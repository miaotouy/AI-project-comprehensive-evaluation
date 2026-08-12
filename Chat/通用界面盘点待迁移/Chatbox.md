# Chatbox 通用界面盘点（待迁移）

> 来源：`../Chat/Chatbox-Chat调查笔记.md` 第 13 节（2026-08-07 调查的旧版长文，2026-08-11 类目拆分时原文搬运）
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 迁移说明：搬运弹窗三套技术栈（13.1）、Toast 两套系统（13.2）、主题三套机制（13.6）、响应式断点（13.8）、动画方案（13.9）、图片灯箱（13.10）、openAboutDialog 死状态（13.13）。"聊天相关弹窗/通知交点"已由 [`../Chat UI/Chatbox-ChatUI调查笔记.md`](<../Chat UI/Chatbox-ChatUI调查笔记.md>) 第 10.1 节承接，此处不重复搬运；13.3（加载/骨架屏/空状态）、13.4（拖放）、13.5（右键菜单）、13.7（无障碍）、13.11（快捷键）、13.12（桌面集成）已迁入 Chat UI 笔记。保留原编号以便对照旧笔记；正文为原文，仅对已迁入 Chat UI 笔记的交点句子做删减。

> 原文导语：
>
> 本节聚焦第 10、12 节未覆盖的细节层面：弹窗底层实现、通知系统、拖放视觉反馈、右键菜单、主题机制、无障碍证据、响应式断点、动画库、图片灯箱、快捷键面板、桌面端集成。每条结论均标注文件+行号，查无实现的方向如实注明。

## 13.1 弹窗/对话框：三套并存的实现，靠 `AdaptiveModal` 统一收口

Chatbox 的弹窗底层实际上是**三套技术栈并存**，不是单一 UI 库：

1. **Mantine `Modal`/`Drawer`（主力）**：`components/layout/Overlay.tsx:42-43` 用 `withOverlayManager` 包了一层 `@mantine/core` 的 `Modal`/`Drawer`，导出为项目内统一的 `Modal`/`Drawer`。`useOverlayManager`（`Overlay.tsx:9-26`）维护一个全局 `overlayStackAtom`（jotai atom，字符串 id 数组），每个弹窗挂载时把自己的 `useId()` 塞进栈顶，**只有当前处于栈顶的弹窗才会把 `closeOnEscape` 设为 `true`**——这是自制的"多层弹窗只有最上层响应 Esc"方案，而不是依赖 Mantine 自带的层级管理。
2. **`vaul`（`AdaptiveModal.tsx:5,19-43`）**：移动端场景下同一个 `AdaptiveModal` 组件切换成 `vaul` 的 `Drawer.Root`，从底部弹出、带手柄（`Drawer.Handle`）、`noBodyStyles` 避免 vaul 改 body 样式。`ActionMenu.tsx`（右键/长按菜单，见 13.5）里的移动端分支也是同一套 `vaul` 用法。
3. **`@radix-ui/react-dialog`（`components/ui/dialog.tsx`）**：这是 shadcn/ui 风格的原始 Dialog 封装，独立于上面两套，`grep` 未发现在聊天相关组件里被直接引用——**未核实具体消费方**，本次阅读范围内只看到定义文件本身，可能给 dev 工具或未接入的功能预留。

真正对外统一的入口是 `AdaptiveModal`（`components/common/AdaptiveModal.tsx`），根据 `useIsSmallScreen()` 在"Mantine Modal"和"vaul Drawer"之间二选一渲染，业务弹窗（设置项、确认框、消息编辑等）基本都通过它，而不是直接用 Mantine `Modal`。

**弹窗生命周期管理用的是 `@ebay/nice-modal-react`**（`modals/ConfirmModal.tsx:1`、`modals/Settings.tsx` 未使用但 `routes/__root.tsx` 顶层包了 `<NiceModal.Provider>`）：`NiceModal.create(...)` 包装组件后，业务代码用 `await NiceModal.show('confirm', props)` 以 Promise 形式弹出并等待用户选择，`modal.resolve(result)` + `modal.hide()` 是标准收尾写法。目前至少 15 个弹窗走这套机制：`ConfirmModal`、`MessageEdit`、`SessionSettings`、`Welcome`、`ExportChat`、`VibedropPublish`、`ArtifactPreview`、`ReportContent`、`ThreadNameEdit`、`ModelEdit`、`ClearSessionList`、`AttachLink`、`FileParseError`、`AgentModeRewardClaimSuccess`、`AppStoreRating`（`modals/*.tsx` 目录清单）。

Esc/遮罩点击关闭的具体行为并不统一，是逐个弹窗手工配置的：
- 默认（不传 `trapFocus`/`closeOnEscape`/`closeOnClickOutside`）：Mantine 默认行为，Esc 和点遮罩都能关。
- **`trapFocus={false}`** 出现在 `MessageEdit.tsx:244`、`SessionSettings.tsx:171`、`CopilotDetailModal.tsx:118`、`CopilotSettingsModal.tsx:140`——`git log -S "trapFocus={false}"` 定位到提交 `2930c21d`（"fix: hard to select text on ios when opening a modal"），说明这是**专门为解决 iOS 上 Modal 内文本无法选中而关闭的焦点陷阱**，代价是这四个弹窗打开时键盘 Tab 可以跳出弹窗到背景内容，是一个明确记录在案、但确实存在的无障碍取舍。
- **`closeOnClickOutside={false}` + `closeOnEscape={false}` + `withCloseButton={false}`** 三个一起出现在 `EmailCodeLoginModal.tsx:74-76`、`LicenseSelectionModal.tsx:37-39`、`guide/-components/ActionButton.tsx:147-149`——登录/许可证选择这类"必须做出选择才能继续"的弹窗，故意禁掉一切"意外关闭"路径，只能点内部按钮走完流程。
- **`withCloseButton={false}`**（无右上角 X，但仍可 Esc/点遮罩关闭）单独出现在 `ArtifactPreview.tsx:104`、`Welcome.tsx:21`、`Settings.tsx:71`（Settings 弹窗把关闭按钮做成了自定义的圆形图标按钮而不是 Mantine 默认样式，`Settings.tsx:88-101`）。

**设置弹窗（`modals/Settings.tsx`）本身是一个嵌套路由**：内部用 `@tanstack/react-router` 的 `createMemoryHistory` + `createRouter` 单独起了一套 `modalRouter`（`Settings.tsx:256-264`），弹窗打开时把外层 URL 的 `?settings=/settings/xxx` search 参数同步进这个内存路由（`Settings.tsx:47-51`），意味着设置弹窗内部的"页面切换"不影响浏览器地址栏的真实路由栈，是路由套路由的实现方式。移动端不走这个弹窗，`navigateToSettings`（`Settings.tsx:115-131`）里判断 `matchMedia(max-width: 640px)` 命中时直接 `router.navigate({ to: '/settings...' })` 做整页路由跳转（对应 `routes/settings/route.tsx`），桌面端才叠加成弹窗——这是本项目"响应式"实现里比较少见的"同一功能在不同屏幕尺寸下走完全不同的路由策略"的例子。

## 13.2 通知/Toast：两套互不相干的系统按场景分工

**系统一：`toastActions` + MUI `Snackbar`（`components/common/Toasts.tsx`）**。`toastActions.add(content, duration?, action?)`（`stores/toastActions.ts:3-5`）往 `uiStore.toasts` 数组里追加一条记录，`Toasts.tsx` 对数组里的每一条都独立渲染一个 MUI `<Snackbar open anchorOrigin={{vertical:'top', horizontal:'right'}} autoHideDuration={toast.duration ?? 3000}>`（`Toasts.tsx:12-36`）。**没有找到任何堆叠/位移逻辑**——多条 toast 同时存在时，每条都定位在同一个右上角锚点，理论上会互相重叠而不是像 sonner 那样自动堆叠错开；本次阅读范围内没有看到针对这一点的额外样式处理。`toast.action` 可选，点击后按 `settingsPath` 跳转设置页（`Toasts.tsx:18-32`）。全局挂载在 `routes/__root.tsx:355`（注释直接写了 `{/* mui */}` 提醒这是 MUI 的那一套）。

**系统二：`sonner`（`packages/toast.ts` + 各 Settings 子页面）**。知识库文档上传、MCP 服务器管理、Skills 安装/更新等**只在 Settings 弹窗内部**触发的提示，直接用第三方库 `sonner` 的 `toast.success/error/warning/info(...)`（`KnowledgeBaseDocuments.tsx:313,315,415`、`CustomServersSection.tsx:79,135`、`SkillsSection.tsx:395,414,418`、`SkillsSpotlight.tsx:436`）。渲染载体是 `<Toaster richColors position="bottom-center" style={{zIndex: 2147483647}} />`，分别挂在 `modals/Settings.tsx:108`（桌面弹窗版）和 `routes/settings/route.tsx:140`（移动端整页路由版），**两处各自独立挂载**，不是共享单例。`sonner` 自身内置堆叠/自动错位能力，位置在屏幕底部居中，和系统一的右上角完全不同。`packages/toast.ts` 里的 `toastError` 还做了一层增强：错误 toast 先用原文展示，随后异步调用 `translateTexts` 把错误信息翻译成用户设置的语言，翻译完成后用同一个 `id` 把 toast 的 `description` 字段原地替换成译文（`toast.ts:12-40`）——即错误提示会"先出现原文，几百毫秒后追加译文"，而非等翻译完成才弹出。

结论：**是否弹右上角还是底部居中、用 MUI 还是 sonner，取决于触发代码所在的功能模块**，而不是一个统一的全局提示系统；两套 z-index 分别是"未特别设置"（跟随 MUI 默认）和硬编码的 `2147483647`（`int32` 最大值，确保永远盖在最上面）。

## 13.6 主题/深色模式：MUI 主题、Mantine `colorScheme`、Tailwind CSS 变量三套机制各管一段

深色模式的"是否生效"由 `uiStore.realTheme`（`'light'|'dark'`）这一个状态源统一决定，但**消费方是三套互不相通的系统**：

1. **Tailwind / CSS 变量**：`useAppTheme.ts:45-52` 在 `realTheme` 变化时切换 `document.documentElement` 的 `dark` class，`tailwind.config.js:3` 声明 `darkMode: ['class']`，所有 `--chatbox-*` CSS 变量在 `static/globals.css:89` 的 `:root[data-mantine-color-scheme="dark"]` 选择器下重新赋值（浅色值在文件顶部 `:root{}`，深色值在这个选择器块）。**注意选择器用的属性是 `data-mantine-color-scheme`，不是 `data-theme`**——`data-theme` 属性同时也被设置（`useAppTheme.ts:45`），但只在 `static/index.css:40` 的 `html[data-theme="dark"]` 块里用来切滚动条颜色，和 `--chatbox-*` 变量的深浅色切换是两个不同的属性驱动的。
2. **MUI**：`getThemeDesign(realTheme, language)`（`useAppTheme.ts:74-126`）根据 `realTheme` 生成 `palette.mode` 和深色下的固定背景色 `#242424`（`:88-92`，注释写明"MUI 内部无法处理 css 变量，需要使用具体颜色值"——即 MUI 侧的深色背景是硬编码色值，没有走 CSS 变量，和 Tailwind 侧的 `--chatbox-background-primary`（同样是 `#242424`，`globals.css:114`）只是数值上凑巧一致，不是同一个来源）。
3. **Mantine**：`routes/__root.tsx:641-644` 的 `<MantineProvider defaultColorScheme={theme===Dark?'dark':theme===Light?'light':'auto'}>`——Mantine 自己的 `colorScheme` 机制是**独立**的第三套，只在初始化时读一次 `theme` 设置项，不响应 `uiStore.realTheme` 的后续变化（`defaultColorScheme` 只影响首次渲染默认值）；Mantine 组件的深浅色实际视觉表现，靠的是它们大量用 `c="chatbox-xxx"`/`color="chatbox-xxx"` 引用第 1 点里那套 CSS 变量，而不是 Mantine 自身的 dark/light 语义色。

**品牌色与颜色预设（第四套"主题输入"机制）**：`2112df43`/`b290309c`/`c603eccc`/`5f1f34d3` 等提交在设置页 `settings/general.tsx` 增加"界面颜色"控件（`components/common/InterfaceColorInput.tsx`，取色时本地预览、确认才提交）：浅/深两套 `interfaceColors`（每套含 brand 主色）存入 Settings schema（`shared/types/settings.ts:506-507`），自定义预设保存为 `interfaceColorPresets` 数组；`useAppTheme.ts:28,55-62` 把 `interfaceColors[realTheme].brand` 解析后写入 CSS 变量 `--chatbox-brand`（`resolveInterfaceBrandColor`，`shared/theme-colors.ts`），同时传入 `getThemeDesign` 作为 MUI `palette.primary.main`（`useAppTheme.ts:82-84`）——品牌色成为 Tailwind CSS 变量与 MUI 主题**共用的第二个输入源**，`tailwind.config.js` 与 `globals.css` 相应扩展。另 `96ef17d3`/`ed535858` 支持背景图片的可配置样式（`backgroundImageKey`/`backgroundImageOpacity`，`settings/chat.tsx`，默认透明度 0.16），`0f2fd22a`/`47288106` 把侧栏背景图挂到 app 根/抽屉层。

**主题来源与存储**：`switchTheme(theme)`（`useAppTheme.ts:10-23`）在 `theme === Theme.System` 时调 `platform.shouldUseDarkColors()` 决定实际颜色；桌面端（`desktop_platform.ts:58-59`）转发给 Electron 主进程的 `nativeTheme.shouldUseDarkColors`（`main.ts:763`），网页端（`web_platform.ts:39-41`）直接查 `matchMedia('(prefers-color-scheme: dark)')`。**跟随系统变化的实时监听**：主进程 `nativeTheme.on('updated', ...)` 转发 IPC 事件 `system-theme-updated`（`main.ts:486-488`）,渲染进程 `onSystemThemeChange`（`desktop_platform.ts:61-63`）订阅后重新走一遍 `switchTheme`；网页端则是标准的 `matchMedia(...).addEventListener('change', ...)`（`web_platform.ts:42-47`）。最终算出的 `realTheme` 落盘在 `localStorage['initial-theme']`（`useAppTheme.ts:20`），供下次启动前（Mantine/React 渲染树建立前）就能同步读出避免主题闪烁（`uiStore.ts:26` 初始化时直接读这个 key）。

## 13.8 响应式断点与移动端导航：断点数值来自 MUI 而非 Tailwind 默认值

统一断点定义在 `useAppTheme.ts:116-124`（MUI `breakpoints.values`）：`xs: 0, sm: 640, md: 900, lg: 1200, xl: 1536`，代码注释明确写"`sm` 的值与 tailwindcss 保持一致"（`:119`）——即项目**把 MUI 断点手动对齐到 Tailwind 的 `sm=640px`**，而不是用 Tailwind 默认的 `sm=640/md=768/lg=1024/xl=1280`（Tailwind 的 `md`/`lg`/`xl` 默认值和这里 `900/1200/1536` 并不一致，只对齐了 `sm` 一档）。`useIsSmallScreen()`（`hooks/useScreenChange.ts:14-18`）就是 `useMediaQuery(theme.breakpoints.down('sm'))`，即 **< 640px 判定为小屏**，这是全项目"移动端分支"的唯一判定标准。另有 `uiStore.ts:10-16` 的 `isSmallScreenViewport()` 用原始 `matchMedia('(max-width: 599.95px)')` 做初始化时的同步判断（用于 `showSidebar` 的初始值），**600px 和 640px 两个数字并不完全一致**——初始渲染判断用 599.95px，之后 React 状态更新走的 `useIsSmallScreen` 用 640px，理论上存在 600px~640px 这个区间首屏渲染和后续渲染判断不一致的窄缝，未核实是否有实际可观察的视觉跳变。

侧栏宽度（`useSidebarWidth`，`useScreenChange.ts:30-59`）按 `sm/md/lg/xl` 四档给出 `200/220/240/280`（`× mantineTheme.scale`）像素的默认值，小屏幕（都不满足 `up('sm')`）反而给了 `240`——但这个值在小屏幕下并不生效为"侧栏宽度",因为小屏幕走的是 `SwipeableDrawer` 的 `temporary` 变体（见下），宽度改成了 `75vw`（`Sidebar.tsx:154-156`）覆盖了 `useSidebarWidth` 的返回值。

**移动端导航方式：不是底部 Tab Bar，是从左侧滑出的 `SwipeableDrawer`**（`Sidebar.tsx:138-158`）。`variant={isSmallScreen ? 'temporary' : 'persistent'}`——小屏幕下侧栏是"临时"的覆盖层（打开时盖住内容，点遮罩或滑动关闭），桌面端是"常驻"的挤压布局（内容区 `padding-left` 让出侧栏宽度）。`ModalProps.keepMounted: true` 保证移动端切换时 DOM 不销毁（`:145`，注释"Better open performance on mobile"），`disableEnforceFocus: true`（`:146`，注释解释是为了避免侧栏打开时其他弹窗里的 input 无法点击）。`SwipeableDrawer` 支持从屏幕边缘滑动手势打开/关闭（MUI 内置能力），阿拉伯语（RTL）时锚点切到右侧（`anchor={language === 'ar' ? 'right' : 'left'}`,`:139`）。全项目 `grep` **没有找到底部 Tab Bar 组件**（`BottomNavigation`/`TabBar` 等关键词零匹配），移动端的一级导航（新建对话/图片创作/搜索/归档/关于/设置）全部收在这一个可滑出的侧栏抽屉里，不是常驻在屏幕底部的图标栏。

`useInputBoxHeight`（`useScreenChange.ts:61-76`）也按同一套 `sm/md/xl` 断点给输入框最小/最大高度（从 `{min:32,max:192}` 到 `{min:96,max:480}`），是另一个响应式细节点。

## 13.9 动画/过渡效果：没有 Framer Motion，靠 Tailwind Animate + 库自带过渡拼起来

`package.json` 全文确认**没有安装 `framer-motion` 或 `motion`**。项目里能看到的动画来源分四类：

1. **`tailwindcss-animate`**（`tailwind.config.js:118` 插件、`package.json` 依赖）：提供 `animate-in`/`animate-out`/`fade-in`/`zoom-in`/`slide-in-from-*` 等 data-attribute 驱动的工具类，用在 `components/ui/dialog.tsx:20,37`（Radix Dialog 的开关动效，200ms `duration-200`）、`pages/PictureDialog.tsx:153`（图片灯箱淡入,`animate-in fade-in duration-300`）、`routes/image-creator/index.tsx`。
2. **Mantine 自带 `transitionProps`**：`InputBox.tsx:1755-1756,1841-1844,1936-1937` 给弹出面板（技能面板、模型选择器、更多菜单）分别配了 `transition: 'pop'` 或 `'fade-up'`，`ModelSelectorV2` 那处还显式设了 `duration: 200`（`:1843`）——这是 Mantine 内置的过渡预设名，不是自定义关键帧。
3. **`vaul`（Drawer）自带的弹簧式滑入动画**：`AdaptiveModal`/`ActionMenu` 的移动端分支（13.1、13.5 节）用 `vaul` 的 `Drawer.Root`，滑入/滑出动效由 `vaul` 库内部实现，项目代码里没有额外配置时长参数。
4. **手写 SVG/CSS 关键帧**：消息生成中的四点跳动指示器是纯 SVG `<animate>`（13.3 节,`1.25s` 周期），图片生成的 shimmer 骨架屏是内联 `<style>` 里的 `@keyframes shimmer-diagonal`（13.3 节,3 秒周期），`tailwind.config.js:102-114` 里另外声明了 `fadeIn`（1s ease-out）和 `flash`（0.5s ease-in-out ×2，用于强调闪烁）两个全局关键帧动画类。

`react-virtuoso` 的消息列表本身对"新消息进入"**没有额外包装过渡动效**——虚拟列表的挂载/卸载是即时的，smooth-follow 滚动是滚动位置的平滑跟随，不等同于消息卡片本身有 fade-in/slide-in 效果；本次没有找到消息卡片首次出现时的专门入场动画。

## 13.10 图片/附件预览：灯箱基于 `react-zoom-pan-pinch`，代码复制按钮有明确的图标+颜色反馈

**图片灯箱**（`pages/PictureDialog.tsx`）不是简单的全屏 `<img>`，而是接了第三方库 `react-zoom-pan-pinch`（`TransformWrapper`/`TransformComponent`,`:6,166-200`），支持鼠标滚轮/触控手势缩放（`minScale=0.1, maxScale=8`）和拖动平移，`centerOnInit` 保证初次打开图片居中。关闭方式三种都支持：点击背景遮罩（`onClick={onClose}`,`:99`）、点击右上角 `Fab` 关闭按钮（MUI `Fab`,`:140-149`）、按 `Escape` 键（`:70-83` 手动监听 `keydown`,不是 Mantine/vaul 自带的 Esc 处理，因为这个弹窗是纯 `position:fixed` 的 div,不经过 `AdaptiveModal`）。右上角还可能出现业务方注入的 `extraButtons`（如"设为头像"之类的场景,`:28-31,116-128`），和固定的"保存"按钮（导出图片到文件系统,`:48-67`）。

**代码块复制按钮**（`Markdown.tsx:560,634-641`）反馈很具体：点击后图标从 `IconCopy` 变为 `IconCheck`，颜色同时从 `chatbox-tertiary`（灰）变为 `chatbox-success`（绿），`useCopied`（`hooks/useCopied.ts:4-20`）内部用 `setTimeout` 在 **2000ms** 后把 `copied` 状态重置回 `false`，图标/颜色随之变回初始状态；悬浮时有 `Tooltip label={t('copy')}`（`openDelay={1000}`，即悬停 1 秒后才显示提示文字，避免划过时闪一下）。同一个 `useCopied` hook 也被消息操作栏的复制按钮复用（"2 秒变绿再变回"的反馈机制一致）。

## 13.13 一处顺带发现的死状态：`uiStore.openAboutDialog`

`uiStore.ts:34,89-90` 定义了 `openAboutDialog: boolean` 和 `setOpenAboutDialog`，`routes/__root.tsx:144,201` 在启动流程里会把它设为 `true`（当远程配置 `setting_chatboxai_first` 命中时）。但全代码库 `grep` **没有找到任何组件读取 `openAboutDialog` 状态来渲染"关于"弹窗**——"关于"功能实际上是通过 `navigate({ to: '/about' })` 做成了一个独立路由页（`Sidebar.tsx:184,434,462`）,不是弹窗。也就是说 `setOpenAboutDialog(true)` 这次调用在当前代码里是**没有任何 UI 效果的空调用**，与 `newSessionState.webBrowsing` 死字段属于同一类"重构后遗留、写了但没人读"的技术债。

## 主要 UI 依据（第 13 节）

`src/renderer/components/layout/Overlay.tsx`、`src/renderer/components/common/AdaptiveModal.tsx`、`src/renderer/components/common/Toasts.tsx`、`src/renderer/stores/toastActions.ts`、`src/renderer/packages/toast.ts`、`src/renderer/modals/Settings.tsx`、`src/renderer/modals/*.tsx`（弹窗清单）、`src/renderer/components/ActionMenu.tsx`、`src/renderer/components/session/SessionItem.tsx`、`src/renderer/hooks/useAppTheme.ts`、`src/renderer/hooks/useScreenChange.ts`、`src/renderer/Sidebar.tsx`、`src/renderer/sidebar-drawer.ts`、`src/renderer/hooks/useShortcut.tsx`、`src/renderer/pages/PictureDialog.tsx`、`src/renderer/components/Markdown.tsx`、`src/renderer/hooks/useCopied.ts`、`src/renderer/components/icons/Loading.tsx`、`src/renderer/routes/image-creator/-components/Shimmer.tsx`、`src/renderer/routes/image-creator/-components/EmptyState.tsx`、`src/renderer/components/chat/MessageMinimapRail.tsx`、`src/renderer/components/InputBox/InputBox.tsx`、`src/main/main.ts`、`src/renderer/platform/desktop_platform.ts`、`src/renderer/platform/web_platform.ts`、`src/renderer/static/globals.css`、`src/renderer/static/index.css`、`tailwind.config.js`、`package.json`。
