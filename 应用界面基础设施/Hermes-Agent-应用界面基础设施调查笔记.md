# Hermes Agent 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\hermes-agent`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 同时维护 Electron 桌面、Ink TUI 和 Web dashboard 三套界面。三端不共享组件实现，但共享后端皮肤与通知协议，并采用从种子值派生语义 token 的主题思路。

桌面端由贡献注册表装配 pane、标题栏、命令面板和路由。弹窗基于 Radix，并提供专门的 Portal 容器解决弹窗内 Popover 的层级问题；通知使用模块级 atom，在顶部和右下角分别承载重要提示与环境提示。TUI 则以单一 overlay state 管理流内提示、浮层面板和 widget 模态。

三端主题权威源各不相同。桌面按 profile 存于 localStorage，TUI 使用启动缓存和环境检测，Web 结合本地与服务端设置。桌面另有完整的 VS Code 主题市场链路，从 Gallery 查询、VSIX 下载到用户主题注册均在项目内实现。

## 系统边界与总体装配

| 表面 | 进程/框架 | 与后端传输 | 根装配入口 |
| --- | --- | --- | --- |
| 桌面端 | Electron 40 + React 19 + Tailwind v4 + radix-ui + nanostores | WebSocket JSON-RPC（`apps/shared`，见 Chat UI 笔记） | `apps/desktop/src/main.tsx` |
| TUI | Node + Ink fork（`@hermes/ink`）+ nanostores | stdio 换行分隔 JSON-RPC | `ui-tui/src/entry.tsx` |
| Web dashboard | React + react-router + `@nous-research/ui` | REST + `/api/pty` WebSocket | `web/src/main.tsx` |

**桌面端根装配。** Provider 顺序是错误边界、查询、国际化、主题、触觉反馈、全局 Tooltip 和路由。TooltipProvider 被提升为全应用单例，以避免拖动分栏时重复渲染；路由关闭 transition，是为了防止流式令牌更新长期挤压导航提交。（`apps/desktop/src/main.tsx:53-85`）

多窗口入口由 URL 参数 win 分支（`main.tsx:30,40-52`）：hud/overlay/quick/wake 各自挂独立根（HUD 是完整 renderer，见 Chat UI 笔记 §1），其余走主装配。模块级副作用在渲染前安装：剪贴板 IPC shim（`lib/clipboard.ts`）与 active-work/power/translucency 等 store。

应用根是贡献注册表驱动的 ContribController（`app/contrib/controller.tsx:697-786`）：SidebarProvider 包住 ContribWiring，内部是固定 34px 标题栏（left/center/right 三个 slot，拖拽区与控件区分离）、LayoutTreeRoot（pane 树，见下）、SessionTileCloseConfirm 与状态栏——状态栏未挂载时整条 unmount（:781）。

pane、布局预设、快捷键、命令面板条目全部通过 ContributionRegistry 注册（`contrib/registry.ts`）：按 area 分桶、快照缓存、区域级失效（改一个状态栏条目不会重渲染标题栏 slot），核心界面与插件走同一注册 API（discoverBundledPlugins 在核心之后加载，同名贡献后者覆盖前者，`controller.tsx:395-402`）。

四个 wired surface（sidebar/chatRoutes/terminal/statusbar，`app/contrib/surfaces.tsx`）各自 memo 化、各自订阅自己的 atom；动作全部收进稳定身份 actions ref（`wiring.tsx:861-924`），任何 pane 的内容级更新不经过控制器。

**TUI 根装配**（`ui-tui/src/entry.tsx`）：启动即 resetTerminalModes 清残留 DEC 鼠标/粘贴模式；GatewayClient 走 stdio；内存监视与优雅退出链（EIO/EPIPE 连续 5 次即退出，:80-88）；ink.render 挂载 App，禁用 Ctrl+C 退出、启用超链接点击。

App（`app.tsx:9-25`）只有 GatewayProvider + AppLayout 两层；AppLayout 再组装状态栏（上下两条 StatusRulePane）、FloatingOverlays、PromptZone、两侧 AmbientRail、底部 AmbientDock、ActiveWidgetSlot（`appLayout.tsx:366, 448, 538-582`）。

**Web 根装配**（`web/src/main.tsx`）：BrowserRouter → I18nProvider → ThemeProvider → SystemActionsProvider → App。

App（`web/src/App.tsx:371-823`）内嵌 ProfileProvider，侧栏（移动抽屉/桌面折叠双态）、Suspense 路由表（RouteFallback = Spinner + 文本）、插件 tab/路由合并（buildRoutes，tab.override 可整页替换内置路由）、`/chat` 为持久 xterm host（首访后常驻挂载、非 chat 路由时 display:none 保活，`App.tsx:406-409, 790-811`）。

## 1. 界面栈、公共组件与状态所有权

**桌面端**：公共组件集中在 `src/components/ui/`（75 个文件，覆盖弹窗、浮层、菜单、按钮、提示、空态、骨架屏与加载器等），全部基于 radix-ui（合并包 1.6.7）封装 + Tailwind v4 token 类。

另有少量局部使用 `motion/react`（`components/ui/diff-count.tsx:1`、`app/right-sidebar/review/file-tree.tsx:3` 的 AnimatePresence）与 cmdk（命令面板）。

`@nous-research/ui` 在桌面只被引用字体资源（`styles.css:40`）与像素风图案（`components/chat/vibe-hearts.tsx:37`），组件不来自它——依赖清单中有该包，但组件面没有接入。会话列表排序用 @dnd-kit（见第 6 节）。聊天正文渲染栈（assistant-ui、shiki 等）见消息渲染器类目。

**状态所有权**（桌面）：遵从 `apps/desktop/AGENTS.md` 的“按权威放状态”契约——后端权威的数据走 react-query 缓存 + store 投影（聊天主链见 Chat UI 笔记 §8）；Electron 权威的机器事实走 window.hermesDesktop 窄桥；

渲染层自己拥有的是“纯本窗口呈现”状态（`store/` 下 151 个 nanostores atom，覆盖布局、侧栏、主题、输入框、通知、窗口等）。持久化偏好按“作用域自声明”原则存 localStorage（如主题按 profile 分键、侧栏视图状态、预览标签）。

命令式 UI 状态（弹窗开合、toast、调色板开关）都是模块级 atom（`$commandPaletteOpen`、`$notifications`、`$sessionPickerOpen`），不经过 React context，命令入口与渲染视图共享同一 store。

**TUI**：`$uiState`/`$overlayState`/`$uiSessionId` 等模块级 atom（`app/uiStore.ts:41`、`app/overlayStore.ts:27`）；浮层状态全部集中在 `$overlayState` 一个 atom 的字段上（见第 2 节）。

**Web**：主题/Profile/SystemActions 走 context（`web/src/themes/context.tsx`、`contexts/ProfileProvider.tsx`），服务端数据走 `lib/api` 的 fetch 封装。

## 2. 弹窗、浮层与菜单

### 桌面端：Radix Dialog 封装 + 弹窗内 Popover 改投 + 覆盖层视图

- **Dialog**（`components/ui/dialog.tsx`）：直接包 radix-ui Dialog。

  Overlay 层级 z-(--z-modal-backdrop)（120）、Content z-(--z-modal)（130），开合动画是 Tailwind `data-[state=open|closed]` 类（fade + zoom，200ms），滚动在内容内层 box 上（`max-h-[85vh]`）。

  Esc/遮罩关闭/焦点陷阱交给 Radix 默认行为——代码未覆盖 onEscapeKeyDown/onInteractOutside（依赖内部行为未下钻，见未验证事项）；提供了 preventCloseButtonAutoFocus 转义口子（`dialog.tsx:59-61`），给无输入框的对话框抑制“首焦落在关闭按钮”导致的 tooltip 闪现。

  横幅变体 banner（error/warn/info 三色调，底部贴边，`dialog.tsx:125-170`）。
- **弹窗内 Popover 改投**（`components/ui/dialog-portal-context.ts`）：Radix 的 Select/Popover/DropdownMenu 默认 portal 到 document.body，会成为 Dialog 的 DOM 兄弟——弹窗内点下拉时，DismissableLayer 把弹窗内交互判为“outside”误关整个弹窗，且 z-index 在跨 body 兄弟间不可控。

  DialogContent 把自身 content 节点发布进 context（`dialog.tsx:100,146,192`），下列三个浮层组件的 Portal container 都改为弹窗节点：
  - `popover.tsx:33-36`
  - `select.tsx:50-53`
  - `dropdown-menu.tsx:79-82`

  浮层成为弹窗真子节点后，焦点不出弹窗，层级共享弹窗 stacking context。
- **ConfirmDialog**（`components/ui/confirm-dialog.tsx`）：共享确认弹窗，Enter/Space 从弹窗任意位置触发确认（onKeyDown，:99-106），内部自带 pending→done→close 节拍（done 后 600ms 自动关）、内联错误（throw 后保持打开）、dismissOnConfirm 乐观模式。
- **覆盖层视图**（settings/command-center/agents/cron/profiles/webhooks/starmap）：不是 Modal，而是挂在 ContribWiring 尾部、由 hash 路由驱动的全尺寸视图（`wiring.tsx:1057-1119`，懒加载 Suspense）；关闭时回跳被覆盖前的路由（`use-overlay-routing.ts:33-59` 的 returnPathRef）。
- **命令面板 ⌘K**（`app/command-palette/index.tsx`）：Radix Dialog + 透明 overlay（保留 click-away 与焦点陷阱，无遮罩变暗，:1270-1272）+ cmdk。搜索排序是自研的（scoreItem/rankGroups，:180-241，cmdk 只当键盘/选择机制，`shouldFilter={false}`）；

  支持嵌套子页，Esc 或空输入时逐级回退（:1315-1323）；关闭动画由 content 的 animationend 事件驱动卸载，`EXIT_FALLBACK_MS=1000` 仅作兜底（:254,1284-1288）；行列表在打开后第二帧渲染（useDeferredValue，:280-283）。

**window 级 Esc 协商。** 多个 window keydown 处理器（窄屏侧栏揭示、布局编辑、zone 编辑器、覆盖层、拖拽）经 `escape-layers.ts:6-15` 的 pushEscapeLayer/isTopEscapeLayer 按优先级（10-50）串行化，一次 Esc 只命中最上层；Radix 弹窗因 stopPropagation 天然排在契约最上。
- 右键/上下文菜单：`components/ui/context-menu.tsx`（Radix ContextMenu 封装，子菜单额外 portal 出父 Content 防 overflow 裁剪，:140-165）；业务侧消息/会话行等消费点在 Chat UI 与消息渲染器笔记。

### TUI：单一 overlayStore + 三种形态

`$overlayState` 一个 atom 管全部浮层（`app/overlayStore.ts:27`），按形态分三类（`appOverlays.tsx`）：

1. **flow 提示**（approval/billing/subscription/confirm/clarify/sudo/secret，PromptZone，:58-163）：在正常文档流中渲染于 ComposerPane 之上（`appLayout.tsx:553-568`），**推挤**下方内容而不是覆盖；Esc/数字键/Enter 各自绑定（ApprovalPrompt 是纯函数键分发，Esc=deny，`components/prompts.tsx:52-81`）。
2. **浮层面板**（sessions/modelPicker/petPicker/skillsHub/pluginsHub/pager/completions，FloatingOverlays，:165-384）：`position="absolute" bottom="100%"` 从 Composer 顶部向上生长（:380-383），面板包 FloatBox 边框；completions 列表是固定 16 行居中视口（COMPLETION_WINDOW，:203-205）。
3. **widget 模态**（SDK 应用，ActiveWidgetSlot，`sdk/host.tsx:209-214`）：渲染在视图层，可锚定九宫格 zone + 伪 scrim（`components/overlay.tsx:31-66`，scrim 是逐行空格 + 背景色，注释引用 lipgloss 的经典模式；Dialog 是圆边框卡片原语，:76-105）。模态打开期间独占键盘（`useInputHandlers.ts:440-442`）。
另有 AmbientDock/AmbientRail（in-flow 驻留卡片：dock 行保留真实行高、rail 从转录宽度预算中扣除列宽，`sdk/host.tsx:219-286`）。浮层关闭语义：resetFlowOverlays 在每轮结束只清 flow 类，用户主动打开的（agents/modelPicker/skillsHub…）保留（`overlayStore.ts:150-163`）。

### Web：`@nous-research/ui` 组件库

ConfirmDialog（重启/更新确认，:1068-1095）与 useToast（见第 3 节）来自 `@nous-research/ui`（`web/src/App.tsx:63` 等）；OAuth 登录模态是自绘（`components/OAuthLoginModal.tsx`，遮罩点击关闭 :160）；

主题/语言切换器在窄屏用底部 sheet 形态 portal 到 body（`components/LanguageSwitcher.tsx:26-31` 注释、`components/ThemeSwitcher.tsx:22-27` 注释）。该库内部实现（焦点陷阱、Esc、层级）未下钻。

## 3. 通知、加载态与错误反馈

### Toast（桌面，自研 store，非 sonner/react-hot-toast）

- **store**（`store/notifications.ts`）：模块级 `$notifications` atom，`notify()` 按 id 幂等替换（同 id 新 toast 顶掉旧 toast，:176），栈上限 4 条；时长默认 `error/warning` 为 0（不自动消失）、其余 5s（defaultDuration，:52-58）；

  位置默认 `error/warning` 或带 action 的走顶部居中、其余右下（defaultPlacement，:67-73）。

  notifyError 维护错误摘要规则表（ERROR_SUMMARIES，:91-133），覆盖磁盘满、网关鉴权失败、OpenAI API key 被拒（带状态码）、ElevenLabs/麦克风权限等常见错误，并把超过 180 字符的错误折叠为 fallback 加可展开 detail。
- **渲染**（`components/notifications.tsx`）：两个 portal 到 body 的栈——TopCenterStack（`role="region"`，最新一条常显 + “+N more”展开 + clear-all，:104-141）与 BottomRightStack（全部平铺，:145-164）。

  单条 role/aria-live 按 kind（error → alert/assertive，其余 status/polite，:205-207）；detail 用 `<details>` 折叠 + 复制按钮；成功/错误/警告触发对应 haptic（:71-77）。注释说明 portal 到 body 的必要性：React 根子树内的 toast 会被 body 级弹窗遮罩盖住（:99-103）。
- **后端通知接入**（`store/agent-notices.ts`）：后端 notification.show 负载（Python `agent/credits_tracker.py` 的 AgentNotice 经 `tui_gateway/server.py` 转发）映射为 toast，映射规则如下：
  - 剥离前导严重级字形（CLI/TUI 用字形表达级别，桌面 toast 已有图标，stripGlyph，:39-44）；
  - 用 · 分隔主文本与 meta；
  - key 兼作 toast id，同 key 重复发射原地替换（额度 50→75→90 逐级原地升级，:107-109）；
  - 额度用量按 75%/90% 门槛变色（noticeAccent，:74-98）。

  notification.clear 按 key 关闭；原生 OS 通知只放行 credits.depleted/credits.restored 两种（:180-206）。
- **原生系统通知**（`store/native-notifications.ts`）：与 in-app toast 分开的独立通道，7 类 kind 各自独立开关（approval/input/turnDone/turnError/backgroundDone/credits/plugin），1s 节流去重（:94-111），仅“后台”（document.hidden 或失焦）时发送，但 approval/input 属于 ATTENTION_KINDS 前台也发（:26, 116-120）。

### TUI 通知

后端 notification.show 在 TUI 渲染为状态栏 notice（`components/appChrome.tsx:478-660`）：busy 时 FaceTicker 优先、空闲时 notice 文本替换状态槽（`showNotice = !busy && !!notice?.text`，:516），按 level 着色（noticeColor，:237），长文本收缩省略。无 toast 形态（终端表面没有浮动通知）。

### 加载 / 空状态 / 错误边界

**桌面。** Loader 是自研 SVG 数学曲线粒子（21 种曲线，rAF 驱动，`components/ui/loader.tsx`），PageLoader/Skeleton/EmptyState（`components/ui/empty-state.tsx`，居中标题+描述，图标+动作版本是 overlays/panel 的 PanelEmpty）/ErrorState 是公共原语。

聊天列表的加载/空状态与渲染预算（RENDER_BUDGET、content-visibility）见 Chat UI 与消息渲染器笔记，不重复。
- **错误边界**（`components/error-boundary.tsx`）：class 组件，根级 RootErrorBoundary（`label="root"`）fallback 是固定全屏 z-(--z-crash)(1500) 的 ErrorState（重试/重载窗口/打开日志，:142-163）；

  componentDidCatch 把组件栈上报主进程写 desktop.log（window.hermesDesktop.reportRendererError，:60-66）；根级对特定 assistant-ui 查找越界错误自动恢复（最多 3 次/5s 窗口，:26-30, 73-78）。

  贡献系统有自己的“防爆墙”ContribBoundary（`contrib/react/boundary.tsx`）：每个插件的 render 都包一层，崩溃只降级为该 slot 内的小型错误（chip 变体）或 pane 内 ErrorState（pane 变体），不拖垮整个应用。

**TUI。** 加载原语是共享 shimmer 时钟（90ms tick、订阅计数驱动启停、30s 动画预算后冻结，`components/loaders.tsx:62-126`）；widget 崩溃由 WidgetBoundary 降级为一行 `⚠ /<appId>: …`（`sdk/host.tsx:150-166`）。

**Web。** 路由级 RouteFallback（Spinner + 文案，`App.tsx:110-123`）；加载/错误语义跟随 `@nous-research/ui`。

## 4. 主题、视觉 token 与持久化

三端共享同一个后端皮肤协议（`~/.hermes/skins/*.yaml`：Python 端 `hermes_cli/skin_engine.py` 解析与 resolve_skin，TS 端契约类型在 `apps/shared/src/skin.ts`——SKIN_COLOR_TOKENS 30+ 语义 token、终端口在前、GUI 从 load-bearing 少数派生；

变更经 `tui_gateway/server.py` 的 skin.changed 广播），但权威源与持久化各不相同；共同哲学是“少量种子色 → 派生全部次级 token”：

- **桌面**（`themes/context.tsx`）：主题名（skin）与明暗模式（mode）按 **profile 分键**持久化于 localStorage（PROFILE_SKINS_KEY/PROFILE_MODES_KEY，未分配 profile 回退全局旧键 hermes-desktop-theme-v2，:29-37, 58-67），`system` 模式用 matchMedia('(prefers-color-scheme: dark)') 即时解析（resolveMode，:44-45）。

  模块加载时立即按“上次活跃 profile”预应用主题（:274-281），并把背景色/色系写进 hermes-boot-background/hermes-boot-color-scheme 两个 localStorage 键供 index.html 内联脚本在 React 挂载前给首帧上色（:243-252）——双保险防首帧闪烁；跨窗口同步靠 storage 事件（:361-376）。

  应用时把 seed 色写进 `--theme-*` 行内变量，`styles.css` 用 `color-mix()` 派生 `--ui-*` 语义层，另设 `--dt-*` shadcn token 直通（:198-234）；data-hermes-theme/data-hermes-mode/`.dark` class 与 color-scheme 同步（:192-195）；

  renderedMode 按背景亮度反推（避免“暗色主题但亮背景”误判，:148-158）；字体经动态 `<link>` 注入（去重，:254-261）。原生窗口外观引脚：setNativeTheme 把 Electron nativeTheme 固定到应用模式（标题栏/模糊材质跟随，:268-269）。

  **后端皮肤同步**（`themes/backend-sync.ts`）：gateway.ready 只播种不应用（防新鲜连接覆盖用户持久化选择），skin.changed 或名变更才经 `$pendingSkinApply` 应用（:80-93）；`/skin` 命令与后端激活共用此路径。

  **主题市场与用户主题**：VS Code Marketplace 是一个完整子系统，两个入口——Cmd-K “Install theme…” 页（`app/command-palette/marketplace-theme-page.tsx`，空查询=热榜、300ms 防抖搜索、staleTime 5min，已装主题仅重激活不重下载，装完保持打开可连装）与外观设置页搜索行（`app/settings/appearance-settings.tsx:96-140`，同管线，行内还有按当前 mode 渲染的 ThemePreview 卡片与 UI 缩放预设 UI_SCALE_PRESETS）。

  下载在 Electron 主进程（`electron/vscode-marketplace.ts:1-22`）：Gallery ExtensionQuery API 解析最新版本、拉 VSIX（40MB 上限、5 跳转、20s 超时），手写 central-directory 解析 + zlib inflate（零 zip 依赖），只读 `package.json` 与主题 JSON、不执行任何主题代码。

  转换在渲染进程（`themes/vscode.ts:1-25`）：数百个 workbench key 只取 ~6 个 load-bearing（background/foreground/accent/elevated surface/sidebar/error），其余全由 color-mix 派生，accent 另设 WCAG AA 4.5:1 护栏（防侧栏“隐形紫标签”，ACCENT_MIN_CONTRAST）；

  `themes/install.ts:19-70` 支持粘贴 JSON 导入与市场下载，明暗双变体合并为一个主题族（light→colors/dark→darkColors，terminal ANSI 同轨）。

  安装结果进**用户主题注册表**（`themes/user-themes.ts:21-140`，localStorage hermes-desktop-user-themes-v1）：与内置主题合并为统一注册表供 Cmd-K/设置页/`/skin` 消费，内置名不可被覆盖，`$marketplaceInstalls` 按 description “VS Code · publisher.extension” 约定跟踪已装扩展，localStorage 持久化使首帧 paint 可同步解析用户主题。

  **accent 派生护栏**：皮肤→桌面模型（`themes/skin.ts:65-104`）只认 accent 等少数种子（ui_accent→banner_accent→banner_title→mix 回退），primary/ring/midground/composerRing 全由 accent 驱动；

  `styles.css:165-169, 255-289` 的 `--theme-fill-{primary..quinary}-accent-mix`（3%~16%）五级填充与 row-hover/active mix 阶梯把单一 accent 摊成整套 `--ui-bg-*` 表面（`DESIGN.md:100` 的 token 表归纳了这一契约）。
- **TUI**（`theme.ts` + `lib/themeBoot.ts`）：亮/暗检测是有序 env 链（HERMES_TUI_LIGHT → HERMES_TUI_THEME → HERMES_TUI_BACKGROUND 亮度 → COLORFGBG → TERM_PROGRAM 白名单，detectLightMode，:702-762）；

  `fromSkin()` 把后端皮肤转为 ThemeSeeds，次级色调全部由 mix 阶梯派生（deriveTones，注释明确这是桌面 color-mix 体系的终端版，:556-568），并对真实终端背景做对比度护栏（display 1.45 / semantic 2.2，亮端更低，:472-475）与填充极性回退（:528-538）；

  Apple Terminal 有限色板路径把前景归一化为 ansi256（:764-791）。

  **首帧防闪烁**：上次解析的主题写入 `$HERMES_HOME/tui-theme-boot.json`（防抖 400ms 原子写，`themeBoot.ts:96-121`），启动时回放为第一帧（`$uiState` 初始值即 bootTheme，`app/uiStore.ts:37`），并回种 env 让首次皮肤解析与上次一致（seedBootEnvironment，:148-179）。

  TUI 的显示密度是 `/density [on|off|toggle]` 命令（`app/slash/commands/core.ts:285-300`）：写 `$uiState.compact` 并 config.set density 持久化——属于紧凑布局开关，与皮肤/主题 token 无关。
- **Web**（`web/src/themes/context.tsx`）：**服务端是权威源**（`api.getThemes()/setTheme`，内建 + 用户 YAML，:474-517，用户主题来自 `~/.hermes/dashboard-themes/*.yaml`，后端扫描在 `hermes_cli/web_server.py:16704-16735`），localStorage 只做首帧防闪烁缓存（STORAGE_KEY，:34-35, 411-423，旧主题名迁移 migrateThemeName）；

  字体覆盖独立于主题（服务端权威 + localStorage 防闪，:41, 443-449, 521-541）。

  token 输出为 :root 行内变量：
  - palette 分层：`--background`/`--midground`/`--foreground` 的 color-mix 透明度层（:68-78）；
  - 排版与布局：字体参数、半径与密度系数 `--theme-spacing-mul`；
  - `--color-*`：shadcn 覆盖与数据序列色；
  - `--theme-asset-*`：背景、徽标等；
  - `--component-<bucket>-*`：组件样式桶；
  - customCSS：单一 `<style>` 标签复用替换（:260-276）；
  - 终端前景/背景：xterm 使用（:392-400）。

  切换时清上一主题的全部动态变量（:351-373）。

  主题 YAML 分为 palette、typography 和 layout 三层。字体层控制正文、等宽和展示字体及排版参数；布局层控制圆角与 compact、comfortable、spacious 三档密度，并映射为 CSS 变量。（`themes/types.ts:4-19`）

  扩展层还包括三种布局变体、18 个颜色覆盖口、命名视觉资产槽和主题选择器 swatch。资产槽覆盖背景、横幅、Logo、徽章、侧栏和标题栏，并与后端使用同一名单。（`themes/context.tsx:114-227,282,390`）
- **本次未找到**（壁纸设置器与独立强调色选择器）：桌面/TUI 内 grep wallpaper/backgroundImage/backgroundOpacity 零匹配，桌面背景是纯色 token（无壁纸机制）；

  Web 的整幅背景图只能由主题 YAML 的 assets.bg 提供（`--theme-asset-bg`，注释指明供 backdrop 插件槽或主题 customCSS 消费，`types.ts:83-85`），无独立壁纸设置 UI；

  grep primaryColor 三端零匹配，强调色只能随皮肤/预设/市场导入主题变化，三端都没有用户直接选主色的 UI（TUI deriveTones 与桌面 `--ui-accent` 的 mix 体系见上文）。

## 5. 响应式、移动端与窗口适配

**桌面断点。** 唯一断点是 `SIDEBAR_COLLAPSE_BREAKPOINT_PX = 768`（`app/layout-constants.ts:24-25`，`$narrowViewport` 经 matchMedia 驱动，`components/pane-shell/tree/store.ts:977-981`）。

窄视口下 collapsible 边栏（sessions/files/review）**离开网格**转为边缘覆盖层：边条 hover 悬停揭示 + ⌘B/⌘G 钉住揭示 + Esc 关闭（`narrow-overlays.tsx:103-147`），宽度取 pane 声明宽与 85vw 的小者。

pane 树本身是重量级可拖拽布局（split/group 权重、preset：Default/Focus/Terminal deck/Quad，`controller.tsx:342-391`），会话选项卡可拖成独立 pane。
- **窗口最小尺寸**（Electron）：
  - 主窗：`MIN_WIDTH=400`（`electron/window-state.ts:14`，默认 1220×? 记忆化恢复）
  - 独立会话窗：`SESSION_WINDOW_MIN_WIDTH=420` / `MIN_HEIGHT=620`（`electron/session-windows.ts:10-11`）
  - HUD 窗：minWidth 380（`electron/main.ts:9213`）

  无按窗口宽度的自动侧栏折叠——768 断点只作用于 renderer 视口。
- **多窗口**（`store/windows.ts` + `electron/main.ts`）：win 参数区分主窗/secondary（单会话无侧栏窗）/hud/pet overlay/quick entry/wake；watch 参数是子代理旁观窗（懒恢复、live-mirror）；`isAuxiliaryWindow()` 决定安装/引导 overlay 只属于主窗（`windows.ts:79-84`）。

  跨窗口状态同步的通用机制是 localStorage storage 事件（主题、草稿、pin 等，见 Chat UI 笔记与第 4 节）。

**Web。** 桌面折叠（collapsed，localStorage hermes-sidebar-collapsed）与移动抽屉（mobileOpen）双态；断点 1024（useBelowBreakpoint(1024) + matchMedia("(min-width: 1024px)")，`App.tsx:395, 502-509`）；移动抽屉打开时锁 body 滚动 + Esc 关闭（:488-500）；

无独立移动入口/路由树，内容区 gutter 用 clamp(1.25rem,4vw,4rem)（`App.tsx:751`）。

**TUI。** 无断点概念；响应式等价物是 WidgetGrid 列数与 AmbientRail 宽度预算（转录宽度 = 总列宽 - rail 宽，`appLayout.tsx:146`）、浮层面板 maxWidth 按当前列数计算（`appOverlays.tsx:380-383`）、completions 视口固定 16 行。

## 6. 图片、附件、拖放与常见内容交互

- **图片灯箱**（桌面，`components/chat/zoomable-image.tsx`）：ZoomableImage（消息内图片按钮）→ ImageLightbox = 无边框 Dialog（border-0 bg-transparent），点击图片本身关闭（:90），右上角悬浮下载按钮（useImageDownload，保存中 pulse）；

  无缩放/旋转/多图导航——比 Cherry Studio 的灯箱能力面小。

  消费点覆盖消息 markdown 图片、指令文本、工具输出图、生成的图片结果与 composer 附件（测试断言“附件图走灯箱不进预览 rail”）：
  - `components/assistant-ui/markdown-text.tsx:389`
  - `directive-text.tsx:370,433`
  - `tool/fallback.tsx:611`
  - `app/chat/composer/attachments.tsx:156-164`
- **预览 rail**（桌面，`store/preview.ts`）：文件/URL/artifact 三类 PreviewTarget 的右侧标签页列表（`previewKind: binary/html/image/pdf/text`），标签持久化（hermes.desktop.previewTabs.v2，:63），dataUrl 目标仅内存不落盘（:27-28）——这是“查看文件”的主通道，与图片灯箱并存分工（附件图灯箱、文件图 rail）。

**拖放。** composer 文件拖入（useFileDropZone + partitionDroppedFiles：应用内路径→@file: ref、OS 文件→附件管线、目录→@folder:、图片→base64 缩略图）已在 Chat UI 笔记 §3 详录，不重复；统一视觉是 DROP_SHEET_CLASS 虚线 sheet（`components/ui/drop-affordance.tsx`）。

会话/项目排序是 @dnd-kit（`app/chat/sidebar/reorderable-list.tsx:51-60` 自含 DndContext、`profile-switcher.tsx`、虚拟列表 useSortable），pane 树拖拽是自研 drag-session。TUI/Web 无聊天拖放（Web FilesPage 有上传拖放，见下）。
- **剪贴板**（桌面，`lib/clipboard.ts`）：模块级把 navigator.clipboard.writeText 替换为经 Electron IPC 的主进程写入（失焦时 Web Clipboard API 抛 “Write permission denied”，IPC 路径无条件可用），失败回退原生 API（`main.tsx:30` 安装）。Web 端无此 shim。

**Web 上传。** FilesPage 拖放上传（dragDepth 计数、`dropEffect="copy"`、拖入高亮、上传中 Spinner + toast 反馈，`web/src/pages/FilesPage.tsx:82-98, 191-235, 336-347`）与文件选择按钮并存；上传走 api.uploadFile。

## 7. 扩展调查：桌面集成与浮层渲染细节

（属于可选扩展；仅记录公共设施，具体业务通知/快捷键的触发语义见各业务类目与 Chat UI 笔记。）

**HUD 与辅助窗口。** HUD 是完整 renderer（非傀儡窗），其快照快捷键、窗口位置记忆（`hud-state.json`）在 Chat UI 笔记 §1/§8；pet overlay/quick entry/wake indicator 是独立最小根（`main.tsx:46-51`）。

**快捷键。** `store/keybinds.ts` 是可重绑定 action 注册表（KEYBINDS_AREA 贡献），TipKeybindLabel 从注册表自动读标签+组合键渲染 tooltip 提示（`components/ui/tooltip.tsx:216-223`）；快捷键面板经自定义事件 hermes:open-keybinds 打开设置页（`wiring.tsx:293-298`）。
- **浮层层级变量**（`styles.css:222-236`）：
  - `--z-modal-backdrop`：120
  - `--z-modal`：130
  - `--z-modal-popover`：140
  - `--z-over-modal`：200
  - `--z-over-modal-content`：210
  - `--z-crash`：1500

  Toast 与命令面板在 over-modal 层。

**动画。** 桌面开合动画全走 Tailwind data-state 类（无 JS 补间）；`motion/react` 仅两处局部（diff 计数、文件树折叠）；Loader 是 rAF 驱动的自研曲线。TUI 的动画是终端字符级（shimmer 扫过、FaceTicker 表情帧）。

## 8. 设计取舍与已确认边界

**贡献注册表是应用壳的唯一组织方式。** pane/标题栏/快捷键/命令面板/路由/主题全部走同一 area 注册 API，核心与插件同权（`contrib/registry.ts`），插件崩溃由 ContribBoundary 按 slot 降级。

**弹窗内浮层改投弹窗节点。** 承认 Radix 默认 body-portal 在嵌套场景下破坏焦点与 z-index，用 context 改投修复（`dialog-portal-context.ts:5-19` 注释完整记载了两种失效模式）。

**Toast 双栈 + 后端 notice 映射。** 重要反馈（error/warning/带 action）与例行确认（右下）分流；后端 notice 的 key 兼作 toast id 实现原地升级，CLI/TUI 的前导字形在桌面被剥离（`agent-notices.ts`）。

**三端主题同哲学不同权威源。** 种子→派生 token（桌面 `--theme-*`→`--ui-*` color-mix、TUI mix 阶梯、Web palette 分层）；权威源分别为 localStorage（按 profile）、启动缓存+env、服务端 API；后端皮肤对桌面只是“播种不覆盖”、对 TUI 是每次启动的解析输入。

**市场主题是种子注入器而非外观镜像。** VS Code 主题数百个 workbench key 只取 ~6 个作为种子，其余全部 color-mix 派生（`vscode.ts:4-9` 注释），与“少量种子→派生全部次级 token”哲学同构；accent 单独设 WCAG AA 4.5:1 护栏，单模式主题经“明暗双变体合并”让桌面明暗切换映射真实变体（`install.ts:27-37` 注释）。

**用户主题与内置主题合并注册、零接线消费。** 桌面 localStorage 用户主题注册表与内置合并后供 Cmd-K/设置页/`/skin` 统一消费，内置名不可覆盖；Web 端用户主题走服务端 YAML（`~/.hermes/dashboard-themes/`）权威，与皮肤的 `~/.hermes/skins/` 是两套并行的用户主题体系。

**聊天表面不共用界面代码。** 桌面/TUI/Web 是三种独立装配（根 AGENTS.md 明示 dashboard 嵌 TUI 而非重写，桌面不嵌 TUI），唯一共享是 `apps/shared` 连接层与后端皮肤/notice 协议。

**错误文本规范化。** 桌面 notifyError 对远程调用包装（“Error invoking remote method…”）、"detail" JSON、磁盘满/API key 等常见错误做摘要化（`notifications.ts:91-153`）。

**边界。** 聊天主链（草稿/附件/流式/消息操作）在 Chat UI 笔记；消息内容渲染在消息渲染器类目；Python 核心的 UI 交点仅皮肤 YAML 与 notification.show 协议。

## 9. 未验证事项

- Radix 内部行为（Esc 关闭、focus trap、DismissableLayer、cmdk 键盘语义、Tooltip 焦点守卫的实际读屏效果）未下钻依赖源码，依赖版本为 radix-ui 1.6.7/cmdk 1.1.1。
- `@nous-research/ui` 内部（Web 的 useToast/ConfirmDialog/BottomSheet 行为与焦点管理）未下钻。
- 视觉效果与运行行为（Loader 动画、Dialog 开合、narrow-overlay 悬停、Toast 堆叠、主题色差、motion 折叠）未经运行验证。
- 多窗口并发事件时序（HUD/主窗/旁窗同时操作）、系统通知触发、nativeTheme 引脚行为未实测。
- 桌面 768 断点、Web 1024 断点、窗口最小尺寸的实际表现未运行验证。
- TUI 终端渲染（Ink fork 的滚动/重绘、OSC-11 背景探测、Apple Terminal ansi256 归一化）未运行验证。
- 后端 notification.show/皮肤协议与三端消费的字段契约已静态核对，端到端实际报文未抓包验证。
- VS Code 市场端到端链路（Gallery API 查询、VSIX 下载/解包、明暗变体合并、粘贴导入）未运行验证，`electron/vscode-marketplace.ts` 的手写 zip central-directory 解析行为未实测。
- Web 主题的 assets.bg/hero 背景图、layoutVariant 的 cockpit/tiled 布局变体、swatchColors 与密度三档的实际渲染效果未运行验证。

## 10. 关键源码索引

- 桌面根：`apps/desktop/src/main.tsx`、`app/contrib/controller.tsx`、`app/contrib/wiring.tsx`、`app/contrib/surfaces.tsx`、`contrib/registry.ts`、`contrib/react/boundary.tsx`
- 桌面浮层/菜单：`components/ui/dialog.tsx`、`components/ui/dialog-portal-context.ts`、`components/ui/confirm-dialog.tsx`、`components/ui/context-menu.tsx`、`components/ui/sheet.tsx`、`components/ui/tooltip.tsx`、`app/command-palette/index.tsx`、`lib/escape-layers.ts`、`app/shell/hooks/use-overlay-routing.ts`
- 桌面通知/反馈：`store/notifications.ts`、`components/notifications.tsx`、`store/agent-notices.ts`、`store/native-notifications.ts`、`components/error-boundary.tsx`、`components/ui/loader.tsx`、`components/ui/empty-state.tsx`、`components/page-loader.tsx`
- 桌面主题：`themes/context.tsx`、`themes/backend-sync.ts`、`themes/install.ts`、`electron/vscode-marketplace.ts`
- 桌面窗口与内容交互：`components/pane-shell/tree/store.ts`、`electron/window-state.ts`、`components/chat/zoomable-image.tsx`
- TUI：`ui-tui/src/app.tsx`、`ui-tui/src/app/overlayStore.ts`、`ui-tui/src/app/useInputHandlers.ts`、`ui-tui/src/theme.ts`
- Web：`web/src/main.tsx`、`App.tsx`、`themes/context.tsx`、`themes/types.ts`、`themes/presets.ts`、`pages/FilesPage.tsx`、`components/LanguageSwitcher.tsx`
- 主题协议（跨端）：`apps/shared/src/skin.ts`（`HermesSkin`/`SKIN_COLOR_TOKENS`）、`hermes_cli/skin_engine.py`（`resolve_skin`、`list_skins`、`load_skin`）、`hermes_cli/skin_cmd.py`、`tui_gateway/server.py`（`skin.changed` 广播）、`hermes_cli/web_server.py`（dashboard-themes 扫描）
