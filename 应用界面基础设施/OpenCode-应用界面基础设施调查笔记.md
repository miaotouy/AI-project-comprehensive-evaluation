# OpenCode 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\opencode`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 同时维护独立的 TUI 与 Web/Desktop 界面。TUI 基于 opentui 和 Solid，自建对话框栈、单条 Toast 与焦点归还；Web 使用 Solid、Kobalte 和项目 UI 包，桌面 Electron 直接复用同一渲染层。

Web 弹窗通过 DialogProvider 提供命令式栈，Toast 仍有 Kobalte 与 solid-sonner 两代实现，按新旧布局静态选择。TUI 和 Web 的主题都在运行时解析：前者从终端 palette 派生，后者把主题 token 注入 CSS 变量，并通过预加载脚本减少首屏闪烁。

项目提供主题注册、URL 加载等库级 API，但应用层尚未接线；本次也没有找到主题市场、壁纸或用户自定义 CSS。桌面端没有托盘和全局快捷键，系统通知由渲染层浏览器 Notification API 发送。

## 系统边界与总体装配

### TUI（`packages/tui`）

根装配在 `src/app.tsx`：`run()`（app.tsx:186-363）先 createCliRenderer（`@opentui/core`，60fps、kitty 键盘、useMouse: !Flag.OPENCODE_DISABLE_MOUSE && config.mouse、外部输出 passthrough、exitOnCtrlC: false），

注册 opentui keymap 与 registerOpencodeKeymap（leader 键、modal 模式栈、input 层），随后 `render()`（`@opentui/solid`）挂载约 30 层 Provider（app.tsx:245-351）：

```text
ExitProvider > EpilogueProvider > ErrorBoundary(ErrorComponent)
> TuiPathsProvider > TuiTerminalEnvironmentProvider > TuiStartupProvider
> ClipboardProvider > OpencodeKeymapProvider > ArgsProvider > KVProvider
> ToastProvider > RouteProvider > TuiConfigProvider > PluginRuntimeProvider
> SDKProvider > PermissionProvider > ProjectProvider > SyncProvider > DataProvider
> ThemeProvider > LocalProvider > PromptStashProvider > DialogProvider > FrecencyProvider
> PromptHistoryProvider > PromptRefProvider > EditorContextProvider > LocationProvider > App
```

主题在挂载前预热：`renderer.getPalette({size:16})` 预取终端调色板，renderer.waitForThemeMode(1000) ?? "dark" 作为初始模式传入 ThemeProvider（app.tsx:239-243，注释说明是为了避免 `system` 主题首帧回退闪烁）。App 按 RouteProvider 在 Home/Session 间切换，底部渲染 plugin Slot（app_bottom/app）与 StartupLoading。

### Web App（`packages/app` + `packages/ui` + `packages/session-ui`）

入口 `src/entry.tsx`：PlatformProvider → AppBaseProviders → AppInterface。

AppBaseProviders（app.tsx:393-428）是全局外壳：MetaProvider、Font、ThemeProvider（onThemeApplied 回调把模式推给桌面窗口 window.api.setTitlebar）、LanguageProvider、UiI18nBridge（把 app 的 i18n 桥到 ui 包）、ErrorBoundary（Sentry + ErrorPage）、QueryProvider（TanStack Query，关闭 window focus 自动 refetch）、WslServersProvider、DialogProvider、FileComponentProvider（session-ui 的 File 组件）。

AppInterface（app.tsx:557-613）挂 ServerProvider/GlobalProvider/SettingsProvider/ConnectionGate（启动健康检查 + 全屏 Splash + 断连错误页），路由根由 TabsProvider/PermissionProvider/NotificationProvider/ServerShell（CommandProvider）包裹，新旧布局由 `settings.general.newLayoutDesigns()` 切换 NewAppLayout 与 LegacyLayout。

### 桌面（`packages/desktop`）

renderer 以源码方式复用 `@opencode-ai/app`（`src/renderer/index.tsx`，见 Chat UI 笔记第 1 节）；

主进程维护窗口注册表和每窗口几何状态，重启后可以恢复。Windows 使用无边框标题栏，macOS 隐藏标题栏并同步 nativeTheme；原生菜单、渲染器权限白名单、外部 URL 策略和无响应恢复也都位于主进程。（`packages/desktop/src/windows.ts:114-233`）

## 1. 界面栈、公共组件与状态所有权

**TUI 栈。** opentui（`@opentui/core`/`@opentui/solid`/`@opentui/keymap` 0.4.5，根 catalog 约束）+ Solid 1.9.10；无 React/Ink（全仓库 package.json 检索 "ink" 无命中）。

**Web 栈。** Solid 1.9.10 + `@kobalte/core` 0.13.11（dialog/toast/dropdown-menu/context-menu/popover/hover-card/select 等原语）+ Tailwind CSS 4（含 tw-animate-css）。

共享组件库 `@opencode-ai/ui` 是两层：v1 组件（`ui/src/components/*`，Kobalte 包装 + data-component 样式钩子）与 v2 设计系统（`ui/src/v2/components/*`，每组件独立 CSS 文件 + Storybook stories，token 见第 4 节）。

消息渲染共享包 `@opencode-ai/session-ui`（markdown worker、message-part、session-turn 等）归消息渲染器类目，不在本笔记展开。
- **状态所有权**（对照指南第 7 条）：
  - 弹窗：TUI 在 DialogProvider 内的模块 store（`ui/dialog.tsx` createStore 栈）；Web 在 DialogProvider（`ui/context/dialog.tsx`）的 context 内 store（`createSignal<Active[]>`），命令入口（`useDialog()`）与渲染（`<For each={ctx.stack()}>`）共享同一 context。
  - Toast：TUI 进程内 ToastProvider 单条状态；Web v1 Kobalte toaster 单例 + v2 solid-sonner toasterV2 单例（两者独立注册表，dismissToast 必须按发出方分派，`app/src/utils/toast.tsx:36-41`）。
  - 主题：TUI 在 ThemeProvider 模块 store + `kv.json` 落盘；Web 在 ThemeProvider store + localStorage（见第 4 节）。
  - 通知：Web 在 NotificationProvider，列表持久化到 Persist.serverGlobal("notification")（localStorage），见第 3 节。
  - 布局偏好：Web LayoutProvider 按 workspace 持久化（`context/layout.tsx`），见第 5 节。
  - 会话/消息 UI 状态：两表面都订阅同一 SSE 事件流投影到各自 store（事实源是服务端事件流，见 Chat UI 笔记第 8 节），不属于本类目持有。

## 2. 弹窗、浮层与菜单

### TUI：自建对话框栈（`ui/dialog.tsx`）

**栈与 API。** DialogProvider（dialog.tsx:182-223）内 createStore 维护 stack（element + onClose），对外 `clear()`、`replace()`、`setSize()`；replace 是 single-flight（清空旧栈、只留新项，dialog.tsx:150-165）。

业务对话框（模型/Agent/主题列表、命令面板、权限/提问、timeline/fork 等）统一经 `dialog.replace(() => <DialogXxx />)` 或 DialogConfirm.show(...) 等命令式入口挂载，入口集中在 `app.tsx` 的 appCommands 与各对话框文件。

**呈现。** Dialog（dialog.tsx:11-67）全屏遮罩（RGBA(0,0,0,150)）+ 居中面板，宽度分三档 `medium/large/xlarge` = 60/88/116 列，`maxWidth = 终端宽 - 2`；zIndex 3000。遮罩点击关闭，但按下时若正在选区复制则挂起（onMouseDown 记 dismiss，dialog.tsx:30-39）；面板内 onMouseUp 阻止冒泡让"复制选择"优先（:51-57）。

**Esc/ctrl+c。** 栈非空且无选区时绑定 escape 与 ctrl+c，两者都弹栈并调 onClose 后 `refocus()`（dialog.tsx:105-137）。

**焦点归还。** `refocus()` 在关闭后 1ms 重查焦点 Renderable 是否仍在渲染树中，在则 `focus.focus()`（dialog.tsx:87-103）——避免触发者随对话框关闭一起卸载时的失效焦点。

**模式栈联动。** 栈非空时 modeStack.push("modal")（dialog.tsx:81-85），opentui keymap 进入 modal 模式，屏蔽下层绑定。

**命令式对话框。** DialogConfirm.show(dialog, title, message, label?) 返回 `Promise<boolean | undefined>`（dialog-confirm.tsx:93-107，`undefined` 表示未确认即关闭）；左右方向键 + Enter 选择（dialog-confirm.tsx:26-55）；

DialogAlert.show（ui/dialog-alert.tsx）、DialogPrompt（ui/dialog-prompt.tsx，TextareaRenderable + 独立 dialog.prompt.submit 键位 + busy 态）、DialogSelect（ui/dialog-select.tsx）同模式。升级确认/失败提示等都用这组 prefab（app.tsx:1038-1077）。

**命令面板。** CommandPaletteDialog（component/command-palette.tsx），命令注册在 `app.tsx` 的 appCommands（namespace palette，含 slash 名称/别名），键盘全局命令列表在 appBindingCommands（app.tsx:106-140）；help 对话框（ui/dialog-help.tsx）说明按 command.palette.show 的实际绑定展示。

**上下文菜单。** 本次未找到——`packages/tui/src` 全目录检索 onContextMenu|ContextMenu|context-menu 无命中。TUI 的"右键"语义是选区复制（app.tsx:1093-1105 与 DialogProvider 内的右键复制分支，dialog.tsx:205-213），没有菜单浮层。

### Web：DialogProvider 栈 + Kobalte 呈现（`packages/ui/src/context/dialog.tsx`）

**API。** `useDialog()` 返回 show（替换栈，用于设置/命令面板等）、push（压栈）、close（关栈顶）、active。owner 语义：新弹窗的 owner 取"栈顶弹窗的 owner"，保证在旧弹窗内打开的下一级弹窗在旧弹窗卸载后仍有生效 owner（dialog.tsx:185-192）；show/push 包在 startTransition 里。

**呈现与层级。** 每项是一个 Kobalte Dialog modal + Portal（默认 body）内的 Overlay 与居中容器，`zIndex = 50 + layer*10`（dialog.tsx:80,101-109）；DialogProvider 在子树内渲染 `<div data-component="dialog-stack">`（dialog.tsx:163-165）。

**Esc 与遮罩。** Provider 在 window 上以 capture: true 挂 keydown，Esc 直接 `close()` 并 `preventDefault/stopPropagation`（dialog.tsx:65-76）；Overlay 点击调 close(id)（:102）。Kobalte 自身还有内容上的 Esc/焦点行为，属依赖内部（未核实）。

关闭路径：`close()` → `onClose()` → setClosing(true)（Kobalte `open={!closing()}` 播放退场）→ 100ms 后 `dispose()` 并从栈移除，期间 lock 防重入（dialog.tsx:43-63）。

**呈现组件。** v1 `ui/components/dialog.tsx` 与 v2 `ui/v2/components/dialog-v2.tsx` 都是 Kobalte Content 包装（标题/描述/关闭按钮/autofocus 元素定位），v2 另有 fit/`variant="settings"`/size 样式档。

**消费面。** `useDialog()` 在 app 侧 51 处调用（对话框组件清单见 grep 结果：dialog-settings、dialog-select-model、dialog-connect-provider、dialog-command-palette-v2、dialog-fork、status-popover-body 等）；

设置对话框经 `useSettingsDialog()` 懒加载 `@/components/settings-v2` 后 dialog.show(...)（settings-dialog.tsx:12-24）。

**命令面板。** DialogCommandPaletteV2（components/dialog-command-palette-v2.tsx）——createResource 按查询加载"命令 + 会话 + 文件"三类条目，entries.latest 保留旧结果防逐键闪烁（:138-140），分组渲染、`role="listbox"/"option"` + aria-selected，键盘 ArrowUp/Down/Enter/Esc（:168-188），悬停只响应真实鼠标移动（`movementX/Y === 0` 忽略，:269-273）。

入口链：mod+k → command.palette → file.open（`use-session-commands.tsx:506`）→ DialogSelectFile → 新布局下渲染 DialogCommandPaletteV2（dialog-select-file.tsx:28-33）。

**命令系统。** `context/command.tsx`——document 级 keydown capture 分发；注册表去重；用户自定义键位覆盖（settings.keybinds）；命令目录持久化（command.catalog.v1）；对话框打开时（dialog.active）暂停键位分发（command.tsx:398）；可编辑键位白名单仅 `terminal.toggle/terminal.new/file.attach`（:16）。

**菜单。** Kobalte DropdownMenu/ContextMenu 的 v1 包装（ui/components/dropdown-menu.tsx、context-menu.tsx）与 v2 包装（ui/v2/components/menu-v2.tsx，含 Checkbox/Radio/Sub/Context）；

app 侧消费点如会话标签右键（session-sortable-tab.tsx:129）、首页项目右键（home-projects-view.tsx:478）；桌面应用菜单是原生 Electron 菜单（见第 7 节）。

## 3. 通知、加载态与错误反馈

### TUI Toast（`ui/toast.tsx`）

**单条模型。** currentToast 单槽，新 toast 覆盖旧 toast 并重置计时（toast.tsx:60-67）；默认 `duration = 5000ms`；`variant: info/success/warning/error`，边框色取 `theme[variant]`；右上角定位、`maxWidth = min(60, 终端宽-6)`。**本次未找到堆叠、更新、取消队列**（单条实现即如此设计）。

**触发方。** 复制成功、session.error 事件（app.tsx:1018-1029）、更新流程、命令面板动作等；插件经 tui.toast.show 事件桥接（app.tsx:990-998）。

### Web Toast：双代实现按布局切换（`packages/ui`）

- **v1**（`ui/components/toast.tsx`）：Kobalte Toast/toaster 单例，ToastRegion 用 Portal 挂载；showToast 支持 title/description/icon/actions/variant/duration/persistent；

  showPromiseToast 走 toaster.promise（loading→success/error 状态渲染）；`ProgressTrack/ProgressFill` 提供进度条。挂载点：旧布局 `pages/layout.tsx:2418`，同时 setV2Toast(false)（layout.tsx:124）。
- **v2**（`ui/v2/components/toast-v2.tsx`）：solid-sonner Toaster（unstyled，closeButton，5s，`swipeDirections=["bottom"]`，RTL 时定位 bottom-left 并换偏移，:49-56）；

  showToastV2 带 key 去重（相同内容更新现有 toast 并做 160ms 缩放脉冲，跳过 reduced-motion，:262-269）；toasterV2.dismiss 同步清理自己的注册表（v1/v2 id 各自编号，负数自增）；

  Region 用 MutationObserver 同步 `data-visible=false` 的 toast 为 `inert + tabIndex=-1`（:15-46）。挂载点：新布局 `pages/layout-new.tsx:46`，setV2Toast(true)（layout-new.tsx:13）。

**分派。** `app/src/utils/toast.tsx` 的 `showToast/dismissToast` 按模块级 v2 开关路由到两套实现；ToastRegion 同样按开关渲染（:17-20）。

### 通知中心与系统通知（Web）

- 应用内通知中心 NotificationProvider（context/notification.tsx）：订阅 session.idle/session.error，生成 turn-complete/error 两类通知，按 session 与 project 建索引、未读数、错误标记；

  列表持久化（Persist.serverGlobal("notification")），30 天 TTL、上限 500 条（:55-63）；markViewed 清未读；伴随音效（playSoundById，受 settings.sounds 开关控制，:345-347,376-378）。
- 系统通知：`settings.notifications.agent/errors` 开关放行后调 platform.notify（:358-362,393-395）。Web 平台实现（entry.tsx:70-92）：浏览器 Notification API，请求权限，仅当窗口不在视口/未聚焦时发；

  桌面实现（renderer/index.tsx:254-268）：同样用渲染层 Notification，点击时 showWindow + setWindowFocus 后跳转。**主进程没有 Notification 通道**（desktop main 检索 Notification 仅见恢复对话框与权限名）。
- TUI 侧注意力机制（`attention.ts` + `tui.json` 的 attention 配置：启用/通知/音效/音量/音色包）属提示音而非 UI 浮层，本次未展开。

### 加载、空状态与错误边界

**TUI 启动加载。** StartupLoading（component/startup-loading.tsx）延迟 500ms 才显示，最短停留 3s（防闪烁），Spinner 提示"Loading plugins…/Finishing startup…"。

**TUI 崩溃屏。** ErrorComponent（component/error-component.tsx）——主题 context 本身可能崩溃，故用按 mode 硬编码的备用调色板；提供复制报告（预填 GitHub issue URL，含 OS/终端/版本，栈超长截断）、Restart、Quit；堆栈区可滚动（上/下/PageUp/PageDown/Home/End）；小终端隐藏副文案/页脚（`term().height >= 18/20`）。

**Web 启动。** ConnectionGate（app.tsx:430-499）阻塞健康检查期间显示全屏 Splash（`fixed inset-0 z-[9999]`），失败进入 ConnectionError（1s 轮询重试 + 其他服务器切换）。

**Web 错误边界。** AppBaseProviders 的 ErrorBoundary → ErrorPage（pages/error.tsx，错误链 causedBy 展开、Sentry 上报、重启/导出日志/检查更新，错误详情可复制）；会话路由另有 SessionRouteErrorBoundary（pages/session.tsx）。

**骨架/空态。** SessionSkeleton（pages/layout/sidebar-items.tsx:326）、HomeSessionSkeleton（pages/home/home-sessions-view.tsx:539）；共享 List 组件内置搜索/分组/list-empty-state 空态与 loadingMessage（ui/components/list.tsx:244,322）。**本次未找到独立的共享"空状态"大组件**，空态多为局部实现。

## 4. 主题、视觉 token 与持久化

### TUI：终端 palette 为权威源（`context/theme.tsx` + `theme/index.ts`）

**主题来源优先级。** 内置 33 个 JSON 主题（`theme/assets/*.json`）< 插件注册（addTheme）< 用户自定义文件（`themes/*.json`，扫描 Global.Path.config 与 cwd 向上每层 `.opencode`，theme/index.ts:37-50；SIGUSR2 热刷新）< 生成的 `system` 主题（theme/index.ts:171-183）。

**`system` 主题生成。** `renderer.getPalette({size:16})` 取终端 16 色 → `terminalMode()` 按背景亮度判明暗（theme/index.ts:353-358）→ generateSystem(colors, mode) 用 ANSI 色 + 灰度插值合成整份 ThemeJson（:360-469）；

resolveSystemTheme 缓存按 palette 签名判重，调色板变化（kitty `\x1b[?997;n` 通知序列、CliRenderEvents.THEME_MODE、SIGUSR2）时 clearPaletteCache 后重试式刷新（context/theme.tsx:155-200,226-246）。

**解析与消费。** resolveTheme(theme, mode) 递归解引用 defs/颜色引用（支持 ANSI 数字引用、transparent），产物是 50 余个 RGBA 语义键（`theme/index.ts:36-91`，含 markdown 与 diff 全套配色）；消费方直接读 theme.xxx（Proxy 转发到响应式 memo，context/theme.tsx:274-280）；

另生成 SyntaxStyle（generateSyntax/generateSubtleSyntax，subtle 版带 thinkingOpacity 透明度）供高亮。

**持久化与模式。** kv.get("theme") 存当前主题、kv.get("theme_mode_lock") 存锁定模式、theme_mode 存已应用模式；`lock()`/`unlock()` 绑定 theme.mode.lock 命令；KV 落盘为状态目录 `kv.json`（context/kv.tsx:15,58，Flock 锁 + 原子写）。

切换主题 UI 在 DialogThemeList（component/dialog-theme-list.tsx），模式切换命令 theme.switch_mode。

**渲染器联动。** 主题变化同步 renderer.setBackgroundColor（context/theme.tsx:269）。

### Web：localStorage 权威源 + 运行时 CSS 变量（`packages/ui/src/theme/context.tsx`）

**持久化键。** opencode-theme-id、opencode-color-scheme（light/dark/system）、`opencode-theme-css-light/dark`（非默认主题的已解析 CSS 缓存，供快速重载与 preload，context.tsx:14-19）。

**主题 JSON 结构。** DesktopTheme（`$schema`/name/id/light/dark，types.ts:44-50），每个 variant 二选一 seeds（8 个种子色）或 palette（含 ink、accent 等，compact 标记），可带 overrides（直接覆盖 v1 token）与 v2Overrides（resolve.ts:473-514、v2/resolve.ts:72-106）；DesktopTheme 不描述背景图/字体/壁纸等非色 token。

**解析管线。** 37 个内置 DesktopTheme JSON 分别进入 v1 或 v2 解析器。v1 生成 OKLCH 中性色、主色和强调色色阶；v2 生成 12 级 ramp、语义层与前景层。结果转换为 CSS 变量后写入 `oc-theme` style，并同步根元素主题、color-scheme 和浏览器主题色。（`theme/context.tsx:133-160`）

v2 静态兜底在 `ui/v2/styles/theme.css`：:root 默认 + `[data-color-scheme="light"]`/`[data-color-scheme="dark"]` 属性选择器两块（theme.css:261,383），`light-dark()` 仅用于旧布局 oc-2 的 6 个 token 修正（:2-12），media 查询兜底整段被注释（:148-259）；

v2 的 alpha ramp 是静态的，在 `v2/styles/colors.css`（v2/resolve.ts:108 注释）。

**首屏防闪烁。** `public/oc-theme-preload.js` 被 `vite.js` 内联进 index.html 并在 app JS 前执行——读 localStorage，先给 `<html>` 打 `data-theme/data-color-scheme` 与背景色，非默认主题时把缓存的 CSS 注入 `#oc-theme-preload`；

applyThemeCss 应用时移除该元素（context.tsx:151）。oc-1 旧 id 自动归一为 oc-2 并清缓存（preload.js:5-10）。配套测试 `theme-preload.test.ts`。

**系统跟随与跨窗口。** `colorScheme === "system"` 时 matchMedia("(prefers-color-scheme: dark)") change 监听更新 mode（context.tsx:258-263）；window storage 事件跨标签页/跨窗口同步主题与配色（:234-253）。

**预览与提交。** `previewTheme/previewColorScheme/commitPreview/cancelPreview`（context.tsx:327-370）供主题选择器即时预览，不落盘。

**库级主题 API（本次核对发现，App 未接线）。** ThemeProvider 暴露 registerTheme 运行时注册自定义 DesktopTheme 对象进 store（context.tsx:326，`ids()` 自动把非内置 id 并入列表，:223-230）；

`ui/src/theme/loader.ts` 提供 headless 主题 API——loadThemeFromUrl（fetch 任意 URL 的 DesktopTheme JSON，即"主题导入"能力，:78-84）、applyTheme（独立注入 `<style id="opencode-theme">` + data-theme，:19-30）、getActiveTheme（:86-95）、removeTheme（:97-104）、setColorScheme（:106-112），经 `theme/index.ts:36` 导出。

此外 `default-themes.ts` 导出 37 个具名主题常量与 DEFAULT_THEMES 对象。

本次在全仓库（`packages/app`、`packages/desktop`、`packages/enterprise`、`packages/console` 的 ts/tsx）检索 registerTheme|loadThemeFromUrl|removeTheme|getActiveTheme 仅命中定义与导出，**未找到任何 App/Desktop 调用方**——这些是面向第三方/嵌入方的库级扩展口，未接入产品 UI。

**主题消费面。** settings-v2 外观区主题下拉（`data-action="settings-theme"`，settings-v2/general.tsx:148-170）+ 主题文档外链（opencode.ai/docs/themes）；

命令面板 theme.set.*/theme.scheme.* 命令 onHighlight 悬停即 previewTheme、onSelect 才 commitPreview（layout.tsx:1044-1076）；TUI 侧切换 UI 在 DialogThemeList（见上小节）。

**桌面联动。** onThemeApplied → `window.api.setTitlebar({mode, scheme})`；主进程按主题设置 win32 标题栏 overlay 颜色、macOS nativeTheme.themeSource（windows.ts:114-124），并维护 setBackgroundColor（应用主题背景色，避免窗口底色闪烁，windows.ts:76-82）。

**字体。** settings.appearance 的 mono/sans 字体写 `--font-family-mono/sans`（context/settings.tsx:349-350）；`--font-size-small/base/large/x-large` 是静态 token（`ui/src/styles/theme.css:8-11`）。

Font 组件（`@opencode-ai/ui/font`）当前是 no-op 占位（ui/src/components/font.tsx:1 `export const Font = () => null`）；

settings.appearance.fontSize（默认 14，settings.tsx:200）本轮全 packages 检索**未找到消费方**（唯一 fontSize 硬编码在 terminal.tsx:405，固定 14）——"字号设置驱动界面字号"暂未形成链路。

## 5. 响应式、移动端与窗口适配

**Web 断点。** 移动/桌面以 createMediaQuery("(min-width: 768px)")（`@solid-primitives/media`）判定（session.tsx:448、session-side-panel.tsx:95 等 5 处）——这是**硬编码 768px 断点**，未发现断点 token 常量。

**移动形态。** 侧栏变底部抽屉（layout.mobileSidebar，layout.tsx:2331-2344 遮罩 + 滑入）；

会话页移动端在"session/changes"两 tab 间切换（session.tsx:2017-2053 mobileTabs），tab 栏位置可设（general.mobileTitlebarPosition top/bottom，session.tsx:2052-2055）；

新布局外层有 env(safe-area-inset-*) 安全区（layout-new.tsx:28-31），standalone 模式 `#root` 用 100vh（index.css:19-25）。

**桌面窗口。** electron-window-state 每窗口持久化几何 + 注册表恢复多窗口（windows.ts:157-160,168-234）；缩放 webContents.setZoomFactor 钳制 0.2-10，捏合缩放开关持久化（PINCH_ZOOM_ENABLED_KEY，windows.ts:131-139,518-531）；全屏事件推送 renderer；无响应采样 + 恢复对话框（wireWindowRecovery）。

**TUI 终端尺寸。** 根节点 `width/height = useTerminalDimensions()`（app.tsx:1088-1091），对话框宽度按终端宽度夹取；崩溃屏按高度隐藏次级内容；diff_style: "auto" 配置按终端宽度切换 diff 排版（config/index.tsx DiffStyle）。

**面板布局（Web）。** LayoutProvider（context/layout.tsx）持久化侧栏/文件树/会话面板/终端面板的 opened 与尺寸（DEFAULT_SIDEBAR_WIDTH 344、FILE_TREE 200、SESSION 600、TERMINAL 280，:36-41），resize 方法由共享 ResizeHandle（ui/components/resize-handle.tsx：拖拽改尺寸，min/max/折叠阈值，拖拽时锁 body 选择与滚动）驱动；

TUI 无面板拖拽，会话布局固定。

## 6. 图片、附件、拖放与常见内容交互

**图片预览（Web）。** 共享 ImagePreview（ui/components/image-preview.tsx：Kobalte Dialog + 关闭按钮 + `<img>`，无缩放/旋转/导航）；消息内消费入口（附件卡片点击、data URL 直出）与下载/揭示见 [`../消息渲染器/OpenCode-消息渲染调查笔记.md`](../消息渲染器/OpenCode-消息渲染调查笔记.md)。**本次未找到独立灯箱组件**（缩放/旋转/翻页能力），图片以自然尺寸展示于对话框内。

**TUI 图片。** 终端内不渲染位图（消息中图片以文件/链接呈现，见消息渲染笔记），无预览浮层。

**剪贴板。** TUI ClipboardProvider（context/clipboard.tsx）经 clipboardy 写系统剪贴板，tmux 下同时写 OSC52 直写与 passthrough（见 Chat UI 笔记第 6 节）；Web 复制走浏览器 API + toast 反馈（toast.session.share.copy.copied 等）；桌面 readClipboardImage 经 preload 读剪贴板图片（prompt 粘贴，见 Chat UI 笔记第 3 节）。

**拖放（Web）。** 文件树拖出（`dataTransfer.setData("file:path"/"text/uri-list")`，file-tree.tsx:159-161）；标签拖拽排序用 @dnd-kit（session-sortable-tab.tsx、session-sortable-tab-v2.tsx）；项目编辑对话框拖入目录（dialog-edit-project.tsx:47-55）；

Composer 图片粘贴/拖入与失败恢复走 toast（见 Chat UI 笔记第 3 节）。**未发现全局 drop zone/上传中转层**——各消费点自行处理 dataTransfer。

**附件选择（桌面）。** preload `openFilePicker/openDirectoryPicker/saveFilePicker/readPickedFile`（主进程 dialog.showOpenDialog，ipc.ts:155-171）——桌面文件选择走原生对话框。

## 7. 扩展调查：桌面集成（Electron）

**原生菜单。** 模板 `app/src/desktop-menu.ts`（role/action/accelerator/平台限定），主进程 `menu.ts` 按平台过滤生成，文案走 nativeT（desktop 的 `i18n/desktop-native.ts` 原生翻译包）；菜单命令经 menu-command 事件回传 renderer（ipc.ts:303）。

**系统通知。** 无主进程通知通道，renderer 用浏览器 Notification（见第 3 节）。

**本次未找到。** 托盘图标（`packages/desktop` 全目录检索 Tray|tray 无命中）、全局快捷键（globalShortcut 无命中）、Dock 角标（setBadgeCount 无命中）、setProgressBar（未检索，未确认）。

**窗口恢复与崩溃恢复。** 多窗口注册表 + 每窗口状态文件（window-registry.ts、windows.ts:281-289）；渲染进程崩溃/无响应/加载失败弹原生恢复对话框（重载/导出日志/退出，windows.ts:345-472）。

## 8. 设计取舍与已确认边界

**双表面两套基础设施。** TUI 与 Web 不共享组件代码（仅共享 `@opencode-ai/ui` 于 Web 侧与 session-ui 渲染包），"弹窗/Toast/主题"各有实现，服务端会话/事件流是唯一共享层。

**TUI 弹窗栈是单栈 single-flight。** replace 语义配合命令面板式交互，深层嵌套弹窗场景少；Esc/ctrl+c 双键关闭、遮罩点击关闭、选区复制优先。

**Web 弹窗栈的 owner 继承。** 新弹窗的 owner 取栈顶弹窗 owner（dialog.tsx:186-191），配合 100ms 退场延迟解决"触发者先卸载"的焦点/资源归属问题（对比 Cherry Studio 的 focusOnClose 转义口，本项目把落点交给 Kobalte 内部处理）。

**Toast 双代并存。** v1（Kobalte）与 v2（solid-sonner）按新旧布局静态切换，共享 showToast 门面但注册表分离——说明界面基础设施正处迁移期（新布局全部 v2 化）。

**主题"解析生成"而非"静态样式表"。** TUI 从终端 palette 生成 system 主题、Web 从主题 JSON 生成 CSS 变量并缓存到 localStorage——第三方/自定义主题无需预编译。

**Web 主题扩展 API 未接线。** registerTheme、`loader.ts`（loadThemeFromUrl 导入等）是库级导出但无 App 内调用方，产品侧主题面就是 37 个内置 JSON + 运行时选择器；无主题市场/导入导出 UI（检索范围见第 4 节）。

**字号设置暂未驱动界面。** settings.appearance.fontSize 无消费方，Font 组件是 no-op，字号仅靠静态 token。

**桌面无托盘/全局快捷键。** 窗口交互（恢复、缩放、全屏）都由主进程窗口层承担，原生菜单承担编辑/窗口命令。

**TUI 无上下文菜单。** 右键语义是选区复制（本次未找到菜单实现）。

**移动端 768px 硬断点。** 无断点 token，各处各自 createMediaQuery。

## 9. 未验证事项

- Kobalte 与 opentui 依赖内部的焦点陷阱、Esc、Portal、动画与读屏行为未下钻（依赖内部未核实）。
- 视觉效果、焦点顺序、键盘可用性、触摸手势与响应式切换需运行验证（本笔记全部为静态确认）。
- TUI `system` 主题在不同终端（kitty/XTerm/Windows Terminal）的 palette 探测与 waitForThemeMode 超时表现未实测。
- Web v1/v2 Toast 切换仅在布局静态绑定（`setV2Toast(false/true)` 各一处），运行期热切换路径未验证。
- 桌面无响应恢复对话框、原生菜单各平台形态、Windows 标题栏 overlay 外观未运行验证。
- Web 通知中心的"跨窗口已读同步"依赖 localStorage storage 事件，实际多窗口表现未实测。
- desktop 包 setProgressBar 能力未检索（未确认有无）。
- 图片预览无缩放/旋转（静态确认组件无这些交互），消息内消费链路的实际体验见消息渲染笔记的运行验证项。
- Web registerTheme 与 `loader.ts`（loadThemeFromUrl/applyTheme/removeTheme 等）无 App 内调用方，其运行时行为未经运行验证（静态仅确认定义与导出）。
- settings.appearance.fontSize 本轮未找到消费方，若存在隐藏接线点需运行验证；`--font-size-*` 静态 token 的实际生效范围未实测。

## 10. 关键源码索引

- `packages/tui/src/app.tsx`：TUI 根装配（renderer 创建、Provider 树、全局命令、Toast 桥接、更新流程）
- `packages/tui/src/ui/dialog.tsx`、`dialog-confirm.tsx`、`dialog-prompt.tsx`、`dialog-alert.tsx`、`dialog-select.tsx`：TUI 弹窗栈与命令式对话框
- `packages/tui/src/ui/toast.tsx`：TUI 单条 Toast
- `packages/tui/src/context/theme.tsx`、`packages/tui/src/theme/index.ts`：TUI 主题解析、system 主题生成、语法高亮规则
- `packages/tui/src/context/kv.tsx`：TUI 偏好持久化（kv.json）
- `packages/tui/src/routes/session/footer.tsx`、`component/startup-loading.tsx`、`component/error-component.tsx`：状态行/启动加载/崩溃屏
- `packages/tui/src/keymap.tsx`：模式栈、leader、斜杠命令
- `packages/app/src/entry.tsx`、`src/app.tsx`：Web 根装配（AppBaseProviders/AppInterface/ConnectionGate）
- `packages/ui/src/context/dialog.tsx`：Web 弹窗栈（show/push/close、Esc、100ms 退场）
- `packages/ui/src/components/dialog.tsx`、`v2/components/dialog-v2.tsx`：弹窗呈现
