# AIO-Hub Chat UI 调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：从 [`../Chat/AIO-Hub-Chat调查笔记.md`](../Chat/AIO-Hub-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，并增量核对消息状态徽标、审批条倒计时、资料引用 chips、批量管理搜索与会话恢复横幅等界面变化
>
> 调查范围：工作台结构、会话导航与搜索工作流、Composer 与草稿、发送前配置、生成反馈、消息操作与分支导航、树图视图、多会话与分离窗口、键盘关键路径、桌面集成交点；会话数据语义、请求执行与内容渲染分别进入会话与消息管理、对话请求与上下文、消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 聊天工作台是 `LlmChat.vue` 装配的三栏布局（Agent 侧栏 / ChatArea / 会话侧栏），标题栏与输入框都可分离成悬浮窗口（`useDetachable` + `useWindowSyncBus` 同步），"分离"是 UI 视图拆分，不会创建新的 Session 或消息副本。
- 消息区有线性（linear）与树图（force-graph，Vue Flow）两种视图，共用同一份节点数据，树图操作不改变 `activeLeafId`。
- 会话侧栏用 TanStack Virtual 只挂载可见项（固定预估行高 71px、overscan 10）；消息列表**不虚拟化**，全量 DOM + 浏览器 `content-visibility` 裁剪（当前机制在消息渲染器笔记 8，撤回虚拟滚动的历史见第 10 节）。
- 搜索分两套：侧栏跨会话搜索（Rust 后端）命中只能到会话级；会话内搜索（Ctrl+F）只扫当前活动路径消息。
- 键盘关键路径：发送可用快捷键完成；会话切换、树图操作基本依赖鼠标；线性视图的分支切换按钮是标准 `<button>` 可 Tab 聚焦。
- 生成完成没有系统通知、托盘没有聊天状态菜单项；桌面集成与聊天状态联动最少。

## 工作台边界与用户主链

```text
进入 LlmChat 工作台（三栏 + 可选分离窗口）
  -> 侧栏选择/新建会话（虚拟化列表、筛选、收藏夹、批量清理）
  -> MessageInput 组织输入（编辑器、附件、快捷操作、临时模型）
  -> 发送 -> 占位气泡出现 -> 发送按钮变中止；生成中再发消息进入排队
  -> 工具调用暂停时 ToolCallingApprovalBar 等待审批
  -> 消息操作：分支、重试/续写、翻译、导出、截图、上下文分析（MessageMenubar）
  -> 线性/树图视图切换；会话内搜索定位消息（ChatSearchPanel -> scrollToMessageId）
  -> 切换会话：草稿、悬浮窗、流缓冲由 UI 状态层独立维护（现场恢复）
```

边界：会话数据语义在 [`../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md`](../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md)；提交后的执行链（上下文拼装、流式节流、排队、审批暂停）在 [`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md)；消息壳装配、富文本与列表绘制的实现在 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)。通用界面盘点（弹窗库、Toast、主题、动画、响应式断点、灯箱、头像、设置面板等）保留于 [`../Chat/AIO-Hub-Chat调查笔记.md`](../Chat/AIO-Hub-Chat调查笔记.md) 第 12 节，本笔记只记录与聊天主链的交点。

## 1. 页面结构、导航与多窗口

### 1.1 三栏工作台

`LlmChat.vue` 装配左侧 `LeftSidebar`（Agent 列表/参数面板）、中央 `ChatArea` 和右侧 `SessionsSidebar`；组件关系和弹窗层在仓库文档 `docs/architecture/llm-chat-ui-structure.md` 已明确列出。`ChatArea.vue` 同时挂载消息区、输入区、搜索面板、上下文分析器以及工具审批条。

- **会话索引恢复横幅**：`store.sessionRecovery.status !== "ready"` 时工作台顶部渲染 `session-recovery-banner`（`LlmChat.vue:454-511`），`recovering` 显示"正在后台恢复会话索引"与扫描/失败计数，`corrupt` 显示"会话索引需要恢复"；横幅提供取消恢复、打开损坏会话目录（`revealItemInDir`）、导出损坏诊断 JSON、删除已隔离文件（`ElMessageBox` 二次确认）等入口（`LlmChat.vue:318-376`）。
- **分离窗口不再自行加载会话**：`/detached-component/` 分离窗口初始化不再调用 `store.loadSessions()`，会话状态由 `useLlmChatStateConsumer` 经 WindowSyncBus 提供，且分离窗口不得触发任何 llm-chat 持久化路径（`LlmChat.vue:180-195`）。

### 1.2 可分离窗口

标题栏拖拽调用 `useDetachable`，输入框也能独立成悬浮窗口；`detachedComponents` 变化后，主 ChatArea 会隐藏重复输入框，并通过 `useWindowSyncBus` 同步主窗口与分离窗口的生成状态。这里的"分离"是 UI 视图拆分，不会创建新的 Session 或消息副本（同步机制与断连边界见 8.2）。

### 1.3 线性与树图两种消息视图

`MessageList.vue` 默认只渲染 `activeLeafId` 回溯得到的活动路径；消息卡片由 `ChatMessage`/`MessageHeader`/`MessageContent`/`MessageMenubar`/`BranchSelector` 组合（组件装配与内容渲染在消息渲染器笔记 1.2/1.3）。`ViewModeSwitcher.vue` 通过 `useLlmChatUiState().viewMode` 在 `linear`（普通气泡/列表）和 `force-graph`（Vue Flow 对话树）之间切换。树图使用独立的 `GraphNode`、连线、节点菜单和详情弹窗，属于同一 Session 的另一种投影，**不改变 `activeLeafId`**。

### 1.4 树图视图的交互与状态

依据 `FlowTreeGraph.vue`、`useGraphD3Simulation.ts`、`useGraphSubtreeDrag.ts`、`useGraphConnectionPreview.ts`、`useGraphNodeActions.ts`、`GraphNodeMenubar.vue`（数据层的树不变量在会话管理 4.5）：

- 视图缩放范围 0.2–4，支持 fit view、定位当前激活节点、背景网格/小地图/控制器/HUD 开关、工具栏折叠、撤销/重做、操作历史、视图设置和开发者 debug overlay。布局有三种：动态树状 `tree`、物理引力 `physics`、静态树状 `static`；循环布局和重置布局均是可见按钮，操作历史仅运行时有效。
- 节点双击会将其设为活动节点；节点上的"详情"按钮才会打开详情弹层。右键可设为当前分支、启用/禁用、剪掉分支；节点菜单可续写、上下文分析、导出、重算 Token、重新解析工具、复制、创建分支、重生成、指定模型重生成、截图、删除。
- 拖拽节点默认移动单点，按 `graphViewShortcuts` 配置的 Shift/Alt/Ctrl 可拖整棵子树；从节点连线到另一节点可移动节点，使用 `graftSubtree` 修饰键则嫁接整棵子树，系统拒绝自连、根节点、后代循环、预设节点和同父节点。
- 压缩节点标题可展开/收起，收起只改变可见拓扑投影，不删除消息。节点以 active-leaf、disabled、compression、connection-valid/invalid 等状态区分；debug 层额外显示 id、深度、速度、尺寸和固定坐标。static 模式不进入拖拽物理布局，physics 模式松手后可能回弹。

## 2. 会话列表、搜索与现场恢复

### 2.1 会话侧栏：虚拟化与筛选

`SessionsSidebar.vue` 接入 `@tanstack/vue-virtual`（`package.json` 依赖 `@tanstack/vue-virtual: ^3.13.12`，第139-149行）：`useVirtualizer({ count: () => displaySessions.value.length, getScrollElement: () => parentRef.value, estimateSize: () => 71, overscan: 10 })`，固定预估行高 71px、overscan 10 项，`virtualItems`/`totalSize` 用 computed 包一层，模板里用 `translateY` 定位每一行。搜索支持精确/AND/OR 三种匹配模式（数据扫描语义在会话管理 5），并可按 Agent、时间、收藏和生成状态筛选；菜单动作包括新建、重命名、AI 自动命名、收藏夹移动、导出、打开数据目录和批量清理（空会话批量清理的数据语义在会话管理 3.2）。列表项的生成状态来自节点集合而不是 Session 布尔值，因此多个会话可以同时显示生成中。批量管理弹窗（`BatchManagerDialog.vue`）提供**会话内容搜索与高亮**：复用 `useLlmSearch`（`scope: "session"`、300ms 防抖、加载/失败状态），命中片段用 `<mark class="search-highlight">` 高亮（输入 ≥2 字符进入搜索模式）。

### 2.2 Agent 侧栏虚拟化

`AgentsSidebar.vue`（第893-946行）同款接入（`agents-list` 容器），但用 `virtualizer.measureElement` 动态测量真实高度——因为智能体卡片高度可能因描述文字长度不同而不固定，不是纯靠 `estimateSize`。

### 2.3 搜索入口与定位工作流

- **侧栏跨会话搜索**：前端 `useLlmSearch` 封装 Tauri 命令 `search_llm_data_stream`（300ms 防抖、精确/全部/任一匹配模式；后端全量扫描数据侧在会话管理 5.1）；命中后只能定位到会话本身，**无法直接跳到会话内的具体消息**。
- **会话内消息搜索**：Ctrl+F 打开 `ChatSearchPanel.vue`，纯内存线性扫描当前活动路径消息（`content + reasoningContent`，最多 50 条，数据语义在会话管理 5.2）；选中结果后调用 `messageListRef.value?.scrollToMessageId(messageId)`（`ChatArea.vue:212-214`），用 `querySelector('[data-message-id="..."]')` 找 DOM 节点滚动过去。`content-visibility: auto` 只跳过屏外内容的渲染工作，不会从 DOM 中删除节点，因此不会妨碍该查询；真正的限制是搜索范围只有当前活动路径，不在当前分支路径上的节点既不会被搜索，也没有对应的消息 DOM。

### 2.4 切换时的现场恢复

会话切换只改变当前活动路径；输入草稿、悬浮窗（detachedComponents）和消息流缓冲仍由 UI 状态层独立维护（8.1）。会话内搜索面板与跨会话搜索结果不会跨会话保留（源调查未记录恢复行为，未核实）。

## 3. Composer、草稿、附件与快捷输入

### 3.1 输入编辑器与发送约定

`MessageInput.vue` 支持 CodeMirror/textarea 两种编辑器、Enter/Shift+Enter（或 Ctrl/Cmd+Enter）发送约定、输入区高度拖拽/双击复位、附件预览、文件拖入和剪贴板粘贴。附件先进入 `useChatInputManager` 的临时列表，处理完成后才随用户消息提交；转写占位符由 `useTranscriptionManager` 按当前模型能力决定是否插入。生成中会禁用流式模式切换，发送按钮转为中止。工具栏可切换流式输出、宏、附件、迷你会话、临时模型、更多工具、工具调用设置、工具栏设置、输入框展开/收起（`MessageInput.vue`）。

Composer 提供**显式 Knowledge 资料引用**入口——工具栏插入 `KnowledgeReferenceControl.vue`（选择器），输入区上方渲染 `KnowledgeReferenceChips.vue`（每个引用库一个 chip，含名称/ID/可用性 tooltip、不可用红色边框、可单独移除，`aria-label="已引用的 Knowledge 资料库"`）；随消息提交的 `knowledgeReference` 会先在 `useChatHandler.sendMessage` 里执行一次资料检索/研究工具事件（生成 tool 节点）再进入正常生成链（执行侧见对话请求与上下文笔记；数据结构 `ChatMessageNode.knowledgeReference`）。

### 3.2 快捷操作（宏）

输入框上方的快捷操作并非固定按钮：`MessageInputToolbar.vue:137-153` 合并聊天全局、当前 Agent、有效用户档案绑定的 `quickActionSetIds`，去重后加载多个操作组。每个操作以 `{{input}}` 接收选区或整个输入框，通过完整宏引擎展开，还可对每一行加前后缀或执行正则替换；结果覆盖选区/输入框，`autoSend=true` 时延迟 50ms 自动发送。操作组支持创建、复制、导入、批量导出和绑定。`QuickAction.hotkey` 类型字段目前没有实际消费方（见第 10 节）。

### 3.3 草稿状态

临时模型和续写模型分别保存在当前会话草稿状态（随会话切换独立维护）。当前 Agent 点击打开 `QuickAgentSwitch`；迷你会话切换在开启 `autoSwitchAgentOnSessionChange` 时会同步切换 display Agent。

### 3.4 附件交互与批量动作

附件卡片（`AttachmentCard.vue`）提供"加载失败"与"导入失败"两种失败态及导入中间态图标（失败态细节属通用盘点，留在源文件 12.3）；输入区侧提供单项重试/取消，以及"一键转写未转写、智能转写、强制重新转写、停止全部"等批量动作（转写执行语义在对话请求与上下文 9.2）。附件两阶段导入的状态机在会话管理 8.3；导入完成后图片引用改用 `asset://` 协议（渲染在渲染器笔记 1.3）。

## 4. Agent、模型、工具与发送前配置

### 4.1 Agent 选择与切换

`useLlmChatUiState().selectAgent(agentId, options?)`（`composables/ui/useLlmChatUiState.ts:198-230`）是切换"当前选中 Agent"的入口——不传 `options` 时（用户在侧栏主动点选 Agent），如果当前有活跃会话，会同步调用 `chatStore.updateSession(chatStore.currentSessionId, {displayAgentId: agentId})`，即"选中 Agent"和"把当前会话的展示 Agent 改成它"是同一个动作。一旦会话已经产生过真实对话，切换 Agent 不会重建开场白，只是单纯改变"接下来发消息用哪个 Agent"；历史消息仍显示生成时记录的 Agent 快照（数据语义在会话管理 8.1）。

### 4.2 模型选择

标题栏模型在 `showModelSelector` 开启时可直接换模型；临时模型选择保存在当前会话草稿状态（3.3）。"切换模型重新生成"/"选择模型续写"走消息操作栏（6.1），执行链在对话请求与上下文 7。

### 4.3 压缩配置与手动压缩入口

压缩配置面板位于 Agent 参数编辑器的 `ContextCompressionConfigPanel.vue`（配置语义在对话请求与上下文附录 A.1）。输入框"更多"菜单的"压缩上下文"调用 `messageInputStore.handleCompressContext()` → `manualCompress()`；菜单会在当前 Agent 没有启用压缩时禁用。手动调用跳过自动开关与阈值判断，但仍受"最近 N 条保护区"约束（候选不足时返回"没有可压缩的消息"）。

### 4.4 管道配置入口

`PipelineConfig.vue` 提供上下文管道处理器的开关、排序和恢复默认入口（启用状态与顺序持久化在 `llm-chat/pipeline-settings.json`；处理器顺序语义在对话请求与上下文 2）。

## 5. 发送、排队、流式反馈与停止

### 5.1 发送/停止与占位气泡

生成中发送按钮转为中止（`MessageInputToolbar.vue:508` 停止按钮 title="停止生成"）。三种"再生成"操作（重新生成、切换模型重试、续写）创建的新节点在完成前先 `generatingNodes.add` → `updateActiveLeaf` → 才真正执行请求，保证 UI 能立刻看到"正在生成"的占位气泡（执行顺序在对话请求与上下文 1；占位气泡的渲染在渲染器笔记）。停止按钮触发的 abort 执行层语义在对话请求与上下文 7。

### 5.2 排队反馈

会话生成中再发消息时，消息节点会被创建并持久化但不触发请求（`metadata.isQueued = true`、`status: "queued"`），当前生成结束后按 `queueReplyMode` 合并或链式触发（执行语义在对话请求与上下文 8）。排队/等待状态的界面呈现：`utils/messageStatus.ts` 把节点状态映射为展示状态（queued→"排队"、waiting→"等待"、generating→"生成中"、error→"错误"、空响应诊断→"异常回复"），`MessageHeader.vue` 在 `settings.uiPreferences.showMessageStatus`（默认 true）开启时于消息头渲染对应徽标（图标 + 文案 + tooltip 详情，生成中带旋转动画；截图模式隐藏）。旧数据 `pending` 状态兼容识别为 queued。

### 5.3 工具审批条

工具调用暂停时，`ToolCallingApprovalBar.vue` 在输入区上方提供允许/拒绝/继续等动作。"全部允许/全部拒绝"按钮特意不按 `sessionId` 精确匹配，而是基于 UI 当前渲染出来的可见请求 ID 列表——因为 VCP 广播来的审批请求 `sessionId` 是 `vcp-${maid}` 格式，跟本地 `llm-chat` 会话 ID 体系不是一套（`ToolCallingApprovalBar.vue:126-151` 注释里专门解释了这个原因；审批状态语义在对话请求与上下文 9.5）。审批条带倒计时提示（`formatApprovalWait`，每秒刷新）——`expiresAt === null` 显示"等待人工审批 · 不会自动超时"，否则显示"剩余 N 秒 · 超时将自动拒绝"；超时自动拒绝来自 `toolCallingStore` 的可配置审批超时（`uiPreferences.toolApprovalTimeoutEnabled`/`Seconds`，默认关闭）。

## 6. 消息操作、分支与版本导航

### 6.1 消息操作栏

`MessageMenubar.vue` 实际提供：上一/下一分支与 `n/total` 选择器、变量快照、续写、选择模型续写、上下文分析、导出分支、消息截图、重算 Token、重新解析工具、数据编辑（高级）、翻译语言/切换或同时显示/显示隐藏/重试、复制、停止生成、编辑、创建分支、重新生成、指定模型重新生成、启用/禁用节点和删除确认。翻译按钮支持按住 Shift/Ctrl/Alt 直接使用默认目标语言（`MessageMenubar.vue:409-420`；翻译执行在对话请求与上下文 9.7，结果字段在会话管理 1.3）。硬删除由 `ElMessageBox` 二次确认（`MessageMenubar.vue:167-186`，通过 `confirmButtonClass: "el-button--danger"` 标记危险操作），删除后代分支的语义与会话管理 4.4 的树操作一致。操作栏的组件装配与渲染属消息渲染器类目。

### 6.2 分支导航 UI

`BranchSelector`（消息卡片组合的一部分）与操作栏的上一/下一分支按钮承担兄弟版本切换，`n/total` 显示当前位置；导航算法（循环切换、`lastSelectedChildId` 记忆、叶子定位）在会话管理 4.1。线性视图下的这些按钮是标准 `<button>`，可 Tab 聚焦（9.1）。

### 6.3 上下文分析器入口

消息菜单"上下文分析"打开 `ContextAnalyzerDialog.vue`，提供五个视图：结构化视图、原始请求、内容分析、宏调试、变量状态；最终 Token 统计对管道产出的每条消息重新计算。它复用真实请求的整条管道且可能触发缺失的转写任务（执行侧细节与副作用在对话请求与上下文 9.8）。

### 6.4 导出与截图工作流

- 导出：`ExportBranchDialog.vue`（BaseDialog 封装，宽 1000px、高 80vh）提供分支导出（Markdown/结构化 JSON/Raw JSON、消息范围与内容选项、可选"使用上下文管道处理"）与整会话导出（树状 Markdown / 完整节点树 JSON/Raw，保留隐藏分支）；格式与范围的数据语义在会话管理 7.1。
- 消息截图："创建消息截图"使用独立的 `ScreenshotRenderer` 重新渲染所选消息范围，再由 `screenshotCapture.ts` 分段捕获并拼成长画布（不是直接截当前窗口可见区域）。用户可选卡片/气泡布局、480-1280px 渲染宽度、输出倍数、主题/纯色/壁纸背景、消息间距与留白、水印、顶部/底部品牌条、工具调用展开策略以及是否显示时间、Token 和字数；交互按钮和编辑入口在 `screenshotMode` 下被隐藏；结果统一输出 PNG，可复制到剪贴板或通过 Tauri 保存对话框写入文件。

### 6.5 可见性设置与语义状态

节点卡片的时间戳、Token 数、字符数、头像、模型信息、性能指标、自动滚动和气泡布局由全局 `uiPreferences` 控制；关闭这些偏好只隐藏元信息，不改变节点内容或请求上下文。`isEnabled=false` 是语义状态，会影响节点是否参与上下文；压缩收起、过滤 active path、隐藏 HUD/小地图则是呈现状态，不能混为"节点被删除"。"查看详情"是 teleported 到 body 的独立弹层，节点右键菜单和详情弹层的位置跟随节点屏幕坐标；因此切换缩放/布局后，弹层需要重新定位，不能把它当成节点卡片的静态子元素。

## 7. 多会话、多模型与后台生成

- 多会话可同时生成：列表项的生成状态来自节点集合（`generatingNodes`）而非 Session 布尔值（2.1；数据语义在会话管理 6）。
- 同会话生成中再发消息进入排队（5.2）；多模型并行、群聊、子 Agent 等场景的界面区分本次调查未覆盖。
- 后台会话生成完成没有专门的返回入口或系统通知（8.3）。

## 8. Chat UI 状态所有权与同步

### 8.1 UI 状态层

`useLlmChatUiState.ts`（`composables/ui/`）持有 viewMode、当前选中 Agent 等 UI 状态（`selectAgent` 见 4.1）。输入草稿、悬浮窗（detachedComponents）和消息流缓冲由 UI 状态层独立维护，与会话对象本身分离——会话切换只改变活动路径，不重置这些局部状态（2.4）。

### 8.2 跨窗口同步与断连边界

主窗口与分离窗口经 `useWindowSyncBus` 同步生成状态（`chat:streaming-delta` 广播，RAF 节流；执行侧在对话请求与上下文 5）。已确认边界：若窗口关闭/断连，流缓冲仍在主进程内存中，用户看到的最后一段内容能否在重连后完整回放取决于订阅时机（渲染侧的重放机制在消息渲染器笔记 2.1）。

### 8.3 桌面集成交点

- 系统托盘（`src-tauri/src/tray.rs:39-59`）菜单包含"显示主窗口、隐藏主窗口、重启前端、清除窗口配置、退出"，**没有聊天生成状态相关的动态菜单项**（托盘完整盘点留在源文件 12.12）。
- 项目中没有找到 `tauri-plugin-notification`、`sendNotification`、`notification::Notification`、`request_user_attention` 或 `UserAttentionType`——没有 Windows Toast、标题栏闪烁或任务栏提醒的实现证据。
- 生成完成只驱动 `generatingNodes`、消息卡片状态和 `useWindowSyncBus` 的跨窗口同步，没有触发系统通知、托盘图标变化或标题栏提醒；应用处于后台时，不会主动提示某个会话已生成完成。

## 9. 键盘、焦点、响应式与关键路径可用性

（依据源调查 12.7/12.8 的静态代码结论；视觉效果与焦点顺序需运行验证，完整 ARIA 盘点保留在源文件 12.7）

### 9.1 关键路径键盘

- **发送消息**：可以。`ChatCodeMirrorEditor.vue`/`ChatTextareaEditor.vue` 都支持 `Ctrl/Cmd+Enter` 或 `Enter` 发送（可配置），不依赖鼠标点击发送按钮。
- **切换会话**：不可以。会话列表是可点击的 `div`（`SessionItem.vue:87`，整个 `div` 绑定 `@click`），没有 `tabindex`、`role="option"` 或 `role="listbox"`，也没有 ArrowUp/ArrowDown 或 Ctrl+Tab 的会话切换绑定；`div` 默认不可聚焦，列表项不在 Tab 焦点序列里，纯键盘用户无法直接切换会话。
- **查看分支**：部分可行。操作栏上一分支/下一分支按钮是标准 `<button>` 元素（可被 Tab 聚焦、可用 Enter/Space 激活）；树图视图（`FlowTreeGraph.vue:22` 容器有 `tabindex="0"`，整个画布本身可以被聚焦）内部的节点选择、右键菜单操作、连线嫁接等均是鼠标驱动的交互（拖拽、右键、双击），**没有找到等效的键盘操作路径**，画布本身可聚焦但聚焦后没有发现方向键选中/切换节点的绑定。
- 结论：发送消息具备键盘路径，会话切换和树图操作基本依赖鼠标；线性视图下的分支切换按钮可通过 Tab 聚焦。该结论来自静态代码搜索，未经屏幕阅读器实测，不能作为正式的 WCAG 合规结论。

### 9.2 可访问名称现状

`llm-chat` 目录下唯一找到的主动语义化 ARIA 标注是 `BatchManagerDialog.vue:75-110`（`role="table"` + `aria-label="批量管理会话列表"`）；`ChatTextareaEditor.vue:324` 有一处技术性 `aria-hidden`。消息操作栏、发送/中止按钮、节点图菜单普遍使用"图标按钮 + `title` 属性"或 `el-tooltip`（发送按钮只有 `title="发送 (Ctrl/Cmd + Enter)"`、停止按钮 `title="停止生成"`，`MessageInputToolbar.vue:530/508`）。`title` 对屏幕阅读器的支持取决于浏览器和辅助技术组合，不能替代明确的可访问名称。

### 9.3 响应式

三栏布局没有 `@media` 查询或容器宽度自动折叠：侧栏显示由用户手动控制并持久化（`isLeftSidebarCollapsed`/`isRightSidebarCollapsed`），窗口变窄时不会自动收起侧栏，三栏会一起被压缩。侧栏宽度可通过拖拽在 200-600px 范围内调整（`useResizable`，通用实现盘点在源文件 12.4），但这是手动操作，不属于响应式自适应。弹窗内部有断点（如 `FavoriteManagerDialog.vue:669-674` 在 720px 切单列、`ChatSettingsDialog.vue:714-737` 两级高度断点）——弹窗细节属通用盘点，留在源文件 12.8。

### 9.4 运行验证要求

视觉反馈、焦点顺序、键盘可用性、响应式行为和系统通知均需运行验证；本笔记结论主要来自静态代码（与源调查一致）。

## 10. 设计取舍与已确认边界

- **消息列表不再虚拟化**（当前方案的渲染机制在消息渲染器笔记 8，撤回历史留在这里）：Git 历史表明消息列表并非一直采用当前方案——`30b0ce71b486f1274274a763539f87d108573c14`（2025-11-02）首次在 `MessageList.vue` 接入 `@tanstack/vue-virtual`（初版 `estimateSize: 200`、`overscan: 5`、只挂载可见消息、绝对定位加 `translateY(virtualItem.start)`），此后持续处理动态高度与滚动定位问题（`6efa00864f534624b5cbd7cea140258e746c17eb`、`515c215de9d6f66923b1ea969bed8e8e16da011f`、`bff4d7de896ff444bc857ca63e0369edbb766a5c`、`d9f56e9a6795c6a40ffffa772553c21f7f72d73b`、`9cce774fe97cae2daa7fb1774ffcce91c55b2b72`、`f5e66344b21910c2d7d0631951488564f8aeb8fc` 等）；`5c68447275237769d9be723849a93b1818d0b45f`（2026-04-29）撤回改用原生 DOM，提交说明将原因归结为聊天消息高度动态、倒序加载闪烁、估算不准和初始化复杂；在该项目"几百条消息"的目标规模下，作者实测会话切换由 3–5 秒降至 500ms 内（**该性能数字来自提交说明，笔记未独立复测**）。撤回后滚动和导航都改为基于真实 DOM（`scrollTop = scrollHeight` 触底、`querySelector(All)` + `getBoundingClientRect()` + `data-message-id` 定位），后续 `1d971ff5476578e713bd7b68a5c86404dce43e99`、`25ef4a7f5cd3edc9683e5ecbefd95470655b603e` 又处理了生产构建中 `content-visibility` 被优化器移除的问题。注意区分：旧方案是真正的列表虚拟化（屏外消息组件不挂载）；当前方案是"完整 DOM + 浏览器渲染裁剪"，所有活动路径消息仍在 DOM 中。
- **线性视图与树图共用同一份节点数据**；树图的交互路径已做静态代码核实，大规模节点树的布局性能未做运行时压测（仓库 `docs/Plan/tree-graph-performance-investigation.md` 记录的是性能计划，不能据此得出性能结论）。
- **分离窗口断连的回放依赖订阅时机**（8.2）。
- **`QuickAction.hotkey` 未落地**：类型定义声明了 `hotkey?: string`，但 `src/tools/llm-chat` 中没有任何读取或注册该字段的代码（搜索不到 `.hotkey` 的读取）——快捷操作按钮、模板展开和自动发送可用，配置快捷键本身没有执行链。
- **语义状态与呈现状态必须区分**（6.5）。
- **通用界面盘点保留**：弹窗库（`BaseDialog`/`useDialogZIndex`）、Toast 与错误分级（`customMessage`/`errorHandler`）、加载态与空状态、拖放双通道（`useFileDrop`）、右键菜单盘点、主题、动画、图片查看器、头像管理、设置面板及首次启动 onboarding 缺失等，保留在源文件第 12 节，待可选界面专题承接；本笔记只记录与聊天主链的交点。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为、系统通知需要运行验证（静态代码只能确认入口、状态与事件绑定）。
- 树图大规模节点布局性能未压测。
- 分离窗口断连后流缓冲重放的实际观感未验证（8.2）。
- 首次启动 onboarding 缺失、会话列表键盘切换缺失、树图无键盘路径等结论来自全项目静态搜索，未经运行时可用性测试（详细清单在源文件 12.7/12.11；应用已引入 GuidedFlow 引导流程系统与升级引导，原"onboarding 缺失"结论已过时，详见通用界面盘点笔记 §12.11）。

## 12. 关键源码索引

- `src/tools/llm-chat/LlmChat.vue`（顶层装配、窗口类型初始化分支、骨架屏切换）
- `src/tools/llm-chat/components/ChatArea.vue`（视图切换、搜索面板挂载、悬浮窗，212-214行滚动定位）
- `src/tools/llm-chat/components/message/MessageMenubar.vue`（消息操作入口，167-186行删除确认，409-420行翻译快捷键）
- `src/tools/llm-chat/components/message/ViewModeSwitcher.vue`、`message/MessageList.vue`（入口层面，渲染机制在渲染器笔记）
- `src/tools/llm-chat/components/message-input/MessageInput.vue`、`MessageInputToolbar.vue`、`ToolCallingApprovalBar.vue`
- `src/tools/llm-chat/components/message-input/KnowledgeReferenceControl.vue`、`KnowledgeReferenceChips.vue`（显式资料引用）
- `src/tools/llm-chat/utils/messageStatus.ts`、`components/message/MessageHeader.vue`（生命周期状态徽标）
- `src/tools/llm-chat/components/sidebar/BatchManagerDialog.vue`（会话内容搜索与高亮）
- `src/tools/llm-chat/components/sidebar/SessionsSidebar.vue`（139-149行虚拟化、491-499行空状态）、`AgentsSidebar.vue`（893-946行）
- `src/tools/llm-chat/components/search/ChatSearchPanel.vue`（52-121行线性扫描）
- `src/tools/llm-chat/components/conversation-tree-graph/`（`FlowTreeGraph.vue`、`useGraphD3Simulation.ts`、`useGraphSubtreeDrag.ts`、`useGraphConnectionPreview.ts`、`useGraphNodeActions.ts`、`GraphNodeMenubar.vue`）
- `src/tools/llm-chat/composables/ui/useLlmChatUiState.ts`（109-243行）
- `src/tools/llm-chat/components/context-analyzer/ContextAnalyzerDialog.vue`、`components/export/ExportBranchDialog.vue`
- `src/tools/llm-chat/composables/features/useExportManager.ts`、`useScreenshotGenerator.ts`
- `src-tauri/src/tray.rs`（托盘）


