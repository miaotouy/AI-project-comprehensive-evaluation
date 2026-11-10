# AstrBot Chat UI 调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：只读源码与历史快照差异交叉定位；重点核实消息历史分页、编辑与重生成的线程级联、可移植按钮的前后端接线；视觉、焦点顺序、键盘可用性未运行验证
>
> 调查范围：项目自带的 WebChat（/chat 与 /chatbox 两个入口）与 Dashboard 管理界面（对话管理、会话规则、追踪、统计）；QQ、Telegram 等外部 IM 客户端的界面不归项目所有，不在本笔记范围；弹窗/Toast/主题/动画等通用 UI 盘点按 Chat UI 类目过滤规则不纳入正文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 主要面向外部 IM 平台（QQ/Telegram/Discord/微信），这些平台客户端的聊天界面不归 AstrBot 所有。按 Chat UI 类目适用性规则，本笔记只覆盖项目自带界面：**WebChat**（Dashboard 内嵌聊天工作台）与 **Dashboard 管理界面**。

- **聊天主链**：聊天请求从工作台进、以流式事件出。`Chat.vue` 承载侧栏会话列表、消息区与 Composer，`useMessages.ts` 用 SSE 与 WebSocket 两条通道提交并消费流，事件先进入 webchat 队列，再并入与外部 IM 共用的同一套事件总线与流水线。执行语义见对话请求与上下文笔记；scheduler 结束时以结束事件刷新 UI，两条提交入口为 SSE 的 `POST /api/v1/chat` 与 WebSocket 的 `/api/v1/unified-chat/ws`，刷新点见 `scheduler.py:99-100`。
- **历史改为分页恢复**：首次只取最新 50 条，滚动接近顶部时加载上一页并保持首条可见消息的屏幕位置；分页响应带回 `total/page/page_size/has_more` 四个字段，加载失败时给出独立的重试表面。运行中的 bot 消息仍通过 active_runs 快照恢复并重连（`astrbot/dashboard/services/chat_service.py:1603-1667`；`dashboard/src/composables/useMessages.ts:293-441`；`components/chat/Chat.vue:1872-1917`）。
- **聊天设置集中到独立对话框**：主题、语言、流式开关、推理显示、发送快捷键与 SSE/WebSocket 传输模式都从 Composer 周边收进 `ChatSettingsDialog`，对话框本体见 `dashboard/src/components/chat/ChatSettingsDialog.vue:1-190`；其中推理开关随发送、编辑续写与重生成请求一起传给后端（`Chat.vue:210-216,1334-1350`；`useMessages.ts:530-559,645-681`）。
- **消息操作完整**：编辑（仅最新用户消息）、重生成（仅最新 turn）、选中文本创建侧线程（thread）、推理/引用面板——入口在 ChatMessageList，执行语义在会话与消息管理笔记 §4。
- **按钮消息可交互**：bot 消息中的按钮行由 `ButtonActionRow.vue` 渲染，URL 按钮打开新窗口，回调按钮把回调载荷作为一条 `button_interaction` 记录发给后端，后端在构建请求时跳过该记录的用户历史写入（`Chat.vue:822-832`、`useMessages.ts:570-599`、`chat_service.py:1810-1825`）。
- **追踪可下钻**：消息旁的追踪预览组件展示该条回复的 trace 摘要，点击进入追踪详情（`components/shared/TraceMessagePreview.vue`）。
- **Live Mode 前端当前未挂载**：`LiveMode.vue` 存在但全仓库没有 import，只有 ChatInput.vue 发出打开事件，且按钮已注释；后台 `/api/v1/live-chat/ws` 与 live agent 执行路径仍保留（`live_chat.py:35-37`；`internal.py:293-329`）。

## 工作台边界与用户主链

```text
进入 /chat（ChatPage.vue）或 /chatbox（ChatBoxPage.vue，全屏独立模式）
  → Chat.vue 工作台：侧栏 ProjectList 会话/项目列表；主区消息列表 + Composer
  → 选择或新建会话（无会话时发送消息自动 newSession 并跳转路由）
  → Composer 组装 parts（文本/附件/回复引用/媒体）→ sendMessageStream
      SSE: POST /api/v1/chat → ChatService.build_chat_stream → webchat 队列 → 流水线
      WS:  /api/v1/unified-chat/ws → LiveChatService（统一通道）
  → 流式事件回传（run_started/plain/tool_call/agent_stats/complete/end...）渲染到 bot 记录
  → 停止/编辑/重生成/线程操作 → 对应 chat API
  → 切换会话/刷新：内存保留已加载会话，active_runs 快照恢复运行中生成
```

WebChat 与外部 IM 共享同一套事件模型，WebChat 界面只负责呈现结果。管理界面（对话管理、会话规则、追踪、统计）位于同一 Dashboard，作为辅助表面单列。

## 1. 页面结构、导航与多窗口

- **入口与路由**：两个入口共用同一个工作台组件。`/chat` 由一层 15 行的壳组件承载，`/chatbox` 走全屏独立模式路由，两者最终都渲染 `components/chat/Chat.vue`（`router/MainRoutes.ts:259-265`、`router/ChatBoxRoutes.ts:2-13`）。
- **工作台拓扑**：侧栏是会话与项目列表；主区有 Provider 工作台、项目视图（项目 + Composer）、常规会话视图（消息区 + Composer）三种形态，入口挂在 `Chat.vue`。消息区与 Composer 分离，推理、引用与线程都以侧边抽屉呈现（`Chat.vue:104,328-332,348-389,391-475,535-540`）。
- **侧栏折叠**：桌面端可折叠、移动端收成抽屉，由 customizer store 控制，按 lgAndUp 断点切换；响应式细节未运行验证（`Chat.vue:836-872`）。
- **多窗口**：同一会话可被多个标签页同时连接，后端按会话维护 SSE 订阅者集合并在 revision 变化时广播，同会话也可并行多个 run（chat_runs 表）。前端各窗口独立持有消息状态，本次静态检查未发现 BroadcastChannel 或 storage 事件一类的跨窗口同步机制（`chat_service.py:958-977`）。

## 2. 会话列表、搜索与现场恢复

- **会话列表**：ProjectList 渲染 `chatApi.listSessions` 返回的会话行（`useSessions.ts:34-48`），支持新建、删除、批量删除与重命名：新建后绑定所选配置 profile 并跳转路由，批量删除按失败项判断当前会话是否已被删除，重命名走对话框。会话可归入项目（`ChatUIProject`）分组，项目展开时懒加载其中的会话，项目内的会话也能单独改标题或删除（`Chat.vue:1271-1285,1391-1421`）。
- **搜索与列表覆盖范围**：会话搜索在管理页提供（对话管理页 conversationApi 的 ilike 搜索，见会话与消息管理笔记 §5），WebChat 工作台内本次未找到会话搜索框。普通会话侧栏读取的后端入口固定取最新 100 行、排除项目会话并丢弃总数；它与消息历史的向前翻页是两条链路，未发现该列表入口的续页控件（`astrbot/dashboard/services/chat_service.py:1571-1594`；`dashboard/src/components/chat/Chat.vue` 会话列表模板）。
- **标题**：首条消息自动取前 40 字作为标题，这一步只更新前端内存对象，不调用持久化 API；持久化标题只在用户手动重命名时写入，走 `chatApi.updateSession`（`Chat.vue:1215-1247,1684-1708`）。
- **现场恢复**：切换或进入会话时，`loadSessionMessages` 一次性取历史、线程与运行中任务快照；`restoreNextActiveRun` 再把仍在运行的 run 以占位加载态插回消息列表并启动恢复流，恢复流最多重连 5 次且按指数退避，收到结束事件才停止（`useMessages.ts:267-313,679-764`）。滚动锚定上，视图距底 80px 以内吸底，流式更新时同样跟随（`Chat.vue:808-812,1979-1997`）。

## 3. Composer、草稿、附件与快捷输入

- **Composer**：由 `ChatInput.vue` 实现，单行 input 与多行 textarea 两种形态按内容自动切换，高度自适应，移动端另设上限（`ChatInput.vue:613-673`）；发送后清空输入并回焦（`Chat.vue:1399,1637`）。
- **发送快捷键**：`sendShortcut` 决定 Enter 与 Shift+Enter 的行为，默认 enter 即回车发送，Ctrl/Meta+Enter 恒为发送；输入法组合输入期间由 `isComposingEnter` 拦下误触发（`Chat.vue:817`；`ChatInput.vue:834-871`）。
- **命令建议**：输入以唤醒前缀开头时弹出 CommandSuggestion，方向键移动、Enter 选中、Esc 关闭（`ChatInput.vue:775-793,803-832`）。
- **草稿**：`draft` 仍是组件内存 ref，不按会话持久化；切换会话会保留当前组件实例中的文本，刷新后丢失。
- **附件**：图片、音频与文件经媒体处理 composable 上传为附件并做 staging 预览（`Chat.vue:740-757`）；大文件走分片上传接口，按初始化、分片、完成、中止、状态查询五个动作完成，落盘名由附件名经去重逻辑生成（`chunked_upload_service.py`；`chat_service.py:66` 起）。拖放热区覆盖整个聊天区域，拖入时显示全区遮罩，松手后与选择文件走同一条上传链路；粘贴图片直接上传，Composer 内另有录音按钮与 Ctrl+B 长按录音（`useDragUpload.ts:7-47`；`ChatInput.vue:837-847`）。
- **回复引用**：消息操作栏触发 `replyTarget`，发送时作为 reply part 一并携带（`Chat.vue:1661-1669`）。

## 4. Agent、模型、工具与发送前配置

- **发送前配置**：Composer 提供 Provider 与模型菜单，选择结果写入组件的选中字段并记忆到 localStorage，随每次发送传给后端；同一区域还有流式开关与配置 profile 选择器，profile 列表取自 `/api/v1/chat/configs`。菜单组件为 `components/shared/ProviderSelectMenu.vue`，接线、持久化与 profile 选择器见 `Chat.vue:1277-1281,1642-1652,1687-1689`、`ChatInput.vue:212`、`chat.py:249-254`。
- **作用域可辨认性**：provider/模型选择是"本次请求参数"（随消息发送，不落会话表，语义见会话与消息管理笔记 §8 模型不绑定）；配置 profile 与会话的绑定由后端 `configRouteApi` 完成（`useSessions.ts:87-94`）。参数透传已由静态代码确认，UI 上是否标注作用域未运行验证。
- **会话级规则**：管理界面的会话管理页按 UMO 配置 persona（字段为 `session_service_config.persona_id`），另有批量设置 provider 与分组，操作位置在 `SessionManagementPage.vue:512,1624-1647`；数据语义见会话与消息管理笔记 §8。

## 5. 发送、排队、流式反馈与停止

- **发送**：发送入口先处理会话与项目：无会话时新建会话并跳转路由，在项目内发送则把消息关联到该项目并刷新列表；随后在本地插入 user/bot 两条占位记录，bot 占位显示加载态。真正传输按当前模式二选一：SSE 由 AbortController 管理，WebSocket 每个会话一条连接（`useMessages.ts:325-380,615-677,766-802`；`Chat.vue:1592-1659`）。
- **流式反馈**：`processStreamPayload`（useMessages.ts:1042-1218）逐事件更新 bot 记录：
  - 运行定位与快照恢复：`run_started`、`run_snapshot`；
  - 本地占位替换为持久化 ID：`user_message_saved`/`message_saved`（:1059-1078）；
  - 统计写入：`agent_stats`；
  - 用户插话移到运行中 bot 之前：`follow_up_captured`（:1004-1032）；
  - 普通文本/推理/工具调用增量合并（:1113-1129），错误以文本追加到消息底部（:1084-1088）。
- **运行状态对应**：会话是否在跑由 `isSessionRunning` 判断，依据是活跃连接表中存在该会话的连接；运行期间 Composer 禁用输入并换成停止按钮，消息编辑入口同样禁用（`useMessages.ts:178-182`；`Chat.vue:393,420-422`）。
- **停止**：Composer 的停止按钮调 `stopCurrentSession`，经 `chatApi.stopSession` 打到后端的 `request_agent_stop_all`，执行软停并保留历史；前端不主动 abort fetch，等后端事件收尾（`ChatInput.vue:369-375`；`chat_service.py:1393-1402`，语义见对话请求与上下文笔记 §7）。
- **排队**：前端没有显式排队界面；同一会话并发发送会产出多个 run，follow-up 机制在后端处理，前端只把新插入的用户消息排到运行中 bot 记录之前（`useMessages.ts:1056-1084`）。限流与 stall 反馈落在 IM 平台侧，WebChat 内本次静态检查未找到排队提示。

## 6. 消息操作、分支与版本导航

- **编辑**：编辑从消息操作栏进入，保存时调 `chatApi.updateMessage`；保存成功且需要重新生成时，前端自动续写，或重生成下一条 bot 回复（`Chat.vue:1740-1744,1764-1784`；`useMessages.ts:422-484`）。只有最新一条用户消息可以编辑，运行期间入口禁用，后端另有校验（语义见会话与消息管理笔记 §4）。
- **重生成**：RegenerateMenu 允许先选模型再重生成，前端重连 SSE 并用新的 bot 占位替换旧记录（`Chat.vue:1792-1806`；`useMessages.ts:497-569`）。
- **侧线程（分支）**：选中 bot 消息的文本会弹出"在 Thread 中提问"浮钮，点击后调 `chatApi.createThread` 建立侧线程，ThreadPanel 内可继续对话或删除线程，ThreadNode 负责把入口挂到对应消息上（`Chat.vue:515-533,1549-1665`）。
- **推理与引用**：推理内容有消息内折叠块与 ReasoningSidebar 两种呈现，引用走 RefsSidebar；两个面板互斥，打开其一就关闭另一个（`Chat.vue:1625-1647`）。
- **版本导航与线程保留**：当前消息操作未提供版本树或旧回答切换入口。编辑最新用户消息会删除其后显示消息，重生成会删除旧 bot 记录；两条服务路径还会清除这些被删记录所关联的侧线程及其独立会话。因此侧线程在创建后可独立对话，但仍受父消息删除级联约束（`astrbot/dashboard/services/chat_service.py:1925-1944,2037-2053`）。
- **删除**：删除会话前弹确认对话框，线程删除同样需要确认，两者都走 `askForConfirmation`（`Chat.vue:1488-1499,1649-1665`）。

## 7. 多会话、多模型、群聊与后台生成

- **多会话**：消息按会话分桶缓存在内存里，切换会话就是切换当前桶，已加载过的会话不重复拉取；生成状态按全局判断是否有任一会话在跑，当前会话的 bot 记录另带流式标记（`useMessages.ts:145-158`；`Chat.vue:452-454`）。
- **多模型**：每次发送可选不同 provider/模型（§4）；重生成可选择模型（§6）。同一会话内不同 run 的模型差异体现在各自请求参数，无统一"多模型对比"视图（静态检查未找到）。
- **群聊**：WebChat 全部是私聊形态（`is_group` 未实现，po.py:335-336 注释）；群聊上下文/主动回复功能作用于 IM 平台（请求侧笔记 §9），WebChat 工作台无群聊 UI。
- **后台生成**：切走会话后生成继续（后端 run 独立于订阅者）；返回会话时以 active_runs 恢复（§2）。项目视图与常规视图共享同一 Chat 组件状态。

## 8. Chat UI 状态所有权与同步

| 状态 | 位置 | 恢复方式 |
|---|---|---|
| 消息列表 messagesBySession / 已加载 loadedSessions | useMessages 内存（:143-144） | 重新加载会话 |
| 活跃连接 activeConnections / WS 连接表 | useMessages 内存（:145-147） | 组件卸载 cleanupConnections（:160-166）；刷新后 active_runs 恢复 |
| draft（草稿） | Chat.vue:782 内存 ref | 不持久化，刷新丢失 |
| 编辑状态 editingMessage / messageEditDraft | Chat.vue:704-706 内存 | 刷新丢失 |
| 线程选择浮钮 threadSelection | Chat.vue:802-815 内存 | 滚动即隐藏（:1713-1715） |
| 传输模式 transportMode | localStorage（:815-832） | 刷新保留 |
| 选中 provider/模型 | localStorage（:954-955） | 刷新保留 |
| 项目展开状态 projectExpandedIds | localStorage（ProjectList.vue:221-230） | 刷新保留 |
| 侧栏折叠/主题 | customizer store | 刷新保留 |
| 吸底滚动 shouldStickToBottom | Chat.vue:789 内存 | 滚动行为重置 |

跨窗口无状态同步（§1 多窗口）；SSE/WS 连接在组件卸载时全部中止（useMessages.ts:170-176、:565-576）。

## 9. 键盘、焦点、响应式与关键路径可用性

- **会话选择**：会话列表项响应 Enter 与 Space，用于选中会话（`Chat.vue:145-146`）。
- **Composer**：Enter 与 Shift+Enter 发送消息，方向键、Enter 与 Esc 用于命令建议（§3）；发送后自动回焦，选中会话后同样回焦（`Chat.vue:1339,1999-2004`）。
- **对话框**：会话标题编辑对话框内 Enter 即保存，确认类对话框统一走 `askForConfirmation`（`Chat.vue:559`；`utils/confirmDialog`）。
- **响应式**：侧栏在移动端变为抽屉（customizer 控制，§1）；textarea 高度按视口限制（§3）。焦点顺序、断点视觉与无障碍名称需运行验证。

## 10. 设计取舍与已确认边界

- **双通道传输**：默认走 SSE（长轮询式流），WebSocket 作为可切换通道，由 `chat.transportMode` 决定；两条通道在后端统一走 back_queue 与订阅者广播，前端按事件类型合并处理，传输差异封装在消息层。
- **本地占位 + 服务端确认**：发送先在本地渲染 user/bot 占位，收到 `user_message_saved`、`message_saved` 后再换成持久化 ID；网络失败时错误文本追加到 bot 消息底部，本次未找到重试按钮级的恢复入口（`useMessages.ts:714-719`）。
- **恢复优先**：刷新/重连先走 active_runs 快照 + resume stream，不需要重新拉全量历史。
- **编辑/重生成的"仅最新"约束**：UI 允许对任意 bot 消息点重生成，但后端只放行最新 checkpoint，旧 turn 重生成报错（数据语义在会话与消息管理笔记 §4）。
- **Live Mode 前端未挂载**：前端组件没有挂载点，触发按钮已注释，`/astr_live_dev` 秘密命令发出的事件没有监听者；后端 live-chat WS 与 run_live_agent 路径仍在，界面侧当前不可达（`ChatInput.vue:322`，未运行验证）。
- **按钮回调的独立链路**：按钮点击产生的 `button_interaction` 记录由前端发出，后端在构建请求时跳过用户历史写入，交互结果作为 bot 侧回复落回会话；同一套按钮在 IM 平台按各平台能力降级（`chat_service.py:1810-1825`）。
- **界面边界**：通用 UI（Modal/Toast/主题/动画）只记录与聊天主链的交点（错误、删除、创建反馈经 toast 与确认对话框出现），不做全仓库盘点；QQ、Telegram、Discord、微信等第三方客户端 UI 不在范围内，项目拥有的是 WebChat（webchat 平台适配器）与 Dashboard。

## 11. 未验证事项

- 视觉效果、焦点顺序、无障碍名称、响应式断点行为与系统通知：静态代码无法确认，未运行验证。
- 多窗口/多标签页同时操作同一会话的竞态表现未运行验证（后端无跨窗口锁，见会话与消息管理笔记 §10）。
- Live Mode 在当前快照的运行时行为未验证（组件未挂载，仅确认代码状态）。
- 会话搜索：WebChat 工作台未找到搜索入口，管理页搜索未运行验证。
- 网络中断时的重试体验（SSE 断流后除 resume 外无自动重试按钮）未运行验证。

## 12. 关键源码索引

- 工作台：`dashboard/src/components/chat/Chat.vue`、`views/ChatPage.vue`、`views/ChatBoxPage.vue`、`router/MainRoutes.ts`、`router/ChatBoxRoutes.ts`
- 消息流：`dashboard/src/composables/useMessages.ts`（SSE/WS/恢复/编辑/重生成）、`useSessions.ts`、`useDragUpload.ts`、`useMediaHandling.ts`
- 组件：`components/chat/ChatInput.vue`、`ChatMessageList.vue`、`ButtonActionRow.vue`、`ProjectList.vue`、`ProjectView.vue`、`ThreadPanel.vue`、`ProviderModelMenu.vue`、`ConfigSelector.vue`、`ChatSettingsDialog.vue`、`LiveMode.vue`、`components/shared/TraceMessagePreview.vue`
- 后端聊天接口：`astrbot/dashboard/api/chat.py`、`api/live_chat.py`、`services/chat_service.py`、`services/chunked_upload_service.py`
- WebChat 适配：`astrbot/core/platform/sources/webchat/webchat_adapter.py`、`webchat_event.py`、`webchat_queue_mgr.py`
- 管理界面：`views/ConversationPage.vue`、`views/SessionManagementPage.vue`、`views/TracePage.vue`、`views/stats/StatsPage.vue`
