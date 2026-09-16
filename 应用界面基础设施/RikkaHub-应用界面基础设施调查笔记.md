# RikkaHub 应用界面基础设施调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：静态走读应用根装配、主题与配色生成、导航栈、公共组件目录、设置持久化与资源目录；未启动 Android 设备、未运行 APK，未下钻 Compose、Material3、Haze、Sonner 等依赖内部实现
>
> 调查范围：应用级装配与状态所有权、浮层与返回、通知与加载反馈、主题与视觉 token、窗口适配、图片与附件预览、国际化资源组织、设置与偏好框架、图标字体资源、无障碍与键盘支持的交点；不重复调查 Composer 输入编排、消息气泡渲染、工具调用 UI 等业务链，也不评价视觉风格与翻译质量
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是单 Activity 的原生 Android 应用，界面全部由 Jetpack Compose 构建，只有一个 Compose 导航栈。公共界面基础设施没有集中的 Overlay Host 或全局 Store；跨页面能力以五组 CompositionLocal 下发：导航控制器、设置快照、Toast 队列、共享元素作用域与朗读识别状态。弹窗与底部表由各页面自行组合 Material3 组件，不存在统一浮层表，遮罩与关闭语义依赖 Material3 默认行为。

主题是其中最集中的一块：明暗模式、动态取色、预置与自定义主题统一在 `RikkahubTheme` 解析，并叠加 AMOLED 纯黑、扩展色板、Expressive 动效与系统栏图标明暗。配色与自定义主题落盘 DataStore，色模式、AMOLED、启动是否新建会话等界面语义开关另走 SharedPreferences，形成两条持久化轨道。

导航是 Navigation 3 的 `NavDisplay` 加一层自研 `Navigator`，返回栈由页面持有的 `MutableList<NavKey>` 表达，`onBack` 直接删栈尾，预测性返回用 `predictivePopTransitionSpec` 声明，页面按需再挂 `BackHandler`。本次静态证据只能确认入口、状态与事件绑定，不能确认手势、焦点、动画与读屏的实际表现。

## 系统边界与总体装配

应用进程入口是 `RikkaHubApp`（Application），在 Koin 启动前完成待恢复备份落盘、创建通知渠道、安装崩溃处理器、初始化 QuickJS、清理临时目录并可选拉起 Web 服务器前台服务（`app/src/main/java/me/rerere/rikkahub/RikkaHubApp.kt:55-109`）。依赖注入用 Koin，界面侧以 `koinInject()` 与 `koinViewModel()` 取存储、仓储与 ViewModel。

界面进程只有一个 Activity：`RouteActivity` 在 `onCreate` 开启 edge-to-edge、关闭导航栏对比保护，崩溃后改跳安全模式，然后设置 Compose 内容——主题包住 Coil 单例加载器，再进入路由组合（`RouteActivity.kt:162-198`）。它同时是 launcher，接收分享文本、划词处理、翻译动作与携带会话 ID 的启动（`AndroidManifest.xml:62-102`）；清单另注册两个界面 Activity：

- `SafeModeActivity`：崩溃降级界面，独立 Scaffold，仅切换助手与进入主界面（`ui/activity/SafeModeActivity.kt:63-120`）。
- `ShortcutHandlerActivity`：响应 `rikkahub://shortcut`，相机拍照后把结果当作分享意图送回主 Activity（`ui/activity/ShortcutHandlerActivity.kt:14-49`）。

多入口不共享同一套基础设施：安全模式只包裹主题、自行读取设置存储，不提供导航控制器与 Toast 上下文；系统悬浮窗也只复用主题。内嵌 Ktor 服务器与 `web` 模块托管的 `web-ui` React 前端是另一套界面实现，与 Compose 侧无 token 或组件复用，托管与挂载见[独特功能调查笔记](../独特功能/RikkaHub-独特功能调查笔记.md)与[外部执行体与应用协作调查笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)。

## 1. 界面栈、公共组件与状态所有权

界面代码集中在 `ui/` 下，按职责分为 `theme`、`components`、`context`、`hooks`、`modifier`、`pages` 六块。技术栈为 Kotlin + Compose BOM `2026.09.00`、Material3 `1.5.0-alpha28`、Navigation 3、Compose Material3 Adaptive，最低 API 26、目标与编译 API 37（`gradle/libs.versions.toml`、`app/build.gradle.kts`）；构建时对 Material3、Expressive、Adaptive 与 Navigation3 的实验性 API 统一 opt-in。

`components` 下有十个公共子目录，跨页面复用的 UI 件按用途归为几类：

| 类别 | 代表组件 |
|---|---|
| 结构容器 | `ui/CardGroup.kt`、`ui/StickyHeader.kt`、`table/DataTable.kt` |
| 表单 | `ui/Input.kt`、`ui/TextArea.kt`、`ui/Switch.kt`、`ui/Select.kt`、`ui/Tag.kt`、`ui/Form.kt` |
| 反馈 | `ui/DotLoading.kt`、`ui/RabbitLoading.kt`、`ui/ErrorCard.kt`、`ui/ChainOfThought.kt`、`modifier/Shimmer.kt` |
| 浮层 | `ui/ConfirmDialog.kt`、`ui/ShareSheet.kt`、`ui/ImagePreviewDialog.kt`、`ui/JsonTree.kt`、`ui/FloatingWindow.kt` |
| 系统能力 | `ui/permission/PermissionManager.kt`、`ui/TTSController.kt`、`ui/KeepScreenOn.kt`、`ui/QRCode.kt` |
| 标识 | `ui/AIIcon.kt`、`ui/UIAvatar.kt`、`ui/Favicon.kt`、`ui/icons/` |

状态所有权分成三层。需持久化的用户偏好由 `SettingsStore` 持有：它把 `Settings` 整体序列化进名为 `settings` 的 Preference DataStore，挂载 V1–V3 迁移，并以常量集中声明 UI、模型、提供商、助手、MCP、备份等键（`app/src/main/java/me/rerere/rikkahub/data/datastore/PreferencesStore.kt:61-155`）。界面用 `rememberUserSettingsState()` 把该流读成 Compose State，并以 `Settings.dummy()` 作初始值避免回写（`ui/hooks/Settings.kt:11-16`、`PreferencesStore.kt:570-574`）。页面级临时状态由各 ViewModel 或 `remember` 持有，聊天页的抽屉开合、预览模式与附件面板开关即属此类，其页面内表现见 [Chat UI 调查笔记](../Chat%20UI/RikkaHub-ChatUI调查笔记.md)与[会话与消息管理调查笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

跨页面传递的公共对象用 CompositionLocal 而不是全局单例，共有五组在路由根一次性提供：

- `LocalNavController`：`Navigator`，包装返回栈与 popUpTo/singleTop 选项（`ui/context/NavContext.kt:7-55`）。
- `LocalSettings`：当前设置快照，静态类型（`ui/context/LocalSettings.kt:6`）。
- `LocalToaster`：Sonner 的 Toast 队列状态（`ui/context/ToasterContext.kt:6`）。
- `LocalSharedTransitionScope`：共享元素作用域，配 `Modifier.heroAnimation(key)` 供跨页共享元素动画使用（`ui/context/SharedElement.kt:6`、`ui/hooks/HeroAnimation.kt:9-20`）。
- `LocalTTSState` / `LocalASRState`：朗读与识别的会话状态。

这五组在 `AppRoutes` 的一处 `CompositionLocalProvider` 内注入，位于 `SharedTransitionLayout` 之内、`NavDisplay` 之外（`RouteActivity.kt:273-296`）：导航与弹层页面都能读取，共享元素动画只在布局作用域内可用。

## 2. 弹窗、浮层与菜单

本仓库没有集中式 Overlay Host。`app/src/main/java` 下共有 49 处 `ModalBottomSheet(` 调用点，分布在设置、助手、模型、搜索、聊天、备份等近三十个文件中，未统一封装（检索范围 `app/src/main/java`，模式 `ModalBottomSheet\(`）。浮层顺序因此就是 Compose 组合顺序，无全局层级常量或 Portal；`RouteActivity` 只额外保证开发模式角标与迁移遮罩压在 `NavDisplay` 之上。

底部表存在一个重复约定：需要完全隐藏而非半开的 Sheet 会显式限制取值集合，如分享表与更新详情表只允许隐藏与展开两态（`ui/components/ui/ShareSheet.kt:43`、`ui/components/ui/UpdateCard.kt:132`）；多数选择器类 Sheet 直接用默认三态的 `rememberModalBottomSheetState`。这说明弹一层还是可选高度由调用点自定，没有统一策略。

对话框分三种来源：通用确认框 `RikkaConfirmDialog` 是 Material3 `AlertDialog` 加标题、正文插槽与两个 `TextButton`，`show` 为假时不进入组合（`ui/components/ui/ConfirmDialog.kt:9-37`）；业务一次性对话框直接用 `AlertDialog`，如设置页赞助提示与主题页导入删除确认（`ui/pages/setting/SettingPage.kt:95-119`）；菜单类浮层由 `Select` 与 `SelectTextField` 提供，后者注释说明为规避菜单接近窗口高度时的坐标约束异常而改用普通 `DropdownMenu` 并限制最大高度，同时把只读态处理为整块可点且不抢焦点（`ui/components/ui/Select.kt:41-181`）。注释与实现一致，属代码内已声明的取舍。

图片预览走窗口对话框：`ImagePreviewDialog` 用 Compose `Dialog`，关闭点击穿透并把 `usePlatformDefaultWidth` 置空以占满窗口，内部用第三方缩放分页器承载多图并保留保存按钮（`ui/components/ui/ImagePreviewDialog.kt:32-88`）；遮罩关闭与 Esc 交由平台 `Dialog`。

系统悬浮窗由 `FloatingWindow` 提供：基于 `petterpx` 的 FloatingX 安装到 Application 上下文，带淡入与 `BOTTOM_START` 锚点，`DisposableEffect` 卸载时取消，内容独立包一层 `RikkahubTheme`（`ui/components/ui/FloatingWindow.kt:39-55`）。它不复用主窗口的导航与 Toast，只复用主题；主题内部因此对嵌套做了还原——更新系统栏图标外观前记录旧值、`onDispose` 写回（`ui/theme/Theme.kt:85-99`）。

返回门禁分层：`NavDisplay` 收到返回即移除栈尾（`RouteActivity.kt:303`），页面按需用 `BackHandler` 抢占，例如聊天抽屉、WebView 可后退、工作区第三级回退、图像生成中或选区时拦截；这些拦截属页面行为，入口见 [Chat UI 调查笔记](../Chat%20UI/RikkaHub-ChatUI调查笔记.md)、[媒体创作调查笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)与[外部执行体与应用协作调查笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)。预测性返回没有独立状态机，而是在 `NavDisplay` 上声明与 pop 相同的 `predictivePopTransitionSpec`（`RouteActivity.kt:311-318`），配合清单 `enableOnBackInvokedCallback`（`AndroidManifest.xml:54`）。

## 3. 通知、加载态与错误反馈

应用内反馈只有一条通道：Sonner（`io.github.dokar3:sonner 0.4.0`）的 `Toaster`，在路由根挂一份，顶部居中、启用富色彩与关闭按钮、明暗跟随 `LocalDarkMode`（`RouteActivity.kt:282-288`）。业务通过 `LocalToaster` 调用 `show`，如聊天页未选模型、更新卡片开始下载（`ui/pages/chat/ChatPage.kt:385-388`、`ui/components/ui/UpdateCard.kt:125-129`）。仓库没有自研 Toast 队列、历史或去重；堆叠、更新与消失时长由 Sonner 决定，本次未下钻该依赖实现，只能标为未核实。少数位置用 Android 原生 `Toast`，集中在启动阶段的恢复失败提示（`RikkaHubApp.kt:64-68`）。

系统通知是另一套设施。三个渠道在 Application 创建：聊天完成（高优先级、震动）、聊天实时更新（低优先级）、Web 服务器（低优先级、不显示角标），常量集中在 Application 文件顶部（`RikkaHubApp.kt:51-53`、`:212-241`）。发送统一走 `NotificationUtil`：权限未授予时直接返回失败而不抛错，DSL 暴露持续通知、仅提示一次、大文本样式、可见性与 `PendingIntent`；Android 15 及以上提升为持续通知，Android 16 及以上设置状态栏短文本（`utils/NotificationUtil.kt:44-117`）。业务事件由聊天生成前台服务与 `ChatNotificationManager` 消费，见[生成式输出与运行时调查笔记](../生成式输出与运行时/RikkaHub-生成式输出与运行时调查笔记.md)。

加载与错误态没有统一封装。轻量等待用 `DotLoading` 或 `RabbitLoadingIndicator`，后者按显示设置二选一：开启时用应用图标形状的 AnimatedVectorDrawable 并着色主题主色，关闭时退回 Material3 的 `ContainedLoadingIndicator`（`ui/components/ui/DotLoading.kt:24-48`、`ui/components/ui/RabbitLoading.kt:16-43`）；骨架由 `modifier/Shimmer.kt` 提供；错误态由 `ErrorCard` 承担，支持复制与逐条或全部关闭（`ui/components/ui/ErrorCard.kt`）。数据库迁移用全屏遮罩而非弹窗：状态来自 `DatabaseMigrationTracker`，迁移中在 `NavDisplay` 上叠加半透明表面、进度环与版本号（`RouteActivity.kt:544-575`）。另有更新提示卡与备份提醒卡两类页面级卡片（`ui/components/ui/UpdateCard.kt:55-133`）。本次未在 `ui/components` 找到通用空状态组件，空列表提示由各页面自行组织（检索范围 `app/src/main/java/me/rerere/rikkahub/ui/components`，未见 Empty/Placeholder 类公共件）。

## 4. 主题、视觉 token 与持久化

主题解析集中在 `RikkahubTheme`：输入色模式与设置快照，输出 Material3 配色、排版、动效与三组 CompositionLocal（`ui/theme/Theme.kt:44-114`）。判定顺序：

1. 色模式折算为是否深色：跟随系统读系统状态，否则按显式选择。
2. 开启动态取色且 Android 12 及以上用系统动态明暗配色；否则按主题 ID 在预置与自定义主题中查找，找不到回退樱色预置（`Theme.kt:57-67`、`ui/theme/PresetTheme.kt:36-38`）。
3. 深色且启用 AMOLED 时把背景与表面覆盖为 `#000000`（`Theme.kt:34`、`:68-77`）。
4. 由 `MaterialExpressiveTheme` 下发，动效固定 expressive，并提供扩展色板与深色标记，把 overscroll 工厂置空以关闭拉伸反馈（`Theme.kt:102-113`）。
5. 系统栏图标明暗跟随深色，嵌套主题退出时还原（`Theme.kt:85-99`）。

主题权威源是 `Settings` 中的动态取色开关、主题 ID 与自定义主题列表，落 DataStore 的 `dynamic_color`、`theme_id`、`custom_themes` 三键（`PreferencesStore.kt:81-83`）。**色模式本身不在 DataStore**，而是 SharedPreferences 的 `colorMode` 字符串，另有 `amoledDark` 布尔，二者由 `ui/hooks/ColorMode.kt` 封装为可写 State（`ui/hooks/ColorMode.kt:9-38`）；启动时首屏是否新建会话也走同一份 SharedPreferences（`RouteActivity.kt:254-263`）。因此持久化跨两套存储：配色与自定义主题在 DataStore，模式开关在 SharedPreferences。

预置主题七个（樱、海、春、秋、黑、极简、Claude），各提供明暗两份 `ColorScheme`，由惰性列表注册；自定义主题由主色（可选副色、第三色）经 HCT 与 Tonal Spot 变体生成完整配色，计算在 `material3` 模块完成（`ui/theme/PresetTheme.kt:13-49`、`ui/theme/CustomTheme.kt:21-67`、`material3/src/main/java/me/rerere/material3/DynamicSchemeExt.kt:9-114`）。该模块是独立 Gradle library，源码并入 `material-color-utilities` 的 Kotlin 实现，只暴露把 `DynamicScheme` 映射为 Compose `ColorScheme` 的扩展（`material3/build.gradle.kts:5-12`），在应用里是配色生成工具，不提供组件。

另有补充 token。`ExtendColors` 是红、橙、绿、蓝、灰各十级的固定色阶，明暗各一份，经 `LocalExtendColors` 暴露为 `MaterialTheme.extendColors`（`ui/theme/Color.kt:13-170`、`Theme.kt:28-30`）。`CustomColors` 是取色自当前配色的语义快捷方式：顶栏容器色浅色取 `surfaceContainer`、深色用 Material3 默认，卡片与列表项分别取 `surfaceContainer` 与 `surfaceBright`（`Color.kt:172-191`）。其内部可变 `black` 字段本次未找到写入点。这些 token 被设置页、抽屉与各列表页直接引用，构成统一外观基线。

排版沿用 Material3 默认，`Typography` 就是 `Typography()`（`ui/theme/Type.kt:13-14`）。仓库保留完整 Google Sans Flex 字体族与可变圆形轴工具，并在排版文件以注释给出逐级替换方案，但当前无生效引用（`ui/theme/GoogleSans.kt:29`、`Type.kt:17-78`）；实际使用的是 JetBrains Mono，用于代码块、日志、JSON 与终端（`Type.kt:81-88`）。会话正文字体族（默认、衬线、等宽、自定义文件）经 `ChatFontProvider` 以 CompositionLocal 下发，自定义文件从应用私有目录加载并做路径前缀校验，字号比例在渲染点乘以本地值（`ui/theme/ChatFont.kt:19-61`、`PreferencesStore.kt:615`）；字号落点属消息渲染，见[消息渲染器调查笔记](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)。

## 5. 响应式、移动端与窗口适配

适配策略是单窗口内的抽屉切换，未使用 `ListDetailPaneScaffold` 或 `NavigationSuiteScaffold`。聊天页读窗口尺寸，横向且宽度不小于 1100dp 判定为大屏，走 `PermanentNavigationDrawer`，否则走 `ModalNavigationDrawer` 并挂返回键关抽屉（`ui/pages/chat/ChatPage.kt:132-142`、`:191-259`）；注释说明进入大屏会主动关闭残留模态抽屉，以免旋转后卡在打开态，与 `LaunchedEffect(isBigScreen)` 实现一致。

窗口与系统栏按 edge-to-edge：Activity 开启 edge-to-edge、取消导航栏对比保护（`RouteActivity.kt:163-164`、`:200-204`），清单把软键盘设为 `adjustResize` 并声明键盘隐藏、方向与屏幕尺寸变化由应用处理、不重建 Activity（`AndroidManifest.xml:69-73`）。内容缩进由各页 `Scaffold` 与 `WindowInsets` 承担；聊天列表另有 IME 高度驱动的自动滚动，监听 IME 底部内边距变化并按差值滚动，让输入区抬起时消息跟手（`ui/hooks/ImeAutoScroller.kt:17-37`）。

没有独立的手机与平板入口，也没有多窗口或桌面布局；安全模式 Activity 与系统悬浮窗是仅有的第二界面，均不参与响应式分支。1100dp 判定线与语音模式的取舍属页面布局，见 [Chat UI 调查笔记](../Chat%20UI/RikkaHub-ChatUI调查笔记.md)。

## 6. 图片、附件、拖放与常见内容交互

图片加载统一走 Coil3 单例，在路由根一次装配：网络取图接 OkHttp 并启用 Cache-Control 缓存、开启交叉淡入、按版本选择动图解码器（Android 9+ 用 AnimatedImageDecoder，否则 GifDecoder）、增加按密度缩放的 SVG 解码器（`RouteActivity.kt:176-194`）。全应用共享同一 loader 与缓存，分享面板的二维码、模型与站点图标复用同一链路。

预览与保存由 `ImagePreviewDialog` 承载：缩放分页器加保存按钮，保存时通过文件管理器把当前页写入相册，成败均用 Toast 反馈，由 Lifecycle 协程作用域发起（`ui/components/ui/ImagePreviewDialog.kt:66-85`）。相册写入与生成资产链路见[媒体创作调查笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)；消息内联图片的缩放件 `ZoomableAsyncImage` 属渲染层，见[消息渲染器调查笔记](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)。对话图片导出的离屏 Compose 复刻与水印不在本笔记范围，见[对话导出与分享调查笔记](../对话导出与分享/RikkaHub-对话导出与分享调查笔记.md)。

附件公共设施包括附件选择底部表、附件标签行、文件选择器与裁剪启动器（`ui/components/ai/FilesPicker.kt`、`AttachmentChips.kt`、`CropLauncher.kt`）；裁剪依赖第三方 uCrop，其 Activity 在清单注册（`AndroidManifest.xml:117-119`）。它们在聊天 Composer 中的编排见 [Chat UI 调查笔记](../Chat%20UI/RikkaHub-ChatUI调查笔记.md)。

剪贴板没有公共封装，调用点直接取 `LocalClipboard` 或 `ClipboardManager`，散落在代码块、日志、错误、主题导入导出与终端（检索范围 `app/src/main/java`，约二十处）。**本次未找到任何 Compose 拖放基础设施**（`dragAndDropSource`、`dragAndDropTarget`、`startDragAndDrop` 均无结果），附件加入因此是可点击的选择器而非拖入。

## 7. 扩展调查

### 7.1 国际化与本地化资源组织

字符串资源按 Android 标准目录：默认 `values` 为英文，另有 `values-ja`、`values-ko-rKR`、`values-ru`、`values-zh`（简体）、`values-zh-rTW`（繁体），`app/src/main/res/resources.properties` 把无修饰资源声明为 en-US。默认语言约 1383 条、简体约 1377 条，简体与繁体文件大小几乎一致，说明独立维护而非复制；功能模块可各自维护翻译，`search` 模块即带一套同语言 `strings.xml`。写作约定要求页面级字符串带页面前缀（如 `setting_page_`），抽查设置页确实遵循。

运行时没有应用内语言切换：本次未找到 `setApplicationLocales`、`LocaleManager` 或 `localeConfig` 声明（检索范围 `app/src/main/java`；`AndroidManifest.xml`），界面语言完全跟随系统。界面里的语言选择器只服务翻译的目标语言，候选项在翻译页硬编码九种（`ui/pages/translator/TranslatorPage.kt:207-240`）。日期与数字格式化统一用 `java.util.Locale.getDefault()`（`utils/TimeUtil.kt`）；语言作为模板变量注入提示词属业务语义，不在界面机制范围。

清单开启 `supportsRtl`（`AndroidManifest.xml:58`），公共扩展用 `LocalLayoutDirection` 做方向相关的内边距计算（`utils/ComposeExt.kt:18`），说明存在 RTL 适配入口；但本次没有 RTL 资源目录，也没有运行验证。

`locale-tui` 是开发侧工具而非应用组成：Python + Textual 终端应用，用 `lxml` 读写各模块 `strings.xml`，用 OpenAI 接口批量补译并提供死键扫描，有独立 `pyproject.toml`、配置与测试，不参与 APK 构建（`locale-tui/pyproject.toml`、`src/services/xml_parser.py`、`src/services/dead_entry_finder.py`）。翻译质量与键覆盖完整性不在本笔记范围。

### 7.2 设置与偏好基础设施

设置页是两级结构。首屏 `SettingPage` 用 `CardGroup` 分组，放通用设置、偏好入口、助手、扩展等，并内联未配置提供商警告卡与启动次数达到后的赞助提示（`ui/pages/setting/SettingPage.kt:95-146`）；偏好二级页 `SettingPreferencesPage` 并列五个子页入口：主题、通知、通用、界面、网络（`SettingPreferencesPage.kt:58-93`），各子页再各自组织表单。

作用域表达扁平：全局设置放 `Settings`，界面显示项放 `DisplaySetting`（约三十字段，覆盖头像昵称、气泡与模型信息展示、字体字号、代码块、TTS 自动播放、回车发送、模糊效果与音量键滚动等），助手级设置在 `Settings.assistants` 内按助手 ID 隔离，模型与提供商在 `Settings.providers` 内（`PreferencesStore.kt:599-637`）。页面统一由 ViewModel 暴露设置流、`collectAsStateWithLifecycle` 后整体 `copy` 回写，需要局部更新时先取当前助手再替换列表元素。没有设置检索、迁移提示或 onboarding 框架，唯一接近首次引导的是未配置提供商的警告卡。

统一分组外观由 `CardGroup` 的 DSL 提供：调用方声明若干 `item`（可带图标、支撑文本、尾部内容与点击），组件按首项、中间项、末项与按压态动画出不同圆角，把一组 `ListItem` 拼成连续卡片（`ui/components/ui/CardGroup.kt:96-173`）。设置页统一用 `LargeFlexibleTopAppBar` 配 `exitUntilCollapsedScrollBehavior` 与 `CustomColors.topBarColors`，返回按钮复用 `components/nav/BackButton`（`ui/components/nav/BackButton.kt:16-31`）。

### 7.3 图标、字体与资源管理

图标走两套图标库加自研：`hugeicons-compose`（`HugeIcons.ArrowLeft01` 这类属性访问）为主，`lucide` 补充，另有四个自研图标（Discord、QQ、心形、推理）与一批 AI 提供商图标（`ui/components/ui/icons/`、`ui/components/ui/AIIcon.kt`）。其无障碍处理不统一：多数用 `stringResource` 给出名称，少数硬编码英文或置空，见无障碍一节。

字体文件只有 Google Sans Flex 与 JetBrains Mono，前者仅被未启用的排版方案引用，后者用于代码与日志（`ui/theme/GoogleSans.kt`、`Type.kt:81-88`）。`drawable` 下只有十余个位图/矢量件，`mipmap-anydpi-v26` 提供自适应图标，加载动画的兔子是 AnimatedVectorDrawable（`ui/components/ui/RabbitLoading.kt:25`）；清单层资源包括备份/数据提取规则、`FileProvider` 路径与注册“拍照”“翻译”的静态快捷方式（`app/src/main/res/xml/shortcuts.xml:1-25`、`AndroidManifest.xml:99-101`）。

### 7.4 无障碍与键盘支持

可访问名称的覆盖是部分的。全应用大量使用 `contentDescription`，多数走字符串资源，但存在硬编码英文（消息分支 Prev/Next、WebView 的 Refresh/Forward/More options、网络指标的 Input/Output/Speed/Duration、下拉件 expand）与大量置空（装饰性及重名图标）。本次未找到应用级语义封装、自定义语义动作或状态描述（检索 `semantics {`、`stateDescription`、`clearAndSetSemantics`，除根节点外无结果）。根节点唯一设置的是把 Compose 测试标签暴露为资源 ID，属 UI 测试而非读屏（`RouteActivity.kt:290-295`）。

键盘支持限于音量键与系统返回，没有通用快捷键：Activity 覆写 `dispatchKeyEvent`，维护“最后注册优先”的音量键监听器列表，音量上下键可被业务消费（聊天页据此实现音量键滚动，开关与步进在 `DisplaySetting`），其余交回系统（`RouteActivity.kt:146-160`、`PreferencesStore.kt:635-636`）。未找到 `onKeyEvent` 或自研焦点请求器，仅搜索页用一个 `FocusRequester` 自动聚焦搜索框（`ui/pages/search/SearchPage.kt:71`）。对话框与底部表的焦点陷阱、Esc、触摸关闭来自 Material3 与平台 `Dialog`，本次未阅读依赖实现也未运行验证。

## 8. 设计取舍与已确认边界

- 公共基础设施用 CompositionLocal 而非全局 store：导航、设置、Toast、共享元素动画都在路由根注入，好处是作用域与预览友好，代价是路由之外的组合（安全模式、系统悬浮窗）不可用，安全模式因此直接读取存储、悬浮窗只复用主题。
- 导航栈是自研薄封装。`Navigator` 只实现入栈、清栈入栈、弹栈与 popUpTo/singleTop 两种选项，返回栈由页面列表持有，因此“单一顶层”“栈内清空”需在调用点显式书写，例如设置页切换色模式后以 inclusive 重新入栈当前页（`ui/pages/setting/SettingPage.kt:165-172`）。
- 没有统一浮层宿主：49 处底部表调用点只共享 Material3 默认行为与团队约定，层级、遮罩、关闭时机不受集中代码约束；唯一强制压在业务界面之上的是开发角标与迁移遮罩。
- 反馈分两条互不相通的通道：轻量页面内提示走 Sonner，需离开应用或长时间运行的提示走系统通知渠道，两者之间没有统一队列或“返回原任务”机制。
- 主题持久化刻意分两轨：需要随设置备份迁移的配色与自定义主题进 DataStore，只具界面语义的色模式与 AMOLED 开关进 SharedPreferences，可在不触碰设置整体迁移的前提下独立读写。
- 主题支持嵌套：`RikkahubTheme` 可被重复包裹，并在卸载时还原系统栏图标外观，既服务悬浮窗也服务局部深色页面。
- 响应式只有一条判定线，按窗口尺寸而非设备类型切换抽屉形态；未使用 Adaptive 多窗格骨架，也未提供独立平板或折叠屏布局。

## 9. 未验证事项

- 未安装或启动应用，配色、动态取色、AMOLED 纯黑、Expressive 动效、Haze 模糊（`enableBlurEffect` 控制聊天输入区的 `hazeBlur`）与交叉淡入等视觉效果均未在设备上观察。
- 未验证预测性返回手势、系统返回与 `BackHandler` 的协同顺序、`NavDisplay` 过渡手感与跨页共享元素的动画连续性。
- 未下钻 Compose、Material3、Sonner、FloatingX、uCrop、Coil 的实现，对话框与底部表的焦点陷阱、Esc、点击外部关闭、滚动锁定与读屏播报只能标为未核实。
- 未验证系统通知渠道的实际投递、权限弹窗路径、Android 15 持续通知提升与 Android 16 状态栏短文本，以及系统悬浮窗在真机上的权限、层级与触摸穿透；悬浮窗本次只确认代码中的安装与卸载路径。
- 未验证 edge-to-edge 与 IME 内边距在横屏、手势导航、折叠屏与 1100dp 阈值附近的表现，也未验证音量键滚动的步进手感。
- 未核查所有底部表调用点是否可达、是否存在同页多表叠加，以及 `rememberSaveable` 之外的浮层状态在配置变更后的残留。
- 无障碍仅确认描述字符串与语义调用的分布，未做键盘走查、焦点顺序或对比度测量，不据此判断是否满足任何无障碍标准。
- 未调查空状态的实际呈现、列表虚拟化与长会话滚动性能（`baselineprofile` 模块与 `ProfileInstaller` 存在，但结论需运行证据），也未评估翻译质量、键覆盖完整性与 RTL 布局表现。

## 10. 关键源码索引

- `app/src/main/java/me/rerere/rikkahub/RouteActivity.kt:140-198`：单 Activity 入口、edge-to-edge、Coil 装配与主题包裹；`:236-319`：路由根装配与过渡规格；`:544-575`：数据库迁移遮罩。
- `app/src/main/java/me/rerere/rikkahub/ui/context/NavContext.kt:7-55`：`Navigator`、popUpTo/singleTop 与 `LocalNavController`；`ui/hooks/Settings.kt:11-16`：设置流读入。
- `app/src/main/java/me/rerere/rikkahub/ui/theme/Theme.kt:44-114`：色模式、动态取色、AMOLED、扩展色板与 Expressive 主题下发；`ui/theme/PresetTheme.kt:13-49`、`ui/theme/CustomTheme.kt:21-67`：预置与自定义主题及 HCT 配色生成；`ui/theme/Color.kt:13-191`：扩展色板与 `CustomColors`。
- `app/src/main/java/me/rerere/rikkahub/data/datastore/PreferencesStore.kt:61-155`、`:599-637`：设置存储与迁移、`DisplaySetting` 字段表；`ui/hooks/SharedPreferences.kt:19-70`：界面级偏好读写与流桥接。
- `app/src/main/java/me/rerere/rikkahub/ui/components/ui/CardGroup.kt:96-173`：设置页统一分组容器；`ConfirmDialog.kt:9-37`、`ImagePreviewDialog.kt:32-88`：通用对话框与图片预览；`FloatingWindow.kt:39-55`：系统悬浮窗。
- `app/src/main/java/me/rerere/rikkahub/utils/NotificationUtil.kt:44-117`、`RikkaHubApp.kt:51-53`、`:212-241`：系统通知构建与渠道定义。
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatPage.kt:113-142`、`:191-259`：返回键门禁与 1100dp 大屏抽屉分支；`ui/hooks/ImeAutoScroller.kt:17-37`：IME 内边距驱动的自动滚动。
