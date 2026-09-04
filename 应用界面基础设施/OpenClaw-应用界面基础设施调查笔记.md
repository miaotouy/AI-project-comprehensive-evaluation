# OpenClaw 应用界面基础设施调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态源码阅读。以 Control UI（`ui/`）为主干，沿入口装配、公共浮层/菜单/反馈/主题/响应式组件与其状态宿主逐层下钻；辅以 `src/tui` 与 `apps/` 的框架判断与平台边界确认。未运行构建、测试或 Gateway。
>
> 调查范围：应用级界面基础设施，含应用根装配、弹窗浮层与菜单、Toast 与加载/空态/错误反馈、主题 token 与持久化、响应式与多入口/多窗口、图片预览等公共内容交互、状态所有权。明确排除：产品结构与设计基因；原生 App（macOS/iOS/Android/Watch/Linux）各自界面的深度实现；Chat UI、消息渲染器、会话导航等业务表面（仅记录与公共机制的交点）；依赖库内部行为（Web Awesome、@uirouter、pi-tui 等仅以接线方式为界）。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的界面设施按“一个 Web 主表面 + 多种独立客户端”分布，真正共享的跨页面基础设施集中在 Control UI（`ui/`，Lit 3 + Web Awesome 组件库 + `@openclaw/uirouter`），它也是 Gateway 同版本捆绑派发的管理界面。应用根由单个 `<openclaw-app>` 元素装配：一个 Lit Context 装载 gateway、agents、theme、overlays 等十余个能力对象，再套一层 Tooltip Provider 与两个业务 Hovercard Provider，随后才渲染壳。同一份 HTML/资源既承载完整 Shell，也通过 URL 解析成 approval/question/terminal/desktop/dashboard 等“聚焦文档”，复用一个入口、跳过壳 chrome。

浮层体系是“Web Awesome 原生组件 + 薄适配层”的混合：Modal 用 `wa-dialog` 包一层 `openclaw-modal-dialog`（登记开放 Modal 层集合、统一焦点归还与 `modal-cancel` 事件）；菜单用 `wa-dropdown` 加每菜单控制器；Tooltip 是自管延迟/冗余抑制/`aria-describedby` 的 `openclaw-tooltip`；另有面向 body 的 Hovercard 定位控制器与把 `<details>` 菜单提升进 top layer 的 `openclaw-menu-surface`。Toast 不是堆叠队列，而是单个常驻宿主元素，必要时被移入当前打开 Modal 的顶层。主题是 8 个家族 ×（暗/亮）经 `data-theme`/`data-theme-mode` 发布，index.html 内联脚本在首帧前读 localStorage 预置背景与调色板，避免白屏闪烁；偏好按 gateway 来源域分桶存 localStorage，其中外观类字段走服务端 config `ui.prefs` 的无哈希 LWW 同步，跨窗口/跨设备收敛，其余偏好为设备本地。

状态所有权呈“三层”：纯设备外观与布局偏好归 localStorage 镜像；可同步偏好以服务端 `ui.prefs` 为权威、localStorage 为即时镜像与离线暂存；应用级注意型状态（执行审批队列、设备配对、更新运行/横幅）由常驻的 `overlays` 能力持有并从 gateway 事件与 operator 访问范围投影。原生 companions（macOS/iOS/Android/Watch/Wear、Linux Tauri 壳）各自是独立的客户端实现，仅与 Gateway 协议而非 Control UI 复用界面基础设施；TUI（`src/tui`）基于 `@earendil-works/pi-tui`，另有独立的主题与浮层处理。所有视觉、焦点与动画表现按静态调查边界记为未运行验证。

## 系统边界与总体装配

产品表面与界面栈：`ui/` 是主要 Web 表面（package.json 依赖 Lit、Web Awesome、`@lit/context`、CodeMirror、markdown-it、panzoom、xterm/novnc/ghostty 等），vite 构建且由 Gateway 同源派发（ui/AGENTS.md 规定 Control UI 与 Gateway 一个安装一个版本、不携带版本兼容分支）。`src/tui` 是终端 TUI，走 Gateway 协议或内嵌后端。`apps/` 下 macOS/iOS/Android/Linux 是原生或 Tauri 客户端，各自实现完整 Gateway 客户端（见“平台边界”）。

入口装配从 `ui/index.html` 的 `<openclaw-app>` 开始：`main.ts` 先注册 service worker（仅生产）、安装 stale-chunk 重载与丢样式表恢复，再把 `/src/app/app-host.ts` 与 `app-root.ts` 里的 `openclaw-app`/`openclaw-app-shell` 两个类定义拉入。`OpenClawApp` 构造 `ApplicationRuntime`（见 bootstrap），用 `ContextProvider` 把 `applicationContext` 提供给整棵子树，然后按连接阶段渲染四类画面之一：Gateway 未就绪时的 mascot 连接页、登录门、approval/question 聚焦文档，或带 Provider 与 Shell 的完整应用（`ui/src/app/app-root.ts:420-618`）。Provider 栈是嵌套顺序固定的一层工具提示 Provider 内包两个数据型 Hovercard Provider，再内包 `openclaw-app-shell`。

`bootstrapApplication` 负责一次性装配（`ui/src/app/bootstrap.ts:278-681`）：解析 basePath/资源路径与文档模式，从持久化设置恢复偏好并清理 URL 凭据，然后创建 gateway、agents、channels、config、sessions、workboard、runtimeConfig、overlays、navigation、theme、native 桥与 web push 等能力对象，最后按启动生命周期分步启动 gateway、模型初始化重定向与应用路由。能力对象都挂在 `ApplicationContext` 上，通过 `@lit/context` 向下注入，跨窗口并不存在共享的全局单例 store——每个文档（tab/聚焦窗口）实例化一套，状态经 Gateway 协议收敛。

路由是第三块公共基础设施：`@openclaw/uirouter` 路由表把数十个页面路由映射到懒加载 chunk（页面在 `ui/src/pages/` 按主题分目录），Shell 订阅路由状态以折叠 chrome、同步 document title，router outlet 在路由数据未就绪前以连接 splash 兜底。

## 弹窗、浮层与菜单

Modal 的公共底层只有一个适配器：`openclaw-modal-dialog` 把 Web Awesome 的 `wa-dialog`（原生 `showModal` top-layer 对话框）包成 `openclaw-*` 元素（`ui/src/components/modal-dialog.ts:17-356`）。它提供 label/description、`manual` 模式、按 class 切换 drawer/fullscreen/viewport-edge-to-edge/palette 等外形（含 nav-drawer 移动抽屉与移动端 edge-to-edge），并在断开时主动 `dialog.close()` 归还焦点。开放期间把自己登记进 `document.openClawModalLayers` 集合（8-15 行），关闭动画后移除；`wa-hide` 冒泡被转换为可取消的 `modal-cancel` 事件供业务层拦截（310-329 行）。自动聚焦 `[autofocus]` 目标、隐藏后归还 `returnFocus`，这些是适配器自带逻辑；wa-dialog 内部对 Esc/遮罩/焦点陷阱/top layer 的表现未下钻源码，按依赖库边界记为未核实。

命令式弹窗基于同一适配器：`confirm-dialog.ts` 用 Lit `render` 把 `openclaw-modal-dialog` 挂到一个临时 div，返回 Promise；提供“不再询问”跳过偏好、AbortSignal 与单飞互斥（`showConfirmDialog` 拒绝重入）。配对设备、懒加载失败等场景同样把 loading/失败态渲染进 `openclaw-modal-dialog` 内（`app-shell-view.ts:121-192`），保证分块加载失败时仍有一个带重试的对话框而不是空白。

菜单没有统一注册表，主路径是 Web Awesome `wa-dropdown` + 每处控制器的组合：`web-awesome.ts` 提供公共粘合（打开时给菜单 part 补 aria 标签、关闭动画后置 inert、跟踪键盘 Tab/Esc 导致的隐藏），`dropdown-menu-controller.ts` 是每菜单的 Lit controller（打开即聚焦首项，Esc 时把焦点还给持久触发器后关闭）。`menu-surface.ts` 会把宿主元素以 `popover=manual` 提升到浏览器 top layer 再渲染内容，让瞬态菜单盖过普通层叠上下文；不支持 Popover API 时回退到文档流内渲染。少量悬浮面板（如会话菜单展开的锚定浮层）用 `<details>` + `wa-popup` 的组合，由 `anchored-overlay.ts` 统一设置 placement/翻转/边界（`ui/src/components/anchored-overlay.ts:12-33`）。tooltip 详见下一节。hovercard（会话、GitHub 链接）是 body 级浮动卡片，见 `portaled-hovercard.ts`：控制器把 `role="dialog"` 的 div append 到 body，监听 resize/scroll/visualViewport 重定位，管理“指针停留/离开再定时关闭”的转移期；无 z-index 管理，靠 DOM 追加顺序。

## 通知、加载态与错误反馈

Toast 是单槽非堆叠的：`showToast` 寻找唯一的 `openclaw-toast-host`，若尚未挂载则暂存最新一条消息（`lib/toast.ts:35,193-218`）。宿主默认 6 秒自动消失，支持可选锚点元素（按其几何把 toast 定位到锚点顶部居中）、图标、动作按钮与关闭原因回调；关闭有淡出并在 `prefers-reduced-motion` 下直接移除。值得注意的机制是 Modal 联动：宿主平时挂在 `.shell` 内，一旦有 Modal 打开，`showToast` 就把宿主用 `moveBefore` 移进当前 Modal 的元素树，并在 `wa-after-hide` 后移回，使 toast 视觉上跟随 modal 顶层而非被遮挡。

应用级“注意型状态”由常驻 `overlays` 能力承担（`app/overlays.ts` 与 `overlays-types.ts`），状态而非弹窗机制是它的主体：执行审批队列、设备配对弹窗开合与生命周期、更新可用/计划/运行/横幅，全部从 gateway 事件与 operator 访问范围（能否审批、能否管理员）投影成快照，供 Shell、标题与通知消费。审批弹窗本身是懒加载的 `openclaw-exec-approval`，仅在队列非空且有显式打开请求时渲染 `openclaw-modal-dialog`，内部固定展示当前审批并列出其余待审项（`components/exec-approval.ts:93-150`）；文档标题上的 attention 计数与“生成结果待批准”的系统/推送通知是它的外呼通道。

加载与空态：连接/首路由阶段用 mascot + `role=status` 的 connect-splash（`app-root.ts:51-63`）；懒加载分块在途用同一 mascot（`loading-state.ts`），提供骨架屏 CSS 原语（`styles/base.css:1015-1037`）；公共空态组件 `openclaw-panel-empty-state` 承担面板无数据文案（标题/描述/动作槽）。错误反馈分层：分块加载失败渲染 `lazy-view-error` 的错误卡（区分过期 chunk 与一般失败，附重试与关闭，`components/lazy-view-error.ts:43-85`）；index.html 内置 12 秒未启动的 mount-fallback 静态错误页，含退避重试与 SW 清理；`stale-chunk-reload` 与 service worker 更新消息构成发布新版本时的刷新链路。业务页面的请求错误多就地渲染，属于各页自身实现。没有 React 式错误边界概念，页面模块加载失败由 router outlet / 懒加载控制器统一承接（`lazy-custom-element.ts` 的 `ensureCustomElementDefined` 校验元素确实注册，失败态带重试并支持已注册动作回放）。

## 主题、视觉 token 与持久化

token 权威源在 `ui/src/styles/base.css`：`:root`（暗底默认）定义背景/表面/文本/边框/强调色/状态色/圆角/间距/阴影/字体与文本缩放等全套 CSS 变量，`:root:where([data-theme-mode="light"])` 整块覆盖为亮色（`styles/base.css:1-645`）。各具名字体族（knot/dash/absolutely/tide/beacon/phosphor）以 `public/themes/<family>.css` 附加调色板，另有 claw（默认，内联在 base.css）与 custom（浏览器本地导入）。强调色 `--accent` 由 `applyControlUiAccent` 从设置写入。组件样式通过 CSS 变量消费 token；颜色直写十六进制被 stylelint 的 `color-no-hex` 禁止（见 ui/AGENTS.md 样式策略），保证单一 token 通道。

主题解析有两套并存实现并刻意保持 lockstep：运行期 `app/theme.ts` 的 `resolveTheme`/`resolveMode` 处理 `system` 跟随 `prefers-color-scheme`，把模式解析成 `ResolvedTheme`；`index.html` 里的内联脚本（23-93 行）在首帧前只读一次 localStorage，命中具名字体族时注入带 `blocking=render` 的调色板 `<link>`，并写 `data-theme`/`data-theme-mode`/`data-theme-resolved` 与 `.wa-light/.wa-dark`。head 中 `<meta name="color-scheme">`、带 media 的 theme-color 及 html 背景色回退覆盖第一帧，避免深色用户先看到白底（`index.html:10-13,94-165`）。因此防闪依赖“内联脚本 + render-blocking palette + 两套实现手工同步”的组合。

模式切换路径 `theme.setMode`（`bootstrap.ts:176-191`）：持久化前先经 `startThemeTransition`——目前它只做“同目标立即应用、异目标先应用后清理动画 class”的收敛，真正的圆形扩散动画声明在 `styles/base.css:730-761`（View Transition API），并带 `prefers-reduced-motion` 关闭。`applyThemePresentation`（`bootstrap.ts:81-106`）写 `data-theme*`、style.colorScheme、文本缩放 `--control-ui-text-scale`，并为具名字体族按需挂载字库样式表。`system` 模式注册 matchMedia 监听，系统明暗变化时重新发布；全部修改走 `syncThemePaletteStylesheet` 的“等调色板 css 可读后再应用”栅栏，防止慢样式覆盖新选择（`theme.ts:121-153,136-154`）。

持久化与同步在 `app/settings.ts`：设置整体按 gateway 来源域（`gatewayOriginScope`）分桶存 localStorage，键形如 `openclaw.control.settings.v1:<scope>`，另有 gateway 选择与按域的会话记录键；token 只放 sessionStorage 且不再落 localStorage（`settings.ts:29-46,410-427,625-739`）。写失败（隐私模式/配额）时内存镜像 `unpersistedSettings` 保底。设置变更走唯一 `patchSettings` 写通道并广播给监听器。

可同步集合由 `app/server-prefs-state.ts` 的 `SYNCED_PREFS` 白名单声明（`server-prefs-state.ts:46-113`）：theme、themeMode、accent、locale、chatShowThinking、chatShowToolCalls、chatPersistCommentary、chatSendShortcut、chatFollowUpMode、sidebarEntries。这些字段的权威源是服务端 config `ui.prefs`（网关强制执行无哈希 LWW 合并），localStorage 只是即时镜像与离线暂存；推送路径 `pushServerUiPrefs`（`app/server-prefs.ts:658-698`）在写失败/只读范围时降级为“保留为设备本地”，应用路径 `applyServerUiPrefs`（309-407 行）只在服务端值相对 lastSeen 变化时打补丁回本地设置，并有 pending shadow、冲突限次重排与按域/按 profile 的作用域模型。效果上跨窗口/跨设备收敛外观与阅读偏好：一个 tab 改了主题/语言，其余窗口在收到 config 快照或变化事件时应用；但注意 UI 不做 `BroadcastChannel`/`storage` 事件（本次 grep 未找到），navCollapsed 这类会话形态刻意不持久化（注释说明共享 localStorage 不应跨 tab 泄漏可见性），因此侧栏折叠、抽屉等布局态在窗口间不同步。

## 响应式、多入口与窗口适配

响应式是“JS 断点 + CSS 断点”双轨：JS 侧 `isMobileNavLayout()` 用 `(max-width: 1100px)`，原生 Web chrome 宿主降到 600px（`app/mobile-nav-layout.ts:5-18`），在窄宽度下 Shell 把常驻侧栏装进 `openclaw-modal-dialog.nav-drawer` 作为抽屉（`app-shell-view.ts:559-572`）。侧栏元素本身是 `OpenClawShell` 一次性创建、再在桌面列与移动抽屉两个 slot 间移动复用的（`app-host.ts:175-178` 注释：避免每个断点重置会话控制器与宠物生命周期），宽度回调统一做焦点归还与菜单收起。CSS 侧 `styles/layout.css` 的 `.shell` 是两列 grid（`var(--shell-nav-width) minmax(0,1fr)`），折叠态把导航列设 0，settings 接管态换固定设置列，onboarding 态置 0（`layout.css:5-26,283-297`）；组件内 `max-width` 媒体条件遵守 400/560/640/768/900/1100/1320 的规范阶梯（ui/AGENTS.md）。`resize` 事件里处理“窄→宽展开、宽→窄关抽屉再保留 tab 局部展开”的交接（`app-shell-chrome.ts:345-366`）。

多入口与窗口：除整页 Shell 外，同一前端接受“聚焦文档”路由——terminal/desktop/dashboard 全屏面板与 approval/question 独立页，由 URL 解析后直接以对应面板/页面渲染、完全省略应用壳（`app-root.ts:447-521`、`bootstrap.ts:321-334` 说明聚焦文档不启动应用路由）。聚焦文档的入口地址语义由 `@openclaw/session-url-contract` 的 focus path 契约管理，供原生客户端“在独立窗口打开某面板/会话”用。macOS 原生 Web chrome 宿主在 html 上加 native class，壳据此去掉 in-page 折叠/搜索按钮并让渡给原生标题栏，原生按键与导航事件经 window 级 CustomEvent 进 Shell（`app-shell-chrome.ts:147-158` 的 native 事件族）。PWA/独立窗口下的安全区 padding 在 `base.css:770-786`。

## 图片、附件、拖放等公共内容交互

图片全屏查看是 `openclaw-image-lightbox`：建立在 `openclaw-modal-dialog` 上、铺满视口的查看器，集成 `@panzoom/panzoom` 平移缩放、双击放大、受限的“在新页打开原图”blob 类型白名单（`components/image-lightbox.ts:9-51` 起），触发入口在消息渲染等业务层。代码文件预览有 `openclaw-file-preview-modal`：同样以 modal 为壳，左侧文件清单可搜索、右侧按 64 行分块渲染代码，附复制按钮与文件种类图标映射（`components/file-preview-modal.ts:17-99,490-554`）。文件种类 `file-kind.ts` 同时被聊天文件链接与预览共用，保证命名一致。

拖放：应用壳在 window 冒泡阶段拦下未被业务消费的“文件拖放”，既不打开浏览器默认行为也不吞掉真正的 `<input type=file>` 与已处理的 drop 目标（`app-shell-chrome.ts:368-387`）；具体拖入/上传/提交的完整链路归属 Chat UI 业务，本类目只记录壳级护栏。附件的跨页面“交接”（把本窗格待发附件交给目标窗格）由 `chatAttachmentHandoff` 能力提供，注册在 ApplicationContext 上。聊天/看板/管理器等业务文件的读取与持久化走 `media-core`、附件 API 等通用层，不在本次下钻。

## 平台边界与相邻表面

桌面与移动 companion 不是 Control UI 的薄壳。Linux 客户端是 Tauri v2 桌面壳，负责 Bonjour 发现、CLI 安装、用嵌入式 WebView 打开所选 Gateway 的 Control UI、Quick Chat 则以 capability 白名单隔离的 child WebView 渲染 `show_widget` 文档、托盘与系统通知（`apps/linux/README.md`）。macOS 客户端是 Swift 应用，可自带本机 UI 也嵌入 Control UI WebView（Control UI 侧的 `native-*.ts` 桥与 macOS 的 WebViewJavaScriptSupport 对应）；iOS/Watch 与 Android/Wear 是完整原生聊天客户端（SwiftUI / Android 工程），经共享 `apps/shared/OpenClawKit`（网关 WebSocket 传输、协议编解码、跨平台共享聊天 UI 与字体工具）与原生能力代码连网关。这些客户端各自实现主题与通知通道，不消费 Control UI 的 token 或 store。本调查只确认平台边界与各自技术栈，未下钻任一原生 App 的界面实现（未验证项）。

TUI（`src/tui`）是基于 `@earendil-works/pi-tui` 的终端界面：组件层有 chat log、markdown 消息、select list、autocomplete 等；浮层经由 pi-tui 的 overlay 机制封装成开合/焦点恢复处理器（`src/tui/tui-overlays.ts:1-29`）；主题 `src/tui/theme/theme.ts` 从 `OPENCLAW_THEME` 或 `COLORFGBG` 判定明暗并用相对亮度公式挑选文字色，与 Web 主题无共享。后端契约面向远程 Gateway 或内嵌后端，属命令行面，不共享 Control UI 设施。

## 设计取舍与已确认边界

可确认的架构取向：应用根“一个入口多种文档模式 + 懒加载分块 + 每个文档一套能力对象”，把一致性建立在单一前端仓库、单一 token 样式表、单一 overlay 适配层与通过 Gateway 收敛的偏好同步上，而不是运行时框架提供的全局 store。浮层统一到 Web Awesome 的 dialog/popover top-layer 能力而非自建 Portal 树；正文大量页面级模块被降为“按需注册 + 动作回放”，配合 stale-chunk 重载，说明团队把分块加载失败也当作一等反馈面。CSS 无 `@layer`、多数组件用 light DOM 共享全局样式表（ui/AGENTS.md 解释了层叠顺序策略），Web Awesome 组件则以 shadow + `::part` 接 token。

边界与推断性质事项：Toast 单槽（一次一条、新消息替换旧消息并上报 replaced）是从“单个宿主 + 队列只留最新”的源码得出的行为推断，未运行确认堆叠缺失的用户体验；多窗口同步仅覆盖可同步外观键，窗口形态差异（折叠/抽屉）有意不跨 tab；聚焦文档与整页 Shell 共享 localStorage 但各自实例化能力对象，theme 等通过服务端偏好收敛。native companions 的主题/通知与 Web 无关。

## 扩展调查

无障碍与键盘面有可静态确认的基础：skip-link（`app-shell-view.ts:471`）、`:focus-visible` 全局焦点环、sr-only、Toast/loading 的 `role=status`/`aria-live`、modal 适配器补 `role=dialog`/`aria-modal`/label 并把 tooltip 文本同步进 `aria-describedby`（`tooltip.ts:556-584`）、菜单项 radio 语义修复（`web-awesome.ts:36-48`）、`prefers-reduced-motion` 全局降级与动画时长清零、iOS 触控文本缩放上界。Web Awesome dialog 的焦点陷阱、roving focus 与读屏公告依赖库内部实现，未下钻、未经运行验证；本次未做 WCAG 合规审计，不做通过性结论。

动画体系没有独立动画库：主用 CSS transition/keyframes，弹层动画时长经 CSS 变量（如 tooltip 的 `--wa-transition-fast`）与 Web Awesome 变量协商，主题切换声明了 View Transition API 圆形扩散并有 reduced-motion 关闭分支；未运行验证动画实际表现。

## 未验证事项

- 视觉表现：任何主题明暗、浮层动效、焦点顺序、Esc/遮罩/焦点陷阱的实际行为、Toast 定位观感、触摸手势与响应式切换，均未运行浏览器验证；Web Awesome dialog/dropdown/popover 与 @uirouter 内部行为按依赖库边界未核实。
- 主题“防闪”链路（内联脚本 + render-blocking palette + 双实现 lockstep）只经代码阅读确认，未在慢网/离线/双 tab 场景实测。
- 跨窗口收敛（config ui.prefs 的推拉、pending 暂存、冲突重排）逻辑完整但未做多窗口实测；推测离线排队与恢复在运行中成立。
- 审批/配对/更新横幅只确认状态机与渲染入口，未观察真实事件流与端到端表现；通知（web push / 原生）需要已注册推送或真实设备，未验证。
- 原生 App 各自的主题、通知、无障碍与响应式未逐一下钻；TUI 的终端渲染仅确认代码接线，未在 PTY 环境运行。
- 语义上属于其它类目的内容交互（拖放上传、文件预览触发点、系统通知触发事件）只记录交点，完整链路未调查。

## 关键源码索引

- 应用根与文档模式分发：`ui/src/app/app-root.ts`、`ui/src/app/app-host.ts`
- 装配与上下文：`ui/src/app/bootstrap.ts`、`ui/src/app/context.ts`
- 弹窗适配层：`ui/src/components/modal-dialog.ts`；命令式确认：`ui/src/components/confirm-dialog.ts`
- Toast：`ui/src/lib/toast.ts`
- 菜单/浮层公共件：`ui/src/components/web-awesome.ts`、`dropdown-menu-controller.ts`、`menu-surface.ts`、`anchored-overlay.ts`、`portaled-hovercard.ts`
- Tooltip：`ui/src/components/tooltip.ts`
- 主题与 token：`ui/src/app/theme.ts`、`ui/src/app/theme-transition.ts`、`ui/src/styles/base.css`、`ui/index.html`
- 偏好存储与同步：`ui/src/app/settings.ts`、`ui/src/app/server-prefs-state.ts`、`ui/src/app/server-prefs.ts`
- 注意型状态：`ui/src/app/overlays.ts`、`ui/src/app/overlays-types.ts`、`ui/src/components/exec-approval.ts`
- 懒加载与错误恢复：`ui/src/app/lazy-custom-element.ts`、`ui/src/app/stale-chunk-reload.ts`、`ui/src/components/lazy-view-error.ts`
- 壳布局与响应式：`ui/src/app/app-shell-view.ts`、`ui/src/app/mobile-nav-layout.ts`、`ui/src/app/app-shell-chrome.ts`、`ui/src/styles/layout.css`
- 公共内容交互：`ui/src/components/image-lightbox.ts`、`ui/src/components/file-preview-modal.ts`、`ui/src/components/file-kind.ts`
- TUI：`src/tui/tui-overlays.ts`、`src/tui/theme/theme.ts`
- 平台文档：`apps/linux/README.md`、`apps/macos/README.md`、`apps/ios/AGENTS.md`、`apps/android/README.md`
