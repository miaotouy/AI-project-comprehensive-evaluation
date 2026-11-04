# Cherry Studio 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：静态复核 Agent Session、Claude Code / Pi / Pi-Durable 驱动注册、Code CLI 管理与终端启动、工具注册、工作区链路、IM 渠道层与远程访问服务；复用 Agent 角色、Agent 工具和独特功能笔记；未运行各 runtime、CLI 或 IM 平台
>
> 调查范围：作为外部执行体的 Agent runtime 会话、受管 Code CLI 与宿主工具面；作为外部控制表面的 IM 渠道与远程访问设备；排除普通 Assistant、普通 MCP server 和 Mini Program
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 有三条独立的完整主链，均为 `主链确认`（静态证据）：

- **外部执行体（进程内 runtime）**：`AgentSessionRuntimeService` 把 Agent runtime 作为独立会话执行者接入，覆盖工作区、消息持久化、流事件、工具审批和取消。runtime 驱动为三种：`claude-code`、`pi`、`pi-durable`，由 Agent 行的 `type` 字段选择。
- **外部执行体（受管 CLI）**：Code CLI 管理层为十余个第三方编程代理写配置、准备二进制并在本机终端中拉起，DeepSeek Harness 已从 Agent runtime 迁到这一面。
- **外部控制表面**：IM 渠道层（discord / dingtalk / feishu / qq / slack / telegram / wechat / wecom 八平台）与远程访问设备把 Agent Session 作为可由宿主之外发起、回答、接管和停止的交互对象。

普通聊天中的 MCP server 只属于 Agent 工具。只有具备独立 runtime、进程或协议生命周期的路径才进入本类目。

## 接入角色与系统边界

- **进程内 Agent runtime**：三种驱动在 `registerRuntimeDrivers` 中一次性注册（`src/main/ai/runtime/registerDrivers.ts:149-152`），runtime 类型取值由 `AGENT_TYPES` 固定为 `claude-code`、`pi`、`pi-durable`（`src/shared/data/api/schemas/agents.ts:45`）。会话按 Agent 行的 `type` 选择驱动，驱动注册表只按类型查找。
- **驱动与实现的分离**：每个驱动只做主进程侧适配，原生执行由内部包承担——Claude Code 走 `@anthropic-ai/claude-agent-sdk`，Pi 与 Pi-Durable 分别对应 `packages/agent-runtime-pi` 与 `packages/agent-runtime-pi-durable`，产品规则由与 harness 无关的 `packages/agent-behavior` 承担。Cherry 持有 Agent Session 产品对象、workspace、消息后端、工具曝光策略、审批 UI 和事件投影。
- **受管 Code CLI**：`CodeCliService` 维护一组外部 CLI 预设（Claude Code、Codex、opencode、openclaw、DeepSeek Harness、Gemini CLI、Qwen Code、Kimi Code、Qoder、GitHub Copilot CLI、Pi、Hermes、MiniMax Code、Antigravity），负责写各家配置文件、准备二进制与登录，并在用户选择的终端应用中启动。
- **外部控制表面**：IM 渠道（`src/main/ai/channels/`）以数据库渠道行保存连接，适配器覆盖八平台；远程访问服务（`src/main/services/remoteAccess/`）让已配对设备经加密 WebSocket 使用桌面 Agent。
- **宿主作为工具面**：`src/main/ai/mcp/servers/assistant.ts` 以 SDK MCP 形式注入会话，提供页面导航（路由白名单）、产品信息、创建 Agent、应用设置等工具，外部 Agent 可操作宿主应用。

## 完整主链

```text
进程内 runtime 会话
  创建或打开 Agent Session
    -> 解析 Agent 配置、workspace 与 runtime 类型
    -> claude-code：settingsBuilder 组装模型、环境变量、MCP、权限模式与 hooks
    -> pi / pi-durable：建立运行时连接，经内部 gateway 绑定模型
    -> 驱动 connect() 返回 Native 会话句柄，工具循环与上下文计费由原生实现持有
    -> 流事件投影为 Cherry 消息块并写入 AgentSessionMessageBackend
    -> 工具审批、文件树与工作区变化投影到 UI；abort 终止当前回合

受管 Code CLI
  选择 CLI 预设 -> 写入该 CLI 的 Provider/模型配置 -> 检查或安装二进制
    -> 选择终端应用与工作目录 -> spawn 终端并注入 gateway 环境变量
    -> 用户在外部终端内交互，Cherry 只保留配置与状态

远程访问设备
  桌面开启局域网访问 -> 发布网关端口与身份 -> 设备经配对邀请声明并取得 token
    -> 设备在 /v1/remote/connect 升级为加密 WebSocket
    -> agent.* RPC：列会话/消息、发消息、订阅流、取消
    -> 服务端按会话日志推送增量与 checkpoint，断线后可续传

IM 渠道
  平台回调经 ChannelManager 路由到对应 adapter
    -> handleIncoming 校验并按渠道会话定位 Agent Session
    -> startAgentSessionRun 流式执行，结果回投原线程
    -> /new、/compact、/help 命令与排队、暂停控制
```

## 身份、协议与状态映射

Agent Session 使用独立于普通 Topic/Assistant 消息路径的持久化后端，workspace 是 Agent 文件操作的事实边界。runtime 侧的原生会话标识存在 Agent Session 行上：Claude Code 用 SDK session，Pi 用原生 Pi 会话文件，Pi-Durable 另有一套持久化命令收据，因此同一 Cherry Session 在重启后仍能续接原生上下文。

远程访问的身份链是设备级的：桌面生成配对邀请，设备认领后取得访问 token，设备身份以 Ed25519 密钥文件表示；配对时同时批准 Agent 能力与配置能力，两者之后各自独立授权。连接建立走 hello/authenticate/refresh/ping，请求方法与协议版本来自 `packages/remote-protocol`。

IM 渠道的身份绑定到平台账号/线程与渠道行；协议层面走 OpenClaw 家族兼容实现：Feishu 适配器实现 `openclaw-lark` 的设备码注册端点，WeChat 适配器兼容 openclaw-weixin 的双编码方案，`FlushController` 的注释自述启发自 openclaw-lark。Agent Session 归属用户、Workspace 与账号体系之间的绑定关系本次未展开。

## 执行、回流与控制语义

Claude Code 路径由 `ClaudeCodeStreamAdapter` 解析 SDK 的 `stream_event/system/result` 与 tool use block，投影为 Cherry 消息块；SDK 原生工具在主进程外部 runtime 执行。Pi 与 Pi-Durable 路径由原生实现持有工具循环、上下文计费与压缩，Cherry 通过 behavior 端口提供审批、提问、模型选择、摘要与大输出存储，并把内容增量交给统一的消息读取器再分发。取消由 Agent Session runtime 的 AbortController 进入对应实现；工具并发、子 Agent 与 Team 行为主要由原生实现决定，Cherry 不重写其调度器。

远程访问的流式回流不是逐事件直传：服务端把同一消息同一 part 的相邻增量合并（50 毫秒或 2048 个 UTF-16 单元），part 变更与结构性/终止事件先冲刷文本；追加偏移按协议字段增量维护，完成时仍校验全量摘要。历史消息列表支持分页摘要模式，避免超大 `partIds` 数组；会话删除先排空执行，保证终止事件仍在会话存在时送出。

IM 渠道的执行与回流与桌面 Agent Session 共用同一套 runtime 驱动：外部线程消息触发与桌面会话相同的工作区与审批语义，流式结果按平台格式转换后回投。渠道层自带外部内容、工作区文件与输出消毒三类不可信输入防护，外部内容可触发原生工具执行与工作区写入，属于本类目必须关注的副作用面。

## 权限、凭据与治理边界

默认权限模式下，Bash 等原生工具逐次审批；`bypassPermissions` 会显著放宽执行。文件类工具由 workspace path hook 限制在工作区或 Agent 数据目录。MCP 工具可采用自身自动审批配置，但不能把普通 MCP 的权限模型等同于原生工具。Pi 侧没有 plan 模式，其 `auto` 是 Cherry 自己的规则门，与 Claude 的模型侧分类器同名不同机制。

模型凭据集中在宿主：Pi 与 Pi-Durable 的每次原生 provider 调用都落到 Cherry 的内部 gateway，由宿主持有上游凭据与计费；受管 Code CLI 则把 gateway 的模型 id 与占位密钥写入各 CLI 配置，凭据本体不出现在 CLI 配置里。远程访问的 token 按能力分权，LAN 守卫只放行远程访问的升级路径，其余 HTTP 路由一律要求 loopback。

## 相邻类目交接

- Assistant 与 Agent Session 两套角色对象见[Agent 角色笔记](../Agent角色/Cherry-Studio-Agent角色配置调查笔记.md)。
- 工具曝光、审批和路径边界见[Agent 工具笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)。
- workspace 的文件树、编辑器和冲突检测见[生成式输出与运行时笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)。
- Code CLI 与 Provider 配置写入、API Gateway 路由见[LLM 渠道管理笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md)。

## 当前外部执行体补充

DSH 不再是一种 Agent runtime：原 `runtime/dsh` 驱动与 bridge 已移除，DeepSeek Harness 变成 Code CLI 预设之一，由 `DeepSeekHarnessService` 负责网关配置写入、子进程启动/停止与状态发布（IPC 为 `deepseek_harness.start/stop`）。它与其它 Code CLI 的差别是带自己的权限模式与启动超时管理，但执行体仍在本机终端之外，不进入 Agent Session 的消息流。

Pi 一侧的接入面在本次快照中变得更宽：前台子 Agent 用原生会话 fork，后台子 Agent 从原生存储继续，子会话可以持久化并独立流式回投；Pi-Durable 把会话状态与命令收据落到可恢复存储，并在数据目录迁移后仍能恢复。两者的模型绑定共享同一 gateway 绑定逻辑，每个新增模型有独立的原生 provider 注册，避免同 Provider 下多个模型的请求选项互相覆盖。

运行时连接会把本次 reasoning effort 纳入连接签名或 reconcile 条件，并为 OpenCode 保留会话头，使同一 Cherry Session 的上游会话身份稳定而不同 Session 相互隔离。后台或目标轮次以 `background-work`、`goal-round` 等 origin 写入运行状态，界面可区分用户回合与运行时主动回合。

## 已确认边界与未验证事项

- 进程内 runtime 为三种（Claude Code / Pi / Pi-Durable），均为静态主链确认，不称为统一 CLI Agent 管理平台；受管 Code CLI 与它们不是同一层，前者只写配置并在终端拉起进程。
- IM 渠道层为八平台静态主链确认，逐平台回调、签名与真实往返未运行验证。
- 远程访问的配对、加密 WebSocket、日志续传与分页协议均有单元/兼容测试覆盖，但真实移动端往返、网络切换与并发接管未运行验证。
- SDK session resume、崩溃恢复、版本兼容和真实进程取消未运行验证。
- `bypassPermissions`、实验性 Agent Teams 与工作区路径限制的组合行为未实测。
- IM 渠道的凭据刷新、渠道停用/重连与不可信输入防护的真实效果未运行验证。

## 关键源码索引

- `src/main/ai/agentSession/AgentSessionRuntimeService.ts`
- `src/main/ai/agentSession/persistence/AgentSessionMessageBackend.ts`
- `src/main/ai/runtime/{registerDrivers,registry,types}.ts`（三种驱动注册与查找）
- `src/main/ai/runtime/claudeCode/{ClaudeCodeRuntimeDriver,ClaudeCodeBinaryService,settingsBuilder,streamAdapter}.ts`
- `src/main/ai/runtime/pi/{PiRuntimeDriver,PiRuntimeConnection,gatewayModelBinding,modelInjection}.ts`
- `src/main/ai/runtime/piDurable/{PiDurableRuntimeDriver,PiDurableRuntimeConnection,durableDesktop,durableMcp}.ts`
- `packages/agent-runtime-pi/`、`packages/agent-runtime-pi-durable/`、`packages/agent-behavior/`（原生执行与 harness 无关的产品规则）
- `src/main/services/codeCli/CodeCliService.ts`、`src/shared/data/presets/codeCliTools.ts`、`src/shared/types/codeCli.ts`
- `src/main/services/deepSeekHarness/{DeepSeekHarnessService,config}.ts`
- `src/main/services/remoteAccess/{RemoteAccessService,RemoteConnection,RemotePairing,agentJournal,agentHandlers}.ts`、`src/main/features/apiGateway/routes/remote.ts`、`lanGuard.ts`
- `src/shared/data/api/schemas/agents.ts`（`AGENT_TYPES` 与 Agent `type` 字段）
- `src/main/ai/tools/adapters/claudeCode/{agentTools,toolConditions}.ts`
- `src/shared/ai/claudecode/{toolRegistry,toolRules}.ts`
- `src/main/ai/channels/{ChannelManager,ChannelMessageHandler,FlushController}.ts`、`channels/adapters/`
- `src/main/ai/channels/security/{ExternalContentGuard,WorkspaceFileGuard,OutputSanitizer}.ts`
- `src/main/ai/mcp/servers/assistant.ts`
