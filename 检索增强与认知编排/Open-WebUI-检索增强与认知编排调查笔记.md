# Open WebUI 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`d3e8bf3405e848cfba377814d0aa7ba7290e414d`（分支：`main`）
>
> 调查方式：直接静态阅读当前后端源码、配置与数据模型；确认仓库分支和提交，未启动服务、Embedding、向量库、外部重排器或外部知识连接
>
> 调查范围：知识库/文件的摄取与检索、legacy 与 native function-calling 入口、候选融合/重排/引用/注入、Persistent Memory 的独立生命周期、访问控制、预算、日志和恢复；不重复通用模型渠道与工具审批机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **谱系定位：知识资产管线、相似度召回与工具化检索；证据状态：主链确认；证据类别：源码事实。** Open WebUI 的长期资料主体是知识库、其目录和文件关联，以及文件抽取文本与向量集合；聊天附件、笔记、聊天记录、URL 和网页结果也可作为一次请求的资料项。它提供发送前自动注入的 legacy RAG，以及由模型在原生函数调用中主动选择资料的工具链，但没有在本次检查范围发现固定思维模块、关系图传播或由检索结果确定下一检索阶段的内建认知编排。
- **查询形态：主链确认；证据类别：源码事实。** 普通路径按资料项解析为全文或集合，向量检索可升级为 BM25 与向量候选的混合检索，随后重排、阈值过滤、跨集合去重排序；native 路径还可先发现知识库和文件，再语义查询片段，或用受限的文件系统式工具逐段读取、检索。多轮工具调用是模型驱动的工具循环，不是检索管线自身的固定多阶段规划。
- **引用与注入：主链确认；证据类别：源码事实。** legacy 结果保留文档、元数据和分数，统一改写为带递增来源编号的 `<source>` 上下文并套入 RAG 模板。native 工具的片段按文件归组为引用事件；内容已存在于工具结果时，后续请求只补来源标记，避免重复灌入正文。
- **Persistent Memory：主链确认；证据类别：源码事实。** 它与知识库分表、分集合、分权限：每个用户使用 `user-memory-<user_id>` 向量集合，保存用户事实或一般上下文，可手工、经工具或可选的后台复盘写回。每轮即时注入会将用户事实、路径邻域和语义命中分段写入系统消息；这不是知识库文档索引，也不共享其访问授权。
- **运行结论边界：未运行验证。** 当前只确认静态路径和默认配置，未测量切块质量、各向量后端的混合检索语义、重排分数校准、外部知识连接的延迟/可用性、引用展示、并发负载、取消，以及模型是否实际选择正确工具。

## 谱系定位与系统边界

**源码事实。** 知识库记录名称、描述、所有者、元数据和访问授权；文件以独立记录保存原始路径、抽取内容、哈希和元数据，通过关联表归入知识库，也可置于知识库目录树。文件的抽取文本仍落在主数据库，向量集合保存其切块、向量和包含 `file_id`、来源名、哈希、Embedding 配置等的元数据；删除知识库会清理本地集合和知识库元数据，文件是否同时保留取决于配置。`backend/open_webui/models/knowledge.py:48-115`，`backend/open_webui/models/files.py:18-48`，`backend/open_webui/routers/knowledge.py:1593-1768`。

资料项并非只限知识库。检索汇总器可处理临时文本、文件、知识库、笔记、聊天、URL、网页结果和有权限的项目文件夹；全文模式直接取抽取文本，切块模式才进入向量集合。外部知识库不是本机再摄取的文件集合，而是以知识库元数据连接 Qdrant、Milvus 或 pgvector，查询时生成向量并把外部返回归一为同一文档/元数据/分数契约。`backend/open_webui/retrieval/utils.py:1334-1682`，`backend/open_webui/retrieval/external.py:89-379`。

**静态推断。** 此处的“认知编排”主要体现为模型可多次挑选工具、文件和查询，而不是服务端维护的检索状态机：混合检索的输出仍是当前请求的片段列表；工具循环只是把模型上轮工具调用结果回送给模型。检索结果不带阶段号、路径评分或下一阶段查询计划。本次以 `backend/open_webui/retrieval/`、`tools/builtin.py`、`tools/knowledge_fs.py` 和中间件工具循环为搜索范围，未找到这些对象。

## 摄取、切块与索引

**源码事实。** 文件处理先从存储路径经配置的 loader 抽取文档，或采用已有文本；抽取文本写入文件记录，计算 SHA-256，并更新 `pending`、`processing`、`completed` 或 `failed` 状态。向量化失败会清除文件哈希、写入错误并发布失败事件；把已处理文件加入知识库时优先复用该文件集合中的切块，集合丢失但数据库仍有抽取文本时则用文本修复重建。`backend/open_webui/routers/retrieval.py:1857-2123`，`backend/open_webui/models/files.py:407-443`。

保存前可先按 Markdown 标题切分并按最小目标长度合并，再按字符、tiktoken 或 Transformers 长度函数切块。默认块大小为 1000、重叠为 100；每个块保存摄取时的 Embedding 引擎和模型信息。Embedding 支持本地 sentence-transformers、OpenAI、Ollama 或 Azure OpenAI 等配置来源，可启用异步批次和并发请求；阻塞的保存过程被移到线程池，但 Embedding 调用本身可设超时。`backend/open_webui/routers/retrieval.py:1650-1819`，`backend/open_webui/config.py:958-1061`，`backend/open_webui/env.py:721-729`。

知识库文件的加入需同时有知识库写权限和文件读权限；更新会先按文件 ID 删除旧块再重新处理，移除会删除关联和按文件 ID、哈希清理块。因而“文件记录存在”“已归入知识库”“集合内有对应块”是可恢复但不同步的三层状态，源码专门处理了文件集合丢失的修复情形。`backend/open_webui/routers/knowledge.py:1407-1673`。

**未运行验证。** 未对任一 loader、OCR、媒体抽取、分块器、增量同步或具体向量后端执行上传和重建；不能据静态路径判断文档格式覆盖率、吞吐量或故障后数据一致性。

## 查询、候选与重排主链

### Legacy 自动注入

**源码事实。** 当模型知识已绑定且请求声明 legacy function calling 时，中间件将模型知识追加为文件资料项，并在请求发送前由文件处理器召回。资料汇总器先对每一项做所有权、文件授权、知识库授权、文件夹授权或外部库检查；全上下文/绕过检索时直接返回文件全文，否则针对可访问集合查询。多个查询和多个集合并行执行，之后以内容哈希去重，保留较高分并按分数截取 top-k。`backend/open_webui/utils/middleware.py:2575-2615`，`backend/open_webui/retrieval/utils.py:1469-1682`，`backend/open_webui/retrieval/utils.py:697-779`。

混合模式打开时，后端优先调用向量后端原生 hybrid search；不可用或失败时，取集合全部文本构建 BM25，再以加权集成融合 BM25 与向量候选，内容哈希作为去重键。随后由 CrossEncoder、ColBERT 或外部 reranker 打分；未配置 reranker 时重新计算余弦相似度。结果按重排分数阈值过滤、取 reranker top-n，再在需要时收缩到请求 k；整个混合分支失败会退回纯向量检索。`backend/open_webui/retrieval/utils.py:422-613`，`backend/open_webui/retrieval/utils.py:697-879`，`backend/open_webui/retrieval/utils.py:1731-1802`。

### Native 工具检索

**源码事实。** 原生 function calling 不在发送前强制把模型绑定知识全文写成 RAG 上下文，而是在系统消息附上已绑定资料清单，并注入内置工具。模型可列出或按名称/描述搜索有权限的知识库、按文件名搜索、对知识库执行语义片段查询、读取单文件，或在开启相应能力时使用 `kb_exec` 的 `ls`、`cat`、`grep`、`find` 等受限命令；若模型有绑定知识，文件工具还会把范围限制到绑定的知识库和文件。`backend/open_webui/utils/middleware.py:2976-3038`，`backend/open_webui/tools/builtin.py:2026-2306`，`backend/open_webui/tools/knowledge_fs.py:319-530`。

语义工具把本地集合与外部库的结果规范为内容、来源、文件 ID、可选距离和外部知识库 ID，并在汇总后按调用者 `count` 截断。知识库发现工具对“当前用户可读”的知识库元数据集合做向量搜索，并按访问列表过滤；它是资料库选择的辅助入口，不会自动再触发后续查询。`backend/open_webui/tools/builtin.py:3260-3449`。

## 结果契约、引用与工具循环

**源码事实。** legacy 汇总结果的每个来源包含原资料项、文档数组、元数据数组和可选距离数组。中间件按元数据中的来源名分配递增 ID，生成 `<source id>`，再用配置模板包装上下文和用户问题，写入 system 或 user 消息；默认模板明确要求只有存在来源 ID 时才输出方括号引用。`backend/open_webui/retrieval/utils.py:1666-1682`，`backend/open_webui/utils/middleware.py:940-1001`，`backend/open_webui/config.py:1063-1089`。

native 工具结果首先作为 tool message 回送模型。对知识库语义查询、文件查看、网页搜索等，系统从结果解析来源：查询片段按文件归组，保留文件 ID、名称、类型和文本，并向前端发出 source 事件。下一轮模型请求恢复发送前的系统/用户消息，再叠加已有资料正文和工具来源的空正文标记，防止同一 RAG 模板与工具文本反复复制。`backend/open_webui/utils/middleware.py:388-556`，`backend/open_webui/utils/middleware.py:5718-5863`。

工具调用每轮解析参数、删除未声明参数、执行工具并将错误变为工具结果；普通工具在该轮顺序执行，任务委派工具可并行。默认每次聊天最多 256 个工具调用迭代，设为 -1 才无限制；到达上限时向会话发送错误。工具调用请求暂停或续跑属于通用 Agent 执行控制，本笔记只记录其限制检索工具循环的效果。`backend/open_webui/utils/middleware.py:5502-5989`，`backend/open_webui/env.py:1060-1077`。

## Persistent Memory 的独立边界与写回

**源码事实。** Memory 表保存用户 ID、两种类型（`user` 或 `context`）、可选层级路径、文本、元数据和时间；每个用户使用独立 `user-memory-<user_id>` 向量集合。新增、替换、移动和删除会同步 upsert 或删除向量；若检测到向量维度不匹配，会删集合并以数据库中该用户的全部记忆重建。`backend/open_webui/models/memories.py:15-42`，`backend/open_webui/routers/memories.py:128-180`，`backend/open_webui/routers/memories.py:183-318`。

即时记忆注入最多拼接最近七条用户消息，并截到末尾 4000 字符后取语义 top-8；它另外无条件列入全部 `user` 类型事实，并根据消息中的路径提示加入至多四条相关 `context` 邻域。三部分经 ID 去重、排序后分别受用户事实和上下文的字符上限控制，以 `<memory_context>` 追加到系统消息。它和文档 RAG 一样最终进入上下文，但事实对象、查询集合、选择规则和权限边界独立。`backend/open_webui/utils/memory.py:289-406`。

写回有三条路径：用户 API 手工新增/编辑；模型可调用的记忆工具批量 add、replace、move、remove；以及默认关闭的后台复盘。后台复盘在启用且用户回合数达到配置间隔时异步调用当前模型，向其给出至多 80 条既有记忆和近 16 条对话，解析 JSON 操作后直接执行；静态实现没有用户或管理员审批队列。提示词要求不记录密钥、凭据、短期活动和无依据猜测，但这是模型提示约束，非独立的内容审查器。`backend/open_webui/utils/memory.py:409-602`，`backend/open_webui/routers/memories.py:234-318`。

## 作用域、预算、可观测与恢复

### 作用域与安全

**源码事实。** 知识库读取与写入以所有者、管理员或 `AccessGrants` 的权限判定，并把用户组带入可访问知识库查询。legacy 切块检索在把客户端提供的集合名投入向量库前再次验证集合归属；未知集合默认拒绝，只有显式开启未作用域集合或总绕过开关才会放宽。native 知识工具同样在知识库/文件解析时检查绑定范围和读取授权。`backend/open_webui/models/knowledge.py:470-493`，`backend/open_webui/retrieval/utils.py:1320-1331`，`backend/open_webui/tools/knowledge_fs.py:319-424`。

记忆 API 首先要求全局记忆功能开启，再检查用户的 `features.memories` 权限；所有读写都按请求用户 ID 查询或更新，向量集合名也由该用户 ID 构成。即时注入虽然由客户端 feature 请求触发，但中间件再次检查同一权限。`backend/open_webui/routers/memories.py:35-65`，`backend/open_webui/routers/memories.py:331-387`，`backend/open_webui/utils/middleware.py:2655-2662`。

### 预算、缓存与观察

**源码事实。** RAG 默认 top-k 和 reranker top-n 都为 3，重排阈值、BM25 权重、全文模式、文件数量/体积、切块大小/重叠、Embedding 批次/并发、Embedding 超时和外部 reranker 超时均可配置。外部知识库查询记录知识库、连接、提供者、用户、延迟和结果数；文件摄取和知识库/记忆变更发布审计事件；查询和重排还写入调试或信息日志。`backend/open_webui/config.py:958-1061`，`backend/open_webui/config.py:2909-2942`，`backend/open_webui/retrieval/external.py:323-379`。

文件系统式知识工具另有单次正则匹配 2 秒预算、最大扫描文件数 200、最大匹配行 50、单次输出 30000 字符；单文件查看默认和最大字符数也可配置。检索代码没有看到跨请求的查询结果缓存或缓存身份键；模型文件和 tokenizer 由本地缓存目录管理，但那不是 RAG 结果缓存。`backend/open_webui/tools/knowledge_fs.py:32-63`，`backend/open_webui/tools/knowledge_fs.py:805-858`，`backend/open_webui/env.py:1140-1159`。

**静态推断。** 日志、事件和返回的距离/来源提供了操作级观察面，但本次未找到离线检索质量夹具、A/B 框架或将候选、重排原因、降级路径完整持久化为可查询追踪的内建评估链路。

### 恢复与删除语义

**源码事实。** 摄取失败保留文件记录并标为 failed，成功后才标为 completed；知识库文件重加可用数据库文本恢复缺失块。记忆支持单用户或管理员全量向量重建，删除用户记忆会同时删其集合。管理员重置整个向量库时也删除全部知识库记录；这一路径是全局清除，不是从文件记录自动重建所有知识库。`backend/open_webui/routers/retrieval.py:2049-2119`，`backend/open_webui/routers/memories.py:448-539`，`backend/open_webui/routers/retrieval.py:3188-3202`。

Embedding 模型切换时，源码对记忆维度不匹配提供即时重建；对知识库块则记录摄取时模型配置、提供显式文件更新与知识库重置/重新处理入口。本次未运行验证向量后端重启、模型切换后的知识库召回是否会自动发现维度问题，也未验证异步摄取中断后的续跑语义。

## 与相邻谱系的可比/不可比边界

**源码事实。** 可与 Dify 等知识资产管线在切块、混合检索、重排、外部向量库、授权、引用和重建语义上比较；可与具有原生工具调用的应用比较模型主动发现资料、工具结果回注和迭代上限。Persistent Memory 可与用户级长期记忆比较事实模型、写回触发、审批与上下文预算。

**静态推断。** 不应把 native 的多轮函数调用等同于检索驱动认知编排。当前实现的循环所有者是模型与通用工具运行时，查询反馈是模型可选行为；服务端没有预定义的检索阶段、思维簇、关系传播或由上一阶段结果计算下一阶段方向，因此不与 VCPToolBox 一类以连续认知路径为核心的问题定义作同级比较。

## 未验证事项

- 外部 Qdrant、Milvus、pgvector 连接与本地各向量后端的实际距离方向、原生 hybrid 支持和失败回退。
- 文档加载、OCR、批量摄取、并发 Embedding、取消和服务重启时的真实状态转换与恢复耗时。
- 引用 source 事件在前端的显示、默认 RAG 模板在不同模型提供商上的遵循程度，以及模型实际的工具选择质量。
- 访问控制配置被显式绕过时的部署风险，以及外部知识连接自身的租户隔离和凭据保管，均需以实际部署配置验证。
- 后台记忆复盘的实际模型输出、错误率、写回内容和运行时成本；静态代码只能确认其自动直写路径。

## 关键源码索引

- `backend/open_webui/routers/retrieval.py:1650-2123`：切块、Embedding、向量写入、文件状态与失败记录。
- `backend/open_webui/retrieval/utils.py:422-879`：混合候选、重排、跨集合合并和纯向量回退。
- `backend/open_webui/retrieval/utils.py:1334-1682`：资料类型解析、授权、全文/切块选择和来源结果契约。
- `backend/open_webui/utils/middleware.py:2520-3105`：legacy 知识注入、原生内置工具和 RAG 上下文写入。
- `backend/open_webui/utils/middleware.py:5460-5989`：原生工具循环、引用提取、上下文回注和迭代上限。
- `backend/open_webui/tools/builtin.py:2026-2306`、`backend/open_webui/tools/knowledge_fs.py:319-530`：知识发现、文件检索与作用域检查。
- `backend/open_webui/routers/memories.py:128-539`、`backend/open_webui/utils/memory.py:289-602`：每用户记忆向量、上下文注入、后台复盘与重建。
- `backend/open_webui/models/knowledge.py:48-115`、`backend/open_webui/models/memories.py:15-42`：知识库与记忆的持久化对象边界。
