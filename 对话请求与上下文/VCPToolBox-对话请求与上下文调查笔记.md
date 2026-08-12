# VCPToolBox 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：从 [`../Chat/VCPToolBox-Chat调查笔记.md`](../Chat/VCPToolBox-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码；`c4c4d00`→`1ae9b63c` 提交范围内 `chatCompletionHandler.js`、`contextManager.js`、`routes/protocolBridge.js`、`modules/messageProcessor.js` 均无改动，仅更新代码快照
>
> 调查范围：一次请求内"客户端历史 → 最终上游 messages → 工具递归 messages"的完整编排：入口归一化、上下文裁剪、预处理器、VCP 工具循环、推理字段分叉；会话事实源不归 VCPToolBox 所有（见会话与消息管理笔记）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 在**单次 HTTP 请求内**拥有完整的"请求历史 → 最终上游 messages → 工具递归 messages"编排能力；它不拥有会话列表、消息编辑/删除/分支或跨请求恢复（数据边界见会话与消息管理笔记）。

- **入口归一化**：OpenAI Chat / Chatvcp / Responses / Anthropic / Gemini 五种协议收敛到同一条主链（`/v1/chat/completions`）；
- **编排是"原地改写消息数组"**：`ChatCompletionHandler.handle()` 对入站 body 原地处理，复制、重排、展开、注入和裁剪，最终把处理后的消息写回 `originalBody.messages`；
- **上下文裁剪是字符数估算**（`contextManager.pruneMessages`），不是摘要压缩，也不保证严格 token 上限；
- **VCP 工具循环走纯文本标记协议**：`<<<[TOOL_REQUEST]>>>`，模型正文即调用声明，工具结果以 `<!-- VCP_TOOL_PAYLOAD -->` user 消息回送再次 POST；
- **模型上下文与前端显示分叉**：工具循环维护独立的 `currentMessagesForLoop`，推理字段另存于日志消息，客户端看到的 SSE/JSON 与模型下一轮读取的内容不是同一份。

## 系统边界与生成任务主链

```text
外部前端（VCPChat / OpenWebUI / 任意客户端）提交 messages
  -> POST /v1/chat/completions（或经 protocolBridge 归一化后本机转发）
  -> ChatCompletionHandler.handle()
      -> contextManager.pruneMessages()（字符数裁剪）
      -> VCPTavern 预设注入、语义路由模型解析
      -> 逐条深拷贝 + 变量解析 + Agent/Toolbox 展开
      -> 多模态预处理器 + 插件 messagePreprocessors
      -> Detector/SuperDetector + Role Divider
      -> 首次上游请求（快照入 finalContextStore）
  -> 流式/非流式 handler：VCP 工具循环（assistant 正文 -> 工具执行 -> VCP_TOOL_PAYLOAD -> 再次 POST）
  -> 客户端输出（SSE / conversationHistoryForClient）
```

## 1. 提交入口、任务对象与状态机

标准入口是 `POST /v1/chat/completions`；`/v1/chatvcp/completions` 只额外强制显示 VCP 调用信息（`server.js:1216-1242`）。协议桥接层先把其他格式转换为 OpenAI 风格的 `{ role, content }` 数组，再在本机 HTTP 转发到标准入口（`routes/protocolBridge.js:789-857`）：

- Responses API：从 `input` 提取 `message` 项；`developer` 归一化为 `system`，文本部分拼接为字符串（`routes/protocolBridge.js:299-332`）。
- Anthropic Messages：把顶层 `system` 放在数组首位，再提取 `body.messages`（`routes/protocolBridge.js:359-379`）。
- Gemini GenerateContent：`systemInstruction` 变成 `system`，`contents[].role=model` 变成 `assistant`（`routes/protocolBridge.js:386-412`）。

桥接会把原生 `tools`、`tool_choice` 和 `parallel_tool_calls` 作为受保护的顶层字段加回转发 body，不放进 `messages` 或 RAG 文本（`routes/protocolBridge.js:54-56`, `158-173`, `820-821`）。但 VCP 自己的工具循环仍依赖模型正文中的 `<<<[TOOL_REQUEST]>>>` 纯文本标记，不能把这两套工具协议视为同一条执行链。

## 2. 上下文来源与拼装顺序：初始请求

`ChatCompletionHandler.handle()` 对入站 body 原地处理，随后把最终消息写回 `originalBody.messages`（`modules/chatCompletionHandler.js:712-729`, `809-829`, `1123-1148`）。可复现的顺序如下：

1. 读取 `requestId/messageId`，移除仅供 VCPChat 使用的 `vcpchatExtensions`。
2. 若带 `contextTokenLimit`，先从 body 删除该字段并调用 `contextManager.pruneMessages()`。它按**文本字符数**估算长度，不计算图片等非文本 part；保留全部 `system`、以 `[系统提示:]` 开头的 user，以及最后两条消息，然后从前向后删除其他消息直到达到限制（`modules/contextManager.js:10-25`, `34-95`）。这不是摘要压缩，也不保证严格 token 上限。
3. 消费连续顶层 system 中的 `[[VCPToolUse=Forbidden]]`，移除占位符并在本次请求禁用 VCP 工具解析（`modules/chatCompletionHandler.js:182-209`, `854-857`）。同时扫描 `{{TransBase64}}` / `{{TransBase64+}}`，决定后续多模态处理；模型命中纯文本 tag 时可自动强制翻译（`modules/chatCompletionHandler.js:859-970`）。
4. 优先执行 `VCPTavern`。触发器 `{{VCPTavern::Preset...}}` 只从 system 查找，触发器本身及其他消息中的同名残留会被删除；预设按 embed → relative → depth 注入，relative/depth 可插入新的消息对象，并可解析会话时间变量（`Plugin/VCPTavern/VCPTavern.js:235-310`, `419-579`）。
5. 若请求模型是语义路由模型，使用 Tavern 注入后的消息选出真实后端模型，再应用模型重定向和思维开关（`modules/chatCompletionHandler.js:911-947`）。
6. 逐条深拷贝消息并执行变量解析。只有 `system`，或以 `[系统提示:]` / `[系统邀请指令:]` 开头的 user，才有权限展开 Agent/Toolbox；整个请求只展开一个 Agent，同名 Toolbox 只展开一次。随后处理时间、环境、SAR、日记/知识库、动态工具、插件描述等其他占位符（`modules/messageProcessor.js:146-255`, `601-823`）。
7. 按配置调用多模态预处理器（`MultiModalProcessor` 优先，否则 `ImageProcessor`），再遍历 `PluginManager.messagePreprocessors` 执行其他插件。预处理器注册顺序由 `preprocessor_order.json` 中的已知顺序优先，未列出的插件按名称排序追加；当前保存顺序以 `VCPTavern → ImageProcessor → RAGDiaryPlugin → VCPTimeLine → OpenHerPersona → OneRing → ContextFoldingV2` 为主（`Plugin.js:802-880`, `preprocessor_order.json`）。因此插件可能修改原消息内容、插入消息，或仅挂载数组元数据。
8. 后置执行 Detector/SuperDetector；最后按开关运行 Role Divider。Role Divider 默认跳过第一个消息，识别 `ROLE_DIVIDE_*` 标签为新的 system/user/assistant 消息，并保护 `TOOL_REQUEST`、DailyNote 标记块不被拆开（`modules/chatCompletionHandler.js:1098-1121`, `modules/roleDivider.js:69-121`, `383-399`）。
9. 以处理后的 body 建立首次上游请求，并写入内存 `finalContextStore`。这个快照是**首次 fetch 前**的请求，不包含后续 VCP 工具递归回合；最多保留 5 组（`modules/chatCompletionHandler.js:1139-1150`, `modules/finalContextStore.js:21-23`, `288-300`）。

## 3. 预算、截断与压缩：RAG、时间线与折叠在消息中的实际形态

这些能力不是独立的"会话消息表"，而是预处理器对本次数组的改写：

- `RAGDiaryPlugin` 只处理 system 或虚拟 system user 中的日记本/知识库占位符；查询向量来自最近真实 user 与最近 assistant 的加权内容，命中的召回结果替换占位符，必要时还会收集附件（`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1134-1219`, `1222-1240`, `1367-1403`）。
- `VCPTimeLine` 找到首个可信 system/系统前缀 user 中的时间线占位符，只接受一次声明，把时间线文本替换到该占位符，其余同名占位符清空（`Plugin/VCPTimeLine/VCPTimeLine.js:372-415`）。
- `ContextFoldingV2` 需要 system 中的激活占位符；它基于 assistant 历史块的深度、向量相似度和 FoldingStore，把低相关且已有摘要的 assistant 内容原地替换为摘要，未完成摘要则异步触发，开关本身从最终 system 文本删除（`Plugin/ContextFoldingV2/ContextFoldingV2.js:158-215`, `228-300`）。
- OneRing 会把触发器改成系统通知、按配置追加上下文/时间标记，并在数组上挂载 `__oneRingMeta`；后续产生新数组的阶段显式复制这份元数据（`Plugin/OneRing/OneRing.js:929-950`, `modules/chatCompletionHandler.js:259-279`）。

## 4. 流式与非流式执行

### 4.1 VCP 工具循环：模型上下文与前端显示分叉

首次上游返回后，流式和非流式 handler 都维护一份 `currentMessagesForLoop`，而不是修改客户端的原始会话。每一轮的核心结构是：

```text
处理后的历史
  -> assistant: 模型本轮正文（含 TOOL_REQUEST 标记）
  -> 执行 Archery/普通工具
  -> user: <!-- VCP_TOOL_PAYLOAD --> + 工具结果
  -> 再次 POST /v1/chat/completions
```

- `ToolCallParser` 先剥离 reasoning block，再解析纯文本工具标记；普通调用与 `archery` 调用分离（`modules/vcpLoop/toolCallParser.js:22-93`, `303-310`）。
- assistant 工具调用正文会追加到循环上下文；普通工具的 `result.content` 汇总后序列化为字符串 user payload，含图片时改用多模态数组并可再次经过图片翻译（`modules/handlers/streamHandler.js:429-441`, `579-688`; `modules/handlers/nonStreamHandler.js:421-434`, `444-518`）。
- Archery 成功结果默认不回送模型；只有 Archery 出错且没有普通调用时，错误内容才形成 `VCP_TOOL_PAYLOAD` 触发递归（`modules/handlers/streamHandler.js:492-560`; `modules/handlers/nonStreamHandler.js:351-416`）。
- `RAGMemoRefresh` 开启时，追加工具 payload 前会刷新历史中的 `VCP_RAG_BLOCK`，查询使用最近真实 user，而不是工具 payload（`modules/chatCompletionHandler.js:531-624`; 两个 handler 的 `RAG 刷新`段）。
- 循环最多由 `MaxVCPLoopStream/NonStream` 控制，默认回退 5；达到上限时流式返回 `finish_reason=length`，非流式也把最终 choice 标为 `length`（`modules/handlers/streamHandler.js:68-70`, `741-752`; `modules/handlers/nonStreamHandler.js:302-304`, `565-589`）。

### 4.2 推理字段、VCP 信息与日志不是同一份消息

- 循环和 OneRing 只读取模型 `message.content`；stream handler 将 reasoning 字段另存于日志 message，不混入 `collectedContentThisTurn`，避免推理链进入工具解析与记忆（`modules/handlers/streamHandler.js:154-169`, `408-417`；非流式同样取 `message.content`，`modules/handlers/nonStreamHandler.js:269-300`）。
- 当模型匹配 reasoning 转正文配置时，发给客户端的 SSE/JSON 才会把 reasoning 包成 `<think>` 或 `<thinking>`；内部循环仍使用原始正文（`modules/reasoningContentAdapter.js:41-49`, `128-137`; `modules/handlers/streamHandler.js:172-217`; `modules/handlers/nonStreamHandler.js:272-285`, `565-577`）。
- `vcpInfoHandler.streamVcpInfo()` 产生的工具结果汇总、成功/失败摘要只写入客户端输出（流式 SSE 或非流式 `conversationHistoryForClient`）；模型下一轮读取的是独立的 `VCP_TOOL_PAYLOAD`。`SHOW_VCP_OUTPUT` 关闭时，`mark_history` 仍可强制显示单个调用（`modules/handlers/streamHandler.js:594-663`; `modules/handlers/nonStreamHandler.js:447-494`）。
- `CHAT_LOG_ENABLED` 打开时，`DebugLog/chat/YYYY-MM-DD/` 才异步写入初始请求、每轮 request/toolCalls/response；默认关闭，不构成会话持久化（`server.js:478-499`）。

## 5. 停止、重试与队列

- 本次调查未发现显式的"停止/重试/队列"用户语义：VCPToolBox 是请求级网关，中断粒度与重试语义由调用方与上游共同决定；协议桥接与 handler 内未见独立的取消/重试入口（未逐行核对的部分见未验证事项）。

## 6. 消息构建边界

已确认：VCPToolBox 在单次 HTTP 请求内拥有完整的"请求历史 → 最终上游 messages → 工具递归 messages"编排能力；它不拥有会话列表、消息编辑/删除/分支或跨请求恢复。`finalContextStore` 是调试快照，不是历史数据库；ChatLog 是可选审计文件，不是前端会话存储。外部 VCPChat、OpenWebUI 或其他客户端必须自行保存并在下一次请求中重新提交历史。

尚未验证：未运行真实上游模型，故没有对每个插件组合下的最终消息数组做运行时快照；`messagePreprocessors` 的未列入 `preprocessor_order.json` 插件顺序只能根据源码确认"按名称排序追加"，不能据此推断每个安装环境的完整实际列表。

## 7. 未验证事项

- 各插件组合下的最终消息数组没有运行时快照。
- `messagePreprocessors` 未列入配置文件的插件实际顺序依赖安装环境。
- 工具循环上限（默认 5）触达后的实际客户端表现未运行验证。
- 与 Agent 的联系：AdminPanel-Vue 的"Agent & 内容"分组（AgentFilesEditor、AgentAssistantConfig、ForumAssistantConfig 等）直接决定接入前端的 Agent 人格、记忆窗口、工具权限与主动任务行为，但 AdminPanel 本身不参与具体某一条聊天消息的收发；更详细的权限/工具边界结论见 `../Agent工具`。

## 8. 关键源码索引

- `server.js`（1206/1220/1235/1239 行聊天相关端点；478-499 行 ChatLog）
- `routes/protocolBridge.js`（协议归一化）
- `modules/chatCompletionHandler.js`（初始请求编排、工具循环刷新、finalContextStore 写入）
- `modules/contextManager.js`（pruneMessages 字符数裁剪）
- `modules/messageProcessor.js`（变量解析与 Agent/Toolbox 展开）
- `modules/roleDivider.js`
- `modules/vcpLoop/toolCallParser.js`
- `modules/handlers/streamHandler.js`、`nonStreamHandler.js`（循环与输出分叉）
- `modules/reasoningContentAdapter.js`
- `vcpInfoHandler.js`（工具结果写回聊天 SSE 流）
- `Plugin/VCPTavern/VCPTavern.js`、`RAGDiaryPlugin`、`VCPTimeLine`、`ContextFoldingV2`、`OneRing`
- `modules/finalContextStore.js`
