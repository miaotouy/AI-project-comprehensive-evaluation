# Dify 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`e568478f8f2b95efc189b698c2f4386a7dbe1c3e`（分支：`main`）
>
> 调查方式：以 API 后端的 ORM、摄取任务、索引执行适配器、检索服务、工作流节点、RAG Pipeline 服务、知识库 API Key 作用域与 KnowledgeFS 契约入口作静态追踪；未启动 Dify、Celery、Redis、向量库、模型或外部数据源
>
> 调查范围：Dataset、Document、分段、索引及恢复；应用与工作流的知识检索；摄取型 RAG Pipeline；KnowledgeFS 新型知识面；租户、预算、审计和追踪边界。不展开普通工作流、Agent 工具的其他行为，也不以静态代码评判召回质量、延迟或权限部署效果
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**源码直接确认。** Dify 的核心谱系是“知识资产管线”，并附带“工具化检索”和“上下文即时注入”两种消费面。长期事实源是租户拥有的 Dataset、Document、DocumentSegment 及可选的 ChildChunk、摘要、元数据和附件绑定；应用或工作流只按已配置的 Dataset ID 检索。Dataset 可选择经济型关键词索引或高质量向量/混合索引，并保存检索模型、Embedding 模型、分段结构和访问权限等配置（`api/models/dataset.py:150`、`api/models/dataset.py:302-372`、`api/models/dataset.py:374-553`、`api/models/dataset.py:554-647`）。

**源码直接确认。** 主摄取链是“建立文档记录并置为等待 -> 按租户隔离的 Celery 队列 -> 解析、清洗、切分、落分段 -> 关键词或向量建索引 -> 文档完成”；索引期间会持续写入阶段、时间、错误、token 数和延迟。高质量索引且开启摘要时，在文档完成后另投递摘要索引任务。执行体已从原先的单一 IndexingRunner 收敛为应用层 `DocumentIndexingService` 加适配器 `IndexingExecutionAdapter`，后者提供抽取、转换、准入、计数、写入和回滚的生命周期接口（`api/services/knowledge/indexing/execution.py:77`；`api/services/knowledge/indexing/adapters/execution.py:49-208`；`api/tasks/document_indexing_task.py:51-204`）。

**源码直接确认。** 一次检索可以是单库模式：先由 LLM 路由器在允许的 Dataset 中选一库，再检索；也可以是多库模式：对各库并发取候选并进行跨库重排。普通应用将最终内容拼成上下文后交给 prompt 组装；Knowledge Retrieval 工作流节点则输出具备来源与分数的 `result` 对象数组，后续节点是否注入、改写查询或再次调用检索，由图定义决定（`api/core/rag/retrieval/dataset_retrieval.py:156-405`、`api/core/rag/retrieval/dataset_retrieval.py:649-946`；`api/core/app/apps/chat/app_runner.py:173-196`；`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-184`）。

**静态推断。** RAG Pipeline 将“资料来源到索引”的摄取过程表达成可发布工作流，包含草稿、发布快照、单步试跑、工作流/节点执行记录和文档管线日志；它是可编排的摄取图，而不是代码中内建的“检索结果自动产生下一认知方向”的循环。DatasetRetrieval、Knowledge Retrieval 节点及其调用方中未找到根据上一批召回自动生成下一次查询、思维簇、关系传播或后台记忆演化的固定机制；这仅覆盖上述入口，不构成全仓库的绝对否定。

**源码直接确认。** 快照中出现了与既有 Dataset 并行的第二套知识面 KnowledgeFS：它由部署开关放开，通过固定的 OpenAPI/Capability 契约与独立部署的 KnowledgeFS 服务交互，并提供独立的检索 v2 工作流节点、文本存储与向量存储适配（`api/services/knowledge_fs/feature_service.py:1-37`；`api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py:166-203`；`api/knowledge-fs-contract/README.md`）。它属于云端/企业版或显式打开的社区开发模式，不能当作既有知识库默认路径的替代。

## 谱系定位与系统边界

| 维度 | 当前代码快照中的结论 | 证据状态 |
| --- | --- | --- |
| 相似度/关键词召回 | 经济型索引使用关键词；高质量索引可用语义、全文或混合检索，并可重排。 | 源码直接确认 |
| 知识资产管线 | Dataset 下维护文档、规则、分段、索引状态、元数据和外部知识绑定。 | 源码直接确认 |
| 工具化检索 | 单库策略会让 LLM 在已允许的数据集描述中选择一个 Dataset；Agent 的检索工具入口另在相邻类目记录。 | 源码直接确认 |
| 上下文即时注入 | Chat/Completion runner 在模型调用前将检索文本和可选文件交给 prompt 组织步骤。 | 源码直接确认 |
| 摄取型 RAG Pipeline | Pipeline 以同租户 Dataset 和 `rag_pipeline` Workflow 关联，发布后可以异步运行。 | 源码直接确认 |
| KnowledgeFS 知识面 | 独立契约的托管知识服务；有独立检索 v2 节点与存储适配，需部署开关与签名能力。 | 源码直接确认（开关与契约）；运行效果未验证 |
| 检索驱动认知编排 | 未发现内建递进查询、关系图路径或自动反馈循环。用户可在工作流图中显式连出后续节点。 | 静态推断 |
| 主动记忆写回 | 本次范围内未发现从会话自动抽取、合并或审批知识记忆的路径。文档摄取与摘要索引不是会话记忆维护。 | 静态推断 |

本笔记的“RAG Pipeline”只覆盖知识库摄取/索引的 Pipeline；workflow 图中的其他节点按工作流本身归类，RAG 分类止于知识摄取与索引这一层。外部知识库也可作为 Dataset provider：本地 Dify 索引与外部端点返回的内容经过不同分支，但都被整理为统一来源结果（`api/core/rag/retrieval/dataset_retrieval.py:406-648`）。

## 事实对象、摄取与索引

### 持久化对象与可维护性

**源码直接确认。** Dataset 有 `tenant_id`，并持有索引技术、Embedding 提供方/模型、关键词数、检索模型 JSON、摘要设置、运行模式、Pipeline 关联、分段结构和多模态开关。其默认检索设置是语义检索、关闭 rerank、`top_k=2`；检索服务的另一默认值为 `top_k=4`，因此实际默认值取决于消费入口和是否已保存 Dataset 配置，属入口级取值（`api/models/dataset.py:150-301`；`api/core/rag/datasource/retrieval_service.py:271-302`）。

**源码直接确认。** Document 保存来源类型及来源信息、处理规则、文件关联、解析/清洗/切分/完成时间、token、索引耗时、暂停/错误/启用/归档状态、文档形态和元数据。可见来源枚举为上传文件、Notion 导入、网站抓取；状态对控制台另映射为排队、索引中、可用、停用、归档或错误（`api/models/dataset.py:374-553`）。DocumentSegment 保存原文、词数、token、索引节点 ID/哈希、问答答案、关键词、分段状态、命中次数及父子分段关联；父子模式用 ChildChunk 记录子块（`api/models/dataset.py:554-647`）。因此文档、普通分段、子块、元数据和启用/归档状态均是数据库层面的可编辑或可删除资产，而不是只存在于 prompt 的临时片段。

**源码直接确认。** DatasetProcessRule 支持 automatic、custom、hierarchical。自动规则内置为按换行、500 token、50 token 重叠切分，并提供空白、URL/邮件等预处理规则；自定义/层级分段的 token 上限由配置控制，索引处理器要求介于 50 与该配置上限之间（`api/models/dataset.py:320-327`；`api/core/rag/index_processor/index_processor_base.py:120-127`）。文档删除先提交数据库删除，再投递异步清理任务删除分段、文件和向量索引，避免主事务与任务锁冲突（`api/services/knowledge/dataset_service.py:1967-2065`；`api/services/knowledge/documents/application.py:192-260`）。

### 摄取、索引和状态生命周期

**源码直接确认。** 索引任务代理把普通任务放到 `document_indexing` 租户隔离队列，再调用 normal 或 priority Celery task；队列已有运行标记时把任务推入 Redis 等待列表，否则设置等待标记并直投。每个任务结束后按 `TENANT_ISOLATED_TASK_CONCURRENCY` 拉取下一批；普通和优先任务分别使用 `dataset`、`priority_dataset` 队列（`api/services/document_indexing_proxy/document_indexing_task_proxy.py:8-13`；`api/services/document_indexing_proxy/batch_indexing_base.py:14-78`；`api/tasks/document_indexing_task.py:205-272`）。这表明“同租户隔离”作用于排队与并发治理，数据库层的权限过滤仍由查询侧承担。

**源码直接确认。** 执行任务先检查订阅批上传数与向量空间额度，失败会将本批文档标为错误；随后短事务写入 `parsing` 和开始时间，再在无此前状态锁的会话中执行索引。索引应用服务按“extract -> transform -> 保存分段 -> load”推进：抽取后置为 `splitting`，保存分段后置为 `indexing`，关键词线程或最多十个哈希分组的向量工作线程完成后置为 `completed`，并记录总 token 和索引耗时；异常写入 `error`、错误文本和停止时间（`api/tasks/document_indexing_task.py:51-204`；`api/services/knowledge/indexing/execution.py:77-160`；`api/services/knowledge/indexing/adapters/execution.py:148-208`）。高质量模式取得该租户的 Embedding 模型；经济型模式生成关键词表，父子模式另保存子块。

**源码直接确认。** 暂停把数据库标记和 Redis `document_<id>_is_paused` 同时写入，索引的阶段转换与分块工作线程都会检查它；恢复删除标记并投递恢复任务。恢复任务按已停留的阶段分别从全流程、切分后或索引后继续；重试以 600 秒 Redis 锁防止同一文档批次并发重试，状态回到等待后再投递任务（`api/services/knowledge/dataset_service.py:2066-2154`；`api/tasks/recover_document_indexing_task.py:17-50`；`api/services/knowledge/indexing/adapters/execution.py:83-100`）。

**静态推断。** 阶段持久化、分段先落库再建索引、恢复分支及删除后清理降低了进程中断造成的不可恢复范围；但本次未在真实 Redis、Celery 重投递、向量库局部写入失败或节点故障时验证最终一致性、重复副作用和重试时序。

## 查询、候选与重排主链

### 入口、作用域和候选过滤

**源码直接确认。** 检索请求必须带 tenant、用户、应用、Dataset ID、策略、查询或附件；`knowledge_retrieval` 首先按 tenant 与 Dataset ID 取得“有已完成且启用且未归档文档”的本地库，外部 Dataset 例外可用；无可用库或查询/附件均为空时直接返回空列表（`api/core/workflow/nodes/knowledge_retrieval/retrieval.py:54-92`；`api/core/rag/retrieval/dataset_retrieval.py:2098-2129`）。这是检索运行时的关键租户边界：即使调用方给出其他 ID，查询也要求 `Dataset.tenant_id == request.tenant_id`。

**源码直接确认。** 元数据过滤可关闭、手工配置或由模型生成条件。过滤 SQL 只选已完成、启用、未归档文档，再将命中文档 ID 传给后续检索；自动模式调用租户模型从允许的元数据字段生成 JSON 条件，失败会记录警告并返回无自动条件（`api/core/rag/retrieval/dataset_retrieval.py:1527-1616`、`api/core/rag/retrieval/dataset_retrieval.py:1694-1779`）。这是一条额外 LLM 调用和费用路径，而不是查询重写链。

**源码直接确认。** 单库模式先把每个可用 Dataset 描述为无参数工具：支持 tool call 的模型走 function-call router，否则走 ReAct router。路由结果仍会与“已允许 Dataset 列表”和 tenant 再次交叉验证，然后才取候选；该策略可能发生一次 LLM 路由调用并累积其用量（`api/core/rag/retrieval/dataset_retrieval.py:649-790`）。多库模式并发对每个库检索；若库的索引技术或 Embedding 不兼容，某些未使用 rerank 的组合会抛错（`api/core/rag/retrieval/dataset_retrieval.py:791-946`）。

### 召回、融合与排序

**源码直接确认。** 经济型库强制关键词检索。高质量库由配置选择语义、全文或混合检索；语义检索调用向量库，以 Dataset ID 作为 `group_id` 过滤，全文检索对转义后的查询执行，混合检索并行聚合关键词/全文/向量候选并按 `(provider, doc_id)` 或内容去重。文本查询与每个附件检索可并发执行（`api/core/rag/datasource/retrieval_service.py:97-220`、`api/core/rag/datasource/retrieval_service.py:271-467`、`api/core/rag/datasource/retrieval_service.py:792-928`）。

**源码直接确认。** 重排有两种配置：租户的 rerank 模型，或向量权重与关键词权重的加权评分。混合检索在融合后执行后处理；多库模式在每库检索后，若开启 rerank 且超过一个库，再执行一次跨库后处理。无重排时，经济型结果按本地计算的关键词 TF-IDF 余弦分数排序，高质量结果按分数阈值和分数排序，再截取 `top_k`（`api/core/rag/data_post_processor/data_post_processor.py:38-133`；`api/core/rag/retrieval/dataset_retrieval.py:1431-1510`）。重排或融合分数与原始向量分数不一定同量纲，混合检索因此延后阈值过滤（`api/core/rag/datasource/retrieval_service.py:204-220`）。

**静态推断。** 该实现是候选并发、去重、重排和排序的单轮检索架构。单库路由和自动元数据过滤会额外调用 LLM，但输出分别是 Dataset 选择和 SQL 过滤条件，并未在当前代码中构成“检索结果反馈到下一轮查询”的闭环。

## 结果契约、注入与工作流阶段

### 结果与引用契约

**源码直接确认。** Knowledge Retrieval 节点最终输出键为 `result`，类型为对象数组。每项为 `Source`：正文、标题、可选文件/摘要，以及 `_source=knowledge`、Dataset/Document/Segment ID 与名称、来源类型、分数、来源位置、文档元数据；父子分段还携带子块 ID、内容、位置与分数（`api/core/workflow/nodes/knowledge_retrieval/retrieval.py:13-85`；`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-184`）。节点还将路由或自动元数据过滤所消耗的 LLM token、价格、货币写入 process data 和 execution metadata。

**源码直接确认。** 本地检索命中会回查 DocumentSegment/Document/Dataset，只保留启用且完成的分段；内容可带问答形式的 `answer` 或摘要，最终按 score 降序并赋位置。检索结束的异步副作用会递增命中分段的 `hit_count`，并将文档、耗时交给应用 trace manager；查询审计则以独立事务写 `dataset_queries`，含文本/图片查询、Dataset、应用、操作者角色和时间（`api/core/rag/datasource/retrieval_service.py:472-791`；`api/core/rag/retrieval/dataset_retrieval.py:947-1090`、`api/core/rag/retrieval/dataset_retrieval.py:1107-1160`）。

**源码直接确认。** Chat 与 Completion 应用在生成模型调用之前调用检索；`retrieve` 将按分数排序的片段内容以换行连接为 context，同时可返回关联图片文件。若启用展示来源，回调会携带来源资源；之后 runner 调用 prompt 组织函数并传入 context 与 context files（`api/core/rag/retrieval/dataset_retrieval.py:406-648`；`api/core/app/apps/chat/app_runner.py:173-196`）。因此来源对象可用于展示/追踪，而普通应用主注入物是拼接后的文本，不是自动保留结构化 `Source` 的模型协议。

### 工作流和 Pipeline

**源码直接确认。** Knowledge Retrieval 节点从变量池读取字符串 query 和可选文件数组；类型不符即节点失败。它可使用单库或多库配置、手工/自动元数据过滤、rerank 或加权配置，并将结构化结果交给后续图节点。没有选择 query/附件时节点成功返回空输出（`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-350`）。是否把 `result` 格式化到 LLM prompt、以它计算下一 query，或在错误时改走另一支，属于用户绘制的 Workflow 连接和节点设置，不能由该节点单独保证。

**源码直接确认。** RAG Pipeline 的 `Pipeline` 记录 tenant、关联 workflow、公开/发布标志，并能在相同 tenant 下反查 Dataset；Pipeline 工作流保存草稿或按发布时间新建发布快照。发布时会扫描 `knowledge-index` 节点并更新关联 Dataset 的索引设置（`api/models/dataset.py:1081-1129`；`api/services/rag_pipeline/rag_pipeline.py:269-307`、`api/services/rag_pipeline/rag_pipeline.py:366-519`）。单节点试跑会保存节点执行、输入、过程数据、输出和草稿变量；文档来源执行还可留下 `DocumentPipelineExecutionLog`（`api/services/rag_pipeline/rag_pipeline.py:581-667`；`api/models/dataset.py:1108-1129`）。

**源码直接确认。** 已发布 Pipeline 的异步任务从文件读取序列化调用实体，在一个最多十线程的池中逐项运行；每个执行重新加载 account、tenant、pipeline、workflow，创建带 tenant、app 和触发来源的 workflow/节点执行仓库，随后用 `PipelineGenerator` 运行。任务 finally 部分继续租户队列、删除暂存调用文件并关闭会话（`api/tasks/rag_pipeline/rag_pipeline_run_task.py:46-126`、`api/tasks/rag_pipeline/rag_pipeline_run_task.py:127-207`）。

## 预算、缓存、可观测与恢复

| 主题 | 源码直接确认的机制 | 已知边界或未验证项 |
| --- | --- | --- |
| 摄取额度 | 索引任务检查订阅批量上传限制与向量空间额度；索引适配器还可在真正建索引前准入检查。 | 实际计划、额度计量和并发竞争未运行验证。 |
| 候选预算 | 每次检索有 `top_k` 与可选 score threshold；自定义分段受最大 token 配置约束。 | 未确认所有前端/API 层对 `top_k` 的最大值校验，也未测量超大候选的内存与延迟。 |
| 并发/超时 | 索引向量阶段最多十线程；检索由 `RETRIEVAL_SERVICE_EXECUTORS` 控制线程池；多库检索以短周期 `join` 轮询检测取消与失败。 | Python 线程取消无法证明已中止底层模型/向量请求。 |
| 租户限流 | 工作流检索入口按 Redis 有序集计算最近 60 秒次数，超额写 `rate_limit_logs` 后失败。 | 该检查位于 `knowledge_retrieval`，本次未确认所有应用/工具入口是否共享同一限流面。 |
| 缓存/锁 | Redis 用于暂停、重试、网站同步和租户任务队列；Embedding 表按模型、哈希、提供方唯一，可作为持久化复用索引。 | 本次未发现面向“查询 + Dataset 配置”的检索结果缓存；未在 Redis 丢失或过期时运行验证。 |
| 观测 | OpenTelemetry trace span 覆盖检索与检索服务；应用 trace manager 接收检索文档和耗时；查询审计、命中计数、文档错误/时延、节点/工作流执行均可持久化。 | 追踪后端、采样、控制台展示和敏感内容脱敏策略未验证。 |
| 恢复 | 暂停/恢复、重试、分阶段恢复和删除后清理均有任务入口；Pipeline 执行使用暂存文件，finally 删除。 | 服务崩溃发生在数据库提交、向量写入和暂存文件删除之间时的精确恢复语义未运行验证。 |

关于安全，数据模型对 Dataset、Document、Segment、元数据绑定、附件绑定、外部知识绑定和 Pipeline 均保存 tenant ID；Dataset 权限表按 Dataset、账户和 tenant 建索引（`api/models/dataset.py:823-847`、`api/models/dataset.py:967-1018`、`api/models/dataset.py:1154-1179`、`api/models/dataset.py:1081-1129`）。检索可用库查询也明确按 tenant 过滤。**静态推断：** 这些字段与入口过滤按 tenant 划定工作区隔离。**未运行验证：** 未以不同角色、仅本人/部分团队权限、服务 API、外部知识端点或签名文件 URL 进行越权测试；端到端授权效果，以及检索文本对不可信文档中提示注入的抵御能力，均属运行验证范围。

**源码直接确认。** 知识库 Service API Key 可以绑定到指定 Dataset，也可以绑定 KnowledgeFS 空间。创建 Key 时控制台接收 `dataset_ids` 与 `knowledge_space_ids` 两组绑定；请求装饰器每次都按绑定行计算作用域，已绑定 Key 只能访问 URL 中明确携带且位于集合内的 Dataset，无 Dataset ID 的列表和创建类端点也会被拒绝。没有绑定行的 Key 仍保留租户内全库访问语义，以兼容既有 Key；只绑定 KnowledgeFS 空间的 Key 没有可达的旧 Dataset，会被拒绝（`api/controllers/console/datasets/datasets.py:271`、`api/controllers/console/datasets/datasets.py:785-800`；`api/controllers/service_api/wraps.py:332-400`）。

资源访问令牌（resource access token）有独立的显式资源绑定，集合接口可列出其仍存在且已启用的知识库；这与绑定 API Key 遇到无 Dataset ID 接口就拒绝的行为不同。装饰器先解析令牌中的知识资源，列表控制器再把授权集合交给 Dataset 查询过滤（[查询作用域](../../dify/api/services/knowledge/dataset_service.py#L148-L172)）。资源详情请求还叠加租户和启用 API 检查。授权成功会记录使用时间，删除入口虽携带 relation ID，却会撤销整个令牌和全部关联；不能按“只解除一个资源”理解（[令牌授权](../../dify/api/services/resource_access_token_service.py#L120-L147)、[列表交接](../../dify/api/controllers/service_api/dataset/dataset.py#L437-L463)、[撤销事务](../../dify/api/repositories/resource_access_token_repository.py#L152-L165)）。权限效果仍未进行多角色运行验证。

## KnowledgeFS：并行的第二套知识面

**源码直接确认。** 快照新增 `knowledge_fs` 子系统：控制台、Service API、OpenAPI、内部 API 各有独立路由，服务层包含控制空间生命周期、来源导入、暂存上传、文本存储与向量存储适配、成员变更、撤销与后台任务（`api/services/knowledge_fs/`、`api/controllers/console/knowledge_fs/`、`api/controllers/service_api/knowledge_fs/`）。文本层有 TiDB 原生与检索服务两种实现，向量层有 Elasticsearch 与 Weaviate 适配；这些选择属于该子系统的内部实现细节，本次未运行验证。

**源码直接确认。** 可用性始终要求开启 `KNOWLEDGE_FS_ENABLED`，同时满足 Cloud/Enterprise 部署或社区开发开关二者之一；社区开发开关本身不能绕过总开关。上传还要求服务地址、Capability v2 开关与签名密钥；Agent 侧再要求 Agent Shell 开关（[可用性判断](../../dify/api/services/knowledge_fs/feature_service.py#L17-L37)）。默认自托管社区部署不进入这条路径。

### 工作流检索 v2：配置、准入与输出

**源码直接确认。** 前端节点目录按 KnowledgeFS 可用性显示 `knowledge-retrieval-v2`，面板保存文本变量、图片变量、所选空间、召回与元数据过滤配置。配置契约允许一至十个空间，输出数默认十、范围一至一百，文本或图片至少绑定一类。工作流节点工厂单独注册该节点，与旧 Dataset 检索并存（[前端目录](../../dify/web/app/components/workflow/node-catalog.ts#L79-L82)、[配置面板](../../dify/web/app/components/workflow/nodes/knowledge-retrieval-v2/panel.tsx#L28-L148)、[节点契约](../../dify/api/services/knowledge_fs/knowledge_retrieval_v2/entities.py#L33-L76)）。

运行时从变量池解析 query，文本最多一万六千字符；图片引用由文件访问 owner 检查后签发短期 grant，节点还限制数量、总大小及重复文件。仅账户发起的 debugger 调用会尝试建立草稿空间绑定；公开/Explore 调用依赖已有应用绑定。之后按当前 tenant、app 和 Workflow 调用者身份向各空间请求检索，关闭 Workflow 渠道、空间不可用或绑定未授权都会转成节点错误；默认并发四路，可注入值限定为一至十路（[执行与输入](../../dify/api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py#L206-L427)）。

各空间返回的候选先交错收集，候选池上限为 `min(100, 4 × top_n)`。有文本时调用租户的显式或默认 rerank 模型；缺失模型或调用失败会使节点失败，不会自动降级为原分数。纯图片查询跳过文本 rerank，直接合并空间分数。随后执行阈值过滤、稳定排序和截取，输出内容、引用、文档版本与空间分数，并补充兼容旧聊天引用的元数据；过程与输出中还携带 metrics（[候选与重排](../../dify/api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py#L637-L787)、[引用契约](../../dify/api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py#L852-L904)）。这条节点主链已在 Dify 侧静态确认，外部空间实际召回仍未运行。

只有所有选中空间都原始返回空候选、文本 query 非空且配置了捕获分派器时，才逐空间尽力投递失败检索质量记录；捕获失败只记录日志，不改变空结果的成功状态。仅因重排阈值过滤为空、或纯图片无命中时不会走该分派，故它是有条件的质量观察面，未形成自动改写查询或知识写回循环（[空结果捕获](../../dify/api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py#L232-L237)、[分派边界](../../dify/api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py#L814-L850)）。

**源码直接确认。** 与外部知识服务之间是显式契约边界：仓库内的 `api/knowledge-fs-contract/` 固定了 OpenAPI、能力操作清单、能力 v2 认证 profile 与源提交哈希，CI 只校验契约而不克隆实现仓库（`api/knowledge-fs-contract/README.md`、`api/knowledge-fs-contract.lock.json`）。这说明 KnowledgeFS 的存储与运行由独立服务承担，Dify 侧持有的是调用协议与授权凭据。

**未验证。** 未运行 KnowledgeFS 服务、控制空间创建、导入、文本/向量检索、成员权限、撤销和后台任务；其召回质量、容量、一致性与多租户隔离效果均无运行证据。它与既有 Dataset 的功能重叠、迁移关系以及是否会在未来取代旧知识库，代码中未给出结论。

## 与相邻谱系的可比/不可比边界

Dify 可以与 Open WebUI、AIO Hub 等知识资产管线比较资料来源、长期文档资产、异步索引、检索设置、引用、租户边界、发布和运行记录。它把这些对象持久化，并提供应用、Workflow 与摄取 Pipeline 三个消费/编排面；KnowledgeFS 又增加了一个外部托管的并行知识面。

它不应按同一算法维度与 VCPToolBox 的 TagMemo、思维簇或元思考机制比较。Dify 的可配置图允许用户显式构造多阶段查询，但当前静态主链的默认输出是当前 query 的候选文本/来源，不是下一阶段的认知方向；是否形成循环取决于用户图，而非该知识检索组件的固定协议。

## 未验证事项

- 未运行文件、Notion、网站抓取、外部知识 API、解析器、Embedding、关键词、全文、向量库、reranker、摘要索引或多模态附件，故未验证实际召回、分数含义、引用完整性、吞吐、超时和费用。
- 未部署 Redis/Celery，故未验证租户队列的 FIFO、公平性、TTL 过期、任务重投递、线程取消和暂停/恢复在竞争下的实际表现。
- 未进行多租户、多角色、公开 Pipeline、服务 API、资源访问令牌或文件签名 URL 的访问测试；本文的安全结论仅限静态过滤和字段传播。
- 未运行单 Dataset API Key 的创建、改绑、删除和越权请求，也未运行 KnowledgeFS 空间绑定的鉴权；兼容的未绑定 Key 仍拥有租户内全库访问范围。
- 未构造含恶意指令的知识文档，也未审查 prompt 组织模板，因此不能评价检索上下文的提示注入隔离。
- 未运行 KnowledgeFS 的部署开关、签名能力、控制空间、导入与检索 v2 节点；其服务端实现不在本仓库。
- 未审查所有 Workflow 节点、插件和 Agent 工具调用路径；“未发现自动递进查询/记忆演化”仅覆盖本笔记列出的知识检索、应用 runner 和 Pipeline 主入口。

## 关键源码索引

- 数据资产、权限、审计、Pipeline 与执行日志：`api/models/dataset.py:150-301`、`api/models/dataset.py:302-372`、`api/models/dataset.py:374-553`、`api/models/dataset.py:554-647`、`api/models/dataset.py:823-847`、`api/models/dataset.py:1081-1129`
- 摄取执行与状态机：`api/services/knowledge/indexing/execution.py:77-160`、`api/services/knowledge/indexing/adapters/execution.py:49-254`、`api/tasks/document_indexing_task.py:51-272`
- 暂停、重试、删除、恢复：`api/services/knowledge/dataset_service.py:1967-2154`、`api/services/knowledge/documents/application.py:192-260`、`api/tasks/recover_document_indexing_task.py:17-50`
- 租户任务队列：`api/services/document_indexing_proxy/batch_indexing_base.py:14-78`
- 候选生成、融合与来源格式化：`api/core/rag/datasource/retrieval_service.py:93-220`、`api/core/rag/datasource/retrieval_service.py:271-467`、`api/core/rag/datasource/retrieval_service.py:472-928`
- 多库/单库策略、审计、租户过滤与限流：`api/core/rag/retrieval/dataset_retrieval.py:156-405`、`api/core/rag/retrieval/dataset_retrieval.py:649-946`、`api/core/rag/retrieval/dataset_retrieval.py:1527-1779`、`api/core/rag/retrieval/dataset_retrieval.py:2098-2151`
- Workflow 结果契约与节点：`api/core/workflow/nodes/knowledge_retrieval/retrieval.py:13-92`、`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-350`
- 普通应用注入：`api/core/app/apps/chat/app_runner.py:173-196`
- RAG Pipeline 草稿、发布、试跑与异步执行：`api/services/rag_pipeline/rag_pipeline.py:269-519`、`api/services/rag_pipeline/rag_pipeline.py:581-667`、`api/tasks/rag_pipeline/rag_pipeline_run_task.py:46-207`
- 知识库 API Key 与资源访问令牌作用域：`api/controllers/console/datasets/datasets.py:785-800`、`api/controllers/service_api/wraps.py:332-400`
- KnowledgeFS 开关、检索 v2 节点与契约：`api/services/knowledge_fs/feature_service.py:1-37`、`api/services/knowledge_fs/knowledge_retrieval_v2/knowledge_retrieval_v2_node.py:166-203`、`api/core/workflow/node_factory.py:83-138`、`api/knowledge-fs-contract/README.md`
