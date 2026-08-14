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

1. **流式管线**：`experimental_throttle: 50` 只节流 UI 状态，`resume: false` 不恢复未完成回合（实现分别见 `$threadId.tsx:292`、`use-chat.ts:101`）；transport 实例按 sessionId 复用。推理参数不经 AI SDK 层，而是由 `createCustomFetch` 注入 HTTP body（`model-factory.ts:366-564`）。
2. **上下文管理在 transport 内**：启用 `max_context_tokens` 后，根据 `auto_compact` 选择摘要压缩或直接截断；完成原因是 length 且 token 达到上下文长度的 0.9 倍时冻结部分消息，并提示用户手动扩容，扩容阶梯为 8192、32768、再按 1.5 倍增长。
3. **队列**：发送时若正在流式且当前线程存在则入队；就绪状态且无挂起工具时自动发下一条，错误或离开线程时清队列。队列消息显示在输入区顶部 `QueuedMessageChip`（界面在 Chat UI 笔记）。
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

- **发送入口**：`handleSendMessage`（`ChatInput.tsx:363-415`）：无模型时拦截；正在流式且在线程内时入队，否则组装提交参数。首页没有提交回调时，走创建线程并通过 sessionStorage 暂存待发消息（L364-518）。
- **发送管线**：`processAndSendMessage`（`$threadId.tsx:913-1123`）先合并和处理附件，再构造、持久化用户消息，最后调用发送入口；分支线程的父消息写入 metadata（L1064-1079）。
- **任务状态机**：由 AI SDK Chat 承载，消息状态包括 submitted、streaming、ready、error（数据字段语义见会话与消息管理笔记 §1.2）。`CHAT_STATUS`（`containers/message/types.ts:3-6`）只是 UI 常量；会话 store 按 threadId 保存 Chat 实例并派生流式状态。出现 banner 错误时，当前状态被强制改为 ready 以终止卡住的流（`$threadId.tsx:692-693`）。
- **自动发下一条**（`$threadId.tsx:1560-1575`）：就绪且没有挂起工具时取出队首并发送纯文本消息；处理中的引用防止重入，错误和离开线程都会清空队列（L1127-1140、L1578-1582、L1654-1658）。

## 2. 历史选择与上下文拼装顺序

`CustomChatTransport.sendMessages`（`custom-chat-transport.ts:1102-1519`）执行顺序：

1. **模型创建**（L1128-1215）：先读取模型默认采样参数和线程助手参数，再解析 llamacpp 的思考预算；合并顺序是模型默认、线程参数、推理参数，后者优先级最高（L1176-1180）。预定义远程 provider 会删除采样参数键；llamacpp 固定 `id_slot=0` 复用 KV 缓存。模型加载与取消竞争由 `createModelOrAbort` 处理，取消时卸载 llamacpp 模型；推理开关最终进入 `chat_template_kwargs.enable_thinking`（相关实现见 L634-655、L1054-1100、L1181-1189）。
2. **refreshTools()**（L1217）：RAG/MCP/web 工具目录构建（禁用集过滤、MCP 智能路由、`web_search`/`web_fetch`），见 §9。
3. **splitAssistantToolWaves**（L1223）：把工具调用后跟文本的 assistant 回合拆成连续多条，以保持 Claude 工具消息配对和 KV 缓存前缀一致（L530-567）。
4. **system 拼接**（L1229-1240）：`systemMessage`（`renderInstructions(threadAssistant.instructions)`，`$threadId.tsx:205-208`）+ `buildFilesSystemInstruction`（L1594-1613，静态说明 `[ATTACHED_FILES]` 块、不随附件变化保提示缓存）+ `buildWebSearchSystemInstruction`（L1621-1634，教模型用 `web_search`/`web_fetch` 并内联 `[[cite:URL]]`）；空白 system 不发送。
5. **上下文管理**（L1258-1297）：`maxContextTokens>0` 时 `auto_compact && this.model ? compactMessages : trimMessages`；system 计 token；预算 = maxCtx − maxOutput − system。
6. **`hasGenuineUserQuery`**（L1302-1306）：用 `TOOL_RESPONSE_ONLY` 正则（L590）判定纯工具结果回合；没有真实用户查询则提前报错（L599-608）。
7. **消息清洗链**（L1310-1323）：依次合并相邻用户消息、补齐孤儿工具调用、移除模型不支持的图片、编码音视频和注入 inline 文档；发送侧的 fetch 包装再把音视频标记解码回 `input_audio`/`input_video`（`model-factory.ts:655-732`）。旧笔记把解码位置写成 model-factory L1537-1585 有误，已修正。
8. **continue 续写 prefill**：`baseMessages + assistant{reasoning,text}` 作为续写前置（L1327-1349）；`prependContinuationToUIStream`（L680-723）把 partial 注入新流首个 reasoning/text delta，UI 无缝衔接。
9. **`streamText`**（L1369-1389）：启用工具时使用当前工具集，工具选择为 auto，并传入最大输出 token 及远程 provider 的 reasoning 选项（L1356-1361）。工具参数修复只处理 Windows 路径反斜杠；`toUIMessageStream` 在 finish-step 和 finish 阶段收集 tokenSpeed、usage 并写入消息 metadata（L1380-1452）。

用户消息构造（`web-app/src/lib/completion.ts` `newUserThreadContent`，L20-117）：图片/音频/视频 base64 data URL 进 content parts；文档经 `injectFilesIntoPrompt` 注入**不含路径**的元数据（id/name/type/size/chunkCount/injectionMode，L37-48）；inline 文档全文进 `metadata.inline_file_contents`（L107-115）；id 默认 `ulid()`。

## 3. 预算、截断、摘要与压缩

`web-app/src/lib/context-manager.ts`（217 行，全读）：

- `estimateTokens`（L13-16）：字符/3.5 的启发式估算；`estimateMessageTokens`（L42-46）每消息 +4 开销。
- `trimMessages`（L69-113）：预算 = maxCtx − maxOutput − systemTokens；从新往旧累加，**超预算即停**；保证至少保留最后一条消息（L95-107）；返回 trimmedCount。
- `compactMessages`（L115-217）：先算 trim 结果 → 把被裁消息拼成 `"role: text"` 摘录（摘录字符上限 = 摘要预算 ×3.5，预算 = `max(1024, maxCtx − 512 − 摘要 system 估算)`，L168-178）→ `generateText`（≤500 词摘要 system、`maxOutputTokens: 512`，L181-186）→ 把 `[Previous conversation summary]` 作为 **system 消息**前置（L190-199）→ 再次 `trimMessages` 保证不超（L205-206）；摘要失败回退纯 trim（L213-215，console.warn）。
- 触发条件：`max_context_tokens`（线程助手参数）> 0 且 `auto_compact`（transport L1253-1256）；两路都在每次发送时同步执行，不可逆（不回填被裁消息）。
- **上下文扩容**（`$threadId.tsx:1425-1524`）：`finishReason==='length'` 且 `totalTokens ≥ ctxLen*0.9` 时（L304-330）存 `pendingContinuationRef` + `stampContextErrorOnThread` + 显示 banner；"Increase Context Size" 按钮阶梯 `当前<8192→8192→<32768→32768→否则×1.5`，封顶 `controller_props.max`（默认 131072，L1439-1454）；llamacpp 走 `updateModelSettings`（写 model 设置并依赖 router 重启）否则 `stopModel`（L1486-1502），然后消费 pending partial 作为续写 prefill（L1507-1512）并在 1s 后 `handleRegenerate`（L1514-1516）。**扩容是用户手动触发，无自动扩容**（注释 L318-319 明确 auto-increase 已移除）。

## 4. SDK、Provider、模型与协议交接

- **模型工厂**：`ModelFactory.createModel`（`model-factory.ts:847-897`）按 provider 分派。llamacpp/mlx 先启动模型，再通过会话查询取得端口与 api_key；远程 provider 使用官方 SDK 和自定义 fetch，OpenAI 走 Responses API（L902-984、L1167）。
- **参数注入**：`createCustomFetch`（`model-factory.ts:366-564`）把合并后的参数写入请求 body，并规整键名，例如把 max_output_tokens 转为 max_tokens（L385-388）。它还会剥离客户端键和 llamacpp 专属参数；上游拒绝采样参数时，自动移除注入参数重试一次并提示用户。错误 body 会清洗，llamacpp 遇到无 body 的 500 响应则重载模型（L423-562）。
- **abort 与取消**：MLX fetch 包装在 abort 时调 `/v1/cancel`（L1045-1064）；llamacpp 模型加载期 abort 调 `unloadLlamaModel`（§2 第 1 步）；流式期间 `options.abortSignal` 透传给 `streamText`。
- **无后端重连**：`reconnectToStream` 是显式 no-op（L1521-1530，注释：无后端可重连）。

## 5. 流式事件、缓冲、节流与顺序

- `experimental_throttle: 50`（`$threadId.tsx:292`，经 `use-chat.ts:100` 透传）只节流 UI 状态更新，不改写事件内容。
- `resume: false`（`use-chat.ts:101`）表示重启或重挂时不恢复未完成回合。
- transport 复用：优先取已有 session 的 transport，并按 sessionId 复用 Chat 实例（实现见 `use-chat.ts:49-62`、`chat-session-store.ts:65-119`）。
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

- **队列存储**：`message-queue-store.ts`（71 行）维护 per-thread 队列，提供入队、原子取删、移除、清空和读取操作；入队条件是流式态且处于当前线程（§1）。
- **消费**：`status==='ready'` 且无挂起工具时自动发下一条（纯文本绕过附件，§1）；`error` 清空队列；离开线程清队列；`removeSession` 也清对应队列（`chat-session-store.ts:181`）。
- **并发**：llamacpp 固定 `id_slot=0`（§2）暗示同一 llama-server 上同一活跃回合复用 KV——多窗口/多会话并发打到同一 server 的行为未验证（推测项）；不同线程各有独立 Chat 会话实例，`sessionData.tools` 也按线程隔离（`chat-session-store.ts:8-12`）。
- **后台生成**：本次未发现独立的后台任务管理器（检查范围：web-app 无后台任务 store/队列；标题生成与嵌入是发送主链内的异步步骤）——标注为未找到。

## 9. Agent、工具、知识库与附件注入点

- **工具目录**：`refreshTools`（`custom-chat-transport.ts:815-977`）在每次发送前重建 RAG、MCP 和 web 工具。MCP 可选智能路由，路由结果冻结在 transport 内以保持提示前缀稳定；MCP/RAG 工具名集合变化时也会刷新（L730-734、`use-chat.ts:111-117`）。
- **注入请求**：`tools: shouldEnableTools ? this.tools : undefined` + `toolChoice:'auto'`（§2 第 9 步）；`splitAssistantToolWaves` 保证历史中 tool_use/tool_result 配对。
- **执行循环**：`onFinish` 内串行执行工具（`$threadId.tsx:462-587`）：RAG 工具 auto-allow，MCP/第三方走审批（`requestApproval`），web 工具内建执行；结果经 `addToolOutput` 回填，SDK `sendAutomaticallyWhen`（`followUpMessage`，L180-191）自动续发。工具执行语义属 Agent 工具类目，本笔记只记录注入点。
- **附件**：`processAttachmentsForSend`（`attachmentProcessing.ts:78-319`）在发送前决定 inline/embeddings（项目文件强制 embeddings、auto 模式按 token 阈值、per-file 选择覆盖）；媒体直接进 content parts；文档元数据进文本、inline 全文进 metadata（§2 用户消息构造）。
- **推理参数注入**：模型默认 + 线程参数 + reasoning 参数按序合并（§2 第 1 步）；远程 provider 剥离全部采样参数键（`isPredefinedRemoteProvider`）。

## 10. 退出恢复、日志与已确认边界

- **退出恢复**：`resume:false` 表示重启不恢复未完成回合；首页新聊天的待发消息经 sessionStorage 暂存，并在进入线程页时恢复发送（键名和实现见 `constants/chat.ts:15-17`、`$threadId.tsx:1145-1172`；界面现场恢复在 Chat UI 笔记 §2）。
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
