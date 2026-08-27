# Hermes Agent 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 调查方式：静态复核 Python gateway、桌面/TUI/Web JSON-RPC 客户端、ACP adapter、REST gateway 和消息平台边界；复用 Chat、Chat UI 和独特功能笔记；未运行跨客户端或 IM 平台
>
> 调查范围：Hermes runtime 被桌面、TUI、Web、CLI/gateway、ACP 宿主与 REST 客户端控制的多表面关系；消息平台逐项只确认入口；排除内建子 Agent 和托管工具 SaaS
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 的多表面控制与反向 Agent 接入均达到 `主链确认`（静态证据）：

- 桌面、TUI 和 Web 控制面共享同一个 Python `tui_gateway`/`AIAgent` runtime、profile 数据库和 session lineage，并通过 JSON-RPC 提交、流式接收、取消和恢复任务。
- `acp_adapter/` 把 Hermes 作为 ACP agent 暴露给 VS Code/Zed/JetBrains 等外部宿主，覆盖会话新建、恢复、提示、分叉与取消操作。
- REST API gateway（`api_server` 平台）提供补全、响应与运行类端点，以及会话管理与 cron 任务接口；具体路由见下方主链。

消息平台 gateway 存在且平台枚举 20+（telegram/discord/whatsapp/slack/signal/mattermost/matrix/钉钉/企业微信/微信/飞书/QQ 机器人/email/sms/webhook/MS Graph 等），但本轮未逐 adapter 走通，标为 `入口确认`。

## 接入角色与系统边界

Hermes 自身是执行体；外部对象是桌面 renderer、Node/Ink TUI、Web dashboard、CLI/gateway、ACP 宿主、REST 客户端和消息平台 endpoint。Python backend 持有 Agent 循环、工具、SQLite session、记忆和执行状态，各客户端只保存投影与交互状态。`gateway/relay/` 的实验性 relay connector 是托管 gateway 形态，由外部 connector 拨号接入（`候选观察`）。

## 完整主链

```text
Desktop
  -> spawn hermes serve --host 127.0.0.1 --port 0
  -> WebSocket JSON-RPC prompt.submit
  -> tui_gateway 启动 AIAgent.run_conversation
  -> message.delta/tool.*/message.complete 事件回 renderer
  -> session.interrupt/resume/branch/steer/redirect 控制后端

TUI
  -> JSON-RPC over stdio
  -> 同一 gateway method/event 合约

Web dashboard
  -> 连接或嵌入同一 gateway/TUI 后端（/api/ws、/api/events，headless serve 模式）
  -> /api/pty 提供 PTY-over-WebSocket 终端面

ACP 宿主
  -> acp_adapter 鉴权（terminal setup）后 NewSession/Resume
  -> Prompt/Fork/Cancel 映射到同一 runtime
  -> 审批经 permissions.py 回调宿主

REST 客户端
  -> /v1/chat/completions、/v1/responses 无状态调用（X-Hermes-Session-Id 续接）
  -> /v1/runs 创建 run 并 SSE 订阅事件，approval/stop 回传
  -> /api/sessions CRUD/fork/chat、/api/jobs cron 管理
```

## 身份、协议与状态映射

profile 是配置和数据隔离单位；持久会话由 `session_key` 标识，压缩轮转通过 parent/end_reason 形成 lineage。桌面端的 UI sid 只是运行期句柄，真正权威状态在 profile 的 `state.db`。客户端重连后重新拉取 session 并重建投影。新客户端接入由 DM Pairing 授权：一次性 8 位配对码经 CLI 批准后绑定，联动平台 allowlist。REST 面身份即 HTTP 会话 id + token；ACP 面身份为 host 鉴权结果。

## 执行、回流与控制语义

JSON-RPC 覆盖提示、工具审批、中断、恢复、分叉、转向与重定向等控制操作；流式事件包括消息、推理、思考、工具与子 Agent。桌面连接采用指数退避重连，恢复后丢弃过期 runtime binding 并刷新 session；正在运行的 turn 可被新客户端收养为 adopted running turn。REST 面支持 run 级 stop 与审批回传；ACP 面提供 Cancel 与审批回调。外部应用分型中，MS Graph webhook（`msgraph_webhook.py`）是明确的业务系统事件入站样本：Graph 订阅校验握手、通知入站、CIDR 白名单与 client_state 强制。

产品表面（桌面/TUI/Web/终端）显示 profile、会话、连接状态与运行中 turn；接管入口为 session resume/steer 与 adopted running turn。来自 IM、webhook 与 REST 的内容进入同一 Agent 执行域，可触发文件、命令与平台投递副作用；审批与工具放行在 gateway 侧集中处理，不可信输入整体按外部消息处理，但逐平台消毒未验证。

## 权限、凭据与治理边界

本机桌面默认连接随机 localhost 端口；OAuth 模式可使用一次性 ticket；DM pairing 提供 CLI 批准的配对授权。多 profile 各自维护独立 socket 和数据。工具审批在 gateway 侧统一承接，自动放行/禁用与审计落点的策略面未展开。真实远程部署、Web 暴露鉴权、消息平台 token 与平台签名边界本次未逐项展开。

## 相邻类目交接

- 会话、lineage、JSON-RPC 与事件流细节见[Chat 笔记](../Chat/Hermes-Agent-Chat调查笔记.md)和[Chat UI 笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- `delegate_task` 创建的子会话由 Hermes 自身 runtime 管理，属于 Agent 编排，不计外部执行体。
- Tool Gateway 连接托管搜索、媒体和沙箱服务，但当前主要是工具供给入口，账号/动作生命周期未达到业务应用分型门槛。

## 当前执行体交接

ACP 多客户端已改为复用同一 OpenAI bridge；当外部 agent 被当作 provider 且其协议允许工具调用时，外部 agent 的工具活动会回流并并入发起回合。该变化加强外部执行体与 Hermes turn 的衔接，但不表示 ACP 宿主获得 Hermes 内部会话库的直接写权限；会话数据仍由各 profile 的后端管理。

## 已确认边界与未验证事项

- 桌面/TUI/Web/ACP/REST 共享 backend 为静态主链确认，未运行多客户端并发和接管。
- gateway 消息平台的安装、endpoint 映射、线程回复和权限未逐 adapter 调查；relay connector 为实验性，标 `候选观察`。
- 远程 OAuth ticket、断网恢复和 profile 多 socket 时序未运行验证。

## 关键源码索引

- `tui_gateway/server.py`
- `tui_gateway/methods_prompt.py`
- `tui_gateway/methods_session.py`
- `acp_adapter/{server,auth,permissions}.py`
- `gateway/platforms/{api_server,msgraph_webhook}.py`
- `gateway/{pairing.py,relay/}`
- `apps/shared/src/json-rpc-gateway.ts`
- `apps/shared/src/websocket-url.ts`
- `apps/desktop/src/hermes.ts`
- `apps/desktop/electron/backend-command.ts`
- `ui-tui/src/gatewayClient.ts`
- `hermes_cli/web_server.py`
- `gateway/`

