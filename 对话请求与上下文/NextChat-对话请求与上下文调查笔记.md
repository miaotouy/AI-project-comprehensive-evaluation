# NextChat 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\NextChat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：直接阅读源码（客户端 store 的发送与上下文拼装、Provider adapter、SSE 流式工具、MCP server actions），对引用的符号与行号逐一核对当前 HEAD；流式动画与 Markdown 渲染细节归消息渲染器类目
>
> 调查范围：客户端提交入口 onUserInput、上下文拼装顺序、token 预算与两级压缩、Provider 交接、SSE 流式事件链、完成/异常/半截流收口、停止/重试/续写、队列与并发、插件/MCP/附件注入点、退出恢复与可观测性；会话数据语义与界面工作流分别归入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的生成任务完全在浏览器客户端编排，无服务端任务状态：

1. `onUserInput` 先填充输入模板与多模态图片，再创建 user 消息 + `streaming: true` 的 assistant 占位，随后组装请求并调用 provider adapter。
2. 上下文按 system prompt → 长期摘要 `memoryPrompt` → `mask.context` → 短期历史（token 估算受限）→ 新 user 消息的顺序组装（`getMessagesWithMemory`）。
3. 占位消息经 SSE 回调原地更新；工具调用由 OpenAI 系 adapter 收集、本地执行并带结果重发请求；MCP 结果以特殊用户消息再进入 `onUserInput`。
4. 长对话两级压缩：`historyMessageCount`/`max_tokens` 管每次请求的短期窗口，`memoryPrompt` 管超过阈值后的摘要；首次达到 50 个估算词时单独生成会话标题。
5. 停止/重试走 `ChatControllerPool`（AbortController）；无发送队列；无续写入口（本次未找到）。
6. 无任务对象与 trace：占位消息本身就是任务记录，错误以对象文本追加进消息内容。

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

1. 读取当前会话的 `session.mask.modelConfig`（`app/store/chat.ts:412-413`）。
2. 普通输入经 `fillTemplateWith` 展开 `{{input}}`、`{{model}}`、`{{time}}`、`{{lang}}`、`{{ServiceProvider}}`、`{{cutoff}}` 六个模板变量；模板缺 `{{input}}` 时自动追加；输入以模板开头时去重（`app/store/chat.ts:161-203`）。MCP response 跳过模板（`app/store/chat.ts:416-418`）。
3. 图片附件与文本合并为 `text + image_url` 多模态数组（`app/store/chat.ts:420-428`）。
4. 用 `createMessage` 创建 user 消息与 `streaming: true` 的 assistant 占位（`app/store/chat.ts:430-440`）。
5. 调用 `getMessagesWithMemory()`，把历史与新 user 消息组成 `sendMessages`（`app/store/chat.ts:443-444`）。
6. 先写入 user/assistant 两条消息（`app/store/chat.ts:448-457`），再从 `getClientApi(modelConfig.providerName)` 调用 `api.llm.chat`（`app/store/chat.ts:459-527`）。

任务对象：没有独立 Task 类型，assistant 占位消息就是任务载体——`streaming`/`isError`/`tools`/`content` 字段承载全部状态；`messageIndex = session.messages.length + 1` 作为 controller 键的兜底（`app/store/chat.ts:445, 512-515, 521-525`）。状态机只有三个回调翻转字段（onUpdate/onFinish/onError），无中间状态（见 §6）。

## 2. 历史选择与上下文拼装顺序

`getMessagesWithMemory`（`app/store/chat.ts:542-640`）：

- **system prompt**：仅当模型名以 `gpt-`/`chatgpt-` 开头且 `enableInjectSystemPrompts` 开启时生成，内容为 `DEFAULT_SYSTEM_TEMPLATE`（`app/constant.ts:290-297`）填充后拼接 MCP 工具段；MCP 启用但无 system prompt 时单独发送 MCP system 消息（两处均在 `app/store/chat.ts:553-581`）。
- **长期记忆**：`sendMemory && memoryPrompt 非空 && lastSummarizeIndex > clearContextIndex` 时才发送，内容包在 `Locale.Store.Prompt.History` 模板里（`app/store/chat.ts:530-540, 589-598`）。
- **预置 context**：`session.mask.context` 原样进入请求（`app/store/chat.ts:550, 632-637`）。
- **短期历史**：从末尾向前扫描，起点为 `max(clearContextIndex, min(lastSummarizeIndex, 总条数 - historyMessageCount))`；反向循环按 `estimateTokenLength` 累计，达到 `max_tokens` 停止；`isError` 消息跳过不发送（`app/store/chat.ts:600-630`）。

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

- **token 估算**：`estimateTokenLength`（`app/utils/token.ts:1-22`）：ASCII 字母 0.25、其他 ASCII 0.5、Unicode 1.5——启发式，不保证与各 provider tokenizer 一致。
- **短期窗口**：`historyMessageCount`（默认 4）与 `max_tokens`（默认 4000，`app/store/config.ts:66-79`）共同限制每次请求的历史条数与估算长度（§2）。
- **摘要**：`summarizeSession`（`app/store/chat.ts:661-797`）：
  - 起点 `max(lastSummarizeIndex, clearContextIndex)`，过滤错误消息（`app/store/chat.ts:727-733`）；
  - 待总结内容估算长度超过 `max_tokens` 时只保留最近 `historyMessageCount` 条（`app/store/chat.ts:737-742`）；
  - 超过 `compressMessageLengthThreshold`（默认 1000）且 `sendMemory` 为 true 时，追加 "总结" system prompt，用配置的 `compressModel` 或 `getSummarizeModel` 发起流式请求（`app/store/chat.ts:758-796`）；`getSummarizeModel` 按模型系选择摘要模型（`app/store/chat.ts:122-152`）：
    - gpt/chatgpt 系强制 `gpt-4o-mini`（`SUMMARIZE_MODEL`，`app/constant.ts:423`）；
    - gemini 用 `gemini-pro`；
    - deepseek 用 `deepseek-chat`；
  - 流式 `onUpdate` 直接写 `session.memoryPrompt`（`app/store/chat.ts:780-782`）；`onFinish` 仅响应 200 时提交 `lastSummarizeIndex` 与最终文本（`app/store/chat.ts:783-791`）。
- **自动标题**：`enableAutoGenerateTitle` 开启、topic 仍是默认值且估算消息长度达到 50（`SUMMARIZE_MIN_LEN`）时，取最近 `historyMessageCount` 条消息 + topic 提示词，用非流式请求生成标题（`app/store/chat.ts:685-726`）；头部"刷新标题"按钮用 `summarizeSession(true, session)` 强制再生成（入口 `app/components/chat.tsx:1716-1726`）。
- **触发点**：`onNewMessage` 在每次成功 assistant 消息后依次更新统计、检测 MCP JSON、调用 `summarizeSession(false, targetSession)`（`app/store/chat.ts:394-405`）。
- **不可逆性**：摘要/标题失败只 `console.error`，原始消息从不删除——本地保留完整历史、请求只带摘要和最近窗口（持久化形状见会话与消息管理笔记 §7）。

## 4. SDK、Provider、模型与协议交接

- `getClientApi(providerName)` 按 `ServiceProvider` 选择 adapter（`app/client/api.ts:368-399`）；`ClientApi` 构造时按 `ModelProvider` 实例化具体 `LLMApi`（`app/client/api.ts:136-183`）；`LLMApi` 抽象接口为 chat/speech/usage/models（`app/client/api.ts:108-113`）。
- 默认 OpenAI 系 `ChatGPTApi.chat`（`app/client/platforms/openai.ts:186-430`）：
  - 合并全局与会话 modelConfig（`openai.ts:187-194`）；
  - DALL-E 3 分支改走 images API（`openai.ts:204-217`）；
  - vision 模型对消息内容做图片预处理（压缩/转 base64，`openai.ts:219-227`，实现在 `app/utils/chat.ts:73-132`）；
  - o1/o3/gpt-5 系列改写参数（去 system、`max_completion_tokens` 等，`openai.ts:199-259`）；`max_tokens` 默认不发送，vision 模型例外取 `max(config, 4000)`（`openai.ts:238-239, 262-265`）；
  - Azure 时解析 deployName 拼接路径（`openai.ts:276-300`）；路径经 `/api/openai` 服务端代理或自配 baseUrl（`openai.ts:85-122`）；认证头由 `getHeaders` 按 provider 选择（`app/client/api.ts:244-366`）。
- 非流式分支直接 fetch + `onFinish`（`openai.ts:405-425`）；`stream=false` 也用于自动标题与 `getClientApi` 的其他调用。
- 服务端角色：`/api/config` 提供能力探测（`app/store/access.ts:252-264`）；`/api/[provider]/[...path]` 是协议代理；MCP 执行在服务端（§9）。服务端不保存会话（见会话与消息管理笔记 §2）。

## 5. 流式事件、缓冲、节流与顺序

以默认 OpenAI 系链路为例，`streamWithThink`（`app/utils/chat.ts:392-667`）：

- **SSE 消费**：`fetchEventSource` 逐条 `onmessage`，`[DONE]` 或重复到达时收尾（`app/utils/chat.ts:586-589`）；空数据跳过；parseSSE 抛错只记录不中断（`app/utils/chat.ts:595-599, 650-653`）。
- **缓冲与节流**（`app/utils/chat.ts:424-443`）：文本先进 `remainText`，`animateResponseText` 用 `requestAnimationFrame` 每帧最多取 `max(1, round(remain/60))` 个字符刷入 `responseText` 并回调 `onUpdate(responseText, chunk)`——这是唯一的输出节流，位置在渲染动画层；`finish` 时把残留文本一次合并（:425-427、:519-520）。
- **think 块**：`<think>`/`</think>` 标记剥离并转成 `>` 引用块前缀（`app/utils/chat.ts:602-649`）。
- **工具调用**（`openai.ts:322-385`、`app/utils/chat.ts:448-513`）：parseSSE 累积 `tool_calls`（`runTools` 按 id 分段拼接 arguments）；流结束 `finish()` 时若有余留工具，逐个 `onBeforeTool`/`onAfterTool` 执行插件 funcs，再经 `processToolMessage` 把 tool_calls 消息与结果 splice 进 `requestPayload.messages`，60ms 后重新发起请求——一轮 SSE 连接对应用户的一次提交。
- **顺序保证**：依赖 SSE 单连接顺序；无服务端重连与断点续传（`fetchEventSource` 自身的错误重试行为未验证，见 §11）。
- **超时**：`REQUEST_TIMEOUT_MS = 60000`（`app/constant.ts:115`）在每次请求时设置定时 abort（`app/utils/chat.ts:541-544`）。

## 6. 完成、异常、半截流与最终回写

- **完成**：`onFinish` 写入最终内容与 date、`streaming = false`、触发 `onNewMessage`（统计、MCP 检测、自动标题/摘要，§3），并从 `ChatControllerPool` 移除 controller（`app/store/chat.ts:473-481`）。
- **异常**（`app/store/chat.ts:498-517`）：`onError` 把错误对象以 `prettyObject` 追加到 assistant.content，`streaming = false`；aborted 错误（消息含 "aborted"）不置 `isError`，其余情况 user/assistant 双双置 `isError`，随后移除 controller。
- **半截流**：连接关闭（`onclose`）、`[DONE]` 或 abort 都汇入 `finish()` 一次性收尾（`app/utils/chat.ts:586-588, 655-657`；abort 接线 :298、:524）；全程空响应触发 `onError("empty response from server")`（:428-430）。
- **回写对象**：始终是当前会话的占位消息（`updateTargetSession` 按 id 定位会话后原地更新数组，`app/store/chat.ts:805-814`），不产生额外任务对象。
- **摘要/标题子请求**：独立的 `api.llm.chat` 调用，`onFinish` 校验 `responseRes.status === 200` 后才提交（`app/store/chat.ts:715-724, 783-791`）。

## 7. 停止、重试、续写与重新生成

- **停止**：`ChatControllerPool`（`app/client/controller.ts:2-37`）按 `sessionId,messageId` 保存 AbortController，`stop` 调用 `controller.abort()`（:15-19），controller 在 `onController` 中注册（`app/store/chat.ts:519-526`）。abort 后 `signal.onabort` 触发 `finish()` 收尾（`app/utils/chat.ts:298, 524`），错误路径因消息含 "aborted" 不置 `isError`（§6）。停止入口与按钮状态见 Chat UI 笔记 §5。
- **重试**：`onResend`（`app/components/chat.tsx:1217-1271`）——assistant 消息向前找最近 user 消息，user 消息向后找下一条 assistant 消息；删除这对消息后用相同文本与图片重新 `onUserInput`，生成全新消息节点。重试上下文起点由当时的 `clearContextIndex`/`lastSummarizeIndex` 决定，无独立重试起点参数。
- **续写**：本次未找到独立"继续生成"执行链（检查范围 `app/components/chat.tsx` 消息操作清单与 `app/store/chat.ts` 方法集）。
- **重新生成标题**：头部刷新按钮 `summarizeSession(true, session)`（`app/components/chat.tsx:1716-1726`）。
- **MCP 回注**：`checkMcpJson` 检测 assistant 输出中的 ` ```json:mcp:<clientId> ` 围栏（`app/mcp/utils.ts:1-11`），经服务端 `executeMcpAction` 执行后，把结果包成 ` ```json:mcp-response:<clientId> ` 围栏并以 `isMcpResponse=true` 再次进入 `onUserInput`（`app/store/chat.ts:827-856`）——这是唯一由程序自动发起的"二次提交"通道，MCP response 不再做模板填充（`app/store/chat.ts:416-418`）。

## 8. 队列、多会话并发与后台生成

- 每次提交都直接走 `onUserInput`，无发送队列、无排队 UI（本次未找到队列或 busy 锁，检查范围 `app/store/chat.ts` 与 `app/components/chat.tsx`）。
- 同一会话快速连续提交会各自追加占位消息并各自发起请求；两个请求的流式回调共享同一个 `botMessage` 对象引用，存在并发原地改写（静态推断，未运行验证竞态）。
- 多会话并行：无全局串行化；`ChatControllerPool` 按 `sessionId,messageId` 键控，互不干扰（`app/client/controller.ts:5-36`）。
- 后台生成：无后台任务机制；窗口/标签页关闭时浏览器中止 fetch（未验证）；`app` 目录 grep `beforeunload`/`pagehide`/`visibilitychange`/`unload` 均无匹配，即没有显式 unload 中止逻辑。

## 9. Agent、工具、知识库与附件注入点

- **插件工具**：仅 OpenAI 系 adapter 在发起请求时生成 tools 定义与本地 funcs（`usePluginStore.getAsTools(session.mask.plugin)`，`openai.ts:308-313`；`app/store/plugin.ts:209-220`），工具执行由流收尾处的 `finish()` 完成并带结果重发（§5）。非 OpenAI 系 adapter 的工具行为未逐一核实。
- **MCP**：`isMcpEnabled` 时 `getMcpSystemPrompt` 把全部 MCP 客户端工具 JSON 注入 system prompt（`app/store/chat.ts:205-224, 558-581`）；执行走服务端 `"use server"` actions（`app/mcp/actions.ts:337-352`），客户端实例存活于 Next.js 服务端进程，配置在 `app/mcp/mcp_config.json`（`app/mcp/actions.ts:22, 142-161`）；工具结果经回注通道进入会话（§7）。
- **附件**：图片进消息 content 多模态数组（`app/store/chat.ts:420-428`）；vision 模型在 adapter 内 `preProcessImageContent` 压缩/转 base64（`openai.ts:219-227`，`app/utils/chat.ts:73-132`）；DALL-E 取最后一条消息文本作 prompt（`openai.ts:204-217`）。
- **变量**：`{{input}}`/`{{model}}`/`{{time}}`/`{{lang}}`/`{{ServiceProvider}}`/`{{cutoff}}` 在 `fillTemplateWith` 展开（`app/store/chat.ts:161-203`）。
- 知识库/联网：本次在请求链（`app/store/chat.ts`、`app/client/platforms/openai.ts`、MCP 注入路径）未找到独立注入点（检查范围如上）。

## 10. 退出恢复、日志与已确认边界

- 无服务端 runtime：任务状态全部在浏览器内存 + IndexedDB；没有任务 ID、trace 或用量日志（`console` 日志为消息/请求级：`[Chat]`、`[Request]`、`[Memory]`、`[Sync]` 等）。
- 刷新/关闭：无 unload 中止逻辑（§8）；重启后残留的 streaming 消息由 Chat 页面启动清理（会话与消息管理笔记 §3，`app/components/chat.tsx:1148-1175`）。
- 错误关联：错误对象序列化进 assistant 消息内容，可通过消息内容追溯，无独立错误存储。
- 已确认边界：流式节流在渲染动画层而非网络层；SSE 无断点续传；同一连接内的工具循环重发由客户端 `setTimeout(60ms)` 驱动（`app/utils/chat.ts:506-511`）；`max_tokens` 不随普通请求发送（`openai.ts:238-239` 注释明确说明）。

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
- MCP JSON 检测与回注：`app/store/chat.ts:827-856`
- 停止 controller：`app/client/controller.ts:2-37`
- Provider 选择与 adapter 抽象：`app/client/api.ts:136-183`、`:368-399`
- OpenAI 系请求构建与工具重发：`app/client/platforms/openai.ts:186-430`
- SSE 流式与动画节流：`app/utils/chat.ts:392-667`
- MCP 服务端执行：`app/mcp/actions.ts:90-99`、`:337-385`
- 重试数据变更：`app/components/chat.tsx:1217-1271`
