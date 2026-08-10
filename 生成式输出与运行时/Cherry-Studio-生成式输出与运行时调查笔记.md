# Cherry Studio 生成式输出与运行时调查笔记

> 调查对象：`../../cherry-studio`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`0001d730aeaf26b8d68baeeb54f258851e7a2aec`（分支：`main`）
>
> 调查方式：静态代码阅读（grep/glob 检索 + 关键实现文件通读），辅以仓库内单元测试作为行为佐证；未构建、未运行应用
>
> 调查范围：聊天内 HTML Artifact（检测、预览、沙箱 webview、编辑、持久化）、Agent 会话工作区文件（文件树、预览、编辑、自动保存、模型回流）、代码执行（Pyodide/PythonService）、特殊视图与文件预览投影；排除 MiniApp webview、MCP 工具调度语义、通用文件管理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的输出对象分两条主链：(1) 聊天内 HTML Artifact——模型以 Markdown 文本或裸 HTML 形式输出，前端用内容探测（`classifyHtmlArtifactSource`）识别为 `document`/`fragment`，fragment 走无脚本 iframe，document 经用户同意后进入独立沙箱 webview（`html-artifact-preview` 分区，主进程强制 sandbox/contextIsolation/无 preload，网络请求受 DNS 级 SSRF 防护），可编辑、保存（全量重写消息 text part）、下载、外部打开、PNG 截图；(2) Agent 工作区——Claude Code SDK 以 `cwd=session.workspace.path` 在本机执行，产物即磁盘文件，`report_artifacts` 工具调用作为声明投影到消息卡片与右侧 pane（chokidar 实时文件树 + FilePreview + CodeEditor 防抖自动保存 + 写时冲突检测），用户编辑后的磁盘文件在下一回合被模型通过文件工具自然回流。Python 代码块可经 Pyodide Web Worker 执行（另有 MCP `python_execute` 工具）。

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
  -> ClaudeCodeRuntimeDriver 以 cwd=workspace.path 调 claude-agent-sdk query()
  -> 模型用文件工具写磁盘；REPORT_ARTIFACTS_PROMPT 提示结束时调 report_artifacts
  -> report_artifacts tool part 持久化 -> 消息内产物卡片 + 右 pane 文件树（实时 watcher）
  -> 点击文件 -> ArtifactPane 预览/编辑 -> useFileEditSession 防抖自动保存（乐观锁）
  -> 磁盘即真相；下一回合模型读盘 -> 修改 -> 再声明（持续维护闭环）
```

主链路 C（Python 执行）：python 代码块 Run 按钮（偏好 `chat.code.execution.enabled`，默认 false）→ `pyodideService.runScript` → `src/renderer/workers/pyodide.worker`（Web Worker，渲染进程内）→ 结果文本/图片显示在代码块 StatusBar，不持久化。

## 1. 触发方式、输出协议与对象模型

- **触发**：无独立协议。HTML artifact 由模型自由文本（```html 围栏或裸 HTML 节点）触发，靠内容探测识别：`classifyHtmlArtifactSource` 在 `src/renderer/components/chat/messages/markdown/plugins/remarkHtmlArtifact.ts:35` 用正则判定 `document`（`<!doctype` / `<html>`）或 `fragment`（`<div` 式闭合开标签）；半截流（`<!doc`、`<di`）返回 `undefined`，渲染器选择"先不渲染、等几个字符再定型"（`remarkHtmlArtifact.ts:29-41`、`CodeBlock.tsx:105`）。误触发防护：`remarkHtmlArtifact` 只把顶层裸 HTML 区域重写为 code 节点，行内 HTML 留在 Markdown 树里（`remarkHtmlArtifact.ts:184-212`）；`transformMarkdownOutsideHtmlArtifacts` 用占位符保护 artifact 源文本不被预处理污染（`remarkHtmlArtifact.ts:150-177`）。
- **输出协议与对象模型**：消息正文就是 AI SDK `UIMessage.parts`（`src/shared/data/types/message.ts:136`），自定义 part 类型只有 error/translation/video/compact/agent-task-event 等（`src/shared/data/types/uiParts.ts:119-130`），**没有 artifact part 类型**——HTML artifact 以 text part 承载。`artifactId` 为 `${blockId}:${codeBlockId}`，`codeBlockId` 由 Markdown 节点行列偏移派生（`src/renderer/utils/markdown.ts:162`），是每次渲染重算的派生身份，仅用于在列表项重挂载时保住已打开的弹窗会话（`src/renderer/components/chat/HtmlArtifactView.tsx:60-61` 注释），无持久对象 ID。Agent 侧 `report_artifacts` 是 zod 校验的结构化工具输入（`src/shared/ai/builtinTools.ts:531-549`），以 tool part 持久化，是最接近"输出声明"的协议；声明只含 path/description/summary，不含对象 ID 或版本。
- **事实源**：chat 消息行（SQLite `data` JSON）是消息文本的事实源；agent 文件的事实源是磁盘，消息只存声明与执行记录。

## 2. 增量生成、更新与最终化

- 聊天文本逐 token 流式：`MessageProcessLayout` 在活动消息上注入 `inlineHtmlPreviewMode: 'generating'`（`src/renderer/components/chat/messages/blocks/MessagePartsRenderer.tsx:1203`），完成态回落为 `'ready'`（`MessagePartsRenderer.tsx:504-507`，仅 assistant + status success）。
- 流式中 artifact 的 HTML 按 250ms 节拍重灌 iframe srcDoc（`useStreamingPacedHtml`，`HtmlArtifactView.tsx:326-344`），避免每 token 全量重解析；完成后的 HTML 原样直通（`HtmlArtifactView.tsx:324`）。
- 分类为 `document` 且流式未完时先以只读 CodeBlockView 展示，完成后才进入 gate（`CodeBlock.tsx:107-118`）。fragment 恒实时渲染。
- **更新/编辑粒度**：整段覆盖。代码块编辑保存走 `updateCodeBlock`（remark-parse 后按位置 ID 找到 code 节点整体替换，再 remark-stringify，`src/renderer/utils/markdown.ts:179-189`），最终 `editMessage` 整体写回 text part（`src/renderer/pages/home/messages/homeMessageListAdapter.tsx:460-489`）。无 patch/diff/AST 级更新协议。
- Agent 文件由模型经 CLI 文件工具直接写磁盘（全量文件写），无 host 侧 diff 应用层。
- 失败收口：artifact 渲染失败/`undefined` 分类时以 `kind` 默认 `document` 收紧（`MessageHtmlArtifact.tsx:22`，"fail closed"）；编辑保存失败走 toast + 保留原文（`homeMessageListAdapter.tsx:483-485`）。

## 3. 投影表面与多视图关系

| 表面 | 承载 | 位置 |
|---|---|---|
| inline（消息内） | `HtmlArtifactView` 自适应高度预览、`HtmlArtifactsCard` 卡片 | `CodeBlock.tsx:120-139` |
| 全屏弹窗 | `HtmlArtifactsPopup`（preview/code/split 三模式、缩放、截图、下载、外部打开） | `CodeBlockView/HtmlArtifactsPopup.tsx` |
| 消息内产物卡片 | `ReportArtifacts`（agent 交付物列表，点击进右 pane） | `src/renderer/components/chat/messages/tools/agent/ReportArtifacts.tsx` |
| sidecar（agent 右 pane） | `ArtifactPaneView`：文件树 + 选中文件 overlay 预览/编辑 | `src/renderer/components/chat/panes/ArtifactPane.tsx` |
| 独立标签页 | `/app/file-preview?path=...`（`FilePreviewPage`），`useOpenFilePreviewTab` 归一化路径复用 tab | `src/renderer/pages/filePreview/FilePreviewPage.tsx`、`components/FilePreview/hooks/useOpenFilePreviewTab.ts` |
| 外部 | 系统浏览器打开临时 HTML 文件、外部代码编辑器（`OpenExternalAppButton`、`buildEditorUrl`） | `HtmlArtifactView.tsx:799-808`、`ArtifactPane.tsx:349-398` |

同一对象多投影同步：chat artifact 的弹窗预览与消息内预览共用同一份 `html` prop，通过 `HtmlArtifactPopupContext` 的 `syncPopup` 在渲染期同步（`HtmlArtifactView.tsx:706-720, 822-831`）；`approvedInteractiveHtmlById` 以 artifactId→HTML 精确匹配记住"已同意交互预览"（`HtmlArtifactView.tsx:763`），HTML 内容变化即失效。agent 文件树与编辑器是同一磁盘状态的两份投影，文件树靠主进程 watcher 推送增量事件保持新鲜（见第 10 节）。

## 4. 表现类型、依赖与运行环境

- **HTML artifact 分级运行**：
  - fragment / 未同意交互的 document：`AdaptiveHtmlPreview`——iframe `sandbox="allow-same-origin"`（仅用于父级读 `contentDocument` 测量高度）+ 严格 CSP `HTML_PREVIEW_RESTRICTED_CSP`（`default-src 'none'`，仅 data/blob/file 静态资源），无脚本（`src/renderer/components/CodeBlockView/HtmlPreviewFrame.tsx:21-28, 465-471`）。
  - 同意后的 document：`InteractiveHtmlPreview`——Electron `<webview>` 加载 `data:text/html;charset=utf-8,` 编码后的完整文档（注入高度/滚轮桥接脚本，`HtmlArtifactView.tsx:115-194, 530-535`）。主进程在 `will-attach-webview` 强制 `sandbox=true、contextIsolation=true、nodeIntegration=false、删 preload、webSecurity=true`，只接受 data: URL 前缀，拒绝 window.open，导航只允许 data: 前缀（`src/main/services/MainWindowService.ts:292-323`）。分区会话 `html-artifact-preview` 全部权限请求拒绝、禁下载、`onBeforeRequest` 用 `isAllowedHtmlArtifactRequest` 拦截（`MainWindowService.ts:268-290`）。
  - 文件预览 HTML：`FilePreview` 的 `type='file'` 用空 sandbox（禁脚本）+ 严格 CSP；`type='artifact'`（仅 agent 工作区）用 `allow-scripts allow-same-origin allow-forms`（`src/renderer/components/FilePreview/plugins/html/HtmlFilePreview.tsx:24-32`，`FilePreview/README.md` 明确"不要把任意本地文件标为 artifact"）。
- **同意判定**：`htmlArtifactRequiresUserConsent` 用 htmlparser2 静态扫描 script/iframe/object/embed、on* 属性、javascript:/外部 URL、meta refresh、CSS url()（含 CSS 转义解码）（`src/renderer/utils/htmlArtifact.ts:49-106`），解析失败 fail-closed。
- **图表**：Mermaid（mermaid 库）、Graphviz/viz-js、PlantUML、SVG 均为静态渲染 + shadow DOM 挂载（`src/renderer/components/Preview/`、`CodeBlockView/constants.ts:7`），无交互、无对象身份，留在消息渲染器类目。
- **代码执行**：仅 `python` 语言且偏好开启时，`pyodideService.runScript`（`src/renderer/services/PyodideService.ts:136-188`）在 Web Worker 内执行，超时默认 60s、初始化重试 5 次、`resetWorker` 可重置（`PyodideService.ts:234-244`）；matplotlib 输出图片经 `output.image` 显示。主进程侧 `PythonService` 通过 IPC 桥接同一 worker，供 MCP 工具 `python_execute` 调用（`src/main/services/PythonService.ts`、`src/main/ai/mcp/servers/python.ts`）。
- **Agent 执行环境**：`ClaudeCodeRuntimeDriver` 用 `@anthropic-ai/claude-agent-sdk` 的 `query()` 在会话工作区 `cwd` 上运行（`src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:3-11, 1297-1298`），是"Agent 工具/执行"类目边界，此处只作为产物的产生方记录；其 Bash 工具等调度语义不展开。

## 5. 用户交互、事件与错误反馈

- 交互面：预览缩放（50%-200%）、预览/源码切换、分屏、全屏、PNG 截图（文件/剪贴板，需 `allow-same-origin` 读 contentDocument，`HtmlArtifactsPopup.tsx:148-176`）、下载、外部打开、同意交互预览。
- 高度自适应：iframe 通过 ResizeObserver/MutationObserver 测高（`HtmlArtifactView.tsx:363-452`）；webview 通过注入脚本 console-message 桥上报 height/wheel（`HtmlArtifactView.tsx:196-206, 542-567`）；滚轮经 `ScrollOwnershipContext` 边界转发，避免内嵌文档吞掉消息列表滚动（`HtmlArtifactView.tsx:267-308`）。
- 错误反馈：渲染错误经 logger+toast；文件预览有 loading/too_large/read_error/empty 分级状态（`HtmlFilePreview.tsx:34-92`）；编辑保存失败提示重试/丢弃（`ArtifactPane.tsx:603-634`）。
- 交互状态恢复：弹窗会话可在列表项重挂载间存活（artifactId 派生身份），但**未发现**跨会话/跨重载的 artifact 视图状态持久化（缩放、弹窗开合均为运行时状态）。

## 6. 编辑、diff、版本与协作

- **chat 内代码块/artifact**：CodeEditor 可编辑（偏好 `chat.code.editor.enabled`，默认 false；流式中禁编辑），保存即全量覆盖消息文本；无 diff、无接受/拒绝、无撤销。
- **agent 工作区文件**（`useFileEditSession`，`src/renderer/hooks/useFileEditSession.ts`，VS Code TextFileEditorModel 形态）：
  - 防抖 800ms 自动保存；写循环串行化（单模型单 in-flight，`useFileEditSession.ts:248-260`）；
  - 乐观锁 `file.write_if_unchanged`（expectedVersion），STALE_VERSION 时读盘验证：内容相同则采纳、仅元数据变动则 rebase 重试（上限 3 次）、真冲突则暂停自动保存并弹"重载/保留草稿"对话框（`useFileEditSession.ts:170-241, 762-771`）；
  - watcher 事件从不覆盖脏草稿；编码/BOM/CRLF 保留（`fileTextSnapshot`）；离开脏编辑有确认（`AgentRightPane.tsx:414-456`）。
  - 用户与模型对同一文件无结构化合并：模型写盘、用户编辑自动保存，冲突时用户侧检出版本冲突并选择重载或保留草稿。
- 无 CRDT、无分支、无对象级版本历史（文件系统版本由 `FileVersion`(mtime/size) 提供比较基础，无历史栈）。

## 7. 能力桥、执行位置与权限范围

- **HTML artifact webview**：隔离的 Electron 分区 + 沙箱 webview，无 preload，无 IPC 桥（不能调 window.api）；唯一"桥"是 console-message 通道上的 height/wheel 结构化消息（`HtmlArtifactView.tsx:108-114`，用随机前缀防伪造）。网络：`isAllowedHtmlArtifactRequest` 只放行 data:/blob: 与通过 `sanitizeRemoteUrl` 的 https URL——后者解析 DNS 并拒绝 localhost/私网/多播/保留网段（SSRF 防护，`src/main/utils/remoteUrlSafety.ts:21-51`）；权限请求（摄像头等）全拒、下载禁止。
- **fragment iframe**：无脚本（空 sandbox + CSP），同源仅用于测高。
- **Pyodide worker**：渲染进程内 Web Worker，无 Node 集成；能力仅 Python 运行时自身（标准库+科学包），文件/网络受限（未在本快照中查证 worker 内是否开放网络，见未验证事项）。
- **agent 文件投影**：FilePreview `type='file'` 严格沙箱；`type='artifact'` 授予脚本权限（`HtmlFilePreview.tsx:24-32`）。外部编辑器/系统浏览器打开是宿主文件能力（`window.api.file.*`），属正常桥接。

## 8. 持久化、恢复、分享与导出

- chat artifact：源文本存于消息 `data.parts`（SQLite）；编辑后 `editMessage` 写回；重开会话从 DB 重读并重新渲染。分享/导出：下载 `.html`（`window.api.file.save`）、临时文件外部打开、PNG 截图、剪贴板；消息图片导出时 `data-html-artifact` 被显式排除（`src/renderer/utils/image.ts:192-193`）。
- agent 文件：磁盘即持久化，跨会话存活；系统工作区位于托管根目录按日期+sessionId 生成（`AgentWorkspaceService.buildSystemWorkspacePath`，`src/main/data/services/AgentWorkspaceService.ts:47-56`），用户工作区为任意绝对路径（DB 实体，`agentWorkspace` 表）。文件树展开态/选中态为渲染器状态，随 workspace 切换重置（`ArtifactPane.tsx:849-872`）。
- 无 artifact 对象的复制/分享/删除协议（文件本身可复制删除）。

## 9. 模型回流、对象感知与持续维护

- **chat 内 artifact**：编辑后的文本回到消息行，下回合作为历史上下文进入模型——回流通道是"会话历史重入"，不是对象查询。模型无法列出/定位具体 artifact（无 ID 协议），也无法对其定向 patch；每回合输出新 HTML 即新"副本"。
- **agent 工作区**：闭环存在且是"磁盘态"回流——模型用文件工具（Read/Glob/Edit/Write）直接感知磁盘当前状态（含用户编辑），`report_artifacts` 声明在会话中重复调用即可更新交付物列表（右 pane 按 path 去重，`agentRightPaneProjection.ts:474-503`）；会话跨回合续跑（resume token、steer、后台任务，`AgentRuntimeConnection`/`AgentSessionRuntimeService`），对象身份绑定在"路径+会话工作区"而非对象 ID。
- 产物卡片点击 → 右 pane 打开文件（`AgentRightPane.tsx:294-320`）→ 用户编辑 → 模型下回合读到 → 形成"查询->读取->定向修改"的自然闭环。

## 10. 生命周期、资源治理与性能

- 文件树：主进程 `DirectoryTreeBuilder` + chokidar watcher，初始扫描后再应用 watcher 事件（背压处理），共享 watcher 去重（`src/main/services/file/tree/builder.ts:19-20, 225-227`、`DirectoryTreeManager.ts`）；缺失根目录可 `watchMissingRoot` 等待出现（`builder.ts:212-218`）。渲染端镜像按事件增删改（`useDirectoryTree.ts:46-84`）。
- webview：分区会话随应用生命周期注册/释放（`setupHtmlArtifactPreviewSession` 的 `registerDisposable`）；`did-attach-webview` 拦截导航；未发现按可见性冻结/卸载 artifact 预览的机制（iframe 一直挂载，仅流式节拍降低重建频率）。
- Pyodide：单例 worker，终止时拒绝所有挂起请求；超时清理；模块状态跨次执行保留（可 reset）。
- 限额：HTML 文件预览上限 2MB（`HtmlFilePreview.tsx:21-22`）；文件编辑上限 2MB（`useFileEditSession.ts:21`）；artifact 预览高度上限为视口 72%（`HtmlArtifactView.tsx:54`）；长会话（agent）有 compaction/上下文用量管理，属 Agent 类目不展开。

## 11. 测试、已确认边界与未验证事项

- 单元测试覆盖：iframe 沙箱属性与 CSP（`CodeBlockView/__tests__/HtmlPreviewFrame.test.tsx`）、webview 附加时主进程强制沙箱/拒绝危险源（`MainWindowService.test.ts:233-300`）、artifact 请求白名单（`src/main/utils/__tests__/htmlArtifactRequest.test.ts`）、分类与流式表面切换（`markdown/__tests__/CodeBlock.test.tsx`、`CodeBlock.test.tsx` 内 MessageHtmlArtifact 分支）、编辑保存载荷（`homeMessageListAdapter.test.tsx:625`）、自动保存/冲突（`hooks/__tests__/useFileEditSession.test.tsx`）、report_artifacts 投影（`agentRightPaneProjection.test.ts`）。均属组件/服务级，未发现覆盖"生成→展示→编辑→保存→重开"整链的端到端测试（`tests/e2e/` 仅 app-launch）。
- 未运行验证：HTML artifact 实际渲染、同意流程交互、webview 执行行为、Pyodide 执行、自动保存/冲突对话框——本次仅静态确认入口、状态与事件绑定；视觉效果与平台行为（Windows/macOS）未验证。
- 未覆盖/超出范围：`v2-refactor-temp/` 阶段代码、MiniApp webview（`persist:webview` 分区为自定义应用，非模型输出）、知识库文件处理 artifact（`knowledge.ts` 中为内部处理产物，非生成式输出）、MCP 工具调度。

## 12. 设计取舍与能力定级

- **取舍**：HTML artifact 无独立 part 类型/对象 ID，换取"模型只需输出普通 Markdown"的协议零成本；对象身份退化为位置派生 ID，代价是无对象级查询与补丁。安全上宁可 fragment 恒禁脚本、document 须显式同意、artifact 资源走 DNS 级 SSRF 防护，体现"模型输出即不可信输入"的基线。agent 侧选择"文件即对象"——工作区磁盘作为共享状态，用户与模型通过同一文件系统协作，避免复制状态，但冲突处理只有写时版本校验，无三方合并。
- **能力等级**：G3（可执行 Artifact：同意后 HTML 进沙箱 webview 可交互；Python 可执行）与 G4（可编辑工作区：agent 工作区文件树+编辑器+自动保存+冲突处理+模型持续维护同一磁盘对象）同时成立。G5 不具备——模型感知靠通用文件工具而非对象状态协议，chat 内 artifact 无跨会话身份。协议开放度：自由文本探测+工具声明（无 typed part）；更新粒度：整段/整文件覆盖；持续维度：文件为跨会话项目资产、chat artifact 为会话级文本；闭环程度：agent 侧"查询->读取->定向修改"成立，chat 侧仅历史重入。
- **已确认边界**：agent 会话消息中的代码块不可编辑（`agentMessageListAdapter.tsx` 未提供 `saveCodeBlock`，`editable` 恒 false）；chat 主界面右侧 pane 无 artifact 面板（右 pane 为话题分支/追踪，`pages/home/Chat.tsx:335-341`）；mindmap/思维导图组件本次未找到（全 renderer 检索 `mindmap|markmap|mind-map` 无结果）。

## 13. 关键源码索引

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
