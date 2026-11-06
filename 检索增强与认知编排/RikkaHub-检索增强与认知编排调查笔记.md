# RikkaHub 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：静态通读当前快照的记忆库、搜索、会话全文索引、附件转换与生成链路源码；对照仓库内 `docs/references/chat-generation-pipeline.md` 检查文档与实现一致性；未构建 APK、未运行设备、未调用任何搜索 provider 或模型
>
> 调查范围：记忆文件库与注入/读取、后台记忆整理、网页搜索 provider 适配与工具回注、会话内/跨会话全文检索与查询构造、文档附件与 OCR 转文本、标题/建议/翻译/压缩等辅助生成、向量检索与 RAG 的存在性核查；不重复 MCP、Workspace、通用消息上下文裁剪的完整调查
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 在本类目中属于“工具化检索 + 上下文即时注入 + 后台记忆整理”的组合，而不是知识资产管线。三类可检索素材分属三条独立链路，且不共享检索基础设施：长期记忆是以助手为隔离键的 Markdown 文件库，注入时给出文件目录与核心文件全文，其余文件由模型按需用工具读取；网页搜索以模型可调用的 `search_web`／`scrape_web` 接入，由设置中选定的 provider 执行；历史会话以本地全文索引承载，通过 `recent_chats` 与 `conversation_search` 两个模型可见工具检索（`data/ai/tools/ChatToolFactory.kt`、`data/ai/tools/MemoryTools.kt`、`data/ai/tools/ConversationTools.kt`）。

本次全仓库 Kotlin 源码范围内未找到可用的向量检索或 RAG 管线：`ai` 模块声明了嵌入生成接口与嵌入模型类型，但应用层没有调用方；附件、记忆和会话都不做分块、嵌入或相似度召回。会话检索与网页搜索都只有一次候选生成，没有 reranker、融合或查询改写；模型可连续多次调用工具，但系统侧没有阶段状态或终止策略（`ai/src/main/java/me/rerere/ai/provider/Provider.kt`、见“未验证事项”中的检索依据）。

记忆文件带版本与元数据，可后台整理与按需读取；会话全文索引采用单字切分、按片段拼 NEAR 查询，原生扩展提供拼音与前缀匹配；搜索目录有 20 个 provider，包含 Bocha、Grok、RikkaHub 与 DeepSeek 等选项。

## 谱系定位与系统边界

按调查指南的谱系划分，本项目的实现分布在三处，且彼此不共享检索基础设施：

| 素材 | 触发方 | 技术手段 | 谱系 |
|---|---|---|---|
| 记忆库 | 每次生成注入目录与核心文件；模型按需读取其余文件；后台整理写入 | Markdown 文件 + 目录/摘要注入 + 工具读取 + 乐观锁写入 | 上下文即时注入 + 主动记忆演化（后台整理） |
| 网页/网页抓取 | 模型按需调用工具 | 20 个 provider 适配器，返回结构化条目 | 工具化检索 |
| 历史会话消息 | 模型按需调用工具；另有用户检索页与 HTTP API | FTS5 全文索引 + 单字/NEAR 查询构造 | 相似度/关键词召回（关键词路径） |
| 文档/图片附件 | 发送前管道 | 解析或 OCR 为纯文本内联为消息 | 上下文即时注入 |

边界上有两点。其一，会话检索的事实源是本地应用数据库与本地索引表，作用范围限于单机单用户的本地库。其二，网页搜索的职责限于发起外部 HTTP 请求并把结果交回模型，每次调用的结果直接进入当轮上下文；索引、正文缓存与搜索历史这三类状态在项目内都没有对应存储（`data/ai/tools/SearchTools.kt`）。

一条与检索相关的端到端主链如下；工具注册顺序、附件转文本与输入变换器链的完整细节分属 Agent 工具与上下文两侧笔记：

```text
用户发送消息
  -> ChatRequestFactory.createContext()：读取助手记忆库文件
       -> system message = 系统提示 + 记忆段（profile/preferences 全文 + memory_listing）+ 各工具 systemPrompt
  -> 输入变换器管道（文档转文本、OCR 等，详见上下文编译笔记）
  -> 模型返回 tool_calls（search_web / conversation_search / memory_read / memory_write ...）
  -> 工具执行，结果内联进 assistant 消息，再送入下一轮
  -> 无工具调用或达到步数上限后收尾：保存会话并增量重建该会话索引
  -> 轮次结束通知 MemoryConsolidationScheduler：空闲计时或攒够轮数后后台整理记忆
```

## 事实对象、摄取与索引

### 记忆：按助手隔离的 Markdown 文件库

记忆的最小实体是一行文件记录：`(assistant_id, path)` 作复合主键，另有 Markdown 正文与更新时间；没有向量、标签或时间序列（`data/db/entity/MemoryFileEntity.kt`）。文件路径有约定的结构，正文带 YAML 风格的前置元数据（名称、标题、描述、别名），并建议按画像、偏好、主题、进行中的项目、人物分目录存放；格式规则写在共享提示词里，主对话与后台整理共用（`data/ai/prompts/MemoryPrompts.kt`）。

仓库层在其上定义三件事：路径归一化与全校验、带版本的写入、以及按助手复制/删除文件。读取 API 返回 `MemoryFile`，写操作都带 `ifVersion` 做乐观锁——新建传 `new`，修改传当前版本号，冲突返回最新内容让调用方合并；连续编辑、替换唯一子串、末尾追加、删除文件都走同一条加锁路径（`data/repository/MemoryRepository.kt`）。全局记忆仍是保留字面量 `__global__` 复用同一张表，而不是独立存储。

> 注释里给出的 “if_version” 是工具参数名，仓储侧的版本是内容派生的版本串；两者语义一致但并非同一字符串。

写入有两类入口：模型在对话中调用记忆工具（读、写、替换、追加、删除、列目录），以及用户在记忆管理页直接编辑。系统提示对写入时机做了明确约束：默认不在对话中写，交给后台整理；只有用户明确要求“记住/忘记”时才当场写。工具目录里另有一个内容守卫模块，对明显不该入库的内容做拦截（`data/ai/tools/MemoryContentGuard.kt`）。

### 记忆整理：后台触发的“做梦”

整理由 `MemoryConsolidationScheduler` 驱动，在轮次结束后登记待整理轮数，触发条件包括空闲计时到点（默认 2 分钟）、累计轮数达到上限（默认 6 轮）、应用切到后台、用户离开当前会话，以及应用启动时的 `resumePending()`；用户手动整理则先处理全部待整理对话再整体清理记忆库。整理时会构造一个独立的模型调用：读取当前记忆库，给出新近完成的对话轮次，让模型按 [stated] 与时效规则抽取事实，再用记忆工具写回（`data/ai/MemoryConsolidationScheduler.kt`、`MemoryConsolidator.kt`、`prompts/MemoryPrompts.kt`）。

整理模型可在设置页独立选择并配置推理强度。运行时优先使用具备工具能力的专用记忆模型，再尝试具备工具能力的快速模型，最后回退当前会话模型（缺会话时取助手/全局聊天模型）；最后一级沿用快速模型的推理强度，返回的模型副本清空供应商内置工具集合，实际整理工具由后续 Agent 请求提供。见 [模型选择](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/ai/MemoryConsolidator.kt#L294-L305)、[设置入口](../../rikkahub/app/src/main/java/me/rerere/rikkahub/ui/pages/setting/SettingModelPage.kt#L220-L240)。

约束与边界：

- 自动整理受助手的 `autoConsolidateMemory` 开关控制，默认开启；关闭后待整理内容仍可供手动整理，但不会由空闲、切后台或离开会话触发。见 [调度入口](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/ai/MemoryConsolidationScheduler.kt#L137-L175)。
- 按记忆库串行，运行锁是进程内 Mutex；自动整理一次只处理一批，剩余交给定时器。
- 自动整理失败不自动重试，避免模型持续出错时反复调用；待整理内容保留到下一轮对话结束或用户手动触发。
- 分叉出来的对话复制过来的轮次由原对话负责整理，不会重复整理（`onConversationForked`）。
- 整理可读的对话受助手范围限制：后台工具只允许看到该记忆库关联助手的对话（`data/ai/tools/ConversationTools.kt` 的 `createMemoryConversationTools`）。
- 整理本身有失败面：结果里记录改动文件、删除文件、标题与耗时，出错时带错误信息；它会等待应用不可见时的保活服务，前台服务细节见 [主动 Agent 与后台任务笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)。

### 会话消息与附件：索引事实源在相邻笔记

历史会话的全文检索建立在一张独立于业务实体的 FTS5 虚表上，索引按会话增量刷新，并用一张普通表记录每行属于哪个会话，避免按会话删除时全表扫描；标题与更新时间不再写入索引，查询时从会话表读取（`data/db/fts/MessageFtsManager.kt`）。索引的表结构、创建时机与重建入口属于[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)的范围，本笔记只把它当作会话检索的事实源。

附件方面只保留一条与检索相邻的结论：文档与图片附件都在发送前被解析或 OCR 成纯文本、内联进用户消息，模型看到的是文本而不是可检索的媒体索引。解析器选择、OCR 触发条件与缓存细节见[媒体创作笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。

## 查询、候选与重排主链

### 网页搜索：单一 provider、provider 自带 schema

搜索工具集最多两个成员：`search_web` 始终按当前所选 provider 装配，`scrape_web` 仅在该 provider 的抓取 schema 非空时追加（`data/ai/tools/SearchTools.kt`）。工具的参数 schema 直接向 provider 适配器索取，因此不同 provider 暴露给模型的字段不同：Exa 提供搜索类型与发布日/域名/时效过滤，Perplexity 提供 maxTokens，本地 Bing 与 SearXNG 只暴露最少的查询字段（`search/src/main/java/me/rerere/search/ExaSearchService.kt`、同目录 `SearchService.kt`）。

provider 集合由 sealed class 的 20 个选项与一个 `when` 分派表定义，没有插件注册机制或优先级链：所有 provider 平级，用户在设置中选中一个后，搜索工具就固定用它。当前选项为：

```text
bing_local, zhipu, doubao, tavily, exa, searxng, linkup, brave, metaso, ollama,
perplexity, firecrawl, jina, bocha, rikkahub, grok, tinyfish, serper, deepseek, custom_js
```

按是否自带抓取端点分三类：Exa、Tavily、LinkUp、Firecrawl、Jina、Ollama、Tinyfish 提供独立抓取端点，因此 `scrape_web` 可用；Bing（本地）与各家云端搜索 API 只做检索；Custom JS 由用户脚本决定是否支持抓取。

搜索不带候选融合或重排：适配器把各家响应映射为统一的 `SearchResult`（可选的 `answer`、条目列表、图片列表、`retrievedAt`），字段缺省即留空，不做去重、cross-encoder 或跨 provider 合并。部分 provider 有自己的附加开关（例如 Tavily 的 answer 选项），但都只影响该适配器返回的字段，不改变统一结果契约。

结果进入上下文前只做一层“贴标签”处理：把统一结果序列化成 JSON，给每个条目补一个 6 字符随机 `id` 与从 1 开始的 `index`，并把 `retrievedAt` 覆盖为本地当前时间，随后整段 JSON 作为工具结果文本返回。模型侧拿到标题、URL、正文、发布日期与高亮；工具描述要求模型在回答句末追加 `[citation,domain](id)`，UI 再按 id 反查搜索输出找到真实 URL 并跳转（`data/ai/tools/SearchTools.kt`、`ui/components/message/ChatMessage.kt`）。

### 会话检索工具：关键词召回、作用域不对称

`conversation_search` 与 `recent_chats` 都以本地全文索引为事实源，是同一素材的两个视角，作用域并不对称。`conversation_search` 把模型给的查询词交给索引层做关键词匹配，返回带高亮标记的片段，排序可选相关性、最新、最早；查询词没有改写、没有同义扩展，也没有把上一轮结果并入下一轮，多次搜索完全依赖模型自行换词重试，工具描述也这样建议。候选在索引层硬编码上限 50，工具层再按模型指定的 limit 钳制在 1–50、默认 15。

`recent_chats` 返回当前助手名下最近会话的 id、标题与最后活跃日期，排序为置顶优先、更新时间次之，limit 钳制 1–30、默认 10；它不返回正文，工具描述要求模型改用 `conversation_search` 查内容。

两者都是模型可见工具，由模型在对话中自行决定调用；同一索引层另有面向用户的检索页和本地 HTTP 检索接口。两者虽与网页搜索同名“search”，但底层、作用域与结果契约完全不同，不应视为同一能力。索引层的查询构造见下节。

### 会话检索的查询构造：单字切分 + NEAR

索引的 tokenizer 是 FTS5 的 `simple` 扩展，随 APK 打包 `libsimple.so`（arm64-v8a 与 x86_64），提供 `simple_query` 与 `simple_snippet` 两个函数；它支持拼音展开与前缀匹配，因此英文、数字与拼音由它处理（`app/src/main/jniLibs/`、`data/db/fts/MessageFtsManager.kt`）。

中文不再依赖 jieba 词典。查询构造的做法是：先把搜索词按“ASCII 字母数字连续段 / 其他字符连续段”切开；ASCII 段交给 `simple_query`，其余段拆成单字并用 NEAR 约束相邻程度，各段之间用 AND 连接。中文片段允许两字的额外间隔（标点、“的”等），片段越长允许的间隔越多；这样不建词典也能得到接近按词匹配的效果（同一文件中的 `buildFtsMatchQuery`、`nearQuery`、`CJK_NEAR_SLACK`）。

该实现有两个已确认的后果：单字词会退化成单字匹配，召回偏宽；长中文片段在单字之间夹字过多时可能漏召回，因为 NEAR 距离是按片段长度推算的。片段本身由 `simple_snippet` 截取固定长度并给命中词加方括号。

## 阶段、反馈与结果注入

### 工具循环中的检索：模型侧多轮、系统无阶段

检索工具与其他工具共用同一条生成循环：每步先让模型生成，再执行本步的工具调用，结果写回同一 assistant 消息后进入下一步。调用时机、审批状态机与结果回注契约属于[Agent工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)的范围。

系统侧没有检索编排：阶段计数、重复查询检测、结果缓存和空结果换词都没有对应实现，是否追加一轮检索由模型自行判断；唯一预算机制是按会话是否具备 shell 能力生效的工具输出截断。因此“多轮检索”是模型可选行为，代码中没有把它固化成认知链，截断细节见 Agent 工具笔记（`ai/src/main/java/me/rerere/ai/agent/AgentLoop.kt`）。

### 记忆段在上下文中的位置与时机

记忆段随 system message 注入，与工具结果分属不同通道：构造上下文时先写系统提示，再追加记忆段，最后追加各工具的系统提示。记忆段的格式是“当前记忆”标题、核心文件全文与一份文件目录；目录每行给出路径、一行描述、别名与更新时间，模型据此决定是否调用 `memory_read` 读取某个文件（`data/ai/ChatRequestFactory.kt`、`data/ai/prompts/MemoryPrompts.kt`）。

这种“目录常驻 + 内容按需”的设计取代了早期的全量注入：注入体积只随文件数增长，正文读取由模型显式触发；系统提示同时要求画像与偏好两份文件已可直接使用、不必重读。记忆以外还有若干发送前注入层（时间提醒、Lorebook 触发注入、占位符替换、模板渲染等），属于检索结果的消费侧：Lorebook 条目按扫描深度匹配上下文并支持四种注入位置，其位置、优先级与变换器顺序见[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。

### 标题、建议、翻译与压缩：认知编排后处理

四类辅助生成都是独立的一次性模型调用，不共享主对话的工具循环或上下文预算，因此定位于生成后的编排后处理，而不是检索链的一环。标题在收尾后按需触发（标题为空或强制重生成时），取最后几条消息各截断后交给 fast 模型；建议取最近若干消息、由 `enableSuggestion` 控制，拆条存入会话元数据（`service/ChatService.kt`、`data/ai/prompts/`）。

压缩已改为检查点模型：把旧消息摘要成一条带标记的检查点插入会话，而不是替换整段历史；默认保留最近若干轮，其余按块递归摘要后并发执行。翻译分两支：普通模型走 `translatePrompt`，Qwen MT 模型改走 `translation_options` 结构化字段（`data/ai/TranslationHandler.kt`）。四条提示词都可在设置页编辑并一键恢复默认（`ui/pages/setting/SettingModelPromptPage.kt`）。

## 记忆写回与主动维护

记忆写回有两条路径。模型在对话中调用六个记忆工具（`memory_read`、`memory_write`、`memory_str_replace`、`memory_append`、`memory_delete`、`memory_list`），工具默认无需审批；写入前要求先读并带上版本，冲突时以返回的最新内容合并后重试。另一条是后台整理，按上节规则在轮次结束后抽取事实并写回（`data/ai/tools/MemoryTools.kt`、`MemoryConsolidationScheduler.kt`）。

后台记忆演化包含复盘与合并：后台复盘、跨会话合并与去重都在整理提示词里成文，整理由用户活动派生而不是独立日程（触发条件见上文）。它仍不是审批闭环：整理写入直接落库，系统侧没有逐条人工审核或回滚入口；冲突处理依赖版本号与模型重试。

## 预算、作用域、可观测与恢复

**作用域**方面，记忆按 `assistant_id` 隔离，全局开关是显式共享而非隐式回退；后台整理只能看到关联助手的对话。聊天侧的会话检索工具仍然不对称：`recent_chats` 绑定当前助手 id，而 `conversation_search` 调用仓库层时未传助手参数，会命中所有助手的会话。历史检索页与 HTTP API 支持选择“当前助手／全部助手”，工具侧没有该选项。这是当前实现事实，是否属于预期行为未在代码或文档中说明。

**预算**集中在少数硬编码常量上，且没有检索专用的资源治理：搜索只有一个结果数（默认 10），会话检索的候选上限为 50、工具层再钳到 1–50，`recent_chats` 上限 30；没有检索专用超时（沿用 HTTP 客户端 30 秒读超时）、没有搜索缓存、没有单次生成的检索次数上限。记忆方面没有 token 预算，但目录注入与按需读取降低了正文常驻成本；工具读最多一次 20 个路径，整理有轮数与空闲延迟上限（`search/src/main/java/me/rerere/search/SearchService.kt`、`data/ai/tools/ConversationTools.kt`、`MemoryTools.kt`、`MemoryConsolidationScheduler.kt`）。工具循环步数上限与工具输出截断阈值同属预算，但实现归属见 Agent 工具笔记。

**可观测面**主要是工具卡（搜索结果显示条数与查询、记忆显示读/写/删与内容）、引用链接跳转、检索页的索引重建进度，以及请求日志拦截器记录的完整请求。本次未找到候选全量列表、检索耗时、命中率、provider 降级路径或质量评测面板（`ui/components/message/tools/BuiltinToolUIs.kt`、`data/ai/RequestLoggingInterceptor.kt`）。

**恢复语义**方面，记忆文件与消息都是持久化表，随数据库备份／同步迁移；索引表不在业务实体列表中，由数据库打开回调保证存在，可全库重建。记忆文件按路径排序还是按更新时间排序取决于 DAO 查询，未显式稳定化；写入的乐观锁保证了并发写不会静默覆盖，但要求调用方处理冲突（`data/db/AppDatabaseFactory.kt`、`data/db/dao/MemoryDAO.kt`、`MemoryRepository.kt`）。

## 与相邻谱系的可比/不可比边界

与**知识资产管线**不可比：本项目没有摄取、分段、嵌入、索引版本、租户授权或发布流程，文档附件是一次性内联文本，会话索引是不可跨设备迁移的本地派生表。

与**工具化检索**可比：两者都定义模型可调用的 schema、都在执行后把结果回注下一模型回合；RikkaHub 的差异是检索源为三个彼此独立的本地/远端素材，且工具 schema 由 provider 决定，项目不保证字段中立。

与**上下文即时注入**可比且高度相关：记忆目录、文档、OCR、Lorebook 都在发送前改写消息列表，区别只是触发方式（无条件、条件、匹配触发）；记忆正文的按需读取又接近检索，构成注入与检索的混合形态。

与**检索驱动认知编排**不可直接比较：当前实现没有查询改写、候选融合、结构重排、关系传播或阶段状态；多次工具调用是模型侧可选行为，不能静态推断为稳定认知链。与具备主动记忆维护的系统相比，RikkaHub 已有后台整理，但没有人工审批或可回滚的合并策略。

## 未验证事项

- 未运行设备、未构建 APK，未验证单字分词与 NEAR 查询在中文/英文/混合文本上的召回质量，也未验证 `libsimple.so` 缺失或加载失败时的行为。
- 未调用任何搜索 provider，未确认真实响应字段与适配器映射是否一致、各 provider 的限流与错误文案、`scrape_web` 的正文质量，以及 `custom_js` 引擎的沙箱边界。
- 未运行模型工具循环，未确认模型对 `search_web`／`conversation_search`／`memory_read` 的实际调用率、是否会连续换词搜索、空结果后的行为，以及输出截断的触发频率。
- 未验证后台整理在真实使用中的触发时序、抽取质量与版本冲突频率；`MemoryContentGuard` 的拦截规则覆盖范围未逐条核对。
- 未确认 `conversation_search` 实际不按助手过滤是否被 UI 或产品层面有意接受，以及目录注入随文件增长对请求体积的影响；本笔记只记录代码路径。
- “无向量检索/RAG”的检索依据是：全仓库 Kotlin 源码中嵌入生成仅出现在 `ai` 模块的接口与 OpenAI／Google provider 实现，`ModelType.EMBEDDING` 只用于模型分类与 UI 标签，未发现调用 `generateEmbedding` 或建立/查询本地向量索引的代码；该结论的覆盖范围是本次已检查的全仓库 Kotlin 源码，原生层、Web 前端与未读模块未纳入。
- 仓库文档 `docs/references/chat-generation-pipeline.md` 与实现存在命名与顺序偏差：文档称的 `GenerationHandler` 一类命名与实际类名不一致，且工具顺序由 `ChatToolFactory` 统一装配；本笔记以可执行路径为准。

## 关键源码索引

- 记忆文件实体、DAO 与仓库：`data/db/entity/MemoryFileEntity.kt`、`data/db/dao/MemoryDAO.kt`、`data/repository/MemoryRepository.kt`
- 记忆提示词、注入格式与整理工作流：`data/ai/prompts/MemoryPrompts.kt`、`data/ai/ChatRequestFactory.kt`
- 记忆工具与内容守卫：`data/ai/tools/MemoryTools.kt`、`data/ai/tools/MemoryContentGuard.kt`、`ui/components/message/tools/BuiltinToolUIs.kt`
- 记忆整理调度与执行：`data/ai/MemoryConsolidationScheduler.kt`、`data/ai/MemoryConsolidator.kt`、`data/db/entity/MemoryConsolidationEntity.kt`
- 网页搜索工具与结果回注：`data/ai/tools/SearchTools.kt`、`ui/components/message/ChatMessage.kt`
- 搜索 provider 抽象与分派：`search/src/main/java/me/rerere/search/SearchService.kt`（各 provider 同目录 `*SearchService.kt`）
- 会话检索工具：`data/ai/tools/ConversationTools.kt`
- 全文索引与查询构造：`data/db/fts/MessageFtsManager.kt`、`app/src/main/jniLibs/*/libsimple.so`
- 检索页与 HTTP 检索接口：`ui/pages/search/SearchVM.kt`、`web/src/main/java/me/rerere/rikkahub/web/routes/ConversationRoutes.kt`
- 辅助生成：`service/ChatService.kt`、`data/ai/TranslationHandler.kt`、`data/ai/prompts/`（TitleSummary／Suggestion／CompressPrompt／Translation）
- 嵌入接口（本次未找到调用方）：`ai/src/main/java/me/rerere/ai/provider/Provider.kt`、`ai/src/main/java/me/rerere/ai/provider/providers/openai/OpenAIProvider.kt`
