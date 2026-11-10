# Pi LLM 渠道管理调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/ai/`、`packages/coding-agent/src/core/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码梳理 `packages/ai` 的 Provider/认证/模型目录与 `packages/coding-agent` 的 ModelRuntime 组合层；未运行真实 Provider 请求
>
> 调查范围：Provider 与 Endpoint 实体、配置生命周期及配置文件/CLI/TUI/Web/桌面端入口、凭据边界、模型目录、协议 Adapter、运行时选路、重试与故障转移、可观测性；Web 端仅检查 p2 插件
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的 LLM 渠道管理由 `packages/ai`（协议与 Provider 实现）和 `packages/coding-agent` 的 `ModelRuntime`（组合与快照）两层构成：

1. **Provider 是代码注册项，同一类型只有一份实例。** 每个 Provider 是 `packages/ai/src/models.ts` 中 Provider 接口的一个对象，id 在代码里固定；仓库为每种 Provider 类型只保留一份内置注册，用户可经 `models.json` 的 providers 覆盖字段，或由扩展追加注册，同一类型无法创建多个并列实例（`providers/all.ts:89-121`）。Radius 网关是唯一的多实例入口，`radiusProvider` 工厂按传入 id 生成新的 Provider（`providers/radius.ts`）。
2. **模型目录分四层合并**，自下而上依次为：
   - 构建期生成的内置目录：`scripts/generate-models.ts` 从各家公开目录生成，落在 `packages/ai/src/providers/data/`，该目录被 gitignore；
   - 启动期叠加的 pi.dev 远端目录：拉取结果按 ETag 缓存进 `models-store.json`；
   - 用户在 `models.json` 中定义的模型与 modelOverrides；
   - 扩展通过 registerProvider 注册的模型列表。
   合并顺序与覆盖关系见 `core/provider-composer.ts:417-443`，远端目录的拉取在 `core/remote-catalog-provider.ts`。
3. **凭据按 Provider 单粒存储**：API Key 与 OAuth 凭据经 `AuthStorage` 写入 `~/.pi/agent/auth.json`，文件权限 0600 并加 proper-lockfile 文件锁（`core/auth-storage.ts:23`）；运行时另有内存覆盖，以及 `models.json` 内嵌 key 与命令行取值两条临时路径，详见 §3。存储中未发现静态加密，OAuth token 刷新在 `packages/ai/src/auth/resolve.ts` 中加锁完成。
4. **请求统一经 Provider 的 stream 与 streamSimple 发出**：Base URL 取自 `Model.baseUrl`，请求路径由各协议 Adapter 按协议拼接；OpenAI-compatible 的兼容开关按 provider 名与 baseUrl 自动探测，也可用模型上的 compat 字段显式覆盖（`api/openai-completions.ts:1439` 起）。
5. **重试与故障转移分层且范围明确**：
   - SDK 层重试由 API Adapter 内的 `retryProviderRequest` 承担；
   - Assistant 消息层重试由 `retryAssistantCall` 与 coding-agent 会话级 auto_retry 承担（`packages/ai/src/utils/retry.ts`、`core/agent-session.ts:2686`）；
   - 常规请求仍没有客户端侧跨 Provider 的自动故障转移，OpenRouter 与 Vercel Gateway 把路由交给聚合服务。Anthropic Messages 另有一处服务端 refusal fallback：只对模型元数据允许的候选发送 `fallbacks`，响应在输出中途切换模型则报错拒绝。
6. **配置管理以文件和扩展为主，TUI 只覆盖认证及运行时刷新**：`models.json` 的 schema 能表达自定义 Provider、Endpoint 和模型，仓库里没有渠道配置编辑器。TUI 一侧只有认证与模型选择几项操作，即 `/login`、`/logout`、`/model`、`/reload`；新增、复制、删除、启停渠道都没有对应入口。
7. **可观测性以内置为主**：用量与成本由 `calculateCost` 依据模型价格表算出，并在 TUI footer 展示 token 与成本；连接检测复用 `checkAuth`，只确认凭据完整，不发起真实请求（`models.ts:878-898`）。

## 总体调用链

```text
CLI/会话层 (AgentSession) 
  -> ModelRuntime (coding-agent/src/core/model-runtime.ts)
     组合: builtin Provider + models.json 覆盖 + 扩展注册 (provider-composer)
     凭据: RuntimeCredentials -> AuthStorage(auth.json) / env / 运行时 key
  -> Models 集合 (packages/ai/src/models.ts)
     getAuth() 解析凭据 -> provider.stream(model, context, options)
  -> API Adapter (packages/ai/src/api/*.ts, lazy 包装)
     baseURL = model.baseUrl; 路径/请求体/流式解析按协议
  -> 上游 HTTP(S)
```

## 1. Provider、渠道与 Endpoint 数据模型

- **Provider 定义**：`packages/ai/src/models.ts:97-149` 的 `Provider` 接口：

  ```text
  id / name / baseUrl? / headers? / auth（必填 apiKey 或 oauth）/
  getModels() / 可选 refreshModels() / filterModels() / stream / streamSimple /
  可选 fetchDeferred / cancelDeferred
  ```

  注释把 Provider 定位为具体的运行时单元，`Models` 则是 Provider 的集合，该集合的定义见 `models.ts:151-223`。
- **Endpoint 粒度**：Endpoint 的粒度由 `Model.baseUrl` 字段承载，没有独立的 Endpoint 实体（`types.ts:794-813`）。同一 Provider 的不同模型可以各带 baseUrl；`models.json` 中 provider 级 baseUrl 会整体替换内置值，`oauth` 为 radius 的配置除外（`provider-composer.ts:191-195`）。
- **Radius 例外**：`radiusProvider(options)` 用调用方传入的 id 构造 Provider，是唯一能按配置生成多实例的入口（`providers/radius.ts:20-34`）。
- coding-agent 在组装 Provider 阶段为 `models.json` 中 `oauth` 为 radius 且带 baseUrl 的每个配置生成一个使用新 id 的 Radius Provider，默认网关指向 `https://radius.pi.dev`，生成逻辑见 `model-runtime.ts:219-230`，网关默认值见 `providers/radius-config.ts:4`。
- **已知 Provider 枚举**：`KnownProvider` 枚举列出 40 个内置 Provider，涵盖 anthropic、openai、google、deepseek、zai、qwen-token-plan 系列、xiaomi 系列与 cloudflare 系列等，其中 qwen-token-plan-individual 的引入见 #7659；`builtinProviders()` 按该枚举实际构造 40 个（`types.ts:35-75`、`providers/all.ts:89-121`）。
- **订阅制标记**：`OAuthAuth` 用 isSubscription 标志区分订阅制 OAuth，以下 Provider 的 OAuth 均标记为订阅制：
  - GitHub Copilot（`providers/github-copilot.ts:16`）；
  - Kimi Code（`kimi-coding.ts:17`）；
  - OpenAI Codex（`openai-codex.ts:13-17`）；
  - xAI（`xai.ts:17`）。
  ModelRuntime 的 isUsingSubscription 据此判断当前会话是否走订阅制，footer 只对已知订阅制显示 (sub)（`model-runtime.ts:462`）。

## 2. 配置生命周期、管理入口与持久化

- **内置注册**：`ModelRuntime.create` 时逐一构造内置 Provider，随后给每个非 radius 的 Provider 套一层远端目录包装；构造列表见 `providers/all.ts:89-121`，组合过程见 `model-runtime.ts:184-188`，包装实现在 `remote-catalog-provider.ts:45`。
- **用户配置**：`models.json` 由 `ModelConfig.load` 读取并用 TypeBox 校验，schema 由 `ModelConfigSchema` 定义，接受下列 provider 级字段（`core/model-config.ts:193-204,245-284`）：

  ```text
  name / baseUrl / apiKey / api / oauth / headers / compat / authHeader / models / modelOverrides
  ```

  校验失败时记录错误并继续启动，错误经 `getError()` 提供给 UI 展示（`model-runtime.ts:422-431`）。
- **默认与用户合并**：`composeModelProvider` 按“内置 → models.json → 扩展”的顺序叠加配置：先由 `applyModelsJson` 修改内置模型，再套用扩展注册的模型列表，最后让 modelOverrides 覆盖单个模型的字段。三层合并与覆盖顺序见 `provider-composer.ts:420-520,434-443`。
- 某个 Provider 没有任何覆盖层时，`recomposeProvider` 直接复用内置 Provider 原对象（`model-runtime.ts:241-263`）。
- **动态目录持久化**：远端目录刷新结果由 FileModelsStore 写入 `models-store.json`，与 auth.json 共用同一套文件锁后端；每条记录保存 lastModified、checkedAt 与 etag。文件存储见 `core/models-store.ts:46`，记录结构见 `packages/ai/src/models-store.ts:3-14`。该文件只承载模型目录缓存，用户渠道配置由 `models.json` 负责。
- **配置文件入口**：`~/.pi/agent/models.json` 是唯一直接定义用户 Provider 的持久化入口，也可通过 agentDir 或 SDK 指定其他路径。schema 支持新增 Provider、覆盖内置 Provider，以及设置地址、协议、Header、凭据来源与模型定义，字段见 `core/model-config.ts:194-209`；官方文档同样说明自定义 Provider 经该文件添加，打开模型选择器时配置会重新加载（`docs/models.md:1-3,92`）。源码里只有读取、解析、校验和不可变快照，未找到 Pi 写回该文件的新增、编辑、复制、删除、导入或导出服务；按静态推断，用户需用外部编辑器或脚本改文件，再通过 `/model` 或 `/reload` 触发运行时重新组合。
- **已有渠道与新建渠道的配置差异**：已有内置渠道只需在 `providers` 下用同名 key 覆盖 baseUrl、Header 或 modelOverrides，内置模型继续保留，给出 models 时按模型 id 合并或替换；新建渠道必须自带模型和可用的 baseUrl 与 API，由扩展提供完整 Provider 的情况除外，且认证配置完成后才会出现在可用模型列表。两类配置都没有文件级启停字段，把模型排除在模型选择范围之外属于模型作用域设置，只影响模型可见性（`docs/models.md:132-145,300-335`）。
- **CLI**：帮助与命令分发显示 CLI 提供下列渠道相关命令（`cli/args.ts:244-290`、`cli/auth-command.ts:17-45`）：
  - `--list-models`：查看可用模型；
  - `pi update --models`：刷新模型目录；
  - `pi auth check`：检查凭据就绪度；
  - `auth print-api-key` 与 `auth print-bearer-token`：显式输出凭据。
  本次未找到 CLI 的 Provider create/edit/copy/enable/disable/delete/import/export 命令；`--api-key` 是当前运行的临时凭据，不写入渠道配置；`pi update --models` 只刷新目录缓存，不创建或修改 Provider。
- **TUI**：交互命令处理器显示，TUI 的四个命令覆盖认证与模型选择两类操作（`interactive-mode.ts:2955-2979,5227-5257,5361-5402,5635-5645,5683-5770`）：
  - `/login`：按 Provider 选择 OAuth 或 API key 登录，成功后调用 `ModelRuntime.login` 并同步凭据与可用性；
  - `/logout`：只删除 `/login` 保存的凭据，环境变量和 `models.json` 保持不变；
  - `/model`：查看和选择当前可用模型，并触发模型目录刷新；
  - `/reload`：重新加载扩展、资源并重读 `models.json`。
  TUI 因此能对已有内置渠道以及经配置或扩展出现的新渠道执行认证、登出和模型选择，新增、复制、编辑 Endpoint、启停、删除渠道都没有对应命令；扩展注册的 Provider 只能在扩展 API 的 `unregisterProvider` 中注销，用户侧 TUI 没有这一操作（`core/model-runtime.ts:733-786`）。
- **导入与导出**：TUI 与 CLI 的 `/import`、`/export`、`--export` 处理的是 session JSONL/HTML，与渠道配置无关（`interactive-mode.ts:5773-5829`、`cli/args.ts:288-289`）。
- **连接测试**：CLI 的 `auth check` 返回 ready、not_ready、invalid 三种状态，可选择刷新 OAuth。底层的 `ModelRuntime.checkAuth` 只解析凭据，不发真实 Provider 请求（`cli/auth-check.ts:22-52`）；本次未找到独立的真实连接测试入口。`/login` 的网络行为取决于认证方式：OAuth 可能访问认证服务，标准 API key 登录只在本地提示输入并保存凭据，Endpoint 连通性需要另行验证。
- **Web 与桌面端**：仓库内的 p2 自托管 Web 应用（`apps/p2`，Chord 插件 + React）有两个与模型相关的插件：models 插件读取 models.json 的免凭据快照并合成 Provider，提供模型摘要与选择；login 插件提供登录入口。Web 端只有 `ModelPicker.tsx` 这类选择器，没有渠道增删改查页面，仓库也没有原生桌面应用，因此 Web 与桌面端在渠道管理上记为**未找到编辑入口**。若外部宿主自行实现 UI，其行为超出当前仓库源码可确认的范围。
- **凭据生命周期**：登录把凭据写入 `auth.json`，登出由 `AuthStorage.delete` 删除指定 Provider 的存储记录（`core/auth-storage.ts:474-483`）；运行时 key 通过 setRuntimeApiKey、removeRuntimeApiKey 管理，只存在于内存（`core/model-runtime.ts:536-559`）。已有渠道可以登出、新建渠道无法从 TUI 删除，区别在删除对象：前者删除凭据记录，后者涉及的 Provider 定义仍留在 `models.json` 或扩展中。

## 3. 凭据、Header 与代理边界

- **存储位置与权限**：`FileAuthStorageBackend` 把凭据存进 `auth.json`（默认 `~/.pi/agent/auth.json`），文件权限 0600、目录权限 0700，所有写操作都在 proper-lockfile 文件锁内完成；进程内共享 sharedAuthFileReadState，按文件 revision 判断并只重读发生变更的内容（`core/auth-storage.ts:47-202,244-257`）。
- **凭据形状**：每个 Provider 对应一条凭据，形态为 `ApiKeyCredential`（type 取 api_key，另有可选的 key 与 env）或 `OAuthCredential`（type 取 oauth，另有 access、refresh、expires），定义见 `packages/ai/src/auth/types.ts:17-37`。其中 env 保存 Cloudflare 账号、网关 id 这类 Provider 作用域配置。
- **解析优先级**：`resolveProviderAuth` 依次尝试显式 apiKey、已存凭据、环境变量或 ambient 来源（AWS profile、ADC），前一级命中后不再向后取。源码注释把这套关系表述为“已存凭据拥有 Provider”，刷新失败也不会回退到环境变量（`packages/ai/src/auth/resolve.ts:50-110`）。
- **环境变量**：各 Provider 的 API Key 环境变量映射由 `env-api-keys.ts` 维护，常见项包括 OPENAI_API_KEY、ANTHROPIC_API_KEY、GEMINI_API_KEY 与 HF_TOKEN 等；Anthropic 另外支持 ANTHROPIC_AUTH_TOKEN 和 ANTHROPIC_OAUTH_TOKEN，Bedrock 与 Vertex 则走 AWS profile、ADC 等 ambient 来源（`env-api-keys.ts:79-119,166-184`）。
- **models.json 内嵌凭据**：`composeApiKeyAuth`（`provider-composer.ts:298-362`）支持三种取值方式：
  - `apiKey` 直接写明文；
  - 环境变量引用：`$VAR`/`${VAR}` 字符串插值；
  - 命令取值：以 `!command` 前缀执行外部命令，结果在进程内缓存并可用 clearApiKeyCache 清除；解析实现见 `resolve-config-value.ts:80-86,145-151`，缓存与来源标记见 `provider-composer.ts:77,555-569`。
  当前语法限于 `$VAR` 字符串插值和 `!command` 前缀，未提供对象式写法；经这条路径得到的 key 会在登录态来源中标记为 models_json_key 或 models_json_command。
- **Header 与代理**：Provider 级 headers 由 `resolveHeadersOrThrow` 解析环境变量模板，authHeader 为 true 时把 key 注入 Authorization: Bearer 头，模型级 header 则从 modelOverrides 或 models[].headers 合并，两处处理都在 `provider-composer.ts:255-267,389-402`。HTTP 代理通过设置项 httpProxy 注入环境变量，再由各 SDK 的 fetch 层消费（`settings-manager.ts:132`）。
- **脱敏边界**：凭据列表接口只返回 providerId 与 type，登录状态界面因此看不到 key（`auth-storage.ts:397-401`）；需要明文时走 `auth print-api-key` 与 `auth print-bearer-token` 两条显式导出路径，实现见 `cli/credential-print.ts`，分发见 `cli/auth-command.ts`。静态存储、日志输出和导出的 HTML 都没有自动脱敏逻辑，本次也未在日志写入路径中找到对 key 的过滤；auth.json 中的凭据以明文保存。

## 4. 模型目录与能力元数据

- **模型元数据**：`Model` 接口（`types.ts:794-813`）字段：

  ```text
  id / name / api / provider / baseUrl / reasoning / thinkingLevelMap / input / cost /
  contextWindow / maxTokens / samplingParams / headers / compat
  ```

  价格定义在 `ModelCost` 上，字段为 input、output、cacheRead、cacheWrite 与可选的 tiers，单位为美元每百万 token（`types.ts:776-790`）；成本由 `calculateCost` 结合用量算出，其中包含 Anthropic 1 小时 cache write 按 2 倍计价的规则（`models.ts:878-898`）。
- **构建期目录**：`scripts/generate-models.ts` 从各家公开目录生成 `packages/ai/src/providers/data/*.json` 与 models.generated.ts，前者被 gitignore；生成时间戳记录在 data/.manifest.json，读取入口是 getBuiltinModels 与 getBuiltinModel（`providers/all.ts:60-86`）。
- **启动期叠加**：`withRemoteCatalog` 从 `https://pi.dev/api/models/providers/<id>` 拉取增量目录，带 If-None-Match 做 ETag 校验，命中 304 时跳过；刷新窗口由 REMOTE_CATALOG_REFRESH_INTERVAL_MS 控制为 4 小时，只有远端 lastModified 晚于本地生成时间才把结果叠加到内置目录（`remote-catalog-provider.ts:45-131`）。
- **动态 Provider**：Radius 的模型目录来自网关的 `/v1/config` 接口（`providers/radius.ts:67-77`、`radius-config.ts:87`）。
- `refreshModels` 的生命周期由 `Models.refresh` 管理：先恢复缓存，再经凭据解析走网络刷新，并发刷新按 Provider 串行并用 generation 号作废过期结果（`models.ts:320-365,386-446`）。
- **能力过滤**：`getAvailable()` 按 Provider 认证状态筛选可用模型，`filterModels` 允许 Provider 按凭据进一步裁减（例如 Radius 免费层），`getSupportedThinkingLevels` 依据 reasoning 与 thinkingLevelMap 计算可用的思考等级（`models.ts:522-542,902-911`）。

## 5. Adapter、协议与请求组装

- **API 模块**：`packages/ai/src/api/` 下 11 个协议实现（`types.ts:17-29`）：

  ```text
  openai-completions / openai-responses / openai-codex-responses / azure-openai-responses /
  anthropic-messages / bedrock-converse-stream / google-generative-ai / google-vertex /
  mistral-conversations / pi-messages / cloudflare-gateway-binding（AI Gateway 经 Cloudflare AI binding 传输，#7901）
  ```

  每个 API 模块都导出 stream 与 streamSimple 两个入口，实现同一套 ProviderStreams 契约（`types.ts:267-276`）；模块外再套一层 lazy 包装以支持 tree-shaking。Mistral 走原生 HTTP 流，绕开生成客户端与 schema 带来的运行时开销（`api/lazy.ts`、`api/mistral-conversations.ts`）。
- **请求组装**：Base URL 来自 `model.baseUrl`，路径在各 Adapter 内拼接。示例：
  - pi-messages：单 POST 到 `<baseUrl>/messages`（`api/pi-messages.ts:360`）；
  - OpenAI-compatible：SDK `baseURL: model.baseUrl`（`api/openai-completions.ts:674`）；
  - Anthropic：`baseURL: model.baseUrl`（`api/anthropic-messages.ts:872`）；
  - Azure：从 `AZURE_OPENAI_BASE_URL`/`AZURE_OPENAI_RESOURCE_NAME` 组装并规范化路径（`api/azure-openai-responses.ts:181-246`）；
  - Codex：默认 `DEFAULT_CODEX_BASE_URL`，WebSocket 与 fetch 双通道（`api/openai-codex-responses.ts:638-647`）。
- **兼容探测**：`detectCompat` 依据 provider 名和 baseUrl 特征（如 openrouter.ai、deepseek.com、api.z.ai、api.moonshot、gateway.ai.cloudflare.com、chutes.ai）决定该用哪套兼容行为，涉及 developer role、thinking 格式、max_tokens 字段和 cache 控制等，模型上的 compat 字段可显式覆盖结论（`api/openai-completions.ts:1439-1489`、`types.ts:545-597`）。
- **兼容性处理**：
  - DeepSeek 的 baseUrl 探测不区分大小写，请求中发送 max_tokens（`openai-completions.ts`，#7933/#7930）；
  - Fireworks GLM 经 Anthropic Messages 兼容端点传输，并修正 prompt caching（`providers/fireworks.ts` 使用 anthropicMessagesApi，#7676）；
  - OpenAI Responses 侧提供 supportsAdditionalTools 兼容开关，延迟工具经 additional_tools 注入。
- **z.ai 特例**：只走 openai-completions（`zai.ts:6-14`）；`api/anthropic-messages.ts:1228` 处提到 z.ai 的注释与当前实现不一致。
- **Provider 分发**：`createProvider` 接受单个 API 实现，也接受按 model.api 分发的映射表；组合层的 `streamWith` 依次尝试扩展提供的 streamSimple、内置 Provider，最后回落到按 model.api 取到的通用 API 实现（`models.ts:762-862`、`provider-composer.ts:451-471`）。

## 6. 运行时选择、绑定与路由

- **会话绑定**：当前模型保存在 Agent 状态里，会话文件用 model_change 条目记录 Provider 与 modelId，回放会话时从条目恢复模型（`session-manager.ts:63-67,362-377`）；重启后继续会话时，`restoreModelFromSession` 会校验该模型仍然存在且已认证，任一条件不满足就回退到默认选择（`core/model-resolver.ts:705-773`）。
- **解析规则**：`resolveCliModel` 接受 --provider/--model、`provider/model` 规范引用和裸模型 id 三种写法：裸 id 跨 Provider 有歧义时报错，或按唯一已认证的 Provider 消歧；部分匹配优先取无日期后缀的 alias，再取最新日期版本；模型 id 完全未知时用 `buildFallbackModel` 构造自定义模型。`parseModelPattern` 另外解析 model:thinkingLevel 后缀（`model-resolver.ts:134-164,202-255,404-604`）。
- **初始选择优先级**：`findInitialModel` 按下列顺序决定启动时使用哪个模型：
  - CLI 参数；
  - scoped models 列表中的第一个；
  - 设置中指定的默认 Provider 与模型；
  - 按 defaultModelPerProvider 匹配到的可用模型；
  - 第一个可用模型。
  defaultModelPerProvider 为每个内置 Provider 指定默认模型 id（`model-resolver.ts:20-60,620-700`）。
- **模型作用域**：`--models` 或 enabledModels 模式由 `resolveModelScopeFromModels` 解析，支持 `*sonnet*`、`provider/*:high` 这类 glob 与思考等级后缀，结果存进 scopedModels 供 Ctrl+P 循环切换（`model-resolver.ts:280-360`）。
- **别名与路由**：Pi 本地没有语义路由。OpenRouter 通过请求体的 provider 字段把 openRouterRouting（allow_fallbacks、order、only、max_price、preferred_throughput 等）透传给聚合服务，Vercel AI Gateway 采用同样的方式；路由策略由这两个服务执行，Pi 只负责拼装参数（`types.ts:695-763,769-773`）。

## 7. 多 Key、限流、重试与故障转移

- **多 Key**：没有多 Key 池，每个 Provider 只有一条凭据。运行时可以用 setRuntimeApiKey、removeRuntimeApiKey 设置会话级临时 key（如 `--api-key`），其优先级高于存储中的凭据；接口见 `model-runtime.ts:528-547`，优先级判断见 `runtime-credentials.ts:24-28`。本次未发现 Key 轮询、健康状态或冷却机制。
- **SDK 层重试**：`retryProviderRequest` 沿用 OpenAI 与 Anthropic SDK 的重试策略，按 x-should-retry 响应头和 408、409、429、5xx 状态码判断是否重试；退避从 0.5 秒起按指数增长、封顶 8 秒并带随机抖动，服务端 retry-after 超过 maxRetryDelayMs（默认 60 秒）时直接失败，maxRetries 由 settings.retry.provider.maxRetries 配置（`ai/src/utils/provider-retry.ts:105-125`、`settings-manager.ts:23-27,839-843`）。
- **Assistant 消息层重试**：`retryAssistantCall` 处理 stopReason 为 error 的助手消息，由 `isRetryableAssistantError` 用正则对错误文本分类：overloaded、rate limit、429、5xx、网络错误、websocket 关闭、流提前结束等可重试，“exceeded request buffer limit while retrying upstream”也归入可重试模式，quota 与 billing 一类不可重试（`ai/src/utils/retry.ts:7-89,162-211`）。
- 退避与上限：重试间隔为 baseDelayMs * 2^(n-1) 的指数退避，默认 2000 毫秒、最多 3 次，abort 会归一化成 aborted 消息（`settings-manager.ts:818-822`）。
- **会话级自动重试**：`_prepareRetry` 在同一重试预算内对最后一条 assistant 消息执行 continue() 重跑，见 `agent-session.ts:2686-2737`；compaction 的摘要生成也复用同一套 settings.retry（`compaction/compaction.ts:557-580`）。
- **上下文溢出处理**：溢出由单独分支处理，`_isRetryableError` 对 isContextOverflow 返回 false，因此不会被当作普通可重试错误；实际做法是压缩一次并自动重试一次，入口在 `_checkCompaction` 的 overflow 分支，随后调用 `_runAutoCompaction("overflow", willRetry)`（`agent-session.ts:1994-2021,2058,2647`）。代码里没有独立的 `_handleOverflowRecovery` 函数。
- **跨 Provider failover**：客户端仍没有通用的跨 Provider 故障转移链，Anthropic Messages 是范围很窄的例外。模型的 compat.allowedFallbackModels 最多配置三个 Anthropic 服务端 refusal fallback 候选，每个候选带 provider、model 与成本，配成空数组即关闭该能力。请求会带上 server-side-fallback-2026-07-01 beta 头与 fallbacks 字段；服务端返回替代模型时按替代模型的成本计费，如果切换发生在已经开始输出之后则直接报错，避免把两个模型的内容拼成一条消息（`packages/ai/src/types.ts:720-725`、`api/anthropic-messages.ts:176-181,596-617,1014,1170-1173`、`packages/coding-agent/src/core/model-config.ts:154-164`）。

## 8. 连接检测、日志与可观测性

- **连接检测**：`Models.checkAuth` 只检查凭据完整性，对存储、环境变量和命令三类来源逐项确认，不发起真实请求（`models.ts:485-520`）。对 `models.json` 内嵌的 key，检查只确认环境变量引用存在，命令取值既不执行也不验证，这与 types.ts 中 list 操作的约束一致（`provider-composer.ts:326-331`、`types.ts:73-75`）。
- TUI 的 `/login` 流程中 OAuth 会真实换取 token，TUI 内部没有独立的连接测试入口。
- CLI 的 `pi auth check` 复用 `ModelRuntime.checkAuth` 检查 Provider 凭据就绪度，结果为 ready、not_ready 或 invalid，对应退出码 0、1、2；命令还提供 JSON 输出、凭据明细与跳过刷新三个选项，全程不发真实请求（`cli/auth-command.ts`、`cli/auth-check.ts:39-71`）。
- **可用性快照**：`ModelRuntime` 维护四份快照，分别是已配置的 Provider、已存凭据的 Provider、认证结果和可用模型；凭据变化时由 `refreshProviderAvailability` 按 Provider 增量刷新，模型选择器据此展示已认证 Provider 列表（`model-runtime.ts:272-378`）。
- **用量与成本**：用量统一记在 `Usage` 结构中，包含下列字段（`types.ts:367-388`）：

  ```text
  input / output / cacheRead / cacheWrite / reasoning / totalTokens / cost
  ```

  会话内的用量由 usage-totals 汇总成当前会话总计，footer 展示 token 与成本，`/session` 命令输出详细统计（`components/footer.ts`、`agent-session.ts:262-279`）。
- **诊断与日志**：失败消息携带经过脱敏的 diagnostics 数组，内容由 utils/diagnostics.ts 的 formatThrownValue 生成（`types.ts:413-420`）。调试日志写到 `getDebugLogPath()` 返回的路径，路径函数定义在 `config.ts:564`，实际使用点在 `interactive-mode.ts:6196`。TUI 对重试事件和 cache miss 有可见提示，后者的统计来自 cache-stats.ts 模块。遥测包 `packages/telemetry` 提供与厂商无关的合约，本次未逐层追到请求路径上的具体埋点。

## 9. 设计取舍与已确认边界

- **Provider 单例与组合式覆盖**：渠道模型建立在一个 Provider 对象加多层覆盖之上，状态管理因此保持简单；代价是同一服务的多个账号需要手工合并成 auth.json 中的单条 key，或改走 Radius 网关的多实例配置。
- **模型目录去中心化**：内置目录在构建期生成且被 gitignore，运行时再叠加 pi.dev 的远端增量目录，用户还能用 models.json 全量自定义。离线场景和 CI 因此需要配合 build:offline 与 `PI_OFFLINE` 语义（`model-runtime.ts:194`），静态代码里也看不到完整的模型清单。
- **凭据未加密**：auth.json 0600 + 文件锁，无静态加密；models.json 内嵌 key 是明文文件的一部分，属于已确认的设计（官方文档以“配置文件属于用户自己”为前提）。
- **无跨渠道高可用**：重试闭环在同一 Provider/模型内；OpenRouter/Vercel Gateway 的上游路由是外部能力，不作为本地 failover。
- **平台边界**：`packages/ai` 可在 Node 和 Bun 上运行，browser 构建靠 importNodeModule 动态引用与 env-api-keys 的惰性加载保持可用（`auth/context.ts:11-18`），本地文件凭据和 ambient 的 AWS/ADC 来源依赖 node 运行时。当前仓库的 server/client 协议只传递模型快照和会话操作，渠道配置管理由本地文件与扩展承担。
- **管理入口的取舍**：配置定义留在用户可编辑的 `models.json`，扩展注册留在代码里，认证凭据留在 `auth.json`，TUI 只操作凭据和模型作用域。已有 Provider 因此能通过覆盖复用内置目录，新 Provider 能通过文件或扩展加入；配置的复制、删除、导入、导出以及真实连通性验证则没有统一的产品入口。

## 10. 未验证事项

- 未运行真实请求，`checkAuth` 与真实链路的一致性未实测。
- 未运行 TUI 的登录、登出、模型选择与重载命令，也未运行 `pi auth check` 和 `pi update --models`；文件变更后的热加载、凭据同步、模型选择器显示与目录刷新行为仍以静态代码和文档为依据。
- 未运行或接入外部 Web/桌面宿主；p2 的“未找到渠道编辑入口”结论仅基于其插件、Web 组件与仓库文件搜索。
- `data/*.json` 构建期生成，本次未检查生成后的实际模型数与价格数据。
- 代理（`httpProxy`）注入后的各 SDK 消费路径未逐层追完。
- OAuth 各 Provider 流程（device-code/PKCE/回调）仅在 `auth/oauth/` 静态阅读，未运行。
- 遥测包在请求路径的具体埋点未逐层核对。

## 11. 模型与思考能力的近期边界

内置目录包含 Z.AI Coding Plan 的中国区域模型与 Qwen Token Plan 的 DeepSeek V4 Pro，xAI 模型经 Responses API 并默认使用 Grok 4.6。Adapter 支持 OpenAI-compatible 的 reasoning details 回放、Google `thinkingLevelMap`、Azure Responses 的 `toolChoice` 以及 Bedrock 脱敏推理内容的保留，会话中的模型与思考状态因此可在跨回合重放时完整恢复（`packages/ai/CHANGELOG.md` 与 `packages/coding-agent/CHANGELOG.md` 的 0.84.3 条目）。

模型和思考级别的即时选择仍写入会话条目；只有在选择器中按 Ctrl+S 才将所选默认值写回设置。模型与思考选择器均支持搜索和 default 标识，避免一次会话中的临时切换意外成为全局默认（`packages/coding-agent/src/modes/interactive/components/model-selector.ts:73-162`、`thinking-selector.ts:37-104`）。

## 12. 关键源码索引

- `packages/ai/src/types.ts:35-75`：KnownProvider 枚举；`types.ts:794-813`：Model 元数据；`types.ts:695-769`：OpenRouter/Vercel 路由参数
- `packages/ai/src/models.ts:97-149`：Provider 接口；`models.ts:386-446`：refresh 生命周期；`models.ts:762-862`：createProvider 组合
- `packages/ai/src/auth/resolve.ts:50-110`：凭据解析优先级；`auth/credential-store.ts`：内存 CredentialStore
- `packages/ai/src/providers/all.ts:89-121`：内置 Provider 构造；`providers/radius.ts:20-34`：Radius 工厂
- `packages/coding-agent/src/core/model-runtime.ts:172-213`：ModelRuntime.create；`model-runtime.ts:219-230`：Radius 配置；`model-runtime.ts:462`：isUsingSubscription
- `packages/coding-agent/src/core/provider-composer.ts:420-520`：三层组合；`model-config.ts:193-209`：models.json schema
- `packages/coding-agent/src/core/auth-storage.ts:47-202`：auth.json 文件锁存储；`runtime-credentials.ts`：运行时 key
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts:2889-2979`：`/model`、`/login`、`/logout`、`/reload` 命令入口；`interactive-mode.ts:4741-4864`：模型选择与刷新；`interactive-mode.ts:5683-5770`：重载流程
- `packages/coding-agent/src/cli/args.ts:244-305`：CLI 命令及选项；`cli/auth-command.ts:17-45`：auth 子命令；`cli/auth-check.ts:22-52`：凭据就绪检查
- `packages/coding-agent/docs/models.md:1-3,92-92,132-145,300-335`：models.json 的添加、重载和已有 Provider 覆盖语义；`docs/custom-provider.md:188-217`：扩展 Provider 注销的运行时 API
- `packages/coding-agent/src/core/remote-catalog-provider.ts:45-131`：pi.dev 目录叠加
- `apps/p2/plugins/models/`（model-config、provider-config、models、contract）、`apps/p2/plugins/login/server.ts`、`apps/p2/src/web/ModelPicker.tsx`：p2 的模型配置与登录边界
- `packages/coding-agent/src/core/model-resolver.ts:620-700`：初始模型选择
- `packages/ai/src/utils/retry.ts:162-211`：消息层重试；`utils/provider-retry.ts:105-125`：SDK 层重试
