# NextChat Agent 工具调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`（重点 `app/store/plugin.ts`、`app/client/platforms/openai.ts`、`app/utils/chat.ts`、`app/mcp/`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`1d3dc331512929a4b1d3e82354e72acce33b5c7a`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：模型可发现并触发的插件工具和 MCP 工具；统计 Agent 工具时只计入这两类，普通聊天能力、图片生成和 Markdown 渲染归属于应用功能
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的“Agent 工具”是挂在普通聊天请求上的两条工具链，没有独立的规划器或多步 Agent runtime：

1. **OpenAPI 插件工具**把 YAML/JSON OpenAPI 文档的 operation 转成 OpenAI 风格的函数 schema，同时生成一份本地执行映射。模型返回原生工具调用后，浏览器并发执行对应的 HTTP operation，把助手侧调用记录与工具结果消息追加回请求，再递归发起下一轮请求。
2. **MCP 工具**走文本协议，不进入原生工具数组。已连接 stdio MCP server 的工具描述被拼入 system prompt，模型按 `json:mcp:<clientId>` 标记输出 fenced block；客户端用正则提取并通过 MCP SDK 执行，再把结果包装成带 `isMcpResponse` 标记的用户消息送回模型。
3. 插件选择存放在当前会话的 `Mask.plugin` 中，只有当前会话选中的插件才会经 `getAsTools` 注入。内置插件在插件 store hydration 时从 `public/plugins.json` 加载，用户插件与内置插件共用同一套 OpenAPI 转换路径。
4. 插件 HTTP 请求由浏览器或桌面请求链执行，MCP 通过 Next.js server action 在服务端进程管理 stdio 子进程。MCP 要求功能开启、部署配置访问码且请求携带有效访问码；子进程环境由 SDK 默认环境叠加各 server 配置里的环境变量组成。门禁覆盖整组端点访问，单次工具调用没有逐次审批、统一沙箱或 Agent 步数上限。见 [授权检查](../../NextChat/app/mcp/actions.ts#L26-L49)、[子进程环境](../../NextChat/app/mcp/client.ts#L12-L31)。

## ASCII 调用链图

```text
用户输入
  -> useChatStore.onUserInput
     -> getMessagesWithMemory
     -> getClientApi(provider).llm.chat
        -> OpenAI-compatible adapter
           -> currentSession.mask.plugin
           -> usePluginStore.getAsTools()
           -> fetchEventSource(SSE, request.tools)
              -> delta.tool_calls 拼接 arguments
              -> streamWithThink.finish()
                 -> funcs[name](JSON.parse(arguments)) 并发执行
                 -> assistant tool_calls + role:tool 结果追加到 payload
                 -> 60ms 后重新请求同一轮
              -> onFinish -> ChatStore 持久化 assistant message

MCP 支路：
  Home -> initializeMcpSystem -> StdioClientTransport/listTools
  -> getMcpSystemPrompt -> system prompt 中的工具目录
  -> 模型输出 json:mcp:<clientId> fenced block
  -> checkMcpJson -> executeMcpAction
  -> json:mcp-response:<clientId> fenced block 作为 isMcpResponse 用户消息
  -> 下一轮普通聊天请求
```

## 1. OpenAPI 插件如何变成工具

### 1.1 插件数据模型

`Plugin`（`app/store/plugin.ts:12-23`）保存基础字段与可选认证信息：

| 分类 | 字段 | 说明 |
| --- | --- | --- |
| 基础 | `id`、标题、版本 | 插件的标识、名称与版本 |
| 基础 | `content` | 原始 OpenAPI 文档内容 |
| 基础 | `builtin` | 标记是否为内置插件 |
| 认证（可选） | `authType` | 认证方式，如 `custom`、`basic`、`bearer` |
| 认证（可选） | `authLocation` | 认证信息的位置，默认 header，也支持 query 与 body |
| 认证（可选） | `authHeader`、`authToken` | 认证字段名与对应的值 |

`FunctionToolService.add(plugin)`（`app/store/plugin.ts:41-156`）是转换核心：

1. 用 `js-yaml` 读取 OpenAPI 文档，取 `servers[0].url` 作为服务地址。
2. 非 App 模式把请求前缀设为 `/api/proxy`，原始地址放进 `X-Base-URL` 请求头；App 与桌面模式直接使用服务地址。
3. 调用 `OpenAPIClientAxios.getOperations()`，每个 operation 生成一个 `type: "function"` 工具，参数由 JSON request body schema 与 query/path 参数合并。
4. 工具名取自 `getOperationId(o)`，同名执行函数登记在 `funcs` 中；调用时先剥出 path/query 参数，按认证位置写入 header、query 或 body，再由 OpenAPI client 按 path 与 method 发出请求。转换逻辑见 `app/store/plugin.ts:55-150`。

因此，模型看到的是标准函数 schema，实际调用的是 OpenAPI client 生成的 Axios 请求；插件本身不需要实现一个额外的 Agent 接口。

### 1.2 插件来源和选择

- `usePluginStore` 通过 `createPersistStore` 实现持久化（`app/store/plugin.ts:168-232`）。
- rehydrate 时浏览器读取 `./plugins.json`，对尚不存在的内置插件再取一次插件清单 schema，然后统一交给 `FunctionToolService.add` 转换（`app/store/plugin.ts:233-269`）。

当前会话的工具集合由 `Mask.plugin` 给出。OpenAI adapter 在发起流式请求前执行：

```ts
usePluginStore.getState().getAsTools(
  useChatStore.getState().currentSession().mask?.plugin || [],
)
```

调用证据位于 `app/client/platforms/openai.ts:306-320`。`getAsTools`（`app/store/plugin.ts:209-219`）只选择给定 id 的插件，合并工具 schema 与执行映射（`funcs`）；未被当前 Mask 选中的插件不会进入本轮工具数组。

## 2. 原生 tool call 的执行循环

### 2.1 请求和流式解析

- `ChatGPTApi.chat`（`app/client/platforms/openai.ts:186-305`）先合并全局与会话模型配置，处理多模态图片、DALL-E、reasoning model 的参数限制，再在流式路径把工具与执行映射交给 `streamWithThink`。
- SSE 解析（`app/client/platforms/openai.ts:322-353`）：`delta.tool_calls` 以 id 为边界收集，后续没有 id 的 chunk 视为前一调用的 arguments 续片。

### 2.2 并发执行和结果回注

`app/utils/chat.ts:175-390` 的 `stream`，以及带推理处理的 `streamWithThink`（`app/utils/chat.ts:392-667`）有相同的工具循环：

1. 流终止时，收到 `[DONE]`、连接关闭或请求 abort 都会触发 `finish()`。
2. 工具列表非空且当前没有正在执行的任务时，构造带 `tool_calls` 的助手消息。
3. 每个 tool call 先过一遍执行前回调 `options.onBeforeTool`，再用解析后的参数调用同名执行函数。
4. 多个工具并发执行，成功分支优先取 `res.data`，取不到时退回状态文本，非字符串结果转成 JSON；HTTP 状态达到 300 及以上进入错误分支。
5. 每条结果包装成 `role: "tool"` 的工具结果消息，由 `processToolMessage` 追加回请求消息数组。
6. 60ms 后带上原工具数组重新请求同一 `chatApi`，模型可以继续产生下一轮工具调用，直到不再有工具调用；整个循环见 `app/utils/chat.ts:225-295`。

`ChatStore.onUserInput` 在工具前后回调中把工具状态写入当前 assistant 消息的 `tools` 数组（`app/store/chat.ts:459-497`），UI 据此显示工具名、加载、成功和失败状态。

### 2.3 工具执行的边界

- 超时使用全局 `REQUEST_TIMEOUT_MS = 60000`（`app/constant.ts:115-116`），是请求级 abort，不是每个函数的独立超时。
- 没有统一的最大 tool-step、循环检测或跨 provider fallback。
- `funcs[tool.function.name]` 没有显式存在性检查，未知函数名可能在构造 `Promise.resolve` 前直接抛错。
- arguments 直接 `JSON.parse`，畸形 JSON 也可能在工具回调映射阶段同步抛错；仓库没有通用的参数修复器。
- 多个工具并发，结果数组按输入顺序回写，但外部 API 的副作用已经并行发生。

## 3. MCP 工具链

### 3.1 初始化和工具发现

- 初始化：`Home` 首次挂载时读取 MCP 开关，开启后从 AccessStore 取出 access code 调用 `initializeMcpSystem`（`app/components/home.tsx:242-259`、`app/mcp/actions.ts:171-192`）。
- 发现：MCP 配置读自 `app/mcp/mcp_config.json`，每个 active server 经 `createClient` 建立 stdio transport，`listTools` 取回的工具目录存入内存 `clientsMap`（`app/mcp/actions.ts:52-169`）。

MCP 模块标记为 `"use server"`，导出的每个函数都等价于可被 HTTP 直接调用的端点，因此各入口统一先做授权检查，以下三项同时成立才继续，否则直接抛错：

- 功能开关 `ENABLE_MCP` 为 `true`；
- 部署侧配置了访问码 `CODE`；
- 调用方传入 access code 的 MD5 落在 `CODE` 允许集合内。

配置读写、子进程启动、工具枚举和工具执行都受这道门禁约束（`app/mcp/actions.ts:29-50`）。MCP 市场页从 AccessStore 取 access code 随每次调用下传，授权状态不留在服务端会话里（`app/components/mcp-market.tsx:46-49`）。

MCP stdio 子进程采用 [getMcpChildEnvironment](../../NextChat/app/mcp/client.ts#L12-L31)：子进程环境由 MCP SDK 的默认环境集合提供基础变量，再叠加各自 server 配置里的 `env`。CLI 型 server 仍能拿到运行时所需的默认变量，配置里声明的自定义变量照旧生效。

### 3.2 Prompt 协议和回注

`getMcpSystemPrompt`（`app/store/chat.ts:205-224`）接收 access code，把各 client 的工具目录序列化后填入 `MCP_TOOLS_TEMPLATE`；外层再套 `MCP_SYSTEM_TEMPLATE`（两个模板定义见 `app/constant.ts:299-421`）。提示词要求模型输出单个 fenced block：

```json:mcp:<clientId>
{
  "method": "tools/call",
  "params": { "name": "...", "arguments": {} }
}
```

模型输出结束后的处理链：

1. 提取：模型输出先由 `checkMcpJson` 判定，命中后按 `json:mcp:<clientId>` 标记取出 fenced block 并直接解析内容（`app/mcp/utils.ts:1-10`）。
2. 执行：解析出的调用带着 access code 经 `executeMcpAction` 转给已连接的 MCP client（`app/mcp/actions.ts:379-397`）。
3. 回注：成功结果包装成 `json:mcp-response:<clientId>` fenced block，以 `onUserInput(..., true)` 送回并跳过普通输入模板（`app/store/chat.ts:828-862`）。

这条链是“模型文本协议 + 客户端回注”，不是 OpenAI `tools`/`tool_calls` 协议；模型要等一条用户消息形式的结果后再继续。

## 4. 运行时状态和 UI 反馈

- 三处状态分开存放：插件定义进入 Zustand 持久化 store，MCP server 配置写回 `app/mcp/mcp_config.json`，活跃 client 只存在进程内 `clientsMap`。
- 普通插件工具集合由当前 Mask 的 `plugin` 数组决定；MCP 工具由全局 MCP 开关和当前活跃 server 决定，不受 `Mask.plugin` 过滤。
- 消息对象的 `tools` 数组记录工具 id、函数名、参数、结果与 `isError` 标志，界面据此渲染图标和函数名（`app/components/chat.tsx:1943-1967`）。
- MCP server 的生命周期状态有以下几种（`app/mcp/types.ts:99-110`）：

```text
undefined | initializing | active | paused | error
```

对应操作：添加、暂停、恢复、移除和重启，全部需要 access code（`app/mcp/actions.ts:194-377`）。

## 5. 风险、边界和未验证事项

1. **缺少审批/沙箱**：插件 HTTP 请求和 MCP stdio 调用在用户会话上下文直接执行，代码中没有统一的确认弹窗、权限白名单或最小权限运行时。MCP 侧新增的 access code 校验属于部署级门禁（谁能调用整组端点），不构成逐次工具调用的审批；通过校验后的一次工具调用仍按模型给出的参数直接执行。
2. **凭据暴露面**：插件认证 token 会进入客户端持久化状态；MCP access code 也由客户端 AccessStore 持有并随每次 server action 传入，因此能访问前端的人可以复用该 code 调用 MCP 端点。MCP 子进程环境为 SDK 默认变量加 server 配置，但配置里的 `env` 仍是原样传入。应把 plugin schema、认证信息和 MCP 命令视为高信任配置。
3. **文本协议脆弱**：MCP 依赖正则和完整 fenced block，模型输出多个调用、未闭合 block 或非法 JSON 时只会记录错误，未见结构化恢复或重试。
4. **递归请求无步数上限**：工具始终重新请求同一 payload，若模型持续调用工具，主要依赖请求 abort，而不是 Agent 状态机收敛。
5. **兼容性范围**：本次确认了 OpenAI-compatible adapter 的原生工具路径；其他 provider adapter 是否完整支持插件工具，需要逐个检查，不能从 `ClientApi` 接口直接推断。
6. 未运行实际 MCP server、恶意 OpenAPI endpoint 或多工具并发场景；上述行为来自源码静态证据。

## 6. 关键源码索引

- 插件类型、OpenAPI 解析与执行映射：`app/store/plugin.ts:12-156`
- 插件持久化和内置插件加载：`app/store/plugin.ts:168-269`
- OpenAI adapter 注入插件工具、收集流式 tool call：`app/client/platforms/openai.ts:186-353`
- 工具并发执行、结果回写和递归请求：`app/utils/chat.ts:175-390`、`392-667`
- Chat message 工具状态回调：`app/store/chat.ts:459-497`
- MCP 授权门与初始化：`app/mcp/actions.ts:29-50`、`171-192`
- MCP 配置与客户端生命周期：`app/mcp/actions.ts:52-169`、`194-397`
- MCP 状态类型：`app/mcp/types.ts:99-118`
- MCP stdio transport 环境变量：`app/mcp/client.ts:12-31`
- MCP prompt 协议：`app/constant.ts:299-421`
- MCP fenced JSON 提取：`app/mcp/utils.ts:1-10`
- MCP 结果回注：`app/store/chat.ts:828-862`
