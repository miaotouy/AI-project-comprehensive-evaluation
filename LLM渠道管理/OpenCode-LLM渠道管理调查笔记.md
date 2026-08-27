# OpenCode LLM 渠道管理调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`c2eacd72afc4a4984564c393e15ab30011057269`（分支：`dev`）
>
> 调查方式：只读源码静态梳理 Provider 组装、配置生命周期、各管理入口、模型目录、凭据、协议适配与请求链路；未运行构建与真实请求
>
> 调查范围：Provider 实体与配置生命周期、配置文件/CLI/TUI/Web/桌面端管理入口、凭据边界、模型目录、AI SDK/native 协议适配、运行时选择与路由、多 Key/重试/故障转移、可观测性、平台边界、OAuth 流程；不覆盖 opencode zen 控制台前端
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的 Provider 是「代码注册的模型目录 + 用户凭据/配置的运行时实例」的合成体：运行时按固定顺序组装 models.dev 目录、插件 hook、config `provider` 字段、环境变量、auth.json 凭据（`src/provider/provider.ts:1343-1668`），通过 AI SDK `streamText` 发起请求（`src/session/llm.ts:280-353`）。模型目录来自远端拉取与缓存（`core/src/models-dev.ts`），无硬编码内置清单；协议适配以 AI SDK 包（内置表 + npm 动态安装）为主路径，另有 opt-in 的 native 协议实现（`packages/llm/src/protocols/`）。

关键事实（快照 1f94d8a）：

- **Provider ID 11 个**（静态工厂 `schema/src/provider.ts:11-21`）：

  ```text
  opencode / anthropic / openai / google / google-vertex / github-copilot /
  amazon-bedrock / azure / openrouter / mistral / gitlab
  ```
- **同 provider 多 Endpoint 不支持**：config `provider` 为单对象，`options` 无数组形态；多端点需注册多个自定义 provider id。
- **凭据存 `~/.local/share/opencode/auth.json`（0o600 明文）**，不写 opencode.json；另 SQLite `credential` 表明文 JSON（core/src/credential/sql.ts:5-14）。**无加密、无系统 keyring、无 UI 打码**。
- **模型目录三级数据源**：磁盘缓存 → 构建期快照（OPENCODE_MODELS_DEV）→ 网络，TTL 5 分钟、每小时刷新、文件锁防并发（models-dev.ts:160-249）。
- **无多 Key 轮询、无跨 provider failover**；重试分三处：会话级 `Effect.retry`（processor.ts:660-674，上限 5 次、指数退避带 0.25 抖动）+ SDK 级 `maxRetries` + native 级指数退避（详见 §7）。
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
- 运行时 `Provider.Model` schema（provider.ts:1036-1051）含 `cost`（带 tiers）、`experimentalOver200K`、`status` 等；媒体能力收敛为 `capabilities.input/output` 布尔（:991-999），无顶层 `modalities` 字段——数组形态的 modalities 只存在于 models.dev 元数据（`ModelsDev.Model`，models-dev.ts:67-121、:92-97）。
- **多 Endpoint**：`ConfigProviderV1.Info` 是单对象（core/src/v1/config/provider.ts:82-126），`options` 为 `Record<string, unknown>`，**无 options 数组/多端点支持**（源码确认）。唯一的动态多实例是 GitLab `discoverModels`（provider.ts:661-726，按账号发现模型）。

## 2. 配置生命周期、管理入口与持久化

OpenCode 把“Provider 定义”和“Provider 凭据”分开管理。Provider 定义属于合并后的配置，旧版配置使用单数 `provider` 对象；凭据由 `auth.json`、环境变量或 V2 的 credential 表提供。因而界面上的“连接”通常是新增或替换凭据，不是创建一个新的 Endpoint 实例；自定义 Provider 才会同时写入配置定义和凭据。

### 配置文件与服务端写入

- **查看**：配置文件可直接查看；`opencode debug config` 输出当前实例解析后的配置，而不是某一个源文件的原文（`packages/opencode/src/cli/cmd/debug/config.ts:5-13`）。全局文件按 `opencode.jsonc`、`opencode.json`、`config.json` 的优先级选择写入目标，加载时三个文件仍会按顺序合并（`packages/opencode/src/config/config.ts:139-145、246-260`）。
- **新增、编辑、复制、删除**：源码确认配置 schema 支持在 `provider` 下新增或修改 Provider 定义、模型、选项和 Header；复制没有专门命令或 API，通常只能手工复制配置对象并改 Provider ID。删除也未找到独立的 Provider 删除接口，需从配置文件移除对象；删除凭据不会删除配置定义。
- **启停**：旧版通过 `disabled_providers` 禁用，以及 `enabled_providers` 作为允许列表限制目录；运行时和 Provider 列表都会按这两个字段过滤（`packages/opencode/src/provider/provider.ts:1388-1390`）。这属于配置层启停，不会删除凭据。V2 设计稿改用 `disabled` 与 `experimental.policies`，但当前 Web 自定义 Provider 表单仍受 `protocol() === "v1"` 限制，不能据此认定 V2 已提供同等用户入口（`specs/v2/config.md:171-206`；`packages/app/src/components/dialog-custom-provider.tsx:132-152`）。
- **导入、导出**：本次检查未找到 Provider 配置专用的导入/导出命令。CLI 的 `export`/`import` 针对会话 JSON，不是 Provider 配置（`packages/opencode/src/cli/cmd/export.ts:222-234、287-290`；`packages/opencode/src/cli/cmd/import.ts:94-110`）。
- **连接测试**：配置文件写入本身不发起 Provider 请求。API Key 连接流程只把 key 写入凭据存储，OAuth 流程执行授权回调；源码未找到“保存后用真实模型或探活接口验证”的通用测试请求。

服务端暴露的是配置和凭据的基础操作，而不是 Provider CRUD：配置 API 可以读取或更新合并后的配置，凭据 API 可以设置或移除某个 Provider 的凭据；Provider API 主要列目录、返回认证方法并承载 OAuth 授权与回调（`packages/opencode/src/server/routes/instance/httpapi/handlers/config.ts:14-32`；`packages/opencode/src/server/routes/instance/httpapi/handlers/control.ts:13-25`；`packages/opencode/src/server/routes/instance/httpapi/groups/provider.ts:34-93`）。静态代码中未找到复制、导入、导出或通用连接测试端点。

### 各管理入口的实际覆盖

| 入口 | 源码确认的查看与新增 | 已有渠道的编辑、复制、启停、删除 | 导入、导出与连接测试 | 已有渠道和新建渠道的差异 |
|---|---|---|---|---|
| 配置文件 | 直接查看源文件；在 `provider` 下手工新增或修改定义、模型、`options`、Header；可用 `opencode debug config` 查看解析结果 | 手工修改或移除配置对象；可手工复制对象；用 `disabled_providers`/`enabled_providers` 控制启停；凭据删除独立于配置删除 | 未找到 Provider 专用导入/导出；未找到保存后的通用测试请求 | 已有 Provider 可覆盖定义；新 Provider 需要新的 ID 和完整自定义配置，凭据仍另存 |
| CLI | `opencode providers list` 查看已存凭据和命中的环境变量；`providers login` 新增或覆盖凭据；`debug config` 查看解析配置 | `providers logout` 删除凭据；重新 login 可替换凭据；未找到 Provider 定义编辑、复制或启停命令 | `export`/`import` 仅处理会话；未找到 Provider 连接测试命令 | 已有 Provider 可选择内置或插件认证方法；`Other` 只保存自定义 Provider 凭据，并明确提示仍需编辑 `opencode.json` |
| TUI | `/connect`（`provider_connect` keybind）列出 Provider 并新增 API Key/OAuth 凭据；可显示已连接标记 | 本次未找到 TUI 中对已有渠道的编辑、复制、断开、启停或删除入口；未找到 Provider 配置导入/导出 | OAuth 授权回调是认证流程，不是独立连接测试；未找到测试请求 | 选择已有 Provider 会进入其认证方法；`Other` 只询问 Provider ID 并保存凭据，随后提示在 `opencode.json` 中配置 |
| Web | 设置页列出已连接 Provider、来源标签和可连接 Provider；内置 Provider 支持 API Key/OAuth；V1 支持自定义表单，可新增 Provider、Base URL、模型和 Header，并可选写入 key | 已有内置渠道只有 Disconnect；自定义渠道 Disconnect 会移除凭据并加入 `disabled_providers`；自定义表单允许用同一 ID 重新连接已禁用项，但未提供已保存配置的编辑或复制界面 | 未找到 Provider 配置导入/导出；提交 API Key 直接调用连接接口并刷新目录，未发起独立模型探测请求 | 已有渠道展示来源并只能断开；新建自定义渠道可一次写配置和凭据，保存时会移除该 ID 的禁用状态（`packages/app/src/components/settings-providers.tsx:87-146、224-258`；`packages/app/src/components/dialog-custom-provider.tsx:117-166`） |
| 桌面端 | 桌面端渲染器复用 Web App 的设置页和 Provider 对话框；通过 sidecar 连接本地服务 | 未找到桌面主进程专属 Provider CRUD、复制、启停或删除逻辑；实际覆盖随 Web/sidecar 路径 | 未找到桌面专属导入/导出或连接测试 | 桌面端是部署和服务连接边界，不是另一套渠道模型；sidecar 启动后提供同一 Server API（`packages/desktop/src/renderer/index.tsx:348-435`；`packages/desktop/src/main/server.ts:57-211`） |

上述表格中的“未找到”仅表示在本次检查的配置、CLI、TUI、Web、桌面端入口及其调用链中未发现对应能力，不等同于项目全局绝对不存在。

- **schema**（opencode.json 的 `provider` 字段，v1/config/config.ts:110-112；类型定义 v1/config/provider.ts:13-126）：

  ```text
  ConfigProviderV1.Info   api/name/env/id/npm/whitelist/blacklist/
                          options(apiKey/baseURL/enterpriseUrl/setCacheKey/timeout/headerTimeout/chunkTimeout + 任意扩展)/models
  ConfigProviderV1.Model  id/name/family/release_date/attachment/reasoning/temperature/tool_call/interleaved/
                          cost/limit/modalities/experimental/status/provider{npm,api}/options/headers/variants
  ```

- **合并顺序**（config/config.ts:314-596）：

  ```text
  远程 well-known → 全局（config.json → opencode.json → opencode.jsonc 深度合并，:246-279；legacy TOML 迁移 :262-276）
  → OPENCODE_CONFIG → 项目 opencode.json → .opencode/ 目录 → OPENCODE_CONFIG_CONTENT
  → opencode zen 账户/org 远程配置 → 企业托管
  ```

- **provider 合并细节**：config 项合并进 models.dev 目录（provider.ts:1424-1520）；`apiNpm` 的解析优先级（:1439-1444）：

  ```text
  model.provider.npm > provider.npm > existing > modelsDev > "@ai-sdk/openai-compatible"
  ```
- **登录不写 opencode.json**：只写 auth.json（cli/cmd/providers.ts:480-485）。
- **配置写入位置**：实例配置更新写入项目目录下的 `config.json` 并与已有内容深度合并；全局配置更新写回当前全局配置文件，`.jsonc` 使用保留格式的补丁写入，并在发生变化后使缓存失效（`packages/opencode/src/config/config.ts:624-659`）。Web 设置页的 `updateConfig` 调用全局配置 API，随后使各作用域的 Provider 查询失效（`packages/app/src/context/server-sync.tsx:660-670`）。
- **V2 生命周期边界**：V2 Core 已有运行时 Catalog 的 `provider.update/remove` 和 Integration credential 的 `connection.update/remove`，但本快照中未找到把这些 Draft/Service 操作完整暴露为 Web、CLI 或 TUI Provider 管理界面的通用入口（`packages/core/src/catalog.ts:29-59`；`packages/core/src/integration.ts:140-192`）。因此不能用 V2 内部可变数据结构推断前端已支持编辑、复制或删除 Provider。

## 3. 凭据、Header 与代理边界

- **存储**：`~/.local/share/opencode/auth.json`（core/src/global.ts:11；src/auth/index.ts:10），`set/remove` 以 0o600 权限写**明文 JSON**（auth/index.ts:73-89）；`OPENCODE_AUTH_CONTENT` 可整体覆盖。
- **三种凭据类型**（src/auth/index.ts）：`Oauth`（refresh/access/expires/accountId/enterpriseUrl，:14-21）、`Api`（key+metadata，:23-27）、`WellKnown`（key+token，:29-33）。
- **env 边界**：config `env` 字段只声明「从哪些环境变量探测 key」（v1/config/provider.ts:85），探测在 provider.ts:1523-1533；key 不写入 opencode.json。
- **credential 服务（V2）**：SQLite `credential` 表 `value` 明文 JSON（core/src/credential/sql.ts:5-14），`create` 先删同 integration 旧记录（credential.ts:101-118）。
- **key 进入请求（AI SDK 路径）**：`options["apiKey"] = provider.key`（provider.ts:1720），SDK factory 构造时带入（:1773-1799），各 SDK 自行放 `Authorization: Bearer`/`x-api-key`。
- **key 进入请求（native 路径）**：`Auth.bearer(apiKey)` 配置在 route（llm/route/auth.ts）。
- **插件 fetch 覆盖**：github-copilot 的 `auth.loader` 替换整个 fetch，注入 `Authorization: Bearer ${info.refresh}`（plugin/github-copilot/copilot.ts:96-180）。
- **脱敏**：native 错误路径系统脱敏（packages/llm/src/route/executor.ts:39-202，`SENSITIVE_NAME` 正则 + `<redacted>` + body 截断 16384 字节）；**未发现 UI/TUI 展示 API key 的打码**（静态推断）。
- **导出脱敏**：仅 `opencode export --sanitize` 会对会话内容做 `[redacted:kind:id]` 替换（cli/cmd/export.ts:231-234、:289，默认导出不脱敏）。
- **日志**：Provider 日志只记 providerID/modelID（session/llm.ts:86-93），不含 key。

## 4. 模型目录与能力元数据

- **拉取与缓存**（models-dev.ts）：源 `https://models.opencode.ai/api.json`（:160，`OPENCODE_MODELS_URL` 可覆盖），缓存 `cache/models.json`（:161-164），TTL 5 分钟（:165）。其余机制定位：
  - 后台每 60 分钟刷新（:257）；
  - 跨进程 `Flock` 文件锁防并发（:223-249）；
  - 写盘临时文件 + rename（:204-213）；
  - `OPENCODE_DISABLE_MODELS_FETCH` 可关闭（:222）。
- **三级数据源**：磁盘缓存 → 构建期快照 → 网络：
  - 构建期快照：`packages/opencode/script/generate.ts` 取数（:10-13），注入点在 `script/build.ts:195` 的 `define OPENCODE_MODELS_DEV`；
  - 网络回退（:217-231）。
- **元数据**：`ModelsDev.Model`（:67-121）字段：

  ```text
  id / name / family / release_date / attachment / reasoning / temperature / tool_call /
  reasoning_options / interleaved / cost（含 tiers、context_over_200k）/ limit（context/input/output）/
  modalities（text/audio/image/video/pdf）/ experimental.modes / status / provider{npm,api}
  ```

- **转换**：`fromModelsDevModel`（provider.ts:1212-1263）+ `fromModelsDevProvider`（:1265-1290，`experimental.modes` 展开为 `modelID-mode` 变体）。
- **暴露**：`Provider.Service.list()`（:1671）；HTTP `GET /config/providers`（handlers/config.ts:24-30）、`GET /provider`（handlers/provider.ts:40-59，含 `default` 与 `connected`）；CLI `opencode models`（cli/cmd/models.ts:8-65）。
- **排序优先级**：`gpt-5 > claude-sonnet-4 > big-pickle > gemini-3-pro`，latest 靠前（provider.ts:1986-1995）。

## 5. Adapter、协议与请求组装

- **主路径 AI SDK**：`streamText`（llm.ts:318），SDK 由 `resolveSDK` 构造（provider.ts:1673-1805）；流事件转换 `llm/ai-sdk.ts:76-286`。
- **BUNDLED_PROVIDERS 表**（provider.ts:107-134）内置的 SDK 包：

  ```text
  @ai-sdk/amazon-bedrock / @ai-sdk/anthopic / @ai-sdk/azure / @ai-sdk/google / @ai-sdk/google-vertex /
  @ai-sdk/openai / @ai-sdk/openai-compatible / @ai-sdk/xai / @ai-sdk/mistral / @ai-sdk/groq /
  @ai-sdk/deepinfra / @ai-sdk/cerebras / @ai-sdk/cohere / @ai-sdk/gateway / @ai-sdk/togetherai /
  @ai-sdk/perplexity / @ai-sdk/vercel / @ai-sdk/alibaba / @openrouter/ai-sdk-provider /
  gitlab-ai-provider / @ai-sdk/github-copilot（映射到 core/github-copilot/copilot-provider）/ venice-ai-sdk-provider
  ```
- **npm 动态安装**：表外包名 `Npm.add(model.api.npm)`（provider.ts:1781-1788；core/src/npm.ts:115-137，装到 `cache/packages/<sanitized>`，Arborist reify），动态 import 后找 `create*` 导出（:1793-1799）；`file://` URL 直接 import。
- **baseURL/Header**：baseURL 优先级 `options.baseURL > model.api.url`，支持 `${VAR}` 插值（:1698-1719）；header 合并 `options.headers + model.headers`（:1721-1725）；会话级 header `x-session-affinity`、`X-Session-Id`、`User-Agent: opencode/<ver>`（llm/request.ts:187-204）。
- **请求参数**：`ProviderTransform` 输出 options/providerOptions/message/temperature/topP/topK/maxOutputTokens/schema（src/provider/transform.ts:1151-1506、464-566），按 SDK 生成 `providerOptions`（sdkKey 映射表，:42-96）。
- **topP 默认值特判**（transform.ts:548-559）：minimax-m2/kimi-k2.5 等 0.95；deepseek-v4-flash 仅 deepseek/opencode 渠道给 0.95（5d95348）。
- **Copilot 模型能力**：image/pdf 输入能力由远端 `capabilities` 探测（plugin/github-copilot/models.ts:88-94、:133），`pdf` 不再硬编码 false（561afb4）。
- **native 协议（opt-in）**：`packages/llm/src/protocols/` 下实现：

  ```text
  openai-chat / openai-responses / anthropic-messages / gemini / bedrock-converse / openai-compatible-chat
  ```

  Route 化四要素 protocol/endpoint/auth/framing（`llm/route/*`）；切换门在 `session/llm/native-runtime.ts:46-72`（仅 openai/opencode/anthropic 且对应 npm 包、非 OAuth）。
- **兼容 provider**：ollama/lmstudio/deepseek 等统一走 `@ai-sdk/openai-compatible`（provider.ts:1444）；deepseek `reasoning_content` 特判（:1485-1487、transform.ts:320-352）。
- **特殊适配**（provider.ts 内）：
  - Azure deployment 选择（:154-160、:240-293）；
  - Bedrock 区域前缀（:367-455）；
  - Vertex GoogleAuth fetch（:529-543）；
  - SAP AI Core（:570-593）；
  - Cloudflare AI Gateway：OpenAI 与 Anthropic 原生模型保留各自协议路径，其他上游改经兼容 REST 路由；Anthropic 的带连字符原生 slug 也保留原样（`packages/opencode/src/provider/provider.ts:1249-1308`）。
  - GitLab（:604-728）。

## 6. 运行时选择、绑定与路由

- **解析**：`Provider.parseModel("provider/model")`（provider.ts:1997-2003）；variant 语法 `provider/model/variant`（acp/config-option.ts:123-130）。**未发现 `@` 全局模型、`#` 本地模型、`:latest` 后缀语义**（源码确认，全仓搜索无匹配）；"latest"仅作排序权重（provider.ts:1992）。
- **resolve 流程**：`getModel`（provider 存在性 + 模型存在性校验，:1811-1833）→ `getLanguage`（构造/缓存 SDK 与 LanguageModel，:1835-1864）。
- **会话默认模型**：`currentModel` 按 session 表 model 字段 → 最近 user 消息携带的 model → `provider.defaultModel()`（prompt.ts:614-633）的顺序解析；`defaultModel` 按 `cfg.model` → state/model.json 最近使用 → 第一个已配置 provider 的排序首个模型（provider.ts:1947-1980）。
- **App 端解析**：改用 server `/config/providers` 响应新增的 `defaultModel {providerID, modelID}` 字段（global-sync/utils.ts:139-142），`cfg.model` 字符串仅作回退（app/src/hooks/provider-catalog.ts:28-38，941e71d）。
- **不存在模型**：抛 `ModelNotFoundError`（:1099-1113），携带 fuzzysort 建议（:1303-1330）；provider 不存在按 providerID 建议（:1814-1821）。**无静默兜底到其他 provider**。

## 7. 多 Key、限流、重试与故障转移

- **多 Key 轮询/负载均衡：不支持**（源码确认，无 keys 数组、无轮询代码）。
- **限流识别（AI SDK 路径）**：错误匹配 `429|500|502|503|504|524`、`rate limit`（session/retry.ts:31-38），`retry-after`/`retry-after-ms` 头解析为延迟（:44-75）。
- **限流识别（native 路径）**：结构化解析 OpenAI `x-ratelimit-*` 与 Anthropic `anthropic-ratelimit-*`（llm/route/executor.ts:112-148），429 区分 `RateLimitReason`/`QuotaExceededReason`（:242-251）。
- **重试三层**：
  - 会话级：`Effect.retry(SessionRetry.policy)`（processor.ts:660-674）：`retryable` 判定 5xx 强制可重试、context overflow 不重试、已识别的网络错误与“稍后重试/容量不足”提示也可重试，`FreeUsageLimitError`/`GoUsageLimitError` 转 upsell action（`packages/opencode/src/session/retry.ts:33-42, 77-147`）；指数退避 2s 起、带 0.25 随机抖动，attempt 超过 5 停止（retry.ts:28-31、76-81、192）。
  - SDK 级：`maxRetries: input.retries ?? 0`（llm.ts:323）。
  - native 级：`MAX_RETRIES=2` 指数退避带 jitter（executor.ts:35-38、345-364）。
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
- **桌面隔离**：Electron 主进程 fork `sidecar.js`（utilityProcess.fork，packages/desktop/src/main/server.ts:57-184），带 password 的 Basic auth 健康检查（:186-211），设置 `OPENCODE_CLIENT=desktop`、`XDG_STATE_HOME=userDataPath`（:44-55）。
- 渠道管理在 sidecar 内与 Web/CLI 完全同构：provider/模型/凭据无桌面差异，仅请求头 `x-opencode-client: desktop` 标识来源（llm/request.ts:193）；v2 侧车（`OPENCODE_SIDECAR_V2=1`）改为复用已存在的 CLI 守护进程（desktop/src/main/background-cli.ts:19-58，`service status/start/get password`）。
- **opencode zen**：device code 登录（src/account/account.ts:387-453），token 存 SQLite `account` 表明文（core/account/sql.ts:6-14）；连接后从 `console.opencode.ai/api/config` 拉取 provider 配置覆盖 catalog（core/plugin/provider/opencode.ts:86-212）；无 key 时仅留免费模型（:167-177）。
- **V2 上下文溢出自动压缩再试**：V2 runner 有 `compactAfterOverflow` 重跑 turn（core/src/session/runner/llm.ts:277-381），V1 无跨模型 fallback。

## 10. 未验证事项

1. 未运行构建与真实 API 请求；AI SDK 各包的 header/请求体组装行为未实测。
2. npm 动态安装（Npm.add）在离线/代理环境的行为未验证。
3. OAuth 各插件（openai/github-copilot/xai 等）的 device flow 未实测。
4. 重试重复计费、prompt cache 命中率等运行时经济行为未实测（静态推断）。
5. models.dev 网络拉取失败时构建期快照的实际覆盖范围未验证。
6. Web 设置页、TUI `/connect` 和桌面端未实际启动操作；表格中的入口、按钮状态和事件调用链是源码确认，视觉表现、权限、错误提示及跨平台行为未验证。
7. 未验证配置文件或 Web 更新后各已存在实例何时重载，以及自定义 Provider 断开后删除凭据、写入禁用列表和目录刷新之间的实际时序。
8. 未验证 V2 Catalog/Integration 的内部更新与删除操作是否会在后续版本通过其他未检查的适配层暴露；当前结论仅针对本快照已读入口。

## 11. 关键源码索引

- `packages/opencode/src/provider/provider.ts`：运行时组装（:1343-1668）、getModel/getLanguage（:1811-1864）、默认模型（:1947-2003）
- `packages/opencode/src/provider/transform.ts`：参数转换（:42-96、:1151-1506）
- `packages/opencode/src/provider/error.ts`：错误归一化（:102-186）
- `packages/opencode/src/auth/index.ts`：auth.json 凭据
- `packages/opencode/src/session/llm.ts`、`src/session/llm/native-runtime.ts`、`llm/request.ts`：请求发起与协议切换
- `packages/opencode/src/session/retry.ts`：重试策略
- `packages/core/src/models-dev.ts`：模型目录
- `packages/core/src/provider.ts`、`src/credential.ts`、`src/account/`：V2 凭据与账户
- `packages/opencode/src/config/config.ts`、`src/server/routes/instance/httpapi/handlers/config.ts`：配置读取、合并与写入
- `packages/opencode/src/server/routes/instance/httpapi/handlers/control.ts`、`groups/provider.ts`：凭据与 Provider/OAuth API
- `packages/opencode/src/cli/cmd/providers.ts`、`src/cli/cmd/debug/config.ts`：CLI 凭据生命周期与解析配置查看
- `packages/app/src/components/settings-providers.tsx`、`dialog-connect-provider.tsx`、`dialog-custom-provider.tsx`：Web Provider 管理入口
- `packages/tui/src/component/dialog-provider.tsx`、`src/config/keybind.ts`：TUI `/connect` 入口
- `packages/desktop/src/renderer/index.tsx`、`src/main/server.ts`：桌面端 Web/sidecar 边界
- `packages/llm/src/protocols/`、`packages/llm/src/route/`：native 协议实现
- `packages/opencode/src/cli/cmd/models.ts`：CLI 模型查看
