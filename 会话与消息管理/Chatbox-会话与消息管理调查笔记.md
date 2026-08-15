# Chatbox 会话与消息管理调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、renderer store、IndexedDB 存储层），符号与行号对照当前 HEAD 逐一核实，未运行应用
>
> 调查范围：会话与消息的持久化模型、生命周期、分支、索引与检索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 以**单会话（Session）为存储单元**，会话与消息是本地持久化的业务对象：

- 会话列表（sidebar）只认识 `SessionMetaRecord`（标识、名称、置顶、归档与排序等元信息），完全不知道 thread、fork、summary 这些"消息级"结构的存在（见第 1 节证据）。
- 首页是一个"假会话"（id 固定为字符串 `'new'`），真正的 `Session` 记录直到用户发出第一条消息才被创建（第 3 节）。
- 消息事实源是**双写**：完整 Session 对象写通用 `storage`，meta 记录写 IndexedDB `session-meta`，两者都要保持同步。
- thread（同会话内历史区间）、fork（同一消息位置的平行分支，替代回复可折叠为分支组）、summary（消息级压缩标记）与 starred（置顶分组）是**四套独立的数据结构**，唯一的交叉点是"move thread to conversations"会把 thread 转成新的顶层会话（第 1 节）。
- 归档 = `hidden: true` + `archivedAt` 时间戳，不删除任何数据；恢复归档不会重置 `sortOrder`。
- 消息搜索没有持久化倒排索引，按分页读取完整 Session 后逐条扫描。
- 自动压缩触发阈值已核实：按模型上下文窗口与 `compactionThreshold`（默认 0.6）计算 token 预算（第 1.4 节），此前标注"未逐行展开"的事项本次已核实。

## 系统边界与数据主链

```text
首页 'new' 假会话（纯 React state + 草稿 localStorage key 'new-chat'）
  -> 首条消息触发 createPersistedChatSession
  -> 真实 Session 写入通用 storage + IndexedDB session-meta（双写）
  -> 会话页经 react-query 读取 Session
  -> 流式期间 UI cache 高频更新 + 2 秒节流落盘（执行语义在对话请求与上下文）
  -> SessionList 经 IndexedDB 游标分页查询 meta 记录
  -> 置顶 / 归档 / 恢复 / 永久删除修改 meta 字段并双写
```

边界：请求体如何组装、流式节流落盘时机属于对话请求与上下文；界面上的拖放、菜单、搜索弹窗工作流属于 Chat UI；消息内容渲染属于消息渲染器（已有独立笔记，本文只记录数据形状）。

## 1. 会话、消息与分支数据模型

### 1.1 会话列表分组：只认 `starred`，不知道 thread/fork 存在

`SessionMetaSchema`（`src/shared/types/session.ts:390-400`，由 pick 挑选字段）只包含列表展示所需的元信息，**不包含** `threads`、`messageForksHash`、`messages` 等消息级结构。挑选的字段如下：

- `id`/`name`：标识与标题；
- `starred`/`hidden`/`archivedAt`：置顶与归档状态；
- `assistantAvatarKey`/`picUrl`/`backgroundImage`：展示图；
- `type`：会话类型。

`SessionList.tsx:106-121` 的分组逻辑只按 `starred` 分成 "Pinned" / "Chats" 两组。侧栏拿不到 thread/fork 数据，所以"会话列表分组"在数据结构层面就和 thread/fork 无关。

### 1.2 Thread：同一个 Session 内部的"历史区间"

`SessionThreadSchema`（`src/shared/types/session.ts:357-363`）：`{ id, name, messages, createdAt, compactionPoints? }`，存在 `session.threads: SessionThread[]` 里，是**同一个 Session 对象内部**的字段，不是独立记录。

产生 thread 的时机（均在 `stores/session/threads.ts`）：

- `switchThread(sessionId, threadId)`（`threads.ts:68-109`）：把**当前**消息打包成一个新 thread 塞进 `session.threads`，再把目标 thread 的消息换上来做当前消息——本质是"交换当前窗口与某个历史窗口"（经 `updateSessionWithMessages` 的队列 current 回调完成），且压缩点随各自消息列表一起交换（归档的 thread 保留当前会话的压缩点，恢复的会话取目标 thread 自己的压缩点，见 `threads.ts:89-106` 注释与代码）；
- `refreshContextAndCreateNewThread`/`startNewThread`（`threads.ts:115-148, 150-157`）：把当前消息整个存成一条新 thread，当前消息清空成只留 system prompt，`compactionPoints` 清空；
- `compressAndCreateThread`（`threads.ts:195-252`，上下文压缩/摘要功能触发）：同样把旧消息存成 thread，当前消息替换为"system prompt + 一条包含压缩摘要文本的 user 消息"，并清空 `messageForksHash` 与 `compactionPoints`。

Thread 边界在数据侧的呈现：`getCurrentThreadHistoryHash(session)`（`sessionHelpers.ts:1106-1132`）把每个 thread 的**第一条消息 id** 映射成一个 `SessionThreadBrief`（`session.ts:413-420`），作为渲染层插入 ThreadLabel 的依据（界面呈现见 Chat UI 笔记）。

### 1.3 Fork：某条消息之后的"平行分支"

`messageForksHash`（`src/shared/types/session.ts:386`）以**分叉点消息 id** 为 key，值为"各分支消息数组 + 当前激活分支下标 + 创建时间"；它挂在会话对象（或其 thread）上，和侧栏无关（`MessageForkSchema` 定义在 `session.ts:351-355`）。

纯变换逻辑在 `shared/session/message-forks.ts`，只导出"算出一个 `Partial<Session>`"的纯函数——切换分支、创建分支（含不切换的"备用分支"）、删除分支与展开分支各有对应的 patch 构造函数，另有消息定位函数；renderer 侧 `stores/session/forks.ts` 负责把 patch 应用到会话并写回。函数与行号清单见本节末尾。

- `shared/session/message-forks.ts`：`buildSwitchForkPatch`（:173）、`buildSwitchForkToPatch`（:181）、`buildCreateForkPatch`（:327）、`buildCreateInactiveForkPatch`（:391）、`buildDeleteForkPatch`（:446）、`buildExpandForkPatch`（:490）、`findMessageLocation`/`findMessageSourceThread` 等定位函数
- `stores/session/forks.ts`：`createNewFork`（:27）、`createInactiveFork`（:52，保存替代回复但不切换）、`switchFork`（:94）、`switchForkTo`（:117）、`deleteFork`（:140）、`expandFork`（:164）

`insertMessage`/`updateMessage`/`removeMessage`（`chatStore.ts:615-676、695-783、785-835`）都要同时处理"消息可能在 `session.messages` 里，也可能在某个 thread 的消息里、或某个 fork list 里"三种情况——即 fork 和 thread 是可以叠加共存的两套坐标系。

`insertMessage` 在带 `previousId` 插入时还会跳过紧随其后的锚定摘要消息——"摘要紧贴其边界之后，两者之间不得插入其他消息"（`:625-631` 注释）。

`removeMessage` 会在全部分支列表里查找并删除目标消息（`removeMessageFromSavedForks`，`chatStore.ts:837-874`），同步清理该消息引用的压缩点，随后 `cleanupEmptyForkBranches`（`chatStore.ts:881-967`）在**同一个函数内**处理两条路径：root 消息层命中时改写消息数组并自动切换分支，thread 层命中时只更新 hash。

### 1.4 Summary：消息级压缩标记与压缩点

`Message.isSummary: boolean`（`src/shared/types/session.ts:331`），由自动压缩机制在某条消息上打标记，UI 用专门的 `SummaryMessage` 组件渲染，提供"删除摘要，恢复原始消息参与上下文计算"的操作。

压缩的数据语义：压缩不只打 `isSummary` 标记，还在 Session/thread 上持久化 `compactionPoints`（`CompactionPointSchema`，`session.ts:337-341`），每项以 `{ summaryMessageId, boundaryMessageId, createdAt }` 配对——boundary 是摘要覆盖范围的边界消息。

共享层 `shared/context/compaction-points.ts:19-40` 的 `findLatestApplicableCompactionPoint` 要求边界与摘要两条消息都存在于当前消息路径上才生效；fork 分支切换可能拆散最新契约，此时跳过并回退到更早仍完整的压缩点。

renderer 侧由 `packages/context-management/compaction-boundary.ts:12-21`（boundary 必须通过上下文合格性过滤且不能是摘要自身）与 `compaction-commit.ts`（`buildCompactionCommitPatch`，`:28`）负责执行压缩。

复制会话/挪 thread 成独立会话时，`remapCompactionPoints`（`src/shared/types.ts:313-337`）按完整 id 映射重映射压缩点，映射不上的点被丢弃（`stores/session/crud.ts:92-102`）。

**触发阈值（本次核实）**：`compaction-detector.ts` 的 `checkOverflow`（`:31-58`）按下式判定；其中固定输出预留 32,000 token，默认阈值系数 0.6，`compactionThreshold` 可经全局设置调整（常量定义与取值见 `:4-5、:49`）；未知模型（无法确定 contextWindow）不触发。

```text
isOverflow = tokens > max(contextWindow - 32000, contextWindow*0.5) * compactionThreshold
```

`compaction.ts`（`:57-125`）先按会话估算 token（带 react-query 缓存）再触发上述判定；压缩执行链（`runCompactionWithStreaming`，`:167-263`）：生成摘要（流式 UI 态）、打摘要标记、找 boundary、构建压缩点，最终原子提交；摘要流式期间 boundary 若被删除则放弃提交（`:240-247`，不报错，下次发送重试）。

### 1.5 ForkMarker：唯一真正打通"消息级"与"会话级"的地方

`Message.isForkMarker` + `forkedFromSessionId`（`src/shared/types/session.ts:332-333`）是第四个概念：把 thread 挪成独立会话、或复制会话时，复制流程（`crud.ts:53-123`）会在**新会话**顶部插入一条 `isForkMarker: true` 的助手消息，该字段指回源会话 id。**这是唯一一处"消息级分支"和"侧栏新增一个会话条目"产生真实关联的地方**——把一段 thread 历史"独立"出来，本质是新建一个真正的会话元记录。

**结论**：会话列表分组（starred）、thread（同会话内的历史区间）、fork（同一消息位置的平行分支）、summary（消息级压缩标记）是四套完全独立的数据结构和交互面，唯一的交叉点是"move thread to conversations"这个操作会把 thread 数据转成一个新的顶层会话。

## 2. 事实源、索引与持久化

### 2.1 双写：完整 Session 与 meta 记录

置顶切换（`SessionItem.tsx:204-206` 移动端菜单、`:315-319` 桌面按钮）经会话 store 的更新链（`chatStore.ts:351-392`）**同时**写两处：完整 Session 对象（`storage.setItemNow`，经每会话 `UpdateQueue` 串行化）和 meta 记录，再重排 react-query 缓存。

`updateSession`（`chatStore.ts:395-411`）是元数据专用路径：只允许修改消息结构（messages/threads/messageForksHash/compactionPoints）之外的字段，违反时由 `chatStore-cache.ts:18-24` 的断言直接抛错，并固定带 `preserveCachedGeneratingMessages: true` 选项。

### 2.2 IndexedDB 分页游标与索引

`listSessionsMetaQueryOptions`（`chatStore.ts:90-96`）经 meta 存储的分页查询完成（`SessionMetaStorage.ts:227-232`），默认页大小 `DEFAULT_PAGE_SIZE = 50`（`:7`）。

主列表分页（`SessionMetaStorage.ts:254-281`）分两段游标扫描，两段都用 `sortOrder` 索引降序：第一段取置顶且未隐藏的记录，不足再补非置顶记录（`:283-329`）。`starredSortOrder` 复合索引虽然创建了（`:79-81`），主列表查询实际没有用到它。效果不变：**置顶会话永远排在分页结果最前面**，而不是先整表排序再切页。

归档分页走独立索引 `archivedAt`（`getArchivedPage`，`:187-208`）；`getTotal` 统计未隐藏记录数（`:234-237`）。

### 2.3 排序落地：分数索引

`reorderSessions(oldIndex, newIndex)`（`stores/session/crud.ts:150-191`）采用**分数索引（fractional indexing）**：新 `sortOrder` 取同置顶分组内相邻两项的平均值，边界情况用 ±1000 固定步长，无邻居时用 `Date.now()`；若拖拽跨过置顶分组边界，会顺带把目标组的置顶状态写到该项（`:179-181`）。移动一项只需改这一项的排序值，无需重写整表；移动后立即写 IndexedDB，并同步更新 react-query 的分页缓存。

`sortSessionRecords`（`shared/utils/session-sort.ts:42-50`）是最终排序函数：先过滤 `hidden`，然后置顶优先、同组内按 `sortOrder` 降序。

### 2.4 IndexedDB schema 变更策略

IndexedDB session-meta 数据库有意不做 `version` 升级（`SessionMetaStorage.ts:51-55` 注释），只允许加法式 schema 变更，理由是版本号升级会导致用户降级客户端版本后打不开数据库（`indexedDB.open(DB_NAME)` 不带 version，`:56`）；注释提到的"捕获 VersionError 后以不带 version 重试"的兜底策略在已读代码里**没有看到实现**——仍属未核实/未实现状态。

## 3. 创建、切换、归档、删除与恢复

### 3.1 惰性创建：`createPersistedChatSession`

`routes/index.tsx:272-353`，触发点是 `handleSubmit`（`routes/index.tsx:355-366`）调用 `createPersistedChatSession`：

1. 调会话 store 的 `createSession`（`chatStore.ts:310-347`）用真实 uuid 创建会话对象，并把首页临时状态的 agentMode、工作目录与全权限开关**直接内联进 `settings` 参数**一次性写入（`routes/index.tsx:289-299`），不是先创建再二次 patch。
2. 如果首页临时状态里存在知识库绑定：调 `addSessionKnowledgeBase` 把绑定转移到真实 id 上，然后 `setNewSessionState({})` **整体清空**（不是只清知识库字段）——工作目录与全权限开关已在第 1 步内联进新会话的 settings，整体清空不会丢数据，但这个耦合关系并不直观（代码注释 `routes/index.tsx:308-311` 明确说明）。
3. `sessionWebBrowsingMap.new` 若存在：`setSessionWebBrowsing(newSession.id, value)` + `clearSessionWebBrowsing('new')`（`:324-328`）。
4. `sessionAgentModeMap.new` 若存在：仅 `clearSessionAgentMode('new')`（因为 agentMode 已经在第 1 步写入了 settings，`:330-333`）。
5. `switchCurrentSession(newSession.id)`（路由跳转到 `/session/$sessionId`）。
6. 删除 `'new-chat'` key（`:336`）——**本次已核实写入点**：`hooks/useMessageInput.ts:18-20` 把首页假会话的草稿存到该 key（真实会话为 `draft-${sessionId}`），创建真实会话后删掉它即清掉临时草稿，不是遗留逻辑。

`chatStore.createSession`（`chatStore.ts:310-347`）还有一个细节：新建会话的 `settings` 会先套一层"上次使用模型"的记录，再用调用方传入的设置覆盖——"新会话默认延续上次用的模型"这条规则在创建时刻硬编码合并（`:312-320`）。新记录的排序值默认当前时间戳，若传了插入位置参考（复制/新建在指定位置）则取相邻项平均值（`:324-334`）。

### 3.2 置顶 / 归档 / 恢复 / 永久删除

全部通过 `SessionMetaRecord` 上的字段完成，**没有单独的"归档表"**：

- **置顶**：`session.starred: boolean`，切换走 `updateSessionWithMessages` 双写（见 2.1）。
- **归档**：`archiveSession(id)`（`chatStore.ts:497-500`）：

  ```ts
  export async function archiveSession(id: string) {
    await updateSession(id, { hidden: true, archivedAt: Date.now() })
    await refreshArchivedSessionListCache()
  }
  ```

   即归档 = `hidden: true`（主列表分页查询与统计都过滤隐藏记录）+ `archivedAt` 时间戳（供归档列表按时间排序/过滤，走 `archivedAt` 索引）。**不删除任何数据**。
- **批量归档**（`archiveSessions`，`chatStore.ts:504-533`，对应清空会话列表的 `clearConversationList`）故意**逐个**调用 `updateSession`，代码注释直言：

  ```ts
  // 这里刻意逐个走 updateSession，保证完整 session 存储和 meta 存储一致。
  // 该实现不针对超大批量归档做性能优化。
  ```

  批量归档还会回收"meta 记录存在但完整 Session 缺失"的失效条目（`:522-529`：清 RAG 索引、批量删 meta、清理删除会话的运行时状态）。这是一个明确写在代码里的、已知的性能取舍。
- **恢复**：`restoreSession(id)`（`chatStore.ts:535-539`）把 `hidden` 置回 false 并清掉 `archivedAt`。**不会重置 `sortOrder`**——恢复后的会话会出现在归档前的原始排序位置，不会被顶到列表最上面。这是一个容易让用户困惑的行为（恢复的会话可能"消失"在列表很靠下的位置）。
- **永久删除**：`deleteSession(id)`（`chatStore.ts:486-495`）/批量 `deleteSessions(ids)`（`:541-559`）。删除动作包含：
  1. 清理该会话的 session-attachment RAG 索引（`cleanupSessionAttachmentRagEntries`，`:459-470`，按 10 个一批并行）；
  2. 从通用 `storage` 删除完整 Session 对象（`storage.removeItem`）；
  3. 从 IndexedDB 的 meta store 删除记录（`metaStorage.delete`/`deleteMany`）；
  4. 同步剔除主列表和归档列表两个 react-query 缓存；
  5. `cleanupDeletedSessionRuntimeState(id)`（`chatStore.ts:472-484`）：统一清理 session query 缓存、`uiStore` 里的网页浏览/知识库/agentMode 三个 map、解析缓存、滚动位置缓存、未读活动标记与挂起的 `UpdateQueue`，并在桌面端调用沙箱清理接口删除该会话生成的落地文件。

删除前会先调 `confirmSessionDeletion(id)`（`chatStore.ts:440-457`）：仅桌面端、且仅当该会话在沙箱里有可下载产物（`platform.sandboxHasArtifacts`）时才弹"删除会话将永久删除这些文件"的确认框；这个确认逻辑同时被 `routes/settings/archive.tsx:136`（归档列表里的删除按钮）复用。

**数据恢复（本次新增核实）**：`recoverSessionList`（`chatStore.ts:975-1033`）扫描通用 storage 全部 `session:` 前缀 key，逐个读取完整会话重建 meta 记录（排序值按首条消息时间戳），清空 meta 后全量重写——这是"meta 表损坏/丢失后从完整会话重建列表"的恢复路径。

## 4. 编辑、重试、续写、回退与分支语义

- Fork 的数据语义见 1.3：重新生成/继续生成会经 `stores/session/generation.ts:95-139` 产生新的分支数组，`position` 记录激活分支；`createInactiveFork` 保存替代回复但不切换（`forks.ts:52` 起，供"在下方继续回复"使用）。
- "把 thread 挪成独立会话"与"复制会话"都会 `copySession(...)` 在**新会话**顶部插入 `isForkMarker` 消息并指回源会话（1.5），即会话级复制在数据上就是新建一个 `SessionMetaRecord`。
- 分支清理存在 root 层与 thread 层两条相似但不完全对称的路径（`cleanupEmptyForkBranches`，`chatStore.ts:881-967`）：root 层命中时改写消息数组并自动切换分支，thread 层命中时只更新 hash。
- 编辑、删除、重试产生的数据变更入口是 `insertMessage`/`updateMessage`/`removeMessage`（`chatStore.ts:615-835`）；重试、续写、再生成的**执行链**（如何选择起始上下文、重新调用模型）在对话请求与上下文笔记。

## 5. 列表、分页、搜索与定位

- **会话列表**：react-query 无限查询 + IndexedDB 游标分页（2.2）。`SessionList.tsx:124-128` 的触底回调触发翻页（`fetchNextPage()`），有下一页时挂加载脚注（`:43-49`）。
- **会话项活动指示（不持久化）**：侧栏的"生成中/回复完成未读"指示来自内存 zustand store（`sessionActivityStore.ts` + `stores/session/generation-runtime.ts`），以会话 id 为 key 的临时集合，**不写 `SessionMetaRecord`、不落盘**，重启即清空——`SessionMetaSchema` 仍是侧栏唯一的持久化认知（界面呈现见 Chat UI 笔记 1.2）。
- **消息搜索**：Chatbox 有一套独立于消息列表渲染的搜索实现。`sessionHelpers.searchSessions`（`sessionHelpers.ts:1052-1104`）对当前消息和历史 thread 的消息做正则匹配（`shared/services/native-session-search.ts:55-76`），覆盖文本、推理、信息与工具调用状态及文件名。
  跨会话时按 IndexedDB 元数据分页（`SEARCH_PAGE_SIZE = 30`，`:1049`）并行读取完整会话，命中上限 `SEARCH_RESULT_LIMIT = 50` 条（`:1050`，不足时继续翻页），每页之间让出执行、UI 渐进渲染（`:1098-1102`）。这套实现**没有持久化倒排索引**，跨会话搜索仍是按页读取并逐条扫描；它不受 Virtuoso 虚拟窗口的 DOM 挂载范围限制。搜索入口与结果定位的工作流在 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

- **两条写路径**：缓存更新路径（`stores/session/messages.ts:132-137`）只改 react-query 缓存，**不碰 storage**，注释写明"性能优先，不检查 session 存在性"；`persistStreamingMessage(...)`（`messages.ts:143-155`）走每会话一个的写队列（`stores/updateQueue.ts`，基于微任务的串行合并队列，写入失败会回滚内存状态并拒绝本批全部更新，`:60-73`），**真正写盘**。节流策略（2 秒定时 + tool-call 特例）属于对话请求与上下文笔记。
- **缓存合并保护**：元数据更新路径（`chatStore.ts:395-411`）固定带 `preserveCachedGeneratingMessages: true` 选项，实际合并逻辑在 `mergeCachedGeneratingMessages`（`chatStore-cache.ts:26-79`）：磁盘上读回较旧的会话快照要写回缓存时，若某条消息在缓存里处于生成中，就保留缓存里更新的内容，不用旧内容覆盖；合并覆盖消息、各 thread 消息与分支哈希三个层级。这是为了防止"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的内容。
- 删除生成中的消息同样走 `preserveCachedGeneratingMessages` 全量写路径（`removeMessage`，`chatStore.ts:785-835`），注释明确"合并只映射仍然存在的消息，不会复活已删除消息"。
- **删除时的状态清理**：`cleanupDeletedSessionRuntimeState` 统一清理 query 缓存、UI map、atom 缓存、滚动位置、未读活动与挂起队列（3.2 删除第 5 步）。

## 7. 迁移、导入导出与保留策略

- IndexedDB schema 只做加法式变更、不做 version 升级，以兼容降级客户端（2.4）。
- 备份导入不依赖 `crypto.randomUUID`（部分浏览器/WebView 环境缺失该 API 时用回退 id 生成），导入在移动/Web 端更稳（`stores/migration.ts` 与 `migration-error.ts` 负责迁移流程与错误上下文，本次未逐行展开迁移 schema 明细）。
- 导出：`exportChat`（`sessionHelpers.ts:947` 起）支持全部/当前 thread 两种范围与 Markdown/TXT/HTML 三种格式（`ExportChatScope`/`ExportChatFormat` 定义在 `shared/types.ts:20-22`），导出内容的界面入口在 Chat UI 类目。
- 导入导出、备份恢复、崩溃恢复与多窗口竞争在本类目范围内未做运行验证（见未验证事项）。

## 8. Agent、模型、知识库与附件绑定

- **首次创建时内联**：工作目录、全权限开关与 agentMode 在 `createPersistedChatSession` 里直接内联进新会话的 `settings`（3.1）；正式会话的 agentMode 也有持久化路径：`setSessionAgentMode`（`stores/session/agent-mode.ts:101` 起）写 `session.settings.agentMode`。
- **知识库**：前端状态只存 `Pick<KnowledgeBase, 'id'|'name'>` 句柄（`uiStore.sessionKnowledgeBaseMap` 或新会话的 `newSessionState.knowledgeBase`），绑定以会话 id 为 key；真实检索发生在生成阶段（见对话请求与上下文笔记）。
- **Copilot**：选中 copilot 时把会话的 `copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`（`routes/index.tsx:211-234`）——创建出来的仍然是一个普通 chat 类型会话，只是多了该字段用于用量统计（`routes/index.tsx:302-306`）。
- **网页浏览**：`sessionWebBrowsingMap`（`uiStore.ts:36`）按会话 id 保存布尔开关。**本次新核实**：uiStore 使用 zustand 持久化中间件（`uiStore.ts:20-21`），`partialize` 只持久化下列五个字段（`:235-241`）：
  - `widthFull`
  - `showCopilotsInNewSession`
  - `sidebarWidth`
  - `agentModeSmartSwitchingDefault`
  - `sessionWebBrowsingMap`

  即网页浏览开关**跨重启保留**，而 `sessionKnowledgeBaseMap`、`sessionAgentModeMap`、`newSessionState` 不持久化、重启丢失。默认值规则（ChatboxAI provider 默认开、其他 provider 默认关）见 `stores/session/utils.ts:33-40`。

## 9. 设计取舍与已确认边界

- **批量归档故意不做性能优化**：代码注释直接承认"逐个走 `updateSession`，不针对超大批量归档做性能优化"（`chatStore.ts:502-503`）——是被记录在案、而非被忽略的工程取舍。
- **恢复归档会话不重置 `sortOrder`**：恢复后出现在归档前位置而非列表顶部，可能与用户预期不符。
- **Fork 清理双路径收敛**：`cleanupEmptyForkBranches` 合并为单一函数内的 root/thread 两条路径（`chatStore.ts:881-967`），root 层会改写消息数组并自动切换分支、thread 层只更新 hash，两者行为仍不完全对称。
- **IndexedDB 无 version 升级**：兼容降级客户端的代价是 schema 只能加法演进（2.4）。
- **首页临时状态耦合**：`newSessionState` 整体清空依赖"workingDirectories/agentFullAccess 已内联进 settings"这一隐式顺序（3.1），代码注释明确但不直观；`newSessionState.webBrowsing` 字段在类型中声明但全仓库无读写点（Chat UI 笔记 3.1）。
- **类目边界**：本笔记只回答数据语义；停止生成的半截消息最终如何落盘、重试如何选择上下文属于对话请求与上下文；列表虚拟化、滚动锚定与消息壳装配属于消息渲染器（`../消息渲染器/Chatbox-消息渲染调查笔记.md`）。

## 10. 未验证事项

- `context-management` 包压缩的**运行行为**（摘要质量、长会话下的触发频率、boundary 消失竞态的实际发生频率）未运行验证；触发阈值公式本身本次已核实（1.4）。
- provider 侧 token 截断策略、导入导出、崩溃恢复、多窗口并发写入需要运行验证。
- IndexedDB "捕获 VersionError 后重试"的兜底实现未在已读代码中找到（2.4）。
- 侧栏"生成中/未读完成"指示为内存态，跨重启/多窗口的同步行为未验证（5）。
- 迁移模块（`stores/migration.ts`）的 schema 明细未逐行展开（7）。

## 11. 关键源码索引

- `src/shared/types/session.ts`（`Session`/`Message`/`SessionThread`/`MessageForkSchema`/`SessionMetaSchema` 等 schema）
- `src/renderer/stores/chatStore.ts`（会话 CRUD、分页缓存、归档/删除、`recoverSessionList`）
- `src/renderer/stores/chatStore-cache.ts`（`mergeCachedGeneratingMessages`、`assertNoMessageDataUpdate`）
- `src/renderer/stores/updateQueue.ts`
- `src/renderer/stores/session/threads.ts`、`forks.ts`、`messages.ts`
- `src/renderer/stores/session/crud.ts`（`reorderSessions`、`copySession`）
- `src/renderer/storage/SessionMetaStorage.ts`（IndexedDB 分页/索引/游标）
- `src/shared/session/message-forks.ts`（fork 纯变换函数）
- `src/shared/utils/session-sort.ts`（`sortSessionRecords`）
- `src/renderer/stores/sessionHelpers.ts`（`searchSessions`、`getCurrentThreadHistoryHash`、`constructUserMessage`）
- `src/shared/services/native-session-search.ts`（消息匹配扫描）
- `src/renderer/packages/context-management/`（`compaction-detector.ts`、`compaction.ts`、`compaction-boundary.ts`、`compaction-commit.ts`）
- `src/renderer/routes/index.tsx`（首页/临时会话/`createPersistedChatSession`）
