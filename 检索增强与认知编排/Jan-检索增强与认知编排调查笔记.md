# Jan 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`95e96d02c58ca361a3e54cb36360ed16bc534c8a`（分支：`main`）
>
> 调查方式：直接静态核对当前 Jan 的 RAG、Vector DB、Tauri 插件、线程附件与工具执行源码；未运行桌面应用、嵌入模型或检索质量评测
>
> 调查范围：附件/项目文件的摄取、索引、工具检索、结果回注及其审批、作用域、预算、缓存、观察与恢复；不重复 MCP、网页搜索及通用消息上下文的完整调查
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 同时具有“上下文即时注入”和“工具化检索”两条附件路径。普通线程文档可按设置直接解析为文本并随用户消息送入模型；选择嵌入时，文档被解析、分块、嵌入并保存到本地 SQLite collection，随后由模型在原生 tool-calling 循环中决定是否调用 `retrieve`。项目文件固定走嵌入路径，供该项目的线程共享。前者不是检索，后者才是本笔记的主要对象（`web-app/src/lib/attachmentProcessing.ts:184-309`）。

工具化路径是单次向量候选召回加模型可选的后续读块，而非项目自行实现的多阶段查询规划：模型可先列文件、按语义召回、再按文件序号读相邻块；每次工具结果会回注下一模型回合，因此模型能够自行发起多次调用，但源码没有查询改写、候选融合、reranker、结构传播或“上一轮结果自动生成下一检索式”的编排器。此结论是对工具定义和执行链的静态判断，实际调用次数与模型策略尚未运行验证。

检索对象与索引以线程或项目为 collection 边界。候选可带文本、文件 ID、块顺序与分数，UI 会把 `retrieve` 的 JSON 结果显示为可展开的引用卡片。ANN 可用时查询交给 sqlite-vec；否则线性遍历全部候选、以余弦相似度阈值过滤并排序。两条路径的 `score` 语义并不相同：ANN 输出的是 distance，线性路径输出 cosine similarity，UI 仅以同一数值格式展示，不能把两种数值横向比较（`src-tauri/plugins/tauri-plugin-vector-db/src/db.rs:447-635`）。

## 谱系定位与系统边界

本项目在本类目中横跨两个谱系：小文档内联属于上下文即时注入；嵌入后的 thread/project 附件属于工具化检索和本地相似度召回。RAG 扩展把三个工具标为内部 server `rag-internal`，但这不是独立 HTTP/RPC 服务端点：前端 RAG service 通过扩展管理器调用扩展，扩展再通过 Tauri API 调用本机 Vector DB 和文档解析插件（`core/src/browser/extensions/rag.ts:18-51`、`web-app/src/services/rag/default.ts:21-60`）。本次检查范围内未找到 RAG 对外网络端点或服务端租户层，不能据此推断不存在其他部署形态。

一条嵌入检索主链如下：

```text
用户添加文档 / 项目文件
  -> 解析模式决定 inline 或 embeddings（项目文件强制 embeddings）
  -> RAG extension 调用 Vector DB extension：解析、分块、嵌入、写入 collection
  -> 有文档 + 功能开启 + 模型支持 tools 时装配内部 RAG tools
  -> 模型输出 retrieve / list_attachments / get_chunks
  -> 线程页串行执行工具，结果作为 tool output 回注并自动续发模型
  -> retrieve JSON 被解析为引用卡片；模型同时得到原始 tool result
```

工具仅在所选模型声明 `tools` capability 时加入请求。线程元数据 `hasDocuments` 是快速标记；项目线程另会查询项目 collection 是否有文件。功能开关关闭、工具被全局禁用、RAG 扩展取工具失败或模型不支持工具时，不会把这些工具交给模型（`web-app/src/lib/custom-chat-transport.ts:851-924`）。这只说明装配条件；模型收到工具后是否调用仍由模型与 provider 运行时决定。

## 事实对象、摄取与索引

事实对象包括待发送附件、文件记录、文本块和 collection。附件记录在前端消息/线程流程中保存其处理状态、文件 ID、大小、块数与注入模式；向量库中每个文件有 UUID、原始路径、名称、类型、大小、块数，每个块有 UUID、文本、嵌入、所属文件和从零开始的文件内顺序（`core/src/browser/extensions/vector-db.ts:9-42`、`src-tauri/plugins/tauri-plugin-vector-db/src/db.rs:300-407`）。本次未发现从对话自动抽取用户事实、摘要记忆、标签图或关系图的写回链。

普通线程 collection 名由 Vector DB 扩展生成为 `attachments_<threadId>`，项目 collection 为 `project_<projectId>`。文件按同一 collection 内“名称和路径都相同”拒绝重复添加。上传服务一次向 RAG 扩展提交一个文档；RAG 扩展拒绝超过配置上限的文件，再调用对应 scope 的 `ingestFile`（`extensions/rag-extension/src/index.ts:365-488`、`web-app/src/services/uploads/default.ts:15-48`）。

摄取先由 RAG 插件将本地文件解析为纯文本，再按字符数切块，批量调用当前嵌入引擎，创建 collection 并插入文件和块。默认块长 512 字符、重叠 64 字符，默认最大文件 100 MB；设置允许把块长设为 64--8192、重叠设为 0--1024。扩展先按嵌入模型上下文窗口估算安全字符数，随后对仍超 token 预算的块递归二分；无法读取嵌入上下文或 token 数时摄取失败，而不是继续写入可能超限的块（`extensions/vector-db-extension/src/index.ts:154-237`、`extensions/rag-extension/settings.json:32-64`）。

附件模式有明确分流。设置可选 auto、inline、embeddings 或 prompt；auto 在能够解析且拿到模型上下文阈值/估算 token 后，可能把较小的线程文档置为 inline。解析失败时该分支回退为 embeddings。项目文件无论设置如何均强制 embeddings；inline 内容随消息转换进模型消息，不经过 Vector DB，因此不应将所有“附件已处理”都解释为已索引（`web-app/src/lib/attachmentProcessing.ts:196-299`）。

索引保存在 Tauri 插件管理的本地 collection SQLite 文件中。插件建表时尝试加载 sqlite-vec；不可用时仍保留普通 chunks 表并记录线性检索回退。插入会拒绝空或非有限嵌入；ANN 表因嵌入维度不匹配拒绝单块时只记录日志，普通块仍保留，之后线性检索仍可服务（`src-tauri/plugins/tauri-plugin-vector-db/src/db.rs:71-126,336-407`）。这是源码可确认的降级策略，未实际验证不同平台的 sqlite-vec 装载结果。

## 查询、候选与重排主链

三个工具共用内部 server 标识，schema 中只声明模型应填写的业务参数；线程/项目标识和 scope 由执行 service 注入，模型无需也不能从 schema 得知这些参数。`list_attachments` 列出当前 scope 的文件；`retrieve` 必填 query，可选 `top_k` 和 `file_ids`；`get_chunks` 必填 file ID 及闭区间的起止块序号。`top_k` 上限和默认值等于当前 retrieval limit，默认 3，最小钳制为 1（`extensions/rag-extension/src/tools.ts:8-78`）。

工具执行发生在 assistant 流完成后。线程页把同一轮工具调用串行处理，将内部 RAG 工具直接视为已允许；RAG service 补入当前 thread/project scope 后调用扩展。成功内容作为 AI SDK tool output 添加到完成的 assistant 消息，`sendAutomaticallyWhen` 触发后续模型请求。中止、拒绝或异常会把工具 part 标成 error；切换线程时会 abort 现有工具循环，并将待审批项按拒绝处理，避免悬挂循环（`web-app/src/routes/threads/$threadId.tsx:462-587,655-682`）。

`retrieve` 对 query 现算一个嵌入，按当前 scope 和可选 file ID 过滤检索 collection。它使用配置的 retrieval threshold（默认 0.3）与 search mode（auto、ann、linear），把返回块映射为 citations；没有关键词/BM25、混合检索、去重、rerank 或相邻块自动扩展。auto 在 ANN 可用时优先 ANN；linear 才执行阈值过滤并按余弦相似度降序截断。ANN 路径按 sqlite-vec distance 排序，且当前调用没有把 threshold 传入 ANN SQL，因此阈值不在该路径施加。这是直接由分支参数可见的源码事实（`extensions/rag-extension/src/index.ts:186-302`、`src-tauri/plugins/tauri-plugin-vector-db/src/db.rs:447-635`）。

`get_chunks` 是按文件和 order 范围读取原始块的补读能力，不是召回重排；工具描述也要求优先使用 `retrieve`。因此“先召回命中块，再由模型决定读相邻范围”是可行调用组合，但“模型会这样做”或其对答案质量的效果均未验证。项目 scope 的 tool service 把 project ID 同时注入 project_id 和 thread_id，以适配扩展读取的 effective ID（`web-app/src/services/rag/default.ts:37-53`、`extensions/rag-extension/src/index.ts:305-363`）。

## 阶段、反馈与结果注入

RAG 扩展返回的是 `MCPToolCallResult`：成功时 `content` 只有一项 text，其文本为 JSON；失败时同时提供 error 字符串和面向模型的错误文本。`retrieve` 成功 JSON 至少含查询、scope、thread/project ID、search mode 与 `citations`；每个 citation 含块 ID、文本、可选 score、file ID 与块序号。`list_attachments` 返回文件数组；`get_chunks` 返回原始块数组（`extensions/rag-extension/src/index.ts:129-363`）。这意味着模型消费的是完整命中文本和这些定位字段，不是只收到 UI 引用编号。

前端从 tool output 解析 citations，要求每项至少有 id、text、file_id；引用卡按 scope 再拉取文件名，显示块序号与两位小数分数，用户可展开文本。`retrieve` 在执行中显示查询和可选 top-k/文件过滤数量，空 citations 显示无匹配；`list_attachments` 和 `get_chunks` 使用通用工具卡。这是组件绑定可确认的展示和字段解析，实际视觉、无障碍和不同 provider 输出兼容性未运行验证（`web-app/src/lib/citation-parser.ts:46-109`、`web-app/src/containers/message/RagToolWidget.tsx:20-99`、`web-app/src/components/Citations.tsx:45-94`）。

模型可在收到 tool output 后选择再次调用工具，构成由模型控制的多回合工具循环；Jan 本身没有在 RAG 层保存阶段状态、限制阶段数或自动以结果改写 query。故可将其与其他工具化附件检索比较工具 schema、回注和候选契约，不能仅由“可多次调用”归入检索驱动认知编排。

## 作用域、审批、预算、缓存、观察与恢复

作用域由调用所在线程决定：非项目线程检索该 thread collection；项目线程的 RAG 调用固定为 project scope，检索项目 collection。模型参数中的 scope/thread ID 在 service 层会被覆盖或补入当前上下文，避免模型任意指定别的 collection；`file_ids` 只能进一步缩小当前 collection 内候选。这里没有看到多用户、ACL 或内容隔离策略，因而本地桌面单用户 scope 不能等同于服务端授权边界（`web-app/src/routes/threads/$threadId.tsx:520-531`、`web-app/src/services/rag/default.ts:37-53`）。

审批分两层理解。RAG 工具在实际执行分支中被认定为内置工具，始终自动允许；文档成功嵌入后，线程流程还把全部 RAG tool name 写入持久化的 thread 级 approval store。后一个写入对该执行分支并非必要条件，但会与通用审批状态保持一致。外部 MCP 的一次、线程、server、全局授权不应套用为 RAG 文件访问审批（`web-app/src/routes/threads/$threadId.tsx:491-531,1020-1029`、`web-app/src/hooks/useToolApproval.ts:6-89`）。检索内容作为工具结果直接交给模型；本次检查范围未找到对文档内不可信指令的隔离或检测层。

预算主要在摄取与候选层：文件大小、块长、重叠、embedding context、`top_k`、线性阈值及 ANN/linear 模式可配。没有找到 RAG 专用的总字符/token 截断、单次检索超时、最大工具回合数、并行候选预算或结果缓存。线程工具在 UI 执行器中串行并支持 AbortSignal；底层 Tauri 检索命令在本次静态范围内未见取消参数，取消能否中断已发出的 SQLite/embedding 操作尚未验证。

缓存与观察面是分离的。MCP 智能路由会冻结其路由工具集以稳定 prompt cache，但 RAG 工具在该路径之外，每次 refreshTools 直接装配，不应把 MCP 路由缓存解释为 RAG 查询缓存（`web-app/src/lib/custom-chat-transport.ts:766-770,901-924`）。RAG/Vector DB 主要观察面是控制台日志、工具运行状态、查询栏和引用卡；源码未见候选全量列表、ANN/linear 决策、阈值淘汰数、embedding 耗时或质量评测面板。仓库有工具与扩展的单元测试，但本次未执行，因而不构成运行确认。

文件删除会在前端先调用当前 scope 的 `deleteFile`，Rust 事务删除该文件的 chunks 与 files 行；项目文件删除走对应 project 方法（`web-app/src/containers/ChatInput.tsx:898-928`、`web-app/src/containers/ProjectFiles.tsx:546-568`、`src-tauri/plugins/tauri-plugin-vector-db/src/db.rs:410-415`）。索引 SQLite 文件可跨应用重启继续存在，这是由持久化路径和按命令重新打开 connection 的静态推断；没有读到重建、迁移、嵌入模型变更后重新嵌入或崩溃恢复流程。

有一处需单列的静态组合边界：线程删除清理函数向 Vector DB extension 传入已经带 `attachments_` 前缀的 ID，而该 extension 又会追加同一前缀，得到 `attachments_attachments_<threadId>`。按两处源码的字符串组合推断，这不会删除实际线程 collection；清理失败只记录警告且线程删除继续。本次未运行验证真实删除时的遗留文件与应用版本兼容性（`web-app/src/hooks/useThreads.ts:44-59`、`extensions/vector-db-extension/src/index.ts:25-27,60-62`）。

## 与相邻谱系的可比/不可比边界

与知识资产管线可比较的维度是本地文件摄取、块/文件删除、thread/project scope、索引回退和引用字段。Jan 没有在本次范围内呈现服务端知识库发布、租户授权、异步索引任务队列或可重建版本管理，不能以未读模块之外的可能实现补全这些能力。

与上下文即时注入可比较的是附件解析模式和最终模型可见内容；inline 文档在发送前成为消息内容，embeddings 文档则只有模型调用工具后才提供片段。与 Agent 工具类目共享的是 schema、审批和 SDK 回注循环；本笔记补充的是工具背后的 local collection、候选算法及持久化生命周期。

与检索驱动认知编排不可直接比较：当前源码只提供一次向量查询和显式读块工具，没有由检索结果驱动的固定阶段、关系路径、主动记忆维护或自动查询反馈。多次工具调用是模型侧可选行为，不能静态推断为稳定的认知链。

## 未验证事项

- 未运行 parseDocument、嵌入模型、sqlite-vec 和线性回退，未确认真实支持的文件类型、跨平台 ANN 装载、延迟、召回率或分数分布。
- 未运行模型工具循环，未确认不同 provider 对三个 schema 的调用率、是否会先列文件/再读块、错误后重试次数及取消传播效果。
- 未确认 SQLite collection 的实际数据目录、重启后的完整性、模型维度变化时已有 ANN 索引的行为，以及上述线程删除前缀组合在真实 UI 路径中的影响。
- 未发现 RAG 专用质量评测、离线夹具、缓存命中指标或针对文档提示注入的防护；这表示本次已检查范围未找到，不等同于项目全局不存在。

## 关键源码索引

- RAG 工具 schema 与执行：`extensions/rag-extension/src/tools.ts`、`extensions/rag-extension/src/index.ts:101-488`
- 向量 collection、摄取、删除与嵌入上下文保护：`extensions/vector-db-extension/src/index.ts:21-284`
- 本地 SQLite/ANN 与线性检索：`src-tauri/plugins/tauri-plugin-vector-db/src/db.rs:227-635`、`src-tauri/plugins/tauri-plugin-vector-db/src/commands.rs`
- 附件模式与发送时摄取：`web-app/src/lib/attachmentProcessing.ts:184-309`、`web-app/src/services/uploads/default.ts`
- 工具装配与模型请求：`web-app/src/lib/custom-chat-transport.ts:851-924,1389-1427`
- 工具执行、授权与自动续发：`web-app/src/routes/threads/$threadId.tsx:462-587,655-682,1000-1030`
- 结果解析与引用展示：`web-app/src/lib/citation-parser.ts`、`web-app/src/containers/message/RagToolWidget.tsx`、`web-app/src/components/Citations.tsx`
- 删除与线程清理：`web-app/src/containers/ChatInput.tsx:898-928`、`web-app/src/containers/ProjectFiles.tsx:546-568`、`web-app/src/hooks/useThreads.ts:44-59`
