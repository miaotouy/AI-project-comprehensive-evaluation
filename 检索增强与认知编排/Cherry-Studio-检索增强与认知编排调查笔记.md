# Cherry Studio 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`88cfe5dd2b77e63464be22968f66ebcb1d429483`（分支：`main`）
>
> 调查方式：只读核对知识库服务、摄取任务、查询工具及 Agent 工具装配；参考已有能力汇总、独特功能和工具笔记；未运行 Electron、索引任务或模型请求
>
> 调查范围：本地知识库的摄取、索引、模型工具化检索、作用域与结果回注；不展开普通会话 FTS、外部 Dify 知识库服务和网页搜索
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的本地知识库属于“知识资产管线”与“工具化检索”的组合，而不是发送前自动把相似文本塞进 prompt 的即时注入器。知识库以 Base、条目、chunk 与可读取 Concept 为事实对象；写侧由后台任务准备、索引、检查和重建，读侧由模型在 Agent 回合中调用 `kb_search`、`kb_read`、`kb_list` 或 `kb_manage`。

已确认的主链是“绑定或本回合选中的知识库限定可见工具范围，模型搜索命中后再按 Concept 深读，工具结果作为回合结果回注模型”。查询本身没有固定的下一阶段向量、重排反馈或额外 LLM 回合；是否继续搜索和读原文由模型工具循环决定。知识库范围为空时工具既不列出也拒绝直接调用，避免共享查询核心把空白名单误解为全部知识库。

## 谱系定位与系统边界

- **谱系**：知识资产管线、工具化检索；源码事实。
- **事实源**：本地知识库及其条目、chunk、Concept 内容和组织树。普通聊天的跨会话 FTS 是产品搜索，不计入本笔记的检索主链。
- **执行边界**：知识库服务、任务和 in-process `cherry-tools` MCP 都在 Electron 主进程。普通聊天与 Claude Code Agent 的工具接入不同，但此处的知识工具共享同一受作用域限制的提供者。
- **相邻类目边界**：知识库 id 如何从 Composer 的 `data-knowledge-scope` message part 进入请求，见“对话请求与上下文”笔记；模型工具的注册、审批和循环上限见“Agent 工具”笔记。

## 事实对象、摄取与索引

知识库服务将管理、摄取、查询和 Concept 读写拆分。Base 是顶层范围；条目可被添加、删除和重新索引；索引后的内容以 chunk 支持召回，Concept 表示可按字符范围读取或 grep 的文档对象。服务还提供组织树，因此模型不必仅依赖相似度片段定位原文。接口集中在 `src/main/features/knowledge/KnowledgeService.ts:76-169`。

摄取为异步任务式生命周期。初始化时注册根目录准备、文档索引、文件处理结果检查、子树删除和重新索引 handler；应用完全就绪后会恢复删除中或中断的条目。这确认了索引可恢复的任务边界，但本次未逐读切块算法、Embedding provider、混合检索权重及重排阈值。见 `src/main/features/knowledge/KnowledgeService.ts:53-74`。

## 查询、候选与重排主链

```text
Agent 静态绑定的知识库，或本回合冻结的 Composer 选择
  -> CherryKnowledgeTools 计算 effective scope
  -> 有范围才向模型公布 kb_search / kb_read / kb_list / kb_manage
  -> 模型调用 kb_search(query, baseIds)
  -> searchKnowledge 在允许的 Base 内产生候选并返回模型可读结果
  -> 模型可按命中 Concept 调用 kb_read，或以 pattern 在原文 grep
  -> 工具结果进入当前 Agent 工具循环，模型决定是否继续查询或作答
```

`CherryKnowledgeTools` 在列工具和每次调用前重新计算作用域。常规 Agent 的有效范围是静态绑定与连接创建时冻结的 Composer 选择的组合；内置 Assistant 可明确获得 unrestricted 范围。范围为空时不公布工具，直调也以错误返回。受限范围以非空 tuple 传给共享查询核心，避免核心把空数组解释为不限制范围，见 `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:57-76,152-194`。

候选的精确排序算法不在本次已读入口中展开。源码确认 `kb_search` 是语义查询入口，并携带命中所属 Base 与可读 Concept 标识；`kb_read` 可读取区段或按 pattern 搜索文档，`kb_list` 可列 Base 或展示组织树。这构成“先找候选、后扩展证据”的工具协议，而不是一次查询即把全文注入。工具输出会转成文本或 JSON 字符串作为 MCP 调用结果，见 `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:88-141`。

## 阶段、反馈与结果注入

查询阶段由模型拥有：模型可在收到搜索结果后继续读 Concept、换词搜索或结束回合。当前代码没有发现组件内部把前一批命中向量、分数或摘要变成下一阶段查询的固定协议，因此不能将该路径归为检索驱动认知编排。

结果通过 MCP 工具结果回注模型，不是由知识组件主动拼接进所有请求。普通聊天与 Claude Code 的外层工具循环和审批机制不同；`kb_manage` 的写操作在 Claude Code 路径依赖逐次权限提示，AI SDK 路径由 `needsApproval` 处理。这是工具调用控制面，不表示查询结果已经过内容安全净化。见 `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:1-22`。

## 作用域、预算、可观测与恢复

作用域是本实现最明确的边界。Base id 限制在有效 scope 内，空范围 fail-closed；但内置 Assistant 的 unrestricted 是显式授权，不能和“未绑定”混同。Composer 选择只在连接创建时冻结，修改选择需要重建连接，静态绑定部分则可在再次列工具或调用时重读。

恢复方面，启动恢复删除中与中断条目，重建入口也存在。查询工具接口没有传入 `AbortSignal`，源码注释明确知识服务没有取消管线；本次未确认检索超时、候选数、chunk token 预算、Embedding 缓存身份、重排、查询日志或可视化证据面。

## 与相邻谱系的可比/不可比边界

可与 Chatbox、Jan、Open WebUI 等模型工具化资料检索比较“绑定范围、search/read 两段协议、工具循环和结果预算”。它也可与知识资产管线比较摄取恢复和文档维护。

不可将其与发送前 Lorebook 或 VCPToolBox 思维簇等同：本链不自动注入候选，也未确认检索结果形成固定的后续查询方向。外部 `difyKnowledge` MCP、会话全局搜索和网页搜索未纳入本次范围，不能据此推断其检索策略。

## 未验证事项

- 未运行本地知识库的导入、文件处理、切块、Embedding、索引恢复或真实查询，候选质量、延迟和中文效果均未验证。
- 本次未逐读 `KnowledgeQueryService` 与 `knowledgeLookup` 的候选生成实现，未确认向量、关键词、混合、rerank、去重和 K 值的具体策略。
- 未验证模型会否按搜索结果继续调用读取工具，以及工具返回文本中不可信资料对模型的实际影响。
- 未验证取消、超时、跨窗口修改 Composer 选择、删除/重建与正在查询之间的一致性。

## 关键源码索引

- `src/main/features/knowledge/KnowledgeService.ts:53-169`：知识库服务、任务注册、恢复和读写门面。
- `src/main/ai/mcp/servers/cherryKnowledgeTools.ts:57-194`：作用域建模、工具可见性、fail-closed 调用与 MCP 输出。
- `src/shared/ai/builtinTools.ts:135-307`：搜索、读取、grep 与命中/Concept 结果契约。
- `src/shared/ai/claudecode/toolRegistry.ts:285-314,410-415`：Claude Code 知识工具的范围门控与依赖关系。
- `src/main/ai/tools/knowledgeLookup.ts`：搜索、读取、列出和管理操作的共享入口。
