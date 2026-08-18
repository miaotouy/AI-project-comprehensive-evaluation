# Risuai Chat UI 调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：直接阅读源码（`App.svelte` 的条件渲染工作台、`ChatScreens/` 系列组件的 Composer 与消息操作、`SideBars/Sidebar.svelte` 与 `SideChatList.svelte` 的会话导航、`process/index.svelte.ts` 的发送/流式/中止链路、`globalApi.svelte.ts` 的会话切换与保存、`hotkey.ts`、`sync/multiuser.ts`、`Mobile/` 组件），并以 grep 核对草稿持久化、消息搜索入口、停止与重试的实际调用链；本次未运行应用
>
> 调查范围：聊天工作台用户主链：页面结构与会话导航、现场恢复、Composer 与草稿、发送前配置可见性、生成状态反馈与停止、消息操作与分支导航、多会话与多用户房间、UI 状态所有权与跨窗口同步、键盘与焦点可用性；消息内容渲染（`ChatBody.svelte`、解析器）、请求构建与执行语义、会话数据模型与导出分别归入消息渲染器、对话请求与上下文、会话与消息管理、对话导出与分享类目；通用界面盘点（全量 Modal、Toast/Alert 类型、主题 token、动画参数、设置页完整清单）不属于本笔记正文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **工作台是"图标栏 + 侧栏面板 + 主题化聊天面"的组合**：无传统路由，`App.svelte:208-236` 按设置页、移动端 GUI、首页、聊天面做条件渲染；聊天面内嵌会话列表侧栏、角色配置、DevTool 与快捷设置四个面板，聊天区同时承载输入区与消息流。
- **会话以角色为单位组织**：每个角色下挂 `chats[]` 数组与当前指针 `chatPage`；切换角色时若正在生成会被 `changeChar` 拒绝；刷新后总是回到首页（`selectedCharID` 初始为 -1），"恢复现场"= 重新点角色图标，聊天指针随角色数据持久化。
- **草稿是单一共享缓冲**：`DefaultChatScreen.svelte` 组件级状态，不按会话区分、不持久化，切角色/切会话不丢输入，刷新即失。
- **生成全程串行、无排队 UI**：`doingChat` 全局锁在发送时置位，发送按钮原位替换为停止按钮；停止 = `AbortController.abort()`，经 fetch signal 取消流，半截回复保留在内存与消息流中；群聊、自动续写、触发器重发都是带同一信号递归的顺序执行。
- **reroll/swipe 是内存快照机制而非持久化候选**：左右箭头渲染在每条消息上但总是作用于会话尾部；候选存于组件内快照栈与模块级分块缓存，刷新即失；只有首条消息的问候语轮换（`fmIndex`）与会话级字段（书签、建议消息）是持久化的。
- **跨窗口/跨设备**：同源多标签页用 BroadcastChannel 做保存冲突检测（冲突后提示并整页重载）；WebRTC 多用户房间同步聊天数据并互斥生成权限，UI 状态（草稿、滚动、生成）不做同步。

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

- **顶层分支**：`App.svelte:196-236` 依次判定加载中、自定义 GUI 菜单、首次设置、设置页、移动端 GUI、角色网格、聊天面七个状态，分别对应欢迎引导（`WelcomeRisu`）、设置面板（`settingsOpen`）、移动端布局（`MobileGUI`）、角色网格与 Sidebar + ChatScreen 组成的聊天面。
- 所有模态类组件（Alert、预设、persona、书签列表、Hypa 记忆、EasyPanel 等）平铺在根元素末尾按各自 store 显隐，不与聊天面抢占布局。
- **侧栏**（`SideBars/Sidebar.svelte`）：左侧竖排图标栏（角色头像列表、文件夹、新建按钮，支持 HTML5 拖拽排序与归组）加右侧可折叠面板；面板内容由 `sideBarMode`/`botMakerMode`/`devTool`/`QuickSettings.open` 切换为会话列表、角色配置、DevTool 或快捷设置。图标栏在 menuSideBar 关闭时仍可用，设置、首页、Playground、角色网格入口在汉堡菜单内。
- **聊天面**（`ChatScreens/ChatScreen.svelte`）：按 `DBState.db.theme` 分支渲染 classic、waifu、waifuMobile 三种布局；角色立绘（`TransitionImage`）、可拖动立绘框（`ResizeBox`）与背景图只在对应主题出现，聊天主体统一是 `DefaultChatScreen`。
- 顶部左上角 `SideBarArrow` 按钮折叠/展开侧栏（`sideBarStore`/`sideBarClosing`，动画结束后更新状态）。
- **多窗口**：本次未找到任何跨窗口 UI 状态同步；同源多标签页依赖保存侧的 BroadcastChannel 冲突检测（见第 8 节），没有草稿、busy、活跃会话的跨窗口共享。

## 2. 会话列表、搜索与现场恢复

- **切换角色**：侧栏头像点击 → `changeChar`（`characters.ts:876-898`），生成中直接拒绝；角色带冷存储标记时先取回冷存储数据再切换。
- **角色级快捷键**：Ctrl+[ / Ctrl+] 按名称排序切换相邻角色（`hotkey.ts:92-123`），Ctrl+G 把侧栏滚动到当前角色。
- **会话列表**（`SideBars/SideChatList.svelte`）：顶部"新建聊天"按钮直接 `unshift` 空会话并 `changeChatTo(0)`；每个会话项带重命名（编辑模式）、复制（`createChatCopyName` 自动编号）、导出、删除（确认、仅剩一个时拒绝）、更多菜单（复制/绑定 persona/创建多用户房间）。列表用 SortableJS 支持会话级与文件夹级拖拽排序，排序结果写回 `chara.chats` 并保持当前页指针。
- **会话文件夹**：`chatFolders[]` 折叠/展开、改色、重命名、删除；分支时可自动创建 "Branches of X" 文件夹（`Chat.svelte:834-843`，受 `createFolderOnBranch` 控制）。未置顶、未读标记功能：本次未找到。
- **第二个会话入口**：聊天菜单（输入区右侧按钮展开）内的"聊天列表"打开 `Others/ChatList.svelte` 弹窗，功能是 SideChatList 的精简版（切换、导出、删除、新建、导入），受 `showMenuChatList` 开关控制。
- **搜索**：角色搜索存在且分两处——桌面角色网格 `GridCatalog.svelte` 的搜索框（按名称过滤）与移动端 `MobileHeader` 的搜索输入（`MobileSearch` store，`MobileCharacters.svelte` 过滤）；**会话列表搜索与消息内容搜索本次未找到 UI 入口**（`v2QuickSearchChat` 是触发器系统的数据查询能力，不属于搜索界面）。
- **现场恢复**：启动时 `selectedCharID.set(-1)`（`bootstrap.ts:252`）固定回首页，不自动恢复上次角色；聊天指针 `chatPage` 是角色持久数据，由保存链路增量持久化，重新选中角色即回到上次会话。消息区按页渲染（初始 30 条，滚动到顶追加 15 条，常量见 `chatLoadPages.ts`），同一角色下切换会话时用上次会话 id 判定"新消息来自同会话才自动滚动"。书签跳转与分支回跳（见第 6 节）会临时拉长渲染页数并滚动高亮目标消息。

## 3. Composer、草稿、附件与快捷输入

- **Composer 布局**（`DefaultChatScreen.svelte:586-727`）：文本域 + 发送/停止按钮 + 菜单按钮一行，`fixedChatTextarea` 开启时 sticky 在底部。
- **输入行下方的同一列**还渲染粘贴图片预览、自动建议、翻译输入框、贴纸选择（`AssetInput`）与插件面板（`chatPanelStore`）。
- **草稿**：`messageInput` 是 `DefaultChatScreen` 的组件级 `$state`（`DefaultChatScreen.svelte:44`）。聊天面在切换角色/会话时不会重挂载（无 key），因此草稿是**整个工作台共享的单缓冲**——换角色不丢、多个会话共用同一份输入；项目源码中除插件沙箱外未发现输入内容的 localStorage/sessionStorage 存取（grep 依据），刷新即失。
- **附件入口**：剪贴板粘贴图片（`DefaultChatScreen.svelte:615-653`）经 `postChatFile` 拆成 inlay 资产引用（文件预览卡，可逐个移除）或 `{{file::name::data}}` 文本引用；聊天菜单"上传文件"同一路径；贴纸面板从角色附加资产中选择并插入占位语法。
- **应用级拖放**（`App.svelte:68-101`）导入角色卡/预设/模块，与 Composer 附件路径分离，靠自定义 MIME 类型（`dragTypes.ts`）区分内部拖拽与文件导入。
- **命令与建议**：输入以 / 开头时 `sendMain` 先交给 `processMultiCommand`（`process/command.ts`）执行并短路发送；自动建议 `Suggestion.svelte` 用子模型按最近 10 条消息生成候选（按角色会话存 `chat.suggestMessages`），点击填入输入框，清理尾缀的 autoSuggestClean 可关闭。
- **翻译输入框**（`useAutoTranslateInput`）提供"先输入原文、翻译后发送"的双文本域模式；@提及、变量补全这类输入辅助本次未找到。
- **发送前文件检查**：`fileInput` 为空时若消息为空，`useSayNothing` 开关决定是否推送一条 `*says nothing*` 用户消息。

## 4. 发送前配置

- **作用域分层且可辨认**：模型、温度、上下文/回复 token 等全局参数在设置页与侧栏快捷设置（`QuickSettingsGUI.svelte` 的三个页签：BotSettings、OtherBotSettings、ModuleSettings）；角色级配置（系统提示、触发器等）在侧栏角色面板（`CharConfig`）；会话级只有少数绑定字段（bindedPersona、modules、suggestMessages）与 Toggles 里的内存开关，开关值存 `globalChatVariables["toggle_*"]`。
- **作用时点**：所有层都作用于"下一次请求"——`sendChat` 在请求开始前快照 preset 与 toggle 状态写入该次消息的 `promptInfo`。
- **聊天内的发送前开关**：输入区右侧菜单（`DefaultChatScreen.svelte:895-1046`）集中了与当前对话相关的开关与动作——自动翻译输入、自动建议、jailbreak 相关 toggle 在侧栏 `Toggles.svelte`（解析 `customPromptTemplateToggle` 与模块 toggle 语法，值存 `globalChatVariables["toggle_*"]`）、"继续回复"、截图、上传文件、模块列表、Hypa 记忆弹窗、插件菜单项与浮动按钮。
- **请求预览**：DevTool 面板提供"预览请求"（`sendChat(-1, {preview/previewPrompt})` 不真正发送，把 `previewFormated`/`previewBody` 以 Markdown 弹出展示，`DevTool.svelte:28-50`），是"发送前查看将发送内容"的唯一界面；热键 Ctrl+U 同一路径。
- **预设与 persona**：Ctrl+P/Ctrl+E 打开预设/persona 列表弹窗，快速菜单（三击触摸或 Ctrl+`` ` ``）汇总这些入口；`QuickSettings`（Ctrl+Q）从侧栏展开。
- 未找到按消息级别的参数注入界面；输入文本的改写（`processScript` 的 editinput 管线、触发器）属于请求类目。

## 5. 发送、排队、流式反馈与停止

- **发送入口**：`sendMain`（`DefaultChatScreen.svelte:144-216`）先检查 `$doingChat`（为真直接返回），再走命令短路、文件展开、触发器与输入脚本，push 用户消息并清空输入，经包装函数调用 `sendChat(-1, {signal, continue})`（`process/index.svelte.ts:99`）。
- **互斥守卫**：`sendChat` 内的 `isDoing` 检查只放行 `chatProcessIndex >= 0` 的递归调用（群聊成员、自动续写、触发器重发），独立的新发送一律拒绝。
- **状态反馈**：`doingChat` 置位后发送按钮原位替换为停止按钮，按钮内 `loadmove` spinner 按 `chatProcessStage` 变色——1 蓝（准备/构建）、2 粉（token 检查）、3 绿（请求与流式）、4 紫（后处理，`DefaultChatScreen.svelte:1063-1088`）。没有排队指示器：同一会话第二次发送被 `doingChat` 直接拒绝，按钮本身已不存在。
- **流式写入**：请求成功后先 push 一个空的 char 占位消息（带 generationInfo 与 chatId），流式块经 editoutput 脚本处理后写回该消息文本；`isStreaming` 标记当前聊天处于流式；展示优化模式（balanced/strong）把刷新合并为 125ms 节流、甚至推迟到流结束后再渲染（`process/index.svelte.ts:1600-1753`，渲染细节见消息渲染器笔记）。
- **停止**：停止按钮 → `abortChat` → `abortController.abort()`（`DefaultChatScreen.svelte:331-335`）；abort 监听取消流 reader，各模型请求层把同一 signal 传给 fetch/WebSocket；`sendChat` 在流中止时清 `isStreaming` 并返回 false，**半截回复保留在消息流中**（不删除；落盘时机属请求类目）。自动续写、群聊顺序生成、触发器重发共用同一个 signal，一次停止可中断整条递归链。
- **错误与重试**：请求失败经 `throwError` 弹错误 Alert，`inlayErrorResponse` 开启时改为把 `risuerror` 代码块追加进最后一条角色消息（`process/index.svelte.ts:159-210`）；没有独立的"重试"按钮——用户重新发送或使用 reroll 触发新一轮生成。完成时按提示音与通知开关播放音效、请求 Web Notification（点击只聚焦窗口）。
- 群聊内部为顺序生成（见第 7 节）；多用户房间生成前有互斥检查（`peerSafeCheck`，失败回滚并提示"其他用户正在请求"）。

## 6. 消息操作、分支与版本导航

- **操作栏**（`Chat.svelte` 的 `majorIconButtonsBody`/`minorIconButtonsBody` 两个 snippet）：主要按钮=复制、翻译、编辑、TTS、删除，次要按钮（书签、分支、禁用本条、禁用以上）收在 `PopupButton` 弹出层；小于 640px 宽时主要按钮也收进弹出层。
- 所有操作按钮带 `button-icon-*` class，供热键系统按 class 触发（见第 9 节）。
- **禁用时机**：流式消息（`isOptimizedStreamingMessage`）隐藏编辑/翻译/局部编辑；多用户房间内隐藏删除按钮；复制受 `useChatCopy` 开关、TTS 受角色模式、书签受 `enableBookmark` 控制；首条问候语消息的轮换箭头受 `swipe` 与 `showFirstMessagePages` 控制。
- **复制**：优先写富文本剪贴板（`ClipboardItem`，把消息渲染为带样式的 HTML 并内联图片），失败回退纯文本。
- **编辑**：编辑按钮或 `clickToEdit` 点击消息进入 textarea 编辑态，再点确认写回；另有 `PartialEditController` 提供区块级与拖拽选择的局部编辑（受 `enableBlockPartialEdit`/`enableDragPartialEdit` 开关）。
- **删除**：`rm` 支持普通删除（`askRemoval` 开关决定是否确认）、Shift 点击截断到该条之前、长按（`longpress` 指令）与 `instantRemove` 的二次确认路径。
- **分支**：分支按钮把当前会话快照复制到 idx+1（名称自动编号，可选放进新文件夹），末尾追加一条 `{{specialcomment::branchedfrom::…}}` 注释消息并切换到新会话；点击该注释链接通过 `changeChatTo` + `foldChatToMessage` 跳回源会话并折叠到分支点（`Chat.svelte:830-865`、`globalApi.svelte.ts:2390-2408`），折叠态下消息区只渲染到该消息，底部出现"加载更多"按钮恢复全量。
- **分支树视图**：会话列表底部按钮打开 `AlertComp` 的 branches 弹窗，`gui/branches.ts` 按消息内容哈希求共同前缀把全部会话画成一棵连接线树，节点 hover 预览消息文本；**节点点击只切换预览、不能导航**（静态代码确认 onclick 仅设置 `branchHover`），实际跳转仍走会话列表与回链注释。
- **书签**：消息书签按钮弹输入框命名（默认取后半段文本），书签列表弹窗（`BookmarkList.svelte`）展开预览、改名、删除，跳转通过 `ScrollToMessageStore` 触发 `scrollToMessage`（临时扩页、等待图片、滚动并加蓝色 ring 高亮）。
- **reroll/swipe**：左右箭头渲染在每条消息上（`Chats.svelte` 挂载时统一传 `rerollIcon:'dynamic'`），但动作总是作用于**会话尾部**：reroll 在无新候选时弹出尾部角色消息重新生成，完成后把新消息段快照推入组件内快照栈（切角色时清空，切会话不重置——快照与具体会话的对应关系未做校验，属静态观察）；同时按 `generationId` 在 `process/prereroll.ts` 模块级缓存流式分块，支持生成过程中的逐块回退。候选栈与分块缓存都在内存中，刷新即失。首条消息的问候语轮换走持久化的 `fmIndex`，带"第几页/共几页"指示。
- **翻译与生成信息**：翻译按钮切换 `translated` 显示态，LLM 翻译可编辑缓存文本；生成信息按钮弹出该消息的请求明细（`alertRequestData`）。

## 7. 多会话、多模型与后台生成

- **全局单生成**：`doingChat` 是模块级 store，任何时刻只允许一个发送链；切角色、热键预览、插件 API 的发送都被同一状态拒绝。没有跨会话后台任务 UI，也没有运行标记列表——"哪条在跑"由停止按钮 spinner 与消息流中的占位消息表达。
- **群聊**：发送时按角色活跃度/talkness 排序（或 `orderByOrder` 固定顺序）逐个成员顺序调用 `sendChat(chatProcessIndex)` 递归，全部完成后整个发送链结束；**没有成员级排队序号 UI**。聊天菜单的"自动模式"（`runAutoMode`，仅群聊可见）用 while 循环连续发送直到关闭或角色被切换。
- **自动续写与触发器重发**：回复 token 不足（`autoContinueMinTokens`）或结尾无标点时自动追加"继续"，触发器 `sendAIprompt` 后整体重发——都是同一 `sendChat` 内的顺序递归，共用停止信号。
- **多用户房间**（`sync/multiuser.ts`）：会话列表菜单"创建房间"或聊天菜单入口启动 PeerJS WebRTC 房间，侧栏显示房间号与主机/访客身份；`peerSync` 把当前聊天同步给各端，`peerSafeCheck` 在生成前互斥（不通过则 `peerRevertChat` 回滚并报错）；房间内消息带发送者用户名、删除按钮被隐藏。这是聊天数据的实时同步，不涉及 UI 状态。
- **插件扩展点**：`additionalChatMenu` 渲染进聊天菜单、`chatPanelStore` 渲染在 Composer 上方的面板区、`additionalFloatingActionButtons` 固定悬浮在右上角——都是 Chat UI 的接入点，具体能力属插件系统。

## 8. Chat UI 状态所有权与同步

| 状态 | 存放位置 | 生命周期 |
|---|---|---|
| 草稿文本 `messageInput` | `DefaultChatScreen` 组件 `$state` | 会话内共享单缓冲，切角色/会话保留，刷新即失 |
| reroll 快照栈 | `DefaultChatScreen` 局部变量 | 切角色清空，不持久化 |
| reroll 分块缓存 | `prereroll.ts` 模块级 Map | 进程内存，刷新即失 |
| `doingChat`/`chatProcessStage` | `process/index.svelte.ts:92-94` | 会话内，刷新即失 |
| 活跃角色 `selectedCharID` | writable store | 启动固定 -1，不持久化 |
| 活跃会话 `chatPage` | 角色数据（DB） | 持久化，随角色保存 |
| 折叠跳转态 `chatFoldedState`/`chatFoldedStateMessageIndex` | `globalApi.svelte.ts:2341-2388` | 会话内；角色或会话不匹配时自动清空 |
| 滚动与页加载 `loadPages`/滚动容器 | `DefaultChatScreen` 局部 + DOM | 组件不重挂载，切角色保留 |
| 侧栏/移动端布局 `sideBarStore`、`MobileGUIStack`、`MobileSearch` 等 | 各 store | 会话内 |
| 问候语 `fmIndex`、书签、`suggestMessages` | 会话字段（DB） | 持久化 |
| 保存冲突广播 | BroadcastChannel `risu-db` | 每次保存会话 |

- **持久化链路**：`saveDb`（`globalApi.svelte.ts:292`）用 `$effect` 跟踪 DB 各分区变化，500ms 防抖后经 `RisuSaveEncoder` 增量编码，Tauri 端写 `database/database.bin`（含时间戳备份），Web 端写 IndexedDB；每个角色的非 chats 字段、当前角色全部 chats 与最近变更的角色/会话进入增量标记，未变更分区不重编码。
- **多标签页**：保存前广播 sessionID，收到他人广播后弹"其他标签页已保存"提示并整页 `location.reload()`；因是整页重载，进行中的生成与草稿一并丢失。
- **多用户房间**：同步的是 chat 数据（`request-chat-sync`/`receive-chat`），草稿、滚动、生成状态各自独立。

## 9. 键盘、焦点与关键路径可用性

- **热键机制**（`hotkey.ts` 全文 422 行）：document 级 keydown 遍历可配置的 `DBState.db.hotkeys`（默认见 `defaulthotkeys.ts`）按修饰键组合匹配；无修饰键的热键在输入框聚焦时自动失效。
- **动作分发**：热键动作通过 `clickQuery` 直接点击匹配 class 的按钮（`.button-icon-send` 等），与鼠标点击走同一条路径；默认覆盖 reroll、反 reroll、翻译、删除、编辑、复制、发送、聚焦输入、设置、首页、角色切换与请求预览等动作，如 Ctrl+Alt+R/F/T/D/E/C、Ctrl+Alt+Enter、空格聚焦输入。
- **输入框内快捷键**：Enter 按 `sendWithEnter`（或 Shift 反转）发送、Ctrl+M 触发 reroll（`DefaultChatScreen.svelte:600-613`），合成输入（`isComposing`）不误触；Esc 全局关闭 Alert/设置页（`hotkey.ts:241-249`），不做停止用途。
- **焦点与可达性**：主输入框没有自动聚焦逻辑（未找到 mount 后的 focus 调用）；侧栏角色/会话项用 `role="button"`、`tabindex="0"` 加 Enter 处理保证可达。
- 绝大多数操作按钮是原生 button 可 Tab 聚焦，但存在若干 div 点击并用 `svelte-ignore a11y_*` 压制告警的控件（如根元素点击、消息正文点击编辑）。
- 移动端有全局横向滑动切页手势（`initMobileGesture`，50px 阈值，切换 `MobileGUIStack`/`MobileSideBar`）与三击快速菜单；读屏命名与焦点顺序的实际体验未运行验证。

## 10. 设计取舍与已确认边界

- **草稿单缓冲且不持久化**：换来"切会话不丢输入"，代价是多个会话无法各自保存草稿、刷新即失；源码层未发现任何输入持久化路径。
- **reroll 是内存撤销而非版本库**：候选只在会话内可回退；首条问候语与消息候选的持久化语义不对称（前者 `fmIndex` 落库，后者不落库）。分支复制会话是唯一把"另一版本"固化的方式。
- **分支树视图只读**：树形预览可见，但节点不可点击导航，跳转入口分散在回链注释与会话列表。
- **搜索能力集中在角色名**：角色网格/移动端有名称搜索，会话与消息内容搜索无 UI 入口；消息定位靠书签跳转与折叠回链。
- **停止即中断且保留半截**：与"失败重试"解耦——没有重试按钮，错误后用户自行再发或 reroll；停止后消息保留在内存，刷新即失，与 SillyTavern 同类的"停止后回滚"语义不同（本项目是保留）。
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
- `src/ts/process/prereroll.ts`（全文 29 行）：流式分块缓存
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
