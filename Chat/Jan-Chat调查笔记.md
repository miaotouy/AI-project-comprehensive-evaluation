# Jan Chat（会话）调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：只读源码梳理（前端 store/hooks/Rust commands 全量行级阅读）；未修改 Jan 仓库
>
> 调查范围：Thread/Message 数据模型、文件与 SQLite 双持久化、流式管线、上下文管理、分支/版本/编辑/续写、队列、错误与恢复
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/Jan-会话与消息管理调查笔记.md`](../会话与消息管理/Jan-会话与消息管理调查笔记.md)（数据模型、双持久化、分支/编辑数据语义、列表检索）
> - 对话请求与上下文：[`../对话请求与上下文/Jan-对话请求与上下文调查笔记.md`](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)（提交入口、上下文拼装与压缩、流式、队列、错误恢复）
> - Chat UI：[`../Chat UI/Jan-ChatUI调查笔记.md`](<../Chat UI/Jan-ChatUI调查笔记.md>)（工作台、Composer、附件摄取、生成反馈、消息操作）
> - 消息渲染：[`../消息渲染器/Jan-消息渲染器调查笔记.md`](../消息渲染器/Jan-消息渲染器调查笔记.md)（已有独立笔记，内容渲染类段落不再重复）
>
> 本文件第 10 节横向比较坐标属跨类目综合内容，暂保留于此。

## 结论摘要

Jan 的 Chat 管线是“**前端直连模型服务**”模式：没有后端聊天业务服务，React 前端（web-app）通过 AI SDK 的 `useChat` + 自研 `CustomChatTransport` 直接发起流式请求（经 Tauri 本地 API 代理到 llama-server、mlx-server 或远程 provider）。桌面与移动端共用前端逻辑，只在持久化后端上分流：桌面端每个 thread 一个目录（`thread.json` + `messages.jsonl`，整文件重写），移动端走 SQLite。

核心链条与关键事实：

1. **三个 store 协作**：`useThreads`（线程列表/排序/搜索/增删改）、`useMessages`（乐观写 + 异步持久化）、`useChatSessions`（AI SDK 会话与流状态）；`$threadId.tsx`（1863 行）是线程页中枢，承载分支/编辑/续写/上下文扩展全部仲裁。
2. **持久化双后端**：桌面 = `threads/<id>/thread.json` + `messages.jsonl`（`Rust threads/helpers.rs` 每线程锁 + `File::create` 整文件重写）；Android/iOS 才用 SQLite（`should_use_sqlite`）；Rust `create_thread` 用服务端 `Uuid::new_v4()` **覆盖前端传入的 id**，且 `create_message` 与 `modify_message` 有 upsert 去重（已存在直接返回）。
3. **流式管线**：`experimental_throttle: 50`（UI 更新节流）、`resume: false`；transport 实例按 sessionId 复用；消息清洗链 `coalesce(resolveOrphan(encodeVideo(encodeAudio(stripUnsupportedImageParts(mapUserInlineAttachments)))))`；推理参数（temperature/top_k 等）不经 AI SDK 层，而是经 `createCustomFetch` 注入 HTTP body。
4. **上下文管理在 transport 内**：设置 `max_context_tokens` 后，`auto_compact ? compactMessages（模型总结） : trimMessages`；`finishReason==='length'` 且 token ≥ 0.9×ctx_len 时冻结部分消息并提示扩容（阶梯 `<8192→8192→32768→×1.5`）。
5. **分支/编辑**：`ensureBranched` + `parentId` 树 + `makeSibling` 产生新版；Continue 原地续写（`setContinueFromContent` + `continueReplaceIdRef`）；编辑消息只保留纯文本（媒体 content 丢失回退），助理编辑不重新生成；删除与编辑均在流式态禁用。
6. **队列**：发送时若正在流式且当前线程存在则 `enqueue` 入队，`status==='ready'` 时自动发下一条，`error` 或离开线程清队列；队列消息显示在输入区顶部 `QueuedMessageChip`。
7. **错误与恢复**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；扩容阶梯写 model.yml+重启 router（llamacpp）或 stopModel（其他 provider），然后消费续写并在 1s 后 regenerate。

## 1. 数据模型

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

### 1.3 UI 消息 ↔ 持久化消息双向转换

`web-app/src/lib/messages.ts`：

- `convertUIMessageToThreadMessage`（L17-133）：text / reasoning（持久化为 ` thinking` 包裹）/ file（image/audio/video）/ tool part（含 `metadata.tool_calls`）→ ThreadMessage；
- `convertThreadMessageToUIMessage`（L203-373）：`tool_call` content 转 `tool-<name>` part（L282-301）；兼容旧 `metadata.tool_calls`（L306-354）；`parseReasoning`（L161-196，兼容 ` thinking`/`<thought>`/`<|channel|>analysis`）；
- `extractContentPartsFromUIMessage`（L440-531）、`uiMessageHasMeaningfulContent`（L375-399）、`threadMessageIsEmpty`（L401-419）。

### 1.4 user 消息构造

`web-app/src/lib/completion.ts` `newUserThreadContent`（L20-117）：图片/音频/视频 base64 data URL 进 content；文档经 `injectFilesIntoPrompt` 注入**不含路径**的元数据（file_id/name/type/size/chunks/mode）；inline 文档全文进 `metadata.inline_file_contents`。id 默认 `ulid()`。

## 2. 持久化

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

`web-app/src/hooks/useMessages.ts`（96 行）：`addMessage` 乐观写后 `createMessage().then` 按 id 替换（L46-55）；`updateMessage` 走 `modifyMessage`（L77）；`deleteMessage` 先删后端（L82）。`useThreads.ts`（489 行）：`setThreads` 归一化 model（`'llama.cpp'→'llamacpp'`，cortex 迁移取 id 前两段按分隔符拼接，L71-86）；`getFilteredThreads` 用 Fzf 搜索 + 懒建索引（L104-138）；`renameThread` 置 `metadata.titleSetManually=true`（L406-428）；`updateThread` 通用合并（L464-488）。

### 2.5 线程列表与删除语义

- `deleteThread`（L159-182）：级联清理 `useAgentMode`/`useChatSessions`/`useAppState.clearThreadState` + `cleanupVectorDB`（删 `attachments_<threadId>` 集合）+ rebuild 索引；
- `deleteAllThreads`（L183-228）：**保留收藏与带 project 的线程**；
- `ThreadList.tsx`（317 行）：ThreadItem 懒加载消息（磁盘为空则不覆盖乐观写，L77-86）；项目模式显示省略的用户消息预览；下拉菜单=重命名/添加到项目/移出项目/删除（`What is Jan?` 且未完成 onboarding 时禁用删除，L255-259）。

### 2.6 会话存储/buildData/migration

`DataProvider.tsx`：线程首拉/重试/防清空逻辑（首拉失败保留现有数据）；`migrateLocalStorageSettings.ts` 处理旧 localStorage 数据迁移。

## 3. 流式管线

### 3.1 useChat 包装

`web-app/src/hooks/use-chat.ts`（149 行）：

- `transportRef` 持 `CustomChatTransport`，跨渲染复用；已有 session transport 优先（L49-62）；
- `useChatSDK`：`experimental_throttle` 由调用方传入（use-chat.ts:100-101 透传 `options.experimental_throttle`，字面值 `50` 在 `$threadId.tsx:292`）、`resume: false`（use-chat.ts:101）；
- MCP/RAG 工具名变化时 `refreshTools()`（L111-117）；
- 暴露 `setContinueFromContent` 与 `updateRagToolsAvailability`。
- 会话 store（`chat-session-store.ts`）按 sessionId 保存 Chat 实例 + transport。

### 3.2 CustomChatTransport.sendMessages（1675 行的 main.ts 入口）

`web-app/src/lib/custom-chat-transport.ts` `sendMessages`（L1102-1519）执行顺序：

1. **模型创建**（L1176-1190）：`extractModelSamplingDefaults`（`MODEL_SAMPLING_SETTING_KEYS`：temperature/top_k/top_p/min_p/repeat_last_n/repeat_penalty/presence_penalty/frequency_penalty）取每模型默认；线程内 `getActiveInferenceParams`（有 thread 助手 id≠'model-only' 时返回 `parameters`，否则空）；**合并顺序 `{...modelDefaults, ...inferenceParams, ...reasoningParams}`**；预定义远程 provider 删除全部 `paramsSettings` 键（L1181-1183）；llamacpp 固定 `id_slot=0` 复用 KV 缓存（L1187-1189）；`createModelOrAbort`（L1054-1099）——模型加载与 abort 竞争，abort 时调 `unloadModel`。
2. `refreshTools()`（L1165-1217）。
3. `splitAssistantToolWaves`（L1223，Claude tool_use/tool_result 配对 + 前缀字节一致保缓存，L530-567）。
4. **system 拼接**（L1229-1240）：`systemMessage（renderInstructions(threadAssistant.instructions)）` + `[ATTACHED_FILES]` 静态说明（L1594-1613，不随附件变化保提示缓存）+ web 搜索指令（L1621-1634，教模型用 `web_search`/`web_fetch` 并内联 `[[cite:URL]]`）。
5. **上下文管理**（L1258-1297）：`maxContextTokens>0` 时 `auto_compact && this.model ? compactMessages : trimMessages`；system 计 token；预算 = maxCtx − maxOutput − system。
6. **`hasGenuineUserQuery`**（L1302-1306，`TOOL_RESPONSE_ONLY` 正则 L590）：纯工具结果回合不发送。
7. **消息清洗链**（L1308-1323）：`coalesceMessagesForAlternation( resolveOrphanToolCalls( encodeVideoAttachments( encodeAudioAttachments( stripUnsupportedImageParts( mapUserInlineAttachments(messages) )))))`；音视频被替换为 sentinel 文本 part，由 `model-factory.ts` 的 fetch 包装解码回 `input_audio`/`input_video`（L1537-1585）。
8. **continue 续写**：`baseMessages + assistant{reasoning,text}:true` 作为续写 prefill（L1327-1349），`prependContinuationToUIStream` 把 partial 注入首个 delta（L680-723）。
9. **`streamText`**（L1369-1389）：`tools: shouldEnableTools ? this.tools : undefined`、`toolChoice:'auto'`、`experimental_repairToolCall`（仅修 Windows 路径反斜杠 `InvalidToolInputError`，L1380-1388）。`toUIMessageStream`（L1394-1509）在 `finish-step`/`finish` 收集 tokenSpeed/usage。

### 3.3 观测修正

- `experimental_throttle: 50` 只节流 UI 状态；`resume: false` 表示重启不恢复未完成回合。
- `id_slot=0` KV 复用暗示同时只有单个活跃回合在本页；多窗口/多会话并发打到同一 llama-server 的行为未验证。

## 4. 上下文管理（context-manager.ts）

`web-app/src/lib/context-manager.ts`（218 行，全读）：

- `trimMessages`（L69-113）：从新往旧走，预算 = maxCtx − maxOut − systemTokens，**保底保留最后一条用户/assistant 消息**；
- `compactMessages`（L115-217）：把被裁消息拼成 “role: text” 摘录（截断到 max(1024, ctx−512−system) 字符）→ `generateText`（llamacpp 摘要请求，≤500 词系统提示、maxOutputTokens=512）→ 把 `[Previous conversation summary]` 作为**system 消息**前置 → 再次 `trim` 保证不超；失败回退纯 trim。
- 上下文横幅 UI（`$threadId.tsx` L1425+）：`finishReason==='length'` 且 `totalTokens ≥ ctxLen*0.9` → 存 `pendingContinuationRef` + `"Increase Context Size"`（步骤 8192→32768→×1.5，封顶 max）。

## 5. 发送、队列与初始消息

`web-app/src/containers/ChatInput.tsx`（2648 行，memo 但无自定义比较器）：

- `handleSendMessage`（L363-415）：`isStreaming` 时 `enqueue({id, text, createdAt})`（L383-388，队列 UI `QueuedMessageChip`）；否则组装 `onSubmit(prompt, files)`（L415）。无模型时拦截（L364-366）。
- 队列存储 `message-queue-store.ts`：`enqueue`/`dequeue`，流式态入队。
- **自动发下一条**（`$threadId.tsx:1560-1575`）：`status==='ready'` 且无挂起工具时 `sendQueuedMessage`（纯文本绕过附件，L1127-1140）；`status==='error'` 清空队列（L1578-1582）；离开线程清队列（L1654-1658）。
- **初始消息恢复**：`stickySessionStorage(INITIAL_MESSAGE_PREFIX + threadId, {…})` 恢复发送（L1145-1172）。
- 附件摄取：图片（仅 JPEG/JPG/PNG ≤10MB，SHA-256 哈希去重）→ `processImageFiles` L950-1144；音频（WAV/MP3 ≤25MB，`decodeAudioDuration`）L1178-1265；视频（VIDEO_EXTS=mp4/mov/webm/mkv/avi/m4v，≤100MB，Tauri 经 `convertFileSrc`+fetch 读文件）L1315-1425；文档握取仅桌面端，扩展名白名单很长（pdf/docx/…/md/ts/js/sh/bash/ps1/…/cu/cuh），`processAttachmentsForSend` 决定 inline/embeddings。
- 拖放（L1519-1597）：`dropAcceptsAnything = hasMmproj || audio || video`；逐类型分流；粘贴（L1599-1724）：音频→`processAudioFiles`；图片走两路径（clipboard items / navigator.clipboard.read），文件命名 `pasted-image-<ts>.<ext>`。
- 历史导航：ArrowUp/Down（光标在行首/尾才触发），历史在 `usePrompt.ts`（MAX_HISTORY_SIZE=100 去重去连续重复）。

## 6. 消息状态机/类型

- `ThreadMessage.status`：`STATUS` 枚举（见 `core/src/types/message/messageEntity.ts`）；具体 `'submitted'|'streaming'|'ready'|'error'` 由 AI SDK 映射；
- `CHAT_STATUS`（`containers/message/types.ts`）与 UI 状态。
- `metadata.stopped`：`onFinish` 在 `isAbort || finishReason==='length'` 时写 true（L341-354）；Continue 按钮仅 `isLastMessage && isStopped` 显示（MessageItem L599-608）。
- 错误元数据：`metadata.error` + `error_code`；`$threadId.tsx` 错误挂载 effect（L1588-1632）：错误找最后一条 assistant（无则最后用户消息）；context overflow 走全局 banner（`stampContextErrorOnThread`+`setContextLimitError`）；否则 `message-errors.setError` 并写 `metadata.error`；L1636-1651 兜底持久化。

## 7. Thread 管理（列表/搜索/重命名/导航）

`web-app/src/hooks/useThreads.ts`（489 行）与 `useThreadManagement.ts`（116 行）、`SearchDialog.tsx`（376 行）：

- 排序：ThreadList 内 `update` 降序（L297-301，由 `updateThreadTimestamp` 更新）。
- 收藏：`toggleFavorite` 改顶层 `isFavorite` 并 `updated=Date.now()/1000`。
- 搜索：`SearchDialog` localStorage `recentSearches`（max 5），Fzf 结果按有无 project 分组，键盘导航。
- 删除对话框 `DeleteThreadDialog`/`DeleteAllThreadsDialog`（`NavChats` 仅显示 >=1 时挂 `<DeleteAllThreadsDialog>`）。
- 重命名 `RenameThreadDialog`。

## 8. 编辑、删除、分支与续写全景（`$threadId.tsx`）

| 操作 | 路由/状态 | 主要组件 |
|---|---|---|
| 发送 | `processAndSendMessage` L913-1123 | 附件合并→预览消息→`processAttachmentsForSend`→ 持久化 userMessage（写 parentId）→ `sendMessage` |
| 分支 | `ensureBranched`/`backfillParentIds` L1227-1233；`setActiveBranch` L1236；`syncActivePath` L1259 | `ThreadList` 版本导航 `< n/m >` |
| 切换版本 | `handleSwitchVersion` L1272-1288 | 版本导航 |
| 重新生成 | `handleRegenerate` L1317-1346（作为兄弟新 sibling，新回复成为 active） | regen 按钮仅末条 |
| 续写 | `handleContinue` L1352-1369（`setContinueFromContent` + `continueUrlRef` 原地续写，**不 fork**） | Continue 仅末条 && `metadata.stopped` |
| 编辑 | `handleEditMessage` L1373-1407：`makeSibling` 新 id/时间戳同 parentId，**content 整体替换为纯文本（媒体丢失）**；用户编辑同步 regenerate，assistant 编辑仅 fork 不重生成 | `EditMessageDialog`（`extractFilesFromPrompt`/`injectFilesIntoPrompt`，Ctrl+Enter 保存，保存禁用当无变化/空文本） |
| 删除 | `handleDeleteMessage` L1410-1422：`deleteMessage` + 清错误 + 从 chatMessages 过滤；流式禁用 | `DeleteMessageDialog` |

`makeSibling`（`message-branching.ts` L236-256）：新 id/created_at/`Metadata` 继承父节点、清 `error`、`content` 替换为纯文本；`planContinuation`（L217-230）原地续写分支；`repairDetachedAssistants`（L170-204）修复 #8432 pre-落地 `parentId:null` 幽灵根。

## 9. 缺陷 / 边界 / 设计取舍

以下按【代码确认】／【推测】区分证据强度：

1. **messages.jsonl 整文件重写**（helpers.rs:34-42）：每次写入全量 `File::create`，长会话 O(消息数) 每轮文件 I/O；per_thread 锁串行化，但无增量维护。【代码确认】
2. **`resume:false`**：不恢复未完成回合【代码确认】；流式 50ms throttle 只节流 UI。
3. **`id_slot=0` KV 复用**：同一活跃回合串行；多并发行为未验证。【推测】
4. **分支树跨重启一致性**：`activeRootId` 存线程 `thread.json` 的 metadata；parentId 在发送时 `backfillParentIds` 铺平，未验证迁移旧数据 tree 的完整性。【代码确认（机制）+ 未验证行为】
5. **紧凑 auto_compact**：compactMessages 退化为纯 trim 时提示“摘要失败已退回截断”；摘要削减可能丢失关键上下文——未做质量实测。【代码确认 + 推测】
6. **线程级 `model` 与助手 `parameters` 的编解**：编辑助手只在线程内生效（快照），线程外保存助手参数不回流既有线程；线程内 SamplerPopover 编辑则“快照 + canonical 镜像”双写。【代码确认】
7. **Rust `get_thread_assistant` 等 3 个命令无调用方**：遗留 API 表面。【代码确认】
8. **编辑除改写文本外会丢弃图片/媒体 content**（`makeSibling` 只保留文本）——设计上原版本仍保留可回退，但用户编辑直观上“图片不见了”。【代码确认】
9. **错误位置**与 banner 互斥：全局 banner 隐藏最后一条失败 assistant 消息，而 error 又写 metadata.error——两者可能同时存在，UI 呈现交由 banner 端配置【代码确认】，行为未实测。

## 10. 横向比较坐标

| 维度 | Jan |
|---|---|
| 消息数据模型 | `ThreadMessage`，content 结构化数组（text/file/reasoning） |
| 持久化 | 桌面 jsonl 整文件重写；移动 SQLite；Rust 全局线程锁 |
| 流式管线 | AI SDK useChat + CustomChatTransport + throttle 50 |
| 参数维度 | 经 createCustomFetch 注入 HTTP body，非 AI SDK 层 |
| 上下文管理 | transport 内 trim/compact（模型摘要），上下文横幅 + 手动扩容 |
| 分支/编辑 | parentId 树 + makeSibling 新版本 + continue 原地续写 |
| 队列 | 流式/提交时入队，ready 自动发出，error 清空 |
| 刷新/恢复 | resume:false；初始消息 sessionStorage 恢复 |
| 消息列表 | 全量渲染，无窗口化/虚拟化（`@tanstack/react-virtual` 仅用于 Hub 模型列表，`web-app/src/routes/hub/index.tsx:282`）；本轮未找到 `content-visibility` 样式声明（同 AIO-Hub，未做 windowing） |

## 11. 关键源码索引

- 前端中枢：`web-app/src/routes/threads/$threadId.tsx`
- 输入框/发送/队列：`web-app/src/containers/ChatInput.tsx`、`web-app/src/hooks/usePrompt.ts`、`message-queue-store.ts`
- transport：`web-app/src/lib/custom-chat-transport.ts`（L1102-1519）
- 上下文：`web-app/src/lib/context-manager.ts`
- 消息转换：`web-app/src/lib/messages.ts`、`completion.ts`
- 附件处理：`web-app/src/lib/attachmentProcessing.ts`、`web-app/src/hooks/useChatAttachments.ts`
- 编辑：`web-app/src/containers/dialogs/EditMessageDialog.tsx`
- 状态存根：`web-app/src/stores/chat-session-store.ts`、`web-app/src/stores/message-errors.ts`、`web-app/src/lib/message-branching.ts`
- Rust 持久化：`src-tauri/src/core/threads/commands.rs`、`helpers.rs`、`db.rs`、`constants.rs`
- 前端 List/Store：`web-app/src/hooks/useThreads.ts`、`useMessages.ts`、`useThreadManagement.ts`