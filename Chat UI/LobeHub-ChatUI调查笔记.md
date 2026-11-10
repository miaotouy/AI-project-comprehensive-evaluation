# LobeHub Chat UI 调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：直接阅读源码（SPA 路由与 Agent 聊天页面、AgentSidebar Topic 列表、ChatInput 编辑器与发送区、Conversation 消息操作与审批卡片、设置页快捷键、桌面通知工具）+ grep 检索键盘/无障碍属性，关键结论以当前源码接线为依据；未运行验证
>
> 调查范围：会话导航与现场恢复、Composer 与草稿、发送前配置、生成反馈与停止、消息操作、阅读辅助、UI 状态所有权、键盘与关键路径可用性、桌面通知；通用 UI 盘点（弹窗库、Toast、主题、断点、动画、拖放、i18n、PWA）不纳入本文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的聊天工作台由会话导航（Topic 侧栏）、消息区与 Lexical 工作台式输入区组成：

- Topic 列表：单击/双击 250ms 定时器区分导航与开新 tab、拖拽引用到输入框、右键菜单、悬浮元数据卡、未读点、失败/运行/等待人工图标与运行耗时、草稿提示；Topic·Thread 并排（`ConversationArea` 的 portal 支持）与桌面端多 tab 由路由层承担。
- 输入区是一个可扩展工作台：草稿按会话（messageMapKey）自动恢复、输入历史按 user×agent scope、IME 组合态、文件粘贴/拖入、Markdown 输入预览、`@` mention（Fuse 模糊检索）、`/` slash action（编辑器插件实现）、goal tag chip、语音消息（MediaRecorder 录制上传后走常规发送链并 `preserveComposer`）。当前快照另有受功能开关控制的实时听写：浏览器采集音频后以 AudioWorklet 转为单声道 16 kHz PCM 帧，前端取得短期会话令牌并建立受校验的 WSS 连接，将识别的中间和最终文本写回编辑器；音频授权、AudioWorklet/WSS 不可用和协议错误都有可区分的失败状态（`src/features/ChatInput/Dictation/`）。发送前配置区有 Token 用量明细与推理强度预设（模型实例级配置，跨 Agent 生效）。
- 生成期间持续保留停止按钮；输入区已有后续内容且宿主允许排队时，发送按钮与停止按钮并排，点击发送或按 Enter 都可提交后续消息。状态由 operation 经 ConversationStore 下发；只读/无权限时禁用发送并解释原因，队列托盘展示待发内容与“立即发送”。见 [发送区条件](../../lobehub/src/features/Conversation/ChatInput/utils.ts#L145-L161)、[按钮渲染](../../lobehub/src/features/ChatInput/SendArea/SendButton.tsx#L36-L66)。
- 工具审批卡片有全局键盘快捷键（1/2/↑/↓/Enter），由共享 arbiter 分发到唯一一张卡片；审批选项带 `role="radiogroup"/"radio"` 语义。无障碍覆盖是“点状”而非体系化的，消息操作栏图标按钮、Topic 行存在明确缺口。
- 桌面端（Electron）完成/审批通知与聊天状态直接联动并深链回具体 Topic；Web/PWA 没有系统级通知，只靠未读点 UI。
- 消息内容渲染（conversation-flow 算法、虚拟列表、Markdown）一律属于消息渲染器笔记，本文只记录工作流与界面状态。
- 会话区封装行容器、消息列表、输入草稿投递、人工干预、跟进建议与工作侧栏等可组合表面，共享同一会话级 store 与消息镜像。主要组装入口见 [ConversationArea](../../lobehub/src/routes/%28main%29/agent/features/Conversation/ConversationArea.tsx)。

## 工作台边界与用户主链

```text
进入 Topic（路由参数 -> useAgentContext -> ConversationProvider，界面入口 ConversationArea.tsx:134-144）
  -> Topic 侧栏：切换 / 双击开 tab / 拖拽引用 / 未读点 / 运行态反馈 / 草稿提示 / 搜索抽屉（会话导航）
  -> Lexical 编辑器：草稿恢复 / 历史 / mention / slash / goal chip / 文件粘贴 / 语音消息（发送前配置：Agent、模型、执行设备、审批模式、Token 明细、推理强度）
  -> 发送区（生成中保留停止，后续内容可并排发送；排队时 QueueTray）-> 流式输出（ChatMiniMap、滚动快照、keepMounted 由渲染器笔记覆盖）
  -> 消息操作：编辑/复制/重试/删除/分支/审批/翻译/TTS（错误卡重试见 PendingRetryTurn）
  -> 离开 / 再次进入：滚动快照与草稿恢复现场
```

边界：消息数据如何分桶、CRUD 落库属于会话与消息管理；发送后任务如何执行、审批如何恢复任务属于对话请求与上下文；消息列表虚拟化、角色分派、Markdown 与组件渲染属于消息渲染器。通用界面盘点（弹窗库、Toast、主题、断点、动画、灯箱、拖放、i18n、PWA 安装、离线提示）不属于本类目正文范围，所在位置见 [`../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md`](../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md)。

## 1. 页面结构、导航与多窗口

- **工作台结构**：Agent 聊天页由 `ConversationArea.tsx` 组装，会话级 Provider 内分成消息区（`ChatList`，逐行渲染拆到 `ChatItem`，还带悬浮头间距与子 Agent 只读提示 footer）与输入区（异构 Agent 下换成简化输入）；人工干预条、跟进建议与工作侧栏作为侧向/底部表面挂在同一层，侧栏与工作台同层布局。Topic 与 Thread 并排打开、桌面端多 tab 打开同一会话，两项能力分别由 chat portal（开与同步两个入口）和 tab 路由（`src/spa/router/tabRouter.tsx`）承担，属于路由层。
- **移动端**：`(mobile)` 路由树 + 独立 `entry.mobile.tsx` SPA，底部 TabBar；移动端 Topic 行单击直接导航（见下节），输入区有 `ChatInput/Mobile` 变体。响应式断点细节属通用盘点，不在本文。
- **多窗口/桌面 tab**：桌面端 Electron 每 tab 挂独立 memory router（`desktopRouter.config.desktop.tsx` 注释），会话可多开；本文确认其存在，跨 tab 的草稿/busy 同步语义未验证。

## 2. 会话列表、搜索与现场恢复

- **Topic 行交互**：桌面端单击 Topic 行后先延迟 250ms 再导航，这段等待用来识别双击——双击会取消待执行的单击并打开新 tab；待执行单击由模块级定时器 `pendingSingleClickTimer` 记录，快速跨行点击时只有最后一次动作生效。移动端没有这层延迟，单击直接导航；把 Topic 拖进输入框走 `startTopicDrag`。定位：`AgentSidebar/Topic/List/Item/index.tsx:76-254`。
- **Topic 行的状态反馈**：每一行叠加了多层提示——右键菜单、悬浮元数据卡（仓库、分支、worktree、PR、CI）、未读点（运行尾巴被掩蔽期间也即时置为未读）、失败/运行/等待人工三种运行态图标（运行尾巴已被看到时用 `#16518` 掩蔽）、工作目录标签，以及由 `useHasDraft` 驱动的红色“草稿”标记。定位：`AgentSidebar/Topic/List/Item/index.tsx:256-316`。
- **搜索与全量查找**：`TopicSearchBar` 与 `AllTopicsDrawer`（`Topic/AllTopicsDrawer/Content.tsx:62-64` 有关键词时走服务端 `useSearchTopics`；服务端 BM25 匹配 Topic 标题与消息内容——实现见会话与消息管理笔记第 5 节；结果不会直接标出或滚动到命中的具体消息）。列表本身按 Flat/按时间/按状态/按项目多种模式组织（由列表视图参数驱动，改的是查询不是消息树）。
- **消息列表滚动现场（快照）**：离开 Topic 时把滚动位置存成快照（是否在底部、偏移量与保存时间），再次进入时按快照恢复，没有快照就滚到最后一条；保存与恢复由滚动快照 store 与会话级滚动持久化 hook 完成（`ChatList/utils/scrollSnapshotStore.ts`、`ChatList/hooks/useTopicScrollPersist.ts:61-195`）。虚拟列表滚动机制与 `keepMounted` 见消息渲染器笔记。
- **小地图**：消息足够多时，`ChatMiniMap` 在侧边列出用户消息锚点，悬停展开预览，点击跳到对应消息（`scrollToIndex`）；指示器带 `aria-label` 与 aria-current。定位：`ChatMiniMap/useMinimapData.ts:19`、`MinimapIndicator.tsx:18`。

## 3. Composer、草稿、附件与快捷输入

### 3.1 输入编辑器是一个可扩展工作台

`src/features/ChatInput/InputEditor/index.tsx`（650 行）基于 Lexical 编辑器（`Editor` from `@lobehub/editor`，549-561 行）：

- **发送键位**：编辑器收到 Enter 时先看当前情境再决定发送还是换行——历史弹窗打开时 Enter 确认历史项，Shift+Enter 换行，Alt+Enter 追加一条 AI 消息，全屏模式只认 Cmd/Ctrl+Enter，其余情况由 `shouldSendOnEnter` 按 Enter 或 Mod+Enter 偏好决定；按键先交给输入历史处理，再进入上述判断。定位：`InputEditor/index.tsx:617-643`。
- **IME 组合态**：输入法组字期间，编辑器跳过 autocomplete 弹出、Enter 不触发发送，并在组字开始前清掉占位节点；这层判断由 `useIMECompositionEvent`（`InputEditor/index.tsx:126`）统一提供，接入点在 autocomplete、Enter 处理与占位节点清理三处。
- **草稿**：输入内容按会话隔离保存，草稿键取当前会话的 contextKey（`Conversation/ChatInput/index.tsx:502`）；编辑器初始化时恢复草稿，输入过程中防抖写入、失焦时立即落盘，切换会话时先把旧会话内容存好再恢复新会话的；读写由 useChatInputDraft 与 draftStorage 完成，最终写进 localStorage（`hooks/useChatInputDraft.ts:45-102`）。离开页面前若编辑器非空，会注册 beforeunload 提示，避免草稿静默丢失（`InputEditor/index.tsx:246-248`）。
- **输入历史**：输入为空时按 ArrowUp 打开历史弹窗，↑/↓ 移动、Enter/Tab 确认、Escape 关闭（`inputHistory.handleKeyDown`）；条目按用户与 Agent 的组合分作用域存储，localStorage 键形如 `lobechat:chat-input-history:v2:user:<uid>:agent:<aid>`，每个作用域上限 50 条；弹窗内以 ghost markdown 预览展示历史内容。定位：`InputEditor/index.tsx:540-575`、`inputHistoryStorage.ts:31-41`。
- **mention / slash / action tag**：
  - `@` mention 按 Agent、话题、文件等分类，用 Fuse 做模糊检索（`InputEditor/index.tsx:153-221`）；
  - `/` slash 项由 `useSlashActionItems` 提供（`InputEditor/index.tsx:254-264`）；
  - 两者都以编辑器选项接入（mentionOption 与 slashOption），输入阶段就渲染成结构化节点，发送时随消息内容一并提交；
  - action tag 是 Lexical 装饰节点（`InputEditor/ActionTag/` 下的节点与插件，正则把用户输入的 `<skill …/>` 变 chip）；
  - `/goal` 目标标记由 `insertGoalTag` 插入，只对消息前缀生效，识别交给 `isGoalPrompt`（`goalTag.ts:92-98`）。
- **文件粘贴/拖入**：粘贴事件直接把文件送去上传（`InputEditor/index.tsx:235-248`）；拖入的文件以及 skill、tool chip 交给 useSkillDrop 与 skillDragData 解析，本地文件由 insertLocalFileTags 插成 tag。
- **语音消息**：录音模块用 MediaRecorder 录完即上传，随后经 `sendVoiceMessage.ts:26-44` 进入常规发送链，发送时保留编辑器已有内容（preserveComposer）；发送进行中不接受新的录音（`Conversation/ChatInput/index.tsx:409-430`）。
- **只读态**：编辑器是否可编辑，同时取决于内容创建权限与资源可用性（`InputEditor/index.tsx:554`）。

### 3.2 发送前配置

`ModeSelector` 切换 Chat/Agent 模式；Agent 模式出现执行设备、工作目录/仓库、分支或 Worktree、审批模式和上下文窗口（这些面板在 `ChatInput/ActionBar` 的 `AgentMode`/`Params` 等目录）。模型按钮切换当前 topic 模型（topic 级快照语义见会话与消息管理笔记 1.3）。

推理强度作为模型选择器的一部分展示。`useReasoningEffortControl` 负责读取有效模型、模型实例配置和当前 topic 覆盖，并把更新写回相应作用域；模型菜单把可用强度作为同一选择流程的一部分显示。见 `src/features/ChatInput/hooks/useReasoningEffortControl.ts` 与 `src/features/ChatInput/ActionBar/Model/SelectorMenu.tsx`。Token 用量/预算明细条仍按对话、历史摘要、系统角色、工具与上限等来源拆分。

## 4. 发送、排队、流式反馈与停止

- **发送/停止按钮**：空闲时显示发送；生成时始终保留停止，已有后续输入且允许排队时在旁边显示发送。发送权限由工作区内容创建权限与资源可用性共同决定，拒绝时 tooltip 给出原因；停止保留自己的回调。见 [SendButton](../../lobehub/src/features/ChatInput/SendArea/SendButton.tsx#L17-L66)。
- **状态与提交**：会话级 hook 读取 operation 可见加载态，再结合输入是否为空与宿主是否禁用队列派生按钮；生成中的后续发送仍进入原有发送链，由队列规则安排执行。触发时重读文件与上下文选择，上传未完成、宿主只读或禁用队列且运行阻塞时不提交。执行环境预检拒绝时保留草稿；定时发送仅在日程持久化成功后清空编辑器。见 [UI 状态推导](../../lobehub/src/features/Conversation/ChatInput/useConversationChatInputUiState.ts#L34-L46)、[发送入口](../../lobehub/src/features/Conversation/ChatInput/index.tsx#L342-L425)。
- **排队反馈**：当前面的生成还没结束、操作类型又属于阻塞队列的那几类时，后续发送经 enqueueMessage 入队（执行侧见对话请求与上下文笔记第 8 节），输入区上方随即出现 QueueTray，列出待发条目与“立即发送”（点击即取消正在阻塞的排队操作）；托盘旁边还叠加运行状态短语、进度与目标武装状态。条目数量由 queuedMessageCount 派生，托盘在同文件渲染，定位：`Conversation/ChatInput/index.tsx:266-268,463-468`。
- **发送错误**：`InputCompletionErrorAlert` 与 sendMessageErrorMsg Alert（440-449 行）就地显示失败原因，编辑内容由执行链恢复（见对话请求与上下文笔记第 6 节）。
- **权限边界**：按钮置灰只是 UI 侧对权限的提前反映，最终仍由服务端校验（第 10 节）。带 `?message=` 参数进入的会话会先挂起自动发送，等 Topic 转移回填（AgentTransferMigration 占位）完成后才真正发出（`ConversationArea.tsx:208-216`）。

## 5. 消息操作、分支与版本导航

- **操作入口**：消息操作栏由 `MessageActionBar` 统一渲染，助手、用户、助手组、任务四个角色的按钮配置分放在各自的 Actions 目录里，由 Provider 注入。助手消息默认给编辑与复制，带工具时默认换成“删除并重新生成”，菜单另外提供评论、创建分支、折叠流程、TTS、翻译、分享、选择与多选、重新生成与删除；用户消息默认重新生成、编辑、复制；错误消息显示重试与删除，由独立的待重试回合组件 `PendingRetryTurn` 及其 hook 承载。工具与任务块另有审批、拒绝、取消和删除孤立工具消息，编辑文件卡可展开查看或隐藏 diff。定位：`Messages/components/MessageActionBar/index.tsx:90-169`。
- **分支导航 UI**：`Messages/components/MessageBranch.tsx`（86/97 行 `role="button"`）画在子消息上；数据语义（激活索引在父消息 metadata）见会话与消息管理笔记 4.2。版本树/兄弟导航的完整界面形态本次未逐一核对（属于消息渲染器笔记的组件装配范围）。
- **操作可用性**：审批类操作对 view-only 成员直接不渲染（`ApprovalActions.tsx:319-321`）；发送/重试按钮的可用性随 operation 状态变化（第 4 节）。
- 消息操作栏如何装配进消息壳（`MessageActionProvider`/`SingletonMessageActionsBar`）属于消息渲染器笔记。

## 6. 阅读辅助与多会话反馈

- 虚拟列表用 Virtua 渲染 conversation-flow 解析出的扁平列表（列表机制、`keepMounted` 与索引空间转换都属于消息渲染器笔记）；正在流式输出的消息和带文本选区的消息会被强制保留节点，因为回收节点会让 Markdown 动画重播、也会丢掉选区，判定在 `ChatList/components/VirtualizedList.tsx:256-290`。界面上的阅读辅助（小地图、滚动快照、跳转）见第 2 节。
- **多会话/后台生成的界面反馈**：Topic 行上的运行/失败/等待人工图标、未读点与耗时（第 2 节），加上完成与审批的桌面通知（第 9 节），共同回答“哪一条还在运行、回到哪一处现场”；这些界面都由 operation 状态驱动，全局 op 状态经 `useOperationState` 桥接成会话级 store 的 operationState 属性（`ConversationProvider.tsx:91`）。
- **排队输入的服务端让行**：QueueTray 不只在本地保存等待项。Gateway 顶层运行会收到是否仍有排队消息的镜像标记，并在下一决策点让出 turn；界面仍由同一 QueueTray 展示与执行“立即发送”。网络同步为 best-effort，失败时不会丢弃本地排队项。见 `src/store/chat/slices/agentRun/actions/transports/gateway/queuedMessagesFlag.ts:52-100`。

## 7. Chat UI 状态所有权与同步

- **按会话隔离**：每个 context 各自持有一个独立的 ConversationStore 实例（`src/features/Conversation/ConversationProvider.tsx:128-138`），实例在切换 topic/thread 时继续存活；切换发生时由 StoreUpdater 的 useLayoutEffect 在浏览器绘制前原地重置纯 UI 状态（`StoreUpdater.tsx:94-118`），重置与保留的分工如下：
  - 重置：当前阅读位置、是否贴底、输入内容、正在编辑的消息、待更新的参数、多选集合与多选模式等纯 UI 字段（`createEphemeralResetState`，`store/initialState.ts:87-102`）；
  - 保留：编辑器实例、输入浮层高度与虚拟列表滚动方法等仍挂载的基础设施（同文件 80-86 行注释）。

  数据层细节见会话与消息管理笔记 2.2/2.3。
- **滚动 API 注册进 store**：滚动方法注册在局部 store 的 virtuaList 动作里；当前阅读位置由可见区域中“top 最小、ratio 最大”的启发式选出，用于高亮与侧边导航，可见项变化时由 upsertVisibleItem 更新。定位：`store/slices/virtuaList/action.ts:54-137`。
- **草稿**：输入草稿按会话（draftKey=contextKey）保存并自动恢复（第 3.1 节）；输入历史按 user×agent scope（第 3.1 节）；离开页面前 `beforeunload` 提示防止草稿静默丢失。

## 8. 键盘、焦点与关键路径可用性

### 8.1 无障碍：点状覆盖，存在明确缺口

**做得到位的具体证据**（有文件行号支撑）：
- 消息操作栏容器带 `role="menubar"` 语义，用户消息一侧同样如此（`Conversation/ChatItem/components/Actions.tsx:34`、`User/Actions/index.tsx:75`）。
- 工作侧栏的进度折叠面板用 `role="button"` 搭配 aria-expanded 与指向列表的 aria-controls（`Conversation/WorkingSidebar/ProgressSection/index.tsx:160-165`）。
- 工作侧栏内嵌浏览器的加载指示器用 progressbar 角色并附 aria-valuetext（`Conversation/WorkingSidebar/Browser/index.tsx:441-443`）。
- 消息列表刷新失败的提示用 status 角色加 polite 级 live region，屏幕阅读器会主动播报（`Conversation/ChatList/components/RefreshError.tsx:37-40`）。
- Git 同步按钮用 aria-busy 与 aria-disabled 反映异步状态（`ChatInput/ControlBar/GitStatus.tsx:383-401`）。
- 发送按钮被禁用时，原因放在 Tooltip 里说明（`ChatInput/SendArea/SendButton.tsx:45-46`，见第 4 节）。
- 音频播放器的播放/暂停按钮 aria-label 随状态切换“播放”/“暂停”文案，进度、下载与语音消息按钮也各自带 aria-label（`src/features/AudioPlayer/index.tsx:328-393`）。
- 工具审批选项带 radiogroup 与 radio 的语义关联，选项组和单个选项分别标注（`ApprovalActions.tsx:325-362`，见 8.3 快捷键）。

**明确的缺口**：
- Topic 列表行没有可聚焦或键盘操作的痕迹：在 `AgentSidebar/Topic/List/Item/index.tsx` 里 grep 不到 tabIndex、onKeyDown、role 与 aria-label；
- 消息操作栏里的单个图标按钮（`Messages/components/MessageActionBar/index.tsx` 没有 aria-label）。这类按钮是 @lobehub/ui 的 ActionIcon，视觉上靠 title/tooltip 提示；组件内部是否把 title 自动映射成可访问名称属于三方包实现，本次未下钻，纯图标按钮是否带可访问名称仍待确认。
- 双击/单击的 250ms 定时器（第 2 节）只挂在鼠标事件上（onClick 与 onDoubleClick），本次没有找到对应的键盘实现，例如 Enter 打开、或用 tabIndex 让行可聚焦；键盘用户能否完成“单击导航 / 双击开新 tab”，本次未找到证据，倾向于没有该能力。
- 虚拟列表渲染的消息条目上没有 `role="log"` 或 aria-live 一类支持“新消息到达时播报”的实现，相关位置只有 onKeyDownCapture 与 aria-hidden 处理（`ChatList/components/VirtualizedList.tsx:304-352`）；流式生成的文字增量对屏幕阅读器用户不可感知。

**结论**：可访问名称在同一类交互上覆盖不一致（点状）。同为图标按钮，`ChatInput/ActionBar/Model/index.tsx:89`、`ChatInput/ControlBar/WorktreeSwitcher.tsx:674`、`Tools/useControls.tsx:655,1581,1594` 等处有 `aria-label`，Topic 行与消息操作栏没有。WCAG 合规判定需要人工用屏幕阅读器/键盘走一遍实际操作流程，本次只是静态代码扫描，结论仅限于“代码里有没有写这些属性”。

### 8.2 快捷键面板/帮助

- **发现型提示**：`src/features/CommandMenu/components/CommandFooter.tsx`（1-29 行）在 Cmd/Ctrl+K 命令面板底部常驻显示“↵ 打开 / ↑↓ 选择”两个键位提示，只覆盖命令面板内部的操作。
- **完整列表（可编辑）**：设置页的快捷键页面把绑定分成桌面端、必备、对话三组，桌面端组只在桌面端显示，对话组的内容来自 `features/Conversation.tsx`（目前只有这一组定义）。每项用 @lobehub/ui 的 HotkeyInput 渲染，可以自定义改键、清除绑定，输入时会遍历其它已绑定项做冲突检测并自动保存，是一块可编辑的快捷键面板。设置页路由只留薄壳转发设置功能，聊天作用域的热键定义在 `src/hooks/useHotkeys/chatScope.ts` 与 packages 下的常量文件。定位：`src/features/Settings/hotkey/index.tsx:1-26`。
- 命令面板本身的完整键位表（Cmd+K 打开、Esc 返回/关闭、Backspace 返回、Tab 进 AI 模式、↑↓ 选择、Enter 确认）本次靠 `useCommandMenu.ts` 的 Esc/滚动锁定 `useEffect` 与仓库内 `README.md` 记录的键位表交叉确认；用户能直接看到的仅有 `CommandFooter` 那两条提示 + 设置页的可编辑列表。

### 8.3 工具审批快捷键

- 审批卡片上支持数字键选择选项、↑/↓ 切换、Enter 提交，按键处理会跳过输入类焦点（INPUT、TEXTAREA、contentEditable）与组合键。监听器经 registerPendingHotkeyCard 注册到一个共享 arbiter：arbiter 全局只挂一个 window keydown，按“事件目标所在的卡片优先，否则最近注册的卡片”把每次按键交给恰好一张卡片，避免多张审批卡同时响应；InterventionBar 与全局审批卡通过 data-pending-hotkey-scope 标记纳入这一范围。选择拒绝后焦点自动落到原因输入框，该输入框有独立的 Enter/↑ 处理，选项在视觉上带编号。定位：`ApprovalActions.tsx:229-365`、`packages/shared-tool-ui/src/pendingHotkeys.ts:28-46`。

## 9. 桌面通知与跨平台连续性

桌面通知与聊天状态的联动在代码中完整可见：`src/store/chat/utils/desktopNotification.ts`（全文件 179 行）定义了两个统一注入点：

- Agent 回复完成时，`notifyDesktopAgentCompleted` 发出完成通知：标题按“话题标题 → Agent 名称 → 通用兜底”的优先级解析，正文把 markdown 回复剥成纯文本并截断到 256 字符，点击通知深链回具体的 agent/topic/group 会话（URL 按 groupId+topicId → groupId → agentId+topicId → agentId 四级顺序回退，并带 workspaceSlug 前缀）。调用点在 `buildRunLifecycle.ts`，紧跟在“停止 loading”之后触发，同批还会调用 markTopicUnread，所以桌面通知与 Topic 未读点由同一个完成事件驱动、作为两个并行副作用发出（执行侧见对话请求与上下文笔记第 6 节）。定位：`store/chat/utils/desktopNotification.ts:155-179`。
- 需要人工审批工具调用时，`notifyDesktopHumanApprovalRequired` 发出审批通知：标题解析沿用同一套逻辑，另外在 dock/任务栏打角标，并带 force 与 requestAttention 两个参数，即使窗口停在前台也强制弹通知、抢占注意力。调用点在 Gateway 事件处理与 client 流式执行的 human_approval 分支，同时把 Topic 置为 waitingForHuman。定位：`store/chat/utils/desktopNotification.ts:104-133`；调用侧见 `gatewayEventHandler.ts` 与 `transports/client/streamingExecutor.ts`。
- 两个入口都先用 isDesktop 短路，在 Web/PWA 环境下直接跳过，这套通知只在 Electron 桌面端生效；在 desktopNotification.ts 与 runAgent 调用点范围内，本次没有找到 Web Push API 或 Service Worker 通知的实现，PWA 模式下的完成与审批事件没有系统级通知，只能靠未读点界面或回到标签页查看。

## 10. 设计取舍与已确认边界

- **Topic 行的双击开 tab 与单击导航依赖 250ms 定时器**，快速跨行点击由模块级 timer 取消前一次动作；但完全依赖鼠标事件，键盘可达性未核实（第 8.1 节）。
- **虚拟列表的 `keepMounted` 只保护生成消息和选区**，普通历史消息仍会被回收，因此任何依赖 DOM 的扩展功能都必须通过 scroll API 而不能缓存节点（列表机制详见消息渲染器笔记）。
- **发送权限在 UI 侧提前反映**，但最终权限仍由服务端校验；只读用户可以阅读同一 Topic，但不能通过按钮绕过权限发送（第 4 节）。
- **审批快捷键的共享 arbiter 设计**：多张审批卡并存（对话内卡片 + 全局审批通知卡）时按键只驱动一张卡，避免“一个键位同时操作两张卡”；代价是键盘操作的可发现性仍依赖视觉阅读（第 8.3 节）。
- **会话级 store 跨 topic 存活 + 原地重置**：UI-only 状态不用手写清理逻辑，但重置清单必须与新加的 UI-only 字段保持同步（第 7 节，数据层语义见会话与消息管理笔记 2.2）。
- **类目边界**：本笔记只记录用户工作流与界面状态；消息数据模型与 CRUD 在会话与消息管理笔记，发送与审批的执行语义在对话请求与上下文笔记，conversation-flow 算法与虚拟列表渲染在消息渲染器笔记。通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、拖放、i18n、PWA 安装、离线提示）不在本文正文。

## 11. 未验证事项

- ActionIcon 的 title 属性是否在渲染时自动映射为 DOM 的 aria-label：属于三方包内部实现，本次未下钻，影响第 8.1 节里图标按钮可访问名称的判断范围。
- 双击/单击 250ms 定时器的键盘可达实现未找到证据（第 8.1 节）。
- 工具快捷按钮在 + 面板的拖拽排序具体实现机制未读 `ChatInput/ActionBar/Tools/useControls.tsx` 确认（拖拽库盘点不属于本文）。
- 输入框文件拖入/拖出时的悬停视觉反馈样式未逐一核对（拖放视觉属通用盘点范围）。
- 视觉效果、键盘焦点顺序、响应式行为与系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 移动端/桌面端的布局差异与断点实现属于通用盘点范围，未在本笔记展开。
- 语音消息的录音/上传/回放全链未运行验证（MediaRecorder 兼容性、`sendVoiceMessage` 与发送链的合并行为仅静态确认）；桌面端多 tab 之间草稿/busy/active session 的同步语义未验证；`ComposerDraftReceiver`/`composerDraftBus` 的跨表面投递时序未验证。
- 会话区、输入区与通知模块的归位已按引用路径核对（会话区包含 ChatItem、InterventionBar、FollowUp、WorkingSidebar 等表面，完成副作用在 buildRunLifecycle），界面交互未重跑；行号引用以模块级定位为准。
- 审批快捷键的 arbiter 分派（containment/最近注册）在“焦点不在任何卡片”时的实际命中行为未运行验证。

## 12. 关键源码索引

- `src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`（134-144 工作台组装，98-108 重连）
- `src/features/AgentSidebar/Topic/List/Item/index.tsx`（76-254 行交互，256-311 状态反馈）、`Topic/AllTopicsDrawer/Content.tsx`（62-64 服务端搜索）
- `src/features/Conversation/ConversationProvider.tsx`（128-138）、`StoreUpdater.tsx`（94-145）
- `src/features/Conversation/store/slices/virtuaList/action.ts`（54-138 滚动 API 与 activeIndex）
- `src/features/ChatInput/InputEditor/index.tsx`（517-534 草稿恢复，582-601 IME/保存，617-643 键位）
- `src/features/ChatInput/SendArea/SendButton.tsx`（12-48）、`src/features/Conversation/ChatInput/index.tsx`（237-299 状态，332-407 发送与按钮，409-430 语音）
- `src/features/Conversation/ChatInput/QueueTray.tsx`、`sendVoiceMessage.ts`（26-44）
- `src/features/ChatInput/ActionBar/Token/`（Token 预算明细）、`src/features/ChatInput/hooks/useReasoningEffortControl.ts` 与 `ActionBar/Model/SelectorMenu.tsx`（模型和推理强度合并选择）
- `src/features/Conversation/Messages/components/MessageActionBar/index.tsx`（90-169）
- `src/features/ChatMiniMap/`（useMinimapData.ts:19,61）、`src/features/Conversation/ChatList/utils/scrollSnapshotStore.ts`（133）
- `src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx`（229-296 快捷键，325-362 radiogroup）
- `packages/shared-tool-ui/src/pendingHotkeys.ts`（38-46 arbiter）
- `src/features/Settings/hotkey/index.tsx`（1-26）、`features/Conversation.tsx`（39-44,87）
- `src/features/CommandMenu/components/CommandFooter.tsx`（1-29）
- `src/store/chat/utils/desktopNotification.ts`、`src/store/chat/slices/agentRun/actions/lifecycle/buildRunLifecycle.ts`（完成/审批通知联动）
