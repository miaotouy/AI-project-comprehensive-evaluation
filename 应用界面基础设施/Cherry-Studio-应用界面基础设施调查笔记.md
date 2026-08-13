# Cherry Studio 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对（Grep + Read 全文阅读），逐条标注文件+行号；查无实据的方向直接写"未找到"
>
> 调查范围：弹窗库（Radix Dialog）、Toast、加载/空状态、右键菜单双模式、主题链路、无障碍盘点、动画方案、图片灯箱与代码块交互、响应式适配、拖放细节、桌面端集成（托盘/通知/快捷键）、未找到方向；聊天主链交点（弹窗在消息操作中的消费、toast 反馈等）由 [`../Chat UI/Cherry-Studio-ChatUI调查笔记.md`](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>) 记录
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 已从 antd Modal 迁移出来（`package.json` 无 `antd` 依赖），弹窗与 Toast 都是自研实现：对话框基础组件是内部 `@cherrystudio/ui` 包基于 `@radix-ui/react-dialog` 封装的 `Dialog`，配合 `services/popup` 模块级 store（`useSyncExternalStore` 驱动、每窗口一个 `PopupHost`）提供命令式 API；Toast 是自研 `createToastStore` 单例（无 antd message/sonner），带 loading→success/error 的 promise 令牌桥接与完整 aria 语义。主题以 Electron 主进程 `nativeTheme` 为权威源，渲染层只是订阅者，CSS 变量遵循 Shadcn 官方契约（无前缀）转发到自家 `--cs-*` 语义层。右键菜单有 Cherry 自绘 / 系统原生双模式，可设置切换。

## 系统边界与总体装配

- **界面栈**：React + Tailwind（含 `tw-animate-css`）；内部 UI 包 `@cherrystudio/ui`（`packages/ui`，基于 Radix 生态）；无 antd、无 framer-motion、无 react-hot-toast/sonner。
- **弹窗装配**：`PopupHost.tsx` 每个窗口挂一个，订阅模块级 `PopupService`（`src/renderer/services/popup/PopupService.ts`，`useSyncExternalStore` 驱动，不依赖 React context）；无 host 时（启动早期）`showComponent`/`showConfirm` 直接 resolve `dismissResult`/`false` 并打 warn（`PopupService.ts:100-103, 124-127`），"popups are not usable on a startup path" 是代码原话。
- **Toast 装配**：`services/toast.ts` 包一层 i18n 标签解析，真正实现在 `@cherrystudio/ui` 的 `packages/ui/src/components/primitives/toast.tsx`——模块级 `createToastStore()`（`toast.tsx:70-162`）+ `useSyncExternalStore`，全应用共享 `defaultToastStore`（`toast.tsx:290-297` 注释解释不按 provider 分叉的原因：分叉会导致命令入口和实际渲染的 viewport 落在不同 store 上，"quickAssistant black-hole bug"）。

## 1. 界面栈、公共组件与状态所有权

- **状态所有权**：弹窗状态在模块级 `PopupService` store（React 组件树外），Toast 在模块级 toast store；两套都是"命令入口与渲染 viewport 共享同一 store"的单例设计。
- **主题状态**：权威在主进程 `ThemeService`，渲染层订阅 IPC（见第 4 节）。
- **窗口装配**：每窗口挂 `<PopupHost/>`；`AppShell` 进入聊天工作台时调整主窗口最小尺寸（见第 5 节）。

## 2. 弹窗、浮层与菜单

### 弹窗/对话框（自建 Radix 封装 + 两套调用入口）

对话框基础组件是 `@cherrystudio/ui` 基于 `@radix-ui/react-dialog` 封装的 `Dialog`/`DialogContent`（`packages/ui/src/components/primitives/dialog.tsx:10-149`）：

- **Esc/遮罩关闭**：`DialogOverlay` 点击默认触发 Radix 的 `Dialog.Close`（`dialog.tsx:101-108`），可用 `closeOnOverlayClick={false}` 关掉；Esc 键关闭是 Radix `Dialog.Root` 默认行为，代码里没有覆盖 `onEscapeKeyDown`——所有 Dialog 默认支持 Esc 关闭。业务层确认弹窗（`ConfirmPopupItem.tsx:121-124`）额外用 `onInteractOutside` 手动挡遮罩点击（`maskClosable === false` 时 `event.preventDefault()`），是 Radix 上叠加的业务开关。
- **焦点管理**：`DialogContent` 默认交给 Radix `FocusScope` 处理关闭后焦点归还，但专门开了转义口子 `focusOnClose`（`ConfirmPopupProps.focusOnClose`，`packages/ui/src/services/popup/types.ts:76-90`）——原因写得很直白：Radix 默认把焦点还给"打开弹窗前聚焦的元素"，但命令菜单/Popover 里触发的弹窗触发者早已卸载，Radix 会把焦点落在过期元素或 `document.body` 上；`focusOnClose` 让调用方在 `onCloseAutoFocus`（`ConfirmPopupItem.tsx:111-119`，先 `preventDefault()` 再执行回调）里精确指定焦点落点，不用 race `requestAnimationFrame`。
- **两套调用入口**：①`createPopup<P,R>` 用于自定义交互弹窗（图片预览、编辑名称对话框），返回 `show()/hide()`，`show()` 是 single-flight（重复调用复用同一 promise，`types.ts:21-24`）；②`popup.confirm/error/info/warning` 四个 "prefab" 走 `showConfirm`，Promise 只解出 `boolean`，无 `onOk/onCancel` 回调，也没有 antd 时代的 `Modal.destroyAll/update/warn/success`（`types.ts:39-59` 注释明确列出被砍掉的 API 面）。两阶段关闭：`settle()` 先 resolve promise 并把 `open` 置 `false`（播放退场动画），`POPUP_EXIT_MS`（=`DIALOG_UNMOUNT_DELAY_MS`=200ms，`packages/ui/src/utils/dialog.ts:5`）后才真正从 store 移除（`PopupService.ts:74-87`）。
- **动画**：开合动画不是 JS 补间，是 Radix `data-[state=open|closed]` 属性配合 Tailwind 动画类的纯 CSS 方案（见第 7 节）。

### 右键/上下文菜单：双模式，设置里可切换 Cherry 自绘 vs 系统原生

菜单走统一 `CommandContextMenu`/`CommandPopupMenu` 抽象（`src/renderer/components/command/CommandMenus.tsx`），由偏好项 `menu.presentation_mode`（`cherry` 或 `native`，默认 `cherry`，`src/shared/data/preference/preferenceSchemas.ts:440,748`）决定渲染路径：

- **`cherry` 模式**：渲染 Radix `ContextMenu`/`ContextMenuContent`（`CommandMenus.tsx:554-584`），菜单项支持子菜单、勾选态、危险态（`variant="destructive"`）、shortcut 标签、tooltip 说明。
- **`native` 模式**：`event.preventDefault()` 后调 `window.api.command.showNativePopupMenu(...)` 把菜单模型序列化成 `NativePopupMenuModel` 丢给主进程弹系统原生右键菜单（`CommandMenus.tsx:469-540`），点击结果经 IPC 返回再本地执行。设置 > 外观 > 右键菜单样式（`AppearanceSettings.tsx:198-199,394`）切换，切换后需重启应用生效（`AppearanceSettings.tsx:91-92` 有专门重启提示 popup）。
- Topic 行、Agent Session 行的右键菜单经 `ResourceListActionContextMenu`（`src/renderer/components/chat/actions/ResourceListActionContextMenu.tsx:21-27`）包一层——里面写明原因："一个动作若带 inline confirm，会被转成 `ConfirmActionPopup` 在弹窗里执行，因为系统原生菜单没法承载内嵌确认框"。
- 消息正文右键菜单是另一路：`SelectionContextMenu.tsx`（选中文本时"复制/引用到主窗口"），专门剥离代码块行号（`.line-number` 过滤，`SelectionContextMenu.tsx:18-54`），保证复制代码不带行号前缀。图片有自己的第三路右键菜单（见第 6 节）。

## 3. 通知、加载态与错误反馈

### Toast（自研 store，非 antd message/react-hot-toast/sonner）

- **位置**：`ToastViewport` 固定在 `top-5 left-1/2`，屏幕顶部居中，`flex-col` 纵向堆叠（`toast.tsx:372-380`）。
- **自动消失时长**：默认 `DEFAULT_TIMEOUT = 3000ms`（`toast.tsx:51`）；`success` 类型的 loading→success 转换用 `timeout ?? 2000`（更短，`toast.tsx:223`）；`error` 转换默认 `timeout ?? 0`（不自动消失，`toast.tsx:242`）；`loading` 类型永不自动消失（`toast.tsx:116-118`）。
- **loading→success/error 的 promise 桥接**：`toast.loading({ promise, onError })` 跟踪一个 `Symbol` 令牌（`loadingTokens`），只有令牌匹配才允许把 loading 状态"续写"为 success/error（`toast.tsx:189-249`），防止同一 key 被后来的 loading 覆盖后旧 promise resolve 误写状态。
- **无障碍**：`getToastA11yProps`（`toast.tsx:313-319`）——`warning`/`error` 用 `role="alert"` + `aria-live="assertive"`，其余 `role="status"` + `aria-live="polite"`；关闭按钮有 `aria-label={labels.close}`（`toast.tsx:346`）。
- 用例（`Topics.tsx:340-372`）：导出图片时 `toast.loading({ key, promise, onError: () => {} })`，promise resolve/reject 后各自 `toast.success`/`toast.error`。

### Loading / 骨架屏 / 空状态（三种场景三种呈现，工具执行没有独立骨架）

- **消息加载中**（Topic 切换/首次进入）：`MessageListInitialLoading`（`src/renderer/components/chat/messages/layout/MessageListLoading.tsx:6-52`）用 `@cherrystudio/ui` 的 `Skeleton` 拼三条假消息（一条用户气泡 + 两条助手气泡骨架），`aria-busy="true"` 标注容器，`aria-hidden="true"` 标注骨架本体。**特意延迟 160ms**（`MESSAGE_LIST_INITIAL_LOADING_DELAY_MS`）才显示骨架——消息在 160ms 内加载完骨架根本不闪一下，是刻意的防闪烁设计。
- **Topic 列表为空**：`TopicListBody` 的 `emptyFallback`（`Topics.tsx:1662` 附近）是一段居中纯文本 `t('chat.topics.empty.title')`，无插图/图标；列表加载中另有一行文字提示"`common.loading`"（`Topics.tsx:1391-1395` 附近）。
- **工具调用执行中**：没有独立骨架屏，走行内状态指示——Topic 列表行右侧运行指示统一为跨面板组件 `ConversationRowStatus`（`src/renderer/components/chat/resourceList/base/ConversationRowStatus.tsx:20-51`）：状态由 `Topics.tsx:1727-1735` 派生，`pending` 用 `Loader2` 旋转图标、`error` 用 `CircleAlert`、绿色小圆点表示"已完成但未读"（read-receipt 语义，`!isActive` 才显示，悬停/聚焦时淡出让位给 pin/delete 按钮）、等待审批显示 warning 徽标；指示器带 `aria-label` + `role="img"`。红/绿视觉区分（避免早期版本"脉动琥珀色点"被误读成警告）的设计历史注释仍在代码中。消息内部工具调用块（`ToolBlockGroup`/`PlaceholderShimmerText`）用的是 `animation-shimmer` 文字光泽扫过效果，不是块状骨架。

## 4. 主题、视觉 token 与持久化

完整链路分三层：

1. **主进程权威状态**：`ThemeService`（`src/main/services/ThemeService.ts:8-38`）持有偏好 `ui.theme_mode`（`light`/`dark`/`system`），启动时写进 Electron 的 `nativeTheme.themeSource`（系统原生 UI——原生右键菜单、系统对话框——也跟着变色）；监听 `nativeTheme.on('updated', ...)`，OS 主题变化即广播 IPC 事件 `system.native_theme_updated`，payload 是解析后的实际颜色（`dark`/`light`，已不含 `system`）。
2. **渲染层订阅 + 首帧防闪烁**：`ThemeProvider.tsx` 用 `useState` 初始值直接读已保存偏好而不是等 effect（`ThemeProvider.tsx:34-36` 注释："入口在渲染前已经 await 过偏好预加载，等 effect 里的同步会先提交一帧 OS 主题，当保存主题和 OS 不同时会闪一下"）；`settedTheme === system` 时先用 `window.matchMedia('(prefers-color-scheme: dark)')` 本地即时判断（`getSystemTheme`，`ThemeProvider.tsx:24-25`）撑住首帧，随后等 IPC `system.get_native_theme` 请求回来对齐权威值（`:86-94`）。切换实际主题只是给 `document.documentElement`/`document.body` 加减 `light`/`dark` 类名（`tailwindThemeChange`，`:18-22`）。
3. **CSS 变量方案**：遵循 Shadcn 官方变量契约（`packages/ui/src/styles/shadcn.css`），`:root`/`.dark` 里的 `--background`/`--foreground`/`--primary` 等官方变量全部 `var()` 转发到 Cherry 自己的语义层 `--cs-*`（`shadcn.css:11-54`），文件顶部注释解释原因：官方变量名不加前缀是"生态兼容性"——第三方 Shadcn 主题（如 TweakCN）可直接套用，产品语义留在 `--cs-*` 层单独切换。用户自定义主色/字体（`AppearanceSettings` 取色器）走另一条路径：`useUserTheme.ts` 直接用 `document.documentElement.style.setProperty('--cs-theme-primary', ...)` 写行内样式（`useUserTheme.ts:19-26`），不经过静态 CSS 文件，livePreview 时不需要重新生成样式表。
4. **存储位置**：三个偏好键都在渲染层 `usePreference` 持久化——`ui.theme_mode`、`ui.theme_user.color_primary`、`ui.theme_user.font_family`/`code_font_family`，底层落在偏好存储（落盘格式未展开细查）。

## 5. 响应式、移动端与窗口适配

- **没有断点驱动的侧栏折叠**：检索侧栏容器和 `ResourceEntityRail` 未发现 `ResizeObserver`/`matchMedia`/CSS `@container` 驱动的自动折叠——侧栏展开/折叠是**手动命令**（`app.sidebar.toggle`，`HomePage.tsx:408`），不随窗口变窄自动收起。
- **主窗口最小宽度随页面动态调整**：进入聊天工作台时 `AppShell` 调用 IPC 把主窗口最小尺寸从默认 `MIN_WINDOW_WIDTH=960px`（`src/shared/utils/window.ts:1`，写在 `windowRegistry.ts:63` 的窗口创建配置里）临时放宽到 `SECOND_MIN_WINDOW_WIDTH=520px`（`AppShell.tsx:140` 的 `window.main.set_minimum_size`），离开时还原——聊天页允许把窗口拖得比其他页面更窄。
- **阅读宽度限制是另一套独立机制**：`NarrowLayout.tsx` 把消息内容限制在 `800px`（`chat.narrow_mode` 偏好开关，默认 `true`，`preferenceSchemas.ts:184,587`），是用户可关闭的排版偏好，不是响应式断点。

## 6. 图片、附件、拖放与常见内容交互

### 图片灯箱与代码块交互

- **图片有完整灯箱**：`ImageViewer.tsx` 包 `@cherrystudio/ui` 的 `ImagePreviewDialog`（`packages/ui/src/components/composites/image-preview/image-preview-dialog.tsx`），支持缩放/旋转/水平垂直翻转/上一张下一张（多图导航靠 `activeIndex`，`ImageViewer.tsx:107-155`），工具栏和右键菜单共享同一份 action 列表（复制图片、复制图片地址、下载，`ImageViewer.tsx:201-232`），右键菜单走第 2 节的统一 `CommandContextMenu`（`:296-298`）。所有操作都有 toast 反馈（成功/失败，`:157-199`）。"保存为图片"动作会把旋转/翻转**烘焙**进输出的 PNG（`transformImageToPng`，`d1ffaa82ce`；全屏观看交互 `e22a976586`）。
- **代码块复制/运行的交互反馈**：复制按钮点击后图标临时切换成对勾（`useCopyTool.tsx:18-31,51`，`useTemporaryValue` hook 控制"临时态"多久后自动复原；复制图片按钮同理有独立 `copiedImage` 临时态），并弹 toast（`CodeBlockView.tsx:154-164`）。"运行"仅对 Python 代码块生效（`isExecutable = codeExecutionEnabled && language === 'python'`，`CodeBlockView.tsx:114-116`），执行走**浏览器内嵌 Pyodide**（`pyodideService.runScript`，`:189-203`）而不是主进程子进程，超时由偏好 `chat.code.execution.timeout_minutes` 控制，执行结果（文本/图片）展示在代码块下方 `StatusBar`（一个纵向滚动 `bg-muted` 面板）。工具栏本身是可弹出子菜单的 `CodeToolButton`（`CodeToolButton.tsx`，支持 `Enter`/`Space` 键盘触发，`:14-22`，有 `aria-label={tool.tooltip}`）。代码查看器 wrapped 模式下超长不可断行内容（base64/URL/minified JSON）强制换行而非截断溢出（`CodeViewer.tsx:638-642` 的 `min-w-0` + `whitespace-pre-wrap!`，`205f042800`）。

### 拖放细节

- **Composer 附件拖入**：拖拽经过 `useFileDragDrop.ts`（文件、文本、文件夹路径分别处理，不支持类型会 toast 提示，`:122-129`），视觉反馈是 2px 绿色虚线边框 + 半透明绿色蒙层（`ComposerSurface.tsx:2171-2173`，硬编码色值 `#2ecc71`，不走 CSS 变量主题色）。
- **Topic 拖拽排序**：只有按"助手分组"显示时才可拖（`canDragTopicItem`/`dragReady = isAssistantDisplayMode && ...`，`Topics.tsx:1136-1139,797`），按"时间分组"显示时完全不可拖——有意为之的限制（时间分组顺序由时间戳决定，拖拽没有语义）。助手分组可整组拖拽重排（`canDragTopicGroup`/`handleTopicReorder` 的 `payload.type === 'group'` 分支，`:1150-1158,1187-1231`），带乐观更新和失败回滚（`setOptimisticAssistantOrderIds`，失败时 toast + 回滚，`:1215-1228`）。
- Session（Agent 会话）列表的独立拖拽排序未在范围内找到实现（`SessionItem.tsx` 只在右键菜单命中），如需确认建议单独检索 `src/renderer/pages/agents`。

## 7. 扩展调查：无障碍、动画、桌面集成

### 无障碍（静态代码结论）

**做得到位的地方**：
- `ResourceList`（Topic 列表、Agent Session 列表共用）实现标准 **roving tabindex + `aria-activedescendant`** 模式：容器 `role="listbox"`（`ResourceListVirtual.tsx:551,777`），行 `role="option"` + `aria-selected`（`ResourceList.tsx:388-394`），键盘 `ArrowUp/ArrowDown/Home/End/Enter` 都有对应测试覆盖并断言 `aria-activedescendant` 正确移动（`__tests__/ResourceList.test.tsx:622-671`）。
- Toast 有 `role="alert"`/`role="status"` + `aria-live` 区分严重程度（第 3 节）。
- 折叠交互（用户消息折叠、Thinking 块展开/收起）用了真实 `aria-expanded`/`aria-controls`（`MainTextBlock.tsx:234-235`、`ThinkingBlock.tsx:95-96`），并且是可聚焦、可键盘触发的 `role="button"` + `onKeyDown` 处理 Enter/Space（`ThinkingBlock.tsx:93-105`），不是纯鼠标 div。
- 消息操作栏**部分**按钮显式传了 `aria-label`：模型选择器（`renderModelPickerToolbarAction`，`MessageMenuBarToolbarRenderers.tsx:287`）、翻译（`:311`）、更多菜单弹出按钮（`:355,412`）。

**实证的缺失**：消息操作栏最常用的一批按钮——默认渲染路径 `renderDefaultToolbarAction` → `ActionButtonWithConfirm`（`MessageMenuBarToolbarRenderers.tsx:63-126`，覆盖复制、编辑、重新生成、删除、点赞等大多数没有专属渲染函数的 action）——生成的 `<MessageActionButton>` **没有传 `aria-label`**（对照 `:80-91` 和 `:103-113` 两处按钮 JSX，都只有 `onClick`/`disabled`/`className`，无任何 `aria-*` 属性）。可访问名称完全依赖视觉 Tooltip（`content={tooltip}`，`:119-125`），而 Tooltip 内容不会自动同步成 `aria-label`——screen reader 用户只会读到"button"没有任何描述。不是全局性缺陷（Topic 列表 pin/delete 都传了 `aria-label`，`Topics.tsx:1737,1750`），而是消息操作栏这一条渲染路径的具体疏漏，覆盖面恰是使用频率最高的复制/编辑/删除等动作。

**其它**：富文本输入框（composer，基于 TipTap `EditorContent`）本身没有为 `contentEditable` 根节点设置 `aria-label`/`role="textbox"`——`RichEditor.tsx`、`ComposerSurface.tsx` 全文只有编辑器外围工具按钮有 `aria-label`（`ComposerSurface.tsx:2114-2207`），输入区域本体依赖浏览器/TipTap 默认可编辑语义。`prefers-reduced-motion` 方面唯一相关的是 Radix 动画类统一带 `motion-reduce:animate-none`（`dialog.tsx:35,127`），业务层滚动/淡入交互是否都遵循未逐一确认。

### 动画/过渡（无 Framer Motion，全部 CSS/Tailwind + Radix data-state）

`package.json` 全文搜索 `framer-motion` **无匹配**。三层方案：

1. **`tw-animate-css`**（`package.json:426`）+ Radix 的 `data-[state=open|closed]` 属性驱动 Dialog/ContextMenu/Tooltip/Popover 进出场（`dialog.tsx:33-37,123-127`：`fade-in-0`/`zoom-in-99`/`slide-in-from-bottom-4` 等，进场 260ms、退场 200ms，统一 `motion-reduce:animate-none`）。
2. **手写 CSS `@keyframes`**：`src/renderer/assets/styles/animation.css` 的 `animation-shimmer`（3s 线性循环，文字渐变光泽扫过，用于 Topic 重命名加载态和工具调用占位文本 `PlaceholderShimmerText.tsx`）与 `animation-reveal`（0.5s，重命名刚完成时的"揭示"效果，`Topics.tsx:1634-1638` 消费）。
3. **纯 CSS transition**：折叠展开（Thinking 块、用户消息折叠）用 `hidden` 属性硬切换 + chevron 图标 `transition-transform duration-200`（`ThinkingBlock.tsx:134-138`、`MainTextBlock.tsx:244`）——内容本身没有高度动画，只有箭头旋转有过渡，"展开"在视觉上是瞬时的。消息栏悬停显隐、滚动到底按钮出现都是 `opacity`/`duration-150` 级简单 CSS transition（`MessageFrame.tsx:34,119`；`MessageVirtualList.tsx` 的 `ScrollToBottomButton`）。

### 桌面端集成（Electron）

- **托盘**：`TrayService.ts` 在 mac 上根据 `nativeTheme.shouldUseDarkColors` 切换亮/暗两套托盘图标（`:29`）；点击托盘图标行为受偏好 `feature.quick_assistant.click_tray_to_show` 控制——开则唤起 QuickAssistant 悬浮窗，关则唤起主窗口（`:61-71`）；托盘本身不显示未读消息数/流式状态角标（未检索到 `setBadgeCount`/`flashFrame`/`setOverlayIcon` 调用）。
- **系统通知**：`NotificationService`（主进程，`src/main/services/NotificationService.ts`）用 Electron 原生 `Notification` API，点击通知会 `showMainWindow()` 并广播 `notification.clicked`（`:14-17`）。渲染层 `notificationService.send()`（`src/renderer/services/notification/NotificationService.ts:10-24`）先查三个偏好开关（`assistant`/`backup`/`knowledge`）再决定是否真的调 IPC 发送。
- **一个值得记录的空路径**：偏好 `app.notification.assistant.enabled` 和对应设置项开关（`NotificationSettings.tsx:36-48`，"助手回复完成通知"）确实存在，但**全仓库检索不到任何一处 `notificationService.send({..., source: 'assistant'})` 调用**——实际发通知的三处调用点（`BackupService.ts` 七处、`useAppUpdateHandler.ts` 一处）分别用 `source: 'backup'` 和 `source: 'update'`。即"助手完成回复时弹系统通知"这个开关目前接不到任何触发点，是个用户能看到、能勾选、但不会生效的空挂钩（不同于代码里自己写 TODO 承认的 `update` 缺口，见 `NotificationService.ts:17-20`；`assistant` 这条连 TODO 都没提到，属于本次调查新发现）。
- **全局快捷键**：`ShortcutService.ts` 按**本地/全局分轨**注册——`global` 标记的仍走 `globalShortcut`（含失焦时的注册集），其余本地快捷键不再注册到系统，而是挂在窗口 `webContents.before-input-event`（含 `did-attach-webview` 挂上的 guest webview 输入）上按命令解析拦截（`ShortcutService.ts:123-196`），应用失焦时本地快捷键自然不生效；快捷键冲突（被其他应用占用）记录冲突集合并经 IPC 广播给渲染层展示提示（`:281-303` 附近）。另有标签页导航快捷键（`324f26f728`）。**未找到独立的"快捷键帮助面板/速查表"浮层**——只有"设置 > 快捷键"这一个静态配置页（`ShortcutSettings.tsx`），不存在按一个快捷键呼出速查列表的入口。

## 8. 设计取舍与已确认边界

- **弹窗无 host 时降级 resolve**：启动早期不挂起等待，直接以默认结果关闭并 warn。
- **`focusOnClose` 转义口子**：承认 Radix 默认焦点归还在"触发者已卸载"场景失效，业务侧显式指定落点。
- **Toast 单例不分叉**：宁可全局共享一个 store，避免命令入口与渲染 viewport 分离（"quickAssistant black-hole bug"）。
- **消息操作栏缺 aria-label**：默认渲染路径的图标按钮只靠视觉 Tooltip，读屏读到"button"无描述——覆盖面是复制/编辑/删除等高频动作。
- **"助手回复完成"通知是空开关**：偏好与设置项存在，全仓库无 `source: 'assistant'` 发送调用。
- **拖拽排序仅在助手分组模式可用**：时间分组语义上不可拖。
- **主题遵循 Shadcn 变量契约**：官方变量名无前缀转发 `--cs-*`，为第三方主题生态兼容。
- **折叠展开无高度动画**：`hidden` 硬切换 + 箭头旋转过渡，视觉瞬时。

## 9. 未验证事项

- 无 host 降级路径、160ms 防闪烁骨架的实际运行表现未实测。
- Session 列表拖拽排序是否存在于 `src/renderer/pages/agents` 未检索确认。
- Pyodide 代码执行的浏览器内性能与超时行为未实测。
- 无障碍结论基于静态代码，未做读屏实测；`prefers-reduced-motion` 在业务层滚动/淡入交互的覆盖情况未逐一确认。
- macOS 托盘图标切换、原生右键菜单（`native` 模式）的实际表现未运行验证。

## 10. 关键源码索引

`packages/ui/src/components/primitives/dialog.tsx`、`packages/ui/src/components/primitives/toast.tsx`、`packages/ui/src/services/popup/types.ts`、`src/renderer/services/popup/PopupService.ts`、`src/renderer/services/toast.ts`、`src/renderer/components/command/CommandMenus.tsx`、`src/main/services/ThemeService.ts`、`src/renderer/components/theme/ThemeProvider.tsx`（或等价路径）、`packages/ui/src/styles/shadcn.css`、`src/renderer/services/notification/NotificationService.ts`、`src/main/services/NotificationService.ts`、`src/main/services/TrayService.ts`、`src/main/services/ShortcutService.ts`、`src/renderer/components/chat/messages/layout/MessageListLoading.tsx`、`src/renderer/components/chat/resourceList/base/ConversationRowStatus.tsx`、`src/renderer/components/chat/resourceList/base/ResourceList.tsx`、`src/renderer/components/ImageViewer.tsx`、`src/renderer/components/chat/messages/CodeBlockView.tsx`（或等价路径）、`src/renderer/components/chat/messages/layout/NarrowLayout.tsx`、`src/renderer/assets/styles/animation.css`。
