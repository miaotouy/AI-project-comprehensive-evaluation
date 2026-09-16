# Jan LLM 渠道管理调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`38491c73d12398edda45ebec366f940e83509490`（分支：`main`）
>
> 调查方式：只读源码梳理（前端 provider/参数体系、Rust server 代理全量行级阅读）；未修改 Jan 仓库
>
> 调查范围：provider 定义与配置、配置文件/CLI/TUI/Web/桌面端的渠道生命周期操作、API key 管理与验证、模型目录与导入、模型能力与采样参数过滤、llama.cpp/MLX 本地引擎、router 与本地 API 代理、Rust 转发链路、https 代理与硬件设置；渠道导入导出及 CLI/TUI 能力按源码搜索结果标注
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的“渠道”由两层构成：

1. **远程 provider**：`web-app/src/constants/providers.ts` 内置 11 个预定义 provider（完整清单见 1.1），每个 provider 只有 api key、base url、模型列表与少量自定义 header；另支持用户自定义 OpenAI 兼容端点（api_type 可选 `openai`/`anthropic`）。
2. **本地引擎**：llamacpp-extension 与 mlx-extension 把 GGUF/MLX 模型通过 OpenAI 兼容端点暴露；本轮 llama.cpp 改由独立 worker 管理模型驻留与线程 KV 状态。Rust 侧 `src-tauri/src/core/server/` 仍提供本地 API server 代理、认证与远程 provider 转发。

聊天请求不经过任何后端业务服务，由前端 `CustomChatTransport` 直接经 `createCustomFetch` 包装的 fetch 发出；**推理参数在 HTTP 层注入 body**，`streamText` 本身只传 AI SDK 字段。请求默认打到本地 router 代理，Rust 按模型 ID 决定转发远程 provider 还是路由到 llama-server/mlx-server 子进程。

横向比较的关键事实：

- 参数体系以 `predefinedParams.ts` 的 `ParamDef`（能力标签 capability + 默认值 + disabledBy 条件）为单一定义源，wire 过滤按 `CLIENT_SIDE_PARAM_KEYS` / `LLAMACPP_ONLY_PARAM_KEYS` / `WIRE_KEY_REMAP` 三层处理；
- 能力表在 `providerCaps.ts`：内置 provider 锁定 base_url → provider ID 可作引擎可靠的代理；自定义 provider 落入 `CUSTOM_PERMISSIVE`（全部采样参数 maybe）；模型级拒绝（OpenAI o 系拒 temperature/top_p/penalties，grok-3-mini 拒 temp 等）；
- API key：主 key + fallback 链（`api-key-fallbacks` 设置项），401/403/429 轮换重试；连接测试对 `/models` 发 GET 并同时发 `x-api-key` 与 `Authorization: Bearer` 双头；远程 key 的 secrets 只在 OS keyring（`register_provider_config`），绝不明文写 settings.json；
- llama-server 鉴权 key = `BASE64(HMAC-SHA256(apiSecret='JustAskNow', msg=modelId))`，知道端口+公开 secret 即可本地伪造——防局域网误连、不防本地恶意进程；
- `SecurityConfigDialog.tsx`（auth/设备/日志三 tab）是**孤儿死代码**：9 个 `security_*` Tauri 命令在 src-tauri 中不存在，组件无任何挂载点（【代码确认】）——需要与“真实认证”区分：真实认证在 `proxy.rs`（`config.proxy_api_key` + Bearer/X-Api-Key 双头校验）。

## 系统边界与总体调用链

Jan 中需要区分三个层次：

- **Provider 注册项**：`predefinedProviders` 提供内置远程 provider；`EngineManager` 提供 `llamacpp`、`mlx` 等本地引擎项。
- **用户渠道实例**：Web 设置页创建的自定义 provider 以 `provider` 字符串作为唯一标识，保存一个 base URL、协议类型、模型列表和设置；当前没有独立的 Endpoint 子实体，因此同名 provider 不能并存，也没有在同一 provider 下创建多个 Endpoint 的 UI。
- **运行时连接配置**：桌面端启动时把有 key 且启用的远程 provider 注册到 Rust 的 `provider_configs` 内存表；请求代理根据模型 ID 在本地引擎和远程 provider 间路由。注册配置不是另一份可供用户编辑的渠道目录。

完整主链路是：桌面 Tauri 启动 `TauriProvidersService.getProviders()` 合并内置 provider 与引擎 provider，Zustand `useModelProvider` 从 `settings.json` 恢复用户状态；`DataProvider` 从 keyring 回填密钥，并对启用的远程 provider 调用 `register_provider_config`。用户在 Web 设置页修改状态后，Zustand 持久化非敏感 provider 数据，状态同步再注册或注销 Rust 运行时配置；聊天请求最终由前端 fetch 或本地 API server 代理发往 endpoint。Web 模式没有 Tauri 服务，provider service 的默认实现返回空列表、模型列表和 keyring 操作均为 no-op，且持久化退回浏览器 localStorage（`web-app/src/services/providers/default.ts:7-29`、`web-app/src/lib/backendStorage.ts:22-60`）。

## 配置生命周期与管理入口

### 操作覆盖矩阵

下表只记录 provider/渠道本身；模型的新增、编辑、复制、删除和本地文件导入另见 6.2 及本节后文。静态源码能够确认入口和事件绑定，未运行桌面应用，因此不据此确认保存时机或跨平台视觉行为。

| 入口 | 查看 | 新增 | 编辑 | 复制 | 启停 | 删除 | 导入/导出 | 连接测试 |
|---|---|---|---|---|---|---|---|---|
| 配置文件 | `settings.json` 中可读到序列化的 `model-provider` Zustand 状态；provider secrets 不在此文件 | **未找到**稳定的手工 schema/命令 | 可手工改非 secret JSON，但不属于产品化入口，效果未验证 | 未找到 | 可改 `active`，效果未验证 | 可从 JSON 删除对象，keyring 残留处理未验证 | **未找到** provider 专用导入/导出格式或命令 | **未找到**文件级测试机制 |
| CLI | `jan config list` 以 JSON 列出 `~/.jan/config.toml` 中的 provider（key 脱敏）；`jan cli models list` 列出已解析 provider 的模型 | `jan config set --provider X [--api-key --base-url --model --api-type]` 新增或改写 provider 条目 | 同左（`set` 覆盖）；`jan login` 写入 Tokamak 账号 key | 未找到 | 未找到 provider `active` 开关（启停只用于 `jan cli mcp` 的 server） | `jan config unset --provider X` | 未找到渠道导入/导出 | **未找到**独立 provider 连接测试；`jan auth status` 只校验 Tokamak 登录 |
| TUI | **未找到 Jan 自身 TUI**；CLI 的模型/agent 选择器是交互式终端选择，不是渠道管理界面 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 |
| Web（浏览器实现） | 默认 provider service 返回空，provider 管理依赖 Tauri；仅确认 backendStorage 在非 Tauri 下使用 localStorage | **源码未找到可用的远程 provider 数据来源** | 同上，不能据此确认浏览器模式可管理 provider | 未找到 | 未找到可执行的 provider 列表状态 | 未找到可执行的 provider 删除 | 未找到 | 未找到 |
| Web UI（桌面 Tauri 壳内） | 设置 > Model Providers 列出 provider、模型数量、启用状态；详情页展示设置、key、模型 | `AddProviderDialog` 新增自定义远程 provider | 详情页编辑设置、Azure base URL、API key/fallback、模型元数据；无 provider 重命名 | 未找到 provider 复制入口 | 列表和详情页均有 `active` 开关；停用 llamacpp 会先停止全部模型 | 仅自定义 provider 显示删除确认；内置 provider 和 EngineManager provider 不显示删除 | provider 导入/导出未找到；llama.cpp/MLX 的**模型**有文件导入入口 | 高级 API key 面板逐 key GET `/models`，显示 200/401/403/429/网络错误 |

### 新建渠道与已有渠道的差异

新建自定义渠道只能通过 `AddProviderDialog` 提交名称、base URL、API key 和 `openai`/`anthropic` 类型。表单只做必填、URL 正则和大小写不敏感的重名检查，不在创建前测试 endpoint；创建对象固定为 `active: true`、空模型列表，并从相应协议模板复制设置（`web-app/src/routes/settings/providers/index.tsx:42-85`、`web-app/src/containers/dialogs/AddProviderDialog.tsx:26-71`）。

已有 provider 的可操作范围取决于来源：

- 内置远程 provider 可以查看模型、修改 API key 链并刷新/手动添加模型，但详情页隐藏通用设置卡；除 Azure 外 base URL 由内置常量提供，不能通过该 UI 改 endpoint。
- 自定义远程 provider 可以编辑通用设置、Azure 式 base URL、主 key/fallback、模型列表和模型元数据，也可以删除；当前没有复制 provider 或修改 provider 名称的入口。
- llamacpp/MLX 是 EngineManager 提供的本地 provider，不按普通远程渠道处理。它们可以编辑引擎设置、导入本地模型、编辑/删除模型和启停单模型；删除 provider 被 `DeleteProvider` 明确屏蔽，停用 llamacpp 还会先 `stopAllModels()`。

### 持久化、合并与迁移

桌面端的 provider Zustand 状态以 `model-provider` 命名空间写入 `<jan_data>/settings.json`；Rust 设置存储保存的是扁平 JSON 对象中一个序列化的 store blob，并以 500ms 防抖、原子替换方式写盘（`src-tauri/src/core/app/settings_store.rs:1-14,25-27,111-119`）。`useModelProvider` 的 `partialize` 在写入前清空 `api_key`、fallback 和设置数组中的 secret 值，因此配置文件不是完整渠道备份。

恢复时 `TauriProvidersService.getProviders()` 重新生成内置 provider 和引擎 provider，`setProviders` 将它们与已有状态按 provider 名合并；已保存的自定义 provider 不会由引擎服务返回，但会保留在 Zustand 状态中。内置/引擎设置的元数据以新拉取版本为准，用户值按条件保留；迁移函数当前版本为 17，包含 base URL、协议类型和旧 provider/model 字段迁移（`web-app/src/hooks/useModelProvider.ts:64-236,338-762`）。因此“已有渠道”不是从单独 provider 配置文件恢复，而是由默认注册项、引擎注册项和持久化用户状态合并得到。

### 渠道操作与模型操作的边界

Web 详情页确实提供“刷新、手动新增、编辑、删除”按钮，但这些按钮作用于模型列表。远程刷新向 endpoint 的 `/models` 获取 ID；llama.cpp/MLX 的 Import 按钮选择并导入本地模型文件；删除模型会写入 `deletedModels` 软删除标记，重新下载或导入的本地模型会清理对应 tombstone。源码中未找到把 provider 配置整体导入/导出为文件的入口，也未找到“复制渠道”实现。`autoqa/checklist.md` 中的 “Create a Custom Provider”“Disabled Model Providers”“Custom Providers can be deleted”是测试清单，能佐证预期场景，但不能增加源码中不存在的导入、导出或复制能力。

### CLI 与 TUI 边界

独立 crate `src-tauri/jan-cli` 的命令树分为 `cli`（threads/models/agent/mcp）、`login`/`auth`、`config`（set/unset/list/path）、`plugin` 与 `update`。渠道管理落在 `jan config`：`set` 可按 `--provider` 写入 API key、base URL、模型列表与 `api_type`，`list` 输出已配置 provider 的 JSON（key 脱敏），`unset` 删除条目，全部作用于全局 `~/.jan/config.toml`；`jan cli models list` 再按解析结果列出模型。解析优先级为 CLI 参数与环境变量、项目 `.jan/agent/agent.toml` 的 `[provider]`、桌面 `settings.json`（只继承不回写）、全局 `~/.jan/config.toml`（`src-tauri/src/core/cli/providers.rs:1-16`）。CLI 不提供 provider 启停开关、独立连接测试与导入导出；`jan login`/`auth` 只处理 Tokamak 账号凭据。裸 `jan` 打开的是 Agent TUI（`src-tauri/src/core/cli/tui.rs`）而非渠道管理界面；MCP server 的增删改与启停由 `jan cli mcp` 负责。

## 1. Provider 定义与配置模型

### 1.1 预定义 provider

`web-app/src/constants/providers.ts`（402 行）`predefinedProviders`（L54）内置 11 个预定义 provider：

```text
openai / azure / anthropic / openrouter / mistral / groq / xai / gemini / minimax / huggingface / nvidia
```

- 字段：

  ```
  provider / api_key / base_url / explore_models_url / settings（controller 描述）/ models
  可选 custom_header / 可选 api_type: 'anthropic'（L117）
  ```

- `custom_header` 示例（Anthropic，L136-145）：

  ```
  anthropic-version: 2023-06-01
  anthropic-dangerous-direct-browser-access: true
  ```

- 内置模型列表只有 OpenRouter/HuggingFace/MiniMax 带条目（带 `capabilities`，如 `['completion','tools']`）；
- 预定义远程 provider 在详情页**隐藏设置卡片**（`$providerName.tsx` L826-941），api-key 交由顶部 key 区。

### 1.2 自定义 provider

`AddProviderDialog.tsx`：四字段 name/baseUrl/apiKey/apiType（默认 openai，L36）；`URL_PATTERN = /^https?:\/\/[^\s]+$/i`（L26）；`handleCreate` 仅做必填 + URL 正则校验，**无连接测试、无 key 校验**。

`CreateProvider`（`index.tsx` L42-87）：重名忽略大小写判重并 toast（L49-52）；`apiType==='anthropic'` 时用 `anthropicProviderSettings` 模板、否则用 `openAIProviderSettings` 模板深拷贝（L55-58），再注入 base-url/api-key（L60-66）；新 provider 对象（L67-75）：

```text
{provider, active: true, models: [], settings, api_key, base_url, api_type（仅 anthropic 写入）}
```

### 1.3 设置 UI 列表页

`routes/settings/providers/index.tsx`：全局开关“从上下文剥离 reasoning”`stripReasoningFromContext`（L34-39）；列表按 `IS_MACOS || provider !== 'mlx'` 过滤 mlx（L142）；llamacpp 停用时显式 `stopAllModels()`（L182-187）；每 provider 卡片显示模型数 + 激活开关（L142-197）。

## 2. API key 管理

### 2.1 主 key + fallback 链

`web-app/src/lib/provider-api-keys.ts`：

- 设置键 `api-key-fallbacks`（L1），多行字符串序列化；
- `providerRemoteApiKeyChain(provider)`（L18-33）返回去重保序的 `[主 api_key, ...fallbacks]`；
- `providerHasRemoteApiKeys` 判断任一 key。

### 2.2 多行草稿区与提交

`$providerName.tsx` L261-497：

- 草稿装载（L268-273）：非 llamacpp/mlx 才装载，`providerRemoteApiKeyChain(provider).join('\n')`；
- `commitApiKeysDraft`（L295-356）：按行分割 → 首行主 key、其余 fallbacks；主 key 写回 settings `api-key`，fallbacks 写回 `api-key-fallbacks` 设置项（不存在则 push password 型 controller）；**仅当主 key+fallbacks 全为空才调 `deleteProviderKeys`（清 keyring）**（L350-355）；
- 多行 UI：`setPrimaryKeyDraft/addKeyLine/removeKeyLine`（L365-387），首行不可删（L383-386）。

### 2.3 连接测试

`handleTestApiKeys`（L426-496）：逐 key 对 `${base_url}/models` 发 GET；**同时发 `x-api-key` 与 `Authorization: Bearer` 双头**（L452-455）；localhost/127.0.0.1 时额外带 `Origin: tauri://localhost`（L458-461）。状态映射（L464-489）：

```text
200 → ok；401 → unauthorized；403 → forbidden；429 → rate_limited；其他异常 → network_error
```

### 2.4 轮换与 keyring

- `createApiKeyRotatingFetch`（model-factory.ts:740-782）：apiKeys>1 时 401/403/429 换下一把；
- `useModelProvider.ts` L13 注释：远程 key 的 secrets 只在 OS keyring（`register_provider_config`），绝不落 settings.json；
- `DataProvider.tsx` `registerRemoteProvider`（L38-59）：llamacpp 跳过；无 API key 跳过；请求骨架 `{provider, api_key: chain[0], api_keys: chain.slice(1), base_url, custom_headers, models}`；mount 时 `invoke('register_provider_config')`、unmount `unregister_provider_config`；
- 旧 localStorage 数据迁移 `migrateLocalStorageSettings.ts`（L97）时也 invoke 注册。

## 3. 参数体系：predefinedParams.ts

`web-app/src/lib/predefinedParams.ts`（595 行）：

### 3.1 ParamDef 结构

`ParamControllerType`（L11-16）：slider/dropdown/textarea/input/checkbox。
`SamplerCap`（L18-36）能力标签清单：

```text
core / client_only / top_k / min_p / repetition / penalties / json_schema / mirostat /
typical_p / top_n_sigma / dynatemp / xtc / dry / grammar / sampler_order /
backend_sampling / ignore_eos / thinking_budget
```
`ParamDef`（L51-62）字段：

```text
key / title / description / value / controllerType / controllerProps / capability / effectHint / disabledBy
```

`disabledBy` 返回非空字符串即解释禁用原因。

### 3.2 paramsSettings 默认值（L70-392，节选）

| key | 默认值 | 控件 | capability | disabledBy |
|---|---|---|---|---|
| temperature L108 | 0.8 | slider 0–2 | core | — |
| top_p L118 | 0.95 | slider 0–1 | core | temperature==0 或 mirostat>0 |
| top_k L134 | 40 | slider 0–200 | top_k | 同上 |
| min_p L149 | 0.05 | slider 0–1 | min_p | mirostat>0 |
| frequency_penalty L160 | 0 | slider -2..2 | penalties | — |
| presence_penalty L169 | 0 | slider -2..2 | penalties | — |
| repeat_penalty L178 | 1.0 | slider 1–2 | repetition | — |
| mirostat L188 | 0 | dropdown | mirostat | — |
| mirostat_tau/eta | 5.0/0.1 | slider | mirostat | mirostat==0 |
| grammar L226 | '' | textarea | grammar | — |
| json_schema L235 | '' | textarea | json_schema | — |
| typical_p/top_n_sigma | 1.0/-1.0 | slider | typical_p/top_n_sigma | — |
| dynatemp_range/exp | 0.0/1.0 | slider | dynatemp | range==0 |
| xtc_probability/threshold | 0.0/0.1 | slider | xtc | prob==0 |
| dry_multiplier/base/… | 0.0/1.75/… | slider/input | dry | multiplier==0 |
| ignore_eos L346 | false | checkbox | ignore_eos | — |
| repeat_last_n L354 | 64 | input | repetition | — |
| samplers L364 | — | input 逗号分列 | sampler_order | — |
| backend_sampling L374 | false | checkbox | backend_sampling | — |
| thinking_budget_tokens L382 | -1 | input | thinking_budget | — |

另：`SAMPLER_DEFAULT_KEYS`（L399-408）是模型编辑对话框暴露的每模型默认采样键，持久化到 model.yml/router preset，并作为本地 API server 默认值；`MLX_SAMPLER_KEYS`（L412-416）仅 temperature/top_p/repeat_penalty 三项（mlx-server 只转发这三个）；`LLAMACPP_ONLY_PARAM_KEYS`（L442+）为 llama.cpp 私有点（wire 层跳过）。

## 4. providerCaps.ts：能力表与决策函数

`web-app/src/lib/providerCaps.ts`（308 行）：

- `ProviderCaps`（L17-22）：`supported`（原样转发）/`maybe`（转发但 UI 提示可能忽略）；`CORE_ONLY = {core, client_only}`（L24）恒注入（L26-27）。
- 内置能力表 `BUILTIN_CAPS`（L148-164）：

| provider | supported | maybe |
|---|---|---|
| openai L29 | penalties, json_schema | ∅ |
| azure L84 | penalties, json_schema | ∅ |
| anthropic L34 | top_k | ∅ |
| gemini/google L39 | top_k, min_p, repetition, penalties | ∅ |
| cohere L44 | top_k, penalties | ∅ |
| mistral L49 | penalties | ∅ |
| groq L54 | ∅ | penalties |
| openrouter L59 | penalties, top_k, min_p, repetition | typical_p |
| xai L64 | ∅ | penalties |
| huggingface L69 | penalties | top_k, min_p, repetition, typical_p |
| nvidia L79 | penalties | top_k |
| minimax L89 | penalties | ∅ |
| llamacpp L94 | penalties + 全套 llama 私有 | ∅ |
| mlx L116 | top_k, repetition | ∅ |
| 自定义 CUSTOM_PERMISSIVE L126 | ∅ | 全部采样参数 |

- `resolveProviderCaps`（L166-174）：`api_type==='anthropic'` → ANTHROPIC，否则按 provider ID 查表，未命中 → CUSTOM_PERMISSIVE；
- `getProviderApiType`（L177-183）：未配置 → 'openai'；`provider.api_type` 优先；否则 provider==='anthropic' → anthropic；
- `isPredefinedRemoteProvider`（L193-199）：`id in BUILTIN_CAPS && ∉ {llamacpp,mlx}`；
- 模型级拒绝（L212-273）：`REASONING_MODEL_RE = /^(o[1-9]|gpt-?[5-9])/i` 匹配的 openai/azure 推理系硬拒 temperature/top_p/frequency_penalty/presence_penalty；
- xai 系列：`grok-3-mini` 拒 temp/top_p、`grok-[3-9]` 拒 penalties；
- 判定按“参数 key”而非 capability（注释 L217-221）；
- `getMutualExclusionDrops`（L229-241）：唯一规则——anthropic 同时带 temperature+top_p 时保留 temperature、丢 top_p；
- `paramsForProviders`（L288-307）：并集得到 `ParamSupportEntry{def, supportedBy[], maybeBy[]}` 供 UI tooltip。

## 5. 模型创建与参数注入

### 5.1 createCustomFetch（model-factory.ts:366-535）

`buildBody`（L401-444）过滤顺序：

1. `CLIENT_SIDE_PARAM_KEYS`（L198-202）：ctx_len/max_context_tokens/auto_compact 永不发送；
2. `!keepLlamacppOnly` 时剥 `LLAMACPP_ONLY_PARAM_KEYS`；
3. `WIRE_KEY_REMAP`（L385-388）：`max_output_tokens→max_tokens`、`dynatemp_exp→dynatemp_exponent`；
4. 数值字符串强转（`coerceNumericParam`）、samplers 逗号/分号切数组（`coerceSamplers`）。

llamacpp 专属（L423-440）：`cache_prompt=true`（防 KV 复用被 preset/CLI 覆盖）、`stream===true` 时 `return_progress=true` + `timings_per_token=true`、`max_tokens===0 → -1`（用户 0 表示无上限）。

恢复逻辑：

- llama.cpp 500 无 JSON body → 合成 “The model crashed and is being reloaded. Please retry.” 错误响应（L506-523）；
- 上游报采样参数不支持（`isSamplingParamRejection`，L284-295 正则）→ 去参重试一次并 toast（L527+）。

SSE 过滤（L474-484）：`filterNamedSseEvents` 仅 OpenAI 兼容流过滤非标准命名事件；Anthropic/OpenAI Responses 用命名事件作协议不过滤。

### 5.2 上游 body 组装（Rust）

`proxy.rs` `upstream_converter.convert_request`（L2606-2613）按 api_type 重写上游 body；mlx 有 `model_param_defaults` 注入 `inject_sampling_defaults`（L2615-2631）——注释明确：llamacpp 走 router preset（不进此 bucket），远程 provider 有意不注入。

密钥轮换：`session_api_keys` 空 → `vec![None]`，否则逐 key（L2633-2637）。

## 6. 模型系统与下载链

### 6.1 模型对象

`core/src/types/model/modelEntity.ts` 的类型与关键字段：

```text
ModelInfo           {id, settings?, parameters?, engine?}
Model               object/version/format/sources/name/created/description/settings/parameters/metadata/engine
ModelSettingParams  ctx_len/ngl/embedding/n_parallel/cpu_threads/prompt_template/…
ModelRuntimeParams  temperature/max_tokens/stop/…
ModelMetadata.default_ctx_len / default_max_tokens（用于跨线程保留模型设置）
```

### 6.2 模型列表与刷新

`$providerName.tsx` `handleRefreshModels`（L523-621）：

- catalog 分支（`fetchTopRemoteModelsProvider`）与非 catalog（`fetchModelsFromProvider`）都把模型 ID 映射为 `{id/model/name=id, capabilities, version:'1.0'}`；
- catalog 分支保留 `imported` 标记模型，本次未命中的 `addDeletedModels(removedIds)` 加入删除集（L556-583）；
- 非 catalog 分支保留已存在模型只追加新 ID（L585-607）。

`AddModel.tsx`（148 行）：`useProviderModels`（API key 可选）；`getModelCapabilities(provider, id)` 自动推断（L54）；模型重复检查（L42-47）。

### 6.3 远程模型目录

`remoteModelCatalog.ts`（276 行）：

- `isAnthropicProvider`（L30-40）：api_type===anthropic 或以 provider 名/base_url 含 “anthropic”；
- `ensureAnthropicHeaders`（L54-65）：自动补 `anthropic-version` 与 `anthropic-dangerous-direct-browser-access: true`（webview Origin 豁免）；
- `supportsRemoteCatalog`（L84-88）：仅 openai/anthropic/gemini 或 api_type==='anthropic'；
- `fetchTopRemoteModels`（L196-232）：key 链逐个试；
- `normalizeCatalog`（L234-265）：按 ID 前缀启发式推断能力（gpt-4o→vision、claude-→vision/tools、embed/whisper→排除），TOP_N=10。

### 6.4 本地模型下载

- `llamacpp-extension` L3115 `proxy: await getProxyConfig()`（模型下载）；`backend.ts downloadBackend` 对每个下载子件附加 proxy；
- `download-extension/src/index.ts`：`downloadFile(s)` invoke `download_files`，proxy 以 `Record<string, string|string[]|boolean>` 透传，监听 `download-$id`；
- Rust `downloads/commands.rs`（L11-80）：`CancellationToken` 取消；`paused_tasks` 保留 `.tmp/.url` 断点续传，真正取消才删已下载部分；
- `models.rs`（L15-31）：`ProxyConfig{url, username?, password?, no_proxy?, ignore_ssl?}`；`DownloadItem{url, save_path, proxy?, sha256?, size?, model_id?}`；
- `helpers.rs`：镜像前缀 + `MIRROR_DOMAINS=['huggingface.co']` + HMAC 签名，并行下载 `DownloadCtx`。

### 6.5 模型源

`useModelSources.ts`：Hub 目录清单缓存写 localStorage（注释：非用户设置不重写 settings.json）；`fetchSources → fetchXml('/models')`；`sanitizeModelId` 处理 `quants.model_id`、`is_mlx = library_name==='mlx'`、非 macOS 过滤 mlx。

## 7. 本地引擎：llamacpp-extension

`extensions/llamacpp-extension/src/index.ts`（约 3,185 行）：

- 读取 `models/<modelId>/model.yml` 的模型配置；
- `resolveEmbeddingConfig`（L1420）：GGUF 元数据探测 embedding → 回写 `cfg.embedding` 与版本化缓存；embedding 模型默认补 `pooling` 与批量参数；
- `resolveMtpLayersConfig`（L1485）：MTP 层数探测；
- `PRESET_AFFECTING_KEYS`（L110）集合内的设置变化会通知 worker 重新应用 preset；旧版的防抖 router 重启与 `selfInflicted` 自激保护已不存在；
- 模型配置中 `quant_type: undefined` 为硬编码 TODO（L1397）。

引擎不再是运行机下载的后端二进制：它按编译期版本捆绑进随附 worker，扩展 `startEngine()`（L853-900）生成 preset 后由插件启动该 worker，握手返回 OS 分配的端口、pid 与 API key；worker 内部 registry 按需加载模型，并在容量已满时只淘汰空闲的最近最少使用 chat 模型（`index.ts:2297-2318` 的 `userModelsMax`/`loadedChatOrder`）。逐线程 KV 状态可按 thread_id 保存到磁盘、在身份校验通过时恢复，缓存预算（MiB）为零即关闭。进程实际生命周期、跨会话缓存命中率与淘汰时延均未运行验证（`src-tauri/plugins/tauri-plugin-llamacpp/src/engine/worker.rs`、`engine/registry.rs`、`engine/http.rs`、`engine/slots.rs`）。

`ModelConfig`（`src-tauri/plugins/tauri-plugin-llamacpp/guest-js/types.ts:104-116`）：

```text
model_path（必填，相对 <jan_data>）/ mmproj_path? / name / size_bytes / sha256? /
mmproj_sha256? / embedding? / template_kwargs? / template_kwargs_check_v?
```

另有 `ModelPlan`/`DownloadItem` 类型。

## 8. Rust server 与代理

### 8.1 路由表（proxy.rs，2,740 行）

| 路径 | 行为 |
|---|---|
| `POST /orchestrations` | `stream=true` 拒绝；缺 `messages` 报错（L1119-1200） |
| `POST /chat/completions`/`/messages/count_tokens` 等 | body 含 model 后解析上游（count_tokens 见 L1460） |
| `GET /v1/models` | 合并本地引擎与远程 provider 模型（L1714 起） |
| `GET /openapi.json` | include_str! 静态文件并替换 host/port（L1801） |
| Anthropic `/v1/messages` | 转发到本地 `/v1/messages`（L1068） |

### 8.2 代理链路

`proxy_request`（L637）按模型解析上游：本地引擎走 `engine_upstream`（L575），远程 provider 走从 `core/agent/上游层` 导入的 `call_openai_chat_completions`（`src-tauri/src/core/agent/upstream.rs:768`）并带 Bearer key 直连。编排辅助（`resolve_upstream_for_model` L403、`load_assistant_config` L41、`parse_openai_messages` L65、`repair_dangling_tool_calls` L146、`collect_mcp_openai_tools` L615、`execute_mcp_tool_calls` L680）已从 `proxy.rs` 移到 `core/agent/upstream.rs`。

`run_server_side_openai_orchestration`（`src-tauri/src/core/agent/loop.rs:1476`）服务端编排：`max_turns` 默认 8（`PROXY_DEFAULT_MAX_TURNS`，loop.rs:1528）。

### 8.3 转换器与流式转发

`converters.rs`：`converter_for`（L154）按 wire 协议分派，`OpenAIResponsesConverter`（L195）、`AnthropicMessagesConverter`（L886）、`GoogleGenerateContentConverter`（L547）完成双向转换与流式转发。

工具 schema 规范化已移到 `src-tauri/src/core/openai_schema.rs`（Tauri-free，与 CLI 的 agent upstream 共用）：

- `LLAMACPP_BROKEN_STRING_FORMATS = ["date","time","date-time"]`（L14）：GBNF 拒绝，静默禁用 tool-call；
- `normalize_openai_tool_parameters_schema`（L54）：description-only 叶子补 `type:"string"`、`object` 无 properties 补空、strip 不认识的 format 与含 PCRE 简写的 pattern，并递归进 properties/anyOf/oneOf/items/definitions；
- `normalize_openai_tools_in_chat_body`（L146）：批量规整 chat body 中的 tools。

### 8.4 认证（真实路径）

`proxy.rs:691` 起：非白名单路径且 `config.proxy_api_key` 非空时，校验 `Authorization: Bearer` 或 `X-Api-Key` 之一；包含 `/configs` 的路径直接 404（L892）。

### 8.5 服务端工具执行

`execute_mcp_tool_calls`（`core/agent/upstream.rs:680`）：串行执行，arguments 解析失败容错 `{}`，错误统一前缀 `"ERROR: "`；入口受配置项 `enable_server_tool_execution` 门控，默认 false（`proxy.rs:955,1497`）。

### 8.6 本地 API server 设置

`routes/settings/local-api-server.tsx`：

- 启动链（L130-178）：`ensureModelForServer`（无模型报错）→ `startServer({host, port, prefix, apiKey, trustedHosts, isCorsEnabled, isVerboseEnabled, proxyTimeout, enableServerToolExecution})` → 实际端口回写（移动端 port=0 自动分配）→ setServerStatus；
- 错误优先级（L180-216）：端口占用 > 模型路径 > 模型启动 > 通用；
- `useLocalApiServer.ts`（110 行）默认值：

  ```text
  serverPort：移动端 0，否则 1337（L61）
  apiPrefix: '/v1'；corsEnabled: true；proxyTimeout: 600；enableServerToolExecution: false
  persist 名 settingLocalApiServer，version: 3，迁移 v0/v1/v2（L88-107）
  ```

### 8.7 remote_provider_commands.rs / provider_secrets.rs

- `RegisterProviderRequest.api_type` 注释：openai 默认 / openai-responses / google / anthropic 触发相应转换器；
- `merge_register_api_keys`（L32-50）：trim 去重保序只留非空；
- `provider_secrets.rs` 对接 `state.rs` 的 `ProviderConfig` 与两命令 `ConfigModel`。

## 9. https 代理与硬件设置

### 9.1 https-proxy

`routes/settings/https-proxy.tsx` + `Settings.tsx` 目录：提供代理 URL、启用开关、用户名/密码、ignoreSSL 与 noProxy 等配置项；唯一挂点读取（llamacpp 下载 proxy + Rust downloads）。

### 9.2 hardware

`routes/settings/hardware.tsx`：GPU/CPU 配置写 provider settings（llamacpp 的 `ngl`/`cpu_threads` 等），经 `updateProvider` 生效；更改引擎设置后立即停止本地模型并刷新已加载模型（`$providerName.tsx:743-754`）。

## 10. 边界与未验证事项

1. **SecurityConfigDialog 是孤儿死代码**：【代码确认】src-tauri 全库 grep 无 `security_*` 命令，组件无挂载点（SettingsMenu 的 privacy 页只实现 analytics 开关）。与之对比的“真实认证”在 proxy.rs 的 `proxy_api_key` 双头校验。
2. **llama-server 鉴权强度**：【代码确认】`api_key = BASE64(HMAC-SHA256(key='JustAskNow', msg=modelId))`——密钥常量 `'JustAskNow'` 在 `extensions/llamacpp-extension/src/index.ts:424`，派生函数 `generate_api_key` 在 `src-tauri/utils/src/crypto.rs`；worker 握手返回的 `EngineInfo{port, api_key, pid}` 对 webview 可见。防局域网误连、不防本地恶意进程。
3. **参数链路分离**：绕过 `createCustomFetch` 的直连请求不带采样参数；`streamText` 层不感知推理参数。【代码确认】
4. **采样参数自动重试**基于错误文本正则启发式，命中误报时静默丢参重试一次。【代码确认 + 推测影响】
5. **`ProviderApiType` TS 类型仅 `'openai'|'anthropic'`**（`web-app/src/types/modelProviders.d.ts:62`），而 Rust 端承认 openai-responses/google 等更宽取值——TS 窄于可写 wire 值。【代码确认】
6. MLX 引擎（`extensions/mlx-extension`）仅确认 `MLX_SAMPLER_KEYS` 三项转发；mlx-server 具体行为未逐项核对。【推测】
7. 未运行项目测试或构建；记录来自静态源码。

## 11. 关键源码索引

| 领域 | 文件 |
|---|---|
| 预定义 provider | `web-app/src/constants/providers.ts:54-402` |
| 参数定义 | `web-app/src/lib/predefinedParams.ts` |
| llama.cpp worker、模型 registry 与 KV 状态 | `src-tauri/plugins/tauri-plugin-llamacpp/src/engine/worker.rs`、`engine/registry.rs`、`engine/http.rs`、`engine/slots.rs` |
| 能力表 | `web-app/src/lib/providerCaps.ts` |
| 参数注入 fetch | `web-app/src/lib/model-factory.ts:366-535` |
| API key 链/测试 | `web-app/src/lib/provider-api-keys.ts`、`$providerName.tsx:261-497` |
| provider 设置 UI | `web-app/src/routes/settings/providers/index.tsx`、`web-app/src/routes/settings/providers/$providerName.tsx` |
| 添加 provider | `web-app/src/containers/dialogs/AddProviderDialog.tsx` |
| provider 状态持久化与迁移 | `web-app/src/hooks/useModelProvider.ts:50-236,325-762`、`web-app/src/lib/backendStorage.ts:22-60`、`src-tauri/src/core/app/settings_store.rs:1-14,98-119` |
| 远程 provider 运行时注册 | `web-app/src/providers/DataProvider.tsx:38-144`、`src-tauri/src/core/server/remote_provider_commands.rs:15-195` |
| provider 密钥持久化 | `src-tauri/src/core/server/provider_secrets.rs:1-16,163-216` |
| Jan CLI | `src-tauri/jan-cli/src/main.rs`、`src-tauri/src/core/cli/providers.rs`、`src-tauri/src/core/cli/tui.rs`、`docs/src/pages/docs/agent/*` |
| 远程目录 | `web-app/src/lib/remoteModelCatalog.ts` |
| 本地 API server | `web-app/src/routes/settings/local-api-server.tsx`、`hooks/useLocalApiServer.ts` |
| 下载 | `extensions/download-extension/src/index.ts`、`src-tauri/src/core/downloads/commands.rs` |
| llamacpp 模型配置与引擎启动 | `extensions/llamacpp-extension/src/index.ts:853-900`（startEngine）、`:1420`（resolveEmbeddingConfig）、`:1485`（resolveMtpLayersConfig）、`:110`（PRESET_AFFECTING_KEYS） |
| 鉴权 key 派生 | 常量 `extensions/llamacpp-extension/src/index.ts:424`；函数 `src-tauri/utils/src/crypto.rs` |
| Rust 代理 | `src-tauri/src/core/server/proxy.rs:637-720`（proxy_request/engine_upstream/白名单）、`:858-892`（proxy_api_key 校验与 /configs 404） |
| 服务端编排与上游层 | `src-tauri/src/core/agent/loop.rs:1476`、`src-tauri/src/core/agent/upstream.rs:403,680,768` |
| schema 规整 | `src-tauri/src/core/openai_schema.rs:14,54,146` |
| server 命令 | `src-tauri/src/core/server/commands.rs`、`remote_provider_commands.rs`、`provider_secrets.rs` |
