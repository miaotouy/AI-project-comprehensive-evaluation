# Chatbox LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-02
>
> 代码快照：`7450ab2dde5eacab4a8721f8680006ba8b99438d`（分支：`main`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：LLM 渠道数据模型、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 使用“**Provider 注册表 + Provider ID 设置表 + 会话级模型绑定**”管理 LLM 渠道。内置 Provider 在代码中用 `defineProvider()` 声明；用户可以创建任意多个自定义 Provider，每个自定义实例有独立 UUID、协议类型、API Host、API Path、Key 和模型列表。

渠道的运行时键是 `provider + modelId`。内置 Provider 的设置保存在 `settings.providers[providerId]`，所以一个内置 ID 只有一个端点实例；需要第二个 OpenAI/Claude 中转时，应创建自定义 Provider，而不是给内置 Provider 增加多组凭据。

主要能力包括：

- 24 个当前注册的内置 Provider，覆盖 OpenAI Chat/Responses、Anthropic、Gemini、Azure、Bedrock、Ollama 和多家兼容网关；
- 四类自定义协议：OpenAI Chat、OpenAI Responses、Anthropic、Gemini；
- Provider API、Chatbox 后端 manifest、本地保存模型和 models.dev 的四源模型目录；
- 桌面端 API Key 与 OAuth 两套认证，并支持 token 刷新与有限的凭据共享；
- 会话、默认聊天、命名、搜索词生成、OCR、Embedding 和 Rerank 分别绑定 Provider/Model；
- 对 429 和 5xx 在同一渠道内最多尝试 5 次指数退避。

它没有多 Key 池、Key 轮询、渠道权重、跨 Provider 自动故障转移或成本/延迟路由。重试始终使用同一个 Provider、端点和凭据；网络错误默认不重试，以避免服务端已经处理请求时发生重复计费。

桌面端 Provider Key、OAuth access/refresh token 和 AWS 凭据都由 Electron Store 写入 `config.json`，没有配置 `encryptionKey` 或系统凭据库。自动配置备份会复制完整 `config.json`，因此敏感信息也会进入滚动备份；用户主动导出聊天备份时则默认剔除凭据，除非明确选择包含 Key。

## 总体调用链

```text
内置 definitions/* --defineProvider()--> providerRegistry
用户 customProviders[] ------------------> ProviderBaseInfo
settings.providers[providerId] -----------> ProviderSettings
                                                apiHost / apiPath / apiKey
                                                oauth / models / useProxy
                                                Azure / AWS 专属字段

SessionSettings { provider, modelId }
  -> getModel()
       -> registry definition 或 custom provider factory
       -> 合并 Provider 默认值、本地设置、共享 OAuth credential
       -> models.dev 元数据富化
       -> resolveEffectiveApiKey()
       -> 创建 ModelInterface
  -> AbstractAISDKModel
       -> AI SDK Provider
       -> 429/5xx 同渠道指数退避
       -> platform request / proxy
```

## 1. Provider 注册表

### 1.1 单一声明入口

注册表位于 `src/shared/providers/registry.ts`，内部是 `Map<string, ProviderDefinition>`。`src/shared/providers/index.ts` 通过副作用导入所有 definition，模块加载时完成注册；导入顺序同时决定设置页展示顺序。

`ProviderDefinition` 集中声明：

| 字段 | 作用 |
|---|---|
| `id` / `name` / `type` | 路由键、显示名和协议族 |
| `defaultSettings` | 默认 Host、Path 和策展模型 |
| `modelsDevProviderId` | 与 models.dev Provider 的映射 |
| `curatedModelIds` | 默认展示和 registry fallback 白名单 |
| `createModel()` | 把已解析配置实例化为 `ModelInterface` |
| `getDisplayName()` | 自定义消息头模型名称 |

当前 `index.ts` 导入 24 个内置定义：Chatbox AI、OpenAI、OpenAI Responses、Gemini、Claude、DeepSeek、Qwen、Qwen Portal、MiniMax、Moonshot、SiliconFlow、OpenRouter、Ollama、LM Studio、Azure、Groq、xAI、Mistral、Perplexity、Volcengine、ChatGLM、GitHub Copilot、Bedrock 和 Vercel AI Gateway。

注册表统一了 Provider 默认值、运行时工厂和 UI 信息。相较按多个 switch 分散维护，设置页和请求入口能够使用同一个 definition；契约测试还检查内置 ID 唯一性、models.dev 映射与策展模型覆盖。

### 1.2 一个内置 ID 只有一份配置

全局设置的结构是：

```ts
providers?: Record<string, ProviderSettings>
customProviders?: CustomProviderBaseInfo[]
```

`providers[providerId]` 是该 ID 唯一的设置对象。编辑内置 `openai` 的 Host 或 Key，会覆盖原来的 OpenAI 配置；数据模型没有 `openai` 下的多实例数组。

“官方 OpenAI + 两个 OpenAI-Compatible 中转”可配置为：

```text
openai                         内置实例
custom-provider-<uuid-1>       自定义 OpenAI 协议实例
custom-provider-<uuid-2>       自定义 OpenAI 协议实例
```

每个自定义 ID 都会成为一等路由键，可独立出现在模型选择器、会话设置和默认模型配置中。

## 2. Provider 设置模型

`ProviderSettingsSchema` 允许保存：

- `apiKey`、`apiHost`、`apiPath`；
- 用户模型列表和排除模型列表；
- `useProxy`；
- OAuth credential 与 `activeAuthMode`；
- Azure endpoint、deployment、DALL-E deployment、API version；
- Bedrock access key、secret key、session token 和 region。

不同 Provider 的 `createModel()` 只消费自己需要的字段。例如 Azure 用 deployment 资源路径，Bedrock 用 AWS 凭据，OpenAI OAuth 会改用 Responses 模型实现，Claude OAuth 会切换为 Bearer Token 并增加 Anthropic Beta Header。

Provider 默认值与用户设置的关键优先级为：

```text
API Host: 用户 provider setting（OAuth 模式例外）
       -> Provider definition default

API Path: 用户 provider setting
       -> Provider definition default

认证: 桌面且 activeAuthMode=oauth 且有 token -> OAuth token
   否则 -> apiKey

模型: 用户保存模型 -> definition 默认模型 -> 最小 { modelId }
```

OAuth token 对特定官方端点签发，因此 OAuth 启用时会忽略用户自定义 `apiHost`，回到 Provider 默认 Host，避免拿官方 token 请求任意中转地址。

## 3. 自定义 Provider

设置页新增 Provider 时生成 `custom-provider-${uuid}`，用户填写名称并选择 API Mode：

- OpenAI API Compatible；
- OpenAI Responses API Compatible；
- Claude API Compatible；
- Google Gemini API Compatible。

运行时 `getModel()` 若找不到内置 definition，会在 `customProviders[]` 查找 ID，再由 `createCustomProviderModel()` 按 `type` 创建对应模型类。

自定义 Provider 可以拥有自己的 Host、Path、Key、模型和图标。它解决的是“同协议多渠道实例”，不是一个实例内部的 Key 池或上游列表。

### 3.1 导入

Chatbox 支持从剪贴板 JSON 或 `chatbox://provider/import?config=<base64>` 深链导入：

- 内置 Provider 配置更新现有 `providers[id]`；
- 自定义 Provider 写入 `customProviders[]` 和 `providers[id]`；
- 同 ID 导入显示覆盖提示；
- 自定义 ID 禁止与内置注册表 ID 冲突；
- 模型按 `modelId` 去重。

当前导入 schema 的自定义协议只接受 `openai`、`openai-responses` 和 `anthropic`，没有包含设置页手工新增已支持的 Gemini 类型。这是导入面与手工创建面的能力差异。

Base64 深链只是编码，不是加密。配置中如果带 Key，URL 本身含有可还原凭据；实现会先展示确认弹窗再写入，但用户仍需注意浏览器、聊天软件或系统的 URL 记录。

## 4. 模型目录

### 4.1 四个来源

`BaseConfig.getMergeOptionGroups()` 合并：

1. `providerSettings.models`：用户本地保存，优先级最高；
2. Chatbox 后端 model manifest；
3. Provider `listModels()` API；
4. models.dev registry：Provider API 空时的 fallback，并用于元数据富化。

合并时本地模型先进入结果，同 ID 的远程项被过滤，因此用户 nickname 等配置不会被覆盖。随后 models.dev 会覆盖 capability、context window 和 max output 这类事实字段。

只有 Provider API 成功返回时，系统才会从 models.dev 追加近 6 个月发布、但不在策展列表中的“New”模型；fallback 路径仅使用 `curatedModelIds`，避免把未验证的全量目录暴露给用户。

### 4.2 models.dev 缓存

registry 数据获取顺序为：

```text
内存运行时数据 -> 平台 Blob 缓存（7 天 TTL）-> 构建时 snapshot
```

应用启动可后台预取 `https://models.dev/api.json`，并发请求复用同一个 Promise。网络失败保留现有数据，不清空缓存。该 registry 是能力和发现元数据来源，不会改变 Provider 路由键、Host 或凭据。

### 4.3 模型类型

`ProviderModelInfo` 区分 `chat`、`embedding`、`rerank` 和 `image`，并声明 vision、reasoning、tool_use、web_search 等能力。模型能力会控制 UI feature gate、上下文窗口、推理参数、工具和专用工作流。

### 4.4 Registry 原始字段与运行时字段不等宽

[`src/shared/model-registry/types.ts`](../../chatbox/src/shared/model-registry/types.ts) 描述的 models.dev 原始条目包含：名称、family、工具调用、推理、附件、结构化输出、开放权重、输入/输出模态、上下文、输出上限、输入/输出价格、发布日期、更新时间和状态。

转换后的内部 `ModelMetadata` 只保留：

| 字段 | 生成方式 |
|---|---|
| `type` | 模型 ID 含 `embed`/`rerank` 时用启发式分类，否则为 `chat` |
| `capabilities` | `tool_call`、`reasoning`、图像/视频输入分别映射为 `tool_use`、`reasoning`、`vision` |
| `contextWindow` / `maxOutput` | 来自 `limit.context/output` |
| `costInput` / `costOutput` | 来自每百万 token 价格 |
| `family` / `releaseDate` / `status` | 原样保留 |

进入设置和请求链的 [`ProviderModelInfoSchema`](../../chatbox/src/shared/types/settings.ts) 更窄，只有 `modelId`、`providerId`、`type`、`apiStyle`、昵称、标签、四种能力、上下文和最大输出。它没有 family、发布日期、状态或价格字段。

registry 中的 `costInput/costOutput` 虽被生成并保存在 snapshot，当前源码却没有 snapshot 以外的消费者；Chatbox 不能据此计算账单或做成本路由。`web_search` 也存在于运行时能力枚举中，但 models.dev 转换器没有从原始条目生成该标记，需要 Provider 静态定义或其他来源补充。

### 4.5 查找与富化规则

[`src/shared/model-registry/enrich.ts`](../../chatbox/src/shared/model-registry/enrich.ts) 先在对应 Provider 的 registry 中做不区分大小写的精确匹配；失败后再做最长前缀匹配，并要求后续边界是 `-`、`:` 或 `.`。这可覆盖 fine-tune/版本后缀，同时避免 `gpt-4` 错配 `gpt-4o`。

命中后只合并六类值：

- 非空 registry capability 覆盖模型原能力；
- 正数 `contextWindow`、`maxOutput` 覆盖已有值；
- nickname 和 type 仅在模型自身缺失时补齐；
- 最后补上当前解析所用的 `providerId`。

所以 4.1 中的“本地模型优先”只保证同 ID 的远端目录项不会替换本地对象；随后 registry 仍会覆盖 capability、上下文和输出上限。用户 nickname 保留，但用户手工修改的这些事实字段可能被 registry 改回。

Provider 必须通过 [`src/shared/model-registry/provider-mapping.ts`](../../chatbox/src/shared/model-registry/provider-mapping.ts) 映射到 models.dev。ChatboxAI、Azure 等未映射或代理上游多厂商模型的 Provider 默认不会自动富化，避免仅凭相同裸 ID 套用错误厂商元数据。

### 4.6 元数据的运行时作用

[`src/shared/providers/index.ts`](../../chatbox/src/shared/providers/index.ts) 在解析当前模型时再次执行 registry 富化，因此并非只在设置页刷新时使用。主要消费者包括：

- `contextWindow`：限制会话上下文和 Token 预算；
- `maxOutput`：约束最大输出设置；
- `vision`：决定附件/图片路径是否开放；
- `reasoning`：决定推理控制是否展示及是否发送；
- `tool_use`：决定工具能力是否可用；
- `type`：区分普通对话、Embedding、Rerank 与图像流程；
- `apiStyle`：结合 Provider 类型选择 Google、OpenAI Chat、OpenAI Responses 或 Anthropic 请求形态。

能力不是自动探测结果。它来自静态 Provider 定义、后端 manifest、上游模型列表和 registry 的合并；错误或过期标注会直接形成错误的 feature gate。Chatbox 没有通过试调用动态纠正单模型能力，也不会把一次能力相关 4xx 写回 registry。

### 4.7 更新与一致性边界

- 运行时优先使用内存 registry，其次是构建期 snapshot；平台 Blob 只负责给内存层提供较新的副本，不是按 Provider 独立版本化的数据库。
- 网络更新失败会保留旧数据，这是可用性优先策略，但 UI 不展示单个字段的来源时间或新旧差异。
- models.dev 的 GPT-5 chat 变体被显式排除 `reasoning`，因为上游标注与 Chat Completions 实际参数支持不一致。这说明 registry 仍需项目级纠错表，不能视为无条件权威。
- 价格、family、releaseDate、status 已进入内部 snapshot 却未进入 `ProviderModelInfo`，后续若增加成本展示或生命周期管理，应先统一 schema，而不是直接从生成文件旁路读取。

## 5. 运行时选择

### 5.1 会话绑定

每个聊天会话的 `SessionSettings` 保存：

```ts
provider?: string
modelId?: string
```

新会话从全局默认复制设置；注释明确指出，修改全局默认不会影响已有会话。用户在模型选择器中切换后，组合会写回当前会话，所以历史会话能继续使用原 Provider/Model，而不是跟随全局漂移。

`getModel()` 使用会话中的 Provider ID 查注册表或自定义 Provider，再按同一 ID 读取设置和模型，不会根据模型名跨 Provider 搜索。

### 5.2 各用途独立默认模型

全局设置可以分别保存：

- `defaultChatModel`；
- `threadNamingModel`；
- `searchTermConstructionModel`；
- `ocrModel`；
- `defaultEmbeddingModel`；
- `defaultRerankModel`。

每项都是 `{ provider, model }`。这使辅助任务可走低成本渠道、知识库可使用专门 Embedding/Rerank 服务，但仍是静态显式绑定，不是策略路由。

收藏模型同样记录 Provider 和模型二元组；同名模型在不同自定义渠道中不会互相覆盖。

## 6. 认证与凭据

### 6.1 API Key

每个 Provider 只有单个 `apiKey` 字段，没有 `apiKeys[]`、Key 权重或健康状态。运行时也不做 Key 轮询。

### 6.2 OAuth

桌面端当前映射包含 OpenAI、OpenAI Responses、Claude、Qwen Portal、MiniMax、GitHub Copilot 等 OAuth Provider，使用 callback、code-paste 或 device-code 流程。

`createOAuthCredentialManager()`：

- 在 token 到期前 2 分钟刷新；
- 合并并发刷新为同一个 Promise；
- 刷新成功后写回 Provider 设置；
- Provider 返回认证失败时可清除 credential。

`openai-responses` 与 `openai` 共享 OAuth credential 存储，但 `activeAuthMode` 各自独立。也就是说，两者可以复用一次登录，又可以分别选择 OAuth 或 API Key。

Web 和 mobile 即使看到已保存 OAuth 配置，也会回退 `apiKey`；OAuth 请求链只在 desktop 启用。

### 6.3 明文落盘和备份扩散

桌面 `settingsStore` 经 IPC 写入 Electron Store 的：

```text
<Electron userData>/config.json
```

`electron-store` 初始化没有 `encryptionKey`。API Key、OAuth access/refresh token、Azure/AWS 凭据均作为普通 JSON 字段保存。

主进程每 10 分钟检查并备份 `config.json`：今天和昨天每小时保留最后一份，更早的 30 天内每天保留一份。该自动备份直接复制完整文件，所以凭据会出现在多个 `config-backup-*.json` 中。

用户主动导出的 `chatbox-backup-*.zip` 使用另一套清洗逻辑：默认删除 Provider Key、OAuth、AWS credential、Web Search Key 和 MCP 环境变量/Header；只有用户明确选择包含 Key 才保留。这一保护不适用于上述内部自动配置备份。

## 7. 请求重试与容错

`AbstractAISDKModel` 为流式和非流式聊天都包装 `ai-retry`：

- 可重试状态：429 和 500-599；
- 最大尝试次数：5；
- 初始等待：1 秒；
- 退避倍率：2；
- 重试状态会进入 UI 状态回调。

代码把这些状态视为“上游在模型运行前拒绝或崩溃”，因而认为再次调用不会重复计费。AI SDK 自带的通用 `maxRetries` 被强制设为 0，避免与外层叠加。

网络错误不自动重试，因为连接断开并不能证明服务端没有处理计费 POST。图片生成等明确计费操作也禁用网络级自动重试。

这套容错只重试同一个模型实例：

```text
同 Provider ID + 同 Host/Path + 同 Key + 同 modelId
```

它不会切换自定义 Provider、内置 Provider、API Key 或模型。Anthropic 流中出现 Provider 自己的 `fallback` 内容块时能够继续解析，但那是 Anthropic 服务端已完成的模型回退，不是 Chatbox 客户端渠道管理策略。

## 8. 网络与代理

OpenAI-Compatible 公共模型类通过 `createFetchWithProxy()` 调用平台 `apiRequest`。Provider 设置的 `useProxy` 决定是否使用 Chatbox 配置的代理；桌面主进程由 `ensureProxy` 更新代理配置，Web/mobile 则由平台 adapter 解决 CORS 和请求差异。

对于 POST，`apiRequest` 显式传 `retry: 0`，把可计费请求的重试唯一交给上层基于 HTTP 状态的 `ai-retry`。GET 模型列表可以沿用平台请求默认重试策略。

官方 Provider definition 常固定 `useProxy: false`，自定义 OpenAI/Responses 会读取 Provider 的 `useProxy`。全局代理和单 Provider 代理开关的实际效果因模型类而异，并非所有 Provider 都通过完全相同的网络路径。

## 9. 能力边界与横向比较要点

### 已实现

- 注册表式内置 Provider；
- 可创建多个自定义渠道实例；
- 四类自定义协议 Adapter；
- 剪贴板/深链配置导入；
- 单 Provider 的 API Key 或桌面 OAuth；
- OAuth 刷新与有限凭据共享；
- 四源模型目录、models.dev 缓存与能力富化；
- 会话级 Provider/Model 固定绑定；
- 六类用途的独立默认模型；
- 429/5xx 的同渠道指数退避；
- 全局代理、Provider 代理选项和跨平台 request adapter。

### 未实现或不应误判

- 内置 Provider ID 下不能创建多个实例；
- 没有多 Key、Key 轮询或 Key 熔断；
- 没有渠道权重、优先级或健康评分；
- 没有跨 Provider/跨模型 failover；
- 模型目录 fallback 不等于推理请求 fallback；
- Anthropic server-side fallback 不等于客户端渠道切换；
- OAuth token 与 API Key 没有加密落盘；
- 自动配置备份会复制敏感字段；
- 导入 schema 与手工创建的协议覆盖目前并不完全一致（Gemini）。

## 10. 关键源码索引

- Provider 架构文档：[`docs/technical/ai-providers.md`](../../chatbox/docs/technical/ai-providers.md)
- 注册表：[`src/shared/providers/registry.ts`](../../chatbox/src/shared/providers/registry.ts)
- Provider 路由入口：[`src/shared/providers/index.ts`](../../chatbox/src/shared/providers/index.ts)
- Provider definition 类型：[`src/shared/providers/types.ts`](../../chatbox/src/shared/providers/types.ts)
- 自定义 Provider 工厂：[`src/shared/providers/utils.ts`](../../chatbox/src/shared/providers/utils.ts)
- 设置 schema：[`src/shared/types/settings.ts`](../../chatbox/src/shared/types/settings.ts)
- 设置持久化：[`src/renderer/stores/settingsStore.ts`](../../chatbox/src/renderer/stores/settingsStore.ts)
- Electron Store：[`src/main/store-node.ts`](../../chatbox/src/main/store-node.ts)
- 自定义 Provider 创建：[`src/renderer/components/settings/provider/AddProviderModal.tsx`](../../chatbox/src/renderer/components/settings/provider/AddProviderModal.tsx)
- 导入解析：[`src/renderer/utils/provider-config.ts`](../../chatbox/src/renderer/utils/provider-config.ts)
- 模型目录合并：[`src/renderer/packages/model-setting-utils/base-config.ts`](../../chatbox/src/renderer/packages/model-setting-utils/base-config.ts)
- models.dev 获取：[`src/renderer/packages/model-registry/fetch.ts`](../../chatbox/src/renderer/packages/model-registry/fetch.ts)
- 请求重试：[`src/shared/models/abstract-ai-sdk.ts`](../../chatbox/src/shared/models/abstract-ai-sdk.ts)
- 代理请求：[`src/shared/models/utils/fetch-proxy.ts`](../../chatbox/src/shared/models/utils/fetch-proxy.ts)
- OAuth 认证解析：[`src/shared/oauth/resolve-auth.ts`](../../chatbox/src/shared/oauth/resolve-auth.ts)
- OAuth credential manager：[`src/shared/oauth/credential-manager.ts`](../../chatbox/src/shared/oauth/credential-manager.ts)
- 导出脱敏：[`src/shared/utils/backup.ts`](../../chatbox/src/shared/utils/backup.ts)

## 11. 未验证事项

1. 本次未启动桌面、Web 或移动端，没有实测各平台代理、CORS 和 OAuth 回调。
2. 明文结论基于 Electron Store 初始化和 settings schema；未检查操作系统对 `userData` 目录施加的账户级 ACL。
3. 没有逐个执行 24 个 Provider 的真实 API 调用；部分专用模型类可能还有各自的服务端错误兼容。
4. Chatbox AI 自营服务的后端内部路由、供应商冗余和额度策略不在本仓库中；客户端只能看到单个 `chatbox-ai` Provider，不能据此推断服务端没有容灾。
5. 文档称 Provider 系统覆盖 30+ 服务商，而当前静态注册入口为 24 个 definition；营销/历史统计可能把自定义兼容服务或后端渠道计入，本笔记按当前客户端注册表计数。
