# AIO Hub 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：静态复核 `src/tools/vcp-connector/` 的分布式节点协议与工具桥接；复用 Agent 工具和独特功能笔记；未连接真实 VCPToolBox 服务端
>
> 调查范围：AIO Hub 作为被远端 Agent 驱动的节点执行面与远端插件桥接；排除普通本地 Agent 工具、宿主内建能力与一次性导入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 通过 `src/tools/vcp-connector/` 把自身注册为 VCP 生态的分布式节点：远端服务端可注册工具清单，并下发执行、取消、审批与心跳等控制帧；AIO 同时把远端插件的工具清单桥接为本地工具注册表，供自身 Agent 调用。双向协议、节点身份、持续生命周期、任务映射与治理边界五项准入门槛全部满足，达到 `主链确认`（静态证据）。它是本类目的反向样本：与 VCPToolBox 笔记的"宿主编排节点"视角互补，本笔记记录"节点被远端驱动"一侧。

远端执行的工具结果已能携带本地媒体：工具返回的本地文件引用由节点协议在同一调用内安全读取并转成 data URL 媒体块，随 `tool_result.result.content` 回传，使远端服务端下一轮请求直接看到图片、音频或视频。自动连接改由应用全局启动项管理，节点协议对审批请求标注来源，接入统一审批仲裁。

## 接入角色与系统边界

- **被驱动的执行面**：远端 Agent/服务端（VCPToolBox 或其他 VCP 兼容端）作为控制方，AIO 持有本地工具执行、文件操作、在途调用（requestId → AbortController）与审批发起。
- **工具桥接**：桥接工厂拉取远端插件清单，工具代理把插件包装为本地工具，异步任务以 `vcp_{id}` 前缀映射到本地任务管理器。
- 宿主 AIO 自身 Agent 的普通工具调用属于 Agent 工具类目，不在本页。

## 完整主链

```text
节点连接与注册
  -> 应用启动时由全局启动项调用 onStartup
  -> 等待连接配置与分布式配置加载，再次确认全局开关
  -> 按 observer / distributed / both 模式建立 WebSocket
  -> 以 nodeId / VCP_Key / serverName 身份注册
  -> sendRegisterTools 上报工具清单（register_tools）
  -> report_ip 上报 + 30s 心跳

远端调用入站
  -> handleExecuteTool 归一化 requestId/toolName/toolArgs
  -> AbortController 登记在途调用，参数索引化拆分
  -> 执行本地工具（含文件外部传输，速率/并发限制）
  -> 工具结果中的 localMedia 读取为 data URL 媒体块
  -> tool_result 回传；断线则批量终止在途调用

审批与取消
  -> tool_approval_request 发起（标注 vcp-node / vcp-file-transfer 来源），tool_approval_response 回传
  -> cancel_tool（best-effort）取消在途调用
  -> 115s 超时保护兜底

工具桥接出站
  -> get_vcp_manifests 拉取远端插件清单
  -> VcpToolProxy 包装为本地 ToolRegistry 工具
  -> vcp_tool_status 进度、vcp_tool_result 结果回注
```

## 身份、协议与状态映射

节点身份由 `nodeId`、`VCP_Key` 与 `serverName` 三部分组成。协议帧按 `VcpMessageType` 区分，覆盖工具注册与执行、结果回传、取消、审批和心跳上报等类型，消息结构与分布式配置见 `types/distributed.ts`。状态映射见下表；断线时服务端不再能下发取消帧，因此本地以"断线即清理在途调用"作为一致化策略。

| 外部状态 | 本地对应 |
|---|---|
| `requestId` | 在途调用 |
| `vcp_{id}` | 本地 taskManager 任务 |
| `tool_status` | 任务面板 |
| `localMedia` 引用 | `tool_result.result.content` 中的 data URL 媒体块 |

启动连接不再由连接配置自身决定：`VcpConfig` 已移除 `autoConnect` 字段，自动连接统一存于应用全局启动项的 `startupTasks["vcp-connector"].enabled`，VCP 页面开关与全局启动项双向联动，旧配置字段在加载时剥离（`stores/vcpConnectorStore.ts:105-106`）。应用启动由启动管理器调用注册表的 `onStartup()`，回调等待连接与分布式配置加载完成后再确认全局开关，然后连接并启动分布式节点（`vcp-connector.registry.ts:50`）。

## 分布式媒体结果

远端 `execute_tool` 调用本地工具时，普通对象结果与 `ToolMethodResult` 信封都可携带 `localMedia` 引用。节点协议在 `prepareDistributedToolResult()` 中把引用从结果里摘出，经与 `internal_request_file` 共用的外传入口逐份读取，再把文本结果与 `image_url` 块拼成顶层 `content` 数组回传（`services/vcpNodeProtocol.ts:470-528`）。媒体块使用 `data:<mime>;base64,...` 形式，VCP 侧据 MIME 区分图片、音频和视频。

同一次请求内的批量调用若混有媒体，节点协议按调用顺序把各调用的 `content` 平铺为一个数组，纯文本部分包成 `{ type: "text" }`（`:563-590`）。媒体读取与外传受外部文件开关、限流、审批、大小限制和当前路径规则约束，安全读取与转换计入 115 秒分布式执行预算；取消后停止后续读取，文件类型在读取后发生变化会明确报错。

## 执行、回流与控制语义

远端 `execute_tool` 在 AIO 本地真实执行工具、文件与模型相关工具链，结果和事件异步回传。可回传内容包括工具结果、进度帧与审批请求；取消经 `cancel_tool` 帧 best-effort 传播，并由超时与断线清理兜底。产品面（`VcpConnector.vue` 连接/监控/分布式三个 Tab、`DistributedNodePage`）展示连接状态、节点身份、暴露工具列表与桥接工具列表，接管入口即本地直接操作节点。监控消息支持分类通知策略：总开关默认关闭，全局可选关闭/仅浮动/通知中心/同时四种输出方式，并允许对六类消息分别覆盖，设置随连接配置持久化（`types/protocol.ts` 的 `VcpNotificationMode`、`components/NotificationSettingsPage.vue`）。

## 权限、凭据与治理边界

- 暴露面治理：`distributedExposed` 白名单与 `disabledToolIds` 黑名单共同收口；文件请求工具 `internal_request_file` 强制内置，协议细节见 `src/tools/vcp-connector/docs/internal-file-request.md`。
- 审批：远端工具调用的审批仍走请求/响应帧，但审批请求进入统一仲裁入口时携带来源标记 `vcp-node` / `vcp-file-transfer`。仲裁服务的来源类型把这两个值与其他来源区分，外部来源默认只允许拒绝或升级人工，自动放行需显式配置；缺少智能体绑定的 VCP 请求继续走既有人工审批链，仲裁设计见源码文档 `docs/architecture/tool-approval-arbitration.md`。
- 资源边界：`EXTERNAL_FILE_RATE_LIMIT=20`/`EXTERNAL_FILE_MAX_CONCURRENCY=2`，115s 调用超时。
- 凭据以 VCP_Key/节点密钥与服务端配置保存，刷新与轮换机制本次未展开。
- 外部 `execute_tool` 输入按不可信处理：参数经归一化、索引化拆分和文件传输限制后进入本地工具，可触发文件与业务副作用，安全边界依赖白名单与审批。

## 相邻类目交接

- 本地工具执行、LLM 调用与 taskManager 见[Agent 工具笔记](../Agent工具/AIO-Hub-Agent工具调查笔记.md)。
- 节点/桥接的更多产品面与调查结论见[独特功能笔记](../独特功能/AIO-Hub-独特功能调查笔记.md)。
- 服务端一侧的编排、取消与文件回流见 [VCPToolBox 外部执行体与应用协作调查笔记](VCPToolBox-外部执行体与应用协作调查笔记.md)；两份笔记分别覆盖宿主编排与节点被驱动视角。

## 已确认边界与未验证事项

- 全部结论基于静态代码与架构文档；未连接真实 VCPToolBox 服务端做节点往返。
- 断线竞争（在途取消 vs 结果回传）、审批超时与多节点并发未运行验证。
- 分布式媒体结果未用真实服务端与真实媒体文件验证；媒体读取耗时计入 115 秒预算后的余量、外部来源自动放行的实际配置表现未运行验证。
- 依赖 VCP 生态外部服务端，节点协议有效性不能脱离服务端版本单独承诺。
- `vcp_connector.registry.ts` 之外是否存在其他消费方未逐一核对，以 registry 注册为准。

## 关键源码索引

- `src/tools/vcp-connector/services/vcpNodeProtocol.ts:470-528`：分布式媒体结果转换
- `src/tools/vcp-connector/services/vcpNodeProtocol.ts:563-590`：混合批量结果平铺
- `src/tools/vcp-connector/services/vcpNodeProtocol.ts:659-735`：外部文件读取与外传审批
- `src/tools/vcp-connector/vcp-connector.registry.ts:50`：启动回调
- `src/services/startup-manager.ts:83-128`：全局启动项调度
- `src/tools/vcp-connector/stores/vcpConnectorStore.ts:105-142`：旧配置字段剥离与自动连接开关
- `src/services/decision-arbiter/types.ts:22-30`：审批来源枚举与外部来源判定
- `src/tools/vcp-connector/services/VcpBridgeFactory.ts`、`VcpToolProxy.ts`：工具桥接
- `src/tools/vcp-connector/types/protocol.ts`、`types/distributed.ts`：协议与分布式类型
- `src/tools/vcp-connector/composables/useVcpWebSocket.ts`、`useVcpDistributedNode.ts`
- `src/tools/vcp-connector/VcpConnector.vue`、`ARCHITECTURE.md`
- `src/tools/vcp-connector/__tests__/vcpNodeProtocol.test.ts`、`__tests__/startup.test.ts`
