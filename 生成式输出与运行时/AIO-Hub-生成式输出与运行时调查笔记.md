# AIO Hub 生成式输出与运行时调查笔记

> 调查对象：`../../aio-hub`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 调查方式：静态代码阅读。对 `src/tools/llm-chat`、`src/tools/rich-text-renderer`、`src/tools/web-canvas`、`src/tools/tool-calling`、`src/tools/media-generator` 等目录做关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、preview、stream、CSP 等）并精读关键实现文件；对照工具自带 ARCHITECTURE.md；抽查 Rust 命令与 Tauri 配置；未运行构建、未启动应用、未运行测试（仓库未安装 node_modules，`bunx vitest` 拉取依赖超时）
>
> 调查范围：模型输出从"消息文本/工具结果"到"可展示、可运行、可编辑、可持久化、可回流对象"的完整链路；覆盖聊天消息物化、HTML 代码块沙箱、web-canvas 工作区、媒体生成资产入库、工具调用结果节点、执行位置与 CSP、持久化与回流；普通 Markdown 渲染细节、Chat 发送/中止/分支语义、工具注册与审批调度本身（仅记录交接点）排除在外；移动端只做概览
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的生成式输出呈现**双层结构**：聊天层把模型输出保持为"消息树节点上的纯文本字符串"，在展示时由 `RichTextRenderer` 动态解释为 Markdown/Mermaid/KaTeX/HTML 沙箱等；工作区层则提供 `web-canvas`——一个以磁盘文件为事实源、Git 为版本追踪的 Agent 协作工作区，模型可通过工具调用查询、定向修改、提交并感知运行时错误，构成一条完整的"查询 -> 读取 -> 定向修改 -> 回流"闭环。

- **聊天输出对象模型**：消息节点（`ChatMessageNode`）有稳定 ID、来源、角色、状态与丰富元数据，但内容只是一段 `content: string`，不存在独立的 Artifact 对象；HTML 代码块在展示时进入 iframe 沙箱（`HtmlInteractiveViewer`）成为可运行预览，属"展示时物化"，无独立生命周期。
- **web-canvas**：`{appDataDir}/canvases/projects/{id}/` 下的物理项目 + `.canvas.json` 元数据 + 独立 Git 仓库；Monaco 编辑直接写盘（500ms 防抖），预览 iframe 用 `asset://` 加载入口文件并注入日志/错误捕获脚本；审批钩子先应用后回滚（`onToolCallPreview` / `onToolCallDiscarded`）。
- **工具结果**：VCP 文本协议 `<<<[TOOL_REQUEST]>>>` 解析执行后，结果被格式化为文本写入"tool 角色"消息节点内容，随会话 JSON 持久化；结果本身不物化为独立对象，但 web-canvas 的文件操作结果会直接落到物理文件。
- **持久化**：聊天会话按会话独立 JSON 文件存储；画布为物理文件 + Git；媒体生成结果通过 `importAssetFromBytes` 进入资产管理系统并带生成来源元数据。
- **执行位置**：全部在前端 JS（Tauri WebView）内执行；无远端沙箱、无容器、无独立进程执行模型代码；iframe 沙箱仅做脚本隔离，不授予 Tauri IPC。应用级 CSP 宽松（见第 7 节），iframe 级 CSP 按预览注入。

横向对比轴（桌面端）：

| 轴 | 聊天层 | web-canvas |
|---|---|---|
| 协议开放度 | 自由文本 + VCP 标记 + 富文本 AST | 工具方法元数据（`agentCallable`） |
| 更新粒度 | 整段文本重解析（稳定区/待定区 patch） | Search/Replace diff（exact/trimEnd/trim/fuzzy） |
| 投影表面 | inline（消息内）+ 弹窗 + 分离窗口 | 工具页内嵌 + 独立 Tauri 窗口 |
| 执行强度 | HTML/CSS/JS 浏览器脚本（iframe 沙箱） | 同左，入口文件加载本地 `asset://` 资源 |
| 持续性 | 会话文件（跨会话可恢复） | 物理项目 + Git（长期活对象） |
| 闭环程度 | 只生成 + 可编辑消息 + 可续写/重解析 | 可查询、可读、可定向修改、可提交、错误回流 |
| 能力范围 | 无桥接（iframe 只回传日志/高度） | 工具方法调用（读文件、写文件、提交、Git） |
| 可移植性 | HTML 预览可"在浏览器中打开"导出单文件 | 可提交 Git、可在 VSCode 中打开 |

**能力等级认定**：综合 **G4（可编辑工作区）**；其中 web-canvas 已覆盖 G5（环境化活对象）的大部分判定要点（跨会话持久、模型感知状态、定向修改、持续维护），但缺少桌面长期挂载与空间画布形态，且该能力只附着于画布这一个工具表面，不覆盖普通聊天输出。聊天内 HTML 代码块沙箱为局部 **G3**，其余聊天输出停留在 G0–G1。

## 系统边界与完整主链路

本类目在 AIO Hub 中由三个物理区域承担：

1. **聊天层**（`src/tools/llm-chat` + `src/tools/rich-text-renderer`）：模型文本流 -> 消息节点 -> 富文本渲染 -> 内嵌 HTML 沙箱/图表/代码块；消息可编辑、可分支、可重解析。
2. **画布层**（`src/tools/web-canvas`）：Agent/用户围绕磁盘项目协作，模型经工具调用直接改文件，Git 追踪版本，iframe 预览并回传运行时错误。
3. **资产层**（`src/composables/useAssetManager` 等）：媒体生成等产物物化为带元数据的 Asset，可被消息引用（`agent-asset://`、`【file::id】` 占位符）。

**主链一（聊天，静态确认）**：用户在 `ChatArea` 发送 -> `useToolCallOrchestrator.orchestrate` 创建 assistant 节点 -> `useSingleNodeExecutor` 流式请求 -> `useChatResponseHandler` 将 chunk 同时写入 `node.content` 与可重放流源（`useStreamingMessageSources.ts:116` appendStreamingMessageChunk）-> `RichTextRenderer` 以 AST patch 渲染，HTML 代码块进入 `HtmlInteractiveViewer` iframe 沙箱 -> 用户可对消息执行"编辑"（`useBranchManager.editMessage`，`useBranchManager.ts:108`）或"保存到分支" -> `sessionManager.persistSession` 落盘（`useChatStorageSeparated.ts:496`）-> 重新打开会话时从 `{appConfig}/llm-chat/sessions/{id}.json` 加载，HTML 预览从内容重新生成。链路各环节均有源码依据；未运行验证。

**主链二（画布，静态确认）**：用户在 `CanvasWorkbench` 创建画布 -> `CanvasService.createCanvas` 从模板复制文件、`git init` + 首次提交（`CanvasService.ts`）-> Monaco 编辑防抖写盘（`CanvasEditorPanel.vue:128`）-> 预览引擎注入 `<base>` 与日志/错误捕获脚本后以 srcdoc 渲染（`useCanvasPreview.ts:47`）-> 提交（`canvasStore.commitChanges`，`canvasStore.ts:402`）/ 丢弃（`discardChanges`，:457）-> 关闭后从索引 `projects.json` + 磁盘元数据重新打开（`loadCanvasList`，:172）。Agent 侧闭环见第 9 节。

**主链三（工具结果，静态确认）**：assistant 流文本 -> `parseToolRequests` 解析 VCP 请求 -> `processCycle` 审批 + 执行 -> 结果格式化为文本写入 tool 节点（`useToolCallOrchestrator.ts:310-365`）-> 节点随会话持久化；其中 web-canvas 类方法会直接写物理文件。

## 1. 触发方式、输出协议与对象模型

### 1.1 聊天输出：无独立对象，消息节点即对象

- 触发由用户消息驱动；模型回复文本流式写入 assistant 节点。节点模型 `ChatMessageNode`（`src/tools/llm-chat/types/message.ts:110-416`）具有稳定 `id`、`parentId`、`role`、`status`（generating/complete/error 等）、`metadata`（模型、Agent、usage、推理内容、翻译、工具调用等），但**内容唯一载体是 `content: string`**。没有 Artifact/part 类型的结构化输出对象；`type?: MessageType` 只用于"预设消息/历史占位符"，与生成内容无关。
- 与 typed part 类协议相比，本项目输出协议是**自由文本 + 约定标记**：VCP 工具调用块、`<think>` 思考块、HTML 标签、Mermaid 围栏都由渲染器在展示时识别（`rich-text-renderer/ARCHITECTURE.md` §3.2、§5.2），而非发送/存储时的结构化 part。
- 唯一接近"part 语义"的是 `LlmReasoningArtifact`（`src/llm-apis/common.ts` 相关类型，`message.ts:282`），但它是 DeepSeek/OpenAI/Gemini 推理内容的**回放状态**，供上下文压缩后精确重放推理文本，不是可操作输出对象。

### 1.2 工具输出：文本结果节点 + 物理副作用

- 工具请求由模型自由文本中的 `<<<[TOOL_REQUEST]>>> ... <<<[END_TOOL_REQUEST]>>>` 标记触发（VCP 协议，`src/tools/tool-calling/core/protocols/vcp-protocol.ts`），支持 `TOOL_REQUEST_ESCAPE` 嵌套与转义。
- 执行结果经 `formatCycleResults` 序列化为协议文本，写入 role 为 `"tool"` 的消息节点（`useToolCallOrchestrator.ts:325-345`），节点 `metadata.toolCalls[]` 记录每个请求的 requestId/工具名/状态/耗时/原始参数。**结果不物化为独立对象**；若工具本身有物理副作用（如画布写文件），结果对象身份在文件侧。
- 工具节点可被"重新解析"（`reparseAndOrchestrate`，`useToolCallOrchestrator.ts:449`），即对已有内容重新走工具调用检测与执行，属于后续回合重入入口。

### 1.3 画布对象模型

- 画布项目有稳定 ID（`cp_{yyyyMMdd}_{shortId}`，`web-canvas/utils/id.ts:22`）、名称、模板、入口文件、创建/更新时间（`.canvas.json` 元数据 + `projects.json` 索引，`web-canvas/ARCHITECTURE.md` §2）。
- **事实源是磁盘文件 + Git**：没有影子文件或内存 VFS，编辑即写盘（`web-canvas/ARCHITECTURE.md` §1.2 "Physical-First"）。画布与聊天的衔接有两个用户侧入口：聊天输入区内置"画布控制"（`MiniCanvasControl.vue`，绑定/新建/预览/跳转管理）与输入工具栏的 web-canvas 开关（`MessageInputToolbar.vue:163-196`）；但**没有把聊天中模型生成的 HTML 一键转入画布的通道**（本次未找到此类入口，`rich-text-renderer` 中无 web-canvas 引用）。
- 项目索引与元数据分离、索引可修复（`repairProject`，`canvasStore.ts:511`）。

## 2. 增量生成、更新与最终化

### 2.1 聊天流式

- 逐 token 注入：`useChatResponseHandler` 把流式 chunk 追加到 `node.content`，同时喂给按节点 ID 缓存的可重放流源 `ReplayableMessageStreamSource`（`useStreamingMessageSources.ts:20-89`），渲染器以流式 AST patch 更新（`text-append`/`replace-node`/`insert-after` 等 op，`rich-text-renderer/ARCHITECTURE.md` §3.4）。
- 渲染器内部是**整段文本重解析 + patch**：V2 自研解析器维护"稳定区/待定区"，稳定区复用已有 AST，待定区每次重解析，经 diff 生成 patch（`core/StreamProcessorV2.ts`）。不是按 AST 节点增量生成，也不是外部 diff/patch 协议。
- 最终化：请求完成调用 `completeAndDisposeStreamingMessageSource`（`useChatResponseHandler.ts:503`）；失败走 `handleNodeError`（:647），错误写入节点 `metadata.error` 并在 UI 显示可复制错误条；空响应写入 `emptyResponseDiagnostic` 诊断。
- 网络层流式节流与 VCP 块冲刷由 `core/StreamController.ts` 处理（`rich-text-renderer/ARCHITECTURE.md` §3.4），保证协议块不被平滑拆碎。

### 2.2 画布更新

- Agent 侧：Search/Replace diff 引擎 `applySearchReplaceDiff`（`web-canvas/utils/diff.ts:71`），匹配策略 exact -> trimEnd -> trim -> fuzzy（Bigram Dice，阈值 0.85），支持行号剥离、`start_line` 消歧、缩进修复、重匹配警告；应用结果写盘并刷新 Git 状态（`canvasStore.ts:354-398`）。
- 用户侧：Monaco 编辑内容 500ms 防抖整体写盘（`CanvasEditorPanel.vue:128-134`）。
- 两类写入都触发 `emitFileChanged` -> 预览刷新（300ms 防抖，`useCanvasPreview.ts:47`）+ 分离窗口同步。

## 3. 投影表面与多视图关系

| 表面 | 承载对象 | 位置 |
|---|---|---|
| 消息正文 inline | 全部聊天输出（Markdown/图表/HTML 沙箱） | `MessageContent.vue` |
| 弹窗 | HTML 代码块大图预览、Mermaid 悬浮交互、文档查看器 | `CodeBlockNode.vue:108`、`MermaidInteractiveViewer` |
| 分离窗口 | 聊天区（`useDetachedChatArea`）、工具组件、画布预览 | `DetachedWindowContainer.vue`、`canvas_window.rs:45` |
| 工具页 | web-canvas 工作台 | `CanvasWorkbench.vue` |
| 外部浏览器 | HTML 预览导出 | `HtmlInteractiveViewer.vue:636-649`（Blob URL 新窗口打开） |
| 桌面覆盖窗 | 弹幕播放器透明覆盖窗口（非模型输出，记相邻） | `useDanmakuOverlay.ts:146` |

- 同一对象多投影同步仅出现在画布：主窗口编辑面板与分离预览窗口通过 `useCanvasSync`（`useCanvasSync.ts:53-80`）同步 `activeCanvasId` 与文件变更通知；分离窗口的操作（写文件、提交）经 `bus.onActionRequest` 代理回主窗口（`web-canvas/ARCHITECTURE.md` §1.8）。
- 聊天消息的"分离"是把整个聊天组件搬到新 WebView 窗口（`useDetachedChatArea.ts`），消息对象本身无多投影。
- 聊天 HTML 预览与画布预览是**两份独立运行时**：前者渲染消息 `content` 中提取的代码块文本，后者渲染磁盘入口文件；彼此无同步。

## 4. 表现类型、依赖与运行环境

- **表现层次**（`RichTextRenderer`，`src/tools/rich-text-renderer`）：Markdown/GFM（表格、Alert）、KaTeX/MathJax 公式、Mermaid（`MermaidInteractiveViewer`，缩放/下载/分屏）、HTML 深度混合排版（`GenericHtmlNode`/`HtmlBlockNode`）、`<video>`/`<audio>` 拦截为项目播放器、`<details>` 折叠面板、`<style>` 作用域隔离、可交互按钮（`ActionButtonNode`，白名单动作 send/input/copy）、`<svar>` 会话变量徽章、`<think>` 思考块。
- **代码块**：CodeMirror 只读查看器（`CodeMirrorSourceViewer.vue`），懒初始化 + `PreCodeNode` 兜底；`html` 语言代码块可切换"预览模式"进入 `HtmlInteractiveViewer` 沙箱（`CodeBlockNode.vue:74-104`），支持内嵌预览 / 弹窗预览 / 无缝模式 / 冻结。
- **HTML 沙箱**（`HtmlInteractiveViewer.vue`）：srcdoc iframe，`sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals"`（:138）；注入 CSP meta（默认 `default-src 'self' 'unsafe-inline' ...`，允许外部脚本时放宽为 `*`，:320-327）；注入日志/错误捕获/交互感知/自适应高度脚本（:335-450）；CDN 本地化（`cdnLocalizer.ts`）替换 jsdelivr/cdnjs/unpkg 等为本地 `public/libs`。
- **依赖提供**：本地 CDN 资源本地化 + `asset://`/`agent-asset://` 本地资产协议；无语言解释器、无 Python/Node 进程执行。
- **移动端**：`mobile/src/tools/rich-text-renderer/RichTextRenderer.vue` 是 `marked` 的简单渲染器，HTML 块直接 `v-html`，无沙箱、无 iframe 预览、无 Mermaid/KaTeX（概览结论，未逐行核对其余工具）。

## 5. 用户交互、事件与错误反馈

- **HTML 沙箱回传**：iframe 通过 `postMessage` 回传 `iframe-log`（console 捕获）、`iframe-height`（自适应高度）、`iframe-mousemove/enter/leave`（悬浮状态）；宿主侧 `handleIframeMessage`（`HtmlInteractiveViewer.vue:517-583`）把 error 级日志收集为 `iframeErrors`（上限 200 条），UI 提供错误浮窗/复制/清空；卸载时主动 `srcdoc=""` + `about:blank` 释放（:596-603）。
- **画布回传**：预览 iframe 回传 `canvas-console` 与 `canvas-runtime-error`（`useCanvasPreview.ts:80-171`）；`useCanvasErrors` 做去重、限流、stale 标记；刷新预览后清理过期错误（`CanvasWindow.vue:165-198`）。
- **错误反馈去向**：画布运行时错误在启用 `autoIncludeErrors` 时注入 Agent 上下文（`CanvasAgentService.ts:96-104`），构成模型可感知的错误反馈回路；HTML 沙箱错误仅留在 UI 层，不回传给模型。
- **运行状态恢复**：`MessageList.vue` 有 keep-alive 滚动位置恢复（:73-99）；画布分离窗口关闭后重新打开时从磁盘重新加载（`CanvasWindow.vue:137-158`）；弹幕覆盖窗等桌面窗不在本类目。

## 6. 编辑、diff、版本与协作

- **聊天消息编辑**：全文覆盖式编辑（`useBranchManager.editMessage`，`useBranchManager.ts:108-156`），仅限 user/assistant 角色；"保存到分支"复制内容到兄弟节点形成分支（:162-209）。无选区编辑、无结构化 patch、无撤销栈持久化（`useChatStorageSeparated.ts:199-204` 明确移除 history 字段）。版本表达依赖消息树分支语义，属于 Chat 类目，此处只记交接点。
- **画布编辑**：用户与 Agent 修改同一组磁盘文件；Agent 用 Search/Replace diff（含 fuzzy 降级与置信度反馈，`CanvasAgentService.ts:168-190`），用户用 Monaco 全量覆盖；未发现两者的 CRDT/合并冲突检测——写盘以"最后写入者"为准（静态推断，代码中未找到锁或冲突合并逻辑）。
- **版本**：Git 提交/回退/丢弃（`canvasStore.commitChanges` :402、`discardChanges` :457）；`GitInternalService` 提供 init/add/commit/log/checkout/statusMatrix（`GitInternalService.ts:149-234`）。**本次未找到**画布 UI 中的提交历史查看器或 diff 视图组件（`gitLog` 仅存在于服务层，未被组件调用）；Agent 的 `commit_changes`/`discard_changes` 是版本操作入口。
- **接受/拒绝**：工具调用审批 UI 在 `ToolCallMessage.vue`（awaiting_approval 状态展示）；画布侧 `onToolCallPreview` 先应用变更让用户在预览中确认，`onToolCallDiscarded` 按文件状态回滚（新文件物理删除、已有文件 `git checkout`）（`CanvasAgentService.ts:270-331`）。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：全部模型输出运行在前端 JS 上下文；工具方法在 Tauri WebView 主窗口执行（`tool-calling/core/executor.ts:177` 起，直接调用 registry 方法），底层文件/Shell 能力经 Tauri plugin（fs、shell、dialog 等，`src-tauri/Cargo.toml`）与 Rust command（画布窗口 `canvas_window.rs`、目录树 `generate_directory_tree`）实现。**未找到**容器/远端沙箱/独立进程执行模型代码的机制。
- **iframe 沙箱与 IPC 隔离**：聊天 HTML 沙箱与画布预览 iframe 都不注入 Tauri IPC 桥；iframe 只有 `postMessage` 回传通道，无法直接调用 `invoke`。注意：`sandbox="allow-scripts allow-same-origin"` 组合在 srcdoc 场景下使 iframe 继承父窗口 origin，理论上存在逃逸面（web-distillery 代码注释亦承认此风险，`web-distillery/core/iframe-bridge.ts:106-112`）；实际隔离依赖注入的 CSP。
- **CSP 现状（文档与实现不一致点）**：`src-tauri/tauri.conf.json:15` 设置 `"csp": null`，但 `index.html:6-8` 有 meta CSP，实际生效的是 meta CSP（宽松：`script-src 'self' 'unsafe-inline' 'unsafe-eval' https://* http://* blob: data: asset:`，`frame-src 'self' https://* asset:` 等）。iframe 级 CSP 由 `HtmlInteractiveViewer` 按预览内容注入（:320-327），默认收紧到 `default-src 'self'` + 本地资产协议，放开外部脚本开关后才放宽。
- **能力授予**：`executor.ts:156-169` 支持工具级 `checkSecurityPolicy`（block/approve）；Agent 侧按工具/method 的 autoApprove/手动审批矩阵控制（`executor.ts:421-423`）；`aio-file-operator` 另有 whitelist/blacklist 沙箱模式（`src/tools/aio-file-operator/composables/useFileOperator.ts:32`）约束文件操作范围，属工具自身策略。
- **asset 协议**：`tauri.conf.json:16-23` 启用 assetProtocol，scope 为 `**` + `$APPLOCALDATA`/`$APPDATA`，即 iframe 可经 `asset://` 读取本地资产，范围宽（事实记录，不做整改建议）。
- **`ActionButtonNode` 窄桥**：模型生成的 `<button>` 只能触发白名单动作 send/input/copy（`ActionButtonNode.vue:28, 93-117`），是唯一"声明式控件 -> 宿主动作"通道，对应 G2 级元素。

## 8. 持久化、恢复、分享与导出

- **聊天会话**：`{appConfigDir}/llm-chat/sessions/{sessionId}.json` 每会话一文件（`useChatStorageSeparated.ts:98-242`），索引 `sessions-index.json`；保存时内容比对避免无谓写盘；防抖批量保存（:642-660）；目录扫描自愈索引（`syncIndex` :321）。恢复 = 启动加载索引 -> 按需 `loadSession`。导出/分享属 Chat 类目（`llm-chat/components/export/`，本次未展开）。
- **画布项目**：物理文件 + `.canvas.json` + `projects.json` 索引（原子写、可修复）；健康检查区分 missing/unindexed/corrupted（`CanvasService.performHealthCheck`）。分享/导出途径：`openInVSCode`（`canvasStore.ts:527`）与 Git 提交本身；未找到打包导出/分享链接功能。
- **媒体生成**：结果经 `importAssetFromBytes`/`importAssetFromPath` 进入资产系统（`useMediaGenerationManager.ts:853-886`），origin 标记 `type: "generated"`，并写衍生数据 JSON（:912 起）；消息附件引用这些 Asset，构成"生成 -> 入库 -> 可复用"链（G1 级物化）。
- **HTML 预览导出**：Blob URL 新窗口打开（`HtmlInteractiveViewer.vue:636-649`），可另存为单文件；无版本概念。

## 9. 模型回流、对象感知与持续维护

- **画布（完整闭环，静态确认）**：
  - 查询：`getExtraPromptContext`（`CanvasAgentService.ts:32-113`）注入项目名、入口文件、文件树（含 modified/new/deleted 标记）、未提交变更列表、运行时错误摘要（`getFormattedErrorContext`，:96-104）；
  - 读取：`read_canvas_file` 带行号返回（:118-139）；
  - 定向修改：`apply_canvas_diff`（含策略/行号/警告反馈）、`write_canvas_file`、`create_canvas`、`commit_changes`、`discard_changes`、`clear_runtime_errors`（`web-canvas.registry.ts:84-241`，`agentCallable: true`）；
  - 身份绑定：三处入口——Agent 设置页的 `canvas-bound-id`（`web-canvas.registry.ts:41-54`）、聊天输入区的 `MiniCanvasControl`（`MiniCanvasControl.vue:70-93` 写入 `toolSettings["web-canvas"].canvasId`）、Agent 工具调用导致隐式建画布后的 `canvas:auto-created` 自动绑定（:125-131）；无绑定/无激活画布时 `ensureActiveCanvas` 隐式创建（`canvasStore.ts:218-236`）。绑定保证后续回合操作同一对象而非重新生成。
- **聊天（有限回流）**：模型侧可感知的只有上下文历史（消息文本本身）；"重新解析"与"续写"（`isContinuation`，`message.ts:385-389`）允许对已有节点继续生成。`llm-chat.registry.ts:270-532` 虽有 10 个 `agentCallable: true` 方法，但全部是**智能体管理**（list/search/read/set agent、预设消息 CRUD、`find_replace_in_presets` 对预设消息内容做查找替换、导入导出），**不针对会话中已生成的输出消息**；本次未找到模型对会话消息对象的"列出/读取/定向修改"工具方法。
- **媒体生成**：任务与资产结果关联（`mediaGenStore`），模型不可直接操作资产。

## 10. 生命周期、资源治理与性能

- **不可见对象**：聊天消息级 `content-visibility: auto` 跳过离屏渲染（`MessageList.vue`，`rich-text-renderer/ARCHITECTURE.md` §3.7）；HTML 预览按消息深度冻结（`MessageContent.vue:846-856` -> `shouldFreeze`），冻结时显示占位并停止 iframe，弹窗打开时内嵌预览冻结避免双份运行（`CodeBlockNode.vue:76-103`）；视口外消息冻结渲染配置（`MessageContent.vue:804-831`）。
- **释放**：HTML 沙箱卸载时清空 srcdoc/src（`HtmlInteractiveViewer.vue:596-603`）；流源完成即 dispose（`useStreamingMessageSources.ts:131`）；`useMarkdownAst.dispose` + 各节点组件取消异步/释放 Blob URL（`rich-text-renderer/ARCHITECTURE.md` §3.7）；错误列表限额（iframe 200 条、画布 `maxRuntimeErrors` 默认 10）；预览刷新防抖 300ms / 编辑写盘防抖 500ms。
- **限额**：流式渲染安全护栏（`safetyGuardEnabled`，超限降级停止 patch）；patch 队列上限 1000；token 限制与上下文压缩属 Chat 类目。
- **长时间会话/多画布**：画布窗口注册表（`canvas_window.rs:32-33`）与关闭清理（:160-173）保证窗口生命周期登记；未发现对多画布并发 Agent 会话的显式配额。

## 11. 测试、已确认边界与未验证事项

### 11.1 验证体系（未运行）

- 本次**未运行任何测试**（仓库未安装 node_modules；`bunx vitest` 因解析依赖超时被终止）。以下为测试文件清单（静态确认）：
  - `rich-text-renderer`：`composables/__tests__/useMarkdownAst.test.ts`、`parser/block/__tests__/parseVcpRole.test.ts`；
  - `llm-chat`：`useStreamingMessageSources.test.ts`、`emptyResponseDiagnostics.test.ts`、`message-format-processors.test.ts`、`sessionManagers.test.ts`、`PipelineEngine.test.ts` 等 10 个文件；
  - `tool-calling`：`__tests__/tool-calling.test.ts`（协议解析/执行器）；另有 `web-distillery.registry.test.ts`。
  - **web-canvas 目录下未找到任何测试文件**（`**/*.test.*` 无命中）。
- 未覆盖：CSP 实际生效行为、iframe 沙箱逃逸面、Git 在 Tauri fs 适配下的行为、多窗口同步、保存/恢复的端到端行为，均需运行验证。

### 11.2 已确认边界（静态）

- 聊天输出没有独立 Artifact 对象与生命周期（搜索 `artifact` 仅命中推理回放 artifacts，见第 1.1 节）。
- 未找到聊天中模型生成的 HTML 输出一键转入画布/工作区的通道（聊天侧仅有画布绑定/新建/预览控制 `MiniCanvasControl.vue`，无内容迁移）。
- 未找到画布提交历史/文件 diff 的可视化 UI（`gitLog` 仅服务层）。
- 未找到模型对**会话中已生成消息**的直接查询/修改工具方法（llm-chat registry 的 agentCallable 方法仅覆盖智能体配置与预设消息，见第 9 节）。
- 移动端无 HTML 沙箱与画布（概览）。
- `notebook` 关键词全仓仅命中图标数据，无 notebook 类能力。
- 模型代码无语言进程/容器/远端沙箱执行环境（搜索 sandbox 命中：iframe 属性、文件操作白名单、正则命名，无执行沙箱基础设施）。

### 11.3 未验证事项

- 所有 UI 行为（编辑保存、审批预览-回滚、冻结、分离窗口同步、滚动恢复）未经运行验证。
- Git 操作经 `isomorphic-git` + Tauri fs 适配层，未经真实仓库验证。
- HTML 沙箱的实际隔离强度与 CSP 在 Tauri WebView2 下的生效情况未验证。
- 测试套件是否通过未验证。

## 12. 设计取舍与扩展调查

### 12.1 设计取舍

- **"文本协议 + 展示时物化"而非 typed part**：全链路（存储、上下文、渲染）以纯文本为单一载体，解析器在渲染层承担协议解释；好处是存储与模型上下文一致、无需对象迁移，代价是输出没有独立生命周期，模型无法对"图表/HTML 预览"本身做定向更新。
- **Physical-First 画布**：放弃影子文件/内存 VFS，换取外部编辑器兼容（VSCode 改文件可见）、崩溃安全与 Git 状态追踪；代价是文件系统成为唯一事实源，写入频率受防抖保护。
- **iframe 双重隔离**（sandbox 属性 + 注入 CSP）：逐预览注入 CSP 而不是全局收紧，换取资产协议与 CDN 本地化的灵活性，代价是应用级 CSP 保持宽松。
- **错误回路只服务画布**：运行时错误注入模型上下文的机制只在 web-canvas 存在，聊天 HTML 沙箱错误不回流。

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
- `src/tools/web-canvas/stores/canvasStore.ts:113-398,402-469`：Git 状态、写盘、diff、提交/丢弃
- `src/tools/web-canvas/services/CanvasAgentService.ts:32-190,270-331`：Agent 上下文、带行号读取、diff 反馈、审批预览/回滚
- `src/tools/web-canvas/web-canvas.registry.ts:84-241`：Agent 可调用方法元数据
- `src/tools/web-canvas/composables/useCanvasPreview.ts:47-192`：预览引擎（base 注入 + 控制台/错误捕获）
- `src/tools/web-canvas/utils/diff.ts:71`：Search/Replace diff 引擎
- `src/tools/web-canvas/composables/useCanvasSync.ts:53-80`：跨窗口状态同步
- `src-tauri/src/commands/canvas_window.rs:45-118,160-173`：画布独立窗口创建与清理
- `index.html:6-8` 与 `src-tauri/tauri.conf.json:15-23`：应用 CSP 与 asset 协议（实现与配置并存）
- `src/tools/tool-calling/core/executor.ts:156-169,177-219`：安全策略与执行入口
- `src/tools/media-generator/composables/useMediaGenerationManager.ts:853-912`：生成媒体资产入库
