# AIO-Hub 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`（分支：`dev`）
>
> 调查方式：以对话请求与上下文调查笔记已复查的源码路径和结论为唯一依据，重组规则对象、编译顺序与消费面的专题记录；未新增源码或运行时调查
>
> 调查范围：世界书、会话变量、Recall 占位符、上下文压缩、管道中的正则和预设注入在请求编译中的已确认交接；不覆盖规则编辑器实现、Provider 协议转换、会话 CRUD、检索和工具执行内部语义
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- AIO-Hub 把请求上下文交给可排序、可启停的 11 个处理器编译；用户调整后的启用状态和顺序持久化在 `llm-chat/pipeline-settings.json`。会话历史先由加载器应用压缩遮罩，之后才进入该管道。
- 已确认实际参与请求层编译的规则对象包括：世界书的匹配和位置注入规则、会话变量标签与读取宏、Recall 严格占位符，以及压缩节点对历史的遮罩和摘要替换。正则处理器与预设注入组装已确认位于管道中，但原笔记未覆盖其对象 schema、具体顺序规则及最终产物，不能据此补全。
- 同一编译链的结果有不同去向：世界书、变量、Recall、转写和附件处理后的消息供模型请求消费；压缩节点还改变后续历史的选择结果。原笔记只确认压缩状态在消息列表的视觉标记，未确认正则、世界书或变量存在仅作用于显示层的规则分流。
- 上下文分析器重跑接近真实请求的管道以供预览，并重新计算产出消息的 Token；这不是纯静态预览，附件存在时可能触发或等待转写。最终 Provider payload 的消息转换未被原调查覆盖，预览不能替代该层的实证。

## 系统边界与规则编译主链

```text
活动分支历史
  -> session-loader：收集启用压缩节点的遮罩 ID，跳过原消息并保留摘要
  -> 按 priority 的已启用处理器：异步结果、正则、转写、世界书、预设、Recall、变量、Token 限制、格式化、附件
  -> useChatExecutor / useSingleNodeExecutor 请求模型

上下文分析器
  -> getLlmContextForPreview
  -> 尽量复用同一 Agent、用户档案、世界书、附件和整条管道
  -> 重新计算产出消息的 Token
```

主链的历史选择在 `src/tools/llm-chat/core/context-processors/session-loader.ts:105-153`，处理器注册、排序和启停在 `src/tools/llm-chat/stores/contextPipelineStore.ts:49-219`。对话提交、任务状态、流式消费和最终回写属于[对话请求与上下文笔记](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md)；会话节点和压缩节点的存储、重挂与删除语义属于会话与消息管理；检索和工具的内部执行不在本专题展开。

## 1. 规则对象、权威源与作用域

### 世界书

世界书是本次已确认具有丰富选择条件的规则对象。运行时处理器合并全局、用户档案和 Agent 绑定的世界书，再执行关键词、正则、常量或选择性条目、概率、扫描深度、角色/名称/标签过滤、递归、延迟递归、sticky、cooldown、delay、包含组和加权选择，最后按严格 depth 或降级 anchor 注入。`st-worldbook-manager` 提供编辑、持久化、JSON/`.lorebook`、角色卡 PNG 与 AIO Bundle 的导入导出，以及与 Agent、用户档案的绑定；已确认的实际消费主链是 `worldbook-processor`，而不是仅存在于兼容数据中的字段（`src/tools/llm-chat/core/context-processors/worldbook-processor.ts`）。

原笔记同时确认 SillyTavern V2/V3 角色卡、`prompt_order` 和部分正则/宏可被解析，且世界书支持的是兼容字段的可运行子集。但世界书条目的完整 schema、版本字段、导入导出的冲突处理，以及哪些 ST 扩展字段仅能表示或编辑而不被运行时消费，均未在原笔记逐项核实。

### 会话变量与 Recall 占位符

会话变量由 Agent 的 `variableConfig` 启用。变量处理器在活动分支上从最近的 `metadata.sessionVariableSnapshot` 起点回放：消息中的 `<svar ... />` 标签可赋值或做四则运算，并按变量定义的最小/最大值截断；`$[player.hp]` 读取单项，`$[svars::json|table|list]` 输出全部非隐藏变量。发生变更的消息写入快照，压缩节点即使无新增变更也会写入锚点快照，因此分支切换后能够按该分支历史重建变量状态（`variable-processor.ts`，priority 500）。变量定义的持久化位置、导入导出和同名变量冲突规则未确认。

Recall 处理器只识别 `【recall::...】` 严格占位符协议，并先校验编码、参数和数值范围，再执行检索和替换。若 Agent 配置 `autoInjectIfMacroMissing`，未被引用的绑定可自动在 `context_head` 或 `before_last_user` 位置补入占位符。旧 `【kb::...】` 与 `【knowledge::...】` 只记录已废弃警告，不再执行检索（`recall-processor.ts:151,180`；`recall-placeholder.ts`）。资料索引、查询、候选和重排仍属于检索增强专题。

### 压缩节点、正则与预设

上下文压缩是 Agent 参数 `LlmParameters.contextCompression` 控制的规则化历史变换，生效优先级为调用参数、当前选中 Agent 配置、默认值。它创建带 `metadata.isCompressionNode=true` 的普通消息树节点，记录被遮罩节点 ID 和本次统计；原消息不会删除。已启用的压缩节点由会话加载器消费，决定哪些历史消息退出请求上下文、哪个摘要进入上下文。压缩节点可编辑摘要、切换角色、启用/禁用或删除；禁用会让原消息重新进入上下文。相关执行见 `useContextCompressor.ts:422-617` 与 `session-loader.ts:105-153`。

正则处理器（priority 200）和预设注入组装（priority 400）均在默认管道中。原笔记没有确认其规则对象的权威源、作用域、匹配/冲突策略、变量展开、持久化或导入导出语义；本笔记仅记录其已位于请求前处理器序列，不能把该事实解释为任何具体的提示词编译行为。

## 2. 选择条件、优先级与编译顺序

管道取 `contextPipelineStore` 的已启用处理器，按 `priority` 排序后执行；配置 UI 中的用户调整结果持久化到 `llm-chat/pipeline-settings.json`。当前默认顺序如下，其中会话加载先于管道，用于完成历史选择与压缩遮罩：

| 阶段 | 处理器 | priority | 本专题已确认的作用 |
| --- | --- | ---: | --- |
| 管道前 | 会话加载 | 100 | 回溯活动路径，应用压缩遮罩 |
| 管道 | 异步任务结果 | 110 | 本专题未展开 |
| 管道 | 正则 | 200 | 已确认参与管道，规则语义未确认 |
| 管道 | 转写/文本提取 | 250 | 以转写文本或文本提取替换附件/占位符 |
| 管道 | 世界书 | 300 | 按匹配条件选择并按位置注入 |
| 管道 | 预设注入组装 | 400 | 已确认参与管道，注入语义未确认 |
| 管道 | Recall | 450 | 校验、检索并替换 Recall 占位符 |
| 管道 | 会话变量 | 500 | 回放变量变更并展开标签/宏 |
| 管道 | Token 限制 | 600 | 本专题未展开 |
| 管道 | 消息格式化 | 800 | 本专题未展开 |
| 管道 | 附件解析 | 10000 | 在末端处理请求用的附件 buffer |

世界书内部存在主/次关键词、正则、概率、过滤、递归、延迟、sticky/cooldown/delay、分组和权重等命中条件，并在选择后按 depth 或 anchor 定位。原笔记未给出这些条件之间的完整判定先后与多个条目的最终合成规则。Recall 的自动补入只在 `autoInjectIfMacroMissing` 为真且绑定未被引用时发生；会话变量只沿活动分支回放。压缩则只处理 `activeLeafId` 所在路径，且保留最近消息保护区，不跨分支遮罩。

## 3. 请求层编译与模型可见结果

模型请求并不直接使用活动路径原消息数组。会话加载器先进行两遍回溯：第一遍收集所有已启用压缩节点遮罩的 ID，第二遍跳过这些原消息并保留摘要节点；同时可把 tool 角色转为 user、限制某些 reasoning 内容，并可选将旧 HTML 转为 Markdown。随后管道按上节顺序继续处理，最终交给 `useChatExecutor` 或 `useSingleNodeExecutor` 执行请求（`session-loader.ts:105-153`；`useChatExecutor.ts:86-508`；`useSingleNodeExecutor.ts:82-374`）。

已确认进入这条请求编译链的结果包括世界书注入、Recall 检索结果替换、变量读写宏展开、转写/文本提取、附件请求 buffer 处理和压缩摘要。附件末端处理只改请求所用的图片 buffer，不改资产管理器保存的原文件。压缩的摘要由独立 LLM 请求生成，成功后作为普通消息树节点供后续会话加载消费；连续压缩会把最近的已启用摘要作为 `previous_summary` 传给续写模板，并将旧摘要一起遮罩。

最终 SDK 消息转换、渠道/Profile 解析和 Provider payload 构造未在原笔记中核实。因此“处理器产出交给请求执行器”是已确认的请求层交接，最终网络负载的精确消息形状未确认。

## 4. 消息生命周期变换与交接

压缩是已确认会改变后续权威历史选择的规则结果，但不删除原消息。成功生成摘要后，压缩节点插入被压缩批次最后一条消息之后，原子节点整体转挂到摘要节点下；摘要元数据保存遮罩 ID、原消息/Token 统计、触发配置和时间。会话加载只据已启用的压缩节点遮罩原消息，因而禁用该节点即可恢复原消息进入后续上下文。压缩成功会持久化会话并刷新上下文 Token 统计（`useContextCompressor.ts:283-415,519-623`）。

会话变量处理器则在编译过程中解释历史消息中的变量变更，并把快照写在发生变更的消息上；压缩节点作为变量回放锚点。原笔记确认这一状态可在变量快照和上下文分析器的变量状态视图中查看，但没有确认变量标签是否会改写原消息正文，或变量计算结果是否单独写回为新的权威消息字段。

世界书、Recall、正则和预设注入的已确认消费点是请求管道。原笔记未确认它们会在生成前后改写消息树、生成内容或后续历史，因此不将其推定为消息写回规则。

## 5. 显示层投影与消息渲染器交接

压缩节点有已确认的显示投影：线性消息列表以半透明样式标记已被压缩的原消息；该标记不等于删除，也不决定是否进入模型上下文，实际分流条件是压缩节点是否启用，并由会话加载器应用。摘要的编辑、角色切换和启停是压缩节点界面能力，具体 DOM 与渲染状态属于消息渲染器和 Chat UI 范围。

原笔记没有确认世界书、Recall、变量、正则或预设规则存在只变换 Markdown、文本或 DOM 而不影响权威消息和请求的显示层作用点。也没有确认它们与显示层共用配置时的分流条件。本次不能据处理器名称或编辑能力推断显示层改写。

## 6. 调试、预览与可解释性

上下文分析器通过 `getLlmContextForPreview()` 以所选节点为路径终点，尽量复用实际请求的 Agent、用户档案、世界书、附件和整条管道，并对处理器产出的每条消息重新计算 Token。因此它是接近真实编译链的预览，而不是静态读取缓存统计（`useChatHandler.ts:924-993`；`useChatExecutor.ts:284-508`）。

该预览不完全无副作用：构建时发现附件会调用 `ensureTranscriptions()`，可能发起或等待缺失的转写任务。原笔记没有确认预览是否展示世界书命中明细、变量展开前后差异、Recall 参数、正则结果、单个处理器 trace，或最终 Provider payload；也没有确认预览与实际请求在所有异常和异步条件下完全一致。

## 7. 失败、更新与已确认边界

压缩的两个自动检查点都会捕获压缩错误，摘要请求失败不阻断正常聊天。其自动判断需同时满足启用、自动触发和最小历史数；`token`、`count` 与 `both` 三种触发模式中，`both` 是任一阈值严格超出即触发。手动压缩跳过自动开关和阈值，但仍受最近消息保护区约束。压缩节点若遮罩的消息含 provider reasoning artifacts，会标记 `reasoningStateStatus: "broken"` 并记录警告，原因是后续请求不再回放隐藏消息的 reasoning 状态。

连续压缩的旧摘要定位、续写模板、继承统计和一并遮罩链路已由静态代码确认，且仓库架构文档已与实现同步。`savedTokenCount` 是被遮罩消息的原 Token 总数，不扣除新摘要自身 Token，不能解释为严格的净节省量。

原笔记还确认一个状态依赖边界：有效压缩配置、摘要模型和优先 Token 统计依赖前台当前 Agent/会话的全局状态，而非按目标后台会话解析。在多会话并行生成且切换 Agent 或会话时，后台压缩理论上可能采用前台配置或统计；这是代码结构可确认的潜在风险，实际误压缩结果未运行复现。

## 8. 未验证事项

- 世界书、正则、预设、变量和 Recall 的编辑器交互、持久化 schema、版本迁移及导入导出往返均未运行验证；其中正则和预设的权威源与运行细节也未由原笔记静态确认。
- 多个世界书条目在关键词、正则、概率、递归、延迟、分组与权重同时命中时的精确排序和冲突结果未验证。
- 变量宏与写入标签在多分支、压缩节点、缺失变量和运算错误组合下的实际展开、写回及错误收口未验证。
- 上下文分析器预览与实际请求的差异、异步转写对预览的影响，以及是否提供单处理器命中/差异/trace 未验证。
- 最终 Provider payload 是否完整携带管道结果、SDK 转换后的角色和 system prompt 形状未核实。
- 多会话并行生成时压缩配置与 Token 统计错位导致的实际误压缩未复现。

## 9. 关键源码索引

- `src/tools/llm-chat/stores/contextPipelineStore.ts:49-219`：处理器注册、启停和 priority 排序。
- `src/tools/llm-chat/core/pipeline/defaultProcessors.ts`：默认处理器序列。
- `src/tools/llm-chat/core/context-processors/session-loader.ts:105-153`：活动路径回溯和压缩遮罩后的请求历史。
- `src/tools/llm-chat/core/context-processors/worldbook-processor.ts`：世界书匹配与位置注入的运行时入口。
- `src/tools/llm-chat/core/context-processors/variable-processor.ts`：会话变量回放、标签和宏展开。
- `src/tools/llm-chat/core/context-processors/recall-processor.ts`、`recall-placeholder.ts`：Recall 占位符校验、自动注入与替换。
- `src/tools/llm-chat/composables/features/useContextCompressor.ts:45-642`：压缩配置、触发、摘要、遮罩和持久化。
- `src/tools/llm-chat/composables/chat/useChatExecutor.ts:284-508`、`useChatHandler.ts:924-993`：上下文分析器复用请求管道的预览入口。
- `src/tools/llm-chat/composables/chat/useSingleNodeExecutor.ts:82-374`：编译结果交接到单次模型请求执行。
