# AI 客户端特色功能贡献统计

> 对比对象：`AIO Hub`、`AstrBot`、`Chatbox`、`Cherry Studio`、`DeepChat`、`Hermes Agent`、`Jan`、`LobeHub`、`Manifold Desktop`、`NextChat`、`OpenCode`、`Open WebUI`、`Pi`、`SillyTavern`、`VCPChat`、`VCPToolBox`
>
> 对比更新日期：2026-08-12
>
> 依据：本目录下通用类目调查笔记及横向对比、十六项目独特功能调查笔记、独特功能待查清单，并参考《AI 客户端完整体验栈与模块组合构想》
>
> 对比方法：先排除通用聊天底座，再把已达到 `主链确认` 的能力按用户目标合并为互不重复的产品功能族；经产品辨识度闸门后，主贡献计 2 点、辅助贡献计 1 点，工程、安全和可靠性机制另表记录且不参与计分
>
> 对比范围：统计当前笔记已确认的差异化产品工作流和直接形成用户能力的运行时形态；不统计品牌、社区规模、代码量、测试量、普通聊天功能、仅有入口或接口骨架的能力
>
> 文档定位：用于回答“各项目真正带来了什么不同”，并补充综合质量评分；不表示功能原创归属、历史首创、运行质量或项目绝对排名

## 结论摘要

最新十六项目专项笔记共归并出 **88 个产品功能族**，另整理 **15 个机制贡献族**。本轮吸收 AIO Hub、VCPChat、VCPToolBox 三份补充盘点：新增 13 个产品族和精确 Token、共享 OCR 两个机制族；同时加入“产品辨识度闸门”，避免仅因实现完整、界面标准或恰好是样本中唯一实现就自动获得主贡献。

> 覆盖说明：全部计分项均已达到静态源码意义上的 `主链确认`，但大量能力尚未运行验证。`入口确认`、外部依赖和声明不符项不计分；默认关闭的已确认能力仍可计入，但在理由中保留边界。

- **AIO Hub** 的覆盖面最宽。本轮新增 Recall 思绪集、网页蒸馏室、窗口自动化语言、实时字幕 OCR 和跨播放器弹幕五项主贡献；Git 提交台与长文翻译虽已闭环，但产品形态更接近成熟专用工具，只计辅助贡献。
- **Hermes Agent、OpenCode、Open WebUI** 分别在持续 Agent 后端、编码会话服务、多人模型工作区三个方向形成宽覆盖；Open WebUI 新增 Channels、Notes、Memory、Calendar、Automations 和 Arena/ELO 六条完整产品链。
- **VCPChat** 新增 Agent 可控 Hi-Fi 播放器、系统级划词助手和双语自动语音链三项主贡献，并以论坛客户端、RAG Observer 和 3D 物理骰子补充既有 VCP 运行时，产品身份从“特色聊天前端”进一步转向 AI 原生桌面环境。
- **VCPToolBox** 新增多观点 Agent 会议主贡献，Skill 目录索引作为既有 Skill 生命周期族的辅助贡献；全盘文件检索、Agent 邮箱、金融聚合、仓库文档 MCP 客户端与管理员认证码分别属于常规系统/服务接入、领域工具或支撑机制，不因主链闭合而抬高产品分。
- **DeepChat、LobeHub、Cherry Studio、AstrBot** 分别补入 IM 遥控与 Skill 迁移、任务调度与个人记忆、小程序与全局搜索、Agent Sandbox 与主动式 Agent，旧统计明显低估了这些产品面。
- **NextChat** 仍只有 fork 与隔离 Artifact 两项辅助贡献；**Manifold Desktop** 经专项复核后仍为 0 分，原因是当前主链未闭合，而非笔记覆盖不足。

这里的“贡献”表示：组合新产品时，现有调查会优先从哪个项目提取该能力的产品契约或实现原型。它不是代码贡献、原创权或成熟度结论。

## 排除与拆分口径

以下能力即使实现良好，也不进入产品特色分：

1. 会话 CRUD、普通历史记录、文本流式显示、停止、错误提示和基础本地持久化。
2. Markdown、代码高亮、公式、Mermaid、复制、编辑、删除、重新生成和普通附件预览。
3. Provider/模型选择、单 Key、自定义 Base URL、基础参数和“支持很多 Provider”本身。
4. 单段 system prompt、普通角色预设、基础知识库、普通联网搜索、简单 RAG、主题、语言、导入导出和备份。
5. 只有一次 `tool_call` 展示，或只声明 MCP、Plugin、Skill、ACP 而没有发现、执行、治理或结果闭环。
6. typed parts、SQLite、事务、类型系统、测试量等纯工程质量。

工程、安全和可靠性机制若直接支撑多个特色工作流，会进入“机制贡献统计”，但不与用户可见产品功能混成总分。一个机制与产品功能同时出现不算重复计分，因为机制表没有分数。

## 计分规则

在分配主贡献前先过“产品辨识度闸门”。能力至少应改变一类核心产品契约，例如引入新的持久对象、交互表面、连续/自主工作模式、跨应用运行时或可迁移生态；仅有规范的 CRUD、完整设置页、常规第三方 API 接入、单用途领域查询或成熟工程实现，不足以成为主贡献。“当前样本中唯一”只能加强证据，不能单独决定等级。

| 标记 | 含义 | 分值 |
|---|---|---:|
| 主贡献 | 已通过辨识度闸门，且当前样本中定义了该功能族的首要产品契约或实现原型 | 2 |
| 辅助贡献 | 主链已闭合并提供关键部分、相邻形态或少见补充，但不足以独立定义产品身份 | 1 |
| 不计 | 通用底座、未闭环骨架、入口确认、外部依赖、证据不足或纯机制 | 0 |

同一项目在同一功能族中最多计一次。共同主贡献表示多种实现分别定义了该功能族的重要形态。只有辅助贡献而没有主贡献的功能族，表示能力已经闭环，但当前独特性或覆盖程度不足以选出首要参考。

## 产品功能统计

| 排序 | 项目 | 主贡献 | 辅助贡献 | 覆盖功能族 | 产品特色点 | 主要特色身份 |
|---:|---|---:|---:|---:|---:|---|
| 1 | AIO Hub | 13 | 12 | 25 | 38 | 上下文召回、网页蒸馏、桌面 RPA、媒体/资产与跨播放器工具枢纽 |
| 2 | VCPChat | 12 | 4 | 16 | 28 | 消息即应用、主动 Agent、桌面感知、Hi-Fi 媒体、记忆工作台与跨端同步 |
| 3 | Open WebUI | 10 | 5 | 15 | 25 | 多用户模型工作区、协作频道与文档、记忆、日历自动化和模型评估 |
| 4 | VCPToolBox | 11 | 1 | 12 | 23 | 记忆演化、上下文语言、托管浏览器、Agent 社会和异步插件编排 |
| 5 | Hermes Agent | 8 | 6 | 14 | 22 | 谱系化会话、后台任务、闭环学习、自进化 Skill 和跨界面 Agent 后端 |
| 6 | DeepChat | 5 | 10 | 15 | 20 | 可操控 Agent turn、IM 遥控、Tape & Trace、Skill 迁移和强审批绑定 |
| 7 | SillyTavern | 7 | 4 | 11 | 18 | 角色卡、World Info、提示词工程工作台、swipe、快捷动作和内容脚本 |
| 8 | OpenCode | 6 | 3 | 9 | 15 | 文件/Git 事实源、多表面会话、CodeMode、会话档案与 ACP 服务端 |
| 9 | LobeHub | 5 | 5 | 10 | 15 | Agent 调度与运营、白盒记忆、conversation-flow 和协作文档对象 |
| 10 | Cherry Studio | 4 | 5 | 9 | 13 | 数据库消息树、Agent workspace、小程序、联邦搜索和持久翻译 |
| 11 | Pi | 4 | 3 | 7 | 11 | 追加型分支会话、终端组件树、项目文件 Agent 和研究数据生产 |
| 12 | AstrBot | 4 | 2 | 6 | 10 | 跨 IM 事件流水线、Agent Sandbox、主动 Agent、组件投影和语音管道 |
| 13 | Jan | 2 | 5 | 7 | 9 | 设备级本地推理器、隔离 Artifact、本地 Agent 编排与 CLI 外接 |
| 14 | Chatbox | 1 | 5 | 6 | 7 | 图像工作站与多项高级能力的稳健辅助实现 |
| 15 | NextChat | 0 | 2 | 2 | 2 | 轻量 fork 与 opaque-origin Artifact |
| 16 | Manifold Desktop | 0 | 0 | 0 | 0 | 当前作为未闭合聊天主链的下限样本 |

排序先看产品特色点，再看主贡献数和覆盖功能族。分数相近不表示能力同质，例如 DeepChat 与 VCPChat 分别偏向可观测 Agent 会话和消息/桌面运行时，不能互相替代。

## 产品功能族明细

### 角色、上下文与长期认知

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F01 | 一体化 Agent 配方编辑：消息树、锚点、消息组、变量、资产和工具策略 | AIO Hub | LobeHub、SillyTavern | 把角色、上下文和工具配置收进同一编辑流程 |
| F02 | 可移植角色卡与社区资产兼容 | SillyTavern | AIO Hub | 支持 PNG/CharX/BYAF 等角色内容生态和跨格式汇入 |
| F03 | World Info / lore 条件触发与分层注入 | SillyTavern | AIO Hub | 面向长期角色世界的内容规则系统，不是普通 RAG |
| F04 | 可迁移且相互隔离的完整 Agent/Profile 运行环境 | Hermes Agent | AIO Hub、SillyTavern | Profile/包覆盖配置、技能、记忆或资产，而非单段 prompt |
| F05 | Persona、模型、知识、工具与访问控制合一的 Workspace Model | Open WebUI | LobeHub | 模型目录项同时成为多人工作区中的角色与权限对象 |
| F06 | 项目目录驱动的 Agent、提示词与 Skill 配置 | OpenCode、Pi | DeepChat | 配置随 cwd/项目文件加载，面向项目而非普通聊天预设 |
| F07 | 多角色群聊与长期 Topic 关系 | VCPChat | LobeHub | 角色关系和多 Agent 协作成为会话的一等结构 |
| F08 | 非对话时段自主整理记忆的 AgentDream | VCPToolBox | - | 后台完成抽种子、联想、生成、审批写回；当前默认禁用 |
| F09 | 可持久化的定时 Agent 与后台任务 | Hermes Agent、LobeHub、VCPToolBox | - | cron/interval/once 任务脱离前台执行并保留结果与历史；AstrBot 的 cron 已并入主动式 Agent，不重复计数 |
| F47 | 可编译、可调试的上下文 DSL 与提示词工程工作台 | AIO Hub、SillyTavern、VCPChat、VCPToolBox | - | 宏、预设、正则、TVS 均有持久对象、编译顺序并进入最终请求 |
| F63 | 闭环 Agent 学习与后台复习 | Hermes Agent | - | 按轮次或工具迭代 fork 复习记忆和技能并回写主环境 |
| F64 | Agent 自创建、改进和维护 Skill 的生命周期 | Hermes Agent | VCPToolBox | Hermes 覆盖 create/patch/归档、用量侧车和 curator；VCPToolBox 的 SkillBridge 补充目录扫描、元数据索引与按需展开，但不含自进化闭环 |
| F65 | 跨会话持久记忆与用户建模 | LobeHub、Open WebUI | Hermes Agent、SillyTavern | 结构化/文件记忆可提取、检索、编辑并进入后续对话 |
| F66 | 记忆语义动力学与元思考演化 | VCPToolBox | - | TagMemo/RiverMemo 排序与递归思考链共同维护长期认知状态 |
| F73 | 神经云图与日记记忆工作台 | VCPChat | - | 将记忆网络、搜索、日记和可视化组织为独立用户工作台 |
| F82 | Agent 私有资产协议与作用域管理 | AIO Hub | - | `agent-asset://` 把资产绑定 Agent，并贯通管理、宏注入和渲染 |
| F83 | 多引擎即时 Recall 思绪集 | AIO Hub | - | 思绪集、四类检索引擎、Agent 管理工具与上下文占位符共同形成世界书之外的语义召回产品面 |

### 会话演化、连续性与研究轨迹

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F10 | 持久消息树与活动分支指针 | Cherry Studio | AIO Hub、Jan、Open WebUI | 历史分支可保存、切换和恢复 |
| F11 | 单条回复候选、swipe 与版本导航 | SillyTavern | AIO Hub、Chatbox、Jan | 多个候选保留在同一语义位置供用户切换 |
| F12 | 多模型并行回复与并排比较 | Open WebUI | Cherry Studio、LobeHub | 同一请求生成多列或兄弟结果并提供专门投影 |
| F13 | 会话 fork、checkpoint 与 lineage | Hermes Agent、Pi | SillyTavern、DeepChat、NextChat、Open WebUI、OpenCode | 从历史点派生新会话并保留来源关系 |
| F14 | 压缩后仍可追溯原会话谱系 | Hermes Agent | Pi | compaction 产生新节点但不抹掉原 transcript 的寻址关系 |
| F15 | 跨会话消息全文检索并直达具体消息 | DeepChat | Chatbox | 搜索结果落到 message id，而非只打开会话 |
| F16 | 生成中的 steer、queue 与 pending input | DeepChat | Jan | Agent turn 未结束时仍可改变后续执行 |
| F17 | 跨 IM 平台事件流水线、群聊唤醒与 follow-up | AstrBot | - | 核心产品单位是平台事件和 UMO，而非桌面聊天窗口 |
| F27 | 多表面共享同一 Agent 后端与会话连续性 | Hermes Agent、OpenCode | Jan | 多前端消费同一事实源；OpenCode 另支持重放与所有权接管 |
| F44 | 可保存、观察和迁移的研究轨迹/会话档案 | OpenCode、DeepChat | Pi、Hermes Agent | 覆盖 Tape & Trace、导出脱敏、导入分享、数据生产与轨迹压缩 |
| F59 | IM 渠道远程控制本地 Agent 会话 | DeepChat | - | 远端命令与本地会话绑定、执行和结果投递形成闭环 |
| F75 | 跨设备双向增量同步 | VCPChat | - | VCPMobileSync 用稳定身份、增量状态和删除传播同步产品数据 |
| F77 | 跨聊天消息转发与气泡附言 | - | VCPChat | 转发保持来源并允许附言，已闭环但独特性不足以单列首要参考 |

### 生成式输出、协作与创作表面

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F18 | 可执行消息小应用与消息运行时 SDK | VCPChat | AIO Hub | 模型输出可成为有交互和行为的应用，而非富文本预览 |
| F19 | 可持久、可查询、可替换的桌面挂件活对象 | VCPChat | - | 挂件有独立 ID、文件和能力桥，跨越单条消息生命周期 |
| F21 | 声明式 conversation-flow 与工具过程投影 | LobeHub | DeepChat、Cherry Studio | Agent 中间过程被编译成可操作流程 |
| F22 | 严格隔离的 HTML/SVG Artifact 预览 | Jan | NextChat、Chatbox、DeepChat、Open WebUI | 生成页面在独立运行域投影，不获得宿主同源权限 |
| F23 | 带文件树、编辑器、冲突检测和自动保存的 Agent workspace | Cherry Studio | AIO Hub、Hermes Agent | 用户直接维护模型生成的项目文件 |
| F24 | 文件/Git/diff 事实源与模型回读、回滚闭环 | OpenCode | LobeHub、AIO Hub、Pi、Hermes Agent、Chatbox | 模型下一轮继续操作同一工作区对象 |
| F25 | 文档对象级 diff、编辑锁与 Page-Agent | LobeHub | - | 文档有独立事实源、节点级修改和接受/拒绝流程 |
| F26 | Notebook、Pyodide、Jupyter 与 Terminal 执行表面 | Open WebUI | Cherry Studio | 代码输出成为可编辑、可运行的工作区 |
| F28 | 终端原生组件树、diff 预演和图片/ASCII 投影 | Pi | - | 在 ANSI 边界内形成完整 Agent 工作台 |
| F29 | 同一消息组件链投影到 WebChat 和多个 IM 平台 | AstrBot | - | 平台适配器把统一业务语义转换为不同消息能力 |
| F48 | 媒体生成与资产创作工作站 | AIO Hub、VCPToolBox、Chatbox | - | 覆盖生成、历史/资产持久化、编辑或插件化媒体工作流 |
| F49 | 中央资产导入、去重、索引与复用 | AIO Hub | - | 资产从字节导入到 SHA-256 去重、JSONL 索引和跨工作流复用 |
| F52 | 可分离窗口与跨窗口状态同步 | AIO Hub | - | 工具/组件可脱离主窗并保持逻辑状态同步 |
| F56 | 内嵌 Web 应用门户与小程序运行池 | Cherry Studio | - | 预设和自定义 Web 应用有 launchpad、侧栏与 keep-alive 生命周期 |
| F57 | 跨 Topic、Session 与消息内容的联邦全局搜索 | Cherry Studio | - | 应用级命令汇聚实体搜索与 FTS5 内容搜索，并支持分页定位 |
| F58 | 消息级流式翻译与译文持久化 | - | Cherry Studio、AIO Hub | Cherry 以 `data-translation` part 持久并可重译覆盖；AIO Hub 以 `metadata.translation` 持久并支持原文/译文/双语显示切换，独特性中等 |
| F67 | Agent 运营汇报与版本化 Work 产物 | LobeHub | - | 任务结果沉淀为 Brief 分类、Inbox 汇报和独立 Work 对象 |
| F68 | 人类与模型共同参与的实时 Channels | Open WebUI | - | 频道、线程、反应、置顶和模型 @ 参与形成协作空间 |
| F69 | 与隐藏会话及工具互通的协作 Notes | Open WebUI | - | Note CRUD、Yjs 协作和模型读写工具构成独立文档工作区 |
| F81 | 人类工具箱、自动 GUI 与节点工作流编辑器 | VCPChat | - | manifest 转表单、专用面板和节点执行引擎形成可操作工具面 |
| F76 | LoomAPP 数据驱动创作运行时 | VCPChat | - | 前端插件可承载独立交互与数据可视化创作应用 |
| F88 | 百万字符长文本分片翻译与上下文继承 | - | AIO Hub | 递归分片、并发限流、相邻片段上下文和精确 Token 预算闭环，但不单独定义客户端身份 |
| F89 | 内置弹幕播放与第三方播放器透明覆盖运行时 | AIO Hub | - | 多格式解析、虚拟时钟、HWND 跟随、DPI/Z-Order 同步和高保真字幕降级链形成独立桌面产品面 |
| F90 | Agent 可控的本机 Hi-Fi 播放子系统 | VCPChat | - | 自研 DSP/WASAPI 引擎、WebDAV 曲库、桌面挂件、歌词与对话点歌贯通 |
| F91 | 系统级划词感知与旁路 Agent 对话 | VCPChat | - | Rust sidecar 捕获任意应用选区，经悬浮动作条进入真实 Agent 话题并可回存笔记 |
| F92 | 双语切片、双模型分流与自动朗读语音链 | VCPChat | - | 混合语言文本按片段分流到两个 TTS 模型，并由前端插件自动朗读和缓存 |
| F93 | 桌面 RAG 信息流监听与工具审批浮层 | - | VCPChat | 独立透明窗口持续展示后端信息流并可批准或拒绝工具，但依赖外部 VCP 后端 |
| F94 | Agent 可调用的 3D 物理骰子 | - | VCPChat | ammo.wasm 物理投掷和结果回传形成闭环，产品面较窄且无持久对象 |

### Agent 工具、运行时与外部互操作

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F30 | 子 Agent / handoff 作为可见或真实子会话 | Hermes Agent | DeepChat、OpenCode、Open WebUI、AstrBot | 委托任务有独立上下文、轨迹或会话 |
| F34 | 角色卡、World Info 或脚本内容可定义模型工具 | SillyTavern | - | 内容资产能够改变 Agent 工具面 |
| F36 | 面向真实项目文件与 shell 的本地编码 Agent 闭环 | OpenCode、Pi | Cherry Studio、DeepChat、Hermes Agent、Chatbox | 读、搜、改、执行、回注组成连续开发工作流 |
| F43 | 受限 JavaScript 工具编排运行时 CodeMode | OpenCode | - | 模型用受限 JS 编排多个工具，并受并发、超时和输出预算约束 |
| F45 | ACP Agent 服务端互操作 | - | OpenCode | 外部 ACP 宿主可创建、恢复、提示、取消和分叉 OpenCode 会话 |
| F46 | 本地 MCP 编排服务端 | - | Jan | `/v1/orchestrations` 把 MCP 工具循环作为 HTTP Agent 服务暴露 |
| F50 | LLM 请求检查器与双层观测面 | AIO Hub | - | 内部钩子和网络层共同展示真实请求、流式响应与耗时 |
| F51 | 可持久化快捷动作与模板按钮 | SillyTavern | AIO Hub | 酒馆 Quick Reply 以持久按钮组、事件自动执行和右键菜单定义生态契约；AIO Hub 快捷操作以宏引擎、行级后处理和自动发送补充相邻形态，并兼容 Quick Reply 导入 |
| F53 | 隔离的 Agent/Skill 执行沙箱 | AIO Hub、AstrBot | - | 覆盖路径锁定、多运行时探测或会话级计算机实例与文件进出 |
| F54 | 主动回复与连续工作 Agent | VCPChat、AstrBot | - | FlowLock/TopicSponsor 与概率唤醒分别形成非单轮被动聊天模式 |
| F55 | 跨平台语音收发与 TTS/STT 管道 | - | AstrBot | 14 个服务统一进入平台无关消息处理链，独特性中等 |
| F60 | Skill 跨工具格式转换与同步 | DeepChat | - | 11+ 工具适配器把 Skill 在不同编码 Agent 生态间迁移 |
| F61 | 多搜索源与浏览工具组合的深度研究链 | - | DeepChat | web 搜索、深度研究和浏览工具已闭环，但普通搜索不单独加分 |
| F62 | DeepLink 外部启动与配置协议 | - | DeepChat | `deepchat://` 可启动会话、安装 MCP 或配置 Provider |
| F74 | 托管浏览器观察、控制与验证运行时 | VCPToolBox | - | managed Chrome 具生命周期、协议、脱敏、验证和指标闭环；默认关闭 |
| F78 | 跨节点文件透明获取与取消传播 | VCPToolBox | - | 来源绑定、缓存、循环保护、断线清理和 cancel_tool 形成分布式文件面 |
| F79 | 文件事实源的 Agent 论坛与异步协作 | VCPToolBox | VCPChat | 后端以 Markdown 帖子形成可持久协作空间，VCPChat 提供隔离渲染的论坛客户端 |
| F80 | 长任务异步回调与结果回注会话 | VCPToolBox | - | 插件先返回任务句柄，完成后把结果重新注入原会话 |
| F84 | 多仓库 Git 工作台与 AI 提交草稿 | - | AIO Hub | diff 审查、暂存、批量仓库操作和 LLM 提交信息闭环完整，但仍是成熟开发工具的 AI 增强形态 |
| F85 | 带身份、配方、反检测代理和 API 嗅探的网页蒸馏 | AIO Hub | - | 网页读取被组织为可交互、可复用且可供 Agent 调用的独立浏览产品面 |
| F86 | 具子流程、变量作用域、条件跳转和 OCR 的桌面 RPA 语言 | AIO Hub | - | 窗口操作从录制回放提升为可持久、可组合的小型流程语言 |
| F87 | 屏幕区域持续 OCR、字幕合并与聊天回注 | AIO Hub | - | 高频截屏、帧去重、字幕时间轴、SRT 导出和跨窗口回注形成连续工作流 |
| F95 | 多观点 Agent 会议与主持综合 | VCPToolBox | - | 多角色并行作答、主持人综合和结构化会议信息构成区别于普通子 Agent 委托的审议形态 |

### 渠道、模型调度与评估

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F37 | 基于自然语言描述的语义虚拟模型路由 | VCPToolBox | - | 请求先匹配任务语义再选择真实模型 |
| F40 | 一键切换完整生成环境的 Connection/Profile | SillyTavern | Hermes Agent | 同时切换连接、模型、采样和创作环境 |
| F41 | 设备级本地推理器生命周期与云 Provider 统一路由 | Jan | Open WebUI、DeepChat | Jan 覆盖后端下载、更新、回滚、硬件选型、Router 与运行验证 |
| F42 | 多用户连接行与统一模型目录 | Open WebUI | DeepChat | 多个连接实例汇入统一目录并参与权限和运行时选择 |
| F70 | 个人/共享日历与模型调度面 | Open WebUI | - | 日历事件、参与者、工具和时间轴形成完整产品链 |
| F71 | 定时 Prompt Automations 与运行记录 | Open WebUI | - | 自动化配置、调度循环、运行表和日历投影闭环 |
| F72 | 模型 Arena / ELO 评估工作台 | Open WebUI | - | 用户反馈进入 Elo 排名和话题加权检索，不只是用量统计 |

## 机制贡献统计

机制贡献不参与产品特色点。这里记录跨能力复用、可明显改变安全性、可靠性或可恢复性的实现原型。

| ID | 机制贡献族 | 主参考 | 辅助参考 | 形成的边界或价值 |
|---|---|---|---|---|
| M01 | 保留富节点状态的稳定前缀流式更新 | AIO Hub | VCPChat、LobeHub | 避免累计全文重画，保留焦点、动画和已完成节点状态 |
| M02 | 具作用域、可复用或可恢复的工具审批策略 | DeepChat | Chatbox、Jan、Cherry Studio、Hermes Agent、LobeHub | 审批绑定会话、参数、命令、server 或持久策略 |
| M03 | Agent 循环步数、超时、重复守卫和大结果落盘 | AstrBot | Hermes Agent、OpenCode | 限制失控循环并把长结果转成可寻址对象 |
| M04 | 多来源统一工具注册、过滤与校验 | OpenCode | AIO Hub、AstrBot、Hermes Agent、Open WebUI、Jan | 内置、Plugin、MCP、Skill 共用发现和执行边界 |
| M05 | 跨进程、远端节点和多协议插件执行 | VCPToolBox | VCPChat、AIO Hub | 工具运行位置离开当前客户端，并由协议和节点编排 |
| M06 | 请求、Key、模型与 Provider 分层故障转移 | Hermes Agent | - | 失败后逐层改变目标，形成完整静态 fallback 链 |
| M07 | Key 健康状态、冷却与当前请求换 Key | AIO Hub | AstrBot、Jan | Key 成为带失败状态和选择逻辑的资源池 |
| M08 | 单写者事件日志、重放与所有权接管 | OpenCode | - | 为跨设备会话提供全序事件、断点恢复和显式写所有权 |
| M09 | 沙箱预算、plain-data 边界与路径锁定 | OpenCode、AIO Hub、AstrBot | - | 限制代码/Skill/计算机沙箱的能力、时间、输出和文件范围 |
| M10 | 原子同步、墓碑删除与稳定哈希 | VCPChat | - | 降低跨设备增量同步中的冲突、复活和身份漂移 |
| M11 | 资产/文件内容寻址、缓存与取消传播 | AIO Hub、VCPToolBox | - | 以哈希去重或来源绑定管理大文件和远端结果生命周期 |
| M12 | 插件桥 IPC 白名单与挂件资源治理 | VCPChat | - | 限制路径和命令，并清理监听器、定时器与不可见挂件资源 |
| M13 | Rust/Rayon 原生记忆内核与可解释排序 | VCPToolBox | - | 把大规模语义计算下沉，同时保留排序结果和解释面 |
| M14 | Tokenizer 资产注册、多模态计费与全局预算服务 | AIO Hub | - | 为上下文截断、压缩、预览、检查和长文翻译提供统一的精确预算依据 |
| M15 | 多引擎共享 OCR 平台与跨工具复用 | AIO Hub | VCPChat | OCR 引擎、Profile 与执行入口被字幕、转写、窗口自动化或桌面感知工作流共同消费 |

本轮明确不计分：AIO Hub 的内容查重器属于性能/工程增强；VCPChat 的普通笔记、翻译窗、语音聊天和运维面未形成足够不同的产品契约；VCPToolBox 的 VCPEverything、VCPClawMail、DigitalOracle、DeepWikiVCP 与 UserAuth 分别属于常规本机检索/邮箱接入、领域数据聚合、单一 MCP 客户端和安全支撑机制。它们的实现完整度仍记录在单项目笔记中，但不转化为特色点。

## 如何解读结果

### 1. 宽贡献和尖贡献分开看

- AIO Hub、VCPChat、Open WebUI、Hermes Agent、DeepChat 覆盖功能族多，适合作为组合架构或产品面的主干参考。
- VCPChat、VCPToolBox、SillyTavern、OpenCode、Pi 主贡献比例高，适合寻找明确的产品差异点。
- Chatbox、Cherry Studio、Jan 有较多成熟实现；Chatbox 更偏把高级能力做稳，Cherry 和 Jan 各有消息树/workspace、本地推理器两个清晰主轴。

### 2. 产品特色点不是质量分

VCPChat 的可执行消息、SillyTavern 的内容脚本、VCPToolBox 的分布式插件和 OpenCode 的可编程工具编排都扩大了安全或维护边界。特色统计只说明能力少见，不说明应原样复制。工程、安全与可恢复性仍应回看[AI 客户端项目评分](AI客户端项目评分.md)和上面的机制表。

### 3. 项目边界会影响结果

AstrBot、OpenCode、Pi、VCPToolBox 本来就不以普通桌面 Chat 为边界，去掉聊天底座后反而更显出贡献。[Manifold Desktop 专项复核](独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)已确认其 0 分不是覆盖不足：当前 HEAD 的基础 Chat、MCP、插件和持久化主链均未闭合。

## 与综合评分的差异

现有[AI 客户端项目评分](AI客户端项目评分.md)回答“一个完整客户端是否成熟、均衡、可控”；本文回答“若拿掉大家都有的底座，这个项目还留下哪些值得组合的产品能力”。

| 观察角度 | 更看重什么 | 容易上升的项目 |
|---|---|---|
| 综合评分 | 完整性、工程、安全、恢复、常见主链 | DeepChat、Hermes Agent、Cherry Studio、LobeHub |
| 产品特色贡献 | 独特工作流、生态契约、运行时形态、产品辨识度 | AIO Hub、Hermes Agent、Open WebUI、VCP 系、SillyTavern、OpenCode |
| 机制贡献 | 跨能力复用、安全、可靠性、可恢复性 | OpenCode、Hermes Agent、AIO Hub、VCP 系、DeepChat |

## 依据索引

- [独特功能调查指南](独特功能/调查指南.md)
- [独特功能待查清单](独特功能/待查清单.md)
- [AIO Hub 独特功能调查笔记](独特功能/AIO-Hub-独特功能调查笔记.md)
- [VCPChat 独特功能调查笔记](独特功能/VCPChat-独特功能调查笔记.md)
- [VCPToolBox 独特功能调查笔记](独特功能/VCPToolBox-独特功能调查笔记.md)
- [上下文编译与提示词工程边界研究](独特功能/上下文编译与提示词工程边界研究.md)
- [AI 客户端完整体验栈与模块组合构想](AI客户端最佳模块组合构想.md)
- [Agent 角色横向对比](Agent角色/Agent角色横向对比.md)
- [Agent 工具横向对比](Agent工具/Agent工具横向对比.md)
- [会话与消息管理横向对比](会话与消息管理/会话与消息管理横向对比.md)
- [对话请求与上下文横向对比](对话请求与上下文/对话请求与上下文横向对比.md)
- [Chat UI 横向对比](<Chat UI/ChatUI横向对比.md>)
- [LLM 渠道管理横向对比](LLM渠道管理/LLM渠道管理横向对比.md)
- [消息渲染器横向对比](消息渲染器/消息渲染器横向对比.md)
- [生成式输出与运行时横向对比](生成式输出与运行时/生成式输出与运行时横向对比.md)
