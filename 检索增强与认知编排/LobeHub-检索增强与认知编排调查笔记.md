# LobeHub 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`7c559cbd4d92a54289bce3a8aab96e057d0ce8c5`（分支：`canary`）
>
> 调查方式：只读核对个人记忆工作流、提取服务、Agent 工具装配及已有汇总、独特功能和工具笔记；未运行 Upstash、PostgreSQL、向量检索或真实模型调用
>
> 调查范围：Personal Memory 的主动提取、五层事实模型、工具化检索/写回、作用域和运行约束；不展开知识库、网页搜索、普通对话压缩或 Goal/Schedule 调度本身
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的 Personal Memory 同时属于“主动记忆演化”和“工具化检索”。它将用户事实分为身份、偏好、经历、活动和情境五层，支持来源追踪、向量索引、用户编辑，以及由 Agent 工具读写。会话 topic 可由用户发起或小时工作流触发提取，提取后的记忆成为后续 Agent 回合可调用的 `lobe-user-memory` 工具事实源。

已确认的完整主链为“topic 进入受控异步工作流，先提取四类 CEPA 记忆再处理 identity，持久化后由开启记忆的 Agent 获得记忆工具；模型按需搜索、分类查询或写回，结果再参加工具循环”。这是结构化、可编辑的长期用户记忆，而非一次发送前固定注入候选文本。代码未显示检索命中自动构造下一阶段查询，因而不将其写成检索驱动认知编排。

## 谱系定位与系统边界

- **谱系**：主动记忆演化、工具化检索、结构化长期事实资产；源码事实。
- **事实对象**：用户记忆主表及身份、偏好、经历、活动、情境五层记录；记录带来源、标签、访问等属性，向量索引服务于语义查找。
- **执行边界**：提取在服务端 Upstash Workflow 中运行并写 PostgreSQL；模型消费通过内建工具加入 Agent runtime。用户和 Agent 配置共同决定工具是否可见。
- **相邻类目边界**：工具注册、审批和执行位置由 Agent 工具类目说明；发送层只记录 memory context 注入点。本笔记关注记忆如何产生、检索和写回。

## 事实对象、摄取与索引

Personal Memory 将用户事实分为五种可分别维护的对象：情境记录影响和关联，经历记录情境与学习，偏好记录行为指令和适用范围，活动记录叙述及时间地点，身份记录关系和角色。已有独特功能调查确认这些记录具有来源 message id、标签和访问计数，并由 PostgreSQL 向量索引支持语义检索；用户可在 memory 路由逐条查看和编辑。

摄取不是上传文档的同步切块。`processTopicHandler` 先验证来源、总开关和用户/异步任务取消状态，调用 `MemoryExtractionExecutor.extractTopic` 处理 CEPA 四层，再单独处理 identity 层。用户主动分析会更新 async task 进度；小时任务和工作流都有取消检查。见 `apps/server/src/router-hono/workflows/memory-user-memory/workflows/processTopic.ts:33-257`。

该分段处理确认身份提取与其余四层是两个顺序步骤，但不表示它们构成查询反馈阶段。提取质量、Embedding 模型、合并冲突策略和各层具体 schema 的全部字段不在本次源码复核范围内。

## 查询、候选与重排主链

```text
用户发起分析或小时工作流选择 topic
  -> processTopicHandler 进行 guard、取消检查与流量控制
  -> MemoryExtractionExecutor.extractTopic：CEPA 四层，随后 Identity 层
  -> 写入用户五层记忆与派生向量索引
  -> Agent 执行时解析 Agent 级或用户级 memory.enabled
  -> ToolsEngine 在允许时公开 lobe-user-memory
  -> 模型调用语义搜索/分类查询，必要时新增、更新或删除记忆
  -> 工具结果回注模型；写回后的记忆供后续回合与后续提取使用
```

工作流在每个关键阶段使用 guard，并将不可重试错误包装为 `WorkflowNonRetryableError`，避免错误反复入队；topic 工作流全局并发上限为 25，初始投递还使用每用户并发 5 的节流。这个主链的入口、阶段和失败收口见 `apps/server/src/router-hono/workflows/memory-user-memory/workflows/processTopic.ts:50-149,175-330`。

运行时先读 Agent 级 `memory.enabled`，否则读取用户设置；解析结果作为 `globalMemoryEnabled` 传入工具装配。工具引擎在 chat mode 白名单和 agent mode 规则中都用该值控制 Memory manifest，默认值为 false。见 `apps/server/src/services/aiAgent/index.ts:3085-3116` 与 `apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:284-336`。

## 阶段、反馈与结果注入

`lobe-user-memory` 是模型可调用的内建工具，描述为跨会话存储和召回用户偏好、活动、身份与经历。其 manifest 声明搜索、分类查询、五层写入、身份更新与带理由的身份删除等 API；模型看到工具后可根据上一工具结果继续行动。工具定义末端见 `packages/builtin-tool-memory/src/manifest.ts:980-1009`。

工具化消费意味着检索不必在每次发送前自动发生。模型可以检索、读取分类信息或写回，再把结果带入同一 Agent 工具循环；用户设置或 Agent 设置关闭时工具不会被自动注入。现有源码未确认候选融合、rerank、关系图传播，或把命中向量转化为固定的下一阶段查询，因此没有将此链描述为认知编排。

## 记忆写回与主动维护

这是三份笔记中唯一已确认存在后台主动维护的路径。小时工作流与用户主动分析均可触发 topic 提取；提取按层写入长期记忆，不需要模型在当前对话中显式调用写工具。与此同时，Agent 的记忆工具也提供运行时读写面，形成“后台提取 + 回合内增删改”的双写入来源。

用户主动任务和小时任务都可协作取消；工作流在 CEPA 与 identity 前重复检查取消，避免在请求取消后继续执行后续层。工作流出错时对非内部 abort 采用非重试错误，用户主动任务的失败处理仍更新进度记账。静态代码确认这些恢复/失败策略，但未验证数据库事务、重试和多来源并发写入的实际一致性。

## 预算、作用域、可观测与恢复

作用域首先是用户和 workspace 维度：工作流携带 user、topic 和可选 workspace，工具可见性由用户或 Agent 的 memory 开关控制。工具层还有 read-only/read-write 权限配置，但本次未重新追踪每一种 API 在全部执行路径的授权判定。

资源边界包括层选择、任务取消、工作流 guard、每用户限流和全局并发。工作流用 tracing 属性记录层、来源、topic 和用户，用户发起的任务以 async task 记录进度。可观测字段可以定位处理对象，但本次未运行确认管理页面、任务进度、提取原因、搜索分数或降级信息是否完整对用户可见。

## 与相邻谱系的可比/不可比边界

可与 Open WebUI Persistent Memory 比较用户事实的自动写回、工具读写、作用域与恢复；可与知识资产管线比较异步摄取、索引和可维护对象。它和普通 RAG 都能返回候选内容，但事实单位是用户记忆层，而非独立文档库的 chunk。

不可仅因有向量检索和后台提取就称为多阶段认知编排。当前未确认检索结果驱动连续查询方向、固定思维模块或关系路径传播。Knowledge Base、网页搜索与用户记忆是独立工具/资产面，不应将它们合并为一条检索链。

## 未验证事项

- 未运行 Upstash Workflow、PostgreSQL/HNSW、LLM 提取或语义检索，提取准确度、召回质量、延迟和小时扫描成本未验证。
- 本次未逐读 `MemoryExtractionExecutor` 的去重、合并、删除、Embedding 和向量查询实现，未确认候选数、相似度阈值或 rerank。
- Agent 级、用户级开关与 read-only/read-write 权限在全部工具 API 上的实际优先级和审批行为未运行验证。
- 并发的小时提取、用户主动提取和模型工具写回发生冲突时的合并、重试、删除恢复和来源一致性未验证。

## 关键源码索引

- `apps/server/src/router-hono/workflows/memory-user-memory/workflows/processTopic.ts:33-330`：按层提取、取消、失败与并发控制主链。
- `apps/server/src/services/memory/userMemory/extract.ts:679-725`：记忆提取执行器创建与服务入口。
- `packages/builtin-tool-memory/src/manifest.ts`：Memory 工具的搜索、分类查询与写回 API 契约。
- `apps/server/src/services/aiAgent/index.ts:3085-3116`：Agent/用户 memory.enabled 的运行时解析。
- `apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:284-336`：chat/agent mode 下的 Memory 工具可见性门控。
- `packages/database/src/schemas/userMemories/`：五层记忆对象、来源字段和向量索引 schema。
