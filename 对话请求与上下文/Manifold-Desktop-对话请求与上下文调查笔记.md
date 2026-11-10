# Manifold Desktop 对话请求与上下文调查笔记

> 调查对象：`https://github.com/gregorik/Manifold-Desktop`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：直接阅读源码并对照当前 HEAD 逐项核对符号与行号：前端发送链（`input-bar.js` → `app.js` → `provider-api.js` → 桥消息）、C++ 执行链（`HandleChatSend` → `Provider::StreamChat` → `HttpClient::StreamPost` → 广播）、三个 Provider 的请求体构造，并对取消、工具执行、附件与设置字段的调用点做全仓库搜索
>
> 调查范围：一次生成任务的提交入口、历史选择、上下文拼装、Provider 交接、流式广播、取消、回写、并发与外部能力注入点；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

请求主链是"前端标签页 → WebView2 消息桥 → C++ 主进程 UI 线程 → 后台线程 Provider 流式调用 → 全局广播回前端"：

```text
input-bar doSend（input-bar.js:169-184）
  -> app.js onSend（86-123）：addUserMessage 入 messages[] + providerApi.sendChat
  -> CHAT_SEND 桥消息 -> OnWebMessage 分发（MainWindow.xaml.cpp:419-454）
  -> HandleChatSend（757-841）：构造 ChatRequest、注入 MCP 工具、起 std::jthread
  -> Provider::StreamChat（OpenAI/Gemini/Anthropic）-> HttpClient::StreamPost（WinHTTP SSE）
  -> CHAT_CHUNK / CHAT_DONE / CHAT_ERROR 广播 -> 所有 chat-tab 全局监听
```

执行层确认的缺口：assistant 的流式回复只写进 DOM，没有回写当前标签的消息数组，第二次发送时上下文里缺少上一轮的 assistant 回复（数据语义见会话与消息管理笔记）。`CHAT_CHUNK` 与 `CHAT_DONE` 两条广播都不带会话标识，主进程也只维护一条聊天线程（`MainWindow.xaml.h:54`），常规聊天因此全局串行。前端随请求发送的 temperature 与 tools 字段在后端没有读取点，MCP 工具只被注入进请求体，不会被调用执行。

## 系统边界与生成任务主链

```text
input-bar.js doSend（读取输入、清空 textarea）
  -> app.js addUserMessage（入 messages[]）+ providerApi.sendChat（provider-api.js:4-13）
  -> CHAT_SEND -> HandleChatSend（MainWindow.xaml.cpp:757-841）
  -> Provider::StreamChat -> 线程内 onChunk 回调 -> DispatcherQueue -> PostMessageToWeb
  -> chat-tab.js 更新 streamingText 与 DOM（渲染细节在消息渲染器）
```

边界：会话文件如何持久化、搜索与导入导出属于会话与消息管理；标签页、侧栏、搜索浮层与错误重试的界面工作流属于 Chat UI；chunk 到 DOM 的内容渲染属于消息渲染器（`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

- **入口**：输入栏在发送时读取输入文本、清空 textarea，再把文本交给应用层的 `onSend` 回调（`input-bar.js:169-184`、`app.js:86-123`）；回调把用户消息追加进当前标签的消息数组，随后经 `providerApi.sendChat` 发出 `CHAT_SEND` 桥消息（`chat-tab.js:119-126`、`provider-api.js:4-13`）。
- **任务对象**：`HandleChatSend` 把 payload 里的 provider、model、messages 与 systemPrompt 读进通用请求对象 `ChatRequest`，请求本身没有显式任务 ID，任务身份由全局聊天线程与无标识的广播事件隐含表示（`MainWindow.xaml.cpp:759-762`、`:771-783`）。
- **状态机**：未发现任务级状态机或占位消息；用户消息同步进入消息数组，前端的 `streaming` 标志只是组件与输入栏各自的局部布尔，应用层另有 `appStreaming` 布尔（`chat-tab.js:19,31`、`input-bar.js:10,22-30`、`app.js:21,111,132-135`）。

## 2. 历史选择与上下文拼装顺序

- **历史选择**：发送时取的是当前标签的整份历史。标签侧的 `getMessages()` 把消息数组里的 `role` 与 `content` 复制成一个列表交给请求构造，不再按 token、分支或角色筛选（`chat-tab.js:127-129`）。
- **顺序与 prompt 来源**：上下文顺序就是消息数组的顺序；system prompt 随请求从设置里取值，payload 缺省时后端回退到已保存的 systemPrompt（`app.js:120`、`MainWindow.xaml.cpp:762`）。assistant 的流式文本只更新 DOM 与 streamingText，不回写消息数组，因此第二轮消息不含上一轮的 assistant 回复（`chat-tab.js:27-59`；该数据缺口在会话与消息管理笔记）。

## 3. 预算、截断、摘要与压缩

发送前未找到上下文截断、摘要压缩或 token 预算处理（检查范围：发送链 `input-bar.js/app.js/provider-api.js`、`HandleChatSend`、`ChatRequest` 定义）。输入栏的 `~N tokens` 估算仅按字符数/4 显示（`input-bar.js:84-87`），不参与请求构造。

## 4. SDK、Provider、模型与协议交接

- **Provider 解析**：`HandleChatSend` 按请求里的 provider 名向 `ProviderRegistry` 取实例，取不到就直接回 `CHAT_ERROR`。Gemini、OpenAI、Anthropic、Proxy、Ollama 与 OpenAI-compat 六个 Provider 在窗口构造时一次性注册（`MainWindow.xaml.cpp:764-768`，注册见 `:129-155`）。
- **参数交接（多个前端字段在后端不消费）**：
  - 温度：请求里的温度一律取自宿主保存的全局设置，前端 payload 中随请求发出的 `temperature` 没有读取点，发送值不生效（`MainWindow.xaml.cpp:775`）；
  - 工具定义：请求里的工具只来自 MCP 客户端注入的清单，前端 `tools` 字段同样无人消费（`MainWindow.xaml.cpp:786-789`、`provider-api.js:11`）；
  - 流式开关：设置项 `streamResponses` 在发送路径上没有读取点，grep 只在 settings-store、settings-panel 与 SettingsManager 命中该名字，切换界面开关不改变发送行为。
- **协议映射**：两个 Provider 各自在 BuildRequestBody 里把通用请求对象翻译成自家格式：
  - OpenAI 系把 system prompt 放成首条 system 消息、role 原样传递，内容 parts 合成内容数组，工具定义转成 function schema（`OpenAIProvider.cpp:20-86`）。
  - Gemini 把 assistant 角色映射为 model，system prompt 移入 systemInstruction，温度放进 generationConfig，工具转成 functionDeclarations（`GeminiProvider.cpp:16-88`）。
  - 两者最终都交给共享网络层 `HttpClient::StreamPost`，由它持有 WinHTTP 请求、读取与句柄关闭，再把原始 chunk 回调给 Provider 做 SSE 行解析（`HttpClient.cpp:93-155`）。
- **交接点结论**：请求体在 Provider 内直接构造，不存在独立的 Adapter 层；`ChatMessage.role` 原样进入 OpenAI 系请求，system/assistant 语义差异由各 Provider 自行处理。

## 5. 流式事件、缓冲、节流与顺序

- **链**（`MainWindow.xaml.cpp:800-822`）：Provider 线程每产出一段增量，都沿同一条路径送回前端。
  1. Provider 线程的 onChunk 回调先确认任务没有收到停止请求，再把文本、工具调用与结束标记打包成 chunk 数据；
  2. 这份数据经 DispatcherQueue.TryEnqueue 切回 UI 线程，由 PostMessageToWeb 以 `CHAT_CHUNK` 广播出去；
  3. 前端 bridge.js 收到桥消息后分发，各 chat-tab 的全局监听器各自更新自己的流式状态（`bridge.js:30-40`、`chat-tab.js:27-59`）。
- **缓冲**：SSE 行缓冲在 Provider 层（`OpenAIProvider.cpp:151-203`、`GeminiProvider.cpp:157-181`）；未发现节流或合并逻辑。
- **顺序**：chunk 经同一 dispatcher 队列投递（`:819-821`），静态推断同一请求内顺序保持；未运行验证。
- **串扰风险**：chunk/done 载荷不含 session/tab 标识，所有已打开标签都监听同一广播（`chat-tab.js:27,61,87`）；多标签同时打开时一个请求可能更新多个标签的局部消息区（可见行为未运行验证）。

## 6. 完成、异常、半截流与最终回写

- **完成**：后台线程跑完且期间没有收到停止请求时，主进程广播 `CHAT_DONE`，并带上本次消耗的 tokens 与 finishReason；前端收到后结束流式状态、挂上 cost badge 展示费用并累计用量（`MainWindow.xaml.cpp:824-833`、`chat-tab.js:61-85`）。完整的流式文本只留在 DOM 与 streamingText 中，既不回写消息数组也不落盘（落盘缺口见会话与消息管理笔记）。
- **异常**：`catch` 回 `CHAT_ERROR`（`MainWindow.xaml.cpp:834-839`）；前端渲染错误行，其 Retry 按钮只删除错误提示、不重发请求（`chat-tab.js:87-98`），工作流见 Chat UI 笔记。
- **半截流**：任何路径都没有把半截文本写入消息数组或文件；停止后 `CHAT_DONE` 不会发送（`:824` 的 `stop_requested` 判断）。

## 7. 停止、重试、续写与重新生成

- **停止**：前端发来的 `CHAT_CANCEL` 由 `HandleChatCancel` 处理：先对当前线程请求停止，再用一个空的线程对象替换 `m_chatThread`。这条路径有两条静态推断出的边界（`MainWindow.xaml.cpp:843-850`）：
  - 停止标记只在 Provider 的 onChunk 回调里检查一次，而网络层是 `HttpClient::StreamPost` 内阻塞式的 WinHttpQueryDataAvailable 与 WinHttpReadData 循环，取消无法主动打断已经阻塞的读取，只能等下一次回调（`HttpClient.cpp:140-149`）；
  - 给 `std::jthread` 赋新值会先请求旧线程停止、再 join 等待结束；旧线程卡在读取上时，这次 join 会把 UI 线程一并阻塞到读取返回。
  真实中断效果均需运行验证。
- **新请求先停旧线程**：`HandleChatSend` 在启动新线程前执行同样动作（`MainWindow.xaml.cpp:791-795`），因此连续发送是"停旧 + join + 起新"的串行关系。
- **重试/续写/重新生成**：除无效 Retry 按钮外未发现独立机制（grep 检查范围：chat-tab.js、app.js、MainWindow 聊天 handler）；再次发送就是重走同一主链，起始上下文仍是当前 `messages[]`。

## 8. 队列、多会话并发与后台生成

- 常规聊天在主进程里只占一条全局线程 `m_chatThread`，发送队列、按会话隔离与后台生成机制都不存在，不同标签的聊天请求会互相覆盖，原因见第 7 节的停止逻辑（`MainWindow.xaml.h:54`）。
- compare 标签走另一套线程结构：独立的线程向量 `m_compareThreads` 为每个槽位各开一条线程，与 chat 线程并存；compare 请求不注入 MCP 工具，其广播事件（如 `COMPARE_CHUNK`）带 `slotIndex` 标识，与 chat 广播不同源（`MainWindow.xaml.h:55`、`MainWindow.xaml.cpp:1063-1125`）。

## 9. Agent、工具、知识库与附件注入点

- **MCP 工具（只注入、不执行）**：整条链止于工具定义的注入与工具调用的展示。
  - 注入：每次构造请求时用 `m_mcpClient.GetAllTools()` 取回全部工具直接挂到请求上，工具 schema 由两个 Provider 各自翻译进请求体（`MainWindow.xaml.cpp:786-789`、`OpenAIProvider.cpp:74-83`、`GeminiProvider.cpp:79-85`）；
  - 展示：模型返回的 toolCall 增量在前端只渲染成可折叠卡片，没有回执或执行动作（`chat-tab.js:47-49`、`message-renderer.js:36-56`）；
  - 执行入口：全仓库搜索显示 `MCPClient::CallTool` 与 `ChatRequest.maxToolCallRounds` 既无调用点也无读取点，因此不存在工具循环（`MCPClient.cpp:131`、`ProviderTypes.h:128`）。
- **附件**：后端有文件对话框与 `FILE_ATTACHED` 广播（`MainWindow.xaml.cpp:559-617`），前端无发送方与监听方（grep 无结果），附件链路未接通。
- **记忆/知识库/Agent 角色**：Chat 主链上未找到对应字段或注入点（检查范围：`provider-api.js`、`HandleChatSend`、`ProviderTypes.h`）。

## 10. 退出恢复、日志与已确认边界

- 会话状态全部在内存（标签局部 `messages[]`），应用退出即丢失；窗口关闭流程只处理终端、插件与 MCP 连接（`MainWindow.xaml.cpp:179-192`），不保存聊天状态；磁盘侧恢复能力缺失见会话与消息管理笔记。
- 未发现任务级日志或 trace；可观测性只有 `CHAT_DONE` 携带的 tokens、前端 cost badge（`chat-tab.js:65-82`）与 localStorage 用量累计（`pricing.js:40-61`）。
- 已确认边界：参数丢弃、广播无标识、工具不执行均来自当前 HEAD 的静态调用点搜索；取消的真实中断效果、多标签串流与网络阻塞场景未做动态验证。

## 11. 未验证事项

- 取消延迟、join 阻塞 UI 线程、网络阻塞读取的中断效果需运行验证（基于 jthread 语义与阻塞读的静态推断）。
- 多标签串流下"一个请求更新多个标签"的可见行为未运行验证。
- 未对照实际 Provider 响应验证协议映射的细节（模型返回差异、SSE 边界情况）。

## 12. 关键源码索引

| 职责 | 文件 |
| --- | --- |
| 标签和发送编排 | `frontend/app.js:86-123` |
| 输入收集 | `frontend/components/input-bar.js:169-184` |
| 请求对象构造 | `frontend/services/provider-api.js:4-13` |
| 聊天 handler 与广播 | `MainWindow.xaml.cpp:757-850` |
| HTTP 流式传输 | `Manifold.Core/Providers/HttpClient.cpp:93-155` |
| 请求体映射 | `Manifold.Core/Providers/OpenAIProvider.cpp:20-86`、`GeminiProvider.cpp:16-88` |
