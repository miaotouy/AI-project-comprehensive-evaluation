# LobeHub 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：静态阅读异构 Agent、Gateway、Connector、Messenger 与 browser MCP 关键源码；复用 Agent 工具和独特功能笔记已确认链路；未运行 CLI、OAuth 或 IM 平台
>
> 调查范围：外部 CLI/Agent runtime 托管（含 SDK/ACP 传输）、业务应用 Connector、Bot 平台/Messenger/设备/浏览器交互表面、Agent Share 访客协作；排除普通模型 Provider、任意 MCP 配置和宿主内建子 Agent
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 在外部执行体、外部应用和外部控制/交互表面三种接入角色上都有实现，且三者从本快照起分属清晰的四层描述符目录：

- `主链确认`：**14 种本地执行体**（Amp、Claude Code、CodeBuddy、Codex、Copilot、Cursor、Devin、Factory Droid、Grok Build、Kimi Code、OpenCode、Pi、Qoder、TRAE）以本地 CLI 形式接入；**4 种 runtime 传输**（`claude-code-sdk`、`cursor-acp`、`droid-acp`、`deepseek-harness`）与它们并列注册但语义不同；OpenClaw/Hermes 属远程任务类，走 gateway 而非本地 JSONL adapter。
- `主链确认`：Connector/Composio 账号与动作权限；CLI Agent 驱动内置浏览器；Bot 平台层安装、回调与 CLI 管理。
- `主链确认`：Agent Share 把 Agent 以链接开放给已登录访客聊天。访客会话与创建者会话分离，拥有主题/回合/花费上限、工具授权、模型与错误信息可见性，以及创建者是否能查看访客会话等治理字段；本快照里分享治理从单一 `shareGate` 拆成 `shareChat` 路由族加运行期 gate。
- `入口确认`：Slack、Discord、Telegram、Feishu/Lark、LINE、QQ、iMessage、WeChat 等平台的安装、绑定、webhook/gateway 和 outbound 已存在；Telegram Guest Mode、Feishu 历史读取与 WeChat 语音解码已有专门入口，但逐平台完整往返仍未运行验证。

执行体的描述符目录现在集中在 `packages/types/src/agent/heterogeneousAgent.ts`：本地 CLI 描述符从 `:78`（amp）到 `:424`（trae），本地 runtime 传输见 `:474` 的 `deepseek-harness`，远程任务描述符在 `:500`（OpenClaw）与 `:510`（Hermes）。注册表与 adapter 实现在 `packages/heterogeneous-agents/src/registry.ts`，该包同时容纳 `adapters/`、`spawn/`、`askUser/`、`builtinMcp/` 与 `codex/`（含由 Codex app-server 协议生成的类型）。描述器与 transport adapter 不是同一层次，因此不应把这些传输名混入本地执行体数量。

## 接入角色与系统边界

| 角色 | 外部对象 | 宿主持有的状态 |
|---|---|---|
| 外部执行体 | 14 种本地执行体、OpenClaw、Hermes | operation、topic、working directory、原生 session id、进程/任务和事件投影 |
| 外部应用 | Connector、Composio 业务账号 | connection、credential、tool catalog、scope、permission |
| 外部控制/交互表面 | Bot 平台、Messenger、设备网关、内置浏览器 | bot binding、webhook secret、步骤/完成回调、installation、binder、线程/用户、device、browser operation |
| 外部控制/交互表面 | Agent Share 访客页 | share、visitor topic、senderId、operation stream、工具授权与配额 |

## 完整主链

```text
Connect Agent / 模型选择
  -> scanHost 扫描命令、版本与登录状态
  -> driver 依描述符组装参数、stdin、图片与工作目录
  -> spawn 本地 CLI，或经 claude-code-sdk / ACP stdio / codex app-server 建会话
  -> JSONL 或协议 stream 进入 AgentStreamPipeline
  -> adapter 归一为 AgentStreamEvent
  -> Chat store 持久化文本、reasoning、tool、todo、subagent、intervention
  -> 保存原生 sessionId 与 cwd，下一轮 resume
  -> UI cancel 终止进程树或平台任务
```

三类传输共用同一条归一管线，但收尾语义不同：`ClaudeCodeSdkAdapter` 只把子类差异压在构造参数上（`runtimeEndStrategy: 'on-transport-close'`、`signalBackgroundTaskCompletion: true`，见 `packages/heterogeneous-agents/src/adapters/claudeCodeSdk.ts`），因为一次 Query 可能报告多个 result，运行期结束以传输关闭为准。ACP 一族（Copilot、Cursor、Devin、Droid、TRAE、DeepSeek Harness）走统一的 `spawn/acpAgentSession.ts` 与 `acpStdioClient.ts`：客户端声明 `ACP_PROTOCOL_VERSION = 1`，把 `session/request_permission` 的 options 数组交给按 agent 排列的偏好层级选择，取消时留 `DEFAULT_CANCEL_GRACE_MS = 2000` 的宽限。Codex 走 app-server 协议，`codex/protocol/generated.ts` 是按协议生成的类型。

OpenClaw/Hermes 不走本地 JSONL adapter。`GatewayConnectionCtr.runHeteroTask`（`apps/desktop/src/main/controllers/GatewayConnectionCtr.ts:518` 起的分发分支）按 topic/task 启动进程，OpenClaw 经 `lh notify` 回传，Hermes 经标准输出与通知接口回流；任务表保存 PID 并支持终止。Gateway 客户端协议抽在 `packages/agent-gateway-client`（`mux/GatewayMuxClient`、`intervention.ts`、`mirroredTerminalEcho.ts`）。

```text
Bot 平台（slack/discord/telegram/feishu/line/qq/imessage/wechat）
  -> lh bot connect 安装/绑定 Agent（微信走二维码登录）
  -> BotCallbackService 校验平台 webhook 或 QStash 队列回调
  -> 关键词触发或命令提交 Agent 运行（execAgent 队列模式）
  -> 步骤进度与完成结果回投平台
```

## 身份、协议与状态映射

本地 CLI 的原生 session id 和工作目录映射到 LobeHub operation/topic；远程任务另映射 task id、topic id、device 与 PID。两类执行体都有独立工具循环，LobeHub 负责适配与观察，不接管其原生工具执行。宿主能注入的能力集中在 `packages/heterogeneous-agents/src/`：`builtinMcp/LobeBuiltinMcpServer.ts` 提供宿主内建 MCP server，`askUser/AskUserBridge.ts` 是 Claude Code `AskUserQuestion` 的本地 HTTP MCP 生产端，`attachedFiles.ts` 处理随轮附件。干预链路仍是 `AgentStreamEvent` 上的 `agent_intervention_request` / `agent_intervention_response` 一对事件，由桥接层把外部 runtime 的结构化提问送到渲染层。

Connector 以个人、Workspace 或 Agent scope 保存持久连接；Messenger installation 绑定 LobeHub 用户与平台账号/线程；设备网关把服务端任务路由到具体桌面设备，并反向把 iMessage 等设备侧消息 API 在桌面上执行（`apps/desktop/src/main/services/imessageBridgeSrv.ts`、`controllers/ImessageBridgeCtr.ts`）；bot 平台绑定以 `lh bot` 命令族和平台回调管理。

## 执行、回流与控制语义

统一事件模型覆盖文本、推理、工具、待办、子 Agent、文件变化、额度、干预和终态。Claude Code/Qoder 可接收临时 MCP 配置；`browserMcpTools.ts` 把下列浏览器操作投给外部 Agent，使其能操作 LobeHub 内置浏览器（工具名带 `browser_` 前缀，如 `browser_navigate`）：

```text
navigate / snapshot / click / fill / press / scroll / screenshot / readPage
```

非 CLI 传输的权限语义分三类（其中 Codex 的 app-server 是 Codex 描述符内部的传输选择，不单独出现在 runtime 适配器注册表里）：

| 传输 | 权限语义 | 超时兜底 |
|---|---|---|
| `claude-code-sdk` | 以 `permissionMode: 'bypassPermissions'` + `allowDangerouslySkipPermissions` 拉 SDK 会话，并用 `CLAUDE_SDK_DISALLOWED_TOOLS` 关掉部分内置工具（`spawn/claudeAgentSdkSession.ts:333-339`） | 空闲超时与任务状态机（`starting`/`running`/`monitoring`/`idle`/`stale`） |
| `codex-app-server` | 携带 `--dangerously-bypass-approvals-and-sandbox` 类标志 | 同上 |
| ACP 一族 | 由 `session/request_permission` 逐请求协商，按 agent 偏好层级自动选 option | 取消宽限 2000ms |

取消由本地进程树终止或 gateway task 终止到达真实执行体。桌面侧每个执行体都有独立 driver（`apps/desktop/src/main/modules/heterogeneousAgent/drivers/` 下 14 个文件），负责参数拼装与本地进程生命周期；另有 `claudeCodeAccounts.ts`、`codexQuota.ts`、`fileStorePort.ts` 处理账号、额度与文件句柄。

Agent Share 的运行由创建者账号承担模型调用，但访客身份被写入 topic 的 `senderId` 并作为 stream owner。本快照中分享面拆成了三块：路由与执行在 `apps/server/src/routers/lambda/shareChat/`（`conversation`、`exec`、`gateway`、`guards`、`runControl`、`runScope`、`upload`、`procedures`），运行期门禁在 `apps/server/src/services/agentRuntime/AgentRuntimeService/shareRunGate.ts`，路由辅助在 `routers/lambda/_helpers/shareVisitorTargetGuard.ts` 与 `agentShareFeatureGate.ts`。访客配额通过 `shareVisitorAbuseGuards.ts` 的 `reserveShareVisitorTopicOrThrow`（`:83`）、`reserveShareVisitorTopic`（`:142`）、`reserveShareVisitorTurnOrThrow`（`:178`）、`reserveShareVisitorTurn`（`:228`）在创建 topic 与写入 turn 时做原子预留；工具可见性由 `shareToolManifest.ts` 与 `grants.ts` 限制，并在 builtin dispatch 再检查一次；访客沙箱不注入创建者 JWT。分享数据结构分化为四张表：`agentShare`、`fileShare`、`documentShare`、`goalShare`（`packages/database/src/schemas/`），仓库另有 `.github/workflows/verify-share.yml` 专门校验分享链路。

产品面（桌面设置与对话界面）会显示已连接 Agent、工作目录和任务/操作视图，并提供干预、取消与 bot/Messenger 绑定入口；CLI 侧 `lh` 命令族在本快照中显著扩张，除 bot/设备/异构 Agent 外还包含 `agent`、`agent-group`、`artifact`、`artifactCanvas`、`channel`、`doc`、`eval`、`kb`、`man`、`memory`、`message`、`model`、`notification`、`plugin`、`project`、`provider`、`read`、`recall`、`resourceUrl`、`search`、`session-group`、`skill`、`thread`、`topic`、`workspace`、`widget`、`acceptance/*` 等子命令。外部 CLI 输出的文本、工具调用和文件变化按事件流进入宿主会话，可触发文件写盘与浏览器操作，属于不可信输入面；其信任边界取决于各 runtime 的权限模型与宿主注入工具的审批，真实提权风险未做运行评估。

## 权限、凭据与治理边界

Connector 支持 OAuth2、bearer、API key 和自定义 header，凭据经 `KeyVaultsGateKeeper` 加密。工具权限为 `auto / needs_approval / disabled`；客户端只拿 manifest，服务端在调用时解密连接凭据。Composio 当前预置业务应用类型清单在 `packages/const/src/composio.ts`，未逐应用运行验证。

外部 CLI 的原生工具权限仍由各 runtime 承担；LobeHub 能观察、审批部分宿主注入工具和展示文件变化，不能由此推断完全统一了所有 CLI 的安全模型。凭据刷新与失效流转机制本次未单独验证。

## 相邻类目交接

- 工具目录、调用与 Connector 权限细节见[Agent 工具笔记](../Agent工具/LobeHub-Agent工具调查笔记.md)。
- 异构 Agent 产品定位、Messenger 与浏览器桥的边界见[独特功能笔记](../独特功能/LobeHub-独特功能调查笔记.md)。
- 宿主内建 `callSubAgent` 属 Agent 角色/工具，不计入本类目。

## 已确认边界与未验证事项

- 14 种本地执行体、4 种 runtime 传输与 2 种远程任务均为静态主链确认，未逐个安装运行；SDK、ACP 与 app-server 传输的真实兼容性未运行验证。
- Agent Share 的服务端访客隔离、配额预留与工具双门禁已静态确认；公开链接、登录跳转、并发配额、商业花费门与访客停止操作未做端到端验证。
- Messenger 逐平台签名、附件、线程映射、审批与完整回复往返未验证；bot 平台层的微信二维码登录、队列回调与逐平台消息格式未运行验证。
- 外部 CLI 进程退出后的会话恢复策略（重连、重放或接管）与断线语义未验证。
- Connector 目录数量不表示每个应用和动作均可用或兼容。
- 浏览器 MCP 工具注册与转发已确认，真实登录态、页面安全提示和取消未运行验证。
- ACP 的权限偏好层级与 Claude Code 的 disallowed tools 集合只按源码核对，未在真实 CLI 上复现拒绝/放行行为。

## 关键源码索引

- `packages/types/src/agent/heterogeneousAgent.ts`（本地 CLI/runtime/远程任务三类描述符与目录清单）
- `packages/heterogeneous-agents/src/{registry.ts,config.ts,attachedFiles.ts}`
- `packages/heterogeneous-agents/src/scan/scanHost.ts`、`spawn/{spawnAgent.ts,agentStreamPipeline.ts}`
- `packages/heterogeneous-agents/src/spawn/{claudeAgentSdkSession.ts,acpAgentSession.ts,acpStdioClient.ts}`
- `packages/heterogeneous-agents/src/adapters/`（含 `claudeCodeSdk.ts`、`*Acp.ts`、`codexAppServer.ts`）
- `packages/heterogeneous-agents/src/{askUser/AskUserBridge.ts,builtinMcp/LobeBuiltinMcpServer.ts}`
- `packages/heterogeneous-agents/src/codex/{CodexThreadSession.ts,CodexAppServerClient.ts,protocol/generated.ts}`
- `packages/agent-gateway-client/src/`（gateway 客户端、干预与终端镜像）
- `apps/desktop/src/main/modules/heterogeneousAgent/`（14 个 driver、`browserMcpTools.ts`、账号与额度模块）
- `apps/desktop/src/main/controllers/GatewayConnectionCtr.ts`
- `src/store/chat/slices/agentRun/actions/transports/hetero/heterogeneousAgentExecutor.ts`
- `packages/database/src/schemas/{connector,agentShare,fileShare,documentShare,goalShare}.ts`
- `apps/server/src/routers/lambda/shareChat/`、`apps/server/src/services/agentRuntime/AgentRuntimeService/shareRunGate.ts`
- `apps/server/src/services/aiAgent/`（`shareVisitorAbuseGuards.ts`、`shareToolManifest.ts`、`grants.ts`、`sandbox.ts`、`subAgentDispatch.ts` 等）
- `packages/const/src/composio.ts`
- `apps/server/src/services/bot/{BotCallbackService.ts,execute.ts,inbound.ts,platforms/}`
- `apps/server/src/router-hono/agent/handlers/`（`messengerInstall`、`messengerWebhook`、`messengerOAuthCallback`、`platformWebhook`、`botCallback`、`gatewayStart`、`gatewayCron`、`gatewayCallback`、`execAgent`、`runStep`、`llmRelay`、`subAgentCallback`、`toolResult` 等）
- `apps/cli/src/commands/`（`bot*`、`connect*`、`device`、`hetero`、`agent*`、`artifact*`、`channel`、`kb`、`memory`、`recall`、`skill`、`workspace` 等）
- `apps/desktop/src/main/services/imessageBridgeSrv.ts`、`controllers/ImessageBridgeCtr.ts`
