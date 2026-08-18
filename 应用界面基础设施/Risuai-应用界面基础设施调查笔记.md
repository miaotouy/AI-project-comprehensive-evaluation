# Risuai 应用界面基础设施调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用根装配和公共实现入手，抽样核对业务消费方；依赖内部行为与运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题与视觉 token、响应式与移动端、常见内容交互、状态所有权，以及无障碍、动画、桌面集成、国际化、设置框架五项扩展调查；聊天业务主链和消息内容渲染分别由 Chat UI 与消息渲染器类目承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 是 Svelte 5 + Tailwind CSS 4 的单页应用，没有路由，根组件用条件渲染切换全屏模式，并在根节点尾部统一挂载一批浮层宿主。弹窗没有共享基座：业务弹窗是各自手写的 `fixed inset-0` 遮罩组件；全局命令式交互走单一 `alertStore`，由 `AlertComp` 渲染成"一次只能有一个"的模态框、等待框或右下角自动消失的 toast。

主题权威源是保存在加密存档文件里的数据库对象。17 套内置配色预设和自定义配色通过运行时改写 CSS 变量生效，另有独立的文字主题、字体、自定义 CSS 和布局主题（waifu 等）；全仓库未找到 prefers-color-scheme，不跟随系统深浅色。响应式由窗口宽度驱动的 `DynamicGUI`（≤1024px）与 `MobileGUI`（≤800px）两级状态和 Tailwind 断点类共同承担，移动端有独立的三屏骨架和滑动手势。

内容交互方面，应用级拖放只有一条公共通道：根元素负责文件拖入导入，自定义 MIME 类型标记用于阻断内部拖拽；列表排序用 SortableJS 共享参数，触屏缺失 HTML5 拖放时用 mobile-drag-drop 打补丁。应用有全局错误边界：window error 与 unhandledrejection 都汇入错误模态框。

## 系统边界与总体装配

**入口。** `index.html` 只挂 `#app` 容器和 `#preloading` 静态加载层（index.html:19-37），`src/main.ts` 挂载 App 后移除预加载层，并行执行 `loadData()`（bootstrap）与 `initHotkey()`（main.ts:16-21）。

**根装配。** `src/App.svelte` 是唯一根组件：先按优先级条件渲染整屏模式——法律声明页、愚人节彩蛋、加载中（`loadedStore` 为假）、自定义 GUI 编辑、首次设置欢迎页、设置页、移动端骨架，最后是桌面布局（侧栏 + ChatScreen，或角色网格）；随后在 `<main>` 尾部统一渲染各浮层宿主（App.svelte:196-281）。全部模式切换都是 Svelte 条件块，没有路由表。

**浮层宿主清单。** 根节点尾部按固定顺序挂载全部浮层宿主（App.svelte:238-281）：全局命令类只有 AlertComp 与 PopupList 两个；其余是业务模态——Realm 系列、预设与人设列表、书签列表、HypaV3 模态与进度、插件警报、EasyPanel、PopupEditor、LoadoutModal、IrisModal、自定义侧栏配置对话框，以及常驻的保存状态图标。这些宿主由各自 store 的布尔字段或快照字段控制。

**无 Provider 概念。** 项目没有全局 Provider 树；需要把子组件挂到其它 DOM 位置时用自研 Portal 工具——`Portal.svelte` 通过 `getAllContexts()` + `mount()` 把内容挂到目标节点，`LazyPortal.svelte` 额外用 IntersectionObserver 在目标可见过半后才挂载（Portal.svelte:16-22、LazyPortal.svelte:19-40）。

**多窗口与多入口。** Tauri 配置只声明一个窗口（tauri.conf.json:52-63），Rust 侧注册了单实例插件（main.rs:570-578），因此不存在跨窗口同步问题。`src/LiteMain.svelte` 是一个独立于 main.ts 的轻量入口，本次未在构建配置或任何导入中找到引用，按静态推断为未接线的测试入口；`src/lib/UI/3DLoader.svelte`（three.js 加载器）同样未被任何组件导入。

## 1. 界面栈、公共组件与状态所有权

**界面栈。** Svelte 5 runes 写法为主，部分旧组件用 writable store；样式是 Tailwind CSS 4（`src/styles.css` 的 `@theme` 块），图标用 lucide-svelte。第三方 UI 依赖里，tippy.js 承担 tooltip，SortableJS 承担列表排序，highlight.js 做代码高亮，Monaco 编辑器在 PopupEditor 里按需动态导入；没有现成组件库，全部自研。

**公共组件。** `src/lib/UI/GUI/` 提供输入类基础件（Button、TextInput、SelectInput、SliderInput 等十余个），是设置页与表单的主要积木；业务组件大多直接消费它们，没有更高层的"设计系统"封装层。

**状态所有权。** 整个应用数据是 `DBState` 这一个 `$state` 代理对象（结构定义在 database.svelte），界面偏好、主题、角色与聊天全在其中；瞬时 UI 状态由 `stores.svelte.ts` 的 writable store 与 `$state` 对象承担（如 `settingsOpen`、`alertStore` 等），不落在主进程或服务端。

**持久化。** 存档写入由 `saveDb` 完成：`$effect.root` 内对各字段做 `$state.snapshot` 跟踪，任一变化延迟 500ms 后落盘（globalApi.svelte.ts:330-389 起），Tauri 下走文件系统、Web 下走 localforage，最终编码为加密存档文件。

## 2. 弹窗、浮层与菜单

**命令式模态：alertStore 单一模态。** `src/ts/alert.ts` 用约二十种 type 区分场景（error、normal、toast、progress 等），全部写入同一个 writable store；AlertComp 按 type 渲染成模态框、toast 或全屏 iframe（login）。调用方式是"设值 + 轮询等待"：`waitAlert()` 每 10ms 检查 type 是否为 none 再继续（alert.ts:76-83）。因此同一时刻只有一个模态框，不可堆叠，后到者覆盖先到者。

**模态框行为。** AlertComp 主模态（AlertComp.svelte:189-191）外层遮罩没有点击关闭，只能通过按钮或全局按键关闭；`hotkey.ts:241-258` 里 Esc 把 type 置为 none 并弹一条 "Alert Closed" toast，Enter 对 ask/normal/error 直接按 yes 关闭。错误类型有专门的详情区：可展开的堆栈跟踪、复制按钮，以及基于 sourcemap 的堆栈翻译（AlertComp.svelte:259-287）。`cardexport` 类型是唯一带"点遮罩关闭"的主模态变体（AlertComp.svelte:726-729）。

**业务模态：各自手写。** 十余个业务模态组件（如 BookmarkList、LoadoutModal、PopupEditor、EasyPanel）共用同一种手写模式："`fixed inset-0` 半透明遮罩 + 内容层 + 点击内容 stopPropagation"，遮罩普遍带 `role="button" tabindex="0"` 和点击关闭。层级只有零散的 z-30/z-40/z-50 约定，没有统一层级注册表，同层浮层靠挂载顺序决定上下。

**上下文菜单：popupStore。** `popupStore` 保存要渲染的 Snippet、鼠标坐标和 openId（stores.svelte.ts:152-157）；PopupList 在根节点挂载，按鼠标位置在四分之一象限翻转定位，打开期间在 document 上注册一次性 click 监听，任何点击都关闭（PopupList.svelte:6-37）。消费方是 PopupButton——消息操作栏的"菜单"按钮，点击时写入当前坐标再切换开关（PopupButton.svelte:15-26）。

**Tooltip 与长按。** tooltip 是 tippy.js 包装的 Svelte action，`tooltip` / `tooltipRight` 两个指令，fade 动画、translucent 主题（tooltip.ts:5-38）；长按用 `longtouch.ts` 的 500ms action，按下后移动或抬起即取消，用于消息删除的右键替代（Chat.svelte:755）。

## 3. 通知、加载态与错误反馈

**通知没有独立系统。** 站内提示全部复用 alertStore：`alertToast` 走右下角 toast 分支，CSS 动画 1s 淡入淡出，`animationend` 事件触发自动关闭（AlertComp.svelte:806-814、1073-1087）。toast 单条显示、不堆叠、没有队列、不能点击取消。由于 hotkey 的 Esc 处理也会把 alert 置为 none，任何模态都可以被 Esc 直接关掉。

**系统通知。** 生成完成后若 `DBState.db.notification` 开启，走 Web Notification API 弹出标题为 "Risuai" 的浏览器通知，点击后 `window.focus()`（process/index.svelte.ts:1947-1961）。设置页的 NotificationToggle 会先查权限再启用（NotificationToggle.svelte:12-29）；Chromium 系浏览器持久化存储还会借用通知权限流程（persistant.ts:18-25）。没有 Tauri 通知插件或托盘。

**加载与进度。** 首屏是 index.html 静态预加载层，挂载完成后由 main.ts 直接移除；随后加载中状态由 `loadedStore` 与 `LoadingStatusState.text` 驱动，bootstrap 在各个阶段更新文案（检查文件、读存档、解码、加载插件等，bootstrap.ts:55-268）。

阻塞型等待用 `wait`/`wait2` 类型模态（wait2 额外加 `.vis` 强制不透明），百分比进度用 `progress` 类型进度条（AlertComp.svelte:190、289-296）；存档保存中显示 `SavePopupIconComp` 动画图标，其状态来自全局 `saving` 字段（SavePopupIcon.svelte:10-15）。

**错误边界。** bootstrap 的 `updateErrorHandling()` 给 window 挂 error 与 unhandledrejection 监听，把异常统一转成 alertError 模态（Worker 内错误被排除），这是应用级渲染崩溃兜底（bootstrap.ts:289-302）。alertError 对 "Failed to fetch" 类网络错误会附加按平台区分的提示文案并保留堆栈（alert.ts:31-74）。Vite 分包加载失败另有 `vite:preloadError` 的浏览器 alert 兜底（main.ts:10-13）。

## 4. 主题、视觉 token 与持久化

**权威源。** 主题相关状态全部在数据库对象上：配色与自定义配色、自定义 CSS、文字主题、字体，以及布局主题 `theme`、动画速度 `animationSpeed`、高度模式 `heightMode`。它们随存档持久化，没有 localStorage 参与；bootstrap 加载完存档后统一调用 `updateColorScheme()` 与 `updateTextThemeAndCSS()` 应用（bootstrap.ts:231-233）。

**配色机制。** `src/ts/gui/colorscheme.ts` 内置 17 套预设（default 即 Dracula、dark、light、cherry、galaxy、nature、ocean、aurora、twilight、realblack、monokai 两套、四套浅色和 lite）。`updateColorScheme()` 把 9 个颜色逐项写到根元素的 `--risu-theme-*` 变量（colorscheme.ts:260-286），styles.css 的 :root 静态默认值就是 Dracula 配色，Tailwind 的 `@theme` 再把 `bg-bgcolor` 等工具类映射到这些变量（styles.css:5-15）——整套主题是运行时改写 CSS 变量，不换 CSS 文件。`ColorSchemeTypeStore` 同步暗/亮标记，prose-invert 等样式读它。

**文字主题与字体。** 由 `updateTextThemeAndCSS()` 应用：standard/highcontrast/custom 三档写 `--FontColor*` 系列变量，字体写 `--risu-font-family`（默认 Arial），`* { font-family: var(--risu-font-family) }` 全局生效（styles.css:346-348、colorscheme.ts:335-413）。

自定义 CSS 经 CustomCSSStore 写入 `#customcss` 样式元素（stores.svelte.ts:70-82），安全模式 SafeModeStore 开启时清空，避免坏 CSS 影响排查。

**系统跟随与首帧。** 全仓库 grep prefers-color-scheme 无匹配（唯一 matchMedia 用在 display-mode 独立模式判断，bootstrap.ts:219），主题完全手动选择。首帧观感是 :root 静态默认色，直到存档加载完成才被用户主题覆盖；index.html 没有内联主题脚本，是否存在可见闪烁未运行验证。

**布局主题。** 数据库 `theme` 字段控制聊天界面布局，取值如下（选项定义见 displaySettingsData.svelte.ts:14-50）：

- 空字符串：Standard，经典桌面双栏；
- `waifu`：立绘 + 聊天窗两栏（waifuMobile 为聊天窗 33% 高的移动形态）；
- `mobilechat`、`cardboard`：消息布局与卡片样式；
- `customHTML`：自定义聊天 HTML。

自定义 GUI 编辑走 CustomGUISettingMenuStore 打开独立整屏编辑器（App.svelte:208-209）。注意：AGENTS.md 所称 Classic/WaifuLike/WaifuCut 与源码不符，源码中不存在 WaifuCut 取值，经典模式就是空字符串——以源码为准。

## 5. 响应式、移动端与窗口适配

**两级窗口状态。** `DynamicGUI`（≤1024px）与 `sideBarStore`（初始 >1024px 为开）由 `updateSize()`（stores.svelte.ts:10-16）在初始化与 resize 时刷新。DynamicGUI 为真时侧栏在 App.svelte 里变成可覆盖式浮层（App.svelte:224-234），为假时侧栏是内联布局。

**移动端独立骨架。** `MobileGUI` 在窗口宽 ≤800px（betaMobileGUI 开启）或 VITE_RISU_LITE 时启用（bootstrap.ts:246-249）。MobileBody 用 `MobileGUIStack` 三屏切换（Realm 主界面 / 角色网格 / 设置），聊天中再由 `MobileSideBar` 在聊天列表、角色配置与开发工具间切换（MobileBody.svelte:37-55）；顶栏返回/搜索与底部三 Tab 分别位于 Mobile 目录的 Header、Footer 组件。

移动端滑动手势由 `initMobileGesture()` 实现：横向位移超过 50px 且以横向为主时切换上述栈（hotkey.ts:362-411）；三指点击走 quickMenu 快捷菜单（hotkey.ts:264-283）。

**断点与设置页。** 除 Tailwind 默认断点类（sm/md/lg）外，设置页还用 JS 判断窗口宽度：≥900px 自动打开左侧菜单、≥700px 双栏（Settings.svelte:28-35）；消息操作图标在 <640px 时收进 PopupButton 菜单（Chat.svelte:484-500）。styles.css 本身没有自写媒体查询。

**高度与窗口。** 高度模式 `heightMode` 在 bootstrap 里映射为 `--risu-height-size`（从 auto 到 vh/dvh/lvh/svh 等视口单位，bootstrap.ts:307-330），html/body 高度取自该变量（styles.css:244-247）。

Tauri 单窗口最小 300×500，`dragDropEnabled: false` 关掉原生文件拖入，改由网页层处理（tauri.conf.json:52-63）；全屏切换在 Tauri 下走窗口 API（util.ts:221-230）。Web 端另有 PWA manifest、独立模式检测与离开拦截（preload.ts:14-21）。

## 6. 图片、附件、拖放与常见内容交互

**图片没有灯箱。** 消息内图片由解析器按资产占位符渲染成内联 `<img>`（parser.svelte.ts:479-576），聊天正文整体在 `clickToEdit` 开启时点击进入编辑（Chat.svelte:428-432）；没有找到点击放大、全屏查看或预览器组件。资产图加载后追加 `root-loaded-image` 类控制居中与尺寸（ChatBody.svelte:173-243）。附件输入（inlay）在输入区直接预览 image/video/audio（DefaultChatScreen.svelte:732-749）。

**文件拖入只有一条公共通道。** App.svelte 的 `<main>` 在 dragover 时按 dataTransfer 类型决定 dropEffect，在 drop 时按扩展名分流：.risup 导入预设、.risum 导入模块、其余走角色卡导入；内部拖拽类型（`application/x-risu-app-internal-drag`、`application/x-risu-sidebar-drag`）在根节点被直接拦截，不会误走文件导入（App.svelte:49-101、73-77）。

**应用内拖拽协议。** `src/ts/dragTypes.ts` 定义 6 个自定义 MIME 类型（应用内部、效果、预设、提示词、侧栏、触发器），约定 dragstart 写类型、dragover/drop 校验类型后 stopPropagation，使事件到不了根元素的文件导入处理器；文件头部注释要求新拖拽功能复用同一模式。侧栏角色/文件夹拖拽（Sidebar.svelte:331-370、729-733）与触发器列表（TriggerV2List.svelte:2499-2500）是主要消费方；Ctrl+拖拽角色卡时触发滚动到活跃角色（hotkey.ts:288-304）。

**列表排序。** SortableJS 在聊天列表、Lorebook、正则、触发器 v1、人设列表等处各自初始化，但共享 `sortableOptions`：触摸端延迟 300ms、`.no-sort` 过滤（util.ts:1091-1098）。触屏设备或 iOS 上不支持原生 draggable 时，用 mobile-drag-drop 补丁（polyfill.ts:23-39），滚动行为按库的 scroll-behaviour 覆盖。

**剪贴板。** 没有公共剪贴板服务，各组件直接调 `navigator.clipboard.writeText`；AlertComp 的复制按钮带 execCommand 兜底（AlertComp.svelte:94-110），代码块右键菜单提供 Copy/Download（observer.svelte.ts:10-53），消息复制会先解析成富文本再写剪贴板（Chat.svelte:511-539）。PDF 预览通过动态导入 pdfjs 在业务层实现（process/dynamicutils/pdf.ts:25-38）。

## 7. 扩展调查

### 无障碍

静态证据有限：没有找到焦点陷阱或系统化焦点归还。唯一可见的焦点动作是 AlertComp 打开时尝试 `btn.focus()`（AlertComp.svelte:120-127），但全文件没有 `bind:this={btn}`，静态推断该引用为空、动作不生效。

键盘通路主要是全局 keydown 的 Enter/Esc 处理（hotkey.ts:241-258）与可配置快捷键系统（initHotkey），后者在输入框聚焦且无修饰键时跳过（hotkey.ts:13-21）。若干较新模态（IrisModal、LoadoutModal）带 aria-label 与 aria-live；多个遮罩使用 `role="button" tabindex="0"` 但没有对应键盘处理器。vite.config 构建层面整体关闭了 Svelte 的 a11y 告警（vite.config.ts:12-16）。以上均为静态证据，读屏与键盘实际表现未运行验证。

### 动画与过渡

动画以零散 CSS 为主：`--risu-animation-speed` 全局时长变量（默认 0.2s，animation.ts 由设置写入）、toast 的 1s fade 关键帧、存档保存的 saving-anime、Tailwind 的 animate-spin/pulse、tippy fade。没有统一缓动 token 或动画库（three.js 只出现在未被引用的 3DLoader）。全仓库 grep prefers-reduced-motion 无匹配，未发现 reduced-motion 处理。

### 桌面与系统集成

Rust 侧只做网络与 OAuth 桥接：`native_request`/`streamed_fetch` 命令转发 HTTP 并把响应 base64 回传，`oauth_login` 走 PKCE 后把授权页 URL 事件化（main.rs:34-184、432-564）。

Tauri 集成点全部是官方插件：单实例、更新器（passive 安装模式）、deep-link 自定义协议 risuailocal、文件关联 .risum/.risup/.charx 与 http、shell、process、dialog、os、fs 等，均在 tauri.conf.json 声明；更新提示与下载安装复用 alert 模态链（update.ts:46-92）。本次未在 Rust 或前端代码中找到托盘、原生菜单、窗口注意力或系统通知插件的证据。

### 国际化与本地化界面机制

7 种语言（en/ko/cn/zh-Hant/vi/de/es），机制是把英文包作为基座、用 lodash merge 覆盖目标语言文件（lang/index.ts:13-35），`language` 是普通可变对象而非响应式 store；语言在存档加载时应用（database.svelte:720），设置切换即时生效。目录中每种语言文件行数差异明显（如 zh-Hant 对 en 是覆盖式），未运行验证界面完整性。未找到 RTL 布局或日期格式本地化处理。

### 设置框架

设置页是数据驱动框架：`ts/setting/` 下每个设置页定义 `SettingItem[]`（id、type、bindKey、condition 等），SettingRenderer 按 type 从 `settingRegistry` 取包装组件渲染（SettingRenderer.svelte:33、settingRegistry.ts:18-31）。

12 种类型从 checkbox、文本输入覆盖到 accordion 与自定义组件，自定义组件经 customComponents.ts 注册（如 ColorSchemeSelect、NotificationToggle）；条件函数接收 `{db, modelInfo, subModelInfo}` 上下文实现按模型显隐（types.ts:15-17）。左侧菜单支持插件经 additionalSettingsMenu 注册额外页。关键词字段为将来搜索预留，本次未找到设置搜索 UI 的消费点。

## 8. 设计取舍与已确认边界

**无路由、根组件整屏切换。** 模式切换全部是条件渲染，浮层也全部挂在根节点；好处是状态全局唯一，代价是模式与浮层的组合在根组件集中增长。

**命令式交互收敛到单一模态。** alertStore 同时承担模态、确认、输入、选择、等待、进度与 toast，一次一个、无堆叠；与业务各自手写 fixed 模态并存，两条路径互不共享底层。

**主题全量进存档。** 主题、布局、字号、自定义 CSS 与业务数据同库持久化，无独立主题文件格式、无导入导出主题包（配色可单独导出/导入 JSON，colorscheme.ts:296-333）、无系统跟随。

**文档与实现不一致。** AGENTS.md 声称的主题取值（Classic/WaifuLike/WaifuCut）在源码中找不到 WaifuCut；实际布局主题取值见第 4 节，以源码为准。

**Tauri 原生拖放关闭。** `dragDropEnabled: false` 配合根元素 HTML5 拖放通道，文件导入与内部拖拽通过自定义 MIME 类型严格分流（dragTypes.ts 头注释是这套协议的规范说明）。

**全局错误边界存在。** 与多数自研 Web 应用不同，Risuai 有 window error/unhandledrejection 钩子并汇入错误模态（见第 3 节）。

**未接线组件。** LiteMain.svelte 与 3DLoader.svelte 未被引用，按静态推断为遗留或测试入口，不代表存在对应能力。

## 9. 未验证事项

- 全部视觉表现、焦点顺序、模态遮罩行为、Toast 时长与动画观感、响应式切换手感、移动端滑动阈值、系统通知弹窗与权限流程均需运行验证。
- tippy.js、SortableJS、mobile-drag-drop、Tauri updater/dialog 等依赖内部行为未下钻；polyfill 在 iOS 上的实际拖拽表现未实测。
- 主题首帧从静态 Dracula 默认色切换到用户主题的可见闪变窗口未实测。
- `btn.focus()` 空引用、LiteMain/3DLoader 未接线、键盘 a11y 状态均为静态推断，未运行注入验证。
- 多语言覆盖的完整性、设置项 condition 的全部触发组合、vite:preloadError 与存档损坏回退路径未运行验证。
- 设置关键词字段的搜索消费点本次未找到，不能据此断言搜索功能不存在。

## 10. 关键源码索引

- `src/App.svelte`（根装配与浮层宿主）
- `src/main.ts`、`src/index.html`、`src/ts/bootstrap.ts`（入口与启动链）
- `src/ts/stores.svelte.ts`（全局瞬时状态）
- `src/ts/alert.ts`、`src/lib/Others/AlertComp.svelte`（命令式模态与通知）
- `src/ts/gui/colorscheme.ts`、`src/styles.css`（主题权威源与 token）
- `src/ts/dragTypes.ts`、`src/lib/UI/PopupList.svelte`、`src/lib/UI/PopupButton.svelte`（拖放协议与上下文菜单）
- `src/ts/hotkey.ts`（键盘与移动手势）
- `src/ts/globalApi.svelte.ts`（saveDb 持久化）
- `src/lib/ChatScreens/ChatScreen.svelte`、`src/lib/Mobile/`（布局主题与移动端骨架）
- `src/ts/setting/`、`src/lib/Setting/SettingRenderer.svelte`（设置框架）
- `src-tauri/src/main.rs`、`src-tauri/tauri.conf.json`（桌面侧边界）
