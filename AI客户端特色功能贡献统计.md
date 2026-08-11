# AI 客户端特色功能贡献统计

> 对比对象：`AIO Hub`、`AstrBot`、`Chatbox`、`Cherry Studio`、`DeepChat`、`Hermes Agent`、`Jan`、`LobeHub`、`Manifold Desktop`、`NextChat`、`OpenCode`、`Open WebUI`、`Pi`、`SillyTavern`、`VCPChat`、`VCPToolBox`
>
> 对比更新日期：2026-08-11
>
> 依据：本目录下 Agent 工具、Agent 角色、会话与消息管理、对话请求与上下文、Chat UI、LLM 渠道管理、消息渲染器、生成式输出与运行时的单项目调查笔记及横向对比，并参考《AI 客户端完整体验栈与模块组合构想》
>
> 对比方法：先排除通用聊天底座，再把剩余能力合并为互不重复的特色功能族；按“主贡献”和“辅助贡献”记录项目对可复用产品能力的贡献，主贡献计 2 点、辅助贡献计 1 点
>
> 对比范围：统计当前笔记已确认的差异化产品工作流和直接支撑这些工作流的专用运行机制；不统计品牌、社区规模、代码量、测试量、普通聊天功能和仅有接口骨架但未闭环的能力
>
> 文档定位：补充现有综合评分中对标准化底座权重较高的问题，用于回答“各项目真正带来了什么不同”；不表示功能原创归属、历史首创或项目绝对质量排名

## 结论摘要

去除“是个 Chat 就有”的基础能力后，本次从现有笔记中归并出 **42 个特色功能族**。统计结果与综合质量评分明显不同：

> 覆盖说明：本表是基于现有通用类目笔记形成的暂定统计。项目介绍扫描已确认，VCPChat、VCPToolBox、AIO Hub、Open WebUI、LobeHub、Hermes Agent 等项目仍有未进入通用类目的产品面；其中 VCPChat 十份笔记只有两份使用当前 HEAD，VCPToolBox 九份笔记有三份使用旧快照。新增的[独特功能调查指南](独特功能/调查指南.md)与[待查清单](独特功能/待查清单.md)完成前，本表不宜解释为稳定排名。

- **Hermes Agent** 的特色贡献面最宽，主贡献集中在 Profile 隔离、定时 Agent、会话谱系、压缩继承、跨界面会话、子 Agent 和跨 Provider fallback。
- **AIO Hub** 的辅助贡献最多，说明它更像多个生态和运行时思路的汇合点；它自己的主贡献是 Agent 配方编辑、稳定前缀 AST 和 Key 健康状态。
- **SillyTavern、OpenCode、VCPChat、VCPToolBox、Pi** 的“主贡献占比”较高。它们不一定拥有最均衡的底座，但产品身份清楚，提供了别的项目难以替代的能力原型。
- **Chatbox** 的综合完成度较高，但在本口径下主要是六项辅助贡献，没有单列为样本首要参考的特色功能。这正是“标准、完整”和“有独特产品贡献”之间的区别。
- **NextChat** 只保留会话 fork 和隔离 Artifact 两项辅助贡献；**Manifold Desktop** 当前主链尚未闭合，去除普通聊天底座后没有可计入的特色功能族。

这里的“贡献”不是代码贡献或原创权声明，而是：若要组合一个新产品，现有调查会从哪个项目优先取这一能力的产品契约或实现原型。

## 排除口径

以下能力即使实现良好，也不计入特色贡献：

1. 会话新建、删除、重命名、列表、普通历史记录和基础本地持久化。
2. 文本发送、流式显示、停止按钮、加载状态和错误提示。
3. Markdown、代码高亮、公式、Mermaid、复制、编辑、删除、重新生成和普通附件预览。
4. Provider/模型选择、API Key、自定义 Base URL、温度等基础参数设置，以及“支持很多 Provider”本身。
5. 单段 system prompt、普通角色预设、基础知识库、普通联网搜索和简单 RAG。
6. 主题、语言、快捷键、通知、导入导出、备份和同步等通用客户端能力。
7. 仅显示一次 `tool_call`，或仅声明支持 MCP/Plugin/Skill，但没有统一发现、审批、治理、分布式执行或结果闭环。
8. typed parts、SQLite、虚拟列表、事务、测试量、类型系统等纯工程质量；只有当它们直接形成特殊工作流时，才合并计入对应功能族。

因此，本统计不会因为“聊天做得顺”“Provider 多”“Markdown 全”“工程标准化”而加分。

## 计分规则

| 标记 | 含义 | 分值 |
|---|---|---:|
| 主贡献 | 当前样本中最完整、最有辨识度、唯一已确认，或现有笔记明确建议作为该能力的首要参考 | 2 |
| 辅助贡献 | 提供可组合的关键部分、另一种有效实现，或在同一能力族中形成重要补充 | 1 |
| 不计 | 只有通用底座、未闭环骨架、证据不足，或只是底层实现质量 | 0 |

同一项目在同一功能族中最多计一次。共同主贡献表示两种实现分别定义了该功能族的重要形态，不强行排出唯一第一。特色点仅用于排序，阅读时应同时看主贡献数、辅助贡献数和具体功能族。

## 项目统计

| 排序 | 项目 | 主贡献 | 辅助贡献 | 覆盖功能族 | 特色点 | 主要特色身份 |
|---:|---|---:|---:|---:|---:|---|
| 1 | Hermes Agent | 7 | 7 | 14 | 21 | 跨界面 Agent 后端、谱系化会话、后台任务、可靠渠道回退 |
| 2 | AIO Hub | 3 | 10 | 13 | 16 | 一体化 Agent 配方、稳定 AST 富消息、Key 健康管理、生态汇合 |
| 3 | Open WebUI | 4 | 6 | 10 | 14 | 多用户模型工作区、多模型比较、代码执行表面、统一模型目录 |
| 4 | OpenCode | 5 | 3 | 8 | 13 | 文件/Git 事实源、跨终端与 Web 会话、可扩展编码 Agent |
| 4 | SillyTavern | 5 | 3 | 8 | 13 | 角色卡、World Info、swipe、内容脚本和完整创作环境 Profile |
| 4 | DeepChat | 3 | 7 | 10 | 13 | 可操控 Agent turn、消息级搜索、强审批绑定和主进程 transcript |
| 7 | LobeHub | 2 | 7 | 9 | 11 | conversation-flow、可协作文档对象和 Agent 工作流投影 |
| 8 | Pi | 4 | 2 | 6 | 10 | 追加型分支会话、终端组件树、项目文件 Agent、轻量编码循环 |
| 9 | AstrBot | 3 | 3 | 6 | 9 | 跨 IM 事件流水线、组件投影、受治理的服务端工具循环 |
| 9 | Cherry Studio | 2 | 5 | 7 | 9 | 数据库消息树和带编辑器的 Agent workspace |
| 9 | Jan | 2 | 5 | 7 | 严格隔离 Artifact、本地模型路由和线程级工具审批 |
| 12 | VCPChat | 3 | 2 | 5 | 8 | 消息即应用、持久桌面挂件、多角色 Topic 和分布式工具消费 |
| 13 | VCPToolBox | 3 | 0 | 3 | 6 | AgentDream、语义虚拟模型和分布式插件编排 |
| 13 | Chatbox | 0 | 6 | 6 | 6 | 多项高级能力的稳健实现，但当前未形成样本独占的产品主轴 |
| 15 | NextChat | 0 | 2 | 2 | 2 | 轻量 fork 与 opaque-origin Artifact |
| 16 | Manifold Desktop | 0 | 0 | 0 | 0 | 当前作为未闭合聊天主链的下限样本 |

特色点相同不表示能力同质。例如 OpenCode、SillyTavern、DeepChat 都为 13 点，但分别代表编码工作区、角色内容生态和可操控 Agent 会话，不能互相替代。

## 特色功能族明细

### 角色、上下文与长期认知

| ID | 特色功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F01 | 一体化 Agent 配方编辑：消息树、锚点、消息组、宏、变量、资产和工具策略 | AIO Hub | LobeHub、SillyTavern | AIO 把原本分散的角色、上下文和工具配置收进同一编辑流程 |
| F02 | 可移植角色卡与社区资产兼容 | SillyTavern | AIO Hub | SillyTavern 提供 PNG/CharX/BYAF 与角色内容生态，AIO 提供跨格式汇入 |
| F03 | World Info / lore 条件触发与分层注入 | SillyTavern | AIO Hub | 不是普通 RAG，而是服务长期角色世界的内容规则系统 |
| F04 | 可迁移且相互隔离的完整 Agent/Profile 运行环境 | Hermes Agent | AIO Hub、SillyTavern | Profile/包不仅含 prompt，还覆盖配置、技能、记忆或资产 |
| F05 | Persona、模型、知识、工具与访问控制合一的 Workspace Model | Open WebUI | LobeHub | 模型目录项同时成为多用户工作区中的角色与权限对象 |
| F06 | 项目目录驱动的 Agent、提示词与 Skill 配置 | OpenCode、Pi | DeepChat | 配置随 cwd/项目文件加载，面向编码项目而非普通聊天预设 |
| F07 | 多角色群聊与长期 Topic 关系 | VCPChat | LobeHub | 角色关系和多 Agent 协作成为会话的一等结构 |
| F08 | 非对话时段自主整理记忆的 AgentDream | VCPToolBox | - | 当前样本唯一明确的后台“抽种子、联想、生成、审批写回”原型 |
| F09 | 定时 Agent 与后台任务 | Hermes Agent | - | cron 任务脱离前台对话执行并保留结果，是持续 Agent 而非聊天按钮 |

### 会话演化与比较

| ID | 特色功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F10 | 持久消息树与活动分支指针 | Cherry Studio | AIO Hub、Jan、Open WebUI | 不是简单 regenerate，而是历史分支可保存、切换和恢复 |
| F11 | 单条回复候选、swipe 与版本导航 | SillyTavern | AIO Hub、Chatbox、Jan | 多个候选留在同一语义位置供用户切换 |
| F12 | 多模型并行回复与并排比较 | Open WebUI | Cherry Studio、LobeHub | 同一请求生成多列/兄弟结果并提供专门投影 |
| F13 | 会话 fork、checkpoint 与 lineage | Hermes Agent、Pi | SillyTavern、DeepChat、NextChat、Open WebUI、OpenCode | 从历史点派生新会话并保留来源关系，不等同于复制文本 |
| F14 | 压缩后仍可追溯原会话谱系 | Hermes Agent | Pi | compaction 产生新节点但不抹掉原始 transcript 的寻址关系 |
| F15 | 跨会话消息全文检索并直达具体消息 | DeepChat | Chatbox | 搜索结果落到 message id，而不是只打开会话列表项 |
| F16 | 生成中的 steer、queue 与 pending input | DeepChat | Jan | 用户能在 Agent turn 尚未结束时改变后续执行，而非只能停止重来 |
| F17 | 跨 IM 平台事件流水线、群聊唤醒与 follow-up | AstrBot | - | 核心产品单位是平台事件和 UMO，而非桌面聊天窗口 |

### 生成式输出与运行时

| ID | 特色功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F18 | 可执行消息小应用与消息运行时 SDK | VCPChat | AIO Hub | 模型输出可以成为有交互和行为的应用，而不只是富文本预览 |
| F19 | 可持久、可查询、可替换的桌面挂件活对象 | VCPChat | - | 挂件拥有独立 ID、文件和能力桥，跨越单条消息生命周期 |
| F20 | 保留富节点状态的稳定前缀流式更新 | AIO Hub | VCPChat、LobeHub | 流式时保留焦点、动画或已完成 DOM，而不是反复重画累计全文 |
| F21 | 声明式 conversation-flow 与工具过程投影 | LobeHub | DeepChat、Cherry Studio | Agent 中间过程被编译成可操作流程，而非普通文本日志 |
| F22 | 严格隔离的 HTML/SVG Artifact 预览 | Jan | NextChat、Chatbox、DeepChat、Open WebUI | 把模型生成页面作为独立运行域投影，且不授予宿主页面同源权限 |
| F23 | 带文件树、编辑器、冲突检测和自动保存的 Agent workspace | Cherry Studio | AIO Hub、Hermes Agent | 用户直接维护模型生成的项目文件，而非只下载代码块 |
| F24 | 文件/Git/diff 事实源与模型回读、回滚闭环 | OpenCode | LobeHub、AIO Hub、Pi、Hermes Agent、Chatbox | 模型下一轮操作同一工作区对象，消息只记录修改过程 |
| F25 | 文档对象级 diff、编辑锁与 Page-Agent | LobeHub | - | 文档有独立事实源、节点级修改和接受/拒绝工作流 |
| F26 | Notebook、Pyodide、Jupyter 与 Terminal 执行表面 | Open WebUI | Cherry Studio | 代码输出成为可编辑、可运行的工作区，而非静态代码块 |
| F27 | TUI、Desktop、Web 共用同一 Agent 会话后端 | Hermes Agent、OpenCode | - | 多种前端消费同一事件协议和会话事实源，可独立演进 |
| F28 | 终端原生组件树、diff 预演和图片/ASCII 投影 | Pi | - | 在 ANSI 边界内形成完整 Agent 工作台，不依赖浏览器富内容 |
| F29 | 同一消息组件链投影到 WebChat 和多个 IM 平台 | AstrBot | - | 平台适配器把统一业务语义转换为各平台消息能力 |

### Agent 工具与执行

| ID | 特色功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F30 | 子 Agent / handoff 作为可见或真实子会话 | Hermes Agent | DeepChat、OpenCode、Open WebUI、AstrBot | 委托任务有独立上下文、轨迹或会话，不只是一次隐藏工具调用 |
| F31 | 具作用域、可复用或可恢复的工具审批策略 | DeepChat | Chatbox、Jan、Cherry Studio、Hermes Agent、LobeHub | 审批带会话、参数、命令、server 或策略范围，不只是无语义的一次性确认框 |
| F32 | Agent 循环治理：步数、超时、重复守卫和大结果落盘 | AstrBot | Hermes Agent、OpenCode | 防止循环失控并把长工具结果转成可寻址对象 |
| F33 | 内置、Plugin、MCP、Skill 等多来源统一工具注册表 | OpenCode | AIO Hub、AstrBot、Hermes Agent、Open WebUI | 不为“支持 MCP”计分，只为统一发现、过滤、校验与执行边界计分 |
| F34 | 角色卡、World Info 或脚本内容可定义模型工具 | SillyTavern | - | 内容资产能够改变 Agent 工具面，能力独特但同时扩大信任边界 |
| F35 | 跨进程、远端节点和分布式插件执行 | VCPToolBox | VCPChat、AIO Hub | 工具运行位置可离开当前客户端，由网关和节点编排 |
| F36 | 面向真实项目文件与 shell 的本地编码 Agent 闭环 | OpenCode、Pi | Cherry Studio、DeepChat、Hermes Agent、Chatbox | 读、搜、改、执行、回注组成连续开发工作流，不是单次代码生成 |

### 渠道与模型调度

| ID | 特色功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F37 | 基于自然语言描述的语义虚拟模型路由 | VCPToolBox | - | 请求先匹配任务语义再选择真实模型，是当前样本唯一明确原型 |
| F38 | 请求重试、Key、模型与跨 Provider/端点分层 fallback | Hermes Agent | - | 失败后跨不同层级改变目标，形成完整静态故障转移链 |
| F39 | Key 健康状态、冷却与当前请求换 Key | AIO Hub | AstrBot、Jan | Key 不再只是字符串列表，而是有失败状态和选择逻辑的资源池 |
| F40 | 一键切换完整生成环境的 Connection/Profile | SillyTavern | Hermes Agent | 切换连接、模型、采样和创作环境，而非只换 Provider 下拉框 |
| F41 | 本地模型运行时与云 Provider 统一路由 | Jan | Open WebUI | 本地引擎是客户端的一等模型来源，并与远程模型共享调用界面 |
| F42 | 多用户连接行与统一模型目录 | Open WebUI | DeepChat | 多个连接实例汇入统一目录，供工作区模型、权限和运行时选择 |

## 如何解读排名

### 1. 宽贡献与尖贡献应分开看

- **Hermes Agent、AIO Hub、Open WebUI、DeepChat** 覆盖功能族多，适合作为组合架构的主干参考。
- **SillyTavern、OpenCode、Pi、VCPChat、VCPToolBox** 覆盖面相对窄，但主贡献比例高，适合寻找明确的产品差异点。
- **Chatbox、Cherry Studio、Jan** 有大量成熟实现，其中 Chatbox 当前更偏“把高级能力做稳”，Cherry 和 Jan 各有消息树/workspace、隔离 Artifact/本地模型两个明确主轴。

### 2. 特色点不是质量分

VCPChat 的可执行消息和桌面挂件、SillyTavern 的内容脚本、VCPToolBox 的分布式插件都同时带来较大的安全或维护边界。特色统计只说明“它提供了别处少见的能力”，不说明应原样复制。安全、工程与可恢复性仍应回看[AI 客户端项目评分](AI客户端项目评分.md)。

### 3. 项目定位会影响上限

AstrBot、OpenCode、Pi、VCPToolBox 本来就不以普通桌面 Chat 为产品边界，因此去除 Chat 基础项后反而更能显出其贡献。[Manifold Desktop 专项复核](独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)已确认其 0 分不是笔记覆盖不足：当前 HEAD 的基础 Chat、MCP、插件和持久化主链均未闭合；这仍不表示未来路线或仓库价值为零。

## 与综合评分的差异

现有[AI 客户端项目评分](AI客户端项目评分.md)回答“一个完整客户端是否成熟、均衡、可控”；本文回答“若拿掉大家都有的底座，这个项目还留下哪些值得组合的产品能力”。两份结果应并列使用：

| 观察角度 | 更看重什么 | 容易上升的项目 |
|---|---|---|
| 综合评分 | 完整性、工程、安全、恢复、常见主链 | DeepChat、Hermes Agent、Cherry Studio、LobeHub |
| 特色贡献 | 独特工作流、生态契约、运行时形态、产品辨识度 | Hermes Agent、AIO Hub、SillyTavern、OpenCode、VCPChat、VCPToolBox、Pi |

这也解释了为什么一个“各项都标准”的项目可以综合分较高，却在特色贡献表中没有主贡献；反过来，一个安全或工程边界较弱的项目仍可能提供不可替代的产品原型。

## 依据索引

- [独特功能调查指南](独特功能/调查指南.md)
- [独特功能待查清单](独特功能/待查清单.md)
- [AI 客户端完整体验栈与模块组合构想](AI客户端最佳模块组合构想.md)
- [Agent 角色横向对比](Agent角色/Agent角色横向对比.md)
- [Agent 工具横向对比](Agent工具/Agent工具横向对比.md)
- [会话与消息管理横向对比](会话与消息管理/会话与消息管理横向对比.md)
- [对话请求与上下文横向对比](对话请求与上下文/对话请求与上下文横向对比.md)
- [Chat UI 横向对比](<Chat UI/ChatUI横向对比.md>)
- [LLM 渠道管理横向对比](LLM渠道管理/LLM渠道管理横向对比.md)
- [消息渲染器横向对比](消息渲染器/消息渲染器横向对比.md)
- [生成式输出与运行时横向对比](生成式输出与运行时/生成式输出与运行时横向对比.md)
