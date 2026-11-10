# Cherry Studio Agent 工具调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：只读源码梳理（未修改被调查仓库任何文件）；未运行仓库测试/构建，结论均以静态阅读源码为准；三种 Agent runtime 的工具注入分别核对
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 存在三条彼此独立、但共享部分基础设施（MCP 运行时、命名规则、审批 UI、cherry-tools）的 Agent 工具路径：

1. **普通聊天 MCP 路径**：MCP 运行时服务在应用启动的 WhenReady 阶段初始化，并按需建立、复用普通聊天使用的 server 连接，管理用户配置的 stdio、SSE、Streamable HTTP、OAuth 与 in-memory 各类 server；发现的工具经 `syncMcpToolsToRegistry` 注册进 AI SDK 的工具注册表，再按会话选中的工具范围过滤，是否强制审批与是否延迟加载由该 server 的 `disabledAutoApproveTools` 决定。
2. **Claude Code Agent 路径**：工具清单来自一份声明式注册表（`src/shared/ai/claudecode/toolRegistry.ts`），它为每个 SDK 原生工具和进程内 MCP 工具（cherry-tools、agent-memory、assistant、skills）标注曝光级别：用户可见、内部隐藏或禁用。主进程按这份声明生成禁用工具名单和调用回调，再挂上一组前置 hook，随会话设置注入 SDK 的 `query()`。

两条路径都最终落在 Electron **主进程**执行：MCP 子进程和 HTTP client 由上述运行时服务持有；Claude Code 的原生工具（Bash/Read/Write/...）由 SDK 自带的原生二进制执行，Cherry 只能通过禁用列表、调用门控和 PreToolUse hook 三层限制或审批，不持有执行本身。

代码中已确认的关键机制事实：
- **审批模型（Claude Code 原生工具）**：Bash 这类原生工具在 default 权限模式下每次调用都要单独审批（`prompt`），没有 "always allow" 式的持久记忆；非 MCP 工具在界面上也不提供自动批准按钮（`useToolApproval.ts:136-146`）。切换到 bypassPermissions，或在 acceptEdits 模式下命中首词快路径（mkdir、touch、mv、cp），可以免掉普通调用的审批；前置拒绝规则仍然照常生效，覆盖禁用工具、对用户数据 SQLite 的写入、全局安装和重复无进展等情形。命令文本按自由文本处理，没有通用 shell 白名单，也没有 OS 沙箱。依据：[toolRules.ts:97–125](../../cherry-studio/src/shared/ai/claudecode/toolRules.ts#L97-L125)、[guardRules.ts:120–181](../../cherry-studio/src/main/ai/runtime/claudeCode/guardRules.ts#L120-L181)。
- **审批模型（in-memory MCP）**：filesystem server 的写入、编辑、删除三个工具默认列在 `disabledAutoApproveTools` 里（`builtinMcpServers.ts:96`），首次调用需要审批；用户选择 "always allow" 后该工具名会从这个列表里移除，之后的写盘调用不再提示。两条路径共用同一个审批桥与 IPC 方法名，主进程的分发逻辑分开走：Claude Code 侧命中内存中的审批注册表快路径，普通聊天侧把决定落到数据库的消息 parts。
- **执行域**：所有工具最终都在 Electron 主进程里执行。browser server 固定使用全局共享的 `persist:default` 分区，任何调用它的会话共用同一份 cookie 与 localStorage；它的 `execute` 工具能在页面上下文执行任意 JS，默认无头运行，用户看不到页面在做什么（`browser/README.md:16`）。
- **路径校验边界**：工作区路径检查只覆盖 Edit、Glob、Grep、NotebookEdit、Read、Write 六个结构化文件工具的字段，Bash 命令文本里出现的路径不经过这道检查，源码注释说明这是有意留出的口子。
- **安全边界事实**：assistant MCP 只在本地 Cherry Assistant 会话注入，外部渠道会话拿不到；其中的 diagnose 工具能读本机日志、源码与配置，因此被特意排除在自动批准之外。自动批准工具集合的注释把一项风险写进了设计依据：可读本机数据的工具与自动批准的网页抓取工具可能出现在同一个会话里。

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

- 普通聊天：工具来源是 mcpServerService 中处于 active 状态的 MCP server，注册进程内共享的工具注册表（`src/main/ai/tools/adapters/aiSdk/registerBuiltinTools.ts` 与 `adapters/aiSdk/mcp/mcpTools.ts`），按会话范围过滤后交给 AI SDK 的 provider 原生 tool-calling。曝光级别只有“server 是否 active”和“工具是否在禁用列表”两级，没有 internal/disabled 的静态分层概念。
- Claude Code Agent：工具来源是一份声明式 TS 常量表 `CLAUDE_TOOL_DEFS`，加上该 Agent 绑定的 MCP server 列表。曝光级别分 `user`、`internal`、`disabled` 三档，定义与生效点注释在 `toolRegistry.ts:27-42`：
  - user：出现在编辑对话框，用户可开关，写回 agent 的禁用工具设置；
  - internal：始终启用、UI 隐藏（例如 Task、AskUserQuestion、ToolSearch）；
  - disabled：始终加入 SDK 的硬黑名单（例如原生 WebSearch、WebFetch、REPL、NotebookEdit、TodoWrite、CronCreate 等），模型完全看不到、也调用不到。

依据：`../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:1-42`、`../../cherry-studio/src/main/ai/tools/adapters/claudeCode/toolConditions.ts:1-90`、`../../cherry-studio/src/main/ai/tools/adapters/aiSdk/mcp/mcpTools.ts:69-97`。

internal 工具（如 Task、Agent、AskUserQuestion、SendMessage、TeamCreate 等 agent-teams 工具）本身并非 SDK ToolInputSchemas 联合类型的正式成员，只是运行时按环境变量条件注入（见下）。

## 2. 工具定义与注册

### 2.1 SDK 原生工具

`CLAUDE_TOOL_DEFS`（`toolRegistry.ts:48-370`）逐条声明运行时名称（也是写回禁用工具设置的 id）、category、exposure、description，以及可选的依赖项和 MCP server。其中几条：

- 后台命令输出由 `BashOutput` 读取，它是否可用跟随 Bash 的开关。这个名称是渲染层使用的别名，SDK 联合类型里对应的条目叫 `TaskOutput`；依赖关系写在注册表条目中（`toolRegistry.ts:48-370`）。
- 任务工具组共七个，全部是内部工具，覆盖任务创建、查询、更新、列表、停止与结果读取，逐项名单见 §10.1 的注册表。注册表注释把 `Task` 记为渲染专用别名，并把真正执行编排的 `Agent` 与这组任务调度工具区分开（`toolRegistry.ts:48-370`）。
- agent-teams 的三个协作工具（发消息、建队、删队）不在 SDK 的 `ToolInputSchemas` 联合类型里，只有设置 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 才由运行时注入。会话构建处无条件把该变量设为 1，所有 Claude Code Agent 会话因此都启用了这一实验特性；同一处还无条件追加 `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT=1`，让会话走 SDK 的简单系统提示模式（`settingsBuilder.ts:829-834`）。
- `EnterWorktree` 与 `ExitWorktree` 的可用性随运行环境判断，条件见 §4。
- SDK 自带的调度、监控与推送类工具共七个，全部列入禁用，逐项名单见 §3.2 的替换表与 §10.1。同类能力由 Cherry 的 cron 与 notify 两个工具接管（`mcp__cherry-tools__cron`、`mcp__cherry-tools__notify`）。

依据：`../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:48-263`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:829-834`。

### 2.2 mcp__* 命名与 wire id 映射（双轨制）

MCP 工具 id 拆成两套：

1. **legacy 名称型 id**：`buildFunctionCallToolName` 把 server 名与工具名分别转成驼峰再拼接，总长上限 63 字符；超长时保留前段，尾部换成服务器名的 FNV-1a 哈希后缀。这套 id 现在只服务持久化的来源策略规则与 Claude Code 适配器，原先按 server 判定归属的 `isFunctionCallToolNameForServer` 已删除，反向解析与转换代码仍在同一文件内（`mcpToolName.ts:114-167`）。
2. **AI SDK catalog 身份 id**：主进程另用 `buildMcpToolWireId` 生成 wire id，取服务器 id 与工具名拼接后的 sha256，以 20 位十六进制摘要收尾；非 ASCII 名字（中文等）先经 `tiny-pinyin` 罗马化，无法罗马化的字符直接退化为摘要。服务器 id 参与哈希，长名截断与哈希相撞都不会让不同 server 落到同一个 wire id 上（`src/main/ai/mcp/mcpToolId.ts:1-50`）。

两条路径共用 `toCamelCase`/`parseFunctionCallToolName` 的反向归属工具，但"普通聊天 MCP 的 catalog 注册"与"Claude Code 的 source-policy 匹配"各用一套 id 空间。

依据：`../../cherry-studio/src/shared/ai/tools/mcpToolName.ts:114-167`、`../../cherry-studio/src/main/ai/mcp/mcpToolId.ts:1-50`。

### 2.3 环境依赖导致的条件可用性

- `EnterWorktree` 与 `ExitWorktree` 是否出现由条件判定表决定：工作目录下存在 `.git` 才启用，否则直接计入禁用工具列表（`toolConditions.ts:34-37`）。
- agent-teams 工具集由 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 这个环境变量门控（见上）。
- 元工具 `ToolSearch` 是否出现取决于工具总数是否超过 SDK 内部阈值，Cherry 把 `ENABLE_TOOL_SEARCH` 设成 `auto`，判断留在 SDK 内完成（`settingsBuilder.ts:583`）。
- assistant MCP server 只在本地 Cherry Assistant 会话注入：会话标记为 assistant 且未关联外部渠道时才成立（`settingsBuilder.ts:283,1186-1193`）。
- `skills` 白名单由当前 Agent 启用的受管技能清单加上工作区本地 `.claude/skills` 目录名动态算出（`buildSkillWhitelist`，`settingsBuilder.ts:672-680`）。

依据：`../../cherry-studio/src/main/ai/tools/adapters/claudeCode/toolConditions.ts:21-37`、`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:283,583-584,672-680`。

## 3. 工具发现与注入

### 3.1 普通聊天 MCP

`syncMcpToolsToRegistry()`（`mcpTools.ts:114-159`）在每次相关会话构建工具集前对齐工具注册表：列出处于 active 的 server，逐个拉取可用工具清单，再注册、替换或剔除。剔除逻辑区分「server 被停用」与「本次刷新范围内工具消失」两种情况，避免瞬时连接失败误删已知工具集，后者由刷新命名空间门控。

### 3.2 Claude Code Agent

（Claude Code 的注入顺序见下条。）

注入发生在 `buildClaudeCodeSessionSettings()`（`settingsBuilder.ts:258-404,896-916`）内，按固定顺序组装九段：cwd、env、plugins、工具权限、system prompt、MCP server 表、工具元数据、allowedTools 微调、skills 白名单。
工具权限段由调用回调、`PreToolUse` hooks、禁用清单与策略快照组成；MCP server 段是用户 MCP 桥加 cherry-tools、agent-memory，本地 Assistant 会话另加 assistant。
会话内热更新无需重连：每次前置 hook 都按会话重新查询策略快照的禁用判定，中途禁用某工具会在下一次调用生效，子进程连接保持不变。

被 hard-disable 的原生工具及替代路径：

| 原生工具 | 替代路径 |
| --- | --- |
| `WebSearch`/`WebFetch` | `mcp__cherry-tools__web_search` / `…__web_fetch` |
| `TodoWrite` | 无直接替代（工具注册表未见等价物，可能依赖模型自行维护待办文本） |
| `REPL`/`NotebookEdit` | 无替代，纯移除 |
| `CronCreate`/`CronList`/`CronDelete`/`ScheduleWakeup`/`RemoteTrigger`/`Monitor`/`PushNotification` | `mcp__cherry-tools__cron` / `…__notify` |

表内四类工具的曝光级别统一是 `disabled`。

新增的 cherry-tools 工具：`mcp__cherry-tools__to_markdown`（`CherryToMarkdown`，exposure `user`，`toolRegistry.ts:317-327`）——把普通文本工具读不了的本地文档（pdf/office/epub/csv 等）转成 Markdown 给模型读；它单独有开关（读取工作区外本地文件，禁用 Read 不能连带关掉这条路径）。

依据：`../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:258-404`、`../../cherry-studio/src/main/ai/tools/adapters/aiSdk/mcp/mcpTools.ts:114-159`。

### 3.3 Pi / Pi-Durable runtime

Pi 路径不复用 `CLAUDE_TOOL_DEFS`：驱动只向会话提供工具清单与 Cherry 侧的能力注入，原生工具循环由 Pi 包持有。会话可用的工具由驱动导出的 `listPiAvailableTools(mcpIds)` 生成，Pi-Durable 在此基础上过滤掉自己的召回元工具后才把列表交给运行时执行。

Pi 自带一组元工具：`tool_search` 按名检索工具、`tool_call` 直接调用、`codemode` 用一段代码编排多个工具调用，另有 `vcc_recall` 供上下文召回。它们都标注为元工具且自动批准，因此模型的工具发现与批量调用由原生侧完成，宿主只注入系统提示、已选 Skill 与 Cherry 选定的 MCP server（经 linked transport 接入）；延迟加载的 MCP 工具仍可经这两个元工具入口被发现，嵌套调用复用同一审批闸门。

### 3.4 跨会话自主工具

`cherryAutonomyTools` 这一组内置工具把"另一个 Agent 会话"当作可访问对象：`agent_list` 列出可用 Agent，`session_read` 读取指定会话的消息（topic 与会话共用统一 facade），`session_create` 新建会话并可指定 Agent 与模型。它们与普通工具一样走审批与审计，但作用域跨会话，因此比单个会话内的文件读写更容易放大误操作面。
## 4. 模型调用表示与解析

普通聊天走 AI SDK 原生 tool-call/tool-result part（provider 层负责 function-calling 组装），Cherry 只在 MCP 工具创建入口中包一层执行和模型输出转换（`mcpTools.ts:29-66`）。

Claude Code Agent 消费的是 `@anthropic-ai/claude-agent-sdk` 输出的 `SDKMessage` 流，消息按流式事件、系统事件、结果事件等 subtype 区分，由 `ClaudeCodeStreamAdapter`（`streamAdapter.ts`）解析并归一成 Cherry 自己的 UI 消息块类型，SDK 侧的三类工具调用块都在这一层完成转换。关键点：
- 工具名先做一次反向解析，认出 `mcp__server__tool` 这类格式后判定调用来自某个 MCP server，据此填展示信息；
- 流式 JSON 累积器设了告警与上限两级阈值：超过 102400 字节先告警，超过 1MB 触发上限保护（`streamAdapter.ts:41-116`）。超限后走截断、报错还是静默丢弃，本次阅读没有追到具体分支，**标记为待进一步验证**。
- CLI 自动拒绝的调用在系统事件里带 permission_denied，适配器把它们单独记入拒绝集合，状态标为 `denied`，与执行失败的 `failed` 区分；回注模型时两者语义不同。

依据：`../../cherry-studio/src/main/ai/runtime/claudeCode/streamAdapter.ts:41-116`、`../../cherry-studio/src/shared/ai/tools/mcpToolName.ts:152-163`。

## 5. 参数校验与规范化

- MCP 通用调用入口收到字符串类型的参数时先尝试按 JSON 解析，解析失败立即抛错终止，避免把裸字符串原样转发给下游 server 产生歧义错误。IPC 层只用 Zod schema 校验外层请求壳，即 server 标识、工具名、参数与调用 ID 四个字段，参数本体按协议信任处理，不做二次校验（`McpRuntimeService.ts:66-68,1082-1094`）。
- in-memory filesystem server 收到路径参数时先解析真实路径（穿透 symlink，落到最近存在的父目录），再与根目录前缀比对确认未越界，`../` 穿越与 symlink 逃逸都在这一步被拦下（`filesystem/types.ts:84-96`）。根目录本身来自用户配置，参数第一项或 `WORKSPACE_ROOT` 环境变量都能改；把它设成 `~` 或盘根之后，这套校验仍会照常放行其下所有路径（`filesystem/config.ts:1-8`）。**该边界的宽窄由配置决定，代码按配置执行。**
- Claude Code Bash 接收自由命令文本，权限模式的 acceptEdits 快路径仅取首词，详见 7.2。命令仍经过前置守卫，覆盖全局安装、用户数据 SQLite 写入和重复无进展等行为；它们不组成通用 shell 解析器或 OS 沙箱。结构化文件工具的路径通过真实路径/最近存在父目录判断是否落在允许根内，越界请求转入 ask 而非一概硬拒绝。依据：[guardRules.ts:38–79,120–181,235–246](../../cherry-studio/src/main/ai/runtime/claudeCode/guardRules.ts#L38-L79)。
- Agent memory MCP 对文件操作加了 `lstat` + `isSymbolicLink()` 双重防御，拒绝对 symlink 文件写入/追加（`agentMemory.ts:16-54,195-204`），是本次阅读中路径安全实现最严格的一处。

依据：
```text
../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:66-68,1082-1098
../../cherry-studio/src/main/ai/mcp/servers/filesystem/types.ts:47-96
../../cherry-studio/src/main/ai/mcp/servers/filesystem/config.ts:1-8
../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:497-514,923-950
../../cherry-studio/src/main/ai/mcp/servers/agentMemory.ts:16-54,195-204
```

## 6. 编排循环

### 6.1 普通聊天

工具轮次上限由 AI SDK 的 `stopWhen` 组合决定，SDK 兜底为 20 步（`buildAgentParams.ts:650`）。
默认 assistant 设置的轮次上限已从 20 轮提到 100（合法范围 1-1000，见 `assistant.ts:31-35`）；未显式自定义时普通聊天按 100 轮执行，`ToolLoopTerminalError` 的过早终止问题因此缓解。
这是**模型侧的 tool-call 轮数上限**，与 Claude Code 的 `max_turns` 是两套独立机制。

### 6.2 Claude Code Agent

- `max_turns` 上限直接取 Agent 配置里的同名字段，作为 SDK 的 `Options.maxTurns` 传下去，超限后的处理交给 SDK（`settingsBuilder.ts:385`）。SDK 在超限时给出 `error_max_turns` 终止原因，适配层确有分支消费它，该原因在渲染层如何呈现本次没有继续追，**标记为待验证**（`streamAdapter.ts`）。
- 并发的粒度是单次工具调用：运行时用一层映射按键记录挂在调用上的取消控制器，同一个 callId 可以关联多个 controller，因此多个 MCP 调用可以并行在跑；数据流中止时取消信号会**传播进在途 MCP 调用**，对应 controller 一并 abort，不必等调用超时（`mcpAbort.ts`、`McpRuntimeService.ts:276`）。Claude Code 侧的并发由 SDK 子进程自身调度，Cherry 没有额外设并发上限。
- 超时分两档：通用 MCP 调用默认 60 秒，可按 server 覆盖，标记为长时间运行的 server 改用进度重置加 10 分钟总时长上限（`McpRuntimeService.ts:1271-1275`）。连接建立阶段的 `initialize` 走独立的 180 秒地板值，不受上面两档影响（`McpRuntimeService.ts:155`）。
- 取消由 `AbortController` 承担：主动取消接口按 callId 中止对应控制器，会话停止钩子批量取消全部在途调用（`McpRuntimeService.ts:220-227,1316-1327`）。Claude Code 侧每条运行时连接各持一个控制器，关闭时以 `agent-runtime-closed` 为原因中止；审批注册表监听同一信号，把等待中的审批置为 deny（`ClaudeCodeRuntimeDriver.ts:148,341-348`、`ToolApprovalRegistry.ts:42-52`）。
- 错误回传分两侧：MCP 调用异常直接抛出，由上层 AI SDK 的 `execute` 包装成 `output-error` 结果 part；Claude Code 侧的异常（含流被 CLI 中途终止）先交给 `handleTruncationError()`，能打捞出已缓冲文本就记为 `truncated` 结束原因，打捞失败才作为 error 事件上抛（`ClaudeCodeRuntimeDriver.ts:455-467`）。

依据：
```text
../../cherry-studio/src/main/ai/runtime/aiSdk/params/buildAgentParams.ts:417-435
../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:92,203-227,688-690,888-894,1067-1138,1316-1327
../../cherry-studio/src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:145-158,341-348,455-478
../../cherry-studio/src/main/ai/runtime/claudeCode/ToolApprovalRegistry.ts:42-83
../../cherry-studio/src/main/ai/runtime/claudeCode/streamAdapter.ts:245
```

## 7. 审批与策略

### 7.1 普通聊天 MCP：`disabledTools` / `disabledAutoApproveTools`

MCP 来源规则匹配函数（`mcpSourcePolicy.ts:22-29`）同时支持四种写法：裸工具名、工具内部 id、完整 wire id（`mcp__server__tool`）和 server 级通配符（`mcp__server__*`）。禁用判定优先于强制提示判定（`mcpSourcePolicy.ts:39-47`：先返回 disabled，未禁用时才检查 prompt）；单测 `mcpSourcePolicy.test.ts:32-42` 显式验证了这一优先级。

这套匹配语义在 **两条路径都复用**：普通聊天直接据此驱动 AI SDK 的审批需求；Claude Code 侧把结果映射为来源审批，再在 `toolRules.ts:68-73` 的来源判定中赋予**最高优先级**。即便权限模式为 bypassPermissions，只要 MCP server 自身配置的 disabledAutoApproveTools 命中，仍然强制 prompt；来源判定发生在该权限模式判断之前（`toolRules.ts:75-95`）。

### 7.2 Claude Code 的 permission mode 优先级实现

Claude 的工具访问判定按固定顺序逐条短路，命中即返回（`toolRules.ts:75-95`）：
1. 该调用命中 MCP server 级的强制审批配置时直接判为需要询问，任何权限模式都盖不过这一条；
2. 权限模式为 bypassPermissions 时，工具本身按自动放行处理；
3. 权限模式为 acceptEdits 且工具属于编辑类集合（Edit、MultiEdit、NotebookEdit、Write）时，判为自动放行；
4. 只读类工具（Read、Glob、Grep、NotebookRead、Task、TodoWrite）在任何权限模式下都判为自动放行；
5. 以上都不命中则判为需要询问。

工具调用判定（`toolRules.ts:108-126`）在上述基础上额外处理 acceptEdits 模式下 Bash 命令首词命中 `mkdir/touch/mv/cp` 时也降级为 auto——这是**唯一**允许该模式免审批执行 Bash 的路径，命令解析仅取空格分隔的首个 token，对 `; rm -rf /` 这种拼接命令不做进一步解析（因为只看首词）。

调用回调之外还有统一前置守卫。`buildClaudeCodeHooks` 在 PreToolUse 阶段对声明式规则表求值，禁用、拒绝、必审与越界 ask 共用这条执行路径；命令改写、上下文和 steer 注入另由机械 hook 处理。SDK 自动允许路径可能跳过 canUseTool，因此必须保留这层守卫；Full Access 只跳过规则显式声明可豁免的交互效果，不能跳过硬拒绝。依据：[hooks.ts:84–147](../../cherry-studio/src/main/ai/runtime/claudeCode/hooks.ts#L84-L147)、[guardRules.ts](../../cherry-studio/src/main/ai/runtime/claudeCode/guardRules.ts)。

依据：
```text
../../cherry-studio/src/shared/ai/tools/mcpSourcePolicy.ts:22-47
../../cherry-studio/src/shared/ai/tools/__tests__/mcpSourcePolicy.test.ts:32-42
../../cherry-studio/src/shared/ai/claudecode/toolRules.ts:30-126
../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:896-950
```

### 7.3 审批桥的 IPC 往返与持久化

普通聊天 MCP 审批复用 AI SDK 原生 approval 状态机（请求态与应答态两个取值），持久化落在消息 parts 字段里。
Claude Code Agent 审批走独立的内存注册表 `toolApprovalRegistry`，按审批 id 记录挂起项，应答入口在主进程（`AiService.ts:241-354`）；两条路径共享同一个 renderer 侧审批桥和 IPC 方法名 `ai.tool.respond_approval`，主进程分发逻辑不同：

1. 先尝试 Agent Session 运行时注册表。流内审批解除 overlay 后唤醒 SDK；独立消息审批必须携带锚点消息 ID，先把决定应用到匹配的持久化卡片，再解除内存等待。依据：[AgentSessionRuntimeService.ts:1587–1629](../../cherry-studio/src/main/ai/agentSession/AgentSessionRuntimeService.ts#L1587-L1629)。
2. 未命中则走 MCP 路径：`messageService.applyToolApprovalDecisions()` 把决定写入 DB 消息 parts（事务化，防止多工具同轮并发审批互相覆盖），全部审批决定完成后才 `AiStreamManager.dispatch({trigger:'continue-conversation'})` 恢复流。

同一回复请求多个工具审批时，响应一个请求会把审批指针推进到下一个挂起请求——不再因响应当前可见请求而隐藏其余仍在等待的审批 UI。

运行时按“当前回合是否交互”与“是否仍有应答者”分别判断流内卡片和独立消息。父回合结束仍有后台应答者时可继续等用户，完全无人应答或没有审批发射器时才拒绝；拒绝理由可回传原生层。依据：[settingsBuilder.ts:566–623](../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts#L566-L623)。

### 7.4 "always allow" 的写回位置

普通聊天 MCP：审批面板把该工具名从 server 的 `disabledAutoApproveTools` 数组移除，PATCH 回 MCP server 服务，由主进程持久化到数据库（`useToolApproval.ts:108-120,136-146`）。
**Claude Code Agent 没有对应持久化机制**：同一文件的注释说明非 MCP 工具没有这类 store，自动批准动作只在存在 MCP 工具描述符时暴露，否则会渲染出一个只生效一次的按钮，因此代码直接不渲染。
原生工具（Bash/Write 等）每次审批都只能逐次点击，没有记住选择的能力；要长期放行，只能改 Agent 设置里的禁用工具，或整体切换权限模式。

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
- Bash 工具在 Windows 上依赖 Git Bash：解析器从 `git.exe` 的安装位置反推 `bash.exe`，依次识别标准 Git、便携版 Git 与 MSYS2 三种布局；都找不到时退回 `CLAUDE_CODE_GIT_BASH_PATH` 环境变量，再失败就放弃（`commandResolver.ts:384-476`）。因此 Windows 上的 Bash 能力**取决于本机是否装了 Git for Windows**，与 macOS、Linux 上的原生 shell 行为不同。
- 命令解析优先用系统已装的 `npx`、`uvx`、`uv`，找不到才用打包内置的版本；Windows 下还单独处理了 `bun` 不接受代理设置的已知问题，启动前会清掉代理环境变量（`McpRuntimeService.ts:503-594`）。
- filesystem server 在比较两个路径前先做平台归一：Windows 上转小写再比，其余平台保持原样（`filesystem/types.ts:44-46`）。这是路径穿越检查里唯一按平台分叉的地方。

### in-memory server 实际访问范围
- **filesystem**：范围 = `resolveFilesystemBaseDir(args, envs)` 返回值，默认回退到 `application.getPath('feature.mcp.workspace')`（应用私有工作区），用户若显式配置 `args[0]` 或 `WORKSPACE_ROOT` 可扩大到任意目录（见 §5）。
- **python**：`PythonServer`（主进程 in-memory MCP）本身不执行代码，而是通过 IPC 把脚本转发给 `PythonService`（主进程），后者再通过 IPC 把请求转给 **renderer 进程里的一个 Web Worker**（`PyodideService.ts:34-57`，`new WorkerModule.default()`），由该 Worker 内的 Pyodide（Wasm）实际运行 Python。也就是说 `python_execute` 这一个工具调用要跨越「Claude Code/MCP 调用方 → 主进程 PythonServer → 主进程 PythonService → IPC → renderer PyodideService → Web Worker → Pyodide」六层，执行沙箱边界落在 Wasm + Web Worker，而不是主进程本身——这与其余 in-memory MCP server（memory/fetch/filesystem/browser 均在主进程直接执行）架构不同，是本次阅读中发现的一处架构差异。Pyodide 默认无法访问真实文件系统/网络（除非显式桥接），本次未继续深挖 Worker 侧是否暴露了任何 postMessage 桥接能力回主进程或 Node API，**标记为待验证**。
- **browser**：`persist:default` 是**全局共享分区**（README 自述），意味着同一台机器上所有触发过 browser MCP 的会话/工具调用共享同一份登录态数据；`execute` 工具可执行任意 JS，且默认 `showWindow:false`（无头），用户不会看到页面在做什么。

依据：
```text
../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:392-436,470-630
../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:408-429,580-587
../../cherry-studio/src/main/utils/commandResolver.ts:384-476
../../cherry-studio/src/main/ai/mcp/servers/filesystem/types.ts:44-46
../../cherry-studio/src/main/ai/mcp/servers/filesystem/config.ts:1-8
../../cherry-studio/src/main/ai/mcp/servers/browser/README.md:16
../../cherry-studio/src/main/ai/mcp/servers/python.ts:82-117
```

## 9. 结果处理与回注

- **格式**：MCP 工具结果统一是一个内容数组，元素类型为文本、图片、音频或 resource。普通聊天用一个摘要函数把多模态内容压成模型可读文本：图片和音频替换成 `[Image: ...]` 这类占位符，二进制 resource 同理，图片本身不会进入模型上下文占 token（`toolResponse.ts:19-54`）。Claude Code 侧的进程内 MCP 另有自己的结果转换（`cherryBuiltinTools.ts:177-188`），图像生成结果以文本加图片的形式一起交给模型，base64 图像随文本进入内容数组，模型能拿到图片本身。
- **截断**：渲染层默认按 5 万字符截断，超限时退到最近的换行处切；换行位置若落在 80% 阈值以内就直接硬切（`truncateOutput.ts:51-72`）。这层截断只作用于界面展示，回注给模型的完整内容长度不受它约束。模型侧的长度限制落在工具**输入**的 JSON 累积上（1MB 上限），输出侧没有找到真正影响上下文 token 的显式截断逻辑，**标记为待进一步验证**。
- **多模态**：结果里出现图片、音频或二进制 resource 时，判断函数返回真，渲染层据此选用图片查看器一类专用 UI（`toolResponse.ts:6-13`）。
- **拒绝、超时与取消的结果形态**：
  - MCP 侧：调用被禁用时执行入口直接抛错，最终以 `output-error` 回到模型（`McpRuntimeService.ts:1097`）；
  - Claude Code 侧：调用回调返回拒绝时，SDK 层面呈现为权限拒绝，适配器用单独的集合跟踪这类调用，与真正执行失败的 `output-error` 区分开；
  - 取消：取消信号在调用回调与审批注册两处都会检查，注册时若信号已中止则立即判为拒绝（`settingsBuilder.ts:744-746`、`ToolApprovalRegistry.ts:42-45`）；
  - 流被打断时的打捞：`handleTruncationError()` 尝试把已经产生的部分文本保留为 `truncated` 结束原因，避免整段丢弃（`ClaudeCodeRuntimeDriver.ts:455-467`）；它依赖的 `isClaudeCodeTruncationError` 判定逻辑本次没有展开全读，触发条件是否完整**标记为待验证**。

依据：
```text
../../cherry-studio/src/renderer/components/chat/messages/tools/toolResponse.ts:1-54
../../cherry-studio/src/main/ai/mcp/servers/cherryBuiltinTools.ts:73-79,148-188
../../cherry-studio/src/renderer/components/chat/messages/tools/shared/truncateOutput.ts:1-72
../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:1097
../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts:744-746
../../cherry-studio/src/main/ai/runtime/claudeCode/ToolApprovalRegistry.ts:42-45
../../cherry-studio/src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:455-467
```

## 10. 内建工具完整清单

### 10.1 Claude Code Agent Registry（`CLAUDE_TOOL_DEFS`）

| 工具名（runtime name） | 曝光级别 | 用途 | 执行位置 | 默认是否需审批 | 风险点 |
| --- | --- | --- | --- | --- | --- |
| `Bash` | user | 执行 shell 命令 | SDK 原生子进程 | 是（`default`）；`bypassPermissions`/`acceptEdits`(限 mkdir/touch/mv/cp) 下自动 | 无通用命令沙箱；仍受 SQLite 写保护、全局安装、停滞等前置拒绝规则 |
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
| `mcp__cherry-tools__to_markdown` | user | 本地文档转 Markdown（pdf/office/epub/csv 等） | 同上 | 未显式排除自动批准（走默认规则） | 可读工作区外本地文件，单独开关（新增） |
| `mcp__cherry-tools__cron` | user | 应用内任务调度 | 同上 | 否 | 仅影响 App 内调度，非系统级 |
| `mcp__cherry-tools__notify` | user | 向已连接渠道发通知 | 同上 | 否 | 若外部渠道被 prompt injection 控制可被滥用发消息（影响范围限于已连接渠道） |
| `mcp__cherry-tools__config` | user | 读写 Agent 自身配置/渠道 | 同上 | 否（但 headless 会话下特定 action 被 `headlessConfigMutationHook` 拒绝） | `rename`/`add_channel`等 mutation action 在无人值守场景被拒绝 |
| `mcp__cherry-tools__generate_image` | user | 生成图像 | 同上 | **是**（显式排除自动批准） | 调用外部计费模型 + 写入用户文件库 |
| `mcp__cherry-tools__cli_list`/`…__cli_search` | 未在 CLAUDE_TOOL_REGISTRY 单列 exposure（走 cherry-tools 聚合） | 查询/搜索受管 CLI 清单 | 同上 | 否 | 只读 |
| `mcp__cherry-tools__cli_install` | 同上 | 安装受管 CLI 到隔离 mise 环境 | 同上 | **是**（显式排除自动批准） | 落地新可执行文件到共享 mise 环境 |
| `mcp__agent-memory__memory` | user | 跨会话记忆（FACT.md/JOURNAL.jsonl） | 同上 | 否（`mcp__agent-memory__*` 整体自动批准） | 限定在 `agentDataPath/memory/`，有 symlink 防御 |
| Skills MCP | internal | 搜索与安装市场 Skill | 主进程服务 | 搜索自动，安装 required；Full Access 可豁免 | 安装来源须由该 server 实例的搜索发出，安装后为当前 Agent 启用，详见 11.3 |
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

依据：
```text
../../cherry-studio/src/shared/ai/claudecode/toolRegistry.ts:48-370
../../cherry-studio/src/main/ai/toolApproval/builtinToolPolicyRegistry.ts
../../cherry-studio/src/main/ai/mcp/servers/cherryBuiltinTools.ts:88-146
../../cherry-studio/src/main/ai/mcp/servers/cherryCliTools.ts:8-108
../../cherry-studio/src/main/ai/mcp/servers/cherryKnowledgeTools.ts:1-20
../../cherry-studio/src/main/ai/mcp/servers/skills.ts:47-76
../../cherry-studio/src/main/ai/mcp/servers/assistant.ts:59-238
../../cherry-studio/src/renderer/pages/settings/McpSettings/builtinMcpServers.ts:23-158
../../cherry-studio/src/main/ai/mcp/McpRuntimeService.ts:397-421
```

## 11. 扩展机制

### 11.1 用户配置的 MCP

MCP 客户端已迁到 `@modelcontextprotocol/client` 2.x（与 `core`/`server` 2.x 同版本族，旧的 `@modelcontextprotocol/sdk` 1.32 仍在依赖里），并支持 SDK v2 的交互式请求：server 可以在调用中途向客户端发起请求，宿主按工具审批同一套通道应答，交互请求与普通工具结果分开处理。

支持四种 transport：

| transport | 实现 | 说明 |
| --- | --- | --- |
| `stdio` | `StdioClientTransport` | 真实子进程 |
| `sse`、`streamableHttp` | Electron `net.fetch` | 网络传输 |
| 内建 server | `InMemoryTransport` | 仅内建 server 使用 |

`sse` 与 `streamableHttp` 之间有**单向一次性回退**：配置为前者但服务端返回 405（表明其实是 Streamable HTTP），或配置为后者遇到 404/405，会自动改用另一种 transport 重试一次。
鉴权失败（401/403）与服务端 5xx 不触发回退，以免掩盖真实的鉴权或服务端错误（`McpRuntimeService.ts:99-117`）。

OAuth 走 `McpOAuthClientProvider` + 本机临时 `CallBackServer`（5 分钟超时）完成授权码交换，token 落盘在 `feature.mcp.oauth/<md5(baseUrl)>_oauth.json`，`removeServer()` 时仅在没有其他 server 共享同一 `baseUrl` 才清理该文件（避免误删共享凭据）。

### 11.2 In-memory factory

`createInMemoryMcpServer`（`factory.ts:17-57`）是一张 `switch` 分派表，按内建 server 名常量选择实例化哪个 Server 类，不认识的名字直接抛错。这是一份**硬编码白名单**，用户不能通过配置注入任意 in-memory server 类型，只能调整已知类型的参数与环境变量。

### 11.3 Skills 市场与信任边界

Skills MCP 只暴露搜索与安装两项操作。`search_skills` 可查询多个市场或解析明确的 GitHub Skill 地址，把返回的安装来源记入该 server 实例的集合；`install_skill` 只接受本实例搜索曾返回的精确来源，否则拒绝。安装成功后调用 Skill 服务为当前 Agent 启用。创作由 Skill 编写器把文件写入专属 Skill 目录，服务随后协调登记，MCP 中没有旧的 init/register action。依据：[skills.ts:39–138](../../cherry-studio/src/main/ai/mcp/servers/skills.ts#L39-L138)。

安装在执行前经过跨运行时审批策略：搜索自动放行，安装标为 required。Claude 的前置工具守卫与调用回调都消费这份策略；Pi 从同一注册表生成必审集合，故 Pi 的 auto 模式也需批准，Full Access（`bypassPermissions`）可以豁免此项。无人应答的渠道/定时回合在普通权限模式下拒绝必审安装。依据：[builtinToolPolicyRegistry.ts:113–118](../../cherry-studio/src/main/ai/toolApproval/builtinToolPolicyRegistry.ts#L113-L118)、[guardRules.ts:220–233](../../cherry-studio/src/main/ai/runtime/claudeCode/guardRules.ts#L220-L233)、[PiRuntimeConnection.ts:215–246](../../cherry-studio/src/main/ai/runtime/pi/PiRuntimeConnection.ts#L215-L246)。

Skill 是指令文本与支持文件，其内容可引导模型使用会话已有权限；安装审批与来源约束不构成执行沙箱。本次未展开安装服务的签名或恶意内容扫描实现。

## 12. 子 Agent 与任务委派

- SDK 原生 Agent/Task 创建子任务，配套任务工具管理查询、停止与结果读取。Cherry 回调通过 SDK 提供的 agentID 识别后台子 Agent，使普通调用与显式 ask/required/用户输入分开处理；禁用和前置拒绝规则仍按会话实时读取。SDK 内部如何转发每一种原生子 Agent 调用未展开，不能据同一会话 ID 推定所有子任务拥有完全相同权限。依据：[settingsBuilder.ts:513–598](../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts#L513-L598)、[hooks.ts:90–114](../../cherry-studio/src/main/ai/runtime/claudeCode/hooks.ts#L90-L114)。
- `EnterWorktree`/`ExitWorktree` 提供 git worktree 切换能力（仅 `.git` 存在时可用），实现在 SDK 内部（Cherry 只声明了工具名/描述/条件门控，未发现自己的 worktree 操作代码），因此其安全边界完全依赖 SDK 自身对 `git worktree add/remove` 命令的封装是否安全。
- `Workflow`（user，曝光可见）用于编排"多步工作流并调度子 Agent"，是 registry 里唯一被标记 `user` 曝光的编排类工具，意味着用户可以在 UI 里单独禁用它。
- 后台任务事件由会话级适配器持续消费，生命周期状态按 taskId 合并到共享缓存；子 Agent 工具流有独立消息投影。交互式后台审批可持久化为独立 assistant 行，父回合结束后仍能分别等待用户，普通后续消息也可继续提交。主进程内存注册表持有仍待解决的授权，消息行是交互投影，两者不可等同为跨重启恢复授权。依据：[ClaudeCodeRuntimeDriver.ts:752–786](../../cherry-studio/src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts#L752-L786)、[AgentSessionRuntimeService.ts:2692–2805](../../cherry-studio/src/main/ai/agentSession/AgentSessionRuntimeService.ts#L2692-L2805)。
- 审批发射器随连接而非单回合存活；请求采用流内卡片还是独立消息由当前应答能力决定。无应答的渠道/定时回合会拒绝需要真实用户输入或仍需批准的工具；普通子 Agent 请求可以自动通过，但显式 ask/deny 守卫继续生效。依据：[settingsBuilder.ts:530–623](../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts#L530-L623)。

## 13. 外部渠道的系统安全提示

外部渠道的内容约束与实际执行权限分层处理：入站内容先由渠道处理链标记与消毒；执行时按工具曝光、运行时权限模式和当前应答能力判定。此处聚焦执行审批，渠道内容包装的具体模板与逐平台往返留在外部协作调查范围。

系统提示提供模型侧内容约束；执行端仍由实时工具曝光、前置守卫和审批决定是否允许调用。渠道会话的实际权限由当前回合是否有人应答、工具是否标为 required/delegation、权限模式和已挂载 server 共同决定；系统提示与自动允许名单是这条判定里的两层输入。网页搜索和抓取的自动允许选择与安装、委派和文件写入的审批分别记录。

**渠道审批按当前回合判断**：是否无人值守取自运行时交互状态，渠道关联只决定入口归属，免审批资格仍按当前回合判定。渠道或定时 headless 回合可自动通过一般后台请求；需要用户作答的工具、required 安装/变更工具和显式 ask 规则仍受守卫约束。没有应答者时拒绝这些交互；Full Access 可豁免标为 lift 的 required 工具，仍受不可豁免规则约束。有人交互的同一渠道关联 Session 则保留正常审批。依据：[settingsBuilder.ts:530–598](../../cherry-studio/src/main/ai/runtime/claudeCode/settingsBuilder.ts#L530-L598)、[guardRules.ts:198–233](../../cherry-studio/src/main/ai/runtime/claudeCode/guardRules.ts#L198-L233)。

网页搜索与抓取依然属于显式自动批准的只读工具，模型看到的外部内容需依赖提示与上下文不可信输入标记共同约束；这项选择不取消文件、命令、安装与委派各自的执行端规则。新增跨会话创建/发送采用 delegation 策略：交互会话按权限模式批准，无人值守回合拒绝再次委派。依据：[builtinToolPolicyRegistry.ts:85–118](../../cherry-studio/src/main/ai/toolApproval/builtinToolPolicyRegistry.ts#L85-L118)、[builtinToolPolicy.ts:19–26](../../cherry-studio/src/main/ai/toolApproval/builtinToolPolicy.ts#L19-L26)。

## 14. 与消息渲染器笔记的交叉点

参考笔记（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`）确认：工具调用统一表示为 AI SDK `ToolUIPart`。
其状态字段覆盖输入流式、输入可用、审批请求、审批应答、输出可用与输出出错等取值。
审批卡片由 `useToolApproval` 读取 `part.approval?.id` 渲染，卡片的通过、取消与自动批准三个动作最终都经 `useToolApprovalBridge` 发起真实 IPC 调用。

**模型能否伪造审批 UI**：
- **不能伪造出真正可点击、能生效的审批卡片**——卡片查找走渲染器自己解析的 parts 映射（数据来自 AI SDK 结构化的 `UIMessage.parts`，由主进程流式 chunk 组装；模型只能通过工具调用协议本身产生这类 part，纯文本 `text` part 里注入不出 `tool-*` 类型）；`approvalId` 来自主进程审批注册表与数据库的持久化决策，模型输出的普通文本伪造不了这个字段。
- **能造成视觉混淆**：模型在**普通文本正文**里完全可以输出形似"⚠️ 需要您批准: 是否允许执行 rm -rf /?"这样的字符串，但这段文本会被当作普通 Markdown 渲染（消息渲染器笔记确认了 Markdown 有白名单净化），不会被识别为真实的审批 part，也不会有 `confirm`/`cancel` 按钮——只是纯文本视觉欺骗，用户如果看不出区别可能误以为需要"回复"该文本从而触发下一轮对话（一种社会工程学风险，而非技术层面的权限绕过）。这一点消息渲染器笔记未覆盖，属于交叉发现。
- 工具块折叠/展开、`ToolBlockGroup` 聚合等渲染细节与审批状态无关，纯 UI 呈现问题，不构成安全边界。

依据：`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`（工具渲染章节）、`../../cherry-studio/src/renderer/components/chat/messages/tools/chooseTool.tsx:271-294`、`../../cherry-studio/src/renderer/components/chat/messages/tools/hooks/useToolApproval.ts:1-146`。

## 15. 当前 Agent 运行时与工具扩展

Agent 会话已不再只由 Claude Code 承担。运行时注册表同时接入 Claude Code、Pi 与 Pi-Durable；三者都通过统一的会话服务、模型兼容性判断和审批注册表交给界面，但各自维持独立的协议适配与工具桥。Pi 的 `codemode` 把工具 schema 转为 TypeScript 供模型编排调用，工具搜索与延迟加载在原生侧完成；Pi-Durable 复用同一套原生工具安装，同时把会话与命令收据持久化，使后台子 Agent 可跨重启继续。跨会话投递由 `AgentSessionDeliveryService` 持久化，子 Agent 的创建、发送和结果因此成为可恢复的工具结果，而不是仅存在于当前流中的临时事件。

内置 MCP 还包含 `install_mcp_server` 与 `prepare_diagnostic_report`。前者把符合输入约束的服务写入 MCP 配置，仍经内建工具策略与审批链处理；后者为 Support/聊天错误生成诊断报告草稿，工具输入只接受问题描述，默认工具集合与渠道会话均可见。它们扩展的是工具目录的管理与支持面，不绕过既有注册和审批边界。依据：`src/main/ai/mcp/servers/mcpManager.ts`、`assistant.ts:247-350`、`src/main/ai/agents/builtin/builtinAgentCapabilities.ts:62-63`。

工具执行的可靠性边界也有三处明确收紧：用户拒绝工具时填写的理由会作为审批结果回传给原生层，模型能看到"为什么被拒"；MCP 工具结果中的超大图片在进入 Agent 前调用 `clampImageForModel` 压缩；filesystem MCP 与 Claude Code 路径都以 realpath 或最近存在父目录拒绝逃出工作区的悬空符号链接。依据：`src/main/ai/mcp/McpRuntimeService.ts`、`src/main/ai/mcp/servers/filesystem/types.ts`、`src/main/ai/runtime/claudeCode/pathContainment.ts`、[builtinToolPolicy.ts](../../cherry-studio/src/main/ai/toolApproval/builtinToolPolicy.ts)。

## 16. 未验证事项与后续调查缺口

1. `streamAdapter.ts` 里工具输入的两个阈值（1MB 上限与 100KB 告警）超限后究竟走截断、报错还是静默丢弃，本次没有追完整。
2. SDK 报出的 `error_max_turns` 终止原因在渲染层怎么呈现，未验证。
3. 截断判断与文本打捞两个函数（`handleTruncationError()`、`isClaudeCodeTruncationError()`）的完整触发条件没有全读。
4. agent-teams 的三个工具（`SendMessage`、`TeamCreate`、`TeamDelete`）实际运行行为与权限模型没有深入验证；已确认的只有两点：它们声明为内部工具，且由环境变量门控，而该变量在会话构建时被无条件打开。
5. Skill 安装时对下载内容的校验（签名、来源、恶意内容扫描）没有展开阅读。
6. Python 执行落在 renderer 进程的 Web Worker 里，该 Worker 是否存在把结果桥接回主进程或 Node API 的 postMessage 通道，未验证。
7. 子 Agent 的嵌套调用（由 Task、Agent 两个工具触发）是否与父会话共用同一份调用回调和禁用策略，还是另有独立策略，取决于 SDK 内部实现；Cherry 代码里没有找到相关证据，需要读 `@anthropic-ai/claude-agent-sdk` 包的源码才能确认。
8. 工具 id 双轨制（§2.2）下，legacy 名称型 id 与 AI SDK catalog 身份 id 在哈希截断边界重合时能否正确换算归属，没有做过穷举验证；拼音罗马化对日文、韩文 server 名会退化成摘要，这条退化路径也没有专门测试（`mcpToolId.ts:20-32` 的注释自述了这一退化）。
9. 三个第三方 server（`didiMcp`、`nowledgeMem`、`flomo`）的具体工具清单与数据流向没有展开阅读，本次只确认了注册与连接方式。
10. 仓库测试与构建均未运行（`node_modules` 未安装，Node 版本也不匹配），全部结论来自静态源码阅读，没有运行时验证。
