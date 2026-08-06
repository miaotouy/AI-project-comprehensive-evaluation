# 七个项目的 LLM 渠道管理横向对比

> 对比对象：AIO Hub、Chatbox、Cherry Studio、LobeHub、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-06
>
> 依据：同目录七份源码调查笔记及其中记录的代码快照
>
> 对比方法：统一比较渠道数据模型、协议适配、模型目录、多 Key、重试与故障转移、凭据、备份、检测和可观测性；未运行跨项目 benchmark
>
> 对比范围：渠道数据模型、协议适配、模型目录、多 Key、重试与故障转移、凭据、备份、检测和可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

七个项目表面上都有 Provider、模型和 API Key 设置，实际承担的职责并不相同。AIO Hub、Chatbox、Cherry Studio 和 LobeHub 把 Provider 与模型作为客户端或应用服务的一级对象；SillyTavern 以当前活动设置和 Connection Profile 组织连接；VCPChat 只管理一条 VCP 网关连接；VCPToolBox 位于网关侧，但核心 LLM 出口仍是一组全局 `API_URL + API_Key`。因此，“支持多少 Provider”不能直接用来判断渠道管理能力。

横向核验后的主要结论如下：

- **AIO Hub 的本地渠道运行状态最完整。** `LlmProfile` 同时容纳协议、端点、模型和多 Key；Key 具有启停、错误计数、429 熔断和恢复状态。它仍不在失败的当前请求内换 Key，也没有跨 Profile 故障转移。
- **Cherry Studio 的 Provider 实例模型和认证边界最规整。** 预设、用户差量、Endpoint Type、Adapter Family、模型覆盖和多种认证被拆成明确层次；同一预设可复制成多条独立渠道。多 Key 只做跨请求轮询，普通聊天默认不重试。
- **LobeHub 在服务端凭据保护和重试框架上领先。** Provider 凭据以 AES-GCM 密文进入 PostgreSQL，Agent Runtime 有错误分类、指数退避和结构化重试事件。开源普通 Provider 仍固定 `providerId + modelId`；`RouterRuntime` 的扩展能力不能等同于已经配置好的跨渠道高可用。
- **Chatbox 的优势是注册表、模型目录和通用客户端的可预期行为。** 它覆盖多种内置 Provider、四类自定义协议、OAuth 和多来源模型数据，对 429/5xx 做同渠道重试。它没有多 Key 池，内置 Provider ID 也只能保存一个端点实例。
- **SillyTavern 侧重快速切换完整使用环境。** Connection Profile 把 API、URL、模型、Preset、模板、Proxy 和 Secret 引用一起保存，适合角色与生成配置联动切换；它不是带健康状态的 Provider 池，多 Key 需要人工选择。
- **VCPChat 是单网关客户端。** 它把上游 Provider 选择留给 VCP 服务端，客户端只保存一组 URL/Key 和各 Agent 的裸模型 ID。这个边界降低了客户端配置复杂度，也形成单连接故障点。
- **VCPToolBox 是协议与模型编排层，不是多 Provider 渠道池。** 它统一多种入站协议，支持模型别名、语义选模、特定请求的模型 fallback 和普通请求重试；所有核心请求仍走同一个 OpenAI-compatible 上游和同一枚 Key。
- **没有一个项目在通用请求路径上实现了完整的跨 Provider 高可用闭环。** 七者都缺少“持续采集健康数据 -> 维护渠道状态 -> 按策略选路 -> 失败后换渠道 -> 恢复探测”的完整链条。AIO Hub 的闭环止于 Key 级跨请求选择；VCPToolBox 的 fallback 止于单上游下的模型级切换。
- **成本、延迟和配额数据普遍没有进入调度。** 模型定价、连接延迟、NewAPI 监控或批量检测即使存在，也主要用于展示和人工判断，不直接决定下一次请求走哪条渠道。
- **凭据保护差异明显。** LobeHub 是本次样本中唯一确认对 Provider 凭据做数据库静态加密的项目。Cherry Studio 和 SillyTavern 缩小了前端可见范围，但磁盘仍为明文；AIO Hub、Chatbox、VCPChat 和 VCPToolBox 的核心配置也以明文保存。备份是否包含 Key 必须单独核对，不能由“设置已备份”或“导出已脱敏”推断。
- **不适合给七者排一个总名次。** 桌面多模型客户端、服务端 Agent 平台、角色扮演前端、单网关客户端和 AI 中间层面对的管理边界不同。更有用的比较是判断能力位于哪一层，以及失败时是否真的改变了 Provider、URL、Key 或模型。

## 一览矩阵

| 维度 | AIO Hub | Chatbox | Cherry Studio | LobeHub | SillyTavern | VCPChat | VCPToolBox |
|---|---|---|---|---|---|---|---|
| 核心连接对象 | `LlmProfile` | Provider 注册项 + 设置 | `user_provider` 实例 | `ai_providers` | 活动设置 + Connection Profile | 全局 VCP URL/Key | 全局上游 URL/Key |
| 同服务多实例 | 有 | 自定义 Provider 有 | 有，可复制预设 | 自定义 Provider 有条件 | Profile 快照可表达 | 无 | 无 |
| 运行时模型身份 | `profileId + modelId` | `provider + modelId` | 含 `providerId` 的模型标识 | `providerId + modelId` | Provider 专属字段/Profile model | 裸 `model` ID | 上游或虚拟模型 ID |
| 多协议出站 Adapter | 有 | 有 | 有 | 有 | 有 | 无，固定 VCP/OpenAI-compatible | 无，出站固定 OpenAI-compatible |
| 调用 SDK / 协议封装 | 自研 `@aiohub/llm-core` Adapter + `fetchWithTimeout` | Vercel AI SDK Provider Adapter | `@cherrystudio/ai-core` + Vercel AI SDK；Claude Code Agent 另走其 SDK | `ModelRuntime` 按 `sdkType` 选择协议实现/Provider SDK | Provider 分支自行组装请求，单次 `fetch` | 直接 `fetch` VCP 的 OpenAI-compatible 入口 | `fetchWithRetry` 调用单一 OpenAI-compatible 上游 |
| 多 Endpoint | 按能力细分端点 | Host + Path | Endpoint Type 级 Base URL | 依 Runtime | Provider/source 分支 | 固定 Chat/VCP 端点 | 固定 `/v1/*` 端点 |
| 多 Key | 有，结构化数组 | 无 | 有，结构化数组 | 有，逗号字符串 | 有，Secret 数组 | 无 | 无 |
| Key 自动选择 | 轮询 | 无 | 跨请求轮询 | 随机或轮询 | 无，人工 active/固定 ID | 无 | 无 |
| Key 健康状态 | 有 | 无 | 无 | 无 | 无 | 无 | 无 |
| 普通请求重试 | 当前渠道层不负责 | 429/5xx，最多 5 次 | 默认关闭 | Agent Runtime 默认 5 次 retry | 无 | 无 | 默认最多 3 次总尝试 |
| 当前请求主动换 Key | 无 | 不适用 | 无 | 无稳定保证 | 无 | 不适用 | 不适用 |
| 通用跨 Provider failover | 无 | 无 | 无 | 开源普通路径无 | 无 | 无 | 本地无 |
| 特殊模型 fallback | 无 | 无 | 无 | Router 框架可扩展 | 可把策略交给 OpenRouter | 无 | 语义虚拟模型有 |
| 凭据静态加密 | 无 | 无 | 无 | 有，AES-GCM | 无 | 无 | 无 |
| 健康数据参与调度 | Key 状态局部参与 | 无 | 无 | 无 | 无 | 无 | 无 |

矩阵中的“重试次数”沿用各项目自己的配置语义。Chatbox 的“最多尝试 5 次”、LobeHub 的“默认 5 次 retry，最多 6 次 attempt”和 VCPToolBox 的“`ApiRetries` 默认 3，表示总尝试数”并不是同一计数方式。

## 比较口径

渠道管理容易因为术语复用而产生误判。本文采用以下定义：

| 概念 | 本文定义 | 不能混同的能力 |
|---|---|---|
| Provider 支持 | 能按某家服务的认证、端点、请求和响应格式完成调用 | 同一家服务可创建多条独立连接 |
| 渠道实例 | 一组可独立启停和引用的 Provider、URL、凭据及相关配置 | Provider 类型或模型名 |
| 多 Key | 同一渠道保存多枚凭据 | 自动选择、失败换 Key 或熔断 |
| 负载分摊 | 请求到来时随机或轮询选择 Key/渠道 | 健康感知和配额感知 |
| 请求重试 | 同一逻辑请求在错误后再次发送 | 换 Key、换模型或换 Provider |
| 模型 fallback | 错误后改用另一个模型 ID | 改用另一条 Provider 渠道 |
| 跨 Provider failover | 错误后选择另一条独立 Provider/URL/凭据组合 | 聚合上游内部可能发生但本地不可见的切换 |
| 健康调度 | 连接检测或请求结果形成持久状态，并直接影响后续选路 | 只在设置页显示成功、失败和延迟 |

这组定义解释了几个常见现象：多 Endpoint 通常解决协议选择，不等于容灾；`@模型` 并行调用解决结果比较，不等于失败候补；模型目录拉取失败后的本地列表 fallback 也不表示推理请求能够切换渠道。

## 架构分型

### 1. Provider 实体型：AIO Hub、Cherry Studio、LobeHub

这三者都有稳定的渠道实体，并把模型归属显式绑定到 Provider。

AIO Hub 的 `LlmProfile` 是聚合根，协议类型、Base URL、Key 池、模型、Header、端点和网络选项集中在一条记录中。优点是编辑、导入、请求构造和健康状态都围绕同一个 ID 展开；代价是 Profile 承担的字段较多，设置页 Provider 类型和运行时 Adapter 若没有同一注册源，容易发生漂移。当前 Azure 可创建但缺少通用运行时 Adapter，就是已经出现的实例。

Cherry Studio 用三层合并减少重复：Registry 保存 Provider/模型基线，用户表保存实例及差量，运行时再应用默认值。Endpoint Type 和 Adapter Family 分开后，同一 Provider 可以拥有多个协议端点，模型还可覆盖默认端点。这个结构适合长期维护不断增加的 Provider 和认证方式，但高可用状态没有进入这套实体模型。

LobeHub 把 Provider 与模型分表保存于 PostgreSQL，内置目录、环境变量和用户配置在运行时合并。`providerId + modelId` 贯穿模型选择，适合多用户和工作区作用域。它还提供 `RouterRuntime` 扩展面，但普通 Provider 调用和 Router 是两条不同路径；没有真实路由配置时，只能评价框架能力，不能归入已部署的跨渠道调度。

### 2. 注册表加设置型：Chatbox

Chatbox 的内置 Provider 由代码注册表声明，用户值保存在按 Provider ID 索引的设置中。模型创建由注册项负责，协议差异集中在 Provider 实现里。结构较直接，适合开箱即用的桌面客户端。

这一模型对内置 Provider 实例数有明确限制：一个内置 ID 只有一组设置。第二个 OpenAI 或 Claude 中转需要创建新的自定义 Provider UUID。自定义实例解决了多连接问题，但内置和自定义路径的能力范围仍需分别核对，例如当前导入 schema 与手工创建对 Gemini 的覆盖并不完全一致。

### 3. 活动设置与快照型：SillyTavern

SillyTavern 的运行时事实源是当前活动的 `main_api`、source/type、URL、模型和 Secret。Connection Profile 在其上保存一份可命名快照，切换时恢复整组设置。

这种结构与产品工作流一致：连接、模型、生成 Preset、模板、Proxy 和 Secret 经常需要一起切换。Profile 因而比纯 Provider 记录包含更多会话生成环境。它的限制也很清楚：Profile 不是规范化渠道实体，没有跨 Profile 的健康表、选择器或自动故障转移。

### 4. 单网关客户端：VCPChat

VCPChat 只认识一组 `vcpServerUrl + vcpApiKey`。Agent 保存模型和生成参数，请求交给 VCP 网关。Provider、真实 Base URL 和上游 Key 不属于客户端配置。

这一边界可以显著压缩客户端的 Provider 代码，Agent 和 widget 也能共用同一入口。相应地，模型身份只是裸 ID，网关切换后可能出现重名或语义变化；客户端没有备用 URL，网关不可用时无法在本地切换。

### 5. 单出口编排层：VCPToolBox

VCPToolBox 位于客户端和上游之间，负责入站协议转换、插件/RAG 编排、模型别名、语义选模、重试和中断。它看起来更接近网关，但核心上游仍只有 `API_URL + API_Key`。

如果 `API_URL` 指向 NewAPI、One API 等聚合服务，多 Provider 池、倍率、渠道熔断可能发生在聚合服务内部。VCPToolBox 本地看不到这些实体和状态，因此横向比较时只能把它记为“依赖外部渠道管理”，不能把外部网关的能力归入本项目。

## 渠道身份与配置复用

稳定身份决定了模型收藏、历史记录、统计和故障切换能否准确指向原连接。

| 项目 | 渠道身份策略 | 复用同一服务的方式 | 主要边界 |
|---|---|---|---|
| AIO Hub | 独立 Profile ID | 新建或导入 Profile | 无跨 Profile 同模型聚合 |
| Chatbox | 内置 ID 或自定义 UUID | 内置单例；额外连接建自定义 Provider | 内置和自定义能力可能不完全等价 |
| Cherry Studio | 独立 `providerId` + 可选 `presetProviderId` | 复制预设生成新实例 | Registry 更新需遵守用户差量合并语义 |
| LobeHub | 内置或自定义 Provider ID | 额外连接使用不同自定义 ID | 同一内置 ID 只存一组 vault |
| SillyTavern | Profile UUID，内部仍引用活动设置字段 | 保存多份 Profile | 快照字段可能随功能增长产生兼容负担 |
| VCPChat | 无渠道实体 | 直接替换全局网关 | 裸模型 ID 缺少网关命名空间 |
| VCPToolBox | 无上游渠道实体 | 直接替换全局上游 | 无法并存或选择多条上游连接 |

Cherry Studio 的 `providerId` 与 `presetProviderId` 分离值得借鉴。前者保证用户实例稳定，后者保留继承关系；用户可拥有两条继承同一预设、但凭据和端点独立的渠道。AIO Hub 的 Profile 也能直接表达多实例，结构更集中。LobeHub 和 Chatbox 可以用自定义 ID 达到类似结果，但内置实例和自定义实例需要按各自规则管理。

VCPChat 和 VCPToolBox 则应作为另一种部署选择看待。它们预期多渠道复杂度由统一上游承担，本地不必再复制一套 Provider 池。只有当上游确实提供并运维这些能力时，这种简化才成立；单一自建接口本身不会自动获得容灾。

## 协议、端点与 Adapter

### 协议数量不等于渠道数量

AIO Hub、Chatbox、Cherry Studio、LobeHub 和 SillyTavern 都能按 Provider 或协议族构造不同请求。Cherry Studio 的拆分最明确：Endpoint Type 决定本次调用使用 OpenAI Chat、Responses、Anthropic Messages 或 Gemini GenerateContent 等接口，Adapter Family 决定协议实现，Base URL 又可按 Endpoint Type 独立覆盖。

AIO Hub 允许 Chat、Responses、Anthropic、Gemini、Embedding、Rerank 和媒体生成使用不同端点，并提供自定义 Header 与 Provider options。它适合一个 Provider 同时暴露多种能力的情形。运行时映射和设置选项必须保持同源，否则就会出现 Azure 这类配置可见、调用不可达的问题。

Chatbox 把内置 Provider 的 Host、Path 和模型创建逻辑收进注册表，自定义 Provider 覆盖 OpenAI Chat、OpenAI Responses、Anthropic 和 Gemini 四类协议。LobeHub 主要由内置 ID 或自定义 Provider 的 `sdkType` 选择 Runtime。SillyTavern 的 Chat Completion source 和 Text Completion type 分轨，兼容的后端数量多，但分支和 Provider 专属字段也更多。

VCPChat 固定发送 OpenAI 风格请求，并用独立 `/v1/chatvcp/completions` 表达工具注入。VCPToolBox 可以接收 OpenAI Chat/Responses、Anthropic 和 Gemini 请求，后几类先转换到内部 Chat 链；出站仍统一为 OpenAI-compatible Chat Completions。因此，VCPToolBox 的“入站多协议”解决客户端兼容，并不表示它能按上游 Provider 选择原生协议。

### 多 Endpoint 主要解决能力分派

多 Endpoint 常用于区分 Chat、Responses、Embedding、Rerank 或媒体生成。它们可能共用同一 Provider 和凭据，也可能指向不同路径。除非实现同时维护独立健康状态并在失败后改选 Endpoint，否则不能把它当作故障转移。

Cherry Studio 的 Endpoint Type、AIO Hub 的 `customEndpoints` 和 VCPToolBox 的固定 `/v1/*` 路径都属于能力分派。Chatbox 的 Host/Path 可定制，但重试仍固定当前 Provider 设置。SillyTavern 按 source/type 选择端点，OpenRouter 的路由参数则由上游执行。

## 模型目录与元数据

模型目录在七个项目中承担三种不同职责：发现可用模型、补充展示与能力信息、决定运行时请求行为。

| 项目 | 主要来源 | 模型归属 | 元数据对运行时的作用 |
|---|---|---|---|
| AIO Hub | 远端目录 + 本地规则 + 手工维护 | Profile | 能力、端点和参数可参与请求构造 |
| Chatbox | Provider API、后端 manifest、本地保存、models.dev | Provider | 能力富化和模型实例化 |
| Cherry Studio | Registry + 上游目录 + 用户覆盖 | Provider | Endpoint、能力和参数多层合并 |
| LobeHub | 内置 Model Bank、环境与用户数据 | Provider | 能力和参数影响 Runtime |
| SillyTavern | Provider `/models` 或专用 API | 当前 source/Profile 字段 | 异构字段控制上下文、多模态、推理和工具 UI |
| VCPChat | 同网关 `/v1/models` | 无本地 Provider 命名空间 | 主要用于选择、收藏和展示 |
| VCPToolBox | 上游 `/v1/models` + 别名 + 虚拟模型 | 单上游 | 公开名改写和语义路由 |

AIO Hub、Cherry Studio 和 LobeHub 都把模型稳定地放在 Provider 命名空间内，可以避免不同服务暴露同名模型时误路由。Chatbox 的运行时键同样包含 Provider。VCPChat 保存裸模型 ID，符合单网关假设；一旦用户替换网关，本地收藏或统计未必还指向原模型语义。

Cherry Studio 的 Registry 将模型本体、Provider 定义和 Provider-模型覆盖分开，适合维护别名、能力差异和端点覆盖。AIO Hub 的模型规则覆盖面较广，能力信息还会驱动请求路径。LobeHub 的 Model Bank 同时容纳能力、限制和定价，但定价目前不参与普通选路。

SillyTavern 接收多家上游返回的异构模型对象，通过多套字段读取上下文、价格、视觉、推理和工具能力。这有利于兼容现有生态，也意味着字段统一和 fallback 规则会持续承担维护成本。

VCPToolBox 的模型层有独特用途：`ModelRedirect.json` 可把公开名映射到内部名，语义路由又把 `VCPModelAuto` 等虚拟模型加入标准目录。客户端无需理解路由协议即可选择虚拟模型。当前快照没有 `ModelRedirect.json`，别名能力存在但默认未启用；虚拟模型目录项也不应掩盖真实上游目录获取失败。

## 多 Key：存储、分摊与健康

“可以保存多个 Key”至少要继续追问四件事：Key 是否有独立身份，如何选择，失败后是否标坏，何时恢复。

| 项目 | 表示 | 正常选择 | 失败处理 | 当前请求换 Key |
|---|---|---|---|---|
| AIO Hub | 带状态的 `apiKeys[]` | 轮询 | 记录错误，429 可熔断并恢复 | 无 |
| Chatbox | 单 Key/OAuth | 固定 | 继续使用同一凭据重试 | 不适用 |
| Cherry Studio | 带 ID、标签、启停的数组 | 跨请求 round-robin | 不记录健康 | 无 |
| LobeHub | 逗号分隔字符串 | server 随机/轮询，client 随机 | 不记录健康 | 无主动保证 |
| SillyTavern | 带 UUID、标签、active 的 Secret 数组 | active 或 Profile 固定 ID | 用户手工 rotate | 无 |
| VCPChat | 单值 | 固定 | 无 | 不适用 |
| VCPToolBox | 单值 | 固定 | 无 | 不适用 |

AIO Hub 是本次样本中唯一确认把 Key 失败状态反馈到后续选择的项目。这个能力的时间边界很重要：失败请求仍然向上抛错，下一次请求才会绕开被熔断的 Key。它是 Key 级跨请求恢复机制，不是无感请求重放。

Cherry Studio 的结构化 Key 数组便于展示标签、启停和逐 Key 检测，轮询可以分摊正常流量。失败不会让某枚 Key 离开候选池，当前请求也不会自动换 Key。LobeHub 的逗号字符串配置更轻，但缺少独立 ID、标签和状态；而且不同 Transport 是否重建 Runtime 会影响 retry 是否重新抽取 Key，不能形成一致承诺。

SillyTavern 把多 Key 当作 Secret 管理和人工切换功能。Profile 可固定某个 Secret UUID，适合稳定复现实验配置。自动负载分摊不是其目标，401/429 也不会触发 rotate。

## 重试、模型回退与跨渠道故障转移

### 重试策略

| 项目 | 普通请求行为 | 错误范围与退避 | 请求目标是否改变 |
|---|---|---|---|
| AIO Hub | 渠道层失败后抛错 | 更新 Key 状态 | 当前请求不改变 |
| Chatbox | 最多 5 次 attempt | 429/5xx，指数退避；网络错误默认不重试 | Provider、端点、Key、模型不变 |
| Cherry Studio | 默认 `maxRetries: 0` | 调用方可显式覆盖 | 不重新选择 Provider/Key |
| LobeHub | Agent Runtime 默认 5 次 retry | 可重试错误，指数退避 1s 起、上限 30s | Provider/模型固定；Key 行为依 Runtime 生命周期 |
| SillyTavern | 普通 Chat 单次请求 | 无统一策略 | 不改变 |
| VCPChat | 主链单次 `fetch` | Flowlock 是新续写轮次 | 不改变 |
| VCPToolBox | 默认 3 次总尝试 | 500、503、429、特定 401、网络和连接/首包超时；线性退避 | 普通模型不变；语义模型可换候选 |

Chatbox 对网络错误默认不重试，是为了避免服务端已经处理请求时发生重复计费。这个选择提醒我们：自动重试并非次数越多越好。对于非幂等生成请求，客户端在断线时通常无法确认服务端是否已经开始计费或生成；重放策略应同时考虑错误类别、是否收到响应头/首包和用户可见状态。

LobeHub 的重试过程会发布结构化事件，UI 可以显示重试状态，这是比简单循环更完整的交互设计。它的多 Key 选择与 Runtime 生命周期耦合：某些路径重建 Runtime 时可能重新取 Key，缓存 Runtime 的路径则复用原 Key。既然行为不是健康调度器的明确决策，就不应描述成“失败自动换 Key”。

VCPToolBox 对可重试错误的分类比单纯 5xx 更细，也把取消信号级联到上游。其退避不读取 `Retry-After`，默认的 `ApiRetries` 又表示总尝试数，配置名称和实际语义需要在 UI 或文档中明确。

### 模型 fallback 仍不等于 Provider failover

VCPToolBox 的语义虚拟模型先按对话内容与 route description 的相似度选出候选，遇到特定错误后沿模型链重试。Embedding 也有独立候选链。这些模型全部发往同一个 `API_URL` 并使用同一枚 `API_Key`。除非聚合上游恰好把不同模型映射到不同 Provider，本地并没有跨渠道切换证据。

SillyTavern 可以把 OpenRouter 的 Provider order 和 `allow_fallbacks` 传给上游；实际选择发生在 OpenRouter。LobeHub 的 `RouterRuntime` 支持 option fallback，当前开源 `lobehub` Router 配置没有真实路由项。这两类能力都应注明执行主体和配置前提。

### 七者都没有通用跨 Provider 闭环

一个完整的跨 Provider 故障转移至少需要：

1. 为同一逻辑模型维护多条独立 Provider/URL/凭据候选；
2. 按认证失败、限流、服务端错误、网络错误和超时区分处理；
3. 在请求内安全重放时明确选择下一候选；
4. 跨请求保存失败、冷却和恢复探测状态；
5. 记录每次 attempt 的渠道、错误、延迟和最终结果；
6. 处理流式响应已经开始后的不可重放边界。

AIO Hub 已覆盖第 2、4 项的一部分，但作用对象是同一 Profile 内的 Key。LobeHub 的 Runtime 与 Router 扩展面覆盖第 2、3、5 项的部分结构，开源普通路径没有候选池。VCPToolBox 对模型候选覆盖第 2、3、5 项的一部分，渠道仍由单一上游封装。其余项目主要停留在固定目标重试或人工切换。

## 路由依据：显式绑定仍是主流

七个项目的普通聊天大多采用显式绑定：用户或 Agent 先选定 Provider 和模型，运行时据此调用。这个策略可预测，也便于解释账单和错误。

| 路由依据 | 已确认项目 | 实际作用 |
|---|---|---|
| 用户/会话显式选择 | 全部 | 固定本次 Provider 或网关模型 |
| Key 随机/轮询 | AIO Hub、Cherry Studio、LobeHub | 同一渠道内分摊凭据 |
| 错误健康状态 | AIO Hub | 影响后续 Key 选择 |
| 语义相似度 | VCPToolBox | 选择虚拟模型的真实候选 |
| 上游 Provider order | SillyTavern/OpenRouter | 把路由偏好交给 OpenRouter |
| Router option 顺序 | LobeHub 框架 | 可扩展；开源品牌路由为空 |
| 成本、延迟、配额 | 无通用实现 | 现有数据未接入调度 |

语义选模回答“这段对话更适合哪个模型”，成本路由回答“满足能力要求的候选中哪一个更便宜”，健康路由回答“当前哪些候选可用”。三者的输入和目标不同。VCPToolBox 的余弦相似度实现只覆盖第一类，不能据此推断质量、价格或延迟最优。

## 凭据边界与持久化

### 静态存储

| 项目 | 主要存储 | 静态保护 | 前端可见边界 |
|---|---|---|---|
| AIO Hub | 本地 Profile 配置文件 | 明文 | 由桌面应用配置链使用 |
| Chatbox | Electron Store `config.json` | 明文 | 桌面设置持有 Key/OAuth/AWS 凭据 |
| Cherry Studio | SQLite JSON 字段 | 明文 | Renderer 读取普通 Provider 时不含秘密 |
| LobeHub | PostgreSQL `keyVaults` | AES-GCM | `fetchOnClient` 路径会下发解密后的运行时配置 |
| SillyTavern | `secrets.json` | 明文 | 浏览器默认只拿掩码、标签和 ID |
| VCPChat | `settings.json` | 明文 | 主进程使用全局 VCP Key |
| VCPToolBox | 主/插件 `config.env` | 明文 | 已认证管理 API 可返回完整主配置原文 |

静态加密、进程隔离和 UI 脱敏解决的是不同问题。Cherry Studio 把真实凭据留在 Main/Data API，能减少 Renderer 泄露面，但数据库文件本身仍是明文。SillyTavern 默认只向浏览器返回 Secret 的掩码和 ID，也不改变 `secrets.json` 的磁盘属性。LobeHub 保护了数据库静态数据；`fetchOnClient` 为浏览器直连而下发解密配置时，运行时暴露面又会扩大。

LobeHub 的密文导出还有密钥迁移约束：导出的 Provider 数据保留数据库密文，恢复目标必须使用相同 `KEY_VAULTS_SECRET`，否则无法解密。加密备份要同时设计数据归档和密钥迁移，仅保存密文不等于可恢复。

### 备份与导出

| 项目 | 默认行为 | 需要注意的边界 |
|---|---|---|
| AIO Hub | 单项目笔记未确认完整备份链 | 不据此推断包含或排除 Key |
| Chatbox | 自动配置备份复制完整 `config.json`；主动聊天导出默认剔除凭据 | 自动备份与用户导出边界不同 |
| Cherry Studio | 当前 legacy 备份不复制 `cherrystudio.sqlite` | v2 Provider 与凭据也未进入这条备份链 |
| LobeHub | 全量导出含 Provider 密文 | 跨主密钥恢复需要额外流程 |
| SillyTavern | 设置快照不含独立 Secret；ZIP 默认排除 Secret | 恢复 Profile 后可能缺少对应 Secret ID |
| VCPChat | 每日设置备份和一键 ZIP 包含明文 Key | 原子写入只保证完整性，不保证保密性 |
| VCPToolBox | 默认归档所有 `.env` 和 JSON | 未加密 ZIP 扩大核心及插件 Secret 副本范围 |

Chatbox 是“同一项目内不同备份入口安全语义不同”的典型：用户主动导出聊天数据时默认剔除 Key，自动配置滚动备份却复制整个配置文件。SillyTavern 默认排除 Secret，降低了普通归档泄露风险，但 Profile 内的 Secret UUID 引用可能在恢复后失效。Cherry Studio 当前 legacy 备份没有覆盖新 SQLite，并不等于已安全备份或已安全排除，而是 Provider 配置尚未进入这条实际备份链。

VCPChat 的 temp、回读校验、旧文件备份和原子替换提高了配置写入完整性。VCPToolBox 的管理 API 直接覆盖主配置，且保存后部分核心值需要重启才生效。这些属于可靠写入和运行配置切换问题，应与 Secret 加密分开评价。

## 连接检测与可观测性

| 项目 | 检测层次 | 运行时观测 | 是否影响调度 |
|---|---|---|---|
| AIO Hub | 能力感知连接测试、批量模型探测 | 请求 Inspector、Key 错误状态 | Key 状态局部影响后续选择 |
| Chatbox | Provider/模型连接能力 | 常规错误与重试 | 无持久健康调度 |
| Cherry Studio | 单 Provider、批量模型、多 Key 检查并显示延迟 | HTTP Trace、取消控制 | 无 |
| LobeHub | Web/CLI 单模型最小请求 | 结构化 retry 事件 | 无 |
| SillyTavern | `/models`、Provider 专用探测、Test Message | 当前 UI 状态 | 无 |
| VCPChat | `/models` 刷新 | 缺少结构化延迟/错误统计 | 无 |
| VCPToolBox | 模型目录、真实 Chat、语义 route preview | 日志 + 可选 NewAPI Monitor | 无 |

检测覆盖面最丰富的是 AIO Hub、Cherry Studio 和 VCPToolBox，但三者的用途不同。AIO Hub 的 Key 请求结果会进入局部状态；Cherry Studio 的逐模型、逐 Key 检测适合人工诊断；VCPToolBox 能分别验证目录、真实生成和语义路由。后两者的结果仍不改变下一次生产请求。

`/models` 成功只能证明鉴权和模型目录端点可用，无法证明 Chat、stream、tool、Embedding 或媒体端点都可用。VCPChat 主要以模型刷新做连通检查，SillyTavern 部分 Provider 也依赖目录探测，所以两者都会提示或需要用户进一步发送 Test Message。VCPToolBox 将真实 Chat 单独作为管理面板测试，验证层次更清楚。

外部监控也不能自动变成调度状态。VCPToolBox 的 NewAPI Monitor 可展示 token、quota、RPM/TPM 等数据，但信息来自外部管理 API，VCP 自己的模型选择器不读取这些指标。LobeHub Model Bank 的价格、Cherry Studio 健康检查的延迟同样没有接入普通路由。

## 各项目最值得借鉴的设计

### AIO Hub：让 Key 状态成为渠道实体的一部分

结构化 Key、手工启停、连续错误、429 熔断和恢复共同形成了可解释的跨请求选择。它比单纯 round-robin 多走了一步：正常分摊与异常摘除使用同一份状态。复用时还需补上明确的错误分类、请求内重放边界和持久化/恢复策略。

### Chatbox：把 Provider 声明和模型来源集中管理

`defineProvider()` 为显示、默认设置、模型映射和实例化提供单一入口，多来源模型目录又能在上游不可用时保留可选项。其同渠道重试明确排除默认网络错误，体现了对重复计费风险的考虑。

### Cherry Studio：分开预设、用户实例、Endpoint 和 Adapter

`presetProviderId` 与实例 `providerId` 分离，多 Endpoint Type 再映射 Adapter Family，既能复制官方预设，也能覆盖某个协议端点。多认证统一进入 Provider 实例，Renderer 默认看不到秘密。这个数据模型适合继续增加云厂商、OAuth 和协议变体。

### LobeHub：把重试过程和路由框架做成可观察扩展点

错误分类、指数退避、结构化事件和 RouterRuntime 的 option/停止条件/attempt 观测提供了较完整的框架边界。需要保留一条表述纪律：扩展点只有在存在真实候选配置和健康策略后，才构成可用的路由方案。

### SillyTavern：把连接与生成环境一起做成可切换 Profile

Profile 同时保存 API、URL、模型、Preset、模板、Proxy 和 Secret 引用，适合需要反复切换整套角色工作环境的用户。Secret UUID 和标签让 Profile 不必保存明文。默认备份排除 Secret 的做法也比静默收集全部 Key 更稳妥，但恢复流程需要处理断开的引用。

### VCPChat：保持客户端和网关职责边界清楚

Agent 只保存模型参数，URL 通过标准 `URL` API 规范化，工具注入使用独立端点，`requestId` 贯穿生成和中断。配置保存的 temp、校验、备份、移动流程也值得复用。备用网关和 Secret 保护仍需在单点风险与使用复杂度之间权衡。

### VCPToolBox：用标准模型接口包装别名和语义路由

公开模型名、真实模型名和语义虚拟模型分层后，普通 OpenAI-compatible 客户端不必理解额外路由协议。语义候选链去重组合首选、互备、默认和显式 fallback，管理面板还能预览路由。模型级编排与 Provider 级渠道管理应继续保持术语区分。

## 组合式参考架构

七个项目没有提供一套完整答案，但可以组合出一条较清楚的实现路径：

1. **渠道实体采用 Cherry Studio/AIO Hub 的稳定实例 ID。** Provider 预设与用户实例分离，模型身份始终包含渠道 ID。
2. **协议选择采用 Cherry Studio 的 Endpoint Type + Adapter Family 或 LobeHub 的显式 SDK Type。** 不从 URL 猜协议，也不把多 Endpoint 宣称为容灾。
3. **Key 使用 AIO Hub/Cherry Studio 的结构化数组。** 每枚 Key 具有 ID、标签、启停、最近错误、冷却截止和恢复状态；选择策略与健康状态分开配置。
4. **重试采用 LobeHub/Chatbox 的错误分类与可观察事件。** 对流式首包前后、网络不确定性、429 `Retry-After` 和重复计费分别定规则。
5. **模型别名和自动选模采用 VCPToolBox 的虚拟模型边界。** 任务分类、成本优化和健康选择使用独立评分，不把语义相似度当作通用路由指标。
6. **凭据采用 LobeHub 的静态加密，同时保留 Cherry Studio/SillyTavern 的前端脱敏。** 数据库密文、运行时解密、浏览器下发和备份密钥迁移分别设计。
7. **验证采用 AIO Hub/Cherry Studio/VCPToolBox 的分层探测。** 目录、最小生成、流式、工具、Embedding 和媒体能力分别检查，结果写入统一健康状态。
8. **连接环境切换可借鉴 SillyTavern Profile。** Provider 负责规范化连接，Profile 只引用 Provider/模型并附带 Preset 等上层设置，避免把两类事实源混在一起。

这是一组从现有实现抽取的设计参考，不表示将所有能力堆入同一个客户端。若部署已经依赖成熟聚合网关，客户端只保留 VCPChat 式单入口可能更合适；若应用必须直连多个厂商，本地才需要完整 Provider、Key 和健康调度模型。

## 容易误判的结论

| 容易写出的结论 | 源码支持的准确表述 |
|---|---|
| “AIO Hub 失败会自动换 Key 重试” | 失败会更新 Key 状态；当前请求抛错，后续请求可能选择其他 Key |
| “Cherry Studio 多 Key 可容灾” | 多 Key 跨请求 round-robin；无健康状态和当前请求换 Key |
| “LobeHub 已有跨 Provider Router” | RouterRuntime 支持 option fallback；当前开源 `lobehub` 路由表为空，普通 Provider 固定 |
| “Chatbox 支持多 Key 重试” | 它使用单 Key/OAuth，对 429/5xx 在同一渠道、同一凭据重试 |
| “SillyTavern Connection Profile 是渠道池” | Profile 是活动连接与生成设置快照，切换由用户发起 |
| “VCPChat 的 Flowlock 提供网络重试” | Flowlock 在失败后触发新的续写轮次，不是同一 HTTP 请求重放 |
| “VCPToolBox 支持多 Provider failover” | 它可在语义模型请求中换模型，但仍使用同一上游 URL/Key |
| “健康检查成功就会避开坏渠道” | 除 AIO Hub 的 Key 局部状态外，检测结果普遍只供 UI/人工判断 |
| “配置原子写入等于 Secret 安全” | 原子写入保护完整性；静态加密和备份控制保护保密性 |
| “模型定价已存在，所以可以按成本路由” | 本次样本中的定价和用量数据未进入通用调度 |

## 选型视角

| 主要需求 | 更接近的现有实现 | 需要接受的边界 |
|---|---|---|
| 桌面端直连多 Provider，并管理多 Key 状态 | AIO Hub | 无请求内换 Key 和跨 Profile failover；凭据明文 |
| 多认证、多协议端点和同预设多实例 | Cherry Studio | 默认不重试，无 Key 健康；SQLite 明文 |
| 服务端多用户 Provider、加密凭据和可观察重试 | LobeHub | 普通开源路径无跨 Provider 路由；密钥迁移复杂 |
| 简洁稳定的多模型桌面客户端 | Chatbox | 内置 Provider 单实例，无多 Key 和跨渠道切换 |
| 角色、Preset、模板与连接整体切换 | SillyTavern | 依赖快照式配置，自动可靠性能力少 |
| 客户端统一接入已有网关 | VCPChat | 单 URL/Key 是故障点，模型缺少 Provider 命名空间 |
| 多入站协议、语义选模和插件编排 | VCPToolBox | 本地仍是单一 OpenAI-compatible 上游 |

这张表描述的是实现接近度，不是产品推荐。最终选择还取决于部署位置、是否允许凭据进入客户端、是否已有聚合网关、生成请求能否安全重放，以及运维方是否真正维护健康状态。

## 横向结论

七个项目展示了三条清晰路线：

1. AIO Hub、Chatbox、Cherry Studio 和 LobeHub 在应用内建立 Provider/模型目录，差别集中在实例模型、多 Key、重试和凭据保护；
2. SillyTavern 用活动设置和 Profile 服务于完整创作环境切换，渠道自动化让位于兼容性和用户控制；
3. VCPChat 与 VCPToolBox 把复杂度推向统一网关，前者保持客户端轻量，后者增加协议和模型编排，但本地都没有多上游渠道池。

如果只比较“配置多少 Provider”，会错过真正影响可靠性和安全性的边界。更有效的审查顺序是：先确定运行时实际选中的 URL、凭据、协议和模型，再跟踪错误发生后其中哪一项会改变，最后核对失败状态能否跨请求保存、何时恢复，以及这些过程是否留下可解释记录。

在本次代码快照中，AIO Hub 对 Key 健康状态推进最远，Cherry Studio 的 Provider/Endpoint 数据模型最完整，LobeHub 的静态加密和重试框架最成熟，VCPToolBox 的模型编排最有特色。它们各自覆盖了渠道治理的一部分；跨 Provider 高可用、健康调度闭环、成本/延迟路由和一致的凭据备份恢复，仍是七个项目共同缺失或只提供扩展接口的部分。

## 依据与范围

- [AIO Hub LLM 渠道管理调查笔记](AIO-Hub-LLM渠道管理调查笔记.md)
- [Chatbox LLM 渠道管理调查笔记](Chatbox-LLM渠道管理调查笔记.md)
- [Cherry Studio LLM 渠道管理调查笔记](Cherry-Studio-LLM渠道管理调查笔记.md)
- [LobeHub LLM 渠道管理调查笔记](LobeHub-LLM渠道管理调查笔记.md)
- [SillyTavern LLM 渠道管理调查笔记](SillyTavern-LLM渠道管理调查笔记.md)
- [VCPChat LLM 渠道管理调查笔记](VCPChat-LLM渠道管理调查笔记.md)
- [VCPToolBox LLM 渠道管理调查笔记](VCPToolBox-LLM渠道管理调查笔记.md)

本文只比较上述笔记记录的代码快照，不把 README 宣称、未接线模块、框架扩展点、托管版私有配置或外部聚合网关能力直接计入当前实现。未运行真实账号下的限流、断网、重复计费、跨平台凭据读取和恢复演练；涉及这些行为的结论以源码可确认边界为限。
