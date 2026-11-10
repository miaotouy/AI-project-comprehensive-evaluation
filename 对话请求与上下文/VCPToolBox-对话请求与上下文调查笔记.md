# VCPToolBox 对话请求与上下文调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：直接阅读源码：server.js 聊天端点与 /v1/interrupt、routes/protocolBridge.js 协议归一化、modules/chatCompletionHandler.js 请求管线、contextManager.js、messageProcessor.js、roleDivider.js、vcpLoop/toolCallParser.js、handlers/streamHandler.js 与 nonStreamHandler.js、reasoningContentAdapter.js、vcpInfoHandler.js，以及 Plugin/VCPTavern、RAGDiaryPlugin、VCPTimeLine、ContextFoldingV2、OneRing 的 processMessages
>
> 调查范围：一次请求内"客户端历史 → 最终上游 messages → 工具递归 messages"的完整编排：入口归一化、上下文裁剪、预处理器、VCP 工具循环、推理字段分叉、停止与重试；客户端会话与 OneRing 插件消息持久化的边界见会话与消息管理笔记
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 在**单次 HTTP 请求内**拥有完整的"请求历史 → 最终上游 messages → 工具递归 messages"编排能力；客户端持有会话导航与分支，OneRing 可另行保存插件消息历史并支持重试更新（数据边界见[会话与消息管理](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)）。本次重新核实的主要结论：

- **入口归一化**：OpenAI Chat、Chatvcp、Responses、Anthropic、Gemini 五种协议都收敛到同一条主链，标准入口是 `POST /v1/chat/completions`（`server.js:1217`）；
- **编排方式**：`ChatCompletionHandler.handle()` 对入站 body 原地改写消息数组，依次完成复制、重排、展开、注入和裁剪，最后把结果写回 `originalBody.messages`（`modules/chatCompletionHandler.js:1124`）；
- **上下文裁剪**：`contextManager.pruneMessages` 按文本字符数估算长度，删除整条消息来控制规模，对严格 token 上限只做近似控制；
- **VCP 工具循环**：走纯文本标记协议，模型正文里的 `<<<[TOOL_REQUEST]>>>` 就是调用声明，工具结果包成 `<!-- VCP_TOOL_PAYLOAD -->` user 消息后再 POST 一次；
- **模型上下文与前端显示分叉**：工具循环维护独立的 `currentMessagesForLoop`，推理字段另存于日志消息，客户端拿到的 SSE/JSON 与模型下一轮读取的内容分别生成；
- **预设占位符注入边界**：VCPTavern 只对预设声明允许、且标为伪系统消息的文本展开运行时占位符；其余占位符保留原文，嵌套消息对象递归处理（`Plugin/VCPTavern/VCPTavern.js:155-640`）；
- **编译规则分化**：SAR 支持精确/包含及其排除模式，Detector/SuperDetector 支持 `/pattern/flags` 正则替换；OneRing 默认把 assistant 的时间与来源标记投影成紧随其后的 user 伪系统块（`modules/sarPromptManager.js:112-128`、`modules/messageProcessor.js:608-642`、`Plugin/OneRing/OneRing.js:518-1467`）；
- **请求级停止与重试**：`/v1/interrupt` 端点负责显式停止，客户端断联会级联中止；上游调用带状态码重试、连接超时和语义路由候选模型回退；响应层按 `clientIp::messageId` 去重回放。

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

- 聊天请求从 `POST /v1/chat/completions` 进入（`server.js:1217-1250`）。另有两个并列端点：`/v1/chatvcp/completions` 在同样的编排之上强制显示 VCP 调用信息（第三个参数 `forceShowVCP`），`/v1/human/tool` 供人类直接调用工具，不进入聊天编排。
- 任务状态：本服务没有独立的任务对象，请求级状态全部落在一张 `activeRequests` Map 里，键是客户端提交的 `requestId`/`messageId`，值是请求、响应与中止控制器等运行时句柄；中断与关机排空都查这张表，请求结束后异步删除条目（`modules/chatCompletionHandler.js:714-1414`、`server.js:142`）。
- 运行形态：只有流式与非流式两种，由首次上游响应是否为 `text/event-stream` 决定，是则走 `StreamHandler`，否则走 `NonStreamHandler`，判断与分发集中在 `modules/chatCompletionHandler.js:1184-1294`。两种形态都没有排队、暂停或恢复状态。
- 协议桥接层先把其他协议的请求体转成 OpenAI 风格的 `{ role, content }` 数组，再在本机用 HTTP 转发到标准入口，三种协议的归一化动作如下（`routes/protocolBridge.js:47-857`）：
  - Responses API 从 `input` 中提取 `message` 项，把 `developer` 角色归一化为 `system`；
  - Anthropic Messages 的顶层 `system` 放在数组首位，随后提取 `body.messages`；
  - Gemini GenerateContent 把 `systemInstruction` 变成 `system`，把 `contents[].role=model` 变成 `assistant`。
- 桥接把原生工具清单与选择策略作为受保护字段加回转发 body；并行调用开关为布尔值时也原样保留。这些字段留在顶层，不进入消息数组或 RAG 文本（`routes/protocolBridge.js:162-175`）：
  - `tools`：工具定义；
  - `tool_choice`：工具选择策略；
  - `parallel_tool_calls`：并行调用开关。

  VCP 自己的工具循环仍依赖模型正文里的 `<<<[TOOL_REQUEST]>>>` 纯文本标记（`README.md:170`）：原生工具字段只原样透传给上游，两套工具协议各走一条执行链。

## 2. 上下文来源与拼装顺序：初始请求

`ChatCompletionHandler.handle()` 对入站 body 原地处理，最终把处理结果写回 `originalBody.messages`（`modules/chatCompletionHandler.js:1124`）。可复现的顺序如下（行号均为该文件）：

1. 读取 `requestId`/`messageId`，并移除仅供 VCPChat 使用的 `vcpchatExtensions`（`modules/chatCompletionHandler.js:714-728`）。
2. 请求带 `contextTokenLimit` 时，先从 body 删除该字段，再调用 `pruneMessages()` 裁剪（`modules/chatCompletionHandler.js:809-829`）。裁剪按**文本字符数**估算长度，图片等非文本 part 不参与计数；全部系统消息、以 `[系统提示:]` 开头的 user 消息和最后两条消息无条件保留，其余消息从前向后逐条删除，直到长度降到限制以内（`modules/contextManager.js:10-95`）。这里直接删除整条消息，对 token 上限只做近似控制。
3. 消费连续顶层 system 里的 `[[VCPToolUse=Forbidden]]`：移除占位符，并在本次请求禁用 VCP 工具解析。同一步还扫描 `{{TransBase64}}` / `{{TransBase64+}}` 决定后续多模态处理，请求模型命中纯文本 tag 列表时自动强制翻译，tag 列表由 `multiModalConfigStore` 热加载（`modules/chatCompletionHandler.js:187-970`）。
4. 优先执行 `VCPTavern`：它只从 system 消息中查找 `{{VCPTavern::Preset...}}` 触发器，并删除触发器本身及其他消息里的同名残留；随后按 embed → relative → depth 注入预设，relative/depth 可插入新的消息对象，注入过程中会解析 `{{LastChatTime}}`/`{{TimeSinceLastChat}}` 会话时间变量（`Plugin/VCPTavern/VCPTavern.js:239-580`）。
5. 请求模型是语义路由模型时，用 Tavern 注入后的消息选出真实后端模型，再应用模型重定向和思维开关（`modules/chatCompletionHandler.js:911-947`；路由实现见 `modules/semanticModelRouter.js`）。
6. 逐条深拷贝消息并执行变量解析（`modules/chatCompletionHandler.js:972-1021`）。展开 Agent/Toolbox 的权限只给 system 消息，以及以 `[系统提示:]` / `[系统邀请指令:]` 开头的 user 消息；整个请求只展开一个 Agent，同名 Toolbox 只展开一次。同一步还会处理时间、环境、SAR、日记/知识库、动态工具和插件描述等占位符（`modules/messageProcessor.js:153-871`）。
7. 除已优先执行的 VCPTavern 外，按保存的预处理顺序遍历真实插件与静态注入虚拟阶段。多模态处理器优先选择 MultiModalProcessor，否则选择 ImageProcessor，且仅在媒体条件满足时执行。当前顺序为：

   ```text
   VCPTavern → CapturePreprocessor → $StaticPlaceholderInjection
     → ImageProcessor（或选定的 MultiModalProcessor）→ MemoryThinkingTray
     → RAGDiaryPlugin → VCPTimeLine → OpenHerPersona → OneRing → ContextFoldingV2
   ```

   捕获阶段排在动态文本注入之前，托盘排在检索与时间线之前；每个插件都可以改写内容、插入消息或挂载元数据。执行位置见 `modules/chatCompletionHandler.js:1083-1124`，顺序由 `preprocessor_order.json:1-12` 保存。
8. 后置处理先跑检测器：Detector/SuperDetector 在此阶段执行（`modules/messageProcessor.js:575-599`）。随后按开关运行 Role Divider（`modules/chatCompletionHandler.js:1109-1121`，跳过首条消息），它识别 `<<<[ROLE_DIVIDE_SYSTEM/ASSISTANT/USER]>>>` 标签拆出新消息，同时保证工具请求与日记标记块不被拆开（`modules/roleDivider.js:11-399`）。
9. 以处理后的 body 建立首次上游请求，并写入内存 `finalContextStore`（`modules/chatCompletionHandler.js:1142-1148`）。这个快照记录**首次 fetch 前**的请求，不包含后续 VCP 工具递归回合；最多保留 5 组，并附带 token 统计摘要，含 tiktoken cl100k_base 精确计数与多模态估算（`modules/finalContextStore.js:10-301`）。

## 3. 预算、截断与压缩：RAG、时间线与折叠在消息中的实际形态

以下路径直接改写本次请求数组；其中 OneRing 另有 SQLite 消息和回合持久化，详见[会话与消息管理](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)：

- `RAGDiaryPlugin` 只处理 system 消息或虚拟 system user（以 `[系统xxx]` 开头）中的日记本/知识库占位符，载体里没有占位符时直接早退。查询向量取自最近真实 user 与最近 assistant 的加权内容，命中召回后替换占位符，需要时收集多模态附件（`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135-1419`）。
- `VCPTimeLine` 找到首个可信 system/系统前缀 user 中的时间线占位符，只接受一次声明，把时间线文本替换到该占位符，其余同名占位符清空（`Plugin/VCPTimeLine/VCPTimeLine.js:372-416`）。
- `ContextFoldingV2` 在 system 文本出现激活占位符 `{{ContextFoldingV2}}` 或 `[[ContextFoldingV2]]`（可带阈值尾缀）时启动。它按 assistant 历史块的深度、向量相似度和 FoldingStore 判断相关性，把低相关且已有摘要的 assistant 内容原地替换成摘要，摘要还没生成完就异步触发，最后从最终 system 文本里删掉开关本身（`Plugin/ContextFoldingV2/ContextFoldingV2.js:164-290`）。
- OneRing 把触发器改写成系统通知，按配置追加上下文与时间标记，并在消息数组上挂载 `__oneRingMeta` 元数据；之后凡是要新建数组的阶段都会显式复制这份元数据，响应阶段再将其冻结（`Plugin/OneRing/OneRing.js:929-950`、`modules/chatCompletionHandler.js:264-279,1102-1137`）。
- OneRing 的热配置现默认采用 `system_user_block`：assistant 正文保持原样，来源与时间另放进 user 伪系统块。`inline` 仍保留给要求严格角色交替的旧模型。前者可能形成连续 user 消息，因此兼容性取舍已经从“标记放在正文哪里”变成“时间理解与角色数组约束如何权衡”（`Plugin/OneRing/OneRingConfig.json:1-8`、`Plugin/OneRing/OneRing.js:518-568,1467`）。

## 4. 流式与非流式执行

### 4.1 VCP 工具循环：模型上下文与前端显示分叉

首次上游返回后，流式和非流式 handler 都维护一份独立循环上下文（`streamHandler.js:68` `currentMessagesForLoop`；`nonStreamHandler.js:306` `currentMessagesForNonStreamLoop`），而不是修改客户端的原始会话。每一轮的核心结构是：

```text
处理后的历史
  -> assistant: 模型本轮正文（含 TOOL_REQUEST 标记）
  -> 执行 Archery/普通工具
  -> user: <!-- VCP_TOOL_PAYLOAD --> + 工具结果（一轮多结果时包成带时间戳的批量块）
  -> 再次 POST /v1/chat/completions
```

- `ToolCallParser.parse()` 先剥离 `<think>` / `<thinking>` 推理块，再解析正文里的纯文本工具标记，并把普通调用与 `archery` 调用分开；字段解析覆盖工具名、archery 标志、回复抑制、历史标记与引用参数（`modules/vcpLoop/toolCallParser.js:36-311`）。
- 模型本轮的 assistant 工具调用正文会追加进循环上下文，两个 handler 都按 `enableRoleDividerInLoop` 决定是否插入角色分隔。普通工具返回的 `result.content` 汇总后序列化成字符串 user payload，结果含图片时改用多模态数组并可能再次经过图片翻译（`modules/handlers/streamHandler.js:429-688`、`modules/handlers/nonStreamHandler.js:422-518`）。
- `archery` 调用成功时结果默认不回送模型；只有它出错且本轮没有普通工具调用时，错误内容才包成 `VCP_TOOL_PAYLOAD` 触发递归（`modules/handlers/streamHandler.js:468-561`、`modules/handlers/nonStreamHandler.js:327-417`）。
- `RAGMemoRefresh` 开启时，追加工具 payload 之前会刷新历史中的 `VCP_RAG_BLOCK`，检索查询取最近的真实 user 消息，跳过工具 payload 和以 `[系统提示:]` / `[系统邀请指令:]` 开头的系统载体。两个 handler 都在拼接 payload 前调用这段刷新逻辑，实现在 `modules/chatCompletionHandler.js:531-625`。
- 循环轮数上限由 `MaxVCPLoopStream` 等两个配置项分别控制流式与非流式，未配置时回退到 5（`server.js:1202-1203`）。达到上限后，两种形态都以 `finish_reason=length` 收口：流式响应以该值结束，非流式把最终 choice 的结束原因标成 length（`modules/handlers/streamHandler.js:70,741-752`、`modules/handlers/nonStreamHandler.js:303` 及其收尾段）。

**批量包裹与上游投影。** 一轮里有多个工具结果时，它们不各自独立成段，而是由 `modules/toolResultBatch.js` 合并成一个带时间戳的批量块：开始标记形如 `<<<[VCP_TOOL_BATCH_START:<时间>]>>>`，结束标记用同一时间戳闭合，外层可再套角色分隔标记，让整批以 user 角色单独成段。时间戳单调递增，既让相邻两批可区分，也避免分隔符与正文碰撞。

发给上游前还有一次投影：对 assistant 或 user 消息里被完整包裹的批量块，包装标记会改写为中文提示行「工具返回批次开始／结束｜时间：…」，让模型读到的是“这一批结果产生于何时”，而不是内部标记；以 `<!-- VCP_TOOL_PAYLOAD -->` 开头的服务器自生成 payload 不参与投影。批量块内部即使出现形似协议标记的文本也不递归解析，代码注释明确这是结构识别而非来源认证。角色重排器同样先按批量边界扫描，把整批当作不可再拆的引用块处理，避免角色切分把一批结果拆散。

依据：[toolResultBatch.js:33-130](../../VCPToolBox/modules/toolResultBatch.js)、[roleDivider.js:82](../../VCPToolBox/modules/roleDivider.js)、[streamHandler.js:5](../../VCPToolBox/modules/handlers/streamHandler.js)、[nonStreamHandler.js:4](../../VCPToolBox/modules/handlers/nonStreamHandler.js)。

### 4.2 推理字段、VCP 信息与日志不是同一份消息

- 工具循环和 OneRing 只读取模型响应的 `message.content`；流式 handler 把 reasoning 字段单独存进日志消息，不写入 `collectedContentThisTurn`，推理链因此不会进入工具解析和记忆，非流式同样只取正文（`modules/handlers/streamHandler.js:158-170`、`modules/handlers/nonStreamHandler.js:272-276`）。
- 只有模型命中 reasoning 转正文配置时，发给客户端的 SSE 或 JSON 才会把推理内容包成 `<think>` / `<thinking>`。转换规则由同一个构造函数统一产出，模型匹配在 `modules/reasoningContentAdapter.js:41-138`；流式改写与非流式移除推理字段分别在 `modules/handlers/streamHandler.js:172-218`、`modules/handlers/nonStreamHandler.js:277-577`。内部循环始终使用原始正文。
- VCP 信息处理器生成的工具结果汇总与成功/失败摘要只写进客户端输出：流式走 SSE，非流式走响应体里的会话历史；模型下一轮读取的是独立的工具结果 payload。`SHOW_VCP_OUTPUT` 关闭时，带 `mark_history` 标记的单次调用仍会强制显示（`vcpInfoHandler.js:96-153`、`modules/handlers/streamHandler.js:594-663`、`modules/handlers/nonStreamHandler.js:447-494`）。
- `CHAT_LOG_ENABLED` 打开时，初始请求以及每一轮的 request、toolCalls、response 会异步写入 `DebugLog/chat/YYYY-MM-DD/`；默认关闭，开启后写入的内容只是审计文件（`server.js:371-499`、`modules/handlers/streamHandler.js:413-738`、`modules/handlers/nonStreamHandler.js:297-585`）。

## 5. 停止、重试与并发

明确的请求级停止与重试机制：

- **显式停止**：客户端调用 `POST /v1/interrupt` 时，服务端按请求 id 在 `activeRequests` 中查到目标请求，置中止标志并调用中止控制器。流式请求随后回发一条"请求已被用户中止"的 SSE chunk 加 `[DONE]`，非流式回发同文案的 JSON，注册表条目延迟 1 秒删除（`server.js:1058-1167`）。该端点通过这张共享 Map 与聊天主链关联。
- **客户端断联级联中止**：`handle()` 为带 id 的请求注册请求与响应的关闭事件监听；传输层断联分不清用户停止、刷新还是断网，三种情况都会触发与显式停止相同的 abort 链路。`fetchWithRetry` 遇到 AbortError 直接放弃重试，两个 handler 的循环在每轮开始检查 `abortController.signal.aborted` 后退出（`modules/chatCompletionHandler.js:493-807`、`modules/handlers/streamHandler.js:309-427`）。
- **上游调用重试**：`fetchWithRetry` 对 500、503、429 以及带 token 错误文本的 401 重试，间隔按指数退避；单次尝试另有连接超时兜底，默认 15 分钟；语义路由的候选模型按顺序回退，由 `applyModelFallbackForAttempt` 执行（`modules/chatCompletionHandler.js:376-529`、`server.js:1206`）。
- **响应去重**：`ResponseReplayCache` 以 `clientIp::messageId` 为键缓存完整响应，重复请求命中后原样回放，不再执行工具链。该功能默认关闭，开关与容量由配置文件中的两个配置项控制（`modules/chatCompletionHandler.js:56-751`、`config.env.example:68-70`）。
- **协议桥重复抑制**：Responses 端点对 15 秒窗口内 `requestId` / `messageId` 相同的重试直接返回抑制提示文本，不再转发主链；它还会为没有 VCP id 的 Responses 请求生成稳定的 `messageId`（`routes/protocolBridge.js:11-1017`）。
- **非流式语义重试**：上游返回只含推理、没有正文的非流式响应时，`readNonStreamResponseWithSemanticRetry` 按 `ApiRetries` 设定的次数重试（`modules/handlers/nonStreamHandler.js:64-121`）。
- **续写/重新生成**：服务端没有按消息定位起始上下文的入口；编辑后发送、续写、重新生成都由客户端自行拼好消息再提交。
- **队列与并发**：本次未找到队列。同一 `messageId` 重复提交时命中响应去重，或作为新请求处理；不同会话的并发由 Node 事件循环承载，服务端不做串行化，也没有后台任务管理。

## 6. 完成、异常、半截流与最终回写

- **流式收口**：正常结束时服务端回发 `finish_reason=stop` 的 chunk 和 `[DONE]`；转发过程中每 5 秒发一次幽灵心跳，chunk 空闲超过 90 秒则回发"[上游响应超时，流已中断]"并强制结束；请求被 abort 时直接销毁上游 body 收尾（`modules/handlers/streamHandler.js:242-461`）。
- **非流式收口**：非流式响应把 `conversationHistoryForClient`（AI 正文与 VCP 信息块拼接）写回初始 JSON 首个 choice 的内容字段，`finish_reason` 按循环是否触顶设为 length 或 stop（`modules/handlers/nonStreamHandler.js:565-583`）。这次回写只改内存里的响应体，落盘和模型上下文都不受影响。
- **上游错误代理**：流式请求遇到上游非 200 时，服务端仍以 200 回包，把错误文本当作 SSE chunk 流给客户端，让前端监听器保持存活；连接失败或重试耗尽也走同样的 SSE chunk 报错（`modules/chatCompletionHandler.js:1187-1333`）。
- **快照与日志**：首次请求前快照入 `finalContextStore`（1142-1148）；ChatLog 可选落盘（见 4.2）。OneRing 的消息持久化由下述交互结算路径另行处理。
- **交互结算的提交条件**：OneRing 的最终 AI 回复和 VCPTavern 访问记录要等上游整轮有效、HTTP 响应正常 finish 之后才异步提交；上游错误、客户端中断或半截流会把当前 pending 回合结算为 aborted。预处理阶段记录请求携带的历史同样会写库，提交条件只约束上述两类记录，整轮不存在事务回滚（`modules/handlers/interactionCompletion.js:3-60`、`Plugin/OneRing/OneRing.js:1047-3088`）。插件的持久化消息边界见[会话与消息管理](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)。

## 7. 消息构建边界与已确认边界

- 已确认：VCPToolBox 在单次 HTTP 请求内拥有完整的"请求历史 → 最终上游 messages → 工具递归 messages"编排能力；客户端会话导航与分支外置，OneRing 则持久化插件消息与回合状态。`finalContextStore` 保存调试快照，ChatLog 是可选的审计文件。外部 VCPChat、OpenWebUI 或其他客户端需要自行保存历史，并在下一次请求中重新提交。
- 上游事实源：首次请求体 `finalUpstreamBody` 由原始请求体展开并覆盖流式标志得到，其中的消息数组已是处理后的结果；工具递归轮把消息数组换成 `currentMessagesForLoop` 并固定走流式再发送（`modules/chatCompletionHandler.js:1139-1140`、`modules/handlers/streamHandler.js:539-709`）。
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
