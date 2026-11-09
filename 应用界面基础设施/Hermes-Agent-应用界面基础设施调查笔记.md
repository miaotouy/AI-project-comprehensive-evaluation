# Hermes Agent 应用界面基础设施调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
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

桌面前端在快照之间大幅扩张：

- `apps/desktop/src/app/` 下新增 `agents`、`learning`、`command-center`、`capabilities`、`gateway`、`messaging`、`profiles`、`cron`、`quick-entry`、`overlays`、`pet-overlay`/`pet-generate`、`master-detail` 等表面；
- `apps/desktop/src/plugins/`、`sdk/`、`i18n/`、`debug/` 升为独立目录；
- 根装配仍由 contrib 注册表驱动（`app/contrib/`、`contrib/registry.ts`），核心与插件走同一套注册 API；
- 仓库一级新增 `apps/bootstrap-installer`（MSIX/安装器方向）与顶层 `pm/` 包管理器。

TUI 仍为 Ink fork，Web dashboard 仍是 REST + PTY。

**桌面端根装配。** Provider 的顺序依次是错误边界、查询、国际化、主题、触觉反馈、全局 Tooltip 和路由。TooltipProvider 在全应用只挂一个实例，用来避免拖动分栏时重复渲染；路由那一层不启用 transition，用来防止流式令牌更新长期挤压导航提交。（`apps/desktop/src/main.tsx:53-85`）

多窗口入口靠 URL 参数 win 分流（`main.tsx:30,40-52`）：hud、overlay、quick、wake 各挂一个独立根（HUD 是完整 renderer，见 Chat UI 笔记 §1），其余都走主装配。渲染之前会先装好模块级副作用：剪贴板 IPC shim（`lib/clipboard.ts`），以及 active-work、power、translucency 等 store。

应用根是贡献注册表驱动的 ContribController（`app/contrib/controller.tsx:697-786`）。它用 SidebarProvider 包住 ContribWiring，里面依次是固定 34px 高的标题栏（left/center/right 三个 slot，拖拽区和控件区分开）、pane 树的 LayoutTreeRoot（见下）、SessionTileCloseConfirm 和状态栏；状态栏没有挂载时，这一整条直接 unmount（:781）。

pane、布局预设、快捷键、命令面板条目全部经 ContributionRegistry 注册（`contrib/registry.ts`）。注册表按 area 分桶，带快照缓存和区域级失效：改一个状态栏条目，标题栏 slot 不会跟着重渲染。核心界面和插件用的是同一套注册 API，`discoverBundledPlugins` 在核心之后加载，同名贡献由后者覆盖前者（`controller.tsx:395-402`）。

界面里有四个 wired surface（sidebar、chatRoutes、terminal、statusbar，见 `app/contrib/surfaces.tsx`），它们各自 memo 化、各自订阅自己那份 atom；对外动作统一收进一份身份稳定的 actions ref（`wiring.tsx:861-924`），任何 pane 的内容级更新都不经过控制器。

**TUI 根装配**（`ui-tui/src/entry.tsx`）：启动时先调 `resetTerminalModes`，把上一次会话残留的 DEC 鼠标、粘贴模式清掉；GatewayClient 走 stdio；内存监视与优雅退出链在 EIO/EPIPE 连续出现 5 次时退出（:80-88）；最后由 `ink.render` 挂载 App，关掉 Ctrl+C 退出，打开超链接点击。

App（`app.tsx:9-25`）只有两层：GatewayProvider 套 AppLayout。AppLayout 再往下组装状态栏（上下两条 StatusRulePane）、FloatingOverlays、PromptZone、两侧 AmbientRail、底部 AmbientDock 和 ActiveWidgetSlot（`appLayout.tsx:366, 448, 538-582`）。

**Web 根装配**（`web/src/main.tsx`）：BrowserRouter → I18nProvider → ThemeProvider → SystemActionsProvider → App。

App（`web/src/App.tsx:371-823`）内部套着 ProfileProvider，侧栏同时支持移动抽屉和桌面折叠两种状态；路由表包在 Suspense 里，RouteFallback 由 Spinner 加一行文本组成；插件 tab 和路由经 `buildRoutes` 合并，`tab.override` 能把内置路由整页替换掉。`/chat` 是一个常驻的 xterm host：首次访问后就一直挂着，离开 chat 路由时用 display:none 保活（`App.tsx:406-409, 790-811`）。

## 1. 界面栈、公共组件与状态所有权

**桌面端**：公共组件集中在 `src/components/ui/`，共 75 个文件，覆盖弹窗、浮层、菜单、按钮、提示、空态、骨架屏和加载器等。它们全部基于 radix-ui（合并包 1.6.7）封装，样式用 Tailwind v4 的 token 类。

另有少量地方局部用到 `motion/react`（`components/ui/diff-count.tsx:1`、`app/right-sidebar/review/file-tree.tsx:3` 的 AnimatePresence）和 cmdk（用于命令面板）。

桌面这边，`@nous-research/ui` 只提供字体资源（`styles.css:40`）和像素风图案（`components/chat/vibe-hearts.tsx:37`），界面组件没有取自它——依赖清单里列了这个包，组件层并未接入。会话列表排序用 @dnd-kit（见第 6 节），聊天正文的渲染栈（assistant-ui、shiki 等）归消息渲染器类目。

**状态所有权**（桌面）：遵从 `apps/desktop/AGENTS.md` 里“按权威放状态”的契约。后端说了算的数据走 react-query 缓存，再投影到 store（聊天主链见 Chat UI 笔记 §8）；Electron 说了算的机器事实走 window.hermesDesktop 这层窄桥。

渲染层自己持有的是“纯本窗口呈现”状态：`store/` 下 151 个 nanostores atom，覆盖布局、侧栏、主题、输入框、通知、窗口等。持久化偏好按“作用域自声明”原则存进 localStorage，比如主题按 profile 分键、侧栏视图状态、预览标签。

命令式 UI 状态——弹窗开合、toast、调色板开关——都放在模块级 atom 上（`$commandPaletteOpen`、`$notifications`、`$sessionPickerOpen`），不经 React context。命令入口和渲染视图读的是同一个 store。

**TUI**：`$uiState`、`$overlayState`、`$uiSessionId` 等都是模块级 atom（`app/uiStore.ts:41`、`app/overlayStore.ts:27`）；浮层状态全部落在 `$overlayState` 这一个 atom 的字段上（见第 2 节）。

**Web**：主题、Profile 和 SystemActions 走 context（`web/src/themes/context.tsx`、`contexts/ProfileProvider.tsx`）；服务端数据走 `lib/api` 的 fetch 封装。

## 2. 弹窗、浮层与菜单

### 桌面端：Radix Dialog 封装 + 弹窗内 Popover 改投 + 覆盖层视图

- **Dialog**（`components/ui/dialog.tsx`）：直接包 radix-ui Dialog。

  Overlay 层级 z-(--z-modal-backdrop)（120）、Content z-(--z-modal)（130），开合动画是 Tailwind `data-[state=open|closed]` 类（fade + zoom，200ms），滚动在内容内层 box 上（`max-h-[85vh]`）。

  Esc 关闭、点遮罩关闭和焦点陷阱都交给 Radix 的默认行为——代码没有覆盖 onEscapeKeyDown 和 onInteractOutside（依赖内部行为未下钻，见未验证事项）。它另外留了 `preventCloseButtonAutoFocus` 这个转义口子（`dialog.tsx:59-61`）：没有输入框的对话框可以借此压住“首焦落在关闭按钮”引起的 tooltip 闪现。

  横幅变体 banner（error/warn/info 三色调，底部贴边，`dialog.tsx:125-170`）。
- **弹窗内 Popover 改投**（`components/ui/dialog-portal-context.ts`）：Radix 的 Select、Popover、DropdownMenu 默认把浮层 portal 到 document.body，浮层于是成了 Dialog 的 DOM 兄弟。这样一来，在弹窗内点下拉时，DismissableLayer 会把弹窗内的交互判成“outside”，整个弹窗跟着被误关；跨 body 兄弟比较 z-index 也没有稳定的控制点。

  DialogContent 把自身的 content 节点发布进 context（`dialog.tsx:100,146,192`），下面三个浮层组件便把自己的 Portal container 换成弹窗节点：
  - `popover.tsx:33-36`
  - `select.tsx:50-53`
  - `dropdown-menu.tsx:79-82`

  浮层成为弹窗真子节点后，焦点不出弹窗，层级共享弹窗 stacking context。
- **ConfirmDialog**（`components/ui/confirm-dialog.tsx`）：共享的确认弹窗。Enter 或 Space 在弹窗任意位置都能触发确认（onKeyDown，:99-106）；内部自带 pending→done→close 的节拍，done 之后 600ms 自动关闭。错误以内联形式出现，throw 后弹窗保持打开；它还提供 dismissOnConfirm 乐观模式。
- **覆盖层视图**（settings/command-center/agents/cron/profiles/webhooks/starmap）：挂在 ContribWiring 尾部、由 hash 路由驱动的全尺寸视图（`wiring.tsx:1057-1119`，懒加载 Suspense），渲染路径独立于 Modal 组件；关闭时回跳被覆盖前的路由（`use-overlay-routing.ts:33-59` 的 returnPathRef）。
- **命令面板 ⌘K**（`app/command-palette/index.tsx`）：Radix Dialog 加一层透明 overlay（没有遮罩变暗，但保留 click-away 与焦点陷阱，:1270-1272），里面嵌 cmdk。搜索排序是自研的（scoreItem/rankGroups，:180-241），cmdk 只承担键盘与选择机制，配 `shouldFilter={false}`；

  命令面板支持嵌套子页，Esc 或输入为空时逐级回退（:1315-1323）。关闭动画靠 content 的 animationend 事件驱动卸载，`EXIT_FALLBACK_MS=1000` 只作兜底（:254,1284-1288）；行列表在打开后的第二帧才渲染（useDeferredValue，:280-283）。

**window 级 Esc 协商。** 窄屏侧栏揭示、布局编辑、zone 编辑器、覆盖层、拖拽等多处都挂了 window keydown 处理器；它们经 `escape-layers.ts:6-15` 的 pushEscapeLayer/isTopEscapeLayer 按优先级（10-50）串行化，一次 Esc 只命中最上层。Radix 弹窗因为 stopPropagation，天然排在契约最上面。
- 右键/上下文菜单：`components/ui/context-menu.tsx`（Radix ContextMenu 封装，子菜单额外 portal 出父 Content 防 overflow 裁剪，:140-165）；业务侧消息/会话行等消费点在 Chat UI 与消息渲染器笔记。

### TUI：单一 overlayStore + 三种形态

`$overlayState` 一个 atom 管全部浮层（`app/overlayStore.ts:27`），按形态分三类（`appOverlays.tsx`）：

1. **flow 提示**（approval、billing、subscription、confirm、clarify、sudo、secret，PromptZone，:58-163）：渲染在正常文档流里，位于 ComposerPane 上方（`appLayout.tsx:553-568`），效果是**推挤**下方内容，而非盖在它上面。Esc、数字键、Enter 各有绑定；ApprovalPrompt 用纯函数做键分发，Esc 对应 deny（`components/prompts.tsx:52-81`）。
2. **浮层面板**（sessions、modelPicker、petPicker、skillsHub、pluginsHub、pager、completions，FloatingOverlays，:165-384）：用 `position="absolute" bottom="100%"` 从 Composer 顶部向上长出来（:380-383），外面包 FloatBox 边框；completions 列表是固定 16 行、居中的视口（COMPLETION_WINDOW，:203-205）。
3. **widget 模态**（SDK 应用，ActiveWidgetSlot，`sdk/host.tsx:209-214`）：渲染在视图层，可以锚定九宫格 zone，并带一层伪 scrim（`components/overlay.tsx:31-66`）；scrim 由逐行空格加背景色拼成，注释说它沿用 lipgloss 的经典做法。Dialog 在这里是圆边框卡片原语（:76-105）。模态打开期间独占键盘（`useInputHandlers.ts:440-442`）。
另有 AmbientDock/AmbientRail 这类驻留在文档流里的卡片：dock 行占真实行高，rail 的列宽从转录宽度预算里扣（`sdk/host.tsx:219-286`）。浮层的关闭语义由 `resetFlowOverlays` 定：每轮结束只清 flow 这一类，用户主动打开的（agents、modelPicker、skillsHub 等）继续留在界面上（`overlayStore.ts:150-163`）。

### Web：`@nous-research/ui` 组件库

ConfirmDialog（重启/更新确认，:1068-1095）和 useToast（见第 3 节）来自 `@nous-research/ui`（`web/src/App.tsx:63` 等）。OAuth 登录模态是项目自绘的（`components/OAuthLoginModal.tsx`，点遮罩关闭 :160）；

主题和语言切换器在窄屏下改用底部 sheet 形态，portal 到 body（`components/LanguageSwitcher.tsx:26-31` 注释、`components/ThemeSwitcher.tsx:22-27` 注释）。该库内部怎么处理焦点陷阱、Esc 和层级，本次未下钻。

## 3. 通知、加载态与错误反馈

### Toast（桌面，自研 store，非 sonner/react-hot-toast）

- **store**（`store/notifications.ts`）：模块级 `$notifications` atom。`notify()` 按 id 幂等替换，同 id 的新 toast 会顶掉旧的（:176），栈最多 4 条。时长上，`error/warning` 默认为 0，也就是不自动消失，其余 5s（defaultDuration，:52-58）；

  位置默认 `error/warning` 或带 action 的走顶部居中、其余右下（defaultPlacement，:67-73）。

  `notifyError` 带一张错误摘要规则表（ERROR_SUMMARIES，:91-133），磁盘满、网关鉴权失败、OpenAI API key 被拒（带状态码）、ElevenLabs 或麦克风权限等常见错误都能命中；超过 180 字符的错误会折叠成 fallback，细节收进可展开的 detail。
- **渲染**（`components/notifications.tsx`）：两个栈都 portal 到 body——TopCenterStack（`role="region"`，最新一条常显，可展开“+N more”，带 clear-all，:104-141）和 BottomRightStack（全部平铺，:145-164）。

  单条的 role 和 aria-live 按 kind 定：error 用 alert/assertive，其余用 status/polite（:205-207）。detail 用 `<details>` 折叠，旁边配复制按钮；成功、错误、警告分别触发对应的 haptic（:71-77）。代码注释解释了为什么要 portal 到 body：React 根子树里的 toast 会被 body 级弹窗遮罩盖住（:99-103）。
- **后端通知接入**（`store/agent-notices.ts`）：后端发来的 notification.show 负载会映射成 toast。这条链路是 Python 端 `agent/credits_tracker.py` 产生 AgentNotice，经 `tui_gateway/server.py` 转发到前端；映射规则逐条如下：
  - 剥离前导严重级字形（CLI/TUI 用字形表达级别，桌面 toast 已有图标，stripGlyph，:39-44）；
  - 用 · 分隔主文本与 meta；
  - key 兼作 toast id，同 key 重复发射原地替换（额度 50→75→90 逐级原地升级，:107-109）；
  - 额度用量按 75%/90% 门槛变色（noticeAccent，:74-98）。

  notification.clear 按 key 关闭；原生 OS 通知只放行 credits.depleted/credits.restored 两种（:180-206）。
- **原生系统通知**（`store/native-notifications.ts`）：这是一条与 in-app toast 分开的独立通道。7 类 kind 各有独立开关（approval、input、turnDone、turnError、backgroundDone、credits、plugin），发送前按 1s 节流去重（:94-111）。默认只在“后台”——document.hidden 或窗口失焦——时发送；approval 和 input 归在 ATTENTION_KINDS 里，前台也会发（:26, 116-120）。

### TUI 通知

后端发来的 notification.show 在 TUI 里变成状态栏上的一条 notice（`components/appChrome.tsx:478-660`）。busy 时由 FaceTicker 占位，空闲时 notice 文本替换状态槽（判断式是 `showNotice = !busy && !!notice?.text`，:516），颜色按 level 取（noticeColor，:237），长文本收缩省略。TUI 里没有 toast 这种形态，终端表面不存在浮动通知。

### 加载 / 空状态 / 错误边界

**桌面。** Loader 是自研的 SVG 数学曲线粒子，内置 21 种曲线，用 rAF 驱动（`components/ui/loader.tsx`）。PageLoader、Skeleton、EmptyState（`components/ui/empty-state.tsx`，标题加描述居中，图标加动作的版本是 overlays/panel 用的 PanelEmpty）和 ErrorState 都是公共原语。

聊天列表的加载/空状态与渲染预算（RENDER_BUDGET、content-visibility）见 Chat UI 与消息渲染器笔记，不重复。
- **错误边界**（`components/error-boundary.tsx`）：一个 class 组件。根级 RootErrorBoundary（`label="root"`）的 fallback 是固定全屏、z-(--z-crash)(1500) 的 ErrorState，提供重试、重载窗口和打开日志三个动作（:142-163）；

  componentDidCatch 把组件栈上报给主进程，写进 desktop.log（window.hermesDesktop.reportRendererError，:60-66）；根级对特定的 assistant-ui 查找越界错误会自动恢复，上限 3 次、窗口 5s（:26-30, 73-78）。

  贡献系统另有一道 ContribBoundary（`contrib/react/boundary.tsx`）：每个插件的 render 都包一层，崩溃只降级成该 slot 内的小型错误（chip 变体），或者 pane 内的 ErrorState（pane 变体），影响范围止于该 slot。

**TUI。** 加载原语是一个共享的 shimmer 时钟，90ms 一跳，按订阅计数启停，跑满 30s 动画预算后冻结（`components/loaders.tsx:62-126`）。widget 崩溃时由 WidgetBoundary 降级成一行 `⚠ /<appId>: …`（`sdk/host.tsx:150-166`）。

**Web。** 路由级回退是 RouteFallback（Spinner 加文案，`App.tsx:110-123`）；加载和错误的语义跟随 `@nous-research/ui`。

## 4. 主题、视觉 token 与持久化

三端共用同一套后端皮肤协议。YAML 放在 `~/.hermes/skins/*.yaml`；Python 端由 `hermes_cli/skin_engine.py` 解析并提供 resolve_skin，TS 端的契约类型在 `apps/shared/src/skin.ts`——那里的 SKIN_COLOR_TOKENS 有 30 多个语义 token，终端口在前，GUI 只从少数 load-bearing 颜色派生。

皮肤变更经 `tui_gateway/server.py` 的 skin.changed 广播出去。三端的权威源和持久化各不相同，共同做法是先定少量种子色，再派生全部次级 token：

- **桌面**（`themes/context.tsx`）：主题名（skin）和明暗模式（mode）都按 **profile 分键**存进 localStorage（PROFILE_SKINS_KEY、PROFILE_MODES_KEY；没分配 profile 时回退到全局旧键 hermes-desktop-theme-v2，:29-37, 58-67）。`system` 模式靠 matchMedia('(prefers-color-scheme: dark)') 即时解析（resolveMode，:44-45）。

  模块一加载，就按“上次活跃 profile”预应用主题（:274-281）；同时把背景色和色系写进 hermes-boot-background、hermes-boot-color-scheme 两个 localStorage 键，index.html 的内联脚本在 React 挂载前就能给首帧上色（:243-252），两层合起来防首帧闪烁。跨窗口同步靠 storage 事件（:361-376）。

  应用主题时，把 seed 色写进 `--theme-*` 行内变量，`styles.css` 再用 `color-mix()` 派生 `--ui-*` 语义层，另留一组 `--dt-*` 直通 shadcn token（:198-234）。data-hermes-theme、data-hermes-mode、`.dark` class 与 color-scheme 保持同步（:192-195）；

  renderedMode 反向从背景亮度推算，免得出现“暗色主题配亮背景”的误判（:148-158）。字体通过动态 `<link>` 注入，注入前会去重（:254-261）。原生窗口的外观另有引脚：setNativeTheme 把 Electron 的 nativeTheme 固定到应用模式，标题栏和模糊材质跟着走（:268-269）。

  **后端皮肤同步**（`themes/backend-sync.ts`）：gateway.ready 只播种、不直接应用，免得新建立的连接盖掉用户已经持久化的选择；只有 skin.changed 或皮肤名变化才经 `$pendingSkinApply` 应用（:80-93）。`/skin` 命令与后端激活共用这条路径。

  **主题市场与用户主题**：VS Code Marketplace 在这里是一个完整子系统，入口有两个。一个是 Cmd-K 的 “Install theme…” 页（`app/command-palette/marketplace-theme-page.tsx`），空查询时显示热榜，搜索带 300ms 防抖、staleTime 5min；已安装的主题只重新激活、不重新下载，装完页面保持打开，可以接着装下一个。另一个是外观设置页的搜索行（`app/settings/appearance-settings.tsx:96-140`），走同一条管线，行内还有按当前 mode 渲染的 ThemePreview 卡片和 UI 缩放预设 UI_SCALE_PRESETS。

  下载发生在 Electron 主进程（`electron/vscode-marketplace.ts:1-22`）：先调 Gallery 的 ExtensionQuery API 解析最新版本，再拉 VSIX（40MB 上限、最多 5 次跳转、20s 超时）。解析靠手写的 central-directory 实现加 zlib inflate，没有引入 zip 依赖；打开包之后只读 `package.json` 和主题 JSON，主题代码不执行。

  转换放在渲染进程（`themes/vscode.ts:1-25`）。几百个 workbench key 里只挑约 6 个 load-bearing 的（background、foreground、accent、elevated surface、sidebar、error），其余全部由 color-mix 派生；accent 另外设了 WCAG AA 4.5:1 的对比度护栏（ACCENT_MIN_CONTRAST），免得侧栏出现“隐形紫标签”。

  `themes/install.ts:19-70` 同时支持粘贴 JSON 导入和市场下载。明暗两个变体会合并成一个主题族：light 进 colors，dark 进 darkColors，terminal 的 ANSI 色走同一条轨道。

  安装结果写进**用户主题注册表**（`themes/user-themes.ts:21-140`，localStorage 键 hermes-desktop-user-themes-v1）。这张表与内置主题合并成统一注册表，供 Cmd-K、设置页和 `/skin` 消费；内置名不能被覆盖。`$marketplaceInstalls` 按 description 里“VS Code · publisher.extension”的约定跟踪已装扩展，而 localStorage 持久化让首帧 paint 时就能同步解析出用户主题。

  **accent 派生护栏**：皮肤转桌面模型这一步（`themes/skin.ts:65-104`）只认 accent 等少数种子，回退顺序是 ui_accent → banner_accent → banner_title → mix；primary、ring、midground、composerRing 全部由 accent 驱动；

  `styles.css:165-169, 255-289` 定义了 `--theme-fill-{primary..quinary}-accent-mix` 五级填充（3%~16%），再配合 row-hover/active 的 mix 阶梯，把单一 accent 摊成整套 `--ui-bg-*` 表面；`DESIGN.md:100` 的 token 表把这一契约归纳了出来。
- **TUI**（`theme.ts` + `lib/themeBoot.ts`）：亮/暗检测走一条有序的 env 链——先看 HERMES_TUI_LIGHT，依次退到 HERMES_TUI_THEME、HERMES_TUI_BACKGROUND 的亮度、COLORFGBG，最后看 TERM_PROGRAM 白名单（detectLightMode，:702-762）；

  `fromSkin()` 把后端皮肤转成 ThemeSeeds，次级色调一律由 mix 阶梯派生（deriveTones；代码注释点明这是桌面 color-mix 体系的终端版，:556-568）。它还会针对真实终端背景做对比度护栏（display 1.45、semantic 2.2，亮端更低，:472-475），并处理填充极性回退（:528-538）；

  Apple Terminal 有限色板路径把前景归一化为 ansi256（:764-791）。

  **首帧防闪烁**：上次解析出的主题会写进 `$HERMES_HOME/tui-theme-boot.json`（防抖 400ms 的原子写，`themeBoot.ts:96-121`）。启动时把它回放成第一帧（`$uiState` 初始值就是 bootTheme，`app/uiStore.ts:37`），同时回种 env，让首次皮肤解析的结果与上次一致（seedBootEnvironment，:148-179）。

  TUI 的显示密度由 `/density [on|off|toggle]` 命令控制（`app/slash/commands/core.ts:285-300`）：它写 `$uiState.compact`，再用 config.set density 持久化。这是紧凑布局的开关，与皮肤和主题 token 无关。
- **Web**（`web/src/themes/context.tsx`）：**服务端是权威源**（`api.getThemes()` 和 `setTheme`，内建主题加用户 YAML，:474-517；用户主题来自 `~/.hermes/dashboard-themes/*.yaml`，后端扫描在 `hermes_cli/web_server.py:16704-16735`）。localStorage 只承担首帧防闪烁缓存（STORAGE_KEY，:34-35, 411-423），旧主题名由 migrateThemeName 迁移；

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

  主题 YAML 分为 palette、typography 和 layout 三层。字体层管正文、等宽和展示字体以及排版参数；布局层管圆角和 compact、comfortable、spacious 三档密度，再映射成 CSS 变量。（`themes/types.ts:4-19`）

  扩展层另有三种布局变体、18 个颜色覆盖口、命名视觉资产槽和主题选择器的 swatch。资产槽覆盖背景、横幅、Logo、徽章、侧栏和标题栏，名单与后端保持一致。（`themes/context.tsx:114-227,282,390`）
- **本次未找到**（壁纸设置器与独立强调色选择器）：桌面/TUI 内 grep wallpaper/backgroundImage/backgroundOpacity 零匹配，桌面背景是纯色 token（无壁纸机制）；

  Web 的整幅背景图只能由主题 YAML 的 assets.bg 提供（`--theme-asset-bg`，注释指明供 backdrop 插件槽或主题 customCSS 消费，`types.ts:83-85`），无独立壁纸设置 UI；

  grep primaryColor 三端零匹配，强调色只能随皮肤/预设/市场导入主题变化，三端都没有用户直接选主色的 UI（TUI deriveTones 与桌面 `--ui-accent` 的 mix 体系见上文）。

## 5. 响应式、移动端与窗口适配

**桌面断点。** 桌面只有一个断点：`SIDEBAR_COLLAPSE_BREAKPOINT_PX = 768`（`app/layout-constants.ts:24-25`），`$narrowViewport` 由 matchMedia 驱动（`components/pane-shell/tree/store.ts:977-981`）。

窄视口下，可折叠的边栏（sessions、files、review）会**离开网格**，改成贴边的覆盖层：鼠标移到边条上揭示，⌘B/⌘G 可以钉住揭示，Esc 关闭（`narrow-overlays.tsx:103-147`）。宽度取 pane 声明宽度和 85vw 中较小的那个。

pane 树本身是一套重量级的可拖拽布局，支持 split/group 权重和 Default、Focus、Terminal deck、Quad 四种预设（`controller.tsx:342-391`）；会话选项卡能拖出来变成独立 pane。
- **窗口最小尺寸**（Electron）：
  - 主窗：`MIN_WIDTH=400`（`electron/window-state.ts:14`，默认 1220×? 记忆化恢复）
  - 独立会话窗：`SESSION_WINDOW_MIN_WIDTH=420` / `MIN_HEIGHT=620`（`electron/session-windows.ts:10-11`）
  - HUD 窗：minWidth 380（`electron/main.ts:9213`）

  768 断点只作用于 renderer 视口，窗口宽度本身不触发侧栏折叠。
- **多窗口**（`store/windows.ts` + `electron/main.ts`）：win 参数区分主窗、secondary（单会话、无侧栏）、hud、pet overlay、quick entry 和 wake；watch 参数开的是子代理旁观窗，支持懒恢复和 live-mirror。安装与引导 overlay 归主窗独占，判断由 `isAuxiliaryWindow()` 做（`windows.ts:79-84`）。

  跨窗口状态同步的通用机制是 localStorage storage 事件（主题、草稿、pin 等，见 Chat UI 笔记与第 4 节）。

**Web。** 侧栏有桌面折叠和移动抽屉两种状态，前者是 collapsed、存在 localStorage 的 hermes-sidebar-collapsed 里，后者是 mobileOpen。断点取 1024（useBelowBreakpoint(1024) 配 matchMedia("(min-width: 1024px)")，`App.tsx:395, 502-509`）。移动抽屉打开时锁住 body 滚动，Esc 可关闭（:488-500）；

移动端没有单独的入口或路由树，内容区 gutter 用 clamp(1.25rem,4vw,4rem)（`App.tsx:751`）。

**TUI。** TUI 里没有断点概念，起作用的是另一套等价物：WidgetGrid 的列数和 AmbientRail 的宽度预算（转录宽度等于总列宽减去 rail 宽，`appLayout.tsx:146`），浮层面板的 maxWidth 按当前列数算（`appOverlays.tsx:380-383`），completions 视口固定 16 行。

## 6. 图片、附件、拖放与常见内容交互

- **图片灯箱**（桌面，`components/chat/zoomable-image.tsx`）：消息里的图片按钮是 ZoomableImage，点开后是 ImageLightbox——一个无边框 Dialog（border-0 bg-transparent）。点图片本身即可关闭（:90），右上角悬浮下载按钮，保存期间按钮 pulse（useImageDownload）；

  灯箱只做查看与下载，没有缩放、旋转和多图导航，能力面比 Cherry Studio 的灯箱小。

  消费点分布在消息 markdown 图片、指令文本、工具输出图、生成的图片结果和 composer 附件上（测试里断言“附件图走灯箱，不进预览 rail”）：
  - `components/assistant-ui/markdown-text.tsx:389`
  - `directive-text.tsx:370,433`
  - `tool/fallback.tsx:611`
  - `app/chat/composer/attachments.tsx:156-164`
- **预览 rail**（桌面，`store/preview.ts`）：右侧的标签页列表，目标分文件、URL、artifact 三类，`previewKind` 取 binary/html/image/pdf/text 之一。标签会持久化（hermes.desktop.previewTabs.v2，:63）；dataUrl 目标只存在内存里，不落盘（:27-28）。这就是“查看文件”的主通道，与图片灯箱分工并存：附件图走灯箱，文件图走 rail。

**拖放。** composer 的文件拖入由 useFileDropZone 和 partitionDroppedFiles 处理：应用内路径走 @file: ref，OS 文件进附件管线，目录走 @folder:，图片转成 base64 缩略图。细节已在 Chat UI 笔记 §3 记录，这里不再重复；统一视觉是 DROP_SHEET_CLASS 那条虚线 sheet（`components/ui/drop-affordance.tsx`）。

会话和项目排序用 @dnd-kit：`app/chat/sidebar/reorderable-list.tsx:51-60` 自带 DndContext，`profile-switcher.tsx` 和虚拟列表也用 useSortable。pane 树的拖拽则是自研的 drag-session。TUI 和 Web 都没有聊天拖放；Web 的 FilesPage 另有上传拖放，见下一段。
- **剪贴板**（桌面，`lib/clipboard.ts`）：模块加载时把 navigator.clipboard.writeText 换成经 Electron IPC 的主进程写入。窗口失焦时 Web Clipboard API 会抛 “Write permission denied”，走 IPC 则不受焦点状态影响；IPC 写入失败再回退到原生 API（`main.tsx:30` 安装）。Web 端没有这层 shim。

**Web 上传。** FilesPage 同时提供拖放上传和文件选择按钮。拖放用 dragDepth 计数，`dropEffect="copy"`，拖入时高亮，上传中显示 Spinner 并给 toast 反馈（`web/src/pages/FilesPage.tsx:82-98, 191-235, 336-347`）；上传本身走 api.uploadFile。

## 7. 扩展调查：桌面集成与浮层渲染细节

（属于可选扩展；仅记录公共设施，具体业务通知/快捷键的触发语义见各业务类目与 Chat UI 笔记。）

**HUD 与辅助窗口。** HUD 是一个完整的 renderer，并非傀儡窗；它的快照快捷键和窗口位置记忆（`hud-state.json`）记在 Chat UI 笔记 §1/§8。pet overlay、quick entry 和 wake indicator 是各自独立的最小根（`main.tsx:46-51`）。

**快捷键。** `store/keybinds.ts` 是一张可重绑定的 action 注册表（由 KEYBINDS_AREA 贡献）。TipKeybindLabel 从注册表读标签和组合键，自动渲染成 tooltip 提示（`components/ui/tooltip.tsx:216-223`）；快捷键面板则通过自定义事件 hermes:open-keybinds 打开设置页（`wiring.tsx:293-298`）。
- **浮层层级变量**（`styles.css:222-236`）：
  - `--z-modal-backdrop`：120
  - `--z-modal`：130
  - `--z-modal-popover`：140
  - `--z-over-modal`：200
  - `--z-over-modal-content`：210
  - `--z-crash`：1500

  Toast 与命令面板在 over-modal 层。

**动画。** 桌面的开合动画全走 Tailwind 的 data-state 类，不用 JS 补间；`motion/react` 只有两处局部（diff 计数、文件树折叠）；Loader 是 rAF 驱动的自研曲线。TUI 的动画落在终端字符粒度上，比如 shimmer 扫过和 FaceTicker 的表情帧。

## 8. 设计取舍与已确认边界

**贡献注册表是应用壳的唯一组织方式。** pane、标题栏、快捷键、命令面板、路由和主题全部走同一套 area 注册 API，核心与插件同权（`contrib/registry.ts`）；插件崩溃时由 ContribBoundary 按 slot 降级。

**弹窗内浮层改投弹窗节点。** Radix 默认把浮层 portal 到 body，进了嵌套场景会破坏焦点和 z-index；这里用 context 改投弹窗节点来解决（`dialog-portal-context.ts:5-19` 的注释完整记下了两种失效模式）。

**Toast 双栈 + 后端 notice 映射。** 重要反馈（error、warning、带 action 的）走一个栈，例行确认走右下角的栈。后端 notice 的 key 同时充当 toast id，同一 key 再发就原地升级；CLI/TUI 文本开头的严重级字形在桌面被剥掉（`agent-notices.ts`）。

**三端主题同为种子派生，权威源各不相同。** 三端都从种子派生 token：桌面是 `--theme-*` 到 `--ui-*` 的 color-mix，TUI 走 mix 阶梯，Web 做 palette 分层。权威源分别是 localStorage（按 profile）、启动缓存加 env、服务端 API。后端皮肤在桌面只做播种、不覆盖用户选择，在 TUI 则是每次启动的解析输入。

**市场主题是种子注入器而非外观镜像。** VS Code 主题的几百个 workbench key 只取约 6 个当种子，其余全部由 color-mix 派生（`vscode.ts:4-9` 注释），与“少量种子 → 派生全部次级 token”的做法一致。accent 单独设 WCAG AA 4.5:1 护栏；单模式主题经“明暗双变体合并”，让桌面的明暗切换映射到真实变体（`install.ts:27-37` 注释）。

**用户主题与内置主题合并注册、零接线消费。** 桌面的 localStorage 用户主题注册表与内置主题合并后，供 Cmd-K、设置页和 `/skin` 统一消费，内置名不能被覆盖。Web 端用户主题以服务端 YAML 为权威（`~/.hermes/dashboard-themes/`），与皮肤的 `~/.hermes/skins/` 是两套并行的用户主题体系。

**聊天表面不共用界面代码。** 桌面、TUI、Web 是三套独立的装配。根 AGENTS.md 写明 dashboard 嵌的是 TUI，没有另写一份；桌面也不嵌 TUI。三端唯一共享的是 `apps/shared` 连接层，以及后端的皮肤与 notice 协议。

**错误文本规范化。** 桌面的 notifyError 会做摘要化处理，覆盖远程调用包装（“Error invoking remote method…”）、“detail” JSON，以及磁盘满、API key 等常见错误（`notifications.ts:91-153`）。

**边界。** 聊天主链——草稿、附件、流式、消息操作——记录在 Chat UI 笔记；消息内容渲染归消息渲染器类目；Python 核心与 UI 的交点只有皮肤 YAML 和 notification.show 协议。

### 当前连接与会话作用域

桌面基础设施继续把 connection、profile 和 session 分开建模。会话 API 的作用域统一由 `sessionScoped` 生成，读写走同一条 profile/connection 路由（`apps/desktop/src/api/sessions.ts:16-31`）；事件缓存也把这三个维度记下来（`apps/desktop/src/store/session-states.ts:80`）。远端连接、profile rail 和同 ID 会话并存因此有了状态边界；视觉与跨窗口交互仍未运行验证。

连接授权和浏览器秘密输入都采用“后端持有状态、前端只呈现请求”的模式。Connector operation 通过 server→client 请求驱动桌面卡片，授权 URL 不会进入模型结果；Vault 把登录信息、支付卡和地址存进 profile 作用域的加密库，模型只能看到 opaque handle 和非秘密元数据，真实字段由后端按 origin 填进浏览器（`apps/desktop/src/store/connection-request.ts:17-54,135-181`，`agent/vault_store.py:1-16,193-293`）。这两条输入面都把敏感值挡在通用弹窗状态和聊天转录之外。

语音控制同样收在 Composer 基础设施里。麦克风按钮用 fan menu 切换 STT、GPT-Live 会话和扬声器状态；全双工引擎的实时音频由独立 hook 管，实际任务仍然提交给当前 Hermes 会话（`apps/desktop/src/app/chat/composer/hooks/use-composer-voice.ts`，`use-voice-live-conversation.ts`，`voice-engine-rows.tsx`）。

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
- Connector 授权弹窗、Vault 自动填充与 GPT-Live 的真实平台权限、焦点和失败恢复未运行验证。
- 本轮按路径复核了装配入口、contrib 注册表与公共组件的归位，未新增对 `agents`/`learning`/`pet-*`/`command-center` 等新表面的界面调查；这些表面只确认存在，未展开交互与状态所有权。

## 10. 关键源码索引

- 桌面根：`apps/desktop/src/main.tsx`、`app/contrib/controller.tsx`、`app/contrib/wiring.tsx`、`app/contrib/surfaces.tsx`、`contrib/registry.ts`、`contrib/react/boundary.tsx`
- 桌面浮层/菜单：`components/ui/dialog.tsx`、`components/ui/dialog-portal-context.ts`、`components/ui/confirm-dialog.tsx`、`components/ui/context-menu.tsx`、`components/ui/sheet.tsx`、`components/ui/tooltip.tsx`、`app/command-palette/index.tsx`、`lib/escape-layers.ts`、`app/shell/hooks/use-overlay-routing.ts`
- 桌面通知/反馈：`store/notifications.ts`、`components/notifications.tsx`、`store/agent-notices.ts`、`store/native-notifications.ts`、`components/error-boundary.tsx`、`components/ui/loader.tsx`、`components/ui/empty-state.tsx`、`components/page-loader.tsx`
- 敏感输入与连接状态：`store/connection-request.ts`、`components/assistant-ui/connector-tool.tsx`、`agent/vault_store.py`、`tools/browser_vault_tool.py`
- 语音控制：`app/chat/composer/hooks/use-composer-voice.ts`、`use-voice-live-conversation.ts`、`voice-engine-rows.tsx`、`apps/desktop/src/lib/voice-live.ts`
- 桌面主题：`themes/context.tsx`、`themes/backend-sync.ts`、`themes/install.ts`、`electron/vscode-marketplace.ts`
- 桌面窗口与内容交互：`components/pane-shell/tree/store.ts`、`electron/window-state.ts`、`components/chat/zoomable-image.tsx`
- TUI：`ui-tui/src/app.tsx`、`ui-tui/src/app/overlayStore.ts`、`ui-tui/src/app/useInputHandlers.ts`、`ui-tui/src/theme.ts`
- Web：`web/src/main.tsx`、`App.tsx`、`themes/context.tsx`、`themes/types.ts`、`themes/presets.ts`、`pages/FilesPage.tsx`、`components/LanguageSwitcher.tsx`
- 主题协议（跨端）：`apps/shared/src/skin.ts`（`HermesSkin`/`SKIN_COLOR_TOKENS`）、`hermes_cli/skin_engine.py`（`resolve_skin`、`list_skins`、`load_skin`）、`hermes_cli/skin_cmd.py`、`tui_gateway/server.py`（`skin.changed` 广播）、`hermes_cli/web_server.py`（dashboard-themes 扫描）
