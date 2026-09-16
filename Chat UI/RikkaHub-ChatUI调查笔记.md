# RikkaHub Chat UI调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：静态阅读原生 Compose 聊天页、抽屉/输入/消息组件、Navigation 3 路由与事件绑定，并对照 `web-ui/`（React Router + TypeScript）的聊天界面
>
> 调查范围：聊天工作台结构与会话导航、Composer 与附件、发送/流式/停止反馈、消息操作与分支、工具审批入口、抽屉与快捷键、Web 端差异；不含全应用设置页、主题视觉与消息渲染细节（属相邻类目）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的聊天面是单 Activity、Navigation 3 栈式导航的 Compose 界面。聊天页把「会话抽屉 + 顶部栏 + 消息列表 + 底部 Composer」组装成一体；会话列表在抽屉里以分页长列表呈现，会话切换调用 `clearAndNavigate`，即清空返回栈后压入新的聊天页，因此不存在「返回上一个会话」的返回历史。

界面层只负责展示与装配，会话数据与生成任务的语义分别属于[会话与消息管理](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)与[对话请求与上下文](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)，消息内容的绘制属于[消息渲染器](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)。输入草稿保存在 `ChatVM` 内、随会话切换被销毁，不落盘。

Web 端是独立的 React Router 7 应用，由应用内本地 Web 服务承载，与端上共用后端状态；两端在 Composer、消息操作、搜索与流式滚动上结构相似，但 Web 端本次未找到语音输入/朗读与消息翻译。

## 工作台边界与用户主链

入口是唯一可见的 Activity，它用 Navigation 3 的 `NavDisplay` 承载返回栈，起始页即聊天页。起始会话 id 由偏好决定：`create_new_conversation_on_start` 为真时每次随机新建，否则沿用 `lastConversationId`；进入聊天后当前会话 id 会写回该偏好以便下次启动恢复，见 `RouteActivity.kt:254-265`、`ChatVM.kt:89-100`。

用户主链：启动即进入一个聊天页（空会话或上次会话）→ 打开抽屉浏览/搜索/切换会话 → 在 Composer 选模型、加附件、发送 → 观察消息区流式与状态 → 对消息重生成/编辑/分支/翻译/朗读 → 从抽屉进入助手或设置。

外部入口通过 Intent 扩展：分享文本/图片、处理文本、翻译动作，以及带会话 id 的通知跳转，都会被解析成导航目标页（聊天页、分享处理页或翻译页），见 `RouteActivity.kt:212-232`。桌面快捷方式另有相机与翻译入口，相机拍完再以 `ACTION_SEND` 回到主 Activity，定义见 `res/xml/shortcuts.xml`。

## 1. 页面结构、导航与多窗口

聊天页由 `ChatPage` 组装，界面主体分为抽屉与内容两栏。窄屏用 `ModalNavigationDrawer`，大屏改用 `PermanentNavigationDrawer`；大屏条件是「横屏且宽度不小于 1100dp」，见 `ChatPage.kt:132-259`。页间过渡由 `NavDisplay` 的规格提供，根页淡入淡出、非根页横向滑入并缩放，见 `RouteActivity.kt:296-318`。

内容区是 `Scaffold`：顶部栏、底部 Composer、中间消息列表。顶部栏显示会话标题与「助手 / 模型（提供方）」副标题，标题可点击编辑（空会话时提示不可改），右侧按钮切换「消息预览模式」和新建会话，见 `ChatPage.kt:622-741`。

返回栈语义有两处已实现的事实：`Navigator.clearAndNavigate` 直接清空再压入（`NavContext.kt:28-31`），切换会话、新建会话、打开搜索结果都走这条路径，所以根聊天页通常栈深为 1、系统返回会退出应用；抽屉打开时用 `BackHandler` 拦截返回以先关抽屉（`ChatPage.kt:118-122`）。

预测性返回：清单开启 `enableOnBackInvokedCallback`，导航层配置了 `predictivePopTransitionSpec` 弹出过渡（`AndroidManifest.xml:54`、`RouteActivity.kt:315-318`）；本次未找到显式的预测性返回处理器用法，工作区也未发现多窗口/分屏同步逻辑。

## 2. 会话列表、搜索与现场恢复

抽屉内列表由 `ChatDrawerVM` 提供：按当前助手过滤、按「未归类」或指定文件夹分页，并用分隔符插入「置顶」与日期分组标题，见 `ChatDrawerVM.kt:44-121`。助手或文件夹变化时列表流重建，切换助手会把文件夹筛选重置回默认视图（`ChatDrawerVM.kt:126-134`）；分页与搜索背后的查询和索引见[会话与消息管理](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

每条会话长按弹出操作菜单：置顶/取消置顶、重新生成标题、移动到其他助手/文件夹、删除（`ConversationList.kt:244-368`）；正在生成的会话显示一个小圆点，集合来自聊天服务的会话任务映射（`:284-294`）。删除文件夹时若有会话正在生成会被拒绝并提示，见 `ChatDrawerVM.kt:165-177`。

现场恢复分两处：抽屉列表把首个可见项索引与偏移写入 `SavedStateHandle`，重建时按保存值恢复滚动位置，见 `ChatDrawerVM.kt:118-139`；打开抽屉后若当前会话不在可见区，会滚动到该项，见 `ConversationList.kt:89-103`。

抽屉顶部还提供搜索与历史记录入口，见 `ChatDrawer.kt:694-757`。搜索页是跨会话的消息全文搜索：支持「当前助手 / 全部助手」范围与相关度/时间排序，结果点击后携带 `nodeId` 打开对应会话并定位到该消息节点，见 `SearchPage.kt:68-250`。助手切换入口在抽屉底部：选择助手后，根据「新建或打开已有」偏好决定目标会话 id，再跳转到聊天页，见 `ChatDrawer.kt:301-324`。

## 3. Composer、草稿、附件与快捷输入

Composer 是底部输入区。文本区默认最多 5 行高度，可展开为全屏编辑；回车发送由偏好 `sendOnEnter` 控制，发送与长按发送分别对应「发送并触发回复」与「仅添加消息不生成」，见 `ChatInput.kt:581-635`、`ChatPage.kt:385-417`。

草稿保存在 `ChatInputState`，它持有文本字段状态、待发送的非文本部件，以及正在编辑的历史消息与原附件集合，见 `ChatInputState.kt:12-48`。该对象是 `ChatVM` 的字段（`ChatVM.kt:69`），属页面级内存状态、不落盘；配合会话切换时的返回栈清空，可推断切换会话会丢失未发送草稿，此点未在设备上验证。

附件入口由「+」按钮打开底部弹层，集合了拍照（可接裁剪）、图片、视频、音频、文件与语音模式（`FilesPicker.kt:116-145`），其中视频/音频仅在选择 Google 提供方时出现（`:130-134`）。文件类型经 MIME 前缀与扩展名白名单校验，粘贴走同一状态：图片被接收为附件，长文本按偏好转成文本文件，见 `ChatUtil.kt:35-63`、`ChatInput.kt:495-530`。已选附件以横向 chip 行展示、可单个移除，编辑历史消息时移除已有附件不会删除源文件（`AttachmentChips.kt:59-64`）。

快捷输入有三处入口：快捷消息按钮把预设内容追加到输入框、会话建议 chips 点击填入输入框、输入补全弹层做工作区文件路径补全，见 `ChatInput.kt:720-766`、`ChatList.kt:717-746`。

语音输入按钮在 ASR 可用时出现，把识别结果追加到文本；独立「语音模式」是听写→入队→朗读的完整循环，状态机与启动校验见 `VoiceSessionController.kt:27-152`、`VoiceMode.kt:67-109`，识别与播放实现见[媒体创作](../媒体创作/RikkaHub-媒体创作调查笔记.md)。排队消息在 Composer 上方以面板展示，支持逐条编辑/移除，暂停时可「继续」，见 `MessageQueuePanel.kt:38-162`。

## 4. Agent、模型、工具与发送前配置

发送前可配置项集中在 Composer 底部一行与「+」弹层：

- 模型：模型选择按钮打开模型列表弹层，选择结果写回当前助手的 `chatModelId`，见 `ChatInput.kt:279-285`、`ChatVM.kt:167-183`。
- 助手：当前助手由设置中的 `assistantId` 决定；抽屉底部助手选择器切换后进入对应会话，见 `ChatDrawer.kt:301-324`。
- 联网搜索：搜索按钮在「关闭 / 本地 / 内置」之间切换；本地模式改助手的 `enableWebSearch`，内置模式在模型工具集合里增删搜索工具，见 `ChatPage.kt:354-384`。
- 推理等级：仅当当前模型具备推理能力时展示按钮，写入助手 `reasoningLevel`，见 `ChatInput.kt:310-320`。
- 「+」弹层内还有工作区绑定与工作目录、MCP 选择器、扩展（快捷消息/提示词注入/技能）计数入口、上下文压缩，见 `FilesPicker.kt:151-285`。

可见性与写回位置提示了作用域：助手级配置写回助手对象，模型级工具开关写回提供方下的模型定义（`ChatPage.kt:354-384`）；字段来源与请求组装见[Agent角色配置](../Agent角色/RikkaHub-Agent角色配置调查笔记.md)。

工具审批入口在消息内：待审批工具卡在折叠步骤右侧给出「拒绝/批准」按钮，拒绝会先弹原因输入框；交互式提问工具 `ask_user` 走独立渲染，支持单选/多选/文本并汇总成答案提交（`ChatMessageTools.kt:161-236`、`:257-436`）。界面只负责收集结果并回调 `ChatVM.handleToolApproval`，见 `ChatVM.kt:263-278`；审批语义与执行校验见[Agent工具](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

## 5. 发送、排队、流式反馈与停止

发送按钮的形态由「是否生成中且输入为空」决定：生成中且输入为空显示为停止（红色），空输入且未生成时禁用，其余为发送（`ChatInput.kt:388-431`）；点击时先清焦点并收键盘，生成中且输入为空则转为停止（`:165-169`）。

发送路径分两支：编辑态提交编辑，否则提交新消息，随后请求列表滚到底部（`ChatPage.kt:385-403`）。停止入口最终落到聊天服务的停止方法（`ChatVM.kt:280-284`），排队、暂停与恢复的判定和持久化见[对话请求与上下文](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。流式期间界面保持常亮，见 `ChatInput.kt:358-360`。

消息区的加载态是列表末尾的一项：显示兔子加载动画与可选的 `processingStatus` 文本（`ChatList.kt:381-402`）。消息文本在 `loading` 时禁用文本选择容器，以避免流式重渲染与选择工具栏的并发问题，生成结束再启用（`ChatMessage.kt:418-428`）。

错误以底部浮层卡片展示，可逐条消除或全部清除（`ChatList.kt:420-428`）；生成完成后可选自动朗读最后一条助手消息（`TTSAutoPlay.kt:14-42`）。流式内容的绘制与滚动锚定见[消息渲染器](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)。

## 6. 消息操作、分支与版本导航

消息操作条随内容与角色变化：复制、重新生成（用户消息需二次确认）、朗读与翻译（仅助手消息）、更多、分支选择器（`ChatMessageActions.kt:70-211`）；助手启用会话级系统提示且非生成中时，顶部另显示自定义系统提示入口（`ChatList.kt:372-379`）。

「更多」打开底部操作表，提供选择并复制、WebView 预览（仅含文本时）、编辑、分享、创建分支、收藏与删除（`ChatMessageActions.kt:246-479`）。编辑把消息内容装载回 Composer 并进入编辑态，创建分支会新建一份会话并跳转过去（`ChatPage.kt:463-472`）。分支切换在操作条内联：节点存在多个候选消息时显示「上一个 / 序号/总数 / 下一个」，切换通过更新消息节点并保存会话实现（`ChatMessageBranch.kt:26-95`）；节点与 `select_index` 语义、从哪个节点重建请求属于相邻类目，分别见[会话与消息管理](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)与[对话请求与上下文](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。

点操作表的「分享」进入多选态并默认勾选到该消息为止，底部浮动工具栏提供清空、全选、确认，确认后打开导出表（`ChatList.kt:349-354`、`:431-507`）；导出表支持 Markdown 与图片两种格式，图片导出可展开推理内容（`Export.kt:111-239`），内容口径与生成链路见[对话导出与分享](../对话导出与分享/RikkaHub-对话导出与分享调查笔记.md)。

阅读导航有两个机制：「消息预览模式」把列表切成带搜索框的消息摘要列表、点击条目跳回原消息；最近滚动后出现的浮动跳转控件提供到顶、上一屏、下一屏、到底，见 `ChatList.kt:596-714`、`:748-848`。翻译结果以可折叠卡片追加在消息下方并有加载态，清理入口在语言选择弹层（`ChatMessageTranslation.kt:56-291`）；会话规模超阈值（节点数与最后助手输入 token 同时超限）时弹一次提醒对话框，见 `ChatSizeChecker.kt:17-57`。

## 7. 多会话、多模型、群聊与后台生成

并行生成的可见线索来自聊天服务的会话任务映射：抽屉会话项据此显示生成中圆点，见 `ConversationList.kt:284-294`、`ChatVM.kt:85-87`。当前聊天页只订阅自己会话的生成任务、状态与队列，见 `ChatVM.kt:76-87`。并发、队列与后台最终化语义见 [对话请求与上下文调查笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)；界面侧的返回路径由通知管理器承担，`RouteActivity.kt:242-251` 注释表明事件由 `ChatNotificationManager` 消费。

群聊：本次未找到群聊/多助手同会话入口。助手切换表现为「切到以另一个助手为上下文的会话」，见 `ChatDrawer.kt:301-324`，与多模型并列的方式是每个会话绑定一个助手与一个当前模型。

## 8. Chat UI 状态所有权与同步

界面状态按所有者分布如下：

- 会话内容、生成任务、处理状态、消息队列、错误：聊天服务持有，`ChatVM` 以 Flow 暴露给界面，见 `ChatVM.kt:65-130`。
- 输入草稿与编辑目标：`ChatInputState`，VM 级内存态，见 `ChatVM.kt:69`。
- 抽屉筛选、分页与滚动位置：`ChatDrawerVM`，滚动位置进 `SavedStateHandle`，见 `ChatDrawerVM.kt:48-139`。
- 抽屉开合、预览模式、多选集合、弹层显隐：页面级 Compose 状态（`ChatPage.kt:113`、`ChatList.kt:246-248`）。
- 挂起的错误与待审批工具：分别来自服务错误流与会话消息本身。

公共状态注入与导航库封装见[应用界面基础设施](../应用界面基础设施/RikkaHub-应用界面基础设施调查笔记.md)。跨窗口同步：本次未找到窗口间的草稿、busy 与会话状态同步机制；Web 端是同仓库内的独立实现，见第 10 节。

## 9. 键盘、焦点、响应式与关键路径可用性

键盘避让由输入区的插入边距与清单的 adjustResize 组合（`ChatInput.kt:208-216`、`AndroidManifest.xml:73`）。列表另有监听 IME 高度做自动滚动的组件，自动到底只在「未处于滚动态、仍在加载且已位于底部」时触发，音量键滚动为可选展示设置，见 `ImeAutoScroller.kt:16-37`、`ChatList.kt:218-290`。

焦点处理上，打开抽屉与发送动作都会主动清焦点并收键盘（`ChatPage.kt:124-130`、`ChatInput.kt:165-175`）。无障碍方面，Activity 根节点开启测试标签映射为资源 id，发送按钮等带测试标签（`RouteActivity.kt:290-294`）。焦点顺序、TalkBack 可用性与真机软键盘表现均未在目标环境验证。

## 10. Web 端界面差异

Web 端是 `web-ui/` 下的 React Router 7 应用，由应用内本地 Web 服务承载；路由只有首页与 `/c/:id`，两者渲染同一聊天页组件，见 `web-ui/app/routes.ts:3`、`web-ui/app/routes/conversations.tsx:704-712`。

结构与端上对应：左侧是可折叠会话侧栏，主区是消息时间轴 + 底部输入区；非移动端把「工作台面板」做成可拖拽分栏，移动端（断点 768px）改为底部抽屉，见 `web-ui/app/routes/conversations.tsx:1175-1219`、`web-ui/app/hooks/use-mobile.ts:3-18`。草稿粒度不同：Web 端草稿按会话 id 建键存入 zustand，首页另用一个随机首页草稿 id，新建会话时重新生成，见 `web-ui/app/stores/slices/chat-input-slice.ts:17-104`。

输入区支持回车发送（偏好关闭时改为 Shift+Enter）、粘贴与拖拽上传（含类型校验），「+」菜单含上传图片/文档与导出会话 Markdown（`web-ui/app/components/input/chat-input.tsx:310-485`）。消息操作与工具审批的构成与端上基本一致：复制、编辑、重新生成、分支切换、导出与删除，审批为批准/拒绝两键、拒绝原因用浏览器输入框，`ask_user` 有独立提问组件，见 `web-ui/app/components/message/chat-message.tsx:230-478`、`web-ui/app/components/message/parts/tool-part.tsx:274-427`。

滚动用贴底库实现自动贴底与「回到底部」按钮（`web-ui/app/components/extended/conversation.tsx:13-91`）；会话侧栏有置顶与日期分组、文件夹筛选与跨会话消息搜索弹窗（`web-ui/app/components/conversation-search-button.tsx:66-205`）。

已确认的差异：Web 端本次未找到语音输入、TTS 朗读或消息翻译入口（仅在部分组件内使用 i18n）；Web 端会话切换是路由跳转而非清栈。端上与 Web 的具体视觉与性能表现未做对照运行。

## 11. 设计取舍与已确认边界

- 会话切换即重置返回栈：换来「聊天页恒为根」的一致行为，代价是无法用系统返回回到上一个会话（`NavContext.kt:28-31`）。
- 会话内容单一事实源在服务层，界面组件多为无状态装配，使抽屉、消息列表、输入区能各自订阅所需切片（`ChatVM.kt:65-130`）。
- 草稿按会话隔离但驻内存、不落盘，符合「切换会话不携带草稿」的取向，未观察到恢复机制。
- 大屏用手势抽屉之外的第二套布局（永久抽屉），阈值写死为横屏且宽 ≥ 1100dp（`ChatPage.kt:132-142`）。
- 审批、朗读、翻译、分支等能力以「消息角色/节点状态」为开关条件装配，界面不自行推断执行结果。
- 端上与 Web 端是两套独立实现，共用后端模型；本类目未确认两者在状态恢复与并发反馈上的完全等价。

## 12. 未验证事项

- 侧栏/抽屉手势与预测性返回的实际动画、可用性，以及 `ModalNavigationDrawer` 边缘手势与系统返回的交互。
- 软键盘避让、焦点顺序、TalkBack 可用性与发送按钮的触摸目标覆盖度。
- 长历史滚动的性能、`ImeLazyListAutoScroller` 的真机观感、音量键滚动的系统共存。
- 草稿是否随会话切换/进程重启丢失（代码结构推断为丢失，未运行验证）。
- 语音模式在弱网、音频焦点抢占与后台切换下的表现；Web 端移动断点下的抽屉/输入与上传行为。
- 并发多会话生成时抽屉圆点与通知返回会话的实际一致性。

## 关键源码索引

- `app/src/main/java/me/rerere/rikkahub/RouteActivity.kt:212-318`（Intent 入口、起始页、NavDisplay 过渡与预测性返回）
- `app/src/main/java/me/rerere/rikkahub/ui/context/NavContext.kt:28-31`（clearAndNavigate 清栈语义）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatPage.kt:94-741`（页面组装、抽屉/大屏分支、TopBar、Composer 接线）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatVM.kt:53-130`（界面侧状态所有权与生成/队列入口）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatList.kt:236-848`（自动到底、错误卡、多选导出、预览模式与浮动跳转）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatDrawer.kt:100-324`（抽屉结构、会话操作菜单、助手切换）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatDrawerVM.kt:44-177`（会话分页、文件夹、滚动恢复）
- `app/src/main/java/me/rerere/rikkahub/ui/components/ai/ChatInput.kt:122-830`（Composer、发送/停止按钮、文本输入与补全）
- `app/src/main/java/me/rerere/rikkahub/ui/hooks/ChatInputState.kt:12-148`（草稿与编辑态数据契约）
- `app/src/main/java/me/rerere/rikkahub/ui/components/ai/FilesPicker.kt:89-310`（附件与发送前配置弹层）
- `app/src/main/java/me/rerere/rikkahub/ui/components/ai/MessageQueuePanel.kt:38-162`（排队消息面板）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessageActions.kt:70-479`（操作条与操作表）
- `app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessageTools.kt:94-479`（工具审批与 ask_user）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/search/SearchPage.kt:68-250`（跨会话消息搜索）
- `web-ui/app/routes/conversations.tsx:419-1223`（Web 草稿控制器、时间轴与页面/侧栏/响应式分栏）
- `web-ui/app/components/input/chat-input.tsx:177-758`（Web 输入区）
- `web-ui/app/components/message/parts/tool-part.tsx:274-675`（Web 工具审批与 ask_user）
