# AIO-Hub 应用界面基础设施调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：只读核对应用根装配、公共组件、状态/持久化与业务消费方，并对照两源码快照和现有测试；未启动服务或应用
>
> 调查范围：桌面应用导航与工具页缓存、设置工作区、公共浮层、反馈、主题、内容预览与编辑器、窗口同步；移动端作为独立表面说明边界，聊天主链由 Chat UI 笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 是 Vue 3、Element Plus 和 Tauri 组成的桌面应用。其界面基础设施包括应用壳、已打开工具导航、路由缓存、公共对话框、异步面板宿主、图片/音视频查看器、统一编辑器、即时提示和持久通知中心，不能只用“弹窗与主题封装”概括。

- 应用壳让标题栏和侧栏共用背景，工作区使用独立圆角与边界；导航可放侧栏、标题栏下拉或抽屉。主页和扩展入口固定，已打开工具可排序、关闭和分离。
- 工具缓存按路由路径分配独立 KeepAlive 边界，关闭工具会从缓存集合移除。缓存保存运行期页面状态，重启恢复的已打开路径列表只恢复导航，业务内容仍由各领域自行加载。
- 设置采用分组、页面、模块三层配置，界面显示两级导航；CSS、AI 渠道、模型元数据和 OCR 使用填满剩余高度的工作区布局，避免把编辑器强塞进固定最小高度的长设置页。
- BaseDialog 有焦点进入/归还、Tab 边界回环、最上层 Esc 与异步关闭拦截。层级同时参考活跃 BaseDialog、Element Plus 和可见覆盖层，提示消息动态保持在浮层上方。
- 主题为明暗、主色色阶和外观效果三层，自定义 CSS 是独立覆盖通道。主题持久化和窗口启动恢复已接线，实时跨窗口修改不应仅凭同一文件推定已同步。
- 静态源码能确认控件、条件和生命周期；视觉效果、键盘实际体验、窗口特效和平台拖放仍需目标环境实测。

## 系统边界与总体装配

```text
应用初始化 -> 加载应用设置 -> 恢复 CSS -> 主题/服务初始化
  -> GlobalProviders（同步服务、顶部提示、媒体查看器、模型选择器、通知中心）
  -> MainLayout（标题栏、导航、伴生宿主、WorkspaceRouteCache）
  -> 工具页面 / 设置页面
       -> 公共对话框、输入面板、编辑器、拖放、预览等消费方
```

[全局 Provider](<../../aio-hub/src/components/GlobalProviders.vue#L17-L139>)在每个 WebView 装配运行期单例与查看器；媒体和模型弹窗按需导入/挂载。[主布局](<../../aio-hub/src/views/MainLayout.vue#L176-L229>)承载应用壳和工具缓存，伴生宿主留在布局层，切换聊天工具页后仍保留后台任务同步。引导流程宿主由[App](<../../aio-hub/src/App.vue>)挂载；激活引导时主布局给背景容器加 inert 和 aria-hidden，限制背景交互。

分离工具窗和分离组件窗是独立 WebView，各自拥有独立的 JavaScript 运行时，共享源码组件的单例状态按窗口分别实例化。聊天跨窗状态、通知、窗口尺寸和设置文件分别有不同通道，见第 7 节。

## 1. 应用导航与工作区生命周期

### 1.1 已打开工具形成工作区导航

工具注册表提供完整工具目录，已打开路径列表单独驱动导航。侧栏保留主页、扩展和底部功能区，把已打开工具放进独立可滚动区域；用户可拖拽排序、关闭或分离。只有横向移出达到条件才进入分离流程，普通点击导航到对应路由。[导航菜单](<../../aio-hub/src/components/SidebarMenu.vue#L54-L163>)确认了列表来源、排序写回、关闭和分离动作。

关闭当前工具先跳主页，再从已打开集合移除，避免路由监听立即把它重新加回。应用启动从 localStorage 恢复已打开路径，并过滤未注册工具、去重、压实无效缓存；最近使用记录与主页固定快捷方式使用独立存储。快捷栏最多六项，用户清空与从未配置有不同语义，后者才提供首次推荐。见[工具 store](<../../aio-hub/src/stores/tools.ts#L26-L120>)。

应用级 `sidebarMode` 选择侧栏、下拉或抽屉；后两者复用标题栏内的导航菜单。侧栏折叠宽度在主壳计算为 64px/220px，隐藏导航时为零，标题栏和侧栏的共享背景随几何更新。主壳用遮罩露出工作区左上圆角及对应玻璃效果，实际观感未运行观察。接线见[主布局状态](<../../aio-hub/src/views/MainLayout.vue#L44-L65>)和[标题栏导航入口](<../../aio-hub/src/components/TitleBar.vue#L622-L660>)。

### 1.2 按路径缓存与关闭回收

[WorkspaceRouteCache](<../../aio-hub/src/components/WorkspaceRouteCache.vue#L20-L71>)为每个路由路径生成独立具名包装组件，让 KeepAlive 的 include 按路径而非业务组件名管理缓存。每个项保留自己的页面 VNode，多个路由共用组件时也能独立回收。

主布局缓存主页、扩展与仍在已打开集合的工具；设置页不在这一集合。工具关闭后包装项和 KeepAlive include 都被移除，页面本地实例有机会卸载；仅切换到其他工具则停用并保留实例。业务模块的单例 store、后台任务和文件持久化不因此自动清除。缓存集合和路由监听见[主布局](<../../aio-hub/src/views/MainLayout.vue#L147-L166>)及[缓存消费](<../../aio-hub/src/views/MainLayout.vue#L212-L228>)。

### 1.3 按需加载面板有可行动失败态

公共 [LazyPanelHost](<../../aio-hub/src/components/common/LazyPanelHost.vue#L16-L95>)只在首次打开时导入面板，合并并发加载请求；加载中显示状态，失败显示 alert 和重新加载按钮，宿主销毁后忽略迟到结果。成功后保留面板实例，由业务显隐决定展示。标题栏的任务中心、用户档案和伴生视图已消费此机制，首次打开失败不再只剩一个无反馈的异步组件。

## 2. 设置系统与编辑工作区

### 2.1 分组、页面与模块

[设置配置](<../../aio-hub/src/config/settings.ts#L138-L239>)用五个分组组织通用、外观、AI 服务、工具与环境、高级与维护；每个页面定义说明、所属分组、模块和可选布局。桌面左侧显示分组与子页面，窄于 1000px 时换为横向分类/子页导航；右侧显示面包屑说明和当前页面模块。

当前页由 `/settings?section=...` 驱动，点击用路由替换，旧模块 ID 仍映射到所属新页面，非法值回退默认页。分离窗口的设置导航请求由主布局监听后跳到同一路由。见[设置页选择逻辑](<../../aio-hub/src/views/Settings.vue#L68-L99>)与[旧 ID 兼容](<../../aio-hub/src/config/settings.ts#L242-L260>)。

页面布局分普通表单与 workspace。CSS 覆盖、AI 渠道、模型元数据、OCR 使用后者；右侧保留页头，工作区内容填满剩余高度，业务表格/编辑器管理内部滚动。普通表单继续组合多个设置模块，字段更新通过应用设置 store 保存。见[设置主区](<../../aio-hub/src/views/Settings.vue#L398-L461>)。

### 2.2 公共编辑器与双栏差异编辑

[RichCodeEditor](<../../aio-hub/src/components/common/RichCodeEditor.vue#L128-L207>)封装 CodeMirror 和 Monaco，按编辑器类型或 diff 模式才加载 Monaco；有独立加载中、失败和重试表面。统一语言、主题、只读、换行和布局接口供消息数据、CSS、正则及文本差异等编辑消费。

diff 模式分别维护 original/modified 输入与更新事件。组件挂载后直接订阅两侧 Monaco model 的内容变化，把用户编辑回传父级；这使父级复制、保存或交换两侧时获取当前显示文本。监听器在重挂载/销毁时释放。[双侧监听](<../../aio-hub/src/components/common/RichCodeEditor.vue#L351-L374>)是数据契约，外层状态的更新以内容变化事件的回传为准。

聊天内的材料编辑、Agent 模型/上下文页签和实发请求诊断工作区属于业务入口，见[Chat UI 笔记](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)；画布编辑和版本管理的生命周期见[生成式输出与运行时笔记](<../生成式输出与运行时/AIO-Hub-生成式输出与运行时调查笔记.md>)。

## 3. 弹窗、菜单与焦点

### 3.1 BaseDialog 的显隐和关闭契约

[BaseDialog](<../../aio-hub/src/components/common/BaseDialog.vue#L17-L107>)默认 Teleport 到 body，以遮罩和容器承载内容；默认关闭销毁，也能保留实例。容器声明 dialog、aria-modal、标题名称和程序化可聚焦点，关闭按钮有名称。遮罩从标题栏下方开始，是否点击关闭由消费方配置。

关闭按钮、遮罩和 Esc 进入同一关闭方法，可先等待 `beforeClose` 返回布尔值；返回 false 保留窗口，检查期间防重复调用。随后按动画开关等待 300ms 或立即发出关闭。父级若直接改显隐状态，则不经过该主动关闭拦截。[关闭契约](<../../aio-hub/src/components/common/BaseDialog.vue#L276-L307>)可复查。聊天设置会关闭遮罩退出并保留内部状态，文本材料等需要处理未保存内容的业务可接关闭检查。

### 3.2 焦点栈与最上层 Esc

[焦点管理器](<../../aio-hub/src/composables/useOverlayFocus.ts#L44-L141>)保存打开时触发元素，DOM 更新后聚焦 autofocus 元素或弹层根；只在最上层处理 Tab 边界回环，过滤禁用、隐藏和 inert 控件。关闭/卸载时，若焦点仍属于关闭表面，则归还仍存在的入口或上一层弹窗；用户已主动移到其他控件时保留新选择。

Esc 额外要求当前弹窗是最上层、按键来自其内部、此前未被处理，且允许关闭按钮，随后阻止冒泡。嵌套弹窗因此不会一次 Escape 全部关闭。这里确认的是公共绑定；第三方浮层、Teleported 子弹层与读屏实际焦点行为仍需运行测试，完整无障碍合规属于另行审计的范围。

### 3.3 层级与菜单

[层级模块](<../../aio-hub/src/composables/useDialogZIndex.ts#L16-L104>)从 2000 的底值出发，分配时参考 Element Plus 高水位、用户首选层级和当前计数器；维护活跃集合，最后一个 BaseDialog 关闭后重置到库高水位。活跃集合决定释放边界，计数器只负责后续分配。

会话项右键、更多按钮、Shift+F10 和菜单键统一打开 Element Plus dropdown；全局仅一个会话项菜单打开。树图另有跟随坐标的 Teleport 上下文菜单，具有越界校正和外部点击关闭；本次在该自绘菜单入口未找到完整方向键导航。两者不能共用“菜单均不支持键盘”的结论。业务入口详见[Chat UI 笔记](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)。

## 4. 即时提示、通知与错误恢复

### 4.1 顶部浮动提示

[customMessage](<../../aio-hub/src/utils/customMessage.ts>)持有公共队列，[TopMessageHost](<../../aio-hub/src/components/common/TopMessageHost.vue#L37-L153>)渲染带倒计时、悬停暂停、关闭和复制反馈的消息。重复分组累加次数并重置计时；内容可为文本、VNode 或显式开启的 HTML，错误处理器使用 VNode。

宿主监听覆盖层变化，层级根据活跃 BaseDialog、Element Plus 和可见 DOM 覆盖层高水位计算，再提高 10 并限制到 9990，保留标题栏 9999 在上方。默认顶部偏移仍为 54px。层级规则见[提示层级计算](<../../aio-hub/src/composables/useDialogZIndex.ts#L117-L144>)，实际遮挡与堆叠像素未实测。

错误提示把用户说明和截断后的友好摘要用于展示，完整模块、用户说明和原始错误组成复制文本；点击提示不受可见摘要截断影响。普通错误 5 秒，信息和警告 3 秒；严重错误走不自动关闭的 Element Plus Notification。分级与复制契约见[错误展示](<../../aio-hub/src/utils/errorHandler.ts#L301-L389>)。

### 4.2 持久通知与后台任务反馈分工

[通知 store](<../../aio-hub/src/stores/notification.ts#L20-L80>)保存列表、未读与通知中心显隐，列表落 localStorage 并监听 storage 更新；[通知中心](<../../aio-hub/src/components/notification/NotificationCenter.vue>)提供搜索、分页、标记已读、清空确认、Markdown 详情，以及按可选路径返回业务。版本说明与升级引导也从此进入。

后台子 Agent 使用标题栏胶囊、任务中心、派遣卡片和伴生视图，不要求先进入持久通知中心。标题栏订阅任务注册表并把事件合并刷新，点击进入子会话或任务中心。完整用户路径见[Chat UI 笔记](<../Chat UI/AIO-Hub-ChatUI调查笔记.md#L129-L135>)。当前在桌面前后端对通知插件、发送通知和请求窗口注意力 API 的检查中，未找到生成完成接操作系统通知的链路；后台任务的完成反馈走上述应用内通道。

### 4.3 加载、空态与错误边界

聊天有模拟三栏的启动骨架；业务空态仍保留完整工作台框架，新会话草稿与历史会话为空有不同说明。公共异步面板和 Monaco 加载有状态/重试表面，附件导入则区分导入中、转换中、加载失败和导入失败，各业务控制重试动作。

[主入口](<../../aio-hub/src/main.ts>)注册 Vue 全局错误/警告处理，以及浏览器 error 和 unhandledrejection；白名单过滤 Popper 卸载竞态和 ResizeObserver 良性警告，其余进入统一错误反馈与前端探针。Rust [前端监测](<../../aio-hub/src-tauri/src/frontend_monitor.rs>)接收错误/心跳，记录窗口健康日志；Linux 启动超时另有诊断覆盖层。启动失败界面提供重试、复制错误和问题链接。检查这些入口和 ErrorBoundary 关键词，本次未找到全应用组件级错误边界；少数工具拥有局部捕获，不可据此泛化全局降级行为。

## 5. 主题、外观与 CSS 覆盖

### 5.1 三层主题与文件权威源

| 层 | 状态与结果 |
|---|---|
| 明暗 | auto/light/dark；读取系统偏好并在 auto 模式监听系统变化 |
| 色阶 | 五个语义色写入应用与 Element Plus token，生成明暗与 hover 色阶 |
| 外观 | 壁纸、混合、透明度、毛玻璃、边框、窗口特效等计算为 CSS 变量和原生窗口调用 |

[明暗状态](<../../aio-hub/src/composables/useTheme.ts#L19-L87>)由共享 composable 管理，切换通过应用设置 store 保存；[应用设置](<../../aio-hub/src/stores/appSettingsStore.ts#L25-L70>)以 300ms 防抖写文件，也提供需要后端立即读取时的即时保存。设置文件路径由[应用设置管理器](<../../aio-hub/src/utils/appSettings.ts#L418-L433>)配置，应用持久化统一从应用配置目录解析。

[色阶引擎](<../../aio-hub/src/utils/themeColors.ts>)生成应用变量和 Element Plus 色阶，并缓存部分颜色到浏览器存储供启动使用。壁纸主色经 OKLCH 明度/彩度修正，自动提取色还避让成功、警告等语义色相；手选主色不经过自动避碰。颜色修正是实现规则；对比度结论需按修正后的前景与背景组合在实际渲染中测量。

### 5.2 外观、壁纸与原生窗口

[外观系统](<../../aio-hub/src/composables/useThemeAppearance.ts>)支持静态或轮播壁纸、自定义目录、填充模式、轮播顺序和索引记忆。背景叠加色使用 ColorThief，主题主色使用 node-vibrant，两种开关独立；切换壁纸或明暗时按配置重新取色。混合模式应用到侧栏、卡片、标题和输入等语义背景，分层透明度与模糊由 token 控制。

CSS 毛玻璃与系统 Mica/Acrylic/Vibrancy 是两条通道；后者走原生窗口命令并受平台支持限制。分离窗口隐藏全局壁纸，使用独立底层背景和透明度，同时保留壁纸变量供内部组件使用。[外观设置页](<../../aio-hub/src/views/Settings/general/ThemeAppearanceSettings.vue>)提供壁纸管理、取色、质感和窗口效果入口。

iframe 预览通过[主题桥接](<../../aio-hub/src/composables/useIframeTheme.ts>)注入计算后的主题变量；外部单色 SVG 由[主题图标适配](<../../aio-hub/src/composables/useThemeAwareIcon.ts>)处理，彩色图标保留自身颜色。主题变量参与内容展示，具体 HTML 承载边界见渲染器笔记。

### 5.3 全局自定义 CSS 与启动恢复

[CSS 设置工作区](<../../aio-hub/src/views/Settings/css/CssOverrideSettings.vue>)提供启用、纯自定义、基于预设、用户预设与应用预览；两种编辑内容分字段保存。编辑变化即时应用，500ms 防抖持久化。

[覆盖状态](<../../aio-hub/src/composables/useCssOverrides.ts>)把文本原样注入当前文档 head 的 style 节点，未在此路径做选择器作用域或规则净化。启动恢复拆为无状态入口，主窗口与分离窗口加载应用设置后、主题服务初始化前调用。见[初始化 store](<../../aio-hub/src/stores/appInitStore.ts#L80-L105>)。重启恢复无需先打开设置页；一个窗口运行期修改后其他已开窗口何时跟随仍需独立核实。

首屏的防闪由原生窗口初始隐藏、静态 splash 明暗媒体查询和异步主题恢复共同组成。当前[HTML 入口](<../../aio-hub/index.html>)的内联脚本主要做 WebView 兼容检测，本次未找到挂载前恢复用户固定主题的脚本；固定主题与系统偏好相反时是否出现可见切换帧尚未运行验证。

## 6. 公共预览、拖放与尺寸调整

图片查看使用 viewerjs，项目封装图片列表、初始索引、主题、打开/关闭和与公共焦点栈的配合；缩放、旋转、翻转、全屏及库内部快捷键由依赖提供。show 回调取得 viewerjs 生成的弹层根并开启项目焦点会话，hidden 时释放；内联模式或显式关闭 focus/keyboard 时跳过接管，见[图片查看器](<../../aio-hub/src/components/common/ImageViewer.vue#L90-L143>)。音视频查看器也接入公共焦点管理与加载失败反馈，原生播放体验仍依赖 WebView 和媒体格式。

[DropZone](<../../aio-hub/src/components/common/DropZone.vue#L17-L72>)提供内置“选择文件”按钮，需消费方允许点击；整区点击需额外开启 clickZone，才为区域加 button 语义和 tabindex。根区域绑定 Enter/Space，处理器按禁用、clickable 和 clickZone 判断是否打开。[使用规范](<../../aio-hub/AGENTS.md>)要求内置按钮原生键盘交互独立可用；当前根监听仍无条件使用 prevent，且处理器未检查事件来源，静态接线与规范在此有差异，嵌套按钮的实际键盘行为待运行核实。它支持直接传 H5 File 或 Tauri 路径，并可配置优先 File，以免同一次拖入被处理两次。

底层 [useFileDrop](<../../aio-hub/src/composables/useFileDrop.ts>)融合 H5 拖放和 Tauri 拖放事件：前者可给 File 数据，后者可给绝对路径；需要路径的消费方留有短融合窗口，无法取得路径时提示使用文件选择器。导入数量、扩展名、大小和错误策略由组件与业务设置共同控制，不能把通用拖放存在当作任意文件均可导入。

公共 [useResizable](<../../aio-hub/src/composables/useResizable.ts>)管理侧栏与面板尺寸、鼠标捕获期光标和文本选择；聊天两侧栏和伴生栏分别设边界。分离输入框宽度进一步进入原生窗口 resize，区别于网页内部面板大小。内部排序列表复用 VueDraggableNext fallback 拖拽，与系统文件拖放是两条交互通道。

## 7. 状态所有权、窗口同步与桌面集成

| 状态 | 所有者 / 持久化 / 连续性 |
|---|---|
| 应用主题、工具可见性、导航模式、CSS 等 | 应用设置 store / 应用配置文件；窗口启动时自行加载 |
| 已打开工具、最近使用与主页固定项 | 工具 store / localStorage；打开列表用于路径恢复与缓存集合 |
| 页面本地表单、滚动及子面板 | 组件与 KeepAlive；关闭标签可销毁，重启后组件实例重新创建 |
| 公共浮层焦点、层级、顶部消息队列 | 当前 WebView 的模块状态，未见跨窗口浮层队列 |
| 通知 | 通知 store / localStorage；storage 事件重新加载 |
| 聊天运行态和动作 | WindowSyncBus、状态同步引擎与操作代理；流式正文有专门增量事件 |
| 窗口位置、尺寸、最大化 | Rust 窗口配置模块 / 窗口配置文件 |

[窗口总线](<../../aio-hub/src/composables/useWindowSyncBus.ts>)包含握手、心跳、全量/增量状态、初始批量状态和操作请求/响应；操作有超时，重连有防抖。协议的静态契约止于消息格式与超时设置；断连和高并发下是否丢消息，取决于心跳、重连与增量状态的实际到达时序，需在运行中观察。聊天专用消费见[聊天同步](<../../aio-hub/src/tools/llm-chat/composables/chat/useLlmChatSync.ts>)。

主题 composable 还发 DOM CustomEvent，但本次搜索该事件未找到订阅者；它不构成跨 WebView 主题同步。应用设置未见通用文件监听广播，不能把多个窗口共享同一配置文件写成运行期实时同步。

[系统托盘](<../../aio-hub/src-tauri/src/tray.rs>)提供主窗口显隐、前端重启、清除窗口配置和退出等应用动作；标题栏另有下载、通知、用户档案和后台任务入口。托盘动态聊天状态与操作系统生成完成通知本次未找到。窗口关闭、退出确认、分离与重新附着由主布局 Tauri 监听及 Rust 窗口模块协同，未做真实平台走查。

移动端拥有独立应用根和 UI 组件，Varlet 作为叶子控件，同时使用 AIO token 和原生 Vue 页面骨架；本轮只复核移动渲染器交点，没有审计移动导航、触摸与安全区。不能用桌面工具页缓存或 BaseDialog 推定移动端全部交互一致。

## 8. 设计取舍与验证边界

路由缓存和领域持久化明确分层：切工具保留现场，关工具回收表面；后台任务和业务数据可继续由单例或服务持有。设置配置同时表达信息架构与内容布局，编辑型页面拥有固定框架和独立滚动，普通表单继续按模块装配。

焦点管理、浮层层级和消息宿主已形成公共机制，但它们仍与 Element Plus、viewerjs、自绘上下文菜单等并存；公共能力的改动需要结合业务消费条件判断，不能从一处标签推定全应用行为。

本轮未启动服务、未修改源码、未运行构建或测试。引用现有测试只说明仓库已有契约覆盖，未声明本轮通过。以下仍待运行或专项核实：

- 设置页窄窗切换、工作区滚动、标题栏共享背景、玻璃效果及主题首帧。
- 嵌套弹窗、Teleported 子浮层、模型选择和媒体查看器的实际焦点顺序、键盘与读屏表现。
- 顶部提示动态层级、堆叠、暂停、复制成功/失败的真实视觉与交互。
- 页面停用/关闭后的内存回收、跨窗口重连、文件写入失败和运行期主题同步。
- Windows/macOS/Linux 原生窗口特效、托盘、文件拖放与媒体播放。
- GuidedFlow 首次启动/升级恢复和 watchdog 异常场景的实际体验。

## 9. 关键源码索引

- [MainLayout](<../../aio-hub/src/views/MainLayout.vue>)、[WorkspaceRouteCache](<../../aio-hub/src/components/WorkspaceRouteCache.vue>)：应用壳与页面生命周期。
- [设置页](<../../aio-hub/src/views/Settings.vue>)、[设置配置](<../../aio-hub/src/config/settings.ts>)：两级导航与工作区布局。
- [BaseDialog](<../../aio-hub/src/components/common/BaseDialog.vue>)、[焦点管理](<../../aio-hub/src/composables/useOverlayFocus.ts>)、[层级管理](<../../aio-hub/src/composables/useDialogZIndex.ts>)：公共浮层契约。
- [GlobalProviders](<../../aio-hub/src/components/GlobalProviders.vue>)、[LazyPanelHost](<../../aio-hub/src/components/common/LazyPanelHost.vue>)：全局与按需面板装配。
- [RichCodeEditor](<../../aio-hub/src/components/common/RichCodeEditor.vue>)：代码和差异编辑契约。
- [外观架构](<../../aio-hub/docs/architecture/theme-system-architecture.md>)、[虚拟列表布局](<../../aio-hub/docs/architecture/virtual-list-layout.md>)：辅助设计材料，以可执行入口为准。
