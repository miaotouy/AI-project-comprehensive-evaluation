# Cherry Studio 对话请求与上下文调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：直接阅读源码（渲染层提交链路、主进程 `AiStreamManager` 状态机与 `PersistentChatContextProvider` 上下文拼装、AI SDK Agent 交接、`messageRules` 消息整形与重试包装），并核对行号与符号至当前 HEAD
>
> 调查范围：一次生成任务的提交入口、任务状态机、上下文拼装顺序、预算压缩、Provider 交接、流式事件链、最终化回写、停止重试续写、队列并发与外部能力注入；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **主链**：一次生成请求先在渲染层组装，再由主进程集中编排：渲染层把当次会话、模型与输入整理成一次 turn，请求体由 `buildStreamRequest` 生成，经 IPC `ai.stream.open` 交给主进程；主进程完成模型解析、上下文拼装与逐模型执行启动，最终经 AI SDK 代理层交给 provider runtime 发起流式调用。
  入口链路是 `ChatContent.onSend`，主进程侧总入口为流管理器的 dispatch（`useConversationTurnController.ts:45-91`；IPC 注册见 `src/main/ipc/handlers/ai.ts:163-168`）；分步图见下文「系统边界与生成任务主链」。
- **上下文拼装集中在一个入口**：`PersistentChatContextProvider.resolveCompactedHistory` 负责选历史与压缩：沿锚点取活动路径，丢弃最近 `data-clear` 标记及其之前的记录，再按最深 marker 与上下文窗口应用持久化压缩（`PersistentChatContextProvider.ts:687-835`，路径取自 `MessageService.getPathToNode`；步骤与条件见第 2、3 节）。
- **模型消息转换**：`toModelMessages` 统一执行四件事：重放持久化工具输出、把旧版 MCP 工具名规范化为 wire 合法名、按模型能力（`toolResultCaps`）门控或剔除媒体、合并相邻同角色消息并补齐空 assistant（`src/main/ai/messages/messageRules.ts:122-133`）。
- **多模型"同时回复"是并行执行**：模型解析出 N 个模型后，主进程在**一个事务**里建 1 条用户消息和 N 条 assistant 占位消息，占位消息共享同一 `siblingsGroupId`；随后发送入口对每个模型**并行**启动独立的执行循环（`modelResolution.ts:15-25`、`MessageService.ts:1160-1297`、`AiStreamManager.ts:594-604`）。
- **重试/回退可配置**：普通聊天请求由 `AiService.streamText` 包一层 `createRetryableWrap`——同模型瞬态错误先按 `chat.retry.*` 偏好重试，重试耗尽后再按用户配置顺序试 fallback 模型并按能力过滤。相关配置与广播契约：
  - 总开关 `chat.retry.enabled` 默认关闭，请求级 `maxRetries: 0` 会显式关闭该包装（`preferenceSchemas.ts:617`、`AiService.ts:567`）。
  - 重试事件以 `data-retry` part 实时广播给渲染层，持久化前被 `PersistenceListener` 剥离（`AiService.ts:588`）。
- **四类输入的组织方式各自不同**：文件和知识库走消息 parts，联网是 assistant 设置的布尔开关（`capabilityBody`），推理强度是独立的 `reasoningEffort` 请求字段，工具是否显示由渲染期决定、是否实际携带由主进程按模型能力判定。
- **停止在网络层有明确接线**：停止入口经 IPC `ai.stream.abort` 进入 `AiStreamManager.abort`，对每个 execution 执行 `AbortController.abort()`，该 signal 随后作为 `requestOptions.signal` 传入流式请求交给 AI SDK（`AiStreamManager.ts:872-1487`）；中断效果未运行验证。
- **崩溃与备份有专门的收口机制**：启动时 boot reconcile 把遗留的 `pending` assistant 行翻为 `error`；备份恢复期间用暂停与在途排空两个入口（`pause`、`drainInFlight`）门禁新 turn，并等待在途持久化完成（`AiStreamManager.ts:371-506`）。

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
  -> IPC chunk/done/error -> 渲染侧 StreamDispatchService -> MessageProjectionService -> readUIMessageStream（渲染侧细节见消息渲染器）
```

边界：请求开始前读取哪些持久化对象（锚点路径、消息树）与结束后写回哪些对象（占位消息、`activeNodeId`）的数据语义在会话与消息管理（`../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md`）；Composer 按钮、发送前配置、分支按钮、停止入口等用户可见工作流在 `<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>`；流式 chunk 到可见状态前的消费、缓冲与 DOM 更新在消息渲染器（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

- **提交入口**：用户点击发送后，`ChatContent` 的发送回调先经渲染层入口组装，再由回合控制器通过 IPC `ai.stream.open` 发给主进程。
  请求体携带模型引用、推理级别、快速模式、用户消息 parts 与发送目标等字段，入口、IPC 调用与字段定义集中在 `useConversationTurnController.ts:44-91`。
- **发送阶段机**：控制器初始与切换会话时处于 draft；发送先持久化会话，再进入 opening。打开流受理后进入 streaming；返回 `blocked` 时转 ready 并提示，异常则经 history adapter 回滚缓存并回到 draft。各分支见 `useConversationTurnController.ts:46-117`。
- **占位消息初始化**：主进程在一个事务里建出 1 条用户消息和 N 条 assistant 占位消息，每个模型对应一条并共用同一个 `siblingsGroupId`（`MessageService.ts:1160-1297`）。随后它给每个模型构建独立的流式请求，各开一个 `ai.turn` trace span（`PersistentChatContextProvider.ts:120-143`）。
- **流式期间的分支提交**：当提交目标是预留的空分支叶子（状态 `awaiting-input`）时，主进程在同一事务里填充该行并建立占位，前提是请求触发类型为 `submit-message` 且父锚点指向该叶子（`PersistentChatContextProvider.ts:234-327`）。流式进行中再提交会被主进程直接拒绝，提示语意为"预留分支在流式进行时不可提交"，这是渲染层排队的竞态兜底。
- **活动路径上的提交走 steer**：提交落在活动路径上时，主进程落一条带 `modelId` 的用户行并排队，等下一轮由 `prepareSteerContinuation` 续答（`PersistentChatContextProvider.ts:257-634`）。
- **任务状态机**：`AiStreamManager` 是中心化状态机类（1673 行），同时管理 chat、prompt、agent-session 三种流，以及 steer 队列、tool approval、多模型并行执行与 grace-period 驱逐。`ActiveStream.status` 的取值与收敛：
  - 状态共 6 个取值：

    ```text
    pending / streaming / done / error / aborted / awaiting-approval
    ```
  - 是否收敛为终态由 `computeTopicStatus` 与 `resolveTerminalStatus` 判断，后者包含 approval 的收敛；代码注释记录了两处正确性顾虑：`message-tree.md:109-112` 否定 `SET NULL` 方案，`AiStreamManager.ts:242,1635-1660` 解释 dispatchLock 的必要性；相关取舍见第 11 节。
- **入口门禁**：`dispatch` 是唯一的 chat 流入口，依次执行 boot reconcile 门禁、每 topic 的 `dispatchLock` 与备份恢复写安静期门禁三道检查；命中暂停时返回 `{mode:'blocked', reason:'paused'}`（`AiStreamManager.ts:309-335`）。

## 2. 历史选择与上下文拼装顺序

- **历史取法**：持久化历史由 `MessageService.getPathToNode` 按锚点取根到节点的活动路径，虚拟根被排除（`MessageService.ts:1874-1878`，数据语义见会话与消息管理笔记 4.2）。
- **注入顺序**：`resolveCompactedHistory` 先取锚点路径，丢弃最近 `data-clear` 标记及其之前的记录，再应用压缩视图（`PersistentChatContextProvider.ts:687-835`；压缩见第 3 节）。
- **保留上下文的取数窗口**：`collectRetainedContext` 从原始路径收集能力保留上下文，因为折叠会吃掉 file part 与工具输出，若从压缩后视图扫描就会漏掉 `read_file` 等工具所需附件（`PersistentChatContextProvider.ts:706-707`，实现在 `src/main/ai/messages/retainedContext.ts`）。
- **输入 parts 拼装（渲染层）**：组装器汇总草稿与队列输入；知识库范围以 `data-knowledge-scope` part 注入，附件 part 在发送时生成（`src/renderer/components/composer/variants/shared/composerQueuedPayload.ts:31-51`、`ChatComposer.tsx:1344-1365`、`uiParts.ts:376-388`）。
- **模型转换阶段**：`toModelMessages` 把消息投影为模型消息，依次执行七步（`messageRules.ts:29-133`）：
  1. 重放持久化工具输出（`renderPersistedToolOutputs`）；
  2. 把非法 `dynamic-tool` 名规范化为 wire 合法名，追加 SHA-1 摘要后缀；
  3. 剔除模型不支持的媒体（`stripUnsupportedMedia`）；
  4. 转换消息并丢弃悬空的不完整工具调用（`convertToModelMessages`）；
  5. 按模型能力门控工具结果内的媒体（`gateToolResultMedia`/`toolResultCaps`，见 `messageCapabilities.ts`）；
  6. 合并相邻同角色消息（`coalesceConsecutiveSameRole`）；
  7. 给空 assistant 补 `'...'`，因为 Gemini 会拒绝空内容。
  知识库范围与工具配置仍由请求字段或 metadata 传递（`knowledgeBaseIds`、`tools`）。
  重放阶段另有几类防御：名为空的 dynamic tool 调用、同一 id 的重复工具 part、入参不是对象的旧工具 part 都在重放前被丢弃，避免把历史脏数据变成非法请求。渲染层手工编辑过的已签名 thinking part 在重放时被改写成普通 `<think>` 文本块，因为签名已不可信。
- **steer 续答**：`prepareSteerContinuation` 复用已持久化的用户行，在模型侧历史副本里给该用户消息包一层 steer system-reminder（`withSteerReminder`），持久化行本身不动（`PersistentChatContextProvider.ts:168-606`）。

## 3. 预算、截断、摘要与压缩

- 当前源码把压缩作为**独立的持久化上下文阶段**处理：`resolveCompactedHistory` 先按分支和清理标记确定历史，再按上下文窗口决定是否生成或沿用摘要。
- **触发与预算**：压缩以可供输入使用的窗口空间为基数，阈值由偏好 `chat.context_settings.compress.threshold_percent` 控制（默认 80%）：触发点为 `inputRoom * thresholdPercent / 100`，保留预算是触发点的 37.5%，裁剪边界仍只能落在 user 行。设置页允许跟随当前模型或指定压缩模型；计算、默认值与比例常量见 `src/main/ai/streamManager/context/PersistentChatContextProvider.ts:977-983`、`src/shared/data/preference/preferenceSchemas.ts:642`、`src/main/ai/constants.ts:12-18`。
- **折叠执行**：边界之前的行被转成模型消息交给压缩模型（`summarizeModelMessages`），输入预算按压缩模型自己的窗口算，避免 128k 聊天把 8k 压缩器撑爆；成功则 `messageService.setCompactionSummary` 持久化摘要（`PersistentChatContextProvider.ts:765-819`、`MessageService.ts:818-823`）。
- **失败结算与树结构**：失败或空摘要以 `status: 'skipped'` 结算，且不留时间线锚点，避免"未压缩的历史"被渲染成"已压缩"标记；树结构本身不被修改，只写 `compactionSummary` 列（`PersistentChatContextProvider.ts:685-834`）。
- 每个 provider 的 token budget 算法未逐一展开；压缩触发阈值未运行验证（见第 12 节）。

## 4. SDK、Provider、模型与协议交接

- **请求交给主进程**：渲染层通过 IPC 流式接口把构建后的 turn 请求交给主进程，主进程侧由流管理器的 dispatch 经派发准备阶段进入上下文提供者的 `prepareDispatch`，请求被暂停时走 blocked 分支（`useConversationTurnController.ts:59`、`context/dispatch.ts:73-115`、`PersistentChatContextProvider.ts:210-440`）。
- **模型解析**：`resolveModels` 接收 `mentionedModelIds` 与 `defaultModelId`，解析出模型数组，超过一个即视为多模型（`modelResolution.ts:15-25`、`PersistentChatContextProvider.ts:284-285`）。
- **兄弟组号**：多模型由 `resolvePersistentSiblingsGroupId` 分配新组号，regenerate 则继承或新分配组号；无 assistant 时回退到 `chat.default_model_id` 偏好（`modelResolution.ts:32-64`）。
- **AI SDK 交接**：`AiService.streamText` 要求调用方注入 `AbortSignal`，再构建 `Agent` 并调用其流式接口（`AiService.ts:502-623`）。
- **消息与 id 交接**：Agent 内部把 `initialMessages` 经 `toModelMessages` 转成模型消息，再交给 AI SDK 的 `aiAgent.stream`；`generateMessageId` 优先复用调用方提供的 messageId，使 UI 占位行与流内 id 一致（`Agent.ts:237-274`）。具体 HTTP payload 由 AI SDK 与 provider runtime 负责，本笔记未展开；不同 Agent runtime 的完整差异未运行验证（第 12 节）。

## 5. 流式事件、缓冲、节流与顺序

- **主进程写入侧**：N 个执行循环各自流式写各自的占位消息，经各自的持久化监听器与消息服务后端终态落盘（`PersistentChatContextProvider.ts:362-389`）；后端只在终态写入，失败时把占位行翻成 `error`（`persistence/backends/MessageServiceBackend.ts:30-48`）。流式期间中间增量落盘的频率本次未核实——执行侧未发现逐 chunk 节流落盘的证据，最终态落盘语义见第 6 节。
- **重连回放缓冲（ring buffer）**：每个 execution 一个环形缓冲，由 `onChunk` 写入，缓存最近未送达的 delta 供迟到监听器重放。设计要点：
  - 入队时把连续 delta 合并进尾部、超长 delta 先切分（`maxDeltaBytes=16_384` 为默认值），避免 delta 洪泛把自身 part 的开头 chunk 挤出、导致重放不可解析；
  - 环形淘汰在有挂起审批时暂停，因为审批的 tool-input chunk 在重连后仍须可操作；淘汰计数记在 `droppedChunks`；
  - `addListener` 对迟到监听器重放缓冲，`attach` 时用 `buildCompactReplay` 重建紧凑重放（`AiStreamManager.ts:146-1400`）。
- **渲染侧交接点**：IPC 的 `ai.stream.chunk/done/error` 事件经 `StreamDispatchService` 按 topic、execution 与 anchor 三个维度分流，再由 `MessageProjectionService` 组装 parts（桌面 Home 与 Agent 共用同一套投影），执行态 overlay 按动画帧合并提交。anchor 用于区分同一 execution 中的不同 turn；steer 或 continue 时 execution 可能切换 assistant row。这些细节属消息渲染器笔记（"流式消息链路"一节），本类目只记录交接契约。平滑播放（jitter buffer）在渲染侧，见消息渲染器笔记。
- **顺序保证**：terminal 事件（done/paused/error）在流式循环里按序发生，渲染侧"先刷新数据库、再清理 overlay"的交接由 `useTopicOverlayHandoffOnTerminal` 驱动（`useTopicStreamStatus.ts:99-117`），保证最终画面先可见再执行持久化交接。

## 6. 完成、异常、半截流与最终回写

- **终态收敛**：一条执行循环可能以三种方式结束：正常完成、暂停与异常，分别由 `onExecutionDone`、`onExecutionPaused`、`onExecutionError` 收口，三者都先收敛为终态，再由统一的终态生命周期处理终态广播与清理（`AiStreamManager.ts:998-1660`）。
- **abort 与空闲超时**：两条中断入口都作用在执行层的 controller 上：
  - 手动停止：`abort()` 同步把 status 置为 `aborted`，并 abort 各 execution 的 `AbortController`；
  - 空闲超时：空闲计时器到期后直接中止该执行持有的控制器，执行循环检测到中止后把执行状态提升为 `aborted` 并走暂停分支，因此截断的回复按 `paused` 落盘。
  聊天回合的空闲上限为 120 分钟，请求可单独覆盖该值（`AiStreamManager.ts:872-1563`）。
- **最终化交接**：渲染侧 `PersistenceListener.onDone/onPaused/onError` 之后，`MessageServiceBackend.persistAssistant` 调 `MessageService.finalizeAssistantMessage`，把终态 parts、status 与 stats 写回占位行（`MessageService.ts:1402-1432`）；渲染侧"流结束后页面先刷新数据库、再清理 overlay"的交接见 `useTopicStreamStatus.ts:99-117`（消息渲染器笔记"history 与 overlay 的交接"）。
- **错误路径**：Home 侧消息流错误走执行错误回调并广播到 topic；Agent 侧的兜底适配器在 agent 消息终态为 `error` 或 `success` 却没有可见 part 时，主动补一条 `data-error` part，防止 UI 卡在空白或转圈（`agentMessageListAdapter.tsx:48-73`，UI 侧兜底见 Chat UI 笔记 6.2）。
- **半截流的落盘形状**：停止或超时产生的半截 assistant 消息以 `status='paused'` 持久化（执行循环 `AiStreamManager.ts:1557-1563`；`finalizeAssistantMessage` 接受 `paused`，`MessageService.ts:1406`）。
- **审批等待中的打断**：审批等待中被中断时，`finalizeInterruptedParts` 在每个投影点把悬挂的工具 part 终态化为 `output-error`（`AiStreamManager.ts:1054-1060` 的注释）。

## 7. 停止、重试、续写与重新生成

- **停止**：用户点 ComposerSurface 的暂停/停止工具按钮触发停止（界面见 Chat UI 笔记 5），请求从渲染层一路接到网络层 abort：
  - 渲染层 `useChatWithHistory.stop` 发出 IPC `ai.stream.abort`（`useChatWithHistory.ts:67-74`、`ai.ts:179-181`）；
  - 主进程 `AiStreamManager.abort` 对各 execution 调 `AbortController.abort(reason)`；
  - 该 signal 已注入流式请求的 `requestOptions.signal`，由 AI SDK 侧中断请求（`AiStreamManager.ts:872-891`、`AiService.ts:507-510`）。
  停止在代码层面接到了网络 abort；实际取消效果未运行验证（第 12 节）。
- **重试/重新生成（用户动作）**：写操作的重新生成方法经写上下文注入真实实现（入口见 Chat UI 笔记 6.1、6.2）；请求 `trigger='regenerate-message'` 需要父锚点，live 期间会被拒；regenerate 继承源回复的模型与 turnOptions（`PersistentChatContextProvider.ts:283-300`、`useChatWriteActions.ts:304-344`）。起始上下文仍由锚点路径机制决定（第 2 节，数据语义见会话与消息管理笔记 4.2、4.3）。
- **Provider 层重试与 fallback**：这一层的重试发生在同一任务内部的单次请求上，用户手动"重新生成"则另起新消息分支。`AiService.streamText` 的 `createRetryableWrap` 先按 `maxAttempts` 重试同模型，再按用户顺序逐一尝试 fallback（`AiService.ts:565-590`、`runtime/aiSdk/retry/createRetryableWrap.ts:107-138`）。
- **续写（continue）与审批续跑**：`trigger='continue-conversation'` 复用原 assistant 行，不建新占位。主进程先把审批决定写回 parts 并把 status 置 `pending`，再用原模型续流；审批决定用单事务串行化（`PersistentChatContextProvider.ts:448-535`、`MessageService.ts:1474-1529`）。
  等待审批时流暂停，审批空闲上限 2 小时，同一回复的多工具审批可逐个连续推进（`AiStreamManager.ts:154-1533`）。审批通过后 reader 用数据库当前 anchor message 作为 seed，使新到的 tool output 合并到既有 tool input（渲染侧细节见消息渲染器笔记；审批界面工作流见 Chat UI 与 Agent 工具类目）。
- **编辑后发送**：编辑消息时保存旧草稿、取消时还原的界面状态机见 Chat UI 笔记 3.3；发送锚定（挂到哪个 parent）语义见会话与消息管理笔记 4.3、4.4。

## 8. 队列、多会话并发与后台生成

- **多模型并行**：`AiStreamManager.send()` 对每个模型调用 `createAndLaunchExecution`，**并行**启动 N 个独立的执行循环，各自流式写各自的占位消息（`AiStreamManager.ts:544-1468`）；共享同一 `siblingsGroupId` 只用于读侧把占位行分到同一兄弟组展示（分桶见会话与消息管理笔记 4.2）。
- **队列**：
  - **steer 队列（主进程）**：流式期间的后续发送先落一条用户行并入队，运行中的 turn 在步骤边界检查到有等待处理的 steer 后让出。干净收尾时调度一次 steer 续答；`awaiting-approval` 状态不立即续答（审批续跑后顺带消费），aborted 或 error 后丢弃队列（`AiStreamManager.ts:764-1212`）。
  - **follow-up 队列（渲染层）**：`ChatComposer` 用 `useFollowupQueue` 管这一队列，topic 空闲时自动 drain 到 `sendQueuedPayload`（`ChatComposer.tsx:1401-1414`）。
  - **并发与再次发送**：`dispatchLock` 只序列化"准备 + 启动"窗口，不序列化运行本身；运行期再次发送按触发时机落到 steer、排队或拒绝预留分支三条路之一。同一会话是否完全串行、不同会话是否并行、再次发送是排队还是报错，本次未逐一验证（第 12 节）。
- **后台生成**：渲染侧组件卸载时 `useExecutionOverlay` 释放视图，但保留 reader 且不 abort（transport 的 detach 只移除监听器），主进程可继续生成并持久化（`useExecutionOverlay.ts:66-69` 注释）。
- **grace-period 驱逐**：`AiStreamManager` 有 grace-period 驱逐，默认 30 秒（`AiStreamManager.ts:147-289`、`lifecycle/ChatStreamLifecycle.ts:55-56`）。
- **后台模式**：`backgroundMode` 默认 `'continue'`，配置为 `'abort'` 时才在监听器归零时中止（`AiStreamManager.ts:148-994`）；切换会话或离开页面后任务如何收口本次未验证。

## 9. Agent、工具、知识库与附件注入点

- **模型解析**：见第 4 节（`resolveModels`、`resolvePersistentSiblingsGroupId`）。
- **知识库**：渲染层把知识库范围编码成用户消息 parts 里的 `data-knowledge-scope` 专用 part，主进程再从 parts 读回、填入请求的 `knowledgeBaseIds` 字段（`ChatComposer.tsx:1344`、`uiParts.ts:348-388`、`PersistentChatContextProvider.ts:400`）。
- **附件**：附件在渲染层发送队列载荷时转成 file part 拼进用户消息 parts；主进程在流式入口按模型的原生文件支持路由附件（`ChatComposer.tsx:1359-1383`、`AiService.ts:556-561`）。
- **联网搜索**：联网搜索由 `assistant.settings.enableWebSearch` 布尔开关控制，经 `capabilityBody` 随 regenerate 等请求携带，实际搜索执行在 AI SDK 工具侧（`useChatWriteActions.ts:296-301`）。
- **推理强度**：`reasoningEffort` 是独立请求字段，从渲染层 turn 选项里的同名值起算，经请求构建与 IPC 流式接口原样带到主进程的流式请求（`useChatRuntimeState.ts:44-305`、`PersistentChatContextProvider.ts:286-289`）。
- **工具**：`ComposerToolRuntimeHost` 与各 `defineTool`（`src/renderer/components/composer/tools/definitions/*.tsx`）在渲染期决定是否显示工具；某个工具是否实际带上由主进程侧按模型能力判定。四类输入的组织方式各不相同：文件和知识库走消息 parts，联网是 assistant 设置，推理是独立请求字段，工具走能力判定。
- 工具执行循环的内部语义（发现、协议、执行、审批）属 Agent 工具类目，本笔记只记录注入点与交接契约。

## 10. 当前上下文预算与运行时补充

上下文设置支持按最近 N 条消息取窗、按 token 阈值截断，以及按窗口百分比触发压缩；压缩模型可以跟随当前模型或单独指定。附件预算与路由先评估输入空间，并可在预算允许时读取完整附件；`fs_read` 同时受到显式门控，避免因附件扩展而无条件暴露文件读取。AI SDK 的工具循环还在单次请求内部执行增量压缩，避免长工具回合只依赖发送前压缩。相关入口见 `src/main/ai/contextBuild/resolveContextSettings.ts`、`src/main/ai/runtime/aiSdk/params/features/inLoopCompaction.ts:179-192`。

这些结论来自预算、请求参数和运行时构造代码；不同 Provider 对大附件、压缩和上下文上限的实际接受行为未运行验证。依据：`src/main/ai/contextBuild/resolveContextSettings.ts`、`src/main/ai/messages/attachmentBudget.ts`、`src/main/ai/messages/maxMessagesWindow.ts`、`src/main/ai/runtime/pi/modelInjection.ts`、`src/main/ai/runtime/piDurable/`（Pi 与 Pi-Durable 的模型注入都经由内部 gateway 绑定，DSH 运行时已移除）。

## 11. 退出恢复、日志与已确认边界

- **启动/崩溃恢复**：启动时 boot reconcile 把遗留的 `pending` 记录翻成 `error`（第 1 节）；`onStop` 在退出时 abort 所有 live 流，并等待执行循环落盘完成（`AiStreamManager.ts:497-534`）。
- **备份恢复**：`pause()` 与 `drainInFlight()` 构成写安静期，期间 dispatch 门禁返回 `blocked`（`AiStreamManager.ts:321-442`）。
- **可观测性**：每个模型的 turn 有独立的 `ai.turn` trace span，构建好的请求由 `applyTurnInputAttributes` 写入 span 属性（`startTurnRootSpans`，`PersistentChatContextProvider.ts:120-425`）。
- **trace 与用量**：容器级 trace id 存 topic 行（`TopicService.ensureTraceId`，`:157-177`）；用量经 `createAiUsagePlugin` 捕获（`AiService.ts:539-552`）。AI 错误以 `data-error` part 持久化（渲染侧展示见消息渲染器笔记）。日志、用量与具体任务的多窗口关联方式本次未展开。
- **已确认边界（取舍）**：`AiStreamManager` 的中心化状态机在代码注释中记录了正确性顾虑（第 1 节）；ring buffer 与 approval 暂停淘汰是"可重放性优先于吞吐"的取舍。
- **类目边界**：停止生成的半截消息最终如何保存（数据语义）见会话与消息管理；停止按钮状态、排队提示、重试入口等用户工作流见 Chat UI；流式事件到 DOM 的消费见消息渲染器。

## 12. 未验证事项

- 流式中断/停止的网络级取消效果、压缩触发阈值、不同 Agent runtime 的完整差异、provider 最终 HTTP payload 字段未运行验证。
- 同会话串行/并发运行行为、steer 队列与 follow-up 队列的运行语义、后台生成收口、退出中途任务处理未验证。
- 流式期间中间增量落盘的频率未核实（第 5 节）；审批空闲 2 小时上限、grace-period 驱逐的实际触发未运行验证。
- 工具执行循环内部细节属 Agent 工具类目，本笔记未覆盖。

## 13. 关键源码索引

- `src/renderer/pages/home/ChatContent.tsx`、`useChatRuntimeState.ts`（提交入口与 `buildStreamRequest`）
- `src/renderer/hooks/useConversationTurnController.ts`（IPC `ai.stream.open` 与阶段机）
- `src/renderer/components/composer/variants/ChatComposer.tsx`、`shared/composerQueuedPayload.ts`（`buildQueuedPayload`/`sendQueuedPayload`）
- `src/renderer/hooks/chat/ChatWriteContext.ts`、`src/renderer/pages/home/hooks/useChatWriteActions.ts`（写操作与能力注入）
- `src/main/ipc/handlers/ai.ts`（`ai.stream.open/abort/attach/detach`）
- `src/main/ai/streamManager/AiStreamManager.ts`（状态机、`dispatch`/`send`/`runExecutionLoop`/ring buffer/abort）
- `src/main/ai/streamManager/context/{PersistentChatContextProvider,dispatch,modelResolution}.ts`
- `src/main/ai/messages/messageRules.ts`（`toModelMessages` 整形管线）
- `src/main/ai/AiService.ts`、`src/main/ai/runtime/aiSdk/retry/`（streamText、retry wrap、fallback 过滤）
- `src/main/ai/runtime/aiSdk/Agent.ts`（`initialMessages` 转换与 SDK 交接）\n- `src/renderer/services/aiTransport/{StreamDispatchService,MessageProjectionService,ExecutionStreamOverlayService}.ts`（桌面共享的流事件分发与消息投影）
- `src/main/data/services/MessageService.ts`（`getPathToNode`、`createUserMessageWithPlaceholders`、`finalizeAssistantMessage`，数据语义见会话与消息管理）
