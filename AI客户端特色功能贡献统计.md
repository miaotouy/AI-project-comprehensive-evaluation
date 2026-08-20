# AI 客户端特色功能贡献统计

> 对比对象：`AIO Hub`、`AstrBot`、`Chatbox`、`Cherry Studio`、`DeepChat`、`DeepSeek Harness`、`Hermes Agent`、`Jan`、`LobeHub`、`Manifold Desktop`、`NextChat`、`OpenCode`、`Open WebUI`、`Pi`、`Risuai`、`SillyTavern`、`VCPChat`、`VCPToolBox`
>
> 对比更新日期：2026-08-19
>
> 依据：各单项目调查笔记（含通用类目、十八项目独特功能调查笔记、独特功能待查清单、“已调查能力汇总”“外部执行体与应用协作”和“对话导出与分享”类目）及横向对比；本次把 DeepSeek Harness 的全方向调查与能力汇总正式纳入统计，并复核其自引用插件运行时、日志化 plan mode、同会话 goal、session-local schedule、进程沙箱和多 Provider 子代理链；此前对 VCPToolBox、VCPChat、公开第三方模组 [VCP-Disco-Elysium-Mod](https://github.com/biyuqingtan-lab/VCP-Disco-Elysium-Mod) 及 AIO Recall 演变关系的专项依据继续沿用，深化程度仍以当前源码主链为依据
>
> 对比方法：先排除通用聊天底座，再把已达到 `主链确认` 的能力按用户目标和已知演变关系合并为互不重复的产品功能族；经产品辨识度闸门后，主贡献计 2 点、辅助贡献计 1 点，工程、安全和可靠性机制另表记录且不参与计分
>
> 对比范围：统计当前笔记已确认的差异化产品工作流和直接形成用户能力的运行时形态；不统计品牌、社区规模、代码量、测试量、普通聊天功能、仅有入口或接口骨架的能力
>
> 文档定位：用于回答“各项目真正带来了什么不同”，并补充综合质量评分；不表示功能原创归属、历史首创、运行质量或项目绝对排名

## 结论摘要

十八个项目的专项笔记共归并出 **99 个产品功能族**，另整理 **20 个机制贡献族**。产品族覆盖角色与长期认知、会话连续性、生成式输出、外部执行体与应用协作、Agent 运行时、模型调度及对话交付等方向。应用界面基础设施和仓库分布主要反映实现质量与工程边界，不转化为产品特色分。

> 覆盖说明：全部计分项均已达到静态源码意义上的 `主链确认`，但大量能力尚未运行验证。`入口确认`、外部依赖和声明不符项不计分；默认关闭的已确认能力仍可计入，但在理由中保留边界。

- **AIO Hub** 的覆盖面最宽。网页蒸馏室、窗口自动化语言、实时字幕 OCR、跨播放器弹幕和对话分享稿工作台构成主贡献；Git 提交台、长文翻译与 Recall 思绪集计辅助贡献。它还在 F18 以 HTML/SVG/JS/Canvas iframe 小应用和 Action Button 计可执行消息的辅助贡献，在 F02/F03 以角色卡导入、独立世界书编辑器及真实条件注入运行时计 ST 兼容辅助贡献。Recall 参考 VCP 的记忆召回路线后形成独立产品面，采用预设法与候选模块组成的检索管线，以 SQLite 为真源并使用 `【recall::…】` 严格占位符协议；它的工程产品化完整，但不再与 VCP 的上位记忆演化能力拆成两个主贡献族。Knowledge 是主动资料库工具，宏共 74 个。
- **Hermes Agent、OpenCode、Open WebUI** 分别在持续 Agent 后端、编码会话服务、多人模型工作区三个方向形成宽覆盖。Open WebUI 的 Channels、Notes、Memory、Calendar、Automations 和 Arena/ELO 均形成完整产品链。
- **VCPChat** 以 Agent 可控 Hi-Fi 播放器、系统级划词助手、双语自动语音链和 Scriptorium 共笔文坊（VDOC/VPPTX 工程 + 文脉 PR 审批）构成主贡献，论坛客户端、RAG Observer 和 3D 物理骰子则扩展 VCP 运行时。Loom v1.4.0 与 VCP Agent WebCore 属于 LoomAPP 数据驱动创作运行时，不重复计数。
- **VCPToolBox** 的 RAG/记忆系统不能只按一个“高级召回”功能计量。复核后拆为两个主贡献族：TagMemo/RiverMemo 负责生成前自动召回、私人语义传播、拓扑重排与解释；VCP 元思考负责用持久链配置逐簇递归检索，并让前一阶段结果改变后一阶段查询。此外，新版正式确立了 F108 “渠道与前端劫持代理（VCPBridgeServer）” 为主贡献，使其主贡献分提升至 13 分。公开的 [VCP-Disco-Elysium-Mod](https://github.com/biyuqingtan-lab/VCP-Disco-Elysium-Mod) 进一步证明这条链已经形成可迁移的内容资产契约：外部作者可以把“内心会议簇 + 四属性域 + 24 个原子模块”连同语义组配置打包，按 K 值组合成不同认知构型并直接部署 to VCP 的日记/RAG 目录；它是 F102 的生态证据，不作为新增项目或重复主贡献。LightMemo 的 KNN/TagMemo/RiverMemo 同候选域对照属于调优与验证机制，另入机制表；一致性预览/修复作为自动召回族的维护子链，Rust/Rayon 内核和 RAG Observer 分别归原生计算机制与辅助观察表面，不重复抬分。AIO Recall 作为后续独立产品化形态，仍在自动召回族计辅助贡献。多观点 Agent 会议同样是主贡献，Skill 目录索引作为 Skill 生命周期族的辅助贡献；全盘文件检索、Agent 邮箱、金融聚合、仓库文档 MCP 客户端与管理员认证码分别属于常规系统/服务接入、领域工具或支撑机制，不因主链闭合而抬高产品分。
- **媒体创作类目已正式建立，但不新增统计分。** AIO Hub、VCPToolBox、Chatbox 的 F48 仍按原口径计入；[媒体创作横向对比](媒体创作/媒体创作横向对比.md)只把三者共同的任务、历史、资产和结果复用契约抽出比较，VCPChat 的 ComfyGen/Loom/Scriptorium 与 Hi-Fi 播放器保留为扩展或相邻边界。
- **DeepChat、LobeHub、Cherry Studio、AstrBot** 分别覆盖 IM 遥控与 Skill 迁移、任务调度与个人记忆、小程序与全局搜索、Agent Sandbox 与主动式 Agent。LobeHub 的 Goals（目标闭环）与 Project（实体项目）分别为主链确认的主贡献和辅助贡献，DeepChat 的 CLI 本地控制平面归入“外部表面驾驶本地会话”主贡献族。
- **DeepSeek Harness** 正式纳入第十八个比较对象。模型在会话中检查、定义、运行、停止和删除自身 Cordis 插件的自引用运行时，以及由会话事件日志持久化并可跨恢复、分叉和压缩一致重放的 plan mode，各形成一个主贡献族；同会话 goal 以事件溯源目标、轮次预算和连续阻塞判定补充目标闭环，session-local schedule 以“日志规则 + 可弃定时投影 + 原会话回合投递”补充定时 Agent 族，均计辅助贡献。进程沙箱、能力缝和子代理委派策略进入机制表，不重复计产品分。
- **LobeHub** 的异构外部 Agent 托管统一六种 CLI、平台任务、原生会话、事件投影与取消；业务应用连接治理把账号、凭据、作用域和逐动作权限组织成 Connector 产品面。两者均为主贡献。DeepChat 与 Cherry Studio 以 ACP 安装运行时和 Claude Agent SDK 会话构成前一功能族的辅助贡献。
- **AIO Hub** 的对话分享稿工作台把任意消息选区、独立视觉编排、实时预览、逐消息捕获拼接和多结果运行时历史组成完整交付表面；NextChat 的固定品牌模板计辅助贡献。Cherry Studio 与 DeepChat 的离屏完整列表、现场滚动截图属于成熟捕获路线，记录在类目笔记中但不因工程完整度加分。
- **Hermes Agent** 的会话心跳和目标质量门均达到主链确认。心跳作为“当前会话定时重入”的实现形态并入 F09，不在同一项目重复计分；目标质量门在 DeepSeek Harness 纳入后具备可比较对象，作为 F96 的辅助贡献计分。
- **NextChat** 有 fork、隔离 Artifact 与固定模板对话分享三项辅助贡献；**Manifold Desktop** 为 0 分，原因是当前主链未闭合，而非笔记覆盖不足。
- **Risuai** 以模型指令标签驱动的角色媒体闭环构成主贡献（Emotion Images 双路径：inlay 指令标签与独立分类请求，群聊多角色分屏）；插件系统（API v2.1/v3.0 iframe 沙箱 + CSP nonce + postMessage RPC）作为机制贡献单列；翻译（渲染链内嵌结构保留翻译、多后端与 LLM 缓存）、Multisend（按文件类型分派的批量发送流水线）、WebRTC 房间（纯 P2P 实时共享角色与聊天）与 Risu Hub（角色市场）各计辅助贡献。

这里的“贡献”表示：组合新产品时，现有调查会优先从哪个项目提取该能力的产品契约或实现原型。它不是代码贡献、原创权或项目整体成熟度判定，但明确的参考与演变关系会影响主、辅助贡献分配：同一技术路线不能因换名或重新产品化而重复记为多个主贡献，后继实现只有在显著改写产品契约时才可另立功能族。

## 排除与拆分口径

以下能力即使实现良好，也不进入产品特色分：

1. 会话 CRUD、普通历史记录、文本流式显示、停止、错误提示和基础本地持久化。
2. Markdown、代码高亮、公式、Mermaid、复制、编辑、删除、重新生成和普通附件预览。
3. Provider/模型选择、单 Key、自定义 Base URL、基础参数和“支持很多 Provider”本身。
4. 单段 system prompt、普通角色预设、基础知识库、普通联网搜索、简单 RAG、主题、语言、导入导出和备份。
5. 只有一次工具调用展示，或只声明 MCP、Plugin、Skill、ACP 而没有发现、执行、治理或结果闭环。
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

## VCP RAG 专项拆解

此前的 F66 把触发方式、检索程序、排序内核、观察面和维护工具都压进“记忆演化”一行，读者无法判断 VCP 究竟改变了哪些产品契约。本次按“谁触发、操作什么事实源、结果如何进入下一轮”重排如下；同一主链内部的算法阶段仍不重复计分。

| 层次或入口 | 已确认主链 | 用户得到的能力 | 统计归属 |
|---|---|---|---|
| RAGDiary 自动注入 | system 消息中的日记占位符进入日记插件预处理，再经作用域检索并替换回最终上下文 | Agent 无须先决定调用搜索工具，相关长期记忆在生成前进入本轮认知环境；实现入口为 `RAGDiaryPlugin` | F66 主贡献 |
| TagMemo V9 + RiverMemo Topology V3 | 当前上下文降噪、标签传播和候选扩展后，由 Rust/Rayon 完成拓扑重排并生成解释元数据 | 召回顺序受私人日记网络、上下文与相对拓扑共同校准，并保留可观察的排序依据；关键解释字段为 `omega/regime/role/topologyBonus` | F66 的排序与解释子链，不再拆分加分 |
| VCP 元思考 | `[[VCP元思考:链名::修饰符:k序列]]` → 持久链配置 → 逐语义簇检索 → 阶段结果向量与原查询融合 → 驱动下一阶段 | 用户或 Agent 可以声明一个可复用的递归检索程序，而非只做一次相似度查询 | F102 主贡献；公开第三方模组证明思维簇可以作为可迁移内容资产分发 |
| 第三方思维簇资产 | 外部仓库提供内心会议簇、四属性域、24 个原子模块和语义组配置，放入 VCPToolBox 日记目录后由日记插件加载，并通过 K 值选择认知构型 | 思维簇从后端内部文件变成可分享、可安装、可二次编排的 Agent 人格/认知内容包；配置文件为 `semantic_groups.edit.json` | F102 的生态证据；不单独计分，仓库采用 CC BY-NC-SA 4.0 |
| LightMemo SearchRAG | Agent 工具调用 → 日记或 TDB 冷知识作用域 → KNN/BM25、TagMemo 或 RiverMemo → 可选 Rerank/AIMemo 总结 → 工具结果回注 | Agent 可主动查记忆、限定署名/文件夹/时间，并选择检索构型 | 主链确认；主动 RAG 工具本身较常规，不另计产品分 |
| LightMemo TagMemoAB | 同一 SQL 权限域、查询向量和候选事实域 → KNN/TagMemo/RiverMemo 三轨 → Top-K 重合率与统一排名 | 维护者能在可比条件下测量不同记忆内核的排序差异 | M18 机制贡献 |
| 一致性与调优面 | RAG 参数热加载、标签配置 → 一致性 preview token → 明确 apply → 增量重索引；管理台提供 RiverMemo/TagMemo 控制面 | 记忆网络可以先预览再修复，并在不重启主服务的情况下调整检索参数 | F66 的维护子链；不把设置页或 CRUD 单独计分 |
| AgentDream | 定时/手动触发 → 多层记忆种子与联想 → LLM 梦境叙事 → 合并/删除/感悟操作 → 人工审批写回 | 记忆在非对话时段被主动整理，破坏性变更经过审批 | F08 主贡献；默认禁用 |
| VCPChat Memo 工作台 | 日记浏览/搜索 → 神经云图与关联选择 → 编辑、合并和发布 | 人类可直接查看和整理 Agent 的记忆网络 | F73 主贡献 |
| VCPChat RAG Observer | 后端 VCP Info/WS 事件 → 独立透明窗口 → 召回阶段展示与工具批准/拒绝 | 用户持续观察 RAG 与工具信息流 | F93 辅助贡献；依赖外部 VCP 后端 |
| VCPChat DeepMemo 2.0 | 以可信会话身份查询 VCP-CDS 中央聊天历史，排除当前主题后扩展窗口、可选精排并回注工具结果 | Agent 可主动回看其他会话中的相关对话片段，模型参数不能覆盖可信会话身份；身份字段为 `agentId/topicId` | 主链确认；属于常规会话历史 RAG，不另计特色分 |

边界说明：TDB 冷知识库的 BM25 + 稠密向量 + 图扩散、AIMemo 候选总结、附件/时间/署名过滤都增强了检索链，但仍服务于 SearchRAG 的同一主动查询目标。RiverMemo 的查询降噪、守恒传播、双尺度场、候选曲线和 Ω 泛函是同一排序契约的内部阶段。第三方思维簇仓库是外部内容资产，不是本次 17 个项目比较对象；它用于证明 VCP 的思维簇生态已经出现可公开分发形态，不把外部仓库的内容创作误记为 VCPToolBox 的新增代码或独立分值。若按模块名逐项计分，会重新造成实现复杂度与产品贡献混算。

## 产品功能统计

| 排序 | 项目 | 主贡献 | 辅助贡献 | 覆盖功能族 | 产品特色点 | 主要特色身份 |
|---:|---|---:|---:|---:|---:|---|
| 1 | AIO Hub | 13 | 13 | 26 | 39 | 上下文召回产品化、网页蒸馏、桌面 RPA、媒体/资产、对话分享稿与跨播放器工具枢纽 |
| 2 | VCPChat | 13 | 4 | 17 | 30 | 消息即应用、主动 Agent、桌面感知、Hi-Fi 媒体、文档共笔、记忆工作台与跨端同步 |
| 3 | VCPToolBox | 13 | 1 | 14 | 27 | 自动联想记忆、递归检索思考链、上下文语言、托管浏览器、前端与 Prompt 劫持、Agent 社会和异步插件编排 |
| 4 | Open WebUI | 10 | 5 | 15 | 25 | 多用户模型工作区、协作频道与文档、记忆、日历自动化和模型评估 |
| 5 | Hermes Agent | 8 | 7 | 15 | 23 | 谱系化会话、后台任务、闭环学习、自进化 Skill、目标质量门和跨界面 Agent 后端 |
| 6 | LobeHub | 8 | 6 | 14 | 22 | 异构 Agent 托管、业务应用连接、Agent 调度与运营、白盒记忆、目标闭环与协作文档对象 |
| 7 | DeepChat | 5 | 11 | 16 | 21 | 可操控 Agent turn、ACP 运行时、IM 遥控、Tape & Trace、Skill 迁移和强审批绑定 |
| 8 | SillyTavern | 7 | 4 | 11 | 18 | 角色卡、World Info、提示词工程工作台、swipe、快捷动作和内容脚本 |
| 9 | OpenCode | 6 | 3 | 9 | 15 | 文件/Git 事实源、多表面会话、CodeMode、会话档案与 ACP 服务端 |
| 10 | Cherry Studio | 4 | 6 | 10 | 14 | 数据库消息树、Agent workspace、SDK Agent 会话、小程序、联邦搜索和持久翻译 |
| 11 | Pi | 4 | 3 | 7 | 11 | 追加型分支会话、终端组件树、项目文件 Agent 和研究数据生产 |
| 12 | AstrBot | 4 | 2 | 6 | 10 | 跨 IM 事件流水线、Agent Sandbox、主动 Agent、组件投影和语音管道 |
| 13 | Jan | 2 | 5 | 7 | 9 | 设备级本地推理器、隔离 Artifact、本地 Agent 编排与 CLI 外接 |
| 14 | Chatbox | 1 | 5 | 6 | 7 | 图像工作站与多项高级能力的稳健辅助实现 |
| 15 | DeepSeek Harness | 2 | 2 | 4 | 6 | 自引用插件运行时、日志化 plan mode、同会话目标驱动与定时重入 |
| 16 | Risuai | 1 | 4 | 5 | 6 | 模型指令标签驱动的角色媒体、多后端结构保留翻译、批量发送流水线、实时房间共享与 Risu Hub 角色市场 |
| 17 | NextChat | 0 | 3 | 3 | 3 | 轻量 fork、opaque-origin Artifact 与固定模板对话分享 |
| 18 | Manifold Desktop | 0 | 0 | 0 | 0 | 当前作为未闭合聊天主链的下限样本 |

排序先看产品特色点，再看主贡献数和覆盖功能族。分数相近不表示能力同质，例如 DeepChat 与 VCPChat 分别偏向可观测 Agent 会话和消息/桌面运行时，不能互相替代。

## 产品功能族明细

### 角色、上下文与长期认知

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F01 | 一体化 Agent 配方编辑：消息树、锚点、消息组、变量、资产和工具策略 | AIO Hub | LobeHub、SillyTavern | 把角色、上下文和工具配置收进同一编辑流程 |
| F02 | 可移植角色卡与社区资产兼容 | SillyTavern | AIO Hub、Risuai | SillyTavern 定义 PNG/CharX/BYAF 等角色内容生态；AIO 可导入 ST V2/V3 JSON/PNG、Context Preset、正则、快捷动作和嵌入式世界书并映射到自己的 Agent 对象。AIO 是跨格式汇入与可继续编辑的辅助形态，尚未复现酒馆全部扩展/事件协议。Risuai 以 Risu Hub 角色市场（浏览/下载/上传 + 资源服务器与账号体系）提供角色卡分发辅助形态，并兼容 Tavern V2/V3、PNG、JSON、CharX、Chub 等格式 |
| F03 | World Info / lore 条件触发与分层注入 | SillyTavern | AIO Hub | SillyTavern 定义完整 World Info 生态；AIO 有独立世界书管理/编辑/导入导出，并在真实请求中执行关键词/正则、selective、概率、扫描深度、过滤、递归、sticky/cooldown/delay、包含组和位置注入。部分字段只保留/编辑或降级映射，因此计可运行子集的辅助贡献，而非“仅兼容导入” |
| F04 | 可迁移且相互隔离的完整 Agent/Profile 运行环境 | Hermes Agent | AIO Hub、SillyTavern | Profile/包覆盖配置、技能、记忆或资产，而非单段 prompt |
| F05 | Persona、模型、知识、工具与访问控制合一的 Workspace Model | Open WebUI | LobeHub | 模型目录项同时成为多人工作区中的角色与权限对象 |
| F06 | 项目目录驱动的 Agent、提示词与 Skill 配置 | OpenCode、Pi | DeepChat | 配置随 cwd/项目文件加载，面向项目而非普通聊天预设 |
| F07 | 多角色群聊与长期 Topic 关系 | VCPChat | LobeHub | 角色关系和多 Agent 协作成为会话的一等结构 |
| F08 | 非对话时段自主整理记忆的 AgentDream | VCPToolBox | - | 后台完成抽种子、联想、生成、审批写回；当前默认禁用 |
| F09 | 可持久化的定时 Agent、后台任务与会话内重入 | Hermes Agent、LobeHub、VCPToolBox | DeepSeek Harness | 三个主贡献实现以 cron/interval/once 任务脱离前台执行并保留结果与历史；Hermes 的 heartbeat 还会定时重入当前会话。DeepSeek Harness 把 schedule 规则写入会话日志，到期且会话在线、Agent 空闲时投递普通回合，因无冷会话调度器和外部通知通道计辅助贡献；AstrBot 的 cron 已并入主动式 Agent，不重复计数 |
| F47 | 可编译、可调试的上下文 DSL 与提示词工程工作台 | AIO Hub、SillyTavern、VCPChat、VCPToolBox | - | 宏、预设、正则、TVS 均有持久对象、编译顺序并进入最终请求 |
| F63 | 闭环 Agent 学习与后台复习 | Hermes Agent | - | 按轮次或工具迭代 fork 复习记忆和技能并回写主环境 |
| F64 | Agent 自创建、改进和维护 Skill 的生命周期 | Hermes Agent | VCPToolBox | Hermes 覆盖 create/patch/归档、用量侧车和 curator；VCPToolBox 的 SkillBridge 提供目录扫描、元数据索引与按需展开，但不含自进化闭环 |
| F65 | 跨会话持久记忆与用户建模 | LobeHub、Open WebUI | Hermes Agent、SillyTavern | 结构化/文件记忆可提取、检索、编辑并进入后续对话 |
| F66 | 生成前自动召回与私人语义拓扑重排 | VCPToolBox | AIO Hub | SillyTavern 的 World Info/世界书建立了生成前条件注入范式；VCP 以日记占位符在请求前自动触发召回，再由 TagMemo/RiverMemo 完成上下文降噪、标签传播、候选拓扑读出、排序解释和作用域约束，使记忆成为每轮上下文环境而非仅供 Agent 选择的搜索工具。AIO Recall 参考 VCP 路线，以思绪集、可插拔候选模块、严格占位符、SQLite 真源和监控面形成独立产品化，计辅助贡献 |
| F102 | 可配置的逐阶段递归检索思考链与可迁移思维簇生态 | VCPToolBox | - | `[[VCP元思考:…]]` DSL 选择持久化链与语义簇，每一阶段检索结果的平均向量会与原查询融合，生成下一阶段查询；链配置、缓存、自动选链参数和 RAG Observer 事件形成独立于单次召回的执行与观察契约。公开第三方 VCP-Disco-Elysium-Mod 将 1 个启动簇、4 个属性域、24 个原子模块和语义组配置打包为可直接放入 `dailynote/` 的内容资产，并用 K 值定义认知构型，说明该契约可被外部作者复用。当前 VCP 快照只有 default 链，文档所称 `thinktheme/*.json` 未实现，运行效果未验证 |
| F73 | 神经云图与日记记忆工作台 | VCPChat | - | 将记忆网络、搜索、日记和可视化组织为独立用户工作台 |
| F82 | Agent 私有资产协议与作用域管理 | AIO Hub | - | agent-asset 协议把资产绑定 Agent，并贯通管理、宏注入和渲染 |
| F103 | 模型指令标签驱动的角色动态媒体 | Risuai | - | 模型回复后按情绪切换角色立绘：inlay 路径由模型直接输出 `<Emotion="…">` 指令标签并经解析器换图，普通路径走独立分类请求（LLM 示例分类或嵌入相似度检索）；群聊按视图模式分屏。与 SillyTavern 表达式系统（仅 `入口确认` 且依赖外部模块）相比形成本地完整闭环 |
| F106 | 可重放的会话级 plan mode | DeepSeek Harness | - | 规划状态以会话事件为唯一权威，可随恢复、分叉、压缩和多客户端重放；退出要求完整计划并经过用户审批，沙箱和工具审批仍由独立策略强制 |

### 会话演化、连续性与研究轨迹

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F10 | 持久消息树与活动分支指针 | Cherry Studio | AIO Hub、Jan、Open WebUI | 历史分支可保存、切换和恢复 |
| F11 | 单条回复候选、swipe 与版本导航 | SillyTavern | AIO Hub、Chatbox、Jan | 多个候选保留在同一语义位置供用户切换 |
| F12 | 多模型并行回复与并排比较 | Open WebUI | Cherry Studio、LobeHub | 同一请求生成多列或兄弟结果并提供专门投影 |
| F13 | 会话 fork、checkpoint 与 lineage | Hermes Agent、Pi | SillyTavern、DeepChat、NextChat、Open WebUI、OpenCode | 从历史点派生新会话并保留来源关系 |
| F14 | 压缩后仍可追溯原会话谱系 | Hermes Agent | Pi | compaction 产生新节点但不抹掉原 transcript 的寻址关系；gpt-5.6 直连 OpenAI 路由使用 native 服务端压缩，本地 compaction-as-fork 作为回退 |
| F15 | 跨会话消息全文检索并直达具体消息 | DeepChat | Chatbox | 搜索结果落到 message id，而非只打开会话 |
| F16 | 生成中的 steer、queue 与 pending input | DeepChat | Jan | Agent turn 未结束时仍可改变后续执行 |
| F17 | 跨 IM 平台事件流水线、群聊唤醒与 follow-up | AstrBot | - | 核心产品单位是平台事件和 UMO，而非桌面聊天窗口 |
| F27 | 多表面共享同一 Agent 后端与会话连续性 | Hermes Agent、OpenCode | Jan | 多前端消费同一事实源；OpenCode 支持重放与所有权接管；Hermes 桌面提供 HUD 浮动聊天窗（完整 renderer + 跨窗口草稿同步） |
| F44 | 可保存、观察和迁移的研究轨迹/会话档案 | OpenCode、DeepChat | Pi、Hermes Agent | 覆盖 Tape & Trace、导出脱敏、导入分享、数据生产与轨迹压缩 |
| F59 | IM 渠道远程控制本地 Agent 会话 | DeepChat | - | 远端命令与本地会话绑定、执行和结果投递形成闭环；CLI 本地控制平面（token 鉴权 + 审批 broker + detached runs）以同一“多表面连续性”标签并入本族，不重复计数 |
| F75 | 跨设备双向增量同步 | VCPChat | - | VCPMobileSync 用稳定身份、增量状态和删除传播同步产品数据 |
| F77 | 跨聊天消息转发与气泡附言 | - | VCPChat | 转发保持来源并允许附言，已闭环但独特性不足以单列首要参考 |
| F105 | 纯 P2P 实时共享角色与聊天 | - | Risuai | PeerJS WebRTC 房间码即 peer ID，共享当前角色与聊天、生成互斥检查、生成后广播；无鉴权/加密/持久化/撤销，断线即结束。作为"实时共享会话"的轻量旁路，与文件导出的快照语义形成两极 |

### 生成式输出、协作与创作表面

| ID | 产品功能族 | 主贡献 | 辅助贡献 | 计入理由 |
|---|---|---|---|---|
| F18 | 可执行消息小应用与消息运行时 SDK | VCPChat | AIO Hub | VCPChat 提供主消息 DOM 脚本与较完整宿主运行时治理；AIO 的 HTML/SVG 代码块可在 iframe 中执行 JavaScript、表单和 Canvas 小应用，Action Button 还能发送消息、插入文本或复制内容。AIO 已具备 iframe 型“消息即应用”，但宿主 SDK 与生命周期深度不足以并列主贡献 |
| F19 | 可持久、可查询、可替换的桌面挂件活对象 | VCPChat | - | 挂件有独立 ID、文件和能力桥，跨越单条消息生命周期 |
| F21 | 声明式 conversation-flow 与工具过程投影 | LobeHub | DeepChat、Cherry Studio | Agent 中间过程被编译成可操作流程 |
| F22 | 严格隔离的 HTML/SVG Artifact 预览 | Jan | NextChat、Chatbox、DeepChat、Open WebUI | 生成页面在独立运行域投影，不获得宿主同源权限 |
| F23 | 带文件树、编辑器、冲突检测和自动保存的 Agent workspace | Cherry Studio | AIO Hub、Hermes Agent | 用户直接维护模型生成的项目文件 |
| F24 | 文件/Git/diff 事实源与模型回读、回滚闭环 | OpenCode | LobeHub、AIO Hub、Pi、Hermes Agent、Chatbox | 模型下一轮继续操作同一工作区对象 |
| F25 | 文档对象级 diff、编辑锁与 Page-Agent | LobeHub | - | 文档有独立事实源、节点级修改和接受/拒绝流程 |
| F26 | Notebook、Pyodide、Jupyter 与 Terminal 执行表面 | Open WebUI | Cherry Studio | 代码输出成为可编辑、可运行的工作区 |
| F28 | 终端原生组件树、diff 预演和图片/ASCII 投影 | Pi | - | 在 ANSI 边界内形成完整 Agent 工作台 |
| F29 | 同一消息组件链投影到 WebChat 和多个 IM 平台 | AstrBot | - | 平台适配器把统一业务语义转换为不同消息能力 |
| F48 | 媒体生成与资产创作工作站 | AIO Hub、VCPToolBox、Chatbox | - | 覆盖生成、历史/资产持久化、编辑或插件化媒体工作流；正式类目见[媒体创作横向对比](媒体创作/媒体创作横向对比.md) |
| F49 | 中央资产导入、去重、索引与复用 | AIO Hub | - | 资产从字节导入到 SHA-256 去重、JSONL 索引和跨工作流复用 |
| F52 | 可分离窗口与跨窗口状态同步 | AIO Hub | - | 工具/组件可脱离主窗并保持逻辑状态同步 |
| F56 | 内嵌 Web 应用门户与小程序运行池 | Cherry Studio | - | 预设和自定义 Web 应用有 launchpad、侧栏与 keep-alive 生命周期 |
| F57 | 跨 Topic、Session 与消息内容的联邦全局搜索 | Cherry Studio | - | 应用级命令汇聚实体搜索与 FTS5 内容搜索，并支持分页定位 |
| F58 | 消息级流式翻译与译文持久化 | - | Cherry Studio、AIO Hub、Risuai | Cherry 以 `data-translation` part 持久并可重译覆盖；AIO Hub 以 `metadata.translation` 持久并支持原文/译文/双语显示切换，独特性中等。Risuai 以渲染链内嵌的结构保留翻译（DOM 遍历文本节点、超长分块拼接、LLM/DeepL/DeepLX/Bergamot/Google 多后端与预设、LLM 翻译缓存）构成相邻辅助形态 |
| F67 | Agent 运营汇报与版本化 Work 产物 | LobeHub | - | 任务结果沉淀为 Brief 分类、Inbox 汇报和独立 Work 对象 |
| F68 | 人类与模型共同参与的实时 Channels | Open WebUI | - | 频道、线程、反应、置顶和模型 @ 参与形成协作空间 |
| F69 | 与隐藏会话及工具互通的协作 Notes | Open WebUI | - | Note CRUD、Yjs 协作和模型读写工具构成独立文档工作区 |
| F81 | 人类工具箱、自动 GUI 与节点工作流编辑器 | VCPChat | - | manifest 转表单、专用面板和节点执行引擎形成可操作工具面 |
| F76 | LoomAPP 数据驱动创作运行时 | VCPChat | - | 前端插件可承载独立交互与数据可视化创作应用；Loom v1.4.0 与 VCP Agent WebCore 支持页面快照（Grounded Markdown）、页面图片、标准动作执行和串行指令协议 |
| F88 | 百万字符长文本分片翻译与上下文继承 | - | AIO Hub | 递归分片、并发限流、相邻片段上下文和精确 Token 预算闭环，但不单独定义客户端身份 |
| F89 | 内置弹幕播放与第三方播放器透明覆盖运行时 | AIO Hub | - | 多格式解析、虚拟时钟、HWND 跟随、DPI/Z-Order 同步和高保真字幕降级链形成独立桌面产品面 |
| F90 | Agent 可控的本机 Hi-Fi 播放子系统 | VCPChat | - | 自研 DSP/WASAPI 引擎、WebDAV 曲库、桌面挂件、歌词与对话点歌贯通 |
| F91 | 系统级划词感知与旁路 Agent 对话 | VCPChat | - | Rust sidecar 捕获任意应用选区，经悬浮动作条进入真实 Agent 话题并可回存笔记 |
| F92 | 双语切片、双模型分流与自动朗读语音链 | VCPChat | - | 混合语言文本按片段分流到两个 TTS 模型，并由前端插件自动朗读和缓存 |
| F93 | 桌面 RAG 信息流监听与工具审批浮层 | - | VCPChat | 独立透明窗口持续展示后端信息流并可批准或拒绝工具，但依赖外部 VCP 后端 |
| F94 | Agent 可调用的 3D 物理骰子 | - | VCPChat | ammo.wasm 物理投掷和结果回传形成闭环，产品面较窄且无持久对象 |
| F97 | 项目实体与项目协调 Agent | - | LobeHub | 独立项目实体（数据表、tRPC 管理接口和 CLI 命令）+ 按项目名生成协调者内置 Agent，与按工作目录的话题分组并存；辅助贡献（主链确认） |
| F98 | 人机共笔文档工作台（VDOC 工程 + 文脉 PR 审批） | VCPChat | - | VDOCX/VPPTX 工程、人类直编渲染版式、Agent 以可审阅 PR（pending/applied/rejected/conflict）协作编辑源码，文脉带版本快照与审批回执（主链确认） |
| F101 | 可编排、可迭代的对话分享稿工作台 | AIO Hub | NextChat | AIO Hub 把消息选区、视觉编排、实时预览、逐消息捕获拼接和多结果运行时历史组成独立交付表面；NextChat 以任意选消息、Mask context 和固定品牌模板补充轻量形态 |
| F104 | 按文件类型分派的批量发送流水线 | - | Risuai | Multisend 按文件类型分派：`.po` 逐条翻译流水线、pdf/txt/xml 本地嵌入检索后剪裁发送、媒体存 inlay 资产；主链已闭合，但批量发送本身更接近输入侧增强，独特性不足以定义产品身份 |

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
| F62 | DeepLink 外部启动与配置协议 | - | DeepChat | deepchat 协议可启动会话、安装 MCP 或配置 Provider |
| F74 | 托管浏览器观察、控制与验证运行时 | VCPToolBox | - | managed Chrome 具生命周期、协议、脱敏、验证和指标闭环；默认关闭。2.4 支持正文图片 IMG* 语义、`get_page_image` 和 Popup 人工 Managed 选择，agent 不隐式控制托管运行时 |
| F78 | 跨节点文件透明获取与取消传播 | VCPToolBox | - | 来源绑定、缓存、循环保护、断线清理和 cancel_tool 形成分布式文件面 |
| F79 | 文件事实源的 Agent 论坛与异步协作 | VCPToolBox | VCPChat | 后端以 Markdown 帖子形成可持久协作空间，VCPChat 提供隔离渲染的论坛客户端 |
| F80 | 长任务异步回调与结果回注会话 | VCPToolBox | - | 插件先返回任务句柄，完成后把结果重新注入原会话 |
| F84 | 多仓库 Git 工作台与 AI 提交草稿 | - | AIO Hub | diff 审查、暂存、批量仓库操作和 LLM 提交信息闭环完整，但仍是成熟开发工具的 AI 增强形态 |
| F85 | 带身份、配方、反检测代理和 API 嗅探的网页蒸馏 | AIO Hub | - | 网页读取被组织为可交互、可复用且可供 Agent 调用的独立浏览产品面 |
| F86 | 具子流程、变量作用域、条件跳转和 OCR 的桌面 RPA 语言 | AIO Hub | - | 窗口操作从录制回放提升为可持久、可组合的小型流程语言 |
| F87 | 屏幕区域持续 OCR、字幕合并与聊天回注 | AIO Hub | - | 高频截屏、帧去重、字幕时间轴、SRT 导出和跨窗口回注形成连续工作流 |
| F95 | 多观点 Agent 会议与主持综合 | VCPToolBox | - | 多角色并行作答、主持人综合和结构化会议信息构成区别于普通子 Agent 委托的审议形态 |
| F96 | 带验收、质量门或阻塞判定的有界目标闭环 | LobeHub | DeepSeek Harness、Hermes Agent | LobeHub 以持久任务对象、验收标准、轮次与花费双上限定义完整产品面。DeepSeek Harness 在同一会话中以事件溯源目标、严格 revision、轮次上限和连续阻塞阈值自动续跑；Hermes 在候选完成时增加 judge 与确定性命令质量门。两者均形成关键辅助形态，但未取代 LobeHub 的任务、验收和界面闭环 |
| F99 | 异构外部 Agent runtime 的发现、托管与会话续接 | LobeHub | DeepChat、Cherry Studio | LobeHub 统一多种 CLI/平台任务的发现、原生会话、工作目录、事件投影、干预与取消；DeepChat 补 ACP runtime 安装和会话，Cherry Studio 补 Claude Agent SDK 会话与工作区 |
| F100 | 业务应用账号连接、作用域与逐动作治理 | LobeHub | - | Connector/Composio 把外部账号、凭据、工具目录和 `auto / needs_approval / disabled` 权限组织成可持久协作对象，不是普通 MCP 或单次 API 调用 |
| F107 | Agent 自检查、定义和管理自身插件运行时 | DeepSeek Harness | - | 模型可查询当前 Cordis 服务目录，定义 host/browser 插件包并在同一进程运行、停止或删除；定义仅会话可见且重启即失，Node vm 明确不是安全边界，但从检查到删除的主链完整 |

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
| F108 | 独立端口透明 API 代理、前端劫持与 Prompt 夺舍 | VCPToolBox | - | 独立透明代理（端口 3100）支持 replace/prepend/append/merge 四种夺舍模式、模型改写与多 Profile 动态路由 |

## 机制贡献统计

机制贡献不参与产品特色点。这里记录跨能力复用、可明显改变安全性、可靠性或可恢复性的实现原型。

| ID | 机制贡献族 | 主参考 | 辅助参考 | 形成的边界或价值 |
|---|---|---|---|---|
| M01 | 保留富节点状态的稳定前缀流式更新 | AIO Hub | VCPChat、LobeHub | 避免累计全文重画，保留焦点、动画和已完成节点状态 |
| M02 | 具作用域、可复用或可恢复的工具审批策略 | DeepChat | Chatbox、Jan、Cherry Studio、Hermes Agent、LobeHub | 审批绑定会话、参数、命令、server 或持久策略 |
| M03 | Agent 循环步数、超时、重复守卫和大结果落盘 | AstrBot | Hermes Agent、OpenCode、Cherry Studio | 限制失控循环并把长结果转成可寻址对象；Cherry Studio 普通聊天工具轮次上限默认 100 |
| M04 | 多来源统一工具注册、过滤与校验 | OpenCode | AIO Hub、AstrBot、DeepSeek Harness、Hermes Agent、Open WebUI、Jan | 内置、Plugin、MCP、Skill 共用发现和执行边界；DeepSeek Harness 以 Service Definition、Provider、Consumer 三角色拆分模型契约与可替换实现 |
| M05 | 跨进程、远端节点和多协议插件执行 | VCPToolBox | VCPChat、AIO Hub | 工具运行位置离开当前客户端，并由协议和节点编排 |
| M06 | 请求、Key、模型与 Provider 分层故障转移 | Hermes Agent | - | 失败后逐层改变目标，形成完整静态 fallback 链 |
| M07 | Key 健康状态、冷却与当前请求换 Key | AIO Hub | AstrBot、Jan | Key 成为带失败状态和选择逻辑的资源池 |
| M08 | 事件日志、重放与单写所有权 | OpenCode | DeepSeek Harness | OpenCode 为跨设备会话提供全序事件、断点恢复和显式写所有权；DeepSeek Harness 以 append-only 会话日志作为模型历史、请求快照和插件状态的唯一持久权威，进程内状态只保留可弃投影 |
| M09 | 沙箱策略、预算与路径或进程隔离 | OpenCode、AIO Hub、AstrBot、DeepSeek Harness | - | 限制代码、Skill、计算机或子进程的能力、时间、输出和文件范围；DeepSeek Harness 按调用携带 read-only/workspace-write 策略，经 Linux、macOS、Windows 原生后端 fail-closed 执行并如实上报 full/partial enforcement |
| M10 | 原子同步、墓碑删除与稳定哈希 | VCPChat | - | 降低跨设备增量同步中的冲突、复活和身份漂移 |
| M11 | 资产/文件内容寻址、缓存与取消传播 | AIO Hub、VCPToolBox | - | 以哈希去重或来源绑定管理大文件和远端结果生命周期 |
| M12 | 插件桥 IPC 白名单与挂件资源治理 | VCPChat | - | 限制路径和命令，并清理监听器、定时器与不可见挂件资源 |
| M13 | Rust/Rayon 原生记忆内核与可解释排序 | VCPToolBox | - | 把大规模语义计算下沉，同时保留排序结果和解释面 |
| M14 | Tokenizer 资产注册、多模态计费与全局预算服务 | AIO Hub | - | 为上下文截断、压缩、预览、检查和长文翻译提供统一的精确预算依据 |
| M15 | 多引擎共享 OCR 平台与跨工具复用 | AIO Hub | VCPChat | OCR 引擎、Profile 与执行入口被字幕、转写、窗口自动化或桌面感知工作流共同消费 |
| M16 | 备份/恢复覆盖主数据库并做写方排空 | Cherry Studio | - | 备份 v7 full/slim 双布局均含 `cherrystudio.sqlite`，恢复经 checkpoint + 崩溃安全 promotion 门原子替换，备份前对写方 quiesce（已接通） |
| M17 | JSONL 原子发布与 torn-tail 修复 | Pi | - | 整文件临时文件 + 原子 rename 发布，fork 与 torn-tail 截断共用同一原子路径，同 cwd+id 并发 create/fork 拒绝 |
| M18 | 同权限候选域的多检索构型对照 | VCPToolBox | - | LightMemo 让 KNN、TagMemo V9、RiverMemo Topology V3 共用 SQL 作用域、查询向量和候选事实域，输出三组 Top-K 重合率与统一排名；它验证和调优记忆寻址，不另算一种用户记忆能力 |
| M19 | 双层安全模型的插件运行时沙箱 | Risuai | - | v3.0 插件在 CSP 隔离 iframe（sandbox 仅放行 allow-scripts/allow-modals/allow-downloads、`connect-src` 置 `'none'`）内经 postMessage RPC 运行，含 SafeDocument/SafeElement 包装、流桥、AbortSignal 转发与热重载；v2.1 走 AST 静态检查与符号改写。为浏览器端插件扩展提供可复制的权限切分原型 |
| M20 | 可重放的子 Agent 委派策略与多 Provider 能力缝 | DeepSeek Harness | - | 一个委派契约承接同进程 spawn/fork 与进程外 ACP、Claude Code、Codex、dsh SDK；父沙箱快照、子审批恒拒和 delegation scope 以事件写入子会话，可冷恢复且不能由子 Agent 扩权 |

明确不计分：AIO Hub 的内容查重器属于性能/工程增强；VCPChat 的普通笔记、翻译窗、语音聊天和运维面未形成足够不同的产品契约。VCPChat DeepMemo 2.0 已闭合“可信 Agent/Topic 上下文 → 中央聊天历史搜索 → 窗口扩展/可选精排 → 回注”的主动会话回忆链，但其产品契约仍属于常规历史 RAG 工具；这里把它记入 VCP RAG 能力地图，不另立特色族。VCPToolBox 的 VCPEverything、VCPClawMail、DigitalOracle、DeepWikiVCP 与 UserAuth 分别属于常规本机检索/邮箱接入、领域数据聚合、单一 MCP 客户端和安全支撑机制。DeepSeek Harness 的 ACP 服务器、MCP 工具桥、通用子 Agent 能力和进程沙箱分别属于既有互操作能力或机制贡献，不因 Provider 数量和主链闭合另加产品分；仅达到入口确认的 workflow/jobs、bundle patch-layer、运行时 invariants 和 e2b POC 也不计入。Pi 的 sqlite FTS 搜索后端（harness 侧、未接入 TUI/AgentSession 路径）、Pi `auth check`（运维机制）、opencode 压缩文本序列化与重试上限（工程细节）、Hermes 紧急停止 `hermes pause/resume`（安全机制）同样不计分。它们的实现完整度仍记录在单项目笔记中，但不转化为特色点。

## 如何解读结果

### 1. 宽贡献和尖贡献分开看

- AIO Hub、VCPChat、Open WebUI、Hermes Agent、DeepChat 覆盖功能族多，适合作为组合架构或产品面的主干参考；DeepSeek Harness 覆盖较窄，但在自引用运行时、日志化协作状态和执行域机制上更尖锐。
- VCPChat、VCPToolBox、SillyTavern、OpenCode、Pi、DeepSeek Harness 主贡献比例高，适合寻找明确的产品差异点。
- Chatbox、Cherry Studio、Jan 有较多成熟实现；Chatbox 更偏把高级能力做稳，Cherry 和 Jan 各有消息树/workspace、本地推理器两个清晰主轴。

### 2. 产品特色点不是质量分

VCPChat 的可执行消息、SillyTavern 的内容脚本、VCPToolBox 的分布式插件和 OpenCode 的可编程工具编排都扩大了安全或维护边界。特色统计只说明能力少见，不说明应原样复制。工程、安全与可恢复性仍应回看[AI 客户端项目评分](AI客户端项目评分.md)和上面的机制表。

### 3. 项目边界会影响结果

AstrBot、DeepSeek Harness、OpenCode、Pi、VCPToolBox 本来就不以普通桌面 Chat 为边界，去掉聊天底座后反而更显出贡献。[Manifold Desktop 专项复核](独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)已确认其 0 分不是覆盖不足：当前 HEAD 的基础 Chat、MCP、插件和持久化主链均未闭合。

## 与综合评分的差异

现有[AI 客户端项目评分](AI客户端项目评分.md)回答“一个完整客户端是否成熟、均衡、可控”；本文回答“若拿掉大家都有的底座，这个项目还留下哪些值得组合的产品能力”。

| 观察角度 | 更看重什么 | 容易上升的项目 |
|---|---|---|
| 综合评分 | 完整性、工程、安全、恢复、常见主链 | DeepChat、Hermes Agent、Cherry Studio、LobeHub |
| 产品特色贡献 | 独特工作流、生态契约、运行时形态、产品辨识度 | AIO Hub、Hermes Agent、Open WebUI、VCP 系、SillyTavern、OpenCode、DeepSeek Harness |
| 机制贡献 | 跨能力复用、安全、可靠性、可恢复性 | OpenCode、Hermes Agent、AIO Hub、VCP 系、DeepChat、DeepSeek Harness |

## 依据索引

- [独特功能调查指南](独特功能/调查指南.md)
- [独特功能待查清单](独特功能/待查清单.md)
- [AIO Hub 独特功能调查笔记](独特功能/AIO-Hub-独特功能调查笔记.md)
- [VCPChat 独特功能调查笔记](独特功能/VCPChat-独特功能调查笔记.md)
- [VCPToolBox 独特功能调查笔记](独特功能/VCPToolBox-独特功能调查笔记.md)
- [Risuai 独特功能调查笔记](独特功能/Risuai-独特功能调查笔记.md)
- [DeepSeek Harness 独特功能调查笔记](独特功能/DeepSeek-Harness-独特功能调查笔记.md)
- [DeepSeek Harness 已调查能力汇总](已调查能力汇总/DeepSeek-Harness-已调查能力汇总.md)
- [VCP-Disco-Elysium-Mod（公开第三方思维簇模组）](https://github.com/biyuqingtan-lab/VCP-Disco-Elysium-Mod)
- [上下文编译与提示词工程边界研究](独特功能/上下文编译与提示词工程边界研究.md)
- [Agent 角色横向对比](Agent角色/Agent角色横向对比.md)
- [Agent 工具横向对比](Agent工具/Agent工具横向对比.md)
- [会话与消息管理横向对比](会话与消息管理/会话与消息管理横向对比.md)
- [对话请求与上下文横向对比](对话请求与上下文/对话请求与上下文横向对比.md)
- [Chat UI 横向对比](<Chat UI/ChatUI横向对比.md>)
- [LLM 渠道管理横向对比](LLM渠道管理/LLM渠道管理横向对比.md)
- [消息渲染器横向对比](消息渲染器/消息渲染器横向对比.md)
- [生成式输出与运行时横向对比](生成式输出与运行时/生成式输出与运行时横向对比.md)
- [媒体创作横向对比](媒体创作/媒体创作横向对比.md)
- [外部执行体与应用协作横向对比](外部执行体与应用协作/外部执行体与应用协作横向对比.md)
- [对话图片分享生成局部横向对比](对话导出与分享/图片分享生成局部横向对比.md)
- [应用界面基础设施横向对比](应用界面基础设施/应用界面基础设施横向对比.md)
