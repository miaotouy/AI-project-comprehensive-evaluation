# AIO Hub LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-02
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改目标仓库
>
> 调查范围：LLM 渠道数据模型、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 把一条 LLM 渠道建模为一个 `LlmProfile`。Profile 同时持有协议类型、Base URL、多个 API Key、模型目录、自定义 Header、自定义端点、网络策略和 Provider 专属参数；业务侧用稳定的 `profileId + modelId` 明确选择请求目标。

这套方案的特点是“**渠道配置集中、运行时显式路由、协议适配与网络传输分层**”：

- 桌面端提供 16 种可见 Provider 类型，其中大部分协议族最终复用 OpenAI-Compatible Adapter；
- 每条渠道可配置多个 Key，按轮询选择，并记录启停、连续错误、429 熔断和自动恢复状态；
- 模型属于渠道，既可手工维护，也可调用模型列表端点获取，再由模型元数据规则补全能力；
- Chat、Responses、Anthropic、Gemini、Embedding、Rerank 和媒体生成可以使用不同端点；
- Provider 请求构造/响应解析位于共享 TypeScript Core，桌面网络默认经本地 Rust 代理；
- Agent 默认绑定一个渠道和模型，单次发送、重试、续写时可临时覆盖；历史消息保存实际使用的渠道/模型快照。

它没有“同模型的多渠道池”、渠道权重、优先级、成本路由或跨渠道自动故障转移。多 Key 也不是请求级重试器：某次调用失败后只会更新 Key 健康状态并把错误抛给上层，下一次请求才可能选择另一个 Key。

当前快照还存在一处明确的不一致：设置和 `ProviderType` 都包含 `azure`，但运行时 `adapters` 映射没有 `azure`。Azure 渠道可以被创建，却会在通用请求入口报“不支持的提供商类型: azure”。

## 总体结构

```text
设置页 / 配置导入
  -> useLlmProfiles
       -> llm-service/profiles.json
       -> LlmProfile[]
            type + baseUrl + apiKeys[] + models[]
            customHeaders + customEndpoints + options
            networkStrategy + TLS/HTTP flags

Agent / 临时模型 / 辅助任务
  -> 确定 profileId + modelId
  -> useLlmRequest.sendRequest()
       -> 校验渠道启用状态与渠道内模型
       -> useLlmKeyManager.pickKey()          Key 轮询/健康过滤
       -> filterParametersByCapabilities()   参数裁剪
       -> adapters[profile.type]             协议与能力分派
       -> @aiohub/llm-core Provider Adapter
       -> desktopLlmTransport
       -> fetchWithTimeout
            -> Rust loopback proxy（默认）
            -> WebView fetch（显式 native）
       -> reportSuccess()/reportFailure()     更新 Key 状态
```

## 1. 渠道数据模型

核心类型位于 `src/types/llm-profiles.ts`。

### 1.1 Profile 是渠道管理的聚合根

`LlmProfile` 的关键字段如下：

| 字段 | 作用 |
|---|---|
| `id` / `name` | 稳定引用和用户显示名 |
| `type` | 选择 Provider 协议 Adapter |
| `baseUrl` | 渠道基础地址，可指向官方服务、中转或本地服务 |
| `apiKeys[]` | 同一渠道内的多凭据池 |
| `enabled` | 是否允许普通业务请求使用 |
| `models[]` | 该渠道可选模型及其能力、参数、价格等元数据 |
| `customHeaders` | 用户自定义请求头，支持预设值和高级兼容配置 |
| `customEndpoints` | 按 API 能力覆盖相对路径或完整 URL |
| `options` | Azure、Vertex 等 Provider 特有字段 |
| `networkStrategy` | `auto`、`proxy` 或 `native` |
| `relaxIdCerts` / `http1Only` | Rust 网络层兼容选项 |

模型没有独立于渠道的全局实体。同名模型可以存在于多条 Profile 中，唯一标识是 `profileId:modelId`。这避免了只凭模型名猜测端点；跨渠道切换时则必须同时改变 Profile。

### 1.2 支持的 Provider 类型

`src/config/llm-providers.ts` 当前向设置页声明：

- OpenAI、OpenAI-Compatible、OpenAI Responses；
- DeepSeek、Anthropic Claude、Google Gemini、Cohere；
- SiliconFlow、Groq、OpenRouter、xAI；
- Ollama；
- Azure OpenAI、Vertex AI；
- Suno (NewAPI)、MiniMax Music。

`src/llm-apis/adapters/index.ts` 再把类型映射到实际 Adapter。OpenAI-Compatible Adapter 还被复用于 Groq、OpenRouter、Ollama、SiliconFlow 等渠道；DeepSeek、Gemini、Anthropic、Cohere、Vertex 和媒体协议有专用实现。

类型层、设置层和适配器注册层不是同一个声明源，因此会产生漂移。当前 `azure` 就是可见配置存在、运行时映射缺失的实例。Adapter 表内还保留 `mistral`、`perplexity`、`together`、`lmstudio`、`vllm`、`volcengine`、`dashscope`、`zhipu`、`moonshot` 等兼容别名，但它们不在 `ProviderType` 的设置枚举中，主要依赖预设或兼容路径，而不是完整的一等配置类型。

### 1.3 网络与安全默认值

`DEFAULT_LLM_PROFILE` 默认启用渠道，并把 `networkStrategy` 设为 `auto`。当前 `fetchWithTimeout()` 的真实解释是：除显式 `native` 外都走 Rust 代理，所以 `auto` 实际等同于默认代理路径，而不是运行时在两种传输间探测择优。

`relaxIdCerts` 和 `http1Only` 默认都是 `true`。前者放宽无效证书校验，后者强制 HTTP/1.1；它们提高私有/老旧网关兼容性，但不是官方 HTTPS API 的保守安全与性能默认值。

## 2. 创建、导入与持久化

### 2.1 创建与编辑

`src/views/Settings/llm-service/LlmServiceSettings.vue` 是桌面渠道管理页，支持：

- 从 Provider 预设或空白 Profile 创建渠道；
- 启用、停用、排序、删除和编辑渠道；
- 配置 Base URL、多 Key、网络策略、自定义 Header 和端点；
- 手工添加/编辑模型，或获取远端模型列表；
- 测试模型列表、指定模型、指定能力与指定端点；
- 批量检测模型，查看首字节和总耗时；
- 对图片/音频等可能计费的探测要求显式确认。

渠道停用只阻止普通 `useLlmRequest` 调用。设置页探测通过 `allowDisabledProfile` 或直接调用 Adapter，可以验证尚未启用的渠道。

### 2.2 多格式导入

`src/utils/llm-config-import/` 提供与 UI 解耦的解析层，可从以下内容生成一个或多个 `ParsedLlmProfileDraft`：

- cURL；
- 环境变量文本；
- JSON，包括 OpenCode 多 Provider 和 Codex `auth.json`；
- TOML，包括 Codex `config.toml`；
- 粘贴的混合文档或多个文件。

解析结果包含来源、置信度、警告和候选渠道。创建态可多选批量写入，编辑态只覆盖一个现有渠道；低置信度协议允许人工修正，相同 `providerType + normalizedBaseUrl` 会提示重复。占位 Key 不会当作真实凭据写入。

这种导入面向“迁移已有客户端配置”，不是运行时动态发现或远程配置中心。

### 2.3 明文配置文件

`useLlmProfiles` 使用 `createConfigManager` 将全部 Profile 保存到应用配置目录下的：

```text
llm-service/profiles.json
```

`ConfigManager.save()` 直接对对象执行 `JSON.stringify()` 并通过 Tauri FS 写文本文件，没有调用系统 Keychain、Stronghold 或字段级加密。因而 `apiKeys[]`、自定义鉴权 Header 和 Provider `options` 中的敏感值均以可读 JSON 落盘。

Key 健康状态另存于：

```text
llm-service/key-states.json
```

该文件以完整 Key 字符串作为状态 Map 的键，所以即使未来只加密 `profiles.json`，当前健康状态文件仍会重复暴露凭据。日志只展示 Key 前 8 位，但配置文件不是脱敏存储。

## 3. 模型目录与元数据

### 3.1 远端模型获取

`src/llm-apis/model-fetcher.ts` 先读取 Provider 声明的 `supportsModelList` 和默认端点，再通过共享 `modelListAdapter` 请求。请求会携带：

- Base URL；
- 指定 Key 或 Profile 第一个 Key；
- 自定义 Header；
- `customEndpoints.models`；
- Provider 类型；
- 桌面 Transport 与 60 秒默认超时。

模型列表请求当前显式使用 `strategy: "proxy"`，不遵循 Profile 的 `networkStrategy`。因此即便渠道配置为 `native`，获取模型列表仍走 Rust 代理。

远端结果被转换成 `LlmModelInfo`，保留模型 ID、名称、Provider、上下文长度、输出上限、输入/输出模态、支持参数和价格。OpenRouter 还会请求/保留更完整的输出模态信息。

### 3.2 模型能力是运行时路由依据

`LlmModelInfo.capabilities` 不只是 UI 标签。`useLlmRequest` 会据此选择：

- `embedding` Adapter；
- Rerank；
- 视频、图片、音频/音乐生成；
- 默认 Chat；
- `preferChat` 强制媒体能力仍走对话接口。

模型元数据规则在模型创建、导入、刷新或批量应用时写入模型对象。运行时读取模型快照，不应再实时用全局规则覆盖网络目标或能力。这样规则升级不会悄悄改变已有渠道的请求语义。

### 3.3 远端条目与本地规则是两套元数据

[`src/types/llm-profiles.ts`](../../aio-hub/src/types/llm-profiles.ts) 的 `LlmModelInfo` 是渠道内持久化的模型快照，主要字段包括：

| 类别 | 字段 |
|---|---|
| 身份与展示 | `id`、`name`、`group`、`provider`、`icon`、`description`、`version` |
| 能力 | `capabilities`，覆盖视觉、联网、工具、代码执行、思考、图像/视频/音频生成、Embedding、Rerank、JSON、文档等 |
| 限制 | `tokenLimits.output`、`contextLength`、`contextLengthRange` |
| 模态和协议提示 | `architecture.inputModalities/outputModalities`、`supportedFeatures.parameters/generationMethods` |
| 参数和费用 | `defaultParameters`、`pricing`、`customParameters` |
| 专用行为 | `defaultPostProcessingRules`、`mediaGenParams` |

远端 `/models` 结果经 [`src/llm-apis/model-fetcher.ts`](../../aio-hub/src/llm-apis/model-fetcher.ts) 转换时，会直接写入上下文、最大输出、输入/输出模态、支持参数和价格；能力对象只由远端信息推导 `vision` 与 `thinking`。工具调用、文档、媒体生成等更细能力仍主要依赖预设规则或人工编辑。

另一套是 [`src/types/model-metadata.ts`](../../aio-hub/src/types/model-metadata.ts) 定义的 `ModelMetadataRule`。规则属性是开放对象，内置支持图标、Tokenizer、分组、能力、上下文、价格、描述、推荐用途、版本、发布日期、特性和媒体生成参数。它不是另一张模型目录，而是对任意 Provider/模型 ID 应用的声明式补丁层。

### 3.4 规则匹配与覆盖顺序

[`src/config/model-metadata.ts`](../../aio-hub/src/config/model-metadata.ts) 支持四种匹配类型：

- `provider`：Provider ID 不区分大小写的精确匹配；
- `model`：默认区分大小写的精确匹配，也可改用正则；
- `modelPrefix`：名称虽叫 Prefix，非正则模式实际是对完整模型 ID 做不区分大小写的 `includes`；
- `modelGroup`：已废弃，不参与匹配。

启用规则先按 `priority` 从高到低排序。若命中 `exclusive` 规则，只保留优先级不低于最高独占规则的匹配项；随后按低优先级到高优先级用 `lodash.merge` 深合并，所以高优先级字段最终覆盖低优先级字段，而不同规则中的嵌套能力可以累积。

内置规则按能力、Provider、模型家族、特定模型、图像/视频生成参数和图片输入限制分模块维护，汇总入口是 [`src/config/model-metadata-presets/index.ts`](../../aio-hub/src/config/model-metadata-presets/index.ts)。用户规则由 [`src/stores/modelMetadataStore.ts`](../../aio-hub/src/stores/modelMetadataStore.ts) 保存到 `model-metadata/metadata-rules.json`，并可从旧版 `localStorage` 的 `model-icon-configs` 迁移。

升级时“合并内置”只按规则 ID 添加缺失项，不覆盖已有同 ID 规则。这能保留用户修改，但也意味着已落盘的旧内置规则不会自动吸收同 ID 的字段修订；需要重置或人工调整才能完全追上新版预设。

### 3.5 元数据的实际消费者

这套元数据不是纯展示信息，消费路径至少有四类：

1. 渠道创建、模型导入和批量应用把 `group`、`icon`、`description`、`capabilities`、`mediaGenParams` 写入 `LlmModelInfo`。
2. `useLlmRequest` 根据已保存模型的能力选择 Chat、Embedding、Rerank 或媒体生成 Adapter。
3. [`src/llm-apis/request-builder.ts`](../../aio-hub/src/llm-apis/request-builder.ts) 用模型能力过滤工具、思考等级等请求参数，同时会实时读取活动规则的 `group` 判定模型家族。
4. Token Calculator 会读取规则的 `tokenizer`，媒体生成器会用 `mediaGenParams` 约束控件、剔除不支持的参数。

因此它并非严格的“只在导入时快照”模型：Adapter 大类和大部分 capability gate 依赖模型对象，但模型家族、Tokenizer 和部分工具仍会读取当前活动规则。修改规则可能不改变渠道网络目标，却仍可能改变参数序列化、Token 估算或媒体参数 UI。

### 3.6 数据边界与风险

- 远端 `pricing.prompt/completion` 使用每 token 字符串，规则层 `pricing.input/output` 声明为每百万 token 数值；二者结构和单位不同，没有统一归一化为一个权威费用模型。
- 同一能力在远端条目、模型快照和活动规则中都可能出现，不同写入入口的覆盖顺序并不完全相同。批量应用时通常保留模型已有字段，编辑器“应用预设”则可能用规则值覆盖能力子字段。
- `modelPrefix` 的实现是包含匹配，宽泛短串容易误命中命名空间中的其他模型；正则规则也只在运行时捕获错误并跳过，没有启动期阻断。
- 元数据规则可影响请求参数和 Adapter 选择，应按运行配置管理，不能只当作图标主题文件备份或分发。

## 4. 运行时选择与路由

### 4.1 Agent 是主聊天的默认绑定点

Agent 配置保存 `profileId` 和 `modelId`。主聊天构造请求时先从 Agent 取默认组合；用户可对一次发送指定 `temporaryModel`，不会永久改写 Agent。

上下文预览和历史分支处理的优先级为：

```text
待发送消息的临时渠道/模型
  -> 目标历史节点 metadata 中的渠道/模型
  -> 当前 Agent 默认渠道/模型
```

助手消息 metadata 会记录 `profileId`、`modelId`，并快照 Profile 名、Provider 类型和模型名。即使用户之后重命名或删除渠道，历史消息仍能说明当时实际使用了什么。

翻译、话题命名、上下文压缩、多模态转写等辅助任务也使用 `profileId:modelId` 字符串或显式二元组配置；未单独配置时才回退全局默认模型或 Agent 模型。

### 4.2 通用请求入口

`src/composables/useLlmRequest.ts` 的请求流程是：

1. 按 `profileId` 读取渠道，并检查启用状态。
2. 只在该 Profile 的 `models[]` 中查找 `modelId`。
3. 选择显式 `options.apiKey`，否则调用 `pickKey(profile)`。
4. 克隆 Profile，并把 `apiKeys` 缩成当前选中的单 Key，避免 Adapter 自行再选。
5. 按模型能力过滤不支持的生成参数，再叠加模型 `customParameters`。
6. 注入 Profile 的网络/TLS/HTTP 选项。
7. 用 `adapters[profile.type]` 选择协议实现。
8. 按模型能力选择 Chat、Embedding、Rerank 或媒体方法。
9. 成功/失败后更新 Key 健康状态，并把响应或异常交还调用方。

路由是确定性的，没有读取 Profile 顺序、权重、延迟、剩余额度或价格来改选渠道。

## 5. 多 Key 轮询与熔断

`src/composables/useLlmKeyManager.ts` 为每条 Profile 保存：

- 每个 Key 的手动启用状态；
- `isBroken`、连续错误次数和最近错误；
- 最近使用、失败和熔断时间；
- Profile 上次选择的 Key 下标；
- 全局自动禁用开关与自动恢复时间。

### 5.1 选择策略

`pickKey()` 先过滤手动禁用和已熔断 Key，再从上次下标之后做 round-robin。默认自动恢复时间为 60 秒；到期的熔断 Key 会被恢复并重新参与选择。

如果所有 Key 都不可用，函数不会终止请求，而是回退 `apiKeys[0]`，让上游真实调用再次失败。这能保留错误反馈，但意味着“全部熔断”不是硬隔离，也可能持续请求已知坏 Key。

### 5.2 失败判定

普通业务请求的 `reportFailure()` 规则是：

- 429 / 包含 rate limit 的错误立即熔断；
- 其他错误累计 3 次熔断；
- 成功一次就清零并恢复；
- 错误消息最多保存 2,000 字符。

该通用路径没有先区分认证失败、模型不存在、请求体错误、Provider 5xx 和网络错误；只要不是取消/超时的特殊分支，很多错误都会累计到 Key。由模型名、参数或端点造成的 400 也可能把本来有效的 Key 熔断。

设置页的新探测服务有更细的分类策略：认证失败可强制标坏，网络/超时/Provider 错误视为暂态，授权和限流只记录，模型不可用/参数错误不影响 Key。不过这套 `key-health-policy.ts` 只服务设置页探测，没有完全替换普通请求的粗粒度规则。

### 5.3 没有请求内换 Key 重试

`sendRequest()` 只调用一次 `pickKey()` 和一次 Adapter。失败后执行 `reportFailure()`，随即 `throw error`。它不会在同一请求中：

- 换下一个 Key 重放；
- 判断流是否已经输出部分内容；
- 对 429/5xx 做退避；
- 切换到另一条 Profile。

因此这里的“负载均衡”更准确地说是跨请求的 Key 轮询；“熔断”也是影响后续请求的状态管理，不是当前请求的高可用恢复。

## 6. Provider Adapter 与协议边界

`src/llm-apis/adapters/index.ts` 定义应用层 `LlmAdapter`，能力方法包括 `chat`、`embedding`、`image`、`audio` 和 `video`。具体实现逐步下沉到 `packages/llm-core`：

- OpenAI-Compatible Chat Completions；
- OpenAI Responses；
- Anthropic Messages；
- Gemini / Vertex GenerateContent；
- Cohere Chat V2；
- Embedding、Rerank、模型列表和异步媒体任务。

共享 Core 使用 canonical request/response 和 `ProviderAdapter`，负责请求体、URL、Header、流式 Decoder 与 Provider 语义；它不读取 Vue Store，也不持有 Key 状态。桌面和移动端各自负责把 Profile 变成 Core DTO，并注入平台 Transport。

这个边界让协议兼容可以跨端复用，同时把系统代理、无效证书、本地文件流上传等平台行为留在 Rust/桌面 Transport。

## 7. 自定义端点与 Header

一个 Profile 可分别覆盖 Chat Completions、Responses、Anthropic Messages、Gemini GenerateContent、Completions、Models、Embeddings、Rerank、图片、音频、审查和视频端点。

端点既可为相对路径，也可为完整 URL；部分端点支持 `{model}`、`{video_id}` 等占位符。Adapter 根据协议读取对应字段，Anthropic 还兼容用 `chatCompletions` 作为旧配置回退。

自定义 Header 在 Adapter 构造鉴权与协议 Header 后合并。设置页提供 OpenAI Codex、Claude Code 等客户端兼容预设，因此它不仅用于租户标记，也可改变鉴权、Beta 特性或网关识别行为。Header 值与 API Key 一样明文持久化。

## 8. 网络传输

`packages/llm-core` 产生 `WireRequest`，`src/llm-apis/transports/desktop.ts` 再把 JSON、文本、字节、Multipart 或本地文件引用序列化。

`fetchWithTimeout()` 的桌面策略为：

- `native` 且请求不含本地文件：WebView 直接 fetch；
- 其他情况：启动本机 loopback Rust 代理并转发；
- 本地文件、Multipart 文件和 tagged `LocalFileRef` 必须走 Rust，避免把本地路径或文件内容暴露给 WebView；
- 本地地址/IP 会由上层额外设置 `forceProxy`；
- 代理启动端口冲突时可换到可用端口，并使用进程内 capability token 校验请求。

这里没有从代理失败自动回退到 native，或反向回退。`auto` 也不做健康探测；当前实现是“除显式 native 外使用代理”。

## 9. 测试、探测与可观测性

渠道设置页的 probe 服务支持：

- 模型列表探测；
- Chat 流式/非流式探测；
- Embedding、Rerank、图片和音频能力探测；
- 自定义端点类型覆盖；
- 响应语义校验，而不只判断 HTTP 2xx；
- 首字节时间、总耗时、用量和响应摘要；
- 最多 8 并发的批量模型探测（默认 3）；
- 错误分类：认证、授权、限流、模型不可用、参数、网络、超时、Provider 等。

LLM Inspector 可在统一请求/Transport 入口关联 `requestId`，捕获请求、响应头、流式块和错误上下文。它改善单渠道诊断，但结果不会进入自动渠道评分或动态路由。

共享 Core 和应用 Adapter 均有协议 fixture、流式分帧、模型列表、Probe 与 Transport 单测。设置页也有导入和探测组件测试。

## 10. 能力边界与横向比较要点

### 已实现

- Profile 级渠道增删改查、启停和排序；
- 丰富的官方/兼容 Provider 预设；
- 多格式配置导入与重复提示；
- 多 Key 轮询、手动启停、错误状态、熔断和恢复；
- 模型手工维护、远端发现和能力元数据；
- 多协议、多能力 Adapter；
- 自定义 Header、细粒度端点和 Provider options；
- Agent/辅助任务/临时请求的显式渠道模型选择；
- Rust 代理、网络兼容选项和请求 Inspector；
- 能力感知的连接测试和批量模型探测。

### 未实现或不应误判

- 没有跨 Profile 的同模型聚合或别名层；
- 没有渠道权重、优先级、配额、成本或延迟路由；
- 没有当前请求内 Key 重试；
- 没有跨渠道 failover；
- 没有按错误类别控制普通请求的精细熔断；
- 没有加密或系统凭据库；
- `auto` 网络策略不是自动择优；
- 模型列表请求固定走代理；
- 设置页可见 Provider 与运行时 Adapter 并非单一注册源，当前 Azure 已发生漂移。

## 11. 关键源码索引

- 渠道与模型类型：[`src/types/llm-profiles.ts`](../../aio-hub/src/types/llm-profiles.ts)
- Provider 声明：[`src/config/llm-providers.ts`](../../aio-hub/src/config/llm-providers.ts)
- Profile 持久化：[`src/composables/useLlmProfiles.ts`](../../aio-hub/src/composables/useLlmProfiles.ts)
- Key 状态与轮询：[`src/composables/useLlmKeyManager.ts`](../../aio-hub/src/composables/useLlmKeyManager.ts)
- 通用请求入口：[`src/composables/useLlmRequest.ts`](../../aio-hub/src/composables/useLlmRequest.ts)
- Adapter 注册：[`src/llm-apis/adapters/index.ts`](../../aio-hub/src/llm-apis/adapters/index.ts)
- 模型列表：[`src/llm-apis/model-fetcher.ts`](../../aio-hub/src/llm-apis/model-fetcher.ts)
- 共享 Provider Core：[`packages/llm-core/src`](../../aio-hub/packages/llm-core/src)
- 桌面 Transport：[`src/llm-apis/transports/desktop.ts`](../../aio-hub/src/llm-apis/transports/desktop.ts)
- Rust 代理入口：[`src/llm-apis/common.ts`](../../aio-hub/src/llm-apis/common.ts)
- 设置页：[`src/views/Settings/llm-service/LlmServiceSettings.vue`](../../aio-hub/src/views/Settings/llm-service/LlmServiceSettings.vue)
- 渠道探测：[`src/views/Settings/llm-service/probe/channel-probe-service.ts`](../../aio-hub/src/views/Settings/llm-service/probe/channel-probe-service.ts)
- 配置导入：[`src/utils/llm-config-import`](../../aio-hub/src/utils/llm-config-import)
- Agent 运行时选择：[`src/tools/llm-chat/composables/chat/useChatExecutor.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useChatExecutor.ts)

## 12. 未验证事项

1. 本次未启动 Tauri 桌面端，没有实测官方 Provider、自建网关和代理模式下的 TLS/HTTP 行为。
2. 未检查真实用户配置目录的文件 ACL；“明文落盘”基于序列化与写入实现，不等于配置文件一定对其他系统账户可读。
3. 未实测 Azure 设置流程；“运行时不支持”来自当前 `ProviderType`、设置声明、Adapter 表和通用请求分派的静态交叉核对。
4. 移动端共用 Provider Core，但有独立 Profile Store、KeyManager 和 Transport；本笔记以桌面端渠道管理为主，没有逐屏比较移动端 UI 能力。
5. Suno、MiniMax 等异步媒体任务自身可能有任务轮询重试；它们不等于 LLM Chat 的 Key/渠道故障转移，本次未逐项展开。
