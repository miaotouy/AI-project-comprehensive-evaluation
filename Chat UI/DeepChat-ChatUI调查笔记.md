# DeepChat Chat UI 调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：从 [`../Chat/DeepChat-Chat调查笔记.md`](../Chat/DeepChat-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据
>
> 调查范围：ChatPage 工作台组合、pending input lane、plan/question/只读 interaction 浮层、搜索入口、renderer UI 状态所有权与子会话边界；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 Electron 桌面 GUI，聊天工作台由 ChatPage 单一页面组合：

- ChatPage（`ChatPage.vue:86-232`）组合消息列表、输入框、pending input lane、plan/question 浮层和只读 interaction overlay。
- 发送中的输入不拼进已完成消息，而是进入 pending lane，支持 queue/steer 交互，并新增 resume（恢复暂停队列）与 retry_required（释放后重试）动作（执行语义在对话请求与上下文笔记）。
- Composer 草稿按会话持久化到 localStorage（`composerDraftPersistence.ts`），切换会话与重启后恢复；provider 搜索（DeepSeek 原生 web 搜索）以开关进入发送前配置。
- subagent session 在 ChatPage 中只读，但仍能显示消息、plan、工具状态和最终 child result。
- 会话内查找（Cmd/Ctrl+F）与跨会话搜索入口并存；UI 状态（active session、working/error）由 Pinia store 持有。
- 键盘/焦点/响应式行为未运行验证（§8）。

## 工作台边界与用户主链

```text
ChatPage
  -> 消息列表（窗口化数据分页接口 -> 会话与消息管理 §5.1）
  -> 输入框 -> ChatClient.sendMessage / steer / queue（执行 -> 对话请求与上下文）
  -> pending input lane（排队显示）
  -> plan/question 浮层、只读 interaction overlay
  -> 会话内查找（Cmd/Ctrl+F，已加载消息 -> 会话与消息管理 §5.2）
  -> session/message Pinia store（UI 状态所有权，§5）
```

边界：消息内容与 block 渲染、滚动锚定属于消息渲染器（`../消息渲染器/DeepChat-消息渲染器调查笔记.md`）；消息窗口数据分页接口在会话与消息管理笔记 §5.1；请求执行在对话请求与上下文笔记（`../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md`）。

## 1. 工作台结构

ChatPage 在 `src/renderer/src/features/chat-page/ChatPage.vue:86-232` 组合消息列表、输入框、pending input lane、plan/question 浮层、只读 interaction overlay。subagent session 被标记为只读（`:431-435`）。窗口化测量快照在 session 切换和消息追加后保存/恢复（`:512-584`、`:728-826`，数据分页侧语义见会话与消息管理笔记 §5.1）。

## 2. 会话与消息搜索入口

- 会话内查找（Cmd/Ctrl+F）：`useChatSearch` 在已加载的 display messages 上匹配、高亮与定位，导航复用共享滚动控制器（`requestChatScroll('search-navigation', ...)`），不与流式自动跟随冲突；搜索数据侧（只搜已加载窗口、不触发数据库查询）见会话与消息管理笔记 §5.2。
- 跨会话搜索：由内存 MCP 服务器 `conversationSearchServer` 暴露给模型工具与设置页（`src/main/mcp/inMemoryServers/conversationSearchServer.ts:465-494`）；会话列表侧未见独立的会话名搜索路由（数据侧见会话与消息管理笔记 §5.3）。
- 搜索命中直接定位到消息（message_id），可滚动到目标行。

## 3. Composer、pending lane 与发送反馈

- 输入框通过 preload bridge 调用 `ChatClient`/`SessionClient`；发送/steer/queue 的执行链见对话请求与上下文笔记 §1/§8。
- 运行中的输入进入独立的 pending input lane，`queuePendingInput`/steer/delete pending item 维护该队列（数据模型见会话与消息管理笔记 §1.3）；交互 UI 不会把 pending input 直接拼进已完成消息。
- **resume 与 retry_required**：`PendingInputLane.vue:25-41` 在队列暂停可用时显示"resume"按钮（`ChatPage.vue:150-160` 由 `showPendingQueueResume` 控制显示条件：非 ACP、会话已提交、无生成中、`pendingInputStore.resumeAvailable`）；`retry_required` 项显示琥珀色标记与重试按钮（`PendingInputLane.vue:206-232`），reorder/编辑在这些状态被禁用。对应动作 `onPendingInputResume`/`onPendingInputRetry` 在 `usePendingInputActions.ts:77-117`。
- **Composer 草稿持久化**：`composerDraftPersistence.ts` 按会话（`deepchat.composerDraft.v1.<sessionId>` 键）把输入文本、附件、active skills 与 TipTap document 镜像到 localStorage（400ms 防抖，空草稿删除、损坏视为无），切换会话即时恢复、应用重启不丢（`useComposerSubmit.ts` 装配）。
- **provider 搜索开关**：`useComposerSubmit.ts:287-363` 按 provider/model 能力（`supportsSearch && searchExecution === 'provider'`）解析 `isSearchAvailable`，`toggleSearch` 写入 session store 的 per-session `searchIntent`（`stores/ui/session.ts:352-373`），发送时以 `input.search === true` 进入 `SendMessageInput`。
- 流式反馈：消息列表随 IPC 增量事件更新（renderer message store 的 streamingBlocks/streamRevision，见会话与消息管理笔记 §6）；`useDisplayMessages` 用稳定 render key 复用显示对象、减少 DOM 替换（数据侧同一节）；DOM 层内容渲染见消息渲染器笔记。

## 4. 消息操作、分支与子会话边界

- 操作入口：源笔记未覆盖 retry/delete/edit/fork/compaction 在界面上的按钮与菜单（SessionTurn 操作面见会话与消息管理笔记 §4，执行链见对话请求与上下文笔记 §7）；本次未找到对应 UI 证据，不虚构。
- 子会话边界：subagent session 在 ChatPage 中只读，但仍能显示消息、plan、工具状态和最终 child result（`:431-435`）；多会话并行生成的界面区分未调查。

## 5. UI 状态所有权与同步

- session store 保存 active session、working/error 状态和 project/agent 关联，另持 per-session `searchIntents`（§3）；message store 保存 `messageCache`、`streamingBlocks`、当前 stream session/message id、`streamRevision` 和游标分页，IPC 事件在消息加载、stream update 和 session reset 分支处理（`src/renderer/src/stores/ui/message.ts`）。
- pendingInput store 除 `items`/`loading` 外新增 `resumeAvailable`、`resumingQueue`、`retryingItemId`（`stores/ui/pendingInput.ts:13-16`），`listPendingInputs` 路由现在返回 `{ items, resumeAvailable }`（`src/main/session/routes.ts:247-266`）。
- 会话切换/追加后保存恢复 measurement snapshot（§1）。
- 草稿的保存粒度：按会话持久化，覆盖文本、附件、active skills 与文档对象（§3，`composerDraftPersistence.ts`）。

## 6. 键盘、焦点与关键路径可用性

本次迁移范围内未覆盖：快捷键清单、焦点顺序、响应式与无障碍实现均未调查（源笔记无对应内容）；需要在桌面端运行验证。

## 7. 设计取舍与已确认边界

- pending input 独立于已完成消息呈现，steer/queue 不混入历史；释放未发送的 queue 项进入 `retry_required` 而非静默丢弃（#2137），暂停的队列可由用户显式 resume。
- Composer 草稿按会话 localStorage 持久化，空草稿不落盘（§3）。
- 失败 assistant 消息保留 error block，界面可重试/分叉（数据语义见会话与消息管理笔记 §4）。
- subagent 只读边界在 ChatPage 层实施（`ChatPage.vue:428`）。
- 通用界面盘点：源笔记无弹窗库/Toast/主题等通用 UI 盘点内容，本类目不虚构清单。

## 8. 未验证事项

- 未运行测试、构建或桌面端交互；视觉效果、键盘可用性、响应式与系统通知未验证。
- 搜索弹窗的具体交互细节（过滤器、结果列表）未在源笔记中覆盖。
- 消息操作按钮/菜单的入口与禁用规则未调查。

## 9. 关键源码索引

- ChatPage 组合：`src/renderer/src/features/chat-page/ChatPage.vue:86-232`、`:428`
- 窗口与滚动恢复：`src/renderer/src/features/chat-page/ChatPage.vue:512-584`、`:728-826`
- pending lane 与 resume/retry：`src/renderer/src/components/chat/PendingInputLane.vue`、`src/renderer/src/features/chat-page/composables/usePendingInputActions.ts:77-117`
- 草稿持久化：`src/renderer/src/features/chat-page/model/composerDraftPersistence.ts`、`useComposerSubmit.ts`
- provider 搜索开关：`useComposerSubmit.ts:287-363`、`src/renderer/src/stores/ui/session.ts:352-373`
- 会话内查找：`src/renderer/src/features/chat-page/composables/useChatSearch.ts`、`src/renderer/src/lib/chatSearch`
- renderer 状态 store：`src/renderer/src/stores/ui/message.ts`、`src/renderer/src/stores/ui/pendingInput.ts`（session store 同目录）
- 跨会话搜索服务：`src/main/mcp/inMemoryServers/conversationSearchServer.ts:465-494`
