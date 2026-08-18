# NextChat Agent 工具调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`（重点 `app/store/plugin.ts`、`app/client/platforms/openai.ts`、`app/utils/chat.ts`、`app/mcp/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：关注模型可发现并触发的插件工具和 MCP 工具；不把普通聊天能力、图片生成和 Markdown 渲染计入 Agent 工具
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的“Agent 工具”不是一个独立的规划器或多步 Agent runtime，而是挂在普通聊天请求上的两条工具链：

1. **OpenAPI 插件工具**把 YAML/JSON OpenAPI 文档的 operation 转成 OpenAI 风格的 `function` schema，同时生成一个本地执行映射。模型返回原生工具调用（`tool_calls`）后，浏览器并发执行对应 HTTP operation，把助手侧调用记录与工具结果消息（`role: tool`）追加回请求，再递归发起下一轮请求。
2. **MCP 工具**不进入原生 `tools` 数组。已连接 stdio MCP server 的工具描述被拼入 system prompt，模型按 `json:mcp:<clientId>` fenced block 输出请求；客户端正则提取并通过 MCP SDK 执行，再把结果作为带 `isMcpResponse` 标记的用户消息送回模型。
3. 插件选择存放在当前会话的 `Mask.plugin` 中，只有当前会话选中的插件才会通过 `getAsTools` 注入。内置插件在插件 store hydration 时从 `public/plugins.json` 加载，用户插件和内置插件使用同一套 OpenAPI 转换路径。
4. 工具执行完全在客户端/桌面端请求上下文内，没有统一的审批、沙箱、权限策略或 Agent 步数上限。插件 endpoint、认证位置和 token 均可由用户配置；MCP stdio 子进程继承整个 `process.env`，因此执行边界很宽。

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

- 基础：`id`、标题、版本、原始 `content`、`builtin` 标志；
- 认证（可选）：
  - `authType`：如 `custom`、`basic`、`bearer` 等；
  - `authLocation`：默认 header，也支持 query/body；
  - `authHeader`、`authToken`：认证名称和值。

`FunctionToolService.add(plugin)`（`app/store/plugin.ts:41-156`）是转换核心：

1. 使用 `js-yaml` 读取 OpenAPI 文档，取 `servers[0].url` 作为 endpoint。
2. 非 App 模式把 base URL 设为 `/api/proxy`，原始 endpoint 放进 `X-Base-URL`；App/桌面模式直接使用 server URL（`app/store/plugin.ts:55-77`）。
3. 调用 `OpenAPIClientAxios.getOperations()`，每个 operation 生成一个 `type: "function"` 工具；参数由 JSON request body schema 与 query/path 参数合并（`app/store/plugin.ts:82-123`）。
4. 用 `getOperationId(o)` 作为函数名，并在 `funcs` 中保存同名执行函数。执行函数会把 path/query 参数单独取出，再按认证位置写入 header、query 或 body，最后调用 `api.client.paths[o.path][o.method]`（`app/store/plugin.ts:125-150`）。

因此，模型看到的是标准函数 schema，实际调用的是 OpenAPI client 生成的 Axios 请求；插件本身不需要实现一个额外的 Agent 接口。

### 1.2 插件来源和选择

- `usePluginStore` 是用 `createPersistStore` 创建的持久化 store（`app/store/plugin.ts:168-232`）。
- rehydrate 时浏览器读取 `./plugins.json`，对尚未存在的内置插件再拉取一次插件清单 schema，然后走同一转换入口 `FunctionToolService.add`（`app/store/plugin.ts:233-269`）。

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

1. `[DONE]`、连接关闭或 abort 触发 `finish()`。
2. `runTools` 非空且当前没有执行任务时，构造 `{ role: "assistant", tool_calls }`。
3. 对每个 tool call 调用 `options.onBeforeTool`，执行 `funcs[tool.function.name](JSON.parse(arguments))`。
4. 多个工具并发执行；成功结果优先读 `res.data`，否则用状态文本兜底，非字符串结果转 JSON 字符串；HTTP 状态大于等于 300 进入错误分支。
5. 每个结果先包装成 `{ name, role: "tool", content, tool_call_id }` 形式的工具结果消息，再经 `processToolMessage` 追加到请求消息数组（`app/utils/chat.ts:225-280`）。
6. 60ms 后重新调用同一 `chatApi`，把原工具数组再次放入请求；模型可以继续产生下一轮工具调用，直到最终没有工具调用（`app/utils/chat.ts:280-295`）。

`ChatStore.onUserInput` 在工具前后回调中把工具状态写入当前 assistant 消息的 `tools` 数组（`app/store/chat.ts:459-497`），UI 据此显示工具名、加载、成功和失败状态。

### 2.3 工具执行的边界

- 超时使用全局 `REQUEST_TIMEOUT_MS = 60000`（`app/constant.ts:115-116`），是请求级 abort，不是每个函数的独立超时。
- 没有统一的最大 tool-step、循环检测或跨 provider fallback。
- `funcs[tool.function.name]` 没有显式存在性检查，未知函数名可能在构造 `Promise.resolve` 前直接抛错。
- arguments 直接 `JSON.parse`，畸形 JSON 也可能在工具回调映射阶段同步抛错；仓库没有通用的参数修复器。
- 多个工具并发，结果数组按输入顺序回写，但外部 API 的副作用已经并行发生。

## 3. MCP 工具链

### 3.1 初始化和工具发现

- `Home` 首次挂载时读取 `getServerSideConfig().enableMcp`，开启后调用 `initializeMcpSystem`（`app/components/home.tsx:242-259`）；
- 配置与发现：MCP 配置读自 `app/mcp/mcp_config.json`；每个 active server 经 `createClient` 建立 stdio transport，工具目录（`listTools`）存入内存 `clientsMap`（`app/mcp/actions.ts:101-161`）。

`app/mcp/client.ts:15-25` 明确把整个 `process.env` 复制进子进程环境，再叠加配置中的 `env`。这方便 CLI 型 MCP server 找到运行时依赖，但也意味着服务器配置可以接触到宿主进程环境变量。

### 3.2 Prompt 协议和回注

`getMcpSystemPrompt`（`app/store/chat.ts:205-224`）把各 client 的工具目录序列化后填入 `MCP_TOOLS_TEMPLATE`；外层再套 `MCP_SYSTEM_TEMPLATE`（模板定义见 `app/constant.ts:299-354`）。提示词要求模型输出单个 fenced block：

```json:mcp:<clientId>
{
  "method": "tools/call",
  "params": { "name": "...", "arguments": {} }
}
```

模型输出结束后的处理链：

1. 提取：`checkMcpJson` → `isMcpJson`/`extractMcpJson`，按 `json:mcp:<clientId>` 标记提取并直接解析 block 内容（`app/mcp/utils.ts:1-10`）；
2. 执行：经 `executeMcpAction` 转到已连接的 MCP client（`app/mcp/actions.ts:336-352`）；
3. 回注：成功结果包装成 `json:mcp-response:<clientId>` fenced block，调用 `onUserInput(..., true)` 并跳过普通输入模板（`app/store/chat.ts:826-855`、`407-434`）。

这条链是“模型文本协议 + 客户端回注”，不是 OpenAI `tools`/`tool_calls` 协议；模型要等一条用户消息形式的结果后再继续。

## 4. 运行时状态和 UI 反馈

- 插件定义、MCP 配置和客户端状态分开保存：插件进入 Zustand 持久化 store，MCP server 配置写回 `app/mcp/mcp_config.json`，活跃 client 只存在进程内 `clientsMap`。
- 当前 Mask 的 `plugin` 数组决定普通插件工具集合；MCP 工具由全局 MCP 开关和当前活跃 server 决定，不受 Mask.plugin 过滤。
- 消息对象的 `tools` 数组记录工具 id、函数名、参数、结果与 `isError` 标志；`app/components/chat.tsx:1943-1967` 据此渲染图标和函数名。
- MCP server 生命周期状态字面量（`app/mcp/actions.ts:26-74`）：

```text
undefined | initializing | active | paused | error
```

对应操作：添加、暂停、恢复、移除和重启（`app/mcp/actions.ts:163-333`）。

## 5. 风险、边界和未验证事项

1. **缺少审批/沙箱**：插件 HTTP 请求和 MCP stdio 调用在用户会话上下文直接执行，代码中没有统一的确认弹窗、权限白名单或最小权限运行时。
2. **凭据暴露面**：插件认证 token 会进入客户端持久化状态；MCP 子进程继承全部 `process.env`。应把 plugin schema、认证信息和 MCP 命令视为高信任配置。
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
- MCP 初始化和配置生命周期：`app/mcp/actions.ts:101-161`、`163-385`
- MCP stdio transport 环境变量：`app/mcp/client.ts:9-38`
- MCP prompt 协议：`app/constant.ts:299-354`
- MCP fenced JSON 提取：`app/mcp/utils.ts:1-10`
- MCP 结果回注：`app/store/chat.ts:826-855`
