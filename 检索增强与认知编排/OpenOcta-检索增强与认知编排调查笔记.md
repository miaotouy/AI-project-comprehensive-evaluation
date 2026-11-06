# OpenOcta 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：通读 Go 侧知识库引擎、Vault 同步、检索工具、Gateway 处理器与 Eino 工具注册，结合 `docs/knowledge-vault.md`、`docs/embedded-models.md` 对照；并对 `embedding_model.txt` 与 `memory` 相关配置做引用检索。未运行 Gateway、索引构建或真实检索
>
> 调查范围：Vault 知识库的摄取、索引、查询、排序、结果注入、记忆注入与生命周期；运维对象查询工具只做边界区分，不展开其内部实现；不涉及 UI 视觉与通用聊天上下文裁剪
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的检索增强只有一个可用主链：把 Obsidian 兼容的 Markdown Vault 切块，写入 Bleve 全文索引，可选地再写一份向量到本地 JSON 文件；模型通过 `memory_search` 工具按需检索，结果以 JSON 数组回注到工具结果里，下一轮模型回合再消费。

它是“工具化检索 + 相似度召回”的组合，不是检索驱动的认知编排。一次查询只有一轮：Bleve 先取三倍于请求条数的候选，再用查询向量对候选做余弦加权重排，截断后返回。向量不参与候选生成，没有独立的向量召回通道、没有 reranker 模型、没有查询改写、没有结果反馈或第二阶段检索。

索引是“全量重建 + 手动触发”。进程启动时只打开或创建索引目录，不扫描 Vault；真正的扫描、切块、嵌入和索引替换由 `vault.sync` 完成，入口是知识库页的“同步索引”、保存笔记、创建笔记和修改 Vault 目录这几个 UI 动作。文档声称“Agent 启动时自动建索引”，与当前可执行路径不一致。

“第二大脑”式记忆由另一套机制承担：`evolution` 包把身份、系统提示、记忆和用户画像四份 Markdown 渲染成系统提示片段，属于发送前的上下文注入，不经过检索。本快照中它有增删改的存储 API，但没有暴露成模型工具，也没有从对话自动提取的后台任务。

`session_search` 是一个声明与实现脱节的能力：系统提示、知识库文档和 UI 工具策略都提到它，但全仓库没有注册同名工具，只有一段未被调用的会话历史打分函数。

运维对象查询（Prometheus 指标、日志、会话列表、浏览器）走 MCP 与内置工具，和知识库检索是两条独立的工具面；本笔记不把它们计入 RAG。

## 谱系定位与系统边界

| 谱系 | 本项目对应 | 证据状态 | 说明 |
| --- | --- | --- | --- |
| 相似度召回 | 有，但是“全文候选 + 向量重排”的混合打分 | 主链确认 | 向量只对 Bleve 命中项加权 |
| 知识资产管线 | 部分：单一 Vault、全量重建、无数据集与发布流程 | 主链确认 | 无权限模型、无增量索引、无版本 |
| 工具化检索 | 有：`memory_search(query, limit)` | 主链确认 | 由模型自行决定何时调用 |
| 上下文即时注入 | 有：Vault 检索规则与 evolution 记忆块进入系统提示 | 主链确认 | 注入的是规则和记忆文本，不是检索结果 |
| 检索驱动认知编排 | 本次未找到对应实现 | 关键词检索未命中 | 无多阶段、无查询反馈，依据见下文 |
| 主动记忆演化 | 本次未找到自动写回；存储层有增删改 API | 入口确认 | 无工具、无后台触发 |

系统边界可以概括为三层：

- **用户资产层**：Vault 目录里的 `.md` 文件，用户用编辑器或 Obsidian 维护；索引目录是派生数据。
- **索引层**：进程内共享的 Bleve 索引加两个 JSON 旁路文件（文档正文、向量），路径固定在状态目录下。
- **消费层**：Eino 工具与 Gateway 的 Vault 浏览/搜索接口，前者给模型，后者给 UI。

## 事实对象、摄取与索引

### 对象与存储

| 对象 | 结构 | 存储 | 可编辑性 |
| --- | --- | --- | --- |
| 文档块 | id、kind、title、text、meta（path、起止行） | `corpus.json` + Bleve 文档 | 由 Vault 派生，不可单独编辑 |
| 向量 | 文档 id 到 float32 数组 | `vectors.json` | 派生，无模型标识 |
| Bleve 文档 | 只索引 kind、title、text | `knowledge-index/bleve/` | 派生 |
| Vault 笔记 | 原始 Markdown | 用户目录 | 用户可编辑，是唯一事实源 |
| 会话历史命中 | 运行时的 `HistoryTurn` 切片 | 内存 | 仅用于未接线的 `SearchHistory` |

文档对象定义见 `src/pkg/agent/knowledge/doc.go:3-22`；kind 只有 `document` 与 `history` 两种，后者明确注明不进 Bleve（`kinds.go:4-7`）。

### 摄取与切块

同步遍历 Vault 的 Markdown 文件并跳过隐藏目录，标题优先取第一个一级标题。切块按整行累加 UTF-8 字节长度，达到 2400 阈值后停止，再回退两行形成重叠；长单行会整体越过阈值，所以它既非字符计数，也非每块硬上限（`src/pkg/agent/knowledge/vault_sync.go:119-149`）。

循环没有确保回退后起点前进：若非末块只消费一至两行，减去两行会回到原起点或更早位置。例如首行已达阈值且后面仍有行时，同一个起点会反复处理。该条件可从循环直接推出，未执行该输入验证；同步也因此可能停在切块阶段，尚未进入索引重建。

块 id 的构成是 `chunk:<相对路径>:<文件内容哈希前 8 位>:<序号>`（`vault_sync.go:75-89`）。这带来两个可观察后果：同一文件内容变化会改变 id，旧块不会被原地更新而是随整库替换消失；文件重命名同样产生全新 id。

摄取没有异步任务、队列或状态机。切块和嵌入都在同步调用里完成，重建期间无法查询。

### 索引重建

`Engine.Rebuild` 是破坏式重建：关闭并删除 Bleve 目录、重建索引映射、批量写入文档、替换 corpus、重置向量库，然后对全部文档调用一次嵌入（`src/pkg/agent/knowledge/engine.go:105-174`）。嵌入请求将整批文本放进单次请求，超时 120 秒；失败或返回数量不匹配时同步报错（`openai_compat_embed.go:31-81`）。此时全文索引和 corpus 已经替换，内存向量表已重置，代码没有回滚旧状态。错误表示重建后段未完成，不能理解为旧索引仍完整保留（`engine.go:125-173`）。

重建使用共享引擎的写锁，期间所有检索阻塞在 `RLock` 上（`engine.go:110-111`、`181-182`）；这是进程内锁，不是索引快照隔离。

### 主链一：从“同步索引”到可检索索引

1. 知识库页点击同步、保存笔记、创建笔记或切换 Vault 目录，前端调用 `syncVaultIndex`，发送 `vault.sync`（`ui/src/ui/controllers/vault.ts:148-158`，触发点见 `ui/src/ui/app-knowledge-vault.ts:345-356`、`392`、`494`）。
2. Gateway 的 `VaultSyncHandler` 先驱逐全部会话运行时，再调用重建（`src/pkg/gateway/handlers/vault.go:557-570`）。
3. 重建函数解析 Vault 目录与索引目录，扫描 Markdown 得到文档，用环境变量构造嵌入器，再交给共享引擎（`src/pkg/agent/runtime/knowledge_sync.go:32-57`）。
4. 共享引擎按索引目录取出进程级单例，执行上一节的破坏式重建（`src/pkg/agent/knowledge/shared.go:107-117`）。
5. 响应返回文件数与块数；UI 把当前时间记为“最近同步”，状态接口则通过 `corpus.json` 的修改时间与文档数量推导同样的信息（`vault.go:575-580`、`vaultIndexStats` 于同文件内）。

这里的“驱逐运行时”不是为了让索引生效——索引是进程内共享对象，重建后立即可查；驱逐的目的更可能是让下一次对话重新读取系统提示与工具集。代码没有注释说明动机，此句为推断。

### 启动时并不建索引

服务启动只调用 `InitKnowledgeEngine`，其实现是 `PreloadEngine`：打开或创建 Bleve 索引并缓存引擎，不扫描 Vault（`src/pkg/gateway/http/server.go:178-180`、`src/pkg/agent/runtime/knowledge_sync.go:13-29`、`shared.go:67-76`）。

因此全新安装后的状态是：Vault 被创建并写入一篇 README（`src/pkg/agent/vault.go:45-55`），索引文件存在但为空，`vault.status` 报 0 块且没有同步时间，`memory_search` 返回“无命中”。文档写的“Agent Runtime 启动时扫描 Vault、分块并全量 rebuild”在当前快照中没有对应调用（`docs/knowledge-vault.md:94`、`127`、`266`）。这是文档与实现的明确不一致，结论以可执行路径为准。

## 查询、候选与重排主链

### 查询入口

模型侧唯一入口是 `memory_search`。它在构建 Eino 引擎时随知识选项一起注册，入参是查询文本与可选条数，默认 8（`src/pkg/agent/eino/engine.go:86-88`、`src/pkg/agent/eino/knowledge_tools.go:15-54`）。

触发不是自动的：系统提示要求“用户询问可能记录在知识库中的内容时必须先调用 memory_search”，但没有把 Vault 内容预注入上下文（`src/pkg/agent/runtime/knowledge.go:37-46`）。是否检索完全取决于模型是否遵守这条指令。

UI 另有一条检索入口 `vault.search`，默认返回 20 条，输出裁剪成路径、标题、摘要、分数、起止行（`src/pkg/gateway/handlers/vault.go:887-954`）。它与工具检索共用同一个引擎和同一套打分，只是结果形态不同。

### 候选生成

`SearchIndex` 的候选来自 Bleve 的 `MatchQuery`，作用在 `text` 与 `title` 两个字段上，两者取并集；如果调用方给了 kind 集合，再与 kind 的 term 查询取交集。索引映射把 kind 设为 keyword，title 与 text 使用英文分析器（`src/pkg/agent/knowledge/engine.go:80-97`、`191-220`）。

请求条数是 `limit × 3`，按 `-_score` 排序（`engine.go:222-227`）。没有关键词扩展、同义词、标签过滤或邻接扩展；也没有多路候选融合。

### 向量重排

如果引擎持有嵌入器，查询会再算一个向量；失败时静默降级为纯全文（`engine.go:243-249`）。对每个候选，只要本地存有同维度向量，就把分数改成全文归一化分与余弦相似度的加权和，默认权重 0.55 / 0.45（`45-46`、`258-262`）。

全文分在候选集内做 min-max 归一化（`vector.go:117-142`），余弦值保持在 −1 到 1 的原始尺度；两段分值直接线性加权，没有再做统一缩放。这是实现细节，不代表检索质量结论。

候选里任何没有向量、维度不一致或查询向量缺失的文档，都只保留全文分。因此“混合检索”的实际形态是：向量只能重排已经被全文检索命中的片段，无法救回全文未命中的语义近邻。

### 主链二：一次 `memory_search` 的完整回合

1. 模型在某轮生成中发出 `memory_search` 工具调用，参数为查询与条数。
2. 工具闭包从共享引擎按索引目录取引擎；传 nil 嵌入器，但若启动时已加载过嵌入器，单例会保留它（`knowledge_tools.go:35-39`、`shared.go:34-50`）。
3. 引擎执行上一节的候选生成与向量重排，按分数降序、id 升序稳定排序，截断到 limit（`engine.go:274-283`）。
4. 每条命中按字节截取约 240 长度的摘要，优先围绕查询词附近；切点没有按 UTF-8 字符边界调整（`engine.go:286-324`）。
5. 命中数组整体序列化成 JSON 返回；无命中时返回一句“No vault hits for …”，而不是空数组（`knowledge_tools.go:45-49`）。
6. 工具结果作为一条 tool 消息进入对话，模型在下一轮生成中使用；没有自动追加第二次检索或引用校验。

单次检索只限制条数，没有字符或 token 总预算。工具返回每个命中的完整正文，块的 2400 字节只是按行累加阈值，长行可越过；条数参数只有非正值回退默认 8，没有硬上限。摘要短于正文不会减少正文回注量（`knowledge_tools.go:26-49`、`engine.go:187-188`）。

## 结果契约与上下文注入

命中结构固定为 id、kind、title、snippet、score、text、meta 七项（`doc.go:14-22`）。来源可追溯性由 meta 承担：路径与起止行在切块时写入，工具原样透传（`vault_sync.go:77-81`）。没有匹配类型、阶段、模型名、查询改写记录或引用编号。

UI 的搜索结果裁掉了 id、kind 与完整正文，只保留路径、标题、摘要、分数，并把来源 meta 里的起止行提成两个顶层字段（`vault.go:878-885`）。模型看到的是完整结构，用户看到的是裁剪结构。

注入方式只有一种：工具结果。系统提示规定“先检索再回答”，并给出无命中时的回答话术（`src/pkg/agent/runtime/knowledge.go:41-46`）；除此之外没有在发送前按语义或规则激活 Vault 条目的层，也没有把检索结果拼进 system prompt 的逻辑。

## 阶段、反馈与认知编排边界

整条链只有一个检索阶段，没有查询规划、子查询分解、多轮递进、结果反馈或终止条件。检索结果不会改变后续查询方向，也不会触发额外的模型回合——除了模型自己决定再调一次工具。

判断依据是知识库引擎与 `memory_search` 工具中都没有第二阶段入口，系统提示也只要求“先查再答”；对重排模型、查询改写、查询分解等关键词做检索，命中的只有无关的工具回合修复中间件（`src/pkg/agent/eino/tool_turn_repair_middleware.go:22`）。

因此本项目的“编排”只体现在 Agent 循环本身：模型决定调用哪个工具、读多少条、是否继续查。它不具备 VCPToolBox 式的思维簇、关系传播或阶段递进，也不属于知识资产管线里的摄取任务编排。

## 记忆写回与主动维护

### evolution 记忆：注入而非检索

`evolution` 包维护四个受字符预算约束的 Markdown 文件：记忆、用户画像、Agent 身份、演化系统提示，条目用固定分隔符拼接，写入采用临时文件加原子替换（`src/pkg/agent/evolution/store.go:17-31`、`332-360`）。默认预算分别是 2200、1375、4000、2000 字符（`62-92`）。

系统提示构建时按工作区拼出 `.agents/evolution` 目录，打开存储并把四个块渲染进提示；每个块带百分比用量标题（`src/pkg/agent/runtime/runtime.go:168-187`、`src/pkg/agent/evolution/store.go:401-425`）。

记忆块在每次构建运行时读取一次：构建函数新建存储实例，用空会话键取快照，再把渲染结果拼进系统提示（`src/pkg/agent/runtime/runtime.go:168-187`、`src/pkg/agent/evolution/store.go:120-144`）。

存储实例内的快照缓存只在那一次调用中有效，真正的边界是运行时生命周期。池化运行时不会重建，运行中新增或修改的记忆就不会进入当前提示，直到运行时被重建。

### 写回路径

存储层提供追加、替换、删除三个方法，带重复检测、字符上限和内容扫描（`store.go:146-237`）。但全仓库没有把这三个方法注册成工具，也没有从对话中自动提取记忆的后台任务；检索 `evolution.` 的调用点只出现在运行时构建与测试里。因此本快照中不存在“模型主动维护记忆”的闭环，只有人（或模型通过文件工具间接）修改文件、再由下一次运行时快照注入的被动路径。

Vault 侧相反：写回是显式的用户动作。保存笔记与创建笔记都会触发一次同步（`ui/src/ui/app-knowledge-vault.ts:356`、`494`），删除文件则不会自动触发，索引会保留已删除文件的块直到下一次同步。

### 其他“记忆”配置

顶层 `memory` 配置声明了 builtin 与 qmd 两种后端、索引路径、会话导出、更新间隔、结果上限等字段（`src/pkg/config/schema.go:1054-1100`），但 Go 侧没有读取该结构的运行时代码；本次未找到 QMD 进程启动、索引或注入实现。示例配置只写了后端类型与引用开关两项，没有 qmd 段。

`src/prompt/prompt-zh/AGENTS.md` 另有一套文件约定：会话启动读 `SOUL.md`、`USER.md`、每日 `memory/YYYY-MM-DD.md` 与 `MEMORY.md`。这是工作区提示词层面的行为约定，和 `evolution` 存储、Vault 索引都不是同一实现。

## 预算、作用域、可观测与恢复

**预算**：切块字节阈值与两行重叠、三倍候选数和混合权重固定。工具默认返回 8 条，但调用方可以传更大的正数；结果正文没有总字符或 token 上限。嵌入整库一次请求、超时 120 秒，没有分批与重试（`vault_sync.go:119-149`、`knowledge_tools.go:26-49`）。

**作用域**：Vault 目录优先取 `agents.defaults.knowledge.vaultDir`，否则取 Agent 工作区下的 `vault/`，再否则取状态目录下的 `vault/`（`src/pkg/agent/vault.go:17-36`）。代码只读取 defaults，Agent 列表里的同名配置不参与解析；索引目录固定为状态目录下的 `knowledge-index`，不按 Agent 或 Vault 隔离（`src/pkg/agent/runtime/knowledge.go:18-20`）。

因此多个 Agent 若配置了不同 Vault，共享同一索引；对其中一个 Vault 执行同步会用该 Vault 的内容整体替换索引，其他 Vault 的块随之消失。这是由“单一索引目录 + 全量重建”直接推出的结果，未运行多 Agent 场景验证。

**安全**：没有用户、租户或知识库级 ACL；能访问 Gateway 的人即可通过 `vault.*` 读写 Vault，模型侧工具拥有与运行时相同的文件访问能力。检索结果里的文本被当作工具输出交给模型，没有来源可信度标记或指令隔离；Vault 内容中的提示注入与普通文件读取属于同一风险面。

**可观测**：能看到的只有索引状态（文件数、块数、最近同步时间）与单条结果的分数。没有查询日志、候选数量、命中阶段、降级路径或嵌入失败的独立指标；嵌入失败只让整次重建返回错误。测试方面有切块、跳过隐藏路径、共享引擎和会话历史打分的单元测试，没有检索质量评测或真实语料夹具。

**恢复**：索引可由 Vault 重建，属于可丢弃派生数据；但重建是手动的，且没有文件监听。向量文件不带模型标识，共享条目只在其嵌入器为空时接受新值；已打开的 Engine 却直接返回缓存对象，后补的条目值不会更新该对象。因而首次打开时无嵌入器的引擎，即使后来同步提供嵌入器，也会继续按纯全文路径运行；原先已有嵌入器时，替换模型同样不会更新它。两种情形都受进程内引擎生命周期约束（`shared.go:34-64,107-116`）。

索引损坏时，启动预载只记一条警告，之后工具调用会返回引擎打开错误；没有自动重建或降级到纯关键字的兜底。

## 与相邻谱系的可比/不可比边界

- **可与普通 RAG 比较**：文档切块、全文索引、可选向量、top-k 与来源行号。这些维度上它是标准的“文件 + 块 + 混合打分”实现。
- **不可与知识资产管线直接比较**：没有数据集、发布、权限、增量索引、索引任务状态或版本回滚；只有一个 Vault 目录和一次全量重建。
- **不可与检索驱动认知编排比较**：没有查询改写、多阶段、结构传播或结果反馈；检索是单次工具调用。
- **运维对象查询不属于本类目**：Prometheus 通过 MCP 服务以工具形式接入（`src/pkg/acp/mcp/manager.go:76-98`），告警 Hook 的提示词要求模型优先调用 MCP 工具与 Skills 获取真实指标（`src/pkg/gateway/http/hooks.go:360-361`）。这些是“查询外部系统”，没有本地索引、切块或向量。
- **日志与会话**：日志尾部读取是 UI 接口（`src/pkg/gateway/handlers/logs.go`），`sessions` 工具列出会话元数据（`src/pkg/agent/tools/sessions.go:40-46`），都不做语义检索。

## 未验证事项

- 未运行索引构建与查询；所有分数、命中率与中文检索效果均未测量。索引分析器被硬编码为英文（`engine.go:88`、`92`），对中文分词的切分方式只能从 Bleve 的 unicode 分词行为推断，属于静态推断，需实测。
- “多 Agent 共享索引互相覆盖”由路径常量与重建逻辑推出，未用两个 Vault 实际验证。
- 更换嵌入模型后向量不更新的结论依赖共享单例的赋值条件，未跑进程级验证。
- 文档称启动时自动建索引，代码路径未找到对应调用；是否存在本快照之外的启动脚本或外部触发，本次未追查。
- `embedding_model.txt` 位于仓库根目录，内容是向本机 18902 端口内嵌对话模型发请求的 curl 样例与响应，文件名与“嵌入模型”无关；全仓库没有引用该文件，判断为手工调试留存，未验证其用途。
- 未运行 Gateway、桌面应用或 `src/pkg/agent/knowledge` 下的测试。

## 关键源码索引

- `src/pkg/agent/knowledge/engine.go`：索引映射、破坏式重建、候选生成与混合打分
- `src/pkg/agent/knowledge/vault_sync.go`：Vault 扫描、切块、id 与来源元数据
- `src/pkg/agent/knowledge/vector.go`、`corpus.go`：向量与正文旁路存储、余弦与归一化
- `src/pkg/agent/knowledge/embedder.go`、`openai_compat_embed.go`：嵌入器构造与请求
- `src/pkg/agent/knowledge/shared.go`：进程级共享引擎、预载与重建
- `src/pkg/agent/eino/knowledge_tools.go`：`memory_search` 工具定义与返回格式
- `src/pkg/agent/runtime/knowledge.go`、`knowledge_sync.go`：索引路径、系统提示规则、重建入口
- `src/pkg/gateway/handlers/vault.go`：`vault.sync`、`vault.search`、状态与文件操作
- `src/pkg/agent/evolution/store.go`：记忆文件、预算、快照与增删改
- `src/pkg/agent/runtime/runtime.go`：系统提示拼接与 evolution 注入
- `src/pkg/agent/knowledge/history.go`：未被调用的会话历史打分
- `docs/knowledge-vault.md`、`docs/embedded-models.md`：用户侧说明与向量模型定位
