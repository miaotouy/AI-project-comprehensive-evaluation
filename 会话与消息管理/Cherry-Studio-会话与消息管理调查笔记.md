# Cherry Studio 会话与消息管理调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`0001d730aeaf26b8d68baeeb54f258851e7a2aec`（分支：`main`）
>
> 调查方式：从 `../Chat/Cherry-Studio-Chat调查笔记.md`（2026-08-10 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：Topic/Session/Message 数据模型、事实源与持久化、生命周期、分支语义、分页索引与搜索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **会话单位是 Topic**（`src/shared/data/types/topic.ts`），存储在 SQLite，由 `TopicService`（`src/main/data/services/TopicService.ts`）管理 CRUD。
- **消息不是线性数组，而是 adjacency-list 树**（`message.parentId` 自引用外键），由 `MessageService`（`src/main/data/services/MessageService.ts`）维护，`docs/references/chat/message-tree.md` 是这棵树的权威文档——本次核实文档与代码基本一致，但文档中"Flow canvas 是 forward reference，代码在其他分支"的说法已经**过时**（见第 9 节）。
- 新建 Topic 的同一写事务里就会创建一条虚拟根消息，不存在"没有根消息的 Topic"这种中间态；"空 Topic"是运行时按消息条数判定的，与虚拟根是否存在无关。
- **"切换分支"不是重排树**，而是把 `activeNodeId` 指针指到目标分支的叶子；前端看到的"当前分支的完整对话"每次从 `activeNodeId` 反向 walk 到根。
- 草稿分支、流式增量等"还没落库的东西"是渲染层维护的纯前端 overlay，与持久化树是两套数据；分支图看到的是"DB 树 + 一层运行时 overlay 的合并结果"。
- **消息搜索没有持久化全文索引**，搜的是真实渲染出来的 DOM 文本节点，虚拟化窗口外的消息搜不到。

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

会话单位是 Topic（`src/shared/data/types/topic.ts`），存储在 SQLite，由 `TopicService` 管理 CRUD。topic 行携带的关键字段在代码中可见：`name`、`isNameManuallyEdited`（自动命名开关，见 3.2）、`activeNodeId`（活动分支指针，见 4.2——`setActiveNodeTx` 就是一次 `UPDATE topic SET active_node_id = ?`）。"空 Topic 判定"不是 topic 表上的字段，而是运行时按消息条数判定（见 3.4）。

**"是否为第一轮对话"的唯一权威判据是 `rootId`**：`message.parentId === rootId`（`message-tree.md:96-99`），文档显式警告不要用"parent 不在已加载列表里"或 v1 遗留的 `askId` 字段去猜，那两种都不可靠。

### 1.2 消息树：adjacency-list 树，由数据库约束强制

- 每条消息一行，`parentId` 自引用外键（`ON DELETE CASCADE`），`siblingsGroupId` 标记同一 parent 下的多模型/多分支兄弟组（`message-tree.md:16-22`）。
- 每个 topic 恰好一条内容为空的虚拟根（`role='root', parentId=NULL`），由数据库 CHECK 约束 `message_root_parent_check` 强制 `(role='root') = (parentId IS NULL)`（`message-tree.md:51-52`），**不是靠应用层约定**。
- 虚拟根永不出现在 `getBranchMessages`/`getTree` 的返回列表里（`message-tree.md` "Consumer contract" 一节，及 `MessageService.ts:474` `return { nodes: [], ... }`）。
- 约束在 `MessageService.ts` 里的具体落地：`delete()`（约 `:1315-1391`）对虚拟根删除请求直接抛 `INVALID_OPERATION`（`:1340-1341`）；`cascade=false` 的删除会把子节点 reparent 到祖父节点上再删本节点（避免留下悬空树）；`clearTopicMessages`（`:1468-1491`）清空一个 topic 的所有内容消息但保留虚拟根。
- **持久化形状**：数据库直接存储 `UIMessage.parts`（AI SDK 结构），传输、持久化和渲染共享同一种结构；part 的类型清单、`providerMetadata.cherry` 扩展与访问器见消息渲染器笔记（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`"消息数据模型"一节）。

## 2. 事实源、索引与持久化

- **权威源是 SQLite**：主进程 `TopicService`/`MessageService` 负责全部 CRUD；renderer 读侧经 DataApi 分页接口，SWR 缓存是缓存投影，不是权威源。
- **活动路径事实源在 topic 行**：`activeNodeId` 由 `setActiveNodeTx`（`TopicService.ts:373-409`）写入，唯一校验是目标消息属于该 topic、且不是虚拟根（`:394-399`）。
- **流式增量 overlay 不落库**：`useExecutionOverlay.ts:149-379` 为每个正在跑的 `ActiveExecution` 起一个 `readUIMessageStream` reader，产出 `overlay: Record<messageId, parts>` 和 `liveAssistants: CherryUIMessage[]`；reader 种子（seed）来自当前 DB 行的深拷贝（`pickSeed`，`:73-84`，特意 `structuredClone` 避免直接写脏 SWR 缓存）。
- **草稿分支/发送锚点是渲染层临时状态**：`Chat.tsx:82-83` 定义 `branchDraftAnchorIdRef`（正在草稿分支的锚点消息 id）、`branchSendAnchorOverrideIdRef`（草稿被取消后，下一条发送锚定到哪个节点的覆盖值），`getBranchDraftAnchorId()`（`Chat.tsx:216-219`）取值优先级 `draft ?? override`；`handleStartBranchDraft`（`Chat.tsx:243-276`）在内存构造 `draft-branch:<anchorId>` 假节点（`isInputDraft: true`）塞进 `TopicMessageFlowLiveState`（`src/renderer/components/chat/flow/topicMessageFlowLiveTree.ts:23-27`，纯前端结构 `{topicId, activeNodeId, nodes}`）广播出去——这些都只存在于渲染进程，不落库。
- **分支图/列表的合并方向**：`buildTopicMessageFlowLiveState`（`:76-117`）把流式中/尚未持久化的 `CherryUIMessage[]` 转成临时节点，`mergeTopicMessageFlowLiveTree`（`:145-221`）再把这份临时状态叠加到从 `/topics/:id/tree` 拉回来的持久化 `TreeResponse` 上——**分支图看到的从来不是纯 DB 树，而是 DB 树 + 运行时 overlay 的合并结果**（树图导航工作流见 Chat UI 笔记）。
- **历史/overlay 两层 parts 缓存**：`useStableMessagePartsLayers`（`src/renderer/pages/home/hooks/useStablePartsByMessageId.ts:93-161`）生成 `historyPartsByMessageId`（DB parts + 翻译 overlay，不含流式增量）与 `partsByMessageId`（叠加 execution overlay）两张表；文件顶部注释（`:1-39`）专门解释为什么用 `useRef` 手搓这层缓存而不是走 `cacheService`/`Zustand`——仓库明确不引入全局状态库，这是"数据分层"的架构决定（渲染侧的合并与结构共享细节见消息渲染器笔记）。

## 3. 创建、切换、归档、删除与恢复

### 3.1 新建：同一事务里建虚拟根

`TopicService.create()`（`TopicService.ts:179-205`）在一个写事务里做两件事：`insertWithOrderKey` 插入 topic 行，然后立即调用 `messageService.createRootMessageTx(tx, topicRow.id)` 创建该 topic 的虚拟根消息。`duplicate()`（`TopicService.ts:207-269`）走同一套逻辑：新 topic 先建虚拟根，再用 `copyPathRowsTx` 把源 topic 某条路径的消息拷贝过来并重新挂到新根下。

### 3.2 重命名与自动命名（"单向棋"设计）

- **重命名**：交互入口在 `Chat.tsx:143-162`（`topic.rename` 命令处理器），弹出 `PromptPopup` 取新名字，成功后 `patchTopic(topic.id, { name, isNameManuallyEdited: true })`。`isNameManuallyEdited: true` 是关键——它会关闭自动命名。`TopicService.update()`（`TopicService.ts:272-309`）对应逻辑：`name` 有值时默认把 `isNameManuallyEdited` 设为 `true`（除非显式传 `false`），只传 `isNameManuallyEdited` 时则是"仅调整元数据"的旁路（供迁移/修复用）。
- **自动命名**：由 `TopicNamingService`（`src/main/services/TopicNamingService.ts`）负责，分两阶段：①`maybeRenameFromFirstUserMessage`（`:126-148`）——第一条用户消息落库后立刻用消息原文截断出一个临时标题；②`maybeRenameFromConversationSummary`（`:150-200`）——首轮回复完成后用 AI 生成摘要标题替换掉临时标题。两阶段都受 `canAutoRenameTopicName`（`:116-119`）把关：topic 名字为空字符串（v2 新建默认值）或者仍等于之前生成的临时标题，才允许继续自动改名；一旦用户手动改过名字（`isNameManuallyEdited`）就永久停止自动命名——不会有"自动改名覆盖用户改名"的情况。

### 3.3 删除：先消息后关联最后删行，磁盘文件不清理

`TopicService.delete`/`deleteByIds` → `deleteManyByIdsTx`（`TopicService.ts:334-359`）。删除顺序：先 `messageService.purgeByTopicIdsTx` 清消息，再清 tag、pin 关联，最后删 topic 行本身。源码里有一条**明确未完成的 TODO**（`TopicService.ts:316`）："Clean up associated files (images, attachments) from disk"——删除 Topic 目前不会清理磁盘上的图片/附件文件，这是一个真实存在、代码自己承认的遗留问题（影响见第 9 节）。

### 3.4 空 Topic 判定：运行时按消息条数

不是 topic 表上的字段，而是 `ChatContent.tsx:212`：`const isEmptyConversation = !isHistoryLoading && runtime.messages.length === 0`，为真时叠加 `ConversationGreeting` 欢迎层（`ChatContent.tsx:213-219`）。因为虚拟根永不出现在 `getBranchMessages`/`getTree` 的返回列表里，"空 Topic"= 除虚拟根外没有任何内容消息，跟 topic 行本身是否存在虚拟根无关（虚拟根总是存在）。

### 3.5 切换与恢复

切换 Topic 的数据侧只是换 `activeNodeId` + 重新分页拉取（读侧投影见第 5 节）；切换时保留哪些局部 UI 状态（草稿、滚动位置、面板开关）属于 Chat UI 类目。异常退出、崩溃后的数据恢复语义本次未调查（见第 10 节）。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 持久层是真的树

证据（`src/main/data/db/schemas/message.ts` 由 `message-tree.md` 摘要，及 `MessageService.ts` 大量校验代码印证）：自引用外键 + `siblingsGroupId` 兄弟组 + CHECK 约束的虚拟根（见 1.2）；删除时的 `INVALID_OPERATION` 拦截与 reparent 语义（见 1.2）。**树是真实的，不是线性链表/锚点跳转的伪装。**

### 4.2 "切分支"是 activeNodeId 指针重定向，不是移动/复制消息

- `TopicService.setActiveNodeTx`（`TopicService.ts:373-409`）就是一次 `UPDATE topic SET active_node_id = ?`，唯一的校验是目标消息属于该 topic、且不是虚拟根（`:394-399`）。
- 渲染时走 `getPathRowsToNodeTx`：从 `activeNodeId` 往上走到虚拟根为止，虚拟根本身被排除在结果外（`message-tree.md:100-101`）。所以前端看到的"当前分支的完整对话"= 从 `activeNodeId` 反向 walk 到根的路径，**每次切分支都要重新 walk 一次**，不是维护什么链表指针跳转结构。
- **兄弟分支导航 `< i/N >`**：`useTopicMessages.ts:43-147` 里 `bucketAssistantSiblingsByModel`/`buildSiblingsMap` 按 `siblingsGroupId`（用户消息）或 `(siblingsGroupId, modelId)`（assistant 消息，多模型多轮混合场景下按模型分桶）把兄弟组装出来；真正切换分支执行的是 `ChatWriteActions.setActiveBranch(throughNodeId)`（`ChatWriteContext.ts:59-67`，实现在 `useChatWriteActions.ts:364-393`）：先 GET `/topics/:id/path?nodeId=throughNodeId` 找到该分支当前的 leaf id，再 `setActiveNodeTrigger` 把 `activeNodeId` 指到那个 leaf——本质仍是"找到目标分支最新的叶子，把指针指过去"，而不是切换到 `throughNodeId` 本身（这样切到某个中间节点也能看到它后续的完整追问链）。

### 4.3 发送锚点：草稿分支的三态机制

"branch draft anchor / 发送锚点"是渲染层为"还没落库的东西"搭的临时状态，但它**决定下一条消息持久化时挂到哪个 parent**：

- `getBranchDraftAnchorId()`（`Chat.tsx:216-219`）取值优先级：`branchDraftAnchorIdRef.current ?? branchSendAnchorOverrideIdRef.current`——一个三态机：都为空=正常发送；draft 有值=正在从某历史节点开草稿分支；override 有值=草稿被取消但要求下一条消息挂到指定节点而非当前 activeNode。
- `handleStartBranchDraft`（`Chat.tsx:243-276`）：先 PUT `/topics/:id/active-node` 把 DB 指针挪过去，再在内存里构造 `draft-branch:<anchorId>` 假节点广播给分支面板（数据侧的临时性见第 2 节；按钮与面板工作流见 Chat UI 笔记）。
- 这是一个容易踩坑的隐式状态机（脆弱性见第 9 节）。

### 4.4 编辑、删除、重试、翻译的数据变更入口

数据侧入口是 `ChatWriteContext` 的写操作（Home 适配器经 `requireChatWrite('xxx')` 取实现，见 Chat UI 笔记 6.2），最终落在 `MessageService`/`TopicService`（删除的 reparent、虚拟根拦截语义见 1.2）。**执行链**（重试如何选择起始上下文、重新生成从哪个节点重建请求）见对话请求与上下文笔记第 2、7 节。

### 4.5 版本切换与复制

"复制分支到新 Topic"（分支面板右键菜单）走 `POST /topics/:id/duplicate`，数据语义即 3.1 的 `duplicate()`：新 topic 建虚拟根 + `copyPathRowsTx` 拷贝路径消息。版本切换本身不产生新对象，只有指针移动（4.2）。

## 5. 列表、分页、搜索与定位

- **消息分页**：`useTopicMessages.ts:178-271` 从 DataApi 分页拉取 `/topics/:topicId/messages`（`includeSiblings: true`），映射成 `uiMessages`——数据库历史由 SWR 缓存驱动，`activeNodeId`/`rootId` 取自最新一页的顶层 metadata（`:213-214`）。
- **全量树接口**：`/topics/:id/tree`（`depth=-1`），供分支图使用（见 Chat UI 笔记 6.3）。
- **搜索：没有持久化全文索引**。`ContentSearch`（`src/renderer/components/ContentSearch.tsx`）用 `document.createTreeWalker` 遍历**真实渲染出来的文本节点**（`findRangesInTarget`，`ContentSearch.tsx:57-135`），不是消息数据模型里的字符串——折叠/未渲染的内容搜不到，虚拟化列表窗口外的消息也搜不到（因为还没挂载到 DOM）。这是"虚拟化 + DOM 搜索"组合下的固有限制，不是 bug（影响见第 9 节）。搜索入口、过滤规则、高亮与跳转工作流见 Chat UI 笔记 2.3。
- **Topic 列表**的分页/加载/空状态呈现属于 Chat UI 与源笔记的通用界面盘点（见 Chat UI 笔记 2.1）。

## 6. 缓存、一致性、多窗口与并发写入

- **SWR 缓存是读投影**：`useTopicMessages` 由 SWR 缓存驱动；execution overlay 的 seed 用 `structuredClone` 深拷贝，避免 AI SDK 的原地修改污染 SWR/数据库历史引用（2 节）。
- **两层 parts 缓存的结构共享**：`useStableMessagePartsLayers` 用 `useRef` 手搓，未变化时复用 part 数组和 map 容器引用；仓库不引入全局状态库（`useStablePartsByMessageId.ts:1-39` 注释）。渲染侧合并细节见消息渲染器笔记。
- **并发写入**：`AiStreamManager` 用 `dispatchLock` 序列化并发 dispatch（代码注释专门解释了为什么需要它）；多模型场景 N 个 `runExecutionLoop` 并行、各自经自己的 `PersistenceListener`/`MessageServiceBackend` 写各自的占位消息（`PersistentChatContextProvider.ts:263-289`）——执行侧语义见对话请求与上下文笔记第 5、8 节。
- **多窗口/多端并发写入**：本次未调查（见第 10 节）。

## 7. 迁移、导入导出与保留策略

- 数据库 schema 版本与迁移代码：本次未调查。
- 导入导出、备份恢复：本次未调查。
- **保留策略的已知缺口**：删除 Topic 不清理磁盘上的图片/附件文件（3.3 的 TODO），长期使用可能造成孤儿附件堆积。

## 8. Agent、模型、知识库与附件绑定

- **附件**：以 file part 内嵌在消息 parts 里（`buildFileParts.ts:53` 生成，发送侧见对话请求与上下文笔记第 9 节），随消息一起持久化。
- **知识库范围**：以 `uiParts.ts:333-361` 的 data part（`data-knowledge-scope`）表达，是消息 parts 的一部分，而非独立关联表；类型清单见消息渲染器笔记。
- **多模型**：`siblingsGroupId` 与 `modelId` 是消息级绑定字段（读侧按 `(siblingsGroupId, modelId)` 分桶，见 4.2）；"这次用哪些模型"本身是请求参数，不持久化在 topic 行（发送前配置见 Chat UI 笔记第 4 节）。
- **Agent 会话**：Agent 侧同样以 session topic 为数据单元，消息数据模型与 Home 同源（同一 `MessageListProvider` 契约）；两边的差异在能力注入层而非数据层（Home/Agent 适配器见 Chat UI 笔记 6.2）。Agent 工作区文件等外部对象的持久化本次未展开。

## 9. 设计取舍与已确认边界

- **三层数据复杂度是有意为之的取舍**：真树结构 + `activeNodeId` 指针 + live overlay 三层，配合 Home/Agent 双适配器，让"保留过程、支持分支比较、多模型并行"这些能力得以实现；代价是要理解至少四层数据（DB 树、SWR 缓存、execution overlay、live branch 前端态）才能追踪一条消息从输入到渲染的完整生命周期，调试门槛明显高于单层 session 客户端。
- **文档漂移**：`message-tree.md` 里 Flow canvas 一节标注为"forward reference，代码在 feat/chat-page 集成分支"，但当前快照 `TopicMessageFlowCanvas.tsx`、`topicMessageFlowGraph.ts`、`topicMessageFlowLiveTree.ts` 等文件已经完整存在并正常工作——文档没跟着代码合并更新，属于 stale doc note。
- **删除 Topic 不清理磁盘文件**：`TopicService.ts:316` 的 TODO 是代码自己承认的功能缺口。
- **消息搜索的 DOM 局限被架构放大**：虚拟化列表意味着窗口外的消息节点根本没挂载到 DOM，`ContentSearch` 的 `TreeWalker` 搜索天然搜不到（5 节）。
- **类目边界**：本笔记只回答数据语义。停止生成时半截消息最终如何落盘、重试如何选择上下文见对话请求与上下文；分支树图、兄弟导航与搜索工作流见 Chat UI；part 渲染、虚拟列表与消息壳装配见消息渲染器。

## 10. 未验证事项

- 崩溃恢复、多窗口竞争、数据库迁移与大数量级搜索未做运行验证（静态代码只能确认事务、索引和写入入口，不能代替运行验证）。
- `AiStreamManager` 状态机（`ActiveStream.status` 六种取值）的竞态风险未运行验证，执行侧详见对话请求与上下文笔记。
- 流式期间中间增量落盘的频率未核实（最终态落盘语义见对话请求与上下文笔记第 6 节）。

## 11. 关键源码索引

- `src/shared/data/types/topic.ts`（Topic 模型）
- `src/main/data/services/TopicService.ts`（CRUD、`setActiveNodeTx`、`deleteManyByIdsTx`）
- `src/main/data/services/MessageService.ts`（树维护、`getPathToNode`、`delete`/`clearTopicMessages`）
- `src/main/services/TopicNamingService.ts`（自动命名两阶段）
- `docs/references/chat/message-tree.md`（树的权威文档）
- `src/renderer/hooks/useTopicMessages.ts`（分页拉取与兄弟分桶）
- `src/renderer/hooks/useExecutionOverlay.ts`（live overlay 与 seed）
- `src/renderer/pages/home/hooks/useStablePartsByMessageId.ts`（两层 parts 缓存）
- `src/renderer/pages/home/Chat.tsx`（发送锚点 ref、重命名命令）
- `src/renderer/pages/home/ChatContent.tsx`（空会话判定）
- `src/renderer/components/ContentSearch.tsx`（DOM 搜索实现；工作流见 Chat UI）
- `src/renderer/components/chat/flow/topicMessageFlowLiveTree.ts`（live overlay 合并）
