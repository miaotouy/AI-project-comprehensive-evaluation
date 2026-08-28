# Risuai 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`e565563a288ebe4c65b6099a1645ba477d1c84b4`（分支：`main`）
>
> 调查方式：直接静态阅读当前 Risuai 工作树的 TypeScript/Svelte 源码、数据结构和持久化路径；未启动应用，未实际调用摘要或 Embedding 模型
>
> 调查范围：Lorebook 的对象、激活、排序与注入；SupaMemory、Hypa V2、Hypa V3、HanuraiMemory 的索引、选择、写回和恢复；发送阶段、预算、作用域与观察面。不覆盖附件检索、触发器、工具调用和其他笔记中的最终渠道请求细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 在本类目属于“上下文即时注入”与“对话记忆压缩/语义召回”的组合，而非知识资产摄取管线或检索驱动认知编排。发送前，Lorebook 将角色级、当前聊天级和已启用模块级条目合并，按最近消息的关键词或正则条件激活，再按优先级在 Token 预算内筛选并插入提示词。该链路是规则匹配和递归触发，不使用 Lorebook 向量索引。`src/ts/process/lorebook.svelte.ts:75-664`

聊天记忆由同一发送入口按配置互斥选择 HanuraiMemory、Hypa V2、Hypa V3 或 SupaMemory。Hanurai 在启用时直接从当前历史召回；其余引擎在上下文超额或已有摘要时压缩旧消息或选择摘要片段。它们均构造 system 消息，SupaMemory 与 Hypa V2/V3 会写回当前聊天对象。Hypa V2/V3 和 Hanurai 使用 Embedding 相似度；Hypa V3 还将重要、最近、相似和随机四类摘要按预算融合。`src/ts/process/index.svelte.ts:1068-1139`

静态代码没有显示模型根据检索结果生成下一阶段查询、维护关系图、执行后台记忆复盘，或以阶段性检索路径作为结果契约。因此这些实现可与 Lorebook、摘要记忆和语义历史选择作局部比较，不能据此称为多阶段认知编排。上述判断是对本次所读 Lorebook、发送和 memory 目录入口的静态推断，不代表未检查目录中绝对不存在相关扩展。

## 谱系定位与系统边界

| 谱系 | 当前静态事实 | 边界 |
| --- | --- | --- |
| 上下文即时注入 | Lorebook 根据聊天文本规则激活，将条目置入常规 Lorebook、角色描述周边、历史深度或指定模板位置。 | 条目来自应用内数据、角色/聊天配置或模块，不是文档上传、切块和发布的知识库。 |
| 对话摘要压缩 | SupaMemory 与 Hypa V2/V3 在 Token 压力下调用本地摘要器、旧 OpenAI completion 或辅助模型，将较早消息变为摘要。 | 摘要质量、模型响应和压缩是否可逆均未运行验证；代码中的摘要文本持久化会覆盖或替代先前上下文。 |
| 语义历史选择 | Hanurai 对历史消息，Hypa V2 对摘要分块，Hypa V3 对摘要分块计算 Embedding 相似度。 | 召回结果仅服务当前请求的 system 上下文，不形成下一轮检索计划或可追踪路径。 |
| 主动记忆演化 | 本次未找到无新消息即可运行的后台整理入口；四种引擎都由发送过程调用。 | 此结论仅覆盖 `src/ts/process/index.svelte.ts` 与 `src/ts/process/memory/` 的检索。 |

## 事实对象、摄取与索引

### Lorebook

Lorebook 的可持久化条目包含主/次关键词、内容、注释、插入顺序、常驻与选择性标记、正则开关、条目 ID、目录等字段。角色保存 `globalLore`，聊天保存 `localLore`；模块可携带 `lorebook` 数组。发送时按“角色、当前聊天、已启用模块”的顺序连接并克隆为一次候选集，模块来源由已启用模块列表解析。`src/ts/storage/database.svelte.ts:1320-1341`，`src/ts/storage/database.svelte.ts:1817-1841`，`src/ts/process/lorebook.svelte.ts:75-86`，`src/ts/process/modules.ts:430-442`

条目可由侧栏新建；导入入口接受 Risu 自有 JSON 或外部 entries 格式，导出写出自有格式。外部条目被归一为关键词、优先级、内容、常驻和选择性字段，因此本实现的摄取是结构化 Lorebook 条目转换，不包含文件分段或 Embedding 建索引。`src/ts/process/lorebook.svelte.ts:16-72`，`src/ts/process/lorebook.svelte.ts:668-765`

### 聊天记忆

四种记忆都以当前聊天的消息及聊天级数据为事实源。SupaMemory 保存带消息锚点的字符串；Hypa V2 保存主摘要、由主摘要切分的检索分块及每个摘要对应的消息 ID；Hypa V3 保存摘要、对应消息 ID、重要标记、分类、标签和最近一次入选分组；Hanurai 不定义聊天级向量对象，而是在每次调用中从传入的聊天消息建立内存向量集合。`src/ts/process/memory/supaMemory.ts:45-136`，`src/ts/process/memory/hypav2.ts:15-37`，`src/ts/process/memory/hypav3.ts:53-99`，`src/ts/process/memory/hanuraiMemory.ts:16-40`

Hypa 的 Embedding 处理器会把向量缓存进名为 `hypaVector` 的 LocalForage 实例；V2 版本的缓存键含文本、Embedding 模型、自定义模型后缀，以及上下文模型的上下文后缀。缓存命中后再附加本次运行的元数据。这个缓存减少重复嵌入，但当前可见键不含角色或聊天 ID；记忆结果的作用域仍由调用时提供的聊天摘要/消息集合决定。`src/ts/process/memory/hypamemoryv2.ts:30-48`，`src/ts/process/memory/hypamemoryv2.ts:133-169`，`src/ts/process/memory/hypamemoryv2.ts:371-384`

Embedding 可来自本地 Transformers 模型（WebGPU 或 WASM）、OpenAI Embeddings、自定义兼容端点，或上下文 Embedding provider。API 批次由限流器调度；本地与 API 的实际载入、网络失败和缓存命中效果未运行验证。`src/ts/process/memory/hypamemoryv2.ts:200-352`，`src/ts/process/memory/hypamemoryv2.ts:418-503`

## 查询、候选与重排主链

### Lorebook 激活与候选筛选

Lorebook 查询入口是发送过程中的 `loadLoreBookV3Prompt`。默认只扫描最近设定深度内的聊天；用户和角色消息被转换为带来源标签的待匹配文本。普通匹配会忽略大小写及空格，可按配置使用空格分词的全词匹配；正则条目对原消息数据执行 JavaScript 正则。主关键词必须命中，选择性次关键词和额外关键词会加入同一组条件，排除关键词命中则取消激活。匹配日志保留命中的文本来源及关键词。`src/ts/process/lorebook.svelte.ts:100-230`，`src/ts/process/lorebook.svelte.ts:518-555`

激活条目可通过内容装饰器改变扫描深度、消息角色、插入位置、概率、优先级和强制开关，也能设置“仅第 N 轮后”或“每 N 轮”条件。全局或逐条递归启用时，已激活条目的内容会加入后续候选的匹配语料，直至没有新条目可激活；聊天变量记录“命中后保持激活/禁止激活”的状态。该反馈只扩大本次 Lorebook 的规则匹配候选，不产生新的 LLM 回合或语义查询。`src/ts/process/lorebook.svelte.ts:299-515`，`src/ts/process/lorebook.svelte.ts:565-605`

候选先按优先级降序，以条目经模板解析前的 Token 数累加，超过角色级或全局 Lorebook 预算即排除；随后按插入顺序重排。带 Lorebook 注入标记的条目可追加、前置或替换另一条同来源条目的文本，但实现明确承认该合并后不会重新计数 Token。`src/ts/process/lorebook.svelte.ts:608-664`

### 语义候选与评分

Hanurai 将除最近四条以外的非空消息作为候选；可按空行拆分。它以最近三条消息逐条查询所有候选，较新的查询权重更高（第 i 条结果除以 i），将相同文本的分数累加、降序排列，跳过仍在当前历史中的原文，再在预留预算内加入结果。`src/ts/process/memory/hanuraiMemory.ts:8-100`

Hypa V2 把主摘要按空行分块并向量化，以最后三条聊天分别查询；每路得分按距离末尾的序号衰减后累加。主摘要按时间顺序占用分配预算的一半，余下空间从语义候选最高分起填入，最后以“摘要”和“细节”两个 XML 区块封装。`src/ts/process/memory/hypav2.ts:562-668`

Hypa V3 先排入用户标记为重要的摘要，再从最新摘要开始取“最近”份额。它把尚未入选的摘要按分隔符切块，最近聊天按空行拆为多个查询并按新近程度加权；普通实现可额外把这些最近聊天概括为一个查询。分块余弦相似度先以加权组合合并，再经子分块到父摘要的 reciprocal-rank fusion 聚合；余下预算可随机抽取未选摘要，最终按原摘要顺序输出。实验实现采用新的 V2 Embedding 处理器及批量查询，普通实现使用旧处理器；两者共享这一选择结构。`src/ts/process/memory/hypav3.ts:1238-1467`，`src/ts/process/memory/hypav3.ts:600-849`，`src/ts/process/memory/hypamemoryv2.ts:55-103`

这不是独立 reranker 服务：评分、加权与父级聚合均在客户端内存中完成，输出对象不携带原始相似度、查询文本或逐项分数。Hypa V3 仅保存四种最终入选摘要的索引，供界面标记。`src/ts/process/memory/hypav3.ts:871-935`，`src/lib/Others/HypaV3Modal/modal-summary-item.svelte:404-434`

## 阶段、反馈与结果注入

发送编排先计算 Lorebook，构造描述与普通 Lorebook 区块，再将深度 Lorebook 置入历史。随后完成聊天历史的格式化和 Token 累计，才进入记忆阶段；代码记录阶段 1/2 耗时并把 UI 阶段状态切为 2，记忆返回后切回 1。`src/ts/process/index.svelte.ts:498-644`，`src/ts/process/index.svelte.ts:1054-1140`

记忆引擎在角色开关开启且至少有一个相应总开关配置时才运行，分支优先级固定为 Hanurai、Hypa V2、Hypa V3、SupaMemory。它们不是串联阶段：同一发送仅调用其中一个。SupaMemory 的 Hyper 模式是其内部额外相似度检索，不是该顶层分支的第五种独立引擎。`src/ts/process/index.svelte.ts:1068-1137`，`src/ts/process/memory/supaMemory.ts:139-170`

各引擎返回的记忆统一作为 `memo` 为 `supaMemory` 或 `hypaMemory` 的 system 消息放在聊天数组开头。之后格式化器将普通历史标为可移除，而将记忆包裹为 Previous Conversation 或置入记忆卡；深度 Lorebook 随后按位置插入。故检索/摘要的最终契约是 prompt 内 system 文本，而不是面向模型调用的检索工具结果、来源引用或 Artifact。`src/ts/process/memory/hanuraiMemory.ts:92-100`，`src/ts/process/memory/hypav2.ts:626-641`，`src/ts/process/memory/hypav3.ts:928-935`，`src/ts/process/index.svelte.ts:1160-1195`

摘要失败、Embedding 失败或无法继续压缩时，Hypa V2/V3 和 SupaMemory 向发送入口返回错误；入口显示错误并中止本次生成。Hypa V3 在错误结果仍携带新摘要时先写回该结果，再终止。Hanurai 在裁剪到空历史仍超预算时显示 Token 错误并返回 `false`。这是可见的失败边界；网络重试、用户取消和模型服务实际错误格式未运行验证。`src/ts/process/index.svelte.ts:1086-1134`，`src/ts/process/memory/hypav2.ts:469-508`，`src/ts/process/memory/hypav3.ts:1040-1055`，`src/ts/process/memory/hanuraiMemory.ts:63-70`

## 记忆写回与主动维护

SupaMemory 仅在输入超过上下文时处理：先尝试根据保存的消息 ID 复原摘要锚点，再逐块总结早期历史；达到一定摘要段数后又概括已有摘要。结果保存为“最后消息 ID 加摘要”字符串；Hyper 模式则保存 JSON 化的摘要与可检索分块。`src/ts/process/memory/supaMemory.ts:23-136`，`src/ts/process/memory/supaMemory.ts:286-421`

Hypa V2 在 Token 压力下保留末尾消息，把较早消息按 `hypaChunkSize` 分批摘要；每个主摘要记录来源消息 ID，分块后用于检索。调用开始时会清除来源消息已不再存在的摘要及其子块，也能将旧格式转换为新格式。`src/ts/process/memory/hypav2.ts:188-297`，`src/ts/process/memory/hypav2.ts:399-560`

Hypa V3 同样只在发送的预算压力下生成摘要，允许预设决定每摘要最多消息数、保留的查询消息数、是否跳过用户消息和额外压缩比例。摘要关联消息 ID；若未设置保留孤儿记忆，则调用时删除来源消息已消失的摘要。摘要可在界面中编辑、重置、设置重要性、分类和标签，属于用户直接修改已有记忆数据，不是自动事实抽取的审批流。`src/ts/process/memory/hypav3.ts:176-209`，`src/ts/process/memory/hypav3.ts:240-465`，`src/lib/Others/HypaV3Modal.svelte:180-279`

发送入口将 SupaMemory、Hypa V2/V3 的返回数据直接赋给当前角色当前聊天的字段。数据库自动保存逻辑观察当前聊天数组和角色数据的快照，经 500 ms 防抖后编码并写入桌面文件或 Web LocalForage，同时保留备份；因此写回是聊天级持久化而非独立服务端记忆库。实际保存时序、崩溃窗口和多标签冲突恢复未运行验证。`src/ts/process/index.svelte.ts:1094-1137`，`src/ts/globalApi.svelte.ts:292-485`

## 预算、作用域、可观测与恢复

| 维度 | 静态实现 | 已确认边界 |
| --- | --- | --- |
| 预算 | Lorebook 以 `loreBookToken` 或角色覆盖值筛选；Hanurai 预留 `hanuraiTokens`；Hypa V2 使用分配 Token 与摘要分块大小；Hypa V3 从最大上下文按记忆、最近、相似和随机比例切分。 | Lorebook 的条目内合并可能令实际 Token 高于筛选计数；各预算在不同引擎独立计算。 |
| 作用域 | Lorebook 读取当前角色、当前聊天与当前启用模块；记忆读写当前聊天字段。 | 本次未发现用户/租户 ACL 或跨设备服务端检索授权层；这不等同于断言应用其他数据层不存在权限机制。 |
| 观察面 | Lorebook 返回匹配日志；发送和记忆代码大量写入 console。Hypa V3 有排队/搜索进度 store，并保存最后一次四类入选索引供模态框显示。 | 未找到持久化的查询、候选分数、逐阶段路径、离线评测或 A/B 入口；本次未运行开发者工具和界面。 |
| 节流与取消 | 实验 Hypa V3 的摘要及 Embedding 使用每分钟和并发上限的队列；队列遇失败可取消待执行任务。 | 普通 V3、V2、Hanurai 和 SupaMemory 不共享这一可配置队列；发送级取消如何传播到已发出的请求未确认。 |
| 恢复 | Hypa V2 可转换旧数据并清除失效来源；Hypa V3 按预设决定是否清除孤儿摘要；Embedding 缓存键区分模型。 | 未看到自动重建聊天记忆摘要或缓存清理策略；删除/迁移后实际缓存与持久化表现未运行验证。 |

## 与相邻谱系的可比/不可比边界

Risuai 可在“规则激活的上下文注入”维度同样比较 Lorebook 的作用域、递归、优先级和 Token 截断；可在“历史语义选择”维度比较摘要对象、Embedding、候选融合和结果注入。Hypa V3 的多路选择属于一次发送内的候选融合，不是查询阶段递进。

不宜将其与知识资产管线直接比较摄取任务、文档权限、引用溯源和索引发布，因为本次确认的资产是角色/聊天/模块条目与聊天历史。也不宜归为检索驱动认知编排：本次所读路径没有根据候选重写下一阶段查询、沿关系图传播、让模型决定检索工具调用，或将检索结果反馈为新的思维模块。

## 未验证事项

- 未运行任何 Lorebook 配置，故关键词边界、正则异常、递归终止、概率激活及各插入位置的最终 prompt 效果仅为源码事实对应的预期路径。
- 未调用摘要模型或 Embedding provider，未验证本地模型下载、WebGPU/WASM 回退、远程 API 兼容性、限流、缓存命中和失败提示。
- 未验证四种引擎的开关组合、分支优先级在实际 UI 中是否可同时配置，及记忆失败后聊天数据是否按预期保留。
- 未检查所有数据库迁移、导入导出和冷存储路径，因而不对旧存档、模型切换、跨设备同步或删除后的端到端恢复作运行结论。
- 本次未找到检索质量评测、延迟基准、召回指标或来源引用展示；该结论基于所读发送、memory、Lorebook 与 Hypa V3 UI 路径的静态搜索范围。

## 关键源码索引

- `src/ts/process/lorebook.svelte.ts:75-664`：三源条目合并、规则激活、递归、预算和匹配日志。
- `src/ts/process/index.svelte.ts:498-644`、`1054-1195`：Lorebook/记忆进入发送上下文的顺序、互斥引擎分支、错误终止和最终格式化。
- `src/ts/process/memory/supaMemory.ts:12-428`：摘要压缩、Hyper 模式检索与字符串写回结果。
- `src/ts/process/memory/hypav2.ts:335-669`：V2 摘要、Embedding 召回和提示词构造。
- `src/ts/process/memory/hypav3.ts:118-952`、`955-1467`：V3 普通/实验实现、候选融合、预算选择和入选指标。
- `src/ts/process/memory/hanuraiMemory.ts:8-103`：原消息的多查询语义召回。
- `src/ts/process/memory/hypamemoryv2.ts:30-503`、`taskRateLimiter.ts:20-188`：Embedding 缓存、批处理、相似度和限流队列。
- `src/ts/storage/database.svelte.ts:1320-1341`、`1817-1841`，`src/ts/globalApi.svelte.ts:292-485`：事实对象与聊天级自动持久化。
