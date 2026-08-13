# Jan 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：静态源码核对（Grep + 全文 Read）。UI 机制以 `web-app/src` 公共组件/Provider/全局对话框与 `index.html` 装配为主，Tauri 侧核对 `src-tauri/src/core/setup.rs`、`lib.rs`、`tauri.conf.json` 的主题/窗口/托盘/退出路径；依赖库（Radix、vaul、sonner、Tailwind 4）内部行为未下钻依赖源码，一律标"未核实"；2026-08-13 追加主题体系专项核对（主题市场/导入导出、壁纸、自定义 CSS、色阶生成、字体/密度/圆角设置入口与强调色 token 覆盖深度）
>
> 调查范围：界面栈与根装配、Provider/Portal/Toast Host、弹窗/浮层/菜单、Toast 与加载/空状态/错误反馈、主题与 CSS token 链路（含 Tauri 原生层接入）、响应式与窗口适配、图片/拖放/剪贴板等常见内容交互、状态所有权与持久化；聊天主链交点（Composer 附件 toast、线程页 banner、搜索导航等）由 [`../Chat UI/Jan-ChatUI调查笔记.md`](<../Chat UI/Jan-ChatUI调查笔记.md>) 记录，会话/请求/渲染数据语义分别归会话与消息管理、对话请求与上下文、消息渲染器类目。同日追加主题能力边界核对（结论见 §4 末小节）。未运行构建、未运行应用
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 是 React 19 + Tailwind CSS 4 + TanStack Router 的单一 web-app（`web-app/`），桌面（Tauri 2）/移动共用同一前端 bundle，界面基础设施全部在 web 侧：shadcn 风格 `components/ui`（Radix 全家族）+ sonner Toast + vaul Drawer，无自研设计系统。根装配是"ServiceHubProvider 先初始化并水合设置 store、再渲染 children"的门控模式（`routes/__root.tsx`），全局对话框（ErrorDialog、附件摄取确认、llamacpp 退出拦截等）直接挂在根布局上；辅助窗口（日志/系统监控）复用同一 bundle，但跳过扩展加载。

主题权威源是 zustand `useTheme` store（桌面端持久化到 Rust settings.json 而非 webview localStorage），`index.html` 内联脚本做首帧防闪烁，`ThemeProvider` 经 matchMedia + Tauri `theme-changed` 事件（Linux 走 XDG Portal D-Bus）跟随系统，切换时 `TauriThemeService` 把显式主题推送到所有窗口。CSS token 遵循无前缀 Shadcn 契约，字号全系由 `--font-size-base` 派生，强调色（11 色板）直接写行内 CSS 变量 `--primary`/`--sidebar`。强调色仅覆盖这两个变量（无色阶生成、不改写 `--primary-foreground`），且静态 `:root` 默认值（`--sidebar:#194D24`）与运行时默认 gray 色板不一致，水合前短暂可见；未发现主题市场/导入导出、壁纸、自定义 CSS、运行时字体切换、密度与圆角设置等能力（专项核对范围见 §4 末小节）。响应式主要是 shadcn Sidebar 的 768px 移动端断点（Sheet 化）+ 可拖拽侧栏宽度（14–20rem，自动折叠阈值），窗口最小尺寸本次未找到任何配置。

弹窗以组件内 state 或全局 zustand 门控 store 驱动，无命令式弹窗服务；Esc/遮罩/焦点行为交给 Radix 默认实现（未下钻核实）。Toast 全部走 sonner，位置/偏移/数量集中配置，无系统通知通道。图片无灯箱（`ImageModal` 未接入消费），剪贴板操作分散为各组件直接调 `navigator.clipboard`。发现两处主题键名不一致（`window/tauri.ts` 读 `jan-theme`、`index.html` 内联脚本读 `theme`，均与 Tauri 下实际持久化位置脱节）。

## 系统边界与总体装配

### 界面栈

- **框架**：React 19.0、Vite 6、Tailwind CSS 4（`@tailwindcss/vite`，`@theme inline` 方案）、TanStack Router（文件路由，`routeTree.gen.ts` 自动生成）、zustand 5（含 persist 中间件）、TanStack Virtual。
- **公共组件层**：`web-app/src/components/ui/` 27 个 shadcn 风格基础组件（dialog/sheet/drawer/dropdown-menu/popover/tooltip/hover-card/sidebar/sonner/skeleton 等，`package.json:29-107` 的 Radix 依赖与之对应）；无内部设计系统包（对比 Cherry Studio 的 `@cherrystudio/ui`）。
- **非通用层**：`containers/`（业务容器与 40 余个对话框组件）、`hooks/`（大量 zustand store 封装）、`providers/`（全局 Provider）。

### 启动装配与 Provider 栈

`web-app/src/main.tsx` 的 `boot()`（L82-106）顺序：装控制台日志转发 → 移动端 viewport 注入（禁用缩放 + safe-area padding，L14-49）→ 全局阻止浏览器默认拖放（L52-59）→ 消费工厂重置哨兵 `take_pending_webdata_reset` 并剪除 localStorage 标志（L71-80，注释说明必须赶在任何 store 模块 import 前，因为 zustand persist 在 import 时同步水合）→ 动态 import 路由与 i18n → `createRouter` 渲染。

`routes/__root.tsx` 的 `RootLayout`（L105-141）是唯一应用根：

```text
ServiceHubProvider          // 初始化 ServiceHub + 后端存储迁移 + 水合全部设置 store，就绪后才渲染 children
├─ ThemeProvider            // 维护 <html> dark 类、系统主题跟随（见第 4 节）
├─ InterfaceProvider        // 字号/强调色 CSS 变量
├─ ToasterProvider          // sonner <Toaster> 全局配置
├─ TranslationProvider      // i18next 语言切换（useGeneralSetting.currentLanguage 驱动）
│  └─ ExtensionProvider     // 注册并加载扩展，完成后才渲染 children；20s 看门狗（ExtensionProvider.tsx:63-66）
│     ├─ DataProvider       // 数据装载（providers/MCP/assistants/threads/deeplink/更新检查）
│     ├─ GlobalEventHandler // 全局事件（settingsChanged、硬件探测）
│     ├─ DownloadEventListener
│     └─ AppLayout 或 LogsLayout（按路由：/logs、/system-monitor、/local-api-server/logs）
└─ 根级全局对话框（TranslationProvider 内）：AttachmentIngestionDialog / ErrorDialog /
   LlamacppBusyOnExitDialog / LlamacppOomListener / MissingDependenciesDialog / OutOfContextPromiseModal
```

`AppLayout`（`__root.tsx:40-86`）用 `SidebarProvider`（受 `useLeftPanel` 控制）+ `WindowControls`（Windows/Linux 自绘标题栏按钮）+ `WindowResizeGrips`（仅 Linux，`decorations:false` 的 Wayland 窗口无合成器 resize 手柄，用 8 个隐形 grip 转发 `startResizeDragging`，`WindowResizeGrips.tsx:14-25`）+ Tauri 顶部 48px 拖拽区 + 常驻的 `DialogAppUpdater`（更新提示为 fixed 右下角卡片，`AppUpdater.tsx:48-53`，非 Dialog）与 `BackendUpdater`。`LogsLayout` 是无侧栏的简化布局（`__root.tsx:88-103`）。

**装配门控**：`ServiceHubProvider`（`providers/ServiceHubProvider.tsx:14-33`）`initializeServiceHub()` 后先跑 localStorage→后端迁移（`migrateLocalStorageToBackend`，一次性，迁移后**不清理** localStorage，按降级兼容策略保留，`migrateLocalStorageSettings.ts:6-13,148-185`），再 `hydrateBackendStores()`（`lib/hydrateStores.ts:56-61`，先 `useTheme` 后其余 19 个 store，因 InterfaceProvider 水合回调读 `useTheme.getState().isDark`），最后才渲染 children。失败时也照常渲染以显示错误状态（`ServiceHubProvider.tsx:27-29`）。

### web-app 与 Tauri 的装配关系（多窗口）

- 桌面窗口由 Rust 侧创建：主窗口无显式配置（`tauri.conf.json` 无 `windows` 段），日志/系统监控/API 日志等辅助窗口由前端 `services/window/tauri.ts` 运行时 `new WebviewWindow` 创建（L43-55），固定 800×600 / 1000×700，可调大小居中（`openLogsWindow` L95-110、`openSystemMonitorWindow` L112-127）。
- 辅助窗口复用同一 bundle 与 routeTree（`logs.tsx`、`system-monitor.tsx` 等路由），但 `ExtensionProvider.isMainWindow()`（`ExtensionProvider.tsx:14-20`）按 webview label 跳过扩展加载——辅助窗口的 Tauri capabilities 不含硬件/llamacpp 等权限，加载会触发 ACL 拒绝并双开 llama-server。
- 每窗口独立渲染一套 Provider：Toaster、ThemeProvider 各自挂载；跨窗口主题经 `TauriThemeService.setTheme` 轮询所有窗口 `window.setTheme`（`services/theme/tauri.ts:16-34`）与 `theme-changed` 事件监听（`services/window/tauri.ts:173-195`）同步。
- 移动端（iOS/Android）走同一 bundle + `services/core/mobile.ts`（SQLite 持久化），移动端发行成熟度未确认（仓库分布笔记 §5）。

## 1. 界面栈、公共组件与状态所有权

### 状态所有权

三层并存，公共界面状态几乎全部是**模块级 zustand 单例**（React 组件树之外）：

| 状态 | 所有者 | 持久化 |
|---|---|---|
| 主题 `useTheme`（activeTheme/isDark） | 模块级 zustand + persist | `backendStorage`（桌面→Rust settings.json） |
| 界面设置 `useInterfaceSettings`（字号/强调色/消息缩放/Toast 位置等） | 模块级 zustand + persist | 同上 |
| 侧栏 `useLeftPanel`（open/width） | 模块级 zustand + persist | 同上（另有 shadcn 侧栏自身的 cookie 双写，见第 5 节） |
| 搜索/项目对话框开关（`useSearchDialog`/`useProjectDialog`） | 模块级 zustand（不持久化） | 无 |
| 附件摄取确认 `useAttachmentIngestionPrompt` | 模块级 zustand（Promise resolver 模式） | 无 |
| 业务对话框开关（RenameThreadDialog、EditMessageDialog 等） | 组件内 useState | 无 |

- **持久化基座**：`lib/backendStorage.ts:22-61` 实现 zustand `StateStorage` 接口——桌面端经 ServiceHub 调 Rust `settings_get/set/remove`（落盘 `<jan_data>/settings.json`，注释说明为了让 jan-cli 等进程外消费者可读）；Web 构建退化为 localStorage。要求使用方 `skipHydration: true`，由 `hydrateBackendStores()` 在 ServiceHub 就绪后显式水合。`lastWritten` Map 跳过未变化的重复写（zustand 每次 set 都触发 setItem，L16-20）。
- **消费方式**：业务组件直接 `useXxx()`（hooks 导出 store），快捷键/事件回调里用 `useXxx.getState()`（如 `KeyboardShortcuts.tsx:29-34`）。ServiceHub（`services/index.ts:56-79`）提供 20 个平台服务（theme/window/events/dialog/opener/threads/messages 等），桌面/移动在 `initialize()` 动态 import 各自的 Tauri/Mobile 实现（L108-211），web 构建用 Default 实现。
- **错误状态**：全局错误弹窗内容由 `useAppState.errorMessage` 持有（`ErrorDialog.tsx:19-20`）；llamacpp 路由错误经 `LlamacppOomListener` 监听 Rust 事件写入 `useAppState`（oom/backend/load-progress/unload，`LlamacppOomListener.tsx:27-74`），banner 呈现归 Chat UI 笔记。

### 弹窗状态门控模式（非命令式）

项目没有 Cherry Studio 那样的命令式 popup service；跨组件触发的弹窗用"全局 zustand 门控 + 根级渲染"模式：`useSearchDialog.open` 由快捷键置真、`SearchDialog` 在 NavMain 里挂载消费；`useAttachmentIngestionPrompt.showPrompt` 返回 Promise、把 resolver 存进 store，根级 `AttachmentIngestionDialog` 渲染选择后 `choose/cancel` 调 resolver 并关弹窗（`hooks/useAttachmentIngestionPrompt.ts:31-52`、`dialogs/AttachmentIngestionDialog.tsx:20-22` 用 `onInteractOutside` 阻止遮罩点击关闭）。这与 Cherry 的 PopupHost 单例是相反的设计取向（Cherry 笔记 §2）。

## 2. 弹窗、浮层与菜单

### 基础组件与层级

- **Dialog**：`components/ui/dialog.tsx` 是标准 shadcn Radix 封装——`DialogPortal` + `DialogOverlay`（fixed inset-0 z-50 bg-black/50 backdrop-blur）+ `DialogContent`（z-50 居中，`max-w-[calc(100%-2rem)] sm:max-w-lg lg:max-w-2xl xl:max-w-3xl`，`max-h-[85vh] overflow-y-auto`，L63）；`aria-describedby={undefined}` 显式关闭默认描述关联（L61）。进出场动画走 `data-[state=open/closed]` + tw-animate-css 类（fade/zoom，L63）。
- **Sheet**：`components/ui/sheet.tsx` 同样基于 Radix Dialog（L4），四方向滑入，`w-3/4 sm:max-w-sm`；Windows/Linux 下右侧 Sheet 会按标题栏按钮布局加 `pt-15` 偏移，避免被 z-[60] 的自绘窗口按钮遮挡（L58-63,79,88）。业务消费：模型设置面板（`ModelSetting.tsx:260-384`）。
- **Drawer**：`components/ui/drawer.tsx` 基于 **vaul**（L1-2），四方向，底部方向带把手条（L66）；业务上独立 Drawer 未见消费，其主要消费者是 DropDrawer 的移动端路径。
- **DropdownMenu/Popover/Tooltip/HoverCard**：Radix 标准封装，z-50 统一（`dropdown-menu.tsx:43`、`popover.tsx:31`、`tooltip.tsx:48`、`hover-card.tsx:33`）。
- **层级纪律**：Radix 浮层统一 z-50；窗口控件 z-[60]（`WindowControls.tsx:78,85`）与拖拽区 z-20、初始载入器 z-9999（`index.html:41`）；业务里另有 `ModelCombobox` 自绘的下拉列表用 `fixed z-9999`（`ModelCombobox.tsx:453`）——属于未走 Radix Portal 的少数自绘浮层。
- **Esc/遮罩/焦点/滚动锁定**：未发现项目级覆盖，默认行为全部由 Radix `Dialog`（Esc 关闭、遮罩点击关闭、焦点圈闭与归还、`body` 滚动锁定）与 vaul 提供；依赖内部实现未下钻，**未核实**。业务侧仅在少数对话框显式干预：`AttachmentIngestionDialog.tsx:22` 阻止遮罩点击、`ErrorDialog.tsx:47` 用 `showCloseButton={false}` 强制走按钮关闭。

### DropDrawer：下拉菜单的移动端自适应

`components/ui/dropdrawer.tsx`（974 行）是项目自研的"桌面 DropdownMenu ↔ 移动端 Drawer"双模组件：`DropDrawer` 按 `useIsMobile()` 在 vaul Drawer 与 Radix DropdownMenu 间切换（L42-62）；移动端路径实现了完整子菜单栈（`submenuStack` + `submenuContentCache`，点击子菜单在 Drawer 内前进/后退，L93-149,256-270）与 framer-motion `AnimatePresence` 页面级滑入滑出（L310-328）。唯一业务消费是工具下拉 `DropdownToolsAvailable.tsx:14`（聊天主链，细节在 Chat UI 笔记）。这是本快照中 framer-motion 的唯一接入点（`package.json:67` 声明依赖，仅此一处 import）。

### 全局对话框清单（根级挂载）

`__root.tsx:131-136` 常驻的六个全局对话框/监听器均基于上述 Dialog：`ErrorDialog`（useAppState.errorMessage 门控）、`AttachmentIngestionDialog`、`LlamacppBusyOnExitDialog`（听 Rust `llamacpp-close-attempt`/`llamacpp-busy-on-exit` 事件，退出被拦时先 `toast.loading` 再换确认框，`LlamacppBusyOnExitDialog.tsx:28-40`）、`LlamacppOomListener`、`MissingDependenciesDialog`、`OutOfContextPromiseModal`。业务对话框（重命名/删除线程、编辑/删除消息、搜索、导入模型等 30+ 个）按需在各自组件内挂载，无统一注册表。

## 3. 通知、加载态与错误反馈

### Toast（sonner）

- **装配**：`ToasterProvider`（`providers/ToasterProvider.tsx:5-33`）全局一份 `<Toaster richColors>`；位置来自 `useInterfaceSettings.notificationPosition`（四角可选），默认 Windows+Tauri 为 bottom-right（避开自绘标题栏，`utils/toastPlacement.ts:22-28`），其余平台 top-right；`offset` 在顶部位置时叠加 48px Tauri 拖拽区（L30-49）；`visibleToasts={5}` 限制堆叠数；toast 样式统一禁用文本选择。
- **主题接入**：`components/ui/sonner.tsx` 从 `useTheme` 订阅 `isDark` 传 sonner `theme`；中性 toast 的底色经 `index.css` 的 `.toaster` 类用 `color-mix` 混入 `--primary` 强调色（`index.css:8-15`）——注释说明必须用类而非行内样式，因为 WebView2 的 CSP hash 掉 sonner 运行时注入的 `<style>`（另见 `tauri.conf.json:30` 的 `style-src 'unsafe-inline'` 与 `dangerousDisableAssetCspModification`）。
- **使用模式**：直接 `toast.success/error/warning/info`（src 内 34 个文件 import）；常驻提示用"命名 id + 完成时 dismiss"配对——唯一一处 `toast.loading` 是 llamacpp 退出拦截（`LlamacppBusyOnExitDialog.tsx:29-38`），模型下载校验用 `toast.info(..., { id, duration: Infinity })` 常驻 + `toast.dismiss(id)` 收尾（`useDownloadEvents.ts:89-116`，`toast.loading` 全 src 仅此两文件模式、无 `toast.promise`）；未发现 sonner 的 promise 参数用法。聊天主链的附件摄取失败/去重提示等用例见 Chat UI 笔记 §3。
- **系统通知**：本次未找到任何系统通知通道——`web-app/src` 搜索 `Notification`（浏览器 API 或 Tauri 插件）仅命中 toast 位置相关符号；模型下载完成、回复完成等均为站内 toast。

### 加载态

- **启动载入器**：`index.html` 内联 `#initial-loader` 全屏启动画面（z-9999，可拖拽），标题栏下文字由 `ExtensionProvider` 实时更新为扩展注册/加载进度（`ExtensionProvider.tsx:78-83`）；扩展就绪后给 `body` 加 `loaded` 类淡出并移除（L86-100）。静态 CSS 提供 light/dark 两套底色与波浪 logo 动画。
- **页面/列表加载**：Hub 页手写 5 条骨架卡片（`animate-pulse`，`routes/hub/index.tsx:467-490`）；线程列表加载中显示 Loader2 旋转图标（`NavChats.tsx:33-38`）；模型加载/卸载用 `ModelLoader` spinner（`containers/loaders/ModelLoader.tsx`）；`Skeleton` 基础组件存在（`ui/skeleton.tsx`）但业务页面（Hub 之外）使用较少；消息流式/工具执行的加载呈现归 Chat UI/消息渲染器笔记。
- **进度反馈**：模型下载进度在侧栏 `DownloadManagement`（下载列表 + toast 事件，`DownloadManegement.tsx:72-83`）；llamacpp 模型加载进度经 Rust 事件推入 `useAppState.updateModelLoadProgress`（`LlamacppOomListener.tsx:50-64`）。

### 空状态与错误边界

- **空状态**：无统一组件，各处就地渲染文本/图标（Hub 无结果 `routes/hub/index.tsx:491-496`、搜索无结果 `SearchDialog.tsx:233-243`、下载列表空、ProjectFiles 空、后端历史空等），多为 `text-muted-foreground` 居中文本。
- **错误边界**：TanStack Router 根路由 `errorComponent` → `GlobalError`（`__root.tsx:37`，整页红底错误页，含刷新/联系链接与可展开的 stack，`containers/GlobalError.tsx`）；无其他业务级 ErrorBoundary 组件（本次未找到）。全局运行错误走 `ErrorDialog` 弹窗（复制错误、可展开详情，`ErrorDialog.tsx:46-124`）。聊天主链的错误 banner 与"隐藏失败消息"归 Chat UI 笔记 §5。

## 4. 主题、视觉 token 与持久化

### 权威源与状态链

权威源是前端 zustand `useTheme`（`hooks/useTheme.ts:23-73`）：

```text
用户切换（ThemeSwitcher）→ setTheme(activeTheme)
  → 先 commit 本地状态（注释：避免 native setTheme 触发的 theme-changed 事件
    在 activeTheme 还是旧值时覆盖 isDark，useTheme.ts:30-44）
  → ServiceHub.theme().setTheme()
     → Tauri：遍历所有 WebviewWindow 调 window.setTheme（services/theme/tauri.ts:16-34）
     → 桌面 Linux 另经 Rust set_gtk_prefer_dark 翻转 GTK HeaderBar（src-tauri/src/core/setup.rs:466-482）
```

- **持久化**：`persist` 挂 `backendStorage`（键 `theme`，`constants/localStorage.ts:5`），`skipHydration: true`，`onRehydrateStorage` 里按 activeTheme 重算 isDark（丢弃陈旧值，`useTheme.ts:63-71`）；水合由 `hydrateBackendStores` 先行（见装配节）。
- **应用**：`ThemeProvider` 的 effect 给 `document.documentElement` 加/去 `dark` 类（`providers/ThemeProvider.tsx:8-19`），CSS 侧 `@custom-variant dark` 让 Tailwind 类基于 `.dark` 祖先生效（`index.css:20`）。

### 系统跟随与跨窗口同步

`ThemeProvider` 第二个 effect（`providers/ThemeProvider.tsx:21-76`）只认 `activeTheme === 'auto'` 时更新 isDark：

- **Web/Windows/macOS**：`matchMedia('(prefers-color-scheme: dark)')` 事件（L33-35）；Tauri 下另订阅 `theme-changed` 事件并初次 `get_system_theme` 对齐（L37-61）。Rust 侧主窗口 `WindowEvent::ThemeChanged` 转发为 `theme-changed`（`setup.rs:565-583`）。
- **Linux 特例**：注释明确 WebKitGTK 的 prefers-color-scheme 不可靠，权威改为 Rust 侧 XDG Desktop Portal 读取 + D-Bus `SettingChanged` 信号（`setup.rs:510-563`，KDE/GNOME 双覆盖），经 `theme-changed` 事件转发；`get_system_theme` 优先 portal、回退 `window.theme()`（`setup.rs:484-504`）。
- **跨窗口**：显式主题经 `TauriThemeService` 全窗口推送；辅助窗口创建时再挂 `theme-changed` 监听（`services/window/tauri.ts:173-195`）。

### 首屏闪烁防护（两层）

1. `index.html` 内联脚本在首次绘制前同步读 `localStorage('theme')` 的 `activeTheme`，dark 或 auto+系统 dark 时立即给 `<html>` 加 `dark` 类（`index.html:105-127`）；初始载入器也提供 `.dark #initial-loader` 深色底（L45-47）。
2. React 侧 `ServiceHubProvider` 水合完成才渲染 children，`ThemeProvider` 首帧即按 store 状态定类，不出现"先亮后暗"。

**已确认的不一致**：该内联脚本读的是 localStorage 键 `theme`，而桌面端主题自迁移起持久化在 Rust settings.json；迁移策略有意不清理 localStorage（`migrateLocalStorageSettings.ts:10-12`），因此 Tauri 下脚本读到的是迁移前的历史值，首帧可能短暂错误（随后由 ThemeProvider 纠正）。同理 `TauriWindowService.createWebviewWindow` 创建辅助窗口时读 localStorage 键 `jan-theme`（`services/window/tauri.ts:15`）——全仓库无任何代码写入该键（仅测试），实际 store 键为 `theme` 且不在 localStorage；新建窗口 `theme` 参数恒为 `undefined`（交给系统），窗口创建后依赖 `theme-changed` 监听与主题切换推送补正。两者均为代码级确认的键名/存储位置脱节，实际视觉影响未运行验证。

### CSS token 体系

- **Shadcn 无前缀契约**：`index.css:94-161` 的 `:root`/`.dark` 定义 `--background/--foreground/--primary/--sidebar-*` 等原始 token（oklch，无前缀，可直接套第三方 Shadcn 主题）；`@theme inline`（L22-77）把 `--color-*` 系列映射到这些变量，供 Tailwind 工具类消费；`--radius` 派生 `--radius-sm/md/lg/xl`。
- **字号体系**：`--font-size-base`（默认 16px，InterfaceProvider 设置 `document.documentElement.style.setProperty`，`InterfaceProvider.tsx:15-18`）派生 `--text-xs…9xl` 全刻度（`index.css:62-75`）；消息区有独立的 `.message-zoom` 重声明（L83-92，注释说明 :root 的 calc 在继承前已替换，覆盖 `--font-size-base` 无效，必须在该元素上重声明刻度），供 `useMessageZoom` 的 Ctrl/Cmd+滚轮与快捷键缩放聊天文字（`useMessageZoom.ts:21-53`，webview 原生缩放已关）。
- **强调色**：`useInterfaceSettings.ACCENT_COLORS` 11 色板（gray/red/orange/green/…，`useInterfaceSettings.ts:14-92`），`applyAccentColorToDOM` 直接写行内 CSS 变量 `--primary` 与 `--sidebar`（亮/暗各一值，L97-106）；`InterfaceProvider`（L21-30）与模块级 `useTheme.subscribe`（L348-355，主题切换时重算 sidebar 色）双路应用。
- **字体**：Inter（全字重，含斜体）+ StudioFeixenSans（标题字体 `--font-studio`），`styles/font.css` 本地 @font-face，无运行时字体切换（本次未找到自定义字体设置）。

### 第三方组件接入

sonner 经 `theme` prop + `.toaster` 类混入强调色（见 §3）；Radix 浮层全部走 Tailwind 工具类 + CSS 变量，无独立 token 层；第三方扩展渲染（Streamdown、Katex、Shiki）不参与主题 token（markdown 样式在 `styles/markdown.css`，归消息渲染器笔记）。

### 主题能力边界（2026-08-13 专项核对）

- **主题市场/导入导出**：本次未找到——Grep `web-app/src` 无 `importTheme`/`exportTheme`/`theme.json`/`themeStore`/`installTheme` 等符号，`web-app` 目录 glob 无 `themes/` 子目录；主题仅 light/dark/auto 三态（`containers/ThemeSwitcher.tsx:23-27`），无"下载主题"入口。
- **壁纸/背景图**：本次未找到——`wallpaper`/`backgroundImage` 仅命中 shimmer 加载动画自身的渐变动画（`components/ai-elements/shimmer.tsx:46`），非用户可配置的背景机制。
- **自定义 CSS**：本次未找到——`customCss`/`userStyle` 无命中，无用户样式注入通道。
- **强调色覆盖深度**：`applyAccentColorToDOM` 只写 `--primary` 与 `--sidebar` 两个变量（`useInterfaceSettings.ts:97-106`）；`--primary-foreground`、`--sidebar-primary/-accent/-border/-ring` 家族保持静态 oklch 默认（`index.css:103,120-126`），前景对比度不随强调色重算；**无色阶生成**——11 色板每色仅硬编码 primary 单值 + sidebar 亮/暗各一值，无色调派生逻辑（`useInterfaceSettings.ts:14-92`）。另注意 gray 色板的 primary 是品牌橙 `#f17455`（L19）而非灰色。
- **静态默认 token 不一致**：`:root`/`.dark` 静态 `--sidebar: #194D24`（Emerald 暗色 sidebar 值，亮暗相同，`index.css:119,153`）、`--primary: oklch(0.7003 0.1611 35.09)`（L102,136），与 ACCENT_COLORS 默认 gray 的 `#f1f1f1/#171717`、`#f17455` 不一致；React 水合前（首帧/启动屏期间）显示的是静态值，属静态确认的边界，视觉影响未运行验证。
- **字号与圆角设置入口**：字号 4 档 14/16/18/20px（`fontSizeOptions`，`useInterfaceSettings.ts:168-173`），旧值 15px 在水合时迁移到 16px（L296-299）；`--radius: 0.625rem`（`index.css:95`）仅静态定义，无运行时设置入口，圆角不可调；密度类设置本次未找到（grep `density`/`compact` 仅命中会话压缩与 Token 计数器紧凑布局，非界面密度）。
- **首帧脚本范围**：`index.html:105-127` 内联脚本只同步处理 dark 类；强调色与字号需等 React 水合后由 `InterfaceProvider`（L15-30）与 `onRehydrateStorage`（`useInterfaceSettings.ts:294-314`）应用，首帧为静态默认值。

## 5. 响应式、移动端与窗口适配

- **断点**：唯一 JS 断点是 `use-mobile.ts` 的 **768px**（`MOBILE_BREAKPOINT=768`，L3-18）；CSS 侧用 Tailwind `md:`（768px）与 `sm:`（640px，如对话框宽度、settings 卡片横排，`ui/dialog.tsx:63`、`settings/interface.tsx:61`）。
- **侧栏**：shadcn `Sidebar`（`ui/sidebar.tsx`）variant="floating" collapsible="offcanvas"（`left-sidebar/index.tsx:26`）。桌面固定 `md:block` 面板（L277），**移动端自动换成 Sheet 抽屉**（`openMobile` 状态 + `Sheet`，L254-272，`toggleSidebar` 按 `isMobile` 分派 L122-131）。展开/折叠状态双持久化：shadcn 自身写 cookie `sidebar:state`（L25-26,116）+ `useLeftPanel` zustand（backend storage，`useLeftPanel.ts:15-31`）。
- **侧栏拖拽缩放**：`SidebarRail`（L353-410）接 `useSidebarResize`（`hooks/use-sidebar-resize.ts`）——鼠标拖 rail 调宽（14–20rem，`sidebar.tsx:33-34`），拖过最小宽度的 `autoCollapseThreshold`（默认 1.5，即 14rem×1.5）自动折叠、反向拖过 `expandThreshold` 自动展开（`use-sidebar-resize.ts:136-53,333-345`）；宽度写 cookie `sidebar:width`（L373-374）与 `useLeftPanel` 双轨。拖拽期间给容器加 `data-dragging` 以关闭 transition（`sidebar.tsx:294-309`）。
- **窗口最小尺寸**：本次未找到——`tauri.conf.json` 无 `windows` 段，`src-tauri` 全文搜索 `min_inner_size/set_min_size` 无命中，web-app 无 `setMinSize` 调用；窗口初始尺寸由 Tauri 默认值与运行时创建参数（日志窗 800×600 等）决定。
- **移动端**：`main.tsx:14-49` 注入禁缩放 viewport 与 safe-area padding；`src-tauri` 提供 iOS/Android 构建入口（`package.json:29-33`，仓库分布笔记 §5），持久化换 SQLite；界面行为未运行验证。
- **窗口与浮层协作**：Toast 顶部偏移避开 48px 拖拽区（§3）；右侧 Sheet 按标题栏布局加 `pt-15`（§2）；`WindowControls` 自绘按钮仅在 Windows/Linux 渲染、Linux 上按 DE 布局左右自适应（`WindowControls.tsx:27-44` + Rust `get_titlebar_layout` 命令与 `TitlebarLayout`，`setup.rs:348-461`）。

## 6. 图片、附件、拖放与常见内容交互

- **图片预览**：无灯箱/查看器。`containers/dialogs/ImageModal.tsx` 是仅有的"查看图片"Dialog（标题 + 内联 `<img>`，max-h-70vh，`onError` 隐藏），但**全 src 无消费方**（本次未找到 import，搜索 `ImageModal` 仅命中自身定义）。消息内图片（附件/工具输出）均内联 `<img>` 渲染：附件图片经 `convertFileSrc`/dataURL（`ChatInput.tsx:1288-1289` 等，附件摄取归 Chat UI 笔记 §3），工具输出图用 `ToolImage`（base64→data:image 前缀补齐，`components/ai-elements/tool.tsx:391-429`，归消息渲染器笔记）。无缩放/旋转/下载按钮。
- **剪贴板**：无统一抽象，各组件直接 `navigator.clipboard.writeText`（17 处：CopyButton、code-block 复制、MarkdownTable、secret-input、ApiKeyInput、ErrorDialog 复制错误等）；`CopyButton`（`containers/CopyButton.tsx:9`）是最接近的共享复制组件。消息区粘贴图片走 `navigator.clipboard.read` 回退路径（`ChatInput.tsx:1672-1677`，Chat UI 笔记 §3）。
- **拖放**：全局 `preventDefaultFileDrop` 禁止浏览器默认打开拖入文件（`main.tsx:52-59`）；Composer 文件拖入（按能力分流、输入框高亮反馈）归 Chat UI 笔记 §3；拖拽排序仅一处——MCP 服务器表单的环境变量列表用 **@dnd-kit**（core+sortable，`AddEditMCPServer.tsx:27-34`，可拖动项/排序容器/`CSS.Transform`），是 `@dnd-kit` 在 src 中的全部消费点。
- **上传/附件反馈**：文档上传（ProjectFiles）、模型导入（ImportLlamacppModelDialog/ImportMlxModelDialog，走 `services/dialog` 的原生文件选择器，`services/dialog/tauri.ts`）均为 toast 反馈（成功/失败/去重提示）+ 大小/类型限制；附件摄取方式选择用全局 `AttachmentIngestionDialog`（§1）。附件解析偏好（inline/embeddings）的发送决策归对话请求笔记。
- **选中复制**：消息文本复制（CopyButton 全量复制）在 Chat UI 笔记 §6；无选区右键菜单等富文本交互（本次未找到 ContextMenu 业务消费，Radix ContextMenu 组件未封装进 ui/ 层）。

## 7. 设计取舍与已确认边界

- **无命令式弹窗服务**：跨组件弹窗走"全局 zustand 门控 + Promise resolver"，与 Cherry Studio 的 PopupService 单例相反；代价是每个弹窗要单独建 store/挂载点，换来的是不依赖 Provider 层级、可在任何组件/事件回调触发。
- **门控式启动**：ServiceHubProvider 与 ExtensionProvider 两层"就绪才渲染"，配合 index.html 静态启动屏，避免水合前闪默认值；20s 看门狗保证扩展卡死不至于白屏（`ExtensionProvider.tsx:63-66`）。
- **主题权威在 Web 侧、原生侧协作**：与 Cherry 的"主进程权威"不同，Jan 的权威状态在渲染层 zustand，Rust 只负责系统主题感知（portal/ThemeChanged）与原生 UI 跟随（GTK prefer-dark、window.setTheme）；两侧靠 `theme-changed` 事件单向对齐。
- **后端存储迁移不清理 localStorage**：为了降级兼容，但导致 index.html 防闪烁脚本与 TauriWindowService 读到的 localStorage 主题值可能陈旧（§4），属已确认的静态不一致。
- **强调色最小覆盖 + 静态默认残留**：运行时只写 `--primary`/`--sidebar` 两变量（其余 token 族静态），而静态 `:root` 默认值又与 gray 色板不一致，水合前短暂显示静态色；属已确认的静态边界（§4 末小节）。
- **未使用依赖**（声明于 `web-app/package.json`，src 内本次未找到 import/配置）：`next-themes`、`react-resizable-panels`、`matter-js`；`vite-plugin-pwa` 在 devDependencies 但未出现在 `vite.config.ts` 插件列表。
- **浮层层级**：Radix 统一 z-50、窗口控件 z-[60]、启动屏 z-9999、ModelCombobox 自绘列表 z-9999；无 z-index 令牌层。
- **依赖清单声明 ≠ 使用**：framer-motion 仅 DropDrawer 一处、@dnd-kit 仅 MCP 表单一处，均按此事实记录。

## 8. 未验证事项

- 全部视觉/动画/焦点/滚动锁定/Esc 行为：Radix Dialog、vaul Drawer、sonner、tw-animate-css 的内部实现未下钻依赖源码，未运行应用验证。
- Linux XDG Portal 主题读取、GTK prefer-dark、Wayland resize grip、托盘（`ENABLE_SYSTEM_TRAY_ICON=true` 构建时才启用，`lib.rs:332-336`）未运行验证。
- 移动端（iOS/Android）界面行为与发行成熟度未验证。
- 多窗口（日志/系统监控）并发、跨窗口主题同步的实际表现未验证。
- 主题键名不一致（`jan-theme`/`theme`/backend storage）的视觉影响未运行确认，仅静态推断。
- 强调色/字号在水合后应用的实际闪烁时序、静态默认 token（`--sidebar:#194D24` 等）在首帧的呈现、gray 色板 primary 非灰色的观感影响均未运行验证，仅静态推断。
- `ImageModal` 无消费方、"无系统通知"、ContextMenu 未接入等"未找到"结论的检查范围：Grep `web-app/src` 全目录（`ImageModal`、`Notification`、`ContextMenu`、`next-themes`、`react-resizable-panels`、`matter-js`、`VitePWA`），未覆盖 node_modules 与构建产物。
- 主题能力"未找到"结论的检查范围（2026-08-13 专项）：Grep `web-app/src`（`importTheme`、`exportTheme`、`theme.json`、`themeStore`、`installTheme`、`wallpaper`、`backgroundImage`、`customCss`、`userStyle`、`density`/`compact`）+ glob `web-app` 全目录 `themes/` 目录与 `theme*.json` 文件，未覆盖 node_modules 与构建产物。

## 9. 关键源码索引

- 装配：`web-app/src/main.tsx`、`web-app/src/routes/__root.tsx`、`web-app/src/providers/ServiceHubProvider.tsx`、`ExtensionProvider.tsx`、`web-app/index.html`
- 弹窗/浮层：`web-app/src/components/ui/dialog.tsx`、`sheet.tsx`、`drawer.tsx`、`dropdrawer.tsx`、`sidebar.tsx`、`web-app/src/hooks/useAttachmentIngestionPrompt.ts`、`web-app/src/containers/dialogs/AttachmentIngestionDialog.tsx`
- Toast/反馈：`web-app/src/providers/ToasterProvider.tsx`、`web-app/src/components/ui/sonner.tsx`、`web-app/src/utils/toastPlacement.ts`、`web-app/src/containers/GlobalError.tsx`、`dialogs/ErrorDialog.tsx`
- 主题：`web-app/src/hooks/useTheme.ts`、`providers/ThemeProvider.tsx`、`InterfaceProvider.tsx`、`hooks/useInterfaceSettings.ts`、`lib/backendStorage.ts`、`lib/hydrateStores.ts`、`lib/migrateLocalStorageSettings.ts`、`services/theme/tauri.ts`、`services/window/tauri.ts`、`web-app/src/index.css`、`containers/ThemeSwitcher.tsx`、`FontSizeSwitcher.tsx`、`AccentColorPicker.tsx`、`routes/settings/interface.tsx`、`src-tauri/src/core/setup.rs`、`src-tauri/src/lib.rs`
- 响应式/窗口：`web-app/src/hooks/use-mobile.ts`、`use-sidebar-resize.ts`、`useLeftPanel.ts`、`components/WindowControls.tsx`、`WindowResizeGrips.tsx`、`src-tauri/tauri.conf.json`
- 快捷键：`web-app/src/providers/KeyboardShortcuts.tsx`、`hooks/useHotkeys.ts`、`lib/shortcuts/`、`hooks/useMessageZoom.ts`
- 服务总线：`web-app/src/services/index.ts`、`services/dialog/`、`services/core/`
