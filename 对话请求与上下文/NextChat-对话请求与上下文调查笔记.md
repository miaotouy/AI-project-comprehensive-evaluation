# NextChat 对话请求与上下文调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`1d3dc331512929a4b1d3e82354e72acce33b5c7a`（分支：`main`）
>
> 调查方式：直接阅读源码（客户端 store 的发送与上下文拼装、Provider adapter、SSE 流式工具、MCP server actions），沿提交、上下文与工具接线核对当前实现；流式动画与 Markdown 渲染细节归消息渲染器类目
>
> 调查范围：客户端提交入口 onUserInput、上下文拼装顺序、token 预算与两级压缩、Provider 交接、SSE 流式事件链、完成/异常/半截流收口、停止/重试/续写、队列与并发、插件/MCP/附件注入点、退出恢复与可观测性；会话数据语义与界面工作流分别归入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的生成任务完全在浏览器客户端编排，无服务端任务状态：

1. 用户提交后，提交入口先展开输入模板、合并多模态图片，随后创建 user 消息和一条处于 streaming 状态的 assistant 占位消息，再组装请求并交给 provider adapter。
2. 请求上下文按 system prompt、长期摘要 memoryPrompt、预置 mask.context、受限的短期历史、当前 user 消息的顺序拼装，拼装逻辑在 `getMessagesWithMemory`。
3. assistant 占位消息经 SSE 回调原地更新；工具调用由 OpenAI 系 adapter 收集、在本地执行后带结果重发请求；MCP 结果包成一条特殊的用户消息，再进入提交入口 onUserInput。
4. 长对话做两级压缩：每次请求的短期窗口由 historyMessageCount 与 max_tokens 限制，超过阈值的部分交给 memoryPrompt 摘要；估算长度首次达到 50 个估算词时另起一次请求生成会话标题。
5. 停止与重试由 ChatControllerPool 持有的 AbortController 完成；提交不做排队；本次未找到续写入口。
6. 浏览器端没有独立的任务对象与 trace 记录，占位消息本身就是任务记录，错误以对象文本形式追加进该消息内容。

## 系统边界与生成任务主链

```text
Chat 输入 -> doSubmit（chat.tsx:1105-1124）
   -> useChatStore.onUserInput（chat.ts:407-528）
      fillTemplateWith 模板填充 + 图片多模态合并（:161-203, :420-428）
      -> getMessagesWithMemory（:542-640）
         system -> memoryPrompt -> mask.context -> 短期历史
      -> 保存 user message + streaming assistant 占位（:448-457）
   -> getClientApi(providerName).llm.chat（api.ts:368-399）
      -> 平台 adapter（默认 OpenAI 系 ChatGPTApi.chat，openai.ts:186-430）
      -> streamWithThink / stream（utils/chat.ts:392-667, :175-390）
         SSE 解析、rAF 动画节流、工具收集与重发
      -> onUpdate / onBeforeTool / onAfterTool / onFinish / onError
   -> updateTargetSession -> IndexedDB/localStorage 持久化
   -> onNewMessage：统计、MCP JSON 检测、自动标题/摘要（chat.ts:394-405）
```

边界：占位消息与 `tools`/`memoryPrompt` 的持久化形状、分页窗口数据接口属于会话与消息管理（`../会话与消息管理/NextChat-会话与消息管理调查笔记.md`）；发送/停止按钮、loading 与流式反馈、消息操作入口属于 Chat UI（`<../Chat UI/NextChat-ChatUI调查笔记.md>`）；流式文本的 rAF 动画渲染与 Markdown 绘制属于消息渲染器（`../消息渲染器/NextChat-消息渲染器调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

`onUserInput(content, attachImages?, isMcpResponse?)`（`app/store/chat.ts:407-528`）执行以下步骤：

1. 当前会话的模型配置从 `session.mask.modelConfig` 读出（`app/store/chat.ts:412-413`）。
2. 纯文本输入经 `fillTemplateWith` 展开六个模板变量：输入内容、模型名、时间、语言、服务提供方与截止时间；模板缺少输入占位符时自动追加，输入本身以模板开头时去重。MCP response 跳过模板（`app/store/chat.ts:161-203`、`416-418`）。
3. 带图片时，数组中的文本取原始输入并覆盖前一步的模板结果，再追加图片部件；文本-only 输入应用模板，带图片输入保留原始文本。MCP 回注同样跳过模板。见 [输入分支](../../NextChat/app/store/chat.ts#L415-L427)。
4. 用 `createMessage` 创建 user 消息与 `streaming: true` 的 assistant 占位（`app/store/chat.ts:430-440`）。
5. 调用 `getMessagesWithMemory()`，把历史与新 user 消息组成 `sendMessages`（`app/store/chat.ts:443-444`）。
6. 先写入 user 与 assistant 两条消息，再由 `getClientApi(modelConfig.providerName)` 取到的 adapter 调用 `api.llm.chat`（`app/store/chat.ts:448-457, 459-527`）。

任务对象：项目里没有独立的 Task 类型，assistant 占位消息本身就是任务载体，streaming、isError、tools 与 content 四个字段承载全部任务状态；controller 键用 `messageIndex = session.messages.length + 1` 兜底（`app/store/chat.ts:445, 512-515, 521-525`）。状态机只由 onUpdate、onFinish、onError 三个回调翻转字段，没有中间状态（见 §6）。

## 2. 历史选择与上下文拼装顺序

`getMessagesWithMemory`（`app/store/chat.ts:542-640`）：

- **system prompt**：模型名以 gpt- 或 chatgpt- 开头、且注入开关开启时才生成，内容由默认模板填充后拼接 MCP 工具段（`app/constant.ts:290-297`、`app/store/chat.ts:553-581`）；MCP 已启用而 system prompt 未生成时，单独发送一条 MCP system 消息。
- **长期记忆**：只有会话开启记忆、memoryPrompt 非空、摘要进度晚于清空位置三项同时成立时才发送，内容包在本地化的 History 模板里（`app/store/chat.ts:530-540`、`589-598`）。
- **预置 context**：会话 mask 中的 context 原样进入请求（`app/store/chat.ts:550`、`632-637`）。
- **短期历史**：从末尾向前扫描，起点在清空位置与「摘要位置、总条数减历史条数中的较小值」之间取较大者；反向累计估算长度，达到 max_tokens 即停止，isError 消息跳过不发送（`app/store/chat.ts:600-630`）。

最终顺序（注释与代码一致，`app/store/chat.ts:606-637`）：

```text
0. system prompt（GPT/chatgpt 模型 + MCP 工具段，可选）
1. long-term memory：memoryPrompt（可选）
2. mask.context：预置示例消息
3. short-term history：最近 n 条（historyMessageCount / max_tokens 双限）
4. 当前 user message（onUserInput 追加）
```

`clearContextIndex` 抬高起点后，更早消息与摘要都不再进入请求（其数据语义见会话与消息管理笔记 §4）。错误消息留在数组里但不会进入本次请求（`app/store/chat.ts:627`）。用户档案/知识库注入：本次在拼装路径未找到（检查范围 `app/store/chat.ts` 的 `getMessagesWithMemory` 与 `Mask` 模型）。

## 3. 预算、截断、摘要与压缩

- **token 估算**：估算按字符类别加权，ASCII 字母记 0.25，其他 ASCII 记 0.5，Unicode 字符记 1.5。这是启发式口径，各 provider 分词器的实际结果可能与之有出入（`app/utils/token.ts:1-22`）。
- **短期窗口**：每次请求的历史条数由 historyMessageCount 限制（默认 4），估算长度由 max_tokens 限制（默认 4000）；两项默认值见 `app/store/config.ts:66-79`，拼装过程见 §2。
- **摘要**：较早的对话由 `summarizeSession` 压成长期记忆（`app/store/chat.ts:661-797`）：
  - 起点取摘要位置与清空位置中的较晚者，并过滤掉错误消息（`app/store/chat.ts:727-733`）；
  - 待总结内容的估算长度超过 max_tokens 时，只保留最近 historyMessageCount 条（`app/store/chat.ts:737-742`）；
  - 估算长度超过压缩阈值（compressMessageLengthThreshold，默认 1000）且会话开启记忆时，追加一段「总结」system prompt，用配置的 compressModel 或按模型系选出的摘要模型发起流式请求（`app/store/chat.ts:758-796`、`122-152`）：
    - gpt 与 chatgpt 系固定用 gpt-4o-mini（`app/constant.ts:423`）；
    - gemini 用 gemini-pro；
    - deepseek 用 deepseek-chat；
  - 流式过程中 onUpdate 直接写入 session.memoryPrompt，onFinish 只在响应状态为 200 时提交摘要进度与最终文本（`app/store/chat.ts:780-782`、`783-791`）。
- **自动标题**：自动标题开关开启、会话 topic 仍是默认值、估算消息长度达到 50（SUMMARIZE_MIN_LEN）三个条件同时满足时，取最近 historyMessageCount 条消息加上 topic 提示词，用一次非流式请求生成标题（`app/store/chat.ts:685-726`）；头部的刷新标题按钮改用 `summarizeSession(true, session)` 强制再生成（`app/components/chat.tsx:1716-1726`）。
- **触发点**：每次 assistant 回复成功后，`onNewMessage` 依次更新统计、检测 MCP JSON，然后触发一次摘要（`app/store/chat.ts:394-405`）。
- **不可逆性**：摘要与标题生成失败只记录一条 console.error，原始消息始终保留在本地，请求只携带摘要和最近窗口（持久化形状见会话与消息管理笔记 §7）。

## 4. SDK、Provider、模型与协议交接

- `getClientApi(providerName)` 按 ServiceProvider 选择 adapter；`ClientApi` 在构造时按 ModelProvider 实例化对应的 LLMApi 实现，抽象接口覆盖 chat、speech、usage 与 models 四类能力（`app/client/api.ts:368-399, 136-183, 108-113`）。
- 默认链路走 OpenAI 系的 `ChatGPTApi.chat`（`app/client/platforms/openai.ts:186-430`）：
  - 进入请求构建前，先合并全局与会话两层的模型配置（`openai.ts:187-194`）；
  - DALL-E 3 请求改走 images API（`openai.ts:204-217`）；
  - vision 模型会先对消息里的图片做压缩与 base64 转换（`openai.ts:219-227`，实现见 `app/utils/chat.ts:73-132`）；
  - o1、o3 与 gpt-5 系列会改写请求参数，例如去掉 system 消息、改用 max_completion_tokens；max_tokens 默认不随请求发送，vision 模型例外，取配置值与 4000 中的较大者（`openai.ts:199-259, 238-239, 262-265`）；
  - Azure 部署会解析 deployName 再拼接请求路径，路径经 /api/openai 服务端代理或自配的 baseUrl 发出，认证头由 getHeaders 按 provider 选择（`openai.ts:276-300, 85-122`，`app/client/api.ts:244-366`）。
- 非流式分支在 fetch 返回后直接调用 onFinish；自动标题等其他调用同样走 stream=false 的路径（`openai.ts:405-425`）。
- 服务端角色：/api/config 提供能力探测（`app/store/access.ts:252-264`），/api/[provider]/[...path] 承担协议代理，MCP 在服务端执行（§9）；服务端不保存会话数据（见会话与消息管理笔记 §2）。

## 5. 流式事件、缓冲、节流与顺序

以默认 OpenAI 系链路为例，`streamWithThink`（`app/utils/chat.ts:392-667`）：

- **SSE 消费**：`fetchEventSource` 逐条处理 onmessage，收到 `[DONE]` 或同一事件重复到达时收尾（`app/utils/chat.ts:586-589`）；空数据直接跳过，单条解析抛错只记录日志、不中断整条流（`app/utils/chat.ts:595-599, 650-653`）。
- **缓冲与节流**：文本先进入 remainText，再由 animateResponseText 通过 requestAnimationFrame 每帧最多取总残留量约六十分之一的字符（至少 1 个）刷入 responseText 并回调 onUpdate；输出节流只发生在渲染动画层，收尾时残留文本一次性合并（`app/utils/chat.ts:424-443, 425-427, 519-520`）。
- **think 块**：`<think>` 与 `</think>` 标记被剥离，内部文本转成引用块前缀（`app/utils/chat.ts:602-649`）。
- **工具调用**：parseSSE 按 id 分段累积 tool_calls 的 arguments；流结束时若仍有待执行的工具，就逐个触发 onBeforeTool 与 onAfterTool 执行本地插件函数，再把工具调用消息与结果插入 requestPayload.messages，60ms 后重新发起请求。一轮 SSE 连接对应用户的一次提交（`app/client/platforms/openai.ts:322-385`、`app/utils/chat.ts:448-513`）。
- **顺序保证**：顺序由 SSE 单连接本身保证，服务端没有重连与断点续传；`fetchEventSource` 自身的错误重试行为未验证（见 §11）。
- **超时**：请求超时设为 60 秒（`app/constant.ts:115`），每次请求都会挂一个定时 abort（`app/utils/chat.ts:541-544`）。

## 6. 完成、异常、半截流与最终回写

- **完成**：`onFinish` 写入最终内容与 date 字段、把 streaming 置回 false、触发 onNewMessage（统计、MCP 检测、自动标题与摘要，见 §3），并从 ChatControllerPool 移除本次 controller（`app/store/chat.ts:473-481`）。
- **异常**：`onError` 把错误对象经 `prettyObject` 序列化后追加到 assistant 消息内容，并把 streaming 置回 false；错误消息里含 "aborted" 时只结束生成、不标 isError，其余情况会把 user 与 assistant 两条消息都标成 isError，随后移除 controller（`app/store/chat.ts:498-517`）。
- **半截流**：连接关闭、收到 `[DONE]` 或 abort 都会汇入 finish() 一次性收尾，abort 的接线在请求开始与收尾两处；如果全程没有收到任何内容，则触发一次 "empty response from server" 错误（`app/utils/chat.ts:586-588, 655-657, 298, 524, 428-430`）。
- **回写对象**：更新目标始终是当前会话里的占位消息，updateTargetSession 按 id 定位会话后原地改写数组，不会产生额外的任务对象（`app/store/chat.ts:805-814`）。
- **摘要/标题子请求**：两者都是独立的 `api.llm.chat` 调用，onFinish 里校验响应状态为 200 之后才提交结果（`app/store/chat.ts:715-724, 783-791`）。

## 7. 停止、重试、续写与重新生成

- **停止**：ChatControllerPool 以 sessionId 与 messageId 为键保存 AbortController，停止时对该 controller 调用 abort，controller 在一次请求的 onController 回调里注册；abort 后 signal 的 onabort 回调触发 finish() 收尾，错误路径因为消息含 "aborted" 而不会把消息标成 isError（§6）。停止入口与按钮状态见 Chat UI 笔记 §5（`app/client/controller.ts:2-37`，`app/store/chat.ts:519-526`，`app/utils/chat.ts:298, 524`）。
- **重试**：`onResend` 从 assistant 消息向前找到最近的 user 消息，再从该 user 消息向后找到下一条 assistant 消息，删除这一对之后用相同的文本与图片重新走一遍 onUserInput，生成全新的消息节点。重试的上下文起点由当时的 clearContextIndex 与 lastSummarizeIndex 决定，没有单独的重试起点参数（`app/components/chat.tsx:1217-1271`）。
- **续写**：本次未找到独立的继续生成执行链（检查范围：`app/components/chat.tsx` 的消息操作清单与 `app/store/chat.ts` 的方法集）。
- **重新生成标题**：头部的刷新按钮调用 `summarizeSession(true, session)` 强制重新生成（`app/components/chat.tsx:1716-1726`）。
- **MCP 回注**：`checkMcpJson` 检查 assistant 输出里的代码围栏，围栏信息为 `json:mcp:<clientId>` 时命中；命中后交给服务端的 `executeMcpAction` 执行，结果再包成围栏信息为 `json:mcp-response:<clientId>` 的代码块，以 isMcpResponse=true 重新进入 onUserInput。这是唯一由程序自动发起的二次提交通道，MCP response 不做模板填充（`app/mcp/utils.ts:1-11`，`app/store/chat.ts:827-856, 416-418`）。

## 8. 队列、多会话并发与后台生成

- 每次提交都直接调用 onUserInput，本次未找到发送队列或 busy 锁，界面上也没有排队提示（检查范围：`app/store/chat.ts` 与 `app/components/chat.tsx`）。
- 同一会话快速连续提交时，每次调用都创建独立的 botMessage，占位消息分别追加到同一会话数组，各请求回调更新各自闭包中的对象（`app/store/chat.ts:436-480`）。快速连续提交的上下文选择与数组更新竞态尚未运行验证。
- 多会话并行：没有全局串行化，ChatControllerPool 按 sessionId 与 messageId 键控，各会话互不干扰（`app/client/controller.ts:5-36`）。
- 后台生成：没有后台任务机制；窗口或标签页关闭时浏览器会中止未完成的 fetch（未验证）。在 app 目录搜索 beforeunload、pagehide、visibilitychange 与 unload 均无匹配，说明代码里没有显式的 unload 中止逻辑。

## 9. Agent、工具、知识库与附件注入点

- **插件工具**：发起请求时，只有 OpenAI 系 adapter 会生成 tools 定义与本地函数（`app/client/platforms/openai.ts:308-313`），工具集合来自当前会话所选插件（`app/store/plugin.ts:209-220`）；执行发生在流收尾的 finish() 里，执行完带结果重发（§5）。非 OpenAI 系 adapter 的工具行为未逐一核实。
- **MCP**：MCP 开关打开时，`getMcpSystemPrompt` 用 AccessStore 里的 access code 取出全部 MCP 客户端工具并注入 system prompt；执行走服务端的 "use server" actions，每个入口都要求 ENABLE_MCP 与部署侧 CODE 配置匹配的 access code（`app/store/chat.ts:205-224, 553-581`，`app/mcp/actions.ts:29-50, 379-397`）。客户端实例存活在 Next.js 服务端进程里，配置来自 `app/mcp/mcp_config.json`（`app/mcp/actions.ts:20-21, 399-422`）。工具结果经回注通道进入会话（§7）。
- **附件**：图片进入消息 content 的多模态数组；vision 模型在 adapter 内调用 preProcessImageContent 压缩并转 base64，DALL-E 则取最后一条消息的文本作 prompt（`app/store/chat.ts:420-428`，`openai.ts:219-227, 204-217`，`app/utils/chat.ts:73-132`）。
- **变量**：`fillTemplateWith` 在提交时展开六个模板占位符（`app/store/chat.ts:161-203`）：

  ```text
  {{input}}  {{model}}  {{time}}  {{lang}}  {{ServiceProvider}}  {{cutoff}}
  ```
- 知识库与联网：本次在请求链上没有找到独立注入点（检查范围：`app/store/chat.ts`、`app/client/platforms/openai.ts` 与 MCP 注入路径）。

## 10. 退出恢复、日志与已确认边界

- 浏览器端承担全部运行时：任务状态保存在内存与 IndexedDB 中，没有任务 ID、trace 或用量日志；控制台日志只到消息与请求粒度，前缀为 `[Chat]`、`[Request]`、`[Memory]`、`[Sync]` 等。
- 刷新与关闭：页面卸载时没有中止逻辑（§8）；重启后残留的 streaming 消息由 Chat 页面在启动时清理（会话与消息管理笔记 §3，`app/components/chat.tsx:1148-1175`）。
- 错误关联：错误对象被序列化进 assistant 消息内容，只能顺着消息内容追溯，没有独立的错误存储。
- 已确认边界：流式节流发生在渲染动画层，网络层不做节流；SSE 没有断点续传；同一连接内的工具循环重发由客户端的 60ms 定时器驱动（`app/utils/chat.ts:506-511`）；普通请求不发送 max_tokens，注释中有明确说明（`app/client/platforms/openai.ts:238-239`）。

## 11. 未验证事项

- 停止按钮的网络级 abort 效果、`fetchEventSource` 在 `onerror` 后 `throw e`（`app/utils/chat.ts:658-661`）的默认重试行为未验证。
- 同一会话连续提交的并发竞态、MCP 回注的重复提交边界（模型持续输出 mcp 围栏时）未运行验证。
- 摘要/标题的模型输出质量与截断未验证；`estimateTokenLength` 与真实 tokenizer 的偏差未量化。
- 非 OpenAI 系 adapter 的流式/工具链未逐一核实（本文以默认 OpenAI 系链路为样本）。
- 未运行项目测试或浏览器交互测试；本笔记结论来自当前 HEAD 源码。

## 12. 关键源码索引

- 提交入口与流式回调：`app/store/chat.ts:407-528`
- 上下文拼装：`app/store/chat.ts:542-640`
- 自动标题与摘要：`app/store/chat.ts:661-797`（触发点 `:394-405`）
- MCP JSON 检测与回注：`app/store/chat.ts:828-862`
- 停止 controller：`app/client/controller.ts:2-37`
- Provider 选择与 adapter 抽象：`app/client/api.ts:136-183`、`:368-399`
- OpenAI 系请求构建与工具重发：`app/client/platforms/openai.ts:186-430`
- SSE 流式与动画节流：`app/utils/chat.ts:392-667`
- MCP 服务端执行与授权门：`app/mcp/actions.ts:29-50`、`:379-397`
- MCP 工具注入 system prompt：`app/store/chat.ts:205-224`、`:553-581`
- 重试数据变更：`app/components/chat.tsx:1217-1271`
