# RisuAI Agent 工具调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：只读源码梳理（`src/ts/process/mcp/`、`src/ts/process/request/`、`src/ts/plugins/`、`src/ts/process/modules.ts`、`src/ts/storage/database.svelte.ts`、`src/ts/globalApi.svelte.ts` 等），未修改被调查仓库
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、发现与注入、协议适配、参数解析、编排循环、审批、执行边界、结果回注与持久化、插件扩展与旁路。排除项：嵌入向量（`src/ts/process/embedding/addinfo.ts` 属 HypaMemory 记忆检索，不参与工具循环）、Lua 触发器与脚本系统对生成入口的间接调用、工具结果在消息渲染层的展示细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

1. RisuAI 的 Agent 工具面完全以 MCP 为骨架，没有独立于 MCP 的函数注册表。工具来源共四类：模块声明的远程 HTTP(S)/SSE MCP 服务器、内置 internal 前缀客户端（文件、角色与模块访问、LLM 直调、搜索、图记忆、骰子）、插件经 `registerMCP` 注册的 plugin 模块，以及 OpenAI Responses 请求体里由 `db.modelTools` 开关控制的 `web_search_preview`。
2. 发现与注入没有任何过滤：主聊天请求不传工具参数，请求入口每请求拉取全部已激活 MCP 的工具，注入 OpenAI 兼容、Responses、Anthropic、Google 四类请求体（`request.ts:208`）。无模型能力判定、无按会话裁剪、无 token 预算、无去重。
3. 模型协议是各家原生结构化字段；应用另有一套 `<tool_call>` 文本标签只用于持久化：调用与结果按 ID 存入 localforage，消息文本里只留引用，下一轮请求再解码还原成结构化格式。模型从不直接输出该标签。
4. 编排循环没有统一驱动者：四条 provider 链各自为政。非流式路径靠请求函数递归调用自己；流式路径在 `wrapToolStream` 这类流包装器内于流结束时执行工具并内联续请求（重新 fetch 后继续读新流）。工具串行执行、无并发、未找到任何迭代上限；续请求失败按 `db.requestRetrys`（默认 2）重试后以已有结果收尾。
5. 审批只存在于 `internal:risuai` 的写/删类工具：执行端 handler 在真正变更前弹 `alertConfirm`，拒绝则返回 "Access denied by user." 文本结果。其余所有工具（含文件写入、远程 MCP、插件 MCP）无任何审批。
6. 所有工具都在前端 JS 上下文执行：远程 MCP 走 `fetchNative`（桌面经 Tauri Rust 侧 `streamed_fetch`，web 走 CORS 代理），stdio MCP 仅桌面可用、经 Tauri shell 插件启动子进程，内置客户端直接操作浏览器 API 与数据库。

## 总体调用链

```text
db.modules[*].mcp.url   // http(s):// 或 internal: 或 stdio: 或 plugin: 前缀
  -> initializeMCPs()   握手并构建 MCPs 注册表（internal:risuai 默认进 callOnlyMCPs）
  -> requestChatData()  每请求 getTools() -> getMCPTools()（客户端工具列表会话级缓存）
  -> 请求体 tools / functionDeclarations（simplifySchema 规整后注入）
  -> 模型返回 tool_calls / tool_use / functionCall / function_call item
  -> 各家执行循环：
       非流式：请求函数递归调用自己（OpenAI/Anthropic/Google/Responses 四条链）
       流式：wrapToolStream 于流结束解析 __tool_calls -> callTool -> 续请求 -> 读新流
  -> callMCPTool() 遍历 MCPs+callOnlyMCPs 按工具名首匹配执行
  -> 结果以 role:'tool' / tool_result / functionResponse / function_call_output 回注
  -> rememberToolUsage(true) 时 encodeToolCall 存入 localforage，
     <tool_call>{id}\uF100{name}</tool_call> 并入消息文本随聊天持久化
  -> 下一轮请求 decodeToolCall 还原为结构化工具调用
```

## 1. 工具定义、来源与注册

工具统一表示为 `MCPTool`（name、description、inputSchema、可选 annotations），执行统一返回 `RPCToolCallContent[]`（text / image+audio base64 / resource 三类）。`mcp.ts` 里的 getTools / callTool 只是 getMCPTools / callMCPTool 的包装（`mcp.ts:272-280`，注释自述为将来扩展预留），当前工具面即 MCP 面。

**模块声明与生命周期**：`db.modules` 的每个模块可带 `mcp.url` 字段，`getModuleMcps()` 取出全部 URL（modules.ts:504-508），`initializeMCPs()` 据此增量构建全局注册表：不在列表里的旧客户端会被 destroy 并删除（`mcp.ts:216-221`）。工具列表在客户端实例内缓存（cached.tools），销毁前不会重取。

**远程 MCP 服务器**（http/https 前缀）：`MCPClient`（`mcplib.ts:80-860`）自实现 JSON-RPC 2.0 客户端——`initialize` 握手优先 2025-03-26 streamable HTTP，404 时回退 2024-11-05 的 SSE 传输；401 触发 OAuth 授权码流程（PKCE，刷新令牌持久化到 `DBState.db.authRefreshes`）；`tools/list` 支持游标分页。除协议版本必须为上述两个之一外，握手结果无其他校验。

**stdio MCP**（`stdio:` 前缀 + JSON 配置）：仅 `isTauri` 时允许；`Command.create` 启动子进程，先做最多 10 次、每次 1 秒的 ping-pong 探测，stdout 逐行 JSON 解析，`onDestroy` 时 `child.kill()`（`mcp.ts:91-183`）。

**内置 internal 客户端**：按前缀 switch 实例化六个 `MCPClientLike` 子类（`mcp.ts:45-77`）：

| 标识 | 能力 | 执行细节 |
| --- | --- | --- |
| `internal:fs` | 12 个文件工具（读/写/删/搜索/树/复制/移动等） | File System Access API 目录句柄，首次初始化弹目录选择；读文本上限 100KB、图片 5MB、PDF 转图 |
| `internal:risuai` | 27 个工具（角色 14、模块 12、聊天 1），读写角色/模块/聊天数据 | 直接操作 `DBState.db`；写/删工具在执行端逐次审批（见维度 6） |
| `internal:aiaccess` | `runLLM` 单工具 | 递归调用 `requestChatData` 触发新一轮 LLM 生成 |
| `internal:googlesearch` | 网页/图片搜索两个工具 | 凭据首次使用弹输入框并存入 localforage，请求走 Google Custom Search API |
| `internal:graphmem` | 读写图记忆两个工具 | 记忆体是聊天变量 `graphmem_graph` |
| `internal:dice` | `rollDice` 单工具 | 本地正则解析骰子记号 |

其中 `internal:risuai` 默认被移入 `callOnlyMCPs`：工具不注入请求、只可被调用（`mcp.ts:19-21,223-228`）；用户若把 `internal:risuai` 导入为模块则恢复注入（导入对话框本身就提供该选项，`mcp.ts:283-295`）。

**插件 MCP**：v3 API 暴露 `risuai.registerMCP`（v3.svelte.ts:1125），内部要求 identifier 以 plugin: 开头并存入 `registeredCustomPluginMCPs`（pluginmcp.ts:36-54）；只有当某模块的 mcp.url 恰好是 plugin:xxx 时才会被实例化进注册表（`mcp.ts:83-90`）。插件的工具列表与执行回调是跨 iframe 的回调，实际执行发生在插件沙箱内（见维度 8）。

**Responses API 内置搜索**：`db.modelTools` 含 `'search'` 时，OpenAI Responses 请求体额外追加 `{ type: 'web_search_preview' }`（`responses.ts:332-334`）；设置开关在 `BotSettings.svelte:777-783`。这是唯一不经过 MCP 层的内置工具，且仅对 Responses 格式生效。

## 2. 工具发现、过滤与注入

发现即模块声明：没有按角色、会话或模型收缩工具集的逻辑。两点静态确认的边界：一是 `getModuleMcps` 不读 `enabledModules`，模块设置页的启用开关对 MCP 工具可达性无效；二是模型能力无关——`LLMFlags` 中没有任何与工具支持相关的标志，工具对四类格式的全部模型注入。

注入发生在 `requestChatData` 的入口：`arg.tools ?? (await getTools())`（request.ts:208）。主聊天生成请求不传 tools（index.svelte.ts:1554-1567），因此每次生成、记忆、翻译等一切经该入口的调用都会执行一次 MCP 初始化与工具列表拉取，尽管只有四类格式会真正使用。显式传 tools 的调用方不存在（搜索确认），arg.tools 分支实际上只有测试使用。

四类格式的注入点相同，schema 都经 `simplifySchema` 规整（util.ts:1125-1200：type 转小写、数组 type 中的 null 提升为 nullable、保留 required/enum/format/anyOf）后写入请求体：

- OpenAI 兼容与 Responses：`body.tools`（requests.ts:474-485、responses.ts:324-334）
- Anthropic：`body.tools`（anthropic.ts:574-583）
- Google：`body.tools.functionDeclarations`（google.ts:352-359）

工具为空时不写该字段；OpenAI 兼容模式下 multiGen（n>1 多生成）与工具互斥，直接返回失败（requests.ts:566-572）。tool_choice 全程未设置，交给服务端默认。

## 3. 模型调用表示与 Provider 适配

模型侧协议全部是原生结构化字段，没有文本协议解析（`<tool_call>` 标签只出现在应用自己写入的消息文本里，见维度 7）：

- **OpenAI 兼容**：非流式取 `choices[i].message.tool_calls`，多 choice 的调用合并到 choices[0]（requests.ts:733-746）；流式把 `delta.tool_calls` 按 index 增量拼进 `__tool_calls` 内部键（arguments 用拼接语义，requests.ts:1055-1090）。
- **Anthropic**：非流式遍历 content 数组里的 `tool_use` 块（anthropic.ts:1088-1167）。流式分支只解析 text/thinking/redacted_thinking delta，content_block_start 里的 tool_use 完全被忽略——Claude 在流式模式下返回的工具调用不会被执行，这是已确认的实现边界（anthropic.ts:921-1049）。
- **Google**：`functionCall` part 在非流式与流式候选里一次性整块出现；流式用 `__tool_calls` 收集，thoughtSignature 经 `__sign_text`/`__sign_function` 透传（google.ts:798-806,1099-1110）。
- **Responses API**：非流式从 data.output 提取 `function_call` 项（responses.ts:458-463）；流式按 `call_id` 聚合 `response.function_call_arguments.delta`，response.completed 时从完整 response 提取（responses.ts:618-666）。

历史消息的还原：上一轮持久化进消息文本的 `<tool_call>` 标签，在请求组装阶段被解码回原生结构——OpenAI 拆成 assistant `tool_calls` 与 `role:'tool'` 消息对（requests.ts:41-107）；Claude 重建 `tool_use`/`tool_result` 块、Google 重建 functionCall/functionResponse parts、Responses 链同样拆分（anthropic.ts:272-335、google.ts:138-249、responses.ts:29-111）。

## 4. 参数解析、校验与错误处理

**没有任何 JSON Schema 校验**。模型返回的 `arguments` 字符串只做 `JSON.parse`（包在 try/catch 里），解析失败转成 `role:'tool'` 的错误文本消息（"Tool call failed with error: ..."）；Claude 的 `input` 本身是对象直接透传。工具名不在本次注入的 `arg.tools` 中时写入 "No tool found with name: ..." 消息。畸形参数不会中断循环，而是以文本错误结果进入上下文供模型继续。

参数内容是否合法的校验完全下放给各工具实现（如骰子工具校验记号格式、搜索工具校验 query 非空），而 `internal:risuai` 的多数 handler 直接按 `args.id`、`args.fields` 取字段，对缺字段只返回错误文本。注入侧的 `simplifySchema` 只做形状规整，不校验、不裁剪未知属性。

## 5. 编排循环、并发与终止条件

循环由各家请求处理函数自行驱动，四条链结构同构，没有共享的编排层：

- **OpenAI 兼容非流式**（requests.ts:748-849）：发现 tool_calls 后把 assistant 消息与逐个执行得到的工具消息推入 `body.messages`，然后**递归调用 `requestHTTPOpenAI` 自身**；下一层若再返回工具调用则继续递归，直到模型不再调用。
- **OpenAI 兼容流式**（`wrapToolStream`，requests.ts:1138-1318）：`getTranStream` 把增量汇总进 `__tool_calls`；流读完发现调用时执行工具、续请求（失败按 `db.requestRetrys` 重试，默认 2，database.svelte.ts:201-202），把新响应经同一变换流接回后继续读——即"工具调用在流包装器内联续请求"，且可一轮接一轮重复。已产出的文本与调用码累积进 prefix 持续输出。
- **Anthropic 非流式**（anthropic.ts:1088-1167）：发现 tool_use 时执行并以 `tool_result` 回注后递归 `requestClaudeHTTP`；流式无此能力（见维度 3）。
- **Google 非流式与流式**（google.ts:806-939、`wrapToolStream` google.ts:1069-1309）：同 OpenAI 模式。
- **Responses 非流式与流式**（responses.ts:549-570、`wrapResponsesToolStream` responses.ts:723-865）：同前；store:false 时续请求输入先经 `sanitizeResponsesContinuationItem` 清洗。

共同特征：工具按模型返回顺序 **串行 await**，无并发；**未找到任何迭代上限或深度上限**（全请求目录搜索无 maxIteration/depth 相关代码），模型持续返回工具调用即持续递归，终止只依赖模型不再调用或 `abortSignal`；续请求彻底失败时 `alertError` 并以已积累的结果按成功返回收尾。工具调用期间若用户在 UI 停止生成，`abortSignal` 会中断后续 fetch。

## 6. 审批、授权与执行边界

**审批**：仅 `internal:risuai` 的 13 个写/删类工具在执行端逐次审批——handler 在真正变更前调用 `promptAccess`（`alertConfirm`，`characters.ts:10-12`、`modules.ts:15-17`），拒绝则返回 "Access denied by user." 文本结果且不发生变更；读类工具无审批。这是执行端审批而非仅展示层（判断与执行在同一个 handler 内），但审批状态不持久化、无超时。其余全部工具——文件写入删除、远程 MCP `tools/call`、网页搜索消耗用户凭据、插件工具——均无审批、无风险分级、无全局开关（除模块本身可删除）。

**执行域与隔离**：

- 远程 MCP：前端发起，经 `fetchNative`（globalApi.svelte.ts:1713+）——桌面由 Tauri Rust 侧 `streamed_fetch` 执行 HTTP，web 端走 CORS 代理（`usePlainFetch` 可绕过）；URL 只校验 http/https 前缀，未发现 SSRF 过滤或私有地址限制。
- stdio MCP：Tauri shell 子进程（`Command.create`，env 可配置），stdout 行协议，应用退出时 kill；无沙箱。
- internal:fs：File System Access 目录句柄，浏览器授予目录权限后工具在所选目录内活动，读写有大小上限。
- internal:risuai：直接改数据库对象（角色、模块、聊天），无独立隔离。
- internal:aiaccess：递归发起新的 LLM 请求——工具可以嵌套模型调用，且嵌套调用同样带全量工具（requestChatData 入口无阻止）。
- 插件工具：插件代码运行在 iframe 沙箱（sandbox 仅 allow-scripts/allow-modals/allow-downloads，CSP 含 `connect-src 'none'`，factory.ts:438,769-921），callTool 回调经 postMessage RPC 回到沙箱内执行，只能经宿主 API 白名单访问外部能力（如 nativeFetch 需 `getPluginPermission`）。

## 7. 结果回注、执行状态与恢复

回注格式与各家协议一致：OpenAI/Responses 用 `role:'tool'` + `tool_call_id`（文本取第一个 text 块，`requests.ts:779-804`；图片块在 OpenAI 链被过滤丢弃，Claude 链则转 base64 image block），Google 用 `functionResponse`（文本结果先尝试 JSON.parse），Claude 用 `tool_result`。执行失败同样以文本错误回注，不设特殊错误通道。

持久化链路：`rememberToolUsage` 默认 true（database.svelte.ts:663）。每次工具调用执行后 `encodeToolCall` 把调用与结果按 ID 写入 localforage 的 mcp-tool-calls 库，返回 `<tool_call>{id}\uF100{name}</tool_call>` 文本（mcp.ts:356-360）；该文本并入请求最终结果，随聊天消息一起保存。下一轮请求组装时 `decodeToolCall` 按 ID 取回结果并还原结构化调用（见维度 3）。`simplifiedToolUse`（默认 false）为 true 时消息只保留结构化调用、正文置空。

两点静态发现：一是 localforage 记录没有清理逻辑，条目随使用累积；二是 `decodeToolCall` 对"完整标签文本"的分支 `text.slice('<tool_call>'.length, 0)` 恒返回空串（`mcp.ts:362-378`），该分支在静态上不可达——所有调用方传入的都是正则捕获的标签内文。工具执行没有独立状态机：没有进行中/待审批/已取消的持久化状态，恢复只依赖消息文本中的标签与 localforage 记录；审批拒绝、失败都以普通文本留在上下文里。

## 8. MCP、插件、Skill 与子 Agent

插件系统（v3 API）与工具面的接口是 `registerMCP`/`unregisterMCP`（v3.svelte.ts:1125-1126）。插件沙箱为 iframe srcdoc + CSP + postMessage RPC 桥（`SandboxHost`，factory.ts:434-942），宿主侧 API 经 `makeRisuaiAPIV3` 白名单暴露；插件的工具列表与执行回调都在沙箱内运行。插件安装路径上，v2.1 插件会先过 `checkCodeSafety` 静态扫描（eval、new Function、sessionStorage、cookieStore 黑名单加 window/document 等标识符重写），v3 插件不扫描、纯靠沙箱（plugins.svelte.ts:345-361 与 pluginSafety.ts）。

未找到 Skill、子 Agent 或任务委派机制。

**旁路能力（静态分析）**：

- 插件可经 `setDatabaseLite`/`setDatabase` 写入 db.modules（allowedDbKeys 含 modules/enabledModules，plugins.svelte.ts:482-507,765-794），因此插件能在自身被启用后把 mcp.url = 'plugin:xxx' 的模块写进数据库，把自己注册的工具注入后续全部请求——绕开手动导入模块这一步，但仍以用户安装并启用该插件为前提。
- internal:aiaccess 的 `runLLM` 让模型可嵌套驱动完整生成链路（含再次注入全部工具），是工具面内唯一可自我放大的路径。
- Lua 触发器与请求 replacer 能改写请求消息内容，属于"影响请求"而非"注册工具"的旁路，不在工具目录的校验路径上。

## 9. 设计取舍与已确认边界

- **以 MCP 为唯一工具协议**：内置能力也套用 MCP 客户端接口（internalmcp.ts:1-8 注释直言"技术上不是 MCP，但对用户就这么叫"）。代价是工具发现、schema、调用、结果四段都耦合在 MCP 语义上。
- **全量注入、零过滤**：工具面大小完全由已安装模块决定，模型可见性等于模块声明，没有产品层的工具管理界面（模块本身可增删）。
- **编排分散在 provider 层**：四家请求实现各自维护循环与持久化编码，行为一致但不共享代码；Claude 流式因此成为唯一没有工具循环的格式。
- **持久化与展示耦合**：`<tool_call>` 标签文本同时承担本地存储引用和用户可见文本两种角色。
- 已确认边界：stdio 仅桌面；web 端对 localhost/内网地址的请求被 `fetchNative` 拒绝（globalApi.svelte.ts:695 附近）；工具与 multiGen 互斥；内部客户端初始化失败（如文件目录选择被取消、搜索凭据未填）在 initializeMCPs 的 internal 分支无 try/catch，异常会向 requestChatData 传播（静态推断，未运行验证）。

## 10. 未验证事项

1. 未运行验证真实 MCP 服务器的端到端流程：OAuth 授权码、SSE 回退、`tools/list` 分页、401 刷新。
2. Claude 流式忽略 `tool_use` 后的用户可见行为（流可能无文本结束或被当作空回复）未运行验证。
3. stdio MCP 子进程在 Windows 上的生命周期、env 传递与 kill 行为未运行验证。
4. 无迭代上限的递归在实际服务上的表现（API 消耗、上下文膨胀）未运行验证。
5. `decodeToolCall` 标签剥离分支的恒空行为未运行验证（调用方均传内文，静态上不可达）。
6. 插件 MCP 的激活路径（插件自行写入 `db.modules`）是否为受支持的官方流程未确认。
7. `enabledModules` 不参与 MCP 过滤属于静态推断；模块设置页的启用开关对工具可达性无效这一点未运行确认。
8. risuaccess 写工具的 `alertConfirm` 在流式续请求等待期间的交互（用户不点确认时循环是否挂起、有无超时）未运行验证。
9. `fetchNative` 在 web 端 CORS 代理与桌面 Rust 端 `streamed_fetch` 的超时与重定向行为未展开。
10. 插件权限系统（`getPluginPermission`）的完整权限清单与 `nativeFetch` 的授权范围未逐一核对。

## 关键源码索引

| 主题 | 位置 |
| --- | --- |
| MCP 注册表构建、回收与 call-only 隔离 | `src/ts/process/mcp/mcp.ts:23-229` |
| 工具拉取与调用总入口 | `mcp.ts:231-245,256-280` |
| 持久化编码/解码 | `mcp.ts:342-379` |
| MCP JSON-RPC 客户端（握手/OAuth/工具列表/调用/SSE） | `src/ts/process/mcp/mcplib.ts:80-860` |
| 内置客户端模板与插件注册 | `internalmcp.ts:8-54`、`pluginmcp.ts:6-58` |
| 每请求取工具 | `src/ts/process/request/request.ts:205-208` |
| OpenAI 兼容：注入、非流式循环、流式内联续请求 | `requests.ts:474-485,748-849,972-1318` |
| Responses：注入、非流式循环、流式包装 | `responses.ts:320-372,458-578,723-865` |
| Anthropic：注入、非流式循环、流式（无工具） | `anthropic.ts:574-583,1088-1167,901-1049` |
| Google：注入、非流式循环、流式包装 | `google.ts:352-359,806-939,1069-1309` |
| 执行端逐次审批 | `risuaccess/characters.ts:543 等`、`risuaccess/modules.ts:424 等` |
| 模块 MCP 声明 | `src/ts/process/modules.ts:504-508` |
| 插件 registerMCP 与沙箱 | `apiV3/v3.svelte.ts:1125-1126,1388-1406`、`apiV3/factory.ts:434-942` |
| 插件数据库写入白名单 | `plugins.svelte.ts:482-507,765-794` |
| 工具相关默认值 | `database.svelte.ts:663-664,201-202` |
| 网络执行层 | `globalApi.svelte.ts:1713-1832` |
