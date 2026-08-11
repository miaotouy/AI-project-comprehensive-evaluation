# SillyTavern Chat UI 调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：从 [`../Chat/SillyTavern-Chat调查笔记.md`](../Chat/SillyTavern-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码；通用界面盘点（弹窗系统、Toastr、主题、响应式断点、动画、图片预览、扩展面板）保留于源文件第 13 节，待可选界面专题承接
>
> 调查范围：聊天工作台的用户工作流：消息操作与 swipe 交互、生成反馈与停止、快捷键、键盘可达性、导航与现场恢复；数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的聊天 UI 是"可变数组 + DOM 操作 + 扩展事件"的组合，用户能直接操作的聊天工作流包括：

- 消息 hover 操作栏（复制/编辑/删除等）与角色回复的 **swipe 左右切换**；Swipe Picker 是候选版本浏览器，也是"以某个候选为基础开分支"的唯一 UI 入口。
- **"swipe"功能并没有手指滑动的手势**：桌面与移动端都是点击消息下方的 `<` `>` 箭头按钮；全仓库未找到消息上的 `touchstart/touchmove/touchend` 手势实现（已核实，是缺失而非猜测）。
- 生成反馈走 **Action Loader**：生成中的 toast 上直接带停止按钮（`STOPPABLE` 模式），另有 `document.body.dataset.generating` 全局状态位驱动 CSS 禁用交互。
- checkpoint 通过消息旁旗标打开（按住 Shift 点旗标是"再建一个新 checkpoint"），分支创建后立即跳转新聊天，回到主聊天靠 `/checkpoint-exit`。
- 键盘可达性靠一套自研的 `keyboard.js` "interactable" 注册系统动态补 `tabindex` + Enter 触发，但屏幕阅读器语义（ARIA）几乎缺失。
- 发送框可被 slash command 短路（执行语义在对话请求与上下文笔记）；快捷键覆盖发送、继续生成、重新生成、swipe 切换与编辑等聊天关键路径。

## 工作台边界与用户主链

```text
进入角色/群聊聊天（Agent/群组列表点击切换）
  -> 输入并发送（slash command 可短路）
  -> 生成反馈（Action Loader toast 可停止；data-generating 禁用交互）
  -> 角色回复：swipe 左右切换 / Swipe Picker（跳转、删除、复制、从候选开分支）
  -> 消息操作：复制、编辑、删除、隐藏
  -> checkpoint 旗标（打开快照聊天）/ branch（创建并跳转）/ /checkpoint-exit 返回主线
  -> 快捷键：Alt+Enter 继续、Ctrl+Enter 重生成、ArrowLeft/Right 切 swipe 等
```

边界：`chat[]`/JSONL/checkpoint/branch/swipe 的数据语义在会话与消息管理；`Generate()` 的请求构建与 slash command 拦截在对话请求与上下文；消息 DOM 渲染（首屏 100 条、`StreamingProcessor`、流式淡入、正则渲染层）在消息渲染器（`../消息渲染器/SillyTavern-消息渲染调查笔记.md`）。本笔记不重复弹窗库、Toastr、主题、响应式断点等通用界面盘点（保留于源文件第 13 节）。

## 1. 页面结构、导航与多窗口

- 聊天主界面为消息区 + 输入框（`#send_textarea`）+ 侧栏角色/群组列表；标题栏有气泡/统一/刊物（presentation mode）三种显示模式。
- Agent/群组列表点击即切换聊天；Agent 设置面板可改名、头像、系统提示词、模型、Temperature、上下文/输出 Token、Top P/Top K、流式开关和 TTS。
- Quick Reply、slash command、预设/模型选择器提供运行中快速切换。

## 2. 会话导航与现场恢复

- checkpoint：创建后不自动跳转，用户点击消息旁的旗标才打开快照聊天（`initBookmarks()` 里 `.mes_bookmark` 点击处理，`bookmarks.js:685-720`）；**按住 Shift 点旗标是"再建一个新 checkpoint"**（覆盖旧 `bookmark_link`），否则打开已有的。创建后 toast 提示"Click the flag icon next to the message to open the checkpoint chat"。
- branch：创建成功后**立即跳转**新聊天（执行语义见会话与消息管理笔记 5.2）。
- 返回主线：`/checkpoint-exit`（`backToMainChat`，`bookmarks.js:312-326`）依赖 `chat_metadata.main_chat` 手动切回主聊天文件——没有"树状导航 UI"。
- `/checkpoint-list` slash command 列出全聊天范围内带 checkpoint 的消息（数据侧是整数组扫描，见会话与消息管理笔记 5.1）。

## 3. 消息操作与 swipe 工作流

### 3.1 消息操作栏

消息 hover 操作栏提供复制、编辑、删除、编辑目标上移/下移、复制当前编辑消息为新消息、取消和确认编辑；操作栏可展开或自动收起。助手消息有 swipe 左右和历史计数器，Swipe Picker 可选历史候选；代码块有 Copy code，附件/媒体支持预览、编辑和删除。隐藏/恢复走 `hideChatMessageRange`（数据语义见会话与消息管理笔记 4.1）。

### 3.2 Swipe 工作流

- 消息下方 `<` `>` 箭头按钮（`.swipe_left`/`.swipe_right`）切换候选版本，历史计数器显示"第几个/共几个"。
- **触摸手势缺失**：全仓库搜索 swipe 相关代码 + `touchstart`/`touchmove`/`touchend` 事件绑定，**没有找到"在消息上左右滑动手指触发 swipe 切换候选回复"的手势实现**——无论桌面还是移动端都是点按钮（已核实）。
- `getOverswipeBehavior()`（`script.js:9163-9181`）状态机决定"划到底之后"的行为：`PRISTINE_GREETING`（纯净问候语循环切备选开场白，chevron 常驻）、`REGENERATE`（角色消息划到底触发重新生成）、`LOOP`（回到第一个候选）、`NONE`（不可 swipe）；`refreshSwipeButtons` 据此显示"划到底了会重新生成"的视觉提示。
- 流式生成中会**主动隐藏 swipe 按钮**（`onStartStreaming` 里 `hideSwipeButtons({hideCounters:true})`），防止用户在流没结束时误触 swipe。

### 3.3 Swipe Picker（`swipe-picker.js`，全文已读）

UI 层的候选浏览器，不是新的存储结构——`openSwipePicker(messageId)`（L52-410）直接读 `chat[messageId].swipes`/`swipe_info` 渲染成可滚动列表，每项可以：

- **跳转**（双击或点 Go，走 `swipe(null, direction, {source: SWIPE_SOURCE.SWIPE_PICKER, forceMesId, forceSwipeId})`）；
- **删除**（`deleteSwipe`，数据语义见会话与消息管理笔记 1.1）；
- **复制文本**；
- **从这个候选创建分支**（`swipe-picker.js:160-174`：点击分支按钮记录 `branchActionSwipeId = index` 并关闭弹窗，弹窗关闭后 `await branchChat(messageId, { swipeId: branchActionSwipeId })`，`swipe-picker.js:387-390`）——这是"以某个 swipe 为基础开分支"在 UI 上唯一的入口，底层调用链和 slash command `/branch-create` 一致，都汇到 `bookmarks.js` 的 `createBranch`。

## 4. 生成反馈与停止

- **Action Loader 的生成中反馈**（`public/scripts/action-loader.js`，全文 617 行）：`STOPPABLE` 模式的 toast 上带停止按钮（`fa-stop-circle`），点击调用 `onStop` 回调或默认的 `stopGeneration()`（`action-loader.js:270-286`）——"生成中"这个最常见的 loading 状态，用户可以直接从 toast 上点停止，不需要找专门的停止按钮。该类 loading toast 不会自动消失（`timeOut: 0, extendedTimeOut: 0, tapToDismiss: false`，`action-loader.js:199-204`），只能通过代码结束。遮罩单例、toast 可堆叠（多个耗时操作只显示一个遮罩，但各有独立 toast）。
- **全局生成状态位**：`document.body.dataset.generating`（`script.js:7020, 7029`）是全局单一状态位，CSS 用 `body[data-generating="true"]` 禁用一批元素交互（`style.css:4569`）——不是逐条消息级别。
- **主聊天流式反馈**：流式 token 直接写入占位消息的 DOM（渲染机制在消息渲染器笔记）；流结束后才触发 `CHARACTER_MESSAGE_RENDERED`/`MESSAGE_RECEIVED` 事件。
- **slash command 场景的浮层**：`streaming-display.js` 是独立的悬浮通知组件（toast-like），仅 `/profile-genstream` 等 slash command 发起独立生成时使用，附带 Stop 按钮，脱离 `chat[]` 与主聊天 DOM（渲染细节在消息渲染器笔记）。

## 5. 快捷键（聊天关键路径）

`send_textarea` 按设置决定 Enter 是否发送，Shift+Enter 换行；**Alt+Enter 继续生成**；**Ctrl+Enter 在输入为空时重新生成最后回复**，在有文本时按发送逻辑处理，编辑态则确认编辑。Ctrl+Shift+Up 跳到上下文行，Ctrl+Shift+Down 回到底部；空输入时 ArrowUp 编辑最后消息，Ctrl+ArrowUp 优先编辑最后一条用户消息，未聚焦输入框时 **ArrowLeft/Right 切换最后一条 swipe**；Escape 关闭/提交编辑，生成中停止。

## 6. 键盘可达性与无障碍现状

- **`keyboard.js`（全文 254 行）"interactable" 注册系统**：维护一个 CSS 选择器白名单（`interactableSelectors`，`keyboard.js:2-28`，涵盖 `.menu_button`、`.mes_buttons .mes_button`、`.swipe_left/.swipe_right`、角色卡片等近 30 类元素），用 `MutationObserver` 监听 DOM 变化（`:46-58`），给匹配到的元素动态加 `tabindex="0"`（`makeKeyboardInteractable`，`:121-159`），并在 `document` 级别监听 `keydown`，收到 Enter 键就沿 DOM 树向上找最近的 interactable 元素并 `.click()`（`handleGlobalKeyDown`，`:213-234`）——**解决了 Tab 键可达和 Enter 触发，但没有解决屏幕阅读器语义**。
- **ARIA 几乎缺失**：对 `public/index.html` grep `aria-` 只有 1 处命中（装饰性图标 `aria-hidden`）；`public/scripts/*.js` 里 3 处 `role=` 都是把业务数据值写进 HTML 属性，不是无障碍语义。屏幕阅读器遇到 `<div tabindex="0">` 通常只能读出文字内容或完全跳过（纯图标按钮）。
- **绝大多数"按钮"是 `<div>`/`<i>` 图标元素**（`index.html` 245 处 `.menu_button` 相关 `<div>`），原生 `<button>` 极少；`title` 属性大量存在（595 处）但不能等价于 `aria-label`。
- 结论（静态代码扫描，未做读屏软件实测）：**键盘可用性中等（有专门框架保障 Tab/Enter），屏幕阅读器语义几乎没有**。

## 7. 附件拖入交点

- 消息输入框拖入文件（`chats.js:2392-2394`，`#form_sheld` 选择器）直接走 `handleFileAttach`，等同于用文件选择器上传附件；
- 附件弹窗内拖入（`chats.js:1510`，Data Bank / Attachment Manager）会弹出目标选择器让用户选挂到全局/角色/聊天哪个作用域（数据语义见会话与消息管理笔记 4.3）。
- 拖放悬停视觉反馈由统一 CSS class `drop_target`/`dragover` 驱动（`dragdrop.js:75, 90, 102`）。

## 8. 设计取舍与已确认边界

- **触摸 swipe 未实现**：功能名叫 swipe，实际交互是点按钮（3.2），移动端无滑动手势。
- **键盘框架补偿语义缺失**：Tab/Enter 可达由自研框架保障，ARIA 语义几乎缺失（6）。
- **生成反馈分散**：主聊天流式反馈在消息 DOM（渲染器），全局状态位 + Action Loader toast 承担"正在处理"的通用反馈（4）。
- **swipe 按钮与计数器是渲染层职责**：`refreshSwipeButtons` 的全量 DOM 扫描、`mesid` 连续反推等实现细节在消息渲染器笔记，本笔记只记录用户可观察的工作流与可用性结论。
- **通用界面盘点保留于源文件**：弹窗系统（`popup.js`）、Toastr、主题（CSS 变量 + 服务端存储）、响应式断点、动画参数、图片预览、扩展面板结构与交互保留在 `../Chat/SillyTavern-Chat调查笔记.md` 第 13 节，待可选界面专题承接。

## 9. 未验证事项

- 屏幕阅读器（NVDA/VoiceOver 等）实际体验未做运行时验证（6 的结论基于静态代码扫描）。
- 长聊天下 swipe 高频操作的卡顿风险未做性能实测（属渲染侧，见消息渲染器笔记）。
- 移动端触摸体验与 iOS PWA 场景未实机验证。

## 10. 关键源码索引

- `public/scripts/action-loader.js`（生成中 toast 与停止按钮）
- `public/scripts/swipe-picker.js`（全文件 1-445，分支联动 387-390）
- `public/script.js`：`swipe()` 主流程（9894-10110+）；`getOverswipeBehavior`/`refreshSwipeButtons`（9163-9249）；`onStartStreaming`（3562-3582）；`data-generating` 状态位（7020, 7029）
- `public/scripts/bookmarks.js`：`initBookmarks` 旗标事件绑定（680-737）
- `public/scripts/keyboard.js`（全文件 254 行）
- `public/scripts/dragdrop.js`（全文件 107 行）
- `public/scripts/chats.js`（2392-2394 输入框拖入；1510 附件弹窗拖入）
