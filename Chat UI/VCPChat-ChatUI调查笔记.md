# VCPChat Chat UI 调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对；原文段自 [`../Chat/VCPChat-Chat调查笔记.md`](../Chat/VCPChat-Chat调查笔记.md)（2026-08-05 调查）迁移，核对范围覆盖 `main.html`、`renderer.js` 及其拆分后的 owner 与工作区侧栏；通用界面盘点（弹窗库、Toast 系统、主题、动画、灯箱）见 [`../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md`](../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md)
>
> 调查范围：工作台结构、Topic 导航与现场恢复、Composer 与快捷输入、发送前配置、发送/停止反馈、消息操作、键盘与无障碍、桌面集成交点；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 是 VCPToolBox 的 Electron 桌面前端，主窗口由左侧 sidebar、中央 chat、右侧 notifications sidebar 三栏，加右侧可展开的工作区侧栏组成：

- 会话导航是"助手 / 话题 / 设置"三个 tab 并列的工作区，不是路由跳转；话题列表渐进渲染 + IntersectionObserver 延迟计数，拖放排序用 SortableJS（第 2 节）。
- 工作区侧栏是标签页容器：状态在纯函数模块里，控制器只做组合与 DOM 投影，标签类型由 provider 与类型声明登记；话题级标签跟随当前对话恢复（1.3）。
- 四种聊天呈现模式（气泡 / 统一 / 刊物 / 对话）是同一消息数据的 CSS 投影，切换不重建消息组件树（1.4）。
- 发送按钮在"发送 / 中止回复 / 中止上下文压缩"三态间切换，标题与 `aria-label` 同步更新；单聊与群聊共用外观，但中断实现不同，UI 上看不出本地 abort 是否真正生效（第 5 节，执行语义见对话请求与上下文笔记）。
- 消息右键菜单承接复制、编辑、重新生成、创建分支、转发、朗读、阅读模式、删除等操作（第 6 节）。
- 无障碍处于初步阶段：核心控件与工作区侧栏有基础 ARIA，但消息列表、Agent/Topic 列表无语义标注，通用 Modal 无焦点陷阱（9.2）。
- 通用界面盘点（弹窗库、Toast、主题、动画、灯箱、全局快捷键清单等）见 [`../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md`](../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md)，本笔记只记录与聊天主链的交点。

## 当前工作台状态所有权

聊天主表面由 `mainChatComposition` 与 `mainChatSurfaceAdapter` 组装。每个 surface 持有自己的 DOM renderer、流消费者和释放动作，发送控件、附件、Flowlock、设置展示与主题也各有 owner；会话选择对象由 `surfaceConversation` 提供。因此 UI 在切换话题或销毁内部表面时可撤销旧流路由，而不是继续依赖单例消息视图。工作区侧栏由独立的 `sidePaneWiring` 装配，并经宿主绑定跟随当前选择，与主聊天表面的生命周期分开。

依据：`renderer.js:311-360`（`createSurfaceConversation` 与初始 surface）、`:577-599`（`createMainChatComposition`）、`:1012`（`initWorkspaceSidePane`）、`modules/renderer/mainChatComposition.js:9-101`、`modules/chat/surfaceConversation.js:8-41`、`modules/chat/chatSurface.js:7-59`。

## 工作台边界与用户主链

```text
进入主窗口（恢复 sidebar/通知栏宽度、最后打开状态与侧栏布局）
  -> 左侧 sidebar：助手 tab（Agent/Group 选择）-> 话题 tab（搜索/列表/拖放排序/右键菜单）
  -> 点击或新建 Topic -> 中央 chat 区按 presentation mode 呈现历史
  -> 右侧工作区侧栏：标签页（通知/辅助对话/代码查看/Git/浏览器/终端/命令输出/计划）
  -> 底部输入卡：文本/附件/表情包 -> 发送按钮（或中止回复按钮）
  -> 流式期间按钮变中断态（气泡流光边框的渲染在消息渲染器）
  -> 消息右键操作（复制/编辑/重试/分支/删除/转发/朗读）
  -> 搜索定位、切换 Topic -> 再次进入恢复现场（settings.json + localStorage）
```

边界：Topic 数据模型、索引与未读计数属于会话与消息管理（[`../会话与消息管理/VCPChat-会话与消息管理调查笔记.md`](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)）；中断执行、群聊调度、最终化落盘属于对话请求与上下文（[`../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)）；消息内容渲染与列表 DOM 策略属于消息渲染器（[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md)）。

## 1. 页面结构、导航与多窗口

### 1.1 主界面布局不是单一聊天页

`main.html` 将窗口拆成左侧 sidebar、中央 chat、右侧 notifications sidebar，以及默认收起的 `#vcpSidePane` 工作区侧栏（`:560`，带 `aria-label` 与随开合切换的 `aria-hidden`）。左侧用"助手 / 话题 / 设置"三个 tab（`:253`），助手 tab 负责 Agent/Group 选择，话题 tab 负责 Topic 搜索与列表，设置 tab 打开全局配置；窄侧栏另有 compact navigation。`renderer.js` 在启动时把这些 DOM 节点注入各模块，并按侧栏宽度、通知栏宽度、激活 tab 与头像模式恢复布局状态。窗口侧栏可拖拽调整宽度，通知栏可独立开关，因而"会话选择""消息阅读""并行工具"是并列的工作区而非路由跳转。页面 CSP 允许 blob 媒体源，并在末尾以 defer 引入前端插件加载器，分别为插件壁纸与自动朗读提供注入主窗口的通道（`:9-16`、`:1418`；插件明细见 Agent 工具笔记）。

### 1.2 侧栏宽度与 Compact 导航

**侧栏可拖拽宽度**：拖拽逻辑集中在 `initializeResizers()`（`modules/uiManager.js:56-171`）。最小/最大宽度优先从 CSS 计算样式读取，代码只提供 fallback：左栏 180px、通知栏 220px，最大宽度 600px；拖拽时写内联宽度并同步无障碍数值，结束后按设置项落盘（`:58-103`）。存在工作区侧栏时，右侧通知栏不放独立拖拽手柄（`:164`），右侧空间改由侧栏接管。

**Compact navigation 触发条件**：不是基于窗口宽度自动触发，而是由设置项 `sidebarAvatarOnly` 控制（`modules/renderer/mainChatSettingsPresentationOwner.js:84-110`）——用户在侧栏宽度设置中主动开启后生效。avatar-only 模式下侧栏折叠为仅显示头像，展示 `.sidebar-compact-navigation` 悬浮菜单（`main.html:224`）。菜单中的话题项给左侧栏加上抽屉展开类，话题列表以抽屉形式叠加（`modules/uiManager.js:440-454`）；Esc 关闭抽屉（`:512-514`），点击话题项后自动关闭（`:500-502`），点击抽屉外部也关闭（`:506-508`）。

### 1.3 工作区侧栏（Workspace Side Pane）

工作区侧栏是主窗口右侧的标签页容器，用来放和当前对话并排使用的工具：通知、辅助对话、代码查看、Git 变更、浏览器、终端、命令输出、计划详情、模型轨迹等。

**结构与装配**。`main.html` 里是 `<aside id="vcpSidePane">` 加标签条、概览浮层、右键菜单与"新标签页"面板（`:560` 起）；标题栏按钮左键展开侧栏、右键打开监控面板（`:459`）。装配入口是 `modules/renderer/sidePaneWiring.js:18-120`：查找 DOM、创建控制器、登记九种标签类型（外观、浏览器、辅助对话、代码查看、模型轨迹、通知、计划详情、终端、命令输出），再接线辅助对话、浮动选区按钮、助手资料与应用源、文件改动与状态面板、宿主事件五组 owner。控制器不识别具体标签类型，只通过类型声明里的钩子与 provider 打交道。

**状态与 DOM 分离**。标签列表、激活标签、可见性、所属对话、宽度都在 `modules/ui-system/side-pane/side-pane-state.js` 里以纯函数表达，所有函数返回新的冻结对象；控制器负责把状态投影到 DOM，并维护挂载表、最近关闭、按对话记住的激活标签与收起状态（`side-pane-controller.js:91-92`，两张记忆表各保留最近 50 条对话）。标签条、概览、右键菜单、新标签页、开合动画、宽度拖拽、焦点归属、关闭授权、快捷键各自是独立子模块，子模块之间不互相引用，联动都经控制器传入的回调完成。

**标签作用域与跟随对话**。标签有两种作用域：`global` 在所有对话可见（笔记、浏览器、终端等），`topic` 只在所属对话可见（辅助对话、计划详情），所属对话记在标签的 `parent` 上。宿主在 `chatManager.onSelectionChange` 与 `onSelectionIntent` 时调用 `controller.setParent`，先记下旧对话的激活标签与展开状态，再按新对话恢复，并让辅助对话 owner 恢复该对话的会话（`modules/renderer/sidePaneHostBindings.js:20-34`）。后台话题调 `openTab` 只登记并挂载自己的标签、返回自己的 handle，不会激活当前话题中的其他标签；`activateTab` 只接受当前话题可见的标签。

**快捷键与宽度**。`Ctrl/Cmd+Alt+B` 开合侧栏：展开时若有待审批先看通知，无标签时打开新标签页，否则回到该对话上次的标签；焦点在侧栏内时 `Ctrl+PageUp/PageDown` 按标签条顺序循环切换。焦点在浏览器标签的网页里时，主进程用 `before-input-event` 截键后转回主窗口执行同样动作（`modules/ui-system/side-pane/side-pane-shortcuts.js`，浏览器侧见 `browserHandlers.js`）。宽度按父容器内容区的比例保存（`sidePaneWidthRatio`，默认 45%，范围 20%–65%），展开/收起有过渡且过渡期间锁定内容宽度；窗口缩放停下 300ms 后，对话区窄于 480px 时自动收起（`side-pane-visibility.js`）。

**持久化**。主窗口用 localStorage 的 `vcp.sidePane.layout.v1` 存档：最多 30 个可持久化标签、单个标签序列化上限 64KB、每个对话的激活标签与收起状态各最多 50 条；读取时按版本号和逐项校验丢弃坏数据，写入做 400ms 防抖，页面隐藏、卸载或控制器销毁时立即写一次。登记完所有标签类型后才调用 `restoreLayout()`，避免启动时的空布局覆盖存档（`side-pane-persistence.js`、`sidePaneWiring.js:117`）。辅助对话不走这套存档，切对话时由 owner 的 `restoreSessions` 从会话服务恢复。

**辅助对话**。`sideChatSurfaceOwner.js` 组合独立渲染器、操作与输入提交；`modules/renderer/side-chat/` 下的 shell、composer-state、model-picker、references、message-actions、scrolling、persistence、draft-cache 分别负责视图、状态投影、模型选择、引用卡片、回答动作、贴底、历史与输入持久化、跨卸载缓存，各模块经组合者的 store 与回调连接。

### 1.4 四种聊天呈现模式是同一消息数据的 CSS/渲染投影

输入区模板 `main.html` 提供四个呈现模式按钮：气泡、统一、刊物、对话（`:137-143`），顶部还有快速切换器（`:129-135`，外层是一个单选组）。模式集合定义在 `modules/renderer/mainChatThemeOwner.js:1`，应用时移除旧模式类、挂上对应的 `chat-presentation-<mode>` 类，同步控件并写入设置（`:19-27`）；它不会转换 `history.json`，也不会创建不同的消息组件树。切换时保持滚动位置与流式状态。

"对话"模式另有一层运行时标记：`modules/renderer/messenger-presentation.js` 给消息打上最后一条助手消息、同发送者连续消息、群聊每组首条、新消息入场等类名，并维护跟随悬停气泡的浮动操作条、让消息列与输入框左右对齐；样式集中在 `styles/chat-messenger.css`。因此四种模式的差异是布局与状态标记，而不是渲染管线分叉。

## 2. 会话列表、搜索与现场恢复

### 2.1 话题列表渐进呈现

`topicListManager.js` 初始只渲染 40 条 Topic（`TOPIC_INITIAL_RENDER_COUNT`），滚动距离底部 320px 后按 30 条批量追加（`TOPIC_PROGRESSIVE_BATCH_SIZE`，常量见 `:28-30`），并用逐帧分片渲染（`:478-560`）。每一行先显示消息数占位符，由 `IntersectionObserver` 在进入视口前 240px 才读取 history 计算总数与未读标记（`:315`；计数逻辑的数据侧见会话与消息管理笔记 5.3/5.4）。行点击切换 Topic，右键打开重命名、删除、标记已读等菜单，搜索模式下禁用拖放排序。这个列表策略与消息区的"整段 DOM 重绘"相互独立：Topic 多时减少首次 IO，消息流中仍直接更新当前气泡。

### 2.2 拖放排序

用 SortableJS，初始化在 `initializeTopicSortable(itemId, itemType)`（`modules/topicListManager.js:1029-1095`）。onStart 时若全局"划词监听"处于开启状态会临时关闭，onEnd 时按拖拽前状态恢复，避免拖拽与全局划词快捷键冲突（`:1047-1063`）。onEnd 拿到新顺序的话题 id 数组后调用 `saveTopicOrder`（agent）或 `saveGroupTopicOrder`（group）（`:1070-1072`），排序落地到配置文件的语义见会话与消息管理笔记 5.1。保存失败会 toast 报错（`:1079-1084`）。搜索状态下不启用拖拽排序（仅在非搜索态初始化，`:505-507`）。

### 2.3 搜索入口

`loadTopicList()`（`modules/topicListManager.js:660-816`）读取搜索框的值，经 `parseTopicSearchQuery` 解析（`:192-201`）：普通关键词走前端过滤与后端内容检索的并集（数据侧见会话与消息管理笔记 5.2）；完整输入"未读话题"或"unread topic"时跳过文本搜索，改由未读置顶逻辑把未读话题稳定排到前面（`:204-230`、`:796`）。搜索框提示与 `aria-label` 为"搜索话题或未读话题"（`main.html:319-322`）。

- 话题条目另带"未读 N"/"未读"文字指示器（创建与更新见 `topicListManager.js:243-258`）；发送消息会清除持久化未读（`modules/chatManager.js:1749`；未读语义细节见会话与消息管理笔记 5.3）。

### 2.4 现场恢复

切换 Topic 成功会写 `localStorage.lastActiveTopic_*`（读取与写入都在 `modules/chatManager.js` 的同一套切换流程里，`:859`、`:1026` 起），并更新 `settings.json` 的最后打开项与话题字段（字段清单见第 8 节；数据语义见会话与消息管理笔记 2.4/3.1）——再次启动时据此恢复上次会话与话题。

## 3. Composer、草稿、附件与快捷输入

`main.html` 的 `textarea#messageInput`（`:514`）、附件预览区和 `sendMessageBtn`（`:552`）组成固定底部输入卡：

- **附件**：点击、删除、预览、自动伸缩都在输入区完成；附件数据对象（`type/src/name/size/_fileManagerData` 等）随用户消息落盘（`modules/chatManager.js:1662-1668`、`:2368`）。
- **换行**：`#messageInput` 的占位提示明示 Shift+Enter 换行（`main.html:514`），Enter 直接发送（`modules/event-listeners.js:425-430`）。
- **Loom 文本分享**：`renderer.js:715` 把 `onLoomShareTextToInput` 注册为 `loomShareText` 能力，LoomAPP 选中的文本直接插入 `#messageInput`。
- **表情包选择器**（`modules/emoticonManager.js`）：从服务端 API `getEmoticonLibrary()` 加载表情库，只筛选当前用户对应的分类（"通用表情包" + 按用户名的分类，`:40-60`）。UI 是平铺图片网格，没有搜索框、分类切换或分页，面板固定 270×240px，出现在按钮上方（`:157-158`）；点击面板外部关闭（100ms 延迟绑定，避免立即触发，`:108`）。
- 点击表情包把带尺寸属性的 `<img>` 标签插入输入框值，不是转义后的 Markdown 语法；表情库为空时显示"没有找到可用的表情包"占位（`:90`）。
- **群聊**：输入区另有邀请 Agent 发言按钮（触发 `handleInviteAgentToSpeak`，执行语义见对话请求与上下文笔记 8 节）。
- 发送按钮右键打开高级回复菜单；草稿（输入框未发送内容）的保存粒度**未在原调查中核实**。

## 4. Agent、模型、工具与发送前配置

- 左侧 Agent 列表支持搜索、点击切换、创建、编辑和删除；群组可创建并邀请 Agent 发言。
- 当前 Agent 设置中的**模型按钮可替换模型**，模型参数、上下文上限、流式输出和 TTS 在**折叠设置段落**中修改；模型参数（temperature、contextTokenLimit、maxOutputTokens、top_p、top_k）留空时显示"未设置"并存 `null`（`modules/settingsManager.js:381-385`，保存侧解析见 `:567-571`；发送侧行为见 Agent 角色笔记）。
- 标题栏提供当前 Agent 设置、通知/监控、主题、语音聊天，以及四种呈现模式的切换器（1.4）。
- 发送按钮右键的高级回复菜单属发送前配置的一部分，具体选项未在原调查中逐项列出。

## 5. 发送、排队、流式反馈与停止

- **按钮三态**：`modules/renderer/mainChatSendOwner.js:59-86` 负责按钮投影。上下文压缩进行中时进入压缩态：显示 spinner、无障碍名称改为"中止上下文压缩"（`:61-71`）；否则按最后一条可中断助手消息是否活跃切成中止或发送态，并同步 `title`、`aria-label` 与忙碌状态（`:74-84`）。
- **活跃回复判定**：`getInterruptibleMessage()`（`:28-57`）先在当前内存历史里从后往前找最后一条助手消息，若其思考中或 DOM 节点带 `streaming` 类即返回；历史里找不到时，再查流式投影的当前消息 id 与上下文，构造临时消息返回——这层兜底覆盖"消息尚未写进历史但流式投影已在处理"的时间窗口。
- **中断**：按钮动作在 `:128-142`，有活跃消息时走 `interrupt()`（`:88-121`），群聊消息走 `chatAPI.interruptGroupRequest`，单聊走 `interruptHandler.interrupt`；两者失败都会 toast 报错。因此**单聊与群聊共用发送按钮外观，但中断实现不同，UI 上看不出本地 abort 是否真正生效**——执行层的不对称见对话请求与上下文笔记 7.1。
- **流式反馈**：`.message-item.streaming` 的流光边框等属于消息渲染器笔记；中断后的"中止已发送"toast 与"流式响应中断"提示见对话请求与上下文笔记 7.1。

## 6. 消息操作、分支与版本导航

消息右键由 `modules/renderer/messageContextMenu.js` 提供：流式/思考中的消息显示"中止回复"（`:133`）；完成消息可编辑、复制渲染后的文本、剪切/粘贴（编辑态）、创建分支（`:295`）、转发（`:324`）、助手消息朗读气泡（`:337`）、阅读模式（`:398`）、删除，以及按角色显示"重新回复"。删除有确认对话框，编辑态有保存/取消和文本区。代码/媒体块另有复制、预览和下载。中键快捷动作另有独立 delegated handler。

Topic 右键可重命名、删除、标记已读；这些操作的数据变更语义未在原调查中核实（会话与消息管理笔记 3.4）。"创建分支"在数据层如何表示未核实（会话与消息管理笔记 1.3）；操作后从哪个节点重建请求属于对话请求与上下文类目。

## 7. 多会话、多模型、群聊与后台生成

- 群聊界面：群组可创建并邀请 Agent 发言（第 4 节）；同一 topic 内多个 agent 的发言按调度结果呈现，调度执行在对话请求与上下文笔记 8 节。
- 顺序模式设置可拖放成员形成 `speakerOrder`。保存前会过滤已移除成员，并把尚未列入顺序的新成员稳定追加；运行时 sequential 策略按该顺序发言，而不是固定沿用成员配置数组（`Groupmodules/groupchat.js:472-478`、`Groupmodules/modes/sequentialMode.js:21-22`）。
- 语音聊天窗口（`Voicechatmodules/voicechat.html`）是独立子窗口。输入从窗口内切换改为全局"按住说话"：语音输入模式与快捷键来自设置（默认 F7），按住说话模式下窗口内切换按钮被禁用并提示使用全局快捷键（`Voicechatmodules/voicechat.js:191-192`、`:220-256`）。关闭窗口时把本次对话历史保存为当前 Agent 的一个新 Topic，并尝试调用话题自动总结（`:118-145`；执行语义见对话请求与上下文笔记 3 节）。朗读与语流由共享的 TTS owner 承载（`:421-430`）。
- 多窗口之间的聊天状态同步（主窗口 vs 语音窗口 vs 图片查看器）未在原调查中核实。

## 8. Chat UI 状态所有权与同步

- **布局状态**：`sidebarWidth`、`notificationsSidebarWidth`、`sidebarActive`、`sidebarAvatarOnly` 四个配置项由启动时的设置应用链恢复（`renderer.js:1279` 转调 `modules/renderer/mainChatSettingsPresentationOwner.js:84-110`，1.1）。
- **侧栏状态**：工作区侧栏的标签与开合走独立的状态模块与 localStorage 存档（1.3），不与上述布局字段混存。
- **最后打开状态**：`lastOpenItemId`/`lastOpenItemType`/`lastOpenTopicId` 存 `settings.json`，`lastActiveTopic_*` 存 localStorage（2.4）。
- **桌面集成交点**（完整托盘/窗口逻辑盘点保留在源文件 13.8）：
  - 系统托盘由 `main.js:987-1090` 创建，主菜单动作与窗口显隐经 `handleTrayPrimaryAction` 收口；关闭主窗口时若桌面模式（Desktop 窗口）处于活跃状态，主窗口隐藏到托盘而非退出（`:895-905`）。托盘另有 Loom 菜单项与 Scriptorium"文坊"应用项（`modules/trayManager.js:32`、`:40`）。
  - 语音聊天是独立子窗口（第 7 节），与主窗口并行存在。
  - VCP Loom Manager 是独立管理窗口（`Loommodules/manager.html`），LoomAPP 运行时用 WebContentsView 承载（`modules/loom/VCPLoomManager.js`）。
  - 应用**不发送系统桌面通知**（未发现 `new Notification(...)` 或 Electron `Notification` 类调用），所有 AI 消息通知通过右侧内置通知侧栏和浮动通知呈现——通知机制的完整盘点保留在源文件 13.2。
- 消息输入中的草稿、busy 状态、滚动位置等临时 UI 状态按什么粒度保存**未在原调查中核实**。

## 9. 键盘、焦点、响应式与关键路径可用性

### 9.1 聊天关键路径快捷键（应用内）

`modules/event-listeners.js:1418-1480`（仅在主窗口有焦点时有效）：

- `Ctrl/Cmd+S`：快速保存 Agent 设置（仅当设置 tab 激活时，`:1419-1425`）
- `Ctrl/Cmd+E`：快速导出当前 Topic（`:1427-1432`）
- `Ctrl/Cmd+D`：AI 续写当前话题（Flowlock 锁定时弹 toast 阻止，`:1434-1449`）
- `Ctrl/Cmd+N`：新建话题（已上锁，`:1471-1478`）
- `Ctrl/Cmd+Shift+N`：新建未上锁话题（`:1466-1469`）
- `Shift+Enter`：输入框内换行；非 Shift 的 Enter 直接发送（`:425-430`）
- 工作区侧栏：`Ctrl/Cmd+Alt+B` 开合、侧栏内 `Ctrl+PageUp/PageDown` 切标签（1.3）

设置页面鼠标快捷操作（`modules/settingsManager.js:1073-1130`）：设置 tab 内用 300ms 双击检测的右键动作跳回助手（Agents）页面（`:1077`）；设置 tab 内中键点击跳转到话题（Topics）页面（`:1098-1130`）。

全局快捷键（Super+Alt+Z 便签、Ctrl+Shift+I 开发者工具，`main.js:2026-2035`；划词助手的挂起热键 CommandOrControl+Shift+P 在 `modules/ipc/assistantHandlers.js:724`；桌面宠物快捷键在 `modules/deskpet/petControls.js:108`）与完整清单保留在源文件 13.6。

### 9.2 无障碍现状（仅聊天关键路径）

**已有 ARIA 标注的区域**：
- 呈现模式切换器（`main.html:129-143`）：外层 `role="radiogroup"` + `aria-label="聊天显示模式"`，各按钮有 `role="radio"` 与 `aria-checked`
- 侧栏 tabs：`role="tablist"` + `aria-label="Sidebar sections"`（`:253`），tabpanel 有 `aria-hidden`
- Compact navigation（`:224`）：`aria-label="窄侧栏导航"`，trigger 有 `aria-label`，菜单项有 `role="menuitem"`
- 工作区侧栏（`:560`）：`aria-label="工作区侧栏"` + `aria-hidden`，标签条、概览浮层与右键菜单各自带 `role` 与 `aria-label`
- 所有 SVG 图标：普遍标注 `aria-hidden="true"`

**缺失 ARIA 标注的区域**（经代码检查确认未见）：
- Agent 列表 `<li>` 和群组列表 `<li>`：无 `aria-label`，无 `role`
- Topic 列表 `<li>`：无 `aria-label`
- 消息列表 `.message-item`：无 `role="listitem"` 或 `aria-label`

**焦点管理**：确认对话框打开时确认按钮自动 `focus()`（`modules/ui-helpers.js:1281`），支持 Esc 取消、Enter 确认，Tab 只在取消/确认两个按钮间循环（`:1285-1299`）；通用 Modal 打开时调用 `modalElement.focus()`（`:651`），但没有焦点陷阱，Tab 可以穿透到背景。Agent/Topic 列表项没有 `tabindex`，列表内无键盘导航。

发送按钮在模式切换时同步替换内部 SVG 与 `aria-label`（`modules/renderer/mainChatSendOwner.js:82-84`），三态名称与视觉状态一致。

总体评估：核心功能控件与工作区侧栏有基础 ARIA，但主要内容区（消息列表、Agent/Topic 列表）缺乏语义标注，键盘可达性不完整，无障碍支持处于初步阶段。完整清单（含设置页等非聊天区域）保留在源文件 13.11。

## 10. 设计取舍与已确认边界

- **四种呈现模式只改变布局/样式与状态标记**，工具块、思考链和 DailyNote 的协议解析仍由同一套 renderer 完成（1.4）；模式切换瞬间生效，没有专属过渡动画（动画盘点保留在源文件 13.7）。
- **消息区不是虚拟列表**，长 Topic 的初始批量渲染和后续重绘会带来整段 DOM 成本——渲染策略见消息渲染器笔记 8.1。
- **单聊与群聊共用发送按钮外观，但中断实现不同**，UI 上看不出本地 abort 是否真正生效（第 5 节）。
- **工作区侧栏把"并行工具"与聊天主链解耦**：状态纯函数化、标签类型可插拔、按对话记忆激活标签与开合；代价是侧栏与主窗口布局共享右侧空间（1.2、1.3）。
- **弹窗与通知交点**（通用机制完整盘点保留在源文件 13.1/13.2）：删除确认对话框（`modules/ui-helpers.js:1222-1300`，支持 Esc 取消、Enter 确认、点击遮挡层取消，危险操作时确认按钮为红色）服务于聊天主链的危险操作；审批类通知**永不自动消失**、须用户回应（`modules/notificationRenderer.js:1185-1191`）；通知浮卡默认 7 秒自动消失，通用 toast 默认 3 秒（`:1186`、`modules/ui-helpers.js:689`）。模型选择弹窗与全局设置弹窗走通用 Modal 懒加载路径（`modules/ui-helpers.js:622-660`）。
- **类目边界**：会话数据语义在会话与消息管理笔记，请求执行在对话请求与上下文笔记，消息壳与内容渲染在消息渲染器笔记。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为需要运行验证。
- 草稿保存粒度、多窗口聊天状态同步未核实。
- 高级回复菜单的具体选项未逐项核实。
- 无障碍部分只覆盖聊天关键路径；源文件 13.11 的全量清单未在本笔记重复。
- 工作区侧栏的标签拖拽、概览浮层、浏览器标签弹窗接管、终端/Git provider 的真实交互未运行验证；辅助对话的跨对话恢复只按 owner 调用链确认。
- renderer 型前端插件（动态壁纸/自动 TTS）的开关界面、与主窗口 DOM 的交互及其启用状态管理（PluginManagerModules 界面）未运行验证。

## 12. 关键源码索引

- `main.html`（三栏布局与工作区侧栏 `:560`、presentation 选择器 `:129-143`、compact 导航 `:224`、输入区 `:514`/`:552`）
- `renderer.js`（surface 与 owner 装配 `:311-360`、`:577-599`、侧栏初始化 `:1012`、布局应用 `:1279`）
- `modules/renderer/sidePaneWiring.js`（侧栏装配与标签类型登记 `:18-120`）
- `modules/renderer/sidePaneHostBindings.js`（跟随对话与辅助对话恢复 `:20-34`）
- `modules/renderer/mainChatSettingsPresentationOwner.js`（头像模式与布局应用 `:84-110`）
- `modules/renderer/mainChatThemeOwner.js`（四种呈现模式 `:1-27`）
- `modules/renderer/messenger-presentation.js`（对话模式状态标记）
- `modules/renderer/mainChatSendOwner.js`（按钮三态 `:59-86`、中断 `:88-121`）
- `modules/uiManager.js`（侧栏拖拽宽度 `:56-171`、compact 抽屉 `:404-523`）
- `modules/topicListManager.js`（渐进渲染 `:28-30`/`:478-560`、搜索 `:192-201`/`:660-816`、拖放排序 `:1029-1095`）
- `modules/chatManager.js`（现场恢复 `:859`/`:1026`、附件组装 `:1662-1668`、未读清除 `:1749`）
- `modules/renderer/messageContextMenu.js`（消息右键菜单）
- `modules/emoticonManager.js`（表情包选择器）
- `modules/event-listeners.js`（应用内快捷键 `:1418-1480`、Enter 发送 `:425-430`）
- `modules/settingsManager.js`（设置页鼠标快捷操作 `:1073-1130`）
- `modules/ui-helpers.js`（`showConfirmDialog` `:1222-1300`、通用 Modal `:622-660`、toast `:689`）
- `modules/notificationRenderer.js`（通知侧栏与浮卡 `:1164-1204`）
- `Voicechatmodules/voicechat.js`（语音聊天窗口）
- `main.js`（托盘 `:987-1090`、桌面模式隐藏 `:895-905`）、`modules/trayManager.js`（文坊/Loom 应用项 `:32`/`:40`）
