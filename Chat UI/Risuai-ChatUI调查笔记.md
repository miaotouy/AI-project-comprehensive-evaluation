# Risuai Chat UI 调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
>
> 调查方式：直接阅读源码（`App.svelte` 的条件渲染工作台、`ChatScreens/` 系列组件的 Composer 与消息操作、`SideBars/Sidebar.svelte` 与 `SideChatList.svelte` 的会话导航、`process/index.svelte.ts` 的发送/流式/中止链路、`globalApi.svelte.ts` 的会话切换与保存、`hotkey.ts`、`sync/multiuser.ts`、`Mobile/` 组件），并以 grep 核对草稿持久化、消息搜索入口、停止与重试的实际调用链；本次未运行应用
>
> 调查范围：聊天工作台用户主链：页面结构与会话导航、现场恢复、Composer 与草稿、发送前配置可见性、生成状态反馈与停止、消息操作与分支导航、多会话与多用户房间、UI 状态所有权与跨窗口同步、键盘与焦点可用性；消息内容渲染（`ChatBody.svelte`、解析器）、请求构建与执行语义、会话数据模型与导出分别归入消息渲染器、对话请求与上下文、会话与消息管理、对话导出与分享类目；通用界面盘点（全量 Modal、Toast/Alert 类型、主题 token、动画参数、设置页完整清单）不属于本笔记正文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **工作台是"图标栏 + 侧栏面板 + 主题化聊天面"的组合**：应用没有传统路由，根组件在设置页、移动端界面、首页与聊天面之间做条件渲染（`src/App.svelte:208-236`）；聊天面内嵌会话列表侧栏、角色配置、DevTool 与快捷设置四个面板，聊天区同时承载输入区与消息流。
- **会话以角色为单位组织**：角色是会话的容器，每个角色持有一组聊天记录与当前会话指针 `chatPage`；生成过程中点击其他角色会被 `changeChar` 守卫拒绝；应用启动时把活跃角色 `selectedCharID` 重置为 -1，因此刷新后总是回到首页，"恢复现场"就是重新点一次角色图标，聊天指针随角色数据一起持久化。
- **草稿是单一共享缓冲**：输入文本是聊天面组件（`DefaultChatScreen.svelte`）的组件级状态，不按会话区分，也不写入持久化存储；切换角色或会话不会丢失输入，刷新页面才会清空。
- **生成全程串行，没有排队界面**：发送时全局锁 `doingChat` 置位，发送按钮原位换成停止按钮；停止动作对 `AbortController` 调用 abort，通过 fetch 的 signal 取消当前流，半截回复留在内存与消息流中；群聊、自动续写与触发器重发都沿同一个信号顺序递归执行。
- **reroll/swipe 依赖内存快照**：左右箭头渲染在每条消息上，实际总是作用于会话尾部；候选保存在组件内的快照栈与生成候选文本表中，刷新即失；选中的正文会写回消息并随保存落盘，问候语轮换另保存索引。
- **跨窗口/跨设备**：同源多标签页用 BroadcastChannel 做保存冲突检测，冲突后提示并整页重载；WebRTC 多用户房间同步聊天数据并互斥生成权限，草稿、滚动与生成状态留在各端。

## 工作台边界与用户主链

```text
启动（bootstrap：加载 database.bin -> 首页 MainMenu，selectedCharID = -1）
  -> 会话导航：侧栏角色图标 changeChar（characters.ts:876，生成中拒绝）或角色网格/移动端搜索
  -> 侧栏面板 SideChatList：新建/切换/重命名/复制/删除/拖拽排序/文件夹；ChatList 弹窗同样可切换
  -> 输入并发送：textarea（messageInput）-> sendMain -> sendChatMain -> sendChat（process/index.svelte.ts:99）
  -> 生成反馈：发送按钮原位变停止按钮（loadmove 四色 spinner，chatProcessStage 0-4）-> abortChat
  -> 角色回复：reroll 左右箭头（尾操作）/ 首条消息问候语轮换 / 书签跳转 / 分支回链
  -> 消息操作：复制、编辑（原地 textarea + 局部编辑）、删除、翻译、TTS、禁用、分支
  -> 离开与恢复：菜单"聊天列表"或侧栏切换；刷新后回首页，聊天指针随角色数据恢复
```

边界：`sendChat` 的请求构建、记忆、触发器与落盘语义归对话请求与上下文、会话与消息管理；消息文本渲染（`ChatBody.svelte`、`Chats.svelte` 的增量挂载、流式优化显示）归消息渲染器；聊天导出/截图归对话导出与分享。本笔记只记录与聊天主链的交点，不盘点弹窗系统、Alert 全部类型与主题设施。

## 1. 页面结构、导航与多窗口

- **顶层分支**：根组件按固定顺序判定七个界面状态，命中第一个成立的状态即停止，顺序为加载中、自定义 GUI 菜单、首次设置、设置页、移动端界面、角色网格，均不命中时进入聊天面（`App.svelte:196-236`）。欢迎引导、设置面板与移动端布局分别由 `WelcomeRisu`、`settingsOpen` 与 `MobileGUI` 承担，聊天面由侧栏与 `ChatScreen` 组合而成。
- 所有模态类组件（Alert、预设、persona、书签列表、Hypa 记忆、EasyPanel 等）平铺在根元素末尾，按各自的开关状态显隐，因此不参与聊天面的布局计算。
- **侧栏**（`SideBars/Sidebar.svelte`）：左侧竖排图标栏排列角色头像、文件夹与新建按钮，支持 HTML5 拖拽排序与归组；右侧是可折叠面板，面板内容由四个开关决定，依次对应会话列表、角色配置、DevTool 与快捷设置（`sideBarMode`、`botMakerMode`、`devTool`、`QuickSettings.open`）。图标栏在 `menuSideBar` 关闭时仍可用，设置、首页、Playground 与角色网格入口收在汉堡菜单内。
- **聊天面**：主题配置决定 classic、waifu、waifuMobile 三种布局，聊天主体统一是 `DefaultChatScreen`。waifu 与 waifuMobile 使用角色立绘组件，classic 使用可拖动立绘框；它们按当前角色及角色显示设置出现，背景图也由相应布局装配。分支与显示条件见 `src/lib/ChatScreens/ChatScreen.svelte:35-81`。
- 左上角的箭头按钮控制侧栏折叠与展开；展开状态在动画结束后统一更新，按钮组件为 `SideBarArrow`，状态存在 `sideBarStore` 与 `sideBarClosing`。
- **多窗口**：本次未找到任何跨窗口 UI 状态同步；同源多标签页依赖保存侧的 BroadcastChannel 冲突检测（见第 8 节），没有草稿、busy、活跃会话的跨窗口共享。

## 2. 会话列表、搜索与现场恢复

- **切换角色**：点击侧栏头像即进入角色切换流程，生成过程中该请求被直接拒绝；角色带冷存储标记时，先取回冷存储数据再完成切换（`changeChar`，见 `src/ts/characters.ts:876-898`）。
- **角色级快捷键**：Ctrl+[ 与 Ctrl+] 按名称顺序切换到相邻角色，Ctrl+G 把侧栏滚动到当前角色（`hotkey.ts:92-123`）。
- **会话列表**（`SideBars/SideChatList.svelte`）：顶部"新建聊天"按钮直接插入一个空会话并跳到第 0 项；每个会话项提供重命名（进入编辑模式）、复制、导出、删除与更多菜单（复制、绑定 persona、创建多用户房间），复制时由 `createChatCopyName` 自动生成编号，删除需要确认且仅剩一个会话时拒绝。列表用 SortableJS 支持会话级与文件夹级拖拽排序，排序结果写回角色的 `chats` 数组并保持当前页指针。
- **会话文件夹**：`chatFolders` 数组中的文件夹可折叠、改色、重命名与删除；创建分支时若开启 `createFolderOnBranch`，会自动建一个 "Branches of X" 文件夹收纳分支会话（`Chat.svelte:834-843`）。置顶与未读标记功能本次未找到。
- **第二个会话入口**：聊天菜单（输入区右侧按钮展开）内的"聊天列表"打开一个精简的会话弹窗（`Others/ChatList.svelte`），功能是侧栏会话列表的子集：切换、导出、删除、新建与导入；入口受 `showMenuChatList` 开关控制。
- **搜索**：角色名搜索有两处入口，桌面角色网格的搜索框按名称过滤，移动端头部的搜索输入把关键字写入 `MobileSearch` 后过滤角色列表；**会话列表搜索与消息内容搜索本次未找到 UI 入口**，`v2QuickSearchChat` 属于触发器系统的数据查询，与搜索界面无关。
- **现场恢复**：启动流程把活跃角色重置为 -1（`bootstrap.ts:252`），因此刷新后固定回到首页，不会自动打开上次的角色；会话指针 `chatPage` 作为角色数据的一部分被增量保存，重新选中该角色就回到上次的会话。消息区按页渲染，初始与追加条数均可配置，默认分别为 30 条与 15 条，取值规则见 `src/ts/chatLoadPages.ts:1-22`；同一角色内切换会话时，用上次会话 id 判定新消息是否来自同一会话，只有同源时才自动滚动。书签跳转与分支回跳（见第 6 节）会临时拉长渲染页数，并滚动高亮目标消息。

## 3. Composer、草稿、附件与快捷输入

- **Composer 布局**：文本域、发送（或停止）按钮与菜单按钮排成一行，开启 `fixedChatTextarea` 时整行吸附在底部（`src/lib/ChatScreens/DefaultChatScreen.svelte:586-727`）。
- 输入行下方的同一列依次堆叠粘贴图片预览、自动建议、翻译输入框、贴纸选择与插件面板，其中贴纸选择来自 `AssetInput`，插件面板由 `chatPanelStore` 提供。
- **草稿**：输入文本 `messageInput` 是 `DefaultChatScreen` 的组件级 `$state`（`DefaultChatScreen.svelte:44`）。切换角色或会话时聊天面组件不会重新挂载，因此这份草稿是**整个工作台共享的单缓冲**：换角色不丢，多个会话共用同一份输入；除插件沙箱外，源码中未发现把输入内容写入 localStorage 或 sessionStorage 的路径（grep 依据），刷新即失。
- **附件入口**：剪贴板粘贴的图片经 `postChatFile` 拆成 inlay 资产引用（文件预览卡，可逐个移除）或 `{{file::name::data}}` 形式的文本引用，聊天菜单"上传文件"走同一条路径；贴纸面板则从角色附加资产里选择并插入占位语法（`DefaultChatScreen.svelte:615-653`）。
- **应用级拖放**：根元素接收角色卡、预设与模块的拖入导入，与 Composer 的附件路径互不相干，靠 `dragTypes.ts` 里的自定义 MIME 类型区分内部拖拽与外部文件（`src/App.svelte:68-101`）。
- **命令与建议**：输入以 / 开头时，发送入口先交给 `processMultiCommand` 执行，命中后不再发送（`process/command.ts`）；自动建议由 `Suggestion.svelte` 调用子模型，基于最近 10 条消息生成候选并按会话存入 `chat.suggestMessages`，点击即填入输入框，尾缀清理可以关闭。
- **翻译输入框**（`useAutoTranslateInput`）提供"先输入原文、翻译后发送"的双文本域模式；@提及、变量补全这类输入辅助本次未找到。
- **空消息处理**：既没有附件、输入框也为空时，是否仍然推送一条 `*says nothing*` 用户消息由 `useSayNothing` 开关决定。

## 4. 发送前配置

- **作用域分层且可辨认**：参数按作用范围分三层。
  - 全局层：模型、温度、上下文与回复 token 等参数，入口是设置页与侧栏快捷设置（`QuickSettingsGUI.svelte` 的 BotSettings、OtherBotSettings、ModuleSettings 三个页签）。
  - 角色层：系统提示、触发器等配置放在侧栏角色面板（`CharConfig`）。
  - 会话层：只保留少数绑定字段（bindedPersona、modules、suggestMessages）与 Toggles 里的内存开关，开关值写入 `globalChatVariables["toggle_*"]`。
- **作用时点**：三层配置都在下一次请求时生效——`sendChat` 在请求开始前快照 preset 与 toggle 状态，写入该次消息的 `promptInfo`。
- **聊天内的发送前开关**：输入区右侧菜单集中了与当前对话相关的开关与动作（`DefaultChatScreen.svelte:895-1046`），包括：
  - 自动翻译输入、自动建议
  - jailbreak 相关 toggle，配置在侧栏 `Toggles.svelte`，解析 `customPromptTemplateToggle` 与模块 toggle 语法，值写入 `globalChatVariables["toggle_*"]`
  - 继续回复、截图、上传文件
  - 模块列表、Hypa 记忆弹窗
  - 插件菜单项与浮动按钮
- **请求预览**：DevTool 面板提供"预览请求"，以预览模式调用发送入口而不真正发送，把格式化后的请求体以 Markdown 弹窗展示，是发送前查看将发送内容的唯一界面，热键 Ctrl+U 走同一路径（`DevTool.svelte:28-50`）。
- **预设与 persona**：Ctrl+P/Ctrl+E 打开预设/persona 列表弹窗，快速菜单（三击触摸或 Ctrl+`` ` ``）汇总这些入口；`QuickSettings`（Ctrl+Q）从侧栏展开。
- 按消息级别注入参数的界面本次未找到；输入文本的改写（`processScript` 的 editinput 管线与触发器）归入对话请求类目。

## 5. 发送、排队、流式反馈与停止

- **发送入口**：发送动作先检查全局生成锁，锁已置位就直接返回；否则依次经过命令短路、文件展开、触发器与输入脚本，把用户消息推进消息数组并清空输入，最后由包装函数进入请求层（`sendMain` 见 `DefaultChatScreen.svelte:144-216`，`sendChat` 见 `process/index.svelte.ts:99`）。
- **互斥守卫**：请求层内部再查一次进行中标记 `isDoing`，只有处理序号 `chatProcessIndex` 非负的递归调用能通过，群聊成员、自动续写与触发器重发都属于这类；独立发起的新发送一律被拒绝。
- **状态反馈**：生成锁置位后，发送按钮原位换成停止按钮，按钮里的 spinner 按处理阶段换色：1 处理准备与构建为蓝色，2 token 检查为粉色，3 请求与流式为绿色，4 后处理为紫色（`DefaultChatScreen.svelte:1063-1088`）。界面没有排队指示器：同一会话的第二次发送被 `doingChat` 直接拒绝，发送按钮此时已不在原位。
- **流式写入**：请求成功后先插入一条空的角色占位消息，携带生成信息与会话 id，随后到达的流式分块经 editoutput 脚本处理，写回这条消息的文本；生成期间另有标记表明当前聊天处于流式。展示优化模式（balanced、strong）把界面刷新合并成 125ms 的节流，更强的模式则推迟到流结束后再渲染（`process/index.svelte.ts:1600-1753`，渲染细节见消息渲染器笔记）。
- **停止**：点击停止按钮调用 `abortChat`，对当前的 AbortController 执行 abort（`DefaultChatScreen.svelte:331-335`）；中止监听随后取消流的 reader，各模型请求层把同一个 signal 传给 fetch 或 WebSocket。请求层在流中止时清掉流式标记并返回 false，**半截回复保留在消息流中**，落盘时机归入对话请求类目。自动续写、群聊顺序生成与触发器重发共用同一个 signal，一次停止就能中断整条递归链。
- **错误与重试**：请求失败时弹出错误 Alert，开启 `inlayErrorResponse` 则改为把 `risuerror` 代码块追加到最后一条角色消息（`process/index.svelte.ts:159-210`）。界面没有独立的重试按钮，用户重新发送或点 reroll 才会发起新一轮生成。生成完成时按提示音与通知开关播放音效，并请求 Web Notification，点击通知只聚焦窗口。
- 群聊内部按顺序生成（见第 7 节）；多用户房间在生成前做互斥检查，检查不通过就回滚并提示"其他用户正在请求"（`peerSafeCheck`）。

## 6. 消息操作、分支与版本导航

- **操作栏**：主要按钮是复制、翻译、编辑、TTS 与删除；书签、分支、禁用本条、禁用以上四个次要按钮收进 `PopupButton` 弹出层，窗口窄于 640px 时主要按钮也一并让位到弹出层。按钮组由 `Chat.svelte` 里的 `majorIconButtonsBody` 与 `minorIconButtonsBody` 两个 snippet 渲染。
- 所有操作按钮都带 `button-icon-*` class，热键系统按 class 找到按钮并触发同一个动作（见第 9 节）。
- **禁用时机**：正在流式优化的消息上隐藏编辑、翻译与局部编辑；多用户房间里隐藏删除按钮；复制、TTS 与书签分别受 `useChatCopy`、角色模式与 `enableBookmark` 控制；首条问候语消息的轮换箭头另受 `swipe` 与 `showFirstMessagePages` 两个开关限制。
- **复制**：优先写富文本剪贴板（`ClipboardItem`，把消息渲染为带样式的 HTML 并内联图片），失败回退纯文本。
- **编辑**：点编辑按钮，或在开启 `clickToEdit` 时点击消息正文，进入 textarea 编辑态，再点确认写回；`PartialEditController` 另提供区块级与拖拽选择的局部编辑，两者分别受 `enableBlockPartialEdit` 与 `enableDragPartialEdit` 控制。页面正在显示 LLM 翻译时，局部编辑从翻译缓存取文本并写回同一缓存键，原消息保持不变；翻译缓存尚未取得时回退为编辑原文。原文编辑、翻译编辑与翻译视图控制三者互斥，避免同时进入多个编辑模式（`Chat.svelte:136-276,498-546`、`PartialEditController.svelte:18-63,238-307`）。
- **删除**：普通删除是否弹确认取决于 `askRemoval`；Shift 点击直接把会话截断到该条之前。长按与开启 `instantRemove` 共用二次确认分支：确认结果为 true 时仅删除当前条目，为 false 时截断到该条之前；分支实现与长按绑定见 `Chat.svelte:106-130,874`。
- **分支**：分支按钮把当前会话整份复制成新会话插在原会话之后，名称自动编号，可选放进新文件夹，并在末尾追加一条 `{{specialcomment::branchedfrom::…}}` 注释消息，随后切到新会话。点击这条注释会跳回源会话并折叠到分支点，折叠态下消息区只渲染到该位置，底部出现"加载更多"按钮恢复全量（`Chat.svelte:830-865`、`globalApi.svelte.ts:2390-2408`）。
- **分支树视图**：会话列表底部的按钮打开 `AlertComp` 的分支弹窗，`gui/branches.ts` 以消息内容哈希求共同前缀，把全部会话画成一棵带连接线的树，hover 节点可预览消息文本。**节点点击目前只切换预览**，静态代码确认 onclick 仅设置 `branchHover`；实际跳转仍然走会话列表与回链注释。
- **书签**：消息上的书签按钮弹出命名输入框，默认取消息后半段文本；书签列表弹窗（`BookmarkList.svelte`）支持展开预览、改名与删除。跳转由 `ScrollToMessageStore` 触发 `scrollToMessage`：临时扩大渲染页数、等待图片加载、滚动到目标并加蓝色 ring 高亮。
- **reroll/swipe 操作**：每条消息都能显示左右箭头，实际动作始终落在会话尾部。没有新候选时先截去尾部的角色回复重新生成，再把新增的消息段快照存入组件栈；该栈在切换角色时清空，切换会话时未校验归属。首条虚拟消息另用持久化索引轮换开场白（`DefaultChatScreen.svelte:219-319`）。
- **候选与持久化**：每个生成 ID 只记录流式末帧的候选全文，中间时间片不留副本，因此无法逐片倒放。候选文本表与消息段快照都只留在内存；用户选中的正文已经写回消息，会随保存循环落盘（`process/index.svelte.ts:1702-1704,1759`）。
- **翻译与生成信息**：翻译按钮切换 `translated` 显示态，LLM 翻译的结果缓存可以编辑；缓存被改写后以渲染版本号触发 `ChatBody` 重新解析，翻译结果为空字符串时同样按有效缓存处理。重新翻译、切换原文与翻译、以及两种编辑态都会在加载或编辑期间禁用；生成信息按钮弹出该消息的请求明细（`Chat.svelte:89-276,427-546,844-872`、`ChatBody.svelte:66-174,255`）。

## 7. 多会话、多模型与后台生成

- **全局单生成**：生成锁 `doingChat` 是模块级 store，任何时刻只允许存在一条发送链，切换角色、热键预览与插件 API 发起的发送都会被同一状态拒绝。界面没有跨会话的后台任务列表，正在跑的是哪一条会话，只能从停止按钮的 spinner 与消息流里的占位消息看出来。
- **群聊**：发送时先按角色活跃度（talkness）排序，开启 `orderByOrder` 则改用固定顺序，然后逐个成员递归进入同一个发送链，全部成员完成后整条链结束；**没有成员级排队序号 UI**。聊天菜单的"自动模式"仅群聊可见，用 while 循环连续发送，直到关闭或角色被切换（`runAutoMode`）。
- **自动续写与触发器重发**：回复 token 不足（`autoContinueMinTokens`）或结尾无标点时自动追加"继续"，触发器 `sendAIprompt` 后整体重发——都是同一 `sendChat` 内的顺序递归，共用停止信号。
- **多用户房间**：从会话列表菜单的"创建房间"或聊天菜单入口启动 PeerJS WebRTC 房间，侧栏显示房间号与主机/访客身份；主机把当前聊天同步给各端，生成前先做互斥检查，不通过就回滚聊天并报错；房间内消息带发送者用户名，删除按钮被隐藏。同步范围是聊天数据本身，草稿、滚动与生成状态留在各端（`sync/multiuser.ts`）。
- **消息表单交互**：带表单触发属性的正文可向角色与模块 Lua 回调提交字段，重复字段保留为数组；结果回写当前会话后重绘对应消息。所有正文 submit 都阻止浏览器默认导航，群聊不执行此交互。该表面与 Composer 发送、Onboarding 入场表单分别接线，详见[消息渲染器](../消息渲染器/Risuai-消息渲染调查笔记.md)第 8 节。
- **插件扩展点**：聊天菜单、Composer 上方的面板区与右上角的悬浮按钮是 Chat UI 留出的三个接入位置（`additionalChatMenu`、`chatPanelStore`、`additionalFloatingActionButtons`），具体能力属插件系统。

## 8. Chat UI 状态所有权与同步

| 状态 | 存放位置 | 生命周期 |
|---|---|---|
| 草稿文本 `messageInput` | `DefaultChatScreen` 组件 `$state` | 会话内共享单缓冲，切角色/会话保留，刷新即失 |
| reroll 快照栈 | `DefaultChatScreen` 局部变量 | 切角色清空，不持久化 |
| reroll 生成候选文本表 | `prereroll.ts` 模块级对象 | 进程内存，刷新即失；选中正文随消息保存 |
| `doingChat`/`chatProcessStage` | `process/index.svelte.ts:92-94` | 会话内，刷新即失 |
| 活跃角色 `selectedCharID` | writable store | 启动固定 -1，不持久化 |
| 活跃会话 `chatPage` | 角色数据（DB） | 持久化，随角色保存 |
| 折叠跳转态 `chatFoldedState`/`chatFoldedStateMessageIndex` | `globalApi.svelte.ts:2341-2388` | 会话内；角色或会话不匹配时自动清空 |
| 滚动与页加载 `loadPages`/滚动容器 | `DefaultChatScreen` 局部 + DOM | 组件不重挂载，切角色保留 |
| 侧栏/移动端布局 `sideBarStore`、`MobileGUIStack`、`MobileSearch` 等 | 各 store | 会话内 |
| 问候语 `fmIndex`、书签、`suggestMessages` | 会话字段（DB） | 持久化 |
| 保存冲突广播 | BroadcastChannel `risu-db` | 每次保存会话 |

- **持久化链路**：保存逻辑用 `$effect` 跟踪数据库各分区的变化，500ms 防抖之后由 `RisuSaveEncoder` 做增量编码：Tauri 端写入 `database/database.bin` 并保留时间戳备份，Web 端写入 IndexedDB；进入增量标记的是每个角色的非聊天字段、当前角色的全部聊天与最近变更的角色/会话，未变动的分区不重新编码（`globalApi.svelte.ts:292`）。
- **多标签页**：保存前广播 sessionID，收到他人广播后弹"其他标签页已保存"提示并整页 `location.reload()`；因是整页重载，进行中的生成与草稿一并丢失。
- **多用户房间**：同步的是 chat 数据（`request-chat-sync`/`receive-chat`），草稿、滚动、生成状态各自独立。

## 9. 键盘、焦点与关键路径可用性

- **热键机制**：监听挂在 document 上，keydown 时逐条比对可配置的热键表（默认表见 `defaulthotkeys.ts`），按修饰键组合匹配；无修饰键的热键在输入框聚焦时自动失效（`hotkey.ts`，全文 422 行）。
- **动作分发**：热键动作通过 `clickQuery` 直接点击匹配 class 的按钮（如 `.button-icon-send`），与鼠标点击走同一条路径。默认动作覆盖 reroll、反 reroll、翻译、删除、编辑、复制、发送、聚焦输入、设置、首页、角色切换与请求预览，绑定方式除 Ctrl+Alt 加 R、F、T、D、E、C 等字母外，还包括 Ctrl+Alt+Enter 与空格聚焦输入。
- **输入框内快捷键**：Enter 是否发送取决于 `sendWithEnter`，Shift 反转该行为，Ctrl+M 触发 reroll，输入法合成的按键（`isComposing`）不会误触（`DefaultChatScreen.svelte:600-613`）；Esc 用于全局关闭 Alert 与设置页，停止生成由停止按钮承担（`hotkey.ts:241-249`）。
- **焦点与可达性**：主输入框没有自动聚焦逻辑（未找到 mount 后的 focus 调用）；侧栏角色/会话项用 `role="button"`、`tabindex="0"` 加 Enter 处理保证可达。
- 绝大多数操作按钮是原生 button 可 Tab 聚焦，但存在若干 div 点击并用 `svelte-ignore a11y_*` 压制告警的控件（如根元素点击、消息正文点击编辑）。
- 移动端有全局横向滑动切页手势（`initMobileGesture`，50px 阈值，切换 `MobileGUIStack`/`MobileSideBar`）与三击快速菜单；读屏命名与焦点顺序的实际体验未运行验证。

## 10. 设计取舍与已确认边界

- **草稿单缓冲且不持久化**：换来"切会话不丢输入"，代价是多个会话无法各自保存草稿、刷新即失；源码层未发现任何输入持久化路径。
- **reroll 是内存撤销而非版本库**：候选只在会话内可回退；首条问候语与消息候选的持久化语义不对称（前者 `fmIndex` 落库，后者不落库）。分支复制会话是唯一把"另一版本"固化的方式。
- **分支树视图只读**：树形预览可见，但节点不可点击导航，跳转入口分散在回链注释与会话列表。
- **搜索能力集中在角色名**：角色网格/移动端有名称搜索，会话与消息内容搜索无 UI 入口；消息定位靠书签跳转与折叠回链。
- **停止即中断且保留半截**：与失败重试分开；中止后的半截正文留在消息数组，可随保存循环持久化。候选缓存刷新丢失的边界不能套用到已经回写的消息正文。
- **并发策略是全局互斥**：不做队列、不做后台，多路需求靠 WebRTC 房间的互斥检查兜底；群聊顺序生成共享一个停止信号，反馈上只有单一 spinner，无成员级进度。
- 本笔记未盘点全项目 Modal、Alert 类型、主题 token、动画参数与响应式断点，仅在聊天主链交点处（停止 spinner、分支树弹窗、书签跳转、保存冲突提示）记录其行为。

## 11. 未验证事项

- 视觉效果、动画与响应式断点行为均未运行验证；键盘焦点顺序、读屏命名与移动端手势灵敏度需要实机确认。
- 发送、停止、reroll 的调用链已从源码确认（按钮 → 对应 action → 状态/请求层），但翻译按钮、TTS、书签、富文本复制、Web Notification 的实际端到端效果未验证。
- 多标签页保存冲突的"提示后整页重载"路径为代码确认，真实浏览器行为未实测；BroadcastChannel 不可用时（旧环境）无该机制。
- reroll 快照栈在"同角色内切换会话后点击 reroll"的场景下与具体会话的对应关系未校验，可能错配——静态观察，未运行验证。
- 群聊顺序生成、自动续写、触发器重发共用停止信号的行为只在代码层确认；冷存储大角色（`coldstorage`）恢复、多用户房间端到端同步未实测。
- 流式显示优化模式（off/balanced/strong）对渲染性能与消息内容最终落盘的差异未做运行验证（渲染细节在消息渲染器笔记）。

## 12. 关键源码索引

- `src/App.svelte`：屏幕条件渲染（196-236）；全局拖放导入（68-101）
- `src/lib/ChatScreens/DefaultChatScreen.svelte`：草稿与输入（44-60）；`sendMain`/`sendChatMain`/`abortChat`/`reroll`（137-335）；Composer 与停止按钮（586-727）；聊天菜单（895-1046）；滚动加载（572-585）；spinner 阶段色（1063-1088）
- `src/lib/ChatScreens/Chat.svelte`：消息操作栏（468-888）；分支与回链（830-865, 396-411）；编辑/局部编辑（129-139, 389-463）
- `src/lib/ChatScreens/Chats.svelte`：增量挂载与自动滚动（65-227）
- `src/lib/ChatScreens/ChatScreen.svelte`：主题布局与立绘
- `src/ts/process/index.svelte.ts`：`doingChat`/`chatProcessStage`（92-94）；`sendChat`（99-2208，流式 1591-1757，错误 159-210）
- `src/ts/process/prereroll.ts`（全文 29 行）：生成候选文本与当前索引
- `src/ts/process/files/multisend.ts`：`postChatFile`（196）
- `src/ts/globalApi.svelte.ts`：`saveDb`（292-471）；`foldChatToMessage`/`changeChatTo`（2390-2429）；`chatFoldedState`（2341-2388）
- `src/ts/characters.ts`：`changeChar` 守卫（876-898）
- `src/ts/stores.svelte.ts`：工作台状态（24-51）
- `src/lib/SideBars/Sidebar.svelte`、`SideChatList.svelte`、`Toggles.svelte`：会话导航、文件夹、toggle 配置
- `src/lib/Others/ChatList.svelte`、`BookmarkList.svelte`、`AlertComp.svelte`（branches 视图 832-903）、`QuickSettingsGUI.svelte`、`GridCatalog.svelte`
- `src/ts/gui/branches.ts`（全文 104 行）：分支树布局
- `src/lib/ChatScreens/Suggestion.svelte`、`src/ts/hotkey.ts`、`src/ts/defaulthotkeys.ts`
- `src/ts/sync/multiuser.ts`：`createMultiuserRoom`（60）、`peerSync`（369）、`peerSafeCheck`（393）
- `src/lib/Mobile/MobileBody.svelte`、`MobileHeader.svelte`、`MobileCharacters.svelte`
- `src/ts/bootstrap.ts`：启动恢复（246-256）；`src/ts/chatLoadPages.ts`（分页常量）
