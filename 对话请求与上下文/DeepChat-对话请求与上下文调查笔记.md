# DeepChat 对话请求与上下文调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：直接阅读源码（main process 的 SessionTurn/turnCoordinator 执行链、contextBuilder 与 promptAssembly、deepChatLoopRunner/process 流式管线、pending input 队列协调器、结构化日志事件面），静态核对符号与行号；未运行测试、构建或桌面端交互
>
> 调查范围：一次生成任务的提交入口（send/steer/queue/retry/delete/edit/fork/compaction/tool interaction）、任务状态机、上下文拼装顺序、预算截断与压缩、Provider 交接与流式事件链、最终回写、停止/重试/续写、队列与并发、外部能力注入点、退出恢复与可观测性；消息/队列的数据持久化语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前实现以 context occupancy 作为压缩判定的输入，并将压缩结果、边界原因和 Provider 用量分开记录。压缩期间建立 checkpoint；过期摘要受 CAS 拒绝，不能收缩上下文的摘要不被采用，但仍可推进带缺口标记的 boundary-only anchor，保留此前摘要（`src/main/agent/deepchat/runtime/compactionService.ts:629-745`、`src/main/session/data/settings.ts:270-310`）。工具目录则在本轮请求开始时冻结为 tool-surface snapshot，避免工具激活改变已经发出的 Provider 请求（`contextCoordinator.ts` 的工具面快照段）。

工具结果的上下文处理是两段式：先由判定模型问“这条已结束的结果这轮还要不要”，判为不需要的整条换成短占位说明，再由既有的按大小截断处理剩余结果（`src/main/agent/deepchat/runtime/jevToolResultPruning.ts`，语义见独特功能笔记能力卡 10）。判定链路只在 Agent 配置了 `judgmentModel` 且本轮允许裁剪时启用，未配置时该段完全跳过。

DeepChat 的生成任务由 main process 编排，单会话串行、多会话各自独立：

1. 请求从 chat 路由进入服务层，再经会话操作 gate 交给 DeepChat runtime 的 turn 协调器：置 generating 状态、准备附件、建一条 pending 的 assistant 消息占位，随后进入流式。
2. 上下文构建按 `leadingMessages（system + checkpoint）→ 预算内完整 tail turns → 新 user 消息` 的顺序拼装；超预算先摘 memory、再摘 directives，仍不够则抛 overflow。重试与恢复按 orderSeq 取到目标 assistant 为止的记录，并保留它所属的 user turn。
3. 每个新 turn 开始前，压缩服务先算出压缩 intent；Provider 请求流经 `processStream` 与 attempt 管线，后者负责预检、严格重试与 context-pressure 恢复。
4. 流式产生的 assistant block 经 echo 节流（renderer 120ms、DB 600ms）写回 transcript；成功时 finalize 成 sent，失败时写入错误状态，并把半截的 pending 与 loading block 转成 error、追加错误块。
5. steer、queue 与工具 question/permission 的响应走独立输入通道；队列项被认领后物化成 user 消息，失败未物化则进入 `retry_required`，等用户显式恢复。
6. 当前工作区 Skills 与 Codex 用户插件上下文均在 Provider 请求前物化：前者进入 Skill 视图和工具目录，后者由受限命令 hook 产生带来源的文本贡献；Direct ACP Agent 不消费这条 hook 链。

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

**服务层**：服务层对外提供发送、steer、停止流与工具交互响应四个入口，其中发送与 steer 会与 session gate 同步执行。四个方法分别位于 `src/main/session/chatService.ts` 的 77、136、212 与 276 行。

**`SessionTurn`**（`src/main/session/turn.ts:36-454`）操作面：

- 发送入口在 session gate 内完成一轮准备：先归一化输入、同步会话的工作目录，再把请求交给 runtime；附件需要用户处理时提前返回，draft 会话会被提升并生成标题。整段流程见 `turn.ts:102-164`。
- steer 与 pending 队列操作：turn 层对外提供一组方法，覆盖入队、调整与消费的全过程，集中在 `turn.ts:166-331`：
  - 入队与调整：`queuePendingInput`、`updateQueuedInput`、`moveQueuedInput`；
  - 转向与解除阻塞：`steerActiveTurn`、`convertPendingInputToSteer`、`steerPendingInput`、`resolveBlockedPendingInput`；
  - 删除：`deletePendingInput`。
- 队列的恢复与重试只对 DeepChat session 开放，ACP session 调用会抛错；界面通过另一个查询方法判断恢复入口是否可用，实现见 `turn.ts:213-242`。
- 消息级操作：turn 层另有一组单消息粒度的方法，涵盖重试、删除、编辑、压缩状态查询与执行、清空消息、取消生成和工具交互响应，定位见 `turn.ts:333-437`。

**任务状态机**（`turnCoordinator.start`，`src/main/agent/deepchat/runtime/turnCoordinator.ts:309-`）：

- 初始化阶段先检查是否还有未结束的工具交互，再经 run lifecycle 取到 abort controller，最后把会话状态切成 generating；这些动作集中在 `turnCoordinator.ts:326-378`。
- steer 的 claim 直接复用预建好的 user 与 assistant 消息；普通发送先做附件准备，附件要求用户处理时把已 claim 的输入置为 blocked 并返回。两段逻辑见 `turnCoordinator.ts:382-525`。
- 资源准备阶段一次性解析出本轮生成用的 generation settings、工具清单、命令壳与 prompt assembler，入口在 `turnCoordinator.ts:539`。
- 历史准备与压缩：本轮开始前先确保 Tape 就绪，再由压缩服务算出压缩 intent。两步都在 `turnCoordinator.ts:566-608`。
- 落库阶段把队列 claim 物化成 user 消息、普通发送直接新建 user 消息，随后再建一条 pending 状态的 assistant 消息占位，实现见 `turnCoordinator.ts:670-701`。
- 循环运行器返回后结算 claim：completed、paused、aborted 三种终态直接 consume，其余情况回滚本轮并走 release-after-rollback，队列项由此进入 `retry_required`。定位见 `turnCoordinator.ts:856-932`，数据形态见会话与消息管理笔记 §1.4。

## 2. 历史选择与上下文拼装顺序

- **候选与游标**：上下文构建先从 transcript 取出候选记录，按 context history 的判定过滤，再从摘要 cursor 处开始建 history turn。相关实现见 `src/main/agent/deepchat/runtime/contextBuilder.ts` 的 267 行与 1569-1689 行。
- **重试/恢复起点**：恢复上下文时按 orderSeq 线性取到目标 assistant 为止的记录，再向前回溯它所属的 user turn，最终保留该 turn 与目标 assistant；这里只做顺序过滤，没有按父子关系回溯分支（分支数据语义见会话与消息管理笔记 §1.5）。实现在 `contextBuilder.ts:1691-1824`。
- **system prompt、记忆、附件与工具**：prompt 组装把基础 prompt、技能与工具定义合成一次请求的系统提示；压缩之后改用恢复版组装器，依次注入 checkpoint、memory 与 directives。记忆注入发生在每个新 user turn 的 pre-stream 阶段，组装入口见 `promptAssemblyService.ts:62-140`，注入点见 `turnCoordinator.ts:766-788`。
- **workspace Skills 与插件上下文**：Skill 服务按会话工作目录发现项目级只读 Skills，并把正文固化到本轮视图；Codex 用户包的 context hook 在顶层 DeepChat 会话的输入边界执行，只把已持久化且仍获授权的附加上下文投影进请求，插件更新、禁用或 run 结束会撤销这份资格。Skills 侧见 `src/main/skill/index.ts:1295-1318`，插件上下文投影见 `src/main/agent/deepchat/runtime/pluginContext.ts`，run 内调用点在 `deepChatLoopRunner.ts:1569-1697`。
- **最终顺序**：`leadingMessages（system + checkpoint）→ 预算内完整 tail turns → 新 user 消息`（`contextBuilder.ts:1673-1688`）。

## 3. 预算、截断、摘要与压缩

- **预算**：构建上下文时先按 contextLength 扣除保留量与额外保留量，算出可用输入预算，并另设物理上限；拼装时若固定内容（leading 消息与新 user 消息）超出预算，就先放弃 memory、再放弃 directives，仍超物理上限则抛出 overflow 错误，历史部分只保留完整的 tail turn。预算计算、裁剪与抛错都集中在 `src/main/agent/deepchat/runtime/contextBuilder.ts:1334-1670`。
- **运行时二次防线**：请求发出前，循环运行器会在 provider attempt 管线里再裁一次上下文——先做预检，严格重试前再做一次适配裁剪；Provider 报 context-pressure 时，同一层生成压缩 intent 后重新发起请求。预检与裁剪见 `deepChatLoopRunner.ts:701-780`，恢复段在同文件 1221 行起。
- **自动压缩**：每个新 user turn 开始前，压缩服务先算出压缩 intent，恢复历史时另走恢复 turn 的入口；intent 由运行时协调器落地，摘要生成按滚动摘要 → 块摘要 → prompt 构造 → 模型调用的顺序推进，四步位于 774-996 行区间。入口见 `compactionService.ts:311`，调用点在 `turnCoordinator.ts:592-608`，压缩消息的前插与顺移见会话与消息管理笔记 §4。
- **手动压缩**：用户手动触发压缩时，session 层把请求转给运行时协调器，后者要求会话属于 DeepChat、状态为 idle 且没有待处理的工具交互，才真正执行压缩。条件判断与执行见 `compactionRuntimeCoordinator.ts:133-155`，入口在 `turn.ts:401-413`。
- **判定模型裁剪（新增前置段）**：已结束的工具结果进入上下文前，先由判定模型逐条判断本轮是否还需要：判为不需要的整条换成指回 Tape 的短占位，判为需要的保留原文。候选范围与判题状态受 token 和路径数上限约束，这一层只做投影，不写 Tape、返回新数组，后续的大小截断照常生效；判题材料是工具输出本身，不含大小与年龄提示。入口在 `jevToolResultPruning.ts:602`，占位替换在 521 行，候选约束见 `jevReviewState.ts:68-129`，反馈信号见 `jevPruningFeedback.ts`。
- **摘要持久化与失败边界**：摘要状态同时写入会话表和 Tape 的重建 anchor，写入事务里会比较旧摘要、cursor 与更新时间，过期结果因此覆盖不了当前状态；读取时优先从最新 Tape anchor 重建，没有 anchor 才回退会话表。读写实现见 `src/main/session/data/settings.ts:244-310`。

  摘要调用失败、返回空内容或结果不够小时，仍可提交 boundary-only anchor：cursor 前移，保留旧摘要，更新时间置空，并记录未摘要区间。已生成但过大的摘要被拒绝采用时，压缩边界停在已推进的位置；取消请求则抛出中止，不推进该结果（`compactionService.ts:629-745`）。启动时先协调压缩 marker，再恢复其余 pending 消息（`createDeepChatAgentHarness.ts:495-518`）。

## 4. SDK、Provider、模型与协议交接

- 循环运行器启动一轮任务时，先解析 provider 的模型事实、生成设置与 model config（含模型请求的 maxTokens 上限），再把工具目录解析成快照（subagent 场景按任务契约裁剪工具定义），最后把上下文结果交给 `processStream`。整段准备见 `deepChatLoopRunner.ts:381-671`。
- `processStream`（`src/main/agent/deepchat/runtime/process.ts:779`）先启动 echo 与输出 sink，再由上下文协调器带上消息列表、模型、温度、maxTokens 与工具定义发起 Provider 请求，按轮次循环直到工具批处理完成或进入终态。请求发起见 `deepChatLoopRunner.ts:719-780`。
- 协议适配：ACP runtime 的外部 payload 与 provider 协议 adapter 本次未展开（边界见 §10）。

## 5. 流式事件、缓冲、节流与顺序

- **生成侧**：echo 层用两档节流把累积中的块推给下游——renderer 快照每 120ms 一次、DB 落盘每 600ms 一次，克隆一份给 renderer 后以 `chat.stream.updated` 事件下发。块由 accumulator 累积，跨轮次的 usage 单独提交，两者都在 `accumulator.ts`（累积在 141 行起，usage 提交在 11 行起）；节流与事件见 `src/main/agent/deepchat/runtime/echo.ts:5-77`。
- **终态事件**：dispatch 的正常收尾与出错收尾分别发布 `chat.stream.completed` 与 `chat.stream.failed`，两处实现都在 `src/main/agent/deepchat/runtime/dispatch.ts:2693-2735`。
- **renderer 侧顺序保证**：renderer 按 sessionId 与 requestId 上的 generation、updatedAt 丢弃过期快照，收到 completed 或 failed 后 settle 并重新加载持久化页。判断与收尾见 `src/renderer/src/stores/ui/messageIpc.ts:92-163`，数据语义见会话与消息管理笔记 §6。
- 未运行网络中断与快速切换场景的实测（§11）。

## 6. 完成、异常、半截流与最终回写

- 正常完成：dispatch 的 finalize 把 pending block 置为 success，再由 transcript 一次性同步 blocks、消息体、搜索文档、usage 与 Tape，最后发布 completed 事件。实现见 `dispatch.ts:2693-2713`，持久化语义见会话与消息管理笔记 §2。
- 异常：dispatch 的出错路径先把 pending 与 loading block 转成 error 并追加错误块，再写入消息错误状态、发布 failed 事件；用户取消生成走单独的错误分支。出错路径见 `dispatch.ts:2715-2735` 与 `transcript.ts:44-70`，取消分支见 `process.ts:359-364`。
- 半截流：流在结束前中断会落到 incomplete 类终态（`INCOMPLETE_PROVIDER_STREAM_ERROR`），终态判定集中在 process 与循环运行器的终态选择函数里；run 结束后由 commitRunTerminal 把结果写进日志与执行台账。循环器侧判定见 `deepChatLoopRunner.ts:332-362`，错误字面量与判定在 `process.ts` 的 49-50 行与 256 行起，落账在 856-859 行。
- 回写频率分三档：流式快照约 120ms 一次，内存与 DB 约 600ms 一次，终态再整体写一次全量。任务结束后，run lifecycle 按处理结果把 session 状态转成 idle 或 error，paused 时保持 generating，见 `src/main/agent/deepchat/runtime/runLifecycleCoordinator.ts:321-362`。

## 7. 停止、重试、续写与重新生成

- **停止（界面 → 网络）**：用户点停止后，界面调用服务层的停止入口，最终交给 run lifecycle 的 cancel：正在进行的生成中断，延后的工具调用与 Provider 权限一并取消；此时还没有开始流的，则把 pending 的工具交互块写成 aborted 终态并调度队列。取消链路见 `chatService.ts:212` 与 `runLifecycleCoordinator.ts:258-306`（界面入口见 Chat UI 笔记 §5），附件准备阶段的取消走另一条路由（`routes.ts:710-718`）。
- **重试**：重试入口取出被重试的 source user 消息，再重新走发送流程；出错且带 steer 回执时允许保留 restart-held 队列。DeepChat 路径会在历史准备前做一次破坏性截断，删除目标位置之后的记录，重试起点因此由恢复上下文构建决定（§2）。入口见 `turn.ts:333-375`，消息准备与截断见 `transcriptMutations.ts:43-73`。
- **续写**：`onMessageContinue` 通过普通发送入口追加本地化的用户指令，不重写目标消息或截断历史；只读、阻塞性交互和同会话重复操作会阻止提交（`src/renderer/src/features/chat-page/composables/useMessageActions.ts:286-304`）。
- **编辑后发送**：编辑操作原地改写 user 消息文本，随后由界面触发的自动重试完成历史截断。改写入口见 `turn.ts:383-390`，文本变更在 `transcriptMutations.ts:85-106`，截断流程见 Chat UI 笔记 §6。
- **队列项恢复**：`retryPendingQueueInput`（`turn.ts:230-242`）→ `PendingInputAdmissionCoordinator.retryPendingQueueInput`（见 §8）。

## 8. 队列、多会话并发与后台生成

- **并发粒度**：同一会话的串行由两层机制保证：session 层的写操作统一经过工作目录上的 session 操作 gate，DeepChat runtime 再用一个 drain lease 确保同一时刻只启动一个 turn。两者分别在 `turn.ts:107-111` 与 `pendingInputPump.ts:407-566` 生效；不同会话各有独立的 runtime scope，彼此不会阻塞。
- **入队与认领**：新的输入进入协调器后，先按当前会话状态判断是立即认领并启动，还是先入队等待；入队路径会在写入前完成附件准备。泵取下一项时优先取 steer 输入，重启后仍被 hold 住的项不会自动启动。判断、入队与泵取分别见 `pendingInputAdmissionCoordinator.ts:104-190` 与 `pendingInputPump.ts:295-494`。
- **失败释放与 retry_required**：turn 失败或回滚时，claim 结算按释放时机分成用户消息落库前释放与回滚后释放两条路径，队列项由此退回可重试状态；turn 内没有 settle 的 claim 会在 finally 里补记。结算逻辑见 `pendingInputPump.ts:149-174`，finally 补记在同文件 546-565 行，数据层语义见会话与消息管理笔记 §1.4。
- **恢复执行**：运行失败而释放的 `retry_required` 项，要逐项重试改回 pending 后才会重新被泵取，返回值里的 accepted 表示状态是否被接受、started 表示是否已经启动。重启时释放但尚未物化的 claimed 项恢复为 pending 并带上 restart hold，在没有阻塞项与 claimed 项且可以泵取时释放 hold；这部分逻辑不处理 `retry_required` 项，仍留给用户显式重试。实现见 `pendingInputAdmissionCoordinator.ts:433-494` 与 `pendingInputs.ts:429-451`。
- **steer 通道**：steer 当前回合与 steer 队列项两条路径都会把输入物化成可见的 user 消息，工具 question/permission 的响应则走另一条独立通道。物化方法见 `turn.ts:192-410`，工具交互响应入口见 `turn.ts:427-437`，数据层语义见会话与消息管理笔记 §1.4。
- 多会话并行生成与"后台（窗口外）生成"：本次在 ChatPage 与 runLifecycle 中未找到后台生成调度入口（检查范围：`turnCoordinator`、`runLifecycleCoordinator`、ChatPage 组合）；不同会话只是各自独立串行执行。

## 9. Agent、工具、知识库与附件注入点

- **工具目录**：本轮请求开始时冻结一份工具面快照：循环运行器解析激活的 skills 与工具目录，subagent 场景按任务契约裁剪工具定义，system prompt 随后按刷新后的技能与工具重新组装。相关实现见 `deepChatLoopRunner.ts:511-698`。
- **工作区 Skill**：当前项目下五类工具目录中的 Skills 会与共享目录合并，但保持 `projectRoot` 作用域和只读属性；离开项目后不进入后续请求。
- **用户插件 hook**：只接受受支持事件的命令型 hook，stdout 必须是匹配事件名的 JSON，且只取文本 `additionalContext`；失败进入诊断，不自动停止模型工作。安装时 Skills、MCP、hooks 分别授权，相关契约见 `src/main/plugin/userPluginPackage.ts:83-168`、`userPluginHooks.ts:445-533`。
- **附件**：附件准备失败时返回 needs_user_action 摘要，摘要里给出两个可选动作：`retry`（重试）与 `send_without_image_content`（不带图片内容直接发送）。准备入口见 `pendingInputAdmissionCoordinator.ts:556-577` 与 `turnCoordinator.ts:497-515`。
- **记忆**：pre-stream 经 `postCompactionPromptAssembler.assemble` 注入（`turnCoordinator.ts:766-788`，contributor 为 `MemoryPromptContributor`）。
- **联网搜索**：开启 search 开关后，搜索诉求会写进 user content；只有 Provider 自带原生搜索且 `searchExecution` 取值为 provider 时才真正启用，见 `turnCoordinator.ts:450-454`。
- **MCP App model context**：保存在 assistant block 的 `extra_json`（`deepchatAssistantBlocks.updateMcpAppModelContext`，数据语义见会话与消息管理笔记 §1.3）。
- 知识库等其余外部能力注入点本次未覆盖。

## 10. 退出恢复、日志与已确认边界

- **启动恢复**：启动时 harness 按固定顺序收口遗留状态：先处理执行日志里的恢复候选，再恢复 queue 与 steer，把 hold 集合交给 pump，之后协调压缩 marker，最后处理其余 pending 消息。入口见 `src/main/agent/deepchat/harness/createDeepChatAgentHarness.ts:495-518`，UI 侧 resume 与逐项重试的呈现见 Chat UI 笔记 §5。
- **可观测性**：主进程按结构化 JSONL 记录任务事件，事件面定义在 `src/main/logging/mainLogEvents.ts`：
  - `agent.run.started` 与 `agent.run.terminal` 携带 runId、sessionId、messageId 关联字段与 stopReason 枚举，位于 921-982 行；
  - `agent.admission.*` 记录输入准入，位于 983-1100 行；
  - `orchestration.delegation.*` 记录委派，位于 1101-1195 行；
  - 关联标识由 `correlationIdentifier` 生成（511-532 行），stopReason 取值见 399-420 行。

  这些事件已具备任务关联所需的字段，本次未运行验证落盘内容与恢复时的回填。
- **已确认边界**：本次静态核对过四条边界：
  - Provider 侧有预检、严格重试与 context-pressure 恢复（§3）；
  - 超预算直接抛 overflow；
  - 手动压缩要求会话非 ACP 且状态为 idle；
  - resume 与 retry 只对 DeepChat session 可用，见 `turn.ts:213-239`。
- 应用退出、切换 session 时任务收口的实时行为本次未运行验证；ACP runtime 的协议 payload 未展开。

## 11. 未验证事项

- 摘要状态、Tape anchor 与 CAS 提交已静态核对；自动压缩触发阈值和完整选段算法未逐行展开，进程崩溃与摘要请求中断的实时表现未运行验证。
- 网络中断、快速切换 session、重复 IPC 事件的流式顺序未运行验证。
- Provider fallback/同 Provider 重试与 context-pressure recovery 的实测效果未验证；重试幂等性（截断后重复执行）未实测。
- 应用退出、窗口关闭时的任务收口未运行验证。
- 未运行测试、构建或桌面端交互；结论来自 main process 静态源码。
- 未运行 workspace Skill 冲突覆盖、用户插件 hook 命令、更新中撤销与恢复后的首次输入；这些路径只完成静态主链核对。
- 判定模型裁剪只做静态核对：`keepThreshold` 自述未标定，判题请求的实际开销、误删后经 Tape 恢复的体验、Provider 不可用时的降级都未运行验证。

## 12. 关键源码索引

- 路由与服务入口：`src/main/session/routes.ts:676-734`、`src/main/session/chatService.ts:77-299`
- turn 操作面：`src/main/session/turn.ts:102-437`
- 任务执行链：`src/main/agent/deepchat/runtime/turnCoordinator.ts:309-956`
- 上下文构建：`src/main/agent/deepchat/runtime/contextBuilder.ts:1577-1824`
- prompt 组装：`src/main/agent/deepchat/runtime/promptAssemblyService.ts:62-140`
- 循环与 provider 管线：`src/main/agent/deepchat/runtime/deepChatLoopRunner.ts:381-780`
- 流式节流与终态：`src/main/agent/deepchat/runtime/echo.ts`、`dispatch.ts`、`process.ts:779`、`runtime/output.ts`（输出 sink）
- 队列协调：`src/main/agent/deepchat/runtime/pendingInputAdmissionCoordinator.ts:104-494`、`pendingInputPump.ts:149-566`
- 压缩：`src/main/agent/deepchat/runtime/compactionService.ts`、`compactionRuntimeCoordinator.ts`
- 判定模型裁剪：`src/main/agent/deepchat/runtime/jevToolResultPruning.ts:602`、`jevReviewState.ts`、`jevPruningFeedback.ts`、`reviewText.ts`
- 停止：`src/main/agent/deepchat/runtime/runLifecycleCoordinator.ts`
- 结构化日志：`src/main/logging/mainLogEvents.ts`
- workspace Skills 与插件上下文：`src/main/skill/index.ts:1295-1322`、`src/main/plugin/userPluginHooks.ts`、`src/main/agent/deepchat/runtime/pluginContext.ts`
