# Risuai LLM 渠道管理调查笔记

> 调查对象：`E:\works\GitStudyNotes\Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：只读源码梳理，覆盖模型目录、请求层、存储层、网络层、设置 UI 与 Node/Tauri 后端；未运行应用；调查时工作树干净
>
> 调查范围：渠道实体模型、配置创建与持久化、凭据存储与传递、模型目录、协议 Adapter 与请求组装、运行时选择、重试与 fallback、连接检测与可观测性；不包含消息与上下文构建（对话请求类目）、模型选择器的聊天工作流（Chat UI 类目）与角色配置
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 没有 Provider 实体表或渠道实例对象。`Provider` 只是模型元数据上的枚举分类，`渠道`由"模型 ID + 若干全局设置字段"组合表达，`Endpoint` 被硬编码进模型条目或由用户级 URL 字段承载，`凭据`全部明文存放在唯一的全局 `Database` 对象中。多连接通过复制模型条目或创建自定义条目表达。

当前快照的关键结论：

- 模型目录是"静态表 + 启动时动态注册 + 设置页实时拉取"三层：内置模型写在 `LLMModels` 数组，启动时按开关拉取 Google/Anthropic/OpenAI 目录合并，设置页再按需拉取 OpenRouter、NanoGPT、Ollama、Horde 目录；远端结果不持久化；
- 协议适配集中在请求层的格式分发：`LLMFormat` 枚举的每个值对应一个 Adapter 函数，OpenAI 兼容协议是主干，Custom API（`reverse_proxy`）可切换格式以复用 Anthropic/Gemini/Responses 等 Adapter；
- 凭据以明文字符串存于 `database.bin`（Tauri）或 IndexedDB（Web），UI 仅提供开关控制的输入掩码；请求日志、云同步与备份都会携带完整凭据；
- 失败处理分三层：同模型重试（`requestRetrys` 默认 2）、按任务模式分离的模型 fallback 候选链、工具调用链重试；没有多 Key、Key 轮换、熔断或健康状态，也没有健康感知的跨渠道 failover；
- 没有独立的连接测试入口；设置页实时加载模型目录与请求体预览（Preview Body）承担验证作用，请求日志（20 条内存记录）是主要的可观测手段。

## 术语定义

调查前先按项目实际含义定义概念，避免与横向对比术语混用：

| 术语 | Risuai 中的含义 |
|---|---|
| Provider | `LLMModel.provider` 上的枚举分类（`LLMProvider`），是模型目录的标签，不是用户可创建或启停的实体 |
| 渠道 / Endpoint | 无独立实体。由模型 ID 决定协议与默认 URL，用户级 URL 字段（`forceReplaceUrl`、`customModels[].url`、`ollamaURL` 等）覆盖端点；同一 Provider 多连接靠多个模型条目表达 |
| 模型 | `LLMModel` 条目（ID、Provider、格式、能力 flags、参数、Tokenizer、内部 ID、endpoint、keyIdentifier），是选择与请求构造的最小单位 |
| 凭据 | `Database` 中的字符串字段（API Key、Token、Header 值等），无独立存储 |
| Profile | `botPresets` 中的命名配置快照，可保存/切换/导入/导出，导出时清空 Key 与 URL |

## 总体调用链

```text
用户发送 -> process/index.svelte.ts 组装 formated 消息
  -> requestChatData(arg, 'model')
       fallback 链循环：fallbackModels['model'] + 末尾 ''（同模型重试）
  -> requestChatDataMain
       由 modelInfo.format 分发到 Adapter
  -> requestOpenAI / requestClaude / requestGoogleCloudVertex
     / requestOoba / requestOllama / requestHorde / requestPlugin ...
  -> globalFetch / fetchNative 平台路由
       Tauri: invoke streamed_fetch（Rust 发起 HTTP）
       Web:   自托管或 hub 的 /proxy2 转发（risu-url / risu-header）
       或:    plain fetch / local_network 直连
  -> 流式或 JSON 响应 -> 解析 -> 消息落库
```

## 1. Provider、渠道与 Endpoint 数据模型

`LLMProvider` 枚举共 17 个值（OpenAI、Anthropic、GoogleCloud、VertexAI、AsIs、Mistral、NovelList、Cohere、NovelAI、WebLLM、Horde、AWS、DeepSeek、DeepInfra、Echo、NanoGPT、Ollama），定义在 `src/ts/model/types.ts:34-53`。OpenRouter、Ooba、Kobold、NovelList、Plugin、Custom API 等不占用独立枚举值，统一标记为 `AsIs`，说明该枚举是模型分类标签而不是渠道注册表。每个 `LLMModel` 条目携带 provider、format、flags、parameters、tokenizer、internalID、endpoint、keyIdentifier 等字段（`types.ts:104-118`），其中 `format` 决定协议 Adapter，`endpoint` 可覆盖默认请求 URL，`keyIdentifier` 决定从 `OaiCompAPIKeys` 取哪一把 Key。

多端点表达方式有三种：

- 内置条目复制：构建 `LLMModels` 时自动为每个 OpenAI 兼容模型生成 `-response-api` 变体、为每个 Google 模型生成 `-vertex` 变体（`src/ts/model/modellist.ts:586-611`）；
- Custom API 单例：模型 ID `reverse_proxy` 使用全局字段 `forceReplaceUrl`（Base URL）、`customAPIFormat`（协议格式）、`customProxyRequestModel`、`proxyKey`（`modellist.ts:558-567`）；
- 自定义模型数组：`db.customModels` 的每条记录以 `xcustom:::<uuid>` 为 ID，携带独立 url、key、format、tokenizer、flags、params，在设置页增删改（`src/lib/Setting/Pages/Advanced/CustomModelsSettings.svelte:174-188`）。

插件模型是第四类：插件调用 `addProvider` 注册回调后，自动生成 `pluginmodel:::<name>` 条目进入 `customV3ProviderMetaStore`（`src/ts/plugins/apiV3/v3.svelte.ts:679-705`）。同一 Provider 实例（如一个 OpenRouter 账号）不能创建多条独立连接，只能通过 `customModels` 或 `reverse_proxy` 条目另起；内置 Provider 条目是全局单例。

## 2. 配置创建、持久化与迁移

全部配置（含凭据）是唯一的 `Database` 对象，由 `setDatabase()` 在加载时对缺失字段逐个补默认值并执行字段级迁移（`src/ts/storage/database.svelte.ts:30-722`），"默认配置"与"用户配置"的合并就是这次启动补齐，没有独立的默认配置层。

持久化使用自定义分块格式：`RisuSaveEncoder` 把数据库按 root、preset、modules、loadouts、plugins、pluginStorage、每个角色独立块打包为 msgpack + 可选 gzip，写入 `database.bin`（`src/ts/storage/risuSave.ts:124-326`）。`saveDb()` 用 Svelte 5 的 `$effect` 监听数据库变化，500ms 防抖后写主文件并同时生成 `dbbackup-<时间戳>.bin`，最多保留 20 份（`src/ts/globalApi.svelte.ts:292-529`）；损坏时启动流程按时间倒序尝试恢复备份（`src/ts/bootstrap.ts:89-153`）。Web 端同一文件存 IndexedDB（localforage），Tauri 端存 AppData 目录；启用账号同步后改经 `/api/account/write` 上传同一份 `database.bin`（`src/ts/storage/accountStorage.ts:22-58`）。

配置快照是 `botPresets`：保存当前活动设置（含模型、URL、`openAIKey`、`proxyKey` 等）、切换、复制，并支持 `.risupreset`（用固定字符串密钥加密）与 JSON 两种导出（`database.svelte.ts:2036-2275, 2291-2337`）。导出前会清空 `openAIKey`、`proxyKey`、各 URL 字段；JSON 导入时用 `presetTemplate` 兜底合并。版本迁移分两级：`setDatabase` 的字段级默认值补齐，以及 `checkNewFormat` 按 `formatversion` 逐级升级（`bootstrap.ts:335-507`）。

## 3. 凭据、Header 与代理边界

### 3.1 静态存储：全库明文

API Key 与其他秘密是 `Database` 接口上的普通字符串字段，没有任何独立凭据存储。代表性字段如下（完整清单见 `database.svelte.ts:805-1211`）：

| 类别 | 字段 |
|---|---|
| 模型服务 Key | `openAIKey`、`claudeAPIKey`、`openrouterKey`、`mistralKey`、`cohereAPIKey`、`nanogptKey`、`ollamaApiKey`、`deepseek` 等按 keyIdentifier 索引的 `OaiCompAPIKeys` |
| 自定义/代理 | `proxyKey`、`customModels[].key`、`mancerHeader`、`hordeConfig.apiKey` |
| 特殊协议 | `novelai.token`、`novellistAPI`、`google.accessToken`、`vertexPrivateKey`（Vertex 服务账号私钥） |
| OAuth 与刷新 | `authRefreshes`（URL、clientSecret、refreshToken 等） |

`database.bin` 与 `dbbackup-*.bin` 只有 msgpack 打包与可选 gzip 压缩，没有字段加密；Web 端 IndexedDB 同此。启动流程与保存流程均无 OS Keychain、DPAPI 或主密钥参与。

### 3.2 云同步与备份边界

凭据会随数据库进入多条同步/备份路径：

- 账号同步：`AccountStorage` 把完整 `database.bin` 上传到 hub 的 `/api/account/write`（`accountStorage.ts:48-58`）；
- Google Drive 备份：`backupDrive` 上传 `encodeRisuSaveLegacy(getDatabase(), 'compression')` 的完整数据库，仅压缩不加密（`src/ts/drive/drive.ts:186-193`）；
- Kei 自动备份：`saveDbKei` 每 5 分钟把整个 `db` 对象以 JSON 发给备份服务器（`src/ts/kei/backup.ts:83-103`）；
- 本地备份 `.risudat`：仅在账号模式且运行于 risuai.xyz 时，用 `sv.risuai.xyz/cryptokey` 下发的临时密钥加密数据库块，并写入加密元数据文件（`src/ts/drive/backuplocal.ts:161-174`）；非账号模式与其它来源的备份为明文。

因此"加密"只出现在一条条件性的备份路径上，属于传输与备份保护，不是磁盘静态加密。

### 3.3 进程间传递与日志

Tauri 桌面端由前端 webview 直接持有全部凭据，HTTP 经 Rust command `streamed_fetch` 发起，headers 以 JSON 字符串传入（`src-tauri/src/main.rs:433-567`）。Web 端请求经 hub 或自托管 Node 服务的 `/proxy2` 转发：目标 URL 放 `risu-url`，完整 headers（含 Authorization）经 `risu-header` 传入，服务端解包后原样转发上游（`server/node/server.cjs:742-821`）。也就是说 Web 运行模式下，凭据会完整经过第三方中转服务器进程。

请求日志会把 headers 与 body 原样记录进内存数组 `fetchLog`（最多 20 条，`globalApi.svelte.ts:650-777`），流式请求在 `fetchNative` 中也先写入日志再返回（`globalApi.svelte.ts:1780-1791`）。日志可通过 DevTool 侧栏或设置页"Show Log"以 Markdown 展示和复制（`src/lib/Setting/Pages/Advanced/SettingsExportButtons.svelte:12-19`），因此 API Key 在日志中可见，没有脱敏。插件读取日志需先获得 `fetchLogs` 权限（`src/ts/plugins/apiV3/v3.svelte.ts:567-603`）。

### 3.4 导出与前端可见性

"Export Settings for Bug Report" 导出会删除含 key/proxy/hypa 关键字、URL 类字段及 `customModels`、`authRefreshes` 等键（`SettingsExportButtons.svelte:43-58`）；Preset 导出同样清空 Key 与 URL。设置页输入框的掩码由 `hideApiKey` 开关（默认开启）控制，仅是 UI 行为，数据始终明文绑定在 `DBState.db` 上（如 `BotSettings.svelte:403-408`）。不存在设置页之外的"只读掩码 API"，前端任意代码均可访问全部凭据。

## 4. 模型目录与能力元数据

模型目录有三层来源：

1. 静态内置表 `LLMModels`：OpenAI、Anthropic、Google、DeepSeek、DeepInfra、Mistral、Cohere、NovelAI、Ollama（本地/云两个条目）、WebLLM、Kobold、NovelList、特殊条目（ooba、mancer、openrouter、kobold、custom、reverse_proxy、echo_model）等（`modellist.ts:44-578`）；
2. 动态注册 `registerModelDynamic`：启动时若 `dynamicModelRegistry` 开启，分别调用 Google `v1beta/models`、Anthropic `/v1/models`、OpenAI `/v1/models`（只收 `gpt-` 前缀），以 `dynamic_<provider>_<id>` 追加到内存数组（`modellist.ts:613-770`，启动入口 `bootstrap.ts:255`）；
3. 设置页实时拉取：OpenRouter（含价格、context、缓存价与推理价元数据，`src/ts/model/openrouter.ts:51-106`）、NanoGPT（模型与订阅目录，`src/ts/model/nanogpt.ts:162-192`）、Ollama `/api/tags`（`src/ts/model/ollama.ts:23-45`）、Horde `status/models`（模块级内存缓存，`src/ts/horde/getModels.ts:19-44`）。

元数据以能力位 `LLMFlags`（27 个值，`types.ts:3-32`）与参数白名单 `parameters` 表达，直接驱动请求行为：`reformater` 按 flags 决定 system prompt 处理、角色交替要求与首条 user 补齐（`request.ts:348-432`）；`keyIdentifier` 决定取哪把 Key，`endpoint` 覆盖默认 URL，`parameters` 决定 `applyParameters` 注入哪些采样参数（`shared.ts:137-342`）。

未知模型 ID 在 `getModelInfo` 中回退为 OpenAI 兼容的通用条目；`hf:::`、`horde:::`、`xcustom:::`、`pluginmodel:::` 四种前缀分别映射到 WebLLM、Horde、自定义条目与插件目录（`modellist.ts:775-870`）。

远端目录不落盘：动态注册只在每次启动执行一次，设置页目录每次打开实时拉取，失败静默返回空列表；模型条目全部在内存数组中，没有上下文长度、价格等元数据的持久化缓存。

## 5. Adapter、协议与请求组装

协议适配集中在请求层：`requestChatDataMain` 按 `modelInfo.format` 的 `LLMFormat` 枚举值（24 个）switch 分发到各 Adapter 函数（`src/ts/process/request/request.ts:484-528`）。各 Adapter 内部自行组装 URL、Header、请求体与流式解析：

| 格式族 | Adapter 与要点 |
|---|---|
| OpenAI 兼容（chat/completions、legacy instruct、Responses API） | `src/ts/process/request/openAI/requests.ts`：URL 由模型 endpoint、`reverse_proxy` 的 `forceReplaceUrl`（自动补全 `/v1/chat/completions`）、OpenRouter/NanoGPT 专用 URL 依次决定（512-541）；headers 含 Authorization、keyIdentifier 覆盖、X-Title/X-Provider/X-Proxy-Risu（547-576）；body 支持 route/provider fallback 参数、thinking、tools、multiGen、response_format |
| Anthropic | `src/ts/process/request/anthropic.ts`：`/v1/messages` + `x-api-key`；AWS Bedrock 分支用 SigV4 签名并把 Key 按 `accessKey:secret:region` 拆解（392-553）；支持 thinking/adaptive 模式 |
| Google / Vertex | `src/ts/process/request/google.ts`：`generativelanguage.googleapis.com` 的 key 查询参数，或 Vertex 的 JWT 换 token（511-521）后走 aiplatform URL（531-563）；RESOURCE_EXHAUSTED 进入重发路径 |
| NAI / NovelList / Cohere / Kobold / Ooba / OobaLegacy | `request.ts` 内实现，各自原生 payload 与流（NAI 用 `api.novelai.net`，Ooba 新版走 `/v1/completions` 或 WebSocket，Kobold 走 `/api/v1/generate`） |
| Horde | 异步提交 + 每 2 秒轮询状态，匿名 Key `0000000000` 兜底（`request.ts:1360-1467`） |
| Ollama | `ollama` SDK，本地走 `ollamaURL`，云端走 `ollama.com` 并注入 Bearer Key；云端还可切换为 OpenAI 兼容/Responses/Anthropic 格式复用对应 Adapter（`request.ts:1118-1228`） |
| WebLLM / Plugin / Echo | 浏览器内 transformers.js、插件回调、纯回显 |

底层网络在 `globalFetch` / `fetchNative` 统一（`globalApi.svelte.ts:681-740, 1713-1968`）：Tauri 走 `streamed_fetch`，Web 走 `/proxy2`，可被 `usePlainFetch` 强制直连，局域网地址在 `localNetworkMode` 下走 `local_network` 路由（Node 端还有 ProxyJobWs 通道），并按模型类型附加可选的 `requestTimeoutMs`（`src/ts/process/request/openAI/shared.ts:9-21`）。自定义 Header 与 Body 字段通过附加参数注入：`applyAdditionalParameters` 支持 `header::` 前缀、`json::` 值、`{{none}}` 删除标记与类型推断（`shared.ts:79-135`），Custom API 与自定义模型均可使用。

## 6. 运行时选择、绑定与路由

运行时有两个全局模型槽 `aiModel` / `subModel`，各辅助任务（memory、emotion、translate、otherAx）可在 `seperateModels` 中单独覆盖（`request.ts:440-447`）；`requestChatDataMain` 的取值优先级是 staticModel（fallback 传入）> 主/子模型槽 > 按模式分离的模型。`reverse_proxy` 与 `xcustom:::` 模型在分发前把 URL、Key、格式从数据库字段解析进请求参数（`request.ts:468-478`）。模型 ID 决定 Provider、格式、端点和凭据，没有别名、语义路由或负载均衡；会话与角色不保存渠道引用（该部分属相邻类目）。

## 7. 重试、模型 fallback 与故障转移

### 7.1 请求层：同模型重试 + 模型候选链

`requestChatData` 是唯一的通用失败处理层（`request.ts:205-346`）。它先取当前任务模式对应的 `fallbackModels[mode]` 候选列表，追加空字符串表示"当前模型本身"，然后对每个候选做内层重试：

- 内层循环中 `trys` 超过 `requestRetrys`（默认 2，设置页可调 0–20，`advancedSettingsData.ts:47-48`）时推进到下一个 fallback 候选；
- 失败且标记 `failByServerError` 时先等待 1 秒，开启 `antiServerOverloads` 时每次计数只加 0.5（实际重试次数翻倍，`advancedSettingsData.ts:207`）；
- 成功但响应为空且 `fallbackWhenBlankResponse` 开启时立即推进候选；
- 成功但命中 `banCharacterset` 禁用脚本时留在同一模型重发；
- 部分 Adapter 返回 `noRetry`（Horde 判定不可能、Kobold 等）直接放弃；
- 插件模型（`custom` / `pluginmodel:::`）不参与候选推进。

fallback 候选是任意模型 ID，设置 UI 在 `PromptSettings.svelte:313-334` 按模式分别配置，因此候选链可以跨 Provider（例如主模型是 OpenAI、候选是 DeepSeek 或 OpenRouter 条目），这是用户静态配置的模型 fallback，不是健康感知的自动 failover；推进候选会完整重发同一请求，存在重复生成与计费的可能（影响未实测）。

### 7.2 工具调用链与 Google 过载路径

工具调用循环在 OpenAI 兼容（`requests.ts:821-828, 1292`）、Responses API（`responses.ts:564, 775`）与 Google（`google.ts:912-919`）三个 Adapter 内各自实现，统一使用同一个 `requestRetrys` 计数。Google 的 RESOURCE_EXHAUSTED 走独立的递归重发路径 `fallBackGemini`（`google.ts:589-614`），开启防过载时递归重发同一请求；静态代码中未发现深度上限，仅受 abort 信号与错误不再命中条件的约束（推断）。

### 7.3 多 Key 与健康状态

本次未找到任何多 Key 结构：每个 Provider 一个字符串 Key 字段，`OaiCompAPIKeys` 是按 keyIdentifier 索引的单值映射。没有 Key 轮询、失败计数、熔断、冷却或恢复，也没有按渠道持久化的健康表；连接测试结果与请求结果都不参与后续选路。

## 8. 连接检测与可观测性

设置页没有独立的"测试连接"按钮（本次未找到）；隐式检测是模型目录加载——OpenRouter/NanoGPT/Ollama 目录在设置页渲染时实时请求，失败静默返回空列表（`BotSettings.svelte:267, 362, 387`）。请求体预览（Preview Body / 预览提示词）复用真实组装逻辑但不发送，OpenAI 兼容、Ollama、Kobold、Cohere 等支持，NAI、Horde、WebLLM、插件不支持（各 Adapter 内的 `previewBody` 分支）。可观测性由内存请求日志承担：`fetchLog` 保留最近 20 条请求的 URL、headers、body、响应与状态码（含凭据，见 3.3），消息对象内会记录生成模型字符串（`process/index.svelte.ts:1533-1573`）。没有用量、成本或延迟统计面板。

## 9. 设计取舍与已确认边界

- 单 `Database` 对象同时承载配置与凭据，读写简单、无隔离层，代价是同步、备份与日志都会自然携带全部 Key；
- 模型 ID 即渠道引用，多连接靠条目复制与自定义条目表达，新增 Provider 不需要实体表，但同一服务的多条独立连接需要手工维护自定义条目；
- `customAPIFormat` 让一个 URL 可切换四种协议族，Custom API 复用完整 Adapter 逻辑；
- Web 版强制经 hub/自托管 `/proxy2` 中转，localhost 直连被浏览器策略阻止（`globalApi.svelte.ts:690-696`），凭据因此完整经过中转进程；
- fallback 链按任务模式分离且候选为任意模型 ID，是本项目唯一的故障转移机制，触发条件是错误类型与空响应，不是健康状态；
- 对上游聚合服务（OpenRouter route/provider、NanoGPT X-Provider）的控制以请求字段形式传递给上游，与 SillyTavern 的做法一致，本地不复制上游路由器。

## 10. 未验证事项

- 未运行应用：设置页交互、掩码显示效果、模型网格加载与目录失败时的实际表现；
- `/proxy2` 经官方 hub 中转时的服务端日志与留存策略（自托管 Node 服务可自行验证）；
- Google `fallBackGemini` 递归路径在持续过载时的实际深度与终止行为；
- `requestRetrys` 与 fallback 推进对计费、重复生成的实测影响；
- `sv.risuai.xyz/cryptokey` 的密钥发放与管理机制；
- 各 Provider 设置 UI 只读了关键区段，未逐项核对全部输入项与提示文案。

## 11. 关键源码索引

- Provider/Format/Flags 枚举与模型类型：`src/ts/model/types.ts`
- 内置模型表与动态注册：`src/ts/model/modellist.ts`
- 远端目录：`src/ts/model/openrouter.ts`、`src/ts/model/nanogpt.ts`、`src/ts/model/ollama.ts`、`src/ts/horde/getModels.ts`
- 数据库定义、默认值与迁移：`src/ts/storage/database.svelte.ts`
- 保存格式与备份：`src/ts/storage/risuSave.ts`、`src/ts/globalApi.svelte.ts`
- 请求入口与 fallback 链：`src/ts/process/request/request.ts`
- 协议 Adapter：`src/ts/process/request/openAI/requests.ts`、`openAI/responses.ts`、`anthropic.ts`、`google.ts`、`shared.ts`
- 网络路由与日志：`src/ts/globalApi.svelte.ts`、`src/ts/network/localNetwork.ts`
- Node 中转：`server/node/server.cjs`
- Tauri 请求：`src-tauri/src/main.rs`
- 插件 Provider：`src/ts/plugins/apiV3/v3.svelte.ts`
- 设置 UI：`src/lib/Setting/Pages/BotSettings.svelte`、`Advanced/CustomModelsSettings.svelte`、`Advanced/SettingsExportButtons.svelte`、`PromptSettings.svelte`
- 云同步与备份：`src/ts/storage/accountStorage.ts`、`src/ts/drive/drive.ts`、`src/ts/drive/backuplocal.ts`、`src/ts/kei/backup.ts`
