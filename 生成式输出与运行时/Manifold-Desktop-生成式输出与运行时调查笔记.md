# Manifold Desktop 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/gregorik/Manifold-Desktop`
>
> 调查更新日期：2026-11-05
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

系统由 C++ 宿主与 WebView2 前端两部分组成。宿主主窗口负责 Provider 注册、HTTP 流式、会话/设置/凭证存储，并管理 ConPTY 终端、MCP 客户端与 DLL 插件；前端位于 frontend 目录，是不使用框架的 ES6 模块。两层通过 JSON 消息桥双向通信，前端侧的桥接口在 `frontend/services/bridge.js:4-8`，宿主侧接收消息并回推，桥接实现与页面映射见 `MainWindow.xaml.cpp:275-281,404-462`。前端只有一个页面 `frontend/index.html`，经虚拟主机映射以 manifold.local 加载。

**主链路（按代码可走的路径）**：

1. 触发：用户在输入框按 Enter 后，前端输入组件经应用入口转调 provider 接口，向宿主发出 `CHAT_SEND` 桥消息。触发链上的输入、应用与接口三层入口依次见 `frontend/components/input-bar.js:169-184`、`frontend/app.js:86-123`、`frontend/services/provider-api.js:4-13`。
2. 生成：宿主收到桥消息后由 `HandleChatSend` 构造请求对象，在独立线程上调用 provider 的 `StreamChat`，按块回调；Provider 层负责 SSE 解析，每段文本再以 `CHAT_CHUNK` 消息回传给前端。请求构造与 SSE 解析分别见 `MainWindow.xaml.cpp:757-841` 和 `Manifold.Core/Providers/OpenAIProvider.cpp:137-218`。
3. 展示：前端在 `chat-tab.js` 里监听 `CHAT_CHUNK`，把文本追加到流式缓冲，每收到一段就整段重渲染 Markdown；`done` 到达后显示定格，`CHAT_DONE` 事件再补上 token 与费用徽标。流式监听与结束处理位于 `chat-tab.js:27-85`。
4. 交互：代码块带复制按钮；错误条上的 Retry 按钮只移除错误元素，不重发请求。两者分别见 `message-renderer.js:20-31` 与 `chat-tab.js:92-95`。
5. 保存：**无**。全前端没有任何模块导入 `session-store.js`（grep `session-store` 无结果），助手回复也没有写入 `messages` 数组，因此不存在落盘路径。
6. 重新打开：加载入口在 `chat-tab.js:100-114`，前端经 `LOAD_SESSION` 得到 `SESSION_DATA` 后渲染磁盘上已存在的会话文件，该消息的处理与宿主侧响应见 `session-store.js:91-95`、`MainWindow.xaml.cpp:521-526`；本快照中没有任何写路径把消息写进会话文件，因此"保存→重新打开"闭环无法成立（会话文件若由外部/旧版本产生则可展示）。

以上链路均为静态代码推断；本次未构建未运行，行为未做运行验证。

## 1. 触发方式、输出协议与对象模型

- **触发**：唯一触发是用户文本输入（`input-bar.js`）。模型自由文本回复，无特殊标记、无 typed part、无输出协议层；会话内的 markdown 只是渲染层效果（`message-renderer.js:80-105`）。
- **输出协议**：chunk 与最终响应结构（`Manifold.Core/Providers/ProviderTypes.h:131-143`）：

  ```cpp
  StreamChunk{ text, done, toolCall }
  ChatResponse{ text, toolCalls, promptTokens, completionTokens, finishReason }
  ```

  桥接层把 chunk 原样转发给前端，对半截流、转义和嵌套结构都没有协议处理；Markdown 的半截状态直接交给 marked 解析，解析异常时静默回退为转义文本。转发与回退分别见 `MainWindow.xaml.cpp:803-817` 和 `chat-tab.js:140-145`。
- **对象模型**：**未找到**。会话内的消息仅为普通对象（`session-store.js:20-27`），字段仅 role/text/parts/timestamp，无稳定 ID、无类型、无版本、无能力声明。会话本身有 id（`session-store.js:14-16`），但会话 ID 只在未使用的 `session-store.js` 中出现，chat-tab 的 `sessionId` 仅用于加载展示。事实源不明：内存 messages 数组（chat-tab 闭包）与磁盘 JSON 谁是谁的事实源无机制保证，且两者目前互不写入。

## 2. 增量生成、更新与最终化

- **粒度**：前端按 token 追加文本，每收到一段就整段重渲染 Markdown，没有 AST 节点更新，也没有 diff/patch；Compare 模式同样按 slot 追加文本。渲染见 `chat-tab.js:42-45`，Compare 侧见 `compare-tab.js:43-56`。
- **最终化**：`done` 标记到达后显示定格，`CHAT_DONE` 事件补上 token 与费用徽标并记录用量；失败时由 `CHAT_ERROR` 事件显示错误条，Retry 按钮只关闭错误条，不重发请求。这一组处理都在 `chat-tab.js:51-98`。
- **收口缺口（静态推断）**：助手流式文本只写进流式缓冲与 DOM，从不追加到消息数组，`getMessages()` 返回的数组因此不含上一轮助手回复，下一轮 `CHAT_SEND` 会缺少这段内容。流式写入与 `getMessages()` 的实现见 `chat-tab.js:42-56,127-129`。

## 3. 投影表面与多视图关系

- **唯一投影**：模型输出只投影为消息正文里的内联 DOM，由 `chat-tab.js` 与 `compare-tab.js` 渲染；没有侧栏、画布、独立窗口或外部浏览器视图，只有一份 DOM，也不涉及多视图同步。
- **横向**：Compare 模式把两个模型的回复并排展示，属并行生成展示，两份回复不共享输出对象（`compare-tab.js:13-38`）。
- **多标签问题（静态推断）**：`CHAT_CHUNK` 事件按事件名全局分发，不经会话 ID 过滤，多个打开的 chat 标签会同时渲染同一份流式内容。对照实现里，终端标签按标签 ID 过滤、Compare 模式按槽位分发，两者都做了区分。分发与对照分别见 `chat-tab.js:27`、`bridge.js:30-40`、`terminal-tab.js:32`、`compare-tab.js:44`。

## 4. 表现类型、依赖与运行环境

- **表现层级**：输出只经 Markdown 与代码高亮两级呈现，分别由 vendor 目录下的 `marked.min.js` 和 `highlight.min.js` 完成；没有图表、媒体对象、声明式组件或 HTML/JS 运行层。渲染入口见 `message-renderer.js:80-105`。
- **运行环境**：**未找到**。在全前端检索 iframe、sandbox、canvas、artifact、WebGL、Worker 等关键词，只命中 vendor 库内部词条；`index.html` 既没有 CSP 也没有子页面。模型输出全部内联进宿主页面 DOM，不经任何独立运行环境；`renderMarkdownSafe` 直接以 `innerHTML` 注入渲染结果，未见消毒层（静态观察）。注入位置见 `chat-tab.js:44`。
- **交接点**：应用提供用户驱动的 ConPTY 终端，由前端 `terminal-tab.js` 对接；DLL 插件也能通过 `RegisterVirtualHost` 注册虚拟主机。两者都没有接入模型输出的路径，属本类目之外的能力（`MainWindow.xaml.cpp:334-341,918-965`）。

## 5. 用户交互、事件与错误反馈

- 面向用户的输出交互集中在四处：

| 交互点 | 行为 | 实现位置 |
| --- | --- | --- |
| 代码块复制 | 每个代码块提供复制按钮 | `message-renderer.js:20-31` |
| 工具调用折叠块 | 点击展开 JSON 参数与结果 | `message-renderer.js:36-56` |
| 错误条 | 失败时在消息区显示错误提示 | `chat-tab.js:87-98` |
| 取消按钮 | 点击发出 `CHAT_CANCEL`，由宿主取消当前聊天 | `input-bar.js:99-106`、`MainWindow.xaml.cpp:843-850` |

- 事件回传方向为单向推送（宿主 → 前端），无组件事件从渲染层回到对象层；无日志、无运行状态机。
- 重载恢复：无（消息不持久化，前端会话内状态仅存于标签页闭包，关标签即丢）。

## 6. 编辑、diff、版本与协作

**未找到**。模型输出无编辑入口（唯一"编辑"是会话标题重命名，`side-panel.js:84-105`）。无 diff、无版本、无接受/拒绝、无协作。`message-renderer.js` 对已渲染消息无任何修改路径；会话内容不可在 UI 中修改。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：模型生成与 SSE 解析运行在 C++ 宿主的后台线程上，渲染发生在 WebView2 主页面 DOM；没有 iframe、worker、沙箱，也没有远端代码执行。后台线程的创建见 `MainWindow.xaml.cpp:798`。
- **能力桥**：宿主把桥接实现为一层普通的消息分发表，入口是 `OnWebMessage`，按消息类型路由，不承载输出对象级能力。前端能请求的宿主动作都是聊天、设置、会话、终端、MCP、导出等全局能力，与具体某次输出无关；前端也可以直接调用 `window.chrome.webview.postMessage`，宿主对消息来源不做校验（静态观察）。分发入口见 `MainWindow.xaml.cpp:404-454`。
- **工具执行**：宿主把 MCP 工具定义随请求注入，Provider 解析出工具调用片段后只作为 chunk 转发展示，从不执行调用；执行方法 `CallTool` 在全仓没有调用方（grep 只命中定义处），多轮工具调用的轮次上限也从未被使用。相关位置见请求结构 `Manifold.Core/Providers/ProviderTypes.h:128`、执行方法定义处 `Manifold.Core/MCP/MCPClient.cpp:131`、工具注入处 `MainWindow.xaml.cpp:786-789`。文档 `docs/architecture.md:172` 声称工具调用会在后端执行并回流重发，与当前代码路径不符；以当前代码为据，工具调用只展示、不执行。

## 8. 持久化、恢复、分享与导出

- **会话存储设施存在但未接入**：`SessionManager` 以 `%LOCALAPPDATA%\Manifold\sessions\<id>.json` 存整个会话 JSON（`Manifold.Core/SessionManager.cpp:24-51`），桥接提供四条会话命令（`MainWindow.xaml.cpp:508-557`）：

  ```text
  SAVE_SESSION / LOAD_SESSION / DELETE_SESSION / SEARCH_SESSIONS
  ```
- **重命名覆盖问题（静态推断）**：前端唯一的 `SAVE_SESSION` 调用来自标题重命名，它发送的数据只含标题字段，宿主的保存处理会用这份数据整体覆盖会话文件，静态推断重命名会话会清空其消息内容。调用点与覆盖路径见 `side-panel.js:98`、`MainWindow.xaml.cpp:528-534`、`Manifold.Core/SessionManager.cpp:29-36`。
- **死代码**：会话持久化模块 `session-store.js` 提供 `createSession`、`addMessage`、`updateModelMessage` 等写入接口，全前端没有任何模块导入它。
- **导出/导入**：三项操作都作用于整个会话文件，没有输出对象级导出：

| 操作 | 接线情况 | 实现位置 |
| --- | --- | --- |
| Markdown 导出 | 前端已接线 | `side-panel.js:136` → `HandleExportMarkdown`（`MainWindow.xaml.cpp:679-722`） |
| JSON 导入 | 前端已接线 | `home-tab.js:88` → `HandleImportSession`（`MainWindow.xaml.cpp:648-677`） |
| JSON 导出 | handler 已实现，前端无调用方 | `HandleExportSession`（`MainWindow.xaml.cpp:619-646`） |

- **恢复**：`LOAD_SESSION → SESSION_DATA → renderMessage` 这条路径能把磁盘上已有的会话渲染出来，磁盘文件也可以由应用导入或重命名路径产生；正常聊天流程没有保存调用。加载见 `chat-tab.js:100-114`，宿主侧见 `MainWindow.xaml.cpp:528-534,648-677`。

## 9. 模型回流、对象感知与持续维护

**对象级回流**：已检查聊天消息数组、发送入口与流式结束处理，未找到独立输出列表、输出源码读取或运行状态查询。新标签从空数组开始，随后用户消息持续累积；加载已有磁盘会话时会装入其中的历史消息。新生成的 assistant 回复只更新 DOM，没有追加进数组，因此下一轮保留用户历史、缺少本次生成的助手回复。见 `frontend/components/chat-tab.js:22-59,61-85,100-128`、`frontend/app.js:109-122`。

## 10. 生命周期、资源治理与性能

- 输出没有独立生命周期，随 DOM 消息节点存在。宿主可以取消正在进行的聊天线程（`HandleChatCancel` 配合 `std::stop_token`）和 Compare 的线程组，窗口关闭时统一回收终端进程、插件、MCP 连接与 WebView。取消与回收的实现见 `MainWindow.xaml.cpp:179-192,843-850,1127-1134`。
- 终端进程登记在 `m_terminals` 中，关闭窗口时停止；输出对象层面没有暂停、冻结或限额机制，因为不存在这样的对象。WebView 用户数据目录固定为 `%LOCALAPPDATA%\Manifold\webview2`。终端登记与用户数据目录见 `MainWindow.xaml.h:64`、`MainWindow.xaml.cpp:181-185,203-208`。

## 11. 测试、已确认边界与未验证事项

- **测试**：按仓库目录分布看，仓库没有显式测试树；本类目也没有找到针对协议、渲染与持久化的测试文件。
- **已确认边界**（检索范围：全仓 `*.{js,html}` 与 `*.{cpp,h,idl,xaml}` 文件，关键词检索并通读全部前端业务代码）：
  - 输出对象模型与 artifact、canvas、iframe、沙箱、专用运行环境均不存在；
  - 消息不落盘：会话写入模块 `session-store.js` 为死代码，前端也没有把消息写进 SAVE_SESSION 的调用；
  - 工具调用不执行：`CallTool` 没有调用方；
  - 助手回复不进入 `messages` 数组，因而无法回流。
- **文档与实现不一致**：`docs/architecture.md:172` 声称工具调用会被执行并回流重发，README 与 architecture.md 也把会话 save/load 描述为已实现功能；当前代码路径与之不符（见 §7、§8）。
- **未验证事项**：本笔记全程静态分析，未构建、未运行。以下行为需在运行中观察：流式渲染的视觉效果、取消语义、Compare 并行生成、重命名覆盖会话文件、多标签重复渲染，以及 WebView2 的实际权限表现。

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
