# DeepChat Chat UI 调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7f3379524da3ac629918d35682e38833ad5c203e`（分支：`dev`）
>
> 调查方式：直接阅读源码（renderer 的 ChatPage 组合、ChatInputBox/ChatInputToolbar/PendingInputLane 组件、useComposerSubmit/useMessageActions/useChatSearch 等 composable、Pinia store 与 IPC 桥），静态核对控件、状态与事件绑定；视觉效果、焦点顺序、键盘可用性与系统通知未运行验证
>
> 调查范围：ChatPage 工作台结构与多窗口边界、会话导航与搜索入口、Composer 与草稿/附件、发送前配置、发送/排队/流式/停止反馈、消息操作工作流、多会话与子会话边界、UI 状态所有权与现场恢复、键盘关键路径；消息与任务的数据/执行语义分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 Electron 桌面 GUI，聊天工作台由 ChatPage 单一页面组合：

- ChatPage（`ChatPage.vue:1-314` 模板）组合顶栏、消息列表（窗口化数据分页接口）、搜索条、Composer（TipTap 编辑器 + 工具栏 + 状态栏）、pending input lane、plan/question 浮层与附件准备对话框。
- 发送中的输入不拼进已完成消息：生成中提交进入 pending lane（queue/steer/编辑/删除/重排），并提供 resume（恢复暂停队列）与 retry_required（释放后重试）动作；执行语义在对话请求与上下文笔记。
- Composer 草稿按会话持久化到 localStorage（`composerDraftPersistence.ts`），切换会话与重启后恢复；provider 原生搜索（DeepSeek web 搜索）以开关进入发送前配置，意图按会话保存在 session store。
- subagent session 在 ChatPage 中只读，但仍能显示消息、plan、工具状态与最终 child result。
- 会话内查找（Cmd/Ctrl+F）与跨会话搜索（侧栏过滤 + Spotlight 历史搜索）并存，命中可定位到消息。
- UI 状态（active session、working/error、message 缓存、streaming、pending input、草稿、plan）分散在 Pinia store 与页面局部状态，active session 按窗口绑定；键盘/焦点/响应式行为未运行验证（§11）。
- 上下文压缩在消息列表中以状态化分隔行呈现；它明确区分正在压缩、已压缩及未生成可用摘要等状态，具体上下文与持久化语义见对话请求与上下文、会话与消息管理笔记（`MessageListRow.vue:10-24,180-187`）。

## 工作台边界与用户主链

```text
ChatMainApp（应用壳：WindowSideBar + RouterView + Spotlight + 通知宿主）
  -> ChatPage
     -> 消息列表（窗口化数据分页接口 -> 会话与消息管理 §5）
     -> 输入框 -> ChatClient.sendMessage / steer / queue（执行 -> 对话请求与上下文）
     -> pending input lane（排队/steer/resume/retry 显示）
     -> plan/question 浮层、只读 interaction overlay
     -> 会话内查找（Cmd/Ctrl+F，已加载消息 -> 会话与消息管理 §5.2）
     -> session/message/stream/pendingInput/agentPlan Pinia store（UI 状态所有权，§8）
```

边界：消息内容与 block 渲染、滚动锚定属于消息渲染器笔记；消息窗口数据分页接口在会话与消息管理笔记 §5.1；请求执行链在对话请求与上下文笔记（`../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md`）。

## 1. 页面结构、导航与多窗口

- **应用壳**：`ChatMainApp.vue` 组合应用栏、侧栏、Spotlight 搜索浮层、路由视图与通知宿主（`src/renderer/src/App.vue:2`）；聊天工作台是路由页 ChatPage。
- **ChatPage 布局**（`src/renderer/src/features/chat-page/ChatPage.vue:1-314`）：顶栏（标题内联重命名、项目名、子会话返回父级，`ChatTopBar.vue:52-58`）；消息滚动区（历史加载指示/错误重试、`MessageList`）；只读 interaction 区；Composer 区（`PendingInputLane`、plan/question 浮层——可合并面板或单独呈现、`ChatInputBox`、`ChatStatusBar`）；附件准备对话框 ×2（composer 发送与 retry 各一）；删除确认对话框。
- **subagent 只读**：`isReadOnlySession` computed（:428，`sessionKind === 'subagent'`），只读时隐藏 Composer（:139）并显示 `ChatToolInteractionOverlay`（:124-136）。
- **多窗口**：active session 按 webContentsId 绑定、IPC 定向更新按 webContentsId 过滤（`src/main/desktop/sessionBinding.ts:13-64`、`src/renderer/src/stores/ui/sessionIpc.ts:29-35`）。草稿经 localStorage 跨窗口共享，但 busy/streaming 等运行时状态为窗口内内存，本次未找到跨窗口同步机制（数据侧结论见会话与消息管理笔记 §5；检查范围：renderer stores 与 sessionIpc）。

## 2. 会话列表、搜索与现场恢复

- **侧栏**（`src/renderer/src/components/WindowSideBar.vue`）：新建聊天、侧栏搜索输入是对**已加载会话列表的客户端过滤**（按标题包含匹配，`matchesSessionSearch`，:902-908，应用于置顶与分组 :911-924）；置顶区、分组区、加载更多（:556-560）。
- **Spotlight 跨会话搜索**：搜索命令按钮打开 Spotlight；`runSearch`（`src/renderer/src/stores/ui/spotlight.ts:305-333`）调用 `sessionClient.searchHistory`（服务端 FTS 历史搜索，数据侧见会话与消息管理笔记 §5.3），会话命中可直接选择，消息命中写入待跳转状态并在 ChatPage 提交后定位滚动（`ChatPage.vue:797-843`，带重试与高亮）。
- **会话内查找**：Cmd/Ctrl+F 打开 `ChatSearchBar`（`ChatPage.vue:15-32`），`useChatSearch`（`src/renderer/src/features/chat-page/composables/useChatSearch.ts`）在已加载 display messages 上匹配、高亮与定位（经共享滚动控制器请求滚动，不与流式自动跟随冲突）；键盘：Esc 关闭、Enter/Shift+Enter 下一条/上一条（`handleSearchKeydown` :237-265）。
- **现场恢复**：`useSessionRestore`（`src/renderer/src/features/chat-page/composables/useSessionRestore.ts:29-`）以 restore 请求 epoch 保证异步写入不串会话；`messageStore.loadMessages` 拉取首屏（默认 100 条，`ChatPage.vue:437`），session 切换时保存/恢复测量快照（:845-848、:984-988）；历史向上翻页在滚动到顶时触发（`loadOlderMessagesAtTop` :700-795，以窗口首行作锚点做滚动补偿）；提交后自动跟随滚动（:1049-1072）。

## 3. Composer、草稿、附件与快捷输入

- **编辑器**：`ChatInputBox`（`src/renderer/src/components/chat/ChatInputBox.vue`）是 TipTap 编辑器（`EditorContent` :24），扩展 Mention 与 slash Mention（:51、:81-82）、文件附件节点（:72）、占位符/历史等；提及对话框经 `useChatInputMentions`（:145）提交。附件经文件变更事件进入草稿（`useComposerSubmit.ts:1172-1198`），并按当前模型能力过滤不支持的音频（:399-418）。
- **工具栏**（`src/renderer/src/components/chat/ChatInputToolbar.vue`）：附件、provider 搜索开关（:21-36）、语音输入、steer 按钮（生成中且有输入时显示，:119-133）；主按钮是四态状态机（:268-273）：取消准备 / 停止 / 排队 / 发送，由 `handlePrimaryAction` 分发（:281-294）。
- **草稿持久化**：`composerDraftPersistence.ts` 按会话键 `deepchat.composerDraft.v1.<sessionId>`（:12）把文本、附件、active skills 与 TipTap document 镜像到 localStorage（400ms 防抖 :13、:543-554；空草稿删除、损坏视为无 :148-155、:164-168）；切换会话即时恢复（`switchComposerSession`，`useComposerSubmit.ts:669-700`），`pagehide/beforeunload` 同步 flush（:566-572）。草稿状态机（revision/fingerprint）在 `model/composerDraftState.ts`。
- **快捷输入**：slash 命令（`/compact` 手动压缩，`useComposerSubmit.ts:952-996`，命令定义 `src/renderer/src/components/chat/mentions/utils.ts:36-37`）；`@` 提及（编辑器扩展）。

## 4. Agent、模型、工具与发送前配置

- **模型切换**：`ChatStatusBar` 的模型切换器（`app-model-switcher`，`src/renderer/src/components/chat/ChatStatusBar.vue:85-105`）在当前会话内选择 provider/model（会话级绑定见会话与消息管理笔记 §8）。
- **provider 搜索开关**（provider 原生搜索的发送前开关）：
  - 可用性：`isSearchAvailable`（`useComposerSubmit.ts:287-297`）按 `modelClient.getCapabilities` 的 `supportsSearch && searchExecution === 'provider'` 解析（`refreshSearchCapability` :302-338）；
  - 切换：`toggleSearch`（:361-364）写入 session store 的 per-session `searchIntents`（`src/renderer/src/stores/ui/session.ts:352`、`getSearchIntent` :377、`toggleSearchIntent` :387-391）；
  - 发送：以 `input.search === true` 进入 `SendMessageInput`（`captureSubmissionSeed` :605-614）。
- **active skills**：编辑器内选择，进入草稿的 `activeSkills`（`recordComposerSkillsChange` :659-667），随 payload 提交。
- **附件准备**：发送前执行附件路由检查（执行侧），需要用户介入时在 `AttachmentPreparationDialog` 呈现（`ChatPage.vue:283-301`），支持 retry / 不带图片内容发送 / 切换视觉模型（`useComposerSubmit.ts:1270-1284`）。
- 设置作用域：模型/搜索意图/技能均按会话记忆；生成参数（temperature 等）在设置页，不在 ChatPage 内（本次未展开）。

## 5. 发送、排队、流式反馈与停止

- **发送路径**：`onSubmit`（`useComposerSubmit.ts:998-1047`）：生成中 → `pendingInputStore.queueInput` 入队（:1027）；空闲 → `dispatchComposerAttempt`（:826-950，发送前先插入乐观 user 消息与 pending-assistant 占位，被拒则回滚并弹附件对话框）。另有排队提交（`onQueueSubmit` :1098-1128）、steer（`onSteer` :1130-1170）与 slash 命令发送（:1049-1096）。
- **pending lane**（`src/renderer/src/components/chat/PendingInputLane.vue`）：队列计数与 blocked 计数徽标（:13-23）；resume 按钮（显示条件 `ChatPage.vue:1299-1309`：非 ACP、视图已提交、无生成中、`pendingInputStore.resumeAvailable`）；`retry_required` 项琥珀色标记 + 重试按钮（:208-229）；blocked 项 retry / send-without 按钮（:174-207）；拖拽排序（:53-62，阻塞/待重试/编辑中禁用）、行内编辑（:95-133）。动作 `onPendingInputResume/Retry/Steer/Resolve` 在 `usePendingInputActions.ts:57-143`（resume :77-96、retry :98-117）。
- **流式反馈**：消息列表随 IPC 增量更新（renderer message store 与 `messageIpc.ts` 的 stream 注册表，见会话与消息管理笔记 §6）；`useDisplayMessages` 用稳定 render key 把占位/流式行与落盘消息关联（`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:339-355`、:367-438）；rate-limit 临时块在列表尾部内联呈现（`ephemeralRateLimitBlock`，:235-250）。
- **停止**：`onStop`（`ChatPage.vue:1346-1374`）→ `chatClient.stopStream`（失败 toast），停止中状态 `stoppingSessionIds` 防重入；执行层 abort 链见对话请求与上下文笔记 §7。

## 6. 消息操作、分支与版本导航

消息操作由 `MessageListRow` 触发（`MessageList.vue:22-30` 的 retry/delete/fork/continue/trace/edit-save 事件）→ `useMessageActions`（`src/renderer/src/features/chat-page/composables/useMessageActions.ts`）：

- **retry**：`retryMessage`（:67-107），只读会话与阻塞性交互（pending question/permission）时不可用；附件再次被拒时进入 `retryAttachmentPreparationSummary` 对话框（`ChatPage.vue:293-301`）。
- **delete**：`onMessageDelete`（:167-170）打开 `DcConfirmDialog` 确认（`ChatPage.vue:302-312`），确认后 `confirmMessageDelete`（:172-200）调用 `deleteMessage` 并重载会话（执行语义：从目标消息起截断，对话请求与上下文笔记 §7）。
- **edit**：`onMessageEditSave`（:212-225）调用 `editUserMessage` 后**自动跟随 retry**（编辑即重发的工作流）。
- **fork**：`onMessageFork`（:227-237）创建 forked 会话后自动切换并刷新列表（数据语义：复制到新会话，会话与消息管理笔记 §1.5）。
- **continue**：`onMessageContinue`（:239-241）复用 retry（非阻塞式）；本次未找到独立"续写"入口。
- **manual compaction**：`/compact` slash 命令（`useComposerSubmit.ts:952-996`），ACP 会话不可用、生成中不触发。
- **trace**：`onMessageTrace`（`ChatPage.vue:1376-1378`）打开 `TraceDialog`（:281）。
- 只读（subagent）会话下上述动作全部跳过（各函数首行 `isReadOnlySession` 检查）；分支树/版本导航界面（兄弟版本列表等）本次未在 ChatPage 找到（检查范围：ChatPage 模板与 useMessageActions）。

## 7. 多会话、多模型、群聊与后台生成

- 多会话靠侧栏列表 + 单页面切换；同一会话串行（队列 lane），steer 打断当前 turn（工具栏 steer 按钮 + lane 内 steer 动作）。
- 多模型：会话级模型切换器（§4）；发送前对不支持音频/视觉的模型做能力过滤与提示（`useComposerSubmit.ts:399-418` 音频过滤；视觉能力判定 `ChatPage.vue:1145-1154` `composerSupportsVision`）。
- 子 Agent：subagent session 只读呈现（§1），plan 浮层与 question 面板在父会话以浮层显示（`ChatPage.vue:166-209`）；工具审批的待处理浮层由 `useToolInteraction`（:1102-1115）驱动。
- 后台生成（窗口外继续运行 + 返回入口）：本次未找到独立界面机制（检查范围：ChatPage、WindowSideBar、通知宿主）。

## 8. Chat UI 状态所有权与同步

- **session store**（`src/renderer/src/stores/ui/session.ts`）：会话列表/分页（列表 epoch :330-344）、`activeSessionId`（:351）、`searchIntents`（:352）、分组模式（:401-416）、删除墓碑（:340-342）。
- **message store**（`src/renderer/src/stores/ui/message.ts`）：
  - 消息 ID/缓存：`messageIds/messageCache`（:62-63）；
  - `committedSessionId`（:68）；
  - 分页游标与 `hasMoreHistory`（:69-71）；
  - 解析缓存（:76）；
  - streaming 状态委托给 `stream` store（`streamingBlocks`、`currentStreamSessionId`、`currentStreamMessageId`、`streamRevision`，:53-59）。
- **pendingInput store**（`src/renderer/src/stores/ui/pendingInput.ts:11-27`）：
  - 状态字段：`items`、`resumeAvailable`、`loading`、`resumingSessionId`、`retryingItemId`；
  - 路由：`listPendingInputs` 返回 `{ items, resumeAvailable }`（`src/main/session/routes.ts:247-259`）。
- **草稿**：feature 内 `composerDraftState` + localStorage（§3）。
- **plan**：`agentPlanStore`（`ChatPage.vue:406` 实例化，导入 :350）按会话存 plan 快照与折叠状态，plan 浮层生命周期 `usePlanFloatLifecycle`（:1117-1131）。
- **切换会话**：清 pendingInput（:993）、切换草稿（:976）、清搜索状态（:977）、重置 display 缓存（:978）、保存/恢复测量快照（:970-972、:984-988）、清其他会话流式状态（:989）；恢复 epoch 贯穿所有异步写（§2）。
- **重启恢复**：草稿从 localStorage 恢复；重启后 held 队列项经 `resumeAvailable` 呈现 resume 按钮（§5）。

## 9. 键盘、焦点、响应式与关键路径可用性

- 键盘事件：`useChatPageEventBridge` 在 window 上注册 keydown（`useChatPageEventBridge.ts:74`）→ `handleWindowKeydown`（`ChatPage.vue:1074-1082`）：滚动意图键（方向键/PageUp/Home 等，:494-503）驱动窗口化测量，搜索快捷键（Cmd/Ctrl+F、Enter/Shift+Enter、Esc）经 `handleSearchKeydown`（`useChatSearch.ts:237-265`）。
- 焦点保持：question/permission 激活时 Composer 用 `v-show + inert` 保留（`ChatPage.vue:217-221`），避免 TipTap 草稿与 IME 状态被卸载。
- 无障碍标记：滚动区 `role="status"/aria-live`（:116-119）、删除对话框 title/description、工具栏按钮 aria-label 等静态可见。
- 焦点顺序、响应式断点、实际键盘可用性未运行验证（§11）。

## 10. 设计取舍与已确认边界

- pending input 独立于已完成消息呈现，steer/queue 不混入历史；释放未发送的 queue 项进入 `retry_required` 而非静默丢弃，暂停队列由用户显式 resume（§5）。
- Composer 草稿按会话 localStorage 持久化，空草稿不落盘，跨窗口共享（§3）。
- 发送反馈采用"乐观 user 消息 + pending-assistant 占位 + render key 交接"（§5）；失败回滚乐观消息并弹附件对话框。
- 编辑即重发：edit 保存后自动 retry（§6）。
- subagent 只读边界在 ChatPage 层实施（`ChatPage.vue:428`）。
- 通用 UI 组件（Toast/Modal 库等）只记录与聊天主链的交点（错误 toast、删除确认、附件对话框），不做全仓库盘点。

## 11. 未验证事项

- 视觉效果、动画、焦点顺序、键盘可用性与响应式行为未运行验证（静态代码只能确认控件与事件绑定）。
- 系统通知（完成/错误通知）的实际呈现与点击返回行为未运行验证。
- Spotlight 搜索弹窗的交互细节（结果列表、分组）静态确认入口，未运行。
- 多窗口 busy/streaming 同步不存在（未找到实现），未验证真实多窗口行为。
- 消息操作按钮在 `MessageListRow` 中的可见/禁用规则属消息渲染器装配，未在本笔记展开验证。
- 未运行测试、构建或桌面端交互；结论来自 renderer 静态源码。

## 12. 关键源码索引

- 工作台组合：`src/renderer/src/features/chat-page/ChatPage.vue:1-314`、`:428`
- 现场恢复与窗口：`src/renderer/src/features/chat-page/composables/useSessionRestore.ts`、`ChatPage.vue:700-795`、`:966-1041`
- 搜索入口：`src/renderer/src/features/chat-page/composables/useChatSearch.ts:110-265`、`src/renderer/src/stores/ui/spotlight.ts:305-333`
- Composer 与草稿：`src/renderer/src/features/chat-page/composables/useComposerSubmit.ts:998-1170`、`model/composerDraftPersistence.ts`
- 工具栏四态与停止：`src/renderer/src/components/chat/ChatInputToolbar.vue:268-294`、`ChatPage.vue:1346-1374`
- pending lane：`src/renderer/src/components/chat/PendingInputLane.vue`、`composables/usePendingInputActions.ts:57-143`
- 消息动作：`src/renderer/src/features/chat-page/composables/useMessageActions.ts:67-241`
- UI 状态 store：`src/renderer/src/stores/ui/session.ts`、`message.ts`、`pendingInput.ts`
