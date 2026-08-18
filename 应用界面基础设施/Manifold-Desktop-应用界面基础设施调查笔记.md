# Manifold Desktop 应用界面基础设施调查笔记

> 调查对象：`https://github.com/gregorik/Manifold-Desktop`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 是极薄的 WinUI 3 原生壳加无框架 WebView2 前端。原生层只负责窗口、系统对话框、剪贴板和消息桥，Toast、确认框、搜索浮层、设置抽屉等界面机制全部由前端原生 DOM 与 CSS 实现。

这些浮层大多是创建后常驻的模块级单例，没有统一 Host、Portal 或栈管理器，层级依赖手写 z-index。搜索浮层支持 Esc 和方向键，确认框却没有同等的焦点陷阱、Esc 关闭和焦点归还，键盘行为并不一致。

主题由原生 `settings.json` 持有，前端通过 `data-theme` 切换固定的 dark 和 light token。项目没有系统跟随、强调色、字体族、密度、自定义 CSS、壁纸或主题导入导出；系统通知、附件拖放和图片灯箱也未实现。

## 系统边界与总体装配

**两层装配关系**：

- 原生层只有一个窗口。`App::OnLaunched`（App.xaml.cpp:38-42）创建 MainWindow 并激活；MainWindow.xaml 只有 RootGrid 加一个空的 Border WebViewHost（:12-14），无任何业务 XAML 控件——整个 UI 是 WebView2 渲染的网页。
- WebView2 初始化是异步 COM 回调链（MainWindow.xaml.cpp:197-236）：CreateCoreWebView2EnvironmentWithOptions → CreateCoreWebView2Controller(m_hwnd) → OnWebViewCreated。

  装载顺序为：设置深色默认背景 → 禁用浏览器加速键（把 Ctrl+N/T/W 让给 JS，:261-265）→ 虚拟主机映射 `manifold.local → <exe目录>\frontend`（:277-281）→ 注册 WebMessageReceived 与 NavigationCompleted → `Navigate(https://manifold.local/index.html)`（:321）。

**握手协议。** 导航完成后原生发送 HOST_READY（providerKeys、settings、version，:300-319），前端 `frontend/services/settings-store.js:46-57` 在收到后才把设置状态置 ready 并应用主题/字号；

前端启动即发 FRONTEND_READY（`frontend/app.js:221`），但原生 OnWebMessage 的派发表（MainWindow.xaml.cpp:419-454）没有对应分支——该消息无消费者，是空路径。

**桥。** 双向 JSON 字符串消息。前端 `frontend/services/bridge.js:4-41` 的 send/on/once 封装 window.chrome.webview.postMessage 与 message 事件；

原生 OnWebMessage 按 type 字段分发到 Handle* 方法（MainWindow.xaml.cpp:404-454），回程统一走 PostMessageToWeb（:456-462）。流式数据经 m_dispatcherQueue.TryEnqueue 从后台 `std::jthread` 切回 UI 线程（如 HandleChatSend :819-821）。
- 原生侧消息表里出现但前端没有任何发送/监听点的消息：GET_SETTINGS、OPEN_FILE_DIALOG（对应 FILE_ATTACHED 回程）——附件链路是原生已实现、前端未接线的死路径（Grep `frontend/**/*.js` 无命中）。

**原生层的"界面基础设施"存量**（即全部）：

1. 窗口状态持久化：关闭时 SaveWindowState 写 `%LOCALAPPDATA%\Manifold\window-state.json`（位置/大小/最大化），构造时 RestoreWindowState 恢复并做工作区越界修正与最小尺寸兜底（MainWindow.xaml.cpp:343-400）。
2. 系统对话框：IFileOpenDialog/IFileSaveDialog Win32 公共对话框，用于会话导出/导入、Markdown 导出（:559-617、:619-646、:648-677、:679-722）。
3. 剪贴板与外部 URL：COPY_TO_CLIPBOARD 用 Win32 OpenClipboard/SetClipboardData(CF_UNICODETEXT)（:724-744）；OPEN_EXTERNAL_URL 用 ShellExecuteW（:746-753）。
4. DPI：app.manifest:16 声明 PerMonitorV2；`RootGrid().SizeChanged` 触发 ResizeWebView 用 GetClientRect 像素设置 put_Bounds（MainWindow.xaml.cpp:176, 325-332）。
5. 窗口关闭清理：Closed 时保存窗口状态、停止终端进程、关停插件与 MCP、释放 WebView COM 指针（:179-192）。

**未找到**（Grep 范围 `*.cpp/*.h/*.xaml/*.idl`）：
- ContentDialog、Flyout、MenuFlyout、TeachingTip、InfoBar、ToastNotification/AppNotification——原生层没有任何 WinUI 浮层、提示或系统通知控件；
- 主题相关只有 MainWindow.xaml:12 一处 ThemeResource（ApplicationPageBackgroundThemeBrush）。

**前端装配**：`index.html:18-29` 固定四个区域加一个独立 toast 容器：
- `#tab-bar`、`#main-area`（侧栏+标签内容）、`#input-bar`
- `#toast-container`

`app.js:24-30` 一次性创建 tab-bar/side-panel/input-bar/settings-panel/search-overlay 五个单例并挂载，Home 标签常驻（:41-44）。

无 Provider/Portal/Overlay Host 抽象，无路由，无 store 框架（见第 1 节）。

## 1. 界面栈、公共组件与状态所有权

**界面栈。** 原生层 WinUI 3（Windows App SDK 1.8.260101001，packages.config:8-17）；前端为无框架 vanilla ES Modules + 手写 CSS，依赖仅 `vendor/marked.min.js` 与 `vendor/highlight.min.js`（`index.html:27-28`）。

前端无构建步骤（`docs/architecture.md:88` 原话 "no virtual DOM, no framework, and no build step"）。
- **公共组件清单**（模块级单例）：
  - `services/toast.js`（Toast）
  - `services/confirm.js`（确认弹窗）
  - `components/search-overlay.js`（搜索浮层）
  - `components/settings-panel.js`（设置抽屉）
  - `services/settings-store.js`（设置缓存 store）

  没有统一的命令式弹窗服务、浮层队列或 Portal 概念；各浮层各自管理自己的挂载与 z-index。

**状态所有权。** 业务偏好（theme、fontSize、temperature、systemPrompt、streamResponses、provider 配置、MCP/插件开关）的权威在原生 `Manifold::Core::AppSettings`（`Manifold.Core/SettingsManager.h:23-51`），落盘 `%LOCALAPPDATA%\Manifold\settings.json`（SettingsManager.cpp:82, 136-144）。

    前端 `settings-store.js` 是缓存：HOST_READY 初始化、SETTINGS_UPDATED 订阅原生回传、updateSettings 乐观更新本地后发 SAVE_SETTINGS（:31-35,46-57,59-64）。

    改动设置时原生 HandleSaveSettings 做钳制（温度 0-2、字号 10-24、系统提示词 10000 字，MainWindow.xaml.cpp:480-494）。
  - UI 状态（标签、聊天消息、流式文本、搜索浮层可见性、设置面板可见性）：全部组件局部或模块级闭包，无全局 store；聊天状态细节见 Chat UI 笔记第 8 节。
  - 用量统计与 onboarding 标记：前端 localStorage（`services/pricing.js:41-61`、`components/home-tab.js:56`）。

**单窗口单入口。** 本快照只有一个 WebView2 控制器挂在一个 HWND 上（MainWindow.xaml.cpp:228），无多窗口/分离窗口机制（与 Chat UI 笔记第 1 节一致）。

## 2. 弹窗、浮层与菜单

原生层无浮层控件（见系统边界）；以下全部是 Web 侧机制。z-index 分层：

| 浮层 | z-index | 位置 |
|---|---|---|
| 设置抽屉 | 100 | `styles/base.css:403` |
| Toast | 200 | :460 |
| 搜索浮层 | 250 | `styles/search.css:9` |
| Confirm 遮罩 | 300 | `styles/layout.css:67` |

### Confirm 确认弹窗（`services/confirm.js`）

- 唯一命令式弹窗：showConfirm(message) 返回 `Promise<boolean>`（`confirm.js:2-31`），每次调用动态创建遮罩与对话框两个 DOM 节点，两个按钮加遮罩点击关闭（:24-26，以点击目标是否为遮罩本体判断）。
- 焦点与键盘：打开后 `ok.focus()`（:29）；**无 Esc 处理、无焦点陷阱、无关闭后焦点归还**——全部静态确认（文件全文无 keydown 监听）。
- 消费方：流式期间关闭聊天标签（`app.js:66-69`）、删除会话（`side-panel.js:122-127`）。Chat UI 笔记第 5 节已指出 Ctrl+W 直接关闭绕过该确认（`app.js:186-196`）。
- 打开期间未发现滚动锁定机制（body 无 overflow:hidden 切换；静态推断，另 `base.css:87` 中 body 本就 overflow:hidden，应用级滚动区域在内部容器）。

### 搜索浮层（`components/search-overlay.js`）

- 单例，Ctrl+F 切换（`app.js:206-209`）。打开时清空输入并聚焦输入框（`search-overlay.js:87-94`），遮罩点击、Esc 关闭，方向键与 Enter 导航结果（:19,35,36-58）。300ms 防抖发 SEARCH_SESSIONS（:24-32），结果点击后关闭并打开会话（:76-79）。无 aria 属性（`role=dialog`/aria-modal 均未设置）。
- 关闭后焦点不归还：`hide()` 只移除 `.open` 类（:96-100），无焦点管理。

### 设置抽屉（`components/settings-panel.js`）

- 单例，Ctrl+, 切换（`app.js:197-200`）。CSS 过渡滑入（`base.css:394-409`：right: -360px → 0，200ms）。打开时无 focus 调用，关闭只靠 × 按钮或再次 Ctrl+,；**无 Esc 处理、无遮罩层**（`styles/settings.css:1-8` 定义的 `.settings-overlay` 遮罩类无任何 JS 创建点，属死样式）。
- 内容为 6 个分区（general/providers/plugins/mcp/prompts/usage，`settings-panel.js:29-36`），分区切换即渲染；表单改动标脏点（`.settings-dirty-dot`，:442-446）并即时 updateSettings 落盘。

### 提示词下拉（`components/input-bar.js:109-153`）

- 📋 按钮发 LIST_PROMPTS，响应到达后动态建 `.prompt-dropdown`（`position:absolute; bottom:100%`，无定位父级翻转、无聚焦/键盘导航）。关闭方式只有两种：点击某项后移除，或文档任意点击一次后移除（:149-151 的一次性监听）；**无 Esc 处理**。
- 选中 system 提示词会替换全局系统提示并持久化（:133-137，注意此时 `updateSettings({systemPrompt})` 走设置链路而非仅插入文本）。

### 其它浮层/菜单

- **onboarding 覆盖层**（`home-tab.js:53-79`）：Home 页内嵌卡片而非全屏遮罩，无 API key 且未 dismissed 时渲染，Dismiss 写 `localStorage['manifold_onboarded']`。
- **更新横幅**（`home-tab.js:16-26`）：UPDATE_AVAILABLE 时在 Home 页顶部插入横幅，Download 链接走 OPEN_EXTERNAL_URL（原生 ShellExecuteW 打开浏览器）。

**右键菜单。** 全仓库无 contextmenu 事件处理（Grep `frontend/**/*.{js,html}` 无命中）；会话列表删除/导出按钮是悬停浮现的 × 与 MD 按钮（`side-panel.js:117-142`），不是菜单。原生层亦无 MenuFlyout。
- 工具调用块/消息内的展开收起（`message-renderer.js:48-51`）是行内点击切换 class，不属于公共浮层机制。

## 3. 通知、加载态与错误反馈

### Toast（`services/toast.js`）

- 唯一 Toast 实现：底部右侧容器（`base.css:456-464`，z-index 200），showToast(message, type) 创建 `toast toast-${type}`，4 秒后透明度渐退 200ms 再移除（`toast.js:16-20`）。无队列上限、无更新/取消、无 promise 令牌、无 aria-live/role 属性。
- type 参数在 CSS 中无对应规则（Grep `styles/*.css` 只有 `.toast` 基础样式，无 `.toast-error`/`.toast-info`/`.toast-warning` 色差）——类型目前只有 class 名差异，视觉不区分（静态推断）。

**唯一调用点。** `app.js:224-227` 的全局 window.onerror 与 unhandledrejection（全局脚本错误兜底）。聊天主链、设置、导入导出等业务流程均不弹 Toast——README 宣称的 "Toast notifications -- non-intrusive status messages"（`README.md:59`）目前只挂载了全局错误路径。

**系统通知。** 原生与前端均未实现（原生 Grep 无 ToastNotification/AppNotification；前端 Grep 无 new Notification）。无托盘、无后台完成通知。

### 加载态与空状态

- 聊天空状态：`chat-tab.js:14-17` 的 `.chat-empty` 纯文本 "Start a conversation"，首个 chunk 到达即移除（:29-30）。
- 流式指示：`.streaming-indicator` 脉冲圆点（`chat-tab.js:37-39`；`chat.css:94-107`）。`base.css:445-453` 的 `.streaming-dots::after` 与 `chat.css:110-113` 的 `.loading-dots::after` 两个文字动画类已定义但无 JS 使用点（Grep 无命中），属死样式。
- 会话列表空状态：`side-panel.js:68-72` 的 "No sessions yet"/"No results" 文本。
- 设置各分区空状态：`settings-panel.js:206, 267, 312, 342, 372` 的 "No providers configured" 等文本；搜索浮层 "No results found"（`search-overlay.js:64`）；提示词下拉 "No saved prompts"（`input-bar.js:125`）。
- 错误反馈：无全局错误边界；聊天错误走 CHAT_ERROR 事件渲染行内 `.error-message` 行（`chat-tab.js:87-98`，Retry 按钮只删行不重发，见 Chat UI 笔记）；compare 错误走列内文本行（`compare-tab.js:73-81`）。加载失败/会话损坏无专门空态。

## 4. 主题、视觉 token 与持久化

**权威源。** 主题值（`dark`/`light` 二选一，SettingsManager.h:28 默认 `dark`）以 `settings.json` 为持久化权威，经 HOST_READY/SETTINGS_UPDATED 下发；

前端 `settings-store.js:71-73` 的 applyTheme 设置 document.documentElement 的 data-theme 属性，CSS 变量随之切换。**无 "system" 选项**（设置面板仅 Dark/Light 两项，`settings-panel.js:132-135`）；

非 vendor 代码无 matchMedia/prefers-color-scheme 使用——prefers-color-scheme 字符串仅出现在 `vendor/highlight.min.js:316` 的媒体查询特性列表内（依赖库内部），不做系统跟随。

**Token 体系全集。** `base.css:2-11` 的 :root 定义 8 个布局/字体常量：

```
--font-size:14px
--mono-family
--sans-family
--radius:8px
--radius-sm:4px
--transition:150ms ease
--sidebar-width:260px
--header-height:42px
```

dark 与 light 两档各定义 29 个同名语义变量，覆盖背景、文本、边框、强调色、消息气泡、代码块、输入框、滚动条、阴影和状态色。两套变量集合完全对齐，组件无需为明暗模式切换类名。（`base.css:14-77`）

去重后语义变量 29 个 + 根常量 8 个 = 37 个。`index.html:2` 硬编码 `data-theme="dark"` 作首帧默认。字号由 `settings-store.js:75-76` 以行内 `--font-size` 同名覆盖 :root 值。

**强调色、字体、密度均无自定义。** 设置面板 general 分区只有 Theme/Temperature/Font Size/System Prompt/Stream 五组控件（`settings-panel.js:127-155`），无强调色选择器、字体设置与密度/圆角设置项：
- 强调色：4 个 token 随主题档硬编码（dark `#6366F1` / light `#4F46E5`，`base.css:25-28,58-61`）；
- 字体：fontFamily 全仓库无命中，只有 `--mono-family`/`--sans-family` 两个固定族（`base.css:4-5`）；
- 密度与圆角：`--radius`/`--radius-sm` 固定 8/4px，无设置项。

**theme 值无白名单校验。** HandleSaveSettings 只钳制 temperature（0-2）、fontSize（10-24）、systemPrompt（10000 字），theme 字符串任意值直通（MainWindow.xaml.cpp:480-494）；非法值经 applyTheme 写入 data-theme 后无匹配 CSS 规则，token 回退 :root 默认（静态推断，未运行验证）。

**深浅色与原生层的关系。** 原生窗口背景用 ApplicationPageBackgroundThemeBrush（MainWindow.xaml:12），跟随系统主题；App.xaml 无自定义主题资源（仅 XamlControlsResources）。

WebView2 默认背景色在 OnWebViewCreated 硬编码为深色 `{255,24,24,27}`（MainWindow.xaml.cpp:240-245，即 #18181B）且之后**不再随主题更新**——浅色模式下页面加载瞬间与窗口边缘可能露出固定深色（静态推断，运行表现未验证）。

**首屏与持久化路径。** 首帧固定暗色（index.html 硬编码），HOST_READY 到达后按保存值切换，无防闪烁机制；localStorage 不参与主题（manifold_onboarded 与 manifold_usage 是仅有的两个 localStorage 键，均与主题无关）。跨窗口同步问题不存在（单窗口）。

**其它组件接入 token。** 各处消费方均为对公共变量的直接引用，无组件级私有主题化：
- 终端状态灯动画与选择高亮：`--accent`/`--accent-transparent`（`terminal.css:34-45`）；
- 消息渲染器代码块行内样式：`--code-bg`/`--border`（`message-renderer.js:99`）；
- 提示词下拉等行内样式：`var(--...)`（`input-bar.js:123`）。

**代码块高亮。** `highlight-github-dark.min.css` 无条件加载（`index.html:15`），与 `data-theme="light"` 无关——浅色模式下代码块仍使用深色高亮主题（静态推断，未验证是否有深色代码块与浅色页面混搭的视觉表现）。
- **本次未找到**（主题体系专项 Grep，范围 `frontend/**` 非 vendor、`Manifold.Core/**`、原生层 `*.cpp/*.h/*.xaml/*.idl`）：
  - 主题市场/商店与主题导入导出：importTheme/exportTheme/`theme.json` 均无命中，frontend 下无任何 `*.json` 文件、无 `themes/` 目录；
  - 壁纸/背景图：wallpaper/backgroundImage 无命中，`styles/*.css` 无 `url()` 引用；
  - 自定义 CSS：customCss/userStyle 无命中；
  - 原生层 RequestedTheme 无命中——原生主题通道只有 MainWindow.xaml:12 一处 ThemeResource。

## 5. 响应式、移动端与窗口适配

**断点与媒体查询。** 全部 `frontend/styles/*.css` Grep 无 @media/@container 命中；前端无 matchMedia/innerWidth 逻辑。唯一响应式手段是 Home 页两张 `grid-template-columns: repeat(auto-fill, minmax(220px/180px, 1fr))` 网格（`home.css:52, 83`）。

**侧栏折叠。** `side-panel.js:23-25` 导出 `toggle()`（切 `.collapsed`，`layout.css:35` 隐藏）但全仓库无调用点，无折叠入口（Chat UI 笔记第 1 节已记录）。

**窗口尺寸。** 原生只做恢复时兜底（宽 <400 高 <300 回退 1200×800，MainWindow.xaml.cpp:395-396）与关闭时保存，未发现运行期最小尺寸约束；无 AppWindow/SetMinSize 调用（Grep 无命中）。WebView 随 RootGrid.SizeChanged 全量拉伸（:176, 325-332）。

**终端自适应。** 唯一使用 ResizeObserver 的地方——`terminal-tab.js:211-247` 按测量字符宽高重算 cols/rows，变化时发 TERMINAL_RESIZE（原生 HandleTerminalResize 同步 ConPTY，MainWindow.xaml.cpp:988-998）。

**DPI。** app.manifest:16 PerMonitorV2；ResizeWebView 用物理像素客户端矩形。WebView2 自身的缩放、put_Bounds 在混合 DPI 下的行为未运行验证。

**移动端/多窗口差异。** 不适用——README 限定 Windows 10+ x64 桌面（`README.md:70`），单窗口单平台。

## 6. 图片、附件、拖放与常见内容交互

**图片与附件。** 前端无任何图片渲染、预览或附件 UI（Grep frontend 无 `<img>`、无 FILE_ATTACHED 消费、无灯箱组件）。

原生 HandleOpenFileDialog 会把多选文件读成 base64 回传 FILE_ATTACHED（MainWindow.xaml.cpp:559-617），但前端无发送 OPEN_FILE_DIALOG 的调用点、无 FILE_ATTACHED 监听——**整条附件链路原生已写、前端未接线**（死路径）。

会话导出/导入走的是原生 IFileOpenDialog/IFileSaveDialog（MainWindow.xaml.cpp:619-677），前端只发 EXPORT_SESSION/IMPORT_SESSION/EXPORT_MARKDOWN 消息。

**拖放。** 全仓库无 dragover/drop/dragstart/FileReader/`input[type=file]`（Grep frontend 无命中，含原生层）；不支持任何拖放上传。

**剪贴板。** 两条路径并存。① 消息代码块复制用 navigator.clipboard.writeText（`message-renderer.js:23-31`，按钮短暂变 "Copied!"）；② 终端 `Ctrl+Shift+C/V`：优先 navigator.clipboard，writeText 不可用时回退原生桥 COPY_TO_CLIPBOARD（`terminal-tab.js:185-208`；

原生实现 MainWindow.xaml.cpp:724-744）。终端粘贴 Ctrl+Shift+V 只走 navigator.clipboard.readText（`terminal-tab.js:202-208`），无原生回退。

**外部链接。** Home 更新横幅 Download 经 OPEN_EXTERNAL_URL → ShellExecuteW（`home-tab.js:23`、MainWindow.xaml.cpp:746-753）。消息内链接为普通 `<a>`（`chat.css:264` 无 target 处理，默认 WebView2 内导航——是否拦截新窗口导航未验证，原生未注册 NewWindowRequested）。

## 7. 设计取舍与已确认边界

**原生壳刻意做薄。** WinUI 层除了承载 WebView2 与系统级能力（窗口、对话框、剪贴板、DPAPI）外没有任何界面实现；浮层、主题、反馈全部落在 Web 侧，且全部为手写零依赖实现。

**无公共浮层抽象。** Confirm/搜索/设置/下拉各自为政，无统一 Portal、无层级队列、无 Esc 契约——同一浮层打开时另一个浮层可见性不做互斥管理（如设置抽屉开着时 Ctrl+F 打开搜索浮层，两者并存，z-index 决定覆盖；静态推断）。

**死代码存量。** 以下项目均经 Grep 确认无对应消费：
- FRONTEND_READY：原生无 handler；
- GET_SETTINGS：前端无发送点；
- OPEN_FILE_DIALOG / FILE_ATTACHED：前端无消费点；
- `.settings-overlay` / `.loading-dots` / `.streaming-dots`：样式无 JS 使用点。

**深浅色边界不一致。** `index.html` 首帧硬编码 dark + WebView2 默认背景硬编码深色 + 高亮 CSS 固定深色，与设置持久化主题解耦；浅色主题下存在首帧与边缘露色的静态推断风险。

**视觉定制面极窄。** 视觉偏好仅 theme + fontSize 两项（`settings-panel.js:127-155`），强调色、字体、密度、圆角、壁纸与自定义 CSS 均无通道，全部 token 硬编码于 `base.css`；README 未宣称主题扩展能力（v0.2.0 changelog 的 "Terminal theme variable consistency" 是终端 token 修复条目，`README.md:172`）。

**侧栏宽度 token 与硬编码并存。** `base.css:9` `--sidebar-width:260px` 与 `layout.css:27` 实际 `#side-panel { width: 240px }` 不一致，且 `base.css` 的 `.sidebar` 类规则无 JS 使用点（实际容器是 `#side-panel`，全部行内样式渲染）。

**会话/设置持久化双权威。** 偏好落盘原生侧，UI 态不落盘（内存标签、草稿丢失见 Chat UI 笔记）；localStorage 只用于用量与 onboarding 标记。

## 8. 未验证事项

- 全部视觉表现（动画时长、深浅色实际观感、浅色模式下代码块高亮、首帧露色）与键盘可用性、焦点顺序均未经运行验证；未构建本快照。
- Toast type 无 CSS 区分、浮层并存行为、"Ctrl+W 绕过流式确认"等属于静态推断，未运行确认。
- WebView2 的 DPI 缩放行为、文档标题（`app.js:57` 更新 document.title）是否同步原生窗口标题、消息内 `<a>` 点击是否触发新窗口导航均未验证（原生未注册 NewWindowRequested）。
- 原生层未使用 ContentDialog/Flyout 等控件，因此 WinUI 框架默认的焦点陷阱、Esc 关闭等行为在本项目中不存在对应机制，未做框架层面核实；Confirm 弹窗自身无 Esc/焦点陷阱属源码直接确认。
- FILE_ATTACHED/OPEN_FILE_DIALOG 死路径、onboarding 覆盖层与更新横幅的运行表现未验证。
- theme 写入非法值时的 token 回退、浅色模式下终端/代码块等深色部件的实际观感未经运行验证（静态推断）。

## 9. 关键源码索引

- `Manifold.Core/SettingsManager.h/.cpp`：AppSettings 与 settings.json 持久化（28, 82, 136-144）
- `frontend/services/bridge.js`：WebMessage 桥
- `frontend/services/confirm.js`：确认弹窗（2-31）
- `frontend/services/toast.js`：Toast（2-21）
- `frontend/services/settings-store.js`：设置缓存、主题/字号应用（46-77）
- `frontend/components/search-overlay.js`：搜索浮层（19, 34-58, 87-102）
- `frontend/components/settings-panel.js`：设置抽屉（420-436）
- `frontend/components/input-bar.js`：提示词下拉（109-153）
- `frontend/components/home-tab.js`：onboarding 与更新横幅（16-26, 53-79）
- `frontend/components/terminal-tab.js`：终端剪贴板与 ResizeObserver（185-247）
