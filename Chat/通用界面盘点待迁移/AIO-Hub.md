# AIO-Hub 通用界面盘点（待迁移）

> 来源文件：`../Chat/AIO-Hub-Chat调查笔记.md` 第 12 节及第 13.2 节、13.3 节界面层部分（2026-08-11 源文件已压缩为概览，本节已完整摘出）
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 摘出日期：2026-08-11
>
> 说明：原文完整搬运，保留段落、证据（文件+行号）与验证边界表述，编号沿用原文；附第 13.2 节界面层依据与 13.3 节界面层未找到能力清单。

## 12. 界面基础设施与可用性

本节说明弹窗、通知、加载态、主题、响应式、动画、桌面集成和无障碍实现；没有代码证据的能力明确标为"未找到"。

### 12.1 弹窗与对话框

`llm-chat` 模块里绝大多数业务弹窗（导出、批量管理、收藏夹管理、聊天设置、正则编辑器等）并不是直接用 `el-dialog`，而是包了一层自研组件 `BaseDialog.vue`（`E:\works\git\aio-hub\src\components\common\BaseDialog.vue`，全局共享组件，非 llm-chat 专属）：

- **实现方式**：`Teleport to="body"`（可通过 `appendToBody` prop 关掉），遮罩层 `base-dialog-backdrop` + 内容容器 `base-dialog-container` 两层结构，`v-show` 控制显隐、`v-if` 控制是否已渲染过（`destroyOnClose` 决定关闭后是否销毁 DOM，默认 `true`）。
- **Esc 关闭**：`BaseDialog.vue:276-280` 监听全局 `document.addEventListener("keydown", ...)`，`event.key === "Escape"` 且 `props.showCloseButton` 为真（默认 `true`）时触发 `handleClose()`。也就是说如果某个弹窗把 `showCloseButton` 设为 `false`，Esc 也会被一并禁用——这是与"关闭按钮"绑定的复合开关，不是独立的 Esc 开关。
- **点击遮罩关闭**：由 `closeOnBackdropClick` prop 控制（默认 `true`），`BaseDialog.vue:29` `@click="props.closeOnBackdropClick && handleClose()"`。部分弹窗显式设为 `false`（如 `ChatSettingsDialog.vue:24` 的聊天设置弹窗、以及导出分支弹窗默认走 `true`），说明团队对"点遮罩误触关闭"的容忍度是按场景区分的。
- **焦点管理**：`BaseDialog.vue` 没有 `autofocus`，也没有在 `nextTick` 后手动调用 `.focus()`；弹窗打开后焦点默认停留在触发按钮上，不会自动进入弹窗。会话重命名弹窗 `RenameDialog.vue` 是例外：它使用原生 `el-dialog`，并在 `el-input` 上设置了 `autofocus`（`E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\RenameDialog.vue:70`）。
- **入场/退场动画**：`showContentTransition` 状态配合双重 `requestAnimationFrame`（`BaseDialog.vue:251-256`，用于绕开 `v-if` 刚插入 DOM 时过渡不生效的问题），CSS 是 `opacity` + `transform: scale(0.95) translateY(-10px)` 的组合，过渡时长 `0.3s ease`（`BaseDialog.vue:327`）；关闭时 `handleClose()` 会先播 300ms 退场动画再真正 emit `update:modelValue: false`（`enableTransition` 为 `false` 时这个延迟归零）。
- **z-index 管理**：`useDialogZIndex.ts`（`E:\works\git\aio-hub\src\composables\useDialogZIndex.ts`）维护一个模块级自增计数器（初始 1800，"避让 Element Plus 默认 1000-2000 范围"），每次弹窗打开调 `acquireZIndex()` 递增并占用，关闭时 `releaseZIndex()` 仅在"释放的正好是当前最大值"时才回退计数器——这是一个简化实现，多个弹窗乱序关闭时计数器不会精确回退，但不影响功能只是可能让计数器只涨不跌。

业务弹窗中，`ExportBranchDialog.vue`（导出，宽 1000px、高 80vh）、`BatchManagerDialog.vue`（批量管理，带 `role="table"` 和 `aria-label="批量管理会话列表"`）、`FavoriteManagerDialog.vue`（收藏夹管理）、`ChatSettingsDialog.vue`（聊天设置）和 `ChatRegexEditor.vue`（正则编辑器）使用 `BaseDialog`。`ChatSettingsDialog.vue` 设置 `close-on-backdrop-click="false"` 和 `destroy-on-close="false"`，关闭后保留内部 tab 与滚动状态。硬删除消息和清空通知使用 Element Plus 的 `ElMessageBox.confirm`；例如 `MessageMenubar.vue:167-186` 的删除确认使用"确定删除"/"取消"，并通过 `confirmButtonClass: "el-button--danger"` 标记危险操作。节点图删除则使用 `el-popconfirm`（`GraphNodeMenubar.vue:386-404`），属于气泡式确认。

### 12.2 通知与状态反馈

- **业务级即时反馈**：`E:\works\git\aio-hub\src\utils\customMessage.ts` 是对 `ElMessage` 的薄包装，唯一的改动是强制加 `offset: 54`（"标题栏 32px + 默认间距 16px + 缓冲 6px"，代码注释原话，`customMessage.ts:23-27`），用于解决无边框窗口下 Toast 被自绘标题栏遮挡的问题。`llm-chat` 内所有业务成功/失败提示（Token 重算、导出成功/失败、翻译等）一律走 `customMessage.success/error/warning/info`，未见直接调用原生 `ElMessage`。
- **错误提示的分级与去重**：`E:\works\git\aio-hub\src\utils\errorHandler.ts:308-371` 是真正决定"报错要不要弹出来、弹多久"的地方：INFO/WARNING 走 `customMessage`，`duration` 按级别区分（ERROR 5000ms，其余 3000ms，`errorHandler.ts:348`），且都设置了 `grouping: true`（"相同消息合并"，避免同一个错误短时间内刷屏）；CRITICAL 级别不走 Toast，改用 `ElNotification.error`，`duration: 0` 即**不自动关闭**，需要用户手动点掉（`errorHandler.ts:362-368`）。这是一个三级反馈体系：INFO/WARNING/ERROR 走短暂 Toast，CRITICAL 走常驻通知。
- **堆叠行为**：`ElMessage`/`ElNotification` 本身是 Element Plus 原生行为，多条消息会纵向堆叠、自动错位，`customMessage.ts` 未覆盖这部分逻辑（只加了 offset），可以认为堆叠方式与 Element Plus 默认一致——**此处未在运行时截图验证堆叠像素细节，仅是代码层面确认走的是 Element Plus 默认堆叠机制**。
- **独立的通知中心**：与即时 Toast 平行存在一套持久化通知系统——`E:\works\git\aio-hub\src\components\notification\NotificationCenter.vue`，用 `el-drawer`（右侧滑出，`direction="rtl"`，宽 360px）实现，顶部有未读数 `el-badge`、搜索框（标题/内容/来源过滤）、列表区、底部"清空所有消息"按钮（`ElMessageBox.confirm` 二次确认，`NotificationCenter.vue:91-103`）；点击通知项可 `markRead` 并可选跳转到 `metadata.path`（`router.push`）。通知详情走**内嵌的 `BaseDialog`**（`NotificationCenter.vue:233-275`，非 drawer），内容用 `RichTextRenderer` 渲染（支持 Markdown）。**这套通知中心是全局的（挂在 `GlobalProviders.vue`），不是 llm-chat 专属**，但 llm-chat 内没有直接搜到主动调用 `useNotificationStore` 推送通知的代码（搜索 `useNotificationStore`/`notificationStore` 在 `src/tools/llm-chat` 下无匹配）——即"生成完成"这类事件目前没有证据表明会被推送进通知中心，只是走 Toast 或前端状态更新。

### 12.3 加载态、骨架屏与空状态

- **首屏骨架屏**：`E:\works\git\aio-hub\src\tools\llm-chat\components\LlmChatSkeleton.vue`（全文 1-533 行）是一个专门手写的骨架屏组件，不是通用占位符，而是逐块模拟真实布局：左侧栏 tab + 12 行文本骨架，中间区域模拟 `ChatAreaHeader`（头像+名称+模型徽标+搜索/设置按钮占位）和 4 张不同长度的消息卡片骨架（用 `el-skeleton-item` 的 `variant="text"/"rect"/"circle"` 拼出头像、气泡宽度不一的多行文本），底部模拟输入框；右侧栏模拟搜索栏 + 8 组会话条目骨架。`LlmChat.vue:369-375` 用 `v-if="isLoading"` 整体切换骨架屏和真实内容，宽度参数（侧栏宽度、折叠状态）与真实布局保持同步传入，避免加载完成后出现布局跳动。
- **会话列表空状态**：`SessionsSidebar.vue:491-499` 区分两种空态——完全没有会话时显示"暂无会话 / 点击下方按钮创建新会话"；有会话但筛选/搜索无结果时显示"未找到匹配的会话 / 尝试其他搜索关键词"（搜索模式下才显示第二行提示）。
- **附件加载失败态**：`AttachmentCard.vue:826-833` 区分"加载失败"（`loadError`，网络或本地路径读取问题）与"导入失败"（`hasImportError`，`useAttachmentManager` 两阶段导入的第二阶段失败），两种文案不同但共用同一个 `TriangleAlert` 图标占位块，替代原本应显示的缩略图；导入过程中间态用 `Loader2` 旋转图标（`isLoadingUrl` 分支，`AttachmentCard.vue:821-824`），具体转换阶段文案见 `AttachmentCard.vue:461-476`（"正在转换文档格式.../正在校验文件.../正在生成预览..."等，按 `phase` 区分）。
- **通知中心空状态**：`NotificationCenter.vue:209-212`，无通知显示 `BellOff` 图标 + "暂无消息通知"，搜索无结果显示"没有匹配的通知"。
- 消息列表本身（`MessageList.vue`）没有"消息加载中"骨架屏。消息随会话详情一次性加载，不存在逐条消息的独立 loading 态；生成中消息使用第 4 节所述的流式内容占位。

### 12.4 拖放与尺寸调整

尺寸调整与拖放由以下机制实现：

- **左右侧栏宽度拖拽**：`LlmChat.vue:88-102` 用通用 composable `useResizable`（`E:\works\git\aio-hub\src\composables\useResizable.ts`，非 llm-chat 专属，纯 `mousedown`/`mousemove`/`mouseup` 手写实现，不依赖第三方拖拽库），左侧栏 `direction: "left"`、右侧栏 `direction: "right"`，两者共用同一套 `minSize: 200, maxSize: 600`（像素）硬编码约束（`LlmChat.vue:91-92, 99-100`）。拖拽时 `document.body.style.cursor = "col-resize"` 全局改鼠标样式并禁用文本选中（`useResizable.ts:54-55`），松开鼠标时还原。
- **分离输入框窗口的宽度拖拽**：`MessageInput.vue:598-611` 在 `props.isDetached` 为真时才渲染左右两条拖拽手柄（`resize-handle-left`/`resize-handle-right`），标题都是"拖拽调整宽度"；触发函数 `createResizeHandler("East"/"West")`（`MessageInput.vue:439-440`）与高度拖拽手柄（"拖拽调整高度（双击重置）"，`MessageInput.vue:513`）是同一套底层实现的不同方向变体，只在窗口已分离时才出现，说明这是专门为悬浮输入框窗口设计的自由调整能力，主窗口内嵌模式下不需要。
- **拖放文件的双通道融合机制**：`E:\works\git\aio-hub\src\composables\useFileDrop.ts`（全局 composable，被 `MessageInput.vue` 和 `AgentsSidebar.vue` 等使用）设计上明确考虑了 Tauri 环境下拖放事件的两条路径——H5 原生 `dragenter/dragover/dragleave/drop` 事件（精准但拿不到文件系统绝对路径，只能拿文件名/大小/MIME）和 Tauri 底层 `webview.onDragDropEvent`（能拿绝对路径但依赖拖拽拦截器配置）。当只有 H5 事件触发且只解析到文件名时，会挂起一个 50ms 的"延迟融合窗口"（`FUSION_WAIT_MS`，`useFileDrop.ts:176`）等待 Tauri 事件补上绝对路径，超时后降级报错"无法获取文件绝对路径，请使用文件选择器添加"（`useFileDrop.ts:572-579`）。这是一个为 Tauri 拖放不稳定性做的工程化兜底，比单纯监听一种事件复杂得多。
- **节点图内的拖拽**：节点单点/子树拖拽和连线嫁接见第 11.3 节。

### 12.5 右键与上下文菜单

- **树图节点右键菜单**（`E:\works\git\aio-hub\src\tools\llm-chat\components\conversation-tree-graph\ContextMenu.vue`）：菜单跟随鼠标坐标定位。`handleNodeContextMenu` 直接把 `event.clientX/clientY`（`useGraphNodeActions.ts:751-753`）作为 `x/y` 传入，组件再用 `getBoundingClientRect()` 校正右侧和底部的越界位置（`ContextMenu.vue:48-66`）。菜单通过 `Teleport to="body"` 挂载，点击外部区域关闭（`ContextMenu.vue:82-90`）。`MenuItem` 接口只有 `label/icon/disabled/danger/action`，因此菜单是扁平列表，不支持子菜单；组件也没有 `@keydown` 或 `tabindex`，缺少方向键操作和 Esc 关闭能力。
- **侧栏列表菜单**：Agent 列表使用 Element Plus 的 `el-dropdown`，`AgentListItem.vue:182-190` 设置 `trigger="contextmenu"`，通过绝对定位覆盖列表项的空 `div.context-menu-trigger` 作为锚点。会话列表的 `SessionItem.vue:145-186` 则使用 `trigger="click"`，由"更多"图标按钮触发，不支持右键。两侧栏的菜单触发方式不一致。`el-dropdown` 的键盘可达性由 Element Plus 提供，本文未独立验证其内部实现。

### 12.6 主题与深色模式

- **实现机制**：`E:\works\git\aio-hub\src\composables\useTheme.ts` 全局单例（`isDark` 用 `@vueuse/core` 的 `useDark()`），三态枚举 `"auto" | "light" | "dark"`。`auto` 模式下用 `window.matchMedia("(prefers-color-scheme: dark)")` 读取系统当前值，并注册 `change` 事件监听（`useTheme.ts:75-87`）在系统主题变化时实时联动更新——**确认支持跟随系统**。切换主题后会 `window.dispatchEvent(new CustomEvent("theme-changed", ...))`（`useTheme.ts:37-41`），供图标等需要感知主题的组件订阅。
- **存储位置**：主题偏好通过 `useAppSettingsStore().update({theme: newTheme})`（`useTheme.ts:57-58`）写入应用级设置文件 `settings.json`（`E:\works\git\aio-hub\src\utils\appSettings.ts:403`），写入前有 300ms 防抖（`appSettingsStore.ts:34-37`），不使用 `localStorage`。
- **CSS 切换方式**：`useDark()`（`@vueuse/core`）默认通过给根元素加/去 `dark` class 来切换（这是该 hook 的标准实现方式，项目未覆盖其默认行为），配合 `E:\works\git\aio-hub\src\styles\variables.css` 里的 CSS 变量分深浅两套取值（如 `--el-color-primary` 等变量在 `:root` 和 `:root.dark`——`NotificationCenter.vue:448` 就有 `:root.dark :global(.notification-drawer)` 的暗色专属选择器，印证了根节点 `.dark` class 切换机制）。llm-chat 内的弹窗、消息卡片等大量使用 `var(--card-bg)`/`var(--border-color)`/`var(--text-color)` 等语义化变量而非硬编码颜色，因此理论上无需额外适配即可跟随全局主题切换——**此处未逐一验证 llm-chat 每个组件在深色模式下的实际视觉效果，只是确认了变量机制本身存在且被使用**。

### 12.7 无障碍

对 `src/tools/llm-chat` 全目录搜索 `aria-label`/`aria-hidden`/`aria-expanded`/`role="`，命中结果非常有限，具体如下：

- `BatchManagerDialog.vue:75-110`：批量管理表格使用 `role="table"` + `aria-label="批量管理会话列表"`，表头和每行使用 `role="row"`。这是 `llm-chat` 目录下唯一找到的主动语义化 ARIA 标注。
- `ChatTextareaEditor.vue:324`：一个用于测量文本高度的隐藏影子节点上有 `aria-hidden="true"`（纯技术性用途，防止屏幕阅读器读到这个不可见的辅助元素，不是面向可用性设计的）。
- 其余组件（消息操作栏 `MessageMenubar.vue`、发送/中止按钮 `MessageInputToolbar.vue`、节点图菜单 `GraphNodeMenubar.vue`、树图节点 `GraphNode.vue`）没有找到 `aria-label`。这些交互元素普遍使用"图标按钮 + `title` 属性"或 `el-tooltip`，例如发送按钮只有 `title="发送 (Ctrl/Cmd + Enter)"`（`MessageInputToolbar.vue:530`），停止生成按钮只有 `title="停止生成"`（`MessageInputToolbar.vue:508`）。`title` 对屏幕阅读器的支持取决于浏览器和辅助技术组合，不能替代明确的可访问名称。
- **纯键盘能否完成核心操作**：
  - **发送消息**：可以。`ChatCodeMirrorEditor.vue`/`ChatTextareaEditor.vue` 都支持 `Ctrl/Cmd+Enter` 或 `Enter` 发送（可配置），不依赖鼠标点击发送按钮。
  - **切换会话**：会话列表是虚拟化的可点击列表项（`SessionItem.vue:87`，整个 `div` 绑定 `@click`），没有 `tabindex`、`role="option"` 或 `role="listbox"`，也没有 `ArrowUp/ArrowDown` 或 `Ctrl+Tab` 的会话切换绑定。由于 `div` 默认不可聚焦，列表项不在 Tab 焦点序列里，纯键盘用户无法直接切换会话。
  - **查看分支**：部分可行。`MessageMenubar.vue` 的上一分支/下一分支按钮是标准 `<button>` 元素（可被 Tab 聚焦、可用 Enter/Space 激活），所以理论上可以通过 Tab 导航到这些按钮再用键盘激活；但树图视图（`FlowTreeGraph.vue:22` 容器有 `tabindex="0"`，说明整个画布本身可以被聚焦）内部的节点选择、右键菜单操作、连线嫁接等均是鼠标驱动的交互（拖拽、右键、双击），**没有找到等效的键盘操作路径**，画布本身可聚焦但聚焦后没有发现方向键选中/切换节点的绑定。
  - 综合结论：发送消息具备键盘路径，切换会话和树图操作基本依赖鼠标；线性视图下的分支切换按钮可通过 Tab 聚焦。该结论来自静态代码搜索，未经屏幕阅读器实测，不能作为正式的 WCAG 合规结论；仍需使用 NVDA/JAWS 和键盘测试逐项验证。

### 12.8 响应式与窗口尺寸适配

- **三栏布局没有响应式断点**：`LlmChat.vue` 的三栏结构没有 `@media` 查询或基于容器宽度的自动折叠逻辑。侧栏显示状态由用户手动控制，并通过 `isLeftSidebarCollapsed`/`isRightSidebarCollapsed` 持久化；窗口变窄时不会自动收起侧栏，三栏会一起被压缩。
- **弹窗内部有断点**：与整体三栏布局不同,弹窗组件内部确实做了响应式处理——`FavoriteManagerDialog.vue:669-674` 在 `max-width: 720px` 时把工具栏/表格/收藏行从多列 grid 改为单列（`grid-template-columns: 1fr`）；`ChatSettingsDialog.vue:714-737` 分别在 `max-height: 900px`（缩小弹窗内边距）和 `max-height: 768px`（缩小分区标题字号）两级断点下调整间距和字号，说明聊天设置弹窗针对小屏笔记本一类的场景做了适配。
- 侧栏宽度可通过第 12.4 节的拖拽机制在 200-600px 范围内调整，但这是手动操作，不属于响应式自适应。

### 12.9 动画与过渡效果

- **消息内容块**：`RichTextRenderer.vue:775-789` 给 `.rich-text-node` 应用 `fade-in-up 0.3s ease-out forwards`，从 `opacity: 0; transform: translateY(-4px)` 过渡到正常状态。动画由 `enableEnterAnimation` prop 控制，`MessageContent.vue` 将其绑定到 `settings.uiPreferences.enableEnterAnimation`。代码块、Mermaid 图、思考节点、VCP 工具节点、HTML 块和图片等 9 类节点位于 `AstNodeRenderer.tsx:99-109` 的 `NO_ANIMATION_NODE_TYPES` 集合中，不应用该动画，以免流式内容已经更新而外层仍处于透明过渡。
- **弹窗**：`BaseDialog` 使用第 12.1 节所述的 0.3 秒缩放和纵向位移动画。
- **图片查看器**：`ImageViewer.vue` 封装 `viewerjs`，通过 `transition: true`（`ImageViewer.vue:86`）启用库自带的缩放、切换、旋转、翻转和全屏过渡。
- **侧栏折叠**：`LlmChat.vue` 通过 `v-if` 直接增删侧栏 DOM，没有宽度 transition；折叠和展开是瞬时切换。

### 12.10 图片查看与头像管理

- **图片预览**：`AttachmentCard.vue` 点击图片附件后调用全局单例 `useImageViewer()`（`E:\works\git\aio-hub\src\composables\useImageViewer.ts`）。挂载在 `GlobalProviders.vue:74-81` 的 `ImageViewer.vue` 使用 `viewerjs` 实现灯箱，支持缩放、旋转、翻转、全屏、键盘操作（`keyboard: true`）和底部缩略图导航（`navbar: true`）。多图通过 `imageAssets` 和 `currentIndex` 左右切换（`AttachmentCard.vue:529-539`）。pending 附件使用 `convertFileSrc` 生成临时 URL，导入完成后改用 `asset://` 协议（`AttachmentCard.vue:548-564`），对应第 7.1 节的两阶段导入机制。
- **Agent 头像**：全局组件 `AvatarSelector.vue` 支持预设图标、本地文件上传和剪贴板粘贴三种来源。本地文件通过 `copy_file_to_app_data` 保存到 AppData，剪贴板读取使用 `navigator.clipboard.read()`。当前头像可通过 `useImageViewer` 放大查看，SVG 在显示前做主题色适配（`AvatarSelector.vue:433-482`）；历史头像以 `BaseDialog` 网格展示并支持删除（`AvatarSelector.vue:600-650`）。上传文件直接保存为 `avatar-{timestamp}.{ext}`，没有裁剪、缩放或宽高比调整流程。

### 12.11 设置面板

`ChatSettingsDialog.vue` 是基于 `BaseDialog` 的全局聊天设置弹窗，设置 `close-on-backdrop-click="false"` 以防误触关闭。顶部 `el-autocomplete` 支持模糊搜索设置项，并通过 `querySearch`、`handleSearchSelect` 和 `highlightedItemId` 定位及高亮；下方卡片式 `el-tabs` 是滚动锚点，所有分区实际位于同一个可滚动容器；主体由 `el-form` 和 `SettingListRenderer` 渐进渲染，`activeGroupCollapses` 记录设置组的展开状态，底部提供"恢复默认"。项目中没有独立的首次启动 onboarding 流程：`onboarding`、`首次使用`、`firstLaunch`、`first-run`、`新手引导`、`guide-tour` 和 `driver.js` 均无匹配。

### 12.12 桌面集成

- **系统托盘**：`E:\works\git\aio-hub\src-tauri\src\tray.rs` 定义应用级托盘，菜单包含"显示主窗口、隐藏主窗口、重启前端、清除窗口配置、退出"（`tray.rs:39-59`）；"显示主窗口"同时调用 `window.show()` 和 `window.set_focus()`。托盘不属于 `llm-chat`，也没有聊天生成状态相关的动态菜单项。
- **系统级通知**：项目中没有找到 `tauri-plugin-notification`、`sendNotification`、`notification::Notification`、`request_user_attention` 或 `UserAttentionType`，因此没有 Windows Toast、标题栏闪烁或任务栏提醒的实现证据。
- **生成完成提示**：生成完成只驱动 `generatingNodes`、消息卡片状态和 `useWindowSyncBus` 的跨窗口同步，没有触发系统通知、托盘图标变化或标题栏提醒。应用处于后台时，不会主动提示某个会话已生成完成。

## 附：界面层依据（原文第 13.2 节）

- `E:\works\git\aio-hub\src\components\common\BaseDialog.vue`（通用弹窗基座，1-450 行）
- `E:\works\git\aio-hub\src\composables\useDialogZIndex.ts`
- `E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\RenameDialog.vue`
- `E:\works\git\aio-hub\src\tools\llm-chat\components\export\ExportBranchDialog.vue`
- `E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\BatchManagerDialog.vue`（75-110 行，ARIA 标注）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\settings\ChatSettingsDialog.vue`
- `E:\works\git\aio-hub\src\tools\llm-chat\components\message\MessageMenubar.vue`（167-186 行删除确认）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\conversation-tree-graph\flow\components\GraphNodeMenubar.vue`（386-404 行 el-popconfirm）
- `E:\works\git\aio-hub\src\utils\customMessage.ts`
- `E:\works\git\aio-hub\src\utils\errorHandler.ts`（290-390 行，三级反馈体系）
- `E:\works\git\aio-hub\src\components\notification\NotificationCenter.vue`
- `E:\works\git\aio-hub\src\components\GlobalProviders.vue`（全局查看器/弹窗挂载点）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\LlmChatSkeleton.vue`（全文骨架屏）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\SessionsSidebar.vue`（491-499 行空状态）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\AttachmentCard.vue`（附件加载/导入失败态、图片预览）
- `E:\works\git\aio-hub\src\composables\useResizable.ts`（侧栏宽度拖拽通用实现）
- `E:\works\git\aio-hub\src\composables\useFileDrop.ts`（拖放双通道融合机制）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\conversation-tree-graph\ContextMenu.vue`（跟随鼠标坐标定位）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\conversation-tree-graph\flow\composables\useGraphNodeActions.ts`
- `E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\AgentListItem.vue`（182-190 行右键菜单锚定元素定位）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\SessionItem.vue`（无右键菜单）
- `E:\works\git\aio-hub\src\composables\useTheme.ts`（主题三态、跟随系统、CustomEvent 通知）
- `E:\works\git\aio-hub\src\stores\appSettingsStore.ts` / `E:\works\git\aio-hub\src\utils\appSettings.ts`（主题持久化到 settings.json）
- `E:\works\git\aio-hub\src\tools\rich-text-renderer\RichTextRenderer.vue`（775-789 行 fade-in-up 动画）
- `E:\works\git\aio-hub\src\tools\rich-text-renderer\components\AstNodeRenderer.tsx`（96-109 行动画排除名单）
- `E:\works\git\aio-hub\src\components\common\ImageViewer.vue`（viewerjs 封装）
- `E:\works\git\aio-hub\src\composables\useImageViewer.ts`（全局图片查看器状态）
- `E:\works\git\aio-hub\src\components\common\AvatarSelector.vue`（头像上传/粘贴/历史，无裁剪）
- `E:\works\git\aio-hub\src-tauri\src\tray.rs`（系统托盘）
- `E:\works\git\aio-hub\src\tools\llm-chat\components\sidebar\FavoriteManagerDialog.vue`（669-674 行响应式断点）

## 附：界面层未找到能力（原文 13.3 节末段）

界面层未找到以下能力：首次启动 onboarding；系统级桌面通知及生成完成联动；树图右键菜单的方向键操作和 Esc 关闭；会话列表键盘切换；头像裁剪；消息列表逐条 loading 骨架屏；侧栏折叠/展开过渡动画。以上结论来自相关关键词的全项目静态搜索，未经运行时可用性测试。
