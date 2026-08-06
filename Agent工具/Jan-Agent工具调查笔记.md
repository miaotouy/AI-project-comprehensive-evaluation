# Jan Agent 工具调查笔记

> 调查对象：`E:\works\git\jan`（重点 `web-app/src/lib/custom-chat-transport.ts`、`web-app/src/hooks/useToolApproval.ts`、`web-app/src/services/mcp/tauri.ts`、`extensions/rag-extension/src/tools.ts`、`web-app/src/lib/webSearchTool.ts`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 Jan 仓库
>
> 调查范围：工具清单、加载与注入（refreshTools）、schema 规整、权限审批、智能路由、工具执行链路与渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的工具体系是 **AI SDK `streamText` 原生 tool calling + 扩展来源**的组合：工具本身由 SDK 执行循环调用，MCP 工具的执行实体在 Rust 侧（经 Tauri 命令），结果以 `tool-<name>` part 流回 UI。

工具来源只有三类（无独立 calculator 等内置工具）：

1. **Web 搜索**：`web_search` / `web_fetch`，执行经 `@janhq/tauri-plugin-websearch-api`；
2. **RAG**：`retrieve` / `list_attachments` / `get_chunks`，来自 rag-extension，仅在线程有文档且 RAG 可用时启用；
3. **MCP**：任意 MCP server 的工具，经 `TauriMCPService` → Rust `collect_mcp_tools` / `execute_mcp_tool_calls`。

值得横向比较的几个事实：

- 工具仅在 `selectedModel.capabilities.includes('tools')` 时加载；
- 智能路由开启时，工具集按最后一条用户消息筛选（`mcpOrchestrator.getRelevantTools`），且**路由结果被冻结**（签名 + 缓存），防止每次请求工具集变化破坏提示缓存；
- 工具 schema 会做“规整”以对齐 Rust/GBNF：展开 `properties`、补 `type`、删 date/time format 与复杂 pattern（GBNF 编译失败会静默禁用工具 JSON）；
- 权限分四级：thread 级 / server 级 / 全局 / allow-all；文档嵌入后自动审批 RAG 工具；
- 禁用列表用复合 key `${serverName}::${toolName}`，全局 store 持久化；
- `DropdownToolsAvailable.tsx` 显式过滤 `server === 'Jan Browser MCP'`，浏览器 MCP 工具不出现在开关列表中；
- Web 搜索 API key 只进 OS keyring（`set_secret`/`get_secret`），绝不明文写 settings.json。

## 1. 工具清单

| 工具 | 来源 | 启用条件 |
|---|---|---|
| `web_search` / `web_fetch` | `web-app/src/lib/webSearchTool.ts`（`WEB_TOOL_NAMES` L4，执行经 tauri-plugin-websearch-api） | `useWebSearchConfig.webSearchEnabled`（默认 true，custom-chat-transport L964-973） |
| `retrieve` / `list_attachments` / `get_chunks` | `extensions/rag-extension/src/tools.ts`（`getRAGTools(retrievalLimit)` L8；`callTool` switch 在 index.ts L110-127；retrieve 返回 citations 载荷） | 线程有文档（`hasDocuments`）且 RAG 可用；`server='rag-internal'` |
| MCP server 任意工具 | `web-app/src/services/mcp/tauri.ts` → `window.core.api` → Rust（`src-tauri/src/core/mcp/commands.rs` `collect_mcp_tools`；本地 API 代理执行 `src-tauri/src/core/server/proxy.rs` L1015/1260/2052 `execute_mcp_tool_calls`） | 模型 `capabilities` 含 `tools` 且未被禁用 |

Web 搜索配置 `useWebSearchConfig.ts`（112 行）：`WEB_SEARCH_PROVIDERS = exa(无 key)/tavily(需 key)/searxng(需 endpoint)`，默认 exa（L16-41）；**API 密钥经 `set_secret`/`get_secret` 存 OS keyring，绝不明文写入 settings.json**（L69-80、L89-94，partialize 只持久化 webSearchEnabled/searchProvider/endpoints）。

## 2. MCP 服务生命周期（Rust 侧）

`src-tauri/src/core/mcp/helpers.rs` 是 MCP 进程的管理核心，下面的事实都是行级核验。

### 2.1 配置存储与解析

- 配置文件位于 jan 数据目录 `mcp_config.json`（`helpers.rs:66-73`）；
- 结构 `{ mcpServers, mcpSettings }`（`helpers.rs:80-93`）；`mcpSettings` 承载 `toolCallTimeoutSeconds` 等设置项。

### 2.2 启动与进程管理

- `run_mcp_commands`（`helpers.rs:62-161`）：对所有已配置 server **并行**拉起；`start_mcp_server`（`helpers.rs:318-395`）自带**幂等保护**（重复调用不会重复 spawn，issue #8411）。
- 进程生命周期与传输类型绑定（`helpers.rs:397` 起，约 819 行内分区实现）：
  - **http streamable**（stdio 的替代，长连接内传 SSE）；
  - **sse**；
  - **stdio**（最常用）。
- Windows 下用 `CREATE_NO_WINDOW`（`0x08000000`，`helpers.rs:615`）避免弹出控制台；Unix 侧 `process_group(0)`（`helpers.rs:622`）让子进程做进程组组长；`kill_on_drop`（`helpers.rs:624`）随 ServerHandle drop 时清理。
- runtime 覆盖：配置指定时优先 `bun`/`uvx`（override 判定 L585-588、命令重写分支 L590-612），**启动失败自动回退系统 `npx`/`uvx` 重试一次**（L640-691，`use_override` loop 的 L673-680）；启动后 500ms 稳定性检查（L720-733，起不来的 server 标记失败），另有 `tools/list` 可达性验证（L735 起，最多 3 次、单次 2s 超时、1s 退避）。

### 2.3 命令入口

- `web-app/src/services/mcp/tauri.ts`：`getToolsForServers`/`callTool`/`callToolWithCancellation`（cancellationToken）/`cancelToolCall`/`activateMCPServer`/`deactivateMCPServer`；
- 执行落在 Rust `collect_mcp_tools`（`src-tauri/src/core/mcp/commands.rs`）与 `execute_mcp_tool_calls`（代理场景在 `src-tauri/src/core/server/proxy.rs` L1015/1260/2052 复用）——即前端只经 `window.core.api` 发命令，真正的 MCP 会话在 Rust 侧维护。

## 3. 加载与注入

### 2.1 refreshTools

`custom-chat-transport.ts` `refreshTools`（L815-977）：

1. 仅 `selectedModel.capabilities.includes('tools')` 时加载（L831-834）；
2. RAG 工具：`hasDocuments`（线程 metadata 或 `VectorDBExtension.listAttachmentsForProject`，L838-859）且 `ragFeatureAvailable`（回退 `useAttachments.enabled`，L861-863）；
3. MCP 工具：`enableSmartToolRouting` 时经 `mcpOrchestrator.getRelevantTools(lastUserMessage, …)`（L898-933）；**路由结果冻结**（`frozenRoutedTools` + 签名，防每次请求工具集变化破坏提示缓存，L730-735、L908-933）；同名校验（L943-948）；
4. 轻量路由模型 `resolveRouterModel`（L979-1024，`isRouterModelSelectable` 校验）；
5. 全部转 `jsonSchema(normalizeToolInputSchema(...))`（L876-881、L950-956）；
6. 禁用过滤：全局 `useToolAvailable.getState().getDisabledTools()`，复合 key `${serverName}::${toolName}`（L823-828）。

`use-chat.ts`（L111-117）：MCP/RAG 工具名变化时自动 `refreshTools()`，保证 MCP server 启停后工具集及时更新。

### 2.2 schema 规整

`normalizeToolInputSchemaValue`（custom-chat-transport.ts:213-290，注释称与 Rust 对齐）：

- `{properties:{foo:"string"}}` 展开为 `{type:"string"}`（L206-211）；
- `type:'object'` 无 `properties` 补 `{}`（L262-264）；
- 仅 description 补 `type:'string'`（L266-268）；
- 删 `date/time/date-time` format 与含 `\d\w\s` 的 pattern（GBNF 编译失败会静默禁用工具 JSON，L270-287）。

## 4. 权限与审批

### 3.1 四级审批

`web-app/src/hooks/useToolApproval.ts`（92 行，zustand + persist）：

- `approvedTools`：threadId → 工具名数组（会话级信任）；
- `approvedServers`：全局信任的 MCP server；
- `approvedToolsGlobal`：全局信任的工具（无 server 归属时用）；
- `allowAllMCPPermissions`：放行所有 MCP 权限。

`isToolApproved`（L62-73）优先级：全局工具 > 全局 server > thread 级。持久化在 localStorage 键 `tool-approval`，`skipHydration: true`。

### 3.2 请求与执行时机

- `useToolApprovalRequests.ts`：待审批请求按 `toolCallId` 收集；
- `MessageItem` 在 `awaitingApproval` 时挂起（L142-149、L519-526），审批结果由 SDK `addToolOutput` 送回；
- 文档嵌入后自动 `approveToolForThread`（`$threadId.tsx` L1024-1029）；
- 工具执行留在 onFinish 循环，使工具结果落在已完成的 assistant 消息上（`$threadId.tsx` L172-173、L659-663）。

### 3.3 设置 UI

- `routes/settings/mcp-servers.tsx`：`toolCallTimeoutSeconds`、智能路由开关、路由模型选择；
- `routes/settings/web-search.tsx`：provider 与 key。

## 5. 工具渲染与执行链路

### 4.1 执行链

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

`TauriMCPService`（`web-app/src/services/mcp/tauri.ts`）：`getTools()`/`getToolsForServers`/`callTool`/`callToolWithCancellation`（带 cancellationToken）/`cancelToolCall`/`activateMCPServer`/`deactivateMCPServer`；`getMCPConfig` 解析 MCP 配置 JSON（含 legacy 顶层 server 兼容，L46-63）。

### 4.2 渲染

- `ToolCallCard` → `components/ai-elements/tool.tsx`（`ToolHeader/Input/Output`，600 字符折叠阈值）；
- `tool-runtime.tsx`：`ToolElapsed` 计时、`ToolProgressRow`；
- `WebToolWidget.tsx`（search/address 栏）、`RagToolWidget.tsx`（documents 变体：查询实时填充 + 引用卡片 + Shimmer + 范围标签）；
- 描述：`lib/toolPresentation.ts` `describeNativeToolCall`（search/address/documents 三变体）；
- 引用：`lib/citation-parser.ts`、`lib/grounding.ts`（句子切分 + 余弦相似度）；
- `ChainOfThoughtGroup` 承载 reasoning + tool parts 的统一展示。

## 6. 边界与未验证事项

- `DropdownToolsAvailable.tsx` 显式过滤 `server === 'Jan Browser MCP'`——浏览器 MCP 工具在开关列表中不可见（事实）；它是否仍可被模型调用需运行时验证。
- 未发现“JSON schema 自动生成参数表单”的机制；工具参数无 UI 表单，由模型直接填 JSON。
- `experimental_repairToolCall` 只修 Windows 路径反斜杠导致的 JSON 转义失败（`InvalidToolInputError` 判定，L1384）；其他工具输入错误由 SDK 默认路径处理。
- 智能路由冻结后，同一签名下的工具集固定；用户消息变化但签名命中缓存时工具集不更新（设计如此，行为需运行时确认）。
- RAG 检索内部（向量库调用、`rag-internal` server 的真实端点）未逐项核对。
- 未运行项目测试或构建；记录来自静态源码。

## 7. 关键源码索引

- 工具加载与注入：`web-app/src/lib/custom-chat-transport.ts:815-977`
- schema 规整：`custom-chat-transport.ts:213-290`
- 禁用过滤：`custom-chat-transport.ts:823-828`
- 工具执行入口：`custom-chat-transport.ts:1369-1389`
- 审批 store：`web-app/src/hooks/useToolApproval.ts`
- 审批请求收集：`web-app/src/hooks/useToolApprovalRequests.ts`
- 禁用列表 store：`web-app/src/hooks/useToolAvailable.ts`
- MCP 服务：`web-app/src/services/mcp/tauri.ts`、`default.ts`
- MCP 进程管理：`src-tauri/src/core/mcp/helpers.rs`（run_mcp_commands:62-161、start_mcp_server:318-395、传输分区:397-819、稳定性检查:720-745）
- MCP 命令：`src-tauri/src/core/mcp/commands.rs`
- Web 搜索：`web-app/src/lib/webSearchTool.ts`、`web-app/src/hooks/useWebSearchConfig.ts`
- RAG 工具定义：`extensions/rag-extension/src/tools.ts`、`extensions/rag-extension/src/index.ts:110-127`
- 工具渲染：`web-app/src/components/ai-elements/tool.tsx`、`tool-runtime.tsx`、`WebToolWidget.tsx`、`RagToolWidget.tsx`
- 工具描述与引用：`web-app/src/lib/toolPresentation.ts`、`citation-parser.ts`、`grounding.ts`
- 设置 UI：`web-app/src/routes/settings/mcp-servers.tsx`、`web-app/src/routes/settings/web-search.tsx`
