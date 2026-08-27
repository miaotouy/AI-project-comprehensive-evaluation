# AIO-Hub 应用界面基础设施调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`（分支：`dev`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO-Hub 是 Vue 3 与 Element Plus 构成的 Tauri 桌面应用。公共界面能力集中在共享组件和 composable：BaseDialog 承担多数业务弹窗，命令式反馈统一绕过自绘标题栏，通知中心则保存需要长期查看的消息。

主题分为明暗、主色色阶和外观效果三层，均持久化到设置文件。外观层覆盖壁纸、自动取色、混合模式、毛玻璃和窗口特效，另有独立的全局自定义 CSS 覆盖子系统，支持内置与用户预设、实时预览和编辑器注入。图片查看使用 viewerjs，侧栏尺寸调整和跨窗口同步由项目自研。

错误处理依靠 Vue 全局钩子、浏览器错误事件、Rust 探针和启动兜底界面，没有通用的组件级 ErrorBoundary。首屏通过先隐藏原生窗口、Vue 挂载完成后再显示来减少闪烁；HTML 只提供静态深浅色 splash，没有挂载前主题脚本。

静态调查还显示，弹窗焦点管理和大量图标按钮的可访问名称覆盖有限。视觉效果、跨窗口主题更新以及各类拖放反馈仍需运行验证。

## 系统边界与总体装配

**界面栈。** Tauri（Rust 主进程 + WebView）+ Vue 3 + Element Plus；

全局共享组件集中在 common 目录，包含 BaseDialog、ImageViewer、AvatarSelector 和 GuidedFlow；全局 composable 集中在 composables 目录，提供尺寸调整、文件拖放、主题、图片查看和弹窗层级能力。

**全局挂载。** GlobalProviders 挂载全局图片查看器、弹窗和通知中心；App 在 `App.vue:81` 挂载引导流程宿主。通知中心不是 llm-chat 专属。

**状态所有权。** 主题与自定义 CSS 等应用设置存于设置文件，由 appSettings 相关实现负责；首页快捷栏显隐与工具可见性同样在该设置中持久化，后者通过替换整个映射对象触发父级写入，供主侧栏和标题栏菜单共同读取（`utils/appSettings.ts:149,346`、`views/Settings/general/ToolsSettings.vue:82-90`、`components/MainSidebar.vue:144-147`）；通知由 useNotificationStore 持有并持久化；拖放能力是全局 composable，被消息输入和智能体侧栏等组件复用。

## 1. 界面栈、公共组件与状态所有权

**弹窗基座。** `BaseDialog.vue`（`src/components/common/BaseDialog.vue`，全文 1-450 行）是全局共享组件，非 llm-chat 专属；业务弹窗（导出、批量管理、收藏夹管理、聊天设置、正则编辑器）大多包它，而不是直接用 el-dialog。

**z-index 管理。** 弹窗层级模块维护一个从 1800 开始的自增计数器，以避让 Element Plus 的默认范围；打开时递增，关闭时只有释放值正好是当前最大值才回退。多个弹窗乱序关闭时计数器不会精确回退，只涨不跌，但不影响功能（实现见 `src/composables/useDialogZIndex.ts`）。

**命令式反馈。** `src/utils/customMessage.ts` 是对 ElMessage 的薄包装，强制增加 54 像素的顶部偏移（标题栏 32 像素、默认间距 16 像素和 6 像素缓冲，依据 `customMessage.ts:23-27`），解决无边框窗口下 Toast 被自绘标题栏遮挡；llm-chat 内所有业务提示都走该包装的成功、失败、警告和信息入口，未见直接调用原生 ElMessage。

**引导流程系统。** common 下的 GuidedFlow 与 upgrade 流程目录共同承担首次启动和升级引导：前者负责流程宿主及运行时状态，后者注册升级流程、版本说明面板和待处理升级恢复（宿主挂载于 `App.vue:81`）。

onboarding、首次使用、firstLaunch 等旧关键词无命中，引导功能以 GuidedFlow/flow 命名存在；视觉呈现与各步骤实际引导体验未运行验证。

### 状态所有权与跨窗口同步

**界面偏好与设置。** 应用级设置（主题、强调色、成功/警告色等）由 appSettingsStore 持有，持久化在设置文件（见第 4 节）；

llm-chat 的 UI 状态（侧栏折叠/宽度、视图模式、当前智能体、各面板展开状态）由 useLlmChatUiState 模块级单例持有，经 createConfigManager 300ms 防抖持久化到 `ui-state.json`（`src/tools/llm-chat/composables/ui/useLlmChatUiState.ts:89-101`）——侧栏宽度与折叠不随聊天数据同步，属于 llm-chat 的本地持久化偏好。

**窗口布局。** 窗口位置、尺寸和最大化状态由 Rust 侧的窗口配置模块持有，主窗口与分离窗口关闭时同步保存到窗口配置文件（依据 `src-tauri/src/events.rs:99-107` 和 `src-tauri/src/commands/window_config.rs:77-80`）。

**通知。** useNotificationStore（`src/stores/notification.ts`）持有通知列表与通知中心显隐；数据通过 localStorage 的 app-notifications 键持久化，跨窗口同步依靠 storage 事件（`notification.ts:61-69`）。这与设置、主题使用文件持久化是两条并存通道。

**浮层队列。** 无应用级浮层队列管理器；z-index 由 useDialogZIndex 模块级计数器提供（第 2 节），弹窗显隐状态在消费方组件与局部 store 内，不进入全局状态。

**跨窗口同步总线 useWindowSyncBus 的职责范围。** `src/composables/useWindowSyncBus.ts` 是主窗口与分离窗口之间的运行时状态同步和操作代理总线，由全局单例初始化（`GlobalProviders.vue:61-66`）；主窗口和 detached-tool 提供数据，detached-component 负责消费并请求初始状态（`useLlmChatSync.ts:479-484`）。

消息协议定义了 8 种 WindowMessageType（`src/types/window-sync.ts:33-40`），覆盖握手、心跳、全量及 JSON Patch 增量同步、批量初始状态和操作请求/响应；

心跳每 30 秒发送，60 秒超时；重连有 5 秒防抖，操作请求广播后 10 秒超时（依据 `useWindowSyncBus.ts:87,121-125` 和 `useWindowSyncBus.ts:606-648`）。

llm-chat 注册 12 个状态键，覆盖智能体、会话、收藏夹、生成状态、用户档案、聊天设置和工具调用待审等内容，并提供 40 多个命名空间操作（依据 `useLlmChatSync.ts:167-227` 和 `useLlmChatSync.ts:304-459`）；另有一条流式增量通道 chat:streaming-delta（`useLlmChatSync.ts:231-257`）。

**主题、通知、窗口布局不在总线职责内**：主题由各窗口启动时读同一 `settings.json` 自行应用（运行期修改不广播，theme-changed 事件无监听者，见第 4 节），通知走 localStorage storage 事件，窗口布局由 Rust 持有。

## 2. 弹窗、浮层与菜单

### 弹窗与对话框

`BaseDialog.vue`（全局共享组件，非 llm-chat 专属）：

**实现方式。** 组件默认 Teleport 到 body，也可通过 appendToBody 关闭；界面由遮罩层和内容容器组成。显隐与是否首次渲染分别由 v-show、v-if 控制，关闭后默认销毁 DOM。

**Esc 关闭。** 对话框在 `BaseDialog.vue:276-280` 监听全局键盘事件，按键为 Escape 且 showCloseButton 开启（默认开启）时关闭。Esc 与关闭按钮共用这个开关，并非独立控制。

**点击遮罩关闭。** 由 closeOnBackdropClick 属性控制，默认开启；实现位置为 `BaseDialog.vue:29`。部分弹窗显式关闭该能力（如 `ChatSettingsDialog.vue:24`），说明不同场景对误触关闭的容忍度不同。

**焦点管理。** BaseDialog 没有 autofocus，也没有在 nextTick 后手动聚焦，因此打开后焦点默认停留在触发按钮。会话重命名弹窗是例外，使用原生 el-dialog 并在输入框上设置 autofocus（`src/tools/llm-chat/components/sidebar/RenameDialog.vue:70`）。

**入场/退场动画。** 内容过渡状态配合双重 requestAnimationFrame，绕开 v-if 刚插入 DOM 时过渡不生效的问题（`BaseDialog.vue:251-256`）；CSS 使用透明度和缩放、纵向位移，时长为 0.3 秒（`BaseDialog.vue:327`）。

关闭时 `handleClose()` 先播 300ms 退场动画再真正 emit update:modelValue: false（enableTransition 为 `false` 时延迟归零）。

**消费方。** 导出、批量管理、收藏夹、聊天设置和正则编辑器等业务弹窗都使用 BaseDialog。批量管理表格带有 table 语义和会话列表名称；聊天设置关闭遮罩关闭与销毁，因而保留内部 tab 和滚动状态。

硬删除消息和清空通知使用 Element Plus 的确认弹窗，删除确认显示“确定删除”和“取消”，并标记危险操作（`MessageMenubar.vue:167-186`）；节点图删除使用气泡式确认（`GraphNodeMenubar.vue:386-404`）。

### 右键与上下文菜单

- **树图节点右键菜单**（`src/tools/llm-chat/components/conversation-tree-graph/ContextMenu.vue`）：菜单跟随鼠标坐标定位，入口取得客户端坐标后传入菜单，再用元素边界校正右侧和底部越界（依据 `useGraphNodeActions.ts:751-753` 和 `ContextMenu.vue:48-66`）。

  菜单 Teleport 到 body，点击外部关闭（`ContextMenu.vue:82-90`）。MenuItem 只有 label、icon、disabled、danger 和 action 字段，是不支持子菜单的扁平列表；组件没有键盘事件或 tabindex，因此缺少方向键操作和 Esc 关闭能力。

**侧栏列表菜单。** Agent 列表用 Element Plus el-dropdown，`AgentListItem.vue:182-190` 设置 `trigger="contextmenu"`，通过绝对定位覆盖列表项的空 div.context-menu-trigger 作为锚点；

会话列表 `SessionItem.vue:145-186` 用 `trigger="click"` 由"更多"图标按钮触发，不支持右键——两侧栏菜单触发方式不一致。el-dropdown 键盘可达性由 Element Plus 提供，未独立验证其内部实现。

## 3. 通知、加载态与错误反馈

### 通知与状态反馈

**业务级即时反馈。** customMessage（见系统边界）。llm-chat 内所有业务成功/失败提示（Token 重算、导出成功/失败、翻译等）一律走 `customMessage.success/error/warning/info`。

**错误提示的分级与去重。** `src/utils/errorHandler.ts:308-371` 决定报错是否弹出及持续时间：INFO、WARNING 和 ERROR 走 customMessage，错误级别显示 5000 毫秒，其余显示 3000 毫秒，并合并相同消息（`errorHandler.ts:348`）。

CRITICAL 不走 Toast，改用 ElNotification.error，持续时间为 0，**不自动关闭**，需手动点掉（`errorHandler.ts:362-368`）。由此形成三级反馈体系：一般级别是短暂 Toast，严重级别是常驻通知。

**堆叠行为。** ElMessage 和 ElNotification 使用 Element Plus 的原生行为，多条消息会纵向堆叠错位，customMessage 只增加顶部偏移。**未在运行时截图验证堆叠像素细节，仅代码层面确认使用默认机制**。

**独立的通知中心。** `src/components/notification/NotificationCenter.vue` 用 el-drawer（右侧滑出，`direction="rtl"`，宽 360px）实现，顶部有未读数 el-badge、搜索框（标题/内容/来源过滤）、列表区、底部"清空所有消息"（ElMessageBox.confirm 二次确认，`NotificationCenter.vue:91-103`）；

点击通知项可 markRead 并可选跳转 metadata.path（router.push）。通知详情走**内嵌的 BaseDialog**（`NotificationCenter.vue:233-275`，非 drawer），内容用 RichTextRenderer 渲染（支持 Markdown）。

通知中心是全局的（挂在 `GlobalProviders.vue`），但 llm-chat 内没有直接搜到主动调用 useNotificationStore 推送通知的代码（搜索 useNotificationStore/notificationStore 在 `src/tools/llm-chat` 下无匹配）——"生成完成"这类事件目前没有证据表明会被推进通知中心。

通知列表带分页（`PAGE_SIZE = 20`，滚动距底 80px 自动加载更多，搜索/筛选重置页码，首屏内容不足以滚动时自动补页）；通知面板可打开版本说明（openReleaseNotes）与恢复待处理的升级引导（resumePendingUpgrade，来自 `src/flows/upgrade`）。

### 加载态、骨架屏与空状态

**首屏骨架屏。** `src/tools/llm-chat/components/LlmChatSkeleton.vue`（全文 1-533 行）是专门手写的骨架屏组件，逐块模拟真实布局：左侧栏 tab + 12 行文本骨架，中间模拟 ChatAreaHeader（头像+名称+模型徽标+搜索/设置按钮占位）和 4 张不同长度消息卡片骨架（el-skeleton-item 的 `variant="text"/"rect"/"circle"` 拼出头像、气泡宽度不一的多行文本），底部模拟输入框；

右侧模拟搜索栏 + 8 组会话条目骨架。`LlmChat.vue:369-375` 用 `v-if="isLoading"` 整体切换骨架屏与真实内容，宽度参数（侧栏宽度、折叠状态）与真实布局保持同步，避免加载完成后布局跳动。

**会话列表空状态。** `SessionsSidebar.vue:491-499` 区分两种空态——完全没有会话时"暂无会话 / 点击下方按钮创建新会话"；有会话但筛选/搜索无结果时"未找到匹配的会话 / 尝试其他搜索关键词"（搜索模式下才显示第二行）。

**附件加载失败态。** `AttachmentCard.vue:826-833` 区分"加载失败"（loadError，网络或本地路径读取问题）与"导入失败"（hasImportError，两阶段导入第二阶段失败），两种文案不同但共用同一个 TriangleAlert 图标占位块；

导入中间态用 Loader2 旋转图标（isLoadingUrl 分支，`AttachmentCard.vue:821-824`），转换阶段文案见 `AttachmentCard.vue:461-476`（"正在转换文档格式.../正在校验文件.../正在生成预览..."按 phase 区分）。

**通知中心空状态。** `NotificationCenter.vue:209-212`，无通知显示 BellOff 图标 + "暂无消息通知"，搜索无结果显示"没有匹配的通知"。
- 消息列表本身（`MessageList.vue`）没有"消息加载中"骨架屏——消息随会话详情一次性加载，不存在逐条独立 loading 态；生成中消息使用流式内容占位。

### 错误边界

**应用级 Vue 钩子（已挂载）。** `src/main.ts` 依次注册 app.config.errorHandler（:241-256，错误走 errorHandler.handle ERROR 级 Toast"应用遇到错误，请查看控制台了解详情"）、app.config.warnHandler（:259-265，仅 logger.warn）、window.addEventListener("unhandledrejection")（:268-289，提示"操作失败，请重试"）与 window.addEventListener("error")（:292-319，ERROR 级）。

两个 window 级钩子各带白名单过滤：Popper 卸载竞态（getBoundingClientRect is not a function，:272-278）与 ResizeObserver 良性警告（:294-301）不弹提示、不进入上报。

**错误上报探针（Rust 侧 watchdog）。** 上述钩子与 mountApp 的 catch（`main.ts:354-361`，CRITICAL 级常驻通知"应用挂载失败，请检查配置或联系支持。

"）都会经 sendFrontendProbe → frontend_probe_error command（`src-tauri/src/frontend_monitor.rs:813-820`）把错误快照（name/message/stack/路由/视口/readyState 等）记入 FrontendMonitorState 并打日志；

前端每 5s 心跳（`main.ts:63,174-189`），Rust watchdog 每 10s 巡检、可见窗口 20s 无心跳告警、60s 升级为持续缺失（`frontend_monitor.rs:27-30,601-663`），必要时注入 __AIO_BACKEND_WATCHDOG_PING__ eval 探针（`frontend_monitor.rs:943-948`）。

get_frontend_probe_status command 已注册（`frontend_monitor.rs:822-827`）但前端本次未找到调用方——探针体系是日志/诊断通道，不承担用户可见兜底。

**渲染进程崩溃/白屏处理（Tauri 侧）。** `WindowEvent::Destroyed` 只记录 destroyed 状态并打印窗口列表（`src-tauri/src/events.rs:156-158`，`frontend_monitor.rs:867-869`）；

Linux 下前端 15s 未收到 frontend-ready 事件（前端在挂载后 emit，`main.ts:350-353`）时，向主窗口注入"界面加载超时"诊断 overlay 并给出 WebKitGTK 启动参数建议（`src-tauri/src/lib.rs:428-474`）。

本次未找到 WebviewEvent 崩溃事件监听或渲染进程崩溃后的重启/重建逻辑（检查范围：`src-tauri/src` 全量搜索 WebviewEvent/destroyed/onDestroyed）。

**兜底 UI。** `index.html:295-321` 内联 WebView 兼容性错误界面（ES Modules/Import Maps/CSS 变量等检测失败时替换启动 splash，并置 window.__AIO_COMPAT_FAILED__ 阻止应用挂载，`main.ts:365-367`）；

`LoadingScreen.vue:90-123` 启动失败界面（重试/复制错误/打开 GitHub issue）。**无通用 ErrorBoundary 组件**（全 src 搜索 ErrorBoundary/error-boundary/FallbackUI 无命中）；

组件级 onErrorCaptured 仅 web-distillery 工具内 3 处（`WebDistillery.vue:60`、`ApiSniffer.vue:58`、`RecipeManager.vue:113`），另有 web-canvas 画布预览 iframe 内的局部 window 错误监听（`useCanvasPreview.ts:139-161`）。

## 4. 主题、视觉 token 与持久化

**实现机制。** `src/composables/useTheme.ts` 提供全局单例，借助 VueUse 的 useDark 管理三态主题：auto、light 和 dark。

auto 用 window.matchMedia("(prefers-color-scheme: dark)") 读取系统当前值并注册 change 监听（`useTheme.ts:75-87`）——**确认支持跟随系统**。

切换主题后 window.dispatchEvent(new CustomEvent("theme-changed", ...))（`useTheme.ts:37-41`），供图标等需要感知主题的组件订阅。

**存储位置。** 主题偏好写入应用级设置文件，不使用 localStorage；更新入口和文件实现分别见 `useTheme.ts:57-58` 与 `src/utils/appSettings.ts:403`，写入前有 300 毫秒防抖。

**CSS 切换方式。** `useDark()` 默认通过给根元素加/去 `dark` class（该 hook 标准实现，项目未覆盖默认行为），配合 `src/styles/variables.css` 的 CSS 变量分深浅两套取值（如 `--el-color-primary` 在 :root 和 :root.dark——`NotificationCenter.vue:448` 就有 :root.dark :global(.notification-drawer) 的暗色专属选择器，印证根节点 `.dark` class 切换机制）。

llm-chat 内弹窗、消息卡片等大量用 `var(--card-bg)`/`var(--border-color)`/`var(--text-color)` 语义化变量而非硬编码颜色，理论上无需额外适配即可跟随全局主题切换——**未逐一验证 llm-chat 每个组件在深色模式下的实际视觉效果，只是确认变量机制存在且被使用**。

**首屏防闪机制。** index.html **没有挂载前内联主题脚本**；其中唯一的内联脚本用于 WebView 兼容性检测而非主题（`index.html:323-401`）。

防闪依靠两条：① 主窗口在 Rust 侧先隐藏，前端挂载完成后再显示（依据 `src-tauri/src/lib.rs:362` 和 `src/main.ts:340-353`）；画布和分离窗口也采用先隐藏策略。

② Vue 接管前的静态启动 splash 使用媒体查询提供明暗两套配色（`index.html:129-146,277-293`）；挂载后由 LoadingScreen 接管，并按主题选择图标和样式。

**主题应用时机。** `initTheme()`（`src/composables/useTheme.ts:65-72`）先 await 设置加载再 applyTheme；

主窗口和分离窗口都在初始化流程的第 3 步并行加载主题和服务，且早于 isReady 置为真（依据 `src/stores/appInitStore.ts:103,165`）。

注意窗口 `show()` 不等待 initMainApp 完成，因此 LoadingScreen 阶段的主题由 `useDark()` 初始值决定：VueUse 默认读 localStorage vueuse-color-scheme 键（项目从不写入该键），未命中时回退系统偏好（依赖内部行为，未下钻 node_modules）——auto 或与系统一致时无闪变；

保存了与系统相反的固定主题时，initTheme 完成前后存在一帧主题切换的可能（静态推断，未运行验证）。

**theme-changed 事件。** `useTheme.ts:36-41` 注释声明该 CustomEvent 供"图标等需要感知主题的组件"响应，但全 src 搜索 theme-changed 仅命中 dispatch 两处（`useTheme.ts:38,81`），本次未找到监听者——跨窗口主题同步也不依赖它（见第 1 节状态所有权）。

### 主题系统全貌：明暗层之外的主色引擎与外观系统

上述条目只覆盖"明暗切换"一层。AIO-Hub 的实际主题系统是三层结构（项目自带架构文档 `docs/architecture/theme-system-architecture.md` 记载了完整设计）：

**① 明暗层（`useTheme.ts`）**：见上文，管 `auto/light/dark` 与系统跟随。

**② 主色色阶引擎（`src/utils/themeColors.ts`，296 行）**：applyThemeColors（`themeColors.ts:198-296`）把 primary/success/warning/danger/info 五色写入 `--primary-color`、`--el-color-primary` 等 CSS 变量，并**为 Element Plus 生成全套色阶**（`--el-color-primary-light-{1..9}`，按当前明暗模式用 darkenColor/lightenColor 调整混合比例，hover 色按相反方向调整，:214-237）；

色值同时缓存到 localStorage（app-theme-color/app-success-color 等键，:284-295，"以避免下次启动时的闪烁"注释原话）。

另有 OKLCH 色彩空间工具（hexToOklch/oklchToHex/harmonizeColorOKLCH，:78-193）——harmonizeColorOKLCH 按明暗模式把感知亮度钳制到 0.45-0.6（亮）/0.7-0.85（暗）、彩度 0.1-0.25，用于壁纸提取主题色的安全修正。

启动链：`useRootInit.ts:47-50` 用 appSettingsStore.effectiveThemeColor（用户手选 themeColor，壁纸自动提取开启时优先用 wallpaperExtractedThemeColor，`appSettingsStore.ts:101-108`）调 applyThemeColors。

设置入口 `ThemeColorSettings.vue`（`src/views/Settings/general/ThemeColorSettings.vue`，五色取色器 + 预设色板）。

**③ 主题外观系统（`src/composables/useThemeAppearance.ts`，1550 行）**：这是独立于颜色主题的“视觉质感”层，保存 appearance 子对象时使用 400 毫秒防抖（`useThemeAppearance.ts:237-241`），默认配置定义在 `appSettings.ts:204-267`。

该层由初始化入口驱动，把设置计算为 CSS 变量写入 document.documentElement.style；主题切换时通过 MutationObserver 重新应用，明暗变化时重新提取壁纸颜色（调用入口见 `useRootInit.ts:86`，实现区间为 `useThemeAppearance.ts:272-588,1117-1260`）。

功能面：

**壁纸系统。** 静态/轮播双模式（wallpaperMode: static|slideshow），来源内置 7 张（BUILTIN_WALLPAPERS，`appSettings.ts:47-55`）或自定义目录（Tauri list_directory_images 扫描）；轮播间隔（分钟）、随机播放（shuffle 保当前图）、索引记忆（builtin/custom 分键）；填充模式 cover/contain/fill/tile（tile 支持翻转/旋转/缩放）；壁纸透明度可调（默认 0.3）。

**双通道自动取色。** ① _extractColorFromWallpaper（:788-864）用 ColorThief 取 5 色调色板按感知亮度排序，暗色选次暗、亮色选次亮 → 存 wallpaperExtractedColor 作为背景叠加色；

② _extractThemeColorFromWallpaper（:883-959）用 node-vibrant 按策略（vibrant/light-vibrant/dark-vibrant/muted）取色后经 harmonizeColorOKLCH 修正 → 存 wallpaperExtractedThemeColor 作为主色。

两个开关独立（autoExtractColorFromWallpaper/autoExtractThemeColorFromWallpaper），开启时切壁纸/切明暗都会重新提取。

**背景色叠加。** backgroundColorOverlayEnabled + 16 种混合模式（BlendMode：normal/multiply/screen/overlay/darken/lighten/color-dodge/color-burn/hard-light/soft-light/difference/exclusion/hue/saturation/color/luminosity，`appSettings.ts:61-77`；

applyBlendMode 实现，:102-156），作用于 sidebar/card/header/input/container 五类元素背景 + 代码块背景 + 滚动条（:370-562）。

**UI 质感（毛玻璃）。** `--ui-blur`（默认 15px）、聊天消息独立模糊系数（chatMessageBlurFactor）、分层透明度（uiBaseOpacity 0.75 + layerOpacityOffsets sidebar +0.1/card +0.05/overlay +0.15/content 0）、边框透明度/宽度、代码块背景不透明度。

**窗口特效（OS 级，实验性）。** Tauri apply_window_effect（`WindowEffect: none/blur/acrylic/mica/vibrancy`，:1055-1066）+ set_window_shadow（:1108-1113）——Windows Mica/Acrylic、macOS blur。

**分离窗口适配。** isDetachedWindow 时给 body 加 no-global-wallpaper class 隐藏全局壁纸、保留 `--wallpaper-url` 供组件内部使用（:299-305），`--detached-base-bg` 独立底层背景 + detachedUiBaseOpacity 0.95（:454-478）。
- 设置入口 `ThemeAppearanceSettings.vue`（1493 行：壁纸管理/轮播控制/取色策略/质感滑块/窗口特效开关，注册于 `src/config/settings.ts:42-45` 的 theme-appearance 分区）。

**配套扩展适配**：useIframeTheme 从主文档读取计算后的主题变量，生成 CSS 文本注入 iframe，使预览与主应用视觉一致（`src/composables/useIframeTheme.ts:78-196`）。

`useThemeAwareIcon.ts` + DynamicIcon（`src/composables/useThemeAwareIcon.ts:66-99`）把外部 SVG 的黑白单色（fill/stroke 为 #000/#fff）替换为 currentColor、彩色保留，让任意来源图标跟随主题（架构文档 §2.2）。

### 自定义 CSS 样式覆盖

自定义 CSS 不属于上述三层主题计算链，而是设置系统中的独立覆盖通道。`src/config/settings.ts:50-55` 注册“CSS 样式覆盖”分区并异步加载 `CssOverrideSettings.vue`；设置页用 `RichCodeEditor` 以 CSS 模式编辑全局样式，提供启用开关、纯自定义模式、内置预设和用户预设，选中预设时先预览，再由用户明确应用（`CssOverrideSettings.vue:35-51,118-150,190-305`；预设定义在 `src/config/css-presets.ts`）。

状态由 `useCssOverrides.ts` 持有，并写入应用设置的 `cssOverride` 字段。`UserCssSettings` 包含 enabled、basedOnPresetId、customContent、pureCustomContent、userPresets 与 selectedPresetId；纯自定义内容和基于预设修改的内容分字段保存，customContent 还有向 pureCustomContent 的兼容迁移（`useCssOverrides.ts:42-49,124-179`；`src/types/css-override.ts:32-40`）。编辑内容变化后 500ms 防抖保存到 appSettingsStore，同时在启用状态下无防抖调用 applyCssToPage（`useCssOverrides.ts:401-426`）。

实际应用方式是向当前 document.head 创建或复用 `<style id="custom-css-override">`，再把编辑器文本原样写入 textContent；禁用或内容为空时移除该节点（`useCssOverrides.ts:369-399`）。因此它可以覆盖整个当前 WebView 的应用样式，并可引用 `--primary-color` 等主题变量，但代码侧没有选择器作用域、规则校验或 CSS 安全过滤。

**装配边界。** 持久配置的启动恢复已经从设置页 composable 中拆成无状态入口 `applyPersistedCssOverrides()`。主窗口与分离窗口初始化都会先加载 `settings.json`，随后立即把 `cssOverride` 注入各自文档的 `<style id="custom-css-override">`，早于主题与服务的并行初始化；进入设置页后，`useCssOverrides()` 再负责编辑、副本状态、预设和实时应用（`src/stores/appInitStore.ts:80-105,147-168`、`src/composables/useCssOverrides.ts:39-69,413-466`）。因此“重启后必须先进入设置页”“独立 WebView 不恢复”已不再成立；多窗口运行期修改是否即时同步仍未运行验证。

## 5. 响应式、移动端与窗口适配

**三栏布局没有响应式断点。** `LlmChat.vue` 的三栏结构没有 @media 查询或基于容器宽度的自动折叠。侧栏显示状态由用户手动控制，通过 isLeftSidebarCollapsed/isRightSidebarCollapsed 持久化；窗口变窄不会自动收起侧栏，三栏一起被压缩。

**弹窗内部有断点。** `FavoriteManagerDialog.vue:669-674` 在 max-width: 720px 时把工具栏/表格/收藏行从多列 grid 改单列（grid-template-columns: 1fr）；`ChatSettingsDialog.vue:714-737` 分别在 max-height: 900px（缩小弹窗内边距）和 max-height: 768px（缩小分区标题字号）两级断点调整间距字号——聊天设置弹窗针对小屏笔记本场景做了适配。
- **侧栏宽度拖拽**（见第 6 节拖放与尺寸调整）：200-600px 手动调整，不属于响应式自适应。

## 6. 图片、附件、拖放与常见内容交互

### 拖放与尺寸调整

**左右侧栏宽度拖拽。** `LlmChat.vue:88-102` 用通用 composable useResizable（`src/composables/useResizable.ts`，非 llm-chat 专属，纯 mousedown/mousemove/mouseup 手写实现，不依赖第三方拖拽库），左侧栏 direction: "left"、右侧栏 direction: "right"，共用 minSize: 200, maxSize: 600（像素）硬编码约束（`LlmChat.vue:91-92, 99-100`）。

拖拽时 `document.body.style.cursor = "col-resize"` 全局改鼠标样式并禁用文本选中（`useResizable.ts:54-55`），松开时还原。

**分离输入框窗口的宽度拖拽。** `MessageInput.vue:598-611` 在 props.isDetached 为真时渲染左右两条拖拽手柄（resize-handle-left/resize-handle-right，标题"拖拽调整宽度"）；

触发函数 `createResizeHandler("East"/"West")`（`MessageInput.vue:439-440`）与高度手柄（"拖拽调整高度（双击重置）"，`MessageInput.vue:513`）是同一套底层实现的不同方向变体，只在窗口分离时出现——专门为悬浮输入框窗口设计的自由调整能力，主窗口内嵌模式不需要。

**拖放文件的双通道融合机制。** `src/composables/useFileDrop.ts`（全局 composable，被 `MessageInput.vue` 和 `AgentsSidebar.vue` 等使用）设计上明确考虑 Tauri 环境下拖放的两条路径——H5 原生 `dragenter/dragover/dragleave/drop` 事件（精准但拿不到文件系统绝对路径，只有文件名/大小/MIME）和 Tauri 底层 webview.onDragDropEvent（能拿绝对路径但依赖拖拽拦截器配置）。

当只有 H5 事件触发且只解析到文件名时，挂起 50ms"延迟融合窗口"（FUSION_WAIT_MS，`useFileDrop.ts:176`）等待 Tauri 事件补上绝对路径，超时降级报错"无法获取文件绝对路径，请使用文件选择器添加"（`useFileDrop.ts:572-579`）——为 Tauri 拖放不稳定性做的工程化兜底。

**节点图内的拖拽。** 节点单点/子树拖拽和连线嫁接见 Chat UI 笔记第 11.3 节。

### 图片查看与头像管理

**图片预览。** `AttachmentCard.vue` 点击图片附件后调用全局单例 `useImageViewer()`（`src/composables/useImageViewer.ts`）。

挂载在 `GlobalProviders.vue:74-81` 的 `ImageViewer.vue` 用 viewerjs 实现灯箱，支持缩放、旋转、翻转、全屏、键盘操作（keyboard: true）和底部缩略图导航（navbar: true）。多图通过 imageAssets 和 currentIndex 左右切换（`AttachmentCard.vue:529-539`）。

pending 附件用 convertFileSrc 生成临时 URL，导入完成后改用 `asset://` 协议（`AttachmentCard.vue:548-564`），对应两阶段导入机制。

**Agent 头像。** 全局组件 `AvatarSelector.vue` 支持预设图标、本地文件上传和剪贴板粘贴三种来源。本地文件经 copy_file_to_app_data 保存到 AppData，剪贴板读取用 `navigator.clipboard.read()`。

当前头像可通过 useImageViewer 放大查看，SVG 显示前做主题色适配（`AvatarSelector.vue:433-482`）；历史头像以 BaseDialog 网格展示并支持删除（`AvatarSelector.vue:600-650`）。上传文件直接保存为 `avatar-{timestamp}.{ext}`，**没有裁剪、缩放或宽高比调整流程**。

## 7. 扩展调查：无障碍、动画、设置面板、桌面集成

### 无障碍（静态代码结论）

对 `src/tools/llm-chat` 全目录搜索 aria-label/aria-hidden/aria-expanded/`role="`，命中非常有限：

- `BatchManagerDialog.vue:75-110`：批量管理表格用 `role="table"` + `aria-label="批量管理会话列表"`，表头和每行用 `role="row"`——llm-chat 目录下唯一找到的主动语义化 ARIA 标注。
- `ChatTextareaEditor.vue:324`：隐藏影子测量节点上有 `aria-hidden="true"`（纯技术性用途，防止读屏读到不可见辅助元素）。
- 其余组件（消息操作栏 `MessageMenubar.vue`、发送/中止按钮 `MessageInputToolbar.vue`、节点图菜单 `GraphNodeMenubar.vue`、树图节点 `GraphNode.vue`）没有找到 aria-label，普遍用"图标按钮 + title 属性"或 el-tooltip（发送按钮 `title="发送 (Ctrl/Cmd + Enter)"`，`MessageInputToolbar.vue:530`；

  停止生成按钮 `title="停止生成"`，:508）。title 对读屏的支持取决于浏览器和辅助技术组合，不能替代明确的可访问名称。

**纯键盘能否完成核心操作。** 发送消息可以使用快捷键；会话切换和树图操作基本依赖鼠标，线性视图的分支按钮可通过 Tab 聚焦。
- **发送消息**：可以。`ChatCodeMirrorEditor.vue`/`ChatTextareaEditor.vue` 支持 `Ctrl/Cmd+Enter` 或 Enter 发送（可配置），不依赖鼠标点击。
- **切换会话**：会话列表是虚拟化可点击列表项（`SessionItem.vue:87`，整个 div 绑 @click），无 tabindex、`role="option"`/`role="listbox"`，也无 `ArrowUp/ArrowDown` 或 Ctrl+Tab 会话切换绑定——div 默认不可聚焦，列表项不在 Tab 焦点序列，纯键盘用户无法直接切换会话。
- **查看分支**：部分可行。`MessageMenubar.vue` 上一分支/下一分支按钮是标准 `<button>`（可 Tab 聚焦、Enter/Space 激活），可 Tab 导航后键盘激活；但树图视图（`FlowTreeGraph.vue:22` 容器有 `tabindex="0"`，画布可聚焦）内部节点选择、右键菜单、连线嫁接均是鼠标驱动（拖拽、右键、双击），**没有找到等效键盘操作路径**，画布聚焦后没发现方向键选中/切换节点绑定。
- 综合结论：发送消息有键盘路径，切换会话和树图操作基本依赖鼠标；线性视图分支切换按钮可 Tab 聚焦。该结论来自静态代码搜索，未经读屏实测，不能作为正式 WCAG 合规结论。

### 动画与过渡

**消息内容块。** `RichTextRenderer.vue:775-789` 给 `.rich-text-node` 应用 fade-in-up 0.3s ease-out forwards（`opacity: 0; transform: translateY(-4px)` → 正常）。

动画由 enableEnterAnimation prop 控制，`MessageContent.vue` 绑定到 settings.uiPreferences.enableEnterAnimation。

代码块、Mermaid 图、思考节点、VCP 工具节点、HTML 块和图片等 9 类节点在 `AstNodeRenderer.tsx:99-109` 的 NO_ANIMATION_NODE_TYPES 集合中，不应用该动画——避免流式内容已更新而外层仍处于透明过渡。

**弹窗。** BaseDialog 的 0.3 秒缩放 + 纵向位移动画（第 2 节）。

**图片查看器。** `ImageViewer.vue` 封装 viewerjs，transition: true（`ImageViewer.vue:86`）启用库自带缩放、切换、旋转、翻转和全屏过渡。

**侧栏折叠。** `LlmChat.vue` 通过 v-if 直接增删侧栏 DOM，没有宽度 transition——折叠/展开是瞬时切换。

### 设置面板与首次启动引导

- `ChatSettingsDialog.vue` 是基于 BaseDialog 的全局聊天设置弹窗，`close-on-backdrop-click="false"` 防误触关闭。顶部 el-autocomplete 模糊搜索设置项，querySearch/handleSearchSelect/highlightedItemId 定位并高亮；下方卡片式 el-tabs 是滚动锚点，所有分区实际位于同一个可滚动容器；

  主体由 el-form + SettingListRenderer 渐进渲染，activeGroupCollapses 记录设置组展开状态，底部提供"恢复默认"。
- 首次启动与升级引导由 `GuidedFlow/` 通用引导流程系统 + `src/flows/upgrade/` 升级引导承担（见系统边界），配套"首次启动基线门禁 + 生命周期迁移 + E2E 覆盖"（提交 eed23cd8e/a9f02cd4f/9434d4473/74675f45f 等）。

### 桌面集成

**系统托盘。** `src-tauri/src/tray.rs` 定义应用级托盘，菜单包含"显示主窗口、隐藏主窗口、重启前端、清除窗口配置、退出"（`tray.rs:39-59`）；"显示主窗口"同时调用 `window.show()` 和 `window.set_focus()`。托盘不属于 llm-chat，也没有聊天生成状态相关的动态菜单项。

**系统级通知。** 项目中没有找到 tauri-plugin-notification、sendNotification、`notification::Notification`、request_user_attention 或 UserAttentionType——没有 Windows Toast、标题栏闪烁或任务栏提醒的实现证据。

**生成完成提示。** 生成完成只驱动 generatingNodes、消息卡片状态和 useWindowSyncBus 的跨窗口同步，没有触发系统通知、托盘图标变化或标题栏提醒。应用在后台时不会主动提示某个会话已生成完成。

## 8. 设计取舍与已确认边界

**Esc 与关闭按钮绑定。** `showCloseButton=false` 会连 Esc 一并禁用，不是独立 Esc 开关。

**z-index 计数器只涨不跌。** 乱序关闭不精确回退，简化实现。

**主题持久化在 settings.json 而非 localStorage。** 与"通常在浏览器层存"的预期相反，因为 Tauri 原生应用（300ms 防抖写入）；唯一例外是主色色阶引擎把五色缓存进 localStorage app-theme-color 等键供下次启动防闪（`themeColors.ts:284-295`）。

**主题系统三层分工。** useTheme（明暗+系统跟随）→ themeColors（五色主色注入 Element Plus 色阶）→ useThemeAppearance（壁纸/取色/混合/窗口特效），各自独立持久化到 settings.json 的不同字段；theme-changed CustomEvent 已无监听者，跨窗口主题同步实际靠各窗口启动时读同一 settings.json 自行应用（见第 1 节）。

**自定义 CSS 是独立旁路。** useCssOverrides 不参与三层主题计算，只把用户文本原样注入当前 document.head，并把配置持久化到 settings.json 的 cssOverride。设置页负责预设与实时编辑；应用初始化则用无状态恢复入口把同一配置应用到主窗口和分离窗口。

**双通道自动取色用两套算法。** ColorThief（背景叠加色，按亮度取次暗/次亮）与 node-vibrant（主题主色，策略化优先级链），提取结果都经 OKLCH 感知修正保证对比度；两个开关独立，开启时切壁纸/切明暗都会重新提取。

**窗口特效走 Tauri 原生通道。** apply_window_effect（mica/acrylic/blur/vibrancy）与 set_window_shadow 是实验性 OS 级能力，与前端 CSS 毛玻璃是两层独立机制（前端 `--ui-blur` 与窗口 windowEffect 互不依赖）。

**拖放双通道融合。** 为 Tauri 拖放不稳定性做的 50ms 延迟融合窗口 + 降级报错。

**通知中心存在但 llm-chat 未接入。** "生成完成"等事件没有证据表明会被推进持久化通知中心。

**无系统级桌面通知与生成完成联动。** 后台不主动提示（已核实，非未找到）。

**头像上传无裁剪流程。** 直接保存原图。

**viewerjs 灯箱。** 第三方库承载全部缩放/旋转/导航能力，项目只是薄封装。

**错误边界采用"应用级钩子 + 探针/watchdog + 启动兜底界面"，无组件级 ErrorBoundary。** `main.ts` 的四个全局钩子把未捕获错误接进统一 errorHandler 分级反馈并上行 Rust 探针日志；用户可见兜底集中在启动阶段（WebView 兼容性界面、启动失败界面）与业务场景 Toast，运行期渲染错误没有组件级降级 UI。

**首帧防闪靠"窗口先隐藏 + 静态 splash 媒体查询兜底"，无内联主题脚本。** 与 DeepChat 的 show:false + ready-to-show 思路类似，但 AIO 的窗口显示由前端挂载后触发而非 Rust ready-to-show；固定主题与系统偏好相反时存在理论上的主题切换帧（未运行验证）。

**跨窗口同步分四条互不重叠的通道。** 聊天运行态走 useWindowSyncBus（状态 + 操作代理），通知走 localStorage storage 事件，设置/主题走 `settings.json` 文件，窗口布局由 Rust 持有 `window-configs.json`。

**theme-changed 事件已无监听者。** 代码注释声明的订阅用途与现状不符（仅 2 处 dispatch，无 addEventListener），目前不影响功能但属于失效的通信约定。

**无障碍初步阶段。** llm-chat 仅批量管理表格有主动 ARIA；会话切换与树图操作无键盘路径（静态结论）。

## 9. 未验证事项

- ElMessage/ElNotification 堆叠像素细节未运行截图验证（仅确认走 Element Plus 默认堆叠）。
- llm-chat 每个组件深色模式下的实际视觉效果未逐一验证（只确认变量机制存在且被使用）。
- 无障碍结论基于静态代码搜索，未经屏幕阅读器实测，不能作为 WCAG 合规结论；el-dropdown 键盘可达性由 Element Plus 提供，未独立验证。
- 引导流程各步骤的实际引导体验未运行验证。
- 界面层未找到以下能力（相关关键词全项目静态搜索，未经运行时可用性测试）：系统级桌面通知及生成完成联动；树图右键菜单的方向键操作和 Esc 关闭；会话列表键盘切换；头像裁剪；消息列表逐条 loading 骨架屏；侧栏折叠/展开过渡动画。首次启动引导由 GuidedFlow 引导流程系统与升级/迁移引导承担，不属于缺失清单。
- 固定主题与系统偏好相反时，LoadingScreen 阶段的主题切换帧是否可见未运行验证；`useDark()` 初始值（localStorage vueuse-color-scheme 键与 matchMedia 回退、`dark` class 挂到 documentElement）为 VueUse 内部行为，未下钻 node_modules。
- 渲染进程崩溃/白屏场景：Linux 15s 诊断 overlay、前端心跳与 Rust watchdog（20s 告警/60s 升级）的实际表现未运行验证；get_frontend_probe_status 无前端调用方，探针数据仅落日志（静态确认）。
- useWindowSyncBus 的握手/心跳/增量同步/10s 操作超时在真实多窗口运行中的行为未运行验证（仅确认消息类型、注册与调用路径）。
- window 级 error/unhandledrejection 钩子对白名单过滤之外的错误在运行中的 Toast 呈现未实测。
- 主题外观系统全部为静态核对，未运行验证：壁纸提取（ColorThief/node-vibrant）的真实取色效果、OKLCH 修正后的视觉观感、16 种混合模式的叠加表现、毛玻璃与分层透明度的实际渲染、no-global-wallpaper 分离窗口表现；initThemeAppearance 初始化失败/清理路径未实测。
- OS 级窗口特效（mica/acrylic/blur/vibrancy）在不同平台与窗口系统（Windows 版本差异、macOS 透明）下的可用性与降级表现未运行验证。
- iframe 主题注入（useIframeTheme）与 SVG 单色替换（useThemeAwareIcon）在真实内容（含 JS 动态改色的 SVG）上的表现未运行验证。
- 自定义 CSS 的实时覆盖、预设预览、保存和主/分离窗口启动恢复已静态确认；未运行验证大段或无效 CSS 的编辑性能、窗口初始化时的实际视觉效果，以及一个窗口运行期修改后其他已打开窗口何时更新。

## 10. 关键源码索引

- `src/components/common/BaseDialog.vue`
- `src/composables/useDialogZIndex.ts`
- `src/utils/customMessage.ts`
- `src/utils/errorHandler.ts`（290-390 行三级反馈）
- `src/components/notification/NotificationCenter.vue`
- `src/components/GlobalProviders.vue`
- `src/composables/useResizable.ts`
- `src/composables/useFileDrop.ts`
- `src/composables/useTheme.ts`
- `src/utils/themeColors.ts`（主色色阶引擎 + OKLCH）
- `src/composables/useCssOverrides.ts`
- `src/views/Settings/css/CssOverrideSettings.vue`
- `src/config/css-presets.ts`
