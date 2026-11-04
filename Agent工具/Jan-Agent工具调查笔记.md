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

工具体系按表面分为普通 Chat、Cowork 与 CLI，三者共享同一套 Rust 工具实现但注入方式不同。普通 Chat 经 AI SDK tool calling 暴露 Web/RAG/MCP 工具；Cowork 在前端显式运行多步循环，调 `tauri-plugin-agent-tools` 执行文件、shell、记忆与技能工具；CLI 从同一套 Rust 工具构建项目工具目录。普通 Chat 的 MCP 执行仍在 Rust 侧，结果以 `tool-<name>` part 回流。外部客户端（ADK/CLI RPC 会话）走另一条工具路径：工具由客户端声明，运行时把调用派回客户端执行，Jan 只提供内置工具作为可选实现，详见[外部执行体笔记](../外部执行体与应用协作/Jan-外部执行体与应用协作调查笔记.md)。工具 schema 以内置定义为准、由 Rust 侧统一产出（`getAgentToolSchemas`），客户端只为 `todo`/`ask`/`task`/`monitor` 这四个自派发工具转录同构 schema，因此桌面与 CLI 宣传的工具契约一致（`web-app/src/lib/agentTools.ts`、`web-app/src/lib/coworkTools.ts`）。

普通 Chat 的原有工具来源有三类；下列清单不覆盖 Cowork/CLI 的内置工具：

1. **Web 搜索**：`web_search` / `web_fetch`，执行经 `@janhq/tauri-plugin-websearch-api`；
2. **RAG**：`retrieve` / `list_attachments` / `get_chunks`，来自 rag-extension，仅在线程有文档且 RAG 可用时启用；
3. **MCP**：任意 MCP server 的工具，经 `TauriMCPService` → Rust `collect_mcp_tools` / `execute_mcp_tool_calls`。

可横向比较的事实：

- 工具仅在 `selectedModel.capabilities.includes('tools')` 时加载；
- 智能路由开启时，工具集按最后一条用户消息筛选（`mcpOrchestrator.getRelevantTools`），且**路由结果被冻结**（签名 + 缓存），防止每次请求工具集变化破坏提示缓存；
- 工具 schema 会做“规整”以对齐 Rust/GBNF：展开 `properties`、补 `type`、删 date/time format 与复杂 pattern（GBNF 编译失败会静默禁用工具 JSON）；
- 权限分四级：thread 级 / server 级 / 全局 / allow-all；文档嵌入后自动审批 RAG 工具；
- 禁用列表用复合 key `${serverName}::${toolName}`，全局 store 持久化；
- `DropdownToolsAvailable.tsx` 显式过滤 `server === 'Jan Browser MCP'`，浏览器 MCP 工具不出现在开关列表中；
- Web 搜索 API key 只进 OS keyring（`set_secret`/`get_secret`），绝不明文写 settings.json。

Cowork 在模型有 tools capability 时冻结一次运行的工具目录，以免每步改变提示前缀；执行器按调用顺序派发，Plan mode 既从目录里剔除破坏性工具，也在派发端拒绝调用。拒绝集合是写文件、编辑、`shell`、`skill_write`、`task` 与监视器，记忆工具只禁用写类操作（写、编辑、删除、移动），读操作仍可用。它通过原生工具读写文件、运行 shell、调用记忆/技能、截图，另由前端处理 todo、ask、task、monitor；普通 Chat 只额外暴露经过沙箱检查的 shell，不等于全量 Cowork 工具。

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

- 配置文件位于 jan 数据目录 `mcp_config.json`（`helpers.rs:66-73`）；
- 结构 `{ mcpServers, mcpSettings }`（`helpers.rs:80-93`）；`mcpSettings` 承载 `toolCallTimeoutSeconds` 等设置项。

### 2.2 启动与进程管理

- `run_mcp_commands`（`helpers.rs:62-161`）：对所有已配置 server **并行**拉起；
- `start_mcp_server`（`helpers.rs:318-395`）：自带**幂等保护**，重复调用不会重复 spawn（issue #8411）。
- 进程生命周期与传输类型绑定（`helpers.rs:397` 起，约 819 行内分区实现）：
  - **http streamable**（stdio 的替代，长连接内传 SSE）；
  - **sse**；
  - **stdio**（最常用）。
- 子进程创建与清理按平台处理：
  - Windows：`CREATE_NO_WINDOW`（`0x08000000`）避免弹出控制台（`helpers.rs:615`）；
  - Unix：`process_group(0)` 让子进程做进程组组长（`helpers.rs:622`）；
  - 清理：`kill_on_drop` 随 ServerHandle drop 时清理子进程（`helpers.rs:624`）。
- runtime 处理（override 判定 L585-588、命令重写 L590-612）：
  - 优先：配置指定时使用 `bun`/`uvx`；
  - 回退：优先 runtime 启动失败时自动改用系统 `npx`/`uvx` 重试一次（L640-691，`use_override` 循环的 L673-680）；
  - 检查：启动后 500ms 稳定性检查（L720-733，起不来的 server 标记失败），另有 `tools/list` 可达性验证（L735 起，最多 3 次、单次 2s 超时、1s 退避）。

### 2.3 命令入口

- 前端入口是 `TauriMCPService`（`web-app/src/services/mcp/tauri.ts`），方法按用途分组：
  - 工具枚举：`getTools`、`getToolsForServers`；
  - 调用与取消：`callTool`、`callToolWithCancellation`（cancellationToken）、`cancelToolCall`；
  - 启停：`activateMCPServer`、`deactivateMCPServer`；
  - 配置：`getMCPConfig`（解析 MCP 配置 JSON，含 legacy 顶层 server 兼容，L46-63）。
- 执行落在 Rust 侧：`collect_mcp_tools`（`src-tauri/src/core/mcp/commands.rs`）与 `execute_mcp_tool_calls`（代理场景复用 `src-tauri/src/core/server/proxy.rs` L1015/1260/2052）。前端只经 `window.core.api` 发命令，真正的 MCP 会话在 Rust 侧维护。

## 3. 加载与注入

### 3.1 refreshTools

`custom-chat-transport.ts` `refreshTools`（L1056-1308），开头先取一次记忆摘要快照（`refreshMemoryDigest`），让同步构建的系统提示读到同一份快照：

1. 仅 `selectedModel.capabilities.includes('tools')` 时加载（L831-834）；
2. RAG 工具：要求线程有文档且 RAG 功能可用；文档检查（`hasDocuments`）经线程 metadata 或 VectorDBExtension 附件列表接口（L838-859），功能开关 `ragFeatureAvailable` 回退 `useAttachments.enabled`（L861-863）；
3. MCP 工具：开启智能路由（`enableSmartToolRouting`）时按最后一条用户消息筛选相关工具；**路由结果冻结**——`frozenRoutedTools` 加签名缓存，签名包含 server 列表与禁用集合，防止每次请求的工具集变化破坏提示缓存；另有同名校验；
4. 轻量路由模型 `resolveRouterModel`（L979-1024，`isRouterModelSelectable` 校验）；
5. 统一转为 JSON Schema（经 `normalizeToolInputSchema` 规整，L876-881、L950-956）；
6. 禁用过滤：按全局禁用列表过滤，复合 key `${serverName}::${toolName}`（L823-828）。

`use-chat.ts`（L111-117）：MCP/RAG 工具名变化时自动 `refreshTools()`，保证 MCP server 启停后工具集及时更新。

### 3.2 schema 规整

`normalizeToolInputSchemaValue`（`custom-chat-transport.ts:290`，注释称与 Rust 对齐），对外入口 `normalizeToolInputSchema`（`custom-chat-transport.ts:746`）：

- `{properties:{foo:"string"}}` 展开为 `{type:"string"}`（L206-211）；
- `type:'object'` 无 `properties` 补 `{}`（L262-264）；
- 仅 description 补 `type:'string'`（L266-268）；
- 删 `date/time/date-time` format 与含 `\d\w\s` 的 pattern（GBNF 编译失败会静默禁用工具 JSON，L270-287）。

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

- `useToolApprovalRequests.ts`：待审批请求按 `toolCallId` 收集；
- `MessageItem` 在 `awaitingApproval` 时挂起（L142-149、L519-526），审批结果由 SDK `addToolOutput` 送回；
- 文档嵌入后自动 `approveToolForThread`（`$threadId.tsx` L1024-1029）；
- 工具执行留在 onFinish 循环，使工具结果落在已完成的 assistant 消息上（`$threadId.tsx` L172-173、L659-663）。

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

- `ToolCallCard` → `components/ai-elements/tool.tsx`（`ToolHeader/Input/Output`，600 字符折叠阈值）；
- `tool-runtime.tsx`：`ToolElapsed` 计时、`ToolProgressRow`；
- `WebToolWidget.tsx`（search/address 栏）、`RagToolWidget.tsx`（documents 变体：查询实时填充 + 引用卡片 + Shimmer + 范围标签）；
- 描述：`lib/toolPresentation.ts` `describeNativeToolCall`（search/address/documents 三变体）；
- 引用：`lib/citation-parser.ts`、`lib/grounding.ts`（句子切分 + 余弦相似度）；
- `ChainOfThoughtGroup` 承载 reasoning + tool parts 的统一展示。

## 6. 边界与未验证事项

- MCP 的 `maxToolOutputChars` 默认 40000，请求级上限与设置值取较紧者，Rust 对结果统一按字符截断并显式标注截断（`src-tauri/src/core/mcp/commands.rs:395,526`、`truncate.rs:39`）。OAuth 2.1 的 PKCE/动态注册凭据另存于 `mcp_oauth.json`，授权地址还要过 allowlist 检查；这条登录链目前由 CLI 与命令层共同驱动，不能直接推定桌面设置页具有完整 OAuth 交互（`src-tauri/src/core/mcp/oauth.rs`、`commands.rs:596-654`）。
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
