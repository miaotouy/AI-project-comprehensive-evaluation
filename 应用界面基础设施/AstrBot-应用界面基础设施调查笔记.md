# AstrBot 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：静态源码核对（Grep + Read），全文阅读 Dashboard 根装配（main.ts/App.vue/FullLayout/plugin/store/theme 链）、逐项核对弹窗/通知/主题/响应式/交互机制，并抽样确认业务消费方（Settings、VerticalHeader、ConversationPage、FileConfigItem 等）；Vuetify 依赖内部行为未下钻源码；2026-08-13 追加主题体系专项核对（`--astrbot-*`/`--v-theme-*` CSS 变量全集、主题市场/导入导出/壁纸/自定义 CSS/字体密度圆角等关键词全量检索）
>
> 调查范围：Dashboard 应用级界面机制（弹窗、通知、主题、布局、响应式、常见内容交互、状态所有权、i18n），含主题体系全量核对（确认无主题市场/导入导出、壁纸背景图、自定义 CSS 能力，检查范围为 `dashboard/src` 全量 grep 与 glob `themes/` 目录）；服务端仅记录与前端界面的交点（静态托管、认证、SSE）；聊天工作台主链交点（Composer 附件/拖放热区/消息区图片预览入口/发送链路）由 [`../Chat UI/AstrBot-ChatUI调查笔记.md`](../Chat%20UI/AstrBot-ChatUI调查笔记.md) 记录，此处不重复；QQ/Telegram 等外部 IM 客户端界面不归本项目所有；未运行服务与界面
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot Dashboard 是 Vue 3.3 + Vuetify 3.7 + Pinia 的 Web 管理台（`dashboard/package.json:18-52`），没有自研组件库或 Design System 层，应用级机制直接消费 Vuetify 全量注册的组件：`v-dialog`（全仓库 100 处以上）、`v-menu`、`v-snackbar`、`v-overlay`、`v-data-table` 等。项目层只有三个真正的公共件：`confirmPlugin`（命令式 `$confirm` 确认对话框，Promise 风格）、`toast` Pinia store（单例 FIFO 队列，由 `App.vue` 全局唯一 Snackbar 消费，无堆叠无更新）、`customizer` store（主题/侧栏偏好，localStorage 持久化）。主题是两套硬编码的 Vuetify theme 对象（PurpleTheme / PurpleThemeDark），支持 light/dark/system 三态，system 跟随由 `main.ts` 注册的全局唯一 `matchMedia` 监听器实现，自定义主色/次色在挂载后直接改写 Vuetify theme 对象（main.ts 与 Settings.vue 两份重复实现）。**本次主题体系核对确认无 AIO Hub 式"完整主题外观系统"遗漏面：无主题市场/导入导出、无壁纸背景图、无自定义 CSS、无字体/密度/圆角设置 UI（关键词全量检索，检查范围见元数据）**；主题消费面为 Vuetify 生成的 `--v-theme-*` CSS 变量被全应用直接使用（100+ 处），`--astrbot-*` 项目变量全集 10 个（含滚动条 6 个），深色适配分散在 `_override.scss`、`_CodeBlockDark.scss`、`_VScrollbar.scss` 三处。图片预览没有公共灯箱，消息列表 4 处各自用 `v-overlay` + `img` 复制实现；拖放/上传是分散实现（聊天热区、配置上传对话框、侧栏定制拖排序）。i18n 为自研 composables 系统，`vue-i18n` 依赖在 package.json 中但源码无导入。全应用未找到 Vue 错误边界（`app.config.errorHandler`/`errorCaptured` 均无匹配），错误处理依赖 axios 拦截器（401 统一登出）+ 业务内 try/catch + toast。

## 系统边界与总体装配

- **部署形态**：Python 服务与 Dashboard 同源部署——FastAPI 提供 `/api/*` 并托管静态产物（`astrbot/dashboard/services/static_file_service.py:7-27` 列出 `/chat`、`/config` 等 INDEX_ROUTES 回退到 `index.html`）；开发模式由 vite 代理到 `127.0.0.1:6185`（`dashboard/vite.config.ts:112-117`）。前端用 hash 路由（`src/router/index.ts:9`），服务端无需配置 history 回退。
- **装配链**：`index.html` → `src/main.ts`：`setupI18n()` 完成后 `createApp`，依次 `use(pinia)` `use(router)` `use(print)` `use(VueApexCharts)` `use(vuetify)` `use(confirmPlugin)`，`await router.isReady()` 后 `mount`，再执行 `setupThemeSync`（`main.ts:104-135`）；i18n 初始化失败也有回退挂载路径。
- **根组件**：`App.vue` 只承载 `RouterView` + 三个全局件：`WaitingForRestart`、`UpgradeRecoveryDialog`、全局唯一 `v-snackbar`（消费 toast store，`App.vue:7-17`）。
- **双布局**：`FullLayout.vue`（`v-app` 绑定主题、顶部进度条、VerticalHeader、VerticalSidebar、`v-main`；chat 路由时内嵌 `Chat.vue` 并隐藏侧栏）与 `BlankLayout.vue`（`v-app` + `RouterView`，用于 `/auth/login`、`/auth/setup`、`/chatbox`）。
- **与外部系统交点**：桌面 wrapper（外部 AstrBot Desktop 项目）通过 `window.astrbotDesktop` / `window.astrbotAppUpdater` bridge 注入（类型见 `src/types/desktop-bridge.d.ts`），本仓只消费不实现：`App.vue:51-58` 订阅托盘重启事件、`VerticalHeader.vue` 桌面更新对话框、`src/utils/restartAstrBot.ts` 优先走 bridge 重启后端。服务端交点：`localStorage` token 认证（`src/api/http.ts`）、日志 SSE（`src/stores/common.js:21-145`，断线 2s 重连）、升级恢复 API（`UpgradeRecoveryDialog.vue` 探测版本不匹配）。

## 1. 界面栈、公共组件与状态所有权

- **界面栈**：Vue 3.3.4、Vuetify 3.7.11（`plugins/vuetify.ts` 全量注册 components/directives，`vite-plugin-vuetify` autoImport）、Pinia 2.1.6、vue-router 4（hash）、自研 i18n；辅助库按需使用：monaco（`@guolao/vue-monaco-editor` + workers 配置，`main.ts:12-50`）、markstream-vue（`VerticalHeader.vue:9-11` 顶部 `enableKatex()/enableMermaid()`）、vue3-apexcharts、vue3-print-nb、qrcode。
- **公共组件**：`src/components/shared/` 44 个文件，大多是业务向共享组件（AstrBotConfig、BackupDialog、2FA 系列、Persona 系列等），不属于通用界面基础设施；可跨应用复用的只有 `ConfirmDialog`（命令式确认）、`StyledMenu`（菜单视觉统一）、`QrCodeViewer`、`FileConfigItem`（配置上传）、`ThemeAwareMarkdownCodeBlock`（按主题切换代码块渲染）。
- **状态所有权**（见各章节详述）：

| 状态 | 所有者 | 持久化 | 备注 |
|---|---|---|---|
| toast 队列 | Pinia `stores/toast.js` | 无 | 单例 FIFO，App.vue 单 Snackbar 消费 |
| 主题 uiTheme/themeMode/侧栏偏好 | Pinia `stores/customizer.ts` | localStorage `uiTheme`/`themeMode` | main.ts 双写对齐 |
| 自定义主/次色 | 无 store | localStorage `themePrimary`/`themeSecondary` | Settings.vue 读写，main.ts 启动应用 |
| 认证 | Pinia `stores/auth.ts` | localStorage `token`/`user` | 401 拦截器强制登出 |
| 日志 SSE 缓存 | Pinia `stores/common.js` | 无 | 上限 1000 条 |
| 路由加载进度 | Pinia `stores/routerLoading.ts` | 无 | 模拟进度 |
| 聊天头上下文 | Pinia `stores/chatHeader.ts` | 无 | Chat 工作台向 Header 发状态 |
| 侧栏菜单定制 | localStorage `astrbot_sidebar_customization` | 是 | 唯一跨标签页同步项（storage 事件，`VerticalSidebar.vue:96`） |
| 页面业务状态 | 组件内存 ref / 各自 API | 多数不持久化 | 如 ConversationPage 分页、Settings 分区 |

- **跨窗口同步**：本次未找到 BroadcastChannel 或全站 storage 事件同步（`src` 中仅 `VerticalSidebar.vue:96` 一处 `storage` 监听，用于侧栏定制刷新）；多标签页打开同一 Dashboard 时主题/偏好各自从 localStorage 读取，无实时同步机制。

## 2. 弹窗、浮层与菜单

- **主弹窗机制是 Vuetify `v-dialog` 的直接使用**：grep `<v-dialog`（`src/**/*.vue`）命中 100 处以上（结果被截断），覆盖 ConfigPage、ExtensionPage（13 处）、ProviderPage、SessionManagementPage（6 处）、知识库、persona、平台、共享组件等全部管理页。滚动锁定、Esc 关闭、遮罩点击关闭、焦点管理、`persistent`、`fullscreen`、`scrollable` 等行为均来自 Vuetify 3.7.11 内部实现，本次未下钻依赖源码，标注未核实；项目代码只传属性（如 `persistent`、`max-width`、`@after-enter`）。
- **命令式确认对话框（项目自建）**：`plugins/confirmPlugin.ts` 在应用初始化时把 `ConfirmDialog.vue` 单实例渲染到 `document.body` 挂载节点，暴露 `app.config.globalProperties.$confirm` 与 provide 注入，`open()` 返回 `Promise<boolean>`（`ConfirmDialog.vue:26-34`）；`utils/confirmDialog.ts` 提供 `useConfirmDialog()`（inject）与 `askForConfirmation()`（无注入时兜底 `window.confirm`）。消费方 16 个文件（ConversationPage、Settings、Chat、ProjectList、BackupDialog、PersonaForm、SubAgentPage 等，grep `askForConfirmation|useConfirmDialog` 命中 59 行）。确认框无 `onOk/onCancel` 回调面，只有布尔结果。
- **样式约定被制度化**：`ConfirmDialog.vue:4-9` 的标题类 `text-h3 pa-4 pb-0 pl-6`、按钮 `variant="text"/"tonal"` 与仓库 `AGENTS.md:54` 的 WebUI 对话框规范一致，且在 WaitingForRestart、FileConfigItem、BackupDialog、SidebarCustomizer 等多处对话框重复出现——这是项目层唯一显式的弹窗一致性约束。
- **全屏代码编辑对话框**：`AstrBotConfig.vue:364`、`AstrBotConfigV4.vue:444`、`ConfigPage.vue:88` 用 `fullscreen + transition="dialog-bottom-transition" + scrollable` 的 v-dialog 内嵌 Monaco 编辑器（`AstrBotConfigV4.vue:457-459` 按 `editor_theme` 传 Monaco 明暗主题）。
- **菜单**：`StyledMenu.vue` 包装 `v-menu`，统一卡片样式（毛玻璃、`--astrbot-menu-shadow` 变量、深色主题 `.v-theme--PurpleThemeDark` 覆盖），在 VerticalHeader 功能菜单、语言/主题下拉、登录页复用；项目内另有直接使用 `v-menu` 的子菜单（VerticalHeader 语言/主题分组）。
- **Overlay 浮层**：`v-overlay` 用途分散——图片预览 4 处、`ConfigPage.vue:183-208` 测试聊天抽屉（`location="right"` + `slide-x-reverse-transition`）、`AddNewPlatform.vue:818` 与 `ProviderSelector.vue:215` 的加载遮罩。无统一 Overlay Host 或 Portal 管理，均靠 Vuetify 内部 teleport 到 body。

## 3. 通知、加载态与错误反馈

- **Toast 链路（项目自建，薄封装）**：`stores/toast.js` 是 Pinia setup store，`queue` 数组 + `current = queue[0]`；`App.vue:7-17` 的 `v-snackbar` 用 `v-if="toastStore.current"` 只渲染队首，`snackbarShow` setter 在关闭时 `shift()` 出队。默认 `timeout=3000`、`location='top center'`、`closable`；图标按 color 映射（success/error/warning/info/primary，`App.vue:38-44`）；关闭按钮显式 `aria-label="Close notification"`（`App.vue:15`）。**单条顺序展示，无堆叠、无同 key 更新、无 loading→success 转换、无持久化**（store 源码仅 31 行）。消费入口：`utils/toast.js` 的 `useToast()`（success/error/info/warning 四个便捷方法），业务调用 65 处（grep `toast.`，覆盖 Settings、ConsolePage、FileConfigItem、Chat、T2ITemplateEditor 等）；另有页面局部 `showToast` 惯例（Settings.vue:844、StorageCleanupPanel.vue:82）。
- **路由加载反馈**：`stores/routerLoading.ts` 模拟进度（50ms 步进到 90%，`afterEach` 收尾到 100% 延迟 300ms 隐藏），`FullLayout.vue:100-108` 渲染顶部固定 `v-progress-linear`（z-index 9999）。仅导航切换触发（`router/index.ts:30-34`）。
- **页面加载/空状态/骨架屏**：无公共 Loading 组件。加载以 Vuetify 内联 `v-progress-circular`/`v-progress-linear` 为主（grep 命中 89 处）；`v-skeleton-loader` 仅 `PersonaManager.vue:96` 一处。管理列表有成熟的"三态 no-data"惯例——`ConversationPage.vue:183-200` 的 `v-data-table` no-data 槽按 `listLoadState` 分支：`loading`（转圈）/ `empty`（图标 + 文案）/ `error`（图标 + 重试按钮）。聊天区加载态（消息骨架、运行指示）归 [`../Chat UI/AstrBot-ChatUI调查笔记.md`](../Chat%20UI/AstrBot-ChatUI调查笔记.md) 第 2 节。
- **错误边界**：本次未找到 `app.config.errorHandler`、`errorCaptured` 或 ErrorBoundary 组件（grep 全 `src` 无匹配）；Vue 组件渲染错误会走默认控制台错误，无兜底 UI。HTTP 层有统一拦截：`api/http.ts:50-107` 对 401（非认证接口）清空 token 并跳 `/auth/login`、429 把 `message` 作为 reject 值透传；业务侧模式是 try/catch + `resolveErrorMessage`（`utils/errorUtils.js`）+ toast.error。
- **长任务反馈（独立对话框 + 轮询）**：更新流程（`VerticalHeader.vue`）用 800ms 轮询 `updatesApi.progress` 渲染分阶段下载进度；重启等待 `WaitingForRestart.vue` 每 1s 轮询 `start-time`，60 次上限后提示重试超限；升级恢复 `UpgradeRecoveryDialog.vue` 每 1s 轮询、90 次上限，blocking 模式下 `persistent` 不可关。这类"返回原任务"反馈均为模态对话框而非可堆叠通知。

## 4. 主题、视觉 token 与持久化

- **权威源**：Vuetify theme。定义在 `src/theme/LightTheme.ts`（PurpleTheme）与 `DarkTheme.ts`（PurpleThemeDark），是两份完整的 `ThemeTypes` 颜色对象（`colors` 共 35 个槽位，其中 25 个自命名，如 `lightprimary`、`containerBg`、`chatMessageBubble`、`mcpCardBg`、`codeBg`，另有 facebook/twitter/linkedin 品牌色、gray100/primary200/secondary200 等；`variables` 还有 `border-color`、`carousel-control-size` 两项），**不是 CSS 变量 token 体系**；运行时权威是 Pinia `customizer.uiTheme`，经两条路径生效：`FullLayout.vue:93` 的 `v-app :theme` 绑定 + `main.ts:74` 的 `vuetify.theme.global.name.value` 对齐（供 `useTheme()` 消费者如 StyledMenu、VerticalHeader 的 `isDarkTheme` 判断）。两处都写，避免只改其一导致组件读到的主题不一致（`main.ts:52-60` 注释说明这是唯一注册点，VerticalHeader/ThemeSwitcher 不再自行注册监听器）。
- **三态与持久化**：`config.ts` 定义 `ThemeMode = 'light'|'dark'|'system'`，`checkThemeMode()` 读取 localStorage `themeMode` 并迁移旧版 `uiTheme` 值；`SET_THEME_MODE`（`customizer.ts:43-49`）同时写 `themeMode` 与 `uiTheme` 两个 key。切换入口共四处：`VerticalHeader.vue:877-886` 主题下拉（light/dark/system 三选项）、登录页/设置向导同款下拉（`LoginPage.vue:31-39,174-221`、`SetupPage.vue:18-26,68-114`），以及聊天工作台内的明暗互切按钮 `Chat.vue:309`（`toggleTheme` 于 `Chat.vue:1747-1749` 调 `SET_UI_THEME`，无 system 选项），均调 `SET_THEME_MODE` 或 `SET_UI_THEME` + 同步 `theme.global.name`。
- **system 跟随**：`config.ts:31-38` 的 `resolveUiTheme` 在模块加载期用 `matchMedia('(prefers-color-scheme: dark)')` 计算初始值；`main.ts:61-101` `setupThemeSync` 注册全局唯一 `matchMedia` change 监听器（仅 `themeMode==='system'` 时生效），系统切换即改 store + localStorage + `theme.global.name`。
- **首屏闪烁**：`index.html` 无内联主题脚本（对比常见 dark-mode 方案）；但 `config.ts` 在模块 import 期（早于 `createApp`）已同步解析出 `uiTheme`，`v-app :theme` 首帧即绑定正确主题名，理论上无明暗切换闪烁。存在两个次要闪变窗口（未运行验证）：① 自定义主/次色在挂载后经动态 `import('./stores/customizer')` 才应用（`main.ts:62-89`），首帧可能先渲染默认色；② `setupThemeSync` 对 system 模式"重新用 matchMedia 计算"是为防 SSR/构建偏差（`main.ts:65-71` 注释）。
- **自定义强调色**：`Settings.vue:533-567` 外观分区提供主色/次色取色器（原生 `<v-text-field type="color">`，非 v-color-picker），`applyThemeColors`（`Settings.vue:542-553`）直接改写 `vuetify.theme.themes.value` 中两个 theme 对象的 `primary/secondary/darkprimary/darksecondary` 四个槽位，写入 localStorage `themePrimary`/`themeSecondary`；`main.ts:77-89` 启动时读回应用（与 Settings.vue 为**两份重复实现**，改的是同一批槽位）；`resetThemeColors`（`Settings.vue:1131-1137`）删除两个 key 并还原默认色。无色阶生成、无预设色板。
- **视觉 token**：SCSS 变量层（`scss/_variables.scss`：`$border-radius-root: 8px`、字体栈 `$body-font-family` Outfit/Noto Sans + CJK fallback、`$rounded`/`$typography` map、`$box-shadow`）。`--astrbot-*` CSS 自定义属性全集共 10 个：CJK 字体 `--astrbot-font-cjk-sans/mono`（`_variables.scss:17-18`）、`--astrbot-code-color`（`_variables.scss:19`，深色下被 `_override.scss:104` 重定义）、`--astrbot-menu-shadow`（`_override.scss:85`）、滚动条 `--astrbot-scrollbar-track/thumb/thumb-hover/thumb-active/thumb-border/thumb-shadow` 6 个（`components/_VScrollbar.scss:4-9`，基于 `--v-theme-primary`/`--v-theme-surface` 动态生成，全局 `::-webkit-scrollbar` 与 Firefox `scrollbar-color` 双路径消费）。Vuetify 把 theme 对象生成 `--v-theme-*` CSS 变量，被业务组件与 scss 直接消费（grep `var(--v-theme-` 全 `src` 命中 100+ 处且被截断，含自定义槽位 `--v-theme-secondaryText`、`--v-theme-border`、`--v-theme-mcpCardBg`、`--v-theme-codeBg` 等）——即"JS theme 对象为权威、运行时以 CSS 变量扩散"的混合模式，并非纯对象直连。深色适配不只在 `_override.scss:102-131`（scrim 更黑、surface 背景、代码色、扁平按钮透明度、markdown 链接色），还有两处：`components/_CodeBlockDark.scss:1-18`（shiki 代码块切 `--shiki-dark`/`--shiki-dark-bg`，markstream-vue 重定义 `--border/--background/--foreground/--secondary/--muted/--muted-foreground` HSL 变量）与 `components/_VScrollbar.scss`（无 dark 覆盖段，滚动条颜色直接由 `--v-theme-*` 动态值决定）。
- **本次未找到（检查范围：`dashboard/src` 全量 grep + glob `**/themes/**` 无目录）**：主题市场/商店/下载、主题导入导出（`importTheme`/`exportTheme`/`theme.json`）、`themes/` 主题目录、壁纸/背景图（`wallpaper`/`backgroundImage`/`bgImage`）、自定义 CSS（`customCss`/`userStyle`）、字体切换 UI、密度/圆角设置 UI——均无匹配。`customizer.fontTheme` 与 `inputBg` 虽有 store 字段与 class 绑定但无设置入口（见第 8 节"声而不用"）。
- **第三方组件主题接入**：markstream-vue 渲染组件无主题参数，靠 CSS 类与 Vuetify 变量；`ThemeAwareMarkdownCodeBlock.vue` 按 inject 的 `isDark` 切换 `themeRenderKey` 强制重渲染（`:62`）；Monaco 明暗主题由配置项 `editor_theme` 传入（`AstrBotConfigV4.vue:457`）。
- **字体切换**：`customizer.fontTheme` 默认 `'Noto Sans SC'` 只作为 `v-app` class（`FullLayout.vue:95`）；`SET_FONT` action 存在但本次未找到任何调用方（grep 仅 store 定义与 config 初始值），未确认有可用入口。

## 5. 响应式、移动端与窗口适配

- **断点策略是混合的**：Vuetify display 对象（`$vuetify.display.xs`/`smAndDown`/`lgAndUp`，如 `VerticalHeader.vue:1109` chat 移动端侧栏按钮、`:133-136` 按 `lgAndUp` 计算 header 偏移）+ 组件内手写 `@media`（全 `src` 60+ 处，断点散落 600/640/700/720/760/768/860/900/960/1080/1170/1280/1400px，无统一断点常量或设计 token）。
- **管理侧栏**：桌面为固定 `v-navigation-drawer`，按钮切换 `mini_sidebar` rail 模式（`VerticalHeader.vue:1063-1073`）；移动端走 `Sidebar_drawer` 抽屉（`:1076-1085`）。`VerticalSidebar.vue:110-116` 用硬编码 `window.innerWidth < 768` 判断 `isMobile` 并在初始化时强制抽屉开关状态——移动/桌面判定只发生在组件初始化，窗口在两者间缩放不会自动切换（静态推断）。
- **chat 工作台侧栏**：独立状态 `chatSidebarOpen`（移动抽屉）/`chatSidebarCollapsed`（桌面折叠，`customizer.ts:16-17`），由 `VerticalHeader.vue:150-152` 按钮切换；chat 模式 `v-app-bar` 为 `absolute` 且 `left/width` 按侧栏宽度计算（`:131-142`）。工作台自身布局细节（断点折叠行为）见 [`../Chat UI/AstrBot-ChatUI调查笔记.md`](../Chat%20UI/AstrBot-ChatUI调查笔记.md) 第 1 节。
- **对话框与页面适配**：更新对话框 `:width="$vuetify.display.smAndDown ? '100%' : '920'"`、xs 时 `fullscreen`（`VerticalHeader.vue:1385-1386`）；VerticalHeader 语言/主题分组菜单在 xs 时 `location="bottom"`（`:1229`、`:1289`）；登录页主题菜单固定 `location="bottom center"`（`LoginPage.vue:177-179`）。管理页主体为 `v-container fluid` 流式 + 各页自定 `@media` 列重排。
- **窗口适配**：`index.html:6` viewport meta 禁缩放（`user-scalable=no`）；chat 路由时 `v-main` 强制 `height:100vh; overflow:hidden`（`FullLayout.vue:113-116`）。Dashboard 是浏览器页面，无窗口最小尺寸/安全区逻辑；桌面 wrapper（外部项目）的窗口行为不在本仓。
- **本次未找到**：PWA/service worker/manifest（grep `serviceWorker|manifest.json` 无匹配）；容器查询、`ResizeObserver` 驱动的自动折叠（仅 `VerticalSidebar.vue` 拖拽改宽度 200-300px 是用户手动 resize）。

## 6. 图片、附件、拖放与常见内容交互

- **图片预览无公共灯箱**：4 处独立实现，均为 `v-overlay` + `<img>`：`ChatMessageList.vue:403-415`、`MessageList.vue:261-273`、`StandaloneChat.vue:197-204`、`MessageListDEPRECATED.vue:174-178`；统一形态是 scrim `rgba(0,0,0,0.86)`、overlay 点击关闭、图片 `@click.stop` 阻止关闭。**无缩放/旋转/前后张导航/工具栏**；无共享组件。消息壳中哪些内容触发预览由消息渲染侧决定（[`../消息渲染器/`](../消息渲染器/) 类目范围）。注意 `MessageListDEPRECATED.vue` 仍是旧 Options API 组件，本次未确认其是否被任何路由挂载（grep `MessageListDEPRECATED` 仅在自身文件命中）。
- **二维码生成**：`QrCodeViewer.vue` 用 qrcode 库 `toDataURL` 渲染，`PlatformPage.vue:138` 等消费。
- **上传机制（分散三处，无统一层）**：① 聊天附件 `composables/useMediaHandling.ts`——SHA-256 去重（`:18-36`）、`fileApi.upload` 上传、blob URL staging 预览与 `URL.revokeObjectURL` 清理（`:107-177`），与 Composer 的粘图/录音入口配合，主链归 [`../Chat UI/AstrBot-ChatUI调查笔记.md`](../Chat%20UI/AstrBot-ChatUI调查笔记.md) 第 3 节；② 配置/插件文件上传 `FileConfigItem.vue`——对话框内 dropzone 行（`@drop.prevent` + `dragover` 高亮，`:49-58`）、隐藏 `<input type=file multiple>`（`:61`）、500MB 单文件上限 + 逐文件 toast 警告（`:239-247`）、成功后 toast 反馈（`:280`）；③ 知识库文档上传带百分比进度（`knowledge-base/components/DocumentsTab.vue:32`）。
- **拖放**：聊天区整区拖放热区 `composables/useDragUpload.ts`（`dragover` 判断 `types.includes('Files')`、50ms `dragleave` 防抖、drop 交回调）——聊天主链交点归 Chat UI 笔记；侧栏菜单定制 `SidebarCustomizer.vue` 用 HTML5 原生 DnD 在"主区/更多区"两列表间拖拽排序，结果存 localStorage `astrbot_sidebar_customization`（`utils/sidebarCustomization.js:2`），其他标签页经 storage 事件刷新（`VerticalSidebar.vue:85-98`）。无全站统一 DnD 基础设施。
- **剪贴板**：公共工具 `utils/clipboard.ts`——优先 `navigator.clipboard.writeText`（非安全上下文降级），失败回退隐藏 textarea + `execCommand('copy')`，并恢复原选区与焦点（`:47-91`）；`ThemeAwareMarkdownCodeBlock.vue:42-49` 在非安全上下文时直接走该兜底路径。`copyToClipboard` 还用于 API Key 复制（`Settings.vue:1028-1030`，带成功/失败 toast）等。
- **打印**：`vue3-print-nb` 全局注册为 `print` 指令（`main.ts:111`），具体使用点未展开。

## 7. 扩展调查：动画、无障碍、桌面集成、国际化

### 动画与过渡

无动画库（grep `framer-motion` 等无匹配；Vuetify 自带 JS/CSS transition 体系）。项目显式使用的：全屏对话框 `dialog-bottom-transition`（AstrBotConfig 系列）、抽屉 `slide-x-reverse-transition`（`ConfigPage.vue:187`）、Vuetify 默认 dialog/menu 过渡。手写 `@keyframes` 仅 `scss/_container.scss`（`blink`、`bounce`）与 `_override.scss`（`progress-circular-rotate`）。`prefers-reduced-motion` 仅在 `scss/layout/_sidebar.scss:234-241` 一处（侧栏 rail 过渡禁用），全应用覆盖情况未逐一确认。

### 无障碍（静态代码证据）

无系统性无障碍实现迹象：图标按钮多数靠 `v-tooltip` 提供可见提示，显式 `aria-label` 只在零星处出现（Snackbar 关闭按钮 `App.vue:15`、登录页版本提示按钮 `LoginPage.vue:241`、部分 `:title` 属性如 `VerticalHeader.vue:1155`）。对话框/菜单的焦点管理、Esc、`aria-modal` 等依赖 Vuetify 内部（未核实）。未做读屏实测，全应用审计不在本次范围。

### 桌面集成（本仓仅消费侧）

本仓是浏览器页面，桌面壳（托盘、系统通知、原生菜单、多窗口）由外部 AstrBot Desktop wrapper 实现，Dashboard 只通过 bridge 交互：`window.astrbotDesktop`（`isDesktop`/`restartBackend`/`stopBackend`/`onTrayRestartBackend`）与 `window.astrbotAppUpdater`（`checkForAppUpdate`/`installAppUpdate`），类型契约见 `src/types/desktop-bridge.d.ts`。消费点：托盘"重启后端"事件（`App.vue:51-58`）、桌面模式更新对话框（`VerticalHeader.vue:294-374`，检测到 `isDesktopReleaseMode` 时 `handleUpdateClick` 改走桌面桥）、`restartAstrBot`（`utils/restartAstrBot.ts:31-49`，有桥优先用桥，无桥回退 `statsApi.restart` + 轮询等待）。Dashboard 自身未调用浏览器 `Notification` API（grep `new Notification` 无匹配）。

### 国际化机制

自研 i18n（`src/i18n/composables.ts`）：模块级 `currentLocale` ref + 静态 JSON 翻译（`translations.ts` 汇总 `locales/`，zh-CN/en-US/ru-RU），`useI18n()` 提供 `t()`（点路径 + `{param}` 插值，缺键返回 `[MISSING: key]`）、`useModuleI18n()` 按模块取命名空间；`setLocale` 写 localStorage `astrbot-locale` 并 `dispatchEvent('astrbot-locale-changed')` 通知页面重拉插件 i18n 数据（`:85-100`）。**`vue-i18n` 在 `package.json:46` 声明但 `src` 全量 grep 无 import**（`i18n/types.ts:117-129` 的 `declare module 'vue-i18n'` 已注释），运行时是自研实现。`FullLayout.vue:91` 的 `v-locale-provider` 未绑定语言值，Vuetify 内部组件文案是否跟随切换未验证。

## 8. 设计取舍与已确认边界

- **Vuetify 全量注册、项目层薄封装**：弹窗/菜单/通知/布局机制全部交给 Vuetify，项目自建只有确认框、toast、主题偏好三件套；一致性靠 AGENTS.md 的对话框样式约定（`text-h3 pa-4 pb-0 pl-6` + text/tonal 按钮）而非组件抽象。构建侧为容纳全量注册设置了 `chunkSizeWarningLimit: 1MB`（`vite.config.ts:103`）。
- **Toast 单例串行而非堆叠**：一条 Snackbar + FIFO 队列，后到通知必须等前一条超时/关闭；无更新/取消/持久化能力，长任务（更新、重启）用模态对话框 + 轮询承载。
- **主题双写机制**：`v-app :theme`（声明式）与 `vuetify.theme.global.name`（命令式）双通道对齐，避免 `useTheme()` 消费者读到旧值；代价是切换路径分散在 Header/登录页/设置向导/聊天工作台四处重复实现（Header 与登录页/向导的 `setThemeMode` 为三份相似代码，Chat.vue 的 `toggleTheme` 走 `SET_UI_THEME` 只在 light/dark 间互切）。
- **自定义色不走 token 而是改写 theme 对象**：`applyThemeColors` 直接改 Vuetify 内存 theme 定义，无 CSS 变量层；启动应用晚于首帧（动态 import），存在色值闪变窗口（未运行验证）。该逻辑在 `main.ts:77-89` 与 `Settings.vue:542-553` 重复实现两份，改的是同一批四个槽位。
- **图片预览 4 份重复实现**：无公共灯箱组件；`MessageListDEPRECATED` 为未确认存活的旧组件（同族 `MessageList` 与 `ChatMessageList` 并存）。
- **错误反馈无全局兜底**：无 errorCaptured/errorHandler，渲染期错误无 UI 化；业务错误走 axios 拦截器（401/429）+ 页面 try/catch + toast 的组合。
- **依赖与使用不一致**：`vue-i18n`（未导入）、`Customizer_drawer` 与 `SET_FONT`（store 中无消费方）、`inputBg`（`config.ts:52` → `customizer.ts:15` → `FullLayout.vue:97` 绑定 `inputWithbg` class，但 scss 全库无 `.inputWithbg` 类定义、无 action、无设置 UI，class 绑定无视觉效果）为本次发现的"声而不用"项；`$toast` 全局属性在 `LongTermMemory.vue` 出现（`this.$toast`）但 main.ts 未注册 globalProperties 的 `$toast`——该文件可能走未确认的注册路径或为无效调用，未展开验证。

## 9. 未验证事项

- Vuetify 3.7.11 内部行为（v-dialog/v-menu/v-snackbar 的 Esc、焦点陷阱、滚动锁定、teleport 层级、动画细节）未读依赖源码，不构成已确认事实。
- 主题首帧表现（自定义色闪变窗口）、system 模式跟随切换、移动端断点与抽屉行为的实际运行表现未运行验证；`isMobile = window.innerWidth < 768` 初始化后不随缩放更新的推断基于静态代码。
- 无障碍结论仅含静态证据，未做读屏/键盘实测。
- `MessageListDEPRECATED.vue` 是否仍被挂载、`$toast` 全局属性是否可达（`LongTermMemory.vue`）、`vue3-print-nb` 使用点、`SET_FONT` 是否有隐藏消费方，均未确认。
- 更新/重启/升级恢复轮询流程（`VerticalHeader`、`WaitingForRestart`、`UpgradeRecoveryDialog`）的端到端表现未运行验证；桌面 bridge 的实际存在性依赖外部 AstrBot Desktop 项目。
- `v-locale-provider` 无语言绑定时 Vuetify 内部组件文案是否跟随 i18n 切换未验证。
- 主题对象 25 个自命名色槽与 `variables`（`border-color`/`carousel-control-size`）的实际消费方未逐一核对（抽样确认 `codeBg`、`mcpCardBg`、`secondaryText`、`border` 被业务组件消费）；滚动条 CSS 变量在 WebKit 与 Firefox `scrollbar-color` 两路径的实际渲染未运行验证。

## 10. 关键源码索引

- 根装配：`dashboard/src/main.ts`、`src/App.vue`、`src/plugins/vuetify.ts`、`src/plugins/confirmPlugin.ts`、`src/config.ts`
- 布局：`src/layouts/full/FullLayout.vue`、`src/layouts/full/vertical-header/VerticalHeader.vue`、`src/layouts/full/vertical-sidebar/VerticalSidebar.vue`
- 弹窗与确认：`src/components/ConfirmDialog.vue`、`src/utils/confirmDialog.ts`、`src/components/shared/StyledMenu.vue`
- 通知与反馈：`src/stores/toast.js`、`src/utils/toast.js`、`src/stores/routerLoading.ts`、`src/components/shared/WaitingForRestart.vue`、`src/components/shared/UpgradeRecoveryDialog.vue`
- 主题：`src/stores/customizer.ts`、`src/theme/LightTheme.ts`、`src/theme/DarkTheme.ts`、`src/types/themeTypes/ThemeType.ts`、`src/views/Settings.vue`（外观分区）、`src/scss/_variables.scss`、`src/scss/_override.scss`、`src/scss/components/_VScrollbar.scss`、`src/scss/components/_CodeBlockDark.scss`、`src/config.ts`
- 内容交互：`src/components/shared/FileConfigItem.vue`、`src/components/shared/SidebarCustomizer.vue`、`src/composables/useDragUpload.ts`、`src/composables/useMediaHandling.ts`、`src/utils/clipboard.ts`、`src/components/shared/QrCodeViewer.vue`、`src/components/chat/ChatMessageList.vue`（图片预览）、`src/components/chat/MessageList.vue`
- 状态与网络：`src/stores/auth.ts`、`src/stores/common.js`、`src/stores/chatHeader.ts`、`src/router/index.ts`、`src/api/http.ts`、`src/utils/errorUtils.js`
- i18n：`src/i18n/composables.ts`、`src/i18n/translations.ts`、`src/components/shared/LanguageSwitcher.vue`
- 服务端交点：`astrbot/dashboard/services/static_file_service.py`
