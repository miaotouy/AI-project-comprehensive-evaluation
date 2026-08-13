# DeepChat 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：Grep + Read 静态源码核对（根装配 main.ts/App.vue/ChatMainApp.vue、`src/renderer/services/notifications` 全文、`src/dc-ui` 与 `src/shadcn` 关键组件、theme/appearance 链路、main 进程窗口/托盘/快捷键/上下文菜单、弹窗与拖放消费方抽样），逐条标注相对路径与行号；未运行构建与测试。2026-08-13 追加主题体系专项核对（关键词：主题市场/导入导出、wallpaper/backgroundImage、accentColor/primaryColor 色阶生成、customCss/userStyle、density/compact/radius、字体链路与 `--dc-ease-*`/`--dc-motion-*` token；范围：`src` 全树 + 设置页外观区表面）
>
> 调查范围：应用根装配与多窗口共享、弹窗/浮层/菜单机制（Reka 底层与业务封装、全局 MessageDialog、Spotlight、原生右键菜单）、通知/Toast 体系（NotificationManager/仲裁/策略/语义通知跨窗口路由）、主题与视觉 token（含 2026-08-13 专项核对：主题市场/导入导出、壁纸、强调色引擎、自定义 CSS、密度/圆角、双字体链路、缓动 token 的存在边界）、响应式与窗口适配、图片预览与拖放/剪贴板、状态所有权、桌面集成与无障碍/动画的简要盘点；聊天主链交点（错误 toast、删除确认、附件对话框在 ChatPage 中的消费）由 [`../Chat UI/DeepChat-ChatUI调查笔记.md`](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 记录，本笔记只记录公共机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的界面基础设施是"shadcn-vue（Reka UI）原始组件 + 少量自研 `dc-ui` 业务壳 + 独立通知管理层"的组合：没有 Element Plus/antd/Naive 之类的整装 UI 库，弹窗底层全部是 `@shadcn/components/ui` 对 Reka UI 的薄封装，业务侧以 `DcConfirmDialog`、全局 `MessageDialog`（主进程命令式、Promise 化、带超时自动默认）和组件内 `Dialog` 三种方式消费。最有特色的公共机制是 renderer 侧完整的通知管理层 `NotificationManager`（请求规范化、身份聚合、瞬态/持久仲裁、优先级抢占、策略化的显示预算与生命周期），配合主进程语义通知路由（episode 注册、跨窗口定向投递）和每窗口一个的 vue-sonner `NotificationHost`；`DcToast` 门面已定义但全仓库零消费。主题权威源在主进程 `DesktopSettings`（`nativeTheme.themeSource` + `appTheme` 键），renderer 主题 store 以"先注册监听再取快照 + revision 防竞态"方式订阅 IPC，DOM 投影经 `applyDocumentAppearance` 完成，首帧防闪主要依赖 `show:false + ready-to-show` 与 CSS `prefers-color-scheme` 兜底，未见挂载前内联主题脚本。**主题可配置面刻意收窄**（2026-08-13 专项核对）：用户面只有明暗三态、字号 5 档与正文/代码双字体；主色阶（`--primary-50..1000` 硬编码）、圆角、密度、壁纸、主题导入导出与自定义 CSS 均无用户入口，也不存在主题市场。窗口体系多入口（主聊天窗、设置窗、浮窗聊天窗复用同一 chat-main 入口、悬浮按钮、浏览器浮层），主题/通知/语言均经 IPC 跨窗口同步；侧栏折叠是纯手动开关（无断点驱动），侧栏宽度持久化在 localStorage。

## 系统边界与总体装配

- **界面栈**：Vue 3 + Pinia + `@pinia/colada` + vue-router（hash history）+ vue-i18n；样式 Tailwind CSS v4 + `tailwindcss-animate` + `tw-animate-css`；组件层 = `src/shadcn`（shadcn-vue 原始组件，底层 Reka UI `reka-ui@^2.10.1`）+ `src/dc-ui`（业务公共壳：DcButton/DcConfirmDialog/DcEmpty/DcSkeleton/DcSheetPanel/StatusPill/InlineError 等）+ 业务组件目录。无 Element Plus/antd/Naive；无 framer-motion。`package.json` 依赖确认 Reka UI、vue-sonner、@vueuse/core、@iconify/vue、vue-virtual-scroller、vuedraggable、tippy.js 等在列，但**依赖清单不等于使用证据**，下文的库使用均有源码接入点。
- **渲染入口装配**（`src/renderer/src/main.ts:14-44`）：`bootstrap()` 先 `await createRendererI18n` 并把 `document.documentElement.dir` 设为 rtl/auto（:20），随后才 createApp + Pinia + `PiniaColada`（`staleTime: 30_000`、`gcTime: 300_000`，注释说明 renderer 数据走 IPC、保持热缓存，:27-33）+ router + i18n，`mount('#app')` 后再 setTimeout 预载图标（:39-43）。**挂载前没有主题内联脚本**（见第 4 节）。
- **应用壳**：`App.vue:6` → `ChatMainApp.vue`。壳内固定装配：`TooltipProvider :delay-duration="200"`（:537）→ `AppBar`（无边框窗口标题栏/窗口控制）→ `WindowSideBar` + 主区 `RouterView`（`isStartupRouteReady` 前不渲染，:549）→ 全局浮层栈（:555-573）：`MessageDialog`、`McpSamplingDialog`、`McpElicitationDialog`、`McpAppConsentDialog`、`CliApprovalDialog`、`NotificationHost surface="main"`、`SelectedTextContextMenu`、`TranslatePopup`、`SpotlightOverlay`、`ModelCheckDialog`。工具提示、主题/语言投影、语义通知订阅、快捷键/深链 IPC 也都在壳层接通（`useAppIpcRuntime` :381-421、主题 watch :107-126）。
- **多窗口与多入口**：同一 `src/renderer/src` 代码树被多个入口复用——主聊天窗与设置窗各挂自己的 `NotificationHost`（`ChatMainApp.vue:560` 与 `src/renderer/settings/App.vue:88`）；悬浮聊天窗加载的是**同一个 chat-main index.html 的 `#/chat` 路由**（`src/main/desktop/window/FloatingChatWindow.ts:255-265`，`tabPresenter.registerFloatingWindow` 注册 webContents 桥）；另有 `src/renderer/floating`（悬浮按钮，自建轻量 Vue 根，`floating/main.ts:19-24`，主题经 `floatingButtonAPI.getTheme()` 独立拉取）与 `src/renderer/browser-overlay`（浏览器浮层）两个入口。跨窗口同步走主进程事件广播（主题/语言/设置变更事件），运行时状态（session busy/streaming）为窗口内内存（见 ChatUI 笔记 §1）。
- **状态所有权概览**：弹窗分三类——全局确认 `MessageDialog` 由主进程 `DialogService` 持状态（Promise map）、renderer `dialog` store 只做呈现；业务确认对话框状态在页面局部（`pendingDeleteMessageId` 等）；MCP 采样/许可等系统对话框由各自 Pinia store 持有。Toast 由 renderer 模块级 `NotificationManager` 持有（不依赖组件树），主进程语义通知路由持 episode 注册表。主题权威在主进程 settings store，renderer `theme` store 订阅。UI 偏好（字号、字体、自动滚动等）走主进程 settings 键（`DesktopSettings`）经 IPC 同步（`uiSettingsStore`）。

## 1. 界面栈、公共组件与状态所有权

- **shadcn 原始层**（`src/shadcn/components/ui/*`，49 个目录）：Dialog/AlertDialog/Popover/DropdownMenu/ContextMenu/Tooltip/Sheet/Tabs/Select 等均为 Reka UI 薄封装（例如 `dialog/DialogContent.vue:31-52` 就是 `DialogPortal` + `DialogOverlay` + `DialogContent` + 默认关闭按钮 + Tailwind 动画类）。Reka UI 内部的 Esc、遮罩点击、focus trap、动画、`data-[state]` 类均属依赖库内部行为，本次未下钻 node_modules，一律标为未核实。
- **`dc-ui` 业务壳**（`src/dc-ui/components`，17 个组件目录）：DcButton/DcCopyButton、DcConfirmDialog、DcEmpty、DcSkeleton、DcSheetPanel、StatusPill、ToggleRow、DcTooltip/DcPopover、SectionCard、InlineError、Form/FormActions、Badge、DropdownActionItem、DcToast。其中 `DcToast`（`src/dc-ui/components/toast/DcToast.ts:19-24`）是 `notifyRenderer` 的 success/info/warning/error 门面，但**全仓库检索（`src` 下所有 .vue/.ts）零消费**，仅被自己的 index.ts 引用——属于已导出未接入的过渡组件；实际业务全部直呼 `@renderer-notifications/rendererNotificationPort` 的 `notifyRenderer`（约 33 个文件命中）。
- **状态所有权模式**：通知——renderer 模块级单例 `rendererNotificationManager`（`rendererNotificationRuntime.ts:9-13`），命令入口与渲染 viewport 共享同一 store；主题——主进程权威 + renderer Pinia store 订阅投影；侧栏/侧边面板——Pinia store，宽度与折叠态经 `useStorage` 落 localStorage（见第 5 节）；全局确认对话框——主进程 `DialogService`（见第 2 节）。

## 2. 弹窗、浮层与菜单

### 2.1 三类弹窗消费方式

1. **全局命令式确认 `MessageDialog`**：主进程 `DialogService`（`src/main/desktop/dialog.ts:32-66`）`showDialog()` 生成 `DialogRequest`（nanoid id、按钮、可选 timeout），经 `dialog.requested` 事件发给当前活动窗口；renderer `stores/dialog.ts` 收事件后驱动 `MessageDialog.vue`（shadcn `AlertDialog` 呈现，`MessageDialog.vue:2-49`）。特性：同一窗口同时只有一个 pending 对话框（重复调用会先对旧请求 `handleError`）；`timeout > 0` 且有默认按钮时倒计时（100ms 步进）到期自动按默认键提交（`stores/dialog.ts:23-34`）；按钮文本默认按 i18n 键翻译（`i18n` 标志）。消费方示例：`useMessageActions` 的删除确认经 `DcConfirmDialog`（页面内），而知识库索引重建等主进程侧场景经 `MessageDialog`。
2. **页面内业务确认 `DcConfirmDialog`**（`src/dc-ui/components/confirm-dialog/DcConfirmDialog.vue:55-90`）：包 shadcn `AlertDialog` + 自研 `AlertDialogAsyncAction`（`src/shadcn/components/ui/alert-dialog/AlertDialogAsyncAction.vue`，把动作按钮包成 Button 组件）；props 支持 danger/confirmLabel/busy（内嵌 Spinner）/disabledConfirm。ChatPage 删除消息确认即此组件（`ChatPage.vue:302-312`，状态 `pendingDeleteMessageId` 在 useMessageActions 内，`useMessageActions.ts:59`）。
3. **组件内 `Dialog`**：图片全屏查看（`MessageBlockImage.vue:31-63`）、fork 确认（`MessageItemAssistant.vue:202-218`，legacy 路径）等，直接使用 shadcn Dialog 原始件。

### 2.2 层级、Portal 与关闭机制

- **Portal**：shadcn `DialogContent` 经 `DialogPortal` 投到 body（`dialog/DialogContent.vue:31`）；Spotlight 自行 `Teleport to="body"`（`SpotlightOverlay.vue:2`）；SidePanel 全屏模式不投 body，直接在布局内提升 `z-index: var(--dc-z-sidepanel)`（`ChatSidePanel.vue:167-171`）。
- **z-index 契约**：`style.css:134-146` 定义统一堆叠刻度 `--dc-z-*`（base 0 < sticky 10 < float 20 < sidepanel 30 < popover 50 < spotlight 90 < modal 100 < toast 1000），注释明确"tooltip/popover 用 --dc-z-popover，永远不用 --dc-z-toast"。shadcn 原始 Dialog 默认 `z-50`（等价 --dc-z-popover），`PromptParamsDialog` 显式提到 `--dc-z-modal`（100）；`--dc-z-toast`（1000）由 NotificationHost 消费（`NotificationHost.vue:39`）。
- **Esc / 遮罩 / 焦点**：shadcn Dialog/AlertDialog 的 Esc 关闭、遮罩点击、焦点陷阱与归还均来自 Reka UI 默认行为，封装层未覆盖（`dialog/DialogContent.vue` 无 `@escape-key-down` 等透传），**Reka 内部行为未下钻，不写成已确认事实**。Spotlight 是自实现：Esc/ArrowUp/Down/Home/End/Enter 在 `handleKeydown` 处理（`SpotlightOverlay.vue:201-240`），`@mousedown.self` 点外层关闭（:8），打开时 `focusInput` 聚焦输入框（:143-148），无 focus trap（Tab 可穿透，未验证实际影响）。应用级还有一个 window keydown Esc 处理器，仅用于关闭浮窗聊天窗（`ChatMainApp.vue:424-428` `handleEscKey` → `windowClient.closeFloatingCurrent`）。
- **浮层嵌套**：`ChatPage` 的 plan/question 浮层、交互遮罩等是页面内定位元素（`--dc-z-float`/`--dc-z-sticky`），不是 Portal；本次未发现显式的"弹窗内再弹浮层"的重投影机制（对照 Cherry/Hermes 的做法），Reka 嵌套浮层行为未验证。

### 2.3 菜单与右键菜单（两条并行通道）

- **原生右键菜单（主进程通道）**：`src/main/desktop/contextMenu.ts` 在每个 tab webContents 上挂 `context-menu` 事件，用 Electron `Menu.buildFromTemplate` 弹系统菜单（复制/翻译/问 AI/图片另存等，`contextMenu.ts:46-322`）；翻译与问 AI 经 `contextMenu.translateRequested`/`contextMenu.askAiRequested` 事件发回 renderer，由 `SelectedTextContextMenu.vue:26-35` 转成 window 级 CustomEvent（`context-menu-translate-text` / `context-menu-ask-ai`），`TranslatePopup` 与 ChatPage 事件桥（`useChatPageEventBridge.ts:69,86`）分别消费。托盘菜单与浮窗按钮菜单同样走主进程 Menu（见第 7 节）。
- **Renderer 自绘右键菜单（Reka ContextMenu）**：消息助手气泡（`MessageItemAssistant.vue:1-200` 新路径）、图片（`ImageActionContextMenu.vue:3-15`，复制/保存，经 `useImageActions`）、工作区文件树（`WorkspaceFileNode.vue:4-45`）。注意 `MessageItemAssistant` 的 `useLegacyActions` 默认 `true`（`MessageItemAssistant.vue:367`），默认路径仍是 legacy 行为（无 Reka 右键菜单，`handleContextMenuOpen` 直接 return，:592-597）；`MessageListRow.vue:36` 显式传 `use-legacy-actions="false"` 才启用 ContextMenu 路径。消息正文选中文本的"复制/引用"等操作在两种路径下的差异未逐一验证。
- **下拉菜单**：业务大量用 shadcn `DropdownMenu`（侧栏项目分组、ChatStatusBar、ChatTopBar、EmojiPicker 等，约 30+ 文件命中），均为 Reka 薄封装。

## 3. 通知、加载态与错误反馈

### 3.1 Toast/通知：三层结构

1. **渲染层 = vue-sonner Toaster + 自研通知管理层**。`NotificationHost.vue:44-58` 每窗口挂一个：位置 top-right、`visible-toasts: 2`、`expand: true`、gap 10、`close-button: false`、主题/方向/`container-aria-label` 透传，主窗口 top offset 96、设置窗 52（:15），宽度 `min(356px, calc(100vw - 32px))`，样式变量映射到 `--dc-notification-*` 与 `--popover` 等 token（:22-40）。业务侧经 `rendererNotificationPort.ts:5-16` 的 `notifyRenderer(request)` 入队。
2. **管理层 = `NotificationManager`**（`src/renderer/services/notifications/notificationManager.ts:64-555`）：请求归一化（`notificationRequest.ts`）→ 按 identity 聚合（同 identity 二次 notify 合并计数/成员，:204-251，contract 变化抛错）→ 交仲裁器。**瞬态仲裁**（`notificationArbitration.ts:23-133`）：单 active + 单 candidate；新通知优先于 active 则抢占（旧 toast 以 `preempted` 关闭），否则 warning/error 降为 candidate（8s 新鲜度，到期丢弃），success/info 低优先级直接关闭（记录 diagnostic）。**持久仲裁**（:135-298）：actionable 队列容量 3、TTL 10 分钟、按优先级+顺序排序；progress 按 operationId 单例、可被 actionable 抢占；progress 手动关闭是 `suppress` 而非移除（:185-196）。**策略层**（`notificationPolicy.ts` + `src/shared/notifications/notificationPolicy.ts:15-36`）：displayBudget 2.4s/4s/6s/8s、maxLifetime 15s/30s/45s/60s（success/info/warning/error）；success/info 无 key 时用 sonner 原生 toast（`content: 'native'`），带 key 或 warning/error 用托管组件。
3. **呈现层 = `SonnerNotificationPresenter`**（`sonnerNotificationPresenter.ts:14-72`）：native 内容走 `toast.success/info`（warning/error 无 native，:71 抛错），托管内容 `toast.custom(ManagedNotificationToast)`。`ManagedNotificationToast.vue` 订阅 `ObservableNotificationRecord`（:18-21），按 kind 显示图标/颜色、occurrence ×N 徽标、pending +N 徽标、action 按钮（点击防重入、失败内联提示、成功后关闭）、progress 进度条（indeterminate 动画）；aria：error/warning/actionable 为 `role="alert"`，其余 `role="status"`（:103-107），progress 有完整 `role="progressbar"`（:178-183），含 `prefers-reduced-motion` 关闭动画（:415-421）。**默认时长由展示预算 + sonner lifecycle 控制，error/warning 的展示预算为 6s/8s，不是"永不消失"**（与 Cherry 的 error 常驻不同）。

### 3.2 主进程语义通知路由（跨窗口）

- 主进程 `WindowNotificationRouter`（`src/main/notifications/windowNotificationRouter.ts`，装配于 `src/main/app/composition.ts:671-712`）维护 episode 注册表（`src/shared/notifications/episodeRegistry.ts`），事件源（MCP 连接失败/工具列表失败、provider 深链失败、数据库安全修复建议，schema 见 `semanticNotification.ts:26-52`）经 `occur/recover` 入路由，按目标窗口兼容性（main/settings）与 focus 状态选目标，经 `semanticNotificationEvent` IPC 投递（`electronWindowNotificationTargets.ts:131`）；renderer 侧 `SemanticNotificationController`（`semanticNotificationController.ts:56-114`）把 episode 映射回 `NotificationManager` 请求（含 action、ack、recover 绑定），如 `databaseSecurity.repairSuggested` 是 `retention: 'until-resolved'` 的 actionable，点动作开设置窗数据库修复页。这是 renderer 内通知与"主进程跨窗口定向通知"的唯一对接层。
- **系统通知（Electron Notification）是另一条独立通道**：`src/main/desktop/notification.ts:14-48` `NotificationService.showNotification`（受 `notificationsEnabled` 开关控制），点击经 `appRuntime.systemNotificationClicked` 广播，renderer `useAppIpcRuntime.ts:63-65` 收事件并跳转到对应会话（`ChatMainApp.vue:404-419`）。业务触发点在主进程侧（远程/循环事件等），renderer 不直接发系统通知。

### 3.3 加载、空状态与错误反馈

- **聊天首屏加载**：`ChatPage.vue:111-122` `isSessionViewPreparing` 时铺 `ChatSessionSkeleton`（`ChatSessionSkeleton.vue`，三条伪消息骨架，容器 `aria-hidden="true"`，外层 `role="status" aria-live="polite" aria-busy="true"`），层级 `--dc-z-sticky`。
- **历史翻页加载/失败**：顶部粘性 pill（`ChatPage.vue:53-85`）：`isLoadingHistory` 显示 `common.loading`；`historyLoadError` 显示错误 + 重试按钮（`role="alert"`）。
- **通用骨架/空态**：`DcSkeleton`（`src/dc-ui/components/skeleton/DcSkeleton.vue:33`）与 `DcEmpty`（`src/dc-ui/components/empty/DcEmpty.vue:25-47`，图标+标题+描述+action slot、虚线边框）是 dc-ui 公共件；`DcEmpty` 在设置/插件页等 11 个文件消费。Spotlight 空态/加载态用 Spinner + `search-x` 图标（`SpotlightOverlay.vue:91-107`）。图片加载中在 `MessageBlockImage.vue:23-25` 用 Spinner。
- **错误边界**：renderer **未找到**应用级 `app.config.errorHandler`、`onErrorCaptured`、`window.onerror`/`unhandledrejection`（搜索范围：`main.ts`、`App.vue`、`ChatMainApp.vue`、`composables/`、`foundation/`）。错误反馈是分场景的：消息执行错误走消息块 `MessageBlockError.vue`（可折叠、`aria-expanded/aria-controls`）；设置页表单错误走 `DcInlineError`；瞬态操作失败走 `notifyRenderer({kind:'error'})` toast（33 个消费文件）。`bootstrap().catch` 只打 console.error（`main.ts:46-48`）。即"组件级错误呈现有、应用级错误边界无"。
- **加载中的阻塞反馈**：发送中 Composer 前置准备条 `role="status" aria-live="polite"` + Spinner（`ChatInputBox.vue:32-41`）；设置页路由切换 `aria-busy` + Spinner（`settings/App.vue:50-59`）。

## 4. 主题、视觉 token 与持久化

### 4.1 权威源与链路

- **主进程权威**：`DesktopSettings`（`src/main/desktop/settings.ts:47-77`）持 `appTheme` 键（默认 `system`），启动 `initializeTheme` 设 `nativeTheme.themeSource` 并监听 `nativeTheme.on('updated')`（仅 system 模式响应）→ 广播 `config.systemTheme.changed`；`setTheme` 写设置 + 广播 `config.theme.changed`（payload 含解析后的 `isDark`）。渲染层只是订阅者。
- **renderer store**（`src/renderer/src/stores/theme.ts`）：VueUse `useDark`/`useToggle` 管 `isDark`；`initTheme` 特意**先 `setupThemeListeners()` 再 `getThemeState()` 取快照**，并用 `stateRevision` 防"快照返回前事件已更新"的竞态（:53-76 注释"先注册监听再读快照，避免另一窗口的更新丢失"）；`setThemeMode` 乐观置 mode + revision 校验（:78-87）。`cycleTheme` 提供 light→dark→system→light 循环。主题初始值：store 默认 `themeMode='system'`、`isDark` 初始值来自 VueUse `useDark` 默认行为（内部实现未下钻）。
- **DOM 投影**：`applyDocumentAppearance`（`src/renderer/src/foundation/appearance/documentAppearance.ts:33-96`）给 html/body 加减 `light`/`dark` 类（含可选 `data-theme`）、字号类（`text-xs`..`text-2xl`）、`lang`/`dir`；跨主题切换时加 `dc-theme-switching` 类一帧（:52-57,85-95），CSS 里该类的规则是 `transition: none !important`（`style.css:904-910`，注释：避免上百个元素同时触发颜色过渡导致的重绘卡顿）。`ChatMainApp.vue:107-126` 与 `settings/App.vue:626-645` 各自 watch 主题+字号并以 `disableThemeTransition` 首帧禁用过渡。
- **首屏防闪烁**：主/设置窗口均 `show: false` + `ready-to-show` 才显示（`src/main/desktop/window/index.ts:652,697-707` 与 :1308-1311）；`index.html` 无内联主题脚本；CSS 提供 `@media (prefers-color-scheme: dark)` 的 `:root:not(.dark):not([data-theme=...])` 兜底（`style.css:293-345`）——即 system 模式首帧与媒体查询一致；若用户保存的是与系统相反的固定主题，IPC 快照返回前可能有一帧媒体查询色（静态推断，未运行验证）。

### 4.2 视觉 token 与第三方接入

- **token 布局**（`style.css`）：`:root` 定义 Shadcn 语义变量（`--background/--foreground/--card/--popover/--primary/--muted/...`，:69-114）与 `--dc-*` 私有层（字体族 :23-27、motion 时长 :123-125、ease 缓动 :126-127、模糊 :130-132、z 刻度 :134-146、通知四色 :154-165）；`.dark`/`[data-theme='dark']` 覆写（:221-291）；`--dc-font-scale` 由 `html.text-*` 字号类驱动（:198-218），`--radius` 系列与 `--animation-*`（:110-121）供 shadcn 组件使用。`@custom-variant dark` 绑定 `.dark`/`[data-theme='dark']`（:16）。
- **主色阶（静态预设，非引擎）**：`--primary-50`..`--primary-1000` 共 11 级硬编码 hsl（`style.css:41-52`），`--ring`/`--chart-*`/`--sidebar-primary` 引用之（:95-108）；本次未找到动态色阶生成、`accentColor`/`primaryColor` 设置键或用户主色选择（2026-08-13 专项核对，见 4.3）。
- **缓动与时长 token**：`--dc-ease-out-express` cubic-bezier(0.16,1,0.3,1) 与 `--dc-ease-out-soft` cubic-bezier(0.22,1,0.36,1)（`style.css:126-127`），配合 `--dc-motion-fast/default/slow`（140/220/320ms，:123-125）被 `--animation-*`（:116-121）与组件过渡（:916,926,1107）统一消费。
- **字体（双字体体系，正文/代码分离）**：renderer 侧 `useFontManager` 把设置里的字体栈写到 `document.documentElement.style` 的 `--dc-font-family` 与 `--dc-code-font-family` 两个变量（`useFontManager.ts:7-10`），正文组件引用前者（`style.css:921`）、代码块引用后者（:950）。主进程侧 `FontSettings`（`src/main/desktop/fontSettings.ts`）是权威：`fontFamily`/`codeFontFamily` 两个设置键（`settingsStore.ts:32-33`，装配于 `composition.ts:858`，变更经 `settingsRoutes.ts:107-110` 处理）；`getSystemFonts` 用 `font-list` 检测系统字体并缓存（`normalizeFontNameValue` 去 Regular/Bold 等变体名，:5-21,47-65）；写入前 `normalizeStoredFont` 做白名单（剔除 `;:{}()[]<>`、引号/反引号/换行，截断 100 字符，:77-91）。renderer 侧 `buildFontStack`（`src/renderer/src/lib/fontStack.ts:7-13`）把自定义字体与默认回退栈（正文 Geist 系、代码 JetBrains Mono 系）拼接；设置 UI `FontSettingsSection.vue`：正文/代码两个 Popover 搜索选择器 + 各字体预览 + 重置按钮 + 系统字体加载态（检测失败时回退内置字体列表，:237-260），系统字体随设置快照下发（`settingsRoutes.ts:242`）。
- **第三方接入主题**：vue-sonner Toaster 由 `toasterTheme` computed 传 `theme` prop（`ChatMainApp.vue:102-104`，system 模式解析成具体明暗）；Reka 组件通过 Tailwind dark 变体与语义变量自然跟随，无需额外桥接。

### 4.3 主题能力边界（2026-08-13 专项核对）

对照 AIO-Hub 式"笔记遗漏深层主题系统"的核查，逐项确认以下机制**在 DeepChat 中不存在**（源码存在即记，以下均为"本次未找到"结论，检查范围为 `src` 全树关键词检索 + 设置页外观区表面核对）：

- **主题市场/商店/下载与导入导出**：无 `importTheme`/`exportTheme`、无 `theme.json`、无 `themes/` 目录（glob `**/themes/*` 无命中）。主题形态只有内置明暗三态。
- **壁纸/背景图设置**：`wallpaper`/`backgroundImage` 无命中；仅两处相近但不属于主题设置——悬浮按钮展开壳的本地视觉变量 `--expanded-shell-bg-image`（`FloatingButton.vue:486,539,613`，渐变背景写死在组件样式中）与 MCP artifacts 示例 HTML 的占位图（`artifactsServer.ts:252`）。
- **强调色/主色引擎**：无 `accentColor`/`primaryColor` 设置键、无色阶生成逻辑；`--primary-*` 为静态硬编码值（见 4.2）。
- **自定义 CSS/用户样式**：`customCss`/`userStyle` 无命中，无用户样式注入入口。
- **密度/紧凑/圆角设置**：`density`/`compact` 命中均为会话压缩（compaction）业务语义；`--radius` 固定 `0.75rem`（`style.css:110-114`），无用户圆角/密度入口。
- **设置页外观表面确认**：`DisplaySettings.vue`（设置-显示页）全部外观项 = 语言、明暗三态主题卡片、系统通知、字号 5 档、字体（正文/代码）、内容保护、悬浮按钮（:9-237），与以上"未找到"结论互为印证。

## 5. 响应式、移动端与窗口适配

- **没有断点驱动的侧栏折叠**：`useMediaQuery` 全项目仅 `McpToolPanel.vue:52` 一处（1024px 面板布局）；侧栏折叠是纯手动开关（`sidebar.ts:7-9` `toggleSidebar`，窗口图标按钮/快捷键触发），宽度固定 `w-12`（折叠）/`w-[288px]`（`WindowSideBar.vue:6`），折叠态**不持久化**（内存态）。
- **可持久化的侧边面板**：`sidepanel.ts` 用 `useStorage` 落 localStorage——面板宽度 `chat-sidepanel-width`（默认 520，clamp 到 `[360, min(960, 62%视口宽)]`，:36-48）、导航宽 `workspace-nav-width`（[160,360]）、导航折叠 `workspace-nav-collapsed`（:72-73）；窗口 resize 时重新 clamp（:90-95）。面板拖动 resize 在 `ChatSidePanel.vue:212-235`（rAF 合并写入 store）。
- **窗口最小尺寸**：主聊天窗 `createManagedWindow` **未设 minWidth/minHeight**（`window/index.ts:650-682`，默认 800×620 可任意缩小）；设置窗 `minWidth: 900, minHeight: 640`（:1310-1311）；悬浮聊天窗 `minSize 460×450`（`FloatingChatWindow.ts:33-39`）；远程控制窗 420/380（`src/main/remote/index.ts:2457,2523`）。窗口位置/尺寸经 `electron-window-state` 持久化（`window/index.ts:622-627` 与设置窗 1295）。
- **RTL**：`main.ts:20` 按语言方向设 `documentElement.dir`；`applyDocumentAppearance` 同时维护 `root.dir`；壳内内容区再绑 `:dir="langStore.dir"`（`ChatMainApp.vue:539`），NotificationHost 传 `dir` prop。
- **多窗口差异**：聊天窗 800 起、设置窗更宽且不可全屏（`fullscreenable: false`，:1313）；悬浮窗 `frame: false, transparent: true, alwaysOnTop, skipTaskbar`（`FloatingChatWindow.ts:66-76`）。移动端适配未发现（桌面 Electron 应用，viewport meta 存在但无移动布局路径）。

## 6. 图片、附件、拖放与常见内容交互

- **图片查看**：`MessageBlockImage.vue:30-63` 点击缩略图打开 shadcn `Dialog` 全屏查看（`sm:max-w-[800px]`），带"保存"按钮（:40-48，`useImageActions.saveImage` → `fileClient.saveImage` 主进程另存，成功/失败均 toast，`useImageActions.ts:15-36`）；`handleImageDialogOpenAutoFocus` 在 `open-auto-focus` 里 preventDefault 后手动聚焦容器（:260-264，规避 Dialog 默认把焦点放关闭按钮）。**无缩放/旋转/翻转/多图导航**（本次未找到；检查范围：MessageBlockImage、ImageActionContextMenu、useImageActions）。图片右键菜单 `ImageActionContextMenu.vue`（复制图片/保存，复制走 `fileClient.copyImage` 主进程写剪贴板，`useImageActions.ts:38-60`）。工具调用的图片预览是另一个组件 `MessageBlockToolCallImagePreview.vue`（内联缩略图 + 同名右键菜单）。视频/音频块有 `MessageBlockVideo`/`MessageBlockAudio`（仅呈现，未发现公共播放器设施）。
- **拖放与上传**：Composer 容器 `@dragover/@drop`（`ChatInputBox.vue:9-11`）→ `useChatInputFiles`（`src/renderer/src/components/chat/composables/useChatInputFiles.ts`）：文件选择/粘贴/拖放三条入口统一走 `processIncomingFiles`（:121-143），图片转 base64 + 写临时文件 + 估算 token（:57-83），目录经 `fileClient.prepareDirectory`（:104-109），失败文件聚合成一条错误 toast（:41-55，最多列 3 个名字）。粘贴事件在 `@paste.capture` 用 `_deepchatHandled` 标记防重复处理（:157-165、`ChatInputBox.vue:22`），纯 URL 粘贴另走 `clipboardUrlPaste` 插入为链接（`ChatInputBox.vue:707-714`）。上传后处理（token 超限、模型能力过滤等）属聊天主链，见 ChatUI 笔记 §3。**本次未找到窗口级全局拖放区**（拖放反馈仅 Composer 容器本地事件）。
- **剪贴板**：文本复制经 `deviceClient.copyText`（主进程，`MessageItemAssistant.vue:621` handleSelectionCopy）；图片复制经 `fileClient.copyImage`；发送中的复制防抖/视觉反馈属消息渲染器范围。剪贴板粘贴（图片/文件）见上文 paste 路径。
- **其它公共件**：EmojiPicker（`components/emoji-picker/EmojiPicker.vue`，DropdownMenu 壳，MCP 服务表单消费）；`ReferencePreview`（消息内引用预览浮层，`--dc-z-popover`）；`TranslatePopup`（翻译浮层，window 事件驱动，`--dc-z-popover`）。代码块复制/高亮等属消息渲染器类目，不在此展开。

## 7. 扩展调查：桌面集成、无障碍与动画

### 7.1 桌面集成（主进程公共设施）

- **托盘**：`src/main/desktop/tray.ts:18-73` 平台图标（mac 模板图/win ico/linux png），菜单 = 打开窗口/检查更新/退出；非 mac 平台单击托盘切换主窗口显隐（:68-72）。托盘无未读数/角标（本次未找到 `setBadgeCount`/`flashFrame`）。
- **系统通知**：见 §3.2（`notification.ts`，`notificationsEnabled` 开关）。
- **快捷键**：`src/main/desktop/shortcut.ts`——`installApplicationMenu` 用应用菜单 accelerator 承载大部分快捷键（新会话/新窗口/搜索/侧栏/工作区/缩放等，:78-188），全局快捷键只有 ShowHideWindow（`registerSystemShortcuts` :276-284）；快捷键触发经 `appRuntime.shortcutRequested` 事件或 `SHORTCUT_EVENTS` 定向发给聚焦聊天窗，renderer 侧 `useAppIpcRuntime` 分发（zoom/new conversation/toggle sidebar/toggle workspace/toggle spotlight，`useAppIpcRuntime.ts:35-61`）。
- **上下文菜单**：见 §2.3；`contextMenu.ts` 还负责图片"复制图片地址/另存"（:72-196）。
- **深链与开机启动**：deeplink 经 `handleStartDeeplink` 进入新会话草稿（`ChatMainApp.vue:289-301`）；`launchAtLogin` 由 `DesktopSettings`（`settings.ts:130-141`）。

### 7.2 无障碍（静态代码盘点）

- 已见良好实践：ManagedNotificationToast 的 `role="alert"/"status"` 分级与 progressbar 语义（§3.1）；历史加载失败条 `role="alert"`（`ChatPage.vue:68`）；消息滚动区 `role="status" aria-live`（ChatUI 笔记 §9）；MessageBlockError/ActivityGroup 折叠真实 `aria-expanded/aria-controls`；设置路由切换 `aria-busy`；Spotlight 结果行 `data-spotlight-active` 但无 `aria-activedescendant` 语义（自实现键盘导航，读屏联动未验证）。
- 未核实/未见：Reka 组件（Dialog/Tooltip/DropdownMenu）内部焦点管理未下钻；`useLegacyActions` 默认路径下消息右键菜单不可达（键盘等效路径缺失是静态可见的，但影响未验证）；应用级 focus trap 策略未发现；`prefers-reduced-motion` 全局兜底存在（`style.css:930-943`：transition/animation 压到 1ms），业务组件局部覆盖未逐一核对。
- 结论边界：以上均为静态代码观察，不构成 WCAG 合规判断。

### 7.3 动画与过渡

- 无 framer-motion（package.json 无匹配）；三件套：`tw-animate-css`（`style.css:2`）+ `tailwindcss-animate`（:7）+ Reka `data-[state]` 动画类（shadcn 组件类如 `dialog/DialogContent.vue:38` 的 fade-in/zoom-in/out）。
- `dc-ui/styles/motion.css` 给 Reka tooltip/select/context-menu 统一 `transform-origin` 变量。
- 业务自定义：Spotlight 进出台 `dc-spotlight-*` transition（80ms，含 reduced-motion 覆盖，`SpotlightOverlay.vue:336-369`）；ManagedNotificationToast 的 spinner/progress 动画（§3.1）；`dc-theme-switching` 切主题防抖（§4.1）。`--dc-motion-*` 时长 token（140/220/320ms）统一消费。

## 8. 设计取舍与已确认边界

- **通知双层架构**（renderer 管理层 + 主进程语义路由）：renderer 侧单例 manager 不依赖组件树（命令入口与 viewport 天然共享），主进程路由解决"事件发生在主进程、跨窗口投递"的问题；代价是概念分层较多（request/entry/record/policy/arbiter/presenter）。
- **策略即契约**：同 identity 聚合时 policy 变化直接抛错（`notificationManager.ts:204-216`），progress 值倒退抛错（:218-225）——通知系统对调用方有严格契约，非宽容设计。
- **两种 toast 呈现**：无 key 的 success/info 走 sonner 原生（省资源），warning/error 与带 key 的走托管组件（聚合计数/动作按钮）；sonner 原生呈现的语义（role/aria）依赖库内部未下钻。
- **`DcToast` 是空壳门面**：定义并导出但全仓库零调用，新旧入口并存（对照 Cherry 的单一 toast 封装）。
- **无应用级错误边界**：renderer 未发现 errorHandler/onErrorCaptured/onerror 挂载，错误反馈全部下放到功能场景。
- **主窗口无最小尺寸**：`createManagedWindow` 未设 minWidth/minHeight，与设置窗（900×640）形成对比；聊天页可缩到很小（布局依赖 flex 与 min-w-0）。
- **默认主题跟随系统**：`appTheme` 默认 `system`，原生菜单/对话框也随 `nativeTheme` 变色（主进程权威的副产品）。
- **主题可配置面收窄（2026-08-13 专项核对）**：明暗三态 + 字号 5 档 + 正文/代码双字体即全部外观选项；主色阶、圆角、密度、壁纸、主题导入导出、自定义 CSS 均无用户入口（见 4.3）。主题体系规模小但链路闭环完整（主进程权威 → 跨窗口广播 → DOM 投影），与 AIO-Hub 式"明暗切换之外还另有一套深层主题外观系统"的情形不同。
- **遗留路径并存**：`MessageItemAssistant` 默认仍走 `useLegacyActions`，Reka 右键菜单是新路径显式启用；`DcToast`、legacy actions 说明基础设施迁移过程中新旧并存，但本次无法判断迁移完成度。

## 9. 未验证事项

- Reka UI 内部行为未下钻：Dialog/AlertDialog 的 Esc、遮罩点击、焦点陷阱与归还、Tooltip 键盘触发、`data-[state]` 动画时长；vue-sonner 的堆叠/expand/宽度行为；VueUse `useDark`/`useStorage` 的初始化与跨 tab 同步细节（node_modules 未安装，未读源码）。
- 首屏主题闪烁：`show:false + ready-to-show` 与 CSS 媒体查询兜底的实际效果未运行验证；保存非 system 主题时 IPC 快照前的首帧颜色未实测。
- 原生右键菜单（mac/win 形态）、托盘行为、系统通知点击跳转、全局快捷键冲突提示未运行验证。
- Spotlight 无 focus trap 的实际 Tab 穿透、`useLegacyActions` 默认路径的键盘可用性、Reka ContextMenu 路径的读屏表现未实测。
- 通知仲裁的抢占/队列/聚合在实际运行中的表现（堆叠像素、展示预算计时、progress 与 actionable 交替）未运行验证。
- 窗口最小尺寸未设主窗口的实际拖拽表现、RTL 布局下的排版未运行验证。
- `font-list` 系统字体检测在 win/mac/linux 的实际结果（字体名清洗、去重、缓存失效时机）与检测失败时的内置 fallback 列表表现未运行验证；主进程 `normalizeStoredFont` 白名单的边界行为（如空串、超长、非法字符）未实测。
- 未运行构建与测试；本次所有结论为静态源码核对，依赖库内部一律标为未核实。

## 10. 关键源码索引

- 根装配：`src/renderer/src/main.ts`、`src/renderer/src/App.vue`、`src/renderer/src/apps/chat-main/ChatMainApp.vue:531-575`、`src/renderer/src/router/index.ts`、`src/renderer/settings/App.vue:88`、`src/renderer/settings/main.ts`、`src/renderer/floating/main.ts`、`src/renderer/src/foundation/appearance/documentAppearance.ts`
- 通知：`src/renderer/services/notifications/`（`NotificationHost.vue`、`notificationManager.ts`、`notificationArbitration.ts`、`notificationPolicy.ts`、`sonnerNotificationPresenter.ts`、`ManagedNotificationToast.vue`、`rendererNotificationPort.ts`、`semanticNotificationController.ts`）、`src/shared/notifications/notificationPolicy.ts`、`src/shared/notifications/semanticNotification.ts`、`src/main/notifications/windowNotificationRouter.ts`、`src/main/app/composition.ts:671-712`、`src/main/desktop/notification.ts`
- 弹窗与菜单：`src/main/desktop/dialog.ts`、`src/renderer/src/stores/dialog.ts`、`src/renderer/src/components/ui/MessageDialog.vue`、`src/dc-ui/components/confirm-dialog/DcConfirmDialog.vue`、`src/shadcn/components/ui/dialog/DialogContent.vue`、`src/shadcn/components/ui/alert-dialog/AlertDialogAsyncAction.vue`、`src/renderer/src/components/spotlight/SpotlightOverlay.vue`、`src/main/desktop/contextMenu.ts`、`src/renderer/src/components/message/MessageItemAssistant.vue`、`src/renderer/src/components/message/ImageActionContextMenu.vue`
- 主题：`src/main/desktop/settings.ts:47-77,83-88`、`src/main/desktop/fontSettings.ts`、`src/main/app/settingsRoutes.ts:107-110,242`、`src/renderer/src/stores/theme.ts`、`src/renderer/src/stores/uiSettingsStore.ts`、`src/renderer/src/lib/fontStack.ts`、`src/renderer/src/composables/useFontManager.ts`、`src/renderer/settings/components/DisplaySettings.vue`、`src/renderer/settings/components/display/FontSettingsSection.vue`、`src/renderer/src/assets/style.css:21-195,293-345,904-910`
- 窗口与桌面：`src/main/desktop/window/index.ts:650-710,1290-1330`、`src/main/desktop/window/FloatingChatWindow.ts:22-95,255-265`、`src/main/desktop/tray.ts`、`src/main/desktop/shortcut.ts`、`src/renderer/src/composables/useAppIpcRuntime.ts`
- 响应式：`src/renderer/src/stores/ui/sidepanel.ts`、`src/renderer/src/stores/ui/sidebar.ts`、`src/renderer/src/components/sidepanel/ChatSidePanel.vue:212-235`
- 内容交互：`src/renderer/src/components/message/MessageBlockImage.vue`、`src/renderer/src/composables/useImageActions.ts`、`src/renderer/src/components/chat/composables/useChatInputFiles.ts`、`src/renderer/src/components/chat/ChatInputBox.vue:9-11`
- 加载与空态：`src/renderer/src/features/chat-page/ChatPage.vue:53-122`、`src/renderer/src/components/chat/ChatSessionSkeleton.vue`、`src/dc-ui/components/empty/DcEmpty.vue`、`src/dc-ui/components/skeleton/DcSkeleton.vue`
