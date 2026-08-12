# Cherry Studio Agent 工具调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：只读源码梳理（未修改被调查仓库任何文件）；未运行仓库测试/构建，结论均以静态阅读源码为准
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 存在两条彼此独立、但共享部分基础设施（MCP 运行时、命名规则、审批 UI）的 Agent 工具路径：

1. **普通聊天 MCP 路径**：`McpRuntimeService` 管理用户配置的 stdio/SSE/Streamable HTTP/OAuth/in-memory MCP server；工具经 `syncMcpToolsToRegistry` 注册进 AI SDK `ToolRegistry`，按 `scope.mcpToolIds` 过滤，`needsApproval`/`defer` 由 `disabledAutoApproveTools` 决定。
2. **Claude Code Agent 路径**：`src/shared/ai/claudecode/toolRegistry.ts` 是一份声明式注册表，定义每个 SDK 原生工具和 in-process MCP 工具（`cherry-tools` / `agent-memory` / `assistant` / `skills`）的 `exposure`（`user`/`internal`/`disabled`）。主进程的 `agentTools.ts` + `toolConditions.ts` + `toolRules.ts` 组合出 `disallowedTools`、`canUseTool`、以及一组 `PreToolUse` hook，注入到 `@anthropic-ai/claude-agent-sdk` 的 `query()`。

两条路径都最终落在 Electron **主进程**执行：MCP 子进程/HTTP client 由 `McpRuntimeService` 持有；Claude Code 的原生工具（Bash/Read/Write/...）由 SDK 自带的原生二进制执行，Cherry 只能通过 `disallowedTools`、`canUseTool`、`PreToolUse` hook 三层来限制/审批，不持有执行本身。

代码中已确认的关键机制事实：
- **审批模型（Claude Code 原生工具）**：`Bash` 等原生工具在 `default` 权限模式下每次调用都需逐次审批（`prompt`），且没有 "always allow" 持久化机制——`useToolApproval` 对非 MCP 工具不渲染 `autoApprove` 按钮（`useToolApproval.ts:136-146`）；一旦 `permissionMode` 为 `bypassPermissions`，或 `acceptEdits` 模式下命令首词命中 `mkdir/touch/mv/cp`，命令即可免审批直接执行，此时唯一过滤是 `dependencyIsolationHook`（拦截全局包安装）与 `rtkRewrite`（改写特定命令），无通用命令白名单或沙箱。
- **审批模型（in-memory MCP）**：`filesystem` 的 `write`/`edit`/`delete` 默认在 `disabledAutoApproveTools`（`builtinMcpServers.ts:96`），用户 "always allow"（`persistAutoApprove`）后会被从该列表移除、后续调用无提示写盘；两条路径的审批桥与 IPC 方法名共享，但主进程分发逻辑不同（Claude 侧命中内存 `toolApprovalRegistry` 快路径，MCP 侧落 DB 消息 parts）。
- **执行域**：所有工具最终落在 Electron 主进程；`browser` in-memory MCP 使用全局共享的 `persist:default` 分区（`browser/README.md:16`），任何调用该 server 的会话共享同一份 cookie/localStorage，且 `execute` 工具可在页面上下文执行任意 JS，默认无头（`showWindow:false`）。
- **路径校验边界**：`workspacePathHook` 越权检查只覆盖 `Edit/Glob/Grep/NotebookEdit/Read/Write` 六个结构化字段，`Bash` 命令文本中的路径不经过该检查（源码注释确认刻意为之）。
- **安全边界事实**：`assistant` MCP 只在本地 Cherry Assistant 会话注入（外部渠道会话不注入），`diagnose`（读本机日志/源码/配置）被刻意排除在自动批准之外；`ASSISTANT_AUTO_APPROVED_RUNTIME_NAMES` 的注释本身就是官方对"可读本机数据的工具与自动批准的网页抓取工具可能同会话出现"这一风险的设计依据。

## ASCII 调用链图

```text
┌───────────────── 普通聊天 MCP 路径 ─────────────────┐
用户配置的 MCP Server (stdio/SSE/streamableHttp/OAuth/inMemory)
  -> McpRuntimeService.getOrCreateClient() (主进程, 建 Client+Transport)
  -> McpCatalogService.listTools() (缓存)
  -> syncMcpToolsToRegistry() -> ToolRegistry (AI SDK Tool, namespace `mcp:<server>`)
  -> buildAgentParams (scope.mcpToolIds 过滤, defer: 'auto'|'never')
  -> AI SDK doStream tool-call
  -> createMcpTool().execute() -> McpRuntimeService.callToolByServer()
       (isMcpToolDisabledBySource 硬拒绝 -> getOrCreateClient -> client.callTool(timeout, AbortController))
  -> McpCallToolResponse -> mcpResultToTextSummary() 回注模型
  -> renderer ToolUIPart (`needsApproval` 由 isMcpToolForcePromptBySource 决定, 走 AI SDK 原生 approval-requested 状态)

┌───────────────── Claude Code Agent 路径 ─────────────────┐
CLAUDE_TOOL_REGISTRY (静态声明: exposure/dependsOn/mcpServer)
  -> resolveDisallowedTools(agent.disabledTools, ctx) -> disallowedTools[]  (硬块黑名单)
  -> createClaudeAgentToolPolicySnapshot() -> canUseTool / isDisabled (会话内热更新)
  -> buildClaudeCodeSessionSettings() -> Options{ permissionMode, allowedTools, disallowedTools,
        canUseTool, hooks:{PreToolUse:[interactive, headlessConfig, disabledTool,
        workspacePath, dependencyIsolation, rtkRewrite, steer]}, mcpServers:{ 用户MCP(sdk桥),
        cherry-tools, agent-memory, assistant? } }
  -> @anthropic-ai/claude-agent-sdk query()/startup() (原生二进制子进程, 内含 Bash/Read/Edit/...)
  -> SDKMessage 流 -> ClaudeCodeStreamAdapter -> CherryUIMessageChunk
  -> 工具调用需要审批时: canUseTool 返回 Promise, toolApprovalRegistry.register()
       -> approvalEmitter.emit({type:'tool-approval-request', approvalId, toolCallId})
       -> IPC 推给 renderer -> useToolApprovalBridge -> ipcApi 'ai.tool.respond_approval'
       -> AiService.respondToolApproval() -> AgentSessionRuntimeService.respondToolApproval()
       -> toolApprovalRegistry.dispatch() -> resolve(PermissionResult) -> canUseTool 返回值送回 SDK 子进程
  -> in-process MCP (cherry-tools/agent-memory/assistant/skills/用户MCP-sdk桥) 全部在主进程内以
     `type:'sdk'` McpServer 实例直接函数调用执行，不经过子进程/网络
```

## 1. 两条工具路径的分界

- 普通聊天：工具来源是 `mcpServerService` 中 `isActive` 的 MCP server，注册进程内共享的 `ToolRegistry`（`src/main/ai/tools/adapters/registry.ts`，未展开读取但被 `mcpTools.ts:11` 引用），按会话 `scope.mcpToolIds` 过滤后交给 AI SDK 的 provider 原生 tool-calling。曝光级别只有「MCP server 是否 active」+「工具是否在 `disabledTools`」两级，没有 `internal`/`disabled` 的静态分层概念。
- Claude Code Agent：工具来源是 `CLAUDE_TOOL_DEFS`（一份 TS 常量表）+ 该 Agent 绑定的 MCP server 列表（`agent.mcps`）。曝光级别 `user`/`internal`/`disabled` 在 `src/shared/ai/claudecode/toolRegistry.ts:27-42` 明确定义并有注释说明生效点：
  - `user`：出现在编辑对话框，用户可开关，写回 `agent.disabledTools`；
  - `internal`：始终启用、UI 隐藏（例如 `Task`/`AskUserQuestion`/`ToolSearch`）；
  - `disabled`：始终加入 SDK `disallowedTools` 硬黑名单（例如原生 `WebSearch`/`WebFetch`/`REPL`/`NotebookEdit`/`TodoWrite`/`CronCreate` 等），模型完全看不到、也调用不到。

依据：`../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:1-42`、`../../cherry-studio/src/main/ai/tools/adapters/claudeCode/toolConditions.ts:1-90`、`../../cherry-studio/src/main/ai/tools/adapters/aiSdk/mcp/mcpTools.ts:69-97`。

`exposure` 三态是这份注册表的核心机制：`enabled` 时工具按条件注入模型调用，`internal` 时始终启用但 UI 隐藏，`disabled` 时加入 SDK 硬黑名单。`internal` 工具（如 `Task`/`Agent`/`AskUserQuestion`/`SendMessage`/`TeamCreate` 等 agent-teams 工具）本身并非 SDK `ToolInputSchemas` 联合类型的正式成员，只是运行时按环境变量条件注入（见下）。

## 2. 工具定义与注册

### 2.1 SDK 原生工具

`CLAUDE_TOOL_DEFS`（`toolRegistry.ts:48-370`）逐条声明 `name`（运行时原生名，即写回 `disabledTools` 的 id）、`category`、`exposure`、`description`、可选 `dependsOn`、可选 `mcpServer`。值得注意的条目：

- `BashOutput` 依赖 `Bash`（`dependsOn: ['Bash']`），是渲染专用别名，真实 SDK 联合类型把它叫 `TaskOutput`。
- `Task`/`TaskOutput`/`TaskStop`/`TaskCreate`/`TaskGet`/`TaskUpdate`/`TaskList` 都是 `internal`，其中注释区分了「渲染专用别名」（`Task`）与真实 `Agent` 编排工具、以及一组任务调度类工具。
- `SendMessage`/`TeamCreate`/`TeamDelete`（agent-teams）**不是 SDK `ToolInputSchemas` 联合类型的成员**，仅在设置了 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 环境变量时由 runtime 注入（`settingsBuilder.ts:830` 无条件设置该变量为 `'1'`，即所有 Claude Code Agent 会话都启用了这一实验特性）。又无条件追加了 `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT=1`（`f3399d38e9`，`settingsBuilder.ts:834`），走 SDK 的简单系统提示模式。
- `EnterWorktree`/`ExitWorktree` 有运行时启用条件（见 §4）。
- `CronCreate`/`CronDelete`/`CronList`/`ScheduleWakeup`/`RemoteTrigger`/`Monitor`/`PushNotification` 全部 `disabled`——这些是 SDK 自带的原生调度/推送工具，Cherry 用自家 `mcp__cherry-tools__cron`/`…__notify` 取代。

依据：`../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:48-263`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:829-834`。

### 2.2 mcp__* 命名与 wire id 映射（双轨制）

MCP 工具 id 拆成两套（`40914ab5cd`）：

1. **legacy 名称型 id**：`buildFunctionCallToolName(serverName, toolName)` 生成 `mcp__{camelCase(server)}__{camelCase(tool)}`，上限 63 字符，超长时用服务器名 FNV-1a 哈希后缀替代被截断的尾部（`mcpToolName.ts:114-165`）。它现在只服务**持久化的 source-policy 规则**与 **Claude Code 适配器**；原 `isFunctionCallToolNameForServer` 已删除（`mcpToolName.ts:165-167` 起不再导出）。
2. **AI SDK catalog 身份 id**：主进程新增 `buildMcpToolWireId`（`src/main/ai/mcp/mcpToolId.ts:41-50`），以 `sha256(serverId + '\0' + toolName)` 的 20 位十六进制摘要结尾，`serverId` 参与哈希——非 ASCII 服务器/工具名（中文等）先经 `tiny-pinyin` 罗马化（`mcpToolId.ts:20-32`），无法罗马化的字符退化为摘要，彻底消除"两个不同 server 因长名截断/撞哈希生成同一 wire id"的碰撞面（原 §2.2 的"哈希碰撞 + 截断边界重合"风险对 catalog id 不再成立）。

两条路径共用 `toCamelCase`/`parseFunctionCallToolName` 的反向归属工具，但"普通聊天 MCP 的 catalog 注册"与"Claude Code 的 source-policy 匹配"各用一套 id 空间。

依据：`../../cherry-studio/src/shared/ai/tools/mcpToolName.ts:114-167`、`../../cherry-studio/src/main/ai/mcp/mcpToolId.ts:1-50`。

### 2.3 环境依赖导致的条件可用性

- `EnterWorktree`/`ExitWorktree`：`TOOL_ENABLE_PREDICATES` 检查 `cwd` 下是否存在 `.git`（`toolConditions.ts:34-37`），无 `.git` 时该工具即被计入 `disallowedTools`。
- Agent-teams 工具集：由 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 环境变量门控（见上）。
- `ENABLE_TOOL_SEARCH=auto`（`settingsBuilder.ts:583`）门控 `ToolSearch` 元工具是否出现，取决于工具总数是否超过 SDK 内部阈值——这是 SDK 自身行为，Cherry 只是把开关设为 `'auto'`。
- `assistant` MCP server 仅在 `isAssistant && linkedChannelSnapshot === null`（本地 Cherry Assistant 会话，非外部渠道）时注入（`settingsBuilder.ts:283`、`1186-1193`）。
- `skills` 白名单按 `agent.id` 启用的 managed skills + 工作区本地 `.claude/skills` 目录名动态计算（`buildSkillWhitelist`，`settingsBuilder.ts:672-680`）。

依据：`../../cherry-studio/src/main/ai/tools/adapters/claudeCode/toolConditions.ts:21-37`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:283,583-584,672-680`。

## 3. 工具发现与注入

### 3.1 普通聊天 MCP

`syncMcpToolsToRegistry()`（`mcpTools.ts:114-159`）在每次相关会话构建工具集前对齐 `ToolRegistry`：列出 `isActive` 的 server → 逐个 `McpCatalogService.listTools(server.id, {includeDisabled:false})` → 注册/替换/剔除。剔除逻辑区分「server 被停用」与「本次刷新范围内工具消失」两种情况，避免瞬时连接失败导致误删已知工具集（`mcpTools.ts:148-158` 的 `refreshedNamespaces` 门控）。

### 3.2 Claude Code Agent

注入时机在 `buildClaudeCodeSessionSettings()`（`settingsBuilder.ts:258-404`）内，按固定顺序构建：cwd → env → plugins → **tool permissions**（`canUseTool`/`hooks`/`disallowedTools`/`toolPolicySnapshot`）→ systemPrompt → **mcpServers**（用户 MCP 桥 + cherry-tools + agent-memory + assistant?）→ mcpToolMetadata → allowedTools 微调 → skills 白名单。会话内热更新（无需重连）通过 `toolPolicySnapshot.update(agent)` 与 `PreToolUse` hook 联动实现——`disabledToolHook` 每次调用都重新查询 `getToolPolicySnapshot(session.id).isDisabled(toolName)`，因此中途禁用某工具会立即在下一次调用生效，不需要重建子进程连接（`settingsBuilder.ts:896-916`）。

被 hard-disable 的原生工具及替代路径：
- `WebSearch`/`WebFetch`（disabled）→ `mcp__cherry-tools__web_search` / `…__web_fetch`；
- `TodoWrite`（disabled）→ 无直接替代（工具注册表未见等价物，可能依赖模型自行维护待办文本）；
- `REPL`/`NotebookEdit`（disabled）→ 无替代，纯移除；
- `CronCreate`/`CronList`/`CronDelete`/`ScheduleWakeup`/`RemoteTrigger`/`Monitor`/`PushNotification`（全部 disabled）→ `mcp__cherry-tools__cron` / `…__notify`。

新增的 cherry-tools 工具（`f1e793da79`）：`mcp__cherry-tools__to_markdown`（`CherryToMarkdown`，exposure `user`，`toolRegistry.ts:317-327`）——把普通文本工具读不了的本地文档（pdf/office/epub/csv 等）转成 Markdown 给模型读；它单独有开关（读取工作区外本地文件，禁用 Read 不能连带关掉这条路径）。

依据：`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:258-404`、`../../cherry-studio/src/main/ai/tools/adapters/aiSdk/mcp/mcpTools.ts:114-159`。

## 4. 模型调用表示与解析

普通聊天走 AI SDK 原生 `tool-call`/`tool-result` part（provider 层负责 function-calling 组装），Cherry 只在 `createMcpTool()` 里包一层 `execute`/`toModelOutput`（`mcpTools.ts:29-66`）。

Claude Code Agent 走 `@anthropic-ai/claude-agent-sdk` 的 `SDKMessage` 流（`stream_event`/`system`/`result` 等 subtype），由 `ClaudeCodeStreamAdapter`（`streamAdapter.ts`）解析 `BetaToolUseBlock`/`BetaServerToolUseBlock`/`BetaMCPToolUseBlock` 并转成 Cherry 的 `CherryUIMessageChunk`。关键点：
- 工具名解析走 `parseFunctionCallToolName`（识别 `mcp__server__tool` 格式）来判定 MCP 来源展示信息；
- `MAX_TOOL_INPUT_SIZE = 1_048_576`（1MB）、`MAX_TOOL_INPUT_WARN = 102_400` 是流式 JSON 累积器的保护阈值（`streamAdapter.ts:45-47`），超限行为未在此次阅读中追踪到截断/报错的具体分支，**标记为待进一步验证**。
- `deniedToolUseIds`：CLI 自动拒绝（`system/permission_denied`）的调用被标记为 `denied` 而非 `failed`，回注模型时状态语义不同。

依据：`../../cherry-studio/src/main/ai/runtime/claudeCode/streamAdapter.ts:41-116`、`../../cherry-studio/src/shared/ai/tools/mcpToolName.ts:152-163`。

## 5. 参数校验与规范化

- MCP 通用调用入口 `McpRuntimeService.callToolByServer()` 对字符串型 `args` 尝试 `JSON.parse`，失败即 fail-fast 抛错而非把原始字符串转发给下游 server（`McpRuntimeService.ts:1082-1094`）——避免服务端收到裸字符串产生歧义错误。IPC 层的 `McpCallToolPayloadSchema`（Zod）只校验外层壳字段（`serverId`/`name`/`args`/`callId`），内层 `args` 本体被视为“协议信任”不做 schema 校验（注释在 `McpRuntimeService.ts:66-68` 明确说明这一取舍）。
- in-memory `filesystem` MCP 的路径参数在 `validatePath()`（`filesystem/types.ts:84-96`）中做真实路径解析（`resolveRealOrNearestExistingPath` 穿透 symlink）+ `isPathWithinRoot` 双重校验，防止 `../` 穿越和 symlink 逃逸；但 `baseDir` 本身来自用户可配置的 `args[0]` 或 `WORKSPACE_ROOT` 环境变量（`resolveFilesystemBaseDir`，`filesystem/config.ts:1-8`），用户可以把它配置成任意目录（包括 `~` 或根目录），届时“越权”检查形同虚设——**这是配置层问题而非代码 bug**。
- Claude Code 侧的 Bash 参数不做结构化校验：`command` 字段是自由文本，Cherry 只挂了两个 `PreToolUse` hook 做**语义级**拦截（`detectGlobalInstall` 正则匹配全局安装命令；`rtkRewrite` 改写特定命令），没有参数白名单或 shell-escape 校验。文件类工具（`Read`/`Write`/`Edit`/`Glob`/`Grep`/`NotebookEdit`）的路径字段由 `workspacePathHook`（`settingsBuilder.ts:923-950`）统一做“在工作区或 agent 数据目录内”校验，使用与普通聊天 filesystem server 相同风格的 realpath 解析（`isPathWithinAllowedRoots`，`settingsBuilder.ts:497-514`）。
- Agent memory MCP 对文件操作加了 `lstat` + `isSymbolicLink()` 双重防御，拒绝对 symlink 文件写入/追加（`agentMemory.ts:16-54,195-204`），是本次阅读中路径安全实现最严格的一处。

依据：`../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:66-68,1082-1098`、`../../cherry-studio/src/main/ai/mcp/servers/filesystem/types.ts:47-96`、`../../cherry-studio/src/main/ai/mcp/servers/filesystem/config.ts:1-8`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:497-514,923-950`、`../../cherry-studio/src/main/ai/mcp/servers/agentMemory.ts:16-54,195-204`。

## 6. 编排循环

### 6.1 普通聊天

`stopWhen`/步数上限来自 AI SDK：`composeStopWhen()` 的 SDK 兜底仍是 `stepCountIs(20)`（`buildAgentParams.ts:650`），但默认 assistant 设置 `maxToolCalls` 已从 20 提到 100（`c992af0222`）（`assistant.ts:108`，`DEFAULT_ASSISTANT_SETTINGS.maxToolCalls`；合法范围 1-1000，`assistant.ts:31-35`）——没有显式自定义时，普通聊天默认工具轮次上限现在是 100 轮而非 20 轮，`ToolLoopTerminalError` 的过早终止问题被缓解。这是**模型侧的 tool-call 轮数上限**，与 Claude Code 的 `max_turns` 是两套独立机制。

### 6.2 Claude Code Agent

- `max_turns` 直接来自 `agent.configuration.max_turns`（`settingsBuilder.ts:385`），传给 SDK `Options.maxTurns`，超限行为由 SDK 自身处理（`streamAdapter.ts:245` 出现 `case 'error_max_turns'` 分支，说明适配层确实消费了该终止原因，但本次未继续追踪其向渲染层的具体呈现，**标记为待验证**）。
- 并发：`McpRuntimeService.activeToolCalls` 改为 `Map<registrationKey, Set<AbortController>>`（`McpRuntimeService.ts:276`，同一 callId 可挂多个 controller），仍按调用隔离支持多个 MCP 调用并发在跑；（`191c372deb`，`mcpAbort.ts`）流中止信号会**传播进在途 MCP 调用**——stream abort 时对应的在途调用 controller 一并 abort，不再只等超时；Claude Code 侧的并发受 SDK 子进程自身模型控制，Cherry 未额外施加并发上限。
- 超时：MCP 通用调用默认 60 秒（`server.timeout ? ... : 60000`），可 per-server 覆盖，`server.longRunning` 时改用 `resetTimeoutOnProgress` + 10 分钟 `maxTotalTimeout`（`McpRuntimeService.ts:1271-1275`）。MCP `initialize`（连接建立）走独立的 180 秒地板值 `MCP_CONNECT_TIMEOUT_FLOOR_MS`（`McpRuntimeService.ts:155`）。
- `AbortController` 取消语义：`abortTool(callId)` 主动 abort 对应 controller；`onStop()` 生命周期钩子会 `abortActiveToolCalls()` 批量取消所有在途调用（`McpRuntimeService.ts:220-227,888-894,1316-1327`）。Claude Code 侧每个 `ClaudeCodeRuntimeConnection` 持有自己的 `abortController`，`close()` 时 `abort('agent-runtime-closed')`（`ClaudeCodeRuntimeDriver.ts:148,341-348`）；`toolApprovalRegistry` 同样监听该 signal 的 `abort` 事件把挂起审批自动 `deny`（`ToolApprovalRegistry.ts:42-52`）。
- 错误回传：MCP 调用异常直接 `throw`，由上层 AI SDK `execute` 包装转成 `output-error` part；Claude Code 侧异常（包括流被 CLI 中途异常终止）由 `handleTruncationError()` 尝试“打捞”已缓冲文本为 `truncated` finish，打捞失败才作为 `error` 事件上抛（`ClaudeCodeRuntimeDriver.ts:455-467`）。

依据：`../../cherry-studio/src/main/ai/runtime/aiSdk/params/buildAgentParams.ts:417-435`、`../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:92,203-227,688-690,888-894,1067-1138,1316-1327`、`../../cherry-studio/src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:145-158,341-348,455-478`、`../../cherry-studio/src/main/ai/runtime/claudeCode/ToolApprovalRegistry.ts:42-83`、`../../cherry-studio/src/main/ai/runtime/claudeCode/streamAdapter.ts:245`。

## 7. 审批与策略

### 7.1 普通聊天 MCP：`disabledTools` / `disabledAutoApproveTools`

`matchesMcpSourceToolRule(value, server, tool)`（`mcpSourcePolicy.ts:22-29`）同时支持四种写法匹配同一条规则：裸工具名（`tool.name`）、工具内部 id（`tool.id`）、完整 wire id（`mcp__server__tool`）、server 级 wildcard（`mcp__server__*`）。`isMcpToolDisabledBySource` 优先级高于 `isMcpToolForcePromptBySource`（`resolveMcpSourceToolAccess`，`mcpSourcePolicy.ts:39-47`：先判 disabled 直接 `{enabled:false}`，否则才看是否需要强制 prompt）。单测 `mcpSourcePolicy.test.ts:32-42` 显式验证了这一优先级。

这套匹配语义在 **两条路径都复用**：普通聊天的 `isMcpToolForcePromptBySource` 直接驱动 AI SDK 的 `needsApproval`；Claude Code 侧的 `resolveMcpSourceToolAccess`（`agentTools.ts:63`）把结果映射成 `sourceApproval`，再在 `toolRules.ts:68-73` 的 `sourceDecision()` 中被赋予**最高优先级**——即便 `permissionMode: 'bypassPermissions'`，只要 MCP server 自身配置了 `disabledAutoApproveTools` 命中，仍然强制 `prompt`（`resolveClaudeToolAccess`，`toolRules.ts:75-95`：`sourceDecision` 检查在 `bypassPermissions` 判断之前）。

### 7.2 Claude Code 的 permission mode 优先级实现

`resolveClaudeToolAccess()`（`toolRules.ts:75-95`）按顺序判定：
1. `sourceDecision`（MCP server 级强制 prompt）→ 最高优先级，任何 permission mode 都不能覆盖；
2. `permissionMode === 'bypassPermissions'` → 该工具本身 `auto`（除非第 1 步已拦截）；
3. `permissionMode === 'acceptEdits'` 且工具属于 `ACCEPT_EDITS_TOOLS`（`Edit`/`MultiEdit`/`NotebookEdit`/`Write`）→ `auto`；
4. `DEFAULT_SAFE_TOOLS`（`Read`/`Glob`/`Grep`/`NotebookRead`/`Task`/`TodoWrite`）→ 任何模式下都 `auto`；
5. 否则 `prompt`。

`resolveClaudeToolInvocationAccess()`（`toolRules.ts:108-126`）在上述基础上额外处理 `acceptEdits` 模式下 `Bash` 命令首词命中 `ACCEPT_EDITS_BASH_COMMANDS = {mkdir, touch, mv, cp}` 时也降级为 `auto`——这是**唯一**允许 `acceptEdits` 模式免审批执行 `Bash` 的路径，命令解析仅取空格分隔的首个 token，对 `; rm -rf /` 这种拼接命令不做进一步解析（因为只看首词）。

但要注意：`canUseTool` 只是 SDK 侧的**一层**门控，`disabledToolHook`/`workspacePathHook`/`interactiveToolPermissionHook` 等作为 `PreToolUse` hook 在**所有** permission mode 下都会触发（注释在 `settingsBuilder.ts:896-901` 明确说明这是因为 SDK 在 `bypassPermissions`/`acceptEdits`/默认安全工具时会跳过 `canUseTool`，所以硬约束必须搬到 hook 层才能生效）。这是本仓库审批体系里唯一贯穿所有 permission mode 的强制层。

依据：`../../cherry-studio/src/shared/ai/tools/mcpSourcePolicy.ts:22-47`、`../../cherry-studio/src/shared/ai/tools/__tests__/mcpSourcePolicy.test.ts:32-42`、`../../cherry-studio/src/shared/ai/claudecode/toolRules.ts:30-126`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:896-950`。

### 7.3 审批桥的 IPC 往返与持久化

普通聊天 MCP 审批复用 AI SDK 原生 approval 状态机（`approval-requested`/`approval-responded`），持久化落在消息 `parts`（DB）里；Claude Code Agent 审批走独立的 `toolApprovalRegistry`（内存态 `Map<approvalId, PendingApproval>`）+ `AiService.respondToolApproval()`（`AiService.ts:241-354`）。两条路径共享同一个 renderer 侧 `useToolApprovalBridge` 和 IPC 方法名 `ai.tool.respond_approval`，但主进程分发逻辑不同：

1. 先尝试 `AgentSessionRuntimeService.respondToolApproval()`（Claude-Agent 快路径：命中内存中的 `toolApprovalRegistry` 直接 `resolve()` 唤醒 `canUseTool` 的 Promise，不落库）；
2. 未命中则走 MCP 路径：`messageService.applyToolApprovalDecisions()` 把决定写入 DB 消息 parts（事务化，防止多工具同轮并发审批互相覆盖），全部审批决定完成后才 `AiStreamManager.dispatch({trigger:'continue-conversation'})` 恢复流。

（`1f99a7d3c0`）同一回复请求多个工具审批时，响应一个请求会把审批指针推进到下一个挂起请求——不再因响应当前可见请求而隐藏其余仍在等待的审批 UI。

`hasLiveStream`/`hasLiveTurnStream` 前置检查防止“审批到达但流已结束/仍在跑”两种竞态场景导致审批被静默丢弃（`AiService.ts:271-280` 附近；`settingsBuilder.ts` 的 `OUT_OF_TURN_APPROVAL_DENIAL` 则处理 Claude 侧分离 turn 场景，直接 deny 而非挂起）。

### 7.4 "always allow" 的写回位置

普通聊天 MCP：`useToolApproval.persistAutoApprove()`（`useToolApproval.ts:108-120`）从 server 的 `disabledAutoApproveTools` 数组中移除该工具名，PATCH 回 `mcpServerService`（renderer 触发，主进程持久化到 DB）。**Claude Code Agent 无对应持久化机制**——`useToolApproval.ts:136-146` 的注释明确写道：非 MCP（Claude-Agent）工具没有这类 store，`autoApprove` action 只在有 `mcpTool` 描述符时才暴露，否则会渲染出“一次性生效但不持久化”的死按钮，因此代码选择直接不渲染该按钮。这意味着 Claude Code 原生工具（Bash/Write/...）的每一次 `prompt` 级审批都**只能逐次点击**，没有"记住我的选择"能力（除非用户在 Agent 设置里手动把该工具切到 `disabled`/加入白名单或整体切换 `permission_mode`）。

依据：`../../cherry-studio/src/main/ai/AiService.ts:241-354`、`../../cherry-studio/src/renderer/hooks/useToolApprovalBridge.ts:1-50`、`../../cherry-studio/src/renderer/components/chat/messages/tools/hooks/useToolApproval.ts:55-146`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:775-783`。

## 8. 执行位置与隔离

| 执行体 | 进程/位置 | 权限边界 |
| --- | --- | --- |
| stdio MCP server（用户配置） | 主进程 `child_process`（`StdioClientTransport`） | 与 Cherry Studio 主进程同等宿主权限；env 继承登录 shell + `server.env` 覆盖 |
| SSE / Streamable HTTP MCP | 主进程内 `net.fetch`（Electron net 模块） | 受目标 URL 权限约束，OAuth token 落盘于 `feature.mcp.oauth/<md5(baseUrl)>_oauth.json` |
| in-memory MCP（memory/fetch/filesystem/python/browser/...） | 主进程内，`InMemoryTransport.createLinkedPair()`，无子进程 | 与主进程同权限；`filesystem` 靠 `baseDir` 应用层校验，无 OS sandbox；`python` 靠 Pyodide（Wasm）隔离；`browser` 靠 Electron `BrowserWindow`/CDP 隔离 |
| Claude Code 原生工具（Bash/Read/Edit/...） | SDK 原生二进制子进程（`pathToClaudeCodeExecutable`，平台专属包如 `@anthropic-ai/claude-agent-sdk-win32-x64`） | 与用户账户同权限；`cwd` 只是默认工作目录，不是隔离边界；`ELECTRON_RUN_AS_NODE=1`/`ELECTRON_NO_ATTACH_CONSOLE=1` 表明该子进程实际是复用 Electron 的 Node 运行时启动，而非独立打包的 Node |
| cherry-tools / agent-memory / assistant / skills（in-process MCP，Claude Code 专用） | 主进程内，`type:'sdk'` 直接函数调用（`createSdkMcpServerInstance`/各 Server 类），无 IPC、无子进程 | 与主进程同权限；`assistant.diagnose` 可读日志/源码/配置（显式黑名单敏感文件，见下）；`agent-memory` 限定在 `agentDataPath/memory/` 目录内并做 symlink 拒绝 |

### Windows 平台差异
- Bash 工具在 Windows 上依赖 Git Bash（`autoDiscoverGitBash()`/`findGitBash()`，`commandResolver.ts:384-476`），通过 `git.exe` 路径反推 `bash.exe` 位置，支持 Standard Git / Portable Git / MSYS2 三种布局；找不到则退回 `CLAUDE_CODE_GIT_BASH_PATH` 环境变量或失败。这意味着 Windows 上的 Bash 能力**依赖用户机器是否装了 Git for Windows**，行为与 macOS/Linux 原生 shell 不同。
- `npx`/`uvx`/`uv` 命令解析有“系统优先，Bundled 兜底”逻辑（`McpRuntimeService.ts:503-587`），Windows 下额外处理 `bun` 不支持代理的已知问题（`removeEnvProxy`，`McpRuntimeService.ts:591-594`）。
- filesystem in-memory server 的 `normalizeForComparison()` 在 Windows 上做大小写不敏感比较（`isWin ? normalizedPath.toLowerCase() : ...`，`filesystem/types.ts:44-46`），这是路径穿越检查里唯一区分平台的分支。

### in-memory server 实际访问范围
- **filesystem**：范围 = `resolveFilesystemBaseDir(args, envs)` 返回值，默认回退到 `application.getPath('feature.mcp.workspace')`（应用私有工作区），用户若显式配置 `args[0]` 或 `WORKSPACE_ROOT` 可扩大到任意目录（见 §5）。
- **python**：`PythonServer`（主进程 in-memory MCP）本身不执行代码，而是通过 IPC 把脚本转发给 `PythonService`（主进程），后者再通过 IPC 把请求转给 **renderer 进程里的一个 Web Worker**（`PyodideService.ts:34-57`，`new WorkerModule.default()`），由该 Worker 内的 Pyodide（Wasm）实际运行 Python。也就是说 `python_execute` 这一个工具调用要跨越「Claude Code/MCP 调用方 → 主进程 PythonServer → 主进程 PythonService → IPC → renderer PyodideService → Web Worker → Pyodide」六层，执行沙箱边界落在 Wasm + Web Worker，而不是主进程本身——这与其余 in-memory MCP server（memory/fetch/filesystem/browser 均在主进程直接执行）架构不同，是本次阅读中发现的一处值得注意的架构差异。Pyodide 默认无法访问真实文件系统/网络（除非显式桥接），本次未继续深挖 Worker 侧是否暴露了任何 postMessage 桥接能力回主进程或 Node API，**标记为待验证**。
- **browser**：`persist:default` 是**全局共享分区**（README 自述），意味着同一台机器上所有触发过 browser MCP 的会话/工具调用共享同一份登录态数据；`execute` 工具可执行任意 JS，且默认 `showWindow:false`（无头），用户不会看到页面在做什么。

依据：`../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:392-436,470-630`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:408-429,580-587`、`../../cherry-studio/src/main/utils/commandResolver.ts:384-476`、`../../cherry-studio/src/main/ai/mcp/servers/filesystem/types.ts:44-46`、`../../cherry-studio/src/main/ai/mcp/servers/filesystem/config.ts:1-8`、`../../cherry-studio/src/main/ai/mcp/servers/browser/README.md:16`、`../../cherry-studio/src/main/ai/mcp/servers/python.ts:82-117`。

## 9. 结果处理与回注

- **格式**：MCP 结果统一为 `McpCallToolResponse.content[]`（`text`/`image`/`audio`/`resource`），`mcpResultToTextSummary()` 把多模态内容压成模型可读文本（图片/音频替换为 `[Image: ...]` 占位符，二进制 resource 同理），保证图片本身不会被塞进模型上下文占用 token（`toolResponse.ts:19-54`，注意：这是**普通聊天 MCP 专用**的摘要函数；Claude Code 侧的 in-process MCP 走 `cherryBuiltinTools.ts:177-188` 自己的 `toMcpResult`，图像生成结果通过 `text+images` 类型让 base64 图像随文本一起进入 `content[]`，模型可以"看到"图片本身）。
- **截断**：渲染层 `truncateOutput()` 默认 `MAX_OUTPUT_LENGTH = 50000` 字符，超限尝试在最近的换行符处截断（若换行位置在 80% 阈值以内），否则硬截断（`truncateOutput.ts:1,51-72`）。这是**渲染层截断**（仅影响 UI 展示），不影响真正回注给模型的完整内容长度——模型侧的长度约束落在 `streamAdapter.ts` 的 `MAX_TOOL_INPUT_SIZE`（1MB，仅约束工具**输入** JSON 累积器，非输出）。**未在本次阅读中找到工具输出侧、真正影响模型上下文 token 的显式截断逻辑**——标记为待进一步验证。
- **多模态**：`hasMultimodalContent()` 判断结果含图片/音频/二进制 resource，供渲染层决定是否走图片查看器等专用 UI（`toolResponse.ts:6-13`）。
- **拒绝/超时/取消的结果形态**：
  - MCP 侧：`disabled` 工具调用直接 `throw new Error('MCP tool is disabled: ...')`（`McpRuntimeService.ts:1097`），转成 AI SDK `output-error`；
  - Claude Code 侧：`canUseTool` 返回 `{behavior:'deny', message}` 时，SDK 层面产生的是权限拒绝（不是工具执行错误），流适配器用 `deniedToolUseIds` 单独跟踪，区别于 `output-error`（真正执行失败）；
  - 取消：`AbortController.signal.aborted` 检查贯穿 `canUseTool`（`settingsBuilder.ts:744-746`）与 `toolApprovalRegistry.register()`（`ToolApprovalRegistry.ts:42-45`，若 signal 已 abort 则立即 `deny`）;
  - 会话/流被打断打捞：`handleTruncationError()` 尝试把已产生的部分文本保留为 `truncated` finish reason，而非整体丢弃（`ClaudeCodeRuntimeDriver.ts:455-467`，具体判定逻辑在 `streamAdapter.ts` 的 `isClaudeCodeTruncationError`，本次未展开全读，**标记为待验证**其触发条件的完整性）。

依据：`../../cherry-studio/src/renderer/components/chat/messages/tools/toolResponse.ts:1-54`、`../../cherry-studio/src/main/ai/mcp/servers/cherryBuiltinTools.ts:73-79,148-188`、`../../cherry-studio/src/renderer/components/chat/messages/tools/shared/truncateOutput.ts:1-72`、`../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:1097`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:744-746`、`../../cherry-studio/src/main/ai/runtime/claudeCode/ToolApprovalRegistry.ts:42-45`、`../../cherry-studio/src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:455-467`。

## 10. 内建工具完整清单

### 10.1 Claude Code Agent Registry（`CLAUDE_TOOL_DEFS`）

| 工具名（runtime name） | 曝光级别 | 用途 | 执行位置 | 默认是否需审批 | 风险点 |
| --- | --- | --- | --- | --- | --- |
| `Bash` | user | 执行 shell 命令 | SDK 原生子进程 | 是（`default`）；`bypassPermissions`/`acceptEdits`(限 mkdir/touch/mv/cp) 下自动 | 无通用命令沙箱；仅两个语义 hook 拦截全局安装/改写特定命令 |
| `BashOutput` | internal | 读取后台 shell 输出（依赖 Bash） | 同上 | 跟随 Bash | 依赖 Bash 是否禁用 |
| `REPL` | disabled | 持久 REPL 会话 | — | — | 硬禁用，模型不可见 |
| `Read` | user | 读文件 | SDK 原生子进程 | 否（DEFAULT_SAFE_TOOLS） | 路径越权靠 `workspacePathHook` 兜底为 `ask` |
| `Edit`/`Write` | user | 改/写文件 | 同上 | 是；`acceptEdits`/`bypassPermissions` 下自动 | 覆盖写无内容 diff 校验；路径越权同上 |
| `NotebookEdit` | disabled | 改 Jupyter notebook | — | — | 硬禁用 |
| `Glob`/`Grep` | user | 文件模式匹配/内容搜索 | 同上 | 否 | 路径越权同上（Grep/Glob 省略 path 时不校验） |
| `Agent`/`Task` | internal | 运行子 Agent 处理复杂任务 | SDK 原生子进程内编排 | 否 | 子 Agent 内部权限与父 Agent 一致（见 §12） |
| `TaskOutput`/`TaskStop`/`TaskCreate`/`TaskGet`/`TaskUpdate`/`TaskList` | internal | 任务调度/查询/终止 | 同上 | 否 | — |
| `TodoWrite` | disabled | 结构化待办列表 | — | — | 硬禁用，无替代 |
| `ExitPlanMode`/`EnterPlanMode` | internal | 进入/退出 Plan 模式 | 同上 | 交互类工具在无人值守（headless）会话中被拒绝 | headless 会话下需 `interactiveToolPermissionHook` 兜底拒绝 |
| `EnterWorktree`/`ExitWorktree` | internal，条件门控（需 `.git`） | 切换/退出 git worktree | 同上 | headless 下 `EnterWorktree` 被拒绝 | 无 `.git` 时被硬禁用 |
| `AskUserQuestion` | internal | 向用户提结构化问题 | 同上 | 始终走 `ask`（即使 `bypassPermissions`） | 是唯一显式排除在 `bypassPermissions` 自动放行之外的工具（`settingsBuilder.ts:771`） |
| `ToolSearch` | internal，`ENABLE_TOOL_SEARCH=auto` 门控 | 按名搜索可用工具（元工具） | 同上 | 否 | — |
| `ListMcpResources`/`ReadMcpResource` | internal | 列出/读取已连接 MCP 的资源 | 同上 | 否 | 可读取任意已连接 MCP server 暴露的 resource |
| `Workflow` | user | 编排多步 workflow/子 Agent | 同上 | 未明确单列（走默认工具判定） | — |
| `CronCreate`/`CronDelete`/`CronList`/`ScheduleWakeup`/`RemoteTrigger`/`Monitor`/`PushNotification` | disabled | SDK 原生调度/监控/推送 | — | — | 硬禁用，用 `mcp__cherry-tools__cron`/`…__notify` 取代 |
| `SendMessage`/`TeamCreate`/`TeamDelete` | internal，`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 门控（Cherry 无条件开启） | agent-teams 多 Agent 协作 | SDK 原生子进程 | 未展开验证 | 实验特性默认全量开启，行为未在本次阅读中深挖 |
| `WebSearch`/`WebFetch` | disabled | 原生网页搜索/抓取 | — | — | 硬禁用，用 `mcp__cherry-tools__web_search`/`…__web_fetch` 取代 |
| `mcp__cherry-tools__web_search` | user | 网页搜索（走用户配置的 WebSearchService） | 主进程 in-process MCP | 否（自动批准列表） | 结果内容未经净化直接进入模型上下文（下游 prompt injection 载体） |
| `mcp__cherry-tools__web_fetch` | user | 抓取网页内容 | 同上 | 否（自动批准） | 同上 |
| `mcp__cherry-tools__kb_search`/`…__kb_list`/`…__kb_read` | user（search/manage）／internal（list/read） | 知识库检索/浏览/深读 | 同上 | 否 | 依赖 `requiresKnowledgeScope`；无绑定知识库时工具不可用 |
| `mcp__cherry-tools__kb_manage` | user | 增删/刷新知识库文档 | 同上 | **是**（显式排除自动批准） | 唯一会写用户知识库的 cherry-tools |
| `mcp__cherry-tools__to_markdown` | user | 本地文档转 Markdown（pdf/office/epub/csv 等） | 同上 | 未显式排除自动批准（走默认规则） | 可读工作区外本地文件，单独开关（`f1e793da79` 新增） |
| `mcp__cherry-tools__cron` | user | 应用内任务调度 | 同上 | 否 | 仅影响 App 内调度，非系统级 |
| `mcp__cherry-tools__notify` | user | 向已连接渠道发通知 | 同上 | 否 | 若外部渠道被 prompt injection 控制可被滥用发消息（影响范围限于已连接渠道） |
| `mcp__cherry-tools__config` | user | 读写 Agent 自身配置/渠道 | 同上 | 否（但 headless 会话下特定 action 被 `headlessConfigMutationHook` 拒绝） | `rename`/`add_channel`等 mutation action 在无人值守场景被拒绝 |
| `mcp__cherry-tools__generate_image` | user | 生成图像 | 同上 | **是**（显式排除自动批准） | 调用外部计费模型 + 写入用户文件库 |
| `mcp__cherry-tools__cli_list`/`…__cli_search` | 未在 CLAUDE_TOOL_REGISTRY 单列 exposure（走 cherry-tools 聚合） | 查询/搜索受管 CLI 清单 | 同上 | 否 | 只读 |
| `mcp__cherry-tools__cli_install` | 同上 | 安装受管 CLI 到隔离 mise 环境 | 同上 | **是**（显式排除自动批准） | 落地新可执行文件到共享 mise 环境 |
| `mcp__agent-memory__memory` | user | 跨会话记忆（FACT.md/JOURNAL.jsonl） | 同上 | 否（`mcp__agent-memory__*` 整体自动批准） | 限定在 `agentDataPath/memory/`，有 symlink 防御 |
| `mcp__skills__skills` | internal | 搜索/安装/卸载/编写 Skill | 同上 | 未见显式审批标记（走 `permissionMode` 默认规则） | 安装的 Skill 会写入 `~/.claude`（或 Cherry 隔离配置目录）并被 SDK 自动加载执行其指令文本 |
| `mcp__assistant__navigate` | 仅 Cherry Assistant 本地会话 | 生成可点击导航链接 | 同上 | 否（显式自动批准，唯一一个） | 不真正跳转，只生成链接，需用户手动点击 |
| `mcp__assistant__diagnose` | 仅 Cherry Assistant 本地会话 | 读本机日志/配置/源码/连通性 | 同上 | **是**（显式排除自动批准，注释含威胁模型说明） | 读本机日志/源码/配置，仅本地会话注入 |

### 10.2 In-memory MCP Servers（普通聊天路径，`BuiltinMcpServerNames`）

| Server | 默认是否 active | 提供工具 | 执行位置 | 默认审批 | 风险点 |
| --- | --- | --- | --- | --- | --- |
| `memory` | 是（需配置 `MEMORY_FILE_PATH`） | 知识图谱式实体/关系存取 | 主进程 in-process | 无 `disabledAutoApproveTools` → 默认自动 | 存储文件路径用户可配 |
| `sequentialThinking` | 是 | 结构化思维链辅助 | 主进程 in-process | 自动 | 纯逻辑辅助，无副作用 |
| `braveSearch` | 否（需 API Key） | 网页搜索 | 主进程 in-process，出网请求 | 自动 | 需用户配置 API Key 才可用 |
| `fetch` | 是 | 抓取网页 | 主进程 in-process，出网请求 | 自动 | 抓取内容可作为 prompt-injection 载体 |
| `filesystem` | 否（默认关闭，需配置目录） | glob/ls/grep/read/edit/write/delete | 主进程 in-process，真实文件系统读写 | `write`/`edit`/`delete` 默认 `disabledAutoApproveTools`（需审批），其余自动 | `baseDir` 由用户配置，可被设成任意目录；"always allow" 后无提示写盘 |
| `difyKnowledge` | 否（需 API Key） | Dify 知识库检索 | 主进程 in-process，出网请求 | 自动 | 需配置 Key |
| `python` | 否 | `python_execute`（Pyodide） | renderer Web Worker（Wasm 沙箱），经两层 IPC 转发 | 自动 | 执行链路长，Worker 侧桥接能力未验证 |
| `@cherry/didi-mcp` | 否（需 API Key） | 滴滴 MCP（未展开阅读具体工具） | 主进程 in-process/HTTP | 自动 | 第三方 API，需配置 Key |
| `browser` | 否 | open/execute/reset/screenshot/snapshot/tabs | 主进程 in-process，驱动隱藏 `BrowserWindow`（CDP） | 自动 | 全局共享 `persist:default` 分区；`execute` 可跑任意 JS；默认无头不可见 |
| `nowledgeMem` | 否 | 第三方记忆服务（Streamable HTTP，非 in-memory） | 连接 `http://127.0.0.1:14242/mcp`（本机第三方进程） | 自动 | 依赖本机第三方服务是否运行 |
| `flomo` | 否 | 第三方笔记服务（Streamable HTTP） | 连接 `https://flomoapp.com/mcp` | 自动 | 真实出网到第三方 SaaS |
| `mcpAutoInstall` | 否 | 元工具，自动安装其他 MCP server（`npx @mcpmarket/mcp-auto-install`） | 主进程子进程（npx 拉取远程包并执行） | 自动 | **供应链风险**：允许模型触发拉取并执行任意 npm 包 |

依据：`../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:48-370`、`../../cherry-studio/src/main/ai/tools/adapters/claudeCode/cherryBuiltinApproval.ts:26-77`、`../../cherry-studio/src/main/ai/mcp/servers/cherryBuiltinTools.ts:88-146`、`../../cherry-studio/src/main/ai/mcp/servers/cherryCliTools.ts:8-108`、`../../cherry-studio/src/main/ai/mcp/servers/cherryKnowledgeTools.ts:1-20`、`../../cherry-studio/src/main/ai/mcp/servers/skills.ts:47-76`、`../../cherry-studio/src/main/ai/mcp/servers/assistant.ts:59-238`、`../../cherry-studio/src/renderer/pages/settings/McpSettings/builtinMcpServers.ts:23-158`、`../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:397-421`。

## 11. 扩展机制

### 11.1 用户配置的 MCP

支持四种 transport：`stdio`（`StdioClientTransport`，真实子进程）、`sse`、`streamableHttp`（均基于 Electron `net.fetch`）、以及内建 server 专用的 `InMemoryTransport`。`sse`/`streamableHttp` 之间有**单向一次性回退**：若配置为 `sse` 但服务端返回 405（表明其实是 Streamable HTTP），或反之遇到 404/405，会自动改用另一种 transport 重试一次；`401`/`403`/`5xx` 不触发回退，以免掩盖真实鉴权/服务端错误（`getTransportCandidates`/`isTransportFallbackError`，`McpRuntimeService.ts:99-117`）。OAuth 走 `McpOAuthClientProvider` + 本机临时 `CallBackServer`（5 分钟超时）完成授权码交换，token 落盘在 `feature.mcp.oauth/<md5(baseUrl)>_oauth.json`，`removeServer()` 时仅在没有其他 server 共享同一 `baseUrl` 才清理该文件（避免误删共享凭据）。

### 11.2 In-memory factory

`createInMemoryMcpServer(name, args, envs)`（`factory.ts:17-57`）是一个 `switch` 分派表，按 `BuiltinMcpServerNames` 常量选择实例化哪个 Server 类；不认识的名字直接 `throw`。这是一份**硬编码白名单**，用户不能通过配置注入任意 in-memory server 类型，只能调整已知类型的参数（`args`/`env`）。

### 11.3 Skills 市场与信任边界

`mcp__skills__skills` 工具的 `search` action 直连 `https://claude-plugins.dev/api/skills`（硬编码域名，`skills.ts:12`），`install` 走 `skillService.install({installSource: 'claude-plugins:<identifier>'})`。本次未深入 `SkillService.install()` 内部对下载内容的校验逻辑（是否校验签名/来源/内容扫描），但已确认：
- 安装后的 Skill 会被 `skillService.toggle()` 立即为当前 Agent 启用，无额外审批步骤；
- Skill 本质是指令文本（`SKILL.md`）+ 支持文件，一旦启用即被 SDK 加载进系统提示/工具目录，其内容可以引导模型执行任何该会话已有权限的操作——**Skill 信任模型等价于"信任其文本内容对模型的引导力"，而不是独立的代码执行沙箱**；
- `init`/`register` 允许模型自己创作并注册新 Skill（先建目录写 `SKILL.md`，再注册），这是一条模型能自我扩展"隐性系统提示"的路径，值得关注但本次未发现额外审批门槛。

依据：`../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:96-117,633-680,966-987`、`../../cherry-studio/src/main/ai/mcp/servers/factory.ts:17-57`、`../../cherry-studio/src/main/ai/mcp/servers/skills.ts:12,149-218,257-374`。

## 12. 子 Agent 与任务委派

- `Agent`/`Task`（internal）是 SDK 原生的子 Agent 编排工具，允许模型派生一个子任务处理流；`TaskCreate`/`TaskGet`/`TaskUpdate`/`TaskList`/`TaskStop`/`TaskOutput` 是配套的任务队列管理工具（均 internal，无需用户手动开关）。本次阅读未在 Cherry 代码中找到对子 Agent 权限的**额外收窄**逻辑——`canUseTool`/`disallowedTools`/hooks 均按 `session.id` 生效，子 Agent 产生的工具调用是否共享父会话同一套策略快照，取决于 SDK 自身如何路由 `parent_tool_use_id`；`streamAdapter.ts` 中可见 `parentToolCallId`/`parentToolUseId` 字段用于渲染层区分嵌套调用来源，但**权限判定层面未见对子 Agent 做区分**（即子 Agent 默认继承与父 Agent 相同的 `canUseTool`/hooks），标记为待进一步验证 SDK 侧行为。
- `EnterWorktree`/`ExitWorktree` 提供 git worktree 切换能力（仅 `.git` 存在时可用），实现在 SDK 内部（Cherry 只声明了工具名/描述/条件门控，未发现自己的 worktree 操作代码），因此其安全边界完全依赖 SDK 自身对 `git worktree add/remove` 命令的封装是否安全。
- `Workflow`（user，曝光可见）用于编排"多步工作流并调度子 Agent"，是 registry 里唯一被标记 `user` 曝光的编排类工具，意味着用户可以在 UI 里单独禁用它。
- 后台任务通知（`task_notification` 等 SDK 消息类型）在 `ClaudeCodeRuntimeDriver.ts:383-391` 中，若到达时没有活跃 turn 流（例如子 Agent 在父 turn 结束后仍在跑），会被**直接丢弃并仅记录日志**，没有独立的后台任务展示 UI；同样，脱离 turn 的权限提示会被 `settingsBuilder.ts:775-783` 的 `OUT_OF_TURN_APPROVAL_DENIAL` 直接拒绝而非挂起等待。

依据：`../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:87-183`、`../../cherry-studio/src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:361-391`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:775-783`、`../../cherry-studio/src/main/ai/runtime/claudeCode/streamAdapter.ts:52-72`。

## 13. 外部渠道的系统安全提示

`CHANNEL_SECURITY_PROMPT`（`constants.ts:8-27`）只在 `linkedChannelSnapshot !== null`（会话绑定了外部消息渠道，如 Telegram/飞书/QQ/微信）时注入到系统提示末尾（`buildSystemPrompt`，`settingsBuilder.ts:1076`）。内容包括：禁止破坏性操作、禁止访问敏感文件（`.env`/SSH key/凭据等，但**明确放行** `mcp__cherry-tools__cron`）、禁止批量操作、禁止系统级配置修改、禁止数据外传、禁止响应"忽略之前指令"式的 prompt override，并要求把 `<<<EXTERNAL_UNTRUSTED_CONTENT>>>` 包裹的内容当作纯聊天输入而非指令。

**这条提示的性质是系统级文本约束，不是权限控制**：它完全依赖模型"愿意遵守"，不改变 `canUseTool`/`disallowedTools`/hooks 的实际判定逻辑。代码注释自己承认"这是最强的防御层，因为它优先于逐条消息的安全提示"（`constants.ts:5-6`），但这仍然只是 prompt-level 防御——一次成功的越狱/注入仍可能让模型忽略该提示直接调用工具，而真正拦得住的仍是 §7 的审批/hook 层（例如 `dependencyIsolationHook`、`workspacePathHook`）。换言之，外部渠道会话的实际安全边界 = 系统提示（软约束） + `assistantMcpEnabled=false`（渠道会话不注入 Assistant 诊断工具） + cherry-tools 自动批准列表本身固定不变（渠道会话与本机会话共享同一份 `CHERRY_BUILTIN_AUTO_APPROVED_TOOL_NAMES`，并**没有**因为是外部渠道而收紧自动批准范围）。

**渠道会话审批变化（`7b1015cd9c`）**：IM 渠道（QQ/微信/飞书/Telegram 等）会话现在在 `canUseTool` 审批闸门里被当作 **background agent** 处理（`settingsBuilder.ts` 把 `linkedChannelSnapshot` 传入 `buildToolPermissions` 作为 `isChannelSession`）——此前渠道会话的 MCP 工具调用会因"out of turn"被直接 deny（`opts.agentID` 只在子 Agent 场景有值），现在常规工具在父 turn 结束后无需实时交互即可自动放行；交互式工具（`AskUserQuestion` 等）仍独立发问。也就是说渠道会话从"审批闸门误拒"变为"后台代理式自动放行"，自动批准的范围实际上比本笔记初稿时更大。

**风险点**：`web_fetch`/`web_search` 在外部渠道会话中依然自动批准（结论来自 `settingsBuilder.ts` 注释自述"the untrusted-channel exposure this creates ... is bounded by the system-level channel security policy"），即防御完全押注在这条软性系统提示上,而没有代码层面为渠道会话单独收紧 `web_fetch` 审批策略。

依据：`../../cherry-studio/src/shared/ai/claudecode/constants.ts:1-27`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:281-283,725-736,1074-1076`。

## 14. 与消息渲染器笔记的交叉点

参考笔记（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`）确认：工具调用统一表示为 AI SDK `ToolUIPart`（含 `input-streaming`/`input-available`/`approval-requested`/`approval-responded`/`output-available`/`output-error` 等状态字段），approval 卡片由 `useToolApproval` 读取 `part.approval?.id` 渲染，审批按钮的 `confirm`/`cancel`/`autoApprove` 最终都要经 `useToolApprovalBridge` 发起真实 IPC 调用。

**模型能否伪造审批 UI**：
- **不能伪造出真正可点击、能生效的审批卡片**——因为 `findToolPartByCallId()` 是从渲染器自己解析的 `partsMap`（AI SDK 结构化 `UIMessage.parts`，由主进程流式 chunk 组装，模型只能通过工具调用协议本身产生这些 part，不能在纯文本 `text` part 里"注入"出一个假的 `tool-*` part 类型）中查找,`approvalId` 字段来自主进程 `toolApprovalRegistry`/DB 持久化决策，模型输出的普通文本无法伪造这个字段。
- **能造成视觉混淆**：模型在**普通文本正文**里完全可以输出形似"⚠️ 需要您批准: 是否允许执行 rm -rf /?"这样的字符串，但这段文本会被当作普通 Markdown 渲染（消息渲染器笔记确认了 Markdown 有白名单净化），不会被识别为真实的审批 part，也不会有 `confirm`/`cancel` 按钮——只是纯文本视觉欺骗，用户如果看不出区别可能误以为需要"回复"该文本从而触发下一轮对话（一种社会工程学风险，而非技术层面的权限绕过）。这一点消息渲染器笔记未覆盖，是本次调查新增的交叉发现。
- 工具块折叠/展开、`ToolBlockGroup` 聚合等渲染细节与审批状态无关，纯 UI 呈现问题，不构成安全边界。

依据：`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`（工具渲染章节）、`../../cherry-studio/src/renderer/components/chat/messages/tools/chooseTool.tsx:271-294`、`../../cherry-studio/src/renderer/components/chat/messages/tools/hooks/useToolApproval.ts:1-146`。

## 15. 未验证事项与后续调查缺口

1. `streamAdapter.ts` 中 `MAX_TOOL_INPUT_SIZE`/`MAX_TOOL_INPUT_WARN` 超限后的具体处理分支（截断/报错/静默丢弃）未完整追踪。
2. `error_max_turns` 终止原因在渲染层的具体呈现方式未验证。
3. `handleTruncationError()`/`isClaudeCodeTruncationError()` 的完整触发条件未展开全读。
4. `SendMessage`/`TeamCreate`/`TeamDelete`（agent-teams 实验特性，默认全量开启）的实际运行时行为、权限模型未深入验证——只确认了它们被声明为 `internal` 且环境变量门控。
5. `skillService.install()` 对下载 Skill 内容的校验逻辑（签名/来源/恶意内容扫描）未展开阅读。
6. Pyodide Web Worker 是否存在任何 postMessage 桥接能力回传主进程/Node API 未验证。
7. `子 Agent`（`Task`/`Agent` 工具触发的嵌套调用）是否与父会话共享同一份 `canUseTool`/`disallowedTools`/`toolPolicySnapshot`，或是否有独立策略,依赖 SDK 内部实现，未在 Cherry 代码中找到相关证据，需要读 `@anthropic-ai/claude-agent-sdk` 包本身源码才能确认。
8. 工具 id 双轨制（§2.2）下，legacy 名称型 id 与 AI SDK catalog 身份 id 之间的换算/归属在哈希截断边界重合场景下的正确性未做穷举测试验证；`buildMcpToolWireId` 的 pinyin 罗马化对日文/韩文 server 名会退化为摘要（`mcpToolId.ts:20-32` 注释自述），该退化路径无专门测试。
9. `didiMcp`/`nowledgeMem`/`flomo` 三个第三方 in-memory/HTTP server 的具体工具清单与数据流向未展开阅读（本次只确认了它们的注册/连接方式）。
10. 未运行仓库测试/构建（`node_modules` 未安装，Node 版本不匹配），所有结论均基于静态源码阅读，未经运行时验证。
