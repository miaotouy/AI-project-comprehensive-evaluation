# Pi 应用界面基础设施调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/tui/`、`packages/coding-agent/src/modes/interactive/`）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e86823096c5bad39e1ca282ec24bc5eb9bec745b`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的 TUI 框架完全自研，提供差分渲染、regular 与 fullscreen 两种屏幕模式、overlay 栈和单焦点模型。常规选择器通过编辑器插槽替换显示，真正悬浮的 overlay 主要用于 fullscreen 搜索和扩展 API。

反馈分为聊天区状态文本、fullscreen flash 和 OSC 9;4 进度三类。主题使用 JSON token 和全局单例，支持终端色彩降级、变量引用、明暗自动模式与主题文件热重载；资源可以来自文件系统、项目、包和扩展，并在设置页实时预览。

TUI 没有主题市场、壁纸、字体、密度或圆角设置。键盘由统一注册表管理，支持用户覆盖和冲突检测；剪贴板在原生插件、平台命令和 OSC 52 之间回退，图片则按 Kitty 或 iTerm2 能力渲染，无协议时显示文本替代。

## 系统边界与总体装配

**界面栈。** `packages/tui` 是自研终端 UI 库（`packages/tui/package.json` 依赖仅两个小包），组件模型为：组件（渲染、输入处理与失效标记）+ 容器组合 + 可聚焦节点（focused 状态 + CURSOR_MARKER APC 序列定位硬件光标供 IME 使用，`packages/tui/src/tui.ts:23-79`）。

不采用 Ink/blessed/react 等框架。

**两种渲染器。** TuiMainScreen（regular：渲染进主屏与滚动回滚，行级差分比较；`tui-main-screen.ts:180` 起 doRender）与 TuiAltScreen（fullscreen 备屏：应用自有视口与布局引擎；`tui-alt-screen.ts:159`，ViewportTUI 标记符号，`tui.ts:320`）。

**装配。** createInteractiveTui（`interactive-mode.ts:343-355`）按 tuiMode 选择渲染器，fullscreen 时注入搜索匹配样式、链接打开与右键粘贴回调；

InteractiveMode.init（:842 起）构建组件树（文档、待处理消息、状态、编辑器、页脚五个容器，:891-899 挂载），并构造 fullscreen 布局根（transcript 滚动视图 + dock 垂直栈，:872-890）。

**渲染器热切换。** switchTuiMode（:791-840）在 regular/fullscreen 之间替换渲染器但保留同一组件树、焦点与渲染状态（TuiMainScreenRenderState capture/restore，:802-822）；组件持有的 TUI 引用经 createInteractiveTuiReference（:358-386）的 Proxy 跟随当前渲染器。

**多入口共享。** 启动选择器/首次设置/登录提示使用独立临时 TuiMainScreen（`cli/startup-ui.ts:77-85` createStartupTui），与主交互共用同一主题系统与 TuiMainScreen 类；TUI 单进程无多窗口概念。

**渲染调度。** requestRender 16ms 最小帧间隔节流 + requestImmediateRender（用户输入路径避免 Windows 16ms 计时 tick，`tui.ts:765-817`）；OSC 11/颜色方案/cell size 应答在输入链最前消费（:819-951）。

## 1. 界面栈、公共组件与状态所有权

- **公共组件**（`packages/tui/src/components/`）：基础布局包括文本、截断文本、盒、间隔与 VStack/HStack 栈（basis/grow/shrink/minSize/maxSize/visible 回调，`stack.ts:4-11,82-87`）；ScrollView 提供尾随、overscroll 链/包含与三态滚动条（`scroll-view.ts:21`）。
- 输入与内容组件包括：输入框、多行编辑器（自动补全、历史/kill-ring/undo，`editor.ts:270`）、选择列表（键盘导航，`select-list.ts:40`）、设置列表（含子菜单与搜索，`settings-list.ts:34,198-220`）、Markdown（主题接口 MarkdownTheme，`markdown.ts:236`）、加载器（见 §3）与图片（见 §6）。

**fullscreen 布局引擎。** `layout.ts` renderLayoutFrame（:353-382）按终端尺寸逐帧布局，render 缓存按组件+宽度键控（:62-75），scroll 节点计算 scrollTop 与 clip（:130-162），paintBox 逐行合成并处理 Kitty 图片裁剪与滚动条绘制（:304-351），全宽行有直接引用快速路径（:319-325）；滚动条几何 getScrollbarGeometry（:266-291）。

**状态所有权。** 编辑器文本/历史/undo 在 editor 组件内（`editor.ts:316-339`）；选择器选中项/搜索文本在各自组件实例内（如 `session-selector.ts:288-310`）；主题是模块级全局单例（§4）；键盘注册表是模块级单例（§7）；busy/流式事实源在 agent session（`agent-session.ts:878-885`，UI 投影见 Chat UI 笔记 §5/§9）。组件树外的共享状态只有 theme 与 keybindings 两个全局点。

## 2. 弹窗、浮层与菜单（TUI 形态）

### Overlay 栈（TUI 层公共机制）

- showOverlay(component, options) 返回 OverlayHandle（hide/setHidden/focus/unfocus/isFocused），记录 preFocus 并在关闭时还原（`tui.ts:549-642`）；OverlayOptions 支持 anchor（九方位）、width/maxHeight/row/col 绝对或百分比、margin、visible 回调（每渲染帧以终端尺寸评估，:666-672）与 nonCapturing（不抢焦点）。

**合成。** compositeOverlays（`tui.ts:1092-1151`）先渲染全部可见 overlay、按 focusOrder 排序后逐行合成到底层行；工作区高度取 max(result.length, termHeight, minLinesNeeded)，注释明确排除历史高水位 maxLinesRendered 以避免终端加宽时自增强膨胀（:1124-1127）。

**焦点。** overlay 捕获焦点后 overlayFocusRestore 进入 eligible/blocked 两态恢复（:422-521），嵌套 overlay 关闭时焦点回退到下一个可见 capturing overlay 或 preFocus 链（:567-641）；输入分发前校验聚焦 overlay 仍可见，不可见则重定向（:855-881）。

TUI 层有 overlay 专项测试（`packages/tui/test/overlay-*.test.ts`、`tui-overlay-style-leak.test.ts`）。

**Esc。** Esc 语义由各组件消费 tui.select.cancel（默认 escape/ctrl+c，`packages/tui/src/keybindings.ts:155-158`）实现；无框架级全局 Esc 拦截。

### 仓库内的 overlay 消费点

1. **fullscreen transcript 搜索框**：openSearch 以 anchor: "top-right"、width: "40%"、minWidth: 24、margin: 1 打开 AltScreenSearchComponent overlay（`tui-alt-screen.ts:416-437`），Enter/Ctrl+G 下一个、Shift+Enter 上一个、Esc 关闭（:567-584）——这是内置代码中唯一的 overlay 实例。
2. **扩展自定义组件**：showExtensionCustom 的 options.overlay 模式（`interactive-mode.ts:2662-2730`，overlayOptions 可为函数动态解析 :2708-2716），关闭时 `ui.hideOverlay()`；该 API 由扩展系统暴露（`core/extensions/types.ts:199-210`）。

本次未在仓库内找到任何具体扩展以 overlay: true 调用的实例（Grep 范围：`packages/coding-agent/src` 全部 `.ts`）。

### 对话框/命令面板的常规形态：编辑器插槽替换

- showSelector（`interactive-mode.ts:4354-4377`）：把编辑器容器里的编辑器换成选择器组件并转移焦点，done 回调恢复编辑器；单实例互斥（token 校验）。全部业务选择器（设置、续聊、文件树、fork、模型、登录等）走此路径，业务细节见 Chat UI 笔记 §1-§3。

**确认形态。** 删除会话等"确认"以选择器内嵌确认行实现（如 `session-selector.ts:576-601` Ctrl+D 进入删除确认），无独立 Modal 组件。

**菜单。** 无右键上下文菜单系统；slash 命令补全列表（editor 内嵌 SelectList，`editor.ts` autocomplete）承担"命令面板"功能；TUI 全屏模式另有鼠标选区/右键粘贴（Windows），见 Chat UI 笔记 §4。

## 3. 通知、加载态与错误反馈（TUI 形态）

### 聊天区文本反馈（regular 与 fullscreen 共用）

- showError（`interactive-mode.ts:4098-4102`）：追加 Error: …（theme.fg("error")）进 chatContainer；showWarning（:4104-4108）用 warning 色；showStatus（:3414-3432）用 dim 色，且连续状态消息复用最后一个文本节点就地更新（lastStatusText/lastStatusSpacer 判定）——明确的防刷屏设计。三者都随聊天区滚动，无自动消失。
- 扩展 notify 事件映射到这三条通道（showExtensionNotify，:2651-2659）。

### fullscreen flash（Toast 等价物）

- AltScreenFlashContainer（`packages/tui/src/components/alt-screen-flash.ts:13-51`）：默认 1000ms 自动消失、反显样式、从顶部行右对齐合成（`tui-alt-screen.ts:1209-1221`）。仅 TuiAltScreen 提供 flash()；

  regular 模式无此通道——`interactive-mode.ts:5956-5969` 复制命令在 ui instanceof TuiAltScreen 时 flash("Copied!")，否则退化为 showStatus。TUI 接口 TUI 本身不含 flash 方法。

### 加载态

- Loader（spinner 帧动画 80ms + 消息文本，`components/loader.ts:11-12,47-91`）；CancellableLoader 增加 Esc→AbortSignal（`components/cancellable-loader.ts:13-40`，Esc 匹配 tui.select.cancel）；

  BorderedLoader（`bordered-loader.ts:7-68`）用 DynamicBorder 框起 loader 并显示 "cancel" 键提示，是扩展 UI 的带框加载面板。消费实例：`/share` 创建 gist 时 new BorderedLoader(this.ui, theme, "Creating gist...")（:5885）。

**OSC 9;4 终端进度条。** ProcessTerminal.setProgress（`packages/tui/src/terminal.ts:537-551`，1s keepalive 重发），开关见 showTerminalProgress 设置（Chat UI 笔记 §5 覆盖执行侧）。

### 错误边界

**渲染层。** TuiMainScreen 检测到行宽超终端列宽时写 pi-crash.log、停止 TUI 并 throw（`tui-main-screen.ts:447-474`）——无组件级错误恢复，渲染异常走进程级兜底。

**进程级。** uncaughtException → uncaughtCrash（`interactive-mode.ts:3839-3856`）先 `ui.stop()` 恢复终端（raw 模式/光标/粘贴模式）再退出，注释明确这是防"终端残留 raw 模式需要 stty sane"的兜底；stdout/stderr EIO（终端已死）→ emergencyTerminalExit 直接 exit(129)（:3820-3826）。

**主题加载失败。** 静默回退 dark（`theme.ts:883-888`、:902-911），交互侧可经 showError 提示（`theme-controller.ts:103-106`）。

## 4. 主题、视觉 token 与持久化

**权威源。** `theme.ts` 全局单例——globalThis 上的 `Symbol.for("@earendil-works/pi-coding-agent:theme")`，导出 theme 为 Proxy 懒解析（未初始化即访问会抛错，:846-852），注释说明用 globalThis 是为跨模块加载器（tsx + jiti）共享同一实例（:840-841）。
- **token 模型**：JSON 主题经 typebox 校验，包含可引用且会检测循环的 vars、51 个必填与 4 个可选语义色，以及 HTML 导出背景。颜色按核心 UI、内容背景、Markdown、语法高亮、thinking、diff 和 bash 分组；部分 schema 注释中的数量与实际键数略有出入。（`theme.ts:31-110`）

  颜色值允许 hex、256 色索引、""（终端默认色）、var 引用；withThemeColorFallbacks（:331-344）为可选 token 提供回退（全表：scrollbarThumb→selectedBg、searchMatchBg→selectedBg、searchMatchText→text、thinkingMax→thinkingXhigh，Theme 构造内同套逻辑 :371-384）。

  内置的 `dark.json` 示例（:22-44）：accent 即 vars 引用，text: "#d4d4d4" 为直接 hex。

**颜色模式。** 按 `getCapabilities().trueColor` 选 24bit 或 256 色（:628-629），256 色路径有加权距离的 RGB→索引映射（:200-265）；fg/bg 生成 ANSI 序列包裹文本（:390-400）。

**组件接入。** 四个主题适配器（:1271-1335）把全局 theme 转成各组件主题接口；组件内部不再感知主题切换，切换后 invalidate + 请求重绘全量重绘（`theme-controller.ts:109-112`，onThemeChange 回调 `theme.ts:923-925`）。

**初始化与持久化。** `main.ts:884` 以交互模式与设置的主题值初始化主题系统；设置键（`settings-manager.ts:98`）的读写（:730-745）落全局 `settings.json`。

值可为主题名或 `light/dark` 斜杠自动模式（parseAutoThemeSetting :681-696，resolveThemeSetting :698-709）。

**系统跟随（终端主题适配）。** 三级检测 detectTerminalThemeForAuto（:810-830）——①终端颜色方案通知：queryTerminalColorScheme 发 DSR CSI ? 996 n、setTerminalColorSchemeNotifications 开 OSC 2031 订阅，应答经 parseTerminalColorSchemeReport（`packages/tui/src/terminal-colors.ts:67-73`）；

②OSC 11 背景色查询（queryTerminalBackgroundColor `tui.ts:1207-1228`）按亮度阈值判明暗（`theme.ts:763-765`）；③COLORFGBG 环境变量兜底（:767-786）。

InteractiveThemeController（`theme-controller.ts:18-139`）在 auto 模式时订阅颜色方案变化实时切换明暗两套主题（:120-138）；`startup-ui.ts:92-100` 启动后异步补一次检测（首帧用 env 检测先撑住）。

**检测结果回写与重订阅。** 未设置主题且非 auto 时，OSC 11 高置信度检测结果会写入 settings.theme 并 flush（`theme-controller.ts:60-66`），下次启动直接生效；rebindTui 在渲染器热切换（regular/fullscreen）后重订阅颜色方案通知（:38-42）。

**热重载。** startThemeWatcher（`theme.ts:927-998`）只监听自定义主题目录 `~/.pi/agent/themes/<name>.json`（`config.ts:523-525`），fs 事件 100ms debounce 后重读并 setGlobalTheme + 通知重绘；文件名/陈旧 timer 守卫齐全。内置主题不 watch。

**导出复用。** HTML 导出经 getResolvedThemeColors 生成 CSS 变量（:1063-1084，256 索引→hex 映射 :1019-1057）、getThemeExportColors 提供页面背景（:1098-1126）。

### 主题资源来源与注册表合并

**内置主题。** 主题目录按运行方式不同指向打包产物或源码内的固定位置（`config.ts:391-404`），仅 `dark.json`/`light.json` 两个。

**自定义目录。** `~/.pi/agent/themes/<name>.json`（`config.ts:523-525`），逐文件 try-catch 加载，无效主题在此静默忽略（注释说明由资源加载器在启动/重载时统一报诊断，`theme.ts:529-545`）。

**设置 themes 键。** 全局与项目级各有一套"主题文件或目录路径数组"（`settings-manager.ts:118`，读写 :1040-1054）；`/config` 选择器可增删该资源组（`config-selector.ts:26-38,537-575`）。

**自动发现目录。** 用户级 `~/.pi/agent/themes` 与项目级 `<cwd>/.pi/themes` 由 package-manager 作为资源目录收集（`package-manager.ts:903-904,2363-2374`），项目级仅在项目受信任时生效（:2395）。

**CLI。** `--theme <path>`（文件或目录，可重复，`cli/args.ts:162-164`）与 `--no-themes`（关闭主题发现与加载，:169；帮助文本 :285-286）。

**包与扩展贡献。** npm 包资源、清单文件（`pi-manifest.ts:7`）的 themes 字段、扩展资源发现返回的 themePaths（`core/extensions/runner.ts:1153-1192`、`core/agent-session.ts:2267-2279`）。

**注册表合并。** 全部来源经 setRegisteredThemes（`theme.ts:863-873`）灌入模块级注册表（启动时 `startup-ui.ts:78`，交互运行中从资源加载器刷新）；getAvailableThemesWithPaths（`theme.ts:493-520`）按内置→自定义目录→注册表顺序合并、同名去重、按名排序。

### 主题选择 UI 与预览

- **`/settings` 主题子菜单**（`components/settings-selector.ts:276-470`）：单主题模式列出全部可用主题；自动模式分别选择明暗两套主题（斜杠设置值）。

  移动光标即触发 onThemePreview → themeController.preview（`theme-controller.ts:82-89`，setTheme + 全量重绘，**不落盘**）；确认后才 settingsManager.setTheme + applyFromSettings（`interactive-mode.ts:4470-4474`）。

**首次设置向导。** FirstTimeSetupComponent 内联主题选择，选择即 setTheme 预览（`startup-ui.ts:189-197`），提交时持久化（:176）。

**启动选择器/向导装配。** 共用 createStartupTui（`startup-ui.ts:77-85`）——先注册启动主题（loadStartupThemes 经 package-manager 解析 :44-75）再 initTheme，启动后异步补一次终端主题检测（:92-100）。

### 扩展主题 API 与内存主题实例

- 扩展面：ctx.theme（当前 Theme 实例）、getAllThemes/getTheme/setTheme（`core/extensions/types.ts:265-275`）；ui.setTheme 接受主题名或 Theme 实例（`interactive-mode.ts:2382-2395`）。

**内存主题实例。** 传实例走 setThemeInstance（`theme.ts:914-921`）——当前主题名置为内存标记并**停止热重载 watcher**（注释 "Can't watch a direct instance"，:917）；非交互扩展运行器中主题 API 为空实现或报 "UI not available"（`runner.ts:258-263`、`rpc-mode.ts:290-298`）。

**仓库内调用实例。** `examples/extensions/mac-system-theme.ts` 轮询 macOS 外观（osascript，2s 间隔）并 `ctx.ui.setTheme("dark"/"light")` 跟随系统明暗——说明扩展可在内置三级检测之外自建系统跟随通道。

**主题名约束。** JSON 必填 name 且不允许含 `/`（保留给 light/dark 自动模式，`theme.ts:547-553`；`theme-schema.json:12-16` 同步 pattern）；`theme-schema.json` 仅供编辑器补全，权威校验是 typebox 的 ThemeJsonSchema。

### 本次未找到的主题机制（Grep 范围：`packages/coding-agent/src`、`packages/tui/src` 全部 `.ts` 与主题目录）

- 主题市场/商店/下载、importTheme/exportTheme 导入导出——无对应符号；主题分发完全走文件系统/包/扩展三路（见上）。
- 壁纸/背景图——无；终端背景色只用于明暗检测（OSC 11/DSR 996/COLORFGBG，见"系统跟随"），不作为主题内容。
- 强调色色阶生成——无 darken/lighten/mix 等调色工具，accent 是单 token，扩展色域只能靠 vars 引用与手工写值。
- 字体/字号/间距/圆角——无字号、密度、圆角 token 或设置；TUI 渲染单位是 cell，字体由终端模拟器控制，Pi 无控制通道。

## 5. 响应式、终端尺寸与窗口适配

- **regular 模式**（`tui-main-screen.ts:269-292`）：宽度变化触发全量重绘（换行变化），高度变化也全量重绘以保持视口对齐，但 Termux 场景（软键盘反复触发）跳过（:277-283）；内容收缩时按 clearOnShrink 清空多余空行（默认开，`PI_CLEAR_ON_SHRINK=0` 或设置关闭，`tui.ts:345`）。

**fullscreen 模式。** 每帧按当前终端尺寸重新布局，VStack 弹性分配（dock 里编辑器与页脚最小高度固定，`interactive-mode.ts:879-890`）；visible 回调可按视口条件隐藏条目（`stack.ts:82-87`），dock 本身未用，扩展可注入。

**overlay 自适应。** visible 回调每渲染帧评估（尺寸不足自动隐藏，`tui.ts:666-672`）；百分比宽高按当前终端计算（resolveOverlayLayout :957-1055）。

**手动控制。** tuiMode（regular/fullscreen）是设置项，可经 `/settings` 切换（`settings-manager.ts:1131-1137`、`settings-selector.ts:638-640`）或 `--tui-mode` CLI（`cli/args.ts:182-186`）；全屏输出与滚动条开关同层（:1141-1157）。

**其它终端适配。** 四项：
- 多路复用器（tmux/zellij/STY）下鼠标跟踪降级为按钮运动模式（`tui-alt-screen.ts:271-284`）；
- SSH 下 Esc 重组窗口 100ms（`terminal.ts:104-121`）；
- cell size 查询校准图片行高（`tui.ts:735-743,933-951`）；
- 终端尺寸回退默认值：宽度 COLUMNS/80、高度 LINES/24（`terminal.ts:493-499`）。

## 6. 图片、附件、剪贴板与常见内容交互

### 剪贴板（多层兜底链）

- copyToClipboard（`utils/clipboard.ts:73-175`）：优先 native 插件（`@mariozechner/clipboard`，Linux 跳过——注释解释其底层库在 Wayland 会话不保留 selection ownership，:82-87）；

  失败或未覆盖平台依次走 pbcopy/clip/termux-clipboard-set/wl-copy（spawn 防 hang，:134-143）/xclip/xsel；OSC 52（`\x1b]52;c;…`，base64 ≤100KB，:26-33）作为远程会话（SSH/MOSH）优先或本地兜底。读取 readClipboardText（:53-71，Wayland 用 wl-paste）。

**fullscreen 选区复制。** 鼠标选择后直接发 OSC 52 并 flash("Copied!")（`tui-alt-screen.ts:1043-1067`）；OSC 8 链接点击打开经 openUrl 回调（coding-agent 注入 openBrowser，`interactive-mode.ts:350`）。

**图片粘贴。** readClipboardImage（`utils/clipboard-image.ts`，含 WSL 用 PowerShell 读 Windows 剪贴板，:157 注释）→ 临时文件 → 编辑器插入路径（handleClipboardPaste `interactive-mode.ts:2848-2871`）；业务侧见 Chat UI 笔记 §1。

### 图片渲染（能力探测 + 协议编码）

- detectCapabilities（`packages/tui/src/terminal-image.ts:68-136`）：按 TERM_PROGRAM/环境变量识别 Kitty/ghostty/wezterm/warp（kitty 协议）、iTerm2（iterm2 协议）、Windows Terminal/VS Code/Alacritty（仅 truecolor）、tmux/screen（保守关闭图片与超链接，tmux 用 client_termfeatures 探测超链接转发，:52-66）；

  无协议时 Image 组件输出文本 fallback（`components/image.ts:113-120`，imageFallback）。

**尺寸链。** 图片按 cell size（默认 9×18，查询应答后更新，`terminal-image.ts:37`）换算行高；Image 组件按 maxWidthCells/maxHeightCells 渲染并缓存行（`image.ts:61-126`）；fullscreen 下 Kitty 图片有离屏缓存与淘汰（`tui-alt-screen.ts:330-378`，上限 16 张/32MB 传输/64MB 解码）。
- 消息内图片消费与尺寸设置（imageWidthCells/autoResize/blockImages）属消息渲染器/会话数据侧，见对应笔记。

### 附件与拖放（无拖放事件通道）

- TUI 无鼠标拖放事件通道（终端协议不支持），"drop files to attach" 通过**粘贴文件路径** + @ 附件补全实现：CombinedAutocompleteProvider 的 extractAtPrefix/buildCompletionValue（`packages/tui/src/autocomplete.ts:463-477,107-121`）解析 @路径（含引号包裹），

  walkDirectoryWithFd 用 fd 快速模糊搜索（gitignore 感知、AbortSignal 取消，:124-217），编辑器 `ATTACHMENT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"]`（`components/editor.ts:244`）。
- 剪贴板图片是唯一"拖入图片"等价路径（§6 图片粘贴）。

## 7. 键盘、焦点与输入基础设施

**键注册表分层。** TUI 层 TUI_KEYBINDINGS（`packages/tui/src/keybindings.ts:71-210`，tui.select.*/tui.editor.*/tui.input.*/tui.altScreen.*）；

coding-agent 通过模块声明合并扩展 app.* 键（`core/keybindings.ts:13-62`），KeybindingsManager 继承 TUI 基类并加载 `~/.pi/agent/keybindings.json` 用户覆盖（:340-367），同键多绑定记录冲突（`packages/tui/src/keybindings.ts:243-268`），旧键名有迁移表（`core/keybindings.ts:209-269`）。

组件只通过 keybindings.matches(data, …) 消费，不硬编码键（Pi 的 AGENTS.md 也强制此规则）。

**输入解码。** Kitty 键盘协议协商（flags 7：disambiguate/event types/alternate keys，`terminal.ts:247-277`）→ DA 哨兵判定后回退 modifyOtherKeys（:348-358）；Windows ENABLE_VIRTUAL_TERMINAL_INPUT native helper（:366-394，libuv 丢修饰键的修复）；

StdinBuffer 把批量输入拆成单序列（`stdin-buffer.ts`），bracketed paste 标记重组（`terminal.ts:221-226`）。

**焦点模型。** TUI 单焦点；Focusable.focused 由 setFocus 维护，聚焦组件在渲染中发 CURSOR_MARKER（APC 序列，零宽），渲染后 extractCursorPosition 定位硬件光标（`tui.ts:79,1182-1200`）——注释说明为 IME 候选窗定位；硬件光标显隐开关 PI_HARDWARE_CURSOR/设置 showHardwareCursor（`tui.ts:344`，`settings-manager.ts:1220-1225`）。

**全局调试键。** Shift+Ctrl+D 触发 onDebug（`tui.ts:850-853`）。
- 业务键位表与 `/hotkeys` 清单见 Chat UI 笔记 §1/§10。

## 8. 设计取舍与已确认边界

**自研 TUI 而非采用 Ink。** 差分渲染、双屏幕模式与终端协议协商（Kitty 键盘/图形、OSC 11/52/133/2026/2031）深度绑定，`packages/tui` 作为独立 npm 包发布（`package.json` description: "Terminal User Interface library with differential rendering"）。

**选择器用插槽替换而非 overlay。** 编辑器区域复用、焦点管理简单（单焦点模型），overlay 只保留"悬浮"语义（fullscreen 搜索框、扩展 overlay API）；regular 模式下内置代码不使用 overlay。

**反馈分轨。** regular 模式错误/状态是聊天区持久文本（随滚动，无自动消失），fullscreen 有 flash 反显条；无全局 toast host 概念。

**主题 token 化 + 终端默认色通道。** "" 表示终端默认色（`theme.ts:272-300`），主题无法完全控制背景，是与 Web 主题的本质差异；自动模式允许 `light/dark` 两个主题名组合。

**主题分发无市场/导入导出。** 主题以 JSON 文件经文件系统（设置 themes 键/`--theme`/自动发现目录）、npm 包与扩展三条来源进入注册表；选择走"预览不落盘、确认才持久化"，避免浏览主题过程污染设置；主题名中 `/` 被保留给自动模式语法。

**聊天区反馈防刷屏。** 连续状态更新复用末行（`interactive-mode.ts:3419-3423`）。

**保守能力探测。** tmux/screen 下关闭图片与 OSC 8 超链接，避免吞序列导致内容丢失（`terminal-image.ts:76-85` 注释）。

**渲染异常无组件级恢复。** 超宽行写 crash log 后 throw，靠进程级 uncaughtException 兜底恢复终端。

**扩展 overlay API 未在仓库内被消费。** showExtensionCustom overlay 模式存在，但仓库内无 overlay: true 调用实例（仅 API 面，见 §2）。

**动画/无障碍/桌面集成边界。** TUI 无读屏协议通道，可访问性靠键盘全功能 + 反显/强调色；动画仅 loader 帧动画与瞬时 flash，无过渡系统；"桌面集成"只表现为 OSC 通道（9;4 进度条、52 剪贴板、0 标题 setTitle `terminal.ts:532-535`），无托盘/系统通知概念。本笔记未展开这三项（机制过薄，无独立结论价值）。

## 9. 未验证事项

- 未在真实终端运行：差分渲染输出、resize 行为、Kitty 图片显示、OSC 52/OSC 9;4、颜色方案通知（DSR 996/OSC 2031）在各终端模拟器上的实际支持度、IME 硬件光标定位、flash 视觉表现——静态代码只确认事件绑定与序列生成。
- 依赖库内部未下钻：marked（Markdown 解析）、cli-highlight（语法高亮）、`@mariozechner/clipboard`（native 剪贴板）、get-east-asian-width 的内部行为均未阅读依赖源码。
- 主题自动跟随的实际切换延迟与热重载 debounce 表现未实测。
- 主题资源管线端到端未实测：设置 themes 键、项目 `.pi/themes` 自动发现、`--theme` 目录形态、扩展 themePaths 的实际解析与优先级；`/settings` 主题子菜单预览与首次设置向导的视觉表现未运行验证；setThemeInstance 内存主题路径无仓库内真实调用（示例扩展只按名字调用，`runner.ts`/`rpc-mode.ts` 均为占位实现）。
- 扩展 overlay 模式仅确认 API 存在，无仓库内运行实例。
- 进程级错误兜底（uncaughtCrash/emergencyTerminalExit）的触发路径未实测。

## 10. 终端能力配置

终端链接、图片协议和真彩色能力除了环境探测外，也可由设置中的 `terminal` 对象或 `PI_HYPERLINKS`、`PI_IMAGE_PROTOCOL`、`PI_TRUECOLOR` 环境变量覆盖。设置层只接受明确的布尔值或受支持图片协议，未指定时保留自动探测；该能力决定链接、图片和色彩的投影策略，不改变消息内容或会话数据（`packages/coding-agent/src/core/settings-manager.ts:43-47,1135-1138`、`packages/tui/src/terminal-image.ts:143-170`）。

## 11. 关键源码索引

- `packages/tui/src/tui.ts`：`showOverlay`/`OverlayHandle`（`:549-642`）、`compositeOverlays`（`:1092-1151`）、渲染调度（`:765-817`）、OSC 11/颜色方案/cell size 查询（`:1207-1255`）
- `packages/tui/src/tui-main-screen.ts`：`doRender` 差分渲染与 resize 处理（`:180-547`）、超宽行崩溃（`:447-474`）
- `packages/tui/src/tui-alt-screen.ts`：`doRender`（`:1223-1290`）、搜索 overlay（`:416-437`）、flash 合成（`:1209-1221`）、选区/OSC 52（`:1043-1067`）
- `packages/tui/src/layout.ts`：`renderLayoutFrame`（`:353-382`）、`paintBox`（`:304-351`）
- `packages/tui/src/keybindings.ts`：`TUI_KEYBINDINGS`（`:71-210`）、`KeybindingsManager`（`:231-307`）
- `packages/tui/src/components/`：`scroll-view.ts`、`select-list.ts`、`settings-list.ts`、`input.ts`、`editor.ts`（`:228-353` 主题/选项）、`loader.ts`、`cancellable-loader.ts`、`alt-screen-flash.ts`
- `packages/tui/src/terminal.ts`：Kitty 键盘协议协商（`:247-358`）、`setProgress`（`:537-551`）
- `packages/tui/src/terminal-image.ts`：`detectCapabilities`（`:68-136`）
- `packages/coding-agent/src/modes/interactive/theme/theme.ts`：token 模型（`:31-110`）、全局单例（`:840-857`）、`initTheme`/`setTheme`（`:875-912`）、`setRegisteredThemes`/`setThemeInstance`（`:863-873`/`:914-921`）、注册表加载源（`:493-545`）、主题名约束（`:547-553`）、终端主题检测（`:679-830`）、主题工厂（`:1271-1335`）
- `packages/coding-agent/src/modes/interactive/theme/theme-controller.ts`：auto 同步（`:114-138`）、预览不落盘（`:82-89`）、检测结果回写（`:60-66`）
