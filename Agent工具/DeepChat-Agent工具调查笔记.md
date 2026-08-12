# DeepChat Agent 工具调查笔记

> 调查对象：`E:\works\git\deepchat`（重点 `src/main/agent/deepchat/loop/`、`src/main/agent/deepchat/runtime/`、`src/main/tool/`、`src/main/provider/aiSdk/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：只读源码梳理（覆盖命令 shell 化、输出上限、执行契约门与二进制读取等实现）；未修改 DeepChat 仓库
>
> 调查范围：Agent 工具目录、MCP/内置工具合并、工具执行循环、参数解析与校验、结果回注、权限边界与 legacy function-call 兼容路径，以及 Windows 命令 shell、输出限制与执行契约
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的 Agent 工具由“会话工具目录 + 统一路由服务 + 独立循环引擎”组成：

1. `DeepChatToolResolver` 根据 Agent 配置、项目目录、Skills、禁用工具、MCP server 选择和 subagent 能力，生成带 fingerprint 的 session tool profile。工具目录按会话缓存，实例失效时会重新解析。
2. `ToolService` 将 MCP 工具和 `AgentToolManager` 的内置工具转换为统一的 MCP-format 定义。名称冲突时保留 MCP 工具，并给每个定义标记 `source: mcp|agent`。
3. `DeepChatLoopEngine` 每轮消费 Provider 流；出现 tool batch 时先结算并持久化，再继续下一轮。默认允许的工具调用总数为 128，另可通过 `maxProviderRounds` 设置 Provider round 上限。
4. 原生工具调用走 AI SDK 的 tool stream；不支持原生工具的 Provider 走 `<function_call>` 文本协议，解析器用 `jsonrepair` 处理部分非严格 JSON。
5. 执行前经过 `ToolPermissionBroker` 和命令专用的 `CommandPermissionService`。权限请求绑定会话、server identity、配置代数、binding hash、工具名、执行 id 和参数 hash，审批请求有数量上限和超时。
6. `exec`/`process` 使用可配置命令 shell（`posix|cmd|windows-powershell|git-bash`，#2109）；Agent 配置有输出上限字段（#2103）；工具分派前经过 Tape 执行契约门（contract lineage）；octet-stream 文本文件允许读取（#2110）。

## 调用链

```text
Session/Agent 配置
  -> DeepChatToolResolver
     -> tool profile fingerprint
     -> ToolService.getAllToolDefinitions
        -> MCP service.getAllToolDefinitions
        -> AgentToolManager.getAllToolDefinitions
        -> ToolMapper（记录 source 与执行合同）
  -> Provider AI SDK runtime
     -> native tool-calls 或 <function_call> legacy stream
  -> DeepChatLoopEngine
     -> ToolService.callTool
        -> permission preflight / command permission
        -> MCP service.callTool 或 AgentToolManager.callTool
     -> 持久化 tool result
     -> 下一 logical round
```

## 1. 工具目录解析

`DeepChatToolResolver.loadToolDefinitionsForSession` 在 `src/main/agent/deepchat/runtime/toolResolver.ts:64-79` 创建会话目录。上下文解析位于 `:81-151`：

- `agentId` 来自当前 runtime instance 或 session identity，缺失时使用内置 `deepchat`；
- `projectDir` 决定 `general` 或 `code` profile；
- `activeSkillNames` 由 Skill service 读取并校验；
- Agent policy 提供 `disabledAgentTools`、`enabledMcpServerIds`、session kind 与 subagent capability；
- profile fingerprint 还包含 Provider/model、tool registry revision、Skill 开关和 subagent slot（`:155-193`）。

对于 ACP-backed subagent session，目录解析显式返回空列表（`:136-150`）。因此 ACP 会话的工具执行能力由 ACP backend 自身承担，不能从 DeepChat 内置工具目录直接推断。

## 2. MCP 与内置工具合并

`ToolService.getAllToolDefinitions`（`src/main/tool/index.ts:127-239`）先调用 MCP service，再调用 AgentToolManager：

- MCP 工具按 `enabledTools`、`enabledServerIds`、Agent/session 过滤，保留 server identity；保留的定义标记为 `mcp`。
- Agent 工具在 `agent` 或 `acp agent` chat mode 加载，按 `activeSkillNames`、workspace 和 subagent capability 裁剪。
- `disabledAgentTools` 只作用于 user-configurable Agent 工具；system-model exposure 工具不被该列表隐藏。
- 若工具名已由 MCP mapper 注册，Agent 同名工具被丢弃，日志记录冲突并保留 MCP 版本（`:221-233`）。

AgentToolManager 的定义集合分为文件系统和命令工具（`read`、`write`、`edit`、`glob`、`grep`、`exec`、`process`，`agentToolManager.ts:797-970`）、Skills（`:2152` 起，含 skill_list/skill_run）、以及 question、计划、Tape、memory、图片生成、cron、subagent 和设置/浏览器工具（分散在 `:2150-2766` 与各 handler 文件）。每个定义带 `TOOL_EXECUTION` 合同：读取操作可标记 sequential/parallel，写入操作固定 sequential。

## 3. 工具调用与权限

`ToolService.callTool`（`src/main/tool/index.ts:311-430`）先由 mapper 识别来源，再观察授权并解析参数。Agent 工具会经过 subagent execution policy 和可选的 live delegation consent，随后由 AgentToolManager 执行；MCP 工具则路由到 MCP service。返回值统一包装为带 `toolCallId`、`content`、`source` 的 result envelope。

`ToolPermissionBroker`（`src/main/tool/permission/toolPermissionBroker.ts:130-183`、`:252-335`）的可观察边界包括：

- `permissionMode` 有 `default`、`auto_approve`、`full_access`；`full_access` 在非显式用户审批场景可直接放行模型来源调用。
- 参数先 canonicalize，再限制最大字节数和预览长度，计算 SHA-256 hash。
- 已批准记录必须同时匹配 conversation、serverId、configGeneration、bindingHash、toolName、executionId、参数 hash、来源和权限类型。
- 单会话 pending 请求有上限，默认请求会超时；会话清理会取消全部 pending。

命令工具在 `CommandPermissionService`（`src/main/tool/permission/commandPermissionService.ts`）另外做 base command、signature 和风险等级判断。安全白名单按 shell dialect 分开（`:31-50`）：posix 的 `ls`、`pwd`、`echo`、`cat`、`head`、`tail`、`wc`、`grep`、`diff`、`find`、`sort`、`uniq`；powershell 的 `get-childitem`、`select-string` 等；cmd 的 `dir`、`findstr` 等（git-bash 下 `diff/find/sort/uniq` 反而需要审批）。破坏性/网络模式按 dialect 分别匹配（`:52-58`），并新增引号感知的控制语法检测（`hasPosixControlSyntax`/`hasPowerShellControlSyntax`/`hasCmdControlSyntax`，`:90-200`）。命令审批请求现在携带 `shellProfile`（`src/main/session/contracts.ts:60`）；`approvePermission` 返回 grant 结果——命令类返回 `oneShotGrantId` 一次性授权（可被 `revokeOneShotCommandPermission` 撤销），非命令类返回 `granted`（`:73-79`）。

**命令 shell 化（#2109，源码确认）**：`src/shared/commandShell.ts` 定义 `AgentCommandShellConfig`（preference：`auto|windows-powershell|git-bash`）与 `ResolvedCommandShell`（profile/dialect/pathStyle/executable/args，四种：posix、cmd、windows-powershell、git-bash）。`AgentBashHandler.executeCommand` 与后台 `backgroundExecSessionManager` 全部改收 `ResolvedCommandShell`（`agentBashHandler.ts:124-186`）；RTK 改写只在 posix dialect 启用（`:713-724`）；工作目录按 `pathStyle` 归一化（`normalizeCommandShellFilePath`，`:293-310`）。设置面：`src/renderer/settings/components/common/CommandShellSettingsSection.vue`（新增，Windows 下可选 shell 偏好与 Git Bash 路径覆盖）。

**输出上限（#2103，源码确认）**：`DeepChatAgentConfig` 新增 `readFileAutoTruncateChars`/`toolOutputInlineChars`/`commandOutputInlineChars`（`agent-interface.d.ts:650-652`），`src/shared/lib/agentOutputLimits.ts` 归一化到 1,000–200,000（默认 4,500/5,000/12,000）；文件读取截断（`agentFileSystemHandler.ts:829-831`）与工具/命令输出内联预览使用这些值。执行侧还有 `executionContract` 分派门：`ToolService.callTool` 在 MCP 与 Agent 工具分派前都调 `assertExecutionContractDispatchAllowed`（`src/main/tool/index.ts:329`、`:388`、`:475`），违反冻结契约抛 `ExecutionContractDispatchError`（来自 Tape 契约谱系，见独特功能笔记能力卡 2）。

**二进制读取放宽（#2110，源码确认）**：`src/main/lib/binaryReadGuard.ts` 移除文档 MIME 例外与 `isLikelyTextFile` 探测，`shouldRejectAgentBinaryRead` 现在只拒绝 `ALWAYS_BINARY_MIMES` 与 audio/video（`:27-36`），octet-stream 文本文件允许读取。

## 4. 多轮执行边界

`DeepChatLoopEngine`（`src/main/agent/deepchat/loop/deepChatLoopEngine.ts:53-131`）的状态机为：

```text
consumeLogicalRound
  -> terminal / halted / tool_batch
  -> 超过 MAX_TOOL_CALLS ? 返回 max_tool_calls
  -> settleToolBatch
  -> afterRoundPersisted
  -> continue 或 terminal
```

`MAX_TOOL_CALLS` 固定为 128（`:3`）。`maxProviderRounds` 为正整数时限制 logical round，否则为无穷；工具数量同时计入初始已执行数量和当前 Provider 请求数量（`:75-110`）。异常会被转成 `thrown`，最终由 `settleTurn` 统一收口（`:61-68`）。

## 5. Provider 工具协议

AI SDK runtime 在 `src/main/provider/aiSdk/runtime.ts:1178-1224` 将 ChatMessage 和 MCP-format tool definitions 映射成 AI SDK messages/tools；支持原生工具的模型直接使用 `tool-calls`。`streamAdapter.ts:57-124` 收集原生 tool stream，并在不支持原生工具时缓冲文本。

legacy 解析器 `src/main/provider/aiSdk/toolProtocol.ts:38-126` 查找完整或未闭合的 `<function_call>`，尝试多种 JSON 外形，并在失败后用 `jsonrepair`；解析成功后转换为统一的 function tool call。流结束时若检测到 legacy tool use，会发出 `stop: tool_use`（`streamAdapter.ts:216-234`），由上层继续工具循环。

## 6. 参数解析、校验与错误处理

- **参数文本解析**：`ToolService.callTool` 对 Agent 工具先走 `parseAgentToolArguments`（`src/main/tool/index.ts:542-560`）：`JSON.parse` 失败后用 `jsonrepair` 修复，再失败则记录警告并返回空参数对象（:548-558）——即"解析失败降级为空参数"而不是抛错，由后续 schema 校验兜底。legacy `<function_call>` 文本的解析失败路径见 §5（`toolProtocol.ts`）。
- **schema 校验**：Agent 工具的执行入口在各 handler 前用 zod `schema.safeParse(args)` 校验（`agentToolManager.ts:997` process 工具、`:1114` 文件工具、`:2533`/`:2586` question 等工具、`:2644` skill_run；文件读写各子命令的解析在 `agentFileSystemHandler.ts:799-1183`）；MCP 工具的 `inputSchema` 校验发生在 MCP service 侧，本笔记未展开。校验失败的工具以 `tool_call_error`/错误响应回注（见 §7），不进入执行端。
- **权限/执行失败反馈**：审批未通过时 `ToolService.callTool` 返回 `createPermissionRequiredResponse`（`tool/index.ts:355-361`），以 `action_type: tool_call_permission` 交互块进入 UI（见消息渲染器笔记 §1）；执行异常由 `createAgentToolErrorResult` 包装为可恢复错误（`tool/index.ts:413-428`，`recoverable: true`）。

## 7. 结果回注与 UI 状态

- **回注模型**：工具调用与结果随 transcript 的 assistant block 持久化后，在下一轮上下文构建时转回模型消息——`contextBuilder.ts:958-1038` 把 `tool_call` 块映射为 assistant 消息的 `tool_calls` 字段（:985-1023），并把 `block.tool_call.response` 转成 `role: 'tool'` 消息（:1031-1038，含 `tool_call_id`）；MCP App 的 `modelContext` 也经此通道回注（contextBuilder.ts:45）。失败/错误响应同样以 tool 角色文本进入上下文。
- **UI 状态**：工具调用的展示状态机（calling/response/end/error 图标、参数/响应折叠、diff、图像预览、审批状态环、自动展开规则）由 `MessageBlockToolCall.vue` 承担（`src/renderer/src/components/message/MessageBlockToolCall.vue:300-378`、`:496-617`），与消息渲染器笔记 §1 的块分发为同一链路，本笔记只记录交接点。
- 正在进行的工具调用在 renderer 的 `streamingBlocks` 中随流式事件更新，结算后由持久化块接管显示（Chat 笔记 §3）。

## 8. 边界与未验证事项

- 工具目录缓存依赖 runtime instance 和 registry revision；本次未运行动态修改 MCP、Skill 或 Agent 配置时的并发竞态。
- `full_access`、命令白名单和文件 containment 是源码可见的权限边界；不同工具具体调用是否触发额外审批，取决于其 `preCheckToolPermission` 实现。
- MCP server 类型包括 `stdio`、`sse`、`http`、`inmemory`（`src/shared/types/mcp.ts:96-123`），本次未启动真实 server 验证 transport、OAuth 或 MCP App 回调。
- 原生工具和 legacy 工具最终都进入同一 LoopEngine，但各 Provider 的 capability snapshot、参数兼容和流式 finish reason 未逐一实测。
- 命令 shell（#2109）、输出上限（#2103）与执行契约门（contract lineage）为源码确认；不同 shell dialect 的实际解析差异、RTK 在非 posix 下的绕过路径、契约违反的运行时表现未运行验证。
- 未运行项目测试、构建或外部工具；以上内容来自静态源码证据。

## 9. 关键源码索引

- 循环引擎与 128 次上限：`src/main/agent/deepchat/loop/deepChatLoopEngine.ts:3-131`
- session tool profile：`src/main/agent/deepchat/runtime/toolResolver.ts:64-193`
- MCP/Agent 工具合并与路由：`src/main/tool/index.ts:182-239`、`:318-430`
- Agent 工具定义与文件访问：`src/main/tool/agentTools/agentToolManager.ts:797-970`、`:2152-2766`
- 权限 broker：`src/main/tool/permission/toolPermissionBroker.ts:130-183`、`:252-335`
- 命令风险、dialect 白名单与会话审批：`src/main/tool/permission/commandPermissionService.ts:31-58`、`:90-200`
- 命令 shell 配置：`src/shared/commandShell.ts`、`src/renderer/settings/components/common/CommandShellSettingsSection.vue`
- 输出上限：`src/shared/lib/agentOutputLimits.ts`、`agent-interface.d.ts:650-652`
- 执行契约门：`src/main/tape/domain/executionContract.ts`、`src/main/tool/index.ts:329/388/475`
- 二进制读取守卫：`src/main/lib/binaryReadGuard.ts:27-36`
- 参数解析与 schema 校验：`src/main/tool/index.ts:542-560`、`src/main/tool/agentTools/agentToolManager.ts:997/1114/2533/2644`
- 工具结果回注：`src/main/agent/deepchat/runtime/contextBuilder.ts:958-1038`
- 工具调用 UI 状态（交接点）：`src/renderer/src/components/message/MessageBlockToolCall.vue:317-323`、`:537-560`
- MCP server/config 类型：`src/shared/types/mcp.ts:45-123`
- 原生/legacy AI SDK 工具协议：`src/main/provider/aiSdk/runtime.ts:1178-1224`、`src/main/provider/aiSdk/toolProtocol.ts:38-150`、`src/main/provider/aiSdk/streamAdapter.ts:57-124`

