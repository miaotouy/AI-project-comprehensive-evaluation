# SillyTavern Chat UI 调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：直接阅读源码（`index.html` 工作台结构与消息模板、`public/script.js` 的发送/停止/swipe/编辑事件绑定、`keyboard.js`/`a11y.js`、`action-loader.js`、`swipe-picker.js`、`welcome-screen.js`），并以 grep 核对触摸手势与 ARIA 覆盖范围
>
> 调查范围：聊天工作台的用户主链：页面结构与会话导航、现场恢复、Composer 与草稿、发送前配置、生成反馈与停止、消息操作与 swipe/分支工作流、多会话与群聊队列反馈、UI 状态所有权、键盘与焦点可用性；数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目；通用界面盘点（弹窗库、Toastr 全量、主题、动画、图片预览、扩展面板等）不属于本笔记正文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的聊天 UI 是"可变数组 + DOM 操作 + 扩展事件"的组合，用户主链上的工作流包括：

- **触摸 swipe 手势存在但受限**：通过 `swiped-events` 库（`public/lib/swiped-events.js`，用触摸开始/移动/结束合成左右滑动的自定义事件）实现，绑定在 `public/scripts/RossAscends-mods.js:908-956`，受 `power_user.gestures` 开关控制（默认开），只对"最后一条消息的可见 swipe 按钮"生效。
- 消息 hover 操作栏（复制/编辑/删除/隐藏/checkpoint/分支等）与角色回复的 `<` `>` 箭头 swipe 切换；Swipe Picker 是候选版本浏览器，也是"以某个候选为基础开分支"的唯一 UI 入口。
- 生成反馈走 **Action Loader**：`STOPPABLE` 模式的 toast 上直接带停止按钮（`action-loader.js:186-196`，默认调 `stopGeneration()`），另有 `document.body.dataset.generating` 全局状态位（`public/script.js:7020, 7029`）驱动 CSS 禁用交互。
- checkpoint 通过消息旁旗标打开（按住 Shift 点旗标是"再建一个新 checkpoint"），分支创建后立即跳转新聊天，回主线靠 `/checkpoint-exit`。
- 键盘可达性靠两套自研机制：`keyboard.js` 的 "interactable" 注册系统（动态补 `tabindex` + Enter 触发）与 `a11y.js` 的 role 属性注入（给消息操作按钮、swipe 箭头、角色选择等关键控件设按钮语义）；但 `aria-label`/`aria-labelledby` 仍然缺失，读屏命名依赖 `title` 属性。
- 发送框可被 slash command 短路（执行语义在对话请求与上下文笔记）；快捷键覆盖发送、继续生成、重新生成、swipe 切换与编辑等聊天关键路径。

## 工作台边界与用户主链

```text
进入（欢迎屏最近聊天 / 角色列表 / 群组列表）
  -> 会话导航：角色列表 selectCharacterById（script.js:873-907）、
     历史聊天弹窗 displayPastChats（8491-8519）、欢迎屏最近聊天（welcome-screen.js:763-817）
  -> 输入并发送（#send_textarea -> sendTextareaMessage，slash command 可短路；草稿按用户句柄存 localStorage）
  -> 生成反馈（#mes_stop 停止按钮 / Action Loader toast 可停止；data-generating 禁用交互）
  -> 角色回复：swipe 箭头（仅最后一条）/ 触摸手势（限最后一条）/ Swipe Picker（跳转、删除、复制、从候选开分支）
  -> 消息操作：复制、编辑（原地改候选）、删除（可只删 swipe）、隐藏/恢复、checkpoint 旗标、分支
  -> 快捷键：Enter 发送、Alt+Enter 继续、Ctrl+Enter 重新生成、ArrowLeft/Right 切 swipe 等
```

边界：`chat[]`/JSONL/checkpoint/branch/swipe 的数据语义在会话与消息管理；`Generate()` 的请求构建、slash command 拦截、正则与宏注入在对话请求与上下文；消息 DOM 渲染（首屏 100 条、`StreamingProcessor` 流式写 DOM、正则 `markdownOnly` 渲染层）在消息渲染器。本笔记不盘点弹窗系统、Toastr 全量调用、主题 token、动画参数等通用界面设施，只记录它们与聊天主链的交点。

## 1. 页面结构、导航与多窗口

- **工作台拓扑**：顶部导航栏 + 可折叠抽屉（drawer），聊天消息区 + 底部输入区（`public/index.html:8071`）。角色/群组列表在右侧抽屉（`public/script.js:11110-11113` 打开）；左侧抽屉（`index.html:72`）是 AI 响应配置等面板。抽屉由 `.drawer-icon` 切换并可 pin（`doNavbarIconClick`，10893-10926）。
- **消息显示模式**：`chat_styles.DEFAULT/BUBBLES/DOCUMENT`（`public/scripts/power-user.js:102-106`），切换时对 `body` 加 `bubblechat` 类（1050-1059）——"气泡/统一/文档"三种形态，属 CSS 样式切换。
- **多窗口/多标签页**：无跨窗口同步（草稿、busy、active session 各自独立，见 8）；防覆写靠保存端 integrity 检查。
- 欢迎屏是首屏入口：最近聊天 + 置顶（`welcome-screen.js`），后续导航在角色/群组列表内完成。

## 2. 会话导航、搜索与现场恢复

- **切换**：角色卡片点击后经 `selectCharacterById` 切换（873-907；绑定 11132-11134），保存中/生成中拒绝切换；群聊切到聊天视图 `select_group_chats`（`group-chats.js:1802`）。
- **历史聊天弹窗**：历史聊天菜单项 → `displayPastChats`（8491-8519）打开弹窗并聚焦搜索框（8513-8516）；列表来自 `/api/chats/search`（`displayChats` 8521-8570，按最后消息时间倒序，当前聊天高亮）；点击聊天块经 `initBookmarks` 的委托处理器用 loader 打开目标聊天（`public/scripts/bookmarks.js:685-720`）。
- **搜索**：弹窗内 `#select_chat_search` 防抖触发服务端搜索（8502-8510，语义见会话与消息管理笔记 5）；欢迎屏无搜索框。
- **新建聊天**：`option_start_new_chat` → 确认弹窗（含"同时删除当前聊天"勾选）→ `doNewChat`（10558-10587，数据语义见会话与消息管理笔记 3）。
- **重命名/删除**：弹窗内每个聊天有重命名、导出、删除按钮（模板 `#past_chat_template`），删除走确认弹窗 + loader 反馈（11217-11266）。
- **现场恢复**：加载完成后自动聚焦 `#send_textarea`（`getChat` 7612-7618）；草稿恢复见 3；"无角色临时聊天"在切换时经 sessionStorage 恢复（`chats.js:1857-1879`，调用点 `script.js:1684, 1693`）；渲染层恢复（滚动位置、首屏 100 条）在消息渲染器笔记。
- **checkpoint/branch 导航**：旗标 `.mes_bookmark`（Shift 点击=再建一个，否则打开已有，`bookmarks.js:685-692`）；建 checkpoint 与建分支按钮（722-734）；回主线 `/checkpoint-exit`（312-326）；`/checkpoint-list` 列出全部 checkpoint 消息。无树状导航 UI。

## 3. Composer、草稿、附件与快捷输入

- **Composer**（`index.html:8071-8109`）：输入框 `#send_textarea`、发送按钮 `#send_but`、停止按钮 `#mes_stop`、STScript 执行控制按钮（继续/暂停/停止三个）。发送按钮经互斥锁串行触发 `sendTextareaMessage`（11099-11102）。
- **草稿**：**按用户句柄全局保存**，不区分会话——localStorage key `${handle}_userInput`（`RossAscends-mods.js:450`），输入防抖写入（464-469，绑定 888-890），启动/恢复时回填（452-462, 906）。切换聊天不换草稿。
- **附件入口**：文件选择器、剪贴板粘贴（`chats.js:2381-2390`）、拖入（`DragAndDropHandler('#form_sheld')`，2392-2394，走同一 `handleFileAttach` 合并去重 2401-2419）；拖放悬停视觉由样式类驱动（`public/scripts/dragdrop.js:75-102`）。Data Bank 弹窗内的拖入会弹目标作用域选择器（`chats.js:1510` 附近，数据语义见会话与消息管理笔记 8）。
- **快捷输入**：slash command（输入以 `/` 开头整体劫持发送，见对话请求与上下文笔记 1）；Quick Reply 扩展把按钮渲染进输入区并注册 `makeFirst` 自动化钩子（`extensions/quick-reply/index.js:282, 292`）。

## 4. 发送前配置

- 模型/参数在右侧抽屉的 API 面板（`#rm_api_block`）与各 API 设置块（`changeMainAPI`，7697+）；角色侧面板可改系统提示词、上下文/输出 token、Temperature 等（角色实体字段，见 Agent 角色类目）。
- 聊天级快捷入口：`#options` 菜单（重新生成/继续/扮演/新建/历史等，11521-11599）；生成中的按钮组状态由 `is_send_press` + `data-generating` 统一控制。
- 配置作用于后续请求；当前请求的构成在生成后被记录为 itemized prompt（消息上的 Prompt 按钮可查看当次 prompt 与 token 分项，`itemized-prompts.js:344-350`）。

## 5. 发送、排队、流式反馈与停止

- **发送反馈**：点击后输入框清空（4342-4343）、全局生成状态位置位（7029）、swipe 按钮隐藏（4286）、停止按钮显示（`showStopButton` 3469-3471，调用点 5277）。**无排队提示**：同一会话的第二次发送直接被 `is_send_press`/`swipeState` 拒绝（`sendTextareaMessage` 1711-1713）。
- **流式反馈**：token 直接写入占位消息 DOM（渲染机制在消息渲染器笔记）；`MESSAGE_RECEIVED`/`CHARACTER_MESSAGE_RENDERED` 只在流结束或错误时触发一次。
- **停止**：点击停止按钮 → `stopGeneration()`（12070-12072）；Escape 在生成中触发同一路径（12280-12287）；Action Loader 的 `STOPPABLE` toast 停止按钮（`action-loader.js:186-196`）默认调 `stopGeneration()`（270-286）；此类 toast 不会自动消失（`timeOut: 0, extendedTimeOut: 0, tapToDismiss: false`，199-204），由代码收尾。停止后半截消息保留在内存与 DOM，不落盘（执行语义见对话请求与上下文笔记 6）。
- **其它 loader 反馈**：聊天加载（`bookmarks.js:702-707`）、聊天删除（`script.js:11221-11226`）等用 loader toast + 遮罩单例（`action-loader.js` 的阻塞计数与遮罩显隐）；生成中的 toast 可堆叠，遮罩只一个。
- **独立生成浮层**：`StreamingDisplay`（`public/scripts/streaming-display.js`，372 行，自带 Stop 按钮）是脱离主聊天 DOM 的悬浮通知，当前唯一使用者是 connection-manager 扩展的 `/profile-genstream` 命令（`extensions/connection-manager/index.js:581-586`）。

## 6. 消息操作、swipe 与版本导航

- **操作栏**（消息模板 `index.html:7399-7427`）：直接按钮区 = 更多菜单（`extraMesButtonsHint` 展开，可被 `power_user.expand_message_actions` 固定展开）、checkpoint 旗标、编辑；更多菜单内 = 翻译、生图、朗读、Prompt 详情、隐藏/恢复、媒体列表/画廊切换、嵌入附件、Swipe Picker、建 checkpoint、建分支、复制。
- **编辑工作流**：编辑按钮 → `messageEdit`（8180-8238，`this_edit_mes_id` 锁定、swipe 按钮隐藏）；编辑态按钮组 = 确认/复制为新消息/加 reasoning/删除/上移/下移/取消（11874-11933）；输入时可选自动保存（11800-11804）；确认后 `messageEditDone` 重渲染并保存（8337-8375）。编辑期间发送/继续被拒（1707-1711, 11587-11590）。
- **删除工作流**：`.mes_edit_delete` 按 `power_user.confirm_message_delete` 决定是否确认，最后一条非用户消息且有多个候选时可选"只删当前 swipe"（11922-11929）；`deleteMessage`（1618-1672）。
- **swipe 切换**：左右箭头只绑定在最后一条消息（11086-11087）；`refreshSwipeButtons` 决定可见性（`public/script.js:9190-9249`：纯净问候语常驻、划到底提示重新生成、全局隐藏类三种策略）；计数历史 `.swipes-counter` 同时是打开 Swipe Picker 的入口（`swipe-picker.js:428, 437-443`，移动端长按 425-426）。
- **越界行为**：`getOverswipeBehavior`（9163-9181）判定滑动越过末尾时的处理模式，`REGENERATE` 会触发新候选生成（10250-10260），另有循环、纯净问候语、无操作三种模式；swipe 期间 `document.body.dataset.swiping` 置位（9984），失败自动回退（`endSwipe(revert)` 10014-10031）。完整模式枚举：

  ```
  REGENERATE / LOOP / PRISTINE_GREETING / NONE
  ```
- **Swipe Picker**（`swipe-picker.js`，全文 444 行）：`openSwipePicker`（52-410）读当前消息的候选数组与元信息渲染滚动列表，每项可跳转（双击/Go）、删除（121-233，含确认与下标重算）、复制、**从这个候选开分支**（160-174 记录分支动作，387-390 按候选 id 调 `branchChat`）——这是"以某个候选为基础开分支"的唯一 UI 入口，底层与 `/branch-create` 汇到 `bookmarks.js`。
- **触摸手势**（已核实，非缺失）：`public/lib/swiped-events.js`（132 行）在 document 上监听触摸开始/移动/结束（28-30）合成左右滑动事件；`RossAscends-mods.js:908-956` 处理它们：`power_user.gestures` 开启（默认 true，`power-user.js:179`）、不在弹窗中、目标在输入区内、非编辑态时触发最后一条消息的可见 swipe 按钮点击。范围限制：只作用于最后一条消息，且要求其 swipe 按钮当前可见。

## 7. 多会话、多模型与后台生成

- **同一时刻只有一个活跃聊天**；角色/群组列表点击即切换，切换期间保存未完成会拒绝（878-881）。
- **群聊队列反馈**：`generateGroupWrapper` 逐成员生成时，开启 `power_user.show_group_chat_queue` 会在成员列表上显示排队序号（`group-chats.js:1044-1048, 1056-1058, 1072-1075`）；生成中角色切换被 `selectCharacterById` 的 `!is_send_press` 守卫拒绝（887-900）。
- **后台生成**：无跨会话后台任务 UI；`/profile-genstream` 的独立浮层（见 5）是唯一"脱离主聊天"的生成反馈，带 Stop 按钮。
- **运行标记**：全局 `data-generating` 由 `deactivateSendButtons`/`activateSendButtons`（7026-7030, 7016-7021）维护；swipe 期间 `data-swiping`。均为 body 级单一状态位，非消息级。

## 8. Chat UI 状态所有权与同步

| 状态 | 存储位置 | 生命周期 |
|---|---|---|
| 草稿文本 | localStorage（按用户句柄，`RossAscends-mods.js:450`） | 跨会话、跨刷新 |
| 置顶聊天 | accountStorage（`welcome-screen.js:101-138`） | 跨会话 |
| 最近聊天显示设置（数量/折叠） | accountStorage（`welcome-screen.js:729-735` 附近） | 跨会话 |
| 无角色临时聊天 | sessionStorage（`chats.js:1857-1879`） | 跨导航，不跨刷新 |
| itemized prompts / token 缓存 | IndexedDB（`itemized-prompts.js:15`） | 随聊天删除 |
| 生成锁/编辑锁 | 模块级 `is_send_press`/`swipeState`/`this_edit_mes_id` + body `data-generating`/`data-swiping` | 刷新即失 |
| 活跃会话指针 | 角色 `chat` 字段 / 群组 `chat_id`（服务端 JSON） | 持久 |

刷新/重连后：草稿与置顶恢复，聊天回到角色记录的文件；进行中的生成丢失（`beforeunload` 只 abort，12401-12407）；多标签页各自独立，靠保存端 integrity 检测冲突（会话与消息管理笔记 6）。

## 9. 键盘、焦点与关键路径可用性

- **快捷键**（`RossAscends-mods.js:979-1282`，弹窗打开时整体禁用 993-996）：
  - Enter 发送（999-1006，按 `shouldSendOnEnter`）；
  - Ctrl+Shift+Up/Down 跳到上下文行/底部（1015-1032）；
  - Alt+Enter 继续（1034-1041）；
  - Ctrl+Enter 确认编辑，否则重新生成（空输入，带"不再询问"确认选项）或按发送逻辑发送（1044-1099）；
  - 输入框空且未聚焦输入控件时 ArrowLeft/Right 切最后一条 swipe（1107-1136，`SWIPE_SOURCE.KEYBOARD`）；
  - Ctrl+ArrowUp 编辑最后一条用户消息（1139-1155）；ArrowUp 编辑最后一条消息（1157-1174）；
  - Escape 逐层关闭弹窗/抽屉（1176-1274，编辑与生成中的 Escape 让位给 `script.js:12266-12289`）。
- **Tab/Enter 可达**：`keyboard.js`（254 行）维护 interactable 选择器白名单（2-34，覆盖消息操作按钮、swipe 箭头、swipe 面板、角色选择、聊天块等），MutationObserver（46-58）给新元素补 `tabindex="0"`（121-159），document 级 Enter 沿 DOM 向上找 interactable 并触发点击（213-234）；`disabled`/`not_focusable` 类可整体移除焦点（138-157）。另有点击后焦点回送输入框的处理（`S_TAPreviouslyFocused`，11051-11068）。
- **role 语义**：`a11y.js`（131 行）给菜单按钮、消息操作按钮、swipe 箭头、角色选择、toast 等注入 `role="button"/"list"/"listitem"/"toolbar"/"tab"/"status"`（63-85），MutationObserver 持续应用（106-127），`initAccessibility` 在启动时调用（`script.js:781`）。
- **缺失部分**：`index.html` 中 `aria-` 仅 1 处（装饰图标 `aria-hidden`，5733 行），无 `aria-label`/`aria-labelledby`/focus trap/live region（toast 的 `role="status"` 除外）；绝大多数控件是 div/i 图标元素（如消息操作栏全部为 div），可访问名称只能依赖标题属性 `title`。
- 结论（静态代码扫描）：键盘主链（选择会话 → 输入 → 发送 → 停止 → 消息操作 → swipe）有专门框架保障 Tab 可达与 Enter 触发，role 语义部分注入；读屏命名与焦点管理不完整，实际体验未运行验证。

## 10. 设计取舍与已确认边界

- **触摸 swipe 存在但作用面窄**：手势只触发最后一条消息的可见箭头按钮，且受 `power_user.gestures` 开关约束；功能名"swipe"的桌面主体交互仍是点按钮。
- **键盘框架补偿语义缺失**：Tab/Enter 可达由自研框架保障，role 由 a11y.js 补充，但命名/焦点陷阱/动态区域缺失（9）。
- **生成反馈分散**：主聊天流式反馈在消息 DOM（渲染器），全局状态位 + Action Loader toast 承担"正在处理"的通用反馈（5）；`/profile-genstream` 走独立浮层。
- **草稿是全局的**：按用户句柄存 localStorage，不按会话区分——切聊天不丢输入，但也无法保留多份会话草稿。
- **swipe 按钮与计数器是渲染层职责**：`refreshSwipeButtons` 的全量 DOM 扫描、`mesid` 连续反推等实现细节在消息渲染器笔记，本笔记只记录用户可观察的工作流与可用性结论。
- **本笔记不包含通用界面盘点**：弹窗系统、Toastr 全量盘点、主题、响应式断点、动画参数、图片预览、扩展面板结构等不属于 Chat UI 类目正文，仅在涉及聊天主链处（loader toast、拖放反馈、弹窗返回定位）记录交点。

## 11. 未验证事项

- 屏幕阅读器（NVDA/VoiceOver 等）实际体验未做运行验证（第 9 节结论基于静态代码扫描与 grep 统计）。
- 触摸手势在真实移动设备上的灵敏度、与编辑态/滚动冲突未实机验证；`power_user.gestures` 默认开启的行为只在代码层确认。
- 多标签页同时编辑同一聊天时的保存冲突体验未实测（integrity 弹窗路径为代码确认）。
- 长聊天下 swipe 高频操作与 `refreshSwipeButtons` 的卡顿风险未做性能实测（属渲染侧，见消息渲染器笔记）。
- 键盘焦点顺序与 Escape 逐层关闭的实际行为未做浏览器手动验证。

## 12. 关键源码索引

- `public/scripts/action-loader.js`：`STOPPABLE` 模式与停止按钮（29, 170-205）；`stop()`（270-286）；遮罩（505-607）
- `public/scripts/swipe-picker.js`：`openSwipePicker`（52-410）；`initSwipePicker`（412-443）；分支联动（387-390）
- `public/script.js`：`swipe()` 主流程（9894-10366）；`getOverswipeBehavior`（9163-9181）；`refreshSwipeButtons`/`hideSwipeButtons`（9190-9270）；`stopGeneration`（5548-5559）；`deactivate/activateSendButtons`（7016-7030）；`displayPastChats`/`displayChats`（8491-8570）；`messageEdit`/`messageEditDone`/`updateMessage`（8080-8375）；编辑与删除按钮绑定（11874-11933）
- `public/scripts/bookmarks.js`：`initBookmarks` 旗标与聊天块点击（680-737）；`backToMainChat`（312-326）
- `public/scripts/keyboard.js`（全文 254 行）；`public/scripts/a11y.js`（全文 131 行）
- `public/scripts/RossAscends-mods.js`：触摸手势（908-956）；快捷键主逻辑（979-1282）；草稿存取（450-469）
- `public/scripts/welcome-screen.js`：最近聊天与置顶（83-202, 763-817）
- `public/lib/swiped-events.js`（全文 132 行）；`public/scripts/streaming-display.js`（全文 372 行）
