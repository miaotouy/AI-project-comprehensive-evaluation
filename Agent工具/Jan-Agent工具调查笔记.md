# Jan Agent 工具调查笔记

> 调查对象：`https://github.com/janhq/jan`（重点 `web-app/src/lib/custom-chat-transport.ts`、`web-app/src/lib/coworkTools.ts`、`src-tauri/plugins/tauri-plugin-agent-tools/`、`web-app/src/hooks/useToolApproval.ts`、`web-app/src/services/mcp/tauri.ts`、`extensions/rag-extension/src/tools.ts`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 Jan 仓库
>
> 调查范围：工具清单、加载与注入（refreshTools）、schema 规整、权限审批、智能路由、工具执行链路与渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

工具体系按表面分为普通 Chat、Cowork 与 CLI 三套入口，三者共用同一批 Rust 工具实现，差别在注入方式：普通 Chat 经 AI SDK 的 tool calling 暴露 Web 搜索、RAG 与 MCP 工具；Cowork 在前端自行运行多步循环，通过 `tauri-plugin-agent-tools` 插件执行文件、shell、记忆与技能工具；CLI 用同一批工具生成项目工具目录。普通 Chat 的 MCP 执行仍留在 Rust 侧，结果以 `tool-<name>` 形式的 part 回传给前端。

外部客户端（ADK/CLI RPC 会话）走另一条工具路径：工具由客户端声明，运行时把调用派回客户端执行，Jan 只提供内置工具作为可选实现，详见[外部执行体笔记](../外部执行体与应用协作/Jan-外部执行体与应用协作调查笔记.md)。

工具 schema 以内置定义为准、由 Rust 侧统一产出（`getAgentToolSchemas`）；客户端只为 todo、ask、task、monitor 这四个自派发工具转录同构 schema，因此桌面与 CLI 宣传的工具契约一致（`web-app/src/lib/agentTools.ts`、`web-app/src/lib/coworkTools.ts`）。

普通 Chat 的原有工具来源有三类；下列清单不覆盖 Cowork/CLI 的内置工具：

1. **Web 搜索**：`web_search` 负责搜索、`web_fetch` 负责抓取，执行交给 `@janhq/tauri-plugin-websearch-api` 插件；
2. **RAG**：`retrieve` 检索、`list_attachments` 列举附件、`get_chunks` 读取分块，来自 rag-extension，仅在线程有文档且 RAG 可用时启用；
3. **MCP**：任意 MCP server 的工具，前端经 `TauriMCPService` 发命令，由 Rust 侧完成工具枚举与执行。

可横向比较的事实：

- 只有选中模型声明了 tools 能力时才加载工具；
- 智能路由开启时，工具集按最后一条用户消息筛选，且筛选结果连同签名一起冻结缓存，避免每次请求的工具集变化破坏提示缓存；
- 工具 schema 会做规整以对齐 Rust 与 GBNF：展开 properties、补齐 type、删除 date/time 格式与复杂 pattern；GBNF 编译失败时工具 JSON 会被静默禁用；
- 权限分四级：thread 级、server 级、全局与 allow-all；文档嵌入后对 RAG 工具自动审批；
- 禁用列表用 `${serverName}::${toolName}` 形式的复合 key 记录，持久化在全局 store；
- `DropdownToolsAvailable.tsx` 显式过滤 Jan Browser MCP，浏览器 MCP 工具不出现在开关列表中；
- Web 搜索的 API key 经 set_secret 与 get_secret 只写入 OS keyring，绝不明文写进 settings.json。

Cowork 在模型有 tools capability 时冻结一次运行的工具目录，以免每步改变提示前缀；执行器按调用顺序派发，Plan mode 既从目录里剔除破坏性工具，也在派发端拒绝调用。拒绝集合是写文件、编辑、`shell`、`skill_write`、`task` 与监视器，记忆工具只禁用写类操作（写、编辑、删除、移动），读操作仍可用。它通过原生工具读写文件、运行 shell、调用记忆/技能、截图，另由前端处理 todo、ask、task、monitor；普通 Chat 只额外暴露经过沙箱检查的 shell，上列完整工具目录仅在 Cowork 运行内可用。

## 1. 工具清单

| 工具 | 来源 | 启用条件 |
|---|---|---|
| `web_search` / `web_fetch` | `web-app/src/lib/webSearchTool.ts`（`WEB_TOOL_NAMES` L4，执行经 tauri-plugin-websearch-api） | `useWebSearchConfig.webSearchEnabled`（默认 true，custom-chat-transport L964-973） |
| `retrieve` / `list_attachments` / `get_chunks` | `extensions/rag-extension/src/tools.ts`（`getRAGTools(retrievalLimit)` L8；`callTool` switch 在 index.ts L110-127；retrieve 返回 citations 载荷） | 线程有文档（`hasDocuments`）且 RAG 可用；`server='rag-internal'` |
| MCP server 任意工具 | `web-app/src/services/mcp/tauri.ts` → `window.core.api` → Rust（`src-tauri/src/core/mcp/commands.rs` `collect_mcp_tools`；本地 API 代理执行 `src-tauri/src/core/server/proxy.rs` L1015/1260/2052 `execute_mcp_tool_calls`） | 模型 `capabilities` 含 `tools` 且未被禁用 |

Web 搜索配置集中在 `useWebSearchConfig.ts`（112 行），`WEB_SEARCH_PROVIDERS` 只含三个 provider，默认 exa（L16-41）：

| provider | 配置要求 |
|---|---|
| `exa` | 无 key，默认 |
| `tavily` | 需 key |
| `searxng` | 需 endpoint |

**API 密钥经 `set_secret`/`get_secret` 存入 OS keyring，绝不明文写入 `settings.json`**（L69-80、L89-94）。

partialize 只持久化 `webSearchEnabled`、`searchProvider`、`endpoints` 三个字段。

## 2. MCP 服务生命周期（Rust 侧）

`src-tauri/src/core/mcp/helpers.rs` 是 MCP 进程的管理核心，下面的事实都是行级核验。

### 2.1 配置存储与解析

- 配置文件是 jan 数据目录下的 mcp_config.json（`helpers.rs:66-93`）；
- 结构分 mcpServers 与 mcpSettings 两段，后者承载 toolCallTimeoutSeconds 等设置项。

### 2.2 启动与进程管理

- 启动入口 `run_mcp_commands` 把所有已配置 server 并行拉起（`helpers.rs:62-161`）。
- 单个 server 的启动入口 `start_mcp_server` 自带幂等保护，重复调用不会重复 spawn（`helpers.rs:318-395`，对应 issue #8411）。进程生命周期按传输类型分区实现（同文件第 397 行起，约 819 行）：
  - http streamable：在长连接内传 SSE，作为 stdio 的替代；
  - sse；
  - stdio：最常用。
- 子进程的创建与清理按平台处理（`helpers.rs:615-624`）：
  - Windows：用 CREATE_NO_WINDOW（0x08000000）避免弹出控制台；
  - Unix：用 process_group(0) 让子进程担任进程组组长；
  - 清理：kill_on_drop 随 ServerHandle drop 时回收子进程。
- runtime 处理分优先、回退与检查三步（`helpers.rs:585-735`）：
  - 优先：配置指定 runtime 时使用 bun 或 uvx；
  - 回退：优先 runtime 启动失败时自动改用系统 npx 或 uvx 重试一次；
  - 检查：启动后做 500ms 稳定性检查，起不来的 server 标记失败；再做 tools/list 可达性验证，最多 3 次、单次 2s 超时、1s 退避。

### 2.3 命令入口

- 前端入口是 `TauriMCPService`（`web-app/src/services/mcp/tauri.ts`），对外方法按用途分四组：
  - 工具枚举用 getTools 与 getToolsForServers；
  - 调用与取消用 callTool、callToolWithCancellation（带 cancellationToken 取消令牌）与 cancelToolCall；
  - 启停用 activateMCPServer 与 deactivateMCPServer；
  - 配置读取用 getMCPConfig，它解析 MCP 配置 JSON，并兼容 legacy 的顶层 server 写法（L46-63）。
- 执行落在 Rust 侧：collect_mcp_tools 负责枚举工具，execute_mcp_tool_calls 负责执行，代理场景复用同一实现（`src-tauri/src/core/mcp/commands.rs`、`src-tauri/src/core/server/proxy.rs:1015`）。前端只经 window.core.api 发命令，真正的 MCP 会话由 Rust 侧维护。

## 3. 加载与注入

### 3.1 refreshTools

`custom-chat-transport.ts` `refreshTools`（L1056-1308），开头先取一次记忆摘要快照（`refreshMemoryDigest`），让同步构建的系统提示读到同一份快照：

1. 先判断选中模型是否声明 tools 能力，未声明则不加载（L831-834）；
2. RAG 工具要求线程有文档且 RAG 功能可用：文档检查走线程 metadata 或 VectorDBExtension 的附件列表接口（L838-859），RAG 开关取 ragFeatureAvailable，缺失时回退到 useAttachments.enabled（L861-863）；
3. MCP 工具在开启智能路由时按最后一条用户消息筛选；筛选结果连同签名一起冻结缓存，签名覆盖 server 列表与禁用集合，避免每次请求的工具集变化破坏提示缓存；此外还有同名校验；
4. 轻量路由模型的解析由 resolveRouterModel 负责，选中前经 `isRouterModelSelectable` 校验（L979-1024）；
5. 所有工具输入统一规整为 JSON Schema，规整由 `normalizeToolInputSchema` 完成（L876-881、L950-956）；
6. 最后按全局禁用列表过滤，匹配按 server 名与工具名拼成的复合 key 判断（L823-828）。

`use-chat.ts`（L111-117）：MCP/RAG 工具名变化时自动 `refreshTools()`，保证 MCP server 启停后工具集及时更新。

### 3.2 schema 规整

`normalizeToolInputSchemaValue`（`custom-chat-transport.ts:290`，注释称与 Rust 对齐），对外入口 `normalizeToolInputSchema`（`custom-chat-transport.ts:746`）：

- 属性值写成简写时展开成标准类型定义，例如 `{properties:{foo:"string"}}` 变为 `{type:"string"}`（L206-211）；
- 声明为 object 却缺 properties 时补一个空对象（L262-264）；
- 字段只有 description 时补上 string 类型（L266-268）；
- 删除 date/time/date-time 三类 format 与含 `\d\w\s` 的 pattern；GBNF 编译失败会让工具 JSON 被静默禁用（L270-287）。

## 4. 权限与审批

本节的四级审批属于普通 Chat 的 MCP 工具。Cowork 的 Plan mode 是执行端拒绝，并非靠模型遵守提示；附加项目目录在 Cowork 中以可写根身份进入工作区，write/edit 可以原地修改，普通 Chat 的附加目录仍只读。判断以调用链和 Rust 的 write_roots 为准（`web-app/src/lib/coworkDispatch.ts`、`src-tauri/plugins/tauri-plugin-agent-tools/src/commands.rs`）。

只读 Agent 与写入 Agent 的根目录策略不同：只读 Agent 拿到的根集合去掉了可写位，子 Agent 各自在独立 git worktree 中工作，避免并行修改互相覆盖；沙箱内 shell 命令可以申请越出沙箱，但需要用户批准，`--safe` 只把这类升级再问一次。CLI 的 `--safe` 审批、`--sandbox` OS 隔离、`--no-sandbox` 与升级开关是相互独立的控制，默认全局 sandbox 关闭。

### 4.1 四级审批

`web-app/src/hooks/useToolApproval.ts`（92 行，zustand + persist）：

- `approvedTools`：threadId → 工具名数组（会话级信任）；
- `approvedServers`：全局信任的 MCP server；
- `approvedToolsGlobal`：全局信任的工具（无 server 归属时用）；
- `allowAllMCPPermissions`：放行所有 MCP 权限。

`isToolApproved`（L62-73）优先级：全局工具 > 全局 server > thread 级。持久化在 localStorage 键 `tool-approval`，`skipHydration: true`。

### 4.2 请求与执行时机

- 待审批请求由 useToolApprovalRequests 按工具调用 ID 收集；
- 消息组件在等待审批时挂起（L142-149、L519-526），审批结果经 SDK 的 addToolOutput 送回；
- 文档嵌入完成后自动为当前 thread 批准相关工具（`$threadId.tsx` L1024-1029）；
- 工具执行放在 onFinish 循环里，让工具结果落在已完成的 assistant 消息上（`$threadId.tsx` L172-173、L659-663）。

### 4.3 设置 UI

- `routes/settings/mcp-servers.tsx`：`toolCallTimeoutSeconds`、智能路由开关、路由模型选择；
- `routes/settings/web-search.tsx`：provider 与 key。

## 5. 工具渲染与执行链路

### 5.1 执行链

```text
useChat.sendMessage
  -> CustomChatTransport.sendMessages
       -> streamText(tools, toolChoice:'auto')
       -> AI SDK 执行循环
            -> MCP 工具经 window.core.api（TauriMCPService.callTool）
               -> Rust collect/execute_mcp_tool_calls
            -> 结果回 tool-* part
       -> toUIMessageStream 流式更新 DOM
```

执行链上的调用对象是 `TauriMCPService`（`web-app/src/services/mcp/tauri.ts`），方法清单见 2.3。

### 5.2 渲染

| 组件或模块 | 职责 |
|---|---|
| `ToolCallCard`（`components/ai-elements/tool.tsx`） | 分 ToolHeader、Input、Output 三段渲染，输出超过 600 字符折叠 |
| `tool-runtime.tsx` | ToolElapsed 计时与 ToolProgressRow 进度行 |
| `WebToolWidget.tsx`、`RagToolWidget.tsx` | 前者渲染 search/address 栏；后者渲染 documents 变体，含查询实时填充、引用卡片、Shimmer 与范围标签 |
| `lib/toolPresentation.ts` | describeNativeToolCall 生成工具描述，覆盖 search、address、documents 三变体 |
| `lib/citation-parser.ts`、`lib/grounding.ts` | 引用解析；grounding 负责句子切分与余弦相似度 |
| `ChainOfThoughtGroup` | 统一承载 reasoning 与 tool parts 的展示 |

## 6. 边界与未验证事项

- MCP 的 `maxToolOutputChars` 默认 40000 字符；请求级上限与设置值取较紧者，Rust 侧按字符统一截断并显式标注（`src-tauri/src/core/mcp/commands.rs:395`、`truncate.rs:39`）。
- OAuth 2.1 的 PKCE 凭据与动态注册凭据另存于 mcp_oauth.json，授权地址还要通过 allowlist 检查；这条登录链目前由 CLI 与命令层共同驱动，桌面设置页是否具备完整 OAuth 交互需在设置页入口单独核对（`src-tauri/src/core/mcp/oauth.rs`、`commands.rs:596-654`）。
- 未运行 Cowork 工作区写入、Shell 沙箱或 MCP OAuth 的端到端调用；普通 Chat 的审批 store 不能代表这些新表面的权限语义。
- 子 Agent 的 git worktree 生命周期（`/new`、`/clear`、`/resume` 与崩溃后的收尾）、只读根的实际生效范围、沙箱升级审批只做了静态核对。
- 记忆工具写入后的索引边界（有界、面向缓存稳定的摘要快照）未验证召回效果；`refreshMemoryDigest` 的缓存失效条件未展开。

- `DropdownToolsAvailable.tsx` 显式过滤 `server === 'Jan Browser MCP'`——浏览器 MCP 工具在开关列表中不可见（事实）；它是否仍可被模型调用需运行时验证。
- 未发现“JSON schema 自动生成参数表单”的机制；工具参数无 UI 表单，由模型直接填 JSON。
- `experimental_repairToolCall` 只修 Windows 路径反斜杠导致的 JSON 转义失败（`InvalidToolInputError` 判定，L1384）；其他工具输入错误由 SDK 默认路径处理。
- 智能路由冻结后，同一签名下的工具集固定；用户消息变化但签名命中缓存时工具集不更新（设计如此，行为需运行时确认）。
- RAG 检索内部（向量库调用、`rag-internal` server 的真实端点）未逐项核对。
- 未运行项目测试或构建；记录来自静态源码。

## 7. 关键源码索引

- 工具加载与注入：`web-app/src/lib/custom-chat-transport.ts:1056-1308`
- schema 规整：`custom-chat-transport.ts:290,746`
- 禁用过滤：`custom-chat-transport.ts:823-828`
- 工具执行入口：`custom-chat-transport.ts:1382`（`sendMessages`）起
- 审批 store：`web-app/src/hooks/useToolApproval.ts`
- 审批请求收集：`web-app/src/hooks/useToolApprovalRequests.ts`
- 禁用列表 store：`web-app/src/hooks/useToolAvailable.ts`
- MCP 服务：`web-app/src/services/mcp/tauri.ts`、`default.ts`
- MCP 进程管理：`src-tauri/src/core/mcp/helpers.rs`（`run_mcp_commands:63`、`start_mcp_server:320`、传输分区与稳定性检查见同文件）
- MCP 命令：`src-tauri/src/core/mcp/commands.rs`
- Web 搜索：`web-app/src/lib/webSearchTool.ts`、`web-app/src/hooks/useWebSearchConfig.ts`
- RAG 工具定义：`extensions/rag-extension/src/tools.ts`、`extensions/rag-extension/src/index.ts:144,180`
- 工具执行插件：`src-tauri/plugins/tauri-plugin-agent-tools/`（`commands.rs`、`workspace.rs`、`preview.rs`）
- 工具渲染：`web-app/src/components/ai-elements/tool.tsx`、`tool-runtime.tsx`、`WebToolWidget.tsx`、`RagToolWidget.tsx`
- 工具描述与引用：`web-app/src/lib/toolPresentation.ts`、`citation-parser.ts`、`grounding.ts`
- 设置 UI：`web-app/src/routes/settings/mcp-servers.tsx`、`web-app/src/routes/settings/web-search.tsx`
