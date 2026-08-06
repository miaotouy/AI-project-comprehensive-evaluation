# Cherry Studio LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-02
>
> 代码快照：`b7673c23860db5dd6da7f42dec5fc21f6b13de1a`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改目标仓库；调查时无未提交修改
>
> 调查范围：LLM 渠道数据模型、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 当前生产代码把一条 LLM 渠道表示为 SQLite 中的一条 `user_provider`。内置 Provider 由 `packages/provider-registry/data/` 提供预设，启动时只增不改地 seed 到用户表；用户配置只保存相对预设的差量，读取时再按“用户差量 > Registry > 应用默认值”合并成运行时 `Provider`。

这套设计的核心不是“一个 Provider ID 对应一种固定协议”，而是 **Provider 实例 + Endpoint Type + Adapter Family**：

- 同一 Provider 可以声明多个 Endpoint Type，例如 OpenAI Chat、OpenAI Responses、Anthropic Messages、Gemini GenerateContent；
- 每个 Endpoint Type 有独立 Base URL，并由 Registry 指定 `adapterFamily`；
- 模型可以用 `endpointTypes[0]` 覆盖 Provider 默认文本端点；
- 用户可以复制一个预设，创建继承同一 `presetProviderId` 的额外实例，因此同一家服务可有多条独立渠道；
- 模型的稳定标识包含 `providerId`，运行时不会只凭裸模型名猜测渠道。

凭据管理比多数纯客户端项目完整：一条 Provider 可保存多个带 ID、标签和启停状态的 API Key，并在请求之间 round-robin；OAuth、AWS、GCP、Azure 等认证也统一进入 `authConfig`。Renderer 读取普通 Provider 时看不到 Key 或 Token，真实凭据只在 Main/Data API 内部使用。

但高可用能力仍然有限：

- 多 Key 只是跨请求轮询，没有失败计数、Key 健康状态、429 熔断或自动恢复；
- 普通聊天默认 `maxRetries: 0`，除非调用方显式覆盖；
- 单次失败不会换下一个 Key、Provider 或模型重放；
- 没有跨 Provider failover、渠道权重、优先级、成本或延迟路由；
- 设置页的批量健康检查会测试每个模型与每个 Key 并显示延迟，但结果不参与运行时调度。

Provider Key、OAuth Token 和云 IAM 凭据以 SQLite JSON 文本字段落在 `<Electron userData>/cherrystudio.sqlite`，当前没有 SQLCipher、字段加密或系统 Keychain。当前仍接线的备份实现被源码明确标记为 v1 legacy：它只复制 IndexedDB、Local Storage 和可选的 `Data` 目录，没有复制 `cherrystudio.sqlite`。因此当前 v2 Provider 配置与凭据不会进入这套真实备份；`src/main/data/db/restore/` 中的 SQLite snapshot/promotion 是新恢复基础设施，不等于已经有可用的 v2 备份入口。

## 总体调用链

```text
packages/provider-registry/data/
  -> RegistryLoader
  -> PresetProviderSeeder（insert-only）
  -> user_provider / user_model（SQLite）

设置页创建、复制或编辑 Provider
  -> Data API
  -> ProviderService
       存用户差量、API Key、authConfig、排序和启停状态
  -> ProviderRegistryService
       合并预设端点、adapterFamily、模型目录和能力元数据

Assistant / 全局默认模型 / @模型
  -> UniqueModelId = providerId + modelId
  -> ModelService 获取 Provider 内模型
  -> resolveEffectiveEndpoint()
       model.endpointTypes[0]
       -> gateway model route
       -> provider.defaultChatEndpoint
  -> providerToAiSdkConfig()
       getRotatedApiKey()
       endpoint adapterFamily -> AI SDK Provider
       Base URL / Header / IAM / OAuth
  -> @cherrystudio/ai-core + AI SDK
  -> customFetch（应用代理感知）
```

## 1. Provider Registry 与用户实例

### 1.1 三层数据，而不是一份完整配置

内置 Provider 和模型目录的真源在 `packages/provider-registry/data/`。预设 seeder 只插入数据库中不存在的 Provider，不覆盖用户已经修改的行。

`user_provider` 并不复制 Registry 的完整定义。以 Endpoint 为例，数据库只持久化用户拥有的 `baseUrl` 覆盖；`modelsApiUrls` 和 `adapterFamily` 仍由 Registry 在读取时注入。这样 Registry 升级后，用户没有覆盖的协议元数据可以跟随更新。

有效配置优先级可以概括为：

```text
user_provider 用户差量
  > providers.json / provider-models.json 预设
  > 应用级默认值
```

`ProviderService.rowToRuntimeProvider()` 返回合并后的 `Provider`，业务层通常不需要判断一个字段来自数据库还是 Registry。

### 1.2 一条用户行就是一条渠道

`user_provider` 的主要字段包括：

| 字段 | 作用 |
|---|---|
| `providerId` | 用户实例的唯一 ID，也是运行时路由键 |
| `presetProviderId` | 继承的预设；自定义 Provider 可为空 |
| `name` / `logoKey` | 显示名称和图标引用 |
| `endpointConfigs` | 用户拥有的各 Endpoint Base URL 差量 |
| `defaultChatEndpoint` | 默认文本生成协议 |
| `apiKeys` | 多 Key 数组，含 ID、值、标签和启停状态 |
| `authConfig` | OAuth 或云 IAM 等认证参数 |
| `apiFeatures` | 对 API 能力基线的差量覆盖 |
| `providerSettings` | Header、超时、服务等级等设置 |
| `isEnabled` / `orderKey` | 启停和展示排序 |

Provider 创建后默认 `isEnabled: false`。启用动作会把它移到同组前部；普通重复启用不会破坏用户排序。

### 1.3 预设可复制为多个渠道实例

设置页的 Duplicate 流程创建新的 `providerId`，同时保留来源的 `presetProviderId`，并让用户重新填写名称、Base URL 和凭据。新实例继续继承同一预设的协议与模型元数据，但拥有独立的：

- API Key 池；
- Endpoint Base URL；
- Provider 设置；
- 启停状态和排序；
- 模型差量。

因此“官方 OpenAI + 两个 OpenAI 兼容中转”可以表达为三个 Provider 实例，而不是挤在一个 Provider 的上游数组中。

内置预设行不能删除；用户复制出的预设实例和纯自定义 Provider 可以删除。删除 Provider 时关联模型通过外键级联处理，模型 Pin 等引用也由服务层清理。

## 2. Endpoint 与 Adapter 路由

### 2.1 Endpoint Type 是协议选择键

Endpoint 不只是 URL。每个 Endpoint Type 的有效配置包含：

- `baseUrl`；
- 按模型类别区分的 `modelsApiUrls`；
- `adapterFamily`。

文本相关类型覆盖 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Google GenerateContent 和 Ollama Chat；自定义 Provider 创建页还可同时配置 OpenAI 图片生成与编辑端点。

运行时端点优先级是：

```text
model.endpointTypes[0]
  -> 多后端网关的按模型路由
  -> provider.defaultChatEndpoint
  -> undefined / OpenAI-Compatible 回退
```

然后 `resolveAiSdkProviderId()` 读取该端点的 `adapterFamily`，必要时再选择 Chat 或 Responses 变体。这里是协议路由，不是错误发生后的容灾路由。

### 2.2 Base URL 与 Header

`providerToAiSdkConfig()` 按 Endpoint Type 格式化 URL：Gemini 补 `v1beta`，Ollama 使用自己的 Host 规则，部分服务禁止自动追加版本。`routeToEndpoint()` 再拆分 Base URL 与端点路径。

`providerSettings.extraHeaders` 会与应用默认 Header、Provider 专用 Header 合并。Azure、Bedrock、Vertex、Copilot、CherryIN、Codex、Grok CLI 等有专门的配置 builder；其余已注册协议走通用 AI SDK Provider，最终才回退 OpenAI-Compatible。

网络请求默认注入 `customFetch`，以复用 Electron Session 的应用代理。个别 Provider 在此基础上增加签名、Body 改写或动态认证。

## 3. 凭据模型与安全边界

### 3.1 多种认证统一在 Provider 行中

`AuthConfig` 当前区分：

- `api-key`；
- `oauth`；
- `iam-aws`；
- `api-key-aws`；
- `iam-gcp`；
- `iam-azure`。

API Key 独立保存在 `apiKeys[]`；OAuth access/refresh token、AWS access key/secret、GCP credentials 则进入 `authConfig`。Codex、Grok CLI、CherryIN 等 OAuth 路径由 `OAuthRuntimeService` 刷新或在 401 后强制刷新，并在请求时注入 Token。

外部 CLI 认证是另一类边界：Claude Code Agent Runtime 等可以依赖 SDK/CLI 自己的认证与重试事件，不应把它们当成普通 Chat Provider 的 API Key 路由能力。

### 3.2 Renderer 默认拿不到秘密

`rowToRuntimeProvider()` 将 `apiKeys` 映射为不含 `key` 的运行时条目，只暴露 ID、标签和启停状态；`authConfig` 也只投影为 `authType`。需要编辑凭据时，设置页调用专用 Data API 资源；普通 Provider 列表和聊天业务不会收到完整秘密。

这降低了 Renderer 泄露面，但不是静态加密：Main 进程仍从 SQLite 读取明文并构造请求。

### 3.3 SQLite 明文落盘

数据库路径由 Path Registry 固定为：

```text
<Electron userData>/cherrystudio.sqlite
```

`DbService` 用 `better-sqlite3` 直接打开文件，并配置 WAL、`synchronous=NORMAL`、外键和 5 秒 busy timeout。没有 SQLCipher 初始化、加密 Key、Keychain 或字段加密调用。

`user_provider.api_keys` 与 `auth_config` 都是 JSON 文本列，因此 Key、Token 和 IAM 凭据可从数据库直接恢复。Renderer 脱敏只保护进程边界，不保护磁盘副本、恶意本机进程或被复制的数据库文件。

### 3.4 当前备份没有覆盖 SQLite

当前 IPC 仍实例化 `LegacyBackupManager`。其 direct backup 只打包：

```text
IndexedDB/
Local Storage/
Data/（可选）
metadata.json
```

源码顶部同时明确写着“v2 can no longer perform real backups”。它没有复制 `cherrystudio.sqlite`，所以 SQLite 中的 Provider、模型、聊天等 v2 业务数据均不在该备份中，不能据此宣称“备份会扩散 Provider 密钥”。实际风险恰好相反：现有备份无法恢复这些渠道配置。

`DbService.createSnapshot()` 和 `src/main/data/db/restore/` 已提供 `VACUUM INTO work.sqlite`、恢复暂存和重启时原子替换能力，但当前可见的用户备份入口尚未接入这条新管线。

## 4. 多 Key 轮询

### 4.1 选择规则

`ProviderService.getRotatedApiKey(providerId)` 的规则很直接：

1. 过滤 `isEnabled=false` 的 Key；
2. 没有可用 Key时返回空字符串；
3. 只有一个 Key时直接返回；
4. 多个 Key时按 Key ID round-robin；
5. 上次使用的 Key ID保存在 Main `CacheService` 的 `settings.provider.<providerId>.last_used_key_id`。

`providerToAiSdkConfig()` 每次构造 SDK 配置时调用一次该方法。连接检查可传 `apiKeyOverride`，从而精确测试某一个 Key 而不受轮询影响。

### 4.2 没有健康状态或同请求换 Key

Key 条目没有错误次数、429 时间、熔断截止时间或健康分。普通请求失败后也没有调用 ProviderService 把该 Key 标坏。

因此多 Key 的准确语义是“请求之间平均分配”，不是：

- 当前请求 429 后换 Key；
- 自动跳过认证失败 Key；
- 按剩余额度、延迟或价格选择 Key；
- 熔断一段时间后自动恢复。

如果一个坏 Key 与一个好 Key同时启用，请求可能按轮询节奏持续交替失败和成功。

## 5. 模型目录与同步

### 5.1 Registry 与上游 API 合并

模型同步先通过 Main IPC `ai.provider.model.list` 请求上游模型列表。Main 读取数据库中的凭据和 Endpoint 配置，Renderer 不接触真实 Key。

拿到上游结果后，`fetchResolvedProviderModels()` 再调用 `/providers/:id/models:resolve`，用 Registry 补充：

- 名称、描述、分组和模型家族；
- capability 与输入/输出模态；
- Endpoint Type；
- 上下文和输出限制；
- 推理参数档位；
- 价格与归属方。

若 Provider 的 `modelListSource` 是 `registry`，则直接读取预设目录；这类目录 fallback 只影响“有哪些模型可选”，不影响推理请求失败后的渠道切换。

### 5.2 模型属于 Provider

模型 ID 使用 `UniqueModelId`，解析后得到 `providerId + modelId`。相同裸模型名可以分别存在于多个 Provider 实例中；选择模型时已经选择了渠道。

模型自己的 `endpointTypes` 可以覆盖 Provider 默认协议。例如同一多协议网关中的 Claude 模型走 Anthropic Messages，而另一模型走 OpenAI Responses。该路由在请求前确定，不读取实时健康度。

### 5.3 Registry 把模型本体与 Provider 覆盖分开

[`packages/provider-registry/src/schemas/model.ts`](../../cherry-studio/packages/provider-registry/src/schemas/model.ts) 的基础模型定义保存模型固有信息：

- ID、名称、描述、family、`ownedBy`、开放权重；
- capability 与输入/输出模态；
- context、最大输入和最大输出；
- 输入、输出、缓存读写、按图和按分钟价格；
- reasoning 控制，包括 effort、token budget 和 toggle；
- temperature/top-p/top-k 等参数支持范围；
- 图像生成各 mode 的控件、范围、输入图数量和专用 transport。

[`packages/provider-registry/src/schemas/provider-models.ts`](../../cherry-studio/packages/provider-registry/src/schemas/provider-models.ts) 则描述 `(providerId, modelId)` 关系。这里可以声明真实 `apiModelId`、变体标签、capability 的 add/remove/force、模态、限制、价格、Endpoint Type、废弃替代项，以及按 Endpoint 区分的 reasoning wire contract。

这种拆分解决了两个常见混淆：能力和上下文通常属于模型本体；模型别名、某网关提供的价格、协议和推理参数编码则属于 Provider-模型组合。聚合平台不会因为复用了同一个基础模型，就被迫共享错误的 API ID 或协议元数据。

### 5.4 元数据在生成期汇集

[`packages/provider-registry/docs/architecture.md`](../../cherry-studio/packages/provider-registry/docs/architecture.md) 说明 registry 是代码生成流水线：creator/provider 的手工 TypeScript 声明，加上生成时实时读取的 models.dev 和 OpenRouter，产出：

| 文件 | 作用 |
|---|---|
| `data/models.json` | 模型本体及固有元数据 |
| `data/providers.json` | Provider 连接和协议定义 |
| `data/provider-models.json` | Provider-模型覆盖与别名 |

[`packages/provider-registry/scripts/upstream.ts`](../../cherry-studio/packages/provider-registry/scripts/upstream.ts) 用 Zod 逐条验证上游数据，格式漂移的条目会被跳过。跨来源合并不是简单选一个赢家：

- capability 和模态取并集；
- context 与最大输出取较大值；
- reasoning control 按种类合并，budget 范围放宽；
- 开放权重只要任一来源为真即为真；
- 定价按字段补齐，较早的 curated 来源在同字段冲突时优先；
- 若 `maxOutputTokens > contextWindow`，最终化阶段丢弃不可信的输出上限。

生成数据随应用发布。运行时 [`RegistryLoader`](../../cherry-studio/packages/provider-registry/src/registry-loader.ts) 只是从磁盘读入、建索引，并在 30 秒空闲后释放内存；下次访问重新读本地文件，不会重新请求 models.dev。所谓模型同步不能替代升级应用或重新生成 registry。

### 5.5 运行时三层覆盖

[`src/shared/data/types/model.ts`](../../cherry-studio/src/shared/data/types/model.ts) 明确给出最终优先级：

```text
用户 user_model 覆盖
  > provider-models.json 的 Provider 级覆盖
  > models.json 的基础模型定义
```

Registry 合并时，Provider override 可修改 capability、模态、context、输出上限、价格、参数支持和 Endpoint Type。随后 [`src/main/data/services/ModelService.ts`](../../cherry-studio/src/main/data/services/ModelService.ts) 应用用户 overlay；用户设置的 capability、模态、协议、限制、reasoning、参数支持和价格均可覆盖基线。`null/undefined` 表示不覆盖，显式空数组则保留，因而可以有意清空 capability 或 Endpoint Type。

最终运行时 `Model` 还包含启停、隐藏、废弃、替代模型和用户 notes。`imageGeneration` 是例外：它在读取时从 registry 注入，不持久化到 `user_model`，避免大块控件 schema 在每个用户数据库中复制。

远端 `/models` 返回的 ID 会用精确 ID、Provider API ID 和规范化 ID 查 registry。带参数规模的 Ollama 风格 ID 优先做保留尺寸的匹配；无法确认具体尺寸时宁可不套元数据，也不借用另一个尺寸变体的价格和限制。

### 5.6 元数据直接参与请求

元数据消费者不止模型选择器：

- `endpointTypes` 与 Provider 默认端点共同确定 OpenAI Chat、Responses、Anthropic、Gemini、Ollama 等 Adapter；
- reasoning support 与 endpoint-specific wire contract 决定 UI 可选档位及最终序列化字段；
- `parameterSupport` 控制 temperature、top-p、max output 等参数是否发送和如何限幅；
- `maxOutputTokens` 参与助手参数裁剪，`contextWindow` 会传给 Ollama 的 `num_ctx`，也用于工具延迟暴露和 Claude 1M context 后缀；
- capability 决定工具调用、视觉、联网、图片/音视频工作流和模型筛选；
- pricing 用于模型详情和用量费用展示，但不参与渠道自动路由。

这套方案的主要代价是元数据错误会同时影响 UI 与 wire protocol，影响面大于普通展示目录。项目通过 schema、catalog invariant、source-sync 和禁止手改生成 JSON 的 CI 约束降低风险；但 live upstream 参与生成，重新生成可能顺带吸收与本次改动无关的价格或能力漂移，仍需审阅生成差异。

## 6. 模型选择与多模型调用

Assistant 保存一个 `modelId: UniqueModelId`；无 Assistant 的 Topic 使用 `chat.default_model_id`。运行时按稳定二元标识精确查找 Provider 和模型。

聊天输入框支持 `@模型` 多选。持久会话中，一次发送可以解析出多个模型，为同一用户消息创建多个 Assistant placeholder，并并行执行多个模型，再以 siblings group 展示结果。这是“同一问题并行比较多个明确选择的模型”，不是某个模型失败后尝试下一个。

多模型还有明确限制：流式会话中的 steer continuation 和临时聊天只使用 `mentionedModelIds[0]`；重试/重新生成会尽量继承目标消息实际使用的模型，避免全局默认模型变化后悄悄漂移。

## 7. 连接检查与可观测性

### 7.1 单 Provider 连接检查

设置页打开连接检查时，先立即保存输入框中尚未完成 debounce 的 Key，再使用第一个可检查模型和指定 `apiKeyOverride` 发起最小请求。默认超时 15 秒，成功后可自动启用有模型的 Provider。

检查中途修改 Provider、Host 或 Key 会 Abort 旧请求，并用 run ID 防止旧回调污染新状态。

### 7.2 批量模型与多 Key 健康检查

`checkModelsHealth()` 可串行或并行检查多个模型；对每个模型，它会并行测试全部 Key 并记录：

- 每个 Key 成功或失败；
- 序列化错误；
- 延迟；
- 模型级成功、部分成功或失败汇总。

图片、视频、音频生成因为可能计费会被标记为生成成本风险，TTS/STT 当前不走这套探针。

这些结果是设置页的即时诊断数据，不会写入 `apiKeys[]`，也不会改变 `getRotatedApiKey()` 的选择。因此“检测出坏 Key”与“运行时自动避开坏 Key”是两回事。

开发者模式还可对 HTTP 请求启用 Trace；普通运行时另有 Topic/Turn trace 和多模型子 Span，但没有以这些指标驱动渠道选择。

## 8. 重试、容错与网络

普通 AI SDK Chat 在 `buildAgentParams()` 中显式设置：

```ts
maxRetries: maxRetries ?? 0
```

即默认不重试。调用方可以通过 `requestOptions.maxRetries` 覆盖，但 SDK 重试仍绑定已经解析完成的同一 Provider、Endpoint、Key 和模型；它不会重新执行渠道决策。

Claude Code Agent Runtime 会接收其 SDK 的 `api_retry` 事件并向 UI 报告 attempt、delay 和错误类别。这属于外部 Agent Runtime 的重试机制，不能外推为普通聊天默认重试。

异步图片/视频任务的轮询、OAuth 401 强制刷新，以及模型列表请求的容错也都有各自用途；它们均不是跨 Provider 推理 failover。

网络层使用 `customFetch` 复用 Electron Session 代理。Provider 可以设置 `timeout` 与额外 Header，但没有单 Provider 的代理池、出口健康选择或自动切换。

## 9. 配置导入

Provider deep link 将 JSON 负载带入设置页，字段包含 ID、Key、Base URL、类型和名称。导入前弹窗确认，并校验 URL Scheme；新 ID 创建 Provider，已有 ID 更新端点，Key 通过专用 API 追加。

类型映射会把 Anthropic、OpenAI Responses、Gemini/Vertex 和 Ollama 解析到相应默认 Endpoint，其余回退 OpenAI Chat Completions。

这是一种用户确认后的配置迁移，不是远程动态配置中心。负载中的 API Key 会经过 URL/路由参数进入应用，调用方仍需考虑浏览器历史、聊天记录或日志对深链的暴露。

## 10. 能力边界与横向比较要点

### 已实现

- Registry 驱动的 Provider 与模型目录；
- 预设 insert-only seed 和运行时差量合并；
- 同一预设下创建多个独立 Provider 实例；
- 多 Endpoint Type 与 Adapter Family 协议路由；
- 独立 Base URL、额外 Header 和 Provider 专属配置；
- 多 API Key 管理与跨请求 round-robin；
- API Key、OAuth、AWS、GCP、Azure 与外部 CLI 认证；
- Main/Data API 凭据隔离和 Renderer 脱敏；
- 上游模型列表与 Registry 元数据合并；
- 单模型、多模型、多 Key 连接检查与延迟展示；
- `@模型` 并行比较；
- 应用代理、HTTP Trace 和取消控制。

### 未实现或不应误判

- 没有 Key 错误计数、熔断、自动恢复或配额感知；
- 多 Key 轮询不等于当前请求内换 Key；
- 普通聊天默认不重试；
- SDK 重试不等于重新选择 Provider；
- 没有跨 Provider、跨模型自动 failover；
- 没有渠道权重、优先级、成本或延迟路由；
- 多 Endpoint 是协议路由，不是容灾路由；
- 模型目录 fallback 不等于推理请求 fallback；
- `@模型` 是并行显式调用，不是错误后的候补链；
- 健康检查结果不进入运行时调度；
- SQLite 凭据没有静态加密；
- 当前 legacy 备份没有覆盖 SQLite Provider 数据。

## 11. 关键源码索引

- Provider Registry 设计：[`docs/references/provider-model/provider-registry.md`](../../cherry-studio/docs/references/provider-model/provider-registry.md)
- Registry 数据：[`packages/provider-registry/data/`](../../cherry-studio/packages/provider-registry/data/)
- Provider 表：[`src/main/data/db/schemas/userProvider.ts`](../../cherry-studio/src/main/data/db/schemas/userProvider.ts)
- Provider 服务与 Key 轮询：[`src/main/data/services/ProviderService.ts`](../../cherry-studio/src/main/data/services/ProviderService.ts)
- Registry 合并：[`src/main/data/services/ProviderRegistryService.ts`](../../cherry-studio/src/main/data/services/ProviderRegistryService.ts)
- Provider 类型与脱敏 Schema：[`src/shared/data/types/provider.ts`](../../cherry-studio/src/shared/data/types/provider.ts)
- Endpoint 解析：[`src/main/ai/provider/endpoint.ts`](../../cherry-studio/src/main/ai/provider/endpoint.ts)
- SDK 配置构建：[`src/main/ai/provider/config.ts`](../../cherry-studio/src/main/ai/provider/config.ts)
- 普通聊天重试参数：[`src/main/ai/runtime/aiSdk/params/buildAgentParams.ts`](../../cherry-studio/src/main/ai/runtime/aiSdk/params/buildAgentParams.ts)
- SQLite 初始化：[`src/main/data/db/DbService.ts`](../../cherry-studio/src/main/data/db/DbService.ts)
- 数据路径：[`src/main/core/paths/pathRegistry.ts`](../../cherry-studio/src/main/core/paths/pathRegistry.ts)
- 当前 legacy 备份：[`src/main/services/LegacyBackupManager.ts`](../../cherry-studio/src/main/services/LegacyBackupManager.ts)
- Renderer 备份入口：[`src/renderer/services/BackupService.ts`](../../cherry-studio/src/renderer/services/BackupService.ts)
- SQLite 恢复基础设施：[`src/main/data/db/restore/README.md`](../../cherry-studio/src/main/data/db/restore/README.md)
- 模型同步：[`src/renderer/pages/settings/ProviderSettings/utils/modelSync.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/utils/modelSync.ts)
- 连接检查：[`src/renderer/pages/settings/ProviderSettings/hooks/providerSetting/useProviderConnectionCheck.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/hooks/providerSetting/useProviderConnectionCheck.ts)
- 批量健康检查：[`src/renderer/pages/settings/ProviderSettings/ModelList/checkModelsHealth.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ModelList/checkModelsHealth.ts)
- 健康检查协议：[`src/renderer/pages/settings/ProviderSettings/utils/healthCheck.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/utils/healthCheck.ts)
- Provider 创建/复制：[`src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderEditorDrawer.tsx`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderEditorDrawer.tsx)
- 自定义多端点：[`src/renderer/pages/settings/ProviderSettings/ProviderList/customProviderCreation.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ProviderList/customProviderCreation.ts)
- Deep Link 导入：[`src/renderer/pages/settings/ProviderSettings/hooks/useProviderDeepLinkImport.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/hooks/useProviderDeepLinkImport.ts)
- 多模型解析：[`src/main/ai/streamManager/context/modelResolution.ts`](../../cherry-studio/src/main/ai/streamManager/context/modelResolution.ts)
- 持久会话多模型调度：[`src/main/ai/streamManager/context/PersistentChatContextProvider.ts`](../../cherry-studio/src/main/ai/streamManager/context/PersistentChatContextProvider.ts)

## 12. 未验证事项

1. 本次没有启动 Electron 应用，也没有向真实 Provider 发起付费或流式请求；连接检查、代理、OAuth 回调和多模型 UI 结论来自源码。
2. 没有枚举并实测 Registry 中每个 Provider 的全部协议组合；专用 Builder 仍可能有服务商级特殊限制。
3. 没有检查操作系统对 Electron `userData` 目录施加的账户级 ACL；“明文”结论只指应用没有额外静态加密。
4. SQLite 新备份/恢复设计仍处于未完成接线状态；本笔记只描述当前可调用入口，不把 `v2-refactor-temp` 或恢复底层设施当成已上线备份能力。
5. CherryIN、AiHubMix 等服务端可能在客户端不可见的位置做模型或上游容灾；本仓库客户端只把它们视为一个 Provider 实例，不能据此推断服务端内部没有 failover。
