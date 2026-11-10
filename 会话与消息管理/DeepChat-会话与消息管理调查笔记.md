# DeepChat 会话与消息管理调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：直接阅读源码（main process 的 SQLite 表定义与 transcript/pending input 数据层、turn 与路由、renderer 的 message store 与 IPC 增量层），静态核对符号与行号；未运行测试、构建或桌面端交互
>
> 调查范围：会话、消息与分支的数据模型与事实源、创建/切换/删除/恢复生命周期、编辑/重试/分支语义、列表分页与双层搜索、缓存一致性与多窗口、schema 版本升级、外部对象绑定；生成任务的执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 main process 驱动、renderer 订阅的持久化会话系统：

- 会话事实源由两张表承担：`new_sessions` 记录会话身份与结构（标题、项目目录、置顶与草稿标记、子会话关系、编排策略等），`deepchat_sessions` 记录生成相关的运行时状态（provider、模型、权限模式与生成设置）。会话 id 由 main process 的会话服务用 nanoid 生成（`src/main/agent/shared/appSessionService.ts:71`）。
- `deepchat_messages` 保存 user/assistant 消息的顺序、内容、状态（仅 `pending`/`sent`/`error` 三档）和 metadata；assistant 的结构化 blocks 另存于 `deepchat_assistant_blocks`，流式更新时两表分别写入（blocks 表落内容，消息表状态不变）。
- 消息事实源是 main process 的 SQLite；renderer message store 维护持久化缓存、解析缓存与 IPC 增量，`useDisplayMessages` 用稳定 render key 让流式消息在落盘后复用显示对象。
- 队列输入是独立的 `deepchat_pending_inputs` 状态对象（待处理/已认领/阻塞/需重试/已消费五档）。重启时 claimed 且未物化的项回到 pending 并加 restart hold，等待 resume；运行失败后释放的项进入 retry_required，等待逐项 retry，两条恢复路径分开处理。
- 消息窗口按"估算测量 + spacer + anchor + 二分查找"只接收当前窗口的 `MessageListItem`，同时服务历史分页和流式追加。
- 搜索分三层：会话内查找只匹配已加载的 display messages；跨会话历史搜索走 FTS5（触发器同步 + LIKE 回退），经 `sessionsSearchHistoryRoute` 服务 Spotlight；内存 MCP 服务器另把同一索引暴露为模型工具。
- 上下文压缩状态由消息 metadata 表达，摘要和 cursor 同时写会话表与 Tape anchor；读取优先重建自最新 anchor，CAS 事务防止过期结果覆盖，启动时协调 marker。boundary-only anchor 可以标记尚无新摘要的上下文边界，普通消息仍沿用三档状态（`src/main/session/data/settings.ts:244-310`、`createDeepChatAgentHarness.ts:495-518`）。
- 会话数据现在是跨设备同步的合并单元：一个 session 包包含会话行、元数据、Tape entries、消息与依赖内容，本地字段（项目目录、revision）不参与合并；删除以墓碑表达，避免旧副本复活（`src/main/sync/replica/units.ts`、`src/main/sync/replica/store.ts`，协议见独特功能笔记能力卡 9）。
- Agent 侧新增只读的会话引用读取（`read_session`）：按 cursor 分页取另一会话的消息或搜索命中，预览 800 字符、详情 8192 字符，不写入被读会话（`src/shared/sessionReferences.ts`、`src/main/session/data/sessionReferences.ts`）。
- 主进程把输出与状态从 session 服务中抽出为投影端口：`outputProjection.ts` 负责流式快照/终态/压缩事件的渲染层克隆，`sessionStatusProjection.ts` 负责状态与 usage 的发布；session 服务本身不再直接拼事件载荷（`src/main/session/outputProjection.ts`、`sessionStatusProjection.ts`）。
- Tape message facts 现在还承担 transcript 投影重建：同一终态 record 可在正常写入或重放时走同一投影器，恢复消息表、user 内容分表、assistant blocks 与搜索文档；投影 cursor 防止重复全量重放。

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

`NewSessionRow`（`src/main/session/data/tables/newSessions.ts:13-30`）是会话主表，字段按用途分组如下：

| 用途 | 字段 |
| --- | --- |
| 身份与标题 | `id`、`agent_id`、`title` |
| 项目与状态 | `project_dir`、`is_pinned`、`is_draft` |
| 技能与工具 | `active_skills`、`disabled_agent_tools` |
| 子会话 | `subagent_enabled`、`session_kind`（取值 `regular` 或 `subagent`）、`parent_session_id`、`subagent_meta_json` |
| 编排与维护 | `orchestration_policy`、`created_at`、`updated_at`、`revision` |

表建索引 `idx_new_sessions_agent` 与 `idx_new_sessions_updated`（`updated_at DESC`，:92-93），列表默认按更新时间倒序排序（:247）。会话 id 在 `appSessionService.create` 内用 nanoid 生成（`src/main/agent/shared/appSessionService.ts:71`）。

runtime 级状态在 `deepchat_sessions`（`src/main/session/data/tables/deepchatSessions.ts`）：`provider_id`/`model_id`/`permission_mode` 及生成设置 JSON（:39-54），即"模型绑定"的持久化位置（见 §8）。

### 1.2 消息表与状态

`deepchat_messages`（建表 SQL 与行接口在 `src/main/session/data/tables/deepchatMessages.ts:42-56`、`:4-16`）是消息主表，字段按用途分组如下：

| 用途 | 字段 |
| --- | --- |
| 标识与排序 | `id`、`session_id`、`order_seq`；索引建在 `(session_id, order_seq)` 上 |
| 内容与角色 | `role`（取值 `user` 或 `assistant`）、`content` |
| 状态 | `status`：`pending`、`sent`、`error` 三档 |
| 边界与扩展 | `is_context_edge`、`metadata`、`created_at`、`updated_at` |

索引与状态取值的定义见 `deepchatMessages.ts:10,54`。

消息 id 由 `SessionTranscript` 用 nanoid 生成（`src/main/session/data/transcript.ts:189`、:207）。

查询面（全部在 `deepchatMessages.ts`）如下：分页主入口 `listPageBySession`（:177-229）用 (order_seq, id) 游标降序分页并内联 trace 计数；启动恢复兜底 `recoverPendingMessages`（:397-404）把所有 pending 置 error；其余按需查询见下列清单：

- `getBySessionUpToOrderSeq`：:231-237
- `getByStatus`：:252-256
- `getLastUserMessageBeforeOrAtOrderSeq`：:360-369

### 1.3 assistant block 表

`deepchat_assistant_blocks`（建表 SQL 在 `src/main/session/data/tables/deepchatAssistantBlocks.ts:79-102`）保存 assistant 消息的结构化 blocks，主键 `(message_id, block_index)`，字段按用途分组：

| 用途 | 字段 |
| --- | --- |
| 块类型与状态 | `block_type`、`status` |
| 正文 | `text_content` |
| 工具调用 | `tool_call_id`、`tool_name`、`tool_params`、`tool_response` |
| 动作类型 | `action_type` |
| 媒体类型 | `image_mime_type` |
| 推理时间 | `reasoning_start_at`、`reasoning_end_at` |
| 扩展数据与更新时间 | `extra_json`、`updated_at` |

写入侧：`replaceForMessage`（:115-166）在单事务内删除旧行后按 index 重建，保证 block 顺序；`:52-72` 把一组运行时字段折叠进扩展 JSON。MCP App 的 model context 经 `updateMcpAppModelContext`（:223-271）回写该表（tool_call 块的 model context）。

### 1.4 pending input 是独立状态对象

队列/steer 记录定义在 `src/shared/types/agent-interface.d.ts:298-320`：`mode`（`queue`/`steer`）、state 五档状态机（取值见下）、payload、关联消息 ids、assistant id、阻塞摘要、`queueOrder` 与时间戳。

```text
state: pending | claimed | blocked | retry_required | consumed
```

持久化表 `deepchat_pending_inputs`（`src/main/session/data/tables/deepchatPendingInputs.ts:31-49`）多出 `retry_required_at` 列（schema v67 引入）。这样，正在生成的 turn 与尚未发送的输入是两条不同记录：queue 项被 claimed 后才物化为 user 消息，steer 输入则先物化 user 消息、claimed 时预建 assistant 占位（物化与占位逻辑见 `pendingInputs.ts:56-83、275-305`）。

**`retry_required` 语义（源码确认）**：该状态没有独立取值——持久化形态是 `state='blocked'` + `retry_required_at` 非空，v67 升级时把旧 `retry_required` 行规范化为此形态（`deepchatPendingInputs.ts:83-91`，读取时再还原）。语义是"queue 项曾被 claimed 但未物化为用户消息"，进入与退出路径如下（claim 的释放前/回滚后两类处置见对话请求与上下文笔记 §8）：

- 进入：把 claimed 队列项置 `blocked` + `retry_required_at`，并清空关联 message ids（:352-354）；
- 退出：回到 `pending`（:356-372）。

**重启恢复（源码确认）**：claimed 队列项已有物化 user 消息则消费，否则释放为 pending 并登记 restart hold；其他 pending/blocked 队列项也登记 hold，已有 retry_required 项保持逐项重试语义。hold 交给 pump 后不会自动 drain，用户 resume 与逐项 retry 是两种独立动作（`pendingInputs.ts:429-460`、`pendingInputStore.ts:353-374`）。

steer 恢复按是否已注入、是否有消息记录分别收口：已接受但尚未完成的 delivery 标记 unknown；blocked steer 转 queue 并进入 hold，其余未读消息经 transcript 结算（`pendingInputs.ts:456-499`）。启动装配把恢复集合交给 pump，再协调压缩 marker 与剩余 pending 消息（`src/main/agent/deepchat/harness/createDeepChatAgentHarness.ts:495-518`）。

每个会话的活动 queue 项上限为 10。数据层在 admission 前以 `countActiveQueue` 计数，达到上限即拒绝继续入队；该容量不包含已经 consumed 的记录，见 `src/shared/pendingInput.ts:2`、`src/main/session/data/pendingInputs.ts:474`。

pending assistant 消息的兜底恢复在 `recoverPendingMessages`（`transcript.ts:771-801`）：处于待定态的 user（非 steer）与 assistant 消息置 error，assistant 补 `common.error.sessionInterrupted` 错误块；`shouldKeepPending`（:827-840）保留带 steer receipt 的 user 消息与等待用户操作的 action 块。

### 1.5 分支与版本

fork 在持久化层是一次整段复制：`SessionLifecycle.forkSession` 新建一个 `regular` 类型的会话，继承源会话的 agent、项目目录、禁用工具与编排策略，标题默认取"原标题 - Fork"；随后把源会话中截至目标消息的已发送消息按原顺序复制成新 id，并重建 user 内容分表与 assistant blocks、补写搜索文档。消息表本身没有父消息或变体字段，变体标记只存在于 renderer 的显示消息投影里。复制入口见 `src/main/session/lifecycle.ts:446-519`，复制链见 `transcriptMutations.ts:108-120` 与 `transcript.ts:724-769`，投影标记见 `useDisplayMessages.ts:127`。

## 2. 事实源、索引与持久化

`SessionTranscript`（`src/main/session/data/transcript.ts:167` 起）是主进程权威生命周期：

```text
createUserMessage(...)        :180-204（写消息表 + user 结构化表 + 搜索文档 + Tape facts）
createAssistantMessage(...)   :206-217（status=pending，content='[]'）
updateAssistantContent(...)   :297-307（replace blocks + 保持 pending + 可选 metadata）
finalizeAssistantMessage(...) :386-401（replace blocks + updateContentAndStatus(sent) + 搜索文档 + usage + Tape）
setMessageError(...)          :419-441（同上，status=error）
```

终态写入与 Tape 重放共享 `TranscriptProjectionApplier`。它按消息 id 幂等 upsert 主消息行，重建 user 内容分表或 assistant blocks，并同步搜索文档；Tape 中的 message retraction event 则成批删除消息及 trace、搜索命中等 sidecar。`deepchat_transcript_projection_meta` 以 session、Tape incarnation、最大 entry id 和 projection version 保存重放游标，见 `src/main/session/data/transcriptProjection.ts`、`src/main/session/data/tables/deepchatTranscriptProjectionMeta.ts:20-87`。

搜索文档与命中快照：

- 完成/错误路径把可检索文本写入搜索文档表（`deepchat_search_documents`，`src/main/session/data/tables/deepchatSearchDocuments.ts:134-176`，行接口 :4-14；document_kind 区分会话级与消息级）：user 消息在创建/更新内容时同步写（`transcript.ts:201、533`），assistant 消息在完成/错误/内容更新时写（`transcript.ts:398、428、438、548`）。
- 可检索文本抽取：`extractSearchableMessageContent`（`transcript.ts:93-135`）解析 user 内容 JSON（正文 + 附件可检索文本，32k 字符截断，:34、:137-157）与 assistant block 数组的各文本字段。
- SQLite FTS5 虚拟表 `deepchat_search_documents_fts` 以外部内容表方式建（`deepchatSearchDocuments.ts:279-287`），带三个触发器保持同步（:309-335）；启动时校验表 SQL 兼容性与触发器存在，不兼容则重建并重建索引（:267-303），FTS5 不可用时置 `ftsUnavailable`。
- 查询用 `searchFts`（:210-241，bm25 排序、token 级短语 AND 匹配），不可用时回退 `searchLike`（:243-265，标题+内容 LIKE '%term%' 模糊匹配）。
- `deepchat_message_search_results`（`src/main/session/data/tables/deepchatMessageSearchResults.ts:21-40`，含搜索 id、排名与去重键）保存消息级搜索命中快照：写入入口（:50-92）按消息+搜索+排序+内容组合去重，随消息删除级联清理（`transcript.ts:592`、:613）。本次未追踪该表的写入触发点与清理策略全貌（仅确认删除级联与按消息查询）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：主进程的会话生命周期服务 `createSession` 按固定顺序建会话：先解析本次使用的 agent、provider 与模型，再把会话行以非草稿状态写入会话表，随后将 provider、模型、权限模式与生成设置写入运行时状态表，绑定到发起窗口，最后直接发送首条输入。若在发送前取消创建且会话尚无消息，这条空会话会被删除（`src/main/session/lifecycle.ts:64-180`）。
- **ACP 草稿会话**：ACP 会话创建时不立即新建正式会话，`ensureAcpDraftSession` 先复用已有的空草稿会话，首次发送才由 `SessionTurn.promoteDraft` 把草稿转为正式会话并生成标题。复用查找与转正入口见 `src/main/session/lifecycle.ts:383-444,526-535` 与 `src/main/session/turn.ts:439-443`。
- **切换**：每个窗口按 webContentsId 绑定自己的活动会话，激活与停用经由会话路由处理（`src/main/desktop/sessionBinding.ts:13-64`、`src/main/session/routes.ts:213-227`）。
- **删除**：删除会话从 `deleteSession` 进入，会话树的实际删除在 `src/main/session/deletion.ts`，本次未展开；消息清理先走 turn 层入口，再交给事务层，连同 pending 输入与 Tape 记录一并删除（`src/main/session/lifecycle.ts:521-524`、`src/main/session/turn.ts:415-420`、`src/main/session/transcriptMutations.ts:33-41`）。
- **恢复**：`restoreSession` 返回会话本身与第一页消息，页大小取默认常量 `DEFAULT_RESTORE_MESSAGE_LIMIT`；启动恢复见 §1.4（queue/steer 收口与 pending 消息置 error）。入口在 `src/main/session/sessionService.ts:69-112`。

## 4. 编辑、重试、续写、回退与分支语义

- **重试**：重试以目标消息为锚点，先向上找到最近的 user 消息作为起点，发送前再从这条消息起截断其后全部内容。截断会一并清理 assistant blocks、user 内容分表、搜索文档、执行轨迹与搜索命中，并写入一条 Tape 撤销记录，因此重试会丢弃源消息之后的整段历史。入口与起点解析见 `src/main/session/turn.ts:333-375`、`transcriptMutations.ts:43-73`，实际删除由 `deleteFromOrderSeq` 完成（`transcript.ts:597-617`）。
- **删除消息**：删除单条消息时先取消正在进行的运行，再走事务层从目标消息截断，并要求该会话没有进行中的 pending 输入（`turn.ts:377-381`、`transcriptMutations.ts:75-83`）。
- **编辑**：编辑只对 user 消息开放，事务层原地改写该消息内容，并同步 user 内容分表与搜索文档，尾随消息此时保留原样；界面随后会自动触发一次重试，历史截断由这次重试完成。编辑入口与事务实现见 `turn.ts:383-390`、`transcriptMutations.ts:85-106`，内容与搜索文档的同步在 `transcript.ts:522-563`（界面流程见 Chat UI 笔记 §6）。
- **续写**：ChatPage 的 continue 动作通过普通发送入口追加用户指令，保留已有消息，不触发 retry 的历史截断（`src/renderer/src/features/chat-page/composables/useMessageActions.ts:286-304`）。
- **分支**：见 §1.5（整段复制到新会话，消息之间没有父子或变体指针）。
- **失败保留**：生成失败的 assistant 消息保留 `error` 状态，并由 `buildTerminalErrorBlocks` 补上一组错误 block，正文不会被静默丢弃，用户可以经重试或 fork 再次生成（`transcript.ts:44-70`）。
- **压缩消息**：上下文压缩会生成一条专门的 assistant 消息，正文是固定文案，metadata 带上 `messageType:'compaction'` 与摘要时间戳；该消息另有前插写法，可以把压缩消息插到指定位置并顺移其后的排序号。追加与前插两种入口见 `transcript.ts:239-268`。

## 5. 列表、分页、搜索与定位

- **消息分页接口**：按会话读取消息时，`listMessagesPage` 用 `(orderSeq, id)` 复合游标向前翻页，单页最多 500 条，并额外探测是否还有更多；renderer 侧由消息 store 保存已加载的页与下一页游标（`src/main/session/data/transcript.ts:457-485`、`src/renderer/src/stores/ui/message.ts:743` 起）。
- **会话列表分页**：`NewSessionsTable.listPage` 以 `(updated_at, id)` 为游标分页，默认每页 30 条、上限 100 条；renderer 的会话 store 给列表带上 epoch，用它保护分页游标链（`newSessions.ts:252-297`、`src/renderer/src/stores/ui/session.ts:330-344`）。
- **消息窗口（数据分页侧）**：消息列表与行组件只接收当前窗口内的消息项，窗口由两个 composable 共同维护：`useMessageWindow` 以估算高度加实测高度确定范围，用首尾 spacer 与逻辑锚点保持滚动位置；消息数超过 160 条后，`useMessageVirtualization` 用二分查找定位视口附近的索引，只渲染这一段。历史分页与流式追加共用同一套窗口：远离视口的已结算消息只保留估算高度。组件 props 与阈值常量见 `src/renderer/src/components/chat/MessageList.vue:10-88,437-440`，窗口化、滚动锚定与消息壳 DOM 的实现在消息渲染器笔记 §6（该笔记把此主题列为交接点）。
- **会话内查找**：会话内查找在 renderer 内存里完成，范围是当前已加载的显示消息，不触发数据库查询；匹配由 `chatSearch.ts` 在显示消息列表上完成，高亮与命中定位交给 DOM 层，导航复用共享的滚动控制器。入口、匹配与导航位置见 `useChatSearch.ts:124-128`、`src/renderer/src/lib/chatSearch.ts:387-522`。
- **跨会话历史搜索**：跨会话搜索先走 FTS5 全文查询，结果为空时回退到 LIKE 模糊匹配，命中按会话与消息去重排序，另用标题 LIKE 兜底；结果经服务路由交给 renderer 的 Spotlight 展示，命中可以直接定位到具体消息。查询入口见 `src/main/session/sessionHistorySearch.ts:98-204`，路由与调用方在 `routes.ts:394-401`、`spotlight.ts:314`。
- **MCP 搜索工具**：内存 MCP 服务器 `conversationSearchServer` 在 `tools/list` 里注册四个工具，分别是搜索会话、搜索消息、读取对话历史与读取对话统计，把同一套搜索索引也提供给模型调用（`src/main/mcp/inMemoryServers/conversationSearchServer.ts:461-504`）。

## 6. 缓存、一致性、多窗口与并发写入

- renderer 的消息 store 维护以下状态（`src/renderer/src/stores/ui/message.ts:31-77`）：
  - `messageIds` 与 `messageCache`：已加载消息的 id 列表和消息缓存
  - `committedSessionId`：当前已提交的会话 id，用于防止新旧会话记录混写
  - `nextCursor`、`hasMoreHistory`、`isLoadingHistory` 与 `historyLoadError`：分页游标与历史加载状态
  - `parsedMessageCache`：LRU 解析缓存，上限 1024
  - 最近会话视图缓存
- **流式一致性与 IPC 顺序**：生成侧对快照做两级节流，发往 renderer 的快照每 120ms 一批，落库每 600ms 一次；流的终态由 dispatch 的 finalize 入口发布，对应 `chat.stream.completed` 与 `chat.stream.failed` 两个事件（`src/main/agent/deepchat/runtime/echo.ts:5-6`、`dispatch.ts:2693-2735`）。
- renderer 的 IPC 绑定层按会话 id 与请求 id 维护请求注册表：流终态到达后，`settleStream` 把流状态折叠进持久化记录并重新加载消息页，同一条消息因此沿用原来的 DOM 节点；增量记录直接合入缓存；流式快照带 generation 与时间戳，过期或乱序的快照被丢弃。相关实现集中在 `src/renderer/src/stores/ui/messageIpc.ts:92-163,213-219`。
- `useDisplayMessages` 的 `displayMessages` computed 先按持久化标识重建显示列表；流式记录尚未进入有序列表时临时插入；稳定的 render key 把占位消息与最终落盘的同一消息关联起来，减少 DOM 替换；转换缓存保证已结算对象保持稳定。各段位置见 `src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:95-162,339-355,367-438`。
- **多窗口**：每个窗口各自持有消息与流式缓存，事件分发由主进程负责。本地会话的完整流只发给绑定的窗口，没有绑定窗口时退化为广播；其他窗口收到的只是一条每会话约 1 秒节流的 activity 信号，终态信号则立即发出，非活动会话的最近视图缓存据此失效。会话状态另经版本事件进入 session store。分发与失效逻辑见 `src/main/events/sessionEventRouter.ts:78-95,160-179`、`messageIpc.ts:230-245` 与 `src/renderer/src/features/chat-session/store.ts:462-465`。
- 未运行网络中断、快速切换 session 或重复事件场景的实测（§10）。

## 7. schema 版本、导入导出与保留策略

- **schema 版本与升级**：数据库启动时用一张版本表记录已应用版本的高水位，逐个执行尚未应用的版本，每个版本的迁移 SQL 与收尾钩子都放在同一个事务里。连接层使用 `better-sqlite3-multiple-ciphers`，开启 SQLCipher 兼容模式与 WAL。升级驱动见 `src/main/data/mainDatabase.ts:315-388`，连接参数见 `src/main/data/connectionConfig.ts:6-20`。
- 已知升级路径按表演进：
  - `deepchat_pending_inputs` 依次经历 v17、v43、v46、v67，其中 v67 增加 `retry_required_at` 列并归一化旧行（`deepchatPendingInputs.ts:52-71`）；
  - `new_sessions` 从 v11 起，经 v15、v16、v20、v21、v44 到 v59，v44 处理 revision 前移恢复，v59 增加编排策略列（`newSessions.ts:97-131`）；
  - `deepchat_assistant_blocks` 与 `deepchat_search_documents` 在 v26 一起做规范化重建（`deepchatAssistantBlocks.ts:104-113`、`deepchatSearchDocuments.ts:64-73`）；
  - transcript 重放游标放在独立表 `deepchat_transcript_projection_meta`，当前投影协议版本为 1；该版本号标识 Tape 到 transcript 派生表的重放协议，与消息 schema 版本各自独立演进。
- **导入导出**：会话导出路由把请求交给 `AgentSessionExportService` 执行，启动组件清单里还能看到 `legacy_import` 一项；legacy import 与导出的完整数据链本次未追踪（`routes.ts:511-518`、`src/main/logging/mainLogEvents.ts:76`）。

## 8. Agent、模型、知识库与附件绑定

- 会话级绑定分放在两张表里：`new_sessions` 记录 agent、项目目录、技能与工具开关和子会话关系，技能与工具另有规范化子表；`deepchat_sessions` 记录 provider、模型、权限模式与生成设置。字段定义与子表位置见 `newSessions.ts:13-30,383-428`、`deepchatSessions.ts:39-54`。
- 消息级绑定分两类，存储位置见下表：

| 绑定对象 | 存储方式 |
| --- | --- |
| user 消息内容 | 正文、附件与链接三张分表：`deepchat_user_messages`、`deepchat_user_message_files`、`deepchat_user_message_links`；读取时拼回 `UserMessageContent`（`transcript.ts:875-912,986-1017`） |
| assistant 元数据 | 消息 metadata 加上 `deepchat_usage_stats`、`deepchat_message_traces` 两张统计表（`transcript.ts:679-722,1176-1221`） |

- MCP App model context 绑定在 assistant block 的 `extra_json`（§1.3）。
- 附件随 `SendMessageInput.files` 传给执行侧，模型无法接收附件时返回 `needs_user_action`（`agent-interface.d.ts:289-296`；执行语义见对话请求与上下文笔记 §1）。

## 9. 设计取舍与已确认边界

- transcript 同时服务展示、搜索、usage 与 Tape 等二级数据，一条消息的完成/错误路径承担全部同步更新（§2）；流式中间态只写 blocks 与 pending 状态，不重复写全量 content。
- transcript 表是可重建投影，但 usage 统计不由投影器重放，因为 fork/import/recovery 重放 record 只重放历史记录，不触发新的 Provider 调用（`transcriptProjection.ts` 的类级契约）。
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
- 未运行跨设备同步的双机合并、墓碑与冲突路径（LWW 语义见独特功能笔记能力卡 9）；未验证 read_session 的游标边界、超长会话分页与被读会话删除后的行为。
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
- Tape transcript 投影：`src/main/session/data/transcriptProjection.ts`、`src/main/session/data/tables/deepchatTranscriptProjectionMeta.ts`
- 输出与状态投影：`src/main/session/outputProjection.ts`、`sessionStatusProjection.ts`
- 跨设备同步单元：`src/main/sync/replica/units.ts`、`store.ts`
- 会话引用读取：`src/shared/sessionReferences.ts`、`src/main/session/data/sessionReferences.ts`
