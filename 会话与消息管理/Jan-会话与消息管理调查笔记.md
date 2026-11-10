# Jan 会话与消息管理调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：直接阅读源码（core 类型定义、React 前端 store 与服务层、服务层与 core 宿主桥接、Rust Tauri 持久化命令、SQLite 移动端模块）并逐条核对符号与行号
>
> 调查范围：Thread/Message 数据模型、文件与 SQLite 双持久化、乐观写、列表/删除/收藏语义、分支/编辑/续写/回退的数据变更、迁移与保留策略；请求执行语义进入对话请求与上下文类目，界面工作流进入 Chat UI 类目，内容渲染进入消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

普通 Chat 的线程与消息由服务层直接调用 @janhq/core 暴露的 `window.core.api.*`，再落到 Tauri 的 Rust 命令上：桌面端把每个线程存成独立的 JSON 与 JSONL，移动端改用 SQLite，这段桥接由 core 宿主承担。Cowork 走另一条链路，用 `CoworkSession` 保存 UIMessage 权威历史、轮次以及模型与工作区状态，经 zustand persist 调 backendStorage 写入设置后端；CLI 项目会话还有第三条恢复链（`web-app/src/hooks/useCoworkSessions.ts:41-64,143-166,323-348`、`src-tauri/jan-cli/src/main.rs:111-140`）。下文的分支、编辑与文件后端章节只覆盖普通 Chat。

数据层关键事实（均有源码依据，正文标注位置）：

1. **持久化双后端**：桌面端为每个线程建立目录，写 thread.json 与 messages.jsonl，写入时按线程加锁并整文件重写；Android 与 iOS 移动端改走 SQLite，由 should_use_sqlite 的编译目标判断决定（`helpers.rs:17-19`）。Rust 创建线程时用服务端 UUID 无条件覆盖前端传入的 id，消息的创建与修改命令则按 id 去重或 upsert。
2. **三个 store 协作**：`useThreads` 管线程列表的排序、搜索与增删改，`useMessages` 管乐观写与异步持久化，`useChatSessions` 按 threadId 保存 AI SDK 会话与流状态；线程页中枢 `$threadId.tsx`（1863 行）负责分支、编辑、续写与上下文扩展的数据仲裁。
3. **线程的助手是嵌入快照**：core 把线程助手声明为 ThreadAssistantInfo（`threadEntity.ts:29-35`），web 服务层写入的却是完整 web Assistant 对象，带头像、指令与参数等字段，运行时 JSON 因此是类型超集，其中 model 改写成 `{id, engine}` 线格式。
4. **分支/编辑**：分支树与编辑、续写语义都在 `message-branching.ts` 里实现，要点如下：
   - 树形链接：父消息由消息元数据里的 parentId 指认，activeChildId 选出当前子版本，活跃根 activeRootId 存在线程元数据中
   - 编辑：`makeSibling` 产生新版本，内容替换为纯文本，媒体丢失
   - 续写：原地替换，删掉旧 partial 而不再 fork
   - 自愈：`repairDetachedAssistants` 修复 parentId 为空的幽灵根缺陷（#8357 系）
5. **删除**：`deleteThread` 级联清理各 store、向量库集合与搜索索引，`deleteAllThreads` 保留收藏与带 project 的线程；删除直接落到磁盘目录，软删除与回收站机制本次未找到，检查范围见 §3。

## 系统边界与数据主链

Cowork 的数据链是创建 session → 占用该 session 运行句柄 → 流式 turns 暂存在运行 store → 正常、停止或错误收尾时统一提交 turns、模型 `messages`、子 Agent 结果与用量 → 经 backendStorage 持久化。模型与工作目录属于会话，子 Agent 结果按 runId 合并，后续没有派发子 Agent 的回合不会清掉旧结果。v0 旧 history 无法表达工具调用，version 1 迁移从 turns 重建模型消息并保留旧字段（[cowork.tsx:1029–1046](../../jan/web-app/src/routes/cowork.tsx#L1029-L1046)、[useCoworkSessions.ts:233–253](../../jan/web-app/src/hooks/useCoworkSessions.ts#L233-L253)、[useCoworkSessions.ts:323–352](../../jan/web-app/src/hooks/useCoworkSessions.ts#L323-L352)）。

Cowork 的显示记录与模型历史允许分化：`/compact` 只压缩后者；编辑、重试和删除较早提问会按“第几个真实用户问题”同步截断两份数组，跳过仅用于子 Agent/监视器通知的系统 ping，原地改写后续历史，保留提问的媒体与文件附件，但不保存普通 Chat 式兄弟版本，也不回滚这些工具已经更改的工作区文件。最后一次提问重试保留问题、移除其后 Agent 产出（[useCoworkSessions.ts:114–141、255–295](../../jan/web-app/src/hooks/useCoworkSessions.ts#L114-L141)、[cowork.tsx:1080–1117](../../jan/web-app/src/routes/cowork.tsx#L1080-L1117)）。

删除会话记录和删除文件沙箱是两层动作；沙箱位于 `agent-workspace/sessions/<id>`，与普通 Chat 的 thread 沙箱为同级目录。CLI 项目线程又使用另一条恢复链，以上 Cowork 的设置存储与消息截断语义不适用于 CLI（`src-tauri/plugins/tauri-plugin-agent-tools/src/workspace.rs:57-80,317-345`）。

```text
ChatInput 发送（新建线程走 createThread，线程内走 processAndSendMessage）
  -> useThreads.createThread（ulid/TEMPORARY_CHAT_ID，title=prompt）-> services/threads -> window.core.api
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

- web-app 本地另有一份私有 Thread 类型，在 core 共享类型之外增加了顶层的收藏、模型与排序字段，以及项目归属字段 metadata.project（`web-app/src/types/threads.d.ts:38-55`）。
- **收藏的存取**：前端状态里 `isFavorite` 是顶层字段；服务层读写时把它映射到 `metadata.is_favorite`（`web-app/src/services/threads/default.ts:65` 读、`default.ts:139` 写），因此落盘的 thread.json 里是 `metadata.is_favorite`，顶层字段只是 web 端投影。
- **运行时"会话"**：AI SDK 的 Chat 会话按 threadId 保存在 `useChatSessions`（`web-app/src/stores/chat-session-store.ts`），不单独持久化，是线程的运行时流状态。
- **临时会话**：`TEMPORARY_CHAT_ID = 'temporary-chat'`（`web-app/src/constants/chat.ts:5`）的内存线程——服务层对临时线程跳过读写（`threads/default.ts:79-82`、`messages/default.ts:16-19` 直接短路返回），界面与请求照常工作。
- **id 生成**：线程 web 侧用 `ulid()`（`useThreads.ts:323`）；Rust 线程创建命令用服务端 UUID 无条件覆盖前端 id（`commands.rs:79-80`），前端以返回值为准。消息 id 由 AI SDK 生成（`$threadId.tsx:973`），新用户消息默认同款 ulid（`completion.ts:101`）；Rust 消息创建命令只在缺 id 时补 uuid。

### 1.2 Message

`core/src/types/message/messageEntity.ts` 的 `ThreadMessage`（L10-41）：

```text
id, object, thread_id, assistant_id?, attachments?,
role, content: ThreadContent[], status: MessageStatus,
created_at, completed_at, metadata?, type?, error_code?, tool_call_id?
```

- `content` 是结构化 parts 数组，part 类型由 `ContentType` 枚举（`messageEntity.ts:139-146`）约束，取值如下；形状与渲染语义见消息渲染器笔记。

  ```text
  text | reasoning | image_url | input_audio | input_video | tool_call
  ```

- **状态字段**：core 的消息状态枚举有 `ready/pending/error/stopped` 四值（`messageEntity.ts:113-122`）；运行时另会出现 AI SDK 的 submitted 与 streaming，两者在 `containers/message/types.ts` 的 CHAT_STATUS 里映射成界面状态。
- **中止与错误标记**：完成回调在中止或因长度截断而结束时把 `metadata.stopped` 置为 true，续写入口据此判断；错误文本写进 `metadata.error`，与错误消息 store 双写，`metadata.oomError/backendError/contextError` 是 banner 的持久化标记，切线程时回读（`$threadId.tsx:341-353、893-910`）。

### 1.3 UI 消息 ↔ 持久化消息双向转换

`web-app/src/lib/messages.ts`：

- `convertUIMessageToThreadMessage`（L17 起）：把 UI 消息的文本、推理、文件与工具 parts 转成 `metadata.tool_calls` 旧格式（L97-116），文件 part 按下列映射，推理内容包裹 `<think>`：

  ```text
  image → image_url | audio → input_audio | video → input_video
  ```

- `convertThreadMessageToUIMessage` 把持久化消息还原成 UI 消息：`tool_call` 内容转成 `tool-<name>` part，旧数据里的 `metadata.tool_calls` 也一并兼容；`parseReasoning` 负责拆开 `<think>`、`<thought>` 与 `<|channel|>analysis` 三种历史包裹格式（`messages.ts:170-354`）。
- 另有三个辅助函数：`uiMessageHasMeaningfulContent` 判断消息是否还有实质内容，`threadMessageIsEmpty` 用于清理空的 assistant 行，`extractContentPartsFromUIMessage` 抽出内容数组（`messages.ts:402-491`）。

### 1.4 分支模型：parentId 树 + activeRootId

`web-app/src/lib/message-branching.ts`（256 行，全读）：

- 父子关系记在消息自身的元数据里：parentId 为字符串时指向父消息，根节点留空，缺该字段的是尚未链接的旧数据；activeChildId 记录父消息当前选用哪个子版本，缺省取最新兄弟。`computeActivePath` 从活跃根沿活跃子节点走出一条可见的线性会话（`message-branching.ts:98`）。
- `backfillParentIds` 在首次 fork 时沿当前线性路径铺平 parentId，只写需要的消息，可重复执行。
- `makeSibling` 生成新 id 与时间戳，继承父节点，清掉 error 与 activeChildId，内容可整体替换为纯文本。
- `planContinuation` 做原地续写：继承被续半截消息的 parentId 并返回待删 id，续写因此替换原半截消息，不再 fork。
- `repairDetachedAssistants` 修复分支线程里被写成 parentId 为空或没有父链的 assistant 回复，把它们重挂到所回答的 user 消息上，并把被挤掉的后续 user 消息重新链接；该函数可重复执行，对未分支线程不做改动。
- 活跃根指针 activeRootId 写在 `thread.json` 的线程元数据里，读写入口在 `$threadId.tsx` 的分支相关回调，分支状态因此能跨重启恢复。旧线性线程要等到首次 fork 才回填 parentId，回填前的树完整性尚未验证。

## 2. 事实源、索引与持久化

### 2.1 路径与文件后端

`src-tauri/src/core/threads/constants.rs` 定义三个路径常量（`THREADS_DIR="threads"`、`THREADS_FILE="thread.json"`、`MESSAGES_FILE="messages.jsonl"`），据此组装出每线程目录下的两个文件路径；数据目录清单含 threads 与 assistants（`src-tauri/src/core/app/constants.rs:14`）。

`helpers.rs`：

- `MESSAGE_LOCKS`（L14）：全局 per-thread 锁表，串行化同一线程的消息写（`get_lock_for_thread`，L22-31）；
- `write_messages_to_file`（L34-44）：`File::create` 整文件重写，每行一条 JSON；
- `read_messages_from_file`（L47-80）：逐行解析，坏行报错跳过；
- `should_use_sqlite`（L17-19）：`cfg!(any(target_os = "android", target_os = "ios"))`——仅移动端。

### 2.2 Rust 命令与去重/upsert 语义

`src-tauri/src/core/threads/commands.rs`（406 行）：

- `list_threads`（L24-62）：目录遍历读 `thread.json`，解析失败跳过；
- `create_thread`（L67-89）：服务端 uuid 覆盖 id，写 `threads/{uuid}/thread.json`；
- `modify_thread`（L94-117）：目录不存在报错，否则整写；
- `delete_thread`（L121-137）：`fs::remove_dir_all` 删除整个目录；
- `create_message`（L159-218）：per-thread 锁内**先按 id 去重**——已存在则直接返回（L192-202），否则追加并落盘（L204-214）；
- `modify_message`（L224-268）：锁内读全量、按 id 替换；找不到则追加（upsert 语义，注释说明用于创建命令丢失锁竞争时，L257-262），整文件重写；
- `delete_message`（L275-301）：`retain` 后整文件重写；
- assistant 三命令读写线程文件的 `assistants` 数组：`get_thread_assistant`（L306）、`create_thread_assistant`（L337）、`modify_thread_assistant`（L369）。web 功能代码无任何调用（仅出现在 `web-app/src/lib/service.ts:19-21` 的通用路由清单），属遗留 API 表面【代码确认】。

### 2.3 SQLite（移动端）db.rs

`src-tauri/src/core/threads/db.rs`（399 行，`#![allow(dead_code)]` 仅移动端编译）：

- `init_database`（L27-106）建两张表与两个索引（`idx_messages_thread_id`、`idx_messages_created_at`）：

  ```sql
  threads(id TEXT PRIMARY KEY, data TEXT, created_at, updated_at)
  messages(id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, data TEXT, created_at)
  ```

  **未发现 schema 版本表或版本迁移机制**。
- 移动端三命令：
  - `db_create_thread`：L139-160（INSERT）
  - `db_modify_thread`：L163-184（UPDATE）
  - `db_delete_thread`：L187-201（依赖外键级联删消息）
- 消息去重与 upsert：
  - `db_create_message`（`:227` 起）：`INSERT OR IGNORE`（注释说明跳过先落地的 modify upsert）
  - `db_modify_message`（`:258` 起）：`INSERT ... ON CONFLICT(id) DO UPDATE SET data = excluded.data`
- `db_list_messages`（`:202`）：按 `created_at ASC` 排序返回（注意与桌面文件 append 顺序的差异）。
- 助手三命令的移动端对应实现（L311-398）同样无 web 调用方。

### 2.4 前端乐观写与服务层

`web-app/src/hooks/useMessages.ts` 提供三个消息操作：

- `addMessage`（L28-59）：先改内存，再 `createMessage().then` 按 id 替换（L46-55）
- `updateMessage`（L60-80）：走 `modifyMessage`
- `deleteMessage`（L81-92）：先删后端再过滤内存

`web-app/src/hooks/useThreads.ts` 提供线程列表相关操作：

- `setThreads`（L66-103）：模型归一化——把 `llama.cpp` 归一化为 `llamacpp`，cortex 迁移时模型名取前两段按路径分隔符拼接（L71-86）
- `getFilteredThreads`（`:134`）：Fzf 搜索（懒建索引）
- `toggleFavorite`（`:169`）：改 `isFavorite` + `updated=Date.now()/1000` 并持久化
- `renameThread`（`:441`）：置 `metadata.titleSetManually=true`
- `updateThread`（L464-488）：通用合并（读-改-写整线程）

服务层 `web-app/src/services/threads/default.ts` 提供三个入口：

- `fetchThreads`：读扩展并转换字段（毫秒转秒、`isFavorite` ↔ `metadata.is_favorite`、模型折叠为 `{id, provider}` 线格式）
- `createThread`：把完整 assistant 对象展开写入，无助手时写 `{id:'model-only', name:'Model'}` 占位
- `updateThread`：同样展开 assistant 并把模型改写为 `{id, engine}` 线格式

链路：服务层（`services/threads/default.ts`、`services/messages/default.ts`）→ `window.core.api.*`（core 宿主暴露的 Tauri 桥）→ Rust 命令。服务层自身只做字段映射（毫秒转秒、`isFavorite` ↔ `metadata.is_favorite`、模型折叠为 `{id, provider}` 线格式），并用 `@janhq/extension-api` 的 `Emitter` 发变更事件。

## 3. 创建、切换、归档、删除与恢复

- **创建**：`createThread`（`useThreads.ts:315-361`）为一段新对话生成线程记录，id 用 ULID，临时会话固定取 `TEMPORARY_CHAT_ID`；标题默认用首次输入（`ChatInput.tsx:488`），可附带项目元数据，创建成功后回填列表并把当前线程指针移过去。落盘时 Rust 端再以自己的 UUID 覆盖该 id（§2.2）。首次发送前线程页的现场建立见 Chat UI 笔记 §2。
- **删除线程**：`deleteThread` 删记录前先逐层解绑运行时资源：agent 模式、AI SDK 会话与页面状态各自清理，再向扩展宿主取向量库服务删掉该线程的集合（传入的集合名已带前缀），随后删服务层记录并重建搜索索引（`useThreads.ts:48`）。
- **批量删除**：`useThreads.ts:183-305` 里有四个批量入口，作用范围各不相同：
  - `deleteAllThreads`：删除全部线程，收藏与带项目元数据的线程保留
  - `deleteAllThreadsByProject`：按项目过滤后删除
  - `clearAllThreads`：清空全部线程并复位当前线程指针
  - `unstarAllThreads`：批量取消收藏
- **删除消息**：Rust 侧 `delete_message` 用 retain 过滤后整文件重写（§2.2）；前端 `handleDeleteMessage` 先删 store 记录、清掉错误状态，再从 chatMessages 中过滤该条，流式进行中禁用（`$threadId.tsx:1410-1422`，界面侧见 Chat UI 笔记 §6）。
- **首拉与防清空**：`web-app/src/providers/DataProvider.tsx:291-330` 首次拉取线程列表，失败时按 150ms×attempt 退避重试（上限 20 次），扩展注册事件会重新触发；返回空结果时保留已填充的列表。线程内消息加载再与本地乐观写按 id 合并（`$threadId.tsx:790-810`）。
- **载入时自愈**：线程页载入时丢弃并删除空的 assistant 行（旧 bug 产物），再对 parentId 为空的幽灵根跑 `repairDetachedAssistants` 修好挂接后回写（`$threadId.tsx:815-835`）。
- **保留语义**：删除直接作用到磁盘目录，没有回收站；检查范围覆盖 threads 模块全部命令、useThreads 全部删除方法以及 ThreadList、NavChats 与对话框目录，均无软删除或回收站入口。`deleteAllThreads` 的保留集是唯一的"批量保护"。
- **归档**：本次未找到归档机制——core 的 Thread 类型没有 archived 字段，threads 命令没有归档命令，ThreadList 菜单也没有归档项。

## 4. 编辑、重试、续写、回退与分支语义

数据侧仲裁全部在 `web-app/src/routes/threads/$threadId.tsx`（界面入口与可用性见 Chat UI 笔记 §6）：

- **编辑**：`handleEditMessage` 走完整的编辑链路：需要首次 fork 时先回填 parentId，再由 `makeSibling` 生成带新标识与时间戳的同父兄弟节点，内容整体替换为纯文本（媒体随之丢失），最后把活跃分支切到新版本。用户消息编辑后会同步重新生成回复，助手消息编辑只 fork、不触发重新生成（`$threadId.tsx:1227-1407`）。
- **重新生成**：`handleRegenerate` 先清掉 banner 错误，确保线程已分支，再解析出新回复应挂的父节点并触发 `regenerate()`；新回复在完成回调里落成兄弟节点，并成为活跃版本（`$threadId.tsx:1291-1346`）。
- **续写**：`handleContinue` 取最后一段部分文本或推理作为续写起点，然后触发重新生成；完成回调里 `planContinuation` 让新内容继承原半截消息的 parentId，并在落盘后删掉旧半截消息，续写因此是原地替换、不产生新版本（`$threadId.tsx:444-449、1352-1369`）。
- **切换版本**：`handleSwitchVersion` 在兄弟列表内前后切换（`getSiblings`），随后切换活跃分支并同步可见路径，活跃指针写回线程元数据或父消息的 activeChildId（`$threadId.tsx:1272-1288`）。
- **父链维护**：线程已分支时，新发的 user 消息链接到活跃路径末位；assistant 回复的父节点在完成回调落盘前再由 `resolveAssistantParent` 兜底解析一次，避免产生脱链的 assistant（`$threadId.tsx:385-395、1064-1079`）。
- **编辑丢媒体的设计取舍**：编辑产生的新兄弟只保留文本，原版本仍在磁盘上，可以回退；编辑对话框里展示的图片与文件保留 chips 只作用于界面展示，进不了落盘内容——`makeSibling` 只接收文本，对话框也只回传字符串（`EditMessageDialog.tsx:63-73`）。

## 5. 列表、分页、搜索与定位

- **排序**：线程列表按 updated 降序展示，置顶刷新由 `updateThreadTimestamp` 把 updated 改成当前时间完成（`ThreadList.tsx:297-301`、`useThreads.ts:433-463`）。
- **收藏**：store 里的 `toggleFavorite` 仍在（§2.4），本快照里 web-app 内没有 UI 调用点：搜索只命中 store 与测试，侧栏也没有收藏分区，收藏星标界面本次未找到。`deleteAllThreads` 的收藏保留逻辑照常生效。
- **搜索**：`getFilteredThreads`（`useThreads.ts:104-138`）用 Fzf 按标题模糊匹配，索引懒建，并排除临时线程与无标题线程；搜索记录（localStorage，上限 5 条）与键盘导航属于 Chat UI 笔记 §2。
- **线程列表加载**：ThreadItem 按需加载所在线程的消息（`ThreadList.tsx:68-98`），磁盘为空的新线程不会覆盖乐观写；列表一次全量渲染，滚动分页策略本次未找到。
- **消息列表**：没有分页接口，`fetchMessages` 一次返回全部消息（`messages/default.ts`），AI SDK 会话内的消息也全量渲染，窗口化策略见消息渲染器笔记（无窗口化或虚拟化）。
- **标题生命周期**：自动标题在回复完成后按每 4 条 assistant 消息的节拍触发，受自动标题开关与 `metadata.titleSetManually` 约束；llamacpp 下先等路由空闲再生成标题（≤10 词），节拍常量与回调都在 `$threadId.tsx:93,589-656`。

## 6. 缓存、一致性、多窗口与并发写入

- **per-thread 锁**：`MESSAGE_LOCKS`（`helpers.rs:14`）把同一线程的消息写串行化，跨线程与跨文件没有共用锁；thread.json 与 messages.jsonl 各自独立整写，`modify_thread` 与消息写之间也不共享锁。
- **去重与 upsert**：桌面端创建命令遇到同 id 直接返回，修改命令找不到就追加（`commands.rs:192-202`）；SQLite 侧分别用 `INSERT OR IGNORE` 与 `ON CONFLICT DO UPDATE` 兜底（`db.rs:248`）。两层共同避免乐观写创建与流式更新竞速时写出重复消息【代码确认；竞态本身未运行验证】。
- **乐观写合并**：`addMessage` 先写内存，等 `createMessage` 返回后按 id 替换占位记录（`useMessages.ts:46-55`）；`updateMessage` 走修改路径，不必再建一条。
- **多窗口并发**：聊天状态没有跨窗口同步机制；检查范围覆盖 web-app 的 chat stores 与 window 服务调用点，后者只用于创建主题与扩展窗口。多窗口同时写同一 thread 的实际行为未验证，按整文件重写推测会互相覆盖。
- **内存权威源关系**：磁盘与数据库是权威持久化，`useMessages` 的内存数组是它的投影兼乐观写来源，读取时按 id 合并（`$threadId.tsx:790-810`）；AI SDK 会话里的 UIMessage 用于渲染。

## 7. 迁移、导入导出与保留策略

- **设置迁移**：`migrateLocalStorageToBackend` 由 `ServiceHubProvider.tsx` 在启动时调用，把 localStorage 里的设置一次性搬到后端存储，API key 与令牌写进系统 keyring，并在后端留标记以防重复迁移；迁移范围只到设置项，线程与消息数据留在原处（`web-app/src/lib/migrateLocalStorageSettings.ts`）。
- **线程数据迁移**：线程数据的兼容处理集中在三处：
  - `setThreads`：模型名归一化，cortex 模型 id 按路径分隔符拼接（`useThreads.ts:71-86`）
  - 消息兼容：解析 `<think>` 旧格式、兼容 `metadata.tool_calls` 旧工具格式、清理空 assistant 行并修复 parentId 为空的幽灵根（§3，`messages.ts:161-354`）
  - Rust 侧：thread.json 整对象透传，没有结构迁移
- **Schema 版本**：SQLite 建表用 `CREATE TABLE IF NOT EXISTS`，`db.rs` 全文没有 `PRAGMA user_version` 或迁移表，版本迁移机制本次未找到。
- **导入导出/备份恢复**：本次未覆盖；检查了 web-app services、Rust threads 模块与对话框目录，均无导入导出入口。
- **保留策略**：`deleteAllThreads` 保留收藏与带 project 的线程；消息级删除是整文件重写，删掉后无法恢复，也没有回收站。

## 8. Agent、模型、知识库与附件绑定

- **嵌入快照**：线程助手以 `ThreadAssistantInfo` 快照随线程保存（core 类型 §1.1），字段取自服务层写入的完整 web Assistant 对象（§2.4），快照字段因此常是类型超集。
- **参数编解**：线程内的参数弹窗做成"快照 + 全局镜像"双写：先 `updateCurrentThreadAssistant` 改线程快照，全局 assistant 仍存在时再镜像更新（`SamplerPopover.tsx:100-113`）【代码确认】；在助手编辑页改全局对象，既有线程里的快照不跟着变（静态推断：未发现同步逻辑）。
- **请求参数来源**：线程助手的 parameters 由 transport 解析成推理参数，model-only 占位助手取空（`custom-chat-transport.ts:773-784`）；执行语义见对话请求与上下文笔记 §2。
- **附件**：附件作为消息的 file parts 持久化：图片、音频与视频存成 base64 data URL，文档转成元数据文本并把全文放进 `metadata.inline_file_contents`（`completion.ts:37-115`）；线程的向量库集合 `attachments_<threadId>` 随线程删除一并清理（`useThreads.ts:45-59`）。
- **遗留 API**：`get_thread_assistant` 等 3 个 assistant 命令在 Rust 与 SQLite 两端都有实现，web 功能代码里没有调用方【代码确认，§2.2/§2.3】。

## 9. 设计取舍与已确认边界

以下按【代码确认】/【静态推断】区分证据强度：

1. **messages.jsonl 整文件重写**：每次写入都用 `File::create` 全量重写，长会话每轮的文件 I/O 随消息数线性增长；per-thread 锁保证串行，但没有增量维护（`helpers.rs:34-44`）。【代码确认】
2. **服务端 uuid 覆盖前端 id**：前端 ULID 在落盘时被服务端 UUID 替换，前端需按响应同步；消息 id 则保留前端值（`commands.rs:79-80`）。【代码确认】
3. **upsert 去重语义**：创建命令遇到已存在的直接返回，修改命令找不到就追加，SQLite 侧用 `INSERT OR IGNORE` 与 `ON CONFLICT`，配合前端乐观写按 id 替换。【代码确认】
4. **分支树懒回填**：`backfillParentIds` 只在首次 fork 时铺平 parentId，旧线性线程的树完整性依赖这次回填；`activeRootId` 持久化在线程 metadata 里，活跃路径可跨重启恢复。【代码确认（机制）+ 未验证行为】
5. **编辑丢媒体**：`makeSibling` 只保留纯文本，编辑对话框里的图片保留只作用于界面，原版本留在磁盘可以回退。【代码确认】
6. **线程级 model 与助手参数**：线程保存自己的 model 与 assistant 快照；SamplerPopover 的线程内编辑双写，线程外编辑不回流。【代码确认 + 静态推断】
7. **快照超集**：thread.json 实际写入的是完整 Assistant 对象，core 的 `ThreadAssistantInfo` 是声明形状（`default.ts:89-91`）。【代码确认】
8. **回收站与归档**：删除直接作用到磁盘目录，线程模型里没有 archived 状态，本次未找到回收站或归档入口；检查范围见 §3。【代码确认（范围内）】

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
- 服务层：`web-app/src/services/threads/default.ts`、`web-app/src/services/messages/default.ts`（均经 `window.core.api.*` 调 Rust）。
- 前端 store：`web-app/src/hooks/useMessages.ts`、`useThreads.ts`、`useThreadManagement.ts`、`providers/DataProvider.tsx`、`lib/migrateLocalStorageSettings.ts`。
- 线程页中枢（数据侧）：`web-app/src/routes/threads/$threadId.tsx`（分支/编辑/续写/删除仲裁与载入自愈见同文件相关回调）。
- 列表（数据侧）：`web-app/src/containers/ThreadList.tsx`（懒加载、排序）。
