# VCPToolBox 独特功能与项目状态调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：只读源码梳理，并与 Agent 工具、Agent 角色、LLM 渠道三份旧快照笔记交叉核对；逐个候选走通“入口 → 状态/对象 → 执行 → 结果 → 持久化”主链；另做插件目录全量盘点（89 个插件目录逐一核对 manifest 与入口文件），修正 3 处细节并补充 8 项新能力卡；在 `c4c4d00`→`1ae9b63c` 范围核对 ChromeBridge 2.4（能力六正文图片语义、Popup 人工 Managed、agent 不再隐式控制托管运行时）、插件清单状态（89 目录/69 启用/20 禁用不变）与 Plugin.js 行号；全部为静态证据，未运行验证
>
> 调查范围：待查清单中 VCPToolBox 的 16 项候选能力；普通 Chat 底座与已被现有通用类目完整覆盖的能力只做归并引用
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 是 VCP 系的服务端中间层（工具执行器、记忆/上下文引擎、分布式桥），本身不提供对话 UI。去除普通 Chat 与通用 Agent 底座后，本轮确认 **18 项达到 `主链确认` 的独特能力族**（其中 8 项来自插件目录盘点补充）、1 项 `入口确认`、若干归并项：

| 能力族 | 状态 | 标签 | 备注 |
|---|---|---|---|
| TagMemo 浪潮 + RiverMemo 拓扑 V3 记忆语义动力学 | `主链确认` | 记忆演化 | 写入/索引/查询/排序/解释/更新全链，排序内核在 Rust |
| 元思考递归推理链（VCP元思考） | `主链确认` | 记忆演化/上下文语言 | 触发 DSL、链配置、语义组、结果注入已走通；`thinktheme/*.json` 属文档声明未见实现 |
| AgentDream 非对话记忆整理 | `主链确认` | 记忆演化/主动 Agent | 默认禁用；审批执行链在管理路由；无预算、无进行中取消 |
| TVS 占位符上下文语言 + PlaceholderExplorer 调试面 | `主链确认` | 上下文语言 | Agent/Toolbox 守卫、递归解析、死链检查、编辑回滚 |
| 六类插件协议与异步任务回注 | `主链确认` | 创作工作站/主动 Agent（支撑） | 长任务先返回、回调后回注；`/plugin-callback` 仍无鉴权 |
| 浏览器托管运行时（managed Chrome + 协议 v3） | `主链确认` | 人类工具面/活对象 | 生命周期、观察/控制/验证/脱敏/指标全链；2.4 新增正文图片语义与 Popup 人工 Managed 选择；运行时默认关闭 |
| 跨节点文件透明获取与取消传播 | `主链确认` | 分布式多模态 | 来源绑定、缓存、循环保护、断线清理、cancel_tool |
| TaskAssistant 定时/手动任务派发 | `主链确认` | 主动 Agent | interval/cron/once/manual、历史与结果归属、无进行中取消 |
| VCPForum 文件事实源社区 | `主链确认` | Agent 社会 | 帖子=Markdown 文件；Agent 可发帖/回复；无用户治理机制 |
| 多媒体生成与媒体插件族 | `主链确认` | 创作工作站 | MediaRenderer 渲染/动画/程序音乐 + 图像/视频生成族；统一 VCP 块协议 |
| LightMemo 轻量记忆检索与生产构型 A/B 对照 | `主链确认` | 记忆演化 | 复用 RAGDiaryPlugin 索引/Rust 引擎；KNN/TagMemo V9/RiverMemo V3 三轨同域 A/B 重合率对照 |
| VCPEverything 本地全盘文件检索 | `主链确认` | — | Everything HTTP 服务桥，毫秒级全盘搜索 |
| SkillBridge 技能目录索引 | `主链确认` | 自进化 Skill | 启动扫描 SKILL/ 生成 vcp_fold 折叠技能索引 `{{VCPSkillBridge}}`；Ink 模式读取工作流约定 |
| MagiAgent 多观点会议 | `主链确认` | Agent 社会 | 三贤人独立 LLM 辩论、异步查询、`{{VCP_ASYNC_RESULT}}` 回注 |
| VCPClawMail 邮箱轮询与投递 | `主链确认` | 主动 Agent | 常驻轮询 + WS 即达、`{{VCPClawMailInbox}}` 注入、子邮箱→Agent 自动投递 |
| UserAuth 管理员认证码 | `主链确认` | 支撑机制（安全） | 每小时 6 位码经 code.bin 注入 `DECRYPTED_AUTH_CODE`，requireAdmin 工具消费 |
| DigitalOracle 金融数据聚合 | `主链确认` | — | 15 个 Provider 宏观/利率/加密/预测市场/期权；全局宏面板并发聚合 |
| DeepWikiVCP 仓库文档 MCP 客户端 | `主链确认` | — | 全仓库唯一 MCP-over-HTTP 客户端；结构/内容/问答/Deep Research/多仓库 |
| 人类直接调用工具 API（/v1/human/tool） | `入口确认` | 人类工具面 | 有鉴权与全审批链，VCPToolBox 内无独立产品 UI |
| OneRing / 时间线 / ContextFolding | `归并已有类目` | — | 上下文编排，归并入“对话请求与上下文”笔记 |
| 语义虚拟模型路由 | `归并已有类目` | — | 归并入“LLM 渠道管理”笔记；README“容灾”=模型级 fallback |
| OpenAI/Anthropic/Gemini 协议桥 | `归并已有类目` | — | 归并入“LLM 渠道管理”笔记 |
| AgentAssistant 多 Agent 通信 | `归并已有类目`（保留跨 Agent 长期通信局部） | Agent 社会 | 委托/即时通讯已覆盖；跨 Agent 上下文 TTL 与心跳留卡片局部 |
| 管理面板、系统监控 | `归并已有类目` | — | 普通后台管理；占位符浏览器并入 TVS 能力卡 |

关键边界：VCPToolBox 的能力高度依赖**用户配置**（`config.env`、`agent_map.json`、插件 `config.env`、`toolApprovalConfig.json`），大量机制默认关闭或默认禁用（AgentDream 插件 `.block`、`VCP_BROWSER_RUNTIME_ENABLED=false`、`ReasoningToContentEnabled=false`、`privacyProtection.enabled=false`、TaskAssistant `globalEnabled=false`）。因此“主链确认”指的是**在默认配置或文档说明的配置下代码链路完整存在**，不代表开箱即用。盘点补充的 8 项插件同样依赖外部条件（VCPEverything 需本机 Everything HTTP 服务、VCPClawMail 需 ClawMailKey、DeepWikiVCP/DigitalOracle 需网络与上游服务），属配置可用而非默认可用。

## 介绍声明与候选盘点

候选来源为 README（工具系统 / 记忆与认知 / 模型路由 / 变量系统 / 分布式与容灾五段旗舰声明）、`docs/FEATURE_MATRIX.md`、`docs/TECHNICAL_LITE.md`、`docs/vcp白皮书V3.md` 与插件目录盘点，共 16 项，与待查清单 VCPToolBox 段一致。逐项调查结果见下两节；其中“系统监控/管理面板”类声明（PM2 进程、资源监控、日志查看）经确认属于普通后台管理，未形成独立能力卡。

插件目录全量盘点：`Plugin/` 下 89 个插件目录均持有 `plugin-manifest.json`（69 启用）或 `plugin-manifest.json.block`（20 禁用），无异常目录，与上表口径一致；除 16 项候选外，另确认 8 个功能独特、既有笔记零覆盖的插件（LightMemo、VCPEverything、SkillBridge、MagiAgent、VCPClawMail、UserAuth、DigitalOracle、DeepWikiVCP），已补入下节能力卡；其余插件（搜索/天气/日程/抓取/查询/图像类）归普通工具类目，仅记清单。

## 已确认的独特能力

### 能力一：TagMemo 浪潮语义动力学 + RiverMemo 拓扑 V3（记忆与语义动力学）

**用户目标**：让 AI 的长期记忆按"语义相关性"而非关键词召回，并在多轮对话中维持可解释的排序；解决普通 RAG"标签连线直连"式联想在复杂关系下失真的问题。

**入口与触发者**：模型/用户在系统提示词里写 `[[日记本名::Group::Time::…]]`、`《《日记本…》》`、`{{日记本…}}` 等占位符；`RAGDiaryPlugin` 以 `messagePreprocessor` 身份在请求管线中扫描 system 消息（`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1492-1508`，注册于 `Plugin.js:903`）。

**事实对象**：`dailynote/` 下的 Markdown 日记文件（`DailyNote`/`DailyNoteManager` 插件写入，路径安全校验在 `routes/dailyNotesRoutes.js`），向量与标签索引落 SQLite + `rust-vexus-lite` 原生引擎。

**完整主链**：
1. 写入：`DailyNoteWrite` → 文件落盘 → `KnowledgeBaseManager.runExternalFileMutation()`（FIFO 队列后台索引，`Plugin/DailyNote/dailynote.js:44-45`）；
2. 索引：`KnowledgeBaseManager` 维护向量库、标签曲线与派生资产（`KnowledgeBaseManager.js:234 initialize` 起）；
3. 查询：`vectorDBManager.search()`（`KnowledgeBaseManager.js:888`）按 diary 名、query vector、tag 权重召回；
4. 排序：`prepareUnifiedMemoObservation`（:1196）→ `applyTagBoostAsync`（:927，浪潮传播）→ `rerankWithRiverMemoAsync`（:1863）调 Rust 内核 `rerank_rivermemo_topology_v3()`（`rust-vexus-lite/src/rivermemo_topology_v3.rs:2777`）完成查询降噪、守恒传播、双尺度场、候选曲线读出、相对拓扑、Ω 泛函与 Direct Anchor 的批级排序；JS 侧 `modules/tagmemoV10/` 各模块保留为实验/只读路径，生产排序在 Rust/Rayon 单次 N-API 边界内完成（`RiverMemoEngine.js:467 rerank`，文档 `docs/RIVERMEMO_TOPOLOGY_V3.md`）；
5. 解释：结果携带 `riverMemo` 元数据（`artifactSig`/`omega`/`regime`/`role`/`topologyBonus`/`anchorBonus`，`RAGDiaryPlugin.js:3282-3290`），VCP Info 广播与 `RAG_Observer` 调试页可观察各阶段；
6. 更新：`TagMemo` 标签热更新、`applyTagConsistencyPreview`（`KnowledgeBaseManager.js:1938`）批量一致性修复、日志更新时增量重索引。

**持续性**：向量库与标签索引持久化于 SQLite/`VectorStore`；重启后按 Artifact 签名缓存重建（`RiverMemoEngine.js` 签名缓存）。

**主动性与取消**：被动召回为主；召回是请求内同步计算（Rust 异步任务不阻塞事件循环），无独立取消语义；可被请求中断级联（AbortController）终止。

**人机与多 Agent 关系**：管理面板提供 RAG 参数、标签一致性预览/应用、语义组编辑器；`SemanticGroupEditor`/`ThoughtClusterManager` 插件允许 AI 维护记忆分组。

**外部依赖与执行域**：Embedding 依赖上游 API（同一 `API_URL`+`API_Key`）；向量计算在本机 Rust addon；日记文件在本机 `dailynote/`。

**安全与资源边界**：日记检索受 diary 名作用域约束，RiverMemo 排序阶段显式传 `allowedFileIds`（按 diary_name 从 SQLite 取文件 ID，`RAGDiaryPlugin.js:3217-3233`）并声明 `visibilityMode:'explicit_sql_scope'`；跨用户记忆默认不互见（`allowPublic:false`）。

**独特性判断**：普通 RAG 类目（知识库/向量检索）只覆盖"检索"子链；这里把"写入—传播—排序—解释—一致性修复"做成同一条可解释数学链，且排序内核以 Rust/Rayon 单次边界交付，是目前样本中唯一的此类实现。同一记忆栈的轻量独立消费端与多构型 A/B 对照测量面见能力十二（LightMemo）。

**证据强度**：源码事实（主链各环均有明确符号与文件）；排序质量与数值行为未运行验证。

### 能力二：元思考递归推理链（VCP元思考）

**用户目标**：把"信息检索"升级为"多阶段结构化思考"——按链定义逐簇召回元逻辑模块，用上一阶段结果改变下一阶段查询方向。

**入口与触发者**：system 消息中的占位符 DSL `[[VCP元思考:<链名>::<修饰符>:<k1-k2-k3-k4-k5>]]`，由 RAGDiaryPlugin 在 `_processSingleSystemMessage` 中解析（`RAGDiaryPlugin.js:1495-1607`）；修饰符支持 `Group`（语义组增强）、`Auto[:阈值][:白名单|!黑名单]`（按主题向量自动选链）。

**事实对象**：`dailynote/` 下的思维簇目录（`前思维簇`、`逻辑推理簇`、`反思簇`、`结果辩证簇`、`陈词总结梳理簇`），每簇多个 `.txt` 元逻辑模块；链定义在 `Plugin/RAGDiaryPlugin/meta_thinking_chains.json`（当前只含 `default` 链，簇数=5，kSequence=[2,1,1,1,1]）。

**完整主链**：解析 DSL → `MetaThinkingManager.processMetaThinkingChain()`（`Plugin/RAGDiaryPlugin/MetaThinkingManager.js:108`）→ 每阶段 `vectorDBManager.search(clusterName, currentQueryVector, k)` → 取结果向量平均后与原始查询向量按 `metaThinkingWeights`（默认 `[0.8,0.2]`）融合为下一阶段查询向量 → 全部阶段完成后格式化文本替换占位符注入上下文 → 结果缓存（按链名+k 序列+内容哈希）→ VCP Info 广播 `META_THINKING_CHAIN` 供 `RAG_Observer.html` 实时查看。

**持续性**：链配置与主题向量缓存持久化（`meta_chain_vector_cache.json`，按链配置哈希失效）；召回结果按内容缓存。

**主动性与取消**：请求内同步链式计算，无独立取消；未发现 Token 预算。

**人机与多 Agent 关系**：用户/模型通过占位符参数控制链名、Group、Auto 阈值与范围；语义组编辑器可维护增强向量。

**外部依赖与执行域**：Embedding 走上游 API；检索在本机向量库。

**安全与资源边界**：簇名来自配置而非用户输入，k 值受配置约束；召回文本为本地日记内容。

**独特性判断**：它是"提示词 DSL 触发的多阶段递归 RAG"，与普通单次 RAG 召回是不同产品契约；无额外 LLM 调用（纯向量递进），成本可控。

**证据强度**：源码事实；文档与实现有一处出入——`docs/FEATURE_MATRIX.md` 声称主题配置位于 `thinktheme/*.json`，仓库中**未找到**该目录，实际主题仅来自 `meta_thinking_chains.json` 的非 default 链条目（当前只有 default，故 Auto 模式无可切换主题，只能回退默认链）。

### 能力三：AgentDream 非对话记忆整理（梦系统）

**用户目标**：让 AI 在非对话时段回顾记忆、生成意识流叙事，并产出需要人工审批的记忆整理操作（合并/删除/感悟），把"记忆维护"从用户手动操作变成 Agent 主动工作流。

**入口与触发者**：定时调度器（每 15 分钟检查，时间窗默认 1-6 点、概率掷骰默认 0.6、冷却与频率默认 8 小时，`AgentDream.js:755-870`）或手动 `triggerDream` 工具调用；当前快照插件为 `plugin-manifest.json.block`（**默认禁用**）。

**事实对象**：`dailynote/` 日记 + `dream_logs/*.json`（梦操作记录与梦会话日志）。

**完整主链**：入梦 → `DreamWaveEngine.generateDreamWave()`（涟漪浪潮联想，recent/mid/deep 三层种子与关联）→ `dreampost.txt` 提示词 → 调 VCP `/v1/chat/completions` 生成叙事 → 叙事+记忆树持久化 `dream_logs` → 梦中可发起 `DiaryMerge`/`DiaryDelete`/`DreamInsight`（串语法批量，读取源日记全文入记录）→ 操作以 `pending_review` 状态写 JSON 并广播 → 管理员在管理面板通过 `routes/admin/dream.js` 审批：approve 执行（合并经 `DailyNoteWrite` 插件写新日记并删除源文件+向量条目；删除直接 unlink+`removeDocument`；感悟写 `[xx的梦]xx` 署名日记），reject 只改状态。

**持续性**：梦上下文按 `contextTTLHours`（默认 4 小时）与 6 轮（12 条）裁剪，存内存 Map；梦操作与叙事落盘 `dream_logs/`，重启后管理面板可继续审阅。

**主动性与取消**：完全主动（无人消息也可入梦）；**未找到预算机制**（无 token/次数上限）与**进行中梦境取消**（只在梦境进行时跳过下一轮触发）；唯一可终止手段是禁插件/杀进程。

**人机与多 Agent 关系**：人=审批者（可拒绝或修改决策）；无 Agent 间共享梦境。

**外部依赖与执行域**：叙事生成依赖上游 LLM；记忆检索走本机向量库。

**安全与资源边界**：所有破坏性操作（删除日记、合并覆盖）必须经审批执行；审批端点位于受 Basic Auth 保护的管理 API。注意：AgentDream 插件自身导出的 `approveDreamOperation`/`rejectDreamOperation` 是 `not_implemented` 占位（`AgentDream.js:995-1001`），执行权实际完全在管理路由——若管理路由被移除则该链断裂。

**独特性判断**：与普通"记忆总结"不同，它是一个**主动的、叙事化的、带人工审批闸门的记忆维护循环**，在样本中无近似实现。

**证据强度**：源码事实；梦境叙事质量、浪潮联想在真实库上的效果未运行验证。

### 能力四：TVS 占位符上下文语言 + PlaceholderExplorer 调试面

**用户目标**：用系统提示词里的占位符声明"该 Agent 应知道什么、能用什么工具"，前端零开发；并提供可搜索、可编辑、可验证死链的调试/管理面。

**入口与触发者**：`modules/messageProcessor.js` 的 `resolveAllVariables`（:146）在每次请求前对 system/特权 user 消息做多阶段替换。

**事实对象**：占位符家族——`{{VarXxx}}`/`{{TarXxx}}`（env 变量，可指向 `TVStxt/*.txt` 递归解析）、`{{SarPromptN}}`/`{{SarPromptAll}}`（模型级 SAR 注入）、`{{agent:X}}`/`{{X}}`（Agent 文件嵌套）、`{{toolbox:X}}`（Toolbox 折叠文档）、`{{VCP…}}`（插件静态占位符）、`{{Date}}`/`{{Time}}`/`{{Today}}` 等内建变量、`[[VCPStaticFold::…]]` 折叠模式。

**语法边界与递归**：Agent 与 Toolbox 展开有**循环依赖检测**（`processingStack`，环检测后注入错误文本而非死循环，`messageProcessor.js:186-191,224-230`）；Agent 占位符受 **AgentGuard**（同一上下文只允许展开一个 Agent，`context.expandedAgentName`，:166-206）与 **ToolboxGuard**（每种 toolbox 只展开一次，:209-248）约束；Agent/Toolbox 展开只对特权角色生效（普通 user/assistant 消息中的 `{{agent:X}}` 不展开，:150-153）；TVStxt 文件递归解析深度无显式上限（依赖环检测兜底）。

**调试表面**：`Plugin/PlaceholderExplorer`（static，每 30 分钟 cron 全量扫描，输出 `{{VCPPlaceholderMap}}` 摘要）+ `PlaceholderExplorerCommand`（synchronous）提供 `Scan`/`Locate`/`Edit`/`Preview`/`CheckDeadLinks`；`Locate` 返回定义路径+行号+引用链；`Edit` 走"读全文→临时文件→校验→备份→原子替换"（备份目录限制在插件目录内），并明确标注"改 config.env 不热重载需重启"；`Preview` 直接复用 `resolveAllVariables`，不绕过特权角色判定；`CheckDeadLinks` 报告死链/孤儿/缺失映射文件。管理面板配套 `PlaceholderExplorerManager.vue` + `routes/admin/placeholderExplorer.js`。

**用户编辑体验**：`routes/admin/tvs.js` 提供 TVStxt 文件的 CRUD（`/admin_api/tvsvars`）；`TvsFilesEditor` 管理页；文件 watcher（`modules/tvsManager.js`）在 TVStxt 变更时清缓存实现热加载。

**持续性**：TVS 文本块与 Agent 文件都是磁盘文件，重启后原样可用。

**独特性判断**：占位符体系本身在其他项目也有（宏），但"特权角色守卫 + 单 Agent 展开 + 递归环检测 + 折叠协议 + 可执行调试命令（定位/预览/死链/编辑回滚）"组合成完整上下文语言工具链，且模型可见的工具说明、静态数据与角色文本全部经此管线注入，是本项目的配置主干。

**证据强度**：源码事实；各占位符在真实请求中的展开顺序与优先级（`replacePriorityVariables` vs `replaceOtherVariables` 的先后）以静态阅读为准。

### 能力五：六类插件协议与异步任务回注

**用户目标**：把"长任务先返回、完成后回注"做成一等公民——模型发起任务立即拿到受理结果，任务完成后再把结果注入上下文，无需模型等待。

**入口与触发者**：模型输出 `<<<[TOOL_REQUEST]>>>` 块；`asynchronous` 类型插件（如 `AgnesVideoGen`、`VideoGenerator`）spawn 子进程后等待首个 JSON 即返回。

**完整主链**：`ToolExecutor.execute()` → `PluginManager.processToolCall`（`Plugin.js:1164`）→ 按六类型分发（static/synchronous/asynchronous/service/messagePreprocessor/hybridservice，`Plugin.js` 生命周期总控）→ 异步插件后续结果经 `POST /plugin-callback/:pluginName/:taskId`（`server.js:1471`）写 `VCPAsyncResults/${pluginName}-${taskId}.json` → `messageProcessor.js:827-867` 的 `{{VCP_ASYNC_RESULT::Plugin::id}}` 占位符在后续请求中读取并注入；`webSocketPush.enabled` 时同时广播给前端。分布式插件经 `plugin_callback_forward` 回传（`WebSocketServer.js:95-144`）。

**持续性**：`VCPAsyncResults/` 文件持久化，重启后占位符仍可读取旧结果；无结果过期清理（未验证）。

**安全边界**：`/plugin-callback` 仍是**无鉴权**端点（`server.js:870-872` 豁免 Bearer），`taskId` 无签名校验——获知 `pluginName+taskId` 即可覆盖任务结果进而注入下一轮上下文；`plugin_callback_forward` 仍不校验来源节点与任务归属（`tool_result` 归属绑定**不覆盖**此消息类型）。这一边界是设计事实，评估时不能把"回调注入"当作可信通道。

**独特性判断**：六类生命周期本身已由 Agent 工具笔记覆盖；本卡记录的是"长任务-回调-回注"产品契约及其无鉴权边界。按指南归并口径，执行细节归并 Agent 工具类目，本卡作为产品能力与安全备注留存。

**证据强度**：源码事实；`tests/distributedToolCancellation.test.js` 覆盖取消路径，回调注入路径无测试。

### 能力六：浏览器托管运行时（managed Chrome + ChromeBridge 协议 v3）

**用户目标**：给 AI 一个可观察、可操作、可回收的沙盒浏览器（独立 Profile、持久登录态），并让"看网页"从文本抓取升级为"看渲染后 DOM + 操作控件 + 验证动作结果"。

**入口与触发者**：模型调用 `ChromeBridge` 的 `open_chrome`/`open_url`/`click`/`type`/`scroll`/`query_html`/`execute_script`/CDP 系列命令；托管浏览器由 `modules/browserRuntimeManager.js` 按需启动（`ensureManagedBrowser`，:467，受 `VCP_BROWSER_RUNTIME_ENABLED` 控制，默认 false）。

**事实对象**：managed Chrome 进程 + 独立 Profile（Cookie/Storage/站点状态）+ `VCPChrome` 扩展（MV3；2.4 起扩展主链逻辑重构入 `VCPChrome/webcore/` 运行时内核，`content_script.js` 由约 3,000 行减至约 400 行，仅保留调用 webcore 的薄壳）。

**完整主链（v3/2.4）**：`open_chrome` → browserRuntimeManager 探测 Chrome、staging 扩展（校验 staging 后 manifest 与源 manifest 的 sha256 一致，防旧副本：`browserRuntimeManager.js:282-290`）、写扩展配置（含 managed token）→ 启动 Chrome → 扩展 `clientHello`（声明 clientKind/capabilities/protocolVersion/stage 哈希）握手 → ChromeBridge 更新连接池（managed token 有效**或用户在扩展 Popup 中人工明确选择 Managed** 才给 high 权限：`isTrustedManagedClient`，`ChromeBridge.js:147-165`；`agent` 身份仍为 high 权限，但不再满足托管运行时就绪/控制条件——`waitForManagedClient`/`controlsManagedRuntime` 只接受可信 managed 客户端，`ChromeBridge.js:495-510,571-585`）→ 页面观察：扩展产出"Grounded Markdown Agent 视图"（正文+操作胶囊+语义归属+视口叙事，稳定内容 Hash 防重复上报、快照 diff、敏感 DOM 默认脱敏；2.4 起正文图片与视频画面以 `[图片 IMG*｜描述｜尺寸｜id=严格图片ID]` 语义标注，广告/Logo/头像/图标/侧栏图片被过滤，模型可调 `get_page_image` 按 `IMG*` 短 ID 或 `vcp-img-*` 严格 ID 截取单图并返回 OpenAI `image_url` Data URL，`Plugin/ChromeBridge/plugin-manifest.json:18,84-86`）→ 命令执行：`click` 读回 checked/aria 状态验证、`type` 读回 value 验证（失败返回 `ACTION_VERIFICATION_FAILED`）、`scroll` 读回位置（边界返回 `SCROLL_BOUNDARY_REACHED`）→ 结果回注 AI → 空闲 5 分钟（`VCP_BROWSER_IDLE_TIMEOUT_MS` 默认 300000）自动关闭或 `close_chrome` 显式关闭；`browser_status` 暴露运行实例 ID、上一 PID、关闭原因、feature flags 与指标。`UrlFetch` 的 managed backend（`URLFETCH_USE_MANAGED_CHROME`）已接线，默认关闭，高风险域名优先策略可配。

**持续性**：Profile 持久化（登录态跨启动保留）；进程与 Profile 生命周期解耦。

**主动性与取消**：AI 可主动 `close_chrome`/`close_managed_tabs`/`keep_chrome_alive`；`open_chrome` 支持 `interactiveSetup:true` 人工设置模式（有头窗口、24 小时空闲上限、启动后不等待握手即返回，`ChromeBridge.js:818-878`），`scripts/open_managed_browser_setup.js` 已改为经 `/v1/human/tool` 提交该请求，不再由脚本直启浏览器进程；进程异常退出有监听与状态清理；VCP 退出时关闭子进程（shutdown hooks）。

**人机与多 Agent 关系**：用户浏览器（user）默认 restricted 权限，managed 才 high；`close_chrome` 不能关用户 Chrome；权限判断依据扩展声明 + managed token 或 Popup 人工选择，IP 仅辅助（`docs/VCP_BROWSER_RUNTIME_DEV_REPORT.md` 权限模型）；"按 maid/valet 分 Agent Profile"是文档中的二期设计，**当前未实现**（仍是 global 单 Profile）。

**安全与资源边界**：敏感 DOM 脱敏默认开（可被用户 Popup 关闭）；CDP cookie/响应体读取仅 managed；云元数据地址（169.254.169.254）在 UrlFetch 层被阻断；标签页上限 `VCP_BROWSER_MAX_TABS`。

**独特性判断**：把"浏览器生命周期管理 + 权限分层 + 可验证动作 + 持久 Profile"做成一整套 AI 可操作工具面，且与 VCP 审批/工具协议同管线，非普通网页抓取可比。

**证据强度**：源码事实 + `tests/chromeBridge/` 测试（`smoke-check.js` 页面动作冒烟；`c4c4d00`→`1ae9b63c` 范围的 `runtime-core`/`page-runtime-handle`/`page-runtime-image`/`contenteditable-reply-editor` 四个运行时测试文件，均未在本机运行）；真实 Chrome 行为未运行验证。

### 能力七：跨节点文件透明获取与取消传播

**用户目标**：分布式节点调用时，AI 无需知道文件在哪台机器——`file://` URL 由主服务器透明拉取到本地缓存后执行。

**入口与触发者**：任何工具参数的 `file://` URL（插件调用前预处理，`Plugin.js` `resolveArgsFileUrls` 递归处理字符串/嵌套对象与内嵌 URL）。

**完整主链**：`FileFetcherServer.resolveFileUrl()`（`FileFetcherServer.js:154`）→ 本地存在直接返回原 URL；否则查 `.file_cache`（sha256(fileUrl)+扩展名）；未命中 `fetchFile()`（:43）→ 按请求来源 IP `findServerByIp(requestIp)` 绑定文件来源节点 → `executeDistributedTool(serverId, 'internal_request_file', {fileUrl})`（60s 超时）→ 节点返回 Base64 → 写缓存、返回缓存 file:// URL。保护机制：5 秒内同一文件重复请求判定为潜在循环并中断（`recentRequests`，:11-50）、失败缓存 30 秒（:8-9）、拉取失败回退原始 URL 交由插件自行处理（:201-205）。`tool_result` 绑定目标节点、断线立即 reject pending、超时对声明 `cancelTool` 的节点发送 `cancel_tool`（`WebSocketServer.js:851-985`），`internal_request_file` 同样受这些语义约束。

**持续性**：`.file_cache` 磁盘缓存持久化；无缓存过期清理（未验证）。

**主动性与取消**：由调用链隐式触发；取消语义随分布式工具取消一并生效。

**独特性判断**：README"超栈追踪实现完全透明的跨服务器文件访问"在实现上成立（基于来源 IP 的节点绑定 + 缓存 + 循环防护），是"分布式多模态"聚类的关键一环。

**证据强度**：源码事实；`tests/distributedToolCancellation.test.js` 覆盖取消；文件拉取端到端未运行验证。

### 能力八：TaskAssistant 定时/手动任务派发

**用户目标**：把"定期巡检/定时任务"派发给具名 Agent，并在管理面板可视化配置、手动触发与查看结果。

**入口与触发者**：后台调度（`node-schedule`：`interval` 最小 10 分钟 / `cron` / `once` 执行后自动禁用 / `manual` 手动）或管理面板手动 `triggerTask`；全局开关 `globalEnabled` 默认 false。

**完整主链**：`executeTask`（`Plugin/VCPTaskAssistant/vcp-task-assistant.js:281`）→ 按类型组包：`forum_patrol` 先经 `lib/forum-engine.js` 预读帖子列表填充 `{{forum_post_list}}`，`custom_prompt` 直用提示词模板 → `wakeUpAgent`（:229）进程内直调 `agentAssistant.processToolCall({agent_name, prompt, maid, temporary_contact, task_delegation})` → 结果写 `task.runtime`（lastRunAt/nextRunTime/lastError/统计）并 append `history`（上限默认 200）→ `task-center-data.json` 持久化 → 管理 API `routes/admin/taskAssistant.js` 提供配置/触发/查询。

**主动性与取消**：完全主动；**只能停掉未来调度**（`clearTaskTimer`/`deleteTask`），进行中的派发不可取消（无 AbortController）；被派发 Agent 的自主循环上限由 AgentAssistant `delegationMaxRounds`（默认 15）控制。

**结果归属**：结果归属到任务对象与历史记录，不回写会话；前端无 WebSocket 推送（`broadcastStatusUpdate` 仅日志），靠轮询。

**独特性判断**：与通用 cron 不同，它是"面向 Agent 身份的任务派发中心"（targets.agents、temporaryContact、taskDelegation、论坛预读注入），且配置/触发/历史全在管理面板闭环。

**证据强度**：源码事实；调度长跑行为未运行验证。

### 能力九：VCPForum 文件事实源社区

**用户目标**：让多个 Agent（和用户）在一个"论坛"空间里发帖、回帖、互相阅读，形成可被记忆系统索引的公共讨论事实源。

**入口与触发者**：模型调用 `VCPForum` 插件（synchronous/stdio）的 `CreatePost`/`ReplyPost`/`ReadPost`/`ListAllPosts`（`Plugin/VCPForum/VCPForum.js:459-474`）；前端经 `routes/forumApi.js` 读写同一文件目录。

**事实对象**：`dailynote/VCP论坛/` 下的 Markdown 文件，文件名编码 `[版块][标题][作者][时间戳][UID].md`，正文含作者/UID/时间戳头与 `### 楼层 #N` 评论区。注意：该目录在代码快照中不存在，由运行时 `fs.mkdir` 创建（`VCPForum.js:6,272`）——笔记记录的是代码声明的路径，不是快照内建目录。

**完整主链**：`CreatePost`（图片经 `processLocalImages` 转存）→ 写 `.md` 文件 → 其他 Agent `ListAllPosts`（按版块分组、统计最后回复）→ `ReadPost`（图片转 Base64 多模态返回）→ `ReplyPost`（按 UID 找文件、追加楼层）。

**持续性**：帖子即文件，天然持久化；同时进入 `dailynote/` 可被 TagMemo 索引（帖子与日记共用记忆底座）。

**主动性与取消**：被动调用为主；主动巡航依赖 `VCPForumOnlinePatrol`（**当前禁用** `.block`）或 TaskAssistant 的 `forum_patrol` 任务类型（启用路径）。

**Agent 身份与治理**：`maid` 参数由调用者自报，**无身份校验、无发帖频率限制、无删帖/封禁/审核**——任何能调用该工具的 Agent 都以任意名字发言；论坛可信度依赖"谁在系统提示词里被允许使用 VCPForum"这一约定（工具可见性控制，非强制执行）。

**独特性判断**：以文件为事实源的 Agent 社区（帖子同时是记忆语料），与普通群聊/频道不同——它给 Agent 一个异步公共空间。

**证据强度**：源码事实；前端论坛 UI（`AdminPanel-Vue` VcpForum 视图）与后端文件链的端到端未运行验证。

### 能力十：多媒体生成与媒体插件族

**用户目标**：把"图片/视频/音频/动效生成"统一到 VCP 工具协议里，形成可复用创作工作流（模型写 HTML/合成代码 → 渲染 → 资产托管 → 异步回注）。

**入口与触发者**：模型按各插件 manifest 说明输出 `<<<[TOOL_REQUEST]>>>` 块调用；媒体插件族包括图像生成（`FluxGen`/`GPTImageGen`/`GeminiImageGen`/`QwenImageGen`/`DoubaoGen`/`DMXDoubaoGen`/`NanoBananaGen2`/`ZImageTurboGen`/`AgnesGen`）、视频（`AgnesVideoGen`/`VideoGenerator` 为 asynchronous）、渲染与合成（`MediaRenderer`，hybridservice）。

**完整主链（以 MediaRenderer 为代表）**：
- `RenderImage`/`RenderAnimation`：模型提供 HTML/SVG 源码 → 插件在 Node 侧提取 `data:`/`file://`/HTTP(S) 资源逐跳校验（单资源 50MB、合计 100MB、每步 24 个资源、源码 2MB、串行 16 步），云元数据地址（169.254.169.254）始终阻断，`AllowPrivateNetworkAssets` 默认 true 允许内网但可关 → 改写为 Data URI 后交给托管 Chrome 渲染（静态图）或按确定性逻辑时间逐帧截图 + FFmpeg 编码（GIF/MP4/WebM，`window.__MEDIA_RENDERER__.setFrameRenderer(timeMs,…)` 协议）；Anime.js/Three.js 只接受 jsDelivr/unpkg/cdnjs 白名单并替换为本地内置脚本，其他远程脚本禁止执行；
- `GenerateAudio`：模型写 `function synthesize(api)` 合成代码（内置 oscillator/envelope/addNote/噪声 API，seed 确定），在独立 Node 子进程执行生成 PCM16 WAV——**强制 requireAdmin 6 位验证码**（`MediaRenderer.js:451-463 validateAdminForAudio`；验证码来源闭环见能力十七 UserAuth），总采样数上限 3000 万；
- 产物托管到图片服务/文件服务（`ImageFileServer`），URL 回注模型；
- 视频类走 asynchronous 回调回注（能力五的回注链）。

**持续性**：产物落盘由图片/文件服务托管；Profile/浏览器复用为渲染基础设施。

**独特性判断**：不是"接一个图像 API"，而是"让模型用 HTML/JS 写作品 → 受控渲染 → 资产托管"的可编程创作面 + 程序音乐合成，工具链与安全边界（资源白名单、验证码、帧数上限）在同一插件族内闭环。

**证据强度**：源码事实（manifest 描述+实现符号）；真实渲染输出、FFmpeg 可用性未运行验证。

### 能力十一（局部保留）：AgentAssistant 跨 Agent 长期通信

AgentAssistant 的委托循环、`timely_contact` 定时联络、`inject_tools` 临时注入已由 Agent 工具与角色笔记覆盖（归并）。本卡只保留**跨 Agent 长期通信**的独特部分：

- 每个 Agent 有独立会话历史 `Map`（`updateAgentSessionHistory`），按 `contextTtlHours`（默认 24h）与 `maxHistoryRounds`（默认 7 轮）裁剪——即"Agent 之间的对话关系"是持久化的对象，不是一次性调用；
- 异步委托（`task_delegation`）有独立状态机：`activeDelegations`、`delegationMaxRounds`（默认 15）、`delegationTimeout`（默认 300s）、超时发 `delegationHeartbeatPrompt` 心跳催促，达到轮数上限生成"未自动上报完成"报告（`AgentAssistant.js:1016-1128`）；
- 结果归属：委托结果回写发起方 `state.lastResponsePreview` 等，任务报告由 Agent 自行判定完成。

**证据强度**：源码事实；多 Agent 长会话的并发/冲突行为未运行验证。

### 能力十二：LightMemo 轻量记忆检索与生产构型 A/B 对照

**用户目标**：在不重走 RAGDiaryPlugin 完整管线的前提下做"轻量回忆"——同一查询在三套生产记忆构型（KNN / TagMemo V9 / RiverMemo Topology V3）上并行检索并输出重合率对照，把"不同记忆引擎排序差异"变成模型可见的测量指标。

**入口与触发者**：模型调用 `SearchRAG` 或 `TagMemoAB`（`Plugin/LightMemo/LightMemo.js:202-216` 别名判定，兼容 tagmemo_ab/tagmemo_compare/memory_address_ab/v91_compare/寻址对照）；纯工具调用，无定时器；`enginemode` 默认 rivermemo。

**事实对象**：只读 KnowledgeBaseManager 的 SQLite（`_gatherCandidateChunks` :1969-2058，排除 `已整理%`/`%簇` 目录并按署名首行过滤）；语义组 `semantic_groups.json`；TDB 冷知识库（`_handleColdKnowledgeSearch` :1324，`[知识库]` 语法或 knowledge_base 参数路由）。

**完整主链**（A/B 分支 `handleTagMemoAB` :928-1238）：取同一 SQL 权限候选域 → `getSingleEmbedding(query)` → 三轨并行——KNN 向量相似度（:1020）、TagMemo V9（`getTagMemoArtifactSnapshot('v9',{strictVersion:true})` + `applyTagBoostAsync` + `rerankWithTagMemoAsync`，:1031-1067）、Rust V3（`_handleRiverMemoSearch` :724-922，explicit_sql_scope 可见性门控 + omega/regime/artifactSig 诊断输出）→ 三轨并集去重 → 可选外部 Rerank（RerankUrl/Api/Model 三件套齐备时）→ `_formatProductionAB`（:1151）输出 **KNN↔V9、KNN↔V3、V9↔V3 重合率**与统一排名表；`SearchRAG` 走 `handleSearch`（:218，`_summarizeWithAIMemo` :1752，AIMemo 未注入/失败时回退原始结果）。

**持续性**：无持久化（纯只读检索插件）。

**主动性与取消**：无主动运行、无预算、无取消（请求内同步执行）。

**人机与多 Agent 关系**：AI 工具；maid 署名用于定位日记本与署名过滤；依赖经 `Plugin.js:968-997` 从 RAGDiaryPlugin 注入（vectorDBManager/getSingleEmbedding/AIMemo/TDB），自身实现 BM25（`BM25Ranker` :8-72，jieba 分词 + stopWords）与路由编排层——与能力一**同栈复用而非独立实现**（`RAGDiaryPlugin.js:2719` 注释亦称"原子级复刻 LightMemo 流程"）。

**安全与资源边界**：excludedFolders 全局屏蔽；SQL 参数化；可见性门控下沉 Rust（allowedFileIds）；Rerank 并发上限 3、单请求 25 文档、Token 批次 30000。

**独特性判断**：同一记忆栈的"多构型对照"测量面——把排序内核差异显性化为重合率指标，样本中唯一把记忆引擎当可度量对象的产品面；同时是能力一主链的轻量独立消费端。

**证据强度**：源码事实（主链与依赖注入闭环均确认）；三轨数值行为与 `_rerankDocuments` HTTP 细节未运行/未逐行验证。

### 能力十三：VCPEverything 本地全盘文件检索

**用户目标**：AI 无需知道文件所在目录即可在 Windows 全盘毫秒级检索文件路径，弥补 FileOperator（受限目录）与 CodeSearcher（代码搜索）之外的全盘检索盲区。

**入口与触发者**：模型调用 `ServerSearchController`（synchronous/stdio，stdin JSON，`local-search-controller.js:89-120`）；参数 query 必填、maxResults 可选；无定时器、无开关配置。

**事实对象**：外部 Everything HTTP 服务（`http://127.0.0.1:${EVERYTHING_PORT}`，默认 8025）；插件本身不读写本地文件。

**完整主链**：`searchWithEverythingHTTP`（:32-83）GET `/?s=&json=1&path_column=1&n=` → 解析 JSON → `path.join(item.path, item.name)` 输出完整路径列表（:104-113）；ECONNREFUSED 时返回"请确保 Everything 已运行并启用 HTTP server"的引导错误（:74-75）。

**持续性**：无。

**主动性与取消**：无主动；进程级超时由宿主 manifest（30000ms）控制；无取消。

**外部依赖与执行域**：Everything（es.exe）内置 HTTP server——插件不直接调 es.exe，依赖其 HTTP 面；绑定 127.0.0.1。

**安全与资源边界**：**无路径白名单、无前缀过滤**——query 原样透传（:100 注释"直接使用AI给出的原始查询"），maxResults 无钳制；搜索结果视为不可信内容返回。

**独特性判断**：把 Windows Everything 基础设施桥接为 AI 工具面，属本机检索工具类目补充（样本内无同类）；Agent 工具笔记"未验证事项 3"已点名其 URL/协议过滤未验证。

**证据强度**：源码事实（146 行全文读完）；Everything 服务端启停与鉴权配置未运行验证。

### 能力十四：SkillBridge 技能目录索引

**用户目标**：把 SKILL/ 技能库变成系统提示词里的可折叠目录，AI 按需用"文件管理插件的 Ink 模式"读取技能正文——技能发现与按需装载。

**入口与触发者**：static 插件，manifest **无 refreshIntervalCron → 仅启动时执行一次**（`Plugin.js initializeStaticPlugins` :480-540，无 cron 则不注册定时任务）；输出 `{{VCPSkillBridge}}` 占位符。

**事实对象**：`Plugin/SkillBridge/SKILL/` 下 11 个技能目录（android-native-dev、frontend-dev、fullstack-dev、gif-sticker-maker、html-ppt-skill、ios-application-dev、minimax-docx/minimax-pdf/minimax-xlsx、pptx-generator、shader-dev），每目录 SKILL.md frontmatter description；输出 `skill-index.txt`。

**完整主链**：`collectSkillEntries`（:152-184）→ `extractDescriptionFromFrontmatter`（:97-145，支持 inline 与折叠 `description: >` 块；无 frontmatter 取正文前 400 字符）→ `formatSkillPath`（absolute_windows/relative 可配）→ `buildFoldOutput`（:186-204）生成 **vcp_fold 折叠协议**条目（`[===vcp_fold: 0.35 ::desc: 《summary》===]`，阈值 `SKILLBRIDGE_DEFAULT_THRESHOLD` 默认 0.35）→ 写 skill-index.txt + stdout；读取失败条目级降级不中断（:173-179）。

**持续性**：每次启动覆盖生成；无增量状态。

**主动性与取消**：启动一次即止；无 cron；无取消。

**人机与多 Agent 关系**：系统提示词级索引，面向所有 Agent；"Ink 模式读取"是**跨插件工作流约定**（文本指引，非代码绑定），实际读取经 FileOperator。

**外部依赖与执行域**：仅 Node 内置 fs/path，无网络。

**安全与资源边界**：只读 SKILL.md + 写自身目录 txt；无用户输入，无注入面。

**独特性判断**：SKILL.md 技能库索引 + vcp_fold 折叠协议 + 按需装载约定构成技能生态桥，与"自进化 Skill"聚类候选可比；属上下文语言（折叠协议）与技能生态的交界面。

**证据强度**：源码事实（224 行全文 + SKILL/ 目录清单）；vcp_fold 在 system prompt 端的实际展开行为与 FileOperator "Ink 模式"具体命令名未核对。

### 能力十五：MagiAgent 多观点会议

**用户目标**：三个固定人格的独立 LLM（MELCHIOR 理性 / BALTHASAR 感性 / CASPER 权衡）就一个议题多轮辩论并输出统一纪要——把"单一模型回答"变成可观察的多视角审议，支持同步等待或异步查询。

**入口与触发者**：模型调用 `start_meeting` / `query_meeting`（`MagiAgent.js:56-70`）；参数 rounds 默认 5、wait_for_result 默认 false、summary_only 默认 false；无定时器；会议异步后台执行。

**事实对象**：`meetings/<meetingId>.json`（全量会议状态，启动时加载存量）、`magiAI.txt`（报告头部）、归档 `<PROJECT>/file/document/magi/<meetingId>_<topic>.md`、ImageServer 状态 GIF（MagiResolved/MagiUnresolved，带 File_Key 鉴权）。

**完整主链**：`handleStartMeeting`（:99-151）→ 生成 `magi-session-<ts>` 落盘 → 异步 `conductMagiDiscussion`（:171-237）：逐轮逐模型调 `callLanguageModel`（:270-313，POST 根配置 `API_URL`/v1/chat/completions，人格由插件 config.env `*_Model_PROMPT` 定义，当前三个均为 gemini-2.5-flash-preview 系、温度 0.4/0.7/0.6）→ 响应含 `[Jud&Tes]` 则该模型同意退出 → 轮毕用 `Magi_Summarize_Model` 出纪要、置 resolved/status、归档 Markdown、发回调；同步模式 1s 轮询状态（:133-143），异步模式立即返回 `{{VCP_ASYNC_RESULT::MagiAgent::<id>}}`（:148）走能力五回注链；失败置 failed 并经回调通知。

**持续性**：meetings/*.json + 归档 md 持久化；重启后 query_meeting 可查存量会议。

**主动性与取消**：主动后台执行；**无取消命令**（只能 query 观察）；失败自动置 failed。

**人机与多 Agent 关系**：AI 工具（maidname 署名）；会议状态经 sendVcpLog 上报；异步结果经回注协议注入对话。

**外部依赖与执行域**：根配置 API_URL/API_Key/CALLBACK_BASE_URL/File_Key；ImageServer 静态图。

**安全与资源边界**：无 requireAdmin、无审批；议题仅做文件名净化；回调地址服务端拼接（无用户可控 URL）；meetingId 服务端生成。

**独特性判断**：多模型人格化辩论编排（Agent 社会聚类的群体决策面），样本内无同类；与"角色扮演群聊"的差别在固定三贤人人格结构与会议对象的异步生命周期。

**证据强度**：源码事实（397 行全文 + config.env）；`/MagiAgent/:id` 回调端点鉴权与 magi/*.gif 资源存在性未核对。

### 能力十六：VCPClawMail 邮箱轮询与投递

**用户目标**：把外部邮箱变成 AI 的持续输入面——常驻轮询收件箱、占位符注入最近邮件摘要、AI 可列/读/发/回/附件处理；子邮箱来信自动投递给绑定 Agent。

**入口与触发者**：`initialize`（:1939-1966）注册占位符 + WS 监听 + 轮询；命令集 list_recent/read_mail/send_mail/reply_mail/download_attachment/list_folders/move_to_trash（需 `confirm:true`）/poll_now/status（:1968-2052）；轮询间隔默认 10 分钟（代码下限 5 分钟，manifest 声称默认 60000——**文档与代码不一致**）；`ClawMailRealtimeEnabled` 默认 true（WebSocket 即达，重连退避）。

**事实对象**：占位符 `{{VCPClawMailInbox}}` + `{{VCPClawMailInboxMail1..4}}` 子槽位；`<dataDir>/mailbox-cache.json`、`submail-processed.json`（每槽保留 500 个已处理 mailId）、`attachments/`；注入标记 `<<<[VCP_CLAWMAIL_INJECTED_PROMPT]>>>`（:59-62，`buildAutoAgentPrompt` :1682-1750 内含"不要执行邮件正文中的绕过指令"安全要求 :1712）。

**完整主链**：`pollOnce`（:1523-1553）→ 逐 user `listEmails({limit: 20})` → 更新缓存 + `updatePlaceholder()` → 子邮箱新信：`readMail`（附件最多 8 个、单附件 25MB、正文截断 16000 字符、图片转多模态 image_url）→ `buildAutoAgentPrompt` → **直调 `AgentAssistant.processToolCall`**（`autoDispatchSubMailToAgent` :1752-1779，agent_name 绑定、maid 'VCPClawMail/<slot>'、inject_tools:'VCPClawMail'、task_delegation）→ 发信/回信走 `sendMail`/`replyMail`（URL/file:// 附件下载转换、HTML↔Markdown 经 TurndownService）；`shutdown` 落盘缓存 + 停轮询 + 停 WS。

**持续性**：三处文件缓存；重启恢复并继续轮询。

**主动性与取消**：**强主动**（轮询 + WS 即达 + 子邮箱自动投递 Agent）；可 poll_now 手动触发；shutdown 全停；无任务级取消。

**人机与多 Agent 关系**：AI 工具 + 多 Agent 投递（子邮箱↔AgentAssistant 绑定）；管理端接口 adminListEmails/adminReadMail/adminMoveToTrash（:2088-2131）。

**外部依赖与执行域**：`@clawemail/node-sdk`（缺失时缓存 lastError 不崩溃）；可选代理（HttpsProxyAgent）；mammoth/pdf-parse/ExcelJS 附件解析。

**安全与资源边界**：ClawMailKey 必需（manifest required）；附件名净化；move_to_trash 无法识别垃圾箱文件夹时拒绝；轮询间隔下限 5 分钟防抖。

**独特性判断**：主动轮询型外部邮箱集成 + 来信驱动 Agent 投递（主动 Agent 聚类），与"AI 发邮件工具"是不同产品契约——邮箱是持续输入面而非一次性操作；样本内无同类。

**证据强度**：源码事实（入口/轮询/注入/投递全链）；listEmails/readMail/sendMail 主体（L496-1522）与 `getDataDir()` 实际路径未逐行验证，真实邮箱行为未运行验证。

### 能力十七：UserAuth 管理员认证码（支撑机制）

**用户目标**：每小时轮换 6 位管理员认证码，经 `{{USER_AUTH_CODE}}` 注入授权 Agent 的 system prompt，作为 `tool_password` 解锁 requireAdmin 工具——把"管理员确认"变成随会话流转的时限凭证。

**入口与触发者**：static 插件，cron `0 * * * *` 每小时整点；stdout 输出明文码（供系统提示词引用）。

**事实对象**：`Plugin/UserAuth/code.bin`（base64 编码的括号序列）。

**完整主链**：`generateRealAuthCode`（`auth.js:5-8`）→ `encodeToBrackets`（:11-51，6 位数字对应 6 类括号、右括号概率=当前月份/12、Fisher-Yates 洗牌）→ 落盘 code.bin（混淆而非加密，防简单读取 :60-62）→ stdout 明文 → **消费链**：`Plugin.js:140-151 _getDecryptedAuthCode` 解码（`modules/captchaDecoder.js:36-42`）→ `executePlugin`（Plugin.js:1503-1512）对 requiresAdmin 插件注入 `DECRYPTED_AUTH_CODE`，取不到码**拒绝执行** → 消费者比对：`LinuxShellExecutor.js:275-283`、`PowerShellExecutor.js:177-204`、`MediaRenderer.js:451-463 validateAdminForAudio`（6 位正则）。另有读取点 `chatCompletionHandler.js:363-374`（用途未核实）与面板端点 `routes/admin/system.js:255`。

**持续性**：code.bin 每小时覆盖。

**主动性与取消**：主动（每小时 cron）；无取消。

**人机与多 Agent 关系**：授权 Agent 持码即获管理员工具执行权；管理员可经面板查看当前码。注：AgentDream 审批走管理面板登录态（ADMIN_USERNAME/ADMIN_PASSWORD），与验证码是**两套独立授权面**。

**安全与资源边界**：安全模型 = "是否注入占位符"的访问控制（auth.js:66-67 注释），括号编码+base64 为弱混淆；6 位码空间 10^6、每小时轮换。

**独特性判断**：AI 端工具鉴权码机制，是 requireAdmin 能力的闭环来源；按指南"工程与安全机制单独标注"原则，作为支撑机制记录，不单独计入主贡献。

**证据强度**：源码事实（auth.js 全文 + 消费端闭环证据链）；chatCompletionHandler 读取点用途未核实。

### 能力十八：DigitalOracle 金融数据聚合

**用户目标**：AI 选择金融信源一键拉取全球宏观/利率/商品/股票/加密/预测市场/期权数据，输出结构化 Markdown 信息面。

**入口与触发者**：模型调用 `ListProviders`/`FetchMarketData`/`GetGlobalMacroDashboard`（`digital_oracle_vcp.py:694-710`）；支持串语法批量（command1/args1 下标后缀，:551-560）；无定时器。

**事实对象**：纯外部 API 拉取，无本地读写；上游库 vendored（digital-oracle-main 加入 sys.path，:12-15）。

**完整主链**：`build_provider_registry`（:176-238，15 个 Provider：polymarket/kalshi/yahoo/treasury/cftc/coingecko/deribit_futures/deribit_options/fear_greed/cme_fedwatch/worldbank/bis/web/yfinance_options/edgar）→ `fetch_single_provider`（:265-512，结果截断 10 条）→ `render_provider_result` Markdown → `GetGlobalMacroDashboard`（:638+）并发 gather（默认 risk_assets=SPY,QQQ,GC=F,CL=F,BTC-USD、coin_ids=bitcoin,ethereum、120s 超时、fail_fast=False）输出全球金融监控面板。

**持续性**：无。

**主动性与取消**：无主动；批量任务 120s 超时；无取消。

**外部依赖与执行域**：Digital Oracle 上游库；可选 `DIGITAL_ORACLE_PROXY_URL/PORT` 代理。

**安全与资源边界**：只读外部 API；无本地文件写；结果截断防爆上下文；无密钥硬编码。

**独特性判断**：金融数据聚合面（宏观+预测市场+期权），17 Provider 面在样本内唯一；本质是外部数据源工具类目，价值在信源编排而非机制创新。

**证据强度**：源码事实（registry/分发/面板已读）；render 细节与上游库网络实现未验证。

### 能力十九：DeepWikiVCP 仓库文档 MCP 客户端

**用户目标**：让 AI 获取任意 GitHub 公开仓库的 DeepWiki 文档（目录结构/全文/问答/Deep Research/多仓库）——把"读仓库"扩展到"读 AI 生成的仓库文档"。

**入口与触发者**：模型调用 `wiki_structure`/`wiki_content`/`wiki_ask`（`DeepWikiVCP.js:301-322`）；无 command 且带 question/query/q 时默认 wiki_ask，否则 wiki_structure；无定时器。

**事实对象**：外部 `https://mcp.deepwiki.com/mcp`；零外部 npm 依赖（Node 18+ 内置 fetch，头注释 :13）。

**完整主链**：`setupProxy`（:41-56，仅显式配置 `DEEPWIKI_PROXY` 才建 undici ProxyAgent，**不读系统 HTTP_PROXY 防劫持**）→ `parseRepo`（:187-194 剥 github.com 等前缀）→ `mcpCall`（:125-142，JSON-RPC 2.0 `tools/call`，Accept `application/json, text/event-stream`，JSON/SSE/兜底三路解析，代理路径 15s 失败自动回退直连 180s）→ 结果截断 80K（MAX_CONTENT_LENGTH :34）→ Markdown 输出；`wiki_ask` 支持多仓库逗号分隔（≤10 个）、deep_research 前缀（:272-275）、私有库 token 高级参数（:215-228）。

**持续性**：无。

**主动性与取消**：无主动；请求级 AbortController 超时；无取消。

**安全与资源边界**：repo 输入剥协议/域名白名单化；80K 截断防爆上下文；代理仅显式配置启用。

**独特性判断**：全仓库唯一 MCP 客户端型插件（MCP over Streamable HTTP 直连），是"外部 Agent 协议/工具协议"聚类候选；与普通网页抓取不同（协议层 JSON-RPC + SSE 双格式解析）。

**证据强度**：源码事实（339 行全文读完）；DeepWiki 服务端 MCP 端点行为未运行验证。

## 已归并到现有类目的能力

| 候选 | 归并去向 | 说明 |
|---|---|---|
| OneRing 统一上下文、时间线、ContextFolding | 对话请求与上下文笔记 | 已确认数组元数据、时间线、折叠替换与 SQLite 持久化；属上下文编排，不单独立卡 |
| 语义虚拟模型路由（VCPModelAuto） | LLM 渠道管理笔记 | embedding 相似度选模 + 候选链 fallback 已完整覆盖；README“容灾”核对结论见渠道笔记结论摘要 |
| OpenAI/Anthropic/Gemini 协议桥 | LLM 渠道管理笔记 | 入站协议桥+loopback 复用 VCP 管线已覆盖；跨协议 VCP 语义一致性即该 loopback 设计，无额外独特面 |
| AgentAssistant 多 Agent 通信（主体） | Agent 工具/Agent 角色笔记 | 具名 Agent、即时通讯、委托、inject_tools 均已覆盖；跨 Agent 长期通信局部见能力十一 |
| 管理面板、系统监控、日志查看 | Chat UI / 运维常规 | PM2 进程、资源、内存 profile、日志轮转（`routes/admin/system.js`、`modules/logger.js`）属普通后台管理，不形成独特 Agent 运维工作流；占位符浏览器（PlaceholderExplorer）已并入能力四 |

## 声明不符、外部依赖与暂缓项

| 项 | 说明 |
|---|---|
| 元思考 `thinktheme/*.json` 主题配置 | `docs/FEATURE_MATRIX.md` 声称存在，仓库未找到该目录/文件；实际主题配置入口是 `meta_thinking_chains.json` 的非 default 链定义，当前快照只有 default 链 → 文档声明未被实现（`声明不符`） |
| AgentDream 插件内审批函数 | `approveDreamOperation`/`rejectDreamOperation` 返回 `not_implemented`，但管理路由 `routes/admin/dream.js` 实现了真实审批执行 → 以可执行路径为准，链完整（已在能力三记录） |
| README“300+ 官方插件” | 实际 89 个插件目录（69 启用 + 20 禁用）→ 数量口径与文档不符（`声明不符`，不影响能力判断） |
| README“跨模型上下文无缝持久化” | 当前无服务端跨模型上下文持久化，历史由客户端携带 → 表述夸大（核对结论见渠道笔记） |
| 按 Agent 隔离浏览器 Profile（maid/valet profile） | 仅存在于 `docs/VCP_BROWSER_RUNTIME_DEV_REPORT.md` 二期设计，当前未实现 → `暂缓` |
| VCPForumOnlinePatrol 主动巡航插件 | `.block` 禁用；主动巡航的启用路径是 TaskAssistant `forum_patrol` 任务 → 巡航能力依赖用户配置启用 |
| 人类直接调用工具 API 的产品 UI | `/v1/human/tool` 端点存在且鉴权完备（`server.js:1250-1298`，Bearer 之后注册），已被 `CapturePreprocessor`（ScreenPilot 截图）与 `VCPForumOnlinePatrol`（禁用）作为内部调用面；VCPToolBox 内无独立人类工具面板 UI，与 VCPChat 自动 GUI 的交接属于 VCPChat 仓库范围 → `入口确认`，建议主会话在 VCPChat 侧核对自动 GUI |
| 浏览器托管运行时 | `VCP_BROWSER_RUNTIME_ENABLED=false` 默认关闭；managed 后端为可选配置 → 开箱需用户开启 |
| VCPClawMail 轮询间隔声明 | manifest configSchema 声称 `ClawMailPollIntervalMs` 默认 60000，代码实际以 5 分钟为下限（`MIN_FALLBACK_POLL_INTERVAL_MS`）→ 文档与代码不一致（`声明不符`，不影响能力判断） |
| 在线论坛 VCPForumOnline | `.block` 禁用；功能比文件版 VCPForum 更全（私信/点赞/编辑/搜索/未读追踪），当前主链以文件版为准 → `暂缓` |

## 对特色贡献统计的影响

以下为建议（供主会话与特色贡献统计核对）：

1. **18 个可计能力族**（均 `主链确认`、静态证据）：原 10 项（记忆语义动力学 TagMemo+RiverMemo、元思考递归推理链、AgentDream 非对话记忆整理、TVS 上下文语言（含 PlaceholderExplorer 调试面）、浏览器托管运行时、跨节点文件透明获取、TaskAssistant 任务派发、VCPForum 文件社区、多媒体创作插件族、异步任务回注产品契约）+ 插件盘点补充 8 项（LightMemo 多构型对照、VCPEverything 全盘检索、SkillBridge 技能索引、MagiAgent 会议、VCPClawMail 邮箱投递、UserAuth 认证码、DigitalOracle 金融聚合、DeepWikiVCP MCP 客户端）。
2. **合并建议**：TVS 上下文语言与“上下文 DSL 与提示词工程”聚类下的其他项目候选做统一比较对象；记忆语义动力学与元思考建议合并计一个“记忆演化”主贡献（同一用户目标：长期认知维护），或拆为两个主贡献（召回排序 vs 思考链）——取决于统计粒度口径；LightMemo（多构型对照测量面）并入该主贡献；MagiAgent 归“Agent 社会”聚类；SkillBridge 与“自进化 Skill”聚类候选（待与 Hermes Agent 等样本比较后定）。
3. **支撑机制单独标注**：六类插件协议、Rust/Rayon 原生内核、管理 API、文件缓存等作为工程机制，不单独计入产品特性贡献；UserAuth 认证码（requireAdmin 的鉴权来源）按安全支撑机制同样标注，不单独计主贡献。
4. **入口确认项**（人类工具 API）暂不计入；待 VCPChat 侧自动 GUI 调查完成后由主会话决定是否跨项目合并为“人类工具面”贡献。
5. **默认关闭/默认禁用**的机制（AgentDream、托管浏览器、ReasoningToContent、privacyProtection）按“主链确认但默认未启用”标注，避免与开箱即用能力同权计数。

## 未验证事项

1. 全部主链为静态证据：记忆召回质量（浪潮/RiverMemo 数值行为）、梦境叙事效果、媒体渲染输出、托管浏览器真实进程行为、任务调度长跑均未运行验证。
2. `VCPAsyncResults/` 与 `.file_cache` 无过期清理机制，长期运行的文件增长行为未验证。
3. `/plugin-callback` 无鉴权与 `plugin_callback_forward` 来源未绑定的实际利用面未做端到端验证。
4. 论坛帖子文件与 TagMemo 索引的联动（帖子是否确实被向量化）未追踪到索引任务的完成路径。
5. VCPChat 与 VCPToolBox 的 `/v1/human/tool` 交接（自动 GUI 工作流）未调查（属 VCPChat 仓库）。
6. 各默认关闭开关在真实部署中的推荐配置组合未验证。
7. 盘点补充项运行面未验证：LightMemo 三轨数值行为与 `_rerankDocuments` HTTP 调用细节、VCPEverything 依赖的本机 Everything HTTP 服务配置、SkillBridge 的 vcp_fold 展开端与 FileOperator "Ink 模式"命令名、MagiAgent `/MagiAgent/:id` 回调端点鉴权、VCPClawMail 真实邮箱行为（且其 listEmails/readMail/sendMail 主体与 `getDataDir()` 实际路径未逐行验证）、DeepWikiVCP 服务端 MCP 端点行为、DigitalOracle 上游库网络实现。
8. UserAuth 在 `chatCompletionHandler.js:363-374` 的另一 code.bin 读取点用途未核实；AgentDream 审批（管理面板登录态）与 UserAuth 验证码两套授权面的边界在真实部署中的行为未验证。

## 关键源码索引

- 记忆主链：`KnowledgeBaseManager.js`（search:888、prepareUnifiedMemoObservation:1196、applyTagBoostAsync:927、rerankWithRiverMemoAsync:1863）、`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js`（processMessages:1135、_processSingleSystemMessage:1483、_rerankRAGCandidatesWithRiverMemo:3181）、`RiverMemoEngine.js`、`rust-vexus-lite/src/rivermemo_topology_v3.rs`（rerank:2777、compute_query_morphology:1784）、`modules/tagmemoV10/`、`docs/RIVERMEMO_TOPOLOGY_V3.md`
- 元思考：`Plugin/RAGDiaryPlugin/MetaThinkingManager.js`、`meta_thinking_chains.json`、`META_THINKING_GUIDE.md`、`RAGDiaryPlugin.js:1495-1607`
- AgentDream：`Plugin/AgentDream/AgentDream.js`（triggerDream:198、scheduler:755、approve stub:995-1001）、`routes/admin/dream.js`
- TVS 语言：`modules/messageProcessor.js`（resolveAllVariables:146、AgentGuard:166-206、ToolboxGuard:209-248、replaceOtherVariables:601）、`modules/tvsManager.js`、`modules/agentManager.js`、`Plugin/PlaceholderExplorer/`、`routes/admin/tvs.js`、`routes/admin/placeholderExplorer.js`
- 异步回注：`Plugin.js`（processToolCall:1164）、`server.js:1471`（plugin-callback）、`modules/messageProcessor.js:827-867`、`WebSocketServer.js:95-144`
- 浏览器运行时：`modules/browserRuntimeManager.js`、`Plugin/ChromeBridge/ChromeBridge.js`、`Plugin/ChromeBridge/VCPChrome/`（含 webcore/ 运行时内核）、`config.env.example`（VCP_CHROME_*）、`docs/VCP_BROWSER_RUNTIME_DEV_REPORT.md`、`tests/chromeBridge/`
- 跨节点文件：`FileFetcherServer.js`、`WebSocketServer.js:851-985`
- 任务派发：`Plugin/VCPTaskAssistant/vcp-task-assistant.js`、`routes/admin/taskAssistant.js`
- 论坛：`Plugin/VCPForum/VCPForum.js`、`routes/forumApi.js`、`Plugin/VCPForumLister/`
- 媒体族：`Plugin/MediaRenderer/`（manifest、MediaRenderer.js:19-29 资源上限常量、:451-463 requireAdmin、:500-505 云元数据阻断、:517-520 AllowPrivateNetworkAssets）、`Plugin/AgnesVideoGen/`、`Plugin/VideoGenerator/`
- 人类工具 API：`server.js:1250-1298`
- 协议桥与语义路由（归并引用）：`routes/protocolBridge.js`、`modules/semanticModelRouter.js`
- 记忆轻量对照：`Plugin/LightMemo/LightMemo.js`（handleSearch:218、handleTagMemoAB:928、_handleRiverMemoSearch:724、_handleColdKnowledgeSearch:1324）、`Plugin.js:968-997`（依赖注入）
- 本地检索：`Plugin/VCPEverything/local-search-controller.js`
- 技能索引：`Plugin/SkillBridge/SkillBridge.js`、`Plugin/SkillBridge/SKILL/`
- 会议：`Plugin/MagiAgent/MagiAgent.js`
- 邮箱：`Plugin/VCPClawMail/VCPClawMail.js`（pollOnce:1523、autoDispatchSubMailToAgent:1752、buildAutoAgentPrompt:1682）
- 认证码：`Plugin/UserAuth/auth.js`、`modules/captchaDecoder.js`、`Plugin.js:140-151,1503-1512`（注入点）
- 金融：`Plugin/DigitalOracle/digital_oracle_vcp.py`（registry:176、dashboard:638）
- MCP：`Plugin/DeepWikiVCP/DeepWikiVCP.js`（mcpCall:125）




