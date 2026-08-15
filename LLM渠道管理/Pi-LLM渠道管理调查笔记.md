# Pi LLM 渠道管理调查笔记

> 调查对象：`../../pi`（重点 `packages/ai/`、`packages/coding-agent/src/core/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`534bcbffb7e1e7551d9ee3572dfeb278e203e493`（分支：`main`）
>
> 调查方式：只读源码梳理 `packages/ai` 的 Provider/认证/模型目录与 `packages/coding-agent` 的 ModelRuntime 组合层；未运行真实 Provider 请求
>
> 调查范围：Provider 与 Endpoint 实体、配置生命周期、凭据边界、模型目录、协议 Adapter、运行时选路、重试与故障转移、可观测性；未覆盖浏览器端和 server/client 包的 RPC 通道
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的 LLM 渠道管理由 `packages/ai`（协议与 Provider 实现）和 `packages/coding-agent` 的 `ModelRuntime`（组合与快照）两层构成：

1. **Provider 是代码注册项，不是可多实例化的用户实体。** 每个 Provider 是 `packages/ai/src/models.ts` 中 `Provider` 接口的一个对象，固定 `id`；同一 Provider 类型在仓库内只有一份内置注册（`providers/all.ts:89-121`），用户通过 `models.json` 的 `providers` 覆盖字段和扩展注册，不能创建同一 Provider 的多个并列实例。Radius 网关是唯一的多实例入口（`radiusProvider({ id })` 工厂按配置生成新 id，`providers/radius.ts`）。
2. **模型目录分四层合并**：
   - 构建期生成的内置目录（`packages/ai/src/providers/data/`，gitignore，`scripts/generate-models.ts` 从各家目录生成）；
   - 启动期 pi.dev 远端目录叠加（`core/remote-catalog-provider.ts`，ETag 缓存于 `models-store.json`）；
   - 用户 `models.json` 的模型定义与 `modelOverrides`；
   - 扩展 `registerProvider` 的模型列表。
   合并顺序与覆盖关系在 `core/provider-composer.ts:417-443`。
3. **凭据按 Provider 一粒存储**：API Key/OAuth 凭据经 `AuthStorage` 写入 `~/.pi/agent/auth.json`（0600 权限 + proper-lockfile 文件锁，`core/auth-storage.ts:23`），运行时另有 `setRuntimeApiKey` 内存覆盖与 `models.json` 内嵌 key/命令行取值两条临时路径（详见 §3）。未发现静态加密；OAuth token 刷新在 `packages/ai/src/auth/resolve.ts` 中加锁完成。
4. **请求组装统一到 Provider 的 `stream`/`streamSimple`**：Base URL 是 `Model.baseUrl`，路径由各 API Adapter（`packages/ai/src/api/`）按协议拼接；OpenAI-compatible 的兼容开关按 provider 名和 baseUrl 自动探测（`api/openai-completions.ts:1439` 起），也可由 `compat` 覆盖。
5. **重试与故障转移分层且范围明确**：
   - SDK 层重试在 `api/*` 的 `retryProviderRequest`；
   - Assistant 消息层重试在 `retryAssistantCall`（`packages/ai/src/utils/retry.ts`）与 `coding-agent` 会话级 `auto_retry`（`core/agent-session.ts:2686`）；
   - 未发现跨 Provider 的自动故障转移；OpenRouter/Vercel Gateway 的上游路由是把路由策略作为请求字段交给聚合服务（`types.ts:685-764`）。
6. **可观测性以内置为主**：用量与成本由 `calculateCost` 依据模型价格表计算（`models.ts:878-898`），TUI footer 展示 token/成本；连接检测复用 `checkAuth`（仅确认凭据完整，不发起真实请求）。

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

  注释明确“Provider 是具体运行时单元”，`Models` 是 Provider 集合（`models.ts:151-223`）。
- **Endpoint 粒度**：Endpoint 不是独立实体，只是 `Model.baseUrl` 字段（`types.ts:794-813`）。同一 Provider 的不同模型可以带不同 baseUrl；`models.json` 的 provider 级 `baseUrl` 会整体替换内置 baseUrl，除非 `oauth: "radius"`（`provider-composer.ts:191-195`）。
- **Radius 例外**：`providers/radius.ts:20-34` 的 `radiusProvider(options)` 以传入 `id` 构造 Provider，是唯一可按配置生成多实例的入口。
- `coding-agent` 在 `model-runtime.ts:219-230` 为每个 `models.json` 中 `oauth === "radius"` 且有 baseUrl 的配置生成一个新 id 的 Radius Provider；默认网关为 `https://radius.pi.dev`（`providers/radius-config.ts:4`）。
- **已知 Provider 枚举**：`types.ts:35-75` 的 `KnownProvider` 列出 40 个内置 Provider（anthropic、openai、google、deepseek、zai、qwen-token-plan 系列、xiaomi 系列、cloudflare 系列等；`qwen-token-plan-individual`，#7659）；`providers/all.ts:89-121` 的 `builtinProviders()` 实际构造 40 个。
- **订阅制标记**：`OAuthAuth` 新增 `isSubscription` 标志，以下 Provider 的 OAuth 均标记为订阅制：
  - GitHub Copilot（`providers/github-copilot.ts:16`）；
  - Kimi Code（`kimi-coding.ts:17`）；
  - OpenAI Codex（`openai-codex.ts:13-17`）；
  - xAI（`xai.ts:17`）。
  `ModelRuntime.isUsingSubscription`（`model-runtime.ts:462`）据此判断，footer 只对已知订阅制显示 `(sub)`。

## 2. 配置创建、持久化与迁移

- **内置注册**：`builtinProviders()`（`providers/all.ts:89-121`）在 `ModelRuntime.create` 时逐一构造（`model-runtime.ts:184-188`），每个非 radius 内置 Provider 再用 `withRemoteCatalog` 包裹（`remote-catalog-provider.ts:45`）。
- **用户配置**：`models.json` 由 `ModelConfig.load` 读取并做 TypeBox 校验（`core/model-config.ts:245-284`，schema 见 `ModelConfigSchema`），支持 provider 级字段（`model-config.ts:193-204`）：

  ```text
  name / baseUrl / apiKey / api / oauth / headers / compat / authHeader / models / modelOverrides
  ```

  校验失败时记录错误而不是中断启动，`getError()` 供 UI 展示（`model-runtime.ts:422-431`）。
- **默认与用户合并**：`composeModelProvider`（`provider-composer.ts:420-520`）按“内置 → models.json → 扩展”顺序合并：`applyModelsJson` 先改内置模型（baseUrl、compat、新增/替换模型），`applyExtension` 再套扩展模型列表，最后 `modelOverrides` 做最顶层单模型字段覆盖（:434-443）。
- 无覆盖层时 `recomposeProvider`（`model-runtime.ts:241-263`）直接使用内置 Provider 原对象。
- **动态目录持久化**：远端目录刷新结果写入 `models-store.json`（`FileModelsStore`，`core/models-store.ts:46`），与 auth.json 同用 `AuthStorageBackend` 文件锁；`ModelsStoreEntry` 记录 `lastModified`、`checkedAt`、`etag`（`packages/ai/src/models-store.ts:3-14`）。
- **登录/登出**：`Models.login`（`models.ts:565-615`）执行 Provider 的 apiKey 或 oauth 登录方法后写入 CredentialStore；`ModelRuntime.login/logout`（`model-runtime.ts:673-687`）在凭据变更后重新组合 Provider 并刷新该 Provider 的可用性快照。`models.json` 的增删改需要手动编辑文件后 `/reload` 或重启，源码未见热编辑 API。

## 3. 凭据、Header 与代理边界

- **存储位置与权限**：`FileAuthStorageBackend` 以 `auth.json`（默认 `~/.pi/agent/auth.json`）为文件，写权限 0600、目录 0700，所有写操作在 proper-lockfile 文件锁内完成（`core/auth-storage.ts:47-202`）；进程内共享 `sharedAuthFileReadState` 按文件 revision 只重读变更（`auth-storage.ts:244-257`）。
- **凭据形状**：每 Provider 一文件：`ApiKeyCredential { type: "api_key", key?, env? }` 或 `OAuthCredential { type: "oauth", access, refresh, expires }`（`packages/ai/src/auth/types.ts:17-37`）。`env` 保存 Cloudflare 账号/网关 id 等 Provider 作用域配置。
- **解析优先级**：`resolveProviderAuth`（`packages/ai/src/auth/resolve.ts:50-110`）：显式 `apiKey` 覆盖 > 已存凭据 > 环境变量/ambient（AWS profile、ADC）。注释明确“已存凭据拥有 Provider，刷新失败后不回退环境变量”。
- **环境变量**：`env-api-keys.ts:79-119` 维护各 Provider 的 API Key 环境变量映射（OPENAI_API_KEY、ANTHROPIC_API_KEY、GEMINI_API_KEY、HF_TOKEN 等）；Anthropic 还支持 `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_OAUTH_TOKEN`；Bedrock/Vertex 走 AWS profile、ADC 等 ambient 源（`env-api-keys.ts:166-184`）。
- **models.json 内嵌凭据**：`composeApiKeyAuth`（`provider-composer.ts:298-362`）支持三种取值方式：
  - `apiKey` 直接写明文；
  - 环境变量引用：`$VAR`/`${VAR}` 字符串插值；
  - 命令取值：`!command` 前缀执行（`resolve-config-value.ts:80-86、145-151` 实现，命令结果进程内缓存，`clearApiKeyCache` 可清，provider-composer.ts:77；无 `$env`/`$command` 对象语法）。
  这类 key 的登录态来源标记为 `models_json_key`/`models_json_command`（`provider-composer.ts:555-569`）。
- **Header 与代理**：Provider 级 `headers` 支持环境变量模板解析（`resolveHeadersOrThrow`）；`authHeader: true` 把 key 注入 `Authorization: Bearer`（`provider-composer.ts:255-267`）；模型级 header 按 `modelOverrides/models[].headers` 合并（:389-402）。HTTP 代理经设置项 `httpProxy` 注入环境变量，由各 SDK 的 fetch 层消费（`settings-manager.ts:132`）。
- **脱敏边界**：`list()` 只返回 `providerId + type`（`auth-storage.ts:397-401`），登录状态 UI 不显示 key；`auth print-api-key`/`print-bearer-token`（`cli/credential-print.ts`，经 `cli/auth-command.ts` 分发）是显式导出路径。静态存储、日志输出、导出 HTML 均未见自动脱敏逻辑；本次未在日志写入路径中找到对 key 的过滤。凭据静态未加密。

## 4. 模型目录与能力元数据

- **模型元数据**：`Model` 接口（`types.ts:794-813`）字段：

  ```text
  id / name / api / provider / baseUrl / reasoning / thinkingLevelMap / input / cost /
  contextWindow / maxTokens / samplingParams / headers / compat
  ```

  价格是 `ModelCost { input, output, cacheRead, cacheWrite, tiers? }`（美元/百万 token，`types.ts:776-790`），成本由 `calculateCost` 结合用量计算（`models.ts:878-898`，含 Anthropic 1h cache write 2 倍规则）。
- **构建期目录**：`scripts/generate-models.ts` 从各家公开目录拉取生成 `packages/ai/src/providers/data/*.json`（gitignore）与 `models.generated.ts`；模型数据生成时间戳记录在 `data/.manifest.json`（`providers/all.ts:72-76`）。`getBuiltinModels`/`getBuiltinModel` 提供类型化读取（`providers/all.ts:60-86`）。
- **启动期叠加**：`withRemoteCatalog`（`remote-catalog-provider.ts:45-131`）从 `https://pi.dev/api/models/providers/<id>` 拉取增量目录，用 `If-None-Match` ETag 做 304 校验，4 小时刷新窗口（`REMOTE_CATALOG_REFRESH_INTERVAL_MS`），只在远端 `lastModified` 晚于本地生成时间时叠加（`remote-models` 判断）。
- **动态 Provider**：Radius 从网关 `/v1/config` 拉取模型目录（`providers/radius.ts:67-77`、`radius-config.ts:87`）。
- `refreshModels` 生命周期由 `Models.refresh` 管理（`models.ts:386-446`）：先恢复缓存，再走凭据解析与网络刷新；并发刷新按 Provider 串行并支持 generation 作废（`models.ts:320-365`）。
- **能力过滤**：`getAvailable()` 按 Provider 认证状态过滤出可用模型（`models.ts:522-542`）；`filterModels` 允许 Provider 按凭据裁减（如 Radius 免费层）。`getSupportedThinkingLevels` 依据 `reasoning + thinkingLevelMap` 计算思考等级（`models.ts:902-911`）。

## 5. Adapter、协议与请求组装

- **API 模块**：`packages/ai/src/api/` 下 11 个协议实现（`types.ts:17-29`）：

  ```text
  openai-completions / openai-responses / openai-codex-responses / azure-openai-responses /
  anthropic-messages / bedrock-converse-stream / google-generative-ai / google-vertex /
  mistral-conversations / pi-messages / cloudflare-gateway-binding（AI Gateway 经 Cloudflare AI binding 传输，#7901）
  ```

  每个模块导出 `stream`/`streamSimple`（`ProviderStreams` 契约，`types.ts:267-276`），lazy 包装用于 tree-shaking（`api/lazy.ts`）。Mistral 由 SDK 传输改为原生 HTTP 流（`api/mistral-conversations.ts`，去掉生成客户端与 schema 运行时开销，#9dd90a4）。
- **请求组装**：Base URL 来自 `model.baseUrl`，路径在各 Adapter 内拼接。示例：
  - pi-messages：单 POST 到 `<baseUrl>/messages`（`api/pi-messages.ts:360`）；
  - OpenAI-compatible：SDK `baseURL: model.baseUrl`（`api/openai-completions.ts:674`）；
  - Anthropic：`baseURL: model.baseUrl`（`api/anthropic-messages.ts:872`）；
  - Azure：从 `AZURE_OPENAI_BASE_URL`/`AZURE_OPENAI_RESOURCE_NAME` 组装并规范化路径（`api/azure-openai-responses.ts:181-246`）；
  - Codex：默认 `DEFAULT_CODEX_BASE_URL`，WebSocket 与 fetch 双通道（`api/openai-codex-responses.ts:638-647`）。
- **兼容探测**：OpenAI-compatible 的 `detectCompat`（`api/openai-completions.ts:1443`）按 provider 名 + baseUrl 特征（openrouter.ai、deepseek.com、api.z.ai、api.moonshot、gateway.ai.cloudflare.com、chutes.ai 等）自动决定 developer role、thinking 格式、max_tokens 字段、cache 控制等（`api/openai-completions.ts:1439-1489`），`model.compat` 可显式覆盖（`types.ts:545-597`）。
- **兼容性修正（提交追溯）**：
  - DeepSeek 的 baseUrl 探测改为大小写不敏感，且发送 `max_tokens`（`openai-completions.ts`，#7933/#7930）；
  - Fireworks GLM 走 Anthropic Messages 兼容端点并修正 prompt caching（`providers/fireworks.ts` 用 `anthropicMessagesApi`，#7676）；
  - OpenAI Responses 侧新增 `supportsAdditionalTools` 兼容开关（延迟工具经 `additional_tools` 注入，#e47b8e3）。
- **z.ai 特例**：仅走 openai-completions（`zai.ts:6-14`）；`api/anthropic-messages.ts:1228` 提及 z.ai 的注释与当前实现不一致。
- **Provider 分发**：`createProvider` 支持单个 API 实现或按 `model.api` 分发的 map（`models.ts:762-862`）；组合层 `streamWith` 优先扩展 `streamSimple`、再内置 Provider、最后 `getApiProvider(model.api)` 的通用 API 实现（`provider-composer.ts:451-471`）。

## 6. 运行时选择、绑定与路由

- **会话绑定**：模型保存在 Agent 状态（`agent.state.model`），会话文件用 `model_change` 条目记录 Provider+modelId，回放会话时从条目恢复（`session-manager.ts:63-67, 362-377`）；重启继续会话时 `restoreModelFromSession` 校验模型仍存在且有认证，否则回退（`core/model-resolver.ts:705-773`）。
- **解析规则**：`resolveCliModel`（`model-resolver.ts:404-604`）支持 `--provider/--model`、`provider/model` 规范引用、裸模型 id（跨 Provider 歧义时报错或按唯一已认证 Provider 消歧）、部分匹配时优先 alias（无日期后缀）再取最新日期版本（`tryMatchModel`，`model-resolver.ts:134-164`）、未知 id 时构造 `buildFallbackModel` 自定义模型。`parseModelPattern` 支持 `model:thinkingLevel` 后缀（`model-resolver.ts:202-255`）。
- **初始选择优先级**：`findInitialModel`（`model-resolver.ts:620-700`）：CLI 参数 > scoped models 首个 > 设置里的默认 Provider/模型 > 按 `defaultModelPerProvider` 匹配可用模型 > 第一个可用模型。`defaultModelPerProvider` 为每个内置 Provider 指定默认模型 id（`model-resolver.ts:20-60`）。
- **模型作用域**：`--models`/`enabledModels` 模式经 `resolveModelScopeFromModels` 支持 glob 模式（`*sonnet*`、`provider/*:high`）与 `:thinkingLevel`（`model-resolver.ts:280-360`），结果用于 Ctrl+P 循环切换（`scopedModels`）。
- **别名/路由**：无本地语义路由。OpenRouter 通过请求体 `provider` 字段透传 `openRouterRouting`（allow_fallbacks、order、only、max_price、preferred_throughput 等，`types.ts:695-763`），Vercel AI Gateway 类似（`types.ts:769-773`）——路由策略由聚合服务执行，Pi 只负责拼参。

## 7. 多 Key、限流、重试与故障转移

- **多 Key**：无多 Key 池。每 Provider 一粒凭据；`setRuntimeApiKey`/`removeRuntimeApiKey`（`model-runtime.ts:528-547`）提供会话级临时 key（如 `--api-key`），优先级高于存储（`runtime-credentials.ts:24-28`）。未发现轮询、健康状态或冷却机制。
- **SDK 层重试**：`retryProviderRequest`（`ai/src/utils/provider-retry.ts:105-125`）镜像 OpenAI/Anthropic SDK 策略（`x-should-retry`、408/409/429/5xx），指数退避 0.5s 起、上限 8s、随机抖动，服务端 `retry-after` 超过 `maxRetryDelayMs`（默认 60s）立即失败；`maxRetries` 经 `settings.retry.provider.maxRetries` 配置（`settings-manager.ts:23-27, 839-843`）。
- **Assistant 消息层重试**：`retryAssistantCall`（`ai/src/utils/retry.ts:162-211`）对 stopReason=error 的消息按错误文本分类（`isRetryableAssistantError`，正则匹配 overloaded/rate limit/429/5xx/网络/websocket 关闭/流提前结束等；“exceeded request buffer limit while retrying upstream” 为可重试模式，`retry.ts:44`；quota/billing 类不可重试，`retry.ts:7-89`）。
- 退避与上限：指数退避 `baseDelayMs * 2^(n-1)`（默认 2000ms、最多 3 次，`settings-manager.ts:818-822`），abort 归一化为 aborted 消息。
- **会话级自动重试**：`agent-session.ts:2686-2737` 的 `_prepareRetry` 在同一预算内对最后一个 assistant 消息 `continue()` 重跑；compaction 摘要生成也用同一 `settings.retry`（`compaction/compaction.ts:557-580`）。
- **上下文溢出处理**：溢出不是重试分支：`_isRetryableError` 对 `isContextOverflow` 返回 false（`agent-session.ts:2647`），溢出走“压缩一次并自动重试一次”（实现在 `_checkCompaction` 的 overflow 分支 :1994-2021 与 `_runAutoCompaction("overflow", willRetry)` :2058+；无独立 `_handleOverflowRecovery` 函数）。
- **跨 Provider failover**：本次未找到。Provider 选择在会话/模型层面完成，请求失败只在同一 Provider/模型内重试；无模型 fallback 链、无 Key 轮换。

## 8. 连接检测、日志与可观测性

- **连接检测**：`Models.checkAuth`（`models.ts:485-520`）只检查凭据完整性（存储/环境/命令源），不发真实请求；`models.json` 内嵌 key 的检查只确认环境变量引用存在（provider-composer.ts:329-331），命令值不执行也不验证（:326-327，与 types.ts:73-75 的 list 约束一致）。
- TUI 的 `/login` 登录流程中 OAuth 会真实换取 token，但无独立的“连接测试”入口。
- CLI `pi auth check`（`cli/auth-command.ts`、`cli/auth-check.ts`）：复用 `ModelRuntime.checkAuth` 检查 Provider 凭据就绪度（`ready/not_ready/invalid`，退出码 0/1/2），支持 `--json`/`--credentials`/`--no-refresh`，全程不发真实请求（`auth-check.ts:39-71`）。
- **可用性快照**：`ModelRuntime` 维护 `configuredProviders/storedProviders/auth/available` 快照（`model-runtime.ts:272-378`），凭据变化时按 Provider 增量刷新（`refreshProviderAvailability`），供模型选择器展示“已认证 Provider”列表。
- **用量与成本**：`Usage` 结构（`types.ts:367-388`）字段：

  ```text
  input / output / cacheRead / cacheWrite / reasoning / totalTokens / cost
  ```

  会话级 `usage-totals.ts` 汇总；footer 展示 token 与成本（`components/footer.ts`），`/session` 命令输出统计（`agent-session.ts:262-279`）。
- **诊断与日志**：失败消息带脱敏后的 `diagnostics` 数组（`types.ts:413-420`，`utils/diagnostics.ts` 的 `formatThrownValue`）；调试日志写入 `getDebugLogPath()`（定义 config.ts:564，使用 interactive-mode.ts:6196）。TUI 对 retry 事件、cache miss 提示（`cache-stats.ts`）有可见反馈。遥测包 `packages/telemetry` 提供 vendor-neutral 合约，但本次未逐层追到请求路径。

## 9. 设计取舍与已确认边界

- **Provider 单例与组合式覆盖**：用“一个 Provider 对象 + 多层覆盖”替代“用户可创建多实例”的渠道模型，简化了状态管理，代价是同一服务多账号需要手工合并到 auth.json 单 key 或依赖 Radius 网关多实例。
- **模型目录去中心化**：内置目录 gitignore 且构建期生成，运行时以 pi.dev 远端目录增量覆盖，用户可 models.json 全量自定义——这使离线/CI 需要 `build:offline` 与 `PI_OFFLINE`（`model-runtime.ts:194`）语义配合，也意味着静态代码中看不到完整模型清单。
- **凭据未加密**：auth.json 0600 + 文件锁，无静态加密；models.json 内嵌 key 是明文文件的一部分，属于已确认的设计（官方文档以“配置文件属于用户自己”为前提）。
- **无跨渠道高可用**：重试闭环在同一 Provider/模型内；OpenRouter/Vercel Gateway 的上游路由是外部能力，不作为本地 failover。
- **平台边界**：`packages/ai` 可运行于 Node/Bun；browser 构建通过 `importNodeModule` 动态引用与 `env-api-keys.ts` 的惰性加载保持可用（`auth/context.ts:11-18`），但本地文件凭据、ambient AWS/ADC 依赖 node 运行时。

## 10. 未验证事项

- 未运行真实请求，`checkAuth` 与真实链路的一致性未实测。
- `data/*.json` 构建期生成，本次未检查生成后的实际模型数与价格数据。
- 代理（`httpProxy`）注入后的各 SDK 消费路径未逐层追完。
- OAuth 各 Provider 流程（device-code/PKCE/回调）仅在 `auth/oauth/` 静态阅读，未运行。
- 遥测包在请求路径的具体埋点未逐层核对。

## 11. 关键源码索引

- `packages/ai/src/types.ts:35-75`：KnownProvider 枚举；`types.ts:794-813`：Model 元数据；`types.ts:695-769`：OpenRouter/Vercel 路由参数
- `packages/ai/src/models.ts:97-149`：Provider 接口；`models.ts:386-446`：refresh 生命周期；`models.ts:762-862`：createProvider 组合
- `packages/ai/src/auth/resolve.ts:50-110`：凭据解析优先级；`auth/credential-store.ts`：内存 CredentialStore
- `packages/ai/src/providers/all.ts:89-121`：内置 Provider 构造；`providers/radius.ts:20-34`：Radius 工厂
- `packages/coding-agent/src/core/model-runtime.ts:172-213`：ModelRuntime.create；`model-runtime.ts:219-230`：Radius 配置；`model-runtime.ts:462`：isUsingSubscription
- `packages/coding-agent/src/core/provider-composer.ts:420-520`：三层组合；`model-config.ts:193-209`：models.json schema
- `packages/coding-agent/src/core/auth-storage.ts:47-202`：auth.json 文件锁存储；`runtime-credentials.ts`：运行时 key
- `packages/coding-agent/src/core/remote-catalog-provider.ts:45-131`：pi.dev 目录叠加
- `packages/coding-agent/src/core/model-resolver.ts:620-700`：初始模型选择
- `packages/ai/src/utils/retry.ts:162-211`：消息层重试；`utils/provider-retry.ts:105-125`：SDK 层重试
