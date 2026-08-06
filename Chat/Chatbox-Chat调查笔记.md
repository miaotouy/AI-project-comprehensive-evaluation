# Chatbox Chat 功能调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：未确认
>
> 代码快照：`7450ab2dde5eacab4a8721f8680006ba8b99438d`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/renderer/routes/index.tsx`、`src/renderer/routes/session/$sessionId.tsx`、`src/renderer/components/session/*`、`src/renderer/stores/session/*`、`src/renderer/stores/chatStore.ts`、`src/renderer/stores/uiStore.ts`、`src/renderer/storage/SessionMetaStorage.ts`、`src/shared/session/message-forks.ts`、`src/shared/types.ts` 等），未凭空推断；不确定处标注"未核实"。
>
> 调查范围：聊天会话、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

说明：下面每一条结论都给出文件路径+行号证据。

## 1. 定位

Chatbox 的 Chat 功能是一个 **local-first、单会话（Session）为存储单元**的多模型聊天系统。核心特征：

- 会话列表（sidebar）只认识 `SessionMetaRecord`（id/name/starred/hidden/archivedAt/sortOrder 等元信息），完全不知道 thread、fork、summary 这些"消息级"结构的存在（见第 4 节的证据）。
- 首页是一个"假会话"（id 固定为字符串 `'new'`），真正的 `Session` 记录直到用户发出第一条消息才被创建（第 2 节）。
- 流式生成把"UI 立即刷新"和"落盘持久化"拆成两条频率完全不同的路径（第 5 节），这是本项目工程复杂度最高的部分之一。
- Agent 模式、知识库、网页浏览三种"输入区上下文增强"在底层被统一建模成同一个工具注册管线里的三个开关，而不是三套独立的 prompt 拼接逻辑（第 6 节）。

## 2. 首页 "new" 临时会话机制

### 2.1 临时会话对象本身

`src/renderer/routes/index.tsx:83-86`：

```ts
const [session, setSession] = useState<Session>({
  id: 'new',
  ...initEmptyChatSession(),
})
```

`session` 是纯本地 React state，`id` 硬编码为字符串 `'new'`（不是 uuid）。`model`（provider/modelId）、`copilotId`、`name`、`messages`（copilot 的 system prompt）、`assistantAvatarKey`/`picUrl`/`backgroundImage` 全部存在这个 state 里，**不落地任何 store**。

### 2.2 临时状态被拆到三个不同的存储位置

`InputBox.tsx` 通过 `isNewSession = currentSessionId === 'new'`（`InputBox.tsx:233-234`）判断分支，但不同类型的"待发送状态"实际上被分散存放在三种不同的容器里：

1. **本地组件 state**（仅 `routes/index.tsx` 内）：模型选择、copilotId、name、messages、头像。
2. **专用临时对象 `newSessionState`**（`uiStore.ts:40-47`）：

   ```ts
   newSessionState: {
     knowledgeBase?: Pick<KnowledgeBase, 'id' | 'name'>
     webBrowsing?: boolean          // 类型里声明了，但实际未被写入/读取（见下）
     workingDirectories?: string[]
     agentFullAccess?: boolean
   }
   ```

   `useKnowledgeBase({ isNewSession })`（`hooks/useKnowledgeBase.ts:16-20`）对新会话读写的是 `newSessionState.knowledgeBase`，而不是通用的 `sessionKnowledgeBaseMap['new']`。

3. **通用的"按 sessionId 映射"Map，直接复用字符串 `'new'` 当 key**：
   - `sessionWebBrowsingMap: Record<string, boolean|undefined>`（`uiStore.ts:36`），`InputBox.tsx:242`：`sessionWebBrowsingMap[currentSessionId || 'new']`。
   - `sessionAgentModeMap: Record<string, AgentModeEntry>`（`uiStore.ts:60`），读取见 `stores/session/agent-mode.ts:23-26`（`legacyMap[sessionId]`，`sessionId` 传入的就是 `'new'`）。

也就是说，`newSessionState.webBrowsing` 这个字段在类型定义里存在，但网页浏览的真实临时值走的是 `sessionWebBrowsingMap['new']`，两者是两套并行机制——`newSessionState.webBrowsing` 看起来是**未被使用的死字段**（grep 未发现任何 `newSessionState.webBrowsing` 的写入点，仅类型声明）。这是一处具体的实现细节/技术债。

### 2.3 首次发送时的迁移：`createPersistedChatSession`

`routes/index.tsx:272-353`，触发点是 `handleSubmit`（`routes/index.tsx:355-366`）调用 `createPersistedChatSession`：

1. 调 `createSessionStore(...)`（即 `chatStore.createSession`，见 `chatStore.ts:309-346`）用真实 uuid 创建 `Session`，并把 `sessionAgentModeMap.new`、`newSessionState.workingDirectories`、`newSessionState.agentFullAccess` **直接内联进 settings 参数**里一次性写入（`routes/index.tsx:290-299`），不是先创建再二次 patch。
2. 如果 `newSessionState.knowledgeBase` 存在：调 `addSessionKnowledgeBase(newSession.id, kb)` 把知识库绑定迁移到真实 id 上，然后 `setNewSessionState({})` **整体清空**（不是只清 knowledgeBase 字段）——`workingDirectories`/`agentFullAccess` 已经在第 1 步内联进新 session 的 settings 了，所以整体清空不会丢数据，但这个耦合关系并不直观。
3. `sessionWebBrowsingMap.new` 若存在：`setSessionWebBrowsing(newSession.id, value)` + `clearSessionWebBrowsing('new')`。
4. `sessionAgentModeMap.new` 若存在：仅 `clearSessionAgentMode('new')`（因为 agentMode 已经在第 1 步写入了 settings）。
5. `switchCurrentSession(newSession.id)`（路由跳转到 `/session/$sessionId`）。
6. `localStorage.removeItem('new-chat')`——**未核实**：在本次阅读范围内没有找到写入 `'new-chat'` 这个 key 的代码，可能是遗留逻辑或由别处（未读到的文件）写入。

`chatStore.createSession`（`chatStore.ts:309-346`）本身还有一个细节：新建 session 的 `settings` 会先套一层"上次使用模型"（`lastUsedModelStore` 的 `chat`/`picture` 字段），再用调用方传入的 `settings` 覆盖——即"新会话默认延续上次用的模型"这条规则是在创建时刻硬编码合并的，而不是在 UI 层做的默认值填充。

## 3. SessionList 分页加载与拖放排序

### 3.1 数据来源：react-query 无限查询 + IndexedDB 游标分页

`chatStore.ts:163-173`：

```ts
export function useSessionList() {
  const result = useInfiniteQuery(listSessionsMetaQueryOptions)
  ...
}
```

`listSessionsMetaQueryOptions`（`chatStore.ts:89-95`）的 `queryFn` 调 `_listSessionsMetaPage(cursor)` → `metaStorage.getPage(cursor)`。真正的分页在 `IndexedDBSessionMetaStorage.getPage`（`SessionMetaStorage.ts:227-232`），默认页大小 `DEFAULT_PAGE_SIZE = 50`（`SessionMetaStorage.ts:7`）。

`getVisibleRecordsPage`（`SessionMetaStorage.ts:254-281`）分两段游标扫描：先在 `starredSortOrder` 索引上过滤 `starred === true` 取满页，若不够再在 `sortOrder` 索引上过滤 `starred !== true` 补齐——这保证了"置顶会话永远排在分页结果最前面"，而不是先整表排序再切页。

`SessionList.tsx:124-128` 用 Virtuoso 的 `endReached` 触发 `fetchNextPage()`：

```ts
const onEndReached = useCallback(() => {
  if (hasNextPage && !isFetchingNextPage) fetchNextPage()
}, ...)
```

即滚到底自动翻页；`hasNextPage` 时挂一个 `SessionListLoadingFooter`（转圈图标，`SessionList.tsx:43-49`）。

### 3.2 拖放排序：dnd-kit + 同组约束 + 分数索引

用的库是 `@dnd-kit/core` + `@dnd-kit/sortable`（`SessionList.tsx:1-20`），不是 react-beautiful-dnd 或 sortablejs。三种传感器：`TouchSensor`（150ms 延迟、8px 容差）、`MouseSensor`（10px 移动阈值才激活，避免误触发拖拽而不是点击）、`KeyboardSensor`（`SessionList.tsx:57-70`）。

关键约束（`SessionList.tsx:82-89`）：拖拽只在**同一个置顶分组内**生效——

```ts
if (oldIndex < 0 || newIndex < 0 || !areSessionsInSamePinGroup(activeSession, overSession)) {
  return
}
```

`areSessionsInSamePinGroup`（`shared/utils/session-sort.ts:3-8`）就是判断两者 `starred` 值是否相同。也就是说**不能靠拖拽把一个未置顶会话拖进置顶区**，必须先手动点"置顶"。

排序结果落地在 `reorderSessions(oldIndex, newIndex)`（`stores/session/crud.ts`，见工具结果里的 grep 输出），采用**分数索引（fractional indexing）**：新 `sortOrder` 取相邻两项 `sortOrder` 的平均值，边界情况用 `±1000` 的固定步长（未在两侧都有邻居时）。这样移动一项只需要改这一项的 `sortOrder`，不需要重写整张表——是标准的"支持任意插入不做整表重排"的分数索引实现。移动后立即调 `metaStorage.update(...)` 写 IndexedDB，并同步更新 react-query 的分页缓存（`chatStore.updateSessionListData` + `sortSessionRecords` 重新排序）。

移动端有一个独立的"调整顺序模式"：普通情况下小屏幕禁止拖拽（`SessionList.tsx:71`：`!isSmallScreen || isReordering ? [touchSensor] : []`；`SortableItem` 的 `disabled` 由 `isSmallScreen && !isReordering` 控制），必须先在 `SessionItem` 的长按菜单里点"Adjust order"（`SessionItem.tsx:204-209`）进入 `isReordering` 状态，此时才出现拖拽把手图标（`IconGripVertical`），顶部出现一条带"Done"按钮的提示条（`SessionList.tsx:150-170`）。这是典型的 iOS 风格"进入编辑模式再拖拽"。

`sortSessionRecords`（`shared/utils/session-sort.ts:42-50`）是最终排序函数：先过滤 `hidden`，然后置顶优先、同组内按 `sortOrder` 降序。

## 4. 置顶 / 归档 / 恢复 / 永久删除

全部通过 `SessionMetaRecord` 上的字段完成，**没有单独的"归档表"**：

- **置顶**：`session.starred: boolean`。切换调 `updateSessionStore(session.id, { starred: !session.starred })`（`SessionItem.tsx:200-201`, `:284`）→ `chatStore.updateSession` → `updateSessionWithMessages`（`chatStore.ts:350-391`）。这个函数会**同时**写两处：完整 Session 对象（`storage.setItemNow`）和 meta 记录（`metaStorage.update`），再重排 react-query 缓存。
- **归档**：`archiveSession(id)`（`chatStore.ts:495-498`）：

  ```ts
  export async function archiveSession(id: string) {
    await updateSession(id, { hidden: true, archivedAt: Date.now() })
    await refreshArchivedSessionListCache()
  }
  ```

  即归档 = `hidden: true`（让它在主列表分页查询里被过滤掉——`getPage`/`getTotal` 都过滤 `!record.hidden`）+ `archivedAt` 时间戳（供归档列表按时间排序/过滤，`archivedAt` 索引）。**不删除任何数据**。

  `SessionItem.archiveCurrentSession`（`SessionItem.tsx:109-138`）额外做了两件事：
  1. 如果当前正打开的就是被归档的会话，`router.navigate({ to: '/', replace: true })` 跳回首页；
  2. 归档总数超过 `ARCHIVED_SESSION_CLEANUP_THRESHOLD = 600`（`SessionItem.tsx:24`）时弹确认框建议去 Settings 清理；否则最多每 24 小时（`ARCHIVE_TIP_INTERVAL`，用 `localStorage['chatbox:lastArchiveSessionTipAt']` 记录）弹一次"已归档，去设置管理"的 toast。

- **批量归档**（`clearConversationList`/"Clear Conversation List" 弹窗对应的底层实现，`chatStore.ts:502-531`）故意**逐个**调用 `updateSession`，代码注释直言：

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

## 5. Thread、Fork、Summary 与"会话列表分组"——用代码证明它们不是一回事

### 5.1 会话列表分组：只认 `starred`，不知道 thread/fork 存在

`SessionMetaSchema`（`shared/types.ts:390-400`）只挑了 `id/name/starred/hidden/archivedAt/assistantAvatarKey/picUrl/backgroundImage/type` 这些字段——**不包含** `threads`、`messageForksHash`、`messages`。`SessionList.tsx:106-121` 的分组逻辑：

```ts
const pinnedSessions = sortedSessions.filter((session) => session.starred)
const otherSessions = sortedSessions.filter((session) => !session.starred)
```

只按 `starred` 分成 "Pinned" / "Chats" 两组。侧栏压根拿不到 thread/fork 数据（因为 `SessionMetaRecord` 类型里没有这些字段），所以"会话列表分组"在数据结构层面就和 thread/fork 无关，不是同一套机制的两种视图。

### 5.2 Thread：同一个 Session 内部的"历史区间"

`SessionThread`（`shared/types.ts:357-363`）：`{ id, name, messages, createdAt, compactionPoints? }`，存在 `session.threads: SessionThread[]` 里，是**同一个 Session 对象内部**的字段，不是独立记录。

产生 thread 的时机（均在 `stores/session/threads.ts`）：
- `switchThread(sessionId, threadId)`（`threads.ts:61-87`）：把**当前**消息打包成一个新 thread 塞进 `session.threads`，再把目标 thread 的消息换上来做当前消息——本质是"交换当前窗口与某个历史窗口"；
- `refreshContextAndCreateNewThread`/`startNewThread`（`threads.ts:93-127`）：把当前消息整个存成一条新 thread，当前消息清空成只留 system prompt；
- `compressAndCreateThread`（`threads.ts:156-208`，上下文压缩/摘要功能触发）：同样把旧消息存成 thread，当前消息替换为"system prompt + 一条包含压缩摘要文本的 user 消息"。

Thread 边界在 UI 上怎么呈现：`sessionHelpers.getCurrentThreadHistoryHash(session)`（`sessionHelpers.ts:934-960`）把每个 thread 的**第一条消息 id** 映射成一个 `SessionThreadBrief`；`MessageList.tsx` 里 `renderMessageBlock`（`:428-472`）在渲染每条消息前检查 `currentThreadHash[msg.id]`，如果命中就在该消息上方插入一个 `ThreadLabel`（`MessageList.tsx:679-755`）——也就是说**thread 边界是消息列表里的一个内联锚点标签**（"# threadName"，可点开菜单编辑名字/在抽屉里定位/继续这个 thread/移到独立会话/删除），和侧栏完全无关。`ThreadHistoryDrawer.tsx` 提供的是当前会话内所有 thread 的一个侧滑抽屉列表，作用域也仅限"这一个 Session"。

### 5.3 Fork：某条消息之后的"平行分支"

`messageForksHash`（`shared/types.ts:346-355`，纯变换逻辑在 `shared/session/message-forks.ts`）结构是 `Record<forkPointMessageId, { position, lists: [{id, messages}], createdAt }>`——以"分叉点消息 id"为 key，`lists` 是各条分支的消息数组，`position` 是当前激活的分支下标。这也是挂在 `session`（或 `session.threads[i]`）上的字段，和侧栏无关；产生方式是"重新生成/在新分支里重试"（`stores/session/generation.ts` 的 `regenerateInNewFork`/`generateMoreInNewFork`）。UI 呈现是 `MessageList.tsx` 的 `ForkNav`（`:613-673`）：分叉点消息下方一个"◀ 1/2 ▶"控件，点左右箭头切换分支内容，是**同一条消息位置上的内容替换**，不产生新的侧栏条目，也不是 thread。

`chatStore.ts` 里 `insertMessage`/`updateMessage`/`removeMessage`（`:613-779`）都要同时处理"消息可能在 `session.messages` 里，也可能在某个 `session.threads[i].messages` 里"两种情况——即 fork 和 thread 是可以叠加共存的两套独立坐标系，`cleanupEmptyForkBranches`（`chatStore.ts:786-872`）对 root 层和 thread 层分别写了两段相似但不完全相同的清理逻辑，是潜在的"改一处忘改另一处"风险点。

### 5.4 Summary：消息级压缩标记

`Message.isSummary: boolean`（`shared/types.ts:331`），由自动压缩机制在某条消息上打标记，UI 用专门的 `SummaryMessage` 组件渲染（不是普通气泡），提供"删除摘要，恢复原始消息参与上下文计算"的操作（据 `docs/ui-inventory.md` 文本清单）。摘要产生的具体触发代码在 `context-management` 包内——**未核实**（本次没有读取该包源码，只读到了调用点 `stores/session/messages.ts:198-205` 的 `runCompactionWithUIState`）。

### 5.5 ForkMarker：唯一真正打通"消息级"与"会话级"的地方

`Message.isForkMarker + forkedFromSessionId`（`shared/types.ts:332-333`）是第四个、和上面三者都不同的概念：当"把某个 thread 挪成独立会话"（`moveThreadToConversations`/`moveCurrentThreadToConversations`，`threads.ts:210-251`）或"复制会话"（`copyAndSwitchSession`，`sessionActions`）时，会调 `copySession(...)`（`stores/session/crud.ts`）在**新会话**顶部插入一条 `isForkMarker: true` 的助手消息，`forkedFromSessionId` 指回源会话 id，由 `ForkMarkerMessage` 组件渲染成"Forked from conversation"的提示条。**这是唯一一处"消息级分支"和"侧栏新增一个会话条目"产生真实关联的地方**——把一段 thread 历史"独立"出来，本质是新建一个真正的 `SessionMetaRecord`，而不是在原会话结构里做记号。

**结论**：会话列表分组（starred）、thread（同会话内的历史区间）、fork（同一消息位置的平行分支）、summary（消息级压缩标记）是四套完全独立的数据结构和交互面，唯一的交叉点是"move thread to conversations"这个操作会把 thread 数据转成一个新的顶层会话。

## 6. 流式消息更新机制：UI cache 高频更新 vs 落盘节流

### 6.1 两条完全独立的写路径

`stores/session/messages.ts`：

- `updateStreamingCache(sessionId, message)`（`:132-137`）：只调 `chatStore.updateMessageCache` → `updateSessionCache`/`updateSessionCacheSync`（`chatStore.ts:413-432`）→ 直接 `queryClient.setQueryData` 改 react-query 缓存，**不碰 storage**，注释里写明"性能优先，不检查 session 存在性"。
- `persistStreamingMessage(sessionId, message, options)`（`:143-155`）：调 `chatStore.updateMessage` → `updateSessionWithMessages`（`chatStore.ts:350-391`），走每会话一个的 `UpdateQueue`（`stores/updateQueue.ts`，基于 `queueMicrotask` 的串行合并队列，避免并发 update 互相覆盖），**真正写 storage**。

### 6.2 节流策略：2 秒定时 + 特例立即持久化

节流判断函数 `shouldPersistStreamingChunk`（`stores/session/orchestration.ts:437-446`）：

```ts
export function shouldPersistStreamingChunk(chunkType, elapsedMs, persistInterval) {
  // Tool calls can block the stream for a long time (waiting on approval),
  // so persist them immediately instead of relying on the periodic 2s flush.
  return chunkType === 'tool-call' || elapsedMs >= persistInterval
}
```

`persistInterval` 硬编码 `2000`（`orchestration.ts:471`）。主循环（`orchestration.ts:632-675`，遍历 `model.chatStream` 产出的每个 chunk）里：

```ts
const shouldPersist = shouldPersistStreamingChunk(chunk.type, Date.now() - lastPersistTimestamp, persistInterval)
if (shouldPersist) {
  void persistStreamingMessage(sessionId, targetMsg)   // 落盘（异步、不等待）
} else {
  updateStreamingCache(sessionId, targetMsg)            // 只刷 UI
}
```

也就是：**每个 text-delta/reasoning-delta chunk 都会立刻刷新 UI 缓存**（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"这个 chunk 是 tool-call"时才真正写 storage。流结束/出错/暂停时还各自补一次无条件的 `persistStreamingMessage(..., { refreshCounting: true })`（`:688, 718, 739, 751, 758`），确保最终态一定落盘。

`tool-call` 被特殊处理的原因写在注释里：tool-call 可能长时间阻塞在等用户批准（`user_exec_approval`/`file_mutation_approval`/`app_action_approval`），如果不立刻持久化，用户刷新/关闭应用会丢失这个待批准状态。

### 6.3 落盘时不丢失"正在生成"的消息（缓存合并保护）

`updateSession`（元数据更新路径，`chatStore.ts:394-410`）调用时传了 `{ preserveCachedGeneratingMessages: true }`（见 `_setSessionCache`，`chatStore.ts:287-300`），实际合并逻辑在 `mergeCachedGeneratingMessages`（`chatStore-cache.ts:26-52`）：当磁盘上读回来的 session（可能是较旧的快照）要写回缓存时，如果某条消息在缓存里 `generating: true`，就保留缓存里那条（更新的）内容，不用磁盘上更旧的内容覆盖。这是为了防止"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的内容。

### 6.4 一处疑似死代码：`throttleWriteSessionAtom.ts`

`stores/atoms/throttleWriteSessionAtom.ts` 里实现了一整套独立的 jotai atom + `WriteQueue`（`:23-66`），`flushInterval` 同样硬编码 `2000`ms（`:28`）——看起来是同一个"节流落盘"想法的另一份实现。全仓库 grep `createSessionAtom` 的结果（含本次单独复核）：

```
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:8
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:74
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:82
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:86
```

只有定义文件内部引用，**没有任何外部调用点**。同文件里的 `cleanupSessionAtomCache` 则确实被 `chatStore.ts:37,476` 引用（用于删除会话时清缓存）。也就是说这个模块里"创建/写入 atom"的那部分（`createSessionAtom`、`WriteQueue`）大概率是被废弃的旧实现，只有"清理"那半个函数还留在调用链里——是一处具体的、可指出文件+行号的死代码/技术债。

## 7. 输入区承接的上下文：Copilot / 知识库 / 网页浏览

### 7.1 Copilot：本质是"系统提示词模板"，不是独立会话类型

`CopilotDetail`（`shared/types.ts:94-108`）：`{id, name, prompt, picUrl(deprecated), avatar, backgroundImage, description, tags, screenshots, createdAt, updatedAt, usedCount, sourceId, starred}`。选中一个 copilot 时（`routes/index.tsx:211-234`），行为是把 `session.copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`——创建出来的仍然是一个普通 `type: 'chat'` 的 Session，只是多了一个 `copilotId` 字段用于用量统计（`remote.recordCopilotUsage`，在 create_session/create_thread/create_message 三个动作点调用，`routes/index.tsx:302-306`、`routes/session/$sessionId.tsx:148-152, 178-182`）。

### 7.2 知识库：客户端只存一个 id/name 句柄，真正生效靠"工具"

前端状态只是 `Pick<KnowledgeBase, 'id'|'name'>`（`uiStore.sessionKnowledgeBaseMap` 或新会话的 `newSessionState.knowledgeBase`），没有把知识库内容拉到前端。真正生效的地方是生成阶段的 `buildToolsForSession`（`stores/session/tools-builder.ts:241-249`）：

```ts
const kbSupported = includeAgentTools && knowledgeBase && model.isSupportToolUse('knowledge-base')
...
if (knowledgeBase && kbSupported) {
  kbToolSet = await getKBToolSet(knowledgeBase.id, knowledgeBase.name)
}
```

即知识库是作为**一个模型可调用的工具**注册进去的（`getToolSet as getKBToolSet` 来自 `@/packages/model-calls/toolsets/knowledge-base`），依赖模型是否支持 `'knowledge-base'` 这个 `ToolUseScope`（`shared/types.ts:227`：`ToolUseScopeSchema = z.enum(['agent','web-browsing','knowledge-base','read-file'])`），而不是把知识库检索结果拼进 prompt 文本。

### 7.3 网页浏览：每会话布尔开关 + provider 默认值

`sessionWebBrowsingMap: Record<string, boolean|undefined>`（`uiStore.ts:36`）。`InputBox.tsx:241-248` 的默认值规则：如果该会话没有显式设置过，ChatboxAI provider 默认开、其他 provider 默认关。生成时 `getSessionWebBrowsing(sessionId, provider)`（`stores/session/utils.ts`，从 `generation.ts:189` re-export）解析出布尔值，再在 `tools-builder.ts:299` 判断 `webBrowsing && model.isSupportToolUse('web-browsing')` 决定要不要注册 web-search 工具（`webSearchTool`/`parseLinkTool`，来自 `@/packages/model-calls/toolsets/web-search`）。同样是"工具开关"模式，不是"胶水 prompt"模式。

### 7.4 三者收敛到同一条流水线

Agent 模式（`agent-mode.ts`）、知识库、网页浏览三个开关最终都汇入同一次调用——`orchestrateGeneration`（`orchestration.ts:577-600`）里的 `prepareAgentGenerationHarness`，内部统一走 `buildToolsForSession`。也就是说输入区这几个"上下文增强按钮"在架构上不是三套独立子系统，而是同一个工具注册管线里的三个布尔开关，每个开关各自受模型能力（`isSupportToolUse(scope)`）门控。这一点对理解代码结构很关键。

### 7.5 消息搜索：独立弹窗，按消息模型扫描并可定位

Chatbox 有一套独立于消息列表渲染的搜索 UI，并非只有 DOM 文本搜索：`pages/SearchDialog.tsx:50-65` 提供“当前会话”和“全部会话”两个入口；`stores/sessionHelpers.ts:871-875,880-929` 对当前消息和历史 Thread 的 `contentParts` 做文本匹配，全部会话按 IndexedDB 元数据分页（每页 30 个）读取完整 Session，最多返回 50 条命中消息。搜索结果项点击后会切换目标会话，并调用 `scrollActions.scrollToMessage`（`SearchDialog.tsx:168-203`）定位到具体消息。

这套实现没有持久化倒排索引，跨会话搜索仍是按页读取并逐条扫描；但它不会受到 Virtuoso 虚拟窗口的 DOM 挂载范围限制。消息匹配覆盖当前线程和历史 Thread，也会读取文本、reasoning、info、tool-call 状态及文件名（`shared/services/native-session-search.ts:8-25,55-75`）。

## 8. 发现的设计问题（汇总）

1. **"new" 临时状态分散在三种不同容器里**（本地 state / `newSessionState` 专用对象 / 通用 map 复用字符串 `'new'` 作 key），且 `newSessionState.webBrowsing` 字段疑似完全未被使用——见第 2.2 节。给后续新增"发送前可配置项"的开发者增加了选错容器、忘记迁移的风险。
2. **`throttleWriteSessionAtom.ts` 的 `createSessionAtom`/`WriteQueue` 疑似死代码**，与 `orchestration.ts` 里真正生效的 2 秒节流持久化机制并存且参数雷同（都是 2000ms），只是没人调用——见第 6.4 节。值得清理或至少加注释说明状态。
3. **恢复归档会话不会重置 `sortOrder`**，恢复后的会话出现在归档前的原始排序位置而非列表顶部——见第 4 节"恢复"。
4. **拖拽排序被限制在同一置顶分组内**（`areSessionsInSamePinGroup`），不能靠拖拽把未置顶会话直接拖进置顶区——第 3.2 节。
5. **Fork 清理逻辑（`cleanupEmptyForkBranches`）在 root 消息层和 thread 层分别写了一套相似但不完全相同的代码**（`chatStore.ts:786-872`），是潜在的双写不一致风险点。
6. **`localStorage.removeItem('new-chat')`**（`routes/index.tsx:336`）在本次阅读范围内找不到对应的写入点——未核实其用途，可能是遗留代码。
7. **批量归档故意不做性能优化**，代码注释直接承认"逐个走 `updateSession`，不针对超大批量归档做性能优化"（`chatStore.ts:500-501`）——这是一个被记录在案、而非被忽略的工程取舍。
8. **`MAX_TOOL_CALLS_BEFORE_CONFIRMATION = 25`**（`orchestration.ts:61`）：一次生成里，工具调用达到 25 次才会暂停要求用户确认，且暂停会冻结同一 step 里**整批**并行工具调用而不是单个——这条限制是在"普通 chat 模式"的 `orchestrateGeneration` 里实现的，但明显是 Agent 能力的一部分，说明 chat 与 agent 在实现上没有清晰边界，是本项目里"聊天"和"Agent"两个概念在代码层面交织最深的地方之一。
9. **IndexedDB session-meta 数据库有意不做 `version` 升级**（`SessionMetaStorage.ts:51-55` 注释），只允许加法式 schema 变更，理由是版本号升级会导致用户降级客户端版本后打不开数据库；注释提到的"捕获 VersionError 后重试"的兜底策略在本次阅读的代码里**没有看到实现**——未核实是否真的存在于别处。

## 9. 主要依据（文件+行号索引）

- `src/renderer/routes/index.tsx`（首页/临时会话/迁移逻辑）
- `src/renderer/routes/session/$sessionId.tsx`（真实会话路由页）
- `src/renderer/components/session/SessionList.tsx`（分页、拖放、分组渲染）
- `src/renderer/components/session/SessionItem.tsx`（置顶/归档/移动端长按菜单）
- `src/renderer/components/session/ThreadHistoryDrawer.tsx`
- `src/renderer/components/chat/MessageList.tsx`（thread 标签、fork 导航、smooth-follow 滚动）
- `src/renderer/components/chat/message-timeline.ts`
- `src/renderer/components/chat/Message.tsx`
- `src/renderer/components/InputBox/InputBox.tsx`（输入区、知识库/网页浏览/技能命令）
- `src/renderer/hooks/useKnowledgeBase.ts`
- `src/renderer/stores/chatStore.ts`（会话 CRUD、分页缓存、归档/删除、streaming cache 合并）
- `src/renderer/stores/chatStore-cache.ts`（`mergeCachedGeneratingMessages`）
- `src/renderer/stores/updateQueue.ts`
- `src/renderer/stores/uiStore.ts`（`newSessionState`、各 sessionId-keyed map）
- `src/renderer/stores/atoms/throttleWriteSessionAtom.ts`（疑似死代码）
- `src/renderer/stores/session/crud.ts`（`reorderSessions`、`copySession`）
- `src/renderer/stores/session/threads.ts`
- `src/renderer/stores/session/forks.ts`
- `src/renderer/stores/session/messages.ts`（`updateStreamingCache`/`persistStreamingMessage`）
- `src/renderer/stores/session/orchestration.ts`（流式生成主循环、节流、tool-call 暂停）
- `src/renderer/stores/session/agent-mode.ts`
- `src/renderer/stores/session/tools-builder.ts`（知识库/网页浏览/agent 工具统一注册）
- `src/renderer/stores/session/generation.ts`
- `src/renderer/stores/sessionHelpers.ts`（`getCurrentThreadHistoryHash`、`getAllMessageList`、`constructUserMessage`）
- `src/renderer/storage/SessionMetaStorage.ts`（IndexedDB 分页/索引/游标实现）
- `src/shared/session/message-forks.ts`（fork 纯变换函数）
- `src/shared/types.ts`（`Session`/`Message`/`SessionThread`/`MessageForkEntry` 等 schema）
- `src/shared/utils/session-sort.ts`（`sortSessionRecords`、`areSessionsInSamePinGroup`）
- `docs/new-session-mechanism.md`（与实际代码对照，发现其中"三步状态转移"描述过于简化，未提及三种容器并存及 `newSessionState.webBrowsing` 死字段问题）
- `docs/ui-inventory.md`（用于定位组件文件路径与文案，交叉验证 SummaryMessage/ForkMarkerMessage/CompactionStatus 等组件的存在）

## 10. UI 交互与呈现补充

### 10.1 会话页的布局与滚动策略

`routes/session/$sessionId.tsx` 的页面顺序固定为 `Header → MessageList → InputBox`，线程历史通过 `ThreadHistoryDrawer` 作为侧滑层挂载。进入会话后延迟调用 `scrollToBottom('auto')`；发送新消息前先把 `MessageList` 标记为新消息并瞬间滚到底部，生成期间由 smooth-follow 控制器跟随输出，用户手动向上滚动后会暂停跟随。`MessageList` 使用 `react-virtuoso`，并缓存每个 Session 的滚动快照（最多 100 个），切换会话不会把阅读位置丢掉。

### 10.2 消息卡片、分组与导航

`MessageList.tsx` 将最新一轮 user+assistant 合成一个渲染 item，其余消息逐条渲染；消息顶部可插入 ThreadLabel，Fork 在分叉点下显示 `ForkNav`，摘要和跨会话来源分别由 `SummaryMessage`、`ForkMarkerMessage` 专用组件呈现。桌面端还有 `MessageMinimapRail`、上一条/下一条用户消息导航和“回到底部”按钮，移动端会隐藏 minimap 以节省空间。`Message` 组件的编辑、复制、重试、删除、分支切换等动作通过 `sessionActions` 写回 store，而不是直接修改 DOM。

### 10.3 输入区与生成中交互

`InputBox.tsx` 将模型选择、Copilot、知识库、网页浏览、Agent 模式和工具入口收敛到 composer 工具栏；附件和知识库以消息 parts/会话句柄进入发送流水线（第 7 节）。`onSubmit` 先更新 UI 滚动状态，再调用 `submitNewUserMessage`；若当前存在 `generating` 消息，停止按钮调用其 `cancel()` 并把该消息以 `generating:false` 乐观写回。新建页的输入状态在首次发送时迁移到真实 Session，因此“首页输入框”和真实会话输入框呈现相同，但生命周期不同。

### 10.4 侧栏和响应式交互

`SessionList.tsx` 用 Virtuoso 分页加载，置顶/普通两组通过 `SessionMetaRecord.starred` 分开；拖拽由 dnd-kit 提供鼠标、触摸和键盘传感器。小屏幕默认禁用拖拽，用户需先进入“调整顺序”模式再长按移动，避免滚动手势误触。`SessionItem` 的右键/长按菜单承接置顶、改名、归档、恢复和删除；归档当前会话会先跳回首页。页面和输入组件均有 `isSmallScreen` 分支，保证窄屏下工具栏和线程抽屉不与消息区重叠。

### 10.5 呈现层边界

- 消息虚拟化只解决挂载/滚动，不改变 `getAllMessageList` 的线程、fork 展平结果；
- 消息内容搜索通过 `SearchDialog` 读取 Session 数据模型完成，结果可定位到具体消息；它不依赖 Virtuoso 当前挂载的 DOM，但跨会话仍是分页全量扫描而非持久化索引（第 7.5 节）；
- `ThreadHistoryDrawer`、Fork 导航和侧栏 Session 分组是三个互不隶属的 UI 入口，不能从视觉位置推断它们共享同一数据结构。

主要 UI 依据：`src/renderer/routes/session/$sessionId.tsx`、`components/chat/MessageList.tsx`、`components/chat/Message.tsx`、`components/InputBox/InputBox.tsx`、`components/session/SessionList.tsx`、`components/session/SessionItem.tsx`、`components/session/ThreadHistoryDrawer.tsx`、`docs/ui-inventory.md`。
## 12. UI 交互详查

### 12.1 消息操作

`Message.tsx` 的操作栏按角色显示：助手“再次回复/重试”，用户“在下方继续回复”；两者可编辑、复制、引用、删除、打开更多菜单。助手生成中可停止，图片会话可“在下方生成更多图片”，移动端助手可举报；可恢复工具错误会让用户选择重试整条消息或从最后工具步骤重试。开发环境的更多菜单可查看原始 JSON。

### 12.2 输入快捷操作

发送键可配置 Enter、Ctrl/Cmd+Enter、Ctrl+Enter、Command+Enter、Shift+Enter 或 Ctrl+Shift+Enter，另有“发送但不生成回复”。空输入（或全文选中）时 ArrowUp/Down 浏览输入历史；技能补全弹窗用 ArrowUp/Down 选择、Enter/Tab 确认、Escape 关闭。Escape 普通输入时阻止浏览器恢复 defaultValue 并让输入框失焦。

### 12.3 快速模型/Agent 配置

输入工具栏提供附件、网页搜索、推理级别、Agent Mode、知识库/技能、新建或回滚 Thread、会话设置、Token/上下文窗口和模型选择。`ModelSelectorV2` 可直接切换 provider/model；Agent Mode 可在 Chat/Agent 间切换，并按模型能力显示执行设备、工作目录、审批模式和 Git/Worktree 控件。生成时发送按钮变为停止。

## 13. UI 交互再深挖：弹窗、状态反馈与无障碍

> 本节聚焦第 10、12 节未覆盖的细节层面：弹窗底层实现、通知系统、拖放视觉反馈、右键菜单、主题机制、无障碍证据、响应式断点、动画库、图片灯箱、快捷键面板、桌面端集成。每条结论均标注文件+行号，查无实现的方向如实注明。

### 13.1 弹窗/对话框：三套并存的实现，靠 `AdaptiveModal` 统一收口

Chatbox 的弹窗底层实际上是**三套技术栈并存**，不是单一 UI 库：

1. **Mantine `Modal`/`Drawer`（主力）**：`components/layout/Overlay.tsx:42-43` 用 `withOverlayManager` 包了一层 `@mantine/core` 的 `Modal`/`Drawer`，导出为项目内统一的 `Modal`/`Drawer`。`useOverlayManager`（`Overlay.tsx:9-26`）维护一个全局 `overlayStackAtom`（jotai atom，字符串 id 数组），每个弹窗挂载时把自己的 `useId()` 塞进栈顶，**只有当前处于栈顶的弹窗才会把 `closeOnEscape` 设为 `true`**——这是自制的"多层弹窗只有最上层响应 Esc"方案，而不是依赖 Mantine 自带的层级管理。
2. **`vaul`（`AdaptiveModal.tsx:5,19-43`）**：移动端场景下同一个 `AdaptiveModal` 组件切换成 `vaul` 的 `Drawer.Root`，从底部弹出、带手柄（`Drawer.Handle`）、`noBodyStyles` 避免 vaul 改 body 样式。`ActionMenu.tsx`（右键/长按菜单，见 13.5）里的移动端分支也是同一套 `vaul` 用法。
3. **`@radix-ui/react-dialog`（`components/ui/dialog.tsx`）**：这是 shadcn/ui 风格的原始 Dialog 封装，独立于上面两套，`grep` 未发现在聊天相关组件里被直接引用——**未核实具体消费方**，本次阅读范围内只看到定义文件本身，可能给 dev 工具或未接入的功能预留。

真正对外统一的入口是 `AdaptiveModal`（`components/common/AdaptiveModal.tsx`），根据 `useIsSmallScreen()` 在"Mantine Modal"和"vaul Drawer"之间二选一渲染，业务弹窗（设置项、确认框、消息编辑等）基本都通过它，而不是直接用 Mantine `Modal`。

**弹窗生命周期管理用的是 `@ebay/nice-modal-react`**（`modals/ConfirmModal.tsx:1`、`modals/Settings.tsx` 未使用但 `routes/__root.tsx` 顶层包了 `<NiceModal.Provider>`）：`NiceModal.create(...)` 包装组件后，业务代码用 `await NiceModal.show('confirm', props)` 以 Promise 形式弹出并等待用户选择，`modal.resolve(result)` + `modal.hide()` 是标准收尾写法。目前至少 15 个弹窗走这套机制：`ConfirmModal`、`MessageEdit`、`SessionSettings`、`Welcome`、`ExportChat`、`VibedropPublish`、`ArtifactPreview`、`ReportContent`、`ThreadNameEdit`、`ModelEdit`、`ClearSessionList`、`AttachLink`、`FileParseError`、`AgentModeRewardClaimSuccess`、`AppStoreRating`（`modals/*.tsx` 目录清单）。

Esc/遮罩点击关闭的具体行为并不统一，是逐个弹窗手工配置的：
- 默认（不传 `trapFocus`/`closeOnEscape`/`closeOnClickOutside`）：Mantine 默认行为，Esc 和点遮罩都能关。
- **`trapFocus={false}`** 出现在 `MessageEdit.tsx:244`、`SessionSettings.tsx:171`、`CopilotDetailModal.tsx:118`、`CopilotSettingsModal.tsx:140`——`git log -S "trapFocus={false}"` 定位到提交 `2930c21d`（"fix: hard to select text on ios when opening a modal"），说明这是**专门为解决 iOS 上 Modal 内文本无法选中而关闭的焦点陷阱**，代价是这四个弹窗打开时键盘 Tab 可以跳出弹窗到背景内容，是一个明确记录在案、但确实存在的无障碍取舍。
- **`closeOnClickOutside={false}` + `closeOnEscape={false}` + `withCloseButton={false}`** 三个一起出现在 `EmailCodeLoginModal.tsx:74-76`、`LicenseSelectionModal.tsx:37-39`、`guide/-components/ActionButton.tsx:147-149`——登录/许可证选择这类"必须做出选择才能继续"的弹窗，故意禁掉一切"意外关闭"路径，只能点内部按钮走完流程。
- **`withCloseButton={false}`**（无右上角 X，但仍可 Esc/点遮罩关闭）单独出现在 `ArtifactPreview.tsx:104`、`Welcome.tsx:21`、`Settings.tsx:71`（Settings 弹窗把关闭按钮做成了自定义的圆形图标按钮而不是 Mantine 默认样式，`Settings.tsx:88-101`）。

**设置弹窗（`modals/Settings.tsx`）本身是一个嵌套路由**：内部用 `@tanstack/react-router` 的 `createMemoryHistory` + `createRouter` 单独起了一套 `modalRouter`（`Settings.tsx:256-264`），弹窗打开时把外层 URL 的 `?settings=/settings/xxx` search 参数同步进这个内存路由（`Settings.tsx:47-51`），意味着设置弹窗内部的"页面切换"不影响浏览器地址栏的真实路由栈，是路由套路由的实现方式。移动端不走这个弹窗，`navigateToSettings`（`Settings.tsx:115-131`）里判断 `matchMedia(max-width: 640px)` 命中时直接 `router.navigate({ to: '/settings...' })` 做整页路由跳转（对应 `routes/settings/route.tsx`），桌面端才叠加成弹窗——这是本项目"响应式"实现里比较少见的"同一功能在不同屏幕尺寸下走完全不同的路由策略"的例子。

### 13.2 通知/Toast：两套互不相干的系统按场景分工

**系统一：`toastActions` + MUI `Snackbar`（`components/common/Toasts.tsx`）**。这是聊天主流程用的那一套：`toastActions.add(content, duration?, action?)`（`stores/toastActions.ts:3-5`）往 `uiStore.toasts` 数组里追加一条记录，`Toasts.tsx` 对数组里的每一条都独立渲染一个 MUI `<Snackbar open anchorOrigin={{vertical:'top', horizontal:'right'}} autoHideDuration={toast.duration ?? 3000}>`（`Toasts.tsx:12-36`）。**没有找到任何堆叠/位移逻辑**——多条 toast 同时存在时，每条都定位在同一个右上角锚点，理论上会互相重叠而不是像 sonner 那样自动堆叠错开；本次阅读范围内没有看到针对这一点的额外样式处理。`toast.action` 可选，点击后按 `settingsPath` 跳转设置页（`Toasts.tsx:18-32`），用于像"已归档，去设置管理"（`SessionItem.tsx:103-105`，`duration: 8000`）这种带 CTA 的提示。全局挂载在 `routes/__root.tsx:355`（注释直接写了 `{/* mui */}` 提醒这是 MUI 的那一套）。消息复制、附件重试排队、发送出错、不支持的文件类型等场景（`Message.tsx:342,352`、`MessageAttachmentGrid.tsx:90,93`、`InputBox.tsx:892,1111,1136,1183,1188,1274`）都走这条路径。

**系统二：`sonner`（`packages/toast.ts` + 各 Settings 子页面）**。知识库文档上传、MCP 服务器管理、Skills 安装/更新等**只在 Settings 弹窗内部**触发的提示，直接用第三方库 `sonner` 的 `toast.success/error/warning/info(...)`（`KnowledgeBaseDocuments.tsx:313,315,415`、`CustomServersSection.tsx:79,135`、`SkillsSection.tsx:395,414,418`、`SkillsSpotlight.tsx:436`）。渲染载体是 `<Toaster richColors position="bottom-center" style={{zIndex: 2147483647}} />`，分别挂在 `modals/Settings.tsx:108`（桌面弹窗版）和 `routes/settings/route.tsx:140`（移动端整页路由版），**两处各自独立挂载**，不是共享单例。`sonner` 自身内置堆叠/自动错位能力，位置在屏幕底部居中，和系统一的右上角完全不同。`packages/toast.ts` 里的 `toastError` 还做了一层增强：错误 toast 先用原文展示，随后异步调用 `translateTexts` 把错误信息翻译成用户设置的语言，翻译完成后用同一个 `id` 把 toast 的 `description` 字段原地替换成译文（`toast.ts:12-40`）——即错误提示会"先出现原文，几百毫秒后追加译文"，而非等翻译完成才弹出。

结论：**是否弹右上角还是底部居中、用 MUI 还是 sonner，取决于触发代码所在的功能模块**，而不是一个统一的全局提示系统；两套 z-index 分别是"未特别设置"（跟随 MUI 默认）和硬编码的 `2147483647`（`int32` 最大值，确保永远盖在最上面）。

### 13.3 Loading / 骨架屏 / 空状态

- **消息生成中占位**：`Message.tsx:946-955` 在 `msg.generating && contentParts.length === 0` 时渲染一个自定义 `Loading` 组件（`components/icons/Loading.tsx`），是手写的纯 SVG 动画——四个圆点用 SVG `<animate>` 标签分别做 `cy`/`opacity`/`r` 三个属性的关键帧动画，`dur="1.25s"`，四个点依次 `begin` 延迟 `0s/0.2s/0.4s/0.6s`，形成"依次跳动"的等待指示器；不依赖任何 CSS 动画库或 Lottie。
- **工具调用等待中**：`MessageLoading.tsx` 提供 `MessageStatuses`/`PreparingToolCallStatus`（`Message.tsx:97` 引入），用于区分"纯文本生成中"和"准备/等待工具调用"两种状态展示（未展开细读该文件全部内容，仅确认了引入点和用途划分）。
- **图片生成 loading**：图片生成走独立的 `routes/image-creator` 子路由，`-components/Shimmer.tsx` 里的 `LoadingShimmer` 是一个 320×320 的圆角容器，内部叠一层 45° 斜向渐变条做 `shimmer-diagonal` 关键帧动画（3 秒一循环，纯 CSS `@keyframes` 内联在组件里），是与聊天消息完全不同的另一套 loading 视觉语言。
- **图片创作空状态**：`-components/EmptyState.tsx` 展示一个占位图标 + 标题文案 + 5 个可点击的"快速提示词"按钮（点击直接填充到输入框），是本项目里唯一发现的、带有可操作引导的空状态设计。
- **会话列表**：只有"翻页加载中"的转圈图标（`SessionListLoadingFooter`，第 3.1 节已记录），**没有找到"会话列表完全为空"时的专门空状态组件**——`grep` 未发现 `SessionList.tsx` 或其父组件里有对 `sessions.length === 0` 的特殊分支处理；新用户首次打开时列表为空，视觉上就是一片空白侧栏,没有引导文案或插图。这是一个可以指出的具体缺口。
- **网络请求失败**：走的是消息级的 `MessageErrTips.tsx`（第 12.1 节已提及重试逻辑），会根据 HTTP 状态码查一张 `httpStatusCodeI18nKeys` 映射表（`MessageErrTips.tsx:49-58`，覆盖 401/403/408/429/500/502/503/504）给出可读文案，还专门检测了错误内容是不是网关返回的原始 HTML 页面（`isHtmlContent`，`:40-43`）以避免把一整页 HTML 源码糊给用户看。

### 13.4 拖放细节：输入区拖文件进来"没有视觉反馈"

`InputBox.tsx:1268-1281` 用 `react-dropzone` 的 `useDropzone` 实现拖拽上传，`getRootProps()` 直接铺在整个输入区容器上（`InputBox.tsx:1340`）。**但只解构了 `getRootProps`/`getInputProps`，没有解构 `isDragActive`/`isDragAccept`/`isDragReject`**——`grep` 全文确认这三个状态字段在 `InputBox.tsx` 里完全没有被使用。也就是说，用户把文件拖到输入区上方悬停时，**没有任何高亮遮罩、虚线边框或文案提示**"松手可上传"，唯一的反馈是松手瞬间文件立刻被处理（成功则出现在附件预览区，被拒绝的文件类型才通过 `toastActions.add` 弹一条"不支持的文件类型"提示，`InputBox.tsx:1274`）。这是一个具体的、可复现的交互缺口：拖拽全程用户得不到"目标区域已识别"的即时反馈。

对比之下，第 10 节记录的会话列表拖拽排序（dnd-kit）有完整的视觉反馈体系（`DragOverlay`、把手图标、编辑模式提示条），输入区文件拖拽在这方面明显更简陋。

### 13.5 右键/上下文菜单：`SessionItem` 桌面端根本没有右键菜单

这是一个和直觉相反的发现：`SessionItem.tsx:181-186` 的 `handleContextMenu` 明确写着——

```ts
const handleContextMenu = (event: MouseEvent) => {
  if (!isSmallScreen) {
    return
  }
  event.preventDefault()
}
```

**桌面端（非小屏）完全不处理 `contextmenu` 事件**，只在小屏幕上 `preventDefault()` 阻止系统默认菜单弹出（防止手机长按弹出"分享图片"之类的原生菜单干扰长按手势）。桌面端唯一能触发的"更多操作"入口是 hover 时显现的两个小图标按钮（置顶、归档，`SessionItem.tsx:273-315`），**没有右键菜单**，改名/删除等操作要通过打开会话后进入 `SessionSettings` 弹窗完成（未在 `SessionItem.tsx` 里找到 rename/delete 相关代码）。

移动端（`isSmallScreen`）的"菜单"其实是**长按触发的 `ActionMenu`**（`SessionItem.tsx:319-335`，`type="contextual"`，`trigger="manual"`，配合 `handlePointerDown`/`handlePointerMove` 系列的自制长按计时器，`MOBILE_LONG_PRESS_DELAY = 550ms`、移动容差 `10px`，`SessionItem.tsx:25-26,166-179`），长按成功会触发一次原生震动反馈（`triggerLongPressHaptic`，桌面浏览器走 `navigator.vibrate?.(10)`，移动 App 走 Capacitor 的 `Haptics.impact({style: ImpactStyle.Light})`，`SessionItem.tsx:40-48`）。这个"菜单"底层是 Mantine `Popover`（`ActionMenu.tsx:112-197` 的 `ContextualActionMenu`），不是浏览器原生 `contextmenu` 事件驱动，也不是独立的第三方右键菜单库。

`ActionMenu.tsx` 本身按 `type` 分三种渲染策略：`desktop`（Mantine `Menu`）、`mobile`（`vaul` 底部抽屉）、`contextual`（Mantine `Popover`，贴着触发元素定位），由调用方显式指定或 `auto`（按屏幕尺寸自动二选一）。`Message.tsx` 全文 `grep` **没有找到 `onContextMenu`**——消息气泡没有右键菜单，所有消息操作（复制/编辑/重试/删除等，见 12.1 节）都是操作栏上的常驻/hover 按钮，不支持右键唤出。

### 13.6 主题/深色模式：MUI 主题、Mantine `colorScheme`、Tailwind CSS 变量三套机制各管一段

深色模式的"是否生效"由 `uiStore.realTheme`（`'light'|'dark'`）这一个状态源统一决定，但**消费方是三套互不相通的系统**：

1. **Tailwind / CSS 变量**：`useAppTheme.ts:41-49` 在 `realTheme` 变化时切换 `document.documentElement` 的 `dark` class，`tailwind.config.js:3` 声明 `darkMode: ['class']`，所有 `--chatbox-*` CSS 变量在 `static/globals.css:89` 的 `:root[data-mantine-color-scheme="dark"]` 选择器下重新赋值（浅色值在文件顶部 `:root{}`，深色值在这个选择器块）。**注意选择器用的属性是 `data-mantine-color-scheme`，不是 `data-theme`**——`data-theme` 属性同时也被设置（`useAppTheme.ts:43`），但只在 `static/index.css:40` 的 `html[data-theme="dark"]` 块里用来切滚动条颜色，和 `--chatbox-*` 变量的深浅色切换是两个不同的属性驱动的。
2. **MUI**：`getThemeDesign(realTheme, language)`（`useAppTheme.ts:56-101`）根据 `realTheme` 生成 `palette.mode` 和深色下的固定背景色 `#242424`（`:64-68`，注释写明"MUI 内部无法处理 css 变量，需要使用具体颜色值"——即 MUI 侧的深色背景是硬编码色值，没有走 CSS 变量，和 Tailwind 侧的 `--chatbox-background-primary`（同样是 `#242424`，`globals.css:114`）只是数值上凑巧一致，不是同一个来源）。
3. **Mantine**：`routes/__root.tsx:641-644` 的 `<MantineProvider defaultColorScheme={theme===Dark?'dark':theme===Light?'light':'auto'}>`——Mantine 自己的 `colorScheme` 机制是**独立**的第三套，只在初始化时读一次 `theme` 设置项，不响应 `uiStore.realTheme` 的后续变化（`defaultColorScheme` 只影响首次渲染默认值）；Mantine 组件的深浅色实际视觉表现，靠的是它们大量用 `c="chatbox-xxx"`/`color="chatbox-xxx"` 引用第 1 点里那套 CSS 变量，而不是 Mantine 自身的 dark/light 语义色。

**主题来源与存储**：`switchTheme(theme)`（`useAppTheme.ts:9-23`）在 `theme === Theme.System` 时调 `platform.shouldUseDarkColors()` 决定实际颜色；桌面端（`desktop_platform.ts:58-59`）转发给 Electron 主进程的 `nativeTheme.shouldUseDarkColors`（`main.ts:763`），网页端（`web_platform.ts:39-41`）直接查 `matchMedia('(prefers-color-scheme: dark)')`。**跟随系统变化的实时监听**：主进程 `nativeTheme.on('updated', ...)` 转发 IPC 事件 `system-theme-updated`（`main.ts:486-488`）,渲染进程 `onSystemThemeChange`（`desktop_platform.ts:61-63`）订阅后重新走一遍 `switchTheme`；网页端则是标准的 `matchMedia(...).addEventListener('change', ...)`（`web_platform.ts:42-47`）。最终算出的 `realTheme` 落盘在 `localStorage['initial-theme']`（`useAppTheme.ts:19`），供下次启动前（Mantine/React 渲染树建立前）就能同步读出避免主题闪烁（`uiStore.ts:26` 初始化时直接读这个 key）。

### 13.7 无障碍：核心发送/停止按钮没有 aria-label，`trapFocus={false}` 是已知的键盘陷阱缺口

- **发送/停止按钮完全没有 `aria-label`**：`InputBox.tsx:1404-1451` 的发送/停止 `ActionIcon`（`onClick={generating ? onStopGenerating : handleSubmit}`）只用图标区分状态（`IconPlayerStopFilled`/`IconArrowUp`），**没有 `aria-label`、没有 `Tooltip` 包裹、没有 `title` 属性**——屏幕阅读器用户点到这个按钮时得不到任何文字描述,这是本次调查里发现的最直接的无障碍缺口证据。
- **模型选择器有 `Tooltip`，但触发元素本身没有 `aria-label`**：`InputBox.tsx:1834-1867` 的 `ModelSelectorV2` 触发按钮（`UnstyledButton`）没有 `aria-label`，视觉上靠内部 `<Text>` 文案传达当前模型名，对屏幕阅读器不算严重问题（有文本内容可读），但下拉箭头图标 `IconChevronRight` 同样没有 `aria-hidden`。`ModelSelectorV2` 内部的行项组件（`ModelRow.tsx:69,101,109,115,132`）反而做得更完整：视觉能力图标（Vision/Reasoning）、收藏按钮都有 `aria-label`。
- **`trapFocus={false}` 的四个弹窗**（`MessageEdit`、`SessionSettings`、`CopilotDetailModal`、`CopilotSettingsModal`，见 13.1 节）打开时键盘 Tab 键可以聚焦到弹窗背后的页面元素——这是`git log`可查证的、有意为之的修复（`2930c21d`，为解决 iOS Safari 里 Modal 内文本框无法长按选中文字的问题），但客观上牺牲了这四个弹窗的键盘可达性边界,是一个真实存在、有代码证据、且项目方明知取舍的无障碍缺口，不是猜测。
- **做得相对完整的反例**：`MessageMinimapRail.tsx:250-263` 的消息跳转导航用真实的 `<button type="button">` 元素、`aria-label={jumpLabel}`（"Jump to message N"）、`focus-visible:ring-1` 可见焦点环，装饰性的圆点用 `aria-hidden="true"`（`:265`）正确隔离；`ModelRow.tsx`、`SessionItem.tsx:276,297`、`SessionList.tsx:264`（拖拽把手）、`ForkMarkerMessage.tsx:45` 等处的图标按钮也都补了 `aria-label`。也就是说项目里**存在无障碍意识**，但覆盖不均——发送/停止这个全应用最高频的交互点恰恰是缺失的。
- **Tab 顺序**：未系统性测试（需要实机/自动化工具验证，本次仅代码静态阅读），但从 DOM 结构看没有发现人为的 `tabIndex` 乱序设置；`trapFocus={false}` 造成的"跳出弹窗"是唯一从代码里能直接证实的 Tab 顺序问题。

### 13.8 响应式断点与移动端导航：断点数值来自 MUI 而非 Tailwind 默认值

统一断点定义在 `useAppTheme.ts:91-98`（MUI `breakpoints.values`）：`xs: 0, sm: 640, md: 900, lg: 1200, xl: 1536`，代码注释明确写"`sm` 的值与 tailwindcss 保持一致"（`:94`）——即项目**把 MUI 断点手动对齐到 Tailwind 的 `sm=640px`**，而不是用 Tailwind 默认的 `sm=640/md=768/lg=1024/xl=1280`（Tailwind 的 `md`/`lg`/`xl` 默认值和这里 `900/1200/1536` 并不一致，只对齐了 `sm` 一档）。`useIsSmallScreen()`（`hooks/useScreenChange.ts:14-18`）就是 `useMediaQuery(theme.breakpoints.down('sm'))`，即 **< 640px 判定为小屏**，这是全项目"移动端分支"的唯一判定标准。另有 `uiStore.ts:10-16` 的 `isSmallScreenViewport()` 用原始 `matchMedia('(max-width: 599.95px)')` 做初始化时的同步判断（用于 `showSidebar` 的初始值），**600px 和 640px 两个数字并不完全一致**——初始渲染判断用 599.95px，之后 React 状态更新走的 `useIsSmallScreen` 用 640px，理论上存在 600px~640px 这个区间首屏渲染和后续渲染判断不一致的窄缝，未核实是否有实际可观察的视觉跳变。

侧栏宽度（`useSidebarWidth`，`useScreenChange.ts:30-59`）按 `sm/md/lg/xl` 四档给出 `200/220/240/280`（`× mantineTheme.scale`）像素的默认值，小屏幕（都不满足 `up('sm')`）反而给了 `240`——但这个值在小屏幕下并不生效为"侧栏宽度",因为小屏幕走的是 `SwipeableDrawer` 的 `temporary` 变体（见下），宽度改成了 `75vw`（`Sidebar.tsx:154-156`）覆盖了 `useSidebarWidth` 的返回值。

**移动端导航方式：不是底部 Tab Bar，是从左侧滑出的 `SwipeableDrawer`**（`Sidebar.tsx:138-158`）。`variant={isSmallScreen ? 'temporary' : 'persistent'}`——小屏幕下侧栏是"临时"的覆盖层（打开时盖住内容，点遮罩或滑动关闭），桌面端是"常驻"的挤压布局（内容区 `padding-left` 让出侧栏宽度,见第 8 节 `routes/__root.tsx:312-321` 已经提到的实现）。`ModalProps.keepMounted: true` 保证移动端切换时 DOM 不销毁（`:145`，注释"Better open performance on mobile"),`disableEnforceFocus: true`（`:146`，注释解释是为了避免侧栏打开时其他弹窗里的 input 无法点击——这与 13.7 提到的 `trapFocus={false}` 是同一类"移动端焦点管理让步"）。`SwipeableDrawer` 支持从屏幕边缘滑动手势打开/关闭（MUI 内置能力），阿拉伯语（RTL）时锚点切到右侧（`anchor={language === 'ar' ? 'right' : 'left'}`,`:139`）。全项目 `grep` **没有找到底部 Tab Bar 组件**（`BottomNavigation`/`TabBar` 等关键词零匹配),移动端的一级导航（新建对话/图片创作/搜索/归档/关于/设置)全部收在这一个可滑出的侧栏抽屉里，不是常驻在屏幕底部的图标栏。

`useInputBoxHeight`（`useScreenChange.ts:61-76`）也按同一套 `sm/md/xl` 断点给输入框最小/最大高度（从 `{min:32,max:192}` 到 `{min:96,max:480}`），是笔记未提及的另一个响应式细节点。

### 13.9 动画/过渡效果：没有 Framer Motion，靠 Tailwind Animate + 库自带过渡拼起来

`package.json` 全文确认**没有安装 `framer-motion` 或 `motion`**。项目里能看到的动画来源分四类：

1. **`tailwindcss-animate`**（`tailwind.config.js:118` 插件、`package.json` 依赖）：提供 `animate-in`/`animate-out`/`fade-in`/`zoom-in`/`slide-in-from-*` 等 data-attribute 驱动的工具类，用在 `components/ui/dialog.tsx:20,37`（Radix Dialog 的开关动效，200ms `duration-200`）、`pages/PictureDialog.tsx:153`（图片灯箱淡入,`animate-in fade-in duration-300`）、`routes/image-creator/index.tsx`。
2. **Mantine 自带 `transitionProps`**：`InputBox.tsx:1755-1756,1841-1844,1936-1937` 给弹出面板（技能面板、模型选择器、更多菜单）分别配了 `transition: 'pop'` 或 `'fade-up'`，`ModelSelectorV2` 那处还显式设了 `duration: 200`（`:1843`）——这是 Mantine 内置的过渡预设名，不是自定义关键帧。
3. **`vaul`（Drawer）自带的弹簧式滑入动画**：`AdaptiveModal`/`ActionMenu` 的移动端分支（13.1、13.5 节）用 `vaul` 的 `Drawer.Root`,滑入/滑出动效由 `vaul` 库内部实现,项目代码里没有额外配置时长参数。
4. **手写 SVG/CSS 关键帧**：消息生成中的四点跳动指示器是纯 SVG `<animate>`（13.3 节,`1.25s` 周期）,图片生成的 shimmer 骨架屏是内联 `<style>` 里的 `@keyframes shimmer-diagonal`（13.3 节,3 秒周期）,`tailwind.config.js:102-114` 里另外声明了 `fadeIn`（1s ease-out）和 `flash`（0.5s ease-in-out ×2，用于强调闪烁）两个全局关键帧动画类。

`react-virtuoso` 的消息列表本身对"新消息进入"**没有额外包装过渡动效**——虚拟列表的挂载/卸载是即时的,第 10 节提到的"smooth-follow 滚动"是滚动位置的平滑跟随,不等同于消息卡片本身有 fade-in/slide-in 效果;本次没有找到消息卡片首次出现时的专门入场动画。

### 13.10 图片/附件预览：灯箱基于 `react-zoom-pan-pinch`，代码复制按钮有明确的图标+颜色反馈

**图片灯箱**（`pages/PictureDialog.tsx`）不是简单的全屏 `<img>`,而是接了第三方库 `react-zoom-pan-pinch`（`TransformWrapper`/`TransformComponent`,`:6,166-200`）,支持鼠标滚轮/触控手势缩放（`minScale=0.1, maxScale=8`）和拖动平移,`centerOnInit` 保证初次打开图片居中。关闭方式三种都支持:点击背景遮罩（`onClick={onClose}`,`:99`）、点击右上角 `Fab` 关闭按钮（MUI `Fab`,`:140-149`）、按 `Escape` 键（`:70-83` 手动监听 `keydown`,不是 Mantine/vaul 自带的 Esc 处理,因为这个弹窗是纯 `position:fixed` 的 div,不经过 `AdaptiveModal`）。右上角还可能出现业务方注入的 `extraButtons`（如"设为头像"之类的场景,`:28-31,116-128`）,和固定的"保存"按钮（导出图片到文件系统,`:48-67`）。

**代码块复制按钮**（`Markdown.tsx:532,600-611`）反馈很具体:点击后图标从 `IconCopy` 变为 `IconCheck`,颜色同时从 `chatbox-tertiary`（灰）变为 `chatbox-success`（绿）,`useCopied`（`hooks/useCopied.ts:4-20`）内部用 `setTimeout` 在 **2000ms** 后把 `copied` 状态重置回 `false`,图标/颜色随之变回初始状态;悬浮时有 `Tooltip label={t('copy')}`（`openDelay={1000}`,即悬停 1 秒后才显示提示文字,避免划过时闪一下)。同一个 `useCopied` hook 也被消息操作栏的复制按钮复用（`Message.tsx`,12.1 节已提及功能但未提及这个"2 秒变绿再变回"的具体反馈机制）。

### 13.11 快捷键面板/帮助：没有"按 `?` 弹出快捷键列表"这类浮层,只有一个静态设置页

全文 `grep` 快捷键相关的帮助浮层触发方式（`?` 键监听、`ShortcutsHelp`、`KeyboardShortcutsModal` 等命名）**均无匹配**。`useShortcut.tsx`（`hooks/useShortcut.tsx:65-133`）里的 `keyboardShortcut` 函数处理了一批硬编码的快捷键（聚焦输入框、切换网页浏览、新建会话、新建 Thread、新建图片会话、Ctrl+Tab 切换会话、Ctrl+数字跳转会话、Ctrl+K 打开搜索、Ctrl+, 打开设置）,**没有对应的"按 `?` 展示这份清单"的浮层**,唯一能看到快捷键说明的地方是设置页面里的静态列表 `routes/settings/hotkeys.tsx` → `components/Shortcut.tsx` 的 `ShortcutConfig`,用户需要主动打开设置才能看到/修改快捷键,不存在按需呼出的浮层式帮助。这与第 12.3 节提到的"输入区收敛了大量按钮入口"形成对比——功能入口做了收敛,但对应的"如何用键盘触发这些功能"这份说明没有做成随手可查的浮层。

### 13.12 桌面端集成（Electron）：托盘 + 全局快捷键唤起窗口,但没有系统原生通知联动聊天状态

- **全局快捷键**：`main.ts:259-274` 的 `registerShortcuts` 只注册了**一个**全局快捷键——`shortcutSetting.quickToggle`,绑定到 `showOrHideWindow()`（显示/隐藏主窗口）。**没有找到**"新建会话""发送最近一条消息"之类更细粒度的全局快捷键——桌面端全局能力仅限于唤起/隐藏整个窗口,不能在窗口隐藏状态下用快捷键直接触发聊天动作。
- **系统托盘**（`main.ts:280-324`）：`createTray()` 按平台选择不同图标（macOS 用 `iconTemplate.png` 模板图标以适配菜单栏深浅色、Windows 用 `.ico`）,右键菜单只有两项——"Show/Hide"（同 `showOrHideWindow`,并把 `quickToggle` 快捷键设为菜单项的 `accelerator` 提示文本）和"Exit",双击托盘图标也触发 `showOrHideWindow`。托盘图标本身**不显示未读消息数、生成状态等聊天相关的动态徽标**——`grep` 未发现 `tray.setImage`/`setTitle` 在生成过程中被调用,即托盘图标状态和聊天的生成/完成/出错状态没有联动。
- **系统级 Notification API 未接入**：全代码库 `grep "new Notification("` 无匹配,Electron 主进程也没有引入/调用 `Notification` 模块。即"某条消息生成完成""工具调用需要审批"等場景**不会弹出系统通知**,即使窗口被隐藏或最小化。相比之下,窗口重新显示/获得焦点时有一个小联动——`useShortcut.tsx:49-56` 监听 `platform.onWindowShow`/`onWindowFocused`,窗口显示或聚焦时自动 `dom.focusMessageInput()`（仅大屏幕),这是唯一的"桌面事件 → 聊天 UI 反应"联动,层级上只是"聚焦输入框",不涉及通知或状态展示。
- **窗口显示/隐藏事件双向打通**：`main.ts:501,515` 在窗口显示时发送 IPC `window-show` 给渲染进程,对应 `desktop_platform.ts:64-65` 的 `onWindowShow`,这条链路目前唯一的消费者就是上面提到的自动聚焦输入框逻辑。
- **系统主题联动**（已在 13.6 节详述）：`nativeTheme.on('updated', ...)` → IPC `system-theme-updated` → 渲染进程重新计算 `realTheme`,这是目前发现的桌面端"系统事件驱动 UI 变化"里实现最完整的一条链路,但它驱动的是主题而非聊天状态本身。

### 13.13 一处顺带发现的死状态：`uiStore.openAboutDialog`

`uiStore.ts:34,89-90` 定义了 `openAboutDialog: boolean` 和 `setOpenAboutDialog`,`routes/__root.tsx:144,201` 在启动流程里会把它设为 `true`（当远程配置 `setting_chatboxai_first` 命中时）。但全代码库 `grep` **没有找到任何组件读取 `openAboutDialog` 状态来渲染"关于"弹窗**——"关于"功能实际上是通过 `navigate({ to: '/about' })` 做成了一个独立路由页（`Sidebar.tsx:184,434,462`）,不是弹窗。也就是说 `setOpenAboutDialog(true)` 这次调用在当前代码里是**没有任何 UI 效果的空调用**,和第 2.2 节记录的 `newSessionState.webBrowsing` 死字段属于同一类"重构后遗留、写了但没人读"的技术债,可以在第 8 节"发现的设计问题"里追加一条同类记录。

主要 UI 依据（第 13 节新增，与第 9 节索引互补）：`src/renderer/components/layout/Overlay.tsx`、`src/renderer/components/common/AdaptiveModal.tsx`、`src/renderer/components/common/Toasts.tsx`、`src/renderer/stores/toastActions.ts`、`src/renderer/packages/toast.ts`、`src/renderer/modals/Settings.tsx`、`src/renderer/modals/*.tsx`（弹窗清单）、`src/renderer/components/ActionMenu.tsx`、`src/renderer/components/session/SessionItem.tsx`、`src/renderer/hooks/useAppTheme.ts`、`src/renderer/hooks/useScreenChange.ts`、`src/renderer/Sidebar.tsx`、`src/renderer/sidebar-drawer.ts`、`src/renderer/hooks/useShortcut.tsx`、`src/renderer/pages/PictureDialog.tsx`、`src/renderer/components/Markdown.tsx`、`src/renderer/hooks/useCopied.ts`、`src/renderer/components/icons/Loading.tsx`、`src/renderer/routes/image-creator/-components/Shimmer.tsx`、`src/renderer/routes/image-creator/-components/EmptyState.tsx`、`src/renderer/components/chat/MessageMinimapRail.tsx`、`src/renderer/components/InputBox/InputBox.tsx`、`src/main/main.ts`、`src/renderer/platform/desktop_platform.ts`、`src/renderer/platform/web_platform.ts`、`src/renderer/static/globals.css`、`src/renderer/static/index.css`、`tailwind.config.js`、`package.json`。
