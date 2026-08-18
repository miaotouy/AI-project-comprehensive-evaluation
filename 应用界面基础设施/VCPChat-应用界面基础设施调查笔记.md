# VCPChat 应用界面基础设施调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 不依赖第三方 UI 组件库。通用弹窗通过 HTML template 懒加载，确认框提供 Promise 接口，头像裁剪另有 Canvas 实现；通知分为短时 Toast 和持久侧栏列表，没有系统 Notification 通道。

主题切换会覆写整份 `themes.css` 并重新加载窗口，不是运行时 token 热替换。主窗口壁纸跟随主题文件，用户没有独立壁纸管理、主题编辑或导入导出入口。Compact 导航也由设置显式控制，不随窗口宽度自动切换。

图片预览运行在独立 Electron 子窗口，支持缩放、绘图和 OCR，能力面比普通灯箱更大。核心控件已有部分 ARIA，但消息与侧栏区域的语义、弹窗焦点陷阱和焦点归还仍不完整。

## 系统边界与总体装配

**界面栈。** Electron 主进程 + 渲染进程原生 JS（无前端框架）；多子窗口：主题选择器（独立 850×700 无框子窗口）、图片查看器、语音聊天、便签（note-mini）等。

**弹窗机制。** `modules/ui-helpers.js` 的 uiHelperFunctions 负责打开、关闭、确认和 Toast；Modal 元素用 `<template>` 懒加载，打开时从同名模板克隆到 `#modal-container`，再派发 modal-ready 自定义事件（:339）通知各模块绑定事件监听器。

**状态所有权。** 主题模式在 `settings.json` 的 currentThemeMode；侧栏状态（折叠、宽度）由渲染进程设置持久化；消息与话题历史见会话与消息管理笔记。

**状态所有权清单**（补充调查核对）：

- **主题**（settings.json.currentThemeMode）：权威值在主进程，由 `themeHandlers.js:22-39` 经 set-theme-mode IPC 写入并设置 nativeTheme.themeSource；读取当前主题时使用系统暗色判断（:46-48）。渲染层启动时自行读设置后经同一 IPC 触发统一广播回环，不直接改 CSS（见第 4 节首帧链路）。
- **侧栏状态**（settings.json.sidebarWidth/notificationsSidebarWidth/sidebarAvatarOnly）：渲染进程持有并持久化。宽度在拖拽结束时写入内存设置再落盘，avatarOnly 开关同样走设置保存（`uiManager.js:143-154`、`event-listeners.js:1303-1337`）；主进程只负责文件读写，不消费这些字段。

**Toast/通知。** 主进程只转发 VCP 日志事件（`renderer.js:523-537` 的 onVCPLogMessage），展示状态由渲染层通知单例持有（浮动 Toast 与侧栏双通道，关键分支见 `modules/notificationRenderer.js:67,248`），无持久化、无跨窗口同步；

应用内部反馈走独立的 Toast 入口（`ui-helpers.js:367-415`），不进入 VCP 通知通道。

**弹窗。** 命令式 UI 由 uiHelperFunctions 持有与销毁，无全局 store；Modal 的 DOM 生命周期（从 `<template>` 克隆到 `#modal-container`、关闭移除）由该模块管理，入口见 `ui-helpers.js:323-360, 889-977`。

## 1. 界面栈、公共组件与状态所有权

**没有使用任何第三方 Modal 库**，全部自定义，有两套分支：

- **通用 Modal**（`uiHelperFunctions.openModal/closeModal`，`modules/ui-helpers.js:323-360`）：给目标元素加/移除 active class。模型选择、正则规则和全局设置三个弹窗均走此路径。

  打开时聚焦 Modal（:347），但**没有焦点陷阱（focus trap）**，Tab 键可以离开 Modal 到达背景元素。Esc/遮罩点击关闭需各弹窗自行绑定：正则规则弹窗绑定了遮罩点击（:736-739），全局设置弹窗未见 Esc 监听。
- **确认对话框**（uiHelperFunctions.showConfirmDialog，`modules/ui-helpers.js:889-977`）：返回 `Promise<boolean>`，用于删除 Agent、群组和正则规则等危险操作。

  动态创建 `.confirm-dialog-overlay` 附到 document.body，requestAnimationFrame 后加 visible class 触发 CSS 进场动画，确认按钮自动聚焦（:944）。支持 Esc 取消（:948）、Enter 确认（:951）和点击遮罩取消（:959-963）。`isDanger=true` 时确认按钮加 danger class（红色）。

  关闭时移除 visible class，200ms 后从 DOM 移除（:969-974）。
- **头像裁剪器**（avatarCropperModal）：Canvas 实现，支持拖拽移动圆形裁剪框和滚轮缩放（半径范围 30-100px），`modules/ui-helpers.js:460-626`。裁剪完成后用 canvas.toBlob 生成 PNG 通过回调传出；事件监听器在关闭时逐一 removeEventListener 清理（:601-608）。

## 2. 弹窗、浮层与菜单

见第 1 节（通用 Modal、确认对话框、头像裁剪器三套）。表情包选择器（`modules/emoticonManager.js`）从服务端 API getEmoticonLibrary() 加载表情库，**只筛选当前用户对应分类**（“通用表情包” + “${userName}表情包”两个分类，:53-59），以平铺图片网格呈现，无搜索、无分类切换、无分页（:85-99）；

面板固定 270×240px，出现在按钮上方（:158-165），上方空间不足则移到下方（:161-163）；点击面板外部关闭（100ms 延迟绑定避免立即触发，:107）；点击表情包把 `<img src="..." width="80">` HTML 标签插入输入框（:131-135），不是转义后的 Markdown 语法；

无加载动画，表情库为空时显示"没有找到可用的表情包"占位（:89-90）。

## 3. 通知、加载态与错误反馈

全部自定义，无系统 Notification API 调用，无 Toast 第三方库（`modules/notificationRenderer.js`）。展示分为浮动 Toast 和持久侧栏两条通道：

**浮动 Toast（`#floating-toast-notifications-container`）**：
- prepend 插入，新 toast 在最上方叠加，无数量上限（会随时间自动消失）。
- 默认 **7 秒**自动消失（:460）；tool_approval_request 类型**永不自动消失**（:463-465），须用户点击允许/拒绝后才消失；支持通过过滤规则配置 duration（毫秒），`duration=0` 也表示永久（:467-469）。
- 点击 toast 本体立即手动关闭（审核类通知例外，:340-342）。
- 关闭动画：加 exiting class → 监听 transitionend 移除 DOM，500ms fallback 强制移除（:399-413）。
- 通知侧栏（`#notificationsSidebar`）处于 active 状态时**抑制浮动 toast**，直接写入侧栏列表（:449）。
- 窗口获焦时清理已加 exiting 且超过 10 秒的残留 toast（:517-547）；每 30 秒定时清理超 15 秒的 toast（:552-571）。

**持久侧栏列表**：列表项插入通知列表顶部，点击淡出并右滑消失（:387-394），复制按钮复制原始 JSON；tool_approval_request 项展示允许/拒绝按钮和可选理由文本框（:278-330）。

uiHelperFunctions.showToastNotification（`modules/ui-helpers.js:367-415`）是面向应用内部的简化版 Toast，支持四种 type（info、success、error、warning）和自定义 duration（默认 3000ms），行为与上面的浮动通道相似。

**加载态（Loading）**（补充调查）：

**应用启动。** 批处理启动原生启动屏 NativeSplash.exe（`main.js:660` 注释说明由批处理拉起），显示 splash.html 的"正在初始化, 请稍候..."文字和伪进度条（按 10%/30%/70%/100% 假进度推进，`splash.html:92-98, 102-110`）；主窗口 did-finish-load 时生成 `.vcp_ready` 信号文件供启动屏退场（`main.js:438-446`）。

**Agent/群组列表加载中。** `itemListManager.js:923` 插入 `<li><div class="loading-spinner-small"></div>加载列表中...</li>`。

**话题列表加载中。** `topicListManager.js:540` 插入 `<div class="loading-spinner-small"></div>正在加载 X 的话题...`；群组话题分支是纯文本 `<p>正在加载群组 X 的话题...</p>`（`Groupmodules/grouprenderer.js:983`）。

**聊天记录加载中。** 以 isThinking: true 的 system 消息渲染"加载聊天记录中..."（`chatManager.js:606`），内容加两个 thinking 指示类并使用三点位文本动画（`messageRenderer.js:3263-3265`；动画定义见 `styles/messageRenderer.css:111-120`）；

加载完成/失败/中途切换时 removeMessageById('loading_history')（`chatManager.js:608-637`）。

**聊天搜索。** 纯文本"正在努力搜索中..."（`searchManager.js:236`）。

**图片查看器。** 无加载动画，图片默认隐藏，加载完成后才显示并启用工具栏（`image-viewer.html:496`、`image-viewer.js:454-458`）；加载失败时切换错误占位并隐藏工具栏（:578-584）。

**检查范围与结论。** 全仓 `*.css` 检索 loading|spinner|skeleton|骨架|加载中 + `modules/` 下加载逻辑逐一核对。**本次未找到**骨架屏（skeleton）组件；唯一的旋转指示类 `.loading-spinner-small` 在全仓所有 `*.css`（含主题文件）中**无样式定义**，即话题/列表加载期只有文字提示、无可见动画。

**空状态**（补充调查）：

**Agent/群组列表为空。** `<li>没有找到Agent或群组。请创建一个。</li>`（`itemListManager.js:888`）。

**话题列表。** 未选择项目 → "请先在'助手与群组'列表选择一个项目以查看其相关话题。"（`topicListManager.js:527`）；无话题 → "X 还没有任何话题…点击上方的'新建…'按钮创建一个。"（:603）；配置加载失败 → 内联错误文本（:556）。

**聊天区。** 无选中项目 → welcome-bubble"欢迎，请从左侧选择 AI 助手或群组，或创建新的对话。"（`chatManager.js:340`）；有项目无话题 → "请选择或创建一个话题以开始聊天。"（:599）；历史加载失败 → system 消息（:643）。

**聊天搜索。** 输入不足 2 字符提示（`searchManager.js:227`）、无结果"未找到匹配的结果。"（:384）、错误占位（:373）。

**通知侧栏。** `#notificationsList` 为空时无专门占位（`main.html:724` 是空 `<ul>`，notificationRenderer 无空态文案）。表情包空态"没有找到可用的表情包"见第 2 节。

**错误边界**（补充调查）：

**渲染进程。** 在 `renderer.js`、`modules/`、`preload.js` 检索 window.onerror、addEventListener('error')、unhandledrejection——**本次未找到**任何全局错误挂载；DOMContentLoaded 初始化的大 try/catch 只 console.error（`renderer.js:1155-1157`）。

用户可见的错误呈现分散在各业务路径：聊天区 system 消息（`chatManager.js:643`）、列表内联错误占位（`topicListManager.js:556`、`searchManager.js:373`）、showToastNotification(..., 'error')（如 `renderer.js:1519, 1822, 2510`），无统一错误收集或上报。

**主进程。** `main.js:409-411` 监听 webContents 'did-fail-load'、:413-415 监听 render-process-gone，**都只 console.error，无恢复动作或用户提示**；

未发现 uncaughtException、unresponsive、旧版 webContents.on('crashed') 监听（检索 `main.js` 与 `modules/ipc/` 无匹配）。

dialog.showErrorBox 只用于具体功能失败（骰子服务 `modules/ipc/diceHandlers.js:46`、音乐引擎 `musicHandlers.js:71`、图片复制 `fileDialogHandlers.js:296-336`），不是崩溃级兜底。

## 4. 主题、视觉 token 与持久化

主题切换**不是 CSS 变量热替换，而是整窗口重载**：handleApplyTheme（`modules/ipc/themeHandlers.js:93-108`）将选中的主题 CSS 文件（`styles/themes/themesXxx.css`）整体覆写到 `styles/themes.css`，然后重载主窗口和主题窗口（:101、:103），窗口完整重新加载。

- 深色/浅色通过 Electron nativeTheme.themeSource 控制（:22-38），可设 'light'/'dark'/'system'，值存入 `settings.json` 的 currentThemeMode。系统主题跟随通过监听更新事件（:41-44, :207），变更时向所有窗口广播 theme-updated IPC，渲染进程收到后切换 body.light-theme class。
- CSS 变量约定：:root 块定义暗色主题变量，body.light-theme 块覆盖亮色变量；每个主题文件同时包含两个块，themeHandlers.handleGetThemes 可枚举所有主题及其变量名（:50-91）。主题选择器是独立 850×700 无框子窗口（`Themesmodules/themes.html`，frame: false，:169）。
- 默认 `styles/themes.css` 已更换为"纸墨与机芯"（VCP Official，深色 Industrial Core / 浅色 Editorial Ink，提交 ac27171"上架全新 vchat 默认主题（对齐官网配色）"），新增 `--chat-wallpaper-dark/light` 壁纸变量与两张默认壁纸；`styles/themes/` 现有 17 个可选主题文件（含同名 `themes纸墨与机芯.css`）。切换机制（整窗口重载覆写）未变。

**首帧主题应用与防闪烁**（补充调查）：

- `main.html` 的 `<body>`（:31）无预置 class，页面首个样式帧使用 `styles/themes.css` 的 :root 块（暗色默认变量）。

  **主题模式由渲染进程发起同步。** 渲染层先读取 settings.json，再通过 IPC 把模式交给主进程。主进程更新 nativeTheme 并写回设置，系统主题变化后广播给各窗口，渲染层最终切换 body 的 light-theme class。（`themeHandlers.js:22-44`；`uiManager.js:165-209`）
- 因此 body.light-theme 的施加要等"读设置 → IPC → nativeTheme 回环"这一异步往返完成；**light 模式用户首帧先以暗色 :root 渲染一帧再切换**（基于调用链的静态推断，是否肉眼可见取决于往返耗时）。`main.js:420` 注释自述："默认 system，由渲染进程启动时发送已保存偏好"。设置缺失时降级：get-current-theme IPC 查主进程（`uiManager.js:213-221`），最终兜底 'light'（:219, :167-169）。
- 与整窗口重载的关系：主题文件切换（handleApplyTheme）`reload()` 后上述启动链路整体重跑一遍，首帧主题行为与冷启动一致，无内联主题脚本兜底。

**主题选择器窗口与能力边界**（本次主题体系核对）：

- **主题选择器内容**（`Themesmodules/themes.html` + `themes.js` + `themes-module.css`）：入口有主窗口标题栏"主题商店"按钮（`main.html:37-45`）、托盘菜单（`modules/trayManager.js:33`）与 Desktop 窗口（`Desktopmodules/builtinWidgets/vchatApps.js:314`）三处。

  窗口由主题卡片网格、实时预览区和"应用并刷新"按钮组成：卡片是**双栏预览**，左半使用暗色变量和暗色壁纸，右半使用亮色变量和亮色壁纸（关键颜色字段及实现见 `themes.js:74-119`）；下方实时预览区同构模拟侧栏/内容区（:136-219）。**无主题编辑器**：不能编辑颜色、不能新建自定义主题；

  `#saveThemeBtn`（:222-226）实际只是调用 applyTheme IPC 应用选中主题，变量名（"保存主题"）与按钮文案"应用并刷新"存在落差，不能据此理解为保存自定义主题。

**无主题导入/导出。** 检索全仓 `*.js/*.html` 的 `customTheme/importTheme/exportTheme/saveTheme` 与主题 JSON 文件均未找到（saveTheme 仅上述按钮标识符一处）；主题就是 `styles/themes/` 下的 CSS 文件，切换机制即覆写 `themes.css`，无打包、分享、导出主题文件的能力。**本次未找到**自定义主题能力。

**主题文件结构与元数据。** 17 个文件均为纯 CSS 变量文件，实测 17/17 同时含 :root（暗色）与 body.light-theme（亮色）两个变量块；变量分六组：壁纸、基础色（bg/边框/输入框）、文字色、气泡色、UI 元素与语义色（按钮/危险/成功/通知/工具）、滚动条与 shimmer。

**无独立预览图文件**——选择器卡片与预览区的颜色全部取自主题解析结果（`themeHandlers.js:50-91`），壁纸取自 `--chat-wallpaper-*`。主题名元数据为 * Theme Name: 注释（:59），但 17 个文件中仅 3 个（themesEva/夜樱猫语/星渊雪境）声明，其余回退为文件名去掉 themes 前缀。

**壁纸机制边界。** 主窗口**无壁纸管理 UI**——`--chat-wallpaper-dark/light` 随主题文件固定（`themes.css:75-80`、`styles/base.css:29`），壁纸图片打包在 `assets/wallpaper/`（26 个文件），用户不能换图；

主题选择器的壁纸预览经 get-wallpaper-thumbnail IPC（`themeHandlers.js:111-157`）用 sharp（懒加载）生成 400px JPEG 缩略图，缓存于 WallpaperThumbnailCache 目录。

**Desktop 窗口另有独立壁纸系统。** 它支持图片、视频和 HTML 动态壁纸，并可设置透明度、模糊、亮度、静音与播放速度。来源既可以由本地选择，也可以远程下发 URL、file 地址或内联 HTML；这套机制与聊天窗口主题壁纸相互独立。（`Desktopmodules/ui/globalSettings.js:21-31,186`）

**主题模式双 IPC 通道。** 除 set-theme-mode（`themeHandlers.js:22-39`，light/dark/system）外，设置处理器（`modules/ipc/settingsHandlers.js:278-297`）另注册 set-theme（仅 light/dark，成功后手动广播主题更新）；

两条通道都会写 `settings.json` 的 currentThemeMode 与 `themeLastUpdated: Date.now()`（`themeHandlers.js:31`、`settingsHandlers.js:287`），后者为本次核对新确认的持久化字段。

**主题文件可不只是变量。** 默认主题"纸墨与机芯"的 `themes.css` 还携带材质与行为规则（:147-357）：磨砂面板 backdrop-filter、气泡描边/阴影、流式脉冲动画 vcpOperationalPulse/editorialProofPulse、滚动条、:focus-visible 焦点环、prefers-reduced-motion 兜底，并声明 `color-scheme: dark/light`——整窗口重载覆写同样会切换这些规则；

其余 16 个文件以变量为主、偶带少量增强规则（如 themesEva 的磨砂气泡）。即"主题文件"由"变量 + 可选材质/行为规则"组成，非纯 token 文件。

**字号/密度。** 全局设置只有字体族预设（正文/代码/日记/工具四类 + 自定义 font-family，`main.html:998-1099`，含场景预览网格 `#fontScenarioPreviewGrid`），**无字号与界面密度设置**（检索"字号/字体大小/fontSize/density"未找到用户入口）；基础字号固定 `styles/base.css:19`（15px）。

## 5. 响应式、移动端与窗口适配

**侧栏可拖拽宽度**：调整逻辑在 `modules/uiManager.js:48-130`。最小/最大宽度**从 CSS 的 computed.minWidth / computed.maxWidth 动态读取**，代码中仅提供 180px 作为 fallback（左侧栏和右侧通知栏均为 180px，:93, :98），最大宽度 fallback 600px（:57）。拖拽过程中通过 requestAnimationFrame 节流更新，拖拽时禁用元素 transition 以避免卡顿（:88）。

**Compact navigation 触发条件**：不是基于窗口宽度自动触发，而是**由 settings.sidebarAvatarOnly 字段控制**（`renderer.js:1577`）——用户在侧栏宽度设置中主动开启后生效。avatar-only 模式下侧栏折叠为仅显示头像，展示 `.sidebar-compact-navigation` 悬浮菜单。

点击菜单项中的 Topics 触发 leftSidebar.classList.add('compact-topics-open')，话题列表以抽屉形式叠加显示（`uiManager.js:382-386`）；Esc 键关闭抽屉（:451）；点击话题项后自动关闭抽屉（:439-441）。

## 6. 图片、附件、拖放与常见内容交互

图片预览**不是内嵌灯箱，而是打开独立 Electron 子窗口**（`modules/image-viewer.html`）。触发点：`modules/messageRenderer.js:2613` 调用 `electronAPI.openImageViewer({ src, title, theme })`。图片查看器功能远超简单灯箱：

**缩放。** Ctrl+滚轮，范围 0.05×–32×（支持极端缩小看长截图全貌）；Shift+滚轮步长更大（`ZOOM_FACTOR_FAST=1.5` vs `ZOOM_FACTOR_STEP=1.15`，`image-viewer.js:54-56`）。

**拖拽平移。** 缩放非 1× 时鼠标左键拖拽，双击重置到 1×（:450-457）。

**绘图工具。** 选择、画笔、橡皮、取色器、直线、矩形、圆形、箭头，支持颜色和画笔大小；操作历史最多 50 步撤销/重做（:47）。

**OCR。** 按需懒加载本地 `vendor/tesseract.min.js`（:608-635），识别简体中文+英文，结果可复制。

**导出。** 复制到剪贴板（原图+绘图叠合）、下载 PNG。

**GIF 支持。** GIF 以动画形式展示；

未编辑（`historyStep<=0`）的 GIF 可**复制原动画**——Chromium Async Clipboard 不接受 `image/gif`，改经 image-viewer:copy-gif IPC 把原始字节写入 Electron 原生剪贴板（`modules/ipc/windowHandlers.js:155-181`，校验 GIF87a/89a 魔数、100MB 上限，macOS 用 public.gif、其余平台 `image/gif`）；

下载时保 `.gif` 扩展名（getGifDownloadName），PNG 默认名"image.png"时改为带时间戳的 image_YYYYMMDD_HHMMSS.png（getPngDownloadName，`image-viewer.js:165-188`）。

原始字节经 fetch 获取并缓存（getOriginalImageBlob，`image-viewer.js:114-186`），mime 类型以源数据识别为准。
- 右键点击切换工具栏可见性（:409-413）。
- 键盘快捷键（仅查看器窗口内有效）：Esc（切换工具/关闭）；Ctrl+Z/Y（撤销重做）；V/B/E/I/L/R/C/A（切换工具，`image-viewer.js:732-742`）。
- 图片打开时携带当前主题（theme 参数），查看器监听 onThemeUpdated 保持同步（:82-83）。大 dataURL（如阅读模式截图）通过 token 机制传递避开 URL 长度限制（:87-101）。

## 7. 扩展调查：快捷键、动画、桌面集成、设置面板、无障碍

### 键盘快捷键清单

**全局快捷键**（Electron globalShortcut，应用窗口无焦点时也有效）：
- Super+Alt+Z：打开便签（note-mini）窗口（`main.js:1164`）
- Ctrl+Shift+I：打开开发者工具（`main.js:1160`；根据焦点窗口转发到 Loom 或普通开发者工具入口）
- CommandOrControl+Shift+P：划词助手浮窗（动态注册/注销，`modules/ipc/assistantHandlers.js:724`）

**应用内快捷键**（`modules/event-listeners.js:1461-1523`，仅主窗口有焦点时有效）：
- `Ctrl/Cmd+S`：快速保存 Agent 设置（仅设置 tab 激活时，:1462-1468）
- `Ctrl/Cmd+E`：快速导出当前 Topic（:1470-1475）
- `Ctrl/Cmd+D`：AI 续写当前话题（Flowlock 锁定时会弹 toast 阻止，:1477-1491）
- `Ctrl/Cmd+N`：新建话题（已上锁，:1513-1517）
- `Ctrl/Cmd+Shift+N`：新建未上锁话题（:1510-1512）
- Shift+Enter：输入框内换行（非 Shift 的 Enter 直接发送，:443-444）

**设置页面鼠标快捷操作**（`modules/settingsManager.js:604-660`）：
- 设置 tab 内双击右键：跳回助手（Agents）页面（300ms 双击检测）
- 设置 tab 内中键点击：跳转到话题（Topics）页面

### 动画与过渡

全部在 `styles/animations.css` 中定义（由 `style.css` 第 10 行导入）：

**流式输出进行中。** `.message-item.streaming .md-content::after` 用 vcp-border-flow（3s linear infinite）在气泡四周绘制流光边框，背景使用 mask 技巧只显示边框区域不遮挡内容（:123-150）。panel/immersive 模式下改为左侧细轨道 vcp-stream-activity-rail（1.8s ease-in-out，高度收缩脉冲）。

**TTS 朗读中。** 头像微浮动（speaking-avatar-float，3.2s cubic-bezier）+ 旋转光晕边框（speaking-orbit，1.8s linear infinite，conic-gradient + mask 尾迹效果，:263-294）。
- **Avatar 反弹**（avatar-bounce，0.6s）和**徽章出现**（badge-appear，0.4s）在 Flowlock 锁定/解锁时触发。

**已注释的动画。** topic 激活波纹（st-soft-circular-ripple-effect）和数字时钟冒号闪烁（blinkColon）均已注释掉，注释原因为"减少空闲重绘"。

**Presentation mode 切换。** `renderer.js` 的 applyChatPresentationMode 直接替换 body 上的 class，**没有专属过渡动画**，是瞬间切换。布局宽度变化由 CSS transition 属性承接，但 CSS 中是否有对应 transition 声明未逐一确认。

### 桌面集成（Electron）

- **系统托盘**（`main.js:454-555`）：图标 `assets/icon.png`，tooltip "VCP AI 聊天客户端"。右键菜单：显示/隐藏主窗口、显示/隐藏信息流监听器、打开 VCP 桌面、退出。左键点击切换主窗口显隐（若主窗口已销毁则改为切换 RAG 观测窗口）。macOS 特殊处理：左键切换显隐、右键弹菜单、不设 setContextMenu 以避免左键也弹菜单（:541-552）；

  macOS 图标 resize 16×16 并 setTemplateImage(true) 适配深浅色菜单栏（:457-465）。关闭主窗口时若桌面模式（Desktop 窗口）活跃，主窗口隐藏到托盘而非退出（`main.js:376-397`）。
- **语音聊天窗口**（`Voicechatmodules/voicechat.html`，`voicechat.js`）：独立子窗口，初始 `inputMode='text'`，点击切换按钮（toggleInputModeBtn）在文本/语音模式切换（:55, :311-320）。

  语音模式用语音识别（browser speech API 或外部识别器），3 秒无语音超时（`SPEECH_TIMEOUT_DURATION=3000`，:58）。关闭窗口时自动将本次对话历史保存为当前 Agent 的新 Topic（:131-163）并尝试调用话题自动总结。audioContext 在首次用户手势时初始化（:14-23），避免自动播放限制。

**系统通知。** 未在主进程或渲染进程发现 new Notification(...) 或 Electron Notification 类调用——**应用不发送系统桌面通知**，所有 AI 消息通知通过右侧内置通知侧栏和浮动 Toast 呈现。

### 全局设置面板分区

`modules/global-settings-manager.js:38-106` 揭示全局设置面板字段分区：

**用户信息。** 用户名、头像（含裁剪）、头像边框色、名称文字色、是否跟随主题色

**VCP 服务器。** vcpServerUrl（失焦自动补全路径）、vcpApiKey、vcpLogUrl、vcpLogKey、fileKey

**话题总结。** topicSummaryModel（可从模型选择弹窗挑选）

**聊天外观。** Presentation mode 单选、宽布局开关、气泡最大宽度（分默认/通知侧栏打开/窄侧栏等场景）、字体预设（正文/代码/日记/工具四类，支持自定义字体名）

**流式体验。** enableSmoothStreaming、minChunkBufferSize、smoothStreamIntervalMs

**功能开关。** enableAgentBubbleTheme（Agent 自定义气泡主题）、enableAiMessageButtons、enableRegenerateConfirmation

**中键快捷操作。** 启用/禁用、action 类型、高级中键（长按延时）

**语音模式。** local（SoVITS URL/Key）vs network（provider URL/Key），语音识别浏览器路径、识别页面路径

**AI 续写。** 续写 prompt、Flowlock 续写延迟秒数

**助手 Agent。** 划词助手绑定的 Agent 下拉选择

**笔记路径。** 多条网络笔记路径输入

**分布式服务器。** 启用开关
- **Rust 助手**（划词监听）：规则模式（whitelist/blacklist/none）、关键词列表、截图应用列表、自定义阈值

### 无障碍现状（静态代码结论）

**已有 ARIA 标注的区域**：
- Presentation mode 切换器（`main.html:47-53`）：`role="radiogroup"` + `aria-label="聊天显示模式"`，各按钮 `role="radio"` 和 aria-checked
- 侧栏 tabs：`role="tablist"` + `aria-label="Sidebar sections"`，tabpanel 有 aria-hidden
- Compact navigation：`aria-label="窄侧栏导航"`，trigger 按钮有 aria-label，menu 项有 `role="menuitem"`
- 设置区各折叠按钮：有 `aria-label="展开或收起xxx"`（`main.html:239, :374, :394` 等）
- 所有 SVG 图标：普遍标注 `aria-hidden="true"`
- 通知侧栏复制按钮的 SVG：有 `aria-hidden="true"`

**缺失 ARIA 标注的区域**（经代码检查确认未见）：
- Agent 列表 `<li>` 和群组列表 `<li>`：无 aria-label，无 role
- Topic 列表 `<li>`：无 aria-label
- 消息列表 `.message-item`：无 `role="listitem"` 或 aria-label
- 发送按钮在"中止回复"模式下动态替换 SVG，但 data-mode 切换未见对应 aria-label 更新

**焦点管理**：确认对话框打开时确认按钮自动聚焦，通用 Modal 打开时也会聚焦自身（相关实现见 :347、:944），但无 focus trap，Tab 键可以穿透到背景。Agent/Topic 列表没有键盘导航支持，列表项无 tabindex。

总体评估：核心功能控件有基础 ARIA，但主要内容区（消息列表、Agent/Topic 列表）缺乏语义标注，键盘可达性不完整，无障碍支持处于初步阶段。

## 8. 设计取舍与已确认边界

**主题切换整窗口重载。** 覆写 `themes.css` + `reload()`，代价是切换时窗口完整刷新（可能出现短暂空白），换取"完全干净的样式应用"。

**无系统桌面通知。** 所有通知走应用内浮动 Toast 与侧栏，后台时不会主动提示生成完成。

**图片预览独立子窗口。** 带完整绘图/OCR 能力，代价是打开独立进程窗口开销大；与聊天主窗口通过 IPC 传 dataURL（token 机制避开 URL 长度限制）。

**无焦点陷阱。** 通用 Modal 与确认对话框均无 focus trap，Tab 可穿透到背景。

**表情包插入原始 `<img>` HTML。** 不是转义后的 Markdown 语法。
- **Compact 导航由设置驱动**而非断点自动触发；侧栏宽度从 CSS computed 值动态读取而非代码硬编码。

**主题仅能整包更换。** 无主题编辑器与导入/导出，自定义主题需手工编写或替换 `styles/themes/` 下的 CSS 文件；主窗口壁纸与主题绑定、无独立壁纸管理（Desktop 窗口壁纸系统独立于主题壁纸，支持视频/HTML 动态壁纸与远程下发）。

## 9. 未验证事项

- 无障碍结论基于静态代码检查，未做屏幕阅读器实测。
- 头像裁剪器与表情包选择器的触屏/触摸板体验未运行验证。
- 主题整窗口重载的白屏表现、Presentation mode 切换的 CSS transition 是否实际存在未逐一确认。
- OCR（Tesseract.js 懒加载）在复杂图片上的识别效果未实测。
- macOS 托盘与语音窗口的实机行为未验证（代码路径已读，平台行为需运行验证）。
- 首帧主题：light 模式启动时先以暗色 :root 渲染一帧再切亮色（基于调用链静态推断），实际闪烁表现未运行验证。
- `.loading-spinner-small` 无任何 CSS 定义，话题/Agent 列表加载期实际只有文字、无旋转动画——该视觉表现未运行确认，也不排除有动态注入样式覆盖。
- 渲染进程崩溃（render-process-gone）与主窗口加载失败（did-fail-load）只打日志、无恢复 UI，崩溃后的实际行为（白屏、能否重启）未实测。
- 主题选择器卡片/预览区的双栏配色与壁纸缩略图（sharp 生成、WallpaperThumbnailCache 缓存命中）的实际渲染表现未运行验证；Desktop 窗口壁纸系统（视频/HTML 动态壁纸、远程下发 desktop-remote-set-wallpaper）的实机表现未验证。

## 10. 关键源码索引

- `modules/ui-helpers.js`（323-360 openModal）
- `modules/notificationRenderer.js`
- `modules/ipc/themeHandlers.js`（22-39 set-theme-mode）
- `modules/ipc/settingsHandlers.js`（278-297 set-theme 通道）
- `Themesmodules/themes.html` / `themes.js`（双栏预览卡片与"应用并刷新"）
- `styles/themes.css`（变量 + 材质/行为规则）
- `styles/base.css`（19 基础字号）
- `styles/animations.css`
- `modules/image-viewer.html` / `modules/ipc/windowHandlers.js`（155-181 copy-gif）
- `modules/emoticonManager.js`
