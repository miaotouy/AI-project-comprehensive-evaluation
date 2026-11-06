# OpenClaw 应用界面基础设施调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：静态源码阅读。沿 Control UI 根装配、原生 Modal 与 Toast 的入口、状态所有者、呈现和清理路径下钻；主题与平台边界辅以已有源码和仓库说明。未运行构建、测试或 Gateway。
>
> 调查范围：应用级装配、公共浮层与反馈、主题与偏好、响应式、多入口及公共内容交互；原生客户端只记录技术栈和共享边界。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Control UI 使用 Solid 2（rc.18）与原生 DOM 公共组件，路由由 `@openclaw/uirouter` 承担。Gateway 与 UI 同版本派发。根组件创建一套应用能力对象，用 Solid Context 交给视图；需要跨自定义元素边界时，由原生 context-request 协议运输相同能力对象。业务权威状态仍由 Gateway 和普通 TypeScript owner 持有，Solid 消费其响应式投影。依据见 [UI 依赖](<../../openclaw/ui/package.json#L11-L54>)、[根组件](<../../openclaw/ui/src/app/app-root.tsx>) 与 [Context 适配](<../../openclaw/ui/src/lib/reactive/context.ts>)。

公共浮层由原生 Modal、Popover、菜单和 Overlay 生命周期协作。Modal 的呈现面是 HTML dialog，开关、滚动锁、焦点归还与可取消关闭事件由项目适配器管理。Toast 由一个宿主管理多条通知：顶部中央面向当前操作，顶部右侧面向后台到达事件；两条 lane 各自堆叠，收起时各显示最新三条。宿主会随当前 Modal 或抽屉切换承载位置，单个宿主并不限制为单条消息。

偏好分为设备本地状态与服务端同步状态：可同步外观偏好由服务端 config 的 `ui.prefs` 持有，localStorage 用作即时镜像与离线暂存；布局开合等窗口现场由各文档实例独立持有。TUI 和原生客户端拥有各自的主题、通知与浮层实现。视觉、焦点、触摸和动画表现均未经运行验证。

## 系统边界与总体装配

Web 入口以 `<openclaw-app>` 为原生宿主，Solid 在宿主内挂载根视图。`bootstrapApplication` 恢复设置并创建 Gateway、会话、Agent、主题、overlays 与导航等能力对象；根视图读取这些 owner 的投影，按连接、登录、聚焦文档或完整 Shell 分支呈现。文档销毁时归还挂载树与运行期资源。完整入口见 [app-root.tsx](<../../openclaw/ui/src/app/app-root.tsx>)、[bootstrap.ts](<../../openclaw/ui/src/app/bootstrap.ts>)。

能力通过 `ApplicationProvider` 注入。它持有 Solid Context，同时监听原生 context-request，为独立升级的自定义元素提供同一能力对象；Context 的存在不会转移 Gateway、会话或配置 owner 的生命周期。每个浏览器文档各创建一套运行期，跨窗口共享状态通过 Gateway 协议收敛。依据见 [context.ts](<../../openclaw/ui/src/lib/reactive/context.ts#L15-L95>)。

路由模块在懒加载边界暴露 Solid renderer，由 outlet 挂载并持续传入路由数据。根视图使用 Loading 与 Errored 边界处理异步视图及失败，连接阶段有 splash，失败可进入带重试的错误组件。过期 chunk 另由 stale-chunk 重载链处理，渲染错误与模块传输失败分层承接。依据见 [根视图](<../../openclaw/ui/src/app/app-root.tsx>) 与 [加载错误组件](<../../openclaw/ui/src/components/solid/lazy-view-error.tsx>)。

## 弹窗、浮层与菜单

Modal 主链是“业务开关或命令式确认 → 公共适配器 → 原生 dialog → 关闭或销毁清理”。`openclaw-modal-dialog` 由 Solid bridge 定义；内部渲染原生 dialog、内容区、瞬态 overlay 容器和两端焦点 guard。适配器调用 `showModal()`，登记当前层、获得文档滚动锁与原生遮挡租约，再处理初始焦点。关闭与断开连接会清理登记、释放租约并按存活目标归还焦点。实现见 [modal-dialog.tsx](<../../openclaw/ui/src/components/modal-dialog.tsx>)、[内容结构](<../../openclaw/ui/src/components/solid/modal-dialog.tsx>)。

用户取消先进入适配器的关闭请求，业务可通过可取消的 `modal-cancel` 事件阻止关闭；程序化关闭和断开连接有各自路径。适配器还处理嵌套层、焦点环绕、原生 cancel 与背景指针事件。静态代码能确认这些策略与事件绑定；浏览器 top layer、键盘焦点和触摸的最终表现仍需在目标浏览器运行验证。

命令式确认沿用同一 Modal。`showConfirmDialog` 先检查调用者显式提供的跳过偏好、必要确认和实时可确认条件；需要展示时由 Promise Modal Host 挂载懒加载的 Solid 确认视图。全局单飞期间第二次展示请求返回空选择，最终映射为 false；AbortSignal、宿主销毁和正常选择都进入结算与清理。依据见 [confirm-dialog.ts](<../../openclaw/ui/src/components/confirm-dialog.ts>)、[确认加载器](<../../openclaw/ui/src/components/confirm-dialog-loading.tsx>)。

菜单使用 Solid 的公共 Menu/Popover 与 Overlay owner，状态、键盘导航、定位和层级分别由公共模块承担。Menu 对每项生成原生绑定，并保留 checkbox/radio、禁用项、嵌套子菜单及关闭策略；导航 runtime 按需加载。根依赖中保留 Zag 菜单状态机，并无 Web Awesome dropdown 接线。依据见 [menu.tsx](<../../openclaw/ui/src/components/solid/menu.tsx>)、[menu-machine.ts](<../../openclaw/ui/src/components/solid/menu-machine.ts>) 与 [UI 依赖](<../../openclaw/ui/package.json#L36-L41>)。Tooltip、链接 Hovercard 和图像预览分别由公共组件承载，具体业务触发点属于对应业务笔记。

## 通知、加载态与错误反馈

Toast 的入口接受文案、严重级别、动作、时长、位置或锚点；宿主尚未出现时，启动队列保留所有待展示通知。宿主连接后由 ToastOwner 管理每条记录、剩余时间、退出动画与关闭原因，再向 Solid bridge 发布不可变视图。依据见 [toast.ts](<../../openclaw/ui/src/lib/toast.ts#L9-L117>)、[toast-host.tsx](<../../openclaw/ui/src/lib/toast-host.tsx>)。

| 场景 | 呈现与生命周期 |
|---|---|
| 当前操作反馈 | 默认顶部中央；显式锚点有效时进入 anchored lane |
| 后台到达事件 | 可指定顶部右侧，独立于当前操作堆叠 |
| lane 收起 | 最新三条可见并倒计时，更旧条目隐藏且暂停 |
| hover、focus 或触摸展开 | 展开该 lane 并暂停计时；触摸外部可收起 |
| 自动退出 | 普通、成功、进度默认 6 秒，警告 8 秒，错误 10 秒；支持单独覆盖 |
| Modal/抽屉打开 | 根据当前 overlay 容器移动宿主，通知记录与剩余时间仍归同一 owner |
| 完成动作或关闭 | 回调区分 action、dismiss、timeout、disconnected 等原因 |

Toast 错误用 alert，其他级别用 status；宿主自身有 Errored fallback 和重试，异步视图用 Loading 承接。计时、堆叠与 Modal 承载切换的实现见 [ToastOwner](<../../openclaw/ui/src/lib/toast.ts>)；真实读屏顺序、通知拥挤程度和触摸观感未经验证。

审批、配对与更新状态由应用的 overlays 能力持有。它消费 Gateway 事件与 operator 权限，向 Shell、标题和通知投影注意状态；公共 Modal 与 Toast 只承担呈现和交互，不拥有审批决策或服务端写入权限。依据见 [overlays.ts](<../../openclaw/ui/src/app/overlays.ts>)。

## 主题、视觉 token 与持久化

样式以 [base.css](<../../openclaw/ui/src/styles/base.css>) 的 CSS 变量为公共 token，主题与明暗通过根节点属性发布，具名调色板按需加载。运行期主题 owner 与 HTML 首帧初始化脚本分别处理正常切换和启动前置，两者需要保持解析规则一致。系统跟随使用媒体查询；主题过渡有 reduced-motion 分支。依据见 [theme.ts](<../../openclaw/ui/src/app/theme.ts>)、[启动 HTML](<../../openclaw/ui/index.html>)。

设置按 Gateway 来源域存浏览器 localStorage，凭据 token 走 sessionStorage；写入失败时保留内存镜像。同步偏好在服务端白名单内，包含主题、语言和部分聊天阅读偏好；Gateway 配置快照和变更事件使多个文档收敛。侧栏折叠、抽屉和局部选中等现场由窗口持有。来源见 [settings.ts](<../../openclaw/ui/src/app/settings.ts>)、[同步偏好状态](<../../openclaw/ui/src/app/server-prefs-state.ts>) 与 [同步操作](<../../openclaw/ui/src/app/server-prefs.ts>)。本次未做离线恢复、双窗口冲突或防闪实测。

## 响应式、多入口与公共内容交互

Shell 同时使用 JS 布局判断与 CSS 媒体查询，窄屏导航进入抽屉，原生 Web chrome 宿主有独立断点。相同前端还接受 approval、question、terminal、desktop、dashboard 和 board 等聚焦文档，直接打开对应视图并省略完整壳。入口与布局判断见 [app-root.tsx](<../../openclaw/ui/src/app/app-root.tsx>)、[mobile-nav-layout.ts](<../../openclaw/ui/src/app/mobile-nav-layout.ts>)。尺寸转换时控件、焦点和页面现场的连续性需要运行观察。

图片 lightbox 和文件预览沿用公共 Modal。壳还负责抑制浏览器默认文件拖放导航，具体附件选择、上传、发送和跨 pane 交接由聊天能力处理。业务入口、消息操作和附件恢复见 [Chat UI 调查笔记](<../Chat UI/OpenClaw-ChatUI调查笔记.md>)，消息内容投影见 [消息渲染器调查笔记](<../消息渲染器/OpenClaw-消息渲染器调查笔记.md>)。

## 平台边界与设计取舍

macOS/iOS 使用 Swift/SwiftUI，Android 使用 Compose；它们通过 Gateway 协议和原生能力代码协作，不复用 Control UI 的 Solid store 或 CSS token。Linux Tauri 客户端可嵌入 Gateway 的 Control UI。TUI 使用 pi-tui 与自己的主题和 overlay 生命周期。平台边界依据 [Apple 客户端](<../../openclaw/apps/macos/README.md>)、[Android 客户端](<../../openclaw/apps/android/README.md>)、[Linux 客户端](<../../openclaw/apps/linux/README.md>)、[TUI 浮层](<../../openclaw/src/tui/tui-overlays.ts>)。

公共视图、原生宿主与业务 owner 分离：Solid 管视图与局部交互，bridge 管自定义元素接入，Overlay 和 Toast owner 管跨视图生命周期，Gateway 管共享业务事实。每个文档有自己的本地运行期，因此跨窗口一致性建立在 Gateway 契约与偏好同步上。

## 扩展调查与未验证事项

- 可静态确认 Modal 的对话框语义、焦点 guard、焦点恢复路径，以及 Toast 的 alert/status、暂停和关闭操作；未做 WCAG 审计或完整键盘/读屏验证。
- 主题、CSS 动效、reduced-motion 和 top layer 接线只确认源码规则，未观察真实视觉、触摸、系统偏好变化或慢网首屏。
- 审批、配对、更新及推送仅确认公共呈现交点，真实事件流、推送服务和设备通知未经验证。
- 原生客户端的主题、响应式、系统菜单和无障碍没有逐一下钻；TUI 未在 PTY 运行。
- 依赖未安装，未读取本地 Solid 包的 CHEATSHEET 或执行 UI；框架版本由依赖锁定与源码导入确认，语义依据仓库维护的 Solid 指南和实际接线。

## 关键源码索引

- [根视图与文档分发](<../../openclaw/ui/src/app/app-root.tsx>)、[应用装配](<../../openclaw/ui/src/app/bootstrap.ts>)、[上下文适配](<../../openclaw/ui/src/lib/reactive/context.ts>)
- [原生 Modal owner](<../../openclaw/ui/src/components/modal-dialog.tsx>)、[Modal 内容](<../../openclaw/ui/src/components/solid/modal-dialog.tsx>)、[命令式确认](<../../openclaw/ui/src/components/confirm-dialog-loading.tsx>)
- [公共菜单](<../../openclaw/ui/src/components/solid/menu.tsx>)、[菜单状态与导航](<../../openclaw/ui/src/components/solid/menu-machine.ts>)
- [Toast owner](<../../openclaw/ui/src/lib/toast.ts>)、[Toast bridge 与错误边界](<../../openclaw/ui/src/lib/toast-host.tsx>)
