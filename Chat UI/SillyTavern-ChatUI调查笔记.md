# SillyTavern Chat UI 调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`06bde939fb1e9c4c8d8641d810f0a916b5bce127`（分支：`release`）
>
> 调查方式：直接阅读源码（`index.html` 工作台结构与消息模板、`public/script.js` 的发送/停止/swipe/编辑事件绑定、`keyboard.js`/`a11y.js`、`action-loader.js`、`swipe-picker.js`、`welcome-screen.js`），并以 grep 核对触摸手势与 ARIA 覆盖范围
>
> 调查范围：聊天工作台的用户主链：页面结构与会话导航、现场恢复、Composer 与草稿、发送前配置、生成反馈与停止、消息操作与 swipe/分支工作流、多会话与群聊队列反馈、UI 状态所有权、键盘与焦点可用性；数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目；通用界面盘点（弹窗库、Toastr 全量、主题、动画、图片预览、扩展面板等）不属于本笔记正文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的聊天 UI 是"可变数组 + DOM 操作 + 扩展事件"的组合，用户主链上的工作流包括：

- **触摸 swipe 手势**：用户在消息区左右滑动时，`swiped-events` 库把触摸开始、移动、结束的轨迹合成为左右滑动事件，`public/scripts/RossAscends-mods.js:908-956` 收到事件后点击最后一条消息的可见 swipe 按钮。该行为由 `power_user.gestures` 控制，默认开启。
- 消息悬停后出现操作栏，提供复制、编辑、删除、隐藏、checkpoint、分支等动作；角色回复两侧的 `<` `>` 箭头用于切换 swipe 候选。Swipe Picker 是候选版本浏览器，也是"以某个候选为基础开分支"的唯一 UI 入口。
- 生成反馈走 **Action Loader**：`STOPPABLE` 模式的 toast 上直接带停止按钮，点击后调用 `stopGeneration()`；另有一个全局生成状态位 `document.body.dataset.generating`，CSS 据此禁用交互（`public/scripts/action-loader.js:186-196`；`public/script.js:7020, 7029`）。
- checkpoint 通过消息旁旗标打开（按住 Shift 点旗标是"再建一个新 checkpoint"），分支创建后立即跳转新聊天，回主线靠 `/checkpoint-exit`。
- 键盘可达性由两套自研机制支撑：`keyboard.js` 的 interactable 注册系统动态补 `tabindex`，并用 Enter 触发点击；`a11y.js` 给消息操作按钮、swipe 箭头、角色选择等关键控件注入 role 语义。读屏命名仍依赖 `title` 属性，aria-label 与 aria-labelledby 在源码中缺失。
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

- **工作台拓扑**：页面顶部是导航栏，中部为聊天消息区，底部固定输入区；角色与群组列表放在右侧抽屉，AI 响应配置等面板放在左侧抽屉。点击抽屉图标可展开或收起抽屉，也可将其 pin 住常驻（`public/index.html:72, 8071`；`public/script.js:10893-10926, 11110-11113`）。
- **消息显示模式**：界面提供气泡、统一、文档三种聊天呈现形态，对应 `chat_styles` 中的 DEFAULT、BUBBLES、DOCUMENT 三个取值；切换时给 body 加 `bubblechat` 类，形态变化由 CSS 完成（`public/scripts/power-user.js:102-106, 1050-1059`）。
- **多窗口/多标签页**：多个标签页之间没有同步，草稿、忙碌状态与活跃会话各自独立（见 8）；同时保存时，由保存端的完整性检查防止互相覆盖。
- 欢迎屏是首屏入口，展示最近聊天与置顶项（`welcome-screen.js`），之后的选择与切换都在角色或群组列表里完成。

## 2. 会话导航、搜索与现场恢复

- **切换**：点击角色卡片后，界面调用 `selectCharacterById` 完成切换；保存或生成尚未结束时，这次切换会被拒绝；群聊则通过 `select_group_chats` 进入聊天视图（`public/script.js:873-907, 11132-11134`；`public/scripts/group-chats.js:1802`）。
- **历史聊天弹窗**：点击历史聊天菜单项后，`displayPastChats` 打开弹窗并把焦点放到搜索框；列表由 `/api/chats/search` 返回，按最后消息时间倒序排列并高亮当前聊天。点击某个聊天块时，`bookmarks.js` 里的委托处理器用 loader 遮罩加载目标聊天（`public/script.js:8491-8570`；`public/scripts/bookmarks.js:685-720`）。
- **搜索**：弹窗内的搜索框带防抖，输入后触发服务端搜索（`public/script.js:8502-8510`，检索语义见会话与消息管理笔记 5）；欢迎屏本身没有搜索框。
- **新建聊天**：选择新建聊天后先弹出确认框，其中可勾选同时删除当前聊天，确认后由 `doNewChat` 执行（`public/script.js:10558-10587`，数据语义见会话与消息管理笔记 3）。
- **重命名/删除**：历史聊天弹窗里每行都带重命名、导出和删除按钮，删除前弹出确认框，操作期间用 loader 提示进度（模板 `#past_chat_template`，`public/script.js:11217-11266`）。
- **现场恢复**：聊天加载完成后自动把焦点移回输入框；草稿恢复见 3；没有角色时创建的临时聊天存放在 sessionStorage，切换会话时按需恢复。滚动位置、首屏 100 条等渲染层恢复在消息渲染器笔记（`public/script.js:1684, 1693, 7612-7618`；`public/scripts/chats.js:1857-1879`）。
- **checkpoint/branch 导航**：消息旁的旗标是 checkpoint 入口，点击打开已有 checkpoint，按住 Shift 点击则再建一个；另有建 checkpoint 与建分支两个按钮，回主线用 `/checkpoint-exit`，`/checkpoint-list` 列出全部 checkpoint 消息。界面没有树状导航（`public/scripts/bookmarks.js:312-326, 685-692, 722-734`）。

## 3. Composer、草稿、附件与快捷输入

- **Composer**：底部输入区由文本输入框、发送按钮、停止按钮和 STScript 的三个执行控制按钮（继续、暂停、停止）组成（`public/index.html:8071-8109`）。发送按钮通过互斥锁串行触发发送，同一时刻只允许一次发送流程（`public/script.js:11099-11102`）。
- **草稿**：草稿按用户句柄存进 localStorage，所有会话共用一份，键名为 `${handle}_userInput`；输入时防抖写入，启动或恢复聊天时回填。因此切换聊天不会更换草稿内容（`public/scripts/RossAscends-mods.js:450, 452-462, 464-469, 888-890, 906`）。
- **附件入口**：附件可以从文件选择器、剪贴板粘贴和拖入三个入口进来，三者都汇到同一个附件处理函数做合并与去重；拖放时的悬停效果由样式类控制。Data Bank 弹窗内的拖入会先弹出目标作用域选择器（`public/scripts/chats.js:1510, 2381-2419`；`public/scripts/dragdrop.js:75-102`，数据语义见会话与消息管理笔记 8）。
- **快捷输入**：输入以 `/` 开头时，整条消息交给 slash command 处理（见对话请求与上下文笔记 1）；Quick Reply 扩展把快捷按钮渲染进输入区，并注册 `makeFirst` 自动化钩子（`extensions/quick-reply/index.js:282, 292`）。

## 4. 发送前配置

- 用户可在右侧抽屉的 API 面板里选择模型并调整生成参数，切换 API 时由 `changeMainAPI` 渲染对应的设置块（`public/script.js:7697` 起）；角色侧面板另行提供系统提示词、上下文与输出 token 上限、Temperature 等字段（字段语义见 Agent 角色类目）。
- 聊天级操作集中在 `#options` 菜单，包含重新生成、继续、扮演、新建、历史等入口；生成期间这组按钮的状态由 `is_send_press` 与 `data-generating` 统一控制（`public/script.js:11521-11599`）。
- 这里的配置在下一次请求时生效；每次生成结束后，当次请求的构成会记录成 itemized prompt，点击消息上的 Prompt 按钮即可查看提示词与 token 分项（`public/scripts/itemized-prompts.js:344-350`）。

## 5. 发送、排队、流式反馈与停止

- **发送反馈**：点击发送后输入框立即清空，全局生成状态位置位，swipe 按钮隐藏并换成停止按钮。界面没有排队提示，同一会话已有请求在跑时，第二次发送会被 `is_send_press` 与 `swipeState` 直接拒绝（`public/script.js:1711-1713, 3469-3471, 4286, 4342-4343, 5277, 7029`）。
- **流式反馈**：生成时 token 直接写进占位消息的 DOM，`MESSAGE_RECEIVED` 与 `CHARACTER_MESSAGE_RENDERED` 只在流结束或出错时各触发一次（渲染机制在消息渲染器笔记）。
- **停止**：点击停止按钮或生成中按下 Escape 都走 `stopGeneration()`，Action Loader 的 `STOPPABLE` toast 停止按钮默认调用同一函数。这类 toast 不会自动消失（`timeOut: 0, extendedTimeOut: 0, tapToDismiss: false`），由调用方代码主动关闭。停止后已生成的那半截消息留在内存与 DOM 中，不写入磁盘文件（`public/script.js:12070-12072, 12280-12287`；`public/scripts/action-loader.js:186-204, 270-286`；执行语义见对话请求与上下文笔记 6）。
- **其它 loader 反馈**：聊天加载、聊天删除等操作也复用 Action Loader 的 toast 与遮罩，遮罩由阻塞计数控制显隐，同一时刻只有一层。生成期间的 toast 可以堆叠出现（`bookmarks.js:702-707`、`script.js:11221-11226`，机制在 `public/scripts/action-loader.js`）。
- **独立生成浮层**：`StreamingDisplay` 是在主聊天 DOM 之外弹出的悬浮通知，自带 Stop 按钮，目前只有 connection-manager 扩展的 `/profile-genstream` 命令使用它（`public/scripts/streaming-display.js`，全文 372 行；`extensions/connection-manager/index.js:581-586`）。

## 6. 消息操作、swipe 与版本导航

- **操作栏**：鼠标悬停在消息上时出现操作按钮区，直接可点的有更多菜单、checkpoint 旗标与编辑三个入口（模板 `public/index.html:7399-7427`）。
  - 更多菜单本身可展开，也能用 `power_user.expand_message_actions` 固定为常显。
  - 菜单内包含翻译、生图、朗读、Prompt 详情、隐藏/恢复、媒体列表与画廊切换、嵌入附件、Swipe Picker、建 checkpoint、建分支、复制。
- **编辑工作流**：点击编辑按钮进入编辑态，用 `this_edit_mes_id` 锁定当前消息并隐藏 swipe 按钮；编辑态下出现确认、复制为新消息、加 reasoning、删除、上移、下移、取消一组按钮，输入内容可选自动保存。确认后由 `messageEditDone` 重渲染并保存，编辑期间发送与继续生成都会被拒绝（`public/script.js:1707-1711, 8180-8238, 8337-8375, 11587-11590, 11800-11804, 11874-11933`）。
- **删除工作流**：删除按钮是否弹确认框由用户设置 `power_user.confirm_message_delete` 决定；删除最后一条非用户消息且它有多个候选时，可以只删当前这一版 swipe（`public/script.js:11922-11929`）。
  - `deleteMessage` 默认连带删除紧邻其前的工具调用系统消息，`/cut` 与 `/del` 可用 toolcalls 参数关掉这一连带行为（`public/script.js:1614-1700`；`public/scripts/power-user.js:2818-2890`）。
- **swipe 切换**：左右箭头只绑定在最后一条消息上，是否显示由 `refreshSwipeButtons` 判断，按纯净问候语常驻、划到底提示重新生成、全局隐藏类三种策略处理。旁边的候选计数同时是 Swipe Picker 的入口，移动端长按计数也能打开（`public/script.js:9190-9249, 11086-11087`；`public/scripts/swipe-picker.js:425-428, 437-443`）。
- **越界行为**：滑到候选末尾再继续滑时，`getOverswipeBehavior` 决定后续动作，可选重新生成、循环、纯净问候语或无操作四种模式，其中重新生成会产出新候选。swipe 进行期间 body 上的 `data-swiping` 置位，失败时自动回退到原候选（`public/script.js:9163-9181, 9984, 10014-10031, 10250-10260`）。模式取值为：

  ```
  REGENERATE / LOOP / PRISTINE_GREETING / NONE
  ```
- **Swipe Picker**：候选版本浏览器，打开后列出当前消息的全部候选，每项可以跳转到该版本、删除、复制，或直接以该候选为基础开一条分支。列表由 `openSwipePicker` 读取候选数组与元信息渲染，删除项带确认并重算下标，开分支按候选 id 调用 `branchChat`；这是"从某个候选开分支"的唯一 UI 入口，底层与 `/branch-create` 汇到 `bookmarks.js`（`public/scripts/swipe-picker.js:52-410, 387-390`，全文 444 行）。
- **触摸手势**：滑动事件库在 document 上监听触摸开始、移动与结束，合成左右滑动事件，再由 `public/scripts/RossAscends-mods.js:908-956` 处理。满足条件后触发最后一条消息当前可见的 swipe 按钮，切换对应候选。
  - 手势开关 `power_user.gestures` 默认开启；当前没有弹窗、触点落在聊天壳内且不处于编辑态时才响应。
  - 聊天壳同时包含消息区与输入区，结构见 `public/index.html:8080-8084`。事件库与开关默认值分别见 `public/lib/swiped-events.js:28-30`、`public/scripts/power-user.js:179`。
- **`/addswipe` 原位更新**：执行该命令不会重载整个聊天；它追加候选后直接更新候选数据、计数与按钮，切换模式仍走统一的 swipe 流程，消息元素的 DOM 身份保持不变（`public/scripts/slash-commands.js:4617-4680`）。

## 7. 多会话、多模型与后台生成

- **同一时刻只有一个活跃聊天**：在角色或群组列表点击即触发切换，当前聊天的保存尚未完成时，这次切换会被拒绝（`public/script.js:878-881`）。
- **群聊队列反馈**：`generateGroupWrapper` 逐成员生成时，若开启 `power_user.show_group_chat_queue`，成员列表上会显示排队序号。生成期间切换角色同样被拒绝（`public/scripts/group-chats.js:1044-1048, 1056-1058, 1072-1075`；`public/script.js:887-900`）。
- **后台生成**：生成任务没有跨会话的后台界面，脱离主聊天的反馈只有 `/profile-genstream` 打开的独立浮层（见 5），浮层上带 Stop 按钮。
- **运行标记**：全局状态由 body 上的 `data-generating` 与 `data-swiping` 两个标记表达，前者由 `deactivateSendButtons` 与 `activateSendButtons` 维护。两个标记都是页面级单一状态位，不区分具体消息（`public/script.js:7016-7030`）。

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

- **快捷键**：聊天主链的关键操作集中在 `RossAscends-mods.js:979-1282` 的键盘处理逻辑中，弹窗打开时整组快捷键暂时失效（993-996）。按键与行为对应如下：

| 按键 | 行为 |
|---|---|
| Enter | 按 `shouldSendOnEnter` 设置发送消息 |
| Ctrl+Shift+Up/Down | 跳到上下文行或消息底部 |
| Alt+Enter | 继续生成 |
| Ctrl+Enter | 编辑态下确认编辑；否则输入为空时重新生成（带"不再询问"确认选项），有输入时按发送逻辑发送 |
| ArrowLeft/ArrowRight | 输入框为空且焦点不在输入控件时，切换最后一条消息的 swipe，来源标记为 `SWIPE_SOURCE.KEYBOARD` |
| Ctrl+ArrowUp | 编辑最后一条用户消息 |
| ArrowUp | 编辑最后一条消息 |
| Escape | 逐层关闭弹窗或抽屉；编辑与生成过程中的 Escape 交给 `script.js:12266-12289` 处理 |

- **Tab/Enter 可达**：键盘框架维护一份 interactable 选择器白名单，覆盖消息操作按钮、swipe 箭头、swipe 面板、角色选择与聊天块等；MutationObserver 给新出现的元素补 `tabindex="0"`，document 上的 Enter 处理沿 DOM 向上找到最近的 interactable 并触发点击。带 disabled 或 not_focusable 类的元素会被整体移出焦点顺序。另有一处点击后把焦点送回输入框的处理 `S_TAPreviouslyFocused`（`public/scripts/keyboard.js`，全文 254 行；`public/script.js:11051-11068`）。
- **role 语义**：`a11y.js` 给菜单按钮、消息操作按钮、swipe 箭头、角色选择与 toast 注入 button、list、listitem、toolbar、tab、status 等 role 值，MutationObserver 持续应用到新节点，`initAccessibility` 在启动时调用一次（`public/scripts/a11y.js:63-85, 106-127`，全文 131 行；`public/script.js:781`）。
- **缺失部分**：`index.html` 中带 ARIA 前缀的只有装饰图标的 `aria-hidden` 一处，aria-label、aria-labelledby、focus trap 与 live region 都未使用，toast 的 `role="status"` 是唯一的状态语义来源；绝大多数控件由 div 或 i 图标元素构成，消息操作栏整排都是 div，可访问名称只能取 `title` 属性（`public/index.html:5733`）。
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
