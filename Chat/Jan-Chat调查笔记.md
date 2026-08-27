# Jan Chat 概览

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`95e96d02c58ca361a3e54cb36360ed16bc534c8a`（分支：`main`）
>
> 调查方式：只读源码梳理（前端 store/hooks/Rust commands 全量行级阅读）；未修改 Jan 仓库
>
> 调查范围：Thread/Message 数据模型、文件与 SQLite 双持久化、流式管线、上下文管理、分支/版本/编辑/续写、队列、错误与恢复
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的 Chat 管线是"前端直连模型服务"模式：没有后端聊天业务服务，React 前端（web-app）经 AI SDK 的 `useChat` + 自研 `CustomChatTransport` 直接发起流式请求（经 Tauri 本地 API 代理到 llama-server、mlx-server 或远程 provider）。桌面与移动端共用前端逻辑，只在持久化后端分流：桌面端每个 thread 一个目录（`thread.json` + `messages.jsonl`，整文件重写），移动端走 SQLite。

关键事实：

1. **三个 store 协作**：`useThreads`（线程列表/排序/搜索/增删改）、`useMessages`（乐观写 + 异步持久化）、`useChatSessions`（AI SDK 会话与流状态）；`$threadId.tsx`（1863 行）是线程页中枢，承载分支/编辑/续写/上下文扩展全部仲裁。
2. **流式管线**：`experimental_throttle: 50`（只节流 UI 状态）、`resume: false`（重启不恢复未完成回合）；transport 实例按 sessionId 复用；推理参数（temperature/top_k 等）不经 AI SDK 层，而是经 `createCustomFetch` 注入 HTTP body。
3. **上下文管理在 transport 内**：`max_context_tokens>0` 时按 `auto_compact` 开关选择模型总结或纯截断；`finishReason==='length'` 且 token 消耗达到上下文 90% 时冻结部分消息并提示扩容，扩容按阶梯 `<8192→8192→32768→×1.5` 逐级提升。
4. **分支/编辑**：`ensureBranched` + `parentId` 树 + `makeSibling` 产生新版；Continue 原地续写（`setContinueFromContent`，不 fork）；编辑消息只保留纯文本（媒体 content 丢失回退），助理编辑不重新生成；删除与编辑在流式态禁用。
5. **队列**：发送时若正在流式且当前线程存在则入队，`status==='ready'` 时自动发下一条，`error` 或离开线程清队列（`QueuedMessageChip` 显示在输入区顶部）。
6. **错误与恢复**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；扩容阶梯写 model.yml + 重启 router（llamacpp）或 stopModel（其他 provider），然后消费续写并在 1s 后 regenerate。

## 产品表面与系统边界

- 产品表面：Tauri 桌面 GUI + Web + Android/iOS 移动端；无后端聊天业务服务，模型生成由本地 llama-server/mlx-server 或远程 provider 完成，前端直连。
- 持久化后端分流：桌面端 Rust 命令层写 `threads/<id>/thread.json` 与 `messages.jsonl`；SQLite 仅 Android/iOS（`should_use_sqlite`，`helpers.rs:17-19`）。
- 边界：Rust `create_thread` 用服务端 `Uuid::new_v4()` 覆盖前端传入的 id；`get_thread_assistant` 等 3 个 Rust 命令无 web 调用方，属遗留 API 表面。

## 端到端聊天主链

```text
ChatInput.handleSendMessage → $threadId.processAndSendMessage（附件合并/摄取 → 持久化 userMessage 并写 parentId → sendMessage）
→ useChatSDK → CustomChatTransport.sendMessages（custom-chat-transport.ts:1102-1519）
   模型创建（createModelOrAbort：合并模型采样默认/线程参数/reasoning 参数；llamacpp 固定 slot 0，并以 thread_id 交给本地引擎切换 KV 状态）
   → refreshTools → 上下文管理（compact/trim）
   → 消息清洗链（coalesce / resolveOrphan / 音视频编码 / 剔除不支持的图片 part）
   → streamText 流式 → toUIMessageStream 回写
→ 落盘（createMessage/modifyMessage，Rust 整文件重写）→ status==='ready' 时自动发下一条队列消息
```

## 核心对象与状态权威

- **Thread**（`core/src/types/thread/threadEntity.ts`）：
  - `id`（默认 ULID）、`title`、`created/updated`：基础字段；
  - `assistants`：`ThreadAssistantInfo` 嵌入快照，非对全局 assistant 的引用；
  - `metadata`：分支 `activeRootId` 等；`isFavorite` 是顶层字段。
  - Rust 侧以服务端 uuid 覆盖前端 id。
- **Message**（`core/src/types/message/messageEntity.ts`）：
  - `content`：结构化 parts 数组（`TEXT` / `FILE` / `REASONING`）；
  - `status`：由 AI SDK 映射为 `submitted` / `streaming` / `ready` / `error`；
  - `metadata.stopped`：`isAbort` 或 `finishReason==='length'` 时写 true，Continue 按钮仅 `isLastMessage && isStopped` 时显示。
- **持久化权威**：分三层——
  - Rust 层：全局 per-thread 锁 `MESSAGE_LOCKS` 串行化同一线程消息写，`write_messages_to_file` 用 `File::create` 整文件重写（`helpers.rs`）；`commands.rs` 的创建/修改消息命令带 upsert 去重（已存在直接返回）。
  - 移动端 `db.rs`：SQLite 幂等写（`INSERT OR IGNORE` / `ON CONFLICT DO UPDATE`）。
  - 前端 `useMessages`：乐观写后按 id 替换（`addMessage` L46-55）。
- **会话流状态**：`chat-session-store.ts` 按 sessionId 保存 Chat 实例 + transport，跨渲染复用（`use-chat.ts` transportRef）。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/Jan-会话与消息管理调查笔记.md`](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/Jan-对话请求与上下文调查笔记.md`](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/Jan-ChatUI调查笔记.md>`](<../Chat UI/Jan-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/Jan-消息渲染器调查笔记.md`](../消息渲染器/Jan-消息渲染器调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- **Thread 目录 + JSONL 整文件重写**（`helpers.rs:34-44`）：每次写入全量 `File::create`，长会话每轮 O(消息数) 文件 I/O；per-thread 锁串行化但无增量维护。【代码确认】
- **`resume:false`**：不恢复未完成回合；初始消息经 `stickySessionStorage(INITIAL_MESSAGE_PREFIX + threadId)` 恢复发送。【代码确认】
- **按线程的 KV 状态缓存**（llamacpp）：请求仍固定使用 slot 0，但 transport 同时传入 thread_id；worker 在换入其他线程前保存旧状态、再恢复同一模型和配置下的目标线程状态。模型、预设、llama.cpp 构建或模型文件变化会拒绝旧缓存；运行时命中率与多窗口并发行为未验证（`custom-chat-transport.ts:1224-1231`、`src-tauri/plugins/tauri-plugin-llamacpp/src/engine/http.rs:225-280`、`engine/slots.rs:35-175`）。
- **分支树跨重启一致性**：`activeRootId` 存 thread.json 的 metadata；`backfillParentIds` 在发送时铺平 parentId；旧数据迁移完整性未验证。【代码确认（机制）+ 未验证行为】
- **compactMessages 退化为纯 trim**：摘要失败提示"摘要失败已退回截断"，摘要削减对关键上下文的影响未做质量实测。【代码确认 + 推测】
- **线程内助手快照**：编辑助手只在线程内生效（快照），线程内 SamplerPopover 编辑则"快照 + canonical 镜像"双写。
- **错误呈现并存**：全局 banner 隐藏最后一条失败 assistant 消息，同时 `metadata.error` 也写入——UI 呈现交由 banner 端配置，行为未实测。
- **消息列表**：全量渲染，无窗口化/虚拟化（`@tanstack/react-virtual` 仅用于 Hub 模型列表；本轮未找到 `content-visibility` 样式声明）。

## 未验证事项

- 运行行为（视觉效果、时序、性能、真实 provider 上的流式）未实测；结论来自静态源码。
- 多窗口/多会话并发及按线程 KV 缓存的命中率、恢复时序未验证。
- 分支树旧数据迁移完整性、compactMessages 摘要质量未验证。
- banner 与 metadata.error 并存的 UI 呈现、队列在错误/离场场景的完整时序未实测。

## 关键源码索引

- 前端中枢：`web-app/src/routes/threads/$threadId.tsx`（分支/编辑/续写/错误挂载）
- 输入框/发送/队列：`web-app/src/containers/ChatInput.tsx`、`web-app/src/hooks/usePrompt.ts`、`web-app/src/stores/message-queue-store.ts`
- transport 与上下文：`web-app/src/lib/custom-chat-transport.ts`（L1102-1519）、`web-app/src/lib/context-manager.ts`
- 本地引擎缓存：`src-tauri/plugins/tauri-plugin-llamacpp/src/engine/http.rs:225-332`、`engine/slots.rs`
- 消息转换与分支：`web-app/src/lib/messages.ts`、`completion.ts`、`web-app/src/lib/message-branching.ts`
- Rust 持久化：`src-tauri/src/core/threads/commands.rs`、`helpers.rs`、`db.rs`、`constants.rs`
- 前端 store：`web-app/src/hooks/useThreads.ts`、`useMessages.ts`、`use-chat.ts`、`web-app/src/stores/chat-session-store.ts`
