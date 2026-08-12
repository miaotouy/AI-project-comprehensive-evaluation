# DeepChat 会话与消息管理调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：从 [`../Chat/DeepChat-Chat调查笔记.md`](../Chat/DeepChat-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据；按提交范围 `dc4177c2..e142b2a` 核对 pending input 数据模型（retry_required/重启恢复）与 turn 的新操作
>
> 调查范围：会话与消息的持久化模型（SQLite transcript 与 assistant blocks）、renderer 缓存与 IPC 增量、消息窗口数据分页接口、会话内/跨会话搜索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 main process 驱动、renderer 订阅的持久化会话系统：

- `deepchat_messages` 保存 user/assistant 消息的顺序、内容、状态和 metadata；assistant blocks 另存于 `deepchat_assistant_blocks`，流式更新时两张表分别更新。
- 用户消息进入后，assistant 先创建 `pending` 占位；流式过程不断替换 assistant blocks，成功结算为 `sent`，异常写入 `error` block 并置为 `error`。
- 消息事实源是 main process 的 SQLite；renderer message store 维护持久化缓存、streaming blocks、解析缓存和 IPC 增量事件，`useDisplayMessages` 用稳定 render key 让流式消息在落盘后复用显示对象。
- 消息窗口按"估算测量 + spacer + anchor + 二分查找"只接收当前窗口的 `MessageListItem`，同时服务历史分页和流式追加。
- 搜索分两层：会话内查找只搜已加载窗口，跨会话 FTS5（触发器同步）+ LIKE 回退，命中直接定位到消息。

## 系统边界与数据主链

```text
SessionTurn（执行侧 -> 对话请求与上下文）
  -> SessionTranscript.createUserMessage
  -> createAssistantMessage(status=pending)
  -> updateAssistantContent(blocks)（流式，双表分别更新）
  -> finalizeAssistantMessage(sent) 或 setMessageError(error)
      同步更新 assistant block、message content/status、搜索文档和 Tape facts
  -> IPC message events -> Pinia message/session store（持久化缓存）
  -> useDisplayMessages -> MessageList 窗口（数据分页接口，DOM 侧见消息渲染器笔记）
```

边界：上下文如何从 transcript 构建请求、流式事件如何产生属于对话请求与上下文；ChatPage 组合与搜索入口工作流属于 Chat UI（`<../Chat UI/DeepChat-ChatUI调查笔记.md>`）；消息壳、内容渲染与滚动锚定属于消息渲染器（`../消息渲染器/DeepChat-消息渲染器调查笔记.md`），本文只记录数据形状与分页接口。

## 1. 会话、消息与分支数据模型

### 1.1 消息表与状态

`deepchat_messages`（`src/main/session/data/tables/deepchatMessages.ts:8-54`）的核心字段为 `id`、`session_id`、`order_seq`、`role`、`content`、`status`、`metadata`、`created_at`、`updated_at`。状态只定义为 `pending|sent|error`，并按 `(session_id, order_seq)` 建索引。表还提供 cursor 查询和按状态查询（`:157-231`、`:297-330`）。

### 1.2 assistant block 表

assistant block 表（`src/main/session/data/tables/deepchatAssistantBlocks.ts:76-115`）以 `message_id + block_index` 保存结构化 block，包含 type、content、status、extra JSON 和更新时间；`replaceForMessage` 用一次替换保持 block 顺序。MCP App model context 也在该表的 extra JSON 中更新（`:223-264`）。

### 1.3 pending input 是独立状态对象

队列记录定义在 `src/shared/types/agent-interface.d.ts:259-281`，其 state 为 `pending`、`claimed`、`blocked`、`retry_required`、`consumed`，同时保存 payload、关联 message ids、assistant id、阻塞原因和时间戳。这样，正在生成的 turn 与尚未发送的输入不是同一条消息状态（队列的投递与执行语义见对话请求与上下文笔记 §8）。

**本次新增（提交范围 `dc4177c2..e142b2a`，源码确认）**：

- **`retry_required` 状态**（#2137）：持久化形态是 `state='blocked'` + `retry_required_at` 列非空（`deepchatPendingInputs.ts` 新增列与 schema v67 迁移，`:65-88` 的 `normalizeRetryRequiredRows` 把旧 `retry_required` 行规范化为该形态）；`SessionPendingInputStore` 在读取时经 `getRowState` 还原为 `retry_required`（`pendingInputStore.ts:561-582`）。该状态表示 queue 项曾被 claimed 但未物化为用户消息，由 `releaseClaimedQueueInputForRetry` 进入、`retryReleasedQueueInput` 回到 `pending`（`:349-383`）。
- **重启恢复**（831b820/e41c08e）：`SessionPendingInputs.recoverInputsAfterRestart`（`pendingInputs.ts:392-468`）返回 `{ affectedSessionIds, heldQueueInputIds }`——claimed 且有物化 user 消息的 queue 项置 consumed，否则释放回队列并登记 held；steer 输入中未读的 pending 用户消息标记为 error（`failPendingSteerMessages`，`transcript.ts:358-385`）；另有 `getPendingAssistantMessages`（`transcript.ts:448-452`）供恢复分类使用。

### 1.4 分支与版本

`SessionTurn` 提供 fork 操作（`src/main/session/turn.ts:36-405`），但源笔记未记录 fork 在持久化层的数据形状（是否复制消息、父子关系如何表达未调查）。会话字段（`src/main/session/data/tables/newSessions.ts:13-30`）本次未展开其持久化字段细节。

## 2. 事实源、索引与持久化

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

搜索文档与命中快照：

- 完成/错误路径把消息内容写入 `deepchat_search_documents` 表（`src/main/session/data/tables/deepchatSearchDocuments.ts:47-56`，`document_kind: 'session'|'message'`，:9）。
- SQLite FTS5 虚拟表 `deepchat_search_documents_fts`（:280-287，content=外部内容表）带 `ai/ad/au` 三个触发器保持同步（:309-335）；查询用 `searchFts`（:210-241，bm25 排序、按 token 做短语 AND 匹配），FTS5 不可用或未兼容时回退 `searchLike`（:243-265，`LIKE '%term%'` 标题+内容扫描）。
- `deepchat_message_search_results` 表（`src/main/session/data/tables/deepchatMessageSearchResults.ts:21-40`，含 `message_id/search_id/rank/content/dedupe_key`）保存一次搜索的命中快照；本次未追踪其完整生命周期（写入触发点与清理策略未展开）。

## 3. 创建、切换、归档、删除与恢复

迁移范围内未覆盖会话的创建/删除/归档的持久化实现（源笔记未调查该部分）；已知会话以 `newSessions` 表保存（`src/main/session/data/tables/newSessions.ts:13-30`），字段细节未展开。renderer session store 的 active session、working/error 状态与 project/agent 关联属于 Chat UI 笔记 §5（UI 状态所有权）。

## 4. 编辑、重试、续写、回退与分支语义

`SessionTurn`（`src/main/session/turn.ts:36-405`）提供 `retryMessage`、`deleteMessage`、`editUserMessage`、fork 等修改已有 transcript 的操作，以及 `getCompactionState`、manual compaction（只对支持的 DeepChat session 生效）和 `respondToToolInteraction`。本次新增 `isPendingQueueResumeAvailable`/`resumePendingQueue`/`retryPendingQueueInput`（`turn.ts:213-244`，只对 DeepChat session 生效），路由 `sessionsResumePendingQueueRoute`/`sessionsRetryPendingQueueInputRoute`（`src/main/session/routes.ts:265-287`）；`sessionsListPendingInputsRoute` 现在返回 `{ items, resumeAvailable }`（`:247-266`）。这些操作在持久化层的数据语义（retry 是否复制消息、delete 是否物理删除、fork 的父子关系）本次未展开。失败 assistant 消息保留 `error` 状态和错误 block，用户可通过 retry/fork 等操作再次产生新 turn；重试/恢复时如何选择起始上下文见对话请求与上下文笔记 §7。

## 5. 列表、分页、搜索与定位

### 5.1 消息窗口的数据分页接口

`MessageList`/`MessageListRow` 只接收当前窗口的 `MessageListItem`（`src/renderer/src/components/chat/MessageList.vue:1-65`）。`useMessageWindow` 以估算高度、实际 ResizeObserver 测量、顶部/底部 spacer 和逻辑 anchor 保存滚动位置；`useMessageVirtualization` 在消息超过阈值时用二分查找确定 viewport 附近的索引范围。ChatPage 在 session 切换和消息追加后保存/恢复 measurement snapshot（`:512-584`、`:728-826`）。

该窗口化策略同时服务历史分页和流式追加：streaming 行保持可见，远离 viewport 的 settled 消息仅保留估算高度，不等同于一次性把全部历史消息挂载到 DOM。本类目记录的是数据分页接口；窗口化、滚动锚定与消息壳的 DOM 实现见消息渲染器笔记 §6（该笔记把此主题列为交接点，不重复展开）。

### 5.2 会话内查找

`useChatSearch`（`src/renderer/src/features/chat-page/composables/useChatSearch.ts`）在已加载的 display messages 上做匹配，配合 `src/renderer/src/lib/chatSearch` 的高亮应用、命中计数与定位；导航复用共享滚动控制器（`requestChatScroll('search-navigation', ...)`），不与流式自动跟随冲突。该路径只搜索当前窗口已加载的消息，不触发数据库查询（搜索入口与定位工作流见 Chat UI 笔记 §2）。

### 5.3 跨会话全文搜索

- 索引与查询见 §2（FTS5 + 触发器 + LIKE 回退）。
- 服务入口：内存 MCP 服务器 `conversationSearchServer`（`src/main/mcp/inMemoryServers/conversationSearchServer.ts`）暴露 `search_conversations`、`search_messages`、`get_conversation_history`、`get_conversation_stats`（:465-494），即跨会话搜索同时服务于模型工具与设置页。
- 边界：搜索命中直接定位到消息（message_id），可滚动到目标行；会话列表侧未见独立的会话名搜索路由，跨会话入口以 `search_conversations` 工具为主。

## 6. 缓存、一致性、多窗口与并发写入

message store 的核心状态包括 `messageCache`、`streamingBlocks`、当前 stream session/message id、`streamRevision` 和游标分页；其 IPC 事件处理在 `src/renderer/src/stores/ui/message.ts` 的消息加载、stream update 和 session reset 分支中。session store 另存 active session、working/error 状态和 project/agent 关联（后者见 Chat UI 笔记 §5）。

`useDisplayMessages`（`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:341-425`）按持久化 id 重建显示列表：

1. 先从 message cache 读取当前 session 的消息并转换为 DisplayMessage；
2. 若 stream record 尚未进入有序 id 列表，临时插入当前 stream message；
3. 保留 settled display-message 对象的转换缓存；
4. 用 `assistantRenderKeyByMessageId` 把 pending assistant 和最终落盘的同一消息关联，减少 DOM 替换。

一致性与未验证：流式 block 的 IPC 顺序依赖 renderer revision/cursor；未运行网络中断、快速切换 session 或重复事件场景（见 §10）。

## 7. 迁移、导入导出与保留策略

源笔记提及 legacy import 表（"本次未追踪所有附件、搜索结果和 legacy import 表的完整迁移链"，见 Chat 笔记 §6）；导入导出、数据库迁移和崩溃恢复策略本次未调查。

## 8. Agent、模型、知识库与附件绑定

- 会话、Agent backend、Provider runtime 在 main process 运行；renderer 通过 typed route/event 和 preload bridge 调用 `ChatClient`、`SessionClient`。
- 附件仍属于 normalized input（`SendMessageInput`），无法接受附件时返回 `needs_user_action`（执行语义见对话请求与上下文笔记 §1）。
- MCP App model context 保存在 assistant block 表的 extra JSON 中（§1.2）。
- 会话级绑定的持久化字段（`newSessions.ts:13-30`）本次未展开。

## 9. 设计取舍与已确认边界

- transcript 同时服务展示、搜索、Tape 和 usage/trace 等二级数据，一条消息的完成/错误路径承担全部同步更新。
- 失败 assistant 消息保留 `error` 状态和错误 block，而不是静默丢弃；用户可通过 retry/fork 再次产生新 turn。
- subagent session 在 ChatPage 中只读，但仍能显示消息、plan、工具状态和最终 child result（界面边界见 Chat UI 笔记 §4）。
- 消息窗口分页与流式追加共用同一机制（§5.1）。
- 搜索分两层实现：内存匹配（不触发数据库）与 FTS5 全文索引（§5.2/§5.3）。

## 10. 未验证事项

- SQLite 使用 `better-sqlite3-multiple-ciphers`，但本次未验证实际数据库加密配置、事务隔离和崩溃恢复。
- 流式 block 的 IPC 顺序依赖 renderer revision/cursor；未运行网络中断、快速切换 session 或重复事件场景。
- 消息窗口高度是估算与观测的组合，复杂 artifact/图片导致的异步高度变化未通过浏览器实测。
- fork/delete/edit 的持久化数据语义、搜索结果命中快照的清理策略未展开。
- 未运行测试、构建或桌面端交互；结论来自 main/renderer 静态源码。

## 11. 关键源码索引

- message 表与状态：`src/main/session/data/tables/deepchatMessages.ts:8-54`、`:157-231`
- assistant block 表：`src/main/session/data/tables/deepchatAssistantBlocks.ts:76-115`、`:223-264`
- transcript 生命周期：`src/main/session/data/transcript.ts:166-381`
- pending input DTO：`src/shared/types/agent-interface.d.ts:259-281`
- pending input 表与迁移：`src/main/session/data/tables/deepchatPendingInputs.ts`（`retry_required_at`、schema v67）
- pending input store 与恢复：`src/main/session/data/pendingInputStore.ts:349-383`、`src/main/session/data/pendingInputs.ts:392-468`
- 会话字段：`src/main/session/data/tables/newSessions.ts:13-30`
- turn 操作：`src/main/session/turn.ts:36-405`、`:213-244`（resume/retry queue）
- 会话内查找：`src/renderer/src/features/chat-page/composables/useChatSearch.ts`、`src/renderer/src/lib/chatSearch`
- 跨会话 FTS 搜索：`src/main/session/data/tables/deepchatSearchDocuments.ts:47-56`、`:210-265`、`:309-335`、`src/main/mcp/inMemoryServers/conversationSearchServer.ts:465-494`
- display message 稳定缓存：`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:341-425`
- 消息窗口和滚动恢复（数据分页侧）：`src/renderer/src/features/chat-page/ChatPage.vue:512-584`、`:728-826`
- 消息列表组件（窗口接口）：`src/renderer/src/components/chat/MessageList.vue:1-65`
- renderer message store：`src/renderer/src/stores/ui/message.ts`
