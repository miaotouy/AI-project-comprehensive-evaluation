# DeepChat 会话与消息管理调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：直接阅读源码（main process 的 SQLite 表定义与 transcript/pending input 数据层、turn 与路由、renderer 的 message store 与 IPC 增量层），静态核对符号与行号；未运行测试、构建或桌面端交互
>
> 调查范围：会话、消息与分支的数据模型与事实源、创建/切换/删除/恢复生命周期、编辑/重试/分支语义、列表分页与双层搜索、缓存一致性与多窗口、schema 版本升级、外部对象绑定；生成任务的执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 main process 驱动、renderer 订阅的持久化会话系统：

- 会话事实源是 `new_sessions`（agent/title/project_dir/置顶/草稿/子会话/编排策略等）加 `deepchat_sessions`（provider/model/权限模式/生成设置等运行时状态），id 由 main process 用 nanoid 生成（`src/main/agent/shared/appSessionService.ts:71`）。
- `deepchat_messages` 保存 user/assistant 消息的顺序（`order_seq`）、内容、状态（仅 `pending|sent|error`）和 metadata；assistant 的结构化 blocks 另存于 `deepchat_assistant_blocks`，流式更新时两表分别写入（blocks 表 + 消息表 status 保持 pending）。
- 消息事实源是 main process 的 SQLite；renderer message store 维护持久化缓存、解析缓存与 IPC 增量，`useDisplayMessages` 用稳定 render key 让流式消息在落盘后复用显示对象。
- 队列输入是独立的 `deepchat_pending_inputs` 状态对象（`pending|claimed|blocked|retry_required|consumed`），与已完成消息不混同；重启恢复把 claimed 未物化的 queue 项释放回队列（`retry_required` 形态）、未读 steer 消息置 error。
- 消息窗口按"估算测量 + spacer + anchor + 二分查找"只接收当前窗口的 `MessageListItem`，同时服务历史分页和流式追加。
- 搜索分三层：会话内查找只匹配已加载的 display messages；跨会话历史搜索走 FTS5（触发器同步 + LIKE 回退），经 `sessionsSearchHistoryRoute` 服务 Spotlight；内存 MCP 服务器另把同一索引暴露为模型工具。

## 系统边界与数据主链

```text
SessionTurn（执行侧 -> 对话请求与上下文笔记）
  -> SessionTranscript.createUserMessage
  -> createAssistantMessage(status=pending)
  -> updateAssistantContent(blocks)（流式，blocks 表 + 消息表状态分别更新）
  -> finalizeAssistantMessage(sent) 或 setMessageError(error)
       同步更新 assistant blocks、message content/status、搜索文档、usage 与 Tape facts
  -> IPC message/stream 事件 -> Pinia message store（持久化缓存 + 解析缓存）
  -> useDisplayMessages -> MessageList 窗口（数据分页接口，DOM 侧见消息渲染器笔记）
```

边界：上下文如何从 transcript 构建请求、流式事件如何产生属于对话请求与上下文（`../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md`）；ChatPage 组合、搜索入口与 pending lane 工作流属于 Chat UI（`../Chat UI/DeepChat-ChatUI调查笔记.md`）；消息壳、内容渲染与滚动锚定属于消息渲染器。本文只记录数据形状、事实源与分页/查询接口。

## 1. 会话、消息与分支数据模型

### 1.1 会话表与状态

`NewSessionRow`（`src/main/session/data/tables/newSessions.ts:13-30`）：`id/agent_id/title/project_dir/is_pinned/is_draft/active_skills/disabled_agent_tools/subagent_enabled/session_kind（regular|subagent）/parent_session_id/subagent_meta_json/orchestration_policy/created_at/updated_at/revision`。表建索引 `idx_new_sessions_agent` 与 `idx_new_sessions_updated`（updated_at DESC，:92-93），列表默认按 `updated_at DESC` 排序（:247）。会话 id 在 `appSessionService.create` 内用 nanoid 生成（`src/main/agent/shared/appSessionService.ts:71`）。

runtime 级状态在 `deepchat_sessions`（`src/main/session/data/tables/deepchatSessions.ts`）：`provider_id/model_id/permission_mode` 及生成设置 JSON（:39-54），即"模型绑定"的持久化位置（见 §8）。

### 1.2 消息表与状态

`deepchat_messages`（`src/main/session/data/tables/deepchatMessages.ts:42-56` 建表 SQL；行接口 :4-16）：`id/session_id/order_seq/role（user|assistant）/content/status（仅 pending|sent|error，:10）/is_context_edge/metadata/created_at/updated_at`，按 `(session_id, order_seq)` 建索引（:54）。消息 id 由 `SessionTranscript` 用 nanoid 生成（`src/main/session/data/transcript.ts:189`、:207）。

查询面：`listPageBySession`（:177-229，`(order_seq, id)` 游标降序分页，内联 trace_count 计数）、`getBySessionUpToOrderSeq`（:231-237）、`getByStatus`（:252-256）、`getLastUserMessageBeforeOrAtOrderSeq`（:360-369）、`recoverPendingMessages`（:397-404，把所有 pending 置 error，供启动恢复兜底）。

### 1.3 assistant block 表

`deepchat_assistant_blocks`（`src/main/session/data/tables/deepchatAssistantBlocks.ts:79-102` 建表 SQL）：主键 `(message_id, block_index)`，保存 `block_type/status/text_content/tool_call_id/tool_name/tool_params/tool_response/action_type/image_mime_type/reasoning_start_at/reasoning_end_at/extra_json/updated_at`。`replaceForMessage`（:115-166）在单事务内删除旧行后按 index 重建，保证 block 顺序；`buildPersistedExtra`（:52-72）把 id/timestamp/imageData/extra/toolCallExtra/reasoningTime 折叠进 `extra_json`。MCP App 的 model context 经 `updateMcpAppModelContext`（:223-271）回写该表 `extra_json`（tool_call 块的 mcpResult.modelContext）。

### 1.4 pending input 是独立状态对象

队列/steer 记录定义在 `src/shared/types/agent-interface.d.ts:259-281`：`mode（queue|steer）`、`state（pending|claimed|blocked|retry_required|consumed，:260-265）`、payload、关联 message ids、assistant id、blocking 摘要、queueOrder 与时间戳。持久化表 `deepchat_pending_inputs`（`src/main/session/data/tables/deepchatPendingInputs.ts:31-49`）多出 `retry_required_at` 列（schema v67，:5、:67-69）。这样，正在生成的 turn 与尚未发送的输入是两条不同记录：queue 项被 claimed 后才物化为 user 消息（`SessionPendingInputs.createClaimedQueueUserMessage`，`src/main/session/data/pendingInputs.ts:56-83`），steer 输入则先物化 user 消息、claimed 时预建 assistant 占位（`claimSteerInput`，:275-305）。

**`retry_required` 语义（源码确认）**：持久化形态是 `state='blocked'` + `retry_required_at` 非空；v67 升级时的 `normalizeRetryRequiredRows`（`deepchatPendingInputs.ts:83-91`）把旧 `retry_required` 行规范化为该形态。`SessionPendingInputStore.getRowState`（`src/main/session/data/pendingInputStore.ts:571-573`）+ `isRetryRequiredRow`（:575-579）读取时还原为 `retry_required`。进入路径是 `releaseClaimedQueueInputForRetry`（:352-354，把 claimed 队列项置 blocked+retry_required_at 并清空 message_ids），退出路径是 `retryReleasedQueueInput`（:356-372，回到 pending）。该状态表示"queue 项曾被 claimed 但未物化为用户消息"（claim 的 `release-before-user-fact`/`release-after-rollback` 处置，见对话请求与上下文笔记 §8）。

**重启恢复（源码确认）**：`SessionPendingInputs.recoverInputsAfterRestart`（`pendingInputs.ts:392-468`）返回 `{ affectedSessionIds, heldQueueInputIds }`——claimed 且有物化 user 消息的 queue 项直接 consumed，否则释放回队列并登记 held；已 claimed 的 steer 输入中未读 pending user 消息经 `failPendingSteerMessages`（`transcript.ts:366-384`）置 error；未 claimed 的 steer 项转为 queue（:419-424）。启动时由 `createDeepChatRuntimeServices` 调用并交给 pump 持有（`src/main/agent/deepchat/harness/createDeepChatAgentHarness.ts:512-513`）。pending assistant 消息的兜底恢复在 `recoverPendingMessages`（`transcript.ts:771-801`）：pending user（非 steer）与 pending assistant 置 error，assistant 补 `common.error.sessionInterrupted` 错误块；`shouldKeepPending`（:827-840）保留带 steer receipt 的 user 消息与等待用户操作的 action 块。

### 1.5 分支与版本

fork 在持久化层是**复制而非父子指针**：`SessionLifecycle.forkSession`（`src/main/session/lifecycle.ts:446-519`）创建新的 regular 会话（继承 agent/project_dir/disabled tools/编排策略，标题默认"`<原标题> - Fork`"，:636-641），再经 `SessionTranscriptMutations.forkSessionFromMessage`（`src/main/session/transcriptMutations.ts:108-120`）→ `cloneSentMessagesToSession`（`transcript.ts:724-769`）把源会话中 `order_seq <= 目标消息` 的 sent 消息按原顺序复制为新 id 的消息（含 user content 结构化表与 assistant blocks 重建、搜索文档 upsert）。消息表没有任何"父消息/变体"字段，`is_variant` 只存在于 renderer 的 DisplayMessage 投影（`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:127` 常量 0）。

## 2. 事实源、索引与持久化

`SessionTranscript`（`src/main/session/data/transcript.ts:167` 起）是主进程权威生命周期：

```text
createUserMessage(...)        :180-204（写消息表 + user 结构化表 + 搜索文档 + Tape facts）
createAssistantMessage(...)   :206-217（status=pending，content='[]'）
updateAssistantContent(...)   :297-307（replace blocks + 保持 pending + 可选 metadata）
finalizeAssistantMessage(...) :386-401（replace blocks + updateContentAndStatus(sent) + 搜索文档 + usage + Tape）
setMessageError(...)          :419-441（同上，status=error）
```

搜索文档与命中快照：

- 完成/错误路径把可检索文本写入 `deepchat_search_documents`（`src/main/session/data/tables/deepchatSearchDocuments.ts:134-176` `upsert`，`document_kind: 'session'|'message'`，行接口 :4-14）；user 消息在 `createUserMessage`/`updateMessageContent` 时同步写（`transcript.ts:201`、:533），assistant 消息在完成/错误/内容更新时写（:398、:428、:438、:548）。
- 可检索文本抽取：`extractSearchableMessageContent`（`transcript.ts:93-135`）解析 user 内容 JSON（text + 附件可检索文本，32k 字符截断，:34、:137-157）与 assistant block 数组（content/text/error 字段）。
- SQLite FTS5 虚拟表 `deepchat_search_documents_fts` 以外部内容表方式建（`deepchatSearchDocuments.ts:279-287`），带 `ai/ad/au` 三个触发器保持同步（:309-335）；启动时校验表 SQL 兼容性与触发器存在，不兼容则重建并 rebuild 索引（`ensureFtsTable` :267-303），FTS5 不可用置 `ftsUnavailable`。查询用 `searchFts`（:210-241，bm25 排序、token 级短语 AND 匹配，`buildFtsMatchQuery` :24-31），不可用时回退 `searchLike`（:243-265，标题+内容 `LIKE '%term%'`）。
- `deepchat_message_search_results`（`src/main/session/data/tables/deepchatMessageSearchResults.ts:21-40`，含 `search_id/rank/dedupe_key`）保存消息级搜索命中快照：`add`（:50-92）以 `messageId::searchId::rank::content` 去重（:118-125）；随消息删除级联清理（`transcript.ts:592`、:613）。本次未追踪该表的写入触发点与清理策略全貌（仅确认删除级联与 `listByMessageId` :94-102）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：`SessionLifecycle.createSession`（`lifecycle.ts:64-180`）先 `resolveCreateAssignment` 解析 agent/provider/model，再 `sessions.create` 落 `new_sessions`（is_draft=false），随后 `initializeSessionRuntime` 把 provider/model/权限/生成设置写入 `deepchat_sessions`，`desktop.bind(webContentsId, sessionId)` 绑定窗口，最后 `startInitialTurn` 直接发送首条输入（:164-172）；取消创建时若尚无消息则删除会话（`cleanupCancelledNewSession` :609-634）。ACP 会话走 `ensureAcpDraftSession`（:383-444）惰性复用空的 draft 会话（`findReusableDraftSession` :526-535），首次发送时由 `SessionTurn.promoteDraft`（`src/main/session/turn.ts:439-443`）置 is_draft=false 并生成标题。
- **切换**：active session 按 webContentsId 绑定（`DesktopSessionBinding`，`src/main/desktop/sessionBinding.ts:13-64`；路由 `sessionsActivateRoute`/`sessionsDeactivateRoute`，`src/main/session/routes.ts:213-227`）。
- **删除**：`deleteSession`（`lifecycle.ts:521-524`）→ `deletion.deleteSessionTree`（删除实现文件 `src/main/session/deletion.ts` 本次未展开）。消息清理 `clearSessionMessages`（`turn.ts:415-420`）→ `SessionTranscriptMutations.clearMessages`（`transcriptMutations.ts:33-41`，连同 pendingInputs 与 Tape 一起清）。
- **恢复**：`restoreSession`（`src/main/session/sessionService.ts:69-112`）返回会话 + 第一页消息（默认 `DEFAULT_RESTORE_MESSAGE_LIMIT`）；启动恢复见 §1.4（queue/steer 收口 + pending 消息置 error）。

## 4. 编辑、重试、续写、回退与分支语义

- **重试**：`turn.retryMessage`（`turn.ts:333-375`）→ `prepareRetryMessage`（`transcriptMutations.ts:43-66`，以目标消息向上取最近 user 消息作为 source）→ `runtime.send`（DeepChat 路径带 `beforeHistoryPreparation` 回调）→ `commitRetryMessage`（:68-73）在流开始前执行 `deleteFromOrderSeq(sourceOrderSeq)`：**retry 是破坏性截断**，从源 user 消息起删除其后全部消息（`transcript.deleteFromOrderSeq`，`transcript.ts:597-617`，同步清理 blocks/结构化表/搜索文档/traces/搜索命中，并写 Tape 撤销 facts）。
- **删除消息**：`turn.deleteMessage`（`turn.ts:377-381`）先 `runtime.cancel()` 再 `transcriptMutations.deleteMessage`（:75-83）——同样从目标消息 `deleteFromOrderSeq` 截断，且要求无 active pending input（`assertNoActivePendingInputs`）。
- **编辑**：`turn.editUserMessage`（`turn.ts:383-390`）→ `transcriptMutations.editUserMessage`（`transcriptMutations.ts:85-106`）只允许 user 消息，**原地更新**该消息 content 并同步 user 结构化表与搜索文档（`transcript.updateMessageContent` :522-563），不物理删除尾随消息；界面流程随后自动触发 retry 完成截断（见 Chat UI 笔记 §6）。这是源码确认的"编辑改原对象、截断由 retry 承担"的语义。
- **续写**：本次在 turn 操作面未找到独立的"续写"执行链；ChatPage 的 continue 动作复用 `retryMessage`（见对话请求与上下文笔记 §7）。
- **分支**：见 §1.5（复制到新会话，非版本指针）。
- **失败保留**：失败 assistant 消息保留 `error` 状态与 error block（`buildTerminalErrorBlocks`，`transcript.ts:44-70`），不静默丢弃；用户可经 retry/fork 再生成。
- **压缩消息**：compaction 生成专门的 assistant 消息（`createCompactionMessage` :239-246，content 为固定文案、metadata 带 `messageType:'compaction'`/summaryUpdatedAt；`createCompactionMessageAtOrderSeq` :248-268 可前插并顺移 order_seq）。

## 5. 列表、分页、搜索与定位

- **消息分页接口**：`SessionTranscript.listMessagesPage`（`transcript.ts:457-485`）页上限 500，游标 `(orderSeq, id)`，hasMore 探测；renderer 侧 `messageStore.loadMessages/loadOlderMessages` 维护缓存与 `nextCursor`（`src/renderer/src/stores/ui/message.ts:743-`）。
- **会话列表分页**：`NewSessionsTable.listPage`（`newSessions.ts:252-297`，默认 30 上限 100，`(updated_at, id)` 游标）；renderer session store 以"列表 epoch"保护分页游标链（`src/renderer/src/stores/ui/session.ts:330-344`）。
- **消息窗口（数据分页侧）**：`MessageList`/`MessageListRow` 只接收当前窗口的 `MessageListItem`（`src/renderer/src/components/chat/MessageList.vue:10-31`、props :61-88）。`useMessageWindow` 以估算高度 + ResizeObserver 实测 + 顶部/底部 spacer + 逻辑 anchor 保存滚动位置；`useMessageVirtualization` 超阈值（160 条）时二分查找 viewport 附近索引并只渲染该窗口（`ChatPage.vue:917-932` 装配，阈值常量 :437-440）。历史分页与流式追加共用该机制：远离 viewport 的 settled 消息只保留估算高度。窗口化、滚动锚定与消息壳 DOM 实现在消息渲染器笔记 §6（该笔记把此主题列为交接点）。
- **会话内查找**：`useChatSearch`（`src/renderer/src/features/chat-page/composables/useChatSearch.ts`）在已加载 display messages 上做内存匹配（`collectChatSearchResults`，`src/renderer/src/lib/chatSearch.ts:501-522`），高亮与命中定位走 DOM 层（`applyChatSearchHighlights` :387-430），导航复用共享滚动控制器（`requestChatScroll('search-navigation', ...)`，useChatSearch.ts:124-128）。该路径只搜索当前窗口已加载消息，不触发数据库查询。
- **跨会话历史搜索**：`SessionHistorySearch.search`（`src/main/session/sessionHistorySearch.ts:98-204`）先 `searchFts`、空结果回退 `searchLike`，命中按 session/message 去重排序，另加标题 LIKE 兜底查询；服务路由 `sessionsSearchHistoryRoute`（`routes.ts:394-401`），renderer 侧由 Spotlight 调用（`src/renderer/src/stores/ui/spotlight.ts:314`），命中可定位到消息（pendingMessageJump，:440）。
- **MCP 搜索工具**：内存 MCP 服务器 `conversationSearchServer`（`src/main/mcp/inMemoryServers/conversationSearchServer.ts`）在 `tools/list` 暴露 `search_conversations/search_messages/get_conversation_history/get_conversation_stats`（:461-504），把同一索引服务给模型工具。

## 6. 缓存、一致性、多窗口与并发写入

- renderer message store（`src/renderer/src/stores/ui/message.ts`）状态：`messageIds/messageCache`（:62-63）、`committedSessionId`（:68，防止新旧会话记录混写）、`nextCursor/hasMoreHistory/isLoadingHistory/historyLoadError`（:69-75）、LRU 解析缓存 `parsedMessageCache`（上限 1024，:31、:76）与最近会话视图缓存（:77）。
- **流式一致性与 IPC 顺序**：生成侧快照节流 120ms（renderer）/600ms（DB）（`src/main/agent/deepchat/runtime/echo.ts:5-6`）；终态事件 `chat.stream.completed/failed` 由 `dispatch.finalize/finalizeError` 发布（`src/main/agent/deepchat/runtime/dispatch.ts:2693-2735`）。renderer 的 IPC 绑定（`src/renderer/src/stores/ui/messageIpc.ts`）按 `(sessionId, requestId)` 维护请求注册表：`acceptStreamUpdate`（:92-113）以"generation + updatedAt"拒绝过期/乱序快照，`settleStream`（:127-163）在 completed/failed 后把流状态折叠进持久化记录并重载消息页（同一 message id 不换 DOM 节点）；`onMessagesChanged`（:213-219）把 main 的增量记录合入缓存。
- `useDisplayMessages`（`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts`）的 `displayMessages` computed（:367-438）：先按持久化 id 重建显示列表，流式记录未进入有序 id 列表时临时插入（:389-406），再用 `assistantRenderKeyByMessageId`（:339-355 `bindPendingAssistantRenderKey`）把占位/pending 与最终落盘的同一消息关联，减少 DOM 替换；转换缓存保证 settled 对象稳定（:95-162）。
- **多窗口**：active session 按 webContentsId 绑定（`desktop/sessionBinding.ts:14`）；renderer session IPC 定向更新按 webContentsId 过滤（`src/renderer/src/stores/ui/sessionIpc.ts:29-35`）。消息/流式缓存是窗口内内存态，本次未找到跨窗口广播 busy/streaming 的实现。
- 未运行网络中断、快速切换 session 或重复事件场景的实测（§10）。

## 7. schema 版本、导入导出与保留策略

- **schema 版本与升级**：`mainDatabase`（`src/main/data/mainDatabase.ts`）用 `schema_versions` 表记录高水位（:315-328），启动时对每个未应用版本在单事务内执行各表的 `getMigrationSQL` 并调用 `finalizeMigration` 钩子（:330-388）。连接层用 `better-sqlite3-multiple-ciphers` 且启用 SQLCipher 兼容与 WAL（`src/main/data/connectionConfig.ts:6-20`）。
- 已知升级路径：`deepchat_pending_inputs` v17/43/46/67（`deepchatPendingInputs.ts:52-71`，v67 加 `retry_required_at` 并归一化旧行）；`new_sessions` v11/15/16/20/21/44/59（`newSessions.ts:97-131`，含 revision 前移恢复 v44、编排策略列 v59）；`deepchat_assistant_blocks` 与 `deepchat_search_documents` 的 v26 规范化重建（`deepchatAssistantBlocks.ts:104-113`、`deepchatSearchDocuments.ts:64-73`）。
- **导入导出**：导出路由 `sessionsExportRoute`（`routes.ts:511-518`）→ `AgentSessionExportService`；启动组件清单含 `legacy_import`（`src/main/logging/mainLogEvents.ts:76`）。本次未追踪 legacy import 与导出的完整数据链。

## 8. Agent、模型、知识库与附件绑定

- 会话级绑定落在两张表：`new_sessions` 保存 `agent_id/project_dir/active_skills/disabled_agent_tools/subagent 关系`（`newSessions.ts:13-30`，skills/tools 另有规范化子表，:383-428）；`deepchat_sessions` 保存 `provider_id/model_id/permission_mode/生成设置`（`deepchatSessions.ts:39-54`）。
- 消息级：user 消息的文本/附件/链接/搜索开关进 `deepchat_user_messages/deepchat_user_message_files/deepchat_user_message_links`（`transcript.ts:986-1017`，读取时 materialize 回 `UserMessageContent`，:875-912）；assistant 消息的 model/provider、usage 与 trace 进 metadata、`deepchat_usage_stats` 与 `deepchat_message_traces`（`transcript.ts:679-722`、:1176-1221）。
- MCP App model context 绑定在 assistant block 的 `extra_json`（§1.3）。
- 附件属于 `SendMessageInput.files`（`agent-interface.d.ts:250-257`），无法接受附件时返回 `needs_user_action`（执行语义见对话请求与上下文笔记 §1）。

## 9. 设计取舍与已确认边界

- transcript 同时服务展示、搜索、usage 与 Tape 等二级数据，一条消息的完成/错误路径承担全部同步更新（§2）；流式中间态只写 blocks 与 pending 状态，不重复写全量 content。
- 失败 assistant 消息保留 `error` 状态和错误块，不静默丢弃；retry/edit/delete 的尾随截断语义统一（§4）。
- fork 是"复制到新会话"而非版本树指针，消息层不存在父子/变体字段（§1.5）。
- queue/steer 输入独立于已完成消息持久化，claimed 未物化项进入 `retry_required` 显式等待用户处置（§1.4）。
- 消息窗口分页与流式追加共用同一机制（§5）。
- 搜索分内存匹配、FTS5 全文、LIKE 回退三层，命中以 message_id 定位（§5）。

## 10. 未验证事项

- SQLite 使用 `better-sqlite3-multiple-ciphers`，但实际密钥来源、加密配置、事务隔离与崩溃恢复未运行验证。
- 流式 IPC 顺序依赖 renderer 的 request 注册表与 generation/updatedAt 判定；网络中断、快速切换 session、重复事件场景未实测。
- 消息窗口高度是估算与观测的组合，复杂 artifact/图片导致的异步高度变化未通过浏览器实测。
- fork/delete/clear 的并发竞态、删除大会话的性能、搜索结果命中快照的完整生命周期（写入触发点与清理策略）未展开。
- legacy import 与导出（session export）的具体数据链未展开。
- 未运行测试、构建或桌面端交互；结论来自 main/renderer 静态源码。

## 11. 关键源码索引

- 消息表与状态：`src/main/session/data/tables/deepchatMessages.ts:42-56`、`:177-229`
- assistant block 表：`src/main/session/data/tables/deepchatAssistantBlocks.ts:115-166`、`:223-271`
- 会话表：`src/main/session/data/tables/newSessions.ts:13-30`、`:252-297`；`appSessionService.ts:71`（id 生成）
- transcript 生命周期：`src/main/session/data/transcript.ts:180-217`、`:297-307`、`:386-441`
- pending input 数据层：`src/main/session/data/pendingInputs.ts:392-468`、`src/main/session/data/pendingInputStore.ts:571-579`、`tables/deepchatPendingInputs.ts:67-91`
- 消息变更操作：`src/main/session/transcriptMutations.ts:43-106`、`src/main/session/turn.ts:333-390`
- 分页与搜索：`src/main/session/data/tables/deepchatSearchDocuments.ts:210-265`、`:309-335`、`src/main/session/sessionHistorySearch.ts:98-204`
- renderer 缓存与 IPC：`src/renderer/src/stores/ui/message.ts`、`src/renderer/src/stores/ui/messageIpc.ts:92-219`
- 显示稳定缓存：`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:367-438`
- 升级驱动：`src/main/data/mainDatabase.ts:315-388`
