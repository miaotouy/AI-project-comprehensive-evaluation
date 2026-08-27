# Chat UI 横向对比

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、DeepSeek Harness、Hermes Agent、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、Risuai、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-27
>
> 依据：本类目 18 篇单项目调查笔记（自 `../Chat/Chat横向对比.md` 迁移）
>
> 对比方法：按工作台拓扑、会话导航、Composer 与发送前配置、生成反馈与停止入口、消息操作、分支导航、搜索与现场恢复等用户工作流维度逐项对照；通用界面盘点（弹窗/Toast/主题/动画等）不进入本对比
>
> 对比范围：用户工作流与界面状态；内容渲染在消息渲染器横向对比，数据语义在会话与消息管理横向对比，执行语义在对话请求与上下文横向对比
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 同样的会话数据结构，用户看到的是**不同的工作流**：主界面/导航、输入与生成中交互、消息操作入口和分支导航方式各不相同。
- **"消息渲染"至少有四层含义**：活动路径编译后完整挂载 DOM + `content-visibility`（AIO Hub）、虚拟化 flat list（Chatbox/Cherry/Lobe/Jan）、测量驱动窗口化（DeepChat）、固定页窗（NextChat）、整段 DOM 增量/重绘（SillyTavern/VCPChat/Manifold）——渲染实现细节在消息渲染器横向对比，这里只记录用户可观察的工作流。
- **停止生成的视觉状态与执行状态可能不同**：VCPChat 单聊只通知远端、Hermes Agent 前端先本地定稿再请求后端中断（存在中间窗口）、Manifold 的 stop token 不能打断阻塞读取；评估停止能力时需要继续追到请求或任务控制层（执行语义见对话请求与上下文横向对比）。
- **输入区承载了大量 Agent 交互**：DeepChat 的 steer/queue/permission、Jan 的排队与附件、Open WebUI 的工具确认和终端事件，与 AIO/Chatbox/Cherry/Lobe/VCPChat 的附件、知识库、mention、审批共同组成了输入协议。
- **窗口化与搜索存在结构性冲突**：Chatbox/Cherry/LobeHub/DeepChat 通过虚拟或窗口列表控制长会话成本，但 Cherry 的 DOM 搜索以及任何依赖已挂载节点的扩展会漏掉窗口外消息；NextChat 的固定页窗也需要显式移动窗口。
- **UI 调查应记录"呈现投影"**：同一份会话数据可以有多种用户可见投影（分支树图、side-by-side、bubble/panel/immersive 模式），仅记录 schema 无法解释用户实际如何切换、编辑、停止和定位。
- **DeepSeek Harness 的"前端"是浏览器里的第二条 Cordis 插件树**：React 18 + Vite 只是薄壳，每个 UI 能力是 `dsh.client` 插件包，由宿主启动图按需取回；四象限 RPC 中上行是 HTTP POST、下行是每条逻辑流一条 WebSocket；会话事件窗口 → `ConversationNodeAssembler` → 块级不可变流式累积（animation-frame 合并）→ ChatView 按 key 订阅座位；工具调用按工具名键控槽分发；设置表单经 schemastery schema 下发、路径式草稿写回。
- **Risuai 是"单缓冲 + 全局互斥"的极简工作流**：草稿是跨角色共享的组件级单缓冲、不持久化、刷新即失；生成全局串行、无排队与重试，停止即中断并保留半截回复；reroll 是内存快照，分支复制会话才是固化版本的唯一方式；刷新总是回首页，靠持久化的聊天指针重选角色恢复现场。

- **表面所有权会直接改变可观察到的收尾行为**：VCPChat 已让每个聊天 surface 持有自己的 renderer、流消费者和释放动作；路由撤销后，迟到的流事件不再投影到旧视图。该机制约束的是界面生命周期，不能据此推断远端请求已经中止。

## 工作台与导航

| 项目 | 主界面/导航 | 输入与生成中交互 | 关键 UI 取舍 |
| --- | --- | --- | --- |
| AIO Hub | 三栏工作台：Agent/参数、ChatArea、Session；支持 ChatArea/输入框分离成悬浮窗 | CodeMirror/textarea、拖入/粘贴附件、工具审批条；发送按钮可 abort | 当前消息列表是完整 DOM + `content-visibility`，依赖活动路径；历史上曾用 TanStack Virtual，后因动态高度、倒序加载闪烁和滚动定位问题于 2026-04-29 撤回 |
| AstrBot | WebChat 与会话管理页服务于多 IM 平台后台 | 输入可触发命令建议与 Live Mode；真实入站还来自 QQ/Telegram 等平台 | Web UI 只是多平台事件系统的一个入口，不能代表群聊唤醒和平台回复的全部行为 |
| Chatbox | Header + Virtuoso 消息区 + 底部 InputBox；ThreadHistoryDrawer 侧滑 | composer 承接模型/Copilot/知识库/网页浏览；停止直接 cancel 当前 generating 消息 | 虚拟列表和 smooth-follow 体验成熟；独立 SearchDialog 走 Session 数据扫描，不受 DOM 虚拟窗口限制 |
| Cherry Studio | Home/Agent 共用 `MessageListProvider` 契约，Topic 侧栏与消息流分离 | 多模型选择可以并行生成 N 个 assistant；工具审批/异构干预走专用操作条 | 适配器复用能力强，但全局/局部 store 双 parse 让状态同步复杂 |
| DeepChat | renderer 通过 ChatPage 组合消息、pending input lane 与工具交互浮层 | steer、queue、question/permission 是独立输入通道；subagent session 只读；Composer 显示 DeepSeek 原生 web 搜索开关（`supportsSearch/searchExecution` 能力字段，仅官方 deepseek-v4-flash 生效） | 主进程是真相源，UI 通过 typed IPC 和 revision/cursor 维护投影 |
| DeepSeek Harness | 三栏工作台（sidebar \| conversation \| details，CSS grid + 两个拖拽手柄，窄视口自动折叠侧栏）；无会话 Hero 先选工作区、复用或创建 blank 会话；侧栏行点击即切换，Session 常驻后台吃帧、切回即时恢复 | InputBar 输入状态机（plain/adjudicating/claimed/submitting）+ slash/@ 命令裁决；停止按钮 `session.cancel()`，队列 Dock 只读展示、项可编辑/移除/steer | 浏览器内第二条 Cordis 插件树，UI 能力都是按需取回的 `dsh.client` 插件包；组件不 import 框架，数据经 slot 四份额 props 与 uSES 快照到达；ChatView 按 key 订阅座位，流式增量只替换 key 值不重挂 |
| Hermes Agent | Electron 桌面通过 WebSocket 连接无头 Python 后端 | prompt RPC、后端中断请求和前端本地定稿具有不同语义 | stored session id 与 lineage root 的匹配、压缩轮转后的身份迁移直接影响固定、恢复和流式状态 |
| Jan | Thread 页面集中承载列表、输入、队列、分支与错误 banner | 流式中再次发送进入 `QueuedMessageChip`；编辑/删除在流式态禁用 | UI 同时仲裁 AI SDK 状态与文件/SQLite 消息，页面中枢职责较重 |
| LobeHub | Agent Sidebar + Topic 多种分组/全量抽屉；输入编辑器是 Lexical 插件工作台 | slash/mention/文件/草稿/输入历史；发送按钮按权限和 generating 切换 | 权限、运行态、工具流程都在 UI 直接可见；Topic 双击开 tab 与单击导航有定时器语义 |
| Manifold Desktop | WebView2 标签页聊天界面 | 新请求先停止全局旧线程；取消只能在下一次流回调检查 stop token | 多标签共享无会话 id 的广播，正常聊天状态与文件存储未接通 |
| NextChat | 单页 Chat + 会话列表 | stop/retry/delete/pin/copy/TTS；图片和音频直接作为消息内容 | 不是虚拟列表；完整历史仍驻留 session 数组，窗口只限制渲染切片 |
| Open WebUI | Svelte Chat 控制器 + 消息、输入、分享/标签组件 | 支持队列、停止、重新生成、继续生成、工具确认和终端事件 | `Chat.svelte` 集中处理约 25 类 Socket.IO 事件，交互完整但状态组合复杂 |
| SillyTavern | Agent/群组/Topic 侧栏 + 中央消息 DOM + 通知/设置面板 | 发送按钮复用为中止；群聊邀请/多模式调度改变消息流 | 扩展性和可定制性最高，但长聊天没有虚拟化，重绘与旧 DOM 引用风险更明显 |
| VCPChat | 三 tab 左侧栏 + 中央聊天 + 通知侧栏，可调宽度 | textarea + 附件预览；发送/中止同一按钮；Topic 列表渐进渲染、IntersectionObserver 计数 | 视觉模式切换成本低，但消息区仍是整段 DOM；单聊/群聊中断能力不对称；话题条目带"未读 N/未读"文字指示器（自动计数或持久化标记，用户参与即清除），搜索框完整输入"未读话题"可置顶未读话题 |
| VCPToolBox | 不提供聊天主界面；AdminPanel 是运维 SPA，OpenWebUISub 是第三方页面增强脚本 | 不承接会话输入/停止/导航 | 不能与其它聊天应用按 UI 直接排名，属于后端协议与外部前端适配层 |
| OpenCode | 会话列表 + 虚拟化 timeline（Web）；TUI 全屏会话页 | Web 发送/中断/排队/followup dock；TUI 发送、双击 Esc 中断、shell 模式、`@` agent 提及 | 渲染核心独立成 `packages/session-ui` 包被 Web 复用；Web 与 TUI 是两套独立渲染栈，共享服务端事件协议 |
| Risuai | 无路由条件渲染：`App.svelte` 按七种屏幕状态分支，聊天面 = 图标栏 + 四面板侧栏（会话列表/角色配置/DevTool/快捷设置）+ ChatScreen | 发送按钮原位变停止按钮、spinner 按生成阶段分四色；全局串行、无排队，群聊/续写/触发器递归共用同一停止信号；发送前开关在侧栏快捷设置可见、作用域分层 | 会话以角色为单位挂 `chats[]` 与持久化指针 `chatPage`；生成中禁止切换角色；刷新回首页后重选角色即恢复；草稿是组件级单缓冲、跨角色共享、不持久化 |
| Pi | 终端 TUI 全屏会话 + 命令面板、选择器、状态行 | 键盘工作流：发送、中断、shell 模式、bash 执行交互；无鼠标工作流 | 以用户任务抽象，不套用桌面布局标题；流式反馈在状态行与消息区 |

消息呈现（消息如何被看见）一列移入消息渲染器横向对比：本表只记录用户如何进入、组织、控制和操作对话。

## 搜索入口与跳转工作流

数据侧的索引、命中粒度与定位标识见会话与消息管理横向对比，这里只记录用户可见的搜索入口和定位行为：

- **Chatbox**：`SearchDialog` 提供"当前会话"和"全部会话"两个入口，点击结果后切换目标会话并 `scrollToMessage` 定位到具体消息——不受 DOM 虚拟窗口限制。
- **DeepChat**：会话内 Cmd/Ctrl+F 走 `useChatSearch` 在已加载 display messages 上匹配并定位，不触发数据库查询；跨会话 FTS5 命中直接定位到消息并可滚动到目标行。
- **Cherry Studio**：搜索用 `document.createTreeWalker` 遍历已渲染的 DOM 文本节点；虚拟列表窗口外消息不会进入搜索范围——DOM 搜索与虚拟列表组合后的范围限制。
- **LobeHub**：侧栏 `TopicSearchBar`/`AllTopicsDrawer` 提供全量 Topic 搜索入口（后端 BM25 返回 Topic 列表，不直接定位到消息）。
- **Jan**：SearchDialog 展示并导航 Thread（Fzf 懒建索引的会话列表搜索）。
- **AIO Hub**：会话内搜索是前端线性扫描，仅覆盖当前活动路径，无法命中隐藏分支；跨会话搜索只能定位到会话，两套搜索没有衔接。
- **Pi**：搜索在选择器内对 `id+名称+全部消息文本+cwd` 做 token/正则匹配，结果是会话级命中；harness SDK 另存 `createScanningSessionSearch`（异步迭代器分页扫描，未接入 TUI/AgentSession，数据侧见会话与消息管理横向对比）。
- **DeepSeek Harness**：侧栏 WorkspaceBrowser 提供本地过滤 + 宿主全文搜索（`session.search`，250ms 防抖、500 码位截断、结果上限 20 条并提示精化查询），结果粒度是会话/工作区行；命中具体消息并定位的行为本次笔记未确认。
- **Risuai**：只有角色名搜索（桌面角色网格与移动端各一处，按名称过滤）；会话列表与消息内容搜索无 UI 入口，消息定位靠书签跳转与分支回链注释。
- **Open WebUI、Manifold Desktop、NextChat、AstrBot、SillyTavern、VCPChat、OpenCode**：本次笔记未确认用户可见的"命中具体消息并跳转"链路（Open WebUI 后端 `/search` 结果粒度是 Chat；OpenCode 仅会话标题搜索；VCPChat 的"未读话题"/"unread topic"是置顶约定词，非内容搜索）。

## 消息操作、分支导航与呈现投影

- **分支/版本导航入口**：
  - Chatbox：ForkGroup 折叠分支组（`N / M` 位置指示，替代已移除的 ForkNav"◀ 1/2 ▶"，替代回复收进"N 个回复"折叠组）与 ThreadLabel 内联锚点；
  - Jan：`< n/m >` 版本导航与 activeRootId 切换；
  - Cherry Studio：`TopicBranchPanel`（React Flow 画布选分支辅助面板）；
  - AIO Hub：Vue Flow 树图与 `BranchNavigator`；
  - Open WebUI：Overview 消息树图（SvelteFlow 只读画布，点击节点沿 childrenIds 走到叶子并切换分支）；
  - SillyTavern：checkpoint 旗标（Shift+点击新建）与 branch 跳转；
  - Pi：label/分支切换选择器；
  - DeepSeek Harness：无树图式分支导航，分支是消息操作栏动作，仅已完成回合的 transcript 尾可用，传消息 seq 给 `session.fork` 按 turn 分叉。
  - Risuai：分支按钮把当前会话快照复制为 idx+1 会话并追加回链注释，跳转走会话列表与回链；分支树弹窗只读预览、节点点击不导航；
- **消息操作入口**：Chatbox 按角色显示操作栏（编辑/复制/引用/删除/更多），桌面端无右键菜单；SillyTavern 消息 hover 操作栏（复制/编辑/删除/上下移）加 swipe 左右箭头；VCPChat 发送/中止同一按钮；OpenCode 消息操作在 Web hover 菜单与 TUI 快捷键两条路径。
- **消息操作入口（Risuai）**：操作栏分主次两层——复制/翻译/编辑/TTS/删除为主按钮，书签/分支/禁用收进弹出层，窄屏主按钮也收进弹出层；操作按钮带 `button-icon-*` class，供热键按 class 触发。
- **消息操作入口（DeepSeek Harness）**：消息操作栏提供复制（剪贴板 + 1 秒对勾反馈）、分支与按需时钟指标（运行时长/TTFT/tok/s），插槽式扩展位供第三方动作（如 Like/Dislike）挂载；历史是追加型，未找到就地编辑与删除入口，修改以分支表达。
- **reroll/swipe（Risuai）**：左右箭头渲染在每条消息上但动作总是作用于会话尾部；候选存组件内快照栈与模块级分块缓存，切角色清空、刷新即失；首条问候语轮换走持久化的 `fmIndex`，带"第几页/共几页"指示——与候选的不落库形成不对称。
- **呈现投影**：同一份会话数据可以有多种用户可见投影——AIO 的 linear/force-graph、Cherry 的 `TopicBranchPanel` 消息树图、Open WebUI 的 side-by-side/MoA 与 Overview 消息树图、VCPChat 的 bubble/panel/immersive 三种 CSS 投影、Chatbox 和 Jan 的分支版本导航。仅记录 `Session/Topic/Thread` schema 无法解释用户实际如何切换、编辑、停止和定位。

## 停止入口与生成反馈（用户可见部分）

执行语义（abort、任务取消、最终化）在对话请求与上下文横向对比，这里只记录用户可见的停止入口与反馈形态：

- **SillyTavern**：生成中 toast 直接带停止按钮（Action Loader `STOPPABLE` 模式）；`document.body.dataset.generating` 全局状态位驱动 CSS 禁用交互；流式生成中主动隐藏 swipe 按钮。
- **Manifold Desktop**：新请求先停止全局旧线程；取消只能在下一次流回调检查 stop token——按钮存在但停止能力受限。
- **Open WebUI**：停止经 `stopResponse` 按 chat/task 停止，`chat:active=false` 事件驱动前端清空 taskIds 并重载。
- **Chatbox**：生成时发送按钮变为停止按钮（`IconPlayerStopFilled`），点击 cancel 当前 generating 消息并乐观写回。
- **Pi**：TUI 键盘停止（abort），中断后消息以 stopReason 持久化、下次恢复可见。
- **VCPChat**：发送/中止同一按钮；单聊只通知远端，前端没有本地 abort 的完整反馈闭环。
- **Jan**：流式态禁止编辑/删除；AI SDK 与 transport 控制当前生成，`resume:false` 不恢复未完成回合。
- **DeepSeek Harness**：停止按钮 → `session.cancel()`（保留 pending inbox 工作，结算后按 FIFO 恢复；子 agent 会话走 `subagent.interrupt`）；运行中 TurnStatus 显示 "Deep diving..."，15 秒后叠加运行时钟。
- **Risuai**：发送按钮原位变停止按钮；停止经 `abortController.abort()` → fetch signal 取消流，半截回复保留在消息流中；自动续写、群聊顺序生成、触发器重发共用同一 signal，一次停止中断整条递归链；无排队指示器、无重试按钮，错误后自行再发或 reroll。

## 键盘、焦点与无障碍（聊天关键路径）

通用无障碍盘点（弹窗焦点、主题对比等）见 [`../应用界面基础设施/应用界面基础设施横向对比.md`](../应用界面基础设施/应用界面基础设施横向对比.md) 与各项目应用界面基础设施笔记，这里只记录与聊天关键路径直接相关的结论：

- **AIO Hub**：发送/停止按钮只有 `title` 没有 `aria-label`；会话列表项没有 `tabindex`，**纯键盘用户无法切换会话**。
- **Chatbox**：发送/停止按钮完全没有 `aria-label`（最高频交互点反而是缺失的）；`trapFocus={false}` 的四个弹窗（消息编辑/会话设置等）键盘 Tab 可穿透背景（有提交记录的已知取舍）；消息跳转导航 `MessageMinimapRail` 是规范反例（真实 `<button>` + `aria-label`）。
- **Cherry Studio**：消息操作栏（复制/编辑/删除/点赞）无 `aria-label`，可访问名称只靠 Tooltip；composer 可编辑区无 `aria-label`/`role="textbox"`；Topic/Session 列表实现了规范的 roving tabindex + `aria-activedescendant`，优于一般水平。
- **LobeHub**：有多处规范实现（`role="progressbar"`、`aria-live="polite"` 等），但 Topic 行、消息操作栏图标按钮普遍缺 `aria-label`——"点状覆盖，非体系化"。
- **SillyTavern**：`index.html` 全文仅 1 处 `aria-hidden`；245 个"按钮"全是 `<div class="menu_button">`；为此专门写了 `keyboard.js`（MutationObserver + 动态 tabindex + Enter 触发）做键盘可达性补偿，但屏幕阅读器语义几乎空白——**无障碍最薄弱**。
- **VCPChat**：Presentation mode 切换、侧栏 tab、compact navigation 等有基础 ARIA；但 Agent/Topic/消息列表项均无 `aria-label`/`role`，无 focus trap。
- **DeepSeek Harness**：关键路径键盘绑定有静态证据（无会话 Hero 以 Enter/Space 打开工作区选择器、IME 合成保护、组合框菜单 ↑↓/Enter/Esc 且焦点留在 textarea、rail 搜索等 300ms 侧栏动画完成）；焦点顺序、无障碍名称与中文输入法下 Enter 边界未运行验证。
- **Risuai**：document 级 keydown 匹配 `DBState.db.hotkeys` 配置，动作通过点击 class 匹配按钮与鼠标走同一条路径，无修饰键热键在输入框聚焦时失效；侧栏角色/会话项用 `role="button"` + `tabindex="0"` 保证可达，但存在若干用 `svelte-ignore a11y_*` 压制告警的 div 点击控件；主输入框无自动聚焦；读屏命名与焦点顺序未运行验证。

**共同结论**：各项目的无障碍语义都不完整，缺口的性质不同；键盘可达性（Tab/Enter）与屏幕阅读器语义（ARIA）是两件独立的事，SillyTavern 用自研框架解决前者、放弃后者。

## 界面层技术债（有具体代码证据支撑的）

- **Chatbox**：文件拖入输入区没有任何高亮遮罩或视觉反馈（`react-dropzone` 未使用拖拽激活等状态字段）；桌面端会话项没有右键菜单；初始断点判定用 599.95px、后续响应式用 640px，两个数字之间存在窄缝；`newSessionState.webBrowsing` 是死字段。
- **Cherry Studio**："助手回复完成通知"开关可勾选，但全仓库找不到任何发送调用——**是不生效的死开关**。
- **SillyTavern**：swipe（候选回复切换）在移动端是**点按钮，不是划手势**，与功能名字暗示的手势操作不符；"角色正在输入"三点动画 keyframe 存在但未挂到主聊天流。
- **VCPChat**：compact navigation 由 `sidebarAvatarOnly` 字段显式控制，**不是宽度断点自动触发**；表情包选择器是平铺图片网格，无搜索无分类，点击插入原始 `<img>` HTML 标签。
- **LobeHub**：移动端是独立路由树 + 独立构建产物，不是同构响应式；资源管理器的文件拖拽是团队主动放弃 `dnd-kit`、自建原生 HTML5 drag/drop。
- **AIO Hub**：侧栏拖拽宽度由自研 `useResizable` 实现，200–600px 硬编码约束。
- **DeepSeek Harness**：开发期 HMR 链默认 disabled（`cordis.patch.yml` 标注 TODO），改插件需重建 bundle 并重挂纤维，且 HMR 单插件重载会丢 React 状态。
- **Risuai**：reroll 快照栈只按角色清空、不校验与具体会话的对应关系——同角色内切换会话后 reroll 可能把旧候选套到新会话（静态观察，未运行验证）；分支树弹窗画出了全部会话的连接线树，但节点点击只切换预览、不能导航。

## 设计取舍与已确认边界

- **TUI 项目按用户任务组织**：Pi 的命令面板、选择器、状态行和键盘工作流不套用桌面布局标题；OpenCode 的 Web/TUI 是两套独立渲染栈、共享服务端事件协议。
- **界面不拥有全部状态**：DeepChat 的 UI 只是主进程真相源的投影；Hermes Agent 桌面端是带版本仲裁的缓存；Manifold Desktop 的 UI 状态甚至没有回写会话。
- **通用界面盘点不在本对比范围**：弹窗/Toast/主题/动画/图片预览等跨项目盘点在 [`../应用界面基础设施/应用界面基础设施横向对比.md`](../应用界面基础设施/应用界面基础设施横向对比.md)，本对比只记录与聊天主链的交点。
- **类目边界**：消息如何被绘制（虚拟化、滚动、消息壳）在消息渲染器横向对比；停止/重试的真实执行在对话请求与上下文横向对比；搜索索引与命中数据在会话与消息管理横向对比。
- **Risuai 的 UI 状态事实源是内存响应式数据而非持久层**：`DBState.db` 内存响应式数据 + 各类 store；跨窗口不做 UI 状态同步——同源多标签页用 BroadcastChannel 检测保存冲突后整页重载（进行中的生成与草稿一并丢失），WebRTC 房间只同步聊天数据并在生成前做互斥检查；聊天指针等关键现场随角色数据落库，刷新后重选角色即恢复。

### DeepSeek Harness

Web Chat UI 是运行在浏览器里的第二条 Cordis 插件树：宿主进程一条 cordis 树、浏览器一条 client 树，每个 UI 能力是 `dsh.client` 插件包，由启动图按需取回，React 18 + Vite 只是薄壳。连接走四象限 RPC（上行 HTTP POST、下行双 WebSocket），重连即重建、无 resume 游标。会话事件先进事件窗口，由装配器折叠成业务节点，块级不可变累积经 animation-frame 合并后按 key 订阅座位、行级更新；工具调用按工具名键控槽分发，未注册落 `GenericToolCard`；设置表单经 schemastery schema 下发、路径式草稿写回。代价是自研快照批处理与 slot 契约接线；未运行 `dsh web`，视觉效果与键盘可用性未实测。

## 未验证事项

- 键盘可达性与屏幕阅读器实际体验大多只有静态证据（各项目笔记均标注 `STATIC_ONLY`）。
- SillyTavern 长聊天下 swipe 高频操作与整段重绘的性能影响未实测。
- LobeHub 的 `@lobehub/ui` 内部焦点管理未下钻。
- DeepSeek Harness 未运行 `dsh web`：视觉效果、动画、CSS 主题、焦点顺序、键盘可用性、IME 行为、滚动与流式性能均未实测（笔记 §14）。
- Risuai 未运行应用：视觉效果、动画、响应式断点、键盘焦点顺序、读屏命名与移动端手势未实测；reroll 快照与具体会话的对应关系为静态观察；多标签页保存冲突整页重载与 WebRTC 房间端到端同步未实测。
