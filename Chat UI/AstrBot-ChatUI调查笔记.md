# AstrBot Chat UI 调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：直接阅读源码（Dashboard 前端 Vue 组件与 composables、FastAPI 聊天接口、WebChat 平台适配器），行号按当前 HEAD 逐一核对；视觉、焦点顺序、键盘可用性等需运行确认的项标注"未运行验证"
>
> 调查范围：项目自带的 WebChat（/chat 与 /chatbox 两个入口）与 Dashboard 管理界面（对话管理、会话规则、追踪、统计）；QQ、Telegram 等外部 IM 客户端的界面不归项目所有，不在本笔记范围；弹窗/Toast/主题/动画等通用 UI 盘点按 Chat UI 类目过滤规则不纳入正文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 主要面向外部 IM 平台（QQ/Telegram/Discord/微信），这些平台客户端的聊天界面不归 AstrBot 所有。按 Chat UI 类目适用性规则，本笔记只覆盖项目自带界面：**WebChat**（Dashboard 内嵌聊天工作台）与 **Dashboard 管理界面**。

- **聊天主链**：`Chat.vue` 工作台（会话列表 + 消息区 + Composer）→ `useMessages` 以 SSE 或 WebSocket 双通道提交并消费流式事件（POST `/api/v1/chat`、`/api/v1/unified-chat/ws`）→ 事件进入 webchat 队列 → 与外部 IM 共享同一套事件总线 + 流水线（执行语义在对话请求与上下文笔记）；`scheduler.execute` 结束时以结束事件刷新 UI（scheduler.py:94-95）。
- **现场恢复是显式设计的**：刷新页面后 `loadSessionMessages` 携带 `active_runs` 快照重建运行中的 bot 消息并重连 `/chat/runs/{id}/stream`（useMessages.ts:257-313）。
- **消息操作完整**：编辑（仅最新用户消息）、重生成（仅最新 turn）、选中文本创建侧线程（thread）、推理/引用面板——入口在 ChatMessageList，执行语义在会话与消息管理笔记 §4。
- **Live Mode 前端当前未挂载**：`LiveMode.vue` 存在但全仓库无 import（仅 ChatInput.vue 的 `openLiveMode` 事件发射，按钮已注释），后台 `/api/v1/live-chat/ws` 与 `run_live_agent` 路径仍保留（live_chat.py:35-37；internal.py:293-329）。

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

WebChat 与外部 IM 共享同一套事件模型；界面只是结果的投递表面之一。管理界面（对话管理、会话规则、追踪、统计）位于同一 Dashboard，作为辅助表面单列。

## 1. 页面结构、导航与多窗口

- **入口与路由**：`/chat` 与 `/chatbox` 两个入口（分别由 15 行壳组件与全屏独立模式路由承载）都渲染 `components/chat/Chat.vue`（router/MainRoutes.ts:244-250、ChatBoxRoutes.ts:2-13）。
- **工作台拓扑**（`Chat.vue`）：侧栏含会话/项目列表（:104）；主区（:328-332 挂拖放热区）分三种形态——Provider 工作台、项目视图（项目 + Composer，:348-389）、常规会话视图（消息区 + Composer，:391-475）。消息区与 Composer 分离，无独立辅助面板；推理/引用/线程以侧边抽屉呈现（:535-540）。
- **侧栏折叠**：桌面折叠/移动端抽屉由 `customizer` store 控制（Chat.vue:751-772，lgAndUp 断点切换行为，未运行验证响应式细节）。
- **多窗口**：同一会话可由多标签页连接——SSE 订阅者集合与 revision 广播在后端（chat_service.py:774-793）；同会话多 run 并行（chat_runs 表）。前端各窗口独立持有消息状态，无跨窗口同步机制（未发现 BroadcastChannel/storage 事件，静态检查）。

## 2. 会话列表、搜索与现场恢复

- **会话列表**：ProjectList 展示 `chatApi.listSessions` 返回的会话行（useSessions.ts:34-48），支持新建（创建后绑定所选配置 profile 并跳转路由）、删除、批量删除（按失败项判定当前会话是否被删）、重命名（对话框）等操作。会话可归入项目（`ChatUIProject`）分组，项目展开时懒加载会话（Chat.vue:1161-1188），项目内会话可独立编辑标题/删除（:1271-1285）。
- **搜索**：会话数据层搜索在管理页（对话管理页 conversationApi 的 ilike 搜索，见会话与消息管理笔记 §5）；WebChat 工作台内本次未找到会话搜索框（静态检查 Chat.vue 模板）。
- **标题**：首条消息自动取前 40 字作为标题只更新前端内存对象（Chat.vue:1426-1450），不调用持久化 API；持久化标题仅发生在用户手动重命名（:1215-1247 → `chatApi.updateSession`）。
- **现场恢复**：`loadSessionMessages`（useMessages.ts:257-283）加载历史 + 线程 + 运行中任务快照；`restoreNextActiveRun`（:285-313）把运行中 run 的快照插回消息列表（占位加载态）并启动恢复流（:679-764，5 次指数退避重连，收到结束事件才停）。滚动锚定：距底 80px 内吸底（Chat.vue:1713-1729），流式更新时吸底滚动（:808-812）。

## 3. Composer、草稿、附件与快捷输入

- **Composer**（ChatInput.vue）：单行 input + 多行 textarea 双形态，按内容自动切换与自动高度（:613-673，移动端高度上限 :632-640）；发送后清空并回焦（Chat.vue:1379、:1399）。
- **发送快捷键**：Enter/Shift+Enter 由 `sendShortcut`（默认 enter，Chat.vue:744）决定，Ctrl/Meta+Enter 恒为发送；IME 组合输入用 `isComposingEnter` 防误发（ChatInput.vue:720-757）。
- **命令建议**：输入以唤醒前缀开头时显示 CommandSuggestion，方向键/Enter 选中、Esc 关闭（ChatInput.vue:689-718、:775-793）。
- **草稿**：`draft` 是组件内存 ref（Chat.vue:711、StandaloneChat.vue:258、ThreadPanel.vue:94 各持一份），**不持久化**（localStorage 仅存传输模式、provider/模型选择与项目展开状态，静态检查）；切换会话清空 replyTarget 但保留 draft 值本身（draft 未按会话分组，属全局草稿——静态推断）。
- **附件**：图片/音频/文件经媒体处理 composable 上传为附件并 staging 预览（Chat.vue:667-680）；拖放热区为整个聊天区域（useDragUpload.ts:7-47，拖入显示全区遮罩 Chat.vue:333-340），松手后与选择文件走同一上传链路（Chat.vue:682-685）；粘贴图片直接上传；录音按钮 + Ctrl+B 长按录音（ChatInput.vue:723-733）。
- **回复引用**：消息操作触发 `replyTarget`，发送时作为 `reply` part 携带（Chat.vue:1403-1411）。

## 4. Agent、模型、工具与发送前配置

- **发送前配置**：Composer 提供 Provider/模型菜单（选好后写入选中字段并记忆到 localStorage，`ProviderModelMenu.vue:217-229`），随每次发送传给后端（Chat.vue:1384-1394）；另有流式开关（:1687-1689）与配置 profile 选择器（ChatInput.vue:144，数据来自 `/api/v1/chat/configs`，chat.py:247-252）。
- **作用域可辨认性**：provider/模型选择是"本次请求参数"（随消息发送，不落会话表，见会话与消息管理笔记 §8 模型不绑定）；配置 profile 绑定到会话由后端 `configRouteApi` 完成（useSessions.ts:59-66）。静态代码确认参数透传，UI 上是否明确标注作用域未运行验证。
- **会话级规则**：管理界面 SessionManagementPage.vue 按 UMO 配置 persona（`session_service_config.persona_id` :512）、批量 provider、分组（:1624-1647）；数据语义在会话与消息管理笔记 §8。

## 5. 发送、排队、流式反馈与停止

- **发送**：`sendCurrentMessage`（Chat.vue:1342-1401）——无会话时先新建并跳转，项目内发送则关联项目并刷新列表；本地先建 user/bot 占位记录（bot 占位显示加载态，createLocalExchange，useMessages.ts:315-369）；随后按传输模式走 SSE（`startSseStream` :615-677，AbortController 管理）或 WebSocket（`startWebSocketStream` :766-802，每会话一个 WS 连接）。
- **流式反馈**：`processStreamPayload`（useMessages.ts:990-1160）逐事件更新 bot 记录：
  - 运行定位与快照恢复：`run_started`、`run_snapshot`；
  - 本地占位替换为持久化 ID：`user_message_saved`/`message_saved`（:1059-1078）；
  - 统计写入：`agent_stats`；
  - 用户插话移到运行中 bot 之前：`follow_up_captured`（:1004-1032）；
  - 普通文本/推理/工具调用增量合并（:1113-1129），错误以文本追加到消息底部（:1084-1088）。
- **运行状态对应**：`isSessionRunning` = activeConnections 中存在该会话连接（useMessages.ts:168-172）；运行时 Composer 禁用输入（Chat.vue:363）并显示停止按钮，消息编辑入口禁用（:420-422）。
- **停止**：Composer 停止按钮（ChatInput.vue:285-291）→ `stopCurrentSession` → `chatApi.stopSession` → 后端 `request_agent_stop_all`（软停，保留历史，chat_service.py:1204-1213；语义见对话请求与上下文笔记 §7）。前端不主动 abort fetch，靠后端事件结束。
- **排队**：无显式排队 UI；同会话并发发送产生多个 run（follow-up 机制在后端，前端以"用户消息插到运行中 bot 之前"呈现，useMessages.ts:1004-1032）。限流 stall 反馈在 IM 平台侧，WebChat 无排队提示（静态检查未找到）。

## 6. 消息操作、分支与版本导航

- **编辑**：消息操作栏打开编辑（Chat.vue:1482-1486），保存调 `chatApi.updateMessage`（useMessages.ts:411-436）；成功且需要重新生成时自动续写（:448-484）或重生成下一条 bot（Chat.vue:1505-1525）。仅最新用户消息可编辑、运行时禁用（后端校验见会话与消息管理笔记 §4）。
- **重生成**：RegenerateMenu 可选择模型后重生成（Chat.vue:1533-1547 → useMessages.ts:486-558，SSE 重连并替换 bot 占位）。
- **侧线程（分支）**：选中 bot 消息文本弹出"在 Thread 中提问"浮钮（Chat.vue:480-492、:1549-1578）→ `chatApi.createThread`（:1580-1614）→ ThreadPanel 内继续对话/删除线程（:1616-1665）；ThreadNode 把线程入口挂到消息上。
- **推理与引用**：reasoning 折叠块与 ReasoningSidebar（`openReasoningPanel` :1636-1647）、引用 RefsSidebar（:1625-1634），面板互斥（打开其一关闭其他）。
- **版本导航**：无版本树/版本切换 UI（数据层也无版本保留，见会话与消息管理笔记 §4）；"分支"只有线程一种形态。
- **删除**：会话删除带确认对话框（`askForConfirmation`，Chat.vue:1253-1264）；线程删除同样确认（:1649-1665）。

## 7. 多会话、多模型、群聊与后台生成

- **多会话**：消息按会话分桶缓存在内存（useMessages.ts:143-144），切换会话即切换桶（activeMessages computed :154-158），已加载会话不重复拉取；生成状态全局判断任一会话是否在跑，当前会话的 bot 记录带流式标记（Chat.vue:417-419）。
- **多模型**：每次发送可选不同 provider/模型（§4）；重生成可选择模型（§6）。同一会话内不同 run 的模型差异体现在各自请求参数，无统一"多模型对比"视图（静态检查未找到）。
- **群聊**：WebChat 全部是私聊形态（`is_group` 未实现，po.py:328-329 注释）；群聊上下文/主动回复功能作用于 IM 平台（请求侧笔记 §9），WebChat 工作台无群聊 UI。
- **后台生成**：切走会话后生成继续（后端 run 独立于订阅者）；返回会话时以 active_runs 恢复（§2）。项目视图与常规视图共享同一 Chat 组件状态。

## 8. Chat UI 状态所有权与同步

| 状态 | 位置 | 恢复方式 |
|---|---|---|
| 消息列表 messagesBySession / 已加载 loadedSessions | useMessages 内存（:143-144） | 重新加载会话 |
| 活跃连接 activeConnections / WS 连接表 | useMessages 内存（:145-147） | 组件卸载 cleanupConnections（:160-166）；刷新后 active_runs 恢复 |
| draft（草稿） | Chat.vue:711 内存 ref | 不持久化，刷新丢失 |
| 编辑状态 editingMessage / messageEditDraft | Chat.vue:704-706 内存 | 刷新丢失 |
| 线程选择浮钮 threadSelection | Chat.vue:730-742 内存 | 滚动即隐藏（:1713-1715） |
| 传输模式 transportMode | localStorage（:815-832） | 刷新保留 |
| 选中 provider/模型 | localStorage（:954-955） | 刷新保留 |
| 项目展开状态 projectExpandedIds | localStorage（ProjectList.vue:221-230） | 刷新保留 |
| 侧栏折叠/主题 | customizer store | 刷新保留 |
| 吸底滚动 shouldStickToBottom | Chat.vue:718 内存 | 滚动行为重置 |

跨窗口无状态同步（§1 多窗口）；SSE/WS 连接在组件卸载时全部中止（useMessages.ts:160-166、:565-576）。

## 9. 键盘、焦点、响应式与关键路径可用性

- **会话选择**：列表项支持 Enter/Space 选中（Chat.vue:135-136）。
- **Composer**：Enter/Shift+Enter 发送、方向键/Enter/Esc 操作命令建议（§3）；发送后自动回焦（`focusChatInput`，Chat.vue:1731-1736，selectSession 后同样回焦 :1339）。
- **对话框**：会话标题编辑对话框 Enter 保存（Chat.vue:516）；确认对话框走 `askForConfirmation`（utils/confirmDialog）。
- **响应式**：侧栏在移动端变为抽屉（customizer 控制，§1）；textarea 高度按视口限制（§3）。焦点顺序、断点视觉与无障碍名称需运行验证。

## 10. 设计取舍与已确认边界

- **双通道传输**：SSE 为默认（长轮询式流），WebSocket 为可切换通道（`chat.transportMode`），后端统一走 back_queue + 订阅者广播，前端按类型合并，传输差异被封装。
- **本地占位 + 服务端确认**：发送先本地渲染 user/bot 占位，收到 `user_message_saved`/`message_saved` 后替换为持久化 ID——网络失败时错误文本追加到 bot 消息（useMessages.ts:665-670），无重试按钮级恢复（本次未找到）。
- **恢复优先**：active_runs 快照 + resume stream 是刷新/重连的主恢复路径，优于重新拉全量历史。
- **编辑/重生成的"仅最新"约束**：UI 允许对任意 bot 消息点重生成，但后端只放行最新 checkpoint，旧 turn 重生成报错（数据语义在会话与消息管理笔记 §4）。
- **Live Mode 半成品**：前端组件未挂载、按钮注释（ChatInput.vue:254）、`/astr_live_dev` 秘密命令发射的事件无监听者；后端 live-chat WS 与 run_live_agent 仍在——界面侧当前不可达（未运行验证）。
- **通用 UI 盘点不在范围**：Modal/Toast/主题/动画等仅记录与聊天主链的交点（错误/删除/创建反馈经 toast 与确认对话框出现），不做全仓库盘点。
- **外部 IM 界面不归项目所有**：QQ、Telegram、Discord、微信等客户端 UI 是第三方表面，不在 Chat UI 调查范围；项目拥有的是 WebChat（webchat 平台适配器）与 Dashboard。

## 11. 未验证事项

- 视觉效果、焦点顺序、无障碍名称、响应式断点行为与系统通知：静态代码无法确认，未运行验证。
- 多窗口/多标签页同时操作同一会话的竞态表现未运行验证（后端无跨窗口锁，见会话与消息管理笔记 §10）。
- Live Mode 在当前快照的运行时行为未验证（组件未挂载，仅确认代码状态）。
- 会话搜索：WebChat 工作台未找到搜索入口，管理页搜索未运行验证。
- 网络中断时的重试体验（SSE 断流后除 resume 外无自动重试按钮）未运行验证。

## 12. 关键源码索引

- 工作台：`dashboard/src/components/chat/Chat.vue`、`views/ChatPage.vue`、`views/ChatBoxPage.vue`、`router/MainRoutes.ts`、`router/ChatBoxRoutes.ts`
- 消息流：`dashboard/src/composables/useMessages.ts`（SSE/WS/恢复/编辑/重生成）、`useSessions.ts`、`useDragUpload.ts`、`useMediaHandling.ts`
- 组件：`components/chat/ChatInput.vue`、`ChatMessageList.vue`、`ProjectList.vue`、`ProjectView.vue`、`ThreadPanel.vue`、`ProviderModelMenu.vue`、`ConfigSelector.vue`、`LiveMode.vue`
- 后端聊天接口：`astrbot/dashboard/api/chat.py`、`api/live_chat.py`、`services/chat_service.py`
- WebChat 适配：`astrbot/core/platform/sources/webchat/webchat_adapter.py`、`webchat_event.py`、`webchat_queue_mgr.py`
- 管理界面：`views/ConversationPage.vue`、`views/SessionManagementPage.vue`、`views/TracePage.vue`、`views/stats/StatsPage.vue`
