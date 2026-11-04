# Codex 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：只读源码静态梳理 app-server 协议与传输、exec-server 反向执行协议、remote control 配对与中继、Python SDK 驱动链路；未运行构建、未启动服务、未做真实网络握手
>
> 调查范围：外部客户端驱动 Codex（app-server）、Codex 驱动独立执行体（exec-server）、外部客户端远程控制本机 Codex（remote control）；MCP 应用连接器仅作为相邻能力说明，不展开业务动作目录
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 在三个方向上建立了外部协作主链，且方向各不相同：

- **外部客户端驱动 Codex**：app-server 以 JSON-RPC 暴露 `thread/*`、`turn/*` 与通知流，IDE 扩展和 SDK 是客户端；审批、用户输入、MCP elicitation 与动态工具调用又反向变成服务端请求。
- **Codex 驱动外部执行体**：exec-server 把进程、文件系统与 HTTP 委派给独立进程或远端主机；Codex 是控制方，执行体持有真实进程与文件句柄。
- **外部客户端远程控制本机 Codex**：remote control 让 app-server 主动连出到中继服务，经过配对后把外部客户端的流接入本机线程。

三者都具备可识别身份、持续生命周期、双向协议、状态映射和治理边界，因此不是简单的“有 HTTP API”或“接了 MCP”。

| 接入方向 | 角色 | 判定 |
|---|---|---|
| app-server | 外部 IDE / SDK 是控制面，Codex 是执行面 | 主链确认 |
| exec-server | Codex 是控制面，独立执行体是执行面 | 主链确认 |
| remote control | 外部客户端经中继控制本机 Codex | 主链确认（源码层，真实中继未验证） |
| MCP 应用连接器 | Codex 单向调用业务工具 | 相邻能力，本次不展开 |
| `codex exec` | 本地无头运行，复用宿主 runtime | 不纳入 |

## 1. 接入角色与系统边界

### 1.1 app-server：Codex 作为被驱动方

app-server 是一个长驻 JSON-RPC 服务。传输由 `--listen` 指定，支持以下取值（`codex-rs/app-server/src/main.rs:42-49`、`codex-rs/app-server-transport/src/transport/mod.rs:123`）：

- `stdio://`，默认值。
- `unix://` 或 `unix://PATH`。
- `ws://IP:PORT`。
- `off`。

默认会话来源是 `vscode`，说明它的主要消费者是编辑器与 IDE 集成（`main.rs:51-58`）。

协议分三层：

- 客户端请求：`initialize`、`thread/start`、`turn/start`、`turn/interrupt`、`thread/archive` 等。
- 服务端通知：回合与条目的生命周期，例如 `turn/started`、`turn/completed`、`item/started`、`item/completed`（`codex-rs/app-server-protocol/src/protocol/common.rs:2049-2062`）。
- 服务端请求：命令审批、文件变更审批、工具提问、MCP elicitation、权限申请、动态工具调用（`common.rs:1861-1910`）。

### 1.2 exec-server：Codex 作为控制方

exec-server 把“执行”从 Codex 进程中拆出去。它可以是本地子进程，也可以是远端主机上的独立服务；Codex 通过环境提供器选择并连接它，远端注册时再由环境注册表分配身份。

协议方法覆盖三类能力（`codex-rs/exec-server-protocol/src/protocol.rs:25-63`）：

| 类别 | 方法 |
|---|---|
| 握手 | `initialize`、`initialized` |
| 进程 | `process/start`、`process/read`、`process/write`、`process/signal`、`process/terminate` |
| 进程事件 | `process/output`、`process/exited`、`process/closed` |
| 文件系统 | `fs/readFile`、`fs/open`、`fs/readBlock`、`fs/writeBlock`、`fs/close`、`fs/writeFile`、`fs/createDirectory`、`fs/getMetadata`、`fs/watchMissing`、`fs/missingChanged`、`fs/canonicalize`、`fs/readDirectory`、`fs/walk`、`fs/remove`、`fs/copy` |
| 网络 | `http/request`、`http/request/bodyDelta` |
| 环境 | `environment/info`、`environment/status`、`capabilityRoots/discoverV1` |

### 1.3 remote control：Codex 作为被远程控制方

remote control 复用 app-server 的连接模型，但连接方向相反：app-server 主动向中继服务建立 WebSocket，外部客户端通过中继与本机 Codex 通信。启动开关是隐藏参数 `--remote-control`（`codex-rs/app-server/src/main.rs:73-75`），也可以由持久化偏好或 RPC 启用。

## 2. 完整主链

### 2.1 外部客户端驱动 Codex

```text
客户端启动 codex app-server --listen stdio://
  → initialize（客户端信息、能力协商）
  → thread/start（cwd、模型、沙箱、审批策略、动态工具…）
  → turn/start（输入项、回合级覆盖）
  → 服务端推送 turn/started / item/started / item/completed
  → 需要审批或提问时，服务端发 item/commandExecution/requestApproval 等请求
  → 客户端回复，回合继续
  → turn/completed
  → turn/interrupt 或 thread/archive 结束
```

初始化是硬门禁：连接未初始化时，除初始化请求外的调用直接返回未初始化错误（`codex-rs/app-server/src/message_processor.rs:1037-1039`）。线程与回合的启动分别在 `message_processor.rs:1359-1370` 与 `:1738-1747` 分发。

回合开始还要经过准入控制。`TurnAdmission` 维护关闭、暂停与活跃计数；`admit` 在服务端 drain 或工作区切换期间拒绝新回合，已准入的请求会在序列化后再次检查（`codex-rs/app-server/src/turn_admission.rs:37-90`、`message_processor.rs:1053-1099`）。

### 2.2 Codex 驱动外部执行体

```text
读取 $CODEX_HOME/environments.toml 或环境变量
  → 选择默认环境（含本地环境）
  → 按 url / program / Noise 注册信息建立连接
  → initialize / initialized
  → process/start（argv、cwd、env、tty、沙箱意图）
  → process/output（带 seq 的增量）
  → process/exited（exitCode、sandboxDenied）
  → process/closed
  → 期间可 process/read|write|signal|terminate
  → 旁路：fs/* 与 http/request
```

`process_id` 是客户端选择的逻辑句柄，不是操作系统 PID；它的作用域是当前连接或会话，后续读写、信号和终止都按这个句柄寻址，而不是按平台 PID（`exec-server-protocol/src/protocol.rs:376-379`）。

启动参数携带的是“可移植沙箱意图”，而不是具体包装命令：`sandbox` 是文件系统沙箱上下文，`enforce_managed_network` 与 `managed_network` 描述托管网络要求，由执行体解析成本地包装 argv（`protocol.rs:399-413`）。这使同一个 Codex 客户端可以驱动 Linux、macOS 或远端执行体，而不把平台细节写进会话层。

### 2.3 远程控制本机 Codex

```text
启用 remote control
  → 向中继服务 enroll，取得 environment_id / server_id / token
  → 建立 WebSocket，状态 Disabled → Connecting → Connected
  → 向中继申请 pairing code 或 manual pairing code
  → 外部客户端完成配对
  → 客户端消息与 Codex 事件按 client_id + stream_id 转发
  → clients/list 查看，clients/revoke 撤销
  → token 到期前刷新；认证主体变化会中断当前会话
```

配对参数只接受两种形式之一：配对码或手动配对码。同时给出或都不给都会被拒绝（`codex-rs/app-server/src/request_processors/remote_control_processor.rs:214-226`）。客户端管理入口是列举与撤销两项（`codex-rs/app-server-transport/src/transport/remote_control/controller.rs:248-262`）。

## 3. 身份、协议与状态映射

### 3.1 身份与认证

| 通道 | 身份载体 | 说明 |
|---|---|---|
| app-server stdio | 进程边界 | 由启动方持有管道，不再额外认证 |
| app-server WebSocket | capability token 或签名的 JWT bearer | `--ws-auth` 选择模式，支持 token 文件、摘要、共享密钥、issuer、audience（`codex-rs/websocket-auth/src/lib.rs:31-65`） |
| exec-server stdio | 进程边界 | 由 Codex 启动子进程 |
| exec-server WebSocket | bearer token | `auth_bearer_token` 配置 |
| exec-server Noise | executor 公钥、harness 公钥、harness key authorization | 注册表返回并校验（`codex-rs/exec-server/src/environment_registry.rs:6-64`） |
| remote control | 账号认证 + enrollment token + client id | token 有到期与刷新（`remote_control/server_api.rs:91-131`） |

app-server 还把认证主体绑定到连接。连接认证会记录一个主体代际；主体变化后连接被判为失效，门禁关闭，排队请求不再启动，已启动的 handler 允许收尾（`codex-rs/app-server-transport/src/connection_auth.rs:10-40`、`codex-rs/app-server/src/connection_rpc_gate.rs:1-60`）。

### 3.2 状态映射

app-server 的映射最直接：外部 `threadId` 对应本地线程，`turnId` 对应一次回合，条目事件对应消息、推理、工具调用、命令执行等 `ThreadItem`。线程元数据保存来源、模型提供方、基础指令、动态工具、角色与能力根等信息；回合级配置另行记录。

exec-server 的映射是“环境 + 逻辑进程”：

- `environment_id` 标识一个执行环境，本地环境有固定 ID，远端环境由注册表分配。
- `process_id` 标识该环境内的一个逻辑进程，生命周期独立于 OS PID。
- 连接状态由 `EnvironmentConnectionState` 表示：`Connected`、`Recovering`、`Disconnected`（`codex-rs/exec-server/src/environment.rs:72-79`）。

remote control 的映射是“客户端 + 流”：

- `installation_id` 标识本机安装，`environment_id` 标识注册后的环境。
- `client_id` 标识配对客户端，`stream_id` 标识一次消息流。
- 连接状态是 `Disabled`、`Connecting`、`Connected`、`Errored`（`app-server-protocol/src/protocol/v2/remote_control.rs:158-166`）。

### 3.3 传输

app-server 支持 stdio、Unix socket 与 WebSocket；exec-server 支持 stdio、WebSocket 与 Noise rendezvous（`exec-server/src/client_api.rs:104-120`）。Noise 用于注册表授权的远端连接，把执行体身份与传输层绑定，而不是只靠一个 URL。

## 4. 执行、回流与控制语义

### 4.1 app-server 的服务端请求

服务端请求是 app-server 与普通“只回通知”的 RPC 最大的区别。客户端必须按请求 ID 回复，否则回合会停在等待状态。当前快照中的请求类型包括（`app-server-protocol/src/protocol/common.rs:1861-1910`）：

- `item/commandExecution/requestApproval`：命令执行审批。
- `item/fileChange/requestApproval`：文件变更审批。
- `item/tool/requestUserInput`：工具向用户提问。
- `mcpServer/elicitation/request`：MCP 服务器 elicitation。
- `item/permissions/requestApproval`：附加权限申请。
- `item/tool/call`：让客户端执行动态工具。
- `account/chatgptAuthTokens/refresh`：让客户端刷新账号令牌。

审批请求只负责“是否允许这次例外”，不改变本地沙箱策略；真正的执行仍由 Codex 的审批与沙箱链路决定。

### 4.2 SDK 驱动

Python SDK 是 app-server 的典型客户端。它启动 `codex app-server --listen stdio://`，用类型化参数创建线程与回合，再按通知路由收集结果（`sdk/python/src/openai_codex/client.py:215-256`、`:478-500`、`:650-700`）。

SDK 没有另起一套协议，因此 app-server 的能力边界就是 SDK 的能力边界：线程、回合、审批、用户输入、动态工具都由同一组 JSON-RPC 方法表达。

### 4.3 exec-server 的流式语义

进程输出是带序号的增量通知。`process/output` 携带进程句柄、序号、流类型与字节块；`process/exited` 携带退出码与沙箱拒绝标记；`process/closed` 表示句柄关闭（`exec-server-protocol/src/protocol.rs:1245-1267`）。序号让客户端可以检测丢包与乱序。

文件系统不是一次性 RPC，而是句柄式分块读写：

- 打开：`fs/open` 返回句柄。
- 传输：`fs/readBlock` 与 `fs/writeBlock`。
- 释放：`fs/close`。

这样大文件不需要整体进内存，也能在远端执行体上保持权限检查。

HTTP 请求先返回状态与响应头，响应体通过 `http/request/bodyDelta` 分块回传，单块上限 1 MiB（`exec-server-protocol/src/protocol.rs:60-65`）。

### 4.4 取消、重连与恢复

app-server 的取消是回合级的：`turn/interrupt` 让当前回合停止，已发出的工具调用按各自的取消语义收尾。连接断开时，服务端依赖连接门禁与回合准入做清理。

exec-server 的取消分为信号与终止两个层级：前者发送信号，后者结束进程。传输中断时环境进入 `Recovering`，由客户端尝试恢复连接并重新初始化；恢复失败则进入 `Disconnected`（`environment.rs:72-79`）。

remote control 的重连由 WebSocket 状态机与 token 刷新共同驱动；认证主体变化会中断当前会话而不是静默重连到旧身份：每次会话操作前后都校验认证主体，失效时以中断错误结束（`codex-rs/app-server-transport/src/transport/remote_control/controller.rs:160-176`）。

## 5. 权限、凭据与治理边界

### 5.1 app-server

app-server 不把审批权交给客户端，而是把“询问”交给客户端。客户端可以在 `thread/start` 请求审批策略与沙箱模式，但这些设置仍受本机配置和托管要求约束；审批请求只负责回答“允许/拒绝/中止”。因此客户端可以拒绝一切，但不能单凭一次审批回复改变本机沙箱。

动态工具是例外通道：模型调用的工具由客户端实现，结果以工具输出回到模型。客户端因此是受信任的扩展面，Codex 只把结果当工具输出处理，不在本地重新执行或校验其行为。

### 5.2 exec-server

exec-server 的治理重点是“执行位置”和“执行权限”都要显式传递：

- 连接层用 token 或 Noise 密钥证明执行体身份。
- 每个进程请求携带沙箱意图与托管网络要求；如果要求托管网络但缺少必要参数，执行体必须 fail closed（`protocol.rs:406-410`）。
- 文件系统操作在远端执行体上做权限检查，而不是在 Codex 本地做完再信任远端。
- 能力发现（`capabilityRoots/discoverV1`）让 Codex 知道执行体上有哪些可用的技能与插件根，而不是假设远端布局与本地一致；插件根的识别认三种清单布局，即 `.codex-plugin`、`.claude-plugin` 与 `.cursor-plugin` 下的 `plugin.json`（`codex-rs/exec-server-protocol/src/protocol.rs:52-59`）。
- 第二版能力发现在客户端侧按环境、执行会话、工作目录与沙箱维度缓存，带响应上限；可重试的失败会被记录并用来触发依赖方（MCP 投影）刷新（`codex-rs/exec-server/src/capability_discovery_v2_cache.rs:1-2`）。

### 5.3 remote control

remote control 有三层治理：

- 启动策略：`RemoteControlPolicy::DisabledByRequirements` 时直接不可用（`remote_control/mod.rs:72-77`）。
- 账号层：enrollment token 有到期时间并会刷新；认证主体变化会中断会话。
- 客户端层：`clients/list` 查看已配对设备，`clients/revoke` 把撤销请求转给中继服务；本机不保存可直接放行的客户端凭据（`codex-rs/app-server-transport/src/transport/remote_control/controller.rs:248-262`、`remote_control/mod.rs:795-809`）。

### 5.4 与 MCP 应用连接器的区别

MCP 应用连接器（`codex_apps` 服务器、OAuth/EMA、应用工具目录）让 Codex 调用外部业务动作，但它没有独立的 Agent runtime，也没有“谁控制谁”的双向回合语义。它属于工具接入，审批按 MCP 规则处理，因此在本类目中只作为相邻能力记录，不作为外部协作主链。

## 6. 相邻类目交接

| 相邻类目 | 本笔记记录 | 留在相邻类目 |
|---|---|---|
| Agent 工具 | 动态工具、工具结果如何经 app-server 往返 | 工具注册、暴露、审批与执行细节 |
| 会话与消息管理 | 线程/回合 ID 与外部状态的映射 | 历史落盘、恢复、分支与归档语义 |
| 对话请求与上下文 | 外部输入如何进入回合 | 提示词拼装、压缩与上下文预算 |
| Agent 角色 | 外部客户端可以发起含子 Agent 的回合，但不定义角色语义 | 角色声明、覆盖与 AGENTS.md |
| LLM 渠道管理 | 外部客户端不直接持有 Provider 凭据 | Provider 解析、鉴权与请求协议 |

## 7. 已确认边界与未验证事项

已确认的边界：

- app-server 是“外部控制 Codex”的入口，不是模型 Provider 代理；它不转发原始模型请求。
- exec-server 是“Codex 控制外部执行体”的入口，执行体不参与模型决策。
- remote control 复用 app-server 协议，不另建一套会话模型。
- 三者都不改变 Codex 本地的审批与沙箱责任；外部只提供输入、回答与执行位置。

未验证事项：

- 未构建或启动 app-server，未验证 stdio、Unix socket、WebSocket 三种传输的真实握手与断线行为。
- 未启动 exec-server，未验证 stdio 子进程、WebSocket 与 Noise rendezvous 的连接、重连和进程恢复。
- 未连接真实 remote control 中继，未验证 enrollment、token 刷新、配对码有效期与客户端撤销的实际时序。
- 未运行 Python SDK，未验证通知路由、审批回调与回合结果收集在异常路径下的行为。
- 未验证多客户端同时连接、认证主体切换与工作区切换时的队列清理。

## 关键源码索引

- `codex-rs/app-server/src/main.rs:42-79`：监听地址、会话来源、remote control 开关。
- `codex-rs/app-server/src/message_processor.rs:995-1099`、`:1359-1370`、`:1738-1747`：初始化门禁、回合准入与请求分发。
- `codex-rs/app-server/src/turn_admission.rs`：回合准入、暂停与 drain。
- `codex-rs/app-server/src/connection_rpc_gate.rs`：连接级 RPC 门禁。
- `codex-rs/app-server-protocol/src/protocol/common.rs:1861-1910`、`:2049-2062`：服务端请求与通知。
- `codex-rs/app-server-transport/src/connection_auth.rs`：认证主体代际。
- `codex-rs/app-server-transport/src/transport/remote_control/`：注册、配对、客户端管理与 WebSocket 中继。
- `codex-rs/exec-server-protocol/src/protocol.rs:25-63`、`:376-414`、`:1245-1267`：执行体协议、进程参数与事件。
- `codex-rs/exec-server/src/environment.rs:72-90`：环境连接状态。
- `codex-rs/exec-server/src/environment_toml.rs:26-57`：`environments.toml` 字段。
- `codex-rs/exec-server/src/environment_registry.rs`：执行体注册与 harness 密钥授权。
- `codex-rs/exec-server-cli/src/command.rs:60-128`：独立执行体的传输与远端注册参数。
- `sdk/python/src/openai_codex/client.py:215-256`、`:478-500`、`:650-700`：SDK 驱动 app-server。
- `codex-rs/websocket-auth/src/lib.rs:31-65`：WebSocket 认证模式。
