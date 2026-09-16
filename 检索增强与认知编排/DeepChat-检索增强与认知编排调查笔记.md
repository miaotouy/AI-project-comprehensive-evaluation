# DeepChat 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`31a6b05ab77986b3f8086d9e16c565c3251639e0`（分支：`dev`）
>
> 调查方式：只读核对 Session Tape、搜索投影、召回服务与模型工具；参考已有能力汇总、独特功能和工具笔记；未运行 Electron、SQLite FTS 或真实模型回合
>
> 调查范围：DeepChat 会话 Tape 的可检索轨迹、子 Agent 范围和工具化召回，以及 Agent memory 的检索、写回和维护链；不把普通聊天 FTS、网页搜索或上下文压缩本身当作 RAG
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 在本类目有两条不同谱系的主链。Session Tape 提供工具化轨迹检索：模型先以 `tape_search` 取得带来源和分数的紧凑结果，再用 `tape_context` 展开受字节预算约束的证据。Agent memory 则从对话提取候选事实，维护 embedding/FTS 检索、冲突与合并状态，并在请求前按 persona、working memory 与 query recall 三类预算注入上下文。

检索使用当前会话的有效 Tape 视图；已完成的直属子 Agent Tape 可被显式加入只读范围。搜索优先走 SQLite FTS 投影及 BM25 分数，投影不可用或不新鲜时回退到有效行搜索。搜索结果不会自动注入本轮 prompt，也未发现“命中改变固定下一阶段查询”的协议，后续行动仍由模型工具循环决定。

Memory 与 Tape 不共享事实对象。Memory 行拥有生命周期、冲突、派生和遗忘 tombstone；查询 embedding 带熔断与取消，召回结果会自动进入发送前 memory contribution。后台维护可做 challenge、merge、reflection 与 persona 草稿，但维护有 LLM 调用预算，并不构成固定多阶段推理链。

## 谱系定位与系统边界

- **谱系**：工具化检索、会话级长期轨迹召回；上下文即时注入、主动记忆演化；源码事实。
- **事实对象**：Tape entry、anchor、消息、工具调用/结果、搜索投影和已完成直属子会话的冻结读取头；另有 Agent memory、persona/working 行、冲突关系、派生边和遗忘 tombstone。
- **范围边界**：仅 DeepChat Agent 会话可用；链接范围只接受 finalized direct child Tapes，不能任意按 session id 跨会话读取。
- **不计入范围**：会话历史 FTS 是用户搜索/模型工具的另一条链，web 搜索是外部资料获取；二者不替代 Tape 的轨迹证据协议。

## 事实对象、摄取与索引

Tape 在会话运行过程中持久化执行事实和视图。已有 Tape/Trace 主链将消息与工具事实写入 SQLite，并维护 view manifest、lineage 和可审计执行记录；搜索对象是有效视图中可见的 entry，既不是切块后的上传文件，也不是原始对话文本的无条件全文副本。

召回服务可为当前 Tape 建立搜索投影。投影把 entry 的 kind、名称、用户消息摘要、证据文本和引用组合为 `searchText`，并保存摘要与 refs；投影元数据以最大 entry id 判断是否与 Tape 同步，不相符时追加或整体替换。见 `src/main/tape/application/recallService.ts:444-512`。SQLite 表及 FTS 维护在 `src/main/tape/infrastructure/sqlite/tapeSearchProjectionStore.ts`；本次未运行迁移与重建。

Agent memory 的主表维护 active、archived、conflicted 生命周期，以及 conflict target、persona state、derivation edge 和 exact-forgetting tombstone。普通 memory 才进入召回；persona 与 working 行走高优先级注入，不参与一般召回索引。表约束与索引见 `src/main/memory/data/tables/agentMemory.ts:93-221`、`:723-776`，生命周期判定见 `src/main/memory/core/lifecycle.ts:45-59`。

## 查询、候选与重排主链

```text
DeepChat Agent 当前回合拥有 agent-tape 工具
  -> 模型调用 tape_search(query, scope, kinds, 时间范围, limit)
  -> AgentTapeToolHandler 确认 DeepChat 会话并转交 TapeRecallService
  -> 当前 Tape：同步的 FTS 投影检索，失败或过期时回退有效视图搜索
  -> 返回来源 session、entry id、kind、摘要、refs 与可用 score 的紧凑候选
  -> 模型选择 entryIds 调用 tape_context
  -> 服务在同一 Tape 或已完成直属子 Tape 中取邻近证据，按条目数与字节预算裁剪
  -> 工具结果回注模型，模型决定继续检索、调用其他工具或作答
```

`tape_search` 的参数限制了单次结果为 1 至 50 条，默认 20 条，可按 entry 类型、时间和 scope 过滤。处理器只向符合条件的 DeepChat 会话公开工具，结果先压缩为 overview，避免搜索阶段直接返回原始大 payload。见 `src/main/tool/agentTools/agentTapeTools.ts:20-52,177-247`。

当前 Tape 的搜索先检查投影是否覆盖最新 entry；可用时调用投影检索并保留 score，不可用则对有效行回退搜索。链接范围会先由 lineage 服务解析可访问来源，再合并、去重、排序并限制总数，见 `src/main/tape/application/recallService.ts:113-184,302-356`。这是 FTS/BM25 候选加范围过滤的实现；本次未确认是否存在额外语义向量召回或 reranker。

## 阶段、反馈与结果注入

第二阶段 `tape_context` 接受最多 20 个 entry id，在目标条目前后选取窗口；默认每条证据 2 KiB、总计 16 KiB，调用方最多可提高至每条 8 KiB、总计 64 KiB。返回值保留 summary、refs、证据文本、字节数和截断标记，使模型可区分检索概览与展开后的证据。见 `src/main/tool/agentTools/agentTapeTools.ts:54-107,249-262` 与 `src/main/tape/application/recallService.ts:187-300`。

这是一条由模型控制的 search-then-read 工具链。上一阶段结果提供下一次工具调用的 entry id，但系统没有自动依据分数、向量或结构状态生成新的查询，也没有确认增加额外 LLM 回合的固定计划器。因此它不属于检索驱动认知编排；Tape 本身的记录、压缩和审计也不等于主动记忆演化。

Memory 召回则在请求前自动执行。检索服务生成查询 embedding，结合向量与派生索引选出可召回行；query embedding circuit 会在连续失败后短路，并响应取消信号，避免已取消请求继续消耗 embedding 工作。注入器把 persona、working 和 query recall 分配到硬 token 预算，受限时优先保证各 lane 的最小片段，再按优先级扩展，见 `src/main/memory/infra/queryEmbeddingCircuit.ts`、`src/main/memory/services/retrievalService.ts`、`src/main/memory/core/contributionBudget.ts:41-165`。

## 记忆写回与主动维护

对话后的候选写入会先经过去重和决策，结果可为新增、更新、替代、无操作或挑战；更新或替代要求模型返回受长度约束的合并文本。维护服务按 challenge、merge、reflection、persona 四类步骤分别计入 LLM 调用预算，并把合并、反思、替代和手工编辑记录为派生关系。服务边界见 `src/main/memory/services/writeCoordinator.ts`、`mergeService.ts`、`maintenanceService.ts` 与 `src/main/memory/core/maintenanceBudget.ts:1-53`。

Persona 演化生成草稿，不会直接覆盖生效人格；active/draft 状态由专门路径维护。删除使用 tombstone 保存作用域化内容哈希，防止已明确遗忘的同一事实被后续提取重新加入。该链具备受预算约束的主动记忆维护，但本次未确认无人触发时的独立调度周期。

## 作用域、预算、可观测与恢复

对子 Agent 的读取采用授权且只读的快照边界。若所请求子 Tape 不在直属 finalized lineage 中，服务返回 unauthorized；若该来源不可用则报 unavailable。链接上下文同样按来源当时的读取头取证，不把后续写入混入已授权结果，见 `src/main/tape/application/recallService.ts:359-438`。

预算由工具 schema 和召回服务共同约束：搜索上限、上下文条数、邻近窗口、单条/总字节数均有上界。可观测结果携带 session、entry、kind、时间、摘要、引用和投影提供的分数；Tape UI 还能显示轨迹，但本次未运行确认 UI 是否完整呈现每次召回。投影查询失败会回退有效视图搜索，减少索引不可用时的完全失效。

## 与相邻谱系的可比/不可比边界

可与 Jan、Chatbox、Open WebUI 的工具化检索比较“模型何时搜索、search/read 粒度、结果来源和预算”。它也可与会话交付和轨迹处理能力比较记录可追溯性和子 Agent 作用域。

不可与知识库摄取管线比较文档切块、Embedding 模型、租户级资料治理，因为本链的主事实源是 DeepChat 运行记录；也不可与发送前记忆注入或多阶段认知链比较，当前未发现自动注入、向量阶段反馈或后台整理 Tape 以改变后续查询方向的实现。

Memory 链可与长期用户记忆比较提取、冲突、遗忘、persona 审批和发送前注入；它仍不是文档知识库，也没有把上一轮检索结果自动改写成下一阶段查询。Tape 与 Memory 可同时进入一个请求，但分别承担审计轨迹召回和长期记忆贡献。

## 未验证事项

- 未运行 SQLite FTS 投影、BM25 排序、fallback、迁移或中文查询，质量、延迟和投影新鲜度未验证。
- 本次未逐读 `effectiveView` 与底层投影 SQL，未确认 tokenization、同分排序和所有 kinds/时间过滤的实际边界。
- 未验证模型是否合理执行 search-then-context，也未验证工具结果在长期会话中的上下文成本和注入风险。
- Tape 与压缩后的 entry 保留关系、投影重建的崩溃恢复、跨会话 lineage 的实际生命周期仍待运行验证。
- 未运行 memory embedding、熔断恢复、冲突合并、persona 草稿审批和 tombstone 防重提取；各策略的质量与长期衰减效果不能由静态代码确认。

## 关键源码索引

- `src/main/tool/agentTools/agentTapeTools.ts:20-264`：模型工具 schema、会话可用性、search/context 调度及预算。
- `src/main/tape/application/recallService.ts:113-184`：当前 Tape 的投影优先检索与回退。
- `src/main/tape/application/recallService.ts:187-438`：上下文扩展、字节裁剪与直属子 Tape 授权。
- `src/main/tape/application/recallService.ts:444-512`：搜索投影的新鲜度、追加/替换和结果字段。
- `src/main/tape/infrastructure/sqlite/tapeSearchProjectionStore.ts`：SQLite 投影、FTS5 与 BM25 查询实现。
- `src/main/tape/application/sessionTape.ts`：Tape 事实记录、服务装配与召回入口。
- `src/main/memory/services/retrievalService.ts`、`src/main/memory/infra/queryEmbeddingCircuit.ts`：Memory 检索、查询 embedding、取消与熔断。
- `src/main/memory/services/writeCoordinator.ts`、`mergeService.ts`、`maintenanceService.ts`：候选写入、合并与维护。
- `src/main/memory/core/contributionBudget.ts`、`maintenanceBudget.ts`、`tombstone.ts`：注入预算、维护预算与精确遗忘。
