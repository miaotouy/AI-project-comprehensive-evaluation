# AIO-Hub Chat UI 调查笔记

> 调查对象：`E:\works\GitStudyNotes\aio-hub`
>
> 调查更新日期：2026-08-18
>
> 代码快照：`2ddbb19288c08bda1c080fc9a5f2e71149feaebc`（分支：`dev`）
>
> 调查方式：直接阅读源码（Vue 组件、composable、store、Rust 后端命令）
>
> 调查范围：工作台结构、会话导航与搜索工作流、Composer 与草稿、发送前配置、生成反馈、消息操作与分支导航、树图视图、多会话与分离窗口、键盘关键路径、桌面集成交点；会话数据语义、请求执行与内容渲染分别进入会话与消息管理、对话请求与上下文、消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 聊天工作台是 `LlmChat.vue` 装配的三栏布局（Agent 侧栏 / ChatArea / 会话侧栏），标题栏与输入框都可分离成悬浮窗口（`useDetachable` + `useWindowSyncBus` 同步），"分离"是 UI 视图拆分，不会创建新的 Session 或消息副本。
- 消息区有线性（linear）与树图（force-graph，Vue Flow）两种视图，共用同一份节点数据；树图双击节点只切活动分支，不改变会话存储结构。
- 会话侧栏用 TanStack Virtual 只挂载可见项（固定预估行高 71px、overscan 10）；消息列表**不虚拟化**，全量 DOM + 浏览器 `content-visibility` 裁剪（机制细节在消息渲染器笔记 8）。
- 搜索分两套：侧栏跨会话搜索（Rust 后端）命中只能到会话级；会话内搜索（Ctrl+F）只扫当前活动路径消息。
- 键盘关键路径：发送可用快捷键完成；会话切换、树图操作基本依赖鼠标；线性视图的分支切换按钮是标准 `<button>` 可 Tab 聚焦。
- 生成完成没有系统通知、托盘没有聊天状态菜单项；桌面集成与聊天状态联动最少。

## 工作台边界与用户主链

```text
进入 LlmChat 工作台（三栏 + 可选分离窗口）
  -> 侧栏选择/新建会话（虚拟化列表、筛选、收藏夹、批量清理）
  -> MessageInput 组织输入（编辑器、附件、快捷操作、临时模型、Knowledge 引用）
  -> 发送 -> 占位气泡出现 -> 发送按钮变中止；生成中再发消息进入排队
  -> 工具调用暂停时 ToolCallingApprovalBar 等待审批（可配置超时倒计时）
  -> 消息操作：分支、重试/续写、翻译、导出、截图、上下文分析（MessageMenubar）
  -> 线性/树图视图切换；会话内搜索定位消息（ChatSearchPanel -> scrollToMessageId）
  -> 切换会话：草稿、悬浮窗、流缓冲由 UI 状态层独立维护（现场恢复）
```

边界：会话数据语义在 [`../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md`](../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md)；提交后的执行链（上下文拼装、流式节流、排队、审批暂停）在 [`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md)；消息壳装配、富文本与列表绘制的实现在 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)。本笔记只记录与聊天主链的交点：弹窗/Toast/主题/动画等通用组件只在其影响聊天可用性时提及，不做全仓库盘点。

## 1. 页面结构、导航与多窗口

### 1.1 三栏工作台

`LlmChat.vue` 装配左侧 Agent 列表/参数面板、中央聊天区和右侧会话侧栏；组件关系和弹窗层在仓库文档 `docs/architecture/llm-chat-ui-structure.md` 已明确列出。`ChatArea.vue` 同时挂载消息区、输入区、搜索面板、上下文分析器以及工具审批条。

- **会话索引恢复横幅**：会话索引状态不是 ready 时，工作台顶部渲染恢复横幅（`LlmChat.vue:457-507`）：恢复中显示"正在后台恢复会话索引"与扫描/失败计数，损坏时显示"会话索引需要恢复"。横幅提供取消恢复、打开损坏会话目录、导出损坏诊断 JSON、删除已隔离文件（`ElMessageBox` 二次确认）等入口，处理器集中在 `LlmChat.vue:321-372`。
- **分离窗口不再自行加载会话**：分离窗口初始化不再调用会话加载入口，会话状态由消费器经 WindowSyncBus 提供，且分离窗口不得触发任何 llm-chat 持久化路径（`LlmChat.vue:179-213` 的注释明确说明）。

### 1.2 可分离窗口

标题栏拖拽调用 `useDetachable`（`ChatArea.vue:186-212`），输入框也能独立成悬浮窗口；分离组件集合变化后，主 ChatArea 会隐藏重复输入框（`ChatArea.vue:225-236`），并通过 `useWindowSyncBus` 同步主窗口与分离窗口的生成状态（`chat:streaming-delta` 广播，见 8.2）。这里的"分离"是 UI 视图拆分，不会创建新的 Session 或消息副本。

### 1.3 线性与树图两种消息视图

`MessageList.vue` 默认只渲染活动路径回溯得到的消息（由 `activeLeafId` 决定）；消息卡片由消息头、内容、操作栏、分支选择器等组件组合装配（组件装配与内容渲染在消息渲染器笔记 1.2/1.3）。`ViewModeSwitcher.vue:53-55` 通过 UI 状态层在 linear（对话视图）和 force-graph（高级树图视图）之间切换。树图使用独立的节点组件、连线、节点菜单和详情弹窗，属于同一 Session 的另一种投影，**不改变 `activeLeafId`**——树图内双击节点会调用 `store.switchBranch(nodeId)` 把活动分支切到该节点（`useFlowTreeGraph.ts:657-666`），这是数据语义上的分支切换，不是独立的树图副本。

### 1.4 树图视图的交互与状态

依据 `FlowTreeGraph.vue` 及 graph 目录下的物理模拟、子树拖拽、连线预览、节点动作等 composable（数据层的树不变量在会话管理 4.5）：

- 视图缩放范围 0.2–4（`FlowTreeGraph.vue:28-29`），支持 fit view、定位当前激活节点、背景网格/小地图/控制器/HUD 开关、工具栏折叠、撤销/重做、操作历史、视图设置和开发者 debug overlay（`FlowTreeGraph.vue:102-138` 等）。布局有三种：动态树状、物理引力、静态树状（`useFlowTreeGraph.ts:150` 的布局模式）；循环布局和重置布局均是可见按钮，操作历史仅运行时有效。static 模式不进入拖拽物理布局，physics 模式松手后可能回弹（`useGraphSubtreeDrag.ts:177`）。
- 节点上的"查看详情"按钮（`GraphNodeMenubar.vue:256-260`）才会打开详情弹层，弹层位置跟随节点屏幕坐标；节点操作栏提供：复制、创建分支（仅 user/assistant/tool）、重新生成、指定模型重新生成、启用/禁用、删除（二次确认，`GraphNodeMenubar.vue:386-404`），以及"更多"菜单（续写消息、上下文分析、导出分支、重新计算 Token、重新解析工具、数据编辑，`GraphNodeMenubar.vue:263-324`）。右键菜单（`useGraphNodeActions.ts:58-110`）提供"设为当前分支、启用/禁用、剪掉这个分支"。
- 拖拽节点默认移动单点；按修饰键可拖整棵子树，从节点连线到另一节点可移动节点，用另一修饰键则嫁接整棵子树（默认都是 Alt，`config/defaultSettings.ts:133-134`；检测在 `useGraphSubtreeDrag.ts:69-73` 与 `useGraphConnectionPreview.ts:103-107`）。系统拒绝自连、根节点、后代循环、预设节点和同父节点（合法性检查见 `useGraphConnectionPreview.ts:60-90`）。
- 压缩节点标题可展开/收起，收起只改变可见拓扑投影，不删除消息。节点以当前分支激活、禁用、压缩、连线有效/无效等状态区分；debug 层额外显示 id、深度、速度、尺寸和固定坐标（`useGraphD3Simulation.ts`）。

## 2. 会话列表、搜索与现场恢复

### 2.1 会话侧栏：虚拟化与筛选

`SessionsSidebar.vue` 接入 TanStack Virtual：固定预估行高 71px、overscan 10 项，模板用 translateY 定位每一行（`SessionsSidebar.vue:139-146,501-535`）。搜索支持精确/AND/OR 三种匹配模式（数据扫描语义在会话管理 5），并可按 Agent、时间、收藏和生成状态筛选（`FilterPanel.vue`）；菜单动作包括新建、重命名、AI 自动命名（force 模式）、收藏夹移动、导出、打开数据目录和批量清理（空会话批量清理的数据语义在会话管理 3.2）。列表项的生成状态来自节点集合而不是 Session 布尔值（`useTopicNamer.ts:54`），因此多个会话可以同时显示生成中。

批量管理弹窗（`BatchManagerDialog.vue`）提供**会话内容搜索与高亮**：复用 `useLlmSearch`（范围限定会话、300ms 防抖），命中片段用 `<mark class="search-highlight">` 高亮，输入 ≥2 字符进入搜索模式，命中行按匹配详情前 2 条渲染摘要（各环节实现行号见关键源码索引）。

### 2.2 Agent 侧栏虚拟化

`AgentsSidebar.vue` 同样接入虚拟列表，但改用动态测量真实高度（`virtualizer.measureElement`，`AgentsSidebar.vue:926`）——因为智能体卡片高度可能因描述文字长度不同而不固定，不能只靠初始预估（预估 65px，`AgentsSidebar.vue:345`）。

### 2.3 搜索入口与定位工作流

- **侧栏跨会话搜索**：前端 `useLlmSearch` 封装 Tauri 命令 `search_llm_data_stream`（300ms 防抖、精确/全部/任一匹配模式；后端全量扫描数据侧在会话管理 5.1）；命中后只能定位到会话本身，**无法直接跳到会话内的具体消息**。
- **会话内消息搜索**：Ctrl+F 打开 `ChatSearchPanel.vue`（`ChatArea.vue:394-407` 的键盘拦截，焦点在 CodeMirror 内时不拦截，交给编辑器自己的搜索），纯内存线性扫描当前活动路径消息（内容 + 推理内容，最多 50 条，数据语义在会话管理 5.2）；选中结果后按消息 ID 找到对应 DOM 节点平滑滚动过去（`MessageList.vue:325-339`）。`content-visibility: auto` 只跳过屏外内容的渲染工作，不会从 DOM 中删除节点，因此不会妨碍该查询；真正的限制是搜索范围只有当前活动路径，不在当前分支路径上的节点既不会被搜索，也没有对应的消息 DOM。搜索面板自身支持角色筛选（user/assistant）与上下键 + Enter 键盘导航（`ChatSearchPanel.vue:130-149,220-243`）。

### 2.4 切换时的现场恢复

会话切换只改变当前活动路径；输入草稿（含临时模型、续写模型、Knowledge 引用）、悬浮窗（detachedComponents）和消息流缓冲仍由 UI 状态层独立维护（8.1）。会话内搜索面板与跨会话搜索结果不会跨会话保留（本次未在代码中发现按会话保存搜索词/结果的逻辑，未核实恢复行为）。

## 3. Composer、草稿、附件与快捷输入

### 3.1 输入编辑器与发送约定

`MessageInput.vue` 支持 CodeMirror/textarea 两种编辑器、Enter/Shift+Enter（或 Ctrl/Cmd+Enter）发送约定（发送键可配置，默认 Ctrl+Enter，`ChatCodeMirrorEditor.vue:293-303`、`ChatTextareaEditor.vue:224-232`）、输入区高度拖拽/双击复位、附件预览、文件拖入和剪贴板粘贴。附件先进入输入管理器（`useChatInputManager`）的临时列表，处理完成后才随用户消息提交；转写占位符由转录管理器按当前模型能力决定是否插入。生成中会禁用流式模式切换，发送按钮转为中止。工具栏可切换流式输出、宏、附件、迷你会话、临时模型、更多工具、工具调用设置、工具栏设置、输入框展开/收起（`MessageInputToolbar.vue`）。

Composer 提供**显式 Knowledge 资料引用**入口——工具栏的引用选择器（`KnowledgeReferenceControl.vue`，带可访问名称），输入区上方渲染已引用资料库 chips（`KnowledgeReferenceChips.vue`，每个引用库一个 chip，含名称/ID/可用性 tooltip、不可用红色边框、可单独移除，同样带可访问名称）；随消息提交的引用会在发送入口里先执行一次资料检索/研究工具事件（生成 tool 节点）再进入正常生成链（执行侧见对话请求与上下文 9.9；数据结构 `ChatMessageNode.knowledgeReference`）。

### 3.2 快捷操作（宏）

输入框上方的快捷操作并非固定按钮：`MessageInputToolbar.vue:138-155` 合并聊天全局、当前 Agent、有效用户档案绑定的操作组 ID，去重后加载多个操作组。每个操作以占位符接收选区或整个输入框，通过完整宏引擎展开，还可对每一行加前后缀或执行正则替换（`messageInputStore.ts:368-437`）；结果覆盖选区/输入框，开启自动发送时延迟 50ms 发送（`messageInputStore.ts:447-451`）。操作组支持创建、复制、导入、批量导出和绑定。类型字段声明的 `QuickAction.hotkey` 目前没有实际消费方（见第 10 节）。

### 3.3 草稿状态

输入草稿按会话保存（持久化到 `llm-chat-input-drafts`，`useChatInputManager.ts:68,117`），包含文本、附件、临时模型、续写模型和 Knowledge 引用（字段定义见 `useChatInputManager.ts:77-79`）；临时模型和续写模型随会话切换独立维护。当前 Agent 点击打开迷你会话列表（`MiniSessionList.vue`，虚拟列表 + 定位当前会话，:191-201）；迷你会话切换在开启同步切换 Agent 的开关（默认关闭）时会同步切换展示 Agent（`SessionsSidebar.vue:285-298`）。

### 3.4 附件交互与批量动作

附件卡片（`AttachmentCard.vue`）提供"加载失败"与"导入失败"两种失败态及导入中间态图标；输入区侧提供单项重试/取消，以及"一键转写未转写、智能转写、强制重新转写、停止全部"等批量动作（转写执行语义在对话请求与上下文 9.2）。附件两阶段导入的状态机在会话管理 8.3；导入完成后图片引用改用 `asset://` 协议（渲染在渲染器笔记 1.3）。拖入文件失败的反馈与恢复路径本次未单独核实（静态代码只确认了拖入事件绑定与 loading 状态）。

## 4. Agent、模型、工具与发送前配置

### 4.1 Agent 选择与切换

`useLlmChatUiState().selectAgent(agentId, options?)`（`composables/ui/useLlmChatUiState.ts:198-230`）是切换"当前选中 Agent"的入口——不传 options（用户在侧栏主动点选 Agent）时，如果当前有活跃会话，会同步把当前会话的展示 Agent 改成它，即"选中 Agent"和"把当前会话的展示 Agent 改成它"是同一个动作。一旦会话已经产生过真实对话，切换 Agent 不会重建开场白，只是单纯改变"接下来发消息用哪个 Agent"；历史消息仍显示生成时记录的 Agent 快照（数据语义在会话管理 8.1）。

### 4.2 模型选择

标题栏模型在 `showModelSelector` 开启时可直接换模型（`ChatAreaHeader.vue:174-186`）；临时模型选择保存在当前会话草稿状态（3.3）。"切换模型重新生成"/"选择模型续写"走消息操作栏（6.1），执行链在对话请求与上下文 7。

### 4.3 压缩配置与手动压缩入口

压缩配置面板位于 Agent 参数编辑器的 `ContextCompressionConfigPanel.vue`（配置语义在对话请求与上下文附录 A.1）。输入框"更多"菜单的"压缩上下文"调用手动压缩入口（`MessageInputToolbar.vue:124-129` 在当前 Agent 没有启用压缩时禁用该菜单项）。手动调用跳过自动开关与阈值判断，但仍受"最近 N 条保护区"约束（候选不足时返回"没有可压缩的消息"）。

### 4.4 管道配置入口

`PipelineConfig.vue` 提供上下文管道处理器的开关、排序和恢复默认入口（启用状态与顺序持久化在 `llm-chat/pipeline-settings.json`；处理器顺序语义在对话请求与上下文 2）。

## 5. 发送、排队、流式反馈与停止

### 5.1 发送/停止与占位气泡

生成中发送按钮转为中止（`MessageInputToolbar.vue:511-555`，停止按钮与发送按钮都有 title 提示，空输入且无附件时禁用）。三种"再生成"操作（重新生成、切换模型重试、续写）创建的新节点在完成前先注册为生成中并更新活动叶子，保证 UI 能立刻看到"正在生成"的占位气泡（执行顺序在对话请求与上下文 1；占位气泡的渲染在渲染器笔记）。停止按钮触发的 abort 执行层语义在对话请求与上下文 7。

### 5.2 排队反馈

会话生成中再发消息时，消息节点会被创建并持久化但不触发请求（`metadata.isQueued = true`、`status: "queued"`），当前生成结束后按 `queueReplyMode` 合并或链式触发（执行语义在对话请求与上下文 8）。排队/等待状态的界面呈现：`utils/messageStatus.ts:33-103` 把节点状态映射为展示状态，`MessageHeader.vue` 在偏好开关开启（默认 true，`config/defaultSettings.ts:33`）时于消息头渲染对应徽标（图标 + 文案 + tooltip 详情，生成中带旋转动画，截图模式隐藏；`MessageHeader.vue:325-350`）。映射如下：

- `queued` → "排队"；旧数据 `pending` 兼容识别为 queued
- `waiting` → "等待中"
- `generating` → "生成中"
- `error` → "错误"
- 空响应诊断 → "异常回复"

### 5.3 工具审批条

三点流式指示器在 `waiting` 与 `generating` 两个阶段都显示，只依赖消息生命周期状态和错误标记，不再依赖可能异步同步的 `generatingNodes` 集合；渲染器流源仍使用后者判断真实生成任务。这个拆分避免首字到达、状态从等待中切换为生成中时指示器短暂消失（`MessageContent.vue:263-300,1173-1180`）。

工具调用暂停时，`ToolCallingApprovalBar.vue` 在输入区上方提供允许/拒绝/全部允许/全部拒绝/静默执行等动作（`ToolCallingApprovalBar.vue:154-172,187-220`）。"全部允许/全部拒绝"按钮特意不按会话 ID 精确匹配，而是基于 UI 当前渲染出来的可见请求 ID 列表——因为 VCP 广播来的审批请求会话 ID 是 `vcp-${maid}` 格式，跟本地 llm-chat 会话 ID 体系不是一套（`ToolCallingApprovalBar.vue:145-153` 注释里专门解释了这个原因；审批状态语义在对话请求与上下文 9.5）。

审批条带倒计时提示（`formatApprovalWait`，每秒刷新，`ToolCallingApprovalBar.vue:40-60`）：无过期时间时显示"等待人工审批 · 不会自动超时"，否则显示"剩余 N 秒 · 超时将自动拒绝"；超时自动拒绝来自可配置的审批超时（默认关闭，`config/defaultSettings.ts:69-70`）。工具节点审批期间显示"等待"、执行期间显示"生成中"的状态切换由编排层写节点状态（对话请求与上下文 9.5）。

## 6. 消息操作、分支与版本导航

### 6.1 消息操作栏

`MessageMenubar.vue` 实际提供：版本导航（上一/下一分支与位置指示）、变量快照、续写、选择模型续写、上下文分析、导出分支、消息截图、重算 Token、重新解析工具、数据编辑、翻译、复制、停止生成、编辑、创建分支、重新生成、指定模型重新生成、启用/禁用节点和删除确认等（`MessageMenubar.vue:423-604` 及更多菜单 509-607）。翻译按钮支持按住 Shift/Ctrl/Alt 直接使用默认目标语言（`MessageMenubar.vue:408-420`；翻译执行在对话请求与上下文 9.7，结果字段在会话管理 1.3）。硬删除由 `ElMessageBox` 二次确认（`MessageMenubar.vue:167-186`，通过危险样式标记危险操作），删除后代分支的语义与会话管理 4.4 的树操作一致。操作栏的组件装配与渲染属消息渲染器类目。

### 6.2 分支导航 UI

`BranchSelector`（消息卡片组合的一部分）与操作栏的上一/下一分支按钮承担兄弟版本切换，`n/total` 显示当前位置（`MessageMenubar.vue:426-477`）；导航算法（循环切换、`lastSelectedChildId` 记忆、叶子定位）在会话管理 4.1。线性视图下的这些按钮是标准 `<button>`，可 Tab 聚焦（9.1）。

### 6.3 上下文分析器入口

消息菜单"上下文分析"打开 `ContextAnalyzerDialog.vue`，提供五个视图：结构化视图、原始请求、内容分析、宏调试、变量状态（`ContextAnalyzerDialog.vue:37-60`）；最终 Token 统计对管道产出的每条消息重新计算。它复用真实请求的整条管道且可能触发缺失的转写任务（执行侧细节与副作用在对话请求与上下文 9.8）。

### 6.4 导出与截图工作流

- 导出：`ExportBranchDialog.vue`（BaseDialog 封装，宽 1000px、高 80vh，`ExportBranchDialog.vue:18-22`）提供分支导出（Markdown/结构化 JSON/Raw JSON、消息范围与内容选项、可选"使用上下文管道处理"，`ExportBranchDialog.vue:74-88,180-191`）与整会话导出（树状 Markdown / 完整节点树 JSON/Raw，保留隐藏分支）；格式与范围的数据语义在会话管理 7.1。
- 消息截图："创建消息截图"使用独立的渲染器重新渲染所选消息范围，再由截图工具分段捕获并拼成长画布（不是直接截当前窗口可见区域）。用户可选卡片/气泡布局、480-1280px 渲染宽度、输出倍数、主题/纯色/壁纸背景、消息间距与留白、水印、顶部/底部品牌条、工具调用展开策略以及是否显示时间、Token 和字数（`ShareScreenshotDialog.vue:178-184` 等）；交互按钮和编辑入口在截图模式下被隐藏；结果统一输出 PNG，可复制到剪贴板或通过 Tauri 保存对话框写入文件（`useScreenshotGenerator.ts:123-140`）。

### 6.5 可见性设置与语义状态

节点卡片的时间戳、Token 数、字符数、头像、模型信息、性能指标、自动滚动和气泡布局由全局 `uiPreferences` 控制（`types/settings.ts:125-141`）；关闭这些偏好只隐藏元信息，不改变节点内容或请求上下文。`isEnabled=false` 是语义状态，会影响节点是否参与上下文；压缩收起、过滤 active path、隐藏 HUD/小地图则是呈现状态，不能混为"节点被删除"。"查看详情"是 teleported 到 body 的独立弹层，节点右键菜单和详情弹层的位置跟随节点屏幕坐标（`useGraphNodeActions.ts:194-234`）；因此切换缩放/布局后，弹层需要重新定位，不能把它当成节点卡片的静态子元素。

## 7. 多会话、多模型与后台生成

- 多会话可同时生成：列表项的生成状态来自节点集合（`generatingNodes`）而非 Session 布尔值（2.1；数据语义在会话管理 6）。
- 同会话生成中再发消息进入排队（5.2）；多模型并行、群聊、子 Agent 等场景的界面区分本次调查未覆盖。
- 后台会话生成完成没有专门的返回入口或系统通知（8.3）。

## 8. Chat UI 状态所有权与同步

### 8.1 UI 状态层

`useLlmChatUiState.ts`（`composables/ui/`）持有视图模式、当前选中 Agent、侧栏折叠与宽度等 UI 状态，持久化到 `llm-chat/ui-state.json`（300ms 防抖，`useLlmChatUiState.ts:89-98`）。输入草稿（按会话保存）、悬浮窗和消息流缓冲由 UI 状态层独立维护，与会话对象本身分离——会话切换只改变活动路径，不重置这些局部状态（2.4）。

### 8.2 跨窗口同步与断连边界

主窗口与分离窗口经 `useWindowSyncBus` 同步生成状态（`chat:streaming-delta` 广播，RAF 节流；执行侧在对话请求与上下文 5）。窗口类型按路径判定（`/detached-component/` 与 detached-tool，`useWindowSyncBus.ts:103-116`）；分离窗口的会话写操作经 `executeOrProxy` 转发主窗口（数据语义在会话管理 2.1）。已确认边界：若窗口关闭/断连，流缓冲仍在主进程内存中，用户看到的最后一段内容能否在重连后完整回放取决于订阅时机（渲染侧的重放机制在消息渲染器笔记 2.1）。

### 8.3 桌面集成交点

- 系统托盘（`src-tauri/src/tray.rs:39-60`）菜单包含"显示主窗口、隐藏主窗口、重启前端、清除窗口配置、退出"，**没有聊天生成状态相关的动态菜单项**。
- 项目中没有找到系统通知相关 API 的使用（搜索 `tauri-plugin-notification`、`sendNotification`、`request_user_attention`、`UserAttentionType`，检查范围：`src/` 与 `src-tauri/` 全目录搜索）——没有 Windows Toast、标题栏闪烁或任务栏提醒的实现证据。
- 生成完成只驱动 `generatingNodes`、消息卡片状态和 `useWindowSyncBus` 的跨窗口同步，没有触发系统通知、托盘图标变化或标题栏提醒；应用处于后台时，不会主动提示某个会话已生成完成。

## 9. 键盘、焦点、响应式与关键路径可用性

（结论来自静态代码；视觉效果与焦点顺序需运行验证，未实测。）

### 9.1 关键路径键盘

- **发送消息**：可以。`ChatCodeMirrorEditor.vue`/`ChatTextareaEditor.vue` 都支持 `Ctrl/Cmd+Enter` 或 `Enter` 发送（可配置 `sendKey`），不依赖鼠标点击发送按钮（9.1 见 3.1 引用）。
- **切换会话**：不可以。会话列表项是绑定点击事件的可点击 `div`（`SessionItem.vue:92`），没有 `tabindex`、`role="option"` 或 `role="listbox"`，也没有方向键或 Ctrl+Tab 的会话切换绑定；div 默认不可聚焦，列表项不在 Tab 焦点序列里，纯键盘用户无法直接切换会话。
- **查看分支**：部分可行。操作栏上一分支/下一分支按钮是标准 `<button>` 元素（可被 Tab 聚焦、可用 Enter/Space 激活，`MessageMenubar.vue:428-476`）；树图视图画布本身可聚焦（`tabindex="0"`，`FlowTreeGraph.vue:22`），但内部的节点选择、右键菜单操作、连线嫁接等均是鼠标驱动的交互（拖拽、右键、双击），**没有找到等效的键盘操作路径**，聚焦后也没有发现方向键选中/切换节点的绑定。
- 结论：发送消息具备键盘路径，会话切换和树图操作基本依赖鼠标；线性视图下的分支切换按钮可通过 Tab 聚焦。该结论来自静态代码搜索，未经屏幕阅读器实测，不能作为正式的 WCAG 合规结论。

### 9.2 可访问名称现状

`llm-chat` 目录下找到的主动语义化 ARIA 标注包括：

- 批量管理会话列表的表格语义（`role="table"` + `aria-label`，行元素 `role="row"`，`BatchManagerDialog.vue:81`）；
- Knowledge 引用控件与引用 chips 的多处 `aria-label`；
- 消息头状态徽标的 `aria-label`（`MessageHeader.vue:339`）；
- `ChatTextareaEditor.vue:324` 一处技术性 `aria-hidden`。

消息操作栏、发送/中止按钮、节点图菜单普遍使用"图标按钮 + title 属性"或 `el-tooltip`（发送/停止按钮只有 title 文案，`MessageInputToolbar.vue:516,539`）。title 对屏幕阅读器的支持取决于浏览器和辅助技术组合，不能替代明确的可访问名称。

### 9.3 响应式

三栏布局没有媒体查询或容器宽度自动折叠（`LlmChat.vue` 模板与样式中未发现媒体查询）：侧栏显示由用户手动控制并持久化（折叠状态存在 `llm-chat/ui-state.json`），窗口变窄时不会自动收起侧栏，三栏会一起被压缩。侧栏宽度可通过拖拽在 200-600px 范围内调整（`useResizable`，`LlmChat.vue:100-114`），但这是手动操作，不属于响应式自适应。弹窗内部有断点（如收藏夹管理在 720px 切单列、会话设置有两级高度断点）——这类弹窗断点不改变聊天主链布局，仅记录存在。

### 9.4 运行验证要求

视觉反馈、焦点顺序、键盘可用性、响应式行为和系统通知均需运行验证；本笔记结论主要来自静态代码。

## 10. 设计取舍与已确认边界

- **消息列表不再虚拟化**（当前方案的渲染机制在消息渲染器笔记 8，撤回历史留在这里）：Git 历史表明消息列表并非一直采用当前方案：
  - `30b0ce71b`（2025-11-02）首次在 `MessageList.vue` 接入 TanStack Virtual（初版固定预估行高 200、overscan 5、只挂载可见消息、绝对定位加 translateY）；
  - 此后多轮提交持续处理动态高度与滚动定位问题（`6efa00864`、`515c215de`、`bff4d7de8`、`d9f56e9a6`、`9cce774fe`、`f5e66344b` 等）；
  - `5c6844727`（2026-04-29）撤回改用原生 DOM，提交说明将原因归结为聊天消息高度动态、倒序加载闪烁、估算不准和初始化复杂；在该项目"几百条消息"的目标规模下，作者实测会话切换由 3–5 秒降至 500ms 内（**该性能数字来自提交说明，笔记未独立复测**）；
  - 撤回后滚动和导航都改为基于真实 DOM（触底滚动、按消息 ID 查询并读取位置定位，`MessageList.vue:325-385`）；
  - 后续 `1d971ff54`、`25ef4a7f5` 又处理了生产构建中 `content-visibility` 被优化器移除的问题。

  注意区分：旧方案是真正的列表虚拟化（屏外消息组件不挂载）；当前方案是"完整 DOM + 浏览器渲染裁剪"，所有活动路径消息仍在 DOM 中。
- **线性视图与树图共用同一份节点数据**；树图的交互路径已做静态代码核实，大规模节点树的布局性能未做运行时压测（仓库 `docs/Plan/tree-graph-performance-investigation.md` 记录的是性能计划，不能据此得出性能结论）。
- **分离窗口断连的回放依赖订阅时机**（8.2）。
- **`QuickAction.hotkey` 未落地**：类型定义声明了 `hotkey?: string`（`types/quick-action.ts:33`），但 `src/tools/llm-chat` 中没有任何读取或注册该字段的代码（搜索 `.hotkey` 无消费方）——快捷操作按钮、模板展开和自动发送可用，配置快捷键本身没有执行链。
- **语义状态与呈现状态必须区分**（6.5）。
- **会话切换无键盘路径、树图无键盘等效操作**：静态代码确认，属关键路径可用性缺口（9.1），需运行验证确认影响范围。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为、系统通知需要运行验证（静态代码只能确认入口、状态与事件绑定）。
- 树图大规模节点布局性能未压测。
- 分离窗口断连后流缓冲重放的实际观感未验证（8.2）。
- 会话切换键盘缺失、树图无键盘路径、会话搜索面板跨会话不保留等结论来自静态代码搜索，未经运行时可用性测试。

## 12. 关键源码索引

- `src/tools/llm-chat/LlmChat.vue`（顶层装配、窗口类型初始化分支、恢复横幅，321-372/457-507行）
- `src/tools/llm-chat/components/ChatArea.vue`（视图切换、搜索面板挂载、悬浮窗，214-216行滚动定位）
- `src/tools/llm-chat/components/message/MessageMenubar.vue`（消息操作入口，167-186行删除确认，408-420行翻译快捷键）
- `src/tools/llm-chat/components/message/ViewModeSwitcher.vue`、`message/MessageList.vue`（入口层面，渲染机制在渲染器笔记）
- `src/tools/llm-chat/components/message-input/MessageInput.vue`、`MessageInputToolbar.vue`、`ToolCallingApprovalBar.vue`
- `src/tools/llm-chat/components/message-input/KnowledgeReferenceControl.vue`、`KnowledgeReferenceChips.vue`（显式资料引用）
- `src/tools/llm-chat/utils/messageStatus.ts`、`components/message/MessageHeader.vue`（生命周期状态徽标）
- `src/tools/llm-chat/components/sidebar/BatchManagerDialog.vue`（会话内容搜索与高亮，154/185/362-364/417-432 行）、`SessionsSidebar.vue`（139-146 行虚拟化）、`AgentsSidebar.vue`（926 行）
- `src/tools/llm-chat/components/search/ChatSearchPanel.vue`（52-121行线性扫描）
- `src/tools/llm-chat/components/conversation-tree-graph/flow/`（`FlowTreeGraph.vue`、`useFlowTreeGraph.ts`、`useGraphD3Simulation.ts`、`useGraphSubtreeDrag.ts`、`useGraphConnectionPreview.ts`、`useGraphNodeActions.ts`、`GraphNodeMenubar.vue`）
- `src/tools/llm-chat/composables/ui/useLlmChatUiState.ts`（198-230行 selectAgent）、`composables/input/useChatInputManager.ts`
- `src/tools/llm-chat/components/context-analyzer/ContextAnalyzerDialog.vue`、`components/export/ExportBranchDialog.vue`、`components/screenshot/ShareScreenshotDialog.vue`
- `src-tauri/src/tray.rs`（托盘）
