# Chatbox 会话与消息管理调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：从 [`../Chat/Chatbox-Chat调查笔记.md`](../Chat/Chatbox-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：会话与消息的持久化模型、生命周期、分支、索引与检索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 以**单会话（Session）为存储单元**，会话与消息是本地持久化的业务对象：

- 会话列表（sidebar）只认识 `SessionMetaRecord`（id/name/starred/hidden/archivedAt/sortOrder 等元信息），完全不知道 thread、fork、summary 这些"消息级"结构的存在（见第 1 节证据）。
- 首页是一个"假会话"（id 固定为字符串 `'new'`），真正的 `Session` 记录直到用户发出第一条消息才被创建（第 3 节）。
- 消息事实源是**双写**：完整 Session 对象写通用 `storage`，meta 记录写 IndexedDB `session-meta`，两者都要保持同步。
- thread（同会话内历史区间）、fork（同一消息位置的平行分支，替代回复可折叠为 ForkGroup 分支组）、summary（消息级压缩标记 + compactionPoints 配对契约）、starred（置顶分组）是**四套独立的数据结构**，唯一的交叉点是"move thread to conversations"会把 thread 转成新的顶层会话（第 1 节）。
- 归档 = `hidden: true` + `archivedAt` 时间戳，不删除任何数据；恢复归档不会重置 `sortOrder`。
- 消息搜索没有持久化倒排索引，按分页读取完整 Session 后逐条扫描。

## 系统边界与数据主链

```text
首页 'new' 假会话（纯 React state）
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

`SessionMetaSchema`（`shared/types.ts:390-400`）只挑了 `id/name/starred/hidden/archivedAt/assistantAvatarKey/picUrl/backgroundImage/type` 这些字段——**不包含** `threads`、`messageForksHash`、`messages`。`SessionList.tsx:106-121` 的分组逻辑只按 `starred` 分成 "Pinned" / "Chats" 两组。侧栏压根拿不到 thread/fork 数据，所以"会话列表分组"在数据结构层面就和 thread/fork 无关。

### 1.2 Thread：同一个 Session 内部的"历史区间"

`SessionThread`（`shared/types.ts:357-363`）：`{ id, name, messages, createdAt, compactionPoints? }`，存在 `session.threads: SessionThread[]` 里，是**同一个 Session 对象内部**的字段，不是独立记录。

产生 thread 的时机（均在 `stores/session/threads.ts`）：

- `switchThread(sessionId, threadId)`（`threads.ts:61-87`）：把**当前**消息打包成一个新 thread 塞进 `session.threads`，再把目标 thread 的消息换上来做当前消息——本质是"交换当前窗口与某个历史窗口"；
- `refreshContextAndCreateNewThread`/`startNewThread`（`threads.ts:93-127`）：把当前消息整个存成一条新 thread，当前消息清空成只留 system prompt；
- `compressAndCreateThread`（`threads.ts:156-208`，上下文压缩/摘要功能触发）：同样把旧消息存成 thread，当前消息替换为"system prompt + 一条包含压缩摘要文本的 user 消息"。

Thread 边界在数据侧的呈现：`sessionHelpers.getCurrentThreadHistoryHash(session)`（`sessionHelpers.ts:934-960`）把每个 thread 的**第一条消息 id** 映射成一个 `SessionThreadBrief`，作为渲染层插入 ThreadLabel 的依据（界面呈现见 Chat UI 笔记）。

### 1.3 Fork：某条消息之后的"平行分支"

`messageForksHash`（`shared/types.ts:346-355`，纯变换逻辑在 `shared/session/message-forks.ts`）结构是 `Record<forkPointMessageId, { position, lists: [{id, messages}], createdAt }>`——以"分叉点消息 id"为 key，`lists` 是各条分支的消息数组，`position` 是当前激活的分支下标。这也是挂在 `session`（或 `session.threads[i]`）上的字段，和侧栏无关。

产生方式是"重新生成/在新分支里重试"（`stores/session/generation.ts` 的 `regenerateInNewFork`/`generateMoreInNewFork`），执行语义见对话请求与上下文笔记。

提交范围内的数据语义变化（`ad248276`、`13bd78eb`、`810b5b04`）：

- fork 变换改为**纯函数 patch 模型**：`message-forks.ts` 只导出 `buildCreateForkPatch`/`buildCreateInactiveForkPatch`/`buildSwitchForkPatch`/`buildSwitchForkToPatch`/`buildDeleteForkPatch`/`buildExpandForkPatch` 等"算出一个 `Partial<Session>`"的函数，`forks.ts`（renderer store）负责应用 patch 并写回；新增 `createInactiveFork`（保存替代回复但不切换）、`expandFork`、`deleteFork`、`switchForkTo`（按位置切换）等动作，供 UI 的 ForkGroup 折叠分支组使用。
- 分支上下文重建改为**自底向上**：`buildCreateInactiveForkPatch`/`buildCreateForkPatch` 从分叉点向上逐段拼接消息上下文，避免旧实现"从分叉点向下递归"在大 fork 上呈指数级搜索（`13bd78eb`）。
- 压缩点（`compactionPoints`）在 fork 分支/复制会话时按完整 id 映射重映射，保证边界/摘要消息跨分支仍配对（`810b5b04`，见 1.4）。

`chatStore.ts` 里 `insertMessage`/`updateMessage`/`removeMessage`（`:613-779`）都要同时处理"消息可能在 `session.messages` 里，也可能在某个 `session.threads[i].messages` 里"两种情况——即 fork 和 thread 是可以叠加共存的两套独立坐标系。`removeMessage`（`chatStore.ts:785-835`）现在还会在全部分支列表里查找并删除目标消息（`removeMessageFromSavedForks`），并同步清理该消息引用的压缩点；`cleanupEmptyForkBranches`（`chatStore.ts:881-967`）合并为**同一个函数**内的两个分支：root 消息层命中时改写消息数组并自动切换分支，thread 层命中时只更新 hash——原先"root 层和 thread 层分别写了两段相似代码"的双写风险点已收敛为单函数内两条路径。

### 1.4 Summary：消息级压缩标记与压缩点

`Message.isSummary: boolean`（`shared/types.ts:331`），由自动压缩机制在某条消息上打标记，UI 用专门的 `SummaryMessage` 组件渲染，提供"删除摘要，恢复原始消息参与上下文计算"的操作。

提交范围（`810b5b04`）补全了压缩的数据语义：压缩不只打 `isSummary` 标记，还在 Session/thread 上持久化 `compactionPoints: CompactionPoint[]`（`{ summaryMessageId, boundaryMessageId, createdAt }` 配对契约，boundary 是摘要覆盖范围的边界消息）。共享层 `shared/context/compaction-points.ts` 的 `findLatestApplicableCompactionPoint` 要求 boundary 与 summary 两条消息都存在于当前消息路径上才生效（fork 分支切换可能拆散最新契约，此时跳过并回退到更早仍完整的压缩点）；renderer 侧 `packages/context-management/compaction-boundary.ts`（`findLastCompactionBoundaryMessage`，boundary 必须通过上下文合格性过滤且不能是 summary 自身）与 `compaction-commit.ts` 负责执行压缩。复制会话/挪 thread 成独立会话时，`remapCompactionPoints`（`shared/types.ts:305-345`）按完整 id 映射重映射压缩点，映射不上的点被丢弃（`crud.ts:60-119`）。

### 1.5 ForkMarker：唯一真正打通"消息级"与"会话级"的地方

`Message.isForkMarker + forkedFromSessionId`（`shared/types.ts:332-333`）是第四个概念：当"把某个 thread 挪成独立会话"（`moveThreadToConversations`/`moveCurrentThreadToConversations`，`threads.ts:210-251`）或"复制会话"（`copyAndSwitchSession`，`sessionActions`）时，会调 `copySession(...)`（`stores/session/crud.ts`）在**新会话**顶部插入一条 `isForkMarker: true` 的助手消息，`forkedFromSessionId` 指回源会话 id。**这是唯一一处"消息级分支"和"侧栏新增一个会话条目"产生真实关联的地方**——把一段 thread 历史"独立"出来，本质是新建一个真正的 `SessionMetaRecord`。

**结论**：会话列表分组（starred）、thread（同会话内的历史区间）、fork（同一消息位置的平行分支）、summary（消息级压缩标记）是四套完全独立的数据结构和交互面，唯一的交叉点是"move thread to conversations"这个操作会把 thread 数据转成一个新的顶层会话。

## 2. 事实源、索引与持久化

### 2.1 双写：完整 Session 与 meta 记录

置顶切换调 `updateSessionStore(session.id, { starred: !session.starred })`（`SessionItem.tsx:200-201, :284`）→ `chatStore.updateSession` → `updateSessionWithMessages`（`chatStore.ts:350-391`）。这个函数会**同时**写两处：完整 Session 对象（`storage.setItemNow`）和 meta 记录（`metaStorage.update`），再重排 react-query 缓存。

### 2.2 IndexedDB 分页游标与索引

`listSessionsMetaQueryOptions`（`chatStore.ts:89-95`）的 `queryFn` 调 `_listSessionsMetaPage(cursor)` → `metaStorage.getPage(cursor)`。真正的分页在 `IndexedDBSessionMetaStorage.getPage`（`SessionMetaStorage.ts:227-232`），默认页大小 `DEFAULT_PAGE_SIZE = 50`（`SessionMetaStorage.ts:7`）。

`getVisibleRecordsPage`（`SessionMetaStorage.ts:254-281`）分两段游标扫描：先在 `starredSortOrder` 索引上过滤 `starred === true` 取满页，若不够再在 `sortOrder` 索引上过滤 `starred !== true` 补齐——这保证了"置顶会话永远排在分页结果最前面"，而不是先整表排序再切页。

### 2.3 排序落地：分数索引

`reorderSessions(oldIndex, newIndex)`（`stores/session/crud.ts`）采用**分数索引（fractional indexing）**：新 `sortOrder` 取相邻两项 `sortOrder` 的平均值，边界情况用 `±1000` 的固定步长。移动一项只需要改这一项的 `sortOrder`，不需要重写整张表。移动后立即调 `metaStorage.update(...)` 写 IndexedDB，并同步更新 react-query 的分页缓存（`chatStore.updateSessionListData` + `sortSessionRecords` 重新排序）。

`sortSessionRecords`（`shared/utils/session-sort.ts:42-50`）是最终排序函数：先过滤 `hidden`，然后置顶优先、同组内按 `sortOrder` 降序。

### 2.4 IndexedDB schema 变更策略

IndexedDB session-meta 数据库有意不做 `version` 升级（`SessionMetaStorage.ts:51-55` 注释），只允许加法式 schema 变更，理由是版本号升级会导致用户降级客户端版本后打不开数据库；注释提到的"捕获 VersionError 后重试"的兜底策略在已读代码里**没有看到实现**——未核实是否真的存在于别处。

## 3. 创建、切换、归档、删除与恢复

### 3.1 惰性创建：`createPersistedChatSession`

`routes/index.tsx:272-353`，触发点是 `handleSubmit`（`routes/index.tsx:355-366`）调用 `createPersistedChatSession`：

1. 调 `createSessionStore(...)`（即 `chatStore.createSession`，见 `chatStore.ts:309-346`）用真实 uuid 创建 `Session`，并把 `sessionAgentModeMap.new`、`newSessionState.workingDirectories`、`newSessionState.agentFullAccess` **直接内联进 settings 参数**里一次性写入（`routes/index.tsx:290-299`），不是先创建再二次 patch。
2. 如果 `newSessionState.knowledgeBase` 存在：调 `addSessionKnowledgeBase(newSession.id, kb)` 把知识库绑定迁移到真实 id 上，然后 `setNewSessionState({})` **整体清空**（不是只清 knowledgeBase 字段）——`workingDirectories`/`agentFullAccess` 已经在第 1 步内联进新 session 的 settings 了，所以整体清空不会丢数据，但这个耦合关系并不直观。
3. `sessionWebBrowsingMap.new` 若存在：`setSessionWebBrowsing(newSession.id, value)` + `clearSessionWebBrowsing('new')`。
4. `sessionAgentModeMap.new` 若存在：仅 `clearSessionAgentMode('new')`（因为 agentMode 已经在第 1 步写入了 settings）。
5. `switchCurrentSession(newSession.id)`（路由跳转到 `/session/$sessionId`）。
6. `localStorage.removeItem('new-chat')`——**未核实**：在本次阅读范围内没有找到写入 `'new-chat'` 这个 key 的代码，可能是遗留逻辑或由别处写入。

`chatStore.createSession`（`chatStore.ts:309-346`）本身还有一个细节：新建 session 的 `settings` 会先套一层"上次使用模型"（`lastUsedModelStore` 的 `chat`/`picture` 字段），再用调用方传入的 `settings` 覆盖——即"新会话默认延续上次用的模型"这条规则是在创建时刻硬编码合并的。

### 3.2 置顶 / 归档 / 恢复 / 永久删除

全部通过 `SessionMetaRecord` 上的字段完成，**没有单独的"归档表"**：

- **置顶**：`session.starred: boolean`，切换走 `updateSessionWithMessages` 双写（见 2.1）。
- **归档**：`archiveSession(id)`（`chatStore.ts:495-498`）：

  ```ts
  export async function archiveSession(id: string) {
    await updateSession(id, { hidden: true, archivedAt: Date.now() })
    await refreshArchivedSessionListCache()
  }
  ```

  即归档 = `hidden: true`（让它在主列表分页查询里被过滤掉——`getPage`/`getTotal` 都过滤 `!record.hidden`）+ `archivedAt` 时间戳（供归档列表按时间排序/过滤，`archivedAt` 索引）。**不删除任何数据**。
- **批量归档**（`clearConversationList` 对应的底层实现，`chatStore.ts:502-531`）故意**逐个**调用 `updateSession`，代码注释直言：

  ```ts
  // 这里刻意逐个走 updateSession，保证完整 session 存储和 meta 存储一致。
  // 该实现不针对超大批量归档做性能优化。
  ```

  这是一个明确写在代码里的、已知的性能取舍。
- **恢复**：`restoreSession(id)`（`chatStore.ts:533-537`）：`updateSession(id, { hidden: false, archivedAt: undefined })`。**不会重置 `sortOrder`**——恢复后的会话会出现在它归档前的原始排序位置，不会被顶到列表最上面。这是一个容易让用户困惑的行为（恢复的会话可能"消失"在列表很靠下的位置）。
- **永久删除**：`deleteSession(id)`（`chatStore.ts:484-493`）/批量 `deleteSessions(ids)`（`:539-557`）。删除动作包含：
  1. 清理该会话的 session-attachment RAG 索引（`platform.getSessionAttachmentRagController().deleteSessionAttachments`）；
  2. 从通用 `storage` 删除完整 Session 对象（`storage.removeItem`）；
  3. 从 IndexedDB 的 meta store 删除记录（`metaStorage.delete`）；
  4. 同步剔除主列表和归档列表两个 react-query 缓存；
  5. `cleanupDeletedSessionRuntimeState(id)`（`chatStore.ts:471-482`）：清理 session query 缓存、`uiStore` 里的 webBrowsing/knowledgeBase/agentMode 三个 map、`throttleWriteSessionAtom` 缓存、消息列表滚动位置缓存、挂起的 `UpdateQueue`，并在桌面端调用 `platform.sandboxReset`/`sandboxRemoveArtifacts` 删除该会话在沙箱里生成的落地文件。

删除前会先调 `confirmSessionDeletion(id)`（`chatStore.ts:439-456`）：仅桌面端、且仅当该会话在沙箱里有可下载产物（`platform.sandboxHasArtifacts`）时才弹"删除会话将永久删除这些文件"的确认框；这个确认逻辑同时被 `routes/settings/archive.tsx:135`（归档列表里的删除按钮）复用。

## 4. 编辑、重试、续写、回退与分支语义

- Fork 的数据语义见 1.3：`regenerateInNewFork`/`generateMoreInNewFork` 产生新的分支数组，`position` 记录激活分支。
- "把 thread 挪成独立会话"与"复制会话"都会 `copySession(...)` 在**新会话**顶部插入 `isForkMarker` 消息并指回源会话（1.5），即会话级复制在数据上就是新建一个 `SessionMetaRecord`。
- 分支清理存在 root 层与 thread 层两套相似但不完全相同的实现（`cleanupEmptyForkBranches`，`chatStore.ts:786-872`），是潜在的双写不一致风险点。
- 编辑、删除、重试产生的数据变更入口是 `insertMessage`/`updateMessage`/`removeMessage`（`chatStore.ts:613-779`）；重试、续写、再生成的**执行链**（如何选择起始上下文、重新调用模型）在对话请求与上下文笔记。

## 5. 列表、分页、搜索与定位

- **会话列表**：react-query 无限查询 + IndexedDB 游标分页（2.2）。`SessionList.tsx:124-128` 用 Virtuoso 的 `endReached` 触发 `fetchNextPage()`，`hasNextPage` 时挂 `SessionListLoadingFooter`。
- **会话项活动指示（不持久化）**：侧栏的"生成中/回复完成未读"指示来自内存 zustand store（`sessionActivityStore.ts` + `generation-runtime.ts`，`81571269`），以会话 id 为 key 的临时集合，**不写 `SessionMetaRecord`、不落盘**，重启即清空——`SessionMetaSchema` 仍是侧栏唯一的持久化认知（界面呈现见 Chat UI 笔记 1.2）。
- **消息搜索**：Chatbox 有一套独立于消息列表渲染的搜索实现，并非只有 DOM 文本搜索：`stores/sessionHelpers.ts:871-875,880-929` 对当前消息和历史 Thread 的 `contentParts` 做文本匹配，全部会话按 IndexedDB 元数据分页（每页 30 个）读取完整 Session，最多返回 50 条命中消息。这套实现**没有持久化倒排索引**，跨会话搜索仍是按页读取并逐条扫描；它不受 Virtuoso 虚拟窗口的 DOM 挂载范围限制。消息匹配覆盖当前线程和历史 Thread，也会读取文本、reasoning、info、tool-call 状态及文件名（`shared/services/native-session-search.ts:8-25,55-75`）。搜索入口与结果定位的工作流在 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

- **两条写路径**：`updateStreamingCache(sessionId, message)`（`stores/session/messages.ts:132-137`）只改 react-query 缓存，**不碰 storage**，注释写明"性能优先，不检查 session 存在性"；`persistStreamingMessage(...)`（`:143-155`）走每会话一个的 `UpdateQueue`（`stores/updateQueue.ts`，基于 `queueMicrotask` 的串行合并队列，避免并发 update 互相覆盖），**真正写 storage**。节流策略（2 秒定时 + tool-call 特例）属于对话请求与上下文笔记。
- **缓存合并保护**：`updateSession`（元数据更新路径，`chatStore.ts:394-410`）调用时传了 `{ preserveCachedGeneratingMessages: true }`（见 `_setSessionCache`，`chatStore.ts:287-300`），实际合并逻辑在 `mergeCachedGeneratingMessages`（`chatStore-cache.ts:26-52`）：当磁盘上读回来的 session（可能是较旧的快照）要写回缓存时，如果某条消息在缓存里 `generating: true`，就保留缓存里那条（更新的）内容，不用磁盘上更旧的内容覆盖。这是为了防止"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的内容。`5ec9eb70` 起删除生成中的消息同样走 `preserveCachedGeneratingMessages` 全量写路径（`removeMessage`，`chatStore.ts:785-835`），注释明确"合并只映射仍然存在的消息，不会复活已删除消息"。
- **删除时的状态清理**：`cleanupDeletedSessionRuntimeState` 统一清理 query 缓存、UI map、节流缓存、滚动位置与挂起队列（3.2 删除第 5 步）。

## 7. 迁移、导入导出与保留策略

- IndexedDB schema 只做加法式变更、不做 version 升级，以兼容降级客户端（2.4）。
- `365ef248` 起备份导入不再依赖 `crypto.randomUUID`（部分浏览器/WebView 环境缺失该 API 时用回退 id 生成），导入在移动/Web 端更稳。
- 导入导出、备份恢复、崩溃恢复与多窗口竞争在本类目范围内未做运行验证（见未验证事项）。

## 8. Agent、模型、知识库与附件绑定

- **首次创建时内联**：`workingDirectories`、`agentFullAccess`、agentMode 在 `createPersistedChatSession` 里直接内联进新 Session 的 `settings`（3.1）。
- **知识库**：前端状态只存 `Pick<KnowledgeBase, 'id'|'name'>` 句柄（`uiStore.sessionKnowledgeBaseMap` 或新会话的 `newSessionState.knowledgeBase`），绑定以会话 id 为 key；真实检索发生在生成阶段（见对话请求与上下文笔记）。
- **Copilot**：选中 copilot 时把 `session.copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`——创建出来的仍然是一个普通 `type: 'chat'` 的 Session，只是多了一个 `copilotId` 字段用于用量统计（`remote.recordCopilotUsage`，在 create_session/create_thread/create_message 三个动作点调用）。
- **网页浏览**：`sessionWebBrowsingMap: Record<string, boolean|undefined>`（`uiStore.ts:36`）按会话 id 保存布尔开关；默认值规则（ChatboxAI provider 默认开、其他 provider 默认关）在 Chat UI 笔记的输入区部分记录。

## 9. 设计取舍与已确认边界

- **批量归档故意不做性能优化**：代码注释直接承认"逐个走 `updateSession`，不针对超大批量归档做性能优化"（`chatStore.ts:500-501`）——是被记录在案、而非被忽略的工程取舍。
- **恢复归档会话不重置 `sortOrder`**：恢复后出现在归档前位置而非列表顶部，可能与用户预期不符。
- **Fork 清理双路径收敛**：`cleanupEmptyForkBranches` 已合并为单一函数内的 root/thread 两条路径（`chatStore.ts:881-967`），较旧快照的"两段相似代码"风险点仍在但范围已收敛；root 层会改写消息数组并自动切换分支、thread 层只更新 hash，两者行为仍不完全对称。
- **IndexedDB 无 version 升级**：兼容降级客户端的代价是 schema 只能加法演进（2.4）。
- **类目边界**：本笔记只回答数据语义；停止生成的半截消息最终如何落盘、重试如何选择上下文属于对话请求与上下文；列表虚拟化、滚动锚定与消息壳装配属于消息渲染器（`../消息渲染器/Chatbox-消息渲染调查笔记.md`）。

## 10. 未验证事项

- `localStorage.removeItem('new-chat')` 的对应写入点未找到，可能是遗留逻辑（3.1 第 6 步）。
- `context-management` 包内的压缩**触发阈值**（何时自动压缩、按什么预算）未逐行展开（1.4 已核实压缩点的结构、边界选择与落盘语义，`compaction-commit.ts` 的具体执行细节未完全读取）。
- provider 侧 token 截断策略、导入导出、崩溃恢复、多窗口并发写入需要运行验证。
- IndexedDB "捕获 VersionError 后重试"的兜底实现未在已读代码中找到（2.4）。
- 侧栏"生成中/未读完成"指示为内存态，跨重启/多窗口的同步行为未验证（5）。

## 11. 关键源码索引

- `src/shared/types.ts`（`Session`/`Message`/`SessionThread`/`MessageForkEntry`/`SessionMetaSchema` 等 schema）
- `src/renderer/stores/chatStore.ts`（会话 CRUD、分页缓存、归档/删除、streaming cache 合并）
- `src/renderer/stores/chatStore-cache.ts`（`mergeCachedGeneratingMessages`）
- `src/renderer/stores/updateQueue.ts`
- `src/renderer/stores/session/threads.ts`、`forks.ts`、`messages.ts`（`updateStreamingCache`/`persistStreamingMessage`）
- `src/renderer/stores/session/crud.ts`（`reorderSessions`、`copySession`）
- `src/renderer/storage/SessionMetaStorage.ts`（IndexedDB 分页/索引/游标）
- `src/shared/session/message-forks.ts`（fork 纯变换函数）
- `src/shared/utils/session-sort.ts`（`sortSessionRecords`）
- `src/renderer/stores/sessionHelpers.ts`（`getCurrentThreadHistoryHash`）
- `src/shared/services/native-session-search.ts`（消息匹配扫描）
- `src/renderer/routes/index.tsx`（首页/临时会话/迁移逻辑）
