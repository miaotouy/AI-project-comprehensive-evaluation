# Cherry Studio 对话请求与上下文调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：直接阅读源码（渲染层提交链路、主进程 `AiStreamManager` 状态机与 `PersistentChatContextProvider` 上下文拼装、AI SDK Agent 交接、`messageRules` 消息整形与重试包装），并核对行号与符号至当前 HEAD
>
> 调查范围：一次生成任务的提交入口、任务状态机、上下文拼装顺序、预算压缩、Provider 交接、流式事件链、最终化回写、停止重试续写、队列并发与外部能力注入；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **主链**：一次生成由渲染层构建请求、主进程集中编排：`ChatContent` 的 `onSend` 组装请求后，由 `useConversationTurnController.ts:45-91` 通过 IPC `ai.stream.open`（`:59`）把 `buildStreamRequest(...)` 的结果发给主进程，`AiStreamManager.dispatch`（IPC 入口见 `src/main/ipc/handlers/ai.ts:163-168`）完成模型解析、上下文拼装与逐模型执行启动，最终经 AI SDK 代理层交给 provider runtime 发起流式调用。每个环节的符号名与行号见下方「系统边界与生成任务主链」分步图。
- **上下文拼装集中在一个入口**：`PersistentChatContextProvider.resolveCompactedHistory`（`:687-835`）负责选历史与压缩——沿锚点取活动路径（`MessageService.getPathToNode`，`:697`），丢弃最近 `data-clear` 标记及其之前的记录，再按最深 marker 与上下文窗口应用持久化压缩（步骤与条件见第 2、3 节）。模型转换阶段由 `toModelMessages`（`src/main/ai/messages/messageRules.ts:122-133`）统一执行：重放持久化工具输出、把旧版 MCP 工具名规范化为 wire 合法名、按模型能力（`toolResultCaps`）门控或剔除媒体、合并相邻同角色消息并补齐空 assistant。
- **多模型"同时回复"字面意义上是真并行**：`resolveModels`（`modelResolution.ts:15-25`）解析出 N 个模型后，在**一个事务**里建 1 条用户消息 + N 条 assistant 占位消息（共享同一 `siblingsGroupId`，`MessageService.ts:1160-1297`），随后 `AiStreamManager.send()` 对每个模型**并行**启动独立的执行循环（`:594-604`）。
- **重试/回退可配置**：普通聊天请求由 `AiService.streamText` 包一层 `createRetryableWrap`（`AiService.ts:565-590`，实现在 `runtime/aiSdk/retry/`）——同模型瞬态错误先按 `chat.retry.*` 偏好重试，重试耗尽后再按用户配置顺序试 fallback 模型并按能力过滤。相关配置与广播契约：
  - 总开关 `chat.retry.enabled` 默认关闭（`preferenceSchemas.ts:617`）；请求级 `maxRetries: 0` 会显式关闭该包装（`:567`）。
  - 重试事件以 `data-retry` part 实时广播给渲染层（`:588`），持久化前被 `PersistenceListener` 剥离。
- **四类输入的组织方式不统一**：文件/知识库=消息 parts，联网=assistant 设置布尔开关（`capabilityBody`），推理=独立的 `reasoningEffort` 请求字段，工具=渲染期决定显示、主进程模型能力判定实际携带。
- **停止在网络层有明确接线**：停止入口经 IPC `ai.stream.abort` 进入 `AiStreamManager.abort`（`AiStreamManager.ts:872-891`），对每个 execution 执行 `AbortController.abort()`，该 signal 随后传入流式请求的 `requestOptions.signal`（`:1484-1487`）交给 AI SDK；中断效果未运行验证。
- **崩溃与备份有专门的收口机制**：启动时 boot reconcile 把遗留 `pending` assistant 行翻为 `error`（`:497-506`）；备份恢复期间用暂停与在途排空两个入口门禁新 turn 并等待在途持久化完成（`pause`/`drainInFlight`，`:371-442`）。

## 系统边界与生成任务主链

```text
ChatContent.onSend
  -> useChatRuntimeState.sendMessage（useChatRuntimeState.ts:419-429）
  -> buildStreamRequest（useChatRuntimeState.ts:290-305）-> useConversationTurnController.ts:59 IPC ai.stream.open
  -> AiStreamManager.dispatch（AiStreamManager.ts:309-335，per-topic dispatchLock + 写安静期门禁 + boot reconcile 门禁）
      -> dispatchStreamRequest -> PersistentChatContextProvider.prepareDispatch（:210-440）
          解析模型 -> createUserMessageWithPlaceholders（1 用户行 + N assistant 占位，一个事务）
          -> resolveCompactedHistory（:687-835）-> buildStreamRequest（:401-415）
  -> AiStreamManager.send（:544-630）：逐模型 createAndLaunchExecution（:1430-1468），各自 runExecutionLoop（:1470-1569）
  -> AiService.streamText（AiService.ts:502-623，retry wrap :565-590）
  -> AI SDK Agent（aiSdk/Agent.ts:237-256）initialMessages -> toModelMessages -> aiAgent.stream
  -> runtime/provider 流式调用（HTTP payload 由 AI SDK 与 provider runtime 负责）
  -> onChunk（AiStreamManager.ts:898-995）ring buffer + 监听器扇出
  -> PersistenceListener / MessageServiceBackend 写占位消息（终态落库）
  -> IPC chunk/done/error -> 渲染侧 TopicStreamSubscription -> readUIMessageStream（渲染侧细节见消息渲染器）
```

边界：请求开始前读取哪些持久化对象（锚点路径、消息树）与结束后写回哪些对象（占位消息、`activeNodeId`）的数据语义在会话与消息管理（`../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md`）；Composer 按钮、发送前配置、分支按钮、停止入口等用户可见工作流在 `<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>`；流式 chunk 到可见状态前的消费、缓冲与 DOM 更新在消息渲染器（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

- **提交入口**：`ChatContent.tsx` 的 `onSend` 经渲染层发送入口组装后，由 `useConversationTurnController.send`（`useConversationTurnController.ts:45-91`）通过 IPC `ai.stream.open`（`:59`）发送 `buildStreamRequest(...)` 组装出的 `ChatTurnInput`——携带模型引用、推理级别、快速模式、用户消息 parts 与发送目标等字段（定义 `:44-53`）。
- **发送阶段机**：发送过程有显式状态机 `draft/persisting/opening/streaming/ready`（`:11,34`）：`ai.stream.open` 返回 `blocked` 时 toast 提示并回到 `ready`（`:61-68`）；失败时用 `historyAdapter.rollback` 回滚渲染层缓存（`:80-88`）。
- **占位消息初始化**：主进程 `createUserMessageWithPlaceholders`（一个事务）建 1 条用户消息 + N 条 assistant 占位消息（每模型一条，都带同一 `siblingsGroupId`；`MessageService.ts:1160-1297`），随后为每个模型构建独立的 `AiStreamRequest` 并各开一个 `ai.turn` trace span（`startTurnRootSpans`，`PersistentChatContextProvider.ts:120-143`）。
- **流式期间的分支提交**：提交目标是"预留空分支叶子"（`awaiting-input` 状态）时用 `mode: 'fill-reserved'` 在同一事务里填充该行并建占位（要求 `req.trigger === 'submit-message'` 且 `parentAnchorId` 指向该叶子，`:234-241,308-327`）；但流式进行中这种提交在主进程侧会被直接拒绝（`:247-253`，提示语意为"预留分支在流式进行时不可提交"），是渲染层排队的竞态兜底。若在活动路径上提交则走 steer：落一条带 `modelId` 的用户行并排队（`:257-280`），由 `prepareSteerContinuation`（`:542-634`）在下一轮续答。
- **任务状态机**：`AiStreamManager` 是中心化状态机类（1673 行），同时管 chat/prompt/agent-session 三种流、steer 队列、tool approval、多模型并行执行、grace-period 驱逐。`ActiveStream.status` 有 6 种取值：`pending`/`streaming`/`done`/`error`/`aborted`/`awaiting-approval`，收敛逻辑在 `computeTopicStatus`（`:1645-1660`）与 `resolveTerminalStatus`（`:1635-1643`，含 approval 收敛）。代码注释本身承认这类正确性隐患（例如 `message-tree.md:109-112` 对 `SET NULL` 方案的否定、`AiStreamManager.ts:242` 对 `dispatchLock` 必要性的解释），说明维护者也清楚这里状态复杂、容易出竞态，属于"必要复杂度"而非明显可简化，但对新人理解成本确实高（取舍见第 10 节）。
- **入口门禁**：`dispatch()`（`:309-335`）是唯一 chat 流入口，串行经过 boot reconcile 门禁、每 topic `dispatchLock`、备份恢复写安静期门禁（返回 `{mode:'blocked', reason:'paused'}`）三道检查（各段行号见 `:310-326`）。

## 2. 历史选择与上下文拼装顺序

- **历史取法**：持久化历史由 `MessageService.getPathToNode`（`MessageService.ts:1874-1878`）按锚点取根到节点的活动路径（虚拟根被排除，数据语义见会话与消息管理笔记 4.2）。
- **注入顺序**：`resolveCompactedHistory`（`PersistentChatContextProvider.ts:687-835`）先取锚点路径（`:697`），丢弃最近 `data-clear` 标记及其之前的记录，再应用压缩视图（见第 3 节）。`collectRetainedContext`（`:706-707`，`src/main/ai/messages/retainedContext.ts`）从**原始路径**收集能力保留上下文——折叠会吃掉 file part 与工具输出，若从压缩后视图扫描会漏掉 `read_file` 等工具所需附件。
- **输入 parts 拼装**（renderer 侧）：`buildComposerQueuedPayload`（`src/renderer/components/composer/variants/shared/composerQueuedPayload.ts:31-51`）汇总草稿和队列输入；知识库范围以 `data-knowledge-scope` part 注入（`ChatComposer.tsx:1344`，注入函数见 `uiParts.ts:376-388`），附件 part 在发送时由 `buildFilePartsForAttachments` 生成（`ChatComposer.tsx:1365`）。
- **模型转换阶段**：`toModelMessages`（`messageRules.ts:122-133`）把消息投影为模型消息，依次执行：
  1. 重放持久化工具输出（`renderPersistedToolOutputs`）；
  2. 把非法 `dynamic-tool` 名规范化为 wire 合法名（SHA-1 摘要后缀，`:77-82,94-109`）；
  3. 剔除模型不支持的媒体（`stripUnsupportedMedia`）；
  4. 转换消息并丢弃悬空的不完整工具调用（`convertToModelMessages`）；
  5. 按模型能力门控工具结果内的媒体（`gateToolResultMedia`/`toolResultCaps`，见 `messageCapabilities.ts`）；
  6. 合并相邻同角色消息（`coalesceConsecutiveSameRole`，`:29-50`）；
  7. 给空 assistant 补 `'...'`（`ensureNonEmptyAssistantContent`，`:60-66`；Gemini 会拒绝空 content，见 `:52-59` 注释）。
  知识库范围与工具配置仍由请求字段/metadata 传递（`knowledgeBaseIds`/`tools`）。
- **steer 续答**：`prepareSteerContinuation` 复用已持久化的用户行，在模型侧历史副本里给该用户消息包一层 steer system-reminder（`withSteerReminder`，`:168-180,606`），持久化行本身不动。

## 3. 预算、截断、摘要与压缩

- 当前源码把压缩作为**独立的持久化上下文阶段**处理：`resolveCompactedHistory` 先按分支和清理标记确定历史，再按上下文窗口决定是否生成或沿用摘要。
- **触发与预算**：以所有模型的 `contextWindow` 最小值做窗口（`resolveMinContextWindow`，`:732`；无 `contextWindow` 的模型直接跳过压缩，`:733-736`）；估算优先用最近带真实 `contextTokens` 的 assistant 行做锚点（`:662-674`），超过 `minContextWindow * CONTEXT_COMPACT_TRIGGER_RATIO` 触发（`:737`）；保留预算为 `minContextWindow * CONTEXT_COMPACT_KEEP_BUDGET_RATIO`（`:742`，且裁剪边界 `planKeepBoundary` 只能落在 user 行上）。
- **折叠执行**：把边界之前的行转成模型消息交给压缩模型（`summarizeModelMessages`，`:765-788`；输入预算按压缩模型自己的窗口算，避免 128k 聊天把 8k 压缩器撑爆，`:779-788`）。成功则 `messageService.setCompactionSummary` 持久化摘要（`:819`，`MessageService.ts:818-823`）；失败或空摘要以 `status: 'skipped'` 结算且不留时间线锚点（`:807-818,824-834`），避免"未压缩的历史"被渲染成"已压缩"标记。树结构本身不被修改，只写 `compactionSummary` 列（`:685` 注释）。
- 每个 provider 的 token budget 算法未逐一展开；压缩触发阈值未运行验证（见第 11 节）。

## 4. SDK、Provider、模型与协议交接

- renderer 通过 `ai.stream.open`（`useConversationTurnController.ts:59`）把构建后的 turn 请求交给 main；主进程 `dispatch` 经 `dispatchStreamRequest`（`context/dispatch.ts:73-115`，`blocked` 分支 `:106-115`）进入 `PersistentChatContextProvider.prepareDispatch`（`:210-440`）。
- **模型解析**：`resolveModels(mentionedModelIds, defaultModelId)`（`modelResolution.ts:15-25`）解析出模型数组，超过一个即视为多模型（`PersistentChatContextProvider.ts:284-285`）；多模型由 `resolvePersistentSiblingsGroupId`（`modelResolution.ts:53-64`）分配新组号、regenerate 则继承或新分配组号；无 assistant 时回退 `chat.default_model_id` 偏好（`resolveAssistantModelId`，`:32-45`）。
- **AI SDK 交接**：`AiService.streamText`（`AiService.ts:502-623`）要求调用方注入 `AbortSignal`（`:507-510`），构建 `Agent`（`:592-619`）后调用其流式接口（`:622`）。Agent 内部把 `initialMessages` 经 `toModelMessages` 转成模型消息（`Agent.ts:245-250`），再交给 AI SDK 的 `aiAgent.stream`（`:253-256`）；`generateMessageId` 优先复用调用方提供的 messageId，使 UI 占位行与流内 id 一致（`Agent.ts:268-274`）。具体 HTTP payload 由 AI SDK 与 provider runtime 负责，本笔记未展开；不同 Agent runtime 的完整差异未运行验证（第 11 节）。

## 5. 流式事件、缓冲、节流与顺序

- **主进程写入侧**：N 个执行循环各自流式写各自的占位消息，经各自的 `PersistenceListener`/`MessageServiceBackend` 终态落盘（`PersistentChatContextProvider.ts:362-389`；`MessageServiceBackend.persistAssistant` 只在终态写，失败把占位行翻 `error`，`persistence/backends/MessageServiceBackend.ts:30-48`）。流式期间中间增量落盘的频率本次未核实——未发现执行侧有逐 chunk 节流落盘的证据，最终态落盘语义见第 6 节。
- **重连回放缓冲（ring buffer）**：每个 execution 一个环形缓冲（`onChunk`，`AiStreamManager.ts:939-962`），缓存最近未送达的 delta 供迟到监听器重放。设计要点：
  - 入队时把连续 delta 合并进尾部、超长 delta 先切分（`maxDeltaBytes=16_384`，默认配置 `:146-154` 的 `:151`），避免 delta 洪泛把自身 part 的开头 chunk 挤出导致重放不可解析；
  - 环形淘汰在有挂起审批时暂停（审批的 tool-input chunk 是重连后仍须可操作的状态，`:956`），淘汰计数记在 `droppedChunks`（`:958`）；
  - `addListener` 对迟到监听器重放缓冲（`:818-830`），`attach` 时用 `buildCompactReplay` 重建紧凑重放（`:1400`）。
- **渲染侧交接点**：IPC 的 `ai.stream.chunk/done/error` 事件经 `TopicStreamSubscription` 按 `topic -> execution + anchor` 分流，再由 `readUIMessageStream` 组装 parts，`useExecutionOverlay` 按 `requestAnimationFrame` 合并帧提交 overlay。anchor 用于区分同一 execution 中的不同 turn；steer/continue 时 execution 可能切换 assistant row。这些细节属消息渲染器笔记（"流式消息链路"一节），本类目只记录交接契约。平滑播放（jitter buffer）在渲染侧（`useSmoothStream`），见消息渲染器笔记。
- **顺序保证**：terminal 事件（done/paused/error）在流式循环里按序发生，渲染侧"先刷新数据库、再清理 overlay"的交接由 `useTopicOverlayHandoffOnTerminal` 驱动（`useTopicStreamStatus.ts:99-117`），保证最终画面先可见再执行持久化交接。

## 6. 完成、异常、半截流与最终回写

- **终态收敛**：`onExecutionDone`（`AiStreamManager.ts:998-1045`）/`onExecutionPaused`（`:1047-1082`）/`onExecutionError`（`:1085-1134`）是三条主要终止转换路径，经 `resolveTerminalStatus`/`computeTopicStatus`（`:1635-1660`）收敛为终态，`runTerminalLifecycle`（`:1199-1206`）处理终态广播与清理。
- **abort 与空闲超时**：`abort()`（`:872-891`）同步把 status 置为 `aborted` 并 abort 各 execution 的 `AbortController`；空闲超时（`withIdleTimeout`，`:1512-1513`）直接 abort controller，执行循环检测到 aborted 后把 exec.status 提升为 `aborted` 并走暂停分支，使截断回复以 `paused` 而不是 `success` 持久化（`:1557-1563`）。
- **最终化交接**：渲染侧 `PersistenceListener.onDone/onPaused/onError` 之后，`MessageServiceBackend.persistAssistant` 调 `MessageService.finalizeAssistantMessage`（`MessageService.ts:1402-1432`）把终态 parts/status/stats 写回占位行；渲染侧"流结束后页面先刷新数据库，再清理 overlay"（`useTopicStreamStatus.ts:99-117`，消息渲染器笔记"history 与 overlay 的交接"）。本类目记录这一"最终回写 = 刷新 DB + 清理 overlay"的交接语义。
- **错误路径**：Home 侧消息流错误走 `onExecutionError` + `broadcastTopicError`；Agent 侧另有 `withTerminalErrorFallback`——agent 消息终态是 `error`/`success` 但没有可见 part 时，主动补一条 `data-error` part 防止 UI 卡在空白/转圈（`agentMessageListAdapter.tsx:48-73`，UI 侧兜底见 Chat UI 笔记 6.2）。
- **半截流的落盘形状**：停止/超时产生的半截 assistant 消息以 `status='paused'` 持久化（执行循环 `:1557-1563` + `finalizeAssistantMessage` 接受 `paused`，`MessageService.ts:1406`）；工具审批等待中的打断由 `finalizeInterruptedParts` 在每个投影点把悬挂工具 part 终态化为 `output-error`（`AiStreamManager.ts:1054-1060` 注释）。

## 7. 停止、重试、续写与重新生成

- **停止**：停止入口在 UI（ComposerSurface 的暂停/停止工具按钮，见 Chat UI 笔记 5）；执行链是 `useChatWithHistory.stop`（`useChatWithHistory.ts:67-74`）→ IPC `ai.stream.abort`（`ai.ts:179-181`）→ `AiStreamManager.abort`（`:872-891`）→ 各 execution 的 `AbortController.abort(reason)` → 该 signal 已注入流式请求的 `requestOptions.signal`（`AiService.ts:507-510`）→ AI SDK 侧中断请求。即**代码层面停止确实接到了网络 abort**；实际取消效果未运行验证（第 11 节）。
- **重试/重新生成（用户动作）**：`ChatWriteActions.regenerateMessage` 等经 `ChatWriteContext` 注入真实实现（入口见 Chat UI 笔记 6.1、6.2）；请求 `trigger='regenerate-message'` 需要 `parentAnchorId`（`PersistentChatContextProvider.ts:283,291-293`），live 期间 regenerate 被拒（`:298-300`）；regenerate 继承源回复的模型与 turnOptions（`useChatWriteActions.ts:304-344`）。起始上下文仍由锚点路径机制决定（第 2 节，数据语义见会话与消息管理笔记 4.2、4.3）。
- **Provider 层重试与 fallback**：注意这是同一任务内部的请求级重试，与用户手动"重新生成"（新消息分支）是不同机制。`AiService.streamText` 的 `createRetryableWrap`（`AiService.ts:565-590`）实现为同模型按 `maxAttempts` 重试后再按用户顺序逐一试 fallback（`runtime/aiSdk/retry/createRetryableWrap.ts:107-138`）。
- **续写（continue）与审批续跑**：`trigger='continue-conversation'` 复用原 assistant 行（不建新占位），主进程先把审批决定写回 parts 并把 status 置 `pending`（`prepareContinueDispatch`，`PersistentChatContextProvider.ts:448-535`；审批决定用单事务串行化，`MessageService.applyToolApprovalDecisions`，`MessageService.ts:1474-1529`），再用原模型续流。等待审批时流暂停，审批空闲上限 2 小时（`approvalIdleTimeoutMs`，`AiStreamManager.ts:154,1533`）；同一回复的多工具审批可逐个连续推进。审批通过后 reader 用数据库当前 anchor message 作为 seed，使新到的 tool output 合并到既有 tool input（渲染侧细节见消息渲染器笔记；审批界面工作流见 Chat UI 与 Agent 工具类目）。
- **编辑后发送**：编辑消息时保存旧草稿、取消时还原的界面状态机见 Chat UI 笔记 3.3；发送锚定（挂到哪个 parent）语义见会话与消息管理笔记 4.3、4.4。

## 8. 队列、多会话并发与后台生成

- **多模型并行**：`AiStreamManager.send()`（`:544-630`）对每个模型 `createAndLaunchExecution`（`:1430-1468`），**并行**启动 N 个独立的执行循环，各自流式写各自的占位消息；共享同一 `siblingsGroupId` 只用于读侧把占位行分到同一兄弟组展示（分桶见会话与消息管理笔记 4.2）。
- **队列**：
  - **steer 队列（主进程）**：流式期间的后续发送落一条用户行并入队（`enqueuePendingSteer`，`AiStreamManager.ts:772-802`），运行中的 turn 在步骤边界让出（`hasPendingSteer`，`:764-768`），`onExecutionDone` 干净收尾时调度 `steer-continuation`（`:1038`，实现 `:1212`）；`awaiting-approval` 状态不立即续答（审批续跑后顺带消费）；aborted/error 后 drop 队列（`:1040-1042`）。
  - **follow-up 队列（渲染层）**：`ChatComposer` 的 `useFollowupQueue`（`ChatComposer.tsx:1401-1414`），topic 空闲时自动 drain（`onDrain: sendQueuedPayload`）。
  - **同一会话是否完全串行化、不同会话是否并行、再次发送是排队还是报错**：`dispatchLock` 只序列化"准备+启动"窗口，不序列化运行本身；运行期再次发送按触发时机走 steer/排队/拒绝（reserved-branch）三条路之一。运行行为未逐一验证（第 11 节）。
- **后台生成**：渲染侧组件卸载时 `useExecutionOverlay` release 视图但不拆 reader、不 abort（`useExecutionOverlay.ts:66-69` 注释；transport 的 detach 只移除监听器），主进程可继续生成并持久化。`AiStreamManager` 有 grace-period 驱逐（默认 30 秒，`:147,289`，`lifecycle/ChatStreamLifecycle.ts:55-56`），`backgroundMode` 默认 `'continue'`（`:148`），仅当配置为 `'abort'` 时才在监听器归零时中止（`:991-994`）。切换会话/离开页面后任务如何收口本次未验证。

## 9. Agent、工具、知识库与附件注入点

- **模型解析**：见第 4 节（`resolveModels`/`resolvePersistentSiblingsGroupId`）。
- **知识库**：不走单独字段，而是编码进 `userMessageParts` 里的 `data-knowledge-scope` part（注入函数 `withKnowledgeScopePart`，`ChatComposer.tsx:1344`，实现见 `uiParts.ts:348,376-388`）；主进程从 parts 读回并放进请求的 `knowledgeBaseIds`（`getKnowledgeBaseIdsFromParts`，`PersistentChatContextProvider.ts:400`）。
- **附件**：`sendQueuedPayload`（`ChatComposer.tsx:1359-1383`）里 `buildFilePartsForAttachments(attachments)` 把附件转成 file part 拼进 `userMessageParts`（`:1365-1368`）；主进程在 `AiService.streamText` 里按模型的原生文件支持路由附件（`AiService.ts:556-561`）。
- **联网搜索**：不进 parts，是 `assistant.settings.enableWebSearch` 的布尔开关，经 `capabilityBody`（`useChatWriteActions.ts:296-301`）随 regenerate 等请求携带；实际搜索执行在 AI SDK 工具侧。
- **推理强度**：`reasoningEffort` 是独立请求字段，从渲染层的 `ChatTurnInput.options.reasoningEffort`（`useChatRuntimeState.ts:44-53`）经 `buildStreamRequest`（`:290-305`）一路通过 IPC `ai.stream.open` 带到主进程的 `AiStreamRequest.reasoningEffort`（`PersistentChatContextProvider.ts:286-289`）。
- **工具**：`ComposerToolRuntimeHost`/各 `defineTool`（`src/renderer/components/composer/tools/definitions/*.tsx`）在渲染期决定要不要显示；实际"要不要带上某工具"由主进程侧模型能力判定，不在这层。四类输入的组织方式并不统一：文件/知识库=消息 parts，联网=assistant 设置，推理=独立请求字段，工具=能力判定。
- 工具执行循环的内部语义（发现、协议、执行、审批）属 Agent 工具类目，本笔记只记录注入点与交接契约。

## 10. 退出恢复、日志与已确认边界

- **启动/崩溃恢复**：boot reconcile 把遗留 `pending` 翻 `error`（第 1 节；`AiStreamManager.ts:497-506`）；`onStop` 在退出时 abort 所有 live 流并等待执行循环落盘完成（`:514-534`）。
- **备份恢复**：`pause()`/`drainInFlight()` 写安静期（`:371-442`），dispatch 门禁返回 `blocked`（`:321-326`）。
- **可观测性**：每个模型的 turn 有独立 `ai.turn` trace span（`startTurnRootSpans`，`PersistentChatContextProvider.ts:120-143`；构建好的请求由 `applyTurnInputAttributes` 写入 span 属性，`:417-425`），容器级 trace id 存 topic 行（`TopicService.ensureTraceId`，`:157-177`）；用量经 `createAiUsagePlugin` 捕获（`AiService.ts:539-552`）。AI 错误以 `data-error` part 持久化（渲染侧展示见消息渲染器笔记）。日志/用量与具体任务的多窗口关联方式本次未展开。
- **已确认边界（取舍）**：`AiStreamManager` 的中心化状态机复杂度是维护者自己承认的正确性隐患来源（第 1 节），属于"必要复杂度"，但新人理解成本高；ring buffer 与 approval 暂停淘汰是"可重放性优先于吞吐"的取舍。
- **类目边界**：停止生成的半截消息最终如何保存（数据语义）见会话与消息管理；停止按钮状态、排队提示、重试入口等用户工作流见 Chat UI；流式事件到 DOM 的消费见消息渲染器。

## 11. 未验证事项

- 流式中断/停止的网络级取消效果、压缩触发阈值、不同 Agent runtime 的完整差异、provider 最终 HTTP payload 字段未运行验证。
- 同会话串行/并发运行行为、steer 队列与 follow-up 队列的运行语义、后台生成收口、退出中途任务处理未验证。
- 流式期间中间增量落盘的频率未核实（第 5 节）；审批空闲 2 小时上限、grace-period 驱逐的实际触发未运行验证。
- 工具执行循环内部细节属 Agent 工具类目，本笔记未覆盖。

## 12. 关键源码索引

- `src/renderer/pages/home/ChatContent.tsx`、`useChatRuntimeState.ts`（提交入口与 `buildStreamRequest`）
- `src/renderer/hooks/useConversationTurnController.ts`（IPC `ai.stream.open` 与阶段机）
- `src/renderer/components/composer/variants/ChatComposer.tsx`、`shared/composerQueuedPayload.ts`（`buildQueuedPayload`/`sendQueuedPayload`）
- `src/renderer/hooks/chat/ChatWriteContext.ts`、`src/renderer/pages/home/hooks/useChatWriteActions.ts`（写操作与能力注入）
- `src/main/ipc/handlers/ai.ts`（`ai.stream.open/abort/attach/detach`）
- `src/main/ai/streamManager/AiStreamManager.ts`（状态机、`dispatch`/`send`/`runExecutionLoop`/ring buffer/abort）
- `src/main/ai/streamManager/context/{PersistentChatContextProvider,dispatch,modelResolution}.ts`
- `src/main/ai/messages/messageRules.ts`（`toModelMessages` 整形管线）
- `src/main/ai/AiService.ts`、`src/main/ai/runtime/aiSdk/retry/`（streamText、retry wrap、fallback 过滤）
- `src/main/ai/runtime/aiSdk/Agent.ts`（`initialMessages` 转换与 SDK 交接）
- `src/main/data/services/MessageService.ts`（`getPathToNode`、`createUserMessageWithPlaceholders`、`finalizeAssistantMessage`，数据语义见会话与消息管理）
