# OpenClaw 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态源码走读；未运行真实 Gateway、多设备、ACP harness、OAuth、渠道、APNS 或外部进程
>
> 调查范围：Gateway、CLI、TUI、Control UI、iOS/Android companion apps、渠道与 ACP 绑定、节点、MCP 桥接及外部进程边界；排除普通 Provider、宿主内建子 Agent、普通 MCP tools/list -> tools/call 和媒体工作站
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的 Gateway 是中心状态与控制平面。CLI、TUI、浏览器 Control UI、移动 companion app 和渠道适配器主要是外部控制表面或设备节点，不持有 OpenClaw 主 Agent runtime；Gateway 负责连接准入、会话路由、事件回流、节点注册和跨表面控制。

外部执行体主链已达到**主链确认（静态证据）**：`sessions_spawn({runtime: "acp"})` 或 `/acp spawn` 可进入 ACPX runtime，由插件启动 Claude/Codex/Gemini/Pi 等外部 harness，外部 harness 保有自己的 runtime、工具循环和原生 session，结果、工具事件、审批与错误再投影回 Gateway session、父 session 或绑定渠道。`openclaw attach` 另有可识别身份、短期授权、外部 Claude Code 进程和撤销清理链。原生 `openclaw acp` 则是反向桥接：外部 ACP client 通过 stdio 控制 OpenClaw Gateway 里的 Agent session。

节点调用也形成主链：Gateway 向已配对的 iOS/Android 等节点发送 `node.invoke.request`，节点回传 progress/result，超时、取消、空闲超时或连接断开时走结构化失败或 cancel。Control UI、TUI 和 companion app 的真实运行行为、具体渠道适配矩阵、APNS 唤醒和真实外部进程终止本次均为**未验证**。

媒体相关入口存在，但静态调查未找到独立媒体任务、资产库、创作历史、专用预览/编辑/版本/再创作 UI 以及完整的生成任务恢复链，因此媒体创作类本次**不适用单项目笔记**；相关能力仅作为入口或边界能力交接。

## 接入角色与系统边界

| 对象 | 在协作关系中的角色 | 状态与执行权归属 |
|---|---|---|
| Gateway | 中心服务、状态源、路由和控制平面 | 持有连接准入、Gateway session、Agent 路由、事件流、节点 registry、ACP 控制面 |
| CLI / TUI / Control UI | 外部控制与交互表面 | 通过 Gateway WebSocket 发起 RPC、订阅事件和恢复历史；不等于独立 Agent runtime |
| iOS / Android companion app | 外部应用与设备节点 | 维护设备身份、节点连接和本地能力；相机、屏幕、语音等执行在设备侧 |
| 渠道与线程 | 外部消息交互表面 | 将当前会话、Discord thread、Telegram topic 等映射到 Gateway session 或 ACP binding |
| ACPX 外部 harness | 外部执行体 | Claude/Codex/Gemini/Pi 等 harness 持有原生 runtime、工具循环与外部 session；OpenClaw 管理适配、投影和进程租约 |
| 原生 ACP client | 外部控制者 | 通过 `openclaw acp` 的 stdio NDJSON 控制 OpenClaw 的 Gateway-backed session |
| `openclaw attach` 子进程 | 外部协作进程 | 外部 Claude Code 进程使用短期 grant 和 loopback MCP 配置访问 OpenClaw 能力 |

Gateway server 的 WebSocket 连接在首帧阶段执行协议和认证准入；连接成功后才注册 session、处理 RPC 和推送事件。外部控制表面不应被理解为 Gateway 内部执行循环的所有者。TUI 的 `--local` 是嵌入式 backend 路径，属于宿主内建 runtime，不纳入外部执行体统计。

## 完整主链

### Gateway 多表面控制链

```text
CLI / TUI / Control UI / companion app
  -> WebSocket connect.challenge
  -> connect（client identity、version、platform、mode、role、scope、认证/设备证明）
  -> hello-ok（methods、events、capabilities、snapshot、Control UI 表面和限制）
  -> sessions.* / chat.* / nodes.* 等 RPC
  -> Gateway session、Agent 路由和事件帧
  -> 客户端按 seq 接收、发现 gap 后恢复历史或重连
  -> chat.abort、node cancel、断开或显式 stop
```

客户端维护 pending request、超时与 `AbortSignal`，连接断开采用退避重连；服务端要求首帧为合法 `connect`，认证、设备证明、节点配对和 session 注册成功后才进入 RPC。多数 UI/SDK RPC 的服务端操作可跨客户端断线继续；`sessions.companion.ask` 与 CLI 发起的 `node.invoke` 在请求方断开时会 Abort，这两个例外不能按通用重试推断。

TUI 已有实际 RPC 和事件处理路径：订阅 sessions、发送和中止 chat、读取 history，以及 sessions/agents/models 等管理调用；运行请求带 `runId`/`idempotencyKey`，事件 gap、断线、重试和历史恢复由 TUI 生命周期处理。Control UI 通过浏览器 WebSocket 复用 Gateway 协议，并有 browser device identity/device token/bootstrap token、scope upgrade、hello 恢复 scope、tick watchdog、Gateway-owned reconnect 和版本/build 准入路径。

### ACPX 外部执行体链

```text
渠道 / CLI
  -> sessions_spawn({ runtime: "acp" }) 或 /acp spawn
  -> ACP admission、agent allowlist、backend 选择
  -> acpx 插件按需注册并 ensureSession
  -> agent registry/config 解析外部命令
  -> upstream acpx/ACP adapter 启动外部 harness
  -> startTurn / runTurn
  -> text_delta、tool_call、done、error、审批或 elicitation
  -> Gateway session、父 session 和绑定渠道投影结果
  -> cancel / close / unfocus / reset；回收进程租约
```

ACPX 侧保留 Gateway session key、backend、agent、runtime session name、identity、mode、runtime options、cwd、state、lastActivity 和 lastError 等元数据，并以 actor queue/runtime handle 管理并发。外部 harness 保留自己的工具循环和原生 session；`stateDir`/session store 用于保存上游 session record 和命令，以满足条件式 persistent resume。cwd、命令、session ID 等不匹配或 session 被 reset 时不会假定可以复用；oneshot turn 结束后关闭。

渠道侧可以把当前会话、Discord thread 或 Telegram topic 绑定到 ACP session。绑定存在时，后续消息进入 ACP session，ACP 输出回到同一聊天表面；`cancel`、`close`、`unfocus`、过期和归档会解除或结束关系。渠道适配器的逐平台行为是**文档/入口确认，未运行验证**，不能据此宣称所有平台均具备相同回流效果。

### 原生 ACP 反向桥接链

```text
外部 ACP client
  -> stdio NDJSON
  -> openclaw acp
  -> CLI 身份连接 Gateway
  -> ACP session/prompt/update translator
  -> Gateway session 与 OpenClaw Agent
  -> prompt、状态更新、权限/输入、cancel 和终态回到 ACP client
```

`openclaw acp` 提供 ACP server 面，支持 new/load/list/resume/close session、prompt、cancel、set mode/config 等操作。`AcpGatewayAgent` 和 translator 将 ACP session、prompt stream、session updates 与 Gateway 的 session/chat 语义互相映射。这里的外部执行者是 ACP client，实际 OpenClaw Agent runtime 仍在 Gateway 侧；不能与 ACPX 启动外部 harness 的方向混为一谈。

### 节点调用链

```text
Gateway node registry
  -> node.invoke.request
  -> 已配对的 iOS/Android 节点 capability router/dispatcher
  -> node.invoke.progress / node.invoke.result
  -> Gateway 调用方和关联 session
  -> timeout、idle timeout、Abort 或断线
  -> node.invoke.cancel 或结构化失败
```

节点记录把 `nodeId` 与 `connId`、pairing identity 和 pairing generation 绑定。命令需经过声明 capability、allowlist、scope、插件策略和执行审批。iOS 前台专属命令还可以进入带 TTL 和每节点数量上限的 pending action，配合 APNS wake/ack 后由设备回前台拉取；这是单独的设备唤醒流程，不是普通 RPC 自动重试。

### `openclaw attach` 外部进程链

```text
openclaw attach
  -> Gateway attach.grant（要求 operator.admin）
  -> 按 session key 签发短期 token/TTL 与 loopback MCP 配置
  -> 临时写入 .mcp.json 并 spawn 外部 Claude Code
  -> 子进程经 MCP 访问获授 OpenClaw 能力
  -> 子进程退出/失败或 grant 过期
  -> attach.revoke、临时目录清理
```

`--print-config` 只输出配置；该路径不会在本地调用 revoke，并会提示调用者自行处理过期授权。正常 spawn 失败或子进程退出会进入 revoke/清理路径，因此 attach 具备外部身份、生命周期、session 映射和治理边界，满足本类目准入。

## 身份、协议与状态映射

Gateway client/server 使用 WebSocket `req`/`res`/`event` 帧。握手顺序为 `connect.challenge -> connect -> hello-ok`。连接参数包含 client identity/version/platform/mode/role/scope，以及 token/password 等认证信息；需要设备证明时还带设备签名。`hello-ok` 返回方法、事件、能力目录、状态快照、Control UI 插件表面、附件限制、role 和 scope，客户端据此建立可用表面。

服务端在首帧检查、认证、设备证明、节点配对和 session 注册后才接受 RPC；共享认证代际变化会使旧连接失效。客户端 pending map 将请求 ID 映射到 response，事件 `seq` 用于检测缺口，重连后通过恢复/历史路径重新建立投影。连接身份、Gateway session key、ACP runtime session name、渠道 thread/topic 和 node ID 是不同层级的标识，源码中分别维护，不能只凭聊天标题推断它们相等。

ACPX 元数据将 Gateway session key 映射到外部 backend/agent 和 upstream runtime session；persistent session 还由 cwd、command、session ID、stateDir 等条件约束。进程租约在 spawn 前写入 pending lease（`rootPid=0`），wrapper 写回 PID；租约包含 `leaseId`、`gatewayInstanceId`、`sessionKey`、wrapper root/path、`rootPid`、command hash 和 state。操作结束后按身份校验回收，Gateway 启动时回收 OpenClaw-owned stale process trees/orphans。

渠道 binding 把 ACP session 映射到具体会话或 thread/topic；native ACP 则把 ACP session 映射到 Gateway-backed session；节点 registry 把设备 node ID 映射到当前连接和配对代际；attach grant 把短期 token 映射到 session key。这些映射共同构成“控制表面/外部执行体/设备/会话”的边界。

## 执行、回流与控制语义

- Gateway RPC 的 response 与事件分离：response 结束单次请求，event 承载状态、增量、节点进度和执行结果。客户端在超时、Abort、seq gap 和 reconnect 时分别处理，不能把事件丢失等同于执行已取消。
- TUI 的 chat.send/chat.abort、history 和 session subscribe 形成可操作的终端控制面；`runId`/`idempotencyKey` 用于把一次运行与重试/回流关联。Control UI 具备浏览器连接看门狗与重连，视觉状态和多浏览器争用本次**未验证**。
- ACPX 把外部 harness 的 text delta、tool call、done、error、approval/elicitation 转换为 Gateway/渠道可消费的更新；取消和关闭必须经过 ACPX runtime 的 session actor、upstream adapter 与进程清理路径，不能只认为 UI 隐藏消息即已停止。
- 节点调用把 progress/result 返回 Gateway；Gateway 对超时、空闲超时、Abort 和断线生成 cancel 或结构化失败。实际设备是否在每个平台及时停止摄像头、录屏、语音或其他动作，本次**未验证**。
- iOS pending action 通过 TTL、容量限制、APNS wake/ack 和前台拉取补足设备不可达窗口；它不是普通 node.invoke 的可靠队列，也不能推广到 Android 或所有节点。
- 渠道 binding 将 ACP 输出回投到绑定聊天表面；平台消息编辑、线程串联、附件和失败重试的完整行为为**入口确认/未验证**。
- attach 的 revoke 负责撤销短期 grant 和清理临时配置；外部 Claude Code 的具体工具调用、进程树终止效果和不同平台 shell 行为本次**未验证**。

## 权限、凭据与治理边界

Gateway 以 client identity、role、scope、token/password、设备签名、设备配对和节点 pairing generation 做准入。Control UI 的 bootstrap token、device token 和 scope upgrade 属于浏览器设备身份链；CLI/TUI/SDK 复用 Gateway 协议但不应共享“匿名本地客户端”的假设。`attach.grant` 明确要求 `operator.admin`，并将 grant 绑定到 session key、短 TTL 和 loopback MCP 配置。

节点命令还受 capability 声明、allowlist、scope、插件策略和执行审批限制。ACPX 配置提供 `permissionMode`（`approve-all`、`approve-reads`、`deny-all`）及 `nonInteractivePermissions`（`deny`、`fail`）；默认 runtime operation timeout 为 120 秒。普通 MCP server 的 `tools/list -> tools/call` 不因存在协议就算外部执行体；ACPX 的 `openclaw-plugin-tools`/`openclaw-tools` MCP bridge 需要显式 opt-in，且以 session key 环境变量标识 session。进程租约的 gateway instance、session key、wrapper 路径、PID 和 command hash 用于限制清理范围。

这些边界意味着外部 harness、设备节点或经授权的渠道输入可能触发文件、命令、浏览器、相机、录屏、语音或业务侧副作用，权限责任分别落在 Gateway policy、ACP harness permission、节点 capability/approval 和渠道账号上。凭据加密存储、OAuth 刷新、团队/服务账号审计，以及所有平台的撤销传播本次**未深入验证**；不能从静态入口推断其部署级保证。

## 相邻类目交接

- CLI、TUI、Control UI、移动 app 和渠道适配器属于外部控制/交互表面；它们对 Gateway Agent 的控制不等于各自拥有独立 Agent runtime。
- iOS/Android 的 camera、screen、voice 等是设备节点能力，属于外部应用协作中的执行边界；具体采集结果、媒体附件回流和平台权限弹窗本次为**入口确认/未验证**。
- 普通 MCP server 仅提供工具发现和调用，不纳入外部执行体与应用协作主链；只有 ACPX 显式开启的 OpenClaw/plugin MCP bridge 作为外部 harness 的受治理资源入口记录。
- 内建子 Agent、普通 Provider 和普通渠道消息处理不单独建外部执行体笔记；只有 ACP runtime、独立进程、节点或可控制的外部客户端达到身份、生命周期、双向协议、状态映射和治理条件时才纳入。
- 媒体入口位于 `media-understanding`、TTS、附件、媒体/视频生成 provider 以及节点 camera/screen 等模块，但**未找到**独立媒体工程对象、创作历史/资产库、专用预览编辑与版本再创作、可恢复生成任务的完整工作站闭环。因此媒体创作类本项目**不适用**，不建立 OpenClaw 单项目笔记。

## 已确认边界与未验证事项

- **已确认（静态）**：Gateway WebSocket 握手、认证准入、RPC/event 协议、请求取消和事件 gap 检测；TUI 的 Gateway 控制路径；节点 invoke 的请求/进度/结果/取消状态机；native ACP 反向桥接；ACPX 外部 harness 调度、session 元数据、回流和进程 lease/reaper；attach grant/revoke 与临时 MCP 配置链。
- **入口确认**：Control UI 浏览器设备准入和 reconnect 表面；渠道 ACP binding 的多平台接入；iOS pending action/APNS wake；ACPX 普通/插件 MCP bridge 的配置入口；媒体理解、TTS、附件、媒体生成及节点媒体采集入口。
- **未验证**：真实 Gateway 网络连接和多客户端争用；真实 TUI/Control UI/mobile 操作；iOS/Android 设备配对、前台唤醒、相机/录屏/语音执行；Discord/Telegram 等具体渠道消息、线程、附件和失败重试；真实 OAuth 与凭据刷新；Claude/Codex/Gemini/Pi 等外部 harness 的实际启动、审批、取消、session resume 和跨平台进程树终止；APNS 及外部进程回收的运行效果。
- **未找到**：可独立管理的媒体创作任务、媒体资产库、媒体项目历史、专用编辑/预览/版本/再创作 UI，以及完整的媒体生成恢复主链。
- **不适用**：把普通 Provider、宿主内建子 Agent、单纯 `tools/list -> tools/call` 的 MCP server 或仅有通知/分享的入口当作本类目的外部执行体/应用协作项目。

## 关键源码索引

- Gateway 协议客户端与请求/事件生命周期：`packages/gateway-client/src/protocol-client.ts:40-120`、`:183-221`、`:390-508`
- Gateway WebSocket 准入与请求分发：`src/gateway/server/ws-connection/message-handler.ts:273-383`、`src/gateway/server/ws-connection/authenticated-request-dispatch.ts:197-247`
- 节点 registry、invoke、progress/result/cancel：`src/gateway/node-registry.ts:221-290`、`src/gateway/server-methods/nodes.invoke.ts:363-604`、`:608-714`、`src/gateway/server-methods/nodes.event.ts`
- TUI Gateway chat/backend/lifecycle：`src/tui/gateway-chat.ts:191-260`、`src/tui/tui-backend.ts:180-201`、`src/tui/tui-event-handlers.ts`、`src/tui/tui-run-lifecycle.ts`
- Control UI 浏览器连接：`ui/src/api/gateway.ts`、`ui/src/api/gateway-browser-socket.ts`
- companion app Gateway/node/camera/screen：`apps/ios/Sources/Gateway/GatewayConnectionController.swift`、`apps/ios/Sources/Chat/IOSGatewayChatTransport.swift`、`apps/ios/Sources/Capabilities/NodeCapabilityRouter.swift`、`apps/ios/Sources/Camera/CameraController.swift`、`apps/ios/Sources/Screen/ScreenRecordService.swift`；`apps/android/app/src/main/java/ai/openclaw/app/gateway/GatewayProtocol.kt`、`GatewaySession.kt`、`node/InvokeDispatcher.kt`、`node/InvokeCommandRegistry.kt`、`node/CameraHandler.kt`
- native ACP server/client/translator：`src/acp/server.ts:94-269`、`src/acp/client.ts:148-242`、`src/acp/translator.ts:58-214`、`src/acp/translator.session-lifecycle.ts`、`src/acp/translator.prompt-stream.ts:93-177`、`:387-440`、`src/acp/translator.session-updates.ts:46-168`
- ACP control plane/runtime registry：`src/acp/control-plane/manager.types.ts:46-115`、`src/acp/control-plane/manager.core.ts:168-365`、`src/acp/control-plane/manager.cancel-session.ts:18-145`、`src/acp/control-plane/manager.turn-stream.ts:34-247`、`src/acp/runtime/registry.ts:54-117`、`src/acp/runtime/session-meta.ts:56-100`
- ACPX plugin/runtime/config/process lifecycle：`extensions/acpx/index.ts:47-65`、`extensions/acpx/register.runtime.ts:117-183`、`extensions/acpx/src/service.ts:325-461`、`extensions/acpx/src/config-schema.ts:7-120`、`extensions/acpx/src/config.ts:186-274`、`extensions/acpx/src/runtime.ts:794-910`、`:967-1106`、`:1108-1168`、`:1228-1462`、`:1486-1571`、`:1624-1745`、`:1832-1875`、`extensions/acpx/src/process-lease.ts:1-18`、`:40-178`、`extensions/acpx/src/process-reaper.ts`
- attach grant/revoke 与 CLI：`src/cli/attach-cli.ts:15-31`、`:33-184`、`src/gateway/server-methods/attach.ts:22-89`
- ACP 渠道/线程 binding 与 spawn：`src/auto-reply/reply/commands-acp/bindings.ts`、`src/auto-reply/reply/commands-acp/lifecycle.ts`、`src/agents/subagents/spawn/acp-spawn*.ts`、`src/agents/subagents/spawn/subagent-spawn-thread-binding.ts`；相关声明见 `docs/tools/acp-agents.md`、`docs/tools/acp-agents-setup.md`
- 媒体边界入口：`src/media-understanding/*`、`src/media/*`、`src/tts/*`、`src/media-generation/*`、`src/video-generation/*`、`src/gateway/chat-attachments.ts`、`src/gateway/managed-image-attachments.ts`
