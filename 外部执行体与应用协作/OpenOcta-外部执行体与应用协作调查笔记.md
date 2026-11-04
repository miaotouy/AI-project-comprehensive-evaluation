# OpenOcta 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态阅读 IM 通道路由、入站下沉、Hooks、OpenAPI、本地 CLI Agent、MCP 客户端、蜂群、A2A Card 与 ACP 占位代码；未连接真实 IM 平台、未调用真实外部 CLI Agent，也未发起网络请求
>
> 调查范围：宿主控制外部 CLI Agent、外部应用经 OpenAPI 调用宿主、IM 与 webhook 入站控制、MCP 工具接入、A2A/ACP 边界；排除模型 Provider、普通工具语义、Chat UI 视觉和业务应用 OAuth 细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 按本类目准入标准，OpenOcta 当前有三条可静态走通的协作主链：IM 渠道入站控制宿主 Agent、OpenAPI 第三方应用调用宿主 Agent、Hooks webhook 触发宿主 Agent。三者都最终汇入 `chat.send`，共享同一 Agent 运行时。
- 宿主调用外部执行体的主链是 `local_agent` 工具。它可以探测本机安装的 CLI Agent、执行单个任务或并行执行多个任务，并回传合并后的文本输出。判定为“入口确认”：发起和执行路径清楚，但没有外部会话映射、流式回传、取消到真实执行体的完整语义，也没有审批。
- 外部应用接入以 OpenAPI 为主。API key 绑定路径白名单、模型白名单、月 token 限额和数字员工绑定；非员工绑定时还可以按 key 过滤技能与 MCP，员工绑定则复用员工自身配置。请求同步等待 Agent 完成后返回 OpenAI 风格响应。判定为“主链确认”。
- IM 渠道覆盖钉钉、飞书、QQ、企业微信和微信。入站消息经 `hooksAgentSink` 转为 `HooksAgent` 调用，再进入 `chat.send`；回复通过通道运行时回发。判定为“主链确认”，但真实平台连接、重连和媒体消息未运行验证。
- MCP 只作为工具接入层存在：宿主作为客户端连接 stdio 或 HTTP 服务并把工具桥接给模型。判定为“入口确认”，不具备账号、业务资源和动作级权限模型，不作为完整外部应用协作主链。
- A2A 只暴露 `/.well-known/agent.json` 的 GET/HEAD AgentCard。检查 `src/pkg/gateway/http` 的路由注册和 `src/pkg/a2a` 包后，本次未找到 JSON-RPC 任务接收、任务状态查询或消息发送入口。ACP 客户端和服务端都是 stub，插件接口没有外部加载路径。三者判定为“候选观察”或“不纳入”。
- 蜂群子 Agent 复用宿主运行时，属于指南明确排除的“宿主内建子 Agent”，不纳入本类目。
- 安全边界上有一个影响全部 HTTP 接入的事实：`gatewayHTTPAuthDisabled` 被硬编码为 true，所有 `requireGatewayToken` 路由的网关令牌校验被全局短路。OpenAPI、Hooks 和 IM 仍各自校验自己的凭据，但普通 `/api/*` 路由没有网关级鉴权。

## 接入角色与系统边界

| 对象 | 关系 | 协议与方向 | 状态权威 | 本次判定 |
|---|---|---|---|---|
| 本地 CLI Agent | 宿主调用外部执行体 | 子进程 stdin 参数、stdout/stderr 回传 | 外部进程 | 入口确认 |
| IM 渠道 | 外部客户端控制宿主 Agent | 平台 SDK/长连接入站，通道运行时出站 | 宿主会话 | 主链确认 |
| OpenAPI 调用方 | 外部应用调用宿主 Agent | HTTP POST，同步响应 | 宿主会话 | 主链确认 |
| Hooks 调用方 | 外部系统触发宿主 Agent | HTTP POST webhook | 宿主会话 | 主链确认 |
| MCP 服务器 | 宿主调用外部工具服务 | stdio 或 HTTP/SSE | 外部服务 | 入口确认 |
| A2A 对端 | 潜在的外部 Agent 互操作 | AgentCard 发现 | 未确认 | 候选观察 |
| ACP 对端 | 潜在的外部控制协议 | 占位 | 未确认 | 不纳入 |
| 蜂群成员 | 宿主内建子 Agent | 进程内调用 | 宿主 | 不纳入 |

## 完整主链

### A. IM 入站控制宿主 Agent

1. Gateway 启动时注册内置通道插件，并从 `channels.*` 配置创建运行时。当前工厂只覆盖企业微信、微信、钉钉、飞书和 QQ，见 `src/pkg/gateway/http/server.go:733-757`。`whatsapp` 包存在但未注册，Telegram、Discord 等只出现在展示顺序列表，见 `src/pkg/channels/registry.go:9-13`。
2. 通道运行时收到消息后，把 `InboundMessage` 交给统一的入站下沉器。下沉器实现见 `src/pkg/gateway/http/inbound_sink.go:32-93`。
3. 下沉器构造 sessionKey。默认形式是 `agent:main:channel:<channelId>:<peerId>`；如果该渠道配置了 `digitalEmployeeId` 且员工仍存在，则改用 `agent:main:employee:<employeeId>`，见 `inbound_sink.go:53-70`。
4. 下沉器调用 `HooksAgent`，后者把消息转成 `chat.send`，并保留渠道、收件人、消息 ID、元数据和超时，见 `src/pkg/gateway/http/server.go:296-324`。
5. Agent 运行完成后，聊天处理器把最终可见文本交给通道运行时发送。投递入口见 `src/pkg/gateway/handlers/chat.go:805-847`。
6. 通道运行时负责平台侧的会话 webhook、token 缓存、媒体上传或流式回复。钉钉、飞书和微信各自的实现位于 `src/pkg/channels/<channel>/runtime.go`。

这条主链的“外部控制面”是 IM 客户端：用户可以在宿主之外发起消息并观察回复。宿主不反向接管 IM 会话，也没有把平台线程 ID 映射为独立任务对象；映射粒度是 sessionKey。

### B. OpenAPI 第三方应用

1. 调用方以 `Authorization: Bearer <key>` 或专用 header 提交 key，入口见 `src/pkg/gateway/http/open_api.go:17-29`。
2. 服务端用 key 哈希认证，并检查启用状态和月度用量重置，见 `src/pkg/apikeys/service.go:356-381`。
3. 请求路径必须命中 key 的允许前缀。默认允许 `ping` 和 `completion`，见 `src/pkg/apikeys/types.go:8-12` 与 `open_api.go:92-96`。
4. `completion` 要求 `model` 字段，并检查模型白名单和月 token 预算，见 `src/pkg/gateway/http/open_api.go:145-157`。
5. 处理器根据 API key 绑定模式生成 sessionKey。员工绑定使用 `agent:main:employee:<id>:run:open-api:<keyId>:<conversation>`；普通绑定使用 `agent:main:open-api:<keyId>:<conversation>`，见 `src/pkg/gateway/handlers/open_api_chat.go:149-162`。
6. 处理器把模型引用和消息正文交给 `chat.send`；非员工绑定还会带上技能与 MCP 过滤资源，员工绑定则返回空资源让员工配置生效，见 `open_api_chat.go:69-76` 与 `185-196`。
7. 处理器注册运行 waiter 并同步等待结果，成功后返回 OpenAI 风格 completion，并记录 token 用量，见 `src/pkg/gateway/http/open_api.go:170-190` 与 `open_api_chat.go:90-138`。

该入口不支持流式响应，代码在收到 `stream=true` 时直接返回 501，见 `open_api_chat.go:40-42`。调用方身份是 API key，不是终端用户；同一个 key 的同一 conversation 会复用会话。

### C. Hooks webhook

1. `POST /hooks/{wake|agent|alert}` 进入统一处理器，见 `src/pkg/gateway/http/hooks.go:77-145`。
2. 配置可以整体禁用 Hooks；配置了 token 时，请求必须携带匹配的 token，见 `hooks.go:89-105`。
3. `wake` 向主会话广播系统事件，并异步写入一条 `[系统事件]` 消息，见 `src/pkg/gateway/http/server.go:279-294`。
4. `agent` 把消息、sessionKey、渠道、收件人、模型、思考级别和超时传给 `HooksAgent`，见 `hooks.go:201-231`。
5. `alert` 构造 SRE 风格的告警分析提示，生成独立 sessionKey 后调用同一个 Agent 回调，见 `hooks.go:284-330`。

Hooks 的 sessionKey 可以由请求指定，也可以由配置映射指定。未指定时使用 `hook:<runId>` 作为临时 key，见 `server.go:296-302`。这意味着调用方可以选择把多次 webhook 归入同一会话，也可以每次创建新会话。

### D. 宿主调用本地 CLI Agent

1. `chat.send` 在 `localAgents` 启用时把 `local_agent` 加入工具列表，默认启用，见 `src/pkg/agent/tools/local_agent_tool.go:162-176` 与 `src/pkg/gateway/handlers/local_agents.go:30-43`。
2. 工具支持状态探测、单任务执行和并行多任务执行三种动作，动作名分别是 status、run 和 run_many。状态探测返回本机探测结果，单任务动作执行一个任务，多任务动作并行执行多个任务，见 `src/pkg/agent/tools/local_agent_tool.go:22-78`。
3. 探测阶段按 PATH 和常见安装路径寻找可执行文件，并缓存结果，见 `src/pkg/localagents/probe.go:51-175`。
4. 执行阶段用 `exec.CommandContext` 启动子进程，工作目录设为 Agent workspace，stdout 和 stderr 被缓冲，见 `src/pkg/localagents/runner.go:63-110`。
5. 进程结束后，输出按段合并为文本返回模型；失败时把输出和错误信息一起写入结果，见 `runner.go:98-110` 与 `137-160`。
6. 默认超时为 10 分钟，可由 `localAgents.timeoutSeconds` 覆盖，见 `runner.go:22-29`。

这条链的“执行体”是外部 CLI Agent，但宿主只把它当作一次性命令：没有外部会话 ID、没有继续对话、没有流式事件、没有取消确认，也无法在宿主重启后恢复。

### E. MCP 工具接入

1. 会话运行时按合并后的 MCP 配置创建 Manager，Manager 逐个连接启用的服务器，见 `src/pkg/acp/mcp/manager.go:27-48`。
2. 连接方式支持 stdio 命令、HTTP URL 和内置 service。URL 以 `/sse` 结尾时使用 SSE，否则优先 streamable HTTP，失败后回退 SSE，见 `src/pkg/acp/mcp/client.go:72-126`。
3. Manager 调用 `tools/list`，把每个工具包装成 Agent 工具；工具调用转发到 `tools/call`，见 `src/pkg/acp/mcp/manager.go:111-132` 与 `159-205`。
4. MCP 连接随会话运行时驱逐关闭，见 `src/pkg/gateway/handlers/chat.go:2358-2362`。

MCP 服务器在这里是工具提供方，不是拥有独立身份和业务资源的外部应用。它满足“外部进程或协议服务”的一面，但不满足账号、installation 和动作级权限的一面。检查 `src/pkg/acp/mcp` 与 Gateway 路由后，本次未找到 OpenOcta 作为 MCP 服务器对外暴露工具或资源的入口。

## 身份、协议与状态映射

| 对象 | 身份绑定 | 本地状态映射 | 重启或断线后 |
|---|---|---|---|
| IM 渠道 | 平台账号凭据 + 渠道配置 | 渠道 ID 与 peer 映射到 sessionKey | 由通道运行时重新连接；会话仍按 key 查找 |
| OpenAPI | API key 哈希 | key ID + conversation 映射到 sessionKey | 会话可按 key 恢复；运行中的请求不恢复 |
| Hooks | Hooks token | 请求或映射指定 sessionKey | 会话可按 key 恢复；运行中的请求不恢复 |
| 本地 CLI Agent | 本机可执行文件路径 | 无外部会话映射 | 不恢复 |
| MCP | 服务器配置 | 工具名映射到 Agent 工具 | 运行时重建时重新连接 |
| A2A | AgentCard 中的 URL | 无 | 未确认 |

IM 渠道的 peer 会被转成小写用于 sessionKey，但回复仍保留原始 ID，见 `src/pkg/gateway/http/inbound_sink.go:50-57`。这是一个有意的双轨处理：会话键稳定，平台回传标识不丢。

OpenAPI 的 conversation ID 只保留字母、数字、连字符和下划线，超长截断到 64 字符，见 `src/pkg/gateway/handlers/open_api_chat.go:164-183`。这避免了 sessionKey 注入，但也意味着不同原始 ID 可能在清洗后冲突。

## 执行、回流与控制语义

### 回流内容

- IM 回流是最终可见纯文本。处理器会剔除工具调用前后的中间文本，只取最后一个工具块之后的回复，见 `src/pkg/gateway/handlers/chat.go:1070-1118`。
- OpenAPI 回流是同步 JSON，包含 content、model 和 token 统计；工具调用过程不暴露给调用方。
- Hooks 回流只有 `runId` 和 202 状态，实际结果写入宿主会话，调用方需要另行读取会话或等待投递。
- 本地 CLI Agent 回流是合并后的 stdout/stderr 文本；没有结构化事件。
- MCP 回流是工具结果文本，进入普通工具结果通道。
- IM、OpenAPI 和 Hooks 都只回传最终文本；reasoning、工具事件、文件变化和审批状态留在宿主，不随外部响应返回。

### 取消与恢复

| 对象 | 取消语义 | 恢复语义 |
|---|---|---|
| IM | 宿主运行可被聊天中止控制器取消；平台侧无撤回 | 同一 sessionKey 继续对话 |
| OpenAPI | HTTP 请求取消会传入运行上下文 | 同一 conversation 继续；无断点续传 |
| Hooks | 请求返回后无法取消 | 同一 sessionKey 继续 |
| 本地 CLI Agent | 上下文取消会终止子进程 | 不恢复，不重放 |
| MCP | 调用随运行上下文结束 | 重新连接后可再次调用 |

本地 CLI Agent 的取消只到 `exec.CommandContext` 层，没有先把取消意图传给外部 Agent 的协议，也没有确认外部进程是否清理了子任务。这一点与“取消到达真实执行体”的准入要求存在差距。

## 权限、凭据与治理边界

### HTTP 网关鉴权

`gatewayHTTPAuthDisabled` 是编译期常量 true，令牌校验函数在入口处直接返回 true，见 `src/pkg/gateway/http/auth.go:16-17` 与 `55-65`。所有使用网关令牌包装的 `/api/*` 路由因此不会校验网关令牌。

WebSocket 连接仍校验配置的 gateway token，见 `src/pkg/gateway/ws/hub.go:391-410`。所以“HTTP 全放行、WS 仍校验”是当前快照的实际边界，而不是统一的网关鉴权模型。

### 各入口凭据

| 入口 | 凭据 | 校验位置 |
|---|---|---|
| OpenAPI | API key 哈希 | `src/pkg/apikeys/service.go:356-381` |
| Hooks | 配置中的 Hooks token | `src/pkg/gateway/http/hooks.go:95-105` |
| IM | 平台应用凭据、机器人 token | 各通道运行时 |
| MCP | 服务器命令、环境变量或 URL | 各服务器配置 |
| 本地 CLI Agent | 本机可执行文件权限 | 操作系统用户 |

API key 的明文只在创建或管理员读取时返回，存储保存哈希和可选的加密副本，见 `src/pkg/apikeys/types.go:14-33`。这比把明文 key 直接落盘更严格，但读 secret 的管理接口仍能取回明文。

### 外部内容处理

Hooks 的 `message` 会直接进入 Agent 提示，`alert` 会把告警 JSON 拼进分析提示。配置中存在 `AllowUnsafeExternalContent` 字段，但本次未找到任何读取点，见 `src/pkg/config/schema.go:953-969` 与 `src/pkg/gateway/http/hooks.go` 全文检索结果。因此当前没有看到对外部内容做信任分级或隔离的实现。

IM 消息同样作为用户输入进入 Agent。若 Agent 拥有 `execute`、`local_agent`、MCP 工具或文件写入能力，外部消息可以间接驱动这些能力；审批只覆盖 `execute`，且需要显式开启。

### 可见性

- 通道状态通过 `channels.status` 返回账号快照，包含运行状态、最近启动时间、最近错误和部分连接元数据，见 `src/pkg/gateway/handlers/channels.go:308-365`。
- 本地 CLI Agent 的安装探测通过 `localAgents.probe` 和 `localAgents.status` 暴露，见 `src/pkg/gateway/handlers/local_agents.go:45-75`。
- 聊天中的工具卡从 `tool_call` 事件读取工具名和参数，见 `src/pkg/gateway/handlers/chat.go:2713-2717`。当前没有专门展示“外部执行位置”“外部会话 ID”或“接管入口”的字段；本次也未找到从 UI 重新接管或继续本地 CLI Agent 任务的入口。

### 本地 CLI Agent 的治理

`localAgents.allowed` 可以限制允许委派的 Agent 列表，未安装或不在列表内的目标会被拒绝，见 `src/pkg/localagents/runner.go:63-78`。`localAgents.requireApproval` 字段存在，但本次未找到读取点。

外部 CLI Agent 以当前用户权限运行，工作目录是 Agent workspace。宿主不解析外部 Agent 的工具调用，也不回收其文件变更清单；只能从最终文本推断执行结果。

## 相邻类目交接

| 相邻类目 | 本笔记记录 | 留在相邻类目 |
|---|---|---|
| Agent 工具 | `local_agent`、MCP 工具、审批与执行边界 | 工具目录、参数校验、循环与结果回注细节 |
| Agent 角色 | 数字员工绑定、员工 prompt/skills/MCP 如何被外部入口复用 | 角色存储、提示词优先级和模型绑定 |
| 会话与消息管理 | sessionKey 如何由渠道、key、conversation 生成 | 会话存储、历史和恢复的整体语义 |
| 消息渲染器 | 回流文本和工具结果的形状 | 工具卡、附件、错误和折叠展示 |
| Chat UI | 外部入口不直接可见 | 审批入口、连接状态和用户反馈 |

## 已确认边界与未验证事项

### 已确认边界

- 外部入口最终都汇入 `chat.send`，没有独立的外部 Agent runtime。
- IM 入站的身份绑定粒度是渠道配置加 peer，不是平台账号级的 installation 对象。
- OpenAPI 是同步请求-响应，不支持流式；调用方看不到工具过程。
- Hooks 是单向触发，结果留在宿主会话，调用方只得到 run ID。
- 本地 CLI Agent 是一次性命令执行，没有外部会话、流式事件和取消确认。
- MCP 是工具桥接，不是带账号和业务资源的 Connector。
- A2A 只有发现卡片，本次未找到任务接收与状态查询入口。
- ACP 客户端和服务端均为 stub，见 `src/pkg/acp/client.go:3-27` 与 `src/pkg/acp/server.go:3-15`。
- 插件接口只有内置通道使用的基类。检查 `src/pkg/channels/plugin.go`、`registry.go` 和 Gateway 路由注册后，本次未找到外部插件加载或生命周期入口。
- 蜂群复用宿主运行时，按指南不纳入外部协作。

### 未验证事项

- 未连接钉钉、飞书、QQ、企业微信或微信，未验证真实入站、重连、媒体上传和流式回复。
- 未验证微信 iLink 会话过期后的重新登录流程。
- 未调用真实 OpenAPI，未验证长任务超时、并发 key 限额和 conversation 冲突。
- 未验证 Hooks token 为空时的实际暴露面，以及 `alert` 提示在真实告警负载下的行为。
- 未安装外部 CLI Agent，未验证探测路径、参数拼接、并行执行和取消后的进程清理。
- 未连接真实 MCP 服务器，未验证 SSE/streamable HTTP 回退、工具名冲突和超时。
- 未验证 A2A 对端是否会仅凭 AgentCard 发起请求，也未找到对应的服务端处理代码。
- 未在真实网络环境中验证 `gatewayHTTPAuthDisabled` 的影响范围；本结论仅来自静态常量与路由包装。

## 关键源码索引

- IM 入站与 sessionKey：`src/pkg/gateway/http/inbound_sink.go:32-93`
- 通道注册与工厂：`src/pkg/gateway/http/server.go:733-757`、`src/pkg/channels/builtin/register.go:13-23`
- Hooks 入口：`src/pkg/gateway/http/hooks.go:77-330`
- Hooks Agent 回调：`src/pkg/gateway/http/server.go:279-324`
- OpenAPI 入口与鉴权：`src/pkg/gateway/http/open_api.go:17-190`
- OpenAPI 会话与执行：`src/pkg/gateway/handlers/open_api_chat.go:36-193`
- API key 模型与校验：`src/pkg/apikeys/types.go:8-33`、`src/pkg/apikeys/service.go:356-429`
- IM 回复投递：`src/pkg/gateway/handlers/chat.go:805-847`
- 本地 CLI Agent：`src/pkg/agent/tools/local_agent_tool.go:22-176`、`src/pkg/localagents/runner.go:22-160`、`src/pkg/localagents/probe.go:51-175`
- MCP：`src/pkg/acp/mcp/manager.go:27-157`、`src/pkg/acp/mcp/client.go:72-126`
- A2A Card：`src/pkg/gateway/http/a2a.go:13-52`、`src/pkg/a2a/card/builder.go:12-23`
- ACP 占位：`src/pkg/acp/client.go:3-27`、`src/pkg/acp/server.go:3-15`
- 网关鉴权短路：`src/pkg/gateway/http/auth.go:16-65`
