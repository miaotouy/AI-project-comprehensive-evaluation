# RikkaHub 消息渲染器调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：静态阅读 Jetpack Compose 消息组件、Markdown/富文本渲染、自研 highlight 模块、流式合并链路与 WebView 承载路径，并对照 `web-ui/` 的 React 渲染作为同项目 Web 端参考
>
> 调查范围：`UIMessagePart` 各类型到可见组件的映射、Markdown/代码/数学/Mermaid 渲染、流式合并与增量展示、reasoning/工具卡/附件/翻译的展示，以及自研高亮引擎的入口与语言覆盖；不覆盖网络协议解析、持久化 schema、Composer 与导出语义
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的消息渲染是纯原生 Compose 实现，不存在 DOM。消息内容以 `UIMessagePart` 密封类表达，渲染时先由 `groupMessageParts()` 把连续的 reasoning 与工具部分聚成一个“思考块”，其余部分按原始下标生成内容块，再逐块分派到 Compose 组件（`ChatMessage.kt:316-577`）。部件类型的字段定义、分支节点与持久化约束由会话与消息管理笔记负责，见 [会话与消息管理调查笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

Markdown 由 `org.intellij.markdown` 的 GFM 方言解析成 AST，默认走 Compose 原生节点渲染；只有内容含 HTML 块或标签时才切到 Jsoup 解析 + Compose 重建的 `MarkdownNew` 分支（`Markdown.kt:254-260`）。代码高亮使用项目自研的 highlight 模块，语法定义从 highlight.js 11.11.1 移植；数学公式用 JLatexMath 以 Drawable 绘制；Mermaid 在 WebView 中执行本地脚本并桥接导出 PNG，html/svg 预览另走一条 WebView 路径。

流式输出把每个 chunk 按事件 id 合并进末条助手消息，并逐 chunk 经会话状态流触发重组；展示期另有 `visualTransform()` 通道把 `<think>` 等转成可见 reasoning，最终落库用 `onGenerationFinish()` 的结果（`GenerationLoop.kt:112-164`）。请求侧的流式事件、节流与半截流语义见 [对话请求与上下文调查笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。

## 总体渲染链路

1. 提供方流事件经合并器归并为一条 `UIMessage`；`GenerationLoop` 逐 chunk 做存储/展示两次转换后发出 `GenerationChunk.Messages`，`ChatService` 据此更新会话状态流，UI 按生命周期收集这个 `MutableStateFlow<Conversation>`（`GenerationLoop.kt:112-131`、`ChatService.kt:767-783`）。
2. `ChatList` 用 `LazyColumn` 按 `MessageNode.id` 渲染消息项（`ChatList.kt:305-370`）。
3. `ChatMessage` 组装头像、`MessagePartsBlock`、翻译、操作栏与统计行（`ChatMessage.kt:100-262`）。
4. `MessagePartsBlock` 分组后分派：文本/图片/视频/音频/文档进入 Compose 组件，reasoning 与工具进入 `ChainOfThought` 时间线（`ChatMessage.kt:316-577`）。

## 1. 消息壳层与部件分派

`ChatMessage` 按角色决定对齐方向：用户消息靠右，其余靠左。头像行只在消息非空时显示，用户侧受 `showUserAvatar` 控制，助手侧按是否使用助手头像在模型图标与助手头像间切换（`ChatMessageAvatar.kt:26-117`）。

文本 part 的分派逻辑（`ChatMessage.kt:363-429`）：

- 用户文本包在 `primaryContainer` 圆角气泡内，点击触发编辑回调。
- 助手文本在 `showAssistantBubble` 开启时包气泡，否则直接渲染。
- 文本在进入 `MarkdownBlock` 前先经过助手正则的视觉替换。

非文本 part 的渲染去向：

| part 类型 | 消息内渲染 |
|---|---|
| `Image` | `ZoomableAsyncImage`；`url` 为空或仅剩 data 前缀时显示 shimmer 占位（`ChatMessage.kt:488-508`） |
| `Video`、`Audio`、`Document` | 带图标的 `Surface` 芯片，点击用 `FileProvider` 发出 `ACTION_VIEW`；文档按 mime 选择 docx/pdf/通用图标并显示文件名（`:431-569`） |
| `Reasoning` | 思考块时间线内的推理步骤，见第 5 节 |
| `Tool`、`ServerTool` | 工具卡，由 `ToolUIRegistry` 解析渲染器，见第 5 节 |
| 已废弃的 `Search`、`ToolCall`、`ToolResult` | 直接跳过 |

部件类型的完整字段与分支语义由会话与消息管理笔记展开；生成图片的落盘与画廊由媒体创作笔记负责，见 [媒体创作调查笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。

注解（引用）在消息末尾折叠展示，展开后逐条显示 favicon 与可点击标题；正文里的 citation 徽标会回查 `search_web` 工具输出中的 `items`，按 id 匹配后打开 url（`ChatMessage.kt:580-634`、`:285-304`）。

操作栏在消息末尾显示，包含复制、重新生成、TTS、翻译与更多；助手消息才有 TTS 与翻译，分支切换器在节点有多个候选时出现，最后可选显示时间（`ChatMessageActions.kt:69-243`、`ChatMessageBranch.kt:27-94`）。统计行按设置显示 token 用量、缓存 token、TPS 与耗时（`ChatMessageNerdLine.kt:35-122`）。

## 2. 流式数据到 UI 的更新链

**从合并结果到状态流。** 合并层的有状态细节属于请求侧语义，见 [对话请求与上下文调查笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)；本节只看它产出的 `UIMessage` 如何驱动画面。

**展示层与持久层的分叉。** `OutputMessageTransformer` 提供两个钩子：`visualTransform()` 用于流式展示，`onGenerationFinish()` 用于生成结束（`data/ai/transformers/Transformer.kt:40-62`）。`GenerationLoop` 对每个 chunk 先调用 `transforms()` 得到“存储态”，再调用 `visualTransforms()` 并发出 `GenerationChunk.Messages`；生成结束后追加一次 `onGenerationFinish()` 再发出最终消息（`GenerationLoop.kt:112-131, 146-164`）。

具体到两个实现：

- `ThinkTagTransformer` 在展示期把 `<think>...</think>` 文本转成 `Reasoning` part，未闭合时 `finishedAt` 留空；生成结束时同样转换并补 `finishedAt`（`data/ai/transformers/ThinkTagTransformer.kt:14-34, 36-81`）。
- `RegexOutputTransformer` 在展示期把助手正则应用到文本与推理，`visual = false`（`data/ai/transformers/RegexOutputTransformer.kt`）。

由于 `onGenerationFinish()` 的结果会随最终 `GenerationChunk.Messages` 写入会话状态，思考标签转换在完成后是持久化生效的，而展示期中间态仅用于流式画面。

**更新频率。** `ChatService` 对每个 `GenerationChunk.Messages` 都执行一次会话状态赋值，服务侧没有额外的 debounce/conflate（`ChatService.kt:767-783`）。重渲染压力主要靠两处收敛：Markdown AST 解析移入后台线程（见第 8 节），以及仅在内容稳定时才启用 `SelectionContainer`（`ChatMessage.kt:418-428`），后者是为规避流式期可选文本频繁注册/注销与选择工具栏绘制期排序的并发修改（`ConcurrentModificationException`）。

## 3. 消息列表、窗口化与滚动

消息列表面向完整 `messageNodes` 列表使用 `LazyColumn`，键为节点 id，没有分页或额外虚拟化（`ChatList.kt:305-370`）。列表尾随加载指示项与滚动定位占位项；自动滚动在启用时监听可见项，仅在未手动滚动且处于底部时滚到底部（`ChatList.kt:278-290`），另有音量键滚动（`:218-234`）和 `ImeLazyListState` 的键盘跟随。

`previewMode` 会切换到另一套列表：带搜索框、按文本过滤消息、逐条显示单行摘要并支持点击跳转原文（`ChatList.kt:597-714`）。消息跳转控件由最近滚动状态触发（`:749-849`）。滚动锚定依赖 `LazyColumn` 的 key 稳定，分支切换通过 `MessageNode.selectIndex` 改变选中消息，节点 id 不变。

## 4. Markdown、代码与富文本管线

- **解析与分派。** `MarkdownBlock` 是统一入口（`Markdown.kt:234-274`）。它先用 GFM 方言解析（开启 https 自动链接与安全链接），并把行内 `\(...\)` 与块级 `\[...\]` 统一成 `$...$`/`$$...$$`（跳过反引号代码区）。随后判断 AST 是否含 HTML 块/标签：有则交给 `MarkdownNew`，无则对顶层子节点逐个 `MarkdownNode()`。

**节点覆盖。** `MarkdownNode` 覆盖段落、标题、有序/无序列表、任务复选框、引用、链接、粗斜体、删除线、表格、水平线、图片、行内/块级数学、行内代码、代码块、HTML 块，其余类型递归子节点（`Markdown.kt:340-645`）。段落对含图片或块级公式的内容改用 `FlowRow`；普通段落把子节点累积成 `AnnotatedString`，行内公式与 citation 徽标以 `InlineTextContent` 嵌入。

**表格。** `TableNode` 从表头与行元素提取单元格文本，用自定义 `DataTable` 渲染（`SubcomposeLayout` 两阶段测量加横向滚动，列宽约束 80/200dp），工具栏提供复制原始 Markdown 与导出 CSV（`Markdown.kt:832-969`、`table/DataTable.kt:41-80`）。

**代码块。** `CODE_FENCE` 节点不能直接取内容节点，代码通过定位 `EOL` 与最后一个内容节点的偏移切片并 `trimIndent()`；语言取 `FENCE_LANG`，缺省为 `plaintext`，是否有闭合围栏决定 `completeCodeBlock`（`Markdown.kt:592-618`）。这个闭合标志就是流式期间“围栏未闭合先不高亮”的门控依据。

**数学公式。** 行内公式优先用 `JLatexMathSplitter` 按顶层运算符拆成多段 Drawable 以便在文本流中换行，失败则回退整条公式；块级公式用 `MathBlock`，横向可滚动（`LatexText.kt:104-133`、`MathBlock.kt:18-53`）。公式渲染失败或关闭 `enableLatexRendering` 时回退为等宽文本。

**HTML 分支。** 内容含 HTML 时，`MarkdownNew` 用 intellij-markdown 的 `HtmlGenerator` 生成 HTML，再用 Jsoup 解析成 DOM，最后按标签逐节点重建 Compose 树（`MarkdownNew.kt:115-157, 186-230`）。这条分支保留了 HTML 的块级结构，但仍是 Compose 组件而非 WebView。

**Mermaid。** Mermaid 代码块把源码与主题色注入 WebView，页面加载本地 `assets/html/mermaid.min.js` 后经 `mermaid.initialize`/`mermaid.run` 渲染成 SVG（`Mermaid.kt:88-109, 166-303`）。导出时页面内函数把 SVG 序列化、画到 canvas 转 PNG，经注入的 `AndroidInterface` 回传 base64，Kotlin 侧解码写入相册目录（`Mermaid.kt:57-80, 256-296`）。

## 5. 工具、reasoning、附件与自定义节点

**思考块与时间线。** `groupMessageParts()` 把连续的 `Reasoning`、`Tool`、`ServerTool` 归入同一 `ThinkingBlock`，遇到其他类型则结束当前思考块并生成内容块，索引取原 parts 下标（`ChatMessageCot.kt:35-68`）。思考块用通用 `ChainOfThought` 渲染：步骤多于阈值时折叠只显示末尾若干步，顶部按钮展开全部，背景绘制时间线竖线，步骤分受控/非受控两种（`ui/ChainOfThought.kt:68-173`）。仅含推理的思考块会使用自适应宽度（`ChatMessage.kt:321-325`）。

**推理展示。** 推理步骤按 `createdAt` 记忆状态，含折叠/预览/展开三态；流式期间若开启显示思考内容，自动进入“预览”态并滚到底部，用渐变遮罩把高度限制在约 100dp（`ChatMessageReasoning.kt:59-80, 96-118`）。生成结束后按 `autoCloseThinking` 决定收起或保持展开并显示耗时（`:136-168`），标题优先取推理文本中最后一整行加粗文本（`utils/MarkdownUtils.kt:35-54`）。

**工具卡。** `ChatMessageToolStep` 通过 `ToolUIRegistry` 解析渲染器，未注册工具回退默认实现，渲染上下文预算好入参 JSON 与输出 JSON（`ChatMessageTools.kt:94-133`、`tools/ToolUI.kt:40-113`）。标题、图标、内联摘要与详情预览均由渲染器提供；默认详情用 `HighlightCodeBlock` 以 JSON 展示入参与输出，图片输出用 `ZoomableAsyncImage`（`tools/ToolUI.kt:124-190`）。待审批时显示拒绝/批准按钮，拒绝走带原因的对话框；详情是 `ModalBottomSheet`，输出图片在摘要区横向排列（`ChatMessageTools.kt:161-252`）。

`ask_user` 不走注册框架，单独渲染为可交互问答：按问题渲染选项 chip 或文本输入，支持单选/多选，提交后汇总成 JSON 答案（`ChatMessageTools.kt:257-436`）。服务端工具渲染为简单步骤，不再有审批控件（`:65-91`）。注册表覆盖记忆、搜索、抓取、时间、剪贴板、TTS、屏幕时间、日历、技能、近期会话、文件编辑/读/写与 Shell 等工具（`tools/ToolUI.kt:92-109`），另有工作区与内置工具的实现文件。

**附件与图片全屏。** 附件在消息内以芯片形式存在，点击交给系统应用处理。图片用 `ZoomableAsyncImage`：Coil 加载、跨淡关闭、支持占位图，点击打开全屏查看器；全屏用可缩放分页器并在底部提供保存动作（`richtext/ZoomableAsyncImage.kt:26-71`、`ui/ImagePreviewDialog.kt:33-89`）。

**翻译展示。** 翻译文本存在 `message.translation`，渲染为可折叠卡片；内容等于本地化“翻译中”文案时显示转圈与呼吸文字，否则用 Markdown 渲染（`ChatMessageTranslation.kt:173-292`）。翻译的写入与流式更新由请求侧驱动（`ChatService.kt:1166-1226`）。工作区写/编辑文件工具另会汇总“已编辑文件”列表（`ChatMessageEditedFiles.kt:53-70`）。

## 6. HTML 与内容承载边界

消息正文不执行脚本、不内嵌 iframe：

- 消息级 HTML（`HTML_BLOCK`）走 `SimpleHtmlBlock`：Jsoup 解析后仅识别段落、标题、列表、`details`、图片、`progress`、表格、`div` 等块级元素与行内加粗/斜体/下划线/链接/代码等样式，不处理 iframe 与脚本（`richtext/SimpleHtmlBlock.kt:44-71, 90-162, 335-422`）。
- 含 HTML 的整条消息由 `MarkdownNew` 处理，同样是 Jsoup + Compose 重建，未引入浏览器内核（`MarkdownNew.kt:146-157`）。
- WebView 只用于 Mermaid 与 html/svg 代码预览；html/svg 预览把代码作为 HTML 或包一层容器载入（`HighlightCodeBlock.kt:474-504`）。
- 消息操作菜单的“用 WebView 渲染”把文本 part 转成 HTML 模板并跳转到独立 WebView 路由（`ChatMessage.kt:233-247`）；模板加载 `assets/html/mark.html`，其中 marked.js、KaTeX、highlight.js、Mermaid 均从 CDN 导入，故该路径渲染依赖网络（`MarkdownWeb.kt`、`app/src/main/assets/html/mark.html:177-237`）。

预览 WebView 由统一组件提供，按用途注入不同的命名 JavaScript 接口：代码块预览注入空接口集，只有页面自身脚本可运行；Mermaid 预览注入 `AndroidInterface.exportImage`，供页面把渲染出的 SVG 转 PNG 后回传宿主（`ui/components/richtext/Mermaid.kt:55-86`）。虚拟域名 `rikkahub.local` 把 `/assets/` 前缀映射到应用 assets，Mermaid 脚本随应用打包、由拦截器提供（`ui/components/webview/WebViewLocalAssets.kt:10-39`）。Mermaid 脚本随应用打包并提供，因此该路径不依赖外网；web-ui 工作台对 html/svg/markdown/mermaid 四类语言提供预览，其中 mermaid 在 iframe 内从 esm.sh 动态导入，属该端自有路径（`web-ui/app/components/workbench/workbench-host.tsx:36-128`）。

WebView 的沙箱姿态（脚本默认开启、无 CSP 与来源白名单）与执行位置，以及 QuickJS 工具、PRoot shell 与 web-ui 工作台 iframe 属生成式输出与运行时笔记的边界。

## 7. 内容交互反馈与可访问性

- **复制**：操作栏复制按钮把 `UIMessage.toText()`（仅拼接文本 part）写入剪贴板（`ChatMessageActions.kt:98-107`、`utils/ChatUtil.kt:31-33`）。“选择并复制”在底部弹层内用 `SelectionContainer` 展示所有非空文本 part，并提供“复制全部”。
- **代码块操作**：复制原始代码、按语言映射扩展名后导出文件、html/svg 内联预览切换与新窗口预览、超长折叠（阈值 10 行）、行号与自动换行组合（`HighlightCodeBlock.kt:85-250, 353-472`）。
- **表格操作**：复制 Markdown 原文与导出 CSV（`Markdown.kt:920-958`）。
- **工具审批反馈**：`onToolApproval`/`onToolAnswer` 回调由消息链路上抛，工具卡依据返回的审批状态重渲染；拒绝原因内联显示为错误色文本（`ChatMessageTools.kt:212-220`）。
- **流式结束选择**：生成结束后才包裹 `SelectionContainer`，避免流式期选择工具栏并发问题（`ChatMessage.kt:418-428`、`ChatMessageReasoning.kt:181-189`）。
- **触感反馈**：开启时，流式期间对 parts 变化做 50ms debounce 后触发键盘触感（`ChatMessage.kt:305-313`）。

## 8. 性能、缓存与测试

- **解析卸载到后台**：`MarkdownBlock` 与 `MarkdownNew` 都用 `snapshotFlow + distinctUntilChanged + mapLatest + flowOn(Dispatchers.Default)` 把解析移出主线程（`Markdown.kt:242-252`、`MarkdownNew.kt:136-144`）。
- **代码高亮长度上限**：`CodeHighlightText` 在代码长度超过 4096 字符时跳过高亮，直接输出纯文本（`highlight/src/main/java/me/rerere/highlight/Highlighter.kt:20, 61-62`）。
- **高亮引擎**：`HighlightEngine` 把每种语言编译成一棵模式树，高亮时用模式栈匹配；未注册语言返回 `null`，上层回退纯文本；语法错误在非调试模式下降级为纯文本（`highlight/.../core/HighlightEngine.kt:21-46, 84-101`）。注释说明其语法定义移植自 highlight.js 11.11.1。
- **测试**：highlight 模块有 `CodeHighlighterTest`、`HighlightEngineTest`、`RegexesTest` 与 `LanguageFixtureTest`，后者对每种内置语言与 highlight.js 产出的 token 流做断言，fixture 存放在 `highlight/src/test/resources/hljs/`。
- **缓存**：WebView 内容通过 `WebViewContentCache` 以内容 id 落盘复用（Mermaid、代码预览与 WebView 预览均使用）。消息列表本身无渲染缓存，依赖 Compose 重组与稳定 key。

## 9. 扩展方式与已确认边界

- **新增工具渲染器**：实现 `ToolUIRenderer` 并加入 `ToolUIRegistry` 的渲染器列表即可，未注册工具自动回退默认实现（`tools/ToolUI.kt:56-113`）。
- **新增高亮语言**：在 `highlight` 的语言目录下用模式 DSL 定义语言并注册进 `builtinLanguages()`；别名映射在引擎构造时建立，重复别名会抛错（`languages/Languages.kt:40-71`、`core/HighlightEngine.kt:23-31`）。当前内置 30 种语言，别名覆盖 shell、js/ts、html/xml/svg、c/cpp、toml/ini 等常见写法；未注册的 `plaintext`/`text` 会回退纯文本。
- **新增 part 类型**：需要同时改密封类、`StreamChunkHandler` 的合并分支、`groupMessageParts()` 的归类与 `MessagePartsBlock` 的分派；四处都按 `when` 穷举。
- **已确认边界**：消息正文不执行脚本、不内嵌 iframe，WebView 只承载 Mermaid 与代码/HTML 预览，HTML 解析限 Jsoup 白名单，代码高亮为纯 Kotlin 实现、不依赖 WebView 或 native 库（详见第 6 节）。

## 10. 未验证事项

- 长会话持续流式输出时的实际帧率与内存表现；笔记只能确认更新入口与职责划分，未做基准测试。
- 流式期禁用 `SelectionContainer` 所规避的并发异常是否在所有机型/Compose 版本上彻底消除。
- WebView 承载 Mermaid 与 html/svg 时的隔离强度与外部资源可控性；`mark.html` 依赖 CDN，离线降级表现未验证。
- JLatexMath 对复杂公式的渲染保真度，以及 `splitLatex` 拆分失败后的回退在真实公式上的覆盖情况。
- `zoomable` 图片查看器与 `haze` 毛玻璃、滚动联动的实际视觉与性能未见测试。
- `web-ui/` 端以 Streamdown + shiki + KaTeX 实现，流式动画与原生端并非同一套渲染路径，二者画面一致性未核对。

## 11. 关键源码索引

- `ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:57-303`（流式合并）
- `app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt:112-164`（展示/持久双通道）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessage.kt:266-635`（part 分派）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessageReasoning.kt:194-255`（推理展示）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/tools/ToolUI.kt:56-190`（渲染器注册表）
- `app/src/main/java/me/rerere/rikkahub/ui/components/richtext/Markdown.kt:234-645`（原生 Markdown 渲染）
- `app/src/main/java/me/rerere/rikkahub/ui/components/richtext/Mermaid.kt:44-303`（Mermaid + SVG→PNG 导出）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatList.kt:305-412`（消息列表）
- `highlight/src/main/java/me/rerere/highlight/Highlighter.kt:30-86`（高亮入口）
- `highlight/src/main/java/me/rerere/highlight/languages/Languages.kt:40-71`（语言覆盖）
