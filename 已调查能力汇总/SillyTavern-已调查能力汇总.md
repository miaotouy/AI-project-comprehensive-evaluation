# SillyTavern 已调查能力汇总

> 汇总对象：`SillyTavern`
>
> 汇总更新日期：2026-11-05
>
> 依据：Agent工具、Agent角色、Chat、Chat UI、LLM渠道管理、仓库分布、会话与消息管理、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时、检索增强与认知编排、媒体创作共 15 份 SillyTavern 调查笔记（代码快照均为 `06bde939`，分支 `release`）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留来源证据状态标记并链接来源；不做新的源码调查
>
> 汇总范围：以上述来源笔记为准的已调查能力摘要；功能能力按主题聚类，仓库分布与应用界面基础设施结论放入工程与基础设施摘要小节；不覆盖上述清单之外的未调查类目，不做跨项目横向比较
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

SillyTavern 是自托管式 Web 聊天应用（浏览器客户端 + Node 服务端），核心聊天状态驻留前端内存、整份序列化到 JSONL 文件；模型推理由外部 LLM Provider 承担，服务端只做请求代理与文件/API 服务。角色卡、World Info、swipe、正则、STscript、群聊、工具调用与渲染链已被多类目深度覆盖，独特能力集中在"以模板编排为中心的提示词工程工作台"与扩展生态两个方向。所有笔记基于同一代码快照（`06bde939fb1e9c4c8d8641d810f0a916b5bce127`，分支 `release`）。

## 完成度速览

| 证据状态 | 条目数 |
|---|---|
| 主链确认 | 30 |
| 入口确认 | 2 |
| 归并已有类目 | 3 |
| 声明不符 | 1 |
| 暂缓 | 0 |
| 合计 | 36 |

其中"主链确认"含独特功能笔记显式标记的 2 项，以及其余 28 项来源笔记以"结论摘要/静态源码确认"给出的能力结论。已确认与已归并合计 33 项（约 92%）；入口确认 2 项与声明不符 1 项合计 3 项（约 8%）属待闭合或与声明不符的边界，集中在文末"已知边界与待验证事项"。另含 1 条特色贡献建议，不计入能力条目。

证据口径：本汇总的“主链确认/静态源码确认”表示已在当前代码快照复查入口、状态、执行与结果处理构成的实现路径；SillyTavern 的浏览器客户端与本地 Node 服务构成完整本地主链。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效。

## 功能能力摘要

### 角色与上下文

- **角色卡格式体系（V1/V2/V3）**：角色以遵循 Tavern Card 规范的角色卡为单位，提示词按描述、人格、场景、示例、系统提示与历史后指令等语义字段分开存放，`extensions` 留作开放扩展点，`character_book` 可以内嵌世界书；导入支持 PNG（tEXt 内嵌元数据）、JSON、CharX 与 BYAF 四种格式，V1 格式的角色卡在导入时自动升级。来源 [Agent 角色配置调查笔记](../Agent角色/SillyTavern-Agent角色配置调查笔记.md)。
- **开场白生命周期**：`first_mes` 与 `alternate_greetings` 在创建会话时实例化为消息与 swipes，首次生成后 `tainted` 固化、不再跟随角色卡修改，备选以 swipe 呈现且无"重新选择 greeting" UI。来源 [Agent 角色配置调查笔记](../Agent角色/SillyTavern-Agent角色配置调查笔记.md)。
- **World Info（世界书）**：按关键词/次级词/constant/selective 触发、支持递归扫描与 position/depth 注入，与角色卡 `character_book` 共享结构；条目激活可经 `automationId` 匹配已配置的 Quick Reply 集；自动化受扩展启用和防递归状态控制。角色卡还可携专属正则，角色允许列表决定其是否参与处理。来源 [Agent 角色配置调查笔记](../Agent角色/SillyTavern-Agent角色配置调查笔记.md)。
- **User Persona**：独立于角色卡的运行时用户设定（名称与描述注入提示词），同一角色卡可配合不同 Persona 使用，不写入角色卡。来源 [Agent 角色配置调查笔记](../Agent角色/SillyTavern-Agent角色配置调查笔记.md)。
- **记忆与作者注释（浮层提示注入）**：memory 扩展以静默生成产出摘要文本并经 `{{summary}}` 模板注入；作者注释（Author's Note）是独立的 floating-prompt 模块（`2_floating_prompt`），支持间隔/深度/位置/角色参数并经 `/note` 命令读写、随 `chat_metadata` 持久化。来源 [对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)、[独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。

### 会话与消息

- **聊天会话存储模型**：聊天的运行时事实源是内存里的消息数组与聊天元数据（`chat_metadata`），保存时把两者整份序列化写入 JSONL 文件，单人与群聊各用一套目录布局；加载时一次整读，没有分页也没有索引。保存前会比对 `integrity` 文件记录的稳定身份，标识不符或文件头损坏时要求用户手工输入 `OVERWRITE` 才能覆盖；同一标识下的两个旧窗口仍可先后互相覆盖，逐次保存没有版本乐观锁保护。来源 [Chat 调查笔记](../Chat/SillyTavern-Chat调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)。
- **Swipe 候选版本机制**：`mes`/`swipe_id`/`swipes`/`swipe_info` 四字段并行表达消息多版本，`ensureSwipes` 惰性补齐老文件，双向同步职责分离；越界行为有四档模式（REGENERATE/LOOP/PRISTINE_GREETING/NONE），Swipe Picker 是唯一"从候选开分支"的 UI 入口。来源 [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/SillyTavern-ChatUI调查笔记.md>)。
- **Checkpoint 与 Branch**：两者共用"截断另存为新文件"底层；checkpoint 不跳转、`extra.bookmark_link` 单值覆盖；branch 必定跳转、`extra.branches` 数组追加并支持连同指定 swipe 截断；回到主聊天只能靠 `/checkpoint-exit` 手动切文件，无树状导航。来源 [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)。
- **聊天 CRUD、列表与搜索**：新建/重命名/删除/恢复走服务端聊天端点，最近聊天列表扫描三处目录按 mtime 排序，搜索在单个角色的聊天目录或单个群组范围内按词过滤；跨角色全局搜索未覆盖，见末尾小节。来源 [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)。
- **对话导出与导入**：单一"数据交换"型能力——JSONL 原样导出（含完整 swipe/附件引用/分支字段，可无损导回）与 TXT 可见正文投影（跳过系统消息、译文优先），导入支持 JSONL 及 Kobold Lite/CAI Tools/oobabooga/Agnai/RisuAI 五种外部格式；交付方式为浏览器本地文件下载，无分享稿与富文档交付，见末尾小节。来源 [对话导出与分享调查笔记](../对话导出与分享/SillyTavern-对话导出与分享调查笔记.md)。
- **消息附件与 Data Bank（知识库）**：消息级 `extra.media`/`extra.files` 存 URL 引用、内容在 prompt 组装时展开；Data Bank 分全局/角色/聊天三作用域，不直接进 prompt 而由 vectors 扩展摄取进向量索引检索注入，与消息级附件是两套并行体系。来源 [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)。
- **三条发送前检索链**：World Info 以关键词、条件、概率和递归扫描选择 Lorebook；Summarize 扩展将聊天压缩为可编辑摘要；Vector Storage 对聊天、Data Bank 附件和可选 World Info 进行向量近邻选择。三者最终均作为普通文本进入 prompt 槽或历史，未确认检索结果驱动的多阶段认知编排。来源：[检索增强与认知编排调查笔记](../检索增强与认知编排/SillyTavern-检索增强与认知编排调查笔记.md)。
- **群聊体系**：群组本体与群聊文件分离存储，消息用 `extra.gen_id` 标记同一轮生成批次；多成员由 `generateGroupWrapper` 串行生成（NATURAL/LIST/POOLED/MANUAL 激活策略）；单聊转群聊是不可逆格式迁移。来源 [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)。

### 生成与创作

- **生成主链 Generate()**：用户从输入框发送消息后，`sendTextareaMessage` 把请求交给 `Generate`，由它串起从历史筛选到落盘的全过程，最后产出流式或非流式回复并写回聊天文件。普通输入若以 `/` 开头，会在 Generate 前段交给 slash command 处理并提前返回，后续模型请求流程随之跳过。来源 [对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)。
  1. 筛选历史消息，隐藏消息被排除，工具调用相关消息例外保留；
  2. 逐条处理消息的正则、附件与标题；
  3. 拼入角色字段与系统提示；
  4. 注入 World Info 命中的条目；
  5. 执行扩展注册的生成前拦截器；
  6. 按所选 API 分支组装请求；
  7. 按 token 预算裁剪上下文；
  8. 发起流式或非流式请求；
  9. 收口并把结果落盘。
- **消息渲染与富文本管线**：`messageFormatting()` 依次执行宏替换、正则、Markdown（Showdown）、DOMPurify 净化与 `<custom-style>` 作用域改写；正文格式化另有 `MessageFormatter` 三阶段扩展钩子（正则前后与 Markdown 转 HTML 后，均在净化前）；`extra.display_text` 提供"源文本 ↔ 显示投影"双视图，reasoning 与媒体走独立旁路 DOM；历史渲染是截断式分页（默认 100 条）而非虚拟列表。来源 [消息渲染调查笔记](../消息渲染器/SillyTavern-消息渲染调查笔记.md)。
- **流式渲染与反馈**：主聊天走 `StreamingProcessor`（默认 30 FPS 节流，每帧对累计全文整段重渲），流式收尾才补代码高亮与事件；`streaming-display.js` 是脱离主聊天的独立浮层（仅 `/profile-genstream` 使用）；生成反馈另有 Action Loader 的 STOPPABLE toast 与 `body[data-generating]` 全局状态位。来源 [消息渲染调查笔记](../消息渲染器/SillyTavern-消息渲染调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/SillyTavern-ChatUI调查笔记.md>)。
- **Agent 工具（函数调用）**：ToolManager 维护浏览器侧工具注册表，模型可发现并触发已注册工具，`tool_choice` 固定 `'auto'`，内置工具仅 Stable Diffusion 的 GenerateImage 一个，`/tools-register` 可把任意 STscript closure 注册为模型可调用的工具；调用循环无逐次审批、参数无 JSON Schema 校验且执行在浏览器主线程、无沙箱隔离；删除助手消息时默认连带清理其前的工具调用消息（`/cut`、`/del` 可用 `toolcalls` 关闭），普通工具的参数解析或执行错误会形成带错误标记的调用记录，保存后回注模型并可继续生成，stealth 另走终止语义；相关边界见末尾小节。来源 [Agent 工具调查笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md)。
- **输出对象模型与运行环境边界**：模型输出只有"聊天气泡文本"一种对象形态，`extra` 是开放元数据袋，支持 Markdown + 受限 HTML/CSS（DOMPurify 净化）与代码高亮；artifact/canvas/notebook/沙箱等输出运行环境不存在，也无对模型文本的代码执行，见末尾小节。来源 [生成式输出与运行时调查笔记](../生成式输出与运行时/SillyTavern-生成式输出与运行时调查笔记.md)。
- **Stable Diffusion 聊天绑定创作**：画笔菜单、消息级画笔、`/imagine` 和可选 `GenerateImage` 工具共用生成链，结果写入本地媒体文件并作为聊天消息的 `extra.media` 附件保存；消息级重生可追加媒体候选，工具调用可把 URL 回注模型。媒体历史依附聊天消息，不是独立任务或资产库。来源：[媒体创作调查笔记](../媒体创作/SillyTavern-媒体创作调查笔记.md)。
- **停止、重试、续写与重新生成**：停止走 `stopGeneration`（保留下半截内存消息、abort 网络），重新生成单聊删尾新建、群聊按 `gen_id` 删尾，续写为纯文本追加；统一自动重试与 `/retry` 命令不存在，见末尾小节。来源 [对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)。

### Agent 运行时与外部协作

- **扩展体系**：浏览器扩展先从 manifest 拉取元数据，通过依赖校验后动态加载代码，加载后可注册全局生成前拦截器介入每一轮生成；从第三方 Git 仓库安装扩展要经过一次性的信任确认。服务端插件同样以动态加载方式载入，但运行在 Node 侧、拥有完整 Node 权限，默认关闭（`enableServerPlugins: false`），与浏览器侧工具分属两套独立机制。来源 [Agent 工具调查笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md)。
- **STscript / slash command 与 Quick Reply**：输入以 `/` 开头即整段交给命令执行器并短路发送；`/tools-register` 把 STscript closure 变成模型可调用工具（可读写变量、发起网络、嵌套生成），模型普通文本不能直接触发 slash command；Quick Reply 监听事件自动执行 STscript，World Info 激活可经 `automationId` 触发它，构成内容驱动的代码执行旁路。来源 [Agent 工具调查笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)。
- **事件总线与扩展介入点**：`eventSource` 事件总线（消息接收/渲染/编辑、工具调用、流式 token 等生命周期事件）是扩展观察与介入输出的唯一通道；Quick Reply 用 `makeFirst` 抢占关键事件监听位置。来源 [消息渲染调查笔记](../消息渲染器/SillyTavern-消息渲染调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)。
- **子 Agent 与任务委派**：函数调用递归（最多 RECURSE_LIMIT 轮）、群聊自动模式定时轮询与 `/trigger` 等待其他成员生成可构成事实上的自主循环；内建的子 Agent/委派机制不存在，且全部循环仍运行在单一浏览器页面的 JS 主线程上，见末尾小节。来源 [Agent 工具调查笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md)。

### 渠道与调度

- **LLM 渠道数据模型与 Connection Profile**：全局只保留一组活动渠道设置，由主 API 类别、source/type、URL、模型与 Secret 五个要素组成，可选来源覆盖 26 个 Chat Completion source 与 15 个 Text Completion type。Connection Profile 把这组设置存成配置快照，切换聊天时可回放或切换；快照里没有健康状态与调度策略，作用限于配置的保存与回放。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)。
- **协议适配与请求代理**：浏览器不直连外部 Provider，请求打到 SillyTavern 服务端代理端点，后端按 source/type 分支构造各家 endpoint、Header、payload 与流式解析，Custom 路径兼容 OpenAI Chat Completions；服务端只做代理转发与 abort 转发，不持有会话状态。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)。
- **模型目录与能力元数据**：状态检查调用 Provider `/models`（部分 Provider 只提示用 Test Message 验证）；`model_list` 是无统一 schema 的异构上游对象数组，上下文上限为动态字段加硬编码 fallback，能力元数据直接控制多模态与推理参数；无本地成本/延迟/权重路由，见末尾小节。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)。
- **凭据、Secret Manager 与安全边界**：同一种 Secret 可存多条带 UUID/标签/active 的 Key（新写入自动启用，rotate 为人工切换，无轮询/自动换 Key/熔断）；浏览器默认只见掩码，明文暴露受 `allowKeysExposure` 开关控制；Secret 明文存 `secrets.json` 原子写入无加密，全量 ZIP 默认排除 Secret。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)。
- **重试、降级与故障转移边界**：普通聊天单次请求执行、失败直接返回前端，仅 `/profile-genstream` 在流式失败时用同一 Profile 降级为非流式再请求一次；OpenRouter 的 fallback/Provider order 作为参数交给上游，本地无跨 Profile failover、权重或健康调度，见末尾小节。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)。
- **连接检测与可观测性**：连接测试可调用 `/models`、专用探测与 Test Message 并更新全局 `online_status`；结果不形成按 Profile/Key 持久化的健康表、不参与后续调度，也无私渠道层汇总 token/成本/延迟的内置观测面板，见末尾小节。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)。

### 独特与差异化能力

- **格式化模板/预设体系**（`主链确认`，静态证据）：六类预设共用一套统一管理器，切换聊天时按角色名或群名自动精确匹配对应预设；master import/export 把整套提示工程配置打包成单个文件迁移，构成提示词工程工作台的骨架。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
  - instruct：指令格式预设
  - context：上下文格式预设
  - sysprompt：系统提示词预设
  - textcompletion：文本补全预设
  - reasoning：推理预设
  - start-reply-with：回复起始内容预设
- **本地向量存储与历史重排（Vector Storage 扩展）**（`主链确认`，静态证据）：生成前拦截器按相关性检索聊天历史、Data Bank 附件与 World Info，把命中旧消息重排注入提示；嵌入支持远程 Extras/本地 WebLLM/koboldcpp，浏览器侧本地 RAG。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
- **内部扩展体系**（`归并已有类目`）：manifest 加载、依赖校验、install 流程与 `generate_interceptor` 机制已归并到 Agent 工具类目，本处仅补充 14 个内置扩展的产品目录盘点。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
- **作者注释（Author's Note）**（`入口确认`/`归并已有类目`）：已归并到"角色与上下文"的记忆与上下文注入能力，仅作入口确认。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
- **角色库管理与批量编辑**（`归并已有类目`）：角色卡存储/导入/缓存已归并到 Agent 角色类目，`bulk-edit.js` 批量编辑为增量入口。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。

表达式系统与连接配置两项为"入口确认"能力，正文不展开，见末尾"已知边界与待验证事项"。表达式扩展另有 `lastExpression`/`defaultExpression`/`availableExpressions` 宏与 `/expression-list` 的 `custom` 过滤，仍属入口确认。

特色贡献建议：独特功能笔记建议将"提示词工程工作台（六类模板 + 角色名绑定 + 主导入导出）"与"向量历史重排注入"列入特色贡献候选，详见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 工程与基础设施摘要

- **仓库分布**：Node 服务与传统浏览器前端合仓的单应用项目，非 package 化 monorepo；`public/scripts` 141,344 行为绝对主体，后端 `src/endpoints` 22,786 行；Git 跟踪 988 文件，JavaScript 占 86.1%；测试独立在 `tests`（Jest 单元 + Playwright E2E）；提供 Docker、Electron 启动器及 Deno/Bun 启动入口，无移动原生代码。来源 [仓库分布调查笔记](../仓库分布/SillyTavern-仓库分布调查笔记.md)。
- **应用界面栈**：原生 HTML + 手写 JS（jQuery 辅助），无前端框架；弹窗基于浏览器原生 dialog 与自研 Popup（点遮罩不关闭、双击 Esc 强制关闭、支持多层堆叠）；通知统一调用 toastr（988 处、86 文件，无项目级门面）；Action Loader 处理阻塞遮罩与可停止的进度 toast。来源 [应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)。
- **主题与视觉体系**：主题是可配置 CSS 变量集合、存服务端 JSON 并在运行时批量改写 CSS 变量，不跟随系统深浅色，无主题市场、无 light/dark 双变体、字体族硬编码（仅字号可缩放）；背景图是独立于主题色的子系统（全局/聊天级、文件夹分组、动画背景、autobg AI 选背景、bgcol 按背景图生成配色主题）。来源 [应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)。
- **响应式与移动端**：媒体查询驱动的桌面/移动切换（主断点 1000px + 横屏/窄屏/iOS PWA 子断点），无响应式框架；末条消息的候选回复可由箭头按钮切换，也可在聊天壳内通过左右滑动触发；手势受设置、弹窗、编辑状态和按钮可见性约束；拖放分"文件拖入导入"与"jQuery UI sortable 列表排序"两套实现。来源 [应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)。
- **无障碍与错误处理**：键盘可达性靠自研 keyboard.js（interactable 白名单 + 动态 tabindex + Enter 触发）与 a11y.js 的 role 注入保障，但 ARIA 命名/焦点陷阱/动态区域基本缺失；无全局 JS 错误边界或渲染崩溃兜底，启动失败靠有限次重载；扩展面板是预先开好的固定坑位而非动态列表。来源 [应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)。

## 已知边界与待验证事项

### 声明不符

- **QR 生成**（`声明不符`）：全仓检索 `qrcode|QRCode|generateQR` 零命中，本次未找到该能力；不写成项目级绝对结论，若指第三方扩展提供则属外部扩展生态。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。

### 暂缓与外部依赖（含入口确认未闭合）

- **表达式系统（Character Expressions）**（`入口确认`）：情绪分类（LLM 或 classify 模块）→ 角色表情 sprite 切换的入口与状态已确认；依赖 Extras API 或本地 LLM，分类映射与实际表现未运行验证。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
- **连接配置（Connection Profiles）**（`入口确认`）：录制连接 slash 命令序列为命名 profile 并在切换聊天时回放的机制入口已确认；profile 回放与当前连接状态的冲突语义未验证。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
- 独特功能笔记未验证项：预设角色名绑定的实际触发、向量检索质量与 WebLLM 嵌入可用性、bulk-edit 批量编辑的完整 UI 工作流，静态代码只确认到入口与状态。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。

### 未覆盖类目

- 第三方扩展生态（Git 安装的 `third-party/*`）能力不在本仓库盘点范围，机制面见 Agent 工具笔记。来源 [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)。
- 跨角色/全局聊天内容搜索、分享稿编辑器、HTML/PDF/PNG 对话交付与链接分享均未找到。来源 [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/SillyTavern-对话导出与分享调查笔记.md)。
- 未找到独立 CLI/TUI 渠道管理界面：CLI 只解析启动参数，Electron 只是窗口包装，Web 是唯一直接提供渠道配置管理的界面。来源 [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)。

### 共性未验证

- 13 份来源笔记均基于同一代码快照且未运行应用，浏览器交互、下载、触屏、键盘焦点、读屏、保存时序、Electron 下载对话框等行为为静态代码结论，需黑盒运行验证（各来源笔记均有注明）。
- 导入格式转换（Ooba/Agnai/CAI/Kobold Lite/Risu/Chub）只核实转换函数存在与调用入口，未用样本文件逐格式验证（会话与消息管理、对话导出与分享）。
- 崩溃恢复、多标签页 integrity 竞争窗口（TOCTOU）、大文件搜索与长聊天渲染性能未实测（会话与消息管理、消息渲染器）。
- 工具调用消息的 `is_system` DOMPurify 豁免分支、DeepSeek/Moonshot/xAI 等服务端转码、`RECURSE_LIMIT` 被改写为极大值的行为未验证（Agent 工具）。
- OpenAI 路径 `populateChatCompletion` 装填算法、各后端停止序列与半截流、Horde 参数自适应细节未逐行核对（对话请求与上下文）。
- 流式渲染性能、`stream_fade_in` 视觉行为、外部媒体拦截实际触发为基于静态代码的推断（生成式输出与运行时）。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/SillyTavern-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/SillyTavern-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/SillyTavern-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/SillyTavern-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/SillyTavern-对话导出与分享调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)
- [消息渲染调查笔记](../消息渲染器/SillyTavern-消息渲染调查笔记.md)
- [独特功能调查笔记](../独特功能/SillyTavern-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/SillyTavern-生成式输出与运行时调查笔记.md)
- [检索增强与认知编排调查笔记](../检索增强与认知编排/SillyTavern-检索增强与认知编排调查笔记.md)
- [媒体创作调查笔记](../媒体创作/SillyTavern-媒体创作调查笔记.md)
