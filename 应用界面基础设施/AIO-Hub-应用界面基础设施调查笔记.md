# AIO-Hub 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对（Grep + Read 全文阅读），逐条标注文件+行号；没有代码证据的能力明确标为"未找到"
>
> 调查范围：弹窗库 BaseDialog（Esc/遮罩/z-index/焦点）、Toast 三级反馈与通知中心、加载/骨架屏/空状态、拖放与尺寸调整、右键菜单、主题与深色模式、无障碍盘点、响应式断点、动画、图片灯箱与头像管理、设置面板与首次启动引导、桌面集成（托盘/无系统通知）、界面层未找到能力清单；聊天主链交点（消息操作、树图视图、流式反馈等）由 [`../Chat UI/AIO-Hub-ChatUI调查笔记.md`](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>) 承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO-Hub 是 Tauri 桌面应用（Vue 3 + Element Plus），界面基础设施的核心是全局共享组件与 composable：`BaseDialog.vue` 是统一弹窗基座（Teleport、`v-show`/`v-if` 双层控制、Esc 与遮罩 prop 化、0.3s 入退场动画、自增 z-index 计数器），绝大多数业务弹窗包在它上面而非直接用 `el-dialog`；通知是 `customMessage`（ElMessage 薄包装，offset 54px 避开无边框标题栏）→ `errorHandler` 四级分发（CRITICAL 走常驻 ElNotification）→ 独立 `NotificationCenter` 抽屉（持久化通知中心）三层；主题是 `useTheme` 全局单例（`@vueuse/core` `useDark` + `matchMedia` 跟随系统 + `theme-changed` CustomEvent），持久化在 `settings.json` 而非 localStorage；图片预览用 `viewerjs` 灯箱；侧栏宽度拖拽是自研 `useResizable`（200-600px 硬编码约束）。无障碍处于初步阶段：llm-chat 目录下唯一主动语义化 ARIA 是批量管理表格的 `role="table"`，消息操作栏等大量交互元素只有 `title` 属性。

## 系统边界与总体装配

- **界面栈**：Tauri（Rust 主进程 + WebView）+ Vue 3 + Element Plus；`src/components/common/` 放全局共享组件（`BaseDialog.vue`、`ImageViewer.vue`、`AvatarSelector.vue`、`GuidedFlow/`），`src/composables/` 放全局 composable（`useResizable.ts`、`useFileDrop.ts`、`useTheme.ts`、`useImageViewer.ts`、`useDialogZIndex.ts`）。
- **全局挂载**：`GlobalProviders.vue` 挂载全局图片查看器/弹窗等；`App.vue:81` 挂载 `GuidedFlowHost.vue`（引导流程宿主）；`NotificationCenter.vue` 是全局通知中心（挂在 `GlobalProviders.vue`），不是 llm-chat 专属。
- **状态所有权**：主题等应用设置存 `settings.json`（`src/utils/appSettings.ts`）；通知存 `useNotificationStore`（持久化通知中心）；拖放是全局 composable 被 `MessageInput.vue` 与 `AgentsSidebar.vue` 等复用。

## 1. 界面栈、公共组件与状态所有权

- **弹窗基座**：`BaseDialog.vue`（`E:\works\git\aio-hub\src\components\common\BaseDialog.vue`，全文 1-450 行）是全局共享组件，非 llm-chat 专属；业务弹窗（导出、批量管理、收藏夹管理、聊天设置、正则编辑器）大多包它，而不是直接用 `el-dialog`。
- **z-index 管理**：`useDialogZIndex.ts`（`E:\works\git\aio-hub\src\composables\useDialogZIndex.ts`）维护模块级自增计数器（初始 1800，"避让 Element Plus 默认 1000-2000 范围"），打开 `acquireZIndex()` 递增占用，关闭 `releaseZIndex()` 仅在"释放的正好是当前最大值"时回退——简化实现，多个弹窗乱序关闭时计数器不精确回退（只涨不跌），不影响功能。
- **命令式反馈**：`E:\works\git\aio-hub\src\utils\customMessage.ts` 是对 `ElMessage` 的薄包装，唯一改动是强制加 `offset: 54`（"标题栏 32px + 默认间距 16px + 缓冲 6px"，代码注释原话，`customMessage.ts:23-27`），解决无边框窗口下 Toast 被自绘标题栏遮挡；llm-chat 内所有业务提示一律走 `customMessage.success/error/warning/info`，未见直接调用原生 `ElMessage`。
- **引导流程系统**：`src/components/common/GuidedFlow/`（`GuidedFlowHost.vue` 挂载于 `App.vue:81`，`guidedFlowStore` 承载流程运行时/步骤/跳过/重试）与 `src/flows/upgrade/`（`APP_UPGRADE_FLOW_ID` 注册、版本说明面板、恢复待处理升级）承担首次启动与升级引导；`onboarding`、`首次使用`、`firstLaunch` 等旧关键词无命中，引导功能以 GuidedFlow/flow 命名存在；视觉呈现与各步骤实际引导体验未运行验证。

## 2. 弹窗、浮层与菜单

### 弹窗与对话框

`BaseDialog.vue`（全局共享组件，非 llm-chat 专属）：

- **实现方式**：`Teleport to="body"`（可 `appendToBody` prop 关掉），遮罩层 `base-dialog-backdrop` + 内容容器 `base-dialog-container` 两层结构，`v-show` 控制显隐、`v-if` 控制是否渲染过（`destroyOnClose` 决定关闭后是否销毁 DOM，默认 `true`）。
- **Esc 关闭**：`BaseDialog.vue:276-280` 监听全局 `document.addEventListener("keydown", ...)`，`event.key === "Escape"` 且 `props.showCloseButton` 为真（默认 `true`）时触发 `handleClose()`——Esc 与"关闭按钮"是绑定的复合开关，不是独立 Esc 开关。
- **点击遮罩关闭**：由 `closeOnBackdropClick` prop 控制（默认 `true`），`BaseDialog.vue:29` `@click="props.closeOnBackdropClick && handleClose()"`。部分弹窗显式 `false`（如 `ChatSettingsDialog.vue:24` 聊天设置弹窗），说明对"点遮罩误触关闭"的容忍度按场景区分。
- **焦点管理**：`BaseDialog.vue` 没有 `autofocus`，也没有 `nextTick` 后手动 `.focus()`；弹窗打开后焦点默认停留在触发按钮，不自动进入弹窗。会话重命名弹窗 `RenameDialog.vue` 是例外：用原生 `el-dialog` 并在 `el-input` 上设 `autofocus`（`E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\RenameDialog.vue:70`）。
- **入场/退场动画**：`showContentTransition` 状态配合双重 `requestAnimationFrame`（`BaseDialog.vue:251-256`，绕开 `v-if` 刚插入 DOM 时过渡不生效的问题），CSS 是 `opacity` + `transform: scale(0.95) translateY(-10px)`，时长 `0.3s ease`（`BaseDialog.vue:327`）；关闭时 `handleClose()` 先播 300ms 退场动画再真正 emit `update:modelValue: false`（`enableTransition` 为 `false` 时延迟归零）。
- **消费方**：`ExportBranchDialog.vue`（导出，宽 1000px、高 80vh）、`BatchManagerDialog.vue`（批量管理，带 `role="table"` 和 `aria-label="批量管理会话列表"`）、`FavoriteManagerDialog.vue`（收藏夹）、`ChatSettingsDialog.vue`（聊天设置，`close-on-backdrop-click="false"` + `destroy-on-close="false"`，关闭后保留内部 tab 与滚动状态）、`ChatRegexEditor.vue`（正则编辑器）使用 `BaseDialog`。硬删除消息和清空通知使用 Element Plus 的 `ElMessageBox.confirm`（`MessageMenubar.vue:167-186` 删除确认用"确定删除"/"取消"并通过 `confirmButtonClass: "el-button--danger"` 标记危险操作）；节点图删除用 `el-popconfirm`（`GraphNodeMenubar.vue:386-404`），属于气泡式确认。

### 右键与上下文菜单

- **树图节点右键菜单**（`E:\works\git\aio-hub\src\tools\llm-chat\components\conversation-tree-graph\ContextMenu.vue`）：菜单跟随鼠标坐标定位——`handleNodeContextMenu` 直接把 `event.clientX/clientY`（`useGraphNodeActions.ts:751-753`）作为 `x/y` 传入，组件再用 `getBoundingClientRect()` 校正右侧和底部越界（`ContextMenu.vue:48-66`）。`Teleport to="body"` 挂载，点击外部关闭（`ContextMenu.vue:82-90`）。`MenuItem` 接口只有 `label/icon/disabled/danger/action`，是扁平列表不支持子菜单；无 `@keydown` 或 `tabindex`，缺方向键操作和 Esc 关闭能力。
- **侧栏列表菜单**：Agent 列表用 Element Plus `el-dropdown`，`AgentListItem.vue:182-190` 设置 `trigger="contextmenu"`，通过绝对定位覆盖列表项的空 `div.context-menu-trigger` 作为锚点；会话列表 `SessionItem.vue:145-186` 用 `trigger="click"` 由"更多"图标按钮触发，不支持右键——两侧栏菜单触发方式不一致。`el-dropdown` 键盘可达性由 Element Plus 提供，未独立验证其内部实现。

## 3. 通知、加载态与错误反馈

### 通知与状态反馈

- **业务级即时反馈**：`customMessage`（见系统边界）。llm-chat 内所有业务成功/失败提示（Token 重算、导出成功/失败、翻译等）一律走 `customMessage.success/error/warning/info`。
- **错误提示的分级与去重**：`E:\works\git\aio-hub\src\utils\errorHandler.ts:308-371` 决定"报错要不要弹出来、弹多久"：INFO/WARNING 走 `customMessage`，`duration` 按级别区分（ERROR 5000ms，其余 3000ms，`errorHandler.ts:348`），都设 `grouping: true`（"相同消息合并"，避免同一错误刷屏）；CRITICAL 不走 Toast，改用 `ElNotification.error`，`duration: 0` **不自动关闭**，需手动点掉（`errorHandler.ts:362-368`）——三级反馈体系：INFO/WARNING/ERROR 短暂 Toast，CRITICAL 常驻通知。
- **堆叠行为**：`ElMessage`/`ElNotification` 是 Element Plus 原生行为，多条纵向堆叠自动错位，`customMessage.ts` 只加了 offset——**未在运行时截图验证堆叠像素细节，仅代码层面确认走 Element Plus 默认堆叠机制**。
- **独立的通知中心**：`E:\works\git\aio-hub\src\components\notification\NotificationCenter.vue` 用 `el-drawer`（右侧滑出，`direction="rtl"`，宽 360px）实现，顶部有未读数 `el-badge`、搜索框（标题/内容/来源过滤）、列表区、底部"清空所有消息"（`ElMessageBox.confirm` 二次确认，`NotificationCenter.vue:91-103`）；点击通知项可 `markRead` 并可选跳转 `metadata.path`（`router.push`）。通知详情走**内嵌的 `BaseDialog`**（`NotificationCenter.vue:233-275`，非 drawer），内容用 `RichTextRenderer` 渲染（支持 Markdown）。通知中心是全局的（挂在 `GlobalProviders.vue`），但 llm-chat 内没有直接搜到主动调用 `useNotificationStore` 推送通知的代码（搜索 `useNotificationStore`/`notificationStore` 在 `src/tools/llm-chat` 下无匹配）——"生成完成"这类事件目前没有证据表明会被推进通知中心。通知列表带分页（`PAGE_SIZE = 20`，滚动距底 80px 自动加载更多，搜索/筛选重置页码，首屏内容不足以滚动时自动补页）；通知面板可打开版本说明（`openReleaseNotes`）与恢复待处理的升级引导（`resumePendingUpgrade`，来自 `src/flows/upgrade`）。

### 加载态、骨架屏与空状态

- **首屏骨架屏**：`E:\works\git\aio-hub\src\tools\llm-chat\components\LlmChatSkeleton.vue`（全文 1-533 行）是专门手写的骨架屏组件，逐块模拟真实布局：左侧栏 tab + 12 行文本骨架，中间模拟 `ChatAreaHeader`（头像+名称+模型徽标+搜索/设置按钮占位）和 4 张不同长度消息卡片骨架（`el-skeleton-item` 的 `variant="text"/"rect"/"circle"` 拼出头像、气泡宽度不一的多行文本），底部模拟输入框；右侧模拟搜索栏 + 8 组会话条目骨架。`LlmChat.vue:369-375` 用 `v-if="isLoading"` 整体切换骨架屏与真实内容，宽度参数（侧栏宽度、折叠状态）与真实布局保持同步，避免加载完成后布局跳动。
- **会话列表空状态**：`SessionsSidebar.vue:491-499` 区分两种空态——完全没有会话时"暂无会话 / 点击下方按钮创建新会话"；有会话但筛选/搜索无结果时"未找到匹配的会话 / 尝试其他搜索关键词"（搜索模式下才显示第二行）。
- **附件加载失败态**：`AttachmentCard.vue:826-833` 区分"加载失败"（`loadError`，网络或本地路径读取问题）与"导入失败"（`hasImportError`，两阶段导入第二阶段失败），两种文案不同但共用同一个 `TriangleAlert` 图标占位块；导入中间态用 `Loader2` 旋转图标（`isLoadingUrl` 分支，`AttachmentCard.vue:821-824`），转换阶段文案见 `AttachmentCard.vue:461-476`（"正在转换文档格式.../正在校验文件.../正在生成预览..."按 `phase` 区分）。
- **通知中心空状态**：`NotificationCenter.vue:209-212`，无通知显示 `BellOff` 图标 + "暂无消息通知"，搜索无结果显示"没有匹配的通知"。
- 消息列表本身（`MessageList.vue`）没有"消息加载中"骨架屏——消息随会话详情一次性加载，不存在逐条独立 loading 态；生成中消息使用流式内容占位。

## 4. 主题、视觉 token 与持久化

- **实现机制**：`E:\works\git\aio-hub\src\composables\useTheme.ts` 全局单例（`isDark` 用 `@vueuse/core` 的 `useDark()`），三态枚举 `"auto" | "light" | "dark"`。`auto` 用 `window.matchMedia("(prefers-color-scheme: dark)")` 读取系统当前值并注册 `change` 监听（`useTheme.ts:75-87`）——**确认支持跟随系统**。切换主题后 `window.dispatchEvent(new CustomEvent("theme-changed", ...))`（`useTheme.ts:37-41`），供图标等需要感知主题的组件订阅。
- **存储位置**：主题偏好经 `useAppSettingsStore().update({theme: newTheme})`（`useTheme.ts:57-58`）写入应用级设置文件 `settings.json`（`E:\works\git\aio-hub\src\utils\appSettings.ts:403`），写入前 300ms 防抖（`appSettingsStore.ts:34-37`），不使用 `localStorage`。
- **CSS 切换方式**：`useDark()` 默认通过给根元素加/去 `dark` class（该 hook 标准实现，项目未覆盖默认行为），配合 `E:\works\git\aio-hub\src\styles\variables.css` 的 CSS 变量分深浅两套取值（如 `--el-color-primary` 在 `:root` 和 `:root.dark`——`NotificationCenter.vue:448` 就有 `:root.dark :global(.notification-drawer)` 的暗色专属选择器，印证根节点 `.dark` class 切换机制）。llm-chat 内弹窗、消息卡片等大量用 `var(--card-bg)`/`var(--border-color)`/`var(--text-color)` 语义化变量而非硬编码颜色，理论上无需额外适配即可跟随全局主题切换——**未逐一验证 llm-chat 每个组件在深色模式下的实际视觉效果，只是确认变量机制存在且被使用**。

## 5. 响应式、移动端与窗口适配

- **三栏布局没有响应式断点**：`LlmChat.vue` 的三栏结构没有 `@media` 查询或基于容器宽度的自动折叠。侧栏显示状态由用户手动控制，通过 `isLeftSidebarCollapsed`/`isRightSidebarCollapsed` 持久化；窗口变窄不会自动收起侧栏，三栏一起被压缩。
- **弹窗内部有断点**：`FavoriteManagerDialog.vue:669-674` 在 `max-width: 720px` 时把工具栏/表格/收藏行从多列 grid 改单列（`grid-template-columns: 1fr`）；`ChatSettingsDialog.vue:714-737` 分别在 `max-height: 900px`（缩小弹窗内边距）和 `max-height: 768px`（缩小分区标题字号）两级断点调整间距字号——聊天设置弹窗针对小屏笔记本场景做了适配。
- **侧栏宽度拖拽**（见第 6 节拖放与尺寸调整）：200-600px 手动调整，不属于响应式自适应。

## 6. 图片、附件、拖放与常见内容交互

### 拖放与尺寸调整

- **左右侧栏宽度拖拽**：`LlmChat.vue:88-102` 用通用 composable `useResizable`（`E:\works\git\aio-hub\src\composables\useResizable.ts`，非 llm-chat 专属，纯 `mousedown`/`mousemove`/`mouseup` 手写实现，不依赖第三方拖拽库），左侧栏 `direction: "left"`、右侧栏 `direction: "right"`，共用 `minSize: 200, maxSize: 600`（像素）硬编码约束（`LlmChat.vue:91-92, 99-100`）。拖拽时 `document.body.style.cursor = "col-resize"` 全局改鼠标样式并禁用文本选中（`useResizable.ts:54-55`），松开时还原。
- **分离输入框窗口的宽度拖拽**：`MessageInput.vue:598-611` 在 `props.isDetached` 为真时渲染左右两条拖拽手柄（`resize-handle-left`/`resize-handle-right`，标题"拖拽调整宽度"）；触发函数 `createResizeHandler("East"/"West")`（`MessageInput.vue:439-440`）与高度手柄（"拖拽调整高度（双击重置）"，`MessageInput.vue:513`）是同一套底层实现的不同方向变体，只在窗口分离时出现——专门为悬浮输入框窗口设计的自由调整能力，主窗口内嵌模式不需要。
- **拖放文件的双通道融合机制**：`E:\works\git\aio-hub\src\composables\useFileDrop.ts`（全局 composable，被 `MessageInput.vue` 和 `AgentsSidebar.vue` 等使用）设计上明确考虑 Tauri 环境下拖放的两条路径——H5 原生 `dragenter/dragover/dragleave/drop` 事件（精准但拿不到文件系统绝对路径，只有文件名/大小/MIME）和 Tauri 底层 `webview.onDragDropEvent`（能拿绝对路径但依赖拖拽拦截器配置）。当只有 H5 事件触发且只解析到文件名时，挂起 50ms"延迟融合窗口"（`FUSION_WAIT_MS`，`useFileDrop.ts:176`）等待 Tauri 事件补上绝对路径，超时降级报错"无法获取文件绝对路径，请使用文件选择器添加"（`useFileDrop.ts:572-579`）——为 Tauri 拖放不稳定性做的工程化兜底。
- **节点图内的拖拽**：节点单点/子树拖拽和连线嫁接见 Chat UI 笔记第 11.3 节。

### 图片查看与头像管理

- **图片预览**：`AttachmentCard.vue` 点击图片附件后调用全局单例 `useImageViewer()`（`E:\works\git\aio-hub\src\composables\useImageViewer.ts`）。挂载在 `GlobalProviders.vue:74-81` 的 `ImageViewer.vue` 用 `viewerjs` 实现灯箱，支持缩放、旋转、翻转、全屏、键盘操作（`keyboard: true`）和底部缩略图导航（`navbar: true`）。多图通过 `imageAssets` 和 `currentIndex` 左右切换（`AttachmentCard.vue:529-539`）。pending 附件用 `convertFileSrc` 生成临时 URL，导入完成后改用 `asset://` 协议（`AttachmentCard.vue:548-564`），对应两阶段导入机制。
- **Agent 头像**：全局组件 `AvatarSelector.vue` 支持预设图标、本地文件上传和剪贴板粘贴三种来源。本地文件经 `copy_file_to_app_data` 保存到 AppData，剪贴板读取用 `navigator.clipboard.read()`。当前头像可通过 `useImageViewer` 放大查看，SVG 显示前做主题色适配（`AvatarSelector.vue:433-482`）；历史头像以 `BaseDialog` 网格展示并支持删除（`AvatarSelector.vue:600-650`）。上传文件直接保存为 `avatar-{timestamp}.{ext}`，**没有裁剪、缩放或宽高比调整流程**。

## 7. 扩展调查：无障碍、动画、设置面板、桌面集成

### 无障碍（静态代码结论）

对 `src/tools/llm-chat` 全目录搜索 `aria-label`/`aria-hidden`/`aria-expanded`/`role="`，命中非常有限：

- `BatchManagerDialog.vue:75-110`：批量管理表格用 `role="table"` + `aria-label="批量管理会话列表"`，表头和每行用 `role="row"`——llm-chat 目录下唯一找到的主动语义化 ARIA 标注。
- `ChatTextareaEditor.vue:324`：隐藏影子测量节点上有 `aria-hidden="true"`（纯技术性用途，防止读屏读到不可见辅助元素）。
- 其余组件（消息操作栏 `MessageMenubar.vue`、发送/中止按钮 `MessageInputToolbar.vue`、节点图菜单 `GraphNodeMenubar.vue`、树图节点 `GraphNode.vue`）没有找到 `aria-label`，普遍用"图标按钮 + `title` 属性"或 `el-tooltip`（发送按钮 `title="发送 (Ctrl/Cmd + Enter)"`，`MessageInputToolbar.vue:530`；停止生成按钮 `title="停止生成"`，`:508`）。`title` 对读屏的支持取决于浏览器和辅助技术组合，不能替代明确的可访问名称。
- **纯键盘能否完成核心操作**：
  - **发送消息**：可以。`ChatCodeMirrorEditor.vue`/`ChatTextareaEditor.vue` 支持 `Ctrl/Cmd+Enter` 或 `Enter` 发送（可配置），不依赖鼠标点击。
  - **切换会话**：会话列表是虚拟化可点击列表项（`SessionItem.vue:87`，整个 `div` 绑 `@click`），无 `tabindex`、`role="option"`/`role="listbox"`，也无 `ArrowUp/ArrowDown` 或 `Ctrl+Tab` 会话切换绑定——`div` 默认不可聚焦，列表项不在 Tab 焦点序列，纯键盘用户无法直接切换会话。
  - **查看分支**：部分可行。`MessageMenubar.vue` 上一分支/下一分支按钮是标准 `<button>`（可 Tab 聚焦、Enter/Space 激活），可 Tab 导航后键盘激活；但树图视图（`FlowTreeGraph.vue:22` 容器有 `tabindex="0"`，画布可聚焦）内部节点选择、右键菜单、连线嫁接均是鼠标驱动（拖拽、右键、双击），**没有找到等效键盘操作路径**，画布聚焦后没发现方向键选中/切换节点绑定。
  - 综合结论：发送消息有键盘路径，切换会话和树图操作基本依赖鼠标；线性视图分支切换按钮可 Tab 聚焦。该结论来自静态代码搜索，未经读屏实测，不能作为正式 WCAG 合规结论。

### 动画与过渡

- **消息内容块**：`RichTextRenderer.vue:775-789` 给 `.rich-text-node` 应用 `fade-in-up 0.3s ease-out forwards`（`opacity: 0; transform: translateY(-4px)` → 正常）。动画由 `enableEnterAnimation` prop 控制，`MessageContent.vue` 绑定到 `settings.uiPreferences.enableEnterAnimation`。代码块、Mermaid 图、思考节点、VCP 工具节点、HTML 块和图片等 9 类节点在 `AstNodeRenderer.tsx:99-109` 的 `NO_ANIMATION_NODE_TYPES` 集合中，不应用该动画——避免流式内容已更新而外层仍处于透明过渡。
- **弹窗**：`BaseDialog` 的 0.3 秒缩放 + 纵向位移动画（第 2 节）。
- **图片查看器**：`ImageViewer.vue` 封装 `viewerjs`，`transition: true`（`ImageViewer.vue:86`）启用库自带缩放、切换、旋转、翻转和全屏过渡。
- **侧栏折叠**：`LlmChat.vue` 通过 `v-if` 直接增删侧栏 DOM，没有宽度 transition——折叠/展开是瞬时切换。

### 设置面板与首次启动引导

- `ChatSettingsDialog.vue` 是基于 `BaseDialog` 的全局聊天设置弹窗，`close-on-backdrop-click="false"` 防误触关闭。顶部 `el-autocomplete` 模糊搜索设置项，`querySearch`/`handleSearchSelect`/`highlightedItemId` 定位并高亮；下方卡片式 `el-tabs` 是滚动锚点，所有分区实际位于同一个可滚动容器；主体由 `el-form` + `SettingListRenderer` 渐进渲染，`activeGroupCollapses` 记录设置组展开状态，底部提供"恢复默认"。
- 首次启动与升级引导由 `GuidedFlow/` 通用引导流程系统 + `src/flows/upgrade/` 升级引导承担（见系统边界），配套"首次启动基线门禁 + 生命周期迁移 + E2E 覆盖"（提交 `eed23cd8e`/`a9f02cd4f`/`9434d4473`/`74675f45f` 等）。

### 桌面集成

- **系统托盘**：`E:\works\git\aio-hub\src-tauri\src\tray.rs` 定义应用级托盘，菜单包含"显示主窗口、隐藏主窗口、重启前端、清除窗口配置、退出"（`tray.rs:39-59`）；"显示主窗口"同时调用 `window.show()` 和 `window.set_focus()`。托盘不属于 llm-chat，也没有聊天生成状态相关的动态菜单项。
- **系统级通知**：项目中没有找到 `tauri-plugin-notification`、`sendNotification`、`notification::Notification`、`request_user_attention` 或 `UserAttentionType`——没有 Windows Toast、标题栏闪烁或任务栏提醒的实现证据。
- **生成完成提示**：生成完成只驱动 `generatingNodes`、消息卡片状态和 `useWindowSyncBus` 的跨窗口同步，没有触发系统通知、托盘图标变化或标题栏提醒。应用在后台时不会主动提示某个会话已生成完成。

## 8. 设计取舍与已确认边界

- **Esc 与关闭按钮绑定**：`showCloseButton=false` 会连 Esc 一并禁用，不是独立 Esc 开关。
- **z-index 计数器只涨不跌**：乱序关闭不精确回退，简化实现。
- **主题持久化在 settings.json 而非 localStorage**：与"通常在浏览器层存"的预期相反，因为 Tauri 原生应用（300ms 防抖写入）。
- **拖放双通道融合**：为 Tauri 拖放不稳定性做的 50ms 延迟融合窗口 + 降级报错。
- **通知中心存在但 llm-chat 未接入**："生成完成"等事件没有证据表明会被推进持久化通知中心。
- **无系统级桌面通知与生成完成联动**：后台不主动提示（已核实，非未找到）。
- **头像上传无裁剪流程**：直接保存原图。
- **`viewerjs` 灯箱**：第三方库承载全部缩放/旋转/导航能力，项目只是薄封装。
- **无障碍初步阶段**：llm-chat 仅批量管理表格有主动 ARIA；会话切换与树图操作无键盘路径（静态结论）。

## 9. 未验证事项

- ElMessage/ElNotification 堆叠像素细节未运行截图验证（仅确认走 Element Plus 默认堆叠）。
- llm-chat 每个组件深色模式下的实际视觉效果未逐一验证（只确认变量机制存在且被使用）。
- 无障碍结论基于静态代码搜索，未经屏幕阅读器实测，不能作为 WCAG 合规结论；`el-dropdown` 键盘可达性由 Element Plus 提供，未独立验证。
- 引导流程各步骤的实际引导体验未运行验证。
- 界面层未找到以下能力（相关关键词全项目静态搜索，未经运行时可用性测试）：系统级桌面通知及生成完成联动；树图右键菜单的方向键操作和 Esc 关闭；会话列表键盘切换；头像裁剪；消息列表逐条 loading 骨架屏；侧栏折叠/展开过渡动画。首次启动引导由 GuidedFlow 引导流程系统与升级/迁移引导承担，不属于缺失清单。

## 10. 关键源码索引

`E:\works\git\aio-hub\src\components\common\BaseDialog.vue`、`src\composables\useDialogZIndex.ts`、`src\utils\customMessage.ts`、`src\utils\errorHandler.ts`（290-390 行三级反馈）、`src\components\notification\NotificationCenter.vue`、`src\components\GlobalProviders.vue`、`src\composables\useResizable.ts`、`src\composables\useFileDrop.ts`、`src\composables\useTheme.ts`、`src\stores\appSettingsStore.ts`、`src\utils\appSettings.ts`、`src\composables\useImageViewer.ts`、`src\components\common\ImageViewer.vue`、`src\components\common\AvatarSelector.vue`、`src\components\common\GuidedFlow\`、`src\flows\upgrade\`、`src-tauri\src\tray.rs`、`src\tools\llm-chat\components\LlmChatSkeleton.vue`、`src\tools\llm-chat\components\sidebar\SessionsSidebar.vue`（491-499）、`src\tools\llm-chat\components\AttachmentCard.vue`、`src\tools\llm-chat\components\conversation-tree-graph\ContextMenu.vue`、`src\tools\llm-chat\components\conversation-tree-graph\flow\composables\useGraphNodeActions.ts`、`src\tools\llm-chat\components\sidebar\AgentListItem.vue`（182-190）、`src\tools\llm-chat\components\sidebar\SessionItem.vue`、`src\tools\rich-text-renderer\RichTextRenderer.vue`（775-789）、`src\tools\rich-text-renderer\components\AstNodeRenderer.tsx`（96-109）。
