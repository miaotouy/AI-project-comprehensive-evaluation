# VCPMobile 应用界面基础设施调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：静态走读 Vue 根装配、Pinia Store、公共覆盖层、主题与原生事件桥接；未启动 Android WebView 或真实系统服务
>
> 调查范围：应用级装配、浮层与物理返回、通知、主题、安全区与移动端适配；不重复调查 Chat Composer、消息气泡和附件业务流程
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 是单个 Vue WebView 表面上的 Android 应用。Vue、Pinia、Vue Router 与 UnoCSS 在 `src/main.ts:1-56` 装配；路由表只保留聊天页，设置、同步、分布式节点、RAG 观察器和日记中心等低频工作区不以 URL 表达，而是由全局覆盖层和虚拟页面栈承载。这样使 Android 物理返回键可按最近打开的页面、对话框、抽屉逐层收回，也使长同步任务能暂时拒绝被返回键卸载。

公共界面层的状态权威在前端 Pinia：覆盖层、通知和主题均由各自 Store 持有；Android 只通过 Tauri 事件或命令补充系统键、Window Insets、通知点击和任务退后台等平台事件。当前静态证据不能确认焦点陷阱、Esc、屏幕阅读器、实际过渡效果、触摸手势和 Android 系统通知表现。

## 系统边界与总体装配

应用入口创建唯一 Vue 实例、安装持久化 Pinia 插件和 Hash 路由，并注册两个全局指令；全局 Vue 错误、浏览器错误和未处理 Promise 拒绝都只写入控制台。根组件在生命周期就绪后依次渲染路由内容、左右抽屉、公共覆盖层、Feature 覆盖层、分享选择器和更新提示，故公共层在业务内容之后挂载并覆盖它（`src/main.ts:1-56`；`src/App.vue:376-514`）。

公共覆盖层集中挂载输入框、确认框、上下文菜单、全屏编辑器和 Toast，并提供单独容器让 Feature 投射业务浮层。低频页面按需加载，日记中心首次打开才固定挂载，保留实例与退场条件；这些是按需加载和局部状态保存策略，并非多窗口或多路由架构（`src/components/GlobalOverlayManager.vue:28-58`；`src/components/FeatureOverlays.vue:20-122`）。

## 1. 浮层、虚拟页面与物理返回

覆盖层 Store 将设置、Agent/群组设置、同步会话、重建会话、Tarven 设置、分布式节点、RAG 观察器和日记中心统一表示为虚拟页面栈。入栈时为页面分配语义层级并注册一个历史项；出栈时同时注销历史项。同步会话在连接或已连接期间拒绝关闭，说明任务状态而非页面组件拥有关闭门禁（`src/core/stores/overlay.ts:15-156`）。

模态历史模块将每个浮层写入浏览器 history，并在主聊天页拦截返回：先交给栈顶关闭回调，空栈时分派应用退出事件，再补回根历史项。根组件先让该栈、会话清空和双击退出逻辑依次消费 Android 返回事件（`src/core/composables/useModalHistory.ts:31-177`；`src/App.vue:324-421`）。这确认了 LIFO 关闭与不可关闭任务的代码路径；浏览器 history 和 Android 返回手势的真实协同尚未运行验证。

视觉层级有一份同步的 CSS 变量、UnoCSS 快捷类和 TypeScript 常量：内容 0、抽屉 20、覆盖层 30、页面基准 40、Sheet 50、对话框 60、编辑器 70、查看器 80、Toast 90、启动层 100、权限门 110。虚拟页面只在基准上增加最多 9 的偏移，避免任意业务组件自行使用高数值（`src/core/constants/layers.ts:23-76`；`src/assets/themes.css:16-27`）。

## 2. 通知、加载与错误反馈

通知 Store 在内存中分别维护历史和活动 Toast。带固定 ID 的活动 Toast 会原位更新，历史记录在 30 秒内去重；非纯 Toast 才进入最多 100 条的历史，抽屉打开或标记为 history-only 时不弹出，普通 Toast 默认三秒移除。审批类通知可以携带操作，Store 将用户决定作为 `tool_approval_response` 发回后端（`src/core/stores/notification.ts:27-200`）。因此通知历史不是持久消息中心，应用重启后的恢复本次未确认。

Toast 容器由全局管理器固定挂载，使用 `TransitionGroup` 渲染 Store 中的活动项（`src/components/ui/ToastManager.vue:9-47`）。启动层、异步 Feature 的 Suspense fallback 与各业务页自身加载/空态共同承担其余反馈；本次没有将这些业务态逐项审计，也未运行验证动画、堆叠上限或通知权限路径。

## 3. 主题、视觉 token 与安全区

主题 Store 从浏览器本地存储读取模式和主题文件名，动态加载主题模块后写入根元素 CSS 变量；模式可为明、暗或跟随系统，系统偏好变化只在跟随模式下重新应用（`src/core/stores/theme.ts:56-279`）。基础 CSS 预设深色变量及安全区回退值，所以静态代码显示它试图在主题模块加载前提供可用初值；无法由此证明没有首屏闪烁。

Android 的标准 safe-area 值若为零，根组件会监听 `vcp-keyboard-inset` 并改写 `--vcp-safe-bottom`；样式表随后以该变量为顶部/底部间距回退（`src/App.vue:25-41`；`src/assets/themes.css:9-10`）。这是一条原生 Window Insets 到 WebView 的适配入口，具体设备、横屏和软键盘动画未运行验证。

## 4. 响应式与常见内容交互

应用以聊天页为唯一 Hash 路由，左右抽屉在根布局中由响应式类控制，抽屉遮罩只在 `md` 以下显示；侧栏开关、全局滑动与硬件返回均在根组件交汇（`src/core/router/index.ts:1-11`；`src/App.vue:401-514`）。这确认了单 WebView 的移动优先布局路径，但没有桌面多窗口实现证据。

根组件还接收系统分享意图，待生命周期就绪后让用户选择 Agent，并把文本或文件准备为后续聊天输入（`src/App.vue:98-223`）。附件查看、文件挑选、上传和 Markdown 内部渲染属于聊天和消息业务链，本笔记没有据此概括为独立的应用级拖放或图片基础设施。

## 设计取舍与已确认边界

- 路由只负责聊天主表面，功能工作区以持久/懒加载的覆盖页接入；这降低了多入口导航的复杂度，但 URL 不表达大多数工作区状态。
- 返回历史同时为页面和短暂对话框服务，页面能声明不可关闭状态；原生退出退回到根组件，不由单个页面自行处理。
- 主题、浮层、通知均以浏览器内存或 Web Storage 为权威。当前未发现跨窗口同步代码；仓库中遗留的浮动助手文件也不能据此视为当前生产多窗口表面。

## 未验证事项

- 未启动 APK，未验证主题切换、首帧、过渡、键盘 Insets、左右滑动、返回栈和系统分享。
- 未下钻 Vue、UnoCSS 或浏览器/Android 依赖内部，因此不确认焦点管理、Esc、读屏、滚动锁定和 reduced-motion 行为。
- 未调查附件查看器、上传队列与具体业务空态；不能由全局层级常量推断这些页面均正确接入。

## 关键源码索引

- `src/main.ts:1-56`：Vue、Pinia、Router 与全局错误入口。
- `src/App.vue:324-514`：根布局、Android 返回与安全区事件消费。
- `src/core/stores/overlay.ts:15-299`、`src/core/composables/useModalHistory.ts:31-177`：虚拟页面栈和 history 协同。
- `src/components/GlobalOverlayManager.vue:28-58`、`src/components/FeatureOverlays.vue:20-122`：全局和 Feature 覆盖层挂载。
- `src/core/stores/notification.ts:27-200`、`src/core/stores/theme.ts:56-279`：通知与主题状态权威。
