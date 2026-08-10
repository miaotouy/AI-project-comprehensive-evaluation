# Manifold Desktop 生成式输出与运行时调查笔记

> 调查对象：`../../Manifold-Desktop`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：grep/glob 关键词检索（webview、iframe、artifact、canvas、sandbox、execution、runtime、preview、generated 等），通读前端全部业务 JS、C++ 宿主消息桥接、Provider 与 SessionManager 实现；静态代码分析，未构建、未运行
>
> 调查范围：模型输出的对象模型、触发与流式链路、投影表面、执行环境、编辑、持久化、模型回流与生命周期；终端、MCP 工具注册、插件系统仅记录与本类目的交接点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 是接入真实模型推理的多 Provider 聊天客户端（C++/WinUI3 宿主 + WebView2 单页面前端），模型输出以 SSE 流式文本逐 token 进入消息 DOM，用 marked.js 渲染为 Markdown 内联 HTML。**本次未找到任何"输出对象"机制**：输出没有独立 ID、类型、状态或生命周期，没有专用预览/编辑器/画布/沙箱/执行环境，没有输出级持久化，也没有模型可查询可修改的对象层。主链路在"保存"环节断开——前端存在 `session-store.js` 但为死代码，没有任何调用方，聊天消息（含助手回复）从不落盘；同时助手流式文本不进入会话消息数组，无法回流到下一轮请求。能力等级评定为 **G0（格式化回复）**，仅在会话层面有 Markdown 导出与代码块复制按钮等 G1 碎片。工具调用（MCP）只被展示、从不执行，与 `docs/architecture.md:172` 的描述不一致。

## 系统边界与完整主链路

系统为两层：`MainWindow.xaml.cpp` 的 C++ 宿主（Provider 注册、HTTP 流式、会话/设置/凭证存储、ConPTY 终端、MCP 客户端、DLL 插件）与 `frontend/` 的 WebView2 前端（无框架 ES6 模块）。两层经 JSON 消息桥通信（`frontend/services/bridge.js:4-8` → `MainWindow::OnWebMessage`，`MainWindow.xaml.cpp:404-454`；宿主回传 `MainWindow::PostMessageToWeb`，`MainWindow.xaml.cpp:456-462`）。前端仅一个页面 `frontend/index.html`，经虚拟主机映射加载（`m_webView3->SetVirtualHostNameToFolderMapping(L"manifold.local", ...)`，`MainWindow.xaml.cpp:275-281`）。

**主链路（按代码可走的路径）**：

1. 触发：输入框 Enter → `doSend`（`frontend/components/input-bar.js:169-184`）→ `app.js:86-123` 的 `onSend` → `providerApi.sendChat` → `bridge.send('CHAT_SEND', ...)`（`frontend/services/provider-api.js:4-13`）。
2. 生成：`HandleChatSend`（`MainWindow.xaml.cpp:757-841`）构造 `ChatRequest`，在 `std::jthread` 上调用 `provider->StreamChat(req, onChunk)`；Provider 层做 SSE 解析（如 `Manifold.Core/Providers/OpenAIProvider.cpp:137-218`），每段文本经 `PostMessageToWeb("CHAT_CHUNK", ...)` 回传。
3. 展示：`chat-tab.js:27-59` 的 `CHAT_CHUNK` 监听器把文本追加到 `streamingText`，`streamingEl.innerHTML = renderMarkdownSafe(streamingText)` 每次整段重渲染；`done` 后定格，`CHAT_DONE`（`chat-tab.js:61-85`）附加 token/费用徽标。
4. 交互：代码块复制按钮（`message-renderer.js:20-31`）；错误条上的 Retry 按钮只移除错误元素，不重发（`chat-tab.js:92-95`）。
5. 保存：**无**——全前端没有任何对 `session-store.js` 的导入（grep `session-store` 无结果），助手回复也未写入 `messages` 数组，不存在落盘路径。
6. 重新打开：`chat-tab.js:100-114` 可经 `LOAD_SESSION` → `SESSION_DATA` 渲染已存在会话文件（`SESSION_DATA` 处理见 `session-store.js:91-95` 与 `MainWindow.xaml.cpp:521-526`），但本快照中没有任何写路径把消息写进会话文件，故"保存→重新打开"闭环无法成立（会话文件若由外部/旧版本产生则可展示）。

以上链路均为静态代码推断；本次未构建未运行，行为未做运行验证。

## 1. 触发方式、输出协议与对象模型

- **触发**：唯一触发是用户文本输入（`input-bar.js`）。模型自由文本回复，无特殊标记、无 typed part、无输出协议层；会话内的 markdown 只是渲染层效果（`message-renderer.js:80-105`）。
- **输出协议**：`StreamChunk{ text, done, toolCall }`（`Manifold.Core/Providers/ProviderTypes.h:131-135`），`ChatResponse{ text, toolCalls, promptTokens, completionTokens, finishReason }`（同文件 137-143）。桥接层把 chunk 原样转发（`MainWindow.xaml.cpp:803-817`），对半截流/转义/嵌套无协议处理——Markdown 半截状态直接交给 marked 解析，异常时静默回退转义文本（`chat-tab.js:140-145`）。
- **对象模型**：**未找到**。会话内的消息仅为 `{role, text, parts, timestamp}` 普通对象（`session-store.js:20-27`），无稳定 ID、无类型、无版本、无能力声明。会话本身有 id（`session-store.js:14-16`），但会话 ID 只在未使用的 `session-store.js` 中出现，chat-tab 的 `sessionId` 仅用于加载展示。事实源不明：内存 `messages` 数组（chat-tab 闭包）与磁盘 JSON 谁是谁的事实源无机制保证，且两者目前互不写入。

## 2. 增量生成、更新与最终化

- **粒度**：逐 token 文本追加 + 每次全量重渲染 Markdown（`chat-tab.js:42-45`）。Compare 模式同样按 slot 追加文本（`compare-tab.js:43-56`）。无 AST 节点更新、无 diff/patch。
- **最终化**：`chunk.done` 定格显示（`chat-tab.js:51-56`），`CHAT_DONE` 补充 token/费用徽标并记录用量（`chat-tab.js:64-82`）。失败经 `CHAT_ERROR` 显示错误条（`chat-tab.js:87-98`），Retry 按钮仅关闭错误条，不重发请求。
- **收口缺口（静态推断）**：助手流式文本从未 `messages.push(...)`（`chat-tab.js:42-56` 只写 `streamingText` 与 DOM），`getMessages()`（`chat-tab.js:127-129`）返回的数组不含上一轮助手回复，下一轮 `CHAT_SEND` 将缺少该内容。

## 3. 投影表面与多视图关系

- **唯一投影**：消息正文内联 DOM（`chat-tab.js` / `compare-tab.js`）。无侧栏、画布、独立窗口、外部浏览器投影；无多视图同步问题——因为只有一份 DOM。
- **横向**：Compare 模式是两个模型回复并排展示（`compare-tab.js:13-38`），属并行生成展示，不共享输出对象。
- **多标签问题（静态推断）**：`bridge.on('CHAT_CHUNK')` 按事件名全局分发，不按 sessionId 过滤，多个打开的 chat 标签会同时渲染同一份流式内容（`chat-tab.js:27` 与 `bridge.js:30-40`）。终端标签按 `tabId` 过滤（`terminal-tab.js:32`），对比模式按 `slotIndex` 分发（`compare-tab.js:44`）。

## 4. 表现类型、依赖与运行环境

- **表现层级**：仅 Markdown + 代码高亮（vendor `marked.min.js` / `highlight.min.js`，`message-renderer.js:80-105`）。无图表、无媒体对象、无声明式组件、无 HTML/JS 运行层。
- **运行环境**：**未找到**。全前端 grep `iframe|sandbox|canvas|artifact|WebGL|Worker` 仅命中 vendor 库内部词条；`index.html` 无 CSP、无子页面。模型输出不进入任何独立运行环境，全部内联进宿主页面 DOM；`renderMarkdownSafe` 直接 `innerHTML` 注入（`chat-tab.js:44`），未见消毒层（静态观察）。
- **交接点**：应用存在用户驱动的 ConPTY 终端（`MainWindow.xaml.cpp:918-965`，前端 `terminal-tab.js`）与 DLL 插件可注册的虚拟主机（`RegisterVirtualHost`，`MainWindow.xaml.cpp:334-341`），但两者均无模型输出接入路径，属本类目之外的能力。

## 5. 用户交互、事件与错误反馈

- 代码块复制（`message-renderer.js:20-31`）、工具调用折叠块（`message-renderer.js:36-56`，点击展开 JSON 参数/结果）、错误条（`chat-tab.js:87-98`）、取消按钮（`input-bar.js:99-106` → `CHAT_CANCEL`，`MainWindow.xaml.cpp:843-850`）。
- 事件回传方向为单向推送（宿主 → 前端），无组件事件从渲染层回到对象层；无日志、无运行状态机。
- 重载恢复：无（消息不持久化，前端会话内状态仅存于标签页闭包，关标签即丢）。

## 6. 编辑、diff、版本与协作

**未找到**。模型输出无编辑入口（唯一"编辑"是会话标题重命名，`side-panel.js:84-105`）。无 diff、无版本、无接受/拒绝、无协作。`message-renderer.js` 对已渲染消息无任何修改路径；会话内容不可在 UI 中修改。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：模型生成与 SSE 解析在 C++ 宿主线程（`std::jthread`，`MainWindow.xaml.cpp:798`）；渲染在 WebView2 主页面 DOM；无 iframe、无 worker、无沙箱、无远端代码执行。
- **能力桥**：桥接口 `MainWindow::OnWebMessage`（`MainWindow.xaml.cpp:404-454`）是普通消息分发表，不是输出对象能力桥。前端可请求的宿主动作均为聊天/设置/会话/终端/MCP/导出等全局能力，与具体输出无关；前端可访问 `window.chrome.webview.postMessage` 且宿主对消息无来源校验（静态观察）。
- **工具执行**：MCP 工具定义注入 `ChatRequest::tools`（`MainWindow.xaml.cpp:786-789`），Provider 解析出 `toolCall` 后仅以 chunk 转发展示。**`MCPClient::CallTool`（`Manifold.Core/MCP/MCPClient.cpp:131`）全仓无调用方**（grep `CallTool` 仅命中其定义处），`maxToolCallRounds`（`ProviderTypes.h:128`）从未使用。这与 `docs/architecture.md:172` 声称的"backend executes it via MCPClient::CallTool … re-sends to the provider"不一致，以当前代码为据：工具调用只展示不执行。

## 8. 持久化、恢复、分享与导出

- **会话存储设施存在但未接入**：`SessionManager` 以 `%LOCALAPPDATA%\Manifold\sessions\<id>.json` 存整个会话 JSON（`Manifold.Core/SessionManager.cpp:24-51`），桥接有 `SAVE_SESSION/LOAD_SESSION/DELETE_SESSION/SEARCH_SESSIONS`（`MainWindow.xaml.cpp:508-557`）。但前端唯一调用 `SAVE_SESSION` 的路径是标题重命名（`side-panel.js:98`），且其发送的 `data` 仅含 `{title}`——而 `HandleSaveSession` 会用该 `data` 整体覆盖会话文件（`MainWindow.xaml.cpp:528-534` → `SessionManager.cpp:29-36`），静态推断重命名会话会清空其消息内容。`session-store.js`（含 `createSession/addMessage/updateModelMessage`）无任何导入方，为死代码。
- **导出/导入**：会话级 Markdown 导出已接线（`side-panel.js:136` → `HandleExportMarkdown`，`MainWindow.xaml.cpp:679-722`）；JSON 导入已接线（`home-tab.js:88` → `HandleImportSession`，`MainWindow.xaml.cpp:648-677`）；JSON 导出 handler 存在（`HandleExportSession`，`MainWindow.xaml.cpp:619-646`）但前端无调用方。均为会话整体导出，无输出对象级导出。
- **恢复**：`LOAD_SESSION → SESSION_DATA → renderMessage` 可展示磁盘上已存在的会话（`chat-tab.js:100-114`），但这只在会话文件由外部生成时才可观测（本快照内部无写路径）。

## 9. 模型回流、对象感知与持续维护

**未找到对象级回流**。模型不可查询输出列表、不可读取输出源码、不可观察运行状态。唯一进入模型上下文的途径是前端把 `messages` 数组随 `CHAT_SEND` 重发（`app.js:96-121`），而如前所述，该数组不含已生成的助手回复（`chat-tab.js:127-129`），因此同一会话内模型也无法延续自己的上一轮输出（静态推断）。会话对象身份绑定不存在——每次聊天都从空数组起步，无"定位既有对象继续修改"机制。

## 10. 生命周期、资源治理与性能

- 输出无独立生命周期（随 DOM 消息节点存在）。宿主侧可取消聊天线程（`HandleChatCancel`，`MainWindow.xaml.cpp:843-850`，`std::stop_token`）；compare 线程组整体取消（`MainWindow.xaml.cpp:1127-1134`）。窗口关闭时回收终端进程、插件、MCP 连接与 WebView（`MainWindow.xaml.cpp:179-192`）。
- 终端进程按 `m_terminals` 登记并在关闭时 `Stop()`（`MainWindow.xaml.h:64`，`MainWindow.xaml.cpp:181-185`）。无输出对象相关暂停/冻结/限额机制（因无对象）。WebView 用户数据目录固定为 `%LOCALAPPDATA%\Manifold\webview2`（`MainWindow.xaml.cpp:203-208`）。

## 11. 测试、已确认边界与未验证事项

- **测试**：本次按仓库分布调查结论，仓库无显式测试树；本类目亦未发现针对协议/渲染/持久化的测试文件。
- **已确认边界**（搜索范围：全仓 `*.{js,html}` 与 `*.{cpp,h,idl,xaml}` 关键词检索，前端业务代码全部通读）：
  - 无输出对象模型、无 artifact/canvas/iframe/沙箱/专用运行环境；
  - 消息不落盘（`session-store.js` 死代码，无 SAVE_SESSION 写入消息）；
  - 工具调用不执行（`CallTool` 无调用方）；
  - 助手回复不入 `messages` 数组（不回流）。
- **文档与实现不一致**：`docs/architecture.md:172` 声称工具调用会被执行并回流重发；README 与 architecture.md 声称会话 save/load 为已实现功能。两者与当前代码路径不符（见 §7、§8）。
- **未验证事项**：本笔记全程静态分析，未构建、未运行。流式渲染的视觉行为、取消语义、Compare 并行、重命名覆盖会话文件的行为、多标签重复渲染、WebView2 实际权限表现均需运行验证。

## 12. 关键源码索引

- `frontend/components/chat-tab.js:27-59,61-85,100-133`：流式渲染与消息数组（输出展示与回流的关键缺口）
- `frontend/components/message-renderer.js:1-105`：Markdown/代码块/工具块渲染
- `frontend/services/session-store.js:18-62`：未接入的会话持久化模块
- `frontend/services/bridge.js:4-41`：JSON 消息桥
- `MainWindow.xaml.cpp:404-454,757-841`：桥分发与聊天流式链路
- `MainWindow.xaml.cpp:528-534`：`HandleSaveSession`（整体覆盖）
- `Manifold.Core/Providers/ProviderTypes.h:120-143`：请求/流式协议
- `Manifold.Core/Providers/OpenAIProvider.cpp:137-218`：SSE 解析与工具调用片段累积
- `Manifold.Core/MCP/MCPClient.cpp:131`：`CallTool`（无调用方）
- `Manifold.Core/SessionManager.cpp:24-96`：会话 JSON 存储设施
- `docs/architecture.md:157-172`：与实现不一致的文档描述
