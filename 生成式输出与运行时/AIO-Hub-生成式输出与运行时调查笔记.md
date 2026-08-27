# AIO Hub 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`（分支：`dev`）
>
> 调查方式：静态代码阅读。对 `src/tools/llm-chat`、`src/tools/rich-text-renderer`、`src/tools/web-canvas`、`src/tools/tool-calling`、`src/tools/media-generator` 等目录做关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、preview、stream、CSP 等）并精读关键实现文件；对照工具自带 ARCHITECTURE.md；抽查 Rust 命令与 Tauri 配置；未运行构建、未启动应用、未运行测试
>
> 调查范围：模型输出从"消息文本/工具结果"到"可展示、可运行、可编辑、可持久化、可回流对象"的完整链路；覆盖聊天消息物化、HTML 代码块沙箱、web-canvas 工作区、媒体生成资产入库、工具调用结果节点、执行位置与 CSP、持久化与回流；普通 Markdown 渲染细节、Chat 发送/中止/分支语义、工具注册与审批调度本身（仅记录交接点）排除在外；移动端只做概览
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的生成式输出呈现**双层结构**：聊天层把模型输出保持为“消息树节点上的纯文本字符串”，在展示时由 `RichTextRenderer` 动态解释为 Markdown、Mermaid、KaTeX 和 HTML 沙箱；工作区层则提供 web-canvas，一个以磁盘文件为事实源、Git 为版本追踪的 Agent 协作工作区。模型可以查询、读取、修改和提交文件，独立预览窗口捕获的运行时错误也会同步回主窗口并进入后续 Agent 上下文。静态代码已经贯通“修改 -> 预览 -> 报错 -> 回流 -> 再修改”，但真实窗口、网络和 Tauri WebView 行为仍未运行验证。

- **聊天输出对象模型**：消息节点（`ChatMessageNode`）有稳定 ID、来源、角色、状态与丰富元数据，但内容只是一段 `content: string`，不存在独立的 Artifact 对象；HTML 代码块在展示时进入 iframe 沙箱（`HtmlInteractiveViewer`）成为可运行预览，属"展示时物化"，无独立生命周期。
- **web-canvas**：`{appDataDir}/canvases/projects/{id}/` 下的物理项目、`.canvas.json` 元数据和独立 Git 仓库构成持久对象。Monaco 编辑以 500ms 防抖写盘；审批前的 Agent 写入或 diff 先重放到不落盘的内存覆盖层，批准后才正式写盘一次，拒绝只移除候选层，不改变已有工作区。预览 iframe 会内联候选 HTML/CSS/JS，并同步显示（`CanvasAgentService.ts:358-415`、`useCanvasPreview.ts:39-87`）。
- **工具结果**：工具调用先经过 `ToolCallingProtocol` 表示层；当前快照的协议注册表只登记 VCP 一种实现，所以实际使用 VCP 文本标记 `<<<[TOOL_REQUEST]>>>`。解析执行后，结果被格式化为文本写入"tool 角色"消息节点内容，随会话 JSON 持久化；结果本身不物化为独立对象，但 web-canvas 的文件操作结果会直接落到物理文件。当前 VCP 是实现范围，不是工具系统的架构上限。
- **持久化**：聊天会话按会话独立 JSON 文件存储；画布为物理文件 + Git；媒体生成结果通过 `importAssetFromBytes` 进入资产管理系统并带生成来源元数据。
- **执行位置**：生成代码在 Tauri WebView 的 iframe 中执行；无远端沙箱、容器或独立语言进程。聊天 HTML 与 canvas 预览分别注入自己的 CSP。canvas iframe 只授予 `allow-scripts`，形成 opaque origin，宿主还校验 `event.source` 与 `origin === "null"`；其 CSP 仍允许 HTTP(S)、WebSocket、外部 frame 和 asset 资源，能力边界见第 7 节。

横向对比轴（桌面端）：

| 轴 | 聊天层 | web-canvas |
|---|---|---|
| 协议开放度 | 自由文本 + 当前 VCP 标记 + 富文本 AST（`ToolCallingProtocol` 可在代码级替换） | 工具方法元数据（`agentCallable`） |
| 更新粒度 | 整段文本重解析（稳定区/待定区 patch） | Search/Replace diff（exact/trimEnd/trim/fuzzy） |
| 投影表面 | inline（消息内）+ 弹窗 + 分离窗口 | 工具页项目列表/Monaco 编辑器 + 独立 Tauri 预览窗口；工具页无内嵌运行预览 |
| 执行强度 | HTML/CSS/JS 浏览器脚本（iframe 沙箱） | 同左，入口文件加载本地 `asset://` 资源 |
| 持续性 | 会话文件（跨会话可恢复） | 物理项目 + Git（长期活对象） |
| 闭环程度 | 只生成 + 可编辑消息 + 可续写/重解析 | 文件查询/读写/提交成立；预览错误经窗口总线回流 Agent 上下文，可继续修改 |
| 能力范围 | 无桥接（iframe 只回传日志/高度） | 工具方法调用（读文件、写文件、提交、Git） |
| 可移植性 | HTML 预览可"在浏览器中打开"导出单文件 | 可提交 Git、可在 VSCode 中打开 |

**能力等级认定**：综合 **G4（可编辑工作区）**。web-canvas 有稳定项目 ID、物理文件、Git、候选预览和运行错误回流，具备若干 G5 原料；但运行实例和审批候选层都不持久，也没有后台持续维护或跨会话自主调度，因此当前快照的 **G5 证据仍不足**。聊天内 HTML 代码块沙箱为局部 G3，其余聊天输出停留在 G0–G1。

### 剩余边界

1. **审批预览为瞬时内存覆盖层。** 预览钩子登记 mutation 并重建候选文件映射，不调用正式写入；批准后 executor 只执行一次真实方法，完成或失败后消费候选记录，拒绝则移除该请求并重算其余候选。候选层不持久化，应用重启或窗口异常关闭后的预览恢复未验证（`CanvasAgentService.ts:299-415`、`canvasStore.ts:580-640`）。
2. **运行时错误链已静态贯通。** 预览窗口把校验后的错误通过 `canvas:runtime-error` 全量消息发送，主窗口总线再次校验、裁剪并写入按 canvasId 管理的错误 store；`getExtraPromptContext()` 再把绑定画布的错误摘要交给 Agent。跨窗口时序、重复去重和真实脚本报错仍需运行验证（`CanvasWindow.vue:176-202`、`useCanvasSync.ts:113-151`、`CanvasAgentService.ts:32-108`）。
3. **外部文件变更进入当前画布监听。** Store 打开画布后递归 watch 项目目录，忽略 `.git` 与元数据文件，对其余变更做 300ms 合并，刷新 Git 状态、标记旧错误并广播文件变化。监听器一次只绑定一个当前画布，多个窗口或快速切换项目的实际行为未验证（`canvasStore.ts:118-173`、`useCanvasStorage.ts:163-176`）。
4. **编辑与状态按目标绑定。** Monaco 防抖任务捕获 `canvasId + filepath + content`，提交前 flush、丢弃时 cancel，组件卸载会释放文件变化监听；Git dirty 状态保存在 `dirtyFilesByCanvas`，Agent 上下文按绑定 canvasId 读取（`CanvasEditorPanel.vue:127-205`、`canvasStore.ts:94-116`）。用户与 Agent 仍没有 revision、CRDT 或冲突合并，实际并发写入遵循最后写入者。
5. **文件和 iframe 边界已收紧。** 存储层拒绝绝对路径、盘符、空段、`.`、`..` 和 NUL，再把规范化相对路径拼入画布根目录。预览 iframe 只启用脚本、使用 opaque origin，并注入禁止 object/form 的 CSP；宿主校验消息来源、origin、类型与长度。CSP 仍允许 HTTP(S)、WebSocket、外部 frame 与 asset 资源，网络访问不是默认封闭（`useCanvasStorage.ts:43-75`、`CanvasPreviewPane.vue:23-135`、`useCanvasPreview.ts:233-251`）。
6. **存在专项回归测试但没有完整窗口 E2E。** `web-canvas.test.ts` 覆盖相对路径拒绝、内存候选层、HTML/CSS/JS 候选内联、拒绝不回退 HEAD、批量审批预览只分发一次和正式方法只执行一次。真实 Tauri 窗口、文件 watcher、CSP、运行错误回流和 Git 恢复仍未由该单测覆盖。

## 系统边界与完整主链路

本类目在 AIO Hub 中由三个物理区域承担：

1. **聊天层**（`src/tools/llm-chat` + `src/tools/rich-text-renderer`）：模型文本流 -> 消息节点 -> 富文本渲染 -> 内嵌 HTML 沙箱/图表/代码块；消息可编辑、可分支、可重解析。
2. **画布层**（`src/tools/web-canvas`）：Agent/用户围绕磁盘项目协作，模型经工具调用直接改文件，Git 追踪版本，iframe 预览并回传运行时错误。
3. **资产层**（`src/composables/useAssetManager` 等）：媒体生成等产物物化为带元数据的 Asset，可被消息引用（`agent-asset://`、`【file::id】` 占位符）。

**主链一（聊天，静态确认）**：用户在 `ChatArea` 发送后，编排器创建 assistant 节点，执行器流式请求，响应处理器把 chunk 同时写入节点内容与可重放流源；渲染器以 AST patch 增量更新，HTML 代码块进入 `HtmlInteractiveViewer` iframe 沙箱。消息可"编辑"（`useBranchManager.editMessage`，`useBranchManager.ts:108`）或"保存到分支"，最后由会话管理器落盘（`useChatStorageSeparated.ts:496`）。重新打开会话时从会话 JSON 文件加载（见第 8 节），HTML 预览从内容重新生成。链路各环节均有源码依据；未运行验证。

**主链二（画布，静态确认）**：用户在画布工作台创建项目，服务层 `CanvasService.createCanvas` 从模板复制文件并完成 Git 初始化与首次提交；Monaco 编辑防抖写盘（`CanvasEditorPanel.vue:128`），预览引擎注入 base 标签与日志/错误捕获脚本后以 srcdoc 渲染（`useCanvasPreview.ts:47`）。提交与丢弃、关闭后从索引 `projects.json` 重新打开，均由 canvas store 承担（`canvasStore.ts:402,457,172`）。Agent 侧闭环见第 9 节。

**主链三（工具结果，静态确认）**：assistant 流文本 -> 按 Agent 配置经 `ToolCallingProtocol` 路由（当前为 `VcpToolCallingProtocol`）-> 解析请求 -> `processCycle` 审批 + 执行 -> 结果格式化为文本写入 tool 节点（`useToolCallOrchestrator.ts:310-365`）-> 节点随会话持久化；其中 web-canvas 类方法会直接写物理文件。

## 1. 触发方式、输出协议与对象模型

### 1.1 聊天输出：无独立对象，消息节点即对象

- 触发由用户消息驱动；模型回复文本流式写入 assistant 节点。节点模型 `ChatMessageNode`（`src/tools/llm-chat/types/message.ts:110-416`）带稳定 ID、来源、角色、状态与 `metadata`（模型、Agent、usage、推理内容、翻译、工具调用等）等字段。但**内容唯一载体是 `content: string`**，没有 Artifact/part 类型的结构化输出对象；`type?: MessageType` 只用于"预设消息/历史占位符"，与生成内容无关。
- 与 typed part 类协议相比，聊天内容层采用**自由文本 + 约定标记**：当前 VCP 工具调用块、`<think>` 思考块、HTML 标签、Mermaid 围栏都由渲染器在展示时识别（`rich-text-renderer/ARCHITECTURE.md` §3.2、§5.2），而非发送/存储时的结构化 part。这里的“当前 VCP”只描述工具调用协议的已接入实现，不等于 AIO 的全部输出协议或工具来源。
- 唯一接近"part 语义"的是 `LlmReasoningArtifact`（`src/llm-apis/common.ts` 相关类型，`message.ts:282`），但它是 DeepSeek/OpenAI/Gemini 推理内容的**回放状态**，供上下文压缩后精确重放推理文本，不是可操作输出对象。

### 1.2 工具输出：文本结果节点 + 物理副作用

- `tool-calling` 通过 `ToolCallingProtocol` 把工具元数据、调用请求和执行结果与模型通信表示隔开：接口负责工具定义生成、使用说明生成、请求解析和结果格式化；解析后的统一请求仍由协议外的发现、校验、审批、执行与循环引擎处理（职责链入口 `core/protocols/base.ts`，其余见文末源码索引）。因此增加另一种**文本协议**可以复用现有工具目录与执行策略，但当前不是运行期可注册的协议市场，也没有直接覆盖模型 API 的结构化 `tool_calls`。
- 当前快照只在协议注册表 `SUPPORTED_PROTOCOLS` 登记 `vcp` 一种；`resolveProtocol()` 对现有配置一律路由到 `VcpToolCallingProtocol`，配置字段 `ToolCallConfig.protocol` 也收窄为该值。以下 VCP 标记语法是当前实现事实，不能据此把 AIO 的整体工具架构等同于 VCP。
- 当前 VCP 实现由模型自由文本中的 `<<<[TOOL_REQUEST]>>> ... <<<[END_TOOL_REQUEST]>>>` 标记触发（`src/tools/tool-calling/core/protocols/vcp-protocol.ts`），支持 `TOOL_REQUEST_ESCAPE` 嵌套与转义。
- 执行结果经 `formatCycleResults` 委托当前协议序列化为文本，写入 role 为 `"tool"` 的消息节点（`useToolCallOrchestrator.ts:325-345`），节点 `metadata.toolCalls[]` 记录每个请求的 requestId/工具名/状态/耗时/原始参数。**结果不物化为独立对象**；若工具本身有物理副作用（如画布写文件），结果对象身份在文件侧。
- 工具节点可被"重新解析"（`reparseAndOrchestrate`，`useToolCallOrchestrator.ts:449`），即对已有内容重新走工具调用检测与执行，属于后续回合重入入口。

### 1.3 画布对象模型

- 画布项目有稳定 ID（`cp_{yyyyMMdd}_{shortId}`，`web-canvas/utils/id.ts:22`）、名称、模板、入口文件与创建/更新时间；项目元数据与索引分别落在 `.canvas.json` 与 `projects.json`（`web-canvas/ARCHITECTURE.md` §2）。
- **事实源是磁盘文件 + Git**：常规编辑直接写盘，不使用内存 VFS；审批候选内容例外，只存在于瞬时覆盖层。画布打开后，store 会递归监听当前项目目录，外部编辑器的改动经合并后刷新 Git 状态并通知编辑器和预览（`canvasStore.ts:118-171`、`useCanvasStorage.ts:163-173`）。画布与聊天的衔接有两个用户侧入口：聊天输入区内置"画布控制"（`MiniCanvasControl.vue`，绑定/新建/预览/跳转管理）与输入工具栏的 web-canvas 开关（`MessageInputToolbar.vue:163-196`）；但**没有把聊天中模型生成的 HTML 一键转入画布的通道**（本次未找到此类入口，`rich-text-renderer` 中无 web-canvas 引用）。
- 项目索引与元数据分离、索引可修复（`repairProject`，`canvasStore.ts:511`）。

## 2. 增量生成、更新与最终化

### 2.1 聊天流式

- 逐 token 注入：`useChatResponseHandler` 把流式 chunk 追加到 `node.content`，同时喂给按节点 ID 缓存的可重放流源（`useStreamingMessageSources.ts:20-89`）；渲染器以流式 AST patch 更新，patch 操作形如文本追加、节点替换、后插等（`rich-text-renderer/ARCHITECTURE.md` §3.4）。
- 渲染器内部是**整段文本重解析 + patch**：V2 自研解析器维护"稳定区/待定区"，稳定区复用已有 AST，待定区每次重解析，经 diff 生成 patch（`core/StreamProcessorV2.ts`）。不是按 AST 节点增量生成，也不是外部 diff/patch 协议。
- 最终化：请求完成调用 `completeAndDisposeStreamingMessageSource`（`useChatResponseHandler.ts:503`）；失败走 `handleNodeError`（:647），错误写入节点 `metadata.error` 并在 UI 显示可复制错误条；空响应写入 `emptyResponseDiagnostic` 诊断。
- 网络层流式节流与 VCP 块冲刷由 `core/StreamController.ts` 处理（`rich-text-renderer/ARCHITECTURE.md` §3.4），保证协议块不被平滑拆碎。

### 2.2 画布更新

- Agent 侧：Search/Replace diff 引擎 `applySearchReplaceDiff`（`web-canvas/utils/diff.ts:71`），匹配策略 exact -> trimEnd -> trim -> fuzzy（Bigram Dice，阈值 0.85），支持行号剥离、`start_line` 消歧、缩进修复、重匹配警告；应用结果写盘并刷新 Git 状态（`canvasStore.ts:354-398`）。
- 用户侧：Monaco 以纯 ESM 方式加载（`src/utils/monaco.ts`），编辑内容 500ms 防抖整体写盘。防抖参数会捕获编辑发生时的画布、文件路径和内容；提交前 flush，丢弃时 cancel，组件卸载时先 flush 再 cancel（`CanvasEditorPanel.vue:133-169,214-219`）。
- 应用内部写入通过文件变化事件触发预览刷新与分离窗口通知；当前画布目录的递归 watcher 也会把外部编辑器写入合并为同一类刷新。预览刷新另有 300ms 防抖（`canvasStore.ts:146-171`、`useCanvasPreview.ts:39-87`）。

## 3. 投影表面与多视图关系

| 表面 | 承载对象 | 位置 |
|---|---|---|
| 消息正文 inline | 全部聊天输出（Markdown/图表/HTML 沙箱） | `MessageContent.vue` |
| 弹窗 | HTML 代码块大图预览、Mermaid 悬浮交互、文档查看器 | `CodeBlockNode.vue:108`、`MermaidInteractiveViewer` |
| 分离窗口 | 聊天区（`useDetachedChatArea`）、工具组件、画布预览 | `DetachedWindowContainer.vue`、`canvas_window.rs:45` |
| 工具页 | web-canvas 项目列表、文件树与 Monaco 编辑器；无内嵌运行预览 | `CanvasWorkbench.vue`、`CanvasEditorPanel.vue` |
| 外部浏览器 | HTML 预览导出 | `HtmlInteractiveViewer.vue:636-649`（Blob URL 新窗口打开） |
| 桌面覆盖窗 | 弹幕播放器透明覆盖窗口（非模型输出，记相邻） | `useDanmakuOverlay.ts:146` |

- 同一项目有编辑器与独立预览窗两个表面。跨窗口机制同步活动画布 ID、文件变化通知和审批候选覆盖层；预览窗口捕获的运行时错误会单向回传主窗口。Git 变更集合、编辑器标签和一般运行状态仍是各窗口本地状态。代码还注册了 write/commit/discard 的 action 代理，但当前独立预览 UI 未找到对应编辑/提交入口，因此不能按架构文档把它们计为已暴露交互（`useCanvasSync.ts:63-168`）。
- 聊天消息的"分离"是把整个聊天组件搬到新 WebView 窗口（`useDetachedChatArea.ts`），消息对象本身无多投影。
- 聊天 HTML 预览与画布预览是**两份独立运行时**：前者渲染消息 `content` 中提取的代码块文本，后者渲染磁盘入口文件；彼此无同步。

## 4. 表现类型、依赖与运行环境

- **表现层次**：渲染器 `RichTextRenderer`（`src/tools/rich-text-renderer`）支持 Markdown/GFM、公式、Mermaid 图表、HTML 深度混合排版、可交互按钮、会话变量徽章与思考块等类型，清单如下：

| 类型 | 说明与入口 |
|---|---|
| Markdown/GFM | 表格、Alert 等 |
| KaTeX/MathJax 公式 | 通用公式语法 |
| Mermaid 图表 | `MermaidInteractiveViewer`（缩放/下载/分屏） |
| HTML 深度混合排版 | `GenericHtmlNode`/`HtmlBlockNode`；`<video>`/`<audio>` 拦截为项目播放器、`<details>` 折叠面板、`<style>` 作用域隔离 |
| 可交互按钮 | `ActionButtonNode`，白名单动作 send/input/copy |
| 其他标记 | `<svar>` 会话变量徽章、`<think>` 思考块 |
- **代码块**：CodeMirror 只读查看器（`CodeMirrorSourceViewer.vue`），懒初始化 + `PreCodeNode` 兜底；`html` 语言代码块可切换"预览模式"进入 `HtmlInteractiveViewer` 沙箱（`CodeBlockNode.vue:74-104`），支持内嵌预览 / 弹窗预览 / 无缝模式 / 冻结。
- **HTML 沙箱**（`HtmlInteractiveViewer.vue`）：srcdoc iframe，配置如下表；此外注入日志/错误捕获/交互感知/自适应高度脚本（:335-450）。

| 项 | 配置 |
|---|---|
| sandbox 属性 | `allow-scripts allow-same-origin allow-forms allow-popups allow-modals`（:138） |
| CSP meta | 默认 `default-src 'self' 'unsafe-inline' ...`，允许外部脚本时放宽为 `*`（:320-327） |
| CDN 本地化 | `cdnLocalizer.ts` 把 jsdelivr/cdnjs/unpkg 等替换为本地 `public/libs` |
- **依赖提供**：本地 CDN 资源本地化 + `asset://`/`agent-asset://` 本地资产协议；无语言解释器、无 Python/Node 进程执行。
- **移动端**：`mobile/src/tools/rich-text-renderer/RichTextRenderer.vue` 是 `marked` 的简单渲染器，HTML 块直接 `v-html`，无沙箱、无 iframe 预览、无 Mermaid/KaTeX（概览结论，未逐行核对其余工具）。

## 5. 用户交互、事件与错误反馈

- **HTML 沙箱回传**：iframe 通过 `postMessage` 向宿主回传事件，宿主侧 `handleIframeMessage`（`HtmlInteractiveViewer.vue:517-583`）把 error 级日志收集为 `iframeErrors`（上限 200 条），UI 提供错误浮窗/复制/清空；卸载时清空 srcdoc 并跳转 `about:blank` 释放资源（:596-603）。事件类型：
  - `iframe-log`：console 捕获
  - `iframe-height`：自适应高度
  - `iframe-mousemove`/`enter`/`leave`：悬浮状态
- **画布回传**：独立预览 iframe 回传控制台与运行时错误两类事件。宿主要求消息来自当前 iframe 的 opaque origin，随后校验类型并裁剪字段；窗口内错误 store 负责去重、限流与 stale 标记（`CanvasPreviewPane.vue:67-145`、`CanvasWindow.vue:165-202`）。
- **错误反馈去向**：预览窗口通过窗口总线发送完整的运行时错误消息，主窗口再次校验后写入对应 canvasId 的错误 store；Agent 上下文会读取这个 store。因此静态代码已形成“iframe -> 预览窗口 -> 主窗口 -> Agent”链路，真实窗口通信时序和错误触发效果仍需运行验证（`useCanvasSync.ts:113-151`、`CanvasAgentService.ts:32-108`）。
- **运行状态恢复**：`MessageList.vue` 有 keep-alive 滚动位置恢复（:73-99）；画布分离窗口关闭后重新打开时从磁盘重新加载（`CanvasWindow.vue:137-158`）；弹幕覆盖窗等桌面窗不在本类目。

## 6. 编辑、diff、版本与协作

- **聊天消息编辑**：全文覆盖式编辑（`useBranchManager.editMessage`，`useBranchManager.ts:108-156`），仅限 user/assistant 角色；"保存到分支"复制内容到兄弟节点形成分支（:162-209）。无选区编辑、无结构化 patch、无撤销栈持久化（`useChatStorageSeparated.ts:199-204` 明确移除 history 字段）。版本表达依赖消息树分支语义，属于 Chat 类目，此处只记交接点。
- **画布编辑**：用户与 Agent 修改同一组磁盘文件；Agent 用 Search/Replace diff（含 fuzzy 降级与置信度反馈，`CanvasAgentService.ts:168-190`），用户用 Monaco 全量覆盖，当前画布的外部文件变化由递归 watcher 接入刷新。未发现 CRDT 或基于 revision 的冲突检测，因此并发写入仍以最后写入者为准。
- **版本**：Git 提交/回退/丢弃走 canvas store（`canvasStore.ts:402,457`）；服务层封装 Git 的初始化、暂存、提交、历史、检出与状态矩阵等操作（`GitInternalService.ts:149-234`）。**本次未找到**画布 UI 中的提交历史查看器或 diff 视图组件（`gitLog` 仅存在于服务层，未被组件调用）。Agent 侧的 `commit_changes`/`discard_changes` 是版本操作入口。
- **接受/拒绝**：工具调用审批 UI 在 `ToolCallMessage.vue`（awaiting_approval 状态展示）。画布写入和 diff 在审批前只登记 mutation，并把候选结果放入内存覆盖层供预览；批准后正式方法写盘一次，拒绝只移除该请求的候选层，不回退 Git HEAD。覆盖层不持久化，也不构成可跨重启恢复的事务日志（`CanvasAgentService.ts:299-415`、`canvasStore.ts:580-632`）。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：全部模型输出运行在前端 JS 上下文；工具方法在 Tauri WebView 主窗口执行（`tool-calling/core/executor.ts:177` 起，直接调用 registry 方法），底层文件/Shell 能力经 Tauri plugin（fs、shell、dialog 等，`src-tauri/Cargo.toml`）与 Rust command（画布窗口 `canvas_window.rs`、目录树 `generate_directory_tree`）实现。**未找到**容器/远端沙箱/独立进程执行模型代码的机制。
- **iframe 沙箱与 IPC 隔离**：聊天 HTML 沙箱和画布预览都没有向生成代码提供一套窄 Tauri API。canvas iframe 只启用 `allow-scripts`，没有 `allow-same-origin`，所以 srcdoc 获得 opaque origin；宿主同时校验 `event.source`、`origin === "null"`、消息类型和字段长度。该隔离在 Tauri WebView2 中的实际强度仍需运行验证（`CanvasPreviewPane.vue:23-145`）。
- **CSP 现状**：`src-tauri/tauri.conf.json:15` 的应用级 CSP 仍为 null，`index.html:6-8` 的 meta CSP 较宽；聊天与 canvas 会分别向预览文档注入 CSP。canvas 策略禁止默认来源、object 和 form，但为脚本、样式、媒体、连接与 frame 保留 asset、HTTP(S) 或 WebSocket 等来源，因此它隔离宿主同源能力，却不封闭网络访问（`useCanvasPreview.ts:233-251`）。
- **能力授予**：`executor.ts:156-169` 支持工具级 `checkSecurityPolicy`（block/approve）；Agent 侧按工具/method 的 autoApprove/手动审批矩阵控制（`executor.ts:421-423`）；`aio-file-operator` 另有 whitelist/blacklist 沙箱模式（`src/tools/aio-file-operator/composables/useFileOperator.ts:32`）约束文件操作范围，属工具自身策略。
- **asset 协议**：`tauri.conf.json:16-23` 启用 assetProtocol，scope 为 `**` 加 `$APPLOCALDATA`/`$APPDATA`。即 iframe 可经 `asset://` 读取本地资产，范围宽（事实记录，不做整改建议）。
- **文件路径边界**：canvas 存储入口先校验画布 ID，再把反斜杠统一为斜杠，并拒绝绝对路径、盘符、NUL、空目录段、`.` 和 `..`；读写删方法使用规范化后的相对路径拼入项目根目录（`useCanvasStorage.ts:35-69,106-159`）。Tauri 文件权限本身仍配置得较宽，画布目录边界主要由这层应用校验落实。
- **`ActionButtonNode` 窄桥**：模型生成的 `<button>` 只能触发白名单动作 send/input/copy（`ActionButtonNode.vue:28, 93-117`），是唯一"声明式控件 -> 宿主动作"通道，对应 G2 级元素。

## 8. 持久化、恢复、分享与导出

- **聊天会话**：每会话一个 JSON 文件（`{appConfigDir}/llm-chat/sessions/{sessionId}.json`，`useChatStorageSeparated.ts:98-242`），另有 `sessions-index.json` 索引；保存时内容比对避免无谓写盘、防抖批量保存（:642-660）、目录扫描自愈索引（`syncIndex` :321）。恢复 = 启动加载索引 -> 按需 `loadSession`。导出/分享属 Chat 类目，本次未展开。
- **画布项目**：物理文件 + `.canvas.json` 元数据 + `projects.json` 索引（原子写、可修复）；健康检查区分缺失、未登记、损坏三种状态（`CanvasService.performHealthCheck`）。分享/导出途径为 `openInVSCode`（`canvasStore.ts:527`）与 Git 提交本身；未找到打包导出/分享链接功能。
- **媒体生成**：任务先进入所有媒体工作区共享、由 `maxConcurrentTasks` 限制的模块级队列，获得槽位后再发送请求；结果经 `importAssetFromBytes`/`importAssetFromPath` 进入资产系统（`useMediaGenerationManager.ts:91-111,727-756,853-886`），origin 标记 `type: "generated"`，并写衍生数据 JSON（:912 起）；消息附件引用这些 Asset，构成"生成 -> 入库 -> 可复用"链（G1 级物化）。
- **HTML 预览导出**：Blob URL 新窗口打开（`HtmlInteractiveViewer.vue:636-649`），可另存为单文件；无版本概念。

## 9. 模型回流、对象感知与持续维护

- **画布（文件与运行反馈闭环在静态代码中成立）**：
  - 查询：`getExtraPromptContext`（`CanvasAgentService.ts:32-113`）注入项目名、入口文件、文件树、对应 canvasId 的未提交变更和运行时错误摘要；变更集合按画布分区，预览错误经窗口总线回到主窗口；
  - 读取：`read_canvas_file` 带行号返回（:118-139）；
  - 定向修改：六个 `agentCallable: true` 的画布方法（`web-canvas.registry.ts:84-241`）：
    - `apply_canvas_diff`：含策略/行号/警告反馈
    - `write_canvas_file`
    - `create_canvas`
    - `commit_changes`
    - `discard_changes`
    - `clear_runtime_errors`
  - 身份绑定（三个入口）：Agent 设置页的 `canvas-bound-id`（`web-canvas.registry.ts:41-54`）；聊天输入区的 `MiniCanvasControl`（`MiniCanvasControl.vue:70-93`，把所选画布写入工具的 canvasId 设置）；隐式建画布后的 `canvas:auto-created` 自动绑定（:125-131）。
  - 身份绑定的兜底与限制：无绑定/无激活画布时 `ensureActiveCanvas` 隐式创建（`canvasStore.ts:218-236`）；项目文件、Git 变更和错误上下文都按 canvasId 读取，但 watcher 一次只绑定 store 当前打开的画布。
- **聊天（有限回流）**：模型侧可感知的只有上下文历史（消息文本本身）；"重新解析"与"续写"（`isContinuation`，`message.ts:385-389`）允许对已有节点继续生成。`llm-chat.registry.ts:270-532` 虽有 10 个 `agentCallable: true` 方法，但全部是**智能体管理**——agent 的列出/搜索/读取/设置、预设消息 CRUD 与查找替换（`find_replace_in_presets`）、导入导出——**不针对会话中已生成的输出消息**；本次未找到模型对会话消息对象的"列出/读取/定向修改"工具方法。
- **媒体生成**：任务与资产结果关联（`mediaGenStore`），模型不可直接操作资产。

## 10. 生命周期、资源治理与性能

- **不可见对象**：聊天消息级 `content-visibility: auto` 跳过离屏渲染（`MessageList.vue`）。HTML 预览按消息深度冻结（`MessageContent.vue:846-856` 的 `shouldFreeze` 判定）：冻结时显示占位并停止 iframe，弹窗打开时内嵌预览冻结避免双份运行（`CodeBlockNode.vue:76-103`）。视口外消息另有冻结渲染配置（`MessageContent.vue:804-831`）。
- **释放**：HTML 沙箱卸载时清空 srcdoc/src（`HtmlInteractiveViewer.vue:596-603`）；流源完成即 dispose（`useStreamingMessageSources.ts:131`）；`useMarkdownAst.dispose` + 各节点组件取消异步/释放 Blob URL（`rich-text-renderer/ARCHITECTURE.md` §3.7）；错误列表限额（iframe 200 条、画布 `maxRuntimeErrors` 默认 10）；预览刷新防抖 300ms / 编辑写盘防抖 500ms。
- **限额**：流式渲染安全护栏（`safetyGuardEnabled`，超限降级停止 patch）；patch 队列上限 1000；token 限制与上下文压缩属 Chat 类目。
- **长时间会话/多画布**：画布窗口注册表（`canvas_window.rs:32-33`）与关闭清理（:160-173）保证窗口生命周期登记；未发现对多画布并发 Agent 会话的显式配额。

## 11. 测试、已确认边界与未验证事项

### 11.1 验证体系（未运行）

- 本轮更新前的调查未运行测试；本轮尝试按锁文件安装依赖，但本机 Bun `1.2.5` 低于仓库声明的 `1.3.11`，`bun install --frozen-lockfile` 长时间停在依赖解析阶段后被终止，针对性测试未实际启动。以下为测试文件清单：
  - `rich-text-renderer`：`composables/__tests__/useMarkdownAst.test.ts`、`parser/block/__tests__/parseVcpRole.test.ts`；
  - `llm-chat`：`useStreamingMessageSources.test.ts`、`emptyResponseDiagnostics.test.ts`、`message-format-processors.test.ts`、`sessionManagers.test.ts`、`PipelineEngine.test.ts` 等 10 个文件；
  - `tool-calling`：`__tests__/tool-calling.test.ts`（协议解析/执行器）；另有 `web-distillery.registry.test.ts`。
  - `web-canvas`：`__tests__/web-canvas.test.ts` 覆盖路径校验、审批候选覆盖层、HTML/CSS/JS 内联、拒绝语义、批量审批与单次正式执行。
- 当前专项单测未覆盖真实 Tauri 窗口、文件 watcher、WebView CSP、跨窗口错误同步、Git 适配层和保存/恢复端到端行为；这些仍需运行验证。

### 11.2 已确认边界（静态）

- 聊天输出没有独立 Artifact 对象与生命周期（搜索 `artifact` 仅命中推理回放 artifacts，见第 1.1 节）。
- 未找到聊天中模型生成的 HTML 输出一键转入画布/工作区的通道（聊天侧仅有画布绑定/新建/预览控制 `MiniCanvasControl.vue`，无内容迁移）。
- 未找到画布提交历史/文件 diff 的可视化 UI（`gitLog` 仅服务层）。
- 外部文件 watcher 一次只监听 store 当前打开的画布；多画布、多窗口或快速切换时的覆盖范围未经运行验证。
- 审批候选层只在内存中存在，重启和窗口异常关闭后不能恢复候选预览。
- dirty 状态和运行时错误按 canvasId 分区，但没有 revision、CRDT 或冲突合并协议。
- canvas 相对路径校验覆盖读写删入口；其对符号链接或 Tauri 文件系统特殊路径的实际行为未运行验证。
- 未找到模型对**会话中已生成消息**的直接查询/修改工具方法（llm-chat registry 的 agentCallable 方法仅覆盖智能体配置与预设消息，见第 9 节）。
- 移动端无 HTML 沙箱与画布（概览）。
- `notebook` 关键词全仓仅命中图标数据，无 notebook 类能力。
- 模型代码无语言进程/容器/远端沙箱执行环境（搜索 sandbox 命中：iframe 属性、文件操作白名单、正则命名，无执行沙箱基础设施）。

### 11.3 未验证事项

- UI 行为（编辑保存、审批候选预览、冻结、分离窗口同步、滚动恢复）仍未经真实应用运行验证；静态代码和专项单测只能确认事件绑定、数据流与纯逻辑结果。
- Git 操作经 `isomorphic-git` + Tauri fs 适配层，未经真实仓库验证。
- HTML 沙箱的实际隔离强度与 CSP 在 Tauri WebView2 下的生效情况未验证。
- 测试套件是否通过未验证。

## 12. 设计取舍与扩展调查

### 12.1 设计取舍

- **"当前文本协议 + 展示时物化"而非 typed part**：当前 VCP 等文本协议通过适配层进入工具调用链；聊天全链路（存储、上下文、渲染）仍以纯文本为单一载体，解析器在渲染层承担协议解释。好处是存储与模型上下文一致、无需对象迁移，代价是输出没有独立生命周期，模型无法对"图表/HTML 预览"本身做定向更新。
- **Physical-First 画布配合瞬时候选层**：正式项目仍以磁盘和 Git 为事实源，外部编辑由 watcher 接入；审批阶段另建不落盘的内存覆盖层，避免候选内容提前改变工作区。代价是候选预览无法跨重启恢复，且并发编辑仍没有 revision 或冲突合并。
- **两套 iframe 策略分别配置**：聊天与 canvas 都使用 sandbox 和文档内 CSP，但许可项不同。canvas 采用 opaque origin 与消息来源校验，同时允许预览访问网络和外部 frame；这是一条“隔离宿主同源能力、保留网页运行兼容性”的边界，而不是封闭网络的执行沙箱。
- **错误回路只在画布中进入模型上下文**：聊天 HTML 沙箱错误停留在用户可见的错误面板；canvas 错误通过跨窗口总线回到主窗口，并由 Agent 上下文读取。真实 WebView 中的事件来源、时序和重复行为仍待运行验证。

### 12.2 扩展调查：移动端（概览）

- `mobile/src/tools/llm-chat` 有会话、分支、流式执行与持久化（`stores/llmChatStore.ts:117` persistSession），结构与桌面同源但规模小得多。
- `mobile/src/tools/rich-text-renderer/RichTextRenderer.vue` 基于 `marked`，HTML 块 `v-html` 直出，无沙箱、无 iframe、无图表预览；生成式输出停留在 G0–G1 级。
- 未逐文件核对移动端其余工具（`agent-manager`、`llm-api`、`log-manager`、`ui-tester`），是否含其他输出运行时未知。

## 关键源码索引

- `src/tools/llm-chat/types/message.ts:110-416`：消息节点对象模型（唯一内容载体为字符串）
- `src/tools/llm-chat/composables/chat/useStreamingMessageSources.ts:20-131`：可重放流源与按节点生命周期
- `src/tools/llm-chat/composables/chat/useChatResponseHandler.ts:244,503,647`：流式写入、最终化、错误收口
- `src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts:276-365`：工具调用审批、执行与结果节点化
- `src/tools/llm-chat/composables/session/useBranchManager.ts:108-209`：消息编辑与分支
- `src/tools/llm-chat/composables/storage/useChatStorageSeparated.ts:190-356`：会话文件持久化与索引自愈
- `src/tools/rich-text-renderer/components/HtmlInteractiveViewer.vue:138,320-327,452-515,596-603`：HTML 沙箱（sandbox/CSP/srcdoc/卸载释放）
- `src/tools/rich-text-renderer/components/nodes/CodeBlockNode.vue:74-110`：html 代码块预览入口
- `src/tools/rich-text-renderer/components/nodes/ActionButtonNode.vue:28,93-117`：白名单交互按钮
- `src/tools/llm-chat/components/message-input/MiniCanvasControl.vue:70-131`：聊天输入区的画布绑定/新建/预览控制（`canvas:auto-created` 自动绑定）
- `src/tools/llm-chat/llm-chat.registry.ts:270-532`：智能体管理类 agentCallable 方法（预设消息 CRUD，不覆盖会话输出）
- `src/tools/tool-calling/core/protocols/base.ts`、`core/discovery.ts`、`core/engine.ts`、`composables/useToolCalling.ts`：协议抽象、当前 VCP 路由、执行循环与工具发现
- `src/tools/tool-calling/core/protocols/vcp-protocol.ts`：当前 VCP 文本协议实现
- `src/tools/web-canvas/stores/canvasStore.ts:80-171,580-632`：按画布区分的 Git 状态、外部文件监听与审批候选覆盖层
- `src/tools/web-canvas/services/CanvasAgentService.ts:32-190,299-415`：Agent 上下文、diff 反馈与不落盘审批预览
- `src/tools/web-canvas/web-canvas.registry.ts:84-241`：Agent 可调用方法元数据
- `src/tools/web-canvas/composables/useCanvasStorage.ts:35-69,106-173`：画布 ID、相对路径校验与递归文件监听
- `src/tools/web-canvas/composables/useCanvasPreview.ts:39-251`：候选文件内联、预览 CSP 与控制台/错误捕获
- `src/tools/web-canvas/components/window/CanvasPreviewPane.vue:23-145`：opaque-origin iframe 与消息来源/字段校验
- `src/tools/web-canvas/utils/diff.ts:71`：Search/Replace diff 引擎
- `src/tools/web-canvas/composables/useCanvasSync.ts:63-168`：文件、候选覆盖层与运行时错误的跨窗口同步
- `src-tauri/src/commands/canvas_window.rs:45-118,160-173`：画布独立窗口创建与清理
- `index.html:6-8` 与 `src-tauri/tauri.conf.json:15-23`：应用 CSP 与 asset 协议（实现与配置并存）
- `src/tools/tool-calling/core/executor.ts:156-169,177-219`：安全策略与执行入口
- `src/tools/media-generator/composables/useMediaGenerationManager.ts:853-912`：生成媒体资产入库
