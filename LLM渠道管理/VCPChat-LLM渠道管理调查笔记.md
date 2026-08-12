# VCPChat LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对；只读源码梳理；未修改目标仓库；调查时无未提交修改
>
> 调查范围：LLM 渠道数据模型、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 不是多 Provider 网关，也没有直接管理 OpenAI、Anthropic、Gemini 等上游渠道。它把 LLM 连接建模为一套全局 VCP 网关配置：

```text
settings.json
  -> vcpServerUrl
  -> vcpApiKey
  -> enableVcpToolInjection

Agent config.json
  -> model
  -> temperature / token limits / stream
```

客户端只认识一个 OpenAI-compatible VCP 入口和一个 Bearer Key。Agent 保存裸 `model` ID，请求时把模型名交给 VCP 服务端；模型究竟映射到哪个上游 Provider、Base URL 和 Key，不在 VCPChat 中决定。独立的 VCPToolBox 才是需要另行调查的服务端渠道管理对象。

当前快照的关键结论：

- 全局设置只有一套 `vcpServerUrl + vcpApiKey`，没有 Provider 实体、渠道列表或连接 Profile；
- 设置页会把 URL 规范到 `/v1/chat/completions`，开启工具注入后运行时改为 `/v1/chatvcp/completions`；
- Chat 请求使用 OpenAI 风格的 `messages`、`model`、采样参数和 `stream`，并增加 `requestId`、`contextTokenLimit` 等 VCP 扩展字段；
- 认证固定为 `Authorization: Bearer <vcpApiKey>`，没有渠道级自定义 Header；
- 模型目录来自同一网关 origin 的 `/v1/models`，只缓存在主进程内存，失败时清空；
- Agent、话题摘要和桌面 widget 可以选模型，但都继续使用同一 URL 和 Key；
- 普通聊天、话题摘要和 widget 调用均为单次 `fetch`，没有自动重试、退避、换 Key、换 URL或跨渠道故障转移；
- `modules/vcpClient.js` 虽然实现了 300 秒 AbortController，但全仓库没有其他模块导入它，当前实际 IPC 请求链没有接线到该模块；
- Flowlock 最多 3 次的“重试”是失败后定时触发下一轮自动续写，不是同一 HTTP 请求的 transport retry，也不换渠道；
- `settings.json` 直接明文保存 VCP Key，没有 DPAPI、Keychain、Electron `safeStorage` 或字段加密；
- 设置保存使用临时文件、JSON 回读校验、旧文件备份和原子替换，但这些机制保证写入完整性，不提供 Secret 保密性；
- 每日设置备份和一键 ZIP 都会携带明文 `vcpApiKey`；
- 模型刷新兼作基本连通性检查，没有独立最小生成测试、持久化健康状态、延迟/错误率统计或熔断器。

## 总体调用链

```text
全局设置
  vcpServerUrl + vcpApiKey
  -> 设置页补全 /v1/chat/completions

Agent config.json
  model + temperature + contextTokenLimit
  + maxOutputTokens + streamOutput
  -> renderer 调用 send-to-vcp IPC
  -> modules/ipc/chatHandlers.js
       清理消息私有字段
       enableVcpToolInjection?
         yes -> /v1/chatvcp/completions
         no  -> 原 vcpServerUrl
       组装 OpenAI-compatible body + VCP 扩展字段
       Authorization: Bearer vcpApiKey
       单次 fetch
  -> VCP 网关
       Provider / Key / Adapter / fallback 均属于服务端职责
  -> SSE 流或 JSON 结果返回 renderer
```

## 1. 渠道数据模型与职责边界

### 1.1 全局单网关，而非 Provider 列表

[`modules/utils/appSettingsManager.js`](../../VCPChat/modules/utils/appSettingsManager.js) 的默认设置直接定义 `vcpServerUrl` 和 `vcpApiKey`。它们是单值字符串，不是数组，也没有以下常见渠道字段：

- Provider 类型；
- 渠道 ID、名称、启停状态；
- 每条渠道独立的 Base URL、Key 列表和 Header；
- 权重、优先级、成本和健康状态；
- 模型到渠道的本地映射。

因此，VCPChat 的“渠道”准确说是“当前 VCP 网关连接”。切换网关需要改全局 URL/Key，而不是在一次请求中选择一个 Provider Profile。

### 1.2 Agent 只保存模型与生成参数

[`modules/utils/agentConfigManager.js`](../../VCPChat/modules/utils/agentConfigManager.js) 把每个 Agent 的配置写到：

```text
AppData/Agents/<agent>/config.json
```

LLM 相关字段包括：

- `model`；
- `temperature`；
- `contextTokenLimit`；
- `maxOutputTokens`；
- `streamOutput`，以及其他采样参数。

配置里没有 Provider ID 或渠道 ID，模型身份也不是 `provider:model` 组合。两个上游若暴露同一个模型 ID，客户端无法仅凭本地 Agent 配置区分它们，最终解释权在 VCP 服务端。

### 1.3 不把 VCPToolBox 能力归因给客户端

VCPChat 请求 `/v1/chat/completions` 或 `/v1/chatvcp/completions` 后，上游可以自行做模型映射、多 Key、重试和 Provider fallback，但这些能力不会出现在客户端调用链中。

所以本篇只评价 VCPChat 自己能否表达和调度渠道。独立 `VCPToolBox` 仓库中的服务端实现应单列调查，不能因请求经过 VCP 网关就写成“VCPChat 支持多 Provider 路由”。

## 2. Base URL、端点、Header 与凭据

### 2.1 URL 规范化

[`modules/settingsManager.js`](../../VCPChat/modules/settingsManager.js) 的 `completeVcpUrl()` 会：

1. 去掉输入首尾空白；
2. 没有协议时补 `http://`；
3. 用标准 `URL` 解析；
4. 强制把 pathname 设为 `/v1/chat/completions`。

正常设置流程会把完整的 Chat Completions endpoint 保存到 `vcpServerUrl`，而非只保存 Base URL。

主聊天请求位于 [`modules/ipc/chatHandlers.js`](../../VCPChat/modules/ipc/chatHandlers.js)。当 `enableVcpToolInjection === true` 时，代码保留原 URL 的 protocol、host、port 和 query 等结构，但把 pathname 改为 `/v1/chatvcp/completions`；关闭时直接使用传入的原 URL。

涉及的主要端点是：

| 端点 | 用途 |
|---|---|
| `/v1/chat/completions` | 普通 OpenAI-compatible 对话 |
| `/v1/chatvcp/completions` | 启用 VCP 工具注入后的对话 |
| `/v1/models` | 拉取模型目录 |
| `/v1/interrupt` | 按 `requestId` 请求服务端中断生成 |

### 2.2 固定 Bearer Header

主请求、模型目录、话题摘要、中断请求和 widget Chat API 都使用：

```http
Content-Type: application/json
Authorization: Bearer <vcpApiKey>
```

客户端没有为 LLM 请求提供自定义 Header 表、Header 模板或不同端点独立凭据。桌面 widget 还存在一套 Admin API Basic Auth，但它用于后台管理代理，不是 LLM Provider 渠道凭据，不能与 `vcpApiKey` 混为一谈。

### 2.3 请求体是 OpenAI 风格加 VCP 扩展

主请求把消息清理为 API 合法字段，剔除附件和内部 UI 元数据，再构造：

```json
{
  "messages": [],
  "model": "...",
  "temperature": 0.7,
  "max_tokens": 60000,
  "contextTokenLimit": 1000000,
  "stream": true,
  "requestId": "message-id",
  "vcpchatExtensions": {
    "schemaVersion": 1,
    "messageMetadataMode": "hash_only",
    "messageTimestampBindings": [],
    "requestContext": {
      "requestId": "message-id",
      "agentId": "...",
      "agentName": "...",
      "topicId": "...",
      "ownerType": "agent",
      "isGroupMessage": false
    }
  }
}
```

`modelConfig` 先经 `omitUnsetOptionalModelParams()`（`modules/ipc/chatHandlers.js:95-118`）清理，采样参数未设置（`null`/空）时不再出现在请求体；`vcpchatExtensions` 可能只含 `requestContext`（消息时间戳绑定为空时省略该段），`requestContext` 携带本轮请求与 Agent/Topic 上下文标识（`buildRequestContext`，`:53-82`）。实际字段由 `modelConfig` 展开，工具、上下文清理和 `vcpchatExtensions` 可能继续增补内容。协议入口兼容 OpenAI Chat Completions，但不是纯粹只发 OpenAI 标准字段。

## 3. 模型目录与模型选择

### 3.1 `/v1/models` 从网关统一获取

[`main.js`](../../VCPChat/main.js) 的 `fetchAndCacheModels()` 从当前 `vcpServerUrl` 取 protocol + host，构造：

```text
GET <vcp-origin>/v1/models
Authorization: Bearer <vcpApiKey>
```

成功时读取响应的 `data.data`，保存到主进程变量 `cachedModels`；失败或 URL 未设置时把缓存清空。这个缓存不落盘，也没有按 Provider 或网关 URL 分区。

应用启动后会后台获取模型；`refresh-models` IPC 支持手工刷新并把列表推送给 renderer。UI 在缓存为空时也会触发刷新，但相关等待和展示逻辑不形成持久化模型同步任务。

### 3.2 模型选择是显式的裸 ID

Agent 配置保存自己的 `model`。全局 `topicSummaryModel` 为话题摘要选择另一模型，未设置时代码回退到 `gemini-2.5-flash`。

[`modules/modelUsageTracker.js`](../../VCPChat/modules/modelUsageTracker.js) 维护：

- `AppData/model_usage_stats.json`：按裸 model ID 累计使用次数；
- `AppData/model_favorites.json`：收藏的 model ID 列表。

热门和收藏只影响模型 UI 排序与快捷选择，不是基于实时延迟、价格或错误率的路由。统计键也不包含 Provider/网关身份，切换 VCP 服务端后同名模型仍会合并计数。

### 3.3 模型目录不是推理 failover

`/v1/models` 请求失败时只是清空可选列表。已有 Agent 配置中的模型字符串仍然是静态值；代码不会因目录缺失而自动选另一个模型，也不会在推理失败后回退到目录中的下一项。

### 3.4 客户端保留对象，但只消费 `id`

[`main.js`](../../VCPChat/main.js) 对响应仅执行：

```js
cachedModels = data.data || [];
```

所以网关返回的 `object`、`created`、`owned_by`、`display_name`、context、pricing、capability 等任意字段会暂时留在内存对象中，没有在主进程被删除或规范化。但 [`modules/settingsManager.js`](../../VCPChat/modules/settingsManager.js) 创建列表项时只读取 `model.id`：

- 列表文字是 `model.id`；
- 搜索目标和点击回调都是 `model.id`；
- Agent 最终保存的也是这个裸字符串；
- `display_name` 和 `owned_by` 不用于展示或分组；
- context、最大输出、模态、能力和价格没有任何 UI 或请求消费者。

因此 VCPChat 的模型目录在语义上是“可选 ID 列表”，不是富模型注册表。VCPToolBox 的语义虚拟模型虽然带 `owned_by: vcp-semantic-router` 和可选 `display_name`，在 VCPChat 中仍只显示公开 ID。

### 3.5 没有模型 schema 与字段校验

主进程不验证顶层 `object`，也不检查 `data` 是否为数组；Renderer 才兼容数组、`payload.data`、`payload.models` 和单个 `{id}` 对象。数组中的成员没有过滤或 schema 校验。

直接后果包括：

- `{data: {…}}` 会被缓存为对象，刷新结果却因没有数组长度而报告失败；
- 非空数组即被视为刷新成功，即使其中没有有效 `id`；
- 重复 ID不去重，会在“全部模型”中重复显示；
- 缺少 ID的成员仍会尝试建立列表项，点击后回传 `undefined`；
- 同一个 ID的新旧对象没有版本、时间戳或来源标识，最后一次全量刷新直接替换缓存。

这对标准 OpenAI `{object:'list', data:[{id,…}]}` 足够，但不适合作为跨网关模型治理层。若要补能力筛选或费用展示，应先在主进程建立规范化 schema 和错误报告，不能继续让 Renderer 猜响应形状。

### 3.6 热门与收藏是旁路元数据

[`modules/modelUsageTracker.js`](../../VCPChat/modules/modelUsageTracker.js) 额外维护的热门次数和收藏状态，可以视为客户端生成的两类模型元数据，但键仍只有裸 ID：

```text
model-id -> usage count
favorite model-id set
```

它们不附着在 `cachedModels` 对象上，而是在打开选择器时并行读取，再按 ID 查回当前目录对象。已经收藏但当前网关目录不存在的 ID 不会显示；切换网关后，同名 ID 会继承之前的热门和收藏状态。

这适合个人快捷选择，不适合渠道级统计。要区分两个网关的同名模型，至少需要把统计键升级为 `gateway identity + model id`；若 VCP 网关以后公开 Provider ID，也应纳入稳定身份，而不是依赖可变的 `owned_by` 展示字段。

## 4. Adapter 与协议路由

### 4.1 客户端只有一个 OpenAI-compatible Adapter 面

主请求统一生成 Chat Completions 风格 payload，客户端没有按 OpenAI、Anthropic、Gemini 分别选择 SDK 或序列化器。所谓协议路由只有：

```text
enableVcpToolInjection = false -> /v1/chat/completions
enableVcpToolInjection = true  -> /v1/chatvcp/completions
```

这是 VCP 功能端点切换，不是 Provider Adapter 选择。各厂商认证、原生端点、工具格式和流式响应转换均应由服务端完成。

### 4.2 SSE 解析不包含渠道状态

主 IPC handler 对流式响应读取 SSE `data:` 事件并转发给 renderer；非 2xx 会解析 JSON 或文本错误。响应处理知道消息 `requestId` 和 UI 上下文，但没有记录 Provider、实际 Key、上游重试次数或 fallback 路径。

### 4.3 `vcpClient.js` 是未接线实现

[`modules/vcpClient.js`](../../VCPChat/modules/vcpClient.js) 另有一个统一请求模块，包含 `AbortController` 和 300 秒定时中断，流式清理也更完整。它同步应用了 `requestContext` 与参数省略两处修改（589 行），但重新 grep 全仓库确认对 `vcpClient` 的命中仍只有该文件自身，没有 `require()` 或 `import` 把它接入当前主流程。

实际生产路径是 `main.js` 注册的 [`modules/ipc/chatHandlers.js`](../../VCPChat/modules/ipc/chatHandlers.js) 中 `send-to-vcp` handler（`:855-1270`）。该 handler 的 `fetch` 没有传 `signal`，所以不能把未接线模块的 300 秒超时算作当前客户端能力。

## 5. 多 Key、轮询、重试与熔断

### 5.1 只有一个 Key

`vcpApiKey` 是单个字符串。代码没有：

- 多 Key 数组；
- Key ID、标签、启停状态和优先级；
- random 或 round-robin 选择；
- 请求失败后换 Key；
- Key 级 401/429 计数、冷却和半开恢复。

如果 VCPToolBox 在服务端管理多 Key，那是网关内部能力；VCPChat 只发送一枚用于访问网关的客户端凭据。

### 5.2 普通请求为单次 `fetch`

[`modules/ipc/chatHandlers.js`](../../VCPChat/modules/ipc/chatHandlers.js) 对主聊天执行一次 `fetch(finalVcpUrl, ...)`。网络异常进入 catch，非 2xx 直接构造错误返回或发送流错误事件。没有：

- 最大重试次数；
- 429/5xx/网络错误分类；
- `Retry-After`；
- 指数退避和抖动；
- 请求幂等/可重放判断；
- 更换 URL、Key、模型或 Provider。

话题摘要 [`modules/topicSummarizer.js`](../../VCPChat/modules/topicSummarizer.js) 和 widget 代理 [`Desktopmodules/api/vcpProxy.js`](../../VCPChat/Desktopmodules/api/vcpProxy.js) 也是单次 `fetch`。失败后分别回退本地标题或返回 `{ success: false }`，不做渠道切换。

### 5.3 Flowlock 是工作流重试，不是 transport retry

[`Flowlockmodules/flowlock.js`](../../VCPChat/Flowlockmodules/flowlock.js) 的 Session 默认：

```text
retryCount: 0
maxRetries: 3
```

一轮自动续写报告错误后，Flowlock 增加计数，按 `flowlockContinueDelay` 的固定延迟调用 `scheduleNextRound()`，再触发一次 `continueWritingForContext()`；成功完成会把计数重置为 0，达到 3 次则停止 Session。

这是新的自动续写轮次，会生成新的 message ID。它不是在 HTTP transport 内透明重放原请求，也不会改变全局网关 URL、Key 或 Agent 模型。因此能力矩阵中应写成“局部工作流重试”，不能写成“LLM 请求自动重试 3 次”。

### 5.4 没有熔断与跨渠道 failover

客户端未持久化连续失败次数、熔断截止时间或半开探测状态，也没有候选 URL/模型/Provider 列表。任何服务端 fallback 对 VCPChat 都是黑盒；客户端错误响应中没有可用于下一次渠道调度的结构化健康数据。

## 6. 权重、成本与延迟路由

VCPChat 没有本地调度器。模型选择来自 Agent 静态配置、用户手工选择或话题摘要专用模型，不读取：

- 渠道权重和优先级；
- 模型输入/输出价格；
- 最近请求延迟；
- 错误率和剩余额度；
- 上下文长度与任务需求的动态匹配；
- Provider 地域和合规策略。

`model_usage_stats.json` 只有调用次数，不能据此计算 token 成本或质量，也没有被请求路径用作自动选模依据。

## 7. 凭据存储、导入与备份

### 7.1 `settings.json` 明文保存 Key

[`main.js`](../../VCPChat/main.js) 把应用数据根目录固定为项目内的 `AppData`，全局设置路径是：

```text
<VCPChat>/AppData/settings.json
```

其中直接包含 `vcpServerUrl`、`vcpApiKey`，以及日志、语音/TTS 等其他服务的 URL/Key。源码未见 DPAPI、系统 Keychain、Electron `safeStorage` 或字段级加密。

能读取项目目录、备份文件或进程内设置对象的主体，可以直接获得网关 Key。桌面 widget 从主进程通过 IPC 取得凭据后缓存在 renderer 代理闭包中，让 widget 脚本不必直接接收 Key；这缩小了 widget API 的暴露面，但不改变磁盘明文事实。

### 7.2 原子保存解决完整性，不解决保密性

[`modules/utils/appSettingsManager.js`](../../VCPChat/modules/utils/appSettingsManager.js) 保存设置时：

1. 写入 `settings.json.tmp`；
2. 重新读取并 JSON 解析验证；
3. 把旧设置复制为 `settings.json.backup`；
4. 将临时文件移动覆盖正式文件。

损坏时也会尝试从 `.backup` 恢复。这能降低崩溃或半写入导致的配置损坏，但临时文件、正式文件和备份都包含同样的明文 Secret。`appSettingsManager.js` 的默认设置还包含 `ChatDataServiceEnabled`/`ChatDataServiceShadowMode`/`ChatDataServiceNotifyEnabled`/`ChatDataServiceTantivyEnabled`/`MobileSyncUseCentralIndex`/`DeepMemoUseCentralSearch`/`DeepMemoLegacyFallback` 等与 LLM 渠道无关的字段（`modules/utils/appSettingsManager.js:132-141`）。

### 7.3 每日备份保留的是最近 7 份，不是严格 7 天

设置管理器每天把完整 `settings.json` 复制到：

```text
AppData/UserData/backups/settings-<timestamp>.json
```

注释写“最近 7 天”，实际代码按文件名排序并只保留最新 7 个 `settings-*` 文件。若手工触发、时钟变化或备份缺失，文件数量和自然日不是同一语义。每一份都带明文 `vcpApiKey`。

### 7.4 一键 ZIP 默认包含 Key

根目录 [`backup.py`](../../VCPChat/backup.py) 会无条件归档 `AppData` 根目录下的所有文件，然后归档若干指定子目录。附件和 TTS 缓存可以选择排除，但没有针对 `settings.json`、`.backup`、临时文件或 Key 的排除规则。

因此正常情况下生成的 `VCP_Backup_<timestamp>.zip` 会包含 `AppData/settings.json`，也可能包含根目录其他设置备份；ZIP 只做 Deflate 压缩，没有密码或加密。该归档应按凭据材料保护。

当前源码未找到全局设置 JSON/ZIP 的同级导入恢复 UI。话题 Markdown 等内容导出不等于渠道配置导出；一键脚本主要提供文件归档，恢复依赖用户或部署侧文件操作。

## 8. 连接测试与可观测性

### 8.1 模型刷新兼作基本连接验证

手工 `refresh-models` 会请求 `/v1/models`，返回 `success`、模型列表和数量。它同时验证：

- URL 能否连接；
- Bearer Key 是否被模型端点接受；
- 响应是否符合 `{ data: [...] }` 预期。

但它不发送最小 Chat Completion，所以不能验证指定模型能否完成推理、工具注入端点是否工作、流式 SSE 是否兼容。失败时主要写 console、清空缓存并让 UI 没有可用模型。

### 8.2 没有持久化渠道健康表

源码未见按 URL、模型或 Key 记录：

- 最近成功/失败时间；
- 连续失败次数；
- HTTP 状态码分布；
- P50/P95 延迟；
- 429、额度和限流恢复时间；
- 当前熔断状态；
- 实际上游 Provider 与 fallback 轨迹。

主路径主要通过 console 和返回给 renderer 的错误信息排障。`requestId` 支持把流事件、中断和 UI 消息关联起来，但不是完整的分布式 trace，也不参与渠道调度。

### 8.3 使用次数不是调用质量观测

模型使用统计在发送 `fetch` 之前就增加，因此失败请求也可能被计数。它没有 token、耗时、状态和成本字段，只适合作为 UI 热门模型指标，不应作为成功调用量或账单审计数据。

## 9. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| 多 Provider 实体 | 无 | 客户端只认识 VCP 网关 |
| 多连接 Profile | 无 | 仅一套全局 URL/Key |
| 自定义 Base URL | 有 | 设置页补全为 Chat Completions endpoint |
| 自定义 LLM Header | 无 | 固定 Content-Type + Bearer |
| 多协议 Adapter | 无 | 统一 OpenAI-compatible/VCP 端点 |
| 远程模型目录 | 有 | 同一 origin 的 `/v1/models` |
| 模型手工选择 | 有 | Agent 和摘要模型保存裸 ID |
| 模型收藏/热门 | 有 | 仅 UI 辅助 |
| 多 Key 存储 | 无 | `vcpApiKey` 为单值 |
| Key 随机/轮询 | 无 | 无 Key 池 |
| 失败自动换 Key | 无 | 无客户端重选 |
| Key 熔断/恢复 | 无 | 无健康状态 |
| 普通请求自动重试 | 无 | 单次 `fetch` |
| 未设置采样参数自动省略 | 有 | `omitUnsetOptionalModelParams`，null/空值不进请求体 |
| Flowlock 工作流重试 | 局部有 | 最多 3 次新续写轮次 |
| 客户端请求超时 | 当前主链无 | 300 秒实现位于未接线模块 |
| 跨 URL/Provider failover | 无 | 服务端能力不归因给客户端 |
| 权重/成本/延迟路由 | 无 | 静态选模 |
| Secret 静态加密 | 无 | `settings.json` 明文 |
| 设置原子写入 | 有 | temp + 校验 + backup + move |
| 设置自动备份 | 有 | 每日复制，保留最新 7 份 |
| 全量备份包含凭据 | 是 | ZIP 默认包含根目录 settings |
| 配置导入恢复 | 未见 | 主要依赖文件操作 |
| 连接测试 | 基础有 | `/v1/models` 刷新 |
| 最小生成测试 | 无 | 未独立验证 Chat/stream/tool endpoint |
| 健康结果参与调度 | 无 | 无本地调度器 |

## 10. 对其他项目的可借鉴点

### 值得借鉴

- 客户端明确依赖统一 OpenAI-compatible 网关，Agent 侧只需保存模型和生成参数；
- 设置页用标准 `URL` API 规范化端点，避免手工字符串拼接造成重复路径；
- 工具注入通过独立 `/v1/chatvcp/completions` 路径表达，普通兼容接口仍保持清晰；
- 发送前清理消息内部字段，减少 UI 私有元数据意外进入模型上下文；
- 设置保存采用临时文件、回读校验、备份和移动，配置完整性处理较扎实；
- `requestId` 贯穿生成、流事件和中断接口，便于把一轮交互关联起来；
- renderer widget 通过受控代理调用主连接，避免每个 widget API 都显式接收凭据。

### 需要补强或谨慎复用

- 单网关设计简单，但客户端没有备用地址，网关故障会成为单点；
- 模型只用裸 ID，切换网关后使用统计和收藏可能发生命名碰撞；
- `/models` 探测不足以验证真实生成和工具端点；
- 普通请求缺少超时、可重试错误分类、退避和 `Retry-After`；
- Flowlock 的工作流重试不应被宣传为 transport 可靠性；
- 已实现但未接线的 `vcpClient.js` 容易让源码阅读者高估当前超时能力；
- Key、设置备份和 ZIP 均为明文，备份扩大了凭据副本数量；
- ZIP 默认包含 Key，却没有显式敏感数据提示或加密；
- 连接错误和延迟没有形成结构化指标，无法驱动自动容灾。

## 11. 关键源码索引

- 应用数据目录、模型目录和刷新 IPC：[`main.js`](../../VCPChat/main.js)
- 当前 Chat/SSE/中断请求主链：[`modules/ipc/chatHandlers.js`](../../VCPChat/modules/ipc/chatHandlers.js)
- 全局设置默认值、原子保存和每日备份：[`modules/utils/appSettingsManager.js`](../../VCPChat/modules/utils/appSettingsManager.js)
- Agent 配置：[`modules/utils/agentConfigManager.js`](../../VCPChat/modules/utils/agentConfigManager.js)
- URL 规范化与 Agent 设置 UI：[`modules/settingsManager.js`](../../VCPChat/modules/settingsManager.js)
- 模型使用和收藏：[`modules/modelUsageTracker.js`](../../VCPChat/modules/modelUsageTracker.js)
- 话题摘要请求：[`modules/topicSummarizer.js`](../../VCPChat/modules/topicSummarizer.js)
- Flowlock 工作流重试：[`Flowlockmodules/flowlock.js`](../../VCPChat/Flowlockmodules/flowlock.js)
- Flowlock 接入层：[`Flowlockmodules/flowlock-integration.js`](../../VCPChat/Flowlockmodules/flowlock-integration.js)
- 未接线统一请求模块：[`modules/vcpClient.js`](../../VCPChat/modules/vcpClient.js)
- 桌面 widget VCP 代理：[`Desktopmodules/api/vcpProxy.js`](../../VCPChat/Desktopmodules/api/vcpProxy.js)
- 一键 ZIP 备份：[`backup.py`](../../VCPChat/backup.py)
