# OpenClaw LLM 渠道管理调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态源码阅读。实际覆盖 `src/agents/sessions/`（ModelRegistry 与 auth store）、`src/agents/model-auth-*`（凭据解析链）、`src/agents/provider-stream.ts` 与 `src/plugins/provider-runtime*`（provider 运行时）、`src/agents/embedded-agent-runner/`（模型解析与流执行主链）、`src/model-catalog/`（远端目录）、`src/agents/plugin-model-catalog.ts` 与 `src/agents/prepared-model-catalog*` 周边（目录持久化）、`packages/ai/` 与 `packages/llm-core/`（协议 adapter 注册与请求契约）、`src/commands/models/`（CLI）、`src/gateway/server-methods/models-probe.ts`（连接探测）、`docs/concepts/{models,model-providers,model-failover}.md` 与 `docs/auth-credential-semantics.md`。全程静态阅读，未运行构建、测试、CLI 或 Gateway。
>
> 调查范围：渠道实体与 Endpoint 数据模型、模型目录与能力元数据、凭据/Header/代理边界、协议 Adapter 与请求组装、会话模型引用到具体渠道实例的解析主链、多 Key/重试/故障转移、连接检测与可观测性、CLI/UI 配置管理入口、平台边界；覆盖一个完整主链并给出相对源码定位。不包含产品结构与设计基因类，不包含会话历史/系统提示词组装等相邻类目内容。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的“渠道管理”是三层结构的合成体，三层各自独立演进：

- **逻辑 Provider**：模型引用与凭据路由的品牌身份（`anthropic`、`openai`、`ollama`、自定义代理名等），只出现在模型引用 `provider/model`、provider 配置与 auth profile 归属中。
- **协议与 Adapter**：按 `model.api`（协议家族标识，如 `openai-responses`、`anthropic-messages`）注册在进程内流式适配器注册表中的执行实现。
- **模型目录与凭据**：运行时 `ModelRegistry` 实例把“有哪些模型、谁给它们发凭据”组织成一个可查询、可复制的目录快照，是会话级解析的单一来源。

代码快照中的核心结论：

- Provider 目录事实分三层来源：author-owned 的 agent 目录 `models.json`、provider 插件 manifest 生成的 catalog（存 agent SQLite `cache_entries`，scope `plugin-model-catalog-v1`）、以及运行时插件 `registerProvider(...)` 的动态注入；目录加载与合并见 `src/agents/sessions/model-registry.ts:459-725`。
- 协议执行实现集中在 `packages/ai`：`createApiRegistry()` 按 `api` id 维护适配器映射，`register-builtins.ts` 懒加载注册 openai/anthropic/google/mistral/azure 等协议族；自定义 Provider 可用插件注册自己的 stream 实现（`src/agents/sessions/model-registry.ts:990-1012`）。
- 凭据进入请求的路径统一为 `ResolvedRequestAuth`（apiKey + headers）；由模型目录持 key 或经 auth profile 解析，最终注入 stream 的 `options.apiKey`/`options.headers`，链路见 `src/agents/embedded-agent-runner/stream-resolution.ts:274-324`。
- 故障处理在同一 provider 内先做 auth profile 轮换（带 cooldown/disabled 状态、round-robin、会话 stickiness），profile 耗尽后再走模型 fallback 到 `agents.defaults.model.fallbacks`；仅当全链都是超载类错误时整链至多重试 10 次。多把 env API key 的旋转只对限流错误触发，见 `src/agents/api-key-rotation.ts:50-112`。
- 连接检测复用 CLI 的 auth-probe 引擎并做成 Gateway 的 `models.probe` RPC（Control UI“Test connection”），会发起真实的最小模型请求，见 `src/gateway/server-methods/models-probe.ts:136-199` 与 `src/commands/models/list.probe.ts`。
- 模型元数据可被“hosted catalog”增量刷新：默认 URL `https://catalog.openclaw.ai/models/v1/catalog.json`（源仓库 `openclaw/catalog`，不在本仓库内），TTL 6 小时，见 `src/model-catalog/remote-config.ts:3-11` 与 `src/model-catalog/remote-refresh.ts:22`。本地仓库中不存在 `catalog.json` 生成文件本身，只有生成/消费它的代码。

## 系统边界与总体调用链

OpenClaw 以本地 Gateway 为控制平面，模型提供商的 HTTP 调用从 Gateway 主进程或本地模型服务发起；浏览器、桌面与 CLI 都只通过 Gateway 的 RPC/CLI 接口间接触发，浏览器端不与 provider 直连。真正执行模型请求的是运行在同一机器上的 agent 运行器：一次用户回合进入嵌入运行器后，模型解析、凭据准备与流执行都在运行器内部完成，文件位置见下方主链。

一次请求“配置/凭据 -> 模型解析 -> 请求组装”的完整主链（实现事实，行号以快照为准）：

```text
模型引用 provider/model（会话选择或 agents.defaults.model.primary/fallbacks）
  -> resolveEmbeddedRunModelSetup: hooks 改选 + harness 选择 + resolveTieredModel
     （embedded-agent-runner/model-setup.ts:18-148）
  -> resolveModelAsync / prepared snapshot stores
     （embedded-agent-runner/model.ts:113-272；ModelRegistry + AuthStorage 来自
       prepared-model-runtime 快照或 agent 目录加载）
  -> prepareEmbeddedRunAuthPlan：为 provider 选出 auth profile 计划并解析出 apiKey
     （run/auth-plan.ts；src/agents/model-auth-provider.ts:89-500 实现优先级链）
  -> session.agent.streamFn 组装：provider stream（插件或 transport fallback）包上
     apiKey/headers/run signal 注入层
     （run/attempt-stream-settle.ts:475-612；stream-resolution.ts:146-325）
  -> LlmRuntime.stream -> registry 按 model.api 取 adapter
     （packages/ai/src/stream.ts:15-57；src/llm/stream.ts:75-115）
  -> 协议 transport 把 model.baseUrl + options.apiKey/headers + 消息上下文组装为
     provider HTTP 请求（packages/ai 的 transports/* 与 providers/*）
```

解析出来的 `Model` 对象是可序列化的数据（id/name/api/provider/baseUrl/cost/contextWindow/compat/params/headers），进程生命周期信息（所属 `LlmRuntime`）通过不可枚举属性绑定在对象上而不进入序列化形状（`src/llm/model-runtime-binding.ts:11-23`）。会话进程内保存“运行时生命周期属主”，重启后由准备快照重建。

## 1. Provider、渠道与 Endpoint 数据模型

### 术语与实体粒度

- Provider 是字符串标识与配置命名空间，不是进程级对象。它出现在模型行的 `provider` 字段、`models.providers.<id>` 配置块与 auth profile 的 `provider:` 前缀中；provider 也是插件 ownership 的单位（官方 provider 由 `extensions/<id>` 插件声明）。
- 同一个 Provider 名可以承载多个模型与多个凭据 profile（API key、OAuth、token），但目录中的“Endpoint 粒度”是 `provider + model.id + baseUrl`：`baseUrl` 可以写在 provider 级或 model 级（`src/agents/sessions/model-registry.ts:687-690`）。没有面向用户的“Endpoint 实例”实体，也没有多实例 Endpoint 表。
- 跨厂商聚合入口（OpenRouter、ClawRouter、vLLM、LM Studio、自建代理等）在 OpenClaw 里就是普通 Provider：要么作为官方插件带自己的目录（docs/concepts/model-providers.md 中列出的官方 provider 插件表），要么由用户在 `models.providers` 里手写 baseUrl+apiKey+models。两种形态最终落到同一个模型目录。

### 模型运行数据契约

文本模型的统一契约在 `packages/llm-core/src/types.ts`：

- `KnownApi` 枚举协议家族：`openai-completions`、`mistral-conversations`、`openai-responses`、`azure-openai-responses`、`openai-chatgpt-responses`、`anthropic-messages`、`bedrock-converse-stream`、`google-generative-ai`、`google-vertex`；`Api` 允许自定义字符串（`packages/llm-core/src/types.ts:6-19`）。
- `Model` 是带 `id`、`name`、`api`、`provider`、`baseUrl`、`reasoning`、`input`、`cost`（每百万 token 单价）、`contextWindow`、`maxTokens`、可选 `params/headers/authHeader/compat/mediaInput` 的扁平对象（`packages/llm-core/src/types.ts:657-707`）。
- `compat` 字段按 api 类型承载协议级兼容开关（如 OpenAI Completions 的 `supportsDeveloperRole`、`thinkingFormat`、OpenRouter/vercel gateway 的路由偏好；Anthropic 的 beta header 控制；类型见同文件 477-567 与 `src/config/types.models.ts:29-112`）。

配置侧 schema 与运行契约同构但字段可选（`src/config/types.models.ts:152-289`）：provider 级与 model 级都可给 `api/baseUrl/headers/params/compat`，`apiKey` 与 `headers` 使用 `SecretInput`（支持 env/文件/exec/store 引用，见下节）；另有 provider 级 `auth` 模式（`api-key`/`aws-sdk`/`oauth`/`token`）、`timeoutSeconds`、`request`（代理/TLS/认证 override）与 `localService`（本地模型服务进程管理）。

### Provider 插件与 setup 元数据

Provider 插件通过 `openclaw.plugin.json` 声明 `providers`、`providerUsageAuthEnvVars`、`providerCatalogEntry` 与 `modelCatalog`（manifest 内置目录，如 `extensions/anthropic/openclaw.plugin.json:21-28` 声明 provider `anthropic` 并内置 `claude-*` 模型目录）。这给核心层提供了不加载插件运行时也能读的静态元数据。尚未安装的官方 provider 由进程内只读索引 `OPENCLAW_PROVIDER_INDEX` 提供预览目录（`src/model-catalog/provider-index/openclaw-provider-index.ts:14-...`），注释明确“installed plugin manifests remain authoritative; this index is a fallback”。

## 2. 模型目录与能力元数据

### 目录来源与合并

运行时 `ModelRegistry`（`src/agents/sessions/model-registry.ts:321` 起的类）把模型合并为内存数组，来源有三：

1. author-owned 的根 `models.json`：默认路径 `join(agentDir, "models.json")`（`model-registry.ts:404-410`），手写、验证 schema、缺失字段用默认值补全（`parseModels` 给 `reasoning:false/input:["text"]/contextWindow:128000/maxTokens:16384/cost:0`，`model-registry.ts:672-725`）。
2. provider 插件生成的 catalog shard：读取 agent SQLite `cache_entries` 中 scope `plugin-model-catalog-v1` 的行（`src/agents/plugin-model-catalog.ts:30-32,63-85,624-660`），每个 shard 按 `requireGeneratedCatalog` 校验并只保留本插件声明的 provider 行（`model-registry.ts:496-517`）。
3. 动态注册：agent session extensions 的 SDK `api.registerProvider(name, config)`（`src/agents/sessions/extensions/types.ts:1377-1428`、`runner.ts:331-360`）与 `ModelRegistry.registerProvider`（`model-registry.ts:929-1052`），可携带 baseUrl/models/streamSimple/oauth/headers，是“会话内自定义 provider”的入口。

合并顺序是 custom models 在前、插件 catalog 追加在后；`models.mode: "replace"` 影响配置层行为（docs/concepts/models.md），目录层始终是上述来源之和。OAuth provider 还可以在合并后改写模型行（如更新 baseUrl，`model-registry.ts:485-491`）。

### 模型元数据怎么算“有凭据可用”

目录行本身不含 key。`getAvailable()` 用轻量判断过滤“配置了凭据”的模型：auth store 有该 provider 凭据，或 provider 配置声明 `aws-sdk`，或 provider 级 apiKey 已配置（`model-registry.ts:738-758`）。更细的 auth 状态（env/command/profile 来源分类）由 `getProviderAuthStatus` 给出（`model-registry.ts:857-882`）。

### 远端 hosted catalog 与本地生成

- `models.providers.<id>` 之外的官方模型元数据默认来自插件 manifest 内置目录；可被远端 catalog 增量覆盖（只允许更新/新增已安装 provider 的模型，不提供 baseUrl 与 headers，忽略比本地 build stamp 旧的 bundle——行为见 `docs/concepts/models.md` 的“Hosted catalog updates”小节）。
- 远端刷新代码路径：`src/model-catalog/remote-refresh.ts`（TTL `6*60*60_000` ms、启动/刷新入口与“fresh/unchanged/updated”结果）、`remote-store.ts`（SQLite 读写与跨进程写锁）、`remote-overlay.ts`（把远端行投影成目录 override）。远端默认地址在 `remote-config.ts:3-11`。
- 本地不存在 `catalog.json`：任务背景提到的 `openclaw/catalog/models/v1/catalog.json` 属于仓库外组织仓库（公开 GitHub `openclaw/catalog`，发布到 `catalog.openclaw.ai`），本地只有拉取与消费逻辑；本仓库内名为 `catalog.json` 的是插件模型目录的“迁移前文件名”常量（`src/agents/plugin-model-catalog.ts:30`），二者不是同一文件。

### 能力元数据的更新纪律

由于目录会进 SQLite 缓存与 UI 快照，仓库 AGENTS.md 规定 provider 模型变更后须等待 `openclaw/catalog` 的 catalog.json 刷新并派发 catalog 发布工作流——这解释了为什么“改 manifest 模型”不等于“立刻全局生效”：Gateway/插件元数据是进程稳定快照，热路径不做 freshness-poll（仓库根 AGENTS.md“Hot paths”条）。

## 3. 凭据、Header 与代理边界

### 凭据形态与存储

OpenClaw 模型凭据分两大类：

- **auth profiles**（`api_key` / `token` / `oauth` 三类，见 `docs/auth-credential-semantics.md`）：存在 SQLite auth store（每 agent 一份，`agents/<agentId>/agent/openclaw-agent.sqlite`；共享 read-through base 在 `state/openclaw.sqlite`，doctor 一次性迁移旧文件）。配置文件里的 `auth.profiles` / `auth.order` 只是“metadata + routing”，不含密钥，OAuth/refresh 例外语义见该文档。存储函数族在 `src/agents/auth-profiles/sqlite.ts`。
- **模型行内凭据**：`models.providers.<id>.apiKey` 与 `headers` 是 `SecretInput`（配置层写法如 `${ENV_VAR}` 或 SecretRef 语法）。落入 agent 目录 `models.json` 的值在解析时先被当成 env 变量名查询，查询不到才按字面量使用；以 `!` 开头的值按命令执行取输出（`src/agents/sessions/resolve-config-value.ts` 的 `resolveConfigValue`）。SecretRef 管理的 apiKey 会在 models.json 里写回 marker（如 `secretref-managed`、env 引用写 env 变量名）而不是解析后的明文（docs/concepts/models.md“Merge mode precedence”）。

### 进入请求的凭据解析优先级

单次 provider 请求的最终凭据由 `resolveApiKeyForProviderCore`（`src/agents/model-auth-provider.ts:89-500`）决定，顺序可概括为：

1. 显式 pin 的 auth profile（会话/user 指定，`model-auth-provider.ts:134-210`）；
2. 配置 `auth.order` / `auth.profiles` 给出的 provider 顺序（`resolveAuthProfileOrder`）；
3. `aws-sdk` 模式或 `auth.profiles` 的 `aws-sdk` 路由标记直接走 SDK 链；
4. env-first 时读 `env:<PROVIDER>_*`（`env-first` 优先级参数可被调用方切换，见 241-288）；
5. provider 配置内联 key（含 env/exec SecretRef 解析、profile 引用解析），随后是“非密钥 marker”的分支，最后回到 auth store 按 order 逐个 profile 尝试并做 OAuth 刷新与 sentinel 处理（397-482）。

返回的 `ResolvedProviderAuth` 携带 `apiKey`、`profileId`、`source`、`mode`（用于与模型 `api` 的兼容性校验 `isAuthModeAllowedForModel`）。

### Header 与代理

`ModelRegistry.getApiKeyAndHeaders` 把三层 header 合并进请求：model 行、provider 级 headers、按 `provider:model` 存的 model headers，合并顺序为后两层覆盖前层；若 provider 配置 `authHeader: true` 则追加 `Authorization: Bearer <key>`（`model-registry.ts:819-844`）。在网关侧更完整的 provider auth（profile/oauth 解析后的 apiKey+profileId）由 `models.providers.<id>.auth` 与 `request.auth`（`authorization-bearer`/`header` 模式、`request.proxy` env/显式代理、`request.tls` 客户端证书）支撑，类型见 `src/config/types.provider-request.ts`。

### 脱敏边界

- probe/状态路径把错误中的凭据材料做脱敏投影（如 `redactAuthProbeError`、错误桶只保留 reasonCode）；auth 错误分类成 auth/billing/rate_limit/timeout 等 bucket 而不透出原始密钥。
- 敏感 env 名集合被用于日志与导出脱敏；工作区 dotenv 禁止注入 provider key 类变量（`src/infra/dotenv.ts:101-169` 的 blocklist，其中含 `OPENAI_API_KEYS`、`OPENCLAW_LIVE_*_KEY` 等），这类变量只接受 shell/启动环境。
- SecretRef 只允许静态凭据；`oauth` profile 不接受 SecretRef，OAuth 是可刷新/轮换的运行时可变状态（docs/auth-credential-semantics.md“OAuth SecretRef Policy Guard”）。本次未逐条验证各 UI 页面脱敏展示，仅有 probe RPC 处理程序与 redaction 工具可见。

### 注意：models.json 中的 marker 与真实解析时机

models.json 持久化的 `apiKey` 很多是“来源 marker”（env 变量名或 `secretref-managed`），真实值在请求时由运行链解析（docs 明示 marker persistence 是 source-authoritative）。因此直接读 `models.json` 看不到明文 key。

## 4. Adapter、协议与请求组装

### Adapter 注册表

协议执行实现位于 `packages/ai`：

- `createApiRegistry()` 返回进程级 registry：`registerApiProvider({api, stream, streamSimple}, sourceId)` 按 api id 存储一对流式入口，`unregisterApiProviders(sourceId)` 支持按插件属主整体卸载（`packages/ai/src/api-registry.ts:76-119`）。
- `createLlmRuntime(registry)` 暴露 `stream/complete/streamSimple/completeSimple`，它们把 `model.api` 查表后委托给 adapter（`packages/ai/src/stream.ts:15-57`）。adapter 契约要求失败编码进返回的流（error 消息带 stopReason/errorMessage），而非抛异常（`packages/llm-core/src/types.ts:204-219` 的注释契约）。
- 内置注册在 `src/llm/stream.ts:20` 调用 `registerBuiltInApiProviders`，`register-builtins.ts:94-158` 列出八组（anthropic-messages、openai-completions、openai-responses、openai-chatgpt-responses、azure-openai-responses、google-generative-ai、google-vertex、mistral-conversations），全部懒加载（首用动态 import）。
- 进程默认有一个惰性全局 runtime（`packages/ai/src/internal/default-runtime.ts`），但会话/嵌入运行器通常使用按 model-registry 生命周期创建的隔离 runtime（`src/agents/sessions/model-registry-runtime.ts:24-40`），并把该 runtime 通过不可枚举绑定挂在 model 上（`src/llm/model-runtime-binding.ts`），`stream` facade 解析时优先取绑定的 runtime 否则回落默认（`src/llm/stream.ts:75-77`）。

### 插件如何贡献执行实现

运行时会话的 provider stream 由 `registerProviderStreamForModel` 构造（`src/agents/provider-stream.ts:22-78`）：先问 provider 运行时插件（`src/plugins/provider-runtime.ts` 的 `resolveProviderStreamFn`），没有插件实现时用 `createTransportAwareStreamFnForModel` 生成传输层 fallback；然后把自定义 api 注册进所在 apiRegistry（`ensureCustomApiRegistered`）。在自定义 provider 案例中，agent session extensions SDK 的 `registerProvider(..., {streamSimple})` 直接注册该 provider 自己的流实现（`model-registry.ts:1001-1012`），模型选择无需知道 stream 是内置还是插件提供。

### 请求组装边界

组装分两层：

- `Context`（systemPrompt/messages/tools）来自上层会话（本类别之外的“任务如何构建”，见相邻类目边界）；渠道层只负责把 context + model + options 映射成上游请求。
- options 携带 apiKey/headers/`onPayload`（发送前改写上游 body 的钩子）/`onResponse`/transport/`cacheRetention`/`sessionId`/`promptCacheKey`/timeout/重试参数等（`packages/llm-core/src/types.ts:68-152`）。内置 provider 模块负责各自协议头与 body 细节，例如 Anthropic adapter 依据 provider 身份决定 `x-api-key`/`anthropic-version`、beta header 与 OAuth bearer（`packages/ai/src/providers/anthropic.ts`），OpenAI 家族区分 native `api.openai.com` 与代理路由的载荷整形（docs/concepts/model-providers.md 的 proxy-route shaping）。baseUrl 拼接与 debug 脱敏集中在 transports 的 URL 工具中。非 native 的 openai-completions 代理强制关闭 `developer` role 以避免 400（docs 描述 + config 层把该开关放在 compat 中）。

## 5. 运行时选择、绑定与会话路由

### 选择源与严格性

模型选择源分为 configured default（`agents.defaults.model.primary`+`fallbacks`）、per-agent primary、cron 任务 payload 与用户会话 pin（`modelOverrideSource: "user"`）。用户 pin 是严格选择：失败时报错而不是落入别的 fallback；configured/cron 主选允许 fallback 链（docs/concepts/models.md“Selection source and fallback strictness”，代码入口如 `src/agents/model-selection-resolve.ts` 的 `resolveConfiguredModelFallbacks` 与 `resolveAllowedModelRefCore`）。模型 ref 解析以第一个 `/` 切分并小写化（docs/concepts/models.md）。

### 会话 pin 的持久化与运行期绑定

会话 pin 持久化在会话/偏好层（docs 说 `/model`、picker、`session_status(model=...)` 写入 `modelOverrideSource:"user"` 的 pin；自动 fallback 记 `"auto"` 并周期性 re-probe 原主选、恢复后清除）。本次未逐行核对 pin 存储表的写路径（属于会话与消息管理类目），只确认解析层在运行器内按会话取选择并交给模型解析。运行期绑定结果表现为 attempt 携带的 `provider/modelId/effectiveModel/resolvedApiKey/authProfileId`，由 `prepareEmbeddedRunRuntime`（`run/runtime-preparation.ts:46-195`）汇总，经 `prepareAndDispatchEmbeddedRunAttempt`（`run/attempt-dispatch-preparation.ts:148-275`）交给运行器。

### Provider 内 auth profile 轮换与顺序

同 provider 多 profile 时，模型失败后的“重试同一 provider 的下一 profile”由 auth 运行层决定：顺序解析函数 `resolveAuthProfileOrder`（配置顺序 > 存储顺序，缺省 round-robin：类型 OAuth > token > api_key，同 tier 内 lastUsed 旧的优先，cooldown/disabled 排后），文档见 `docs/concepts/model-failover.md`；会话对自动选中的 profile 有 stickiness（避免每请求换 key 破坏缓存）。一个 provider/model 还能走不同 agent runtime（OpenAI 的 Codex harness 与 OpenClaw 内置 runtime 分开选择），这是运行时选择而非凭据选择，超出本笔记深挖范围，仅在边界处注明。

### “解析到具体渠道实例”的含义

OpenClaw 没有持久化的“渠道实例”对象；“引用解析”的终点是 (1) 目录中确定的 `Model` 行（决定 baseUrl/api/协议兼容），(2) 该行可用的 auth 方案（决定 apiKey/headers/profile），(3) 绑定该 api 的 stream adapter（内置或插件），(4) 会话绑定的 LlmRuntime。这四者即“真实连接”的全部前置条件，运行期重建成本低，无实例缓存需管理。

## 6. 多 Key、限流、重试与故障转移

OpenClaw 把“同一模型失败”的恢复拆成四个互不混淆的层次：

1. 同 key 瞬时重试（transient retry）；
2. 多把 env key 在限流时轮换；
3. auth profile 轮换（每个 profile 一个 cooldown/disabled 状态）；
4. 模型级 fallback（进入 `fallbacks` 链）。

### 多 Key（env 集合）

多 key 的候选集来自环境变量，收集顺序（`src/agents/live-auth-keys.ts:112-167`）：`OPENCLAW_LIVE_<P>_KEY` 单 key 钉住（测试/复现时禁旋转）> `<P>_API_KEYS`（逗号/分号/空白分隔，`parseKeyList`）> `<P>_API_KEY` > `<P>_API_KEY_*` 前缀枚举 > 回退变量（如 Google 的 `GOOGLE_API_KEY`）> provider manifest 声明 env 名；对 `anthropic/google/openai` 有显式表（同文件 33-58）。候选解析后 `normalizeUniqueStringEntries` 去重。

旋转执行器 `executeWithApiKeyRotation`（`src/agents/api-key-rotation.ts:50-112`）：外层遍历 key、内层做同 key 瞬时重试；`shouldRetry` 命中（默认 429/rate_limit 类错误，经 `classifyFailoverSignal`）就换下一把 key 并跳过同 key 重试；非限流错误失败即止。该执行器通过插件 SDK 的 `resolveApiKeyForProvider`/`getRuntimeAuthForModel`（`src/plugin-sdk/provider-auth-runtime.ts:297-319`）暴露给 provider 插件，也在 media-understanding 运行器使用；本次未验证它是否覆盖所有内置 transport 的 SDK 内重试路径。

### 瞬时重试

瞬时重试规则集中在 `src/provider-runtime/operation-retry.ts`：分类网络/超时/DNS 类错误与 5xx，提供每 key 内重试次数/延迟上限与“该 stage 是否重试”的判定（`shouldRetrySameKeyProviderOperation`、`executeProviderOperationWithRetry`）。SDK 内重试由各自 adapter 处理，OpenClaw 可设 `OPENCLAW_SDK_RETRY_MAX_WAIT_SECONDS` 限制 SDK 对 `Retry-After` 的等待上限（docs/model-failover）。本次未验证 SDK 级默认重试数与整体运行超时如何在 attempt 层综合。

### Auth profile 冷却与故障分类

profile 冷却状态（`cooldownUntil`/`disabledUntil`/`usageStats.errorCount`）存 SQLite auth state；时长随失败次数增长（30s/1m/5m 上限），billing/permanent-auth 走 disabled 长退避；冷却与模型 fallback 的交互、每候选的决策表、以及“只有全链都是超载时才整链重试最多 10 次”的行为，见 `docs/concepts/model-failover.md`。错误分类将文本/HTTP 状态归一化成 failover reason（`rate_limit/overloaded/billing/auth/...`），实现位于 `src/agents/failover/`（`classify.ts` 等）。本笔记未逐行核对该分类器与 cooldown 计时器、未验证运行时持久化的精确列。

### 模型 fallback

fallback 链构建与执行在 `src/agents/model-fallback-*`（candidates/cooldown/observation/runner）与 `session-model-fallback.ts`；fallback 是 turn-local 的，回复运行器只持久化“通知状态”（区分 selected 与 active model），不会把 fallback 写成下一轮的选择（docs/model-failover）。本次仅确认文件与行为契约，未逐行追踪 fallback runner 与 run 主循环的接线。

## 7. 连接检测与可观测性

### Probe（连接测试）

存在两套易混的“probe”：`src/gateway/probe.ts` 是探测 Gateway 进程自身可达/健康；模型提供商连接测试是另一条链——CLI 的 `models status --probe` 与 `models list --probe` 走 `src/commands/models/list.probe.ts` 的 `runAuthProbes`，Control UI 的“Test connection”经 Gateway RPC `models.probe` 复用同一引擎（`src/gateway/server-methods/models-probe.ts:1-18` 注释直述“reuses the CLI auth-probe engine behind an admin-scoped RPC”）。

Probe 会发起真实最小模型请求（RPC 侧约束 `PROBE_MAX_TOKENS=8`、并发 2、超时 5-60s），结果带状态桶与稳定 reasonCode（`ok/auth/rate_limit/billing/timeout/format/unknown/no_model`；`excluded_by_auth_order/missing_credential/expired/...`，语义见 `docs/auth-credential-semantics.md`）。凭据目标解析与真实运行共享同一套 auth 顺序逻辑，但 probe 不是完整 agent 运行（不会生成回复、不进会话记录）。每 provider 探测所有 eligible profile 并做汇总状态（`models-probe.ts:100-134`）。UI 侧调用由 `ui/src/pages/model-providers/` 页面与 i18n 文案（“Test connection”）佐证，本次未运行 UI。

### 用量与成本

`AssistantMessage.usage`（token 四类 + cost 明细与 `totalOrigin`）在协议层归一化并随每条 assistant 消息落会话与用量记录（`src/agents/usage.ts` 等）；成本单价来源是目录行 `cost`/pricing 元数据与远端定价刷新（`src/model-catalog/pricing.ts`）。per-attempt 失败信息与 `model_fallback_decision` 结构化日志、cooldown 摘要字段见 docs/model-failover 的可观测性小节。本次未验证用量面板与导出端到端。

### 请求日志与脱敏

子系统 logger（`src/logging/subsystem.ts`）把模型解析/auth/运行分开命名空间记录；错误与诊断经 provider-error 投影与各类 redaction（`redactAuthProbeError`、`formatModelTransportDebugUrl` 等）剥离凭据。prompt 与 body 的抓包调试在 `proxy-capture` 与 debug 工具目录中，本次未覆盖。

## 8. 配置生命周期、管理入口与持久化

### 文件与写模式

模型/Provider 配置事实落在两类位置：

- `openclaw.json`（合并后 schema 的 `models` 段：`mode`/`providers`/`catalogRefresh`）与 `agents.defaults.model*`（选择、aliases、policy）。
- 运行目录 `agents/<agentId>/agent/models.json`：手写 custom provider 的落点。由 models 命令/onboard/configure 生成或改写，并可被 config 的 `models.providers` 通过 merge 模式刷新（合并优先级见 docs/concepts/models.md）。

`models.mode: "merge"`（默认）时 custom providers 与 bundled catalog/插件目录共存；`"replace"` 时 picker/CLI 只列配置行。provider 插件生成目录写进 agent SQLite cache，不占用 models.json。

### 已确认的操作入口覆盖

| 入口 | 已确认能力 | 本次未验证 |
|---|---|---|
| 配置文件 | 查看合并结果（`openclaw models`/UI models.list）；`models.providers` 新增/编辑模型、baseUrl、headers、apiKey marker | UI/CLI 中“复制 provider”“导入/导出 provider 配置”入口未找到（本次仅按已读入口声明，不作项目级结论） |
| CLI | `openclaw onboard/configure`（auth 选择）；`models status/list/set/set-image/scan/aliases/fallbacks/auth/refresh` 子命令族在 `src/commands/models/*` 与 `src/cli/models-cli.ts` 均有实现 | `models auth order/list/add/login` 等子命令的参数语义仅看实现入口，未逐一跑通 |
| Control UI | Settings → Model Providers：增删/替换 provider apiKey（写 `models.providers.<id>.apiKey`）、显示来源不显示明文、Test connection（`models.probe`）、Default models 卡管理 primary/fallbacks/utilityModel（e2e 与 i18n 佐证） | 页面元素级操作覆盖未运行 UI；编辑后生效时机未在目标环境观察 |
| 桌面主进程 | 渲染器复用 Web 设置页并通过 sidecar 连本机 Gateway（仓库根文档表述） | 桌面端特有入口本次未在代码中逐项定位 |

### 启停与删除的粒度

provider 插件本身由 plugins 管理（enable/disable/卸载）；模型行没有“停用单个模型”的独立开关，目录里的 deprecated/disabled 元数据只影响 picker 展示与显式 `view:"all"` 浏览（docs/concepts/models.md），显式配置的模型不受影响。自定义 provider 的“删除”即从 models.json/配置移除条目；未找到面向模型的“复制”命令。

## 9. 设计取舍与已确认边界

- **目录可序列化、运行时进程稳定**：模型行是数据，LlmRuntime 是弱绑定；目录进 SQLite 缓存与 UI 快照，热路径不新鲜轮询，模型元数据更新要等 catalog 发布/重启。代价是“改了 manifest 模型立刻生效”不成立。
- **凭据与模型配置分层**：auth profile（含 OAuth、token 生命周期）由 auth store 管理；models.json 里只放来源 marker。运行时解析统一收敛在 `resolveApiKeyForProviderCore`，规避了分散取 key。
- **“支持多 Provider”不等于“无脑自动 failover”**：fallback 有严格的源语义（user pin 严格、configured 可回退），auth rotation 只在一个 provider 内进行、并有 cooldown/billing 禁用，避免静默换凭据。
- **Provider 名不是协议名**：同一 provider 可配不同 `api`（如 Anthropic-compatible 端点用 `anthropic-messages`），同一协议可被多个 provider 使用；注册键是 `api` 而非品牌，便于代理/自托管接入，但也意味着“API 兼容”能力要靠 `compat` 元数据逐开关声明。
- **本地模型服务被纳入 provider 配置**：`models.providers.<id>.localService`（command/healthUrl/空闲停）在配置层描述“由本进程启动并轮询就绪的本地推理进程”，实际消费方是 provider 插件（本次未跟踪插件内实现）；自托管 OpenAI 兼容端点需按来源显式信任（docs/concepts/model-providers.md 的 network opt-in），体现本地 vs hosted 的边界。
- **凭据相关“本次未找到”的条目**：在工作区/项目内导入导出 provider 配置的专用入口、把 API key 写进模型目录展示层的路径、桌面端独立 provider CRUD。这些只基于本次读过的入口声明不存在，不能作项目级绝对结论。

## 10. 平台边界

- **Gateway（本机进程）**：控制平面。持有配置、SQLite 状态、插件运行时、模型目录快照；模型探测 RPC 与 models.list/会话模型更新都在这层；Gateway 后台还会拉 hosted catalog。
- **agent 运行器（同一进程内执行）**：真实推理入口，负责模型选择、凭据计划、adapter/transport 组装与 retry/fallback。
- **本地模型服务**：通过 provider 插件（llama-cpp、ollama、lmstudio、vllm 等）接入；服务可以是受管启动的子进程，也可以连接用户已有服务；发现接口（如 `/v1/models`）用于目录扩充。
- **浏览器/桌面/CLI**：都不直接向模型 provider 发推理请求；CLI 与桌面复用 Gateway 能力，UI 仅展示/编辑（models.list/models.probe/config.patch 等 RPC）。desktop sidecar 承担“把本机 Gateway 桥接给渲染器”的职责。
- **worker inference**：Gateway 还内置面向非会话小任务的推理执行器（`src/gateway/worker-environments/inference-runtime.ts:523-639`），它复用同一套 prepared model/auth/stream 组装，说明模型解析逻辑在会话运行器与微任务推理间共享。

## 11. 未验证事项

- auth profile cooldown 计时、模型 fallback 决策表与 run 主循环的实际接线只对照文档与文件级证据，未逐行追踪 `model-fallback-*` 全部实现；未验证 cooldown/disable 状态在 SQLite 的具体写入点。
- hosted catalog 启动拉取与 6 小时 TTL 的调度方（谁在 Gateway 启动时触发 `refreshRemoteModelCatalog`）只确认常量与入口函数，未核对调用图；`openclaw models refresh` 的 CLI 路由同理。
- env 多 key 旋转执行器 `executeWithApiKeyRotation` 是否覆盖全部内置 transport 的正常聊天请求路径未验证（其在插件 SDK 与 media-understanding 中确认使用）；内置 transport 的 SDK 内重试计数未核对。
- UI 页面操作覆盖仅靠 e2e/i18n/RPC handler 佐证，未运行界面；desktop 端特有入口未在代码中逐项定位。
- 会话 pin（`modelOverrideSource`）与 auth profile pin 的持久化写路径未深入（属于会话与消息管理、对话请求类目边界）。
- probe 是否与聊天请求完全共享 transport/重试策略未逐行确认（代码注释表明复用 auth 顺序解析与真实模型请求，但 probe 请求体是独立小请求）。

## 关键源码索引

- `src/agents/sessions/model-registry.ts`：模型目录三来源合并、schema 校验、凭据/header 组装、动态 provider 注册（`registerProvider`/`applyProviderConfig`）。
- `src/agents/sessions/model-registry-runtime.ts`：每个 model-registry 生命周期一份隔离的 ApiRegistry + LlmRuntime。
- `packages/ai/src/api-registry.ts` 与 `packages/ai/src/providers/register-builtins.ts`：协议 adapter 注册表与内置协议族。
- `packages/llm-core/src/types.ts`：`Model`/`Api`/`Context`/`Usage`/stream 事件契约。
- `src/config/types.models.ts` 与 `src/config/types.provider-request.ts`：models.providers 配置形态与 provider 请求 override。
- `src/agents/model-auth-provider.ts`：单次 provider 请求的凭据解析优先级主链。
- `src/agents/model-auth-env.ts`、`src/agents/live-auth-keys.ts`、`src/agents/api-key-rotation.ts`：env key 发现与限流旋转。
- `src/agents/embedded-agent-runner/stream-resolution.ts`：把 apiKey/headers/authProfileId 注入 streamFn 的封装。
- `src/agents/provider-stream.ts`、`src/plugins/provider-runtime.ts`：provider 运行时插件 stream 解析与 transport fallback。
- `src/agents/embedded-agent-runner/model-setup.ts` 与 `model.ts`：attempt 的模型解析（resolveTieredModel/resolveModelAsync）。
- `src/agents/plugin-model-catalog.ts`：插件生成目录的 SQLite 缓存布局。
- `src/model-catalog/remote-*.ts`：远端目录刷新（TTL/存储/overlay）与默认 URL。
- `src/gateway/server-methods/models-probe.ts`、`src/commands/models/list.probe.ts`：连接探测 RPC/CLI 与复用引擎。
- `src/commands/models/*`、`ui/src/pages/model-providers/`：CLI 与 Control UI 管理入口。
