# Jan 对话请求与上下文调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：直接阅读源码（AI SDK useChat 包装与自定义 ChatTransport、上下文管理模块、模型工厂与 fetch 注入、线程页执行仲裁、队列 store）并逐条核对符号与行号
>
> 调查范围：一次生成任务的提交入口、上下文拼装顺序、预算/截断/摘要压缩、Provider 与模型交接、流式事件链、最终化与回写、停止/重试/续写/重新生成、队列与并发、外部能力注入点、退出恢复与可观测性；会话数据语义进入会话与消息管理类目，界面工作流进入 Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

普通 Chat 的生成由前端 useChat 包装配合自定义传输层发起；Cowork 复用同一传输层完成模型调用，多步工具循环与预算交给独立的 coworkRunner 管理；CLI/TUI 在 Rust Agent 核心执行，仅使用远程 Provider。三条链的入口分别在 `web-app/src/lib/coworkTransport.ts:29-48`、`web-app/src/lib/coworkRunner.ts:15-25,407-445`、`src-tauri/jan-cli/src/main.rs:1-5`。下文普通 Chat 的 resume:false、扩容与队列语义只覆盖第一条链。

核心链条与关键事实：

1. **流式管线**：界面状态按 50ms 节流刷新，重启或重新挂载时未完成回合不再恢复，传输层实例按 sessionId 复用；推理参数绕过 AI SDK 层，由 createCustomFetch 直接写入 HTTP 请求体（`$threadId.tsx:292`、`use-chat.ts:101`、`model-factory.ts:437`）。
2. **上下文管理在传输层内**：启用 max_context_tokens 后，按 auto_compact 在摘要压缩与直接截断之间二选一；完成原因是 length 且 token 达到上下文长度的 0.9 倍时，冻结部分消息并提示用户手动扩容，扩容阶梯为 8192、32768，再往上按 1.5 倍增长。
3. **队列**：发送时若正在流式且目标线程就是当前线程，消息先入队；线程就绪且没有挂起工具时自动发下一条，出错或离开线程时清空队列。队列消息显示在输入区顶部的 QueuedMessageChip，界面部分见 Chat UI 笔记。
4. **错误与恢复**：错误 banner 置顶显示（OOM、backend、context 三类），最后一条失败的 assistant 消息被隐藏；扩容流程写入 model 设置并重启 router（llamacpp）或调用 stopModel（其他 provider），随后消费续写 prefill，1 秒后触发重新生成。

## 系统边界与生成任务主链

Cowork 先校验所选模型支持工具并占用该 session 的运行句柄，再冻结本次工具目录，由前端循环逐步调用 transport、串行派发工具；完成或异常收尾都把显示 turns 与模型 UIMessage 历史提交到会话 store。不同 session 有独立句柄，同一 session 正在运行时拒绝再次启动（[cowork.tsx:447–489](../../jan/web-app/src/routes/cowork.tsx#L447-L489)、[cowork.tsx:1029–1052](../../jan/web-app/src/routes/cowork.tsx#L1029-L1052)）。

预算以一次用户请求为单位：最多 100 个模型步骤，token 花费上限 200000，每次 `runRequest` 都从零开始；命名为 `MAX_SESSION_TOKENS` 的常量约束的是单次请求内的 token 花费。步骤花费计算新生成 token 与提示增长，避免把每步重放的上下文重复计费（[coworkBudget.ts:10–23、46–88](../../jan/web-app/src/lib/coworkBudget.ts#L10-L88)、[cowork.tsx:682–689](../../jan/web-app/src/routes/cowork.tsx#L682-L689)）。取消传播给模型、工具与子 Agent，已启动的 shell 另有取消入口；运行句柄位于组件之外，离开路由不自动中断。

队列也按 Cowork session 归属：正常完成才自动发送下一条，即使用户已切到另一 session，仍采用原 session 的模型和技能上下文；出错清空，停止或预算触限则保留可见队列。手动 `/compact` 只改写模型重放的 `messages`，保留用户阅读的 turns，因而之后编辑或删除需要按同一用户提问对齐两份历史（[cowork.tsx:1054–1117](../../jan/web-app/src/routes/cowork.tsx#L1054-L1117)、[useCoworkSessions.ts:272–295](../../jan/web-app/src/hooks/useCoworkSessions.ts#L272-L295)）。

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

- **发送入口**：ChatInput 的 handleSendMessage 在提交前做两次判定：没有可用模型时直接拦截，正在流式且目标线程就是当前线程时把消息入队，其余情况组装提交参数交给下游。首页尚无提交回调时改走创建线程，并把待发消息暂存在 sessionStorage（`ChatInput.tsx:364-518,625`）。
- **发送管线**：processAndSendMessage 先合并并处理附件，再构造、持久化用户消息，最后调用发送入口；分支线程会把父消息 id 写入 metadata（`$threadId.tsx:1064-1079,1449`）。
- **任务状态机**：任务状态由 AI SDK 的 Chat 对象持有，取值有 submitted、streaming、ready、error 四种（字段语义见会话与消息管理笔记 §1.2）；CHAT_STATUS 只是界面用的常量，实际流式状态由会话 store 按 threadId 从 Chat 实例派生。出现 banner 错误时，当前状态被强制改为 ready 以终止卡住的流（`containers/message/types.ts:3-6`、`$threadId.tsx:692-693`）。
- **自动发下一条**：线程就绪且没有挂起的工具调用时，取队首的纯文本消息直接发送；处理中的引用标记防止重入，出错或离开线程都会清空队列（`$threadId.tsx:1560-1575`，清空逻辑见同文件 L1127-1140、L1578-1582、L1654-1658）。

## 2. 历史选择与上下文拼装顺序

`CustomChatTransport.sendMessages`（`custom-chat-transport.ts:1382` 起）执行顺序：

1. **模型创建**：发送前先取模型默认采样参数与线程助手参数，再解析 llamacpp 的思考预算，最后叠加推理参数，覆盖顺序为模型默认、线程参数、推理参数。预定义远程 provider 的采样参数键在这一步删除；llamacpp 固定使用 id_slot=0，并把 thread_id 传给 worker，使同一模型与兼容配置下的线程 KV 状态可以保存和恢复。模型加载与取消的竞争由 createModelOrAbort 处理，取消时卸载 llamacpp 模型；思考开关最终以 chat_template_kwargs.enable_thinking 传入（`custom-chat-transport.ts:634-655,1054-1231`）。
2. **工具目录刷新**：refreshTools 在发送前重建 RAG、MCP 与 web 三类工具，过程包含禁用集过滤与 MCP 智能路由，web 侧提供 web_search 和 web_fetch，细节见 §9（L1217）。
3. **工具波次拆分**：splitAssistantToolWaves 把「工具调用后紧跟文本」的 assistant 回合拆成连续多条消息，保持 Claude 要求的工具消息配对，同时让 KV 缓存前缀保持稳定（L630）。
4. **system 提示拼接**：buildSystemPrompt 按固定顺序拼出 system 内容，依次是助手指令、Agent 记忆摘要、附件说明、Web 搜索指令与 Agent 工具说明。附件说明是一段静态文本，不随实际附件变化，用以保住提示缓存；Web 搜索指令教模型调用搜索与抓取工具并内联引用标记；记忆摘要取自 refreshTools 开头那一次快照，提示里只放摘要。拼装结果为空时不发送 system（L1025-1037）。
5. **上下文管理**：maxContextTokens 大于 0 时，auto_compact 为真且模型可用则走摘要压缩，否则走直接截断。system 提示计入 token，可用预算为上下文上限减去最大输出与 system 占用（L1258-1297）。
6. **真实用户查询判定**：发送前检查本回合是否只剩工具结果，hasGenuineUserQuery 为假就直接报错返回，避免把空窗口交给聊天模板（L732）。
7. **消息清洗链**：发送前依次合并相邻用户消息、补齐孤儿工具调用、移除模型不支持的图片、编码音视频并注入 inline 文档；请求侧的 fetch 包装再把音视频标记还原成 input_audio 或 input_video（本文件 L1310-1323，fetch 包装见 `model-factory.ts:655-732`）。
8. **续写 prefill**：续写请求把原有消息加上一条只含 reasoning 与 text 的 assistant 消息作为前置（L1327-1349）；prependContinuationToUIStream 再把这段 partial 内容注入新流的首个 reasoning 或 text delta，界面看不出接缝（L680-723）。
9. **发起生成**：streamText 在启用工具时挂上当前工具集，工具选择设为 auto，同时传入最大输出 token 与远程 provider 的 reasoning 选项（L1356-1361）。工具参数修复只处理 Windows 路径中的反斜杠；toUIMessageStream 在 finish-step 与 finish 两个阶段收集 tokenSpeed 和 usage 写入消息 metadata（L1380-1452）。

用户消息构造（`web-app/src/lib/completion.ts` `newUserThreadContent`，L20-117）：图片/音频/视频 base64 data URL 进 content parts；文档经 `injectFilesIntoPrompt` 注入**不含路径**的元数据（id/name/type/size/chunkCount/injectionMode，L37-48）；inline 文档全文进 `metadata.inline_file_contents`（L107-115）；id 默认 `ulid()`。

## 3. 预算、截断、摘要与压缩

`web-app/src/lib/context-manager.ts`：

- **token 估算**：estimateTokens 按字符数除以 3.5 做启发式换算；estimateMessageTokens 在每条消息上再附加固定开销；estimateConversationTokens 汇总整段会话（`context-manager.ts:14,89,96`）。
- **截断**：trimMessages 用上下文上限减去最大输出与 system 占用得到预算，从最新消息往旧消息累加，超出预算立即停止，并保证至少保留最后一条消息，返回被裁掉的条数（`context-manager.ts:95-107,126`）。
- **摘要压缩**：compactMessages 先跑一遍截断拿到要裁掉的消息，把这些消息拼成「role: text」形式的摘录，摘录长度上限为摘要预算的 3.5 倍，预算取 max(1024, 上下文上限 − 512 − 摘要 system 估算)；随后调用 generateText 生成不超过 500 词的摘要，maxOutputTokens 设为 512，把 `[Previous conversation summary]` 作为一条 system 消息放在最前，再跑一次 trimMessages 确认不超预算；摘要生成失败时回退为纯截断并打印警告（`context-manager.ts:168-215`）。
- **触发条件**：线程助手参数 max_context_tokens 大于 0 且开启 auto_compact 时生效，截断与摘要都在每次发送时同步执行，被裁掉的消息不回填。
- **工具结果上限**：deriveToolOutputCap 从上下文预算换算出单次工具输出可占的字符数，再与 MCP 配置的 maxToolOutputChars 取较小值，避免工具结果吃掉刚算好的预算（`context-manager.ts:36`）。
- **上下文扩容**：完成原因为 length 且总 token 达到上下文长度的 0.9 倍时，线程页记下待续写内容、给线程打上上下文错误标记并显示 banner（`$threadId.tsx:304-330`）。用户点击「Increase Context Size」后按阶梯抬高上限：当前值不足 8192 取 8192，不足 32768 取 32768，再往上按 1.5 倍增长，并以 controller_props.max 封顶（默认 131072）。llamacpp 走 updateModelSettings 写入模型设置并依赖 router 重启，其他 provider 调 stopModel；随后消费待续写的 partial 作为 prefill，1 秒后触发重新生成（同文件 L1439-1516）。扩容由用户手动触发，自动扩容已在注释 L318-319 中标注移除。

## 4. SDK、Provider、模型与协议交接

- **模型工厂**：ModelFactory.createModel 按 provider 分派，createCustomFetch 与 key 轮换分别位于 `model-factory.ts:437` 和 L833。llamacpp 与 mlx 先启动模型，再从会话查询里取到端口和 api_key；远程 provider 使用官方 SDK 配合自定义 fetch，OpenAI 走 Responses API（同文件 L902-984、L1167）。
- **参数注入**：createCustomFetch 把合并后的参数写进请求 body，同时规整键名，例如把 max_output_tokens 转成 max_tokens，映射表见 WIRE_KEY_REMAP。客户端键与 llamacpp 专属参数会被剥离；上游拒收采样参数时，它移除注入参数重试一次并提示用户。错误响应体会做清洗，llamacpp 收到无 body 的 500 响应则重载模型（`model-factory.ts:423-562`）。
- **abort 与取消**：MLX 的 fetch 包装在 abort 时向 /v1/cancel 发请求；llamacpp 在模型加载期收到 abort 会调用 unloadLlamaModel 卸载模型（§2 第 1 步）；流式期间 abortSignal 原样透传给 streamText（`model-factory.ts:1045-1064`）。
- **无后端重连**：reconnectToStream 是显式空实现，注释写明没有可重连的后端（L1521-1530）。

## 5. 流式事件、缓冲、节流与顺序

- **界面节流**：experimental_throttle 设为 50ms，经 useChat 包装透传到线程页，只控制 UI 状态更新频率，不改写事件内容（`$threadId.tsx:292`、`use-chat.ts:100`）。
- **不恢复未完成回合**：resume 置为 false 后，重启或重新挂载都不会续上上次未完成的回合（`use-chat.ts:101`）。
- **传输层复用**：优先取已有 session 的传输层实例，并按 sessionId 复用 Chat 实例（`use-chat.ts:49-62`、`chat-session-store.ts:65-119`）。
- **顺序与防串扰**：streamGeneration 单调递增，被替代的请求（例如 Reload 后遗留的旧请求）其 onError 与 onFinish 不再清除 loading 或 stream 状态；setCurrentStreamThreadId 记录当前流式线程供全局界面使用（`custom-chat-transport.ts:751,1113,1460,1488`）。
- **续写注入**：prependContinuationToUIStream 在首个 reasoning-start 或 text-start 之后插入 prefill delta（L680-723，见 §2 第 8 步）。
- **用量收集**：toUIMessageStream 在 finish-step 阶段收集每秒 token 与提示速度，在 finish 阶段把完成原因、usage 与 tokenSpeed 写进消息 metadata；onFinish 回调再把 usage 交给 onTokenUsage，它是 TokenSpeedIndicator 的数据源（L1403-1452、L1499-1507）。

## 6. 完成、异常、半截流与最终回写

- **stopped 标记**：onFinish 在请求被中断或完成原因为 length 时，把 metadata.stopped 置为 true，并同步更新 chatMessages 副本；Continue 按钮只在这一条是末条且已被标记停止时出现，界面部分见 Chat UI 笔记 §6（`$threadId.tsx:293-353`）。
- **落盘**：有实质内容的 assistant 消息在 onFinish 时持久化：planContinuation 让它继承 parentId、删掉被替换的旧 partial、清掉历史上的 error 标记；分支线程里找不到 parent 时由 resolveAssistantParent 兜底；新生成的消息成为父节点的 activeChild（`$threadId.tsx:385-459`）。
- **错误回写**：错误处理 effect 先找到最后一条 assistant 消息（没有则取最后一条用户消息）；上下文溢出走全局 banner，其余错误交给 useMessageErrors 写入 metadata.error；另一个兜底 effect 再按 store 同步一次落盘（`$threadId.tsx:1588-1651`）。
- **半截流**：resume 为 false 时不恢复未完成回合；流式期间的消息持久化采用首包发出后的异步乐观写入；出现 banner 错误时，effectiveStatus 被强制成 ready，把卡住的流终止（§1，持久化见会话笔记 §2.4）。
- **标题生成**：onFinish 之后按节拍触发自动标题（会话笔记 §5）；llamacpp 下要等 router 空闲才发，AbortController 可随时取消。

## 7. 停止、重试、续写与重新生成

- **停止**：用户点 ChatInput 的停止按钮（界面见 Chat UI 笔记 §5）会调用 AI SDK 的 stop，线程页把它作为 onStop 传入；模型加载阶段的取消由 createModelOrAbort 竞争处理（§2）；banner 错误出现时另有 effect 自动停止；工具执行循环持有独立的 toolCallAbortController，切线程时中止（`$threadId.tsx:879-888,1531-1542,1856`）。
- **续写（Continue）**：handleContinue 先把待续的 text 与 reasoning 写入 continueFromContent，并记下替换目标 id，再触发重新生成；请求侧的 prefill 见 §2 第 8 步，数据侧是原地替换、不新建分支（会话笔记 §4，`$threadId.tsx:1352-1369`）。
- **重新生成**：handleRegenerate 把新结果作为兄弟消息生成（会话笔记 §4），执行前先清掉 banner 错误；regen 按钮只在最后一条消息上可用（`$threadId.tsx:1317-1346`）。
- **编辑**：编辑用户消息会同步触发重新生成，编辑 assistant 消息只做 fork，不重新生成（数据语义见会话笔记 §4，界面见 Chat UI 笔记 §6）。
- **扩容后恢复**：用户抬升上下文上限后，先消费待续写内容作为 prefill，1 秒后执行重新生成（§3）。

## 8. 队列、多会话并发与后台生成

- **队列存储**：每个线程一条队列，由 message-queue-store.ts（71 行）维护，提供入队、原子取删、移除、清空与读取操作；入队条件是线程正在流式且就是当前线程（§1）。
- **消费**：线程状态为 ready 且没有挂起的工具时自动发送下一条，纯文本消息绕过附件处理（§1）；出错或离开线程都会清空队列，removeSession 也会清掉该会话的队列（`chat-session-store.ts:181`）。
- **并发与本地缓存**：llamacpp 的 worker 固定使用 id_slot=0，但以 thread_id 区分需要保存和恢复的状态：换入新线程时先保存被替换 slot 的状态，再恢复目标线程，并用模型、预设、构建与模型文件校验可用性。多窗口、多会话并发下的实际排队与恢复时序尚未验证；不同线程各持一份 Chat 会话实例，工具集也按线程隔离（`engine/http.rs:225-280`、`engine/slots.rs:35-175`，会话实例见 `chat-session-store.ts:8-12`）。
- **后台生成**：普通 Chat 的标题生成与嵌入在发送主链内异步执行；Cowork 的 Agent 循环保存在模块级运行状态中，切出路由不会自动中断，会话仍能收到子 Agent 的完成通知（`coworkRunner.ts:15-25,101-116`、`cowork.tsx:923-941`）。

## 9. Agent、工具、知识库与附件注入点

- **工具目录**：refreshTools 在每次发送前重建 RAG、MCP 与 web 三类工具，开头先取一次记忆摘要快照。MCP 可启用智能路由，路由结果冻结在传输层内以保持提示前缀稳定；MCP 或 RAG 的工具名集合发生变化时同样触发刷新（`custom-chat-transport.ts:730-734,1056-1308`、`use-chat.ts:111-117`）。
- **注入请求**：请求体在启用工具时挂上当前工具集，工具选择设为 auto，splitAssistantToolWaves 保证历史里 tool_use 与 tool_result 成对（§2 第 9 步）。
- **执行循环**：onFinish 内串行执行工具：RAG 工具直接放行，MCP 与第三方工具走审批，web 工具内建执行；结果经 addToolOutput 回填，SDK 依据 sendAutomaticallyWhen 的判定自动续发（`$threadId.tsx:538` 起，followUpMessage 见 L180-191）。工具执行语义属 Agent 工具类目，本笔记只记录注入点。
- **附件**：processAttachmentsForSend 在发送前决定走 inline 还是 embeddings：项目文件强制 embeddings，auto 模式按 token 阈值判断，单个文件的显式选择可覆盖；媒体直接进 content parts，文档元数据进文本，inline 全文进 metadata（§2 用户消息构造，`attachmentProcessing.ts:78-319`）。
- **推理参数注入**：模型默认、线程参数与 reasoning 参数按序合并（§2 第 1 步）；预定义的远程 provider 会剥掉全部采样参数键。

## 10. 退出恢复、日志与已确认边界

- **退出恢复**：resume 为 false 时重启不恢复未完成回合；首页新聊天的待发消息先暂存在 sessionStorage，进入线程页后再恢复发送（键名见 `constants/chat.ts:15-17`，恢复逻辑见 `$threadId.tsx:1145-1172`；界面现场恢复在 Chat UI 笔记 §2）。
- **可观测性**：toUIMessageStream 在 finish-step 与 finish 阶段收集 tokenSpeed 和 usage（§5），消息级字段记录在 metadata 里；任务级的日志与 trace 不在本次调查范围，本次未找到按任务 id 关联的日志机制。
- **已确认边界**：聊天业务没有后端服务，前端直连，reconnectToStream 是空实现；未完成回合不随重启恢复；工具错误的可恢复性由 output-available、output-error、output-denied 三个状态字段表达，字段定义在消息渲染器笔记；上下文扩容需要用户手动触发。
- **banner 与 metadata.error 并存**：全局 banner 覆盖 oom、backend、context 三类错误，置顶显示并隐藏最后一条失败的 assistant 消息，同时 metadata.error 也会写入；banner 端配置决定最终呈现【代码确认】，两者并存时的实际界面行为未运行验证。

## 11. 未验证事项

- `id_slot=0` KV 复用下的多窗口/多会话并发行为（推测项）。
- `compactMessages` 摘要削减对关键上下文的影响（未做质量实测；失败回退纯 trim 已代码确认）。
- 停止的网络级 abort 效果、退出恢复的端到端行为（未运行验证）。
- 远程 provider 上参数注入与 `paramsSettings` 键删除的实际效果（未运行验证）。
- Cowork 切换页面与应用退出后进程级继续运行的差异未实测；CLI 项目会话跨进程恢复未运行验证。
- 自动发下一条队列消费与工具执行循环的完整时序（未运行验证）。

## 12. 关键源码索引

- transport：`web-app/src/lib/custom-chat-transport.ts`（`sendMessages` :1382、`splitAssistantToolWaves` :630、`hasGenuineUserQuery` :732、`buildSystemPrompt` :1025、`refreshTools` :1056-1308、`prependContinuationToUIStream` :813 起）。
- 上下文：`web-app/src/lib/context-manager.ts`（`estimateTokens` :14、`deriveToolOutputCap` :36、`trimMessages` :126、`compactMessages` :181）。
- 模型交接：`web-app/src/lib/model-factory.ts`（`createCustomFetch` :437、key 轮换 :833）。
- useChat 包装：`web-app/src/hooks/use-chat.ts`（throttle/resume 透传、transportRef、refreshTools 触发）；`web-app/src/stores/chat-session-store.ts`。
- 线程页执行中枢：`web-app/src/routes/threads/$threadId.tsx`（`processAndSendMessage` :1449、onFinish :538、`handleRegenerate` :1930、`handleContinue` :1971、错误与 banner 见同文件 `effectiveStatus` :1147）。
- 输入/队列：`web-app/src/containers/ChatInput.tsx`（`handleSendMessage` :625）；`web-app/src/stores/message-queue-store.ts`。
- 消息构造与附件：`web-app/src/lib/completion.ts`（`newUserThreadContent` L20-117）；`web-app/src/lib/attachmentProcessing.ts`；`web-app/src/lib/fileMetadata.ts`。
- 错误：`web-app/src/stores/message-errors.ts`、`web-app/src/utils/error.ts`。
