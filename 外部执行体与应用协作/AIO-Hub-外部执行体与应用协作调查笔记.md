# AIO Hub 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：静态复核 `src/tools/vcp-connector/` 的分布式节点协议与工具桥接；复用 Agent 工具和独特功能笔记；未连接真实 VCPToolBox 服务端
>
> 调查范围：AIO Hub 作为被远端 Agent 驱动的节点执行面与远端插件桥接；排除普通本地 Agent 工具、宿主内建能力与一次性导入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 通过 `src/tools/vcp-connector/` 把自身注册为 VCP 生态的分布式节点：远端服务端可注册工具清单，并下发执行、取消、审批与心跳等控制帧；AIO 同时把远端插件的工具清单桥接为本地工具注册表，供自身 Agent 调用。双向协议、节点身份、持续生命周期、任务映射与治理边界五项准入门槛全部满足，达到 `主链确认`（静态证据）。它是本类目的反向样本：与 VCPToolBox 笔记的"宿主编排节点"视角互补，本笔记记录"节点被远端驱动"一侧。

## 接入角色与系统边界

- **被驱动的执行面**：远端 Agent/服务端（VCPToolBox 或其他 VCP 兼容端）作为控制方，AIO 持有本地工具执行、文件操作、在途调用（requestId → AbortController）与审批发起。
- **工具桥接**：桥接工厂拉取远端插件清单，工具代理把插件包装为本地工具，异步任务以 `vcp_{id}` 前缀映射到本地任务管理器。
- 宿主 AIO 自身 Agent 的普通工具调用属于 Agent 工具类目，不在本页。

## 完整主链

```text
节点连接与注册
  -> 按 observer / distributed / both 模式建立 WebSocket
  -> 以 nodeId / VCP_Key / serverName 身份注册
  -> sendRegisterTools 上报工具清单（register_tools）
  -> report_ip 上报 + 30s 心跳

远端调用入站
  -> handleExecuteTool 归一化 requestId/toolName/toolArgs
  -> AbortController 登记在途调用，参数索引化拆分
  -> 执行本地工具（含文件外部传输，速率/并发限制）
  -> tool_result 回传；断线则批量终止在途调用

审批与取消
  -> tool_approval_request 发起，tool_approval_response 回传
  -> cancel_tool（best-effort）取消在途调用
  -> 115s 超时保护兜底

工具桥接出站
  -> get_vcp_manifests 拉取远端插件清单
  -> VcpToolProxy 包装为本地 ToolRegistry 工具
  -> vcp_tool_status 进度、vcp_tool_result 结果回注
```

## 身份、协议与状态映射

节点身份由 `nodeId`、`VCP_Key` 与 `serverName` 组成，不是匿名 URL。协议帧按 `VcpMessageType` 区分，覆盖工具注册与执行、结果回传、取消、审批和心跳上报等类型，消息结构与分布式配置见 `types/distributed.ts`。状态映射见下表；断线时服务端不再能下发取消帧，因此本地以"断线即清理在途调用"作为一致化策略。

| 外部状态 | 本地对应 |
|---|---|
| `requestId` | 在途调用 |
| `vcp_{id}` | 本地 taskManager 任务 |
| `tool_status` | 任务面板 |

## 执行、回流与控制语义

远端 `execute_tool` 触发的是 AIO 本地真实执行（工具、文件、模型相关工具链），结果与事件异步回传，而非仅通知。可回传内容包括工具结果、进度帧与审批请求；取消经 `cancel_tool` 帧 best-effort 传播，并由超时与断线清理兜底。产品面（`VcpConnector.vue` 连接/监控/分布式三个 Tab、`DistributedNodePage`）展示连接状态、节点身份、暴露工具列表与桥接工具列表，接管入口即本地直接操作节点。

## 权限、凭据与治理边界

- 暴露面治理：`distributedExposed` 白名单与 `disabledToolIds` 黑名单共同收口；文件请求工具 `internal_request_file` 强制内置，说明见 `docs/internal-file-request.md`。
- 审批：远端工具调用与桥接工具的审批均走请求/响应帧。
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
- 依赖 VCP 生态外部服务端，节点协议有效性不能脱离服务端版本单独承诺。
- `vcp_connector.registry.ts` 之外是否存在其他消费方未逐一核对，以 registry 注册为准。

## 关键源码索引

- `src/tools/vcp-connector/services/vcpNodeProtocol.ts`
- `src/tools/vcp-connector/services/{VcpBridgeFactory,VcpToolProxy}.ts`
- `src/tools/vcp-connector/types/{protocol,distributed}.ts`
- `src/tools/vcp-connector/stores/{vcpConnectorStore,vcpDistributedStore}.ts`
- `src/tools/vcp-connector/composables/{useVcpWebSocket,useVcpDistributedNode}.ts`
- `src/tools/vcp-connector/{VcpConnector.vue,ARCHITECTURE.md}`
- `src/tools/vcp-connector/__tests__/vcpNodeProtocol.test.ts`
