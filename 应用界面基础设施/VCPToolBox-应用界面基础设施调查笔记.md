# VCPToolBox 应用界面基础设施调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 的管理台是 Vue、Pinia 和 vue-router 构成的单页应用，没有第三方 UI 组件库。BaseModal 自行处理 Portal、焦点陷阱、滚动锁定、Esc 和遮罩关闭；confirm、input、loading 与 message 通过模块级 feedback state 和唯一 Host 提供命令式接口。

主题完全保存在浏览器 localStorage，使用 OKLCH token、明暗属性和 17 个预设，并允许颜色覆盖、自定义 CSS 和背景图。编辑器还能运行时发现可调变量，同时锁定 z-index、间距等结构 token。项目没有系统跟随、主题市场或自动色阶生成。

响应式主要依赖媒体查询，Dashboard 另外使用容器查询和列数感知。拖放实现分散：插件上传使用 HTML5 事件，排序与面板调整采用自研指针会话；项目没有公共图片灯箱或上传组件。

## 系统边界与总体装配

**托管方式。** 管理面板由独立进程 `adminServer.js`（监听 PORT+1）托管 `AdminPanel-Vue/dist` 静态产物（:237-240），非扩展名路径一律回退 `index.html`（history fallback，:242-250），`/AdminPanelLegacy` 保留旧路径兼容（:240,250）；

主进程对 `/AdminPanel` 302 重定向（`server.js:837-846`）。物理解耦细节见 [`../仓库分布/VCPToolBox-仓库分布调查笔记.md`](../仓库分布/VCPToolBox-仓库分布调查笔记.md) 与 [`../Chat UI/VCPToolBox-ChatUI调查笔记.md`](<../Chat UI/VCPToolBox-ChatUI调查笔记.md>)。

**前端装配。** `src/main.ts` 顺序为：创建应用与 Pinia、初始化鉴权 store、把命令式反馈总线接到模块级实现（setFeedbackSink，:20）、注册 401 自动登出监听（:21-42）、注册全局 v-lazy 指令（:45）后挂载；`App.vue` 只渲染 `router-view`。

**布局 shell。** `MainLayout.vue` 是唯一业务壳（Login 独立路由），挂载星空背景、沉浸观星面板、顶栏、侧栏、内容区、反馈宿主、通知抽屉与全局命令面板（:11-126）。

应用级滚动策略是 **body 滚动锁死、只有 `.content-scroll-region` 滚动**：`useMainLayoutDomEffects.ts:165-166` 挂载时把 body 滚动设为 hidden，内容区独立滚动（`MainLayout.vue:263-274`）。

**路由与守卫。** 40 条路由来自 `src/app/routes/manifest.ts`，除 login 外全部作为 Main 的子路由（`router/index.ts:28-51`）；beforeEach 统一做鉴权（checkAuth + 5 分钟缓存，`stores/auth.ts:20-26,43-82`），未登录跳 Login 并带安全 redirect（:69-121）；`base.ts` 把 `/AdminPanelLegacy` 路径归一化到 `/AdminPanel`（:14-40）。

**页头动作机制。** `MainLayout.vue:56-63` 提供 `#page-header-actions` 容器，32 个业务页面各自 Teleport 把自己的操作按钮（保存/导入/导出等）挂进统一页头（如 `views/ThemeEditor.vue:3-31`、`views/PluginStore.vue:3`）。

**Chat UI 边界。** 按 Chat UI 类目判定，本项目不产出最终用户聊天表面（见前述 ChatUI 笔记），本笔记无聊天主链交点需要记录；Nova 气泡、沉浸观星等装饰元素属 Dashboard 业务，不纳入。

## 1. 界面栈、公共组件与状态所有权

**界面栈。** Vue ^3.5.31 + Pinia ^3.0.4 + vue-router ^5.0.4 + TypeScript + Vite 8；功能性依赖为 easymde（Markdown 编辑器）、marked/marked-highlight/`highlight.js`/dompurify（渲染与消毒）、@fontsource-*（字体）、font-awesome（遗留图标）；

无 UI 组件库、无动画库、无 i18n 库（`package.json:17-45`）。`src/vendor/three.module.js` 供 `SolarSystemBg.vue` 星空背景使用。

**公共组件层。** `src/components/ui/` 26 个手写控件（UiButton/UiInput/UiSelect/UiTextarea/UiField/UiCard/UiAlert/UiBadge/UiEmptyState/UiList/UiListItem/UiTableFrame/UiToolbar/UiIconButton/UiPageActions/UiDirtyIndicator/UiSettingsCard/UiSettingsForm/UiSettingsGroup/UiSettingsSwitchRow/UiSideConsoleNav/AppCheckbox/AppSwitch/DragHandle 等）。

设置类页面通过 UiSettings* 系列构成统一的"设置卡片 + 表单分组 + 开关行"骨架。
- **状态所有权**（按问题 7）：
  - **全局 Pinia**：六个 store，分别负责主题与界面偏好、鉴权会话、按 key 计数的加载计数、通知连接与列表、日记、插件配置（文件：`stores/app.ts`、`stores/auth.ts`、`stores/loading.ts`、`stores/notifications.ts`、`stores/diary.ts`、`stores/pluginConfig.ts`）。
  - **模块级单例（不经 Pinia）**：`platform/feedback/feedbackState.ts` 的 reactive 状态 + 队列，见第 2、3 节。
  - **组件本地 + localStorage**：布局瞬态（菜单开合、移动菜单、命令面板开关）放在 `useMainLayoutControls.ts` 的组件内 ref（:7-16），其中侧栏折叠持久化到 useLocalStorage("sidebarCollapsed")（:9）；偏好类统一走 useLocalStorage（响应式 ref 包装 + storage 事件跨标签同步，`composables/useLocalStorage.ts:80-125`）。
  - **服务端**：插件列表（pluginApi.getPlugins）、通知内容（WebSocket，见第 3 节）来自服务端；主题、侧栏偏好等全部本地。

## 2. 弹窗、浮层与菜单

### BaseModal：自研弹窗基座

`src/components/ui/BaseModal.vue` 是页面级内容弹窗的公共底座，消费方 11 处（EmojiGallery 预览、ImageCacheEditor、ThemeEditor 导入/另存、ToolCallRecordsManager 详情、ThinkingChainsEditor、ToolboxManager、GlobalCommandPalette、rag-tuning 两个分析弹窗、DailyNotesManager/PlaceholderViewer 子弹窗等）：

**Portaling。** 用 Teleport 默认挂到 body（:35），外层套过渡动画（:3-11）；面板与遮罩 attrs 通过作用域插槽交给业务层（overlay-attrs/panel-attrs/panel-ref，:61-73）。

**遮罩与 Esc。** 遮罩点击要求事件目标与遮罩自身相等（点击面板内部不关，:128-138）；Esc 经 overlay 的 onKeydown 处理（:140-145）；两者都受 closeOnBackdrop/closeOnEscape props 控制（默认均 `true`，:36-40）。

**焦点管理。** 打开时记录 previousActiveElement，nextTick 后聚焦面板内第一个可聚焦元素（:94-102,177-200）；Tab 在首尾元素间循环（getFocusableElements 用标准选择器过滤 disabled，:75-92,147-175）；关闭时把焦点归还给触发元素（:194-197）。

**滚动锁定。** `document.body.style.overflow = "hidden"` 并保存原值、卸载时恢复（:104-121,202-204）；注意应用本身已锁定 body 滚动，此机制影响的是与页面滚动区域的交互。

**层级。** 遮罩 `z-index: var(--z-index-modal)`（10000，:211）。

**缺陷边界（静态）。** 嵌套弹窗时两套独立 focus trap 并存的行为未运行验证。

### 命令式 confirm/input：feedback 平台

**总线可替换。** `platform/feedback/feedbackBus.ts` 定义 FeedbackSink 接口（showLoading/showMessage/askConfirm/askInput，:26-35），默认 noopSink 回退到原生 `confirm/prompt`（:37-58），`main.ts:20` 替换为 feedbackState 实现——业务代码只依赖总线，不依赖组件。

**状态与队列。** `feedbackState.ts` 用模块级 reactive 单例承载 loadingCount/message/confirm/input 四个通道；confirm 与 input 都是 **Promise + 队列**（askConfirm 返回布尔结果的 Promise 入队，:220-229，openNextConfirmRequest 一次只展示一个，:156-173；

input 同理，:255-296），上一请求 settle 后 setTimeout(0) 开下一个（:185-188）。

**渲染层。** `FeedbackHost.vue`（挂在 MainLayout :86）把四个通道渲染为全屏 loading 遮罩、右上角 message 弹条、ConfirmDialog、InputDialog。
- **ConfirmDialog 与 InputDialog 是独立实现**，不用 BaseModal：均为 Teleport to body + 自己的 overlay（:82-93、:135-146）。

  差异点：InputDialog 有 Esc 关闭（`InputDialog.vue:11`）、Enter/Ctrl+Enter 提交（:25-26,36）、打开时聚焦并全选输入框（:109-118）；

  **ConfirmDialog 静态代码中未绑定任何 Esc 处理**（模板只有遮罩点击取消，:10），两者也都没有 Tab 焦点陷阱与滚动锁定——即命令式对话框的键盘关闭与焦点圈与 BaseModal 不一致（运行表现未验证）。层级均为 `calc(var(--z-index-modal) + 1)`（10001，:86/:139），在 BaseModal 之上。

### 下拉菜单、抽屉与命令面板

- **顶栏下拉**（系统/用户菜单）：`TopBar.vue:114-170` 手动开关两个 `.dropdown`，关闭路径有三条：文档级 click 监听（`useMainLayoutDomEffects.ts:113-118` 匹配 `.dropdown` 之外点按）、MainLayout 的 `.dropdown-backdrop` 遮罩（:110-114，z-998）、全局 Esc（`useMainLayoutDomEffects.ts:127-141`）。

**通知抽屉。** `NotificationsDrawer.vue` Teleport 到 body，backdrop 点击关闭（:4-9），`role="dialog"` aria-modal（:15-18），见第 3 节。

**全局命令面板。** `GlobalCommandPalette.vue` 用 BaseModal 承载，`Ctrl/Cmd+K` 唤起、Esc 关闭（`useMainLayoutDomEffects.ts:121-125`），结果区 `role="listbox"` + 行 `role="option"` + aria-activedescendant（:34,56-78），空结果有专属空态（:46-54）。

**主题快捷抽屉。** `ThemeQuickDrawer.vue` 自带 Teleport + scrim 关闭 + @keydown.esc（:2-17）。

**未找到。** 上下文/右键菜单处理（@contextmenu 全 src 零命中）、公共 Tooltip/Popover 组件（仅 `Dashboard.vue` 一处 CSS 自绘 `role="tooltip"` 提示，:14,899-935）——按 Grep 范围 `AdminPanel-Vue/src` 计。

## 3. 通知、加载态与错误反馈

**message-popup（Toast）。** 单条覆盖式（新消息直接替换旧消息，非堆叠），默认 3500ms 自动消失（`feedbackState.ts:75`），带 id 防竞态（:201-217）；四种类型用左侧色条区分（`FeedbackHost.vue:175-189`）；`role="status"` + `aria-live="polite"`（:14-23）；移动端变全宽（:191-208）。位置固定右上（`top: 80px; right: 30px`，:140-156）。

**全局 loading。** FeedbackHost 全屏遮罩 + spinner（`role="status" aria-busy`，:2-12），`showLoading(true/false)` 计数式开关（`feedbackState.ts:190-194`）。

**API 层自动反馈。** `src/api/requestWithUi.ts` 包一层 executeRequest——默认 showLoader: true（:24-28），即 `api/*.ts` 中 80 余处 requestWithUi 调用（Grep 命中 81 处，含函数定义本身）默认每次请求都会闪现全局 loading；

失败自动 showMessage(error, "error")（:76-84），TypeError 映射为"网络请求失败"（:39-49），abort 与 401（isAuthError）抑制提示。可选 loadingKey 走 `stores/loading.ts` 的 **key→引用计数**（`start/stop`，:9-21），支持并发多次同一操作互不误关（80+ 处使用）。

**组件级请求。** `useRequest.ts` 提供 `data/isLoading/error` + AbortController 取消（:85-90）+ 默认 3 次指数退避重试（:110-131）+ 组件卸载自动取消（:167-171），与全局反馈解耦。

**通知中心（站内通知）。** `stores/notifications.ts` 经服务端鉴权接口拿 wsUrl 后建 WebSocket 连接（:392-420），带 2s→30s 指数退避自动重连与手动断开标记（:62-63,309-324）；

消息解析出 vcp_log / daily_note_created / 工具审核请求等类型（:70-273），列表上限 200 条（:61），未读按 `receivedAt > lastViewedAt` 计算（:288-295）。

抽屉内 tool_approval_request 卡内嵌"允许/拒绝 + 原因 textarea"，响应经同一 WebSocket 回发（`NotificationsDrawer.vue:85-109`，`notifications.ts:470-498`）。顶栏铃铛显示未读角标（`TopBar.vue:96-111`）。

**空状态。** 公共 UiEmptyState（icon/title/description/action 插槽）；页面级空态各自实现（Dashboard 无卡片、通知抽屉"暂无通知"、命令面板"没有匹配的结果"）。

**错误边界。** **本次未找到**应用级错误边界——onErrorCaptured/ErrorBoundary 全 src 零命中。错误呈现为：全局 toast + 页面内 UiAlert（如 `Login.vue:65-71`）+ store error 字段（`auth.ts:11,119-121`）。

**骨架屏。** 无公共骨架组件；仅 `EmojiGallery.vue` 页面内自实现骨架网格（:259-275,604-605，hasLoadedOnce 控制只在首次加载显示，shimmer 动画 :1929）。

**服务端交点。** 通知内容、插件列表等来自管理 API/WebSocket；本类目不评价业务反馈语义（归各业务笔记）。

## 4. 主题、视觉 token 与持久化

**权威源与持久化。** 全部主题状态在 **localStorage**（`themeEngine.ts:8-18` 列出全部键），无服务端存储、无系统跟随。模式选项只有 `dark`/`light`（THEME_MODE_OPTIONS，`themeEngine.ts:36-39`）；prefers-color-scheme 仅出现在 `assets/vite.svg` 资产内的 CSS（Grep 依据），JS 中零使用。

**首屏防闪烁。** `index.html:11-21` 内联脚本在应用加载前读 localStorage.theme（兼容旧裸字符串，`stores/app.ts:39-54`）设 data-theme 与浏览器主题色 meta。

**token 体系。** `style/index.css` 用 OKLCH 定义 `--*-dark`/`--*-light` 两套变量，:root 默认暗色（:5-56），`html[data-theme="dark"/"light"]` 把语义别名（`--primary-bg` 等）切到对应套并同步 color-scheme（:237-334）；

另有 z-index（:161-169，`--z-index-modal:10000` 等）、圆角、4pt 间距、流体字号 `clamp()`（:202-229）、`--app-viewport-height` 默认 100dvh（:231-235）。
- **预设与自定义引擎**（`src/features/theme-editor/themeEngine.ts` + `src/style/theme-presets.css`）：**17 个预设**（`themeEngine.ts:146-302`），其中 7 个的色板由色相函数生成 8 个变量（:133-144），editorial-graphite/anthropic 等为特制；

  色板实际渲染不靠行内变量，而是 applyThemePreferences 写 data-theme-preset 属性（:895-903）命中 `theme-presets.css` 的 `html[data-theme-preset="..."]` 属性选择器（含 editorial-graphite 的 `[data-theme="light"/"dark"]` 明暗复合选择器与 color-mix 值，:7-224）；

  radius/scale/font/contentLayout/shellLayout 各档的具体 CSS 规则也全部在 `theme-presets.css:226-306`。可编辑颜色变量分组（:323-573）；

  应用路径 applyFullTheme（:942-951）＝ 行内 setProperty 颜色覆盖（:804-811）+ data-theme-* 属性（setBodyAttribute 同时写 html 与 body，:879-889）+ 自定义 CSS 注入 `<style id="vcp-custom-theme-css">`（:823-835）+ 背景图注入 `<style id="vcp-custom-theme-bg">`（目标 `.admin-layout`，:858-872）；

  支持主题 JSON 导入导出（:763-800，导入只接受合法 CSS 变量名与字符串值）与用户主题收藏（customThemeUserThemes，`ThemeEditor.vue:795-847` 的另存命名/应用/删除管理，id 为 `user-${Date.now()}`）。

**编辑器运行时变量发现与结构 token 锁。** `ThemeEditor.vue` 挂载时 refreshGlobalCssVars（:1282-1292）用 getComputedStyle 枚举 :root 全部 `--*` 变量，按关键字启发式归入内建分组与 10 个扩展分类（resolveGlobalVariableCategoryId，:1030-1102）；

LOCKED_THEME_VAR_RULES（:951-976）把以下前缀类结构 token 锁为只读"受保护变量"（模板 :427-440 展示锁定原因），其余非内建变量以文本输入可调：
- `--z-index-`、`--app-*`、`--space-*`
- `--font-(fluid|size|mono)`、`--transition-`、`--switch-`

改动命中当前预设或用户主题的变量时会自动清除预设标记（:1421-1445）。

**自定义 CSS 的页面定位锚点。** 路由页根组件统一带 data-page 属性（`MainLayout.vue:80`），自定义 CSS 可用 `[data-page="..."]` 选择器按页覆盖（编辑器内置说明文档 `ThemeEditor.vue:576-599`，`index.css:892-898` 亦有 `#config-details-container > [data-page]` 规则）。

**存储容量边界。** saveThemeSnapshot 对背景图写入返回失败（safeSetItem try/catch，`themeEngine.ts:104-112,749-761`）时，编辑器提示"背景图片过大无法存储到本地，请使用 URL 方式设置背景"（`ThemeEditor.vue:1582-1587`）；背景图以 dataURL 或 URL 字符串原样入 localStorage。

**本次未找到。** 主题市场/商店/下载通道（themeMarket/ThemeStore/主题商店类关键词全 `AdminPanel-Vue/src` 零命中，仅存在与主题无关的插件商店 `PluginStore.vue`）；自动色阶/派生色生成器（无 lighter()/shade/tint/derive 类颜色计算，hover 色是独立变量而非由按钮色派生）——按 Grep 范围 `AdminPanel-Vue/src` 计。

**消费链路。** `stores/app.ts` 的 theme（useLocalStorage("theme")，:62-65）watch 后 syncThemeToDom 写 data-theme + syncBrowserThemeColor（:81-98，后者从计算样式取 `--primary-bg` 写入 meta，`themeEngine.ts:924-937`）；

启动时 `applyActiveTheme()` 恢复完整快照（`app.ts:101`）。

设置入口两个：`views/ThemeEditor.vue`（完整编辑器：预设/颜色/圆角/密度/字体/宽度/外壳布局/导入导出）与顶栏 `ThemeQuickDrawer.vue`（快捷切换），两者经 THEME_SETTINGS_CHANGED_EVENT 自定义事件互知变更（`themeEngine.ts:710-713`，`ThemeEditor.vue:1705-1726`）。

**跨标签同步。** useLocalStorage 默认监听 storage 事件（`useLocalStorage.ts:101-125`），主题/侧栏等偏好跨标签页自动同步；无多窗口概念（单 SPA）。

**第三方组件接入。** EasyMDE/CodeMirror 通过深样式选择器接 CSS 变量主题（`DailyNotesManager/DiaryEditor.vue:140-349` 的 :deep(.EasyMDEContainer ...)，含 `:root[data-theme="light"]` 分支）。

## 5. 响应式、移动端与窗口适配

**断点。** 无统一断点 token；CSS 媒体查询散布于布局与各页面（768/480/1024/1280 最常见，如 `MainLayout.vue:618-695`、`FeedbackHost.vue:191-208`、`Sidebar.vue:298-330`）。

应用级唯一 JS 断点是 `MOBILE_LAYOUT_MEDIA_QUERY = "(max-width: 768px)"`（`useMainLayoutDomEffects.ts:8`）：监听 matchMedia change，回到桌面宽度时自动关闭移动菜单（:82-84,172-178）。

**视口高度。** syncViewportHeight 用 visualViewport?.height ?? innerHeight 同步 `--app-viewport-height`（:61-73），配合 @supports (height:100dvh) 默认值（`index.css:231-235`），随 resize/visualViewport change 更新。

**侧栏三态。** 桌面端折叠是**手动命令**（顶栏按钮 + useLocalStorage("sidebarCollapsed")，`useMainLayoutControls.ts:9,36-41`），折叠后可 hover 临时展开（悬停状态标志，:11，`Sidebar.vue:6-11,80-82`），不随窗口变窄自动折叠；

移动端（<768px）侧栏切换为抽屉模式（sidebar-overlay 遮罩 + 顶栏汉堡按钮，`MainLayout.vue:47-52,347-365`，`TopBar.vue:6-14`），路由切换与 Esc 都会关闭（closeTransientUi，`useMainLayoutControls.ts:58-63`）。

**布局外壳。** data-theme-shell-layout（inset 默认 / sidebar）改变容器圆角与贴边策略（`MainLayout.vue:320-345`、`TopBar.vue:336-341`、`Sidebar.vue:268-274`），属主题选项而非自动响应式。

**Dashboard 网格。** 两层机制——卡片内容器查询断点（520/420/360/280px，`components/dashboard/dashboard-card.css:207-283`，约 14 个卡片消费）；

网格层用 CSS Grid auto-fit 且通过 getComputedStyle(gridTemplateColumns) 反推列数判定 desktop/tablet/mobile 模式（`Dashboard.vue:319-358`），卡片大小 token `desktopCols/tabletCols/rows` 以自定义属性 `--dashboard-card-cols-desktop/-tablet/--dashboard-card-rows` 下发（:309-317），布局持久化于 localStorage（`useDashboardLayoutV2.ts`，含布局迁移 :130-152）。

**移动端路由。** 无独立移动端路由或入口；Login 独立页其余共享同一 shell。

**不适用项。** 浏览器 SPA 无窗口最小尺寸、安全区域（notch）处理；桌面集成类（托盘/系统通知）不适用。

## 6. 图片、附件、拖放与常见内容交互

**图片预览。** **无公共灯箱组件**；`EmojiGallery.vue` 用 BaseModal 自建预览（上/下一张、`1/N（当前页）`计数、@keydown 导航，:398-456）。

图片懒加载有公共机制：全局指令 v-lazy（`directives/lazy.ts`，IntersectionObserver + rootMargin 50px + 共享 observer + 卸载清理），用于 `ImageCacheEditor.vue:113`、`EmojiGallery.vue:339` 的缩略图。

**上传。** **无公共上传组件**，三处各自实现：①`PluginStore.vue`（`/plugin-store`）——HTML5 拖放 drop zone + 压缩包文件选择 + webkitdirectory 文件夹选择 + 安装日志面板（:475-502,538-568），拖放视觉反馈是 isDragging 类名切换；

②`EmojiGallery.vue`——图片/压缩包多选、accept 过滤、上传结果与拒绝列表；

③`ThemeEditor.vue`——背景图管理：URL 输入 + 本地上传（`accept="image/*"`、10MB 上限，:471-477,1533-1566，FileReader 转 dataURL 后交给主题引擎注入）+ Image 探针网络源可用性检测（10s 超时，probeImageSource/checkBackgroundSource，:1470-1525）+ 300ms 防抖实时预览与清除（:1458-1468）；

引擎侧 normalizeBackgroundSource 剥 `url()` 与引号、注入前转义引号与反斜杠（`themeEngine.ts:846-872`）。反馈均走页面内状态 + showMessage + loadingKey，无统一上传进度条。

**拖放（HTML5 vs 指针）。** HTML5 drag 事件全仓仅 `PluginStore.vue:478-480` 三处。

**排序类拖拽统一走 Pointer Events 自研基础设施**：`usePointerDragSession.ts`（激活距离 8px、拖拽幽灵元素、`commitOnPointerCancel/commitOnWindowBlur/commitOnVisibilityHidden` 提交语义，:26-43）被 VcptavernEditor 规则排序、ThinkingChainsEditor 链排序、PreprocessorOrderManager 插件排序消费；

`Dashboard.vue` 则**自实现**一套指针拖拽（重排拖动手柄 :76-78、右下 resize 手柄 :93-98，handleReorderPointerDown/handleResizePointerDown :600-694，getDropPlacementForTarget 计算 before/after 落点，TransitionGroup 过渡）。

`DragHandle.vue` 是公共拖拽手柄外观组件。

**剪贴板。** copyToClipboard（navigator.clipboard → 隐藏 textarea + execCommand('copy') 回退，`utils/ui.ts:26-62`）；消费方如通知卡片"复制原始消息"（`NotificationsDrawer.vue:71-80`）、日志复制（`useServerLogViewer.ts:150-152`，成功/失败 toast）。

**Markdown/代码。** `useMarkdownRenderer.ts` 懒加载 marked + marked-highlight + highlight.js + DOMPurify，消毒配置禁 `style/script/iframe/form/input/button` 等标签与 style 属性（:6-23）；EasyMDE 仅 `DailyNotesManager.vue:149-156` 懒加载使用。

**虚拟滚动。** useVirtualScroll 用于笔记列表与服务器日志（`NoteList.vue:209`、`useServerLogViewer.ts:5`），属列表级工具而非全局机制。

## 7. 扩展调查：无障碍与动画（静态代码结论）

**无障碍静态盘点。** BaseModal 有 `role="dialog"/"alertdialog"` + aria-modal + 焦点陷阱与归还（`BaseModal.vue:61-73,94-102`）；全局 :focus-visible 轮廓（`index.css:380-388`）；skip-link 跳到内容区（`MainLayout.vue:9,207-224`）；

命令面板 listbox/option/aria-activedescendant（`GlobalCommandPalette.vue:34,56-78`）；通知抽屉 `role="dialog"` + aria-live 列表（`NotificationsDrawer.vue:12-18,53`）；loading/message `role="status"` + `aria-live="polite"`。

**静态缺口**：ConfirmDialog/InputDialog 无 Tab 陷阱、ConfirmDialog 无 Esc 路径（见第 2 节）；未发现应用级错误边界（见第 3 节）。未做读屏实测，不据此判定合规性。

**reduced-motion。** prefers-reduced-motion: reduce 覆盖面广（BaseModal/ConfirmDialog/InputDialog/UiButton/UiInput 等 30+ 组件与页面各有一处，如 `BaseModal.vue:231-236`、`layout.css:1150`）。

**动画体系。** 无动画库（无 framer-motion/GSAP）；全部为 Vue 过渡 + CSS（fade/slide/backdrop-fade，`MainLayout.vue:482-513,607-615`）与 @keyframes（spinner、emoji shimmer 等）。

用户级开关 animationsEnabled（localStorage，`app.ts:67`，顶栏系统菜单可切换）控制星空背景（`SolarSystemBg.vue:6`）、Nova 动画（`VcpAnimation.vue:4,453,510,559`）与 dashboard 动画（`useDashboardState.ts:640,742`）。

**桌面集成。** 不适用（浏览器管理台；OpenWebUISub 注入脚本的宿主环境行为见 ChatUI 笔记）。

## 8. 设计取舍与已确认边界

**零组件库路线。** 控件全部手写并直接消费 CSS 变量，无第三方主题适配负担；一致性靠 Ui* 命名约定与 UiSettings* 页面骨架维持（静态推断，未做视觉核验）。

**feedback 总线可替换。** 业务经 FeedbackSink 调用，`main.ts` 才接线到实际实现；未接线时静默回退原生 confirm/prompt（`feedbackBus.ts:37-64`）——机制上允许无 UI 环境调用不崩溃。

**命令式对话框与 BaseModal 能力不对齐。** ConfirmDialog/InputDialog 无焦点陷阱与滚动锁定，ConfirmDialog 无 Esc；静态可见的不一致，运行表现未验证。

**z-index 双轨。** token 声明了 `--z-index-loading:10001`/`--z-index-message:10003`，但 FeedbackHost 用硬编码 9999（loading）/10000（message）（`FeedbackHost.vue:108,150`）；结果（静态推断）：全局 loading 遮罩（9999）**低于** BaseModal（10000）与 confirm/input（10001），即请求中打开弹窗时 loading 不会盖住弹窗。

**主题纯浏览器端。** 不落服务器、不跟随系统；跨标签靠 storage 事件，换设备不迁移。首屏防闪烁靠 `index.html` 内联脚本而非框架能力。

**编辑器对结构 token 的锁策略。** z-index/间距/字号/动效/开关尺寸等体系级变量只读展示而非可调（`ThemeEditor.vue:951-976`），可调面限定在颜色、圆角、密度等外观变量；FullPresetTheme 接口声明了预设级 backgroundImage/customCss 字段（`themeEngine.ts:116-127`），但 17 个预设均未实例化使用（引擎保留的潜在能力）。

**拖放/上传分散。** 无统一上传与灯箱；Dashboard 自实现指针拖拽与 usePointerDragSession 并存两套指针拖拽实现。

**滚动模型。** body 全局锁滚动 + 内容区独立滚动，与移动端抽屉遮罩、弹窗滚动锁定叠加；多滚动容器组合行为未运行验证。

## 9. 未验证事项

- 未运行构建与浏览器实测：焦点陷阱/Esc/滚动锁定的实际表现、嵌套弹窗焦点行为、跨标签主题同步、移动端抽屉、Dashboard 拖拽缩放手感、通知 WebSocket 重连时序、骨架/loading 动画呈现。
- ConfirmDialog 无 Esc、命令式对话框无焦点陷阱的键盘可用性影响未经运行验证。
- 依赖内部行为未下钻：marked/highlight.js/DOMPurify 的安全边界、EasyMDE 编辑器行为、three.js 星空渲染均未阅读库源码。
- 40 个路由页的个别媒体查询与局部空态（如 FinalContextViewer、RagTuning 的 @container nested-shell）未逐页核对。
- 无障碍结论全部基于静态代码，无读屏实测；不据此宣称任何合规级别。
- 主题体系运行面未验证：背景图网络源检测的防盗链/CORS/鉴权行为、取色器 OKLCH→HEX 的 canvas 转换（cssColorToHex，`ThemeEditor.vue:1395-1405`）、dataURL 大背景图的 localStorage 容量边界、变量发现（refreshGlobalCssVars）随预设切换后的枚举完整性，均未经运行验证。
- 声明"无"的能力（右键菜单、系统跟随、错误边界、公共灯箱、主题市场、自动色阶生成）基于 `AdminPanel-Vue/src` 的 Grep 范围，写"本次未找到"，不构成项目级绝对结论。

## 10. 关键源码索引

- `AdminPanel-Vue/src/main.ts`
- `AdminPanel-Vue/src/layouts/MainLayout.vue`
- `AdminPanel-Vue/src/router/index.ts`
- `AdminPanel-Vue/src/app/routes/manifest.ts`
- `AdminPanel-Vue/src/components/ui/BaseModal.vue`
- `AdminPanel-Vue/src/platform/feedback/feedbackBus.ts`
- `AdminPanel-Vue/src/platform/feedback/feedbackState.ts`
- `AdminPanel-Vue/src/components/feedback/FeedbackHost.vue`
- `AdminPanel-Vue/src/components/feedback/ConfirmDialog.vue`
- `AdminPanel-Vue/src/components/feedback/InputDialog.vue`
