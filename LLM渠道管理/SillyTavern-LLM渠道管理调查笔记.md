# SillyTavern LLM 渠道管理调查笔记

> 调查对象：`E:\works\GitStudyNotes\SillyTavern`
>
> 调查更新日期：2026-08-18
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读源码梳理；补查配置文件、Web 操作入口、CLI、TUI 和 Electron 边界；未修改目标仓库
>
> 调查范围：LLM 渠道数据模型、配置生命周期、配置文件、CLI/TUI/Web/Electron 操作覆盖、协议适配、模型目录、凭据、导入导出、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 没有用统一的数据库 Provider 表表示渠道。核心运行时仍以“主 API 类别 + 子类型/Provider + URL + 模型 + Secret”为一组全局活动设置：

```text
main_api
  -> chat completion source 或 text completion type
  -> Provider 专属 URL / 自定义 URL / reverse proxy
  -> Provider 专属 model 字段
  -> Secret 类型 + 可选 Secret ID
```

内置 Connection Manager 扩展在这组全局设置之上提供 Connection Profile。Profile 是一个可命名、可切换的配置快照，记录 API、URL、模型、Preset、Proxy 和 Secret ID 等字段。它让同一服务的多条渠道可以表达成多个 Profile，但不是一个带健康状态和调度策略的 Provider 池。

当前快照的关键结论：

- Chat Completion 有 26 个 `chat_completion_source`，Text Completion 有 15 个 `textgen_type`；
- Chat Completion 后端按 source 分支构造各家端点、Header、payload 和流式解析，Custom 路径兼容 OpenAI Chat Completions；
- Connection Profile 保存 API、URL、模型、代理和 Secret ID 等引用，可快速切换整套连接；
- Secret Manager 对同一种 Secret 支持多条带 UUID、标签和 active 状态的 Key；
- 新写入的 Key 会成为唯一启用项，也可以手动 rotate，Profile 还能显式固定某个 Secret ID；
- 多 Key 不会随机或轮询，不会因 401/429 自动切换，也没有失败计数、熔断和恢复；
- 普通聊天请求没有统一自动重试和指数退避，失败直接返回前端；
- `/profile-genstream` 专用命令在流式失败时会改成非流式再请求一次，但仍使用同一 Profile、模型和 Secret；
- 本地没有跨 Profile failover、权重、成本或延迟路由；
- OpenRouter 的模型 fallback 和 Provider order/allow_fallbacks 会作为参数交给 OpenRouter，实际切换发生在上游；
- Secret 以明文 JSON 保存到用户目录的 `secrets.json`，使用原子写入但没有字段加密或系统 Keychain；
- `settings.json` 的自动快照包含 Connection Profile、URL 和普通设置，但不包含独立 `secrets.json`；
- 全量用户 ZIP 默认排除 `secrets.json` 及 Secret 迁移备份，只有显式开启 `allowKeysExposure` 才把它们纳入归档；
- 状态检查主要调用 Provider `/models`，部分 Provider 只提示用 Test Message 验证；成功/失败只更新全局 UI 状态，不参与后续调度。
- 本次补查未找到独立的 CLI/TUI 渠道管理界面。CLI 只解析服务启动、网络、数据根目录和请求代理等参数；Electron 入口只启动同一 HTTP 服务并把 Web 页面装入窗口。
- Web 是当前源码中唯一直接提供渠道配置管理的界面：普通 API 设置通过设置页和 preset 操作，Connection Profile 提供查看、新建、编辑、更新、重新应用和删除，Secret Manager 提供查看掩码、新增、重命名、复制、人工启用和删除。
- 现有 Profile 可以更新和编辑，但没有 Profile 复制按钮；“新建 Profile”实际读取当前全局 API 设置生成快照，因此新建渠道与已有渠道不是同一层对象，也不存在把一个 Provider 实例复制成另一个独立 Endpoint 的后端 CRUD。

## 总体调用链

```text
用户选择 API / Connection Profile
  -> main_api
  -> CONNECT_API_MAP
       chat completion -> chat_completion_source
       text completion -> textgen_type
  -> URL + model + preset + secret_id
  -> 浏览器请求 SillyTavern 本地后端
  -> /api/backends/chat-completions/generate
       或 /api/backends/text-completions/generate
  -> 后端读取用户 secrets.json
       按 secret_id 取指定 Key，否则取 active Key
  -> Provider 分支构造 Endpoint / Header / Body
  -> 单次 fetch 上游
  -> 透传流或归一化 JSON
```

## 三类对象与平台边界

### 当前 API 设置、Connection Profile、Secret Manager 的区别

这三个对象分别处于活动状态、配置快照和凭据库三个层级，不能互相替代：

| 对象 | 实际载体 | 作用 | 是否代表独立渠道实例 |
|---|---|---|---|
| 当前 API 设置 | 用户 `settings.json` 中的 `main_api`、Provider 字段、URL、模型、Preset 和代理字段 | 当前页面和普通聊天请求实际读取的全局活动连接 | 否；同一 API/source 通常只有一套当前字段 |
| Connection Profile | `settings.json` 的 `extension_settings.connectionManager` | 将一组 API、URL、模型、Preset、代理、模板和 Secret UUID 保存为可命名快照 | 部分是；可表达多套连接组合，但没有独立后端实体、健康状态或调度策略 |
| Secret Manager | 用户目录的 `secrets.json`，按 Secret 类型保存带 UUID 的值数组 | 保存 API Key、服务账号 JSON、部分 URL/标识，并按 active 或指定 UUID 解析 | 否；它只保存凭据，不保存 Provider URL、模型或协议配置 |

Profile 的 `secret-id` 只是对 Secret Manager 条目的引用。Profile 删除不会删除对应 Secret；删除或迁移 Secret 也可能使 Profile 保留失效引用。当前 API 设置中的普通字段与 Profile 快照通过 slash command 逐项读写，Profile 不是独立的服务端连接记录（`public/scripts/extensions/connection-manager/index.js:215-248, 258-317, 392-434`）。

### 配置文件与默认值

- 部署级 `config.yaml` 由 `src/command-line.js` 读取并与命令行参数合并。它控制端口、监听地址、数据根目录、请求代理、认证、备份和 `allowKeysExposure` 等服务行为，不定义用户 Provider 实例列表，也不创建 Connection Profile。
- 用户 `settings.json` 由 `/api/settings/save` 原子写入；其中包含普通 API 设置、Provider 专属模型和 URL、preset 选择、代理预设以及 Connection Profile。服务端在启动、保存和定时流程中创建设置快照（`src/endpoints/settings.js:118-156, 206-216`）。
- 用户 Provider preset 是按 API ID 分目录保存的 JSON 文件。OpenAI preset 位于用户 `openAI_Settings` 目录，由 `/api/presets/save`、`/delete` 和 `/restore` 管理；preset 保存的是生成/连接字段子集，不是 Secret 文件，也不是 Profile（`src/endpoints/presets.js:16-36, 42-101`）。
- `secrets.json` 是用户目录独立文件，服务端 `SecretManager` 原子写入；默认设置和用户 preset 不会把 Secret 值自动合并进去。

### 配置入口操作矩阵

下表按源码能确认的入口记录操作。静态源码能够确认按钮、事件和 endpoint；未运行浏览器时不把保存成功、不同平台视觉表现或重启后的即时效果写成已验证事实。

| 入口/对象 | 查看 | 新增 | 编辑 | 复制 | 启停/切换 | 删除 | 导入 | 导出 | 连接测试 |
|---|---|---|---|---|---|---|---|---|---|
| 配置文件：`config.yaml` | 有，服务启动读取 | 可手工写入配置键 | 可手工编辑 | 未找到专用复制 | 有服务级开关，如代理、监听、备份；不是渠道启停 | 可手工删键，未找到渠道删除语义 | 未找到配置导入命令 | 未找到配置导出命令 | 不适用；只配置服务行为 |
| 用户 `settings.json` | 有，Web `/api/settings/get` 读取并加载 | Web 保存当前设置或 Profile 后写入 | Web 设置控件和快照恢复可改写 | 可通过文件复制/快照恢复，未找到渠道复制 API | 可切换 `main_api`、source/type、Profile；不是独立渠道 active 状态 | 可删字段或恢复旧快照，未找到 Provider 实例删除 API | 未找到通用 settings 上传恢复入口 | 设置快照可查看；全量 ZIP 可下载 | 由 Web 设置页调用 Provider status 或 Test Message |
| Web 当前 API 设置 | 有，Provider 连接设置页显示当前字段和状态 | 选择已有 source/type 并填写 URL、模型、凭据；没有“新建 Provider”表单 | 有，输入框、下拉框、开关和保存设置 | preset 的 `Save As` 可复制设置子集，未复制 Secret | 可切换 API/source/type；`online_status` 不是持久化启停状态 | 可删除 preset，不删除 Provider 代码项或 Secret | OpenAI preset 支持 JSON 文件导入，可选择移除代理/自定义端点字段 | OpenAI preset 支持 JSON 下载，可选择移除连接字段 | `/api/backends/.../status`、部分专用探测和 Test Message |
| Web Connection Profile | 下拉选择和详情按钮 | 从当前 API 设置新建命名 Profile | Update 记录当前设置；Edit 改名称和纳入字段 | 未找到专用复制按钮；可用 `profile-create` 以当前设置另建 | 选择或 reload 应用 Profile；无 active/disabled 字段 | 删除选中 Profile | 未找到 Profile JSON 导入入口 | 未找到 Profile JSON 导出入口；设置快照/全量 ZIP 间接包含 Profile | 应用 Profile 后重新连接；`profile-genstream` 使用指定 Profile |
| Web Secret Manager | 列出 ID、标签、active 和掩码；明文查看受配置限制 | 输入值和可选标签新增 | 只能重命名标签；未找到原值编辑，改值实际是新增 | 可复制 ID；明文复制值受 `allowKeysExposure` 限制 | rotate 人工指定某 UUID 为唯一 active | 按 ID 删除；删除 active 后首条剩余值 active | 未找到 Secret 专用导入入口 | 未找到 Secret 专用导出入口；全量 ZIP 默认排除 | 凭据被 status、Test Message 和实际请求使用 |
| CLI | 可查看 `--help` 和启动参数 | 未找到 Provider/Profile/Secret 新增命令 | 未找到 | 未找到 | 只能配置服务启动开关，不切换渠道 | 未找到 | 未找到 | 未找到 | 未找到渠道测试命令 |
| TUI | 未找到 TUI 实现 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 |
| Electron 桌面端 | 窗口中加载 Web 页面 | 复用 Web | 复用 Web | 复用 Web | 复用 Web | 复用 Web | 复用 Web | 复用 Web | 复用 Web |

### Web 当前设置与新建 Profile 的差异

当前 API 设置是单份全局可变状态。选择 source/type、填写 URL 或模型、写入 Secret 后，设置保存接口把整个设置对象写回用户 `settings.json`；普通聊天请求直接从这份状态构造请求。它能编辑连接字段，但不能把“同一 Provider 的多个 URL”作为多个后端实体列出来。

Connection Profile 的“新建”读取当前 `cc` 或 `tc` 模式下由命令列表定义的字段，要求用户输入唯一名称，然后把快照追加到 `extension_settings.connectionManager.profiles`。已有 Profile 的查看、Update、Edit、Reload 和 Delete 都在浏览器内操作该数组并调用设置保存；没有服务端 Profile endpoint。Edit 只改变名称和包含字段，若不点击带保存语义的 Update，当前设置变化不会自动重新抓取到 Profile（`public/scripts/extensions/connection-manager/index.js:769-882`）。

因此：

- 新建 Profile 不是新增 Secret，也不是新增 Provider 代码注册项；它只是把当前设置组合保存为另一个可应用快照。
- 已有 Profile 可以应用到当前全局设置，也可以更新快照，但应用不会创建新的运行时连接池成员。
- Web 没有 Profile 复制、JSON 导入或 JSON 导出按钮。可确认的间接迁移方式是 `settings.json` 快照或用户全量 ZIP；两者携带 Profile，但默认不携带 `secrets.json`。

### Preset 的导入、导出、复制边界

OpenAI 设置页的 preset 具有独立于 Profile 的文件生命周期：保存/更新通过 `/api/presets/save`，删除通过 `/api/presets/delete`，恢复内置默认 preset 通过 `/api/presets/restore`。`Save As` 是复制当前 preset 内容并以新名称保存，rename 实现为先保存新名称再删除旧名称（`public/scripts/preset-manager.js:441-517, 774-836`）。

OpenAI preset 导入读取本地 JSON；如果发现代理、自定义 URL、Header/Body 等敏感连接字段，会先让用户选择移除或按原样导入。导出也会提示是否移除这些字段，并另有选项删除连接数据。这里的“敏感字段”仍属于普通 preset JSON，不等于 Secret Manager 的 Key；源码未显示 preset 导入会自动写入 Secret Manager（`public/scripts/openai.js:4661-4742, 4744-4785`）。

## 1. 渠道数据模型

### 1.1 运行时设置不是 Provider 实体表

SillyTavern 的连接状态分散在用户 `settings.json` 的多个设置块中：

- `main_api`：Kobold、Horde、Novel、Chat Completion、Text Completion 等顶层模式；
- `oai_settings.chat_completion_source`：Chat Completion 的具体 Provider；
- `textgenerationwebui_settings.type`：Text Completion 的具体后端类型；
- 各 Provider 的模型字段、URL、端点变体和参数；
- `extension_settings.connectionManager`：Connection Profile 列表和当前选中 Profile；
- `proxies`：reverse proxy 预设及其密码。

这不是“一个 Provider 行拥有一组模型”的规范化数据模型。一个 source 通常只有一套当前活动设置；要保存多套组合，需使用 Connection Profile 把当前状态快照下来。

### 1.2 Chat Completion 与 Text Completion 双轨

[`public/scripts/openai.js`](../../SillyTavern/public/scripts/openai.js) 定义 26 个 Chat Completion source，包括 OpenAI、Claude、OpenRouter、Google AI Studio、Vertex AI、Mistral、Cohere、Groq、DeepSeek、xAI、Azure OpenAI、Custom 等。

[`public/scripts/textgen-settings.js`](../../SillyTavern/public/scripts/textgen-settings.js) 定义 15 个 Text Completion type，包括 Ooba、vLLM、Aphrodite、Tabby、KoboldCpp、llama.cpp、Ollama、OpenRouter、Hugging Face 和 Generic 等。

[`public/scripts/slash-commands.js`](../../SillyTavern/public/scripts/slash-commands.js) 的 `CONNECT_API_MAP` 把用户可见的 API 名称映射到：

| 字段 | 含义 |
|---|---|
| `selected` | 顶层 `main_api` |
| `source` | Chat Completion source |
| `type` | Text Completion type |
| `button` | 对应 UI 连接按钮 |

同名协议也可能有不同入口，例如 `openrouter` 走 Chat Completion，`openrouter-text` 走 Text Completion。

### 1.3 Connection Profile 是配置快照

[`public/scripts/extensions/connection-manager/index.js`](../../SillyTavern/public/scripts/extensions/connection-manager/index.js) 的 Profile 字段包括：

| 字段 | 作用 |
|---|---|
| `id` / `name` | UUID 与用户命名 |
| `mode` | `cc` 或 `tc` |
| `api` | Provider/API 类型 |
| `api-url` | Server URL、Custom URL 或端点变体 |
| `model` | 当前模型 |
| `preset` | 生成参数预设 |
| `proxy` | reverse proxy 预设名 |
| `secret-id` | 固定使用的 Secret UUID |
| `instruct` / `context` / `tokenizer` | Text Completion 相关模板 |
| `stop-strings` 等 | 生成与提示词相关设置 |
| `exclude` | 不纳入 Profile 的字段 |

创建 Profile 时，扩展通过 slash command 逐项读取当前设置；应用时再按固定命令顺序逐项写回全局状态。Chat Completion 会先设置 API，再应用 preset，最后再次设置 API，避免 preset 覆盖 source。

Profile 本身没有以下调度字段：

- 权重或优先级；
- 健康状态；
- 最大失败次数；
- 冷却截止时间；
- 成本或延迟统计；
- fallback Profile ID。

因此它是人工切换和脚本复用工具，不是自动渠道路由器。

## 2. Base URL、端点与 Header

### 2.1 Chat Completion 后端集中适配

[`src/endpoints/backends/chat-completions.js`](../../SillyTavern/src/endpoints/backends/chat-completions.js) 根据所选 Chat Completion 来源决定：

- 固定官方 Base URL；
- 用户填写的 Custom URL；
- Provider 支持时的 reverse proxy URL；
- Provider 专属认证 Header；
- `/models`、`/chat/completions` 或专属原生端点；
- payload 转换与流式解析。

OpenAI、OpenRouter、Custom 等路径最终调用 OpenAI 风格 `/chat/completions`；Claude、Google、Cohere、AI21、Mistral、Azure 等有专用处理函数或 URL 规则。

Custom source 支持：

- 自定义 Base URL；
- 自定义 Header YAML；
- 向请求 Body 合并字段；
- 从 Body 删除指定字段；
- Prompt post-processing；
- 可选 API Key。

Header 合并使用结构化对象/YAML 解析，而不是字符串拼接。自定义 Header 可能包含秘密，但它保存在普通设置中，不会自动进入 Secret Manager。

### 2.2 reverse proxy 是 Provider 当前设置

支持代理的 Provider 可把 `reverse_proxy` 作为 Base URL，把 `proxy_password` 作为请求凭据。UI 还支持命名 proxy preset。

Proxy preset 保存名称、URL 和密码，并进入 `settings.json`。这与 `secrets.json` 的 API Key 隔离机制不同：代理密码属于普通设置明文，也会进入设置快照和默认全量备份。

导入 OpenAI preset 时，代码会识别代理 URL、代理密码、自定义 URL、自定义 Body/Header 和 Azure URL 等敏感字段，提示用户是否删除；这是导入时的提醒，不是静态加密。

### 2.3 Text Completion 的附加 Header

[`src/additional-headers.js`](../../SillyTavern/src/additional-headers.js) 按 `TEXTGEN_TYPES` 为 Mancer、TogetherAI、vLLM、Aphrodite、Tabby、OpenRouter、llama.cpp 等生成 `Authorization`、`X-API-KEY` 等 Header。

部署者还可在 `config.yaml` 的 `requestOverrides` 中按 host 注入 Header。该配置是服务端部署配置，不属于某个用户 Profile，也没有本地按渠道权重选择的含义。

## 3. Secret Manager 与多 Key

### 3.1 同一种 Secret 可以保存多条值

[`src/endpoints/secrets.js`](../../SillyTavern/src/endpoints/secrets.js) 将每类凭据保存为数组：

```json
{
  "api_key_openai": [
    { "id": "uuid-1", "value": "sk-...", "label": "Primary", "active": true },
    { "id": "uuid-2", "value": "sk-...", "label": "Backup", "active": false }
  ]
}
```

写入新 Secret 时会先把同类所有条目标成 inactive，再把新条目标成 active。删除 active 条目后，如果仍有剩余条目，会把第一条设为 active。

读取逻辑是：

```text
请求带 secret_id
  -> 读取同 Secret 类型下匹配该 UUID 的值
否则
  -> 读取 active=true 的值
```

Connection Profile 可以记录 Secret ID，因此两个 Profile 可以使用同一 Provider 类型、不同 URL 和不同 Key，而不必反复切换全局启用的 Key。

### 3.2 rotate 是手工选择，不是自动轮询

前端 [`public/scripts/secrets.js`](../../SillyTavern/public/scripts/secrets.js) 提供新增、删除、重命名、查看掩码和 rotate。rotate 请求把指定条目设为唯一启用项，并触发重新连接。

源码中没有：

- random 或 round-robin；
- 请求前自动选下一 Key；
- 401、403、429 后自动 rotate；
- Key 级错误计数、余额和限额；
- 熔断、半开测试或自动恢复。

“保存多个 Key”只能证明支持 Key 库和人工切换，不能描述成多 Key 负载均衡。

### 3.3 客户端默认看不到明文

`/api/secrets/read` 返回每条 Secret 的 ID、标签、启用状态和掩码值。长度较长时只显示最后 3 个字符；较短值显示固定星号。

只有部署配置开启 `allowKeysExposure` 时，`/view` 和普通 `/find` 查询才允许返回明文；少数纯 URL 类型列在 `EXPORTABLE_KEYS` 中，即使不开启暴露也可读取。

这降低了浏览器侧意外展示 Key 的风险，但服务端磁盘上的 Secret 仍是明文。

## 4. 模型目录与模型选择

### 4.1 状态检查兼任模型拉取

Chat Completion 设置页调用 `/api/backends/chat-completions/status`。大多数 OpenAI 兼容 Provider 会请求：

```text
GET {apiUrl}/models
Authorization: Bearer {apiKey}
```

然后把响应中的模型数组保存到前端 `model_list`，再按 Provider 特性筛选、分组和排序。Workers AI、Azure 等有专用探测；Claude、AI21、Vertex AI、Perplexity、Z.AI、MiniMax 等 source 不做常规 `/models` 验证，只提示“Key 已保存，请用 Test Message 验证”。

Text Completion 也按 type 使用各自的模型拉取函数，例如 Ollama、vLLM、llama.cpp、OpenRouter 和 Generic。

### 4.2 模型字段随 Provider 分散保存

oai_settings 为不同 Provider 保存独立字段，例如：

- `openai_model`；
- `claude_model`；
- `openrouter_model`；
- `google_model` / `vertexai_model`；
- `custom_model`；
- `azure_openai_model`；
- 各聚合平台和厂商的专属 model 字段。

切换来源时，`getChatCompletionModel()` 从对应 Provider 字段取当前模型；Connection Profile 则把最终选定的 API 和模型固化为通用字段。

模型列表排序和分组只影响 UI。即使模型条目包含上下文、定价或 Provider 元数据，也没有本地调度器按成本或延迟自动选择模型。

### 4.3 `model_list` 是异构上游对象数组

[`public/scripts/openai.js`](../../SillyTavern/public/scripts/openai.js) 的全局 `model_list` 没有统一 schema。状态请求返回后，前端基本做浅拷贝并按 ID 排序；同一个概念会因 Provider 使用不同路径：

| 概念 | 实际读取示例 |
|---|---|
| 上下文 | `context_length`、`context_window`、`max_context_length`、`max_model_len`、`tokens`、`inputTokenLimit` |
| 输入/输出价格 | `pricing.prompt/completion` 或 `pricing.input/output` |
| 视觉 | `architecture.input_modalities`、`capabilities.vision`、`metadata.vision`、`features`、`input_modalities`、`supports_image_in` |
| 推理 | `metadata.reasoning`、`supported_features`、`capabilities.reasoning` |
| 工具 | `metadata.function_call`、`supported_features`、Provider 固定模型表 |
| Tokenizer | OpenRouter 的 `architecture.tokenizer` |

[`src/endpoints/backends/chat-completions.js`](../../SillyTavern/src/endpoints/backends/chat-completions.js) 作为服务端代理只做少量标准化：

- Google AI Studio：去掉 `models/` 前缀并保留原对象；
- Pollinations：把数组包装为 `{data}`；
- Chutes：把 `prompt/completion` 复制为 `input/output`；
- 其余 Provider：大多原样透传。

因此前端分支必须了解每家字段结构。

当前 Cohere 分支还有明显的代码顺序问题：通用路径先发送原始响应，随后才把 `data.models` 转成 `{id, ...model}` 形式的 `data.data`。这个转换不会进入已经发送的响应，前端能否正确加载 Cohere 模型取决于原始响应是否恰好符合后续预期。

### 4.4 元数据用于模型列表展示

SillyTavern 对富元数据利用最完整的是聚合平台选择器：

- OpenRouter 显示名称、context 和按 prompt 价格换算的 tokens/$；
- ElectronHub 显示输入/输出价格、context、视觉、推理、工具和 premium 标记；
- Chutes、NanoGPT 等按各自字段显示 context、价格和能力图标；
- 排序函数可按字母、context、输入价或输出价排序；
- 分组函数按模型 ID/Provider 规则分组。

价格还用于计算“当前最大 prompt + completion”的估算成本，但只是前端提示。它不读取真实账单、不处理缓存 token、阶梯价或按请求费用，也不参与自动路由。

### 4.5 上下文上限是动态字段加硬编码 fallback

模型切换时，SillyTavern 会按 Provider 调用不同的取最大上下文函数：优先读取模型列表中该 Provider 的 context 字段，缺失时再查本地模型 ID 映射，最后使用 8K、32K、128K 等 Provider 默认值。OpenRouter 例外地直接用 `context_length`，缺失时回退 128K。

随后 `openai_max_context` 会被裁剪到该上限。用户开启 `max_context_unlocked` 后可绕过元数据限制，说明 context metadata 是 UI 安全边界，不是不可突破的协议校验。

这套策略对新模型有较好兼容性，但 fallback 可能高估未知模型。高估会让客户端构建超长 prompt，最终由上游返回 context error；错误不会反向修正本地模型元数据。

### 4.6 能力元数据直接控制多模态与推理

图片、视频和音频的内联支持判断（见 [`public/scripts/openai.js`](../../SillyTavern/public/scripts/openai.js)）混合使用两种方式：有富模型目录的 Provider 读取实时条目，OpenAI、Claude、Gemini、Z.AI 等则匹配硬编码模型名。Custom Provider 默认允许图片输入。

因此“目录返回 vision=false/缺失”的含义不统一：某些 Provider 会真正关闭图片内联；另一些 Provider 完全不看目录而由模型名表决定。新模型常需要等项目更新硬编码表，或者使用 Custom 模式绕过保守判断。

ElectronHub 是少数用单模型元数据校验 reasoning effort 的分支：只有 `metadata.supported_reasoning_efforts` 包含当前档位才发送，否则删除该参数。其他 Provider 大多由设置和模型名逻辑决定，尚未形成统一的 per-model 参数支持矩阵。

OpenRouter 的 tokenizer 元数据还会选择 Llama、Mistral、Yi、Gemini、Qwen、Cohere 等本地 tokenizer；无法识别时再按模型 ID 启发式判断。错误 metadata 会影响 Token 估算和上下文裁剪，但不会改变实际 Provider。

### 4.7 缓存与持久化边界

模型列表是当前页面会话中的内存数组，切换 Provider 或刷新状态时替换。用户设置持久化的是各 Provider 的选中 model ID、排序/分组、context 和生成参数，而不是整份上游模型对象。

因此目录的新价格和能力在下次状态检查时自然更新，不会和旧 snapshot 合并；反过来，Provider 暂时不可达时也没有可复用的持久化富元数据。已有 model ID 仍可留在设置中，但 context、能力图标、成本估算和动态参数 gate 会退回硬编码或默认路径。

## 5. Adapter 与协议路由

### 5.1 source/type 决定 Adapter

Chat Completion 的前端把统一生成设置转为 `generate_data`，后端再按 source 进入不同处理路径。适配范围包括：

- Provider 原生 endpoint；
- OpenAI-compatible endpoint；
- Provider 特有认证与安全设置；
- system message/prefill/tool/schema 转换；
- SSE 或流式 JSON 解析；
- reasoning、image、tool call 等响应字段抽取。

Text Completion 则由后端类型决定 URL 规则、模型发现、模板能力和 Header。

这套路由是一请求一 Adapter：请求进来时 source/type 已确定，不会在错误后换到另一条 Adapter 分支。

### 5.2 ConnectionManagerRequestService 可直接按 Profile 发请求

[`public/scripts/extensions/shared.js`](../../SillyTavern/public/scripts/extensions/shared.js) 的 `ConnectionManagerRequestService.sendRequest()` 不必先永久切换整个 UI，就能读取指定 Profile 并构造请求：

- Chat Completion 传 `source`、`model`、`api-url`、`secret-id` 和 Proxy；
- Text Completion 传 `type`、`model`、`api_server` 和 `secret-id`。

这是插件、slash command 和后台功能复用 Profile 的重要接口，但调用方一次仍只提供一个 Profile ID。

## 6. 重试、故障转移和路由

### 6.1 普通聊天没有统一自动重试

[`public/scripts/openai.js`](../../SillyTavern/public/scripts/openai.js) 的 `sendOpenAIRequest()` 对本地后端只执行一次网络请求；后端 Provider 分支对上游也通常只执行一次，非 2xx 或业务错误被返回给前端。

源码没有统一的：

- 最大重试次数；
- 429/5xx/网络错误分类；
- Retry-After 支持；
- 指数退避和抖动；
- 失败后换 Secret/Profile/Provider。

`public/script.js` 中出现的 `MAX_RETRIES = 3` 只用于等待临时 Response Length 覆盖结束后再次保存设置，与 LLM 请求重试无关。

### 6.2 流式降级是一个局部例外

Connection Manager 的 `/profile-genstream` 命令先请求流式响应；如果流式失败且不是用户主动取消，会隐藏流式显示，再用同一 Profile 发一次非流式请求。

它属于“传输模式降级”：

- Provider 不变；
- 模型不变；
- Base URL 不变；
- Secret ID 不变；
- 不按状态码区分是否值得重放。

因此不能称为渠道 failover，也不能代表普通聊天统一具有一次 retry。

### 6.3 OpenRouter fallback 属于上游路由

选择 OpenRouter 时，SillyTavern 可传：

- `route: fallback`：允许替代模型 route；
- `provider.order`：指定上游 Provider 顺序；
- `provider.allow_fallbacks`：指定 Provider 不可服务时是否允许替代；
- `provider.quantizations`：限制量化类型。

这些字段由 [`src/endpoints/backends/chat-completions.js`](../../SillyTavern/src/endpoints/backends/chat-completions.js) 原样加入 OpenRouter 请求 Body。真实模型/Provider 选择、健康判断和重试发生在 OpenRouter 服务端。

因此，SillyTavern 暴露的是 OpenRouter 路由控制面，本地并未实现跨 Provider failover。NanoGPT 的 `X-Provider` 等设置也属于向聚合上游传递偏好。

### 6.4 没有本地权重、成本或延迟路由

Connection Profile 选择是人工操作或调用方显式传 Profile ID。当前源码没有根据以下指标选择 Profile：

- 最近延迟；
- 错误率；
- Token 单价；
- Key 余额或剩余配额；
- 模型上下文适配度；
- 用户定义权重。

## 7. 凭据存储、导入与备份

### 7.1 `secrets.json` 是明文文件

每个用户目录有独立 `secrets.json`。Secret Manager 使用 `write-file-atomic` 原子写入格式化 JSON，但没有：

- AES/DPAPI/Keychain 加密；
- 主密钥包封；
- Secret 值哈希以外的不可逆保护；
- 文件内容级访问审计。

因此文件系统权限和用户数据目录隔离是主要保护边界。能读取该文件的进程或备份持有者可以直接得到所有 API Key。

旧版平面格式迁移到数组格式前，会把原文件复制到 `backups/secrets_migration_<timestamp>.json`，该迁移备份同样是明文。

### 7.2 `settings.json` 与自动 snapshot

[`src/endpoints/settings.js`](../../SillyTavern/src/endpoints/settings.js) 将用户设置原子写入 `settings.json`，并在启动和设置保存流程中创建：

```text
backups/settings_<handle>_<timestamp>.json
```

默认每类保留 50 份，重复内容可跳过。设置 snapshot 可列出、查看和恢复。

Connection Profile 存放在扩展设置块中，因此会进入 `settings.json` 和设置快照；Secret 值位于单独的 `secrets.json`，不会进入设置快照。Profile 里的 Secret UUID 只有和对应 Secret 文件一起恢复才有意义。

Proxy password、自定义 Header、reverse proxy URL 等普通设置可能进入设置快照，不能因为 API Key 被拆到 Secret Manager 就把整个设置文件视为无敏感信息。

### 7.3 全量 ZIP 默认排除 Secret

[`src/users.js`](../../SillyTavern/src/users.js) 的 `createBackupArchive()` 归档整个用户根目录，但默认 `allowKeysExposure` 未开启时，会排除 `secrets.json` 及 Secret 迁移备份两类文件。只有部署者开启该开关，完整备份才包含这些文件；`backups.allowFullDataBackup` 则单独控制用户能否请求全量 ZIP。

这带来明确的恢复取舍：

- 默认全量 ZIP 可恢复 Profile 和普通连接设置，但不能恢复 API Key；
- 开启 Key 暴露后 ZIP 可完整迁移凭据，但归档本身含明文 Key，必须按密钥材料保护；
- 设置 snapshot 不是 Secret 备份；
- 当前用户 API 提供全量下载，未见对任意 ZIP 进行对称“上传并恢复”的同级自动入口，恢复主要依赖部署/文件操作或具体导入功能。

## 8. 连接检测与可观测性

### 8.1 状态检查是即时 UI 状态

Chat Completion 的 `getStatusOpen()` 会：

1. 校验 Custom/Azure URL；
2. 可选验证 reverse proxy；
3. 请求本地 `/status`；
4. 后端取当前 active Secret；
5. 请求上游模型目录或专用探测；
6. 更新全局 `online_status` 和模型列表。

部分 Provider 明确跳过模型验证，只显示“Key 已保存，请发送 Test Message”。Azure 会先 GET models，再对 deployment 发送一个最多 5 token 的最小 Chat Completions 探测。

用户也可用 Test Message 发送 `Hi` 验证实际生成路径。

### 8.2 检测结果不形成调度状态

`online_status` 是当前连接的前端状态，不是按 Profile/Secret 持久化的健康表。切换 Profile 后会重新连接，但系统不记录：

- 每条 Profile 最近成功时间；
- 连续失败次数；
- P50/P95 延迟；
- Key 级 429 或余额耗尽；
- 熔断截止时间；
- 调度权重。

日志主要是浏览器 console、服务端 console 和错误响应；没有在渠道层汇总 token、成本与延迟的内置观测面板。

## 9. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| 多 Provider/后端 | 有 | 26 Chat source + 15 Text type |
| 多连接实例 | 有 | Connection Profile 快照 |
| 自定义 Base URL | 有 | Custom、Text backends、reverse proxy |
| 自定义 Header | 有 | Custom YAML + 部署级 requestOverrides |
| 多协议 Adapter | 有 | source/type 分支 |
| 远程模型目录 | 有 | `/models` 或 Provider 专用 API |
| 模型手工选择 | 有 | Provider 专属字段或 Profile model |
| 多 Key 存储 | 有 | 同 Secret 类型的带 ID 数组 |
| Key 标签/启停 | 有 | label + 唯一 active |
| Key 随机/轮询 | 无 | 只读指定 ID 或 active |
| 失败自动换 Key | 无 | rotate 为人工操作 |
| Key 熔断/恢复 | 无 | 无健康状态 |
| 普通请求自动重试 | 无 | 单次 fetch |
| 流转非流降级 | 局部有 | 仅 `/profile-genstream` |
| 本地跨 Profile failover | 无 | 调用方显式选择 |
| 上游路由控制 | 有 | OpenRouter route/provider 参数 |
| 权重/成本/延迟路由 | 无 | 无本地调度器 |
| Secret 静态加密 | 无 | `secrets.json` 明文 |
| 设置自动备份 | 有 | 不含独立 Secret 文件 |
| 默认全量备份凭据 | 无 | 默认排除 Secret |
| 连接测试 | 有 | `/models`、专用探测、Test Message |
| 健康结果参与调度 | 无 | 仅当前 UI 状态 |

## 10. 对其他项目的可借鉴点

### 值得借鉴

- Connection Profile 把 API、URL、模型、Preset、模板和 Secret 引用组合成一键切换单元；
- Secret 使用稳定 UUID 和标签，Profile 可以固定非 active Key；
- 浏览器默认只拿掩码、标签和 ID，明文暴露由服务端开关控制；
- Chat 与 Text Completion 明确分轨，再由映射表统一用户入口；
- Custom API 支持结构化 Body/Header 合并和排除，兼容面较强；
- 对导入 preset 中的 URL、Header 和 password 做显式敏感字段提示；
- 默认全量备份排除明文 Secret，避免普通导出静默携带 API Key；
- 将 OpenRouter 的 Provider order/fallback 暴露为上游控制参数，而不在客户端重复实现其路由器。

### 需要补强或谨慎复用

- Profile 是设置快照，缺少规范化 Provider 实体和模型关联；
- 多 Key 只有人工 active 切换，不具备分摊和故障恢复；
- API Key、迁移备份均为磁盘明文；
- Proxy password 和自定义 Header 留在普通设置，敏感数据边界不统一；
- 通用请求没有重试分类、退避和 Retry-After；
- 状态检查结果不能反哺 Profile/Key 调度；
- 默认全量备份恢复 Profile 后会留下失效的 Secret ID 引用，需要单独迁移 Key；
- 上游聚合服务的 fallback 不应误记为本地渠道容灾。

## 11. 未验证事项

- 本次未运行 SillyTavern Web 页面，因此按钮点击后的实际浏览器提示、网络失败时的交互、保存时序和不同浏览器表现未验证；表格中的操作覆盖来自静态 HTML、事件绑定和请求代码。
- 本次未对 Electron 打包产物运行验证；源码只确认 `src/electron/index.js` 在服务启动后创建 `BrowserWindow` 并加载服务 URL，桌面端操作是否存在额外菜单、权限或打包配置未确认。
- 本次未找到独立 TUI 实现，但未对所有可选插件、用户脚本或外部启动器进行运行时扫描；“未找到”限于当前代码快照和仓库内入口。
- 普通 API 设置中每个 Provider 的具体连接字段、状态探测和导入导出差异并非完全同构；本文以 OpenAI Chat Completion、Text Completion、Connection Profile 和 Secret Manager 的共用入口为主，未逐一运行全部 Provider。
- 全量 ZIP 的下载权限、用户账号模式和部署配置组合未运行验证；凭据排除结论来自 `createBackupArchive()` 的静态路径。

## 12. 关键源码索引

- Chat Provider 与设置：[`public/scripts/openai.js`](../../SillyTavern/public/scripts/openai.js)
- Text Provider 与设置：[`public/scripts/textgen-settings.js`](../../SillyTavern/public/scripts/textgen-settings.js)
- API 映射：[`public/scripts/slash-commands.js`](../../SillyTavern/public/scripts/slash-commands.js)
- Connection Manager：[`public/scripts/extensions/connection-manager/index.js`](../../SillyTavern/public/scripts/extensions/connection-manager/index.js)
- Profile 请求服务：[`public/scripts/extensions/shared.js`](../../SillyTavern/public/scripts/extensions/shared.js)
- Chat 请求客户端：[`public/scripts/custom-request.js`](../../SillyTavern/public/scripts/custom-request.js)
- Chat 后端 Adapter：[`src/endpoints/backends/chat-completions.js`](../../SillyTavern/src/endpoints/backends/chat-completions.js)
- Text 后端 Adapter：[`src/endpoints/backends/text-completions.js`](../../SillyTavern/src/endpoints/backends/text-completions.js)
- 追加 Header：[`src/additional-headers.js`](../../SillyTavern/src/additional-headers.js)
- Secret 服务端：[`src/endpoints/secrets.js`](../../SillyTavern/src/endpoints/secrets.js)
- Secret 前端：[`public/scripts/secrets.js`](../../SillyTavern/public/scripts/secrets.js)
- CLI 参数与配置合并：[`src/command-line.js`](../../SillyTavern/src/command-line.js)
- Electron 启动包装：[`src/electron/index.js`](../../SillyTavern/src/electron/index.js)
- Preset 文件 API：[`src/endpoints/presets.js`](../../SillyTavern/src/endpoints/presets.js)
- 设置与 snapshot：[`src/endpoints/settings.js`](../../SillyTavern/src/endpoints/settings.js)
- 全量用户备份：[`src/users.js`](../../SillyTavern/src/users.js)
- 全量备份入口：[`src/endpoints/users-private.js`](../../SillyTavern/src/endpoints/users-private.js)
- 默认备份/暴露配置：[`default/config.yaml`](../../SillyTavern/default/config.yaml)
