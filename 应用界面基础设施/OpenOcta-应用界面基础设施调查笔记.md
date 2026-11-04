# OpenOcta 应用界面基础设施调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态源码核对。以 `ui/index.html` → `main.ts` → `openclaw-app` 的装配为入口，逐项阅读根组件状态、渲染函数、全局样式表、浮层与主题实现，并用全文检索交叉确认键盘、焦点、Toast、拖放、剪贴板与桌面窗口 API 的调用范围；未运行应用，未做视觉、键盘与响应式实测
>
> 调查范围：应用级界面基础设施（装配、公共组件、状态所有权、浮层、反馈、主题、响应式、内容交互、桌面窗口与打包、i18n、首次启动）；不含聊天工作台业务细节、消息渲染器、各业务页表单语义
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的控制台是**以单个 Lit 自定义元素为根的 light DOM 单页应用**，不是组件库驱动的界面。`ui/index.html` 只放一个 `<openclaw-app>`，`main.ts` 仅加载全局样式并注册组件；根组件让 `createRenderRoot` 返回自身，把整棵界面渲染到文档 light DOM，因此 19 个参与加载的全局 CSS 文件可以按类名作用到所有视图。界面依赖只有 Lit 3.3、A2UI 的 Lit/核心包、`marked` 与 `dompurify`，没有 UI 组件库、路由库或状态管理库（`ui/package.json:13-20`）。

浮层、反馈与主题都由“根组件状态 + 渲染函数 + CSS 类”手工拼装。快照内有 28 个 `.modal-overlay` 根节点、一套右侧滑出面板样式（`.channel-panel-overlay`，模板与类名引用 18 处）、独立的执行审批/网关切换全屏层、文件预览层和会话溢出菜单。它们没有公共 Modal 组件，也没有 Portal Host，而是随所在视图渲染在 `.content` 或 `.shell` 内，再由样式强制改回固定定位；层级靠手写 z-index 阶梯维持。Esc 只在四个入口绑定，本次未找到焦点陷阱、焦点归还或滚动锁定。

反馈同样是局部的：没有全局 Toast、通知中心或错误边界，错误主要落在各模块自己的 `*Error` 字段与内联提示里；字符串检索到的“Toast”只有压缩完成提示（5 秒后自动清除）和蜂群页局部提示条。主题实现相对完整：双份 CSS 变量 token、`data-theme` 与 `color-scheme`、系统跟随监听、View Transition 圆形扩散及 reduced-motion 降级都已具备；但偏好只存 localStorage，首屏没有预挂载脚本。布局桌面优先，窗口最小 800×600，断点集中在 900 与 1200 附近，没有移动端入口。

## 系统边界与总体装配

本类目记录跨页面复用的界面底层，不承担业务流程说明。聊天输入、消息气泡与会话列表属于 Chat UI；Markdown 与 A2UI 绘制属于消息渲染器；渠道、模型、技能等表单含义属于各自业务类目。这里只记录这些业务页面共同依赖的装配、承载与反馈机制。

**界面栈。**

| 层 | 实现 |
|---|---|
| 桌面壳 | Wails 窗口加载内置启动页，再跳转本地网关页面 |
| 视图 | Lit 3.3 自定义元素与模板字符串，根节点渲染到 light DOM |
| 协议渲染 | `@a2ui/lit` basic catalog（生成式输出的交互组件） |
| 构建 | Vite 7；测试用 Vitest + Playwright Chromium |
| 样式 | 19 个参与加载的全局 CSS 文件，CSS 变量 token，少量容器查询 |
| 状态 | 根组件 494 个 `@state` 字段 + 41 个控制器模块 |
| 路由 | 无路由库；tab 状态 + History API + `popstate` |

**启动装配链。**

1. `ui/index.html:10-12` 只有 `<openclaw-app>` 与模块入口，没有内联主题脚本或 splash。
2. `ui/src/main.ts:1-2` 先导入 `styles.css`，再导入 `ui/app.ts` 完成自定义元素注册。
3. 根组件的 `connectedCallback` 注册原生对话框代理、全局 Escape 监听和卸载保护，然后调用 `handleConnected`（`ui/src/ui/app.ts:783-790`）。
4. `handleConnected` 依次推断 base path、应用 URL 参数、同步 tab、同步主题、挂系统主题监听、连接网关（`ui/src/ui/app-lifecycle.ts:45-52`）。
5. `firstUpdated` 观察顶栏高度，并在 400 毫秒后尝试启动安装引导（`app-lifecycle.ts:69-79`）。
6. `render()` 只转调 `renderApp`（`ui/src/ui/app.ts:1301-1303`）；总渲染函数按 tab 组装 `.shell` 栅格（`ui/src/ui/app-render.ts:638-656`）。

**状态所有权。** 根类持有 494 个 `@state` 字段，覆盖聊天、配置、渠道、模型、技能、蜂群、知识库、日志等全部页面（`ui/src/ui/app.ts:150-728`）。控制器目录下的 41 个文件（另有 3 个测试文件）提供 205 个导出入口，统一接收 host 并直接改字段。

`ui/src/ui/views/` 下的 59 个模块基本是纯函数，只把状态和回调拼成模板；根类只保留 `applySettings`、`setTheme` 等转发方法（`app.ts:874-884`）。这形成“一个状态根 + 函数式控制器 + 渲染函数”的分层，没有 selector、订阅或不可变更新。

**一次浮层的完整主链。** 以 API Key 表单弹窗为例：

1. 入口按钮把 `apiKeysFormModalOpen` 置真（状态声明见 `app.ts:484`）。
2. 总渲染在根级条件分支中调用 `renderApiKeysFormModal`（`app-render.ts:3879`）。
3. 视图返回 `div.modal-overlay`，内容卡片停止冒泡，遮罩点击直接关闭（`ui/src/ui/views/api-keys.ts:312-343`）。
4. 样式把该层设为固定定位、铺满视口、`z-index: 150`（`ui/src/styles/common.css:482-496`）；若它被渲染在 `.content` 或 `.shell` 内，另有规则用 `!important` 抵消父级定位与网格排布（`ui/src/styles/components.css:1257-1276`）。
5. 关闭回调把状态置假，Lit 重新渲染后节点直接移除；没有退场动画、焦点归还或滚动锁定。

## 1. 界面栈、公共组件与状态所有权

**根节点与 light DOM。** `createRenderRoot` 返回 `this`，根组件不使用 shadow root（`ui/src/ui/app.ts:779-781`）。另有 9 个组件做同样选择，包括聊天输入、聊天线程、建议提示、交付物附件、本地 Agent 选择器、吉祥物、思考计时器、Vault 编辑器与图谱视图；其余组件保持 Lit 默认的 shadow DOM。结果是一半组件共享全局 CSS 与 `:root[data-theme]` 选择器，另一半必须把样式写进各自的 `static styles`。`thinking-timer.ts:27` 的注释直接说明了这一动机：为了让组件继承全局 CSS。

**公共组件面。** 实际存在的复用件集中在少数交互：

- `resizable-divider` 提供拖拽分隔条与 `splitRatio` 事件（`ui/src/ui/components/resizable-divider.ts:8-96`），但模板中没有 `<resizable-divider>` 引用，属于本次未接入的组件。
- `native-dialog-bridge` 把 `confirm` / `alert` / `prompt` 代理到应用内浮层，未注册时回退浏览器原生 API（`ui/src/ui/native-dialog-bridge.ts:1-40`）。
- `openocta-mascot` 元素与 `styles/mascot.css` 都存在，但组件未出现在任何模板中，样式文件也不在导入链上，当前处于未接入状态。
- `chat-file-preview`、`chat-local-image` 承担文件与图片查看（见第 6 节）。
- `openocta-chat-input`、`openocta-chat-thread`、`openocta-chat-suggestions` 是聊天区的局部组件。

没有 Button、Modal、Drawer、Toast、Tooltip 这类应用级原语；按钮、卡片、胶囊和弹窗都靠 `.btn`、`.card`、`.pill`、`.modal` 等类名约定复用，样式定义分散在 `common.css`、`components.css`、`tech-theme.css` 与各业务样式表中。

**状态所有权。**

| 状态 | 持有者 | 持久化 |
|---|---|---|
| 主题、会话键、分隔比例、导航折叠 | 根组件 `settings` | localStorage `openclaw.control.settings.v1` |
| 各弹窗开关、选中项、表单草稿 | 根组件 `@state` | 不持久化，关闭即丢弃 |
| 业务列表（渠道、模型、技能、日志等） | 根组件字段，由控制器写入 | 以网关/服务端配置为准 |
| 窗口最大化、桌面模式 | 根组件字段 + `window.runtime` | 不持久化 |
| 安装引导完成状态 | localStorage + `openocta.json` 的 `wizard.setup` | 双写，按版本比较 |

**路由与多入口。** 没有路由库。`setTab` 更新字段后调用 `syncUrlWithTab`，用 `history.pushState` 写入路径（`ui/src/ui/app-settings.ts:461-495`）；启动与后退分别由 `syncTabWithLocation` 与 `popstate` 恢复（`app-lifecycle.ts:45-51`）。浏览器与桌面共用同一页面，仅靠 `_shell=d` 查询参数把桌面模式写入 sessionStorage，从而启用窗口按钮与外部链接处理（`ui/src/ui/open-external-url.ts:19-54`）。

## 2. 弹窗、浮层与菜单

**没有 Portal，浮层就地渲染。** 所有浮层都是视图模板的一部分，挂载点随调用位置变化：业务页弹窗通常落在 `.content` 内，根级审批与引导落在 `.shell` 内或 `.shell` 之后。`tech-theme.css:21-26` 的注释记录了这样做的代价：内容区子元素统一 `position: relative` 并获得入场动画，而 `translateY(0)` 也会成为固定定位的包含块，因此弹层必须显式排除；`components.css:1257-1276` 再用 `position: fixed !important` 与 `inset: 0 !important` 把落在内容区或 shell 里的弹层拉回视口。

**浮层家族。**

| 类型 | 根节点 / 样式 | 典型入口 | 层级 |
|---|---|---|---|
| 居中弹窗 | `div.modal-overlay` | 技能、渠道、Cron、数字员工、API Key、教程等 28 处 | 150 |
| 右侧滑出面板 | `.channel-panel-overlay` | 渠道配置、MCP 编辑、模型选择 | 150 |
| 叠在侧栏上的二级弹窗 | `.models-overlay--add-model` / `--use-model` | 添加模型、选择默认模型 | 160 / 165 |
| 执行审批与网关切换 | `.exec-approval-overlay` | 命令审批、切换网关确认 | 200 |
| 会话溢出菜单 | `.session-overflow-backdrop` + `.session-overflow-flyout` | 会话行的“⋯” | 200 / 201 |
| 安装引导 | `.setup-wizard` | 首次启动或版本变化 | 300，内部 310 / 320 |
| 文件预览 | shadow 内 `.backdrop` + `.panel` | 点击附件 | 1200 |
| 原生对话框替代 | `.channel-panel-overlay--centered` 内联样式 | `alert` / `confirm` / `prompt` | 10000 |

层级阶梯没有统一常量或层级栈，全部写在各自样式里：150、160、165、200、201、300、310、320、1200、10000。另有 1000 与 1200 的字段提示气泡，它们是绝对定位的 tooltip，不与全屏层竞争。该阶梯能覆盖“侧栏 → 二级弹窗 → 引导 → 原生对话框”的已知嵌套，但新增浮层时需要人工选择数值。

**关闭、Esc 与焦点。**

- 遮罩关闭由每个视图自行实现：多数在根层绑定点击回调，内层卡片 `stopPropagation`；有的先判断 `e.target.classList.contains(...)` 以免误关（`ui/src/ui/views/app-update-modal.ts:34-40`、`channels.config.ts:272-276`）；原生 `alert` 点遮罩等同确认（`ui/src/ui/views/native-dialog-overlay.ts:29-38`）。
- Escape 只有四个处理点：全局监听负责原生对话框与会话溢出菜单（`ui/src/ui/app.ts:754-769`）；会话重命名输入框取消编辑（`app-render.ts:1054-1062`）；聊天输入的 @ 提及浮层收起（`openocta-chat-input.ts:260-264`）；安装引导把 Esc 映射为“跳过当前步骤”（`views/setup-wizard.ts:1348-1353`）。28 个 `modal-overlay` 没有任何一个绑定 Esc。
- 本次未找到焦点陷阱、`inert`、焦点归还或 `document.body` 滚动锁定（检索范围：`ui/src` 全量检索 `focusTrap`、`inert`、`body.style.overflow`、`.focus()`；只有聊天输入与 Vault 编辑器会主动聚焦文本框）。
- 无障碍标注不完整：15 处 `aria-modal="true"`、18 处 `role="dialog"`，其余弹窗只有类名；遮罩内的关闭按钮多数有 `aria-label`，但列表项、菜单项之外的内容没有统一的可访问名称约定。

**会话溢出菜单。** 位置由触发按钮计算出的 `top` / `right` 写入状态，菜单固定定位并配一层独立遮罩；点击菜单项先关菜单再执行动作（`ui/src/ui/app-render.ts:248-342`）。它使用 `role="menu"` / `role="menuitem"`，但没有方向键导航或焦点移入，键盘路径只有 Esc 关闭。

**销毁时机。** 浮层由条件模板控制，关闭即从 DOM 移除，没有过渡动画或延迟卸载；未提交的表单草稿随节点一起丢弃（少数业务状态例外）。

## 3. 通知、加载态与错误反馈

**没有全局反馈宿主。** 本次未找到 Toast Host、Snackbar、通知中心或消息队列（检索范围：`ui/src` 全量检索 `toast`、`Toast`、`notification`、`snackbar`；`new Notification` 与 `serviceWorker` 也无命中）。现有反馈按场景分散：

| 机制 | 触发 | 呈现与持续时间 |
|---|---|---|
| 审批横幅 | `approvals.list` 每 3 秒轮询，出现新待审批 ID 时显示 | 顶栏下方的 `role="status"` 横幅，可手动关闭；关闭后仅在新 ID 到来时重现（`ui/src/ui/app-approvals-banner.ts:8-66`、`app-render.ts:659-687`） |
| 压缩完成提示 | compaction 事件 `phase: "end"` | 状态对象保留 5 秒后清空（`ui/src/ui/app-tool-stream.ts:177-206`） |
| 蜂群错误条 | `swarmError` 非空 | 页面局部 `.agent-swarm__toast`（`ui/src/ui/views/agent-swarm.ts:592`、`:617`） |
| 页头错误胶囊 | `lastError` 非空 | 内容区标题旁的 `.pill.danger`，无自动消失（`app-render.ts:1256`） |
| 各业务错误 | 控制器 catch 后写 `*Error` 字段 | 对应页面内的 callout、空态或内联文案 |
| 原生确认 | `nativeConfirm` / `nativeAlert` / `nativePrompt` | 应用内居中浮层，`z-index: 10000`；未注册时回退浏览器 API |

**错误边界。** 本次未找到 `unhandledrejection`、`window.onerror` 或 `errorHandler` 注册（检索范围：`ui/src` 全量）。请求失败由各控制器就地捕获并写入自己的错误字段，渲染层没有统一的异常兜底组件。由此可推断：后台页签中的失败不会主动提示，用户需要切回对应页面才能看到错误；这是实现结构推导，未做运行验证。

**加载与空态。** 各页面自行输出“加载中…”、旋转图标或占位文案，没有通用骨架屏。`tech-theme.css:655-666` 定义了 `.tech-shimmer` 动画，但全仓库只有定义处一处命中，没有使用方。空态同样是页面级文案，例如聊天首屏的欢迎语与快捷提示（`ui/src/ui/views/chat.ts:890-910`）、技能/模型/教程列表的“暂无匹配”。

**阻断式确认。** 桌面 WebView 中原生 `confirm` / `alert` / `prompt` 可能不显示或阻塞，项目因此在根组件注册应用内实现，并用自定义浮层承载；这使确认框也进入同一套手写浮层体系（`ui/src/ui/native-dialog-bridge.ts:1-40`）。

## 4. 主题、视觉 token 与持久化

**token 权威源。** `ui/src/styles/base.css:1-78` 定义浅色 `:root`，`:80-124` 用 `:root[data-theme="dark"]` 覆盖为深色，并分别设置 `color-scheme`。变量覆盖背景、文本、边框、强调色、警告/危险/信息色、阴影、圆角、字体、缓动与时长，另有 `--text`、`--muted`、`--card-bg` 等语义别名供旧样式使用。

`tech-theme.css` 不重新定义这批变量，而是在其上做组件级外观覆盖，部分规则以深色为基底、用 `:root[data-theme="light"]` 反向修正（`tech-theme.css:755-771`）；因此组件最终样式需要按“base → tech-theme → 业务样式”的导入顺序叠加理解。

**初始化。** 根组件字段初始化时直接调用 `loadSettings()`，默认主题为 light（`ui/src/ui/storage.ts:34-45`、`app.ts:195-196`）。连接后 `syncThemeWithSettings` 解析 `system` 并调用 `applyResolvedTheme`，把结果写到 `document.documentElement.dataset.theme` 与 `style.colorScheme`（`ui/src/ui/app-settings.ts:328-341`）。系统跟随通过 `matchMedia("(prefers-color-scheme: dark)")` 的 `change` 监听实现，只有当前模式为 `system` 时才重新应用（`app-settings.ts:343-362`）。

**切换与过渡。** 顶栏按钮按 light → dark → system 循环，并把指针坐标或按钮位置交给过渡函数（`app-render.ts:757-769`、`ui/src/ui/theme.ts:18-23`）。`startThemeTransition` 在支持 View Transition 且用户未要求减少动态效果时，把指针位置换算成百分比写入 `--theme-switch-x/y`，在回调里应用主题，结束后清理类名与变量；不支持或抛错时直接应用（`ui/src/ui/theme-transition.ts:46-108`）。

**持久化与首屏。** 偏好写入 localStorage 的 `openclaw.control.settings.v1`，每次 `applySettings` 都同步保存（`ui/src/ui/storage.ts:1`、`:99-100`；`app-settings.ts:79-91`）。`index.html` 没有在模块加载前读取并写入 `data-theme` 的内联脚本，因此深色用户可能先看到浅色 token 再切换；这是由加载顺序推出的风险，未做首屏实测。也没有 `storage` 事件监听或跨窗口广播（检索范围：`ui/src` 全量），当前只有一个窗口，暂不构成功能缺口。

## 5. 响应式、移动端与窗口适配

**应用骨架。** `.shell` 是两行两列的网格：顶栏横跨整行，第二行是 200px 导航栏与自适应内容区（`ui/src/styles/layout.css:5-24`）。导航折叠时列宽变 56px，聊天专注模式变 0；无侧栏页面改用单列布局（`layout.css:1650-1655`）。顶栏使用 sticky + 半透明背景，内容区独立滚动（`layout.css:853-864`、`:1657-1673`）。

**断点。** 以媒体查询为主，断点分散且不统一：

| 断点 | 主要变化 |
|---|---|
| 1200px | 隐藏顶栏状态区（`layout.css:1913-1917`） |
| 1100px | 员工市场详情由双栏变单栏（`components.css:800-809`） |
| 980px | 智能体布局与头部改单列（`components.css:1848-1856`） |
| 960px / 640px | 安装引导布局收紧（`setup-wizard.css:346-356`） |
| 900px | 顶部标签隐藏文字、目录与聊天布局调整（`layout.css:1919-1932`、`chat/layout.css:1023-1029`） |
| 768px | 聊天侧栏改为覆盖式（`chat/sidebar.css:132-140`） |
| 600px / 560px / 480px | 统计卡片、聊天控件与配置表单进一步堆叠（`usage.css:1821`、`chat/layout.css:1029`、`config.css:1378-1387`） |

另有 3 处容器查询，分别调整列表项、日志行与技能网格（`components.css:458`、`:1212`、`:1842`），整体仍是视口断点驱动。

**窗口与移动端。** Wails 窗口初始 1280×800，最小 800×600（`src/main.go:108-112`）。没有独立移动端路由、触摸手势或系统性的安全区处理，只有聊天输入区引用了一次 `env(safe-area-inset-bottom)`（`chat/layout.css:303`）。在浏览器中打开时窗口可以更窄，但布局只做隐藏与堆叠，不改变信息架构。

**用户可控的布局状态。** 导航折叠写入 `navCollapsed` 并在启动时恢复。`splitRatio` 也进入设置与 props，但聊天视图只声明该属性，渲染时使用固定栅格 `clamp(340px, 30vw, 520px)`（`ui/src/styles/chat/sidebar.css:12-15`、`views/chat.ts:1004-1027`）；拖动组件 `resizable-divider` 没有出现在任何模板中，因此该偏好当前不影响布局。

## 6. 图片、附件、拖放与常见内容交互

**附件选择与粘贴。** 聊天输入的文件选择一次只接受一个文件，超过数量或校验失败时把错误写回 `chatAttachmentError` 并清空 input（`ui/src/ui/views/chat.ts:399-430`）。粘贴路径只识别 `image/*`，其余类型直接放行给浏览器默认行为（`views/chat.ts:437-476`）。

**附件承载。** 文件读取用 `FileReader` 转 data URL，附件以 id、dataUrl、MIME、文件名、大小与 kind 组成对象，存在根组件数组中并随消息提交（`views/chat.ts:380-396`、`app-chat.ts:169-206`）。

**文件预览。** 点击附件后由 `chat-file-preview` 以固定定位层展示（`ui/src/ui/components/chat-file-preview.ts:16-18`、`:246-268`）。PDF 与 HTML 直接放进 `iframe`，没有 `sandbox` 属性；文本类按扩展名解码成表格、代码块或 Markdown；远程且无法解码时只给下载链接。预览层自带“下载”和关闭按钮，但没有缩放、翻页或键盘导航。

**图片。** `chat-local-image` 通过网关的附件接口取得 URL，渲染为受限尺寸的 `<img>`，点击用 `window.open` 打开新窗口（`ui/src/ui/components/chat-local-image.ts:50-97`）。本次未找到灯箱、缩放、旋转或图片列表切换组件。

**拖放。** 唯一实现拖放的入口是技能创建的 ZIP 上传区：`dragover` 阻止默认行为，`drop` 只接受 `.zip`，点击则动态创建 file input（`ui/src/ui/views/skill-create-modals.ts:94-128`）。聊天区、知识库和附件条都没有拖放监听（检索范围：`ui/src` 全量 `dragenter`、`dragover`、`dragleave`、`drop`、`dataTransfer`）。

**剪贴板。** 只有写入：复制会话链接、复制更新提示、复制 API Key、复制消息为 Markdown 等，均调用 `navigator.clipboard.writeText`；失败时用 `nativePrompt` 让用户手动复制（例如 `app-render.ts:304-310`）。没有读取剪贴板图片或文本的入口。

**其他尺寸交互。** 知识库侧栏宽度单独存 localStorage（`ui/src/ui/app-knowledge-vault.ts:49-60`）；聊天侧栏宽度由 CSS 决定（见第 5 节）；没有通用面板拖拽或分栏记忆。

## 7. 扩展调查：桌面、国际化与首次启动

### 7.1 桌面窗口、系统集成与打包

**单窗口壳。** Wails 只创建一个窗口，启动本地网关并等待健康检查，然后把内置启动页交给 WebView；启动页用 `fetch` 轮询 `http://127.0.0.1:18900?_shell=d`，最多 120 次、每次 500 毫秒，超时后显示手动链接（`src/main.go:63-123`、`src/wails-bootstrap/index.html:26-48`）。业务界面本身由网关托管的 Web 页面提供，所以窗口能力只通过 `window.runtime` 暴露的最小 API 使用。

**窗口控制。** 根组件在桌面模式下读取 `runtime.Environment()` 判断平台，只有 Windows 才启用自定义最小化/最大化/关闭按钮，并对 `resize` 做 120 毫秒防抖后查询最大化状态（`ui/src/ui/app.ts:1169-1292`）。Windows 构建同时把 `Frameless` 设为 `false`，注释说明要保留系统原生标题栏（`src/main.go:114-122`），但界面仍会在 `isWindowsDesktop` 时渲染一套窗口按钮（`app-render.ts:842-876`）。两套控制是否同时可见、是否重叠，需要实际运行确认。

**系统集成缺口。** 本次未找到托盘、系统通知、全局快捷键、文件关联或多窗口 API（检索范围：`src` 全量 `Tray`、`Notification`、`NewWebviewWindow`；`ui/src` 全量 `new Notification`）。应用更新提示走页面内弹窗与顶栏链接，不依赖系统通知。

**打包与运行形态。**

| 平台 | 产物 | 实现要点 |
|---|---|---|
| macOS | `.app` + `.dmg` | `deploy/macos/build-app.sh` 把 libffi 放入 `Contents/Frameworks`，签名前先单独 codesign；DMG 输出到 `dist-mac/` |
| Windows | 便携 exe + NSIS 安装器 | `deploy/windows/openocta-installer.nsi` 安装两个 exe、创建快捷方式、写开机启动与卸载项 |
| Linux | 单二进制 + systemd / Docker | `deploy/openocta.service` 以 service 模式运行网关；`deploy/Dockerfile` 三阶段构建并嵌入前端 |

文档与实现有一处不一致：`deploy/PACKAGING.md:58` 称 NSIS 安装器包含 WebView2 检测，但 `openocta-installer.nsi`、`deploy/windows/build-installer.ps1` 与 `build.sh` 的 NSIS 分支都没有相关检测或安装步骤。以当前脚本为准，安装器不处理 WebView2 依赖。

### 7.2 国际化

`ui/src/ui/strings.ts:1-17` 定义最小 i18n：locale 从 `document.documentElement.lang` 读取，只有 `zh` 与 `en` 两套字典，`t()` 在调用时同步查表（`strings.ts:3025-3029`）。`index.html:2` 固定 `lang="zh"`，本次未找到语言切换入口或对 `documentElement.lang` 的写入（检索范围：`ui/src` 全量 `documentElement.lang`、`setAttribute("lang")`）。配置字段的标签与帮助文本另有中英双份映射（`ui/src/ui/config-field-labels.ts:538-543`、`config-field-help.ts:594-599`）。

界面文案是混合状态：导航标题、主题切换等使用 `t()`，顶部标签、审批横幅、部分弹窗标题与说明直接写中文（例如 `app-render.ts:700-710`、`:663-667`）。因此切换到英文需要同时改 HTML 语言与替换硬编码文案，当前没有完整路径。

### 7.3 首次启动与设置框架

**版本门控。** 安装引导是否显示由 `shouldShowSetupWizard(version, config)` 决定：配置中的 `wizard.setup` 状态为 completed/skipped 且版本相同则跳过；版本不同、状态未完成、配置已加载但缺少该字段时重新显示；配置尚未加载时退回 localStorage 中的版本记录（`ui/src/ui/setup-wizard.ts:195-242`）。完成后把版本写入 localStorage，并同步到 `openocta.json`；跳过时先写一个“待同步”标记，避免配置尚未落盘时重复弹出（`setup-wizard.ts:274-318`）。首帧后延迟 400 毫秒启动，给配置加载留出时间（`app-lifecycle.ts:69-79`）。

**引导界面。** 主层是固定全屏的 `.setup-wizard`，`z-index: 300`，内部再叠 310/320 两级（`ui/src/styles/setup-wizard.css:9-28`）。它用 `role="dialog"` 与 `aria-modal`，点击背景关闭场景菜单，Esc 执行“跳过当前步骤”（`views/setup-wizard.ts:1341-1355`）。欢迎页是同一体系的独立全屏层（`setup-wizard.ts:1286-1311`）。

**设置框架。** 配置页以“表单 / 原始 JSON”双模式编辑，状态包括搜索词、当前分区、脏标记与 schema 版本（`app.ts:268-288`）。保存走网关配置接口，成功后以服务端配置为准；与 localStorage 中的界面偏好分属两套持久化。

## 8. 设计取舍与已确认边界

**实现取向。**

- 用 light DOM + 全局 CSS 换取“所有视图共享一套 token”，代价是类名成为事实上的公共 API，组件样式无法局部封装。
- 用单状态根换取直接、可追踪的数据流，代价是 494 个字段集中在 1201 行的类里，页面渲染函数达到 3848 行。
- 用“渲染函数 + 固定定位 + z-index 数字”承载浮层，避免引入 Portal 与层级管理器，代价是每个弹窗重复实现遮罩、关闭、层级与无障碍属性。
- 反馈按页面就近放置，避免全局队列的复杂度，代价是跨页面的错误与完成事件没有统一出口。
- 桌面优先，断点只服务于窗口收窄与局部堆叠，不追求移动端信息架构。

**已确认边界。**

- 没有公共 Modal/Toast/Portal Host；浮层由 28 个手写根节点与会话菜单、审批层、预览层等专用实现组成。
- 28 个居中弹窗中没有一个绑定 Esc；未找到焦点陷阱、焦点归还、`inert` 或滚动锁定。
- 没有全局错误捕获与错误边界；错误以各页 `*Error` 字段和内联提示呈现。
- 没有灯箱或图片缩放；本地图片在新窗口打开。
- 聊天区没有拖放；拖放只存在于技能 ZIP 上传。
- 没有语言切换入口；`index.html` 固定中文，部分文案硬编码。
- 没有托盘、系统通知、全局快捷键或多窗口。
- `splitRatio` 与 `resizable-divider` 未接入当前聊天布局。

## 9. 未验证事项

- 浮层在真实窗口中的层叠结果：z-index 阶梯能否覆盖所有嵌套组合，尤其是引导内的二级弹窗与原生对话框同时出现时。
- 遮罩点击、Esc、Tab 顺序与读屏播报的实际表现；静态代码只能确认绑定与属性，不能证明键盘可用性或 WCAG 合规。
- 深色用户在首屏是否看到浅色闪烁；`index.html` 无预挂载主题脚本，实际闪烁取决于 WebView 首帧时机。
- View Transition 的圆形扩散在 WebView2/WebKit 下的效果、掉帧与 reduced-motion 分支。
- PDF/HTML 附件在无 `sandbox` 的 iframe 中的脚本、下载与同源行为。
- Windows 上原生标题栏与页面内窗口按钮是否同时显示、是否重叠；代码同时具备两条路径。
- 800×600 最小窗口下各业务页的可用性，以及 900px 以下断点的实际堆叠效果。
- 安装引导的版本门控在配置删除、并发写入与多设备场景下的表现。
- 审批横幅 3 秒轮询在断线重连、后台页签与大量待审批项下的时序。

## 关键源码索引

- `ui/index.html`、`ui/src/main.ts`、`ui/src/styles.css`：入口与全局样式装配
- `ui/src/ui/app.ts`：根组件、494 个 `@state`、窗口控制、Escape 全局监听
- `ui/src/ui/app-render.ts`：总渲染、`.shell` 栅格、顶栏、会话溢出菜单、根级浮层
- `ui/src/ui/app-lifecycle.ts`、`app-settings.ts`、`storage.ts`：启动、tab/主题同步、偏好持久化
- `ui/src/ui/controllers/`：41 个函数式控制器
- `ui/src/styles/base.css`：浅色/深色 token 与全局基础样式
- `ui/src/styles/layout.css`、`components.css`、`common.css`、`tech-theme.css`：栅格、浮层定位、层级与主题覆盖
- `ui/src/ui/theme.ts`、`theme-transition.ts`：主题解析与 View Transition
- `ui/src/ui/components/chat-file-preview.ts`、`chat-local-image.ts`、`resizable-divider.ts`：内容查看与拖拽组件
- `ui/src/ui/native-dialog-bridge.ts`、`views/native-dialog-overlay.ts`：原生对话框代理
- `ui/src/ui/app-approvals-banner.ts`、`app-tool-stream.ts`：审批横幅与压缩提示
- `ui/src/ui/setup-wizard.ts`、`views/setup-wizard.ts`：版本门控与引导界面
- `ui/src/ui/strings.ts`、`config-field-labels.ts`：最小 i18n 与配置字段双语文案
- `src/main.go`、`src/wails-bootstrap/index.html`：Wails 窗口与启动页
- `deploy/PACKAGING.md`、`deploy/windows/openocta-installer.nsi`、`deploy/macos/build-app.sh`、`deploy/openocta.service`、`deploy/Dockerfile`：跨端打包
