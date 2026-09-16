# RikkaHub 会话与消息管理调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：只读阅读本地快照源码，沿 Room 实体、DAO、Repository、ChatService、GenerationLoop 与备份/导入链路核对符号与行号；未运行应用，未做设备侧观察
>
> 调查范围：会话/消息/分支数据模型、Room 表与迁移、select_index 分支选择、列表/分页/置顶/文件夹/删除与撤销、FTS5 + jieba 消息检索、生成状态与中断时的落盘时机、ConversationTools 跨会话引用、备份/导入导出保留；不含 Provider 请求协议、渲染器、Chat UI 视觉与工作流细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是原生 Android 应用（Kotlin + Compose + Room + DataStore + Koin），会话数据核心是「Room 双表 + 内存会话 + 独立 FTS5 索引」：会话元信息存 `conversationentity`，消息按「节点」拆到 `message_node`，同一节点的多个候选消息以 JSON 数组存在同一行，用 `select_index` 选择当前分支。

- **会话单位是 Conversation**：`assistantId` 是会话的一员，会话必然归属于某个助手，没有跨助手共享会话（`data/model/Conversation.kt:17-35`）。
- **消息是「路径上的节点列表 + 节点内候选」**：活动路径由 `currentMessages` 逐节点取 `messages[selectIndex]` 得到，不是父子树（`Conversation.kt:46-49`）；`ConversationEntity.nodes` 列自迁移 11→12 起废弃，恒写 `'[]'`（`data/repository/ConversationRepository.kt:358`）。
- **写入是「内存领先、回合结束落库」**：用户消息在生成开始前落库，助手回复在整回合成功结束时一次落库，生成期间只改内存 `StateFlow`（`service/ChatService.kt:464-471`、:794-804）。请求执行、任务状态机与流式处理见[对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。
- **分支切换 = 改 `select_index`**：编辑用户消息与重新生成助手回复都是给同一节点追加候选并选中，只有用户消息的「重新生成」是截断其后节点（`ChatService.kt:1230-1262`、:546-554）。
- **消息全文检索是独立 FTS5 虚表**：`message_fts` 由自定义分词器 `simple`（分层字典 + jieba）驱动，检索与摘要分别走 `jieba_query()` 和 `simple_snippet()`（`data/db/fts/MessageFtsManager.kt:64-109`、`data/db/AppDatabaseFactory.kt:36-48`）；列表分页用 Paging3、标题搜索用 `LIKE`，与全文检索是三套不同查询，而助手侧的 `recent_chats` / `conversation_search` 复用同一仓库与 FTS 索引（`ConversationDAO.kt:24-46`、`data/ai/tools/ConversationTools.kt:23-110`）。

## 系统边界与数据主链

```text
打开会话 ChatVM.init -> ChatService.initializeConversation（ui/pages/chat/ChatVM.kt:89-100、service/ChatService.kt:330-347）
  -> ConversationRepository.getConversationById：读 conversationentity + 分页读 message_node，
     反序列化为 UIMessage，按 node_index 排序（data/repository/ConversationRepository.kt:273-279、:433-472）
  -> 进入会话内存态 ConversationSession.state（service/ConversationSession.kt:29）
发送 -> 用户 UIMessage 追加为节点并 saveConversation 落库（ChatService.kt:464-471）
  -> 请求执行与流式回写（执行语义见对话请求与上下文笔记）
  -> 回合成功结束时整会话落库一次（:794-804）
列表/搜索：ChatDrawerVM（Paging3 分页、日期分隔）与 SearchVM（FTS 检索）
备份：BackupManager 打包 settings.json + VACUUM INTO 的数据库快照 + 附件目录
```

边界：提交入口、任务状态机、上下文拼装与流式执行主体在[对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)；上下文裁剪/压缩的编译规则在[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)；界面导航与操作属于 Chat UI 类目；Markdown/图片导出、备份远端传输与 Chatbox 导入的 Provider 合并属于[对话导出与分享笔记](../对话导出与分享/RikkaHub-对话导出与分享调查笔记.md)与 [LLM渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)；图片生成资产属于[媒体创作笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。

## 1. 会话、消息与分支数据模型

### 1.1 会话（Conversation）

领域模型 `Conversation` 与 Room 实体 `ConversationEntity` 并不一一对应：实体的 `nodes` 列是历史残留，消息实际在 `MessageNodeEntity`。会话行字段（`data/db/entity/ConversationEntity.kt:7-35`）：

| 列 | 语义 |
|---|---|
| `id` | 会话主键，String 形式的 UUID |
| `assistant_id` | 所属助手；有默认值，旧数据可回退到默认助手 |
| `title` | 标题，可为空串 |
| `nodes` | 旧版节点 JSON，当前恒为 `'[]'` |
| `create_at` / `update_at` | 毫秒时间戳，排序与列表分组依据 |
| `suggestions` | 后续问题建议的 JSON 数组 |
| `is_pinned` | 置顶布尔，映射为 0/1 |
| `custom_system_prompt` | 会话级系统提示词（空串表示未设置） |
| `mode_injection_ids` / `lorebook_ids` | 会话绑定的提示注入/世界书 UUID 集合（JSON 数组） |
| `workspace_cwd` | 会话在 workspace 沙箱内的绝对路径，空串表示未绑定 |
| `folder_id` | 助手内文件夹归属，空串表示未归类 |

领域侧 `Conversation` 用 `Uuid` 与 `Instant`，`assistantId` 没有默认值，`newConversation` 是 `@Transient` 的运行时标记（`Conversation.kt:27-35`）。

### 1.2 消息节点与候选（MessageNode / select_index）

`MessageNodeEntity` 是分支语义的载体（`data/db/entity/MessageNodeEntity.kt:9-32`）：表名 `message_node`，主键 `id`；`conversation_id` 建有索引并声明 `ON DELETE CASCADE`，删会话即级联删节点；`node_index` 是节点顺序号，读取时按 `node_index ASC` 排序、保存时按列表下标重排（`ConversationRepository.kt:474-485`）；`messages` 是候选消息数组（`List<UIMessage>`）整段序列化成的 JSON 字符串；`select_index` 指向当前选中的候选下标。

领域侧 `MessageNode` 另有 `isFavorite` 的 `@Transient` 字段，由 `FavoriteDAO` 单独查回后合并（`Conversation.kt:113-114`、`ConversationRepository.kt:434-437`）。候选消息的追加集中在 `Conversation.updateCurrentMessages`：节点已含同 id 消息就原位替换，否则追加并把 `selectIndex` 指向新末尾（`Conversation.kt:59-91`）——这是「同一节点内形成多个版本」的统一入口。`currentMessage` 在空数组或下标越界时抛 `IllegalStateException`，但读取路径会先过滤空节点（:116-120、:379）。

### 1.3 消息与部件（UIMessage / UIMessagePart）

`UIMessage` 与角色、部件、注解、时间、模型与用量（`ai/src/main/java/me/rerere/ai/ui/Message.kt:16-31`）：

| 字段 | 说明 |
|---|---|
| `id` | Kotlin `Uuid`，默认随机 |
| `role` | `MessageRole`（USER/ASSISTANT/SYSTEM/TOOL 等） |
| `parts` | 内容部件数组，是消息的主体 |
| `createdAt` / `finishedAt` | `LocalDateTime`，生成结束时补 `finishedAt` |
| `modelId` | 关联的模型 UUID，不保存模型快照 |
| `usage` | token 用量，供统计与 JSON 聚合查询使用 |
| `translation` | 单条消息的翻译结果，直接持久化在消息 JSON 内 |
| `isSynthetic` | 仅内存使用，代表请求期构造的系统消息 |

注解目前只有 `url_citation` 一种（`UIMessageAnnotation.kt`）。部件是封闭多态类型（`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt:72-217`），序列化用短类型名：

```text
text / image / video / audio / document / reasoning / search(废弃)
tool_call(废弃) / tool_result(废弃) / server_tool / tool
```

图片、文档、视频、音频部件只保存 URL 字符串（本地文件为 `file:`、内联为 `data:`）；工具部件 `Tool` 用 `output: List<UIMessagePart>` 表示是否已执行——`isExecuted` 以「输出非空」判定，`isPending` 以「未执行且审批态为 pending」判定，审批态取值为 `auto`/`pending`/`approved`/`denied`/`answered`；`server_tool` 承载 Provider 在服务端执行的工具（`UIMessagePart.kt:11-32`、:193-199）。

Provider 回传所需的协议原始数据放在部件的 `metadata`（`JsonObject`）里，由 `MessageMetadata.kt` 提供强类型视图（如 Claude 的 `signature`、OpenAI 的 `encrypted_content`），随消息 JSON 一起持久化，字段需可空且 key 与历史数据一致。

### 1.4 附件与本地文件引用

`Conversation.files` 遍历所有节点、所有候选消息的部件，收集以 `file://` 开头的 URL，工具部件的输出会被递归展开（`Conversation.kt:37-41`、:139-155）。写库前有硬性约束：`conversationToConversationEntity` 要求消息中不存在 base64 图片部件，否则 `require` 失败（`ConversationRepository.kt:353-354`）。附件文件本身不属于 Room，由 `FilesManager` 管理，删会话/删消息时按上述引用集合清理（见第 3 节）。

## 2. 事实源、索引与持久化

### 2.1 权威源与投影

持久化权威源是 Room 数据库（文件名 `rikka_hub`，WAL 模式；`data/db/SQLiteConfiguration.kt:10`）；运行时权威源是 `ConversationSession.state` 这个 `MutableStateFlow<Conversation>`，打开会话时从数据库装载一次，此后由 `ChatService` 在内存中更新并按时机回写（`service/ConversationSession.kt:29`、`ChatService.kt:1079-1084`）；FTS 索引是派生投影，随会话写入重建，也可手动全量重建。

### 2.2 Room 表与 schema 版本

`AppDatabase` 声明 8 个实体、版本号 25，并把 1→25 的迁移全部登记（`data/db/AppDatabase.kt:30-63`）。与本文相关的是 `ConversationEntity`、`MessageNodeEntity`、`FavoriteEntity`、`FolderEntity`。schema JSON 保存在 `app/schemas/me.rerere.rikkahub.data.db.AppDatabase/`，可逐版本核对：`lorebook_ids` 在 20、`workspace_cwd` 在 22、`folder_id` 在 24，说明会话级注入绑定、workspace 归属与文件夹分组分三个版本加入；`message_node` 表从 schema 12 开始出现。

### 2.3 message_node 的读写与写放大

`ConversationRepository.updateConversation` 的策略是「整会话重写」：在一个 Room 事务里更新会话行，然后 `deleteByConversation` 删掉全部节点再按列表顺序整批插入（`ConversationRepository.kt:299-309`、:474-485）。节点 id 会保留，`node_index` 由列表下标重新生成。因此任何一次会话保存（包括生成结束）都会重写该会话的全部消息 JSON。读取侧相反，按 64 条一页循环翻页，遇到超大 blob 或非法状态时报错并跳过该页继续（:433-472）。

### 2.4 FTS5 虚表与 jieba

FTS 不是 Room 实体，而在数据库 `onOpen` 回调中用 `CREATE VIRTUAL TABLE IF NOT EXISTS` 创建，列为 `text` 与 5 个 `UNINDEXED` 元数据列（节点、消息、会话 id、标题、更新时间），分词器为自定义的 `simple`（`AppDatabaseFactory.kt:36-48`）。同一回调还会调用 `jieba_dict()` 注册词典目录，词典由 `SimpleDictManager` 从 assets 解压到 files 目录并按版本号判断是否重拷（`data/db/fts/SimpleDictManager.kt:19-32`）；分词与摘要能力来自原生扩展 `libsimple`，经 requery 的 SQLite 工厂加载（`SQLiteConfiguration.kt:12-21`）。

`MessageFtsManager` 的行为要点（`data/db/fts/MessageFtsManager.kt`）：建索引是「先按 conversation_id 删、再逐消息插入」，只索引 `Text` 部件，拼接后截断到 10000 字符（:33-54、:112-115）；检索用 `text MATCH jieba_query(?)`、摘要用 `simple_snippet(..., 30)`、默认 `LIMIT 50`（:81-92）；排序有相关度（`rank, update_at DESC`）、最新、最旧，可选用 `EXISTS` 子查询按助手过滤（:21-25、:70-80）。

### 2.5 索引维护时机

`insertConversation`/`updateConversation` 在 Room 事务提交之后调用 `messageFtsManager.indexConversation`，即 FTS 写入与主表写入不在同一事务内（`ConversationRepository.kt:289-309`）。`rebuildAllIndexes` 提供全量重建：先 `deleteAll`，再逐会话读取并重建，回调进度（:334-345），界面侧由 `SearchVM.rebuildIndex` 驱动（`ui/pages/search/SearchVM.kt:124-136`）。

## 3. 创建、切换、归档、删除与恢复

### 3.1 创建与惰性创建

界面层「新建会话」只是生成一个 UUID 并导航过去，对象创建推迟到第一次有内容时：`ChatService.initializeConversation` 若数据库无此 id，就用当前助手构造空会话并把助手预设消息塞进节点，然后 `updateConversation` 只改内存（`ChatService.kt:330-347`）；`saveConversation` 会拦住「新会话、标题为空、节点为空」的保存（:1144-1148），因此空会话不会落库，也就不会出现在列表里。「清空空会话」这一独立机制本次未找到。

### 3.2 切换与打开

列表点击进入聊天页时 `ChatVM.init` 调 `addConversationReference` + `initializeConversation`，并把会话 id 记到 SharedPreferences 的 `lastConversationId` 以便下次恢复（`ui/pages/chat/ChatVM.kt:89-100`）；切换助手时 `ChatDrawerVM` 会把文件夹筛选重置为「未归类」（`ChatDrawerVM.kt:126-134`）。

### 3.3 重命名、置顶、移动到助手/文件夹

- 重命名：`updateTitle` 走整对象保存，Web 端另有 `POST /conversations/{id}/title`（`ChatVM.kt:292-297`、`ConversationRoutes.kt:183-198`）；首轮生成成功后标题为空时用 fast 模型按 `titlePrompt` 生成（`ChatService.kt:888-989`，建议文案同理）。
- 置顶：`togglePinStatus` 先读当前值再取反，是单列 `UPDATE`（`ConversationRepository.kt:403-408`），列表排序恒为 `is_pinned DESC, update_at DESC`。
- 移动助手会把 `folderId` 清空，避免归属悬空（`ChatVM.kt:310-325`）；移动文件夹时先同步活跃内存态再落库，否则后续整对象保存会用旧 `folder_id` 覆盖，Web 端还校验目标文件夹属于同一助手（`ChatService.kt:1099-1104`、`ConversationRoutes.kt:249-268`）。

### 3.4 归档与未读

本次未找到「归档」与「未读」的字段或查询：会话实体没有归档时间/未读计数列，DAO 也没有对应谓词，唯一的生命周期状态是 `is_pinned` 与 `folder_id`；检查范围为 `ConversationEntity`、`ConversationDAO`、`ChatDrawerVM`、`ConversationRoutes` 中的全部查询。

### 3.5 删除与撤销

`deleteConversation` 先尽力取完整会话（含节点）以便清理文件，然后删 FTS 行、在事务里删会话行（节点靠 CASCADE 删除），最后删本地文件（`ConversationRepository.kt:311-326`），删除助手时批量删该助手全部会话（:347-351）。**列表页删除无可撤销**，侧栏 `onDelete` 直接删除并刷新（`ChatDrawer.kt:279-287`）；**历史页提供一次性撤销**，删除前先 `getFullConversation` 取完整对象，`Snackbar` 的 Undo 再 `insertConversation` 写回（`ui/pages/history/HistoryPage.kt:116-129`、`HistoryVM.kt:57-61`），只在该提示存活期间有效，不是回收站。另有「删除全部会话」按钮直接批量删除（`HistoryPage.kt:140-163`）。

### 3.6 文件夹的删除语义

`FolderEntity` 表名 `conversation_folder`，不设 Room 外键；删除文件夹时由仓库层先把归属会话的 `folder_id` 置空再删文件夹，避免级联误删会话（`data/db/entity/FolderEntity.kt`、`data/repository/FolderRepository.kt:33-40`）。活跃会话的归属通过 `ChatService.deleteFolder` 先同步内存态（`ChatService.kt:1121-1126`）；若文件夹内存在正在生成的会话，界面层拒绝删除（`ChatDrawerVM.kt:165-177`）。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 编辑用户消息 = 追加候选

`ChatService.editMessage` 找到包含该消息的节点，把新内容作为**同角色的另一条消息**追加，并把 `selectIndex` 指向末尾（`ChatService.kt:1230-1262`）。原消息不被覆盖，因此「编辑」本身产生一个可切换的版本；编辑本身不触发重新生成。

### 4.2 重新生成助手回复 = 追加候选

`regenerateAtMessage` 区分角色：目标是助手消息时，新回复经 `updateCurrentMessages` 变成该节点的新候选并被选中，重试复用同一个助手消息 id 以覆盖当前分支而非额外产生候选（`ChatService.kt:530-574`）；目标是用户消息时，会话被裁到该节点（`subList(0, indexAt + 1)`）后再生成（:546-554），这一步是**截断删除**，其后节点不再保留。

### 4.3 分支切换 = 改 select_index

`selectMessageNode` 校验下标范围后改写节点 `select_index` 并整会话保存（`ChatService.kt:1297-1323`）；Web 端对应 `POST /conversations/{id}/nodes/{nodeId}/select`（`ConversationRoutes.kt:323-333`）。「活动路径」由每节点一个下标推得，没有持久化的指针链；切换分支只改这个整数。

### 4.4 删除消息

`buildConversationAfterMessageDelete` 从所属节点移除该消息；节点因此变空则整节点删除；`selectIndex` 被压到新的最大下标（`ChatService.kt:1350-1379`）。生成中禁止删除：界面在存在生成任务时改走提示错误分支（`ui/pages/chat/ChatPage.kt:473-479`）。

### 4.5 复制会话（fork）

`forkConversationAtMessage` 复制目标消息所在节点及其之前的所有节点到新会话，新会话保留原会话的助手、系统提示词、注入 id、workspace 与文件夹归属（`ChatService.kt:107-119`）；每个节点获得新的 `Uuid.random()`，但**节点内消息的 id 原样保留**（:1279-1289）；本地附件会逐个按内容复制出新文件，避免与源会话共享同一文件引用（:1381-1395）。

### 4.6 续写与排队的数据侧结果

续写即向同一会话继续发送。若同一会话已在生成，新消息进入内存 `MessageQueue`（不持久化）由当前任务结束时取出继续（`ChatService.kt:405-445`、`service/MessageQueue.kt`）。数据侧只体现在：排队的用户消息轮到它时按常规路径追加为节点并落库。调度、串行与多会话并发语义见[对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。

### 4.7 上下文压缩的落库结果

`compressConversation` 把较早的消息按 256 条一段二分，分批调用压缩模型生成摘要，然后用「摘要消息节点 + 保留的最近消息节点」整体替换原 `messageNodes` 并落库（`ChatService.kt:993-1075`）。压缩后的历史不含旧部件的原始结构，属于破坏性重写而非旁路标注；裁剪与压缩的编译语义见[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。

## 5. 列表、分页、搜索与定位

### 5.1 会话列表与分页

侧栏用 Paging3：`pageSize = 20`、`initialLoadSize = 40`、无占位（`ConversationRepository.kt:37-40`、:66-90），只查不含 `nodes` 与 `suggestions` 的轻量投影 `LightConversationEntity`（:24-31、:491-499）。三个列表变体并存：助手全部、助手内未归类（`folder_id = ''`）、指定文件夹（`ConversationDAO.kt:24-31`）；界面在分页流上插入「置顶」与日期分隔项（`ChatDrawerVM.kt:68-121`）。Web 端另有以 `PagingSource` + `nextKey` 实现的分页（`ConversationRepository.kt:105-219`）。

### 5.2 标题搜索

会话标题搜索是数据库 `LIKE '%' || ? || '%'`，不带全文索引，排序仍是置顶优先（`ConversationDAO.kt:36-46`）。它与消息全文搜索是两套互不相关的查询。

### 5.3 消息全文搜索与命中定位

消息搜索返回 `MessageSearchResult`（节点 id、消息 id、会话 id、标题、更新时间与高亮片段），因此能定位到具体节点与消息而非仅会话（`MessageFtsManager.kt:12-19`）。界面侧对输入做 300ms 防抖，请求经 `Channel.CONFLATED` 串行化，可切换「当前助手/全部助手」范围并记忆排序偏好（`SearchVM.kt:86-152`）。

### 5.4 统计类查询

会话每日计数用 SQLite `strftime` 聚合（`ConversationDAO.kt:93-100`）；token 与每日消息数则用 `json_each()` 展开 `message_node.messages` 后 `json_extract` 聚合，并以 `json_valid` 兜底损坏行（`MessageNodeDAO.kt:64-91`）——消息 JSON 结构一旦变化会波及统计。

### 5.5 界面的规模保护

聊天页对「节点数 > 768 且最后助手消息输入 token > 300000」同时成立时弹出规模警告（`ui/pages/chat/ChatSizeChecker.kt:18-19`、:37-56）。这是提示，不改变数据。

## 6. 写入时机与一致性

流式事件、停止/重试、最终回写与半截流的收口语义由[对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)负责。数据侧：用户消息在生成开始前落库，助手回复只在整回合成功结束时一次落库，生成期间与取消/异常的收尾只改内存，工具审批状态写回节点后落盘（`service/ChatService.kt:464-471`、:748-804、:629-630）；被中途停止的纯文本半截回复**没有独立落盘调用**（本次未找到），但下一次发送消息时会连同它整会话落库。

一致性要点：`select_index` 与候选数组同处一行，不存在跨行指针不一致；整会话重写提供单事务原子性，代价是写放大约为会话全部消息 JSON；FTS 与主表非同一事务，崩溃窗口内可能落后，`rebuildAllIndexes` 是补齐手段；fork 保留原消息 id，故 `FavoriteRepository` 用「会话 id + 节点 id」构造引用键（`FavoriteRepository.kt:28-44`）；多端（App 与 Web SSE）同时操作时内存会话是单一权威源（`ConversationRoutes.kt:366-450`），本笔记未做并发写入实验验证。

## 7. 迁移、导入导出与备份保留

### 7.1 Room 迁移的关键节点

| 迁移 | 动作 | 依据 |
|---|---|---|
| 6→7 | `messages` 列改造成 `nodes`，每条旧消息包装为单候选节点 | `Migration_6_7.kt` |
| 8→9 | 删除 `usage` 列 | `Migration_8_9.kt` |
| 11→12 | 新建 `message_node`，把 `nodes` JSON 拆行，`nodes` 置为 `'[]'` | `Migration_11_12.kt` |
| 13→14 | 把 JSON 中旧的部件类名映射为 `@SerialName` 短名 | `Migration_13_14.kt` + `MigrationUtils.kt` |
| 15→16 | 把旧的 TOOL 角色节点合并进前置助手节点，`ToolCall`/`ToolResult` 归一为 `Tool` | `Migration_15_16.kt` |
| 16→17 | 删除 `truncate_index` 列 | `Migration_16_17.kt` |
| 22→23 | 删除 workspace 的 `shell_enabled` 列 | `Migration_22_23.kt` |

迁移期间通过全局 `DatabaseMigrationTracker` 暴露 `Migrating(from, to)` 状态供界面显示进度（`data/db/DatabaseMigrationTracker.kt`）。

### 7.2 备份包格式

`BackupManager.createBackup` 生成一个 zip：`settings.json`、可选的数据库快照、可选的 `upload/`、`skills/`、`fonts/` 附件目录（`data/sync/BackupManager.kt:37-73`）。数据库快照用 `VACUUM INTO` 获得包含已提交 WAL 的独立文件，避免直接拷 WAL（`data/sync/DatabaseBackup.kt:15-19`）。附件写入时会逐个校验相对路径在目标目录内，拒绝越权路径（`BackupManager.kt:141-148`、`PendingRestore.resolveInside`）。

### 7.3 恢复是「下一次启动时安装」

恢复不直接覆盖运行中的数据库：`stageRestore` 把内容落到 `noBackupFilesDir/backup-restore` 暂存目录并就地校验——数据库副本先 `normalize`（checkpoint + `PRAGMA integrity_check`），再用与线上一致的 schema 工厂打开以便执行受支持的旧迁移；`settings.json` 经 `SettingsJsonMigrator` 迁移并拒绝「未初始化」设置（`BackupManager.kt:114-132`、`DatabaseBackup.kt:22-39`）。应用启动时 `applyPendingRestore` 在任何 Koin/Room/SettingsStore 消费者之前执行（`BackupManager.kt:163-168`、`RikkaHubApp.kt:58-67`）。安装用「journal + 原子移动 + 回滚」实现可恢复：先生成待安装条目清单并持久化，逐条 `ATOMIC_MOVE` 安装，失败回滚原文件，成功以重命名 `pending` 目录为提交动作；数据库的 `-wal`/`-shm`/`-journal` 作为「不安装只备份」条目处理，避免把旧库 WAL 留在新库旁（`PendingRestore.kt:29-115`）。

### 7.4 保留策略与提醒

本地、WebDAV 与 S3 使用同一归档格式，列表按修改时间倒序，删除是显式用户操作；远端上传与客户端细节见[对话导出与分享笔记](../对话导出与分享/RikkaHub-对话导出与分享调查笔记.md)。**未发现按数量或时间自动清理旧备份的逻辑**，也未发现 WorkManager 周期任务；所谓「自动备份提醒」只是本地到期提示，由 `BackupReminderConfig` 的开关、间隔天数与上次备份时间在界面侧判断（`data/datastore/PreferencesStore.kt:657-662`、`ui/components/ui/BackupReminderCard.kt:37-38`）。

### 7.5 导入

Chatbox 备份导入解析 `manifest.json` 与各 `sessions/*/session.json`，把会话、消息、fork、图片资源映射到本应用模型，id 由稳定 UUID 派生，同 id 会话跳过（`ChatboxImporter.kt:41-157`、:693-694，`BackupVM.kt:111-171`）；`mainMessage` 与 fork 的候选会合并为同一 `MessageNode` 并按 fork position 设定 `selectIndex`，对应外部「fork 列表」（`ChatboxImporter.kt:318-364`）。Cherry Studio 只导入 Provider（`BackupVM.kt:173-187`），其合并规则见 [LLM渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)；`ui/pages/chat/Export.kt` 的 Markdown/图片导出属于导出与分享类目，数据来源是当前选中路径的 `currentMessages`。

## 8. 助手、模型、注入与附件的绑定粒度

- **助手 / workspace / 注入**：均为会话级——助手列决定模型、提示词与工具集并可在会话生命周期内整体迁移；workspace 保存沙箱内绝对路径；提示注入与世界书只存 id 集合、内容在设置中，Web 写入前校验 id 存在（`ConversationRoutes.kt:464-485`）。
- **模型**：消息级 + 设置级。`UIMessage.modelId` 只存 UUID 引用而非快照；模型定义在 DataStore，模型删除后旧消息仍带 id，需反查设置取元信息（`ui/pages/chat/Export.kt:533`）。
- **附件 / 收藏**：附件是消息部件级、只存 URL 并由 `FilesManager` 落地清理；收藏是节点级，独立 `favorites` 表以 `ref_key` 唯一索引、`ref_json`/`snapshot_json` 存节点快照，源会话删除后仍可读（`data/db/entity/FavoriteEntity.kt`、`FavoriteRepository.kt`）。

## 9. 跨会话引用（ConversationTools）

助手按需检索历史会话而不静态注入系统提示词，注释说明这是为了不破坏提示词缓存（`data/ai/tools/ConversationTools.kt:19-25`）。`recent_chats` 与 `conversation_search` 在 `ChatToolFactory` 中随助手工具集注册（`ChatToolFactory.kt:64`），都以文本 JSON 结果回给模型、属于消息部件并随会话持久化：前者复用 `getRecentConversations` 取当前助手最近会话，后者复用 `searchMessages(..., RELEVANCE)` 对历史消息做全文检索（`ConversationTools.kt:28-110`）。参数与检索范围语义见[检索增强与认知编排笔记](../检索增强与认知编排/RikkaHub-检索增强与认知编排调查笔记.md)。

## 10. 设计取舍与已确认边界

- **双轨数据形状**：领域模型以「节点列表」工作，Room 侧把节点拆行、候选消息打包成 JSON 列，换来整会话事务重写的简单一致性与按节点定位能力，代价是 FTS 必须独立维护。
- **分支用下标、编辑靠追加候选**：没有 parent/child 外键，活动路径由每节点的 `select_index` 推得，分支切换是 O(1) 单列修改，但不存在可引用的「分支实体」；编辑与重新生成都保留原消息并追加候选，只有用户消息的重新生成会截断后续节点。
- **`nodes` 列保留但不使用**：迁移 11→12 后恒为 `'[]'`，该列与 `resetConversationNodes` 语句仍在（`ConversationDAO.kt:69-70`），本次未找到调用方。
- **写入是回合制**：流式期间不逐 chunk 落库以省写放大，代价是崩溃/取消在半截回复处丢弃最近内容。
- **搜索分两层**：标题 `LIKE` 即时过滤，内容 FTS5 + jieba，且只索引 `Text` 部件，图片、工具输出与 reasoning 文本不进入全文检索。
- **删除无回收站，无归档、无未读、无消息级软删除**：检查范围见 3.4。

## 11. 未验证事项

1. 生成中停止后，半截文本助手消息的实际落盘结果未在设备上验证；本笔记结论来自静态路径分析（`ChatService.kt:748-804`），请求侧停止语义见[对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。
2. FTS 自定义分词器 `simple` 与 `jieba_query`/`simple_snippet` 对中英文混合、停用词与长片段的实际命中/高亮效果未实测。
3. `loadMessageNodes` 在超大消息 blob 上跳过整页的行为（`ConversationRepository.kt:444-454`）是否导致消息静默缺失未实测。
4. 多端（App + Web SSE）同时写入的合并结果、以及 FTS 与主表事务外窗口是否可观察到不一致，未做并发实验。
5. 备份恢复的中断回滚路径，以及 `VACUUM INTO` 快照在超大库上的耗时与空间占用，均未实测。
6. 会话规模达到 768 节点 / 30 万输入 token 后的列表与生成性能未实测；`Conversation.newConversation` 等运行时标记在 Web 路径下的传播细节未逐处核对。

## 12. 关键源码索引

- 数据模型与消息抽象：`data/model/Conversation.kt`；`ai/src/main/java/me/rerere/ai/ui/` 的 `Message.kt`、`UIMessagePart.kt`、`MessageMetadata.kt`
- 数据层：`data/db/`（`entity/`、`dao/`、`AppDatabase.kt`、`AppDatabaseFactory.kt`、`SQLiteConfiguration.kt`、`migrations/`、`fts/MessageFtsManager.kt`、`fts/SimpleDictManager.kt`）、`data/repository/ConversationRepository.kt`
- 服务与执行：`service/ChatService.kt`、`service/ConversationSession.kt`、`service/MessageQueue.kt`、`data/ai/GenerationLoop.kt`
- 跨会话工具与界面：`data/ai/tools/ConversationTools.kt`、`ChatToolFactory.kt`；`ui/pages/chat/ChatDrawerVM.kt`、`ChatVM.kt`、`ui/pages/search/SearchVM.kt`、`ui/pages/history/HistoryVM.kt`
- 备份、导入与 Web：`data/sync/`（`BackupManager.kt`、`DatabaseBackup.kt`、`PendingRestore.kt`、`webdav/WebDavSync.kt`、`S3Sync.kt`、`importer/ChatboxImporter.kt`、`CherryStudioProviderImporter.kt`）；`web/routes/ConversationRoutes.kt`
