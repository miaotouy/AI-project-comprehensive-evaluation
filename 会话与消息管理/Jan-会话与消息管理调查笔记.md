# Jan 会话与消息管理调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：从 [`../Chat/Jan-Chat调查笔记.md`](../Chat/Jan-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：Thread/Message 数据模型、文件与 SQLite 双持久化、乐观写、列表与删除语义、分支/编辑/续写的数据变更；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目，内容渲染进入消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的 Chat 管线是“**前端直连模型服务**”模式：没有后端聊天业务服务，React 前端（web-app）直接发起流式请求（执行语义在对话请求与上下文笔记）。桌面与移动端共用前端逻辑，只在持久化后端上分流：桌面端每个 thread 一个目录（`thread.json` + `messages.jsonl`，整文件重写），移动端走 SQLite。

数据层关键事实：

1. **持久化双后端**：桌面 = `threads/<id>/thread.json` + `messages.jsonl`（`Rust threads/helpers.rs` 每线程锁 + `File::create` 整文件重写）；Android/iOS 才用 SQLite（`should_use_sqlite`）；Rust `create_thread` 用服务端 `Uuid::new_v4()` **覆盖前端传入的 id**，且 `create_message` 与 `modify_message` 有 upsert 去重（已存在直接返回）。
2. **三个 store 协作**：`useThreads`（线程列表/排序/搜索/增删改）、`useMessages`（乐观写 + 异步持久化）、`useChatSessions`（AI SDK 会话与流状态）；`$threadId.tsx`（1863 行）是线程页中枢，承载分支/编辑/续写/上下文扩展全部仲裁（界面侧在 Chat UI 笔记）。
3. **线程的助手是嵌入快照**：`ThreadAssistantInfo` 而非对全局 assistant 的引用；web 实际写入的是完整 web Assistant 对象（运行时 JSON 是类型超集）。
4. **分支/编辑**：`ensureBranched` + `parentId` 树 + `makeSibling` 产生新版；Continue 原地续写（`setContinueFromContent` + `continueReplaceIdRef`）；编辑消息只保留纯文本（媒体 content 丢失回退），助理编辑不重新生成。
5. **删除**：`deleteThread` 级联清理各 store 与向量库；`deleteAllThreads` 保留收藏与带 project 的线程；无回收站（本次未发现软删除/回收站机制）。

## 系统边界与数据主链

```text
processAndSendMessage（写 userMessage，持久化时写 parentId）
  -> useMessages.addMessage 乐观写 → createMessage().then 按 id 替换
  -> 桌面：Rust create_message（per-thread 锁 + upsert 去重）→ messages.jsonl 整文件重写
  -> 移动端：SQLite db.rs create_message（INSERT OR IGNORE）
  -> Thread 元数据：create_thread / modify_thread → threads/<id>/thread.json
  -> 读取：useThreads.getFilteredThreads（Fzf 搜索）、ThreadItem 懒加载消息
  -> 删除：deleteThread 级联清理 useAgentMode/useChatSessions/useAppState + cleanupVectorDB + rebuild 索引
```

边界：请求如何组装、流式消费、上下文管理属于对话请求与上下文（`../对话请求与上下文/Jan-对话请求与上下文调查笔记.md`）；线程列表菜单、搜索对话框、消息操作等界面工作流属于 Chat UI（<../Chat UI/Jan-ChatUI调查笔记.md>）；消息内容与列表渲染属于消息渲染器（`../消息渲染器/Jan-消息渲染器调查笔记.md`，本笔记只记录持久化形状）。

## 1. 会话、消息与分支数据模型

### 1.1 Thread

`core/src/types/thread/threadEntity.ts`：

```text
Thread {
  id,             // 默认 ULID（web 侧）；Rust create_thread 用服务端 uuid v4 覆盖
  object, title,
  assistants: ThreadAssistantInfo[],   // 快照，见下
  created, updated,                    // ISO 秒
  metadata?: Record<string, unknown>,  // 版本分支 activeRootId 等
}
ThreadAssistantInfo { id, name, model: ModelInfo, instructions?, tools?: AssistantTool[] }
```

线程的助手是“**嵌入快照**”而非对全局 assistant 的引用（`ThreadAssistantInfo`）；Rust 侧 `thread.json` 无 assistants 结构迁移。线程字段含 `isFavorite`（顶层字段，非 metadata.starred）、`model`、`assistants`；`updatedAt` 用于排序。

web 实测（代码确认）：实际写入 thread.json 的是**完整 web Assistant 对象（含 avatar/parameters/created_at）**，与 `ThreadAssistantInfo` 类型不符——运行时 JSON 是超集。

### 1.2 Message

`core/src/types/message/messageEntity.ts` 的 `ThreadMessage`：

```text
id, object, thread_id, assistant_id?, attachments?,
role, content: ThreadContent[], status, created_at, completed_at,
metadata?, type?, error_code?, tool_call_id?
```

`content` 是结构化 parts 数组（TEXT / FILE / REASONING），见消息渲染笔记。

`ThreadMessage.status`：`STATUS` 枚举（见 `core/src/types/message/messageEntity.ts`）；具体 `'submitted'|'streaming'|'ready'|'error'` 由 AI SDK 映射（状态机执行语义在对话请求与上下文笔记）。

`metadata.stopped`：`onFinish` 在 `isAbort || finishReason==='length'` 时写 true（`$threadId.tsx` L341-354）。错误元数据：`metadata.error` + `error_code`。

### 1.3 UI 消息 ↔ 持久化消息双向转换

`web-app/src/lib/messages.ts`：

- `convertUIMessageToThreadMessage`（L17-133）：text / reasoning（持久化为 ` thinking` 包裹）/ file（image/audio/video）/ tool part（含 `metadata.tool_calls`）→ ThreadMessage；
- `convertThreadMessageToUIMessage`（L203-373）：`tool_call` content 转 `tool-<name>` part（L282-301）；兼容旧 `metadata.tool_calls`（L306-354）；`parseReasoning`（L161-196，兼容 ` thinking`/`<thought>`/`<|channel|>analysis`）；
- `extractContentPartsFromUIMessage`（L440-531）、`uiMessageHasMeaningfulContent`（L375-399）、`threadMessageIsEmpty`（L401-419）。

### 1.4 分支模型：parentId 树 + activeRootId

- `ensureBranched`/`backfillParentIds`（`$threadId.tsx` L1227-1233）在发送时把 `parentId` 铺平；`setActiveBranch` L1236；`syncActivePath` L1259。
- 分支树跨重启一致性：`activeRootId` 存线程 `thread.json` 的 metadata；`parentId` 在发送时 `backfillParentIds` 铺平，未验证迁移旧数据 tree 的完整性。【代码确认（机制）+ 未验证行为】
- `makeSibling`（`message-branching.ts` L236-256）：新 id/created_at/`Metadata` 继承父节点、清 `error`、`content` 替换为纯文本；`planContinuation`（L217-230）原地续写分支（不产生新 sibling）；`repairDetachedAssistants`（L170-204）修复 #8432 pre-落地 `parentId:null` 幽灵根。

## 2. 事实源、索引与持久化

### 2.1 路径与后端

`src-tauri/src/core/threads/constants.rs`：

```text
THREADS_DIR = "threads"; THREADS_FILE = "thread.json"; MESSAGES_FILE = "messages.jsonl"
```

`utils.rs` 组装 `threads/<id>/thread.json` 与 `messages.jsonl`。数据目录 `JAN_DATA_DIRS_CONVERSATIONS = ["threads", "assistants"]`（`app/constants.rs`）。

`helpers.rs`：

- `MESSAGE_LOCKS`（L14）：全局 per-thread 锁 `HashMap<threadId, Arc<Mutex>{}>`，串行化同一线程消息写；
- `write_messages_to_file`（L34-44）：**`File::create` 整文件重写**（每行一条 JSON）；
- `read_messages_from_file`（L47-80）：逐行解析；
- `should_use_sqlite`（L17-19）：**仅 Android/iOS**；桌面永远文件。

### 2.2 Rust 命令与 upsert 语义

`commands.rs`（406 行）：

- `create_thread`（L67-89）：**前端传入 id 被服务端 `Uuid::new_v4()` 覆盖**（L79-80），写入 `threads/{uuid}/thread.json`；
- `create_message`（L159-218）：加 per-thread 锁，与 modify 的 upsert 去重——存在则直接返回（L192-202），否则 append+flush（L204-214）；
- `modify_message`（L224-268）：锁内替换，找不到则 upsert 追加，整文件重写；
- `delete_message`（L275-298）：retain 后整文件重写；
- assistant 三命令 `get_thread_assistant`（L306）/`create_thread_assistant`（L337）/`modify_thread_assistant`（L369）读写 thread.json——**web 层无任何调用，属遗留 API**（实际写盘路径是整线程覆写）。

### 2.3 SQLite（移动端）db.rs

`db.rs`（399 行）：`threads(id PK, data JSON文本, created_at, updated_at)` + `messages(id PK, thread_id FK CASCADE ON DELETE, data, created_at)`，2 个索引；`create_message` `INSERT OR IGNORE`（L248），modify 用 `ON CONFLICT DO UPDATE` upsert（L279-288）。移动端 `modify_thread` 更新 `thread.json` 文本。

### 2.4 前端乐观写

`web-app/src/hooks/useMessages.ts`（96 行）：`addMessage` 乐观写后 `createMessage().then` 按 id 替换（L46-55）；`updateMessage` 走 `modifyMessage`（L77）；`deleteMessage` 先删后端（L82）。`useThreads.ts`（489 行）：`setThreads` 归一化 model（`'llama.cpp'→'llamacpp'`，cortex 迁移取 id 前两段按分隔符拼接，L71-86）；`renameThread` 置 `metadata.titleSetManually=true`（L406-428）；`updateThread` 通用合并（L464-488）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：Rust `create_thread` 用服务端 uuid v4 覆盖前端 id（2.2）；线程页中枢 `$threadId.tsx` 首次进入即建立现场（切换/恢复的界面工作流在 Chat UI 笔记）。
- **删除线程**：`deleteThread`（L159-182）：级联清理 `useAgentMode`/`useChatSessions`/`useAppState.clearThreadState` + `cleanupVectorDB`（删 `attachments_<threadId>` 集合）+ rebuild 索引。
- **批量删除**：`deleteAllThreads`（L183-228）：**保留收藏与带 project 的线程**。
- **删除消息**：`delete_message`（Rust）retain 后整文件重写；前端 `handleDeleteMessage`（`$threadId.tsx` L1410-1422）：`deleteMessage` + 清错误 + 从 chatMessages 过滤；流式态禁用（界面侧在 Chat UI 笔记）。
- **恢复/初始化**：`DataProvider.tsx`：线程首拉/重试/防清空逻辑（首拉失败保留现有数据）；`migrateLocalStorageSettings.ts` 处理旧 localStorage 数据迁移。
- **保留语义**：无回收站（本次未发现软删除/回收站机制）；`deleteAllThreads` 有保留集；归档机制本次未找到（线程无 archived 字段的界面入口，标注为未调查）。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑**：`handleEditMessage`（`$threadId.tsx` L1373-1407）：`makeSibling` 新 id/时间戳同 parentId，**content 整体替换为纯文本（媒体丢失）**；用户编辑同步 regenerate，assistant 编辑仅 fork 不重生成（regenerate 执行语义在对话请求与上下文笔记 §7）。
- **重新生成**：`handleRegenerate`（L1317-1346）作为兄弟新 sibling，新回复成为 active。
- **切换版本**：`handleSwitchVersion`（L1272-1288）+ `setActiveBranch`/`syncActivePath`——数据侧是活跃分支指针的切换。
- **续写**：`handleContinue`（L1352-1369）：`setContinueFromContent` + `continueUrlRef` 原地续写，**不 fork**（`planContinuation` 原地续写分支）。
- **删除**：`deleteMessage`（L1410-1422，见 §3）。
- **父链维护**：`backfillParentIds` 发送时铺平 parentId；`repairDetachedAssistants` 修复历史幽灵根（1.4）。
- **编辑丢弃媒体的设计取舍**：原版本仍保留可回退，但用户编辑直观上“图片不见了”（缺陷清单见 §9）。

## 5. 列表、分页、搜索与定位

- **排序**：ThreadList 内 `update` 降序（L297-301，由 `updateThreadTimestamp` 更新）。
- **收藏**：`toggleFavorite` 改顶层 `isFavorite` 并 `updated=Date.now()/1000`。
- **搜索**：`getFilteredThreads` 用 Fzf 搜索 + 懒建索引（`useThreads.ts` L104-138）；搜索对话框的 `recentSearches`（localStorage，max 5）与键盘导航属于 Chat UI 笔记 §2。
- **线程列表加载**：`ThreadList.tsx`（317 行）ThreadItem 懒加载消息（磁盘为空则不覆盖乐观写，L77-86）；项目模式显示省略的用户消息预览。
- **消息列表**：无分页接口，全量渲染；列表窗口化策略在消息渲染器笔记 §1.4（无窗口化/虚拟化）。

## 6. 缓存、一致性、多窗口与并发写入

- **per-thread 锁**：`MESSAGE_LOCKS`（helpers.rs L14）串行化同一线程消息写；无跨线程锁。
- **upsert 去重**：`create_message`/`modify_message` 已存在直接返回（commands.rs L192-202）；SQLite `INSERT OR IGNORE`（db.rs L248）——防止乐观写与异步持久化路径产生重复消息。
- **乐观写合并**：`addMessage` 乐观写后 `createMessage().then` 按 id 替换（2.4）。
- **多窗口并发**：`id_slot=0` KV 复用暗示同一 llama-server 上单活跃回合（推测，见对话请求与上下文笔记）；多窗口并发写入行为未验证。
- **迁移**：`migrateLocalStorageSettings.ts` 处理旧 localStorage 数据；Rust 侧 `thread.json` 无 assistants 结构迁移（1.1）。

## 7. 迁移、导入导出与保留策略

- 迁移：`migrateLocalStorageSettings.ts`（2.4）；`setThreads` 的模型名归一化与 cortex 迁移逻辑（L71-86）。
- Schema：`threads(id PK, data JSON文本)` + `messages(id PK, thread_id FK CASCADE ON DELETE)`——本快照未发现 SQLite schema 版本迁移机制（标注为未调查）。
- 导出/备份：本次调查未覆盖。
- 保留：`deleteAllThreads` 保留收藏与带 project 的线程；消息级删除整文件重写不可恢复（无回收站）。

## 8. Agent、模型、知识库与附件绑定

- **嵌入快照**：线程助手是 `ThreadAssistantInfo` 快照而非引用（1.1）。
- **线程级 model 与助手 parameters 的编解**：编辑助手只在线程内生效（快照），线程外保存助手参数不回流既有线程；线程内 SamplerPopover 编辑则“快照 + canonical 镜像”双写。【代码确认】
- **附件**：附件作为消息 `content` 中的 file parts 持久化（图片/音频/视频 base64 data URL 或文档元数据，构造在对话请求与上下文笔记 §2）；向量库 `attachments_<threadId>` 集合随线程删除清理（`cleanupVectorDB`）。
- **遗留 API**：Rust `get_thread_assistant` 等 3 个命令无调用方（2.2）。【代码确认】

## 9. 设计取舍与已确认边界

以下按【代码确认】／【推测】区分证据强度（源笔记 §9 缺陷清单按类目迁移）：

1. **messages.jsonl 整文件重写**（helpers.rs:34-42）：每次写入全量 `File::create`，长会话 O(消息数) 每轮文件 I/O；per_thread 锁串行化，但无增量维护。【代码确认】
2. **服务端 uuid 覆盖前端 id**（commands.rs L79-80）：前端 ULID 在落盘时被替换，前端需按响应同步。【代码确认】
3. **分支树跨重启一致性**：`activeRootId` 存线程 `thread.json` 的 metadata；`parentId` 在发送时 `backfillParentIds` 铺平，未验证迁移旧数据 tree 的完整性。【代码确认（机制）+ 未验证行为】
4. **线程级 `model` 与助手 `parameters` 的编解**：线程外保存助手参数不回流既有线程；线程内编辑“快照 + canonical 镜像”双写。【代码确认】
5. **Rust `get_thread_assistant` 等 3 个命令无调用方**：遗留 API 表面。【代码确认】
6. **编辑除改写文本外会丢弃图片/媒体 content**（`makeSibling` 只保留文本）——设计上原版本仍保留可回退，但用户编辑直观上“图片不见了”。【代码确认】
7. **upsert 去重语义**：create/modify 已存在直接返回，配合前端乐观写按 id 替换。【代码确认】

## 10. 未验证事项

- 分支树迁移旧数据 tree 的完整性（§9-3）。
- 多窗口并发写入、`id_slot=0` 多并发行为（推测项）。
- 长会话下 messages.jsonl 整文件重写的实际性能。
- SQLite 移动端 schema 迁移机制未调查（§7）。
- 导入导出/备份恢复未调查。
- 崩溃恢复（应用退出时未写消息的丢失范围）未调查。

## 11. 关键源码索引

- 类型：`core/src/types/thread/threadEntity.ts`（Thread/ThreadAssistantInfo）、`core/src/types/message/messageEntity.ts`（ThreadMessage/STATUS）。
- 转换：`web-app/src/lib/messages.ts`（UI↔持久化双向转换）。
- 持久化（Rust）：`src-tauri/src/core/threads/commands.rs`、`helpers.rs`、`db.rs`、`constants.rs`。
- 前端 store：`web-app/src/hooks/useMessages.ts`、`useThreads.ts`、`useThreadManagement.ts`；`DataProvider.tsx`、`migrateLocalStorageSettings.ts`。
- 分支：`web-app/src/lib/message-branching.ts`（`makeSibling`/`planContinuation`/`repairDetachedAssistants`）。
- 线程页中枢（数据侧）：`web-app/src/routes/threads/$threadId.tsx`（删除/编辑/分支/续写仲裁 L913-1422）。
- 列表（数据侧）：`web-app/src/containers/ThreadList.tsx`（排序、懒加载）。
