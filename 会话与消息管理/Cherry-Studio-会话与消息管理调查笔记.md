# Cherry Studio 会话与消息管理调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：直接阅读源码（主进程 SQLite 数据层 `TopicService`/`MessageService`、schema 与 FTS 触发器、`docs/references/chat/message-tree.md` 文档、渲染层 DataApi 分页与搜索实现），并核对行号与符号至当前 HEAD
>
> 调查范围：Topic/Session/Message 数据模型、事实源与持久化、生命周期、分支语义、分页索引与搜索、恢复与保留语义；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **会话单位是 Topic**（`src/shared/data/types/topic.ts`），存储在 SQLite，由 `TopicService`（`src/main/data/services/TopicService.ts`）管理 CRUD。
- **消息不是线性数组，而是 adjacency-list 树**（`message.parentId` 自引用外键，`ON DELETE CASCADE`），由 `MessageService`（`src/main/data/services/MessageService.ts`）维护；`docs/references/chat/message-tree.md` 是这棵树的权威文档——本次核实文档与当前代码一致（虚拟根、awaiting-input 分支、删除语义、consumer contract 均与实现对应）。
- 新建 Topic 的同一写事务里就会创建一条虚拟根消息（`createRootMessageTx`），不存在"没有根消息的 Topic"这种中间态；"空 Topic"是运行时按消息条数判定的，与虚拟根是否存在无关。
- **"切换分支"不是重排树**，而是把 `activeNodeId` 指针指到目标分支的叶子；前端看到的"当前分支的完整对话"每次从 `activeNodeId` 反向 walk 到根（`getPathRowsToNodeTx`，虚拟根被排除）。
- 分支草稿是**持久化空叶子**：`POST /messages/:id/branches` 落一条空的 successful user 行（`reserveBranch`），等待输入状态由结构派生（`isBlankUserTurn`），不依赖渲染层假节点；只有流式增量仍是不落库的纯前端 overlay。
- **搜索分两条路**：会话内搜索是"已加载数据粗匹配 + 已挂载 DOM 精确 Range"混合（`MessageListSearch`，`a012837e5c` 起支持虚拟化窗口外的消息定位）；跨会话全局搜索走**持久化 FTS5 全文索引**（`message_fts` 外部内容表 + `searchableText` 触发器维护），不是 DOM 搜索。旧结论"消息搜索没有持久化全文索引"已过时，需要按这两条路分别描述。
- **崩溃恢复有明确机制**：主进程启动时把上次崩溃遗留的 `pending` assistant 行统一翻为 `error`（boot reconcile），避免 UI 永久停留在"思考中"。
- 删除 Topic 不主动清理磁盘附件文件，但内部附件经 `chat_message_file_ref` 引用计数，FileManager 有策略化条目回收（`delete_when_unreferenced` 宽限期扫描 + 孤儿条目扫描），不是无主泄漏。

## 系统边界与数据主链

```text
写操作（ChatWriteActions / DataApi IPC）
  -> TopicService / MessageService（SQLite 写事务，权威源）
  -> 读侧：DataApi 分页拉取 /topics/:topicId/messages（SWR 缓存是投影）
  -> execution overlay（流式增量，不落库）
  -> useStableMessagePartsLayers 合并（渲染细节见消息渲染器笔记）
```

边界：请求开始前读取哪些持久化对象、结束后写回哪些对象（锚点路径取历史、占位消息落库）在本类目只记录交接点，拼装与执行在对话请求与上下文（`../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md`）；分支面板树图、兄弟导航、搜索工作流等界面呈现与操作在 `<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>`；消息 part 的持久化形状、虚拟列表与内容组件装配在消息渲染器（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`）。

## 1. 会话、消息与分支数据模型

### 1.1 Topic：会话单位

会话单位是 Topic（`src/shared/data/types/topic.ts:23-42`，`TopicSchema`）。topic 行除时间戳外还携带下列字段（表结构见 `src/main/data/db/schemas/topic.ts:11-36`）：

- `id`/`name`、`isNameManuallyEdited`：名称与自动命名开关（见 3.2）；
- `assistantId`："上次使用的助手"引用，助手删除时 `SET NULL`；
- `activeNodeId`：活动分支指针（见 4.2）；
- `traceId`：容器级 OTel trace；
- `orderKey`：全局 fractional-indexing 排序键。

- 置顶不在 topic 表上：v2 迁移已移除 `isPinned`/`pinnedOrder`，置顶改为多态 `pin` 表（`entityType='topic'`，唯一约束 `UNIQUE(entityType, entityId)`），由 `PinService` 维护（`src/main/data/services/PinService.ts:51-89`）；列表按"置顶段 + 普通段"两段分页（见 5 节）。
- "空 Topic 判定"不是字段，而是运行时按消息条数判定（见 3.4）。

**"是否为第一轮对话"的唯一权威判据是 `rootId`**：`getBranchMessages`/`getTree` 每页响应都携带虚拟根 id，`message.parentId === rootId` 即第一轮（`MessageService.ts:655-663`）；`message-tree.md:116-122` 显式警告不要用"parent 不在已加载列表里"或 v1 遗留的 `askId` 去猜。

### 1.2 消息树：adjacency-list 树，由数据库约束强制

- 每条消息一行，`parentId` 自引用外键（`ON DELETE CASCADE`，`src/main/data/db/schemas/message.ts:59`）；`siblingsGroupId`（非零）标记同一 parent 下的多模型/多分支兄弟组（`message-tree.md:14-15,22`）。
- 每个 topic 恰好一条内容为空的虚拟根（`role='root'`，`parentId=NULL`，`data={parts:[]}`）。这是存储层不变量，不是应用层约定，由 schema 强制（`message.ts:70-83`）：
  - 唯一索引 `message_topic_root_uniq` 强制"每 topic 至多一条 live 根"（`:70-72`）；
  - CHECK 约束 `message_root_parent_check` 强制 `(role='root') = (parentId IS NULL)`（`:83`）；
  - role/status 各有 CHECK（`:78-79`）。
- 虚拟根永不出现在 `getBranchMessages`/`getTree`/`getPathRowsToNodeTx` 的返回里：前者对空结果直接返回（`MessageService.ts:419-421,522-524`），后者在返回前把根从链上摘掉（`:1925-1929`）。
- **持久化形状**：数据库直接存储 AI SDK 的 `UIMessage.parts`（`data` JSON 列，`message.ts:30`），传输、持久化和渲染共享同一种结构；part 类型清单、`providerMetadata.cherry` 扩展与访问器见消息渲染器笔记"消息数据模型"一节。
- 附加字段（schema 见 `message.ts:41-53`）：`searchableText`（FTS 用，触发器填充，见 2 节）、`ftsRowid`（FTS 稳定外键）、`messageSnapshot`（模型快照）、`stats`（用量统计）、`compactionSummary`（持久化压缩标记）。
- 树相关服务方法（均在 `MessageService` 中）：
  - `getTree`（`:348-622`）：CTE 求活动路径 + 深度限制子树 + 活动路径补全，是分支图数据源；`messageToTreeNode`（`:286-310`）由"空 successful user 叶子且无子节点"派生 `isAwaitingInput`（`:300-303`）。
  - `getBranchMessages`（`:641-768`）：before-cursor 分页，见 5 节。
  - `getPathToNode`（`:1874-1878`）/`getPathRowsToNodeTx`（`:1885-1930`）：节点到根的反向路径。
  - `getPathThrough`（`:2019-2052`）：求经过某节点的分支的最新叶子，供分支导航。
- 约束在 `MessageService` 里的具体落地：
  - `delete()`（`:1650-1748`）对虚拟根直接抛 `INVALID_OPERATION`（`:1675-1677`）；非 cascade 删除先把子节点 reparent 到祖父节点再删本节点（`:1709-1724`，`reparentChildrenTx` `:1763-1810` 会给被移动的兄弟组重分配组号，避免与目标父节点下既有组碰撞）；首轮消息可正常删除（子节点挂回虚拟根）。
  - `deleteReplyGroup`（`:1538-1625`）只删同组 assistant 兄弟并把各组直接子节点 reparent 到共享用户消息下；组内任一回复 `pending` 时拒绝删除（`:1586-1588`）。
  - `clearTopicMessages`（`:1822-1843`）清空一个 topic 的所有内容消息，但保留虚拟根并清 `activeNodeId`。

## 2. 事实源、索引与持久化

- **权威源是 SQLite**：主进程 `TopicService`/`MessageService` 负责全部 CRUD；renderer 读侧经 DataApi 分页接口，SWR 缓存是缓存投影，不是权威源（`useTopicMessages.ts` 的 projection 用 WeakMap 保持同一行消息的投影身份稳定，`:243-247,305-320`）。
- **活动路径事实源在 topic 行**：`activeNodeId` 由 `setActiveNodeTx`（`TopicService.ts:371-407`）写入，唯一校验是目标消息属于该 topic、且不是虚拟根（`:372-398`，`:392-397` 显式拒绝 root）。
- **流式增量 overlay 不落库**：overlay 是窗口级服务 `ExecutionStreamOverlayService`（`src/renderer/services/aiTransport/ExecutionStreamOverlayService.ts`），按 transport `topicId` 引用计数，并在 rAF 周期批量提交：
  - 生命周期：`acquire` `:221`、`release` `:230`、`syncExecutions` `:249`、批量提交 `:609`；
  - React 绑定：`useExecutionOverlay.ts` 只做 `useSyncExternalStore`（`:54-78`），组件卸载不拆 reader——路由/标签页切换期间 Main 继续生成，重挂载同步恢复 live overlay；
  - reader 种子（seed）来自当前 DB 行的深拷贝（`structuredClone`，`:143`），避免写脏 SWR 缓存。
- **分支草稿/发送锚点已是持久化行**：锚点是持久化的空 user 叶子，创建、填充、删除都有服务端守卫，渲染层只负责发起请求：
  - **创建**：`MessageService.reserveBranch(anchorId, activate)`（`MessageService.ts:1099-1134`）要求 anchor 必须是 assistant 消息（`:1110-1112`），在其下插一条 `role='user'`、`data.parts=[]`、`status='success'` 的空叶子；重复调用同一 anchor 每次都新建行（有意的分支点），`activate=false` 用于流式期间不挪动 active 指针（`:1127-1129`）；
  - **等待输入状态**：由结构派生（`isBlankUserTurn`，`src/shared/data/types/uiParts.ts:367-373`），不落任何 draft 标记；
  - **删除/填充守卫**：`DELETE /messages/:id?awaitingInputOnly=true` 复核目标仍是空叶子（`MessageService.ts:1679-1684`，判定 `isAwaitingInputLeaf` `:1311-1320`）；`createUserMessageWithPlaceholders` 的 `fill-reserved` 模式在同一事务里填充该行并建 assistant 占位（`:1218-1251`，填充前再校验 `:1233-1238`）；
  - **竞态兜底**：主进程 `PersistentChatContextProvider` 在流式进行时拒绝 reserved-branch 提交（`PersistentChatContextProvider.ts:247-253`，错误原文见 `:252`）；
  - **渲染侧入口**：`useTopicBranchActions`（路径见文末索引）的 `reserveBranch`（`:18-31`）发 `POST /messages/:id/branches`、`deleteReservedBranch`（`:33-40`）发删除请求；`Chat.tsx` 旧的 `branchDraftAnchorIdRef`/`branchSendAnchorOverrideIdRef` 三态 ref 已删除。
- **分支图/列表的合并方向**：`topicMessageFlowLiveTree.ts` 的合并函数只叠加"流式中尚未持久化的消息"临时节点；awaiting-input 叶子本身是 DB 节点，直接进 `/topics/:id/tree` 结果（`TreeNode.isAwaitingInput`，`MessageService.ts:300-303`）——分支图 = 持久化树（含空分支叶子）+ 流式 overlay，不再有"假草稿节点"。
- **FTS 全文索引（跨会话内容搜索）**：持久化全文索引，由触发器随消息行维护，分三层：
  - **文本抽取**：`message.searchableText` 由 SQLite 触发器从 `data.parts` 抽取下列五类 part 的文本内容（`message.ts:112-146`）：
    ```text
    text / data-code / data-translation / data-compact / data-error
    ```
  - **索引与同步**：`message_fts` 是 external-content FTS5 表（trigram 分词，键在 `ftsRowid`，`message.ts:148-158`），`message_ai`/`message_ad`/`message_au` 三个触发器在 INSERT/DELETE/UPDATE OF data 时同步（`message.ts:170-194`）；
  - **查询与分发**：`MessageService.search`（`:825-889`）JOIN `message_fts`、过滤 `searchable_text != ''`、cursor 分页；agent 会话有同构的 `agent_session_message_fts`。FTS 与行同步的保持策略（`fts_rowid` 随重建表不变）有专门测试（`src/main/data/db/__tests__/ftsRebuild.test.ts:65-126`）。
  - **全局分发**：`ContentSearchService`（`src/main/data/services/ContentSearchService.ts:133`）把 `/search/contents` 分派给 `messageService.search`（`:63-64`）与 `agentSessionMessageService.search`（`:80-81`）。

## 3. 创建、切换、归档、删除与恢复

### 3.1 新建：同一事务里建虚拟根

`TopicService.create()`（`TopicService.ts:179-205`）在一个写事务里做两件事：`insertWithOrderKey` 插入 topic 行（置顶/新建默认排首位），然后立即调用 `messageService.createRootMessageTx`（`:198`）创建该 topic 的虚拟根。

`duplicate()`（`TopicService.ts:207-269`）复用同一套创建逻辑，并在其上加拷贝步骤：

- 新 topic 先建虚拟根（`:241`）；
- 用 `copyPathRowsTx`（`MessageService.ts:1943-2006`）把源 topic 某条路径的消息拷过来、头消息 reparent 到新根下；
- 最后把 `activeNodeId` 指向拷贝出的叶子（`TopicService.ts:251-256`）；`chat_message_file_ref` 引用随拷贝一并复制（`TopicService.ts:63-95,249`），但 pin、tag、trace 链接不复制（`:247-248` 注释）。

虚拟根的写者还包括 `TemporaryChatService`（临时聊天转正，`TemporaryChatService.ts:222`）和 v1→v2 迁移器（`ChatMigrator`，`message-tree.md:79-89`）。

### 3.2 重命名与自动命名（"单向棋"设计）

- **重命名**：交互入口在 `Chat.tsx:112-131`（`topic.rename` 命令处理器，弹出输入框取新名字），成功后写回新名字并置手动改名标记（`:127`）。`TopicService.update()`（`TopicService.ts:272-309`）的两种语义：
  - 传 `name` 时：默认把 `isNameManuallyEdited` 置为 `true`（除非显式传 `false`，`:285-288`）；
  - 只传 `isNameManuallyEdited` 时：走"仅调整元数据"旁路（`:289-291`，供迁移/修复用）。
- **自动命名**：由 `TopicNamingService`（`src/main/services/TopicNamingService.ts`）负责，分两阶段：
  - ①第一条用户消息落库后立刻用消息原文截断出临时标题（`maybeRenameFromFirstUserMessage`，`:144-166`）；
  - ②首轮回复完成后用 AI 生成摘要标题替换临时标题（`maybeRenameFromConversationSummary`，`:168-175`，实现 `doMaybeRenameFromConversationSummary` `:181+`）。

  两阶段都受 `canAutoRenameTopicName`（`:134`）与 `isNameManuallyEdited` 把关（`:150,190,196`）：topic 名为空或仍等于上次生成的临时标题才允许继续自动改名；用户一旦手动改名就永久停止自动命名——不存在"自动改名覆盖用户改名"。
  - 提交 `b68fafcaf7` 起摘要生成请求不再携带 `assistantId`（测试断言 `generateText` 调用无该属性，`TopicNamingService.test.ts:137`），避免把助手的工具配置挂到标题生成请求上。

### 3.3 删除：先消息后关联最后删行；附件回收交给 FileManager GC

`TopicService.delete`（`:316-321`）/`deleteByIds`（`:323-330`）→ `deleteManyByIdsTx`（`:332-357`），删除顺序分三步：

1. 先清消息（`messageService.purgeByTopicIdsTx`，`MessageService.ts:333-338`）；
2. 再清 tag、pin 关联（`:352-353`）；
3. 最后删 topic 行本身（`:354`）。

删除是硬删除（`tx.delete`）；`deletedAt` 列在各查询中仍被过滤，供未来软删除路径使用（`TopicService.ts:312-315` 注释明确要求未来软删除必须同时清 pin）。

"删除 Topic 不主动删磁盘文件"仍是事实（删除动作本身不做文件清理），但内部附件经 `chat_message_file_ref` 引用计数 + FileManager 策略化条目回收兜底，不再是纯无主泄漏：

- 引用计数：`MessageService.replaceChatMessageFileRefsTx`（`:251-281`）每次写 parts 时重建引用，`extractChatMessageFileRefs`（`:217-235`）收集 file part 与 tool_output 持久化 blob 的引用；
- 策略化回收：`delete_when_unreferenced` 条目有宽限期扫描回收（`src/main/services/file/internal/entryCleanup.ts:2-3,75,102`），手动条目有孤儿扫描（`src/main/services/file/internal/orphanSweep.ts:75-76`，`findManualUnreferenced`）。

回收时机与策略参数未运行验证（静态推断）。

### 3.4 空 Topic 判定：运行时按消息条数

不是 topic 表上的字段，而是运行时判定：`ChatContent.tsx:208` 用 `!isHistoryLoading && runtime.messages.length === 0` 判断，为真时叠加 `ConversationGreeting` 欢迎层（`:211-215`）。因为虚拟根永不出现在读取接口的返回列表里（见 1.2），"空 Topic"= 除虚拟根外没有任何内容消息，跟 topic 行本身是否存在虚拟根无关（虚拟根总是存在）。

### 3.5 切换与恢复

切换 Topic 的数据侧只是换 `activeNodeId` + 重新分页拉取（读侧投影见 5 节）；切换时保留哪些局部 UI 状态（草稿、滚动位置、面板开关）属于 Chat UI 类目。

崩溃恢复：`AiStreamManager` 启动时执行 boot reconcile——把上次进程崩溃遗留的 `pending` assistant 行统一翻为 `error`（`AiStreamManager.ts:497-506`；配套查找与批量标记见 `MessageService` `:794-815`），避免 UI 永久显示"思考中"的冻结气泡；reconcile 完成前新流会等待（`AiStreamManager.ts:310-313`）。多窗口并发写入、数据库迁移的运行行为本次未验证（见第 10 节）。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 持久层是真的树

证据：自引用外键（`message.ts:59`）+ `siblingsGroupId` 兄弟组 + CHECK 约束的虚拟根（见 1.2）；删除时的 `INVALID_OPERATION` 拦截与 reparent 语义（见 1.2）；`createSibling`（`MessageService.ts:926-974`，编辑后重发）在源未分组时分配新的兄弟组号、加入已有组时继承组号（`:942-946`），并立即把 active 指针移到新行（`:963`）。**树是真实的，不是线性链表/锚点跳转的伪装。**

### 4.2 "切分支"是 activeNodeId 指针重定向，不是移动/复制消息

- `TopicService.setActiveNodeTx`（`TopicService.ts:371-407`）就是一次 `UPDATE topic SET active_node_id = ?`（`:400-406`），唯一的校验是目标消息属于该 topic、且不是虚拟根（`:372-398`）。
- 渲染时走 `getPathRowsToNodeTx`（`MessageService.ts:1885-1930`）：从目标节点往上走到虚拟根为止，虚拟根本身被排除在结果外（`:1925-1929`）。所以前端看到的"当前分支的完整对话"= 从 `activeNodeId` 反向 walk 到根的路径，**每次切分支都要重新 walk 一次**，不是维护链表指针跳转结构。
- **兄弟分支导航与分支面板切换**：`ChatWriteActions.setActiveBranch(throughNodeId)`（`src/renderer/hooks/chat/ChatWriteContext.ts:66-75` 接口注释；实现 `useChatWriteActions.ts:450-479`）先 GET `/topics/:topicId/path?nodeId=throughNodeId` 拿到该分支的最新叶子（`MessageService.getPathThrough`，`:2019-2052`，取 `created_at` 最大且无存活子节点的后代），再把 `activeNodeId` 指到那个叶子——本质是"找到目标分支最新的叶子，移动指针"，这样切到中间节点也能看到它后续的完整追问链。读侧组装见下：
  - 用户消息按 `siblingsGroupId` 分组；
  - assistant 消息按 `(siblingsGroupId, modelId)` 分组（多模型多轮混合场景按模型分桶）；
  - 实现见 `useTopicMessages.ts:51-60,104-122,136-155`。

### 4.3 发送锚点：持久化预留行（reservation）

"从历史节点开新分支"先持久化一个空 user 叶子（`reserveBranch`），下一次提交用 `fill-reserved` 模式填充同一行（语义见第 2 节）：

- 分支预留行在流式进行中创建时带 `activate=false`，不挪动正在跑的 active 路径（`useTopicBranchActions.ts:20`）；用户选中该预留行并在 topic 仍 live 时发送，排队负载携带预留行 id（`useChatRuntimeState.ts:206-227`，模式 `reserved-branch`），等待 topic 空闲后才提交；主进程侧 `PersistentChatContextProvider` 拒绝流式期间的该模式提交作为竞态兜底（`PersistentChatContextProvider.ts:247-253`）。
- 空叶子的删除带 `awaitingInputOnly=true` 守卫：已填充的行拒绝删除（`MessageService.ts:1679-1684`），避免"删掉一条刚被填充的消息"。

与旧实现（三态 ref 状态机）相比，数据语义从"临时态"变成"持久化结构"，跨重载/重挂载保持不变。

### 4.4 编辑、删除、重试、翻译的数据变更入口

数据侧入口是 `ChatWriteContext` 的写操作（Home 适配器经 `requireChatWrite('xxx')` 取实现，见 Chat UI 笔记 6.2），最终落在 `MessageService`/`TopicService`：

- `editMessage` → `PATCH /messages/:id`（`MessageService.update` `:1328-1395`，含防环校验 `:1332-1337` 与虚拟根不可 reparent 守卫 `:1355-1365`）；
- 删除的 reparent、虚拟根拦截语义见 1.2；
- `forkAndResend`（编辑用户消息后重发）走 `createSibling` + `regenerate-message`（`useChatWriteActions.ts:346-396`）。

**执行链**（重试如何选择起始上下文、重新生成从哪个节点重建请求）见对话请求与上下文笔记第 2、7 节。

### 4.5 版本切换与复制

"复制分支到新 Topic"（分支面板右键菜单）走 `POST /topics/:id/duplicate`，数据语义即 3.1 的 `duplicate()`：新 topic 建虚拟根 + `copyPathRowsTx` 拷贝路径消息（被拷贝的 `pending` 行转为 `error`，因为拷贝后没有流属主，`MessageService.ts:1987-1988`）。版本切换本身不产生新对象，只有指针移动（4.2）。

## 5. 列表、分页、搜索与定位

- **消息分页**：`useTopicMessages.ts:184-298` 从 DataApi 用 `useInfiniteQuery` 拉取 `/topics/:topicId/messages`（`includeSiblings: true`，`:194-206`），分页细节分三层：
  - 分支接口是 newest-page-first 的 before-cursor 分页（`MessageService.getBranchMessages` `:641-768`，`DEFAULT_LIMIT=20` `:102`），渲染层翻转页序得到 root→activeNode 的单调时间序列（`:211`）；
  - 页大小按 `chat.message.navigation_mode` 偏好分 50/页（`PAGE_SIZE` `:30`）与 150/页（锚点轨模式 `ANCHOR_RAIL_PAGE_SIZE` `:35`，偏好默认 `'anchor'`，`preferenceSchemas.ts:609`）；
  - `activeNodeId` 取自最新一页响应的顶层 metadata（`:223`）；`rootId`（第一轮判据）由服务端在每页响应中携带（`MessageService.ts:663`）。
- **全量树接口**：`/topics/:id/tree`（`depth=-1`），供分支图使用（见 Chat UI 笔记 6.3）。
- **会话内搜索：数据 + DOM 混合，不读 FTS**。`MessageListSearch`（`src/renderer/components/chat/messages/list/MessageListSearch.tsx`）先在**已加载的消息数据**上做粗匹配，再对**已挂载 DOM** 做精确 Range：
  - 数据粗匹配：`computeMessageSearchMatches`（`messageSearch.ts:120-162`）把每个消息的 text part 投影成纯文本（`markdownToPlainText` 降级渲染），排除 `pending` assistant（`:84`），多模型回复组以整组粒度出一个匹配（`:133-148`）；
  - DOM 精确匹配：`findRangesInScope`（`src/renderer/utils/contentSearch.ts:40-88`）用 TreeWalker 求 Range，`findTextMatches` 用 `Intl.Segmenter` 做整词（`:11,27-33`）；`messageSearchDom.ts` 的节点过滤（`:10-18`）排除按钮/引用/代码块工具栏等。
  - 提交 `a012837e5c`（"fix(message-search): support virtualized conversations"）使虚拟化窗口外的消息可经粗匹配被找到，导航到未挂载行时 `locateMessage` 把行滚入视口（`MessageListSearch.tsx:337-339`）；
  - 高亮用 CSS Custom Highlight API（`MessageListSearch.tsx:189-199,242-244`，样式 `src/renderer/assets/styles/index.css:227-228`）；
  - 流式期间匹配数据被锁存，流结束才重算（`MessageListSearch.tsx:97-102`）。
- **跨会话全局搜索：FTS**。入口 `app.search` 命令打开 `GlobalSearchPopup`（`src/renderer/components/layout/AppShell.tsx:80-99`），提供两个端点：
  - `/search/contents`：由主进程 `ContentSearchService` 分派到 `MessageService.search`（FTS，见 2 节）与 agent 会话搜索；
  - `/search/entities`：覆盖 topic/assistant/agent/session/knowledge 名称检索（`EntitySearchService.ts:40-84`）。

  会话内搜索与全局搜索是两套独立实现，前者无持久化索引。
- **Topic 列表**：分页、排序、搜索三块（分页/加载/空状态呈现属于 Chat UI 类目）：
  - 分页：`/topics` 无限分页，页大小 200（`Topics.test.tsx:594,1068` 断言 `useInfiniteQuery('/topics', { limit: 200 })`）；
  - 排序：置顶段（`pin.orderKey`）优先、普通段按 `orderKey`/创建顺序（`TopicService.listByCursor` `:427-512`），时间分组视图的"最近"排序由渲染层在已加载列表上做（`TopicService.ts:419-425` 注释）；
  - 名称搜索：`TopicService.search`（`:514-547`，LIKE 转义）。
## 6. 缓存、一致性、多窗口与并发写入

- **SWR 缓存是读投影**：`useTopicMessages` 由 SWR infinite 缓存驱动；execution overlay 的 seed 用 `structuredClone` 深拷贝，避免 AI SDK 的原地修改污染 SWR/数据库历史引用（2 节）。`useDataChange` 订阅数据变更信号，命中已加载消息才触发重验证（`useTopicMessages.ts:257-266`）。
- **两层 parts 缓存的结构共享**：`useStableMessagePartsLayers`（`src/renderer/components/chat/messages/stream/useStableMessagePartsLayers.ts`）用 `useRef` 手搓，未变化时复用 part 数组和 map 容器引用；文件头部注释说明仓库不引入全局状态库（`:1-41`）。渲染侧合并细节见消息渲染器笔记。
- **并发写入**：两个层面分别序列化：
  - 单会话串行：`AiStreamManager` 用每 topic 的 `dispatchLock` 序列化 `prepareDispatch → send` 整个窗口（`AiStreamManager.ts:242,309-335`，`withDispatchLock` `:346-348`），注释专门解释为什么需要它（防止并发 open 与 approval-continue 同时看到"无 live 流"而孤儿化占位行）；
  - 多模型并行：N 个 `runExecutionLoop` 并行、各自经自己的 `PersistenceListener`/`MessageServiceBackend` 写各自的占位消息（`PersistentChatContextProvider.ts:362-389`）。

  执行侧语义见对话请求与上下文笔记第 5、8 节。
- **备份恢复写安静期**：`AiStreamManager.pause()`/`drainInFlight()`（`:371-385,402-442`）在备份恢复期间门禁新 turn 准入并等待在途持久化落盘，`dispatch` 在 quiesce 期间返回 `blocked`（`:321-326`）。这是"多端并发写入"之外的数据一致性机制。
- **多窗口/多端并发写入**：本次未调查（见第 10 节）。

## 7. 迁移、导入导出与保留策略

- **schema 迁移**：存在 v2 迁移体系（`src/main/data/migration/v2/migrators/`），两类迁移器：
  - `ChatMigrator`：为每个迁移的 topic 内联创建虚拟根并重挂 v1 物理根（`message-tree.md:84-85,98`）；
  - `AgentsMigrator`：维护 agent 会话消息及其 `searchableText`/FTS（`AgentsMigrator.ts:1194-1203,1625`）。

  FTS 虚拟表与触发器由迁移后脚本重建（`MESSAGE_FTS_STATEMENTS` 幂等，`message.ts:106-111` 注释）。迁移细节与 schema 版本号机制本次未展开。
- **导入导出、备份恢复**：备份（BackupService/AutoBackupService）与恢复的写入安静期机制见 6 节；导入导出 UI 与格式细节本次未调查。
- **保留策略的已知边界**：删除 Topic 不清理磁盘上的图片/附件文件（3.3），但文件条目有引用计数 + 策略化扫描回收兜底，不再是纯遗留缺口；回收时机与宽限参数未运行验证。

## 8. Agent、模型、知识库与附件绑定

- **附件**：以 file part 内嵌在消息 parts 里（渲染侧 `src/renderer/utils/file/buildFileParts.ts` 生成，发送侧见对话请求与上下文笔记第 9 节），随消息一起持久化；其 `fileEntryId` 同时落到 `chat_message_file_ref` 引用表（`MessageService.ts:217-235`）。
- **知识库范围**：用两种 part 表达，都属于消息 parts 的一部分而非独立关联表：
  - 知识库范围：`data-knowledge-scope` part，访问器见 `uiParts.ts:348`（`withKnowledgeScopePart` `:376-388`、`getKnowledgeBaseIdsFromParts` `:391-400`）；
  - "清理上下文"边界：`data-clear` part（`createClearContextPart`/`hasClearContextPart` `:354-364`），消息渲染时携带 `isContextBoundary`（`MessageService.ts:299`）。
- **多模型**：`siblingsGroupId` 与 `modelId` 是消息级绑定字段（读侧按 `(siblingsGroupId, modelId)` 分桶，见 4.2）；"这次用哪些模型"本身是请求参数，不持久化在 topic 行（发送前配置见 Chat UI 笔记第 4 节）；assistant 头像/身份以 `messageSnapshot` 快照在回复行上（`PersistentChatContextProvider.ts:101-114` 构建，删除助手后 header 仍可渲染）。
- **Agent 会话**：Agent 侧以 session 为数据单元，会话消息是独立的扁平表（`agent_session_message`，`message-tree.md:8-9` 明确其不适用树模型），不在本笔记覆盖范围内；Home 侧 Topic 与 Agent 侧 session 的差异在能力注入层而非消息壳（Home/Agent 适配器见 Chat UI 笔记 6.2）。

## 9. 设计取舍与已确认边界

- **三层数据复杂度是有意为之的取舍**：真树结构 + `activeNodeId` 指针 + live overlay 三层，配合 Home/Agent 双适配器，让"保留过程、支持分支比较、多模型并行"这些能力得以实现；代价是要理解至少四层数据（DB 树、SWR 缓存、execution overlay、live branch 前端态）才能追踪一条消息从输入到渲染的完整生命周期，调试门槛明显高于单层 session 客户端。
- **虚拟根是存储层不变量而非约定**：CHECK 约束 + 部分唯一索引把"每 topic 一根、根 ⇔ null parent、内容必有 parent"固化在 schema（1.2），服务层的大量校验只是友好错误入口（`MessageService.ts:935-940,1349-1364,1675-1677`）。
- **分支草稿从临时态变成持久化态**：等待输入分支现在是 DB 行（empty successful user leaf），`isAwaitingInput` 由结构派生、无 draft 标记；代价是出现"空叶子必须保持不可见/不可当普通消息处理"的派生规则（列表隐藏、删除/填充带守卫）。
- **删除语义收敛为"splice 保留可达历史"**：首轮消息可删（子节点挂回虚拟根）、多模型组删除只删兄弟回复并 reparent 子节点、组删除在回复生成中被禁用；`SET NULL` 方案被明确否掉（会在级联删除中途制造第二个 null-parent 行，`message-tree.md:109-112`）。
- **删除 Topic 的磁盘文件回收交给 FileManager GC**：删除动作本身不做文件清理，但文件条目有引用计数 + 策略化扫描回收（3.3）。
- **搜索双轨的边界**：会话内搜索是"已加载数据 + 已挂载 DOM"（流式行被排除、未加载页搜不到，这是分页 + 数据匹配的固有限制）；全局搜索才是持久化 FTS（trigram），命中定位到消息级别，不提供 DOM 级高亮。
- **崩溃恢复有专门路径**：boot reconcile 把遗留 `pending` 翻成 `error`（3.5），加上 `clearActiveNode` 与事务原子性，异常退出后的数据语义是"已提交的写都保留、未提交的回滚、半截回复标为 error"（运行验证见第 10 节）。
- **类目边界**：本笔记只回答数据语义。停止生成时半截消息最终如何落盘、重试如何选择上下文见对话请求与上下文；分支树图、兄弟导航与搜索工作流见 Chat UI；part 渲染、虚拟列表与消息壳装配见消息渲染器。

## 10. 未验证事项

- 崩溃恢复、多窗口竞争、数据库迁移与大数量级 FTS 搜索未做运行验证（静态代码只能确认事务、索引和写入入口，不能代替运行验证）。
- `AiStreamManager` 状态机（`ActiveStream.status` 六种取值）的竞态风险未运行验证，执行侧详见对话请求与上下文笔记。
- FileManager 附件回收的触发时机与宽限参数（`entryCleanup.ts` 的 `ENTRY_CLEANUP_GRACE_MS`）未运行验证。
- 流式期间中间增量落盘的频率未核实（最终态落盘语义见对话请求与上下文笔记第 6 节）。
- schema 版本号演进、迁移执行时机与失败恢复未展开调查。

## 11. 关键源码索引

- `src/shared/data/types/topic.ts`（Topic 模型）
- `src/main/data/db/schemas/message.ts`（消息表、CHECK/索引、FTS 触发器语句）
- `src/main/data/services/TopicService.ts`（CRUD、`setActiveNodeTx`、`listByCursor`、`deleteManyByIdsTx`）
- `src/main/data/services/MessageService.ts`（树维护、`getTree`/`getBranchMessages`/`getPathRowsToNodeTx`、`reserveBranch`、`createUserMessageWithPlaceholders`、`delete`/`clearTopicMessages`、FTS `search`）
- `src/main/services/TopicNamingService.ts`（自动命名两阶段）
- `docs/references/chat/message-tree.md`（树的权威文档）
- `src/renderer/hooks/useTopicMessages.ts`（分页拉取与兄弟分桶）
- `src/renderer/hooks/useExecutionOverlay.ts`、`src/renderer/services/aiTransport/ExecutionStreamOverlayService.ts`（live overlay）
- `src/renderer/components/chat/messages/list/MessageListSearch.tsx`、`messageSearch.ts`、`src/renderer/utils/contentSearch.ts`（会话内搜索）
- `src/renderer/pages/home/hooks/useTopicBranchActions.ts`（分支预留/删除守卫入口）
- `src/main/services/file/internal/entryCleanup.ts`、`orphanSweep.ts`（附件 GC）
