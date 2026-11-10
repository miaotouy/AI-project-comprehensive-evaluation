# Open WebUI Chat UI 调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：直接阅读源码（Svelte 组件与 store、`Chat.svelte` 会话状态机、Overview 消息树图组件、`MessageInput` 输入区）；界面视觉、焦点与键盘可用性未运行验证
>
> 调查范围：工作台结构、会话侧栏与搜索、Composer 与发送前配置、发送/排队/流式反馈与停止、消息操作与 Overview 分支导航、多会话与后台生成、UI 状态所有权；消息内容与列表渲染归消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的前端会话状态机整体内聚在 `src/lib/components/chat/Chat.svelte`（5754 行），包含发送、停止、重新生成、继续生成、MoA 合并与队列排队：

- 聊天控制器为 `Chat.svelte`，消息列表、输入区与渲染组件各自独立成组件（`Messages.svelte`、`MessageInput.svelte`、`Messages/*` 系列）；
- 临时会话没有 chat_id，前端先创建 `temporary:{socket.id}` 形式的会话 ID（`Chat.svelte:2868-2871`）；响应带回真实 chat_id 后，前端更新 store 与 `/c/{id}` URL 并刷新列表；
- 同一会话的多次提交先进入 `chatRequestQueues` 队列，由 `processNextInQueue` 合并后串行发送（3187 行）；服务端广播 `chat:active=false` 时，前端清空 taskIds 并重载；
- 右侧面板的 Overview 用 SvelteFlow 把整个消息树渲染成只读节点图（`Overview/View.svelte` 与 `Flow.svelte`），点击节点即把 `history.currentId` 切到该消息所在分支；
- 重新生成、继续生成与合并回复都基于同一棵 `history` 树，Overview 也读这棵树，界面不另建视图状态。

## 工作台边界与用户主链

```text
进入会话（/c/[id] 路由 -> Chat.svelte 会话控制器）
  -> 输入与发送（MessageInput.svelte -> submitPrompt -> sendMessage）
  -> 观察生成（Socket.IO events 事件 -> chatEventHandler 分发）
  -> 控制（stopResponse / regenerateResponse / continueResponse / mergeResponses）
  -> 分支导航（Overview 消息树图 -> showMessage 切换 currentId）
  -> 再次进入（URL /c/{id} 直接装载，history 由服务端快照恢复）
```

边界：发送链的请求构造与事件分发细节在对话请求与上下文；history 快照与消息表的数据语义在会话与消息管理；消息内容、Markdown、结构化输出与列表渲染在消息渲染器（`../消息渲染器/Open-WebUI-消息渲染器调查笔记.md`）。按 Chat UI 指南的通用 UI 过滤规则，本笔记不盘点全仓库的 Modal/Toast/Tooltip 库、主题 token 与响应式断点，只记录与聊天主链的交点。

## 1. 页面结构、导航与多窗口

- 路由 `/c/[id]` 的页面只做装配：把 URL 里的会话 id 传给 Chat 控制器（`src/routes/(app)/c/[id]/+page.svelte:1-7`）；根路径 `/` 挂载同一个控制器，用作新会话占位；
- 会话控制器 `Chat.svelte`（5754 行）按职责挂载渲染组件：消息列表壳交给 `Messages.svelte`（566 行），输入区交给 `MessageInput.svelte`（3067 行）；消息壳内部的入口分发、主渲染（流式内容、Markdown、引用、代码执行、评分）、用户消息、并排多列与结构化输出等组件的渲染实现属于消息渲染器，此处只把挂载位置记为工作台结构；
- 右侧工作台 `ChatTabs.svelte`（1202 行）按标签组织内容，标签覆盖会话、文件、文件预览、终端、浏览器、桌面、Artifact、预览、语音、评论与侧聊（`ChatTabs/tabs.ts:5-32`）；会话概览是其中按需打开的抽屉，由 `showOverview` store 控制，入口在 `ChatTabs.svelte:792-818`，先挂载 `Overview.svelte` 再进入 `Overview/View.svelte`（195 行）；左侧 `Sidebar.svelte`（2038 行）承载会话导航，见第 2 节；
- 多窗口：同一用户的多标签页经 Socket.IO 事件广播共享生成状态（对话请求与上下文笔记 5.3），但 `chatRequestQueues` 等前端 store 不跨窗口同步——同一会话在两个标签页同时提交的队列行为未验证；
- 嵌入场景：`Chat.svelte` 支持 `embedded` 模式（在笔记内嵌聊天，经 `onCreateEmbeddedChat`/`onSelectEmbeddedChat` 等 prop 接入，125-137 行），草稿按 `embeddedDraftKey` 管理（525-528 行）。

## 2. 会话列表、搜索与现场恢复

- 会话列表、搜索与未读状态的请求参数和数据语义见会话与消息管理笔记第 5 节（`GET /list`，60 条/页，支持 pinned/folders/sort）；界面侧：
  - 侧栏 `Sidebar.svelte` 承载会话列表、文件夹（`Sidebar/Folders.svelte`）、置顶模型与笔记，以及搜索入口 `SearchModal`；移动端把侧栏做成覆盖式抽屉，关闭后收成 42px 窄条，宽度可以拖拽调整（`Sidebar.svelte:892-989`）；
  - 搜索弹窗 `SearchModal.svelte`（布局组件）提供跨会话搜索，可用标签、文件夹、置顶、归档、共享等前缀限定范围，结果支持标题内联重命名和删除/归档，点击条目跳转到对应会话 URL（`SearchModal.svelte:146-277`）；
  - 新会话创建后，前端更新 store、把地址改成 `/c/{id}` 并刷新列表（发送链的数据侧见对话请求与上下文笔记 1.1）；
- 现场恢复：再次进入会话由服务端返回 history 快照，恢复当前分支与消息列表；标签面板与草稿有各自状态范围（见第 3、8 节），不随 history 一并持久保存。重连查询活动任务，已无活动任务的未完成消息可在加载时本地结算为 done，待回答的人工提问保留；滚动与视觉恢复未运行验证（[`Chat.svelte:3053-3107`](../../open-webui/src/lib/components/chat/Chat.svelte#L3053-L3107)）。

## 3. Composer、草稿、附件与快捷输入

- 输入区由 `MessageInput.svelte` 承担（3067 行），文本、附件、语音、命令与提及都在这一组件内组装：
  - `@` 提及用于选择模型或文件，`/` 命令由 `CommandSuggestionList` 提供，两者都经 suggestions 机制插入；粘贴上传由 `onPaste` 处理，拖放目标的 id 定义在 `Chat.svelte:142`（`MessageInput.svelte:101,1140-1178`）；
  - 语音输入由麦克风按钮和听写快捷键 `Shortcut.TOGGLE_DICTATION` 触发，另有 `speechAutoSend` 选项（`MessageInput.svelte:1106-1462`）；
  - `largeTextAsFile` 会把大段文本自动转成文件上传，触发方式取决于设置与 Shift 键（`MessageInput.svelte:1767`）；
- 草稿按浏览器标签页中的会话键保存到 sessionStorage：新会话用 `chat-input`，已有会话用带会话 id 的键；编辑回调默认 500ms 防抖，发送时清除对应键。保存内容包括正文、已上传的非图片附件，以及工具、技能、过滤器和部分能力选择；正文达到 5000 字符时清除缓存，浏览器 File 实例和图片附件不进入该草稿（[`Chat.svelte:4977-5035`](../../open-webui/src/lib/components/chat/Chat.svelte#L4977-L5035)、[`Chat.svelte:5531-5545`](../../open-webui/src/lib/components/chat/Chat.svelte#L5531-L5545)）。
- 加载持久会话时读取对应键并恢复输入，再应用模型默认配置；新会话也读取通用键，模型默认选择可能覆盖草稿中的能力选择。临时会话模式跳过恢复；旧草稿中的审批模式被忽略，防止恢复输入时修改审批设置或自动批准工具。嵌入笔记聊天另有草稿键。sessionStorage 只提供当前标签页生命周期内的恢复，未发现账户级跨设备草稿同步（[`Chat.svelte:847-869`](../../open-webui/src/lib/components/chat/Chat.svelte#L847-L869)、[`Chat.svelte:2798-2804`](../../open-webui/src/lib/components/chat/Chat.svelte#L2798-L2804)、[`Chat.svelte:3103-3107`](../../open-webui/src/lib/components/chat/Chat.svelte#L3103-L3107)）；
- 发送快捷键（Enter 发送、Shift+Enter 换行）与焦点管理也在输入区完成：按键由 `onKeyDown` 处理，提交后控制器把焦点交回 `chat-input` 元素；实际焦点顺序与键盘走查未运行验证（`MessageInput.svelte:1101-1125`、`Chat.svelte:2533-2534`）。

## 4. Agent、模型、工具与发送前配置

- 发送前配置经请求体传递，包括参数集（设置、会话参数、stop tokens）、工具/技能/终端/工具服务器的选择字段、功能标记与变量（数据侧见对话请求与上下文笔记 1.1），字段名见下：

  ```
  params / tool_ids / skill_ids / terminal_id / tool_servers / features / variables
  ```

  模型列表由 `ModelSelector.svelte` 渲染（95 行），多选结果记录在 `selectedModels`，可进入 side-by-side 并排输出；
- 配置入口分布在 Composer 周边：模型选择器、工具、技能与终端选择；工具和技能分别对应 `selectedToolIds` 与 `selectedSkillIds`（`Chat.svelte:356-357`）；参数设置由 `SettingsModal.svelte` 承载（975 行），工具服务器与技能选择另有专门弹窗。
- 输入菜单允许在完整访问与逐次确认之间切换。该动作同时保存会话参数与用户默认参数；切为完整访问时，还会批准最近一条属于当前用户的待审批工具并恢复执行，人工提问不参与自动批准。服务端负责校验消息归属与已结算状态（[`Chat.svelte:532-605`](../../open-webui/src/lib/components/chat/Chat.svelte#L532-L605)）。
- 人工提问从当前分支的 assistant output 恢复为输入区问题卡；作答、拒绝和超时都调用消息 resolve API，再把返回 task id 接回当前生成状态。持久聊天与工具审批共用恢复基础设施，交互目标分别为收集信息与允许执行；临时聊天通过在线回调交互（[`Chat.svelte:624-703`](../../open-webui/src/lib/components/chat/Chat.svelte#L624-L703)、[`main.py:1883-1906`](../../open-webui/backend/open_webui/main.py#L1883-L1906)）。
- 作用域辨认：`@` 提及内联切换 `atSelectedModel`（单次会话模型覆盖，`MessageInput.svelte:179`），会话参数 `params` 在创建会话时持久化（对话请求与上下文笔记 1.1 第 4 步）。配置项在界面上的作用域标识（全局/会话/本次）未运行验证。

## 5. 发送、排队、流式反馈与停止

- 提交排队：`chatRequestQueues` store（`src/lib/stores/index.ts:148`）+ `processNextInQueue`（`Chat.svelte:3187`）——同一会话的多次提交在前端合并（prompt 以换行连接、文件合并）后一次性发送；
- 生成状态反馈经 Socket.IO 事件驱动（事件分发表见对话请求与上下文笔记 5.3），前端按事件类型更新界面：

  | 事件 | 界面作用 |
  |---|---|
  | `chat:active` | 有/无活动任务，false 时清 taskIds；只在事件携带的 message_id（未携带时任一消息）确存在未完成 assistant 叶子时才重载，随后更新已读（`Chat.svelte:1220-1236`） |
  | `chat:message:tasks` | 任务进度（1005-1006 行） |
  | `chat:message:error` | 错误展示（1018-1019 行） |
  | `chat:tasks:cancel` | 置 response done 并走队列（987-998 行） |
  | `chat:message:follow_ups` | 追问建议（1020-1025 行） |

  生成中按钮的状态与真实任务状态的对应由 `taskIds`、`generating` 与上表事件驱动；停止按钮何时可点、失败后如何恢复，未运行验证；
- 停止：`stopResponse`（3303-3345 行）先停止会话级或逐个任务，再把所有 response 消息标记完成并 abort MoA 的 fetch 流，最后处理下一个排队请求；停止的实际网络中断层在对话请求与上下文笔记第 7 节；
- 完成反馈：`chat:completion` done 后 `chatCompletedHandler` 刷新侧栏列表（2179-2185 行）；`responseAutoCopy`/`responseAutoPlayback` 可选自动复制/朗读（2442-2449 行）。

## 6. 消息操作、分支与版本导航

- 消息操作有三个入口，都定义在 `Chat.svelte` 内：
  - 重新生成使用 `regenerateResponse`（3380-3411 行），多模型会话按模型与列序号单列重生成；
  - 继续生成使用 `continueResponse`（3413-3437 行），把 done 消息重置为未完成后继续写；
  - MoA 合并使用 `mergeResponses`（3439-3489 行），把多个模型的回复合成一条，执行侧见对话请求与上下文笔记第 7 节；
- 这些入口的按钮装配（何时显示、何时禁用）在 `ResponseMessage.svelte` 等渲染组件，属于消息渲染器类目；
- 会话级操作入口：分享 `ShareChatModal.svelte`、标签 `TagChatModal.svelte`、分叉/克隆走侧栏与消息操作菜单（数据语义在会话与消息管理笔记第 3-4 节）。

### 6.1 Overview：会话消息树图

会话概览由 `ChatTabs.svelte` 的抽屉承载（有消息时才允许打开，`ChatTabs.svelte:479,792-818`）。该视图把整个消息树渲染成一张**只读节点图**，实现分三层：

- **图数据构建**：`Overview/View.svelte`（195 行，`drawFlow` 从 65 行起）从 `history.messages` 逐条遍历，为每条消息生成节点，按 `parentId` 连出平滑折线边；节点层级取父节点层级加一，同层节点按层宽计数均匀排布。垂直与水平布局方向可以切换，按钮来自 `Flow.svelte` 的 ControlButton；
- **画布**：`Overview/Flow.svelte`（73 行，视口与缩放控制在 32-58 行）基于 `@xyflow/svelte` 的 SvelteFlow，默认自动适配视口，最小缩放 0.001，节点与连线均不可拖拽；缩放平移由 `Background` 和 `Controls` 提供，另有 pin 按钮把视口固定；
- **交互**：分支指针 `history.currentId` 变化时，视图自动定位到当前消息，pin 状态下跳过；点击节点触发 `onNodeClick`，会话控制器据此调用 `showMessage`，沿 `childrenIds` 走到叶子、更新分支指针，并把主消息区滚动到该消息，即**点击树图节点等于切换到该消息所在分支**；活动路径的边带高亮动画（`View.svelte:51-57,124-133`）；
- **节点卡**：`Node.svelte`（123 行）显示用户或模型头像、名称与两行内容摘要，全文放在 Tooltip 里；assistant 卡片另有收藏按钮，收藏只改本地 `message.favorite` 状态，刷新后恢复原状（静态推断）。

该视图是消息树的分支导航辅助，与发送链路共享同一棵 `history` 树，不创建新消息或独立视图状态。超大消息树上的渲染性能未运行验证。

## 7. 多会话、多模型、群聊与后台生成

- side-by-side：`MultiResponseMessages.svelte`（477 行）把多个模型的输出并排成多列，`modelIdx` 保留各列顺序；消息创建在 `Chat.svelte:2808-2845` 完成，每列可以单独重新生成，也可以合并（第 6 节）；
- 多会话：侧栏切换会话，每个会话各自持有一条 `chatRequestQueues` 队列；同一时间可以在多个会话并行生成，服务端按任务维度调度，前端用 `taskIds` 区分当前会话的活动任务（对话请求与上下文笔记第 8 节）；
- 群聊：`channel:` 前缀的会话由服务端 `_make_channel_emitter` 向 `events:channel` 房间推送消息（`socket/main.py:898-965`）；前端频道界面的详细工作流本次未调查；
- Direct Connection 的界面形态本次未调查。

## 8. Chat UI 状态所有权与同步

- 会话状态机内聚在 `Chat.svelte`：`history` 树是前端主状态，数据事实源在服务端（会话与消息管理笔记）；分支定位指针 `currentId` 与任务 id、生成中、输入内容、参数、聊天文件等局部状态共同构成前端投影，字段见下：

  ```
  currentId / taskIds / generating / prompt / params / chatFiles
  ```
- 生成状态以服务端广播为准：前端收到 `chat:active=false` 就清空 taskIds 并按需重载；静态代码确认了事件绑定，实际重载时机未运行验证（`Chat.svelte:975-984`）。
- 多窗口/多端同步：Socket.IO 事件广播使其他标签页收到生成事件；队列属于前端 store，草稿属于 sessionStorage，均没有账户级同步。桌面/移动端连续性（PWA 等）未调查；
- 标签工作台的打开列表、活动标签和最近激活历史在组件内存，关闭活动标签回到最近使用项；既有聊天 id 切换时重置，首次空 id 取得真实 id 时保留现场。只有侧边/全宽布局偏好写入 localStorage。文件编辑器在路由离开前逐个询问未保存修改，因此面板恢复应与聊天历史恢复区分（[`ChatTabs/tabs.ts:46-89`](../../open-webui/src/lib/components/chat/ChatTabs/tabs.ts#L46-L89)、[`ChatTabs.svelte:625-635,695-714`](../../open-webui/src/lib/components/chat/ChatTabs.svelte#L625-L714)）；
- Socket 重连时，临时聊天调用 resume API 重新绑定会话并取回 task id 与服务端流快照，用于补齐仍在内存的消息树；它没有聊天数据库持久化保证。持久聊天则查询活动任务，必要时重新加载服务端快照。浏览器刷新后重建全部临时消息的能力未确认（[`Chat.svelte:1895-1933`](../../open-webui/src/lib/components/chat/Chat.svelte#L1895-L1933)、[`main.py:2164-2179`](../../open-webui/backend/open_webui/main.py#L2164-L2179)）。

## 9. 键盘、焦点、响应式与关键路径可用性

- 静态代码确认的键盘路径有三处：输入区的 `onKeyDown` 处理 Shift 状态记录、听写快捷键 `matchKeybinding` 与 Escape 取消拖拽；提交后控制器把焦点交回输入框；侧栏"新建会话"按钮带固定 id，供快捷键或自动化触发（`MessageInput.svelte:1101-1125`、`Chat.svelte:2533-2534`、`Sidebar.svelte:912-919`）；
- 焦点顺序、Tab 走查、aria 完整性与响应式断点行为（移动端抽屉、`$mobile` 分支）**未运行验证**；
- 发送与停止的入口及事件绑定已核实；键盘能否走完全部聊天关键路径（选择会话→输入→发送→停止→消息操作）未实测。

## 10. 设计取舍与已确认边界

- 前端只维护 history 快照的投影与导航（currentId、消息树图、队列），权威数据在服务端——临时会话 `temporary` ID 的存在说明发送前状态仍在客户端一侧；
- 分支导航（Overview）与数据语义分离：树图只读、不创建新消息，分支数据（parentId/childrenIds）由服务端与消息表共同维护（会话与消息管理笔记）；
- 流式反馈完全走 Socket.IO 事件而非前端轮询，REST 只负责发起与终止任务，前端按钮状态与真实任务状态靠事件对齐；
- 界面细节覆盖有限是本笔记的已知边界，不是项目能力结论；频道/Direct Connection 界面形态未调查。

## 11. 未验证事项

- 会话列表界面交互（拖放分组、置顶操作流）、Composer 深层交互（命令语法、附件失败恢复）未调查；
- Overview 树图在超大消息树上的渲染性能未验证；
- 键盘焦点顺序、响应式断点行为、多标签页并发提交的队列行为未运行验证；
- 收藏按钮仅本地更新（`Node.svelte:63-78`，静态推断），其持久化路径未找到。

## 12. 关键源码索引

- 前端会话状态机：[`src/lib/components/chat/Chat.svelte`](../../open-webui/src/lib/components/chat/Chat.svelte)（`showMessage` 1249、`chatEventHandler` 1462、`processNextInQueue` 3187、`submitPrompt` 3667、`sendMessage` 4118、`stopResponse` 4681）
- 输入区：[`src/lib/components/chat/MessageInput.svelte`](../../open-webui/src/lib/components/chat/MessageInput.svelte)
- 右侧工作台与 Overview 入口：[`src/lib/components/chat/ChatTabs.svelte`](../../open-webui/src/lib/components/chat/ChatTabs.svelte)（479、792-818 行）、[`ChatTabs/tabs.ts`](../../open-webui/src/lib/components/chat/ChatTabs/tabs.ts)
- Overview 消息树图：[`src/lib/components/chat/Overview/`](../../open-webui/src/lib/components/chat/Overview/)（`View.svelte` 65-140、`Flow.svelte`、`Node.svelte`）
- 会话侧栏与搜索：[`src/lib/components/layout/Sidebar.svelte`](../../open-webui/src/lib/components/layout/Sidebar.svelte)、[`SearchModal.svelte`](../../open-webui/src/lib/components/layout/SearchModal.svelte)
- 前端 store：[`src/lib/stores/index.ts`](../../open-webui/src/lib/stores/index.ts)（`chatRequestQueues` 148）
