# VCPChat 生成式输出与运行时调查笔记

> 调查对象：`../../VCPChat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支：`main`）
>
> 调查方式：静态代码走读。grep/glob 检索 artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、runtime、exec、preview、tool、message、markdown、highlight 等关键词；通读消息渲染管线（messageRenderer / contentPipeline / streamManager / contentProcessor）、阅读窗口（text-viewer）、Canvas 协同编辑器、桌面挂件与收藏链路、聊天历史持久化链路，以及 Scriptorium 文坊子系统（ScriptoriumModules + docxHandlers + ScriptoriumCollaborator 插件）。未运行应用、未发起真实模型请求。
>
> 调查范围：生成式输出与运行时类目全部必查问题；覆盖消息内嵌运行组件、独立阅读窗口、桌面画布挂件、Canvas 文件工作区、Scriptorium 文档工程、持久化与回流。排除：聊天上下文装配与发送细节（Chat 类目）、工具注册与执行调度（Agent 工具类目）、消息渲染器通用 Markdown/高亮/KaTeX 细节（仅在获得运行生命周期处记录交点）、音频引擎与 TTS、VCPHumanToolBox 工作流编辑器与 ComfyUI（独立人工工具，非模型生成对象）、Loom 应用运行器（第三方应用托管，非模型输出）。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 的"生成式输出"没有独立的 Artifact 对象模型。模型产出全部是消息正文内的原始文本流，通过私有标记协议（`<<<[TOOL_REQUEST]>>>`、`[[VCP调用结果信息汇总:]]`、`<<<[DESKTOP_PUSH]>>>`、`[--- VCP元思考链 ---]`、`<<<DailyNoteStart>>>` 等）表达结构化块，由渲染器转为宿主渲染的声明式卡片（工具结果卡、思维链卡、日记卡、桌面推送占位卡）。事实源是 `AppData/UserData/<agent>/topics/<topic>/history.json` 中的原始 Markdown 文本，DOM 每次重新解析派生，无独立对象 ID/状态/版本层。

**例外：Scriptorium 共笔文坊**是仓库里第一套"独立对象模型"的模型协作面——VDOCX/VPPTX 工程（`AppData/ScriptoriumDocument/`）自带文档模型、资源清单与**文脉版本历史**（人类刻点 + Agent PR 以 pending/applied/rejected/conflict/failed 状态进入同一文脉，含 changeSet 与审批回执），Agent 经 `ScriptoriumCollaborator` 插件以"源码 PR + 人工审批"方式修改对象（详见 6.2）。它仍走"唯一完整 source"的文本真相模型（源码即真相，不序列化渲染树），但补上了聊天侧没有的版本/冲突/身份语义。

运行能力是项目特色：气泡内 HTML 预览（iframe srcdoc，未设置 sandbox 属性）、独立阅读窗口可执行模型内联脚本（CDN 替换为本地 vendor）、Python 双模式执行（Pyodide WASM 沙箱 / 本机 `python -u` 进程）、桌面画布常驻挂件（Shadow DOM + 脚本 IIFE 沙箱 + 能力桥：widgetFS、musicAPI、`__vcpProxyFetch`/`__vcpProxyPost`）。桌面挂件是唯一具备"独立 ID + 文件持久化 + 可重载 + 模型可远程创建/替换/查询"的完整对象链。Canvas 协同窗口提供"AI 写文件 → chokidar 检测 → 行级 diff → 接受/拒绝"的编辑协作面，但版本仅为内存内容快照。

增量生成采用"稳定前缀截断 + 整段尾部重渲染 + morphdom 差量合并"，无 AST 级 patch，未在自有代码中找到 diff-match-patch 使用（依赖虽在 package.json）。用户可编辑消息全文、重新生成回复、点击模型生成的按钮回发 `[[点击按钮:...]]`。

综合能力等级判定为 **G3（可执行 Artifact）为主、G4（可编辑工作区）部分成立**：HTML/JS/Python 有真实运行环境且用户可实际操作，桌面挂件有持久化生命周期；但协议是自由文本私有标记、更新粒度是整段/整文件、无结构化版本与冲突语义、模型对对象的维护是"每次重新生成"而非按对象身份定向修改。

## 系统边界与完整主链路

进程/窗口边界：主窗口（main.html，聊天 UI，CSP 见 `main.html:7-13`，`script-src 'self' 'unsafe-inline'`）、阅读窗口（text-viewer.html）、图片查看窗口（image-viewer.html）、Canvas 协同窗口（Canvasmodules/canvas.html）、桌面窗口（Desktopmodules/desktop.html，透明置底画布）、笔记窗口（Notemodules/notes.html）、Memo 工作台（Memomodules/memo.html）。附属进程：VCPDistributedServer（本地 Express+WS 服务，插件执行）、`vcp_chat_data_service.exe`（VCP-CDS，历史消息影子索引与搜索）、`assistant_core_server.exe`（选区监听 sidecar，`modules/assistant/assistant-rust-adapter.js`）、`rust_audio_engine`/`python` 音频引擎。

完整主链路（源码确认的调用链，未运行验证）：

1. **触发**：用户点击发送 → `renderer.js` 按钮 → `modules/chatManager.js:1360` `handleSendMessage` → `electronAPI.sendToVCP` → `ipcMain 'send-to-vcp'`（`modules/ipc/chatHandlers.js:855`）→ 主进程 `fetch` VCP 服务器（`chatHandlers.js:1107`；若 `enableVcpToolInjection` 则改走 `/v1/chatvcp/completions`，`chatHandlers.js:922-926`）。
2. **生成**：SSE 流在 `chatHandlers.js:1174-1240` 被读取，以 `vcp-stream-event` 通道回传事件（thinking/start/content/end/error）；`renderer.js` 的 `onVCPStreamEvent` 分发，`modules/renderer/streamManager.js:1624` `startStreamingMessage` 建消息，`:2097` `appendStreamChunk` 累积文本，`:2190` `finalizeStreamedMessage` 收口。工具请求由模型以 `<<<[TOOL_REQUEST]>>>` 文本标记输出，由 VCP 服务端（本地 VCPDistributedServer 插件或远端）执行，结果以 `[[VCP调用结果信息汇总:...]]` 块拼入消息流。
3. **展示/运行**：流式渲染 `renderStreamFrame`（`streamManager.js:1361`）：稳定前缀固化到 stable-root、尾部重新 parse + morphdom 差量。最终化后按协议块渲染卡片（`modules/messageRenderer.js:875` `transformSpecialBlocks`、`:2043` `renderToolResultBlock`）。HTML 代码块获得气泡内 iframe 预览（`modules/renderer/contentProcessor.js:645` `setupHtmlPreview`）；Python/HTML/three.js 块在阅读窗口获得运行按钮（`modules/text-viewer.js:1563-1713`）。
4. **交互或编辑**：用户点播放/编辑/复制；中键或右键菜单编辑消息全文、重新生成（`modules/renderer/messageContextMenu.js:128,353`）；AI 按钮点击回发消息（`contentProcessor.js:869`）；`<<<[DESKTOP_PUSH]>>>` 标记在流式期间被拦截实时创建桌面挂件（`streamManager.js:1906` `processDesktopPushToken`），挂件可收藏、可打开源码到 Canvas 编辑。
5. **保存**：最终消息文本（含协议标记的原始 Markdown）写入 `history.json`（`modules/ipc/chatHandlers.js:497`；防抖保存 `streamManager.js:348-375`）；挂件存 `AppData/DesktopWidgets/<id>/`（`modules/ipc/desktopHandlers.js:999`）；Canvas 文件存 `AppData/Canvas/`（`modules/ipc/canvasHandlers.js:299`）。
6. **重新打开**：切换话题/重启后 `get-chat-history` 读 `history.json`，`messageRenderer.js:3158` `renderMessage` 从原始文本重新解析渲染；挂件从收藏 spawn（`Desktopmodules/favorites/favoritesManager.js:108`）；Canvas 文件列表按 mtime 排序重载（`canvasHandlers.js:399`）。

## 1. 触发方式、输出协议与对象模型

**触发方式**：无独立的"创建输出对象"命令；一切输出是模型自由文本流。能力由模型在回复中输出私有标记触发：

| 标记 | 含义 | 处理点 |
|---|---|---|
| `<<<[TOOL_REQUEST]>>>...<<<[END_TOOL_REQUEST]>>>` | 工具请求块（服务端执行） | `messageRenderer.js:308`、`findToolRequestEnd`（`messageRenderer.js:341`，ESCAPE 感知扫描器） |
| `[[VCP调用结果信息汇总:...VCP调用结果结束]]` | 工具结果块 | `messageRenderer.js:312`、`:2043` |
| `<<<[DESKTOP_PUSH]>>>...<<<[DESKTOP_PUSH_END]>>>` | 桌面挂件推送 | `streamManager.js:17-21`、`:1906`；替换模式 `target:/replace:` 字段 |
| `<<<DailyNoteStart>>>...<<<DailyNoteEnd>>>` | 日记创建/更新 | `messageRenderer.js:311`、`transformSpecialBlocks` |
| `[--- VCP元思考链...---]...元思考链结束`、`<think>` | 思维链 | `contentPipeline.js:195` `protectThoughtChains` |
| `<<<[ROLE_DIVIDE_...]>>>` | 角色分界 | `streamManager.js:963` |
| `{{VCPChatCanvas}}` | Canvas 协同占位 | `messageRenderer.js:1341` |
| `[[点击按钮:文本]]` | 用户点击按钮回发 | `messageRenderer.js:314,1334` |

**协议处理**：半截流——`streamManager.js:978` `findExplicitStablePrefix` 在流式时只把已闭合的围栏/工具块/段落边界标记为稳定，未闭合块保持尾部待渲染；未闭合推送块 150 秒超时自动 finalize（`streamManager.js:2041-2051`）。转义——反引号包裹的标记不生效（`streamManager.js:1929-1936`，`messageRenderer.js:328` `isBacktickWrappedMarker`）；工具参数内用「始ESCAPE」「末ESCAPE」承载字面量结束标记（`messageRenderer.js:332-360`）。误触发防护——推送内容需匹配合法前缀白名单否则丢弃（`streamManager.js:2004-2076`）；工具气泡内的 `pre` 块禁止转成 HTML 预览（`contentProcessor.js:608-613,650-655`）。

**对象模型**：不存在统一输出对象模型。可辨识的对象身份只有四类：(a) 消息——`id + role + content(原始文本) + timestamp`，`history.json` 是事实源，DOM 是派生投影；(b) 桌面挂件——运行时 `widgetId` + 收藏后 `savedId`（目录名），`meta.json` 记录 `id/name/createdAt/updatedAt`（`desktopHandlers.js:1015-1031`），无版本字段；(c) Canvas 文件——文件路径即身份；(d) **Scriptorium 文档工程**——`.vdocx/.vpptx` 工程（`AppData/ScriptoriumDocument/`）以 `document.json` + 唯一完整 HTML source + 资源清单为对象，文脉刻点/PR 提供版本与审批语义（6.2）。工具结果卡、思维链卡等无独立 ID，`data-vcp-block-type` 仅用于 DOM 标记与流式保留。推断：无"能力声明/状态机"机制；消息侧对象身份与后续回合的绑定（指南必查 10）没有实现，模型每次重新生成新挂件/新文件；Scriptorium 是唯一带"按对象身份继续修改"通道的面（PR 提交到既有工程）。

## 2. 增量生成、更新与最终化

**流式更新**：两段式渲染。稳定前缀按块固化（`appendNewStableRange`/`appendStableBlockFragment`，`streamManager.js:546-561`），块记录 `{id,start,end,source,html,element}` 存于 `segmentState.stableBlocks`，切换视图重建 DOM 时用缓存的原始 HTML 恢复而不重新解析（`streamManager.js:568-606`，这是"源码与 HTML 双份缓存"的典型实现）；尾部文本每帧重新 parse + morphdom 差量合并（`streamManager.js:1411-1549`），`shouldPreserveStreamElement` 保护已后处理的块（mermaid/katex/工具卡/预览容器/hljs 子树）。渲染节流：30fps 全局 rAF 循环 + 预缓冲队列上限 1000 chunks（`streamManager.js:1805-1812`、`:2110`）。平滑流式可关（`globalSettings.enableSmoothStreaming`）。

**最终化**：`finalizeStreamedMessage`（`streamManager.js:2190-2309`）移除流式根节点，对完整文本执行 `prepareFinalTextForRender`（`messageRenderer.js:2015`，应用前端正则规则与深度计算）后重新全量渲染；流中断时 `renderer.js:601-627` 拼接 `> [!WARNING]` 提示并保存已接收部分。主进程与渲染器文本一致性：取 accumulatedText 与 payload fullResponse 中更长/含恢复标记者（`streamManager.js:2245-2259`）。

**非流式工具结果**：工具结果块由服务端一次性拼接，不做逐 token 注入（`streamManager.js:1900-1904` 注释明确说明）。**未找到**：AST 级节点 patch、diff-match-patch 应用、服务端 patch 协议（grep `diff-match-patch|DiffMatchPatch|applyPatch` 在 `modules/` 下无命中；`diff-match-patch` 仅在 `package.json:43` 依赖声明中）。更新粒度为"整段文本替换尾部 + 块级追加"。

## 3. 投影表面与多视图关系

同一内容可投影到多表面，但各表面间无同步协议（推断：除历史文本外互不感知）：

- **消息正文（inline）**：主表面。工具卡/思维链卡/日记卡/推送占位卡均在此渲染。
- **独立阅读窗口（sidecar 窗口）**：`ipcMain 'display-text-content-in-viewer'`（`fileDialogHandlers.js:381-411`，base64 参数传内容），可从消息右键菜单打开（`messageContextMenu.js:316-318`）；包含编辑全文、分享到笔记、截图导出（`text-viewer.js:1425-1445,2045-2155`）。
- **桌面画布（spatial canvas）**：`<<<[DESKTOP_PUSH]>>>` 实时创建挂件（`desktopHandlers.js:948-954` 转发 `desktop-push-to-canvas`，`Desktopmodules/api/ipcBridge.js:277-278` 接收）；挂件与聊天消息并存但内容不回流到消息 DOM（流式时推送块内容被拦截，消息内只留占位卡，`streamManager.js:2146-2154`）。
- **Canvas 协同窗口（文件工作区）**：`AppData/Canvas/` 目录，AI 工具写文件、用户在 CodeMirror 中编辑。
- **Scriptorium 文坊窗口（文档工程）**：`WINDOW_APP_IDS.DOCX='docx-editor'`（`modules/services/windowAppIds.js:17`），`main.js:1083-1092` 初始化 `docxHandlers`，经 `open-scriptorium-window`（`desktopHandlers.js:779-781`）或托盘"文坊"（`trayManager.js:26`）打开；工程/导出/PR 审批均在 `ScriptoriumModules/scriptorium.html` 内完成（6.2）。
- **本地文件系统**：widget 收藏目录、Canvas 目录、笔记 `AppData/Notemodules/*.md`（`notesHandlers.js:548`）。
- **图片查看窗口**：阅读窗口截图 → `openImageViewer`（`text-viewer.js:2109-2151`）。

多视图关系事实：历史 DOM 重渲染只从 `history.json` 原始文本重建；桌面挂件收藏后内容存文件，从文件恢复（`favoritesManager.js:108-139`），消息内的占位卡不链接到挂件文件（未找到占位卡到 `savedId` 的关联逻辑）。

## 4. 表现类型、依赖与运行环境

按执行强度分层（源码确认，未运行验证）：

- **静态/声明式**：Markdown（marked，`marked.setOptions({sanitize:false})`，`text-viewer.js:1071-1081`）、语法高亮（hljs，`text-viewer.js:1559-1561`）、Mermaid（`text-viewer.js:1483-1505`）、draw.io 图（`text-viewer.js:1507-1541`）、KaTeX（`text-viewer.js:1768-1783`）、工具结果卡/思维链卡（宿主按字段 schema 渲染，`messageRenderer.js:2043-2176`；大内容二级截断 + 懒加载展开，`:2117-2138`）。
- **浏览器脚本**：
  - 气泡内 HTML 预览：iframe `srcdoc`，**未设置 sandbox 属性**（`contentProcessor.js:729-736`），iframe 内脚本可 `window.parent.postMessage` 上报高度（`:758-791`）；关闭时销毁 `srcdoc`→`about:blank`（`:696-704`）。安全性质（推断）：srcdoc iframe 同源继承主窗口 preload 环境。
  - 阅读窗口：模型内联脚本在**查看器窗口主 DOM** 执行（`text-viewer.js:931-1043` `processAnimationsInContent`），CDN three.js/anime.js 替换为本地 vendor（`:882-924`），脚本可访问 `viewerAPI`（含 executePythonCode 等，`text-viewer.js:1211-1234`）。
  - three.js 预览：代码块检测 `THREE.` + 语言标记（`text-viewer.js:1575-1579`），模板注入 `vendor/three.min.js` 在 iframe 内运行（`:1683-1711`）。
- **语言进程**：
  - Python 双模式（`text-viewer.js:1239-1248`）：沙箱模式 = Pyodide WASM（`initializePyodide`，`:1087-1118`，`vendor/pyodide.js` + CDN `cdn.jsdelivr.net/pyodide/v0.25.1/full/`，`# requires:` 注释声明包，`:1140-1154`）；本地模式 = `ipcMain 'execute-python-code'` → `spawn('python', ['-u'])`（`main.js:1185-1221`，无沙箱、无超时、10MB 缓冲区），ANSI 剥离后展示（`text-viewer.js:1251-1255`）。
  - Canvas 窗口跑 Python 按钮同样走本机 python（`Canvasmodules/canvas.js:641-654`）。
- **桌面挂件**：Shadow DOM 隔离（`widgetManager.js:70-93`），脚本包装为 IIFE 沙箱注入宿主 API（`buildSandboxCode`，`widgetManager.js:500-625`），本地/同源 script 被 fetch 后包裹执行，CDN 脚本透传不包装（`widgetManager.js:640-692`）。依赖提供：挂件通过 `widgetFS.loadFile` 读取收藏目录附加文件（app.js/style.css 等），CDN 库直连。

## 5. 用户交互、事件与错误反馈

- **代码块操作**：复制（`contentProcessor.js:507-573`）、HTML 播放/返回（`:710-815`，含 ResizeObserver 高度同步）、Python 运行按钮切换输出容器（`text-viewer.js:1630-1648`）、编辑按钮（contentEditable，`text-viewer.js:1715-1736`）。
- **AI 生成按钮**：消息内任意 `<button>` 被宿主接管（`contentProcessor.js:822-848`），点击发送 `[[点击按钮:文本]]` 回聊天（`:869-975`），按钮禁用 + 勾选反馈，发送失败恢复并 toast（`:966-975`）。这是"声明式组件 + intent 回发"的 G2 形态。
- **工具结果卡**：可折叠（`text-viewer.js:1785-1797`）、截断展开、图片链接预览（`messageRenderer.js:2107-2111`）。
- **消息操作**：中键径向菜单/右键菜单编辑消息、重新生成、转发、删除（`middleClickHandler.js:452-620`，`messageContextMenu.js:353-366`）。
- **错误反馈**：Python 错误输出到 outputContainer（`text-viewer.js:1197-1204`）、流错误以警告块追加（`renderer.js:608`）、pyodide 加载失败状态栏提示（`text-viewer.js:1111-1117`）。
- **交互状态恢复**（推断/未验证）：流式期间 `preserveDynamicStreamState` 保留展开/预览/按钮状态跨 morphdom 帧（`streamManager.js:138-168`）；气泡内 iframe 在历史重渲染时被 `cleanupPreviewsInContent` 销毁重建（`contentProcessor.js:1321-1326`），运行状态不持久。

## 6. 编辑、diff、版本与协作

- **消息编辑**：全文文本编辑（textarea），保存写回内存历史并经防抖落盘（`middleClickHandler.js:468-595` + `messageRenderer` 编辑模式）。无选区编辑、无 diff。
- **Canvas 协同**：这是"人机同对象编辑"链路。AI 经 FileOperator 工具写 `AppData/Canvas/`（`VCPDistributedServer/Plugin/FileOperator/FileOperator.js:1239` `createCanvas`，`:1497`），chokidar 监听外部变更（`canvasHandlers.js:87-109`），渲染器显示变更条并打开 CodeMirror MergeView 行级 diff（`Canvasmodules/canvas.js:247-308`），接受=覆盖编辑器内容（触发自动保存 `:102-113`），拒绝=用户内容写回文件。编辑历史是**内存内内容快照列表**（`canvas.js:777-791` `filesHistory`，可点击回滚 `:824-844`），不落盘、无版本号、无冲突/分支语义。
- **Scriptorium 文坊（人机同对象编辑的第二条链）**：文档工程 `AppData/ScriptoriumDocument/VDOCX|VPPTX/`（`modules/services/scriptoriumAgentControlService.js:133`），人类在 `ScriptoriumModules/scriptorium.html` 直接编辑渲染版式或源码；Agent 经 `ScriptoriumCollaborator` direct 插件（`VCPDistributedServer/Plugin/ScriptoriumCollaborator/ScriptoriumCollaboratorService.js`）读取（GetRenderedText/GetSource/GetVisualContext 等）并提交 `SubmitSourcePr`（带唯一完整 source 的修订，主进程 `docxHandlers` 侧 `AGENT_REQUEST_TIMEOUT_MS=30s`、`AGENT_REVIEW_TIMEOUT_MS=5min`）→ 人类审阅/回执（pending/applied/rejected/conflict/failed）→ 应用的修订进入**文脉**（带 changeSet、工程内嵌版本快照与审批元数据，可回溯且不删后续文脉）。对比 Canvas：Scriptorium 有落盘的版本对象（文脉）与冲突状态（conflict），但仍无 CRDT/合并算法，"最后写入者赢"之外的冲突交给人工裁决；PR 是"整份 source 替换"粒度，与 Canvas 的行级 diff 不同。源码是唯一真相（不序列化渲染树，`ScriptoriumModules/README.md` 明确说明），可编程页面的瞬态 DOM 不写入工程。
- **桌面挂件源码编辑**：挂件可在 Canvas 窗口以 `desktop-widget` 上下文打开（`desktopHandlers.js:956-996`），保存后通知桌面刷新（`canvasHandlers.js:70-85` `notifyDesktopWidgetSourceSaved`）。
- **协作冲突处理**：仅"最后写入者赢"+ 人工 diff 接受/拒绝；无 CRDT、无结构化 patch、无撤销栈（编辑器自带 CodeMirror 撤销仅限当前会话，推断）。

## 7. 能力桥、执行位置与权限范围

执行位置汇总（前节已述）：宿主 DOM（阅读窗口/桌面窗口/Canvas 窗口）、气泡内同源 iframe（无 sandbox 属性）、Pyodide WASM（沙箱内）、本机 python 进程（完全无沙箱）、VCPDistributedServer 本地服务（插件工具，Agent 工具类目边界）。

能力桥（生成对象→宿主动作）：

- **挂件沙箱注入 API**（`widgetManager.js:500-625`）：`widgetFS.saveFile/loadFile/listFiles`（限制在收藏目录，文件名安全校验 + 核心文件保护，`desktopHandlers.js:1070-1080`）、`musicAPI`（播放控制）、`__vcpProxyFetch`（admin API Basic Auth 代理，`vcpProxy.js:60-73`）、`__vcpProxyPost`（OpenAI 兼容模型调用，`vcpProxy.js:94-151`——挂件可再调模型，形成模型-挂件环）。
- **阅读窗口**：`viewerAPI.executePythonCode`（本机进程执行）、`openNotesWithContent`（写入笔记）、`openImageViewer`（截图展示）。模型内联脚本因此可获得与窗口同等的桥能力（安全边界弱，静态确认事实）。
- **气泡 iframe**：仅 `postMessage('vcp-html-resize')` 单向通信（`contentProcessor.js:779-791`）；无沙箱属性和主窗口 preload 环境的叠加意味着 iframe 内脚本可访问聊天 API（推断，未验证具体可达面）。
- **桌面远程控制**（模型→桌面，由 Rust/服务端经 IPC 注入 `VCPDistributedServer.js:57`）：`SetWallpaper`（写 `AppData/DesktopData/ai_wallpaper_*.html`，`desktopRemoteHandlers.js:287-356`）、`CreateWidget`（写 widget 目录 app.js/widget.html，`:621-622`）、`QueryDesktop`/`QueryDock`（状态报告回流为 Markdown 工具结果，`:358-405`）、`ViewWidgetSource`、`SetStyleAutomation`。这是模型查询/修改活对象的受控通道。

## 8. 持久化、恢复、分享与导出

- **消息**：`history.json` 全量 JSON（`chatHandlers.js:497-512`，1 秒防抖，`streamManager.js:349`），存原始 Markdown 文本（含全部协议标记）。VCP-CDS（`modules/services/chatDataService`）作为影子索引服务摄取 history 并提供搜索（`index.js:50-70`，**非事实源**，事实源仍是 history.json）。无版本、无导出格式。
- **桌面挂件**：收藏 = 目录 `AppData/DesktopWidgets/<savedId>/` 内 `widget.html + meta.json + thumbnail.png + 附加文件`（`desktopHandlers.js:999-1095`）；列表/加载/删除 IPC（`:1180-1276`）；挂件可分享到 Dock/图标；**运行状态不持久**，恢复时重新执行脚本（`favoritesManager.js:130-132`）。桌面布局/图标独立持久化（`desktop-save-dock`/`desktop-save-layout`，`desktopHandlers.js:1801-1906`）。
- **Canvas 文件**：纯文本文件，mtime 排序列表（`canvasHandlers.js:399-419`）；复制/重命名/删除 IPC。
- **笔记**：`AppData/Notemodules/*.md`（`notesHandlers.js:548-616`），分享到笔记即写文件（`text-viewer.js:1425-1445`）。
- **导出**：阅读窗口截图（modern-screenshot `domToBlob`，`text-viewer.js:2045-2155`）；挂件 thumbnail.png；无标准项目导出/分享格式（Loom 的 `.vloom.json` 包导出属第三方应用运行器，超出本类目）。

## 9. 模型回流、对象感知与持续维护

- **聊天回流**：消息原始文本整体进入下一轮请求（`chatManager.js` 组消息 → `chatHandlers.js:862-907` 规范化），`contextSanitizer` 按深度脱敏（`chatHandlers.js:1036-1057`）；思维链默认剥离（`:1010-1034`）。
- **桌面状态感知**：模型可经 `QueryDesktop`/`QueryDock` 获取挂件列表（saved/savedName/savedDir，`desktopRemoteHandlers.js:379-404`），报告作为工具结果 Markdown 回流。挂件替换模式 `target:/replace:`（`streamManager.js:1962-1978`）可对已存在挂件定向替换（选择器级）。
- **文件回流**：FileOperator 等工具可读写 `AppData/Canvas/`、widget 目录（`desktop-save-widget-file`/`load-widget-file`）。
- **对象身份绑定**：未找到。无对象注册表、无"按 savedId 继续修改同一对象"的协议（desktop push 的 `target:` 替换是例外但选择器基于内容而非对象身份）；每个回合模型重新生成新 `dw-<timestamp>` 挂件 ID（`streamManager.js:1941`）。**持续维护**仅存在于用户侧（收藏→刷新→再编辑），模型侧无跨回合对象引用机制（推断：协议中没有对象 ID 参数通道）。

## 10. 生命周期、资源治理与性能

- **消息内资源**：`visibilityOptimizer`（`modules/renderer/visibilityOptimizer.js:41-884`）——IntersectionObserver 热区检测，离屏消息暂停 rAF/Element.animate/Three.js 实例/media，`containIntrinsicSize` 高度缓存（与 Pretext 文本测量引擎集成，见 `PRETEXT_INTEGRATION.md`）；`cleanupMessageDomResources`（`messageRenderer.js:2318`）与 `cleanupPreviewsInContent`（`contentProcessor.js:1321`）释放 iframe、message 监听器、动画。
- **流式 transient**：预缓冲上限、桌面推送 interval 与 150s 空闲超时（`streamManager.js:2041-2052`）、`beforeunload` 全局清理（`:207-210`）、消息 finalize 清理桌面推送状态（`:2088-2095`）。
- **桌面窗口**：`visibilityFreezer`（`Desktopmodules/core/visibilityFreezer.js:154-183`，冻结壁纸 iframe/视频）；挂件删除带 450ms fallback（`widgetManager.js:10-12`）；z-index 管理、拖动限位。
- **渲染性能**：30fps 合帧、`findExplicitStablePrefix` 避免全量重解析、`renderHtmlCache`（`messageRenderer.js:1686-1752`，FNV1a 指纹，含 shouldBypassRenderHtmlCache 判定）、块级 HTML 缓存复用（`streamManager.js:568-606`）。
- **限额**：HTML island 深度 128/256KB（`streamManager.js:44-45`）、推送块 150s 超时、代码行扫光动画最多并发 3（`:12-13`）；未找到挂件数量/进程数全局限额。

## 11. 测试、已确认边界与未验证事项

**测试体系**：`tests/` 顶层 7 个文件（`frontend-plugins.test.js`、`loom-controller.test.js`、`loom-electron-adapter.test.js`、`loom-manager-runtime.test.js`、`deepmemo-central-adapter.test.js`、`mobile-sync-central-adapter.test.js`，node:test + jsdom 驱动（`frontend-plugins.test.js:1-13`），以及 `test-export-inline.cjs`）；另有 `tests/重构中禁用脚本/` 子目录 12 个 Scriptorium 测试/冒烟脚本（目录名自述"重构中禁用"）。**未找到**：针对聊天渲染管线（contentPipeline/streamManager）、工具结果解析、桌面推送、Canvas diff、历史保存恢复、iframe 预览的测试。流式最终一致性、资源回收、能力边界均无自动化覆盖。

**已确认边界**（本次调查结论）：
- 不存在统一 Artifact/输出对象模型、无对象注册表、无模型侧跨回合对象绑定——**唯一例外是 Scriptorium 文档工程**（VDOCX/VPPTX + 文脉 PR，6.2），聊天消息/桌面挂件/Canvas 文件均无版本语义。
- 气泡内 HTML 预览 iframe 未设 sandbox 属性（`contentProcessor.js:729-736`）；阅读窗口内联脚本在窗口主 DOM 执行（`text-viewer.js:991-1037`）——均为静态代码确认的架构事实，其安全影响未评估。
- 本机 Python 执行（`main.js:1185-1221`）无沙箱/超时/资源限制。
- 桌面挂件脚本沙箱对 CDN 脚本透传（`widgetManager.js:676-684`），沙箱 IIFE 内注入宿主桥（widgetFS/musicAPI/vcpProxy）。
- 消息 DOM 是派生投影，history.json 为事实源；流式期间存在"源码前缀 + 块 HTML 缓存 + 预览 DOM"三份状态，切换视图时以块 HTML 恢复（`streamManager.js:568-606`）。

**未验证事项**（未运行验证）：SSE 流实际事件时序与中断恢复；Pyodide CDN 加载与包安装行为；桌面挂件在实际桌面窗口的渲染/脚本执行；Canvas 外部变更 diff 的实际交互；CSP 与 preload 组合下模型脚本的实际可达面；多话题并发流式下的性能表现。

## 12. 关键源码索引

- `modules/renderer/streamManager.js:1624/2097/2190/1361/1906`：流式消息生命周期、块级稳定前缀渲染、桌面推送拦截
- `modules/renderer/contentPipeline.js:408`：全量渲染流水线（保护-修正-恢复顺序协议）
- `modules/messageRenderer.js:875/2043/1397/3158`：协议块转换、工具结果卡、HTML 作用域化、消息渲染
- `modules/renderer/contentProcessor.js:645/822/869`：气泡内 HTML 预览、AI 按钮接管
- `modules/text-viewer.js:1083/1239/1581/931/1425`：Python 双模式、HTML/three.js 预览、内联脚本执行、分享到笔记
- `modules/ipc/chatHandlers.js:855/497/480`：send-to-vcp 流式转发、历史保存
- `modules/ipc/desktopHandlers.js:948/999/1063/1180`：桌面推送、挂件收藏持久化
- `modules/ipc/desktopRemoteHandlers.js:241/287`：模型→桌面远程控制
- `Desktopmodules/core/widgetManager.js:23/500/640`：挂件 Shadow DOM 与脚本沙箱
- `Desktopmodules/api/vcpProxy.js:60/94`：挂件能力桥（admin fetch / 模型调用）
- `Desktopmodules/favorites/favoritesManager.js:21/108`：挂件收藏与恢复
- `modules/ipc/canvasHandlers.js:87/299/399` + `Canvasmodules/canvas.js:247/290/777`：Canvas 协同、diff、内存历史
- `ScriptoriumModules/`（scriptorium.html/scriptorium.js/vdoc-hybrid-compiler.js/vdoc-core.js，README.md 为权威说明）+ `modules/ipc/docxHandlers.js` + `modules/services/scriptorium{AgentControl,Import,PptxImport}Service.js` + `VCPDistributedServer/Plugin/ScriptoriumCollaborator/`：文档工程、导入导出、Agent PR 协作（6.2）
- `VCPDistributedServer/Plugin/FileOperator/FileOperator.js:1239`：AI 创建 Canvas 文件
- `main.js:1185`：本机 Python 执行 IPC
- `modules/renderer/visibilityOptimizer.js:41`：消息资源暂停/恢复
- `main.html:7` / `Desktopmodules/desktop.html:6`：窗口 CSP

## 能力等级评估

- **等级判定：G3（可执行 Artifact）为主，G4（可编辑工作区）部分成立**。
- 主要依据：HTML/JS 进入专用 iframe/窗口运行（气泡预览、阅读窗口、three.js 模板）、Python 双执行环境（WASM 沙箱 + 本机进程）、桌面挂件是带独立 ID、文件持久化、可重载、可远程替换的活对象；Canvas 提供 AI-用户同对象文件编辑 + 行级 diff + 接受/拒绝（G4 特征），但无结构化版本/冲突/分支语义，消息编辑为全文覆盖。Scriptorium 文坊进一步强化 G4 侧：对象带落盘版本（文脉）与冲突状态、Agent 以 PR 提交修订并人工审批，但合并仍是"整份 source 替换 + 人工裁决"。
- 横向轴：协议开放度=自由文本 + 私有标记（低）；更新粒度=整段流式 + 整文件覆盖（低）；投影表面=inline + sidecar 窗口 + 桌面画布 + 本地文件（广）；执行强度=浏览器脚本 + WASM + 本机语言进程（强）；持续性=消息会话内 + 挂件/文件跨会话（中高）；闭环程度=可交互、可编辑、模型可查询桌面状态并定向替换，但无对象身份级持续维护（中）；能力范围=挂件窄桥（widgetFS/musicAPI/vcpProxy）+ 桌面远程通道 + 本机 python 全权（宽窄并存）；可移植性=仅宿主可用（挂件为宿主私有格式，无标准导出）。
