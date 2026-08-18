# Cherry Studio 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 已将弹窗主路径迁移到内部 UI 包。该包封装 Radix Dialog，业务侧再通过模块级 popup store 和每窗口一个 PopupHost 获得命令式调用能力。Toast 也是自研单例，支持 loading 到 success 或 error 的状态衔接，并区分警告与状态消息的可访问语义。

主题权威源位于 Electron 主进程，渲染进程订阅主题变化。视觉 token 在 UI 包中分层组织，从基础色板、产品语义到 Tailwind 映射均有清楚契约和校验脚本。用户可设置明暗、单一主色、字体和自定义 CSS，但没有主题市场、壁纸或主题文件导入导出。

上下文菜单可以在项目自绘菜单和系统原生菜单之间切换。弹窗焦点等细节大多由 Radix 提供，静态调查只能确认项目侧接入和覆盖项，实际键盘与多窗口表现仍需运行验证。

## 系统边界与总体装配

**界面栈。** React + Tailwind（含 tw-animate-css）；内部 UI 包首次以 `@cherrystudio/ui` 标识，源码位于 packages/ui，基于 Radix 生态；无 antd、无 framer-motion、无 react-hot-toast/sonner。

**弹窗装配。** 每个窗口挂一个 PopupHost，订阅模块级 PopupService（`src/renderer/services/popup/PopupService.ts`，useSyncExternalStore 驱动，不依赖 React context）；

无 host 时（启动早期）两个弹窗入口直接 resolve 默认关闭结果并打 warn（`PopupService.ts:100-103, 124-127`），"popups are not usable on a startup path" 是代码原话。

**Toast 装配。** services/toast.ts 只包一层 i18n 标签解析，真正实现在 UI 包的 toast.tsx——模块级 `createToastStore()`（`toast.tsx:70-162`）配合 useSyncExternalStore，

全应用共享 defaultToastStore（`toast.tsx:290-297` 的注释解释不按 provider 分叉的原因：分叉会导致命令入口和实际渲染 viewport 落在不同 store 上，"quickAssistant black-hole bug"）。

## 1. 界面栈、公共组件与状态所有权

**状态所有权。** 弹窗状态在模块级 PopupService store（React 组件树外），Toast 在模块级 toast store；两套都是“命令入口与渲染 viewport 共享同一 store”的单例设计。

**主题状态。** 权威在主进程 ThemeService，渲染层订阅 IPC（见第 4 节）。

**窗口装配。** 每窗口挂 PopupHost；AppShell 进入聊天工作台时调整主窗口最小尺寸（见第 5 节）。

## 2. 弹窗、浮层与菜单

### 弹窗/对话框（自建 Radix 封装 + 两套调用入口）

对话框基础组件是 UI 包基于 `@radix-ui/react-dialog` 封装的 Dialog/DialogContent（`packages/ui/src/components/primitives/dialog.tsx:10-149`）：

**Esc/遮罩关闭。** DialogOverlay 点击默认触发 Radix 的 Dialog.Close（`dialog.tsx:101-108`），可用 closeOnOverlayClick=false 关掉；Esc 键关闭是 Radix Dialog.Root 默认行为，代码里没有覆盖 onEscapeKeyDown，所有 Dialog 默认支持 Esc 关闭。

业务层确认弹窗（`ConfirmPopupItem.tsx:121-124`）额外用 onInteractOutside 手动挡遮罩点击（`maskClosable === false` 时 `event.preventDefault()`），是 Radix 上叠加的业务开关。

**焦点管理。** DialogContent 默认交给 Radix FocusScope 处理关闭后焦点归还，但专门开了转义口子 focusOnClose（ConfirmPopupProps.focusOnClose，`packages/ui/src/services/popup/types.ts:76-90`）——原因写得很直白：Radix 默认把焦点还给"打开弹窗前聚焦的元素"，但命令菜单/Popover 里触发的弹窗触发者早已卸载，Radix 会把焦点落在过期元素或 document.body 上；

focusOnClose 让调用方在 onCloseAutoFocus（`ConfirmPopupItem.tsx:111-119`）里先阻止默认行为，再精确指定焦点落点，不用 race requestAnimationFrame。

**两套调用入口。** ①`createPopup<P,R>` 用于自定义交互弹窗（图片预览、编辑名称对话框），返回 `show()/hide()`，`show()` 是 single-flight（重复调用复用同一 promise，`types.ts:21-24`）；

②`popup.confirm/error/info/warning` 四个 "prefab" 走 showConfirm，Promise 只解出 boolean，无 `onOk/onCancel` 回调，也没有 antd 时代的 `Modal.destroyAll/update/warn/success`（`types.ts:39-59` 注释明确列出被砍掉的 API 面）。

两阶段关闭：settle() 先 resolve promise 并把 open 置为 false（播放退场动画），等待 200ms 的退场延迟（`packages/ui/src/utils/dialog.ts:5`）后才真正从 store 移除（`PopupService.ts:74-87`）。

**动画。** 开合动画不是 JS 补间，是 Radix `data-[state=open|closed]` 属性配合 Tailwind 动画类的纯 CSS 方案（见第 7 节）。

### 右键/上下文菜单：双模式，设置里可切换 Cherry 自绘 vs 系统原生

菜单走统一 CommandContextMenu/CommandPopupMenu 抽象（`src/renderer/components/command/CommandMenus.tsx`），由偏好项 menu.presentation_mode（cherry 或 native，默认 cherry，`src/shared/data/preference/preferenceSchemas.ts:440,748`）决定渲染路径：

**cherry 模式。** 渲染 Radix ContextMenu/ContextMenuContent（`CommandMenus.tsx:554-584`），菜单项支持子菜单、勾选态、危险态（`variant="destructive"`）、shortcut 标签、tooltip 说明。

**native 模式。** `event.preventDefault()` 后调 window.api.command.showNativePopupMenu(...) 把菜单模型序列化成 NativePopupMenuModel 丢给主进程弹系统原生右键菜单（`CommandMenus.tsx:469-540`），点击结果经 IPC 返回再本地执行。

设置 > 外观 > 右键菜单样式（`AppearanceSettings.tsx:198-199,394`）切换，切换后需重启应用生效（`AppearanceSettings.tsx:91-92` 有专门重启提示 popup）。
- Topic 行、Agent Session 行的右键菜单经 ResourceListActionContextMenu（`src/renderer/components/chat/actions/ResourceListActionContextMenu.tsx:21-27`）包一层——里面写明原因："一个动作若带 inline confirm，会被转成 ConfirmActionPopup 在弹窗里执行，因为系统原生菜单没法承载内嵌确认框"。
- 消息正文右键菜单是另一路：`SelectionContextMenu.tsx`（选中文本时"复制/引用到主窗口"），专门剥离代码块行号（`.line-number` 过滤，`SelectionContextMenu.tsx:18-54`），保证复制代码不带行号前缀。图片有自己的第三路右键菜单（见第 6 节）。

## 3. 通知、加载态与错误反馈

### Toast（自研 store，非 antd message/react-hot-toast/sonner）

**位置。** ToastViewport 固定在屏幕顶部居中，消息纵向堆叠（`toast.tsx:372-380`）。

**自动消失时长。** 默认时长为 3000ms（`toast.tsx:51`）；成功类型的 loading→success 转换默认更短，为 2000ms（`toast.tsx:223`）；错误转换默认不自动消失（`toast.tsx:242`）；loading 类型永不自动消失（`toast.tsx:116-118`）。

**loading→success/error 的 promise 桥接。** `toast.loading({ promise, onError })` 跟踪一个 Symbol 令牌（loadingTokens），只有令牌匹配才允许把 loading 状态"续写"为 success/error（`toast.tsx:189-249`），防止同一 key 被后来的 loading 覆盖后旧 promise resolve 误写状态。

**无障碍。** getToastA11yProps（`toast.tsx:313-319`）按严重程度区分语义：warning/error 用 role=alert 和 aria-live=assertive，其余用 role=status 和 aria-live=polite；关闭按钮有关闭标签（`toast.tsx:346`）。
- 用例（`Topics.tsx:340-372`）：导出图片时 `toast.loading({ key, promise, onError: () => {} })`，promise resolve/reject 后各自 toast.success/toast.error。

### Loading / 骨架屏 / 空状态（三种场景三种呈现，工具执行没有独立骨架）

- **消息加载中**（Topic 切换/首次进入）：MessageListInitialLoading（`src/renderer/components/chat/messages/layout/MessageListLoading.tsx:6-52`）用 `@cherrystudio/ui` 的 Skeleton 拼三条假消息（一条用户气泡 + 两条助手气泡骨架），`aria-busy="true"` 标注容器，`aria-hidden="true"` 标注骨架本体。

  **特意延迟 160ms**（MESSAGE_LIST_INITIAL_LOADING_DELAY_MS）才显示骨架——消息在 160ms 内加载完骨架根本不闪一下，是刻意的防闪烁设计。

**Topic 列表为空。** TopicListBody 的 emptyFallback（`Topics.tsx:1662` 附近）是一段居中纯文本 t('chat.topics.empty.title')，无插图/图标；列表加载中另有一行文字提示"common.loading"（`Topics.tsx:1391-1395` 附近）。

**工具调用执行中。** 没有独立骨架屏，走行内状态指示——Topic 列表行右侧运行指示统一为跨面板组件 ConversationRowStatus（`src/renderer/components/chat/resourceList/base/ConversationRowStatus.tsx:20-51`）：状态由 `Topics.tsx:1727-1735` 派生，pending 用 Loader2 旋转图标、error 用 CircleAlert、绿色小圆点表示"已完成但未读"（read-receipt 语义，!isActive 才显示，悬停/聚焦时淡出让位给 pin/delete 按钮）、等待审批显示 warning 徽标；

指示器带 aria-label + `role="img"`。红/绿视觉区分（避免早期版本"脉动琥珀色点"被误读成警告）的设计历史注释仍在代码中。消息内部工具调用块（ToolBlockGroup/PlaceholderShimmerText）用的是 animation-shimmer 文字光泽扫过效果，不是块状骨架。

### 错误边界与崩溃恢复（react-error-boundary 分层；渲染进程无全局 error 兜底）

- **React 错误边界分三层**，基座是第三方 react-error-boundary@^6.0.0（`package.json:402`）加自封装 `@renderer/components/ErrorBoundary`（`src/renderer/components/ErrorBoundary.tsx:42-62`，onError 只走 loggerService 记录并透传可选回调）：
  - **窗口级（Provider 之外的最外层）**：主窗口、子窗口、快捷助手和两个选区工具窗口都在 Provider 外包裹 ErrorBoundary。这样 Provider 初始化失败时也会进入 WindowFatalFallback，而不是直接白屏。（`MainApp.tsx:78-81`）

    WindowFatalFallback（`src/renderer/components/WindowFatalFallback.tsx:16-42`）在无任何 React context 的环境渲染：i18n 走全局单例（禁止 useTranslation）、样式只能靠 :root token 默认值（ThemeProvider 没跑到，主题留在浅色），并主动移除启动 `#spinner` 残留覆盖层（否则 Provider 崩溃时全屏 spinner 遮罩挡住点击）；

    呈现错误 Alert（formatErrorDetails 过滤后的详情，用户文案"似乎出现了一些问题..."，`zh-cn.json:2507`）+ "打开调试面板"/"重新加载"两个按钮（system.toggle_dev_tools/window.main.reload）。
  - **路由/tab 级**：TanStack Router defaultErrorComponent: RouteErrorFallback（`TabRouter.tsx:28-31`）——路由渲染错误限定在单个 tab，可原地 `reset()` 重试（`RouteErrorFallback.tsx:26`），不炸掉整个窗口。
  - **消息/块级**：每条消息包 MessageErrorBoundary（手写 class 组件 getDerivedStateFromError，`src/renderer/components/chat/messages/frame/MessageErrorBoundary.tsx:34-50`，`role="alert"`，生产隐藏具体 error.message 只显示通用文案、仅 dev 显示详情）；

    `MessagePartsRenderer.tsx:153,165` 与 `ToolBlockGroup.tsx:552` 用 BlockErrorFallback（`BlockErrorFallback.tsx:6-15`，同样 dev-only 详情）。

    局部还有 `FilePreview.tsx:151`（直接 import react-error-boundary）、`McpServerCard.tsx:217`、`RightPanel.tsx:497`、ResourceList 的 errorFallback（`Topics.tsx:1661`）。
  - **双实现并存**：`packages/ui/src/components/primitives/error-boundary/index.tsx`（首行注释 "Original path: src/renderer/components/ErrorBoundary.tsx"）是另一份平行封装（英文默认文案、props 面不同：errorMessage/onDebugClick/onReloadClick），全仓库只在 UI 包自己的 stories 里使用；

    渲染层实际消费的是 `@renderer/components/ErrorBoundary`。

**全局错误监听。** 渲染进程**本次未找到** window.onerror/addEventListener('error')/unhandledrejection 挂载——全仓库 grep unhandledrejection 零命中，渲染层 onerror 全部是 img/FileReader/XHR 的元素级属性。

主进程在 app ready 前初始化崩溃遥测。生产环境记录未捕获异常和 Promise 拒绝，Electron crashReporter 只写本地文件、不上传；每个 webContents 还会启用 JS 调用栈收集，便于诊断无响应。（`src/main/core/preboot/crashTelemetry.ts:36-99`）

**渲染进程崩溃（render-process-gone）。** 主窗口 setupMainWindowMonitor（`src/main/services/MainWindowService.ts:241-255`）——记录日志后，距上次崩溃 >60s 自动 `webContents.reload()` 恢复，≤60s 判为连环崩溃 forceExit(1)。

其它窗口：userDataRelocation 迁移窗口在非关键阶段崩溃/无响应自动 `requestRestart()`（`src/main/services/userDataRelocation/window.ts:110-119`）、v2 迁移窗口直接 forceQuit（`MigrationWindowManager.ts:121-123`）、`ProtocolService.ts:55` 崩溃即标记主渲染器未就绪。

child-process-gone 全仓库零命中（HTML artifact 预览 webview 只见 will-attach-webview 配置校验，未见崩溃监听）。

## 4. 主题、视觉 token 与持久化

完整链路分四层：主进程权威状态 → 渲染层订阅与首帧防闪烁 → UI 包的 Design Token 契约 → 用户自定义（主色/字体/CSS 覆盖），另有一条自定义 CSS 旁路。

1. **主进程权威状态**：ThemeService（`src/main/services/ThemeService.ts:8-38`）持有偏好 ui.theme_mode（`light`/`dark`/`system`），启动时写进 Electron 的 nativeTheme.themeSource（系统原生 UI——原生右键菜单、系统对话框——也跟着变色）；

监听 nativeTheme.on('updated', ...)，OS 主题变化即广播 IPC 事件 system.native_theme_updated，payload 是解析后的实际颜色（`dark`/`light`，已不含 `system`）。
2. **渲染层订阅 + 首帧防闪烁**：ThemeProvider 用 useState 初始值直接读已保存偏好而不是等 effect（`ThemeProvider.tsx:34-36` 注释：“入口在渲染前已经 await 过偏好预加载，等 effect 里的同步会先提交一帧 OS 主题，当保存主题和 OS 不同时会闪一下”）；

`settedTheme === system` 时先用 window.matchMedia('(prefers-color-scheme: dark)') 本地即时判断（getSystemTheme，`ThemeProvider.tsx:24-25`）撑住首帧，随后等 IPC system.get_native_theme 请求回来对齐权威值（:86-94）。

切换实际主题只是给 document.documentElement/document.body 加减 `light`/`dark` 类名（tailwindThemeChange，:18-22）。

Electron 侧配合：主窗口 showMode: 'manual'（`src/main/core/window/windowRegistry.ts:42,57`），首次显示完全由 ready-to-show 回调控制（`MainWindowService.ts:326-338`，托盘启动可压制首显）；

窗口创建时 backgroundColor 直接按 nativeTheme.shouldUseDarkColors 取 `#181818`/`#FFFFFF`（`MainWindowService.ts:188-190`），内容加载前的窗口底色已与主题一致。

全仓库 prefers-color-scheme 消费面只有 ThemeProvider 这一处（另有一处 `MigrationApp.tsx:410` 用于迁移窗口自身首帧判断）。
3. **Design Token 体系（packages/ui/src/styles，契约分层 + 生成器）**：UI 包内含一套正式的分层 CSS 契约，contract.css 声明导入顺序必须单向：“foundation providers → runtime inputs → official Shadcn semantics → product semantics”（`contract.css:1-13`）：
   - **基础色板（foundation）**：`tokens/index.css` 汇总 `tokens/colors/primitive.css`（23 个色族 × 50-950 共 10 阶 + `--cs-black`/`--cs-white`/`--cs-brand-*`，全部 oklch 值，

     `primitive.css:6-309`）、`tokens/colors/status-legacy.css`（冻结的旧状态色板，

     只缩不扩）、`tokens/colors/providers.css`（语义提供层：`--cs-primary`=`--cs-brand-500`、`--cs-destructive`/`--cs-success`/`--cs-warning`/`--cs-info` 及其 subtle/border 反馈契约、sidebar 子调色板、light/dark 双模式分写，

     `providers.css:13-165`），以及 `tokens/spacing.css`/`tokens/radius.css`/`tokens/typography.css`（`--cs-size-*`/`--cs-radius-*`/`--cs-font-*` 等设计刻度）。
   - **受控运行时输入**：`theme-input.css` 定义 `--cs-theme-primary`/`--cs-theme-primary-foreground` 的默认值（`var(--cs-primary)` 等），是唯一允许运行时主题逻辑写入的共享变量子集（`theme-input.css:9-13`）。
   - **官方 Shadcn 契约（公共 API）**：`shadcn.css` 把 `--background`/`--primary` 等官方无前缀变量全部 `var()` 转发到 `--cs-*`（`shadcn.css:11-54`），文件顶部注释解释原因：官方变量名不加前缀是"生态兼容性"——第三方 Shadcn 主题（如 TweakCN）可直接套用。`--radius: var(--cs-radius-lg)` 也是契约输入之一，但用户侧没有可调圆角的设置（见下方"未找到"）。
   - **Cherry 产品语义层**：`product.css` 在同一个无前缀公共命名空间里追加产品扩展（`--background-subtle`/`--link`/`--success`/`--warning`/`--info`/`--error` 系列、`--code-block`/`--inline-code`、`--reference`/`--highlight`、`--chat-user`、`--resource-list-row-*`，

     light/dark 分写，`product.css:10-80`）。
   - **Tailwind 适配层（生成产物）**：`theme.css` 由 pnpm theme:build（`packages/ui/scripts/build-theme-css.ts`，package.json 脚本 theme:build/theme:check）生成，用 Tailwind v4 @theme inline 把上述语义映射成 `--color-*`/`--radius-*`/`--font-*` 等工具类层（`theme.css:11-453`），文件头部标注"DO NOT EDIT DIRECTLY"。

     配套约束工具：`scripts/theme-contract.ts`、`check-theme-contract.ts`、`validate-theme-contract.ts`、`migration-registry.ts` + `scripts/migrations/shadcn-v2.json`；

     契约规范见 `packages/ui/docs/design-token-system.md`（v2 契约：无前缀语义是唯一公共 API、`--cs-*` 只是内部 provider、`--cs-theme-*` 是受控输入、`--app-*` 属 owner-local）、`variable-catalog.md`、`migration-plan.md`、`styles-reference.md`。
    - **消费规则**：组件只消费无前缀公共变量（bg-background/text-foreground 等工具类），不直接引用内部变量。
4. **用户自定义主题**：外观设置提供明暗三态预览、五个预设主色、任意颜色输入，以及全局字体和代码字体选择。字体列表通过 IPC 从系统字体表取得。（`AppearanceSettings.tsx:148-162,283-341,621-660`）

`useUserTheme.ts` 把这些偏好直接写 document.documentElement 行内样式：`--cs-theme-primary` + `--cs-theme-primary-foreground`（后者用 getForegroundColor 按 WCAG 相对亮度、阈值 0.179 选黑/白，`src/renderer/utils/style.ts:138-145`），以及 `--app-user-font-family`/`--app-user-code-font-family`（`useUserTheme.ts:19-26`，属于 `--app-*` owner-local 命名空间）；

字体变量被 `src/renderer/assets/styles/font.css:3,13,19,25` 的 UI/代码字体栈兜底消费。livePreview 时不需要重新生成样式表。**没有色阶生成引擎**：用户主色只产出 primary + 对比前景两个变量，不生成 50-950 色阶，也没有 dark 变体；

`--cs-ring` 的 light 值用 `color-mix(in srgb, var(--cs-primary) 40%, transparent)` 跟随主色，dark 值则是硬编码 `oklch(0.76 0.204 131 / 0.4)` 不随用户主色变化（`providers.css:41,121`）。

`.dark` 块中未覆盖 `--cs-theme-primary`，即用户主色在明暗模式下是同一个色值。
5. **用户自定义 CSS（旁路注入）**：偏好 ui.custom_css（`preferenceSchemas.ts:516,810`）在设置 > 外观用 CodeMirror 编辑（`AppearanceSettings.tsx:538-562`）；

`useCustomCss.ts` 把文本原样同步进 `<head>` 的 `<style id="user-defined-custom-css">` 单元素（先删旧节点防重复、卸载时移除、空值/v1 标记内容不注入，`useCustomCss.ts:17-34`）。

注入点覆盖所有常规 UI 窗口：main/subWindow 走 `useWindowRuntime.ts:52` 的公共 hook，另有 quickAssistant（`QuickAssistantApp.tsx:20`）、selection toolbar/action（`SelectionToolbarApp.tsx:14`、`SelectionActionApp.tsx:18`）；

preboot 迁移窗口（migrationV2/userDataRelocation）不初始化偏好、不注入（`useCustomCss.ts:38-40` 注释）。

v2 迁移时旧版 settings.customCss（redux 时代）被迁移到 ui.custom_css 并加 V1_CUSTOM_CSS_MARKER（`/* cherry-studio:custom-css:v1 */`）头标记——被标记的内容视为"对 v2 界面不安全"而拒绝注入（`src/shared/utils/customCssMigration.ts:1-17`、`src/main/data/migration/v2/migrators/mappings/ComplexPreferenceMappings.ts:93-97`），设置页显示迁移提示横幅（`AppearanceSettings.tsx:540-542`）。
6. **存储位置**：相关偏好键都在渲染层 usePreference 持久化——ui.theme_mode、ui.theme_user.color_primary、ui.theme_user.font_family/code_font_family、ui.custom_css，底层落在偏好存储（落盘格式未展开细查）。

**本次未找到的主题能力**（检查范围：`src/` + `packages/ui/` 全文 Grep）：①主题市场/商店/下载主题——themeMarket/ThemeStore/downloadTheme/installTheme/applyTheme 零命中，marketplace 相关命中全部是 skill 市场（SkillMarketplaceDialog）和 MCP 市场（McpMarketList），与主题无关；

zh-cn 词条 settings.theme 段只有 color_primary/title 两个 key；②壁纸/背景图——wallpaper/backgroundImage/background_image 零命中；③主题文件导入导出——importTheme/exportTheme/`theme.json`/`themes/` 目录零命中；

④密度/圆角用户设置——`preferenceSchemas.ts` 无相关偏好（compact 仅 feature.selection.compact 属选择工具栏，radius 只是 token 常量 `--cs-radius-lg` 不可配置）。即主题个性化面只有"明暗模式 + 单主色 + 字体 + 自定义 CSS"，无主题包生态。

## 5. 响应式、移动端与窗口适配

**没有断点驱动的侧栏折叠。** 检索侧栏容器和 ResourceEntityRail 未发现 ResizeObserver、matchMedia 或 CSS @container 驱动的自动折叠——侧栏展开/折叠是**手动命令**（app.sidebar.toggle，`HomePage.tsx:408`），不随窗口变窄自动收起。

**主窗口最小宽度随页面动态调整。** 进入聊天工作台时 AppShell 调用 IPC 把主窗口最小尺寸从默认 960px（`src/shared/utils/window.ts:1`，

写在 `windowRegistry.ts:63` 的窗口创建配置里）临时放宽到 `SECOND_MIN_WINDOW_WIDTH=520px`（`AppShell.tsx:140` 的 window.main.set_minimum_size），离开时还原——聊天页允许把窗口拖得比其他页面更窄。

**阅读宽度限制是另一套独立机制。** `NarrowLayout.tsx` 把消息内容限制在 800px（chat.narrow_mode 偏好开关，默认 `true`，`preferenceSchemas.ts:184,587`），是用户可关闭的排版偏好，不是响应式断点。

## 6. 图片、附件、拖放与常见内容交互

### 图片灯箱与代码块交互

**图片有完整灯箱。** `ImageViewer.tsx` 包 `@cherrystudio/ui` 的 ImagePreviewDialog（`packages/ui/src/components/composites/image-preview/image-preview-dialog.tsx`），支持缩放/旋转/水平垂直翻转/上一张下一张（多图导航靠 activeIndex，`ImageViewer.tsx:107-155`），工具栏和右键菜单共享同一份 action 列表（复制图片、复制图片地址、下载，`ImageViewer.tsx:201-232`），右键菜单走第 2 节的统一 CommandContextMenu（:296-298）。

所有操作都有 toast 反馈（成功/失败，:157-199）。"保存为图片"动作会把旋转/翻转**烘焙**进输出的 PNG（transformImageToPng，d1ffaa82ce；全屏观看交互 e22a976586）。

**代码块复制/运行的交互反馈。** 复制按钮点击后图标临时切换成对勾（`useCopyTool.tsx:18-31,51`，useTemporaryValue hook 控制“临时态”多久后自动复原），并弹 toast（`CodeBlockView.tsx:154-164`）。复制图片按钮也有独立的临时状态。

"运行"仅对 Python 代码块生效（`isExecutable = codeExecutionEnabled && language === 'python'`，`CodeBlockView.tsx:114-116`），执行走**浏览器内嵌 Pyodide**（pyodideService.runScript，:189-203）而不是主进程子进程，超时由偏好 chat.code.execution.timeout_minutes 控制，执行结果（文本/图片）展示在代码块下方 StatusBar（一个纵向滚动 bg-muted 面板）。

工具栏本身是可弹出子菜单的 CodeToolButton（`CodeToolButton.tsx`，支持 Enter/Space 键盘触发，:14-22，有 `aria-label={tool.tooltip}`）。

代码查看器 wrapped 模式下超长不可断行内容（base64/URL/minified JSON）强制换行而非截断溢出（`CodeViewer.tsx:638-642` 的 min-w-0 + whitespace-pre-wrap!，205f042800）。

### 拖放细节

**Composer 附件拖入。** 拖拽经过 `useFileDragDrop.ts`（文件、文本、文件夹路径分别处理，不支持类型会 toast 提示，:122-129），视觉反馈是 2px 绿色虚线边框 + 半透明绿色蒙层（`ComposerSurface.tsx:2171-2173`，硬编码色值 `#2ecc71`，不走 CSS 变量主题色）。

**Topic 拖拽排序。** 只有按"助手分组"显示时才可拖（canDragTopicItem/`dragReady = isAssistantDisplayMode && ...`，`Topics.tsx:1136-1139,797`），按"时间分组"显示时完全不可拖——有意为之的限制（时间分组顺序由时间戳决定，拖拽没有语义）。

助手分组可整组拖拽重排（canDragTopicGroup/handleTopicReorder 的 `payload.type === 'group'` 分支，:1150-1158,1187-1231），带乐观更新和失败回滚（setOptimisticAssistantOrderIds，失败时 toast + 回滚，:1215-1228）。
- Session（Agent 会话）列表的独立拖拽排序未在范围内找到实现（`SessionItem.tsx` 只在右键菜单命中），如需确认建议单独检索 `src/renderer/pages/agents`。

## 7. 扩展调查：无障碍、动画、桌面集成

### 无障碍（静态代码结论）

**做得到位的地方**：
- ResourceList（Topic 列表、Agent Session 列表共用）实现标准 **roving tabindex + aria-activedescendant** 模式：容器 `role="listbox"`（`ResourceListVirtual.tsx:551,777`），行 `role="option"` + aria-selected（`ResourceList.tsx:388-394`），

  键盘 `ArrowUp/ArrowDown/Home/End/Enter` 都有对应测试覆盖并断言 aria-activedescendant 正确移动（`__tests__/ResourceList.test.tsx:622-671`）。
- Toast 有 `role="alert"`/`role="status"` + aria-live 区分严重程度（第 3 节）。
- 折叠交互（用户消息折叠、Thinking 块展开/收起）用了真实 aria-expanded/aria-controls（`MainTextBlock.tsx:234-235`、`ThinkingBlock.tsx:95-96`），并且是可聚焦、可键盘触发的 `role="button"` + onKeyDown 处理 Enter/Space（`ThinkingBlock.tsx:93-105`），不是纯鼠标 div。
- 消息操作栏**部分**按钮显式传了 aria-label：模型选择器（renderModelPickerToolbarAction，`MessageMenuBarToolbarRenderers.tsx:287`）、翻译（:311）、更多菜单弹出按钮（:355,412）。

**实证的缺失**：消息操作栏最常用的一批按钮——默认渲染路径 renderDefaultToolbarAction → ActionButtonWithConfirm（`MessageMenuBarToolbarRenderers.tsx:63-126`，覆盖复制、编辑、重新生成、删除、点赞等大多数没有专属渲染函数的 action）——生成的 `<MessageActionButton>` **没有传 aria-label**（对照 :80-91 和 :103-113 两处按钮 JSX，都只有 onClick/disabled/className，无任何 aria-* 属性）。

可访问名称完全依赖视觉 Tooltip（`content={tooltip}`，:119-125），而 Tooltip 内容不会自动同步成 aria-label——screen reader 用户只会读到"button"没有任何描述。

不是全局性缺陷（Topic 列表 pin/delete 都传了 aria-label，`Topics.tsx:1737,1750`），而是消息操作栏这一条渲染路径的具体疏漏，覆盖面恰是使用频率最高的复制/编辑/删除等动作。

**其它**：富文本输入框（composer，基于 TipTap EditorContent）本身没有为 contentEditable 根节点设置 aria-label/`role="textbox"`——`RichEditor.tsx`、`ComposerSurface.tsx` 全文只有编辑器外围工具按钮有 aria-label（`ComposerSurface.tsx:2114-2207`），输入区域本体依赖浏览器/TipTap 默认可编辑语义。

prefers-reduced-motion 方面唯一相关的是 Radix 动画类统一带 motion-reduce:animate-none（`dialog.tsx:35,127`），业务层滚动/淡入交互是否都遵循未逐一确认。

### 动画/过渡（无 Framer Motion，全部 CSS/Tailwind + Radix data-state）

`package.json` 全文搜索 framer-motion **无匹配**。三层方案：

1. **tw-animate-css**（`package.json:426`）+ Radix 的 `data-[state=open|closed]` 属性驱动 Dialog/ContextMenu/Tooltip/Popover 进出场（`dialog.tsx:33-37,123-127`：fade-in-0/zoom-in-99/slide-in-from-bottom-4 等，进场 260ms、退场 200ms，统一 motion-reduce:animate-none）。
2. **手写 CSS @keyframes**：`src/renderer/assets/styles/animation.css` 的 animation-shimmer（3s 线性循环，文字渐变光泽扫过，用于 Topic 重命名加载态和工具调用占位文本 `PlaceholderShimmerText.tsx`）与 animation-reveal（0.5s，重命名刚完成时的"揭示"效果，`Topics.tsx:1634-1638` 消费）。
3. **纯 CSS transition**：折叠展开（Thinking 块、用户消息折叠）用 hidden 属性硬切换 + chevron 图标 transition-transform duration-200（`ThinkingBlock.tsx:134-138`、`MainTextBlock.tsx:244`）——内容本身没有高度动画，只有箭头旋转有过渡，"展开"在视觉上是瞬时的。

消息栏悬停显隐、滚动到底按钮出现都是 opacity/duration-150 级简单 CSS transition（`MessageFrame.tsx:34,119`；`MessageVirtualList.tsx` 的 ScrollToBottomButton）。

### 桌面端集成（Electron）

**托盘。** `TrayService.ts` 在 mac 上根据 nativeTheme.shouldUseDarkColors 切换亮/暗两套托盘图标（:29）；点击托盘图标行为受偏好 feature.quick_assistant.click_tray_to_show 控制——开则唤起 QuickAssistant 悬浮窗，关则唤起主窗口（:61-71）；托盘本身不显示未读消息数/流式状态角标（未检索到 setBadgeCount/flashFrame/setOverlayIcon 调用）。

**系统通知。** NotificationService（主进程，`src/main/services/NotificationService.ts`）用 Electron 原生 Notification API，点击通知会 `showMainWindow()` 并广播 notification.clicked（:14-17）。

渲染层 `notificationService.send()`（`src/renderer/services/notification/NotificationService.ts:10-24`）先查三个偏好开关（assistant/backup/knowledge）再决定是否真的调 IPC 发送。

**一个值得记录的空路径。** 偏好 app.notification.assistant.enabled 和对应设置项开关（`NotificationSettings.tsx:36-48`，"助手回复完成通知"）确实存在，但**全仓库检索不到任何一处 `notificationService.send({..., source: 'assistant'})` 调用**——实际发通知的三处调用点（`BackupService.ts` 七处、`useAppUpdateHandler.ts` 一处）分别用 source: 'backup' 和 source: 'update'。

即"助手完成回复时弹系统通知"这个开关目前接不到任何触发点，是个用户能看到、能勾选、但不会生效的空挂钩（不同于代码里自己写 TODO 承认的 update 缺口，见 `NotificationService.ts:17-20`）。

**全局快捷键。** `ShortcutService.ts` 按**本地/全局分轨**注册——global 标记的仍走 globalShortcut（含失焦时的注册集），其余本地快捷键不再注册到系统，而是挂在窗口 webContents.before-input-event（含 did-attach-webview 挂上的 guest webview 输入）上按命令解析拦截（`ShortcutService.ts:123-196`），应用失焦时本地快捷键自然不生效；

快捷键冲突（被其他应用占用）记录冲突集合并经 IPC 广播给渲染层展示提示（:281-303 附近）。另有标签页导航快捷键（324f26f728）。**未找到独立的"快捷键帮助面板/速查表"浮层**——只有"设置 > 快捷键"这一个静态配置页（`ShortcutSettings.tsx`），不存在按一个快捷键呼出速查列表的入口。

## 8. 设计取舍与已确认边界

**弹窗无 host 时降级 resolve。** 启动早期不挂起等待，直接以默认结果关闭并 warn。

**focusOnClose 转义口子。** 承认 Radix 默认焦点归还在"触发者已卸载"场景失效，业务侧显式指定落点。

**Toast 单例不分叉。** 宁可全局共享一个 store，避免命令入口与渲染 viewport 分离（"quickAssistant black-hole bug"）。

**消息操作栏缺 aria-label。** 默认渲染路径的图标按钮只靠视觉 Tooltip，读屏读到"button"无描述——覆盖面是复制/编辑/删除等高频动作。

**"助手回复完成"通知是空开关。** 偏好与设置项存在，全仓库无 source: 'assistant' 发送调用。

**拖拽排序仅在助手分组模式可用。** 时间分组语义上不可拖。

**主题遵循 Shadcn 变量契约。** 官方变量名无前缀转发 `--cs-*`，为第三方主题生态兼容。

**Token 契约分层是单向的。** foundation → runtime input → 官方语义 → 产品语义，`--cs-*` 只是内部 provider、`--cs-theme-*` 是受控输入、`--app-*` 归 owner-local，组件只允许消费无前缀公共语义——依赖"契约纪律"而非仅命名约定（有 theme:check/validate-theme-contract 等脚本和 registry 把关）。

**用户主色无"主色引擎"。** 只写 primary + 对比前景两个行内变量，不生成 50-950 色阶、无 dark 变体；dark 模式 focus ring 硬编码、不随用户主色。

**自定义 CSS 的 v1 迁移标记。** 旧版 CSS 原样保留但整体标记为"对 v2 界面不安全"，拒绝注入而不是尝试兼容。

**折叠展开无高度动画。** hidden 硬切换 + 箭头旋转过渡，视觉瞬时。

## 9. 未验证事项

- 无 host 降级路径、160ms 防闪烁骨架的实际运行表现未实测。
- Session 列表拖拽排序是否存在于 `src/renderer/pages/agents` 未检索确认。
- Pyodide 代码执行的浏览器内性能与超时行为未实测。
- 无障碍结论基于静态代码，未做读屏实测；prefers-reduced-motion 在业务层滚动/淡入交互的覆盖情况未逐一确认。
- macOS 托盘图标切换、原生右键菜单（native 模式）的实际表现未运行验证。
- 错误边界各层 fallback 的实际运行表现未实测：Provider 崩溃后的 WindowFatalFallback（i18n 全局单例、浅色主题残留、spinner 移除）与消息/块级 fallback 生产隐藏详情的行为仅静态确认。
- 渲染进程无 window.onerror/unhandledrejection 兜底：事件处理器内未捕获异常、未处理 Promise rejection 的可见表现（是否无声白屏）未运行验证；HTML artifact 预览 webview 崩溃处理未找到（child-process-gone 全仓库零命中）。
- 主进程 render-process-gone 的 60s 间隔自动 reload / forceExit(1) 决策与 crash telemetry 日志在真实崩溃场景的行为未运行验证。
- 主题体系核对结论基于静态源码：pnpm theme:build 生成器输出与 `contract.css` 导入顺序的实际产物未构建验证；theme:check/validate-theme-contract 校验脚本未实际运行；用户主色在 dark 模式的对比度、`--cs-ring` dark 硬编码值不随主色的视觉影响未运行确认。
- 自定义 CSS 注入在 main/subWindow/quickAssistant/selection 五类窗口的同步时机（偏好更新到 style 节点生效的延迟）、CodeMirror 编辑大段 CSS 时的性能、v1 标记内容的迁移提示流程未运行验证。

## 10. 关键源码索引

- `packages/ui/src/components/primitives/dialog.tsx`
- `packages/ui/src/components/primitives/toast.tsx`
- `packages/ui/src/services/popup/types.ts`
- `src/renderer/services/popup/PopupService.ts`
- `src/renderer/services/toast.ts`
- `src/renderer/components/command/CommandMenus.tsx`
- `src/main/services/ThemeService.ts`
- `src/renderer/components/ThemeProvider.tsx`
- `src/renderer/hooks/useUserTheme.ts`
- `src/renderer/hooks/useCustomCss.ts`
