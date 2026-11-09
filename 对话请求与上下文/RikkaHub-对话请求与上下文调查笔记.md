# RikkaHub 对话请求与上下文调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：以当前快照源码复核为主，沿 `ChatService` → `ChatRequestFactory` → `ai/agent/AgentLoop` → Provider 解码器的可执行路径逐段阅读；文档 `docs/references/chat-generation-pipeline.md` 仅作对照，凡与实现不一致处以源码为准。未运行应用，取消效果、并发竞态与端到端行为属未验证项。
>
> 调查范围：覆盖一次用户输入从提交、上下文拼装与裁剪、模型调用（流式/非流式）、流式 chunk 合并、Step 循环与多轮工具、取消与中断、token 用量与最终回写的主链。会话/消息的持久化 schema、UI 交互、Agent 工具与知识库内部机制、渠道管理与协议细节只记录与本链的交接点，不展开。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 生成任务由 `ChatService` 统一编排，每个会话对应一个内存中的 `ConversationSession`，会话状态、生成 Job 与消息队列都收敛在该对象内；发送输入先进入内存消息队列，再由队列调度器串行取出执行，同一会话不并行，不同会话各自独立。
- 通用的 Agent 循环已下沉到 `ai` 模块：`ai/agent/AgentLoop` 负责 Step 循环、工具执行与审批等待，通过 `AgentHooks` 回调把“怎么组装请求”交还应用层；应用侧 `ChatRequestFactory` 实现这些回调，负责系统提示、上下文裁剪、输入/输出变换与 `sessionId`。
- 上下文在 `ChatRequestFactory.buildStep()` 内一次性拼装：先构造一条合成 system 消息（助手系统提示 + 记忆 + 各工具的系统提示），再拼接经 `limitContext()` 裁剪的历史消息，最后依次穿过输入变换管道。变换器成员的构成与执行规则见[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。
- `limitContext()` 是“滞回/阶梯式”截断而非逐条滑动窗口：截断点只在消息条数越过阈值时前进一大步，保留条数始终落在 `[limit*0.5, limit)`，并向前对齐以避免把工具调用与其结果拆散。
- Provider 层是无状态接口，`ProviderManager` 按 ProviderSetting 类型路由（OpenAI 兼容、Google、Claude）；调用 `streamText` 还是 `generateText` 由助手配置 `streamOutput` 决定；两套线协议的请求组装与解码细节见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。
- 流式链为：Provider 解码 SSE → 通用 `StreamChunk` 事件 → `StreamChunkHandler` 合并进末尾助手消息 → `AgentEvent.MessageUpdated` → `ChatService` 写回会话内存状态；数据库落盘发生在整轮结束（含取消与异常兜底）而非每个 chunk。
- Step 循环默认上限 256 步，工具结果内联写回助手消息的 parts（不创建 TOOL 角色消息）；审批未决时循环以 `AwaitingApproval` 结束、等待用户。工具契约、注册顺序与审批状态机见 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。
- 网络型 `IOException` 重试由 `RetryPolicy` 描述，默认最多 3 次、1s 起指数退避，受设置项 `enableAutoRetry` 开关；用户取消通过协程取消传播，并在重试判定前用 `ensureActive()` 防止把取消误判为网络波动而重放请求。

## 系统边界与生成任务主链

本类目的系统边界是“执行编排层”：RikkaHub 自己持有会话状态与生成任务，`ai` 模块只做协议适配与通用 Agent 循环，本身不持有会话。`Provider` 接口被显式设计为无状态——每次调用除消息与参数外还要传入 provider setting（`ai/src/main/java/me/rerere/ai/provider/Provider.kt`）。因此“上游会话状态”全部归 `app` 模块的 `ChatService` / `ConversationSession` 所有。

一条完整主链（从 UI 提交到最终回写）：

1. `ChatVM.handleMessageSend()` 调用 `ChatService.sendMessage()`（`app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatVM.kt`）。
2. `sendMessage()` 把内容封装为队列项并入队，然后触发队列调度（`service/ChatService.kt`）。
3. `dispatchNextQueuedMessage()` 在当前会话空闲时取出下一项，`sendQueuedMessage()` 预处理用户文本、追加 USER 消息节点并落库。
4. 生成任务经 `launchGenerationJob()` 启动，任务体调用 `runTurn()`：先 `requestFactory.createContext()` 解析助手、模型、渠道、记忆与工具，再 `createAgent()` 得到 `AgentRequest` + `AgentHooks`。
5. `runAgent(request, hooks)` 返回 `Flow<AgentEvent>`，`ChatService` 在 IO 线程收集：`MessageUpdated` 写回会话内存状态并发出通知事件，`Retrying` 更新处理状态，`Finished` 记录结束原因（`service/ChatService.kt` 的 `runTurn`）。
6. `AgentLoop` 在每一步调用 `hooks.prepareStep()` 取得实际请求与参数（上下文拼装、裁剪、输入变换），按 `stream` 选择 Provider 的流式或一次性调用；流式增量经 `StreamChunkHandler` 合并后，由 `hooks.previewStep()` 产出展示态、`hooks.finishStep()` 产出该步最终消息。
7. 本步若含未执行工具：先按审批状态决定执行或结束等待；工具执行结果写回本步助手消息后继续下一 Step；无工具调用则以 `Completed` 结束（`ai/src/main/java/me/rerere/ai/agent/AgentLoop.kt`）。

文档差异：`docs/references/chat-generation-pipeline.md` 仍把核心生成类记作 `GenerationHandler`，当前快照中不存在该类；实际拆分为 `ai/agent/AgentLoop`（循环、工具、审批）与 `app` 的 `data/ai/ChatRequestFactory`（请求组装与变换），`ChatService` 只做编排与持久化。

## 1. 提交入口、任务对象与状态机

**入口与任务对象**：没有独立的“任务 ID”实体。会话状态由 `ConversationSession` 承载，本链只用到其中几样任务态：权威会话内存态、生成状态提示、当前生成 Job、回复消息 id 与生成开始时间（`state`、`processingStatus`、`generationJob`、`replyMessageId`、`generationStartedAt`）。会话对象由会话管理器惰性创建，初始值只是一条带 id 与助手 id 的占位会话，真正的历史在初始化时经 `ConversationStore` 从数据库载入（`service/ConversationSession.kt`、`service/ConversationSessionManager.kt`）；消息节点、分支与占位会话的数据语义归[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

**发送即入队**：`sendMessage()` 先判空，再把输入封装成队列项入队并立即触发调度。队列语义在 `MessageQueue` 中：`takeNext()` 跳过处于编辑占位的项，暂停时返回空，`pause()` 把所有等待中的回复以异常结束（`service/MessageQueue.kt`）。因此“再次发送”进入队列，等待本轮结束后再调度。

**任务状态初始化**：`launchGenerationJob()` 用惰性启动创建 Job，`keepAliveInBackground` 为真时先申请前台服务保活，任务体结束后释放（`service/ChatService.kt`）；前台服务、通知与后台悬浮窗的语义归[主动 Agent 与后台任务笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)。Job 完成回调里比较并清空当前 Job、触发 `onGenerationFinished`——回调会暂停队列、把有未决审批工具的语音等待者置错，并驱动队尾消息调度。

**错误状态**：错误集中记录在 `ChatService` 的错误列表，`CancellationException` 被直接忽略，不进入错误列表；生成前失败、MCP 服务名非法等各自带本地化标题。

## 2. 历史选择与上下文拼装顺序

每次模型调用前，`ChatRequestFactory.buildStep()` 用 `buildList` 组装本次请求的消息，顺序固定（`data/ai/ChatRequestFactory.kt`）：

1. **合成 system 消息**（仅当内容非空时加入），文本按“生效系统提示 → 可选记忆清单 → 每个工具的系统提示”顺序拼接；生效系统提示在会话级自定义提示非空且 `allowConversationSystemPrompt` 为真时取会话级，否则取助手 `systemPrompt`。该消息以 `isSynthetic = true` 标记。
2. **裁剪后的历史**：`messages.limitContext(assistant.contextMessageLimit)`，即不含 system 的当前分支消息列表。

随后整段消息列表穿过输入变换管道。管道成员在 `ChatRequestFactory` 构造时固定：时间提醒、提示注入、占位符、文档转提示、OCR、模板渲染、会话级工作区提醒，以 `fold` 顺序应用，后者能看到前者的结果（`data/ai/ChatRequestFactory.kt`、`data/ai/transformers/Transformer.kt`）。各变换器的成员、触发条件、注入位置与优先级、占位符与模板渲染规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)；本链只关心这条管道是 Provider 调用前的最后一道拼装步骤。

**请求参数**：`TextGenerationParams` 由助手与模型配置合成——温度、topP、maxTokens、reasoningLevel 取自助手，`tools` 取本轮工具集（`AgentRequest` 声明给模型的工具与可执行工具始终是同一份），自定义 header/body 把助手级与模型级拼接，`sessionId` 使用会话 id（`data/ai/ChatRequestFactory.kt`）。该 sessionId 会经 `configureSessionHeaders()` 进入请求头，是“同一会话稳定标识”的落点，也是与渠道笔记的交接面。

**后台请求**：标题、建议、记忆整理这类请求由 `backgroundTextGenerationParams()` 生成参数，只带模型级自定义请求头与请求体，并沿用同一 `sessionId`；实现在 `ChatRequestFactory.kt` 与 `ConversationMetaGenerator` / `MemoryConsolidator` 附近。

## 3. 预算、截断、摘要与压缩

**截断是条数口径，不是 token 口径**。`limitContext(limit)` 只依据消息条数：`limit <= 0` 或未超限时原样返回；超限时计算回落目标 `target = limit * 0.5`（四舍五入并夹取到 `[1, limit]`），步幅 `stride = limit - target`，截断起点按步幅对齐。因此截断点在一段连续轮次内保持不动，请求前缀稳定，利于命中提示词缓存（`ai/src/main/java/me/rerere/ai/ui/Message.kt`）。

**对齐避免拆散工具对**。`alignContextStart()` 在截断点落在含工具的消息上时向前回退：若当前消息含已执行工具（有 output），向前找同一调用链中未执行的工具调用；若含未执行工具调用，向前找对应的 USER 消息。回退只减不增，故不破坏保留下界（同文件）。

**压缩是手动、非自动，采用检查点式**。入口是聊天页对话框经 `ChatVM.handleCompressContext()` 调到 `ChatService.compressConversation()`，没有基于 token 预算的自动触发。它以会话中最后一个上下文检查点为起点，把“检查点之后、末尾保留区之前”的节点作为压缩范围；生成摘要后在压缩范围的最后一条消息之后插入一条检查点消息，原消息节点全部保留（`service/ChatService.kt` 的 `compressConversation`、`Conversation.insertContextCheckpoint`）。

压缩请求刻意复用正常对话的请求组装：同一模型、同一系统提示与工具定义、同一 `sessionId`，只在末尾追加压缩指令，使请求前缀与上一轮对话一致以命中提示词缓存；摘要请求把 `maxTokens` 置空以免被聊天回复的输出上限截断（`data/ai/ChatRequestFactory.kt` 的 `generateCompressionSummary`）。前置条件包括：当前不在生成中、压缩范围内没有待执行或可续跑的工具调用；摘要回复若仍调用工具则判为失败而不是把说明文字存成摘要。

`contextMessageLimit` 是助手级配置（`data/model/Assistant.kt`），界面上 0 表示不限制。

## 4. SDK、Provider、模型与协议交接

**模型与渠道解析**：`ChatRequestFactory.createContext()` 以会话视角解析助手与模型（`settings.getChatModelOf`），查不到直接抛“未选择对话模型”；渠道由 `model.findProvider(settings.providers)` 解析，支持模型级 `providerOverwrite` 覆盖；实现实例由 `ProviderManager.getProviderByType()` 按 `ProviderSetting` 子类型取得（`data/datastore/Settings.kt`、`ai/src/main/java/me/rerere/ai/provider/ProviderManager.kt`）。创建上下文时还会一次性取出记忆文件、构建工具集，并校验 MCP 服务名。

ProviderManager 在初始化时注册三个渠道实现：OpenAI 兼容、Google、Claude。**协议交接点**就是 `Provider` 接口的两个方法：`streamText` 返回 `Flow<StreamChunk>`，`generateText` 返回 `TextGenerationResult`（含 message、finishReason、usage）；是否流式由 `AgentRequest.stream = assistant.streamOutput` 决定。协议内部的分支不改变这个交接面——OpenAI 兼容渠道再按 `useResponseApi` 二分到 Chat Completions 与 Responses 两套线协议，Claude 渠道把首条 SYSTEM 提取为顶层字段并实现 `pause_turn` 续跑，这些字段映射、方言适配与续跑细节见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

**用量记录**：`ChatRequestFactory` 用 `UsageRecorder` 包裹 Provider，给每次调用打上来源标签（聊天/压缩）与助手、会话 id；`TokenUsage` 的合并规则仍是“非零值优先覆盖”（`ai/src/main/java/me/rerere/ai/core/Usage.kt`）。

## 5. 流式事件、缓冲、节流与顺序

**传输与缓冲**：Provider 侧用 `callbackFlow` 承载 SSE 事件，流以 `Channel.UNLIMITED` 缓冲并 `flowOn(Dispatchers.IO)`；注释明确指出缓冲必须有界性反转的原因——曾有缓冲满静默丢 delta 导致回复中间缺字（`ai/.../openai/ChatCompletionsAPI.kt`、`ai/.../claude/ClaudeProvider.kt`）。这是全链唯一的显式缓冲策略，管道本身不做节流或合并窗口，每个 chunk 都向下游转发。SSE 事件源与各协议的逐字段解码见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

**通用事件模型**：`StreamChunk` 是与协议无关的密封类，覆盖文本、推理、工具调用、服务端工具、图片、注解、用量与 Finish，并普遍采用 Start/Delta/End 三元组（`ai/src/main/java/me/rerere/ai/ui/StreamChunk.kt`）。各协议实现 `StreamChunkDecoder`（`accept`/`onClosed`），且要求 Finish 幂等、每条流独立实例（`ai/src/main/java/me/rerere/ai/provider/stream/StreamChunkDecoder.kt`）。

**合并层**：`StreamChunkHandler` 保存每个事件 id 在 parts 中的下标，把增量并入末尾助手消息；容忍 Provider 未发 Start 时由首个 Delta 直接建 part；工具调用按 `toolCallId` 而非 part 位置定位（支持并行）；`Finish` 时设置 `finishedAt`、结束未关闭的推理 part 并清空索引（`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt`）。它是有状态对象，“每条流独立实例、不复用”被写在类注释中。

**重试与合并的交互**：流式分支每轮尝试都新建 `StreamChunkHandler`，并以“本次调用开始前的消息快照”为基线重新合并，避免把重试响应追加到已展示的半截回复之后；为此会预先建好一条复用同一 id 的空助手消息，使 `ChatService` 覆盖当前分支而不是新建候选（`ai/agent/AgentLoop.kt`）。下游消息转换或 UI 更新抛错会被包成 `StreamChunkHandlingException` 并直接上抛，不触发网络重放。

**非流式分支**：用 `withRetry()` 包一次 `generateText()`，结果经 `handleTextGenerationResult()` 合并——末条角色相同则并入（文本/推理/工具按语义合并，图片作为独立完整项追加），不同则新增一条（`AgentLoop.kt`、`StreamChunkHandler.kt`）。

**图像与推理的特殊合并**：`ImageSnapshot` 用完整快照替换同 id 图片数据，与追加型 `ImageDelta` 区分；把不含 reasoning part 的回复里的 `<think>...</think>` 提取为推理 part 由 `ThinkTagTransformer` 完成，其规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。

## 6. 完成、异常、半截流与最终回写

**单步收尾**：每一步生成结束后，`AgentLoop` 调用 `hooks.finishStep()` 拿到该步最终消息，再检查未执行的工具调用：待审批则以 `AwaitingApproval` 结束，已批准则执行并进入下一 Step，无工具调用则 `Completed`；步数达到 `maxSteps` 以 `StepLimitReached` 结束（`ai/src/main/java/me/rerere/ai/agent/Agent.kt`、`AgentLoop.kt`）。

**输出变换的三个时机**（`data/ai/transformers/Transformer.kt`）：循环每次发出增量前调用 `hooks.previewStep()`（只影响这一次展示事件，不写回循环内部）；每步结束时 `hooks.finishStep()` 依次跑 `transforms()`、`visualTransforms()`、`onGenerationFinish()`；且只对“这一步新生成”的 part 生效，避免正则改写叠加（`ChatRequestFactory.kt` 的 `transformNewParts`）。`RegexOutputTransformer` 只实现视觉变换；`visualOnly == true` 的正则在生成管道中被过滤掉，只在消息渲染层以 `visual = true` 调用时生效（`data/model/Assistant.kt`、`ui/components/message/ChatMessage.kt`）。

**整轮收尾**：`runTurn` 的 `finally` 在 `NonCancellable` 中清空处理状态、调用 `session.finishGeneration()` 兜底保存并发出 `ChatGenerationEnded` 事件；随后 Job 完成回调再 `session.flush()` 落库并调度队列。因此**取消或异常也会保存本轮已产生的半截消息**（`service/ChatService.kt`、`service/ConversationSession.kt` 的 `finishGeneration`）。

轮次结束后按结束原因做派生任务：非 `AwaitingApproval` 时异步启动标题生成、建议生成，并在启用记忆时通知 `MemoryConsolidationScheduler.onTurnFinished()`；等待审批的轮次把这些推迟到审批之后（`ChatService.kt` 的 `runTurn`）。

**用量统计**：`TokenUsage` 含 prompt/completion/cached/total，合并规则是“非零值优先覆盖”（`ai/src/main/java/me/rerere/ai/core/Usage.kt`）。流式下 `StreamChunk.Usage` 逐次并入助手消息的 `usage`；非流式下 `handleTextGenerationResult()` 把结果用量并入消息。用量随消息一起在落库时持久化；Claude 的缓存读取单列为 cachedTokens，其字段合成规则见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

## 7. 停止、重试、续写与重新生成

**停止**：`stopGeneration()` 先暂停消息队列（把所有等待中的回复置错），再取消会话所有活跃 Job，逐个 `join()` 等待收尾，最后把未执行工具以取消错误补全（`service/ChatService.kt`、`service/ConversationSession.kt`）。补全仅在确实有未执行工具时才保存会话。取消会沿协程传播到 Provider 的 `callbackFlow`，其 `awaitClose` 调用 `eventSource.cancel()`；本次调查未运行验证底层 OkHttp 连接是否同步中断。

**网络重试**：`RetryPolicy` 描述“最多重试几次、初始延迟、按什么异常判定”，默认值 `NETWORK` 为 3 次、1s 起翻倍，仅重试 `IOException`；设置项 `enableAutoRetry` 关闭时使用 `NONE`。`withRetry()` 在每次失败判定前先 `currentCoroutineContext().ensureActive()`，避免把用户取消导致的 `IOException("canceled")` 当成网络抖动重放；重试经 `AgentEvent.Retrying` 上报，`ChatService` 据此显示带错误分类的提示文案（`ai/src/main/java/me/rerere/ai/agent/Retry.kt`、`service/ChatService.kt`）。渠道侧的多 Key 与故障转移策略见 [LLM 渠道笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

**重新生成**：`regenerateAtMessage()` 区分角色——对 USER 消息，把消息节点截断到该条并保存后重新补全；对 ASSISTANT 消息，`regenerateAssistantMsg` 为真时以该条之前的上下文重跑，为假时仅保存；重跑前会清空上一轮建议并剔除无法续跑的工具调用（`service/ChatService.kt` 的 `runTurn` 中 `withoutUnresumableToolCalls`）。它复用同一个 Job 槽位并先 `join` 上一个 Job。

**工具审批后的续跑**：`handleToolApproval()` 更新目标工具为 Approved/Denied/Answered 并落库，只有在没有其他未决工具时才再次启动生成；`AgentLoop` 从消息末尾的助手消息继续执行工具而非重新请求模型（`service/ChatService.kt`、`ai/agent/AgentLoop.kt`）。审批状态机本身归 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

## 8. 队列、多会话并发与后台生成

同一会话串行：`dispatchNextQueuedMessage()` 在存在活跃 Job 或未决审批工具时直接返回，且整个调度在 `synchronized(session)` 内完成；不同会话各自持有 Job，跑在同一个作用域上，彼此并行（`service/ChatService.kt`、`service/ConversationSessionManager.kt`）。再次发送的行为是入队，等本轮或审批结束后由 Job 完成回调、队列增删等多个触发点驱动下一步。

后台生成由 `ChatGenerationForegroundService` 保活，生成仍归 `ChatService`；`keepAliveInBackground` 决定是否申请前台服务。另有 `ChatFloatingTracker` 与悬浮窗 UI 提供生成进度与快速回复入口，前台服务生命周期、通知与超时细节归[主动 Agent 与后台任务笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)，本链只在 `launchGenerationJob()` 处做申请与释放。

语音输入有独立通道：`enqueueVoiceMessage()` 返回一个 `Deferred<String?>`，在入队前校验队列未暂停且无未决工具，结果在生成结束后回填；队列暂停或存在未决工具时，等待者被置错（`service/ChatService.kt`）。

## 9. Agent、工具、知识库与附件注入点

本链在 `createContext()` 处构建一次工具目录，其余内部机制不在本类目展开。目录由 `ChatToolFactory.createTools()` 按固定顺序累积；注册顺序、过滤条件与工具来源归 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

工具以三类信息进入请求：schema 进 `TextGenerationParams.tools`，`systemPrompt` 被拼进合成 system 消息，`needsApproval` 决定是否进入审批状态机；执行结果内联写回助手消息的 parts，因此与助手回复一同落库，而不产生 TOOL 角色消息。工具输出超过 32KB 且工具集含工作区 shell 时，仅保留预览、全文另存并在消息中附读取提示（`data/ai/tools/ChatToolFactory.kt` 的 `MAX_TOOL_OUTPUT_CHARS`）；工具契约、参数校验与结果限制细节归 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

附件方面，文档附件在变换管道中解析为文本注入消息，模型不支持图像输入时图片经 OCR 转文本；上传文件位于应用私有 `upload` 目录，被映射为工作区内的只读路径。附件与占位符的注入规则归[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)，工作区侧的路径与执行边界归[外部执行体与应用协作笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)。

## 10. 退出恢复、日志与已确认边界

**会话生命周期**：`ConversationSession` 用原子引用计数管理内存驻留，UI 打开/关闭经 `acquire()`/`release()` 调整；引用归零后安排 5 秒空闲检查，若期间仍无引用且未在生成则回调清理（`service/ConversationSession.kt`、`service/ConversationSessionManager.kt`）。`isInUse` 综合引用数、活跃 Job 与队列非空三者判断。

**可观测性**：错误集中于 `ChatService` 错误列表；生成状态经 `processingStatus` 暴露给 UI；生成开始/更新/结束通过应用事件总线发出，供通知与悬浮窗消费（`tryEmit` 不挂起，事件丢失只影响单次通知更新，不反压生成链）。请求级日志由 Provider 打印请求体与流事件，`RequestLoggingInterceptor` 另有实现位置。

**已确认边界**：
- 截断只按消息条数，不做 token 估算；`limitContext` 不影响 system 消息与工具 schema。
- 压缩是手动触发，以检查点插入摘要并保留原始节点，摘要本身不可再展开。
- 整轮结束（成功、取消、失败）都会经 `finishGeneration` 兜底保存。
- 工具结果内联在 ASSISTANT 消息 parts 中，不产生 TOOL 角色消息。
- 同一会话严格串行，无 steer/替换当前生成的能力，再次发送即排队。

## 11. 未验证事项

- 用户点击停止后，`eventSource.cancel()` 是否即时中断底层网络请求，未运行验证。
- UI 层对高频 chunk 的渲染节流/重组频率未在本次范围内核查（管道本身无节流）。
- Google 渠道与 Responses API 两条协议分支的逐字段映射未逐一复核，仅确认入口与解码器存在。
- 检查点式压缩在多次压缩叠加后的请求前缀稳定性、摘要与检查点的模型可见形式未运行验证。
- `visualOnly == true` 正则在渲染层的端到端效果未运行验证。
- 取消后兜底保存的半截消息在跨进程重启后的可见性未运行验证。

## 12. 关键源码索引

- 编排入口与状态：`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt`（`sendMessage`、`sendQueuedMessage`、`runTurn`、`compressConversation`、`stopGeneration`）；会话状态：`service/ConversationSession.kt`；管理器：`service/ConversationSessionManager.kt`；队列：`service/MessageQueue.kt`
- 请求组装与变换：`app/src/main/java/me/rerere/rikkahub/data/ai/ChatRequestFactory.kt`；变换器：`data/ai/transformers/Transformer.kt`
- 通用 Agent 循环：`ai/src/main/java/me/rerere/ai/agent/Agent.kt`、`AgentLoop.kt`、`Retry.kt`
- 上下文裁剪与消息模型：`ai/src/main/java/me/rerere/ai/ui/Message.kt`
- 流式合并：`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt`；事件模型：`ai/.../ui/StreamChunk.kt`
- Provider 路由与协议：`ai/src/main/java/me/rerere/ai/provider/ProviderManager.kt`
- 对照文档（存在与实现不一致处）：`rikkahub/docs/references/chat-generation-pipeline.md`
