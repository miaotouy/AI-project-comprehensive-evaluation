# Codex 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：只读静态阅读当前快照的 memories 读写 crate、`core` 记忆与上下文注入、AGENTS.md 发现、压缩流水线、MCP 客户端与工具元数据检索；沿“会话启动 → 记忆抽取 → 全局合并 → 摘要注入 → 工具/Shell 查询 → 引用回写”追踪。未运行真实记忆流水线或模型请求。
>
> 调查范围：记忆事实源、摄取与合并、读路径工具、摘要注入、AGENTS.md 指令注入、上下文压缩、MCP/网页搜索等外部检索边界、预算与可观测性；不覆盖外部 MCP Server 自身的索引实现、ChatGPT 后端检索服务、桌面端渲染器。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的检索相关能力由“文件化记忆 + 模型驱动的工具/Shell 查询 + 启动时后台记忆演化”三部分构成，全程不依赖向量 RAG。当前快照中：

- **没有 Embedding、向量库或本地语义索引**。按 embedding、vector store、faiss、lance、qdrant、bm25、rerank 等关键词做全仓检索，唯一命中的是 `tool_search` 对延迟加载的工具元数据所做的 BM25 排序，知识语料索引没有命中（`codex-rs/core/src/tools/handlers/tool_search.rs:14-17`）。
- **记忆事实源是 `$CODEX_HOME` 下 memories 或 memories_v2 目录中的 Markdown 工件**：原始 rollout 事件另存为同级的 sessions 目录下的 JSONL，由摘要文件引用，数据库里没有对应的向量块；两套目录由 `memories.version` 配置决定（`codex-rs/protocol/src/memory_version.rs:17-22`）。
- **写入由会话侧主动发起**：根会话带输入的新回合成功提交后，经后台条件检查触发 Phase 1，按 rollout 逐个抽取，随后执行 Phase 2 全局合并；实际合并由一个受限子代理完成（`codex-rs/memories/write/src/start.rs:24-95`；`codex-rs/memories/write/src/phase2.rs:81-207`）。
- **读取以记忆工具和 Shell 命令为主**：会话默认先注入压缩后的 `memory_summary.md`，模型再用搜索、读取、列举三个记忆工具或普通 Shell 命令打开 `MEMORY.md`、rollout 摘要目录和技能目录（`codex-rs/ext/memories/src/extension.rs:56-104、137-161`；`codex-rs/ext/memories/templates/memories/read_path.md:19-49`）。
- **检索本身是子串匹配，没有打分、候选融合或重排**；结果按路径和行号排序，最多 200 条，用游标翻页（`codex-rs/ext/memories/src/local/search.rs:17-88`）。
- **AGENTS.md 属于确定性上下文注入**，走独立于检索链路的注入通道：按项目根到当前目录逐级拼接，受 32 KiB 默认预算限制（`codex-rs/core/src/agents_md.rs:1-18、68-116`；`codex-rs/config/src/config_toml.rs:77`）。
- **上下文压缩是预算管理**，会生成摘要并替换历史，但不查询外部知识（`codex-rs/core/src/compact.rs:117-150、403-416`）。

谱系定位如下：

| 谱系 | 状态 | 判断依据 |
|---|---|---|
| 相似度召回 | **不存在** | 未找到 Embedding、向量表、KNN 或语义相似度实现；记忆搜索是精确子串 |
| 知识资产管线 | **部分实现，源码事实** | 有 rollout 到 Markdown 工件的合并与 git 基线，但没有切块、Embedding、索引发布和多租户知识库 |
| 工具化检索 | **主链确认，源码事实** | `memories.search/read/list`、Shell 读取、MCP 工具、网页搜索工具 |
| 上下文即时注入 | **主链确认，源码事实** | 记忆摘要作为 developer policy 注入；AGENTS.md 作为 user 上下文片段注入 |
| 检索驱动认知编排 | **不成立** | 读路径没有由检索结果改写下一轮查询的内置协议；Phase 1/2 是后台记忆维护，不是查询规划 |
| 主动记忆演化 | **主链确认，源码事实** | 启动时后台抽取与合并、显式 remember/forget 写入 ad-hoc note、引用使用量回写 |

## 谱系定位与系统边界

Codex 把“记忆”实现为一组可编辑的本地工件，而不是一个独立的检索服务。系统边界可以分成三层：

1. **事实源与工件层**：`$CODEX_HOME` 下的 memories（V1）或 memories_v2（V2）目录，全部记忆工件都存放于此：
   - 记忆文件：MEMORY.md、memory_summary.md、raw_memories.md；
   - 子目录：rollout_summaries/、skills/、extensions/ad_hoc/notes/。
2. **派生状态层**：state DB 中的 Phase 1 任务、租约、stage-1 输出、Phase 2 选择与水位；它记录“哪些 rollout 已抽取、哪些被合并、使用量多少”，不保存向量。
3. **注入与访问层**：会话启动时注入摘要和工具说明；模型通过工具或 Shell 读取文件；最终回答中的引用块被解析并回写使用量。

这个边界决定了它不能按“RAG 服务”来比较。它没有查询编码器、候选召回器、reranker 或向量索引；它的“检索质量”主要取决于模型是否选择正确的关键词、是否打开正确的 rollout 摘要，以及 `MEMORY.md` 是否维护得足够清晰。

## 事实对象、摄取与索引

### 事实对象

| 对象 | 形态 | 生命周期 |
|---|---|---|
| rollout | 会话事件流，state DB 记录路径、cwd、分支、时间 | 受年龄、空闲时长、来源和租约过滤 |
| stage-1 输出 | `raw_memory`、`rollout_summary`、可选 `rollout_slug` | 抽取成功后写回 state DB；有保留期和清理 |
| `MEMORY.md` | 面向模型的记忆注册表 | 由 Phase 2 子代理维护 |
| `memory_summary.md` | 压缩后的稳定摘要 | 注入 developer prompt；文件为空则不注入 |
| `raw_memories.md` | 合并后的原始记忆 | V1 由 Phase 2 重建；V2 不再生成该文件 |
| `rollout_summaries/` | 每个 rollout 一份摘要文件 | 随 Phase 2 选择集同步、增删 |
| `skills/` | 可复用的技能目录 | 由合并代理维护，不是普通检索索引 |
| ad-hoc note | 用户显式要求记住/忘记/修正时写入的小 Markdown | 追加式，等待下一次合并消费 |

这些对象都可直接编辑或删除，除了 state DB 中的任务记录之外没有不可变的索引结构。V1/V2 目录名和差异见 `codex-rs/protocol/src/memory_version.rs:17-22` 与 `codex-rs/memories/README.md:96-137`。

### 摄取与索引

Phase 1 的输入是 state DB 中“可抽取”的 rollout，不是工作区文件的实时扫描。筛选条件包括允许的交互式会话来源、年龄窗口、空闲时长、是否已被其他 worker 租用，以及单次启动的扫描/领取上限（`codex-rs/memories/README.md:40-63`）。实现上，它先领取任务，再按并发上限并行处理：

- 领取上限默认每次启动 2 个 rollout，扫描上限 5000，租约 3600 秒，并发 8（`codex-rs/config/src/types.rs:57-62`；`codex-rs/memories/write/src/lib.rs:85-88`）。
- 每个 rollout 被裁剪为记忆相关响应项，送入抽取模型，要求结构化输出 `raw_memory`、`rollout_summary` 和可选 `rollout_slug`（`codex-rs/memories/write/src/phase1.rs:54-83、199-250`）。
- 输出在写入前经过 secret 脱敏（`codex-rs/memories/write/src/phase1.rs:423`）。
- 失败任务按退避重试，成功但无内容记为 `succeeded_no_output`（`codex-rs/memories/README.md:71-77`）。

模型选择优先使用 `memories.extract_model`，否则使用当前 Provider 的 `memory_extraction_preferred_model`（`codex-rs/memories/write/src/phase1.rs:161-169`；`codex-rs/model-provider/src/provider.rs:150-155`）。

Phase 1 没有切块、Embedding 或索引构建。它把一次 rollout 压成一条结构化记忆记录；所谓“索引”只是 state DB 的行和随后生成的 Markdown 文件。

另有一个指向 `memories/trace_summarize` 的一元摘要客户端，用于把原始 trace 交给服务端摘要；当前快照中除自身单测外没有调用点，实际记忆抽取仍由 Phase 1 子代理完成（`codex-rs/codex-api/src/endpoint/memories.rs:32-58`；`codex-rs/core/src/client.rs:852-899`）。

## 查询、候选与重排主链

### 查询入口

读路径有两种入口，二者都由模型决定何时查询：

1. **专用工具**：把 `memories.dedicated_tools` 设为 true、并同时开启记忆 feature 与 use_memories 开关后，扩展会注册搜索、读取、列举和追加笔记四个记忆工具（`codex-rs/ext/memories/src/extension.rs:137-161`；`codex-rs/ext/memories/src/lib.rs:13-22`）。
2. **普通 Shell**：V1 提示词直接要求用关键词搜索 `MEMORY.md`，只在命中指针时打开 1-2 个 rollout 摘要或 skill；V2 提示词也允许在需要的路径缺失时做选择性搜索（`codex-rs/ext/memories/templates/memories/read_path.md:33-49`；`read_path_v2.md:7-10`）。

`dedicated_tools` 默认是 `false`，所以默认路径更依赖 Shell 和提示词；专用工具是显式开启后的替代面（`codex-rs/config/src/types.rs:388-390`）。

### 候选生成与排序

`memories.search` 接收一个或多个查询串，支持三种匹配模式：

- 任一词命中；
- 所有词在同一行；
- 所有词在指定行窗口内。

默认大小写敏感，可选分隔符归一化；结果按路径、匹配行号排序，不计算相关性分数。单次最多 200 条，返回 `next_cursor` 和 `truncated` 支持翻页（`codex-rs/ext/memories/src/tools/search.rs:28-42、102-117`；`codex-rs/ext/memories/src/local/search.rs:17-88`）。

`memories.read` 按行偏移读取，默认上限 20,000 tokens；`memories.list` 默认和上限都是 2,000 条（`codex-rs/ext/memories/src/lib.rs:13-16`；`codex-rs/ext/memories/src/local/read.rs:38-49`）。

这里没有候选融合、同义词扩展、向量召回、reranker 或多样性控制。所谓“重排”不存在，结果顺序由路径字典序和行号决定。

### 结果契约

搜索命中携带相对路径、匹配行号、内容起始行号、内容和实际命中的查询词（`codex-rs/ext/memories/src/backend.rs:127-133`）。读结果携带内容、截断标记和行范围。最终结果作为工具输出进入会话，不会自动改写下一轮查询。

模型被要求在使用了 rollout 摘要时，在最终回答末尾附加一个 `<oai-mem-citation>` 块，列出文件、行范围和用途，并尽可能附带 rollout UUID（`codex-rs/ext/memories/templates/memories/read_path.md:75-115`）。该块对用户不可见，由 core 解析后回写使用量（`codex-rs/core/src/stream_events_utils.rs:136-154、185-205`）。

## 阶段、反馈与结果注入

### 写入阶段

Phase 2 是串行的全局合并，流程如下：

1. 取得记忆工作区文件锁和全局 Phase 2 租约，避免并发合并；以下六步都在 `codex-rs/memories/write/src/phase2.rs:67-225` 内完成。
2. 准备 `~/.codex` 下的记忆根目录及其 git 基线。
3. 从 state DB 选取最多 `max_raw_memories_for_consolidation` 条 stage-1 输出：默认先按使用次数、再按最近使用或生成时间排序，超过 `max_unused_days` 未使用的记忆被排除（`codex-rs/memories/README.md:87-95`）。
4. 同步 rollout_summaries/ 和 V1 的 raw_memories.md，清理过期扩展资源。
5. 用 git 工作区差异判断有无实际变化；无变化且工件有效时直接成功退出。
6. 有变化时把 diff 写入工作区、生成合并提示，启动受限的合并子代理。

合并子代理以固定配置运行：不做审批，MCP、协作工具与记忆工具本身全部禁用。默认受管沙箱下，它只能写记忆根且没有网络；父会话使用外部隔离或显式关闭沙箱时，它继承父级的文件与网络权限（`codex-rs/memories/write/src/phase2.rs:318-357`）。合并模型来自 `memories.consolidation_model` 或 Provider 的默认合并模型（`codex-rs/model-provider/src/provider.rs:157-162`）。子代理读取工作区 diff 文件 phase2_workspace_diff.md，据此更新 MEMORY.md、memory_summary.md 和 skills/ 目录。

### 读路径注入

读路径的固定注入是 `memory_summary.md`：

- 文件不存在或为空则不注入；
- 内容按 2,500 tokens 截断；
- 作为 developer policy 片段进入提示，而不是 user 消息；
- V2 模式下再把结果按每段最多 8,900 字节切分，避免单片段超限。

实现见 `codex-rs/ext/memories/src/prompts.rs:31-63` 与 `codex-rs/ext/memories/src/extension.rs:70-103`。记忆内容的固定注入只有这段摘要：没有按查询动态挑选条目，也没有为每个问题重新检索摘要。

### 反馈

读路径的反馈只有间接两种：

- 模型可以按提示词“再跑一次快速记忆检查”，但这是模型行为，不是系统强制的查询改写；
- 引用块被解析后，会更新 stage-1 输出的使用次数和最近使用时间，进而影响下一次 Phase 2 的选择排序（`codex-rs/core/src/stream_events_utils.rs:200-205`；`codex-rs/memories/README.md:124-131`）。

这不是“检索结果改变下一轮查询”的认知编排。系统没有阶段化查询向量、关系路径传播或自动生成的后续问题。

## 记忆写回与主动维护

主动维护分两条路径：

- **后台流水线**：根会话带输入的新回合成功提交后，主环境已配置时会调用 `start_memories_startup_task`；会话需为非 ephemeral、记忆 feature 已开启且当前为根代理，后台任务还需通过 state DB、目录布局与速率限制检查，随后依次跑 Phase 1 和 Phase 2。入口与后台检查见 `codex-rs/app-server/src/request_processors/turn_processor.rs:742-754`、`codex-rs/memories/write/src/start.rs:24-95`。
- **显式用户请求**：用户要求记住、忘记或修正时，模型只能调用 `memories.add_ad_hoc_note` 往 extensions/ad_hoc/notes/ 目录追加一条 Markdown 笔记，生成的记忆文件仍由合并代理维护；这条笔记留给下一次合并消费（`codex-rs/ext/memories/src/tools/ad_hoc_note.rs:50-86`；`codex-rs/ext/memories/src/local/ad_hoc_note.rs:12-17`）。

写回不需要管理员审批。合并子代理本身以 `AskForApproval::Never` 运行；默认受管沙箱下依靠关闭网络、清空 MCP 和只写记忆根来限制影响面，而不是逐条审批。父会话显式关闭沙箱或自带外部隔离时，这层沙箱约束随父级权限放宽（`codex-rs/memories/write/src/phase2.rs:328-357`）。

文档与实现存在差异：`memories/README.md:29-38` 写的是“根会话启动时触发”，而当前可执行入口是 app-server 在带输入的新回合成功提交后调用（`turn_processor.rs:742-754`）。两者描述的是同一后台流水线，但触发时机的精确语义以代码为准。

## AGENTS.md 与确定性上下文注入

AGENTS.md 不属于记忆检索，但它决定了模型在每次会话中看到哪些项目规则，因此作为“上下文即时注入”单独记录。

发现规则：

- 从当前工作目录向上找项目根，默认标记是 `.git`；找不到标记时只考虑当前目录。
- 从项目根到当前目录逐级收集，顺序为由外到内拼接，不越过项目根。
- 每个目录优先 AGENTS.override.md，其次 AGENTS.md，再其次配置的 fallback 文件名。
- `$CODEX_HOME` 下的全局 AGENTS.override.md 与 AGENTS.md 作为 user 级指令另行加载（`codex-rs/codex-home/src/instructions/mod.rs:40-84`）。
- 未信任项目直接跳过项目文档，只保留 host 提供的用户指令；上述发现、收集与文件优先级规则实现在 `codex-rs/core/src/agents_md.rs:10-296`。

预算与注入：

- 总预算默认 32 KiB，配置项 `project_doc_max_bytes` 可以改这个上限；读取按目录逐层进行，每读一层扣减剩余字节，余额不足即停止（`codex-rs/config/src/config_toml.rs:77、337-338`；`codex-rs/core/src/agents_md.rs:68-95`）。
- 线程级额外指令另有 10,000 估算 token 上限（`codex-rs/core/src/agents_md_manager.rs:187-196`）。
- 最终内容转成 user 角色的上下文片段；内容变化时以“替换此前所有 AGENTS.md 指令”的提示整体替换已有片段，不重复追加（`codex-rs/core/src/agents_md.rs:473-486`；`codex-rs/core/src/context/world_state/agents_md.rs:11-80`）。

因此 AGENTS.md 只做规则注入：候选生成、历史检索和记忆维护分别由检索链路与 memory 工具链承担。

## 上下文压缩：相邻但不同的问题

压缩处理的是“上下文超预算”，与“从外部资料找答案”属于两类问题。主链是：

1. 每个回合结束后读取当前 token 状态，计算自动压缩的作用域和上限（`codex-rs/core/src/session/context_window.rs:58-109`）。
2. 达到阈值或模型仍需后续回合时，触发内联压缩；完整上下文窗口是独立硬上限（`codex-rs/core/src/session/turn.rs:632-720`）。
3. 压缩任务用 SUMMARIZATION_PROMPT 或配置的 compact_prompt 请求模型生成摘要。
4. 摘要加上固定的 SUMMARY_PREFIX，替换历史并保留真实用户消息；压缩项成为新的上下文边界（`codex-rs/core/src/compact.rs:117-150、404-417`）。
5. 若 Provider 声明支持远端压缩 V2，则改走 Provider 的压缩协议；否则走本地摘要实现（`codex-rs/core/src/tasks/compact.rs:63-93`；`codex-rs/model-provider-info/src/capabilities.rs:22-32`）。

这条链路不会查询 `MEMORY.md`、rollout 摘要或任何外部知识库。它产出的是当前对话的压缩摘要，与检索增强的候选生成、相关性排序无关。

## 外部工具检索与内置边界

### MCP

Codex 是 MCP 客户端，不实现 MCP Server 的索引。`mcp_servers` 配置定义传输、认证、启用状态、启动就绪模式、工具输入 schema 上限和暴露面（`codex-rs/config/src/mcp_types.rs:232-301`）。运行时通过 `tools/list` 发现工具、通过 `tools/call` 调用（`codex-rs/rmcp-client/src/rmcp_client.rs:736-752、983-1016`）。

因此，如果某个 MCP Server 提供知识库检索、代码索引或文档搜索，检索的索引、切块和打分都在该 Server 内部；本仓库只负责工具发现、调用和结果回注。本次未在本仓库找到内置的 MCP 检索索引实现。

MCP 资源另有两个工具面：列出资源和读取资源。它们读取 Server 暴露的资源，不建立本地索引。

### 网页搜索

网页搜索是 Responses 协议里的托管工具，不是本地爬虫或索引：

- `WebSearchMode` 分为 Cached、Indexed、Live、Disabled；
- Cached 只允许索引访问，Indexed 同时声明索引访问，Live 允许实时网页访问；
- 工具声明还携带内容类型、过滤器和上下文大小（`codex-rs/core/src/tools/hosted_spec.rs:14-46`）。

搜索的执行和索引归属在模型后端；本仓库只组装工具声明并处理返回的搜索事件。部分 Provider 还支持独立的 `web.run` 工具面，但那同样是外部执行（`codex-rs/core/src/tools/spec_plan.rs:1692-1713`）。

当前快照还给搜索加了一层**提供者仲裁**：每一步只允许一个搜索提供者生效，候选是宿主 MCP 搜索、原生 Responses 搜索或不启用。同一线程里已有占用者时，另一种提供者拿不到备用名额；冲突时工具声明会被直接摘掉，避免同一步同时暴露两种搜索入口（`codex-rs/core/src/model_search.rs:28-40`、`:104-141`）。

宿主可以通过配置层指定客户端搜索提供者，是否允许宿主独立授权 MCP 搜索由策略特性决定（`codex-rs/core/src/model_search.rs:182-202`）。回退事实写进响应项元数据，恢复历史时据此重建占用状态（`:147-170`）；同一回合混用两种提供者的次数单独计入遥测（`:42-70`）。

### 工具元数据检索

`tool_search` 使用 BM25 对“延迟加载的工具描述”排序，目的是让模型发现尚未暴露的工具。它检索的是工具 metadata，不是知识文档；结果会改变下一轮可用工具集，但不产生知识候选（`codex-rs/core/src/tools/handlers/tool_search.rs:14-17`；`codex-rs/core/src/tools/handlers/tool_search_spec.rs:94`）。

### 文件搜索

`codex-rs/file-search` 使用 nucleo 做模糊文件匹配，主要服务 TUI 的 `@` 提及和文件选择，不参与模型推理前的知识检索（`codex-rs/file-search/src/lib.rs:1-30`）。

综上，本仓库内置的“检索”只有：记忆文件的子串搜索、工具元数据的 BM25、以及确定性的文件/指令加载。知识库检索、代码语义索引和网页索引均不由本仓库实现。

## 预算、作用域、可观测与恢复

### 预算

| 维度 | 默认值 | 证据 |
|---|---|---|
| 每次启动抽取 rollout 数 | 2 | `codex-rs/config/src/types.rs:57` |
| 单次扫描上限 | 5,000 | `codex-rs/memories/write/src/lib.rs:88` |
| 抽取并发 | 8 | `codex-rs/memories/write/src/lib.rs:85` |
| 任务租约 | 3,600 秒 | `codex-rs/memories/write/src/lib.rs:86` |
| 合并输入上限 | 256 条 | `codex-rs/config/src/types.rs:61` |
| 记忆未使用淘汰 | 30 天 | `codex-rs/config/src/types.rs:62` |
| rollout 最大年龄 | 10 天 | `codex-rs/config/src/types.rs:58` |
| rollout 最小空闲 | 6 小时 | `codex-rs/config/src/types.rs:59` |
| 启动所需最低限流余量 | 25% | `codex-rs/config/src/types.rs:60` |
| 注入摘要上限 | 2,500 tokens | `codex-rs/ext/memories/src/lib.rs:16` |
| 搜索/列表/读取上限 | 200 / 2,000 / 20,000 tokens | `codex-rs/ext/memories/src/lib.rs:13-15` |

### 作用域与安全

- 记忆根固定在 `$CODEX_HOME` 下的版本目录，工具路径解析被限制在根内；符号链接被拒绝，隐藏路径被跳过（`codex-rs/ext/memories/src/local/search.rs:44-49、107-125`）。
- 合并子代理的 MCP 始终清空、审批固定为 Never；受管沙箱下它只获得记忆根的写权限且网络关闭，父级沙箱为 Disabled 或 External 时沿用父级权限（`codex-rs/memories/write/src/phase2.rs:328-357`）。
- 工具搜索、网页搜索和函数输出等外部上下文可以把线程标记为 `memory_mode = "polluted"`，从而影响后续是否使用记忆；这个行为由 `memories.disable_on_external_context` 控制（`codex-rs/core/src/stream_events_utils.rs:157-183`；`codex-rs/config/src/types.rs:330-332`）。
- 生成记忆前会脱敏 secret；但记忆文件本身是普通文本，若模型写入敏感信息，后续仍可被读取。这是实现边界，不是已确认的漏洞。

### 可观测性

- 每次记忆工具调用记录工具名、作用域、成功与否、是否截断等指标（`codex-rs/ext/memories/src/tools/search.rs:88-98`）。
- Phase 1/2 记录领取数、成功/失败、跳过原因、输入条数和端到端耗时。
- 引用块被解析后更新 stage-1 输出的使用次数和最近使用时间；Shell 读取记忆工件（注册表、摘要、原始记忆文件、rollout 摘要目录和技能目录）也会被归类为记忆使用（`codex-rs/memories/read/src/usage.rs:30-70`）。
- 本次未找到面向用户的“检索解释面板”或候选分数展示；可解释性主要来自引用块中的文件、行号和 note。

### 恢复语义

- Phase 1 用 state DB 租约和重试退避避免重复抽取；进程重启后未完成任务可由后续启动重新领取（`codex-rs/memories/README.md:65-77`）。
- Phase 2 用全局锁和租约串行化合并；工作区 git 基线用于计算 diff 和判断是否需要代理（`codex-rs/memories/write/src/phase2.rs:81-95、137-167`）。
- 合并成功后重置 git 基线；失败则保留工作区，下一次根据 diff 重试。
- 记忆版本切换（V1/V2）不会自动迁移既有文件；`dual_write` 只在 V1 选中时同时预热 V2（`codex-rs/memories/write/src/start.rs:44-50`）。

## 与相邻谱系的可比/不可比边界

| 比较对象 | 可比维度 | 不可比原因 |
|---|---|---|
| 传统向量 RAG | 事实源、注入预算、引用 | Codex 没有 Embedding 和向量召回，不能比较 recall@k 或语义相似度 |
| 知识库管线（Dify/Open WebUI） | 摄取、合并、发布、权限 | Codex 的记忆是单用户本地 Markdown，没有数据集、分段、索引任务和多租户权限 |
| 工具化检索（MCP/函数调用） | 查询入口、结果回注、工具契约 | Codex 的检索工具是文件子串搜索；外部 MCP 的索引不在本仓库 |
| Lorebook/记忆注入 | 发送前注入、预算、作用域 | Codex 注入的是压缩摘要，不按关键词激活条目 |
| 检索驱动认知编排（VCPToolBox） | 阶段、查询反馈、结构传播 | Codex 没有多阶段查询向量或由结果驱动的后续问题生成 |
| 主动记忆演化 | 后台触发、写回、审批 | Codex 有后台抽取/合并；本次未找到梦境式离线重组、遗忘审批或记忆关系图 |

## 未验证事项

- 未运行真实记忆流水线，未验证 Phase 1 抽取质量、Phase 2 合并质量、摘要注入对模型行为的实际影响。
- 未验证 `max_rollouts_per_startup`、限流余量、租约和重试在真实账号/真实 state DB 下的表现。
- 未验证 V1 与 V2 的实际差异，包括 V2 是否仍依赖 Shell 读取、`raw_memories.md` 缺失时模型的行为。
- 未验证 `disable_on_external_context` 对真实会话记忆可用性的影响，也未验证 `memory_mode = "polluted"` 的后续消费路径。
- 未验证 MCP Server 侧的知识库检索实现；本笔记只确认 Codex 侧的客户端与工具暴露。
- 未检查桌面端渲染器；当前快照没有对应源码，因此“无检索界面”只表示本次未找到。

## 关键源码索引

- `codex-rs/memories/README.md`：记忆流水线的阶段、工件和触发条件。
- `codex-rs/memories/write/src/start.rs`：启动任务、版本选择、限流检查。
- `codex-rs/memories/write/src/phase1.rs`：rollout 领取、抽取、脱敏、stage-1 写回。
- `codex-rs/memories/write/src/phase2.rs`：全局锁、选择、工作区同步、受限合并代理。
- `codex-rs/memories/write/src/prompts.rs`：合并提示与版本模板。
- `codex-rs/ext/memories/src/extension.rs`：摘要注入与工具注册。
- `codex-rs/ext/memories/src/prompts.rs`：`memory_summary.md` 截断与模板渲染。
- `codex-rs/ext/memories/templates/memories/read_path.md`：V1 读路径提示词。
- `codex-rs/ext/memories/templates/memories/read_path_v2.md`：V2 读路径提示词。
- `codex-rs/ext/memories/src/tools/`：`search`、`read`、`list`、`add_ad_hoc_note` 工具。
- `codex-rs/ext/memories/src/local/search.rs`：子串匹配、排序、游标。
- `codex-rs/memories/read/src/citations.rs`：记忆引用解析。
- `codex-rs/memories/read/src/usage.rs`：Shell 读取的记忆使用分类。
- `codex-rs/core/src/stream_events_utils.rs`：引用解析与使用量回写。
- `codex-rs/core/src/agents_md.rs`：AGENTS.md 发现、拼接、预算与上下文片段。
- `codex-rs/core/src/agents_md_manager.rs`：线程指令上限与缓存。
- `codex-rs/core/src/compact.rs`：压缩摘要生成与历史替换。
- `codex-rs/core/src/session/context_window.rs`：压缩触发预算。
- `codex-rs/core/src/tools/hosted_spec.rs`：托管网页搜索工具声明。
- `codex-rs/core/src/tools/handlers/tool_search.rs`：工具元数据 BM25 检索。
- `codex-rs/rmcp-client/src/rmcp_client.rs`：MCP 工具发现与调用。
