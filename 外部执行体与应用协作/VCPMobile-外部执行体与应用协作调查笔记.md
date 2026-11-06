# VCPMobile 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5`（分支：`main`）
>
> 调查方式：静态走读分布式节点协议、工具注册表、设置与 Android 权限入口；未连接 VCP 分布式服务或调用真实设备权限
>
> 调查范围：手机作为外部可执行设备节点的连接、调用、回流与治理；协作链的统计范围限于节点与设备执行，普通模型 Provider、聊天请求和单次文件上传归入其他类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 满足本类目的“外部控制与交互表面”准入：它以配置中的设备名和 VCP Key 连接外部 VCP 分布式服务，接收服务端的结构化工具调用，在 Android 本机执行后把结果送回同一 WebSocket 会话。外部服务拥有请求发起、调度和连接确认；手机拥有本地工具注册表、系统权限和实际执行环境。连接状态映射为前端可见的 server/client ID、会话代次、已注册工具数和最后错误（`src-tauri/src/distributed/client.rs:586-1340`；`src/features/distributed/composables/useDistributed.ts:34-167`）。

这不是外部 Agent runtime：当前协议在连接确认与 `execute_tool` 之外还解析 `cancel_tool`，但没有发现独立工具循环、外部会话映射、任务审批或远端 Agent 继续执行语义。它也不同于普通 MCP 配置，因为设备有可识别身份、持续连接、反向命令、结果回传和本机可治理工具目录。

## 接入角色与系统边界

外部对象是 VCP 分布式服务；移动端由服务端地址、VCP Key 和用户设置的设备名识别。设置页从 VCPLog 的 WebSocket 地址和 Key 派生分布式连接参数，用户开启开关后保存设置；后端在启动和设置改变时调和分布式节点（`src/components/layout/RightSidebar.vue:38-40`；`src-tauri/src/vcp_modules/infra/settings_manager.rs:37-60、settings_manager/repository.rs:1-2438`）。

移动端的 `DistributedState` 管理一个连接客户端、工具注册表和遥测中心，并由 Tauri 应用在启动时创建（`src-tauri/src/distributed/mod.rs:20-40`；`src-tauri/src/lib.rs:19-90`）。它不依赖聊天 Store，故设备节点能在聊天 UI 之外维持自己的连接与工具状态。

## 完整主链

```text
用户保存“分布式节点”开关与设备名
  -> 生命周期调和从 wsUrl + VCP Key 建立 WebSocket
  -> 服务端 ConnectionAck 返回 serverId/clientId
  -> 手机发送启用工具的 manifest 与静态占位符
  -> 服务端发 execute_tool(requestId, toolName, toolArgs)
  -> 注册表在 Android 本机执行对应工具
  -> 手机回传 ToolResult(requestId, status, result/error)
  -> 前端订阅连接状态并展示工具数、ID 和错误
```

连接地址携带 Key 并使用固定分布式路径；连接成功后先记录 server/client ID、注册当前启用的工具，再报告 IP 与静态占位符。接到执行请求时，请求追踪器先声明 request ID，随后在子任务中取得保活租约、调用注册表并发送成功或失败结果，不阻塞 WebSocket 接收循环；`cancel_tool` 会按 request ID 取消对应入站请求（`src-tauri/src/distributed/client.rs:586-720,1298-1340`）。

断线会由 5 秒起、最大 60 秒的指数退避重连；网络恢复事件可以触发立即重连。该机制确认重连意图和状态更新，未在真实网络下验证幂等、服务端去重或断线期间的请求补偿（`src-tauri/src/distributed/client.rs:586-720`；`src-tauri/src/lib.rs:75-100`）。

## 身份、协议与状态映射

协议的入站类型解析 `connection_ack`、`execute_tool` 与 `cancel_tool`；出站包含注册工具、静态占位符更新和工具结果。请求关联键是服务端提供的 `requestId`，连接代次防止旧会话 ACK 覆盖新状态（`src-tauri/src/distributed/types.rs:18-260`；`src-tauri/src/distributed/client.rs:1298-1340`）。外部请求不绑定 Chat topic；其中 CLI 适配器用稳定远端身份派生会话 ID，并以身份与请求 ID 派生持久化操作键，转交本机 job 运行时，支持幂等重放和轮询。此会话用于 shell/job 身份隔离，未接入聊天历史。见 [CLI 身份适配](../../VCPMobile/src-tauri/src/distributed/tools/vcp_mobile_cli.rs#L84-L144)。本次检查节点与 CLI 入口未找到外部账号安装或 OAuth 刷新。

工具清单来自本地注册表。当前快照注册设备信息、通知、剪贴板、`VCPMobileCLI`，以及电量、CPU/GPU、内存、网络、存储、位置、运动、环境传感器和设备状态摘要等项目；manifest 只发送处于启用状态的工具（`src-tauri/src/distributed/tools/mod.rs:29-63`；`src-tauri/src/distributed/tool_registry.rs:468-520`）。README 中“14 项”与当前 `build_registry` 中可见注册调用一致，共四项一次性工具与十项流式工具，未接线的交互式相机工具在计数之外。

## 执行、回流与控制语义

连接和工具状态通过 `vcp-distributed-status` 事件与首次读取送入一个共享 composable；它用 listener 引用计数、代次和 `session_id` 忽略过期状态。分布式页显示连接、server/client ID、已注册数量、错误及每项工具的启用状态，也可对单项工具直接调用本机执行命令作查看（`src/features/distributed/composables/useDistributed.ts:34-167`；`src/features/distributed/DistributedView.vue:78-147`）。

工具执行本身没有当前前端逐次批准的交互链。`ToolInteractionOverlay` 仅监听未来交互式工具的事件，模板明确标为 skeleton；对当前入站请求，客户端直接调用启用工具。客户端现已解析并处理 `cancel_tool`，按 request ID 取消对应的在途执行，因此“远程取消”是已确认的协议能力；但服务端是否发送、何时发送及 UI 的断开按钮是否等价触发它仍未验证（`src/components/FeatureOverlays.vue:1-245`；`src/features/distributed/ToolInteractionOverlay.vue:1-64`；`src-tauri/src/distributed/types.rs:198-260`；`src-tauri/src/distributed/client.rs:1298-1340`）。

## 权限、凭据与治理边界

治理的第一层是功能默认关闭和本地启用白名单：用户可在分布式页更改启用集合；注册表会先将完整白名单写入应用配置目录，成功后才切换内存策略并重新注册。配置损坏或无法读取时，代码退回空白名单（等价全部禁用）并暴露恢复状态；任何未列入白名单的名称在执行入口会被拒绝（`src-tauri/src/distributed/mod.rs:43-134`；`src-tauri/src/distributed/tool_registry.rs:289-380,468-520`）。

第二层是 Android 权限。工具 trait 声明所需权限，分布式页可请求相应原生许可；是否真的获得位置、传感器或剪贴板权限，以及某工具在拒绝后如何降级，需要在设备上验证（`src-tauri/src/distributed/tool_registry.rs:60-190`；`src/features/distributed/DistributedView.vue:78-147`）。VCP Key 的来源是全局设置；本次未扩展审计该设置文件的加密、服务端鉴权强度或 TLS 部署，因此不作凭据安全结论。

## 平台差异与入站数据

节点协议在 Android 与 iOS 两侧共用同一套 Rust 客户端与工具注册表，平台差异集中在插件实现（Kotlin 与 Swift）。iOS 侧另有系统分享扩展与分享收件箱（`share_inbox.rs`、`src-tauri/gen/apple/VCPShare`），把系统分享的文本与文件暂存后再交给聊天输入；这条路径是入站外部数据，不改变节点的出站执行契约。

## 相邻类目交接

- 本笔记记录外部服务对手机节点的身份、协议、执行和治理闭环；设备工具的参数、平台 API 和 Agent 工具可见性应由 Agent 工具类目继续调查。
- 与 VCPChat 的聊天、同步和模型请求是另一类外部依赖，尚未确认它们满足本类目的双向执行状态映射，不在此合并。
- 分布式节点如何成为产品辨识度，见同项目的独特功能与产品结构笔记；其协议细节以本笔记为准。

## 已确认边界与未验证事项

- 未连接真实服务，未确认服务端实现、请求鉴权、工具结果消费、断线恢复和 Android 权限行为。
- 检查分布式客户端、设置页面及 CLI 适配后，未找到外部 Agent runtime、OAuth 安装、外部业务资源模型或逐次审批。CLI 有远端身份到本地 session/operation/job 的映射；它不拥有远端 Agent 的任务循环。`cancel_tool` 已解析且 CLI 可按稳定操作键找到 job 发出取消，但远端发送时机与真实进程效果未运行验证。
- `ToolInteractionOverlay` 是尚未接线的未来交互入口；相机、生物识别和人工接管当前都停在该入口，尚无可用实现。

## 关键源码索引

- `src-tauri/src/distributed/client.rs:586-1340`：连接循环、ACK、注册、执行、取消与回传。
- `src-tauri/src/distributed/types.rs:18-260`：当前双向消息契约。
- `src-tauri/src/distributed/tool_registry.rs:261-500`、`src-tauri/src/distributed/tools/mod.rs:29-63`：本地工具治理与注册边界。
- `src-tauri/src/vcp_modules/infra/settings_manager.rs:37-60、settings_manager/repository.rs:1-2438`：设置变更触发运行时调和。
- `src/components/layout/RightSidebar.vue:38-40`、`src/features/distributed/DistributedView.vue:78-147`：用户配置和可观察状态表面。
