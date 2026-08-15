# LobeHub Chat UI 调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：直接阅读源码（SPA 路由与 Agent 聊天页面、AgentSidebar Topic 列表、ChatInput 编辑器与发送区、Conversation 消息操作与审批卡片、设置页快捷键、桌面通知工具）+ grep 检索键盘/无障碍属性，全部行号按当前 HEAD 逐一核对；未运行验证
>
> 调查范围：会话导航与现场恢复、Composer 与草稿、发送前配置、生成反馈与停止、消息操作、阅读辅助、UI 状态所有权、键盘与关键路径可用性、桌面通知；通用 UI 盘点（弹窗库、Toast、主题、断点、动画、拖放、i18n、PWA）不纳入本文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的聊天工作台由会话导航（Topic 侧栏）、消息区与 Lexical 工作台式输入区组成：

- Topic 列表：单击/双击 250ms 定时器区分导航与开新 tab、拖拽引用到输入框、右键菜单、悬浮元数据卡、未读点、失败/运行/等待人工图标与运行耗时、草稿提示；Topic·Thread 并排（`ConversationArea` 的 portal 支持）与桌面端多 tab 由路由层承担。
- 输入区是一个可扩展工作台：草稿按会话（messageMapKey）自动恢复、输入历史按 user×agent scope、IME 组合态、文件粘贴/拖入、Markdown 输入预览、`@` mention（Fuse 模糊检索）、`/` slash action（编辑器插件实现）、goal tag chip、语音消息（MediaRecorder 录制上传后走常规发送链并 `preserveComposer`）。发送前配置区有 Token 用量明细与推理强度预设（模型实例级配置，跨 Agent 生效）。
- 发送/停止按钮是同一个交互位，`generating` 状态由 operation 驱动（经 ConversationStore 桥接全局 ChatStore 的 op 状态）；只读/无权限时提前置灰并给出 tooltip 原因；发送被阻塞时还会弹出队列托盘（QueueTray）提示排队与“立即发送”。
- 工具审批卡片有全局键盘快捷键（1/2/↑/↓/Enter），由共享 arbiter 分发到唯一一张卡片；审批选项带 `role="radiogroup"/"radio"` 语义。无障碍覆盖是“点状”而非体系化的，消息操作栏图标按钮、Topic 行存在明确缺口。
- 桌面端（Electron）完成/审批通知与聊天状态直接联动并深链回具体 Topic；Web/PWA 没有系统级通知，只靠未读点 UI。
- 消息内容渲染（conversation-flow 算法、虚拟列表、Markdown）一律属于消息渲染器笔记，本文只记录工作流与界面状态。

## 工作台边界与用户主链

```text
进入 Topic（路由参数 -> useAgentContext -> ConversationProvider，界面入口 ConversationArea.tsx:134-144）
  -> Topic 侧栏：切换 / 双击开 tab / 拖拽引用 / 未读点 / 运行态反馈 / 草稿提示 / 搜索抽屉（会话导航）
  -> Lexical 编辑器：草稿恢复 / 历史 / mention / slash / goal chip / 文件粘贴 / 语音消息（发送前配置：Agent、模型、执行设备、审批模式、Token 明细、推理强度）
  -> 发送按钮（生成中变停止；排队时 QueueTray）-> 流式输出（ChatMiniMap、滚动快照、keepMounted 由渲染器笔记覆盖）
  -> 消息操作：编辑/复制/重试/删除/分支/审批/翻译/TTS（错误卡重试见 PendingRetryTurn）
  -> 离开 / 再次进入：滚动快照与草稿恢复现场
```

边界：消息数据如何分桶、CRUD 落库属于会话与消息管理；发送后任务如何执行、审批如何恢复任务属于对话请求与上下文；消息列表虚拟化、角色分派、Markdown 与组件渲染属于消息渲染器。通用界面盘点（弹窗库、Toast、主题、断点、动画、灯箱、拖放、i18n、PWA 安装、离线提示）不属于本类目正文范围，所在位置见 [`../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md`](../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md)。

## 1. 页面结构、导航与多窗口

- **工作台结构**：Agent 聊天页由 `ConversationArea.tsx` 组装——`ConversationProvider`（134-144 行）内是消息区（`ChatList`，158-183 行，含悬浮头间距与子 Agent 只读提示 footer）与输入区（`MainChatInput`/`HeterogeneousChatInput`，187-191 行，异构 Agent 用简化输入）；侧栏与工作台同层布局。Topic 与 Thread 并排打开由 chat portal（开/同步两个入口）与桌面端多 tab 路由（`src/spa/router/tabRouter.tsx`）承担，属于路由层能力。
- **移动端**：`(mobile)` 路由树 + 独立 `entry.mobile.tsx` SPA，底部 TabBar；移动端 Topic 行单击直接导航（见下节），输入区有 `ChatInput/Mobile` 变体。响应式断点细节属通用盘点，不在本文。
- **多窗口/桌面 tab**：桌面端 Electron 每 tab 挂独立 memory router（`desktopRouter.config.desktop.tsx` 注释），会话可多开；本文确认其存在，跨 tab 的草稿/busy 同步语义未验证。

## 2. 会话列表、搜索与现场恢复

- **Topic 行交互**（`AgentSidebar/Topic/List/Item/index.tsx`）：桌面端单击延迟 250ms 以便把双击解释为“打开新 tab”——单击处理器（229-239 行）里 `setTimeout(..., 250)`，双击处理器（241-254 行）取消待执行单击并开 tab；模块级 `pendingSingleClickTimer`（76 行）保证快速跨行点击只执行最后一次动作；移动端单击直接导航（236-238 行）。拖拽引用到输入框走 `startTopicDrag`（220-227 行）；行内还有右键菜单、悬浮元数据卡（313-316 行，repo/branch/worktree/PR/CI）、未读点（288 行，含“运行尾巴”掩蔽期的即时未读 283-286 行）、失败/运行/等待人工图标（256-264 行，`#16518` 掩蔽已见输出的运行尾巴）、工作目录标签（270-281 行）与“草稿”红色提示（298-311 行 `useHasDraft`）。
- **搜索与全量查找**：`TopicSearchBar` 与 `AllTopicsDrawer`（`Topic/AllTopicsDrawer/Content.tsx:62-64` 有关键词时走服务端 `useSearchTopics`；服务端 BM25 匹配 Topic 标题与消息内容——实现见会话与消息管理笔记第 5 节；结果不会直接标出或滚动到命中的具体消息）。列表本身按 Flat/按时间/按状态/按项目多种模式组织（由列表视图参数驱动，改的是查询不是消息树）。
- **消息列表滚动现场（快照）**：滚动快照 store（`ChatList/utils/scrollSnapshotStore.ts`，`saveScrollSnapshot` 133 行）持久化 `{atBottom, offset, savedAt}`，`useTopicScrollPersist`（`ChatList/hooks/useTopicScrollPersist.ts:61-195`）在离开/进入时保存与恢复（无快照时滚到最后一条，192-195 行）；虚拟列表滚动机制与 `keepMounted` 见消息渲染器笔记。
- **小地图**：`ChatMiniMap` 在消息足够多时显示 user 消息锚点（`useMinimapData.ts:19` 只收 user 消息），悬停展开预览，点击 `scrollToIndex`（61 行），指示器带 `aria-label`（`MinimapIndicator.tsx:18`）与 aria-current。

## 3. Composer、草稿、附件与快捷输入

### 3.1 输入编辑器是一个可扩展工作台

`src/features/ChatInput/InputEditor/index.tsx`（650 行）基于 Lexical 编辑器（`Editor` from `@lobehub/editor`，549-561 行）：

- **发送键位**：`onPressEnter`（620-643 行）——历史弹窗打开时 Enter 确认历史项；Shift+Enter 换行；Alt+Enter 加 AI 消息；全屏模式只认 Cmd/Ctrl+Enter；否则 `shouldSendOnEnter` 决定（Enter 或 Mod+Enter 偏好）。`onKeyDown`（617-619 行）把键位先交给输入历史处理。
- **IME 组合态**：`useIMECompositionEvent`（126 行）贯穿 autocomplete 跳过（304-305 行）、Enter 不发送（628 行）、组合开始前清除占位节点（591-601 行）。
- **草稿**：`draftKey = contextKey`（按会话隔离，`Conversation/ChatInput/index.tsx:502`）；`useChatInputDraft`（`hooks/useChatInputDraft.ts`）在编辑器 init 时恢复（67-76 行）、onChange 时防抖保存（45-58 行）、onBlur 时 flush（60-63 行），并订阅 draftKey 变化先持久化旧的再恢复新的（82-102 行）；存储层 `draftStorage.ts`（111 行）写 localStorage。离开页面前若编辑器非空注册 `beforeunload` 提示（246-248 行），避免草稿静默丢失。
- **输入历史**：`InputHistoryPopup`（540-548 行）——输入为空时 ArrowUp 打开，↑/↓ 移动、Enter/Tab 确认、Escape 关闭（`inputHistory.handleKeyDown`）；存储按 **user × agent scope**（`inputHistoryStorage.ts:31-41`，localStorage key `lobechat:chat-input-history:v2:user:<uid>:agent:<aid>`，上限 50 条，6 行），历史弹窗里显示 ghost markdown 预览（563-575 行）。
- **mention / slash / action tag**：
  - `@` mention 按 Agent/话题/文件等分类并用 Fuse 模糊检索（153-221 行）；
  - `/` slash 项来自 `useSlashActionItems`（254-264 行）；
  - 两者都是编辑器选项（`mentionOption` 485-496 行、`slashOption` 498-501 行），不是发送前字符串替换；
  - action tag 是 Lexical 装饰节点（`InputEditor/ActionTag/` 下的节点与插件，正则把用户输入的 `<skill …/>` 变 chip）；
  - `/goal` 目标标记由 `goalTag.ts` 的 `insertGoalTag` 插入（92-98 行，必须是消息前缀，`isGoalPrompt` 识别）。
- **文件粘贴/拖入**：paste 事件监听上传（235-248 行）；拖放文件与 skill/tool chip 拖入编辑器（`useSkillDrop.ts`、`skillDragData.ts`），`insertLocalFileTags.ts` 插入本地文件 tag。
- **语音消息**：`ChatInput/VoiceMessage/`（录制模块）用 MediaRecorder 录制，经 `sendVoiceMessage`（`sendVoiceMessage.ts:26-44`，带 `preserveComposer: true`）走常规发送链；发送期间输入 loading 时不接受新录音（`ChatInput/index.tsx:409-430`）。
- **只读态**：`editable={canCreateContent && canUseResource}`（554 行）。

### 3.2 发送前配置

`ModeSelector` 切换 Chat/Agent 模式；Agent 模式出现执行设备、工作目录/仓库、分支或 Worktree、审批模式和上下文窗口（这些面板在 `ChatInput/ActionBar` 的 `AgentMode`/`Params` 等目录）。模型按钮切换当前 topic 模型（topic 级快照语义见会话与消息管理笔记 1.3）。

推理强度预设（`ChatInput/ActionBar/Effort/`，`Controls.tsx:79-129`）来自**用户级模型实例配置**（`index.tsx:15-44` 注释：不属于 Agent 的 chatConfig——跨 Agent 跟随用户），经加载器加载。Token 用量/预算明细条（`ChatInput/ActionBar/Token/`，`useTokenBreakdown.ts:75-79,140,179-189` 按对话、历史摘要、系统角色、工具与上限等来源拆分）常驻发送区上方（非 dev 模式且占比 ≤50% 时隐藏，`TokenTag.tsx:36`）。

## 4. 发送、排队、流式反馈与停止

- **发送/停止按钮**（`src/features/ChatInput/SendArea/SendButton.tsx:12-48`）：生成/禁用状态读自 ChatInput store 的 `sendButtonProps`（17 行），`handleSendButton`/`handleStop`（18 行）——普通状态点击发送，生成状态切换为停止动作；只读权限（`usePermission('create_content')`，23 行）与 Agent 资源 view-only（27-29 行）会把按钮置灰，外面套 `<Tooltip title={reason}>`（45-46 行）把“为什么不能发送”用无障碍可读文案暴露出来。
- **状态来源**：按钮属性在 `src/features/Conversation/ChatInput/index.tsx:399-407` 组装——生成态由状态选择器按 `isInputVisiblyLoading` 计算（237、290-294 行），停止动作接 `stopGenerating`；禁用态（298-299 行）由输入空/上传中/`disableQueue && 输入加载中`/宿主只读决定。该状态是 operation 状态选择器（`INPUT_LOADING_OPERATION_TYPES`，见对话请求与上下文笔记第 1 节），**按钮状态并非根据 DOM 中最后一条消息猜测**。发送处理器（`handleSend`，332-397 行）在触发时重新校验（上传中/队列阻塞/内容为空则不发），有定时发送时先提交定时任务（372-376 行）。
- **排队反馈**：发送被阻塞操作类型（`QUEUE_BLOCKING_OPERATION_TYPES`）阻塞时 `enqueueMessage`（执行侧见对话请求与上下文笔记第 8 节），输入区上方出现 `QueueTray`（463 行；`queuedMessageCount` 266-268 行）展示排队条目与“立即发送”（取消排队中阻塞 op），另有运行状态短语、进度与目标武装状态等悬浮托盘（464-468 行）。
- **发送错误**：`InputCompletionErrorAlert` 与 sendMessageErrorMsg Alert（440-449 行）就地显示失败原因，编辑内容由执行链恢复（见对话请求与上下文笔记第 6 节）。
- **交互层注意点**：发送权限在 UI 侧提前反映，但最终权限仍由服务端校验；只读用户可以阅读同一 Topic，但不能通过按钮绕过权限发送。`MessageFromUrl`（`?message=` 参数）在 Topic 转移回填（`AgentTransferMigration`）占位期挂起，回填完成后自动发送（`ConversationArea.tsx:208-216`）。

## 5. 消息操作、分支与版本导航

- **操作入口**：`Messages/components/MessageActionBar/index.tsx`（90-169 行）用 `ActionIconGroup` 渲染；各角色配置在助手、用户、助手组、任务四个 Actions 目录（`useActionsBarConfig` 经 `ConversationProvider.actionsBar` 注入）。助手消息默认编辑、复制；有工具时默认“删除并重新生成”；菜单还提供评论、创建分支、折叠流程、TTS、翻译、分享、选择/多选、重新生成、删除；用户消息默认重新生成、编辑、复制；错误消息显示重试与删除（`PendingRetryTurn` 独立待重试回合组件 + 配套 hook）。工具/任务块另有审批、拒绝、取消和删除孤立工具消息，编辑文件卡可展开并查看/隐藏 diff。
- **分支导航 UI**：`Messages/components/MessageBranch.tsx`（86/97 行 `role="button"`）画在子消息上；数据语义（激活索引在父消息 metadata）见会话与消息管理笔记 4.2。版本树/兄弟导航的完整界面形态本次未逐一核对（属于消息渲染器笔记的组件装配范围）。
- **操作可用性**：审批类操作对 view-only 成员直接不渲染（`ApprovalActions.tsx:319-321`）；发送/重试按钮的可用性随 operation 状态变化（第 4 节）。
- 消息操作栏如何装配进消息壳（`MessageActionProvider`/`SingletonMessageActionsBar`）属于消息渲染器笔记。

## 6. 阅读辅助与多会话反馈

- 虚拟列表用 Virtua 渲染 `conversation-flow.parse()` 产出的 flat list（列表机制、`keepMounted`、索引空间转换等全部属于消息渲染器笔记）；流式消息和有文本选区的消息强制 `keepMounted`（`ChatList/components/VirtualizedList.tsx:256-290`，`useSelectionMessageIds` 注释说明回收节点会丢选区），避免 Markdown 动画重播或选区被回收。界面呈现的阅读辅助（ChatMiniMap、滚动快照、`scrollToIndex`）见第 2 节。
- **多会话/后台生成的界面反馈**：Topic 行的运行/失败/等待人工图标、未读点与耗时（第 2 节），以及完成/审批的桌面通知（第 9 节）；“哪一条仍在运行并返回对应现场”由 operation 状态驱动这些 UI（`useOperationState` 桥接全局 op 状态到会话级 store 的 `operationState` prop，`ConversationProvider.tsx:91`）。

## 7. Chat UI 状态所有权与同步

- **按会话隔离**：`ConversationProvider`（`src/features/Conversation/ConversationProvider.tsx:128-138`）为每个 context 创建独立 ConversationStore 实例；**store 实例跨 topic 存活**，切 topic/thread 时 `StoreUpdater` 的 `useLayoutEffect`（94-118 行）在 paint 前原地重置 UI-only 状态：
  - 重置：`activeIndex`、`atBottom`、`inputMessage`、`messageEditingIds`、`pendingArgsUpdates`、`selectedMessageIds`、`selectionMode` 等（`createEphemeralResetState`，`store/initialState.ts:87-102`）；
  - 保留：`editor`、`chatInputOverlayHeight`、`virtuaScrollMethods` 等仍挂载的基础设施（80-86 行注释）。

  数据层细节见会话与消息管理笔记 2.2/2.3。
- **滚动 API 注册进 store**：滚动方法通过 `registerVirtuaScrollMethods` 注册进局部 store 的 `virtuaList/action.ts`（81-83 行）；`activeIndex` 由 `calculateActiveIndex`（54-75 行）按可见区域内“top 最小、ratio 最大”的启发式算出，用于“当前阅读到哪条消息”的高亮/侧边导航（`upsertVisibleItem` 130-137 行）。
- **草稿**：输入草稿按会话（draftKey=contextKey）保存并自动恢复（第 3.1 节）；输入历史按 user×agent scope（第 3.1 节）；离开页面前 `beforeunload` 提示防止草稿静默丢失。

## 8. 键盘、焦点与关键路径可用性

### 8.1 无障碍：点状覆盖，存在明确缺口

**做得到位的具体证据**（有文件行号支撑）：
- `Conversation/ChatItem/components/Actions.tsx:34` 消息操作栏容器带 `role="menubar"`（`User/Actions/index.tsx:75` 亦同）。
- `Conversation/WorkingSidebar/ProgressSection/index.tsx:160-165` 折叠面板用 `role="button"` + `aria-expanded` + `aria-controls={listId}` 三件套。
- `Conversation/WorkingSidebar/Browser/index.tsx:441-443` 加载指示器用 `role="progressbar"` + `aria-valuetext`。
- `Conversation/ChatList/components/RefreshError.tsx:37,40` 消息列表刷新失败提示用 `role="status"` + `aria-live="polite"`，能被屏幕阅读器主动播报。
- `ChatInput/ControlBar/GitStatus.tsx:383-401` Git 同步按钮用 `aria-busy`/`aria-disabled` 反映异步状态。
- `ChatInput/SendArea/SendButton.tsx:45-46` 发送按钮禁用时用 Tooltip 暴露原因（第 4 节）。
- `src/features/AudioPlayer/index.tsx:328` 播放/暂停按钮 `aria-label` 随状态切换文案（“播放”/“暂停”），另有 seek/download/voiceMessage 相关 `aria-label`（339/369/382/393 行）。
- 工具审批选项带 **`role="radiogroup"`（`ApprovalActions.tsx:325`）与 `role="radio"`（333/362 行）** 语义关联（见 8.3 快捷键）。

**明确的缺口**（如实指出，不夸大也不回避）：
- Topic 列表行（`AgentSidebar/Topic/List/Item/index.tsx`，grep 无 `tabIndex`/`onKeyDown`/`role`/`aria-label` 命中）；
- 消息操作栏里的单个 icon 按钮（`Messages/components/MessageActionBar/index.tsx` 无 `aria-label`）——这些是 `ActionIcon`，视觉上靠 title/tooltip 提示，但本次没有确认 `@lobehub/ui` 的 `ActionIcon` 组件内部是否自动把 title 映射成可访问名称（三方包内部实现，未下钻），如果没有，纯图标按钮对屏幕阅读器就是无文字描述的。
- 双击/单击 250ms 定时器（第 2 节）完全依赖鼠标事件（`onClick`/`onDoubleClick`），本次未找到对应的键盘可达实现（如 Enter 打开、Tab 可聚焦的 `tabIndex`）——键盘用户能否等效完成“单击导航/双击开新 tab”这两个操作未核实到证据，倾向于没有。
- 虚拟列表（`ChatList/components/VirtualizedList.tsx`）渲染的消息条目本次未找到 `role="log"`/`aria-live` 一类支持“新消息到达时屏幕阅读器播报”的实现（仅 `onKeyDownCapture` 304 行与 `aria-hidden` 352 行），流式生成的文字增量对屏幕阅读器用户是不可感知的。

**结论**：无障碍支持是工程师按需加的“点状覆盖”（哪个组件出问题/被特别关注就补一处 aria），而不是设计系统层面统一约定的产物——同一类交互（图标按钮）在有的地方有 `aria-label`（`ChatInput/ActionBar/Model/index.tsx:89`、`ChatInput/ControlBar/WorktreeSwitcher.tsx:674`、`Tools/useControls.tsx:655,1581,1594` 等），在另一些地方没有（Topic 行、消息操作栏），取决于具体开发者是否补充。真正的 WCAG 合规判定需要人工用屏幕阅读器/键盘走一遍实际操作流程，本次只是静态代码扫描，结论仅限于“代码里有没有写这些属性”。

### 8.2 快捷键面板/帮助

- **发现型提示**：`src/features/CommandMenu/components/CommandFooter.tsx`（1-29 行）在 Cmd/Ctrl+K 命令面板底部常驻显示“↵ 打开 / ↑↓ 选择”两个键位提示，只覆盖命令面板内部的操作。
- **完整列表（可编辑）**：设置页 `src/features/Settings/hotkey/index.tsx`（1-26 行）组织三个分组——桌面端（仅桌面端显示，19 行）/必备/对话（`features/Conversation.tsx`，21-91 行，当前只有 Conversation 分组）。每一项用 `@lobehub/ui` 的 `<HotkeyInput>`（48-56 行）渲染，支持**自定义改键**、清除绑定、冲突检测（39-44 行遍历其它已绑定项做重复检测）、自动保存（87 行）——不只是一个只读的快捷键说明面板。设置页路由只留薄壳转发设置功能；聊天作用域热键定义在 `src/hooks/useHotkeys/chatScope.ts` 与 packages 下的常量/类型文件。
- 命令面板本身的完整键位表（Cmd+K 打开、Esc 返回/关闭、Backspace 返回、Tab 进 AI 模式、↑↓ 选择、Enter 确认）本次靠 `useCommandMenu.ts` 的 Esc/滚动锁定 `useEffect` 与仓库内 `README.md` 记录的键位表交叉确认；用户能直接看到的仅有 `CommandFooter` 那两条提示 + 设置页的可编辑列表。

### 8.3 工具审批快捷键

`ApprovalActions.tsx:229-276` 支持 1/2/3…（数字选行）、↑/↓（切换选项）、Enter（提交），并正确跳过 INPUT/TEXTAREA/contentEditable 焦点（243 行）与组合键（245 行）。与旧实现不同，监听器现在不是每张卡片各挂一个 `window` listener，而是经 `registerPendingHotkeyCard`（282-296 行）注册到共享 arbiter（`packages/shared-tool-ui/src/pendingHotkeys.ts:38-46`）：arbiter 只挂一个 `window keydown`，按“包含事件目标的卡片优先，否则最近注册的卡片”把每次按键分派给**恰好一张**卡片（28-32 行），避免多张审批卡同时响应；containment 覆盖 `data-pending-hotkey-scope` 标记的 InterventionBar/全局审批卡（287-293 行）。选择拒绝后自动聚焦原因输入框（221-227 行），该输入框有独立的 Enter/↑ 处理（298-310 行）。视觉上选项带编号（365 行）。

## 9. 桌面通知与跨平台连续性

桌面通知与聊天状态的联动是本次调查中确认度最高的一处集成：`src/store/chat/utils/desktopNotification.ts`（全文件 179 行）定义了两个统一注入点：

- `notifyDesktopAgentCompleted`（155-179 行）：Agent 回复完成时调用，`title` 按“话题标题 → Agent 名称 → 通用兜底”优先级解析，`body` 是把 markdown 回复剥成纯文本并截断到 256 字符（`buildNotificationBody`，93-102 行，上限常量 27 行），导航深链回具体的 agent/topic/group 会话（38-57 行，按 groupId+topicId → groupId → agentId+topicId → agentId 四级优先级拼 URL，含 workspaceSlug 前缀 29-30 行）。调用点在 `store/chat/slices/aiAgent/actions/runAgent.ts:250-253`，紧跟在“停止 loading”之后触发，同批还会调用 `markTopicUnread`（255-263 行）——**桌面通知和“Topic 未读点”是同一个完成事件驱动的两个并行副作用**（执行侧见对话请求与上下文笔记第 6 节）。
- `notifyDesktopHumanApprovalRequired`（104-133 行）：需要人工审批工具调用时触发，标题走同一套解析逻辑，额外调用 `desktopNotificationService.setBadgeCount(1)`（121 行）在 dock/任务栏打角标，并传 `force: true, requestAttention: true`（124-126 行，前台窗口也强制弹通知、抢占用户注意力，区别于普通完成通知）。调用点 `runAgent.ts:303`（`step_start` 的 human_approval 分支），同时把 Topic 置 `waitingForHuman`（304-317 行）。
- 两者都通过 `isDesktop` 短路（108/159 行），Web/PWA 环境下直接跳过，说明这套通知目前只在 Electron 桌面端生效，**没有找到** Web Push API/Service Worker 通知的对应实现（搜索范围：`desktopNotification.ts` 与 runAgent 调用点），PWA 模式下完成/审批事件不会有系统级通知，只能靠“未读点”UI 或回到标签页查看。

## 10. 设计取舍与已确认边界

- **Topic 行的双击开 tab 与单击导航依赖 250ms 定时器**，快速跨行点击由模块级 timer 取消前一次动作；但完全依赖鼠标事件，键盘可达性未核实（第 8.1 节）。
- **虚拟列表的 `keepMounted` 只保护生成消息和选区**，普通历史消息仍会被回收，因此任何依赖 DOM 的扩展功能都必须通过 scroll API 而不能缓存节点（列表机制详见消息渲染器笔记）。
- **发送权限在 UI 侧提前反映**，但最终权限仍由服务端校验；只读用户可以阅读同一 Topic，但不能通过按钮绕过权限发送（第 4 节）。
- **审批快捷键的共享 arbiter 设计**：多张审批卡并存（对话内卡片 + 全局审批通知卡）时按键只驱动一张卡，避免“一个键位同时操作两张卡”；代价是键盘操作的可发现性仍依赖视觉阅读（第 8.3 节）。
- **会话级 store 跨 topic 存活 + 原地重置**：UI-only 状态不用手写清理逻辑，但重置清单必须与新加的 UI-only 字段保持同步（第 7 节，数据层语义见会话与消息管理笔记 2.2）。
- **类目边界**：本笔记只记录用户工作流与界面状态；消息数据模型与 CRUD 在会话与消息管理笔记，发送与审批的执行语义在对话请求与上下文笔记，conversation-flow 算法与虚拟列表渲染在消息渲染器笔记。通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、拖放、i18n、PWA 安装、离线提示）不在本文正文。

## 11. 未验证事项

- `ActionIcon` 的 `title` prop 是否在渲染时自动映射为 DOM `aria-label`——三方包内部实现，未下钻，直接影响第 8.1 节里“大量图标按钮有没有 aria-label”的判断范围。
- 双击/单击 250ms 定时器的键盘可达实现未找到证据（第 8.1 节）。
- 工具快捷按钮在 + 面板的拖拽排序具体实现机制未读 `ChatInput/ActionBar/Tools/useControls.tsx` 确认（拖拽库盘点不属于本文）。
- 输入框文件拖入/拖出时的悬停视觉反馈样式未逐一核对（拖放视觉属通用盘点范围）。
- 视觉效果、键盘焦点顺序、响应式行为与系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 移动端/桌面端的布局差异与断点实现属于通用盘点范围，未在本笔记展开。
- 语音消息的录音/上传/回放全链未运行验证（MediaRecorder 兼容性、`sendVoiceMessage` 与发送链的合并行为仅静态确认）；桌面端多 tab 之间草稿/busy/active session 的同步语义未验证。
- 审批快捷键的 arbiter 分派（containment/最近注册）在“焦点不在任何卡片”时的实际命中行为未运行验证。

## 12. 关键源码索引

- `src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`（134-144 工作台组装，98-108 重连）
- `src/features/AgentSidebar/Topic/List/Item/index.tsx`（76-254 行交互，256-311 状态反馈）、`Topic/AllTopicsDrawer/Content.tsx`（62-64 服务端搜索）
- `src/features/Conversation/ConversationProvider.tsx`（128-138）、`StoreUpdater.tsx`（94-145）
- `src/features/Conversation/store/slices/virtuaList/action.ts`（54-138 滚动 API 与 activeIndex）
- `src/features/ChatInput/InputEditor/index.tsx`（517-534 草稿恢复，582-601 IME/保存，617-643 键位）
- `src/features/ChatInput/SendArea/SendButton.tsx`（12-48）、`src/features/Conversation/ChatInput/index.tsx`（237-299 状态，332-407 发送与按钮，409-430 语音）
- `src/features/Conversation/ChatInput/QueueTray.tsx`、`sendVoiceMessage.ts`（26-44）
- `src/features/ChatInput/ActionBar/Token/`（useTokenBreakdown.ts:75-189）、`ActionBar/Effort/`（index.tsx:15-44）
- `src/features/Conversation/Messages/components/MessageActionBar/index.tsx`（90-169）
- `src/features/ChatMiniMap/`（useMinimapData.ts:19,61）、`src/features/Conversation/ChatList/utils/scrollSnapshotStore.ts`（133）
- `src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx`（229-296 快捷键，325-362 radiogroup）
- `packages/shared-tool-ui/src/pendingHotkeys.ts`（38-46 arbiter）
- `src/features/Settings/hotkey/index.tsx`（1-26）、`features/Conversation.tsx`（39-44,87）
- `src/features/CommandMenu/components/CommandFooter.tsx`（1-29）
- `src/store/chat/utils/desktopNotification.ts`（38-179）、`src/store/chat/slices/aiAgent/actions/runAgent.ts`（250-263, 303）
