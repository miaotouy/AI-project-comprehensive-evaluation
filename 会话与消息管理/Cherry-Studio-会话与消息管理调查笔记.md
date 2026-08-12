# Cherry Studio 会话与消息管理调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：从 `../Chat/Cherry-Studio-Chat调查笔记.md`（2026-08-10 调查）迁移现有段落与证据；在 `0001d730ae..cd82f996fb`（177 提交）区间内核对删除语义、空分支节点持久化、overlay 服务化与 message-tree.md 文档更新
>
> 调查范围：Topic/Session/Message 数据模型、事实源与持久化、生命周期、分支语义、分页索引与搜索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **会话单位是 Topic**（`src/shared/data/types/topic.ts`），存储在 SQLite，由 `TopicService`（`src/main/data/services/TopicService.ts`）管理 CRUD。
- **消息不是线性数组，而是 adjacency-list 树**（`message.parentId` 自引用外键），由 `MessageService`（`src/main/data/services/MessageService.ts`）维护，`docs/references/chat/message-tree.md` 是这棵树的权威文档——本次核实文档与代码基本一致，但文档中"Flow canvas 是 forward reference，代码在其他分支"的说法已经**过时**（见第 9 节）。
- 新建 Topic 的同一写事务里就会创建一条虚拟根消息，不存在"没有根消息的 Topic"这种中间态；"空 Topic"是运行时按消息条数判定的，与虚拟根是否存在无关。
- **"切换分支"不是重排树**，而是把 `activeNodeId` 指针指到目标分支的叶子；前端看到的"当前分支的完整对话"每次从 `activeNodeId` 反向 walk 到根。
- 分支草稿改为**持久化空叶子**（`ad0ce9cd04`）：`POST /messages/:id/branches` 落一条空的 successful user 行（`reserveBranch`），等待输入状态由结构派生，不再依赖渲染层假节点；只有流式增量仍是不落库的纯前端 overlay。
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
- 约束在 `MessageService.ts` 里的具体落地：`delete()`（当前约 `:1650-1720`，`8b78177a61` 调整过删除语义）对虚拟根删除请求直接抛 `INVALID_OPERATION`；非 cascade 删除把子节点 reparent 到祖父节点上再删本节点。行为变化：**首轮消息现在可以正常删除**（splice 到虚拟根），**多模型回复组删除**（集合端点）只删除同组兄弟 assistant 并把各组直接子节点 reparent 到共享用户消息下，组内任一回复仍在生成时删除按钮被禁用；`clearTopicMessages` 清空一个 topic 的所有内容消息但保留虚拟根。
- **持久化形状**：数据库直接存储 `UIMessage.parts`（AI SDK 结构），传输、持久化和渲染共享同一种结构；part 的类型清单、`providerMetadata.cherry` 扩展与访问器见消息渲染器笔记（`../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`"消息数据模型"一节）。

## 2. 事实源、索引与持久化

- **权威源是 SQLite**：主进程 `TopicService`/`MessageService` 负责全部 CRUD；renderer 读侧经 DataApi 分页接口，SWR 缓存是缓存投影，不是权威源。
- **活动路径事实源在 topic 行**：`activeNodeId` 由 `setActiveNodeTx`（`TopicService.ts:373-409`）写入，唯一校验是目标消息属于该 topic、且不是虚拟根（`:394-399`）。
- **流式增量 overlay 不落库**：overlay 逻辑已从 `useExecutionOverlay` 抽成窗口级服务 `ExecutionStreamOverlayService`（`src/renderer/services/aiTransport/ExecutionStreamOverlayService.ts`，按 transport `topicId` 引用计数，reader/快照/rAF 批处理都在服务内）；`useExecutionOverlay.ts` 只是 React 绑定（`acquire/release/syncExecutions + useSyncExternalStore`），组件卸载不再拆掉 reader——路由/标签页切换期间 Main 继续生成，重挂载同步恢复 live overlay。reader 种子（seed）仍来自当前 DB 行的深拷贝（`structuredClone` 避免写脏 SWR 缓存），继续审批时合并既有 tool input 的语义不变。
- **分支草稿/发送锚点已是持久化行**：提交 `ad0ce9cd04` 把"从历史节点开新分支"从渲染层假节点改为 `MessageService.reserveBranch(anchorId, activate)`（`MessageService.ts:1099-1134`）：在 anchor（必须是 assistant 消息）下插一条 `role='user'`、`data.parts=[]`、`status='success'` 的空叶子，重复调用同一 anchor 每次都新建行（有意的分支点）；`activate=false` 用于流式期间不挪动 active 指针。等待输入状态由结构派生（`isBlankUserTurn`，`uiParts.ts:363-372`），不落任何 draft 标记。删除/填充都有服务端守卫：`DELETE /messages/:id?awaitingInputOnly=true` 复核目标仍是空叶子（`MessageService.ts:1679-1684`），`createUserMessageWithPlaceholders` 的 `mode: 'fill-reserved'` 在同一事务里填充该行并建 assistant 占位（`MessageService.ts:1152-1153`）。主进程 `PersistentChatContextProvider` 在流式进行时拒绝 reserved-branch 提交（`PersistentChatContextProvider.ts:234-247`），作为渲染层排队的竞态兜底。渲染侧入口是 `useTopicBranchActions`（`src/renderer/pages/home/hooks/useTopicBranchActions.ts`，`POST /messages/:id/branches` + `DELETE /messages/:id?awaitingInputOnly=true`）；`Chat.tsx` 旧的 `branchDraftAnchorIdRef`/`branchSendAnchorOverrideIdRef` 三态 ref 已删除。
- **分支图/列表的合并方向**：`buildTopicMessageFlowLiveState`/`mergeTopicMessageFlowLiveTree` 仍存在，但只叠加"流式中尚未持久化的消息"临时节点；awaiting-input 叶子本身是 DB 节点，直接进 `/topics/:id/tree` 结果（`TreeNode.isAwaitingInput`，`message.ts:565-570`）——分支图 = 持久化树（含空分支叶子）+ 流式 overlay，不再是"假草稿节点"。

## 3. 创建、切换、归档、删除与恢复

### 3.1 新建：同一事务里建虚拟根

`TopicService.create()`（`TopicService.ts:179-205`）在一个写事务里做两件事：`insertWithOrderKey` 插入 topic 行，然后立即调用 `messageService.createRootMessageTx(tx, topicRow.id)` 创建该 topic 的虚拟根消息。`duplicate()`（`TopicService.ts:207-269`）走同一套逻辑：新 topic 先建虚拟根，再用 `copyPathRowsTx` 把源 topic 某条路径的消息拷贝过来并重新挂到新根下。

### 3.2 重命名与自动命名（"单向棋"设计）

- **重命名**：交互入口在 `Chat.tsx:143-162`（`topic.rename` 命令处理器），弹出 `PromptPopup` 取新名字，成功后 `patchTopic(topic.id, { name, isNameManuallyEdited: true })`。`isNameManuallyEdited: true` 是关键——它会关闭自动命名。`TopicService.update()`（`TopicService.ts:272-309`）对应逻辑：`name` 有值时默认把 `isNameManuallyEdited` 设为 `true`（除非显式传 `false`），只传 `isNameManuallyEdited` 时则是"仅调整元数据"的旁路（供迁移/修复用）。
- **自动命名**：由 `TopicNamingService`（`src/main/services/TopicNamingService.ts`）负责，分两阶段：①`maybeRenameFromFirstUserMessage`——第一条用户消息落库后立刻用消息原文截断出一个临时标题；②`maybeRenameFromConversationSummary`——首轮回复完成后用 AI 生成摘要标题替换掉临时标题。两阶段都受 `canAutoRenameTopicName` 把关：topic 名字为空字符串（v2 新建默认值）或者仍等于之前生成的临时标题，才允许继续自动改名；一旦用户手动改过名字（`isNameManuallyEdited`）就永久停止自动命名——不会有"自动改名覆盖用户改名"的情况。提交 `b68fafcaf7` 起摘要生成请求不再携带 `assistantId`——避免把助手的工具配置（MCP/联网/知识库）挂到标题生成请求上。

### 3.3 删除：先消息后关联最后删行；附件回收交给 FileManager GC

`TopicService.delete`/`deleteByIds` → `deleteManyByIdsTx`（`TopicService.ts:334-359`）。删除顺序：先 `messageService.purgeByTopicIdsTx` 清消息，再清 tag、pin 关联，最后删 topic 行本身。

旧的"Clean up associated files from disk"TODO 注释已随 file-manager 治理（`9775f78ed5`）移除：内部附件现在经 `chat_message_file_ref` 引用计数，`FileManager` 的策略化条目 GC（`cleanup_policy`/扫描回收，`src/main/services/file/internal/orphanSweep.ts`，`FileManager.ts`/`orphanSweep.ts` 继续改动）只在引用归零后清理文件条目。也就是说"删除 Topic 不主动删磁盘文件"仍是事实（删除动作本身不做文件清理），但不再是无主泄漏——孤儿文件会进入 GC 的回收范围（静态推断，回收时机与策略参数未运行验证）。

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

### 4.3 发送锚点：持久化预留行（reservation）

"从历史节点开新分支"不再靠渲染层临时锚点，而是先持久化一个空 user 叶子（`reserveBranch`），下一次提交用 `fill-reserved` 模式填充同一行（语义见第 2 节）：

- 分支预留行在流式进行中创建时带 `activate=false`，不挪动正在跑的 active 路径；用户选中该预留行并在 topic 仍 live 时发送，排队负载携带预留行 id，等待 topic 空闲后才提交，主进程侧在 `PersistentChatContextProvider` 拒绝流式期间的 reserved-branch 提交作为竞态兜底（`PersistentChatContextProvider.ts:234-247`）。
- 空叶子的删除带 `awaitingInputOnly=true` 守卫：已填充的行拒绝删除（`MessageService.ts:1679-1684`），避免"删掉一条刚被填充的消息"。

与旧实现（三态 ref 状态机）相比，数据语义从"临时态"变成"持久化结构"，跨重载/重挂载保持不变。

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
- **文档漂移已修复**：`message-tree.md` 的 Flow canvas "forward reference" 说明已随文档更新删除，并新增 "Persisted awaiting-input branches" 一节描述空分支叶子语义。
- **分支草稿从临时态变成持久化态**（`ad0ce9cd04`）：等待输入分支现在是 DB 行（empty successful user leaf），`isAwaitingInput` 由结构派生、无 draft 标记；代价是出现"空叶子必须保持不可见/不可当普通消息处理"的派生规则（列表隐藏、删除/填充带守卫）。
- **删除语义收敛为"splice 保留可达历史"**（`8b78177a61`）：首轮消息可删、多模型组删除只删兄弟回复并 reparent 子节点；组删除在回复生成中被禁用。
- **删除 Topic 的磁盘文件回收交给 FileManager GC**：删除动作本身不做文件清理，但文件条目有引用计数 + 策略化扫描回收（3.3），不再是代码自己承认的纯遗留缺口。
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
- `src/renderer/pages/home/Chat.tsx`（发送锚点、重命名命令）
- `src/renderer/pages/home/hooks/useTopicBranchActions.ts`（分支预留/删除守卫入口）
- `src/renderer/services/aiTransport/ExecutionStreamOverlayService.ts`（流式 overlay 服务化实现）
- `src/renderer/pages/home/ChatContent.tsx`（空会话判定）
- `src/renderer/components/ContentSearch.tsx`（DOM 搜索实现；工作流见 Chat UI）
- `src/renderer/components/chat/flow/topicMessageFlowLiveTree.ts`（live overlay 合并）
