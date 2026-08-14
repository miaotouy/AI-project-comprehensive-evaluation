# LobeHub LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：只读源码梳理；未修改目标仓库；调查时无未提交修改
>
> 调查范围：LLM 渠道数据模型、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 把 LLM 渠道建模为 PostgreSQL 中的一条 `ai_providers` 记录，把模型建模为 `ai_models` 中的 `providerId + modelId` 组合。内置 Provider 目录、服务端环境变量和用户数据库配置在运行时合并；用户创建的自定义 Provider 拥有独立 ID，并通过 `settings.sdkType` 选择 OpenAI、Anthropic、Google、Bedrock、Azure、Ollama、Router 等协议适配器。

这套实现的主要特点是：

- Provider 与模型始终成对选择，不按裸模型名在普通聊天请求失败后寻找另一家 Provider；
- 同一个内置 Provider 只能保存一组 `keyVaults`，但 API Key 字符串可以用逗号表达多个 Key；
- 服务端多 Key 默认随机选取，也可通过 `API_KEY_SELECT_MODE=turn` 改为 round-robin；客户端固定随机；
- 多 Key 没有失败计数、健康状态、熔断、冷却恢复或基于错误的主动换 Key；
- Agent Runtime 默认对可重试错误重放 5 次，即最多 6 次 attempt，指数退避从 1 秒起、上限 30 秒；
- 重试固定同一 Provider 与模型。是否重新随机取 Key 取决于 transport 是否重新初始化 Model Runtime，而不是健康调度；
- 通用 `RouterRuntime` 支持一个逻辑 Provider 内按 option 顺序 fallback，option 还可切换底层 `apiType`；
- 但当前开源 `lobehub` Router 配置的 `routers()` 返回空数组，真实托管渠道表及排序/健康策略不在这份开源配置中，不能据此宣称普通 Provider 已有跨渠道故障转移；
- 连接检测只对指定模型发送一次最小非流式请求，结果仅保留在当前 UI 状态，不写入调度健康表；
- Provider 凭据以 AES-GCM 密文保存在 PostgreSQL，但 `fetchOnClient` 场景会把解密后的运行时配置下发到浏览器内存；
- 全量数据导出包含 `aiProviders` 和 `aiModels`，导出的 Provider 凭据仍是数据库密文。跨实例恢复必须保持同一个 `KEY_VAULTS_SECRET`，否则不能正常解密。

因此，LobeHub 已具备较完整的 Provider/模型配置、协议适配、多 Key 分摊和请求级重试；权重、成本、延迟、健康感知和跨上游路由只在可注入的 RouterRuntime 扩展面上出现，普通开源 Provider 配置并未实现这些策略。

## 总体调用链

```text
Model Bank 内置 Provider / *_MODEL_LIST 环境变量
  + ai_providers / ai_models（PostgreSQL）
  -> AiInfraRepos 合并有效 Provider 与模型目录
  -> Agent / Topic 保存 provider + model
  -> ClientLLMTransport 或 ServerLLMTransport
  -> ModelRuntime
       内置 Provider -> 对应 Runtime
       自定义 Provider -> settings.sdkType 对应 Runtime
       lobehub -> RouterRuntime（路由配置由 business/deployment 注入）
  -> API Key 选择
       server: random 或 turn
       client: random
  -> SDK Adapter
  -> Base URL + Header + 凭据
  -> 上游 API
```

## 1. Provider 与模型数据模型

### 1.1 `ai_providers` 是渠道配置实体

[`packages/database/src/schemas/aiInfra.ts`](../../lobehub/packages/database/src/schemas/aiInfra.ts) 定义了 Provider 表。主要字段包括：

| 字段 | 作用 |
|---|---|
| `id` | Provider 逻辑 ID，也是运行时路由键 |
| `name` / `logo` / `description` | 展示信息 |
| `source` | `builtin` 或 `custom` |
| `enabled` / `sort` | 启停与排序 |
| `fetchOnClient` | 是否允许浏览器直接初始化 Runtime |
| `checkModel` | 连接检测默认模型 |
| `settings` | SDK 类型、认证类型、浏览器请求限制等 |
| `config` | 例如是否启用 OpenAI Responses API |
| `keyVaults` | 加密后的 API Key、Base URL 和云凭据 |
| `userId` / `workspaceId` | 个人或工作区作用域 |

唯一性分成两类：个人范围使用 `id + userId`，工作区范围使用 `id + userId + workspaceId`。同一用户可在不同工作区拥有同 ID 的独立配置，但在同一作用域内不能用同一个 Provider ID 建立多条渠道实例。

与 Cherry Studio 的“复制预设生成多个 Provider 实例”相比，LobeHub 如果要表达两条 OpenAI 兼容中转，一般需要创建两个不同 ID 的自定义 Provider，而不是在一个普通 Provider 行内保存多个 Base URL。

### 1.2 模型身份包含 Provider

`ai_models` 的业务唯一范围包含 `providerId + modelId`，另加用户/工作区作用域。模型记录可保存：

- 启停与排序；
- 模型类型；
- 能力、上下文窗口和参数；
- 定价与发布日期；
- `builtin`、`remote` 或 `custom` 来源。

Agent、Topic 和 Message 都分别保存 `provider` 与 `model`。新 Topic 会快照 Agent 当时的选择，Topic 也可以固定自己的 Provider/模型，因此后续修改 Agent 默认值不会让既有 Topic 自动漂移。

普通推理调用用显式 Provider 初始化 Runtime。即使另一个 Provider 也提供相同模型 ID，也不会仅凭裸模型名自动改道。

### 1.3 内置目录、环境变量与用户差量

[`packages/model-bank/src/modelProviders/index.ts`](../../lobehub/packages/model-bank/src/modelProviders/index.ts) 汇总内置 Provider 定义。当前快照（HEAD）的固定列表有 84 张卡（该文件 84 个 import），其中品牌 `lobehub` 由 `ENABLE_BUSINESS_FEATURES` 条件加入（`index.ts:145-146`），即开源默认 83、商业构建 84——与上快照（4edba1b7）口径一致，成员无增减。

有效配置来自三层：

```text
用户数据库中的 Key / Base URL / Provider 设置 / 模型差量
  > 对应 Provider 的服务端环境变量
  > Model Bank 内置元数据与默认值
```

用户值优先；缺少用户 Key 或 Base URL 时，服务端可以回退到该 Provider 的部署环境变量。这里的“回退”是配置解析优先级，不是请求失败后的渠道 failover。

## 2. Base URL、Header 与凭据

### 2.1 `keyVaults` 统一承载连接秘密

不同 Runtime 会从这一加密字段读取各自需要的字段，常见字段包括：

- `apiKey`；
- `baseURL` 或 `endpoint`；
- `customHeaders`；
- AWS 的 `accessKeyId`、`secretAccessKey`、`sessionToken`、`region`；
- Cloudflare 的账号/Base URL；
- Vertex AI 的项目、区域或 JSON 凭据；
- OAuth access token、refresh token、bearer token 与过期时间。

[`apps/server/src/modules/ModelRuntime/index.ts`](../../lobehub/apps/server/src/modules/ModelRuntime/index.ts) 负责把数据库中已解密的 `keyVaults` 转成具体 Runtime 的初始化参数；客户端路径在 [`src/services/_auth.ts`](../../lobehub/src/services/_auth.ts) 做相似转换。

Header 和端点规则主要由各 Provider Runtime 或 OpenAI-compatible factory 实现，而不是统一拼一个固定 `/chat/completions`。OpenAI 兼容 Provider 可根据 `config.enableResponseApi` 选择 Chat Completions 或 Responses；Anthropic、Google、Bedrock、Azure 等使用各自 SDK 和端点语义。

### 2.2 自定义 Provider 的协议选择

自定义 Provider 创建时需要独立 ID、名称和 Base URL，可选 API Key，并通过 `sdkType` 选择适配器。类型层 `AiProviderSDKEnum` 仍保留 14 种（`anthropic, azure, azureai, bedrock, cloudflare, comfyui, google, huggingface, ollama, openai, qwen, replicate, router, volcengine`，`packages/model-bank/src/types/aiProvider.ts`），但**自定义 Provider 创建界面已收敛为其中的 9 个选项**（`src/features/Settings/provider/features/customProviderSdkOptions.ts:3-13`）——`azureai`/`bedrock`/`huggingface`/`replicate`/`comfyui` 在类型与 API 层仍可写，只是不再出现在 UI 选项中。

运行时不是根据 URL 猜协议，而是按 Provider 元数据中的 SDK Type 选择 Model Runtime。相同 OpenAI 兼容协议可以对应多个不同 Provider ID，各自保存 Base URL、Key、模型目录和开关。

### 2.3 浏览器直连与服务端代理

`fetchOnClient` 决定推理和模型拉取是否可从浏览器直接访问上游：

- 明确禁用浏览器请求的 Provider 强制走服务端；
- Ollama、LM Studio 等本地服务可按设置直连；
- 只有 Base URL、没有 Key 时会倾向客户端访问，以便访问用户本机端点；
- 有 Key 时默认走服务端，除非用户明确开启浏览器请求。

数据库中的凭据虽然静态加密，但 [`getAiProviderRuntimeState`](../../lobehub/apps/server/src/routers/lambda/aiProvider.ts) 会为运行时解密配置。需要浏览器直连时，解密后的 Key 会进入客户端 Zustand 状态和浏览器内存。因此它不是“密钥永不离开服务端”的设计。

## 3. 模型目录与选择

### 3.1 四类模型来源

模型目录可由以下来源共同组成：

1. `packages/model-bank` 的内置模型卡；
2. 部署环境变量中的 `*_MODEL_LIST`；
3. PostgreSQL `ai_models` 的用户差量；
4. Provider Runtime 的远程 `models()` API。

远程拉取同样遵循浏览器直连开关：浏览器直连 Provider，或调用 `/webapi/models/:provider` 由服务端代取。用户可以在设置中启停、编辑或新增模型。

Model Bank 的 fallback 用于补充模型能力、上下文、定价等元数据。它不会在推理失败时把请求送到另一个 Provider。

### 3.2 请求前匹配不等于失败切换

[`packages/database/src/repositories/aiInfra/index.ts`](../../lobehub/packages/database/src/repositories/aiInfra/index.ts) 的 `tryMatchingProviderFrom()` 可按首选 Provider、fallback Provider、拥有目标模型的 Provider 依次解析渠道。目前主要用于 Memory/Persona 等后台服务。

该逻辑发生在请求发出前，目的是为内部任务找到一个可用的 Provider。选定后若请求失败，并不会再次运行这段逻辑去换渠道。因此应称为“Provider 预解析”，不能称为运行时 failover。

### 3.3 Model Bank 的字段范围

[`packages/model-bank/src/types/aiModel.ts`](../../lobehub/packages/model-bank/src/types/aiModel.ts) 将模型元数据分成几组：

| 类别 | 主要字段 |
|---|---|
| 身份与生命周期 | `id`、`displayName`、`description`、`organization`、`family`、`generation`、`releasedAt`、`knowledgeCutoff`、`legacy`、`visible` |
| 类型 | chat、embedding、tts、asr、image、video、text2music、realtime |
| 能力 | audio、files、functionCall、imageOutput、reasoning、search、structuredOutput、video、vision |
| 限制 | `contextWindowTokens`、`maxOutput`、Embedding 的 `maxDimension` |
| 请求策略 | `settings.extendParams`、`disabledParams`、`searchImpl`、`searchProvider` |
| 生成参数 | 图像/视频模型的参数 schema、分辨率等 |
| 费用 | 旧式 input/output 价格和新式 `Pricing.units` |

新价格结构支持 fixed、tiered、lookup 三种策略，单位可为百万 token、百万字符、图片、视频、像素、秒，并分别描述文本、音频、图片、视频和缓存读写。它能表达“按分辨率查价”或“超过阈值后分段计价”，不是只有两个 token 单价。

同一类型模块还定义了 benchmark rating，包括 intelligence、speed、price、agentic、writing 和 design 的 0-100 归一化分数及来源日期；但评分不是内置模型卡类型或 `ai_models` 的字段，而是商业层通过 `useBusinessModelRating()` 按 Provider/模型另行注入。它只用于详情和比较界面，不进入普通请求路由，也不构成基于质量的自动选模器。

### 3.4 四种来源的字段完整度不同

内置 [`packages/model-bank/src/aiModels`](../../lobehub/packages/model-bank/src/aiModels) 是最完整的真相源，通常同时给出能力、限制、发布日期、知识截止、参数策略和价格。

部署变量 `*_MODEL_LIST` 由 [`src/utils/server/parseModels.ts`](../../lobehub/src/utils/server/parseModels.ts) 解析。其紧凑语法可表达：

```text
model-id=显示名<context:reasoning:vision:fc:file:video:search:imageOutput>
```

并支持 `+` 增加、`-` 排除和 `-all`。它只能覆盖这套简化词汇，不足以表示分层价格、family、knowledge cutoff 或复杂生成参数。

Provider `/models` 通常只返回 ID、owner、created 等薄条目。远端结果适合发现“当前渠道实际提供什么”，但不能单独承担可靠 capability 和价格目录；同 ID 的 Model Bank 卡片仍负责富化。完全未知的自定义模型则可能只有 ID、类型和空 abilities，需要用户补录。

数据库 `ai_models` 保存用户对内置模型的差量，也保存自定义/远端模型。`source` 区分 `builtin`、`remote`、`custom`，但该字段只是来源标识，不决定请求 Adapter；Adapter 仍由 Provider 和模型类型/设置决定。

### 3.5 合并与覆盖语义

[`packages/database/src/repositories/aiInfra/index.ts`](../../lobehub/packages/database/src/repositories/aiInfra/index.ts) 在聊天可用模型列表中，以 `providerId + modelId` 匹配内置卡和数据库行。用户值按字段覆盖：

- 非空 user `abilities`、`config`、`pricing` 覆盖内置值；
- 数值型上下文窗口、启停与排序等字段优先使用用户值；
- `settings` 做深合并，用户子字段覆盖内置子字段；
- 未被内置列表命中的数据库模型再追加到结果。

Provider 设置页的模型列表则用 `mergeArrayById` 合并，并强制让内置 `type` 覆盖远端/数据库错误类型。原因是多数 `/models` 响应没有类型，直接保存会把 Sora 等视频模型误归为 chat。

这种处理体现了“用户配置优先，但已知分类事实优先”的折中。不同查询为服务各自用途，覆盖字段并非完全同构；扩展元数据字段时需要同时检查聊天列表、设置页列表和 enabled-model selector，不能只改一处 merge。

### 3.6 元数据如何影响运行时

元数据在 LobeHub 中至少参与以下行为：

- 模型选择器可按 `abilities` 中的视觉、函数调用、推理等能力过滤；
- capability 决定上传、工具、搜索、思考、结构化输出和多模态控件；
- `settings.extendParams` 决定展示哪种推理强度、思考预算、图像宽高比、详细程度等扩展参数；推理强度参数新增了**用户级模型实例配置层**（提交 `03929d283`）：`ai_models.config.chatConfig`（类型 `AiModelReasoningConfig`，定义见 `aiModel.ts:323-349`）按 `userId + providerId + modelId` 保存该模型实例的推理强度族默认值，运行时经 `modelExtendParams` 映射进请求参数；它与 Agent 级配置的模型专属字段（如 gpt5ReasoningEffort）并存，两层的合并/覆盖优先级本次未走通（见未验证事项）。
- `disabledParams` 会隐藏并从出站请求删除模型拒绝的 temperature/top-p 等字段；
- `searchImpl` 区分 tool、params、internal 三种联网实现；
- `contextWindowTokens` 用于上下文预算与模型详情，`maxOutput` 约束生成；
- pricing 驱动模型详情和 Message Usage 费用展示，品牌 Provider 还可在展示前替换为 credits 定价；Model Bank 定价的音频输入费用估计（`Pricing` 的 audio 维度，提交 `cd474dfcc`）也会计入同一费用计算。

这些字段不会触发跨 Provider 调度。即使两个渠道中同一个模型的评分或价格不同，普通聊天仍使用 Topic/Agent 中显式保存的 Provider。

### 3.7 一致性风险

- Model Bank 随应用版本发布，远端模型列表刷新不会自动刷新能力、价格、知识截止和参数策略；新模型在下一版内置卡发布前可能只有薄元数据。
- 环境变量 parser、数据库 Zod schema 和 TypeScript `ModelAbilities` 的可表达字段并非完全一致；例如类型层可以描述更多能力，创建/更新接口未必全部开放编辑。
- 用户 ability 非空时会整体替换内置 abilities，而不是逐个布尔字段深合并。只保存一个能力的旧数据可能意外丢掉新版 Model Bank 新增的其他能力。
- pricing 同样通常整体采用用户对象。用户一旦手工覆盖，内置价格更新不会自动补齐该模型的新计费单位。
- 远端同名模型只在当前 Provider 作用域内富化。不能把 Model Bank 的组织归属或 family 当作 Provider 路由键，否则会把聚合平台提供的模型错误改道到原厂。

## 4. Adapter 与协议路由

### 4.1 普通 Provider 是一对一 Runtime 选择

Model Runtime 根据内置 Provider ID 或自定义 Provider 的 SDK 类型选择具体实现。Provider Runtime 再负责：

- SDK 客户端构造；
- Base URL 规范化；
- Header 与认证参数；
- 请求 payload 转换；
- 流式响应转换；
- 上游错误归一化；
- 模型列表拉取。

普通 Provider 的这一层是协议适配，不是多上游调度器。

### 4.2 RouterRuntime 的确支持 option fallback

[`packages/model-runtime/src/core/RouterRuntime/createRuntime.ts`](../../lobehub/packages/model-runtime/src/core/RouterRuntime/createRuntime.ts) 提供通用 Router Runtime：

```text
按 Base URL pattern 匹配 router
  -> 按 model 列表匹配 router
  -> 否则取最后一个 router
  -> 可由 sortRouterOptions() 重排 option
  -> 顺序尝试每个 option
       option 可覆盖 apiType，从而切换底层协议 Runtime
       成功即返回
       不可重试请求错误立即停止
       shouldStopFallback() 可额外终止
  -> onRouteAttempt() 记录每次成功/失败与耗时
```

它可表达一个逻辑 Provider 下的多个真实 channel，也允许 fallback 时从 OpenAI API 切到 Anthropic、Vertex AI 等不同 `apiType`。这是当前代码中最接近完整渠道路由器的部分。

但需要严格区分“框架能力”和“当前品牌配置”。[`packages/business/model-runtime/src/router-runtime-options.ts`](../../lobehub/packages/business/model-runtime/src/router-runtime-options.ts) 中开源的 `lobehubRouterRuntimeOptions.routers()` 直接返回空数组；[`packages/model-runtime/src/providers/lobehub/index.ts`](../../lobehub/packages/model-runtime/src/providers/lobehub/index.ts) 只是把这份配置交给 Router 运行时。

因此当前仓库能确认：

- RouterRuntime 支持多 option、顺序 fallback、动态排序和 attempt 观测钩子；
- LobeHub 品牌 Provider 的真实渠道清单、权重、健康降级和成本策略没有出现在这份开源配置中；
- 不能把托管网关或部署侧能力归因成所有 LobeHub 开源 Provider 的默认客户端能力。

## 5. 多 Key、轮询与重试

### 5.1 逗号分隔字符串表达多 Key

一条 Provider 的 `apiKey` 可以是逗号分隔字符串。服务端 [`apps/server/src/modules/ModelRuntime/apiKeyManager.ts`](../../lobehub/apps/server/src/modules/ModelRuntime/apiKeyManager.ts) 的选择模式是：

- `API_KEY_SELECT_MODE` 默认 `random`：每次初始化时随机选一个；
- `turn`：按完整 Key 字符串维护轮询位置；
- KeyStore 以完整逗号字符串为缓存键。

客户端 `ClientApiKeyManager` 固定为随机模式，没有接线允许用户切换到轮询模式。

这只是请求分摊，不包含：

- Key 失败计数；
- 401、429 或配额耗尽后的标坏；
- 熔断与半开探测；
- 冷却期和自动恢复；
- 按额度、权重或价格分流。

### 5.2 重试时是否换 Key 取决于 Runtime 生命周期

系统没有“当前 Key 失败后主动选下一 Key”的逻辑。重试时可能换 Key，只是重新初始化 Runtime 的副作用：

| 调用路径 | retry 时 Key 行为 |
|---|---|
| 浏览器直连 Provider | 每次重试重新调用服务并初始化 Runtime，可能重新随机取 Key |
| 浏览器调用 `/webapi/chat/:provider` | 每次是新 HTTP 请求，服务端可能重新选 Key |
| Server Agent Runtime | `ServerLLMTransport` 缓存 Provider Runtime Promise，重试复用同一 Runtime 和最初选中的 Key |

即使前两条路径换到了其他 Key，也没有利用上一次错误作健康判断；随机模式还有可能再次选中同一个失败 Key。

### 5.3 Agent Runtime 重试策略

[`packages/agent-runtime/src/utils/runtimeRetry.ts`](../../lobehub/packages/agent-runtime/src/utils/runtimeRetry.ts) 和 [`packages/agent-runtime/src/utils/llmErrorClassifier.ts`](../../lobehub/packages/agent-runtime/src/utils/llmErrorClassifier.ts) 定义当前 Agent Runtime 的策略：

- 默认 `maxRetries = 5`，最多 6 次 attempt；
- 退避从 1 秒开始，每次乘 2，上限 30 秒；
- 408、425、429、5xx、网络、连接和超时错误重试；
- 401/403、400/404/409/422，以及模型不存在、Key、权限、计费、上下文错误停止；
- 未知错误默认归类为可重试；
- 每次重试发布 `stream_retry` 事件供 UI 展示。

Client 和 Server Agent Runtime 都使用这套策略。Provider 和模型在 `call_llm` 准备阶段已固定，重试不会跨 Provider 或跨模型。

品牌 Provider `lobehub` 被列入 `noRetryProviders`，客户端（`src/store/chat/agents/transports/ClientLLMTransport.ts`）和 Server Transport 都不会在 Agent Runtime 再自行重放该逻辑渠道；重试次数与判定仍保持默认 `maxRetries = 5`（`runtimeRetry.ts:1,30-33`）。结合 Router 运行时的 fallback 扩展面，可推断其意图是让品牌渠道自身处理一次请求内的路由；但真实策略未在开源 Router 配置中，不能继续推断具体 SLA 或算法。

还需注意：旧的或零散调用所用 `fetchSSE()` 本身没有这套业务级重试循环，不能把 Agent Runtime 的 5 次重试描述成所有 ModelRuntime 调用的统一保证。

## 6. 跨渠道故障转移、权重与成本路由

普通 Provider 路径没有以下能力：

- Provider A 失败后自动切 Provider B；
- 同模型多 Provider 的优先级链；
- 基于延迟、错误率、余额或价格的动态选择；
- 健康探测结果参与请求调度；
- 多 Base URL 加权负载均衡。

Router 运行时提供了 option 排序、fallback 终止判定和 attempt 观测等扩展点，可以由商业包或部署侧实现健康降级、排序和记录，但仓库中的默认 `lobehub` 配置没有给出实现。

第三方网关自身可能提供 load balancing 或 fallback，那属于上游服务能力。LobeHub 客户端只看到一个 Provider/Base URL 时，不应把上游内部路由写成客户端跨 Provider failover。

## 7. 凭据存储、导入与备份

### 7.1 数据库静态加密

[`apps/server/src/modules/KeyVaultsEncrypt/index.ts`](../../lobehub/apps/server/src/modules/KeyVaultsEncrypt/index.ts) 使用 `KEY_VAULTS_SECRET` 初始化 AES-GCM 密钥：

- Base64 解码后必须为 16、24 或 32 字节；
- 每次加密生成 12 字节随机 IV；
- Web Crypto 返回的最后 16 字节作为认证标签；
- 数据库存储格式为 `iv:authTag:ciphertext` 的十六进制字符串。

Provider 创建和更新时加密该字段，读取 Provider 详情或 Runtime 状态时再解密。数据库静态泄露不会直接得到明文 Key，但应用服务器持有主密钥，且浏览器直连模式会获得运行时明文。

### 7.2 CLI 是管理入口，不是安全导入格式

[`apps/cli/src/commands/provider.ts`](../../lobehub/apps/cli/src/commands/provider.ts) 支持 list、view、create、config、test、toggle、delete 等子命令。配置子命令可写入 API Key、Base URL、检测模型、Responses API 和浏览器请求设置。

CLI 通过已认证的 tRPC 调用服务器，Key 在服务端入库前加密。它没有单独的 Provider 配置文件导入/导出协议，也没有多渠道批量迁移时的密钥重包封装。

### 7.3 全量导出包含 Provider 密文

[`packages/database/src/repositories/dataExporter/index.ts`](../../lobehub/packages/database/src/repositories/dataExporter/index.ts) 的 `DATA_EXPORT_CONFIG` 明确包含 `aiProviders` 和 `aiModels`。导出器直接查询表行并移除 `userId`，没有解密或剔除凭据密文。

这意味着：

- 导出 JSON 不含明文 Provider Key；
- 但包含可离线保存的 `key_vaults` 密文；
- 用同一 `KEY_VAULTS_SECRET` 恢复数据库后可以继续解密；
- 换了主密钥的另一实例无法直接使用这些凭据；
- 恢复设计应同时备份数据库与主密钥，并按同等敏感级别保护两者。

导入器对渠道表使用保留 ID、冲突时跳过的策略，对模型表保留 `providerId + modelId` 关系。它没有对 Provider 密文做解密再加密，因此不是跨主密钥迁移工具。

工作区 API Key 与 Provider 凭据是两套独立机制：`api_keys` 表新增 `capability_scopes` 列（提交 `0c7e2c713`/`ee7b69d17`/`a9bf96d95`/`b0fbd5f18`），工作区 API Key 按成员权限收敛作用域，受限 Key 仍可访问 `/users/me`；本节的静态加密结论不涉及这类 Key。

## 8. 连接测试与可观测性

### 8.1 Web 与 CLI 有两条检测入口

Web 设置页 [`src/routes/(main)/settings/provider/features/ProviderConfig/Checker.tsx`](<../../lobehub/src/routes/(main)/settings/provider/features/ProviderConfig/Checker.tsx>) 允许选择 chat 模型，然后发送一条 `hello`。它使用常规 chatService 路径，并附带 `ConnectivityChecker` trace。

CLI 的 `provider test` 调用 [`apps/server/src/routers/lambda/aiProvider.ts`](../../lobehub/apps/server/src/routers/lambda/aiProvider.ts) 中的 `checkProviderConnectivity`：

```text
读取 Provider 详情
  -> 取命令行 model 或持久化 checkModel
  -> 从数据库初始化指定 Provider Runtime
  -> 非流式发送 "Hi"，temperature = 0
  -> 返回 ok / status / error
```

持久化的是用户选择的检测模型，不是检测结果。Web 的成功/错误只存在当前组件状态，CLI 直接输出结果；两者都没有写 Provider 健康度、连续失败次数、延迟 EWMA 或熔断状态。

### 8.2 运行时观测

可观测性分成几层：

- Agent Runtime 发布 `stream_retry` 事件，UI 可显示重试进度；
- Runtime 和 Transport 记录请求错误；
- 连接检测带 trace 名称，可进入已有 tracing 链路；
- Router 运行时可通过 `onRouteAttempt` 记录 option、channel ID、API type、耗时、成功和错误；
- 它还把最近 route attempt 元数据附到品牌 Provider 的请求 metadata；
- `providerDiagnostics.ts` 中的 `ProviderResponseDiagnostics` 在 provider 边界捕获原始响应事件（有界记录、超限丢弃计数，避免污染 Redis 序列化），是 provider 层新增的诊断捕获点；`signatureScope.ts` 处理签名级（reasoning 等）的状态作用域。

但这些信号默认没有形成普通 Provider 的健康调度闭环。观测到失败不等于后续请求会降低该渠道权重或熔断。

## 9. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| 多 Provider | 有 | 内置目录 + 自定义 Provider |
| 同服务多渠道实例 | 有条件 | 需使用不同自定义 Provider ID |
| 自定义 Base URL | 有 | 保存于加密 `keyVaults` |
| 自定义 Header | 有 | 部分 Runtime 支持 `customHeaders` |
| 多协议 Adapter | 有 | 由内置 ID 或 `sdkType` 选择 |
| 远程模型拉取 | 有 | 浏览器直连或服务端代取 |
| 模型自定义/启停 | 有 | `ai_models` 用户差量 |
| 多 Key | 有 | 逗号分隔字符串 |
| Key 随机/轮询 | 有 | server random/turn，client random |
| Key 健康状态 | 无 | 失败不标坏 |
| Key 熔断/恢复 | 无 | 无冷却和半开探测 |
| 请求重试 | 有 | Agent Runtime 默认 5 次 retry |
| 同请求主动换 Key | 无 | 可能换 Key 只是 Runtime 重建副作用 |
| 普通跨 Provider failover | 无 | Provider/model 固定 |
| Router option fallback | 框架有 | 当前开源品牌路由表为空 |
| 权重路由 | 未见默认实现 | 可由 Router 排序扩展注入 |
| 成本/延迟路由 | 未见默认实现 | Model Bank 定价不参与调度 |
| 凭据静态加密 | 有 | AES-GCM + `KEY_VAULTS_SECRET` |
| 配置全量导出 | 有 | 包含 Provider/模型及凭据密文 |
| 跨主密钥恢复 | 无 | 导入器不重加密密文 |
| 连接测试 | 有 | 单模型、单次最小请求 |
| 健康结果参与调度 | 无 | 检测结果不持久化 |

## 10. 对其他项目的可借鉴点

### 值得借鉴

- 把模型身份稳定表示为 Provider ID 加模型 ID 的组合，避免同名模型误路由；
- Provider、模型和工作区作用域分表，便于用户差量覆盖内置目录；
- 用明确的 SDK Type 选择协议 Adapter，而不是从 URL 猜测协议；
- 将不可重试认证/参数错误与 429、5xx、网络错误分类处理；
- 重试过程发布结构化事件，让 UI 能解释当前状态；
- 凭据数据库静态加密，并在更新时合并 OAuth token 等未出现在表单中的字段；
- Router 运行时将路由选择、option fallback、停止条件、排序和 attempt 观测拆成独立扩展点。

### 需要补强或谨慎复用

- 逗号分隔多 Key 缺少独立 ID、标签、启停和健康数据，不利于精细运维；
- 随机/轮询只做分摊，不能替代配额感知和熔断；
- 不同 Transport 的 Runtime 生命周期使 retry 是否换 Key 不一致；
- 连接检测不进入调度闭环，无法避免持续命中已知故障渠道；
- 浏览器直连开关会扩大凭据暴露面，应在 UI 和权限设计中明确提示；
- 全量导出绑定主密钥，跨实例恢复需要显式密钥迁移流程；
- RouterRuntime 的扩展能力不应在缺少真实路由配置时被描述为现成高可用方案。

## 11. 关键源码索引

- Provider/模型表：[`packages/database/src/schemas/aiInfra.ts`](../../lobehub/packages/database/src/schemas/aiInfra.ts)
- Provider 模型层：[`packages/database/src/models/aiProvider.ts`](../../lobehub/packages/database/src/models/aiProvider.ts)
- Provider 合并仓储：[`packages/database/src/repositories/aiInfra/index.ts`](../../lobehub/packages/database/src/repositories/aiInfra/index.ts)
- 内置 Provider 目录：[`packages/model-bank/src/modelProviders/index.ts`](../../lobehub/packages/model-bank/src/modelProviders/index.ts)
- Provider 类型：[`packages/model-bank/src/types/aiProvider.ts`](../../lobehub/packages/model-bank/src/types/aiProvider.ts)
- 服务端全局配置：[`apps/server/src/globalConfig/genServerAiProviderConfig.ts`](../../lobehub/apps/server/src/globalConfig/genServerAiProviderConfig.ts)
- 服务端 Runtime 初始化：[`apps/server/src/modules/ModelRuntime/index.ts`](../../lobehub/apps/server/src/modules/ModelRuntime/index.ts)
- 多 Key 管理：[`apps/server/src/modules/ModelRuntime/apiKeyManager.ts`](../../lobehub/apps/server/src/modules/ModelRuntime/apiKeyManager.ts)
- 凭据加密：[`apps/server/src/modules/KeyVaultsEncrypt/index.ts`](../../lobehub/apps/server/src/modules/KeyVaultsEncrypt/index.ts)
- Agent Runtime 重试：[`packages/agent-runtime/src/utils/runtimeRetry.ts`](../../lobehub/packages/agent-runtime/src/utils/runtimeRetry.ts)
- 错误分类：[`packages/agent-runtime/src/utils/llmErrorClassifier.ts`](../../lobehub/packages/agent-runtime/src/utils/llmErrorClassifier.ts)
- Router Runtime：[`packages/model-runtime/src/core/RouterRuntime/createRuntime.ts`](../../lobehub/packages/model-runtime/src/core/RouterRuntime/createRuntime.ts)
- 品牌 Router 配置：[`packages/business/model-runtime/src/router-runtime-options.ts`](../../lobehub/packages/business/model-runtime/src/router-runtime-options.ts)
- 连接检测 UI：[`src/routes/(main)/settings/provider/features/ProviderConfig/Checker.tsx`](<../../lobehub/src/routes/(main)/settings/provider/features/ProviderConfig/Checker.tsx>)
- 连接检测 API：[`apps/server/src/routers/lambda/aiProvider.ts`](../../lobehub/apps/server/src/routers/lambda/aiProvider.ts)
- 数据导出：[`packages/database/src/repositories/dataExporter/index.ts`](../../lobehub/packages/database/src/repositories/dataExporter/index.ts)
- 数据导入：[`packages/database/src/repositories/dataImporter/index.ts`](../../lobehub/packages/database/src/repositories/dataImporter/index.ts)
- Provider CLI：[`apps/cli/src/commands/provider.ts`](../../lobehub/apps/cli/src/commands/provider.ts)
