# Jan 会话与消息管理调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：直接阅读源码（core 类型定义、React 前端 store 与服务层、conversational 扩展桥接、Rust Tauri 持久化命令、SQLite 移动端模块）并逐条核对符号与行号
>
> 调查范围：Thread/Message 数据模型、文件与 SQLite 双持久化、乐观写、列表/删除/收藏语义、分支/编辑/续写/回退的数据变更、迁移与保留策略；请求执行语义进入对话请求与上下文类目，界面工作流进入 Chat UI 类目，内容渲染进入消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的聊天数据层是"前端直连持久化后端"模式：没有后端聊天业务服务，React 前端（web-app）通过 conversational 扩展把 Thread/Message 读写转发到 Tauri Rust 命令。桌面与移动端共用前端逻辑，只在持久化后端上分流：桌面端每个 thread 一个目录（`thread.json` + `messages.jsonl`，消息整文件重写），移动端走 SQLite（`jan.db`，JSON 文本列 + CASCADE 外键）。

数据层关键事实（均有源码依据，正文标注位置）：

1. **持久化双后端**：桌面 = `threads/<id>/thread.json` + `messages.jsonl`（`src-tauri/src/core/threads/helpers.rs` 每线程锁 + `File::create` 整文件重写）；Android/iOS 才用 SQLite（`should_use_sqlite`，`helpers.rs:17-19`）；Rust `create_thread` 用服务端 `Uuid::new_v4()` 无条件覆盖前端传入的 id，`create_message`/`modify_message` 有按 id 的去重/upsert 语义。
2. **三个 store 协作**：`useThreads`（线程列表/排序/搜索/增删改）、`useMessages`（乐观写 + 异步持久化）、`useChatSessions`（AI SDK 会话与流状态，按 threadId 键控）；`$threadId.tsx`（1863 行）是线程页中枢，承载分支/编辑/续写/上下文扩展的数据仲裁。
3. **线程的助手是嵌入快照**：core 类型为 `ThreadAssistantInfo`（`threadEntity.ts:29-35`）；web 服务层实际写入的是完整 web Assistant 对象（含 avatar/instructions/parameters 等，运行时 JSON 是类型超集），其中 `model` 被改写为 `{id, engine}` 线格式。
4. **分支/编辑**：`metadata.parentId` + `metadata.activeChildId` 树（`message-branching.ts`），`activeRootId` 存线程 metadata；`makeSibling` 产生新版（编辑时 content 替换为纯文本，媒体丢失）；Continue 原地续写（删除旧 partial 不 fork）；`repairDetachedAssistants` 修复旧版 `parentId:null` 幽灵根缺陷（#8357 系）。
5. **删除**：`deleteThread` 级联清理各 store、向量库集合与搜索索引；`deleteAllThreads` 保留收藏与带 project 的线程；无回收站（本次未找到软删除/回收站机制，检查范围见 §3）。

## 系统边界与数据主链

```text
ChatInput 发送（新建线程走 createThread，线程内走 processAndSendMessage）
  -> useThreads.createThread（ulid/TEMPORARY_CHAT_ID，title=prompt）-> services/threads -> conversational-extension
        -> Rust create_thread（服务端 uuid 覆盖前端 id，写 thread.json）
  -> useMessages.addMessage 乐观写 -> createMessage().then 按 id 替换
        -> 桌面：Rust create_message（per-thread 锁 + 去重）-> messages.jsonl 追加
        -> 移动端：SQLite db.rs create_message（INSERT OR IGNORE）
  -> 更新：updateMessage -> modifyMessage -> modify_message（锁内替换，找不到则追加，整文件重写）
  -> 读取：DataProvider 首拉（重试+防清空）-> useThreads.setThreads -> ThreadItem 懒加载消息
  -> 删除：deleteThread / deleteAllThreads（保留收藏与 project 线程）/ delete_message（retain 整写）
```

边界：请求如何组装、流式消费、上下文管理属于对话请求与上下文（`../对话请求与上下文/Jan-对话请求与上下文调查笔记.md`）；线程列表菜单、搜索对话框、消息操作入口等界面工作流属于 Chat UI（`<../Chat UI/Jan-ChatUI调查笔记.md>`）；消息内容与列表渲染属于消息渲染器（`../消息渲染器/Jan-消息渲染器调查笔记.md`），本笔记只记录持久化形状与数据变更。

## 1. 会话、消息与分支数据模型

### 1.1 Thread 与"会话单位"

`core/src/types/thread/threadEntity.ts`：

```text
Thread {
  id, object, title,
  assistants: ThreadAssistantInfo[],   // 嵌入快照，见 §8
  created, updated,                    // 数字时间戳
  metadata?: Record<string, unknown>,  // 分支 activeRootId、project、titleSetManually 等
}
ThreadAssistantInfo { id, name, model: ModelInfo, instructions?, tools? }
```

- web-app 另有私有 `Thread` 类型（`web-app/src/types/threads.d.ts:38-55`），增加顶层 `isFavorite?`、`model?`、`order?`、`metadata.project`——core 共享类型没有这些字段。
- **收藏的存取**：前端状态里 `isFavorite` 是顶层字段；服务层读写时把它映射到 `metadata.is_favorite`（`web-app/src/services/threads/default.ts:65` 读、`default.ts:139` 写），因此落盘的 thread.json 里是 `metadata.is_favorite`。旧笔记"顶层字段而非 metadata"的表述需要修正：顶层只是 web 端投影。
- **运行时"会话"**：AI SDK 的 Chat 会话按 threadId 保存在 `useChatSessions`（`web-app/src/stores/chat-session-store.ts`，`sessions: Record<threadId, ChatSession>`），不单独持久化，是线程的运行时流状态。
- **临时会话**：`TEMPORARY_CHAT_ID = 'temporary-chat'`（`web-app/src/constants/chat.ts:5`）的内存线程——服务层对临时线程跳过读写（`threads/default.ts:79-82`、`messages/default.ts:16-19` 直接短路返回），界面与请求照常工作。
- **id 生成**：线程 web 侧 `ulid()`（`useThreads.ts:323`）；Rust `create_thread` 用 `Uuid::new_v4()` 无条件覆盖前端 id（`commands.rs:79-80`），前端以返回值为准。消息 id 由 AI SDK `generateId()` 生成（`$threadId.tsx:973`），`newUserThreadContent` 默认 `ulid()`（`completion.ts:101`）；Rust `create_message` 只在缺 id 时补 uuid（`commands.rs:179-182`）。

### 1.2 Message

`core/src/types/message/messageEntity.ts` 的 `ThreadMessage`（L10-41）：

```text
id, object, thread_id, assistant_id?, attachments?,
role, content: ThreadContent[], status: MessageStatus,
created_at, completed_at, metadata?, type?, error_code?, tool_call_id?
```

- `content` 是结构化 parts 数组（`ContentType`：text/reasoning/image_url/input_audio/input_video/tool_call，`messageEntity.ts:139-146`），形状与渲染语义见消息渲染器笔记。
- `status`：core 枚举为 `ready/pending/error/stopped`（`messageEntity.ts:113-122`）；运行时 `'submitted'|'streaming'` 是 AI SDK 状态，映射到 UI（`containers/message/types.ts` 的 `CHAT_STATUS`）。
- `metadata.stopped`：`onFinish` 在 `isAbort || finishReason==='length'` 时写 true（`$threadId.tsx:341-353`），Continue 入口依赖它。错误相关：`metadata.error`（错误文本，与 `message-errors` store 双写）、`metadata.oomError/backendError/contextError`（banner 持久化标记，`$threadId.tsx:893-910` 切线程时回读）。

### 1.3 UI 消息 ↔ 持久化消息双向转换

`web-app/src/lib/messages.ts`：

- `convertUIMessageToThreadMessage`（L17-133）：text / reasoning（包裹 `<think>`）/ file（image→image_url、audio→input_audio、video→input_video）/ tool parts → `metadata.tool_calls` 旧格式（L97-116）；
- `convertThreadMessageToUIMessage`（L203-373）：`tool_call` content 转 `tool-<name>` part（L282-301）；兼容旧 `metadata.tool_calls`（L304-354）；`parseReasoning`（L161-196）兼容 `<think>`/`<thought>`/`<|channel|>analysis`；
- `uiMessageHasMeaningfulContent`（L375-399）、`threadMessageIsEmpty`（L401-419，用于清理空 assistant 行）、`extractContentPartsFromUIMessage`（L440-531）。

### 1.4 分支模型：parentId 树 + activeRootId

`web-app/src/lib/message-branching.ts`（256 行，全读）：

- 树形链接存在**消息自身 metadata**：`parentId`（null=根、字符串=父、缺省=未链接旧数据）+ `activeChildId`（父消息选择哪个子版本；缺省取最新兄弟）；`computeActivePath`（L95-117）从 active root 沿 active child 走出一条可见线性会话。`hasBranching`（L44-47）判定是否已进入分支态。
- `backfillParentIds`（L142-145）：首次 fork 时沿当前线性路径铺平 parentId（只写需要的消息，幂等）。
- `makeSibling`（L236-256）：新 id/时间戳、继承父节点、清 `error` 与 `activeChildId`、content 可整体替换为纯文本。
- `planContinuation`（L217-230）：原地续写——继承被续 partial 的 parentId 并返回待删 partial id，使续写替换原半截消息而非 fork。
- `repairDetachedAssistants`（L170-204）：修复旧版本（#8357 及其变体）分支线程里 assistant 回复被写成 `parentId:null`/无 parentId 的"幽灵根"：重挂到其回答的 user 回合并把被挤掉的后续 user 重新链接。幂等；对未分支线程无操作。
- 活跃根指针 `activeRootId` 存线程 `thread.json` 的 metadata（`$threadId.tsx` 的 `setActiveBranch` L1236-1256 写、`syncActivePath` L1259-1269 读），因此分支状态跨重启可恢复。旧数据（尚无 parentId 的线性线程）在首次 fork 时才回填，回填前的树完整性未验证。

## 2. 事实源、索引与持久化

### 2.1 路径与文件后端

`src-tauri/src/core/threads/constants.rs`：`THREADS_DIR="threads"`、`THREADS_FILE="thread.json"`、`MESSAGES_FILE="messages.jsonl"`。`utils.rs` 组装 `threads/<id>/thread.json` 与 `messages.jsonl` 路径。数据目录清单 `JAN_DATA_DIRS_CONVERSATIONS = ["threads", "assistants"]`（`src-tauri/src/core/app/constants.rs:14`）。

`helpers.rs`：

- `MESSAGE_LOCKS`（L14）：全局 per-thread 锁 `HashMap<threadId, Arc<Mutex<()>>>`，串行化同一线程的消息写（`get_lock_for_thread` L22-31）；
- `write_messages_to_file`（L34-44）：`File::create` 整文件重写，每行一条 JSON；
- `read_messages_from_file`（L47-80）：逐行解析，坏行报错跳过；
- `should_use_sqlite`（L17-19）：`cfg!(any(target_os = "android", target_os = "ios"))`——仅移动端。

### 2.2 Rust 命令与去重/upsert 语义

`src-tauri/src/core/threads/commands.rs`（406 行）：

- `list_threads`（L24-62）：目录遍历读 `thread.json`，解析失败跳过；
- `create_thread`（L67-89）：服务端 uuid 覆盖 id，写 `threads/{uuid}/thread.json`；
- `modify_thread`（L94-117）：目录不存在报错，否则整写；
- `delete_thread`（L121-137）：`fs::remove_dir_all` 删除整个目录；
- `create_message`（L159-218）：per-thread 锁内**先按 id 去重**——已存在则直接返回（L192-202），否则 append + flush（L204-214）；
- `modify_message`（L224-268）：锁内读全量，按 id 替换；找不到则**追加**（upsert，注释说明用于 create 丢失锁竞争时，L257-262），整文件重写；
- `delete_message`（L275-301）：`retain` 后整文件重写；
- assistant 三命令 `get_thread_assistant`（L306）/`create_thread_assistant`（L337）/`modify_thread_assistant`（L369）：读写 thread.json 的 `assistants` 数组；web 功能代码无任何调用（仅出现在 `web-app/src/lib/service.ts:19-21` 的通用路由清单），属遗留 API 表面【代码确认】。

### 2.3 SQLite（移动端）db.rs

`src-tauri/src/core/threads/db.rs`（399 行，`#![allow(dead_code)]` 仅移动端编译）：

- `init_database`（L27-106）：`CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY, data TEXT, created_at, updated_at)` + `messages(id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, data TEXT, created_at)` + 2 个索引（`idx_messages_thread_id` L87-90、`idx_messages_created_at` L92-95）；**未发现 schema 版本表或版本迁移机制**。
- `db_create_thread`（L139-160）INSERT；`db_modify_thread`（L163-184）UPDATE；`db_delete_thread`（L187-201）依赖 CASCADE 删消息。
- `db_create_message`（L229-257）：`INSERT OR IGNORE`（L248，注释说明跳过先落地的 modify upsert）；`db_modify_message`（L260-291）：`INSERT ... ON CONFLICT(id) DO UPDATE SET data = excluded.data`（L279-282）。
- `db_list_messages`（L204-226）：按 `created_at ASC` 排序返回（注意与桌面文件 append 顺序的差异）。
- 助手三命令的移动端对应实现（L311-398）同样无 web 调用方。

### 2.4 前端乐观写与服务层

`web-app/src/hooks/useMessages.ts`（96 行）：`addMessage`（L28-59）先改内存再 `createMessage().then` 按 id 替换（L46-55）；`updateMessage`（L60-80）走 `modifyMessage`；`deleteMessage`（L81-92）先删后端再过滤内存。

`web-app/src/hooks/useThreads.ts`（489 行）：`setThreads`（L66-103）做模型归一化——`provider.replace('llama.cpp','llamacpp')`，cortex 迁移时模型 id 取前两段按路径分隔符拼接（L71-86）；`getFilteredThreads`（L104-138）Fzf 搜索（懒建索引 L118-124）；`toggleFavorite`（L139-158）改 `isFavorite` + `updated=Date.now()/1000` 并持久化；`renameThread`（L406-428）置 `metadata.titleSetManually=true`；`updateThread`（L464-488）通用合并（读-改-写整线程）。

服务层 `web-app/src/services/threads/default.ts`：`fetchThreads`（L25-76）读扩展并转换（`updated` 毫秒→秒、`isFavorite` ↔ `metadata.is_favorite`、assistants model → `{id, provider}`）；`createThread`（L78-119）把完整 assistant 对象展开写入、无助手时写 `{id:'model-only', name:'Model'}` 占位；`updateThread`（L121-146）同样展开 assistant 并把 model 改写为 `{id, engine}` 线格式。链路：服务层 → `extensions/conversational-extension/src/index.ts`（`window.core.api.*` 透传）→ Tauri 命令。

## 3. 创建、切换、归档、删除与恢复

- **创建**：`useThreads.createThread`（L315-361）：`ulid()` 或 `TEMPORARY_CHAT_ID`；title 默认取首次输入（`ChatInput.tsx:488`）；可选 project metadata；创建成功回填列表并置 `currentThreadId`。磁盘层再被 Rust uuid 覆盖（§2.2）。首次发送前的线程页现场建立见 Chat UI 笔记 §2。
- **删除线程**：`deleteThread`（`useThreads.ts:159-182`）级联 `useAgentMode.removeThread` / `useChatSessions.removeSession` / `useAppState.clearThreadState` + `cleanupVectorDB`（删 `attachments_<threadId>` 集合，L45-59）+ 服务层 `deleteThread` + 重建 searchIndex。
- **批量删除**：`deleteAllThreads`（L183-228）保留 `isFavorite` 或 `metadata.project` 的线程；`deleteAllThreadsByProject`（L250-285）按 project 过滤删除；`clearAllThreads`（L229-249）全部清理并清空 currentThreadId；`unstarAllThreads`（L286-305）。
- **删除消息**：Rust `delete_message` retain 整写（§2.2）；前端 `handleDeleteMessage`（`$threadId.tsx:1410-1422`）：store 删除 + 清错误 + 从 chatMessages 过滤；流式态禁用（界面侧见 Chat UI 笔记 §6）。
- **首拉与防清空**：`web-app/src/providers/DataProvider.tsx:282-334`——fetchThreads 失败按 150ms×attempt 退避重试（上限 20 次），扩展注册事件会重新触发；**空结果不覆盖已填充的列表**；线程内消息加载合并本地乐观写（`$threadId.tsx:790-810`）。
- **载入时自愈**：`$threadId.tsx:815-835` 丢弃并删除空 assistant 行（旧 bug 产物），并对 `parentId:null` 幽灵根跑 `repairDetachedAssistants` 后回写。
- **保留语义**：无回收站（检查范围：`threads` 模块全部命令、`useThreads` 全部删除方法、`ThreadList`/`NavChats`/对话框目录——均无软删除或回收站入口）；`deleteAllThreads` 的保留集是唯一的"批量保护"。
- **归档**：本次未找到归档机制（core Thread 类型无 archived 字段；threads 命令无归档命令；ThreadList 菜单无归档项）——标注为未找到，非项目级否定。

## 4. 编辑、重试、续写、回退与分支语义

数据侧仲裁全部在 `web-app/src/routes/threads/$threadId.tsx`（界面入口与可用性见 Chat UI 笔记 §6）：

- **编辑**：`handleEditMessage`（L1373-1407）：`ensureBranched`（L1227-1233，首次 fork 时回填 parentId）→ `makeSibling(target, {text})` 新 id/时间戳同 parentId，**content 整体替换为纯文本（媒体丢失）** → `setActiveBranch`；用户消息编辑同步 regenerate 新回复（L1392-1395），助手消息编辑仅 fork 不重新生成（L1396-1398）。
- **重新生成**：`handleRegenerate`（L1317-1346）：清 banner 错误 → `ensureBranched` → `pendingAssistantParentId = resolveAssistantParent(messageId)`（L1291-1313）→ `regenerate()`；新回复在 onFinish 落为兄弟 sibling 并 `withActiveChild` 成为 active（L432-442）。
- **续写**：`handleContinue`（L1352-1369）：取最后部分文本/reasoning → `setContinueFromContent` + `continueReplaceIdRef` → 触发 regenerate；onFinish 中 `planContinuation` 继承 parentId 并在落盘后**删除旧 partial**（L444-449），因此续写是原地替换、不产生新版本。
- **切换版本**：`handleSwitchVersion`（L1272-1288）：在兄弟列表（`getSiblings`）内 ±1 → `setActiveBranch(next)` + `syncActivePath()`；活跃指针写回线程 metadata 或父消息 activeChildId。
- **父链维护**：发送时若线程已分支，新 user 消息链接到 active path 末位（L1064-1079）；assistant 回复的 parent 在 onFinish 落盘前再兜底 `resolveAssistantParent`，防止产生脱链 assistant（L385-395）。
- **编辑丢媒体的设计取舍**：原版本仍保留可回退（fork 而非覆盖），但新 sibling 只有文本——编辑对话框里展示的图片/文件保留 chips 只影响 UI 展示，不会进入落盘内容（`makeSibling` 只接收文本，`EditMessageDialog.tsx:63-73` 的 onSave 仅回传字符串）。

## 5. 列表、分页、搜索与定位

- **排序**：`ThreadList.tsx:297-301` 按 `updated` 降序；`updateThreadTimestamp`（`useThreads.ts:433-463`）置顶刷新。
- **收藏**：`toggleFavorite` store 方法存在（§2.4），但本快照 **web-app 内没有 UI 调用点**（搜索 `toggleFavorite` 仅命中 store 与测试；侧栏无收藏分区）——旧笔记"界面入口改顶层 isFavorite"的说法不成立，收藏星标界面本次未找到。`deleteAllThreads` 的收藏保留逻辑仍有效。
- **搜索**：`getFilteredThreads`（`useThreads.ts:104-138`）用 Fzf 按标题模糊搜索，索引懒建且排除 `TEMPORARY_CHAT_ID` 与无标题线程；搜索对话框的 recentSearches（localStorage，max 5）与键盘导航属于 Chat UI 笔记 §2。
- **线程列表加载**：`ThreadList.tsx:68-98` ThreadItem 懒加载消息——磁盘为空（新线程）不覆盖乐观写；列表滚动加载策略未找到（全量渲染）。
- **消息列表**：无分页接口——`fetchMessages`（`messages/default.ts:15-27`）全量返回；AI SDK 会话内消息全量渲染，窗口化策略在消息渲染器笔记（无窗口化/虚拟化）。
- **标题生命周期**：自动标题在 onFinish 后按"每 4 条 assistant 消息"节拍触发（`TITLE_REFRESH_EVERY_N_ASSISTANT_MESSAGES=4`，`$threadId.tsx:93,589-656`），受 `autoGenerateTitle` 设置与 `metadata.titleSetManually` 约束，llamacpp 下先等 router 空闲（`router_slots_idle`，L626-642）再调用 `generateThreadTitle`（≤10 词）。

## 6. 缓存、一致性、多窗口与并发写入

- **per-thread 锁**：`MESSAGE_LOCKS`（`helpers.rs:14`）串行化同一线程消息写；无跨线程/跨文件锁；`modify_thread` 与消息写之间无共享锁（thread.json 与 messages.jsonl 各自独立整写）。
- **去重与 upsert**：桌面 `create_message` 已存在直接返回（`commands.rs:192-202`）、`modify_message` 找不到则追加（L259-262）；SQLite `INSERT OR IGNORE`（`db.rs:248`）/ `ON CONFLICT DO UPDATE`（L279-282）——两层都防止"乐观写 create 与流式 modify 竞速"产生重复消息【代码确认；竞态本身未运行验证】。
- **乐观写合并**：`addMessage` 先入内存、`createMessage().then` 按 id 替换（`useMessages.ts:46-55`）；`updateMessage` 用 modify 避免重复。
- **多窗口并发**：聊天状态无跨窗口同步机制（本次未找到；检查范围：web-app chat stores、window 服务调用点——`services/window` 仅用于创建主题/扩展窗口）；多窗口并发写入同一 thread 的行为未验证（推测会互相整文件覆盖）。
- **内存权威源关系**：磁盘/数据库是权威持久化；`useMessages` 内存数组是投影 + 乐观写源，读取时按 id 合并（`$threadId.tsx:790-810`）；AI SDK 会话内的 UIMessage 是渲染投影。

## 7. 迁移、导入导出与保留策略

- **设置迁移**：`migrateLocalStorageToBackend`（`web-app/src/lib/migrateLocalStorageSettings.ts:148-186`，由 `providers/ServiceHubProvider.tsx` 调用）：一次性把 localStorage 设置迁移到后端存储、API key/令牌入系统 keyring，后端 flag 防重复；**不涉及线程/消息数据**。
- **线程数据迁移**：`setThreads` 的模型名归一化与 cortex 模型 id 拼接（`useThreads.ts:71-86`）；消息兼容路径——`<think>` 旧格式解析（`messages.ts:161-196`）、`metadata.tool_calls` 旧工具格式（L304-354）、空 assistant 行清理与 `parentId:null` 幽灵根修复（§3）；Rust 侧 thread.json 无结构迁移（整对象透传）。
- **Schema 版本**：SQLite 为 `CREATE TABLE IF NOT EXISTS`，本快照未发现版本迁移机制（检查范围：`db.rs` 全文，无 `PRAGMA user_version` 或迁移表）——标注为未找到。
- **导入导出/备份恢复**：本次未覆盖（检查范围：web-app services、Rust threads 模块、对话框目录均无导入导出入口）。
- **保留策略**：`deleteAllThreads` 保留收藏与带 project 的线程；消息级删除为整文件重写不可恢复（无回收站）。

## 8. Agent、模型、知识库与附件绑定

- **嵌入快照**：线程助手是 `ThreadAssistantInfo` 快照而非对全局 assistant 的引用（core 类型 §1.1）；服务层写入的是完整 web Assistant 对象（§2.4），因此快照字段实际是类型超集。
- **参数编解**：线程内 SamplerPopover 编辑为"快照 + canonical 镜像"双写——先 `updateCurrentThreadAssistant`（线程快照），若全局 assistant 仍存在再 `updateAssistant` 镜像（`SamplerPopover.tsx:100-113`）【代码确认】；线程外（助手编辑页）修改 canonical 不回流既有线程（静态推断：线程保存的是快照，未发现同步逻辑）。
- **请求参数来源**：线程助手 `parameters` 在 transport 内解析为推理参数（`custom-chat-transport.ts:773-784`，`model-only` 时取空），执行语义见对话请求与上下文笔记 §2。
- **附件**：附件作为消息 `content` 的 file parts 持久化——图片/音频/视频 base64 data URL（`completion.ts:61-95`），文档注入"不含路径"的元数据文本 + `metadata.inline_file_contents` 全文（L37-48, L107-115）；向量库 `attachments_<threadId>` 集合随线程删除清理（`useThreads.ts:45-59`）。
- **遗留 API**：Rust 与 SQLite 两端的 `get_thread_assistant` 等 3 个命令无 web 功能调用方【代码确认，§2.2/§2.3】。

## 9. 设计取舍与已确认边界

以下按【代码确认】/【静态推断】区分证据强度：

1. **messages.jsonl 整文件重写**（`helpers.rs:34-44`）：每次写入全量 `File::create`，长会话每轮 O(消息数) 文件 I/O；per-thread 锁串行化但无增量维护。【代码确认】
2. **服务端 uuid 覆盖前端 id**（`commands.rs:79-80`）：前端 ULID 落盘时被替换，前端需按响应同步；消息 id 则保留前端值。【代码确认】
3. **upsert 去重语义**：create 已存在直接返回 + modify 找不到追加 + SQLite INSERT OR IGNORE/ON CONFLICT，配合前端乐观写按 id 替换。【代码确认】
4. **分支树懒回填**：`backfillParentIds` 只在首次 fork 时铺平 parentId，旧线性线程的树完整性依赖该次回填；`activeRootId` 持久化在线程 metadata，跨重启可恢复活跃路径。【代码确认（机制）+ 未验证行为】
5. **编辑丢媒体**：`makeSibling` 只保留纯文本，编辑对话框的图片保留 UI 不落盘；原版本保留可回退。【代码确认】
6. **线程级 model 与助手参数**：线程保存自己的 model/assistant 快照；SamplerPopover 线程内编辑双写，线程外编辑不回流。【代码确认 + 静态推断】
7. **快照超集**：thread.json 实际写入完整 Assistant 对象（`default.ts:89-91`），core `ThreadAssistantInfo` 是声明形状。【代码确认】
8. **无回收站、无归档**：检查范围见 §3，不是项目级绝对结论。【代码确认（范围内）】

## 10. 未验证事项

- 分支树旧数据迁移完整性（首次 fork 回填前后，多版本/多窗口场景未运行验证）。
- 多窗口并发写入同一 thread（整文件重写互相覆盖的实际行为）。
- 长会话下 messages.jsonl 整文件重写的实际性能。
- SQLite 移动端 schema 版本迁移机制（本快照未找到，标注为未调查）。
- 导入导出/备份恢复（未覆盖）。
- 崩溃恢复（应用退出时未落盘消息的丢失范围、坏文件自愈路径未运行验证）。

## 11. 关键源码索引

- 类型：`core/src/types/thread/threadEntity.ts`、`core/src/types/message/messageEntity.ts`、`web-app/src/types/threads.d.ts`。
- 转换：`web-app/src/lib/messages.ts`、`web-app/src/lib/completion.ts`、`web-app/src/lib/message-branching.ts`。
- 持久化（Rust）：`src-tauri/src/core/threads/commands.rs`、`helpers.rs`、`db.rs`、`constants.rs`、`utils.rs`。
- 服务与扩展：`web-app/src/services/threads/default.ts`、`web-app/src/services/messages/default.ts`、`extensions/conversational-extension/src/index.ts`。
- 前端 store：`web-app/src/hooks/useMessages.ts`、`useThreads.ts`、`useThreadManagement.ts`、`providers/DataProvider.tsx`、`lib/migrateLocalStorageSettings.ts`。
- 线程页中枢（数据侧）：`web-app/src/routes/threads/$threadId.tsx`（分支/编辑/续写/删除仲裁 L1227-1422、载入自愈 L776-865）。
- 列表（数据侧）：`web-app/src/containers/ThreadList.tsx`（懒加载、排序）。
