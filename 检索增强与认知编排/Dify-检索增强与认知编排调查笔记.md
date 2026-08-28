# Dify 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：以 API 后端的 ORM、摄取任务、检索服务、工作流节点、RAG Pipeline 服务和单元/集成测试入口作静态追踪；未启动 Dify、Celery、Redis、向量库、模型或外部数据源
>
> 调查范围：Dataset、Document、分段、索引及恢复；应用与工作流的知识检索；摄取型 RAG Pipeline；租户、预算、审计和追踪边界。不展开普通工作流、Agent 工具的其他行为，也不以静态代码评判召回质量、延迟或权限部署效果
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**源码直接确认。** Dify 的核心谱系是“知识资产管线”，并附带“工具化检索”和“上下文即时注入”两种消费面。长期事实源是租户拥有的 Dataset、Document、DocumentSegment 及可选的 ChildChunk、摘要、元数据和附件绑定；应用或工作流只按已配置的 Dataset ID 检索。Dataset 可选择经济型关键词索引或高质量向量/混合索引，并保存检索模型、Embedding 模型、分段结构和访问权限等配置（`api/models/dataset.py:166-213, 538-613, 913-959`）。

**源码直接确认。** 主摄取链是“建立文档记录并置为等待 -> 按租户隔离的 Celery 队列 -> 解析、清洗、切分、落分段 -> 关键词或向量建索引 -> 文档完成”；索引期间会持续写入阶段、时间、错误、token 数和延迟。高质量索引且开启摘要时，在文档完成后另投递摘要索引任务（`api/tasks/document_indexing_task.py:49-197`；`api/core/indexing_runner.py:81-165, 643-742, 886-929`）。

**源码直接确认。** 一次检索可以是单库模式：先由 LLM 路由器在允许的 Dataset 中选一库，再检索；也可以是多库模式：对各库并发取候选并进行跨库重排。普通应用将最终内容拼成上下文后交给 prompt 组装；Knowledge Retrieval 工作流节点则输出具备来源与分数的 `result` 对象数组，后续节点是否注入、改写查询或再次调用检索，由图定义决定（`api/core/rag/retrieval/dataset_retrieval.py:626-765, 768-916`；`api/core/app/apps/chat/app_runner.py:161-215`；`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-155`）。

**静态推断。** RAG Pipeline 将“资料来源到索引”的摄取过程表达成可发布工作流，包含草稿、发布快照、单步试跑、工作流/节点执行记录和文档管线日志；它是可编排的摄取图，而不是代码中内建的“检索结果自动产生下一认知方向”的循环。此次在 DatasetRetrieval、Knowledge Retrieval 节点及其调用方中未找到根据上一批召回自动生成下一次查询、思维簇、关系传播或后台记忆演化的固定机制；这仅覆盖上述入口，不构成全仓库的绝对否定。

## 谱系定位与系统边界

| 维度 | 当前代码快照中的结论 | 证据状态 |
| --- | --- | --- |
| 相似度/关键词召回 | 经济型索引使用关键词；高质量索引可用语义、全文或混合检索，并可重排。 | 源码直接确认 |
| 知识资产管线 | Dataset 下维护文档、规则、分段、索引状态、元数据和外部知识绑定。 | 源码直接确认 |
| 工具化检索 | 单库策略会让 LLM 在已允许的数据集描述中选择一个 Dataset；Agent 的检索工具入口另在相邻类目记录。 | 源码直接确认 |
| 上下文即时注入 | Chat/Completion runner 在模型调用前将检索文本和可选文件交给 prompt 组织步骤。 | 源码直接确认 |
| 摄取型 RAG Pipeline | Pipeline 以同租户 Dataset 和 `rag_pipeline` Workflow 关联，发布后可以异步运行。 | 源码直接确认 |
| 检索驱动认知编排 | 未发现内建递进查询、关系图路径或自动反馈循环。用户可在工作流图中显式连出后续节点。 | 静态推断 |
| 主动记忆写回 | 本次范围内未发现从会话自动抽取、合并或审批知识记忆的路径。文档摄取与摘要索引不是会话记忆维护。 | 静态推断 |

本笔记的“RAG Pipeline”限定为知识库摄取/索引的 Pipeline，不将所有 Dify Workflow 都归入 RAG。外部知识库也可作为 Dataset provider：本地 Dify 索引与外部端点返回的内容经过不同分支，但都被整理为统一来源结果（`api/core/rag/retrieval/dataset_retrieval.py:273-374`）。

## 事实对象、摄取与索引

### 持久化对象与可维护性

**源码直接确认。** Dataset 有 `tenant_id`，并持有索引技术、Embedding 提供方/模型、关键词数、检索模型 JSON、摘要设置、运行模式、Pipeline 关联、分段结构和多模态开关。其默认检索设置是语义检索、关闭 rerank、`top_k=2`；检索服务的另一默认值为 `top_k=4`，因此实际默认值取决于消费入口和是否已保存 Dataset 配置，不能简单视为全局常量（`api/models/dataset.py:175-213, 356-374`；`api/core/rag/retrieval/dataset_retrieval.py:100-106`）。

**源码直接确认。** Document 保存来源类型及来源信息、处理规则、文件关联、解析/清洗/切分/完成时间、token、索引耗时、暂停/错误/启用/归档状态、文档形态和元数据。可见来源枚举为上传文件、Notion 导入、网站抓取；状态对控制台另映射为排队、索引中、可用、停用、归档或错误（`api/models/dataset.py:538-632`）。DocumentSegment 保存原文、词数、token、索引节点 ID/哈希、问答答案、关键词、分段状态、命中次数及父子分段关联；父子模式用 ChildChunk 记录子块（`api/models/dataset.py:913-1012, 1129-1174`）。因此文档、普通分段、子块、元数据和启用/归档状态均是数据库层面的可编辑或可删除资产，而不是只存在于 prompt 的临时片段。

**源码直接确认。** DatasetProcessRule 支持 automatic、custom、hierarchical。自动规则默认按换行、500 token、50 token 重叠切分，并提供空白、URL/邮件等预处理规则；自定义/层级分段的 token 上限由配置控制且代码要求至少 50 token（`api/models/dataset.py:494-520`；`api/core/indexing_runner.py:551-589`）。文档删除先提交数据库删除，再投递异步清理任务删除分段、文件和向量索引，避免主事务与任务锁冲突（`api/services/dataset_service.py:1998-2036`）。

### 摄取、索引和状态生命周期

**源码直接确认。** 索引任务代理把普通任务放到 `document_indexing` 租户隔离队列，再调用 normal 或 priority Celery task；队列已有运行标记时把任务推入 Redis 等待列表，否则设置等待标记并直投。每个任务结束后按 `TENANT_ISOLATED_TASK_CONCURRENCY` 拉取下一批；普通和优先任务分别使用 `dataset`、`priority_dataset` 队列（`api/services/document_indexing_proxy/document_indexing_task_proxy.py:8-13`；`api/services/document_indexing_proxy/batch_indexing_base.py:14-78`；`api/tasks/document_indexing_task.py:200-267`）。这表明“同租户隔离”是排队/并发治理语义，并不等于以该队列替代数据库层的权限过滤。

**源码直接确认。** 执行任务先检查订阅批上传数与向量空间额度，失败会将本批文档标为错误；随后短事务写入 `parsing` 和开始时间，再在无此前状态锁的会话中执行索引。IndexingRunner 按“extract -> transform -> 保存分段 -> load”推进：抽取后置为 `splitting`，保存分段后置为 `indexing`，关键词线程或最多十个哈希分组的向量工作线程完成后置为 `completed`，并记录总 token 和索引耗时；异常写入 `error`、错误文本和停止时间（`api/tasks/document_indexing_task.py:49-124`；`api/core/indexing_runner.py:69-86, 448-540, 643-715, 886-929`）。高质量模式取得该租户的 Embedding 模型；经济型模式生成关键词表，父子模式另保存子块（`api/core/indexing_runner.py:655-701, 847-906`）。

**源码直接确认。** 暂停把数据库标记和 Redis `document_<id>_is_paused` 同时写入，索引的阶段转换与分块工作线程都会检查它；恢复删除标记并投递恢复任务。恢复任务按已停留的阶段分别从全流程、切分后或索引后继续；重试以 600 秒 Redis 锁防止同一文档批次并发重试，状态回到等待后再投递任务（`api/services/dataset_service.py:2073-2154`；`api/tasks/recover_document_indexing_task.py:15-50`；`api/core/indexing_runner.py:798-835`）。

**静态推断。** 阶段持久化、分段先落库再建索引、恢复分支及删除后清理降低了进程中断造成的不可恢复范围；但本次未在真实 Redis、Celery 重投递、向量库局部写入失败或节点故障时验证最终一致性、重复副作用和重试时序。

## 查询、候选与重排主链

### 入口、作用域和候选过滤

**源码直接确认。** 检索请求必须带 tenant、用户、应用、Dataset ID、策略、查询或附件；`knowledge_retrieval` 首先按 tenant 与 Dataset ID 取得“有已完成且启用且未归档文档”的本地库，外部 Dataset 例外可用；无可用库或查询/附件均为空时直接返回空列表（`api/core/workflow/nodes/knowledge_retrieval/retrieval.py:54-83`；`api/core/rag/retrieval/dataset_retrieval.py:141-149, 2035-2065`）。这是检索运行时的关键租户边界：即使调用方给出其他 ID，查询也要求 `Dataset.tenant_id == request.tenant_id`。

**源码直接确认。** 元数据过滤可关闭、手工配置或由模型生成条件。过滤 SQL 只选已完成、启用、未归档文档，再将命中文档 ID 传给后续检索；自动模式调用租户模型从允许的元数据字段生成 JSON 条件，失败会记录警告并返回无自动条件（`api/core/rag/retrieval/dataset_retrieval.py:1471-1560, 1576-1636`）。这是一条额外 LLM 调用和费用路径，而不是查询重写链。

**源码直接确认。** 单库模式先把每个可用 Dataset 描述为无参数工具：支持 tool call 的模型走 function-call router，否则走 ReAct router。路由结果仍会与“已允许 Dataset 列表”和 tenant 再次交叉验证，然后才取候选；该策略可能发生一次 LLM 路由调用并累积其用量（`api/core/rag/retrieval/dataset_retrieval.py:626-765`）。多库模式并发对每个库检索；若库的索引技术或 Embedding 不兼容，某些未使用 rerank 的组合会抛错（`api/core/rag/retrieval/dataset_retrieval.py:768-916`）。

### 召回、融合与排序

**源码直接确认。** 经济型库强制关键词检索。高质量库由配置选择语义、全文或混合检索；语义检索调用向量库，以 Dataset ID 作为 `group_id` 过滤，全文检索对转义后的查询执行，混合检索并行聚合关键词/全文/向量候选并按 `(provider, doc_id)` 或内容去重。文本查询与每个附件检索可并发执行（`api/core/rag/datasource/retrieval_service.py:93-173, 220-262, 303-405, 780-915`）。

**源码直接确认。** 重排有两种配置：租户的 rerank 模型，或向量权重与关键词权重的加权评分。混合检索在融合后执行后处理；多库模式在每库检索后，若开启 rerank 且超过一个库，再执行一次跨库后处理。无重排时，经济型结果按本地计算的关键词 TF-IDF 余弦分数排序，高质量结果按分数阈值和分数排序，再截取 `top_k`（`api/core/rag/data_post_processor/data_post_processor.py:38-134`；`api/core/rag/retrieval/dataset_retrieval.py:1873-1984`）。重排或融合分数与原始向量分数不一定同量纲，混合检索因此延后阈值过滤（`api/core/rag/datasource/retrieval_service.py:323-330, 880-913`）。

**静态推断。** 该实现是候选并发、去重、重排和排序的单轮检索架构。单库路由和自动元数据过滤会额外调用 LLM，但输出分别是 Dataset 选择和 SQL 过滤条件，并未在当前代码中构成“检索结果反馈到下一轮查询”的闭环。

## 结果契约、注入与工作流阶段

### 结果与引用契约

**源码直接确认。** Knowledge Retrieval 节点最终输出键为 `result`，类型为对象数组。每项为 `Source`：正文、标题、可选文件/摘要，以及 `_source=knowledge`、Dataset/Document/Segment ID 与名称、来源类型、分数、来源位置、文档元数据；父子分段还携带子块 ID、内容、位置与分数（`api/core/workflow/nodes/knowledge_retrieval/retrieval.py:13-51`；`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:138-155`）。节点还将路由或自动元数据过滤所消耗的 LLM token、价格、货币写入 process data 和 execution metadata。

**源码直接确认。** 本地检索命中会回查 DocumentSegment/Document/Dataset，只保留启用且完成的分段；内容可带问答形式的 `answer` 或摘要，最终按 score 降序并赋位置。检索结束的异步副作用会递增命中分段的 `hit_count`，并将文档、耗时交给应用 trace manager；查询审计则以独立事务写 `dataset_queries`，含文本/图片查询、Dataset、应用、操作者角色和时间（`api/core/rag/datasource/retrieval_service.py:472-778`；`api/core/rag/retrieval/dataset_retrieval.py:918-1038, 1058-1110`）。

**源码直接确认。** Chat 与 Completion 应用在生成模型调用之前调用检索；`retrieve` 将按分数排序的片段内容以换行连接为 context，同时可返回关联图片文件。若启用展示来源，回调会携带来源资源；之后 runner 调用 prompt 组织函数并传入 context 与 context files（`api/core/rag/retrieval/dataset_retrieval.py:378-624`；`api/core/app/apps/chat/app_runner.py:161-215`；`api/core/app/apps/completion/app_runner.py:118-174`）。因此来源对象可用于展示/追踪，而普通应用主注入物是拼接后的文本，不是自动保留结构化 `Source` 的模型协议。

### 工作流和 Pipeline

**源码直接确认。** Knowledge Retrieval 节点从变量池读取字符串 query 和可选文件数组；类型不符即节点失败。它可使用单库或多库配置、手工/自动元数据过滤、rerank 或加权配置，并将结构化结果交给后续图节点。没有选择 query/附件时节点成功返回空输出（`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-183, 185-301`）。是否把 `result` 格式化到 LLM prompt、以它计算下一 query，或在错误时改走另一支，属于用户绘制的 Workflow 连接和节点设置，不能由该节点单独保证。

**源码直接确认。** RAG Pipeline 的 `Pipeline` 记录 tenant、关联 workflow、公开/发布标志，并能在相同 tenant 下反查 Dataset；Pipeline 工作流保存草稿或按发布时间新建发布快照。发布时会扫描 `knowledge-index` 节点并更新关联 Dataset 的索引设置（`api/models/dataset.py:1722-1753`；`api/services/rag_pipeline/rag_pipeline.py:264-301, 361-414, 453-512`）。单节点试跑会保存节点执行、输入、过程数据、输出和草稿变量；文档来源执行还可留下 `DocumentPipelineExecutionLog`（`api/services/rag_pipeline/rag_pipeline.py:575-659`；`api/models/dataset.py:1756-1775`）。

**源码直接确认。** 已发布 Pipeline 的异步任务从文件读取序列化调用实体，在一个最多十线程的池中逐项运行；每个执行重新加载 account、tenant、pipeline、workflow，创建带 tenant、app 和触发来源的 workflow/节点执行仓库，随后用 `PipelineGenerator` 运行。任务 finally 部分继续租户队列、删除暂存调用文件并关闭会话（`api/tasks/rag_pipeline/rag_pipeline_run_task.py:37-116, 119-207`）。

## 预算、缓存、可观测与恢复

| 主题 | 源码直接确认的机制 | 已知边界或未验证项 |
| --- | --- | --- |
| 摄取额度 | 索引任务检查订阅批量上传限制与向量空间额度；IndexingRunner 还可在真正建索引前准入检查。 | 实际计划、额度计量和并发竞争未运行验证。 |
| 候选预算 | 每次检索有 `top_k` 与可选 score threshold；自定义分段受最大 token 配置约束。 | 未确认所有前端/API 层对 `top_k` 的最大值校验，也未测量超大候选的内存与延迟。 |
| 并发/超时 | 索引向量阶段最多十线程；检索由 `RETRIEVAL_SERVICE_EXECUTORS` 控制线程池，底层等待上限分别可见 300 秒和 3600 秒；多库遇异常设取消事件。 | Python 线程取消无法证明已中止底层模型/向量请求。 |
| 租户限流 | 工作流检索入口按 Redis 有序集计算最近 60 秒次数，超额写 `rate_limit_logs` 后失败。 | 该检查位于 `knowledge_retrieval`，本次未确认所有应用/工具入口是否共享同一限流面。 |
| 缓存/锁 | Redis 用于暂停、重试、网站同步和租户任务队列；Embedding 表按模型、哈希、提供方唯一，可作为持久化复用索引。 | 本次未发现面向“查询 + Dataset 配置”的检索结果缓存；未在 Redis 丢失或过期时运行验证。 |
| 观测 | OpenTelemetry trace span 覆盖检索与检索服务；应用 trace manager 接收检索文档和耗时；查询审计、命中计数、文档错误/时延、节点/工作流执行均可持久化。 | 追踪后端、采样、控制台展示和敏感内容脱敏策略未验证。 |
| 恢复 | 暂停/恢复、重试、分阶段恢复和删除后清理均有任务入口；Pipeline 执行使用暂存文件，finally 删除。 | 服务崩溃发生在数据库提交、向量写入和暂存文件删除之间时的精确恢复语义未运行验证。 |

关于安全，数据模型对 Dataset、Document、Segment、元数据绑定、附件绑定、外部知识绑定和 Pipeline 均保存 tenant ID；Dataset 权限表按 Dataset、账户和 tenant 建索引（`api/models/dataset.py:913-923, 1439-1463, 1530-1558, 1722-1753, 1802-1825`）。检索可用库查询也明确按 tenant 过滤。**静态推断：** 这些多层字段和入口过滤提供了预期的工作区隔离。**未运行验证：** 未以不同角色、仅本人/部分团队权限、服务 API、外部知识端点或签名文件 URL 进行越权测试，因此不能据此断言端到端授权效果，也不能判断检索文本是否足以抵御不可信文档中的提示注入。

## 与相邻谱系的可比/不可比边界

Dify 可以与 Open WebUI、AIO Hub 等知识资产管线比较资料来源、长期文档资产、异步索引、检索设置、引用、租户边界、发布和运行记录。其强项在于把这些对象持久化并提供应用、Workflow 与摄取 Pipeline 三个消费/编排面。

它不应按同一算法维度与 VCPToolBox 的 TagMemo、思维簇或元思考机制比较。Dify 的可配置图允许用户显式构造多阶段查询，但当前静态主链的默认输出是当前 query 的候选文本/来源，不是下一阶段的认知方向；是否形成循环取决于用户图，而非该知识检索组件的固定协议。

## 未验证事项

- 未运行文件、Notion、网站抓取、外部知识 API、解析器、Embedding、关键词、全文、向量库、reranker、摘要索引或多模态附件，故未验证实际召回、分数含义、引用完整性、吞吐、超时和费用。
- 未部署 Redis/Celery，故未验证租户队列的 FIFO、公平性、TTL 过期、任务重投递、线程取消和暂停/恢复在竞争下的实际表现。
- 未进行多租户、多角色、公开 Pipeline、服务 API 或文件签名 URL 的访问测试；本文的安全结论仅限静态过滤和字段传播。
- 未构造含恶意指令的知识文档，也未审查 prompt 组织模板，因此不能评价检索上下文的提示注入隔离。
- 未审查所有 Workflow 节点、插件和 Agent 工具调用路径；“未发现自动递进查询/记忆演化”仅覆盖本笔记列出的知识检索、应用 runner 和 Pipeline 主入口。

## 关键源码索引

- 数据资产、权限、审计、Pipeline 与执行日志：`api/models/dataset.py:166-213, 494-632, 913-959, 1215-1238, 1439-1463, 1722-1775`
- 摄取和状态机：`api/tasks/document_indexing_task.py:49-197`、`api/core/indexing_runner.py:81-165, 448-540, 643-715, 886-929`
- 暂停、重试、删除、恢复：`api/services/dataset_service.py:1998-2154`、`api/tasks/recover_document_indexing_task.py:15-50`
- 候选生成、融合与来源格式化：`api/core/rag/datasource/retrieval_service.py:93-173, 220-262, 303-405, 472-778, 780-915`
- 多库/单库策略、审计、租户过滤与限流：`api/core/rag/retrieval/dataset_retrieval.py:141-374, 626-916, 1058-1110, 1471-1560, 1873-2088`
- Workflow 结果契约与节点：`api/core/workflow/nodes/knowledge_retrieval/retrieval.py:13-83`、`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-301`
- 普通应用注入：`api/core/app/apps/chat/app_runner.py:161-215`、`api/core/app/apps/completion/app_runner.py:118-174`
- RAG Pipeline 草稿、发布、试跑与异步执行：`api/services/rag_pipeline/rag_pipeline.py:264-301, 361-512, 575-659`、`api/tasks/rag_pipeline/rag_pipeline_run_task.py:37-207`
