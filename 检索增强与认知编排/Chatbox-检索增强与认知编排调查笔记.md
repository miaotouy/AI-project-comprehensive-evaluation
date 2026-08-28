# Chatbox 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`348d3875c1bffa3899539e61fa960d6ccb3ccafb`（分支：`main`）
>
> 调查方式：直接静态追踪当前源码中的 Electron 主进程、renderer 工具装配、SQLite/LibSQL 持久化、单元测试与会话附件评测夹具；未启动应用、未调用模型或外部解析/Embedding/Rerank 服务
>
> 调查范围：桌面端知识库和会话大附件的摄取、索引、模型工具查询、结果回注、预算、作用域、可观测与恢复；不重复网页搜索、MCP、代码执行及普通内联附件上下文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 同时实现了两个相邻但不可混同的谱系：可长期维护的知识资产管线，以及模型决定是否查询的工具化检索。前者以用户选中的单个知识库为单位，解析文件、切块、Embedding 后写入 `kb_<知识库 ID>` 向量索引；后者只面向同一会话消息中标记为 `session-retrieval` 的大附件，并为每个附件建立独立 `sa_<附件 ID>` 索引。两者的检索结果都不是发送前自动拼接的上下文，而是 AI SDK 工具调用结果，随模型的后续步骤回到模型输入。此结论为**源码事实**，入口见 `src/renderer/stores/session/tools-builder.ts:197-365`。

会话附件检索有明确的两段读取模式：先按子块向量召回、可选 rerank、按父块去重，再由模型用返回的父块 ID 请求较大的父块。它是一次查询内的候选重排与按需扩读，不会从上一轮命中自动生成下一轮查询，也未见主动维护用户记忆或思维图的路径。因此可比较其工具装配、候选数、来源字段和会话隔离，不能称为检索驱动认知编排。此段为**源码事实**；实际模型是否遵从“先查后读”的提示仍属**未运行验证**。

## 谱系定位与系统边界

知识库属于“知识资产管线 + 工具化检索”。主进程启动时初始化本地数据库、注册 IPC 并启动常驻待处理文件 worker；会话生成准备阶段仅在会话已绑定知识库且当前模型声明支持 `knowledge-base` 工具能力时，将四个知识库工具和文件清单说明装入本回合请求。工具装配不依赖 Agent 模式，装配失败只记录错误并省略该工具集。`src/main/knowledge-base/index.ts:11-58`、`src/renderer/stores/session/tools-builder.ts:221-274`。

会话附件 RAG 属于“会话作用域的工具化检索 + 相似度召回”。桌面端在窗口创建后初始化；Web 与移动平台的对应 controller 都直接抛出“未实现”。普通附件继续作为 inline 内容或文件工具上下文，只有桌面端、支持的扩展名、解析文本超过 256 KiB、未超过 6 MiB 安全上限、且具备默认 Embedding 模型或有效许可及远程能力时，才切换到 session-retrieval。`src/main/main.ts:579-585`、`src/renderer/stores/sessionHelpers.ts:287-346,523-726`、`src/renderer/platform/web_platform.ts:199-205`、`src/renderer/platform/mobile_platform.ts:315-321`。

两条链路均会把文件名和内容交给配置的解析、Embedding 或 rerank 提供方；是否出网、远端服务的数据保留与模型提供方权限，不能由本地调用代码确认。知识库可选择本地、Chatbox AI 或 MinerU 解析器；会话附件使用预处理后存储的文本。此为**静态代码所示的数据流**，外部服务行为**未验证**。

## 事实对象、摄取与索引

知识库的事实对象是知识库记录和其文件记录。前者保存名称、Embedding/Rerank/Vision 模型与解析器配置；后者保存文件路径、MIME、大小、分块计数、状态和错误。元数据与向量共用用户目录下的 `chatbox-databases/chatbox_kb.db`；每个知识库使用独立索引名。创建知识库要求名称和 Embedding 模型，上传限制原文件不大于 50 MiB，解析结果另限制不大于 20 MiB。`src/main/knowledge-base/db.ts:11-16,31-101`、`src/main/knowledge-base/ipc-handlers.ts:76-144,445-498`、`src/shared/knowledge-base.ts:1-5`。

知识库上传仅插入 pending 文件记录。worker 每 3 秒扫描 pending 项：按配置解析成文本，以递归策略切为最大 1200、重叠 150 的块，再以 50 块一批生成向量并写入索引；每批更新已处理数，完成后设为 done。首次和每批 Embedding 都禁用 SDK 自动重试，批间等待 100 ms，以避免重复计费。配置了 rerank 时，查询候选会再取前 5；无 rerank 或 rerank 异常时返回原始向量命中。`src/main/knowledge-base/file-loaders.ts:81-244,289-402,405-474`。

会话附件将附件、父块、子块分开持久化。附件记录绑定 `session_id`、`message_id` 与原始附件 storage key；父块保存较大正文和章节/页信息，子块保存原文、供向量化的带文件名/章节前缀文本及其父块关系。每个附件有自己的向量索引，元数据数据库与向量数据库也分别落在用户目录。状态依次为 pending、indexing、ready、failed 或 canceled，且索引阶段记录 queued、chunking、embedding、finalizing、ready。`src/main/session-attachment-rag/db.ts:14-19,39-61,161-218,495-520`。

附件 worker 一轮至多取 5 个 pending 项，先清除至多 20 个已取消项。它按文件扩展名选择结构化或普通文本管线：Markdown、JSON 和若干代码格式保留标题路径；父块目标 1600 字符、硬上限 2400，子块为 448 字符并重叠 64。向量写入以单队列串行化；每 50 个子块一批，遇到网络、429 或 5xx 的 Embedding 错误最多额外重试两次。`src/main/session-attachment-rag/chunking.ts:3-14,44-60,189-305`、`src/main/session-attachment-rag/file-loaders.ts:26-90,93-230,233-307`。

## 查询、候选与结果回注主链

**知识库主链。** 会话准备从所见消息、会话绑定的知识库和模型能力建立工具集。模型可以查询语义检索、查询文件元数据、按文件 ID 与块序号读取块、分页列文件；提示在装配时预载至多 50 个已完成文件名，要求模型自行决定是否查询。语义查询文本限制为非空且最多 1000 字符，主进程生成查询向量，在当前知识库索引取前 20 个命中，再可选重排至 5 个。结果格式化为文件名、块号、三位分数和文本后作为 tool result 返回模型。`src/renderer/packages/model-calls/toolsets/knowledge-base.ts:61-83,113-150,191-228`、`src/main/knowledge-base/ipc-handlers.ts:500-526`、`src/main/knowledge-base/file-loaders.ts:405-474`。

**会话附件主链。** 工具装配从本次 prompt 消息提取去重后的附件 ID，排除 blocked 状态；要求模型具备 `read-file` 工具能力。工具说明列出 ready、仍在索引和失败的附件，并明确全文不在 prompt。模型的查询工具将用户请求改写为语义 query，可指定 1 至 12 的返回数；构造的计划固定召回 20，默认最终返回 8、最高 12。`src/renderer/stores/session/tools-builder.ts:197-242,255-274`、`src/renderer/packages/model-calls/toolsets/session-attachment-rag.ts:66-104,117-165,168-198`。

主进程只检索传入 ID 中状态为 ready 的附件，对每个附件各取最多 20 个向量命中，按原始分数合并排序；若可解析到配置的 rerank 模型，则以全部合并命中重排，否则捕获错误后保留原排序。随后按父块 ID 去重并截断到最终数量。每个返回项携带附件 ID、父块 ID、文件名、可选章节路径、子块序号、分数和子块文本；模型可再调用读取父块工具，后端 SQL 同时要求父块 ID 与本回合允许附件 ID 匹配。`src/main/session-attachment-rag/ipc-handlers.ts:185-279,282-315`。

两类工具以 AI SDK 的文本 tool output 回注，而非由检索器直接改写 prompt。会话生成把 tools 传给流式模型调用；SDK 的停止条件由调用方可选 maxSteps 控制，未传入时为安全整数上限，并另外遇到持久化工具调用暂停时停止。故当前源码没有检索专属的总调用轮数或总返回字符/token 预算。`src/renderer/stores/session/agent-harness.ts:306-355`、`src/shared/models/abstract-ai-sdk.ts:344-359`。

## 阶段、反馈与结果注入

系统提示会建议知识库问题复用先前结果、主题变化或覆盖不足时再查；会话附件则建议先查询再按命中读取父块，并在索引中或失败时如实告知用户。这是给模型的策略文本，不是强制的查询规划器。源码中未找到上一轮候选自动改写下一次查询、关系扩展、阶段评分状态或检索结果写回知识资产的执行路径；检查范围为上述两个 toolset、两个主进程查询入口与会话 harness。因此“不具备认知编排循环”是**基于当前检查范围的静态判断**，不是对未来分支或未读扩展的绝对否定。

作为结果契约，知识库搜索保留 filename、chunkIndex、score、text，读取块保留 fileId、filename、chunkIndex、text；会话搜索额外保留 parentId、sectionPath，父块读取返回页范围、文本、tokenEstimate 与 charCount。工具层会将这些字段排版成可读文本，测试固定验证了来源、块/父块 ID、分数和正文会进入模型输出。`src/renderer/packages/model-calls/toolsets/knowledge-base.test.ts:23-84`、`src/renderer/packages/model-calls/toolsets/session-attachment-rag.test.ts:126-165`。

## 作用域、预算、可观测与恢复

知识库的作用域来自会话选择的单个知识库 ID，所有文件元数据、读取块和检索 IPC 都将该 ID 作为 SQL/索引边界；文件元数据查询最多 100 个文件 ID，读取最多 200 个块，分页单次最多 100 项。知识库工具未见逐文件 ACL、用户/租户标识或对文档中不可信指令的净化层。前一句是**源码事实**，后一句是对 `knowledge-base` IPC、toolset 和查询实现的**静态检查结果**。`src/main/knowledge-base/ipc-handlers.ts:324-442`。

会话附件的读取边界更细：工具只接收当前 prompt 消息提取的附件 ID；查询再次过滤 ready 状态，读取父块要求 parent ID 同时属于允许的附件 ID。为避免本地日志记录完整私密查询，查询日志只保留长度和最多 16 个字符的空白归一化前缀。它仍把检索文本交给模型，因此模型提供方和文档提示注入风险不由这一层消除。`src/main/session-attachment-rag/ipc-handlers.ts:45-64,185-201,282-301`。

可观测面包括主进程日志和 Sentry：知识库对初始化、IPC、解析、向量写入、查询和 rerank 标注 component/operation；会话附件记录状态迁移、候选数量和 rerank 异常。会话附件另有仅桌面端的开发面板，可查看两个数据库路径和大小、附件/父块/子块计数、状态计数、索引名及最近 20 个附件，并能手动执行维护或清空数据。查询分数虽会回传模型，但当前检查范围内未找到面向普通用户的候选、分数或 rerank 原因视图。`src/main/knowledge-base/index.ts:11-44`、`src/main/session-attachment-rag/db.ts:891-949`、`src/renderer/components/dev/SessionAttachmentRagDevPane.tsx:23-225`。

恢复语义存在两套策略。知识库启动时把中断的 processing 文件改为 paused，需用户恢复；运行超过 5 分钟的 processing 项标记 failed，failed 项可以 reset 为 pending 重试。删除知识库会删文件记录和整个向量索引；删除单文件时，即使向量删除失败仍会删除文件记录，因此 SQLite 与向量索引可能遗留不一致。`src/main/knowledge-base/db.ts:240-295`、`src/main/knowledge-base/ipc-handlers.ts:207-254,529-737`。

会话附件启动时把 indexing 直接标为 failed，并检查 ready 项是否缺少对应向量索引；缺失者也改为 failed。删除 pending/indexing/failed 附件先标 canceled，worker 检查到后删除其图和索引。renderer 定义了一个每 30 分钟按现存会话和消息清理孤儿、并清理已取消项的维护任务；但本次全仓库调用搜索只找到其定义，未找到初始化函数的调用，故其定时运行不能视为已确认。SQL 侧的附件、父块和子块删除是事务性的，但索引删除在事务提交后尽力执行，源码注释明确承认跨存储原子性缺口。导入备份时，桌面端会用已导入的 storage key 重建索引；创建失败则降为 inline 并产生警告，非桌面端直接降为 inline。`src/main/session-attachment-rag/db.ts:382-493,664-888`、`src/renderer/setup/session_attachment_rag_maintenance.ts:74-124`、`src/renderer/packages/backup/rehydrate.ts:7-72`。

## 与相邻谱系的可比/不可比边界

Chatbox 可与其他工具化检索系统比较：检索由模型还是固定规则触发、候选数与 rerank 降级、结果的来源/分数/父块契约、会话或知识库作用域、索引恢复和调试面。知识库部分还可与知识资产管线比较摄取状态、解析器、切块、可删除性和索引隔离。

它不应与主动记忆演化或检索驱动认知编排按“阶段思考能力”直接比较：本次找到的是单次语义查询、可选 rerank 与模型自行发起的后续工具调用，没有后台从聊天提取事实、合并/审批记忆、关系图传播或系统生成后继查询。检索质量、延迟、成本和模型实际工具遵从率没有运行数据，不能据静态参数判断优劣。

## 未验证事项

- **未运行验证**：知识库的本地、Chatbox AI 与 MinerU 解析器对各种格式的实际输出、分段质量、远端失败提示和暂停时机。
- **未运行验证**：Embedding/Rerank 模型的实际计费、网络传输、缓存命中、召回质量与 rerank 降级后的回答质量。
- **未运行验证**：完整端到端会话中模型是否按提示先查后读、工具结果是否因上下文压缩丢失，以及 maxSteps 的具体调用方配置。
- **已有评测资产但未执行**：仓库提供 session attachment RAG 的正向、隐式、多文档与无关问题夹具，以及覆盖 Electron、上传、索引、注册、模型调用和持久化消息的端到端 harness；本次未运行，不能把该文档描述当作运行结论。`docs/technical/session-attachment-rag-eval.md:7-18,59-86`。
- **本次未找到**：知识库的导入/导出重建策略、跨设备迁移时知识库原文件路径的有效性处理，以及普通用户可见的检索引用 UI；搜索范围为知识库主进程、renderer toolset、会话 harness 和备份 rehydrate 入口。

## 关键源码索引

- `src/renderer/stores/session/tools-builder.ts:197-365`：会话范围筛选、模型能力门槛与工具集合并。
- `src/main/knowledge-base/file-loaders.ts:81-244,405-544`：知识库切块、批量索引、向量检索与 rerank 降级。
- `src/main/knowledge-base/ipc-handlers.ts:445-737`：知识库上传、查询、读取、状态操作和删除。
- `src/main/session-attachment-rag/file-loaders.ts:93-307`：附件索引状态机、批量 Embedding、重试与取消。
- `src/main/session-attachment-rag/ipc-handlers.ts:185-315`：会话附件候选合并、重排、父块去重和读取隔离。
- `src/main/session-attachment-rag/db.ts:382-493,664-949`：启动修复、删除/孤儿维护和调试快照。
