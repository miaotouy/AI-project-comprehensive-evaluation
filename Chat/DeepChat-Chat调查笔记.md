# DeepChat Chat 调查笔记

> 调查对象：`E:\works\git\deepchat`（重点 `src/main/session/turn.ts`、`src/main/session/data/`、`src/renderer/src/stores/ui/`、`src/renderer/src/features/chat-page/`）
>
> 调查更新日期：2026-08-07
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：Chat session 生命周期、SQLite transcript、流式 assistant blocks、IPC/renderer 状态、消息窗口化和模型请求的上下文构建
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat Chat 是 main process 驱动、renderer 订阅的持久化会话系统：

1. Session、Agent backend、Provider runtime 和 transcript 在 main process 运行；renderer 通过 typed route/event 和 preload bridge 调用 `ChatClient`、`SessionClient`。
2. `deepchat_messages` 保存 user/assistant 消息的顺序、内容、状态和 metadata；assistant blocks 另存于 `deepchat_assistant_blocks`，流式更新时两张表分别更新。
3. 用户消息进入后，assistant 先创建 `pending` 占位；流式过程不断替换 assistant blocks，成功结算为 `sent`，异常写入 `error` block 并置为 `error`。
4. `SessionTurn` 同时提供普通发送、steer、queue、retry、delete、edit、fork、manual compaction 和 tool interaction response，pending input 具有独立的 queue/steer 状态。
5. renderer message store 维护持久化缓存、streaming blocks、解析缓存和 IPC 增量事件；`useDisplayMessages` 用稳定 render key 让流式消息在落盘后复用显示对象。消息窗口使用测量、spacer、anchor 和二分查找实现附近消息渲染。

## 调用链

```text
ChatPage
  -> ChatClient/SessionClient（preload bridge）
  -> main SessionTurn
     -> session gate + runtime.pending
     -> SessionTranscript.createUserMessage
     -> createAssistantMessage(status=pending)
     -> Agent/Provider stream
        -> transcript.updateAssistantContent(blocks)
        -> IPC message events
     -> finalizeAssistantMessage(sent) 或 setMessageError(error)
  -> Pinia message/session store
  -> useDisplayMessages
  -> MessageList / MessageListRow
```

## 1. SessionTurn 操作面

`SessionTurn`（`src/main/session/turn.ts:36-405`）提供：

- `sendMessage`：普通发送并等待当前 session gate；
- `steerActiveTurn`：把输入交给正在运行的 turn；
- `queuePendingInput`、更新/移动/steer/delete pending item：维护输入队列；
- `retryMessage`、`deleteMessage`、`editUserMessage`、fork：修改已有 transcript；
- `getCompactionState`、manual compaction：只对支持的 DeepChat session 生效；
- `respondToToolInteraction`：向 question/permission 等工具交互写回答案。

队列记录定义在 `src/shared/types/agent-interface.d.ts:258-275`，其 state 为 `pending`、`claimed`、`blocked`、`consumed`，同时保存 payload、关联 message ids、assistant id、阻塞原因和时间戳。这样，正在生成的 turn 与尚未发送的输入不是同一条消息状态。

## 2. SQLite transcript

`deepchat_messages`（`src/main/session/data/tables/deepchatMessages.ts:8-54`）的核心字段为 `id`、`session_id`、`order_seq`、`role`、`content`、`status`、`metadata`、`created_at`、`updated_at`。状态只定义为 `pending|sent|error`，并按 `(session_id, order_seq)` 建索引。表还提供 cursor 查询和按状态查询（`:157-231`、`:297-330`）。

assistant block 表（`src/main/session/data/tables/deepchatAssistantBlocks.ts:76-115`）以 `message_id + block_index` 保存结构化 block，包含 type、content、status、extra JSON 和更新时间；`replaceForMessage` 用一次替换保持 block 顺序。MCP App model context 也在该表的 extra JSON 中更新（`:223-264`）。

`SessionTranscript`（`src/main/session/data/transcript.ts:166-381`）的典型生命周期：

```text
createUserMessage(...)
  -> createAssistantMessage(... status=pending)
  -> updateAssistantContent(...)
       replace assistant blocks + 保持 pending
  -> finalizeAssistantMessage(... status=sent)
  或 setMessageError(... status=error)
```

完成和错误路径都同步更新 assistant block、message content/status、搜索文档和 Tape facts；流式中间态只更新 blocks 和 pending 状态（`:264-281`、`:329-381`）。

## 3. Main/renderer 通信与状态

renderer 的 `ChatClient`、`SessionClient` 通过 typed API 调用 main process，ChatPage 在 `src/renderer/src/features/chat-page/ChatPage.vue:86-232` 组合消息列表、输入框、pending input lane、plan/question 浮层、只读 interaction overlay；subagent session 被标记为只读（`:431-435`）。

message store 的核心状态包括 `messageCache`、`streamingBlocks`、当前 stream session/message id、`streamRevision` 和游标分页；其 IPC 事件处理在 `src/renderer/src/stores/ui/message.ts` 的消息加载、stream update 和 session reset 分支中。session store 另存 active session、working/error 状态和 project/agent 关联。

`useDisplayMessages`（`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:341-425`）按持久化 id 重建显示列表：

1. 先从 message cache 读取当前 session 的消息并转换为 DisplayMessage；
2. 若 stream record 尚未进入有序 id 列表，临时插入当前 stream message；
3. 保留 settled display-message 对象的转换缓存；
4. 用 `assistantRenderKeyByMessageId` 把 pending assistant 和最终落盘的同一消息关联，减少 DOM 替换。

## 4. 消息窗口化

`MessageList`/`MessageListRow` 只接收当前窗口的 `MessageListItem`（`src/renderer/src/components/chat/MessageList.vue:1-65`）。`useMessageWindow` 以估算高度、实际 ResizeObserver 测量、顶部/底部 spacer 和逻辑 anchor 保存滚动位置；`useMessageVirtualization` 在消息超过阈值时用二分查找确定 viewport 附近的索引范围。ChatPage 在 session 切换和消息追加后保存/恢复 measurement snapshot（`:512-584`、`:728-826`）。

该窗口化策略同时服务历史分页和流式追加：streaming 行保持可见，远离 viewport 的 settled 消息仅保留估算高度，不等同于一次性把全部历史消息挂载到 DOM。

## 5. Chat 交互边界

- `steer`、`queue`、工具 question/permission response 均作为 session turn 的独立输入通道；其交互 UI 不会把 pending input 直接拼进已完成消息。
- 失败 assistant 消息保留 `error` 状态和错误 block，用户可通过 retry/fork 等操作再次产生新 turn。
- subagent session 在 ChatPage 中只读，但仍能显示消息、plan、工具状态和最终 child result。
- transcript 同时服务展示、搜索、Tape 和 usage/trace 等二级数据；本次未追踪所有附件、搜索结果和 legacy import 表的完整迁移链。

## 6. 边界与未验证事项

- SQLite 使用 `better-sqlite3-multiple-ciphers`，但本次未验证实际数据库加密配置、事务隔离和崩溃恢复。
- 流式 block 的 IPC 顺序依赖 renderer revision/cursor；未运行网络中断、快速切换 session 或重复事件场景。
- 消息窗口高度是估算与观测的组合，复杂 artifact/图片导致的异步高度变化未通过浏览器实测。
- 未运行测试、构建或桌面端交互；结论来自 main/renderer 静态源码。

## 7. 消息构建流程

1. **输入与 UI 消息对象**：`SessionTurn.sendMessage`（`src/main/session/turn.ts:102-145`）接收字符串或 `SendMessageInput`，先经 `normalizeSendMessageInput`，再调用当前 session runtime 的 `send`。附件仍属于 normalized input；无法接受附件时返回 `needs_user_action`（`:145-146`）。
2. **历史筛选**：`runtime/contextBuilder.ts:1501-1512` 从 transcript 取得候选记录，过滤为 context history，并从 summary cursor 开始构建 history turns。`buildCacheAwareResumeContextWithMetadata`（`:1614-1639`）在重试/恢复时按 `orderSeq` 取到目标 assistant 为止的记录，并保留其所属 user turn；该函数本身没有按父子关系回溯分支。
3. **system prompt、记忆、附件与工具**：`promptAssemblyService.ts:59-73` 通过 `buildSystemPromptWithSkills` 组合基础 system prompt、技能和工具定义；压缩后的恢复 prompt 还在 `:89-104` 注入 checkpoint、memory 和 directives。`deepChatLoopRunner.ts:375-398` 解析 active skills 与工具目录，生成本轮 tool catalog。
4. **截断与压缩**：`contextBuilder.ts:1513-1589` 计算固定 prompt/新 user 消息和历史 token，超预算时先移除 memory，再移除 directives，最后按完整 tail turns 选择历史；固定内容仍超物理预算则抛出 overflow。运行时还通过 `deepChatLoopRunner.ts:479-548` 做 provider 预检、严格重试和 context-pressure recovery。
5. **最终请求与 Provider**：`contextBuilder` 返回 `leadingMessages + selected history + new user message`；`deepChatLoopRunner.ts:447-469` 将其交给 `processStream`，`:489-528` 以 `requestMessages`、model、temperature、maxTokens、tools 进入 provider attempt 管线。assistant 流式 block 再写回 transcript，形成下一轮候选历史。
6. **边界**：源码确认了 DeepChat agent 的消息选择、预算和降级顺序；ACP runtime 的具体外部协议 payload 未在本次专题中展开。

## 8. 关键源码索引

- turn 操作：`src/main/session/turn.ts:36-405`
- pending input DTO：`src/shared/types/agent-interface.d.ts:258-275`
- message 表与状态：`src/main/session/data/tables/deepchatMessages.ts:8-54`、`:157-231`
- assistant block 表：`src/main/session/data/tables/deepchatAssistantBlocks.ts:76-115`、`:223-264`
- transcript 生命周期：`src/main/session/data/transcript.ts:166-381`
- session 字段：`src/main/session/data/tables/newSessions.ts:13-30`
- ChatPage 组合：`src/renderer/src/features/chat-page/ChatPage.vue:86-232`、`:431-435`
- display message 稳定缓存：`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:341-425`
- 消息窗口和滚动恢复：`src/renderer/src/features/chat-page/ChatPage.vue:512-584`、`:728-826`
- 消息列表组件：`src/renderer/src/components/chat/MessageList.vue:1-65`
