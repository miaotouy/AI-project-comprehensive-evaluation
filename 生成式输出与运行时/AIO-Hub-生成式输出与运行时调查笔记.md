# AIO Hub 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：对照源码快照差异，只读复核画布路径/Git适配与测试、VCP分段/媒体结果、子Agent任务边界和移动HTML分支；原有画布候选预览、CSP与回流链保留就近依据；未运行构建、应用或测试
>
> 调查范围：模型输出从"消息文本/工具结果"到"可展示、可运行、可编辑、可持久化、可回流对象"的完整链路；覆盖聊天消息物化、HTML 代码块沙箱、web-canvas 工作区、媒体生成资产入库、工具调用结果节点、执行位置与 CSP、持久化与回流；普通 Markdown 渲染细节、Chat 发送/中止/分支语义、工具注册与审批调度本身（仅记录交接点）排除在外；移动端只做概览
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的生成式输出呈现**双层结构**：聊天层把模型输出保持为“消息树节点上的纯文本字符串”，在展示时由 `RichTextRenderer` 动态解释为 Markdown、Mermaid、KaTeX 和 HTML 沙箱；工作区层则提供 web-canvas，一个以磁盘文件为事实源、Git 为版本追踪的 Agent 协作工作区。模型可以查询、读取、修改和提交文件，独立预览窗口捕获的运行时错误也会同步回主窗口并进入后续 Agent 上下文。静态代码已经贯通“修改 -> 预览 -> 报错 -> 回流 -> 再修改”，但真实窗口、网络和 Tauri WebView 行为仍未运行验证。

- **聊天输出对象模型**：聊天消息以消息节点 `ChatMessageNode` 为唯一载体，节点记录稳定 ID、来源、角色、状态以及模型、用量等元数据，可生成的内容只存在 `content` 一个字符串字段里，没有独立的 Artifact 对象。HTML 代码块在展示时才进入 `HtmlInteractiveViewer` 的 iframe 沙箱，渲染成可运行预览，这份预览随展示产生，没有自己的生命周期。
- **web-canvas**：一个画布项目由磁盘上的物理目录、`.canvas.json` 元数据和独立 Git 仓库组成，目录位于 `getAppConfigDir()` 解析出的 canvases/projects/{id}/。Monaco 编辑以 500ms 防抖写盘；Agent 的写入或 diff 在审批前先重放到不落盘的内存覆盖层，批准后正式写盘一次，拒绝只移除候选层、不动已有工作区。预览 iframe 会内联候选的 HTML/CSS/JS 并同步显示（`CanvasAgentService.ts:358-415`、`useCanvasPreview.ts:39-87`）。
- **工具结果**：工具调用先经过 `ToolCallingProtocol` 表示层，当前快照的注册表只登记 VCP 一种实现，实际通信使用它的 `<<<[TOOL_REQUEST]>>>` 文本标记。请求解析并执行后，结果被格式化成文本，写进 role 为 tool 的消息节点内容，随会话 JSON 一起持久化。结果自身没有独立对象，画布类的文件操作会直接落到物理文件。VCP 属于当前的实现范围，工具系统的抽象边界由协议接口界定。
- **持久化**：聊天会话按会话各存一个独立 JSON 文件，画布以物理文件加 Git 记录，媒体生成结果经 `importAssetFromBytes` 进入资产管理系统，并附带生成来源元数据。
- **执行位置**：模型生成的代码全部在 Tauri WebView 的 iframe 中执行，没有远端沙箱、容器或独立语言进程；聊天 HTML 与画布预览各自注入自己的 CSP。画布 iframe 只授予 `allow-scripts`，页面因此处在 opaque origin，宿主另外校验消息来源与 `origin === "null"`，其 CSP 仍放行 HTTP(S)、WebSocket、外部 frame 和 asset 资源，完整边界见第 7 节。

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

1. **审批预览停留在内存。** 预览钩子只登记待执行的变更并重建候选文件映射，正式写入并不会发生；批准后执行器调用一次真实方法，方法完成或失败后消费对应候选记录，拒绝则移除该请求并重算其余候选。候选层不落盘，应用重启或窗口异常关闭后的预览恢复尚未验证（`CanvasAgentService.ts:299-415`、`canvasStore.ts:580-640`）。
2. **运行时错误链在静态代码中已贯通。** 预览窗口把校验后的错误以 `canvas:runtime-error` 消息整包发出，主窗口总线再校验、裁剪，写入按画布 ID 分区的错误存储；Agent 上下文生成时取绑定画布的错误摘要一并传入。跨窗口时序、重复错误的去重和真实脚本报错的表现仍需运行验证（`CanvasWindow.vue:176-202`、`useCanvasSync.ts:113-151`、`CanvasAgentService.ts:32-108`）。
3. **外部文件变更由当前画布的监听接入。** 画布 store 打开项目后递归监听整个目录，跳过 `.git` 与元数据文件，其余变更按 300ms 合并，随后刷新 Git 状态、给已有错误打上过期标记并广播文件变化。监听器同一时间只绑定 store 当前打开的那个画布，多窗口或快速切换项目时的行为未验证（`canvasStore.ts:118-173`、`useCanvasStorage.ts:163-176`）。
4. **编辑任务与状态都按目标绑定。** Monaco 的防抖写盘任务在创建时记下画布、文件路径和内容，提交前先 flush、丢弃时 cancel，组件卸载还会释放文件变化监听；Git 的未提交状态按画布分区保存，Agent 上下文只读取绑定画布的那一份（`CanvasEditorPanel.vue:127-205`、`canvasStore.ts:94-116`）。用户与 Agent 之间没有 revision、CRDT 或冲突合并，并发写入以最后写入者为准。
5. **文件与 iframe 边界分两层收紧。** 存储层拒绝绝对路径、盘符、空路径段、`.`、`..` 和 NUL 字符，只把规范化后的相对路径拼进画布根目录。预览 iframe 只开放脚本执行，运行在 opaque origin 下，并注入禁止 object/form 的 CSP，宿主再校验消息来源、origin、类型和长度。CSP 仍放行 HTTP(S)、WebSocket、外部 frame 与 asset 资源，网络访问默认可通（`useCanvasStorage.ts:43-75`、`CanvasPreviewPane.vue:23-135`、`useCanvasPreview.ts:233-251`）。
6. **专项回归测试只覆盖纯逻辑部分。** `web-canvas.test.ts` 检查了相对路径拒绝、内存候选层、HTML/CSS/JS 候选内联、拒绝后不回退 HEAD、批量审批预览只分发一次以及正式方法只执行一次。真实 Tauri 窗口、文件监听、CSP 生效、运行错误回流和 Git 恢复都不在这份单测的覆盖范围内。

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

- 聊天输出由用户消息触发，模型回复以流式文本写入 assistant 节点。节点结构定义在 `src/tools/llm-chat/types/message.ts:110-416`，带稳定 ID、来源、角色、状态和一组元数据字段，涵盖模型、Agent、用量、推理内容、翻译与工具调用。**内容只存在一个纯文本字段里**，没有 Artifact 或 part 类型的结构化输出对象；另一个类型标记字段只用于区分预设消息与历史占位符，和生成内容无关。
- 聊天内容层采用**自由文本加约定标记**的形态：VCP 工具调用块、`<think>` 思考块、HTML 标签和 Mermaid 围栏都留作文本的一部分，由渲染器在展示时识别，发送和存储阶段保持原始文本（`rich-text-renderer/ARCHITECTURE.md` §3.2、§5.2）。与 typed part 类协议相比，协议解释集中在渲染层。
- 最接近 part 语义的是推理回放类型 `LlmReasoningArtifact`，它保存 DeepSeek、OpenAI、Gemini 推理内容的**回放状态**，用途是在上下文压缩后精确重放推理文本，本身只作为内部状态存在（`src/llm-apis/common.ts` 相关类型，`message.ts:282`）。

### 1.2 工具输出：文本结果节点 + 物理副作用

- tool-calling 用 `ToolCallingProtocol` 接口把工具元数据、调用请求和执行结果与模型侧的通信表示隔开。接口负责生成工具定义和用法说明、解析请求、格式化结果；解析出的统一请求再交给协议之外的发现、校验、审批、执行和循环引擎处理（职责链入口 `core/protocols/base.ts`，其余见文末源码索引）。新增一种**文本协议**可以复用现有的工具目录和执行策略；注册表目前固定登记一种实现，尚未开放运行期协议注册，也没有直接使用模型 API 的结构化 `tool_calls`。
- 协议注册表目前只登记 `vcp` 一项，解析函数对任何现有配置都路由到 `VcpToolCallingProtocol`，配置里的协议字段也被收窄成同一取值。下面的 VCP 标记语法就是这唯一注册实现的具体形态；工具系统的设计范围由 `ToolCallingProtocol` 抽象界定。
- 当前 VCP 实现由模型自由文本中的 `<<<[TOOL_REQUEST]>>> ... <<<[END_TOOL_REQUEST]>>>` 标记触发（`src/tools/tool-calling/core/protocols/vcp-protocol.ts`），只有标准请求块执行；转义请求标记用于参数内字面文本，还原后不再展开额外调用。服务端工具批次先被遮蔽，避免结果里的示例被二次执行（`vcp-protocol.ts:358-427`）。
- 执行结果由当前协议序列化成文本，写进 role 为 tool 的消息节点，节点的工具调用元数据逐条记录请求 ID、工具名、状态、耗时和原始参数（`useToolCallOrchestrator.ts:325-345`）。**结果不物化为独立对象**；工具若有物理副作用，例如画布写文件，对象身份就落在文件侧。
- 工具节点支持"重新解析"，即对节点已有内容重新走一遍工具调用检测与执行，是后续回合重入的入口（`reparseAndOrchestrate`，`useToolCallOrchestrator.ts:449`）。

### 1.3 画布对象模型

- 画布项目带稳定 ID，格式为 `cp_{yyyyMMdd}_{shortId}`，另含名称、模板、入口文件和创建、更新时间；每个项目的元数据写在 `.canvas.json`，全局索引写在 `projects.json`（生成规则见 `web-canvas/utils/id.ts:22`，结构见 `web-canvas/ARCHITECTURE.md` §2）。
- **事实源是磁盘文件加 Git**：常规编辑直接写盘，没有内存 VFS；审批中的候选内容只存在于瞬时覆盖层。画布打开后，store 递归监听当前项目目录，外部编辑器的改动经合并后刷新 Git 状态并通知编辑器和预览（`canvasStore.ts:118-171`、`useCanvasStorage.ts:163-173`）。画布与聊天的衔接有两个用户侧入口：聊天输入区的"画布控制"负责绑定、新建、预览和跳转管理，输入工具栏另有 web-canvas 开关（`MiniCanvasControl.vue`、`MessageInputToolbar.vue:163-196`）；把聊天中模型生成的 HTML 一键转入画布的通道本次未找到，渲染器代码里也没有画布引用。
- 项目索引与项目元数据分开存放，索引损坏时可由修复逻辑重建（`repairProject`，`canvasStore.ts:511`）。

### 1.4 媒体输出：任务对象 + 资产对象

媒体生成不走消息文本，而是"任务 + 资产"两层对象：`useMediaGenerationManager` 为每次生成建立带状态流转（排队、处理中、完成、失败/取消）、取消与超时控制的任务，任务结束后结果写入资产系统并带 `type: "generated"` 的来源元数据与衍生数据，消息附件再引用资产。协议侧由 `packages/llm-core/src/providers/openrouter-media.ts` 新增 OpenRouter 的图片、音频与视频任务三类适配器，把尺寸、比例、分辨率、质量、种子与输出编码映射到上游请求；参考图在本地保留结构化引用，由原生 transport 转成 data URL。资产与任务的绑定、工作区状态与预览表面见媒体创作笔记。

## 2. 增量生成、更新与最终化

### 2.1 聊天流式

- 流式注入按 token 进行：响应处理器把每个 chunk 追加到节点内容，同时写入按节点 ID 缓存的可重放流源，渲染器再以 AST patch 更新界面，常见操作是文本追加、节点替换和后插（`useStreamingMessageSources.ts:20-89`、`rich-text-renderer/ARCHITECTURE.md` §3.4）。
- 渲染器内部是**整段文本重解析加 patch**：自研的 V2 解析器把文本分成稳定区和待定区，稳定区复用已有 AST，待定区每次重新解析，再由 diff 生成 patch。解析粒度是文本区段，没有细到单个 AST 节点的增量，也没有引入外部的 diff/patch 协议（`core/StreamProcessorV2.ts`）。
- 最终化分三种结果：请求正常完成时释放流源；失败时由错误处理函数把信息写入节点的错误元数据，并在界面上显示可复制的错误条；空响应则记录一条诊断信息（`useChatResponseHandler.ts:503,647`）。
- 网络层的流式节流与 VCP 协议块冲刷由 `core/StreamController.ts` 统一处理，保证协议块不会被平滑输出拆碎（`rich-text-renderer/ARCHITECTURE.md` §3.4）。

### 2.1.1 服务端分段响应与本地媒体结果

服务端 VCP 交互可把同一网络响应拆为独立助手/工具树节点，执行器串接段落、切换流源、重挂排队后代，并在元数据保存共同请求 ID 和各段状态；历史里的工具批次依然有正文解析路径。文本之外，本地工具媒体引用作为消息字段保存，后续请求经附件管道转为多模态；分布式回传时另按外传规则重新读取并物化为 data URL，避免远端尝试访问本机路径（`useSingleNodeExecutor.ts:337-470`；`vcp-connector/services/vcpNodeProtocol.ts:469-520`）。

这些产物各有稳定消息/资产引用，没有升级为通用 Artifact 工作区；实发请求快照独立关联其多个节点。消息和快照持续性见[会话与消息管理](<../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md>)，实际请求编排见[对话请求与上下文](<../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md>)。

### 2.2 画布更新

- Agent 侧：Search/Replace diff 引擎 `applySearchReplaceDiff` 按 exact、trimEnd、trim、fuzzy 四级依次尝试匹配，fuzzy 使用 Bigram Dice 相似度，阈值 0.85；引擎还处理行号剥离、起始行消歧、缩进修复和重匹配警告，应用成功后写盘并刷新 Git 状态（`web-canvas/utils/diff.ts:71`；`canvasStore.ts:354-398`）。
- 用户侧：Monaco 以纯 ESM 方式加载，编辑内容整体在 500ms 防抖后写盘。防抖任务在创建时记下当时的画布、文件路径和内容，提交前先 flush、丢弃时 cancel，组件卸载时先 flush 再 cancel（`src/utils/monaco.ts`、`CanvasEditorPanel.vue:133-169,214-219`）。
- 应用内部的写入经文件变化事件触发预览刷新和分离窗口通知，画布目录的递归监听把外部编辑器的写入合并进同一类刷新；预览刷新另有 300ms 防抖（`canvasStore.ts:146-171`、`useCanvasPreview.ts:39-87`）。

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
- **移动端**：独立渲染器基于 marked，HTML token 进入 pre 插值转义显示；有独立公式、Mermaid、VCP 和媒体组件，流式更新约 80ms 合并。当前检查入口未提供桌面 HTML iframe 运行预览，HTML 字面显示、结构化图表与任意脚本执行分别走不同边界（`mobile/src/tools/rich-text-renderer/RichTextRenderer.vue:1-11,44-65,513-515`）。

## 5. 用户交互、事件与错误反馈

- **HTML 沙箱回传**：iframe 用 `postMessage` 把事件发给宿主，宿主的消息处理只把 error 级日志收进错误列表，上限 200 条，界面上提供错误浮窗、复制和清空；卸载时清空 srcdoc 并跳转 `about:blank` 释放资源（`HtmlInteractiveViewer.vue:517-583,596-603`）。事件分三类：
  - `iframe-log`：console 捕获
  - `iframe-height`：自适应高度
  - `iframe-mousemove`/`enter`/`leave`：悬浮状态
- **画布回传**：独立预览 iframe 回传控制台与运行时错误两类事件。宿主要求消息来自当前 iframe 的 opaque origin，随后校验类型并裁剪字段；窗口内的错误存储负责去重、限流和过期标记（`CanvasPreviewPane.vue:67-145`、`CanvasWindow.vue:165-202`）。
- **错误反馈去向**：预览窗口通过窗口总线发送完整的运行时错误消息，主窗口再次校验后写入对应画布的错误存储，Agent 上下文再读这份存储。静态代码因此已构成"iframe -> 预览窗口 -> 主窗口 -> Agent"链路，真实窗口的通信时序和错误触发效果仍需运行验证（`useCanvasSync.ts:113-151`、`CanvasAgentService.ts:32-108`）。
- **运行状态恢复**：`MessageList.vue` 有 keep-alive 滚动位置恢复（:73-99）；画布分离窗口关闭后重新打开时从磁盘重新加载（`CanvasWindow.vue:137-158`）；弹幕覆盖窗等桌面窗不在本类目。

## 6. 编辑、diff、版本与协作

- **聊天消息编辑**：编辑只做全文覆盖，仅对 user 和 assistant 角色开放；"保存到分支"把内容复制到兄弟节点形成新分支（`useBranchManager.ts:108-156,162-209`）。编辑没有选区级操作和结构化 patch，撤销栈也不持久化，会话存储中已明确移除 history 字段（`useChatStorageSeparated.ts:199-204`）。版本表达依赖消息树的分支语义，属于聊天类目，这里只记交接点。
- **画布编辑**：用户和 Agent 修改的是同一组磁盘文件。Agent 通过 Search/Replace diff 写入，带 fuzzy 降级和置信度反馈；用户侧由 Monaco 全量覆盖，外部文件变化经递归监听接入刷新（`CanvasAgentService.ts:168-190`）。代码中没有 CRDT 或基于 revision 的冲突检测，并发写入以最后写入者为准。
- **版本与 Git 适配**：提交与丢弃由 store 调用 isomorphic-git，服务层已具备初始化、暂存、提交、历史、检出和状态查询。Tauri IPC 返回的是字符串错误，适配层把它包装成可写 Error 并保留 cause 与 code，避免 Git 内部补写错误属性时二次失败；文件类型用 lstat 读取，符号链接的读写仍是简化实现。专项测试覆盖空目录初始提交、历史、修改状态和检出恢复，并检查权限错误可诊断（`GitInternalService.ts:47-151`；`__tests__/GitInternalService.test.ts:102-129`）。画布组件和调用点中仍未找到提交历史查看器或文件 diff 界面，服务层能力与界面开放程度需分开看。
- **接受与拒绝**：工具调用的审批界面在 `ToolCallMessage.vue`，以待批状态展示请求。画布的写入和 diff 在批准前只登记变更，候选结果放进内存覆盖层供预览；批准后正式方法只写盘一次，拒绝只移除该请求的候选层，Git HEAD 保持不动。覆盖层不落盘，重启后无法作为事务日志恢复（`CanvasAgentService.ts:299-415`、`canvasStore.ts:580-632`）。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：模型输出全部跑在前端 JS 上下文，工具方法在 Tauri WebView 主窗口内直接调用注册表实现，入口从 `tool-calling/core/executor.ts:177` 起。底层文件与 Shell 能力由 Tauri 插件（fs、shell、dialog 等）和 Rust 命令承担，后者包括画布独立窗口与目录树生成（`src-tauri/Cargo.toml`、`canvas_window.rs`、`generate_directory_tree`）。**未找到**容器、远端沙箱或独立进程执行模型的代码。
- **iframe 沙箱与 IPC 隔离**：聊天 HTML 沙箱和画布预览都没有向生成代码提供窄化的 Tauri API。画布 iframe 的 sandbox 只含 `allow-scripts`，不带 `allow-same-origin`，srcdoc 因此处在 opaque origin；宿主再校验消息来源窗口、`origin === "null"`、消息类型和字段长度。这套隔离在 Tauri WebView2 中的实际强度仍需运行验证（`CanvasPreviewPane.vue:23-145`）。
- **CSP 现状**：应用级 CSP 在 `src-tauri/tauri.conf.json:15` 处为 null，`index.html:6-8` 里的 meta 策略较宽；聊天和画布各自向预览文档注入 CSP。画布策略禁止默认来源、object 和 form，但对脚本、样式、媒体、连接和 frame 放行 asset、HTTP(S) 与 WebSocket 等来源，隔离宿主同源能力的同时仍允许访问网络（`useCanvasPreview.ts:233-251`）。
- **能力授予**：执行器支持工具级安全策略，可取值 block 或 approve；Agent 侧再按工具与方法的自动批准、手动审批矩阵控制执行（`executor.ts:156-169,421-423`）。文件操作工具另有白名单与黑名单两种沙箱模式约束可写范围，属工具自身策略（`src/tools/aio-file-operator/composables/useFileOperator.ts:32`）。
- **asset 协议**：`tauri.conf.json:16-23` 启用了 assetProtocol，scope 为通配 `**` 加 `$APPLOCALDATA` 与 `$APPDATA`。iframe 因此可通过 `asset://` 读取本地资产，可访问范围较宽（事实记录，不做整改建议）。
- **文件路径边界**：画布存储入口先校验画布 ID，再把反斜杠统一成斜杠，并拒绝绝对路径、盘符、NUL、空目录段、`.` 和 `..`；读写删方法都用规范化后的相对路径拼进项目根目录（`useCanvasStorage.ts:35-69,106-159`）。Tauri 的文件权限配置较宽，画布目录边界主要由这层应用校验落实。
- **交互按钮窄桥**：模型生成的 `<button>` 只能触发 send、input、copy 三个白名单动作，是当前唯一的"声明式控件到宿主动作"通道，对应 G2 级元素（`ActionButtonNode.vue:28,93-117`）。

## 8. 持久化、恢复、分享与导出

- **聊天会话**：每个会话一个 JSON 文件，文件名即会话 ID，存放在 `{appConfigDir}/llm-chat/sessions/` 下，另有一份 `sessions-index.json` 索引。保存时先比对内容避免无谓写盘，批量保存带防抖；索引缺失时可通过目录扫描自愈（`useChatStorageSeparated.ts:98-242,321,642-660`）。恢复流程是启动时加载索引、再按需读取对应会话。导出与分享属聊天类目，本次未展开。
- **画布项目**：由物理文件、`.canvas.json` 元数据和 `projects.json` 索引组成，索引采用原子写并可修复；健康检查把异常分成缺失、未登记和损坏三种状态（`CanvasService.performHealthCheck`）。对外分享只有"在 VSCode 中打开"和 Git 提交两条途径，本次未找到打包导出或分享链接功能（`canvasStore.ts:527`）。
- **媒体生成**：任务先进入所有媒体工作区共享、由 `maxConcurrentTasks` 限制的模块级队列，获得槽位后再发送请求；任务状态机覆盖排队、执行、取消与超时，异步任务通过任务管理器跟踪。结果经 `importAssetFromBytes`/`importAssetFromPath` 进入资产系统（`useMediaGenerationManager.ts`），origin 标记 `type: "generated"`，并写衍生数据 JSON；消息附件引用这些 Asset，构成"生成 -> 入库 -> 可复用"链（G1 级物化）。转到 VCP 分布式调用时，图片类结果以 `data:` URL 形式随工具结果回传，避免远端节点无法访问本地 asset 路径（见外部执行体笔记的分布式媒体结果一节）。
- **HTML 预览导出**：Blob URL 新窗口打开（`HtmlInteractiveViewer.vue:636-649`），可另存为单文件；无版本概念。

## 9. 模型回流、对象感知与持续维护

- **画布**：文件读写与运行反馈的闭环在静态代码中已成立，链路如下：
  - 查询：`getExtraPromptContext`（`CanvasAgentService.ts:32-113`）注入项目名、入口文件、文件树、对应 canvasId 的未提交变更和运行时错误摘要；变更集合按画布分区，预览错误经窗口总线回到主窗口；
  - 读取：`read_canvas_file` 带行号返回（:118-139）；
  - 定向修改：六个 `agentCallable: true` 的画布方法（`web-canvas.registry.ts:84-241`）：
    - `apply_canvas_diff`：含策略/行号/警告反馈
    - `write_canvas_file`
    - `create_canvas`
    - `commit_changes`
    - `discard_changes`
    - `clear_runtime_errors`
  - 身份绑定有**三个入口**：Agent 设置页的画布绑定字段（`web-canvas.registry.ts:41-54`）；聊天输入区的画布控制组件，把所选画布写入工具的 canvasId 设置（`MiniCanvasControl.vue:70-93`）；隐式新建画布后，由自动创建事件完成绑定（:125-131）。
  - 身份绑定的兜底与限制：无绑定/无激活画布时 `ensureActiveCanvas` 隐式创建（`canvasStore.ts:218-236`）；项目文件、Git 变更和错误上下文都按 canvasId 读取，但 watcher 一次只绑定 store 当前打开的画布。
- **聊天（有限回流）**：模型能感知的只有上下文历史，也就是消息文本本身；"重新解析"和"续写"两种操作允许对已有节点继续生成。聊天注册表里 10 个可被 Agent 调用的方法全部围绕**智能体管理**，覆盖 Agent 的列出、搜索、读取和设置，预设消息的增删改查与查找替换，以及导入导出，没有一项针对会话中已生成的输出消息。本次未找到模型对会话消息对象的列出、读取或定向修改工具（`llm-chat.registry.ts:270-532`；`message.ts:385-389`）。
- **媒体生成**：模型通过 `media-generator` 的 `generate_<model>` 方法直接发起生成，任务与资产结果关联（`mediaGenStore`），模型可读取任务状态但不可直接读改资产字节；生成参数与提示词由模型控制，结果落资产库后由消息附件或画布引用。
- **子智能体任务**：委派结果落标准子会话消息和独立任务快照。同步模式等待回复，后台模式先返回句柄，任务中心和伴生分栏读快照及子会话；实际生成仍在主 WebView 异步链，同子会话车道串行。恢复快照把未完成项结算为 interrupted，不自动续推理；独立 background-runtime 尚未托管该执行链。工具契约见[Agent 工具](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)，不据此提升为跨进程持续维护级别。

## 10. 生命周期、资源治理与性能

- **不可见对象**：仍在活动路径上的消息只保留轻量行壳，阅读区之外的显示树可被回收，接近视口时再恢复；草稿、编辑和锚定状态各有独立的保留条件。HTML 预览还按消息深度冻结，弹窗打开时冻结内嵌预览，以免同时运行两份。显示树与 AST 的释放、恢复边界见[消息渲染器](<../消息渲染器/AIO-Hub-消息渲染器调查笔记.md>)，整套资源治理还涉及渲染器的 AST 生命周期，content-visibility 只概括其中一部分。
- **释放**：HTML 沙箱卸载时清空 srcdoc 和 src；流源在完成时立即 dispose；渲染器调用 AST 的 dispose 方法，各节点组件取消未完成的异步任务并释放 Blob URL；错误列表有固定上限，iframe 为 200 条，画布默认 10 条；预览刷新防抖 300ms，编辑写盘防抖 500ms（`HtmlInteractiveViewer.vue:596-603`、`useStreamingMessageSources.ts:131`、`rich-text-renderer/ARCHITECTURE.md` §3.7）。
- **限额**：流式渲染设有安全护栏，超限后降级停止 patch（`safetyGuardEnabled`）；patch 队列上限为 1000 条。token 限制与上下文压缩属聊天类目。
- **长时间会话与多画布**：画布窗口注册表和关闭清理逻辑共同维护窗口生命周期登记；本次未找到针对多画布并发 Agent 会话的显式配额（`canvas_window.rs:32-33,160-173`）。

## 11. 测试、已确认边界与未验证事项

### 11.1 验证体系（未运行）

- 本篇采用静态复查，未安装依赖、运行测试或启动应用。下面只列出已读测试覆盖的契约范围，结果未经验证：
  - rich-text-renderer：`composables/__tests__/useMarkdownAst.test.ts`、`parser/block/__tests__/parseVcpRole.test.ts`；
  - llm-chat：`useStreamingMessageSources.test.ts`、`emptyResponseDiagnostics.test.ts`、`message-format-processors.test.ts`、`sessionManagers.test.ts`、`PipelineEngine.test.ts` 等 10 个文件；
  - tool-calling：`__tests__/tool-calling.test.ts` 检查协议解析与执行器，另有 `web-distillery.registry.test.ts`；
  - web-canvas：`__tests__/web-canvas.test.ts` 覆盖路径校验、审批候选覆盖层、HTML/CSS/JS 内联、拒绝语义、批量审批与单次正式执行。
- Git 适配另有专项测试，用模拟的 IPC 文件系统覆盖初始提交、状态与历史、检出恢复；真实 Tauri 窗口、文件监听、WebView CSP、跨窗口错误同步和保存恢复的端到端流程仍待运行验证。

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
- 移动渲染器基于 marked，HTML 原文进入 pre 转义显示，另有公式、Mermaid、VCP 与媒体节点组件；本次入口检查未见桌面 HTML 代码 iframe 运行时。图表展示与任意 HTML 执行分开判断，渲染细节见[消息渲染器](<../消息渲染器/AIO-Hub-消息渲染器调查笔记.md>)。
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
- `src/tools/media-generator/composables/useMediaGenerationManager.ts`：生成任务状态机、队列与资产入库
- `packages/llm-core/src/providers/openrouter-media.ts`：OpenRouter 图片/音频/视频任务适配器（`:19-173`）
- `src/tools/media-generator/ARCHITECTURE.md`：媒体协议、输入工作区与资产链说明
