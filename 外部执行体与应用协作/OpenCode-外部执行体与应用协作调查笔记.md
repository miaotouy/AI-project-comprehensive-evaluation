# OpenCode 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`c2eacd72afc4a4984564c393e15ab30011057269`（分支：`dev`）
>
> 调查方式：静态复核 server、sync、ACP、CLI/TUI/Desktop/Web 客户端与 Slack 包；复用 Chat、会话和独特功能笔记；未运行多客户端或 ACP 宿主
>
> 调查范围：OpenCode 作为可被外部客户端和 ACP 宿主控制的 Agent runtime；排除普通 Provider 与宿主内建子 Agent
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 是本类目的反向主样本：它主要不是托管其他 CLI Agent，而是把自身 runtime 通过 HTTP/SSE、ACP、CLI、TUI、Web、Desktop 和 Slack 客户端暴露出去。会话、事件、所有权、重放、取消和分叉形成完整控制主链，达到 `主链确认`（静态证据）。

## 接入角色与系统边界

外部对象是 OpenCode 的客户端或 ACP 宿主；OpenCode server 持有 Agent 循环、SQLite session、文件/Git 工作区和工具权限。Desktop 通过 sidecar 启动同一 server，TUI/Web/attach 连接服务端，ACP service 将协议操作映射到 OpenCode session。外部对象还包括 PTY 终端客户端（WebSocket attach）与插件注册的远端 workspace 提供方（control-plane `WorkspaceAdapter`，`入口确认`）。

## 完整主链

```text
外部客户端发现或启动 opencode server（localhost、mDNS 或远程 URL）
  -> HTTP 创建/选择 session，SSE 订阅 event
  -> prompt 写入服务端 session
  -> OpenCode Agent 执行工具和模型循环
  -> message/part/event 持久化并按序推送
  -> 客户端重连后 replay；必要时 steal 写所有权
  -> cancel/revert/fork 等控制回到服务端

ACP 宿主
  -> acp service 创建/恢复 session
  -> prompt / permission / cancel / fork
  -> 映射 OpenCode 消息、工具和终态

HTTP 审批与提问
  -> permission/question handler list/reply/reject
  -> web 客户端回传审批与结构化提问答案

远端 workspace（入口确认）
  -> control-plane 按 Target 路由 HTTP/WS 到远端 server
  -> Fence.wait 等待 sync 完成
```

## 身份、协议与状态映射

SQLite message/part 与事件序列是权威状态；`owner_id` 和 sync handler 处理多客户端写所有权。客户端本地 store 是投影。ACP session 映射到 OpenCode session，工作目录与项目状态继续由服务端持有。客户端/ACP 宿主身份经 HTTP 密码鉴权（`middleware/authorization.ts`）、sidecar 用户名密码与 CORS 白名单绑定。mDNS 在 loopback 之外提供局域网发现（`mdns.ts`，`入口确认`），云 control-plane 的账号绑定不在本仓库默认路径。

## 执行、回流与控制语义

SSE 推送消息、part、delta 和工具状态；sync 支持历史重放与 owner steal。ACP service 暴露创建、恢复、提示、权限、取消和分叉语义。HTTP 面另有三类远程入口：

- 审批与提问回复通道：`permission.ts` / `question.ts`
- PTY 终端 WebSocket attach：connect token + 一次性 ticket 鉴权
- 远程 TUI 控制：`tui.ts`，方法 `appendPrompt`/`submitPrompt`/`controlNext`/`controlResponse`

CLI `serve/attach/web`、Desktop sidecar、Web/TUI 均消费同一事实源；Slack bot 按 channel/thread 建 session，但产品面较窄；SessionShare 可生成共享 URL（`入口确认`）。

产品表面（TUI/Web/Desktop）显示会话列表、连接与运行状态、工作目录和工具执行过程；接管入口为 session 列表选择与 owner steal。外部客户端提交的 prompt、replay 数据和 ACP 输入直接进入 Agent 工具循环，可触发文件、命令与浏览器副作用；本地工具权限仍由 OpenCode runtime 承担，外部宿主只经 ACP/HTTP 审批面参与放行，不可信输入的边界与本地用户一致。

## 权限、凭据与治理边界

工具与文件权限由 OpenCode runtime 承担。ACP permission 将宿主审批映射到 runtime；多客户端并发通过事件顺序和写所有权收口。网络暴露、远程 server 鉴权和云 control-plane 的完整部署边界本次未展开，不能因 localhost 默认路径推断所有部署均为本机可信。

## 相邻类目交接

- 会话事件源、消息和文件事实源见[Chat 笔记](../Chat/OpenCode-Chat调查笔记.md)与[会话管理笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md)。
- ACP、CodeMode 和多表面连续性能力卡见[独特功能笔记](../独特功能/OpenCode-独特功能调查笔记.md)。
- 后台 task/subagent 属 OpenCode 自身 Agent 编排，不因其独立会话就自动视为外部执行体。

## 已确认边界与未验证事项

- 未运行真实 ACP 宿主、多设备 replay/steal 或云 workspace 同步；mDNS 与远端 workspace 路由为 `入口确认`。
- Slack 包是简化客户端，不等于完整 IM 远程控制产品。
- control-plane 服务端和企业部署边界超出本次仓库主链复核范围。

## 关键源码索引

- `packages/opencode/src/server/server.ts`
- `packages/opencode/src/server/mdns.ts`
- `packages/opencode/src/server/routes/instance/httpapi/handlers/{session,event,sync,permission,question,pty,tui}.ts`
- `packages/opencode/src/server/routes/instance/httpapi/middleware/{authorization,workspace-routing}.ts`
- `packages/opencode/src/control-plane/{types,workspace-adapter-runtime}.ts`
- `packages/core/src/event/sql.ts`
- `packages/opencode/src/acp/{service,permission}.ts`
- `packages/opencode/src/cli/cmd/{serve,attach,web,acp}.ts`
- `packages/desktop/src/main/sidecar.ts`
- `packages/slack/src/index.ts`
