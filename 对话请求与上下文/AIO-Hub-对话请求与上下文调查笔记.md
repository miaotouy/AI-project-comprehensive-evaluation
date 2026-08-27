# AIO-Hub 对话请求与上下文调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`（分支：`dev`）
>
> 调查方式：直接阅读源码（Vue 组件、composable、store、Rust 后端命令），并补充核对 ST 世界书类型、编辑/导入导出链与请求期处理器
>
> 调查范围：生成任务的提交入口、上下文拼装管道、预算与压缩、流式消费与节流落盘、完成与回写、停止/重试/续写执行链、队列与并发、外部能力注入点；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 提交入口 `useChatHandler.sendMessage` → 上下文管道（11 个处理器按 priority 拼装）→ 执行器请求模型 → 流式回调 → 节流写回。
- 渲染与持久化是**两套独立节流**：流缓冲 → RAF 节流 → UI（显示几乎实时）；chunk 缓冲 → setTimeout（默认 2 秒或增量保存间隔）→ 节点 content → 落盘。崩溃时可能丢失最后几秒流式内容——`content` 字段本身滞后于屏幕显示。
- 上下文压缩是**非破坏性遮罩**：只压当前活动路径、摘要由独立 LLM 请求生成、原消息保留可恢复。两个自动检查点 + 手动入口；连续压缩时旧摘要作为 `previous_summary` 传入续写模板、新摘要创建后旧摘要一并隐藏。
- 目标父节点到根的路径仍在生成时再发消息会**排队**（`skipGeneration` + `metadata.isQueued` 节点）；同一会话的其它分支可继续并行。调度器扫描持久化队列标记，在该路径空闲后按 `queueReplyMode` 合并或链式触发（触发本身还受 `autoTriggerGenerationAfterQueue` 设置控制，默认开启）。
- 工具调用审批用 Promise resolver 挂起执行（`toolCallingStore.requestApproval` 返回 Promise，UI 审批时才 resolve）；编排循环内部语义已由 Agent 工具笔记承接。

## 系统边界与生成任务主链

```text
sendMessage（useChatHandler：Agent 配置、附件等待、压缩检查点 1）
  -> 创建用户消息节点 + 占位助手节点（generatingNodes.add -> updateActiveLeaf -> executeRequest）
  -> 上下文拼装：session-loader 两遍回溯（压缩遮罩）+ contextPipelineStore 11 处理器按 priority 执行
  -> useChatExecutor / useSingleNodeExecutor 执行（模型过滤、前缀续写、工具循环检查点 2）
  -> handleStreamUpdate：正文 delta -> 渲染流缓冲（消息渲染器笔记 2）+ persistBuffer/syncBuffer（节流写回）
  -> finalizeNode 强制 flush 全部缓冲并落盘（含 continuation 前缀补回）
  -> llmChatStore watch generatingNodes.size 减少 -> 触发排队任务（queueReplyMode）
```

边界：节点/会话如何持久化、分支指针与索引在 [`../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md`](../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md)；发送按钮、审批条等界面反馈在 [`<../Chat UI/AIO-Hub-ChatUI调查笔记.md>`](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)；流缓冲到正文渲染的最后交接在 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)（2 节）；工具执行循环内部语义在 [`../Agent工具/AIO-Hub-Agent工具调查笔记.md`](../Agent工具/AIO-Hub-Agent工具调查笔记.md)。

## 1. 提交入口、任务对象与状态机

`useChatHandler.sendMessage()`（`composables/chat/useChatHandler.ts:91-579`）是主提交入口，创建任务对象的顺序：

1. 取 Agent 配置；附件未导入完成则等待（9.1）；
2. 压缩检查点 1：创建新用户消息前调用一次（附录 A.1），保证本轮请求可以使用刚生成的摘要；
3. 创建用户消息节点与占位助手节点（`createMessagePair`），`generatingNodes.add(id)` → `updateActiveLeaf` → 最后才真正调用 `executeRequest`——这个顺序保证 UI 能立刻看到"正在生成"的占位气泡，即使还没发出网络请求；
4. 若目标父节点到根的路径仍含生成节点，走排队分支：消息节点被创建、持久化但不触发实际 LLM 请求，节点打 `metadata.isQueued = true` 且 `status: "queued"`；切换到其它空闲分支则可直接执行（`useChatHandler.ts:523-557`，见第 8 节）。

执行器分层：`useChatExecutor`（LLM 请求执行、附件/Token 前置处理，`useChatExecutor.ts:86-169` 的 `executeRequest`）与 `useSingleNodeExecutor`（单次请求 + 重试策略，`useSingleNodeExecutor.ts:82-374`，含前缀续写 `prefix: true` 的调用，`:241`）。Provider/协议 Adapter 层本次调查范围未覆盖（见第 4 节）。

## 2. 历史选择与上下文拼装顺序

发送给模型的内容并非简单的"活动路径消息数组"：

- **历史选择**：`getBranchHistory`（`core/context-processors/session-loader.ts:105-153`）两遍回溯构建请求上下文——第一遍从叶子向上收集所有"已启用压缩节点"遮罩的 ID（`:115-129`），第二遍跳过这些原消息而保留摘要节点（`:131-151`，压缩的"非破坏性遮罩"语义，见附录 A.2）。tool 角色按配置转成 user（`convertToolRoleToUser`）；仅保留"无 toolCallsRequested 的最终回答"的 reasoningContent（`:255-268`）；可选把旧消息 HTML 转 Markdown 以省 token（`:229-253`）。
- **上下文管道**：`contextPipelineStore.ts:49-219` 注册并按 `priority` 排序执行 11 个处理器（`sortedAndEnabledProcessors`，`contextPipelineStore.ts:114-118`）。当前默认顺序：
  1. 会话加载（100）；
  2. 异步任务结果（110）；
  3. 正则（200）；
  4. 转写/文本提取（250）；
  5. 世界书（300）；
  6. 预设注入组装（400）；
  7. Recall 检索（450，原 `knowledge-processor` 已被 `recall-processor` 替换，见 9.6）；
  8. 会话变量（500）；
  9. Token 限制（600）；
  10. 消息格式化（800）；
  11. 附件解析（10000）。
  启用状态和用户调整后的顺序持久化到 `llm-chat/pipeline-settings.json`（配置 UI `PipelineConfig.vue` 见 Chat UI 4.4）。压缩发生在这个管道之前（由会话加载器把原消息替换为摘要）；图片实际缩放/Base64 化在管道末端才发生（9.3）。

## 3. 预算、截断、摘要与压缩（模型、入口与不变量）

主文保留配置模型、触发入口与关键不变量，触发/执行细节见附录 A：

- **配置模型**：压缩是 **Agent 级配置**（`LlmParameters.contextCompression`），生效优先级"调用参数 > 当前选中 Agent 的配置 > 默认值"（`useContextCompressor.getEffectiveConfig()`，`useContextCompressor.ts:422-447`）；当前实现已移除 Session 级压缩配置（附录 A.1）。
- **触发入口**：两个自动检查点——`sendMessage()` 创建新用户消息前（`useChatHandler.ts:120-125`）、`useSingleNodeExecutor.execute()` 助手节点完成后（`useSingleNodeExecutor.ts:360-367`，工具循环中的单节点执行也经过后者）；外加输入框"更多"菜单的 `manualCompress()` 手动入口（`useContextCompressor.ts:495-505`）。两处自动检查点都捕获压缩错误，摘要请求失败不会阻断正常聊天。
- **关键不变量**：只处理当前 `activeLeafId` 所在路径；不跨分支压缩隐藏分支；**不删除旧消息**（非破坏性遮罩，可逆：禁用压缩节点让原消息重新进入上下文，删除走会话管理 4.4 的特殊重挂逻辑）。
- **已确认边界**：连续压缩的"增量摘要滚动合并"已接入执行路径（`executeCompression()` 会把本次压缩范围之前最近的已启用摘要节点作为 `previous_summary` 传入续写模板，新摘要创建后旧摘要一并隐藏，`useContextCompressor.ts:570-596`；仓库文档 `docs/architecture/context-compression.md` 已同步，文档与实现一致）。仍存在的边界：后台会话自动压缩可能读取前台会话/Agent 的配置与 Token 统计（状态依赖错位）。两者详情见附录 A.3/A.4。

## 4. SDK、Provider、模型与协议交接

- 模型能力过滤：`filterParametersForModel` 按目标模型支持的参数过滤——这是"切换模型重试"的实现基础（第 7 节）。
- 前缀续写：`useSingleNodeExecutor.ts:241` 对续写节点用 `prefix: true` 调用支持前缀续写的 API（节点语义在会话管理 4.3）。
- 翻译：独立请求的模型选择优先级见 9.7。
- Provider/协议 Adapter 层（SDK 消息转换、渠道与 Profile 解析、`useLlmRequest` 内部的请求构造）本次调查范围未覆盖，未核实。

## 5. 流式事件、缓冲、节流与顺序

流式正文和持久化更新分离的具体机制在 `composables/chat/useStreamingMessageSources.ts` + `useChatResponseHandler.ts`（渲染侧的显示交接见消息渲染器笔记 2 节，这里记录执行与落盘侧）：

- **渲染通道**：`useStreamingMessageSources.ts` 维护模块级 `Map<nodeId, ReplayableMessageStreamSource>`（`:91`），**完全独立于节点的持久化 content**（`session.nodes[id].content`）；`getOrCreateStreamingMessageSource(nodeId, initialContent)`（`useStreamingMessageSources.ts:102-114`）是渲染层唯一入口，`MessageContent.vue` 只在生成中为真时创建/获取（细节见渲染器笔记 2.1）。
- **持久化通道**：`useChatResponseHandler.handleStreamUpdate()`（`useChatResponseHandler.ts:177-274`）对正文（非 reasoning）分支把 chunk 同时塞进 `contentUpdateBuffer` 里的 `persistBuffer`（用于落地节点内容）与 `syncBuffer`（用于跨窗口同步）。节流分两路：
  - **跨窗口同步**：`scheduleStreamSync()`（`:121-147`）用 `requestAnimationFrame` 节流，把 `syncBuffer` 经 `useWindowSyncBus().syncState("chat:streaming-delta", ...)` 广播给分离窗口（主窗口/悬浮输入框窗口共享生成状态的机制）；
  - **内容落盘**：`scheduleContentFlush()`（`:109-119`）用 `setTimeout`，延迟由 `getContentPersistDelay()`（`:78-84`）决定——若开启增量保存（`enableIncrementalSave`），延迟取 `max(250, incrementalSaveInterval)` 毫秒，否则固定 2000ms；到时 `flushContentToNode()`（`:86-107`）才把 `persistBuffer` 写入节点 `content` 并触发按配置节流的增量落盘（`triggerIncrementalSave()`，`:149-172`）。

也就是说：**渲染路径**（流缓冲区 → RAF 节流 → UI）和**持久化路径**（chunk 缓冲 → setTimeout 节流 → 节点 content → 落盘）是两套完全独立的节流策略，渲染更新几乎实时（RAF 级别），持久化写盘则明显更慢（默认 2 秒或用户配置的增量保存间隔）。这解释了为什么应用崩溃时可能丢失最后几秒的流式内容——`content` 字段本身滞后于屏幕显示。`finalizeNode()`（`useChatResponseHandler.ts:364-642`）在生成结束时会强制 flush 所有缓冲区（`flushAllBuffers`，`useChatResponseHandler.ts:371-394`），确保最终落盘内容完整，但过程中的中间态确实可能因为节流而未落盘。

- **reasoning 不对称**：reasoning（思考内容）走另一套 RAF 节流缓冲（`reasoningUpdateBuffer`，声明在 `useChatResponseHandler.ts:42-45`，处理分支在 196-241），没有单独的"流源"抽象，而是每帧把 buffer flush 进 `node.metadata.reasoningContent`。因此 reasoning 写入节点的频率高于正文（每帧对比默认每 2 秒），两条持久化路径并不对称。

## 6. 完成、异常、半截流与最终回写

- `finalizeNode()`（`useChatResponseHandler.ts:364-642`）在生成结束时**强制 flush 所有缓冲区**（`flushAllBuffers`，`useChatResponseHandler.ts:371-394`），确保最终落盘内容完整；过程中的中间态可能因节流未落盘（第 5 节）。
- `finalizeNode()`（`useChatResponseHandler.ts:490-501`）对 `metadata.isContinuation` 且返回内容未包含原 `continuationPrefix` 的节点手动补回前缀，防止模型漏复述前缀导致内容断裂（节点语义在会话管理 4.3）。
- 响应中的 Base64 内联图片会被转换为附件追加到节点（`finalizeNode` 内 `processInlineData`，`useChatResponseHandler.ts:399-488`）；usage 为 0 但有内容时用本地 token 计算修复（`validateAndFixUsage`，`useChatResponseHandler.ts:280-359`）。
- 生成结束后，`llmChatStore.ts` 里对 `generatingNodes.value.size` 减少的 watch（`llmChatStore.ts:129-207`）触发排队任务处理（第 8 节）；同一 watch 也是"僵死节点修复"的触发点（数据语义在会话管理 9 缺陷 1）。
- 半截流的错误诊断（错误与空响应诊断存 metadata）见消息渲染器笔记 1.1；执行侧的异常分支 `handleNodeError`（`useChatResponseHandler.ts:647-694`）区分超时/abort/普通错误并写 `metadata.error`，清理缓冲后收口。工具编排层异常由 `orchestrate` 的 catch 统一转交 `handleNodeError`（`useToolCallOrchestrator.ts:445-451`）。

## 7. 停止、重试、续写与重新生成

- **重新生成（regenerateFromNode）**：`useChatHandler.regenerateFromNode()`（`useChatHandler.ts:585-736`）负责取 Agent 配置，若 `options.modelId/profileId` 存在则覆盖模型并用 `filterParametersForModel` 过滤出目标模型支持的参数——这就是"切换模型重试"的执行链（UI 层"切换模型重新生成"按钮在 Chat UI 6.1）。节点语义（给同一用户消息新增兄弟助手节点）在会话管理 4.3。
- **续写（continueGeneration）**：`useChatHandler.continueGeneration()`（`useChatHandler.ts:741-862`）：对 assistant 节点新建内容等于原内容、`isContinuation` 的兄弟节点，发送时用 `prefix: true`（`useSingleNodeExecutor.ts:241`）让支持前缀续写的 API 从 `continuationPrefix` 后继续；对 user 节点是"角色接力"（空子节点）。最终内容的前缀补回在 `finalizeNode`（第 6 节）。
- **停止/abort**：`abortControllers: Map<string, AbortController>` 在 `sessionRuntimeManager`（数据语义在会话管理 6）。停止走 `llmChatStore.abortSending`/`abortNodeGeneration`（`llmChatStore.ts:587-604`）：先拒绝挂起的审批（`toolCallingStore.cancelBySession`），再 `sessionRuntime.abortSessionGeneration`/`abortNodeGeneration`（`sessionRuntimeManager.ts:77-122`）——`controller.abort()` 后把节点标记为"用户手动停止"（有内容 → complete，无内容 → error + `metadata.error: "用户手动停止"`），并清掉 generatingNodes/流源。网络级中断层（controller 具体接到哪个请求对象、服务端任务是否取消）本次未核实。

## 8. 队列、多会话并发与后台生成

`sessionGenerationManager.ts` 的排队机制分三部分：

- **排队写入**：`sendMessage()` 检测目标父节点到根的路径仍在生成时，把该 sessionId 加入 `queuedSessionIds`，并调用 `chatHandler.sendMessage(..., {skipGeneration: true})`（`sessionGenerationManager.ts:279-344`）——消息节点会被创建、持久化，但不触发实际 LLM 请求；节点打 `metadata.isQueued = true`，`status` 同步写为 `"queued"`（`useChatHandler.ts:523-557`：combined 模式标在 user 节点上，chained 模式标在占位 assistant 节点上；旧数据里的 `pending` 状态在展示层仍按 queued 兼容）。
- **触发条件**：当前生成结束（`llmChatStore.ts` 对 `generatingNodes.value.size` 减少的 watch，`llmChatStore.ts:129-207`）且 `settings.uiPreferences.autoTriggerGenerationAfterQueue` 为真（`llmChatStore.ts:192`）。
- **触发执行**：`triggerQueuedGenerationForSession()`（`sessionGenerationManager.ts:132-267`）扫描节点上的持久化 `isQueued`/`queued`/兼容 `pending` 标记，只启动没有排队祖先且目标路径已经空闲的节点；因此同一条排队链保持顺序，其他分支仍可并行。user 节点走 `regenerateFromNode`（合并回复），assistant 占位节点走 `continueGeneration`（链式追加），具体由 `queueReplyMode`（`"combined"`/`"chained"`，默认 combined）决定。

多会话并行：`generatingNodes` 是节点粒度集合，会话间互不阻塞（数据语义在会话管理 6）。排队与等待的可见 UI 提示有明确实现：`utils/messageStatus.ts` 把 queued/waiting 映射为"排队/等待"徽标，`MessageHeader` 按 `showMessageStatus`（默认开启）展示（Chat UI 5.2）。

## 9. Agent、工具、知识库与附件注入点

### 9.1 附件发送前等待

`useChatExecutor.processUserAttachments()`（`composables/chat/useChatExecutor.ts:199-212`）：等待所有附件的 `importStatus` 变成非 pending/importing（`waitForAssetsImport`，30 秒超时，`useChatExecutor.ts:171-197`），超时抛错阻断发送。附件两阶段导入的状态机在会话管理 8.3。

### 9.2 转写注入

`useTranscriptionManager.ts` 负责发送前转换：支持图片、音频、视频、PDF 和 DOCX，转写模型按"类型专用模型 → 转写兜底模型 → Chat 全局默认模型 → 当前会话/Agent 模型"四级选择（`getTranscribeModelIdentifier`，`useTranscriptionManager.ts:72-99`）。两种策略：

- **smart（默认）**：模型原生不支持该模态时才使用转写；较老的附件超过 `forceTranscriptionAfter`（默认 10 条，`config/defaultSettings.ts:117`）后可强制转写；已有转写且 `smartPrioritizeTranscription` 为真（默认 true）时优先发文本（`useTranscriptionManager.ts:465-507`）。
- **always**：始终使用转写（`useTranscriptionManager.ts:424`）。

发送和上下文预览都会在执行管道前调用 `ensureTranscriptions()` 等待必要任务（`useChatHandler.ts:442-499` 与 `useSingleNodeExecutor.ts:174-227`），管道中的 `transcription-processor`（priority 250）再把 `【file::assetId】` 占位符或附件替换为转写文本/文本提取结果。附件卡片的单项重试/取消与批量转写动作是界面工作流（Chat UI 3.4）。

### 9.3 图片压缩

与上下文摘要无关，是 Agent 参数 `imageCompression` 控制的发送前二进制处理。管道最后的 `asset-resolver.ts`（priority 10000）先按模型 `maxImageDimension` 做安全缩放（`asset-resolver.ts:46-57`），再按用户配置执行最大边限制、保持原格式或转为 JPEG/WebP，并可设置 0.1-1.0 的有损质量（默认 0.85，`asset-resolver.ts:70-81`）；失败时保留当前图片继续发送。处理发生在请求用的图片 buffer 上，没有改写资产管理器中保存的原文件。

### 9.4 会话变量注入

Agent 开启 `variableConfig` 后，`variable-processor.ts`（priority 500）解析消息中的 `<svar name="player.hp" op="-" value="10" />` 标签，支持赋值和 `+ - * /` 运算，并按变量定义的 min/max 截断；`$[player.hp]` 读取单值，`$[svars::json|table|list]` 输出全部非隐藏变量。处理器从活动分支最近的 `metadata.sessionVariableSnapshot` 起点继续回放，所以切分支后能按该分支历史重建状态；含变更的消息会写快照，压缩节点即使没有新变更也强制写一份锚点快照（快照字段数据语义在会话管理 1.3）。消息菜单的"变量快照"和上下文分析器的"变量状态"页是这套数据的可视化入口（Chat UI 6.3）。

### 9.5 工具调用审批暂停与编排循环

分两层：

- **状态层**：`stores/toolCallingStore.ts` 维护 `pendingRequests: PendingToolRequest[]`，每条请求带一个 `resolve: (result) => void`（Promise resolver）。`requestApproval(sessionId, request, externalId?, options?)`（`toolCallingStore.ts:148-187`）返回一个 Promise，UI 调用 `approveRequest`/`rejectRequest`/`approveByIds`/`rejectByIds` 时才 resolve 对应 Promise（`toolCallingStore.ts:189-225`）——工具执行流程因此可以用 `await` 直接"卡住"等待用户点击审批，而不需要额外的状态机轮询。相关行为：
  - **可配置超时**：默认 `toolApprovalTimeoutEnabled: false`（无限等待）；开启后按 `toolApprovalTimeoutSeconds`（5 秒–24 小时，默认 60 秒，`toolCallingStore.ts:25-27`）定时自动拒绝（`scheduleTimeout`，`toolCallingStore.ts:122-133`），调用方也可显式传 `timeoutMs` 或 `AbortSignal`；
  - **批量拒绝**：会话删除/清理按 sessionId 批量拒绝（`cancelBySession`，`toolCallingStore.ts:227-233`），窗口关闭（beforeunload/pagehide）时全部拒绝（`toolCallingStore.ts:251-255,273-277`）；
  - **VCP 兼容**：`externalId` 用于兼容 VCP（通过 WebSocket 连接的外部协议）广播过来的审批请求——这类请求的 `sessionId` 是 `vcp-${maid}` 格式，跟本地 `llm-chat` 会话 ID 体系不是一套，审批条 UI 因此不按 sessionId 精确匹配（见 Chat UI 5.3）。
- **编排层**：`composables/chat/useToolCallOrchestrator.ts` 的 `orchestrate()`（`useToolCallOrchestrator.ts:70-463`）驱动"LLM 生成 → 检测工具请求 → 等待审批 → 执行 → 把结果拼回上下文 → 再请求"循环。每一轮先用 `parseToolRequests()` 检测响应文本中的工具调用（VCP 或其他协议），检测到后创建一个 `role: "tool"` 的节点，`metadata.toolCalls` 初始状态为 `"awaiting_approval"`（`:222-254`）；随后 `processCycle()` 调用 `requestApproval()` 等待审批（`:276-327`）。`processCycle()` 来自 `@/tools/tool-calling`——其内部解析/校验/执行/结果格式化的细节已由 [`../Agent工具/AIO-Hub-Agent工具调查笔记.md`](../Agent工具/AIO-Hub-Agent工具调查笔记.md)（同代码快照）承接。循环上限由 `toolCallConfig.maxIterations` 控制（默认 5，`:107`）；`rateLimitInterval` 支持从上次请求开始或从上次流结束开始计时（`:130-157`）。所有请求被拒绝或节点标记为 `isSilent` 时循环终止（`:388-396`），否则创建下一个 assistant 节点继续对话；结束后自动命名 `generateSessionTopic`（`:444`）。

### 9.6 外部能力注入概览（已确认入口，未逐分支展开）

| 功能 | 当前快照中确认的实现（注入点） |
| --- | --- |
| 世界书 | `worldbook-processor`（priority 300）合并全局、用户档案和 Agent 绑定的世界书，执行主/次关键词与正则匹配、selective/constant/概率、扫描深度、角色/名称/标签过滤、递归与延迟递归、sticky/cooldown/delay、包含组和加权选择，再按严格 depth 或降级 anchor 位置注入。这是 `st-worldbook-manager` 编辑/导入数据的真实运行主链，不是只保存兼容字段。部分 ST 扩展字段仍只有表示/编辑能力，未找到运行时消费。 |
| Recall 思绪检索 | `recall-processor`（priority 450）解析 `【recall::...】` 严格占位符协议（`recall-placeholder.ts` 校验编码/参数/数值范围），执行检索并替换；Agent 配置 `autoInjectIfMacroMissing` 时按未引用绑定自动注入占位符到 `context_head` 或 `before_last_user`（`recall-processor.ts:151,180`）。原 `knowledge-processor` 已删除，旧 `【kb::...】`/`【knowledge::...】` 占位符只记录"已废弃"警告、不再执行检索。 |
| Skill 集成 | `skill-manager` 的 `SkillManagerProxy` 以 `skill:system` 注册到工具调用系统，提供动态激活及 `skill_read_file`/`skill_list_dir`/`skill_run_script`；复用 9.5 的审批/工具循环，不是独立消息协议。 |
| SillyTavern 兼容 | `sillyTavernParser.ts` 和 Agent 导入服务可解析 V2/V3 角色卡 JSON/PNG、提示词 `prompt_order` 和部分正则/宏；快捷操作导入还兼容 SillyTavern Quick Reply。独立 `st-worldbook-manager` 提供世界书编辑、持久化、JSON/`.lorebook` 与角色卡 PNG/AIO Bundle 导入、导出和 Agent/User Profile 绑定，受支持字段由上行 `worldbook-processor` 实际执行。兼容是可运行子集，不是完整复刻酒馆扩展/事件协议。 |

### 9.7 独立生成请求：消息翻译

`composables/chat/useTranslation.ts` 是纯粹的"调用 LLM 翻译一段文本"的工具函数（`translateText`，`useTranslation.ts:37-127`），不感知消息树结构。模型选择优先级：配置的翻译专用模型 → 全局默认模型 → 报错要求用户手动选择。翻译使用的 Prompt 支持 `{targetLang}`/`{text}`/`{thinkTags}` 占位符替换，`{thinkTags}` 会展开成当前生效的思考标签列表（例如 `<think>...</think>`），确保翻译时提示模型保留 XML 标签结构不翻译标签本身（`useTranslation.ts:76-97`）。翻译结果存消息 `metadata.translation`（字段语义在会话管理 1.3），界面入口与快捷交互在 Chat UI 6.1。

### 9.8 上下文分析器：复用真实管道预览

消息菜单的"上下文分析"不是静态读取已有统计，而是以所选节点为路径终点重新调用 `getLlmContextForPreview()`（`useChatHandler.ts:924-993` → `useChatExecutor.getContextForPreview`，`useChatExecutor.ts:284-508`），尽量复用真实请求的 Agent、用户档案、世界书、附件和整条管道；最终 Token 统计会对管道产出的每条消息重新计算（`useChatExecutor.ts:465-483`）。副作用：预览构建在发现附件时会调用 `ensureTranscriptions()`（`useChatExecutor.ts:412-458`），因此打开上下文分析器可能发起或等待缺失的转写任务，它并非严格只读的调试窗口（五视图界面见 Chat UI 6.3）。

### 9.9 显式 Knowledge 资料引用

Composer 的 Knowledge 引用（`knowledgeReference`，UI 在 Chat UI 3.1）随消息进入 `sendMessage`：先创建 `role: "tool"` 的"显式 Knowledge 工具事件"节点（`services/explicitKnowledgeReference.ts:31` 的 `createExplicitKnowledgeToolEvent`），按引用模式执行资料检索（`executeKnowledgeReferenceSearch`）或研究（`executeKnowledgeReferenceResearch`，带轮次进度、可中止），完成后把结果写入 tool 节点、随后进入正常生成链；失败则把错误写回 tool 节点并阻断本轮生成（`useChatHandler.ts:227-365`）。

## 10. 退出恢复、日志与已确认边界

- 切换会话、关闭窗口、应用退出时的任务收尾（未完成请求如何 abort/落盘）本次未调查；崩溃后残留 generating 节点的数据语义在会话管理 9 缺陷 1。窗口关闭时挂起的工具审批会被 `beforeunload` 拒绝（9.5）。
- 日志/trace/用量与具体任务的关联：本次未调查（`inspectorContext` 携带 `sessionId`/`purpose` 进入请求层，但本次未核实其消费方）。
- 分离窗口断连时流缓冲仍在主进程内存中，重连后的回放取决于订阅时机（Chat UI 8.2；渲染侧重放机制在渲染器笔记 2.1）。
- 已确认边界汇总：后台压缩状态依赖错位（附录 A.4）；`@/tools/tool-calling` 内部实现与 VCP 协议细节本次未展开（已由 Agent 工具笔记承接）；Provider 协议 Adapter 层未覆盖（第 4 节）。压缩文档与实现的"增量摘要"不一致已确认修复（附录 A.3）。

## 11. 未验证事项

- 网络级停止效果（AbortController 实际中断层）、停止后半截消息的最终落盘形状需运行验证。
- 队列触发（`triggerQueuedGenerationForSession`）在并发/切换会话场景下的竞态未做运行时复现。
- 压缩在多会话并行生成时的误压缩风险未复现（附录 A.4）。
- 转写、图片压缩、压缩摘要等未实际调用模型验证；导入导出往返与原子写的真实崩溃行为未验证。

## 12. 关键源码索引

- `src/tools/llm-chat/composables/chat/useChatHandler.ts`（sendMessage/regenerate/continueGeneration，91-862行）
- `src/tools/llm-chat/composables/chat/useChatExecutor.ts`（86-508行）、`useSingleNodeExecutor.ts`（82-374行）
- `src/tools/llm-chat/composables/chat/useChatResponseHandler.ts`（流式节流/finalize/错误处理，40-702行）
- `src/tools/llm-chat/composables/chat/useStreamingMessageSources.ts`（20-153行，渲染交接）
- `src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts`（60-476行）
- `src/tools/llm-chat/composables/chat/useTranslation.ts`
- `src/tools/llm-chat/stores/session/sessionGenerationManager.ts`（发送/重试/续写/排队，113-344行）
- `src/tools/llm-chat/stores/toolCallingStore.ts`（工具审批状态）
- `src/tools/llm-chat/composables/features/useContextCompressor.ts`（45-642行）
- `src/tools/llm-chat/composables/features/useTranscriptionManager.ts`、`useAttachmentManager.ts`
- `src/tools/llm-chat/core/context-processors/session-loader.ts`（105-153行）、`transcription-processor.ts`、`asset-resolver.ts`、`variable-processor.ts`、`recall-processor.ts`（替换原 knowledge-processor）
- `src/tools/llm-chat/stores/contextPipelineStore.ts`、`core/pipeline/defaultProcessors.ts`
- `src/tools/llm-chat/stores/llmChatStore.ts`（129-207行 watch）
- `src/tools/llm-chat/components/context-analyzer/*`（预览与视图）

## 附录 A：上下文压缩机制细节（专题附录）

### A.1 配置、触发条件与调用时机

上下文压缩是 **Agent 级配置**，字段位于 `LlmParameters.contextCompression`，默认配置在 `types/llm.ts:378-392`：

- 总开关默认关闭，自动触发默认开启，触发模式默认 `token`；
- Token 阈值 80000、消息阈值 50、最小历史数 15、最近消息保护数 10、单次最多压缩 20 条；
- 摘要节点默认使用 `system` 角色。

配置面板位于 Agent 参数编辑器的 `ContextCompressionConfigPanel.vue`（界面见 Chat UI 4.3）；当前实现已经移除了 Session 级压缩配置，生效优先级是"调用参数 > 当前选中 Agent 的配置 > 默认值"（`useContextCompressor.getEffectiveConfig()`，`useContextCompressor.ts:422-447`）。

自动判断先检查 `enabled` 和 `autoTrigger`，再检查 `minHistoryCount`（`checkAndCompress`，`useContextCompressor.ts:466-490`）。`triggerMode` 支持 `token`、`count`、`both`；`both` 是 Token 或消息数任一超限即触发（OR），比较符是严格的 `>`，等于阈值时不会触发（`shouldCompress`，`useContextCompressor.ts:64-90`）。Token 优先使用 `llmChatStore.contextStats.totalTokenCount`，统计未就绪才回退为路径节点 `metadata.tokenCount` 之和（`calculateContextStats`，`useContextCompressor.ts:95-138`）。代码里有两个自动检查点：`useChatHandler.sendMessage()` 在创建新用户消息前调用一次，保证本轮请求可以使用刚生成的摘要；`useSingleNodeExecutor.execute()` 在助手节点完成后又调用一次，工具循环中的单节点执行也会经过后一个检查点。两处都捕获压缩错误，因此摘要请求失败不会阻断正常聊天。

输入框"更多"菜单的"压缩上下文"调用 `messageInputStore.handleCompressContext()` → `manualCompress()`（`useContextCompressor.ts:495-505`）。菜单会在当前 Agent 没有启用压缩时禁用；手动调用跳过自动开关与阈值判断，但仍受"最近 N 条保护区"约束，候选消息数不多于 `protectRecentCount` 时返回"没有可压缩的消息"。需要区分 UI 约束和函数契约：`manualCompress()` 本身没有再次检查 `enabled`，只是正常 UI 不会在未启用时让用户点到它。

### A.2 压缩范围、树结构与可逆性

压缩只处理当前 `activeLeafId` 所在路径。执行时先收集所有**已启用**压缩节点的 `compressedNodeIds`，剔除已经被遮罩的消息，再从候选集中排除 `system` 角色和压缩节点（`executeCompression`，`useContextCompressor.ts:519-536`）；保留末尾 `protectRecentCount` 条，从最早的可压缩消息起最多取 `compressCount` 条（`useContextCompressor.ts:538-568`）。因此它不会删除旧消息，也不会跨分支压缩隐藏分支。

摘要由一次独立 LLM 请求生成。模型选择顺序是：显式 `summaryModel` → 当前选中 Agent 的模型 → 聊天全局默认模型 → 第一个已启用 Profile 的第一个模型（`generateSummary`，`useContextCompressor.ts:201-249`）；请求使用单条 `user` 消息，并应用独立的 `summaryTemperature` 和 `summaryMaxTokens`（`useContextCompressor.ts:251-267`）。摘要成功后，`compressNodes()`（`useContextCompressor.ts:283-415`）创建带 `metadata.isCompressionNode=true` 的普通树节点，将其插在该批最后一条被压缩消息之后，并把该消息原有的子节点整体转挂到摘要节点下（删除/重挂语义在会话管理 4.4）。元数据记录被遮罩 ID、原消息/Token 数、触发配置和时间；如果被遮罩消息含 provider `reasoningArtifacts`，压缩节点会标成 `reasoningStateStatus: "broken"` 并写入警告，因为后续请求不会再回放这些隐藏消息的 reasoning 状态（`useContextCompressor.ts:309-339`，字段语义在会话管理 1.3）。

请求上下文由 `session-loader.ts:105-153` 两遍回溯构建（第 2 节）。因此"压缩"准确说是**非破坏性上下文遮罩**。`CompressionMessage.vue` 允许用户直接编辑摘要、切换摘要角色、启用/禁用和删除；禁用压缩节点会让原消息重新进入上下文，删除则走会话管理 4.4 的特殊重挂逻辑。原消息一直存在于会话 JSON 和树图里，线性消息列表只是用半透明样式标记其已被压缩状态（渲染在渲染器笔记 1.2）。

压缩成功后会立即 `persistSessions()` 并刷新上下文 Token 统计（`useContextCompressor.ts:613-617`）。返回值里的 `savedTokenCount` 只是被遮罩节点记录的 Token 总和，**没有减去新摘要自身的 Token**（`useContextCompressor.ts:598-602,619-623`），所以它是"原内容 Token 数"，不是严格意义上的净节省量。

### A.3 压缩实现与仓库说明的差异

- `executeCompression()` 先定位本次压缩范围之前最近一个"已启用且未被遮罩"的摘要节点（`useContextCompressor.ts:572-583`）；
- 把它作为 `previousSummary` 传给 `generateSummary()`（`useContextCompressor.ts:591-596`），`generateSummary()` 在有前情提要时改用续写模板（`CONTINUE_CONTEXT_COMPRESSION_PROMPT` 或用户配置的 `continueSummaryPrompt`，`useContextCompressor.ts:183-199`）；
- 新摘要创建时把旧摘要一并纳入 `compressionNodes`（`useContextCompressor.ts:584-586`），即旧摘要随新压缩一起被隐藏，避免上下文中累积多个摘要；
- 新摘要的 `originalTokenCount`/`originalMessageCount` 会继承旧摘要承载的历史统计（`compressNodes`，`useContextCompressor.ts:294-308`）；
- 仓库文档 `context-compression.md` 同步改写了对应段落。

注：旧摘要的定位只找"本次压缩范围之前最近"的一个，且摘要生成/隐藏链路为静态代码确认，未做运行验证。

### A.4 后台压缩的状态依赖错位

另一个边界来自全局 UI 状态：有效压缩配置、摘要模型和摘要节点精确 Token 计算都读取 `currentAgentId`（`getEffectiveConfig`，`useContextCompressor.ts:430-439`），并没有根据目标会话的历史节点或传入的 `sessionIndex/detail` 解析 Agent；`calculateContextStats()` 又优先读取 `llmChatStore.contextStats`，而该统计在 `llmChatStore.ts:613-614` 明确绑定的是 `currentSession/currentSessionDetail`（`useChatContextStats.ts:46-47` 直接读传入的当前会话 ref）。前台当前会话通常不会出错，但多会话并行生成、生成期间切换 Agent/会话时，后台会话理论上可能套用前台当前 Agent 的配置/摘要模型，甚至用前台会话的 Token 总数判断自己是否达到压缩阈值。状态依赖错位由代码可以确认，实际误压缩结果仍标为**潜在风险，未做多会话运行时复现**。
