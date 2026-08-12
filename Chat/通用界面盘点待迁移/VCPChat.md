# VCPChat 通用界面盘点（待迁移承接）

> 来源：`../Chat/VCPChat-Chat调查笔记.md` 第 13 节（原文完整搬运）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支：`main`）
>
> 摘出日期：2026-08-11

## 13. UI 交互再深挖：弹窗、状态反馈与无障碍

### 13.1 弹窗/对话框机制

VCPChat **没有使用任何第三方 Modal 库**，全部自定义实现，有两套分支：

**通用 Modal（`uiHelperFunctions.openModal/closeModal`，`modules/ui-helpers.js:323-360`）**：给目标元素加/移除 `active` class。为节省首屏 DOM，Modal 元素采用 `<template>` 懒加载模式——打开时如果 `document.getElementById(modalId)` 不存在，会从同名 `<template id="...Template">` 克隆到 `#modal-container`，然后派发 `modal-ready` 自定义事件（`:339`）通知各模块绑定事件监听器。模型选择弹窗（`modelSelectModal`）、正则规则弹窗（`regexRuleModal`）和全局设置弹窗（`globalSettingsModal`）均走此路径。打开时调用 `modalElement.focus()`（`:347`），但**没有焦点陷阱（focus trap）**，Tab 键可以离开 Modal 到达背景元素。Esc/遮罩点击关闭需各 Modal 自行绑定（`regexRuleModal` 绑定了遮罩点击，`:736-739`；全局设置弹窗未见 Esc 监听）。

**确认对话框（`uiHelperFunctions.showConfirmDialog`，`modules/ui-helpers.js:889-977`）**：返回 `Promise<boolean>`，用于删除 Agent/群组、删除正则规则等危险操作。动态创建 `.confirm-dialog-overlay` 并附到 `document.body`，`requestAnimationFrame` 后加 `visible` class 触发 CSS 进场动画，确认按钮自动 `focus()`（`:944`）。支持：Esc 取消（`:948`）、Enter 确认（`:951`）、点击遮罩取消（`:959-963`）。`isDanger=true` 时确认按钮加 `danger` class（红色）。关闭时移除 `visible` class，200ms 后从 DOM 移除（`:969-974`）。

**头像裁剪器（`avatarCropperModal`）**：Canvas 实现，支持拖拽移动圆形裁剪框和滚轮缩放（半径范围 30-100px），`modules/ui-helpers.js:460-626`。裁剪完成后用 `canvas.toBlob` 生成 PNG 文件，通过回调传出；事件监听器在关闭时逐一 `removeEventListener` 清理（`:601-608`）。

### 13.2 Toast 与通知侧栏

全部自定义，无系统 `Notification` API 调用，无 Toast 第三方库。有两套并行展示机制（`modules/notificationRenderer.js`）：

**浮动 Toast（`#floating-toast-notifications-container`）**：
- `prepend` 插入，新 toast 在最上方叠加，无数量上限（会随时间自动消失）。
- 默认 **7 秒**自动消失（`:460`）；`tool_approval_request` 类型**永不自动消失**（`:463-465`），须用户点击允许/拒绝后才消失；支持通过过滤规则配置 `duration`（毫秒），`duration=0` 也表示永久（`:467-469`）。
- 点击 toast 本体立即手动关闭（审核类通知例外，`:340-342`）。
- 关闭动画：加 `exiting` class → 监听 `transitionend` 移除 DOM，500ms fallback 强制移除（`:399-413`）。
- 当通知侧栏（`#notificationsSidebar`）处于 `active` 状态时，**抑制浮动 toast**，直接写入侧栏列表（`:449`）。
- 窗口获焦时清理已加 `exiting` 且超过 10 秒的残留 toast（`:517-547`）；每 30 秒定时清理超 15 秒的 toast（`:552-571`）。

**持久侧栏列表**：`<li>` prepend 到 `#notificationsList`，点击淡出 + 右滑消失（`:387-394`），copy 按钮复制原始 JSON；tool_approval_request 项展示允许/拒绝按钮和可选理由文本框（`:278-330`）。

`uiHelperFunctions.showToastNotification`（`modules/ui-helpers.js:367-415`）是面向应用内部的简化版 Toast，支持 `type`（`info/success/error/warning`）和自定义 `duration`（默认 3000ms），写法与上面相同。

### 13.3 主题切换机制

主题切换**不是 CSS 变量热替换**，而是**整窗口重载**：`handleApplyTheme`（`modules/ipc/themeHandlers.js:93-108`）将选中的主题 CSS 文件（`styles/themes/themesXxx.css`）整体覆写到 `styles/themes.css`，然后调用 `mainWindow.reload()`（`:101`）和 `themesWindow.reload()`（`:103`），窗口完整重新加载。

深色/浅色模式通过 Electron `nativeTheme.themeSource` 控制（`:22-38`），可设置 `'light'`、`'dark'` 或 `'system'`，值存入 `settings.json` 的 `currentThemeMode` 字段。系统主题跟随通过监听 `nativeTheme.on('updated')` 实现（`:41-44`, `:207`），变更时向所有窗口广播 `theme-updated` IPC 消息，渲染进程收到后切换 `body.light-theme` class。

CSS 变量约定：`:root` 块定义暗色主题变量，`body.light-theme` 块覆盖亮色变量；每个主题文件同时包含两个块，通过 `themeHandlers.handleGetThemes` 可枚举所有主题及其变量名（`:50-91`）。主题选择器是一个独立的 850×700 无框子窗口（`Themesmodules/themes.html`，`frame: false`，`:169`）。

默认 `styles/themes.css` 已更换为"纸墨与机器芯"（VCP Official，深色 Industrial Core / 浅色 Editorial Ink，提交 `ac27171`"上架全新 vchat 默认主题（对齐官网配色）"），新增 `--chat-wallpaper-dark/light` 壁纸变量与 `assets/wallpaper/vcp_industrial_core_dark.jpg`、`vcp_editorial_ink_light.jpg` 两张默认壁纸；`styles/themes/` 现有 17 个可选主题文件（含同名 `themes纸墨与机器芯.css`）。切换机制（整窗口重载覆写）未变。

### 13.4 图片/附件预览——独立窗口而非灯箱

VCPChat 的图片预览**不是内嵌灯箱**，而是打开一个独立 Electron 子窗口（`modules/image-viewer.html`）。触发点：`modules/messageRenderer.js:2613` 调用 `electronAPI.openImageViewer({ src, title, theme })`。

图片查看器功能远超简单灯箱：
- **缩放**：Ctrl+滚轮，范围 `0.05×–32×`（支持极端缩小看长截图全貌）；Shift+滚轮步长更大（`ZOOM_FACTOR_FAST=1.5` vs `ZOOM_FACTOR_STEP=1.15`，`image-viewer.js:54-56`）。
- **拖拽平移**：缩放非 1× 时鼠标左键拖拽；双击重置到 1×（`:450-457`）。
- **绘图工具**：选择、画笔、橡皮、取色器、直线、矩形、圆形、箭头，支持颜色和画笔大小；操作历史最多 50 步撤销/重做（`:47`）。
- **OCR**：按需懒加载本地 `vendor/tesseract.min.js`（`:608-635`），识别简体中文+英文，结果可复制。
- **导出**：复制到剪贴板（原图+绘图叠合）、下载 PNG。
- **GIF 支持**：GIF 图片以动画形式展示；未编辑（`historyStep<=0`）的 GIF 可**复制原动画**——Chromium Async Clipboard 不接受 `image/gif`，改经 `image-viewer:copy-gif` IPC 把原始字节写入 Electron 原生剪贴板（`modules/ipc/windowHandlers.js:155-181`，校验 GIF87a/89a 魔数、100MB 上限，macOS 用 `public.gif`、其余平台 `image/gif`）；下载时保 `.gif` 扩展名（`getGifDownloadName`），PNG 默认名"image.png"时改为带时间戳的 `image_YYYYMMDD_HHMMSS.png`（`getPngDownloadName`，`image-viewer.js:165-188`）。原始字节经 `fetch(resolvedImageSrc)` 获取并缓存（`getOriginalImageBlob`，`image-viewer.js:114-186`），mime 类型以源数据识别为准。
- 右键点击切换工具栏可见性（`:409-413`）。
- 键盘快捷键（仅在查看器窗口内有效）：Esc（切换工具/关闭）；Ctrl+Z/Y（撤销重做）；V/B/E/I/L/R/C/A（切换工具，`image-viewer.js:732-742`）。

图片打开时携带当前主题（`theme` 参数），查看器也监听 `onThemeUpdated` 事件保持同步（`:82-83`）。大 dataURL（如阅读模式截图）通过 token 机制传递避开 URL 长度限制（`:87-101`）。

### 13.5 表情包选择器

`modules/emoticonManager.js`：从服务端 API `getEmoticonLibrary()` 加载表情库，**只筛选当前用户对应的分类**（`"通用表情包"` + `"${userName}表情包"` 两个分类，`:53-59`）。

UI：**平铺图片网格**，没有搜索框，没有分类切换，没有分页（`:85-99`）。面板固定尺寸 270×240px，出现在按钮上方（`:158-165`）；若上方空间不足则移到按钮下方（`:161-163`）。点击面板外部关闭（100ms 延迟绑定，避免立即触发，`:107`）。

点击表情包将 `<img src="..." width="80">` HTML 标签插入到 `textarea.value`（`:131-135`），不是转义后的 Markdown 语法。面板无加载动画——若表情库为空，格内显示"没有找到可用的表情包"占位文字（`:89-90`）。

### 13.6 键盘快捷键清单

**全局快捷键**（Electron `globalShortcut`，应用窗口无焦点时也有效）：
- `Super+Alt+Z`：打开便签（note-mini）窗口（`main.js:1164`）
- `Ctrl+Shift+I`：打开开发者工具（`main.js:1160`；经 `toggleDevToolsForWindow` 转发——若焦点窗口是 Loom 运行窗口则交 `loomManager.toggleDevToolsForWindow` 处理，否则走普通 `webContents.toggleDevTools()`）
- `CommandOrControl+Shift+P`：划词助手浮窗（动态注册/注销，`modules/ipc/assistantHandlers.js:724`）

**应用内快捷键**（`modules/event-listeners.js:1461-1523`，仅在主窗口有焦点时有效）：
- `Ctrl/Cmd+S`：快速保存 Agent 设置（仅当设置 tab 激活时，`:1462-1468`）
- `Ctrl/Cmd+E`：快速导出当前 Topic（`:1470-1475`）
- `Ctrl/Cmd+D`：AI 续写当前话题（Flowlock 锁定时会弹 toast 阻止，`:1477-1491`）
- `Ctrl/Cmd+N`：新建话题（已上锁，`:1513-1517`）
- `Ctrl/Cmd+Shift+N`：新建未上锁话题（`:1510-1512`）
- `Shift+Enter`：输入框内换行（非 Shift 的 Enter 直接发送，`:443-444`）

**设置页面鼠标快捷操作**（`modules/settingsManager.js:604-660`）：
- 设置 tab 内双击右键：跳回助手（Agents）页面（300ms 双击检测）
- 设置 tab 内中键点击：跳转到话题（Topics）页面

### 13.7 动画与过渡效果

全部在 `styles/animations.css` 中定义（`style.css` 第 10 行 `@import`）：

**流式输出进行中**：`.message-item.streaming .md-content::after` 用 `vcp-border-flow`（3s linear infinite）在气泡四周绘制流光边框，背景使用 mask 技巧只显示边框区域不遮挡内容（`:123-150`）。在 panel/immersive 模式下改为左侧细轨道 `vcp-stream-activity-rail`（1.8s ease-in-out，高度收缩脉冲）。

**TTS 朗读中**：头像微浮动（`speaking-avatar-float`，3.2s cubic-bezier）+ 旋转光晕边框（`speaking-orbit`，1.8s linear infinite，利用 conic-gradient + mask 实现尾迹效果，`:263-294`）。

**Avatar 反弹**（`avatar-bounce`，0.6s）和**徽章出现**（`badge-appear`，0.4s）在 Flowlock 锁定/解锁时触发。

**已注释的动画**：topic 激活波纹（`st-soft-circular-ripple-effect`）和数字时钟冒号闪烁（`blinkColon`）均已注释掉，注释原因为"减少空闲重绘"。

**Presentation mode 切换**：`renderer.js` 的 `applyChatPresentationMode` 直接替换 `body` 上的 class，**没有专属过渡动画**，是瞬间切换。布局宽度变化由 CSS `transition` 属性承接，但 CSS 中是否有对应 transition 声明未在此次调查中逐一确认。

### 13.8 桌面集成（Electron）

**系统托盘**（`main.js:454-555`）：图标为 `assets/icon.png`，tooltip "VCP AI 聊天客户端"。右键菜单包含：显示/隐藏主窗口、显示/隐藏信息流监听器、打开 VCP 桌面、退出。左键点击切换主窗口显隐（若主窗口已销毁则改为切换 RAG 观测窗口）。macOS 特殊处理：左键切换显隐，右键弹出菜单，不设置 `setContextMenu` 以避免左键也弹菜单（`:541-552`）；macOS 图标 resize 为 16×16 并 `setTemplateImage(true)` 适配深浅色菜单栏（`:457-465`）。关闭主窗口时若桌面模式（Desktop 窗口）处于活跃状态，主窗口隐藏到托盘而非退出（`main.js:376-397`）。

**全局快捷键**：见 13.6 节。

**语音聊天窗口**（`Voicechatmodules/voicechat.html`，`voicechat.js`）：独立子窗口，初始 `inputMode='text'`，点击切换按钮（`toggleInputModeBtn`）在文本模式和语音模式之间切换（`:55`, `:311-320`）。语音模式使用语音识别（browser speech API 或外部识别器），有 3 秒无语音超时（`SPEECH_TIMEOUT_DURATION=3000`，`:58`）。关闭窗口时自动将本次对话历史保存为当前 Agent 的一个新 Topic（`:131-163`），并尝试调用话题自动总结。audioContext 在首次用户手势时初始化（`:14-23`），避免浏览器自动播放限制。

**系统通知**：未在主进程或渲染进程中发现 `new Notification(...)` 或 Electron `Notification` 类调用——应用**不发送系统桌面通知**，所有 AI 消息通知通过右侧内置通知侧栏和浮动 Toast 呈现。

### 13.9 侧栏宽度与 Compact 导航

**侧栏可拖拽宽度**：调整逻辑在 `modules/uiManager.js:48-130`。最小/最大宽度**从 CSS 的 `computed.minWidth` / `computed.maxWidth` 动态读取**，代码中仅提供 180px 作为 fallback（左侧栏和右侧通知栏均为 180px，`:93`, `:98`），最大宽度 fallback 600px（`:57`）。拖拽过程中通过 `requestAnimationFrame` 节流更新，拖拽时禁用元素 `transition` 以避免卡顿（`:88`）。

**Compact navigation 触发条件**：不是基于窗口宽度自动触发，而是**由 `settings.sidebarAvatarOnly` 字段控制**（`renderer.js:1577`）——用户在侧栏宽度设置中主动开启后生效。avatar-only 模式下侧栏折叠为仅显示头像，展示 `.sidebar-compact-navigation` 悬浮菜单。点击菜单项中的 Topics 触发 `leftSidebar.classList.add('compact-topics-open')`，话题列表以抽屉形式叠加显示（`uiManager.js:382-386`）；Esc 键关闭抽屉（`:451`）；点击话题项后自动关闭抽屉（`:439-441`）。

### 13.10 全局设置面板分区

`modules/global-settings-manager.js` 的 `handleSaveGlobalSettings` 函数（`:38-106`）揭示全局设置面板涵盖以下字段分区：

- **用户信息**：用户名、头像（含裁剪）、头像边框色、名称文字色、是否跟随主题色
- **VCP 服务器**：`vcpServerUrl`（失焦自动补全路径）、`vcpApiKey`、`vcpLogUrl`、`vcpLogKey`、`fileKey`
- **话题总结**：`topicSummaryModel`（可从模型选择弹窗挑选）
- **聊天外观**：Presentation mode 单选、宽布局开关、气泡最大宽度（分默认/通知侧栏打开/窄侧栏等场景）、字体预设（正文/代码/日记/工具四类，支持自定义字体名）
- **流式体验**：`enableSmoothStreaming`、`minChunkBufferSize`、`smoothStreamIntervalMs`
- **功能开关**：`enableAgentBubbleTheme`（Agent 自定义气泡主题）、`enableAiMessageButtons`、`enableRegenerateConfirmation`
- **中键快捷操作**：启用/禁用、action 类型、高级中键（长按延时）
- **语音模式**：local（SoVITS URL/Key）vs network（provider URL/Key），语音识别浏览器路径、识别页面路径
- **AI 续写**：续写 prompt、Flowlock 续写延迟秒数
- **助手 Agent**：划词助手绑定的 Agent 下拉选择
- **笔记路径**：多条网络笔记路径输入
- **分布式服务器**：启用开关
- **Rust 助手**（划词监听）：规则模式（whitelist/blacklist/none）、关键词列表、截图应用列表、自定义阈值

### 13.11 无障碍现状（如实记录）

**已有 ARIA 标注的区域**：
- Presentation mode 切换器（`main.html:47-53`）：`role="radiogroup"` + `aria-label="聊天显示模式"`，各按钮有 `role="radio"` 和 `aria-checked`
- 侧栏 tabs：`role="tablist"` + `aria-label="Sidebar sections"`，tabpanel 有 `aria-hidden`
- Compact navigation：`aria-label="窄侧栏导航"`，trigger 按钮有 `aria-label`，menu 项有 `role="menuitem"`
- 设置区各折叠按钮：有 `aria-label="展开或收起xxx"` （`main.html:239`, `:374`, `:394` 等）
- 所有 SVG 图标：普遍标注 `aria-hidden="true"`
- 通知侧栏复制按钮的 SVG：有 `aria-hidden="true"`

**缺失 ARIA 标注的区域**（经代码检查确认未见）：
- Agent 列表 `<li>` 和群组列表 `<li>`：无 `aria-label`，无 `role`
- Topic 列表 `<li>`：无 `aria-label`
- 消息列表 `.message-item`：无 `role="listitem"` 或 `aria-label`
- 发送按钮在"中止回复"模式下动态替换 SVG，但 `data-mode` 切换未见对应 `aria-label` 更新

**焦点管理**：确认对话框打开时确认按钮自动 `focus()`（`:944`）；通用 Modal 打开时调用 `modalElement.focus()`（`:347`），但无 focus trap——Tab 键可以穿透到背景。无键盘导航在 Agent/Topic 列表中的支持（列表项无 `tabindex`）。

总体评估：核心功能控件有基础 ARIA，但主要内容区（消息列表、Agent/Topic 列表）缺乏语义标注，键盘可达性不完整，无障碍支持处于初步阶段。
