# VCPChat 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：静态代码走读。grep/glob 检索 artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、runtime、exec、preview、tool、message、markdown、highlight 等关键词；通读消息渲染管线（messageRenderer / contentPipeline / streamManager / contentProcessor）、阅读窗口（text-viewer）、Canvas 协同编辑器、桌面挂件与收藏链路、聊天历史持久化链路，以及 Scriptorium 文坊子系统（ScriptoriumModules + docxHandlers + ScriptoriumCollaborator 插件）。未运行应用、未发起真实模型请求。
>
> 调查范围：生成式输出与运行时类目全部必查问题；覆盖消息内嵌运行组件、独立阅读窗口、桌面画布挂件、Canvas 文件工作区、Scriptorium 文档工程、持久化与回流。排除：聊天上下文装配与发送细节（Chat 类目）、工具注册与执行调度（Agent 工具类目）、消息渲染器通用 Markdown/高亮/KaTeX 细节（仅在获得运行生命周期处记录交点）、音频引擎与 TTS、VCPHumanToolBox 工作流编辑器与 ComfyUI（独立人工工具，非模型生成对象）、Loom 应用运行器（第三方应用托管，非模型输出）。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 的"生成式输出"没有独立的 Artifact 对象模型。模型产出全部是消息正文内的原始文本流，通过私有标记协议（工具请求、桌面推送、日记、思维链等文本围栏）表达结构化块，由渲染器转为宿主渲染的声明式卡片（工具结果卡、思维链卡、日记卡、桌面推送占位卡）。事实源是 `AppData/UserData/<agent>/topics/<topic>/history.json` 中的原始 Markdown 文本，DOM 每次重新解析派生，无独立对象 ID/状态/版本层。

**例外：Scriptorium 共笔文坊**是仓库里第一套"独立对象模型"的模型协作面——VDOCX/VPPTX 工程（`AppData/ScriptoriumDocument/`）自带文档模型、资源清单与**文脉版本历史**（人类刻点 + Agent PR 以 pending/applied/rejected/conflict/failed 状态进入同一文脉，含 changeSet 与审批回执），Agent 经 `ScriptoriumCollaborator` 插件以"源码 PR + 人工审批"方式修改对象（详见 6.2）。它仍走"唯一完整 source"的文本真相模型（源码即真相，不序列化渲染树），但补上了聊天侧没有的版本/冲突/身份语义。

运行能力覆盖四类执行位置：气泡内 HTML 预览、独立阅读窗口脚本、Python 双模式执行和桌面画布常驻挂件。Canvas 协同窗口除外部文件监听外，现为 Agent 编辑提案提供 requestId、原文快照、差异审阅与显式允许/拒绝；批准时复读文件并检查内容未变化，再用临时文件替换。它仍只保留内存内容历史，没有持久版本号。`modules/ipc/canvasHandlers.js:92-193`、`Canvasmodules/canvas.js:546-645`

增量生成采用"稳定前缀截断 + 整段尾部重渲染 + morphdom 差量合并"，无 AST 级 patch，未在自有代码中找到 diff-match-patch 使用（依赖虽在 package.json）。用户可编辑消息全文、重新生成回复、点击模型生成的按钮回发 `[[点击按钮:...]]`。

综合能力等级判定为 **G3（可执行 Artifact）为主、G4（可编辑工作区）部分成立**：HTML/JS/Python 有真实运行环境且用户可实际操作，桌面挂件有持久化生命周期；但协议是自由文本私有标记、更新粒度是整段/整文件、无结构化版本与冲突语义、模型对对象的维护是"每次重新生成"而非按对象身份定向修改。

## 系统边界与完整主链路

进程/窗口边界分为渲染侧窗口与附属进程两层。

| 窗口 | 载体与说明 |
|---|---|
| 主窗口（聊天 UI） | `main.html`，CSP 见 `main.html:7-13`，脚本源为 `script-src 'self' 'unsafe-inline'` |
| 阅读窗口 | `text-viewer.html` |
| 图片查看窗口 | `image-viewer.html` |
| Canvas 协同窗口 | `Canvasmodules/canvas.html` |
| 桌面窗口（透明置底画布） | `Desktopmodules/desktop.html` |
| 笔记窗口 | `Notemodules/notes.html` |
| Memo 工作台 | `Memomodules/memo.html` |

附属进程按职责分四类：VCPDistributedServer 是本地 Express + WebSocket 服务，承担插件执行；`vcp_chat_data_service.exe` 是 VCP-CDS 影子索引，负责历史消息索引与搜索；`assistant_core_server.exe` 是选区监听 sidecar，由 `modules/assistant/assistant-rust-adapter.js` 接入；`rust_audio_engine` 与 `python` 是音频引擎进程。

完整主链路（源码确认的调用链，未运行验证）：

1. **触发**：用户点击发送后，聊天窗口的发送入口经 IPC 把请求转给主进程（`chatManager.js:1360`），主进程再请求本地 VCP 服务；启用工具注入时改走 `/v1/chatvcp/completions`（`chatHandlers.js:855-1107`）。
2. **生成**：主进程读取 SSE 流并以 `chat.stream.*` 事件回传增量（`chatHandlers.js:1056-1360`）；渲染侧由流管理器消费终态，负责建消息、入队和终态投影（`streamManager.js:1371-1845`）。工具请求由模型以 `<<<[TOOL_REQUEST]>>>` 文本标记输出，交本地插件或远端服务执行，结果以 `[[VCP调用结果信息汇总:...]]` 块拼回消息流。
3. **展示/运行**：流式帧渲染先固化稳定前缀，再重新解析尾部并做 morphdom 差量合并（`streamManager.js:1000`）；终态后按协议块渲染卡片（`messageRenderer.js:2342`）。HTML 代码块获得气泡内 iframe 预览，Python、HTML 与 three.js 块在阅读窗口获得运行按钮（`contentProcessor.js:645`、`text-viewer.js:1563-1713`）。
4. **交互或编辑**：用户可播放、复制或编辑消息，中键与右键菜单提供全文编辑和重新生成（`messageContextMenu.js:128-353`）；点击模型生成的按钮会回发消息（`contentProcessor.js:869`）；流式期间桌面推送标记被 `desktopPushConsumer` 拦截并实时创建挂件，挂件可收藏，也可把源码打开到 Canvas 编辑。
5. **保存**：最终消息文本（含协议标记的原始 Markdown）经历史 IPC 写入 `history.json`，渲染侧由历史持久化模块提交（`chatHandlers.js`）；桌面挂件与 Canvas 文件另由各自处理器落到 `AppData/` 下的 DesktopWidgets/<id> 与 Canvas 目录（`desktopHandlers.js:999`、`canvasHandlers.js:299`）。
6. **重新打开**：切换话题或重启后，消息从 `history.json` 读出并按原始文本重新解析渲染（`messageRenderer.js:3158`）；挂件从收藏恢复（`favoritesManager.js:108`），Canvas 文件列表按 mtime 排序重载（`canvasHandlers.js:399`）。

## 1. 触发方式、输出协议与对象模型

**触发方式**：无独立的"创建输出对象"命令；一切输出是模型自由文本流。能力由模型在回复中输出私有标记触发：

| 标记 | 含义 | 处理点 |
|---|---|---|
| `<<<[TOOL_REQUEST]>>>...<<<[END_TOOL_REQUEST]>>>` | 工具请求块（服务端执行） | `messageRenderer.js:413`、`findToolRequestEnd`（`messageRenderer.js:446`，ESCAPE 感知扫描器） |
| `[[VCP调用结果信息汇总:...VCP调用结果结束]]` | 工具结果块 | `messageRenderer.js:417`、`:2043` |
| `<<<[DESKTOP_PUSH]>>>...<<<[DESKTOP_PUSH_END]>>>` | 桌面挂件推送 | `modules/renderer/desktopPushConsumer.js:6,195`；替换模式 `target:/replace:` 字段 |
| `<<<DailyNoteStart>>>...<<<DailyNoteEnd>>>` | 日记创建/更新 | `messageRenderer.js:416`、`transformSpecialBlocks` |
| `[--- VCP元思考链...---]...元思考链结束`、`<think>` | 思维链 | `contentPipeline.js:218` `protectThoughtChains` |
| `<<<[ROLE_DIVIDE_...]>>>` | 角色分界 | `streamManager.js:963` |
| `{{VCPChatCanvas}}` | Canvas 协同占位 | `messageRenderer.js:1456` |
| `[[点击按钮:文本]]` | 用户点击按钮回发 | `messageRenderer.js:419,1444` |

**协议处理**分三件事：

- **半截流**：流式时只把已闭合的围栏、工具块和段落边界标记为稳定，未闭合块留在尾部待渲染；未闭合的推送块满 150 秒自动收口（`streamManager.js:1088`、`desktopPushConsumer.js:43`）。
- **转义**：反引号包裹的标记不生效，工具参数里用「始ESCAPE」「末ESCAPE」承载字面量结束标记（`streamManager.js:1929-1936`、`messageRenderer.js:328-360`）。
- **误触发防护**：推送内容必须匹配合法前缀白名单，否则整块丢弃；工具气泡内的 `pre` 块禁止转成 HTML 预览（`streamManager.js:2004-2076`、`contentProcessor.js:608-655`）。

**对象模型**：没有统一的输出对象模型，可辨识的对象身份有四种。

- **消息**：以 id、role、原始文本 content 和 timestamp 标识，`history.json` 是事实源，DOM 只是派生投影。
- **桌面挂件**：运行时用 `widgetId`，收藏后以目录名 `savedId` 持久化，`meta.json` 记录 id、名称与创建/更新时间，没有版本字段（`desktopHandlers.js:1015-1031`）。
- **Canvas 文件**：文件路径即身份。
- **Scriptorium 文档工程**：`.vdocx`/`.vpptx` 工程存放在 `AppData/ScriptoriumDocument/`，以 `document.json`、唯一完整 HTML source 和资源清单为对象，文脉刻点与 PR 提供版本和审批语义（见 6.2）。

工具结果卡、思维链卡等无独立 ID，`data-vcp-block-type` 仅用于 DOM 标记与流式保留。推断：无"能力声明/状态机"机制；消息侧对象身份与后续回合的绑定（指南必查 10）没有实现，模型每次重新生成新挂件/新文件；Scriptorium 是唯一带"按对象身份继续修改"通道的面（PR 提交到既有工程）。

## 2. 增量生成、更新与最终化

**流式更新**：采用两段式渲染。稳定前缀按块固化，每个块缓存一份"源码 + 原始 HTML"，切换视图重建 DOM 时直接用缓存恢复；尾部文本每帧重新解析，再做 morphdom 差量合并，已后处理的 mermaid、KaTeX、工具卡、预览容器和高亮子树受保护、不被重建。渲染节流为全局 30fps 的 rAF 循环，预缓冲队列上限 1000 chunks，平滑流式可由 `globalSettings.enableSmoothStreaming` 关闭。实现见 `streamManager.js:537-1765`。

**最终化**：终态投影（streamManager.js:1845-2079）移除流式根节点，对完整文本执行最终处理（前端正则规则与深度计算，`messageRenderer` 全量渲染）后重新全量渲染；流中断时拼接 `> [!WARNING]` 提示并保存已接收部分（renderer.js:601-627）。主进程与渲染器以累积文本与最终响应的更长者/含恢复标记者保持一致（streamManager.js:1901-1910）。

**非流式工具结果**：工具结果块由服务端一次性拼接，不做逐 token 注入（`streamManager.js:1726-1729` 注释明确说明）。**未找到** AST 级节点 patch、diff-match-patch 应用或服务端 patch 协议：在 `modules/` 下检索 `diff-match-patch|DiffMatchPatch|applyPatch` 无命中，依赖仅声明于 `package.json:49`。更新粒度为"整段文本替换尾部 + 块级追加"。

## 3. 投影表面与多视图关系

同一内容可投影到多表面，但各表面间无同步协议（推断：除历史文本外互不感知）：

- **消息正文（inline）**：主表面，工具卡、思维链卡、日记卡和推送占位卡都在这里渲染。
- **独立阅读窗口（sidecar 窗口）**：通过主进程的 `display-text-content-in-viewer` 通道打开，内容以 base64 参数传入（`fileDialogHandlers.js:382-413`），入口在消息右键菜单（`messageContextMenu.js:316-318`）；窗口内可编辑全文、分享到笔记、截图导出（`text-viewer.js:1545-2284`）。
- **桌面画布（spatial canvas）**：桌面推送标记触发实时创建挂件，转发与接收分别在桌面处理器和 IPC 桥完成（`desktopHandlers.js:948-954`、`ipcBridge.js:277-278`）；挂件与聊天消息并存，推送内容不回流到消息 DOM，流式期间推送块被拦截，消息里只留占位卡。
- **Canvas 协同窗口（文件工作区）**：以 `AppData/Canvas/` 为工作目录，AI 工具写文件，用户在 CodeMirror 中编辑。
- **Scriptorium 文坊窗口（文档工程）**：窗口应用 ID 取自 `windowAppIds.js` 的 DOCX 常量，初始化入口在 `main.js:1083-1092`；经 IPC 通道或托盘「文坊」打开（`desktopHandlers.js:779-781`、`trayManager.js`）。工程、导出与 PR 审批都在 `ScriptoriumModules/scriptorium.html` 内完成（见 6.2）。
- **本地文件系统**：挂件收藏目录、Canvas 目录与笔记文件 `AppData/Notemodules/*.md` 都落在本地磁盘（`notesHandlers.js:550`）。
- **图片查看窗口**：阅读窗口的截图经 `openImageViewer` 在此展示（`text-viewer.js:2238-2280`）。

多视图关系事实：历史 DOM 重渲染只从 `history.json` 原始文本重建；桌面挂件收藏后内容存文件，从文件恢复（`favoritesManager.js:109-141`），消息内的占位卡不链接到挂件文件（未找到占位卡到 `savedId` 的关联逻辑）。

## 4. 表现类型、依赖与运行环境

按执行强度分层（源码确认，未运行验证）：

- **静态/声明式**：Markdown 由 marked 渲染，并关闭了内容清洗（`marked.setOptions({sanitize:false})`），同一窗口还负责语法高亮（hljs）、Mermaid、draw.io 图与 KaTeX；工具结果卡和思维链卡由宿主按字段 schema 渲染，大内容做二级截断，展开时懒加载。渲染与后处理见 `text-viewer.js:1071-1783`，卡片渲染见 `messageRenderer.js:2043-2176`。
- **浏览器脚本**：
  - 气泡内 HTML 代码预览：点击后创建 srcdoc iframe，仅授予 `sandbox="allow-scripts"`，未授予同源权限，并设置 no-referrer。预览脚本通过 postMessage 上报高度；宿主同时检查来源窗口、消息类型与 frameId，将高度限制在 100–12000px。返回代码视图或清理消息时移除监听器、清空 srcdoc、导航到 about:blank 并移除 iframe。该边界与直接进入主 DOM 的原始 HTML 动画岛不同。依据：[预览创建、通信与销毁](../../VCPChat/modules/renderer/contentProcessor.js#L817-L924)。
  - 阅读窗口：模型内联脚本直接在**查看器窗口主 DOM** 执行，CDN 上的 three.js 与 anime.js 换成本地 vendor 版本，脚本可访问 `viewerAPI` 的 Python 执行等能力（`text-viewer.js:882-1234`）。
  - three.js 预览：代码块检测 `THREE.` 与语言标记，命中后注入本地 vendor 并在 iframe 内运行（`text-viewer.js:1575-1711`）。
- **语言进程**：
  - Python 双模式：沙箱模式使用 Pyodide WASM，本地模式经 IPC 启动本机 `python -u`，将代码写入 stdin，累计 stdout/stderr 后一次返回。该 handler 没有超时、进程取消或输出截断；源码虽给 spawn 传入 10MB 的 maxBuffer，但没有按输出大小检查或终止的路径，输出配额尚未确认。依据：[本机执行 handler](../../VCPChat/main.js#L2073-L2109)。
  - Canvas 窗口的运行按钮调用同一 Python IPC，结果区展示输出与错误。依据：[Canvas 运行入口](../../VCPChat/Canvasmodules/canvas.js#L1076-L1090)。
- **桌面挂件**：用 Shadow DOM 与页面隔离，脚本包装成 IIFE 沙箱并注入宿主 API；本地与同源脚本 fetch 后包裹执行，CDN 脚本原样透传。挂件通过 `widgetFS.loadFile` 读取收藏目录里的附加文件（如 app.js、style.css），CDN 库直接加载。实现见 `widgetManager.js:70-692`。

## 5. 用户交互、事件与错误反馈

- **代码块操作**：复制、HTML 播放与返回都由内容处理器实现，播放态用 ResizeObserver 同步高度；Python 运行按钮负责切换输出容器，编辑按钮把代码块切成 contentEditable。定位见 `contentProcessor.js:508-815`、`text-viewer.js:1759-1865`。
- **AI 生成按钮**：消息内任意 `<button>` 由宿主接管，点击后以 `[[点击按钮:文本]]` 消息回发聊天；按钮进入禁用并显示勾选反馈，发送失败则恢复并弹出 toast。这是"声明式组件 + intent 回发"的 G2 形态，实现见 `contentProcessor.js:866-975`。
- **工具结果卡**：支持折叠、截断后展开和图片链接预览（`text-viewer.js:1914-1926`、`messageRenderer.js:2340-2344`）。
- **消息操作**：中键径向菜单与右键菜单提供编辑、重新生成、转发和删除（`middleClickHandler.js:452-620`、`messageContextMenu.js:353-366`）。
- **错误反馈**：Python 执行错误写进输出容器，流错误以警告块追加到消息，Pyodide 加载失败在状态栏提示（`text-viewer.js:1232-1325`、`renderer.js:630`）。
- **交互状态恢复**（推断/未验证）：流式期间由 `preserveDynamicStreamState` 把展开、预览和按钮状态带过 morphdom 帧（`streamManager.js:147-185`）；气泡内 iframe 在历史重渲染时经 `cleanupPreviewsInContent` 销毁重建，运行状态随之中断（`contentProcessor.js:1378-1383`）。

## 6. 编辑、diff、版本与协作

- **消息编辑**：编辑以 textarea 做全文替换，保存后写回内存历史并防抖落盘，编辑模式由 `messageRenderer` 提供（`middleClickHandler.js:468-595`）；没有选区编辑与 diff。
- **Canvas 协同**：外部文件变更仍由 chokidar 通知并用 CodeMirror MergeView 展示。模型经 FileOperator 提交编辑时，主进程保存原文与修改后文本并等待 Canvas 窗口回执；用户可直接拒绝或打开差异后批准，批准前会确认活跃文件与原文快照均未变化，冲突则拒绝应用，成功以临时文件替换。编辑历史仍是内存内容快照，不落盘、无版本号或分支。`modules/ipc/canvasHandlers.js:92-193`、`Canvasmodules/canvas.js:546-1306`
- **Scriptorium 文坊（人机同对象编辑的第二条链）**：文档工程位于 `AppData/ScriptoriumDocument/VDOCX|VPPTX/`（scriptoriumAgentControlService.js:133），人类在 `ScriptoriumModules/scriptorium.html` 直接编辑渲染版式或源码。
  - 协作方式：Agent 通过 `ScriptoriumCollaborator` direct 插件（实现位于 `ScriptoriumCollaboratorService.js`）读取渲染文本、源码与视觉上下文（GetRenderedText、GetSource、GetVisualContext），再以 `SubmitSourcePr` 提交一份带唯一完整 source 的修订；主进程在 docx 侧把 Agent 请求超时设为 30 秒、审阅超时设为 5 分钟（`AGENT_REQUEST_TIMEOUT_MS`、`AGENT_REVIEW_TIMEOUT_MS`）。人类审阅后给出回执，状态为 pending、applied、rejected、conflict、failed 之一；应用的修订进入**文脉**，带 changeSet、工程内嵌版本快照与审批元数据，可回溯且不删后续文脉。
  - 与 Canvas 的差异：Scriptorium 有落盘的版本对象（文脉）与冲突状态（conflict），但仍无 CRDT/合并算法，"最后写入者赢"之外的冲突交给人工裁决；PR 是"整份 source 替换"粒度，与 Canvas 的行级 diff 不同。
  - 事实源：源码是唯一真相（不序列化渲染树，`ScriptoriumModules/README.md` 明确说明），可编程页面的瞬态 DOM 不写入工程。
- **桌面挂件源码编辑**：挂件可在 Canvas 窗口以 `desktop-widget` 上下文打开，保存后经 `notifyDesktopWidgetSourceSaved` 通知桌面刷新（`desktopHandlers.js:1050-1103`、`canvasHandlers.js:70-85`）。
- **协作冲突处理**：Canvas 的受管提案会做原文快照冲突检查并要求人工接受/拒绝；普通文件保存仍是整文件写入。无 CRDT 或结构化 patch，撤销与内容历史限当前窗口内存。

## 7. 能力桥、执行位置与权限范围

执行位置包括宿主 DOM、不同权限的预览 iframe、Pyodide WASM、本机 Python 进程及分布式插件服务。气泡代码预览使用无同源权限的 iframe；阅读窗口代码预览与直接进入页面的脚本权限不同，具体配置见第 4 节。

能力桥（生成对象→宿主动作）：

- **挂件沙箱注入 API**：沙箱向挂件注入四类宿主能力（`widgetManager.js:500-625`）。
  - `widgetFS`：文件读写，范围限定在收藏目录，带文件名安全校验与核心文件保护（`desktopHandlers.js:1070-1080`）；
  - `musicAPI`：播放控制；
  - `__vcpProxyFetch`：带 Basic Auth 的 admin API 代理（`vcpProxy.js:60-73`）；
  - `__vcpProxyPost`：OpenAI 兼容的模型调用代理，挂件可借此再调模型，形成模型-挂件环（`vcpProxy.js:94-151`）。
- **阅读窗口**：`viewerAPI` 暴露 `executePythonCode`、`openNotesWithContent` 与 `openImageViewer`，分别用于本机进程执行、写入笔记和截图展示；模型内联脚本因此拿到与窗口同等的桥能力，安全边界较弱（静态确认事实）。
- **气泡代码预览**：宿主提供的消息桥只处理尺寸上报，并验证来源与 frameId；iframe 未获得同源权限，本次未找到向它注入聊天或本机执行 API 的路径。正文主 DOM 动画岛另按页面脚本权限运行。依据：[预览权限与尺寸消息](../../VCPChat/modules/renderer/contentProcessor.js#L859-L924)。
- **桌面远程控制**：模型经 Rust/服务端把指令注入本地 VCPDistributedServer（`VCPDistributedServer.js:57`），这是查询和修改桌面活对象的受控通道，提供以下动作：
  - `SetWallpaper`：写入 `AppData/DesktopData/ai_wallpaper_*.html`（`desktopRemoteHandlers.js:287-356`）；
  - `CreateWidget`：写入挂件目录的 app.js 与 widget.html（`desktopRemoteHandlers.js:621-622`）；
  - `QueryDesktop` 与 `QueryDock`：把桌面状态报告以 Markdown 工具结果回流（`desktopRemoteHandlers.js:358-405`）；
  - `ViewWidgetSource`、`SetStyleAutomation` 等其他动作。

## 8. 持久化、恢复、分享与导出

- **消息**：全部消息以原始 Markdown 文本（含全部协议标记）写入 `history.json` 这一个 JSON 文件，写盘有 1 秒防抖（`chatHandlers.js:497-512`、`streamManager.js:349`）。`modules/services/chatDataService/index.js:50-70` 作为影子索引服务摄取并提供搜索，事实源仍是这一文件。没有版本，也没有导出格式。
- **桌面挂件**：收藏即在 `AppData/DesktopWidgets/<savedId>/` 下保存 widget.html、meta.json、thumbnail.png 与附加文件，列表、加载、删除走 IPC，挂件还可分享到 Dock 或图标；**运行状态不持久**，恢复时重新执行脚本（`favoritesManager.js:130-132`）。桌面布局与图标走独立 IPC 持久化（`desktop-save-dock`、`desktop-save-layout`）。实现见 `desktopHandlers.js:999-1906`。
- **Canvas 文件**：纯文本文件，mtime 排序列表（`canvasHandlers.js:400-420`）；复制/重命名/删除 IPC。
- **笔记**：`AppData/Notemodules/*.md`（`notesHandlers.js:550-618`），分享到笔记即写文件（`text-viewer.js:1545-1565`）。
- **导出**：阅读窗口截图（modern-screenshot `domToBlob`，`text-viewer.js:2174-2284`）；挂件 thumbnail.png；无标准项目导出/分享格式（Loom 的 `.vloom.json` 包导出属第三方应用运行器，超出本类目）。

## 9. 模型回流、对象感知与持续维护

- **聊天回流**：消息原始文本整段进入下一轮请求，由 chatManager 组消息、主进程侧规范化，再经 contextSanitizer 按深度脱敏并默认剥离思维链（`chatHandlers.js:862-1057`）。
- **桌面状态感知**：模型经 `QueryDesktop` 与 `QueryDock` 取到挂件列表，字段含 saved、savedName、savedDir，报告以工具结果 Markdown 形式回流（`desktopRemoteHandlers.js:379-404`）；桌面推送的替换模式 `target:/replace:` 能对已存在的挂件做选择器级定向替换（`desktopPushConsumer.js`）。
- **文件回流**：FileOperator 等工具可读写 `AppData/Canvas/`、widget 目录（`desktop-save-widget-file`/`load-widget-file`）。
- **对象身份绑定**：本次未找到对象注册表，也没有"按 savedId 继续修改同一对象"的协议；桌面推送的 `target:` 替换是一处例外，其选择器按内容匹配。每个回合模型都生成新的 `dw-<timestamp>` 挂件 ID（`desktopPushConsumer.js:40`）。**持续维护**只存在于用户侧（收藏、刷新、再编辑），模型侧没有跨回合对象引用机制（推断：协议中没有对象 ID 参数通道）。

## 10. 生命周期、资源治理与性能

- **消息内资源**：可见性所有者按消息登记动画、媒体、定时器和图形实例，离屏时冻结，移除消息时撤销观察并清理资源。Pixi 另外实行按聊天根的已启动气泡配额：通常最多三个，历史初载最多一个；满额先淘汰离屏旧实例，热区内取不到配额的新实例会被销毁并标记抑制。详情见[消息渲染器笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md#脚本执行)，依据为 [Pixi 配额](../../VCPChat/modules/renderer/visibilityOptimizer.js#L449-L473) 与 [资源清理](../../VCPChat/modules/renderer/visibilityOptimizer.js#L1045-L1095)。
- **流式 transient**：临时状态包括预缓冲上限、桌面推送的 interval 与 150 秒空闲超时，页面卸载时统一清理，消息进入终态时清掉推送状态（`desktopPushConsumer.js:42-43`、`streamManager.js:336-1738`）。
- **桌面窗口**：`visibilityFreezer`（`Desktopmodules/core/visibilityFreezer.js:154-183`，冻结壁纸 iframe/视频）；挂件删除带 450ms fallback（`widgetManager.js:10-12`）；z-index 管理、拖动限位。
- **渲染性能**：30fps 合帧、`findExplicitStablePrefix` 避免全量重解析、`renderHtmlCache`（`messageRenderer.js:1838-1904`，FNV1a 指纹，含 shouldBypassRenderHtmlCache 判定）、块级 HTML 缓存复用（`streamManager.js:634-653`）。
- **限额**：HTML island 深度 128/256KB（`streamManager.js:53-54`）、推送块 150s 超时、代码行扫光动画最多并发 3（`:12-13`）；未找到挂件数量/进程数全局限额。

## 11. 当前 Scriptorium 协作运行时

Scriptorium 在当前快照由单体脚本拆为文档存储、渲染协调、编辑历史、来源编辑、版式、图形资源和演示文稿模块。它仍以源码为事实源，但 Agent 已可经 ScriptoriumCollaborator 查询文档与视觉上下文，并以完整 source PR 提交修订；文坊等待人类审阅后才产生 applied、rejected、conflict 或 failed 回执及文脉记录。相较消息内预览或 Canvas 文件，这是一条拥有显式对象、审阅回执和可追溯编辑记录的 G4 工作区链路；没有证据表明其具备 CRDT 或自动三方合并。

依据：`ScriptoriumModules/scriptorium-{document-store,render-coordinator,edit-history,pr-diff}.js`、`VCPDistributedServer/Plugin/ScriptoriumCollaborator/ScriptoriumCollaboratorService.js:979-1001`、`modules/ipc/docxHandlers.js:32-33`。

## 12. 测试、已确认边界与未验证事项

**测试体系**：`tests/` 已形成聊天内核、流式终态清理、内容管线、桌面推送、Canvas 审批、LoomSkill、移动同步、设置协调与媒体模块等多组 node:test 契约。Canvas 审批由 `tests/canvas-edit-approval.test.js` 覆盖，稳定前缀/终态清理由 stream 与 content 系列测试覆盖；真实 Electron 视觉、脚本隔离、长会话性能和资源回收效果仍需运行验证。

**已确认边界**（本次调查结论）：
- 不存在统一 Artifact/输出对象模型、无对象注册表、无模型侧跨回合对象绑定——**唯一例外是 Scriptorium 文档工程**（VDOCX/VPPTX + 文脉 PR，6.2），聊天消息/桌面挂件/Canvas 文件均无版本语义。
- HTML 的执行边界按表面区分：气泡代码预览只授予脚本权限；阅读窗口的 HTML/three.js 代码预览还授予同源、弹窗、下载等权限；直接写入阅读窗口正文的内联脚本则在查看器主 DOM 执行。三者不能共享同一种沙箱判断。依据：[气泡预览](../../VCPChat/modules/renderer/contentProcessor.js#L859-L866)、[阅读窗口脚本](../../VCPChat/modules/text-viewer.js#L1059-L1179)、[阅读窗口代码预览](../../VCPChat/modules/text-viewer.js#L1757-L1783)。
- 本机 Python 执行没有专用沙箱、超时或输出截断，权限随宿主进程；详见[执行 handler](../../VCPChat/main.js#L2073-L2109)。
- 桌面挂件脚本沙箱对 CDN 脚本透传（`widgetManager.js:768-776`），沙箱 IIFE 内注入宿主桥（widgetFS/musicAPI/vcpProxy）。
- 消息 DOM 是派生投影，history.json 为事实源；流式期间存在"源码前缀 + 块 HTML 缓存 + 预览 DOM"三份状态，切换视图时以块 HTML 恢复（`streamManager.js:568-606`）。

**未验证事项**（未运行验证）：SSE 流实际事件时序与中断恢复；Pyodide CDN 加载与包安装行为；桌面挂件在实际桌面窗口的渲染/脚本执行；Canvas 外部变更 diff 的实际交互；CSP 与 preload 组合下模型脚本的实际可达面；多话题并发流式下的性能表现。

## 13. 关键源码索引

- `modules/renderer/streamManager.js`：流式投影工厂（`createStreamProjection` `:19`、稳定前缀扫描 `:1088`、帧渲染 `:1000`、终态投影 `:1845`）。
- `modules/renderer/desktopPushConsumer.js:6,40-43,195`：桌面推送白名单、挂件 id、节流与空闲收口。
- `modules/renderer/contentPipeline.js:468,564`：全量渲染与流式轻量流水线（保护-修正-恢复顺序协议）。
- `modules/messageRenderer.js:2342,3763,3886`：工具结果卡、统一 DOM 后处理提交点、单条消息总编排。
- `modules/renderer/contentProcessor.js:592,1258-1290,1328`：代码块复制与预览按钮、KaTeX/高亮后处理、CSS selector 作用域。
- `modules/text-viewer.js`：Python 双模式、HTML/three.js 预览、内联脚本执行、分享到笔记。
- `modules/ipc/chatHandlers.js:1056-1360,1561-1614`：`send-to-vcp` 流式转发与中断入口。
- `modules/ipc/desktopHandlers.js`：桌面推送转发、挂件收藏持久化与远程控制。
- `Desktopmodules/core/widgetManager.js`：挂件 Shadow DOM 与脚本沙箱。
- `Desktopmodules/api/vcpProxy.js`：挂件能力桥（admin fetch / 模型调用）。
- `Desktopmodules/favorites/favoritesManager.js`：挂件收藏与恢复。
- `modules/ipc/canvasHandlers.js` + `Canvasmodules/canvas.js`：Canvas 协同、diff 与内存历史。
- `VCPDistributedServer/Plugin/FileOperator/FileOperator.js`：AI 创建 Canvas 文件。
- `main.js`：本机 Python 执行 IPC。
- `modules/renderer/visibilityOptimizer.js`：消息资源暂停/恢复。
- `main.html` / `Desktopmodules/desktop.html`：窗口 CSP。

## 能力等级评估

- **等级判定：G3（可执行 Artifact）为主，G4（可编辑工作区）部分成立**。
- 主要依据：HTML/JS 进入专用 iframe/窗口运行（气泡预览、阅读窗口、three.js 模板）、Python 双执行环境（WASM 沙箱 + 本机进程）、桌面挂件是带独立 ID、文件持久化、可重载、可远程替换的活对象；Canvas 提供 AI-用户同对象文件编辑 + 行级 diff + 接受/拒绝（G4 特征），但无结构化版本/冲突/分支语义，消息编辑为全文覆盖。Scriptorium 文坊进一步强化 G4 侧：对象带落盘版本（文脉）与冲突状态、Agent 以 PR 提交修订并人工审批，但合并仍是"整份 source 替换 + 人工裁决"。
- 横向轴：协议开放度=自由文本 + 私有标记（低）；更新粒度=整段流式 + 整文件覆盖（低）；投影表面=inline + sidecar 窗口 + 桌面画布 + 本地文件（广）；执行强度=浏览器脚本 + WASM + 本机语言进程（强）；持续性=消息会话内 + 挂件/文件跨会话（中高）；闭环程度=可交互、可编辑、模型可查询桌面状态并定向替换，但无对象身份级持续维护（中）；能力范围=挂件窄桥（widgetFS/musicAPI/vcpProxy）+ 桌面远程通道 + 本机 python 全权（宽窄并存）；可移植性=仅宿主可用（挂件为宿主私有格式，无标准导出）。
