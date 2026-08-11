# LobeHub 会话与消息管理调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`5952f4c3f29ed3bb08dda6fd5fd64d6fffd4d3ae`（分支：`canary`）
>
> 调查方式：从 [`../Chat/LobeHub-Chat调查笔记.md`](../Chat/LobeHub-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：会话定位与消息分桶 key、双层 Store 事实源与同步、消息数据形状与树、消息 CRUD 与分支数据语义、Topic 与消息检索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的会话不是“session_id + topic_id”二元定位，而是多维坐标 `ConversationContext` 压平出的 `messageMapKey` 分桶：

- 同一份消息数据在两个独立的 Zustand store（全局 ChatStore 与会话级 ConversationStore）里各自维护一份“解析后”的展示数据，各自独立调用 `parse()`；两层 store 靠 `onMessagesChange` 单向回调 + `StoreUpdater` 反向同步，没有一致性校验断言。
- 本地消息分桶 key 比服务端缓存 key 更细（多 `documentId`/`subAgentId` 等维度），`query.ts:242-265` 专门写了 `representableBucketKey` 防御逻辑承认两者不同构。
- 消息是带 `parentId/threadId/groupId` 的扁平数组，渲染前重建为树；分支激活指针存在**父消息**的 `metadata.activeBranchIndex` 里，判断逻辑在 `BranchResolver`，UI 只负责改一个整数。
- 工具调用与结果是独立的持久化消息行；删除“组”消息时要连带收集工具结果行的 id 一起删。
- Topic 与消息检索走服务端 BM25；`message.searchMessages` 后端端点本次未找到前端调用。
- 本笔记迁移来源主要是前端代码；Topic 生命周期 CRUD、数据库 schema、多端并发写入等后端与运行行为原调查未覆盖，如实标注。

## 系统边界与数据主链

```text
路由参数 -> useAgentContext 拼出 ConversationContext（agentId/topicId/threadId/groupId?...）
  -> messageMapKey 归一化分桶（main/thread/group/group_agent/page/sub_agent 等 scope）
  -> 全局 ChatStore：dbMessagesMap（原始消息）/ messagesMap（parse 后展示消息）
  -> ConversationProvider 按 key 建会话级 ConversationStore（dbMessages/displayMessages）
  -> 局部 store parse 后经 onMessagesChange 写回全局（全局再 parse）；StoreUpdater 反向回灌
  -> 编辑/删除/分支/审批经 messageService 与服务端交互
  -> 服务端 message:list 缓存 key 与本地方桶 key 不同构（representableBucketKey 防御）
```

边界：消息数据如何变成 `displayMessages`/`flatList` 的三阶段解析算法、虚拟列表窗口化与滚动属于消息渲染器（已有独立笔记 [`../消息渲染器/LobeHub-消息渲染调查笔记.md`](../消息渲染器/LobeHub-消息渲染调查笔记.md)）；发送任务如何读取这些数据、审批如何恢复任务属于对话请求与上下文；界面上的会话导航与操作工作流属于 Chat UI。

## 1. 会话、消息与分支数据模型

### 1.1 会话定位：ConversationContext 与 messageMapKey

聊天页面不是“session_id + topic_id”这种简单二元定位，而是一套多维坐标 `ConversationContext { agentId, topicId, threadId, groupId?, subAgentId?, documentId?, scope? }`，由 `useAgentContext`（`src/features/Conversation/useAgentContext.ts:16-44`）从路由参数 + `useDocumentStore`（页面协作场景下的 `documentId`）拼出。

真正把这坐标“压平”成一个 map key 的是 `messageMapKey`（`src/store/chat/utils/messageMapKey.ts`）：

- `toMessageMapContext`（第 50-117 行）先按优先级把输入归一化成 `{scope, scopeId, topicId, subTopicId, isNew}`：
  - `scope==='page' && documentId` → `page_<agentId>_<documentId>`（第 58-66 行），注释明确指出如果不带 documentId，两个不同文档会被塞进同一个 `page_<agent>_new` 桶，“leak history / queue behind each other's operations”；
  - `threadId && scope==='thread'` → thread 优先（第 71-78 行，Group Chat 场景下 task 会用 SubAgent 的 agentId 建 thread，这里显式说明“优先级”是为了避免和 groupId 混淆）；
  - `groupId` 存在时区分 `group_agent`（子 Agent 在群里的独立消息流，用 `subAgentId` 当 subTopicId）与默认 `group`（第 81-96 行）；
  - 有 `threadId` 但未显式指定 scope 时自动推断为 `thread`（第 99-106 行）；
  - 否则落到 `main`（`sub_agent` scope 会被强制映射回 `main`，第 108-116 行的注释：“same conversation, just different display”）。
- `generateKey`（第 122-146 行）按 `${scope}_${scopeId}[_{topicId}][_{subTopicId}][_new]` 拼字符串。

这套 key 同时被两层 store 使用（见第 2 节），是它们互相定位到“同一份数据”的唯一纽带——没有其它地方做一致性校验。`src/store/chat/slices/message/actions/query.ts:242-265` 里甚至专门为此写了一段防御代码：写回 SWR/IndexedDB 缓存前要重算一个 `representableBucketKey`，因为服务端 `message:list` key 只认 agentId/groupId/threadId/topicId，**不认** `documentId`/`subAgentId` 这些本地专属维度；如果两个 key 不一致就直接跳过写缓存（第 265 行 `if (messagesKey !== representableBucketKey) return;`）——这说明本地分桶方案比服务端缓存 key 更细，两者天然不完全对齐，是需要长期小心维护的耦合点，不是“设计完美”。

### 1.2 消息数据形状与树

消息是扁平数组（`UIChatMessage` 的别名 `Message`，字段含 `id/parentId/threadId/groupId/role/tools/agentId/...`），渲染前经 `conversation-flow.parse()` 重建为树（`packages/conversation-flow/src/`，入口 `parse.ts:23-151`）。树的构建与虚拟消息生成算法本身属于消息渲染器笔记（[`../消息渲染器/LobeHub-消息渲染调查笔记.md`](../消息渲染器/LobeHub-消息渲染调查笔记.md)），本笔记只记录数据形状与数据修复事实：

- `buildHelperMaps`（`indexing.ts:42-119`）产出 `messageMap`（id→message）、`childrenMap`（parentId→子 id 列表）、`threadMap`（threadId→消息列表）、`messageGroupMap`（compare/manual 分组元数据）；thread 是独立话题线，`buildIdTree`（`structuring.ts:11-38`）**过滤掉带 `threadId` 的消息**，不进主干树。
- **压缩组重定向**（`indexing.ts:52-66、76-79`）：如果一条 `role: 'compressedGroup'` 消息的 `lastMessageId`（压缩前链条的最后一条）被其它消息当作 `parentId` 引用，会把这个 parentId 重定向指向压缩组本身的 id，否则压缩后新产生的消息会挂到一个已经被隐藏的消息下面，从树上“消失”。
- **孤儿兜底**（`indexing.ts:80-86`）：如果 `parentId` 指向的消息不在当前查询到的消息集合里（比如分页/局部查询漏掉了祖先），直接把该消息降级为根节点，“so post-compression follow-up chains remain visible instead of being dropped entirely”。
- **dual-form 历史数据形态**（`transformation/MessageCollector.ts`，代码称为 “dual-form”）：assistant 与工具消息的链接关系存在两种历史数据形态——assistant-anchored（新形态，下一步 assistant 是当前 assistant 的非工具子节点，兄弟于 tool 结果）与 tool-anchored（旧形态，下一步 assistant 挂在某个 tool 结果消息下面），`findFlatChainContinuation`（256-286 行）要同时支持两种。
- **分支数据语义**：分支指示器画在**子消息**上，但激活索引存在**父消息**的 `metadata.activeBranchIndex` 里；`BranchResolver`（`transformation/BranchResolver.ts:11-77`）的两个入口 `getActiveBranchId`（IdNode 版本，供 contextTree）和 `getActiveBranchIdFromMetadata`（child-id 数组版本，供 flatList）逻辑一致：优先读 `metadata.activeBranchIndex`；越界等于子节点数时代表“乐观更新中，分支还没创建”，返回 `undefined`；否则退化为“选第一个有子节点的分支”，最后兜底选第一个。

### 1.3 外部对象绑定粒度（可确认部分）

- 附件/文件引用在**消息 metadata 层**绑定：发送时写入 user message 的 metadata（`sendMessage.ts:431-465` 的文件 id 列表、图片/视频预览），编辑器数据（editorData）在 `conversationLifecycle.ts:274-280` 提取为 skills/tools/mentions/文件引用（注入执行语义见对话请求与上下文笔记）。
- 工具调用与结果是**独立的持久化消息行**：删除一个 `assistantGroup`/`supervisor` 时要连 `children[]` 里每个 block 的 id 以及每个 block 里 `tools[].result.id`（工具结果消息）一起收集进删除列表（`crud.ts:302-315`），说明这些是底层 db 行而非渲染期对象。

## 2. 事实源、索引与持久化：双层 Store 架构

这是本类目最关键的一点：**同一份消息数据在两个独立的 Zustand store 里各自维护一份“解析后”的展示数据，而且各自独立调用 `parse()`。**

### 2.1 全局 ChatStore

`src/store/chat/slices/message/initialState.ts:5-38` 定义：

```ts
dbMessagesMap: Record<string, UIChatMessage[]>;   // 原始消息，按 messageMapKey 分桶
messagesMap: Record<string, UIChatMessage[]>;     // parse() 之后的展示消息（含 assistantGroup 等虚拟消息）
```

写入路径有两处，都会各自跑一次 `parse`：
- `message/actions/query.ts` 的 `replaceMessages`（第 105-209 行）：第 197 行 `const { flatList } = parse(reconciled);`，写入 `messagesMap`；同时（第 156-170 行）支持 `preserveWorks` 参数，把旧消息里的 `works` 字段“移植”到新消息上（这是仅在这一处存在的合并逻辑）。
- `message/actions/internals.ts` 的 `internal_dispatchMessage`（第 36-75 行）：第 68 行 `const { flatList } = parse(reconciled);`，用于乐观更新（工具审批、编辑内容等）后的即时重算。

`ConversationArea.tsx`（`src/routes/(main)/agent/features/Conversation/ConversationArea.tsx:66-73`）只从这个全局 store 读 `dbMessagesMap[chatKey]` 这一份**原始**数据，作为 `messages` prop 喂给下面的会话级 Provider。

### 2.2 会话级 ConversationStore

`ConversationProvider.tsx`（`src/features/Conversation/ConversationProvider.tsx:86-130`）用 `<Provider key={contextKey} createStore={...}>`（第 111 行）为每个 `messageMapKey` 创建一个**独立**的 Zustand store 实例——key 变了（切 topic/thread）整个 store 连同其内部状态一起重建。

`store/action.ts` 的 `createStoreAction`（第 63-88 行）在创建时如果拿到 `initialMessages`，会**立即再跑一次 parse**（第 76 行 `displayMessages: parse(initialMessages).flatList`），注释解释这是为了避免 store 重建时先渲染一帧空骨架再“闪现”消息（第 42-54 行的长注释）。

这个局部 store 自己也维护 `dbMessages` / `displayMessages`（`store/slices/data/initialState.ts:3-25`），并在三处独立调用 `parse()`：
- `internal_dispatchMessage`（`store/slices/data/action.ts:97-159`，第 139 行）
- `replaceMessages`（同文件 161-182 行，第 166 行）
- `useFetchMessages` 的 SWR `onData`（197-275 行，第 250 行）

### 2.3 两层之间的同步与引用稳定性

两层 store 之间通过 `onMessagesChange` 回调单向同步：局部 store 每次 `parse` 完之后调用 `get().onMessagesChange?.(messages, get().context)`（`data/action.ts:158`/`181`），这个回调在 `ConversationArea.tsx:127-129` 里被接成 `replaceMessages(messages, { context: ctx })`，写回**全局** ChatStore——全局 store 那边再跑一次自己的 `parse`。反方向（全局 → 局部）靠 `StoreUpdater.tsx`（`src/features/Conversation/StoreUpdater.tsx:79-99`，`useLayoutEffect` 监听 `messages` prop 变化并调用局部 `replaceMessages`）。

**这意味着同一批 `UIChatMessage[]` 在一次“发消息/工具审批/编辑”操作里，`parse()` 这个相对重的三阶段算法（算法细节见消息渲染器笔记）可能被调用两次以上**（局部 store 乐观更新一次，全局 store 落库后再一次，全局 store 再回灌局部 store 又一次）。为了不让每次 `parse` 重建全部对象引用打穿 `memo`/`isEqual`，两边分别调用了同一个补丁函数 `stabilizeReferences`（`store/slices/data/stabilizeReferences.ts:1-15`，本质是 `@tanstack/react-query` 的 `replaceEqualDeep`），注释直言：“`parse()` ... rebuilds the entire displayMessages tree on every dispatch ... That defeats memo ... Walking old vs new and pinning unchanged subtrees back to their previous reference”。也就是说，**parse 本身不保证引用稳定性，稳定性是每个调用点手工“缝”上去的**，且这个补丁在全局 store 那边（`internals.ts`/`query.ts`）看不到被调用——只在局部 `ConversationStore` 里用了。全局 `messagesMap` 每次都是全新对象树。

### 2.4 为什么要分两层（能看出的设计动机）

- 全局状态（`operations`/`operationsByContext`/`operationsByMessage`、`dbMessagesMap`）刻意保持全局，是为了让“多个 Agent/Topic 同时跑生成任务”这件事可行——`ConversationProvider.tsx:70-76` 的文档注释直接写：“Operations are kept global to support multiple agents/topics running in parallel.”
- 局部状态（generation/editing/selection/scroll/virtua 相关、pendingArgsUpdates）放进按 `contextKey` 隔离的 store，是为了让“切换 topic”时这些 UI-only 状态天然被丢弃重置（store 整个换掉），不用手写清理逻辑。（这些 UI-only 状态如何被界面消费属于 Chat UI 笔记。）

## 3. 消息 CRUD 与数据变更语义

说明：迁移来源只覆盖以下操作；Topic 生命周期 CRUD（新建、惰性创建、归档、重命名、删除、恢复）在迁移来源中没有对应调查内容，本笔记不虚构（见第 7 节）。

### 3.1 创建 / 删除 / 工具参数更新（局部 ConversationStore）

`src/features/Conversation/store/slices/message/action/crud.ts`：
- `createMessage`（203-241 行）：先 `createTempMessage` 乐观插入一条 `tmp_xxx` 消息（`internal_dispatchMessage` type `createMessage`），再调 `messageService.createMessage`，成功后用服务端返回的 `result.messages` 整批 `replaceMessages` 覆盖（失败则把临时消息标错误）。
- `deleteMessage`（293-331 行）：如果目标是 `assistantGroup`/`supervisor`，要把 `children[]` 里每个 block 的 id，以及每个 block 里 `tools[].result.id`（工具结果消息）都一并收集进删除列表（302-315 行），保证删掉一个“组”时连带清理所有底层 db 行；单条删走 `messageService.removeMessage`（走父子链重接），批量删走 `removeMessages`。
- `updatePluginArguments`（537-630 行）：更新工具参数时同时乐观更新“工具消息本身”和“父 assistant 消息 tools[] 里的那一条”，并把这次更新的 Promise 记录进 `pendingArgsUpdates`（609-613 行）供后续 `waitForPendingArgsUpdate` 使用——目的是保证“审批/拒绝工具”前，任何正在进行的参数编辑必须先落地，避免竞态。

### 3.2 编辑 / 多选状态（纯局部 UI 状态）

`src/features/Conversation/store/slices/messageState/action.ts`：`toggleMessageEditing`（123-129 行）、多选相关 `enterSelectionMode/selectRange/selectToHere/toggleMessageSelected`（59-141 行，支持类似微信的 shift 范围选择和“选择到这里”）。这些完全是局部 UI 状态，不落库，不经过全局 store；它们如何呈现在界面上属于 Chat UI 笔记。

### 3.3 分支切换的数据语义

局部 `switchMessageBranch`（`store/slices/data/action.ts:184-195`）只是把目标消息的 `parentId` 找出来，调用 `updateMessageMetadata(parentId, { activeBranchIndex })`——分支指示器画在**子消息**上，但激活索引存在**父消息**的 metadata 里，真正的“哪个分支是激活的”判断逻辑在 `BranchResolver`（第 1.2 节）里做，UI 只负责改一个整数。全局 ChatStore 也有一份几乎相同实现：`conversationControl.ts:306-316` 的 `switchMessageBranch` 走 `optimisticUpdateMessageMetadata`。

### 3.4 工具审批的数据层事实（薄转发层）

`src/features/Conversation/store/slices/tool/action.ts` 的 `ToolActionImpl`（16-142 行）里**每一个**方法（`approveToolCall`/`rejectToolCall`/`rejectAndContinueToolCall`/`skipToolInteraction`/`submitToolInteraction`/`cancelToolInteraction`/`submitHeteroIntervention`）都是：等待 `waitForPendingArgsUpdate` → 触发本地 `hooks.onToolApproved/onToolRejected` → **调用 `useChatStore.getState()` 上的同名方法**，把局部 `context` 传过去。真正的业务逻辑（Gateway/本地 client runtime 二分、乐观更新顺序、IPC/tRPC 转发异构 Agent 干预）全部在**全局** ChatStore 的 `conversationControl.ts`，属于对话请求与上下文笔记（[`../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md`](../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md) 第 7 节）。笼统地说“编辑/删除/分支切换/审批 action 都在 Conversation Store 中”，对审批这一项是不准确的，容易让人误判其状态归属。

## 4. 列表、索引与检索

- **Topic 搜索（服务端 BM25）**：`apps/server/src/routers/lambda/topic.ts:854-858` 调用 `TopicModel.queryByKeyword`，`packages/database/src/models/topic.ts:743-765` 并行用 BM25 匹配 Topic 标题和消息内容，再合并返回 Topic 列表。因此用户可以通过 Topic 搜索找到包含关键词的会话，但结果不会直接标出或滚动到命中的具体消息（搜索入口与结果呈现工作流见 Chat UI 笔记）。
- **消息内容搜索端点**：`apps/server/src/routers/lambda/message.ts:526-530` 的 `message.searchMessages` 后端端点（`MessageModel.queryByKeyword`，`packages/database/src/models/message.ts:1872-1883`），本次未找到聊天 UI 对它的调用，不能把它误写成已有的前端消息定位功能。
- **列表分页**：消息/会话列表的客户端分页实现原调查未覆盖，本笔记不虚构；可见列表的数据分页接口属于消息渲染器笔记的记录范围。
- **索引自愈**：conversation-flow 专门有一个 `doctor/diagnose.ts` 模块，用途是“detect and repair message trees the reader cannot fully render”，其实现方式是**真的跑一遍 `parse()`，然后 diff 出 parse 无法渲染的消息**（`diagnose.ts:86-91` 的文档注释）。存在专门的“树医生”模块，说明孤儿工具消息、断裂的 parentId 链、悬空的 signal 回调等异常树形是生产环境中会实际出现的情况，而不是纯理论边界情况。

## 5. 缓存、一致性、多窗口与并发写入

1. **`parse()` 双跑**（第 2 节已展开）：全局 ChatStore 与局部 ConversationStore 各自独立调用 `conversation-flow.parse()`，各维护一份 `displayMessages`/`flatList`，仅靠 `onMessagesChange` 回调单向同步 + `StoreUpdater` 的 `useLayoutEffect` 反向同步。没有看到任何断言/测试保证两份数据在任意时刻完全一致；全局侧的 `replaceMessages`（`query.ts`）支持 `preserveWorks` 合并逻辑，局部侧的同名方法没有——这是两份实现出现语义分叉的一个具体证据点，而不是纯理论风险。
2. **引用稳定性靠手工补丁而非算法本身保证**：`stabilizeReferences`/`replaceEqualDeep` 在局部 store 的三个 parse 调用点都手动包了一层（`data/action.ts:120,142,167,251`），但全局 ChatStore 的两个 parse 调用点（`query.ts:197`、`internals.ts:68`）**没有**做同样处理——意味着全局 `messagesMap` 上的 React 组件如果直接订阅（本次没有找到直接订阅全局 messagesMap 渲染 UI 的路径，UI 主要读局部 store），风险可控；但这也说明“parse 结果引用不稳定”是团队公认要专门绕过的已知缺陷，而不是设计选择。
3. **messageMapKey 与服务端缓存 key 并非同构**：`query.ts:242-265` 里的 `representableBucketKey` 防御逻辑，字面上承认“page/`group_agent` 等 scope 的本地 key 无法被服务端 `message:list` 缓存 key 表达”，所以这些场景下乐观更新完全不写缓存，只能靠下一次真实网络请求纠正——这是一个已知但被绕过而非修复的不一致。
4. **`reconcileAssistantToolLinks`（两处独立调用：`internals.ts:61`、`query.ts:177`）**专门用来修复“assistant.tools[] 弄丢了某条工具引用，但对应的 tool 消息行还在”的情况——注释直接写“an optimistic updateMessage{tools} on the wrong/old assistant during a step boundary can drop the link”，说明流式生成的 step 边界上，`tools[]` 数组和独立的 tool 消息行两份数据保持同步本身就是一个容易出错、需要专门补救的地方。
5. **多窗口/多端并发写入**：原调查未覆盖多窗口与并发写入合并语义，未验证（不虚构）。

## 6. 设计取舍与已确认边界

- 本地分桶 key 的 scope 远比“agentId/topicId/threadId 三元组”复杂：实际存在 main/thread/group/group_agent/page/sub_agent（别名，会被强制映射回 main）等 6+ 种 scope，各自有独立的字段映射和降级规则（详见第 1.1 节），且这套本地 key 与服务端 `message:list` 缓存 key 并不同构。
- `parse()` 在全局 ChatStore 和局部 ConversationStore 两层各自独立运行：一次“发消息/审批/编辑”操作里，`parse()` 可能被调用两次以上，两边各自维护一份 `displayMessages`/`flatList`，仅靠回调同步保持一致（详见第 2 节）。
- 树形数据在生产环境中会出现需要专门修复的异常状态：`doctor/diagnose.ts`、`reconcileAssistantToolLinks`、`stabilizeReferences` 都是针对已知问题的手工补丁（详见第 4、5 节）。
- **类目边界**：本笔记只回答数据语义与持久化形状；发送任务如何读取这些数据、审批如何恢复任务属于对话请求与上下文（[`../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md`](../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md)）；`conversation-flow` 的三阶段解析算法与虚拟消息生成细节、列表窗口化与滚动属于消息渲染器（[`../消息渲染器/LobeHub-消息渲染调查笔记.md`](../消息渲染器/LobeHub-消息渲染调查笔记.md)）。

## 7. 未验证事项

- 全局 `messagesMap` 是否在除 `useOperationState`/`displayMessageSelectors` 之外还有 UI 组件直接订阅渲染（本次没有找到直接消费全局 `messagesMap` 做渲染的组件，主渲染路径都走局部 `ConversationStore` 的 `displayMessages`），若存在，则第 5 节第 2 点的引用稳定性风险影响面会更大——未完全排查全部消费点，此处标注未核实。
- `doctor/diagnose.ts` 生成的修复补丁（`RepairOp`）具体在哪个写路径被自动应用、还是仅用于 `TopicDoctorModal`（`src/features/TopicDoctorModal/Content.tsx`）人工触发修复，本次只读到 `diagnose.ts` 本身前 120 行，未读 `TopicDoctorModal` 和补丁应用逻辑，未核实。
- Topic 生命周期（新建、惰性创建、归档、删除、恢复）、消息数据库 schema 与迁移、导入导出、多窗口/多端并发写入：迁移来源没有对应调查内容，本笔记不虚构。
- 崩溃恢复与保留语义：未调查（原调查未覆盖异常退出与恢复路径）。

## 8. 关键源码索引

- `src/store/chat/utils/messageMapKey.ts`（全文件，7-181）
- `src/features/Conversation/useAgentContext.ts`（16-44）
- `src/store/chat/slices/message/initialState.ts`（5-38）
- `src/store/chat/slices/message/actions/query.ts`（48-309，尤其 105-209, 242-269）
- `src/store/chat/slices/message/actions/internals.ts`（36-91）
- `src/store/chat/slices/message/selectors/displayMessage.ts`（29-309）
- `src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`（66-73, 119-130）
- `src/features/Conversation/ConversationProvider.tsx`（86-130）
- `src/features/Conversation/StoreUpdater.tsx`（49-127）
- `src/features/Conversation/store/action.ts`（63-88）
- `src/features/Conversation/store/slices/data/action.ts`（91-276）
- `src/features/Conversation/store/slices/data/stabilizeReferences.ts`（1-15）
- `src/features/Conversation/store/slices/message/action/crud.ts`（167-638）
- `src/features/Conversation/store/slices/messageState/action.ts`（53-141）
- `src/features/Conversation/store/slices/tool/action.ts`（13-142）
- `packages/conversation-flow/src/indexing.ts`（1-119）
- `packages/conversation-flow/src/structuring.ts`（1-38）
- `packages/conversation-flow/src/transformation/BranchResolver.ts`（1-77）
- `packages/conversation-flow/src/transformation/MessageCollector.ts`（1-674）
- `packages/conversation-flow/src/doctor/diagnose.ts`（1-121+，读取部分）
- `packages/conversation-flow/src/types/shared.ts`（1-64）
- `apps/server/src/routers/lambda/topic.ts`（854-858）
- `packages/database/src/models/topic.ts`（743-765）
- `apps/server/src/routers/lambda/message.ts`（526-530）
- `packages/database/src/models/message.ts`（1872-1883）


