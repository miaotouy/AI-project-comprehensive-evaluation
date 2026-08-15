# AIO-Hub 会话与消息管理调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：直接阅读源码（Vue 组件、composable、store、Rust 后端命令）
>
> 调查范围：会话/消息/分支的数据模型、事实源与持久化、生命周期、消息操作与分支语义、列表索引与检索（数据侧）、缓存与一致性、迁移导入导出、外部对象绑定、恢复与保留语义；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

llm-chat 以"会话 = 树形消息结构 + 活动路径指针"为存储单位：

- 会话有轻量索引（`ChatSessionIndex`，列表展示）与重量详情（`ChatSessionDetail`，节点字典 + 分支指针 + 撤销栈）两层，**分文件存储**：一个 `sessions-index.json` 存放全部索引，每个会话的完整详情单独存成 `sessions/{sessionId}.json`。磁盘文件是权威源，前端 store 的 Map 只是工作副本；实际落盘统一走 Rust 原子写（临时文件 + fsync + 原子替换 + revision 校验 + 进程锁 + 备份轮换，细节见 2.1）。
- 消息是**树**（`parentId`/`childrenIds`/可选 `lastSelectedChildId`），`activeLeafId` 是当前显示路径的末端节点；线性对话列表只是消息树的一种视图。分支导航算法集中在 `utils/BranchNavigator.ts`（纯静态类）。
- **撤销/重做栈从不持久化**：写盘前剥离 `history`/`historyIndex`（`toStoredSession`），应用重启后历史栈清空——撤销只在单次会话运行期间有效（明确设计取舍）。
- 会话/节点 ID 用 `Date.now()`-随机后缀拼接，不是 UUID（理论碰撞风险，未见多设备同步机制）。
- 跨会话全文搜索**没有索引**：Rust 端每次都是目录全量扫描 + 正则预过滤 + 50 并发（`src-tauri/src/commands/llmchat_search.rs`），命中粒度只有会话级；会话内消息搜索是纯内存线性扫描当前活动路径，两套搜索能力不对等。
- 应用崩溃/强退后，"生成中"节点在加载时会被修复（有内容 → complete，无内容 → error），修复后回写磁盘；僵死修复 watch 仍在生成节点减少时兜底。

## 系统边界与数据主链

```text
useSessionManager.createSession（根节点 + 开场白 live greeting 节点）
  -> sessionLifecycleManager.createSession（写入 store Map + persistSession 落盘 + clearHistory）
  -> 消息操作经 useNodeManager / useBranchManager 修改 detail（分支、重试、续写、硬删除、编辑）
  -> 流式期间节点 content 经节流缓冲写回（执行语义在对话请求与上下文 5）
  -> saveSession 写盘：索引 sessions-index.json + 详情 sessions/{id}.json 分离，Rust 原子写
  -> loadSessions 启动恢复（当前会话详情 + 增量核对/损坏后台恢复）
  -> 检索：前端 useLlmSearch 调 Rust 命令，全目录扫描 + 正则预过滤
```

边界：生成任务如何读取/写回这些对象（上下文拼装、流式节流、压缩触发）在 [`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md)；界面动作的工作流与现场恢复在 [`<../Chat UI/AIO-Hub-ChatUI调查笔记.md>`](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)；消息与列表的绘制在 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)（已有独立笔记，内容渲染类内容一律链接过去，不复制）。

## 1. 会话、消息与分支数据模型

### 1.1 索引 / 详情分离

`ChatSessionIndex`（`types/session.ts:22-59`）是轻量索引，用于列表展示，关键字段包括：

- `id`/`name`：会话标识与标题；
- `displayAgentId`：当前活动路径最新助手消息所用的 agentId，用于列表头像展示；
- `messageCount`：缓存的有效消息数，排除根节点和未固化开场白（计算逻辑在 `utils/sessionMessageCount.ts:35-44`）；
- `createdAt`/`updatedAt`：创建与更新时间；
- `isFavorite`/`favoriteFolderId`：收藏，只活在索引里。

`ChatSessionDetail`（`types/session.ts:64-110`）是重量级详情，关键字段包括：

- `nodes: Record<string, ChatMessageNode>`：以 ID 为键的节点字典；
- `rootNodeId`：根节点 ID；
- `activeLeafId`：当前活跃分支的叶节点 ID；
- `parameterOverrides?`：会话级参数覆盖；
- `history`/`historyIndex`：撤销/重做栈，数据结构在 `types/history.ts`，Delta 型条目记录 create/delete/update/relation/active_leaf_change 五类变更。

会话单位只有 Session 一个概念。在 `src/tools/llm-chat` 的 types、stores、composables 中未找到 Thread/Topic/Conversation 等其他会话单位定义；`useTopicNamer` 的"主题命名"只是给会话生成 `name` 标题（`generateSessionTopic`，入口在 `sessionLifecycleManager.ts:956-1011`），不引入新的会话对象。

### 1.2 消息树：parentId / childrenIds / activeLeafId

`ChatMessageNode`（`types/message.ts:111-428`）：`parentId: string | null`（根节点为 null）、`childrenIds: string[]`（用于 O(1) 查找子节点，避免每次遍历全部节点）、可选的 `lastSelectedChildId`（记住上次在该节点下选择走的分支，用于"切走再切回"时恢复原位置）。

`activeLeafId` 存在于会话详情对象上。`getActivePath(sessionId)`（`stores/session/sessionAccessManager.ts:74-102`）从活动叶指针沿 `parentId` 一路向上走到根节点，翻转成正序数组后过滤掉根节点本身；若中途某个 `parentId` 指向的节点不存在，会记录警告并截断路径（不抛异常但静默丢失更早消息——见第 9 节）。

### 1.3 节点 metadata：状态字段与快照

正文仍是单一 `content: string`，富内容与状态放在 `metadata`（渲染层对 metadata 的读取见消息渲染器笔记 1.1）。各字段的取值与说明如下表：

| 字段 | 说明 |
|---|---|
| `status` | 节点生命周期状态，完整取值 `complete`/`generating`/`waiting`/`queued`/`error`；展示层映射在 `utils/messageStatus.ts`，旧数据 `pending` 兼容为 queued。 |
| `reasoningContent` + `reasoningArtifacts` | 用于精确回放 provider 自己维护的 reasoning 状态，另配 `reasoningStateStatus`（`"intact"`/`"broken"`，`types/message.ts:283-290`）；上下文压缩隐藏历史后 replay artifact 失效，压缩节点生成 `reasoningStateWarning`（执行侧见对话请求与上下文附录 A.2）。 |
| `translation` | 保存 `content`/`targetLang`/`modelIdentifier`/`timestamp`/`visible`/`displayMode` 及显示模式（`"original"`/`"translation"`/`"both"`，`types/message.ts:329-343`）；翻译的 LLM 调用在对话请求与上下文 9.7，界面入口在 Chat UI 6.1。 |
| `isQueued` | 排队等待生成的消息节点置 `true`（执行语义在对话请求与上下文 8）。 |
| Agent/模型快照 | 记录生成时的 `metadata.agentId`/`agentName`/`agentIcon` 及 `profileId`/`profileName`/`modelId`/`modelName`（写入点在 `useChatHandler.sendMessage()`，见第 8 节）。 |
| `isCompressionNode` | 压缩节点置 `true`，并记被遮罩 ID、原消息/Token 数等（见第 4.4 节与对话请求与上下文附录 A）。 |
| `sessionVariableSnapshot` | 含变量变更的消息记录会话变量快照，是分支级状态回放的起点（注入语义在对话请求与上下文 9.4）。 |
| `attachments` | 附件作为节点字段（`Asset[]`）随用户消息提交，两阶段导入状态机见第 8.3 节。 |

## 2. 事实源、索引与持久化

### 2.1 索引与详情分文件存储

存储采用"索引与详情分文件"策略：`sessions-index.json` 存放所有 `ChatSessionIndex`（含收藏夹），每个会话的完整 `ChatSessionDetail` 单独存成 `sessions/{sessionId}.json`。写入路径是"协调器 + 原生原子写"：

- `useChatStorageSeparated.ts` 是兼容门面（文件头注释自述 "Compatibility facade"，`:15-22`），所有写盘经会话持久化协调器（`services/sessionPersistenceCoordinator.ts:51-327`）合并：按会话/索引分槽、同一会话不允许并发写、写前在首个 await 之前同步捕获快照、失败按指数退避重试（100ms 起、上限 2 秒）、最多 4 个会话并发写；
- 实际落盘由 Rust 命令 `llm_chat_atomic_write`（`src-tauri/src/commands/llm_chat_persistence.rs:324-383`）完成：临时文件写盘 + fsync + 原子替换（Windows 用 `ReplaceFileW`），带 revision 校验（旧写返回 `staleRejected`，`:194-205`）、进程级文件锁（5 秒超时）、`.bak` 有效备份轮换（索引文件启用）；命令只接受白名单校验过的 llm-chat 会话标识，不接受任意文件路径；
- 每个会话文件与索引文件都写入 `_persistence: { schema: 1, revision, committedAt }` 元数据（`services/sessionPersistenceRepository.ts:58-60`），旧文件按 revision 0 兼容；
- 损坏会话文件被隔离到 `sessions-corrupt/` 并登记 `corruption-manifest.json`；索引损坏时保留损坏样本并回退 `.bak` 或最高 revision 的临时文件，加载结果区分正常、恢复、缺失、损坏、不兼容与 IO 错误六档（`sessionPersistenceRepository.ts:184-215,263-286`、`types/persistence.ts:69-75`）；
- 分离窗口（`/detached-component/`）禁止直写持久化，必须经主窗口代理（`useChatStorageSeparated.ts:109-127`；store 层转发点在 `llmChatStore.ts:379-389`）。

权威源：磁盘文件（含 revision 与 tombstone 约束）；内存 store 的 `sessionIndexMap`/`sessionDetailMap` 是运行时工作副本，启动时从磁盘载入，写盘由 manager 统一触发。

### 2.2 撤销/重做栈不持久化

写盘前 `toStoredSession()`（`useChatStorageSeparated.ts:89-105`）会剥离撤销栈字段（`history`/`historyIndex`）与只活在索引里的收藏字段，并补上持久化元数据——**撤销/重做栈从不持久化到磁盘**，应用重启后历史栈清空；加载或切换会话时，若详情缺少有效 history，`sessionLifecycleManager.ts` 会重新初始化撤销栈。这是一个明确的设计取舍：撤销/重做只在单次会话运行期间有效，不是跨会话持久功能。

### 2.3 索引恢复与自愈

`loadSessions()`（`sessionLifecycleManager.ts:663-730`）的恢复分两支：

- **索引损坏时的后台恢复**：发现索引状态为 `corrupt` 时调用 `startBackgroundIndexRecovery()`（`sessionLifecycleManager.ts:119-166`）——可取消、并发 4、逐批回填索引，并暴露恢复状态（正常/恢复中/损坏三档，`sessionRecovery`）给 LlmChat 工作台渲染恢复横幅（取消、打开损坏目录、导出诊断、删除隔离文件等入口见 Chat UI 1.1）；
- **正常启动的增量核对**：`reconcileIndexIncrementally()`（`useChatStorageSeparated.ts:514-581`）只拿目录文件名与索引比对，补新项、摘除文件缺失项（并发 4），不再解析每个会话文件，避免阻塞首屏；手动 `refreshSessionsIndex()` 仍走完整修复，带进度与失败计数（`useChatStorageSeparated.ts:584-686`）。

## 3. 创建、切换、归档、删除与恢复

### 3.1 创建会话

`useSessionManager().createSession(agentId, name?)`（`composables/session/useSessionManager.ts:100-179`）：

- 生成 `sessionId`/`rootNodeId`（`session-${Date.now()}-${random}` 格式，无强唯一性保证，靠时间戳+随机后缀降低碰撞概率，未见 UUID）；
- 创建 `role: "system"`、内容为空、`isEnabled: true` 的根节点（`useSessionManager.ts:126-135`）；
- 未指定 `name` 时默认名 `会话 ${当前时间}`；
- `index.displayAgentId = agentId`（创建时就绑定 Agent）；
- 调用 `insertLiveGreetings(index, detail, agent, effectiveUserProfile)`（`services/greetingService.ts:106-153`）：Agent 配置了开场白（greetings）时为每条开场白创建 `metadata.isGreeting=true, greetingLive=true` 的"活的"节点挂到根节点下，并把 `activeLeafId` 指向默认开场白（`agent.defaultGreetingId` 命中项，否则第一条）。

`sessionLifecycleManager.createSession()`（`stores/session/sessionLifecycleManager.ts:268-301`）在此基础上把 index/detail 写入 store 的 Map、设为当前会话、刷新消息计数并落盘，同时初始化撤销栈。

### 3.2 删除 / 批量删除 / 清理空会话 / 清空全部

- 单个删除 `deleteSession()`（`sessionLifecycleManager.ts:303-330`）：先经会话管理器计算新当前会话（若删的是当前会话，取列表中相邻的会话），再调用 Rust 删除命令（`llm_chat_persistence.rs:385-430`）：先写 tombstone（`sessions-tombstones/{id}.json`，revision 取封顶值），再把会话文件移入回收站目录 `sessions-trash/`（文件名带随机 UUID 后缀，避免与新建会话冲突）；随后清理运行时状态（中止控制器、正在生成节点、挂起的工具审批、撤销历史）与输入草稿，再切换到新当前会话并落盘；
- 批量删除 `batchDeleteSessions()`（`sessionLifecycleManager.ts:332-379`）：剩余会话按 `updatedAt` 倒序排列取第一个作为新当前会话；逐个删除文件、清理运行时和草稿；
- 清理空会话 `clearEmptySessions()`（`sessionLifecycleManager.ts:436-510`）：筛选出消息数为 0 的会话；若当前会话在被清理列表中，优先按调用方传入的当前展示顺序向前/向后找一个未被清理的邻居会话，找不到再退化为按更新时间倒序取第一个剩余会话。这个实现比"随便切一个"更细致，是为了避免清空后 UI 焦点跳到一个语义上不相关的会话；
- 清空全部会话 `clearAllSessions()`（`sessionLifecycleManager.ts:1023-1052`）：先经文件删除路径把索引与磁盘上已知的所有会话文件 tombstone/移入回收站（并发 4 的 worker 池），再发布空索引——代码注释明确：先关写路径，避免迟到的流式写盘"复活"已删文件。

本次检查范围（`src/tools/llm-chat` 目录内 grep `archiv`/`归档`）未发现会话级"归档"字段或机制：索引状态字段只有收藏，没有 `archivedAt` 类字段；架构文档 `docs/architecture/data-persistence.md:58` 中的"收藏夹归档"指的就是收藏夹功能本身。

### 3.3 改名与会话更新入口

`updateSession()`（`sessionLifecycleManager.ts:590-661`）是通用的会话更新入口，字段合并逻辑在 `useSessionManager.ts:241-286`（逐字段判断未传才写入，避免覆盖未传字段）。改名之外，传入新 `displayAgentId`（即切换会话绑定的 Agent）时会尝试切换开场白（`services/greetingService.ts:313-366`）：仅当会话根节点的子节点里没有非开场白节点（会话尚未真正开始）时，才把旧 Agent 的 live greeting 节点整批删除、换成新 Agent 的开场白；否则静默跳过（不报错，也不提示用户"切换未生效"）。该判定的边界风险见第 9 节潜在风险 5。

切换会话 `switchSession()`（`sessionLifecycleManager.ts:732-793`）：按需加载详情（已加载则复用）、历史栈无效时重新初始化、`refreshLiveGreetingsIfNeeded` 同步未固化的开场白（Agent 开场白配置变更后，在会话真正开始前重建 live greeting 节点），再更新当前会话指针并持久化。

### 3.4 恢复与保留语义

- 撤销/重做只在单次会话运行期间有效（2.2）。
- 应用重启后残留生成中节点会在加载时自动修复：修复入口对每个状态为 `generating` 的节点，有内容（非空字符串）标记为 `complete`、无内容标记为 `error` 并写入错误提示（"生成意外中断"），同时更新 `updatedAt`；随后刷新消息计数并回写磁盘与索引（`sessionLifecycleManager.ts:67-91、168-187`）。加载启动与按需加载详情两条路径都会调用。
- 索引损坏时先尝试 `.bak`/临时文件回退，失败则进入可取消的后台恢复并展示恢复横幅（2.3）；索引的 `messageCount`/`displayAgentId` 数值漂移在正常启动时不再全量修复，只有手动 `refreshSessionsIndex` 才完整重算。
- 删除的会话进入回收站目录（`sessions-trash/`）并留下 tombstone，但进程内没有任何回收站恢复入口（界面只有删除确认，无"恢复已删除会话"操作；本次未在 llm-chat 目录找到读取 `sessions-trash/` 的代码）。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 分支导航：BranchNavigator

`utils/BranchNavigator.ts` 是纯静态类，核心方法：

- `getSiblings(session, nodeId)`（`BranchNavigator.ts:29-57`）：通过父节点的 `childrenIds` 取兄弟列表；根节点没有父节点，视为"自己是唯一兄弟"。
- `switchToSibling(session, nodeId, direction)`（`BranchNavigator.ts:63-102`）：在兄弟列表里循环切换（切到最后一个再点"下一个"会绕回第一个），再用 `findLeafOfBranch` 找到目标兄弟分支下的叶子节点。
- `findLeafOfBranch(session, startNodeId)`（`BranchNavigator.ts:108-154`）：从起点沿子节点一路走到叶子，每一步优先用该节点的 `lastSelectedChildId`（若仍在其 `childrenIds` 中），否则退化为第一个子节点。这就是"记住上次看到哪条分支"的实现。
- `updateSelectionMemory(session, leafNodeId)`（`BranchNavigator.ts:160-201`）：从叶子回溯到根，把路径上每个父节点的 `lastSelectedChildId` 更新为路径中的下一个节点。所有会改变 `activeLeafId` 的操作（切换分支、创建分支、硬删除节点后重新定位）都会调用它，保证记忆链条一致。
- `ensureValidActiveLeaf(session)`（`BranchNavigator.ts:242-253`）：如果 `activeLeafId` 指向的节点已不存在，重置为 `rootNodeId`。只在撤销/重做后（`sessionHistoryManager.ts:60-77`）显式调用，其他修改路径（如普通删除）各自在内部处理相邻节点回退逻辑，并不统一走这个兜底。

界面上的分支按钮与 `n/total` 选择器在 Chat UI 6.2。

### 4.2 创建分支

`useBranchManager().createBranch(session, sourceNodeId)`（`composables/session/useBranchManager.ts:162-256`）：只允许对 user 或 assistant 角色的节点创建分支（预设消息不行）。实现是创建一个与源节点**同 `parentId`** 的新兄弟节点，复制 `content`/`attachments`；助手消息整份复制元数据，用户消息则分三种情况处理身份快照：

1. 源节点是开场白 → 原样复制 greeting 快照；
2. 源节点已有 `userProfileId`（历史消息本来就有身份快照）→ 原样复制，保证历史一致性；
3. 否则（旧数据没有身份快照）→ 用当前生效的用户档案重新计算一份快照，而不是留空。

创建完成后调用 `session.activeLeafId = newNode.id` 并 `updateSelectionMemory`，即"创建分支 = 立即切到新分支"。

### 4.3 重试 / 续写 / 编辑的节点语义

三种"再生成"路径底层都由 `useNodeManager` 提供节点级操作，`useChatHandler` 负责组装参数与调用执行链（执行链在对话请求与上下文 7）：

- **重新生成**：`useNodeManager.createRegenerateBranch(session, targetNodeId)`（`composables/session/useNodeManager.ts:221-312`）。如果目标是用户消息，直接以它为父节点新建一个空的 assistant 节点（新的回复分支）；如果目标是助手消息，先找到它的父节点（必须是 user 消息，否则拒绝），然后同样在这个父节点下新建一个空 assistant 节点——也就是"重试"在树上表现为给同一个用户消息新增一个兄弟助手节点，原来的回复完整保留、只是不再是 `activeLeafId`。
- **续写**：`useNodeManager.createContinuationBranch()`（`useNodeManager.ts:319-384`）区分两种情况：对 assistant 节点续写，新建一个内容**等于原内容**、带 `isContinuation` 标记并记录 `continuationPrefix` 的兄弟节点（发送请求时用前缀模式，让支持前缀续写的 API 从这段内容后继续）；对 user 节点续写，则是"角色接力"——新建一个空的子节点。写回最终内容时（`useChatResponseHandler.ts:490-501`），如果标记为续写且返回内容未包含原前缀，会手动把前缀拼回去，防止模型漏复述前缀导致内容断裂。
- **编辑**：`useBranchManager.editMessage()`（`useBranchManager.ts:108-156`）是原地修改：直接覆盖节点 `content`（及可选附件），只允许 user/assistant 角色，不创建新节点；编辑前的状态由撤销栈的 `NODE_EDIT` 条目承接。

"再生成"类操作创建的新节点在完成前都先 `generatingNodes.add(id)`、再 `updateActiveLeaf`，最后才真正调用 `executeRequest`——这个顺序保证了 UI 能立刻看到"正在生成"的占位气泡，即使还没发出网络请求。

### 4.4 硬删除与压缩节点的特殊处理

删除普通节点时（`useNodeManager.hardDeleteNode()`，`useNodeManager.ts:449-632`），会递归收集其所有后代一并删除；删除"压缩节点"（`metadata.isCompressionNode` 标记）时则只删除该节点，并把它的子节点重新挂接给父节点（"归还子节点"，`useNodeManager.ts:489-515`），不会级联删除后续对话。删除后如果活动叶指针落在被删集合里，会优先切到相邻兄弟节点最深的叶子，找不到才回退到父节点。删除前会用 `structuredClone` 对节点做一份备份（用于历史记录/撤销）；克隆失败时降级为浅拷贝，不中断删除流程。压缩节点在树中的插入位置与上下文遮罩语义见对话请求与上下文附录 A.2。

### 4.5 树图嫁接的树不变量

树图视图的连线/嫁接操作（工作流见 Chat UI 1.4）在预览层拒绝自连、`preset-` 前缀节点、根节点、后代循环和同父节点（`useGraphConnectionPreview.ts:60-90`）；通过预检后按修饰键调用数据层的整棵子树移动或单点移动（子节点交旧父收养，`useNodeManager.ts:876-986、992-1077`），数据层同样拒绝根节点、自挂与循环。

## 5. 列表、索引与检索（数据侧）

### 5.1 跨会话全文搜索：全量扫描 + 正则预过滤

`useLlmSearch.ts` 前端封装了对 Rust 流式搜索命令的调用（Channel 流式返回、300ms 防抖、支持"精确/全部/任一"三种匹配模式，`useLlmSearch.ts:272-301`；取消入口在 `useLlmSearch.ts:172-179`）。真正的搜索逻辑在 Rust 端 `src-tauri/src/commands/llmchat_search.rs`（当前 HEAD 仅注册流式搜索与取消两个命令，非流式搜索命令已删除，注册点在 `src-tauri/src/commands.rs:357-358`）：

- **没有任何持久化的搜索索引**。每次搜索都是遍历 `llm-chat/sessions/` 与 `agent-manager/agents/` 目录下的全部文件（会话任务只找 `*.json`，Agent 任务找 `agent.json`，返回各自的完整路径，`llmchat_search.rs:44-46,485-492,647-656`），对每个文件异步读全文；
- 用一个正则（`SearchMatcher::is_match`，`llmchat_search.rs:293-298`）先对**整个文件原始文本**做一次快速预过滤（不命中直接跳过，不做 JSON 解析），命中了才做部分反序列化（`PartialAgent`/`PartialSession` 只解析需要的字段，减少解析开销）；
- 并发度固定为 50（`llmchat_search.rs:633,768`），流式版本额外做了取消令牌、结果数量上限的原子计数（CAS 循环而不是锁，`llmchat_search.rs:96-110`）以及按时间/数量批量推送结果（100ms 或 10 条一批，`llmchat_search.rs:775-778`）；前端对收到的批次按匹配数降序 + 更新时间合并排序（`useLlmSearch.ts:219-227`）。

结论：这是一个**基于文件系统全量扫描 + 正则匹配的检索**（类似简化版 grep），不是倒排索引/全文索引方案。会话数量或单会话消息量很大时，每次搜索的成本随总数据量线性增长（虽有并发和取消机制缓解体感延迟，但计算量本身不会减少）。

### 5.2 命中定位：会话级 vs 活动路径内

后端只返回匹配的会话/Agent 级别的上下文片段（`MatchDetail.context` + 字符级 `match_offsets`，用于前端高亮，`extract_context_with_regex()` 在 `llmchat_search.rs:330-412`，按 `graphemes` 计数保证多字节字符下标正确），**并不返回具体是哪个节点命中**——侧栏跨会话搜索命中后只能定位到会话本身，无法直接跳到会话内的具体消息。

会话内消息搜索（`ChatSearchPanel.vue`，与跨会话搜索是两套完全不同的实现）则是纯前端线性扫描：`searchResults` computed（`ChatSearchPanel.vue:52-121`）直接从后往前遍历当前活动路径的消息数组，对每条消息的文本内容（含 reasoning）做小写不敏感包含判断，最多收集 50 条结果后停止，另有角色筛选。搜索范围只有当前活动路径，不在该路径上的分支节点既不会被搜索，也没有对应的消息 DOM。两套搜索能力不对等（详见第 9 节缺陷 4）。

### 5.3 会话列表数据侧

会话列表不分页：所有 `ChatSessionIndex` 一次性载入 store 的 `sessionIndexMap`，UI 层用 TanStack Virtual 只渲染可见项（Chat UI 2.1）。排序与筛选逻辑在 `useSessionsSidebarLogic.ts`：

- 排序字段为 `updatedAt`/`createdAt`/`messageCount`/`name`（`:173-194`）；
- 筛选支持按 Agent（`displayAgentId`）、时间区间（today/week/month/older）与收藏状态（`:127-171`）；
- 搜索命中时列表由后端结果驱动，搜索中且尚无结果时回退显示本地筛选列表（`:222-230`）。

## 6. 缓存、一致性、多窗口与并发写入

- **运行态追踪是会话粒度的**：`sessionRuntimeManager.ts` 用两个全局响应式集合追踪生成态——正在生成的节点 ID 集合与中止控制器表。生成判定通过遍历该会话所有节点、检查是否有节点 ID 落在集合里实现（`sessionRuntimeManager.ts:38-49`），不是简单的会话级布尔标记，因此天然支持"多个会话同时生成"而不互相影响。
- **索引与详情的一致性靠统一写入口维持**：所有会话修改经 manager 层，写盘时同步更新索引项并标记两个槽位为脏（`useChatStorageSeparated.ts:350-377`）；revision 递增校验在 Rust 侧拒绝旧写；索引数值漂移由后台修复兜底（2.3）。
- **流式期间的节点 content 写入与跨窗口同步**属于执行层（对话请求与上下文 5）；分离窗口的同步总线与断连边界在 Chat UI 8.2。多进程/多端并发写入的合并策略本次未调查（未见相关机制，见第 10 节）：单进程内由协调器分槽 + Rust 进程锁保证串行，跨进程场景（如同时开两个应用实例）只有文件锁与 revision 防线，未发现合并/冲突 UI。

## 7. 迁移、导入导出与保留策略

### 7.1 导出格式与范围语义

导出并非单一"保存聊天记录"（界面工作流见 Chat UI 6.4）。分支导出支持三种格式（Markdown、结构化 JSON、保留原始节点字段的 Raw JSON），入口在 `useExportManager.ts:229,607,1078`，可选择消息范围以及是否包含预设、用户档案、Agent/模型信息、Token、附件和错误（选项面板在 `ExportBranchDialog.vue:74-88`）；启用"使用上下文管道处理"后（`ExportBranchDialog.vue:191`），导出的是宏、世界书、知识库、变量替换和 Token 裁剪后的真实 Payload（从 `:311` 起走上下文预览），此时手工范围和预设选项由管道接管。

整会话导出（`exportSessionAsMarkdownTree`，`useExportManager.ts:849`）支持树状 Markdown 和包含完整节点树的 JSON/Raw 形式，**能保留隐藏分支**，而不是只导出 `activeLeafId` 路径。

### 7.2 外部格式导入

SillyTavern 兼容：`services/sillyTavernParser.ts` 可解析 V2/V3 角色卡 JSON/PNG（V3 内嵌 character_book 世界书）、提示词文件与部分正则/宏，各解析入口见下列清单；会话导入的冲突策略 `keep/overwrite/skip`，重命名与冲突处理在 `services/sessionImportExportService.ts`（`:203`，策略定义 `:26`）。

- `parseCharacterCard`（V2/V3 角色卡 JSON/PNG）：`sillyTavernParser.ts:192`；V3 内嵌 character_book 世界书：`:78`
- `parsePromptFile`（提示词文件，含 `prompt_order`）：`sillyTavernParser.ts:355`、`:99`
- `convertMacros`（部分正则/宏）：`sillyTavernParser.ts:128`

快捷操作导入还兼容 SillyTavern Quick Reply 格式（`services/quickActionImportService.ts`，本次仅核实入口，未逐分支展开）。

### 7.3 schema 版本与数据库迁移

会话存储已引入版本与损坏治理机制：

- 索引文件含 `version`（当前 `"1.1.2"`，`useChatStorageSeparated.ts:54`）与 `_persistence: { schema: 1, revision, committedAt }`（`types/persistence.ts:17-21`）；无法识别的版本会被拒绝加载；
- 损坏会话文件隔离到 `sessions-corrupt/` + `corruption-manifest.json`（version 1，`sessionPersistenceRepository.ts:234-286`），Rust 侧按 revision/tombstone 拒绝旧写；
- 持久化类型层（`sessionPersistenceRepository.ts`、`sessionPersistenceCoordinator.ts`）配套单测覆盖原子写、恢复与损坏路径（Rust 侧 `llm_chat_persistence.rs:432-490` 亦有单测）。

仍没有传统意义的数据库迁移脚本（JSON 文件格式，非 SQLite）。导入导出往返与备份恢复未做运行验证（见第 10 节）。

## 8. Agent、模型、知识库与附件绑定

### 8.1 Agent 绑定：创建时强绑定 vs 消息级快照

- 创建会话时必须传入 `agentId`，若在 agent store 中找不到对应 Agent 会直接抛错（`useSessionManager.ts:110-119`），不允许创建"无主"会话。
- `displayAgentId` 在创建时被设为该 `agentId`，但这个字段的语义并不是"会话永久绑定的 Agent"，而是**"当前活跃路径上最新一条助手消息使用的 agentId"**（类型定义里的注释，`types/session.ts:33-36`）。证据：每次生成/撤销/重做后，会从活动路径末端向上遍历，找到第一个带 agentId 快照的助手消息并覆盖该字段（`useSessionManager.ts:62-95`）。也就是说，**同一个会话里可以有多条消息使用不同的 Agent 生成**，该字段只是给列表展示用的、跟随当前分支实时变化的快照。
- 消息节点保存生成时快照：`metadata.agentId`/`agentName`/`agentIcon`/`agentDisplayName`（发送入口在发消息前写入，`useChatHandler.ts:395-409`），UI 上历史消息仍显示生成时用的 Agent 头像/名字。

结论：Agent 与会话的关系不是"创建时写死、之后不可变"的强绑定，而是"消息级快照 + 会话级实时展示指针"的组合，可以随时更换，且更换本身不影响历史消息已经记录的生成上下文。切换 Agent 的界面入口（`useLlmChatUiState().selectAgent`）在 Chat UI 4.1。

### 8.2 切换 Agent 的开场白替换条件

`switchAgentGreetings()`（`greetingService.ts:313-366`）：仅当会话根节点的子节点里没有非开场白节点（会话尚未真正开始）时，才会把旧 Agent 的 live greeting 节点整批删除、换成新 Agent 的开场白；否则静默跳过（3.3）。判定依据"根节点下是否存在非 greeting 节点"在数据异常时可能出现假阳性/假阴性（第 9 节潜在风险 5）。另一条路径 `refreshLiveGreetingsIfNeeded`（`greetingService.ts:242-304`）在切换会话时核对 Agent 开场白配置（数量、内容、角色、附件、快照字段），不一致则重建。

### 8.3 附件：消息级绑定与两阶段导入

附件随用户消息节点绑定（发送时等待导入完成见对话请求与上下文 9.1）。导入侧是"立即预览 + 异步导入"两阶段（`composables/features/useAttachmentManager.ts`）：先用 `createPendingAsset()`（`:345`）快速读取文件元数据、检测 MIME/类型，生成 `importStatus: "pending"` 的占位 Asset 立即塞进附件数组供 UI 展示缩略图；再异步调用真正导入（生成缩略图、SHA256 去重等），完成后替换成正式 Asset 对象。`checkModelCapability()` 在附件加入时同步检查当前 Agent/模型是否支持该附件类型（vision/audio/video/document 能力位），不支持时按"是否已开启多模态转写"决定是拦截还是仅警告——**没有能力信息的模型默认视为不支持**（"安全默认"注释）。预览与引用路径的渲染见消息渲染器笔记与 Chat UI 3.4。

### 8.4 用户档案与模型快照

用户消息的身份快照（`userProfileId`/`userProfileName`/`userProfileIcon`，另有显示名字段）按 4.2 节三种情况处理：开场白复制 greeting 快照、已有快照原样复制、旧数据缺快照时用当前生效档案补算，保证分支复制时的历史一致性。助手消息同时记录 profile 与 model 快照（`useChatHandler.ts:395-409`、`useChatExecutor.ts:138-145`），"切换模型重新生成"等操作按消息快照回显目标模型。

## 9. 设计取舍与已确认边界

以下结论按"已确认缺陷、设计取舍、静态推断"区分证据强度：

1. **崩溃残留 generating 节点：加载期已修复**。修复机制见 3.4（`sessionLifecycleManager.ts:67-91、168-187`）。僵死修复 watch 本身仍保留，且把 `waiting` 状态一并纳入检测范围（`llmChatStore.ts:129-207`，检测条件在 `llmChatStore.ts:140-144`）。修复行为为静态代码确认，未做崩溃-重启的运行复现。
2. **跨会话全文搜索没有索引**（推断，未实测）：纯目录扫描 + 正则预过滤（5.1），数据量增长后搜索延迟线性增长，虽有并发扫描（50 并发）和流式返回缓解体感，但没有做任何持久化索引或增量更新机制。
3. **撤销/重做栈不持久化**（设计取舍，非缺陷）：应用重启或切换会话重新加载详情后历史栈清空（2.2），"撤销"只在当前运行时会话内有效。
4. **两套搜索能力不对等**（已确认）：跨会话搜索（Rust 后端）能搜到所有会话但只能定位到会话级别；会话内搜索（`ChatSearchPanel.vue`）只能搜当前活动路径上、已经在 `props.messages` 数组里的消息，搜不到被分支切换隐藏的其它分支内容，也无法从跨会话搜索结果直接跳转到会话内的具体消息位置——中间缺一环。
5. **Agent 切换时的开场白替换判定比较脆弱**（潜在风险，未实测复现）：`switchAgentGreetings()` 判断"会话是否已经开始"的依据是"根节点的子节点里是否存在非 greeting 节点"（`greetingService.ts:323-327`）。如果由于某种数据异常（比如导入、手动编辑导出的会话 JSON）导致根节点下混入了其它类型节点，这个判定可能出现假阳性/假阴性，但属于极端边界情况，正常操作路径下不会触发。
6. **ID 非 UUID**（潜在风险）：`sessionId`/`rootNodeId`/节点 ID 都用 `Date.now()`-随机后缀拼接（`useSessionManager.ts:121-122`、`useNodeManager.ts:85-87`），正常单机使用碰撞概率极低，但严格来说不是强唯一性保证；未看到"多设备并发生成会话/节点后合并"的同步机制，若未来出现该场景存在理论碰撞风险。
7. **`getActivePath` 路径截断**（已确认边界）：`parentId` 指向不存在的节点时 `break` 并静默丢失更早的消息（1.2），属极端数据异常路径。
8. **回收站无恢复入口**（已确认边界）：删除走 `sessions-trash/` + tombstone，但 `src/tools/llm-chat` 内没有读取回收站目录的代码，删除不可逆（3.4）。

## 10. 未验证事项

- 大数据量下跨会话搜索的实际延迟未做压测（5.1 的线性增长结论是推断）。
- 崩溃-重启的加载期修复（`repairInterruptedGeneratingNodes`）、回收站删除、原子写的真实崩溃行为未做运行复现；导入导出往返、多窗口/多进程并发写入需要运行验证。
- 多设备并发生成/合并场景无同步机制，ID 碰撞风险仅理论推断。
- 跨进程双实例并发写（文件锁 + revision 防线之外）的实际表现未验证。

## 11. 关键源码索引

- `src/tools/llm-chat/types/session.ts`（`ChatSessionIndex`/`ChatSessionDetail`，22-110行）、`types/message.ts`（`ChatMessageNode` 及 metadata 字段，111-428行）、`types/history.ts`、`types/persistence.ts`
- `src/tools/llm-chat/stores/session/sessionLifecycleManager.ts`（创建/删除/清理/切换/索引恢复）、`sessionAccessManager.ts`（74-102行 `getActivePath`）、`sessionRuntimeManager.ts`、`sessionHistoryManager.ts`
- `src/tools/llm-chat/composables/session/useSessionManager.ts`、`useNodeManager.ts`、`useBranchManager.ts`
- `src/tools/llm-chat/utils/BranchNavigator.ts`、`utils/sessionMessageCount.ts`
- `src/tools/llm-chat/composables/storage/useChatStorageSeparated.ts`、`services/sessionPersistenceCoordinator.ts`、`services/sessionPersistenceRepository.ts`
- `src-tauri/src/commands/llm_chat_persistence.rs`（原子写/删除/回收站/tombstone）、`src-tauri/src/commands/llmchat_search.rs`（跨会话全文搜索）
- `src/tools/llm-chat/composables/features/useAttachmentManager.ts`、`services/greetingService.ts`、`services/sessionImportExportService.ts`、`services/sillyTavernParser.ts`、`composables/features/useExportManager.ts`
- `src/tools/llm-chat/composables/chat/useLlmSearch.ts`、`components/search/ChatSearchPanel.vue`、`composables/sidebar/useSessionsSidebarLogic.ts`


