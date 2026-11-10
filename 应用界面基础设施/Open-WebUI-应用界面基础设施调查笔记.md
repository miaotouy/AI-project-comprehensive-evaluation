# Open WebUI 应用界面基础设施调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 是关闭 SSR 的 SvelteKit SPA，公共界面组件主要由项目自研。Modal 负责 Portal、焦点陷阱、Esc、遮罩和滚动锁定，ConfirmDialog、Drawer 与 Dropdown 则有各自实现；全应用没有自绘右键菜单。

Toast 统一使用 svelte-sonner，并在根布局挂载唯一 Toaster。聊天完成等站内通知会渲染自定义 Toast，同时还能通过浏览器 Notification 和 webhook 发送到外部渠道。

主题以设备本地的 localStorage 为权威，内联脚本在首屏应用 light、dark、system 或 OLED 模式。聊天背景图却属于账户设置，按文件夹、用户和许可配置决定优先级。项目没有主题市场、主题导入导出、用户强调色或字体选择；自定义 CSS 只保留部署级入口。

## 系统边界与总体装配

**界面栈。** SvelteKit 2 + Svelte 5（package.json 第 44 行为 ^5.53.10），但组件主体仍是旧式反应式写法（`$:`、onMount、createEventDispatcher），runes（`$state`/`$derived`）仅在 common/CodeEditorModal.svelte 第 19-20 行和 admin/Analytics/ChartLine.svelte 第 14-23 行出现；

Tailwind CSS v4（src/tailwind.css 第 1 行，@theme 只扩展 gray 色阶第 6-18 行，tailwind.config.js 第 6 行将 darkMode 设为 class）；

无 UI 组件库，公共层在 common 目录（68 个文件，含 Modal、ConfirmDialog、Drawer、Dropdown、Tooltip、Spinner、Loader、Image、ImagePreview、Switch、Checkbox、Select、Pagination、PanzoomContainer、PDFViewer 等）。

**构建与运行边界。** svelte.config.js 第 15-19 行使用 adapter-static 和 index.html fallback，根布局第 10 行关闭 SSR，因而是纯 SPA；

svelte.config.js 第 20-39 行把 SvelteKit 的版本变化检测设为每 60 秒轮询一次；版本号一变，根布局就在 beforeNavigate 里注销 service worker，再用 location.href 强制刷新整页（第 104 行）。
- **根装配**（src/routes/+layout.svelte，1535 行）：
  - Toast Host：`<Toaster>`（svelte-sonner，位置为 top-right，启用 richColors 和 closeButton，主题随 `$theme` 计算）；
  - 社区统计弹窗 `<SyncStatsModal>`（import 于第 80 行，挂在根布局而非 app 布局）；Electron 壳侧栏组件已从仓库移除，桌面模式只保留 `isApp` 置位与事件通道；
  - 全局服务：Socket.IO 连接后由 `chatEventHandler` 与 `channelEventHandler` 分发事件，`desktopEventHandler` 接收桌面壳事件，三者的注册点散布在根布局第 122-1289 行；另有会话过期自动登出（fetch 401 拦截加定时 token 检查）、BroadcastChannel 活跃标签页仲裁与移动端下拉刷新手势；
  - splash 屏移除（:1232-1260）与 her 主题彩蛋进度条。
- **(app) 布局**（src/routes/(app)/+layout.svelte，556 行）：装配 Sidebar、SettingsModal、ChangelogModal、AccountPending 和 UpdateInfoToast，并负责全局快捷键分发与 `?settings=` URL 深链（`openSettingsFromUrl`）。

**多入口。** 首页 `/` 与会话页 `/c/[id]` 都只用一行 Chat 组件装配（`(app)/+page.svelte:15`）。登录注册页负责登录、注册与 SSO 自动跳转，并带 OnBoarding 欢迎页（`auth/+page.svelte:178-217`）；分享会话页 /s/[id] 自行加载用户设置；/watch 只做 YouTube 跳转；/error 是后端缺失时的落地页。这些入口共用同一套根布局基础设施：Toaster、Socket.IO 连接与主题应用。
- 桌面壳（Electron 原生应用在独立仓库，见仓库分布笔记）只在需要时经 window.electronAPI 与 window.applyTheme 两个全局钩子接入。本仓既无实现也无类型声明，`src/app.d.ts` 为空，所有调用处都先做存在性检查；其中 window.applyTheme 在本仓只有调用点，没有定义（`+layout.svelte:507-1073`、`General.svelte:177`）。

## 1. 界面栈、公共组件与状态所有权

**公共组件层。** common 目录是唯一的跨页公共组件目录。使用面最大的是 toast 与 Tooltip（各 100 个以上文件），其次是 Modal（60 个文件）和 ConfirmDialog（26 个文件）；以上为对 src/lib 中 import 语句的 Grep 统计，相对路径变体可能低估。业务侧弹窗入口（ShareChatModal、TagChatModal、ToolServersModal 等）只记录底层机制，入口语义归 Chat UI 等业务类目。
- **依赖使用证据**（依赖清单之外逐一在源码找到 import）：
  - svelte-sonner：根布局 Toaster + 100+ 文件 toast.*（见第 3 节）；
  - focus-trap：`Modal.svelte:6`、`ConfirmDialog.svelte:5`；
  - `tippy.js`：`common/Tooltip.svelte:6-10`；
  - sortablejs：侧栏、置顶模型和笔记、模型管理及横幅管理等入口均有 import（拖拽排序）；
  - bits-ui：`common/Switch.svelte:2`、`common/Pagination.svelte:2`、LinkPreview（`Sidebar/ChatHoverPreview.svelte:3` 等 5 处）；
  - paneforge：聊天、频道、笔记和知识库等入口均有 import（面板拖拽分栏）；
  - panzoom：`common/PanzoomContainer.svelte:3`；`@sveltejs/svelte-virtual-list`：`common/EmojiPicker.svelte:2`；svelte-confetti：`chat/Settings/SyncStatsModal.svelte:2`；
  - alpinejs 在 package.json 第 90 行列为依赖，但 src 全目录搜索 import 语句无匹配，本次未找到任何接入点。
- **状态所有权**（src/lib/stores/index.ts）：模块级 writable store 单例约 60 个，分三类：
  1. 后端数据投影：config/user/models/tools/knowledge/tags/banners/channels（服务端 API 拉取后写入）；
  2. 应用 UI 状态：showSidebar/showSearch/showSettings（可接受 boolean | string | SettingsModalRequest，:120）/showChangelog/showControls/showOverview/showFileNav/showCallOverlay/mobile/temporaryChatEnabled 等——这些是跨页面共享的浮层/面板开关，业务组件 bind:show 消费；
  3. 用户偏好：settings store（服务端权威，见第 4 节）+ theme store（:36，仅镜像 localStorage）。
  - 界面偏好分散存在 localStorage 里，共 8 个键：主题、侧栏宽度、显示控件开关等。其中前三项的写入点分布在 app 布局第 399-402 行与 ChatControls 第 163-412 行，侧栏宽度另在侧栏第 625-645 行同步写 `--sidebar-width` CSS 变量；终端选择与相邻处理共用 ChatControls 同一段范围。
  - 跨窗口同步：多标签页只经 BroadcastChannel 仲裁“最后活跃标签页”（根布局第 1076-1095 行），其余本地 store（队列、草稿、侧栏状态）不跨窗口同步（Chat UI 笔记第 8 节同述）。

## 2. 弹窗、浮层与菜单

### Modal（自研，应用主弹窗机制）

common/Modal.svelte（160 行），60 个消费文件：

**Portal。** `$:` 块中 document.body.appendChild(modalElement)（:61-103），挂到 body 顶层；

**层级。** 无 z-index 栈管理，所有 modal 容器都带 modal class；Esc 关闭前由 isTopModal 检查自己是否为 document.getElementsByClassName('modal') 中最后一个（第 49-52 行），即“最后挂载的最上层才响应 Esc”。Drawer 和 ImagePreview 也参与同一判定（容器类见第 124 行）。

**Esc/遮罩。** window keydown + isTopModal（:42-47）；遮罩 on:mousedown 关闭、内容区 stopPropagation（:127-138）；

**滚动锁定。** 打开 `document.body.style.overflow = 'hidden'`，关闭直接 'unset'（:88,102）——无共享计数器（见设计取舍节）；

**焦点管理。** 使用 focus-trap 的 createFocusTrap，allowOutsideClick 放行 sonner toast 与名义上的 modal-content（第 63-70 行；该 class 在模板中并不存在，仅是样式残留，静态推断该分支实际对所有 modal 外点击生效）；另注册 pointerdown/focusin 对陷阱做 pause/unpause（第 74-85 行），注释说明是为 Portal 化的 Dropdown 等浮层准备的；

**尺寸。** size prop 映射 xs(16rem)~3xl(100rem) 固定宽度（:19-40），full 为全宽；
- 关闭后焦点归还：源码中未找到显式 focus 恢复逻辑，focus-trap 的 deactivate 归还行为属库内部，未运行验证。

### ConfirmDialog（独立实现，确认弹窗）

common/ConfirmDialog.svelte，26 个消费文件，不基于 Modal：

- 自己的 Portal + focus-trap（默认配置，:84-85）+ Esc 取消（:47-50）+ Enter 确认（:52-62，焦点在 a/button/textarea 内时让位）+ 遮罩 on:mousedown 取消；
- 支持输入框（text/password/select）与消息 Markdown（DOMPurify.sanitize(marked.parse(...))，:145）；
- 与 Modal 的差异：aria-label 兜底文案（:125）、无 modal class（不参与 isTopModal 判定——静态推断：ConfirmDialog 的 Esc 始终生效，即使叠在其他 modal 之上）、z-index 更高（z-99999999，:116）。

### Drawer

common/Drawer.svelte：底部滑出抽屉（fly 过渡），带 modal class 参与 Esc 层级，遮罩 mousedown 关闭，**没有焦点陷阱**（与 Modal/ConfirmDialog 不同）；相关实现见第 13-23、62-64 行，关闭时触发 onClose。

### Dropdown（自研 popover）

common/Dropdown.svelte（359 行）：

- Portal + position: fixed 定位，自实现 auto-flip（空间不足自动翻转 top/bottom，:111-158）与视口边缘修正；
- visualViewportAware 模式针对移动端软键盘：按 window.visualViewport 计算、动态 clamp 高度（:160-204），并订阅 viewport resize/scroll 重定位；
- ResizeObserver 防溢出重定位（:49-54）；Esc 关闭（:292-296）、外部 pointerdown 关闭（:284-290）；
- 焦点：打开时可选把焦点移入内容（shouldFocusContent），关闭时若焦点在内容内则归还触发元素（:259-269）；
- 语义：菜单本体使用 role="menu"，触发区使用 role="button"、aria-haspopup 和 aria-expanded（第 333-341 行）。
- 配套：DropdownMenu/DropdownOptions/DropdownSub 是纯样式容器（无定位/焦点逻辑）。

### Tooltip

`common/Tooltip.svelte`：tippy.js 封装，内容过 DOMPurify（:44），默认 theme: 'dark'、arrow: false，支持 interactive（:56-66）；tippy 的焦点/读屏默认行为未核实。消费面 100+ 文件。

### 右键菜单

消息与侧栏项的操作仍走普通按钮、Dropdown 或 Modal，没有全局自绘右键菜单。contextmenu 事件只在少数内嵌表面出现，用途是屏蔽浏览器默认菜单：内置浏览器与外部桌面画面、终端文件面板与语音头像各有一处（`ChatTabs/ChromeBrowser.svelte:260`、`FileNav.svelte:2387`，其余入口见第 10 节）。

## 3. 通知、加载态与错误反馈

### Toast（svelte-sonner，唯一 Host）

- 装配：根布局 `<Toaster>`（根布局第 1341-1358 行），位置为 top-right，启用 richColors 和 closeButton；theme 属性由 `$theme` 推导（dark/system/light），toastOptions.classes.closeButton 覆写深色样式；
- 消费：Grep 显示 100+ 文件直接引入 svelte-sonner 的 toast，错误路径几乎统一调用 error 方法（如 Sidebar 第 868 行、SearchModal 第 80 行）；
- 堆叠/动画/更新/取消等具体行为是 svelte-sonner 内部实现，本次未下钻。

### 站内通知 toast（自研 NotificationToast）

- `NotificationToast.svelte` 负责站内通知卡片：它通过 toast.custom 渲染带 role="status" 与 aria-live="polite" 的提示，点击跳转前先看指针是否拖动超过 6px，超过按拖拽处理，悬停时露出关闭按钮，Enter/空格可键盘激活（`NotificationToast.svelte:31-99`）。
- 三个触发点都在根布局的事件处理器里：聊天完成停留 15 秒，频道消息与日历提醒停留 30 秒，对应的三个分支集中在根布局第 529-802 行。
- 通知同时旁路到浏览器 Notification API 与通知音：前者受 settings.notificationEnabled 和 `$isLastActiveTab` 门控，后者由 playingNotificationSound store 配合音频文件播放（根布局第 664-683 行）。`NotificationToast.svelte` 自身也有一段声音逻辑，受 navigator.userActivation 门控（第 66-82 行）。
- 通知设置界面：chat/Settings/Notifications.svelte 请求通知权限，并提供 webhook targets 的增删改查和测试；权限与功能开关门控分别见第 49-75 行。

  服务端通道：backend/open_webui/events.py 第 161-212 行定义 CHAT_FINISHED、CHAT_FAILED 等事件，第 651-666 行定义通知事件集；webhook 目标订阅这些事件（通知事件的具体派发链本次未追查）。
- 连接状态反馈：Socket.IO 断开延迟 2s 弹 warning toast，页面不可见或刚恢复时再宽限 8s，重连成功弹 success；相关逻辑集中在根布局第 146-194、251-262 行。

### Loading / 骨架 / 空状态

- `Spinner.svelte`：内联 SVG 旋转（0.75s 线性），全站通用；
- Loader.svelte：无限滚动触发器，IntersectionObserver 以 10% 阈值观察，元素可见期间每 100ms 派发 visible 事件；聊天列表分页和 ChatList 列表消费（实现见 Loader 第 10-33 行及相邻消费点）；
- Overlay.svelte：容器级局部加载遮罩（blur 背景、Spinner 和文本），实现见第 10-30 行；
- 空状态：落地页 chat/Placeholder.svelte（建议和搜索框）、空聊天 ChatPlaceholder.svelte、ChatList 的 emptyMessage 属性以及文件夹空提示；无统一 Empty 组件。相关宽度和入口分别在 Placeholder、ChatList 第 28 行与 FileNav 第 1395 行；
- 消息列表虚拟化：使用 content-visibility: auto，Safari 按 UA 剔除（Messages/Message.svelte 第 51-60、154-155 行，注释引用 paint bug #26712）；
- 消息生成中的流式反馈、按钮状态与停止逻辑属聊天主链（Chat UI 笔记第 5 节）。

### 错误边界

- SvelteKit 根错误页 src/routes/+error.svelte 显示 `$page.status` 和 `$page.error`；
- 后端不可达专用页 src/routes/error/+page.svelte 在 onMount 检测到 `$config` 存在即跳回 `/`；根布局后端配置拉取失败时调用 goto('/error')，相关入口见专用页第 10-16 行和根布局第 1225-1228 行；
- 业务错误走 toast（如 app 页面第 8-12 行处理的 `?error=` 参数）；
- 无 React 式 ErrorBoundary 组件——Grep ErrorBoundary 无匹配（Svelte 生态下组件内 onError/边界捕获本次未发现，含源码未检索 onError 之外的兜底机制）。

## 4. 主题、视觉 token 与持久化

### 权威源与首屏防闪烁

- 主题的权威来源是设备上的 localStorage.theme，取值为 `system / light / dark / oled-dark / her` 五档：system 是默认值，her 是仅在 enable_easter_eggs 开启时可用的彩蛋主题；首次访问由 app.html 的内联脚本写入，前端的 theme store 只镜像这个值（`app.html:49-51`、`src/routes/+layout.svelte:1120`）。
- 防 FOUC：app.html head 中的内联脚本在首帧前读取 localStorage，给 document.documentElement 加上 light、dark 或 her class；oled-dark 另用行内 CSS 变量覆盖 gray 色阶并同步 theme-color 元标签，这段变量分支与脚本主体同在 `app.html:43-116`（脚本内注释写着 "best to add inline in head to avoid FOUC"）。
- 系统跟随：内联脚本给 matchMedia('(prefers-color-scheme: dark)') 挂 addListener，系统配色一变就切换 class；设置页把主题切到 `system` 时也会立即按当前系统偏好解析一次（`app.html:84-96`、`General.svelte:131-133`）。

### 切换链路与 token 体系

- 设置页 chat/Settings/General.svelte：themeChangeHandler（第 192-196 行）依次更新 theme、localStorage 并调用 applyTheme（第 128-190 行），给 html 加删 `light/dark` class、写 `--color-gray-800/850/900/950` 行内变量并同步 theme-color 元标签；

  桌面壳存在时调用 window.applyTheme 通知（第 177-179 行）。行内 gray 变量并非 oled-dark 独有：普通 dark 也覆盖为 `#333/#262626/#171717/#0d0d0d`（第 135-140 行），oled-dark 才用更纯黑 `#101010/#050505/#000000/#000000`（第 181-187 行）并强制加 dark class；

  app.html 防 FOUC 脚本只在 oled-dark 分支写变量（第 56-61 行）。
- her 彩蛋主题边界：选项仅在 enable_easter_eggs 功能开关开启时出现（General.svelte 第 218-220 行）；

  app.html 第 66-68 行给它加 her class 并同步 theme-color（`#983724`），但 app.css 全文无任何 html.her 样式规则；该主题无独立 token/配色定义，可见效果只有 splash 专属外观（app.html 第 206-247 行的 her logo/进度条）与 theme-color；

  桌面壳 theme:update 事件把它映射为 `light` 基底（根布局第 915-917 行）。
- 视觉 token：没有语义色层（无 `--primary`/`--accent` 之类，在 src 搜索 accent、primaryColor 和这两个变量均无匹配），颜色直接用 Tailwind gray-50~950 色阶；定义见 tailwind.css 的 @theme oklch（第 5-18 行，含自定义 gray-850）；

  明暗切换由 Tailwind 的 dark 变体驱动（darkMode 在 tailwind.config.js 中设为 class）；tippy、svelte-sonner 的 Toaster，以及 CodeMirror、KaTeX、ProseMirror 这类内嵌组件各自处理明暗自适应，其中 tippy 的深色样式覆盖写在 app.css 里（第 363-365、691-693 行）。
- 字体：默认字体栈为 Inter 与 Vazirmatn（本地文件，font-display: swap），代码字体 JetBrainsMono，字体栈定义在 `src/app.css:3-13` 与 `src/tailwind.css:41-45`。界面字体族可由用户覆盖：Interface 设置的 Font Family 行（Default/Custom 切换加自由输入）把设置项 fontFamily 写进 --app-font-family 变量并挂到根元素，保存时随用户设置同步，未设置或清空则移除变量回落到默认栈（`src/lib/utils/text-scale.ts:9-27`、`src/lib/components/common/InterfaceSettings.svelte:553-597`）。字号没有档位设置，仍只经 `--app-text-scale` 统一缩放。
- 扩展 token：`--app-text-scale` 用于 UI 缩放（写入 html font-size，相关样式和工具分别在 app.css 第 15-24 行、text-scale.ts 第 1-27 行）；`--sidebar-width` 控制侧栏宽度，`--color-gray-*` 用于 dark/oled-dark 行内覆盖。
- 无障碍模式：设置键仍是 `highContrastMode`，界面标签已改为 Accessibility Mode（`src/lib/components/common/InterfaceSettings.svelte:590-605`），开启后由根布局按 `html.high-contrast` class 应用（`src/routes/+layout.svelte:1361`）；`src/app.css:423-999` 提供对比度修正规则，覆盖焦点轮廓、placeholder、app-muted 灰色文字、着色文本、编辑占位与 shimmer，并引用 WCAG 1.4.3/1.4.11。

### 聊天页背景图（壁纸，三级优先级）

- 应用点：非 embedded 模式下，`chat/Chat.svelte` 按优先级取得第一个非空来源，把它渲染成绝对定位、bg-cover 的背景层，上面再叠一层白色或灰色渐变遮罩——浅色是 `from-white to-white/85`，深色是 `from-gray-900 to-gray-900/90`。背景只铺在 Chat 页面容器上，输入区没有独立的背景设置（`chat/Chat.svelte:3783-3801`）。
- 优先级（高→低）：
  1. 文件夹级：`selectedFolder.meta.background_image_url`，由文件夹弹窗上传或移除（`layout/Sidebar/Folders/FolderModal.svelte:28-205`）。
  2. 用户级：`settings.backgroundImageUrl`，对应 Interface 设置页的 "Chat Background Image" 项，可上传或重置；上传时用 FileReader 转成 dataURL，只接受 gif/webp/jpeg/png 四种格式（`Interface.svelte:321-347`、`src/lib/stores/index.ts:232`）。
  3. 许可级：`config.license_metadata.background_image_url`，由后端 `/api/config` 组装下发（`chat/Chat.svelte:3792-3797`、`backend/open_webui/main.py:2098-2267`）。
- 持久化：用户级与文件夹级都走服务端（saveSettings 全量回写 `{ ui: $settings }`，见下节）——与 theme 的 localStorage 权威相反，背景图是**账户级且随账户同步**的偏好。

### 持久化与服务端交点

- 主题**不**随账户同步：Settings 类型里没有 theme 字段，切换主题的 themeChangeHandler 只写 localStorage，同一用户在另一台设备或另一个浏览器上会看到不同主题（静态推断）；聊天背景图（backgroundImageUrl）与文本方向（chatDirection）则是 Settings 字段，随用户设置同步（`src/lib/stores/index.ts:202-275`）。
- 桌面壳可反推主题：desktopEventHandler 的 theme:update 事件写 localStorage + 应用 class（`+layout.svelte:909-928`）。
- 服务端用户设置：读取与保存接口都要求通过用户身份验证。读取接口返回当前用户设置；保存接口按字段权限过滤提交内容，再更新设置（`backend/open_webui/routers/users.py:461-541`）。

  | 接口或保存条件 | 行为 |
  | --- | --- |
  | `GET /user/settings` | 通过用户身份验证后读取设置 |
  | `POST /user/settings/update`，非 admin 且缺少 `settings.interface` 权限 | 从提交的界面设置中剥离 InterfaceSettings 定义的字段，其他字段继续按各自规则处理 |
  | 非 admin 且缺少系统提示词相关权限 | 剥离提交的 system 字段 |
  | 非 admin 且缺少直连工具服务器权限 | 剥离提交的 toolServers 字段 |
  | 非 admin 且缺少 webhook 权限 | 剥离提交的通知配置及界面通知中的 webhook_url |

  前端 `(app)/+layout.svelte:92-117` 启动时拉取 userSettings.ui 写入 settings store（失败回退 localStorage 缓存），`SettingsModal.svelte:817-822` 的 saveSettings 合并后全量回写（`{ ui: $settings }`）。
- 部署级自定义 CSS：无用户级自定义 CSS 设置（Grep customCss/userStyle/customCSS 在 src 无匹配，Interface 设置页无对应项），但 `app.html:35` 固定链接 `/static/custom.css`（`static/static/custom.css` 为空占位文件）——自定义样式只能经部署时改写该静态文件实现，与用户设置体系无关。

### 文本方向（Chat Direction）

- 用户设置项 chatDirection 取 'LTR'、'RTL' 或 'auto' 三态，Interface 面板用一个控件循环切换，取值随账户同步（`src/lib/stores/index.ts:253`、`Interface.svelte:616-638`）。
- 应用方式：各消息容器在自己渲染的元素上显式设置 dir 属性，方向只沿组件逐层透传——用户消息与回复消息各设一处，消息输入框、频道消息与频道输入框也各带一份（`chat/Messages/UserMessage.svelte:134`、`chat/MessageInput.svelte:1590-1622`，其余三处入口见第 10 节）；

  auto 由浏览器按内容自动判定。这是布局方向与主题联动的最浅层实现（不改全局 dir/CSS，仅逐组件透传）。

## 5. 响应式、移动端与窗口适配

**断点。** 唯一的应用级断点是 mobile store，即 window.innerWidth 小于 768；常量和 resize 监听见根布局第 127、1122-1131 行，消费点共 12 处，分布在聊天、导航栏和多响应消息等组件；

其余为 Tailwind 响应式工具类与 @container；项目启用 @tailwindcss/container-queries，落地页使用 @2xl 等容器查询变体。
- **侧栏三态**（layout/Sidebar.svelte，桌面 1732 行）：
  1. 桌面展开：宽度由 sidebarWidth store 控制，拖拽分隔条即可调宽。拖拽用 pointerdown 加 setPointerCapture 锁定单个指针，pointermove 改宽，pointerup 与 pointercancel 收尾，组件销毁时复位拖拽期间对 body 文本选择的锁定；新宽度持久化到 localStorage 并写入 `--sidebar-width` CSS 变量（`src/lib/components/layout/Sidebar.svelte:603-891`）；
  2. 桌面折叠：42px 图标窄条（第 931-989 行，showSidebar=false 时）；
  3. 移动端：侧栏变成覆盖式抽屉加全屏遮罩（容器带 md:hidden），并支持从屏幕左缘滑动开合，手势起点在左侧 40px 内、滑动距离达到屏宽八分之一即触发（`Sidebar.svelte:557-901`）。

**面板分栏。** 聊天工作台与右侧标签面板用 paneforge 的 PaneGroup、Pane 和 PaneResizer 拖拽，入口在 Chat.svelte；面板宽度另存于 `chatControlsSize`（`ChatTabs.svelte:1176`），移动端标签面板走非侧滑路径。

**阅读宽度。** 消息区以 max-w-[58rem] 居中，widescreenMode 设置可改为 max-w-full；设置入口和两个消费点分别见 Interface.svelte 第 741-751 行、Messages/Message.svelte 第 58-60 行及 MessageInput.svelte 第 1382-1422 行。这是用户偏好而非断点策略。

**安全区域与 viewport。** `viewport-fit=cover` + `interactive-widget=resizes-content`（`app.html:27-30`）、padding-safe-bottom: env(safe-area-inset-bottom)（`tailwind.config.js:21-23`）。

**移动端特性。** 下拉刷新手势（`+layout.svelte:1011-1043`，仅导航区域、滚动到顶时）、soft 键盘感知的 Dropdown（visualViewportAware）、底部 Drawer、触摸优先交互；Safari 消息虚拟化例外（见第 3 节）。

**PWA 现状。** `app.html:26` 引用 `/manifest.json`，但 `static/manifest.json` 内容为空对象 `{}`；src 中无 serviceWorker.register（Grep 仅命中 `+layout.svelte:87` 的注销逻辑 unregisterServiceWorkers，用于版本更新清理，:84-96）；

`static/static/loader.js` 为空文件。即：保留 manifest 引用与 SW 清理代码，本次未找到 SW 注册与有效 manifest 内容。

## 6. 图片、附件、拖放与常见内容交互

### 图片预览（灯箱）

链路：`common/Image.svelte`（通用图片组件）→ 点击打开 `common/ImagePreview.svelte`：

- `Image.svelte`：safeImageUrl 白名单过滤（`utils/safeImageUrl`），`aria-label="Show image preview"`，可 dismissible（删除角标，:43-56）；
- `ImagePreview.svelte`：全屏黑底灯箱（modal class、z-9999），关闭按钮 + 下载按钮（data:/blob:/http(s) 三路 Blob 处理，:76-145），正文 PanzoomContainer（panzoom 库，`PanzoomContainer.svelte:3-28`，滚轮缩放/拖拽平移）承载 `<img>`；Esc 关闭 + body 滚动锁定（:18-33）；
- 无多图轮播/旋转/翻转（对比 Cherry Studio 有完整灯箱），图片缩放仅 panzoom 滚轮/拖动——静态推断；
- 消息渲染器的图片点击入口归消息渲染器类目。

### 拖放

**无公共拖放抽象**：各业务点自实现 dragover、drop 和 dragleave（Grep 命中 12 处实现），包括：

- 聊天输入（`chat/MessageInput.svelte:1014,1310-1336`，dropzoneId 注入，视觉反馈 `MessageInput/FilesOverlay.svelte` 拖入遮罩 + AddFilesPlaceholder）——主链细节见 Chat UI 笔记第 3 节；
- 频道输入、笔记、知识库、侧栏导入聊天文件、文件夹归类和富文本图片拖入均各自实现；代表性入口见 channel/MessageInput.svelte 第 528、657-679 行及其余业务组件对应实现。
- 排序拖放：sortablejs（第 1 节清单），侧栏聊天列表与置顶项、模型管理、横幅管理等。

### 上传与反馈

- 聊天附件上传/粘贴/大文本转文件的提交链在 Chat UI 笔记第 3 节；失败反馈统一 toast；
- 图片压缩设置（`settings.imageCompression/imageCompressionSize`，`Interface/ManageImageCompressionModal.svelte`）影响上传前处理，处理实现本次未追查；
- 侧栏文件导入（JSON 聊天备份）有格式校验 toast（`Sidebar.svelte:494-512`）。

### 其他常见交互

- 剪贴板：复制按钮临时态（消息操作按钮、代码块复制）属消息渲染器类目；
- 分页：`common/Pagination.svelte`（bits-ui Pagination 封装）与 Loader 无限滚动双模式并存；
- 富文本/代码编辑器（ProseMirror/TipTap、CodeMirror、xterm 终端）属各自业务类目，不在本笔记范围。

## 7. 扩展调查：快捷键、设置框架、桌面集成交点

### 快捷键系统

- 注册表：`src/lib/shortcuts.ts` 用 Shortcut 枚举登记 24 项快捷键及其默认绑定，其中 19 项允许用户改键；同一文件还提供按键事件匹配与按平台格式化快捷键的辅助逻辑（`src/lib/shortcuts.ts:19-203`）。
- 持久化：按键绑定存在用户设置的 keybindings 字段里，启动时经 loadKeybindings 读入，改键后调用 updateUserSettings 回写服务端，因此跨设备同步（`(app)/+layout.svelte:110`、`Settings/Shortcuts.svelte:65-75`）。
- 分发：app 布局用一个 document keydown 监听统一分发，20 多个分支直接操作 DOM id 和 store；关闭弹窗默认绑定 Escape，聚焦输入框默认绑定 Shift+Escape，两者是独立动作。settings.keyboardShortcuts 为 false 时整套禁用；默认绑定与分发分别见 `src/lib/shortcuts.ts:100-102`、`src/routes/(app)/+layout.svelte:287-305`。
- 输入区内的快捷键（听写、停止生成、@ / 等）在 `MessageInput.svelte` 本地处理（Chat UI 笔记第 9 节）。

### 设置框架（SettingsModal）

- 宿主是 `chat/SettingsModal.svelte`（1281 行），开关状态由 showSettings store 承载，可存 boolean、字符串或 `{tab, state}` 对象，后两者用来指定打开哪个 tab 及其初始状态（`chat/SettingsModal.svelte:60-92`）。
- tab 组织：侧栏分个人 13 项与管理 16 项（管理项带 admin: 前缀），渲染前先按角色和功能开关过滤；搜索框对每个 tab 预置的 keywords 数组做匹配，输入有 100ms 防抖；分组标题个人侧为 Basics/Services/Preferences/Data/Profile，管理侧为 System/AI/Quality/Tools/Experience/Data（`chat/SettingsModal.svelte:103-844`）。
- 深链：`?settings=<tab>` URL 参数（`(app)/+layout.svelte:199-228`，处理完剥离参数）；快捷键 Cmd+. 打开、`Cmd+/` 直达 shortcuts tab；
- 保存模式：各 tab 组件只把改动交给 saveSettings 合并进 store，再整体回写服务端；admin 相关配置另走一条独立的 config 拉取与提交路径（`chat/SettingsModal.svelte:817-835`）。
- 版本更新提示由两处配合：ChangelogModal 关闭时把 settings.version 记为已读，UpdateInfoToast 在右下角提示新版本，并用 dismissedUpdateToast 做 24 小时静默（`ChangelogModal.svelte:41-46`、`(app)/+layout.svelte:386-452`）。

### 桌面集成交点（壳在独立仓库）

- 入口：桌面壳往渲染进程注入 window.electronAPI，Web 侧通过它查询应用信息与数据目录、更新令牌、判断窗口是否聚焦并订阅桌面事件，调用集中在 `+layout.svelte:1038-1216`；用到的通道名为：
  - `app:info`、`app:data`
  - `token:update`、`window:isFocused`
  - `onEvent`

  桌面模式在这里把 `isApp` store 置位（`:1202`），本快照内没有组件读取该标志，桌面壳实际经事件通道影响导航与主题。
- 双向事件：桌面发来的事件由 `desktopEventHandler` 写入 desktopEvent store，再由各处理器消费，通道有：
  - `page:reload`、`page:navigate`
  - `query`、`call`
  - `theme:update`、`models:refresh`
  - `connections:*`

  Web 侧回给桌面的只有两个调用：window.applyTheme 同步主题、`load` 触发导航（`+layout.svelte:1038-1054`、`:1191-1192`）。
- 本仓不含桌面壳实现（仓库分布笔记同述），electronAPI/applyTheme 无类型声明，属运行时注入钩子。

### 无障碍与动画（静态证据，运行未验证）

- 应用级：
  - skip link 放在根布局（`+layout.svelte:1310-1315`）；
  - Modal 与 ConfirmDialog 带 role="dialog"、aria-modal，并套 focus-trap；
  - Dropdown 用 role="menu" 配 aria-expanded，关闭时归还焦点；
  - NotificationToast 声明 role="status" 与 aria-live="polite"；
  - Switch 把 aria-label 透传给内部控件（`Switch.svelte:31-32`）；
  - 高对比度模式由 html.high-contrast 上的一层对比度修正规则承担。
- 未覆盖证据：Toast 的 svelte-sonner 内部 aria 行为未核实；tippy Tooltip 的读屏名称未核实；Modal 关闭后的焦点去向未运行验证；全站按钮 aria-label 覆盖率未统计（工具按钮多数带 aria-label，如 `Image.svelte:37`、`Sidebar.svelte:953`）。
- 动画：项目没有引入动画库，过渡全部来自 Svelte 的 fade/fly/slide、自研的 flyAndScale 与 CSS 关键帧三条路径。flyAndScale 由 `utils/transitions/index.ts` 实现，时长 200ms、缓动 cubicOut，风格参照 shadcn；关键帧动画有 shimmer、smoothFadeIn 与 fade-in-token，定义在 `app.css:187-256`。prefers-reduced-motion 的处理本次未找到（Grep reduced-motion|motion-reduce 无匹配）。

## 8. 设计取舍与已确认边界

**弹窗层级是"最后挂载者优先"而非 z-index 栈。** Esc 用 isTopModal 判定（`Modal.svelte:49-52`），但同层多个 modal 的视觉层叠只由 body append 顺序决定；ConfirmDialog 不带 modal class，其 Esc 判定独立（静态推断：可与 Modal 同时响应 Esc）。

**body 滚动锁无共享计数器。** Modal/ConfirmDialog/Drawer/ImagePreview 各自 `overflow='hidden'/'unset'`，多弹窗叠加时关闭其中一个即恢复滚动；

`ImagePreview.svelte:42-43` 注释自述："NOTE: If multiple modals can stack in the future, direct 'unset' may re-enable page scroll too early. Consider a shared body-scroll lock manager."——代码作者已确认该边界。

**焦点陷阱与浮层交互的平衡。** Modal 显式 allowOutsideClick 放行 toast 与（名义上的）`.modal-content`，并监听 pointerdown/focusin 自动 pause/unpause，服务于"modal 上再开 Dropdown"的场景；ConfirmDialog 用 focus-trap 默认配置，两者策略不一致（差异的实际表现未运行验证）。

**Drawer 无焦点陷阱。** 与 Modal/ConfirmDialog 形成不一致面（静态确认）。

**主题是设备本地偏好。** 权威在 localStorage，服务端不存 theme——多设备不同步是有意的设计边界（设置里主题项无账户同步迹象，静态推断）；oled-dark 通过行内 CSS 变量覆盖 `--color-gray-*` 实现，而非独立 class 变体。

**同一外观域内权威源分裂。** 主题（theme）走 localStorage 设备本地，而聊天背景图（backgroundImageUrl）与文本方向（chatDirection）走服务端用户设置、随账户同步——外观类偏好的持久化不统一（静态确认）。

**拖放与上传无公共抽象。** 12 处业务自实现 drop 处理、sortablejs 分散 6 处实例化，没有统一的上传队列/拖放 store（区别于聊天发送队列 chatRequestQueues）。

**无右键菜单、无 SW 注册、manifest 为空对象。** 与桌面原生类产品（Cherry Studio）形成明显差异；SW 注销代码保留说明历史上曾注册（版本更新强制刷新的配套）。
- **移动端策略靠单一 768px 断点 + `$mobile` store 显式分支**，而非容器查询驱动折叠（容器查询仅用于落地页排版）。

**Svelte 5 的 runes 只零星引入。** 代码主体是 Svelte 4 风格，渐进迁移中（静态观察）。

## 9. 未验证事项

- 所有视觉、焦点顺序、键盘路径、动画与触摸行为均未运行验证；以下为静态推断项：Modal 关闭后的焦点归还、ConfirmDialog 与 Modal 同时打开时的 Esc 竞争、allowOutsideClick 实际放行效果。
- 依赖库内部行为未下钻：svelte-sonner（堆叠/动画/aria）、focus-trap（deactivate 归还）、tippy.js（焦点与读屏默认行为）、sortablejs、panzoom、bits-ui Switch/Pagination、paneforge 的键盘与动画细节。
- window.applyTheme 与 window.electronAPI 是桌面壳运行时注入，本仓无定义；桌面壳侧行为未调查。
- 后端通知事件（CHAT_FINISHED/CHAT_FAILED 等）到 webhook 目标的完整派发链未追查。
- 主题跨设备同步、`?settings=` 深链在 SPA 导航中的表现、Safari 虚拟化例外的实际修复效果未实测。
- 聊天背景图的暗色渐变遮罩对图片可读性的实际效果、RTL 方向下各消息组件的布局表现未运行验证；her 主题"无独立样式定义"基于 src 内 html.her/`.her` 选择器 Grep（仅命中 `app.html`）的静态推断。
- 图片压缩（imageCompression）处理实现未追查；alpinejs 依赖在本次源码检查范围内未找到接入点。

## 10. 关键源码索引

- 根装配与全局事件：`src/routes/+layout.svelte`（Toaster 1341、socket 事件 495-805、桌面事件 889-975、mobile 1122-1131、主题应用 909-928）
- 首屏主题防闪烁与 splash：`src/app.html`（43-116、126-189）
- (app) 布局与快捷键分发：`src/routes/(app)/+layout.svelte`（278-367、439-452）
- 全局 store：`src/lib/stores/index.ts`（settings 104、theme 36、showSettings 120、sidebarWidth 111）
- 弹窗：`src/lib/components/common/Modal.svelte`、`ConfirmDialog.svelte`、`Drawer.svelte`、`Dropdown.svelte`、`Tooltip.svelte`
- Toast 与通知：`src/routes/+layout.svelte`（Toaster 装配）、`src/lib/components/NotificationToast.svelte`、`src/lib/components/chat/Settings/Notifications.svelte`
- 加载与空状态：`src/lib/components/common/Loader.svelte`、`Spinner.svelte`、`Overlay.svelte`、`chat/Placeholder.svelte`、`chat/ChatPlaceholder.svelte`
- 错误页：`src/routes/+error.svelte`、`src/routes/error/+page.svelte`
- 主题切换：`src/lib/components/chat/Settings/General.svelte`（128-196）；token：`src/tailwind.css`、`src/app.css`（high-contrast 423-999）；缩放与字体：`src/lib/utils/text-scale.ts`
- 聊天背景图：`src/lib/components/chat/Chat.svelte`（3783-3801）、`chat/Settings/Interface.svelte`（664-691）、`layout/Sidebar/Folders/FolderModal.svelte`；许可字段下发：`backend/open_webui/main.py:2267`；部署级自定义 CSS：`src/app.html:35` + `static/static/custom.css`
- 文本方向透传：`chat/Messages/UserMessage.svelte`（134）、`chat/Messages/ResponseMessage.svelte`（659）、`chat/MessageInput.svelte`（1590-1622）、`channel/Messages/Message.svelte`（379-460）、`channel/MessageInput.svelte`（807）
- 右键菜单屏蔽点：`chat/ChatTabs/ChromeBrowser.svelte`（260）、`chat/ChatTabs/NativeDesktop.svelte`（73）、`FileNav.svelte`（2387）、`chat/CallOverlay/VoiceAvatar.svelte`（222）
