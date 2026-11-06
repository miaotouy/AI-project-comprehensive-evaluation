# Cherry Studio 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：只读核对知识库服务、摄取任务、查询工具及 Agent 工具装配；参考已有能力汇总、独特功能和工具笔记；未运行 Electron、索引任务或模型请求
>
> 调查范围：本地知识库的摄取、索引、模型工具化检索、作用域与结果回注；不展开普通会话 FTS、外部 Dify 知识库服务和网页搜索
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的本地知识库属于“知识资产管线”与“工具化检索”的组合，检索结果由模型工具调用带回，不在发送前自动拼接进 prompt。知识库以 Base、条目、chunk 与可读取 Concept 为事实对象；写侧由后台任务准备、索引、检查和重建，读侧由模型在 Agent 回合中调用 `kb_search`、`kb_read`、`kb_list` 或 `kb_manage`。

已确认的主链是“绑定或本回合选中的知识库限定可见工具范围，模型搜索命中后再按 Concept 深读，工具结果作为回合结果回注模型”。查询本身没有固定的下一阶段向量、重排反馈或额外 LLM 回合；是否继续搜索和读原文由模型工具循环决定。工具在连接建立时按当时范围决定是否注册；范围为空则不注册，每次调用再重读范围，中途变空则以错误拒绝，避免共享查询核心把空白名单误解为全部知识库。

## 谱系定位与系统边界

- **谱系**：知识资产管线、工具化检索；源码事实。
- **事实源**：本地知识库及其条目、chunk、Concept 内容和组织树。普通聊天的跨会话 FTS 是产品搜索，不计入本笔记的检索主链。
- **执行边界**：知识库服务、任务和 in-process `cherry-tools` MCP 都在 Electron 主进程。普通聊天与 Claude Code Agent 的工具接入不同，但此处的知识工具共享同一受作用域限制的提供者。
- **相邻类目边界**：知识库 id 如何从 Composer 的 `data-knowledge-scope` message part 进入请求，见“对话请求与上下文”笔记；模型工具的注册、审批和循环上限见“Agent 工具”笔记。

## 事实对象、摄取与索引

知识库服务将管理、摄取、查询和 Concept 读写拆分。Base 是顶层范围；条目可被添加、删除和重新索引；索引后的内容以 chunk 支持召回，Concept 表示可按字符范围读取或 grep 的文档对象。服务还提供组织树，因此模型不必仅依赖相似度片段定位原文。接口集中在 `src/main/features/knowledge/KnowledgeService.ts:76-169`。

摄取为异步任务式生命周期。初始化时注册根目录准备、文档索引、文件处理结果检查、子树删除和重新索引 handler；应用完全就绪后会恢复删除中或中断的条目。重新索引不再默认复用库内旧副本：文件重新复制原文件，目录根重新扫描原目录，Note 从数据库内容重建快照，URL 重新获取。重取阶段失败会将对应根标为失败；若来源在入队后、锁内重置前消失，则跳过该根并保留现有向量与可搜索状态。来源解析与写入见 `src/main/features/knowledge/pipeline/sources/reacquire.ts`、`tasks/reindexSubtreeJobHandler.ts`。

文档转 Markdown 与图片转文本由文件处理子系统独立承担：文件处理有自己的任务模型（`FileProcessingService` 与 `FileProcessingTaskId`），知识库摄取只通过任务 API 创建与查询任务，不再直接调用处理器；判断处理结果改为任务结算时检查一次，而不是轮询。导入来源的文件复制也被移出 Base 锁，避免长耗时复制阻塞同一知识库的其它操作。依据：`src/main/features/fileProcessing/FileProcessingService.ts`、`ingestion/KnowledgeIngestionService.ts`、`tasks/utils/jobInput.ts`。

## 查询、候选与重排主链

```text
Agent 静态绑定的知识库，或本回合冻结的 Composer 选择
  -> 连接建立时 registerKnowledgeTools：范围为空则不注册任何 kb_* 工具
  -> 每次调用 allowedIds 重新读取范围；范围中途为空则以错误拒绝
  -> 模型调用 kb_search(query, baseIds)
  -> searchKnowledge 在允许的 Base 内产生候选并返回模型可读结果
  -> 模型可按命中 Concept 调用 kb_read，或以 pattern 在原文 grep
  -> kb_manage 可 add（支持批量 items）/ delete / refresh / create
  -> 工具结果经 modelOutputToMcpResult 转成 MCP 结果，进入当前 Agent 工具循环
```

`registerKnowledgeTools` 在注册时算一次作用域，之后每次调用重读；范围为空时工具根本不存在，直调也以一个失败错误结束。常规 Agent 的有效范围是静态绑定与连接创建时冻结的 Composer 选择的组合；内置 Assistant 可明确获得 unrestricted 范围。受限范围以非空 tuple 传给共享查询核心，避免核心把空数组解释为不限制范围，见 `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:93-153`。

写入面比读面宽：`kb_manage` 的动作除增删改外新增 create，可在会话内新建知识库并批量加入来源（`KB_MANAGE_ADD_TYPES` 覆盖 file、url、note，批量上限与摄取管线共享）。为了让 Agent 能继续操作自己新建的库，连接内成功创建过的 Base 会被加入该连接的有效范围；这个提升只活在这条连接内，不持久化，也不影响其它会话。绑定仍是既有 Base 的上限，作用域中途变空时连新建的 Base 一并拒绝，见 `cherryKnowledgeTools.ts:104-117,145-153`、`src/shared/ai/builtinTools.ts:326-332`。

候选的精确排序算法不在本次已读入口中展开。源码确认 `kb_search` 是语义查询入口，并携带命中所属 Base 与可读 Concept 标识；`kb_read` 可读取区段或按 pattern 搜索文档，`kb_list` 可列 Base 或展示组织树。这构成“先找候选、后扩展证据”的工具协议，而不是一次查询即把全文注入。工具注册走 MCP SDK v2 的 `McpServer.registerTool`，模型侧输出统一经 `modelOutputToMcpResult` 转成文本结果；工具描述在共享契约里压到约 120 字符，以减少每回合的固定 token 占用。见 `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:122-155`、`src/main/ai/mcp/toolResult.ts`。

## 阶段、反馈与结果注入

查询由模型驱动：模型可在收到搜索结果后继续读 Concept、换词搜索或结束回合。当前代码没有发现组件内部把前一批命中向量、分数或摘要变成下一阶段查询的固定协议，因此不能将该路径归为检索驱动认知编排。

结果通过 MCP 工具结果回注模型，不是由知识组件主动拼接进所有请求。普通聊天与 Claude Code 的外层工具循环和审批机制不同；`kb_manage` 的写操作在 Claude Code 路径依赖逐次权限提示，AI SDK 路径由 `needsApproval` 处理。这是工具调用控制面，负责调用与审批；查询结果的内容安全净化需另行确认。见 `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:1-22`。

## 作用域、预算、可观测与恢复

作用域在本实现中有明确约束：Base id 限制在有效 scope 内，空范围 fail-closed；但内置 Assistant 的 unrestricted 是显式授权，不能和“未绑定”混同。Composer 选择只在连接创建时冻结，修改选择需要重建连接，静态绑定部分则可在再次列工具或调用时重读。会话内新建的 Base 只提升当前连接的范围，属于有意的自治放宽而非新的授权来源。

恢复方面，启动恢复删除中与中断条目，重建入口也存在；重建会在 mutation lock 前读取真实来源，锁内再次确认目标未进入删除态，再替换索引。取消若发生在破坏性重置前会保留旧索引；根已切到 active 状态后，调度失败或中断才由结算路径标为失败，避免永久停在处理中。查询工具接口没有传入 `AbortSignal`；本次仍未确认检索超时、候选数、chunk token 预算、Embedding 缓存身份、查询日志或质量评估。

## 与相邻谱系的可比/不可比边界

可与 Chatbox、Jan、Open WebUI 等模型工具化资料检索比较“绑定范围、search/read 两段协议、工具循环和结果预算”。它也可与知识资产管线比较摄取恢复和文档维护。

本链与发送前 Lorebook、VCPToolBox 思维簇分属不同机制：候选由模型通过工具循环按需查询获得，检索结果是否形成固定的后续查询方向本次未确认。外部 `difyKnowledge` MCP、会话全局搜索和网页搜索未纳入本次范围，其检索策略本次未调查。

## 未验证事项

- 未运行本地知识库的导入、文件处理、切块、Embedding、索引恢复或真实查询，候选质量、延迟和中文效果均未验证。
- 本次未逐读 `KnowledgeQueryService` 与 `knowledgeLookup` 的候选生成实现，未确认向量、关键词、混合、rerank、去重和 K 值的具体策略。
- 未验证模型会否按搜索结果继续调用读取工具，以及工具返回文本中不可信资料对模型的实际影响。
- 未验证取消、超时、跨窗口修改 Composer 选择、删除/重建与正在查询之间的一致性。
- 未运行验证 `kb_manage` 的 create 与批量 add：新建 Base 的默认索引策略、批量导入的失败回滚，以及审批提示在 Claude Code 与 AI SDK 两条路径上的实际表现。
- 文件处理任务模型与知识库任务的交接（任务结算检查替代轮询）未在真实任务链上观测。

## 关键源码索引

- `src/main/features/knowledge/KnowledgeService.ts`：知识库服务、任务注册、恢复和读写门面。
- `src/main/features/knowledge/ingestion/KnowledgeIngestionService.ts`：条目导入、文件复制与处理任务衔接。
- `src/main/features/fileProcessing/FileProcessingService.ts`：独立的文件处理任务模型。
- `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:93-153`：作用域建模、注册时机、会话内新建 Base 的范围提升与 fail-closed 调用。
- `src/shared/ai/builtinTools.ts:326-432`：搜索、读取、grep、管理动作与命中/Concept 结果契约。
- `src/shared/ai/claudecode/toolRegistry.ts`：Claude Code 知识工具的范围门控与依赖关系。
- `src/main/ai/tools/knowledgeLookup.ts:476-572`：搜索、读取、列出和管理操作的共享入口（含批量添加）。
- `src/main/ai/mcp/toolResult.ts`：模型输出到 MCP 结果的统一转换。
- `src/main/features/knowledge/pipeline/sources/reacquire.ts`、`tasks/reindexSubtreeJobHandler.ts`：真实来源重取、锁内重置与失败收口。
