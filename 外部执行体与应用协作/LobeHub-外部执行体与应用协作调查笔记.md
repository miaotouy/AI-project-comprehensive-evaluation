# LobeHub 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7c559cbd4d92a54289bce3a8aab96e057d0ce8c5`（分支：`canary`）
>
> 调查方式：静态阅读异构 Agent、Gateway、Connector、Messenger 与 browser MCP 关键源码；复用 Agent 工具和独特功能笔记已确认链路；未运行 CLI、OAuth 或 IM 平台
>
> 调查范围：外部 CLI/Agent runtime 托管（含 SDK/codex-app-server 传输）、业务应用 Connector、Bot 平台/Messenger/设备/浏览器交互表面；排除普通模型 Provider、任意 MCP 配置和宿主内建子 Agent
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 是当前样本中覆盖面最宽的项目，三种接入角色都有实现：

- `主链确认`：Amp、Claude Code、CodeBuddy、Codex、Cursor、Grok Build、Kimi Code、OpenCode、Pi、Qoder、TRAE 十一种本地 CLI；OpenClaw/Hermes 平台任务；Connector/Composio 账号与动作权限；CLI Agent 驱动内置浏览器；Bot 平台层安装、回调与 CLI 管理。
- `入口确认`：Slack、Discord、Telegram、WeChat Messenger 的安装、绑定、webhook/gateway 和 outbound 已存在，逐平台完整线程往返未静态走通。

本地 CLI 之外还有两种独立传输层次：注册表另注册 `claude-code-sdk`（Claude Agent SDK 进程内 runtime）与 `codex-app-server`（stdio JSON-RPC 连接 Codex app server）两种适配器，均由 lab 开关门控。CLI 描述器与 adapter 注册表不是同一层次，因此不应把后两项混入本地 CLI 数量。

## 接入角色与系统边界

| 角色 | 外部对象 | 宿主持有的状态 |
|---|---|---|
| 外部执行体 | 十一种本地 CLI、OpenClaw、Hermes | operation、topic、working directory、原生 session id、进程/任务和事件投影 |
| 外部应用 | Connector、Composio 业务账号 | connection、credential、tool catalog、scope、permission |
| 外部控制/交互表面 | Bot 平台、Messenger、设备网关、内置浏览器 | bot binding、webhook secret、步骤/完成回调、installation、binder、线程/用户、device、browser operation |

## 完整主链

```text
Connect Agent / 模型选择
  -> 扫描命令、版本与登录状态
  -> driver 组装参数、stdin、图片和工作目录
  -> spawn CLI 或 SDK runtime
  -> JSONL/SDK stream 进入 AgentStreamPipeline
  -> provider adapter 归一为 AgentStreamEvent
  -> Chat store 持久化文本、reasoning、tool、todo、subagent、intervention
  -> 保存原生 sessionId 与 cwd，下一轮 resume
  -> UI cancel 终止进程树或平台任务
```

OpenClaw/Hermes 不走本地 JSONL adapter。`GatewayConnectionCtr.runHeteroTask` 按 topic/task 启动进程，OpenClaw 经 `lh notify` 回传，Hermes 经标准输出与通知接口回流；任务表保存 PID 并支持终止。

```text
Bot 平台（slack/discord/telegram/feishu/line/qq/imessage/wechat）
  -> lh bot connect 安装/绑定 Agent（微信走二维码登录）
  -> BotCallbackService 校验平台 webhook 或 QStash 队列回调
  -> 关键词触发或命令提交 Agent 运行（execAgent 队列模式）
  -> 步骤进度与完成结果回投平台
```

## 身份、协议与状态映射

`heterogeneousAgent.ts` 将执行体分为 `local-cli` 与 `remote-task`。本地 CLI 的原生 session id 和工作目录映射到 LobeHub operation/topic；平台任务另映射 task id、topic id、device 与 PID。两类执行体都有独立工具循环，LobeHub 负责适配与观察，不接管其原生工具执行。

Connector 以个人、Workspace 或 Agent scope 保存持久连接；Messenger installation 绑定 LobeHub 用户与平台账号/线程；设备网关把服务端任务路由到具体桌面设备，并反向把 iMessage 等设备侧消息 API 在桌面上执行；bot 平台绑定以 `lh bot` 命令族和平台回调管理。

## 执行、回流与控制语义

统一事件模型覆盖文本、推理、工具、待办、子 Agent、文件变化、额度、干预和终态。Claude Code/Qoder 可接收临时 MCP 配置；`browserMcpTools.ts` 把下列浏览器操作投给外部 Agent，使其能操作 LobeHub 内置浏览器：

```text
navigate / snapshot / click / fill / press / scroll / screenshot / readPage
```

`claude-code-sdk` 与 `codex-app-server` 两种传输的权限语义不同于 CLI spawn，对照如下：

| 传输 | 权限语义 | 超时兜底 |
|---|---|---|
| `claude-code-sdk` | 使用 `permissionMode: 'bypassPermissions'`，禁用 `AskUserQuestion`/`Monitor`/`ScheduleWakeup` | 空闲超时与任务状态机（`starting`/`running`/`monitoring`/`idle`/`stale`） |
| `codex-app-server` | 携带 `--dangerously-bypass-approvals-and-sandbox` 类标志 | 同上 |

`agent_intervention_request/response` 允许外部 runtime 在执行中挂起并向用户提出结构化问题；取消由本地进程树终止或 gateway task 终止到达真实执行体。

产品面（桌面设置与对话界面）会显示已连接 Agent、工作目录和任务/操作视图，并提供干预、取消与 bot/Messenger 绑定入口；CLI 侧提供 `lh` 命令族（连接、设备、异构 Agent、bot 管理、消息与通知等子命令）控制设备、任务与 bot。外部 CLI 输出的文本、工具调用和文件变化按事件流进入宿主会话，可触发文件写盘与浏览器操作，属于不可信输入面；其信任边界取决于各 runtime 的权限模型与宿主注入工具的审批，真实提权风险未做运行评估。

## 权限、凭据与治理边界

Connector 支持 OAuth2、bearer、API key 和自定义 header，凭据经 `KeyVaultsGateKeeper` 加密。工具权限为 `auto / needs_approval / disabled`；客户端只拿 manifest，服务端在调用时解密连接凭据。Composio 当前预置 24 种业务应用类型，但未逐应用运行验证。

外部 CLI 的原生工具权限仍由各 runtime 承担；LobeHub 能观察、审批部分宿主注入工具和展示文件变化，不能由此推断完全统一了所有 CLI 的安全模型。凭据加密已确认（`KeyVaultsGateKeeper`），凭据刷新与失效流转机制本次未单独验证。

## 相邻类目交接

- 工具目录、调用与 Connector 权限细节见[Agent 工具笔记](../Agent工具/LobeHub-Agent工具调查笔记.md)。
- 异构 Agent 产品定位、Messenger 与浏览器桥的边界见[独特功能笔记](../独特功能/LobeHub-独特功能调查笔记.md)。
- 宿主内建 `callSubAgent` 属 Agent 角色/工具，不计入本类目。

## 已确认边界与未验证事项

- 十一种 CLI 和两种平台任务均为静态主链确认，未逐个安装运行；`claude-code-sdk`/`codex-app-server` 传输与相应 lab 开关未运行验证。
- Messenger 逐平台签名、附件、线程映射、审批与完整回复往返未验证；bot 平台层的微信二维码登录、队列回调与逐平台消息格式未运行验证。
- 外部 CLI 进程退出后的会话恢复策略（重连、重放或接管）与断线语义未验证。
- Connector 目录数量不表示每个应用和动作均可用或兼容。
- 浏览器 MCP 工具注册与转发已确认，真实登录态、页面安全提示和取消未运行验证。

## 关键源码索引

- `packages/types/src/agent/heterogeneousAgent.ts`
- `packages/heterogeneous-agents/src/{registry.ts,scan/scanHost.ts,spawn/spawnAgent.ts,spawn/agentStreamPipeline.ts}`
- `packages/heterogeneous-agents/src/spawn/{claudeAgentSdkSession.ts,codexAppServerSession.ts}`
- `apps/desktop/src/main/modules/heterogeneousAgent/`
- `src/store/chat/slices/agentRun/actions/transports/hetero/heterogeneousAgentExecutor.ts`
- `apps/desktop/src/main/controllers/GatewayConnectionCtr.ts`
- `apps/desktop/src/main/modules/heterogeneousAgent/browserMcpTools.ts`
- `packages/database/src/schemas/connector.ts`
- `packages/const/src/composio.ts`
- `apps/server/src/services/bot/{BotCallbackService.ts,platforms/}`
- `apps/server/src/router-hono/agent/handlers/{messengerInstall,platformWebhook,gatewayCron,botCallback,execAgent}.ts`
- `apps/cli/src/commands/{bot,botMessage,botMessengers,connect,device,hetero}.ts`
- `apps/desktop/src/main/services/imessageBridgeSrv.ts`

