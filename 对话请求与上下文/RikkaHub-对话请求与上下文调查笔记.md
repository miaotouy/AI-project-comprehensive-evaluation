# RikkaHub 对话请求与上下文调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：以当前快照源码复核为主，沿 `ChatService` → `GenerationLoop` → Provider 解码器的可执行路径逐段阅读；文档 `docs/references/chat-generation-pipeline.md` 仅作对照，凡与实现不一致处以源码为准。未运行应用，取消效果、并发竞态与端到端行为属未验证项。
>
> 调查范围：覆盖一次用户输入从提交、上下文拼装与裁剪、模型调用（流式/非流式）、流式 chunk 合并、Step 循环与多轮工具、取消与中断、token 用量与最终回写的主链。会话/消息的持久化 schema、UI 交互、Agent 工具与知识库内部机制、渠道管理与协议细节只记录与本链的交接点，不展开。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 生成任务由 `ChatService` 统一编排，每个会话对应一个内存中的 `ConversationSession`，会话状态与生成 Job 都收敛在该对象内；发送输入先进入内存消息队列，再由队列调度器串行取出执行，同一会话不并行，不同会话各自独立。
- 上下文在 `GenerationLoop.generateInternal()` 内一次性拼装：先构造一条合成 system 消息（助手系统提示 + 记忆 + 各工具的系统提示），再拼接经 `limitContext()` 裁剪的历史消息，最后依次穿过输入变换管道。变换器成员的构成与执行规则见[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。
- `limitContext()` 是“滞回/阶梯式”截断而非逐条滑动窗口：截断点只在消息条数越过阈值时前进一大步，保留条数始终落在 `[limit*0.5, limit)`，并向前对齐以避免把工具调用与其结果拆散。
- Provider 层是无状态接口，`ProviderManager` 按 ProviderSetting 类型路由（OpenAI 兼容、Google、Claude）；调用 `streamText` 还是 `generateText` 由助手配置 `streamOutput` 决定；两套线协议的请求组装与解码细节见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。
- 流式链为：Provider 解码 SSE → 通用 `StreamChunk` 事件 → `StreamChunkHandler` 合并进末尾助手消息 → `GenerationChunk.Messages` → `ChatService` 写回会话内存状态；数据库落盘发生在生成成功之后，不在每个 chunk。
- Step 循环默认上限 256 步，工具结果内联写回助手消息的 parts（不创建 TOOL 角色消息）；审批未决时循环中断等待用户。工具契约、注册顺序与审批状态机见 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。
- 网络型 `IOException` 自动重试最多 3 次、指数退避；用户取消通过协程取消传播，并在重试判定前用 `ensureActive()` 防止把取消误判为网络波动而重放请求。

## 系统边界与生成任务主链

本类目的系统边界是“执行编排层”：RikkaHub 自己持有会话状态与生成循环，`ai` 模块只做协议适配，本身不持有会话。`Provider` 接口被显式设计为无状态——每次调用除消息与参数外还要传入 provider setting（`ai/src/main/java/me/rerere/ai/provider/Provider.kt:17-56`）。因此“上游会话状态”全部归 `app` 模块的 `ChatService` / `ConversationSession` 所有。

一条完整主链（从 UI 提交到最终回写）：

1. `ChatVM.handleMessageSend()` 调用 `ChatService.sendMessage()`（`ui/pages/chat/ChatVM.kt:207-212`）。
2. `sendMessage()` 把内容封装为队列项并入队，然后触发队列调度（`service/ChatService.kt:405-413`）。
3. `dispatchNextQueuedMessage()` 在当前会话空闲时取出下一项，交给 `sendQueuedMessage()`（`service/ChatService.kt:434-445`）。
4. `sendQueuedMessage()` 预处理用户文本、追加 USER 消息节点、落库，再进入 `handleMessageComplete()`（`service/ChatService.kt:447-508`）。
5. `handleMessageComplete()` 解析助手与模型、构建工具集，调用 `GenerationLoop.generateText()` 并把返回的 `Flow<GenerationChunk>` 收集进会话状态（`service/ChatService.kt:658-805`）。
6. `GenerationLoop.generateText()` 运行 Step 循环，在每一步调用 `generateInternal()` 完成上下文拼装与 Provider 调用（`data/ai/GenerationLoop.kt:74-325`）。
7. Provider 返回 `Flow<StreamChunk>` 或一次性 `TextGenerationResult`，由 `StreamChunkHandler` 合并为 `UIMessage`（`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:69-303`）。

文档差异：`docs/references/chat-generation-pipeline.md` 把核心生成类记作 `GenerationHandler.kt`，但当前快照中该类已改名为 `GenerationLoop`，文件是 `data/ai/GenerationLoop.kt`，且日志 TAG 仍保留旧名 `"GenerationHandler"`（`data/ai/GenerationLoop.kt:54,69`）。

## 1. 提交入口、任务对象与状态机

**入口与任务对象**：没有独立的“任务 ID”实体。会话状态由 `ConversationSession` 承载，本链只用到其中三样任务态：权威会话内存态、生成状态提示、以及当前生成 Job（`state` / `processingStatus` / `_generationJob`；`isGenerating` 即末者是否活跃）。会话对象由 `ChatService.getOrCreateSession()` 惰性创建，初始值只是一条带 id 与助手 id 的占位 `Conversation.ofId(...)`，真正的历史由 `initializeConversation()` 从仓库载入（`service/ChatService.kt:211-237,330-347`）；消息节点、分支与占位会话的数据语义归[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

`ChatService` 与 `GenerationLoop` 都是 Koin 单例（`di/AppModule.kt:93`，`di/DataSourceModule.kt:104-110`），会话表是 `ConcurrentHashMap<Uuid, ConversationSession>`，用 `_sessionsVersion` 计数支持会话集合变化的观察。

**发送即入队**：`sendMessage()` 先判空，再在 `synchronized(session)` 内把输入封装成 `QueuedMessage` 入队，并立即调用调度器（`service/ChatService.kt:405-413`）。队列语义在 `MessageQueue` 中：`takeNext()` 跳过处于编辑占位的项且被暂停时返回空，`pause()` 会把所有等待中的回复以异常结束（`service/MessageQueue.kt:44-117`）。因此“再次发送”在当前快照中不是 steer 或替换，而是排队等待本轮结束。

**任务状态初始化**：`launchGenerationJob()` 用 `CoroutineStart.LAZY` 启动，`keepAliveInBackground` 为真时先申请前台服务保活，任务体结束后释放（`service/ChatService.kt:304-326`）；前台服务的通知与超时语义归[主动 Agent 与后台任务笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)。Job 通过 `session.setJob()` 注入会话；Job 完成回调里比较并清空 `_generationJob`，随后触发 `onGenerationFinished` 回调——回调会暂停队列、把有未决审批工具的语音等待者置错，并驱动队尾消息调度（`service/ConversationSession.kt:85-104`，`service/ChatService.kt:222-231`）。

**错误状态**：错误集中记录在 `ChatService._errors`（`StateFlow<List<ChatError>>`），`CancellationException` 被 `addError()` 直接忽略，不进入错误列表（`service/ChatService.kt:180-190`）。

## 2. 历史选择与上下文拼装顺序

每次模型调用前，`generateInternal()` 用 `buildList` 组装本次请求的 `internalMessages`，顺序固定（`data/ai/GenerationLoop.kt:346-383`）：

1. **合成 system 消息**（仅当内容非空时加入），文本按“生效系统提示 → 可选记忆清单 → 每个工具的系统提示”顺序拼接；生效系统提示在会话级自定义提示非空且 `allowConversationSystemPrompt` 为真时取会话级，否则取助手 `systemPrompt`。该消息以 `isSynthetic = true` 标记。
2. **裁剪后的历史**：`messages.limitContext(assistant.contextMessageLimit)`，即不含 system 的当前分支消息列表。

随后整段消息列表穿过输入变换管道。管道在 `ChatService` 侧按固定顺序拼成（时间提醒、提示注入、占位符、文档转提示、OCR，再追加模板渲染与会话级工作区提醒），以 `fold` 顺序应用，后者能看到前者的结果（`service/ChatService.kt:134-142,741-745`，`data/ai/transformers/Transformer.kt:64-88`）。各变换器的成员、触发条件、注入位置与优先级、占位符与模板渲染规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)；本链只关心这条管道是 Provider 调用前的最后一道拼装步骤。

**请求参数**：`TextGenerationParams` 由助手与模型配置合成——温度、topP、maxTokens、reasoningLevel 取自助手，`tools` 取自本次工具集，自定义 header/body 把助手级与模型级拼接，`sessionId` 使用会话 id（`data/ai/GenerationLoop.kt:386-402`）。该 sessionId 会经 `configureSessionHeaders()` 进入请求头，是“同一会话稳定标识”的落点，也是与渠道笔记的交接面。

## 3. 预算、截断、摘要与压缩

**截断是条数口径，不是 token 口径**。`limitContext(limit)` 只依据消息条数：`limit <= 0` 或未超限时原样返回；超限时计算回落目标 `target = limit * 0.5`（四舍五入并夹取到 `[1, limit]`），步幅 `stride = limit - target`，截断起点 `startIndex = ((size - limit) / stride + 1) * stride`（上限兜底到 `size - 1`）。因此截断点在一段连续轮次内保持不动，请求前缀稳定，利于命中提示词缓存（`ai/src/main/java/me/rerere/ai/ui/Message.kt:131-162`）。

**对齐避免拆散工具对**。`alignContextStart()` 在截断点落在含工具的消息上时向前回退：若当前消息含已执行工具（有 output），向前找同一调用链中未执行的工具调用；若含未执行工具调用，向前找对应的 USER 消息。回退只减不增，故不破坏保留下界（`ai/src/main/java/me/rerere/ai/ui/Message.kt:164-210`）。

**压缩是手动、非自动**。压缩入口是聊天页对话框经 `ChatVM.handleCompressContext()` 调到 `ChatService.compressConversation()`，没有基于 token 预算的自动触发。其做法是：按 `keepRecentMessages`（默认 32）把消息切分为“待压缩/保留”两段，对过长部分递归二分到每块不超过 256 条，再并发地对每块调用压缩模型（`compressModelId`，缺失时回退当前对话模型）生成摘要，最后用摘要 USER 消息加保留消息替换整段历史并落库（`service/ChatService.kt:993-1075`）。压缩结果不可逆，原始历史不会保留在会话快照中。

`contextMessageLimit` 是助手级配置（`data/model/Assistant.kt:27`），界面上 0 表示不限制（`ui/pages/assistant/detail/AssistantBasicPage.kt:442`）。

## 4. SDK、Provider、模型与协议交接

**模型与渠道解析**：`handleMessageComplete()` 以 `assistant.chatModelId ?: settings.chatModelId` 查模型，查不到直接抛“未选择对话模型”；渠道由 `model.findProvider(settings.providers)` 解析，该函数支持模型级 `providerOverwrite` 覆盖；实现实例由 `ProviderManager.getProviderByType()` 按 `ProviderSetting` 子类型取得（`service/ChatService.kt:664-667`，`data/datastore/PreferencesStore.kt:666-728`，`ai/src/main/java/me/rerere/ai/provider/ProviderManager.kt:16-56`）。

ProviderManager 在初始化时注册三个渠道实现：OpenAI 兼容、Google、Claude。**协议交接点**就是 `Provider` 接口的两个方法：`streamText` 返回 `Flow<StreamChunk>`，`generateText` 返回 `TextGenerationResult`（含 message、finishReason、usage）；是否流式由 `generateInternal(stream = assistant.streamOutput)` 决定（`data/ai/GenerationLoop.kt:138,404-469`）。协议内部的分支不改变这个交接面——OpenAI 兼容渠道再按 `useResponseApi` 二分到 Chat Completions 与 Responses 两套线协议，Claude 渠道把首条 SYSTEM 提取为顶层字段并实现 `pause_turn` 续跑，这些字段映射、方言适配与续跑细节见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

## 5. 流式事件、缓冲、节流与顺序

**传输与缓冲**：Provider 侧用 `callbackFlow` 承载 SSE 事件，流以 `Channel.UNLIMITED` 缓冲并 `flowOn(Dispatchers.IO)`；`trySend` 失败只记日志，代码注释明确指出缓冲必须有界性反转的原因——曾有缓冲满静默丢 delta 导致回复中间缺字（`.../openai/ChatCompletionsAPI.kt:222-223`，`.../claude/ClaudeProvider.kt:428-429`）。这是全链唯一的显式缓冲策略，管道本身不做节流或合并窗口，每个 chunk 都向下游转发。SSE 事件源与各协议的逐字段解码见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

**通用事件模型**：`StreamChunk` 是与协议无关的密封类，覆盖文本、推理、工具调用、服务端工具、图片、注解、用量与 Finish，并普遍采用 Start/Delta/End 三元组（`ai/src/main/java/me/rerere/ai/ui/StreamChunk.kt:16-156`）。各协议实现 `StreamChunkDecoder`（`accept`/`onClosed`），且要求 Finish 幂等、每条流独立实例（`ai/src/main/java/me/rerere/ai/provider/stream/StreamChunkDecoder.kt:9-21`）。

**合并层**：`StreamChunkHandler` 保存每个事件 id 在 parts 中的下标，把增量并入末尾助手消息；容忍 Provider 未发 Start 时由首个 Delta 直接建 part；工具调用按 `toolCallId` 而非 part 位置定位（支持并行）；`Finish` 时设置 `finishedAt`、结束未关闭的推理 part 并清空索引（`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:57-303`）。它是有状态对象，“每条流独立实例、不复用”被写在类注释中。

**重试与合并的交互**：流式分支每轮尝试都新建 `StreamChunkHandler`，并以“本次调用开始前的消息快照”为基线重新合并，避免把重试响应追加到已展示的半截回复之后；为此会预先建好一条复用同一 id 的空助手消息，使 `ChatService` 覆盖当前分支而不是新建候选（`data/ai/GenerationLoop.kt:404-455`）。下游消息转换或 UI 更新抛错会被包成 `StreamChunkHandlingException` 并直接上抛，不触发网络重放。

**非流式分支**：用 `executeProviderRequestWithRetry()` 包一次 `generateText()`，结果经 `handleTextGenerationResult()` 合并——末条角色相同则并入（文本/推理/工具按语义合并，图片作为独立完整项追加），不同则新增一条（`data/ai/GenerationLoop.kt:456-469`，`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:323-452`）。

**图像与推理的特殊合并**：`ImageSnapshot` 用完整快照替换同 id 图片数据，与追加型 `ImageDelta` 区分；把不含 reasoning part 的回复里的 `<think>...</think>` 提取为推理 part 由 `ThinkTagTransformer` 完成，其规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)（`ai/.../StreamChunkHandler.kt:249-290`）。

## 6. 完成、异常、半截流与最终回写

**单步收尾**：`generateInternal()` 返回后，`generateText()` 对消息做视觉变换与 `onGenerationFinish()`，再给末条消息打上 `finishedAt` 并 emit；随后检查末条消息中未执行的工具调用，无则 break（`data/ai/GenerationLoop.kt:146-170`）。

**输出变换的三个时机**（`data/ai/transformers/Transformer.kt:38-122`）：模型每次更新消息时，先跑所有输出变换的 `transform()`，再以 `visualTransforms()` 的结果 emit——`ChatService` 正是把这份 emit 结果写回会话，因此视觉变换会体现在被存储的消息上；`onGenerationFinish()` 在模块调用结束后执行一次，做未结束推理片的收口与图片物化等收尾；`RegexOutputTransformer` 只实现视觉变换。各变换器的成员与内部规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)，图片物化落盘与序列化约束归[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。注意 `visualOnly == true` 的正则在生成管道中被过滤掉，只在消息渲染层以 `visual = true` 调用时生效（`data/model/Assistant.kt:99-123`，`ui/components/message/ChatMessage.kt:379-408`）。

**流结束后的回写**：`ChatService` 收集 `GenerationChunk.Messages` 时只更新会话内存态（`updateConversation` → `session.state`），不逐 chunk 落库。真正的落库与派生任务在 `onSuccess` 分支：先 `saveConversation()`，再把标题与建议生成作为带引用计数的后台任务启动（`service/ChatService.kt:767-804`）。`onCompletion` 分支（无论正常结束或被取消）只做内存态的 `finishReasoning` 兜底并发出 `ChatGenerationEnded` 事件；`onFailure` 分支暂停队列并 `addError`，本路径不调用 `saveConversation`（`service/ChatService.kt:748-793`）。

由此有一个可确认的行为：**中途停止或异常时，半截助手回复只存在于会话内存态，不由该路径落库**；它会在下一次成功发送（`sendQueuedMessage()` 的 `saveConversation`）或其他显式保存时随整段会话写入，持久化语义归[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。文档 `chat-generation-pipeline.md` 的流程图把 `saveConversation()` 画在 `onCompletion` 下，与实现中其位于 `onSuccess` 不一致。

**用量统计**：`TokenUsage` 含 prompt/completion/cached/total，合并规则是“非零值优先覆盖”（`ai/src/main/java/me/rerere/ai/core/Usage.kt:6-36`）。流式下 `StreamChunk.Usage` 逐次并入助手消息的 `usage`；非流式下 `handleTextGenerationResult()` 把结果用量并入消息。用量随消息一起在落库时持久化；Claude 的缓存读取单列为 cachedTokens，其字段合成规则见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)（`.../claude/ClaudeStreamDecoder.kt:176-191`）。

## 7. 停止、重试、续写与重新生成

**停止**：`stopGeneration()` 先暂停消息队列（把所有等待中的回复置错），再取消会话所有活跃 Job（`cancelJobs()` 逆序取消），逐个 `join()` 等待收尾，最后调用 `finishInterruptedPendingTools()` 把未执行工具以取消错误补全（`service/ChatService.kt:1417-1427`，`service/ConversationSession.kt:108-112`）。`finishInterruptedPendingTools()` 仅在确实有未执行工具时才保存会话（`service/ChatService.kt:857-884`）。取消会沿协程传播到 Provider 的 `callbackFlow`，其 `awaitClose` 调用 `eventSource.cancel()`；本次调查未运行验证底层 OkHttp 连接是否同步中断。

**网络重试**：`awaitNetworkRetryOrThrow()` 只对 `IOException` 重试，最多 3 次，延迟从 1s 起按位移递增；判定前先 `currentCoroutineContext().ensureActive()`，代码注释明确这是为了避免把用户取消导致的 `IOException("canceled")` 当成网络抖动重放（`data/ai/GenerationLoop.kt:57-58,495-524`）。重试期间 `processingStatus` 会显示带错误分类的提示文案。渠道侧的多 Key 与故障转移策略见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

**重新生成**：`regenerateAtMessage()` 区分角色——对 USER 消息，把消息节点截断到该条并保存后重新补全；对 ASSISTANT 消息，`regenerateAssistantMsg` 为真时以 `messageRange = 0..<nodeIndex` 让补全基于该条之前的上下文重跑，为假时仅保存（`service/ChatService.kt:530-574`）。它复用同一个 Job 槽位并先 `join` 上一个 Job。

**工具审批后的续跑**：`handleToolApproval()` 更新目标工具为 Approved/Denied/Answered 并落库，只有在没有其他未决工具时才再次调用 `handleMessageComplete()`；其 Job 以 `cancelPrevious = false` 设置，以便与前序任务串行而非覆盖（`service/ChatService.kt:578-654`，`service/ConversationSession.kt:138-148`）；审批状态机本身归 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

## 8. 队列、多会话并发与后台生成

同一会话串行：`dispatchNextQueuedMessage()` 在存在活跃 Job 或未决审批工具时直接返回，且整个调度在 `synchronized(session)` 内完成；不同会话各自持有 Job，跑在同一个 `appScope` 上，彼此并行（`service/ChatService.kt:434-445`）。再次发送的行为是入队，等本轮或审批结束后由 `onGenerationFinished`、`saveConversation`、队列增删等多个触发点驱动下一步。

后台生成由 `ChatGenerationForegroundService` 保活，但生成仍归 `ChatService`；`keepAliveInBackground` 决定是否申请前台服务，服务超时时反查仍在进行的会话并停止生成。前台服务生命周期、通知与超时细节归[主动 Agent 与后台任务笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)，本链只在 `launchGenerationJob()` 处做申请与释放（`service/ChatService.kt:304-326`）。

语音输入有独立通道：`enqueueVoiceMessage()` 返回一个 `CompletableDeferred<String?>`，在入队前校验队列未暂停且无未决工具，结果在生成结束后回填；队列暂停或存在未决工具时，等待者被置错（`service/ChatService.kt:415-432,108-112`）。

## 9. Agent、工具、知识库与附件注入点

本链在 `handleMessageComplete()` 处构建一次工具目录，其余内部机制不在本类目展开。目录由 `ChatToolFactory.createTools()` 按固定顺序累积，调用点见（`service/ChatService.kt:658-805`）；注册顺序、过滤条件与工具来源归 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

工具以三类信息进入请求：schema 进 `TextGenerationParams.tools`，`systemPrompt` 被拼进合成 system 消息，`needsApproval` 决定是否进入审批状态机；执行结果内联写回助手消息的 parts，因此与助手回复一同 `saveConversation` 持久化，而不产生 TOOL 角色消息。工具输出超过 32KB 且工具集含 `workspace_shell` 时，仅保留前 4KB 预览、全文另存并在消息中附读取提示（`data/ai/GenerationLoop.kt:55-56,536-568`）；工具契约、参数校验与结果限制细节归 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

附件方面，文档附件在变换管道中解析为文本注入消息，模型不支持图像输入时图片经 OCR 转文本；上传文件位于 `filesDir/upload`，被映射为工作区内的 `/upload` 只读路径。附件与占位符的注入规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)，工作区侧的路径与执行边界归[外部执行体与应用协作笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)。

## 10. 退出恢复、日志与已确认边界

**会话生命周期**：`ConversationSession` 用原子引用计数管理内存驻留，UI 打开/关闭经 `acquire()`/`release()` 调整；引用归零后安排 5 秒空闲检查，若期间仍无引用且未在生成则回调 `removeSession()` 清理（`service/ConversationSession.kt:19,55-63,114-127`）。`isInUse` 综合引用数、活跃 Job 与队列非空三者判断；`cleanup()` 清空 Job 并取消任务。

**可观测性**：错误集中于 `ChatService.errors`；生成状态经 `processingStatus` 暴露给 UI；生成开始/更新/结束通过 `AppEventBus` 发出，供通知管理消费（`tryEmit` 不挂起，事件丢失只影响单次通知更新，不反压生成链）。请求级日志由 Provider 打印请求体与流事件，`RequestLoggingInterceptor` 另有实现位置。

**已确认边界**：
- 截断只按消息条数，不做 token 估算；`limitContext` 不影响 system 消息与工具 schema。
- 压缩是手动触发，且替换式不可逆。
- 生成成功才走 `saveConversation`，停止/异常路径的半截回复不在该点落库。
- 工具结果内联在 ASSISTANT 消息 parts 中，不产生 TOOL 角色消息。
- 同一会话严格串行，无 steer/替换当前生成的能力，再次发送即排队。

## 11. 未验证事项

- 用户点击停止后，`eventSource.cancel()` 是否即时中断底层网络请求，未运行验证。
- UI 层对高频 chunk 的渲染节流/重组频率未在本次范围内核查（管道本身无节流）。
- Google 渠道与 Responses API 两条协议分支的逐字段映射未逐一复核，仅确认入口与解码器存在。
- 压缩后实际 token 占用与模型上下文预算的关系、以及并发压缩块在超大历史下的行为未运行验证。
- `visualOnly == true` 正则在渲染层的端到端效果未运行验证。
- 中断/异常导致半截回复不落库时，跨进程重启后的可见性未运行验证（据源码推断下次成功发送会随整段会话写入）。

## 12. 关键源码索引

- 编排入口与状态：`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt:405-508,658-805`；会话状态：`service/ConversationSession.kt:21-148`；队列：`service/MessageQueue.kt:40-118`
- 生成循环与上下文拼装：`app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt:74-325,327-473`
- 上下文裁剪与消息模型：`ai/src/main/java/me/rerere/ai/ui/Message.kt:131-210`
- 流式合并：`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:57-303,323-452`；事件模型：`ai/.../ui/StreamChunk.kt:16-156`
- Provider 路由与协议：`ai/src/main/java/me/rerere/ai/provider/ProviderManager.kt:16-56`
- 对照文档（存在与实现不一致处）：`rikkahub/docs/references/chat-generation-pipeline.md`
