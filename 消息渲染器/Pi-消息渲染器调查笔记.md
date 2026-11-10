# Pi 消息渲染器调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/tui/`、`packages/coding-agent/src/modes/interactive/components/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码梳理组件树、Markdown 管线与事件流；未在真实终端运行
>
> 调查范围：输入模型、流式链路、列表与滚动、消息壳层、Markdown/代码/富文本管线、工具与附件节点、交互反馈、性能与扩展机制；HTML 导出属独立静态生成，只说明调用关系
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的“消息渲染器”是终端组件树 + 事件驱动全量重建 + 帧节流渲染：

1. **输入模型是完整消息对象**：会话事件向渲染器投递整条消息或带增量的消息事件，类型覆盖消息生命周期、工具执行与 bash 输出三组，助手侧另有按文本、思考、工具调用细分的增量事件随消息更新一并透传（`core/agent-session.ts:210`、`interactive-mode.ts` 的事件分发分支）。
2. **渲染管线从 Markdown 文本到终端行**：TUI 的 Markdown 组件先用 marked 解析（含自定义删除线与 LaTeX 分词器），再由主题函数着色、按 ANSI 感知换行，最后补边距与背景填充，产出可直接写屏的终端行。扩展点在解析之前，MarkdownTransformer 可改写原始文本，例如把 mermaid 转成 Unicode 图（`packages/tui/src/components/markdown.ts`、`components/mermaid.ts:60-88`）。
3. **代码高亮走 highlight.js 加主题映射**：代码块先由 highlight.js 高亮成带作用域的 span，再由语法高亮模块把 hljs 作用域换算成主题函数，输出 ANSI 着色结果（`utils/syntax-highlight.ts`）。
4. **消息壳层按角色与类型分派**：入站消息由统一入口按用户、助手、bash 执行、自定义、压缩摘要、分支摘要逐一建壳；助手壳层再按内容块顺序渲染文本与思考，工具调用块由事件层单独建组件，最后依 stopReason 补上截断、中止或错误提示（`interactive-mode.ts:3963`、`components/assistant-message.ts:31`）。
5. **列表结构是普通容器，没有虚拟化**：聊天区就是一个容器，流式时在末尾追加组件并重建内容，滚动交给 TUI 主屏幕整帧重绘；TUI 包另有带滚动条与动画的 ScrollView，聊天列表没有使用虚拟化（`interactive-mode.ts:394`、`packages/tui`）。
6. **性能策略是缓存叠加帧合并**：Markdown 组件以文本与宽度为键缓存渲染结果，渲染请求由 TUI 按最小间隔合并降频；worker、增量 AST 与虚拟列表均未使用，Markdown 管线由 1334 行的测试覆盖（`markdown.ts:271-281`、`packages/tui/src/tui.ts:765-817`、`packages/tui/test/markdown.test.ts`）。
7. **安全边界**：终端渲染只输出 ANSI 与 OSC 序列，HTML 由导出命令离线静态生成（marked、highlight.js 与模板），工具结果另走独立的渲染模块；本次未发现运行时的 HTML 渲染路径（`core/export-html/`、`tool-renderer.ts`）。
8. **扩展机制**：扩展可接入四个位置：
   - 解析前的 Markdown 文本改写（MarkdownTransformer）
   - 工具节点的调用、结果与壳层渲染钩子
   - 按类型注册的自定义消息与条目渲染器
   - 主题热切换（`theme-controller.ts`）

## 总体渲染链路

```text
AgentSession 事件 (message_start/update/end, tool_execution_*, bash_execution_update)
  -> InteractiveMode.handleEvent (interactive-mode.ts:3068-3374)
       分派: addMessageToChat / streamingComponent.updateContent / ToolExecutionComponent
  -> 组件树: chatContainer (Container) 内追加/替换子组件
  -> TUI.requestRender(force?) -> nextTick -> 帧节流 (tui.ts:765-817)
  -> renderLayoutFrame(root, w, h) -> 组件 render(width) -> ANSI 行
  -> terminal 写出 + OSC 133 区域标记 (assistant/user 消息首尾)
```

## 1. 消息与内容块数据模型

- **消息**：消息对象按角色分为用户、助手与工具结果三类，另有自定义消息、bash 执行、压缩摘要、分支摘要等类型；助手消息的内容块数组由文本、思考、工具调用三种块组成（`core/messages.ts:29-67`、`packages/ai/src/types.ts:338-368`）。
- **事件携带**：消息更新事件带出助手增量事件，该增量按文本、思考、工具调用细分；界面重建时取同一事件里携带的 partial 完整消息，增量字段用于标识当前内容块（`types.ts:523-539`、`interactive-mode.ts` 的事件到 UI 分支）。
- **角色分派点**：组件创建只有两个分派入口，入站消息走消息追加函数的类型分支，消息开始事件走另一分支；工具调用块在消息更新事件到达时同步建出工具组件（`interactive-mode.ts:3456-3561,3124-3146,3153-3177`）。

## 2. 流式数据到 UI 的更新链

- **每个增量都整体重建**：消息更新事件触发流式组件的更新方法，内容容器被清空后按最新消息重画；思考块在流式中按连续块合并成一个区，隐藏时退化为静态标签（`assistant-message.ts:89-196,115-169`）。
- **工具参数流式**：工具调用增量到达时逐步更新参数，工具执行更新事件携带部分结果刷新工具组件；结果中的非 PNG 图片先异步转码成 kitty 可显示的格式再重绘（`interactive-mode.ts:3171-3175,3251-3258`、`tool-execution.ts:178-199`）。
- **收口**：消息结束事件用最终消息再更新一次，按 stopReason 补写中止、错误或长度截断的状态文本，中止与错误时把原因写进所有挂起的工具组件；代理结束事件负责清理流式组件与挂起工具表（`interactive-mode.ts:3183-3221,3270-3283`）。
- **bash 流式**：bash 执行更新事件由 bash 执行组件追加输出，逐段写入已有内容（`interactive-mode.ts:3223-3225` 与 `components/bash-execution.ts`）。
- **节流**：界面侧只发出渲染请求，帧合并与降频由 TUI 主体按最小渲染间隔统一处理，强制渲染可以立即出帧（`tui.ts`）。

## 3. 消息列表、窗口化与滚动

- **列表结构**：聊天区就是一个普通容器，没有分页、虚拟化或窗口化，流式期间组件持续追加；`/resume` 与 `/tree` 的会话列表由选择器组件呈现，只负责选择条目（`interactive-mode.ts:394`）。
- **滚动与高度**：整屏组件树交给布局函数按终端宽高排布，滚动行为由 TUI 主屏幕统一管理，输入区与聊天区共存；TUI 包另有通用 ScrollView，支持滚动条、鼠标滚轮与 API 滚动，没有拖拽。半页滚动与“到达末端抑制跟随”的语义只在 fullscreen 搜索跳转里使用，聊天列表本次未找到虚拟化接入（`tui-alt-screen.ts:831`、`tui-main-screen.ts`、`components/scroll-view.ts:116-190`）。
- **分支切换**：`/tree` 提交导航后，聊天容器先清空再调用初始消息渲染重建整屏；另有从消息列表整体重建的路径，用于压缩结束、thinking 开关切换、设置变更与会话重载（`interactive-mode.ts:5053-5054,3696,3747`）。

## 4. 消息壳层与角色分派

- **用户消息**：用户消息组件由一个带背景色的盒子包住 Markdown 渲染结果，背景色取主题里的 userMessageBg；渲染时打开两个开关，保留有序列表序号与反斜杠转义（`user-message.ts:38-58`）。
- **助手消息**：助手组件按内容块顺序渲染，文本块走 Markdown 并使用助手主题；连续的思考块合并成一个 Markdown 区，以斜体和 thinkingText 色呈现，隐藏时收成单行标签；最后按 stopReason 追加长度截断、中止或错误状态文本，OSC 133 区域标记只在没有工具调用时包裹整段（`assistant-message.ts:78-87,104-169,172-195`）。
- **工具执行**：工具组件默认套一层“调用标题加输出框”的壳，工具也可以选择自绘；内容优先由工具定义自带的渲染钩子产出，其次用内置工具定义兜底，最后落到纯文本输出（`tool-execution.ts:81-145`）。
- **系统与扩展消息**：另有一组专用壳层：
  - 压缩摘要与分支摘要：可折叠
  - 自定义消息与自定义条目：交给扩展注册的渲染器
  - skill 调用：渲染为可折叠的 `<skill>` 块（`interactive-mode.ts:3509-3513`）
- **状态与操作栏**：底部栏显示当前模型、token 用量、成本与运行状态；重试、压缩和分支摘要各有专用状态指示器（`components/footer.ts`、`status-indicator.ts`）。

## 5. Markdown、代码与富文本管线

- **解析**：Markdown 由 marked 实例解析，挂在其上的是两个自定义分词器：删除线要求 `~~` 两端紧贴非空格字符，LaTeX 分词器支持行内与块级两类数学分隔符（美元符号与反斜杠括号两种写法）；未闭合且形似公式的片段按 pending 状态渲染，流式时还会裁掉未闭合的代码围栏（`markdown.ts:9-24,48-144,146-169`）。
- **渲染顺序**：解析出的 token 按类型逐个处理标题、代码、行内代码、引用、链接、列表与分隔线，再按 ANSI 感知换行（图片行跳过），最后补边距并填充背景到整行宽（`markdown.ts:454,316-326,328-350`）。
- **代码高亮**：主题通过 MarkdownTheme 的 highlightCode 钩子接管代码块；高亮模块先用 highlight.js 生成带作用域的 HTML，再把作用域映射成主题函数输出 ANSI，嵌套结构由作用域栈处理（`markdown.ts:215,523-525`、`syntax-highlight.ts:80-132`）。
- **LaTeX**：LaTeX 渲染默认开启，把公式转成 Unicode 文本。矩阵与 array 环境按多行布局节点参与行高对齐，分数、运算符和矩阵统一由布局器拼行；关系运算符与命名算子会自动补空格，等号与不等号有专门的间距处理，CRLF 换行与跨行控制空格也在处理范围内（`latex.ts:291-378,655-668,869-873,923-930,1314-1341`）。
- **图片**：终端图片能力由能力探测函数返回，图片协议只有 kitty、iterm2 和空值三种取值，能力不足时退化为文本占位；图片行由识别函数标记，在换行阶段跳过（`terminal-image.ts:138`、`image.ts:114-119`）。
- **链接与超链接**：终端支持超链接时，链接由 hyperlink 函数输出为 OSC 8 序列（`terminal-image.ts`）。

## 6. 工具、reasoning、附件与自定义节点

- **工具调用**：内容里的工具调用块建为工具执行组件，细节见第 4 节；结果图片在 kitty 终端会把非 PNG 格式转码后显示（`tool-execution.ts:178-199`）。
- **thinking**：思考内容渲染成独立的 Markdown 区并整体设为斜体，也可以收成一行标签，行为由设置项切换（`assistant-message.ts:115-169`）。
- **附件**：用户消息中的图片内容交给终端图片能力渲染，粘贴或拖入都走这条路径，是否显示由 showImages 设置控制；工具结果里的图片处理方式相同（`interactive-mode.ts` 的设置读取处）。
- **自定义节点**：扩展按类型注册消息渲染器与条目渲染器，渲染器返回组件工厂；自定义条目在建节点时读取注册结果，自定义消息则在消息分派处读取。bash 执行、压缩摘要和分支摘要各自是独立节点类型（`interactive-mode.ts:3434-3435,3474`）。

## 7. HTML、Artifact 与安全隔离

- **运行时无 HTML**：终端输出只包含 ANSI 转义与 OSC 序列，模型输出直接进入终端管线，未经 HTML 渲染。OSC 133 区域标记的常量定义在助手消息与用户消息组件中，用于终端复制时识别消息边界（`components/assistant-message.ts:7-9`、`components/user-message.ts:6-8`）。
- **HTML 导出**：`/export` 生成自包含的单页文件，解析由 marked 在服务端完成，代码高亮使用打包好的 highlight.min.js，ANSI 转 HTML 与工具结果渲染各有一个模块；system prompt 可折叠展示（`core/export-html/`、`template.js:1405-1420`）。
- **终端输入侧**：编辑器渲染用户输入（`packages/tui/src/components/editor.ts`），无 HTML 注入面。

## 8. 交互反馈与可访问性

- **复制、折叠与重试**：`/copy` 取最后一条助手消息；工具与摘要类组件支持展开收起，自动重试与压缩期间有状态指示器，可用 Esc 中止（`interactive-mode.ts:3168,3342-3368`）。
- **键盘**：按键由全局按键系统统一注册，可用 `/hotkeys` 查看；此外还有 fullscreen 会话搜索（Ctrl+Shift+F）、半页与单行滚动、多击选词选行等绑定，编辑器支持输入法输入与硬件光标选项（`packages/tui/src/keybindings.ts:44-52,165-207`、`settings-manager.ts:128`，工作流见 Chat UI 笔记）。
- **可访问性**：终端渲染没有图形无障碍接口可用，消息边界识别依赖 OSC 133 标记，供终端模拟器与复制工具定位；无障碍审计目前没有专门测试。

## 9. 性能、缓存与测试

- **缓存**：Markdown 组件按文本与宽度缓存已排版的行，流式时每个增量都会改变文本，缓存随之失效并触发整段重新解析（`markdown.ts:271-295`）。
- **帧节流**：渲染请求按最小渲染间隔合并降频，关键路径（如编辑器聚焦）用强制渲染跳过等待（`tui.ts:765-817`）。
- **无虚拟化与 worker**：长会话的聊天区按消息数线性重建；本次未找到增量 AST、Web Worker 或延迟渲染的实现。
- **测试**：1334 行的 markdown 测试覆盖解析、换行与主题，TUI 包另有 LaTeX 与终端相关测试；聊天列表性能没有基准测试（`packages/tui/test/markdown.test.ts`）。

## 10. 扩展方式与已确认边界

- **MarkdownTransformer**：扩展可以在解析前改写 Markdown 文本，作用范围由消息类型与流式状态决定，默认只覆盖助手、用户与助手思考三类；注册时传入 messageTypes 可扩到自定义消息、skill 块、分支与压缩摘要以及 What's New、changelog 等更新提示表面。mermaid 就是内置的 transformer 实例，展开的分支与压缩摘要里同样会画图（`core/extensions/loader.ts:365`、`core/extensions/types.ts:1583`）。
- **工具渲染**：工具定义通过调用渲染、结果渲染与壳层渲染三个钩子决定节点外观；执行模式影响工具的编排流程（`tool-execution.ts`）。
- **主题**：主题控制器支持 dark 与 light 两套 JSON 主题热切换，MarkdownTheme 接口是渲染器与主题之间的契约（`theme-controller.ts`、`theme/dark.json`）。
- **已确认边界**：渲染器的输入是完整消息加事件，块级局部更新不在支持范围；聊天列表没有虚拟化，超长会话的渲染成本随消息数线性增长；终端图片能力靠能力探测获得，能力不足时图片退化为不可显示。

## 11. 未验证事项

- 未在真实终端运行，OSC 133、超链接、图片能力与滚动行为未实测。
- 流式期间的帧率与长会话性能未测量。
- HTML 导出的浏览器端行为（`template.js`）未运行验证。

## 12. 终端能力覆盖

渲染器的超链接、图片与真彩色分支既可以由环境自动探测决定，也能被 terminal 设置或三个环境变量显式覆盖（PI_HYPERLINKS、PI_IMAGE_PROTOCOL、PI_TRUECOLOR）。覆盖结果由能力探测函数集中缓存，Markdown 链接、图片降级文本与工具结果共用这一份结果（`packages/tui/src/terminal-image.ts:143-184`、`components/markdown.ts:690-699`）。

## 13. Fullscreen 渲染交互

fullscreen transcript 仍使用完整渲染行，但搜索已缓存可搜索语料与命中结果，并对 ASCII 连续文本采用区段映射，避免为每个字符分配来源对象；可见命中区间用二分定位。界面增加可点击的前后命中按钮、离开末尾时的 jump-to-end 指示器，以及可拖动滚动条（`packages/tui/src/alt-screen-search.ts:30-193`、`packages/tui/src/tui-alt-screen.ts:496-625,1016-1116,1621-1641`）。

TUI 还建立了通用鼠标事件分派与捕获，组件可处理 press、drag、release、click 和 wheel；编辑器主动放行拖选，使选区能够跨过输入区。该能力扩展了交互层，不改变消息仍按完整组件重建、聊天列表不虚拟化的结论（`packages/tui/src/tui.ts:21-59`、`packages/tui/src/tui-alt-screen.ts:771-943`、`packages/tui/src/components/editor.ts:641-642`）。

## 14. 关键源码索引

- `packages/tui/src/components/markdown.ts:277-369`：Markdown 渲染主流程；`146-169`：流式围栏裁剪；`454` 起：token 渲染
- `packages/coding-agent/src/utils/syntax-highlight.ts:80-142`：hljs scope→ANSI
- `packages/coding-agent/src/modes/interactive/components/assistant-message.ts:89-196`：助手消息壳
- `packages/coding-agent/src/modes/interactive/components/tool-execution.ts:81-199`：工具节点
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts:3068-3374`：事件→组件
- `packages/tui/src/tui.ts:765-817`：帧节流
- `packages/tui/src/latex.ts`：LaTeX→Unicode 与多行布局
- `packages/coding-agent/src/modes/interactive/components/mermaid.ts:60-88`：mermaid transformer
