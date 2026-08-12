# DeepChat 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：从 [`../Chat/DeepChat-Chat调查笔记.md`](../Chat/DeepChat-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据；按提交范围 `dc4177c2..e142b2a` 核对 turn 新增的 queue resume/retry 操作
>
> 调查范围：一次生成任务的提交入口（sendMessage/steer/queue/retry/delete/edit/fork/compaction/tool interaction）、上下文构建、预算截断与压缩、Provider 交接与流式回写；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的生成任务由 main process 的 `SessionTurn` 编排，session gate 保证单会话串行：

1. `sendMessage` 经 `normalizeSendMessageInput` 规范化输入后交给 session runtime 的 `send`；assistant 先创建 `pending` 占位再流式更新。
2. 上下文构建分四步：历史筛选（含 summary cursor 与重试恢复起点）→ system prompt/记忆/附件/工具组装 → 预算截断（先移除 memory、再 directives、最后选完整 tail turns）→ 固定内容仍超物理预算则抛出 overflow。
3. 运行时对 provider 做预检、严格重试和 context-pressure recovery。
4. 流式 assistant blocks 写回 transcript，形成下一轮候选历史；成功结算为 `sent`，异常写入 `error` block。
5. steer、queue、工具 question/permission response 是独立的输入通道，不把 pending input 直接拼进已完成消息。

## 系统边界与生成任务主链

```text
ChatPage（preload bridge）
  -> SessionTurn.sendMessage（或 steer/queue/respondToToolInteraction）
     -> session gate + runtime.pending
     -> SessionTranscript.createUserMessage
     -> createAssistantMessage(status=pending)
     -> Agent/Provider stream（contextBuilder 构建请求）
        -> transcript.updateAssistantContent(blocks)
        -> IPC message events
     -> finalizeAssistantMessage(sent) 或 setMessageError(error)
```

边界：消息与 block 的持久化形状、搜索结果与 Tape 的同步写入属于会话与消息管理（`../会话与消息管理/DeepChat-会话与消息管理调查笔记.md`）；ChatPage 的输入框、pending lane 与只读交互浮层属于 Chat UI（`<../Chat UI/DeepChat-ChatUI调查笔记.md>`）；工具执行循环内部语义属于 Agent 工具类目。

## 1. 提交入口、任务对象与状态机

`SessionTurn`（`src/main/session/turn.ts:36-405`）提供：

- `sendMessage`：普通发送并等待当前 session gate；
- `steerActiveTurn`：把输入交给正在运行的 turn；
- `queuePendingInput`、更新/移动/steer/delete pending item：维护输入队列；
- `resumePendingQueue`、`retryPendingQueueInput`（#2137，`turn.ts:213-244`）：暂停/被释放的队列输入恢复执行——`retry_required` 项经 `retryPendingQueueInput` 重新进入 pending 并启动，`isPendingQueueResumeAvailable` 供 UI 判断恢复可用性（数据模型见会话与消息管理笔记 §1.3）；
- `retryMessage`、`deleteMessage`、`editUserMessage`、fork：修改已有 transcript（数据语义见会话与消息管理笔记 §4）；
- `getCompactionState`、manual compaction：只对支持的 DeepChat session 生效；
- `respondToToolInteraction`：向 question/permission 等工具交互写回答案。

`sendMessage`（`src/main/session/turn.ts:102-145`）接收字符串或 `SendMessageInput`，先经 `normalizeSendMessageInput`，再调用当前 session runtime 的 `send`。附件仍属于 normalized input；无法接受附件时返回 `needs_user_action`（`:145-146`）。占位与结算的状态机见 §6；pending input 的队列数据模型（state：`pending|claimed|blocked|retry_required|consumed`，`agent-interface.d.ts:259-281`）见会话与消息管理笔记 §1.3。

## 2. 历史选择与上下文拼装顺序

- **历史筛选**：`runtime/contextBuilder.ts:1501-1512` 从 transcript 取得候选记录，过滤为 context history，并从 summary cursor 开始构建 history turns。
- **重试/恢复起点**：`buildCacheAwareResumeContextWithMetadata`（`:1614-1639`）在重试/恢复时按 `orderSeq` 取到目标 assistant 为止的记录，并保留其所属 user turn；该函数本身没有按父子关系回溯分支。
- **system prompt、记忆、附件与工具**：`promptAssemblyService.ts:59-73` 通过 `buildSystemPromptWithSkills` 组合基础 system prompt、技能和工具定义；压缩后的恢复 prompt 还在 `:89-104` 注入 checkpoint、memory 和 directives。`deepChatLoopRunner.ts:375-398` 解析 active skills 与工具目录，生成本轮 tool catalog。
- **最终顺序**：`contextBuilder` 返回 `leadingMessages + selected history + new user message`（见 §4）。

## 3. 预算、截断、摘要与压缩

`contextBuilder.ts:1513-1589` 计算固定 prompt/新 user 消息和历史 token，超预算时先移除 memory，再移除 directives，最后按完整 tail turns 选择历史；固定内容仍超物理预算则抛出 overflow。运行时还通过 `deepChatLoopRunner.ts:479-548` 做 provider 预检、严格重试和 context-pressure recovery。manual compaction 由 `SessionTurn.getCompactionState` 触发，只对支持的 DeepChat session 生效（压缩的具体算法与摘要存储本次未展开，见 §11）。

## 4. SDK、Provider、模型与协议交接

`deepChatLoopRunner.ts:447-469` 把 contextBuilder 结果交给 `processStream`，`:489-528` 以 `requestMessages`、model、temperature、maxTokens、tools 进入 provider attempt 管线。assistant 流式 block 再写回 transcript，形成下一轮候选历史。ACP runtime 的具体外部协议 payload 未在本次专题中展开（边界见 §10）。

## 5. 流式事件、缓冲、节流与顺序

流式过程不断替换 assistant blocks；renderer 端经 IPC 增量事件接收（主进程 120ms 节流快照与 DB 600ms 节流落盘，由生成侧 `echo.ts` 控制，`src/main/agent/deepchat/runtime/echo.ts:7-8`；详细链路见消息渲染器笔记 §8 与生成式输出与运行时笔记）。renderer 侧 stream revision/cursor 与缓存合并语义见会话与消息管理笔记 §6；IPC 顺序依赖 revision/cursor，未运行网络中断与快速切换场景（§11）。

## 6. 完成、异常、半截流与最终回写

transcript 生命周期（`src/main/session/data/transcript.ts:166-381`）：

```text
createUserMessage(...)
  -> createAssistantMessage(... status=pending)
  -> updateAssistantContent(...)（replace assistant blocks + 保持 pending）
  -> finalizeAssistantMessage(... status=sent)
  或 setMessageError(... status=error)
```

完成和错误路径都同步更新 assistant block、message content/status、搜索文档和 Tape facts；流式中间态只更新 blocks 和 pending 状态（`:264-281`、`:329-381`）。数据语义（两表分别更新的持久化形状）见会话与消息管理笔记 §1-2。

## 7. 停止、重试、续写与重新生成

- 重试/恢复时的起始上下文由 `buildCacheAwareResumeContextWithMetadata`（`contextBuilder.ts:1614-1639`）按 `orderSeq` 决定：取到目标 assistant 为止的记录并保留其所属 user turn；该函数没有按父子关系回溯分支（分支数据语义见会话与消息管理笔记 §1.4）。
- 失败 assistant 消息保留 `error` 状态和错误 block，用户可通过 retry/fork 等操作再次产生新 turn（操作入口见 Chat UI 笔记；数据语义见会话与消息管理笔记 §4）。
- 停止与续写：源笔记未记录独立的"停止网络请求"与"续写"执行链，本次未调查。

## 8. 队列、多会话并发与后台生成

- 并发粒度是单 session gate：`sendMessage` 等待当前 session gate；运行中通过 `steerActiveTurn` 打断、`queuePendingInput` 排队。
- 队列记录（`src/shared/types/agent-interface.d.ts:259-281`）保存 payload、关联 message ids、assistant id、阻塞原因和时间戳，state 为 `pending|claimed|blocked|retry_required|consumed`；其数据模型与重启恢复语义见会话与消息管理笔记 §1.3。
- **队列释放与重试（#2137，源码确认）**：claimed 队列输入若因异常被释放且未物化为用户消息，进入 `retry_required`（而不是静默回到队列或丢弃）；`retryPendingQueueInput` 把该项重新置 pending 并启动新一轮 turn，`resumePendingQueue` 恢复整个暂停的队列（运行 gate 内执行，只对 DeepChat session 可用）。
- 工具 question/permission response 通过 `respondToToolInteraction` 写回答案，是独立于 sendMessage 的输入通道。
- 多会话并行生成与后台任务本次未调查。

## 9. Agent、工具、知识库与附件注入点

- 工具目录：`deepChatLoopRunner.ts:375-398` 解析 active skills 与工具目录，生成本轮 tool catalog；system prompt 组合见 §2。
- MCP App model context 保存在 assistant block 表的 extra JSON 中，随 block 更新（数据语义见会话与消息管理笔记 §1.2）。
- 附件作为 normalized input 的一部分随用户消息进入（§1）；知识库/联网等外部能力注入点本次未在源笔记中覆盖。

## 10. 退出恢复、日志与已确认边界

- 已确认：provider 预检、严格重试、context-pressure recovery（`deepChatLoopRunner.ts:479-548`）、overflow 抛出与 manual compaction 限制（§3）。
- 边界：ACP runtime 的具体外部协议 payload 未展开；应用退出、切换 session 时的任务收口本次未调查。新增结构化主进程 JSONL 日志（`src/main/logging/`，#2141，替代 `electron-log`），事件面覆盖 run/turn 生命周期（`mainLogEvents.ts` 的 `run_*`/`turn_*` 事件，含 runId/sessionId 关联字段），任务与日志的关联面已具备基础设施，但本次未运行验证其落盘内容与恢复时的回填。
- 队列恢复：应用重启后 `recoverInputsAfterRestart` 收口 claimed/steer 输入（数据侧见会话与消息管理笔记 §1.3），UI 侧 resume 动作见 Chat UI 笔记 §3。

## 11. 未验证事项

- 压缩/compaction 的具体算法、摘要存储与恢复路径未展开（源笔记只确认了入口）。
- 网络中断、快速切换 session、重复 IPC 事件的流式顺序未运行验证。
- 多会话并发、退出恢复未调查。
- 未运行测试、构建或桌面端交互；结论来自静态源码。

## 12. 关键源码索引

- turn 操作：`src/main/session/turn.ts:36-405`（sendMessage :102-145，queue resume/retry :213-244）
- pending input DTO：`src/shared/types/agent-interface.d.ts:259-281`
- 历史筛选与上下文构建：`src/main/agent/deepchat/runtime/contextBuilder.ts:1501-1589`、`:1614-1639`
- system prompt 组装：`src/main/agent/deepchat/runtime/promptAssemblyService.ts:59-73`、`:89-104`
- 工具目录与 provider 管线：`src/main/agent/deepchat/runtime/deepChatLoopRunner.ts:375-398`、`:447-548`
- transcript 生命周期：`src/main/session/data/transcript.ts:166-381`
- 节流源：`src/main/agent/deepchat/runtime/echo.ts:7-8`
- 结构化日志：`src/main/logging/mainLogEvents.ts`（run/turn 事件）
