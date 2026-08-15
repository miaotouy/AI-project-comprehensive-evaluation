# Manifold Desktop 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-12
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

执行层确认的缺口：assistant 流式回复只进 DOM 不进 `messages[]`（第二次发送缺少上一轮 assistant 上下文，数据语义见会话与消息管理笔记）；`CHAT_CHUNK`/`CHAT_DONE` 广播没有会话标识；主进程只有一个 `m_chatThread`（`MainWindow.xaml.h:54`），常规聊天全局串行。本次调查还确认：前端发送的 `temperature` 与 `tools` 字段在后端不消费；MCP 工具只注入不执行。

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

- **入口**：`input-bar.js:169-184` 读取输入文本并清空 textarea；`app.js:86-123` 的 `onSend` 回调把用户消息加入当前标签的 `messages[]`（`chat-tab.js:119-126`），再经 `providerApi.sendChat` 发送 `CHAT_SEND`（`provider-api.js:4-13`）。
- **任务对象**：`HandleChatSend` 从 payload 读取 `provider/model/messages/systemPrompt`（`MainWindow.xaml.cpp:759-762`），构造 `ChatRequest`（`:771-783`）。没有显式任务 ID——任务身份隐含在全局 `m_chatThread` 与无标识的广播事件中。
- **状态机**：未发现任务级状态机或占位消息；用户消息同步进入 `messages[]`，前端 `streaming` 标志是组件/输入栏局部布尔（`chat-tab.js:19,31`、`input-bar.js:10,22-30`），`appStreaming` 是应用级布尔（`app.js:21,111,132-135`）。

## 2. 历史选择与上下文拼装顺序

- **历史选择**：`chat-tab.js:127-129` 的 `getMessages()` 返回当前标签整个 `messages[]` 的 `role`/`content` 副本；没有按 token、分支或角色再筛选历史的逻辑。
- **顺序与 prompt 来源**：上下文顺序即数组顺序；system prompt 由 `app.js:120` 从设置取值随请求发送，后端在 payload 缺省时回退 `m_currentSettings.systemPrompt`（`MainWindow.xaml.cpp:762`）。assistant 流式文本只更新 DOM 与 `streamingText`（`chat-tab.js:27-59`），不回写 `messages[]`，因此第二轮消息不含上一轮 assistant（该数据缺口在会话与消息管理笔记）。

## 3. 预算、截断、摘要与压缩

发送前未找到上下文截断、摘要压缩或 token 预算处理（检查范围：发送链 `input-bar.js/app.js/provider-api.js`、`HandleChatSend`、`ChatRequest` 定义）。输入栏的 `~N tokens` 估算仅按字符数/4 显示（`input-bar.js:84-87`），不参与请求构造。

## 4. SDK、Provider、模型与协议交接

- **Provider 解析**：`HandleChatSend` 经 `ProviderRegistry::GetProvider` 查找，未找到即回 `CHAT_ERROR`（`MainWindow.xaml.cpp:764-768`）；Provider 在窗口构造时注册（Gemini/OpenAI/Anthropic/Proxy/Ollama/OpenAI-compat，`:129-155`）。
- **参数交接（多个前端字段在后端不消费）**：
  - `req.temperature` 取 `m_currentSettings.temperature`（`MainWindow.xaml.cpp:775`），前端 payload 中的 `temperature` 字段无人读取——前端发送值不生效（settings-store 的前端副本才是实际参数来源）；
  - `req.tools` 只来自 MCP 注入（`:786-789`），前端 `tools` 字段（`provider-api.js:11`）同样无人消费；
  - 设置里的 `streamResponses` 开关在发送路径无读取点（grep 仅命中 settings-store/settings-panel/SettingsManager），界面开关不改变行为。
- **协议映射**：OpenAI 系 `BuildRequestBody` 把 system prompt 作为首条 system 消息、role 直传、parts 转内容数组、工具转 function schema（`OpenAIProvider.cpp:20-86`）；Gemini `BuildRequestBody` 把 role 映射 `assistant→model`、system prompt 放 `systemInstruction`、温度放 `generationConfig`、工具转 `functionDeclarations`（`GeminiProvider.cpp:16-88`）。网络层统一走 `HttpClient::StreamPost`（`HttpClient.cpp:93-155`，WinHTTP + SSE 行解析在各 Provider 内）。
- **交接点结论**：请求体在 Provider 内直接构造，不存在独立的 Adapter 层；`ChatMessage.role` 原样进入 OpenAI 系请求，system/assistant 语义差异由各 Provider 自行处理。

## 5. 流式事件、缓冲、节流与顺序

- **链**（MainWindow.xaml.cpp:800-822）：
  1. Provider 线程内 `onChunk` 回调检查 `stop_token`（`:801`）后构造 `chunkData`（`:803-817`，只含 `text`/`toolCall`/`done`）；
  2. `DispatcherQueue.TryEnqueue`（`:819`）→ `PostMessageToWeb("CHAT_CHUNK")`（`:820`）；
  3. `bridge.js:30-40` 分发 → 每个 chat-tab 的全局监听器（`chat-tab.js:27-59`）。
- **缓冲**：SSE 行缓冲在 Provider 层（`OpenAIProvider.cpp:151-203`、`GeminiProvider.cpp:157-181`）；未发现节流或合并逻辑。
- **顺序**：chunk 经同一 dispatcher 队列投递（`:819-821`），静态推断同一请求内顺序保持；未运行验证。
- **串扰风险**：chunk/done 载荷不含 session/tab 标识，所有已打开标签都监听同一广播（`chat-tab.js:27,61,87`）；多标签同时打开时一个请求可能更新多个标签的局部消息区（可见行为未运行验证）。

## 6. 完成、异常、半截流与最终回写

- **完成**：线程正常结束且未被请求停止时发送 `CHAT_DONE`（`MainWindow.xaml.cpp:824-833`，含 tokens 与 finishReason）；前端据此收尾、挂 cost badge 并记录用量（`chat-tab.js:61-85`）。完整流式文本停留在 DOM 与 `streamingText`，不写回 `messages[]` 也不落盘（落盘缺口见会话与消息管理笔记）。
- **异常**：`catch` 回 `CHAT_ERROR`（`MainWindow.xaml.cpp:834-839`）；前端渲染错误行，其 Retry 按钮只删除错误提示、不重发请求（`chat-tab.js:87-98`），工作流见 Chat UI 笔记。
- **半截流**：任何路径都没有把半截文本写入消息数组或文件；停止后 `CHAT_DONE` 不会发送（`:824` 的 `stop_requested` 判断）。

## 7. 停止、重试、续写与重新生成

- **停止**：`CHAT_CANCEL` → `HandleChatCancel`（`MainWindow.xaml.cpp:843-850`）`request_stop()` 后 `m_chatThread = std::jthread{}`。两个静态推断的边界：
  - `stop_token` 只在 onChunk 回调处检查（`:801`），而 `HttpClient::StreamPost` 是阻塞式 `WinHttpQueryDataAvailable/WinHttpReadData` 循环（`HttpClient.cpp:140-149`）——取消不能主动中断已阻塞的读取，只能等下一次回调；
  - `std::jthread` 的赋值会先 `request_stop()` 再 `join()` 旧线程，若旧线程阻塞在读取上，join 会阻塞 UI 线程直到读取返回。
  真实中断效果均需运行验证。
- **新请求先停旧线程**：`HandleChatSend` 在启动新线程前执行同样动作（`MainWindow.xaml.cpp:791-795`），因此连续发送是"停旧 + join + 起新"的串行关系。
- **重试/续写/重新生成**：除无效 Retry 按钮外未发现独立机制（grep 检查范围：chat-tab.js、app.js、MainWindow 聊天 handler）；再次发送就是重走同一主链，起始上下文仍是当前 `messages[]`。

## 8. 队列、多会话并发与后台生成

- 常规聊天只有一条全局 `m_chatThread`（`MainWindow.xaml.h:54`），没有发送队列、每会话隔离或后台生成机制；不同标签的聊天请求也互相覆盖（见第 7 节）。
- compare 标签使用独立的 `m_compareThreads` 向量、每槽位一线程（`MainWindow.xaml.h:55`、`MainWindow.xaml.cpp:1063-1125`），与 chat 线程并存；compare 请求不注入 MCP 工具，且其广播（`COMPARE_CHUNK` 等）带 `slotIndex` 标识，与 chat 广播不同源。

## 9. Agent、工具、知识库与附件注入点

- **MCP 工具（只注入、不执行）**：
  - 注入：请求构造时 `m_mcpClient.GetAllTools()` 全局注入（`MainWindow.xaml.cpp:786-789`），工具 schema 进入请求体（`OpenAIProvider.cpp:74-83`、`GeminiProvider.cpp:79-85`）；
  - 展示：模型返回的 `toolCall` chunk 只渲染为可折叠卡片（`chat-tab.js:47-49`、`message-renderer.js:36-56`）；
  - 无执行证据：全仓库搜索确认 `MCPClient::CallTool`（`MCPClient.cpp:131`）与 `ChatRequest.maxToolCallRounds`（`ProviderTypes.h:128`）均无调用点/读取点——不存在工具循环。
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
