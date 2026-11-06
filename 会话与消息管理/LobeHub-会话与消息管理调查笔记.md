# LobeHub 会话与消息管理调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：直接阅读源码（SPA 页面路由与 Conversation 组件、全局 ChatStore 与会话级 ConversationStore、conversation-flow 算法包、tRPC 服务端路由与数据库模型）+ grep 检索调用点，关键结论以当前源码接线为依据；未运行应用
>
> 调查范围：会话定位与消息分桶 key、双层 Store 事实源与同步、消息数据形状与树、Topic 生命周期 CRUD 与分页、消息 CRUD 与分支数据语义、Topic 与消息检索、导入导出与树修复；数据库 schema 迁移脚本、多端并发写入合并未覆盖
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的会话由多维坐标 `ConversationContext` 压平出的 `messageMapKey` 分桶定位，与 agentId 加 topicId 的二元定位属于不同粒度：

- 每个会话桶（`messageMapKey`）的消息由全局 ChatStore 的 transcript 层独占写入：原始行与解析后的展示列表都只在该层落盘，并经 `@/libs/replica` 做本地持久化副本；会话级 ConversationStore 是它的**单向镜像**，通过 `internal_syncChatTranscript()` 读取同一桶，写入则先转发回 chat store。
- 镜像有两种来源：默认订阅 chat store 的桶引用变化（`StoreUpdater` 的 `useChatStore.subscribe`）；传入静态 `messages` 时（画廊、分享快照）本地 store 自行持有，标记 `transcriptSource='static'`，既不订阅也不回写。
- 本地消息分桶 key 比服务端消息列表缓存 key 更细（多 `documentId`/`subAgentId` 等维度），缓存身份由 `services/message/cache` 的 `getMessageListCacheIdentity` 计算，副本 key 由 `services/message/replica` 定义，两者不同构时以副本 key 为准。
- 消息是带 `parentId/threadId/groupId` 的扁平数组，渲染前重建为树；分支激活指针存在**父消息**的 `metadata.activeBranchIndex` 里，解析在 `BranchResolver`，UI 只负责改一个整数。
- 工具调用与结果是独立的持久化消息行；删除“组”消息时要连带收集工具结果行的 id 一起删。
- Topic 全生命周期（创建/切换/删除/收藏/完成/导入/复制）在 `topic/action.ts` 中实现，列表按页拉取（默认每页 20）；Topic 搜索走服务端 BM25（标题+消息内容），`message.searchMessages` 端点本次未找到聊天 UI 调用。
- 树修复是“诊断只读、修复显式”：`doctor/diagnoseTopic` 跑真实 `parse()` 产出补丁，修复走 `TopicDoctorModal` 人工触发的服务端 `repairTopic`，没有自动应用写路径。

## 系统边界与数据主链

```text
路由参数 + useDocumentStore -> useAgentContext 拼出 ConversationContext
  -> messageMapKey 归一化分桶（main/thread/group/group_agent/page 等 scope）
  -> 全局 ChatStore 的 transcript 副本：dbMessagesMap（原始）/ messagesMap（parse 后展示）/ messagePagingMap（页游标）
      独占写入 + 本地持久化（@/libs/replica）
  -> ConversationProvider 建会话级 ConversationStore（dbMessages/displayMessages，store 实例跨 topic 存活），单向镜像该副本
  -> 编辑/删除/分支/审批经 messageService/topicService 与服务端交互
  -> 服务端列表缓存身份与副本桶 key 不同构（getMessageListCacheIdentity 与 conversationMessagesKey 各算各的）
```

边界：消息数据如何变成 `displayMessages`/`flatList` 的三阶段解析算法、虚拟列表窗口化与滚动属于消息渲染器（已有独立笔记 [`../消息渲染器/LobeHub-消息渲染调查笔记.md`](../消息渲染器/LobeHub-消息渲染调查笔记.md)）；发送任务如何读取这些数据、审批如何恢复任务属于对话请求与上下文（[`../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md`](../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md)）；界面上的会话导航与操作工作流属于 Chat UI。

## 1. 会话、消息与分支数据模型

### 1.1 会话定位：ConversationContext 与 messageMapKey

聊天页面由一套多维坐标 `ConversationContext` 定位（定义于 `packages/types/src/conversation.ts:121-`），`agentId` 与 `topicId` 只是其中两个维度，完整字段包括：

- 会话定位：`agentId`、`topicId`、`threadId`、`groupId?`、`scope?`；
- 子 Agent/文档维度：`subAgentId?`、`documentId?`、`agentDocumentId?`、`isolatedTopic?`、`isSubAgent?`；
- 其他：`workspaceSlug?`、`editingGroupId?`。

坐标由 `useAgentContext`（`src/features/Conversation/useAgentContext.ts:16-44`）从路由坐标（`useAgentConversationCoordinate`）+ `useDocumentStore` 的 topic-document 关系拼出；`documentId` 只有在活动 document 属于 notebook 且绑定当前 topic 时才带上。

真正把这坐标“压平”成一个 map key 的是 `messageMapKey`（`src/store/chat/utils/messageMapKey.ts`）：

- `toMessageMapContext`（第 50-117 行）按优先级把输入归一化成 `{scope, scopeId, topicId, subTopicId, isNew}`：
  - `scope==='page' && documentId` → `page_<agentId>_<documentId>`（第 58-66 行），注释明确指出如果不带 documentId，两个不同文档会被塞进同一个 `page_<agent>_new` 桶，“leak history / queue behind each other's operations”；
  - `threadId && scope==='thread'` → thread 优先（第 71-78 行，Group Chat 场景下任务会用 SubAgent 的 agentId 建 thread，这里显式说明“优先级”是为了避免和 groupId 混淆）；
  - `groupId` 存在时区分 `group_agent`（子 Agent 在群里的独立消息流，用 `subAgentId` 当 subTopicId）与默认 `group`（第 81-96 行）；
  - 有 `threadId` 但未显式指定 scope 时自动推断为 `thread`（第 99-106 行）；
  - 否则落到 `main`（`sub_agent` scope 会被强制映射回 `main`，第 111-116 行的注释：“same conversation, just different display”）。
- `generateKey`（第 122-146 行）按 `${scope}_${scopeId}[_{topicId}][_{subTopicId}][_new]` 拼字符串；page 无 topic 时避免拼出字面量 `null` 段（第 127-132 行）。
- 入口 `messageMapKey`（第 177-180 行）。

这套 key 同时被 chat store 的 transcript 副本与会话级镜像使用（见第 2 节），是它们定位到"同一份数据"的唯一纽带。副本读写不再经过早期的写穿缓存函数：`src/services/message/replica` 用 `conversationMessagesKey`/`toPersistedTranscript` 定义持久化形状，`src/services/message/cache` 用 `getMessageListCacheIdentity` 计算服务端列表缓存身份——后者只认 agentId/groupId/threadId/topicId 等坐标，不认 `documentId`/`subAgentId` 这类本地专属维度，因此副本按自己的 key 存，服务端缓存按更粗的 key 取，两者天然不完全对齐。

流式期间 chat store 的同步会丢弃不改变内容的头部响应，`settle` 只在 run 结束时把转写定稿落盘；也就是说，逐 token 的中间态只存在内存里，不逐次写副本。这一点与本地分桶 key 更细的事实叠加，构成本地展示与服务端快照之间持续存在的一致性耦合点。

### 1.2 消息数据形状与树

消息是扁平数组（`UIChatMessage`，字段含 `id/parentId/threadId/groupId/role/tools/agentId/...`），渲染前经 `conversation-flow.parse()` 重建为树（`packages/conversation-flow/src/parse.ts:23-51`：预处理 sub_agent 消息的 agentId 覆盖 → 索引 → 建树 → 变换 → flatList）。树的构建与虚拟消息生成算法本身属于消息渲染器笔记，本笔记只记录数据形状与数据修复事实：

- `buildHelperMaps`（`indexing.ts:42-119`）产出四类辅助映射：`messageMap`（id→message）、`childrenMap`（parentId→子 id 列表）、`threadMap`（threadId→消息列表）、`messageGroupMap`（compare/manual 分组元数据）；
- `buildIdTree`（`structuring.ts:11-38`）**过滤掉带 `threadId` 的消息**——thread 是独立话题线，不进主干树。
- **压缩组重定向**（`indexing.ts:52-66` 建立 `lastMessageId→compressedGroup.id` 映射，76-79 行重定向 parentId）：如果压缩组消息的 `lastMessageId`（压缩前链条的最后一条）被其它消息当作 `parentId` 引用，会把该 parentId 重定向指向压缩组本身，否则压缩后新产生的消息会挂到一个已经被隐藏的消息下面，从树上"消失"。
- **孤儿兜底**（`indexing.ts:80-86`）：如果 `parentId` 指向的消息不在当前查询到的消息集合里（分页/局部查询漏掉祖先），直接把该消息降级为根节点，注释原文 "so post-compression follow-up chains remain visible instead of being dropped entirely"。
- **dual-form 历史数据形态**（`transformation/MessageCollector.ts`）：assistant 与工具消息的链接关系存在两种历史形态——
  - assistant-anchored（新形态）：下一步 assistant 是当前 assistant 的非工具子节点，兄弟于 tool 结果；
  - tool-anchored（旧形态）：下一步 assistant 挂在某个 tool 结果消息下面。
  - `findFlatChainContinuation`（256-289 行）同时从两个位置收集候选，另有 fan-out 守卫（AgentCouncil/异步任务子节点时链路终止，264-276 行）与分支解析（284 行 `resolveActiveContinuationId`）。
- **分支数据语义**：分支指示器画在**子消息**上，但激活索引存在**父消息**的 `metadata.activeBranchIndex` 里；`BranchResolver`（`transformation/BranchResolver.ts:12-159`）的两个入口 `getActiveBranchId`（IdNode 版本，28-69 行，供 contextTree）和 `getActiveBranchIdFromMetadata`（child-id 数组版本，77-114 行，供 flatList）逻辑一致，优先级为：
  1. 读 `metadata.activeBranchIndex`（越界等于子节点数代表"乐观更新中，分支还没创建"，返回 `undefined`）；
  2. 找"包含最新持久化 user 后代"的分支（43-58 行，`findBranchContainingLatestUser` 124-158 行，防止重试分支把当前用户轮次挤出历史）；
  3. 退化为"选第一个有子节点的分支"；
  4. 兜底选第一个。
  - 工具结果行不算可选分支兄弟（20-22 行）。

### 1.3 外部对象绑定粒度（可确认部分）

- 附件/文件引用在**消息 metadata 层**绑定：发送时写入 user message 的 metadata（`conversationLifecycle/index.ts` 的 fileIdList、contextSelections、pageSelections、localSystemToolSnapshots），编辑器数据（editorData）在同一文件里提取为 skills/tools/mentions/文件引用（解析函数集中在 `parseLocalFileReferencesFromEditorData` 等一组 helper；注入执行语义见对话请求与上下文笔记）。`conversationLifecycle` 已从单文件改为目录：`index.ts`（主链，约 2,182 行）+ `compression.ts` + `runCwd.ts` + `sendErrorNotice.ts`。
- 工具调用与结果是**独立的持久化消息行**：
  - 删除"组"消息（`assistantGroup`/`supervisor`）时要连 `children[]` 里每个 block 的 id、以及每个 block 里 `tools[].result.id`（工具结果消息）一起收集进删除列表（`crud.ts:307-320`），说明这些是底层 db 行而非渲染期对象；
  - `deleteAssistantMessage`（261-278 行）则按 `tool_call_id` 反查并连带删除。
- 模型/渠道在**会话（topic）级**保存快照：发送创建新 topic 时由 `src/store/chat/utils/snapshotAgentModel.ts` 的 `snapshotAgentModel`/`snapshotAgentReasoning` 写入 `topics.model`/`provider` 列，切换 topic 模型走 `updateTopicModel`（`src/store/chat/slices/topic/action.ts:640`）。

## 2. 事实源、副本与镜像

**每个会话桶的消息只由全局 ChatStore 的 transcript 层写一次，其余表面都是它的读取方或镜像。** transcript 层注释直接声明自己是 `dbMessagesMap` / `messagesMap` 的唯一写入者（`src/store/chat/slices/message/transcript/index.ts`）。

### 2.1 副本层：chat store 的 transcript

`src/store/chat/slices/message/initialState.ts` 定义三类状态：

```ts
dbMessagesMap: Record<string, UIChatMessage[]>;   // 原始消息，按桶存
messagesMap: Record<string, UIChatMessage[]>;     // parse() 之后的展示消息
messagePagingMap: Record<string, TranscriptPaging>; // 每桶的页游标与加载深度
```

解析后的列表不是各自写入的：`transcript/lens.ts` 的 `createTranscriptLens()` 在同一 commit 内从条目行派生 `messagesMap[bucket]`（`parse(items, ...)`），并用 WeakMap 缓存「同一 rows + paging 返回同一 view」，所以重复读取不会产生新树。分组元数据、压缩组重定向等仍在 `conversation-flow.parse()` 里完成，本笔记不重复。

写入这个副本的路径有四类：

- 头部同步与翻页：`actions/transcript.ts` 的 `MessageTranscriptActionImpl` 在挂载时同步头部页，旧页经 `loadEarlierMessages`/`loadLaterMessages` 走 round-cursor 翻页；
- 本地持久化：副本经 `@/libs/replica` 的 `createReplicaSlice` 落 IndexedDB，刷新后先画已落盘转写，再由网络头部校正；
- 定稿：`internal_settleTranscript` 在 agent run 结束时持久化转写（包括已无视图显示的会话），流式中间态只留内存；
- 修补式替换：`query.ts` 的 `replaceMessages` 仍负责 preserveWorks（中期 refetch 保留 Work 芯片）、语音占位合并与 `reconcileAssistantToolLinks`，但最终写的是副本层条目。

主聊天页向会话 Provider 传入上下文、操作状态与行为 hooks，**省略 `messages` prop**，由 Provider 内的镜像层订阅全局消息桶。显式传消息数组会被解释为静态转录并关闭同步，不能用这条路径解释实时聊天。见 [ConversationArea 的 Provider 接线](../../lobehub/src/routes/%28main%29/agent/features/Conversation/ConversationArea.tsx#L142-L148)、[StoreUpdater 来源判断与订阅](../../lobehub/src/features/Conversation/StoreUpdater.tsx#L83-L109)。

### 2.2 会话级 ConversationStore：单向镜像

Provider 实例跨 topic 存活，切换时不重建 store：`StoreUpdater` 的 `useLayoutEffect` 在 paint 前用 `createEphemeralResetState` 原地重置 UI-only 状态（activeIndex/atBottom/inputMessage/messageEditingIds/pendingArgsUpdates/selectedMessageIds 等），刻意保留 `editor`/`chatInputOverlayHeight`/`virtuaScrollMethods` 等仍在挂载的字段，并把 `messagesInit` 置为当前是否为静态转录。

数据来源只有一处：默认 `transcriptSource='chat'`，`StoreUpdater` 订阅 chat store 的桶引用变化（`dbMessagesMap[bucket]` 或 `messagesMap[bucket]` 变化）后调用 `internal_syncChatTranscript()`；镜像读取由 `chatTranscriptState()` 完成——行来自 `dbMessagesMap`，解析结果优先复用 `messagesMap[bucket]`，再用 `stabilizeReferences` 固定引用。

传入 `messages` 时进入静态转录模式（`transcriptSource='static'`）：本地直接持有该数组，`replaceMessages(messages)` 跟随 prop，既不订阅 chat store 也不回写，用于画廊与分享快照。`createStoreAction` 在创建时若拿到初始消息会先 parse 一次，避免挂载首帧空白。

局部写方法的行为随来源分叉：chat 模式下 `internal_dispatchMessage`/`replaceMessages` 先把写入转发给 `useChatStore` 再同步回来；静态模式下直接走本地 `messagesReducer` 与 `setStaticMessages`。

### 2.3 同步方向与引用稳定性

两层之间只剩一个方向：chat store 副本 → 会话级镜像。镜像在挂载的会话上订阅桶引用变化并重读；写入一律先落副本，再回读，不存在局部 store 写完后回调全局的第二条路径。

引用稳定性由两处手工补丁保证：镜像读取的 `chatTranscriptState()` 与静态模式的 `setStaticMessages` 都用 `stabilizeReferences`（`@tanstack/react-query` 的 `replaceEqualDeep`）把未变子树钉回上一帧引用；此外 `transcript/lens.ts` 用 WeakMap 按「同一 rows + paging」缓存派生 view，使重复读取返回同一对象。parse 本身不保证稳定引用，稳定性仍靠这两层补丁。

一致性事实：未挂载的会话没有镜像，但副本仍在 agent run 结束时由 `internal_settleTranscript` 定稿落盘；镜像只在挂载期间跟随，所以「看到的数据」与「已落盘的数据」在流式期间可以短暂不同，刷新或重挂载后以副本为准。

### 2.4 为什么要分两层（能看出的设计动机）

- 全局状态（`operations`/`operationsByContext`/`operationsByMessage`、`dbMessagesMap`）刻意保持全局，是为了让“多个 Agent/Topic 同时跑生成任务”这件事可行——`ConversationProvider.tsx:86-91` 的文档注释直接写：“Operations are kept global to support multiple agents/topics running in parallel.”
- 局部状态（generation/editing/selection/scroll/virtua 相关、pendingArgsUpdates）放进按 `contextKey` 隔离的 store，切 topic 时由 `StoreUpdater` 的 `createEphemeralResetState` 一次性丢弃重置（见 2.2），不用手写逐项清理逻辑。（这些 UI-only 状态如何被界面消费属于 Chat UI 笔记。）

## 3. 创建、切换、归档、删除与恢复（Topic 生命周期）

Topic 生命周期在 `src/store/chat/slices/topic/action.ts`（ChatTopicActionImpl，约 1,775 行）；服务端的复制与导入已下沉到 `packages/database/src/repositories/topic/`（`duplicate.ts`、`topicImporter/`），路由按职责拆到 `apps/server/src/routers/lambda/topic/`（`create.ts`、`queries.ts`、`remove.ts`、`share.ts`、`transcript.ts` 等）：

- **创建（惰性）**：聊天页面本身不预建 Topic；Topic 在两类时机被创建——
  - 用户主动"新话题"：`createTopic`（345 行）或 `saveToTopic`（366 行，把当前展示消息绑定进新 topic 并 fire-and-forget 自动摘要标题 `summaryTopicTitle`）；
  - 首次发送时由发送链创建（`conversationLifecycle/index.ts` 客户端铸造 topic id，`internal_dispatchTopic` 先插乐观侧栏行，见对话请求与上下文笔记）。
  - 两者最终都走 `internal_createTopic`（1826 行：先 `Date.now()` 临时 id 乐观插入，再 `topicService.createTopic` 落库并 `refreshTopic`）；乐观行由 `creatingTopicIds` 追踪。
- **切换**：`switchTopic`（1475 行）清 `_new` 桶、置 `activeTopicId`、`markTopicRead`，然后用微任务 + `#switchTopicEpoch` 防连点竞态后 `revalidateMessages`；深链/预取场景走 `revalidateMessages` 的 "server verified" 软保证（`query.ts:46`，分桶 refetch 与 in-flight 预取共享）。
- **重命名/收藏/完成**：一组并列操作，各自对应一个方法——
  - `updateTopicTitle`（395 行）；
  - `favoriteTopic`（346 行）；
  - `markTopicCompleted`/`unmarkTopicCompleted`（332-345 行，写 `completedAt`）；
  - `updateTopicMetadata`（379 行）、`autoRenameTopicTitle`（795 行）。
- **删除**：分单删与批量删两类——
  - 单删：`removeTopic`（1340-1354 行，可带 `removeFiles` 删附件，删后 `evictMessageCache` 逐出该 topic 消息缓存并回默认话题）；
  - 批量：`removeSessionTopics`/`removeGroupTopics`/`removeAllTopics`（1303-1338 行，删除后统一 `evictMessageCache` 并 `switchTopic(null)` 回默认话题）；
  - 其他：`removeUnstarredTopic`（1356-1372 行）；`cleanupStaleRunningTopics`（635 行）负责清理陈旧运行标记。
- **复制/导入**：`duplicateTopic`（394 行）、`importTopic`（445 行）在 store 侧只做状态更新与跳转，实际数据语义在服务端 repository（消息树深拷贝、附件引用）中，本次未下钻其 SQL。
- **归档**：本次未找到"归档（archive）"概念——与完成/删除/收藏是并列状态字段（`completedAt`/`favorite`/`status`）不同，本快照的 topic 数据模型中没有 archive 标志位（检查范围：`topic/action.ts` 全部方法列表与 topic 类型定义未出现 archive 字段）。
- **列表分页**：分桶存储 + 追加式翻页——
  - 分桶：`useFetchTopics`（803 行）与 `useFetchAgentTopicsView`（962 行）存 `topicDataMap`/`agentTopicsViewMap`；
  - 翻页：`loadMoreTopics`（1134 行起，pageSize 取 `globalStore.status.topicPageSize || 20`，1156-1171 行并把 `excludeTriggers`/`excludeStatuses` 带到后续页）与 `loadMoreAgentTopicsView`（1055-1123 行）追加式翻页；
  - 服务端 `getMessages` 同样接受 `current/pageSize` 分页（`apps/server/src/routers/lambda/message.ts:347-359`）。

## 4. 消息 CRUD 与数据变更语义

`src/features/Conversation/store/slices/message/action/crud.ts`：

- `createMessage`（`crud.ts:207` 起）的流程：
  1. `createTempMessage`（`tmp_<nanoid>` 乐观插入，`internal_dispatchMessage` type `createMessage`）先落临时消息；
  2. 再调 `messageService.createMessage`，成功后用服务端返回的 `result.messages` 整批 `replaceMessages` 覆盖（失败则把临时消息标错误）。
  - id 一致性：`packages/utils/src/entityId.ts` 提供客户端 id 铸造（`generateEntityId`，与服务端同字母表同前缀），发送链与 `execAgent` 服务端按客户端 id 落库，乐观消息 id 与最终落库 id 的一致性由客户端预生成保证（`conversationLifecycle/index.ts` 注释）。
- `deleteMessage`（298-336 行）：
  - 目标为 `assistantGroup`/`supervisor` 时，要把 `children[]` 里每个 block 的 id、以及每个 block 里 `tools[].result.id`（工具结果消息）都一并收集进删除列表（307-320 行），保证删掉一个"组"时连带清理所有底层 db 行；
  - 单条删走 `messageService.removeMessage`（父子链重接），批量删走 `removeMessages`；
  - 其他变体：`deleteDBMessage`（281-296 行）、`deleteMessages`（338-350 行）、`deleteToolMessage`（352-376 行，连父 assistant 的 `tools[]` 条目一起删）、`removeToolFromMessage`（378-401 行）。
- `updatePluginArguments`（542-637 行）：更新工具参数时同时乐观更新"工具消息本身"和"父 assistant 消息 tools[] 里的那一条"（586-602 行），并把这次更新的 Promise 记录进 `pendingArgsUpdates`（613-619 行，以 toolCallId 为 key），供 `waitForPendingArgsUpdate`（639-644 行）在审批/拒绝前等待——保证任何正在进行的参数编辑必须先落地，避免竞态。

### 4.1 编辑 / 多选状态（纯局部 UI 状态）

`src/features/Conversation/store/slices/messageState/action.ts` 提供编辑与多选两类纯局部 UI 状态操作：

- 编辑：`toggleMessageEditing`（123-129 行）；
- 多选：`enterSelectionMode`/`selectRange`/`selectToHere`/`toggleMessageSelected`（59-141 行，支持类似微信的 shift 范围选择和"选择到这里"）。

这些操作只改 `selectedMessageIds`/`selectionAnchorId`/`selectionMode` 三个字段，不落库、不经过全局 store；如何呈现在界面上属于 Chat UI 笔记。

### 4.2 分支切换的数据语义

局部 `switchMessageBranch`（`store/slices/data/action.ts:232-243`）只做两件事：把目标消息的 `parentId` 找出来，调用 `updateMessageMetadata(parentId, { activeBranchIndex })`。分支指示器画在**子消息**上，但激活索引存在**父消息**的 metadata 里，"哪个分支是激活的"判断逻辑在 `BranchResolver`（第 1.2 节）里做，UI 只负责改一个整数。全局 ChatStore 也有一份几乎相同实现：`conversationControl.ts:313-323` 的 `switchMessageBranch` 走 `optimisticUpdateMessageMetadata`。

### 4.3 工具审批的数据层事实（薄转发层）

`src/features/Conversation/store/slices/tool/action.ts` 的 `ToolActionImpl`（18-208 行）里**每一个**方法都是薄转发：

- 单个方法：`approveToolCall`/`rejectToolCall`/`rejectAndContinueToolCall`/`skipToolInteraction`/`submitToolInteraction`/`cancelToolInteraction`/`submitHeteroIntervention`；
- 批量方法：`approveAllToolCalls`/`stopPendingApproval`/`stopPendingApprovalForCard`。

它们共同的固定三步：等待 `waitForPendingArgsUpdate` → 触发本地 `hooks.onToolApproved`/`onToolRejected` → **调用 `useChatStore.getState()` 上的同名方法**，把局部 `context` 传过去（例：`approveToolCall` 27-47 行）。业务逻辑（Gateway/本地 client runtime 二分、乐观更新顺序、IPC/tRPC 转发异构 Agent 干预）全部在**全局** ChatStore 的 `conversationControl.ts`，属于对话请求与上下文笔记第 7 节。

## 5. 列表、索引与检索

- **Topic 搜索（服务端 BM25）**：`apps/server/src/routers/lambda/topic/queries.ts:366` 的 `searchTopics` 调用 `TopicModel.queryByKeyword`（`packages/database/src/models/topic/find.ts:215`），机制分三步：
  - `sanitizeBm25Query` 清洗查询词；
  - **并行**跑"标题 `@@@` 匹配"与"消息内容匹配反查 topicId"；
  - 去重合并后按 `updatedAt` 排序返回 Topic 列表。
  - 因此用户可以通过 Topic 搜索找到包含关键词的会话，但结果不会直接标出或滚动到命中的具体消息（搜索入口与结果呈现工作流见 Chat UI 笔记）。
  - 查询参数含 `excludeStatuses`/`excludeTriggers`/`includeTriggers`（`models/topic/find.ts`，`includeTriggers` 优先于 `excludeTriggers`），列表查询可按状态/触发源排除（如排除已完成的自动化任务话题），`loadMoreTopics` 会把它们带到后续页。
- **消息内容搜索端点**：`apps/server/src/routers/lambda/message.ts:726` 的 `message.searchMessages`（`MessageModel.queryByKeyword`，经 `models/message/lookup.ts` 与 `models/message/search.ts` 的 BM25 + `sanitizeBm25Query`，后者还提供 `buildMessageSearchSnippet` 生成命中片段）。本次在 `src/` 下未找到聊天 UI 对它的调用——唯一找到的 `searchMessages` 前端调用是内置 message 工具（`botMessage` 路由的另一变体），不能把它误写成已有的前端消息定位功能。
- **可选 Elasticsearch 候选层**：FTS facade 可切换到 Elasticsearch。搜索实体包括 Topic、消息、Agent、群组、文档、文件、知识库和用户记忆；外部索引只返回候选，消息与 Topic 模型再从 PostgreSQL 按当前作用域与权限水化，数据库仍是事实源。见 `apps/server/src/services/ftsSearch/elasticsearch.ts`、`packages/database/src/models/message/search.ts`、`packages/database/src/models/topic/find.ts` 与 `apps/server/src/services/ftsSearchSync/index.ts`。
- **列表分页**：Topic 列表分页见第 3 节；消息列表的可见部分分页（`getMessages` 的 `current/pageSize` 参数在 `message.ts` 声明）由消息渲染器笔记的虚拟列表记录，本笔记不重复。
- **索引自愈（树医生）**：`packages/conversation-flow/src/doctor/diagnose.ts` 的 `diagnoseTopic`（入参为消息数组，返回 `{hiddenCount, issues, patch}`）用途是 "detect and repair message trees the reader cannot fully render"，实现分两步：
  - **诊断（只读）**：真的跑一遍 `parse()`，然后 diff 出 parse 无法渲染的消息，再按已知缺陷形状归因（并发分叉、陈旧分支索引、孤儿 signal 轮次、segment-split、丢失内容）；
  - **修复（显式人工触发）**：`src/features/TopicDoctorModal/Content.tsx`（SWR 拉诊断、按钮触发）调 `messageService.repairTopic`（`src/services/message/index.ts`），服务端在 `apps/server/src/routers/lambda/message.ts` 由 `topicDoctorRepo.repair`（`packages/database/src/repositories/topicDoctor/`）重新从数据库派生补丁执行（注释明确"the repair is a separate, explicit call"）。

## 6. 缓存、一致性、多窗口与并发写入

1. **单一写入者**（第 2 节已展开）：全局 ChatStore 的 transcript 层是 `dbMessagesMap`/`messagesMap` 的唯一写入者；会话级 store 只做单向镜像，写操作先转发给副本再同步回来。两份展示数据的分叉问题由结构消除，而不是靠回调对齐。
2. **引用稳定性集中在两处补丁**：镜像读取的 `chatTranscriptState()` 与静态模式的 `setStaticMessages` 都用 `stabilizeReferences`；`transcript/lens.ts` 用 WeakMap 按「同一 rows + paging」缓存派生 view。派生只发生在 lens 一处，不存在早期多个 parse 调用点各缝一次的情况。
3. **messageMapKey 与服务端缓存 key 并非同构**：副本按 `services/message/replica` 的 `conversationMessagesKey` 落盘（保留 `documentId`/`subAgentId` 等本地维度），服务端列表缓存身份由 `getMessageListCacheIdentity` 计算（只认 agentId/groupId/threadId/topicId）。两者不同构时以副本 key 为准，翻页用 round-cursor（`getMessageListWindowOlderCursor`）而不是重新取整页。
4. **`reconcileAssistantToolLinks`**（`slices/message/actions/query.ts`、`internals.ts` 与 `transcript/` 共用）专门用来修复“assistant.tools[] 弄丢了某条工具引用，但对应的 tool 消息行还在”的情况——`internals.ts` 注释直接写 “an optimistic updateMessage{tools} on the wrong/old assistant during a step boundary can drop the link”，说明流式生成的 step 边界上，`tools[]` 数组和独立的 tool 消息行两份数据保持同步本身就是一个容易出错、需要专门补救的地方。
5. **多窗口/多端并发写入**：本次未覆盖多窗口与并发写入合并语义（客户端无多窗口写入入口；服务端写入合并行为未调查），未验证（不虚构）。

## 7. 迁移、导入导出与保留策略

- **导入/导出**：Topic 级 `importTopic`/`duplicateTopic`（`src/store/chat/slices/topic/action.ts`）已见第 3 节；服务端 clone/import 的实现在 `packages/database/src/repositories/topic/`（`duplicate.ts`、`topicImporter/`），其内部数据语义（消息深拷贝、附件/文件引用处理）本次未逐行下钻。
- **schema 版本与数据库迁移**：`packages/database/migrations` 的 journal 已推进到 0201 号迁移，新增的迁移集中在频道、目标、项目、工作区、记忆等新表（如 `0184_channel_tables.sql`、`0193_goal_file_shares_memory_structure_tables.sql`、`0199_topic_analyses.sql`）。messages 与 topics 的 schema 文件在本次范围内没有改动（`packages/database/src/schemas/message.ts`、`topic.ts` 的 diff 为空），但对应模型已拆成目录：`models/message/` 25 个文件（analytics、annotation、attachments、backgroundSubAgent、branchSnapshots、cursorWindow、search、spine、trash 等），`models/topic/` 15 个文件（context、create、find、list、scheduledRun、taskCallback 等）。Topic 的遗留 `sessionId`/`containerId` 兼容注释仍在 `models/topic/find.ts`。
- **树修复作为“恢复”手段**：崩溃/异常留下的不可渲染树形通过第 5 节的 doctor 诊断 + 人工 `repairTopic` 恢复（服务端重新派生补丁），这是本次确认到的唯一“修复既有数据”路径。
- **保留语义**：
  - 删除 Topic 可连附件（`removeTopic(removeFiles)`，1340 行）；
  - `switchTopic` 清 `_new` 桶乐观数据；
  - 流式中的半截 assistant 消息由发送链的 `cleanupTempMessages`/`rollbackOptimisticTopic` 处理（对话请求与上下文笔记）；
  - 本地专属消息（`isLocalOnlyMessage`，如语音上传占位行）明确不写入 SWR/IndexedDB 规范缓存（`query.ts:248-249` 注释）。

## 8. Agent、模型、知识库与附件绑定

- **绑定粒度**：Agent/模型绑定在会话（topic）级（第 1.3 节）；附件/文件引用与工具选择绑定在消息级（user 消息 metadata + editorData）；工具调用与结果作为独立消息行存在（第 1.3 节）。本次未找到会话级“知识库”绑定字段（知识库检索属于 Agent 角色/工具专项，发送时注入点见对话请求与上下文笔记第 9 节）。
- **历史快照 vs 引用**：topic 创建时 `snapshotAgentModel` 快照模型/provider（`conversationLifecycle/index.ts` 调用 `src/store/chat/utils/snapshotAgentModel.ts`），会话级配置变化不追溯改旧 topic；消息级 `editorData` 中 skills/tools/mentions 在发送时持久化进 user 消息内容（同一文件，跨轮次存活），属于“写时快照”而非引用。

## 9. 设计取舍与已确认边界

- 本地分桶 key 的 scope 远比“agentId/topicId/threadId 三元组”复杂：实际存在 main/thread/group/group_agent/page/sub_agent（别名，会被强制映射回 main）等 6 种 scope，各自有独立的字段映射和降级规则（详见第 1.1 节），且这套本地 key 与服务端 `message:list` 缓存 key 并不同构。
- 消息副本成为 chat store 的独立层后，`parse()` 只在一处派生（`transcript/lens.ts`）；一次“发消息/审批/编辑”不再触发两套独立解析，展示数据只有一份来源（详见第 2 节）。
- 会话级 store 实例**跨 topic 存活**，切换时由 `StoreUpdater` 用 `createEphemeralResetState` 原地重置（2.2 节）——重置清单要与新加入的 UI-only 状态字段保持同步。
- 树形数据在生产环境中会出现需要专门修复的异常状态：`doctor/diagnose.ts`、`reconcileAssistantToolLinks`、`stabilizeReferences` 都是针对已知问题的手工补丁（详见第 5、6 节）。
- **类目边界**：本笔记只回答数据语义与持久化形状；发送任务如何读取这些数据、审批如何恢复任务属于对话请求与上下文；`conversation-flow` 的三阶段解析算法与虚拟消息生成细节、列表窗口化与滚动属于消息渲染器；Topic 侧栏、搜索面板、分支导航等界面工作流属于 Chat UI。

## 10. 未验证事项

- 全局 `messagesMap` 的消费点未完全排查；主渲染路径走会话级镜像的 `displayMessages`，但若存在直接订阅全局 `messagesMap` 的组件，其引用稳定性只由 lens 的 WeakMap 保证。
- 消息数据库 schema 本身在本次范围内未变，迁移只新增了其他业务表；服务端导入导出/复制的数据语义（消息深拷贝、附件引用）与多窗口/多端并发写入合并语义未调查，不虚构。
- 本轮按引用路径核对并改写了副本/镜像、分桶、Topic 操作、检索与树医生的定位，未重新逐行通读 `conversation-flow` 的三阶段解析与 `transcript` 的全部流程；行号引用以模块级定位为准。
- 崩溃恢复与保留语义中“异常退出后半截流的落库行为”未运行验证（发送链的清理/回滚逻辑仅静态确认）。
- 服务端 `topicDoctorRepo.diagnose/repair` 的具体 SQL/事务实现未下钻（仅确认路由入口与前端调用链）。
- Elasticsearch 索引回填、outbox 重放、mapping generation 切换和候选排序未运行验证；PostgreSQL 水化与权限复核入口已静态确认。
- 多窗口/多端并发写入合并语义未验证（见第 6 节第 5 点）。

## 11. 关键源码索引

- `src/store/chat/utils/messageMapKey.ts`（`toMessageMapContext`/`generateKey`/`messageMapKey`）
- `src/features/Conversation/useAgentContext.ts`、`useAgentConversationCoordinate.ts`：坐标拼装
- `src/store/chat/slices/message/initialState.ts`：副本状态（`dbMessagesMap`/`messagesMap`/`messagePagingMap`/`messageReplica`）
- `src/store/chat/slices/message/transcript/index.ts`、`lens.ts`、`mergeFetched.ts`：副本唯一写入者、派生 view、拉取合并
- `src/store/chat/slices/message/actions/transcript.ts`：头部同步、翻页、定稿（`internal_settleTranscript`）
- `src/store/chat/slices/message/actions/query.ts`（`replaceMessages`/`revalidateMessages`/`prefetchMessages`）、`internals.ts`
- `src/services/message/{cache,replica,roundCursorPage}.ts`：缓存身份、副本契约、round-cursor 翻页
- `src/libs/replica`：本地副本持久化
- `src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`：把桶交给 Provider
- `src/features/Conversation/ConversationProvider.tsx`、`StoreUpdater.tsx`：订阅桶、原地重置、静态转录
- `src/features/Conversation/store/slices/data/action.ts`、`stabilizeReferences.ts`：单向镜像与引用稳定
- `src/features/Conversation/store/slices/message/action/crud.ts`：消息 CRUD 与分支
- `src/features/Conversation/store/slices/tool/action.ts`：工具审批入口
- `src/store/chat/slices/topic/action.ts`：Topic 生命周期
- `src/store/chat/slices/agentRun/actions/entries/conversationLifecycle/index.ts`：发送前上下文/元数据
- `packages/conversation-flow/src/{indexing,structuring,parse}.ts`、`transformation/{BranchResolver,MessageCollector,FlatListBuilder}.ts`
- `packages/conversation-flow/src/doctor/diagnose.ts`：树诊断
- `packages/database/src/models/message/`、`models/topic/`：拆分后的数据模型
- `packages/database/src/schemas/{message,topic}.ts`、`packages/database/migrations`：schema 与迁移
- `apps/server/src/routers/lambda/topic/`（`queries.ts` 的 `searchTopics`）、`routers/lambda/message.ts`（`searchMessages`/诊断修复）
- `packages/conversation-flow/src/doctor/`、`packages/database/src/repositories/topicDoctor/`
