# RikkaHub 消息渲染器调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：静态阅读 Jetpack Compose 消息组件、Markdown/富文本渲染（外部 BetterText 库与主题插槽）、流式合并链路与 WebView 承载路径，并对照 `web-ui/` 的 React 渲染作为同项目 Web 端参考
>
> 调查范围：`UIMessagePart` 各类型到可见组件的映射、Markdown/代码/数学/Mermaid 渲染、流式合并与增量展示、reasoning/工具卡/附件/翻译的展示，以及 BetterText 高亮接入边界；不覆盖网络协议解析、持久化 schema、Composer 与导出语义
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的消息渲染是纯原生 Compose 实现，不存在 DOM。消息内容以 `UIMessagePart` 密封类表达，渲染时先由 `groupMessageParts()` 把连续的 reasoning 与工具部分聚成一个“思考块”，其余部分按原始下标生成内容块，再逐块分派到 Compose 组件（`ChatMessage.kt`）。部件类型的字段定义、分支节点与持久化约束由会话与消息管理笔记负责，见 [会话与消息管理调查笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

Markdown 与富文本渲染已整体迁移到外部 Compose 库 BetterText：应用侧 `MarkdownBlock` 只负责主题与组件插槽（代码块、图片、公式、表格、citation、颜色代码块），解析、排版与流式补全由库完成。代码高亮同样由 BetterText 的 highlight 模块提供。Mermaid 仍在 WebView 中执行本地脚本并桥接导出 PNG，html/svg 预览另走一条 WebView 路径。

流式输出把每个 chunk 按事件 id 合并进末条助手消息，由 `ChatRequestFactory` 调用输出变换器产生展示态与持久态两条流；最终落库用 `onGenerationFinish()` 的结果（`ChatRequestFactory.kt`）。请求侧的流式事件、节流与半截流语义见 [对话请求与上下文调查笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。

## 总体渲染链路

1. 提供方推送的流事件先由合并器归并成一条 `UIMessage`；请求工厂对每个 chunk 依次做存储转换与展示转换后发出，消息服务据此更新会话状态流，界面在生命周期内收集这个 `MutableStateFlow<Conversation>`（`ChatRequestFactory.kt`、`ChatService.kt`）。
2. `ChatList` 用 `LazyColumn` 按 `MessageNode.id` 渲染消息项（`ChatList.kt`）。
3. `ChatMessage` 组装头像、`MessagePartsBlock`、翻译、操作栏与统计行（`ChatMessage.kt`）。
4. `MessagePartsBlock` 分组后分派：文本/图片/视频/音频/文档进入 Compose 组件，reasoning 与工具进入 `ChainOfThought` 时间线（`ChatMessage.kt`）。

## 1. 消息壳层与部件分派

`ChatMessage` 按角色决定对齐方向：用户消息靠右，其余靠左。头像行只在消息非空时显示，用户侧受 `showUserAvatar` 控制，助手侧按是否使用助手头像在模型图标与助手头像间切换（`ChatMessageAvatar.kt`）。

文本 part 的分派逻辑（`ChatMessage.kt`）：

- 用户文本包在 `primaryContainer` 圆角气泡内，点击触发编辑回调。
- 助手文本在 `showAssistantBubble` 开启时包气泡，否则直接渲染。
- 文本在进入 `MarkdownBlock` 前先经过助手正则的视觉替换。

非文本 part 的渲染去向：

| part 类型 | 消息内渲染 |
|---|---|
| `Image` | `ZoomableAsyncImage`；`url` 为空或仅剩 data 前缀时显示 shimmer 占位（`ChatMessage.kt`） |
| `Video`、`Audio`、`Document` | 带图标的 `Surface` 芯片，点击用 `FileProvider` 发出 `ACTION_VIEW`；文档按 mime 选择 docx/pdf/通用图标并显示文件名（`:431-569`） |
| `Reasoning` | 思考块时间线内的推理步骤，见第 5 节 |
| `Tool`、`ServerTool` | 工具卡，由 `ToolUIRegistry` 解析渲染器，见第 5 节 |
| 已废弃的 `Search`、`ToolCall`、`ToolResult` | 直接跳过 |

部件类型的完整字段与分支语义由会话与消息管理笔记展开；生成图片的落盘与画廊由媒体创作笔记负责，见 [媒体创作调查笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。

注解（引用）在消息末尾折叠展示，展开后逐条显示 favicon 与可点击标题；正文里的 citation 徽标会回查 `search_web` 工具输出中的 `items`，按 id 匹配后打开 url（`ChatMessage.kt`、`:285-304`）。

操作栏在消息末尾显示，包含复制、重新生成、TTS、翻译与更多；助手消息才有 TTS 与翻译，分支切换器在节点有多个候选时出现，最后可选显示时间（`ChatMessageActions.kt`、`ChatMessageBranch.kt`）。统计行按设置显示 token 用量、缓存 token、TPS 与耗时（`ChatMessageNerdLine.kt`）。

## 2. 流式数据到 UI 的更新链

**从合并结果到状态流。** 合并层的有状态细节属于请求侧语义，见 [对话请求与上下文调查笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)；本节只看它产出的 `UIMessage` 如何驱动画面。

**展示层与持久层的分叉。** 输出变换器接口 `OutputMessageTransformer` 提供两个钩子：visualTransform() 用于流式展示，onGenerationFinish() 用于生成收尾，定义见 `data/ai/transformers/Transformer.kt`。请求工厂对每个 chunk 先调用 transforms() 得到“存储态”，再调用 visualTransforms() 发出展示消息；生成结束后追加一次 onGenerationFinish() 再发出最终消息（`ChatRequestFactory.kt`）。

具体到两个实现：

- 思考标签变换器在展示期把 `<think>...</think>` 包裹的文本转成 Reasoning 部件，标签未闭合时把 finishedAt 留空；生成结束时再做一次同样的转换并补上 finishedAt，实现在 `data/ai/transformers/ThinkTagTransformer.kt, 36-81`。
- `RegexOutputTransformer` 在展示期把助手正则应用到文本与推理，`visual = false`（`data/ai/transformers/RegexOutputTransformer.kt`）。

由于 `onGenerationFinish()` 的结果会随最终 `GenerationChunk.Messages` 写入会话状态，思考标签转换在完成后是持久化生效的，而展示期中间态仅用于流式画面。

**更新频率。** 每收到一个流式 chunk，消息服务就对会话状态赋值一次，自身没有 debounce 或 conflate 之类的节流（`ChatService.kt`）。重渲染压力主要靠两处收敛：Markdown AST 解析移入后台线程（见第 8 节），以及仅在内容稳定时才启用 SelectionContainer；后者用于规避流式期可选文本频繁注册/注销与选择工具栏绘制期排序引发的并发修改异常（ConcurrentModificationException），代码在 `ChatMessage.kt`。

## 3. 消息列表、窗口化与滚动

消息列表把完整的 messageNodes 交给 LazyColumn 渲染，键取节点 id，没有分页或额外虚拟化；列表尾部带加载指示项与滚动定位占位项。自动滚动在启用时监听可见项，只在用户未手动滚动且列表停在底部时滚到底部，另有音量键滚动与 ImeLazyListState 的键盘跟随（`ChatList.kt`，音量键滚动见 `:218-234`）。

`previewMode` 会切换到另一套列表：带搜索框、按文本过滤消息、逐条显示单行摘要并支持点击跳转原文（`ChatList.kt`）。消息跳转控件由最近滚动状态触发（`:749-849`）。滚动锚定依赖 `LazyColumn` 的 key 稳定，分支切换通过 `MessageNode.selectIndex` 改变选中消息，节点 id 不变。

## 4. Markdown、代码与富文本管线

- **解析与分派。** MarkdownBlock 是应用侧的统一入口，把内容交给 BetterText 的 Markdown 模块解析与排版，自身只构造主题与组件插槽：正文样式合并 LocalTextStyle 与 LocalContentColor，标题字号按正文字号等比缩放，块间距与 fontSize 联动，引用色可按设置开启；传入 streaming 后，库会补全或隐藏末尾未写完的语法，例如 `**加粗`、`$\frac{` 这类半截标记（`Markdown.kt` 的 MarkdownBlock）。

**组件插槽。** MarkdownBlock 通过 BetterText 的 MarkdownComponents 注入 Material 组件，各内容类型的分派方式如下：

- 代码块交给 `HighlightCodeBlock`，流式未闭合围栏是否高亮由 `completeCodeBlock = block.closed` 决定。
- 图片交给 `ZoomableAsyncImage`，工作区路径先经 `rememberWorkspaceImageUrl` 解析成宿主文件路径。
- 块级公式交给 `MathBlock`，行内公式交给 `LatexInline`；关闭 LaTeX 渲染时两者都不注册，公式回退为等宽源码。
- 表格交给 `TableCard`，链接交给 citation 徽标逻辑。
- 行内代码与正文里的颜色代码经 `parseColorCode` 前置色块。

MaterialMarkdown 是不带聊天特化的默认包装，中文注释说明它供悬浮窗等拿不到导航上下文的场景使用；它的默认组件未注册公式与高亮。

**表格。** 表格数据来自 BetterText 的 `MarkdownBlock.Table`，用自定义 `DataTable` 渲染（SubcomposeLayout 两阶段测量加横向滚动），工具栏提供复制原始 Markdown 与导出 CSV（`Markdown.kt` 的 `TableCard`/`buildTableCsv`）。

**代码块。** `HighlightCodeBlock` 保留复制、按语言映射扩展名导出文件、html/svg 内联与新窗口预览、超长折叠、行号与自动换行切换；着色由 BetterText 的 `rememberHighlightedCode` 提供（`CodeHighlightText` 是同源的轻量版，供工具调用预览这类不需要并入正文选择的场景）。文档级代码块与正文共享同一个 `BetterSelectionContainer`，因此可以连续选择（`SelectableContent.kt`）。

**数学公式。** 块级公式用 `MathBlock`（内部是 BetterText 的 `LatexBlock`），行内公式用 `LatexInline`；公式换行与排版由 BetterText 负责。公式渲染失败或关闭 `enableLatexRendering` 时回退为等宽源码。

**高亮实现。** 高亮与语言定义来自 BetterText 的 `bettertext-highlight`，配色走 `HighlightTextColorPalette`（默认配色与 web-ui 的 Atom One 同源），应用侧不维护语言清单。

**Mermaid。** Mermaid 代码块把源码与主题色注入 WebView，页面加载本地 `assets/html/mermaid.min.js` 后经 `mermaid.initialize`/`mermaid.run` 渲染成 SVG（`Mermaid.kt`）。导出时页面内函数把 SVG 序列化、画到 canvas 转 PNG，经注入的 `AndroidInterface` 回传 base64，Kotlin 侧解码写入相册目录。

## 5. 工具、reasoning、附件与自定义节点

**思考块与时间线。** 连续的推理、本地工具与服务端工具部件聚成一个思考块，遇到正文或附件就结束当前分组，索引保持原始部件下标（`ChatMessageCot.kt` 的分组函数）。通用时间线默认折叠前面的步骤、显示末尾若干步，顶部按钮可展开全部；仅含推理时使用自适应宽度。

**待审批步骤的可见性。** 有工具等待用户动作时，折叠可见范围扩展至最早待审批步骤及其后的全部步骤，使批准、拒绝或问答入口始终可见；动作仍交给服务更新审批状态并恢复 Agent 循环。见 [ChatMessage 的折叠条件](../../rikkahub/app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessage.kt#L341-L380)。

**推理展示。** 推理步骤按 `createdAt` 记忆状态，含折叠/预览/展开三态；流式期间若开启显示思考内容，自动进入“预览”态并滚到底部，用渐变遮罩把高度限制在约 100dp（`ChatMessageReasoning.kt, 96-118`）。生成结束后按 `autoCloseThinking` 决定收起或保持展开并显示耗时（`:136-168`），标题优先取推理文本中最后一整行加粗文本（`utils/MarkdownUtils.kt`）。

**工具卡。** 工具步骤组件先从 `ToolUIRegistry` 取该工具对应的渲染器，未注册的工具回退到默认实现；渲染上下文会预先备好入参 JSON 与输出 JSON。标题、图标、内联摘要与详情预览都由渲染器提供，默认详情用 HighlightCodeBlock 以 JSON 展示入参与输出，图片输出用 ZoomableAsyncImage。待审批时显示拒绝与批准按钮，拒绝走带原因的对话框；详情在 ModalBottomSheet 内展开，输出图片在摘要区横向排列。入口在 `ChatMessageTools.kt`，渲染器注册表与默认实现在 `tools/ToolUI.kt`。

`ask_user` 不走注册框架，单独渲染为可交互问答：按问题渲染选项 chip 或文本输入，支持单选/多选，提交后汇总成 JSON 答案（`ChatMessageTools.kt`）。服务端工具渲染为简单步骤，不再有审批控件（`:65-91`）。注册表覆盖记忆、搜索、抓取、时间、剪贴板、TTS、屏幕时间、日历、技能、近期会话、文件编辑/读/写与 Shell 等工具（`tools/ToolUI.kt`），另有工作区与内置工具的实现文件。

**附件与图片全屏。** 附件在消息内以芯片形式存在，点击交给系统应用处理。图片用 `ZoomableAsyncImage`：Coil 加载、跨淡关闭、支持占位图，点击打开全屏查看器；全屏用可缩放分页器并在底部提供保存动作（`richtext/ZoomableAsyncImage.kt`、`ui/ImagePreviewDialog.kt`）。

**翻译展示。** 翻译文本存在 `message.translation`，渲染为可折叠卡片；内容等于本地化“翻译中”文案时显示转圈与呼吸文字，否则用 Markdown 渲染（`ChatMessageTranslation.kt`）。翻译的写入与流式更新由请求侧驱动（`ChatService.kt`）。工作区写/编辑文件工具另会汇总“已编辑文件”列表（`ChatMessageEditedFiles.kt`）。

## 6. HTML 与内容承载边界

消息正文不执行脚本、不内嵌 iframe：

- Markdown 与内嵌 HTML 片段都由 BetterText 的 Compose 渲染器绘制，应用侧不使用 Jsoup 白名单；jsoup 目前只被 search 模块用于解析 Bing 搜索结果页。
- WebView 只用于 Mermaid、html/svg 代码预览与「用 WebView 渲染」预览；WebView 组件已移入公共 `ui` 模块（`ui/src/main/java/me/rerere/ui/webview/WebView.kt`），虚拟域名 `rikkahub.local` 与本地 assets 映射保留（`WebViewLocalAssets.kt`）。
- 消息操作菜单的“用 WebView 渲染”把文本 part 转成 HTML 模板并跳转到独立 WebView 路由（`ChatMessage.kt` 的 `buildMarkdownPreviewHtml`）；模板加载 `assets/html/mark.html`，其中 marked.js、KaTeX、highlight.js、Mermaid 均从 CDN 导入，故该路径渲染依赖网络（`MarkdownWeb.kt`、`app/src/main/assets/html/mark.html`）。

预览 WebView 由统一组件提供，按用途注入不同的命名 JavaScript 接口：代码块预览注入空接口集，页面上只有自身脚本可运行；Mermaid 预览注入 `AndroidInterface.exportImage`，让页面把渲染出的 SVG 转成 PNG 回传宿主（`ui/components/richtext/Mermaid.kt`）。Mermaid 脚本随应用打包并提供，拦截器把虚拟域名 rikkahub.local 下的 `/assets/` 前缀映射到应用 assets，因此该路径不依赖外网（`ui/components/webview/WebViewLocalAssets.kt`）。web-ui 工作台对 html、svg、markdown、mermaid 四类语言提供预览，其中 mermaid 在 iframe 内从 esm.sh 动态导入，属该端自有路径（`web-ui/app/components/workbench/workbench-host.tsx`）。

WebView 的沙箱姿态（脚本默认开启、无 CSP 与来源白名单）与执行位置，以及 QuickJS 工具、PRoot shell 与 web-ui 工作台 iframe 属生成式输出与运行时笔记的边界。

## 7. 内容交互反馈与可访问性

- **复制**：操作栏的复制按钮调用消息的 toText()（只拼接文本类部件）写入剪贴板，位置见 `ChatMessageActions.kt` 与 `utils/ChatUtil.kt`。“选择并复制”在底部弹层内用选择容器展示所有非空文本部件，并提供“复制全部”。
- **代码块操作**：复制原始代码、按语言映射扩展名后导出文件、html/svg 内联预览切换与新窗口预览、超长折叠（阈值 10 行）、行号与自动换行组合（`HighlightCodeBlock.kt, 353-472`）。
- **表格操作**：复制 Markdown 原文与导出 CSV（`Markdown.kt`）。
- **工具审批反馈**：`onToolApproval`/`onToolAnswer` 回调由消息链路上抛，工具卡依据返回的审批状态重渲染；拒绝原因内联显示为错误色文本（`ChatMessageTools.kt`）。
- **流式期间选择**：正文与推理使用 BetterText 的选择容器，生成中同样可选择；代码块通过公共包装并入外层选择范围，避免嵌套容器抢走选区。见 [SelectableContent](../../rikkahub/app/src/main/java/me/rerere/rikkahub/ui/components/richtext/SelectableContent.kt#L10-L25)、[推理内容](../../rikkahub/app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessageReasoning.kt#L174-L189)。工具栏与持续更新并发时的实际体验未验证。
- **触感反馈**：开启时，流式期间对 parts 变化做 50ms debounce 后触发键盘触感（`ChatMessage.kt`）。

## 8. 性能、缓存与测试

- **解析与高亮的线程归属**：解析、排版与着色都在 BetterText 内部完成；解析任务的后台调度由库自行安排，流式补全也通过 `streaming` 参数交给库处理，应用侧只负责递交内容。
- **代码高亮长度上限**：上限由 BetterText 的 `rememberHighlightedCode` 决定，应用侧不另设阈值。
- **测试**：原 highlight 模块的 `CodeHighlighterTest`、`HighlightEngineTest`、`RegexesTest`、`LanguageFixtureTest` 与 `hljs` 夹具随模块移除；相关回归覆盖转移到 `ai` 与 `app` 的单元测试（本笔记未逐条确认新增用例覆盖范围）。
- **缓存**：WebView 内容通过 `WebViewContentCache`（`ui` 模块）以内容 id 落盘复用（Mermaid、代码预览与 WebView 预览均使用）。消息列表本身无渲染缓存，依赖 Compose 重组与稳定 key。

## 9. 扩展方式与已确认边界

- **新增工具渲染器**：实现 `ToolUIRenderer` 接口并注册进 `ToolUIRegistry` 的渲染器列表即可；没有注册的工具会回退到默认渲染器（`tools/ToolUI.kt`）。
- **新增高亮语言**：语言定义与别名由 BetterText 的 highlight 模块提供，应用侧不暴露 `builtinLanguages()` 或模式 DSL 入口；需要新语言时只能依赖库版本升级。
- **新增 part 类型**：需要同时改密封类、`StreamChunkHandler` 的合并分支、`groupMessageParts()` 的归类与 `MessagePartsBlock` 的分派；四处都按 `when` 穷举。
- **已确认边界**：消息正文不执行脚本、不内嵌 iframe，WebView 只承载 Mermaid 与代码/HTML 预览；Markdown/HTML 由 Compose 渲染（具体安全策略属外部库实现），代码高亮为纯 Kotlin 实现、不依赖 WebView 或 native 库（详见第 6 节）。

## 10. 未验证事项

- 长会话持续流式输出时的实际帧率与内存表现；笔记只能确认更新入口与职责划分，未做基准测试。
- 流式期 `BetterSelectionContainer` 的选择工具栏与内容更新的并发行为，未在真机验证。
- WebView 承载 Mermaid 与 html/svg 时的隔离强度与外部资源可控性；`mark.html` 依赖 CDN，离线降级表现未验证。
- BetterText 的 LaTeX 渲染保真度与流式补全策略属外部库实现，本次未读其源码，也未在复杂公式上对比。
- BetterText 对内嵌 HTML 的处理范围与转义/过滤策略未核实（应用侧不再持有 Jsoup 白名单）。
- `zoomable` 图片查看器与 `haze` 毛玻璃、滚动联动的实际视觉与性能未见测试。
- `web-ui/` 端仍以自身 Markdown/高亮方案实现（其代码高亮已改为 highlight.js，配色与 App 同源），与原生端并非同一套渲染路径，二者画面一致性未核对。

## 11. 关键源码索引

- `ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt`（流式合并）、`StreamChunk.kt`
- `app/src/main/java/me/rerere/rikkahub/data/ai/ChatRequestFactory.kt`（展示/持久双通道与请求组装）
- `app/src/main/java/me/rerere/rikkahub/data/ai/transformers/`（`Transformer.kt`、`ThinkTagTransformer.kt`、`RegexOutputTransformer.kt`）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessage.kt`（part 分派）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessageReasoning.kt`（推理展示）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/tools/ToolUI.kt`（渲染器注册表）
- `app/src/main/java/me/rerere/rikkahub/ui/components/richtext/Markdown.kt`（`MarkdownBlock` 组件插槽）
- `app/src/main/java/me/rerere/rikkahub/ui/components/richtext/MaterialMarkdown.kt`（Material 主题与默认组件）
- `app/src/main/java/me/rerere/rikkahub/ui/components/richtext/{HighlightCodeBlock,CodeHighlightText,SelectableContent,MathBlock,Mermaid}.kt`
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatList.kt`（消息列表）
- `ui/src/main/java/me/rerere/ui/webview/`（公共 WebView、内容缓存与本地 assets 映射）
- `ui/src/main/java/me/rerere/ui/table/DataTable.kt`（表格渲染）
