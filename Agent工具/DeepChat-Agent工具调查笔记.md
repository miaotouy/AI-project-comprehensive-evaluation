# DeepChat Agent 工具调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/main/agent/deepchat/loop/`、`src/main/agent/deepchat/runtime/`、`src/main/tool/`、`src/main/provider/aiSdk/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：只读源码梳理（覆盖命令 shell 化、输出上限、执行契约门与二进制读取等实现）；未修改 DeepChat 仓库
>
> 调查范围：Agent 工具目录、MCP/内置工具合并、工具执行循环、参数解析与校验、结果回注与上下文裁剪、权限边界与 legacy function-call 兼容路径，以及 Windows 命令 shell、输出限制与执行契约
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的 Agent 工具由“会话工具目录 + 统一路由服务 + 独立循环引擎”组成：

1. `DeepChatToolResolver` 根据 Agent 配置、项目目录、Skills、禁用工具、MCP server 选择和 subagent 能力，生成带 fingerprint 的 session tool profile。工具目录按会话缓存，实例失效时会重新解析。
2. `ToolService` 将 MCP 工具和 `AgentToolManager` 的内置工具转换为统一的 MCP-format 定义。名称冲突时保留 MCP 工具，并给每个定义标记 `source: mcp|agent`。
3. `DeepChatLoopEngine` 每轮消费 Provider 流；出现 tool batch 时先结算并持久化，再继续下一轮。默认允许的工具调用总数为 128，另可通过 `maxProviderRounds` 设置 Provider round 上限。
4. 原生工具调用走 AI SDK 的 tool stream；不支持原生工具的 Provider 走 `<function_call>` 文本协议，解析器用 `jsonrepair` 处理部分非严格 JSON。
5. 执行前经过 `ToolPermissionBroker` 和命令专用的 `CommandPermissionService`。`auto_approve` 下由 `resolveAgentToolReview` 统一回答“这次调用是否需要助手审阅、审批授权的是命令还是路径”；权限请求绑定会话、server identity、配置代数、binding hash、工具名、执行 id 和参数 hash，审批请求有数量上限和超时。
6. `exec`/`process` 使用可配置命令 shell（preference 有 `auto`、`bash`、`zsh`、`fish`、`windows-powershell`、`powershell-core`、`cmd`、`git-bash` 八种，#2109）；Agent 配置有输出上限字段（#2103）；工具分派前经过 Tape 执行契约门（contract lineage）；octet-stream 文本文件允许读取（#2110）。
7. 当前请求不再直接复用整份会话目录：循环会从有效目录派生并冻结 tool-surface snapshot，按激活证据决定下一视图可见的工具；程序化工具调用也绑定该快照的执行授权，取消或结束时撤销资格（`src/main/agent/deepchat/loop/contextCoordinator.ts:962-1010`、`loopRun.ts:519-616`）。
8. Agent 可选择配置判定模型（judgment model）；配置后工具权限审阅与工具结果裁剪改由 Jev 协议（TypeSafe System One）做原子问答，未配置时仍走原有的生成式审阅与仅按体积截断。
9. Skill 工具面可合并当前工作区发现的只读 Skills；Codex 用户包还可选择发布 Skills、MCP 配置和上下文 hook。Hook 只贡献经校验的附加上下文，不直接绕过冻结工具目录执行任意工具。

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

`DeepChatToolResolver.loadToolDefinitionsForSession` 在 `src/main/agent/deepchat/runtime/toolResolver.ts:292-314` 通过会话 catalog port 创建目录；单轮执行的目录解析入口是 `resolveRunToolDefinitionUniverse`（`:316` 起），其上下文来源为：

- `agentId` 来自当前 runtime instance 或 session identity，缺失时使用内置 `deepchat`（`:333-337`）；
- `projectDir` 决定 `general` 或 `code` profile；
- `activeSkillNames` 由 Skill service 读取并校验（`:338-347`）；
- Agent policy 提供 `disabledAgentTools`、`enabledMcpServerIds`、session kind 与 subagent capability；
- profile fingerprint 由上述输入序列化而成，还包含 Provider/model、tool registry revision、Skill 开关和 subagent slot（`:846-874`）。

工作区 Skill 由 Skill 服务按会话项目路径即时合并：扫描项目根下 `.agents/.deepchat/.claude/.codex/.cursor/skills`，只接受物理路径仍位于项目根内的条目，并将其标记为只读。它们可以进入路由卡和 `skill_run`，但不会成为共享 Skill 库中的可编辑对象；发现、物理根校验与请求级 overlay 见 `src/main/skill/index.ts:1295-1322`、`:1940-1954`。

对于 ACP-backed subagent session，目录解析显式返回 `acp-excluded` 的空集合（`:329-331`）。因此 ACP 会话的工具执行能力由 ACP backend 自身承担，不能从 DeepChat 内置工具目录直接推断。

## 2. MCP 与内置工具合并

`ToolService.getAllToolDefinitions`（`src/main/tool/index.ts:332-510`）先调用 MCP service，再调用 AgentToolManager：

- MCP 工具按 `enabledTools`、`enabledServerIds`、Agent/session 过滤，保留 server identity；保留的定义标记为 `mcp`；名称落在 `RESERVED_AGENT_TOOL_NAMES` 的 MCP 工具被剔除（`:442-445`）。
- Agent 工具在 `agent` 或 `acp agent` chat mode 加载，按 `activeSkillNames`、workspace 和 subagent capability 裁剪。
- `disabledAgentTools` 只作用于 user-configurable Agent 工具；system-model exposure 工具不被该列表隐藏。
- 若工具名已由 MCP mapper 注册，Agent 同名工具被丢弃，日志记录冲突并保留 MCP 版本（`:474-491`）。

AgentToolManager 的定义集合按功能分组装配（`agentToolManager.ts:599-850` 的编号段），每个定义带 `TOOL_EXECUTION` 执行合同——读取操作可标记 sequential/parallel，写入操作固定 sequential：

- 文件系统与命令工具：`read`、`write`、`edit`、`glob`、`grep`、`exec`、`process`（`:1128-1295`）；
- 内置 question 工具 `deepchat_question`：schema 已迁到 `src/shared/contracts/questionTool.ts`，定义仍由 `getQuestionToolDefinitions` 提供（`:1277`）；
- 会话 Tape 工具与 `read_session`（`:649-702`）：会话参考读取器只在 DeepChat 会话、非 subagent 且存在 conversationId 时挂载；
- 长期记忆、图片生成、定时任务 `cronjob`、持久委派 `deepchat_subagents`（`:704-773`）；
- Skills 工具：`skill_list`、`skill_view`、`skill_manage`、`skill_run`（`:2901-2962`）；
- 设置工具与 YoBrowser CDP 工具（`:792-850`）。

原 `update_plan` 计划工具已随计划能力一起移除（`src/shared/types/agent-plan.ts` 与 `agentPlanTool.ts` 均不存在），工具面只保留执行类能力。

Codex 用户包是另一种组合来源。安装器识别 `.codex-plugin/plugin.json`，用户在安装时分别选择 Skills、MCP 与 hooks；已选择的 Skills/MCP 进入现有目录体系，命令 hook 在输入边界运行并只接受匹配事件名的文本 `additionalContext`。Hook 超时在清单里声明，默认 5 秒、上限 30 秒，失败进入诊断且不会自动获得工具调用资格；实现见 `src/main/plugin/userPluginPackage.ts:100-168`、`src/main/plugin/userPluginHooks.ts:45-141`、`:490-533`。

## 3. 工具调用与权限

`ToolService.callTool`（`src/main/tool/index.ts:676` 起）先由 mapper 识别来源，再观察授权并解析参数。Agent 工具会经过 subagent execution policy 和可选的 live delegation consent，随后由 AgentToolManager 执行；MCP 工具则路由到 MCP service。返回值统一包装为带 `toolCallId`、`content`、`source` 的 result envelope。

`ToolPermissionBroker`（`src/main/tool/permission/toolPermissionBroker.ts:113-165`、`:203-246`）的可观察边界包括：

- `permissionMode` 有 `default`、`auto_approve`、`full_access`；`full_access` 在非显式用户审批场景可直接放行模型来源调用（`:121-142`）。
- 参数先 canonicalize，再限制最大字节数和预览长度，计算 SHA-256 hash。
- 已批准记录必须同时匹配 conversation、serverId、configGeneration、bindingHash、toolName、executionId、参数 hash、来源和权限类型。
- 单会话 pending 请求上限为 `MAX_PENDING_PER_CONVERSATION`（64），默认请求会超时；会话清理会取消全部 pending。

`auto_approve` 下“这次调用是否要助手审阅、审批授权的是什么”由 `resolveAgentToolReview`（`src/main/tool/permission/agentToolReviewPolicy.ts:134-174`）单独回答：它按工具声明执行合同判断，`exec` 授权命令、文件类工具授权路径、其余写操作授权工具本身；`cronjob`、`deepchat_question` 自成审批路径，`process` 的 `list/poll/log` 与只读操作不进入审阅。该模块与允许路径共用同一份路径承载工具清单，避免“审阅认为授权路径、放行却不需要路径”的分歧。

**判定模型审阅（可选）**：Agent 配置了 `judgmentModel`（providerId + modelId）后，审阅不再走生成式补全，而是调用 Jev 协议（`src/main/agent/deepchat/runtime/toolPermissionReviewer.ts:355-372`、`:228-300`）。动作被序列化成带 hash 的 envelope，`fitJevReviewState` 按约 64k token 的请求预算分阶段裁剪 `toolArgs` 等状态（`jevReviewState.ts:1-60`），问题固定为风险等级、用户授权程度与注入压力三问，由 `composeJevReviewDecision` 依阈值合成 `auto_allow`、`ask_user` 或 `block`（`jevPermissionQuestions.ts:20-45`）。只有 low 风险可自动放行，比生成式路径的 low+medium 更严格；超时、预算不足和异常一律落到 `ask_user`。未配置判定模型时沿用原有生成式审阅。

命令工具在 `CommandPermissionService`（`src/main/tool/permission/commandPermissionService.ts`）里额外做 base command、signature 与风险等级判断。安全白名单按 shell dialect 分开（`:32-65`）：

- posix：`ls`、`pwd`、`echo`、`cat`、`head`、`tail`、`wc`、`grep`、`diff`、`find`、`sort`、`uniq`
- powershell：`get-childitem`、`get-content`、`select-string`、`measure-object`、`sort-object` 等
- cmd：`dir`、`findstr`、`type`、`where` 等
- git-bash 下 `diff/find/sort/uniq` 反而需要审批（`GIT_BASH_COMMANDS_REQUIRING_APPROVAL`，`:65`）

破坏性/网络模式按 dialect 分别匹配（`:67-78`），另有引号感知的控制语法检测（`hasPosixControlSyntax`/`hasPowerShellControlSyntax`/`hasCmdControlSyntax`，`:92-230`）。命令审批请求携带 `shellProfile`（`src/main/session/contracts.ts:68`）；`CommandPermissionService` 返回一次性授权 id（`oneShotGrantId`，可被 `revokeOnce` 撤销），非命令类则返回 `granted`。

**命令 shell 化（#2109，源码确认）**：`src/shared/commandShell.ts` 定义配置与解析结果两层：偏好取值有 `auto|bash|zsh|fish|windows-powershell|powershell-core|cmd|git-bash` 八种，解析后的 profile 也为八种，但 dialect 只有 posix、cmd、powershell 三种，pathStyle 有 native、win32、msys 三种（`:3-118`）。`AgentBashHandler` 收 `ResolvedCommandShell`（`agentBashHandler.ts:114` 起），命令提示行、`exec` 描述与方言提示由 `formatCommandShellPromptLine`/`formatExecCommandDescription` 统一生成（`commandShell.ts:224-241`）。设置面：`src/renderer/settings/components/common/CommandShellSettingsSection.vue`（Windows 下可选 shell 偏好与 Git Bash 路径覆盖）。

**输出上限（#2103，源码确认）**：`DeepChatAgentConfig` 的 `readFileAutoTruncateChars`/`toolOutputInlineChars`/`commandOutputInlineChars` 在 `deepChatAgentRepository.ts:154-156` 合并，归一化在 `src/shared/lib/agentOutputLimits.ts`；文件读取截断与工具/命令输出内联预览分别使用这些值（`agentToolManager.ts:1725-1740`、`toolOutputGuard.ts:212`）。

**执行契约分派门**：`ToolService.callTool` 在 MCP 与 Agent 工具分派前都调 `assertExecutionContractDispatchAllowed`（`src/main/tool/index.ts:885`、`:953`、`:1065`、`:1576`），违反冻结契约抛 `ExecutionContractDispatchError`（来自 Tape 契约谱系，见独特功能笔记能力卡 2）。

**二进制读取放宽（#2110，源码确认）**：`src/main/lib/binaryReadGuard.ts:69-80` 的 `shouldRejectAgentBinaryRead` 只拒绝 `ALWAYS_BINARY_MIMES` 与 audio/video，image 放行；octet-stream 文本文件允许读取。ACP 文本读取另走 `shouldRejectAcpTextRead`（`:50-66`），对 octet-stream 仍会用 `isLikelyTextFile` 探测。

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

AI SDK runtime 在 `src/main/provider/aiSdk/runtime.ts:1169-1249` 把 ChatMessage 和 MCP-format tool definitions 映射成 AI SDK messages/tools；支持原生工具的模型拿到 `toolsMap` 并直接使用 `tool-calls`。`streamAdapter.ts:98-230` 的 `adaptAiSdkStream` 收集原生 tool stream 与参数缓冲，并在不支持原生工具时把文本攒进 `bufferedLegacyText`。

legacy 解析器 `parseLegacyFunctionCalls`（`src/main/provider/aiSdk/toolProtocol.ts:50-127`）查找完整或未闭合的 `<function_call>`，尝试多种 JSON 外形，失败时用 `jsonrepair` 修复，成功则转换为统一的 function tool call。流结束时若检测到 legacy tool use，会发出 `stop: tool_use`（`streamAdapter.ts:340-360`），由上层继续工具循环。

## 6. 参数解析、校验与错误处理

- **参数文本解析**：`ToolService.callTool` 对 Agent 工具先走 `parseAgentToolArguments`（`src/main/tool/index.ts:1463-1485`）：`apply_patch` 直接包装成 `{ patch }`，其余按 `JSON.parse` 解析，失败后用 `jsonrepair` 修复，再失败则记录警告并返回空参数对象——即解析失败时降级为空参数、不抛错，由后续 schema 校验兜底。legacy `<function_call>` 文本的解析失败路径见 §5。
- **schema 校验**：Agent 工具的执行入口在各 handler 前用 zod `schema.safeParse(args)` 校验，主要入口包括：
  - `agentToolManager.ts:1343` process 工具、`:1456` 文件工具统一入口、skill 工具 `:3348`/`:3362`/`:3479`/`:3537`；
  - 文件读写各子命令的解析在 `agentFileSystemHandler.ts:892-1000` 一带。
  MCP 工具的 `inputSchema` 校验发生在 MCP service 侧，本笔记未展开。校验失败的工具以 `tool_call_error`/错误响应回注（见 §7），不进入执行端。
- **权限/执行失败反馈**：审批未通过时 `ToolService.callTool` 返回 `createPermissionRequiredResponse`（`tool/index.ts:1515-1540`），以 `action_type: tool_call_permission` 交互块进入 UI（见消息渲染器笔记 §1）；执行异常由 `createAgentToolErrorResult` 包装为可恢复错误（定义在 `src/shared/lib/agentToolResultEnvelope.ts:70`，调用点 `tool/index.ts:1004-1013`，`recoverable: true`）。

## 7. 结果回注与 UI 状态

- **回注模型**：工具调用与结果随 transcript 的 assistant block 持久化后，在下一轮上下文构建时转回模型消息——`contextBuilder.ts:1100-1190` 把 `tool_call` 块映射为 assistant 消息的 `tool_calls` 字段，并把 `block.tool_call.response` 转成 `role: 'tool'` 消息（含 `tool_call_id`）；MCP App 的 `modelContext` 也经此通道回注（`contextBuilder.ts:60`）。失败/错误响应同样以 tool 角色文本进入上下文。
- **上下文裁剪**：关闭的工具结果在拼装上下文时先经过体积截断（超过阈值的保留头尾）。配置判定模型后，会在截断之前先追加一次 Jev 判定，问每个已关闭结果“是否仍然需要”，判定为过时的整条替换成短说明，判定为必要的原样保留（`src/main/agent/deepchat/runtime/jevToolResultPruning.ts:1-45`，接线在 `loop/contextCoordinator.ts:907-922`）。裁剪只作用于本轮投影，不写 Session Tape；每次尝试最多判定一次，异常时保留全部结果。
- **UI 状态**：工具调用的展示状态机（running/reviewing/error 状态环与图标、权限徽标、参数/响应折叠、diff、图像预览、自动展开规则）由 `MessageBlockToolCall.vue` 承担（`src/renderer/src/components/message/MessageBlockToolCall.vue:24-70`、`:360-620`），与消息渲染器笔记 §1 的块分发为同一链路，本笔记只记录交接点。
- 正在进行的工具调用在 renderer 的 `streamingBlocks` 中随流式事件更新，结算后由持久化块接管显示（Chat 笔记 §3）。

## 8. 边界与未验证事项

- 工具目录缓存依赖 runtime instance 和 registry revision；本次未运行动态修改 MCP、Skill 或 Agent 配置时的并发竞态。
- 未运行 workspace skill 同名覆盖、用户插件更新/回滚、hook 超时与安装中取消；Direct ACP Agent 不接收这些 hook 上下文。
- `full_access`、命令白名单和文件 containment 是源码可见的权限边界；不同工具具体调用是否触发额外审批，取决于其 `preCheckToolPermission` 实现。
- MCP server 类型包括 `stdio`、`sse`、`http`、`inmemory`（`src/shared/types/mcp.ts:116`），本次未启动真实 server 验证 transport、OAuth 或 MCP App 回调。
- 原生工具和 legacy 工具最终都进入同一 LoopEngine，但各 Provider 的 capability snapshot、参数兼容和流式 finish reason 未逐一实测。
- 命令 shell（#2109）、输出上限（#2103）与执行契约门（contract lineage）为源码确认；不同 shell dialect 的实际解析差异、RTK 在非 posix 下的绕过路径、契约违反的运行时表现未运行验证。
- 判定模型的阈值与问题集在源码里自标注为临时值，本次未运行其假阳/假阴评估；判定期把工具参数、近期对话与工具结果内容发给该模型，是否启用由 Agent 配置决定。
- 未运行项目测试、构建或外部工具；以上内容来自静态源码证据。

## 9. 关键源码索引

- 循环引擎与 128 次上限：`src/main/agent/deepchat/loop/deepChatLoopEngine.ts:3-131`
- session tool profile：`src/main/agent/deepchat/runtime/toolResolver.ts:292-314`、`:316-360`、`:846-874`
- MCP/Agent 工具合并与路由：`src/main/tool/index.ts:332-510`
- Agent 工具定义与文件访问：`src/main/tool/agentTools/agentToolManager.ts:599-850`、`:1128-1295`、`:2901-2962`
- 权限 broker：`src/main/tool/permission/toolPermissionBroker.ts:113-165`、`:203-246`
- `auto_approve` 审阅范围：`src/main/tool/permission/agentToolReviewPolicy.ts:134-174`
- 判定模型审阅：`src/main/agent/deepchat/runtime/toolPermissionReviewer.ts:355-372`、`jevPermissionQuestions.ts`、`jevReviewState.ts`
- 命令风险、dialect 白名单与会话审批：`src/main/tool/permission/commandPermissionService.ts:32-78`、`:92-230`
- 命令 shell 配置：`src/shared/commandShell.ts`、`src/renderer/settings/components/common/CommandShellSettingsSection.vue`
- 输出上限：`src/shared/lib/agentOutputLimits.ts`、`src/main/agent/deepchat/deepChatAgentRepository.ts:154-156`
- 执行契约门：`src/main/tape/domain/executionContract.ts`、`src/main/tool/index.ts:885/953/1065`
- 二进制读取守卫：`src/main/lib/binaryReadGuard.ts:50-80`
- 参数解析与 schema 校验：`src/main/tool/index.ts:1463-1485`、`src/main/tool/agentTools/agentToolManager.ts:1343/1456/3348/3537`
- 工具结果回注：`src/main/agent/deepchat/runtime/contextBuilder.ts:1100-1190`
- 工具结果裁剪：`src/main/agent/deepchat/runtime/jevToolResultPruning.ts`、`src/main/agent/deepchat/loop/contextCoordinator.ts:907-922`
- 工具调用 UI 状态（交接点）：`src/renderer/src/components/message/MessageBlockToolCall.vue:24-70`、`:360-620`
- MCP server/config 类型：`src/shared/types/mcp.ts:116`
- 原生/legacy AI SDK 工具协议：`src/main/provider/aiSdk/runtime.ts:1169-1249`、`src/main/provider/aiSdk/toolProtocol.ts:50-127`、`src/main/provider/aiSdk/streamAdapter.ts:98-230`
- workspace skills：`src/main/skill/index.ts:1295-1322`、`src/main/skill/routingCatalog.ts`、`src/main/skill/sync/`
- Codex 用户包与上下文 hooks：`src/main/plugin/userPluginPackage.ts`、`src/main/plugin/userPluginHooks.ts`、`src/main/agent/deepchat/runtime/pluginContext.ts`
