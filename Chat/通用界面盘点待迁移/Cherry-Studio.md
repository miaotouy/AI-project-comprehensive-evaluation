# Cherry Studio 通用界面盘点

> 来源：`Chat/Cherry-Studio-Chat调查笔记.md` 第 13 节「UI 交互再深挖：弹窗、状态反馈与无障碍」，原文完整搬运
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 摘出日期：2026-08-11
>
> 更新日期：2026-08-12
>
> 用途：通用界面基础设施盘点（弹窗库、Toast、主题、动画、灯箱、右键双模式等），按类目边界不属于 Chat UI 主文（Chat UI 只记录与聊天主链的交点）；本目录是可选界面专题建立前的临时承接位置，专题建立后整体迁入。

## 13. UI 交互再深挖：弹窗、状态反馈与无障碍

本节聚焦此前完全没提到的细节层：弹窗/Toast 的具体组件栈、加载态与空状态的视觉呈现、右键菜单双模式、主题切换的完整链路、无障碍的实证（含明确缺失）、窗口尺寸适配、动画方案、图片灯箱与代码块交互、以及桌面端通知/托盘与聊天状态的联动。逐条给出文件路径 + 行号依据。

### 13.1 弹窗/对话框：不是 antd，是自建 Radix 封装 + 两套调用入口

Cherry Studio 早已从 antd Modal 迁移出来，`package.json` 里已经**没有 `antd` 依赖**（`grep '"antd"' package.json` 无匹配）。对话框基础组件是内部 `@cherrystudio/ui` 包基于 `@radix-ui/react-dialog` 封装的 `Dialog`/`DialogContent`（`packages/ui/src/components/primitives/dialog.tsx:10-149`）：
- **Esc/遮罩关闭**：`DialogOverlay` 点击默认触发 Radix 的 `Dialog.Close`（`dialog.tsx:101-108`），可用 `closeOnOverlayClick={false}` 关掉；Esc 键关闭是 Radix `Dialog.Root` 的默认行为，代码里没有覆盖 `onEscapeKeyDown`，即所有 Dialog 默认支持 Esc 关闭。业务层的确认弹窗（`ConfirmPopupItem.tsx:121-124`）额外用 `onInteractOutside` 手动挡掉遮罩点击（当 `maskClosable === false` 时 `event.preventDefault()`），是在 Radix 基础上叠加的业务开关。
- **焦点管理**：`DialogContent` 默认交给 Radix 的 `FocusScope` 处理关闭后焦点归还，但专门开了一个转义口子 `focusOnClose`（`packages/ui/src/services/popup/types.ts` 对应的 `ConfirmPopupProps.focusOnClose`，注释见 `types.ts:76-90`）——原因写得很直白：Radix 默认把焦点还给"打开弹窗前聚焦的元素"，但命令菜单/Popover 里触发的弹窗，触发者早已卸载，Radix 会把焦点落在过期元素或 `document.body` 上；`focusOnClose` 让调用方在 `onCloseAutoFocus`（`ConfirmPopupItem.tsx:111-119`，先 `preventDefault()` 再执行回调）里精确指定焦点落点，不用 race 一个 `requestAnimationFrame`。
- **两套调用入口**：`services/popup`（`src/renderer/services/popup/PopupService.ts`）是一个模块级 store，用 `useSyncExternalStore` 驱动，不依赖 React context，`PopupHost.tsx`（每个窗口一个）订阅它并渲染。①`createPopup<P,R>` 用于自定义交互弹窗（如图片预览、编辑名称对话框），返回 `show()/hide()`，`show()` 是 single-flight（重复调用复用同一个 promise，`types.ts:21-24`）；②`popup.confirm/error/info/warning` 四个"prefab"走 `showConfirm`，Promise 只解出 `boolean`，没有 `onOk/onCancel` 回调，也没有 antd 时代的 `Modal.destroyAll/update/warn/success`（`types.ts:39-59` 注释明确列出被砍掉的 API 面）。两阶段关闭：`settle()` 先 resolve promise 并把 `open` 置为 `false`（播放退场动画），`POPUP_EXIT_MS`（=`DIALOG_UNMOUNT_DELAY_MS`=200ms，`packages/ui/src/utils/dialog.ts:5`）后才真正从 store 移除（`PopupService.ts:74-87`）。
- **无 host 时的降级**：如果某个窗口没挂 `<PopupHost/>`（比如启动早期），`showComponent`/`showConfirm` 会直接 resolve `dismissResult`/`false` 并打 warn 日志（`PopupService.ts:100-103`, `124-127`），不会挂起等待——"popups are not usable on a startup path" 是代码原话。
- **动画**：开合动画不是 JS 补间，是 Radix `data-[state=open|closed]` 属性配合 Tailwind 动画类实现的纯 CSS 方案（见 13.7）。

### 13.2 Toast：自研 store，不是 antd message/react-hot-toast/sonner

`services/toast.ts` 包一层 i18n 标签解析，真正实现在 `@cherrystudio/ui` 的 `packages/ui/src/components/primitives/toast.tsx`：
- 也是模块级 `createToastStore()`（`toast.tsx:70-162`）+ `useSyncExternalStore`，全应用共享同一个 `defaultToastStore`（`toast.tsx:290-297` 的注释解释了为什么不按 provider 分叉：分叉会导致命令入口和实际渲染的 viewport 落在不同 store 上，"quickAssistant black-hole bug"）。
- **位置**：`ToastViewport` 固定在 `top-5 left-1/2`，即屏幕顶部居中，`flex-col` 纵向堆叠（`toast.tsx:372-380`），不是右下角/右上角。
- **自动消失时长**：默认 `DEFAULT_TIMEOUT = 3000ms`（`toast.tsx:51`），`success` 类型的 loading→success 转换用 `timeout ?? 2000`（更短，`toast.tsx:223`），`error` 转换默认 `timeout ?? 0`（即不自动消失，`toast.tsx:242`），`loading` 类型永不自动消失（`toast.tsx:116-118`）。
- **loading→success/error 的 promise 桥接**：`toast.loading({ promise, onError })` 会跟踪一个 `Symbol` 令牌（`loadingTokens`），只有令牌匹配才允许把 loading 状态"续写"为 success/error（`toast.tsx:189-249`），防止同一个 key 被后来的 loading 调用覆盖后，旧 promise resolve 时误写状态。
- **无障碍**：`getToastA11yProps`（`toast.tsx:313-319`）——`warning`/`error` 用 `role="alert"` + `aria-live="assertive"`，其余用 `role="status"` + `aria-live="polite"`；关闭按钮有 `aria-label={labels.close}`（`toast.tsx:346`）。
- Topic 侧的实际用例（`Topics.tsx:340-372`）演示了 loading toast 模式：导出图片时 `toast.loading({ key, promise, onError: () => {} })`，promise resolve/reject 后再各自 `toast.success`/`toast.error`。

### 13.3 Loading / 骨架屏 / 空状态：三种场景三种呈现，工具执行没有独立骨架

- **消息加载中**（Topic 切换/首次进入）：`MessageListInitialLoading`（`src/renderer/components/chat/messages/layout/MessageListLoading.tsx:6-52`）用 `@cherrystudio/ui` 的 `Skeleton` 拼出三条假消息（一条用户气泡 + 两条助手气泡骨架），`aria-busy="true"` 标注容器，`aria-hidden="true"` 标注骨架本体（纯装饰，不读给屏幕阅读器）。**特意延迟 160ms**（`MESSAGE_LIST_INITIAL_LOADING_DELAY_MS`）才显示骨架——如果消息在 160ms 内就加载完，骨架根本不会闪一下,这是刻意的防闪烁设计。
- **Topic 列表为空**：`TopicListBody` 的 `emptyFallback`（`Topics.tsx:1662` 附近）就是一段居中纯文本 `t('chat.topics.empty.title')`，没有插图/图标，比消息骨架简陋得多。列表加载中另有一行文字提示"`common.loading`"（`Topics.tsx:1391-1395` 附近），出现在已有部分数据但还在刷新时。
- **工具调用执行中**：没有独立的"骨架屏"，走的是行内状态指示——Topic 列表行右侧的运行指示统一为跨面板组件 `ConversationRowStatus`（`src/renderer/components/chat/resourceList/base/ConversationRowStatus.tsx:20-51`）：状态由 `Topics.tsx:1727-1735` 派生，`pending` 用 `Loader2` 旋转图标、`error` 用 `CircleAlert`、绿色小圆点表示"已完成但未读"（read-receipt 语义，`!isActive` 才显示，悬停/聚焦时淡出让位给 pin/delete 按钮）、等待审批显示为 warning 徽标；指示器带 `aria-label` + `role="img"`。红/绿视觉区分（避免早期版本"脉动琥珀色点"被误读成警告）的设计历史注释仍在代码中。消息内部工具调用块（`ToolBlockGroup`/`PlaceholderShimmerText`）用的是 13.7 提到的 `animation-shimmer` 文字光泽扫过效果，而不是块状骨架。

### 13.4 右键/上下文菜单：双模式，可在设置里切换 Cherry 自绘 vs 系统原生

菜单不是简单套一个 Radix `ContextMenu`，而是走统一的 `CommandContextMenu`/`CommandPopupMenu` 抽象（`src/renderer/components/command/CommandMenus.tsx`），由偏好项 `menu.presentation_mode`（`cherry` 或 `native`，默认 `cherry`，`src/shared/data/preference/preferenceSchemas.ts:440,748`）决定渲染路径：
- **`cherry` 模式**：渲染 Radix `ContextMenu`/`ContextMenuContent`（`CommandMenus.tsx:554-584`），菜单项支持子菜单、勾选态、危险态（`variant="destructive"`）、shortcut 标签、tooltip 说明。
- **`native` 模式**：`event.preventDefault()` 后调用 `window.api.command.showNativePopupMenu(...)` 把菜单模型序列化成 `NativePopupMenuModel` 丢给主进程弹出系统原生右键菜单（`CommandMenus.tsx:469-540`），点击结果通过 IPC 返回再本地执行对应 action。用户可在"设置 > 外观 > 右键菜单样式"（`AppearanceSettings.tsx:198-199,394`）切换，切换后需要重启应用生效（`AppearanceSettings.tsx:91-92` 有专门的重启提示 popup）。
- Topic 行、Agent Session 行的右键菜单都经 `ResourceListActionContextMenu`（`src/renderer/components/chat/actions/ResourceListActionContextMenu.tsx:21-27`）包一层——里面写明了原因："一个动作若带 inline confirm，会被转成 `ConfirmActionPopup` 在弹窗里执行,因为系统原生菜单没法承载内嵌确认框"。
- 消息正文的右键菜单是另一路：`SelectionContextMenu.tsx`（用于选中文本时提供"复制/引用到主窗口"），逻辑上专门剥离代码块行号（`.line-number` 过滤，`SelectionContextMenu.tsx:18-54`），保证复制代码时不会带上行号前缀。图片有自己的第三路右键菜单（见 13.8）。

### 13.5 主题/深色模式：Electron `nativeTheme` 是权威源，渲染层只是订阅者

完整链路分三层：
1. **主进程权威状态**：`ThemeService`（`src/main/services/ThemeService.ts:8-38`）持有偏好 `ui.theme_mode`（`light`/`dark`/`system`），启动时把它写进 Electron 的 `nativeTheme.themeSource`（这样系统原生 UI，比如原生右键菜单、系统对话框，也会跟着变色）；监听 `nativeTheme.on('updated', ...)`，一旦 OS 主题变化就广播 IPC 事件 `system.native_theme_updated`，payload 是解析后的实际颜色（`dark`/`light`，已经不含 `system`）。
2. **渲染层订阅 + 首帧防闪烁**：`ThemeProvider.tsx` 用 `useState` 的初始值直接读已保存偏好而不是等 effect（`ThemeProvider.tsx:34-36` 注释:"入口在渲染前已经 await 过偏好预加载，等 effect 里的同步会先提交一帧 OS 主题,当保存主题和 OS 不同时会闪一下"）；如果 `settedTheme === system`，先用 `window.matchMedia('(prefers-color-scheme: dark)')` 本地即时判断（`getSystemTheme`，`ThemeProvider.tsx:24-25`）撑住首帧,随后再等 IPC `system.get_native_theme` 请求回来对齐权威值（`:86-94`）。切换实际主题只是给 `document.documentElement`/`document.body` 加减 `light`/`dark` 类名（`tailwindThemeChange`，`:18-22`）。
3. **CSS 变量方案**：不是自定义一套变量名,而是**遵循 Shadcn 官方变量契约**（`packages/ui/src/styles/shadcn.css`），`:root`/`.dark` 里的 `--background`/`--foreground`/`--primary` 等官方变量全部 `var()` 转发到 Cherry 自己的语义层 `--cs-*`（`shadcn.css:11-54`），文件顶部注释解释了这么做的原因：保持官方变量名不加前缀是为了"生态兼容性",这样第三方 Shadcn 主题（如 TweakCN）可以直接套用,而 Cherry 的产品语义留在 `--cs-*` 这一层单独切换。用户自定义主色/字体（`AppearanceSettings` 里的取色器）走另一条路径：`useUserTheme.ts` 直接用 `document.documentElement.style.setProperty('--cs-theme-primary', ...)` 写行内样式（`useUserTheme.ts:19-26`），不经过偏好里的静态 CSS 文件,livePreview 时不需要重新生成样式表。
4. **存储位置**：三个偏好键都在渲染层通过 `usePreference` 持久化——`ui.theme_mode`（跟随系统/浅色/深色）、`ui.theme_user.color_primary`（自定义主色）、`ui.theme_user.font_family`/`code_font_family`（自定义字体），底层落在偏好存储（未展开细查其落盘格式,超出本节范围）。

### 13.6 无障碍：Topic/Session 列表有完整的 listbox 语义，但消息操作按钮的默认渲染路径缺 `aria-label`

**做得到位的地方**（有代码实证）：
- `ResourceList`（Topic 列表、Agent Session 列表共用的基础组件）实现了标准的**roving tabindex + `aria-activedescendant`** 模式：容器 `role="listbox"`（`ResourceListVirtual.tsx:551,777`），行 `role="option"` + `aria-selected`（`ResourceList.tsx:388-394`），键盘 `ArrowUp/ArrowDown/Home/End/Enter` 都有对应测试覆盖并断言 `aria-activedescendant` 正确移动（`__tests__/ResourceList.test.tsx:622-671`）——这是教科书式的可访问列表实现，比很多类似应用的自绘列表更规范。
- Toast 有 `role="alert"`/`role="status"` + `aria-live`区分严重程度（13.2）。
- 折叠交互（用户消息折叠、Thinking 块展开/收起）用了真实的 `aria-expanded`/`aria-controls`（`MainTextBlock.tsx:234-235`、`ThinkingBlock.tsx:95-96`），并且是可聚焦、可键盘触发的 `role="button"` + `onKeyDown` 处理 Enter/Space（`ThinkingBlock.tsx:93-105`），不是纯鼠标 div。
- 消息操作栏里**部分**按钮显式传了 `aria-label`：模型选择器（`renderModelPickerToolbarAction`,`MessageMenuBarToolbarRenderers.tsx:287`）、翻译（`:311`）、更多菜单弹出按钮（`:355,412`）。

**实证的缺失**：消息操作栏最常用的一批按钮——默认渲染路径 `renderDefaultToolbarAction` → `ActionButtonWithConfirm`（`MessageMenuBarToolbarRenderers.tsx:63-126`，覆盖复制、编辑、重新生成、删除、点赞等大多数没有专属渲染函数的 action）——生成的 `<MessageActionButton>` **没有传 `aria-label`**（对照 `:80-91` 和 `:103-113` 两处按钮 JSX，都只有 `onClick`/`disabled`/`className`,没有任何 `aria-*` 属性）。这些按钮的可访问名称完全依赖视觉 Tooltip（`content={tooltip}`，鼠标悬停才出现，`:119-125`），而 Tooltip 内容不会自动同步成 `aria-label`——screen reader 用户对着这些图标按钮会读到"button"而没有任何描述文字。这不是全局性缺陷（Topic 列表的 pin/delete 按钮都老老实实传了 `aria-label`，见 `Topics.tsx:1737,1750`），而是消息操作栏这一条渲染路径的具体疏漏，且覆盖面恰恰是使用频率最高的复制/编辑/删除等动作。
- 富文本输入框（composer,基于 TipTap `EditorContent`）本身没有为 `contentEditable` 根节点设置 `aria-label`/`role="textbox"`——检索 `RichEditor.tsx`、`ComposerSurface.tsx` 全文,只有编辑器外围的工具按钮（暂停、编辑定位、取消编辑、展开高度等）有 `aria-label`（`ComposerSurface.tsx:2114-2207`），输入区域本体依赖浏览器/TipTap 默认的可编辑语义，没有显式补充可访问名称。
- 未检索到 `prefers-reduced-motion` 的针对性处理之外的内容：唯一相关的是 Radix 动画类统一带了 `motion-reduce:animate-none`（`dialog.tsx:35,127`），说明弹窗动画对"减少动态效果"系统设置有响应，但业务层的滚动/淡入交互没有逐一确认是否都遵循这条。

### 13.7 动画/过渡：没有 Framer Motion，全部是 CSS/Tailwind + Radix data-state

`package.json` 全文搜索 `framer-motion` **无匹配**——这个仓库不用 JS 动画库。实际方案是三层：
1. **`tw-animate-css`**（`package.json:426`,Tailwind 动画工具类插件）+ Radix 组件自带的 `data-[state=open|closed]` 属性,驱动 Dialog/ContextMenu/Tooltip/Popover 的进出场（`dialog.tsx:33-37,123-127`：`fade-in-0`/`zoom-in-99`/`slide-in-from-bottom-4` 等,进场 260ms、退场 200ms,统一 `motion-reduce:animate-none`）。
2. **手写 CSS `@keyframes`**：`src/renderer/assets/styles/animation.css` 里 `animation-shimmer`（3s 线性循环,文字渐变光泽扫过,用于 Topic 重命名中的加载态和工具调用占位文本 `PlaceholderShimmerText.tsx`）与 `animation-reveal`（0.5s,重命名刚完成时的"揭示"效果,`Topics.tsx:1634-1638` 消费这两个类名）。
3. **纯 CSS transition**：折叠展开（Thinking 块、用户消息折叠）用的是 `hidden` 属性硬切换 + chevron 图标 `transition-transform duration-200`（`ThinkingBlock.tsx:134-138`,`MainTextBlock.tsx:244`）——内容本身没有高度动画,只有箭头旋转有过渡,即"展开"在视觉上是瞬时的,不是逐渐撐开高度。消息栏悬停显隐、滚动到底按钮出现,都是 `opacity`/`duration-150` 级别的简单 CSS transition（`MessageFrame.tsx:34,119`；`MessageVirtualList.tsx` 的 `ScrollToBottomButton`）。

### 13.8 图片/附件预览与代码块交互反馈

- **图片有完整灯箱**：`ImageViewer.tsx` 包 `@cherrystudio/ui` 的 `ImagePreviewDialog`（`packages/ui/src/components/composites/image-preview/image-preview-dialog.tsx`），支持缩放/旋转/水平垂直翻转/上一张下一张（多图导航靠 `activeIndex`,`ImageViewer.tsx:107-155`），工具栏和右键菜单共享同一份 action 列表（复制图片、复制图片地址、下载,`ImageViewer.tsx:201-232`），右键菜单走的还是 13.4 提到的统一 `CommandContextMenu`（`:296-298`）。所有操作都有 toast 反馈（成功/失败,`:157-199`）。另提供"保存为图片"动作，保存时把旋转/翻转**烘焙**进输出的 PNG（`transformImageToPng`，`d1ffaa82ce`；全屏观看交互 `e22a976586`）。
- **代码块复制/运行的交互反馈**：复制按钮点击后图标临时切换成对勾（`useCopyTool.tsx:18-31,51`,`useTemporaryValue` hook 控制"临时态"多久后自动复原,复制图片按钮同理有独立的 `copiedImage` 临时态）,并弹 toast（`CodeBlockView.tsx:154-164`）。“运行”仅对 Python 代码块生效（`isExecutable = codeExecutionEnabled && language === 'python'`,`CodeBlockView.tsx:114-116`），执行走**浏览器内嵌 Pyodide**（`pyodideService.runScript`,`:189-203`）而不是发到主进程开子进程,超时由偏好 `chat.code.execution.timeout_minutes` 控制,执行结果（文本/图片）展示在代码块下方的 `StatusBar`（`StatusBar.tsx`,一个纵向滚动的 `bg-muted` 面板）。工具栏本身是可弹出子菜单的 `CodeToolButton`（`CodeToolButton.tsx`,支持 `Enter`/`Space` 键盘触发,`:14-22`,有 `aria-label={tool.tooltip}`）。代码查看器 wrapped 模式下超长不可断行内容（base64/URL/minified JSON）强制换行而非截断溢出（`CodeViewer.tsx:638-642` 的 `min-w-0` + `whitespace-pre-wrap!`，`205f042800`）。

### 13.9 响应式/窗口尺寸适配：没有断点驱动的侧栏折叠,但主窗口最小宽度会跟着页面切换

- 检索侧栏容器和 `ResourceEntityRail` 未发现 `ResizeObserver`/`matchMedia`/CSS `@container` 驱动的自动折叠逻辑——侧栏展开/折叠是**手动命令**（`app.sidebar.toggle`,`HomePage.tsx:408`）,不是随窗口变窄自动收起。
- 但主窗口的**最小可缩放宽度会随页面动态调整**：进入聊天工作台时 `AppShell` 调用 IPC 把主窗口最小尺寸从默认 `MIN_WINDOW_WIDTH=960px`（`src/shared/utils/window.ts:1`,写在 `windowRegistry.ts:63` 的窗口创建配置里）临时放宽到 `SECOND_MIN_WINDOW_WIDTH=520px`（`AppShell.tsx:140` 的 `window.main.set_minimum_size`），离开页面时还原。也就是说聊天页允许把窗口拖得比其他页面更窄。
- **阅读宽度限制**是另一套独立机制,跟窗口尺寸无关：`NarrowLayout.tsx` 把消息内容限制在 `800px`（`chat.narrow_mode` 偏好开关,默认 `true`,`preferenceSchemas.ts:184,587`）,是用户可关闭的排版偏好,不是响应式断点。

### 13.10 拖放细节：Topic 按助手分组排序有完整拖拽,按时间分组则不可拖拽;附件拖入有绿色虚线高亮

- **Composer 附件拖入**：拖拽经过 `useFileDragDrop.ts`（文件、文本、文件夹路径分别处理,不支持类型会 toast 提示,`:122-129`），视觉反馈是 2px 绿色虚线边框 + 半透明绿色蒙层（`ComposerSurface.tsx:2171-2173`,硬编码色值 `#2ecc71`,不是走 CSS 变量的主题色）。
- **Topic 拖拽排序**：只有当 Topic 列表按"助手分组"显示时才可拖（`canDragTopicItem`/`dragReady = isAssistantDisplayMode && ...`,`Topics.tsx:1136-1139,797`）,按"时间分组"显示时完全不可拖——这是一个有意为之的限制（时间分组的顺序由时间戳决定,拖拽没有语义）。助手分组本身也可以整组拖拽重排（`canDragTopicGroup`/`handleTopicReorder` 里的 `payload.type === 'group'` 分支,`:1150-1158,1187-1231`），带乐观更新和失败回滚（`setOptimisticAssistantOrderIds`,失败时 toast + 回滚,`:1215-1228`）。
- 未在本节范围内找到"Session 列表拖拽排序"的独立实现（Agent 侧 `SessionItem.tsx` 只在右键菜单命中,未见拖拽相关代码路径）,如需确认建议单独检索 `src/renderer/pages/agents`。

### 13.11 桌面端集成（Electron）：托盘/通知与聊天状态部分联动,但"助手回复完成"通知是个空开关

- **托盘**：`TrayService.ts` 在 mac 上会根据 `nativeTheme.shouldUseDarkColors` 切换亮/暗两套托盘图标（`:29`），点击托盘图标的行为受偏好 `feature.quick_assistant.click_tray_to_show` 控制——开则唤起 QuickAssistant 悬浮窗,关则唤起主窗口（`:61-71`）,这是托盘点击与"快速助手"功能的联动,但托盘本身不显示未读消息数/流式状态角标（未检索到 `setBadgeCount`/`flashFrame`/`setOverlayIcon` 调用）。
- **系统通知**：`NotificationService`（主进程,`src/main/services/NotificationService.ts`）用 Electron 原生 `Notification` API,点击通知会 `showMainWindow()` 并广播 `notification.clicked`（`:14-17`）。渲染层 `notificationService.send()`（`src/renderer/services/notification/NotificationService.ts:10-24`）会先查三个偏好开关（`assistant`/`backup`/`knowledge`）再决定是否真的调 IPC 发送。
- **一个值得记录的空路径**：偏好 `app.notification.assistant.enabled` 和对应的设置项开关（`NotificationSettings.tsx:36-48`，"助手回复完成通知"）确实存在,但**全仓库检索不到任何一处 `notificationService.send({..., source: 'assistant'})` 调用**——实际发通知的三处调用点（`BackupService.ts` 七处、`useAppUpdateHandler.ts` 一处）分别用的是 `source: 'backup'` 和 `source: 'update'`。也就是说"助手完成回复时弹系统通知"这个开关目前接不到任何触发点,是个用户能看到、能勾选、但不会生效的空挂钩(不同于代码里自己写 TODO 承认的 `update` 缺口，见 `NotificationService.ts:17-20` 的另一条已知 TODO——这里是 `assistant` 这条连 TODO 都没提到，属于本次调查新发现)。
- **全局快捷键**：`ShortcutService.ts` 按**本地/全局分轨**注册——`global` 标记的快捷键仍走 `globalShortcut`（含失焦时的注册集），其余本地快捷键不再注册到系统，而是挂在窗口 `webContents.before-input-event`（含 `did-attach-webview` 挂上的 guest webview 输入）上按命令解析拦截（`ShortcutService.ts:123-196`），应用失焦时本地快捷键自然不生效；快捷键冲突（被其他应用占用）仍记录冲突集合并通过 IPC 广播给渲染层展示提示（`:281-303` 附近）。另有标签页导航快捷键（`324f26f728`）。**未找到独立的"快捷键帮助面板/速查表"浮层**——只有"设置 > 快捷键"这一个静态配置页（`ShortcutSettings.tsx`），不存在按一个快捷键呼出速查列表的入口。

### 13.12 未找到实现的方向（如实说明）

- 快捷键速查/帮助浮层：不存在,只有设置页（13.11）。
- Session（Agent 会话）列表的独立拖拽排序：未检索到实现,与 Topic 的拖拽是两套完全独立的代码路径,本次未展开确认 Agent 侧细节。
- 托盘/任务栏图标随聊天状态变化（未读计数、流式中角标）：未找到 `setBadgeCount`/`flashFrame`/`setOverlayIcon` 调用,判断为没有实现。
- 折叠/展开动画的高度渐变：Thinking 块、用户消息折叠都是 `hidden` 属性硬切换,没有 `max-height`/`grid-rows` 过渡,只有箭头旋转有动画（13.7 已述,此处不重复归为缺失,只是澄清并非"平滑展开"效果）。
