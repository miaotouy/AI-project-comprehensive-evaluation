# OpenClaw 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：直接静态阅读当前快照的 `memory-core`、`active-memory`、`memory-wiki`、可替换 `memory-lancedb` 插件、Agent prompt/工具/会话边界、Memory Host SDK、相关配置、测试和当前源码文档；沿索引摄取、查询、结果注入、写回和生命周期调用链追踪。未启动 Gateway，未调用真实 Embedding、模型、QMD 或端到端会话。
>
> 调查范围：记忆 provider/manager、Markdown 与 session corpus、QMD 移除后的内置 SQLite 引擎、FTS/向量/Embedding、摄取/重建、`memory_search`/`memory_get`、Active Memory、项目记忆、Memory Wiki、候选融合/重排/预算/来源/权限、不可信内容、缓存/失败/取消/恢复，以及 dreaming 和记忆写回；普通 skills、工具目录、固定 prompt、网页搜索和一般上下文压缩不作为 RAG 能力，除非它们直接参与记忆检索链。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**谱系定位。** OpenClaw 在当前快照中同时落入以下谱系：

| 谱系 | 状态 | 判断依据 |
| --- | --- | --- |
| 相似度召回 | **主链确认，源码事实** | `memory-core` 对 Markdown/session chunks 做 Embedding 向量检索、SQLite FTS5/BM25 或二者混合，再做时效、重要性、项目亲和度和 MMR 处理。 |
| 知识资产管线 | **主链确认，源码事实** | `memory-wiki` 把来源、实体、概念、综合页、报告、claims/evidence 和关系编译成可维护的 Wiki vault；内置记忆则把工作区文件、额外路径和可选会话转成按 agent 存储的 SQLite 派生索引。 |
| 工具化检索 | **主链确认，源码事实** | Agent 可调用 `memory_search` 后再用 `memory_get` 精读；Wiki 另提供 `wiki_search`/`wiki_get`/维护工具；Active Memory 的子 Agent 只获准使用配置的记忆工具。 |
| 上下文即时注入 | **主链确认，源码事实** | `MEMORY.md`/`USER.md` 在 Bootstrap 阶段按资格和预算注入；Active Memory 先做触发词召回，再可把摘要作为 `before_prompt_build` 的隐藏前缀；`memory-wiki` 可注入受预算限制的 compiled digest。 |
| 检索驱动认知编排 | **部分实现，源码事实 + 静态推断** | Active Memory 能按召回意图和首层结果决定是否启动一次阻塞的记忆子 Agent，并由该子 Agent 选择记忆工具；但当前没有确认 VCPToolBox 式固定多阶段查询向量反馈、关系路径传播到下一查询或由检索命中自动生成下一自然语言问题的内置协议。Wiki 的 claims/关系、相邻文件和固定研究能力也不等于该谱系。 |
| 主动记忆演化 | **主链确认，源码事实** | `memory-core` 默认注册受 cron 管理的 light → REM → deep dreaming：先收集和评分短期召回，再由确定性门控和有界 consolidation 子 Agent 维护 `MEMORY.md`，并把摘要/前像写入审阅面。 |

**总体判断。** OpenClaw 的中心设计不是一个外置知识库，而是“可编辑 Markdown 事实源 + 每 agent SQLite 派生索引 + 受权限控制的工具召回 + 发送前即时注入 + 后台记忆晋级”。内置检索的最终输出通常仍是当前回合的候选片段或精确文件区段；认知编排只在 Active Memory 的“主 Agent → 记忆子 Agent → 记忆工具 → 有界摘要”路径中部分出现，不能因为存在第二个模型回合就写成已实现的多阶段推理 RAG。

**当前快照的重要边界。** QMD memory backend 已移除，配置迁移代码只负责把旧 QMD 路径/会话设置迁移到内置 `memory.search.extraPaths`、session source 和相关设置；当前内置后端是唯一内置 memory engine。QMD 的 learned cross-encoder rerank、HyDE 和零 key GGUF 路径不属于当前 builtin 实现。`docs/concepts/memory-qmd.md:9-14`、`docs/concepts/memory-builtin.md:120-159`、`src/commands/doctor/shared/legacy-config-migrations.runtime.retired-memory-qmd.ts:132-190`。

## 谱系定位与系统边界

### 入口与组件边界

当前 memory 能力由插件槽和通用 SDK 组合，而不是由 Agent 代码硬编码某一个数据库。插件 registry 只允许 memory kind 的插件注册 memory capability；选中的 capability 可以提供 runtime、prompt builder、flush plan、public artifacts，另有 corpus supplement 作为 Wiki 等附加检索域。内置 `memory-core` 注册 `memory_search`、`memory_get`、`intent`、memory runtime、flush plan 和 dreaming；`memory-wiki` 注册 Wiki 工具、prompt supplement/preparation、corpus supplement；`memory-lancedb` 是可替换的另一种 memory plugin，不与 `memory-core` 同时拥有同一个 memory slot。`src/plugins/registry-registrars-memory.ts:6-87`、`src/plugins/memory-state.ts:40-123,125-259`、`extensions/memory-core/index.ts:228-285`、`extensions/memory-wiki/index.ts:160-223`。

内置 manager 的取得入口是 `getMemorySearchManager`。registry/runtime bridge 先按 `plugins.slots.memory` 解析当前插件，再以 agent、workspace、搜索配置、provider identity 和 purpose 组成 manager cache key；默认请求复用常驻 manager，status/CLI 请求使用 transient purpose。manager 创建后打开该 agent 的 SQLite 数据库，初始化 schema、watcher、session listener 和同步状态。插件关闭时会等待正在进行的 manager operation、同步、provider 初始化/退休和 watcher 清理。`src/plugins/memory-runtime.ts:78-195,248-274`、`extensions/memory-core/src/memory/search-manager.ts:31-75`、`extensions/memory-core/src/memory/manager.ts:136-193,205-281,567-704`。

这条边界把三类对象分开：

- **事实源**：工作区 `MEMORY.md`、`USER.md`、`memory/` 下的 Markdown、显式 `extraPaths`，以及可选的 session transcript corpus；它们可由人或受权限控制的 Agent 写入。
- **派生检索资产**：每 agent 的 `openclaw-agent.sqlite` 中的 source/file 状态、chunks、FTS5 表、可选 sqlite-vec 表、Embedding cache、索引 metadata 和 provenance 表；这些由 manager 重建，不是模型可直接修改的文本事实源。
- **认知维护资产**：memory-core plugin state 中的短期召回、阶段信号、session ingestion checkpoint、来源 lineage、忘却 tombstone 和 dreaming backup；`DREAMS.md`/phase reports 是面向人的审阅或报告面，不是普通检索 corpus 的默认替代品。

### 与普通上下文机制的界线

Agent 的 system prompt 会列出 skills 和工具，但 skill 名单、工具目录和固定提示词本身没有检索事实对象，也不会产生候选。因此本笔记不把它们称为 RAG。真正属于本类目的 prompt 变化有四种：memory-core 的 `Memory Recall` 工具指导、Bootstrap 文件内容、Active Memory 的检索结果前缀，以及 memory-wiki 的 compiled digest/工具结果。默认 legacy prompt assembly 会准备 memory prompt；有 active context engine 时，`attempt-system-prompt-prepare` 会关闭基础 memory section，把 memory prompt 组装责任交给该 context engine。`src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:230-240,314-324`、`extensions/memory-core/src/memory-tool-contract.ts:105-127`。

## 事实对象、摄取与索引

### Markdown 记忆与额外路径

内置 source `memory` 读取真实的根 `MEMORY.md`、`USER.md` 和 `memory/` 目录中的 Markdown。根 `USER.md` 是可选的；legacy `memory.md` 和 repair 目录不进入普通扫描。`extraPaths` 可是工作区相对/绝对路径或带 root-relative glob 的目录项，目录递归扫描，默认跳过 symlink；默认 memory roots 保持 Markdown-only。开启 multimodal 后，只有额外路径中的受支持图片/音频才会生成结构化 Embedding input，文件大小、MIME 和内容 hash 均在建立 entry 时重新核对。`packages/memory-host-sdk/src/host/internal.ts:206-304,306-390,393-460`、`src/memory/root-memory-files.ts:41-77`。

Markdown 在索引前按估算 token 字符预算切块，默认目标 400 tokens、80 tokens overlap；`MEMORY.md` 与 `USER.md` 按 curated entry 边界切块，使一条带 `trigger`、`importance`、`project` 注释的条目不会在后续 fragment 丢失其注释范围。普通 Markdown 使用正文切块；session transcript 使用 reset boundary 和 line map 切块，最后把扁平化内容的行号映射回原始 transcript 行。`src/agents/memory-search.ts:119-137,296-364`、`packages/memory-host-sdk/src/host/internal.ts:477-508,511-661`、`extensions/memory-core/src/memory/manager-embedding-ops.ts:1129-1191`。

每个 chunk 的主键包含 source、路径、行范围、chunk hash 和当前 model。数据库的 canonical 表包括：

| 表/派生对象 | 内容 | 生命周期 |
| --- | --- | --- |
| `memory_index_sources` | 每个 source/path 的 hash、mtime、size 和整数 source identity | 文件/会话状态与脏检查；删除或路径消失时清理。 |
| `memory_index_chunks` | chunk 文本、行范围、hash、model、序列化 embedding 和更新时间 | 从当前 source 重建或增量替换。 |
| `memory_index_chunks_fts` | 正文 FTS5/BM25 派生行 | schema/tokenizer 变化时重建。 |
| `memory_index_paths_fts` | 路径和 source 的独立全文索引 | 支持精确路径、basename/stem 和 partial path 优先级。 |
| `memory_index_chunks_vec` | 可选 sqlite-vec KNN 虚表 | sqlite-vec 不可用时退回进程内 cosine；缺失/不完整时要求重建。 |
| `memory_index_chunk_recall_metadata` | importance、trigger phrases、project key | 从 curated entry 注释读取；缺失值保持 NULL 中性。 |
| `memory_index_chunk_provenance` | origin class、session kind、observed time、supersession key | 由分类器/摄取器写入，独立于 chunk 正文。 |
| `memory_embedding_cache` | provider/model/provider key/hash 对应的 chunk embedding | 可复用 unchanged chunk；按更新时间受上限裁剪。 |
| `memory_index_meta` 与 `memory_index_state` | provider/index identity、source/scope/chunking/tokenizer 以及 revision | 用来判断索引能否安全复用和发布。 |

schema 初始化由 `ensureMemoryIndexSchema` 完成：它确保严格表、FTS/path-FTS、触发器、revision、recall metadata 和 provenance；老结构只在迁移阶段复制到 canonical 表，随后由当前同步链重建失效 derived rows。`packages/memory-host-sdk/src/host/memory-schema-base.ts:5-61`、`packages/memory-host-sdk/src/host/memory-schema.ts:593-702`、`packages/memory-host-sdk/src/host/memory-schema-fts.ts:136-259`。

### Embedding provider 与索引 identity

`memory.search.provider` 默认解析为 `openai`；provider adapter 由 memory embedding registry 提供，当前源码和文档覆盖 OpenAI、Gemini、Voyage、Mistral、Bedrock、DeepInfra、Ollama、LM Studio、GitHub Copilot、local llama.cpp 和 OpenAI-compatible 等路径。配置可指定 model、remote endpoint、query/document input type、输出维度、批处理和 fallback。provider adapter 的 transport、model、cache key data 和 alias 一起参与 index identity；改变 provider、model、provider settings、sources、scope、chunking 或 tokenizer 后，已有 SQLite vector index 会变为 mismatched，而不是盲目当作兼容。`src/agents/memory-search.ts:188-215,282-398,421-454`、`extensions/memory-core/src/memory/embeddings.ts:38-73,106-120,136-175`、`extensions/memory-core/src/memory/manager-reindex-state.ts:10-24,39-73,136-232`。

搜索时的 provider requirement 有三种：显式 `provider: "none"` 是 FTS-only；未明确 provider、legacy `auto` 或 local transport 允许先以关键词模式启动；其他显式 provider 在不可用时应保持可见的 unavailable 状态，避免把已有语义索引悄悄重建成 FTS-only。一次 provider operation 有独立超时和最多三次 retry；Embedding batch 有 token、文件/请求上限，可在 provider batch 失败后转非 batch，并记录批次失败状态。主 provider 失败时，若配置了单一 fallback，manager 可退休当前 provider、创建 fallback 并按新 identity 重新验证/重建。`extensions/memory-core/src/memory/manager-provider-lifecycle.ts:41-107,180-239,278-359,418-466`、`extensions/memory-core/src/memory/manager-provider-state.ts:185-220`、`extensions/memory-core/src/memory/manager-embedding-ops.ts:81-103,273-311,572-690,823-883`。

### 摄取、监听与重建

manager 在启动、首次搜索、文件变化、session transcript 更新或 CLI force index 时同步。常驻 manager 对 `MEMORY.md`、`USER.md`、`memory/` 和合规的 extra paths 建立 native watcher；Windows/macOS 使用递归 `fs.watch`，Linux 使用目录树 watcher，native watcher 失败再落到 chokidar。事件先进入 watch-settle 队列，按 size/mtime 重查，默认 debounce 为 1500ms；文件仍在变化时不会把不稳定快照直接索引。大型目录会产生 watcher pressure 诊断，watcher 出错不会让 Gateway 崩溃，而是标脏并转降级 watcher/后续同步。`extensions/memory-core/src/memory/manager-watch-ops.ts:106-227,229-265,272-417,749-789`、`extensions/memory-core/src/memory/watch-settle.ts:17-98`。

增量同步先枚举当前合规文件并对比 source hash，删除 stale path；变化文件读取后切块，先从 SQLite embedding cache 按 provider identity/hash 复用向量，再按 batch 或普通并发请求缺失向量。正文、recall metadata、provenance、FTS、vector row、cache 和 source row 在一次短的 SQLite commit section 中替换。提交前会重新读取工作区文件 hash，防止把正在写入的快照发布为索引；session source 还会在提交前检查忘却 tombstone。`extensions/memory-core/src/memory/manager-source-sync-ops.ts:46-136`、`extensions/memory-core/src/memory/manager-embedding-cache.ts:16-120`、`extensions/memory-core/src/memory/manager-embedding-ops.ts:885-1079`。

完整重建走 shadow database：在共享 agent DB 外生成临时数据库，复制可用 embedding cache，重建配置 source，写入新的 meta，随后在 workspace lock、reindex lock 和旧 revision fence 下以短事务发布 memory-owned tables。发布前/后会检查 revision；中途失败保留旧 index 可用并设置 full-retry dirty，清理老的 shadow database/sidecar。故“force index”是可恢复的派生资产重建，不是复制或删除 canonical memory 内容。`extensions/memory-core/src/memory/manager-sync-ops.ts:501-677`、`extensions/memory-core/src/memory/manager-db.ts:139-256,258-337`。

## 查询、候选与重排主链

### `memory_search` 的入口与 corpus 选择

模型可见的 `memory_search` 参数是 query、可选 maxResults/minScore 和受限 corpus 枚举 `memory`、`wiki`、`all`、`sessions`。工具构造时通过当前 config 和 session agent 解析 source contract；执行时再次读取 live config，配置已失效会变成 revocation，而不是继续使用旧 captured context。模型只能请求 schema 中的 corpus，真正的 session corpus 还要由 trusted runtime 的 `conversationRecall` 或启用的 session source 授权；任意未知 corpus 会 fail closed，不能借参数把 recall-only transcripts 扩成普通搜索。`extensions/memory-core/src/memory-tool-contract.ts:11-45,66-99`、`extensions/memory-core/src/tools.shared.ts:53-78`、`extensions/memory-core/src/tools.ts:83-101,272-316`。

memory-core 工具执行时，普通 memory 查询与已注册的 Wiki corpus supplement 可以并发运行：`corpus=memory` 只保留 `source=memory`，`corpus=sessions` 只保留 session hits，`corpus=wiki` 只访问 Wiki supplement，`corpus=all` 才合并两类结果并为两个 corpus 各留出初始配额。各 backend 先保持自己的 ranked stream；最终按 score head merge，`all` 模式用近似均衡的 per-corpus cap，再填充余量。Wiki 不是 memory-core manager 的内部表，而是通过 `registerMemoryCorpusSupplement` 接入的独立事实域。`extensions/memory-core/src/tools.ts:165-228,330-392,465-525`、`extensions/memory-core/src/memory-corpus.ts:129-199`。

### 内置候选生成

manager 的 `search` 主链先规范化 query，必要时同步空 index 或 dirty source，然后解析 source filter 和候选窗口。默认 query 配置为最多 6 个返回结果、最低 score 0.35、hybrid 开启、vector/text 权重默认 0.7/0.3、候选倍率 4；有 active project 时扩大候选窗口至最多 200，再在最终阶段按原 minScore/maxResults 收敛。`extensions/memory-core/src/memory/manager-search-orchestration.ts:52-72,74-145,179-237`、`src/agents/memory-search.ts:119-137,301-322`。

候选路由如下：

1. **关键词路。** query 被提取为 FTS tokens；语言停用词和低价值请求词被移除，CJK 由 unicode61/trigram 策略处理。正文 FTS5 使用 BM25 rank 转为 bounded score；路径 FTS 单独处理完整路径、basename、stem 和 partial path。长对话 query 会在上限内补充最多 6 个有意义关键词 probe，避免“之前讨论的那个方案”完全没有 lexical candidate。`packages/memory-host-sdk/src/host/query-expansion.ts:636-776`、`extensions/memory-core/src/memory/manager-keyword-retrieval.ts:237-343`、`extensions/memory-core/src/memory/manager-search.ts:653-769,771-1075`。
2. **向量路。** query 以 `inputType: "query"` 请求 Embedding；sqlite-vec 可用时以 KNN overfetch，候选倍数为 8，单次 K 上限为 4096；KNN 受 model/source filter 后若可能漏掉合规行，则扩大窗口或退回有界的分批 cosine 扫描。sqlite-vec 不可用时仍可使用进程内 cosine，逐批让出 event loop 并响应 AbortSignal。`extensions/memory-core/src/memory/manager-search.ts:444-558,560-651`。
3. **混合合并。** vector 与 keyword 以 chunk id 去重，保留两路 component scores；正文命中优先于 path-only score，multimodal 只有向量信号。混合 content score 进入时效衰减、importance multiplier、project ranking 和 MMR。`extensions/memory-core/src/memory/hybrid.ts:16-29,87-239`、`extensions/memory-core/src/memory/manager-search-orchestration.ts:386-401`。

这是一种相似度/关键词候选管线，不是 learned cross-encoder rerank。当前 MMR 是本地 Jaccard/text similarity 的确定性多样性排序，默认 lambda 0.7；它只重新排列候选，不调用模型、不改变阈值，也不制造下一阶段 query。重要性为 1-10 时乘以 0.75 + N×0.05，NULL 保持中性；默认开启的时效衰减只针对带日期的 `memory/YYYY-MM-DD*.md`，根 `MEMORY.md`、`USER.md` 和其他 evergreen path 不衰减，默认 half-life 30 days。`extensions/memory-core/src/memory/mmr.ts:19-29,51-134`、`extensions/memory-core/src/memory/importance.ts:1-19`、`extensions/memory-core/src/memory/temporal-decay.ts:10-35,72-167`。

### 项目亲和度与去重

Agent 在准备 embedded session 时解析当前 Git repository 的 `remote.origin.url`，以稳定 repository key 标记最多四个最近活跃项目；没有 origin 时退回 canonical root path。写入 repository-specific memory 时，prompt 会要求把 `<!-- project: ... -->` 放在同一行。搜索会轻微提升 active project 的条目、降低其他项目条目；无效 annotation 被过滤。项目标记不会把文件物理分区，但会改变 ranking、项目 bootstrap 和 trigger eligibility。`src/agents/project-memory-scope.ts:6-59`、`src/agents/embedded-agent-runner/session-prompt-state.ts:13-26,68-86`、`src/agents/project-memory-bootstrap.ts:65-119,122-159`、`extensions/memory-core/src/memory/project-ranking.ts:11-52`。

混合搜索以 chunk id 合并同一命中；最终结果携带 path、startLine、endLine、score、vectorScore/textScore、snippet、source，以及可用的 importance/triggers/projectKey/provenance。结果中的 exact path specificity 是路径 precedence 的内部排序事实，最终公共结果不暴露内部 tier。MMR 通过 snippet token 的 Jaccard overlap 选择下一项，结果仍保留原始 component score。`packages/memory-host-sdk/src/host/types.ts:18-49`、`extensions/memory-core/src/memory/hybrid.ts:242-318`。

## 阶段、反馈与结果注入

### 被动 Bootstrap 与项目块

Bootstrap 不是对全 corpus 的相似度检索。它读取固定 workspace bootstrap files，并按每文件/总字符预算裁剪；memory-core 额外通过选中 memory runtime 的 provenance classifier 判断 `MEMORY.md`、`USER.md` 是否允许自动注入。`owner`/`agent` provenance 才有资格；`untrusted`/`system` 会从自动 context 移除。根文件还受 direct/shared session 的 bootstrap session filter 约束，相关 hook 不能把被保护的 root memory 重新加回来。`src/agents/bootstrap-files.ts:237-290,292-371`、`packages/memory-host-sdk/src/host/types.ts:38-49`。

有项目 active set 时，embedded runner 会另取最多 48 个 curated project candidates，仅接受带 active project key、具可信 provenance、且来自 `MEMORY.md` 的条目，格式化成最多 2000 字符的 `Project Memory` 块。该块是按项目身份的受限即时注入，不是跨项目知识图，也不改变 canonical file。`src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:249-268`、`src/agents/project-memory-bootstrap.ts:15-16,65-154`。

### Active Memory 两条 recall lane

`active-memory` 是当前实现中最接近“检索驱动认知编排”的组件，但它的阶段边界需要精确描述。

**Lane 1 是无模型的即时触发召回。** `before_prompt_build` 只在有 turn tool authority、user trigger、eligible interactive persistent session 时进入；它并行执行一次 memory manager 的 lexical-only search（最多 24 个候选）和 `listTriggerCandidates`，不发送 query embedding 或网络请求。候选必须来自 `source=memory`、可信自动注入 provenance、curated root，并满足项目 key 全部 active；trigger phrase 与当前消息打分后最多取 3 条，组合为受限的 hidden `Context: <active_memory_plugin>` 前缀。`extensions/active-memory/trigger-recall.ts:11-19,59-124,127-185,222-237`。

**Lane 2 是有条件的记忆子 Agent。** 默认 `mode=escalate` 时，只有消息包含过去/之前/记得/决定等 recall intent 且 Lane 1 没有 strong hit，才启动阻塞子 Agent；`always` 在所有 targeted eligible turns 启动，`off` 只关闭 deep lane，不关闭 Lane 1。子 Agent 的 prompt 明确要求使用 bounded search query，只使用 configured memory tools，返回 `NONE` 或一条不超过 `maxSummaryChars` 的纯文本摘要，不直接回答用户。queryMode 可为 latest message、有限 recent tail 或 full conversation；搜索 query 会去除 Active Memory/XML、JSON fence、external untrusted block 和既有 recall 噪声，并限制为最多 480 字符。`extensions/active-memory/escalation.ts:48-72`、`extensions/active-memory/query.ts:19-83,86-163`、`extensions/active-memory/prompt.ts:66-136`。

子 Agent 通过 `runEmbeddedAgent` 形成额外模型回合，但它只获得 `toolsAllow` 中的记忆工具；默认 builtin 为 `memory_search`/`memory_get`，LanceDB 为 `memory_recall`，配置值会过滤 wildcard、group entry 和普通 core tools。若使用 `rememberAcrossConversations`，trusted runtime 把 `conversationRecall` 限定为 same-agent-private，并可强制只用 session corpus。子 Agent 输出经 transcript/tool-result evidence 检查，只有“确实有可用 memory result + 非空摘要”才成为 `ok`；不可用、空、失败或未确认的文本不会注入主回复。`extensions/active-memory/types.ts:30-89,231-280`、`extensions/active-memory/config.ts:96-133,204-283`、`extensions/active-memory/recall-run.ts:251-313,336-361`、`extensions/active-memory/transcript-result.ts:240-265`。

因此可确认的反馈是“Lane 1 是否命中”影响是否启动 Lane 2，以及 Lane 2 的工具结果影响是否生成摘要；没有确认“第一阶段命中向量的均值成为第二阶段向量”“关系路径递进检索”或“上一轮候选自动重写下一自然语言 query”。Active Memory 属于**有条件的工具化 deep recall 与上下文编排**，是检索驱动认知编排的部分实现，不是 VCPToolBox 式固定多阶段认知链。

### 结果注入与引用契约

memory-core 的 `memory_search` 返回 JSON 结果，不自动把结果直接塞进主 prompt；模型需要先看到工具结果，再决定是否调用 `memory_get`。工具说明要求在回答历史工作、决定、日期、人物、偏好或 todo 前先 search，低置信度时说明已检查。`memory_get` 只读指定的相对 path 和 bounded line range，返回 `status=ok`/`not_found`、text、from/lines/nextFrom/truncated 等契约。`extensions/memory-core/src/memory-tool-contract.ts:80-99`、`packages/memory-host-sdk/src/host/types.ts:100-122`。

内置 search 会在结果显示层按 `memory.citations` 的 `auto`/`on`/`off` 处理 `Source: path#Lx-Ly`；无论是否显示 citation，内部结果仍保留 path/行范围。注释载体（trigger、importance、project）在 snippet 进入模型前剥离，避免把控制 metadata 当作记忆内容。`extensions/memory-core/src/tools.ts:417-462`、`extensions/memory-core/src/tools.citations.ts`、`extensions/memory-core/src/memory/manager-embedding-ops.ts:1143-1186`。

Active Memory 的 hidden prefix 是 `before_prompt_build` hook 返回的 `prependContext`，由 runner 与其他 hook context 合并后进入该次模型输入，而不是写进普通用户 transcript；它随后会在 query 清洗时被识别并去除，防止 recall-loop。Active Memory 可在 session entry 的 pluginDebugEntries 中持久化 status/debug 摘要，默认子 Agent transcript rows 在运行结束清理。`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts:154-187`、`extensions/active-memory/index.ts:236-326,431-531`、`extensions/active-memory/session.ts:175-196,276-346`。

### Memory Wiki 作为资产型检索域

`memory-wiki` 不是普通 memory manager 的另一个 FTS 表。它维护 vault 下的 `sources/`、`entities/`、`concepts/`、`syntheses/`、`reports/` 等 Markdown 页面，页面包含 frontmatter、claims、evidence、privacy tier、freshness、contradictions 和 relationships。导入 source 时写 source page 和 append-only log，再编译相关页面、索引页、dashboard、backlinks 和 compiled cache；编译在 vault mutation lock 内执行，并以 vault generation、publication id、snapshot hash 和 source generation 验证后发布到 plugin BlobStore。`extensions/memory-wiki/src/vault.ts:23-34,107-186`、`extensions/memory-wiki/src/ingest.ts:68-158`、`extensions/memory-wiki/src/compile.ts:63-72,1224-1400`、`extensions/memory-wiki/src/compiled-cache.ts:15-19,220-367,409-465`。

Wiki 查询按页面/claim 的 title、path、id、metadata、正文、claim confidence/status/freshness 和显式 search mode 评分；支持 `auto`、`find-person`、`route-question`、`source-evidence`、`raw-claim`，结果可携带 matched claim、evidence kinds/source IDs、privacy、provenance 和 updatedAt。它可以按 `wiki_search` → `wiki_get` 由模型继续精读，也可以在 `memory_search corpus=wiki/all` 中作为 supplement 被动合并。Wiki 的关系和 claims 改变当前页面候选与解释，不会在已确认的路径中生成固定下一阶段查询。`extensions/memory-wiki/src/query.ts:113-158,424-467,719-787,836-898,1195-1351`、`extensions/memory-wiki/src/tool.ts:145-192,269-320`、`extensions/memory-wiki/src/corpus-supplement.ts:6-55`。

Wiki 还有可选的 compiled digest prompt：最多 4 个高信号页面，每页最多 2 个 claims，总 prompt 约 2800 字符，按 contradiction/open questions/claim count、confidence 和 freshness 选取。这是知识资产的摘要注入，不是 query-time semantic recall，也不应单独计为认知链。`extensions/memory-wiki/src/prompt-section.ts:12-24,70-124,191-207`。

## 记忆写回与主动维护

### 会话内写回与 pre-compaction flush

当前内置 memory 的主要 canonical writer 仍是 Markdown 文件，而不是向量表。模型通过普通写工具把重要事实追加到 `memory/YYYY-MM-DD.md`；memory-core 的 flush plan 在上下文接近 compaction threshold 时要求“只写当天文件、只 append、不要覆盖 `MEMORY.md`/`DREAMS.md`/其他 bootstrap 文件”，并允许 silent reply。`extensions/memory-core/src/flush-plan.ts:13-44,98-148`。

主 Agent runner 在 compaction 前按 token、上次 output、当前 prompt 估计和可选 transcript byte fuse 判断是否需要 flush；CLI/native-compaction/heartbeat/incognito 或 sandbox workspace 非 rw 时跳过。flush 失败最多记录到 session state 并继续用户主回合，避免记忆维护吞掉答复；这条路径不是检索算法，但它决定 episodic source 是否产生。`src/auto-reply/reply/memory-flush.ts:17-59,146-201`、`src/auto-reply/reply/agent-runner-memory.ts:714-1073,1085-1144`。

写工具边界会观察 workspace memory mutation：owner turn 默认记录为 `agent`，sender 明确非 owner 或当前 turn 已被 network result taint 时记录为 `untrusted`；写入 provenance 先落库，文件提交失败会尝试回滚记录。memory path classifier 对 workspace 内 Markdown 默认按 agent/已记录 provenance 分类，对 workspace 外 extra path、DREAMS/dreaming 目录或无法 realpath 的对象采用更严格的非自动注入分类。`src/agents/agent-tools.ts:521-531`、`src/agents/memory-write-provenance.ts:11-78,101-161`、`extensions/memory-core/src/memory/memory-path-provenance.ts:16-64`。

### Session corpus 与短期召回

`memory.search.sources` 默认是 `memory`；`experimental.sessionMemory` 或 `rememberAcrossConversations` 才会启用 session source。session corpus 可来自当前 SQLite transcript identity、保留的 reset/delete transcript artifact 和 active session；工具查询会把它们映射为 `sessions/...` identity，按 session visibility 和 conversation recall 授权后才展示。session source 的索引更新由 transcript event listener、startup catch-up、5 秒 debounce 和 targeted queue 驱动；active session 的 transcript 可以在 SQLite 中直接读取，archive artifact 仍是文件输入。`src/agents/memory-search.ts:200-215,263-271,343-371`、`packages/memory-host-sdk/src/host/session-transcript-corpus.ts:25-53,200-275,316-459`、`extensions/memory-core/src/memory/manager-session-sync-ops.ts:47-99,128-257`。

会话 transcript 的 provenance 按消息来源分类：owner user message、owner turn 的 assistant-derived 内容、system/internal message、外部/不明来源分别进入闭合集合 `owner`/`agent`/`system`/`untrusted`。工具输出、network-sourced result 或非 owner participant 可使后续 assistant 消息 turn tainted。自动 session ingestion 只从 interactive live corpus 提取 bounded snippets 到 `memory/.dreams/session-corpus/<day>.txt`；cron、heartbeat、subagent、dream narrative、system-only 内容和 foreign archive 不进入可晋级的 canonical dreaming candidate，foreign JSONL 即使自带 ownership fields 也被强制标成 untrusted。`packages/memory-host-sdk/src/host/session-provenance.ts:4-24`、`extensions/memory-core/src/session-ingestion.ts:111-150,176-210,263-403`、`extensions/memory-core/src/memory/manager-session-sync-state.ts:17-37`。

每次 `memory_search` 成功得到 memory hits 时，若 dreaming 开启，工具会异步把 query、hit、score 和时间写入短期 recall store；这一写回不阻塞工具结果，并成为后续 dreaming 的 ranking evidence。短期状态本身保留在 plugin state，含 retention、seen hashes、phase signals 和 promotion markers，不等于将工具结果自动写成长期事实。`extensions/memory-core/src/tools.ts:422-447`、`extensions/memory-core/src/short-term-promotion-record.ts`、`extensions/memory-core/src/short-term-promotion-store.ts:25-57,148-183`。

### Dreaming：主动记忆演化闭环

当前 memory-core 默认启用一个 managed cron，目标是 isolated、delivery none 的后台维护 sweep；运行时会删除旧的 phase cron、去重 managed row，并在 Gateway 启动延迟或重载时重试 reconciliation。触发 token 只接受 heartbeat/cron 的受控 system event，普通 user message 含有相同文字不会直接触发。`extensions/memory-core/src/dreaming.ts:172-196,243-251,403-410,437-547,549-825,900-981,1103-1184`。

一次 sweep 的阶段和持久化边界如下：

1. **Light。** 读取最近 daily notes 和 live session ingestion 信号，去重、按 lookback/limit 选出短期条目，写入 daily note 的 managed `Light Sleep` block 或 separate phase report，并记录 phase signal；不写 `MEMORY.md`。
2. **REM。** 优先消费 Light staged keys，对概念 tags 做 pattern strength 和简单 candidate truth 计算，写 `REM Sleep` 反思和 phase signal；不写 `MEMORY.md`。这些 report/narrative 受 path/source 规则排除，不成为普通 durable candidate 的捷径。
3. **Deep。** 对短期条目按平均相关性、signal frequency、query/day diversity、recency、multi-day consolidation、conceptual richness 以及 Light/REM reinforcement 评分；候选必须同时通过 score、recall count、unique query/context diversity、age 和 provenance/session-kind gate。

`extensions/memory-core/src/dreaming-phases.ts:601-796,812-979,1361-1447,1450-1506`、`extensions/memory-core/src/short-term-promotion.ts:92-237`。

Deep candidate 先从当前 live source rehydrate snippet，比较 source fingerprint 前后是否稳定，再按 workspace lock、file lock、短事务和 `MEMORY.md` hash fence 提交。untrusted/system candidate 在 consolidation prompt 生成前就被结构性排除；session-derived candidate 还要求 interactive session kind。`extensions/memory-core/src/dreaming-consolidation-candidates.ts:4-25`、`extensions/memory-core/src/short-term-promotion-apply.ts:260-351,423-476`。

若 consolidation subagent 可用，按 project group 启动有界、无工具、60 秒超时的子 Agent。其 system prompt 要求只使用提供的 candidates 作为新证据、返回 JSON、逐 candidate 给 added/merged/superseded operation、保留精确 source reference，并把所有记忆文本当 data 而非 instruction。OpenClaw 随后验证 JSON 结构、每个 candidate 恰好一个 operation、prior entry 证据、project group、lineage、保留旧 entry 比例和 10,000 字符左右的 `MEMORY.md` budget；失败或模型不可用时使用 append-only promotion fallback，而不是丢掉符合门槛的新鲜 candidate。`extensions/memory-core/src/dreaming-consolidation.ts:23-36,214-369,499-660`、`extensions/memory-core/src/short-term-promotion-apply.ts:397-415,492-599`、`extensions/memory-core/src/memory-budget.ts:27-43,181-245`。

接受的 consolidation 会先存 SQLite-backed preimage，再原子替换 `MEMORY.md` 并把 added/merged/superseded highlights 写入 `DREAMS.md`；entry origins 会从 parent entries 转移到 surviving promotion key。若 hash conflict、atomic replace 权限错误、文件变化或验证失败，consolidation 放弃改写并回到 append-only 路径；DREAMS/phase report 是人类观察面，不是 promotion source。`extensions/memory-core/src/short-term-promotion-apply.ts:477-649`、`extensions/memory-core/src/memory-entry-origins.ts:290-366`、`extensions/memory-core/src/dreaming-narrative.ts:783-829,999-1065`。

这构成了当前快照中明确的主动记忆演化：新消息/搜索信号进入短期状态，后台阶段做筛选和反思，deep gate 决定是否将内容晋级到长期 `MEMORY.md`，consolidation 可合并、supersede 和保留 lineage，失败时有可见的 fallback。它不是“dreaming 模型自己自由改写所有记忆”：模型被限制在候选和 operation 契约内，且 untrusted/system 无法靠高 recall count 晋级。

## 预算、作用域、可观测与恢复

### 预算和性能边界

| 环节 | 当前源码可确认的边界 |
| --- | --- |
| 普通 memory query | 默认最终 maxResults 6、minScore 0.35；hybrid candidate multiplier 4，内部候选上限 200。 |
| keyword fallback | 额外 FTS probe 最多 6 个关键词；snippet 最大约 700 字符；CJK tokenizer 可选 unicode61/trigram。 |
| vector query | sqlite-vec KNN overfetch factor 8、K 上限 4096；无 vec index 时分批 256 行扫描并让出 event loop。 |
| trigger recall | 候选窗口 24，strong match 注入最多 3 条，总 trigger context 约 1800 字符；lane-1 lexical-only，不发送 query embedding。 |
| Active Memory | query 最多 480 字符；默认 recall work 15 秒，setup grace 默认 0，preflight/post-settlement 各有独立约 1500ms 级边界；summary 默认最多 220 字符；recent tail 和每条 user/assistant 字符数均有上限。 |
| memory_get | path、from、lines 为正整数，返回 bounded excerpt 和 continuation metadata；具体最大读取由 memory host contract/调用层控制。 |
| Embedding | query/batch 有 provider-owned timeout，普通 batch 8,000 token 预算；最多 3 次 embedding retry，批次可拆分，source-wide batch 最多 2048 files/50,000 requests。 |
| Wiki | prompt digest 最多 4 页、每页 2 claims、总约 2,800 字符；页面查询用有限 candidate path/页面并发读取。 |
| dreaming | short-term/session ingestion 有每文件/每 sweep 上限；deep promotion、snippet token、prior entry loss fraction、consolidation 60 秒和 narrative 60 秒均有边界。 |

默认 memory manager cache 是按 agent/config/provider identity 的进程内 lifecycle cache；Embedding cache 是 SQLite 持久派生数据，键含 provider/model/provider key/hash。Active Memory 另有最多 1000 项、默认 TTL 15 秒的进程内摘要 cache，但 private `conversationRecall` 不复用 cached private summary；相同 run 会以 run registry 合并并避免重复启动。`extensions/active-memory/recall-state.ts:20-27,95-176,179-227`、`extensions/memory-core/src/memory/manager-embedding-cache.ts:39-60,63-98`。

### 作用域、权限与不可信内容

内置 memory 的文件作用域首先是 agent workspace 和 agent SQLite DB；不同 agent 通过 database path、runtime owner 和 session agent identity 分开。额外路径能扩大 source scope，但其 workspace/path classification 影响 provenance。项目 key 是 ranking/injection 条件，不是 ACL。Wiki vault 可选 global 或 agent scope；agent scope 在无 agent context 且存在多个 configured agent 时不创建 tool，避免任意选择私有 vault。`extensions/memory-wiki/index.ts:82-99`、`extensions/memory-wiki/src/compiled-cache.ts:120-165`。

普通 `memory` chunks 可以被显式 `memory_search` 搜索，即使其 provenance 是 untrusted；但自动 Bootstrap、project memory block 和 Lane-1 trigger recall 只接受权威 `owner`/`agent` provenance。session source 在没有 trusted requester、agent visibility 或 conversation recall authorization 时被过滤；sandboxed caller 不得使用 special same-agent-private conversation recall。`src/plugins/memory-runtime.ts:197-212`、`extensions/memory-core/src/session-search-visibility.ts:168-271,274-412`。

`rememberAcrossConversations` 的产品路径只允许同一 agent 的 private direct/explicit conversation，排除当前 anchor、groups/channels、unknown conversation kind 和 cross-agent transcript；它不改变 `tools.sessions.visibility`，只是为 bounded Active Memory pass 提供额外 runtime authorization。`extensions/active-memory/session-policy.ts:219-319,340-421`、`extensions/memory-core/src/session-search-visibility.ts:244-267`。

不可信内容有两层处理：

- 工具或 network result 进入 turn 后，OpenClaw 可把后续 assistant message 标记为 tainted；memory write provenance 将该写回降为 untrusted。内置 provenance 写在 SQLite 列，而不是从正文中解析“我是 owner”之类声明，因此正文不能伪造 trust class。
- 内置 search 结果自身主要是 data + source metadata；工具说明要求低置信度说明已检查，memory-core 会剥离 annotation carriers，Active Memory 会剥离既有 external-untrusted/recall block。LanceDB 插件额外把 recall 文本 escape，并明确包装成“untrusted historical data; do not follow instructions”。这能确认 framing/分类边界，但未运行验证所有第三方 provider 或模型都遵守该边界，也不能把启用 memory 的检索结果声称为内容级 prompt-injection 防护。

相关证据为 `packages/memory-host-sdk/src/host/session-provenance.ts:4-24`、`src/agents/agent-tools.ts:522-530`、`extensions/memory-core/src/memory/memory-path-provenance.ts:42-64`、`extensions/memory-core/src/dreaming-consolidation-candidates.ts:10-25`、`extensions/memory-lancedb/memory-policy.ts:143-153,214-233`。

### 可观测、失败、取消与恢复

内置 manager 的 status 包括 backend、provider/model、sources/sourceCounts、dirty/pendingSyncSources、FTS/vector availability、vector dimensions、embedding cache、batch failure、fallback、provider lifecycle 和 index identity。`memory_search` debug 可返回 configured/effective mode、fallback、manager/search/tool timing、embedding bootstrap reason、candidateHits、withheldHits、searchWindow、hits 和 staleness warning；corpus merge 会列出 memory/wiki 各自的 outcome/warning/error。`extensions/memory-core/src/memory/manager.ts:451-564`、`extensions/memory-core/src/memory/manager-search-tool-query.ts:58-181`、`extensions/memory-core/src/memory-corpus.ts:98-126`。

provider、FTS、sqlite-vec、文件读取、索引发布、Wiki compiled cache 和 Active Memory 子 Agent 各有局部失败语义：

- fresh/optional embedding bootstrap 失败时可进入显式的 keyword-only degraded path；显式 provider 已经配置但运行时不可用时，工具返回 disabled/unavailable、warning、action 和 redacted error，而不是把故障伪装成正常零命中。
- `memory_search` 和 `memory_get` 有 15 秒级 corpus deadline，调用方 AbortSignal 会传播；manager 遇到 closed database 会 refresh manager 后重试一次。session-only sync 可以后台进行，让已有搜索继续返回，并标记 pending/stale。
- Active Memory timeout 会 abort 子 Agent、保存有限 partial transcript data；若所有候选都是 unavailable，partial summary 不会注入。连续超时达到阈值后 circuit breaker 在冷却期跳过 recall；超时后 manager cleanup 仍被调度，避免下一次复用仍在关闭的 provider/DB。
- full reindex 使用 shadow publish + revision fence，失败保留旧 index 并设置 retry；watcher/native watcher 失败转 fallback 或后续重同步。provider replacement 会等待 active uses 归零，跨 plugin reload 的 provider retirement 也保留在 process-global lifecycle 中。

`extensions/memory-core/src/memory/memory-corpus.ts:35-96`、`extensions/memory-core/src/memory/manager-search-tool-query.ts:108-181`、`extensions/active-memory/recall.ts:177-225,315-351,414-476`、`extensions/active-memory/recall-state.ts:72-136`、`extensions/memory-core/src/memory/manager-sync-ops.ts:299-371,501-677`。

取消的语义是“停止等待/向下传播 abort，并把未完成工作留在其生命周期清理路径”，不是把已开始的外部 provider 请求强制恢复成可回滚事务。后台 watch、session sync、dreaming cron 和 detached narrative 可能继续以 bounded best-effort 完成或记录失败；Active Memory 的 temporary subagent rows 最终清理，若 `persistTranscripts=true` 才把 bounded transcript artifact 保存到 agent sessions 的独立目录。`extensions/active-memory/recall-run.ts:184-215,341-423`、`extensions/active-memory/recall.ts:239-255,315-351,472-476`。

memory-core 的 session ingestion checkpoint、seen message hashes、short-term recall/phase state、entry origins、forget tombstones 和 dreaming preimage 通过 plugin state/agent SQLite 持久化；运行中的 Promise、watcher、circuit breaker 和 Active Memory result cache 不跨进程恢复。Wiki 用 vault log、vault generation 和 BlobStore publication 恢复已验证 compiled snapshot；失败 lifecycle refresh 会先撤销旧 active owner，避免 stale compiled cache 继续注入。`extensions/memory-core/src/dreaming-state.ts:9-18,50-177`、`extensions/memory-core/src/session-ingestion.ts:417-476`、`extensions/memory-wiki/src/compiled-cache.ts:242-340`。

## 与相邻谱系的可比与不可比边界

### 可比范围

- 与传统相似度召回实现可比较：Markdown/session 事实对象、400/80 默认切块、FTS5/BM25 与 Embedding 双路、候选窗口、source filter、时效/importance/project ranking、MMR、path/line citation 和 embedding/index cache。
- 与知识资产管线可比较：extra paths、agent SQLite 派生索引、memory-wiki 的 source → page → claim/evidence → compiled publication、可编辑/可删除对象、source generation、异步/增量/force rebuild 和 status/diagnostic 面。
- 与工具化检索可比较：模型发现并调用 `memory_search`、`memory_get`、`wiki_search`、`wiki_get`，结果携带 source/line/claim/provenance，模型可根据前一工具结果再执行精读。该循环的决策主体通常是模型，而不是检索组件内置的查询规划器。
- 与上下文即时注入可比较：curated Bootstrap、项目记忆块、trusted trigger recall、Active Memory summary 和 compiled Wiki digest 都会改变本轮模型输入，但它们的激活条件、来源可信度和预算不同。
- 与主动记忆演化可比较：short-term recall evidence、light/REM/deep phase、promotion threshold、consolidation、supersession、preimage、DREAMS review surface 和 background schedule。

### 不可比范围

- 不把普通 skills、`tools` 目录、静态 tool description、memory prompt guidance 或固定 bootstrap file 名称当作 RAG；这些对象没有 query/candidate/source lifecycle。
- 不把 `memory_get` 单独称为检索算法。它是命中后的 bounded exact read，负责把候选摘要还原成所需行区段。
- 不把 Active Memory 的一次额外 subagent turn 直接等同于 VCPToolBox 的多阶段认知链。当前已确认的是“条件门控 + 记忆工具回合 + compact summary”，未确认固定的命中向量反馈、关系传播、阶段状态图或多阶段自然语言 query planner。
- 不把 memory-wiki 的 claims、relationships、freshness、contradiction dashboards 或 route-question mode 直接称为“推理 RAG”。它们提高知识资产的结构化查询和解释能力，输出仍是当前页面/claim 候选或精确页面内容。
- 不把 `sessions_search` 和 memory semantic search 混为同一路径：前者是 session transcript 的 SQLite FTS exact search，后者是可选 session corpus 的 semantic/hybrid memory source。`docs/concepts/session-search.md:11-43`。
- 不把 Lobe/外部 memory plugin 的文档或 `memory-lancedb` 的 `dreaming` 配置字段外推为 builtin dreaming 语义。当前 builtin 的 dreaming 由 memory-core 自己注册和调度；LanceDB 当前源码确认的是 auto-capture、auto-recall、memory_store/recall/forget，未在其 plugin 代码中找到等价的后台 consolidation loop。`extensions/memory-lancedb/index.ts:89-116,545-667`。

## 设计取舍与已确认边界

1. **写入和检索分离。** OpenClaw 把 canonical memory 留在可编辑 Markdown，把向量/FTS/metadata 当可重建派生物；provider/model/scope 变化会暂停不兼容 vector search 并要求显式重建。这牺牲了“索引永远即时”的假设，换来可检查、可迁移和不因派生表损坏而丢失原文。
2. **低成本 recall 与高成本 recall 分层。** 普通 `memory_search` 没有 query-time LLM rerank；Lane 1 用 lexical-only trigger prefilter，只有明确 recall intent 且无 strong hit 才支付 Active Memory 子 Agent 回合。这里的“阶段”是请求路径和成本门控，不是固定向量认知链。
3. **信任优先于分数。** provenance 是 SQLite-owned closed metadata，自动注入和 promotion 都在 score 之前受资格门控。高相似度、频繁召回或模型摘要不能让 untrusted/system 内容直接进入 curated memory。
4. **可见的降级优先于静默空结果。** 工具结果区分 empty、not found、stale、unavailable、disabled 和 fallback；embedding bootstrap、FTS、vector store、batch、corpus supplement 和 Active Memory debug 都保留诊断路径。未运行验证这些字段在每个具体 provider/channel UI 中是否完整呈现。
5. **后台维护受限而非自由反思。** dreaming 有明确 cron、短期 evidence、阶段信号、阈值、候选来源、模型操作契约、hash fence、preimage 和 append-only fallback；DREAMS.md 是 review/narrative surface，不能反过来作为长期记忆来源。
6. **作用域有多层，不是单一 ACL。** agent DB/workspace、source/corpus、session visibility、same-agent-private recall、sandbox 和 Wiki vault scope 分别承担不同边界；project key 只做 affinity/eligibility。静态代码可确认这些判断点，不能替代多 agent、共享 workspace、archive alias 和恶意内容的运行对抗测试。

## 未验证事项

- 未启动 Gateway 或真实 user-facing persistent chat，未确认当前配置下 `before_prompt_build`、memory-core prompt builder、Active Memory hidden prefix、Wiki prompt preparation 与 context engine 的最终顺序和模型所见字节。
- 未调用真实 Embedding provider、sqlite-vec、FTS5、batch API、local llama.cpp、provider fallback 或实际模型，未验证召回质量、混合分数与真实 token/延迟/成本。
- 未建立真实 Markdown、extraPaths、CJK/trigram、multimodal、session transcript 和跨 reset/delete archive corpus，未验证 watcher、line map、source hash、partial vector rows 与 force rebuild 的端到端结果。
- 未进行 session visibility、DM scope、same-agent-private、sandbox、cross-agent、shared workspace、Wiki global/agent scope 的权限对抗测试；代码中的 fail-closed 分支不等于已运行证明。
- 未验证 network tool result 的全链路 taint declaration coverage，也未验证任意第三方 memory plugin 的结果 framing 能否阻止模型把 recalled text 当指令。
- 未验证 `memory_search corpus=all` 同时有 memory、wiki、sessions 时的真实候选平衡、重复结果、warning/error 展示和模型后续工具选择。
- 未运行 Active Memory 的 lane-1 strong hit、escalate、always、off、timeout partial、circuit breaker、terminal unavailable、provider missing、CLI-backend recall 和 transcript cleanup 场景。
- 未运行 memory-lancedb 的 LanceDB schema/agent predicate、auto-recall/auto-capture、provider retirement、prompt-injection rejection 和 timeout cooldown；也未确认其可选 `dreaming` 配置在当前快照是否有实际消费者。
- 未运行 dreaming cron、light/REM/deep、consolidation model、model-unavailable fallback、MEMORY.md external edit conflict、promotion source deletion、forget race、DREAMS.md publication 和 Gateway restart 恢复；因此阶段输出与恢复结论均为源码事实/静态推断，不是运行事实。
- 未找到统一离线 recall benchmark、A/B、跨项目质量评测或可用于声称效果优劣的真实生产指标。本次测试文件只能支持局部分支、schema、预算和失败契约的静态/夹具证据。

## 关键源码索引

- `extensions/memory-core/index.ts:228-377`：内置 memory plugin 注册 capability、`memory_search`/`memory_get`、intent、flush plan、session backfill 和 dreaming。
- `src/plugins/memory-runtime.ts:78-212`、`src/plugins/memory-state.ts:40-259`：memory slot/runtime owner、manager adapter、hit authorization、prompt/corpus supplement registry。
- `src/agents/memory-search.ts:28-115,200-454`：provider、source、extra path、chunk、query、hybrid、MMR、cache 和 session memory 配置解析。
- `extensions/memory-core/src/memory/manager.ts:80-193,205-285,451-564,567-704`：per-agent SQLite manager、生命周期、状态和关闭。
- `extensions/memory-core/src/memory/manager-search-orchestration.ts:52-72,74-237,247-401`：搜索入口、bootstrap sync、FTS/vector/hybrid 主链。
- `extensions/memory-core/src/memory/manager-keyword-retrieval.ts:74-212,237-343`：关键词候选、path search、fallback terms、metadata 和 keyword-only finalize。
- `extensions/memory-core/src/memory/manager-search.ts:444-558,560-769`：sqlite-vec KNN、cosine fallback、FTS/BM25 和 bounded scan。
- `extensions/memory-core/src/memory/hybrid.ts:87-239,242-318`、`extensions/memory-core/src/memory/mmr.ts:19-29,51-166`：路合并、时效/importance/project 处理和 MMR。
- `packages/memory-host-sdk/src/host/internal.ts:206-390,511-661`：memory 文件枚举、extra paths、multimodal entry、Markdown chunk 和行映射基础。
- `packages/memory-host-sdk/src/host/memory-schema.ts:593-702`、`packages/memory-host-sdk/src/host/memory-schema-base.ts:5-61`：canonical SQLite、FTS、vector/cache、provenance schema。
- `extensions/memory-core/src/tools.ts:272-541`、`extensions/memory-core/src/memory-tool-contract.ts:23-127`：`memory_search` corpus 参数、manager query、Wiki supplement merge、citation 和 tool contract。
- `extensions/memory-core/src/memory-search-tool-query.ts:58-181`、`extensions/memory-core/src/memory-corpus.ts:52-199`：source/visibility post-filter、manager refresh、deadline 和多 corpus outcome。
- `extensions/active-memory/index.ts:236-551`：Active Memory hook 的 authority、session/chat eligibility、Lane 1/Lane 2、prependContext 和 cleanup。
- `extensions/active-memory/trigger-recall.ts:59-124,147-237`：trusted trigger candidate、lexical-only recall、项目资格和最多三条注入。
- `extensions/active-memory/escalation.ts:48-72`、`extensions/active-memory/query.ts:19-163`、`extensions/active-memory/prompt.ts:66-136`：recall intent、query shaping、模型子 Agent prompt 契约。
- `extensions/active-memory/recall.ts:116-228,239-476`、`extensions/active-memory/recall-run.ts:142-161,251-361,362-423`：模型/缓存/circuit breaker、bounded subagent、工具 evidence、timeout 和 transcript 生命周期。
- `extensions/memory-core/src/session-search-visibility.ts:168-412`、`packages/memory-host-sdk/src/host/session-transcript-corpus.ts:316-459`：session corpus 的 agent/session/private/archive visibility。
- `extensions/memory-core/src/session-ingestion.ts:111-210,263-403,417-518`：session provenance、admission policy、bounded ingestion、`.dreams/session-corpus`。
- `extensions/memory-core/src/short-term-promotion.ts:92-237`、`extensions/memory-core/src/short-term-promotion-apply.ts:239-351,423-692`：短期 recall scoring、source rehydrate、promotion、lock、budget 和 origin reconciliation。
- `extensions/memory-core/src/dreaming.ts:549-825,900-1184`、`extensions/memory-core/src/dreaming-phases.ts:1337-1506`：managed cron、light/REM/deep 阶段入口、后台触发和阶段报告。
- `extensions/memory-core/src/dreaming-consolidation.ts:23-36,214-369,396-660`：consolidation prompt、JSON operation、loss/budget/source validation、模型失败 fallback。
- `extensions/memory-core/src/dreaming-state.ts:9-177`、`extensions/memory-core/src/dreaming-narrative.ts:783-829,999-1139`：SQLite-backed dreaming state、DREAMS diary、narrative cleanup 和 detached bounded concurrency。
- `extensions/memory-wiki/index.ts:77-239`、`extensions/memory-wiki/src/ingest.ts:68-158`、`extensions/memory-wiki/src/compile.ts:1224-1447`：Wiki vault 注册、source ingest、编译、dashboard 和 publication。
- `extensions/memory-wiki/src/query.ts:113-158,719-787,836-898,1195-1491`、`extensions/memory-wiki/src/prompt-section.ts:70-207`：Wiki claims/page search、search modes、shared memory corpus、compiled digest prompt。
- `extensions/memory-lancedb/index.ts:89-116,210-337,340-541,545-667`、`extensions/memory-lancedb/auto-recall.ts:38-147`：可替换 LanceDB provider、memory_recall/store/forget、auto recall/capture 和 timeout。
- `docs/concepts/memory-architecture.md:11-64,127-265,363-392`、`docs/concepts/memory-search.md:65-165`、`docs/concepts/dreaming.md:31-95`：当前文档对 memory tier、hybrid recall、provenance、dreaming 的设计自述；实现判断以源码为准。
- `docs/concepts/memory-qmd.md:9-14`、`src/commands/doctor/shared/legacy-config-migrations.runtime.retired-memory-qmd.ts:132-230`：QMD backend 已移除及旧配置迁移边界。
