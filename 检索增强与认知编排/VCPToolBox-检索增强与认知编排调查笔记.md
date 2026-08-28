# VCPToolBox 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`e2762e4dab5c70952d88f96689fba1270624e5ef`（分支：`main`）
>
> 调查方式：直接静态追踪当前 Node.js、Rust N-API 与管理路由的可执行链；核对 Git 分支和提交；补充匿名化的外部运行观察。未运行服务、Embedding 上游、SQLite 实例或管理面板。
>
> 调查范围：会话内 DailyNote 工具的记录/更新和后续索引，日记和标签的摄取/索引，TagMemo 与 RiverMemo 的查询和派生资产，元思考链，AgentDream 的独立梦境内容与后台维护，以及作用域、预算、缓存、观测和恢复；不调查普通工具调用、会话裁剪或其他类别已覆盖的最终请求编排。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**源码事实。** VCPToolBox 的长期记忆不是单一向量库。`dailynote/` 中的 Markdown/TXT 日记被切块、嵌入并写入 SQLite 与按日记本划分的 Vexus 索引；文件标签、标签向量、标签顺序和文件-标签关系又构成 TagMemo/RiverMemo 所需的结构事实。RAGDiaryPlugin 只在请求含日记、知识库或元思考占位符时处理消息，把检索结果替换回占位符所在的 system 消息或特定的虚拟 system user 消息。

**源码事实。** 该快照同时有两条结构读出。TagMemo 是对 KNN 结果的标签增强和 DTSC 测地读出；RiverMemo 是与 TagMemo 互斥的 Topology V3 路径。RiverMemo 先在限定日记本的候选上建立六路候选超集，再由 Rust/Rayon 一次完成候选投影、路径/相对拓扑、Direct Anchor、Omega 河网观测和最终排序。它的输出仍是当前 prompt 可注入的日记片段，但结果契约另携带 artifact 签名、query ID、Omega、角色和加分项。

**源码事实。** 元思考不是 LLM 的逐步推理循环：它顺序检索已索引的“思维簇”，用上一阶段命中向量的均值与原查询向量加权融合，驱动下一阶段检索，并把每阶段文本拼成注入块。AgentDream 则从同一日记和向量索引形成跨时间层级的联想树，调用本地 VCP API 生成梦叙事；模型提出的合并、删除、感悟先落为 `pending_review` 日志，再由管理路由审批后写日记或删除源文件。

**源码事实。** 主要的会话内日记写入入口不是 AgentDream，而是启用的 DailyNote 常驻工具服务。它对模型暴露创建和更新日记命令；请求按单进程 FIFO 执行，文件提交后即可返回，而 KnowledgeBaseManager 在后台协调 SQLite/Rust 索引更新。AgentDream 的 manifest 处于 `.block` 禁用态，并且它在缺少自己的 `config.env` 时主动休眠，故不能从当前默认文件状态把 Dream 作为默认对话记录来源。`Plugin/DailyNote/plugin-manifest.json:3-21,61-90`、`Plugin/DailyNote/dailynote.js:41-49,1573-1684`、`Plugin/AgentDream/plugin-manifest.json.block:1-48`、`Plugin/AgentDream/AgentDream.js:119-135`。

**匿名化运行观察。** 在一份外部部署中，会话内主动或指导式 DailyNote 写入是日记的主要来源；这与源码中启用的会话工具和异步索引衔接相符。Dream 的写入比例较低，但运行时不只是合并、删除或压缩已有日记：它会混入梦境专属的叙事和联想内容。该观察只描述该部署，不能外推为所有 VCPToolBox 安装的默认比例、调用频率或内容质量。

**匿名化目录快照。** 一份外部部署的日记目录同时包含日常/知识资产、公共资料、技术归档、思维簇和按 Agent 命名的梦目录。该快照确认部署中确有独立梦目录与思维簇事实源，不能仅凭路径名、文件数或体积推断任一目录的内容质量、每篇来源、索引完成状态或写入比例。

**静态推断。** 因此它属于“检索驱动认知编排”及具有会话内主动记录和独立梦境维护的谱系，而非只有相似度召回的知识库 RAG。当前仓库的 `.block` 文件说明 Dream 在此代码快照的默认发现状态为禁用，但匿名化运行观察表明某个外部部署已通过本快照以外的启用/配置状态实际使用该链；二者不能互相替代。算法质量、延迟、跨 Agent 隔离效果和后台维护收益同样未作独立运行测量。

## 谱系定位与系统边界

### 事实对象与来源

**源码事实。** 权威持久化层是 `VectorStore/knowledge_base.sqlite` 与配置的日记根目录；默认分别是项目下的 `VectorStore/` 和 `dailynote/`。SQLite 的 `files` 保存相对路径、所属日记本、校验和、修改时间和大小，`chunks` 保存分块正文及向量 BLOB，`tags` 保存全局唯一标签与向量，`file_tags` 保存文件标签及其位置。模型名和向量维度共同形成模型签名，模型或维度变化会使相关派生数据不能沿用。见 `KnowledgeBaseManager.js:50-147` 与 `modules/knowledgeBase/schemaManager.js:3-79`。

**源码事实。** TagMemo 的派生资产以标签共现、标签间相似度、残差等为输入；RiverMemo 另有 `rivermemo_artifacts` 表，保存来源 V9 artifact、模型/配置/数据库/来源代际、压缩 JSON payload、校验和、状态、节点边数和发布时间。当前生产说明明确将完整图、CSR 和 provenance 交给 Rust 的 `VexusIndex.memoRuntime` 持有，而不是由 Node 中的旧 Map 构建。`modules/knowledgeBase/schemaManager.js:65-159`、`KnowledgeBaseManager.js:336-371`。

**源码事实。** 思维簇不是从对话临时产生的对象，而是可检索的日记本/索引名。当前版本的 `meta_thinking_chains.json` 只定义一条 `default` 链，依次为“前思维簇、逻辑推理簇、反思簇、结果辩证簇、陈词总结梳理簇”，K 序列为 2、1、1、1、1。`Plugin/RAGDiaryPlugin/meta_thinking_chains.json:1-16`。

**匿名化运行观察。** 提供的目录快照包含与该 default 链同名的五个目录。这说明在该部署快照时五个阶段都已有可作为日记本索引来源的文件；是否所有文件都已通过 watcher 摄取、每阶段实际命中了哪些条目及其效果，仍需索引状态和运行追踪确认。

**源码事实。** Dream 运行状态由 AgentDream 的 JSON 日志和调度状态文件组成。每个梦日志保存叙事、记忆树和待处理操作；调度状态保存每 Agent 最近成功做梦时间。它们不是 SQLite 事务的一部分。`Plugin/AgentDream/AgentDream.js:319-344, 919-956`。

### 摄取、删除与派生更新

**源码事实。** 启动时文件观察器可全量扫描日记根目录中的 `.md`、`.txt`，跳过配置的文件夹、前后缀及若干系统目录；运行期优先使用 Rust watcher，拿不到则走 chokidar。add/change 进入固定收集窗口，unlink 进入独立删除批次；不稳定文件会延后重试，稳定事件带 generation 时会丢弃同一路径的旧事件。`modules/knowledgeBase/fileWatcher.js:20-137, 139-257`，`modules/knowledgeBase/ingestionPipeline.js:40-130`。

**源码事实。** 摄取批次按第一层目录分为日记本，读取时二次 stat 防止把写入中的快照入库；按内容切块、抽取标签，复用可用的旧向量或批量调用外部 Embedding API。随后在 SQLite 事务中更新文件、chunk、tag 和关联，并更新各日记本索引。Embedding 失败位置以空值跳过，因此“文件被监测到”不等于“每个分块均已向量化”。`modules/knowledgeBase/ingestionPipeline.js:100-257`。

**源码事实。** 全局 Tag 索引可从持久化双槽基线恢复后回放 SQLite 差分；没有兼容基线才从 `tags` 恢复。日记索引按需载入，闲置默认两小时可卸载。RiverMemo 冷启动仅读 SQLite artifact 清单，兼容清单命中时由 Rust 在首个查询懒加载并原子发布；不命中会在 System Ready 后排入原生 bootstrap。`KnowledgeBaseManager.js:263-409`。

**源码事实。** 新标签和热参数变化会影响派生资产。TagMemo 将派生任务串行化，避开 JS 摄取、删除、Rust 写租约和数据库异常状态；重建失败时可保留累计的新标签并在静默窗口后重试。手动“主动全量训练”也只是把全量派生训练排队。`TagMemoEngine.js:3539-3765, 3921-4099`。

## 请求入口、候选与输出主链

### DailyNote：会话内的主动记录主链

**源码事实。** DailyNote 是已启用的 direct `hybridservice`，声明 `create` 与 `update` 两个 invocation command。插件管理器会把声明的工具描述生成为 `{{VCPDailyNote}}`；只有 Agent 的系统提示词实际包含该占位符时，模型才会收到这些调用说明。创建要求作者、日期和完整正文，可显式指定目录和标签；更新以最少 15 字符的旧文本定位替换内容。`Plugin/DailyNote/plugin-manifest.json:3-21,61-90`、`Plugin.js:1060-1087`。

**源码事实。** 调用经 VCP 工具循环进入 `PluginManager.processToolCall`，随后由 DailyNote 的常驻服务串行处理。服务会对缺失或错误的 command 按参数推断 create/update；每个请求先进入本进程 FIFO，再交给 `KnowledgeBaseManager.runExternalFileMutation`。文件系统提交是工具返回的完成边界，索引更新在知识库管理器的后台队列继续进行，因此“模型已得到创建成功结果”不等于新日记已经可被向量检索。`modules/vcpLoop/toolExecutor.js:371-374`、`Plugin.js:1131-1159,1197-1346`、`Plugin/DailyNote/dailynote.js:1573-1651`。

**源码事实。** DailyNote 写入目录会清理路径成分；更新目录解析还以作者别名限制非公共目录匹配。服务关闭时停止接收新请求并等待队列排空。创建/更新后的文件监测、切块、标签提取、Embedding 与索引更新由知识库摄取管线接手；其中单个 chunk 的 Embedding 失败可被跳过。`Plugin/DailyNote/dailynote.js:80-126,175-192,1653-1691`、`modules/knowledgeBase/fileWatcher.js:20-257`、`modules/knowledgeBase/ingestionPipeline.js:100-257`。

**未运行验证。** 当前快照能确认 DailyNote 是启用的会话工具和默认可用的记录路径，却不能仅凭 manifest 断言每个 Agent 都带有 `{{VCPDailyNote}}`，更不能量化其相对 AgentDream 或人工管理面板的实际写入比例。

### 占位符到查询向量

**源码事实。** RAGDiaryPlugin 扫描 system 消息，以及以 `[系统...]` 开头、被认作虚拟 system 的 user 消息，识别日记、知识库、AIMemo 与 `[[VCP元思考...]]` 声明。没有这些声明时直接返回消息，避免普通请求扫描历史或调用 Embedding。命中后从最后一个真实 user 消息和最后一个 assistant 消息生成向量，默认按 0.7/0.3 加权；assistant 文本中的 `[@tag]` 另会转为硬/软 ghost tag。各目标消息并发处理，最后替换其占位符。`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1212-1510`。

**源码事实。** 标准日记查询按 `[[...日记本]]` 等声明选择一个或多个日记本。正常路径以当前查询加最多三个历史主题分段并行搜索，历史分段按衰减权重降分；时间修饰符另从日期范围取 chunk，BM25 修饰符从正文或标签路取得稀疏候选。候选池会过滤已在上下文中的日记前缀，并执行 ID、正文及可选语义近重复去重。`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2813-2954`。

**源码事实。** 时间检索保留语义路和时间路的配额，默认按最终 K 的 80/20 切分；新对话可额外附加最多三条最近日记，不占最终 K。语义组会先检测用户文本命中的组并将组向量融合到查询向量。可选外部 reranker 在候选形成后运行，且其单批 token 上限默认 30,000、预取倍率默认 2。`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2770-2845, 2995-3061`，`plugin-manifest.json:17-42`。

**源码事实。** 最终结果经过可选时间衰减、外部 rerank、联想共现、父文档展开和最终语义去重；按普通、时间或语义组格式写成 HTML 注释包裹的 `VCP_RAG_BLOCK`，其中正文逐项附 `file:///` 来源路径。Observer 广播最多 20 条清洗后的结果，包含查询、日记本、K、模式开关、BM25、标签统计，以及 RiverMemo 诊断。`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3063-3233`，`Plugin/RAGDiaryPlugin/RAGResultFormatter.js:20-173`。

### TagMemo：标签增强与 DTSC 读出

**源码事实。** 普通 KNN 由按日记本的 Vexus 索引执行；请求 `::TagMemo` 时，插件先经 `applyTagBoostAsync` 感应查询标签并得到增强向量。请求 `::TagMemo+` 时，检索会以放大的候选 K 执行 TagMemo DTSC 重排，之后仍收敛到调用方所需 K。单日记本和联合日记本均复用同一原生 QueryObservation；联合搜索先并发取各物理索引，再合并后只作一次读出。`modules/knowledgeBase/searchService.js:86-220, 368-471`。

**源码事实。** TagMemo 初始化只建立 EPA 和残差金字塔门面，不在冷启动同步重算大规模派生数据；生产图资产由 Rust memo runtime 所有。当前 Node 代码保留旧 JS 结构和兼容字段，但注释与调用链均表明生产计算不能再将该 Map/CSR 作为输入。`TagMemoEngine.js:633-671`。

### RiverMemo：六路候选、拓扑排序与结构证据

**源码事实。** `::RiverMemo` 使同一声明中的 TagMemo/TagMemo+ 失效，并提高初始 KNN 的提供量，使候选域至少覆盖 RiverMemo 的 `queryK` 或 `maxUnionCandidates` 配置。时间路候选不交给 RiverMemo 改写，其他语义和 BM25 候选进入 Topology V3；RiverMemo 失败、缺 artifact、错误维度或无法建立范围时抛错，不静默退回 KNN/TagMemo。`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2665-2755, 2956-2985, 3236-3331`。

**源码事实。** RiverMemo 的候选超集定义六个来源：原查询 KNN、降噪场 KNN、局部场 KNN、迁移场 KNN、BM25 和 Direct Anchor。实现先按来源归一化、以 chunk ID 合并，按来源配额保留覆盖，再以多来源数和统一分填满上限；诊断中保存每路 offered/entered/dropped、配额及被上限丢弃的候选。`modules/tagmemoV10/candidateSuperset.js:3-256`。

**源码事实。** 插件为 RiverMemo 查询执行 SQL `files.diary_name IN (...)`，把所得 file ID 作为 `allowedFileIds`；上下文标为 `explicit_sql_scope`，公共、本人、其他 Agent 公共及 provenance 不明均设为不允许，只有 authorized 标记为允许。Rust 输入亦含此 ID 集合。这个范围构建失败会中止查询。`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3271-3324`，`RiverMemoEngine.js:261-313`。

**源码事实。** 通过一次 N-API 调用，Rust 取得原生预备的降噪/局部/迁移场，完成候选投影、路径几何、相对拓扑、DSTC、Direct Anchor 与排序；Rust 侧可用 Rayon 并行。返回条目包含原始/基础分、拓扑和 anchor bonus、命中标签、角色、Omega、河网状态、候选来源；仅在 `includeTrace` 才再返回拓扑、几何和观测细节。`RiverMemoEngine.js:467-545`、`RiverMemoEngine.js:365-464`、`rust-vexus-lite/src/rivermemo_topology_v3.rs:1-14, 82-154`。

**源码事实。** Omega 只读查询侧河网，不读候选或数据库。它由活跃边相对种子数、涌现节点相对种子数、边流熵的几何均值组成；不完整观测再乘 0.5，并划分 collapsed、sparse、dense 三种 regime。`modules/tagmemoV10/riverObservability.js:34-130`。

## 元思考：阶段反馈与注入

**源码事实。** `[[VCP元思考:<链>::...]]` 可直接选择链，或用 Auto 对非 default 链的主题向量计算余弦相似度，并受白名单、黑名单和阈值约束。主题向量以配置文件哈希作为磁盘缓存身份；当前只有 default，构建主题向量时还会显式跳过 default，因此当前快照的 Auto 没有其他已配置主题可切换。`Plugin/RAGDiaryPlugin/MetaThinkingManager.js:15-103, 108-145`。

**源码事实。** 每阶段在对应簇上检索该阶段 K；命中时取结果自带向量，必要时按文本回查向量，平均后与最初查询向量按 `metaThinkingWeights`（默认 0.8/0.2）融合，作为下一阶段查询。空结果记录 `degraded` 并沿用当前向量；取不到结果向量或阶段异常则中断剩余阶段。它不会追加模型调用，最终把各阶段命中的思维模块格式化为文本并替换占位符。`Plugin/RAGDiaryPlugin/MetaThinkingManager.js:147-332, 359-401`。

**源码事实。** 元思考结果缓存键包含 user/assistant 文本、最终链名、K 序列、是否使用语义组和 Auto 标志；缓存命中仍会重放保存的 VCP Info。未命中时广播 `META_THINKING_CHAIN`，内容包括显示查询、激活语义组、每阶段簇/K/结果数及文本分数。`Plugin/RAGDiaryPlugin/MetaThinkingManager.js:177-201, 303-330`。

**未运行验证。** 思维簇是否已完成摄取、主题向量缓存是否能在实际文件变动后正确更新、注入块是否总位于最终上游请求，以及其对输出的影响，需在真实服务和具体 prompt 下验证。

## AgentDream：独立梦境内容、审批与写回

**源码事实。** AgentDream 的 manifest 当前以 `.block` 形式存在，故插件发现不会把它作为启用插件加载。即使部署者手动启用 manifest，缺少插件级 `config.env` 仍会令模块进入休眠；配置齐备时才按 Agent 模型、时间窗、频率、概率和冷却设置每 15 分钟检查。默认时间窗 01:00-06:00、频率八小时、概率 0.6；成功后的时间戳写入磁盘，重启会读取它避免立即重复触发。`Plugin/AgentDream/plugin-manifest.json.block:1-48`、`Plugin/AgentDream/AgentDream.js:119-187, 749-956`。

**源码事实。** 梦的召回不调用新的 Embedding API：近期、中期、深远三个时间桶从本地日记扫描而来，近期随机取至多三篇种子，中期取至多两篇；每篇依现有首 chunk 向量在所属 Agent 与公共目录的索引中检索。近期多种子重复命中形成 L1 共振桥梁，L1 再下探 L2，所有 L1/L2 向量归一化合成深层查询；最后把各层完整文件正文截到 `DREAM_MAX_RECALL_TOKENS * 1.5` 字符的共享上限。`Plugin/AgentDream/DreamWaveEngine.js:171-323, 390-469, 513-755`。

**源码事实。** DreamWave 的 Agent 边界是目录名和公共日记署名的启发式过滤：专属目录名包含 Agent 就允许，公共目录有不同署名时排除，无署名或读取失败时保留。它调用 KnowledgeBaseManager 搜索时会使用 TagMemo+ 语法并按路径去重。因而这是服务内的筛选约定，不是 RiverMemo 那样的显式 SQL file-ID 授权域。`Plugin/AgentDream/DreamWaveEngine.js:92-165, 400-468`。

**源码事实。** 生成的记忆树与 Agent system prompt 一起提交到本机 `/v1/chat/completions`，请求有 Bearer Key、最大输出 token、temperature 和默认 118 秒通信超时。只取 `message.content`，移除 reasoning 内容和 VCP 元思考标记，再写入梦日志并广播开始、关联、叙事或错误事件。叙事本身不直接改变日记；只有后续 Dream 工具提案获审批才会写入日记。`Plugin/AgentDream/AgentDream.js:198-363, 466-637, 688-738`。

**匿名化运行观察。** 一份启用 Dream 的外部部署中，产物会在日记联想之外混入梦境专属内容，呈现为独立的梦境叙事，而不是对既有日记作机械合并或摘要。这与源码分离“梦树召回 -> 独立 Agent prompt -> dream narrative -> 待审批操作”的步骤相容，但未运行复现，不能将叙事质量、梦境感或内容来源比例量化为通用结论。

**匿名化目录快照。** 快照中存在多个按 Agent 命名的梦目录。它与外部观察到的低比例 Dream 写入并不矛盾：文件数反映保留的文件集合，不能直接作为全部日记写入事件或来源占比的分母。目录命名属于部署约定，不应由此推断源码中的 Agent 边界过滤一定无歧义。

**源码事实。** AgentDream 工具操作只会把 merge、delete、insight 记录为 `pending_review`。管理端批准 merge 时先经 `DailyNote` 创建合并日记再逐一删除源文件；批准 delete 时删除目标文件；批准 insight 时经 `DailyNote` 创建梦感悟。删除后尝试从向量库移除文档，失败被忽略；操作结果和审批时间写回日志。拒绝只更新日志状态。`Plugin/AgentDream/AgentDream.js:466-637`，`routes/admin/dream.js:34-164`。

**静态推断。** 这提供了“模型建议、人工批准后执行”的写回闭环，但 merge 的新日记创建与后续多个源文件删除并非一个跨文件/SQLite 原子事务。创建成功后部分删除失败会作为逐项结果保留；实际索引删除异常被吞掉。因此故障后可能存在源文件、日志状态和索引暂时不一致的窗口，最终表现需运行验证。

## 作用域、安全、预算、缓存、观测与恢复

### 已确认的治理条件

| 主题 | 当前实现证据与边界 |
| --- | --- |
| 会话写回 | DailyNote 的启用态工具经单 FIFO 落盘，KnowledgeBaseManager 后台索引；路径组件会清理，更新目录匹配另有作者别名约束。它是当前代码快照中默认可用的会话记录路径，但具体 Agent 是否取得工具描述取决于其提示词的 `{{VCPDailyNote}}` 占位符。`Plugin/DailyNote/plugin-manifest.json:3-21,61-90`、`Plugin/DailyNote/dailynote.js:1573-1684`、`Plugin.js:1060-1087`。 |
| RAG 作用域 | 常规 RAG 由占位符解析出的日记本名限定，联合索引只查询指定成员；RiverMemo 再把成员转换为 `allowedFileIds` 传入原生层。普通全局 `search()` 仍存在，会枚举全部 `files.diary_name`，但本次追踪的 RAGDiary placeholder 主链传入了日记本名。`searchService.js:9-83, 359-375`。 |
| 管理鉴权 | `/admin_api` 在路由前经过管理员 Basic/Cookie 鉴权；未配置管理员凭据时返回 503，认证失败返回 401，并有 IP 尝试限制。Dream 审批端点由这一全局中间件保护。`server.js:658-835`。 |
| Dream 启用与路径边界 | 当前仓库快照的 Dream manifest 为 `.block`；匿名化运行观察显示某个外部部署已启用该链，并产出独立梦境叙事。部署者启用并配置后，审批路由才成为可达写回面。**静态推断：** `routes/admin/dream.js` 对日志文件名只检查 `.json` 后缀后 `path.join`，并未在该文件内做根目录规范化/前缀检查；操作中的 file URL 也直接转成本地路径再 `unlink`。即使入口受管理员认证保护，若攻击者能控制日志名或待审批日志内容，路径范围主要依赖调用者和日志可信性，不能从此路由确认有目录沙箱。`Plugin/AgentDream/plugin-manifest.json.block:1-48`、`routes/admin/dream.js:11-25, 49-59, 100-124, 211-218`。 |
| 查询预算 | 动态 K、修饰符倍率、RiverMemo 候选并集上限、时间路配额、外部 rerank token 上限、最终 K/去重均为显式控制点；Dream 有候选数量、深层 top-3、上下文最多六轮及回忆字符上限。具体生效数值取决于未读取的运行时环境与 `rag_params.json`。 |
| 缓存 | 插件有 query 与 embedding LRU/TTL 缓存，键是 JSON 参数 SHA-256；日记标签热更新会清 query cache。元思考主题向量有文件哈希磁盘缓存，元思考和 RAG 结果缓存还保存可重放的观察事件。`Plugin/RAGDiaryPlugin/CacheManager.js:6-153`，`MetaThinkingManager.js:34-103`。 |
| 可观测性 | RAG 广播检索详情，RiverMemo 元数据带 artifact/query/Omega/regime/候选统计，元思考广播阶段明细，Dream 广播生命周期事件。RiverMemo 仅在 `includeTrace` 才返回详细拓扑证据，而 RAGDiary 调用固定 `includeTrace: false`，所以正常 RAG Observer 不会取得逐候选拓扑轨迹。`RAGDiaryPlugin.js:3144-3225, 3316-3324`。 |
| 取消与超时 | Dream 的 HTTP 请求有超时；本次追踪的 RAG、RiverMemo N-API、TagMemo 派生队列和元思考链未找到请求级取消接口。派生任务有最大尝试次数与递增退避，但不是用户取消。`AgentDream.js:283-289`，`TagMemoEngine.js:3995-4099`。 |
| 运行恢复 | 索引、Tag 基线和 RiverMemo artifact 有启动恢复/懒载与兼容性检查；SQLite 健康状态会门控队列和派生任务。Dream 恢复的是调度时间戳和日志，内存中的 dream 对话上下文在 shutdown 时清空。`KnowledgeBaseManager.js:263-409`，`AgentDream.js:106-114, 919-956`。 |

**未运行验证。** SQLite 损坏、Rust artifact checksum 不匹配、Embedding 部分失败、管理端中途断线、重启落在梦审批中、模型/维度切换、外部 reranker 故障和 RiverMemo native ABI 缺失时的端到端可见结果，均只看到局部错误处理或重试代码，尚未通过运行确认。

## 与相邻谱系的可比与不可比边界

VCPToolBox 可以与传统长期记忆/RAG 实现比较以下事实：会话内日记工具写入、文件摄取、chunk/标签索引、关键词与向量候选融合、日记本作用域、结果格式、缓存、引用路径、观察事件和失败处理。

它不应因使用了向量和 rerank 就与所有知识资产管线混成同一成熟度序列。RiverMemo 的产物包含查询场、六路候选覆盖、结构路径与河网可观测性；元思考的中间产物是下一阶段查询方向。DailyNote 则是模型在会话内显式提交的日记变更；匿名化运行观察表明，AgentDream 在启用的外部部署中还产生独立梦境叙事，并在审批后才形成后台维护提案。它们与“当前问题的相关 chunk”是不同的输出契约。

反过来，这不说明其在权限、隔离、评测或生产稳定性上优于资料摄取型知识库。当前源码可确认 RiverMemo 的显式文件 ID 范围与管理 API 的认证入口，但不能确认多租户模型、统一文件沙箱、检索质量评测、A/B 实验或真实规模性能；本次检查范围内也未找到这些机制的可执行评估链。

## 未验证事项

- 未启动服务，未确认 RAGDiaryPlugin 在消息处理总链中的实际注册顺序、占位符替换后的最终请求位置及多占位符并发时的显示行为。
- 匿名化外部运行观察显示，会话内主动或指导式写入是日记的主要来源；本次未读取各 Agent 的实际系统提示词或工具调用日志，未独立复核哪些 Agent 带有 `{{VCPDailyNote}}`、具体计数口径，以及文件提交到可检索索引之间的实际时延。
- 匿名化目录快照确认该部署存在思维簇和梦目录，但未包含文件内容、修改时间、索引状态、调用日志或生成来源；本文不从目录统计反推 DailyNote/Dream 的精确比例，也不据其评估梦叙事或元思考质量。
- 未建立真实日记库，未确认文件 watcher、chunk 复用、标签派生、Rust artifact bootstrap 和 SQLite 恢复的实际时延、资源占用与异常日志。
- 未调用 Embedding、外部 reranker 或 Dream 模型，未验证失败重试、超时、部分向量缺失和输出质量。
- 未进行认证会话或恶意/异常 dream 日志测试；Dream 路由的路径处理结论仅是静态代码推断，不能替代实际部署配置和访问路径验证。
- 未验证各 Agent 的目录和署名约定能否满足实际隔离要求，也未验证公共无署名日记的预期归属。

## 关键源码索引

- `KnowledgeBaseManager.js:263-409`：SQLite、Tag 索引、Memo artifact 启动恢复与派生任务启动。
- `modules/knowledgeBase/ingestionPipeline.js:100-257`：文件批量摄取、切块、Embedding、标签和事务写入。
- `Plugin/DailyNote/plugin-manifest.json`、`Plugin/DailyNote/dailynote.js:1573-1691`：会话内 create/update 工具、常驻 FIFO、文件提交和知识库索引协调。
- `Plugin.js:1060-1087,1131-1159,1197-1346`、`modules/vcpLoop/toolExecutor.js:371-374`：工具描述注入、direct 调用和会话工具循环入口。
- `modules/knowledgeBase/searchService.js:9-83, 115-220, 368-471`：按日记本 KNN、TagMemo 增强和联合索引检索。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1200-1510, 2602-3375`：占位符入口、候选链、RiverMemo 范围和观察输出。
- `Plugin/RAGDiaryPlugin/MetaThinkingManager.js:108-332`：多阶段思维簇检索、向量反馈、缓存与广播。
- `TagMemoEngine.js:3539-3765, 3921-4099`：原生派生资产构建、队列、重试与恢复门控。
- `RiverMemoEngine.js:231-464, 467-545` 与 `rust-vexus-lite/src/rivermemo_topology_v3.rs`：N-API 输入、Rust/Rayon 排序和结果契约。
- `Plugin/AgentDream/plugin-manifest.json.block`、`Plugin/AgentDream/DreamWaveEngine.js:513-755`、`Plugin/AgentDream/AgentDream.js:119-363, 466-637`、`routes/admin/dream.js:49-164`：禁用态、启用条件、梦的多层召回、提案日志和审批写回。
