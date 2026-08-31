# VCPChat 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`89e02b778d626078be91dfbad01e5c9554c47f76`（分支：`main`）
>
> 调查方式：静态阅读 VCPChat 分布式节点启动、连接、注册与执行回流代码，并交叉阅读 VCPToolBox 的 WebSocket 调度、文件回取和人类工具端点；复用既有 VCPChat Agent 工具与独特功能笔记；未启动 Electron、VCPToolBox 或真实节点
>
> 调查范围：VCPChat 作为连接 VCPToolBox 的外部执行节点，以及 VCPToolBox 人类工具面和跨节点文件回流；排除普通模型 Provider、仅展示工具文本块、DESKTOP_PUSH 本地旁路和宿主内的 Flowlock 续写
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 达到外部执行体 `主链确认`（静态证据）：Electron 主进程在设置默认开启时启动独立的 VCPDistributedServer，使用 VCPLog URL 和 key 连接 VCPToolBox，注册本机插件 manifest；VCPToolBox 将这些能力登记为分布式工具，并以 `execute_tool` 下发调用。节点在本机 Node/Python 子进程或主进程注入 handler 中执行，随后以 `tool_result` 将结果回传（`main.js:455-481`；`VCPDistributedServer/VCPDistributedServer.js:259-357,594-667`）。

关系中的执行权分层明确：VCPToolBox 保存已连接节点、可发现工具和在途请求；VCPChat 保存本机插件、Electron 窗口与本地文件/设备能力。普通模型输出中的工具文本块不会在 VCPChat 聊天 renderer 内解析执行，真正的执行调度在上游服务与本地节点之间完成。DESKTOP_PUSH 直接由 renderer 创建桌面挂件，未经过该协议，故不纳入本篇主链。

VCPToolBox 也提供 `/v1/human/tool`，使 VCPChat 的 HumanToolBox 等外部控制表面能够以文本工具协议发起同一插件执行路径。跨节点文件则通过请求来源 IP 找到节点，向节点发出内部 `internal_request_file`，取回 Base64 后缓存到服务端。本次未确认这些链路的端到端鉴权、真实取消、断线恢复或多节点竞争行为。

## 接入角色与系统边界

| 外部对象 | 关系角色 | 身份与状态权威 |
|---|---|---|
| VCPChat VCPDistributedServer | 外部执行体 | 节点名称、WebSocket 连接、本机插件、Electron 注入服务和本地执行结果 |
| VCPToolBox WebSocketServer | 协作宿主/调度者 | 节点 ID、注册的分布式工具、在途请求、超时与断线清理 |
| VCPChat 本机插件与主进程 handler | 实际执行资源 | Node/Python 子进程，或音乐、骰子、Flowlock、桌面控制等 Electron handler |
| VCP HumanToolBox / 人类客户端 | 外部控制表面 | 用户填写的工具块，经 HTTP 请求 VCPToolBox 触发执行 |
| 跨节点文件来源 | 外部资源 | file URL 所属节点、本机读取结果、VCPToolBox 文件缓存 |

VCPChat 的节点不是单次 MCP 调用：它具有可识别连接身份、连接/重连生命周期、工具注册、双向请求结果、节点与远端工具映射及服务端超时/断线治理。因此符合本类目的外部执行体准入。聊天中渲染的工具请求和结果卡仅为显示，不拥有独立 runtime，不纳入。

## 完整主链

```text
VCPChat 启动且 enableDistributedServer 为真
  -> 主进程创建 VCPDistributedServer，注入 VCPLog URL/key 与本机 handler
  -> 节点连接 VCPToolBox /vcp-distributed-server/VCP_Key=<key>
  -> 节点扫描 manifest 并发送 register_tools
  -> VCPToolBox 登记节点工具与节点状态
  -> 上游选择该分布式工具，VCPToolBox 发送 execute_tool(requestId)
  -> VCPChat 执行插件子进程或主进程 handler
  -> 节点发送 tool_result(requestId)
  -> VCPToolBox 解除 pending request，结果回到原工具调用链
```

节点断开时，VCPToolBox 取消该节点的工具登记，并 reject 该节点所有在途请求；发起端超时也会删除 pending 项并尝试向支持的节点发送取消命令（`VCPToolBox/WebSocketServer.js:506-514,900-970`）。这证明服务端拥有任务等待状态，但不等同于已确认本机子进程一定被终止。

## 身份、协议与状态映射

VCPChat 在 renderer 可用后读取设置；关闭 `enableDistributedServer` 时不启动节点，默认值为 true。启动参数将 `vcpLogUrl`、`vcpLogKey`、稳定的显示名、renderer WebContents 与若干主进程 handler 注入节点实例（`main.js:455-481`；`modules/utils/appSettingsManager.js:211-220`）。节点据 URL 将 HTTP(S) 形式转换为 WebSocket，并以 URL 中的 VCP key 连接服务端（`VCPDistributedServer/VCPDistributedServer.js:259-280`）。

连接建立后，节点扫描可注册插件并发送 `register_tools`。VCPToolBox 从消息中排除内部文件工具，登记其余 manifest 到该 server ID，同时保存显示名、能力和最后活动时间。节点断线时服务端注销同一 server ID 的所有工具，故“本机能力属于哪个执行体”的映射随连接生命周期建立和撤销（`VCPDistributedServer/VCPDistributedServer.js:320-357`；`VCPToolBox/WebSocketServer.js:724-746,506-514`）。

工具调用使用 requestId 关联。服务端创建 pending 条目后发送工具名和参数；VCPChat 收到后将 `_vcpContext` 与模型工具参数分离传给插件执行入口。这表示调用上下文在协议层可独立携带，但当前服务端分发片段只明确发送工具名和参数，完整上下文字段在所有调用路径中的传递一致性未逐项核实（`VCPToolBox/WebSocketServer.js:910-970`；`VCPDistributedServer/VCPDistributedServer.js:607-667`）。

## 执行、回流与控制语义

节点对 `execute_tool` 调用统一入口。一般插件由 Plugin Manager 执行；hybridservice direct 插件的对象或字符串保持原结果语义。音乐、骰子、Flowlock 和桌面控制属于显式特例：节点先取得插件结果或参数，再调用由 Electron 主进程注入的 handler，因此副作用发生在 VCPChat 的本机窗口与设备域（`VCPDistributedServer/VCPDistributedServer.js:661-762`）。既有 Agent 工具笔记已确认其他本机插件可启动 Node/Python 子进程，涵盖 shell、文件、屏幕和媒体能力；这些具体工具权限另见相邻类目。

文件回流是一条专用协作链：VCPToolBox 从请求 IP 找到节点，调用 `internal_request_file`；节点只接受 `file://` URL，在其本地文件系统读取并将 Base64 与 MIME 类型作为工具结果返回。服务端将成功结果缓存成本地文件，之后以缓存 URL 继续处理（`VCPToolBox/FileFetcherServer.js:102-143,154-184`；`VCPChat/VCPDistributedServer/VCPDistributedServer.js:619-657`）。这形成外部节点提供资源、宿主保存可消费副本的双向链，而非把远端路径误当服务端本地路径。

人类控制表面使用另一条入口：VCPToolBox 的 `/v1/human/tool` 解析文本工具请求，保留请求 IP 并交给 Plugin Manager。该 API 可将 VCPChat HumanToolBox 等独立应用的表单操作接入同一工具执行生态，但具体客户端的 Bearer 鉴权配置、用户身份与工具审批回合需要结合运行环境验证（`VCPToolBox/server.js:1248-1298`）。

## 权限、凭据与治理边界

节点连接使用 VCP key，且 key 位于连接 URL；本次只确认连接构造，未在两端完成握手校验及传输层加密的端到端验证。服务端对已连接节点保存 pending 请求，超时后会清理状态并调用取消发送逻辑，节点断开会立即拒绝其 pending 请求（`VCPToolBox/WebSocketServer.js:900-970`）。

对本机执行而言，VCPChat 节点在收到 `execute_tool` 后直接按工具名和参数分发。现有静态证据未见节点端逐消息签名或对服务端下发工具的第二次权限审批；工具审批策略主要由 VCPToolBox 的插件管理和人类审批链承担，不能仅由 VCPChat 节点连接推断为本机沙箱。`internal_request_file` 只校验 URL 协议并读取节点可访问路径，路径授权与跨节点来源可信性需要运行及部署配置复核。

外部输入会触及本机文件、命令、窗口和设备等高副作用资源。服务端断线/超时有状态收口，但 VCPChat 的子进程杀灭、主进程 handler 中断和已发生副作用的补偿均未在本次运行验证，不能将“发送取消”写成“执行必然取消”。

## 相邻类目交接

- 本机工具目录、执行位置、工具审批 UI 与 DESKTOP_PUSH 旁路见 [Agent 工具笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- Loom、Scriptorium、移动同步和人类工具箱的产品面见 [独特功能笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- VCPToolBox 作为宿主的分布式节点、SSH、浏览器和 CLI worker 侧能力见 [VCPToolBox 外部执行体与应用协作笔记](VCPToolBox-外部执行体与应用协作调查笔记.md)。

## 已确认边界与未验证事项

- 主链确认范围是“VCPChat 节点注册 -> VCPToolBox 分派 -> 本机执行入口 -> `tool_result` 回流”，不包含真实 VCP key、WebSocket 连通或任何实际工具副作用。
- 未运行多节点同时注册同名工具、节点重连后的重新注册、在途请求与重连的竞态，以及 IP 到节点的来源识别准确性。
- 未验证服务端超时后的取消帧是否被当前 VCPChat 节点消费并进一步杀灭对应 Node/Python 子进程；已确认的是服务端 pending 状态清理。
- 未验证 VCPChat 本机 `internal_request_file` 的真实文件访问范围、超大文件内存占用、缓存失效和请求 IP 在反向代理部署中的语义。
- 未验证 HumanToolBox 到 `/v1/human/tool` 的真实认证、审批、审计和用户身份映射；本页只确认服务端解析与执行入口。
- DESKTOP_PUSH、Flowlock 的 renderer 自主续写和聊天中工具块展示具有本地或 UI 语义，但不构成此篇的外部协作主链。

## 关键源码索引

- `main.js:455-481`：VCPChat 节点按设置启动及 Electron handler 注入。
- `modules/utils/appSettingsManager.js:211-220`：分布式节点默认设置。
- `VCPDistributedServer/VCPDistributedServer.js:259-357`：连接、重连与 manifest 注册。
- `VCPDistributedServer/VCPDistributedServer.js:594-762`：工具接收、本机执行、文件读取和特例 handler。
- `VCPToolBox/WebSocketServer.js:724-746`：节点工具注册与状态映射。
- `VCPToolBox/WebSocketServer.js:900-970`：分布式分派、超时与 pending request。
- `VCPToolBox/FileFetcherServer.js:102-184`：跨节点文件识别、拉取与缓存。
- `VCPToolBox/server.js:1248-1298`：人类工具控制入口。
