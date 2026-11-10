# Cherry Studio 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：静态代码阅读（grep/glob 检索 + 关键实现文件通读），辅以仓库内单元测试作为行为佐证；未构建、未运行应用
>
> 调查范围：聊天内 HTML Artifact（检测、预览、沙箱 webview、编辑、持久化）、Agent 会话工作区文件（文件树、预览、编辑、自动保存、模型回流）、代码执行（Pyodide/PythonService）、特殊视图与文件预览投影；排除 MiniApp webview、MCP 工具调度语义、通用文件管理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的输出对象分两条主链。(1) 聊天内 HTML Artifact：模型以 Markdown 文本或裸 HTML 形式输出，前端用内容探测（`classifyHtmlArtifactSource`）把输出识别为完整文档或片段两类——片段恒进无脚本 iframe，完整文档经用户同意后进入独立沙箱 webview（专用隔离分区，主进程强制沙箱与上下文隔离、无 preload，网络请求受 DNS 级 SSRF 防护）；对象可编辑并以整段重写的方式保存回消息正文，可下载、外部打开、PNG 截图。(2) Agent 工作区：Claude Code SDK 以会话工作区路径为本机执行目录，产物即磁盘文件，`report_artifacts` 工具调用作为声明投影到消息卡片与右侧面板（实时文件树 + 文件预览 + 编辑器防抖自动保存 + 写时冲突检测），用户修改可由后续文件读取回流，也可从文档选区、文本行评论或浏览器批注显式插入 Composer，作为下一条用户输入的目标引用。Python 代码块可经 Pyodide Web Worker 执行（另有 MCP `python_execute` 工具）。

chat 内 artifact 没有独立对象类型（无 artifact part，身份为按 Markdown 位置派生的临时 ID）；agent 文件的真相源是磁盘而非消息。能力等级：**G3 + G4**（见"设计取舍与能力定级"）。

## 系统边界与完整主链路

边界：本类目覆盖"输出获得独立对象身份或专用运行环境"之后的环节。消息如何进入时间线、工具调度与审批、普通 Markdown 渲染分别属于 Chat / Agent 工具 / 消息渲染器类目，此处只记录交接点。

主链路 A（聊天内 HTML Artifact，完整走通）：

```text
模型流式输出 ```html 代码块 / 裸 HTML
  -> text part（AI SDK UIMessage.parts，无专用 part 类型）
  -> MessagePartsRenderer.renderPart（assistant + success => inlineHtmlPreviewMode='ready'）
  -> ChatMarkdown + remarkHtmlArtifact（顶层 HTML 区域重写为 code 节点）
  -> CodeBlock.tsx：classifyHtmlArtifactSource 分类 document/fragment
  -> MessageHtmlArtifact（fragment 恒为无脚本 iframe；document 需用户同意后才进 webview）
  -> 编辑：HtmlArtifactsPopup CodeEditor -> onSave -> saveCodeBlock
  -> updateCodeBlock 按位置 ID 重写 Markdown -> editMessage -> SQLite 消息行
  -> 重开会话：DB 消息重读 -> 重新渲染 artifact（位置 ID 重新派生）
```

主链路 B（Agent 工作区文件）：

```text
用户创建/选择 agent 会话工作区（USER 自选路径 / SYSTEM 按日期+sessionId 生成）
  -> Agent runtime 驱动（claude-code 调 SDK query()，pi / pi-durable 走原生会话）以 cwd=workspace.path 执行
  -> 模型用文件工具写磁盘；REPORT_ARTIFACTS_PROMPT 提示结束时调 report_artifacts
  -> report_artifacts tool part 持久化 -> 消息内产物卡片 + 右 pane 文件树（实时 watcher）
  -> 点击文件 -> ArtifactPane 预览/编辑 -> useFileEditSession 防抖自动保存（乐观锁）
  -> 磁盘即真相；下一回合模型读盘 -> 修改 -> 再声明（持续维护闭环）
```

主链路 C（Python 执行）：python 代码块的 Run 按钮由偏好 `chat.code.execution.enabled` 控制（默认 false），开启后经 `pyodideService.runScript` 在渲染进程内的 Web Worker（`src/renderer/workers/pyodide.worker`）中执行；结果文本或图片显示在代码块状态栏，不持久化。

## 1. 触发方式、输出协议与对象模型

- **触发**：模型输出 HTML Artifact 时没有独立协议，触发源就是自由文本里的 html 代码围栏或裸 HTML 节点，由渲染层做内容探测来认定。探测函数 `classifyHtmlArtifactSource` 用正则把输出分成两类：以 `<!doctype` 或 `<html>` 开头的判为完整文档，以 `<div` 这类带闭合的起始标签开头的判为片段；遇到尚未闭合的半截前缀则先返回未定型，渲染器据此暂不渲染，等后续几个字符到达再重新判定。
- **误触发防护**：识别只把顶层的裸 HTML 区域重写成代码节点，行内 HTML 留在 Markdown 树中；源文本另用占位符保护，避免被后续预处理改写。探测与这两处防护在 `src/renderer/components/chat/messages/markdown/plugins/remarkHtmlArtifact.ts:29-41,150-212`，渲染器侧的启用判断在 `CodeBlock.tsx:105`。
- **输出协议与对象模型**：
  - 消息正文直接用 AI SDK 的消息 parts 承载，自定义 part 类型只有错误、翻译、视频、紧凑与 agent 任务事件等少数几种，其中没有 artifact 类型，HTML artifact 一律以 text part 进入消息。part 结构见 `src/shared/data/types/message.ts:136`，自定义类型清单见 `src/shared/data/types/uiParts.ts:139-151`。
  - `artifactId` 由块 ID 与代码块 ID 拼成，代码块 ID 取自 Markdown 节点的行列偏移，因此每次渲染都会重算。这个身份只用于列表项重挂载时保住已打开的弹窗会话，没有持久对象 ID。派生规则见 `src/renderer/utils/markdown.ts:162`，用途在 `src/renderer/components/chat/HtmlArtifactView.tsx:60-61` 的注释中说明。
  - Agent 侧的 `report_artifacts` 是经 zod 校验的结构化工具输入，以 tool part 持久化，是最接近"输出声明"的协议；声明只有 path、description、summary 三个字段，不含对象 ID 与版本。定义见 `src/shared/ai/builtinTools.ts:489-552`。
  - 另注：内建工具不使用 `strict: true`，`report_artifacts` 的 schema 为非 strict 形态。
- **事实源**：chat 消息行（SQLite `data` JSON）是消息文本的事实源；agent 文件的事实源是磁盘，消息只存声明与执行记录。

## 2. 增量生成、更新与最终化

- 聊天文本按 token 流式到达。正在生成的消息带上 `inlineHtmlPreviewMode: 'generating'` 标记，回合结束、角色为 assistant 且状态为 success 时回落到 `'ready'`；标记的注入与回落都在同一处实现，见 `src/renderer/components/chat/messages/blocks/MessagePartsRenderer.tsx:504-507,1203`。
- 流式中 artifact 的 HTML 按 250ms 节拍重灌 iframe 的 srcDoc（`useStreamingPacedHtml`，`HtmlArtifactView.tsx:326-344`），避免每 token 全量重解析；完成后的 HTML 原样直通。
- 分类为完整文档且流式未完时先以只读代码块视图展示，完成后才进入交互同意门（`CodeBlock.tsx:107-118`）；片段类恒实时渲染。
- **更新/编辑粒度**：整段覆盖。用户在代码块里保存编辑时，前端先解析 Markdown，按位置 ID 定位到对应的代码节点并整体替换，序列化后整段写回消息的 text part。替换逻辑见 `src/renderer/utils/markdown.ts:179-189`，写回链路见 `src/renderer/pages/home/messages/homeMessageListAdapter.tsx:460-489`。没有 patch、diff 或 AST 级的更新协议。
- Agent 文件由模型经 CLI 文件工具直接写磁盘（全量文件写），无 host 侧 diff 应用层。
- 失败收口：artifact 渲染失败或分类未定型时按完整文档模式收紧处理，即"fail closed"（`MessageHtmlArtifact.tsx:22`）；编辑保存失败走 toast 提示并保留原文（`homeMessageListAdapter.tsx:483-485`）。

## 3. 投影表面与多视图关系

| 表面 | 承载 | 位置 |
|---|---|---|
| inline（消息内） | `HtmlArtifactView` 自适应高度预览、`HtmlArtifactsCard` 卡片 | `CodeBlock.tsx:120-139` |
| 全屏弹窗 | `HtmlArtifactsPopup`（preview/code/split 三模式、缩放、截图、下载、外部打开） | `CodeBlockView/HtmlArtifactsPopup.tsx` |
| 消息内产物卡片 | `ReportArtifacts`（agent 交付物列表，点击进右 pane） | `src/renderer/components/chat/messages/tools/agent/ReportArtifacts.tsx` |
| sidecar（agent 右 pane） | `ArtifactPaneView`：文件树 + 选中文件 overlay 预览/编辑 | `src/renderer/components/chat/panes/ArtifactPane.tsx` |
| 独立标签页 | `/app/file-preview?path=...`（`FilePreviewPage`），`useOpenFilePreviewTab` 归一化路径复用 tab | `src/renderer/pages/filePreview/FilePreviewPage.tsx`、`components/FilePreview/hooks/useOpenFilePreviewTab.ts` |
| 外部 | 系统浏览器打开临时 HTML 文件、外部代码编辑器（`OpenExternalAppButton`、`buildEditorUrl`） | `HtmlArtifactView.tsx:799-808`、`ArtifactPane.tsx:349-398` |

同一对象多投影同步：chat artifact 的弹窗预览与消息内预览共用同一份 HTML 数据，通过弹窗上下文在渲染期同步（`HtmlArtifactView.tsx:706-720,822-831`）；"已同意交互预览"按 artifactId 到 HTML 的精确匹配记忆（`HtmlArtifactView.tsx:763`），HTML 内容变化即失效。agent 文件树与编辑器是同一磁盘状态的两份投影，文件树靠主进程 watcher 推送增量事件保持新鲜（见第 10 节）。

预览层已拆成可移植包与应用内插件两层。PDF、DOCX、PPTX、XLSX、RTF 与图片等"与产品无关"的预览实现、工具栏、布局和超限提示进入 `packages/file-preview`，由 `filePreviewRegistry` 按文件类型注册；HTML、Markdown 与源码预览仍留在应用内，因为它们依赖宿主的沙箱、主题与编辑器能力。桌面侧通过 `Preview.tsx` 与 `previewContext.ts` 把宿主能力注入包内组件，注入面包含资源解析、选中文本与本地化，因此包本身不引用 Electron。
## 4. 表现类型、依赖与运行环境

- **HTML artifact 分级运行**：同一份 HTML 按内容性质与用户是否同意交互，分三档给予运行环境。

| 场景 | 运行方式 | 边界 |
|---|---|---|
| 片段，或尚未同意交互的完整文档 | 无脚本 iframe 预览；父级读取 `contentDocument` 测量高度并截图 | sandbox 只开 `allow-same-origin`，CSP 为 `default-src 'none'`，静态资源限 data/blob/file |
| 用户同意后的完整文档 | 进入 Electron webview，以 data URL 加载编码后的文档，并注入高度与滚轮桥接脚本 | 主进程在 webview 附加时强制沙箱、上下文隔离与 web 安全，关闭 Node 集成并删除 preload；URL 与导航都只接受 data: 前缀，拒绝 `window.open` |
| 文件预览中的 HTML | 普通文件用空 sandbox 加严格 CSP；agent 工作区的 artifact 类型才授予脚本权限 | 权限按文件类型是否标记为 artifact 区分 |

iframe 档与 webview 档的装载实现在同一文件，见 `HtmlArtifactView.tsx:115-194,465-471,530-535`；CSP 常量见 `HtmlPreviewFrame.tsx:10-28`。webview 档的主进程加固见 `src/main/services/MainWindowService.ts:268-323`：专用分区会话名为 `html-artifact-preview`，拒绝全部权限请求、禁止下载，网络请求交由 `isAllowedHtmlArtifactRequest` 拦截。文件预览档见 `HtmlFilePreview.tsx:24-32`，同目录的 `FilePreview/README.md` 明确要求不要把任意本地文件标为 artifact。

- **同意判定**：完整文档是否要弹交互同意门，由 `htmlArtifactRequiresUserConsent` 用 htmlparser2 静态扫描内容后决定。扫描覆盖这几类危险模式：可执行与嵌入标签（script、iframe、object、embed）、行内事件属性、javascript: 与外部 URL、meta refresh、CSS url() 引用（含转义写法）；扫描过程中解析失败按 fail-closed 处理。判定逻辑见 `src/renderer/utils/htmlArtifact.ts:49-106`。
- **图表**：Mermaid、Graphviz/viz-js、PlantUML 与 SVG 均以静态渲染 + shadow DOM 挂载（`src/renderer/components/Preview/` 及 `CodeBlockView/constants.ts:7`），无交互、无对象身份，留在消息渲染器类目。
- **代码执行**：只有 python 语言且偏好开关打开时才能执行，入口把脚本交给渲染进程内的 Web Worker 运行，默认超时 60 秒、初始化最多重试 5 次，运行状态可重置；matplotlib 输出的图片以 image 内容显示。主进程另有一套 Python 服务经 IPC 桥接同一个 worker，供 MCP 的 `python_execute` 工具调用。执行入口见 `src/renderer/services/PyodideService.ts:136-188`，桥接侧见 `src/main/services/PythonService.ts` 与 `src/main/ai/mcp/servers/python.ts`。
- **Agent 执行环境**：三种 runtime 驱动都在会话工作区目录上运行——claude-code 用 Claude Agent SDK 的查询入口，pi 与 pi-durable 用原生会话，工作区路径由 `prepareAgentSessionWorkspaceDirectory` 统一准备（`src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:3-11,1297-1298`），是"Agent 工具/执行"类目边界，此处只作为产物的产生方记录；其 Bash 工具等调度语义不展开。

## 5. 用户交互、事件与错误反馈

- 预览弹窗提供的操作面包括缩放（50%-200%）、预览与源码切换、分屏、全屏、下载、外部打开，以及显式的"同意交互预览"。PNG 截图可存为文件或写入剪贴板，取像素依赖 iframe 的 `allow-same-origin` 权限与 `contentDocument` 访问，链路见 `HtmlArtifactsPopup.tsx:148-176`。
- 高度自适应分两条通道。iframe 用 ResizeObserver 与 MutationObserver 直接测量内容高度；webview 只能靠注入脚本通过 console 消息通道上报高度与滚轮事件。滚轮事件再经 `ScrollOwnershipContext` 在边界处转发，避免内嵌文档吞掉消息列表的滚动；该上下文位于消息列表目录，并同时隔离嵌套滚动区。测量、上报与转发见 `HtmlArtifactView.tsx:196-206,267-308,363-452,542-567`。
- 错误反馈：渲染错误经日志与 toast；文件预览有加载中、过大、读取失败、空四种分级状态（`HtmlFilePreview.tsx:34-92`）；编辑保存失败提示重试/丢弃（`ArtifactPane.tsx:603-634`）；agent 文件编辑显式关闭时若保存失败可直接丢弃草稿，不再被失败保存阻塞。
- 交互状态恢复：弹窗会话可在列表项重挂载间存活（artifactId 派生身份），但**未发现**跨会话/跨重载的 artifact 视图状态持久化（缩放、弹窗开合均为运行时状态）。

## 6. 编辑、diff、版本与协作

- **chat 内代码块/artifact**：CodeEditor 可编辑（偏好 `chat.code.editor.enabled`，默认 false；流式中禁编辑），保存即全量覆盖消息文本；无 diff、无接受/拒绝、无撤销。
- **Agent 工作区文本编辑**：`useFileEditSession` 是共享文件编辑管理器的 React 租约入口；按 owner/文件定位复用草稿，同一时刻只有绑定租约可写。文件标签页与面板可见性变化释放绑定时会冲刷脏草稿；关闭自动保存只关闭输入后的 800ms 定时保存，离开面板仍会保存。无视图持有但保存失败的草稿留在管理器清单，用户可重试或丢弃。依据：[FileEditSessionManager.ts:76–183](../../cherry-studio/src/renderer/services/fileEdit/FileEditSessionManager.ts#L76-L183)、[AgentRightPane.tsx:1070–1086](../../cherry-studio/src/renderer/pages/agents/components/AgentRightPane/AgentRightPane.tsx#L1070-L1086)。
- **冲突处理**：写入经文件编辑 IPC 携带版本与内容哈希基线，队列串行执行；版本冲突时重读，若只是元数据变化则采纳新基线重试，真正内容变化会暂停保存并保留本地草稿。watcher 对脏草稿只置冲突，不覆盖内容；用户可重载或选择保留本地内容。编码、BOM 与换行信息随磁盘快照保留。依据：[FileEditSessionManager.ts:320–469](../../cherry-studio/src/renderer/services/fileEdit/FileEditSessionManager.ts#L320-L469)。
- 用户和模型协作仍基于同一磁盘文件，本次检查的文本编辑链没有三方合并、CRDT 或文件对象历史栈；会话消息分支另见[会话与消息管理笔记](../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md)。

## 7. 能力桥、执行位置与权限范围

- **HTML artifact webview**：运行在隔离分区里的沙箱 webview，没有 preload，也没有 IPC 桥，因此页面无法调用宿主 API。唯一的通道是 console 消息上的高度与滚轮结构化消息，消息带随机前缀以防伪造。网络只放行两类请求：data: 与 blob:，以及经净化函数检查通过的 https URL；后者先解析 DNS，拒绝本机回环、私网、多播与保留网段，构成 SSRF 防护。摄像头等权限请求一律拒绝，下载被禁止。桥接消息见 `HtmlArtifactView.tsx:108-114`，网络判定见 `src/main/utils/remoteUrlSafety.ts:21-51`。
- **fragment iframe**：无脚本（空 sandbox + CSP），同源仅用于测高。
- **Pyodide worker**：渲染进程内 Web Worker，无 Node 集成；能力仅 Python 运行时自身（标准库+科学包），文件/网络受限（未在本快照中查证 worker 内是否开放网络，见未验证事项）。
- **agent 文件投影**：FilePreview `type='file'` 严格沙箱；`type='artifact'` 授予脚本权限（`HtmlFilePreview.tsx:24-32`）。外部编辑器/系统浏览器打开是宿主文件能力（`window.api.file.*`），属正常桥接。

## 8. 持久化、恢复、分享与导出

- chat artifact 的源文本存在消息的 `data.parts` 中（SQLite 消息行）；用户编辑后整段写回，重开会话时从数据库重读消息并重新渲染。分享与导出有四条路径：经宿主保存接口下载 `.html` 文件、写入临时文件后交给系统浏览器打开、PNG 截图、复制到剪贴板。消息图片导出时会显式跳过带 `data-html-artifact` 标记的节点，见 `src/renderer/utils/image.ts:192-193`。
- agent 文件的持久化就是磁盘本身，因此产物跨会话存活。系统工作区由托管根目录按日期加 sessionId 生成，用户工作区可指向任意绝对路径并以 `agentWorkspace` 表记录；工作区路径与删除前的引用统计见 `src/main/data/services/AgentWorkspaceService.ts:47-56,115-141`。文件树的展开态与选中态属于渲染器状态，切换 workspace 时随之重置，见 `ArtifactPane.tsx:849-872`。删除工作区前，系统先统计引用它的会话、渠道与任务并在确认对话框中逐项列出，对话框实现在 `WorkspaceDeleteConfirmDialog.tsx`。
- artifact 对象层没有复制、分享或删除协议，能操作的只有底层文件本身。

## 9. 模型回流、对象感知与持续维护

- **chat 内 artifact**：用户编辑后的文本回到消息行，下一回合作为历史上下文一起送进模型，回流通道只有"会话历史重入"这一条，没有对象查询接口。模型因此无法列出或定位某个 artifact（缺少 ID 协议），也无法对它做定向 patch；每回合重新输出 HTML，得到的是新的一份副本。
- **agent 工作区**：闭环建立在磁盘状态上——模型用文件工具直接读取磁盘的当前内容（含用户编辑），交付物列表靠重复调用 `report_artifacts` 更新，右 pane 按 path 去重；会话可跨回合续跑，支持恢复令牌、转向与后台任务。对象身份绑定在"路径 + 会话工作区"这一组合上，没有单独的对象 ID。去重逻辑见 `agentRightPaneProjection.ts:474-503`，续跑能力由 `AgentRuntimeConnection` 与 `AgentSessionRuntimeService` 承担。
- **显式引用回流**：文件面板可把文件/目录加入上下文；Office/PDF 选区和文本行评论可作为引用芯片插入当前会话 Composer。事件按 topicId 与当前活动输入层过滤，避免同时挂载的 Composer 吞入别的会话引用。文档引用保留结构锚点、摘录、文件大小与整数毫秒时间戳；行评论保留路径、行范围、原文及用户评论。发送时芯片的提示文本进入用户消息，形成比“下回合模型主动读盘”更明确的目标交接。依据：[AgentRightPane.tsx:1122–1165](../../cherry-studio/src/renderer/pages/agents/components/AgentRightPane/AgentRightPane.tsx#L1122-L1165)、[useComposerSelectionReferenceInsertion.ts:22–42](../../cherry-studio/src/renderer/components/composer/variants/shared/useComposerSelectionReferenceInsertion.ts#L22-L42)。
- 文档选区序列化为 `selection-ref` 围栏内的 JSON，锚点分别采用表格范围、段落、页面或幻灯片坐标；文本行评论则输出 Markdown 路径、原文围栏与评论。它们是输入文本契约，由模型或 Skill 继续解释，不是宿主对 Office 文件直接执行的结构化编辑命令。浏览器元素批注另走注释芯片，包含页面定位与评论，同样经用户下一次发送回流。依据：[selectionReferenceToken.ts:17–65](../../cherry-studio/src/renderer/components/composer/selectionReferenceToken.ts#L17-L65)、[selectionReference.ts:18–55](../../cherry-studio/src/renderer/types/selectionReference.ts#L18-L55)、[AgentRightPane.tsx:1199–1217](../../cherry-studio/src/renderer/pages/agents/components/AgentRightPane/AgentRightPane.tsx#L1199-L1217)。

## 10. 生命周期、资源治理与性能

- 文件树由主进程维护：先做一次全量初始扫描，之后的变更靠 watcher 事件增量更新，处理时带背压，多个消费者共享同一 watcher 去重；根目录暂时不存在时可以先等待它出现。渲染端只按事件增删改本地镜像。初始扫描与事件更新见 `src/main/services/file/tree/builder.ts:19-20,212-218,225-227`，去重与等待逻辑在 `DirectoryTreeManager.ts`。
- 快照与实时流之间的交付间隙由三阶段握手补上：渲染进程依次调用 `file.tree.create`、`activate` 与 `dispose`，consumer 创建后先挂起、期间的变更在主进程排队，activate 成功才放行，被拒绝则重新取快照（最多 3 次）。渲染侧因此改为请求式调用，并给懒加载 watcher 保留 10 秒的 dispose 宽限（`LAZY_WATCHER_DISPOSE_GRACE_MS`），用于吸收 `<Activity>` 标签切换。
- webview：分区会话随应用生命周期注册/释放（`setupHtmlArtifactPreviewSession` 的 `registerDisposable`）；`did-attach-webview` 拦截导航；未发现按可见性冻结/卸载 artifact 预览的机制（iframe 一直挂载，仅流式节拍降低重建频率）。
- Pyodide：单例 worker，终止时拒绝所有挂起请求；超时清理；模块状态跨次执行保留（可 reset）。
- 编辑会话资源在无租约、无脏草稿或错误时才可回收；保留的失败草稿属于当前渲染进程内存状态，本次未确认跨窗口或应用重启恢复。文件编辑资源上限与二进制判断在主进程文件编辑服务处理；HTML 预览另有类型插件自己的大小限制。长会话的压缩与上下文用量属请求类目。依据：[FileEditSessionManager.ts:95–126,488–507](../../cherry-studio/src/renderer/services/fileEdit/FileEditSessionManager.ts#L95-L126)、[useFileEditSession.ts](../../cherry-studio/src/renderer/hooks/useFileEditSession.ts)。

## 11. 当前输出对象补充

Artifact 面板新增 XLSX 预览：电子表格解析在 worker 中执行，进入终态时会终止解析 worker，避免已完成或失败任务继续占用资源。PDF 翻译的结果会进入翻译历史与文件管理器，可作为可重新访问的文件对象；它保留页面布局，但并未证实用户或模型能对同一文档执行结构化增量编辑。聊天中的生成图片仍属于消息内投影；除非进入上述文件或 Artifact 表面，否则在本类目中不构成独立运行对象。

XLSX 预览还会解析 drawing/chart XML，把 bar、line、pie、area 图表映射为 ECharts；不支持的散点等类型保留占位与原始类型名，图表锚点数量和引用单元格数均有限额。解析在 worker 内完成，ECharts 实例在组件卸载时释放。依据：`packages/file-preview/src/plugins/spreadsheet/worker/chartXmlParser.ts`、`charts/EchartsChartRenderer.ts:10-36`。

PDF 翻译的结果会进入翻译历史与文件管理器，可作为可重新访问的文件对象；它保留页面布局，但并未证实用户或模型能对同一文档执行结构化增量编辑。聊天中的生成图片仍属于消息内投影；除非进入上述文件或 Artifact 表面，否则在本类目中不构成独立运行对象。

## 12. 测试、已确认边界与未验证事项

- 单元测试覆盖组件与服务两级，集中在这些对象上：
  - iframe 沙箱属性与 CSP：`CodeBlockView/__tests__/HtmlPreviewFrame.test.tsx`
  - webview 附加时主进程强制沙箱、拒绝危险源：`MainWindowService.test.ts:233-300`
  - artifact 请求白名单：`src/main/utils/__tests__/htmlArtifactRequest.test.ts`
  - 分类与流式表面切换：`markdown/__tests__/CodeBlock.test.tsx`，含其中的 MessageHtmlArtifact 分支
  - 编辑保存载荷：`homeMessageListAdapter.test.tsx:625`
  - 自动保存与冲突：`hooks/__tests__/useFileEditSession.test.tsx`
  - report_artifacts 投影：`agentRightPaneProjection.test.ts`
- 未发现覆盖"生成→展示→编辑→保存→重开"整链的端到端测试（`tests/e2e/` 仅 app-launch）。
- 未运行验证：HTML artifact 实际渲染、同意流程交互、webview 执行行为、Pyodide 执行、自动保存/冲突对话框——本次仅静态确认入口、状态与事件绑定；视觉效果与平台行为（Windows/macOS）未验证。
- 未覆盖/超出范围：`v2-refactor-temp/` 阶段代码、MiniApp webview（`persist:webview` 分区为自定义应用，非模型输出）、知识库文件处理 artifact（`knowledge.ts` 中为内部处理产物，非生成式输出）、MCP 工具调度。

## 13. 设计取舍与能力定级

- **取舍**：HTML artifact 无独立 part 类型/对象 ID，换取"模型只需输出普通 Markdown"的协议零成本；对象身份退化为位置派生 ID，代价是无对象级查询与补丁。安全上宁可 fragment 恒禁脚本、document 须显式同意、artifact 资源走 DNS 级 SSRF 防护，把模型输出当作不可信输入处理。agent 侧选择"文件即对象"——工作区磁盘作为共享状态，用户与模型通过同一文件系统协作，避免复制状态，但冲突处理只有写时版本校验，无三方合并。
- **能力等级**：G3（可执行 Artifact：同意后 HTML 进沙箱 webview 可交互；Python 可执行）与 G4（可编辑工作区：agent 工作区文件树+编辑器+自动保存+冲突处理+模型持续维护同一磁盘对象）同时成立。G5 不具备——模型感知靠通用文件工具而非对象状态协议，chat 内 artifact 无跨会话身份。协议开放度：自由文本探测+工具声明（无 typed part）；更新粒度：整段/整文件覆盖；持续维度：文件为跨会话项目资产、chat artifact 为会话级文本；闭环程度：agent 侧"查询->读取->定向修改"成立，chat 侧仅历史重入。
- **已确认边界**：agent 会话消息中的代码块不可编辑（`agentMessageListAdapter.tsx` 未提供 `saveCodeBlock`，`editable` 恒 false）；chat 主界面右侧 pane 无 artifact 面板（右 pane 为话题分支/追踪，`pages/home/Chat.tsx:335-341`）；mindmap/思维导图组件本次未找到（全 renderer 检索 `mindmap|markmap|mind-map` 无结果）。

## 14. 关键源码索引

- 消息渲染到 artifact 的开关：`src/renderer/components/chat/messages/blocks/MessagePartsRenderer.tsx:504-507`
- HTML 分类与保护：`src/renderer/components/chat/messages/markdown/plugins/remarkHtmlArtifact.ts`
- 聊天内 artifact 视图与同意门：`src/renderer/components/chat/HtmlArtifactView.tsx`
- iframe 沙箱/CSP 常量：`src/renderer/components/CodeBlockView/HtmlPreviewFrame.tsx`
- 弹窗编辑器：`src/renderer/components/CodeBlockView/HtmlArtifactsPopup.tsx`
- 保存回调：`src/renderer/pages/home/messages/homeMessageListAdapter.tsx:460-489`、`src/renderer/utils/markdown.ts:162-189`
- webview 安全：`src/main/services/MainWindowService.ts:268-323`、`src/main/utils/htmlArtifactRequest.ts`、`src/main/utils/remoteUrlSafety.ts`
- agent 产物声明与投影：`src/shared/ai/builtinTools.ts:531-549`、`src/renderer/components/chat/messages/tools/agent/ReportArtifacts.tsx`、`src/renderer/pages/agents/components/AgentRightPane/agentRightPaneProjection.ts:474-543`
- 文件工作区 pane：`src/renderer/components/chat/panes/ArtifactPane.tsx`、`useArtifactFileTreeModel.ts`、`useFileEditSession.ts`
- 文件树 watcher：`src/main/services/file/tree/builder.ts`、`DirectoryTreeManager.ts`、`src/renderer/hooks/useDirectoryTree.ts`
- Python 执行：`src/renderer/services/PyodideService.ts`、`src/main/services/PythonService.ts`、`src/main/ai/mcp/servers/python.ts`
- Agent 运行时驱动：`src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts`、`agentSessionWarmup.ts`
- 系统工作区路径：`src/main/data/services/AgentWorkspaceService.ts:47-56`
