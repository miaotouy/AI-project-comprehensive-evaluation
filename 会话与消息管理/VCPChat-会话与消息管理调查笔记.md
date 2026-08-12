# VCPChat 会话与消息管理调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支：`main`）
>
> 调查方式：原文段自 [`../Chat/VCPChat-Chat调查笔记.md`](../Chat/VCPChat-Chat调查笔记.md)（2026-08-05 调查）迁移；基于当前 HEAD 的静态源码核对 chatHandlers.js 行号，并补充新增的 VCP-CDS 子系统
>
> 调查范围：会话与话题（Topic）的数据模型、消息字段、持久化格式、生命周期（创建/切换/选择）、列表索引与检索、未读计数、并发写入与一致性；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 以 **Agent 或 AgentGroup（群组）为一级会话主体、Topic（话题）为二级会话单位**，均为本地持久化的业务对象：

- 每个 Topic 对应磁盘上独立的 `history.json`；Agent/群组配置里的 `topics[]` 数组只存元数据（`id/name/createdAt/locked/unread/creatorSource`），消息内容全部落在 `UserData/<agentId 或 groupId>/topics/<topicId>/history.json`（第 1、2 节）。
- 打开 Topic 的优先级为 **Flowlock 锁定 Topic > localStorage 记忆 Topic > 最新创建的 Topic（数组首位）**（3.1）。
- 默认话题存在两条创建路径，产生的 id 格式不一致（`"default"` vs `"topic_<timestamp>"`），是历史遗留的不一致点（3.3）。
- `history.json` 是**裸数组 + 整份覆盖写**，没有 schema 版本、增量写入或原子写保护（2.2）。
- 自动未读只在"话题历史尚无用户消息"时按 assistant 消息数计数，用户参与后归零；持久化标记带 `unreadSource` 来源区分，手动标记保留、Agent/TopicSponsor 旧标记在用户参与后清除（5.3）。
- 话题内容搜索只匹配字符串型 `content`，多模态数组内容匹配不到（5.2）。
- 群聊历史写盘在多次调用之间**没有文件锁或版本号校验**，理论上存在互相覆盖写丢消息的风险（6.1）。

## 系统边界与数据主链

```text
Agent/群组配置（topics[] 数组，仅元数据）
  -> selectItem / selectTopic 决定当前 Topic（Flowlock > localStorage > 最新创建）
  -> 消息事实源：UserData/<agentId|groupId>/topics/<topicId>/history.json（裸 JSON 数组）
  -> 读取：chatManager.js loadChatHistory / 各 IPC handler 逐文件读
  -> 写入：chatHandlers.js、groupchat.js 各阶段 fs.writeJson 整份覆盖；渲染进程另有 1 秒防抖
  -> 索引：topic 列表（前端过滤 + searchTopicsByContent 内容检索 + "未读话题"置顶）、未读计数（自动计数 + unreadSource 持久化标记）
  -> 现场恢复：settings.json 的 lastOpenItemId/lastOpenTopicId + localStorage lastActiveTopic_*
```

边界：上下文拼装、群聊调度、中断/超时、半截流最终化与落盘时机的执行语义属于对话请求与上下文（[`../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)）；会话侧栏、拖放排序、搜索入口、右键菜单等界面工作流属于 Chat UI（[`<../Chat UI/VCPChat-ChatUI调查笔记.md>`](<../Chat UI/VCPChat-ChatUI调查笔记.md>)）；消息内容与气泡渲染属于消息渲染器（[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md)）。

## 1. 会话、消息与分支数据模型

### 1.1 两级会话单位：Agent/群组 → Topic

聊天以 **Agent 或 AgentGroup（群组）** 为一级会话主体，二级是 **Topic（话题）**。每个 Topic 对应磁盘上独立的 `history.json`，Agent/群组配置里的 `topics` 数组只存元数据（id/name/createdAt/locked/unread），实际消息内容全部落在 `UserData/<agentId 或 groupId>/topics/<topicId>/history.json`。

### 1.2 消息对象字段全集

`history.json` 文件内容是一个 JSON 数组，每条消息是一个对象，字段随场景略有不同，综合各写入点可得到字段全集：

- 通用字段：`role`（'user'|'assistant'|'system'）、`content`（字符串或 `{text}`，assistant 流式结束后是纯字符串）、`timestamp`、`id`。
- user 消息还有：`name`、`attachments`（数组，每项含 `type/src/name/size/_fileManagerData` 等，见 `modules/chatManager.js:992-1002`）。
- assistant 消息还有：`name`、`avatarUrl`、`avatarColor`、`isThinking`（流式过程中临时为 true，落盘前被 `streamManager.finalizeStreamedMessage` 置为 `false`，`modules/renderer/streamManager.js:2279`）、`finishReason`（`:2278`）。
- 群聊 assistant 消息额外带：`agentId`、`model`、`modelSource`（`'group_unified'` 或 `'agent'`，见 `Groupmodules/groupchat.js:950`）、`isGroupMessage: true`、`groupId`、`topicId`、`interrupted`（用户中断时为 true，`:1033`）。
- Agent 配置里的 `topics[]` 元素字段：`id, name, createdAt, locked（默认 true）, unread（默认 false）, creatorSource`（`modules/ipc/chatHandlers.js:492-499` 的兼容归一化逻辑）。

### 1.3 分支数据语义

原调查仅在消息右键菜单中记录"创建分支"入口（`modules/renderer/messageContextMenu.js`，工作流见 Chat UI 笔记），**分支在数据层如何表示（树、指针还是复制）未在原调查中核实**，本文不虚构分支模型。

## 2. 事实源、索引与持久化

### 2.1 文件路径规则

路径规则（agent）：`UserData/<agentId>/topics/<topicId>/history.json`（`modules/ipc/chatHandlers.js:483`，`:505-506`）；群组同构：`UserData/<groupId>/topics/<topicId>/history.json`（`Groupmodules/groupchat.js:159`, `:500`, `:1770`, `:1825`）。

### 2.2 裸数组、整份覆盖写、无原子写

`history.json` 本身没有 schema 版本号或额外的 wrapper，就是裸数组，`fs.writeJson(file, history, {spaces:2})` 直接整份覆盖写（例如 `modules/ipc/chatHandlers.js:506`、`Groupmodules/groupchat.js:539`），**没有增量写入或原子写保护**（没见到先写临时文件再 rename 的模式）——如果写入过程中进程崩溃，理论上可能截断成非法 JSON，这是潜在风险点（未在代码里发现任何缓解措施，标注为"未核实是否曾经出问题"，但从实现上看确实缺乏保护）。

### 2.3 topics 元数据数组是会话级索引

Agent/群组配置中的 `topics[]` 是唯一的话题级索引：`id, name, createdAt, locked（默认 true）, unread（默认 false）, creatorSource`（`modules/ipc/chatHandlers.js:538-543` 的兼容归一化逻辑）。话题列表、未读标记、最后打开状态均以该数组 + 各 `history.json` 为数据来源。

### 2.4 最后打开状态持久化

切换话题成功后会写 `localStorage.setItem(lastActiveTopic_...)`（`modules/chatManager.js:525`）并调用 `_saveLastOpenState()` 把 `lastOpenItemId/lastOpenItemType/lastOpenTopicId` 存进 `settings.json`（`modules/chatManager.js:275-292`，`526`）——这是"最后打开状态持久化"的具体落点。

## 3. 创建、切换、归档、删除与恢复

### 3.1 Agent/群组选择 → Topic 加载判断顺序

`chatManager.js` 的 `selectItem(itemId, itemType, ...)`（`modules/chatManager.js:352-481`）：

1. 先停掉上一个 item 的文件监听器（`electronAPI.watcherStop()`，`:356-358`）。
2. 拉取该 item 的话题列表：agent 走 `electronAPI.getAgentTopics`，群组走 `electronAPI.getGroupTopics`（`:412-416`）。
3. 若话题列表非空，按以下**优先级**决定要打开哪个 topic（`:418-430`）：
   - 默认取 `topics[0].id`（数组第一个，因为新建话题会 `unshift` 到最前面，所以实际是"最近创建的话题"）；
   - 若是 agent 类型，检查 Flowlock 锁定：`window.flowlockManager?.getLockedTopicId?.(itemId)`（`:420-422`），若锁定的 topic 仍存在于列表中则**优先**使用它（`:425-426`）；
   - 否则检查 `localStorage.getItem(\`lastActiveTopic_${itemId}_${itemType}\`)`（`:423`），若存在且在列表中则使用它（`:427-428`）。
   - 即优先级为：**Flowlock 锁定 topic > localStorage 记忆 topic > 最新创建的 topic（数组首位）**。
4. 若话题列表为空：
   - agent：先 `getAgentConfig(itemId)` 确认没有 topics，再调用 `createNewTopicForAgent(itemId, "主要对话")` 建立默认话题（`:438-454`）；
   - group：直接调用 `createNewTopicForGroup(itemId, "主要群聊")`（`:458-467`）。

### 3.2 selectTopic 与 Flowlock 阻止切换

`selectTopic(topicId)`（`modules/chatManager.js:483-537`）在用户主动点击话题列表项时被调用，同样会先检查 Flowlock：如果当前 agent 被锁定且要切换到的 topic 不是锁定的那个，直接 toast 提示并 `return`，阻止切换（`:485-495`）。切换成功后会写 `localStorage.setItem(lastActiveTopic_...)`（`:525`）并调用 `_saveLastOpenState()`（2.4）。

### 3.3 默认话题创建的两条路径与 id 不一致

Agent 侧存在**两条**创建默认话题的路径——`modules/ipc/agentHandlers.js` 的 `create-agent` handler 在新建 Agent 时会直接写入 `topics: [{ id: "default", name: "主要对话", createdAt: ... }]`（`modules/ipc/agentHandlers.js:430`），话题 id 固定为字符串 `"default"`；而 `chatManager.js` 里 fallback 创建时调的是 `createNewTopicForAgent`，其 id 格式是 `topic_${Date.now()}`（`modules/ipc/chatHandlers.js:555`）。两条路径产生的默认话题 id 格式不一致（`"default"` vs `"topic_<timestamp>"`），是历史遗留的不一致点，非致命但值得注意。

### 3.4 归档、删除与恢复

话题右键菜单提供重命名、删除、标记已读等入口（见 Chat UI 笔记），但其**数据侧实现（删除是否连同 `history.json` 一起移除、是否有恢复机制）未在原调查中核实**，本文如实标注，不虚构。

## 4. 编辑、重试、续写、回退与分支语义

原调查未覆盖消息编辑、重试、续写在数据层的变更语义：

- 消息右键菜单提供"编辑、重新回复、创建分支、转发、朗读、阅读模式、删除"等入口（`modules/renderer/messageContextMenu.js`，工作流见 Chat UI 笔记），但编辑后是修改原对象还是新建消息、分支如何落盘，**未在原调查中核实**。
- AI 续写（Flowlock）与"重新回复"的请求重建语义属于对话请求与上下文类目，数据变更是否与普通发送一致**未核实**；Flowlock 状态机本身见源文件 `Flowlockmodules/flowlock.js`。

## 5. 列表、分页、搜索与定位

### 5.1 话题列表数据来源与排序落地

`loadTopicList()`（`modules/topicListManager.js:498-616`）读取 `#topicSearchInput` 的值经 `parseTopicSearchQuery` 解析为普通搜索词或"未读话题"置顶约定词（`:533` 起）。

拖放排序结束时 `onEnd`（`topicListManager.js:660` 起）拿到新顺序的 `topicId` 数组后调用 `saveTopicOrder`（agent，`:674`）或 `saveGroupTopicOrder`（group，`:676`），对应 IPC 在 `modules/ipc/chatHandlers.js:345-377`（agent，用 `agentConfigManager.updateAgentConfig` 重排 `topics` 数组）和同文件 `:378-407`（group，直接读写 `config.json`）。排序失败会 toast 报错并 `loadTopicList()` 回滚展示（`topicListManager.js:680-693`）。拖拽交互本身（SortableJS 初始化、与划词监听的冲突处理）见 Chat UI 笔记。

### 5.2 搜索：前端过滤 + 后端内容检索的并集

搜索是**前端过滤 + 后端内容检索的并集**：

- 前端过滤：对 `topic.name`（经 `normalizeTopicTitle` 归一化）和格式化后的创建时间字符串做 `includes` 匹配（`modules/topicListManager.js:560-575`）；
- 后端内容检索：调 `electronAPI.searchTopicsByContent(itemId, itemType, searchTerm)`（`:577`），实现在 `modules/ipc/chatHandlers.js:408-451`，会遍历该 item 所有 topic 的 `history.json`，对每条消息 `message.content` 做 `toLowerCase().includes()`（`:435`）。**注意**：这里只处理 `typeof message.content === 'string'` 的情况（`:435`），如果消息 content 是多模态数组（`[{type:'text',text:...}]`），这条内容检索会直接跳过、匹配不到——这是一个实际的搜索盲点。当前 HEAD 的 VCP-CDS（Tantivy 全文索引，见 6.4 节）**没有**接入该搜索路径。
- 两路结果取并集（`modules/topicListManager.js:592-595`）。

搜索入口、结果列表与"搜索状态下不启用拖拽排序"的界面行为见 Chat UI 笔记。

### 5.3 未读标记：自动计数 + 带来源的持久化标记

两套机制并存，逻辑在前端和后端各自重复实现了一份（`topicListManager.js:47-106` 与 `chatHandlers.js:1325-1368` 逐行相同）：

- **自动计数**（"Agent 主动发起、尚无用户参与的话题"）：`countUnreadMessages(history)` 过滤掉 `role==='system'` 与 `isThinking===true` 的消息后，**只要历史中出现任何 `role==='user'` 消息就返回 0**；否则返回全部 assistant 消息条数（`topicListManager.js:91-102`、`chatHandlers.js:1325-1340`）。即自动未读现在覆盖"Agent 在无人回应的新话题里连续说了多条"的整个阶段，用户一旦发言即归零；旧的"非系统消息恰好只有 1 条且为 assistant"硬编号条件（`shouldActivateCount`）已被删除。注意历史消息的 `isThinking` 在落盘前被置 false（6.3），故历史里通常只有流式瞬时占位才带 `isThinking:true`。
- **持久化标记与来源**：右键菜单"标记为未读/已读"调用 `electronAPI.setTopicUnread(itemId, topicId, !isUnread)`（`topicListManager.js:841-855`），写入 `topic.unread` 字段；标记未读时同时写 `topic.unreadSource = 'manual'`，清除时删除该字段（`chatHandlers.js:1501-1526`）。Agent/TopicSponsor 等插件侧写入的旧标记没有 `unreadSource`，被视为"过期自动标记"：只要历史已有用户参与就失效。
- 汇总函数 `calculateTopicUnreadCount(topic, history)`（`topicListManager.js:206-211`）：自动计数 >0 返回数字；否则 `topic.unread===true` 且（`unreadSource==='manual'` 或无用户参与）时返回 `-1`（小点）；否则 0。UI 侧据此给 `.message-count` 加 `has-unread`（数字）/`unread-marker-only`（小点）class，并维护 `.topic-unread-indicator`（"未读 N"/"未读"文本）与 `has-unread-topic` class（`ensureTopicUnreadIndicator/removeTopicUnreadIndicator`，`topicListManager.js:178-198`）。
- **失效标记主动清理**：前端在列表渲染（`clearStalePersistentUnreadMarker`，`topicListManager.js:63-88`，`loadTopicMessageCount` `:292`）与用户发送消息（`chatManager.js:1037-1055` 调 `setTopicUnread(false)`）两条路径上清除"非 manual 且已有用户参与"的持久化未读标记。
- **"未读话题"置顶**：搜索框完整输入"未读话题"或"unread topic"时（`parseTopicSearchQuery`，`topicListManager.js:128-142`），跳过文本搜索，由 `prioritizeUnreadTopics` 读取每个话题历史并重排：自动未读数 >0 或持久化标记有效的话题移到顶部，组内保持用户自定义顺序（`:143-175`，`loadTopicList` 内应用点 `:599`）；搜索框占位提示与 `aria-label` 同步更新（`main.html:213-216`、`topicListManager.js:513`）。

### 5.4 延迟计数：IntersectionObserver 摊平 IO

每个话题列表项创建时先把 `message-count` 文本设为占位符 `'...'`（`topicListManager.js:351`），并 `ensureTopicCountObserver().observe(li)`（`:370`）。Observer 用 `rootMargin: '240px 0px', threshold: 0.01`（`:252-253`），条目滚入视口附近时才触发 `loadTopicMessageCount(li)`（`:259-310`），该函数据 `li.dataset` 读取 `itemId/itemType/topicId`，异步拉取该话题完整 `history.json` 算未读数（并顺带清理失效持久化标记，`:292`）和总消息数，**触发一次后立即 `unobserve`**（`:247`）且用 `dataset.countLoaded` 防止重复加载。这个设计的意义是：列表可能有大量话题，如果一次性给每个话题都发一次 IPC 读取历史文件会造成打开列表时的 IO 风暴，用 IntersectionObserver 把这个成本摊到"用户实际滚动到看见"的时刻。列表本身的渐进渲染策略（初始 40 条、触底批量追加 30 条、requestAnimationFrame 分帧）见 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

### 6.1 群聊写盘：单次调用内串行、多次调用之间无锁

`handleGroupChatMessage`（`Groupmodules/groupchat.js:477-1118`）内部，`agentsToRespond` 列表用**普通 `for...of` 循环 + 每次内部 `await`** 串行处理（`:579`起，注释明确写"按顺序让选中的 Agent 发言 (严格串行处理)"，`:578`）。关键在于：

- 循环体内每个 agent 的上下文构建（`contextForAgentPromises`，`:611-719`）都是基于**同一个内存变量 `groupHistory` 数组**的当前状态，而不是每次重新读盘（尽管注释里讨论过"频繁读写文件"的取舍，`:585-591`，但最终实现选择了内存数组 + 各阶段写盘）；
- 每个 agent 说完话后，无论流式还是非流式，都会 `groupHistory.push(...)` 后立即 `await fs.writeJson(groupHistoryPath, groupHistory, {spaces:2})`（例如流式结束分支 `:950-952`，`[DONE]` 分支 `:965-967`，非流式分支 `:1062-1064`），下一个 agent 在构建自己的上下文时就能看到上一个 agent 刚说的话——这就是"同一 topic 内多个 Agent 发言不交错"的实现基础：**因为是严格的串行 await 循环，不存在并发 fetch，天然不会有两个 agent 的流式 chunk 交错写入同一个 messageId**。

但这个"串行"只保证了**单次 `handleGroupChatMessage` 调用内部**的顺序，并没有对**多次调用之间**加锁。如果用户在上一次群聊消息还在处理中（比如某个 agent 的回复还没写完）时再次发送消息，或者同时点了"邀请发言"按钮（`handleInviteAgentToSpeak` 是完全独立的另一个函数，同样在开头 `await fs.readJson(groupHistoryPath)` 读一次全量历史，逻辑与 `handleGroupChatMessage` 类似），两次调用各自持有自己的内存 `groupHistory` 快照，各自在结尾 `fs.writeJson` 整份覆盖写——**没有看到任何文件锁、互斥量或版本号校验**。理论上后写入的调用会把先写入的调用追加的内容覆盖掉（丢消息），这是一个真实存在但未被验证触发过的并发风险点（标注"未核实是否在实际使用中触发过"，因为需要构造并发场景才能验证，但代码层面确实没有防护）。

### 6.2 群聊消息的单一真源在主进程

存盘走 `debouncedSaveHistory`（**1 秒防抖**，`modules/renderer/streamManager.js:348-375`），但**群聊消息永远不在这里存盘**——`saveHistoryForContext` 一进来就 `if (context.isGroupMessage) return;`（`:379-383`），注释解释是"群聊由主进程 `groupchat.js` 作为历史单一真源，避免渲染进程重复保存造成竞态"。也就是说群聊的落盘完全依赖 `groupchat.js` 里各个 `fs.writeJson(groupHistoryPath, ...)` 调用（`AbortError` 分支、正常结束分支等各自都会写一次），streamManager 只负责 UI。

### 6.3 流式期间的临时状态与落盘时机

assistant 消息 `isThinking` 在流式过程中临时为 true，落盘前被 `streamManager.finalizeStreamedMessage` 置为 `false`（`modules/renderer/streamManager.js:2279`），`finishReason` 同时写回（`:2278`）；群聊中断场景把已累积内容连同 `interrupted:true` 标记落盘（`Groupmodules/groupchat.js:1030-1039`）。最终化的执行语义（文本选择、防抖落盘）属于对话请求与上下文笔记 6 节。

### 6.4 VCP-CDS 影子镜像：事实源不变、索引分层

当前 HEAD 新增 `modules/services/chatDataService/*`（生命周期 `lifecycle.js`、客户端 `client.js`、外观 `index.js`）与 Rust 实现 `rust_chat_data_service/src/*`（`ingest.rs`/`storage.rs`/`search.rs`/`sync.rs`/`watcher.rs`），随主进程后台启动（`main.js:679-698`，`ChatDataServiceEnabled` 默认 `true`）。关键边界（据 `rust_chat_data_service/README.md` 与代码）：

- `history.json` 仍是桌面聊天兼容真源；普通聊天保存仍先写 `history.json`，再经通知/摄取进入 CDS。
- SQLite 是完整查询镜像，也是移动消息同步的中央索引；Tantivy 是可删除、可重建的全文搜索派生物（`ChatDataServiceTantivyEnabled` 默认 `true`）。
- 消费方：DeepMemo 深度回忆（`searchMemories`）与 VCPMobileSync 中央同步（`MobileSyncUseCentralIndex=true` 时 Manifest/Diff/Pull/Push/Tombstone/Change Feed 改由 CDS 提供，`VCPDistributedServer/Plugin/VCPMobileSync/sync/central.js`）。
- 主进程只暴露 `chat-data-service-status` / `chat-data-service-reconcile` 两个 IPC（`main.js:1050-1065`）；聊天内容搜索（`search-topics-by-content`）**没有**切换到 CDS，仍是逐文件 `includes` 的旧路径（5.2 节）。
- 二进制缺失/启动超时/崩溃时 CDS 降级（`lifecycle.js` 熔断 + 上限 5 次重启），聊天功能不受影响，但 DeepMemo 中央检索与 MobileSync 中央同步不可用。

## 7. 迁移、导入导出与保留策略

- `history.json` 无 schema 版本号（2.2）；`topics[]` 字段做过兼容归一化（`creatorSource` 等，`modules/ipc/chatHandlers.js:538-543`），但未见显式迁移代码——原调查未覆盖导入导出、备份恢复与跨版本升级。
- 未发现对损坏 `history.json`（截断的非法 JSON）的读取兜底，恢复语义未核实。
- CDS 的 `reconcile`（`chat-data-service-reconcile`）可手工触发全量重扫，属于旁路索引的迁移/修复通道；旧 `VCPMobileSync/sync_state.db` 在中央模式下不再写入，但不会自动删除（据 CDS README 声明）。

## 8. Agent、模型、知识库与附件绑定

- **会话级**：Topic 挂在 Agent/群组配置的 `topics[]` 数组下，即话题归属 Agent/群组（1.1）。
- **消息级**：群聊 assistant 消息快照保存 `agentId/model/modelSource`（`Groupmodules/groupchat.js:950`）——"谁说的话、用的什么模型"在消息层持久化；附件作为 `attachments` 数组挂在 user 消息上（`modules/chatManager.js:992-1002`）。
- Agent 的模型等配置保存在 Agent 配置对象中（模型按钮与折叠设置段落的界面见 Chat UI 笔记），配置 schema 未在原调查中核实。
- VCPChat 是 VCPToolBox 的官方桌面前端，消息结构、会话存储与 VCPToolBox 请求编排的对应关系见 [`../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)。

## 9. 设计取舍与已确认边界

- **两级会话模型**（Agent/群组 → Topic）天然适合"多角色 + 长期关系"场景，但配套了 Flowlock、群聊多策略调度等重型运行时机制，比通用聊天客户端复杂得多（调度执行语义见对话请求与上下文笔记 8 节）。
- **未读自动判定以"用户是否参与"为边界**：历史无用户消息时按 assistant 消息数计数，用户一发言即归零；持久化标记带 `unreadSource` 来源区分（手动标记保留、Agent/TopicSponsor 旧标记在用户参与后由前端主动清除），旧版"恰有一条 assistant 消息才触发"的窄条件已删除（5.3）。
- **话题内容搜索有盲点**：`searchTopicsByContent` 只匹配字符串型 `content`，多模态数组内容匹配不到（5.2）。
- **`history.json` 整份覆盖写，无原子写**（临时文件+rename）保护，进程崩溃时点存在截断风险（未实际验证过是否发生过，仅代码层面推断）（2.2）。
- **群聊历史写盘缺乏并发保护**：多次 `handleGroupChatMessage`/`handleInviteAgentToSpeak` 调用之间没有锁，理论上存在互相覆盖写丢消息的风险（6.1）。
- **默认话题 id 不一致**：`"default"` vs `"topic_<timestamp>"`（3.3）。
- **类目边界**：本笔记只回答数据语义；停止生成的半截消息如何收口、话题自动总结请求的执行属于对话请求与上下文；消息列表渲染与滚动属于消息渲染器。

## 10. 未验证事项

- 崩溃导致的 `history.json` 截断是否实际发生过（2.2）。
- 群聊多次调用并发覆盖写是否在实际使用中触发过（6.1）。
- 分支数据模型、消息编辑/重试/续写的数据变更语义、Topic 删除与恢复的数据侧实现（1.3、3.4、4）。
- 导入导出、备份恢复、跨版本迁移（7）。
- 多窗口（主窗口/语音聊天窗口）同时写同一 Topic 的文件级并发未核实。
- VCP-CDS 摄取一致性、Tantivy 重建与 `reconcile` 的耗时/正确性未运行验证（6.4）。

## 11. 关键源码索引

- `modules/chatManager.js`：`selectItem` `:352-481`，`selectTopic` `:483-537`，`_saveLastOpenState` `:275-292`，附件组装 `:992-1002`
- `modules/topicListManager.js`：`hasUserParticipation/countUnreadMessages/hasValidPersistentUnreadMarker` `:47-106`，"未读话题"置顶 `:128-175`，`ensureTopicCountObserver/loadTopicMessageCount` `:239-310`，`loadTopicList` `:498-616`，排序 `:635-694`，右键标记已读/未读 `:841-855`
- `modules/ipc/chatHandlers.js`：`search-topics-by-content` `:408-451`，`saveTopicOrder`/`saveGroupTopicOrder` `:345-407`，`topics[]` 兼容归一化 `:538-543`，未读计数后端实现 `:1325-1368`，`setTopicUnread`（含 `unreadSource`）`:1474-1527`，默认话题 id `:555`
- `modules/ipc/agentHandlers.js`：`create-agent` 写 `topics: [{id:"default",...}]` `:430`
- `Groupmodules/groupchat.js`：群聊历史路径与写盘 `:159`, `:500`, `:539`, `:950-952`, `:965-967`, `:1030-1039`, `:1062-1064`, `:1770`, `:1825`
- `modules/renderer/streamManager.js`：`isThinking/finishReason` 写回 `:2277-2279`，`saveHistoryForContext`（群聊不落盘）`:377-396`
- `Flowlockmodules/flowlock.js`：Session 状态机、锁定 topic 查询 `getLockedTopicId` `:554-557`
- `modules/services/chatDataService/*`（新增）：VCP-CDS 生命周期 `lifecycle.js`、客户端 `client.js`、外观 `index.js`；Rust 侧 `rust_chat_data_service/src/{ingest,storage,search,sync,watcher}.rs`；`main.js:679-698`（启动）、`:1050-1065`（status/reconcile IPC）
