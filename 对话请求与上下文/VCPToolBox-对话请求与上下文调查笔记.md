# VCPToolBox 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：直接阅读源码：server.js 聊天端点与 /v1/interrupt、routes/protocolBridge.js 协议归一化、modules/chatCompletionHandler.js 请求管线、contextManager.js、messageProcessor.js、roleDivider.js、vcpLoop/toolCallParser.js、handlers/streamHandler.js 与 nonStreamHandler.js、reasoningContentAdapter.js、vcpInfoHandler.js，以及 Plugin/VCPTavern、RAGDiaryPlugin、VCPTimeLine、ContextFoldingV2、OneRing 的 processMessages
>
> 调查范围：一次请求内"客户端历史 → 最终上游 messages → 工具递归 messages"的完整编排：入口归一化、上下文裁剪、预处理器、VCP 工具循环、推理字段分叉、停止与重试；会话事实源不归 VCPToolBox 所有（见会话与消息管理笔记）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 在**单次 HTTP 请求内**拥有完整的"请求历史 → 最终上游 messages → 工具递归 messages"编排能力；它不拥有会话列表、消息编辑/删除/分支或跨请求恢复（数据边界见会话与消息管理笔记）。本次重新核实的主要结论：

- **入口归一化**：OpenAI Chat / Chatvcp / Responses / Anthropic / Gemini 五种协议收敛到同一条主链（`/v1/chat/completions`，`server.js:1217`）；
- **编排是"原地改写消息数组"**：`ChatCompletionHandler.handle()` 对入站 body 原地处理，复制、重排、展开、注入和裁剪，最终把处理后的消息写回 `originalBody.messages`（`modules/chatCompletionHandler.js:1124`）；
- **上下文裁剪是字符数估算**（`contextManager.pruneMessages`），不是摘要压缩，也不保证严格 token 上限；
- **VCP 工具循环走纯文本标记协议**：`<<<[TOOL_REQUEST]>>>`，模型正文即调用声明，工具结果以 `<!-- VCP_TOOL_PAYLOAD -->` user 消息回送再次 POST；
- **模型上下文与前端显示分叉**：工具循环维护独立的 `currentMessagesForLoop`，推理字段另存于日志消息，客户端看到的 SSE/JSON 与模型下一轮读取的内容不是同一份；
- **存在显式的请求级停止与重试机制**：`/v1/interrupt` 端点 + 客户端断联级联中止（本次调查新核实，旧版本未记录）；上游调用有状态码重试、连接超时、语义路由候选模型回退；响应层有按 `clientIp::messageId` 的去重回放。

## 系统边界与生成任务主链

```text
外部前端（VCPChat / OpenWebUI / 任意客户端）提交 messages
  -> POST /v1/chat/completions（或经 protocolBridge 归一化后本机转发）
  -> ChatCompletionHandler.handle()（modules/chatCompletionHandler.js:644）
      -> 读取 requestId/messageId，移除 vcpchatExtensions（714-728）
      -> contextManager.pruneMessages() 字符数裁剪（809-829）
      -> 模型重定向 / 语义路由模型标记（831-850, 911-947）
      -> VCPToolUse=Forbidden 与 TransBase64 占位符消费（854-897）
      -> VCPTavern 预设注入（899-909）
      -> 逐条深拷贝 + 变量解析 + Agent/Toolbox 展开（972-1021）
      -> 多模态预处理器 + 其他插件 messagePreprocessors（1023-1061）
      -> TransBase64+ 清理与还原（1063-1096）
      -> Detector/SuperDetector + Role Divider（1098-1121）
      -> originalBody.messages = processedMessages（1124）
      -> 首次上游请求（finalContextStore 快照 1142-1148，fetchWithRetry 1152-1182）
  -> 流式/非流式 handler：VCP 工具循环（assistant 正文 -> 工具执行 -> VCP_TOOL_PAYLOAD -> 再次 POST）
  -> 客户端输出（SSE / conversationHistoryForClient）
```

## 1. 提交入口、任务对象与状态机

- 标准入口 `POST /v1/chat/completions`（`server.js:1217-1228`）；`/v1/chatvcp/completions` 只额外强制显示 VCP 调用信息（`server.js:1231-1242`，第三个参数 `forceShowVCP`）。`/v1/human/tool`（`server.js:1250`）是人类直接调用工具的入口，不进入聊天编排。
- 任务对象：本服务没有独立的任务对象。`requestId`/`messageId`（客户端提交，`modules/chatCompletionHandler.js:714`）被注册进 `activeRequests` Map（`server.js:142`），携带 `{req, res, abortController, aborted, abortReason}`（`modules/chatCompletionHandler.js:753-761`）。这个注册表是请求级中断与关机排空的唯一任务状态；请求结束后经 `finally` 用 `setImmediate` 删除（1381-1414）。
- 状态机只有两种运行形态：流式（`StreamHandler`，`modules/handlers/streamHandler.js:18`）与非流式（`NonStreamHandler`，`modules/handlers/nonStreamHandler.js:129`），由首次上游响应是否为 `text/event-stream` 决定（`modules/chatCompletionHandler.js:1184-1186` 判定、1290-1294 分发）。没有排队、暂停、恢复状态。
- 协议桥接层先把其他格式转换为 OpenAI 风格的 `{ role, content }` 数组，再在本机 HTTP 转发到标准入口（`routes/protocolBridge.js:795-857`）：
  - Responses API：从 `input` 提取 `message` 项，`developer` 归一化为 `system`（`routes/protocolBridge.js:299-333`，角色映射 47-52）；
  - Anthropic Messages：顶层 `system` 放在数组首位，再提取 `body.messages`（`routes/protocolBridge.js:359-380`）；
  - Gemini GenerateContent：`systemInstruction` 变成 `system`，`contents[].role=model` 变成 `assistant`（`routes/protocolBridge.js:386-413`）。
- 桥接把原生 `tools`、`tool_choice`、`parallel_tool_calls` 作为受保护顶层字段加回转发 body，不放进 `messages` 或 RAG 文本（`routes/protocolBridge.js:158-174`，在 `forwardToChatCompletions` 内调用点 821）。但 VCP 自己的工具循环仍依赖模型正文中的 `<<<[TOOL_REQUEST]>>>` 纯文本标记（`README.md:170`），两套工具协议不是同一条执行链：原生工具字段只会原样透传给上游，不参与 VCP 工具执行。

## 2. 上下文来源与拼装顺序：初始请求

`ChatCompletionHandler.handle()` 对入站 body 原地处理，最终把处理结果写回 `originalBody.messages`（`modules/chatCompletionHandler.js:1124`）。可复现的顺序如下（行号均为该文件）：

1. 读取 `requestId/messageId`（714），移除仅供 VCPChat 使用的 `vcpchatExtensions`（716-728）。
2. 若带 `contextTokenLimit`，先从 body 删除该字段并调用 `contextManager.pruneMessages()`（809-829）。它按**文本字符数**估算长度，忽略图片等非文本 part；保留全部 `system`、以 `[系统提示:]` 开头的 user，以及最后两条消息，然后从前向后删除其他消息直到达到限制（`modules/contextManager.js:10-25` 估算、34-95 裁剪）。这不是摘要压缩，也不保证严格 token 上限。
3. 消费连续顶层 system 中的 `[[VCPToolUse=Forbidden]]`，移除占位符并在本次请求禁用 VCP 工具解析（`modules/chatCompletionHandler.js:187-210` 消费函数、854-857 调用点）。同时扫描 `{{TransBase64}}` / `{{TransBase64+}}`，决定后续多模态处理（859-897）；模型命中纯文本 tag 列表时自动强制翻译（949-970，tag 列表来自 `multiModalConfigStore` 热加载，676-687）。
4. 优先执行 `VCPTavern`。触发器 `{{VCPTavern::Preset...}}` 只从 system 查找（`Plugin/VCPTavern/VCPTavern.js:239-250`），触发器本身及其他消息中的同名残留会被删除（291-310）；预设按 embed → relative → depth 注入，relative/depth 可插入新的消息对象，并可解析 `{{LastChatTime}}`/`{{TimeSinceLastChat}}` 会话时间变量（`Plugin/VCPTavern/VCPTavern.js:419-580` 注入、314-388 时间追踪）。
5. 若请求模型是语义路由模型，使用 Tavern 注入后的消息选出真实后端模型，再应用模型重定向和思维开关（`modules/chatCompletionHandler.js:911-947`；语义路由实现见 `modules/semanticModelRouter.js`）。
6. 逐条深拷贝消息并执行变量解析（972-1021）。只有 `system`，或以 `[系统提示:]` / `[系统邀请指令:]` 开头的 user，才有权限展开 Agent/Toolbox（`modules/messageProcessor.js:153`）；整个请求只展开一个 Agent，同名 Toolbox 只展开一次（166-206、208-248）。随后处理时间、环境、SAR、日记/知识库、动态工具、插件描述等其他占位符（`modules/messageProcessor.js:601-871`，SAR 注入 606-674，动态工具与 VCPAllTools 803-812）。
7. 按配置调用多模态预处理器（`MultiModalProcessor` 优先，否则 `ImageProcessor`），再遍历其余插件 messagePreprocessors（`modules/chatCompletionHandler.js:1023-1061`）。预处理器注册顺序由 `preprocessor_order.json` 中的已知顺序优先，未列出的插件按名称排序追加（`Plugin.js:881-904`，`Array.sort()` 在 899）；当前保存顺序为 `VCPTavern → ImageProcessor → RAGDiaryPlugin → VCPTimeLine → OpenHerPersona → OneRing → ContextFoldingV2`（`preprocessor_order.json`）。因此插件可能修改原消息内容、插入消息，或仅挂载数组元数据。
8. 后置执行 Detector/SuperDetector（`modules/messageProcessor.js:575-599` 的 `applyDetectorsToMessages`）；最后按开关运行 Role Divider（`modules/chatCompletionHandler.js:1109-1121`，skipCount=1 跳过首条）。Role Divider 识别 `<<<[ROLE_DIVIDE_SYSTEM/ASSISTANT/USER]>>>` 标签拆出新消息，保护 `TOOL_REQUEST` 与 DailyNote 标记块不被拆开（`modules/roleDivider.js:11-27` 标签、101-121 保护块、383-399 process）。
9. 以处理后的 body 建立首次上游请求，并写入内存 `finalContextStore`（`modules/chatCompletionHandler.js:1142-1148`）。这个快照是**首次 fetch 前**的请求，不包含后续 VCP 工具递归回合；最多保留 5 组（`modules/finalContextStore.js:21`、288-301），并附带 token 统计摘要（含 tiktoken cl100k_base 精确计数与多模态估算，`modules/finalContextStore.js:10-19`、40-133）。

## 3. 预算、截断与压缩：RAG、时间线与折叠在消息中的实际形态

这些能力不是独立的"会话消息表"，而是预处理器对本次数组的改写：

- `RAGDiaryPlugin` 只处理 system 或虚拟 system user（以 `[系统xxx]` 开头）中的日记本/知识库占位符（`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135` 入口、1168-1215 载体识别、1217-1220 无占位符早退）；查询向量来自最近真实 user 与最近 assistant 的加权内容（1222-1240），命中召回后替换占位符，必要时收集多模态附件（1367-1403 替换循环、1405-1419 附件）。
- `VCPTimeLine` 找到首个可信 system/系统前缀 user 中的时间线占位符，只接受一次声明，把时间线文本替换到该占位符，其余同名占位符清空（`Plugin/VCPTimeLine/VCPTimeLine.js:372-416`）。
- `ContextFoldingV2` 需要 system 中的激活占位符（`{{ContextFoldingV2}}` 或 `[[ContextFoldingV2]]`，可带阈值尾缀）；它基于 assistant 历史块的深度、向量相似度和 FoldingStore，把低相关且已有摘要的 assistant 内容原地替换为摘要，未完成摘要则异步触发，开关本身从最终 system 文本删除（`Plugin/ContextFoldingV2/ContextFoldingV2.js:164-191` 激活检测、200-211 开关移除、213-226 候选与阈值、228-290 折叠循环）。
- OneRing 会把触发器改成系统通知、按配置追加上下文/时间标记，并在数组上挂载 `__oneRingMeta`；后续产生新数组的阶段显式复制这份元数据（`Plugin/OneRing/OneRing.js:929-950` processMessages；`modules/chatCompletionHandler.js:264-279` copyArrayMetadata、1102-1106 检测器后复制、1126-1137 冻结响应元数据）。

## 4. 流式与非流式执行

### 4.1 VCP 工具循环：模型上下文与前端显示分叉

首次上游返回后，流式和非流式 handler 都维护一份独立循环上下文（`streamHandler.js:68` `currentMessagesForLoop`；`nonStreamHandler.js:306` `currentMessagesForNonStreamLoop`），而不是修改客户端的原始会话。每一轮的核心结构是：

```text
处理后的历史
  -> assistant: 模型本轮正文（含 TOOL_REQUEST 标记）
  -> 执行 Archery/普通工具
  -> user: <!-- VCP_TOOL_PAYLOAD --> + 工具结果
  -> 再次 POST /v1/chat/completions
```

- `ToolCallParser.parse()` 先剥离 `<think>/<thinking>` 推理块（`modules/vcpLoop/toolCallParser.js:36-67`），再解析纯文本工具标记（74-94）；普通调用与 `archery` 调用分离（306-311），字段解析见 125-165（`tool_name`/`archery`/`no_reply`/`ink=mark_history`/`river`/`vref`）。
- assistant 工具调用正文追加到循环上下文（`modules/handlers/streamHandler.js:429-439`；`nonStreamHandler.js:422-432`，均带 `enableRoleDividerInLoop` 分支）。普通工具的 `result.content` 汇总后序列化为字符串 user payload，含图片时改用多模态数组并可再次经过图片翻译（`modules/handlers/streamHandler.js:580-582`、677-688；`nonStreamHandler.js:434-444`、507-518）。
- Archery 成功结果默认不回送模型；只有 Archery 出错且没有普通调用时，错误内容才形成 `VCP_TOOL_PAYLOAD` 触发递归（`modules/handlers/streamHandler.js:468-490` 执行、493-561 递归；`nonStreamHandler.js:327-349`、351-417）。
- `RAGMemoRefresh` 开启时，追加工具 payload 前会刷新历史中的 `VCP_RAG_BLOCK`，查询使用最近真实 user（跳过 `VCP_TOOL_PAYLOAD`/`[系统提示:]`/`[系统邀请指令:]`），而不是工具 payload（`modules/chatCompletionHandler.js:531-625` `_refreshRagBlocksIfNeeded`，581-598 找真实 user；两个 handler 的 RAG 刷新段：`streamHandler.js:665-675`、`nonStreamHandler.js:496-505`）。
- 循环最多由 `MaxVCPLoopStream/NonStream` 控制（`server.js:1202-1203`），默认回退 5（`streamHandler.js:70`；`nonStreamHandler.js:303`）；达到上限时流式返回 `finish_reason=length`（`streamHandler.js:741-752`），非流式把最终 choice 标为 `length`（`nonStreamHandler.js:578`）。

### 4.2 推理字段、VCP 信息与日志不是同一份消息

- 循环和 OneRing 只读取模型 `message.content`；stream handler 将 reasoning 字段另存于日志 message，不混入 `collectedContentThisTurn`，避免推理链进入工具解析与记忆（`modules/handlers/streamHandler.js:158-170`；非流式同样只取正文，`nonStreamHandler.js:272-276`）。
- 当模型匹配 reasoning 转正文配置时，发给客户端的 SSE/JSON 才会把 reasoning 包成 `<think>` 或 `<thinking>`（`modules/reasoningContentAdapter.js:41-49` 模型匹配、128-138 `buildClientVisibleContent`；`streamHandler.js:172-218` 客户端转换；`nonStreamHandler.js:277-286`、565-577 移除推理字段）；内部循环始终使用原始正文。
- `vcpInfoHandler.streamVcpInfo()` 产生的工具结果汇总、成功/失败摘要只写入客户端输出（流式 SSE 或非流式 `conversationHistoryForClient`）；模型下一轮读取的是独立的 `VCP_TOOL_PAYLOAD`（`vcpInfoHandler.js:96-104` 文本块格式化、117-153 streamVcpInfo；`streamHandler.js:594-663`；`nonStreamHandler.js:447-494`）。`SHOW_VCP_OUTPUT` 关闭时，`mark_history` 标记仍可强制显示单个调用（`streamHandler.js:600-617`；`nonStreamHandler.js:453-471`）。
- `CHAT_LOG_ENABLED` 打开时，`DebugLog/chat/YYYY-MM-DD/` 才异步写入初始请求、每轮 request/toolCalls/response（`server.js:371`、478-499；`streamHandler.js:413`、551-556、722-728、738；`nonStreamHandler.js:297`、402-407、545-551、585）；默认关闭，不构成会话持久化。

## 5. 停止、重试与并发

本次调查核实到明确的请求级停止与重试机制（旧版笔记未记录，结论已修正）：

- **显式停止**：`POST /v1/interrupt`（`server.js:1058-1167`）按 `requestId`/`messageId` 在 `activeRequests` 中查找，置 `aborted` 标志并调用 `AbortController.abort()`；流式请求回发"请求已被用户中止"的 SSE chunk + `[DONE]`，非流式回发同文案 JSON；随后延迟 1 秒删除注册表条目。这是一个独立端点，与聊天主链通过共享 Map 关联。
- **客户端断联级联中止**：`handle()` 为有 id 的请求注册 `req 'aborted'/'close'` 与 `res 'close'` 监听，传输层断联（无法区分用户停止/刷新/断网）会触发同样的 abort 链路（`modules/chatCompletionHandler.js:763-807`）。`fetchWithRetry` 对 AbortError 不重试（493-510），handler 循环每轮检查 `abortController.signal.aborted` 提前退出（`streamHandler.js:423-427`、309-313 非流式）。
- **上游调用重试**：`fetchWithRetry`（`modules/chatCompletionHandler.js:409-529`）对 500/503/429 及带 token 错误文本的 401 重试（455-473），指数延迟；单次尝试有连接超时安全网（437-439，默认 15 分钟，`server.js:1206`）；语义路由的候选模型按顺序回退（415-418、447、`applyModelFallbackForAttempt` 376-404）。
- **响应去重（非会话级重试语义）**：`ResponseReplayCache` 按 `clientIp::messageId` 缓存完整响应并在重复请求时原样回放，不再执行工具链（`modules/chatCompletionHandler.js:56-124` 类、730-734 键计算、742-751 录制器；默认关闭，由 `config.env` 的 `ResponseReplayCacheEnabled`/`ResponseReplayCacheMaxEntries` 控制，`config.env.example:68-70`，构造函数读取 630-634）。
- **协议桥重复抑制**：Responses 端点对 15 秒窗口（`routes/protocolBridge.js:11`）内的同 `requestId`/`messageId` 重试直接返回抑制提示文本，不再转发主链（`routes/protocolBridge.js:189-208` 判定、1008-1017 调用点）；并为无 VCP id 的 Responses 请求生成稳定 `messageId`（180-187、997-1006）。
- **非流式语义重试**：上游返回"只有推理无正文"的非流式响应时，按 `ApiRetries` 次数重试（`nonStreamHandler.js:64-121` `readNonStreamResponseWithSemanticRetry`）。
- **续写/重新生成**：不适用。编辑后发送、续写、重新生成都是客户端语义（客户端自行拼消息再提交），服务端没有任何按消息定位起始上下文的入口。
- **队列与并发**：未找到队列。同一 `messageId` 重复提交只会命中响应去重或作为新请求处理；不同会话的并发由 Node 事件循环自然承载，服务端不做串行化。没有后台任务管理。

## 6. 完成、异常、半截流与最终回写

- **流式收口**：正常结束时回发 `finish_reason=stop` chunk + `[DONE]`（`streamHandler.js:442-461`）；SSE 转发带 5 秒幽灵心跳（242-250）与 90 秒 chunk 空闲超时保护（252-282，超时回发"[上游响应超时，流已中断]"并强制结束）；abort 时直接销毁上游 body 并结束（285-291）。
- **非流式收口**：把 `conversationHistoryForClient`（AI 正文 + VCP 信息块拼接）写回初始 JSON 的 `choices[0].message.content`（`nonStreamHandler.js:565-583`），`finish_reason` 按循环是否触顶置 `length/stop`。**注意**：这个回写只发生在内存响应体里，不会持久化，也不回写模型上下文。
- **上游错误代理**：流式请求上游非 200 时，服务端回 200 并把错误文本作为 SSE chunk 流给客户端（`chatCompletionHandler.js:1187-1248`），避免前端监听器终止；连接失败/重试耗尽同样以 SSE chunk 报错（1307-1333）。
- **快照与日志**：首次请求前快照入 `finalContextStore`（1142-1148）；ChatLog 可选落盘（见 4.2）。服务端不写回任何会话/消息存储（见会话与消息管理笔记）。

## 7. 消息构建边界与已确认边界

- 已确认：VCPToolBox 在单次 HTTP 请求内拥有完整的"请求历史 → 最终上游 messages → 工具递归 messages"编排能力；不拥有会话列表、消息编辑/删除/分支或跨请求恢复。`finalContextStore` 是调试快照，ChatLog 是可选审计文件，均不是前端会话存储。外部 VCPChat、OpenWebUI 或其他客户端必须自行保存并在下一次请求中重新提交历史。
- 上游事实源：最终请求体以 `finalUpstreamBody = { ...originalBody, stream: willStreamResponse }` 为准（`chatCompletionHandler.js:1139-1140`），其中 messages 已是处理后的数组；工具递归轮的请求体是 `{ ...originalBody, messages: currentMessagesForLoop, stream: true }`（`streamHandler.js:539`、709）。
- 与 Agent/工具的边界：Agent 人格与工具权限的配置面在 AdminPanel-Vue（Agent & 内容分组），但管理面板不参与单条聊天消息的收发；工具执行、审批、循环内部语义见 `../Agent工具` 类目笔记。

## 8. 未验证事项

- 未运行真实上游模型，各插件组合下的最终消息数组没有运行时快照；`<think>` 包裹、中断、上游错误代理等行为的实际客户端表现未运行验证。
- `messagePreprocessors` 中未列入 `preprocessor_order.json` 的插件只能从源码确认"按名称排序追加"（`Plugin.js:899`），各安装环境的完整顺序未知。
- 工具循环上限（默认 5）触达后的实际客户端表现未运行验证。
- `/v1/interrupt` 与 SSE 竞态、`ResponseReplayCache` 与多客户端同 id 并发回放的实际行为未运行验证（属静态推断：代码路径完整但未实测）。

## 9. 关键源码索引

- `server.js`（1217/1231/1247/1250 聊天相关端点；1058-1167 `/v1/interrupt`；478-499 ChatLog；1202-1206 循环上限与重试参数）
- `routes/protocolBridge.js`（47-52 角色归一化；158-174 受保护工具字段；299-413 三种协议提取；795-884 内部转发）
- `modules/chatCompletionHandler.js`（644-1418 主链；56-124 ResponseReplayCache；409-529 fetchWithRetry；531-625 RAG 块刷新）
- `modules/contextManager.js`（10-25 估算；34-95 pruneMessages）
- `modules/messageProcessor.js`（146-256 变量解析；575-599 检测器；601-871 其他占位符）
- `modules/roleDivider.js`（69-314 单条拆分；383-399 process）
- `modules/vcpLoop/toolCallParser.js`（36-67 推理块剥离；74-94 解析；306-311 分离）
- `modules/handlers/streamHandler.js`、`nonStreamHandler.js`（循环与输出分叉）
- `modules/reasoningContentAdapter.js`、`vcpInfoHandler.js`
- `Plugin/VCPTavern/VCPTavern.js`、`RAGDiaryPlugin`、`VCPTimeLine`、`ContextFoldingV2`、`OneRing`
- `Plugin.js`（881-904 预处理器排序）、`preprocessor_order.json`
- `modules/finalContextStore.js`
