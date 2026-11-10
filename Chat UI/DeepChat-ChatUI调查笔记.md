# DeepChat Chat UI 调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：直接阅读源码（renderer 的 ChatPage 组合、ChatInputBox/ChatInputToolbar/PendingInputLane 组件、useComposerSubmit/useMessageActions/useChatSearch 等 composable、Pinia store 与 IPC 桥），静态核对控件、状态与事件绑定；视觉效果、焦点顺序、键盘可用性与系统通知未运行验证
>
> 调查范围：ChatPage 工作台结构与多窗口边界、会话导航与搜索入口、Composer 与草稿/附件、发送前配置、发送/排队/流式/停止反馈、消息操作工作流、多会话与子会话边界、UI 状态所有权与现场恢复、键盘关键路径；消息与任务的数据/执行语义分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 Electron 桌面 GUI，聊天工作台由 ChatPage 单一页面组合：

- ChatPage 在一个路由页内把工作台表面分成四类：顶部导航与查找（顶栏、搜索条）、消息区（消息列表、消息地图、回到底部提示）、输入区（TipTap 编辑器、工具栏、状态栏、引用与附件节点，以及 pending input lane），覆盖层则是 question/权限浮层与附件准备对话框。
- 发送中的输入不拼进已完成消息：生成中提交进入 pending lane（queue/steer/编辑/删除/重排），并提供 resume（恢复暂停队列）与 retry_required（释放后重试）动作；执行语义在对话请求与上下文笔记。
- Composer 草稿按会话持久化到 localStorage（`composerDraftPersistence.ts`），切换会话与重启后恢复；provider 原生搜索（DeepSeek web 搜索）以开关进入发送前配置，意图按会话保存在 session store。
- subagent session 在 ChatPage 中只读，但仍能显示消息、工具状态与最终 child result。
- 会话内查找（Cmd/Ctrl+F）与跨会话搜索（侧栏过滤 + Spotlight 历史搜索）并存，命中可定位到消息。
- UI 状态（active session、working/error、message 缓存、streaming、pending input、草稿、引用与附件）分散在 Pinia store 与页面局部状态，active session 按窗口绑定；键盘/焦点/响应式行为未运行验证（§11）。
- 工作台另有三块表面：消息地图（`ChatMinimap.vue`，刻度来自 `minimapTicks.ts`，与消息窗口化共用同一布局表）、回到底部提示（`ScrollToLatestPill.vue`）、引用与附件编辑（编辑器侧 chip、编辑器、附件架与附属表达菜单，消息侧引用/文件节点；组件见 `src/renderer/src/components/chat/{ReferenceChip,ReferenceEditor,AttachmentShelf,AttachmentRepresentationMenu}.vue` 与 `nodes/{SessionReferenceView,FileReferenceView}.vue`）。
- 上下文压缩在消息列表中以状态化分隔行呈现；它明确区分正在压缩、已压缩及未生成可用摘要等状态，具体上下文与持久化语义见对话请求与上下文、会话与消息管理笔记（`MessageListRow.vue:10-24,180-187`）。
- 非视觉工作流可通过 Electron 的 accessibility support 状态启用：ChatPage 为消息区补充可聚焦 region 与 live 状态，并在该模式下关闭消息窗口化，避免屏幕阅读器只接触当前视口窗口。

## 工作台边界与用户主链

```text
ChatMainApp（应用壳：WindowSideBar + RouterView + Spotlight + 通知宿主）
  -> ChatPage
     -> 消息列表（窗口化数据分页接口 -> 会话与消息管理 §5）+ 消息地图 ChatMinimap
     -> 输入框 -> ChatClient.sendMessage / steer / queue（执行 -> 对话请求与上下文）
     -> pending input lane（排队/steer/resume/retry 显示）
     -> question/权限浮层、只读 interaction overlay
     -> 会话内查找（Cmd/Ctrl+F，已加载消息 -> 会话与消息管理 §5.2）
     -> session/message/stream/pendingInput Pinia store（UI 状态所有权，§8）
```

边界：消息内容与 block 渲染、滚动锚定属于消息渲染器笔记；消息窗口数据分页接口在会话与消息管理笔记 §5.1；请求执行链在对话请求与上下文笔记（`../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md`）。

## 1. 页面结构、导航与多窗口

- **应用壳**：`ChatMainApp.vue` 把应用栏、侧栏、Spotlight 搜索浮层、路由视图与通知宿主组合成应用外壳，聊天工作台是其中的路由页 ChatPage（`src/renderer/src/App.vue:2`）。
- **ChatPage 布局**（`src/renderer/src/features/chat-page/ChatPage.vue:1-314`）：顶栏（标题内联重命名、项目名、子会话返回父级，`ChatTopBar.vue:52-58`）；消息滚动区（历史加载指示/错误重试、消息列表）；只读 interaction 区；Composer 区（pending lane、工具交互 dock、输入框、状态栏）；附件准备对话框 ×2（composer 发送与 retry 各一）；删除确认对话框。
- **subagent 只读**：`isReadOnlySession` computed（:428，`sessionKind === 'subagent'`），只读时隐藏 Composer（:139）并显示 `ChatToolInteractionOverlay`（:124-136）。
- **多窗口**：活动会话按 webContentsId 绑定，激活事件只由目标窗口处理。完整流式内容定向发给绑定该会话的窗口，其余窗口通过轻量 activity 信号使最近会话缓存失效；会话状态另经带版本事件同步。窗口内仍各自持有消息缓存和草稿镜像（`src/main/events/sessionEventRouter.ts:78-95,160-179`、`src/renderer/src/stores/ui/messageIpc.ts:230-245`）。

## 2. 会话列表、搜索与现场恢复

- **侧栏**：侧栏组件提供新建聊天入口，搜索输入框对已加载的会话列表做客户端过滤，按标题包含匹配（`matchesSessionSearch`），过滤结果分别作用于置顶区与分组区，列表底部提供加载更多（`src/renderer/src/components/WindowSideBar.vue:556-924`）。
- **Spotlight 跨会话搜索**：搜索命令按钮打开 Spotlight；`runSearch`（`src/renderer/src/stores/ui/spotlight.ts:305-333`）调用 `sessionClient.searchHistory`（服务端 FTS 历史搜索，数据侧见会话与消息管理笔记 §5.3），会话命中可直接选择，消息命中写入待跳转状态并在 ChatPage 提交后定位滚动（`ChatPage.vue:797-843`，带重试与高亮）。
- **会话内查找**：Cmd/Ctrl+F 打开 `ChatSearchBar`（`ChatPage.vue:15-32`），`useChatSearch`（`src/renderer/src/features/chat-page/composables/useChatSearch.ts`）在已加载 display messages 上匹配、高亮与定位（经共享滚动控制器请求滚动，不与流式自动跟随冲突）；键盘：Esc 关闭、Enter/Shift+Enter 下一条/上一条（`handleSearchKeydown` :237-265）。
- **现场恢复**：`useSessionRestore`（`src/renderer/src/features/chat-page/composables/useSessionRestore.ts:29-`）以 restore 请求 epoch 保证异步写入不串会话；首屏消息由消息 store 拉取（默认 100 条），会话切换时保存并恢复测量快照，各阶段入口同在 `ChatPage.vue:437,845-848,984-988`。

  历史向上翻页在滚动到顶时触发（`loadOlderMessagesAtTop` :700-795，以窗口首行作锚点做滚动补偿）；提交后自动跟随滚动（:1049-1072）。

## 3. Composer、草稿、附件与快捷输入

- **编辑器**：`ChatInputBox` 用 TipTap 承载输入，扩展覆盖 Mention 与 slash 提及、文件附件节点、占位符与历史输入，提及对话框由 `useChatInputMentions` 提交（`src/renderer/src/components/chat/ChatInputBox.vue:24-145`）。附件由文件变更事件写入草稿，并按当前模型能力过滤掉不支持的音频（`useComposerSubmit.ts:399-1198`）。
- **工具栏**（`src/renderer/src/components/chat/ChatInputToolbar.vue:21-36,119-133,268-294`）：附件、provider 搜索开关、语音输入、steer 按钮（生成中且有输入时显示）；主按钮是四态状态机：取消准备 / 停止 / 排队 / 发送，由 `handlePrimaryAction` 分发。
- **草稿持久化**：按会话键 `deepchat.composerDraft.v1.<sessionId>` 存取的草稿由 `composerDraftPersistence.ts:12-13,148-168,543-554` 管理：文本、附件、active skills 与 TipTap document 镜像到 localStorage，写入带 400ms 防抖；空草稿删除、损坏视为无。

  切换会话时由 `switchComposerSession` 立即载入目标会话的草稿，页面隐藏或卸载前再同步写盘一次（`useComposerSubmit.ts:566-700`）；草稿的 revision 与 fingerprint 状态机在 `model/composerDraftState.ts`。
- **新会话草稿**：尚未创建 session 时，草稿按 Agent 使用 `new-thread:<agentId>` 键保存；切换 Agent 不会再让其文本、附件、Skills 选择互相覆盖。状态所有者见 `src/renderer/src/stores/ui/draft.ts:33-78`。
- **快捷输入**：slash 命令（`/compact` 手动压缩，`useComposerSubmit.ts:952-996`，命令定义 `src/renderer/src/components/chat/mentions/utils.ts:36-37`）；`@` 提及（编辑器扩展）。

## 4. Agent、模型、工具与发送前配置

- **模型切换**：`ChatStatusBar` 内的模型切换器（模板标记 `app-model-switcher`）在当前会话内选择 provider 与 model，选择结果成为该会话的模型绑定（`src/renderer/src/components/chat/ChatStatusBar.vue:85-105`；绑定语义见会话与消息管理笔记 §8）。
- **provider 搜索开关**（provider 原生搜索的发送前开关）：
  - 可用性：`isSearchAvailable`（`useComposerSubmit.ts:287-297`）按 `modelClient.getCapabilities` 的 `supportsSearch && searchExecution === 'provider'` 解析（`refreshSearchCapability` :302-338）；
  - 切换：`toggleSearch` 写入 session store 中按会话保存的 `searchIntents`（`useComposerSubmit.ts:361-364`、`src/renderer/src/stores/ui/session.ts:352-391`）；
  - 发送：以 `input.search === true` 进入 `SendMessageInput`（`captureSubmissionSeed` :605-614）。
- **active skills**：编辑器内选择，进入草稿的 `activeSkills`（`recordComposerSkillsChange` :659-667），随 payload 提交。
- **附件准备**：发送前执行附件路由检查（执行侧），需要用户介入时在 `AttachmentPreparationDialog` 呈现（`ChatPage.vue:283-301`），支持 retry / 不带图片内容发送 / 切换视觉模型（`useComposerSubmit.ts:1270-1284`）。
- 设置作用域：模型/搜索意图/技能均按会话记忆；生成参数（temperature 等）在设置页，不在 ChatPage 内（本次未展开）。

## 5. 发送、排队、流式反馈与停止

- **发送路径**：提交入口 `onSubmit` 先看当前会话是否正在生成：生成中把输入交给 pending input store 入队，空闲则走 `dispatchComposerAttempt` 发送，后者先插入乐观 user 消息与 pending assistant 占位，被拒时回滚并弹出附件对话框。排队提交、steer 与 slash 命令发送是同文件的平行入口（`useComposerSubmit.ts:826-1170`）。
- **pending lane**（`src/renderer/src/components/chat/PendingInputLane.vue:13-229`）：队列计数与 blocked 计数徽标；非 ACP、视图已提交、无生成中且 `pendingInputStore.resumeAvailable` 为真时显示 resume 按钮（`ChatPage.vue:1299-1309`）；`retry_required` 项琥珀色标记 + 重试按钮；blocked 项 retry / send-without 按钮；拖拽排序（阻塞/待重试/编辑中禁用）与行内编辑。

  活动 queue 项上限为 10；UI 的可用槽位与主进程 `MAX_PENDING_INPUTS` 使用同一容量语义（`src/shared/pendingInput.ts:2`、`src/main/session/data/pendingInputs.ts:474`）。

  resume 用于重启后被 hold 的 pending 队列，逐项 retry 用于运行失败后释放的 retry_required 项，两者对应两种不同的中断来源。按钮动作绑定在 `usePendingInputActions.ts:57-143`，能否执行由主进程的准入条件决定（`pendingInputAdmissionCoordinator.ts:433-494`）。
- **流式反馈**：消息列表随 IPC 增量更新（renderer message store 与 `messageIpc.ts` 的 stream 注册表，见会话与消息管理笔记 §6）；`useDisplayMessages` 用稳定 render key 把占位/流式行与落盘消息关联（`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:339-355`、:367-438）；rate-limit 临时块在列表尾部内联呈现（`ephemeralRateLimitBlock`，:235-250）。
- **停止**：`onStop`（`ChatPage.vue:1346-1374`）→ `chatClient.stopStream`（失败 toast），停止中状态 `stoppingSessionIds` 防重入；执行层 abort 链见对话请求与上下文笔记 §7。

## 6. 消息操作、分支与版本导航

消息操作由 `MessageListRow` 触发（`MessageList.vue:22-30` 的 retry/delete/fork/continue/trace/edit-save 事件）→ `useMessageActions`（`src/renderer/src/features/chat-page/composables/useMessageActions.ts`）：

- **retry**：`retryMessage` 在只读会话或存在阻塞性交互（待回答的 question、待审批的 permission）时不执行；重试时附件再次被拒，则进入重试专用的附件准备对话框 `retryAttachmentPreparationSummary`（`useMessageActions.ts:67-107`、`ChatPage.vue:293-301`）。
- **delete**：`onMessageDelete`（:167-170）打开 `DcConfirmDialog` 确认（`ChatPage.vue:302-312`），确认后 `confirmMessageDelete`（:172-200）调用 `deleteMessage` 并重载会话（执行语义：从目标消息起截断，对话请求与上下文笔记 §7）。
- **edit**：`onMessageEditSave`（:212-225）调用 `editUserMessage` 后**自动跟随 retry**（编辑即重发的工作流）。
- **fork**：`onMessageFork`（:227-237）创建 forked 会话后自动切换并刷新列表（数据语义：复制到新会话，会话与消息管理笔记 §1.5）。
- **continue**：续写动作向当前会话追加一条本地化的用户指令，再进入普通发送链，保留原 assistant 历史；它和重试的破坏性截断具有不同语义。只读、阻塞性交互及同会话重复操作会阻止提交（`useMessageActions.ts:286-304`）。
- **manual compaction**：`/compact` slash 命令（`useComposerSubmit.ts:952-996`），ACP 会话不可用、生成中不触发。
- **trace**：`onMessageTrace`（`ChatPage.vue:1376-1378`）打开 `TraceDialog`（:281）。
- 只读（subagent）会话下上述动作全部跳过（各函数首行 `isReadOnlySession` 检查）；分支树/版本导航界面（兄弟版本列表等）本次未在 ChatPage 找到（检查范围：ChatPage 模板与 useMessageActions）。

## 7. 多会话、多模型、群聊与后台生成

- 多会话靠侧栏列表 + 单页面切换；同一会话串行（队列 lane），steer 打断当前 turn（工具栏 steer 按钮 + lane 内 steer 动作）。
- 多模型：会话级模型切换器（§4）；发送前对不支持音频/视觉的模型做能力过滤与提示（`useComposerSubmit.ts:399-418` 音频过滤；视觉能力判定 `ChatPage.vue:1145-1154` `composerSupportsVision`）。
- 子 Agent：subagent session 只读呈现（§1）；父会话的 question、审批等待处理交互进入统一交互 dock，独立 plan 浮层未接入当前 ChatPage（`ChatPage.vue:168-227`）。
- 后台生成（窗口外继续运行 + 返回入口）：本次未找到独立界面机制（检查范围：ChatPage、WindowSideBar、通知宿主）。

## 8. Chat UI 状态所有权与同步

- **session store**：会话 store 保存会话列表及其分页 epoch、活动会话 id、按会话记录的搜索意图、分组模式与删除墓碑，页面各处的会话级状态都从这一处读取（`src/renderer/src/stores/ui/session.ts:330-416`）。
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
- **交互浮层**：当前挂载 `ChatInteractionDock`，消费待处理工具交互与 ACP elicitation；它和回到底部提示位于输入区上方。模板仍留有 plan/question 的历史注释，但当前脚本没有独立 plan store 接线（`ChatPage.vue:203-227`）。
- **切换会话**：清理 pendingInput、切换草稿、清搜索状态、重置显示缓存、保存并恢复测量快照、清其他会话的流式状态，均在同一处切换流程内（`ChatPage.vue:970-993`）；恢复 epoch 贯穿所有异步写（§2）。
- **重启恢复**：草稿从 localStorage 恢复；重启后 held 队列项经 `resumeAvailable` 呈现 resume 按钮（§5）。

## 9. 键盘、焦点、响应式与关键路径可用性

- 键盘事件：`useChatPageEventBridge`（`useChatPageEventBridge.ts:74`）在 window 上注册一个 keydown 监听，事件进入 ChatPage 后按意图分流：方向键、PageUp、Home 等滚动键驱动窗口化测量，Cmd/Ctrl+F、Enter/Shift+Enter 与 Esc 交给查找处理器（`ChatPage.vue:494-1082`、`useChatSearch.ts:237-265`）。
- 焦点保持：question/permission 激活时 Composer 用 `v-show + inert` 保留（`ChatPage.vue:217-221`），避免 TipTap 草稿与 IME 状态被卸载。
- 无障碍标记：滚动区 `role="status"/aria-live`（:116-119）、删除对话框 title/description、工具栏按钮 aria-label 等静态可见。
- 焦点顺序、响应式断点、实际键盘可用性未运行验证（§11）。
- **非视觉模式**：`useAccessibilitySupport` 读取 Electron accessibility support 状态；开启时 ChatPage 把消息滚动区设为可聚焦 region，并关闭列表窗口化。Mention 建议列表使用 listbox/option 角色、`aria-activedescendant` 与状态播报；接线见 `src/renderer/src/composables/useAccessibilitySupport.ts`、`ChatPage.vue:428,955`、`components/chat/composables/useChatInputMentions.ts:96-101`。

## 10. 设计取舍与已确认边界

- pending input 独立于已完成消息呈现，steer/queue 不混入历史；释放未发送的 queue 项进入 `retry_required` 而非静默丢弃，暂停队列由用户显式 resume（§5）。
- Composer 草稿按会话 localStorage 持久化，空草稿不落盘，跨窗口共享（§3）。
- 发送反馈采用"乐观 user 消息 + pending-assistant 占位 + render key 交接"（§5）；失败回滚乐观消息并弹附件对话框。
- 编辑即重发：edit 保存后自动 retry（§6）。
- subagent 只读边界在 ChatPage 层实施（`ChatPage.vue:428`）。
- 通用 UI 组件（Toast/Modal 库等）只记录与聊天主链的交点（错误 toast、删除确认、附件对话框），不做全仓库盘点。

## 11. 未验证事项

- 视觉效果、动画、焦点顺序、键盘可用性与响应式行为未运行验证；本次未运行测试、构建或桌面端交互，结论来自 renderer 静态源码（静态代码只能确认控件与事件绑定）。
- 系统通知（完成/错误通知）的实际呈现与点击返回行为未运行验证。
- Spotlight 搜索弹窗的交互细节（结果列表、分组）静态确认入口，未运行。
- 多窗口的定向流、轻量 activity 与状态版本链已静态确认；真实多窗口切换、断连和重新绑定时序未运行验证。
- 消息操作按钮在 `MessageListRow` 中的可见/禁用规则属消息渲染器装配，未在本笔记展开验证。

## 12. 关键源码索引

- 工作台组合：`src/renderer/src/features/chat-page/ChatPage.vue:1-314`、`:428`
- 现场恢复与窗口：`src/renderer/src/features/chat-page/composables/useSessionRestore.ts`、`ChatPage.vue:700-795`、`:966-1041`
- 搜索入口：`src/renderer/src/features/chat-page/composables/useChatSearch.ts:110-265`、`src/renderer/src/stores/ui/spotlight.ts:305-333`
- Composer 与草稿：`src/renderer/src/features/chat-page/composables/useComposerSubmit.ts:998-1170`、`model/composerDraftPersistence.ts`
- 工具栏四态与停止：`src/renderer/src/components/chat/ChatInputToolbar.vue:268-294`、`ChatPage.vue:1346-1374`
- pending lane：`src/renderer/src/components/chat/PendingInputLane.vue`、`composables/usePendingInputActions.ts:57-143`
- 消息动作：`src/renderer/src/features/chat-page/composables/useMessageActions.ts:67-241`
- UI 状态 store：`src/renderer/src/stores/ui/session.ts`、`message.ts`、`pendingInput.ts`
- 非视觉模式：`src/renderer/src/composables/useAccessibilitySupport.ts`、`src/renderer/src/features/chat-page/ChatPage.vue:428,955`
