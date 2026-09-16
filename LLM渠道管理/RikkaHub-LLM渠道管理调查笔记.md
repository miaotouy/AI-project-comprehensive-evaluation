# RikkaHub LLM 渠道管理调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9a35e3f2f1e2820e95c37deb82ef8f5e1592e06f`（分支：`master`）
>
> 调查方式：只读检查 `ai/`、`app/`、`oauth/` 模块源码与仓库文件；未修改目标仓库，未启动应用做界面或真实网络验证
>
> 调查范围：Provider/渠道数据模型与持久化、ProviderManager 注册、模型目录与静态能力推断、端点与请求组装、凭据与多 Key 轮询、二维码与 Chatbox/CherryStudio 导入、协议适配与流式解析、运行时选择、错误解析与重试。不含聊天界面模型选择器的交互细节，也不含 `oauth/` 模块的 MCP 授权流程
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 把「渠道」拆成两层：一层是可序列化的配置对象 `ProviderSetting`，另一层是无状态的运行时实现 `Provider<T>`。配置按协议只有三种子类（OpenAI、Google、Claude），序列化后写进一个单例 DataStore 的同一个字符串键；运行时按子类在 `ProviderManager` 里查到固定实现。因此一个协议类型对应一个实现类，而用户可以在同一类型下创建任意多个实例，实例彼此以 Uuid 区分。

内置渠道（AiHubMix、DeepSeek、OpenRouter 等）以固定 Uuid 写死在默认列表里，读取设置时会按 Uuid 补回缺失项并刷新展示信息，所以内置项在界面上不能删除、实质上也不会真正消失。用户新建的实例使用随机 Uuid，是唯一可删除的一类。

模型能力不来自远端也不来自模型卡：`ModelRegistry` 用一张静态的模型定义表，对模型 ID 做分词与打分匹配，推断输入/输出模态、工具与推理能力及上下文长度。远端 `listModels` 只刷新「有哪些模型 ID」，不刷新能力元数据。推断结果在模型加入渠道时会快照进 `Model` 对象。

请求组装完全按协议分支：OpenAI 子类内部再按 `useResponseApi` 在 Chat Completions 与 Responses 两个实现之间切换，Claude 走 Messages API，Google 子类再按 Vertex 开关与认证方式切换 URL 与凭据位置。用户自定义 Header 与自定义 Body 在最后合并，自定义 Body 递归合并进协议请求体。

运行时选择只做「模型 ID → 所属渠道」的线性查找，没有别名、语义路由、负载均衡或跨渠道故障转移。多 Key 仅做轮询：把 Key 字段按空白与逗号拆开，用持久化的 LRU 时间戳挑一个最久未用的；单个 Key 失败不会被记录、冷却或熔断。失败重试只在应用层对 `IOException` 生效，最多 3 次，且可用全局开关关闭。

## 系统边界与总体调用链

渠道配置属于 `ai/` 模块的数据层与 `app/` 模块的持久化层；协议请求属于 `ai/` 的 provider 实现；运行时选择属于 `app/` 的 `ChatService` 与 `GenerationLoop`。一次对话的主链路可概括为：

```text
Settings.providers : List<ProviderSetting>   (DataStore 单键 JSON)
  -> settings.findModelById(assistant.chatModelId ?: settings.chatModelId)
  -> model.findProvider(providers)           -- 线性扫描，命中 model.id
       └─ model.providerOverwrite 非空时改用它
  -> ProviderManager.getProviderByType(setting)   -- 按子类取实现
  -> Provider.streamText / generateText
       ├─ OpenAI 子类: ChatCompletionsAPI 或 ResponseAPI (useResponseApi)
       ├─ Claude 子类: ClaudeProvider  -> /messages
       └─ Google 子类: GoogleProvider  -> generativelanguage 或 Vertex
  -> 逐 SSE 事件交给各协议的 StreamChunkDecoder
  -> 通用 StreamChunk 流回到 StreamChunkHandler/UIMessage
```

app 层不直接持有协议实现，只通过 `ProviderManager` 以子类为键取实现；`ProviderManager` 在构造时一次性注册三个实现，之后不再变化。这一点决定了「新增一个协议」属于改动 `ai/` 模块的编译期行为，而不是运行时注册。

## 1. Provider、渠道与 Endpoint 数据模型

### 1.1 配置模型

`ProviderSetting` 是 kotlinx 序列化的密封类，公共字段为 `id`（Uuid）、`enabled`、`name`、`models`、`balanceOption`；`builtIn`、`description`、`shortDescription` 标了 `@Transient`，属于运行时展示信息，不落盘。三个子类各自带端点与凭据字段：

| 子类（`@SerialName`） | 默认 baseUrl | 端点字段 | 凭据字段 | 其它字段 |
|---|---|---|---|---|
| `ProviderSetting.OpenAI`（`"OpenAI"`） | `https://api.openai.com/v1` | `chatCompletionsPath`、`responsesPath`、`useResponseApi` | `apiKey` | `includeHistoryReasoning` |
| `ProviderSetting.Google`（`"google"`） | `https://generativelanguage.googleapis.com/v1beta` | `vertexAI`、`useServiceAccount`、`location`、`projectId` | `apiKey`、`serviceAccountEmail`、`privateKey` | — |
| `ProviderSetting.Claude`（`"claude"`） | `https://api.anthropic.com/v1` | — | `apiKey` | `promptCaching`、`promptCacheTtl` |

协议类型集合写死在 `ProviderSetting.Types`，顺序为 OpenAI、Google、Claude，设置页的类型切换按钮就直接遍历它。三个子类都实现了同一组模型增删改与搬移操作，以及一个 `copyProvider`。实现事实：模型搬移的方法名是 `moveMove`（含重复前缀），模型编辑方法名为 `editModel`。

`balanceOption` 包含开关、请求路径和结果 JSON 路径三部分，用于余额查询。本次只在 OpenAI 子类上看到余额查询的实际使用（详情页与 `ProviderBalanceText` 都限定为 OpenAI）。

### 1.2 渠道实体粒度

一个 `ProviderSetting` 实例对应一个可路由渠道：它同时携带名称、启用状态、端点、凭据和模型列表，数据模型里没有「一个渠道下挂多个 Endpoint」的结构。要接多个中转地址，只能创建多个实例，`id` 由 Uuid 区分。内置渠道与用户渠道在这一层没有结构差异，区别只在 `builtIn` 标记和固定的 Uuid。

模型对象 `Model` 的字段包括 API 侧模型名 `modelId`、展示名 `displayName`、内部标识 `id`（Uuid）、类型（CHAT/IMAGE/EMBEDDING）、输入输出模态、能力集合、内置工具集合、模型级 `customHeaders` 与 `customBodies`，以及一个模型级 `providerOverwrite: ProviderSetting?`。

`providerOverwrite` 让单个模型可以覆盖所属渠道的端点与凭据。选择时会先用覆盖对象替换渠道，并把它的 `models` 置空以避免 JSON 循环引用；设置页创建覆盖对象时同样显式清空模型列表。

### 1.3 Endpoint 的定义

本笔记把「渠道实例 + 其端点字段 + 凭据 + 模型列表」视为一个 Endpoint。路径拼接方式是按协议硬编码的：OpenAI 用 baseUrl 拼 `chatCompletionsPath` 或 `responsesPath`，Claude 固定拼 `/messages`，Google 的路径由 `vertexAI` 决定是 `models/{id}:...` 还是 `publishers/google/models/{id}:...`。自定义路径的能力只对 OpenAI 子类开放，且路径输入框对内置渠道禁用。

## 2. 配置生命周期、管理入口与持久化

### 2.1 存储

所有渠道配置放在同一个 DataStore Preferences 文件（名称 `settings`）里的一个字符串键 `providers`，值是 `List<ProviderSetting>` 的 JSON。`Settings` 数据类里 `providers` 的默认值就是内置默认列表。写盘走持久化函数，把整个 `Settings` 逐字段写入；读取时对 `providers` 键做 JSON 解码，为空则用默认列表。

读取管线是连续多次 `map`：先补齐缺失的内置渠道（按 Uuid 判断），再把内置渠道的 `builtIn`、`description`、`shortDescription` 用默认值覆盖回来，然后按渠道 Uuid 去重、按模型 Uuid 去重，最后过滤掉指向不存在模型的收藏项。这条管线同时解释了「内置渠道删不掉」和「内置渠道的说明文案随版本更新」两个可观察行为。

### 2.2 管理入口与操作覆盖

渠道管理集中在设置页的两个页面：列表页负责总览、排序与新增，详情页负责单渠道编辑与模型管理。详情页用两页 Pager 分成「配置」和「模型」两个视图。

| 操作 | 实现入口 | 内置渠道 | 自建渠道 |
|---|---|---|---|
| 查看 | 列表页展示全部实例与模型数；详情页配置页 | 支持 | 支持 |
| 新增 | 列表页新增按钮；初始为空的 OpenAI 子类，类型可再切换 | 不适用 | 支持 |
| 编辑 | 详情页字段即时改本地状态，点保存才写入设置 | 可改 Key、baseUrl、开关等字段；类型与路径不可改 | 可改名称、类型、端点、凭据、开关 |
| 类型转换 | 配置页顶部分段按钮，按 `convertTo` 转换子类 | 不显示 | 支持 |
| 复制 | 本次在列表页、详情页与数据层未找到实例级复制/克隆入口 | 未找到 | 未找到 |
| 启停 | 配置页开关写 `enabled` | 支持 | 支持 |
| 删除 | 详情页删除按钮，仅 `!builtIn` 时显示 | 不提供 | 支持 |
| 导入 | 列表页导入按钮：相机扫码或从相册识别二维码 | 支持 | 支持 |
| 分享/导出 | 详情页顶部分享按钮，展示二维码并可拉起系统分享 | 支持 | 支持 |
| 连接测试 | 详情页连接测试弹窗（三段式测试） | 支持 | 支持 |
| 余额查询 | 详情页余额区与余额文案，仅 OpenAI 子类 | 支持 | 支持 |
| 排序 | 列表页长按拖拽重排，写回 `providers` 顺序 | 支持 | 支持 |

「本次未找到」只表示在当前快照的源码搜索范围内没有对应入口，不代表历史版本或外部脚本没有该能力。

排序不只是展示顺序：运行时按 `providers` 列表顺序线性查找模型所属渠道，因此当两个渠道包含同一 `modelId` 的不同模型对象时，排序会影响谁先被命中。这是一个结构性的顺序依赖。

### 2.3 二维码导入导出协议

导出把渠道序列化成一行文本：前缀 `ai-provider:v1:` 后接 Base64 的 JSON，JSON 是渠道对象本身，但显式清空了 `models`（因此二维码只共享端点与凭据，不共享模型列表）。导入要求字符串以该前缀开头，解码后反序列化为 `ProviderSetting`，再作为新实例插入列表首位。

导入没有版本兼容或字段校验之外的额外处理：前缀不匹配会抛异常，扫码与相册两条路径都把异常转成 Toast 提示。导入得到的实例 `id` 仍是被分享方的 Uuid，随后由持久化管线的去重逻辑按 Uuid 处理。

### 2.4 Chatbox 与 CherryStudio 导入

两条导入来自备份/导入页，且只导入渠道与（Chatbox 的）会话，不涉及导出。

CherryStudio 导入器把备份当作 ZIP，读取其中的 `data.json`，再逐层取到 localStorage 里的持久化字符串、`llm` 字段和 `providers` 数组。它按 `type` 字段映射协议：`anthropic` 映射为 Claude 子类并补 `/v1`，`gemini`、`vertexai` 映射为 Google 子类并补 `/v1beta`，其余映射为 OpenAI 子类；`openai-response` 类型或模型带 `endpoint_type: "openai-response"` 时置 `useResponseApi`。没有 `apiKey` 的渠道会被跳过，最终按「协议 + baseUrl + apiKey」去重后整体插到列表头部。模型能力用 `ModelRegistry` 按模型 ID 现算后写入。

Chatbox 导入器面向 Chatbox 备份 v2：校验 `manifest.json` 的格式与版本，从 settings 文件里读 `providers` 对象，按 provider key 映射协议（`claude`/`anthropic`、`gemini`/`google`、其余 OpenAI 兼容），并用一张内置的 key 到 baseUrl 映射表补齐缺省端点（DeepSeek、Qwen、Moonshot、OpenRouter、SiliconFlow、Groq、xAI、Mistral、Perplexity 等）。它按 `apiStyle` 是否含 response 或模型级 `apiStyle` 决定 Responses 模式，模型能力来自 Chatbox 的 `capabilities` 数组（vision、image_generation、tool_use、reasoning）而不是本地注册表。同样跳过无 Key 的渠道；导入结果会与现有渠道按身份串去重，避免重复。

两个导入器都要求凭据非空，也就是「导入渠道」在实现上等价于「导入带 Key 的渠道」；同时导入对象的 Uuid 由字符串哈希派生（Chatbox 用 name-based UUID），因此同一份备份重复导入会命中相同 Uuid，而不是每次生成新实例。

`build.gradle` 层面没有单独的 provider 持久化迁移代码；渠道字段的变化靠 kotlinx 的默认值和 `ignoreUnknownKeys` 兜底，设置级迁移由 Version 1/2/3 三个迁移器处理，本次只确认它们存在于设置初始化路径，未逐行核对是否触及 `providers`。

## 3. 凭据、Header 与代理边界

凭据以明文存在渠道设置里。`apiKey` 直接写在 `ProviderSetting` 的 JSON 中，随 DataStore 文件落盘；私有 Key（Google 服务账号）与代理密码同样是明文字段。本次在数据层、备份层和请求层都没有找到加解密或掩码处理：写入就是 `copy(apiKey = ...)`，展示只是用密码输入框遮挡字符。

凭据会出现在四个可见位置。分享/二维码把完整 JSON（含 Key）Base64 编码后展示并可通过系统分享发出；备份会把完整 `Settings` 序列化为 `settings.json` 打进 ZIP（WebDAV/S3 备份项为数据库与文件）；请求日志在开启时会记录请求头与请求体；设置页的 Key 输入框可切换明文显示。请求日志的掩码只覆盖 `Proxy-Authorization` 一个头，`Authorization` 与 `x-api-key` 不在掩码范围内。

Header 分三层组装。协议层负责认证与内容类型（OpenAI 用 Bearer，Claude 用 `x-api-key` 加 `anthropic-version`，Google 用 `x-goog-api-key` 或 Vertex 的 Bearer/key 查询参数）；渠道层不加额外 Header；请求层在最后合并模型级与助手级的自定义 Header，并追加两个按来源域判断的 Header——aihubmix 追加 `APP-Code`，OpenRouter 追加 `X-Title` 与 `HTTP-Referer`。会话 ID 通过 `X-Session-ID` 下发，目标域为 opencode.ai 时额外加 `x-opencode-session`。

代理与传输参数来自全局网络设置：OkHttp 客户端挂载按设置动态选择的代理选择器与代理认证器，连接超时 20 秒、读超时 10 分钟、写超时 120 秒，并开启连接失败重试；拦截器统一注入 `Accept-Language` 与 User-Agent（未设置时用 `RikkaHub-Android/<版本>`）。代理配置变化时会清空连接池。这些属于全局设置而非单渠道字段，即渠道不能各自指定代理。

## 4. 模型目录与能力元数据

### 4.1 目录来源

模型目录有两个来源，且分工明确。远端来源是各协议的 `listModels`：OpenAI 与 Claude 请求 `baseUrl/models`，Google 请求 `models?pageSize=100` 并只保留支持 generateContent 或 embedContent 的项。远端返回只提供模型 ID 与展示名（Google 额外给 displayName 并按方法推断类型），不提供服务端能力或上下文长度。静态来源是 `ModelRegistry`，只负责能力推断。

界面上模型列表在进入详情页模型页时按渠道状态拉取一次并排序，然后把结果交给模型选择器；「全选」会批量加入远端返回但本地未选的模型。本次未找到显式的「刷新模型列表」按钮，列表随渠道对象变化重新拉取。

### 4.2 静态能力推断

`ModelRegistry` 维护一张模型定义表，每条定义由匹配器与三类元数据组成：输入模态、输出模态、能力集合，外加可选上下文长度。匹配基于把模型 ID 转成小写并切分成字母段、数字段与单字符，然后对各段序列做匹配；支持 token 序列、取反序列、正则段和精确 ID 四种形式，精确 ID 带 1000 分加权。解析时取所有定义里得分最高的一组，同分则合并；模态为空时回退为纯文本，能力取并集。定义表用 `defineGroup` 把多个定义聚合成一个逻辑组（如 `CLAUDE_SERIES`、`GEMINI_SERIES`），供请求层按系列判断。

推断结果在模型加入渠道那一刻被快照进 `Model`：手工新增时按输入 ID 现算并写入，从选择器添加或全选时同样现算，两个导入器也各自调用注册表补齐。因此注册表更新后，已加入的模型不会自动重算，除非重新添加模型或重新导入。界面上模型选择器展示的模态与能力标签是现算的，与已存储值可能不一致。

`contextLength` 只在极少数定义上给出（如 Claude 5 系列与部分 DeepSeek 为 1M），其余为 null；本次未找到上下文长度被用于请求裁剪的入口，只在注册表中作为元数据存在。

模型级还有一组与渠道协议无关的字段：类型、模态、能力、内置工具集合。内置工具是「服务端工具」的概念，包含搜索、URL 上下文与图像生成三项，随模型对象提交给支持它的协议；能力集合里的工具能力则决定是否下发客户端函数工具。

推理强度是全局枚举，取值为 off/auto/low/medium/high/xhigh/max，每个取值同时带预算 token 数与 effort 字符串，两者由各协议按需取用。

## 5. Adapter、协议与请求组装

### 5.1 协议分支与实现归属

`Provider` 接口定义 `listModels`、`generateText`、`streamText`、`getBalance`，并为 embedding 与图像生成/编辑提供默认实现（默认直接抛「不支持」）。OpenAI 子类的实现内部持有 ChatCompletions 与 Response 两个 API 对象，在两个入口按 `useResponseApi` 二选一，因此「切换协议」是渠道级开关而不是新类型。Claude 与 Google 各自只有一个实现类。`ProviderMessageUtils` 提供把消息 parts 按工具边界分组的公共逻辑，保证工具调用与其结果相邻。

### 5.2 OpenAI 兼容（Chat Completions）

请求地址是 baseUrl 拼渠道上配置的路径，认证用 Bearer。请求体先写模型名与消息数组，温度与 top_p 只在该模型允许时写入（o 系列、GPT-5 系列与部分 Kimi 模型被排除），随后是 max_tokens、stream 与流式的 usage 选项（Mistral 不写该选项）。推理参数按 baseUrl 的域名逐一适配：OpenRouter 写 reasoning 对象，阿里云百炼写 enable_thinking/thinking_budget，火山与智谱写 thinking.type，Moonshot 写 thinking.type 且对 K2.6 追加 keep，DeepSeek 写 thinking.type 与 reasoning_effort，NVIDIA、opencode 与默认分支写 reasoning_effort，Mistral 不写。函数工具仅在该模型具备工具能力且本次带有工具时下发。请求体最后与模型级、助手级的自定义 Body 递归合并，自定义值可覆盖协议字段。

### 5.3 OpenAI Responses

地址同样是 baseUrl 拼渠道上的 responses 路径。请求体固定 `store: false`，system 消息被提取为顶层 instructions，消息数组放进 input，推理写 reasoning.summary 与 effort，并可按服务端能力追加加密内容包含项。工具是扁平数组，函数工具与服务端工具共存于同一个键下（代码注释说明若分开写会互相覆盖），服务端搜索映射为 web_search，图像生成映射为 image_generation 并固定模型名，URL 上下文在该分支不支持。按域名解析的服务端能力只对火山关闭推理摘要与加密内容。

### 5.4 Claude（Messages API）

地址固定为 baseUrl 拼 `/messages`，认证头为 `x-api-key` 与 `anthropic-version: 2023-06-01`。system 消息作为顶层数组提交，max_tokens 缺省 64000。开启提示缓存时，会在顶层、system 最后一段、工具定义最后一项以及消息序列中插入 `cache_control: ephemeral`，TTL 由渠道配置的枚举决定（5 分钟不写 ttl，1 小时写 1h）。推理用 adaptive 模式加 output_config.effort，关闭时写 disabled。函数工具用 input_schema，服务端搜索映射为 `web_search_20250305`。

Claude 实现外还有一层针对 `pause_turn` 的续跑逻辑：非流式与流式都包在续跑封装里，最多续 5 次，每次把上一轮的服务端工具结果拼回请求，并对服务端工具索引做偏移重映射，最后把各轮 usage 累加。

### 5.5 Google / Vertex

未开 Vertex 时请求 `generativelanguage` 的 baseUrl，认证头为 `x-goog-api-key`；开 Vertex 且用服务账号时请求 `aiplatform.googleapis.com` 的项目级路径并用服务账号换取的 Bearer token 认证；开 Vertex 但用 API Key 时请求 `aiplatform` 的通用路径并把 Key 作为 `key` 查询参数。路径按是否 Vertex 在 `models/{id}:generateContent` 与 `publishers/google/models/{id}:...` 之间切换，流式端点固定加 `alt=sse`。请求体把 system 写成 systemInstruction，消息写成 contents，工具写成 functionDeclarations 与 functionResponse，服务端工具映射为 Google 的搜索与 URL 上下文档位。服务账号 token 由独立组件用私钥签发 JWT 换取，私钥在请求时先做 JSON 反转义。

### 5.6 流式解析

三个协议都用 OkHttp 的 SSE 事件源，把每个事件的 data 交给各自的解码器，解码器是有状态对象（每条流新建实例），负责把协议差异归一化成通用的 StreamChunk 事件：文本的 Start/Delta/End、推理的 Start/Delta/End、工具调用的 Start/Delta/End、图像的 Start/Delta/End、用量与结束事件。归一化在解码器内部按「切换 part 类型时先关闭上一个已开启段」的方式维护状态，并用序号生成稳定 ID。工具调用的多段增量按 index 聚合 ID。OpenAI 兼容解码器还会把 `[DONE]` 与 finish_reason 收敛为结束事件，并解析 OpenRouter 的 reasoning_details 增量与 URL 引注标注。

流式收集用无界的 callbackFlow 缓冲（注释说明有界的 trySend 会静默丢增量导致回复缺字），关闭时取消事件源。模块里另有一个自定义 SSE 事件源实现，但本次在 LLM provider 主链路中未找到它的调用方，三个协议都使用 OkHttp 自带的 SSE 工厂。

## 6. 运行时选择、绑定与路由

对话开始时先解析模型：用助手配置里的模型 ID，为空则回退到全局聊天模型 ID，再经 `findModelById` 按模型 Uuid 在全部渠道的模型列表中查找；查不到则抛「No chat model selected」。全局模型的默认值是一个固定 Uuid 常量，它不属于任何渠道的任何模型，因此未配置模型时该默认值不会被解析成功。

拿到模型后再解析渠道：`findProvider` 按 `providers` 列表顺序遍历，返回第一个包含同 `id` 模型对象的渠道；若模型带 `providerOverwrite` 且允许覆盖，则返回覆盖对象并把其模型列表清空。随后 `ProviderManager.getProviderByType` 按子类取运行时实现。整条链路是纯粹的线性查找与类型分发，没有别名表、模型名到渠道的映射、语义路由、权重或负载均衡，也没有重定向到其它渠道的机制。

除主对话外，快速模型、翻译、压缩、OCR、图像生成与会话标题等场景也各自按同一套 `findModelById` 加 `findProvider` 解析渠道，只是输入的模型 ID 来源不同。渠道的 `enabled` 字段不参与这条解析链，只在模型选择器过滤可见性时使用；也就是说禁用渠道只是不再出现在选择器里，本次未发现它在请求路径上做拦截。

## 7. 多 Key、重试与故障转移

### 7.1 多 Key 轮询

三个渠道实现都持有一个 Key 轮询器，在每次请求前用渠道的 Key 字段换取本次使用的 Key。轮询器把 Key 字段按空白与逗号切分、去重，两种策略按构造方式选择：无 Context 时用随机策略，有 Context 时用 LRU 策略（应用内注册的三个实现都走了 LRU 分支）。

LRU 策略按渠道 Uuid 分槽保存每个 Key 的最后使用时间，优先选从未使用过的 Key，否则选最久未使用的，并把本次使用时间写回。缓存文件位于应用缓存目录，结构是渠道到 Key 时间戳的映射，条目有效期 1 天，整个文件的读写放在同一个锁对象里以避免同一进程内多实现并发写坏。过期条目在读取时被丢弃，整槽过期的记录会被清理。

这套机制只做「用哪个 Key」，不记录 Key 的健康状态。本次未找到按 Key 的错误计数、冷却、熔断、恢复或失败后换 Key 的逻辑，因此某个 Key 持续失败时轮询仍会按 LRU 分派给它。

### 7.2 重试与故障转移

传输层开启了连接失败重试。应用层的重试发生在 `GenerationLoop`：对 `IOException` 最多重试 3 次，退避时长为 1 秒左移重试次数（即 1s、2s、4s），是否启用由全局网络设置的开关决定（默认开启）。重试前会先检查协程是否已被取消，以避免用户主动停止生成被误判为网络抖动；非网络类异常（例如下游消息处理失败）不重试。

流式重试的做法是从本次模型调用前的消息快照重新开始，并复用同一个助手消息 ID，从而覆盖当前分支而不是追加候选消息。非流式走同一套重试包装。

跨渠道故障转移、模型级 fallback、以及失败后自动换渠道都不存在：重试始终在同一个渠道实例上发生，失败最终以异常上抛，由聊天服务记录为会话错误。余额查询、连接测试与模型列表是独立请求，不参与这套重试。

## 8. 连接检测、日志与可观测性

连接测试弹窗针对当前渠道的三个维度并行发起真实调用：非流式补全、流式补全、带一个假工具的函数调用。它复用 `ProviderManager` 返回的真实实现和真实的 generateText/streamText 入口，只用一条固定的 system 加 user 消息；失败时展示异常消息并可在底部弹窗查看完整堆栈。因为走的是同一实现，测试能反映真实组装路径，但也意味着测试会消耗真实配额。

余额查询由协议的 `getBalance` 实现，地址由 baseUrl 与渠道的余额路径拼成（路径以 http 开头时直接使用），用同一个 Key 轮询器取 Key，返回体按配置的结果路径取字段；数值结果格式化为两位小数，非数值原样返回。界面上只有 OpenAI 子类展示余额，且需要渠道余额开关打开。

请求日志由网络拦截器实现，在开关打开时记录 URL、方法、请求头、请求体、响应码、响应头与耗时；请求头掩码只覆盖 `Proxy-Authorization`。另有一个 OkHttp 日志拦截器以 HEADERS 级别输出，同样只掩码该头。用量按 token 数解析后合并进消息对象，展示受全局显示设置控制。

本次在 `ai/` 与 `app/` 源码范围内未找到按请求记录花费、价格或延迟聚合的实现（对 cost、pricing 等关键字的搜索无结果）；可观测性目前限于连接测试、余额、用量 token、请求日志与错误信息。

## 9. 设计取舍与已确认边界

协议类型在编译期固定。新增协议需要同时改密封类、`ProviderManager` 注册与设置页分支；运行时不提供插件式注册入口，`registerProvider` 虽然在 API 上公开，但应用内没有调用方。这换来的是类型安全与设置页的直接映射。

凭据与配置同层同文件。凭据没有独立的凭据库或加密，Key 与端点、模型放在同一个 DataStore 键里，并随二维码、备份、请求日志三条路径对外流动；分享协议只剥离模型列表，不剥离 Key。本次未找到任何加密、脱敏或导出排除的实现，相关的边界是「默认全量」。

多 Key 只解决轮询，不解决可用性。轮询状态持久化在缓存目录，属于可丢失的派生数据；没有健康状态存储，因此不存在「某 Key 冷却中」的概念。重试与轮询是两条互不相干的逻辑：重试不感知 Key，轮询不感知错误。

渠道顺序具有语义。列表拖拽重排写回的是同一个 `providers` 数组，而运行时查找依赖其顺序，因此排序在含重复模型名的场景下会改变实际命中渠道。

启停的作用域有限。`enabled` 只影响模型选择器的可见性，不影响 `findProvider` 与请求路径；本次未找到在请求侧拒绝禁用渠道的校验。

无跨渠道、无模型 fallback、无自动上下文长度感知裁剪。这三项在当前快照中均未实现或不构成机制：故障始终落在同一渠道，上下文长度仅作为注册表元数据存在。

平台分工是单端的。渠道 CRUD、凭据与二维码都在 Android 应用内；内嵌 Web 服务只暴露助手级设置（模型选择、思考预算、内置工具、收藏模型等），不暴露渠道列表或 Key；`oauth/` 模块服务于 MCP 服务器授权，与 LLM 渠道凭据无关。仓库中未找到面向终端的 LLM 渠道管理入口。

## 10. 未验证事项

以下事项本次只做了静态代码阅读，未运行验证：二维码在真机上的扫码与相册识别结果、分享协议在外部应用间的传递、备份的导出与恢复（含 `settings.json` 的凭据落地形态）、Chatbox/CherryStudio 备份的真实文件结构与导入结果、连接测试与余额查询的实际返回、以及 Vertex 服务账号换取 token 的端到端可用性。

以下结论属于基于实现的推断而非运行事实：禁用渠道不会阻断请求（代码只在校验选择器处使用 `enabled`，未见请求侧校验）；已加入模型的模态与能力在注册表更新后保持旧值（推断自「加入时快照」的写入路径）；`settings.json` 中的 `providers` 使用 kotlinx 密封类多态形式（由 `@SerialName` 注解与序列化配置推断，未导出实际文件核对字段名）。

以下入口的状态未确认：`ai` 模块内的自定义 SSE 事件源实现是否仍被其它模块使用（本次全仓搜索只命中其自身定义）；设置级迁移器是否触及 `providers` 字段；`ModelRegistry` 定义表与真实模型能力的覆盖差异（表内条目数量与命名以当前快照为准，未与厂商文档比对）。

## 11. 关键源码索引

- 渠道配置模型：`ai/src/main/java/me/rerere/ai/provider/ProviderSetting.kt:26`（密封类与三个子类）、`:241`（`Types`）
- 模型对象与能力枚举：`ai/src/main/java/me/rerere/ai/provider/Model.kt:8`、`:41`
- 运行时注册与分发：`ai/src/main/java/me/rerere/ai/provider/ProviderManager.kt:12`、`:49`
- 运行时实现接口与生成参数：`ai/src/main/java/me/rerere/ai/provider/Provider.kt:17`、`:68`
- 静态能力推断：`ai/src/main/java/me/rerere/ai/registry/ModelRegistry.kt:596`、`:694`、`:716`
- 匹配器与 DSL：`ai/src/main/java/me/rerere/ai/registry/ModelDsl.kt:37`、`:161`
- 持久化与默认合并：`app/src/main/java/me/rerere/rikkahub/data/datastore/PreferencesStore.kt:61`、`:188`、`:263`、`:321`、`:710`
- 内置与推荐渠道：`app/src/main/java/me/rerere/rikkahub/data/datastore/DefaultProviders.kt:19`、`RecommendedProviders.kt:17`
- 二维码分享与解码：`app/src/main/java/me/rerere/rikkahub/ui/components/ui/ShareSheet.kt:89`、`:99`
- 渠道列表页与扫码入口：`app/src/main/java/me/rerere/rikkahub/ui/pages/setting/SettingProviderPage.kt:92`、`:337`
- 渠道详情页、模型管理与覆盖：`app/src/main/java/me/rerere/rikkahub/ui/pages/setting/SettingProviderDetailPage.kt:137`、`:385`、`:1432`
- 渠道表单与类型转换：`app/src/main/java/me/rerere/rikkahub/ui/pages/setting/components/ProviderConfigure.kt:48`、`:82`
- 连接测试：`app/src/main/java/me/rerere/rikkahub/ui/pages/setting/components/ProviderConnectionTester.kt:53`、`:122`
- Chatbox 导入：`app/src/main/java/me/rerere/rikkahub/data/sync/importer/ChatboxImporter.kt:170`、`:640`
- CherryStudio 导入：`app/src/main/java/me/rerere/rikkahub/data/sync/importer/CherryStudioProviderImporter.kt:19`、`:45`
- OpenAI 兼容请求与流：`ai/src/main/java/me/rerere/ai/provider/providers/OpenAI/ChatCompletionsAPI.kt:93`、`:133`、`:225`
- Responses 请求与能力：`ai/src/main/java/me/rerere/ai/provider/providers/OpenAI/ResponseAPI.kt:91`、`:209`、`:721`
- Claude 请求与缓存：`ai/src/main/java/me/rerere/ai/provider/providers/claude/ClaudeProvider.kt:244`、`:431`、`:546`
- Google / Vertex：`ai/src/main/java/me/rerere/ai/provider/providers/google/GoogleProvider.kt:90`、`:100`、`:213`
- 流式解码器：`ai/src/main/java/me/rerere/ai/provider/providers/OpenAI/ChatCompletionsStreamDecoder.kt:39`、`ai/src/main/java/me/rerere/ai/provider/stream/StreamChunkDecoder.kt:9`
- 多 Key 轮询：`ai/src/main/java/me/rerere/ai/util/KeyRoulette.kt:8`、`:56`
- 错误解析：`ai/src/main/java/me/rerere/ai/util/ErrorParser.kt:14`
- Header 与会话/自定义体合并：`ai/src/main/java/me/rerere/ai/util/Request.kt:14`、`:24`、`:57`
- 运行时选择与重试：`app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt:91`、`:404`、`:495`；`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt:666`
- 网络客户端与代理：`app/src/main/java/me/rerere/rikkahub/di/DataSourceModule.kt:116`
- 请求日志：`app/src/main/java/me/rerere/rikkahub/data/ai/RequestLoggingInterceptor.kt:9`
- 备份中的设置导出：`app/src/main/java/me/rerere/rikkahub/data/sync/BackupManager.kt:37`
