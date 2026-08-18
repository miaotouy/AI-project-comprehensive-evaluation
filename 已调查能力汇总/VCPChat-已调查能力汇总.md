# VCPChat 已调查能力汇总

> 汇总对象：`VCPChat`（远端仓库 `https://github.com/lioensky/VCPChat`）
>
> 汇总更新日期：2026-08-18
>
> 依据：Agent工具、Agent角色、Chat、Chat UI、LLM渠道管理、仓库分布、会话与消息管理、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时十二个类目的单项目笔记；除 LLM渠道管理外均指向代码快照 `fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支 `main`）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态并链接来源；异常项（声明不符/暂缓/入口确认未闭合/未覆盖）集中到末尾"已知边界与待验证事项"小节
>
> 汇总范围：本次覆盖上述十二类目笔记的已调查结论；未做新的源码调查，未做跨项目横向比较
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

VCPChat 是 VCPToolBox 的官方 Electron 桌面前端，也是一个围绕 VCP 后端协议建立的"AI 原生桌面运行时"：聊天、桌面挂件、记忆工作台、人类工具面、移动同步和插件系统共享同一套 `AppData/` 文件事实源，由前端私有标记协议与后端工具链驱动。聊天以 Agent 或 AgentGroup 为一级会话主体、Topic 为二级会话单位；模型推理与流式输出由外部 VCP 服务器承担，客户端通过 HTTP 流式读取。除聊天主链外，项目还合仓了 Rust 音频引擎、Rust 历史索引服务（VCP-CDS）、Rust 桌面感知 sidecar、独立的分布式节点子进程和多个旁路子窗口应用。独特功能密度高：十六项候选中十五张能力卡达到 `主链确认`，能力覆盖与状态计数见下一节。

## 完成度速览

| 证据状态 | 条目数 | 说明 |
| --- | ---: | --- |
| 主链确认 | 23 项 | 16 张独特能力卡（含 DeepMemo 2A、卡 10 的机制与 Loom 主体）+ 7 项旁路产品面（双语朗读、3D 骰子、论坛、RAG Observer、语音聊天、笔记、翻译） |
| 入口确认 | 6 项 | 卡 10 两个渲染器插件本体、任务台、VchatManager、VCPLog 日志中心、分布式多模态文件追踪的节点侧 |
| 归并已有类目 | 5 项 | 日记渲染、群聊发言模式、Canvas 协作、转发入口、VCPDesktop 渲染与流式 |
| 声明不符 | 11 项 | README 声明核对（8 项 + 群文件/ST 角色卡/VCPLog WS）；能力卡局部边界另计 2 项（气泡评论未实现、工作流编辑器 README 陈旧）；另有骨架/未接线 4 项（主题系统、lyricFetcher/weatherService/modelUsageTracker） |
| 暂缓 | 3 项 | 分布式完整闭环、跨端记忆本体、ST 角色卡归因；另有剪贴板模型触发 1 项未确认 |

主链确认条目约占功能能力条目的四成以上，是本次汇总的主体；异常项（声明不符/暂缓/骨架）合计约占三成，不混入能力正文，集中列于末尾"已知边界与待验证事项"小节。

本汇总所有"主链确认/静态源码确认"均基于对当前代码快照的源码贯通，在编译型桌面应用或完整本地主链中视为完成交付态；"未运行验证"仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。

## 功能能力摘要

### 角色与上下文

- **Agent 角色配置（以文件夹为单位）**：每个 Agent 对应用户数据目录下一个 `agentId` 命名的子目录，`config.json` 存系统提示词、模型、温度、上下文/输出上限、流式开关与话题列表，`regex_rules.json` 存正则规则，头像图片同目录；`{{AgentName}}` 是唯一已确认的内置宏。边界：无内置角色预设、无批量导入，工具调用策略不能在 Agent 内部配置，由 VCP 分布式服务器在全局或后端决定。见 [Agent角色配置调查笔记](../Agent角色/VCPChat-Agent角色配置调查笔记.md)。
- **三模式提示词管理器**：独立于 systemPrompt 字段，由 `promptMode` 决定 original、modular（积木块，扁平 blocks 带 disabled 与 variants）、preset（目录单选 `.md/.txt` 预设）三种模式；是全部调查项目中最接近 AIO Hub 消息组的块机制，但没有组级总开关。见 [Agent角色配置调查笔记](../Agent角色/VCPChat-Agent角色配置调查笔记.md)。
- **发送时配置引用与历史快照语义**：发送用内存缓存引用、刷新点仅三处；重新生成总是重读最新配置并重新提取附件文本；消息不保存模型/参数元数据，`__vcpchatTimestampMeta` 只进请求 payload 不落盘；模型参数留空存 `null` 并在发送前省略。见 [Agent角色配置调查笔记](../Agent角色/VCPChat-Agent角色配置调查笔记.md) 与 [Chat调查笔记](../Chat/VCPChat-Chat调查笔记.md)。
- **请求上下文扩展与脱敏**：发送请求携带 `requestContext` 扩展（请求 id、agent/topic 标识、所有者类型、群聊标记）；消息原始文本整体进入下一轮请求并按深度脱敏（contextSanitizer），思维链默认剥离；附件以 `attachments` 数组挂 user 消息。见 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 与 [Chat调查笔记](../Chat/VCPChat-Chat调查笔记.md)。

### 会话与消息

- **两级会话单位与事实源**：Agent/群组配置里的 `topics[]` 存元数据（id/name/createdAt/locked/unread/creatorSource），消息内容全部落在 `UserData/<agentId|groupId>/topics/<topicId>/history.json`（裸 JSON 数组，整份覆盖写，无原子写保护、无 schema 版本）；群聊消息单一真源在主进程内存 `groupHistory` + 各阶段写盘。见 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md) 与 [Chat调查笔记](../Chat/VCPChat-Chat调查笔记.md)。
- **消息对象字段**：通用字段 `role/content/timestamp/id`；user 消息带 `name/attachments`，assistant 消息带 `name/avatarUrl/avatarColor/isThinking/finishReason`，群聊 assistant 额外带 `agentId/model/modelSource/groupId/topicId/isGroupMessage/interrupted`。见 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)。
- **Topic 打开优先级与现场恢复**：打开优先级为 Flowlock 锁定 Topic > localStorage 记忆 Topic > 最新创建（数组首位）；现场恢复靠 `settings.json` 的 lastOpenItemId/lastOpenTopicId + localStorage。边界：默认话题存在 `"default"` 与 `"topic_<timestamp>"` 两种 id 并存的历史遗留不一致。见 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md) 与 [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)。
- **未读计数、搜索与排序**：自动未读只在"历史无用户消息"时按 assistant 条数计数，用户参与即归零；持久化标记带 `unreadSource` 区分来源（manual 保留、插件旧标记清除）；"未读话题"约定词触发置顶；话题搜索是前端标题过滤 + 后端逐文件 `includes` 的并集；列表渐进渲染 + IntersectionObserver 延迟计数 + SortableJS 拖放排序。边界：内容检索只匹配字符串型 content，多模态数组匹配不到。见 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md) 与 [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)。
- **话题自动总结**：流式回合收尾后自动为默认名话题请求 AI 总结并写回 `topics[]` 元数据。边界：单聊路径无超时保护、群聊路径有明确 20 秒超时，健壮性不对等（细节见末尾小节）。见 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)。
- **群聊串行调度与三种发言模式**（`归并已有类目`）：`Groupmodules/modes/` 策略注册表，sequential 全员轮发、naturerandom 按 @提及/tag 权重/保底发言者、invite_only 仅按钮驱动；单次调用内严格串行 await，杜绝 chunk 交错。边界：多次调度之间无文件锁（细节见末尾小节）。见 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 8.1 节。
- **消息操作、重新生成与分支**：消息右键承接复制、编辑、重新生成、创建分支、转发、朗读、阅读模式、删除；重新生成是截断重建（覆盖语义），分支复制前缀历史到新话题。边界：编辑/删除/分支在数据层的表示与持久化语义未核实（见末尾小节）。见 [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)、[对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 与 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)。

### 生成与创作

- **消息渲染链**：以原始消息字符串为事实源，Markdown（Marked）位于中间层；在 Markdown 解析前识别 VCP 私有语法（工具请求/结果、思维链、LaTeX、代码围栏、日记、Desktop Push、角色分界、AI 按钮），用保护、转换、恢复三阶段的有序占位映射隔离多层协议；DOM 后处理补 KaTeX、Highlight.js、Mermaid、预览与交互按钮；历史重渲染始终从 `history.json` 原始文本派生。见 [消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md)。
- **流式渲染引擎**：稳定前缀按块固化并缓存源码+HTML，不稳定尾部逐帧重解析 + morphdom 差量合并；全局 30fps 合帧、预缓冲队列上限 1000 chunks、pendingFinalizationEvents 防 finalize 抢跑；最终化统一收口并防抖 1 秒落盘（群聊消息不在渲染进程落盘）。见 [消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 与 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)。
- **富消息运行时与执行环境**：气泡内 iframe 提供 HTML 预览（srcdoc），独立阅读窗口可在主 DOM 执行模型内联脚本（CDN 替换为本地 vendor），Python 双模式（Pyodide WASM 沙箱 / 本机 `python -u` 进程），桌面挂件用 Shadow DOM + IIFE 沙箱 + 能力桥（widgetFS/musicAPI/`__vcpProxyFetch`/`__vcpProxyPost`）；消息离屏由 visibilityOptimizer 暂停动画/媒体并缓存高度。边界：气泡 iframe 未设 sandbox 属性、本机 Python 进程无沙箱/超时/资源限制（静态确认的架构事实，见末尾小节）。见 [消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。
- **生成式输出对象模型与等级判定**：模型产出作为消息正文内的原始文本流，经私有标记协议表达为结构化卡片（工具结果卡、思维链卡、日记卡、桌面推送占位卡）；可辨识对象有四类（消息、桌面挂件、Canvas 文件、Scriptorium 文档工程）；能力等级判定为 G3（可执行 Artifact）为主、G4（可编辑工作区）部分成立。边界：无独立 Artifact 对象模型与对象注册表，聊天消息/桌面挂件/Canvas 文件无版本语义，唯一例外是 Scriptorium 文档工程。见 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。
- **Canvas 协同编辑**（`归并已有类目`）：AI 经 FileOperator 工具写 `AppData/Canvas/`，chokidar 监听外部变更，CodeMirror MergeView 行级 diff + 接受/拒绝，可点击回滚内存内快照。边界：编辑历史不落盘、无版本号，无网络级多人协同协议。见 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 第 6 节。
- **AI 生成按钮与交互回发**：消息内任意 `<button>` 被宿主接管，点击回发 `[[点击按钮:文本]]` 触发新一轮对话；工具结果卡大内容二级截断 + 懒加载展开；阅读窗口支持编辑全文、分享到笔记、截图导出。见 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 与 [消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md)。
- **阅读窗口、图片查看器与导出**：独立文本查看器窗口（编辑/分享/截图）；图片查看器是独立 Electron 子窗口，支持缩放 0.05×–32×、绘图工具、OCR（Tesseract.js 懒加载）、GIF 原生复制。见 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 与 [应用界面基础设施调查笔记](../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md)。

### Agent 运行时与外部协作

- **VCPDistributedServer 分布式节点**（默认开启，`enableDistributedServer: true`）：随主进程启动，以 WebSocket 分布式节点身份连接主 VCPToolBox 服务器，把本机 `VCPDistributedServer/Plugin/*` 插件目录（HEAD 30 个目录）的能力注册为工具；收到 `execute_tool` 后在本机 Node/Python 子进程执行；renderer 型插件跳过工具注册改走前端插件加载器。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **本机能力清单**：PowerShell/PTY Shell 执行、FileOperator 文件读写（受 ALLOWED_DIRECTORIES 约束）、ScreenPilot 截图/OCR/UI 自动化、MediaShot 媒体截取、MusicController 点歌控制、SuperDice 骰子、Flowlock 控制、DesktopRemote 桌面远程、`internal_request_file` 本机文件读回 Base64、DistImageServer 图床/下载服务、剪贴板读取（UI 触发），均由服务端规则审批。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **DESKTOP_PUSH 旁路协议**（`主链确认`，既有）：模型在流式输出中吐出 `<<<[DESKTOP_PUSH]>>>...<<<[DESKTOP_PUSH_END]>>>` 包裹的 HTML/CSS/JS，renderer 侧直接拦截调用 `electronAPI.desktopPush()` 创建/写入桌面挂件，不经过 VCPToolBox 审批协议，唯一前置校验是前缀白名单；挂件收藏、持久化与资源治理见独特能力卡 3。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md) 与 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- **审批终端与自动允许规则**：`tool_approval_request` 卡片永不自动消失，用户可允许/拒绝并附理由；自动允许规则支持 contain/exact/regex 三种匹配，明文存 `settings.json`。边界：匹配无权限分级、无 deny 优先、无高危工具强制人工审批的例外（静态确认的机制事实）。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **VCPLog 通道鉴权模型**：连接 URL 内 `VCP_Key` 一次性握手后，同一条 WebSocket 上的消息无消息级鉴权/签名，审批响应原样回传；`/plugin/callback` 绑定 `0.0.0.0` 且无鉴权。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **admin_api 管理面**：HTTP Basic Auth，凭据明文存 `forum.config.json`；admin 面板可改写服务端 Agent Assistant / Task Assistant 配置（新增/删除委托 Agent、系统提示词、定时任务）。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **无客户端 VCP 文本块分发**：聊天流内的 `<<<[TOOL_REQUEST]>>>`/`tool_calls` 不在客户端解析执行，由服务端（VCPToolBox）解析，客户端只展示；唯一的本地解析+分发例外是 DESKTOP_PUSH 与 Flowlock 控制行。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。

### 渠道与调度

- **全局单 VCP 网关（非多 Provider）**：`settings.json` 只有一套 `vcpServerUrl + vcpApiKey`，Agent 只保存裸 `model` ID，模型映射到哪个上游 Provider 由 VCP 服务端决定；切换网关靠改全局 URL/Key。见 [LLM渠道管理调查笔记](../LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md)。
- **请求协议与认证**：请求体遵循 OpenAI Chat Completions 风格并附加 `requestId`、`contextTokenLimit` 等 VCP 扩展字段；URL 规范到 `/v1/chat/completions`，开启工具注入后改走 `/v1/chatvcp/completions`；认证固定 `Authorization: Bearer <key>`；模型目录来自同一网关 origin 的 `/v1/models`，只缓存在主进程内存。见 [LLM渠道管理调查笔记](../LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md)。
- **请求行为与重试语义**：普通聊天、话题摘要和 widget 调用均为单次 HTTP 请求，行为确定、无隐式重试；Flowlock 最多 3 次"重试"是失败后定时触发下一轮续写，不是传输层重试；`modules/vcpClient.js` 实现了 300 秒超时中断但从未被任何模块 require，是未接入的死代码。见 [LLM渠道管理调查笔记](../LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md) 与 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)。
- **凭据存储与备份**：`settings.json` 直接明文保存 VCP Key；原子保存保证写入完整性但不提供保密性，每日备份与一键 ZIP 均携带明文 Key。见 [LLM渠道管理调查笔记](../LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md)。
- **中断能力（单聊与群聊）**：单聊与群聊都提供"中止回复"按钮并发送远端 `/v1/interrupt` 信号；群聊另有本地 AbortController + 60 秒超时，单聊则无本地 abort、无客户端超时，是否停止依赖远端配合（可靠性边界，见末尾小节）。见 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 与 [Chat调查笔记](../Chat/VCPChat-Chat调查笔记.md)。
- **管理入口边界**：客户端不提供 Provider 管理 CLI/TUI/浏览器 Web 前端或 HTTP 管理 API；可操作对象是全局网关设置、Agent 配置或备份文件。见 [LLM渠道管理调查笔记](../LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md)。

### 独特与差异化能力

以下保留 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 的能力卡标题与证据状态（该笔记对十六项候选逐一走读源码主链，证据口径见完成度速览）：

- **能力卡 1：高级回复（VCPChatTarven）三类注入系统** — `主链确认`：类 SillyTavern 的规则注入，规则存 `AppData/VCPChatTarven.json`，system_suffix/user_suffix/context_inject 三类注入覆盖单聊与群聊全部发言路径，用户消息尾部注入不写入历史；Agent 角色笔记 §4 的 Tavern Rules（`getActiveRulesForScope`）与之一致。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent角色配置调查笔记](../Agent角色/VCPChat-Agent角色配置调查笔记.md)。
- **能力卡 2：Memo 神经云图与日记工作台** — `主链确认`：日记文件由后端 `admin_api/dailynotes` 管理，前端提供文件夹分类、语义联想云图（Canvas 力导向图）、批量编辑、多日记引用工作台与 Agent 代笔（经 `/v1/human/tool` 调 DailyNote 工具）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- **能力卡 2A：DeepMemo 2.0 中央会话回忆适配器（主动历史 RAG）** — `主链确认`：插件是常驻薄适配器，只消费 VCP-CDS 的 `searchMemories()`，按字符预算筛选并格式化回注当前工具结果；可选外部 Rerank，中央服务失败按配置回退旧链路。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **能力卡 3：VCPDesktop 流式推送与持久挂件** — `主链确认`（既有，已补）：`<<<[DESKTOP_PUSH]>>>` 流式拦截创建挂件，收藏后按目录持久化于 `AppData/DesktopWidgets/`，带性能打点、可见性冻结与定时器/监听器清理等资源治理。边界：运行状态不持久，恢复时重新执行脚本。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)、[Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。
- **能力卡 4：FlowLock 主动连续工作** — `主链确认`（既有，已补）：模型输出 `[[Flowlock::...]]` 控制协议，前端状态机驱动后台心跳续写，支持多 Agent 并发 Session、跨 Topic 原子交接（CreateFlowlockTopic + claimPendingFlowlockTopic）与 generation 防复活；心跳延迟钳制 1–86400 秒，续写失败最多重试三次。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **能力卡 5：VCP 人类工具箱（人类工具面）与插件 manifest → 表单转译** — `主链确认`：独立 Electron 应用把 VCP 插件 manifest 自动转译为表单化 GUI，执行经主进程代理到 `/v1/human/tool`；插件管理面板支持从后端导入并解析参数 schema。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- **能力卡 6：工作流编辑器（节点编排与执行引擎）** — `主链确认`（静态）：jsPlumb 节点画布 + 分层拓扑执行引擎，插件节点按 `<<<[TOOL_REQUEST]>>>` 实际调用后端，支持环检测、同层并发与 maxConcurrency 限流。README 自述"执行管线为空壳"与当前代码不一致，以代码为准（细节见末尾小节）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- **能力卡 7：ComfyGen 专用创作配置面板** — `主链确认`（配置管理链）：HumanToolBox 内嵌 ComfyUI 配置抽屉，管理连接、工作流模板（导入/转换/校验）、模型与 LoRA 参数，写回后端插件配置。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- **能力卡 8：Agent 正则系统（四类作用点）** — `主链确认`：`stripRegexes` 规则带作用域（渲染/上下文）、角色、min/max 深度，GUI 编辑并兼容导入 SillyTavern 正则脚本。README 声称的"content 数组正则"未定位到实现（见末尾小节）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent角色配置调查笔记](../Agent角色/VCPChat-Agent角色配置调查笔记.md)。
- **能力卡 9：跨聊天消息转发与转发附言** — `主链确认`：右键转发 → 目标选择（Agent/群组）→ 带来源标识与可选附言构造新消息 → 走标准发送链，附件一并携带。README 声称的独立"气泡评论"未找到实现（见末尾小节）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)。
- **能力卡 10：前端插件机制与 LoomAPP 运行时** — `主链确认`（机制与 Loom）/ `入口确认`（两个渲染器插件本体）：`manifest.frontend` 声明插件样式/脚本，主进程扫描后注入主窗口；现有 VChatDynamicWallpaper、VChatAutoTTS 两个渲染器插件；Loom 是 Agent 可创建、管理、注入代码的隔离 WebApp 运行时（WebContentsView 托管），b6ffa22 后升级为 v1.4.0 + VCP Agent WebCore（页面快照/图片/动作执行/串行指令/WebHID-USB-Serial-Bluetooth 设备管理）。两个渲染器插件本体行为仅确认注册与加载机制（见末尾小节）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **能力卡 11：VCPMobileSync 跨端双向增量同步** — `主链确认`：三阶段协议（Reconcile → Double-Hash Merkle Diff → NDJSON 流式），冲突按最新时间戳胜出，墓碑拦截防回流；中央索引模式由 VCP-CDS 承接。边界：同步范围不含记忆库，附件表存在但"实际上不能同步"。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **能力卡 12：Agent 自主管理 Topic（TopicSponsor）** — `主链确认`：分布式插件直接读写 `AppData/Agents|UserData` 创建话题、回复话题、检查所有权/未读，与 FlowLock 的 CreateFlowlockTopic 交接构成闭环；跨 Agent 回复是仅 VCP 系出现的拓扑。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **能力卡 13：VCP Hi-Fi 音频引擎与音乐播放器** — `主链确认`：自研 Rust 解码/DSP/WASAPI 独占输出引擎（Symphonia 解码、FIR EQ 真实卷积、EBU R128 响度、SoX VHQ 重采样、无缝隙切歌、WebDAV 曲库）+ Agent 点歌工具（MusicController）+ 桌面音乐挂件；Agent 点歌时得到曲目元数据注入。README 多项 Hi-Fi 声明不符（DSD 硬解码、AI 歌词创作、音乐实时听音，见末尾小节）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- **能力卡 14：划词小助手（Rust 桌面感知引擎）** — `主链确认`：Rust sidecar 经 Windows UIA/macOS/Linux 捕获系统级划选文本，悬浮动作条（翻译/总结/解释/搜索/配图）内用独立对话窗口处理并回话，会话保存为真实 Agent 话题。README 声称的"全域右键呼出"与"文件夹工作区模式"未实现（见末尾小节）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- **能力卡 15：Scriptorium 共笔文坊** — `主链确认`（b6ffa22 → fb66a52 范围新增）：本地富文档/演示创作空间（VDOCX/VPPTX 工程、ZIP 容器 + document.json + SHA-256 内容寻址资源），人类直接编辑渲染版式，Agent 经 ScriptoriumCollaborator direct 插件以"可审阅 PR"（文脉刻点 + 审批回执 + 修订冲突保护）协作编辑源码；这是聊天侧之外第一套带独立对象模型、版本与冲突语义的协作面。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)、[Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。

**归并已有类目项**（只记归并去向，不重复展开）：

- VCP 日记渲染和认知可见性 — `归并已有类目`：协议块渲染已由消息渲染器笔记覆盖，对象管理（Memo 窗口）由能力卡 2 承接。
- Agent 群聊三种发言模式 — `归并已有类目`：由对话请求与上下文笔记 8.1 主链确认。
- Canvas 协作 — `归并已有类目`：由生成式输出与运行时笔记第 6 节覆盖。
- 跨聊天消息转发入口 — `归并已有类目`：入口由 ChatUI 笔记第 6 节记录，内容链并入能力卡 9。
- VCPDesktop 渲染与流式 — `归并已有类目`：渲染器侧由运行时笔记覆盖，持久化与资源治理并入能力卡 3。

**旁路产品面（主链确认）**：双语混合朗读引擎、3D 物理骰子 VCPSuperDice、VCP Forum 论坛客户端、RAG Observer 信息流监听、语音聊天（Puppeteer 方案）、笔记系统与迷你便签、翻译窗口，均见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 补查节；其余旁路模块（任务台、VchatManager、VCPLog 日志中心、主题系统、lyricFetcher/weatherService/modelUsageTracker）状态见末尾小节。

## 工程与基础设施摘要

- **仓库分布与代码组织**：VCPChat 是 Electron 主应用 + 众多按功能命名的前端目录 + 多个 Rust 本地服务 + VCP 附属服务/工具合仓的复合仓库，一级目录很多但未形成统一 workspace。HEAD 894 个 Git 跟踪文件，自有源码约 33.5 万行（剔除 vendor/测试/文档后约 32.6 万行，JS 49.6%、JSON 24.3%、CSS 12.8%、Rust 7.2%）；`vendor` 是最大单一区域，必须与自有代码分开看。b6ffa22 → fb66a52（101 个提交）期间新增 ScriptoriumModules（约 2.5 万行 + 6.5 万行诊断 JSON）、modules/loom/webcore（VCP Agent WebCore 约 5,075 行）、tests/ 下 15 个新测试文件。测试树显著扩大但只覆盖 frontend-plugins/loom/deepmemo/mobile-sync 等适配层。Electron builder 声明三平台目标，但 README 与部分工具具有 Windows 专属行为。见 [仓库分布调查笔记](../仓库分布/VCPChat-仓库分布调查笔记.md)。
- **应用界面基础设施**：不依赖第三方 UI 组件库；通用弹窗用 HTML template 懒加载克隆到 modal-container，确认框提供 Promise 接口，头像裁剪为 Canvas 实现；通知分浮动 Toast（默认 7 秒，tool_approval_request 永不自动消失）与持久侧栏双通道，无系统桌面通知；主题切换是覆写整份 `themes.css` + 整窗口重载，不是运行时 token 热替换；图片预览是独立子窗口（缩放/绘图/OCR/GIF 原生复制）；无障碍处于初步阶段（核心控件有基础 ARIA，消息/Agent/Topic 列表无语义标注，通用 Modal 无 focus trap）。见 [应用界面基础设施调查笔记](../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md)。
- **桌面集成与多窗口**：主窗口三栏布局（sidebar/chat/notifications），非路由跳转；系统托盘（隐藏到托盘、macOS 特判）、语音聊天独立子窗口、主题选择器独立无框子窗口、图片查看器、Memo 工作台、便签（Super+Alt+Z 全局快捷键）、Canvas 协同窗口、桌面透明置底画布窗口、Scriptorium 文坊窗口，以及 VCPDistributedServer/VCP-CDS/assistant_core_server/rust_audio_engine 等多个附属进程。见 [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)、[应用界面基础设施调查笔记](../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。

## 已知边界与待验证事项

### 声明不符

以下为来源笔记逐项核对 README 声明与当前代码后确认未实现或与代码不符的项，全部留在本小节：

- 群文件、共享工作区与群内协同编辑：全仓库 grep `群文件/GroupFiles/groupFiles/group-files` 零命中；群聊"文件共享"实为消息级附件，协同编辑仅存在于单用户 Canvas 双窗口场景。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- ST 预设、角色卡、世界书与可视化注入：VCPChat 前端无 ST 角色卡/世界书格式支持，唯一确认的 ST 兼容入口是正则脚本导入；相关能力在外部仓库，暂缓归因。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 音频引擎相关（能力卡 13）：README 声称的 DSD 256bit 硬解码（引擎 grep `dsd|dsf` 零命中、Symphonia 无 DSD 支持）、"AI 歌词创作（听歌识曲生成 .lrc）"（歌词仅网易云单源拉取）、"音乐实时被 agent 听到"（实际是曲目元数据注入，无音频流/频谱上传）均不成立。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- TTS"流式剪枝算法 600% 加速"：`SovitsTest/GSVI.py`、`my_infer.py` 仅为 OpenAI 兼容 HTTP 封装，无剪枝算法代码；双语混合朗读为真，加速数字不成立。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 主题系统"自然语言主题生成器"：grep `主题管理/themeGenerator/ThemeAgent` 零命中，仅手动 CSS 主题选择器可用。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 骰子"十多种主题"与"物理施法"：`assets/dice-box/themes/` 仅 default 一个主题，插件参数仅 notation/themecolor，无打滑/黏着/磁铁施法入口。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 划词小助手（能力卡 14）："全域右键呼出"实际只跟踪左键划选（windows_event_source.rs:33），"文件夹工作区模式"grep 零命中。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 笔记"Obsidian 类云端同步"与"分享到 AI 知识库"：实际为网络目录挂载 + 扫描缓存，无同步协议，知识库分享未找到代码。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- VCPLog"通过 WebSocket 连接"：日志中心为 HTTP 轮询（`log.js:219-231`），WS 连接实际属于 RAG Observer。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 独立"气泡评论"：README 声称的评论附加在原始消息下方未找到独立实现，实际只有转发对话框内的"附加评论"字段（能力卡 9 边界）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 工作流编辑器（能力卡 6）：README §8 自述"执行管线为空壳、不建议在生产中依赖"，当前代码已实现完整执行链，以可执行路径为准，README 属陈旧说明。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 骨架/未接线旁路模块：主题系统（"主题生成器"未接线，选择器主链完整）、lyricFetcher（歌词网易云单源）、weatherService（后端 `admin_api/weather` 卡片）、modelUsageTracker（`model_usage_stats.json`），均为常规小工具，不提案。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。

### 暂缓与外部依赖

- 分布式多模态文件追踪与跨模态转译：节点侧 `internal_request_file` 拉取链为 `入口确认`；"全 URL 超栈追踪"与"高阶模型对低阶模型能力转译"的主服务器逻辑在 VCPToolBox，本仓库无实现，完整闭环 `暂缓`。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md) 与 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 跨端记忆：README"跨端记忆"描述以 VCP 后端为中心的统一记忆库，VCPMobileSync 同步范围明确不含记忆；记忆同步 `暂缓`（外部后端），消息/元数据同步 `主链确认`。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- ST 角色卡/世界书归因：能力在外部仓库（VCPToolBox 管理面板存在 VcptavernEditor），暂缓归因。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 剪贴板读取：渲染层 UI 可触发主进程 clipboard 读取，模型能否主动触发此路径 `未确认`。见 [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)。
- Memo 云图与日记工作台的后端依赖：后端 `admin_api/dailynotes` 与 `/v1/human/tool` 属于 VCPToolBox；ComfyGen 依赖本地 ComfyUI 服务与后端插件；音频引擎 WebDAV 曲库依赖用户自备服务器；DeepMemo 中央检索依赖 VCP-CDS 正常运行。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。

### 未覆盖类目与未核实语义

- 数据层语义缺口：分支数据模型（树/指针/复制未核实）、消息编辑/重试/续写的数据变更语义、Topic 删除与恢复、导入导出与跨版本迁移均未在原调查中核实。见 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)。
- 请求层未核实：单聊上下文拼装顺序、附件如何进入请求体、重试/续写的请求重建语义（从哪个节点选起始上下文）未核实。见 [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)。
- 旁路机制未核实：TopicSponsor 创建普通话题后侧栏的即时刷新机制（前端重读 config 而非订阅）、草稿保存粒度、多窗口聊天状态同步、切换会话/退出时任务收尾行为。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md) 与 [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)。
- Agent 正则的"content 数组正则"：README 声称的作用点未定位到实现，`applyFrontendRegexRules` 与上下文路径均只处理字符串（能力卡 8 边界）。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。
- 前端插件本体（能力卡 10）：VChatDynamicWallpaper、VChatAutoTTS 两个渲染器插件仅确认注册与加载机制，插件本体 UI 行为与开关界面未运行验证。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)。

### 共性未验证

- 全部调查结论均为静态源码分析，未运行应用、未发起真实模型请求；运行行为未验证的项包括：流式事件时序与中断恢复、桌面挂件实际渲染与动画冻结效果、移动同步握手与吞吐、音频引擎 WASAPI 独占/DSP 听感/gapless 切歌、划词助手 UIA 选区读取与三平台行为、ComfyUI 连接与模板转换、LoomAPP 运行与隔离、Pyodide 加载与包安装、Canvas 外部变更 diff 交互、CSP 与 preload 组合下模型脚本的实际可达面、气泡内 iframe 无 sandbox 属性与本机 Python 无沙箱的实际安全影响。见 [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。
- 已确认的可靠性风险（静态证据，未实际触发验证）：`history.json` 裸数组整份覆盖写、无原子写（进程崩溃可能截断）；群聊多次调度之间无文件锁（并发覆盖写丢消息风险）；单聊中断无本地 abort/无客户端超时；话题自动总结单聊无超时保护；话题内容搜索对多模态数组有盲点。见 [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 与 [Chat调查笔记](../Chat/VCPChat-Chat调查笔记.md)。
- 测试覆盖现状：`tests/` 顶层 7 个文件覆盖前端插件、Loom 控制器/适配器/管理器、DeepMemo 与移动同步适配器；另有 `tests/重构中禁用脚本/` 子目录 12 个 Scriptorium 测试/冒烟脚本（目录名自述"重构中禁用"，未纳入运行）；未找到针对聊天渲染管线、工具结果解析、桌面推送、Canvas diff、历史保存恢复、iframe 预览的测试；Flowlock 等核心模块无自动化测试覆盖。见 [仓库分布调查笔记](../仓库分布/VCPChat-仓库分布调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)。
- 来源笔记的调查对象路径此前存在标注差异（`E:\works\GitStudyNotes\VCPChat` 与 `E:\works\git\VCPChat`），已统一为远端链接 `https://github.com/lioensky/VCPChat`；全部十二份来源笔记均存在且结论摘要可识别，无缺失。
- 特色贡献统计建议（见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md) 相关口径）：主贡献候选为高级回复、Memo 工作台、VCPDesktop 持久挂件、FlowLock、人类工具箱、工作流编辑器、Agent 正则系统、VCPMobileSync、LoomAPP 运行时、音频引擎、划词小助手、Scriptorium 文坊；辅助贡献为跨聊天转发、前端插件机制、双语混合朗读、3D 骰子、RAG Observer。

## 来源笔记索引

- [Agent工具调查笔记](../Agent工具/VCPChat-Agent工具调查笔记.md)
- [Agent角色配置调查笔记](../Agent角色/VCPChat-Agent角色配置调查笔记.md)
- [Chat调查笔记](../Chat/VCPChat-Chat调查笔记.md)
- [ChatUI调查笔记](<../Chat UI/VCPChat-ChatUI调查笔记.md>)
- [LLM渠道管理调查笔记](../LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/VCPChat-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md)
- [消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md)
- [独特功能调查笔记](../独特功能/VCPChat-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md)