# AIO-Hub 会话与消息管理调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：从 [`../Chat/AIO-Hub-Chat调查笔记.md`](../Chat/AIO-Hub-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据；按提交范围核对会话持久化（原子写/回收站/损坏隔离）、加载期生成状态修复与索引恢复的代码变化，受影响结论在 HEAD 处源码重新确认，失效行号已更新
>
> 调查范围：会话/消息/分支的数据模型、事实源与持久化、生命周期、消息操作与分支语义、索引与检索（数据侧）、外部对象绑定、恢复与保留语义；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

llm-chat 以"会话 = 树形消息结构 + 活动路径指针"为存储单位：

- 会话有轻量索引（`ChatSessionIndex`，列表展示）与重量详情（`ChatSessionDetail`，节点字典 + 分支指针 + 撤销栈）两层，**分文件存储**：一个 `sessions-index.json` 存放全部索引，每个会话的完整详情单独存成 `sessions/{sessionId}.json`（`composables/storage/useChatStorageSeparated.ts`）。
- 消息是**树**（`parentId`/`childrenIds`/可选 `lastSelectedChildId`），`activeLeafId` 是当前显示路径的末端节点；线性对话列表只是消息树的一种视图。分支导航算法集中在 `utils/BranchNavigator.ts`（纯静态类）。
- **撤销/重做栈从不持久化**：写盘前删除 `history/historyIndex`，应用重启后历史栈清空——撤销只在单次会话运行期间有效（明确设计取舍）。
- 会话/节点 ID 用 `Date.now()`-随机后缀拼接，不是 UUID（理论碰撞风险，未见多设备同步机制）。
- 跨会话全文搜索**没有索引**：Rust 端每次都是目录全量扫描 + 正则预过滤 + 50 并发（`src-tauri/src/commands/llmchat_search.rs`），命中粒度只有会话级；会话内消息搜索是纯内存线性扫描当前活动路径，两套搜索能力不对等。
- 应用崩溃/强退后，"生成中"节点可能永久卡死：加载路径没有任何针对残留 generating 状态节点的检查或重置，僵死修复 watch 只有等 `generatingNodes.size` 先增后减才会触发。

## 系统边界与数据主链

```text
useSessionManager.createSession（根节点 + 开场白 live greeting 节点）
  -> sessionLifecycleManager.createSession（写入 store Map + persistSession 落盘 + clearHistory）
  -> 消息操作经 useNodeManager / useBranchManager 修改 detail（分支、重试、续写、硬删除）
  -> 流式期间节点 content 经节流缓冲写回（执行语义在对话请求与上下文 5）
  -> saveSession 写盘：索引 sessions-index.json + 详情 sessions/{id}.json 分离
  -> loadSessions 启动恢复 + 3 秒后台 repairIndex 索引自愈
  -> 检索：前端 useLlmSearch 调 Rust 命令，全目录扫描 + 正则预过滤
```

边界：生成任务如何读取/写回这些对象（上下文拼装、流式节流、压缩触发）在 [`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md)；界面动作的工作流与现场恢复在 [`<../Chat UI/AIO-Hub-ChatUI调查笔记.md>`](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)；消息与列表的绘制在 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)（已有独立笔记，内容渲染类内容一律链接过去，不复制）。

## 1. 会话、消息与分支数据模型

### 1.1 索引 / 详情分离

`ChatSessionIndex`（`types/session.ts:22-59`）是轻量索引，用于列表展示：`id`、`name`、`displayAgentId`（当前活动路径最新助手消息所用的 agentId，用于列表头像展示）、`messageCount`（缓存的有效消息数，排除根节点和未固化开场白）、`createdAt`/`updatedAt`、`isFavorite`/`favoriteFolderId`（收藏，只活在索引里）。

`ChatSessionDetail`（`types/session.ts:64-110`）是重量级详情：`nodes: Record<string, ChatMessageNode>`（以 ID 为键的节点字典）、`rootNodeId`、`activeLeafId`（当前活跃分支的叶节点 ID）、`parameterOverrides?`（会话级参数覆盖）、`history: HistoryEntry[]` + `historyIndex`（撤销/重做栈，数据结构在 `types/history.ts`）。

### 1.2 消息树：parentId / childrenIds / activeLeafId

`ChatMessageNode`（`types/message.ts:110-416`）：`parentId: string | null`（根节点为 null）、`childrenIds: string[]`（用于 O(1) 查找子节点，避免每次遍历全部节点）、可选的 `lastSelectedChildId`（记住上次在该节点下选择走的分支，用于"切走再切回"时恢复原位置）。

`activeLeafId` 存在 `ChatSessionDetail` 上。`getActivePath(sessionId)`（`stores/session/sessionAccessManager.ts:74-102`）从 `activeLeafId` 沿 `parentId` 一路向上走到根节点，`unshift` 拼出正序数组，最后过滤掉 rootNodeId 本身；若中途某个 `parentId` 指向的节点不存在，会 `logger.warn` 并 `break`（路径截断，不抛异常但静默丢失更早消息——见第 9 节）。

### 1.3 节点 metadata：状态字段与快照

正文仍是单一 `content: string`，富内容与状态放在 `metadata`（渲染层对 metadata 的读取见消息渲染器笔记 1.1）：

- **reasoning**：`metadata.reasoningContent` + `reasoningArtifacts`（用于精确回放 provider 自己维护的 reasoning 状态）+ `reasoningStateStatus: "intact"|"broken"`（`types/message.ts:279-292`）。上下文压缩把历史消息隐藏后其 replay artifact 失效，压缩节点会生成 `reasoningStateWarning`（执行侧见对话请求与上下文附录 A.2）。
- **翻译**：`metadata.translation` 保存 `content`/`targetLang`/`modelIdentifier`/`timestamp`/`visible`/`displayMode`（`"original"|"translation"|"both"`）；翻译的 LLM 调用在对话请求与上下文 9.7，界面入口在 Chat UI 6.1。
- **排队**：排队等待生成的消息节点打 `metadata.isQueued = true`（执行语义在对话请求与上下文 8）。
- **Agent 快照**：消息节点记录生成时 `metadata.agentId`/`agentName`/`agentIcon` 快照（见第 8 节）。
- **压缩**：压缩节点 `metadata.isCompressionNode = true` 及被遮罩 ID、原消息/Token 数等（见第 4.4 节与对话请求与上下文附录 A）。
- **会话变量**：含变量变更的消息写 `metadata.sessionVariableSnapshot`，是分支级状态回放的起点（注入语义在对话请求与上下文 9.4）。
- **附件**：附件作为节点字段随用户消息提交，两阶段导入状态机见第 8.3 节。

## 2. 事实源、索引与持久化

### 2.1 索引与详情分文件存储

存储仍采用"索引与详情分文件"策略：`sessions-index.json` 存放所有 `ChatSessionIndex`（+`favoriteFolders`），每个会话的完整 `ChatSessionDetail` 单独存成 `sessions/{sessionId}.json`。写入路径已重构为"协调器 + 原生原子写"——

- `useChatStorageSeparated.ts` 现在只是兼容门面（注释自述 "Compatibility facade"），所有写盘经 `SessionPersistenceCoordinator`（`services/sessionPersistenceCoordinator.ts`）合并：按会话/索引分槽、同一会话不允许并发写、写前同步捕获快照、失败按指数退避重试、最多 4 个并发会话写；
- 实际落盘由 Rust 命令 `llm_chat_atomic_write`（`src-tauri/src/commands/llm_chat_persistence.rs`）完成：临时文件写盘 + fsync + 原子替换，带 revision 校验（`_persistence.revision` 与 tombstone 比对，旧写 staleRejected）、进程级文件锁、`.bak` 有效备份轮换；命令只接受逻辑上的 llm-chat 标识符而非任意文件路径；
- 每个会话文件与索引文件都写入 `_persistence: { schema: 1, revision, committedAt }` 元数据（`services/sessionPersistenceRepository.ts` 的 `createPersistenceMeta`），旧文件按 revision 0 兼容；
- 损坏会话文件被隔离到 `sessions-corrupt/` 并登记 `corruption-manifest.json`（version 1），索引损坏时保留 `.corrupt` 样本并回退 `.bak` 或最高 revision 的临时文件（`IndexLoadResult` 区分 ready/recovered/missing/corrupt/unsupported/io-error，`types/persistence.ts:69-75`）；
- 分离窗口（`/detached-component/`）禁止直写持久化，必须经主窗口代理。

### 2.2 撤销/重做栈不持久化

`toStoredSession()`（`useChatStorageSeparated.ts:89-105`）在写盘前仍会剥离 `history`/`historyIndex` 与 `isFavorite`/`favoriteFolderId`，并补上 `_persistence` 元数据——**撤销/重做栈从不持久化到磁盘**，应用重启后历史栈清空（`sessionLifecycleManager.ts` 的 `loadSessions()`、`switchSession()` 都会在 detail 缺少有效 history 时调用 `managers.history.clearHistory(sessionId)` 重新初始化）。这是一个明确的设计取舍：撤销/重做只在单次会话运行期间有效，不是跨会话持久功能。

### 2.3 索引恢复与自愈

旧的"启动 3 秒后 `repairIndex()` 后台自愈"已被两套新机制取代（`sessionLifecycleManager.ts`）：

- **索引损坏时的后台恢复**：`loadSessions()` 发现索引状态为 `corrupt` 时调用 `startBackgroundIndexRecovery()`——带 AbortController（可取消）、并发 4、逐批回填 `sessionIndexMap`，并暴露 `sessionRecovery` 状态（`ready/recovering/corrupt` + 扫描/失败计数）给 LlmChat 工作台渲染恢复横幅（取消、打开损坏目录、导出诊断、删除隔离文件等入口在 `LlmChat.vue:318-376`）；
- **正常启动的增量核对**：`reconcileIndexIncrementally()` 只拿目录文件名与索引比对补新项（并发 4），不再解析每个会话文件，避免阻塞首屏；手动 `refreshSessionsIndex()` 仍走完整 repairIndex（带进度与失败计数，返回 `repairedCount/failedCount/cancelled`）。

### 3.1 创建会话

`useSessionManager().createSession(agentId, name?)`（`composables/session/useSessionManager.ts:99-178`）：

- 生成 `sessionId`/`rootNodeId`（`session-${Date.now()}-${random}` 格式，无强唯一性保证，靠时间戳+随机后缀降低碰撞概率，未见 UUID）；
- 创建 `role: "system"`、内容为空、`isEnabled: true` 的根节点；
- 未指定 `name` 时默认名 `会话 ${当前时间}`；
- `index.displayAgentId = agentId`（创建时就绑定 Agent）；
- 调用 `insertLiveGreetings(index, detail, agent, effectiveUserProfile)`（`services/greetingService.ts:106-153`）：Agent 配置了开场白（greetings）时为每条开场白创建 `metadata.isGreeting=true, greetingLive=true` 的"活的"节点挂到根节点下，并把 `activeLeafId` 指向默认开场白（`agent.defaultGreetingId` 命中项，否则第一条）。

`sessionLifecycleManager.createSession()`（`stores/session/sessionLifecycleManager.ts:148-181`）在此基础上把 index/detail 写入 store 的 Map、设为 `currentSessionId`、调用 `updateMessageCount` 刷新计数、`persistSession` 落盘，并 `clearHistory` 初始化撤销栈。

### 3.2 删除 / 批量删除 / 清理空会话

- 单个删除 `deleteSession()`（`sessionLifecycleManager.ts:183-210`）：删除不再直接 `remove` 文件，而是调用 Rust `llm_chat_delete_session` 把会话文件移入 `sessions-trash/`（文件名带随机 UUID 后缀，避免与新建会话冲突），返回 `moved_to_trash`；同时清理运行时状态（abort controller、generatingNodes、挂起的工具审批等，见第 6 节）与输入草稿，`switchSession` 到邻近会话（`useSessionManager.deleteSession()` 中，若删的是当前会话则取数组中相邻索引 `Math.min(index, length-1)`，`useSessionManager.ts:206-215`）。
- 批量删除 `batchDeleteSessions()`（`sessionLifecycleManager.ts:212-259`）：剩余会话按 `updatedAt` 倒序排列取第一个作为新当前会话；逐个删除文件、清理运行时和草稿。
- 清理空会话 `clearEmptySessions()`（`sessionLifecycleManager.ts:316-390`）：筛选 `messageCount === 0` 的会话；若当前会话在被清理列表中，优先按调用方传入的 `preferredOrderIds`（即 UI 上当前展示顺序）向前/向后找一个未被清理的邻居会话，找不到再退化为按 `updatedAt` 倒序取第一个剩余会话。这个实现比"随便切一个"更细致，是为了避免清空后 UI 焦点跳到一个语义上不相关的会话。
- 清空全部会话 `clearAllSessions()`：先经 `deleteSessionFiles` 把索引与磁盘上已知的所有会话文件 tombstone/移入回收站，再发布空索引——先关写路径，避免迟到的流式写盘"复活"已删文件（`sessionLifecycleManager.ts` 注释原话）。

本次调查范围（源 Chat 笔记）未见"归档"机制；会话状态字段只有收藏（`isFavorite`/`favoriteFolderId`），没有 `archivedAt` 类字段。

### 3.3 改名与会话更新入口

`updateSession()`（`sessionLifecycleManager.ts:430-501`）是通用的会话更新入口，字段合并逻辑在 `useSessionManager.updateSession()`（`useSessionManager.ts:236-281`，逐字段判断 `!== undefined` 才写入，避免覆盖未传字段）。改名之外，传入新 `displayAgentId`（即切换会话绑定的 Agent）时会尝试 `switchAgentGreetings(index, detail, agent, effectiveUserProfile)`（`services/greetingService.ts:313-366`）：仅当会话根节点的子节点里没有非开场白节点（会话尚未真正开始）时，才把旧 Agent 的 live greeting 节点整批删除、换成新 Agent 的开场白；否则静默跳过（不报错，也不提示用户"切换未生效"）。该判定的边界风险见第 9 节潜在风险 5。

### 3.4 恢复与保留语义

- 撤销/重做只在单次会话运行期间有效（2.2）。
- 应用重启后残留生成中节点会在加载时自动修复：有内容 → `complete`，无内容 → `error`（带"生成意外中断"错误），并回写磁盘（`repairInterruptedGeneratingNodes`，`sessionLifecycleManager.ts:63-90`；修复细节见第 9 节缺陷 1）。
- 索引损坏时先尝试 `.bak`/临时文件回退，失败则进入可取消的后台恢复并展示恢复横幅（2.3）；索引的 `messageCount`/`displayAgentId` 数值漂移在正常启动时不再全量修复，只有手动 `refreshSessionsIndex` 才完整重算。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 分支导航：BranchNavigator

`utils/BranchNavigator.ts` 是纯静态类，核心方法：

- `getSiblings(session, nodeId)`（第29-57行）：通过父节点的 `childrenIds` 取兄弟列表；根节点没有父节点，视为"自己是唯一兄弟"。
- `switchToSibling(session, nodeId, direction)`（第63-102行）：在兄弟列表里按 `(currentIndex ± 1 + length) % length` 循环切换（切到最后一个再点"下一个"会绕回第一个），再用 `findLeafOfBranch` 找到目标兄弟分支下的叶子节点。
- `findLeafOfBranch(session, startNodeId)`（第108-154行）：从起点沿子节点一路走到叶子，每一步优先用该节点的 `lastSelectedChildId`（若仍在 `childrenIds` 中），否则退化为 `childrenIds[0]`。这就是"记住上次看到哪条分支"的实现。
- `updateSelectionMemory(session, leafNodeId)`（第160-201行）：从叶子回溯到根，把路径上每个父节点的 `lastSelectedChildId` 更新为路径中的下一个节点。所有会改变 `activeLeafId` 的操作（切换分支、创建分支、硬删除节点后重新定位）都会调用它，保证记忆链条一致。
- `ensureValidActiveLeaf(session)`（第242-253行）：如果 `activeLeafId` 指向的节点已不存在，重置为 `rootNodeId`。只在撤销/重做后（`sessionHistoryManager.persistHistoryMutation`，`stores/session/sessionHistoryManager.ts:60-77`）显式调用，其他修改路径（如普通删除）各自在内部处理相邻节点回退逻辑，并不统一走这个兜底。

界面上的分支按钮与 `n/total` 选择器在 Chat UI 6.2。

### 4.2 创建分支

`useBranchManager().createBranch(session, sourceNodeId)`（`composables/session/useBranchManager.ts:162-256`）：只允许对 `role === "user"` 或 `"assistant"` 的节点创建分支（预设消息不行，工具调用节点见下）。实现是创建一个与源节点**同 parentId** 的新兄弟节点，复制 `content`/`attachments`，如果是助手消息则整份复制 `metadata`；如果是用户消息，分三种情况处理身份快照（`userProfileId`/`userProfileName`/`userProfileIcon`）：

1. 源节点是开场白 → 原样复制 greeting 快照；
2. 源节点已有 `userProfileId`（历史消息本来就有身份快照）→ 原样复制，保证历史一致性；
3. 否则（旧数据没有身份快照）→ 用当前生效的用户档案重新计算一份快照，而不是留空。

创建完成后调用 `session.activeLeafId = newNode.id` 并 `updateSelectionMemory`，即"创建分支 = 立即切到新分支"。

### 4.3 重试 / 续写的节点语义

三种"再生成"路径底层都由 `useNodeManager` 提供节点级操作，`useChatHandler` 负责组装参数与调用执行链（执行链在对话请求与上下文 7）：

- **重新生成**：`useNodeManager.createRegenerateBranch(session, targetNodeId)`（`composables/session/useNodeManager.ts:221-312`）。如果目标是用户消息，直接以它为父节点新建一个空的 assistant 节点（新的回复分支）；如果目标是助手消息，先找到它的父节点（必须是 user 消息），然后同样在这个父节点下新建一个空 assistant 节点——也就是"重试"在树上表现为给同一个用户消息新增一个兄弟助手节点，原来的回复完整保留、只是不再是 `activeLeafId`。
- **续写**：`useNodeManager.createContinuationBranch()`（`useNodeManager.ts:319-384`）区分两种情况：对 assistant 节点续写，新建一个内容**等于原内容**、`metadata.isContinuation=true` 且记录 `continuationPrefix` 的兄弟节点（发送请求时用 `prefix: true` 让支持前缀续写的 API 从这段内容后继续）；对 user 节点续写，则是"角色接力"——新建一个空的子节点。`finalizeNode()`（`useChatResponseHandler.ts:490-501`）在写回最终内容时，如果 `metadata.isContinuation` 为真且返回内容未包含原 `continuationPrefix`，会手动把前缀拼回去，防止模型漏复述前缀导致内容断裂。

三类操作创建的新节点在完成前都先 `generatingNodes.add(id)`、再 `updateActiveLeaf`，最后才真正调用 `executeRequest`——这个顺序保证了 UI 能立刻看到"正在生成"的占位气泡，即使还没发出网络请求。

### 4.4 硬删除与压缩节点的特殊处理

`useNodeManager.hardDeleteNode()`（第 449-632 行）删除普通节点时，会递归收集其所有后代一并删除；删除"压缩节点"（`metadata.isCompressionNode`）时则只删除该节点，并把它的子节点重新挂接给父节点（"归还子节点"），不会级联删除后续对话。删除后如果 `activeLeafId` 落在被删集合里，会优先切到相邻兄弟节点最深的叶子，找不到才回退到父节点。删除前会用 `structuredClone(toRaw(node))` 做一份备份（用于历史记录/撤销）；克隆失败时降级为浅拷贝，不中断删除流程。压缩节点在树中的插入位置与上下文遮罩语义见对话请求与上下文附录 A.2。

### 4.5 树图嫁接的树不变量

树图视图的连线/嫁接操作（工作流见 Chat UI 1.4）在数据层拒绝自连、根节点、后代循环、预设节点和同父节点；`graftSubtree` 修饰键拖拽会嫁接整棵子树（`useGraphConnectionPreview.ts`/`useGraphNodeActions.ts`）。

## 5. 列表、索引与检索（数据侧）

### 5.1 跨会话全文搜索：全量扫描 + 正则预过滤

`useLlmSearch.ts` 前端封装了对 Tauri 命令 `search_llm_data_stream` 的调用（Channel 流式返回、300ms 防抖、支持"精确/全部/任一"三种匹配模式，`matchMode` 对应 exact/and/or）。真正的搜索逻辑在 Rust 端 `src-tauri/src/commands/llmchat_search.rs`：

- **没有任何持久化的搜索索引**。每次搜索都是 `WalkDir` 遍历 `llm-chat/sessions/` 与 `agent-manager/agents/` 目录下的全部文件（第398-412、526-542行：sessions 目录 `max_depth(1)` 找 `*.json`；Agent 搜索目录已随资产路径统一从 `llm-chat/agents/` 迁移到 `agent-manager/agents/`，`agent_search_result_path` 返回 `agent-manager/agents/{id}/agent.json`，非流式 `search_llm_data` 命令已删除，只剩流式版本），对每个文件异步 `fs::read_to_string` 读全文；
- 用一个正则（`SearchMatcher::is_match`，第276-282行）先对**整个文件原始文本**做一次快速预过滤（"如果全文都不包含关键词，直接跳过昂贵的 JSON 解析"，第419-422行注释原话），命中了才 `serde_json::from_str` 做部分反序列化（`PartialAgent`/`PartialSession` 只解析需要的字段，减少解析开销）；
- 并发度固定 `buffer_unordered(50)`（第520、619、929、1064行），流式版本额外做了取消令牌（`CancellationToken`）、结果数量上限的原子计数（`reserve_result_slot`，第80-94行，用 CAS 循环而不是锁）、以及按时间/数量批量推送结果（100ms 或 10 条一批，第1071-1074行）。

结论：这是一个**基于文件系统全量扫描 + 正则匹配的检索**（类似简化版 grep），不是倒排索引/全文索引方案。会话数量或单会话消息量很大时，每次搜索的成本随总数据量线性增长（虽有并发和取消机制缓解体感延迟，但计算量本身不会减少）。

### 5.2 命中定位：会话级 vs 活动路径内

后端只返回匹配的会话/Agent 级别的上下文片段（`MatchDetail.context` + 字符级 `match_offsets`，用于前端高亮，`extract_context_with_regex()` 第314-396行按 `graphemes` 计数保证多字节字符下标正确），**并不返回具体是哪个 `nodeId` 命中**——侧栏跨会话搜索命中后只能定位到会话本身，无法直接跳到会话内的具体消息。

会话内消息搜索（`ChatSearchPanel.vue`，与跨会话搜索是两套完全不同的实现）则是纯前端线性扫描：`searchResults` computed（第52-121行）直接从后往前遍历 `props.messages`（当前活动路径的消息数组），对每条消息的 `content + reasoningContent` 做 `toLowerCase().includes()` 判断，最多收集 50 条结果后 `break`。搜索范围只有当前活动路径，不在该路径上的分支节点既不会被搜索，也没有对应的消息 DOM。两套搜索能力不对等（详见第 9 节缺陷 4）。

### 5.3 会话列表数据侧

会话列表不分页：所有 `ChatSessionIndex` 一次性载入 store 的 `sessionIndexMap`，UI 层用 TanStack Virtual 只渲染可见项（Chat UI 2.1）。列表的排序/筛选/搜索联动由 `useSessionsSidebarLogic.ts` 承担（界面工作流见 Chat UI 2.1），数据侧的排序字段与增量更新机制本次未单独核实。

## 6. 缓存、一致性、多窗口与并发写入

- **运行态追踪是会话粒度的**：`sessionRuntimeManager.ts` 用两个全局响应式集合追踪生成态：`generatingNodes: Set<string>`（正在生成的节点 ID）和 `abortControllers: Map<string, AbortController>`。`isSessionGenerating(sessionId)` 通过遍历该会话所有节点、检查是否有节点 ID 落在 `generatingNodes` 里实现（第41-52行），不是简单的会话级布尔标记，因此天然支持"多个会话同时生成"而不互相影响。
- **索引与详情的一致性靠统一写入口维持**：所有会话修改经 manager 层，写盘时 `saveSession` 同步更新索引（2.1）；索引数值漂移由 `repairIndex` 后台自愈兜底（2.3）。
- **流式期间的节点 content 写入与跨窗口同步**属于执行层（对话请求与上下文 5）；分离窗口的同步总线与断连边界在 Chat UI 8.2。多进程/多端并发写入的合并策略本次未调查（未见相关机制，见第 10 节）。

## 7. 迁移、导入导出与保留策略

### 7.1 导出格式与范围语义

导出并非单一"保存聊天记录"（界面工作流见 Chat UI 6.4）：分支导出支持 Markdown、结构化 JSON 和保留原始节点字段的 Raw JSON，可选择消息范围以及是否包含预设、用户档案、Agent/模型信息、Token、附件和错误；启用"使用上下文管道处理"后，导出的是宏、世界书、知识库、变量替换和 Token 裁剪后的真实 Payload，此时手工范围和预设选项由管道接管。整会话导出支持树状 Markdown 和包含完整节点树的 JSON/Raw 形式，**能保留隐藏分支**，而不是只导出 `activeLeafId` 路径。

### 7.2 外部格式导入

SillyTavern 兼容：`sillyTavernParser.ts` 和 Agent 导入服务可解析 V2/V3 角色卡 JSON/PNG、提示词 `prompt_order` 和部分正则/宏；快捷操作导入还兼容 SillyTavern Quick Reply 格式（仅核实入口，未逐分支展开）。

### 7.3 schema 版本与数据库迁移

会话存储现已引入版本与损坏治理机制，不再是"无版本号"：

- 索引文件含 `version`（当前 `"1.1.2"`）与 `_persistence: { schema: 1, revision, committedAt }`（`types/persistence.ts`）；`loadIndex()` 对无法识别的版本返回 `unsupported` 状态；
- 损坏会话文件隔离到 `sessions-corrupt/` + `corruption-manifest.json`（version 1，`sessionPersistenceRepository.ts:234-286`），Rust 侧按 revision/tombstone 拒绝旧写；
- 持久化类型层（`types/persistence.ts`、`sessionPersistenceRepository.ts`、`sessionPersistenceCoordinator.ts`）配套单测覆盖原子写、恢复与损坏路径。

仍没有传统意义的数据库迁移脚本（JSON 文件格式，非 SQLite）。导入导出往返与备份恢复未做运行验证（见第 10 节）。

## 8. Agent、模型、知识库与附件绑定

### 8.1 Agent 绑定：创建时强绑定 vs 消息级快照

- 创建会话时必须传入 `agentId`（`useSessionManager.createSession(agentId, name?)`），若 `agentStore.getAgentById(agentId)` 找不到对应 Agent 会直接 `throw new Error`（`useSessionManager.ts:111-118`），不允许创建"无主"会话。
- `ChatSessionIndex.displayAgentId` 在创建时被设为该 `agentId`，但这个字段的语义并不是"会话永久绑定的 Agent"，而是**"当前活跃路径上最新一条助手消息使用的 agentId"**（类型定义里的注释，`types/session.ts:34-36`）。证据：`useSessionManager.updateSessionDisplayAgent()`（`useSessionManager.ts:61-94`）在每次生成/撤销/重做后被调用，逻辑是从 `activeLeafId` 向上遍历直到找到第一个带 `metadata.agentId` 的 assistant 节点，用它的 agentId 覆盖 `index.displayAgentId`。也就是说，**同一个会话里可以有多条消息使用不同的 Agent 生成**，`displayAgentId` 只是"给列表展示用的、跟随当前分支实时变化的快照"。
- 消息节点保存生成时快照 `metadata.agentId`/`agentName`/`agentIcon`（`useChatHandler.sendMessage()` 第237-252行发消息前写入，专门写了注释"防止 Agent 被删除后无法显示"），UI 上历史消息仍显示生成时用的 Agent 头像/名字。

结论：Agent 与会话的关系不是"创建时写死、之后不可变"的强绑定，而是"消息级快照 + 会话级实时展示指针"的组合，可以随时更换，且更换本身不影响历史消息已经记录的生成上下文。切换 Agent 的界面入口（`useLlmChatUiState().selectAgent`）在 Chat UI 4.1。

### 8.2 切换 Agent 的开场白替换条件

`switchAgentGreetings()`（`greetingService.ts:313-366`）：仅当会话根节点的子节点里没有非开场白节点（会话尚未真正开始）时，才会把旧 Agent 的 live greeting 节点整批删除、换成新 Agent 的开场白；否则静默跳过（3.3）。判定依据"根节点下是否存在非 greeting 节点"在数据异常时可能出现假阳性/假阴性（第 9 节潜在风险 5）。

### 8.3 附件：消息级绑定与两阶段导入

附件随用户消息节点绑定（发送时等待导入完成见对话请求与上下文 9.1）。导入侧是"立即预览 + 异步导入"两阶段（`composables/features/useAttachmentManager.ts`，`addAttachments()` 第547-621行）：先用 `createPendingAsset()`（第345-381行）快速读取文件元数据、检测 MIME/类型，生成 `importStatus: "pending"` 的占位 Asset 立即塞进 `attachments` 数组供 UI 展示缩略图；再异步调用 `assetManagerEngine.importAssetFromPathResult()` 真正导入（生成缩略图、SHA256 去重等），完成后用数组 `splice` 整体替换成正式 Asset 对象（保留 `uploadingId` 以便输入框里的占位符 UI 能对上号）。`checkModelCapability()`（第188-338行）在附件加入时同步检查当前 Agent/模型是否支持该附件类型（vision/audio/video/document 能力位），不支持时按"是否已开启多模态转写"决定是拦截还是仅警告——**没有能力信息的模型默认视为不支持**（"安全默认"，第235行注释）。预览与引用路径的渲染见消息渲染器笔记与 Chat UI 3.4。

### 8.4 用户档案快照

用户消息的身份快照（`userProfileId`/`userProfileName`/`userProfileIcon`）按 4.2 节三种情况处理：开场白复制 greeting 快照、已有快照原样复制、旧数据缺快照时用当前生效档案补算，保证分支复制时的历史一致性。

## 9. 设计取舍与已确认边界

以下结论按"已确认缺陷、设计取舍、静态推断"区分证据强度：

1. **崩溃残留 generating 节点：已修复**。旧结论（源调查）：`llmChatStore.ts` 里"自动修复僵死节点"的 watch（第115-198行）只在 `generatingNodes.value.size` 减少时触发，而应用重启后 `generatingNodes` 是全新的空 Set，加载路径又没有针对残留 generating 状态节点的检查或重置，节点会一直显示"正在生成"。提交 `5b5c55207`/`06427a464` 之后，加载路径新增 `repairInterruptedGeneratingNodes()`（`sessionLifecycleManager.ts:63-90`）：对每个 `status === "generating"` 的节点，有内容（非空字符串）标记为 `complete`、无内容标记为 `error` 并写入 `metadata.error: "生成意外中断"`，同时更新 `updatedAt` 并回写磁盘与索引；`loadSessions()` 与按需加载 `loadSessionDetail` 两条路径都会调用（`persistInterruptedGenerationRepair`）。僵死修复 watch 本身仍保留，且把 `waiting` 状态一并纳入检测范围（`llmChatStore.ts:139-150`）。修复行为为静态代码确认，未做崩溃-重启的运行复现。
2. **跨会话全文搜索没有索引**（推断，未实测）：纯目录扫描 + 正则预过滤（5.1），数据量增长后搜索延迟线性增长，虽有并发扫描（50 并发）和流式返回缓解体感，但没有做任何持久化索引或增量更新机制。
3. **撤销/重做栈不持久化**（设计取舍，非缺陷）：应用重启或切换会话重新加载详情后历史栈清空（2.2），"撤销"只在当前运行时会话内有效。
4. **两套搜索能力不对等**（已确认）：跨会话搜索（Rust 后端）能搜到所有会话但只能定位到会话级别；会话内搜索（`ChatSearchPanel.vue`）只能搜当前活动路径上、已经在 `props.messages` 数组里的消息，搜不到被分支切换隐藏的其它分支内容，也无法从跨会话搜索结果直接跳转到会话内的具体消息位置——中间缺一环。
5. **Agent 切换时的开场白替换判定比较脆弱**（潜在风险，未实测复现）：`switchAgentGreetings()` 判断"会话是否已经开始"的依据是"根节点的子节点里是否存在非 greeting 节点"（第323-327行）。如果由于某种数据异常（比如迁移、手动编辑导出的会话 JSON）导致根节点下混入了其它类型节点，这个判定可能出现假阳性/假阴性，但属于极端边界情况，正常操作路径下不会触发。
6. **ID 非 UUID**（潜在风险）：`sessionId`/`rootNodeId`/节点 ID 都用 `Date.now()`-random 拼接（`useSessionManager.ts:120-121`、`useNodeManager.ts:85-87`），正常单机使用碰撞概率极低，但严格来说不是强唯一性保证；未看到"多设备并发生成会话/节点后合并"的同步机制，若未来出现该场景存在理论碰撞风险。
7. **`getActivePath` 路径截断**（已确认边界）：`parentId` 指向不存在的节点时 `break` 并静默丢失更早的消息（1.2），属极端数据异常路径。

## 10. 未验证事项

- 大数据量下跨会话搜索的实际延迟未做压测（5.1 的线性增长结论是推断）。
- 崩溃-重启的加载期修复（`repairInterruptedGeneratingNodes`）、回收站删除、原子写的真实崩溃行为未做运行复现；导入导出往返、多窗口/多进程并发写入需要运行验证。
- 会话列表数据侧的排序字段与增量更新机制未单独核实（5.3）。
- 多设备并发生成/合并场景无同步机制，ID 碰撞风险仅理论推断。
- 消息编辑的数据层变更（`MessageMenubar` 的"编辑"入口）本次未展开，编辑如何修改节点对象未核实。

## 11. 关键源码索引

- `src/tools/llm-chat/types/session.ts`（`ChatSessionIndex`/`ChatSessionDetail`，22-110行）
- `src/tools/llm-chat/types/message.ts`（`ChatMessageNode` 及 metadata 字段，110-416行）
- `src/tools/llm-chat/types/history.ts`（撤销/重做数据结构）
- `src/tools/llm-chat/stores/llmChatStore.ts`（僵死节点修复 watch，115-198行）
- `src/tools/llm-chat/stores/session/sessionLifecycleManager.ts`（会话创建/删除/清理/索引修复，148-899行）
- `src/tools/llm-chat/stores/session/sessionHistoryManager.ts`、`sessionRuntimeManager.ts`、`sessionAccessManager.ts`（74-102行）、`sessionGenerationManager.ts`
- `src/tools/llm-chat/composables/session/useSessionManager.ts`（43-406行）、`useNodeManager.ts`（52-1153行）、`useBranchManager.ts`（31-431行）
- `src/tools/llm-chat/utils/BranchNavigator.ts`（25-254行）
- `src/tools/llm-chat/composables/storage/useChatStorageSeparated.ts`（94-733行）
- `src/tools/llm-chat/composables/features/useAttachmentManager.ts`（两阶段导入，101-793行）
- `src/tools/llm-chat/services/greetingService.ts`（开场白插入/固化/Agent 切换替换，106-366行）
- `src/tools/llm-chat/composables/chat/useLlmSearch.ts`（前端搜索封装，105-517行）
- `src/tools/llm-chat/components/search/ChatSearchPanel.vue`（会话内线性搜索，1-309行）
- `src-tauri/src/commands/llmchat_search.rs`（跨会话全文搜索，全文件）


