# OpenOcta LLM渠道管理调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：通读 Go 侧模型工厂、配置 schema、Gateway HTTP/WS 入口与 Lit 模型设置代码，并与 `docs/model-providers.md`、`docs/embedded-models.md` 对照；未运行 Gateway、桌面应用或真实模型请求
>
> 调查范围：Provider/Endpoint 数据模型、配置生命周期与桌面入口、凭据存储、模型目录、协议适配、运行时选择、失败与可观测性；不涉及聊天上下文构建细节、UI 视觉与打包流程
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的“渠道”是配置文件 `models.providers` 下的一个 provider 条目：键名就是模型引用里的 provider 标识，值是单一 `baseUrl`、单一 `apiKey` 和一个可手填的模型数组。代码另有一张内置 provider 模板表，用于在用户没有写配置时提供默认端点与环境变量名。同一个 provider 可以挂多个模型，但不能有多个 Endpoint。

模型引用固定为 `provider/modelId`，首个斜杠前解析为 provider，其余全部作为模型名；没有斜杠时默认为 anthropic。真正的协议适配只有两条：Anthropic Messages（eino-ext 的 claude 组件）和 OpenAI Chat Completions（eino-ext 的 openai 组件）。Gemini、Bedrock、Cohere 等没有独立适配器，`api` 字段除 anthropic 两个别名外一律落到 OpenAI 兼容分支。

配置的全部可写入口是桌面 Control UI 加 Gateway 的配置读写接口，落盘为状态目录下的 `openocta.json`。Go 侧没有模型管理 CLI 子命令；内置 provider 模板不能在界面上“启用/禁用”，只能写入或删除配置。保存后模型解析在每次 `chat.send` 时重新读取内存中的配置对象，但会话级运行时池会复用旧实例（详见第 6 节）。

凭据边界偏薄：provider 的 `apiKey` 以明文或 `$ENV` 引用保存在同一个配置文件，`config.get` 会连原始文本一起返回，日志脱敏字段只存在于 schema。入站 API Key（`octa_` 前缀）是另一套机制，做了哈希与 AES-GCM 加密，和上游模型凭据无关。

失败处理没有实现重试、Key 轮换或跨渠道故障转移：`agents.defaults.model.fallbacks` 与 `auth.cooldowns` 只在 schema 中声明；模型调用失败后错误直接结束该次运行并写入会话转写。可观测面主要是 token_usage JSONL 与 usage 聚合，没有单价表，成本统计基本为空；另外 CozeLoop 链路追踪在默认配置下开启并带内置工作区凭据。

## 系统边界与总体调用链

桌面端是 Wails 窗口内嵌 Lit 控制界面，业务请求走本机 Gateway（默认 `127.0.0.1:18900`）的 HTTP/WS 接口。渠道配置由 UI 组装成一次配置 patch，后端合并后整文件写回；模型实例则在发起对话时才按 `modelRef` 创建。

一条完整的对话级主链如下：

1. 聊天页维护 `chatModelRef`，空值表示“使用默认配置”；下拉选项由 `agents.defaults.models` 的别名和 `models.providers.*.models` 合并生成（`ui/src/ui/app-render.ts:2585-2641`）。
2. 前端通过 WebSocket 发送 `chat.send`，把所选引用放进 `modelRef`（方法白名单见 `src/pkg/gateway/ws/hub.go:103`）。
3. 处理器先取请求显式引用，取不到再按会话键解析 Agent 默认模型（`src/pkg/gateway/handlers/chat.go:2117-2125`）。
4. 用该引用创建模型工厂；显式引用走 `CreateModelFactoryForModelRef`，否则走 `CreateModelFactoryFromConfig`（`chat.go:2162-2166`）。
5. 工厂解析 provider 与模型，组装 claude 或 openai 客户端（`src/pkg/agent/eino/model_factory.go:183-280`）。
6. 工厂随运行时选项进入会话运行时池；池未命中时调用 `runtime.New`，在构建 Eino 引擎时执行一次 `ChatModel(ctx)` 拿到具体模型实例（`src/pkg/agent/eino/engine.go:71-74`）。
7. 流式事件由 Eino 迭代器转成 `message_delta`、`content_block_delta` 等事件，经 WS 广播给前端（`src/pkg/agent/stream/event.go:6-24`、`src/pkg/agent/eino/event_bridge.go:299-435`）。

在这条链里，`modelRef` 是唯一的渠道选择依据；没有按任务类型、成本或延迟的语义路由。OpenAI 兼容的对外接口 `/openocta/open/v1/completion` 复用同一套 `chat.send`，只是额外校验入站 Key 的模型白名单（`src/pkg/gateway/http/open_api.go:145-157`）。

## 1. Provider、渠道与 Endpoint 数据模型

“Provider”在本项目里有两层含义，需要分开：

| 层级 | 表示 | 是否用户可建多个 | 位置 |
| --- | --- | --- | --- |
| 内置模板 | 代码里的 `builtInProviders` 映射，含默认 baseUrl、凭据环境变量名、默认模型、是否用 Anthropic 协议 | 否，固定 25 项 | `src/pkg/agent/eino/model_factory.go:26-52` |
| 用户 provider | `models.providers` 的 map 条目，键名即引用前缀 | 是，任意键名 | `src/pkg/config/schema.go:466-484` |
| 模型 | provider 内的 `models[]` 条目，含 id、显示名、上下文与输出上限、价格、模态 | 是，同一 provider 下多个 | `schema.go:487-498` |
| 内嵌模型 provider | 运行时自动维护的两个固定键：对话与向量 | 否，由进程状态生成 | `src/pkg/embeddedmodels/provider_config.go:12-22` |

用户 provider 的能力字段中，实际进入请求的只有端点、密钥和协议类型三项，其余字段只存在于配置结构里。

- **provider 级声明未消费**：自定义 Header、密钥前缀、鉴权方式、鉴权 Header 开关、环境变量映射。
- **模型级声明未消费**：模型自己的 Header，以及兼容性开关（例如最大输出字段名）。

判断依据是对这些字段名做全仓库检索：除 schema 定义与 UI 表单类型外，模型请求路径没有命中（IM 渠道里的 `frame.Headers` 与模型无关，结构见 `src/pkg/config/schema.go:472-498`）。因此“自定义 Header 鉴权”这类配置虽然能写进文件，却不会影响模型请求。

模型引用的解析规则只有一次按首个斜杠切分：前段为 provider，后段完整保留（`src/pkg/agent/eino/model_factory.go:82-91`）。因此 `openrouter/anthropic/claude-sonnet-4-5` 会得到 provider `openrouter` 与模型 `anthropic/claude-sonnet-4-5`。裸模型名默认归到 anthropic，这既是兼容旧配置的兜底，也意味着把 `gpt-4` 这样的裸名写进默认模型时，请求会发往 Anthropic 客户端。

`models.mode` 声明了 `merge` 与 `replace` 两种语义，但除 schema 和默认配置模板外没有消费点；实际合并行为由配置 patch 的深度合并逻辑决定（见第 2 节）。

## 2. 配置生命周期、管理入口与持久化

配置路径由状态目录推导，文件名固定为 `openocta.json`：

- Linux 与 macOS 落在用户主目录下的 `~/.openocta/`，Windows 落在 `%APPDATA%\openocta\`。
- 状态目录可用 `OPENOCTA_STATE_DIR` 覆盖，配置文件也可用 `OPENOCTA_CONFIG_PATH` 直接指定；旧版 `.clawdbot` 目录仍被兼容读取。

首次启动时若文件不存在，会把内嵌的示例配置写到规范路径，权限 0600。桌面运行模式下，如果网关使用 token 鉴权，还会把 token 强制改成内置固定值；password 模式不动。路径解析与初始化逻辑见 `src/pkg/paths/paths.go:23-79`、`src/pkg/config/config.go:26-58`，token 改写见 `config.go:80-116`。

管理入口覆盖情况按前端逐项记录如下。“配置”指直接编辑 `openocta.json`；“CLI”指专用子命令，通用的 `gateway call` 可以透传任意 Gateway 方法。

| 操作 | 桌面 Control UI | Gateway API | 配置文件 | CLI |
| --- | --- | --- | --- | --- |
| 查看 provider 列表 | 有，内置模板与自定义分组展示 | `GET /api/config` 返回完整配置 | 直接可读 | 无 |
| 新增 provider | 有，弹窗填 id、显示名、baseUrl、apiKey、前缀 | `POST /api/config/patch` | 手写 | 无 |
| 编辑 provider | 有，改显示名、baseUrl、apiKey、api 类型 | 同上 | 手写 | 无 |
| 新增/删除模型 | 有，模型表内增删 | 同上 | 手写 | 无 |
| 模型级环境变量 | 有，写入 `env.modelEnv` | 同上 | 手写 | 无 |
| 设为默认模型 | 有，写 `agents.defaults.model.primary` | 同上 | 手写 | 无 |
| 删除 provider | 有；内置模板仅在已写入配置后允许删除 | 同上 | 手写 | 无 |
| 复制 provider | 本次未找到 | 无专用接口 | 手工复制键 | 无 |
| 启用/停用 | 本次未找到开关；删除即停用 | 无 | 无 | 无 |
| 导入/导出 | 本次未找到专用入口 | 无专用接口 | 文件级复制 | 无 |
| 连接测试 | 本次未找到；仅内嵌模型有“测试对话” | 无 | 无 | 无 |

UI 侧的操作实现集中在 `ui/src/ui/app-models.ts:38-388`，按动作可以分成四段：

- 新增 provider 时把 id 规范化为小写连字符键，并预置 OpenAI 兼容协议。
- 编辑通过把补丁合并进本地表单对象完成。
- 保存时把各 provider 的环境变量映射汇总到顶层环境变量，冲突键直接拒绝保存。
- “使用该模型”会写默认引用并立即提交 agents 补丁。

删除内置模板与自定义 provider 的判定另在 `ui/src/ui/views/models.ts:118-127`。

表中标为“本次未找到”的行，检查范围是模型设置页的按钮与事件绑定、配置结构定义，以及 Gateway 的 HTTP/WS 路由；未发现对应入口或专用接口。

保存语义是“读一次快照拿 baseHash，再整文件覆盖”。HTTP 入口要求 `baseHash` 与当前文件哈希一致，否则提示重新读取；合并使用原始 JSON 文本为基底以保留未知键，写盘后再解析成结构体并替换内存配置（`src/pkg/gateway/http/config_api.go:126-193`）。WS 侧的 `config.patch` 同样是这个流程，且只在补丁包含 `channels` 时热重载 IM 渠道运行时（`src/pkg/gateway/handlers/config.go:256-363`）。也就是说，**保存模型配置不会主动清理或重建模型运行时池**。

由于 `chat.send` 优先使用内存中的 `ctx.Config`（`src/pkg/gateway/handlers/sessions.go:1064-1078`），UI 保存后的模型解析会立刻看到新配置；但外部手工改文件不会刷新这个内存对象，直到下一次配置接口调用。对于已经池化的会话运行时，adapter 仍是旧实例（见第 6 节）。

## 3. 凭据、Header 与代理边界

上游凭据只有一个字段：provider 的 `apiKey`。它的取值规则按顺序有三条：

- 字面量直接使用。
- 以 `$` 开头时去掉前缀，把余下部分当作环境变量名解析。
- 留空时按 provider 名推导，形如 `<PROVIDER>_API_KEY`，连字符转下划线。

环境变量的查找顺序是：模型级映射、顶层环境变量映射、进程环境（`src/pkg/agent/eino/model_factory.go:54-80`）。内置 provider 的密钥名固定在模板表中，例如 OpenRouter 用 `OPENROUTER_API_KEY`，Hugging Face 用 `HUGGINGFACE_HUB_TOKEN`。

静态存储就是状态目录下配置文件里的明文：写盘权限 0600，没有任何字段级加密，示例配置还预置了一个占位密钥（`src/prompt/prompt-zh/openocta.json.example:6-13`）。

读取侧有三条路径都会把密钥结构原样带出：

- WS 的 `config.get` 返回完整快照，包含文件原文与解析后的结构（`src/pkg/gateway/handlers/config.go:36-48`、`659-670`）。
- REST 的 `GET /api/config` 不返回原文，但同样返回含密钥的解析结果（`src/pkg/gateway/http/config_api.go:29-36`、`69-76`）。
- 模型可调用的 `gateway_config` 工具，暴露读取、schema、环境变量、打补丁四个动作（`src/pkg/agent/tools/gateway.go:16-22`）。

因此密钥会原样回到前端，也会被模型通过工具读到。

日志侧没有脱敏实现：`logging.redactSensitive` 与 `redactPatterns` 只出现在 schema（`src/pkg/config/schema.go:11-18`），全仓库没有读取点。是否有密钥实际进入日志取决于各调用点的打印内容，本次未逐条核对，因此只能确认“配置了也不会生效”。

代理边界是显式的：模型流量统一使用禁用代理的 HTTP 客户端，注释说明本机代理会让部分厂商 TLS 握手失败。该客户端总超时 180 秒，响应头超时 30 秒，空闲连接 90 秒（`model_factory.go:106-123`）。因此系统代理、`HTTP_PROXY` 对模型请求无效，需要走代理的网络环境只能改 baseUrl 指向本地转发。

入站 Key 是另一套体系，容易与上游凭据混淆。`apikeys` 服务生成 `octa_` 前缀的随机密钥，保存 SHA-256 哈希用于校验，同时用由存储路径派生的密钥做 AES-GCM 加密以支持管理端回显；明文只在创建和轮换时返回一次（`src/pkg/apikeys/service.go:167-218`、`src/pkg/apikeys/crypto.go:13-37`）。它还带路径白名单、模型白名单、月度 token 上限和数字员工绑定（`service.go:384-467`），在对外接口 `/openocta/open/v1/completion` 上强制执行。

## 4. 模型目录与能力元数据

模型目录有三个来源，彼此不合并成一个统一目录：

- **内置模板**：每个模板给一个默认模型名，仅用于未显式指定模型时的兜底；`vllm`、`litellm`、`huggingface` 等没有默认模型，必须显式给出（`model_factory.go:26-52`、`212-246`）。
- **用户手填**：provider 的 `models[]` 由 UI 逐条添加，字段只有 id、显示名、上下文窗口、最大输出，其余能力字段需手写配置文件（`ui/src/ui/app-models.ts:114-145`）。
- **内嵌模型运行时**：启动本地 GGUF 后，按运行快照生成 provider 条目，上下文和输出上限取自内置 catalog（`src/pkg/embeddedmodels/provider_config.go:39-99`）。

没有远端模型列表拉取：本次未找到调用厂商 `/models` 的代码路径，`models.list` 的处理器虽然存在，但服务端注入的实现固定返回空切片（`src/pkg/gateway/http/server.go:200`、`src/pkg/gateway/handlers/models.go:15-25`）。UI 的模型下拉因此完全依赖配置里的模型数组；内置模板在没有配置 models 时会显示默认模型名（`ui/src/ui/views/models.ts:147-153`）。

能力元数据的使用面很窄。`contextWindow` 是唯一进入运行时预算的字段：它被当作会话历史裁剪的 token 上限传给运行时（`src/pkg/agent/model_factory.go:108-134`、`src/pkg/gateway/handlers/chat.go:2317-2319`）。`maxTokens` 会作为客户端最大输出传给适配器；`reasoning`、`input`、`cost`、`compat` 在本快照中没有请求侧消费点。价格字段不参与成本计算，见第 8 节。

内嵌模型目录另有一套静态表：可下载模型、GGUF 地址、量化、上下文与向量维度写在 `src/pkg/embeddedmodels/catalog.go`，模型广场的前端目录由脚本从外部列表生成。二者只按 id 对齐，运行状态由 manifest 维护。

## 5. Adapter、协议与请求组装

适配器选择发生在创建工厂时：若 provider 配置的 `api` 等于 `anthropic` 或 `anthropic-messages`，就用 claude 客户端；否则一律用 openai 客户端（`model_factory.go:203-208`）。两边的组装都很薄——只传 API Key、模型名、可选 baseUrl、可选最大输出，再挂上前面提到的直连 HTTP 客户端（`125-154`）。没有自定义 Header 注入、没有请求体重写、没有 `max_tokens` 字段名兼容分支，schema 里的 `compat.maxTokensField` 也没有被读取。

Anthropic 分支在未配置 baseUrl 时使用 SDK 官方端点；OpenAI 分支同理。`apiKey` 前缀不会自动补 `Bearer`，由 SDK 负责。Builtin 模板声明了是否使用 Anthropic 协议，`kimi-coding`、`synthetic`、`xiaomi`、`minimax` 四项走 Anthropic 兼容路径。

唯一的“非标准协议”是讯飞图片理解：当 provider 名为 xunfei/spark 且本次请求带图片附件时，处理器改用自定义 WebSocket 客户端，用 HMAC-SHA256 生成鉴权 URL，走 `spark-api.cn-huabei-1.xf-yun.com` 的图片接口（`src/pkg/gateway/handlers/chat.go:2144-2188`、`src/pkg/agent/xunfei_image.go:20-80`）。凭据需要 `XUNFEI_APP_ID`、`XUNFEI_API_KEY`、`XUNFEI_API_SECRET` 三项；缺省时回退到 OpenAI 兼容端点并记一条警告。这是本快照中唯一按“模型能力 + 输入模态”改变协议路径的分支。

内嵌模型走的是另一条链路：provider 的 baseUrl 指向 Gateway 自己的 OpenAI 兼容代理 `/api/embedded-models/v1`，请求体里的 `model` 字段决定转发到哪个本地实例。启动模型时分配回环端口并注册 OpenAI 路由（`src/pkg/embeddedmodels/runtime.go:162-197`），代理按模型 id 查运行时并转发，超时 5 分钟（`src/pkg/embeddedmodels/chat_proxy.go:12-56`）。对话与向量共用同一代理前缀，但分别只能命中对应类型的实例。

流式消费由 Eino 回调与事件桥接完成，不区分厂商：模型流片段被转成内容块增量，工具调用、工具结果和用量各自成事件。上游若返回 `finish_reason=length`，只作为停止原因映射，不触发重试或续写（`src/pkg/agent/eino/event_bridge.go:153-206`）。

## 6. 运行时选择、绑定与路由

解析顺序是：请求显式 `modelRef` → 会话键解析出的 Agent 配置里的 `model`（字符串或 `{primary}`）→ `agents.defaults.model.primary` → 空（`src/pkg/agent/model_factory.go:59-77`）。Agent 的查找先按会话键第二段匹配 id，再找 `default` 标记，最后取列表首项（`26-46`）。

运行时池以会话键为粒度，指纹包含工作区、Agent id、数字员工 id、模型引用、讯飞图片模式、Web 搜索开关、系统提示覆盖、工具 schema 标记、系统提示版本，以及排序后的 MCP 与 Skill 键（`src/pkg/gateway/handlers/chat_runtime_pool.go:15-46`）。指纹一致就复用已有运行时，否则关闭重建（`src/pkg/agent/runtime/pool.go:85-101`）。

这里有一个由实现结构可以推出的行为边界：指纹不含 provider 的 baseUrl、apiKey、api 类型或模型参数，而这些值只在创建引擎时被读进 adapter（`src/pkg/agent/eino/engine.go:71`）。因此修改同一 provider 的端点或密钥后，已池化会话仍会用旧连接参数，直到模型引用变化、系统提示版本变化、MCP/Skill 集合变化，或运行时被显式驱逐。UI 保存配置不会触发驱逐；`vault.sync` 会调用 `EvictAllSessionRuntimes`，这是本快照中唯一会清空全部会话运行时的调用点（`src/pkg/gateway/handlers/vault.go:557-570`）。该结论是代码结构推断，未用运行中的 Gateway 验证。

别名不参与路由。`agents.defaults.models` 的 `alias` 只在聊天页生成下拉标签时使用（`ui/src/ui/app-render.ts:2599-2613`），Go 侧没有读取该映射的代码。因此别名不能当作模型引用的短写。

并发上，同一会话键的运行时被互斥占用；等待超时后先驱逐再等 5 秒，仍失败则返回“运行时仍忙”的错误（`src/pkg/gateway/handlers/chat.go:3190-3208`）。这属于会话调度，不是模型重试。

## 7. 多 Key、限流、重试与故障转移

上游 Key 没有多 Key 概念：`ModelProvider.APIKey` 是单个字符串，代码里没有 Key 列表、轮询、冷却或健康状态。`auth.cooldowns` 结构声明了计费退避、失败窗口等字段（`src/pkg/config/schema.go:359-365`），但没有读取点。

模型调用没有重试层。检索 `retry`、`backoff`、`fallback` 等关键词，命中的是下载重试、MCP 传输回退、渠道消息回退和运行时池忙重试，模型请求路径没有命中。`agents.defaults.model.fallbacks` 只在 schema、注释和示例配置里出现（`schema.go:575-579`、示例 `src/prompt/prompt-zh/openocta.json.example:71-74`），没有执行逻辑。

失败处理的实际形态是逐次冒泡：工厂创建失败会写一条错误到会话转写并结束本次运行（`chat.go:2167-2171`），运行时创建失败同样处理（`2365-2368`），运行中 panic 会尽量先冲刷已生成的部分文本再记错（`2097-2115`）。对外 OpenAI 兼容接口把错误映射成 HTTP 状态（`src/pkg/gateway/handlers/open_api_chat.go:330-350`）。因此不存在“同渠道重试”“换 Key 重试”或“跨渠道 failover”的区分，三层都没有实现。

限流只有入站维度：入站 Key 的月度 token 上限在请求前检查，额度用 1 个 token 做预检；耗用量在运行结束后累加（`src/pkg/gateway/http/open_api.go:154-157`、`src/pkg/gateway/handlers/open_api_chat.go:129`）。上游 429 或配额错误不会被转成冷却状态，只会作为本次错误返回。

## 8. 连接检测、日志与可观测性

没有渠道级连接测试。模型页没有“测试”按钮或探测请求，Gateway 也没有对应的方法；唯一类似能力是内嵌模型的“测试对话”，它通过 Gateway 代理发一条真实 completion（`ui/src/ui/controllers/embedded-chat-test.ts`、`src/pkg/gateway/http/embedded_models.go:321-327`），因此不能用来验证远程 provider 的 Key。

用量采集依赖 Eino 的全局回调：每次模型调用结束把输入、输出、缓存命中与总量追加成一条 `token_usage` JSONL 到会话转写（`src/pkg/agent/eino/usage_callback.go:36-73`、`207-240`）。写入时 provider 参数固定传空字符串，所以按 provider 汇总不可用；`model` 取回调配置里的模型名，通常只有模型 id，不含 provider 前缀。

成本统计基本为空：聚合逻辑只在转写条目自带 `cost` 时累计，否则记入 `missingCostEntries`（`src/pkg/session/usage.go:855-880`）；而用量写入器不产生 cost，schema 里的单价表也没有被使用。因此 `usage.cost` 能返回结构，但价格字段通常为零。价格表和模型 `cost` 字段属于“有 schema、无计算”。

链路追踪是默认开启的。若配置没有 `cozeloop` 段，`resolveCozeLoopSettings` 返回启用并填入内置的工作区 id 与 API Token；示例配置同样默认 `enable: true` 并带同一组值（`src/pkg/agent/eino/cozeloop.go:81-98`、`src/prompt/prompt-zh/openocta.json.example:59-64`）。启用后所有 Eino 组件回调（模型、工具、Agent）都会导出到 CozeLoop，导出内容包括输入输出与 Agent 事件序列（`src/pkg/agent/eino/cozeloop_parser.go:22-60`）。

关闭需要同时满足两个条件：显式写入 `cozeloop` 段的 `enable` 或 `enabled` 为 false，且 token 与 workspace 都为空。函数末尾还有一次兜底——只要 token 和 workspace 都有值（来自配置或 `COZELOOP_*` 环境变量），即使显式写了 false 也会重新置为启用（`cozeloop.go:109-111`）。

普通日志按级别写文件并可按日期滚动，UI 通过 `logs.tail` 读取尾部若干行，带行数、字节数与游标限制（`src/pkg/gateway/handlers/logs.go:15-60`）。没有按请求维度归一化的上游错误码、延迟或重试计数。

## 9. 设计取舍与已确认边界

- **以字符串引用为唯一路由契约**：`provider/modelId` 同时承担渠道与模型选择，优点是配置和 UI 都简单，代价是 provider 级参数变更无法表达为“引用变化”，运行时缓存因此可能保留旧参数。
- **薄适配层**：只依赖两个 eino-ext 组件，Anthropic 与 OpenAI 兼容覆盖了绝大多数厂商；代价是 Gemini 原生协议、自定义 Header 签名等需要靠自建网关（如 LiteLLM）绕行。
- **单 Key、单端点**：配置结构不支持 Key 池与多 Endpoint，也就没有轮换、冷却和熔断状态需要持久化。
- **模型流量直连**：明确禁用代理以避免本机代理导致的 TLS 失败，这与常见“读取系统代理”的桌面应用默认相反。
- **本地模型经 Gateway 代理**：多个 GGUF 实例端口不同，用统一 baseUrl 加请求体 `model` 路由，使同一 provider 下可以挂多个本地模型。
- **配置写盘整文件覆盖**：以原始文本为基底做深度合并，保留未知键，但没有 JSON Schema 校验；写盘后仅做结构体解析。
- **桌面优先**：默认网关只监听回环、使用固定 token，模型管理没有 CLI 入口，远程运维需要自行改配置或接 HTTP API。

已确认的实现边界：

- 模型配置的热生效只到“下一次解析引用”这一层；已池化运行时的 adapter 参数不会自动刷新。
- `models.mode`、provider 的 headers/auth/envVars、模型 compat/cost、`fallbacks`、`auth.cooldowns`、日志脱敏均为声明未消费。
- 入站 Key 与上游 Key 是两套独立凭据，前者有加密与白名单，后者没有。
- `models.list` 在服务端固定为空，UI 模型选择器读的是配置快照而非该接口。

## 10. 未验证事项

- 未运行桌面应用或 Gateway，因此 UI 保存后的实际生效时机、并发 patch 的行为、Windows 与 macOS 的路径差异均未实测。
- “修改 provider 端点后旧会话仍用旧参数”来自指纹与引擎构建顺序的静态推断；未构造请求验证池复用时的连接目标。
- 内嵌模型的端口分配、Gateway 重启后的恢复、以及启动/停止对配置文件的实际改写未运行验证；仅按代码与文档描述记录。
- CozeLoop 是否真的能连上远端、失败时是否影响对话，本次未验证（`SetupCozeLoop` 失败只记警告）。
- 未核对各厂商端点对 `maxTokens` 字段名的兼容性，`compat.maxTokensField` 未被读取意味着该差异目前无处声明。
- 未运行测试；仓库内 `src/pkg/agent/eino/model_factory_test.go` 覆盖了内嵌向量 provider 被拒绝等少量分支。

## 关键源码索引

- `src/pkg/agent/eino/model_factory.go`：内置 provider 表、Key 解析、协议选择、客户端组装
- `src/pkg/agent/model_factory.go`：Agent 默认模型解析、上下文窗口预算
- `src/pkg/config/schema.go`：`models.providers`、模型能力、cooldown、memory 等配置结构
- `src/pkg/config/config.go`、`src/pkg/paths/paths.go`：配置加载、默认初始化与路径解析
- `src/pkg/gateway/handlers/chat.go`：`chat.send` 的引用解析、工厂创建与运行时池接入
- `src/pkg/gateway/handlers/chat_runtime_pool.go`、`src/pkg/agent/runtime/pool.go`：运行时指纹与复用/驱逐
- `src/pkg/gateway/http/config_api.go`、`src/pkg/gateway/handlers/config.go`：配置读写、哈希校验、深度合并
- `ui/src/ui/app-models.ts`、`ui/src/ui/views/models.ts`：桌面端 provider 与模型管理操作
- `src/pkg/embeddedmodels/provider_config.go`、`runtime.go`、`chat_proxy.go`：内嵌模型 provider 注册与本地推理代理
- `src/pkg/apikeys/service.go`、`crypto.go`：入站 API Key 的哈希、加密、白名单与用量
- `src/pkg/agent/eino/usage_callback.go`、`src/pkg/session/usage.go`：token 用量与成本聚合
- `docs/model-providers.md`、`docs/embedded-models.md`：厂商与内嵌模型的用户侧说明
