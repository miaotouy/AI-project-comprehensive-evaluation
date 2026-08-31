# AstrBot 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`8ea8ce613a0bee4ddb48b21490afe23418277c75`（分支：`master`）
>
> 调查方式：直接阅读知识库的 Dashboard/API 服务、摄取与存储、FAISS/FTS 检索、融合与重排、Agent 请求装配和相关单元测试；未启动 AstrBot、Embedding、Rerank、FAISS 服务实例或 Dashboard
>
> 调查范围：知识库文档、分块、索引、混合查询、结果契约、直接上下文注入与 agentic 工具检索，以及持久化、作用域、预算和恢复边界；不展开通用 Agent 工具循环、对话历史压缩、网页搜索和第三方 runner
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**源码直接确认。** AstrBot 的知识库属于“知识资产管线”，并有“相似度/关键词召回”“上下文即时注入”和“工具化检索”三个消费面。长期事实对象是本地知识库、文档、文档媒体和文本块：元数据集中保存在 `data/knowledge_base/kb.db`，每个知识库另有自己的块存储 SQLite 文件和 `index.faiss`。知识库记录其 Embedding/Rerank provider、分块参数、候选预算和统计；块保留知识库、源文档与块序号元数据（`astrbot/core/knowledge_base/models.py:11-120`、`kb_helper.py:137-194,384-444`）。

**源码直接确认。** 文件上传与预分块导入都先进入进程内后台任务。标准文件链为“暂存文件 -> 解析文本与媒体 -> 按文档类型分块 -> 批量 Embedding -> SQLite 块表/FTS5 与 FAISS ID 索引 -> 文档和媒体元数据 -> 统计刷新”；URL 路径使用 Tavily 提取正文，并可通过 LLM 清洗、翻译和重新分块。写入跨越文件、两个 SQLite 数据库和 FAISS，不能共享事务；提交文档元数据前失败会按块/向量、元数据、媒体的顺序尽力补偿，提交后统计刷新失败则保留已上传文档（`knowledge_base_service.py:134-235,537-622,853-939`、`kb_helper.py:211-502,504-572,721-895`）。

**源码直接确认。** 一次查询固定组合稠密和稀疏候选：各库以查询向量检索自己的 FAISS `IndexFlatL2`，同时由 SQLite FTS5 的 BM25 查询；FTS5 不可用或查询出错时退回内存 `rank_bm25`。候选按全局稠密归一化、每库稀疏归一化，以稠密 0.9、稀疏 0.1 的加权分数排序，RRF（平滑参数 60）只作同分稳定排序，按完全相同的块文本去重。若任一选中知识库存在可用 rerank provider，融合候选再用其中遇到的第一个 provider 重排；失败时保留融合顺序（`retrieval/manager.py:64-193`、`rank_fusion.py:26-205`、`sparse_retriever.py:56-182`）。

**源码直接确认。** 默认的非 agentic 模式在主 Agent 构建期以当前 `req.prompt` 查询，并将来源、内容和当前分数格式化成临时用户内容 part；它不持久化进会话历史。`kb_agentic_mode=true` 时则不预取，仅把 `astr_kb_search` 加入工具集，模型可在工具循环中以短关键词或简短问题自行发起同一检索。工具结果会返回给模型，但知识库组件本身没有根据命中生成下一查询、结构路径、固定多阶段循环或自动记忆写回的实现（`astrbot/core/astr_main_agent.py:289-320,1608-1616`、`knowledge_base_tools.py:40-142`）。

## 谱系定位与系统边界

| 谱系 | 当前代码快照中的结论 | 证据状态 |
| --- | --- | --- |
| 知识资产管线 | 知识库、文档、媒体、块、两类索引和统计是可管理的本地持久化资产。 | 源码直接确认 |
| 相似度/关键词召回 | 每库 FAISS 稠密召回与 FTS5 BM25 或内存 BM25 稀疏召回共同产生候选。 | 源码直接确认 |
| 上下文即时注入 | 默认模式在构建 ProviderRequest 后、工具装配前检索，并追加临时用户内容。 | 源码直接确认 |
| 工具化检索 | agentic 开关只注册内置检索工具；检索时机与继续轮数由模型/通用 Agent runner 决定。 | 源码直接确认 |
| 检索驱动认知编排 | 本次覆盖的固定主链未发现由命中、分数或向量改写下一阶段查询的协议。 | 静态推断 |
| 主动记忆演化 | 本次覆盖的知识库路径未发现从对话自动抽取、合并、审批或后台维护知识条目的链路。 | 静态推断 |

这里的“知识库”是服务实例内按 UUID 区分的集合，不是与 IM 用户、会话或 persona 一一对应的记忆库。会话可以覆盖全局选择的集合和最终返回数量；若没有会话覆盖，则使用配置中的名称列表。会话绑定、一般上下文装配和模型工具迭代的其余语义分别属于相邻类目。

## 事实对象、摄取与索引

### 对象、可维护性与来源

知识库元数据包含唯一 ID、名称、描述、图标、Embedding/Rerank provider ID、分块尺寸与重叠、稠密/稀疏候选数、最终数量、文档数和块数。文档具有独立 ID、所属库、文件名/类型/大小、块数和媒体数；媒体另存 ID、文件路径、MIME 类型和大小。块并不写入该元数据 SQLite，而是写入每库 `doc.db` 的 `documents` 表；其 JSON 元数据只有 `kb_id`、`kb_doc_id` 与 `chunk_index`。因此 Dashboard 能按库列文档、按文档列块、删除文档或单块，但当前结果不携带原始文件路径、段落标题或页面位置（`models.py:11-120`、`kb_helper.py:656-682`、`faiss_impl/document_storage.py:27-41`）。

Dashboard 的受 `kb` scope 保护 API 支持建库、改库、删除库、列文档/块、上传文件、导入预切块及 URL 导入。创建时会实际请求 Embedding，并校验返回维度；配置了 Rerank 时也会发送探测重排请求。删除整库先关闭并删除该库目录，再删元数据；删除文档先删除 SQLite 文档/媒体行，随后按 `kb_doc_id` 删除块与向量。文档与块可删除，但本次未找到面向已存在块的编辑和重新向量化接口（`dashboard/api/knowledge_bases.py:81-305`、`knowledge_base_service.py:347-405,738-795`、`kb_mgr.py:168-180`）。

### 摄取、分块与异步状态

文件 API 把上传体写入权限为 0700 的临时任务目录，立即返回 task ID，并以 `asyncio.create_task` 顺序处理任务内文件。进度仅保存在服务对象的 `upload_tasks`/`upload_progress` 字典，按 parsing、chunking、embedding 等阶段供轮询读取；服务重启后这些任务和进度不会恢复。预分块导入使用同一后台模式，却跳过解析与切分；URL 导入先由 Tavily 抓取正文，可选择指定 LLM 对初步分块逐块修复/翻译/丢弃，然后复用普通上传（`knowledge_base_service.py:24-111,134-235,625-704,853-939`）。

普通文件只接受 Markdown、文本、RST、AsciiDoc、Office 表格/文档、EPUB 和 PDF 这些后缀。结构化来源先被解析为 Markdown，再由 Markdown 分块器按标题层级保留父标题上下文；超长章节在章节内退回递归字符切分。其他内容按段落、换行、中英文标点、空格到单字符的优先顺序递归切分。创建知识库的默认参数为每块 512 字符、重叠 50 字符；上传接口可逐次覆盖它们，而不是强制使用库记录的分块值（`parsers/util.py:4-17`、`chunking/recursive.py:30-167`、`chunking/markdown.py:63-162`、`kb_mgr.py:108-119`、`knowledge_base_service.py:537-552`）。

每块写入时，保存的检索正文是块文本，送入 Embedding 的文本则在前面加源文件去后缀名称。批量调用 Embedding provider 后，代码先校验数量、二维形状和向量维度，再把块 SQLite 行写入并将相同内部整数 ID 写进 FAISS。每库 FAISS 索引是内存 `IndexFlatL2` 加 `IndexIDMap`，每次批量插入或删除即覆写 `index.faiss`；索引维度来自当前 provider 配置，加载已有索引时不会复核该文件与已改 provider 的维度是否一致。这也是文档要求库创建后不要更改 Embedding 模型或维度的实现背景（`faiss_impl/vec_db.py:59-213`、`embedding_storage.py:62-186`、`docs/zh/use/knowledge-base.md:34-41`）。

## 查询、候选与重排主链

```text
用户消息构造 ProviderRequest
  -> _decorate_llm_request 完成动态请求装配
  -> _apply_kb
     非 agentic：以 req.prompt 调 retrieve_knowledge_base
       -> 取会话 kb_config，或全局 kb_names
       -> KnowledgeBaseManager.retrieve
          -> 各库 FAISS 稠密 top_k_dense
          -> 各库 FTS5 BM25 top_k_sparse；不可用则内存 BM25
          -> 分数融合、RRF 同分排序、相同文本去重，截至 fusion top-k
          -> 回查文档/知识库元数据；可选 rerank
          -> 截至 final top-k，格式化来源/正文/分数
       -> [Related Knowledge Base Results] 临时 TextPart
     agentic：注册 astr_kb_search，模型在工具循环中按需重复上述检索
  -> 工具、Provider 和 runner 继续生成
```

### 查询入口与作用域选择

两种消费路径共享 `retrieve_knowledge_base`。先读取以统一消息来源 UMO 为键的会话偏好 `kb_config`：存在 `kb_ids` 时，空列表是显式禁用；非空时逐个把 ID 解析成当前已加载的库名称，失效 ID 仅记录警告。没有该偏好时，读取当前配置实例的 `kb_names`。没有指定库、所有库为空或未加载时不调用检索；初始化失败的库被从本次调用跳过，若请求的库全部不可用则抛错（`knowledge_base_tools.py:40-103`、`kb_mgr.py:282-340`）。

这一作用域是“当前 AstrBot 进程内的配置与会话选择”，不是文档级 ACL。API 路由要求 Dashboard 的 `kb` scope，但块和知识库模型没有 owner、tenant、用户或会话字段；检索函数只接受已解析的库集合。静态代码可确认 API 管理面和会话选库的门槛，不能据此断言多用户部署中的端到端资料隔离或检索内容安全。

### 候选、融合和 rerank

稠密路径逐库调用 FAISS，要求块元数据的 `kb_id` 与当前库相等，先取两倍 `top_k_dense` 再过滤，返回每库设定数量。FAISS 的 L2 距离被映射为 `1 - distance / 2`，随后把各库结果汇总。稀疏路径先对查询去停用词并分词；优先保证 FTS5 内容无索引缺口后以 OR 查询和 SQLite `bm25()` 取每库 `top_k_sparse`，FTS5 不可用或搜索失败时才把涉及库的所有块载入内存构建 BM25Okapi。两条路径都是按当前 query 的单轮候选生成，并无查询改写或扩展（`retrieval/manager.py:195-240`、`sparse_retriever.py:56-182`、`faiss_impl/document_storage.py:464-583`）。

融合阶段不是纯 RRF：稠密相似度在所有候选中 min-max 归一，BM25 分数在各知识库内部归一，再以 0.9/0.1 加权。RRF 只在融合分数相等时参与次级排序，之后保留至全局 `kb_fusion_top_k`，默认 20，并仅按块正文完全相同去重，不折叠同一文档的相邻块。融合块需能回查 `KBDocument` 与 `KnowledgeBase` 元数据才会成为最终结果。若多个库配置了不同 rerank provider，当前实现选择遍历到的第一个可用 provider 处理全部融合候选，而不会按来源库分别重排；调用异常时记录警告、直接使用融合结果。最后截断至会话 `top_k` 或全局 `kb_final_top_k`，默认 5（`rank_fusion.py:58-205`、`retrieval/manager.py:148-193`、`config/default.py:318-321`）。

## 阶段、反馈与结果注入

`KnowledgeBaseManager.retrieve` 返回两种同源表示：供注入的文本，以及包含块 ID、文档 ID、知识库 ID/名称、文档名、块序号、正文、最终分数、字符数的结果数组。文本将每块写成“知识序号、来源、内容、相关度”的中文段落。Dashboard 手动检索接口返回结构化数组，可选生成 t-SNE 可视化；普通 Agent 注入和工具调用只消费格式化文本，因此模型看不到独立的候选类型、密集/稀疏来源、融合分数或重排理由（`kb_mgr.py:320-361`、`knowledge_base_service.py:812-851`）。

非 agentic 模式只有在用户提示非空白时同步检索。`_apply_kb` 在请求装饰完成后追加 `[Related Knowledge Base Results]`，并标记这个 TextPart 为临时内容；单元测试确认它会参与当轮 assembled message，但不会写入检查点历史。该模式没有让模型决定是否检索的机会，也没有质量阈值或字符/token 预算，最终注入规模主要受块大小与最终块数控制，之后仍可能由通用上下文管理器裁剪（`astr_main_agent.py:289-320,1608-1616`、`tests/unit/test_astr_main_agent.py:453-553`）。

agentic 模式把同一个检索函数包装为 `astr_kb_search`。工具说明要求短关键词或简短问题，空 query 返回错误；无结果则返回固定文本。工具可在模型获得前一次结果后再次调用，所以存在由模型自由决定的工具循环，但组件未维护阶段状态、候选反馈、下一查询模板或退出条件。工具发现、调用次数、超时与输出裁剪由通用 Agent 工具系统负责，不属于本知识库实现可保证的多阶段编排（`knowledge_base_tools.py:106-142`）。

## 预算、可观测性与恢复

| 主题 | 源码直接确认的机制 | 已知边界或未验证项 |
| --- | --- | --- |
| 摄取输入 | 文档支持的后缀由 parser 分派；Dashboard 文档说明称单次最多 10 文件、单文件最多 128 MB。 | 服务层本次未见对文件数和字节数的同等强制校验；未运行验证网关或前端是否执行该限制。 |
| 分块与 Embedding | 默认块 512、重叠 50；批次默认 32、并发任务默认 3、重试默认 3，均可在上传请求覆盖。 | 未测量大文档、provider 限额、重试退避或并发实际效果。 |
| 查询预算 | 每库默认稠密/稀疏候选各 50；融合默认保留 20；最终默认 5。 | 未见最低分阈值、注入字符/token 上限或跨库公平配额。 |
| FTS 与降级 | 启动时建立/核对 FTS5；若不可用、重建或查询失败，退回将相关库所有块装入内存的 BM25。 | 大库降级时的内存、延迟和并发影响未测量。 |
| 观测 | 上传可轮询任务状态、文件序号和阶段进度；管理 API 可列资产、手动检索结果并可选生成 t-SNE 图；检索各阶段记录耗时 debug 日志。 | 无持久化的查询审计、候选列表、融合细节、rerank 原因或离线质量评测；Dashboard 实际展示未经运行验证。 |
| 恢复与备份 | 重启时从 kb.db 重建 helper 并打开各库索引；导出器包含 KB 元数据和每库文档数据。 | 进程内上传任务/进度不能恢复；跨 SQLite/FAISS/媒体写入只做尽力补偿，崩溃时最终一致性未实测。 |

文档上传测试覆盖 FAISS 写入失败后的块回滚、向量维度不符时不写块、元数据提交前后的不同补偿边界；文档存储测试覆盖 FTS5 可用性与回退选择。这些测试支持实现分支的存在，不代表真实 provider、文件解析器或多进程故障场景已经运行确认（`tests/unit/test_kb_upload_atomicity.py:132-277,280-652`、`tests/unit/test_document_storage_fts.py`）。

## 与相邻谱系的可比/不可比边界

AstrBot 可与 Dify、Open WebUI、Chatbox、AIO Knowledge 等知识资产管线比较本地资料摄取、分块、向量/关键词混合候选、重排、来源和恢复。其当前实现的特点是每库独立 SQLite/FAISS 文件与轻量 Dashboard 管理面，而非 Dataset/Pipeline 发布、租户 ACL 或异步任务队列体系。

它也可与模型工具化检索实现比较“模型能否在结果后再次查询”：agentic 模式确实返回工具结果给通用 Agent 循环。不过这不等同于检索驱动认知编排。当前固定链输出的终点始终是本轮候选文本；本次在知识库检索器、工具和请求装配入口中未找到用命中内容、分数或向量构造下一阶段查询的机制，也未找到关系图、思维簇、主动记忆维护或检索质量评测。该结论只限所列入口和搜索范围，不能排除插件或用户提示自行组织额外循环。

## 未验证事项

1. 未启动 Dashboard、Embedding/Rerank provider、FAISS 或真实文档解析器，未验证上传限制、实际分块质量、召回率、分数含义、重排效果、注入长度和 t-SNE 可视化。
2. 未在 FTS5 缺失、索引重建、超大资料库、多个库使用不同 Embedding 或 Rerank provider、网络故障和并发上传下测量降级、延迟、资源消耗与结果稳定性。
3. 未以多个 Dashboard 用户、配置实例、会话和 IM 身份进行访问测试；作用域结论仅限 `kb` API scope 与会话/全局选库代码，不能证明端到端授权隔离。
4. 未构造含恶意指令的文档；检索文本直接以用户内容 part 或工具结果交给模型，当前调查不评价提示注入防护。
5. 未模拟进程在块 SQLite、FAISS、元数据 SQLite 和媒体文件的不同提交点崩溃，亦未运行备份导入，因此补偿、重建和备份恢复的一致性只限静态路径与测试覆盖。
6. 未逐项审查所有插件、第三方 runner 或外部工具；“未发现认知编排与记忆写回”不构成全仓库绝对否定。

## 关键源码索引

- 资产模型、SQLite 元数据与统计：`astrbot/core/knowledge_base/models.py:11-120`、`kb_db_sqlite.py:22-81,175-369`
- 生命周期与每库文件布局：`astrbot/core/knowledge_base/kb_mgr.py:24-180,282-361`、`kb_helper.py:117-210,574-719`
- 上传、解析、分块、Embedding 与补偿：`astrbot/core/knowledge_base/kb_helper.py:211-572,721-895`、`chunking/recursive.py:30-167`、`chunking/markdown.py:63-162`、`parsers/util.py:4-17`
- FAISS、块 SQLite、FTS5 和回退：`astrbot/core/db/vec_db/faiss_impl/vec_db.py:59-349`、`embedding_storage.py:62-186`、`document_storage.py:59-168,464-583`
- 稠密/稀疏候选、融合与重排：`astrbot/core/knowledge_base/retrieval/manager.py:64-283`、`sparse_retriever.py:56-182`、`rank_fusion.py:26-205`
- 会话选库、工具和请求注入：`astrbot/core/tools/knowledge_base_tools.py:40-149`、`astrbot/core/astr_main_agent.py:289-320,1608-1616`、`astrbot/core/config/default.py:318-321`
- Dashboard API、后台摄取、资产查看与手动检索：`astrbot/dashboard/api/knowledge_bases.py:81-305`、`astrbot/dashboard/services/knowledge_base_service.py:134-235,347-405,537-704,812-939`
- 已读测试与备份入口：`tests/unit/test_astr_main_agent.py:453-553`、`tests/unit/test_kb_upload_atomicity.py:132-652`、`tests/unit/test_kb_document_cleanup.py:91-199`、`astrbot/core/backup/exporter.py:40-139`
