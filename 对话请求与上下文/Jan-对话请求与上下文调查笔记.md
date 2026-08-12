# Jan 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：直接阅读源码（AI SDK useChat 包装与自定义 ChatTransport、上下文管理模块、模型工厂与 fetch 注入、线程页执行仲裁、队列 store）并逐条核对符号与行号
>
> 调查范围：一次生成任务的提交入口、上下文拼装顺序、预算/截断/摘要压缩、Provider 与模型交接、流式事件链、最终化与回写、停止/重试/续写/重新生成、队列与并发、外部能力注入点、退出恢复与可观测性；会话数据语义进入会话与消息管理类目，界面工作流进入 Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的生成管线是"**前端直连模型服务**"模式：没有后端聊天业务服务，React 前端（web-app）通过 AI SDK 的 `useChat` + 自研 `CustomChatTransport` 直接发起流式请求（经 Tauri 本地 API 代理到 llama-server、mlx-server 或远程 provider）。桌面与移动端共用前端逻辑，只在持久化后端分流（数据语义见会话与消息管理笔记）。

核心链条与关键事实（均有源码依据）：

1. **流式管线**：`experimental_throttle: 50`（只节流 UI 状态，`$threadId.tsx:292`）、`resume: false`（`use-chat.ts:101`）；transport 实例按 sessionId 复用；推理参数（temperature/top_k 等）不经 AI SDK 层，而是经 `createCustomFetch` 注入 HTTP body（`model-factory.ts:366-564`）。
2. **上下文管理在 transport 内**：`max_context_tokens>0` 时按 `auto_compact ? compactMessages（模型总结）: trimMessages`；`finishReason==='length'` 且 token ≥ 0.9×ctx_len 时冻结部分消息并提示用户手动扩容（阶梯 `<8192→8192→32768→×1.5`）。
3. **队列**：发送时若正在流式且当前线程存在则入队，`status==='ready'` 且无挂起工具时自动发下一条，`error` 或离开线程清队列；队列消息显示在输入区顶部 `QueuedMessageChip`（界面在 Chat UI 笔记）。
4. **错误与恢复**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；扩容流程写 model 设置 + 重启 router（llamacpp）或 stopModel（其他 provider），消费续写 prefill 并在 1s 后 regenerate。

## 系统边界与生成任务主链

```text
ChatInput.handleSendMessage（isStreaming 时 enqueue，否则组装 onSubmit）
  -> processAndSendMessage（$threadId.tsx L913-1123）：附件合并 → 预览消息 → processAttachmentsForSend
        -> 持久化 userMessage（分支线程写 parentId）-> sendMessage（AI SDK）
  -> useChat（use-chat.ts）-> CustomChatTransport.sendMessages（custom-chat-transport.ts L1102-1519）
        模型创建/参数合并 -> refreshTools -> splitAssistantToolWaves
        system 拼接（instructions + [ATTACHED_FILES] 说明 + web 搜索指令）
        maxContextTokens>0 时 compactMessages / trimMessages（context-manager.ts）
        hasGenuineUserQuery 判定 -> 消息清洗链 ->（continue 续写 prefill）
        streamText -> toUIMessageStream（finish-step/finish 收集 tokenSpeed/usage）
  -> UI 流式消费（throttle 50ms）
  -> onFinish：isAbort || finishReason==='length' -> metadata.stopped=true；工具执行循环；队列消费
```

边界：会话与消息如何持久化、分支数据语义属于会话与消息管理（`../会话与消息管理/Jan-会话与消息管理调查笔记.md`）；Composer 附件摄取、排队提示、错误 banner 等界面工作流属于 Chat UI（`<../Chat UI/Jan-ChatUI调查笔记.md>`）；流式内容如何渲染、工具卡与引用展示属于消息渲染器。

## 1. 提交入口、任务对象与状态机

- **发送入口**：`handleSendMessage`（`ChatInput.tsx:363-415`）：无模型时提示并拦截（L364-367）；正在流式（`isStreaming` = submitted/streaming，L1726）且在线程内时 `enqueue` 入队（L382-390）；否则组装 `onSubmit(prompt, files)`（L415）。首页（无 onSubmit）走创建线程 + sessionStorage 待发消息路径（L418-518）。
- **发送管线**：`processAndSendMessage`（`$threadId.tsx:913-1123`）：附件合并 → 有文档时先插入预览消息 → `processAttachmentsForSend`（inline/embeddings 决策）→ 构造并持久化 userMessage（分支线程写 `parentId` 到 metadata，L1064-1079）→ `sendMessage({parts, id, metadata})`。
- **任务状态机**：由 AI SDK Chat 承载——`ThreadMessage.status` 的 `'submitted'|'streaming'|'ready'|'error'` 是 AI SDK 运行时状态（数据字段语义见会话与消息管理笔记 §1.2）；`CHAT_STATUS`（`containers/message/types.ts:3-6`）是 UI 用常量；`useChatSessions` 按 threadId 保存 Chat 实例与 `isStreaming` 派生值（`chat-session-store.ts:41-49`）。banner 错误存在时 `effectiveStatus` 被强制为 'ready' 以终止卡住的流（`$threadId.tsx:692-693`）。
- **自动发下一条**（`$threadId.tsx:1560-1575`）：`status==='ready'` 且 `sessionData.tools` 为空时 `dequeue` 并 `sendQueuedMessage`（纯文本绕过附件，L1127-1140）；`processingQueueRef` 防重入；`status==='error'` 清空队列（L1578-1582）；离开线程清队列（L1654-1658）。

## 2. 历史选择与上下文拼装顺序

`CustomChatTransport.sendMessages`（`custom-chat-transport.ts:1102-1519`）执行顺序：

1. **模型创建**（L1128-1215）：`extractModelSamplingDefaults`（`MODEL_SAMPLING_SETTING_KEYS`：temperature/top_k/top_p/min_p/repeat_last_n/repeat_penalty/presence_penalty/frequency_penalty，L107-116）取每模型默认；`getActiveInferenceParams`（L773-784）取线程助手 `parameters`（`model-only` 时为空）；llamacpp 解析思考预算符号等级 → 实际 token（`resolveThinkingBudgetTokens` L170-196）；**合并顺序 `{...modelSamplingDefaults, ...inferenceParams, ...reasoningParams}`**（L1176-1180，注释说明 assistant 参数是显式会话级覆盖，优先级最高）；预定义远程 provider 删除全部 `paramsSettings` 键（L1181-1183）；llamacpp 固定 `id_slot=0` 复用 KV 缓存（L1187-1189）；`createModelOrAbort`（L1054-1100）——模型加载与 abort 竞争，abort 时对 llamacpp 调 `unloadLlamaModel`（防泄漏，L1067-1080）。推理开关经 `buildLlamacppReasoningParams`（L634-655）进 `chat_template_kwargs.enable_thinking`。
2. **refreshTools()**（L1217）：RAG/MCP/web 工具目录构建（禁用集过滤、MCP 智能路由、`web_search`/`web_fetch`），见 §9。
3. **splitAssistantToolWaves**（L1223）：把"工具调用后跟文本"的 assistant 回合拆成连续多条（Claude tool_use/tool_result 配对 + 前缀字节一致保 KV 缓存，L530-567）。
4. **system 拼接**（L1229-1240）：`systemMessage`（`renderInstructions(threadAssistant.instructions)`，`$threadId.tsx:205-208`）+ `buildFilesSystemInstruction`（L1594-1613，静态说明 `[ATTACHED_FILES]` 块、不随附件变化保提示缓存）+ `buildWebSearchSystemInstruction`（L1621-1634，教模型用 `web_search`/`web_fetch` 并内联 `[[cite:URL]]`）；空白 system 不发送。
5. **上下文管理**（L1258-1297）：`maxContextTokens>0` 时 `auto_compact && this.model ? compactMessages : trimMessages`；system 计 token；预算 = maxCtx − maxOutput − system。
6. **`hasGenuineUserQuery`**（L1302-1306）：`TOOL_RESPONSE_ONLY` 正则（L590）判定"纯工具结果回合"，无真实用户查询则提前报错（L599-608）。
7. **消息清洗链**（L1310-1323）：`coalesceMessagesForAlternation( resolveOrphanToolCalls( encodeVideoAttachments( encodeAudioAttachments( stripUnsupportedImageParts( mapUserInlineAttachments(messages) )))))`——相邻 user 合并保交替（L568-588）、孤儿工具调用补 `output-error`（L482-509）、无 vision 模型剥离图片 part（L430-458）、音视频替换为 sentinel 文本 part（L1537-1585）、inline 文档全文注入（L1636-1674）；sentinel 由 `model-factory.ts` 的 fetch 包装在**发送侧**解码回 `input_audio`/`input_video`（`decodeAudioSentinelsInBody` L655-690、`decodeVideoSentinelsInBody` L697-732，在 `createCustomFetch` 的 buildBody 内调用 L441-442）——旧笔记把解码位置写成 model-factory L1537-1585 有误，已修正。
8. **continue 续写 prefill**：`baseMessages + assistant{reasoning,text}` 作为续写前置（L1327-1349）；`prependContinuationToUIStream`（L680-723）把 partial 注入新流首个 reasoning/text delta，UI 无缝衔接。
9. **`streamText`**（L1369-1389）：`tools: shouldEnableTools ? this.tools : undefined`、`toolChoice:'auto'`、`maxTokens`、远程 provider 的 reasoning `providerOptions`（L1356-1361）；`experimental_repairToolCall`（L1380-1388）仅重转义 Windows 路径反斜杠（`repairToolArgs`，InvalidToolInputError 专属）。`toUIMessageStream`（L1394-1509）在 `finish-step`/`finish` 收集 tokenSpeed/usage 写入消息 metadata（L1403-1452）。

用户消息构造（`web-app/src/lib/completion.ts` `newUserThreadContent`，L20-117）：图片/音频/视频 base64 data URL 进 content parts；文档经 `injectFilesIntoPrompt` 注入**不含路径**的元数据（id/name/type/size/chunkCount/injectionMode，L37-48）；inline 文档全文进 `metadata.inline_file_contents`（L107-115）；id 默认 `ulid()`。

## 3. 预算、截断、摘要与压缩

`web-app/src/lib/context-manager.ts`（217 行，全读）：

- `estimateTokens`（L13-16）：字符/3.5 的启发式估算；`estimateMessageTokens`（L42-46）每消息 +4 开销。
- `trimMessages`（L69-113）：预算 = maxCtx − maxOutput − systemTokens；从新往旧累加，**超预算即停**；保证至少保留最后一条消息（L95-107）；返回 trimmedCount。
- `compactMessages`（L115-217）：先算 trim 结果 → 把被裁消息拼成 `"role: text"` 摘录（摘录字符上限 = 摘要预算 ×3.5，预算 = `max(1024, maxCtx − 512 − 摘要 system 估算)`，L168-178）→ `generateText`（≤500 词摘要 system、`maxOutputTokens: 512`，L181-186）→ 把 `[Previous conversation summary]` 作为 **system 消息**前置（L190-199）→ 再次 `trimMessages` 保证不超（L205-206）；摘要失败回退纯 trim（L213-215，console.warn）。
- 触发条件：`max_context_tokens`（线程助手参数）> 0 且 `auto_compact`（transport L1253-1256）；两路都在每次发送时同步执行，不可逆（不回填被裁消息）。
- **上下文扩容**（`$threadId.tsx:1425-1524`）：`finishReason==='length'` 且 `totalTokens ≥ ctxLen*0.9` 时（L304-330）存 `pendingContinuationRef` + `stampContextErrorOnThread` + 显示 banner；"Increase Context Size" 按钮阶梯 `当前<8192→8192→<32768→32768→否则×1.5`，封顶 `controller_props.max`（默认 131072，L1439-1454）；llamacpp 走 `updateModelSettings`（写 model 设置并依赖 router 重启）否则 `stopModel`（L1486-1502），然后消费 pending partial 作为续写 prefill（L1507-1512）并在 1s 后 `handleRegenerate`（L1514-1516）。**扩容是用户手动触发，无自动扩容**（注释 L318-319 明确 auto-increase 已移除）。

## 4. SDK、Provider、模型与协议交接

- **模型工厂**：`ModelFactory.createModel`（`model-factory.ts:847-897`）按 provider 分派——llamacpp/mlx 先 `startModel` 再 `find_session_by_model` 拿端口与 api_key（L902-984）；远程 provider 用官方 SDK（anthropic/openai/mistral/xai/google）+ 自定义 fetch；OpenAI 走 Responses API（L1167）。
- **参数注入**：`createCustomFetch`（`model-factory.ts:366-564`）在请求 body 注入合并参数并做键名规整（`max_output_tokens→max_tokens`、`dynatemp_exp→dynatemp_exponent`，L385-388）、剥离客户端侧键、llamacpp 专属 `cache_prompt=true`/`return_progress`/`timings_per_token`（L423-433）；上游采样参数拒绝时**自动剥离全部注入参数重试一次**并 toast 提示（L533-550）；错误 body 清洗（L552-562）；llamacpp 500 无 body 时触发 `reloadModel` 并合成错误（L506-523）。
- **abort 与取消**：MLX fetch 包装在 abort 时调 `/v1/cancel`（L1045-1064）；llamacpp 模型加载期 abort 调 `unloadLlamaModel`（§2 第 1 步）；流式期间 `options.abortSignal` 透传给 `streamText`。
- **无后端重连**：`reconnectToStream` 是显式 no-op（L1521-1530，注释：无后端可重连）。

## 5. 流式事件、缓冲、节流与顺序

- `experimental_throttle: 50`（`$threadId.tsx:292`，经 `use-chat.ts:100` 透传）：只节流 UI 状态更新，不改写事件内容。
- `resume: false`（`use-chat.ts:101`）：重启/重挂不恢复未完成回合。
- transport 复用：`transportRef` 优先取 `useChatSessions` 中已有 session 的 transport（`use-chat.ts:49-62`）；`ensureSession` 按 sessionId 复用 Chat 实例（`chat-session-store.ts:65-119`）。
- **顺序与防串扰**：`streamGeneration` 单调令牌——被替代请求（如 Reload 后的旧请求）的 `onError`/`onFinish` 不再清 loading/stream 状态（`custom-chat-transport.ts:751, 1113, 1460, 1488`）；`setCurrentStreamThreadId`（L1114）记录当前流式线程供全局 UI 使用。
- **续写注入**：`prependContinuationToUIStream`（L680-723）在首个 reasoning-start/text-start 后插入 prefill delta（§2 第 8 步）。
- **用量收集**：`toUIMessageStream` 的 `finish-step` 收集 tokensPerSecond/promptPerSecond，`finish` 写 `finishReason/usage/tokenSpeed` 到消息 metadata（L1403-1452）；`onFinish` 回调把 usage 传给 `onTokenUsage`（L1499-1507，TokenSpeedIndicator 数据源）。

## 6. 完成、异常、半截流与最终回写

- **stopped 标记**：`onFinish`（`$threadId.tsx:293-656`）在 `isAbort || finishReason==='length'` 时写 `metadata.stopped=true`（L341-353）并同步更新 chatMessages 副本；Continue 按钮仅 `isLastMessage && isStopped` 显示（界面在 Chat UI 笔记 §6）。
- **落盘**：有实质内容的 assistant 消息在 onFinish 持久化——`planContinuation` 继承 parentId、删除被替换的旧 partial（L444-449）、清历史 error 标记（L451-459）；分支线程中 parent 丢失时兜底 `resolveAssistantParent`（L385-395）；新生成成为父节点 activeChild（L432-442）。
- **错误回写**：错误挂载 effect（`$threadId.tsx:1588-1632`）——错误找最后一条 assistant（无则最后用户消息）；context overflow 走全局 banner（`stampContextErrorOnThread` + `setContextLimitError`）；否则 `useMessageErrors.setError` 并写 `metadata.error`；L1638-1651 的兜底 effect 再按 store 同步一次落盘。
- **半截流**：`resume:false` 明确不恢复未完成回合；流式期间消息持久化是"首包发出后的异步乐观写"（`useMessages.addMessage`，会话笔记 §2.4）；banner 错误时 `effectiveStatus` 强制 ready 终止卡死流（§1）。
- **标题生成**：onFinish 后按节拍触发自动标题（会话笔记 §5），llamacpp 下等 router 空闲，AbortController 可取消。

## 7. 停止、重试、续写与重新生成

- **停止**：ChatInput 停止按钮（界面在 Chat UI 笔记 §5）调 `stop()`（AI SDK，`$threadId.tsx` 传入 `onStop={stop}` L1856）；模型加载期的 abort 竞争在 `createModelOrAbort`（§2）；banner 错误出现时 effect 自动 `stop()`（`$threadId.tsx:1531-1542`）；工具执行循环用独立 `toolCallAbortController`，切线程时 abort（L879-888）。
- **续写（Continue）**：`handleContinue`（L1352-1369）：`setContinueFromContent({text, reasoning})` + `continueReplaceIdRef` → 触发 regenerate；请求侧 prefill 见 §2 第 8 步；数据侧原地替换不 fork（会话笔记 §4）。
- **重新生成**：`handleRegenerate`（L1317-1346）作为兄弟新 sibling（会话笔记 §4），banner 错误清理后执行；regen 按钮仅末条可用。
- **编辑**：用户编辑同步 regenerate，assistant 编辑仅 fork 不重生成（数据语义在会话笔记 §4；界面在 Chat UI 笔记 §6）。
- **扩容后恢复**：扩容阶梯 → 续写 prefill 消费 → 1s 后 regenerate（§3）。

## 8. 队列、多会话并发与后台生成

- **队列存储**：`message-queue-store.ts`（71 行）per-thread 队列：`enqueue`/`dequeue`（原子读-删）/`removeMessage`/`clearQueue`/`getQueue`；入队条件 = 流式态 + 当前线程（§1）。
- **消费**：`status==='ready'` 且无挂起工具时自动发下一条（纯文本绕过附件，§1）；`error` 清空队列；离开线程清队列；`removeSession` 也清对应队列（`chat-session-store.ts:181`）。
- **并发**：llamacpp 固定 `id_slot=0`（§2）暗示同一 llama-server 上同一活跃回合复用 KV——多窗口/多会话并发打到同一 server 的行为未验证（推测项）；不同线程各有独立 Chat 会话实例，`sessionData.tools` 也按线程隔离（`chat-session-store.ts:8-12`）。
- **后台生成**：本次未发现独立的后台任务管理器（检查范围：web-app 无后台任务 store/队列；标题生成与嵌入是发送主链内的异步步骤）——标注为未找到。

## 9. Agent、工具、知识库与附件注入点

- **工具目录**：`refreshTools`（`custom-chat-transport.ts:815-977`）在每次发送前重建——RAG 工具（有文档且功能可用时）、MCP 工具（可选智能路由 `mcpOrchestrator`，路由结果冻结在 transport 内保提示前缀稳定，L730-734）、web 工具（webSearchEnabled 时注册 `web_search`/`web_fetch`）；`use-chat.ts:111-117` 在 MCP/RAG 工具名集合变化时刷新。
- **注入请求**：`tools: shouldEnableTools ? this.tools : undefined` + `toolChoice:'auto'`（§2 第 9 步）；`splitAssistantToolWaves` 保证历史中 tool_use/tool_result 配对。
- **执行循环**：`onFinish` 内串行执行工具（`$threadId.tsx:462-587`）：RAG 工具 auto-allow，MCP/第三方走审批（`requestApproval`），web 工具内建执行；结果经 `addToolOutput` 回填，SDK `sendAutomaticallyWhen`（`followUpMessage`，L180-191）自动续发。工具执行语义属 Agent 工具类目，本笔记只记录注入点。
- **附件**：`processAttachmentsForSend`（`attachmentProcessing.ts:78-319`）在发送前决定 inline/embeddings（项目文件强制 embeddings、auto 模式按 token 阈值、per-file 选择覆盖）；媒体直接进 content parts；文档元数据进文本、inline 全文进 metadata（§2 用户消息构造）。
- **推理参数注入**：模型默认 + 线程参数 + reasoning 参数按序合并（§2 第 1 步）；远程 provider 剥离全部采样参数键（`isPredefinedRemoteProvider`）。

## 10. 退出恢复、日志与已确认边界

- **退出恢复**：`resume:false`——重启不恢复未完成回合；首页新聊天的待发消息经 `sessionStorage`（键 `initial-message-<threadId>`，`constants/chat.ts:15-17`，`$threadId.tsx:1145-1172`）在进入线程页时恢复发送（界面现场恢复在 Chat UI 笔记 §2）。
- **可观测性**：`toUIMessageStream` 的 finish-step/finish 收集 tokenSpeed/usage（§5）；消息级 `metadata.usage/tokenSpeed`；任务级日志/trace 不在本次调查范围（未发现任务 id 关联日志机制）。
- **已确认边界**：无后端聊天业务服务（前端直连，`reconnectToStream` no-op）；`resume:false`；工具错误可恢复性（`output-available/output-error/output-denied` 状态字段在消息渲染器笔记）；扩容需用户手动触发。
- **banner 与 metadata.error 并存**：全局 banner（oom/backend/context）置顶且隐藏最后一条失败 assistant 消息，同时 `metadata.error` 也会写入——呈现交由 banner 端配置【代码确认】，两者并存的实际 UI 行为未运行验证。

## 11. 未验证事项

- `id_slot=0` KV 复用下的多窗口/多会话并发行为（推测项）。
- `compactMessages` 摘要削减对关键上下文的影响（未做质量实测；失败回退纯 trim 已代码确认）。
- 停止的网络级 abort 效果、退出恢复的端到端行为（未运行验证）。
- 远程 provider 上参数注入与 `paramsSettings` 键删除的实际效果（未运行验证）。
- 后台生成机制未调查（未发现独立任务管理器）。
- 自动发下一条队列消费与工具执行循环的完整时序（未运行验证）。

## 12. 关键源码索引

- transport：`web-app/src/lib/custom-chat-transport.ts`（`sendMessages` L1102-1519、`splitAssistantToolWaves` L530-567、`hasGenuineUserQuery` L599-608、清洗链 L1310-1323、prefill L1327-1349、`refreshTools` L815-977）。
- 上下文：`web-app/src/lib/context-manager.ts`（`trimMessages` L69-113、`compactMessages` L115-217）。
- 模型交接：`web-app/src/lib/model-factory.ts`（`createCustomFetch` L366-564、sentinel 解码 L655-732、`createModelOrAbort` 调用点 L1190）。
- useChat 包装：`web-app/src/hooks/use-chat.ts`（throttle/resume 透传、transportRef、refreshTools 触发）；`web-app/src/stores/chat-session-store.ts`。
- 线程页执行中枢：`web-app/src/routes/threads/$threadId.tsx`（发送 L913-1123、续写 L1352-1369、扩容 L1425-1524、错误挂载 L1588-1651、队列消费 L1560-1658、onFinish L293-656）。
- 输入/队列：`web-app/src/containers/ChatInput.tsx`（`handleSendMessage` L363-415）；`web-app/src/stores/message-queue-store.ts`。
- 消息构造与附件：`web-app/src/lib/completion.ts`（`newUserThreadContent` L20-117）；`web-app/src/lib/attachmentProcessing.ts`；`web-app/src/lib/fileMetadata.ts`。
- 错误：`web-app/src/stores/message-errors.ts`、`web-app/src/utils/error.ts`。
