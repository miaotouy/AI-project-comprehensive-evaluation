# SillyTavern 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：静态追踪当前核心发送链、World Info、随发行版加载的 Summarize/Vector Storage 扩展及其 HTTP 存储端点；未运行实例、Embedding 提供方或外部扩展
>
> 调查范围：World Info、聊天摘要记忆、Vector Storage 与 Data Bank 的事实对象、存储、发送时选择、注入、预算、作用域、安全、观察和恢复；不覆盖生成渠道、第三方扩展或横向比较
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**源码事实。** SillyTavern 在此范围内是三条并列的“发送前上下文选择”链，而非统一知识库或检索驱动认知编排器：核心 World Info 对 Lorebook 条目作关键词、条件、概率和可选递归扫描；Summarize 扩展将对话压缩为一段可编辑摘要；Vector Storage 扩展对聊天、附件和可选的 World Info 条目做一次向量近邻查询。三者最终都以普通文本进入核心的 extension prompt 槽或消息历史，模型不会取得带分数、来源引用或阶段信息的结构化检索结果。

**源码事实。** 核心拥有发送时的 prompt 槽、World Info 扫描及 World Info 文件 API；摘要与向量策略由内置扩展拥有。后端向量路由只提供 Embedding 调用、Vectra 本地索引和增删查，不决定何时索引、如何组织查询或如何将结果写入 prompt。Vector Storage 的 `generate_interceptor` 在主发送链的 World Info 扫描之前执行，World Info 因而可扫描标记为允许扫描的扩展提示。见 `public/script.js:4500-4505,4562-4618`、`public/scripts/extensions.js:2008-2040` 与 `public/scripts/extensions/vectors/manifest.json:1-16`。

**静态推断。** 该架构可让检索到的旧消息替代其在工作历史中的位置，并将资料片段、摘要或 Lorebook 内容放到可配置深度；它解决的是本轮上下文取舍。已检查核心和这两个内置扩展的发送路径，未发现“检索结果改写下一次查询”“关系图传播”“跨回合检索计划”或无新消息自动维护记忆的实现。因此不应将其称作多阶段认知编排，也不能从存在 Data Bank 名称推断有统一知识资产管线。

## 谱系定位与系统边界

| 机制 | 谱系与执行所有者 | 事实对象 | 本轮输出 |
| --- | --- | --- | --- |
| World Info | 上下文即时注入；核心 | 用户 World Info JSON 中的条目 | 按位置拆分的普通文本、示例消息或 outlet |
| Summarize | 上下文即时注入与被动记忆写回；内置扩展 | 聊天消息及某条消息的摘要字段 | 单一摘要文本 |
| Vector Storage | 一次性相似度召回；内置扩展加核心向量 API | 聊天消息/分块、文件分块、可选 Lorebook 条目 | 旧消息重排后的文本，或 Data Bank 文本块 |

核心将扩展提示按位置、深度和角色收集；同位置的多个槽按键名排序后拼接。槽可放在 prompt 前后或聊天深度，角色可为 system、user、assistant，但这只是文本组装契约，不是检索结果 schema。World Info 还可将内容放入示例消息、作者注释或命名 outlet；outlet 只保存为无注入位置的槽，是否被后续宏或扩展消费取决于消费者。见 `public/script.js:483-499,3242-3269` 与 `public/script.js:4576-4618`。

## 事实对象、摄取与存储

### World Info

**源码事实。** World Info 是每个用户 worlds 目录内的 JSON 文件，文件至少含 `entries`；服务端以清理后的文件名读写，编辑使用原子写入。条目可编辑、导入和删除；前端可将书绑定到角色、聊天、人格或全局选择。每个条目可以携带主/次关键词、常驻标记、角色和标签过滤、触发类型、概率、分组、计时效果、递归控制、内容位置及忽略预算标记。并非所有字段都在每次选择中使用，具体激活见下一节。见 `src/endpoints/worldinfo.js:17-35,71-156`、`public/scripts/world-info.js:1013-1029` 与 `public/scripts/world-info.js:4597-4796`。

### 摘要记忆

**源码事实。** Summarize 扩展不维护独立记忆库。它从当前聊天倒序找到最近一条 `extra.memory`，将新摘要写回倒数第二条消息或指定消息的同一字段，并触发聊天保存；聊天切换时则取最近摘要重新设定 prompt 槽。用户可直接编辑摘要、冻结自动摘要，或移除当前摘要以回退到上一份。这是聊天内的派生文本，不是逐条事实、实体或可检索向量。见 `public/scripts/extensions/memory/index.js:350-415,925-985`。

**源码事实。** 自动摘要只在聊天有新消息、未冻结、未在摘要或流式生成时考虑执行；达到消息间隔或强制词数阈值后，输入包含上一份摘要和之后的非系统消息，且会受摘要来源的上下文容量和每次最大消息数限制。摘要可调用主生成渠道、Extras summarize 或浏览器 WebLLM；主渠道可选择静默 prompt 或原始请求。当前聊天/角色/群组在请求期间改变时会丢弃结果。见 `public/scripts/extensions/memory/index.js:417-470,541-625,681-824`。

### 向量与 Data Bank

**源码事实。** Vector Storage 对聊天消息使用内容哈希作标识，可选先摘要，再按递归分隔符切成消息块；新消息写入索引，已从聊天删除的哈希会删除。索引项的元数据只有哈希、文本和原消息/块索引。服务端将索引落在当前用户的 vectors 目录，路径按 Embedding source、collection ID 和模型名分层，因此不同 source/model 不共用索引。后端使用 Vectra `LocalIndex` 做 top-K：metadata 会按相似度阈值过滤，但返回的 hashes 未过滤；聊天扩展消费 hashes，故聊天重排实际只受 top-K 限制。模型不会取得分数。见 `public/scripts/extensions/vectors/index.js:440-543` 与 `src/endpoints/vectors.js:300-392`。

**源码事实。** Data Bank 不是另一个由向量服务管理的资料表。它是三种附件清单的合并视图：全局设置、当前聊天元数据、当前角色的设置；附件记录 URL、大小、名称和创建时间，可被禁用。文件本体在用户 files 目录。向量扩展首次需要时按文件 URL 哈希建 collection，读取文件、按阈值选择整篇或分块入库；文件删除事件会清除该文件索引。见 `public/scripts/chats.js:1723-1786`、`src/endpoints/files.js:28-100` 与 `public/scripts/extensions/vectors/index.js:640-766,2085-2093`。

**源码事实。** 向量扩展还可索引已选 World Info 中带 `vectorized` 标记的条目，或在“all”开关下索引全部有内容条目；collection 以书名哈希区分。这个功能召回条目后发出强制激活事件，仍由核心 World Info 负责最后的过滤、预算和文本落点，不能等同于直接把向量结果注入。见 `public/scripts/extensions/vectors/index.js:1623-1726`。

## 发送时激活、候选、预算与注入

### World Info 主链

**源码事实。** 生成前，核心以反序的消息文本及角色描述、人格、场景等全局扫描数据调用 World Info。扫描前会把所有标有 `scan` 的 extension prompt 放入扫描缓冲区。候选先排除禁用项、生成类型不符项、角色/标签不符项和计时抑制项；随后接受显式装饰器、外部强制激活、常驻项、仍处于 sticky 状态的项，或主关键词与可选次关键词逻辑命中的项。成功候选按 sticky 状态和书内排序进入概率与分组处理。见 `public/script.js:4562-4577` 与 `public/scripts/world-info.js:4597-4887`。

**源码事实。** 预算为最大上下文乘 `world_info_budget` 百分比，最少一 token，并受非零 `world_info_budget_cap` 截断。核心以 tokenizer 计数已递归加入的文本与本轮候选文本；达到预算后，普通条目不再加入，`ignoreBudget` 条目例外。递归开启且未溢出时，已激活且未禁止递归的内容会成为下一轮缓冲；还可为满足最少激活数推进扫描深度，或由最大递归轮数终止。概率失败、预算溢出和深度上限是该链的明确停止条件。见 `public/scripts/world-info.js:4620-4633,4881-5068`。

**源码事实。** 最终条目再依排序写入故事串前后、示例消息、作者注释、指定聊天深度和 outlet。核心把深度条目转换为 extension prompt；故事串的前后锚点和聊天深度均由通用 prompt 组装器消费。因而 World Info 的“候选”和“最终注入”不是同一概念，且 outlet 自身不会自动进入模型上下文。见 `public/scripts/world-info.js:5070-5162` 与 `public/script.js:4605-4675`。

### 摘要与向量主链

**源码事实。** 摘要槽名为 `1_memory`，内容可格式化并可配置在 prompt 或聊天深度、角色和是否参与 World Info 扫描。摘要写回通常发生在新消息事件之后，并不为本轮原始生成额外规划一个检索阶段；下一次生成读取的只是最近持久化摘要。摘要长度的可配置词数是生成指令约束，实际输出长度仍取决于所选摘要后端。见 `public/scripts/extensions/memory/index.js:105-115,953-985`。

**源码事实。** Vector Storage 是生成拦截器，默认加载顺序为 100。它在每次非静默发送先清空自己的聊天与 Data Bank 槽，再依开关处理文件、可选 World Info 向量激活和聊天检索。聊天查询把最近 `query` 条非附件文本拼接；保留末尾 `protect` 条消息，从同一聊天 collection 取 `insert` 个近邻，按近邻返回顺序重排，移除这些原消息并将其格式化文本写入 `3_vectors`。因此召回结果既增加 prompt 文本，也改变该次发送的历史消息序列。见 `public/scripts/extensions/vectors/index.js:769-869,895-924`。

**源码事实。** Data Bank 查询使用同一最近消息查询文本，在所有当前可用附件 collection 上做全局相似度排序、阈值过滤和 `chunk_count_db` 截断；随后又按原分块索引排序、按文本去重，套入模板并写入 `4_vectors_data_bank`。默认阈值为 0.25、Data Bank 取 5 块，均可配置；文件分块默认大小为 2500 字符，是否分块由 5 KiB 阈值决定。这里没有 token 计数或与 World Info 预算共享的硬预算，最终仍可能在总 prompt 组装时被上下文限制裁剪。见 `public/scripts/extensions/vectors/index.js:58-120,640-700` 与 `src/endpoints/vectors.js:407-437`。

## 作用域、安全、可观测与恢复

### 作用域与安全

**源码事实。** 服务器私有路由在向量、World Info 和文件路由之前安装用户数据中间件。未启用账号时所有请求使用默认用户目录；启用账号后从 session 取得用户并改用该用户目录。因此 World Info、文件和 Vectra 索引的磁盘位置以用户为边界，向量 collection 不能通过常规路由跨用户访问。Data Bank 的“全局”只指同一用户的全局设置，不是服务器所有用户共享的资料库。见 `src/server-startup.js:140-184`、`src/users.js:955-1018` 与 `src/endpoints/vectors.js:470-605`。

**源码事实。** 默认配置不监听外网，IP 白名单启用且只允许回环地址；账号、基本认证、CORS 代理、私有地址白名单默认关闭。若改为监听模式，启动安全检查要求启用白名单、基本认证或用户账号，否则会退出，除非明确覆盖。这个结论描述默认配置和启动检查，不代表部署后的反向代理、CORS、账号密码或第三方 Embedding 服务一定安全。见 `default/config.yaml:3-10,58-107,154-182` 与 `src/users.js:149-196`。

**静态推断。** 本次读取的路径将附件和 Lorebook 内容作为待嵌入及待注入的普通文本，没有发现对其内容进行“可信知识”标记、提示注入隔离或检索结果授权判定的专用层。选择远程 Embedding source 时，待索引文本和查询文本会经服务器转交该 source；应将资料内容的外发边界理解为所选 provider 与部署配置共同决定，而不是由向量索引自动隔离。检查范围为 `src/endpoints/vectors.js`、Vector Storage 和文件路由，未审计每个 provider 的传输、保留策略或网络部署。

### 可观测、失败与恢复

**源码事实。** World Info 在浏览器控制台记录每轮扫描、候选、概率和预算状态，发送后还发出激活事件；每轮扫描完成事件会暴露已激活条目、递归状态和预算对象给监听器。向量扩展记录索引、查询和命中文本，提供聊天索引数量/唯一哈希的 UI 标记，以及 Data Bank 搜索命令。它们是开发者控制台、提示和扩展事件级观察面；本次未找到内置的离线检索评测、A/B 对照、命中来源引用或持久化审计记录。见 `public/scripts/world-info.js:4879-5068,5155-5162` 与 `public/scripts/extensions/vectors/index.js:1501-1527,2125-2139`。

**源码事实。** 向量同步会跳过本轮摘要或插入失败的消息哈希，并提示可再次执行全量向量化；聊天切换、生成进行中或同步锁冲突会中止或延后同步。文件与聊天索引可由 UI、斜杠命令或删除事件清除。服务端捕获索引 JSON 解析错误时删除损坏索引并以一次 307 重试请求，索引可由原聊天/文件或 World Info 再次摄取重建；切换 Embedding model/source 会落入不同目录，不迁移旧索引。见 `public/scripts/extensions/vectors/index.js:203-274,440-543,1203-1289` 与 `src/endpoints/vectors.js:440-468`。

**源码事实。** 摘要写回经聊天保存，故服务重启后的恢复依赖聊天数据；编辑或重新生成附着该摘要的末条消息时，扩展会删除该字段，删除消息时则重新装载最近仍存在的摘要。当前实现没有摘要版本链、审批队列或后台整理任务。见 `public/scripts/extensions/memory/index.js:450-470,925-985`。

## 已确认边界与未验证事项

- **源码事实：** World Info 的递归是把已命中条目内容追加到下一轮关键词扫描缓冲区，不是调用 LLM 产生下一阶段查询；Vector Storage 的 World Info 向量命中只进入现有强制激活入口。
- **源码事实：** 向量后端仅做 Embedding KNN 与 top-K；单 collection 的 metadata 按阈值过滤，但聊天链实际消费未过滤 hashes。没有 BM25、关键词混合、reranker、多样性算法或结果反馈字段。Data Bank 多 collection 查询才在全局相似度排序后按阈值过滤，随后按原文块顺序拼接。
- **静态推断：** 多个扩展可在同一发送中写 prompt 槽，核心按槽键名排序拼接，且这些文本与故事串/历史共同占最终上下文；实际某一渠道的精确裁剪顺序需在生成渠道运行时验证。
- **运行缺口：** 未以真实聊天验证 World Info 的计时效果、概率、递归与 token 计数；未调用任何 Embedding provider，故未确认近邻质量、延迟、阈值效果、失败重试表现或不同模型索引兼容性。
- **运行缺口：** 未启动多用户、外网监听或反向代理配置，未验证 session、CSRF、白名单和文件路径检查在实际部署中的组合效果；也未审计第三方扩展，它们可注册额外拦截器或监听 World Info 扫描事件。

## 关键源码索引

- `public/script.js:4500-4675`：生成拦截器、World Info 调用和 extension prompt 注入。
- `public/scripts/world-info.js:4597-5162`：World Info 候选、预算、递归、事件及输出位置。
- `public/scripts/extensions/memory/index.js:417-985`：摘要触发、上下文构造、写回和恢复。
- `public/scripts/extensions/vectors/index.js:440-869,1623-1726,2085-2139`：同步、聊天/Data Bank/World Info 向量选择及生命周期。
- `src/endpoints/vectors.js:300-605`：按用户、source、collection、model 落盘的 Vectra 索引和损坏重建。
- `src/endpoints/worldinfo.js:17-156`、`src/endpoints/files.js:28-100`、`src/users.js:955-1018`：资料文件、World Info 和用户目录边界。
