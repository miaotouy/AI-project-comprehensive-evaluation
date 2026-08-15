# DeepChat 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：直接阅读源码（main process 的 SessionTurn/turnCoordinator 执行链、contextBuilder 与 promptAssembly、deepChatLoopRunner/process 流式管线、pending input 队列协调器、结构化日志事件面），静态核对符号与行号；未运行测试、构建或桌面端交互
>
> 调查范围：一次生成任务的提交入口（send/steer/queue/retry/delete/edit/fork/compaction/tool interaction）、任务状态机、上下文拼装顺序、预算截断与压缩、Provider 交接与流式事件链、最终回写、停止/重试/续写、队列与并发、外部能力注入点、退出恢复与可观测性；消息/队列的数据持久化语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的生成任务由 main process 编排，单会话串行、多会话各自独立：

1. `chatSendMessageRoute` 等路由 → `ChatService` → `SessionTurn`（session 操作 gate）→ DeepChat runtime 的 `turnCoordinator.start`：状态置 generating、附件准备、以 `createAssistantMessage(pending)` 占位后进入流式。
2. 上下文构建（`contextBuilder`）顺序：`leadingMessages（system prompt + checkpoint）→ 预算内完整 tail turns → 新 user 消息`；超预算先摘 memory、再摘 directives，仍超则抛 overflow；重试/恢复按 orderSeq 取到目标 assistant 为止的记录并保留其所属 user turn。
3. 每次新 turn 前由 compaction 服务计算压缩 intent（自动压缩），Provider 流经 `processStream` + `streamProviderAttempts`（预检、严格重试、context-pressure recovery）。
4. 流式 assistant blocks 经 echo 节流（renderer 120ms / DB 600ms）写回 transcript；成功 `finalizeAssistantMessage(sent)`，异常 `setMessageError(error)`，半截 pending/loading block 转 error 并追加错误块。
5. steer、queue、工具 question/permission response 是独立输入通道；queue 项 claimed 后物化为 user 消息，失败未物化则进入 `retry_required` 等待显式恢复。

## 系统边界与生成任务主链

```text
ChatPage（preload bridge，执行入口见 Chat UI 笔记）
  -> chatSendMessageRoute（routes.ts:676-691，submission 取消注册）
  -> ChatService.sendMessage（chatService.ts:77）
  -> SessionTurn.sendMessage（turn.ts:102-111，session 操作 gate）
  -> runtime.send -> turnCoordinator.start（turnCoordinator.ts:309）
     -> 状态 generating（:366）+ pending interactions 检查（:339-341）
     -> 附件准备（attachmentRouter.prepare，:497-515；needs_user_action -> block/返回）
     -> createUserMessage / createAssistantMessage(pending)（appendUserFact :670-701）
     -> compaction prepare（:575-608）-> 记忆注入（:766-788）-> contextBuilder 拼装（:789-...）
     -> deepChatLoopRunner.run（:856）-> processStream（process.ts:779）
        -> streamProviderAttempts（预检/严格重试/恢复，deepChatLoopRunner.ts:701-780）
        -> echo 节流（120ms/600ms）-> transcript.updateAssistantContent
        -> IPC chat.stream.updated / completed / failed
     -> claim 结算（consume / release-after-rollback，:918-932）
  -> 终态：finalizeAssistantMessage(sent) 或 setMessageError(error)
```

边界：消息与 block 的持久化形状、搜索文档与 Tape 的同步写入属于会话与消息管理（`../会话与消息管理/DeepChat-会话与消息管理调查笔记.md`）；输入框、pending lane 与停止按钮的界面状态属于 Chat UI（`../Chat UI/DeepChat-ChatUI调查笔记.md`）；工具执行循环内部语义属于 Agent 工具类目；ACP runtime 的具体外部协议 payload 不在本文展开。

## 1. 提交入口、任务对象与状态机

**路由层**（`src/main/session/routes.ts:676-734`）注册五个 chat 操作入口：

- `chatSendMessageRoute`：发送；
- `chatSteerActiveTurnRoute`：steer；
- `chatCancelSubmissionRoute`：取消附件提交；
- `chatStopStreamRoute`：停止流；
- `chatRespondToolInteractionRoute`：工具交互响应。

send/steer 经 `withSubmissionCancellation`（:129-141）注册 `SubmissionCancellationRegistry`，可在附件准备阶段用 submissionId 取消。

**服务层**：`ChatService.sendMessage` / `steerActiveTurn` / `stopStream` / `respondToolInteraction`（`src/main/session/chatService.ts:77/:136/:212/:276`），其中 send/steer 与 session gate 同步。

**`SessionTurn`**（`src/main/session/turn.ts:36-454`）操作面：

- `sendMessage`（:102-111）经 `sendMessageUnderSessionGate`（:113-164）执行：输入归一化（:120）、工作目录同步（:126-132）、`runtime.send`（:133-144）；附件 `needs_user_action` 时提前返回（:145-147）；draft 会话提升（:149-154）与标题生成（:155-162）。
- steer 与 pending 队列操作：`steerActiveTurn`（:166-206）、`queuePendingInput`（:244-279）、`updateQueuedInput`（:281-290）、`moveQueuedInput`（:292-301）、`convertPendingInputToSteer`/`steerPendingInput`（:303-315）、`resolveBlockedPendingInput`（:317-326）、`deletePendingInput`（:328-331）。
- `resumePendingQueue`（:219-228）与 `retryPendingQueueInput`（:230-242）只对 DeepChat session 可用（ACP 抛错）；`isPendingQueueResumeAvailable`（:213-217）供 UI 判断。
- 消息级操作：`retryMessage`（:333-375）、`deleteMessage`（:377-381）、`editUserMessage`（:383-390）、`getSessionCompactionState`（:392-399）、`compactSession`（:401-413）、`clearSessionMessages`（:415-420）、`cancelGeneration`（:422-425）、`respondToolInteraction`（:427-437）。

**任务状态机**（`turnCoordinator.start`，`src/main/agent/deepchat/runtime/turnCoordinator.ts:309-`）：

- `initializeTurn`（:326-378）：`hasPendingInteractions` 检查（:339-341）、`transitionStatus(scope,'generating')`（:366）、经 `runLifecycle.ensureOperationController` 拿 abort controller（:362）。
- steer claim 复用预建的 user/assistant 消息（:382-388、:466-495）；普通 send 走附件准备（:497-515），`needs_user_action` 时把 claimed 输入置 blocked 并返回（:516-525）。
- `prepareTurnResources`（:539）解析 generation settings/工具/命令壳/prompt assembler。
- 历史准备与压缩：`prepareCompactionIntent`（:575-608，调 `compactionService.prepareForNextUserTurn`）、`ensureHistory`（:566-574，Tape 就绪）。
- `appendUserFact`（:670-701）：queue claim 用 `createClaimedQueueUserMessage` 物化（:686-691），否则 `createUserMessage`；再 `createAssistantMessage(pending)`。
- `loopRunner.run`（:856）；返回后 claim 结算（:918-932）：completed/paused/aborted → consume；否则回滚（`rollbackPendingInputTurn`）并 `release-after-rollback`（queue 项即进入 `retry_required`，数据形态见会话与消息管理笔记 §1.4）。

## 2. 历史选择与上下文拼装顺序

- **候选与游标**：`buildCacheAwareContextWithMetadata`（`src/main/agent/deepchat/runtime/contextBuilder.ts:1577-1689`）从 transcript 取候选记录（:1589），`isContextHistoryRecord`（:267）过滤为 context history，从 summary cursor（`filterRecordsFromCursor` :1569-1575）开始建 history turns。
- **重试/恢复起点**：`buildCacheAwareResumeContextWithMetadata`（:1691-1824）按 `orderSeq` 取到目标 assistant 为止的记录（:1708-1710），向前回溯其所属 user turn（:1713-1718），保留该 turn 与目标 assistant（:1724-1728）；该函数只做线性 orderSeq 过滤，没有按父子关系回溯分支（分支数据语义见会话与消息管理笔记 §1.5）。
- **system prompt、记忆、附件与工具**：`PromptAssemblyService.build`（`src/main/agent/deepchat/runtime/promptAssemblyService.ts:62-79`）组合基础 prompt、技能与工具定义；压缩后的恢复 prompt 由 `createPostCompactionPromptAssembler`（:123-140）注入 checkpoint、memory 与 directives。记忆注入发生在每次新 user turn 的 pre-stream 阶段（`turnCoordinator.ts:766-788`）。
- **最终顺序**：`leadingMessages（system + checkpoint）→ 预算内完整 tail turns → 新 user 消息`（`contextBuilder.ts:1673-1688`）。

## 3. 预算、截断、摘要与压缩

- **预算**（contextBuilder.ts:1372-1388）：`resolveFiniteInputBudget` 按 contextLength 减去保留与额外保留计算，`resolvePhysicalInputBudget` 给物理上限。拼装时固定内容（leading + 新 user 消息）超预算先移除 memory（:1625-1642）、再移除 directives（:1644-1661），仍超物理预算抛 `buildCacheAwareOverflowError`（:1663-1670，错误文案 :1390-1403）；历史按完整 tail turns 裁剪（`selectCompleteTailTurns` :1334-1348）。
- **运行时二次防线**：`deepChatLoopRunner` 的 `coreStream`（`src/main/agent/deepchat/runtime/deepChatLoopRunner.ts:701-780`）向 provider attempt 管线提供 `preflight`（:736-743）与 `fitStrictRetry`（:744-751，严格重试前再裁剪）；context-pressure 错误由 `recoverRequestContextPressure`（:1221-）经 `compactionService.prepareForContextPressureRecovery` 生成压缩 intent 后重试。
- **自动压缩**：每次新 user turn 前由 `compactionService.prepareForNextUserTurn`（`compactionService.ts:311-`，调用点 turnCoordinator.ts:592-608）计算 intent，恢复 turn 用 `prepareForResumeTurn`（:359-）；intent 落地 `compactionRuntimeCoordinator.apply`（:291-，压缩消息的前插/顺移见会话与消息管理笔记 §4）。摘要生成（`generateRollingSummary` :774-、`summarizeBlocks` :810-、summary prompt 构造 :965-、模型调用 :996-）。
- **manual compaction**：`turn.compactSession`（`turn.ts:401-413`）→ `compactionRuntimeCoordinator.compact`（`compactionRuntimeCoordinator.ts:133-`），要求非 ACP、状态 idle、无 pending interactions（:147-155）。
- 压缩摘要的存储（summaryState 的持久化位置）本次未展开（§11）。

## 4. SDK、Provider、模型与协议交接

- `deepChatLoopRunner.run`（`deepChatLoopRunner.ts:381-`）解析 provider model facts（:435-442）、生成设置与 model config（:443-488，含 `capAgentRequestMaxTokens` 上限），工具目录 `toolCatalog.resolve`（:523-539，subagent 场景应用 `meetTaskContractToolDefinitions` 契约），随后把上下文结果交给 `processStream`（:671）。
- `processStream`（`src/main/agent/deepchat/runtime/process.ts:779-`）启动 echo（:849）与输出 sink（:861-865），经 `coreStream` → `contextCoordinator.streamProviderAttempts`（`deepChatLoopRunner.ts:719-780`）发起 provider 请求（requestMessages/model/temperature/maxTokens/tools），按轮次循环直到工具批处理完成或终态。
- 协议适配：ACP runtime 的外部 payload 与 provider 协议 adapter 本次未展开（边界见 §10）。

## 5. 流式事件、缓冲、节流与顺序

- **生成侧**（`src/main/agent/deepchat/runtime/echo.ts:5-77`）：`echo.ts` 双节流——renderer 快照 120ms、DB 落盘 600ms（:5-6，`startEcho` :15-77，`cloneBlocksForRenderer` 克隆给 renderer）；事件 `chat.stream.updated`（snapshot，:16-28）。块累积在 `accumulator.accumulate`（`accumulator.ts:141-`），跨轮次 usage 由 `commitRoundUsage`（:11-）提交。
- **终态事件**：`chat.stream.completed`/`chat.stream.failed`（`dispatch.finalize`/`finalizeError`，`src/main/agent/deepchat/runtime/dispatch.ts:2693-2735`）。
- **renderer 侧顺序保证**：`messageIpc.ts` 按 `(sessionId, requestId)` 的 generation/updatedAt 拒绝过期快照（`src/renderer/src/stores/ui/messageIpc.ts:92-113`），completed/failed 后 settle 并重载持久化页（:127-163）；数据语义见会话与消息管理笔记 §6。
- 未运行网络中断与快速切换场景的实测（§11）。

## 6. 完成、异常、半截流与最终回写

- 正常完成：`dispatch.finalize`（:2693-2713）把 pending block 置 success、`finalizeAssistantMessage(sent)`（transcript 同步 blocks/message/搜索文档/usage/Tape，见会话与消息管理笔记 §2）、发布 completed。
- 异常：`dispatch.finalizeError`（:2715-2735）经 `buildTerminalErrorBlocks`（`transcript.ts:44-70`，pending/loading block 转 error 并追加错误块）→ `setMessageError(error)`，发布 failed；`USER_CANCELED_GENERATION_ERROR` 走 `finalizeUserCanceledErrorIfNeeded`（`process.ts:359-364`）。
- 半截流：`INCOMPLETE_PROVIDER_STREAM_ERROR`（`process.ts:49-50`）等终态判定在 `selectProcessTerminal`/`resolveProviderTerminalDecision`（`deepChatLoopRunner.ts:332-362`、`process.ts:256-`）；run 终态经 `commitRunTerminal`（`process.ts:856-859`）落日志与执行台账。
- 回写频率三档：流式快照（120ms）→ 内存/DB（600ms）→ 终态一次写全量。任务结束后 `runLifecycle.applyProcessResultStatus`（`src/main/agent/deepchat/runtime/runLifecycleCoordinator.ts:321-362`）把 session 状态转 idle/error 或保持 generating（paused，:337-349）。

## 7. 停止、重试、续写与重新生成

- **停止（界面 → 网络）**：ChatPage `onStop`（见 Chat UI 笔记 §5）→ `ChatService.stopStream`（`chatService.ts:212-`）→ `RunLifecycleCoordinator.cancel`（`runLifecycleCoordinator.ts:258-306`）：请求生成中断、延后工具调用与 provider 权限全部取消，未开始流的场景把 pending interaction 块写为 aborted 终态并调度队列（:284-305）。附件准备阶段另有 submission 取消（`chatCancelSubmissionRoute`，`routes.ts:710-718`）。
- **重试**：`turn.retryMessage`（`turn.ts:333-375`）→ `prepareRetryMessage`（`transcriptMutations.ts:43-66`，取 source user 消息；error + steer receipt 时允许保留 restart-held queue）→ `runtime.send`，DeepChat 路径在 `beforeHistoryPreparation` 中 `commitRetryMessage`（:68-73，`deleteFromOrderSeq` 破坏性截断）。重试的起始上下文由 `buildCacheAwareResumeContextWithMetadata` 决定（§2）。
- **续写**：本次在 turn 操作面与 ChatPage 动作中未找到独立的"续写"执行链；`onMessageContinue` 复用 retryMessage 语义（见 Chat UI 笔记 §6）。检查范围：`turn.ts` 全部公开操作、`useMessageActions.ts`。
- **编辑后发送**：`editUserMessage`（`turn.ts:383-390`）→ `transcriptMutations.editUserMessage`（:85-106，原地改文本）；随后 UI 自动 retry 完成截断（Chat UI 笔记 §6）。
- **队列项恢复**：`retryPendingQueueInput`（`turn.ts:230-242`）→ `PendingInputAdmissionCoordinator.retryPendingQueueInput`（见 §8）。

## 8. 队列、多会话并发与后台生成

- **并发粒度**：单会话串行由两层保证——`SessionTurn` 全部写操作走 `workdir.runWithSessionOperationGate`（`turn.ts:107-111` 等），DeepChat runtime 另以"drain lease"保证同一时间只启动一个 turn（`pendingInputPump.ts:407` `tryAcquirePendingQueueDrain`、`launch` :505-566）。不同会话各有独立 runtime scope，互不阻塞。
- **入队与认领**：`PendingInputAdmissionCoordinator.queue`（`pendingInputAdmissionCoordinator.ts:104-139`）按 `shouldClaimImmediately`（`pendingInputPump.ts:295-331`）决定直接 claimed 启动还是入队等待；`sendQueuedMessage`（:141-190）在入队前完成附件准备。`drain`（`pendingInputPump.ts:402-494`）按 steer 优先取下一项（:432-439），restart-held 项不自动启动（:436-438）。
- **失败释放与 retry_required**：`DurablePendingInputClaim.apply`（`pendingInputPump.ts:149-174`）——`release-before-user-fact`/`release-after-rollback` 对 queue 项调用 `releaseClaimedQueueInputForRetry`（数据层见会话与消息管理笔记 §1.4）；turn 内未 settle 的 claim 会在 finally 记账（:546-565）。
- **恢复执行**：`retryPendingQueueInput`（`pendingInputAdmissionCoordinator.ts:433-474`）把 `retry_required` 项置回 pending 并 drain；`resumePendingQueue`（:476-494）要求无 blocked/claimed 项并释放 restart hold 后 drain。
- **steer 通道**：`steerActiveTurn`（:192-289）与 `steerPendingInput`（:315-410）把输入物化为可见 user 消息（`acceptSteerMessage`/`promoteQueuedInputToSteerMessage`，数据层见会话与消息管理笔记 §1.4）；工具 question/permission 响应经 `respondToolInteraction`（`turn.ts:427-437`）走独立通道。
- 多会话并行生成与"后台（窗口外）生成"：本次在 ChatPage 与 runLifecycle 中未找到后台生成调度入口（检查范围：`turnCoordinator`、`runLifecycleCoordinator`、ChatPage 组合）；不同会话只是各自独立串行执行。

## 9. Agent、工具、知识库与附件注入点

- **工具目录**：`deepChatLoopRunner` 的 `toolCatalog`（`deepChatLoopRunner.ts:523-539`）解析 active skills 与工具目录（`resolveActiveSkillNamesForToolProfile` :511-514），subagent 场景经 `meetTaskContractToolDefinitions` 裁剪；system prompt 随技能/工具刷新（`refreshSystemPrompt` :679-698，经 `promptAssemblyService.build`）。
- **附件**：`attachmentRouter.prepare`（`pendingInputAdmissionCoordinator.ts:556-577`、`turnCoordinator.ts:497-515`），失败返回 `needs_user_action` 摘要（retry / send_without_image_content）。
- **记忆**：pre-stream 经 `postCompactionPromptAssembler.assemble` 注入（`turnCoordinator.ts:766-788`，contributor 为 `MemoryPromptContributor`）。
- **联网搜索**：`search` 开关进入 user content（`turnCoordinator.ts:450-454`，provider 原生搜索能力 + `searchExecution === 'provider'` 时启用）。
- **MCP App model context**：保存在 assistant block 的 `extra_json`（`deepchatAssistantBlocks.updateMcpAppModelContext`，数据语义见会话与消息管理笔记 §1.3）。
- 知识库等其余外部能力注入点本次未覆盖。

## 10. 退出恢复、日志与已确认边界

- **启动恢复**：`createDeepChatRuntimeServices`（`src/main/agent/deepchat/harness/createDeepChatAgentHarness.ts:512-523`）先 `recoverInputsAfterRestart`（queue/steer 收口，held 项交给 pump 持有）再 `recoverPendingMessages`（pending 消息置 error）；UI 侧 resume 动作见 Chat UI 笔记 §5。
- **可观测性**：结构化主进程 JSONL 日志（`src/main/logging/mainLogEvents.ts`）：`agent.run.started`（:921-941）与 `agent.run.terminal`（:942-982）携带 runId/sessionId/messageId 关联字段（`correlationIdentifier`，:511-532）与 stopReason 枚举（:399-420）；另有 `agent.admission.*`（:983-1100）与 `orchestration.delegation.*`（:1101-1195）事件。事件面已具备任务关联基础设施，但本次未运行验证落盘内容与恢复时的回填。
- **已确认边界**：Provider 预检/严格重试/context-pressure recovery（§3）、overflow 抛出、manual compaction 限制（非 ACP + idle）、resume/retry 只对 DeepChat session 可用（`turn.ts:216`、:223-225、:237-239）。
- 应用退出、切换 session 时任务收口的实时行为本次未运行验证；ACP runtime 的协议 payload 未展开。

## 11. 未验证事项

- 压缩摘要的存储位置与恢复路径（summaryState 持久化）未展开；自动压缩触发阈值与算法细节未逐行验证。
- 网络中断、快速切换 session、重复 IPC 事件的流式顺序未运行验证。
- Provider fallback/同 Provider 重试与 context-pressure recovery 的实测效果未验证；重试幂等性（截断后重复执行）未实测。
- 应用退出、窗口关闭时的任务收口未运行验证。
- 未运行测试、构建或桌面端交互；结论来自 main process 静态源码。

## 12. 关键源码索引

- 路由与服务入口：`src/main/session/routes.ts:676-734`、`src/main/session/chatService.ts:77-299`
- turn 操作面：`src/main/session/turn.ts:102-437`
- 任务执行链：`src/main/agent/deepchat/runtime/turnCoordinator.ts:309-956`
- 上下文构建：`src/main/agent/deepchat/runtime/contextBuilder.ts:1577-1824`
- prompt 组装：`src/main/agent/deepchat/runtime/promptAssemblyService.ts:62-140`
- 循环与 provider 管线：`src/main/agent/deepchat/runtime/deepChatLoopRunner.ts:381-780`、`:1221`
- 流式节流与终态：`src/main/agent/deepchat/runtime/echo.ts:5-77`、`dispatch.ts:2693-2735`、`process.ts:779`
- 队列协调：`src/main/agent/deepchat/runtime/pendingInputAdmissionCoordinator.ts:104-494`、`pendingInputPump.ts:149-566`
- 压缩：`src/main/agent/deepchat/runtime/compactionService.ts:311-491`、`compactionRuntimeCoordinator.ts:106-291`
- 停止：`src/main/agent/deepchat/runtime/runLifecycleCoordinator.ts:258-306`
- 结构化日志：`src/main/logging/mainLogEvents.ts:921-982`
