# LLM 渠道管理横向对比

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、DeepSeek Harness、Dify、Hermes Agent、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、Risuai、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-28
>
> 依据：同目录十九份源码调查笔记及其中记录的代码快照
>
> 对比方法：统一比较渠道数据模型、配置生命周期与管理入口、协议适配、SDK 使用与请求组装、模型目录、多 Key、重试与故障转移、凭据、备份、检测和可观测性；未运行跨项目 benchmark
>
> 对比范围：渠道数据模型、配置生命周期与管理入口、协议适配、SDK 使用与请求组装、模型目录、多 Key、重试与故障转移、凭据、备份、检测和可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

十九个项目表面上都有 Provider、模型和 API Key 设置，实际承担的职责并不相同。AIO Hub、Cherry Studio、DeepChat、Dify、LobeHub 和 Open WebUI 把连接或 Provider 作为稳定实体；Chatbox、NextChat、Pi 与 OpenCode 以代码注册表加用户覆盖组织渠道；AstrBot 按“来源 + 能力实例”拆分；Jan 将远程 Provider 与本地推理引擎统一到本地 router；Hermes Agent 以声明式 Profile、端点配置和凭据池运行；SillyTavern 保存整套 Connection Profile；VCPChat 与 VCPToolBox 分别位于单网关客户端和单上游编排层；Risuai 把渠道摊薄到模型条目加全局设置字段，没有独立渠道实体。因而，“支持多少 Provider”不能直接代表多实例、故障转移或凭据治理能力。

横向核验后的主要结论如下：

- **AIO Hub 的本地渠道运行状态最完整。** `LlmProfile` 同时容纳协议、端点、模型和多 Key；21 种可见渠道类型包含四类聚合服务入口，渠道身份再经模型路由解析到实际协议适配器。Key 具有启停、错误计数、429 熔断和恢复状态；渠道层单次调用不换 Key，但主聊天链路在应用层等待重试（默认最多 2 次、3 秒固定间隔，429 追加 5 秒惩罚）并重新选 Key，失败 Key 已熔断/标坏时重试即换 Key；仍无跨 Profile 故障转移。
- **Cherry Studio 的 Provider 实例模型和认证边界最规整。** 预设、用户差量、Endpoint Type、Adapter Family、模型覆盖和多种认证被拆成明确层次；同一预设可复制成多条独立渠道。多 Key 只做跨请求轮询，普通聊天默认不重试。
- **LobeHub 在服务端凭据保护和重试框架上领先。** Provider 凭据以 AES-GCM 密文进入 PostgreSQL，Agent Runtime 有错误分类、指数退避和结构化重试事件。开源普通 Provider 仍固定 `providerId + modelId`；`RouterRuntime` 的扩展能力不能等同于已经配置好的跨渠道高可用。
- **Chatbox 的优势是注册表、模型目录和通用客户端的可预期行为。** 它覆盖多种内置 Provider、四类自定义协议、OAuth 和多来源模型数据，对 429/5xx 做同渠道重试。它没有多 Key 池，内置 Provider ID 也只能保存一个端点实例。
- **SillyTavern 侧重快速切换完整使用环境。** Connection Profile 把 API、URL、模型、Preset、模板、Proxy 和 Secret 引用一起保存，适合角色与生成配置联动切换；它不是带健康状态的 Provider 池，多 Key 需要人工选择。
- **VCPChat 是单网关客户端。** 它把上游 Provider 选择留给 VCP 服务端，客户端只保存一组 URL/Key 和各 Agent 的裸模型 ID。这个边界降低了客户端配置复杂度，也形成单连接故障点。
- **VCPToolBox 是协议与模型编排层，不是多 Provider 渠道池。** 它统一多种入站协议，支持模型别名、语义选模、特定请求的模型 fallback 和普通请求重试；所有核心请求仍走同一个 OpenAI-compatible 上游和同一枚 Key。
- **Pi 是代码注册 Provider + 多层覆盖，不是渠道管理产品。** 39 个内置 Provider 由代码构造（`providers/all.ts`），用户配置（`models.json`）、pi.dev 远端目录和扩展注册逐层覆盖模型与凭据；每 Provider 一粒凭据（auth.json 0600 明文 + 文件锁），无多 Key、无跨 Provider failover。重试分 SDK 层与消息层两级，同渠道内完成；OpenRouter/Vercel Gateway 的上游路由作为请求字段交给聚合服务。
- **OpenCode 是运行时组装型渠道层。** 每个 Provider 是「models.dev 目录 + 插件 hook + config 覆盖 + env 探测 + auth.json 凭据」在进程内组装的只读记录（`src/provider/provider.ts:1343-1668`）；模型目录来自 `https://models.opencode.ai/api.json` 的 5 分钟 TTL 缓存 + 构建期快照 fallback。请求走 AI SDK 的 `streamText`（内置 Provider 表 + npm 动态安装），另有可选的 native 协议实现。单 provider 单凭据、无多 Key、无跨渠道 failover；重试三层（会话级 `Effect.retry` 上限 5 次 / SDK maxRetries / native 指数退避）都不改变目标；Anthropic/Bedrock 请求默认自动做 prompt caching，可通过 `setCacheKey` 关闭。
- **DeepSeek Harness 是 Pi 家族衍生：渠道治理全在 dsh 侧，pi-ai 只贡献模型目录、Provider 构造与事件流。** `LlmRuntime` 持有 route → adapter 实例注册表，route 只是注册键不是用户实体，注册与替换同步原子；直连适配器 `dsh-llm-deepseek`（fetch + SSE）与 pi-ai 适配器 `dsh-llm-pi-ai`（复用 `@earendil-works/pi-ai`）自始实现同一 `StreamChunk` 词汇以验证 seam 中性，凭据解析、retry policy、settings 分层与错误分类全在 dsh 侧。key 永不进配置：只存 `apiKeyEnv` 引用，经凭据 seam 每请求解析（继承环境 > `.credentials.yaml` > `.env`）；重试在 agent 步边界由 `agent/request-error` 瀑布执行，normal 默认最多 2 次；模型目录是配置，不自动刷新。
- **Risuai 的“模型 ID 即渠道 + 全局活动设置”形态把渠道实体弱化到极限。** 渠道由模型条目加全局设置字段组合表达，多连接靠内置条目变体、`reverse_proxy` 单例、`xcustom::` 数组与插件条目；凭据全库明文，Web 请求经 `/proxy2` 中转完整经过第三方进程，请求日志原样记录含鉴权头的 headers。失败处理分同模型重试、按任务模式分离的模型 fallback 候选链与工具链重试，候选是任意模型 ID 的用户静态配置，触发条件不是健康状态。
- **AstrBot、DeepChat 与 Open WebUI 都是服务端/主进程渠道层，但治理重点不同。** AstrBot 允许同一来源生成多个能力实例，错误驱动换 Key，并在图片能力或空输出时走显式 fallback；DeepChat 将 Provider、ModelConfig、runtime registry 与 QPS 队列分开；Open WebUI 以 URL 配置行表示连接，OpenAI 模型固定到首见连接，Ollama 同名模型可随机选后端。
- **Hermes Agent 是样本中唯一确认实现显式跨渠道 fallback 链的项目。** 它把应用重试、同 Provider credential pool、模型 fallback、跨 Provider/端点 fallback 与恢复主通道分成四层。该链需用户配置，不是健康感知的动态路由器；切换后会重发同一任务，存在重复生成与计费可能。
- **Jan 的多 Key 与凭据边界较完整。** 主 Key 加 fallback Key 链保存在 OS keyring，401/403/429 会在当前请求换 Key；远程 Provider 与 llama.cpp/MLX 本地引擎都经本地 router 暴露为 OpenAI-compatible 路径。它不做跨 Provider failover。
- **NextChat 与 Manifold Desktop 是轻量客户端路线。** NextChat 用 Provider 枚举、adapter、客户端 store 和 Next.js 代理组合渠道，服务端可从逗号 Key 随机选一枚但失败不换 Key；Manifold Desktop 只有每 Provider 单 Key、全局默认选择和少数 adapter，且本地 Proxy/Ollama 路径存在已确认的拼接/协议不一致。
- **渠道配置的底层能力与管理界面覆盖经常不一致。** AIO Hub、Cherry Studio、DeepChat 和 Open WebUI 已提供较完整的图形化生命周期；OpenCode 的配置文件能修改完整 Provider 定义，复用同一设置页的 Web 与桌面端却只能新增自定义渠道或断开已有渠道，不能从界面编辑已保存的定义；Manifold Desktop 也只能在桌面设置页修改 Ollama endpoint，兼容 Provider 的新增和编辑仍依赖手工修改配置文件。
- **没有一个项目实现完整的健康感知跨 Provider 高可用闭环。** Hermes Agent 已能按静态配置链跨 Provider/端点切换，AstrBot 也有特定触发条件的模型 fallback，Open WebUI 的 Ollama 可随机分摊；但十八者都缺少“持续健康采集 -> 动态选路 -> 失败换渠道 -> 恢复探测”的完整闭环。
- **成本、延迟和配额数据普遍没有进入调度。** 模型定价、连接延迟、NewAPI 监控或批量检测即使存在，也主要用于展示和人工判断，不直接决定下一次请求走哪条渠道。
- **凭据保护差异明显。** LobeHub 对数据库 Provider 凭据做 AES-GCM 加密；Jan 与 Manifold Desktop 分别使用 OS keyring 和 Windows Credential Manager。Hermes Agent 以 `.env`/`auth.json` 分层存储并在日志、UI、备份和子进程环境中脱敏，但底层文件不是密文库。其余多项目仍有明文配置或客户端持久化边界。备份是否包含 Key 必须单独核对。
- **SDK 使用分三类：AI SDK 统一抽象、官方 SDK 直用、自研协议实现。** 凡项目级重试与 SDK 重试并存的项目都显式分权——Chatbox、Cherry Studio 与 DeepSeek Harness 关闭 SDK 内层 retry，Pi 镜像官方 SDK 判定；SDK 只承担协议层，渠道决策、Key 选择与平台传输都在 SDK 之外。
- **不适合给十八者排一个总名次。** 桌面多模型客户端、服务端 Agent 平台、IM 机器人、角色扮演前端、单网关客户端、AI 中间层和终端编码 Agent 面对的管理边界不同。更有用的比较是判断能力位于哪一层，以及失败时是否真的改变 Provider、URL、Key 或模型。

AstrBot 的 SSYCloud 接入、元数据备用端点与推理强度预设，继续落在来源实例、模型目录和请求预设三层；Cherry Studio 则补充了 DeepSeek V4 的路由与图像目录，并让 Pi/DeepSeek Harness 的模型选择经过独立兼容性解析。这些变化强化了“渠道目录、运行时可选模型和实际请求协议”应分开比较的口径。

## 一览矩阵

| 项目 | 核心连接对象 | 模型身份 | 多 Key / 当前请求换 Key | 普通重试 | 跨 Provider/端点 failover | 凭据静态边界 |
|---|---|---|---|---|---|---|
| Dify | tenant 下的 Provider 配置、模型设置与 Provider/模型两层凭据 | 应用或节点引用 Provider、模型类型与模型名，运行时由 ModelManager 解析实例 | 同模型多份 credential 可轮询；限流、授权和连接异常可冷却并改选 | 同一模型凭据池内处理可恢复异常 | 未确认跨 Provider failover | 凭据经 tenant 作用域加密保存，读取时脱敏 |
| AIO Hub | `LlmProfile` | `profileId + modelId` | 结构化 Key 池 / 渠道层不换，聊天应用层重试时重选（可换） | 渠道层无；聊天链路默认最多 3 次尝试 | 无 | 明文本地配置 |
| AstrBot | `provider_sources` + 能力 `provider` 实例 | provider instance + model | Key 数组 / 429、无效时换 | transport 5 次 + adapter 最多 10 次 | 仅图片能力、空输出/错误的配置 fallback | `cmd_config.json` 明文；Dashboard 可返回完整 Key |
| Chatbox | Provider 注册项 + 设置 | `provider + modelId` | 单 Key / 不适用 | 429/5xx 最多 5 次 | 无 | Electron Store 明文 |
| Cherry Studio | `user_provider` 实例 | 含 `providerId` 的模型标识 | 结构化数组 / 不换 | 默认关闭 | 无 | SQLite JSON 明文，renderer 边界收窄 |
| DeepChat | `LLM_PROVIDER` + `ModelConfig` + runtime registry | `provider.id + modelId` | 单 Provider 凭据 / 无多 Key | runtime/adapter 依定义；无统一跨渠道重试 | 无 | apiKey 明文存 SQLite；OAuth 走 OS safeStorage |
| DeepSeek Harness | `LlmRuntime` 注册表 route → adapter 实例 | provider + model | 每 route 单凭据 / 不换 | agent 步边界，normal 默认最多 2 次 | 无 | `.credentials.yaml` 0600 明文；配置只存 `apiKeyEnv` 引用 |
| Hermes Agent | ProviderProfile + endpoint config + credential pool | provider + endpoint + model | credential pool / 401、429 等换 | 应用层默认 3 次 | **有，显式 fallback 链** | `.env`/`auth.json` 分层明文，日志/UI/备份脱敏 |
| Jan | 远程 Provider + 本地 llama.cpp/MLX router | provider + model | 主 Key + fallbacks / 401、403、429 换 | Key 链内重发 | 无 | OS keyring |
| LobeHub | `ai_providers` | `providerId + modelId` | 逗号 Key / 无稳定保证 | Agent Runtime 默认 5 次 retry | 普通 Provider 无；Router 可扩展 | PostgreSQL AES-GCM |
| Manifold Desktop | ProviderRegistry + 单 Key | providerId + model | 单 Key / 不适用 | 无 | 无 | Windows Credential Manager |
| NextChat | Provider 枚举 + adapter + access store/代理 | `model@provider` | 服务端逗号 Key随机选 / 失败不换 | 无统一 retry | 无 | 客户端 store 明文；服务端 env |
| Open WebUI | OpenAI/Ollama URL 配置行 | model id + urlIdx/prefix | 每连接单 Key / 不换 | 无 | OpenAI 无；Ollama 同名模型随机分摊但失败不换 | DB persistent config，静态加密未确认 |
| OpenCode | models.dev + config + auth 运行时记录 | `provider/model[/variant]` | 单 Key / 不换 | Effect（上限 5 次）+ SDK + native 三层 | 无 | auth/SQLite 明文（0600 文件） |
| Pi | Provider 代码注册项 + 覆盖层 | `provider + modelId` | 单 Key / 不换 | SDK + 消息层，默认最多 3 次 | 无 | auth.json 0600 明文 |
| Risuai | 模型条目 + 全局 Database 字段 | 模型 ID | 单 Key / 不适用 | 同模型 `requestRetrys` 默认 2 | 用户静态 fallback 候选链（按任务模式） | `database.bin`/IndexedDB 明文 |
| SillyTavern | 活动设置 + Connection Profile | source/Profile model | Secret 数组 / 人工切换 | 无统一 retry | 无 | `secrets.json` 明文，前端只见掩码/ID |
| VCPChat | 全局 VCP URL/Key | 裸 model id | 单 Key / 不适用 | 无 | 无 | `settings.json` 明文 |
| VCPToolBox | 全局上游 URL/Key | 上游或虚拟 model id | 单 Key / 不适用 | 默认 3 次总尝试 | 本地无；语义模型可换候选模型 | `.env` 明文 |

矩阵中的“重试次数”沿用各项目自己的配置语义，不能直接横比。Chatbox 计总 attempt，LobeHub 配置 retry 次数，VCPToolBox 的 `ApiRetries` 表示总尝试数；AIO Hub 的渠道层不重试，重试在聊天应用层（默认最多 2 次、可配置间隔与模式）并重新选 Key；Pi、OpenCode、AstrBot 与 Hermes Agent 还各自叠加多层重试；Risuai 的 `requestRetrys` 是同一模型内的最多重试次数，fallback 候选链推进会整体重发请求。Hermes Agent 的静态 fallback 链是本次确认最完整的跨 Provider/端点通用链路，Risuai 的模型 fallback 候选链也能沿用户配置的模型 ID 跨 Provider 切换，但两者都不是按实时健康动态选择。

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
| 配置管理覆盖 | 分别核对配置文件、CLI、TUI、Web 和桌面端对已有与新建渠道提供的操作 | 底层 schema、数据库或 API 存在相应读写能力 |

这组定义解释了几个常见现象：多 Endpoint 通常解决协议选择，不等于容灾；`@模型` 并行调用解决结果比较，不等于失败候补；模型目录拉取失败后的本地列表 fallback 也不表示推理请求能够切换渠道。

## 架构分型

### 1. Provider 实体型：AIO Hub、Cherry Studio、LobeHub

这三者都有稳定的渠道实体，并把模型归属显式绑定到 Provider。

AIO Hub 的 `LlmProfile` 是聚合根，协议类型、Base URL、Key 池、模型、Header、端点和网络选项集中在一条记录中。优点是编辑、导入、请求构造和健康状态都围绕同一个 ID 展开；代价是 Profile 承担的字段较多。模型执行还会按显式路由绑定、端点类型唯一识别和 Provider 默认映射依次解析。New API、Sub2API、通用聚合与 OpenCode Go 等渠道名称表达配置身份，最终线协议仍由解析结果决定。

Cherry Studio 用三层合并减少重复：Registry 保存 Provider/模型基线，用户表保存实例及差量，运行时再应用默认值。Endpoint Type 和 Adapter Family 分开后，同一 Provider 可以拥有多个协议端点，模型还可覆盖默认端点。这个结构适合长期维护不断增加的 Provider 和认证方式，但高可用状态没有进入这套实体模型。

LobeHub 把 Provider 与模型分表保存于 PostgreSQL，内置目录、环境变量和用户配置在运行时合并。这一模型身份贯穿模型选择，适合多用户和工作区作用域。它还提供 `RouterRuntime` 扩展面，但普通 Provider 调用和 Router 是两条不同路径；没有真实路由配置时，只能评价框架能力，不能归入已部署的跨渠道调度。

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

如果该上游地址指向 NewAPI、One API 等聚合服务，多 Provider 池、倍率、渠道熔断可能发生在聚合服务内部。VCPToolBox 本地看不到这些实体和状态，因此横向比较时只能把它记为“依赖外部渠道管理”，不能把外部网关的能力归入本项目。

### 6. 代码注册 + 组合覆盖型：Pi

Pi 的 Provider 是 `packages/ai` 里的 TypeScript 对象：39 个内置 Provider 在 `builtinProviders()` 中构造，用户没有“新建渠道”的 UI 或数据表。渠道变化全部表达为覆盖：`models.json` 改地址、Key 与模型，模型级覆盖改单模型字段，扩展 `registerProvider` 注册新 Provider，Radius 网关按配置生成新 id。凭据每 Provider 一粒，运行时 API key 是内存覆盖，OAuth 令牌自动刷新。模型目录是“构建期生成 + pi.dev 远端叠加 + 用户定义 + 扩展”四层合并，这使静态代码看不到完整模型清单。它面向单机 CLI 工作流，渠道管理能力止于“可配置、可覆盖、可重试”，没有实例管理、多 Key 或健康调度。

### 7. 运行时组装型：OpenCode

OpenCode 的 Provider 不是持久化实体也不是纯代码注册项，而是每次启动在进程内按固定顺序组装出的只读记录：models.dev 目录（`packages/core/src/models-dev.ts`）→ 插件 hook → config 覆盖 → 环境变量探测 → auth.json 凭据 → 插件凭据加载器 → 内置 `custom(dep)` 适配器。模型目录是「磁盘缓存 → 构建期快照（OPENCODE_MODELS_DEV）→ 网络」三级数据源，TTL 5 分钟、每小时刷新，仓库内没有硬编码模型清单。请求主路径是 Vercel AI SDK 的流式接口（内置 Provider 表 + 未收录包名 npm 动态安装），另有可选的 native 协议实现（`packages/llm/src/protocols/`，仅 openai/opencode/anthropic 且非 OAuth）。多端点通过注册多个自定义 provider id 表达（config 的 options 项没有数组形态）。它面向服务端 Agent 工作流：session 解析 `provider/model[/variant]`，无 `@`/`#`/`:latest` 语法；重试与故障转移全部在同渠道内完成。

### 8. 来源 + 能力实例型：AstrBot

AstrBot 将可复用的 `provider_sources` 与具体能力实例分开。同一来源可派生 Chat、STT、TTS、Embedding、Rerank 等多个实例，运行时按会话偏好、全局默认和实例列表顺序选择。它已经有错误驱动 Key 轮换和少数明确触发的 fallback，但默认配置中的 provider pool/权重没有运行时消费者。

### 9. Provider/连接实体 + runtime registry：DeepChat、Open WebUI

DeepChat 的 Provider 记录、ModelConfig、能力快照和 AI SDK behavior registry 分层，适合在桌面主进程统一多协议、媒体和 QPS 队列。Open WebUI 则把每条 Base URL 作为连接行，并在服务端把 OpenAI-compatible 与 Ollama 模型合并成统一目录。二者都有稳定连接身份，但都没有通用跨连接故障转移；Open WebUI 只有 Ollama 同名模型的随机后端选择。

### 10. 本地 Router 聚合型：Jan

Jan 把远程 Provider 与本地 llama.cpp/MLX 引擎都放到本地 router 背后，前端 AI SDK 请求按模型 ID 被路由。它的 Provider 配置较轻，但参数能力表、Key 链、keyring 和本地模型生命周期较完整。失败换 Key发生在同 Provider，跨 Provider 仍需用户切换。

### 11. Profile + 凭据池 + fallback 链：Hermes Agent

Hermes Agent 的 ProviderProfile 是声明，不持有客户端；用户端点配置、凭据池和 transport 在运行时解析。它是本次唯一把同 Provider 多 Key、同渠道模型 fallback 与跨 Provider/端点 fallback 明确拆成独立层次的项目。连接测试走独立探针，不覆盖真实 resolver、凭据池和 fallback 链。

### 12. 枚举/注册表 + 轻量代理：NextChat、Manifold Desktop

NextChat 以 Provider 枚举、平台 adapter、客户端 access store 和 Next.js 代理组合；Manifold Desktop 以 C++ ProviderRegistry 和 Windows Credential Manager 组合。两者都适合小型客户端，但缺少健康状态、自动故障转移和规范化多实例生命周期；Manifold 的 Ollama/Proxy 路径还存在当前快照已确认的端点拼接和协议不一致。

### 13. 注册键 + 双适配器型：DeepSeek Harness

DeepSeek Harness 的 Provider 是 `LlmRuntime` 注册表里的 route 键，不是用户实体：同一 adapter 实例可注册多条 route，注册与替换同步原子，请求观察不到注册空隙。两个适配器自始实现同一流式词汇——直连适配器走 fetch + SSE，pi-ai 适配器复用 `@earendil-works/pi-ai` 的 Models 集合、Provider 构造与事件流；凭据解析、retry policy、settings 分层与错误分类全在 dsh 侧，SDK 重试被强制为 0。key 永不进配置，只存 `apiKeyEnv` 引用，经凭据 seam 每请求解析到 0600 的 `.credentials.yaml` 托管文档或继承环境。重试在 agent 步边界，normal 默认最多 2 次；模型目录是配置，不自动刷新。HTTP 代理配置本次未找到。

### 14. 模型 ID 即渠道 + 全局活动设置型：Risuai

Risuai 把渠道拆散成模型条目与全局活动设置，没有独立实体：模型 ID 决定 Provider 分类、协议格式、端点与 Key 标识，URL 与 Key 则取自唯一 `Database` 对象的字段级覆盖；多连接靠内置条目变体、全局 `reverse_proxy` 单例、`xcustom::` 自定义数组与插件条目表达。失败处理分同模型重试、按任务模式分离的模型 fallback 候选链与工具链重试，候选是用户静态配置的任意模型 ID，触发条件是错误与空响应，不是健康状态。

## 渠道身份与配置复用

稳定身份决定了模型收藏、历史记录、统计和故障切换能否准确指向原连接。

| 项目 | 渠道身份策略 | 复用同一服务的方式 | 主要边界 |
|---|---|---|---|
| AIO Hub | 独立 Profile ID | 新建或导入 Profile | 无跨 Profile 同模型聚合 |
| AstrBot | provider instance id，引用 source id | 同一 source 派生多个能力/模型实例 | pool/权重配置无运行时消费者 |
| Chatbox | 内置 ID 或自定义 UUID | 内置单例；额外连接建自定义 Provider | 内置和自定义能力可能不完全等价 |
| Cherry Studio | 独立 `providerId` + 可选 `presetProviderId` | 复制预设生成新实例 | Registry 更新需遵守用户差量合并语义 |
| DeepChat | Provider id + ModelConfig | 新建 custom Provider 或复用 apiType behavior | ACP backend 与普通 Provider runtime 分离 |
| Hermes Agent | ProviderProfile 名 + endpoint 配置项 | 多个 custom provider 条目/显式 fallback 条目 | 内置 Provider 默认单配置块，连接测试不复用真实 resolver |
| Jan | Provider id；本地模型另由 model id 路由 | 自定义 OpenAI/Anthropic compatible Provider | 远程 Provider 与本地引擎共享 router，但生命周期不同 |
| LobeHub | 内置或自定义 Provider ID | 额外连接使用不同自定义 ID | 同一内置 ID 只存一组 vault |
| Manifold Desktop | ProviderRegistry id | 手工配置 OpenAI-compatible 实例 | 设置页不能新增任意自定义 Provider |
| NextChat | ServiceProvider/ModelProvider + `model@provider` | 各枚举渠道一组设置；自定义 URL 覆盖 | 不是任意多实例实体，用户/服务端配置双来源 |
| Open WebUI | URL 列表索引 `urlIdx` + 可选 prefix | 增加连接行 | OpenAI 同名模型首见连接获胜；删行会重排序号 |
| SillyTavern | Profile UUID，内部仍引用活动设置字段 | 保存多份 Profile | 快照字段可能随功能增长产生兼容负担 |
| VCPChat | 无渠道实体 | 直接替换全局网关 | 裸模型 ID 缺少网关命名空间 |
| VCPToolBox | 无上游渠道实体 | 直接替换全局上游 | 无法并存或选择多条上游连接 |
| Pi | Provider id（代码注册项） | `models.json`/扩展覆盖；Radius 网关按配置生成新 id | 同服务多账号只能并入单凭据或依赖 Radius 多实例 |
| OpenCode | Provider id（branded string，内置 11 个 + 自定义） | 注册多个自定义 provider id；同 id 单凭据 | `options` 无数组形态，多端点需新 id；模型别名经 config `models.<alias>.id` |
| DeepSeek Harness | route 注册键（adapter 声明 route 集，原子 replace） | 同一 adapter 实例多 route；pi-ai 一实例多 profile；settings 加 route | 无用户渠道实体；settings 只能加 route、删不掉 base 的 route |
| Risuai | 模型条目 ID + 全局字段覆盖 | 内置条目变体、`reverse_proxy` 单例、`xcustom::` 数组、插件条目 | 无独立渠道实体；同一 Provider 多连接靠条目复制与自定义条目维护 |

Cherry Studio 的 `providerId` 与 `presetProviderId` 分离值得借鉴。前者保证用户实例稳定，后者保留继承关系；用户可拥有两条继承同一预设、但凭据和端点独立的渠道。AIO Hub 的 Profile 也能直接表达多实例，结构更集中。LobeHub 和 Chatbox 可以用自定义 ID 达到类似结果，但内置实例和自定义实例需要按各自规则管理。

VCPChat 和 VCPToolBox 则应作为另一种部署选择看待。它们预期多渠道复杂度由统一上游承担，本地不必再复制一套 Provider 池。只有当上游确实提供并运维这些能力时，这种简化才成立；单一自建接口本身不会自动获得容灾。

## 配置入口与操作覆盖

渠道配置是否能落盘，与用户能否在当前入口维护已有渠道是两个问题。下表优先记录产品提供的管理入口；“无”表示单项目笔记在当前源码范围内未找到相应操作，不把手工改数据库或二进制文件算成正式管理能力。界面入口、状态和事件绑定来自静态源码，保存结果、平台文件对话框和实际网络测试仍以各单项目笔记的未验证项为准。

| 项目 | 主要管理入口 | 已有配置 | 新建与复制 | 启停与删除 | 导入导出与连接测试 |
|---|---|---|---|---|---|
| AIO Hub | 桌面端与移动端各自的设置页 | 两端均可完整编辑；配置分别持久化 | 均可新建；无直接复制按钮 | 均支持 | 桌面端支持渠道导入导出；两端有模型/能力探测 |
| AstrBot | Dashboard；配置文件为补充入口 | source 与 provider 均可编辑 | 可新建；复制只覆盖非聊天 provider | provider 可启停/删除；删 source 会级联 | 只有整体备份，无渠道级导入导出；已加载 provider 可测试 |
| Chatbox | 桌面端与 Web 共用 Provider 设置页 | 内置项可改公开设置，自定义项可完整编辑和删除 | 可新建自定义渠道；无复制 | 无渠道启停；只删自定义项 | Provider JSON/深链导入，导出随通用备份；可发测试请求 |
| Cherry Studio | Electron Provider Settings | 可编辑完整实例；规范预设不能改身份或删除 | 可新建自定义渠道，也可复制 Provider | 支持启停；只删用户实例 | 支持 deep link 导入和数据库备份，无 Provider 专用导出；支持模型/Key 检查 |
| DeepChat | Electron 设置页与本地 CLI | 可编辑；自定义渠道可删除 | 可新建自定义渠道；无复制 | 支持启停；只删自定义项 | 桌面端有导入向导、无 Provider 导出；桌面端与 CLI 均可测试 |
| DeepSeek Harness | Web Models 设置页、配置文件与有限 CLI | 可编辑凭据、地址和模型；只有用户层 profile 可删除 | 可从目录或自定义表单新增；无复制 | 页面无 route 级启停；只删用户新增项 | 无渠道导入导出；模型发现只探测目录，不等于聊天健康测试 |
| Hermes Agent | Electron Desktop Settings；CLI 可编辑更完整配置 | 桌面端可编辑自定义 endpoint | 可新增 endpoint；无复制 | 可激活；非 direct-config 项可删除，无 endpoint 停用 | 桌面端无 endpoint 导入导出；Test 只验证 `/models` |
| Jan | Tauri WebView 设置页 | 内置远程渠道编辑受限，自定义渠道可编辑和删除 | 可新建自定义渠道；无复制 | 支持启停；只删自定义项 | 无 Provider 导入导出；API Key 面板逐 Key 请求 `/models` |
| LobeHub | Web/桌面共享设置页与 CLI | 内置项按元数据编辑，自定义项可编辑和删除 | 可新建自定义渠道；无复制 | 支持启停；只删自定义项 | 只有数据库级备份，无 Provider 专用导入导出；Web 与 CLI 均可测试 |
| Manifold Desktop | `settings.json`；Windows 设置页只覆盖少量字段 | 桌面端只能改 Ollama endpoint，不能改已有 compatible Provider | 配置文件可手工新增；桌面端不能新增或复制 | 只可在文件中控制 compatible 项；桌面端无启停/删除 | 无渠道导入导出；虽有底层校验消息，设置页没有测试按钮 |
| NextChat | Web 与 Tauri App 共用设置页 | 可编辑每个枚举 Provider 的单一全局槽位 | 无渠道实例新增或复制 | 只有全局自定义配置开关，无逐渠道启停/删除 | 仅整套本地状态备份；无普通 LLM 连接测试 |
| Open WebUI | 管理员 Web Connections | 连接行可完整编辑 | 可新增连接；无复制 | 逐连接启停和删除均支持 | 无单连接导入导出，通用管理员配置支持 JSON；有独立 `/verify` |
| OpenCode | 配置文件；Web 与桌面端共用 Provider 设置页 | 配置文件可完整修改；界面中的已有渠道只能 Disconnect，不能载入表单编辑定义 | 界面可新增自定义渠道；无复制 | 配置文件可控制启停和删除定义；界面断开自定义项时移除凭据并禁用 | 无 Provider 导入导出或独立连接测试 |
| Pi | `models.json`；CLI/TUI 只管理认证和模型选择 | 配置文件可覆盖定义；TUI 只能登录、登出和选模型 | 文件可定义新 Provider；无产品化复制 | 无渠道级启停或删除界面 | 会话导入导出与渠道无关；`auth check` 不发真实请求 |
| Risuai | Web 与 Tauri 共用设置页 | 内置模型只读；`customModels` 可编辑和删除 | 可新增自定义模型条目；无复制 | 没有 Provider/模型 enabled 状态 | 预设导入导出不等于渠道导入导出；无独立测试 |
| SillyTavern | Web；Electron 复用同一页面 | 可编辑当前 API 设置和 Connection Profile | 可从当前设置新建 Profile；无 Provider 实例或直接复制 | 通过切换 API/Profile 生效；Profile 可删除 | OpenAI preset 可导入导出；有状态探测和 Test Message |
| VCPChat | Electron 全局设置 | 可编辑唯一网关 URL、Key 和 Agent 模型 | 无 Provider 实例新增或复制 | 无逐渠道启停/删除 | 无渠道导入导出或独立连接测试 |
| VCPToolBox | Web 管理端与 `config.env` | 可编辑唯一全局上游和语义路由 | 无上游 Provider 实体；只能新增路由 preset/route | 无逐上游启停/删除 | 全目录备份不等于渠道导入导出；管理端可测模型目录和真实 Chat |

AIO Hub、Cherry Studio、DeepChat 和 Open WebUI 的图形入口覆盖了已有渠道编辑、新建、启停、删除和连接测试；差异主要在复制与导入导出。AstrBot 的 Dashboard 也覆盖主要生命周期，但 source、聊天模型 provider 和其他能力 provider 的复制、删除与测试规则不同，不能压成一个“全支持”。LobeHub 的 Web、桌面和 CLI 共用服务端权限与持久化边界，入口较完整，但仍没有渠道复制或专用导入导出。

OpenCode 和 Manifold Desktop 展示了最明显的“底层可配置、界面不可达”。OpenCode 的 Web/桌面设置页可以创建自定义 Provider，却不能把已有 Provider 定义载回同一表单修改；Disconnect 处理凭据和禁用状态，也不等于删除配置定义。Manifold Desktop 的 `providerConfigs` 能在文件中表达多个 compatible Provider，桌面设置页却没有新增表单，也不能编辑已有 compatible endpoint。两者若只按 schema 或配置文件判断，都会高估桌面端的渠道管理能力。

NextChat、Risuai、SillyTavern、VCPChat 和 VCPToolBox 的缺项还受到数据模型影响：它们分别管理全局 Provider 槽位、模型条目、活动连接快照、单网关或单上游，并不存在可统一套用增删改查的渠道实例。横向比较应先说明实际管理对象，再评价界面是否缺少该对象已有的生命周期操作。

## 协议、端点与 Adapter

### 协议数量不等于渠道数量

AIO Hub、Chatbox、Cherry Studio、LobeHub 和 SillyTavern 都能按 Provider 或协议族构造不同请求。Cherry Studio 的拆分最明确：Endpoint Type 决定本次调用使用 OpenAI Chat、Responses、Anthropic Messages 或 Gemini GenerateContent 等接口，Adapter Family 决定协议实现，Base URL 又可按 Endpoint Type 独立覆盖。

AIO Hub 允许 Chat、Responses、Anthropic、Gemini、Embedding、Rerank 和媒体生成使用不同端点，并提供自定义 Header 与 Provider options。它适合一个 Provider 同时暴露多种能力的情形。当前模型路由编辑器支持显式绑定和批量应用探测结果；无法解析时会抛出专用路由错误，而不是退回到不可追踪的隐式猜测。

Chatbox 把内置 Provider 的 Host、Path 和模型创建逻辑收进注册表，自定义 Provider 覆盖 OpenAI Chat、OpenAI Responses、Anthropic 和 Gemini 四类协议。LobeHub 主要由内置 ID 或自定义 Provider 的 `sdkType` 选择 Runtime。SillyTavern 的 Chat Completion source 和 Text Completion type 分轨，兼容的后端数量多，但分支和 Provider 专属字段也更多。

VCPChat 固定发送 OpenAI 风格请求，并用独立 `/v1/chatvcp/completions` 表达工具注入。VCPToolBox 可以接收 OpenAI Chat/Responses、Anthropic 和 Gemini 请求，后几类先转换到内部 Chat 链；出站仍统一为 OpenAI-compatible Chat Completions。因此，VCPToolBox 的“入站多协议”解决客户端兼容，并不表示它能按上游 Provider 选择原生协议。

Risuai 把协议适配集中在请求层：主入口按 `LLMFormat` 枚举分发到各 Adapter，OpenAI 兼容协议是主干，Custom API 通过格式切换复用 Anthropic/Gemini/Responses 等 Adapter。端点多数硬编码进模型条目，用户级 URL 字段按条目覆盖；Web 模式固定经 `/proxy2` 中转，Tauri 端经 `streamed_fetch` 发起。

### 多 Endpoint 主要解决能力分派

多 Endpoint 常用于区分 Chat、Responses、Embedding、Rerank 或媒体生成。它们可能共用同一 Provider 和凭据，也可能指向不同路径。除非实现同时维护独立健康状态并在失败后改选 Endpoint，否则不能把它当作故障转移。

Cherry Studio 的 Endpoint Type、AIO Hub 的 `customEndpoints` 和 VCPToolBox 的固定 `/v1/*` 路径都属于能力分派。Chatbox 的 Host/Path 可定制，但重试仍固定当前 Provider 设置。SillyTavern 按 source/type 选择端点，OpenRouter 的路由参数则由上游执行。

## SDK 使用情况与请求组装边界

本类目考察谁构造线上请求、SDK 与项目自有逻辑如何分权，以及 SDK 依赖如何固定；协议覆盖面与端点多态细节见「协议、端点与 Adapter」一节。

### 三类请求构造层

| 项目 | 请求构造层 | 请求体与流式由谁负责 | 项目保留在 SDK 外的控制 |
|---|---|---|---|
| AIO Hub | 自研 ProviderAdapter（`packages/llm-core`）+ 平台 Transport | 协议请求体、URL、Header、流式解码与工具编解码 | Key 状态与轮询、聊天层重试、模型执行路由、探测与错误分类 |
| AstrBot | 官方 SDK：OpenAI 客户端与 `google.genai` | 协议请求体、鉴权与流式；Anthropic 适配器自行转换 | 错误分类重试循环、Key 剔除轮换、payload 修正 |
| Chatbox | 混合：统一模型类 + AI SDK adapter | OpenAI 兼容走自研模型类；Claude/Gemini/Responses 走 AI SDK | 外层重试包装（SDK 内层 retry 置 0）、代理 |
| Cherry Studio | AI SDK（Adapter Family 映射 Provider）+ 专用 builder | 协议请求体、鉴权与流式 | Endpoint Type/Adapter Family 解析、Key 轮询、重试偏好包装 |
| DeepChat | AI SDK provider factory + behavior registry | 协议请求体、鉴权与流式 | Provider→runtime 映射、QPS 队列、代理注入 |
| DeepSeek Harness | 双适配器：自研 fetch + SSE；pi-ai（自带官方 SDK，lazy 加载） | 流式统一为 `StreamChunk` 词汇 | 凭据解析、retry policy、错误分类；SDK 重试强制 0 |
| Hermes Agent | OpenAI Python SDK；Gemini 用 GeminiNativeClient | 协议请求体与鉴权 | resolver、credential pool、fallback 链；SDK 内建重试为第 0 层 |
| Jan | AI SDK `streamText` + `createCustomFetch` | SDK 协议字段 | 推理参数注入、Key 链轮换、本地/远程 router 选择 |
| LobeHub | 各 Provider Runtime（按 `sdkType`）；OpenAI 兼容 factory + `fetchSSE` | 协议请求体、鉴权与流式 | Agent Runtime 重试、apiKeyManager、RouterRuntime |
| Manifold Desktop | C++ 自研 Provider 类 | 协议请求体与 SSE 解析 | 凭据访问、模型目录、Key 校验 |
| NextChat | 平台 adapter 自研 + fetch | 协议路径、Header、请求体与流式解析 | Provider→adapter 映射、服务端代理 |
| Open WebUI | 服务端路由自研组装 | 协议请求体与 Header/凭据组装 | 连接行索引、模型合并、随机后端选择 |
| OpenCode | AI SDK（内置 Provider 表 + npm 动态安装）；native 可选 | 协议请求体、鉴权、流式与 telemetry | 目录组装、会话级 `Effect.retry`、错误归一化、usage 落库 |
| Pi | pi-ai 自研 API 层，底层复用官方 SDK 传输 | 协议请求体、鉴权与流式 | `retryProviderRequest`（镜像 SDK 策略）、消息层重试 |
| Risuai | 自研 Adapter 集合；Ollama 用 `ollama` SDK | 协议请求体与流式解析 | 同模型重试、fallback 候选链、平台网络路由 |
| SillyTavern | 自研 source 分支 + 单次 fetch + SSE 解析 | 协议请求体与流式解析 | 无统一重试；流式降级局部特例 |
| VCPChat | 自研单次 fetch | OpenAI 风格 payload | 无（单网关，URL/Key 全局） |
| VCPToolBox | 自研 `fetchWithRetry` | 入站协议转换与出站 payload | 重试策略、语义路由、取消级联 |

请求构造层决定协议兼容面与流式词汇的归属。自研实现并不等于协议覆盖少：SillyTavern 的 26 个 Chat Completion source 与 Risuai 的 24 个 LLMFormat 分支都是自研，覆盖面反而最宽；官方 SDK 直用者获得协议兼容与原生错误类型，却要在 SDK 之外叠加重试与 Key 逻辑；AI SDK 使用者把协议差异压缩进 provider 抽象，代价是协议行为受 SDK 版本约束。

### SDK 内外的职责划分

AI SDK 使用者（Cherry Studio、DeepChat、OpenCode、Jan，以及 Chatbox 的部分协议）把协议请求体、Header 与流式解析交给 SDK，项目代码只保留 Provider 解析、Key 选择和模型路由等渠道决策。四家的映射入口不同，但共同点是渠道决策全部发生在 SDK 调用之前；SDK 内建重试不会重新执行 Provider、模型或 Key 的选择，这与「重试、模型回退与跨渠道故障转移」一节的核验一致。

官方 SDK 直用者把 SDK 内建行为当作契约处理。AstrBot 在 OpenAI 客户端之上做错误分类、最多 10 次内层重试与 Key 剔除轮换，Gemini 适配器依赖 `google.genai`；Hermes Agent 把 OpenAI SDK 内建重试明确列为第 0 层，其上再叠加应用层重试、credential pool 与 fallback 链；Pi 的 SDK 层重试复制官方 SDK 的 `x-should-retry` 与 `retry-after` 判定，而不是绕过它。

自研协议实现者拥有最完整的控制面：请求体、SSE 解析、错误分类与重试全部自有，不需要协调 SDK 策略；代价是协议兼容与上游字段演进（如 Responses 新字段、推理摘要）都要自己跟踪。DeepSeek Harness 刻意让直连 fetch 适配器与 pi-ai 库适配器自始实现同一 `StreamChunk` 词汇，用双实现钉住协议语义。

SDK 自带重试与项目级重试并行时，需要显式分权。Chatbox 与 Cherry Studio 把 AI SDK 内层 retry 置 0，由外层包装接管；DeepSeek Harness 强制 SDK 自动重试为 0，把重试全部移到 agent 步边界，理由是流已发出部分 chunk 后不可重放；OpenCode 的会话级、SDK 级与 native 级三层重试各自独立配置。未做分权的项目要接受模糊边界，例如 LobeHub 的重试是否换 Key 取决于 Runtime 生命周期，而不是明确决策。

### SDK 依赖固定与传输层边界

SDK 依赖的固定方式影响渠道层的升级一致性。OpenCode 对未收录的 provider 包用 npm 动态安装，把 SDK 依赖推迟到运行时；LobeHub 的 `sdkType` 类型层保留 14 种、创建界面收敛为 9 种，形成 API 可写而 UI 不可达的差异；DeepSeek Harness 用编译期 drift gate 拦截 pi-ai 升级带来的模态、思考等级与思考格式漂移。

请求构造层与网络传输层分离是另一条观察轴。AIO Hub 把协议适配放在共享 Core，桌面端再经 Rust 代理或 WebView fetch 发送；Risuai 的适配器之上统一走平台路由，Tauri 端经 `streamed_fetch`、Web 端经 `/proxy2` 中转；Open WebUI 的管理员连接由服务端代发，用户 Direct Connections 则由浏览器直连；NextChat 的 Web 模式经 Next.js 代理，App 模式直连官方 URL。无论使用哪种 SDK，平台边界（CORS、代理、本地文件、凭据暴露面）都由项目自有的传输层处理，这解释了同一协议在不同项目里呈现的可用性与安全差异。

## 模型目录与元数据

模型目录在十九个项目中承担三种不同职责：发现可用模型、补充展示与能力信息、决定运行时请求行为。

| 项目 | 主要来源 | 模型归属 | 元数据对运行时的作用 |
|---|---|---|---|
| AIO Hub | 远端目录 + 本地规则 + 手工维护 | Profile | 能力、端点和参数可参与请求构造 |
| AstrBot | 适配器配置、Provider API 与 `LLM_METADATAS` | Provider 实例/source | 模态、工具、上下文等影响 fallback 和 payload |
| Chatbox | Provider API、后端 manifest、本地保存、models.dev | Provider | 能力富化和模型实例化 |
| Cherry Studio | Registry + 上游目录 + 用户覆盖 | Provider | Endpoint、能力和参数多层合并 |
| DeepChat | 默认目录 + Provider DB 聚合 JSON + 用户 customModels/config | Provider | 有效能力快照决定 route、tool、媒体和 endpoint |
| DeepSeek Harness | 直连适配器配置列表（默认 V4 Flash/Pro）；pi-ai 安装目录 + `models` 整表替换 + `modelOverrides`；无自动刷新 | Provider/route | 上下文、输出上限、思考等级参与请求构造；未列出 id 直连 pass-through、pi-ai 报 `UNKNOWN_MODEL` |
| Hermes Agent | 静态表 + OpenRouter/Nous 远端缓存（`provider_models_cache.json`）+ 用户输入 + custom 端点 `/v1/models` 探活磁盘缓存（`custom:<base_url>` 键 + blake2b 凭据指纹 TTL，models.py:4737） | Provider/endpoint | profile 与 metadata 决定 transport、上下文和辅助模型 |
| Jan | Provider `/models`、远端目录、本地 GGUF/MLX 下载库 | Provider/本地引擎 | capability 与参数表决定 wire 字段和 router 目标 |
| LobeHub | 内置 Model Bank、环境与用户数据 | Provider | 能力和参数影响 Runtime |
| Manifold Desktop | 内置硬编码 + compatible `/v1/models` | Provider | 主要用于下拉选择；模型请求认证有已知缺口 |
| NextChat | 内置表 + adapter 拉取 + 服务端/用户 CUSTOM_MODELS | `model@provider` | UI 可用性、默认/视觉模型和代理限制 |
| Open WebUI | 并发拉 OpenAI/Ollama/函数模型 + Workspace Model | urlIdx/base model | 固定路由、权限、prefix、preset/override 继承 |
| Pi | 构建期生成目录（gitignore）+ pi.dev 远端叠加 + `models.json` 定义/覆盖 + 扩展注册 | Provider | 能力、价格、contextWindow 参与请求构造与成本计算 |
| OpenCode | models.opencode.ai/api.json（5 分钟 TTL 缓存 + 构建期快照 fallback + 网络三级数据源）；config `models` 覆盖 | Provider | 能力、上下文限制、价格参与请求构造与 usage/cost 落库；`OPENCODE_MODELS_URL`/`OPENCODE_DISABLE_MODELS_FETCH` 可控制 |
| Risuai | 静态 `LLMModels` 表 + 启动动态拉取 Google/Anthropic/OpenAI + 设置页实时拉取 OpenRouter/NanoGPT/Ollama/Horde（远端不持久化） | Provider 分类/模型条目 | flags、parameters、keyIdentifier 直接决定请求行为；未知 ID 回退 OpenAI 兼容条目 |
| SillyTavern | Provider `/models` 或专用 API | 当前 source/Profile 字段 | 异构字段控制上下文、多模态、推理和工具 UI |
| VCPChat | 同网关 `/v1/models` | 无本地 Provider 命名空间 | 主要用于选择、收藏和展示 |
| VCPToolBox | 上游 `/v1/models` + 别名 + 虚拟模型 | 单上游 | 公开名改写和语义路由 |

AIO Hub、Cherry Studio 和 LobeHub 都把模型稳定地放在 Provider 命名空间内，可以避免不同服务暴露同名模型时误路由。Chatbox 的运行时键同样包含 Provider。VCPChat 保存裸模型 ID，符合单网关假设；一旦用户替换网关，本地收藏或统计未必还指向原模型语义。

Cherry Studio 的 Registry 将模型本体、Provider 定义和 Provider-模型覆盖分开，适合维护别名、能力差异和端点覆盖。AIO Hub 的模型规则覆盖面较广，能力信息还会驱动请求路径。LobeHub 的 Model Bank 同时容纳能力、限制和定价，但定价目前不参与普通选路。

SillyTavern 接收多家上游返回的异构模型对象，通过多套字段读取上下文、价格、视觉、推理和工具能力。这有利于兼容现有生态，也意味着字段统一和 fallback 规则会持续承担维护成本。

需要特别区分“元数据可配置”与“元数据规则编辑器”：LobeHub、Jan、DeepChat、Cherry Studio、DeepSeek Harness 和 OpenCode 都存在模型级覆盖或配置层合并，但本次未找到与 AIO Hub 同等完整的用户规则集合。AIO Hub 的规则包含匹配类型、优先级、正则、独占和深合并，并有独立编辑器、命中测试、覆盖分析及导入导出；规则还影响能力门控、请求参数、Tokenizer 和媒体参数。当前更适合把它记录为 LLM 渠道管理中的稀有扩展能力，而不是在独特功能统计中重复计数。边界研究见 [`独特功能/模型元数据规则可配置边界研究.md`](../独特功能/模型元数据规则可配置边界研究.md)。

VCPToolBox 的模型层有独特用途：`ModelRedirect.json` 可把公开名映射到内部名，语义路由又把 `VCPModelAuto` 等虚拟模型加入标准目录。客户端无需理解路由协议即可选择虚拟模型。当前快照没有该文件，别名能力存在但默认未启用；虚拟模型目录项也不应掩盖真实上游目录获取失败。

## 多 Key：存储、分摊与健康

“可以保存多个 Key”至少要继续追问四件事：Key 是否有独立身份，如何选择，失败后是否标坏，何时恢复。

| 项目 | 表示 | 正常选择 | 失败处理 | 当前请求换 Key |
|---|---|---|---|---|
| AIO Hub | 带状态的 `apiKeys[]` | 轮询 | 记录错误，429 可熔断并恢复 | 渠道层无；聊天应用层重试时重选 Key |
| AstrBot | source `key` 数组 | 随机选一 | 429/无效剔除当前 Key，耗尽后报错 | **有** |
| Chatbox | 单 Key/OAuth | 固定 | 继续使用同一凭据重试 | 不适用 |
| Cherry Studio | 带 ID、标签、启停的数组 | 跨请求 round-robin | 不记录健康 | 无 |
| DeepChat | Provider `apiKey/oauthToken` | 固定 | 单 Provider 凭据，无多 Key 结构 | 不适用 |
| DeepSeek Harness | 每 route 一个 `CredentialRef` 引用，解析后单值 | 固定 | 无多 Key 结构，同凭据重试 | 不适用 |
| Hermes Agent | auth.json `credential_pool`，含状态/冷却 | selector 选可用项 | 401/429/供应商错误标记耗尽并轮换，冷却后恢复 | **有** |
| Jan | 主 Key + `api-key-fallbacks` 有序链 | 首 Key | 401/403/429 换下一枚 | **有** |
| LobeHub | 逗号分隔字符串 | server 随机/轮询，client 随机 | 不记录健康 | 无主动保证 |
| Manifold Desktop | 每 Provider 单 Key | 固定 | 无 | 不适用 |
| NextChat | 客户端单 Key；服务端逗号 Key | 服务端每次随机 | 失败不重选 | 无 |
| Open WebUI | 每 URL 一枚 Key；Ollama 每连接配置 | 模型固定 URL；Ollama 同名模型随机后端 | 失败事件只观测，不换 Key/连接 | 无 |
| Pi | 每 Provider 单凭据（存储/运行时/环境变量） | 固定 | 同凭据重试；OAuth 到期自动刷新 | 不适用 |
| OpenCode | 每 provider 单凭据（auth.json 或 env 探测） | 固定 | 同凭据重试；OAuth 到期自动刷新（插件实现） | 不适用 |
| Risuai | 每模型单 Key（按 keyIdentifier 索引的 OaiCompAPIKeys） | 固定 | 无多 Key 结构，同凭据重试 | 不适用 |
| SillyTavern | 带 UUID、标签、active 的 Secret 数组 | active 或 Profile 固定 ID | 用户手工 rotate | 无 |
| VCPChat | 单值 | 固定 | 无 | 不适用 |
| VCPToolBox | 单值 | 固定 | 无 | 不适用 |

AIO Hub、Hermes Agent、AstrBot 和 Jan 都会让 Key 失败影响选择，但时间边界不同。AIO Hub 的渠道层失败只影响后续请求，但主聊天链路在应用层等待重试并重新选 Key，失败 Key 已熔断或标坏时重试即换 Key；AstrBot 与 Jan 可在当前请求内沿 Key 链即时重试；Hermes Agent 还会持久化 credential pool 状态、冷却并在池耗尽后推进 fallback。四者都仍需与跨 Provider 健康调度区分。

Cherry Studio 的结构化 Key 数组便于展示标签、启停和逐 Key 检测，轮询可以分摊正常流量。失败不会让某枚 Key 离开候选池，当前请求也不会自动换 Key。LobeHub 的逗号字符串配置更轻，但缺少独立 ID、标签和状态；而且不同 Transport 是否重建 Runtime 会影响 retry 是否重新抽取 Key，不能形成一致承诺。

SillyTavern 把多 Key 当作 Secret 管理和人工切换功能。Profile 可固定某个 Secret UUID，适合稳定复现实验配置。自动负载分摊不是其目标，401/429 也不会触发 rotate。Risuai 则完全没有多 Key 结构：每个模型按一个 Key 标识取一把 Key，无轮询、失败计数或熔断。

## 重试、模型回退与跨渠道故障转移

### 重试策略

| 项目 | 普通请求行为 | 错误范围与退避 | 请求目标是否改变 |
|---|---|---|---|
| AIO Hub | 渠道层抛错；聊天应用层默认最多 2 次重试（共 3 次尝试） | 固定/指数间隔（默认 3s），429 追加 5s 惩罚；400 与流式已输出后不重试 | 重试重新 pickKey，可换 Key；渠道/模型不变 |
| AstrBot | transport tenacity 5 次 + OpenAI adapter 最多 10 次分类循环 | 指数退避；429/无效 Key、超长、图片/工具能力分别处理 | 可换 Key；只有图片/空输出等特定条件换 fallback 模型 |
| Chatbox | 最多 5 次 attempt | 429/5xx，指数退避；网络错误默认不重试 | Provider、端点、Key、模型不变 |
| Cherry Studio | 默认 `maxRetries: 0` | 调用方可显式覆盖 | 不重新选择 Provider/Key |
| DeepChat | 由 runtime behavior/AI SDK 执行；另有 Provider QPS 队列 | timeout/abort 与 adapter 策略；未确认统一次数 | Provider/模型固定 |
| DeepSeek Harness | `agent/request-error` 瀑布执行 route 注册时捕获的策略，normal 最多 2 次、always 无上限；SDK 重试强制 0 | 五个可重试码，500ms → 10s 指数退避 + 10% 抖动 | Provider/模型/Key 不变 |
| Hermes Agent | 应用层默认 3 次，随后 credential pool、模型 fallback、Provider fallback 分层推进 | 按 429/401/provider 错误分类；pool 有冷却 | 可依次换 Key、模型、Provider/端点 |
| Jan | `createApiKeyRotatingFetch` 在认证/限流错误后重发 | 401/403/429 | 同 Provider 换 Key，模型/端点不变 |
| LobeHub | Agent Runtime 默认 5 次 retry | 可重试错误，指数退避 1s 起、上限 30s | Provider/模型固定；Key 行为依 Runtime 生命周期 |
| Manifold Desktop | 单次请求 | 无 retry | 不改变 |
| NextChat | 单次聊天请求 | 超时/Abort，无通用 retry | 不改变；服务端随机 Key只在请求前选择 |
| Open WebUI | 单次请求 | 默认 300s timeout，失败分类事件 | 不改变；Ollama 随机选择只发生请求前 |
| Pi | 消息层默认最多 3 次（`settings.retry`）；SDK 层 `maxRetries` 独立 | 错误文本分类（429/5xx/网络/流中断可重试，quota/billing 不可），指数退避 `baseDelayMs * 2^n`（默认 2s 起）；SDK 层读 `x-should-retry`/`retry-after`，上限 60s | Provider/模型/Key 不变 |
| OpenCode | 会话级 `Effect.retry`（`retryable` 判定 5xx/429/超时/网络错误，context overflow 不重试；上限 5 次，`attempt > 5` 停止）+ SDK `maxRetries: retries ?? 0` + native 层 `MAX_RETRIES=2`（指数退避带 jitter） | 指数退避 2s 起，尊重 `retry-after` 头；429 区分 `RateLimitReason`/`QuotaExceededReason`；`FreeUsageLimitError`/`GoUsageLimitError` 转 upsell action | Provider/模型/Key 不变；会话级重试重跑整个 stream effect，可能重复计费（静态推断） |
| Risuai | 同模型重试（`requestRetrys` 默认 2，0–20 可调）→ fallback 候选链 → 工具链重试 | 服务端错误先等 1 秒；防过载时计数减半（实际重试翻倍）；空响应/禁用脚本可推进候选 | 可换模型（用户静态候选链），Key/端点不变 |
| SillyTavern | 普通 Chat 单次请求 | 无统一策略 | 不改变 |
| VCPChat | 主链单次 `fetch` | Flowlock 是新续写轮次 | 不改变 |
| VCPToolBox | 默认 3 次总尝试 | 500、503、429、特定 401、网络和连接/首包超时；线性退避 | 普通模型不变；语义模型可换候选 |

Chatbox 对网络错误默认不重试，是为了避免服务端已经处理请求时发生重复计费。这个选择提醒我们：自动重试并非次数越多越好。对于非幂等生成请求，客户端在断线时通常无法确认服务端是否已经开始计费或生成；重放策略应同时考虑错误类别、是否收到响应头/首包和用户可见状态。

LobeHub 的重试过程会发布结构化事件，UI 可以显示重试状态，这是比简单循环更完整的交互设计。它的多 Key 选择与 Runtime 生命周期耦合：某些路径重建 Runtime 时可能重新取 Key，缓存 Runtime 的路径则复用原 Key。既然行为不是健康调度器的明确决策，就不应描述成“失败自动换 Key”。

VCPToolBox 对可重试错误的分类比单纯 5xx 更细，也把取消信号级联到上游。其退避不读取 `Retry-After`，默认的 `ApiRetries` 又表示总尝试数，配置名称和实际语义需要在 UI 或文档中明确。

### 模型 fallback 仍不等于 Provider failover

VCPToolBox 的语义虚拟模型先按对话内容与 route description 的相似度选出候选，遇到特定错误后沿模型链重试。Embedding 也有独立候选链。这些模型全部发往同一个上游地址、使用同一枚 Key。除非聚合上游恰好把不同模型映射到不同 Provider，本地并没有跨渠道切换证据。

SillyTavern 可以把 OpenRouter 的 Provider order 和 `allow_fallbacks` 传给上游；实际选择发生在 OpenRouter。LobeHub 的 Router 运行时支持 option fallback，当前开源 `lobehub` Router 配置没有真实路由项。这两类能力都应注明执行主体和配置前提。
### 静态 fallback 链仍不等于健康调度闭环

一个完整的跨 Provider 故障转移至少需要：

1. 为同一逻辑模型维护多条独立 Provider/URL/凭据候选；
2. 按认证失败、限流、服务端错误、网络错误和超时区分处理；
3. 在请求内安全重放时明确选择下一候选；
4. 跨请求保存失败、冷却和恢复探测状态；
5. 记录每次 attempt 的渠道、错误、延迟和最终结果；
6. 处理流式响应已经开始后的不可重放边界。

AIO Hub 已覆盖第 2、3、4、6 项的一部分：错误分类与等待重试作用于同一 Profile 内的 Key，聊天链路每次重试重新选 Key，失败、冷却与恢复状态跨请求持久化，流式已输出后不再重放。LobeHub 的 Runtime 与 Router 扩展面覆盖第 2、3、5 项的部分结构，开源普通路径没有候选池。VCPToolBox 对模型候选覆盖第 2、3、5 项的一部分，渠道仍由单一上游封装。Pi 覆盖第 2、3 项的一部分（错误分类 + 同渠道重放），没有候选池与健康状态。OpenCode 覆盖第 2、3 项的一部分（错误归一化 + 同渠道重放，V2 runner 的 context overflow 自动压缩再试属模型内行为），同样没有候选池与健康状态。Risuai 覆盖第 2、3 项的一部分：候选链按任务模式静态配置、错误与空响应后推进并完整重发请求，但没有持久健康状态。其余项目主要停留在固定目标重试或人工切换。

Hermes Agent 覆盖第 1、2、3、4、5 项的较大部分：fallback 候选显式配置，credential pool 有冷却状态，跨端点切换会留下运行状态；但候选不是持续健康探测形成，流开始后的重放边界也未形成通用保证。它更准确地属于“静态高可用链”，还不是完整健康调度器。AstrBot 的 fallback 只覆盖特定图片能力与空输出/错误语义，Open WebUI 的 Ollama 随机分摊则只发生在请求前。

## 路由依据：显式绑定仍是主流

十九个项目的普通聊天大多采用显式绑定：用户或 Agent 先选定 Provider 和模型，运行时据此调用。Dify 由应用或节点预设模型引用并在 tenant 侧解析。Hermes Agent 会在错误后按预配置链推进，AstrBot 有少量按能力/空输出触发的 fallback，Open WebUI 的 Ollama 会在请求前随机选同名模型后端，Risuai 的模型 fallback 链也由用户按任务模式静态配置；这些例外仍不以实时成本、延迟和持续健康数据动态选路。

| 路由依据 | 已确认项目 | 实际作用 |
|---|---|---|
| 用户/会话显式选择 | 全部 | 固定本次 Provider 或网关模型 |
| Key 随机/轮询 | AIO Hub、Cherry Studio、LobeHub | 同一渠道内分摊凭据 |
| 错误健康状态 | AIO Hub | 影响后续 Key 选择，聊天链路重试时也据此改选 |
| 任务模式静态 fallback 候选链 | Risuai | 错误或空响应后沿候选推进，候选是用户配置的任意模型 ID |
| 语义相似度 | VCPToolBox | 选择虚拟模型的真实候选 |
| 上游 Provider order | SillyTavern/OpenRouter、Pi/OpenRouter 与 Vercel Gateway | 把路由偏好交给聚合服务 |
| Router option 顺序 | LobeHub 框架 | 可扩展；开源品牌路由为空 |
| 成本、延迟、配额 | 无通用实现 | 现有数据未接入调度（Pi 本地计算成本仅供展示） |

语义选模回答“这段对话更适合哪个模型”，成本路由回答“满足能力要求的候选中哪一个更便宜”，健康路由回答“当前哪些候选可用”。三者的输入和目标不同。VCPToolBox 的余弦相似度实现只覆盖第一类，不能据此推断质量、价格或延迟最优。

## 凭据边界与持久化

### 静态存储

| 项目 | 主要存储 | 静态保护 | 前端可见边界 |
|---|---|---|---|
| AIO Hub | 本地 Profile 配置文件 | 明文 | 由桌面应用配置链使用 |
| AstrBot | `data/cmd_config.json` | 明文 | 有权限 Dashboard API 可返回完整 Key |
| Chatbox | Electron Store `config.json` | 明文 | 桌面设置持有 Key/OAuth/AWS 凭据 |
| Cherry Studio | SQLite JSON 字段 | 明文 | Renderer 读取普通 Provider 时不含秘密 |
| DeepChat | SQLite-backed Provider store | apiKey 明文存 `providers.api_key` 列；OAuth 走 OS safeStorage credentialStore | Provider 对象含 apiKey/oauthToken；Header 统一注入、脱敏在 redact.ts |
| DeepSeek Harness | `$DSH_HOME/.credentials.yaml`（ref → 明文值映射）；settings/配置只存引用 | 明文，0600 + 0700 目录 + 原子写 + 文件锁；POSIX 拒绝 group/other 可读 | `credentials.describe` 只返回 configured/source/writable；错误只命名引用不回显 key |
| Hermes Agent | `.env` + `auth.json` + 可选 config 内嵌 | 文件本身明文；输出/日志/UI/子进程环境脱敏 | runtime resolver 读取，设置页返回脱敏值 |
| Jan | OS keyring；设置只保留引用/非秘密配置 | OS 凭据库 | 前端注册/注销 Provider，Key 正文不写 settings.json |
| LobeHub | PostgreSQL `keyVaults` | AES-GCM | `fetchOnClient` 路径会下发解密后的运行时配置 |
| Manifold Desktop | Windows Credential Manager `Manifold_<providerId>` | OS 凭据库 | 前端只拿是否已配置布尔值 |
| NextChat | 客户端 IndexedDB/store；服务端环境变量 | 客户端明文 | 设置页直接持有用户 Key；服务端可隐藏用户 Key入口 |
| Open WebUI | DB persistent config / 环境变量种子 | 未确认静态加密 | 管理页按连接编辑 Key/auth/headers |
| Pi | `~/.pi/agent/auth.json`（0600 + 文件锁）；`models.json` 可内嵌 key/环境变量/命令 | 明文 | 本地 CLI 进程内使用；`list()` 只暴露 providerId+type |
| OpenCode | `~/.local/share/opencode/auth.json`（0o600 明文）+ SQLite `credential` 表（明文 JSON）+ `account` 表（access/refresh 明文） | 明文 | 运行时错误路径系统脱敏（native executor `<redacted>`）；未发现 UI 展示 key 的打码；`opencode export` 脱敏会话内容 |
| Risuai | `database.bin`（Tauri）/IndexedDB（Web） | 明文（msgpack 打包 + 可选 gzip，无字段加密） | Web 经 `/proxy2` 中转完整经过 hub/自托管进程；请求日志原样记录含 Authorization 的 headers |
| SillyTavern | `secrets.json` | 明文 | 浏览器默认只拿掩码、标签和 ID |
| VCPChat | `settings.json` | 明文 | 主进程使用全局 VCP Key |
| VCPToolBox | 主/插件 `config.env` | 明文 | 已认证管理 API 可返回完整主配置原文 |

静态加密、进程隔离和 UI 脱敏解决的是不同问题。Cherry Studio 把真实凭据留在 Main/Data API，能减少 Renderer 泄露面，但数据库文件本身仍是明文。SillyTavern 默认只向浏览器返回 Secret 的掩码和 ID，也不改变 `secrets.json` 的磁盘属性。LobeHub 保护了数据库静态数据；`fetchOnClient` 为浏览器直连而下发解密配置时，运行时暴露面又会扩大。

LobeHub 的密文导出还有密钥迁移约束：导出的 Provider 数据保留数据库密文，恢复目标必须使用相同 `KEY_VAULTS_SECRET`，否则无法解密。加密备份要同时设计数据归档和密钥迁移，仅保存密文不等于可恢复。

### 备份与导出

| 项目 | 默认行为 | 需要注意的边界 |
|---|---|---|
| AIO Hub | 单项目笔记未确认完整备份链 | 不据此推断包含或排除 Key |
| AstrBot | 单项目笔记未确认备份/导出链 | `cmd_config.json` 本身含明文 Key |
| Chatbox | 自动配置备份复制完整 `config.json`；主动聊天导出默认剔除凭据 | 自动备份与用户导出边界不同 |
| Cherry Studio | legacy 备份引擎已升级为 **v7 full/slim 双布局，包含 `cherrystudio.sqlite`**（`220dff874f` 起） | 备份会落盘明文 Provider 凭据（SQLite 无静态加密）；v2 backup 仍在开发中 |
| DeepChat | 模型 config 支持导入/导出；凭据备份未确认 | 不能由 config 导出推断包含 Provider Key |
| DeepSeek Harness | 无数据库、无导入导出；备份链单项目笔记未确认 | `.credentials.yaml` 即全部 key 值所在，复制文件等于复制凭据；settings 不含 key 可共享 |
| Hermes Agent | 备份导出对 `.env`、`auth.json`、`state.db` 做脱敏 | 连接恢复是否完整取决于重新提供 Secret |
| Jan | 单项目笔记未确认全量备份；Key 在 OS keyring | settings 迁移会重新注册 keyring，但不等于可移机导出 |
| LobeHub | 全量导出含 Provider 密文 | 跨主密钥恢复需要额外流程 |
| Manifold Desktop | 单项目笔记未确认备份 | Windows Credential Manager 不随普通 settings.json 复制 |
| NextChat | 客户端配置随持久化 store；未确认专用脱敏导出 | 用户 Key 明文保存在客户端状态 |
| Open WebUI | DB 配置迁移/备份范围未确认 | 环境变量只是种子，实际运行配置可能已转入 DB |
| Pi | 无备份/导出机制；`auth.json` 即全部凭据，0600 权限 | `models.json` 内嵌 key 明文参与配置分发；`--print-credentials` 是显式导出入口 |
| OpenCode | 无凭据备份/导出机制；`opencode export` 只导出会话 | auth.json/credential 表/account 表均为明文；`OPENCODE_AUTH_CONTENT` 可整体注入 auth.json |
| Risuai | 保存自动生成主文件与最多 20 份备份，均含完整数据库（含 Key）；Preset 导出清空 Key/URL；Bug Report 导出删除凭据字段 | 云同步（账号/Drive/Kei 备份）全明文；仅本地 `.risudat` 在账号模式下用临时密钥加密；恢复依赖备份时间序回退 |
| SillyTavern | 设置快照不含独立 Secret；ZIP 默认排除 Secret | 恢复 Profile 后可能缺少对应 Secret ID |
| VCPChat | 每日设置备份和一键 ZIP 包含明文 Key | 原子写入只保证完整性，不保证保密性 |
| VCPToolBox | 默认归档所有 `.env` 和 JSON | 未加密 ZIP 扩大核心及插件 Secret 副本范围 |

Chatbox 是“同一项目内不同备份入口安全语义不同”的典型：用户主动导出聊天数据时默认剔除 Key，自动配置滚动备份却复制整个配置文件。SillyTavern 默认排除 Secret，降低了普通归档泄露风险，但 Profile 内的 Secret UUID 引用可能在恢复后失效。Cherry Studio 的 legacy 备份引擎（类名仍标 `@deprecated LEGACY v1 CODE`）已升级为 v7 full/slim 双布局并接入 SQLite 备份（`220dff874f`），v2 Provider 与凭据因此随备份落盘——旧"备份不复制 SQLite 数据库、Provider 配置未进入备份链"的结论已被推翻；由于 Provider 凭据是 SQLite 明文，备份文件本身的保密性成为新的边界。

VCPChat 的 temp、回读校验、旧文件备份和原子替换提高了配置写入完整性。VCPToolBox 的管理 API 直接覆盖主配置，且保存后部分核心值需要重启才生效。这些属于可靠写入和运行配置切换问题，应与 Secret 加密分开评价。

## 连接检测与可观测性

| 项目 | 检测层次 | 运行时观测 | 是否影响调度 |
|---|---|---|---|
| AIO Hub | 能力感知连接测试、批量模型探测 | 请求 Inspector、Key 错误状态 | Key 状态局部影响后续选择 |
| AstrBot | Provider/Dashboard 配置与实际请求错误 | adapter 错误、Key 剔除、fallback 日志 | Key 可用集和特定 fallback 影响选择 |
| Chatbox | Provider/模型连接能力 | 常规错误与重试 | 无持久健康调度 |
| Cherry Studio | 单 Provider、批量模型、多 Key 检查并显示延迟 | HTTP Trace、取消控制 | 无 |
| DeepChat | Registry connectivity strategy、模型目录刷新 | requestTrace + QPS/队列状态事件 | 只影响限流队列，不跨 Provider 路由 |
| DeepSeek Harness | 无独立连接测试；Models 页就绪 = `credentials.describe` 三态 + settings 存在性静态组合；真实探测仅配置时 `discoverModels`（GET /models，不进运行时） | `llm/retry` 与 `llm/retry-started` 事件、`llm/adapters-updated` 拓扑事件、`assistant/chunk` 可重建请求、`LlmError` 稳定 code + failure | 无；错误码只驱动同 route 内重试 |
| Hermes Agent | `hermes doctor` 与设置页独立探针 | 日志脱敏、credential pool 状态/冷却、usage tracker | pool/fallback 影响选择；探针结果不直接驱动 fallback |
| Jan | 每 Key `/models` 测试 | Key 状态结果、router/本地引擎状态 | 失败请求可换 Key；测试结果不形成持续健康调度 |
| LobeHub | Web/CLI 单模型最小请求 | 结构化 retry 事件 | 无 |
| Manifold Desktop | compatible `/models` 列表 | token usage + 前端静态费用估算 | 无；模型列表调用可能阻塞 UI |
| NextChat | adapter `models()` 与服务端配置 | 常规错误/usage；无渠道健康表 | 无 |
| Open WebUI | 每连接手动 `/verify`、模型目录拉取 | `MODEL_PROVIDER_REQUEST_FAILED` 分类事件含 Key 后四位 | 无；Ollama 请求前随机不看健康 |
| Pi | `checkAuth` 只验凭据完整性，不发真实请求；无连接测试入口 | 用量/成本本地计算（footer/`/session` 展示）、retry 事件可见 | 无 |
| OpenCode | 登录流程无专门 validation 请求（仅插件 prompt `validate` 回调与 GitLab `discoverModels` 真实调 API） | usage/cost 落 session 表（tiers 定价）、OTel trace/日志（`OTEL_EXPORTER_OTLP_ENDPOINT`）、重试状态广播 `{type:"retry"}` UI 倒计时 | 无 |
| Risuai | 无独立连接测试按钮；设置页模型目录实时加载 + Preview Body 复用真实组装逻辑但不发送 | 内存请求日志（最近 20 条，含 headers/body/状态码，未脱敏） | 无 |
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

错误分类、指数退避、结构化事件和 Router 运行时的选项、停止条件与尝试次数观测提供了较完整的框架边界。需要保留一条表述纪律：扩展点只有在存在真实候选配置和健康策略后，才构成可用的路由方案。

### SillyTavern：把连接与生成环境一起做成可切换 Profile

Profile 同时保存 API、URL、模型、Preset、模板、Proxy 和 Secret 引用，适合需要反复切换整套角色工作环境的用户。Secret UUID 和标签让 Profile 不必保存明文。默认备份排除 Secret 的做法也比静默收集全部 Key 更稳妥，但恢复流程需要处理断开的引用。

### VCPChat：保持客户端和网关职责边界清楚

Agent 只保存模型参数，URL 通过标准 URL API 规范化，工具注入使用独立端点，`requestId` 贯穿生成和中断。配置保存的 temp、校验、备份、移动流程也值得复用。备用网关和 Secret 保护仍需在单点风险与使用复杂度之间权衡。

### VCPToolBox：用标准模型接口包装别名和语义路由

公开模型名、真实模型名和语义虚拟模型分层后，普通 OpenAI-compatible 客户端不必理解额外路由协议。语义候选链去重组合首选、互备、默认和显式 fallback，管理面板还能预览路由。模型级编排与 Provider 级渠道管理应继续保持术语区分。

### Pi：分层重试与组合式覆盖

错误分类正则、SDK 层与消息层两级重试、OAuth 加锁刷新和配置文件覆盖层，构成一套轻量但边界清楚的单机渠道管理。其可复用点在于“组合式覆盖”：内置目录、pi.dev 远端叠加、用户定义与扩展注册各管一层，互不破坏基线。代价也明确：没有渠道实例、多 Key 或健康调度，跨 Provider 高可用完全不在设计内。

### OpenCode：目录、SDK 与凭据的分层组装 + 三层重试

models.dev 目录、config 覆盖、env 探测与 auth.json 凭据按固定顺序组装，任一层缺省都不阻断整条链（构建期快照兜底目录、`OPENCODE_AUTH_CONTENT` 兜底凭据）。可复用点在于把“目录与凭据分离”：模型目录是公共数据源（缓存+快照），凭据独立存 auth.json，config 只声明 env 探测名。会话级、SDK 级与 native 级三层重试各自独立配置（`retries` 参数、`maxRetries`、`MAX_RETRIES`），错误归一化集中识别 context overflow/quota/rate limit。代价明确：无多 Key、无健康状态、无跨渠道 failover；native 协议仅覆盖 openai/anthropic/opencode 三家且要求非 OAuth。

### AstrBot：来源复用、能力实例与错误驱动 Key 轮换

将来源配置与能力实例拆开，既能复用同一端点配置，也能按 Chat/STT/TTS/Embedding/Rerank 独立选择。两层重试、错误驱动换 Key和少数显式 fallback 让运行链有清楚边界；`provider_pool`/权重仍只是未接通配置，不能视为负载均衡。

### DeepChat：Provider、能力快照与 QPS 队列分层

Provider CRUD、ModelConfig、runtime behavior registry 和 RateLimitManager 分开后，多协议差异集中在 runtime，QPS 限流也不会污染模型身份。它的优势是主进程治理和能力快照，不是故障转移；凭据静态保护尚未由现有笔记确认。

### Hermes Agent：把重试、Key 池、模型与 Provider fallback 正交化

四层失败处理使“重发是否改变 Key、模型还是端点”可以明确追踪，credential pool 还有冷却和恢复。设置页探针不复用真实 resolver 的边界同样值得保留，避免把连接测试误当成全链路验证。

### Jan：OS keyring + 请求内 Key 链

远程 Provider 的主 Key 与 fallback Key 都留在 OS keyring，401/403/429 时沿链切换；本地 llama.cpp/MLX 又复用同一 router 契约。这是桌面端兼顾本地与远程的一种紧凑实现，但不会跨 Provider 自动切换。

### Open WebUI：连接行与统一模型目录

OpenAI-compatible 和 Ollama 连接逐行配置，再合并成统一模型目录，适合多用户 Web 管理。`prefix_id`、认证类型、headers 模板与 Workspace Model 提供了较强的接入能力；OpenAI 路由固定、Ollama 只随机分摊，失败均不会自动改选。

### Risuai：把渠道摊薄到模型条目与全局活动设置

Risuai 用一个全局 `Database` 对象同时承载配置与凭据，多连接靠条目变体和自定义数组，不需要实体表；`customAPIFormat` 让一个 URL 切换多套协议族以复用 Adapter。代价同样直接：凭据随同步、备份与日志自然扩散，Web 模式完整经过中转进程，失败处理只有同模型重试与用户静态配置的 fallback 候选链。

## 组合式参考架构

十九个项目没有提供一套完整答案，但可以组合出一条较清楚的实现路径：

1. **渠道实体采用 Cherry Studio/AIO Hub 的稳定实例 ID。** Provider 预设与用户实例分离，模型身份始终包含渠道 ID。
2. **协议选择采用 Cherry Studio 的 Endpoint Type + Adapter Family 或 LobeHub 的显式 SDK Type。** 不从 URL 猜协议，也不把多 Endpoint 宣称为容灾。
3. **Key 使用 AIO Hub/Cherry Studio 的结构化数组。** 每枚 Key 具有 ID、标签、启停、最近错误、冷却截止和恢复状态；选择策略与健康状态分开配置。
4. **重试采用 LobeHub/Chatbox 的错误分类与可观察事件。** 对流式首包前后、网络不确定性、429 `Retry-After` 和重复计费分别定规则。
5. **模型别名和自动选模采用 VCPToolBox 的虚拟模型边界。** 任务分类、成本优化和健康选择使用独立评分，不把语义相似度当作通用路由指标。
6. **凭据采用 LobeHub 的静态加密，同时保留 Cherry Studio/SillyTavern 的前端脱敏。** 数据库密文、运行时解密、浏览器下发和备份密钥迁移分别设计。
7. **验证采用 AIO Hub/Cherry Studio/VCPToolBox 的分层探测。** 目录、最小生成、流式、工具、Embedding 和媒体能力分别检查，结果写入统一健康状态。
8. **连接环境切换可借鉴 SillyTavern Profile。** Provider 负责规范化连接，Profile 只引用 Provider/模型并附带 Preset 等上层设置，避免把两类事实源混在一起。
9. **请求内 Key 轮换可借鉴 Jan/AstrBot，跨端点链可借鉴 Hermes Agent。** Key、模型和 Provider fallback 分层记录，避免把不同失败动作压成一个 retry 开关。

这是一组从现有实现抽取的设计参考，不表示将所有能力堆入同一个客户端。若部署已经依赖成熟聚合网关，客户端只保留 VCPChat 式单入口可能更合适；若应用必须直连多个厂商，本地才需要完整 Provider、Key 和健康调度模型。

## 容易误判的结论

| 容易写出的结论 | 源码支持的准确表述 |
|---|---|
| “AIO Hub 渠道层会换 Key 重试” | 渠道层单次调用抛错并更新 Key 状态；重试在聊天应用层，等待后重发并重新 pickKey，已熔断/标坏的 Key 被跳过，同渠道有其他可用 Key 时换 Key |
| “Cherry Studio 多 Key 可容灾” | 多 Key 跨请求 round-robin；无健康状态和当前请求换 Key |
| “LobeHub 已有跨 Provider Router” | RouterRuntime 支持 option fallback；当前开源 `lobehub` 路由表为空，普通 Provider 固定 |
| “Chatbox 支持多 Key 重试” | 它使用单 Key/OAuth，对 429/5xx 在同一渠道、同一凭据重试 |
| “SillyTavern Connection Profile 是渠道池” | Profile 是活动连接与生成设置快照，切换由用户发起 |
| “VCPChat 的 Flowlock 提供网络重试” | Flowlock 在失败后触发新的续写轮次，不是同一 HTTP 请求重放 |
| “VCPToolBox 支持多 Provider failover” | 它可在语义模型请求中换模型，但仍使用同一上游 URL/Key |
| “健康检查成功就会避开坏渠道” | AIO Hub、Hermes Agent、AstrBot、Jan 的运行时失败可影响 Key 选择，但设置页探针结果普遍不直接形成动态渠道调度 |
| “Hermes Agent 有完整健康路由器” | 它有显式 fallback 链和 credential pool 冷却；候选仍由静态配置给出，不按持续健康/成本/延迟动态评分 |
| “Open WebUI 多连接会自动容灾” | OpenAI 模型固定到首见连接；Ollama 同名模型只在请求前随机选后端，失败后不改选 |
| “OpenCode 支持多 Provider 自动 failover” | 会话级重试、SDK `maxRetries` 与 native 重试都不改变 Provider/模型/Key；context overflow 自动压缩重试是模型内行为 |
| “OpenCode 的 `@`/`#`/`:latest` 模型语法” | 本快照仅 `provider/model[/variant]` 语义，无 `@` 全局、`#` 本地或 `:latest` 后缀代码 |
| “DeepSeek Harness 复用 pi-ai 即拥有 Pi 的渠道管理” | pi-ai 只贡献 Models 集合、Provider 构造、事件词汇与思考等级；凭据解析、retry policy、settings 分层与错误分类全在 dsh 侧，SDK 自动重试被强制为 0 |
| “Risuai 的 reverse_proxy / 自定义模型是独立渠道实体” | reverse_proxy 是全局单例，自定义模型以 xcustom:: 条目表达；没有可独立启停的渠道实例 |
| “Risuai 的 fallback 链是健康感知 failover” | 候选链按任务模式静态配置，触发条件是错误类型与空响应，推进候选会完整重发请求 |
| “配置原子写入等于 Secret 安全” | 原子写入保护完整性；静态加密和备份控制保护保密性 |
| “模型定价已存在，所以可以按成本路由” | 本次样本中的定价和用量数据未进入通用调度 |

## 选型视角

| 主要需求 | 更接近的现有实现 | 需要接受的边界 |
|---|---|---|
| 在图形界面中管理多条渠道的完整生命周期 | AIO Hub、Cherry Studio、DeepChat、Open WebUI | 各自仍缺少部分复制或渠道级导入导出；运行时故障转移能力需另行比较 |
| 桌面端直连多 Provider，并管理多 Key 状态 | AIO Hub | 渠道层不换 Key，聊天链路有等待重试并重选 Key；无跨 Profile failover；凭据明文 |
| 多认证、多协议端点和同预设多实例 | Cherry Studio | 默认不重试，无 Key 健康；SQLite 明文 |
| 服务端多用户 Provider、加密凭据和可观察重试 | LobeHub | 普通开源路径无跨 Provider 路由；密钥迁移复杂 |
| 显式多 Key、模型与跨 Provider fallback 链 | Hermes Agent | 需手工配置候选；不是健康感知动态路由；重发可能重复计费 |
| 本地/远程统一 router 与 OS keyring Key 链 | Jan | 同 Provider 换 Key，不跨 Provider；本地 API 鉴权不防本机恶意进程 |
| IM Agent 的多能力 Provider 实例 | AstrBot | Key 明文，普通网络错误不触发跨 Provider fallback |
| 多用户 Web 连接行和统一模型目录 | Open WebUI | OpenAI 连接固定路由，无请求重试或健康故障转移 |
| 主进程多协议、能力快照与 QPS 队列 | DeepChat | 无跨 Provider failover；apiKey 明文落盘、OAuth 走 OS keyring |
| 简洁稳定的多模型桌面客户端 | Chatbox | 内置 Provider 单实例，无多 Key 和跨渠道切换 |
| 角色、Preset、模板与连接整体切换 | SillyTavern | 依赖快照式配置，自动可靠性能力少 |
| 客户端统一接入已有网关 | VCPChat | 单 URL/Key 是故障点，模型缺少 Provider 命名空间 |
| 多入站协议、语义选模和插件编排 | VCPToolBox | 本地仍是单一 OpenAI-compatible 上游 |
| 终端编码 Agent、多 Provider 直连与模型覆盖 | Pi | 无渠道实例与多 Key；凭据明文；依赖外部容器化做隔离 |
| 服务端 Agent 运行时、多前端共用与自动模型目录 | OpenCode | 单 provider 单凭据；Web/桌面端不能编辑已有 Provider 定义；无多 Key 与跨渠道 failover；凭据明文；模型目录依赖远端拉取（可禁用） |
| 服务端 Agent 平台、组合配置热重载与双适配器渠道层 | DeepSeek Harness | 无多 Key 与跨 Provider failover；模型目录需写配置不自动刷新；HTTP 代理配置本次未找到 |
| 角色创作工作流、模型 ID 即选模入口与多协议 Custom API | Risuai | 无渠道实体、多 Key 与健康状态；凭据明文并随同步、备份与日志扩散；Web 端经 /proxy2 中转经过第三方进程 |

这张表描述的是实现接近度，不是产品推荐。最终选择还取决于部署位置、是否允许凭据进入客户端、是否已有聚合网关、生成请求能否安全重放，以及运维方是否真正维护健康状态。

## 横向结论

十九个项目展示了八条清晰路线：

1. AIO Hub、Cherry Studio、DeepChat、LobeHub 和 Open WebUI 在应用内建立稳定 Provider/连接实体，差别集中在实例模型、多 Key、限流、重试和凭据保护；
2. SillyTavern 用活动设置和 Profile 服务于完整创作环境切换，渠道自动化让位于兼容性和用户控制；
3. VCPChat 与 VCPToolBox 把复杂度推向统一网关，前者保持客户端轻量，后者增加协议和模型编排，但本地都没有多上游渠道池；
4. Pi 把 Provider 做成代码注册项 + 组合覆盖，服务于单机 CLI 工作流，渠道管理能力止于可配置、可覆盖、可重试。
5. OpenCode 把 Provider 做成运行时组装体（目录 + config + 凭据），服务于服务端 Agent 工作流，渠道能力止于可配置、可重试、可观测，多前端共享同一渠道层。
6. AstrBot 将来源与能力实例分开，Jan 将远程 Provider 和本地引擎汇入 router，分别服务于 IM Agent 和本地桌面推理。
7. Hermes Agent 将 Profile、credential pool、模型 fallback 与跨 Provider/端点 fallback 分层，是静态故障转移链最完整的样本；NextChat 与 Manifold Desktop 则保留枚举/注册表加轻量代理的客户端路线。
8. Risuai 把渠道摊薄到模型条目与全局活动设置，服务于角色创作工作流，多连接靠条目变体、全局 reverse_proxy 单例与自定义条目表达，失败处理止于同模型重试和用户静态 fallback 候选链。

配置管理入口形成了另一条独立比较轴。AIO Hub、Cherry Studio、DeepChat 和 Open WebUI 已在图形界面覆盖主要生命周期；OpenCode 与 Manifold Desktop 的底层配置表达力明显高于桌面设置页；其余缺项有些来自入口未暴露，有些来自项目本身没有独立渠道实体。选择产品时需要同时核对运行时能力和已有配置是否能在目标前端继续维护。

如果只比较“配置多少 Provider”，会错过真正影响可靠性和安全性的边界。更有效的审查顺序是：先确定运行时实际选中的 URL、凭据、协议和模型，再跟踪错误发生后其中哪一项会改变，最后核对失败状态能否跨请求保存、何时恢复，以及这些过程是否留下可解释记录。

在本次代码快照中，Hermes Agent 的静态跨端点 fallback 链最完整，Dify 的 tenant 级凭据加密与同模型多 Key 冷却、AIO Hub 的本地 Key 健康状态、Jan 的请求内 Key 链、Cherry Studio 的 Provider/Endpoint 数据模型、LobeHub 的静态加密与可观察重试、Open WebUI 的连接行模型、VCPToolBox 的模型编排和 OpenCode 的目录/凭据组装各有清晰边界。Risuai 的“模型 ID 即渠道 + 全局活动设置”形态则是渠道实体最薄的样本。持续健康感知的跨 Provider 调度、成本/延迟路由和一致的凭据备份恢复，仍是十九个项目共同未闭合的部分。

## 依据与范围

- [AIO Hub LLM 渠道管理调查笔记](AIO-Hub-LLM渠道管理调查笔记.md)
- [AstrBot LLM 渠道管理调查笔记](AstrBot-LLM渠道管理调查笔记.md)
- [Chatbox LLM 渠道管理调查笔记](Chatbox-LLM渠道管理调查笔记.md)
- [Cherry Studio LLM 渠道管理调查笔记](Cherry-Studio-LLM渠道管理调查笔记.md)
- [DeepChat LLM 渠道管理调查笔记](DeepChat-LLM渠道管理调查笔记.md)
- [DeepSeek Harness LLM 渠道管理调查笔记](DeepSeek-Harness-LLM渠道管理调查笔记.md)
- [Dify LLM 渠道管理调查笔记](Dify-LLM渠道管理调查笔记.md)
- [Hermes Agent LLM 渠道管理调查笔记](Hermes-Agent-LLM渠道管理调查笔记.md)
- [Jan LLM 渠道管理调查笔记](Jan-LLM渠道管理调查笔记.md)
- [LobeHub LLM 渠道管理调查笔记](LobeHub-LLM渠道管理调查笔记.md)
- [Manifold Desktop LLM 渠道管理调查笔记](Manifold-Desktop-LLM渠道管理调查笔记.md)
- [NextChat LLM 渠道管理调查笔记](NextChat-LLM渠道管理调查笔记.md)
- [Open WebUI LLM 渠道管理调查笔记](Open-WebUI-LLM渠道管理调查笔记.md)
- [OpenCode LLM 渠道管理调查笔记](OpenCode-LLM渠道管理调查笔记.md)
- [Pi LLM 渠道管理调查笔记](Pi-LLM渠道管理调查笔记.md)
- [Risuai LLM 渠道管理调查笔记](Risuai-LLM渠道管理调查笔记.md)
- [SillyTavern LLM 渠道管理调查笔记](SillyTavern-LLM渠道管理调查笔记.md)
- [VCPChat LLM 渠道管理调查笔记](VCPChat-LLM渠道管理调查笔记.md)
- [VCPToolBox LLM 渠道管理调查笔记](VCPToolBox-LLM渠道管理调查笔记.md)

本文只比较上述笔记记录的代码快照，不把 README 宣称、未接线模块、框架扩展点、托管版私有配置或外部聚合网关能力直接计入当前实现。未运行真实账号下的限流、断网、重复计费、跨平台凭据读取和恢复演练；涉及这些行为的结论以源码可确认边界为限。
