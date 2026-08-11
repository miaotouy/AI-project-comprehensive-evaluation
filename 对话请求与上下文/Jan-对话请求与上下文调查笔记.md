# Jan 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：从 [`../Chat/Jan-Chat调查笔记.md`](../Chat/Jan-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：一次生成任务的提交入口、上下文拼装、预算与压缩、Provider 交接、流式消费、最终化与回写、停止/重试/续写、队列；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的 Chat 管线是“**前端直连模型服务**”模式：没有后端聊天业务服务，React 前端（web-app）通过 AI SDK 的 `useChat` + 自研 `CustomChatTransport` 直接发起流式请求（经 Tauri 本地 API 代理到 llama-server、mlx-server 或远程 provider）。桌面与移动端共用前端逻辑，只在持久化后端上分流（数据语义在会话与消息管理笔记）。

核心链条与关键事实：

1. **流式管线**：`experimental_throttle: 50`（UI 更新节流）、`resume: false`；transport 实例按 sessionId 复用；消息清洗链 `coalesce(resolveOrphan(encodeVideo(encodeAudio(stripUnsupportedImageParts(mapUserInlineAttachments)))))`；推理参数（temperature/top_k 等）不经 AI SDK 层，而是经 `createCustomFetch` 注入 HTTP body。
2. **上下文管理在 transport 内**：设置 `max_context_tokens` 后，`auto_compact ? compactMessages（模型总结） : trimMessages`；`finishReason==='length'` 且 token ≥ 0.9×ctx_len 时冻结部分消息并提示扩容（阶梯 `<8192→8192→32768→×1.5`）。
3. **队列**：发送时若正在流式且当前线程存在则 `enqueue` 入队，`status==='ready'` 时自动发下一条，`error` 或离开线程清队列；队列消息显示在输入区顶部 `QueuedMessageChip`（界面在 Chat UI 笔记）。
4. **错误与恢复**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；扩容阶梯写 model.yml+重启 router（llamacpp）或 stopModel（其他 provider），然后消费续写并在 1s 后 regenerate。

## 系统边界与生成任务主链

```text
ChatInput.handleSendMessage（isStreaming 时 enqueue，否则组装 onSubmit）
  -> processAndSendMessage：附件合并 → 预览消息 → processAttachmentsForSend → 持久化 userMessage（写 parentId）→ sendMessage
  -> useChat（AI SDK）→ CustomChatTransport.sendMessages
       模型创建/参数合并 → refreshTools → splitAssistantToolWaves
       system 拼接（instructions + [ATTACHED_FILES] + web 搜索指令）
       maxContextTokens>0 时 compactMessages / trimMessages（context-manager.ts）
       hasGenuineUserQuery 判定 → 消息清洗链 →（continue 续写 prefill）
       streamText → toUIMessageStream（finish-step/finish 收集 tokenSpeed/usage）
  -> UI 流式消费（throttle 50ms）
  -> onFinish：isAbort || finishReason==='length' → metadata.stopped=true
```

边界：会话与消息如何持久化、分支数据语义属于会话与消息管理（`../会话与消息管理/Jan-会话与消息管理调查笔记.md`）；Composer 附件摄取、排队提示、错误 banner 等界面工作流属于 Chat UI（<../Chat UI/Jan-ChatUI调查笔记.md>）；流式内容如何渲染属于消息渲染器（`../消息渲染器/Jan-消息渲染器调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

- `handleSendMessage`（`ChatInput.tsx` L363-415）：`isStreaming` 时 `enqueue({id, text, createdAt})`（L383-388，队列 UI `QueuedMessageChip`）；否则组装 `onSubmit(prompt, files)`（L415）。无模型时拦截（L364-366）。
- `processAndSendMessage`（`$threadId.tsx` L913-1123）：附件合并→预览消息→`processAttachmentsForSend`→ 持久化 userMessage（写 parentId）→ `sendMessage`。
- 任务状态由 AI SDK 的 Chat 状态机承载：`ThreadMessage.status` 的 `'submitted'|'streaming'|'ready'|'error'` 由 AI SDK 映射（数据字段语义在会话与消息管理笔记 §1.2）；`CHAT_STATUS`（`containers/message/types.ts`）与 UI 状态。
- **自动发下一条**（`$threadId.tsx:1560-1575`）：`status==='ready'` 且无挂起工具时 `sendQueuedMessage`（纯文本绕过附件，L1127-1140）；`status==='error'` 清空队列（L1578-1582）；离开线程清队列（L1654-1658）。

## 2. 历史选择与上下文拼装顺序

`CustomChatTransport.sendMessages`（`web-app/src/lib/custom-chat-transport.ts` L1102-1519，1675 行的 main.ts 入口）执行顺序：

1. **模型创建**（L1176-1190）：`extractModelSamplingDefaults`（`MODEL_SAMPLING_SETTING_KEYS`：temperature/top_k/top_p/min_p/repeat_last_n/repeat_penalty/presence_penalty/frequency_penalty）取每模型默认；线程内 `getActiveInferenceParams`（有 thread 助手 id≠'model-only' 时返回 `parameters`，否则空）；**合并顺序 `{...modelDefaults, ...inferenceParams, ...reasoningParams}`**；预定义远程 provider 删除全部 `paramsSettings` 键（L1181-1183）；llamacpp 固定 `id_slot=0` 复用 KV 缓存（L1187-1189）；`createModelOrAbort`（L1054-1099）——模型加载与 abort 竞争，abort 时调 `unloadModel`。
2. `refreshTools()`（L1165-1217）。
3. `splitAssistantToolWaves`（L1223，Claude tool_use/tool_result 配对 + 前缀字节一致保缓存，L530-567）。
4. **system 拼接**（L1229-1240）：`systemMessage（renderInstructions(threadAssistant.instructions)）` + `[ATTACHED_FILES]` 静态说明（L1594-1613，不随附件变化保提示缓存）+ web 搜索指令（L1621-1634，教模型用 `web_search`/`web_fetch` 并内联 `[[cite:URL]]`）。
5. **上下文管理**（L1258-1297）：`maxContextTokens>0` 时 `auto_compact && this.model ? compactMessages : trimMessages`；system 计 token；预算 = maxCtx − maxOutput − system。
6. **`hasGenuineUserQuery`**（L1302-1306，`TOOL_RESPONSE_ONLY` 正则 L590）：纯工具结果回合不发送。
7. **消息清洗链**（L1308-1323）：`coalesceMessagesForAlternation( resolveOrphanToolCalls( encodeVideoAttachments( encodeAudioAttachments( stripUnsupportedImageParts( mapUserInlineAttachments(messages) )))))`；音视频被替换为 sentinel 文本 part，由 `model-factory.ts` 的 fetch 包装解码回 `input_audio`/`input_video`（L1537-1585）。
8. **continue 续写**：`baseMessages + assistant{reasoning,text}:true` 作为续写 prefill（L1327-1349），`prependContinuationToUIStream` 把 partial 注入首个 delta（L680-723）。
9. **`streamText`**（L1369-1389）：`tools: shouldEnableTools ? this.tools : undefined`、`toolChoice:'auto'`、`experimental_repairToolCall`（仅修 Windows 路径反斜杠 `InvalidToolInputError`，L1380-1388）。`toUIMessageStream`（L1394-1509）在 `finish-step`/`finish` 收集 tokenSpeed/usage。

用户消息构造（`web-app/src/lib/completion.ts` `newUserThreadContent`，L20-117）：图片/音频/视频 base64 data URL 进 content；文档经 `injectFilesIntoPrompt` 注入**不含路径**的元数据（file_id/name/type/size/chunks/mode）；inline 文档全文进 `metadata.inline_file_contents`。id 默认 `ulid()`。

## 3. 预算、截断、摘要与压缩

`web-app/src/lib/context-manager.ts`（218 行，全读）：

- `trimMessages`（L69-113）：从新往旧走，预算 = maxCtx − maxOut − systemTokens，**保底保留最后一条用户/assistant 消息**；
- `compactMessages`（L115-217）：把被裁消息拼成 “role: text” 摘录（截断到 max(1024, ctx−512−system) 字符）→ `generateText`（llamacpp 摘要请求，≤500 词系统提示、maxOutputTokens=512）→ 把 `[Previous conversation summary]` 作为**system 消息**前置 → 再次 `trim` 保证不超；失败回退纯 trim。
- 上下文横幅 UI（`$threadId.tsx` L1425+）：`finishReason==='length'` 且 `totalTokens ≥ ctxLen*0.9` → 存 `pendingContinuationRef` + `"Increase Context Size"`（步骤 8192→32768→×1.5，封顶 max）。

## 4. SDK、Provider、模型与协议交接

- 推理参数（temperature/top_k 等）不经 AI SDK 层，而是经 `createCustomFetch` 注入 HTTP body（`model-factory.ts`）。
- 模型加载：`createModelOrAbort`（加载与 abort 竞争，abort 时 `unloadModel`）；llamacpp 固定 `id_slot=0` 复用 KV 缓存（§2 第 1 步）。
- `experimental_repairToolCall` 仅修 Windows 路径反斜杠 `InvalidToolInputError`（L1380-1388）。

## 5. 流式事件、缓冲、节流与顺序

- `experimental_throttle` 由调用方传入（use-chat.ts:100-101 透传 `options.experimental_throttle`，字面值 `50` 在 `$threadId.tsx:292`）；只节流 UI 状态。
- `resume: false`（use-chat.ts:101）表示重启不恢复未完成回合。
- `transportRef` 持 `CustomChatTransport`，跨渲染复用；已有 session transport 优先（use-chat.ts L49-62）；会话 store（`chat-session-store.ts`）按 sessionId 保存 Chat 实例 + transport。
- `prependContinuationToUIStream` 把续写 partial 注入首个 delta（L680-723）；`toUIMessageStream` 在 `finish-step`/`finish` 收集 tokenSpeed/usage（§2 第 9 步）。
- 观测修正：`experimental_throttle: 50` 只节流 UI 状态；`id_slot=0` KV 复用暗示同时只有单个活跃回合在本页；多窗口/多会话并发打到同一 llama-server 的行为未验证。

## 6. 完成、异常、半截流与最终回写

- **stopped 标记**：`metadata.stopped`：`onFinish` 在 `isAbort || finishReason==='length'` 时写 true（`$threadId.tsx` L341-354）；Continue 按钮仅 `isLastMessage && isStopped` 显示（界面在 Chat UI 笔记）。
- **错误回写**：错误元数据 `metadata.error` + `error_code`；`$threadId.tsx` 错误挂载 effect（L1588-1632）：错误找最后一条 assistant（无则最后用户消息）；context overflow 走全局 banner（`stampContextErrorOnThread`+`setContextLimitError`）；否则 `message-errors.setError` 并写 `metadata.error`；L1636-1651 兜底持久化。
- **半截流**：`resume:false` 明确不恢复未完成回合；流式期间消息持久化（`createMessage`）在首包发出后异步完成（乐观写语义在会话与消息管理笔记 §2.4）。

## 7. 停止、重试、续写与重新生成

- **停止**：ChatInput 提供停止/继续流式；abort 竞争发生在 `createModelOrAbort`（§2 第 1 步）；`metadata.stopped` 标记使 Continue 入口出现（§6）。删除与编辑均在流式态禁用（界面在 Chat UI 笔记）。
- **续写**：`handleContinue`（`$threadId.tsx` L1352-1369）：`setContinueFromContent` + `continueUrlRef` 原地续写，**不 fork**（数据语义在会话与消息管理笔记 §4）；request 侧 prefill 见 §2 第 8 步。
- **重新生成**：`handleRegenerate`（L1317-1346）作为兄弟新 sibling，新回复成为 active（数据语义在会话与消息管理笔记 §4）；regen 按钮仅末条。
- **编辑**：用户编辑同步 regenerate，assistant 编辑仅 fork 不重生成（界面入口与对话框在 Chat UI 笔记；数据语义在会话与消息管理笔记 §4）。
- **上下文扩容后的恢复**：扩容阶梯写 model.yml+重启 router（llamacpp）或 stopModel（其他 provider），然后消费续写并在 1s 后 regenerate（结论摘要第 4 条）。

## 8. 队列、多会话并发与后台生成

- 队列存储 `message-queue-store.ts`：`enqueue`/`dequeue`，流式态入队；`status==='ready'` 且无挂起工具时自动发下一条（`sendQueuedMessage` 纯文本绕过附件）；`error` 清空队列；离开线程清队列（§1）。
- 并发：`id_slot=0` KV 复用暗示同时只有单个活跃回合在本页（推测）；多会话并行时各会话独立 `useChat` 实例（`chat-session-store.ts` 按 sessionId 保存）；多窗口/多会话并发打到同一 llama-server 的行为未验证。
- 后台生成：本次调查未发现独立的后台任务管理器（标注为未调查）。

## 9. Agent、工具、知识库与附件注入点

- 工具目录：`refreshTools()` 在 MCP/RAG 工具名变化时刷新（use-chat.ts L111-117，`updateRagToolsAvailability`）；`shouldEnableTools ? this.tools : undefined` 传入 `streamText`（§2 第 9 步）；`splitAssistantToolWaves` 处理 Claude tool_use/tool_result 配对与缓存（L530-567）。
- 纯工具回合：`hasGenuineUserQuery`（`TOOL_RESPONSE_ONLY` 正则 L590）判定后不发送（§2 第 6 步）。
- 附件：`processAttachmentsForSend` 决定 inline/embeddings（界面摄取在 Chat UI 笔记 §3）；图片/音频/视频 base64 data URL 进 content，文档注入不含路径的元数据与 inline 全文（`newUserThreadContent`，§2）；音视频 sentinel part 经 `model-factory.ts` 解码回 `input_audio`/`input_video`（L1537-1585）。
- 推理参数注入：模型默认值、线程内 `parameters`、reasoning 参数按 `{...modelDefaults, ...inferenceParams, ...reasoningParams}` 合并（§2 第 1 步）。

## 10. 退出恢复、日志与已确认边界

- **退出恢复**：`resume: false`——重启不恢复未完成回合；初始消息经 `stickySessionStorage(INITIAL_MESSAGE_PREFIX + threadId, {…})` 恢复发送（`$threadId.tsx` L1145-1172，界面现场恢复在 Chat UI 笔记 §2）。
- 可观测性：`toUIMessageStream` 在 `finish-step`/`finish` 收集 tokenSpeed/usage（§2 第 9 步）；任务级日志/trace 不在本次调查范围。
- 已确认边界：无后端聊天业务服务（前端直连）；`resume:false`；工具错误可恢复性（`output-available`/`output-error`/`output-denied` 状态字段见消息渲染器笔记）。

## 11. 未验证事项

- `id_slot=0` KV 复用下的多窗口/多会话并发行为（推测项）。
- `compactMessages` 摘要削减可能丢失关键上下文——未做质量实测。
- 停止的网络级 abort 效果、退出恢复的端到端行为未运行验证。
- 远程 provider 上推理参数注入与 `paramsSettings` 键删除的实际效果未验证。
- 后台生成机制未调查（未发现独立任务管理器）。

## 12. 关键源码索引

- transport：`web-app/src/lib/custom-chat-transport.ts`（`sendMessages` L1102-1519、`splitAssistantToolWaves` L530-567、`hasGenuineUserQuery` L1302-1306、清洗链 L1308-1323、prefill L1327-1349）。
- 上下文：`web-app/src/lib/context-manager.ts`（`trimMessages` L69-113、`compactMessages` L115-217）。
- 模型交接：`web-app/src/lib/model-factory.ts`（fetch 包装、input_audio/input_video 解码 L1537-1585）。
- useChat 包装：`web-app/src/hooks/use-chat.ts`（throttle/resume 透传、transportRef、refreshTools）；`web-app/src/stores/chat-session-store.ts`。
- 线程页中枢（执行侧）：`web-app/src/routes/threads/$threadId.tsx`（发送 L913-1123、续写 L1352-1369、扩容 L1425+、错误挂载 L1588-1632、队列消费 L1560-1658）。
- 输入/队列：`web-app/src/containers/ChatInput.tsx`（`handleSendMessage` L363-415）；`web-app/src/stores/message-queue-store.ts`；`web-app/src/hooks/usePrompt.ts`。
- 消息构造：`web-app/src/lib/completion.ts`（`newUserThreadContent` L20-117）；`attachmentProcessing.ts`、`useChatAttachments.ts`。
- 错误：`web-app/src/stores/message-errors.ts`。
