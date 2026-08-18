# Open WebUI 应用界面基础设施调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
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

无 UI 组件库，公共层在 common 目录（53 个文件，含 Modal、ConfirmDialog、Drawer、Dropdown、Tooltip、Spinner、Loader、Image、ImagePreview、Switch、Checkbox、Select、Pagination、PanzoomContainer、PDFViewer 等）。

**构建与运行边界。** svelte.config.js 第 15-19 行使用 adapter-static 和 index.html fallback，根布局第 10 行关闭 SSR，因而是纯 SPA；

svelte.config.js 第 20-39 行配置 SvelteKit 版本轮询（60s），版本变化时根布局的 beforeNavigate 注销 service worker 并用 location.href 硬刷新（根布局第 98-104 行）。
- **根装配**（src/routes/+layout.svelte，1358 行）：
  - Toast Host：`<Toaster>`（根布局第 1341-1358 行，svelte-sonner，位置为 top-right，启用 richColors 和 closeButton，主题随 `$theme` 计算）；
  - Electron 壳侧栏 `<AppSidebar>`（仅 `$isApp` 时，:1324-1331）与社区统计弹窗 `<SyncStatsModal>`（:1337-1339，挂在根布局而非 app 布局）；
  - 全局服务：Socket.IO 连接与事件分发（chatEventHandler 495-703、channelEventHandler 705-805）、会话过期自动登出（fetch 401 拦截 + token 定时检查，:807-887,993-1007）、桌面壳事件（desktopEventHandler 889-975）、BroadcastChannel 活跃标签页仲裁（:108-109,1076-1095）、移动端下拉刷新手势（:1011-1043）；
  - splash 屏移除（:1232-1260）与 her 主题彩蛋进度条。
- **(app) 布局**（src/routes/(app)/+layout.svelte）：装配 Sidebar、SettingsModal、ChangelogModal、AccountPending 和 UpdateInfoToast（第 439-452 行），并负责全局快捷键分发（第 278-367 行）与 `?settings=` URL 深链（openSettingsFromUrl，第 199-228 行）。

**多入口。** `/` 与 `/c/[id]` 都是 `<Chat />` 一行装配（`(app)/+page.svelte:15`）；`/auth`（登录/注册/SSO 自动跳转 + OnBoarding 欢迎页，`auth/+page.svelte:178-201,211-217`）、`/s/[id]`（分享会话，自载用户设置）、`/watch`（YouTube 重定向）、`/error`（后端缺失页）均共享同一根布局基础设施（Toaster、socket、主题）。
- 桌面壳（Electron 原生应用在独立仓库，见仓库分布笔记）只经 window.electronAPI/window.applyTheme 全局钩子接入，本仓无实现与类型声明（`src/app.d.ts` 为空），调用处均带存在性检查（`+layout.svelte:507,1051-1073`；window.applyTheme 仅调用无定义，:1046、`General.svelte:177`）。

## 1. 界面栈、公共组件与状态所有权

**公共组件层。** common 目录是唯一的跨页公共组件目录；Modal 有 60 个消费文件、ConfirmDialog 26 个、Tooltip 100+ 个、toast 100+ 个文件（以上为 Grep 统计，搜索 src/lib 中的 import 语句，相对路径变体可能低估）。业务侧弹窗入口（ShareChatModal、TagChatModal、ToolServersModal 等）只记录底层机制，入口语义归 Chat UI 等业务类目。
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
  - 界面偏好持久化分散在 localStorage：theme、sidebarWidth（侧栏第 625-645 行，同时写入 CSS 变量 `--sidebar-width`）、showControls、chatControlsSize、selectedTerminalId、dismissedUpdateToast、locale 和 token；其中前三项的写入分别见 app 布局第 399-402 行、ChatControls 第 163 与 409-412 行，selectedTerminalId 与其相邻处理共用第 405-411 行。
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

全应用**没有自绘右键菜单**：在 src/lib 全部搜索 oncontextmenu 和 contextmenu 均无匹配。消息操作、侧栏项操作均走普通按钮、Dropdown 或 Modal，与 Cherry Studio 等桌面产品不同。

## 3. 通知、加载态与错误反馈

### Toast（svelte-sonner，唯一 Host）

- 装配：根布局 `<Toaster>`（根布局第 1341-1358 行），位置为 top-right，启用 richColors 和 closeButton；theme 属性由 `$theme` 推导（dark/system/light），toastOptions.classes.closeButton 覆写深色样式；
- 消费：Grep 显示 100+ 文件直接引入 svelte-sonner 的 toast，错误路径几乎统一调用 error 方法（如 Sidebar 第 868 行、SearchModal 第 80 行）；
- 堆叠/动画/更新/取消等具体行为是 svelte-sonner 内部实现，本次未下钻。

### 站内通知 toast（自研 NotificationToast）

- NotificationToast.svelte：通过 toast.custom 渲染，使用 role="status" 和 aria-live="polite"（第 86-87 行）；点击跳转时将 pointer 拖动超过 6px 视为拖拽，hover 显示关闭按钮，Enter/Space 可键盘激活（分别见第 31-64、94-99 行）；
- 三个触发点都在根布局事件处理器：聊天完成（duration: 15000）、频道消息和日历提醒（30s），实现集中在第 529-539、685-695、792-802 行；
- 同时旁路浏览器 Notification API（受 settings.notificationEnabled 与 `$isLastActiveTab` 门控）与通知音（playingNotificationSound store 加音频文件，根布局第 664-683 行）；NotificationToast 自身也有声音逻辑，受 navigator.userActivation 门控（第 66-82 行）。
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

- 权威源：localStorage.theme，取值为 `system`（默认）、light、dark、oled-dark 或 her（彩蛋，需 enable_easter_eggs）；首次访问写入见 app.html 第 49-51 行，theme store 仅镜像（根布局第 1120 行）。
- 防 FOUC：app.html head 中的内联脚本（第 43-116 行，注释原文 "best to add inline in head to avoid FOUC"）在首帧前按 localStorage 给 document.documentElement 加 `light/dark/her` class，oled-dark 用行内 CSS 变量覆盖 gray 色阶，并同步 theme-color 元标签；变量分支见第 56-61 行。
- 系统跟随：内联脚本用 matchMedia('(prefers-color-scheme: dark)').addListener 实时切换 class；设置页切换 `system` 时也即时解析（分别见 app.html 第 84-96 行、General.svelte 第 131-133 行）。

### 切换链路与 token 体系

- 设置页 chat/Settings/General.svelte：themeChangeHandler（第 192-196 行）依次更新 theme、localStorage 并调用 applyTheme（第 128-190 行），给 html 加删 `light/dark` class、写 `--color-gray-800/850/900/950` 行内变量并同步 theme-color 元标签；

  桌面壳存在时调用 window.applyTheme 通知（第 177-179 行）。行内 gray 变量并非 oled-dark 独有：普通 dark 也覆盖为 `#333/#262626/#171717/#0d0d0d`（第 135-140 行），oled-dark 才用更纯黑 `#101010/#050505/#000000/#000000`（第 181-187 行）并强制加 dark class；

  app.html 防 FOUC 脚本只在 oled-dark 分支写变量（第 56-61 行）。
- her 彩蛋主题边界：选项仅在 enable_easter_eggs 功能开关开启时出现（General.svelte 第 218-220 行）；

  app.html 第 66-68 行给它加 her class 并同步 theme-color（`#983724`），但 app.css 全文无任何 html.her 样式规则；该主题无独立 token/配色定义，可见效果只有 splash 专属外观（app.html 第 206-247 行的 her logo/进度条）与 theme-color；

  桌面壳 theme:update 事件把它映射为 `light` 基底（根布局第 915-917 行）。
- 视觉 token：没有语义色层（无 `--primary`/`--accent` 之类，在 src 搜索 accent、primaryColor 和这两个变量均无匹配），颜色直接用 Tailwind gray-50~950 色阶；定义见 tailwind.css 的 @theme oklch（第 5-18 行，含自定义 gray-850）；

  明暗由 dark 变体（darkMode: 'class'）驱动；主题相关的第三方组件包括 tippy、svelte-sonner Toaster，以及 CodeMirror、KaTeX、ProseMirror 的明暗自适应（tippy 样式见 app.css 第 363-365、691-693 行）。
- 字体：Inter + Vazirmatn（app.css 第 3-13 行，本地文件，font-display: swap），代码字体 JetBrainsMono；基础字体栈在 tailwind.css 第 41-45 行。无用户可配置的字体或字号档位设置（搜索 fontFamily 仅命中编辑器、PDF、终端等局部样式），字号只经 `--app-text-scale` 统一缩放。
- 扩展 token：`--app-text-scale` 用于 UI 缩放（写入 html font-size，相关样式和工具分别在 app.css 第 15-24 行、text-scale.ts 第 1-7 行）；`--sidebar-width` 控制侧栏宽度，`--color-gray-*` 用于 dark/oled-dark 行内覆盖。
- 高对比模式：html.high-contrast class 按 settings.highContrastMode 切换，设置开关见 Interface.svelte 第 436-456 行，根布局应用见第 1283-1288 行；app.css 第 848-919 行提供大量对比度修正规则，覆盖 placeholder、灰色文字、着色文本和 hover 状态，并引用 WCAG 1.4.3/1.4.11。

### 聊天页背景图（壁纸，三级优先级）

- 应用点：`chat/Chat.svelte:3783-3801`——非 embedded 时按优先级取首个非空来源渲染绝对定位 bg-cover 背景层，其上叠白色/灰渐变遮罩（:3789-3791,3799-3801，`from-white to-white/85`，dark 下 `from-gray-900 to-gray-900/90`）；仅作用于 Chat 页面容器，输入区无独立背景设置。
- 优先级（高→低）：
  1. 文件夹级 selectedFolder.meta.background_image_url（:3783-3787），设置入口在 `layout/Sidebar/Folders/FolderModal.svelte:28,75,102,165,193-205`（上传/移除）；
  2. 用户级 settings.backgroundImageUrl（`stores/index.ts:232`），设置入口在 `Interface.svelte:664-691`（"Chat Background Image"，上传/重置；FileReader 转 dataURL，限 gif/webp/jpeg/png，:321-347）；
  3. 许可级 config.license_metadata.background_image_url（`Chat.svelte:3792-3797`），由后端 `/api/config` 下发（`backend/open_webui/main.py:2098,2267`）。
- 持久化：用户级与文件夹级都走服务端（saveSettings 全量回写 `{ ui: $settings }`，见下节）——与 theme 的 localStorage 权威相反，背景图是**账户级且随账户同步**的偏好。

### 持久化与服务端交点

- 主题**不**随账户同步：Settings 类型（`stores/index.ts:202-275`）无 theme 字段，themeChangeHandler 只写 localStorage——跨设备/跨浏览器主题不一致（静态推断）；与之相反，聊天背景图（backgroundImageUrl，`stores/index.ts:232`）与文本方向（chatDirection，:253）是 Settings 字段，随用户设置同步。
- 桌面壳可反推主题：desktopEventHandler 的 theme:update 事件写 localStorage + 应用 class（`+layout.svelte:909-928`）。
- 服务端用户设置：`GET /user/settings` / `POST /user/settings/update`（`backend/open_webui/routers/users.py:438-509`），带权限检查（settings.interface 权限，:458-464）与字段过滤（非 admin 剥离 toolServers/notifications.webhook_url，:466-497）；

  前端 `(app)/+layout.svelte:92-117` 启动时拉取 userSettings.ui 写入 settings store（失败回退 localStorage 缓存），`SettingsModal.svelte:817-822` 的 saveSettings 合并后全量回写（`{ ui: $settings }`）。
- 部署级自定义 CSS：无用户级自定义 CSS 设置（Grep customCss/userStyle/customCSS 在 src 无匹配，Interface 设置页无对应项），但 `app.html:35` 固定链接 `/static/custom.css`（`static/static/custom.css` 为空占位文件）——自定义样式只能经部署时改写该静态文件实现，与用户设置体系无关。

### 文本方向（Chat Direction）

- 用户设置 chatDirection（'LTR' | 'RTL' | 'auto'，`stores/index.ts:253`），设置入口在 `Interface.svelte:64,173-182,616-638`（三态循环切换，随账户同步）。
- 应用方式：消息容器显式 dir 属性——`chat/Messages/UserMessage.svelte:134`、`chat/Messages/ResponseMessage.svelte:659`、`chat/MessageInput.svelte:1590,1622`、channel 侧 `channel/Messages/Message.svelte:379,460`、`channel/MessageInput.svelte:807`；

  auto 由浏览器按内容自动判定。这是布局方向与主题联动的最浅层实现（不改全局 dir/CSS，仅逐组件透传）。

## 5. 响应式、移动端与窗口适配

**断点。** 唯一的应用级断点是 mobile store，即 window.innerWidth 小于 768；常量和 resize 监听见根布局第 127、1122-1131 行，消费点共 12 处，分布在聊天、导航栏和多响应消息等组件；

其余为 Tailwind 响应式工具类与 @container；项目启用 @tailwindcss/container-queries，落地页使用 @2xl 等容器查询变体。
- **侧栏三态**（layout/Sidebar.svelte，桌面 1732 行）：
  1. 桌面展开：宽度由 sidebarWidth store 控制，mousemove 拖拽调宽（:921-929,615-645），持久化到 localStorage 并写 `--sidebar-width` CSS 变量；
  2. 桌面折叠：42px 图标窄条（第 931-989 行，showSidebar=false 时）；
  3. 移动端：覆盖式抽屉 + 全屏遮罩（:892-901，md:hidden），另支持屏幕左缘滑动手势开合（:557-581，起点 x<40、滑动距离≥屏宽/8）。

**面板分栏。** 聊天工作台与右侧控制面板用 paneforge 的 PaneGroup、Pane 和 PaneResizer 拖拽，入口从 Chat.svelte 第 3805 行开始；ChatControls 宽度另存于 chatControlsSize，移动端控制面板走非侧滑路径（Chat.svelte 第 1308 行的 `$mobile` 分支）。

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

- 注册表：src/lib/shortcuts.ts 定义 Shortcut 枚举 24 项、默认绑定、19 项可配置绑定，并提供按事件匹配和按平台格式化快捷键的逻辑；各段依次见第 19-100、199-203、157-188 行；
- 持久化：keybindings 存于用户设置（loadKeybindings(userSettings?.keybindings)，`(app)/+layout.svelte:110`；保存 `updateUserSettings({ keybindings })`，`Settings/Shortcuts.svelte:65-75`）——服务端权威、跨设备同步；
- 分发：app 布局第 278-367 行使用单一 document keydown 监听，20+ 分支直接操作 DOM id 和 store；关闭快捷键默认绑定 Escape，聚焦输入框绑定 Shift+Escape。settings.keyboardShortcuts 为 false 时整体禁用（第 280-282 行，默认绑定见第 94-95 行）；
- 输入区内的快捷键（听写、停止生成、@ / 等）在 `MessageInput.svelte` 本地处理（Chat UI 笔记第 9 节）。

### 设置框架（SettingsModal）

- 宿主：`chat/SettingsModal.svelte`（1281 行），showSettings store 支持 `boolean | string | {tab, state}`（:60-92）；
- tab 组织：个人 13 tab + 管理 16 tab（admin: 前缀），按角色过滤（:787）与功能开关过滤（:794-796）；关键字搜索（每 tab 带 keywords 数组，100ms 防抖，:837-844）；分组标题（Basics/Services/Preferences/Data/Profile 与 System/AI/Quality/Tools/Experience/Data，:103-143）；
- 深链：`?settings=<tab>` URL 参数（`(app)/+layout.svelte:199-228`，处理完剥离参数）；快捷键 Cmd+. 打开、`Cmd+/` 直达 shortcuts tab；
- 保存模式：各 tab 组件 saveSettings(partial) → 合并 store → 全量回写服务端（`SettingsModal.svelte:817-822`）；admin 配置走独立 config 拉取（:831-835）；
- 版本更新提示：ChangelogModal（关闭时记录 settings.version，`ChangelogModal.svelte:41-46`）+ UpdateInfoToast（右下角，24h 静默记忆 dismissedUpdateToast，`(app)/+layout.svelte:442-452,386-396`）。

### 桌面集成交点（壳在独立仓库）

- 入口：window.electronAPI（app:info/app:data/token:update/window:isFocused/onEvent，`+layout.svelte:1051-1073`）；`$isApp` 时装配 AppSidebar（4.5rem 应用导航条，`app/AppSidebar.svelte`）且 `Sidebar.svelte` 加 `ml-[4.5rem]` 偏移（:894-896）；
- 双向事件：桌面→Web desktopEvent store（page:reload/page:navigate/query/call/theme:update/models:refresh/connections:*，`+layout.svelte:889-975`）；Web→桌面 window.applyTheme（主题）与 load（导航，`AppSidebar.svelte:27-30`）；
- 本仓不含桌面壳实现（仓库分布笔记同述），electronAPI/applyTheme 无类型声明，属运行时注入钩子。

### 无障碍与动画（静态证据，运行未验证）

- 应用级：skip link（`+layout.svelte:1310-1315`）、Modal/ConfirmDialog `role="dialog" aria-modal` + focus-trap、Dropdown `role="menu"` + aria-expanded + 焦点归还、NotificationToast `role="status" aria-live="polite"`、Switch 封装透传 aria-label（`Switch.svelte:31-32`）、html.high-contrast 对比度修正层；
- 未覆盖证据：Toast 的 svelte-sonner 内部 aria 行为未核实；tippy Tooltip 的读屏名称未核实；Modal 关闭后的焦点去向未运行验证；全站按钮 aria-label 覆盖率未统计（工具按钮多数带 aria-label，如 `Image.svelte:37`、`Sidebar.svelte:953`）。
- 动画：无动画库，全部 Svelte transition（fade/fly/slide）与自研 flyAndScale（`utils/transitions/index.ts`，200ms cubicOut，shadcn 风格）+ CSS @keyframes（shimmer、smoothFadeIn、fade-in-token，`app.css:187-256`）；prefers-reduced-motion 处理本次未找到（Grep reduced-motion|motion-reduce 无匹配）。

## 8. 设计取舍与已确认边界

**弹窗层级是"最后挂载者优先"而非 z-index 栈。** Esc 用 isTopModal 判定（`Modal.svelte:49-52`），但同层多个 modal 的视觉层叠只由 body append 顺序决定；ConfirmDialog 不带 modal class，其 Esc 判定独立（静态推断：可与 Modal 同时响应 Esc）。

**body 滚动锁无共享计数器。** Modal/ConfirmDialog/Drawer/ImagePreview 各自 `overflow='hidden'/'unset'`，多弹窗叠加时关闭其中一个即恢复滚动；

`ImagePreview.svelte:42-43` 注释自述："NOTE: If multiple modals can stack in the future, direct 'unset' may re-enable page scroll too early. Consider a shared body-scroll lock manager."——代码作者已确认该边界。

**焦点陷阱与浮层交互的平衡。** Modal 显式 allowOutsideClick 放行 toast 与（名义上的）`.modal-content`，并监听 pointerdown/focusin 自动 pause/unpause，服务于"modal 上再开 Dropdown"的场景；ConfirmDialog 用 focus-trap 默认配置，两者策略不一致（差异的实际表现未运行验证）。

**Drawer 无焦点陷阱。** 与 Modal/ConfirmDialog 形成不一致面（静态确认）。

**主题是设备本地偏好。** 权威在 localStorage，服务端不存 theme——多设备不同步是有意的设计边界（设置里主题项无账户同步迹象，静态推断）；oled-dark 通过行内 CSS 变量覆盖 `--color-gray-*` 实现，而非独立 class 变体。

**同一外观域内权威源分裂。** 主题（theme）走 localStorage 设备本地，而聊天背景图（backgroundImageUrl）与文本方向（chatDirection）走服务端用户设置、随账户同步——外观类偏好的持久化没有统一哲学（静态确认）。

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
- 图片压缩（imageCompression）处理实现未追查；alpinejs 依赖无源码接入点（本次未找到，不能据此断言构建产物中不存在）。

## 10. 关键源码索引

- 根装配与全局事件：`src/routes/+layout.svelte`（Toaster 1341、socket 事件 495-805、桌面事件 889-975、mobile 1122-1131、主题应用 909-928）
- 首屏主题防闪烁与 splash：`src/app.html`（43-116、126-189）
- (app) 布局与快捷键分发：`src/routes/(app)/+layout.svelte`（278-367、439-452）
- 全局 store：`src/lib/stores/index.ts`（settings 104、theme 36、showSettings 120、sidebarWidth 111）
- 弹窗：`src/lib/components/common/Modal.svelte`、`ConfirmDialog.svelte`、`Drawer.svelte`、`Dropdown.svelte`、`Tooltip.svelte`
- Toast 与通知：`src/routes/+layout.svelte`（Toaster 装配）、`src/lib/components/NotificationToast.svelte`、`src/lib/components/chat/Settings/Notifications.svelte`
- 加载与空状态：`src/lib/components/common/Loader.svelte`、`Spinner.svelte`、`Overlay.svelte`、`chat/Placeholder.svelte`、`chat/ChatPlaceholder.svelte`
- 错误页：`src/routes/+error.svelte`、`src/routes/error/+page.svelte`
- 主题切换：`src/lib/components/chat/Settings/General.svelte`（128-196）；token：`src/tailwind.css`、`src/app.css`（high-contrast 848-919）；缩放：`src/lib/utils/text-scale.ts`
- 聊天背景图：`src/lib/components/chat/Chat.svelte`（3783-3801）、`chat/Settings/Interface.svelte`（664-691）、`layout/Sidebar/Folders/FolderModal.svelte`；许可字段下发：`backend/open_webui/main.py:2267`；部署级自定义 CSS：`src/app.html:35` + `static/static/custom.css`
