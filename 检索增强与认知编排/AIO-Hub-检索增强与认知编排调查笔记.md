# AIO Hub 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`（分支：`dev`）
>
> 调查方式：静态追踪当前 TypeScript、Rust/Tauri 实现、注册入口和单元测试夹具；未启动 Tauri、未调用真实 Embedding 或执行端到端检索
>
> 调查范围：Recall 思绪与 Knowledge 文档资料的对象、摄取/索引、查询、候选和重排、聊天/工具结果回注、权限、预算、缓存、监控与恢复；不评价检索质量，也不重复普通会话上下文机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**源码事实。** 当前 AIO Hub 有两个独立检索域。Recall 是可编辑的完整思绪条目集合，既能被 Agent 工具读写，也能在聊天请求构造时由占位符被动召回并替换进消息。Knowledge 是带文件来源、分块、索引任务和 chunk 回源的本地文档资料库；它以 Agent 授权为前提，经工具调用或用户显式资料引用执行查询、续读和研究结果回注。两域各有存储和查询实现，通用 `retrievalRouter` 可在独立调用中做配额分流与 RRF，但此次沿聊天实际入口未发现把 Recall 与 Knowledge 自动混合注入的路径。

**谱系定位。** Recall 同时属于“相似度召回”和“上下文即时注入”：稳定预设从关键词、条目内容向量及标签共现图产生候选，融合后按优先级重排；其输出是当回合 prompt 中的格式化条目。Knowledge 是“知识资产管线”与“工具化检索”：文件摄取、FTS/BM25、按向量空间隔离的语义检索、相邻块扩展和受权读取已经落在可执行代码中。Knowledge 的 research 会按规则拆分问题、搜索和读取，并据命中或粗略冲突补充查询；它不调用 LLM 来生成下一步计划或综合答案，所谓 conclusion 是对证据片段的模板化排序摘要。因此不能等同于检索驱动的多阶段认知编排。

**证据状态。** 本文“源码事实”均可由当前快照中的实现复查；“静态推断”只描述代码在成功依赖、配置和调用条件下的预期。真实模型向量质量、Tauri IPC、文件系统异常、监控界面、缓存命中率与权限在真实 Agent 运行时的效果均未运行确认。

## 谱系定位与系统边界

Recall 后端在应用启动时建立 SQLite repository 并恢复内存读模型，前端通过 `services/api.ts` 调用其门面。一个集合包含完整 Markdown 条目、带权标签、启用标记、优先级、内容哈希与资产引用；检索返回条目、集合名、分数、匹配类型、高亮和信号。它不将条目自动切块，也不保存外部文档来源。条目可以由界面和 `recall-basic`/`recall-admin` Agent 工具创建、更新、批量改元数据、删除及可选向量化；写入后的向量是否已经与内容同步取决于调用方是否请求自动向量化或另行索引。见 `src-tauri/src/recall/core.rs`、`src/tools/recall/actions/agentActions.ts`。

Knowledge 的持久对象是资料库、文件或目录来源、来源文件、可领取的摄取任务、文档、chunk、FTS 索引、向量记录和 chunk 边。资料库清单在 `knowledge_meta.db`，每个资料库另有 SQLite 文件；文档保存来源路径、校验和、解析器版本和版本号，chunk 保存标题、heading 与字符偏移，因此工具结果可回溯来源。其配置只支持定长分块，默认目标为 1000 字符、重叠 120 字符；关键词索引强制开启，语义和图边可按资料库配置启用。见 `src-tauri/src/knowledge/types.rs:133-283`、`src-tauri/src/knowledge/repository.rs:42-130`。

Recall 和 Knowledge 的“图”含义不同。Recall 的图是由同一条目中带权标签构建的标签共现关系，用于受限扩散；Knowledge 的图边是摄取时在文档 chunk 间建立的邻接关系，用于给已有命中补充邻块。二者都没有在已读产品路径中维护跨回合的思维簇、关系路径状态或后台记忆演化。

## 事实对象、摄取与索引

### Recall：条目写入及派生向量

Recall 的 SQLite 真源分为主数据与向量库；启动初始化后从两库恢复集合、倒排索引、向量矩阵和按模型隔离的标签池。新增或更新条目先持久化内容及内容哈希，再由前端 `IndexingOrchestrator` 调用当前默认 Embedding 配置，并把条目向量写回后端；标签向量也单独同步，标签池索引可重建。向量加载和标签池以模型身份区分，空、维度不一致或非有限向量在余弦计算中降为零，避免异常值进入排序。该条链确认的是实现顺序，不表示任何条目必然已向量化。见 `src/tools/recall/logic/orchestrator.ts`、`src/tools/recall/actions/agentActions.ts:130-265`、`src-tauri/src/recall/ops.rs`、`src-tauri/src/recall/utils.rs`。

Recall 导出只保留集合源数据和引用资产，不保留向量、标签池或内存索引，导入后需重建派生数据。旧 `.aio-kb` 与旧文件目录可迁移到 Recall，也可在用户确认下把旧条目的标题和 Markdown 转为 Knowledge 文档；后一路径不转换旧标签、优先级、启用状态、条目关联和附件。迁移以源指纹、确认和提交状态保护中断续跑，验证失败不会清理源目录。见 `src/tools/recall/ARCHITECTURE.md:144-170` 与 `src-tauri/src/recall/storage/legacy_import.rs`；这部分以架构说明补充实现检查，未实际迁移验证。

### Knowledge：摄取队列、分块和索引空间

文件导入先检查路径、大小、校验和和 parser version，在每个资料库 SQLite 中事务性登记去重后的 upsert 任务。前端 worker 用 lease 领取任务，读取并解析文件后携带原始校验和与 parser version 完成任务；后端再次验证 lease 未过期、未取消、来源未变化，再原子替换文档、chunk 和全文索引。目录来源使用不跟随符号链接的遍历，可配置递归和忽略规则；重新扫描会为消失文件建立 delete 任务。见 `src-tauri/src/knowledge/repository.rs:268-415,488-591,763-980,1027-1148` 与 `src/tools/knowledge-base/services/ingestQueue.ts`。

语义索引不在摄取事务中完成。队列处理完有导入的文档后，前端按 batch 调用 Embedding；首批生成向量空间描述符，后续批次并发数受运行配置限制，每批写入后端。空间描述符含模型规范身份、维度、查询/文档 task type、编码和适配器版本；查询时会拒绝与现有空间身份或维度不一致的路由。向量化失败时，文档与关键词索引仍已保存，调用结果只返回“稍后补齐”的警告。静态推断：这使关键词检索成为语义索引不可用时的可用资料入口。见 `src/tools/knowledge-base/services/service.ts:531-683`。

队列任务有 pending、processing、retry、failed、completed、cancelled 状态。过期 lease 被下一次领取动作恢复为 retry 或 failed；可取消未领取任务，可手动把失败任务重置为 pending。文档更新前会保存旧的语义 fallback chunk；查询同一空间时排除新文档的旧向量而回查保留快照，避免新正文与旧向量直接混配。此恢复保护只覆盖代码所示的下一次领取、更新和查询，不代表应用崩溃时所有前端 worker 都能自动恢复。见 `src-tauri/src/knowledge/repository.rs:488-760,763-980,2990-3046`。

## 查询、候选与重排主链

### Recall：从请求到稳定预设

Recall 门面首先对主查询清洗并从全局标签池匹配标签；次查询不参与标签匹配。带缓存调用会编译所选预设，未命中缓存时才执行管线。`algorithmic` 预设不请求 Embedding：它规范化和分词后，从倒排索引及标题包含关系取候选，候选预算为 80。`comprehensive` 在此基础上准备一次主/次查询的加权融合向量，加载目标集合的模型向量和标签池，再并列取得关键词、内容向量、邻近标签和标签图条目候选。见 `src/tools/recall/services/api.ts:220-316`、`src/tools/recall/services/retrievalPipeline.ts:182-357`、`src-tauri/src/recall/retrieval_modules.rs:1477-1656`。

综合预设的标签扩散有一跳、每标签最多 12 个邻居、最多 80 个状态及 0.6 最大流出量；图由当前作用域中同条目标签的权重积临时构造，已访问标签不会回流。它并不改变内容向量所使用的原查询，也不据结果生成第二阶段自然语言查询。候选信号按信号类型做 ln(1+x) 后的当前查询内最大值归一化，以固定权重相加；随后只对大于默认值的条目优先级施加对数加成。阈值比较的是优先级重排前的 relevance score，集合阈值优先于请求阈值，最后以分数、集合 ID、条目 ID 的稳定顺序截断。结果保留各信号类型与贡献，但最终 `RecallResult` 未暴露模块 ID；完整模块来源保留在 pipeline trace。见 `src-tauri/src/recall/retrieval_modules.rs:577-765,958-1399`。

Recall 的集合、启用状态和标签约束在候选阶段及 finalizer 前再次检查；标签条件是“条目任一普通或核心标签命中请求标签”。输入 `minScore` 和集合配置均限制在 0 到 1。综合预设无法准备查询向量时，只有调用方显式准许时才退回 `algorithmic`，返回结果记录 requested/actual preset 和失败原因；其他编译、工件或 Runner 错误作为结构化失败上抛。见 `src/tools/recall/services/retrievalPipeline.ts:291-343`、`src-tauri/src/recall/retrieval_pipeline.rs:879-1113`。

### Knowledge：每库检索、融合和邻接扩展

Knowledge 查询可指定 keyword、semantic、hybrid 或 auto。auto 在有查询向量时落为 hybrid，否则为 keyword；前端按“向量空间 ID + 路由”分组，逐组生成查询向量。如果 auto 的向量生成或路由身份检查失败，该组退回关键词并在 trace 标明原因；显式 semantic/hybrid 错误不会自动退回。每个资料库中，FTS5 的 BM25 和全量向量余弦候选以 chunk ID 合并；双路命中的分数为 0.6 倍关键词分数加 0.4 倍向量分数，单路命中保留本路分数。见 `src/tools/knowledge-base/services/service.ts:371-529`、`src-tauri/src/knowledge/repository.rs:1914-2021,2960-3056`。

后端再从已有候选沿 chunk edge 补一跳邻块，以种子分数的 0.08 作为图信号；前端 Agent 工具层会按每库原排序换算 RRF rank score，去重后可对前 topK 命中再添加前后相邻 chunk，新增项分数为种子 rank score 的一半。最终按 topK 与总字符预算截断，响应携带原始分数、rank score、BM25/向量/图信号、资料库、文档、chunk、标题、heading 和来源路径。这里的图扩展是局部证据连续性，而不是对下一轮问题方向的推断。见 `src-tauri/src/knowledge/repository.rs:3059-3096`、`src/tools/knowledge-base/services/application.ts:258-377`。

通用 `routeRetrieval` 支持单域或 mixed 请求：mixed 并行取得 Recall 和 Knowledge 的固定配额，再以 `1/(60+域内名次)` 做 RRF 并按域名和对象 ID 打破平手。该函数是可调用服务，不能据其存在推断默认聊天路径已经启用跨域融合；此次检查的 Recall processor 与显式 Knowledge 路径均各自调用本域服务。见 `src/services/retrievalRouter.ts`。

## 阶段、反馈与结果注入

### Recall 的被动注入

聊天上下文处理器优先级为 450。它扫描 `【recall::...】`，记录已废弃 `【kb】` 的告警但不执行旧检索；若 Agent 开启自动注入且没有无指定集合的占位符，会把未被引用的启用 binding 插入 context head 或最后一个用户消息之前。处理器从 session history 提取最后用户消息和最近一条 assistant 消息作为主/次查询，并在每个占位符前检查集合是否存在于当前 Agent 的 enabled bindings。未授权集合只记日志且保留原占位符，授权调用则以格式化条目替换占位符。见 `src/tools/llm-chat/core/context-processors/recall-processor.ts:116-257`。

Recall 占位符还有 always、turn、gate 与 static 模式。turn 以用户轮次整除判定，gate 在最近指定深度的消息里查字面关键词，static 可按条目 ID 或 `all` 读取已启用条目。语义结果在格式化前按最大字符数逐条累加，超过预算即停止，不会截断单条内容；异常时返回配置的空文本或错误文本并记录日志，因此一次检索失败不会直接使上下文处理器抛出。输出模板默认包含集合名、条目 key、完整内容和两位小数分数。见 `src/tools/recall/logic/placeholderRetrieval.ts`、`src/tools/recall/core/retrievalPolicy.ts`。

这一路径的作用域是 Agent 配置中的 binding，不是按用户、租户或文档来源的后端访问控制；Recall Agent 工具本身从 workspace 解析集合名称，所读代码中未见将工具调用绑定到该 Agent 可访问集合的同等校验。静态推断：Recall 更适合作为同一桌面工作区内由 Agent 配置约束的记忆域，不能据此声称具有多租户隔离。

### Knowledge 的工具结果与规则化研究

Knowledge 注册为 Agent 可调用的 `listLibraries`、search、read、research。工具必须取得含 Agent ID 与 `knowledgeAccess` 的上下文：未启用则拒绝；指定资料库必须在 allowlist；未指定只在 `allowSearchAll` 时扩展为该 allowlist；资料库还必须存在、可用且至少有关键词或语义索引。read 另要求 `allowDocumentRead`，research 另要求 `allowResearch`。过滤器可进一步约束文档 ID、来源类型、路径前缀和标签。见 `src/tools/knowledge-base/services/access.ts`、`src/tools/knowledge-base/services/application.ts:223-575`、`src/tools/knowledge-base/knowledge-base.registry.ts`。

用户也可在聊天输入显式选择资料库。发送前会重新验证其中的稳定 library ID 和当前授权，而不是信任消息里仅用于显示的资料库快照；search 把结构化结果序列化为工具事件文本后再供后续回答使用。research 的默认上限为 3 轮、12 次 search/read、24000 证据字符和 120 秒，且可取消。它把问题按标点切成至多四个初始/缺口查询，对每轮命中读取 chunk，按相同标题中简单否定词差异记录潜在冲突；无命中或冲突时追加固定的补充查询。其“结论”只按问题词与摘录的重合度列出证据和空缺，不请求模型综合。见 `src/tools/knowledge-base/services/reference.ts`、`src/tools/knowledge-base/services/research.ts:90-498`、`src/tools/llm-chat/composables/chat/useChatHandler.ts:247-339`。

Knowledge 的结果契约使调用记录可显示来源：工具元数据保留 Agent ID、实际策略、降级原因、命中数量及每个 chunk 的资料库/文档/路径/位置；研究结果还保留查询列表、引用、冲突、空缺、轮数、调用数、证据字符、耗时和终止原因。静态代码确认这些字段会被构造和传递，未运行确认聊天 UI、模型工具协议是否完整呈现或遵从“保留来源”的提示。

## 预算、作用域、可观测与恢复

| 主题 | Recall | Knowledge |
| --- | --- | --- |
| 查询与结果预算 | 预设候选预算 80，最终条目上限 1-100；占位符可额外施加条目数、阈值和字符总量 | 工具 search 的 topK 为 1-50、字符总量为 1000-50000；read 强制字符上限，研究另有限制轮次、调用数、证据字符和超时 |
| Embedding 与降级 | 仅综合预设需要默认 Embedding 模型；请求级不能覆盖模型，准备失败可显式退到关键词预设 | 分批次数、并发、重试和间隔来自运行配置；auto 允许每个向量空间组降到关键词，显式语义策略失败 |
| 缓存 | 进程内 LRU 风格结果缓存，容量默认 200；键含规范化双查询、集合/标签、权重、limit、阈值、预设、配置哈希、模型身份、资产代际和算法版本 | 本次阅读范围未找到查询结果缓存；向量、FTS、语义 fallback 和摄取任务属于持久索引/恢复数据，不等同于查询缓存 |
| 访问边界 | 被动注入限制到启用的 Agent binding；本次未见在 Recall 工具操作上同级的 Agent allowlist | `knowledgeAccess` 控制启用、allowlist、全库搜索、续读与研究，并在执行时重验资料库可用性 |
| 观察面 | Rust 发送 `recall-monitor`，RAG payload 可含耗时、命中数、预设、运行结果、trace 与结构化错误 | 工具/研究返回 trace、降级理由、来源和进度对象；本次未找到对应的后端全局监控事件 |
| 恢复 | SQLite 是真源；向量和标签索引可从持久数据重载或重建，导出不携带派生索引 | 每库 SQLite 保存任务和 lease；下次 claim 恢复过期 lease，文件变更以 checksum/parser version 防止旧解析结果提交 |

Recall 缓存按最近访问时间更新，达到容量时删去约五分之一最旧项；它只存在 `RecallState` 内存，进程重启即丢失。模型切换/资产代际变化通过缓存键分隔，配置流程还会清空当前检索缓存。pipeline trace 逐节点记录耗时、输入/输出数量、截断量、原因、配置哈希、工件 bundle 和实际预设，故可以静态确认其可解释字段比最终条目结果丰富。见 `src-tauri/src/recall/commands/retrieval_cache.rs`、`src-tauri/src/recall/retrieval_pipeline.rs:367-488,879-1057`、`src-tauri/src/recall/monitor.rs`。

未在已读入口中发现 Recall 或 Knowledge 对不可信文档内容进行提示注入隔离、净化或模型侧安全标注。两域都会把检索内容作为可供模型消费的文本，Knowledge 的结果含来源与结构化字段、Recall 的注入有模板，但这些是可追溯和格式边界，不足以静态推断能抵御内容级提示注入。

## 记忆写回与主动维护

Recall 的 Agent 工具可以新增、修改或删除条目，删除需要显式 `confirm`；写回是模型或用户调用工具后发生的动作，不是从会话自动抽取事实。自动向量化是调用参数，默认关闭。Knowledge 可导入、更新标签、删除文档、重扫目录和重建索引，但未发现从聊天自动摘要并写回资料库的路径。此次搜索范围为 `src/tools/recall`、`src/tools/knowledge-base`、聊天接入及其后端命令，未发现无新消息触发的复盘、合并、遗忘或审批队列；因此只能表述为“本次未找到主动记忆演化实现”，不排除其他未读模块。

## 与相邻谱系的可比/不可比边界

- 可与传统 RAG 的共同维度包括：Recall 的多信号候选、阈值/优先级重排、缓存与 trace；Knowledge 的资料摄取、来源回溯、语义空间隔离、BM25/向量混合、权限和任务恢复。
- 与 Lorebook 或世界书的可比处是 Recall 在发送前按 binding 与激活规则把结果放入上下文；但其条目检索可使用向量和标签共现，而不是只做字面触发。
- Knowledge 的工具检索与研究有显式的 search/read 循环、相邻证据读取及预算终止，能够与其他工具化本地资料检索比较；研究的下一查询来自固定拆分、无命中或粗略冲突规则，不能称为模型驱动的查询规划。
- Recall 的标签扩散和 Knowledge 的 chunk 邻接都只改变当前查询的候选集合。当前稳定链中没有以检索结果改写查询向量、生成新自然语言问题、维护跨回合图状态，故不可与 VCPToolBox 一类思维簇、关系路径和连续认知方向机制等同。
- `retrievalRouter` 的 RRF mixed 模式是独立服务能力。是否有产品页面或 Agent 策略实际调用它、以及 RRF 对混合来源质量的影响，属于未运行和未追踪调用方的事项。

## 未验证事项

- 未运行 Tauri，因此未确认启动时 Recall 初始化、Knowledge 延迟初始化、IPC 参数、SQLite schema 升级、目录权限和实际文件解析是否与静态路径一致。
- 未调用任何 Embedding 服务，未验证 Recall 默认模型身份与已存向量的匹配、Knowledge 分批重试、auto 降级、语义 fallback 或不同空间的真实召回结果。
- 未做端到端聊天请求，未确认 Recall 注入的最终消息顺序、字符预算对 token 数的实际影响，或显式 Knowledge 工具事件如何被具体模型协议消费。
- 未做权限对抗测试。已确认 Knowledge 的前端工具层执行时授权检查，但没有审计 Tauri command 是否可被同一桌面应用内其他前端模块直接调用，亦未验证 Recall binding 在所有 Agent 工具调用链上的约束效果。
- 未发现项目自带离线质量集、A/B、召回率、延迟基准或生产遥测聚合。存在单元测试与合同夹具可验证结构和分支，不能证明检索质量、性能或用户可观察行为。

## 关键源码索引

- `src/tools/llm-chat/core/context-processors/recall-processor.ts`：Recall 占位符、binding 授权和聊天上下文替换入口。
- `src/tools/recall/services/api.ts`、`src/tools/recall/services/retrievalPipeline.ts`：Recall 门面、缓存、查询向量准备与 fallback。
- `src-tauri/src/recall/retrieval_modules.rs`、`src-tauri/src/recall/retrieval_pipeline.rs`：两个稳定预设、候选模块、重排、编译、Runner 与 trace 契约。
- `src-tauri/src/recall/storage/repository.rs`、`src-tauri/src/recall/storage/legacy_import.rs`：Recall SQLite 真源与旧数据迁移。
- `src/tools/knowledge-base/services/ingestQueue.ts`、`src/tools/knowledge-base/services/service.ts`：Knowledge 队列消费、向量化和按空间查询向量准备。
- `src-tauri/src/knowledge/repository.rs`：Knowledge 的摄取事务、FTS/BM25、向量、fallback、图边和任务恢复。
- `src/tools/knowledge-base/services/application.ts`、`src/tools/knowledge-base/services/research.ts`：Knowledge 授权、工具结果预算、续读与规则化研究循环。
- `src/tools/knowledge-base/knowledge-base.registry.ts`、`src/tools/llm-chat/composables/chat/useChatHandler.ts`：Agent 工具注册和用户显式资料引用的聊天回注。
