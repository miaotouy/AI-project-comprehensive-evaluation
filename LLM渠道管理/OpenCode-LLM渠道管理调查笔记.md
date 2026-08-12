# OpenCode LLM 渠道管理调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：只读源码静态梳理 Provider 组装、模型目录、凭据、协议适配与请求链路；未运行构建与真实请求
>
> 调查范围：Provider 实体与配置生命周期、凭据边界、模型目录、AI SDK/native 协议适配、运行时选择与路由、多 Key/重试/故障转移、可观测性、平台边界、OAuth 流程；不覆盖 opencode zen 控制台前端
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的 Provider 是「代码注册的模型目录 + 用户凭据/配置的运行时实例」的合成体：运行时按固定顺序组装 models.dev 目录、插件 hook、config `provider` 字段、环境变量、auth.json 凭据（`src/provider/provider.ts:1343-1668`），通过 AI SDK `streamText` 发起请求（`src/session/llm.ts:280-353`）。模型目录来自 `https://models.opencode.ai/api.json` 的拉取与缓存（`core/src/models-dev.ts`），无硬编码内置清单。协议适配以 AI SDK 包（BUNDLED_PROVIDERS 表 + npm 动态安装）为主路径，另有 opt-in 的 native 协议实现（`packages/llm/src/protocols/`）。

关键事实（快照 1f94d8a）：

- **Provider ID 11 个**：opencode/anthropic/openai/google/google-vertex/github-copilot/amazon-bedrock/azure/openrouter/mistral/gitlab（静态工厂 `schema/src/provider.ts:11-21`）。
- **同 provider 多 Endpoint 不支持**：config `provider` 为单对象，`options` 无数组形态；多端点需注册多个自定义 provider id。
- **凭据存 `~/.local/share/opencode/auth.json`（0o600 明文）**，不写 opencode.json；另 SQLite `credential` 表明文 JSON（core/src/credential/sql.ts:5-14）。**无加密、无系统 keyring、无 UI 打码**。
- **模型目录三级数据源**：磁盘缓存 → 构建期快照（OPENCODE_MODELS_DEV）→ 网络，TTL 5 分钟、每小时刷新、文件锁防并发（models-dev.ts:160-249）。
- **无多 Key 轮询、无跨 provider failover**；重试为会话级 `Effect.retry`（processor.ts:660-674，上限 5 次、指数退避带 0.25 抖动，retry.ts:28-31、76-81、192）+ SDK 级 `maxRetries` + native 级指数退避三处。
- **无登录后连接测试请求**：登录流程直接写凭据结束（cli/cmd/providers.ts:480-485）。
- **错误归一化**：`parseAPICallError`/`parseStreamError`（provider/error.ts:102-186）识别 context_length_exceeded/insufficient_quota 等，映射为 `ContextOverflowError`/`APIError`（message-v2.ts:603-719）。
- **浏览器不直连 provider**：OAuth 授权由 server 端插件发起，浏览器只显示授权 URL 并等待（provider/auth.ts:163-186）。
- **prompt caching**：Anthropic/Bedrock 家族自动 `cacheControl: ephemeral`（provider/transform.ts:357-406）。

## 总体调用链

```text
运行时组装（provider.ts:1343-1668）：
  models.dev 目录 → 插件 provider hook → config.provider 覆盖 → env key 探测
  → auth.json API key → 插件 auth loader → 内置 custom(dep) 适配器 → 重放 config
→ getModel/getLanguage（provider.ts:1811-1864）：parseModel → 校验存在性 → resolveSDK
→ streamText（session/llm.ts:318）→ fullStream → LLMEvent（llm/ai-sdk.ts）
→ usage/cost 落库（session/session.ts:338-407 → session 表 cost/tokens_*）
```

## 1. Provider、渠道与 Endpoint 数据模型

- `ProviderV2.ID` 为 branded string + 静态工厂（schema/src/provider.ts:8-23）；`ProviderV2.Info`：`id/integrationID/name/disabled/api(AISDK|Native)/request(headers+body)`（:52-72）。
- 运行时 `Provider.Model` schema（provider.ts:1036-1051）含 `cost`（带 tiers）、`experimentalOver200K`、`status` 等；媒体能力收敛为 `capabilities.input/output` 布尔（:991-999），无顶层 `modalities` 字段——`modalities` 数组形态只存在于 models.dev 元数据（`ModelsDev.Model`，models-dev.ts:67-121、:92-97）。
- **多 Endpoint**：`ConfigProviderV1.Info` 是单对象（core/src/v1/config/provider.ts:82-126），`options` 为 `Record<string, unknown>`，**无 options 数组/多端点支持**（源码确认）。唯一的动态多实例是 GitLab `discoverModels`（provider.ts:661-726，按账号发现模型）。

## 2. 配置创建、持久化与迁移

- **schema**（opencode.json 的 `provider` 字段，v1/config/config.ts:110-112）：`ConfigProviderV1.Info`：`api/name/env/id/npm/whitelist/blacklist/options(apiKey/baseURL/enterpriseUrl/setCacheKey/timeout/headerTimeout/chunkTimeout + 任意扩展)/models`；`ConfigProviderV1.Model`：`id/name/family/release_date/attachment/reasoning/temperature/tool_call/interleaved/cost/limit/modalities/experimental/status/provider{npm,api}/options/headers/variants`（v1/config/provider.ts:13-126）。
- **合并顺序**（config/config.ts:314-596）：远程 well-known → 全局（config.json→opencode.json→opencode.jsonc 深度合并，:246-279，legacy TOML 迁移 :262-276）→ `OPENCODE_CONFIG` → 项目 opencode.json → `.opencode/` 目录 → `OPENCODE_CONFIG_CONTENT` → opencode zen 账户/org 远程配置 → 企业托管。
- **provider 合并细节**：config 项合并进 models.dev 目录（provider.ts:1424-1520），`apiNpm` 优先级 `model.provider.npm > provider.npm > existing > modelsDev > "@ai-sdk/openai-compatible"`（:1439-1444）。
- **登录不写 opencode.json**：只写 auth.json（cli/cmd/providers.ts:480-485）。

## 3. 凭据、Header 与代理边界

- **存储**：`~/.local/share/opencode/auth.json`（core/src/global.ts:11；src/auth/index.ts:10），`set/remove` 以 0o600 权限写**明文 JSON**（auth/index.ts:73-89）；`OPENCODE_AUTH_CONTENT` 可整体覆盖。三种类型：`Oauth`（refresh/access/expires/accountId/enterpriseUrl，:14-21）、`Api`（key+metadata，:23-27）、`WellKnown`（key+token，:29-33）。
- **env 边界**：config `env` 字段只声明「从哪些环境变量探测 key」（v1/config/provider.ts:85），探测在 provider.ts:1523-1533；key 不写入 opencode.json。
- **credential 服务（V2）**：SQLite `credential` 表 `value` 明文 JSON（core/src/credential/sql.ts:5-14），`create` 先删同 integration 旧记录（credential.ts:101-118）。
- **key 进入请求**：AI SDK 路径 `options["apiKey"] = provider.key`（provider.ts:1720），SDK factory 构造时带入（:1773-1799），各 SDK 自行放 `Authorization: Bearer`/`x-api-key`；native 路径 `Auth.bearer(apiKey)` 配置在 route（llm/route/auth.ts）；插件 fetch 覆盖：github-copilot `auth.loader` 替换整个 fetch 注入 `Authorization: Bearer ${info.refresh}`（plugin/github-copilot/copilot.ts:96-180）。
- **脱敏**：native 错误路径系统脱敏（packages/llm/src/route/executor.ts:39-202，`SENSITIVE_NAME` 正则 + `<redacted>` + body 截断 16384 字节）；`opencode export --sanitize` 才会对会话内容做 `[redacted:kind:id]` 替换（cli/cmd/export.ts:231-234、:289，默认导出不脱敏）；**未发现 UI/TUI 展示 API key 的打码**（静态推断）。
- **日志**：Provider 日志只记 providerID/modelID（session/llm.ts:86-93），不含 key。

## 4. 模型目录与能力元数据

- **拉取与缓存**（models-dev.ts）：源 `https://models.opencode.ai/api.json`（:160，`OPENCODE_MODELS_URL` 可覆盖）；缓存 `cache/models.json`（:161-164）；TTL 5 分钟（:165），后台每 60 分钟刷新（:257），跨进程 `Flock` 文件锁（:223-249），写盘临时文件+rename（:204-213）；`OPENCODE_DISABLE_MODELS_FETCH` 可关闭（:222）。三级数据源：磁盘缓存 → 构建期快照（`packages/opencode/script/generate.ts` 取数 :10-13，注入点在 script/build.ts:195 的 `define OPENCODE_MODELS_DEV`）→ 网络（:217-231）。
- **元数据**：`ModelsDev.Model`（:67-121）：id/name/family/release_date/attachment/reasoning/temperature/tool_call/reasoning_options/interleaved/cost（含 tiers、context_over_200k）/limit（context/input/output）/modalities（text/audio/image/video/pdf）/experimental.modes/status/provider{npm,api}。
- **转换**：`fromModelsDevModel`（provider.ts:1212-1263）+ `fromModelsDevProvider`（:1265-1290，`experimental.modes` 展开为 `modelID-mode` 变体）。
- **暴露**：`Provider.Service.list()`（:1671）；HTTP `GET /config/providers`（handlers/config.ts:24-30）、`GET /provider`（handlers/provider.ts:40-59，含 `default` 与 `connected`）；CLI `opencode models`（cli/cmd/models.ts:8-65）。排序优先级 `gpt-5 > claude-sonnet-4 > big-pickle > gemini-3-pro`，latest 靠前（provider.ts:1986-1995）。

## 5. Adapter、协议与请求组装

- **主路径 AI SDK**：`streamText`（llm.ts:318），SDK 由 `resolveSDK` 构造（provider.ts:1673-1805）；流事件转换 `llm/ai-sdk.ts:76-286`。
- **BUNDLED_PROVIDERS 表**（provider.ts:107-134）：覆盖 `@ai-sdk/amazon-bedrock/anthopic/azure/google/google-vertex/openai/openai-compatible/xai/mistral/groq/deepinfra/cerebras/cohere/gateway/togetherai/perplexity/vercel/alibaba`、`@openrouter/ai-sdk-provider`、`gitlab-ai-provider`、`@ai-sdk/github-copilot`（映射到 core/github-copilot/copilot-provider）、`venice-ai-sdk-provider`。
- **npm 动态安装**：表外包名 `Npm.add(model.api.npm)`（provider.ts:1781-1788；core/src/npm.ts:115-137，装到 `cache/packages/<sanitized>`，Arborist reify），动态 import 后找 `create*` 导出（:1793-1799）；`file://` URL 直接 import。
- **baseURL/Header**：baseURL 优先级 `options.baseURL > model.api.url`，支持 `${VAR}` 插值（:1698-1719）；header 合并 `options.headers + model.headers`（:1721-1725）；会话级 header `x-session-affinity`、`X-Session-Id`、`User-Agent: opencode/<ver>`（llm/request.ts:187-204）。
- **请求参数**：`ProviderTransform.options/providerOptions/message/temperature/topP/topK/maxOutputTokens/schema`（src/provider/transform.ts:1151-1506、464-566），按 SDK 生成 `providerOptions`（sdkKey 映射表，:42-96）。`topP` 按模型族特判默认值（transform.ts:548-559：minimax-m2/kimi-k2.5 等 0.95；deepseek-v4-flash 仅 deepseek/opencode 渠道给 0.95，5d95348）。
- **Copilot 模型能力**：image/pdf 输入能力由远端 `capabilities` 探测（plugin/github-copilot/models.ts:88-94、:133），`pdf` 不再硬编码 false（561afb4）。
- **native 协议（opt-in）**：`packages/llm/src/protocols/`：openai-chat/openai-responses/anthropic-messages/gemini/bedrock-converse/openai-compatible-chat，Route 化四要素 protocol/endpoint/auth/framing（llm/route/*）；切换门在 `session/llm/native-runtime.ts:46-72`（仅 openai/opencode/anthropic 且对应 npm 包、非 OAuth）。
- **兼容 provider**：ollama/lmstudio/deepseek 等统一走 `@ai-sdk/openai-compatible`（provider.ts:1444）；deepseek `reasoning_content` 特判（:1485-1487、transform.ts:320-352）。特殊适配：Azure deployment 选择（provider.ts:154-160、240-293）、Bedrock 区域前缀（:367-455）、Vertex GoogleAuth fetch（:529-543）、Cloudflare AI Gateway（:767-842）、SAP AI Core（:570-593）、GitLab（:604-728）。

## 6. 运行时选择、绑定与路由

- **解析**：`Provider.parseModel("provider/model")`（provider.ts:1997-2003）；variant 语法 `provider/model/variant`（acp/config-option.ts:123-130）。**未发现 `@` 全局模型、`#` 本地模型、`:latest` 后缀语义**（源码确认，全仓搜索无匹配）；"latest"仅作排序权重（provider.ts:1992）。
- **resolve 流程**：`getModel`（provider 存在性 + 模型存在性校验，:1811-1833）→ `getLanguage`（构造/缓存 SDK 与 LanguageModel，:1835-1864）。
- **会话默认模型**：`currentModel`：session 表 model 字段 → 最近 user 消息携带的 model → `provider.defaultModel()`（prompt.ts:614-633）；`defaultModel`：`cfg.model` → state/model.json 最近使用 → 第一个已配置 provider 的排序首个模型（provider.ts:1947-1980）。App 端解析改用 server `/config/providers` 响应新增的 `defaultModel {providerID, modelID}` 字段（global-sync/utils.ts:139-142），`cfg.model` 字符串仅作回退（app/src/hooks/provider-catalog.ts:28-38，941e71d）。
- **不存在模型**：抛 `ModelNotFoundError`（:1099-1113），携带 fuzzysort 建议（:1303-1330）；provider 不存在按 providerID 建议（:1814-1821）。**无静默兜底到其他 provider**。

## 7. 多 Key、限流、重试与故障转移

- **多 Key 轮询/负载均衡：不支持**（源码确认，无 keys 数组、无轮询代码）。
- **限流识别**：AI SDK 路径错误匹配 `429|500|502|503|504|524`、`rate limit`（session/retry.ts:31-38），`retry-after`/`retry-after-ms` 头解析为延迟（:44-75）；native 路径结构化解析 OpenAI `x-ratelimit-*` 与 Anthropic `anthropic-ratelimit-*`（llm/route/executor.ts:112-148），429 区分 `RateLimitReason`/`QuotaExceededReason`（:242-251）。
- **重试三层**：会话级 `Effect.retry(SessionRetry.policy)`（processor.ts:660-674，`retryable` 判定 5xx 强制可重试、context overflow 不重试、`FreeUsageLimitError`/`GoUsageLimitError` 转 upsell action，retry.ts:77-147；指数退避 2s 起、带 0.25 随机抖动，attempt 超过 5 停止，retry.ts:28-31、76-81、192）；SDK 级 `maxRetries: input.retries ?? 0`（llm.ts:323）；native 级 `MAX_RETRIES=2` 指数退避带 jitter（executor.ts:35-38、345-364）。
- **跨 provider failover：不存在**（源码确认）；`closest`（provider.ts:1866-1876）与重试无关。
- **错误归一化**：`parseAPICallError`/`parseStreamError`（provider/error.ts:102-186）识别 `context_length_exceeded/insufficient_quota/usage_not_included/invalid_prompt/server_is_overloaded` 等 code；context overflow 文本特征 30+ 正则（llm/provider-error.ts:4-38）；映射 `ContextOverflowError`/`APIError`（message-v2.ts:603-719，ECONNRESET、ZlibError、header/stream timeout 归一为可重试 APIError）。

## 8. 连接检测、日志与可观测性

- **连接测试**：登录流程**无专门 validation/测试请求**（源码确认，providers.ts 登录后直接写凭据）；仅插件 prompt 字段有 `validate` 回调（provider/auth.ts:170-176）与 GitLab 登录后 `discoverModels` 真实调 API（provider.ts:661-726）。
- **usage/cost**：`Session.getUsage` 按 `model.cost`（tiers 按 context 选档、`experimentalOver200K`）乘 token 数除 1e6 计算（session/session.ts:338-407）；投影到 session 表 `cost/tokens_{input,output,reasoning,cache_read,cache_write}`（core/src/session/sql.ts:43-48），删除消息/part 回滚 usage（projector.ts:276-311）。
- **OTel**：`OTEL_EXPORTER_OTLP_ENDPOINT` 时启用日志与 trace 导出（core/observability/otlp.ts:50-77）；AI SDK `experimental_telemetry`（llm.ts:344-352）；`packages/stats` 消费 tokens 做聚合（stats/core/src/domain/inference.ts:32-118）。
- **重试可见性**：`SessionStatus` 广播 `{type:"retry", attempt, message, action, next}`（processor.ts:664-672），UI 渲染倒计时卡片（packages/session-ui/src/components/session-retry.tsx:8-73）。
- **debug**：无独立 debug 开关；`logLevel` 配置 DEBUG/INFO/WARN/ERROR（v1/config/config.ts:27-37）；`opencode debug` 相关 CLI（cli/cmd/debug/）。

## 9. 设计取舍与已确认边界

- **超时三类可配**：`timeout`（整体）、`headerTimeout`（响应头）、`chunkTimeout`（SSE 块间），可 `false` 关闭（v1/config/provider.ts:101-120；provider.ts:1737-1768）；OpenAI 默认 headerTimeout 300s（provider.ts:35、208）。
- **prompt caching**：Anthropic/Bedrock 家族自动 `cacheControl: ephemeral` 注入 system + 最后 2 条消息（transform.ts:357-406）；`promptCacheKey` 按 sessionID 设置（transform.ts:1254-1267）；V2 runner 用 `session.id.slice(4)` 作 key（runner/llm.ts:204）；`options.setCacheKey` 可关。
- **重试可能重复计费**：会话级 `Effect.retry` 重跑整个 `llm.stream` effect，同一回合首请求若已计费则重试可能重复计费（静态推断；processor.ts:660-674 未做去重）。
- **凭据明文存储**：auth.json（0o600）与 credential/account 表均为明文，无加密；权限保护靠文件系统权限。
- **浏览器不直连 provider**：OAuth 由 server 端插件发起，浏览器只显示授权 URL 并等待（provider/auth.ts:163-186、app/src/utils/server-compat.ts:408-450）。
- **桌面隔离**：Electron 主进程 fork `sidecar.js`（utilityProcess.fork，packages/desktop/src/main/server.ts:57-184），带 password 的 Basic auth 健康检查（:186-211），设置 `OPENCODE_CLIENT=desktop`、`XDG_STATE_HOME=userDataPath`（:44-55）。渠道管理在 sidecar 内与 Web/CLI 完全同构：provider/模型/凭据无桌面差异，仅请求头 `x-opencode-client: desktop` 标识来源（llm/request.ts:193）；v2 侧车（`OPENCODE_SIDECAR_V2=1`）改为复用已存在的 CLI 守护进程（desktop/src/main/background-cli.ts:19-58，`service status/start/get password`）。
- **opencode zen**：device code 登录（src/account/account.ts:387-453），token 存 SQLite `account` 表明文（core/account/sql.ts:6-14）；连接后从 `console.opencode.ai/api/config` 拉取 provider 配置覆盖 catalog（core/plugin/provider/opencode.ts:86-212）；无 key 时仅留免费模型（:167-177）。
- **V2 上下文溢出自动压缩再试**：V2 runner 有 `compactAfterOverflow` 重跑 turn（core/src/session/runner/llm.ts:277-381），V1 无跨模型 fallback。

## 10. 未验证事项

1. 未运行构建与真实 API 请求；AI SDK 各包的 header/请求体组装行为未实测。
2. npm 动态安装（Npm.add）在离线/代理环境的行为未验证。
3. OAuth 各插件（openai/github-copilot/xai 等）的 device flow 未实测。
4. 重试重复计费、prompt cache 命中率等运行时经济行为未实测（静态推断）。
5. models.dev 网络拉取失败时构建期快照的实际覆盖范围未验证。

## 11. 关键源码索引

- `packages/opencode/src/provider/provider.ts`：运行时组装（:1343-1668）、getModel/getLanguage（:1811-1864）、默认模型（:1947-2003）
- `packages/opencode/src/provider/transform.ts`：参数转换（:42-96、:1151-1506）
- `packages/opencode/src/provider/error.ts`：错误归一化（:102-186）
- `packages/opencode/src/auth/index.ts`：auth.json 凭据
- `packages/opencode/src/session/llm.ts`、`src/session/llm/native-runtime.ts`、`llm/request.ts`：请求发起与协议切换
- `packages/opencode/src/session/retry.ts`：重试策略
- `packages/core/src/models-dev.ts`：模型目录
- `packages/core/src/provider.ts`、`src/credential.ts`、`src/account/`：V2 凭据与账户
- `packages/llm/src/protocols/`、`packages/llm/src/route/`：native 协议实现
- `packages/opencode/src/cli/cmd/providers.ts`、`models.ts`：CLI 登录与模型查看
