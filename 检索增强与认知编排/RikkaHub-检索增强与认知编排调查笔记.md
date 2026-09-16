# RikkaHub 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9a35e3f2f1e2820e95c37deb82ef8f5e1592e06f`（分支：`master`）
>
> 调查方式：静态通读当前快照的记忆、搜索、会话检索、附件转换与生成链路源码；对照仓库内 `docs/references/chat-generation-pipeline.md` 检查文档与实现一致性；未构建 APK、未运行设备、未调用任何搜索 provider 或模型
>
> 调查范围：记忆实体与注入、网页搜索 provider 适配与工具回注、会话内/跨会话全文检索、文档附件与 OCR 转文本、标题/建议/翻译/压缩等辅助生成、向量检索与 RAG 的存在性核查；不重复 MCP、Workspace、通用消息上下文裁剪的完整调查
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 在本类目中属于“工具化检索 + 上下文即时注入”的组合，而不是知识资产管线或检索驱动认知编排。三类可检索素材分属三条独立链路，且不共享检索基础设施：长期记忆以纯文本记录直接注入 system prompt，并暴露一个增删改工具供模型维护；网页搜索以模型可调用的 `search_web`／`scrape_web` 接入，由设置中选定的 provider 执行，抓取工具只在 provider 提供抓取 schema 时装配；历史会话以本地全文索引承载，通过 `recent_chats` 与 `conversation_search` 两个模型可见工具按需检索（`data/ai/tools/ChatToolFactory.kt:38-95`、`data/ai/tools/MemoryTools.kt:20-101`、`data/ai/tools/ConversationTools.kt:23-110`）。

本次全仓库 Kotlin 源码范围内未找到可用的向量检索或 RAG 管线：`ai` 模块声明了嵌入生成接口与嵌入模型类型，但应用层没有调用方；附件、记忆和会话都不做分块、嵌入或相似度召回。会话检索与网页搜索都只有一次候选生成，没有 reranker、融合或查询改写；模型可连续多次调用工具，但系统侧没有阶段状态或终止策略（`ai/src/main/java/me/rerere/ai/provider/Provider.kt:36-40`、`data/ai/tools/SearchTools.kt:20-124`、见“未验证事项”中的检索依据）。

## 谱系定位与系统边界

按调查指南的谱系划分，本项目的实现分布在三处，且彼此不共享检索基础设施：

| 素材 | 触发方 | 技术手段 | 谱系 |
|---|---|---|---|
| 助手/全局记忆 | 每次生成无条件注入 + 模型调用工具写回 | 表全量读取、拼入 system prompt | 上下文即时注入 + 主动记忆演化（弱，仅模型触发） |
| 网页/网页抓取 | 模型按需调用工具 | 19 个 provider 适配器，返回结构化条目 | 工具化检索 |
| 历史会话消息 | 模型按需调用工具；另有用户检索页与 HTTP API | 本地全文索引 + 自定义分词扩展 | 相似度/关键词召回（关键词路径） |
| 文档/图片附件 | 发送前管道 | 解析或 OCR 为纯文本内联为消息 | 上下文即时注入 |

边界上有两点。其一，会话检索的事实源是本地应用数据库与本地索引表，不涉及远端知识库或租户；单机单用户是唯一的部署形态（`data/db/AppDatabaseFactory.kt:16-52`）。其二，网页搜索只是发起外部 HTTP 请求并把结果交回模型，项目自身不保存搜索索引、不缓存网页正文，也不维护搜索历史（`data/ai/tools/SearchTools.kt:62-85`）。

一条与检索相关的端到端主链如下；工具注册顺序、附件转文本与输入变换器链的完整细节分属 Agent 工具与上下文两侧笔记：

```text
用户发送消息
  -> ChatService.handleMessageComplete()
  -> 装配记忆/搜索/会话工具，读取记忆列表（全局或助手隔离）
  -> GenerationLoop 构造 system message：系统提示 + Memories + 各工具 systemPrompt
  -> 输入变换器管道（文档转文本、OCR 等，详见上下文编译笔记）
  -> 模型返回 tool_calls（search_web / conversation_search / memory_tool）
  -> 工具执行，结果内联进 assistant 消息，再送入下一轮
  -> 无工具调用或达到 256 步上限后收尾：保存会话并重建该会话索引，异步生成标题与建议
```

## 事实对象、摄取与索引

### 记忆：以助手为隔离键的纯文本行

记忆的最小实体只有三个字段：自增主键、所属助手标识 `assistant_id`、内容 `content`，没有时间戳、标签、来源、向量或分类；DAO 只提供按助手或 id 的查询、插入、更新、删除与按助手批量删除，没有全文或相似度检索入口（`data/db/entity/MemoryEntity.kt:7-15`、`data/db/dao/MemoryDAO.kt:11-38`）。仓库层在其上定义全局记忆：`GLOBAL_MEMORY_ID = "__global__"` 并不是单独的表，而是把 `assistant_id` 固定为一个保留字面量复用同一张表（`data/repository/MemoryRepository.kt:10-12`）。

记忆的读写在两个方向上发生。写入有两处入口：模型通过 `memory_tool` 增删改，以及助手记忆管理页的手动增改（`data/ai/tools/MemoryTools.kt:73-100`、`ui/pages/assistant/detail/AssistantDetailVM.kt:181-205`）。读取只有一处：每次生成前由 `ChatService` 按 `useGlobalMemory` 选择全局列表还是当前助手列表，整表读出后交给生成循环（`service/ChatService.kt:736-740`）。工具写入目标同样跟随该开关：开启全局记忆时写 `__global__`，否则写当前助手 id（`data/ai/tools/ChatToolFactory.kt:44-58`）。因此开启全局记忆的助手读写的都是共享池，其余助手仍读各自隔离池。

这条设计使记忆没有任何“摄取”阶段：内容即记录，模型自行决定创建、合并或删除，工具描述也要求“相似记忆应合并、优先更新已有记录”。但是否真的发生合并取决于模型行为，系统侧没有去重或冲突检测（`data/ai/tools/MemoryTools.kt:28-45`）。

### 会话消息与附件：索引事实源在相邻笔记

历史会话的全文检索建立在一张独立于业务实体的虚拟表上，由随 APK 打包的原生库提供分词与高亮函数；索引按会话整体重建并在会话保存时同步刷新，另有全库重建入口。这些结构、装载方式与维护时机属于[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)的范围，本笔记只把它当作会话检索的事实源。

附件方面只保留一条与检索相邻的结论：文档与图片附件都在发送前被解析或 OCR 成纯文本、内联进用户消息，模型看到的是文本而不是可检索的媒体索引。解析器选择、OCR 触发条件与缓存细节见[媒体创作笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。

## 查询、候选与重排主链

### 网页搜索：单一 provider、provider 自带 schema

搜索工具集最多两个成员：`search_web` 始终按当前所选 provider 装配，`scrape_web` 仅在该 provider 的抓取 schema 非空时追加（`data/ai/tools/SearchTools.kt:20-124`）。工具的参数 schema 不是项目自定义的中立协议，而是直接向 provider 适配器索取，因此不同 provider 暴露给模型的字段不同：Exa 提供搜索类型与发布日/域名/时效过滤，Perplexity 提供 maxTokens，本地 Bing 与 SearXNG 只暴露最少的查询字段（`search/src/main/java/me/rerere/search/ExaSearchService.kt:50-101`、同目录 `SearchService.kt:143-360`）。

provider 集合由 sealed class 的 19 个选项与一个 `when` 分派表定义，没有插件注册机制或优先级链：所有 provider 平级，用户在设置中选中一个后，搜索工具就固定用它（`search/src/main/java/me/rerere/search/SearchService.kt:46-68,152-172`）。按是否自带抓取端点分三类：Exa、Tavily、LinkUp、Firecrawl、Jina、Ollama、Tinyfish 提供独立抓取端点，因此 `scrape_web` 可用；Bing（本地）与各家云端搜索 API 只做检索；Custom JS 由用户脚本决定是否支持抓取。

搜索不带候选融合或重排：适配器把各家响应映射为统一的 `SearchResult`（可选的 `answer`、条目列表、图片列表、`retrievedAt`），字段缺省即留空，不做去重、cross-encoder 或跨 provider 合并（`search/src/main/java/me/rerere/search/SearchService.kt:95-117`）。

结果进入上下文前只做一层“贴标签”处理：把统一结果序列化成 JSON，给每个条目补一个 6 字符随机 `id` 与从 1 开始的 `index`，并把 `retrievedAt` 覆盖为本地当前时间，随后整段 JSON 作为工具结果文本返回（`data/ai/tools/SearchTools.kt:62-85`）。模型侧拿到标题、URL、正文、发布日期与高亮；工具描述要求模型在回答句末追加 `[citation,domain](id)`，UI 再按 id 反查搜索输出找到真实 URL 并跳转（`data/ai/tools/SearchTools.kt:41-53`、`ui/components/message/ChatMessage.kt:285-304`）。

### 会话检索工具：关键词召回、作用域不对称

`conversation_search` 与 `recent_chats` 都以本地全文索引为事实源，是同一素材的两个视角，作用域并不对称。`conversation_search` 把模型给的查询词直接交给索引层做关键词匹配，返回带高亮标记的片段，排序可选相关性、最新、最早；查询词没有改写、没有同义扩展，也没有把上一轮结果并入下一轮，多次搜索完全依赖模型自行换词重试，工具描述也这样建议（`data/ai/tools/ConversationTools.kt:68-97`）。候选在索引层硬编码上限 50，工具层再按模型指定的 limit 钳制在 1–50、默认 15。

`recent_chats` 返回当前助手名下最近会话的 id、标题与最后活跃日期，排序为置顶优先、更新时间次之，limit 钳制 1–30、默认 10；它不返回正文，工具描述要求模型改用 `conversation_search` 查内容（`data/ai/tools/ConversationTools.kt:28-64`）。

两者都是模型可见工具，由模型在对话中自行决定调用；同一索引层另有面向用户的检索页和本地 HTTP 检索接口。两者虽与网页搜索同名“search”，但底层、作用域与结果契约完全不同，不应视为同一能力。

## 阶段、反馈与结果注入

### 工具循环中的检索：模型侧多轮、系统无阶段

检索工具与其他工具共用同一条生成循环，最多 256 步：每步先让模型生成，再执行本步的工具调用，结果写回同一 assistant 消息后进入下一步。调用时机、审批状态机与结果回注契约属于[Agent工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)的范围。

系统侧没有检索编排：不统计阶段数、不检测重复查询、不缓存结果、不因空结果自动换词；唯一预算机制是按会话是否具备 shell 能力生效的工具输出截断。因此“多轮检索”是模型可选行为，代码中没有把它固化成认知链，截断细节见 Agent 工具笔记（`data/ai/GenerationLoop.kt:83,96-218,536-568`）。

### 记忆段在上下文中的位置与时机

记忆不是工具结果，而是 system message 的一部分：`generateInternal` 在系统提示之后追加 Memory 段，再追加各工具的 systemPrompt（默认返回空串，因此多数工具不贡献系统提示）（`data/ai/GenerationLoop.kt:346-371`）。Memory 段的实际格式是一行 Markdown 标题加英文说明，随后是 `[{id, content}, ...]` 的 JSON 数组（`data/ai/GenerationPrompts.kt:9-26`）。

这里存在一处文档与实现不一致：`memory_tool` 的描述称记忆稍后会出现在 `<memories>` 标签中，但实际注入不含该标签，内容直接以“**Memories**”标题和 JSON 出现（`data/ai/tools/MemoryTools.kt:34`），以可执行路径为准。注入是全量的：本次未找到按相关性筛选、按 token 预算裁剪或只取最近 N 条的代码，记忆条数增长会等量增加每次请求的 system prompt。

记忆以外还有若干发送前注入层（时间提醒、Lorebook 触发注入、占位符替换、模板渲染等），属于检索结果的消费侧：Lorebook 条目按扫描深度匹配上下文并支持四种注入位置，其位置、优先级与变换器顺序见[上下文编译与提示词工程笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。

### 标题、建议、翻译与压缩：认知编排后处理

四类辅助生成都是独立的一次性模型调用，不共享主对话的工具循环或上下文预算，因此定位于生成后的编排后处理，而不是检索链的一环。标题在收尾后按需触发（标题为空或强制重生成时），取最后 4 条消息各截断 500 字符交给 fast 模型；建议取最后 8 条消息、由 `enableSuggestion` 控制，拆成最多 10 条存入会话元数据（`service/ChatService.kt:888-989`）。

压缩是用户手动触发的破坏性操作：默认保留最近 32 条消息，其余按每块最多 256 条递归二分后并发摘要，再用“摘要消息 + 保留原消息”重建会话，替换而非追加，也不产生可回滚的中间产物（`service/ChatService.kt:993-1075`）。翻译分两支：普通模型走 `translatePrompt`，Qwen MT 模型改走 `translation_options` 结构化字段（`data/ai/TranslationHandler.kt:26-96`）。四条提示词都可在设置页编辑并一键恢复默认（`ui/pages/setting/SettingModelPromptPage.kt:53-91`）。

## 记忆写回与主动维护

记忆写回完全由模型在对话中发起：`memory_tool` 是普通工具，默认无需审批（`needsApproval` 缺省为 false），因此增删改在许可状态下会直接执行，没有二次确认（`ai/src/main/java/me/rerere/ai/core/Tool.kt:17`、`data/ai/tools/MemoryTools.kt:20-101`）。工具的返回是写入后的记录 JSON，删除返回 `{"success": true, "id": ...}`，UI 为三种动作分别提供展示组件（`ui/components/message/tools/BuiltinToolUIs.kt:90-155`）。

本次检查范围内未找到任何主动记忆演化机制：没有后台复盘、定时整理、跨会话合并、冲突消解或“从消息自动抽取事实”的管道；记忆的变化只来自工具调用或用户手动编辑。工具描述中的“相似记忆应合并”是给模型的指令，不是系统强制（`data/ai/tools/MemoryTools.kt:39`）。这一点在检索指南的“主动记忆演化”谱系中只算弱实现，与具备后台触发与审批闭环的系统不可直接比较。

## 预算、作用域、可观测与恢复

**作用域**方面，记忆按 `assistant_id` 隔离，全局开关是显式共享而非隐式回退；会话检索工具的作用域则不一致：`recent_chats` 绑定当前助手 id，而 `conversation_search` 调用仓库层时未传助手参数，会命中所有助手的会话（`data/ai/tools/ConversationTools.kt:50-53` 对同文件 95-97）。历史检索页与 HTTP API 支持选择“当前助手／全部助手”，工具侧没有该选项（`ui/pages/search/SearchVM.kt:108-122`、`web/src/main/java/me/rerere/rikkahub/web/routes/ConversationRoutes.kt:123-141`）。这是当前实现事实，是否属于预期行为未在代码或文档中说明。

**预算**集中在少数硬编码常量上，且没有检索专用的资源治理：搜索只有一个 `resultSize`（默认 10），会话检索的候选上限为 50、工具层再钳到 1–50，`recent_chats` 上限 30；没有检索专用超时（沿用 HTTP 客户端 30 秒读超时）、没有搜索缓存、没有单次生成的检索次数上限，也没有记忆条数或 token 预算（`search/src/main/java/me/rerere/search/SearchService.kt:70-98`、`data/ai/tools/ConversationTools.kt:33-97`）。工具循环步数上限与工具输出截断阈值同属预算，但实现归属见 Agent 工具笔记。

**可观测面**主要是工具卡（搜索结果显示条数与查询、记忆显示增删改与内容）、引用链接跳转、检索页的索引重建进度，以及请求日志拦截器记录的完整请求。本次未找到候选全量列表、检索耗时、命中率、provider 降级路径或质量评测面板（`ui/components/message/tools/BuiltinToolUIs.kt:90-155`、`data/ai/RequestLoggingInterceptor.kt`）。

**恢复语义**方面，记忆与消息都是持久化表，随数据库备份／同步迁移；索引表不在业务实体列表中，由数据库打开回调保证存在，词典缺失时可全库重建（`data/db/AppDatabaseFactory.kt:20-52`、`data/repository/ConversationRepository.kt:334-345`）。记忆没有排序字段，DAO 查询不含 `ORDER BY`，注入顺序依赖底层返回顺序，未做显式稳定化（`data/db/dao/MemoryDAO.kt:12-16`）。

## 与相邻谱系的可比/不可比边界

与**知识资产管线**不可比：本项目没有摄取、分段、嵌入、索引版本、租户授权或发布流程，文档附件是一次性内联文本，会话索引是不可跨设备迁移的本地派生表。

与**工具化检索**可比：两者都定义模型可调用的 schema、都在执行后把结果回注下一模型回合；RikkaHub 的差异是检索源为三个彼此独立的本地/远端素材，且工具 schema 由 provider 决定，项目不保证字段中立。

与**上下文即时注入**可比且高度相关：记忆、文档、OCR、Lorebook 都在发送前改写消息列表，区别只是触发方式（无条件、条件、匹配触发）。

与**检索驱动认知编排**不可直接比较：当前实现没有查询改写、候选融合、结构重排、关系传播或阶段状态；多次工具调用是模型侧可选行为，不能静态推断为稳定认知链。与具备主动记忆维护的系统相比，RikkaHub 的记忆写回只有模型触发一条路径，也没有审批或合并策略。

## 未验证事项

- 未运行设备、未构建 APK，未验证分词与高亮片段在中文/英文/混合文本上的表现，也未验证词典解压失败时的降级行为。
- 未调用任何搜索 provider，未确认真实响应字段与适配器映射是否一致、各 provider 的限流与错误文案、`scrape_web` 的正文质量，以及 `Custom JS` 引擎的沙箱边界。
- 未运行模型工具循环，未确认模型对 `search_web`／`conversation_search`／`memory_tool` 的实际调用率、是否会连续换词搜索、空结果后的行为，以及输出截断的触发频率。
- 未验证 `conversation_search` 实际不按助手过滤是否被 UI 或产品层面有意接受，以及记忆注入顺序的稳定性、条目增长对请求体积的影响与全局/隔离记忆并存的认知成本；本笔记只记录代码路径。
- “无向量检索/RAG”的检索依据是：全仓库 Kotlin 源码中嵌入生成仅出现在 `ai` 模块的接口与 OpenAI／Google provider 实现，`ModelType.EMBEDDING` 只用于模型分类与 UI 标签，未发现调用 `generateEmbedding` 或建立/查询本地向量索引的代码；这表示本次已检查范围内未找到，不等同于全局不存在其他形态（原生层、Web 前端或未读模块）。
- 仓库文档 `docs/references/chat-generation-pipeline.md` 与实现存在命名与顺序偏差：文档称 `GenerationHandler` 而实际类为 `GenerationLoop`，并称搜索工具列首、记忆工具内置且列末，实际由 `ChatToolFactory` 统一装配；本笔记以可执行路径为准。

## 关键源码索引

- 记忆实体、DAO 与仓库、注入格式：`data/db/entity/MemoryEntity.kt`、`data/db/dao/MemoryDAO.kt`、`data/repository/MemoryRepository.kt:9-71`、`data/ai/GenerationPrompts.kt:9-26`
- 记忆工具与写回 UI：`data/ai/tools/MemoryTools.kt:20-101`、`ui/components/message/tools/BuiltinToolUIs.kt:90-155`
- 助手记忆开关：`data/model/Assistant.kt:29-31,64-67`、`data/ai/tools/ChatToolFactory.kt:44-58`
- 网页搜索工具与结果回注：`data/ai/tools/SearchTools.kt:20-124`、`ui/components/message/ChatMessage.kt:285-304`
- 搜索 provider 抽象与分派：`search/src/main/java/me/rerere/search/SearchService.kt:22-360`（各 provider 同目录 `*SearchService.kt`）
- 会话检索工具：`data/ai/tools/ConversationTools.kt:23-110`
- 检索页与 HTTP 检索接口：`ui/pages/search/SearchVM.kt:27-152`、`web/src/main/java/me/rerere/rikkahub/web/routes/ConversationRoutes.kt:123-141`
- 辅助生成：`service/ChatService.kt:888-1075`、`data/ai/TranslationHandler.kt`、`data/ai/prompts/`（TitleSummary／Suggestion／CompressPrompt／Translation）
- 嵌入接口（本次未找到调用方）：`ai/src/main/java/me/rerere/ai/provider/Provider.kt:36-40,104-115`、`ai/src/main/java/me/rerere/ai/provider/providers/openai/OpenAIProvider.kt:151-198`
