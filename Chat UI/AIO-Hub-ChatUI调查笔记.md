# AIO-Hub Chat UI 调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：只读核对源码、两源码快照差异与现有测试；追踪组件入口、状态、事件和持久化，未启动应用或服务
>
> 调查范围：桌面聊天工作台、会话导航、输入与草稿、配置入口、生成控制、消息编辑、阅读导航、后台任务与伴生视图、分离窗口；移动端聊天整体布局未展开，消息绘制和应用级设置框架分别由相邻类目承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 桌面聊天以 Agent/参数侧栏、中央聊天区、会话侧栏组成工作台；中央区可分离，输入框也可独立成窗。子 Agent 另有只读伴生栏和画中画，能在保留主会话选中态的同时观察子会话。
- 线性阅读支持卡片、气泡、连续紧凑三种布局；紧凑模式按身份连续性合并展示，提供按用户提问定位的导航点，消息节点和分支身份仍独立保存。树图是同一消息树的另一种投影。
- 会话列表使用动态测量虚拟列表。消息区常驻的只有活动路径的行壳，富文本正文按阅读区延迟解析，并随显示树回收与恢复。
- 输入功能面板、输入工具栏与消息工具栏均可配置。文本材料支持输入前编辑、消息发送后直接编辑或保存到新分支；草稿已按会话存入应用文件，新会话的身份草稿也可独立恢复。
- 会话项具有 Tab、Enter/Space 和 Shift+F10/菜单键绑定；树图的拖拽、嫁接仍以鼠标为主。代码可确认这些路径，实际焦点顺序与键盘体验尚未实测。
- 后台任务拥有标题栏胶囊、任务中心、派遣卡片和返回派遣位置的入口。生成完成接入系统通知的链路当前未在桌面源码中找到，应用内的可观察性由这些入口承担。

## 工作台边界与用户主链

```text
进入聊天 -> 加载渠道、Agent、会话索引与草稿
  -> 恢复选择或进入新会话草稿
  -> 输入正文/附件/文本材料，选择模型与配置
  -> 发送前确认有效模型，必要时打开模型选择器
  -> 生成/排队/审批/压缩任务反馈 -> 停止或继续
  -> 编辑、保存到分支、版本切换、搜索、提问导航与树图
  -> 主会话与子任务伴生视图之间观察/跳转
  -> 切换工具或会话，再恢复各层拥有的现场
```

会话树与数据变更语义见[会话与消息管理笔记](<../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md>)；请求、压缩与仲裁执行见[对话请求与上下文笔记](<../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md>)；列表、内容块与承载边界见[消息渲染器笔记](<../消息渲染器/AIO-Hub-消息渲染器调查笔记.md>)；应用级导航和设置框架见[应用界面基础设施笔记](<../应用界面基础设施/AIO-Hub-应用界面基础设施调查笔记.md>)。

## 1. 页面结构、聊天入口与多种表面

### 1.1 三栏工作台与首次发送

[聊天根组件](<../../aio-hub/src/tools/llm-chat/LlmChat.vue#L138-L213>)先加载模型渠道，再加载 Agent、用户档案和会话等核心数据，随后准备聊天入口。中央区保留消息区和输入区的完整框架；恢复索引期间显示恢复横幅，可取消恢复、打开损坏文件目录、导出诊断或确认删除隔离文件。

首次进入只尝试恢复已有配置，无有效模型时不会立即弹出选择器。真正发送时才请求选择模型；取消选择则不提交，选择成功后可更新 Agent 模型、建立默认 Agent，并进入新会话草稿。发送准备状态用于阻止重复准备；索引恢复尚未 ready 时中央输入仍禁用。入口见[发送处理](<../../aio-hub/src/tools/llm-chat/LlmChat.vue#L245-L277>)与[聊天入口准备器](<../../aio-hub/src/tools/llm-chat/composables/ui/useChatEntryPreparation.ts#L29-L78>)。

### 1.2 分离窗口和伴生窗口的区别

聊天区和输入区通过分离机制成为独立 WebView；同一输入框分离后，原聊天区隐藏重复输入表面。分离视图沿同步总线消费状态，写动作由主窗口代理，视图分离本身不创建新会话。装配和输入隐藏条件见[ChatArea](<../../aio-hub/src/tools/llm-chat/components/ChatArea.vue#L196-L252>)。

伴生视图面向后台子任务：它按指定子会话 ID 加载活动路径，不改变主会话选择。空间充足时注入中央区右侧槽位，为聊天正文结构性让位；空间不足或用户选择画中画时改用浮动面板。中央宿主需至少容纳 480px 聊天区和 360px 伴生栏，伴生宽度默认 420px，可在 360–720px 内调整并写入本地偏好。几何与偏好见[伴生停靠状态](<../../aio-hub/src/tools/llm-chat/composables/ui/useChatCompanionDock.ts#L19-L42>)，两种表面的实际切换见[伴生视图](<../../aio-hub/src/tools/sub-agent/components/CompanionSessionSheet.vue#L72-L115>)。

### 1.3 线性、紧凑阅读与树图

线性视图中，卡片和气泡为逐节点展示；连续紧凑模式让连续的相同助手身份及其所属工具结果共用身份头，连续用户输入也可合组。压缩、预设、开场白和 Knowledge 引用形成边界。合组要求父子连续，并比较 Agent、模型和来源身份，属于展示投影，不可用作执行轮次计数。[分组规则](<../../aio-hub/src/tools/llm-chat/utils/messagePresentation.ts#L26-L140>)与[行装配](<../../aio-hub/src/tools/llm-chat/components/message/MessageRow.vue#L137-L170>)保留各节点原有 ID、操作和状态。

树图和线性视图共享会话节点；切换视图只换投影，双击树图节点会进一步调用分支切换，改变活动叶子。树图提供动态树状、物理引力和静态布局、缩放/定位、小地图、操作历史、节点详情、启用禁用、重试、分支与删除。节点单点拖动、修饰键拖子树、连线移动和嫁接都有合法性判断，拒绝根节点、自连或后代循环；这些路径主要集中在[树图编排](<../../aio-hub/src/tools/llm-chat/components/conversation-tree-graph/flow/composables/useFlowTreeGraph.ts>)和[树图宿主](<../../aio-hub/src/tools/llm-chat/components/conversation-tree-graph/flow/FlowTreeGraph.vue>)。布局性能和拖动观感未运行验证。

## 2. 会话列表、搜索与恢复

### 2.1 同一会话项服务两处入口

会话侧栏使用公共动态测量虚拟列表，71px 是初始估高，实际行高由 DOM 测量更新；搜索摘要和菜单等内容不再依靠固定高度假设。[列表配置](<../../aio-hub/src/tools/llm-chat/components/sidebar/SessionsSidebar.vue#L124-L146>)与[行测量挂载](<../../aio-hub/src/tools/llm-chat/components/sidebar/SessionsSidebar.vue#L375-L408>)共同确认这一点。输入区迷你会话列表复用相同会话项和操作对话框，只采用较紧凑的样式。

会话项可点击或经 Enter/Space 激活；右键、Shift+F10 和菜单键打开同一操作菜单，全局只保留一个已打开的会话菜单。菜单除重命名、自动命名、收藏、导出和打开目录外，还提供“从文件重新加载”；生成中禁用重新加载，动作进入公共会话操作处理器。详见[会话项](<../../aio-hub/src/tools/llm-chat/components/sidebar/SessionItem.vue#L60-L98>)、[键盘与右键绑定](<../../aio-hub/src/tools/llm-chat/components/sidebar/SessionItem.vue#L129-L145>)、[重新加载处理](<../../aio-hub/src/tools/llm-chat/components/sidebar/SessionActionDialogs.vue#L179-L230>)。

尚无历史会话时，侧栏明确区分“当前是新会话草稿”和可创建新会话的空态；草稿不会被当成已落入历史列表的会话。[空态条件](<../../aio-hub/src/tools/llm-chat/components/sidebar/SessionsSidebar.vue#L358-L373>)可直接复查。

### 2.2 两套搜索与提问导航

- 跨会话搜索通过 Rust 流式搜索命令返回命中会话和摘要，支持精确、AND、OR，以及 Agent、时间、收藏等筛选；点击结果进入会话，当前侧栏路径未提供直接定位某条命中消息的动作。入口见[搜索封装](<../../aio-hub/src/tools/llm-chat/composables/chat/useLlmSearch.ts>)。
- 会话内 Ctrl+F 打开搜索面板，扫描当前活动路径的正文及推理内容；焦点在 CodeMirror 内时交给编辑器搜索。结果支持角色筛选、上下键和 Enter，随后按消息 ID 定位行壳。入口与定位见[ChatArea](<../../aio-hub/src/tools/llm-chat/components/ChatArea.vue>)、[搜索面板](<../../aio-hub/src/tools/llm-chat/components/search/ChatSearchPanel.vue>)。
- 紧凑模式把阅读导航改为“上/下一个提问”和提问点列，主聊天用户及人工干预来源进入提问集合，预设和工具消息不成为提问点；必要时保留开场导航点。按钮带提问摘要及当前步骤标记，点击实际发送锚点节点 ID。见[导航投影](<../../aio-hub/src/tools/llm-chat/utils/messagePresentation.ts#L173-L197>)与[导航器](<../../aio-hub/src/tools/llm-chat/components/message/MessageNavigator.vue#L149-L225>)。

### 2.3 现场恢复按层处理

会话切换更换选中会话和活动路径；输入管理器另存每个会话草稿，不依赖当前消息 DOM。工具页被 KeepAlive 停用时，消息列表保存阅读锚点并停止测量观察器；恢复时重新计算阅读范围和行高，继续按消息相对视口的位置恢复。详情晚到结果也会复核当前选择，避免快速切换时回跳旧会话。相关实现见[列表停用与激活](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L92-L112>)、[滚动锚点](<../../aio-hub/src/tools/llm-chat/composables/ui/useMessageScrollAnchor.ts>)与[会话生命周期管理](<../../aio-hub/src/tools/llm-chat/stores/session/sessionLifecycleManager.ts>)。

搜索词、树图运行期历史和面板内部状态各有生命周期；本次未确认存在跨重启恢复全部这些现场的统一快照。

## 3. Composer、面板与草稿

### 3.1 编辑器、快捷操作与功能面板

输入区支持 CodeMirror 和 textarea，发送键可配置；附件选择、粘贴和文件拖入进入同一输入管理器。输入框可拖高度、双击复位，分离模式另有原生窗口宽度调整手柄。工具栏提供临时模型、续写模型、附件、会话和 Knowledge 等入口；正文编辑器各自实现发送及斜杠补全，见[CodeMirror 输入](<../../aio-hub/src/tools/llm-chat/components/message-input/ChatCodeMirrorEditor.vue>)与[textarea 输入](<../../aio-hub/src/tools/llm-chat/components/message-input/ChatTextareaEditor.vue>)。

斜杠候选聚合系统指令和当前有效快捷操作组，支持拼音检索；系统动作进入会话操作，快捷操作则运行宏模板、选区替换或自动发送。三层操作组来自聊天全局、Agent 和有效用户档案。候选及执行入口见[斜杠服务](<../../aio-hub/src/tools/llm-chat/services/slashCommandService.ts>)。类型中虽有快捷键字段，本次在聊天域仍未找到注册该字段的消费链，不能把按钮快捷操作等同于已启用任意自定义热键。

输入框上方由公共插槽承载输入设置、宏、会话、工具调用、Knowledge 和画布等面板。同一时刻一个面板；折叠保留内部状态，关闭清空组件；重复点击按偏好选择折叠或关闭。面板可声明最大内容高度，部分面板自行管理虚拟列表滚动。见[面板宿主](<../../aio-hub/src/components/common/input-panel/InputPanelHost.vue>)与[面板状态](<../../aio-hub/src/composables/useInputPanel.ts>)。

### 3.2 两类工具栏的自定义

输入工具栏可排列常驻动作、快捷操作组和右侧状态项，提供简洁/完整预设；窄宽度把末尾动作和部分统计临时收进“更多”。编辑器从主窗口打开，设置保存后发布完整快照供分离输入窗同步。配置与动作分派分别见[输入工具栏配置](<../../aio-hub/src/tools/llm-chat/config/inputToolbar.ts>)及[工具栏实现](<../../aio-hub/src/tools/llm-chat/components/message-input/MessageInputToolbar.vue>)。

消息操作栏另有独立的排序/显隐偏好，动作由固定配置表映射，新增动作需要同时登记可定制 ID 和实际动作。聊天布局与两个工具栏偏好均属于 ChatSettings，非某条消息的内容字段；见[消息工具栏配置](<../../aio-hub/src/tools/llm-chat/config/messageToolbar.ts>)与[自定义弹窗](<../../aio-hub/src/tools/llm-chat/components/message/MessageToolbarCustomizeDialog.vue>)。

### 3.3 草稿持久化与文本材料

输入管理器按会话 ID 保存正文、附件、文本材料、Knowledge 引用、临时与续写模型，另有全局草稿剪贴板及保存状态。桌面持久化写入应用配置下 `llm-chat/input-drafts.json`，旧浏览器键仅用于迁移；写入队列冻结快照，避免先发写入的晚到结果覆盖新状态。字段与作用域见[输入管理器](<../../aio-hub/src/tools/llm-chat/composables/input/useChatInputManager.ts#L77-L146>)，文件读写见[草稿存储](<../../aio-hub/src/tools/llm-chat/composables/storage/useChatInputDraftStorage.ts>)。

未发送首条消息的新会话另把身份、根节点 ID 和参数覆盖保存到 `llm-chat/new-session-draft.json`；输入仍通过同一会话 ID 关联草稿。恢复时重建空根，首条真实消息提交后再进入普通历史会话生命周期。[新会话草稿存储](<../../aio-hub/src/tools/llm-chat/composables/storage/useNewSessionDraftStorage.ts#L22-L99>)确认了文件恢复路径。

长文本粘贴及跨工具发送可转为消息内文本附件；输入区把文件与文本材料统一计数和排列，卡片提供新建、编辑、回填正文等入口。历史消息也能编辑文本材料或保存到新分支：会话生成中拒绝修改，保存前核对原材料内容与标题，冲突时提示重新打开；只读伴生表面只可预览。入口见[文本材料组件](<../../aio-hub/src/tools/llm-chat/components/VirtualTextAttachments.vue>)，写入与冲突判断见[正文适配层](<../../aio-hub/src/tools/llm-chat/components/message/MessageContent.vue#L169-L208>)。长图切片、转写和材料如何进入请求由请求笔记说明。

## 4. 发送前配置与诊断工作区

Agent 选择、标题栏模型选择、输入临时模型、续写模型是不同作用域。历史消息显示生成时 Agent/渠道/模型快照；切换当前 Agent 影响后续发送，已有真实对话不会因此重建开场白。Agent 编辑器提供“模型参数”和“上下文”两个页签，共用同一参数草稿；上下文页含限制、压缩、后处理及自动动静分离配置。实际编辑与保存见[Agent 编辑弹窗](<../../aio-hub/src/tools/agent-manager/components/management/EditAgentDialog.vue#L341-L413>)，参数面板见[模型参数编辑器](<../../aio-hub/src/tools/agent-manager/components/parameters/ModelParametersEditor.vue#L502-L677>)。配置对执行的影响以请求笔记为准。

上下文分析器有六个视图：结构化、原始请求、内容分析、变化与缓存、宏调试、变量状态。前三者等预览内容由当前目标重建；“变化与缓存”读取真实发送记录，二者证据来源不同。[分析器装配](<../../aio-hub/src/tools/llm-chat/components/context-analyzer/ContextAnalyzerDialog.vue#L28-L70>)及[预览调用](<../../aio-hub/src/tools/llm-chat/components/context-analyzer/ContextAnalyzerDialog.vue#L159-L189>)可复查。当前预览链使用预览上下文，缺少转写时不启动后台转写，详见请求笔记。

变化与缓存页是独立诊断工作区：可选本次请求、对照基准、前次重试，自动关联当前消息，提示跨分支比较；展示公共前缀、首个变化块、配置变化、来源、组装步骤、缓存读写和明细。记录摘要和保存去敏文本预览分别有开关，支持刷新与清空当前会话记录；明细按需展开。上游用量区分实报、部分上报和未报，文本相同或前缀稳定只说明可比较的输入结构，实际缓存量仍看上游。入口与开关见[诊断页顶部](<../../aio-hub/src/tools/llm-chat/components/context-analyzer/ChangesAndCacheView.vue#L1-L172>)，用量状态见[实报分派](<../../aio-hub/src/tools/llm-chat/components/context-analyzer/ChangesAndCacheView.vue#L768-L831>)。

## 5. 生成反馈、排队、压缩与审批

发送进入生成后，输入按钮提供停止入口，消息头显示等待、生成、排队、错误或异常回复；手动停止和队列停止有独立展示映射。对生成中的目标父路径继续发送，先创建排队消息，其他空闲分支仍可独立生成。停止既可针对会话，也有消息级停止动作；真正取消及队列语义见请求笔记。显示状态以[状态映射](<../../aio-hub/src/tools/llm-chat/utils/messageStatus.ts>)和[消息操作分派](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L673-L739>)为证。

上下文压缩单独显示为会话级任务条，位于消息列表末尾，含消息数、运行/取消/失败状态和可展开解释。取消按钮直接调用当前视图会话的取消压缩动作；只读表面隐藏取消，截图隐藏任务条。它不是普通“助手正在回复”气泡，任务完成后的摘要节点另有压缩消息展示。见[任务条组件](<../../aio-hub/src/tools/llm-chat/components/message/ContextCompressionTask.vue#L20-L61>)与[列表接线](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L829-L837>)。

工具审批条提供逐项允许/拒绝、批量处理和静默执行。批量动作基于当前可见请求集合，以兼容本地聊天与外部来源不同的会话标识。倒计时在配置了过期时间时提示自动拒绝，否则显示持续等待；自动仲裁只在其配置和来源条件满足时执行，未得出可自动执行结论时仍保留人工入口。UI 状态和事件见[审批条](<../../aio-hub/src/tools/llm-chat/components/message-input/ToolCallingApprovalBar.vue>)，仲裁执行边界见[Agent 工具笔记](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)。

## 6. 消息操作、编辑、分支与交付

消息菜单按节点角色、生成状态、只读与截图模式装配复制、翻译、停止、编辑、重试、续写、分支、导出、截图、上下文分析和高级数据编辑；删除有二次确认。兄弟版本选择只换活动路径，编辑保存或“保存到分支”才进入数据写动作。操作装配见[消息菜单](<../../aio-hub/src/tools/llm-chat/components/message/MessageMenubar.vue>)，对应 store 接线见[列表动作表](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L673-L739>)。

高级 JSON 编辑器打开时复制目标节点并聚焦编辑器；保存要求合法对象及文本正文，分支保存还要求原节点有父节点。普通保存更新节点，分支保存调用创建编辑分支入口，成功后给出不同反馈。[高级编辑器](<../../aio-hub/src/tools/llm-chat/components/message/MessageDataEditor.vue#L103-L211>)说明了两种保存路径。树图入口也携带明确的会话作用域，避免目标被当前会话选择隐式替换。

分支导出可选择 Markdown、结构化 JSON、Raw 等格式及消息范围；整会话导出保留隐藏分支。截图另起渲染表面，选择范围、卡片/气泡/紧凑布局、宽度、背景、品牌条和元信息，截图模式隐藏操作后生成 PNG，可复制或保存。交互入口见[导出对话框](<../../aio-hub/src/tools/llm-chat/components/export/ExportBranchDialog.vue>)与[截图对话框](<../../aio-hub/src/tools/llm-chat/components/screenshot/ShareScreenshotDialog.vue>)；交付数据语义留给导出及会话专项。

## 7. 多会话与后台任务的可观察性

普通多会话生成以节点运行集合和列表状态区分。后台子 Agent 进一步提供三层入口：主消息中的派遣卡片，子会话伴生视图，以及全局任务中心。标题栏活动胶囊订阅任务注册表，展示活动任务数和最近摘要，悬浮列表最多五条；点击有子会话的任务直接打开伴生视图，没有子会话则定位任务中心。返回派遣入口可切回父会话并定位对应卡片。见[标题栏任务装配](<../../aio-hub/src/components/TitleBar.vue#L193-L279>)。

伴生视图通过子会话 ID 读取完整活动路径并显示执行流；只读契约由列表显式作用域、下传 readonly 和写操作代理共同约束。只有“打开完整会话”才切换主会话选择；加载失败可重试或进入完整会话，任务变更按 350ms 合并刷新。见[伴生状态与加载](<../../aio-hub/src/tools/sub-agent/composables/useCompanionSession.ts#L61-L161>)、[跳转和刷新](<../../aio-hub/src/tools/sub-agent/components/CompanionSessionSheet.vue#L152-L181>)与[列表只读代理](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L153-L173>)。

上述是应用内可观察性。检查桌面前后端目录中的通知插件、发送通知和请求窗口注意力 API，当前未找到生成完成接系统通知的实现证据；普通后台会话也未找到专门的完成通知返回入口。系统托盘保留应用显示、隐藏、前端重启、清配置和退出等动作，未见聊天状态动态项。

## 8. UI 状态所有权与同步

| 状态 | 所有者和恢复方式 |
|---|---|
| 当前会话、消息树、活动叶子、生成与压缩任务 | 聊天 store 与会话管理层；UI 以明确会话 ID 消费 |
| 侧栏折叠/宽度、选中 Agent、视图模式、参数分组展开 | UI 单例，配置文件 `llm-chat/ui-state.json`，300ms 防抖 |
| 正文、附件、文本材料、临时/续写模型、引用、草稿剪贴板 | 输入单例，按会话记录；应用文件持久化，并走输入状态同步 |
| 输入/消息工具栏布局与消息外观 | ChatSettings；主窗口保存后向分离窗口发布 |
| 当前输入功能面板及折叠 | 当前输入容器提供的面板状态；关闭销毁，折叠保留 |
| 阅读锚点、富文本折叠/代码查看现场 | 当前列表与渲染器运行期状态，按停用/恢复交接 |
| 伴生任务目标和显示模式 | 伴生单例运行期状态；栏宽另存 localStorage |

文件偏好定义见[聊天 UI 状态](<../../aio-hub/src/tools/llm-chat/composables/ui/useLlmChatUiState.ts#L66-L101>)。跨窗口总线提供初始状态、增量、操作代理与流式 delta，输入同步带版本及本地变更时间，避免迟到初始状态覆盖首轮输入。高频正文流源和低频节点字段是不同通道，流源位于前端窗口内存，不能描述为 Rust 主进程保留全部可重放正文。详见[聊天同步](<../../aio-hub/src/tools/llm-chat/composables/chat/useLlmChatSync.ts>)与[流接收服务](<../../aio-hub/src/tools/llm-chat/services/chatStreamReceiver.ts>)；断连后的最终恢复体验未实测。

## 9. 键盘、焦点、响应式与验证边界

- 发送有编辑器快捷键；已挂载的会话项可 Tab 聚焦并以 Enter/Space 选择，菜单可用 Shift+F10/菜单键打开。虚拟列表仅挂载可见项，这些绑定本身不足以证明全部历史会话可无障碍遍历。
- 线性分支按钮、提问导航、工具卡展开和压缩任务按钮有键盘可聚焦元素；公共对话框接入焦点进入、Tab 边界回环、最上层 Esc 和关闭归还，细节见基础设施笔记。
- 树图节点拖拽、连线和嫁接，本次在已读交互入口中未找到完整键盘等效路径；画布可聚焦只解决焦点进入，上述操作仍停留在指针交互。
- 左右业务侧栏仍由用户手动折叠和拖宽；中央伴生栏另按可用宽度自动切为画中画，工具栏有溢出收纳。不能用“三栏无媒体查询”否定这些局部适配。

本轮未运行 Tauri、浏览器或服务。视觉层级、窄窗可用性、焦点实际顺序、读屏、拖拽、多窗口重连、系统托盘与长会话性能都需要目标运行态观察；源码与现有测试仅用于确认事件、条件和状态路径。本笔记不据静态标签作 WCAG 合规判断。

## 10. 关键源码索引

- [LlmChat](<../../aio-hub/src/tools/llm-chat/LlmChat.vue>)：入口准备、三栏、恢复与发送。
- [ChatArea](<../../aio-hub/src/tools/llm-chat/components/ChatArea.vue>)：搜索、视图、输入、停靠槽位。
- [MessageList](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue>)：会话作用域、动作表、提问导航与任务条。
- [输入管理器](<../../aio-hub/src/tools/llm-chat/composables/input/useChatInputManager.ts>)：会话草稿与跨窗口输入同步。
- [伴生视图](<../../aio-hub/src/tools/sub-agent/components/CompanionSessionSheet.vue>)：只读双表面、任务刷新和完整会话跳转。
- [变化与缓存页](<../../aio-hub/src/tools/llm-chat/components/context-analyzer/ChangesAndCacheView.vue>)：实发请求诊断工作区。
