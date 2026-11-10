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

- 每个会话桶（messageMapKey）的消息由全局 ChatStore 的 transcript 层独占写入：原始行与解析后的展示列表都只在该层落盘，并经本地副本库 `@/libs/replica` 持久化；会话级 ConversationStore 是它的**单向镜像**，通过 `internal_syncChatTranscript()` 读取同一桶，写入时先转发回 chat store。
- 镜像有两种来源：默认订阅 chat store 的桶引用变化（StoreUpdater 内的 useChatStore.subscribe）；传入静态消息时（画廊、分享快照）本地 store 自行持有，标记为静态转录，既不订阅也不回写。
- 本地消息分桶 key 比服务端消息列表缓存 key 更细，多出 documentId、subAgentId 等维度；缓存身份由 `src/services/message/cache` 的 getMessageListCacheIdentity 计算，副本 key 由 `src/services/message/replica` 定义，两者不同构时以副本 key 为准。
- 消息是带 parentId、threadId、groupId 的扁平数组，渲染前重建为树；分支激活指针存在**父消息**的 metadata 里，具体是 activeBranchIndex 字段，解析交给 BranchResolver，UI 只负责改一个整数。
- 工具调用与结果是独立的持久化消息行；删除“组”消息时要连带收集工具结果行的 id 一起删。
- Topic 全生命周期（创建/切换/删除/收藏/完成/导入/复制）在 `topic/action.ts` 中实现，列表按页拉取（默认每页 20）；Topic 搜索走服务端 BM25（标题加消息内容），message.searchMessages 端点本次未找到聊天 UI 调用。
- 树修复按“诊断只读、修复显式”两步走：doctor/diagnoseTopic 跑真实 `parse()` 产出补丁，修复由 TopicDoctorModal 人工触发服务端的 repairTopic 执行，没有自动应用的写路径。

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

| 维度 | 字段 |
| --- | --- |
| 会话定位 | agentId、topicId、threadId、groupId?、scope? |
| 子 Agent/文档 | subAgentId?、documentId?、agentDocumentId?、isolatedTopic?、isSubAgent? |
| 其他 | workspaceSlug?、editingGroupId? |

坐标由 `useAgentContext`（`src/features/Conversation/useAgentContext.ts:16-44`）从路由坐标（`useAgentConversationCoordinate`）+ `useDocumentStore` 的 topic-document 关系拼出；`documentId` 只有在活动 document 属于 notebook 且绑定当前 topic 时才带上。

真正把这坐标“压平”成一个 map key 的是 `messageMapKey`（`src/store/chat/utils/messageMapKey.ts`）：

- `toMessageMapContext`（`messageMapKey.ts:50-117`）按优先级把输入归一化成 `{scope, scopeId, topicId, subTopicId, isNew}` 五个字段，规则依次为：
  - page 作用域带 documentId 时，键为 `page_<agentId>_<documentId>`；注释指出缺少 documentId 会让两个不同文档共用一个桶，互相泄漏历史、串行排队操作；
  - threadId 与 thread 作用域同时成立时 thread 优先；Group Chat 里任务会用 SubAgent 的 agentId 建 thread，这条显式优先级用来避免与 groupId 混淆；
  - 存在 groupId 时，以 subAgentId 作为 subTopicId 生成 group_agent 键，表示子 Agent 在群里的独立消息流，否则用默认 group 键；
  - 只有 threadId 而未显式指定作用域时，推断为 thread；
  - 其余情况落到 main；sub_agent 作用域会被强制映射回 main，注释说明两者是同一会话的不同展示。
- `generateKey` 与入口 `messageMapKey` 同在 `messageMapKey.ts:122-180`：前者按 `${scope}_${scopeId}[_{topicId}][_{subTopicId}][_new]` 拼字符串，page 无 topic 时跳过字面量 null 段；后者是调用入口。

这套 key 同时被 chat store 的 transcript 副本与会话级镜像使用（见第 2 节），是它们定位到同一份数据的唯一纽带。副本读写不经写穿缓存函数：副本按本地分桶 key 落盘，持久化形状由 `src/services/message/{replica,cache}` 各自定义，缓存侧只认 agentId/groupId/threadId/topicId 等会话坐标，本地专属的 `documentId`/`subAgentId` 维度不进服务端缓存 key，因此副本按自己的 key 存，服务端缓存按更粗的 key 取，两者天然不完全对齐。

流式期间 chat store 的同步会丢弃不改变内容的头部响应，`settle` 只在 run 结束时把转写定稿落盘；也就是说，逐 token 的中间态只存在内存里，不逐次写副本。这一点与本地分桶 key 更细的事实叠加，构成本地展示与服务端快照之间持续存在的一致性耦合点。

### 1.2 消息数据形状与树

消息是扁平数组（`UIChatMessage`，字段含 `id/parentId/threadId/groupId/role/tools/agentId/...`），渲染前经 `conversation-flow.parse()` 重建为树（`packages/conversation-flow/src/parse.ts:23-51`：预处理 sub_agent 消息的 agentId 覆盖 → 索引 → 建树 → 变换 → flatList）。树的构建与虚拟消息生成算法本身属于消息渲染器笔记，本笔记只记录数据形状与数据修复事实：

- `buildHelperMaps`（`indexing.ts:42-119`）在解析前建立四类辅助映射：

  - messageMap：消息 id 到消息；
  - childrenMap：parentId 到子消息 id 列表；
  - threadMap：threadId 到消息列表；
  - messageGroupMap：compare 与 manual 分组元数据。
- `buildIdTree`（`structuring.ts:11-38`）**过滤掉带 threadId 的消息**：thread 是独立话题线，不进主干树。
- **压缩组重定向**：建立压缩前链条最后一条消息（lastMessageId）到压缩组 id 的映射，再把引用它的 parentId 改指向压缩组本身；缺少这一步，压缩后新产生的消息会挂到已被隐藏的消息下面，从树上"消失"。映射建立与重定向同在 `indexing.ts:52-79`。
- **孤儿兜底**：parentId 指向的消息若不在当前查询到的消息集合里（分页或局部查询漏掉祖先），该消息直接降级为根节点，注释原文是 "so post-compression follow-up chains remain visible instead of being dropped entirely"。见 `indexing.ts:80-86`。
- **dual-form 历史数据形态**（`transformation/MessageCollector.ts`）：assistant 与工具消息的链接关系存在两种历史形态：
  - assistant-anchored（新形态）：下一步 assistant 是当前 assistant 的非工具子节点，与 tool 结果互为兄弟；
  - tool-anchored（旧形态）：下一步 assistant 挂在某个 tool 结果消息下面；
  - 候选收集由 findFlatChainContinuation 同时从两个位置完成，遇到 AgentCouncil 或异步任务子节点时链路终止，最终分支由 resolveActiveContinuationId 解析，定位见 `transformation/MessageCollector.ts:256-289`。
- **分支数据语义**：分支指示器画在**子消息**上，激活索引存在**父消息**的 metadata 里。解析器 `BranchResolver`（`transformation/BranchResolver.ts:12-159`）有两个入口：contextTree 用 IdNode 版本 getActiveBranchId，flatList 用 child-id 数组版本 getActiveBranchIdFromMetadata，两者判定逻辑一致，优先级依次为：
  1. 读取 activeBranchIndex；索引越界到等于子节点数，表示乐观更新中分支尚未创建，返回 undefined；
  2. 选出包含最新持久化 user 后代的分支，避免重试分支把当前用户轮次挤出历史；
  3. 退化为选第一个带子节点的分支；
  4. 兜底选第一个。
  - 工具结果行不参与分支兄弟的候选。

### 1.3 外部对象绑定粒度（可确认部分）

- 附件/文件引用在**消息 metadata 层**绑定。发送时写入 user message 的 metadata，字段包括：

  - fileIdList；
  - contextSelections；
  - pageSelections；
  - localSystemToolSnapshots。

  编辑器数据（editorData）在同一文件里提取为 skills、tools、mentions 和文件引用，解析集中在 `parseLocalFileReferencesFromEditorData` 等一组 helper，注入执行语义见对话请求与上下文笔记。发送链入口 conversationLifecycle 已从单文件改为目录，主链在 `index.ts`（约 2,182 行），另有 compression、runCwd、sendErrorNotice 三个文件。
- 工具调用与结果是**独立的持久化消息行**：
  - 删除"组"消息（assistantGroup 或 supervisor）时，要把 children 中每个 block 的 id 和每个 block 内 tools[].result.id 对应的工具结果消息一起收集进删除列表，因为这些都是底层 db 行；
  - deleteAssistantMessage 则按 tool_call_id 反查并连带删除。
  两处逻辑同在 `crud.ts:261-320`。
- 模型/渠道在**会话（topic）级**保存快照：发送创建新 topic 时，由 snapshotAgentModel 与 snapshotAgentReasoning 写入 topics 的 model、provider 列；切换 topic 模型走 updateTopicModel，定位见 `src/store/chat/utils/snapshotAgentModel.ts` 与 `src/store/chat/slices/topic/action.ts:640`。

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

- 头部同步与翻页：`actions/transcript.ts` 的 MessageTranscriptActionImpl 在挂载时同步头部页，旧页经 loadEarlierMessages 与 loadLaterMessages 走 round-cursor 翻页；
- 本地持久化：副本经 `@/libs/replica` 的 createReplicaSlice 落 IndexedDB，刷新后先画已落盘的转写，再由网络头部校正；
- 定稿：internal_settleTranscript 在 agent run 结束时持久化转写，已无视图显示的会话同样落盘，流式中间态只留内存；
- 修补式替换：`query.ts` 的 replaceMessages 负责 preserveWorks（中期 refetch 保留 Work 芯片）、语音占位合并与 reconcileAssistantToolLinks，最终写的是副本层条目。

主聊天页向会话 Provider 传入上下文、操作状态与行为 hooks，**省略 `messages` prop**，由 Provider 内的镜像层订阅全局消息桶。显式传消息数组会被解释为静态转录并关闭同步，不能用这条路径解释实时聊天。见 [ConversationArea 的 Provider 接线](../../lobehub/src/routes/%28main%29/agent/features/Conversation/ConversationArea.tsx#L142-L148)、[StoreUpdater 来源判断与订阅](../../lobehub/src/features/Conversation/StoreUpdater.tsx#L83-L109)。

### 2.2 会话级 ConversationStore：单向镜像

Provider 实例跨 topic 存活，切换时不重建 store：`StoreUpdater` 在 paint 前用 `createEphemeralResetState` 原地重置 UI-only 状态（输入内容、选中、滚动位置等），保留仍挂在 DOM 上的编辑器与虚拟滚动字段，并把 `messagesInit` 置为当前是否为静态转录。

数据来源只有一处：默认 `transcriptSource='chat'`，`StoreUpdater` 订阅 chat store 的桶引用变化后调用镜像同步方法 `internal_syncChatTranscript()`；镜像读取由 `chatTranscriptState()` 完成——行来自原始消息表，解析结果优先复用已 parse 的展示表，再用 `stabilizeReferences` 固定引用。

传入 `messages` 时进入静态转录模式（`transcriptSource='static'`）：本地直接持有该数组，`replaceMessages(messages)` 跟随 prop，既不订阅 chat store 也不回写，用于画廊与分享快照。`createStoreAction` 在创建时若拿到初始消息会先 parse 一次，避免挂载首帧空白。

局部写方法的行为随来源分叉：chat 模式下 `internal_dispatchMessage`/`replaceMessages` 先把写入转发给 `useChatStore` 再同步回来；静态模式下直接走本地 `messagesReducer` 与 `setStaticMessages`。

### 2.3 同步方向与引用稳定性

两层之间只剩一个方向：chat store 副本 → 会话级镜像。镜像在挂载的会话上订阅桶引用变化并重读；写入一律先落副本，再回读，不存在局部 store 写完后回调全局的第二条路径。

引用稳定性由两处手工补丁保证：镜像读取的 `chatTranscriptState()` 与静态模式的 `setStaticMessages` 都调用 `stabilizeReferences`，用 `@tanstack/react-query` 的深比较把未变子树钉回上一帧引用；此外 `transcript/lens.ts` 用 WeakMap 按「同一 rows + paging」缓存派生 view，使重复读取返回同一对象。parse 本身不保证稳定引用，稳定性仍靠这两层补丁。

一致性事实：未挂载的会话没有镜像，但副本仍在 agent run 结束时由 `internal_settleTranscript` 定稿落盘；镜像只在挂载期间跟随，所以「看到的数据」与「已落盘的数据」在流式期间可以短暂不同，刷新或重挂载后以副本为准。

### 2.4 为什么要分两层（能看出的设计动机）

- 全局状态刻意保持全局，范围包括 operations 系列状态映射与 dbMessagesMap 原始消息表，让多个 Agent/Topic 同时跑生成任务成为可能——`ConversationProvider.tsx:86-91` 的文档注释原文是 "Operations are kept global to support multiple agents/topics running in parallel."。
- 局部状态（generation/editing/selection/scroll/virtua 相关与 pendingArgsUpdates）放进按 contextKey 隔离的 store，切 topic 时由 StoreUpdater 的 createEphemeralResetState 一次性丢弃重置（见 2.2），无需手写逐项清理。（这些 UI-only 状态如何被界面消费属于 Chat UI 笔记。）

## 3. 创建、切换、归档、删除与恢复（Topic 生命周期）

Topic 生命周期在 `src/store/chat/slices/topic/action.ts`（ChatTopicActionImpl，约 1,775 行）中实现；服务端的复制与导入下沉到 `packages/database/src/repositories/topic/`，路由按职责拆到 `apps/server/src/routers/lambda/topic/`，入口包括创建、查询、删除、分享和转写等文件：

- **创建（惰性）**：聊天页面本身不预建 Topic，Topic 在两类时机被创建：
  - 用户主动开"新话题"：createTopic 直接新建，或由 saveToTopic 把当前展示消息绑定进新 topic 并异步自动摘要标题；
  - 首次发送时由发送链创建：客户端先铸造 topic id，再插入乐观侧栏行（见对话请求与上下文笔记）。

  两条路径最终都进入 internal_createTopic：先用 Date.now() 生成临时 id 乐观插入，再由 topicService.createTopic 落库并 refreshTopic，乐观行由 creatingTopicIds 追踪。创建入口见 `topic/action.ts:345`。
- **切换**：switchTopic 先清 `_new` 桶、置 activeTopicId 并标记已读，再用微任务配合 #switchTopicEpoch 防止连点竞态，最后触发 revalidateMessages；深链与预取场景依赖 revalidateMessages 的 "server verified" 软保证，分桶 refetch 与进行中的预取共享同一结果（`query.ts:46`）。入口在 `topic/action.ts:1475`。
- **重命名/收藏/完成**：一组并列操作，各自对应一个方法：
  - updateTopicTitle；
  - favoriteTopic；
  - markTopicCompleted 与 unmarkTopicCompleted，写 completedAt；
  - updateTopicMetadata、autoRenameTopicTitle。

  这些方法位于 `topic/action.ts:332-795`。
- **删除**：分单删与批量删两类：
  - 单删由 removeTopic 完成，可带 removeFiles 一并删附件，删除后逐出该 topic 的消息缓存并回到默认话题；
  - 批量删由 removeSessionTopics、removeGroupTopics、removeAllTopics 完成，删除后统一逐出消息缓存并切回默认话题；
  - removeUnstarredTopic 删除未收藏话题，cleanupStaleRunningTopics 清理陈旧的运行标记。

  实现位于 `topic/action.ts:635-1372`。
- **复制/导入**：duplicateTopic 与 importTopic 在 store 侧只做状态更新与跳转，实际数据语义在服务端 repository 里，涉及消息树深拷贝与附件引用，本次未下钻其 SQL。store 侧入口在 `topic/action.ts:394-445`。
- **归档**：本次未找到"归档（archive）"概念。本快照的 topic 数据模型没有 archive 标志位，状态字段为 completedAt、favorite、status；检查范围是 `topic/action.ts` 的全部方法列表与 topic 类型定义。
- **列表分页**：分桶存储配合追加式翻页。
  - 分桶：useFetchTopics 与 useFetchAgentTopicsView 分别维护 topicDataMap 与 agentTopicsViewMap；
  - 翻页：loadMoreTopics 与 loadMoreAgentTopicsView 追加下一页，pageSize 取 globalStore.status.topicPageSize，缺省为 20，并把触发源与状态的排除条件（excludeTriggers、excludeStatuses）带到后续页；
  - 服务端 getMessages 同样接受 current 与 pageSize 分页参数，见 `apps/server/src/routers/lambda/message.ts:347-359`。

  前端实现位于 `topic/action.ts:803-1134`。

## 4. 消息 CRUD 与数据变更语义

`src/features/Conversation/store/slices/message/action/crud.ts`：

- `createMessage`（`crud.ts:207` 起）分两步完成：
  1. 先用 createTempMessage 插入一条 `tmp_<nanoid>` 临时消息，走 internal_dispatchMessage 的 createMessage 类型；
  2. 再调 messageService.createMessage，成功后用服务端返回的 result.messages 整批 replaceMessages 覆盖，失败则把临时消息标为错误。
  - id 一致性由客户端预生成保证：`packages/utils/src/entityId.ts` 的 generateEntityId 以与服务端相同的字母表和前缀铸造 id，发送链与 execAgent 服务端都按这个 id 落库（见 conversationLifecycle 的注释）。
- `deleteMessage`（`crud.ts:298-336`）处理三类情况：
  - 目标是 assistantGroup 或 supervisor 时，把 children 中每个 block 的 id 与每个 block 内 tools[].result.id 对应的工具结果消息一并收集进删除列表，保证删掉一个"组"时底层 db 行一起清理；
  - 单条删走 messageService.removeMessage 并重接父子链，批量删走 removeMessages；
  - 其余变体：
    - deleteDBMessage；
    - deleteMessages；
    - deleteToolMessage，连父 assistant 的 tools 条目一起删；
    - removeToolFromMessage。

  crud 中这些方法的行号范围为 `crud.ts:281-401`。
- `updatePluginArguments`（`crud.ts:542-637`）：更新工具参数时同时乐观更新工具消息本身和父 assistant 消息 tools 里的对应条目，并把这次更新的 Promise 以 toolCallId 为 key 记录进 pendingArgsUpdates，供 waitForPendingArgsUpdate 在审批或拒绝前等待，保证正在进行的参数编辑先落地，避免竞态。

### 4.1 编辑 / 多选状态（纯局部 UI 状态）

`src/features/Conversation/store/slices/messageState/action.ts` 提供编辑与多选两类纯局部 UI 状态操作：

- 编辑：`toggleMessageEditing`（123-129 行）；
- 多选：`enterSelectionMode`/`selectRange`/`selectToHere`/`toggleMessageSelected`（59-141 行，支持类似微信的 shift 范围选择和"选择到这里"）。

这些操作只改 `selectedMessageIds`/`selectionAnchorId`/`selectionMode` 三个字段，不落库、不经过全局 store；如何呈现在界面上属于 Chat UI 笔记。

### 4.2 分支切换的数据语义

局部 switchMessageBranch（`store/slices/data/action.ts:232-243`）只做两件事：取出目标消息的 parentId，再调用 updateMessageMetadata 写入 activeBranchIndex。分支指示器画在**子消息**上，激活索引却存在**父消息**的 metadata 里，判断哪个分支激活的逻辑在 BranchResolver（第 1.2 节），UI 只负责改一个整数。全局 ChatStore 有一份几乎相同的实现，走 optimisticUpdateMessageMetadata 写入，见 `conversationControl.ts:313-323`。

### 4.3 工具审批的数据层事实（薄转发层）

`src/features/Conversation/store/slices/tool/action.ts` 的 `ToolActionImpl`（18-208 行）里**每一个**方法都是薄转发：

- 单个方法：
  - approveToolCall
  - rejectToolCall
  - rejectAndContinueToolCall
  - skipToolInteraction
  - submitToolInteraction
  - cancelToolInteraction
  - submitHeteroIntervention
- 批量方法：
  - approveAllToolCalls
  - stopPendingApproval
  - stopPendingApprovalForCard

它们共同的固定三步：等待 `waitForPendingArgsUpdate` 落定 → 触发本地批准/拒绝钩子的回调 → **转调全局 ChatStore 上的同名方法**，把局部上下文传过去（例：`approveToolCall`，`tool/action.ts:27-47`）。业务逻辑（Gateway/本地 client runtime 二分、乐观更新顺序、IPC/tRPC 转发异构 Agent 干预）全部在**全局** ChatStore 的 `conversationControl.ts`，属于对话请求与上下文笔记第 7 节。

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

1. **单一写入者**（第 2 节已展开）：全局 ChatStore 的 transcript 层是 dbMessagesMap 与 messagesMap 的唯一写入者；会话级 store 只做单向镜像，写操作先转发给副本再同步回来。两份展示数据的来源由结构统一，无需靠回调对齐。
2. **引用稳定性集中在两处补丁**：镜像读取的 `chatTranscriptState()` 与静态模式的 setStaticMessages 都用 stabilizeReferences 固定引用；`transcript/lens.ts` 用 WeakMap 按「同一 rows + paging」缓存派生 view，派生只发生在 lens 一处。
3. **messageMapKey 与服务端缓存 key 并非同构**：副本按 `src/services/message/replica` 的 conversationMessagesKey 落盘，保留 documentId、subAgentId 等本地维度；服务端列表缓存身份由 getMessageListCacheIdentity 计算，只认会话级坐标，文档与子 Agent 维度由副本单独保留。两者不同构时以副本 key 为准；翻页通过 round-cursor 定位，避免重新取整页。
4. **`reconcileAssistantToolLinks`**（`slices/message/actions/query.ts`、internals.ts 与 transcript/ 共用）专门用来修复 assistant.tools 数组丢失某条工具引用、而对应的 tool 消息行还在的情况。internals.ts 注释直接写 “an optimistic updateMessage{tools} on the wrong/old assistant during a step boundary can drop the link”，说明流式生成的 step 边界上，tools 数组和独立的 tool 消息行两份数据保持同步本身容易出错，需要专门补救。
5. **多窗口/多端并发写入**：本次未覆盖多窗口与并发写入合并语义；客户端没有多窗口写入入口，服务端写入合并行为未调查，均未验证。

## 7. 迁移、导入导出与保留策略

- **导入/导出**：Topic 级的 importTopic 与 duplicateTopic 已见第 3 节；服务端 clone/import 的实现在 `packages/database/src/repositories/topic/`，内部数据语义涉及消息深拷贝与附件/文件引用处理，本次未逐行下钻。
- **schema 版本与数据库迁移**：`packages/database/migrations` 的 journal 已推进到 0201 号迁移，新增的迁移集中在频道、目标、项目、工作区、记忆等新表，例如频道表、目标文件分享与记忆结构表、topic 分析表（0184、0193、0199 号迁移）。messages 与 topics 的 schema 文件在本次范围内没有改动（diff 为空），但对应模型已拆成目录：

  - 消息模型 25 个文件，涵盖 analytics、annotation、attachments、backgroundSubAgent、branchSnapshots、cursorWindow、search、spine、trash 等；
  - topic 模型 15 个文件，涵盖 context、create、find、list、scheduledRun、taskCallback 等。

  Topic 遗留的 sessionId、containerId 兼容注释仍在 `models/topic/find.ts`。
- **树修复作为“恢复”手段**：崩溃或异常留下的不可渲染树形通过第 5 节的 doctor 诊断加人工 repairTopic 恢复，服务端重新派生补丁，这是本次确认到的唯一“修复既有数据”路径。
- **保留语义**：
  - 删除 Topic 时可一并删附件，对应 removeTopic 的 removeFiles 参数，入口在 `src/store/chat/slices/topic/action.ts:1340`；
  - switchTopic 清 `_new` 桶里的乐观数据；
  - 流式中的半截 assistant 消息由发送链的 cleanupTempMessages 与 rollbackOptimisticTopic 处理（对话请求与上下文笔记）；
  - 本地专属消息（例如语音上传占位行）不写入 SWR/IndexedDB 规范缓存（`query.ts:248-249` 注释）。

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
