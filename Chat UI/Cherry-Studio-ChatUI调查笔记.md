# Cherry Studio Chat UI 调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：从 `../Chat/Cherry-Studio-Chat调查笔记.md`（2026-08-10 调查）迁移现有段落与证据；通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、右键菜单双模式）保留于原 Chat 笔记，待可选界面专题承接
>
> 调查范围：工作台结构、会话导航、Composer 与草稿、发送前配置、生成反馈、消息操作、分支树图导航、键盘与无障碍、桌面集成；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **Home 和 Agent 两个入口共用同一套"会话壳 + composer + 消息列表"框架**，但不是共用组件树，而是共用类型契约（`MessageListProviderValue`），由两个适配器各自注入能力——下游组件用存在性判断决定要不要渲染某个按钮。
- **会话单位 Topic 是导航单位**：侧栏列表 + 右侧分支面板（React Flow 树图）+ 消息列表 `< i/N >` 兄弟导航三套入口并存；分支面板看到的是"DB 树 + live overlay"合并结果。
- **消息搜索是 DOM 搜索**：`CSS Custom Highlight API` 高亮、TreeWalker 过滤正文文本节点；虚拟化窗口外消息搜不到（数据侧限制见会话与消息管理笔记 5）。
- **多模型并行**通过 Composer 的"提及模型"多选触发：选中 N 个模型 → 主进程并行 N 个 execution，读侧按兄弟组横向/网格展示（执行语义见对话请求与上下文笔记 8）。
- **桌面集成与聊天状态联动最少**："助手回复完成"系统通知开关接不到任何触发点（空挂钩）、托盘无角标、无快捷键速查浮层。
- **无障碍**：Topic/Session 列表有完整的 listbox 语义，但消息操作栏默认渲染路径（复制/编辑/删除等最高频按钮）缺 `aria-label`，Composer 输入区本体也没有可访问名称。

## 工作台边界与用户主链

```text
进入 Home 或 Agent 入口（同一套会话壳 + composer + 消息列表框架，适配器注入能力）
  -> Topic 列表选择/新建/重命名/删除（拖拽排序仅助手分组可用）
  -> Composer 组织输入：文本、附件、提及模型、知识库、联网、推理强度、工具面板
  -> 发送 -> 生成反馈（流式尾部、兄弟组、Topic 行运行指示）
  -> 消息操作：复制/编辑/重新生成/删除/翻译/分支/导出
  -> 分支导航：< i/N > 兄弟切换 + 分支面板树图
  -> 搜索定位（ContentSearch -> DOM 高亮与滚动）
  -> 再次进入：恢复 Topic 现场
```

边界：会话与消息的数据语义（树、指针、锚点）见 `../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md`；提交、上下文拼装、流式执行与最终化见 `../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md`；消息内容、Markdown、虚拟列表与消息壳的渲染实现见 `../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`（内容渲染类内容一律链接过去，不复制）。

## 1. 页面结构、导航与多窗口

### 1.1 工作台拓扑：一套框架，两套适配器

Home 和 Agent 两个入口共用同一套"会话壳 + composer + 消息列表"框架，但不是共用一个组件树，而是共用**类型契约**：`MessageListProvider`（`src/renderer/components/chat/messages/MessageListProvider.tsx`）定义了 `MessageListState/Actions/Meta` 的 shape，Home 用 `useHomeMessageListProviderValue`（`src/renderer/pages/home/messages/homeMessageListAdapter.tsx`）实现，Agent 用 `useAgentMessageListProviderValue`（`src/renderer/pages/agents/messages/agentMessageListAdapter.tsx`）实现。`MessageList.tsx`、`MessageGroup`、`MessageFrame` 等渲染组件只读这两个 context，完全不知道自己在哪个入口下（适配器的能力注入细节见 6.2；组件装配见消息渲染器笔记"入口与页面适配"）。

### 1.2 侧栏折叠与窗口宽度：无断点驱动，手动命令 + 页面级最小宽度

- 侧栏展开/折叠是**手动命令**（`app.sidebar.toggle`，`HomePage.tsx:408`），未发现 `ResizeObserver`/`matchMedia`/CSS `@container` 驱动的自动折叠逻辑——不随窗口变窄自动收起。
- 主窗口最小可缩放宽度随页面动态调整：进入聊天工作台时 `AppShell` 立即调用 IPC 把最小尺寸从默认 `MIN_WINDOW_WIDTH=960px`（`src/shared/utils/window.ts:1`）临时放宽到 `SECOND_MIN_WINDOW_WIDTH=520px`（该逻辑从 `HomePage.tsx:665-670` 迁到 `AppShell.tsx:140`，`window.main.set_minimum_size`），离开时还原——聊天页允许拖得比其他页面更窄。
- 阅读宽度限制是独立机制：`NarrowLayout.tsx` 把消息内容限制在 `800px`（`chat.narrow_mode` 偏好，默认 `true`，`preferenceSchemas.ts:184,587`），是用户可关闭的排版偏好。
- （断点/窗口管理的完整盘点保留于源笔记 13.9，此处只记录与聊天主链的交点。）

## 2. 会话列表、搜索与现场恢复

### 2.1 Topic 列表与生成运行指示

- Topic 列表空状态（`TopicListBody` 的 `emptyFallback`，`Topics.tsx:1662` 附近）与加载骨架的呈现盘点保留于源笔记 13.3。
- **运行指示器与聊天主链的交点**：Topic 列表行右侧的运行指示统一为跨面板组件 `ConversationRowStatus`（`src/renderer/components/chat/resourceList/base/ConversationRowStatus.tsx:20-51`）：状态由 `Topics.tsx:1727-1735` 从 topic 流状态派生——等待审批显示为 warning 徽标（badge）、`pending` 用 `Loader2` 旋转图标、`error` 用 `CircleAlert`、"已完成但未读"（`!isActive && isTopicStreamFulfilled`）用绿色小圆点；指示器是绝对定位 overlay，悬停/聚焦时淡出让位给 pin/delete 操作（`CONVERSATION_ROW_STREAM_INDICATOR_CLASS`）。`ConversationRowStatus` 带 `aria-label` + `role="img"`。

### 2.2 Topic 拖拽排序：仅助手分组可拖

- 只有当 Topic 列表按"助手分组"显示时才可拖（`canDragTopicItem`/`dragReady = isAssistantDisplayMode && ...`，`Topics.tsx:1136-1139,797`），按"时间分组"显示时完全不可拖——时间分组的顺序由时间戳决定，拖拽没有语义，这是有意为之的限制。
- 助手分组可整组拖拽重排（`canDragTopicGroup`/`handleTopicReorder` 的 `payload.type === 'group'` 分支，`:1150-1158,1187-1231`），带乐观更新和失败回滚（`setOptimisticAssistantOrderIds`，失败时 toast + 回滚，`:1215-1228`）。
- Agent 侧 Session 列表拖拽排序**未检索到独立实现**（`SessionItem.tsx` 只在右键菜单命中，未见拖拽相关代码路径）——判断为没有实现（源笔记 13.10/13.12）。

### 2.3 消息搜索工作流：命令触发 + DOM 高亮 + 滚动定位

- **触发**：`Chat.tsx:128-141` 注册命令 `chat.message.search`，取当前选中文本作为初始搜索词，调用 `contentSearchRef.current?.enable(selectedText)`；Esc 键关闭（`Chat.tsx:119-126`）。
- **过滤**：`Chat.tsx:164-174` 定义 `NodeFilter`——只接受祖先链上有 `.message-content-container` 且再往上有 `.message` 的文本节点；默认排除用户消息（`.message-assistant` 才放行），`filterIncludeUser` 打开后才纳入用户消息。搜索对象是 `document.createTreeWalker` 遍历出来的**真实渲染出来的文本节点**，不是数据模型字符串（`findRangesInTarget`，`ContentSearch.tsx:57-135`）——折叠/未渲染与虚拟化窗口外的消息搜不到（数据侧限制见会话与消息管理笔记 5）。
- **高亮**：用浏览器原生 **CSS Custom Highlight API**（`CSS.highlights.set('search-matches', ...)`/`'current-match'`，`locateByIndex`，`ContentSearch.tsx:171-198`）配合 `Range` 对象，样式在 CSS 里用 `::highlight()` 伪元素定义。
- **跳转**：`scrollElementIntoView(parentElement, target)`（`:189-193`），滚动容器是外部传入的 `searchTarget`（`Chat.tsx:391` 传的是 `mainRef`），不是 `window.scrollTo`。
- 大小写/整词切换重新触发 `search(true)`（`:322-326`），Enter/Shift+Enter 前进后退（`:285-305`），防抖 300ms（`:266`）。

### 2.4 现场恢复

切换 Topic 时保留哪些局部状态（草稿、滚动位置、面板开关）本次未核实；分支面板 dock/popout 时视口会按 `focusKey` 复位（6.3）。

## 3. Composer、草稿、附件与快捷输入

### 3.1 输入快捷操作（源笔记 12.2）

`ComposerSurface.tsx` 根据设置使用 Enter、Ctrl/Command/Alt/Shift+Enter 发送，单独 Shift+Enter 在非发送配置下换行。输入为空时 ArrowUp/Down 浏览历史，Enter/Tab 确认，Escape 关闭；Escape 还能退出展开编辑器。Tab 遍历 prompt variable，正文为空时 Backspace 可移除最后附件。支持文件拖放/粘贴、图片/文件 token、@ 实体引用、slash/工具面板和 follow-up 队列。

### 3.2 附件拖入反馈：绿色虚线高亮

拖拽经过 `useFileDragDrop.ts`（文件、文本、文件夹路径分别处理，不支持类型会 toast 提示，`:122-129`），视觉反馈是 2px 绿色虚线边框 + 半透明绿色蒙层（`ComposerSurface.tsx:2171-2173`，硬编码色值 `#2ecc71`，不走 CSS 变量主题色）。

### 3.3 草稿与编辑恢复状态机

`ChatComposerInner` 在一个组件内混杂了草稿缓存、输入历史导航、编辑会话恢复（含"编辑消息时保存旧草稿、取消编辑时还原"的完整状态机）、mentioned models、reasoning effort 的乐观更新+回滚、queued followups 等多套独立状态机，用一堆 ref 协调（`inputHistoryToolsRef`、`skipDraftCacheWriteForHistoryPreviewRef`、`editingOriginalFilePartsByTokenIdRef`、`savedDraftBeforeEditingRef` 等）——功能齐全但可读性门槛高（取舍见第 10 节）。

以下两个行为已确认：

- **未发送草稿跨导航保留**（`292fb2064e`）：草稿按会话/对话粒度缓存（`chatDraftCache.ts`/`agentDraftCache.ts`），切换 Topic/标签页后再回来草稿仍在。
- **编辑用户消息可直接保存、不重发**（`b9f38187d5`）：编辑历史用户消息后提供"仅保存"路径（`editMessage` 写回 parts），不必触发重新生成。

## 4. Agent、模型、工具与发送前配置

### 4.1 Agent/模型快速切换（源笔记 12.3）

`ChatConversationControls.tsx` 同时提供 AssistantSelector 与 ModelSelector；模型可单选或多选，已选模型可移除并恢复 Assistant 默认模型。消息栏的"指定模型重新生成"只影响该次操作，不改写 Assistant 默认配置；composer 工具栏支持固定、取消固定、拖拽重排和恢复默认。

### 4.2 多模型提及模式：如何触发"多模型同时回复"（UI 侧）

`ChatConversationControls` 在 `useMentionedModelSelector` 为真时渲染 `ModelSelector multiple` + `SelectedModelsTrigger`（`:136-164`），选中结果经 `useChatMentionedModels` hook（`src/renderer/components/composer/variants/chat/useChatMentionedModels.ts`）管理：非多选模式下选一个模型会同步单模型 `onModelSelect`（`:108-121`，`handleMentionedModelsSelect`），多选模式下则只更新 `mentionedModels` 数组，不触发单模型切换。选中结果如何进入请求（`mentionedModels.map(m => m.id)` 进 payload、主进程解析与并行执行）见对话请求与上下文笔记 9、8。

### 4.3 发送前配置与请求的交界

知识库选择（`withKnowledgeScopePart`）、附件（file parts）、联网开关（`assistant.settings.enableWebSearch` 走 capabilityBody）、推理强度（`reasoningEffort` 独立字段）四类配置的最终去向见对话请求与上下文笔记 9；工具面板"要不要显示某工具"由 `ComposerToolRuntimeHost`/各 `defineTool` 在渲染期决定，实际携带由主进程模型能力判定（同上一节链接）。

## 5. 发送、排队、流式反馈与停止

- **发送入口**：`onSend` → `useChatRuntimeState.sendMessage` → IPC `ai.stream.open`（执行链见对话请求与上下文笔记 1）。
- **生成反馈**：流式尾部以 live 层渲染（`MessageLiveLayer`，历史/live 两层切分的渲染实现见消息渲染器笔记）；消息区初始加载骨架特意延迟 160ms 防闪烁（`MessageListInitialLoading`，`MessageListLoading.tsx:6-52`，`MESSAGE_LIST_INITIAL_LOADING_DELAY_MS`——呈现盘点保留于源笔记 13.3，此处记录与聊天主链的交点）。
- **暂停/停止**：Composer 外围有暂停、编辑定位、取消编辑、展开高度等工具按钮（均有 `aria-label`，`ComposerSurface.tsx:2114-2207`）；停止/暂停按钮状态与真实任务状态（`ActiveStream.status`）的对应关系本次未核实——停止入口的 UI 反馈与底层中断层语义见对话请求与上下文笔记 7。
- **Toast 交点**：Topic 侧导出图片用 `toast.loading({ key, promise, onError })` 再各自 success/error（`Topics.tsx:340-372`）；复制代码等操作的 toast 反馈盘点保留于源笔记 13.2/13.8。

## 6. 消息操作、分支与版本导航

### 6.1 消息操作清单与可用性（源笔记 12.1）

`messageMenuBarActions.tsx` 注册复制（纯文本/富文本）、编辑、重新生成、删除、翻译中止、新建分支、多选、保存到文件/知识库、复制图片、导出图片/Markdown（含 reasoning）、Word、Notion、语雀、Obsidian、Joplin、思源及点赞。助手的"指定模型重新生成"打开模型选择器；删除按设置确认并检查可删除状态。删除可用性语义（`8b78177a61`）：首轮消息可删；多模型回复组删除只删组内兄弟回复（隐藏的重新生成版本一并移除），组内任一回复仍在生成时删除按钮禁用并带解释性 tooltip（`messageDeleteAvailability.ts`）。

**可用性判定机制**：几乎所有 action 的 `availability` 都在判断 `!!actions.xxx`——能力是否出现完全由适配器注入的字段决定（6.2），不是 if/else 页面模式分支。

### 6.2 适配器注入的操作面：Home 可写、Agent 只读 + agent 专属

- **Home 适配器**（`homeMessageListAdapter.tsx`）：`state` 里 `readonly` 默认 false（即可写），`actions` 里塞了全套写操作——`deleteMessage/deleteMessageGroup/editMessage/startMessageBranch/setActiveBranch/regenerateMessage/translateMessage/removeMessageTranslation/renderRegenerateModelPicker`（`:800-835`），全部通过 `requireChatWrite('xxx')` 从 `ChatWriteContext` 拿真实实现（该 context 由 `ChatContent.tsx:268` 的 `<ChatWriteProvider value={runtime.chatWriteActions}>` 注入）。
- **Agent 适配器**（`agentMessageListAdapter.tsx`）：`state.readonly: true`（`:377`），`actions` 里**没有** `editMessage/deleteMessageGroup/setActiveBranch/regenerateMessage/translateMessage`（`:405-430` 找不到），但多了 `respondToolApproval/openArtifactFile/openAgentToolFlow/isDirectory/openInExternalApp`（经 `resolveWorkspaceFilePath` 把相对路径解析到 agent workspace 目录，`:118-125`）——agent 运行时才有的概念（工作区文件、工具审批、artifact 面板），Home 侧完全没有对应实现。还有一个 Home 没有的行为：`withTerminalErrorFallback`（`:45-73`）——agent 消息终态是 `error`/`success` 但没有可见 part 时补一条 `data-error` part，防止 UI 卡在空白/转圈（执行侧语义见对话请求与上下文笔记 6）。
- 总结：不是靠 if/else 判断"我是 Home 还是 Agent"，而是靠两份完全独立的 hook 各自组装一份 `MessageListActions` 对象，字段有没有由各自的业务上下文决定。

### 6.3 分支面板（TopicBranchPanel）：消息树的图形导航

右侧分支面板（`src/renderer/pages/home/components/TopicBranchPanel.tsx`，292 行）把整个 Topic 的消息树渲染成一张 React Flow 图，是"在树上选分支/开分支"的图形入口，与消息列表的 `< i/N >` 兄弟导航并存：

- **数据流**：面板打开时 `useQuery('/topics/:topicId/tree', { query: { depth: -1 } })` 拉全量树（64-68 行）→ `mergeTopicMessageFlowLiveTree` 叠加 live 态（76-79 行）→ `buildTopicMessageFlowGraph` + `layoutTopicMessageFlowGraph` 生成 React Flow 的 nodes/edges（80 行）；头部显示 `branchCount`/`nodeCount` 统计（253-259 行）。"DB 树 + live overlay 合并"的数据侧见会话与消息管理笔记 2。
- **图构建**（`components/chat/flow/topicMessageFlowGraph.ts`）：`buildTopicMessageFlowGraph`（14-61 行）把 `TreeResponse.nodes` 与 `siblingsGroups` 去重合并；`collectActivePath`（173-188 行）从 `activeNodeId` 沿 `parentId` 回溯活动路径；边按 `isActivePath / isSiblingBranch / isInactiveBranch` 打标。**布局**（`topicMessageFlowLayout.ts`）用 `@dagrejs/dagre` 做 `rankdir: 'TB'` 分层（60-75 行），节点固定 220×112（14-17 行）、nodesep 56/ranksep 96（23-29 行），兄弟顺序用 OrderConstraint 按（深度, 创建时间, id）强制排序（232-253 行）；边样式按状态着色：活动路径 `--success` 加粗 + `animated`，非活动分支淡色虚线，兄弟边普通虚线（`toReactFlowEdge`，162-191 行）。`isInputDraft` 草稿假节点机制已被移除（`ad0ce9cd04`）——空分支叶子是持久化树节点（`data.isAwaitingInput`），正常参与 dagre 布局，节点卡用 warning 配色 + "等待输入"状态标签标识（`TopicMessageFlowNode.tsx:64-67,227-232`）。
- **画布**（`TopicMessageFlowCanvas.tsx`）：`@xyflow/react`，`nodesConnectable/Draggable: false`、`onlyRenderVisibleElements`（只挂载可视区域节点）、minZoom 0.08/maxZoom 1.4、`zoomOnDoubleClick: false`（228-253 行）；`MiniMap`（右下，节点按角色着色，255-263 行）+ `Controls`（左下）+ 图例（254 行）；空树渲染空状态（209-220 行）。初始视口把根节点定位在画布顶部（`getRootFocusViewport`，zoom 0.85），`focusKey` 变化（面板 dock/popout 位置切换）时重新测量容器并复位视口（154-207 行）。
- **节点卡**（`TopicMessageFlowNode.tsx`）：role 徽标（user=success 系、assistant=info 系，25-32 行）、模型短名（`getModelShortLabel` 取最后一段，41-48 行）、两行 `preview` 摘要、状态圆点（pending/success/error/paused，34-39 行）、时间（MM/DD HH:mm）；`isActive` 节点 ring 高亮、非活动分支 `opacity-55`（223-235 行）；Handle 仅装饰。悬停 300ms 后 Popover 打开完整预览卡（`TopicMessageFlowNodePreviewCard`，74-164 行）：按需 `GET /messages/:id` 拉全量消息，复用主消息区的 `MessageContent` 真实渲染（150-158 行）；awaiting-input/上下文边界节点不触发（234-236、285 行）。
- **点击与右键**（`TopicBranchPanel.tsx`）：`handleNodeSelect`（86-128 行）分三种情况——有活动草稿锚点且点的是锚点：取消草稿并定位；点击活动路径上的节点：仅 `onLocateMessage` 定位不切分支；否则 `GET /topics/:id/path?nodeId=` 求该分支叶子后 `PUT /topics/:id/active-node` 切换并 refetch（"点到中间节点 = 切到该分支最新叶子"，与 `< i/N >` 的 `setActiveBranch` 同语义，数据侧见会话与消息管理笔记 4.2）。右键菜单（`CommandContextMenu`，271-285 行 + `getNodeContextMenuItems`，181-238 行）有三项："从这条消息发起新分支"（仅 assistant 且有 assistant 后代、非当前 active 节点；禁用原因区分"就是当前活动节点"/"没有后续消息"）、"复制分支到新 Topic"（`POST /topics/:id/duplicate`），以及 awaiting-input 叶子的"删除该分支"（`DELETE /messages/:id?awaitingInputOnly=true`，服务端守卫见会话与消息管理笔记 4.3）。
- **分支草稿工作流**：点"从这条消息发起新分支"（`handleStartBranchDraft`）经 `useTopicBranchActions.reserveBranch`（`src/renderer/pages/home/hooks/useTopicBranchActions.ts`）先 `POST /messages/:id/branches` 持久化空 user 叶子，流式进行中 `activate=false` 不挪动 active 指针，分支面板立即显示"等待输入"节点；不再广播 `draft-branch:<anchorId>` 假节点（数据侧语义见会话与消息管理笔记 4.3）。
- **重命名入口**：`Chat.tsx:143-162`（`topic.rename` 命令处理器）弹出 `PromptPopup` 取新名字（数据侧见会话与消息管理笔记 3.2；弹窗库完整盘点保留于源笔记 13.1，此处只记录聊天主链交点）。

## 7. 多会话、多模型、群聊与后台生成

- **多模型并行**：Composer 提及模型多选 → 主进程 N 个 execution 并行（执行语义见对话请求与上下文笔记 8）；读侧 `bucketAssistantSiblingsByModel` 按 `siblingsGroupId`/模型分桶后，同组兄弟以横向/网格布局展示，消息列表头部有 `< i/N >` 兄弟导航（数据分桶见会话与消息管理笔记 4.2；布局渲染见消息渲染器笔记"消息分组"）。
- **运行标记**：Topic 列表行的 `TopicStreamIndicator` 让用户在侧栏看到哪个会话仍在运行（2.1）；切换会话后 Main 进程仍可继续生成（渲染侧 detach 不 abort，见对话请求与上下文笔记 8）。
- 群聊、子 Agent、后台任务面板的界面区分本次未调查。

## 8. Chat UI 状态所有权与同步（含桌面集成）

### 8.1 UI 状态所有权：持久化预留 + 前端广播 + 桌面集成

- **分支草稿已是持久化行**：`Chat.tsx` 旧的 `branchDraftAnchorIdRef`/`branchSendAnchorOverrideIdRef` 三态 ref 状态机已被删除（`ad0ce9cd04`，`Chat.tsx` 相应约 84 行代码移除），"从历史节点开新分支"改为 `useTopicBranchActions.reserveBranch` 持久化空 user 叶子 + `fill-reserved` 填充（6.3；数据侧语义见会话与消息管理笔记 4.3）——原先"隐式三态机容易漏清空"的脆弱点随机制移除而消失。
- **live branch 前端状态广播**：`TopicMessageFlowLiveState` 仍是纯前端结构，现在只广播流式中消息（草稿假节点已删除）；"草稿/面板/流式"这些 UI 状态的事实源分散在组件 ref、hook 与 SWR 缓存里，仓库不引入全局状态库（`src/renderer/components/chat/messages/stream/useStableMessagePartsLayers.ts:1-39` 注释，原 `useStablePartsByMessageId.ts` 已迁移至此）。
- **多窗口同步**（分离窗口、悬浮窗 QuickAssistant 与主窗口之间的会话/草稿/生成状态同步）：本次未调查。

### 8.2 桌面端集成（源笔记 13.11）：托盘、通知、快捷键

- **托盘**：`TrayService.ts` 在 mac 上根据 `nativeTheme.shouldUseDarkColors` 切换亮/暗两套托盘图标（`:29`）；点击托盘图标的行为受偏好 `feature.quick_assistant.click_tray_to_show` 控制——开则唤起 QuickAssistant 悬浮窗，关则唤起主窗口（`:61-71`）。托盘本身**不显示未读消息数/流式状态角标**（未检索到 `setBadgeCount`/`flashFrame`/`setOverlayIcon` 调用）。
- **系统通知**：`NotificationService`（主进程，`src/main/services/NotificationService.ts`）用 Electron 原生 `Notification` API，点击通知会 `showMainWindow()` 并广播 `notification.clicked`（`:14-17`）；渲染层 `notificationService.send()`（`src/renderer/services/notification/NotificationService.ts:10-24`）先查三个偏好开关（`assistant`/`backup`/`knowledge`）再决定是否真的调 IPC 发送。
- **一个值得记录的空路径**：偏好 `app.notification.assistant.enabled` 和对应设置项（"助手回复完成通知"）确实存在，但**全仓库检索不到任何一处 `notificationService.send({..., source: 'assistant'})` 调用**——实际发通知的三处调用点（`BackupService.ts` 七处、`useAppUpdateHandler.ts` 一处）分别用 `source: 'backup'` 和 `source: 'update'`。即"助手完成回复时弹系统通知"这个开关目前接不到任何触发点，是个用户能看到、能勾选、但不会生效的空挂钩（`NotificationService.ts:17-20` 有另一条已知 TODO，但 `assistant` 这条连 TODO 都没提到，属于本次调查新发现）。
- **全局快捷键**：`ShortcutService.ts`（`f9dd175d5f`）从"按窗口聚焦分层注册"改为**本地/全局分轨**——`global` 标记的快捷键仍走 `globalShortcut`，其余本地快捷键不再注册到系统，而是挂在窗口 `webContents.before-input-event`（含 `did-attach-webview` 挂上的 guest webview 输入）上按命令解析拦截，应用失焦时本地快捷键自然不生效，无需按焦点切换注册集；快捷键冲突（被其他应用占用）仍记录冲突集合并经 IPC 广播给渲染层展示提示（`:281-303` 附近）。另新增标签页导航快捷键（`324f26f728`，如标签切换类命令）。**仍未找到独立的"快捷键帮助面板/速查表"浮层**——只有"设置 > 快捷键"这个静态配置页（`ShortcutSettings.tsx`）。

## 9. 键盘、焦点、响应式与关键路径可用性

### 9.1 无障碍：列表完整，消息操作栏与输入区有缺口（源笔记 13.6 的聊天关键路径部分）

**做得到位的地方**（有代码实证）：

- `ResourceList`（Topic 列表、Agent Session 列表共用的基础组件）实现标准的 **roving tabindex + `aria-activedescendant`** 模式：容器 `role="listbox"`（`ResourceListVirtual.tsx:551,777`），行 `role="option"` + `aria-selected`（`ResourceList.tsx:388-394`），键盘 `ArrowUp/ArrowDown/Home/End/Enter` 都有对应测试覆盖并断言 `aria-activedescendant` 正确移动（`__tests__/ResourceList.test.tsx:622-671`）——会话导航这条关键路径的键盘可用性是有保障的。
- 消息操作栏里**部分**按钮显式传了 `aria-label`：模型选择器（`MessageMenuBarToolbarRenderers.tsx:287`）、翻译（`:311`）、更多菜单弹出按钮（`:355,412`）。
- 折叠交互（用户消息折叠、Thinking 块展开/收起）用真实的 `aria-expanded`/`aria-controls` 且是可聚焦、可键盘触发的 `role="button"` + `onKeyDown`（`MainTextBlock.tsx:234-235`、`ThinkingBlock.tsx:93-105`）——但这两个是消息内容组件，渲染细节见消息渲染器笔记。

**实证的缺失**：

- **消息操作栏默认渲染路径缺 `aria-label`**：`renderDefaultToolbarAction` → `ActionButtonWithConfirm`（`MessageMenuBarToolbarRenderers.tsx:63-126`，覆盖复制、编辑、重新生成、删除、点赞等大多数没有专属渲染函数的 action）生成的 `<MessageActionButton>` **没有传 `aria-label`**（对照 `:80-91` 和 `:103-113` 两处按钮 JSX，都只有 `onClick`/`disabled`/`className`，没有任何 `aria-*` 属性）。这些按钮的可访问名称完全依赖视觉 Tooltip（`content={tooltip}`，鼠标悬停才出现，`:119-125`），而 Tooltip 内容不会自动同步成 `aria-label`——screen reader 用户对着这些图标按钮会读到"button"而没有任何描述文字。这不是全局性缺陷（Topic 列表的 pin/delete 按钮都传了 `aria-label`，见 `Topics.tsx:1737,1750`），而是消息操作栏这一条渲染路径的具体疏漏，且覆盖面恰恰是使用频率最高的复制/编辑/删除等动作。
- **Composer 输入区本体没有可访问名称**：富文本输入框基于 TipTap `EditorContent`，`contentEditable` 根节点没有 `aria-label`/`role="textbox"`——检索 `RichEditor.tsx`、`ComposerSurface.tsx` 全文，只有编辑器外围的工具按钮（暂停、编辑定位、取消编辑、展开高度等）有 `aria-label`（`ComposerSurface.tsx:2114-2207`），输入区本体依赖浏览器/TipTap 默认的可编辑语义。
- Toast 的 `role="alert"`/`role="status"` 与 `motion-reduce` 处理属于通用界面盘点，保留于源笔记 13.2/13.6。

### 9.2 键盘主链与响应式

- 输入区键盘操作（发送键配置、历史浏览、Tab 遍历变量、Escape）见 3.1；会话列表键盘（listbox）见 9.1；分支面板的键盘操作（树图能否用键盘导航）本次未核实。
- 响应式：无断点驱动的侧栏折叠（1.2）；移动端/小屏布局本次未调查。

## 10. 设计取舍与已确认边界

- **`ChatComposer.tsx` 单文件复杂度偏高**：`ChatComposerInner` 一个组件本体加上闭包状态就有 1400+ 行，混杂了草稿缓存、输入历史导航、编辑会话恢复（含"编辑消息时保存旧草稿、取消编辑时还原"的完整状态机）、mentioned models、reasoning effort 的乐观更新+回滚、queued followups 等好几套独立状态机在同一个函数体内用一堆 ref 协调（3.3）。功能齐全，但可读性/可维护性门槛显著高于单一职责组件，牵一发动全身的回归风险不低。
- **branch draft 的持久化改型**（8.1）：旧的"三态 ref 状态机"（无类型枚举兜底、多处手动清空 ref）被 `reserveBranch` 持久化行取代，原来的脆弱点随机制移除而消失；新机制的代价是"空 user 叶子"需要在渲染与删除/填充路径上做派生判断与守卫（数据侧见会话与消息管理笔记 4.3）。
- **适配器模式的代价与收益**：能力注入（6.2）让"Home 可写、Agent 只读"不需要 if/else 分支，代价是追踪某个按钮为何出现需要跨两个 adapter 文件；`messageListProviderBuilder.ts` 的"只塞存在的字段"（`pickMessageLeafState` 等纯函数）保证 `actions.xxx &&` 判断语义清晰（该文件细节见消息渲染器笔记）。
- **搜索的 DOM 局限**（2.3）：虚拟化 + DOM 搜索组合下的固有限制，数据侧影响见会话与消息管理笔记 5。
- **桌面集成缺口**（8.2）：通知空挂钩、托盘无角标、无快捷键速查浮层；Session 列表无拖拽排序（2.2）。
- **类目边界**：本笔记只记录用户工作流与界面状态；树模型与指针语义在会话与消息管理笔记 1/4，流式执行与最终化在对话请求与上下文笔记 5/6，消息壳与 Markdown 渲染在消息渲染器笔记。**源笔记（`../Chat/Cherry-Studio-Chat调查笔记.md`）第 13 节的通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、右键菜单双模式、桌面托盘等基础设施）保留于源文件，待可选界面专题承接**，本笔记只记录与聊天主链的交点（2.1 运行指示、5 的 Toast/骨架交点、6.3 的 PromptPopup 交点）。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为、系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 停止/暂停按钮状态与真实任务状态的对应关系、切走 Topic 后任务收口（见对话请求与上下文笔记 7、8）。
- 草稿粒度已核实为"按会话缓存、跨导航保留"（3.3）；切换 Topic 保留的滚动位置、分支面板键盘操作仍未核实。
- 移动端布局、QuickAssistant 悬浮窗与主窗口的状态同步未调查。

## 12. 关键源码索引

- `src/renderer/pages/home/Chat.tsx`、`ChatContent.tsx`（命令注册、搜索触发、重命名、发送锚点 ref）
- `src/renderer/pages/home/components/TopicBranchPanel.tsx`、`src/renderer/components/chat/flow/{TopicMessageFlowCanvas,TopicMessageFlowNode,topicMessageFlowGraph,topicMessageFlowLayout}.ts(x)`
- `src/renderer/components/composer/variants/ChatComposer.tsx`、`ComposerSurface.tsx`、`chat/ChatConversationControls.tsx`、`chat/useChatMentionedModels.ts`
- `src/renderer/components/ContentSearch.tsx`（搜索工作流）
- `src/renderer/components/chat/actions/messageMenuBarActions.tsx`、`MessageMenuBarToolbarRenderers.tsx`
- `src/renderer/pages/home/messages/homeMessageListAdapter.tsx`、`src/renderer/pages/agents/messages/agentMessageListAdapter.tsx`
- `src/renderer/components/chat/messages/MessageListProvider.tsx`、`messageListProviderBuilder.ts`
- `src/renderer/components/chat/ResourceList.tsx`、`ResourceListVirtual.tsx`（listbox 键盘语义）
- `src/renderer/hooks/SiblingsContext.ts`（`< i/N >` 兄弟导航）
- `src/renderer/pages/home/Topics.tsx`（拖拽排序、运行指示、Toast 交点）
- `src/main/services/{TrayService,NotificationService,ShortcutService}.ts`（桌面集成）
