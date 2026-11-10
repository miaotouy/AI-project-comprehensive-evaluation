# Cherry Studio 会话与消息管理调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：直接阅读源码（主进程 SQLite 数据层 `TopicService`/`MessageService`、schema 与 FTS 触发器、`docs/dev/references/chat/message-tree.md` 文档、渲染层 DataApi 分页与搜索实现），并核对行号与符号至当前 HEAD
>
> 调查范围：Topic/Session/Message 数据模型、事实源与持久化、生命周期、分支语义、分页索引与搜索、恢复与保留语义；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 普通聊天以 Topic 为会话单位，Agent 则各自拥有独立 Session。两类对象分表存放在 SQLite，都维护活动路径与带父节点的消息树；Agent 一侧另外保存原生上下文绑定与 fork checkpoint（见 1.3）。
- 消息按 adjacency-list 树存储，父子关系由 `message.parentId` 自引用外键表达并带级联删除，读写统一走主进程的消息服务。这棵树的语义以 `docs/dev/references/chat/message-tree.md` 为权威文档，本次核对确认文档与当前代码一致：虚拟根、等待输入分支、删除语义与 consumer contract 都能对应到实现。源码定位：`src/main/data/services/MessageService.ts`。
- 新建 Topic 的同一个写事务里就会插入一条虚拟根消息（`createRootMessageTx`），因此不存在"还没有根消息的 Topic"这种中间态。空 Topic 的判定发生在运行时，按消息条数计算，与虚拟根是否存在无关。
- "切换分支"只是移动活动节点指针 `activeNodeId`，把它指向目标分支的叶子。前端看到的"当前分支的完整对话"每次都要从该指针反向走到根重新求一遍，求路径时虚拟根被排除在结果之外（`getPathRowsToNodeTx`）。
- 分支草稿是一条真正落库的空叶子：`POST /messages/:id/branches` 写入一行内容为空、状态为成功的 user 消息（`reserveBranch`），等待输入的状态由结构派生（`isBlankUserTurn`），渲染层不需要假节点。流式增量仍然是不落库的前端 overlay。
- 搜索分两条独立路径。会话内搜索混合使用已加载数据的粗匹配与已挂载 DOM 的精确 Range 匹配，能定位到虚拟化窗口之外的消息（`MessageListSearch`）。跨会话全局搜索依赖持久化的 FTS5 全文索引：外部内容表 `message_fts` 配合 `searchableText` 列的触发器维护。
- 崩溃恢复有明确机制：主进程启动时执行一次 boot reconcile，把上次崩溃遗留的处于 `pending` 的 assistant 行统一翻成 `error`，避免界面永久停在"思考中"。
- 删除 Topic 分两段执行：默认只置位 `deletedAt` 把条目送进回收站并清掉 tag/pin 关联，永久删除才清消息行与 topic 行，保留期到期由后台清理任务批量处理。删除动作本身不碰磁盘上的附件文件；内部附件由 `chat_message_file_ref` 的引用计数配合 FileManager 的策略化条目回收兜底，覆盖宽限期扫描与孤儿条目扫描两类。

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
- "空 Topic 判定"由运行时按消息条数计算，topic 表上没有对应字段（见 3.4）。

判断一条消息是否属于第一轮对话，唯一权威判据是它的父节点是否为虚拟根。`getBranchMessages` 与 `getTree` 的每页响应都携带虚拟根 id，消息的父节点 id 等于该值即为第一轮，实现见 `MessageService.ts`。树文档在 `docs/dev/references/chat/message-tree.md:116-122` 明确排除了另外两种猜法：按"父节点不在已加载列表里"反推，或沿用 v1 遗留的 `askId`。

### 1.2 消息树：adjacency-list 树，由数据库约束强制

- 每条消息占一行，父子关系用 `parentId` 自引用外键表达并带级联删除，非零的 `siblingsGroupId` 标记同一个父节点下的多模型、多分支兄弟组。定位：`src/main/data/db/schemas/message.ts:59`、`docs/dev/references/chat/message-tree.md:14-15,22`。
- 每个 topic 恰好持有一条内容为空的虚拟根：角色为 `role='root'`，父节点为 `parentId=NULL`，parts 为空数组。这条不变量由 schema 强制，应用层不负责维持（`message.ts:70-83`）：
  - 唯一索引 `message_topic_root_uniq` 强制"每 topic 至多一条 live 根"；
  - CHECK 约束 `message_root_parent_check` 强制 `(role='root') = (parentId IS NULL)`；
  - role/status 各有 CHECK。
- 分支消息、树与反向路径这三个读接口都不返回虚拟根：前两个接口遇到空结果直接返回，求反向路径的接口在返回前把根从链上摘掉。实现均在 `MessageService.ts`。
- **持久化形状**：数据库直接存储 AI SDK 的 `UIMessage.parts`，落在 `data` JSON 列上（`message.ts:30`），传输、持久化与渲染共用同一种结构；part 类型清单、`providerMetadata.cherry` 扩展与访问器见消息渲染器笔记"消息数据模型"一节。
- 消息行另有五个附加列（schema 见 `message.ts:41-53`）：
  - `searchableText`：供 FTS 使用的文本，由触发器填充（见 2 节）；
  - `ftsRowid`：FTS 的稳定外键；
  - `messageSnapshot`：模型快照；
  - `stats`：用量统计；
  - `compactionSummary`：持久化压缩标记。
- 树相关服务方法（均在 `MessageService` 中）：
  - `getTree`：用一次主题查询同时取回活动路径、补齐项与受深度限制的子树，是分支图的数据源；转换节点时，一条没有子节点的空白 successful user 叶子会派生出 `isAwaitingInput`。
  - `getBranchMessages`：先用路径 id 算出分页窗口，只对当前页加载完整行，见 5 节。
  - `getPathIdsToNodeTx` 与 `getRowsInOrderTx` 分两步完成：先只取 id 与 parent_id 排出到根的路径顺序，再按 id 分块加载行，长路径因此不会撞上 SQLite 的绑定变量上限。
  - `getPathToNode`/`getPathRowsToNodeTx`：节点到根的反向路径。
  - `getPathThrough`：求经过某节点的分支的最新叶子，供分支导航。
  - `deleteBranch`：删除"从所选节点到其叶子"的一条路径，见 4.6。
- 约束在 `MessageService` 里的具体落地：
  - 删除接口遇到虚拟根直接抛 `INVALID_OPERATION`；非级联删除先把子节点重新挂到祖父节点，再删本节点，重挂时会给被移动的兄弟组重新分配组号，避免与目标父节点下已有的组撞号；首轮消息可以正常删除，其子节点会挂回虚拟根。
  - `deleteReplyGroup` 只删除同组的 assistant 兄弟消息，再把各组下的直接子节点重新挂到共享的用户消息下；组内任一回复仍处于 `pending` 时拒绝删除。
  - `clearTopicMessages` 清空一个 topic 的内容消息，保留虚拟根并清空 `activeNodeId`。

### 1.3 Agent Session：独立消息树与原生上下文

Agent Session 与普通 Topic 分表存储，不能把 Topic 的所有操作套用到 Agent。Agent 消息表也有父节点与每会话唯一虚拟根，Session 行持有活动节点；选中兄弟消息时向下取该分支最新叶子并更新指针。消息另存原生上下文绑定、输入 ID、恢复令牌与运行时 checkpoint，用于让产品消息路径对应到各 runtime 的历史。依据：[agentSessionMessage.ts:12–69](../../cherry-studio/src/main/data/db/schemas/agentSessionMessage.ts#L12-L69)、[AgentSessionMessageService.ts:478–518](../../cherry-studio/src/main/data/services/AgentSessionMessageService.ts#L478-L518)。

用户消息的“编辑并重发”保留旧分支：主进程校验目标仍在活动路径、属于普通交互输入，并以历史快照版本拒绝过期提交；运行中、后台活动、审批或关闭未完成时拒绝编辑。编辑操作关闭原连接，发布对应原生历史，再把活动指针选回被编辑输入的前驱，在同一 Session 新建兄弟用户消息与 assistant 占位，然后启动生成。它与直接改写已存消息正文的保存操作有不同语义。依据：[AgentSessionRuntimeService.ts:387–440](../../cherry-studio/src/main/ai/agentSession/AgentSessionRuntimeService.ts#L387-L440)、[AgentSessionMessageService.ts:520–564](../../cherry-studio/src/main/data/services/AgentSessionMessageService.ts#L520-L564)、[AgentChatContextProvider.ts:328–361](../../cherry-studio/src/main/ai/streamManager/context/AgentChatContextProvider.ts#L328-L361)。

“复制为新会话”另外创建 Session：按选中消息的 checkpoint 调用 runtime fork，复制工作区文件与原生历史后才事务发布子会话及消息前缀。相同源会话/锚点的并发 fork 共用在途操作；临时资源有恢复与清理记录。检查范围覆盖 fork 的准备、原生发布与数据库提交，未实际运行跨 runtime 恢复或复制大工作区。依据：[AgentSessionForkOperations.ts:37–57,200–300](../../cherry-studio/src/main/ai/agentSession/fork/AgentSessionForkOperations.ts#L37-L57)。

## 2. 事实源、索引与持久化

- **权威源是 SQLite**：主进程 `TopicService`/`MessageService` 负责全部 CRUD；renderer 读侧经 DataApi 分页接口，SWR 缓存是缓存投影，不是权威源（`useTopicMessages.ts` 的 projection 用 WeakMap 保持同一行消息的投影身份稳定）。
- **活动路径事实源在 topic 行**：`activeNodeId` 由 `setActiveNodeTx`（`TopicService.ts`）写入，唯一校验是目标消息属于该 topic、且不是虚拟根（ 显式拒绝 root）。
- **流式增量 overlay 不落库**：overlay 是窗口级服务 `ExecutionStreamOverlayService`（`src/renderer/services/aiTransport/ExecutionStreamOverlayService.ts`），按 transport `topicId` 引用计数，并在 rAF 周期批量提交：
  - 生命周期：`acquire`、`release`、`syncExecutions`、批量提交；
  - React 绑定：`useExecutionOverlay.ts` 只做 `useSyncExternalStore`，组件卸载不拆 reader——路由/标签页切换期间 Main 继续生成，重挂载同步恢复 live overlay；
  - reader 种子（seed）来自当前 DB 行的深拷贝（`structuredClone`），避免写脏 SWR 缓存。
- **分支草稿/发送锚点已是持久化行**：锚点是持久化的空 user 叶子，创建、填充、删除都有服务端守卫，渲染层只负责发起请求：
  - **创建**：`MessageService.reserveBranch(anchorId, activate)`（`MessageService.ts`）要求 anchor 必须是 assistant 消息，在其下插一条 `role='user'`、`data.parts=[]`、`status='success'` 的空叶子；重复调用同一 anchor 每次都新建行（有意的分支点），`activate=false` 用于流式期间不挪动 active 指针；
  - **等待输入状态**：由结构派生（`isBlankUserTurn`，`src/shared/data/types/uiParts.ts:367-373`），不落任何 draft 标记；
  - **删除/填充守卫**：`DELETE /messages/:id?awaitingInputOnly=true` 复核目标仍是空叶子（`MessageService.ts`，判定 `isAwaitingInputLeaf`）；`createUserMessageWithPlaceholders` 的 `fill-reserved` 模式在同一事务里填充该行并建 assistant 占位（填充前再校验）；
  - **竞态兜底**：主进程 `PersistentChatContextProvider` 在流式进行时拒绝 reserved-branch 提交（`PersistentChatContextProvider.ts:247-253`，错误原文见）；
  - **渲染侧入口**：`useTopicBranchActions`（路径见文末索引）的 `reserveBranch` 发 `POST /messages/:id/branches`、`deleteReservedBranch` 发删除请求。
- **分支图/列表的合并方向**：`topicMessageFlowLiveTree.ts` 的合并函数只叠加"流式中尚未持久化的消息"临时节点；awaiting-input 叶子本身是 DB 节点，直接进 `/topics/:id/tree` 结果（`TreeNode.isAwaitingInput`，`MessageService.ts`）——分支图 = 持久化树（含空分支叶子）+ 流式 overlay。
- **FTS 全文索引（跨会话内容搜索）**：持久化全文索引，由触发器随消息行维护，分三层：
  - **文本抽取**：`message.searchableText` 由 SQLite 触发器从 `data.parts` 抽取下列五类 part 的文本内容（`message.ts:112-146`）：
    ```text
    text / data-code / data-translation / data-compact / data-error
    ```
  - **索引与同步**：`message_fts` 是 external-content FTS5 表（trigram 分词，键在 `ftsRowid`，`message.ts:148-158`），`message_ai`/`message_ad`/`message_au` 三个触发器在 INSERT/DELETE/UPDATE OF data 时同步（`message.ts:170-194`）；
  - **查询与分发**：`MessageService.search`JOIN `message_fts`、过滤 `searchable_text != ''`、cursor 分页；agent 会话有同构的 `agent_session_message_fts`。FTS 与行同步的保持策略（`fts_rowid` 随重建表不变）有专门测试（`src/main/data/db/__tests__/ftsRebuild.test.ts:65-126`）。
  - **全局分发**：`ContentSearchService`（`src/main/data/services/ContentSearchService.ts:133`）把 `/search/contents` 分派给 `messageService.search`与 `agentSessionMessageService.search`。

## 3. 创建、切换、归档、删除与恢复

### 3.1 新建：同一事务里建虚拟根

`TopicService.create()`（`TopicService.ts`）在一个写事务里做两件事：`insertWithOrderKey` 插入 topic 行（置顶/新建默认排首位），然后立即调用 `messageService.createRootMessageTx`创建该 topic 的虚拟根。

`duplicate()`（`TopicService.ts`）复用同一套创建逻辑，并在其上加拷贝步骤：

- 新 topic 先建虚拟根；
- 用 `copyPathRowsTx`（`MessageService.ts`）把源 topic 某条路径的消息拷过来、头消息 reparent 到新根下；
- 最后把 `activeNodeId` 指向拷贝出的叶子（`TopicService.ts`）；`chat_message_file_ref` 引用随拷贝一并复制（`TopicService.ts`），但 pin、tag、trace 链接不复制（ 注释）。

虚拟根的写者还包括 `TemporaryChatService`（临时聊天转正，`TemporaryChatService.ts:222`）和 v1→v2 迁移器（`ChatMigrator`，`docs/dev/references/chat/message-tree.md:79-89`）。

### 3.2 重命名与自动命名（"单向棋"设计）

- **重命名**：用户通过 `topic.rename` 命令触发改名，命令处理器弹出输入框取得新名字，成功后把名字写回并置上手动改名标记，交互入口在 `Chat.tsx:112-131`。数据侧的 `TopicService.update()` 承担两种语义（`TopicService.ts`）：
  - 传名字时，默认置上手动改名标记；显式传 `isNameManuallyEdited: false` 会把标记清为 false（`TopicService.ts:391-398`）；
  - 只传 `isNameManuallyEdited` 时：走"仅调整元数据"旁路（供迁移/修复用）。
- **自动命名**：由 `TopicNamingService` 负责，分两阶段执行，实现见 `src/main/services/TopicNamingService.ts`：
  - ①第一条用户消息落库后，立即截取消息原文生成临时标题（`maybeRenameFromFirstUserMessage`）；
  - ②首轮回复完成后，用 AI 生成的摘要标题替换临时标题（`maybeRenameFromConversationSummary`，实际逻辑由 `doMaybeRenameFromConversationSummary` 承担）。

  两阶段都受 `canAutoRenameTopicName`与 `isNameManuallyEdited` 把关：topic 名为空或仍等于上次生成的临时标题才允许继续自动改名；用户一旦手动改名就永久停止自动命名——不存在"自动改名覆盖用户改名"。
  - 摘要生成请求不携带 `assistantId`（测试断言 `generateText` 调用无该属性，`TopicNamingService.test.ts:137`），避免把助手的工具配置挂到标题生成请求上。

### 3.3 删除：先进回收站，再按保留期清理

`TopicService.delete`与 `deleteByIds`默认是**软删除**：`trashManyByIdsTx`只把 topic 行的 `deletedAt` 置为当前时间，同时清掉该 topic 的 tag 与 pin 关联，消息行与磁盘文件都不动。读取侧按 `deletedAt IS NULL` 过滤，回收站视图反过来只看非空的行。

只有显式传 `permanent` 才真正清除：`purgeManyByIdsTx`要求目标已处于回收站（`targetState` 决定按 active 还是 trashed 过滤），按顺序清消息（`messageService.purgeByTopicIdsTx`）、清 tag 与 pin 关联、最后删 topic 行。回收站条目可以 `restore`把 `deletedAt` 置回 null。

到期清理由保留期驱动：`purgeExpiredTx`按截止时间批量删过期条目，由后台清理任务调用，期限取偏好 `data.trash.retention_days`（默认 30 天）。因此"删除 Topic 不主动删磁盘文件"依然成立，但中间态现在是可见、可恢复的回收站，而非立即硬删。

内部附件仍经 `chat_message_file_ref` 引用计数 + FileManager 策略化条目回收兜底：

- 引用计数：`MessageService.replaceChatMessageFileRefsTx` 每次写 parts 时重建引用，`extractChatMessageFileRefs` 收集 file part 与 tool_output 持久化 blob 的引用；
- 策略化回收：`delete_when_unreferenced` 条目有宽限期扫描回收（`src/main/services/file/internal/entryCleanup.ts`），手动条目有孤儿扫描（`src/main/services/file/internal/orphanSweep.ts`，`findManualUnreferenced`）。

回收时机与策略参数未运行验证（静态推断）。

### 3.4 空 Topic 判定：运行时按消息条数

空 Topic 由运行时判定，topic 表上没有对应字段：`ChatContent.tsx:208` 用 `!isHistoryLoading && runtime.messages.length === 0` 判断，为真时叠加 `ConversationGreeting` 欢迎层。因为虚拟根永不出现在读取接口的返回列表里（见 1.2），"空 Topic"= 除虚拟根外没有任何内容消息，跟 topic 行本身是否存在虚拟根无关（虚拟根总是存在）。

### 3.5 切换与恢复

切换 Topic 的数据侧只是换 `activeNodeId` + 重新分页拉取（读侧投影见 5 节）；切换时保留哪些局部 UI 状态（草稿、滚动位置、面板开关）属于 Chat UI 类目。

崩溃恢复由主进程的流管理器承担：`AiStreamManager` 启动时执行一次 boot reconcile，把上次进程崩溃遗留的 `pending` assistant 行统一翻成 `error`，避免界面永久显示"思考中"的冻结气泡；reconcile 完成之前，新的流会等待。相关实现见 `AiStreamManager.ts:497-506,310-313`，配套的查找与批量标记在 `MessageService`。多窗口并发写入、数据库迁移的运行行为本次未验证（见第 10 节）。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 持久层是真实树结构

证据：自引用外键（`message.ts:59`）+ `siblingsGroupId` 兄弟组 + CHECK 约束的虚拟根（见 1.2）；删除时的 `INVALID_OPERATION` 拦截与 reparent 语义（见 1.2）；`createSibling`（`MessageService.ts`，编辑后重发）在源未分组时分配新的兄弟组号、加入已有组时继承组号，并立即把 active 指针移到新行。**消息树是持久层的真实结构，不是渲染层临时拼装的视图。**

### 4.2 "切分支"是 activeNodeId 指针重定向，不是移动/复制消息

- 切换分支在数据侧只是一条更新语句：`TopicService.setActiveNodeTx` 把新的节点 id 写进 topic 行的活动节点列，校验只有两条——目标消息属于该 topic，且目标不是虚拟根（`TopicService.ts`）。
- 渲染时由 `getPathRowsToNodeTx` 从活动节点向上走到虚拟根，并把根本身排除在结果之外；前端看到的"当前分支的完整对话"就是这条每次现算的反向路径，切一次分支就重走一次，系统不维护链表式的指针跳转结构（`MessageService.ts`）。
- **兄弟分支导航与分支面板切换**：`setActiveBranch(throughNodeId)` 先发 GET 请求 `/topics/:topicId/path?nodeId=throughNodeId` 求出该分支的最新叶子，服务端的 `MessageService.getPathThrough` 取创建时间最大、且没有存活子节点的后代，再把活动指针指到那个叶子。这样即使切到中间节点，也能看到它后续的完整追问链；接口注释在 `src/renderer/hooks/chat/ChatWriteContext.ts:66-75`，实现见 `useChatWriteActions.ts:450-479`。读侧组装规则见下：
  - 用户消息按 `siblingsGroupId` 分组；
  - assistant 消息按 `(siblingsGroupId, modelId)` 分组（多模型多轮混合场景按模型分桶）；
  - 实现见 `useTopicMessages.ts:51-60,104-122,136-155`。

### 4.3 发送锚点：持久化预留行（reservation）

"从历史节点开新分支"先持久化一个空 user 叶子（`reserveBranch`），下一次提交用 `fill-reserved` 模式填充同一行（语义见第 2 节）：

- 流式进行中创建的分支预留行带 `activate=false`，正在跑的 active 路径不会被挪动（`useTopicBranchActions.ts:20`）。用户选中该预留行、且 topic 仍处于 live 状态时发送，排队负载会带上预留行 id 并以 `reserved-branch` 模式等到 topic 空闲才提交（`useChatRuntimeState.ts:206-227`）。主进程侧还有一层竞态兜底：流式期间收到该模式的提交一律拒绝（`PersistentChatContextProvider.ts:247-253`）。
- 空叶子的删除带 `awaitingInputOnly=true` 守卫，已经填充的行会被拒绝删除，避免误删一条刚被填充的消息（`MessageService.ts`）。



### 4.4 编辑、删除、重试、翻译的数据变更入口

数据侧入口是 `ChatWriteContext` 的写操作（Home 适配器经 `requireChatWrite('xxx')` 取实现，见 Chat UI 笔记 6.2），最终落在 `MessageService`/`TopicService`：

- 编辑消息由 `editMessage` 发 `PATCH /messages/:id` 请求，落到消息服务的更新方法，其中包含防环校验与虚拟根不可被重新挂父的守卫（`MessageService.ts`）；
- 删除时的 reparent 与虚拟根拦截语义见 1.2；
- 编辑用户消息后的重发由 `forkAndResend` 处理，内部串起 `createSibling` 与 `regenerate-message` 两步（`useChatWriteActions.ts:346-396`）。

**执行链**（重试如何选择起始上下文、重新生成从哪个节点重建请求）见对话请求与上下文笔记第 2、7 节。

### 4.5 版本切换与复制

"复制分支到新 Topic"（分支面板右键菜单）走 `POST /topics/:id/duplicate`，数据语义即 3.1 的 `duplicate()`：新 topic 建虚拟根 + `copyPathRowsTx` 拷贝路径消息（被拷贝的 `pending` 行转为 `error`，因为拷贝后没有流属主，`MessageService.ts`）。版本切换本身不产生新对象，只有指针移动（4.2）。

### 4.6 删除一条分支：按路径而不是按子树

分支图节点菜单提供"删除分支"，走 `DELETE /messages/:id/branch`，由 `MessageService.deleteBranch(selectedId, expectedTopicId)` 在一个写事务里完成。删除范围是从所选节点到其叶子的一条路径，**不是所选子树的全部分支**：即使所选节点下方还挂着其他分支，也只删这一条。

该方法拒绝三类目标：虚拟根、topic 上仅剩的唯一路径，以及所选子树在树接口中被截断（`TREE_OFF_PATH_DEPTH_LIMIT`）因而无法确定叶子集合的情况。被删路径包含 topic 的 `activeNodeId` 时，事务内会把指针移到仍存活的分支。前端入口是 `useTopicBranchActions.deleteBranch`，与空叶子删除（`awaitingInputOnly=true`）是两条不同路由。
## 5. 列表、分页、搜索与定位

- **消息分页**：渲染侧的 `useTopicMessages` 用 `useInfiniteQuery` 从 DataApi 拉取 `/topics/:topicId/messages`，请求带 `includeSiblings: true`，实现位于 `useTopicMessages.ts:184-298`。分页细节分三层：
  - 分支接口按"新页在前"的 before-cursor 方式分页，默认每页 20 条（`MessageService.getBranchMessages`）。分页窗口先由路径 id 算出，只对当前页加载完整行，长路径因此不受 SQLite 绑定变量上限约束（`getPathIdsToNodeTx` 与 `getRowsInOrderTx`）。渲染层再翻转页序，得到从根到活动节点的单调时间序列；
  - 页大小随 `chat.message.navigation_mode` 偏好变化：普通模式每页 50 条，锚点轨模式每页 150 条，该偏好默认取 `'anchor'`（常量 `PAGE_SIZE` 与 `ANCHOR_RAIL_PAGE_SIZE`，`preferenceSchemas.ts:609`）；
  - 活动节点 id 取自最新一页响应的顶层 metadata，第一轮判据所需的 `rootId` 由服务端在每页响应里一并返回（`MessageService.ts`）。
- **全量树接口**：`/topics/:id/tree` 用一次主题查询返回活动路径与截断后的旁支子树，供分支图使用。请求参数已经收敛为只按 topic 查询，按深度、根节点、指定节点过滤的三个选项都从 schema 里移除，旁支深度由常量 `TREE_OFF_PATH_DEPTH_LIMIT` 封顶（见 Chat UI 笔记 6.3）。
- **会话内搜索：数据粗匹配 + DOM 精确 Range**。`MessageListSearch` 先在已加载的消息数据上做粗匹配，再对已挂载的 DOM 求精确 Range，整条路径不经过 FTS 索引，实现见 `src/renderer/components/chat/messages/list/MessageListSearch.tsx`：
  - 数据粗匹配由 `computeMessageSearchMatches` 完成：把每条消息的 text part 投影成纯文本（`markdownToPlainText` 做降级渲染），跳过仍处于 `pending` 的 assistant，多模型回复组按整组只出一个匹配（`messageSearch.ts:120-162`）；
  - DOM 精确匹配用 TreeWalker 求 Range，整词切分交给 `Intl.Segmenter`；节点过滤会跳过按钮、引用和代码块工具栏等界面元素（`src/renderer/utils/contentSearch.ts:40-88`）。
  - 虚拟化窗口外的消息可经粗匹配被找到，导航到未挂载行时 `locateMessage` 把行滚入视口（`MessageListSearch.tsx:337-339`）；
  - 高亮用 CSS Custom Highlight API（`MessageListSearch.tsx:189-199,242-244`，样式 `src/renderer/assets/styles/index.css:227-228`）；
  - 流式期间匹配数据被锁存，流结束才重算（`MessageListSearch.tsx:97-102`）。
- **跨会话全局搜索：FTS**。`app.search` 命令打开 `GlobalSearchPopup`，提供两个端点，组件实现在 `src/renderer/components/layout/AppShell.tsx:80-99`：
  - `/search/contents`：主进程的 `ContentSearchService` 把它分派给普通消息的 FTS 搜索（见 2 节）与 agent 会话搜索；
  - `/search/entities`：覆盖 topic、assistant、agent、session、knowledge 五类对象的名称检索（`EntitySearchService.ts:40-84`）。

  会话内搜索与全局搜索是两套独立实现，前者没有持久化索引，匹配范围限于已加载的数据与已挂载的 DOM。
- **Topic 列表**：分页、排序、搜索三块（分页/加载/空状态呈现属于 Chat UI 类目）：
  - 分页：`/topics` 走无限分页，每页 200 条（`Topics.test.tsx:594,1068` 断言 `useInfiniteQuery('/topics', { limit: 200 })`）；
  - 排序：置顶段按 `pin.orderKey` 排在最前，普通段按 `orderKey` 或创建顺序排列（`TopicService.listByCursor`）；时间分组视图的"最近"排序由渲染层在已加载列表上完成，注释见 `TopicService.ts`；
  - 名称搜索：走 `TopicService.search`，底层是带转义的 LIKE 查询。
## 6. 缓存、一致性、多窗口与并发写入

- **SWR 缓存是读投影**：消息列表由 SWR infinite 缓存驱动，数据变更信号只在命中已加载消息时才触发重验证（`useTopicMessages.ts:257-266`）。execution overlay 的 seed 对数据库行做 `structuredClone` 深拷贝，避免 AI SDK 的原地修改污染缓存与数据库历史引用（见 2 节）。
- **两层 parts 缓存的结构共享**：`useStableMessagePartsLayers` 用 `useRef` 自己实现缓存，数据未变化时直接复用 part 数组和 map 容器的引用；文件头部注释说明仓库不引入全局状态库。实现见 `src/renderer/components/chat/messages/stream/useStableMessagePartsLayers.ts`，渲染侧合并细节见消息渲染器笔记。
- **并发写入**：两个层面分别序列化：
  - 单会话串行：流管理器为每个 topic 持有一把 `dispatchLock`，把从准备分派到发送的整个窗口串行起来（`AiStreamManager.ts:242,309-335`）。代码注释专门解释了这把锁的用途：避免并发 open 与 approval-continue 同时判定"没有 live 流"，从而把占位行变成孤儿；
  - 多模型并行：N 个执行循环同时运行，各自通过独立的持久化监听器与消息服务后端写入自己的占位消息（`PersistentChatContextProvider.ts:362-389`）。

  执行侧语义见对话请求与上下文笔记第 5、8 节。
- **备份恢复写安静期**：`AiStreamManager.pause()`/`drainInFlight()`在备份恢复期间门禁新 turn 准入并等待在途持久化落盘，`dispatch` 在 quiesce 期间返回 `blocked`。这是"多端并发写入"之外的数据一致性机制。
- **多窗口/多端并发写入**：本次未调查（见第 10 节）。

## 7. 迁移、导入导出与保留策略

- **schema 迁移**：仓库有一套 v2 迁移体系，迁移器放在 `src/main/data/migration/v2/migrators/`，主要有两类：
  - `ChatMigrator`：为每个被迁移的 topic 就地创建虚拟根，再把 v1 的物理根重新挂到它下面（`docs/dev/references/chat/message-tree.md:84-85,98`）；
  - `AgentsMigrator`：维护 agent 会话消息，以及这些消息的 `searchableText` 与 FTS 索引（`AgentsMigrator.ts:1194-1203,1625`）。

  FTS 虚拟表与触发器由迁移后脚本重建（`MESSAGE_FTS_STATEMENTS` 幂等，`message.ts:106-111` 注释）。迁移细节与 schema 版本号机制本次未展开。
- **导入导出、备份恢复**：备份（BackupService/AutoBackupService）与恢复的写入安静期机制见 6 节；导入导出 UI 与格式细节本次未调查。
- **保留策略的已知边界**：删除 Topic 不清理磁盘上的图片/附件文件（3.3），但文件条目有引用计数 + 策略化扫描回收兜底，不再是纯遗留缺口；回收时机与宽限参数未运行验证。

## 8. Agent、模型、知识库与附件绑定

- **附件**：附件以 file part 的形式内嵌在消息 parts 中，随消息一起持久化；每个附件对应的 `fileEntryId` 同时写进 `chat_message_file_ref` 引用表（`MessageService.ts`）。渲染侧由 `buildFileParts.ts` 生成这类 part，发送侧的处理见对话请求与上下文笔记第 9 节。
- **知识库范围**：项目用两种 part 表达知识库相关状态，两者都是消息 parts 的组成部分，各自没有独立的关联表：
  - 知识库范围：由 `data-knowledge-scope` part 表达，写入与读取各有对应的访问器，定义在 `uiParts.ts:348`；
  - "清理上下文"边界：由 `data-clear` part 表达，消息渲染时会带上 `isContextBoundary` 标记（`MessageService.ts`）。
- **多模型**：模型归属是消息级绑定，由兄弟组号与 `modelId` 两个字段表达，读侧就按这两个字段分桶（见 4.2）。"这次用哪些模型"是请求参数，不落在 topic 行上，发送前的配置见 Chat UI 笔记第 4 节。assistant 的头像与身份以 `messageSnapshot` 快照存在回复行上，助手被删除后 header 仍能渲染（`PersistentChatContextProvider.ts:101-114`）。
- **Agent 会话**：Agent 侧以 Session 为数据单元，拥有独立消息树和原生上下文绑定；运行时分支与新会话 fork 的交接见 1.3。Home/Agent 共用消息列表契约，各自适配器注入不同的编辑和分支操作（[Chat UI 笔记 6.2](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>)）。

## 9. 当前持久化语义补充

从叶子消息创建分支现在由 `MessageService` 生成真实分支，而不是把新消息错误地附着到原路径的中间节点。Agent 会话另新增持久化的跨会话投递：`AgentSessionDeliveryService` 保存待投递、执行与结果状态，`agent_session_message` 的写入链因此需要同时表示本会话消息和其他会话返回的结果。普通 Topic 与 Agent Session 都有消息树，但分表存储；Agent 另需维护运行时 checkpoint 与原生历史绑定（1.3）。

删除活动节点后，服务层会在 splice/reparent 完成后重新计算 active node，保留仍可达的回复而不是把整条后续链视为被删节点的附属品。数据库还为 message 表上的 user-model 外键增加索引，改善按模型关联与迁移检查的访问路径。投递在重启、多个窗口和大量待投递任务下的实际恢复顺序尚未运行验证。依据：`src/main/data/services/MessageService.ts`、`src/main/ai/agentSession/AgentSessionDeliveryService.ts`、`src/main/data/services/AgentSessionMessageService.ts`、`src/main/data/db/schemas/message.ts`。

删除路径有两处结构性约束。其一，删除整条分支走独立路由 `DELETE /messages/:id/branch`：按"所选节点到其叶子"的一条路径删除，而不是把所选子树里所有分支一起删，且会先排除虚拟根、唯一路径与叶子集合不可确定的情况。其二，`update` 带父子关系校验，自引用与跨 topic 的 parent 都被拒绝，树结构不再依赖调用方自觉。

回收站与清理任务一起改变了"删除"的可观察语义：回收站条目可以恢复，`deletedAt` 为空的行才出现在常规列表与搜索里，清理任务按保留期删除过期条目并保留自己的待处理状态，重启后不会丢失未完成的清理请求。Agent 会话侧另有自己的归档语义：归档的会话可随其 Agent 一起恢复，权限检查按行归属判定。
## 10. 设计取舍与已确认边界

- **三层数据复杂度是有意为之的取舍**：真树结构、活动节点指针与 live overlay 叠成三层，再配合 Home/Agent 两套适配器，撑起了"保留过程、支持分支比较、多模型并行"这些能力。代价是追踪一条消息从输入到渲染要走通至少四层数据——数据库树、SWR 缓存、execution overlay 与 live branch 前端态，调试门槛明显高于单层 session 客户端。
- **虚拟根是存储层不变量**：CHECK 约束与部分唯一索引把"每 topic 一根、根对应空父节点、内容消息必有父节点"固化在 schema 里（1.2）；服务层那些校验只是提供友好错误的入口（`MessageService.ts`）。
- **分支草稿是持久化态**：等待输入的分支本身就是一行数据库记录，即内容为空的 successful user 叶子，`isAwaitingInput` 由结构派生，行上没有 draft 标记。代价是派生出一条额外规则：空叶子必须保持不可见、且不能当普通消息处理（列表隐藏、删除与填充带守卫）。
- **删除语义收敛为"splice 保留可达历史"**：首轮消息可删（子节点挂回虚拟根），多模型组删除只删兄弟回复并把子节点重新挂到共享用户消息下，组删除在回复生成过程中被禁用；`SET NULL` 方案被明确否掉，理由是它会在级联删除中途制造第二个 null-parent 行（`docs/dev/references/chat/message-tree.md:109-112`）。
- **删除 Topic 是两段式**：默认进回收站，靠 `deletedAt` 做软删除；永久删除才清消息行与 topic 行。两段都不主动删磁盘文件，文件条目另由引用计数加策略化扫描回收（3.3）。
- **搜索双轨的边界**：会话内搜索是"已加载数据 + 已挂载 DOM"（流式行被排除、未加载页搜不到，这是分页 + 数据匹配的固有限制）；全局搜索才是持久化 FTS（trigram），命中定位到消息级别，不提供 DOM 级高亮。
- **崩溃恢复有专门路径**：boot reconcile 把遗留 `pending` 翻成 `error`（3.5），加上 `clearActiveNode` 与事务原子性，异常退出后的数据语义是"已提交的写都保留、未提交的回滚、半截回复标为 error"（运行验证见第 10 节）。
- **类目边界**：本笔记只回答数据语义。停止生成时半截消息最终如何落盘、重试如何选择上下文见对话请求与上下文；分支树图、兄弟导航与搜索工作流见 Chat UI；part 渲染、虚拟列表与消息壳装配见消息渲染器。

## 11. 未验证事项

- 崩溃恢复、多窗口竞争、数据库迁移与大数量级 FTS 搜索未做运行验证（静态代码只能确认事务、索引和写入入口，不能代替运行验证）。
- `AiStreamManager` 状态机（`ActiveStream.status` 六种取值）的竞态风险未运行验证，执行侧详见对话请求与上下文笔记。
- FileManager 附件回收的触发时机与宽限参数（`entryCleanup.ts` 的 `ENTRY_CLEANUP_GRACE_MS`）未运行验证。
- 流式期间中间增量落盘的频率未核实（最终态落盘语义见对话请求与上下文笔记第 6 节）。
- schema 版本号演进、迁移执行时机与失败恢复未展开调查。

## 12. 关键源码索引

- `src/shared/data/types/topic.ts`（Topic 模型）
- `src/main/data/db/schemas/message.ts`（消息表、CHECK/索引、FTS 触发器语句）
- `src/main/data/services/TopicService.ts`（CRUD、`setActiveNodeTx`、`listByCursor`、`trashManyByIdsTx`/`purgeManyByIdsTx`/`restore`/`purgeExpiredTx`）
- `src/main/data/services/MessageService.ts`（树维护、`getTree`/`getBranchMessages`/`getPathIdsToNodeTx`/`getRowsInOrderTx`、`reserveBranch`、`createUserMessageWithPlaceholders`、`delete`/`deleteBranch`/`deleteReplyGroup`/`clearTopicMessages`、FTS `search`）
- `src/main/services/TopicNamingService.ts`（自动命名两阶段）
- `docs/dev/references/chat/message-tree.md`（树的权威文档）
- `src/renderer/hooks/useTopicMessages.ts`（分页拉取与兄弟分桶）
- `src/renderer/hooks/useExecutionOverlay.ts`、`src/renderer/services/aiTransport/ExecutionStreamOverlayService.ts`（live overlay）
- `src/renderer/components/chat/messages/list/MessageListSearch.tsx`、`messageSearch.ts`、`src/renderer/utils/contentSearch.ts`（会话内搜索）
- `src/renderer/pages/home/hooks/useTopicBranchActions.ts`（分支预留/删除守卫入口）
- `src/main/services/file/internal/entryCleanup.ts`、`orphanSweep.ts`（附件 GC）
- `src/main/services/trash/{TrashService,trashPurgeJobHandler}.ts`（回收站与保留期清理）
