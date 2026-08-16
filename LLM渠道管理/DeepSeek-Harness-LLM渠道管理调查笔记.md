# DeepSeek-Harness LLM 渠道管理调查笔记

> 调查对象：`../../deepseek-harness`（重点 `packages/llm/`，关联 `packages/credentials/`、`packages/settings/`、`packages/core/agent-loop`、`packages/bundle/base`）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：静态源码阅读：`packages/llm` 全部包源码与 README、agent-loop 请求路径、credentials/settings 服务与文件 provider、dsh 基座 bundle 与 examples 组合、`docs/subsystems/llm-streaming.md` 与 `docs/config-catalog.md` 对照；未运行真实 Provider 请求，未执行测试
>
> 调查范围：llm capability seam 三角色（Service Definition / Provider / Consumer）、两个 DeepSeek 渠道适配器、pi-ai 复用边界、凭据与配置生命周期、流式词汇与组装、重试与 token 计量、默认模型解析与 dsh 基座配置；未覆盖 web Models 页 UI 交互细节、ACP/JSON-RPC 通道、会话持久化格式
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的 LLM 渠道管理是"一个中性流式词汇 + 一个注册表 + 两个实现同一 seam 的适配器"：

1. **Provider 是注册键，不是用户实体。** 抽象服务 `LlmRuntime`（`packages/llm/llm/src/index.ts:284`）持有 provider route → adapter 实例的注册表；route 是普通字符串（如 `deepseek-official`、`openai`、自建网关名），同一 adapter 实例可注册多条 route，注册与替换全有或全无且同步原子（`index.ts:338-413`）。用户没有"新建渠道"的数据表或 UI 实体，渠道的增删改全部表达为组合配置与用户 settings 文档。
2. **双适配器验证 seam 中性。** `dsh-llm-deepseek`（直连 fetch + SSE）与 `dsh-llm-pi-ai`（经 pi-ai 库）自始一起实现同一 `StreamChunk` 协议，目的是让"中性词汇"不被单一实现带偏（Agent Note 2026-06-13-twin-llm-adapters）。直连适配器独占 `deepseek-official` route，pi-ai 适配器的目录 route 名（如 `deepseek`）与之刻意区分，一份组合可以同时挂两个 DeepSeek 路径。
3. **pi-ai 只贡献模型目录、Provider 构造与事件流。** dsh 复用 pi-ai 的 `Models` 集合、Provider/Model/Api 类型、安装目录、createProvider、streamSimple 事件词汇和思考等级工具；其余全部在 dsh 侧：凭据解析、retry policy、settings 分层、attribution 头、空闲看门狗、请求冻结、replay 状态投影、错误分类。SDK 自动重试被强制为 0，pi-ai 的凭据库/OAuth/价格元数据未被使用（详见 §9）。
4. **配置只存凭据引用，key 永不进配置文件。** 配置携带 `apiKeyEnv`（环境变量名）这类引用，经凭据 seam 每次请求解析；托管文档是 `$DSH_HOME/.credentials.yaml`（0600 + 文件锁），继承环境 > 托管文档 > 项目/用户 .env 分层（`packages/credentials/credentials-local/src/index.ts:1-37`）。引用有值但不可用报 `INVALID_CREDENTIAL`，引用未命中报 `MISSING_CREDENTIAL`，只有完全不声明凭据的 profile 才允许 pi-ai 的 ambient 发现。
5. **配置热生效，route 事实注册时捕获。** 两个适配器都把 `cordis.yml` 入口配置作为 base、`$DSH_HOME/settings.yaml` 用户节为覆盖层，通过 thunk 每次请求重读连接事实，settings 文件热重载即可改 baseURL、模型目录和 key，无需重启；只有注册时捕获的 retry policy 和 route 集变化时需要同步原子重注册。
6. **模型目录是配置，不是远端刷新。** 直连适配器的模型是配置列表（默认 V4 Flash/Pro、上下文 100 万）；pi-ai 适配器以安装目录为默认，`models` 整表替换、`modelOverrides` 逐模型微调。目录是 advisory——未列出的模型 id 仍可请求；pi-ai route 的模型必须存在于配置解析出的集合，否则 `UNKNOWN_MODEL`。没有任何自动拉取模型目录的路径（README 明确"catalog never refreshes itself"）。
7. **重试在 agent 步边界，不在 SDK。** `dsh-llm-retry` 监听 `agent/request-error` 瀑布执行 provider-owned 策略：normal 模式默认对五个可重试错误码（见 §7）重试最多 2 次（500ms → 10s 指数退避 + 10% 抖动），always 模式无上限且先问下游；一次 adapter 调用 = 一次 provider 尝试。无多 Key、无 Key 轮换、无跨渠道 failover。
8. **默认模型在基座 bundle。** `packages/bundle/base/cordis.patch.yml:63-67` 挂载 `agent-default-model`（`deepseek-official`/`deepseek-v4-flash`），web 与 headless 模式都在此基础上叠加；用户默认模型存于 `agent-default-model` settings 节。

## 总体调用链

一条会话请求从 agent-loop 到上游 HTTP 的完整路径：

```text
dsh-agent-loop (packages/core/agent-loop/src/agent.ts step/buildRequest)
  ├─ 从 session.requestHeader() 恢复 call config（仅同 route 且非 adapter 默认的 effort）
  ├─ agent/request 瀑布（model-selection 注入当前 Provider/Model 选择，可整体替换 config）
  ├─ llm.prepareCall(config)：resolveModelInfo → 校验 effort、materialize 默认 maxTokens/effort → 绑定注册快照
  ├─ session 记录 request/header（含 adapterDefaults 标记）与 request/context
  ├─ markAgentLoopRequest(deepFreeze(GenerateOptions))
  └─ preparedCall.stream(request)
       └─ llm/stream 瀑布（缓存/日志/路由拦截点）
            └─ LlmRuntime.adapterStream（失败归一化为 finish error/aborted chunk）
                 └─ adapter.stream(options)
                      ├─ llm-deepseek: 解析连接事实+apiKey → fetch POST {baseURL}/chat/completions
                      │                → eventsource-parser SSE → translate 为 StreamChunks
                      └─ llm-pi-ai: 捕获不可变 snapshot(profiles+Models) → 解析 apiKey
                                     → toPiContext 转 pi-ai Context → streamSimple
                                     → toStreamChunks 映射 AssistantMessageEvent → StreamChunks
       └─ BlockAssembler 组装 → assistant/message 落日志（原始 chunk 同时以 assistant/chunk 落库）
            └─ finish error 时 → agent/request-error 瀑布 → llm-retry 决策重试（开新 turn）
```

每次请求的最终输出是：原始 `StreamChunk` 流以 `assistant/chunk` 事件持久化（供重建），组装后的块以 `assistant/message` 携带 usage 与来源（provider/model/replayState）入会话；失败回合不产生正常的 assistant 消息。

## 1. Provider、渠道与 Endpoint 数据模型

**seam 三角色**：按仓库约定，一个 capability seam 由三个角色组成，缺一不可（根 `AGENTS.md`、`docs/glossary.md`）：

- **Service Definition/Consumer**：`LlmRuntime` 同时承担两者——抽象服务定义与消费者使用的调用 API。它维护三类注册：adapter route 注册表（决定谁服务哪个 provider）、configurable-provider 目录（声明"可被配置激活"的休眠 route）、model discovery 注册表（按 settings namespace 提供端点探测）。
- **Service Provider**：`LlmAdapter` 抽象基类（`index.ts:180-233`），`stream()` 是唯一必实现方法；providerInfo、providerRetryPolicy、listModels、resolveModel 为可选能力，分别提供展示元数据、重试策略、advisory 目录和精确模型元数据。
- **Consumer**：agent-loop（逐回合调用）、`dsh-llm-retry`（消费失败事实）、`token-meter`（消费 usage 事件）、模型选择器与 Models 页（消费目录与凭据描述）。

**route 语义**：`registerAdapter(providers, adapter)` 一次性注册一组 route，任一冲突（`DUPLICATE_ADAPTER`）则整体拒绝；返回的 handle 携带 replace() 做同步原子换路由集（`index.ts:338-413`），请求不会观察到注册空隙。route 的展示名来自 adapter 声明的元数据，pi-ai 用 profile 的 `displayName`（route 键只是注册键）。**Endpoint 不是实体**：baseURL 是 route 配置字段（直连适配器一个实例一个 baseURL；pi-ai 每个 profile 一个 baseURL，目录模型可自带各自端点）。每 route 注册时解析并捕获不可变 retry policy（`index.ts:387-393`）。

**休眠目录**：`registerConfigurableProviders` 声明 adapter 可激活但未注册的 route，每条带 settings namespace 与到 profile 的路径（`settingsPath`），供配置界面展示"可添加的 Provider"；pi-ai 把全部安装目录 route（仅限声明 api-key 认证者）与当前 profile 声明的 route 取并集（`llm-pi-ai/src/index.ts:120-147`），并用 `declared` 区分"目录自带"与"配置声明"。拓扑每次提交点发 `llm/adapters-updated` 事件，观察者重读列表而不是轮询。

**与 Pi 对比**：pi 的 Provider 是 `packages/ai` 中固定 `id` 的代码对象、以覆盖层合并；dsh 的 route 是注册表键，渠道实例化差异由两个适配器各自承担——直连适配器是单 route 单例，pi-ai 适配器用"一个实例 + 多 profile"表达多 route。两者都没有用户可建的渠道实体。

## 2. 配置创建、持久化与迁移

**分层来源**：应用配置由 Cordis 组合决定：`apps/cli/src/profile-boot.ts:142-171` 把 bundle 补丁层、profile 的 `cordis.patch.yml`、`$DSH_HOME/cordis.patch.yml` 与 `--patch` 覆盖层按顺序叠加（行级最后写入生效），用户层文件可热重载。渠道相关的默认配置全部在基座 bundle（`packages/bundle/base/cordis.patch.yml`）：llm 服务、llm-retry、默认模型、settings 与凭据的本地文件 provider、休眠挂载的 pi-ai 适配器、无 key/baseURL 内联的直连 DeepSeek 适配器。

**用户层**：`dsh-settings` 服务（`packages/settings/settings/src/index.ts:1-120`）按 namespace 注册 schema；解析值 = schema 默认 → 注册者组合 base → 用户文档节。`settings-file` 把文档存为 `$DSH_HOME/settings.yaml`（可配 path，0600 原子写 + watcher 热发布）。两个适配器都用 installSettingsSection 注册同名 namespace，并在组合入口配置之上叠加用户节；pi-ai 的 `providers` 是 dict，用户节与 base 按 provider 逐项合并，即"settings 能加 route、改单字段、换代理，但删不掉 base 里的 route"（README 已记录该限制）。

**每操作重读**：适配器通过 thunk 读取解析后的连接事实，每次流调用重解析（直连 `index.ts:200-222`、pi-ai `index.ts:150-173`），settings 修改在下一个请求生效，一次在途流保持其开始时的快照。settings 快照越过 schema 但违反附加约束时保留"最后一个好配置"并记录日志；pi-ai 的 `assertServiceable` 使不可服务的 profile 在 `settings.mutate` 写入处就被拒绝（`settings-rejected`），而不是先存储再静默失效。

**迁移**：无数据库、无导入导出。pi-ai 对 pre-release 形状做 fail-loud 迁移：`providers` 数组形状、每 profile 的 `provider` 字段、`maxRetries`/`maxRetryDelayMs` 字段都拒绝加载并给出迁移方向（`llm-pi-ai/src/config.ts:276-291`），避免"SDK 重试 + agent 重试"叠加。直连适配器无此类历史形状。

## 3. 凭据、Header 与代理边界

**引用模型**：`credentialRef`（`packages/credentials/credentials/src/index.ts:23-28`）把环境变量名 brand 成 `CredentialRef`；适配器配置只携带引用。抽象服务 `CredentialProvider` 提供解析、描述、存储、删除四操作，描述只返回 configured/source/writable 三态，绝不含值；空存储值全局视为未配置。

**本地 provider 分层**（`credentials-local/src/index.ts:265-331`）：继承进程环境（只读，最高）> `$DSH_HOME/.credentials.yaml`（托管、可写）> 项目 .env > 用户 .env（只读回退）。托管文档只存引用到明文值的映射，0600 写入、0700 目录、原子写 + 文件锁，POSIX 下拒绝 group/other 可读文件（`assertOwnerOnly`）；watcher 热发布外部编辑。被环境遮蔽的引用拒绝写入（写了也无效）。Windows 下无 mode 检查，注释明确跳过。

**适配器解析**：每流调用经凭据 seam resolve(ref) 取 key；没有凭据 seam 的组合退化为读受信环境层。解析后的 key 一律过 assertUsableApiKey（trim + 可打印 ASCII 检查），非法值报 `INVALID_CREDENTIAL` 且错误消息只命名引用、绝不回显 key（`llm/src/index.ts:137-152`）；引用未命中报 `MISSING_CREDENTIAL` 并枚举配置入口。pi-ai 侧只有 profile 完全不命名凭据时才把认证交给 pi-ai 自身（ambient 发现）；一旦命名引用，未命中就 fail loud，防止误用无关环境 key 计到别家账上（`llm-pi-ai/src/index.ts:175-198`）。

**pi-ai 边界**：key 通过 `streamSimple` 的 `apiKey` 选项传入，是 pi-ai 认证覆盖的最高优先级；`Models` 集合完全不持有凭据库，因此 pi-ai 需要"已存储 OAuth 凭据"的认证路径（如 openai-codex）在此不可用，相关 route 从可配置目录中隐去（`llm-pi-ai/src/catalog.ts:144-162`）。

**Header 与代理**：所有请求携带 attributionHeaders() 生成的 User-Agent（app 身份，公开字段，白标部署可替换不可抑制）。直连适配器额外发送三个身份与用途头（x-deepseek-harness-user-id、按需 x-deepseek-harness-session-id、compaction 请求的 x-deepseek-harness-compact，`llm-deepseek/src/adapter.ts:283-295`）；pi-ai 把 profile 的请求头并进 SDK 请求，冲突时 Harness attribution 名优先（`llm-pi-ai/src/adapter.ts:172-179`）。**HTTP 代理配置本次未找到**：直连适配器用裸 fetch（README 记录 TODO(http)，未接入 cordis-plugin-http），pi-ai 侧由各 SDK 的 transport 决定，两处都未见 proxy 配置键。

**脱敏**：settings 的 `redactSecrets` 按 schema 的 `role('secret')` 摘除值并枚举位置（`settings/src/redact.ts`）；`apiKeyEnv` 是引用不是秘密，因此两个 LLM 适配器的 settings 节没有 secret 字段。pi-ai 的 `headers` dict 是纯字符串，可在其中放明文 `Authorization` 且 redactor 不可见——README 已把该点列为已知限制（"headers 可携带 redactor 看不到的凭据"）。

## 4. 模型目录与能力元数据

**两类元数据**：advisory 目录（`LlmModelInfo`，供选择器展示；未列入的模型 id 请求不会被拒绝）与精确元数据（`LlmResolvedModelInfo`：上下文、默认输出上限、思考能力三件套），后者由 route 属主 adapter 的 `resolveModel` 解析并经 `LlmRuntime` 校验脱附（`index.ts:627-718`）。

**直连适配器**：`models` 配置列表即全部目录，缺省为 V4 Flash/Pro（各 100 万上下文）。`resolveModel` 对每个 id 按"条目值优先、profile 回退值兜底"的顺序解析上下文容量（默认 100 万）与输出上限（默认 256,000）；输出上限只作为请求未声明时的默认，显式值永远获胜，且不按上下文窗口钳制。思考等级为 off/high/max 三档，部署锁 `thinking: disabled` 时只提供 off。未列出的 pass-through id 返回同样能力回退。

**pi-ai 适配器**：以安装目录为每 route 的默认模型表；profile `models` 列表整体替换目录（每个 entry 未设置字段从同名安装模型继承），`modelOverrides` 只重塑单个目录模型（键是目录模型 id，其余模型继续服务）；两者都不可用时回退到 route 级默认上下文（262,144）、默认输出能力（32,768）与默认模态（text）。只有配置显式声明的输出上限会成为请求默认，目录继承的上限只是模型能力。未配置的模型 id 在请求前就报 `UNKNOWN_MODEL`（`llm-pi-ai/src/adapter.ts:218-225`）——与直连适配器的 pass-through 语义不同。

**思考等级**：pi-ai 的七个等级（off、minimal、low、medium、high、xhigh、max）经 profile 的 reasoningEfforts 显式声明（键 = 可选等级、值 = 线上拼写），翻译成 pi-ai 的 Model.reasoning 与 thinkingLevelMap，未声明等级钉为不支持，避免依赖 pi-ai 的不对称默认（五个基础等级缺省即支持、xhigh/max 缺省即不支持）；off 是唯一三态键（缺省 = 不提供、空值 = 支持且不发送、带值 = 按值发送）。兼容开关 compat.thinkingFormat 与 supportsReasoningEffort 只对 openai-completions 模型存在，解析顺序为模型 → route → 目录条目 → pi-ai 按 URL 猜测（`llm-pi-ai/src/catalog.ts:388-419`）。

**无远端刷新**：目录就是配置文档的内容；README 明确"route 的目录永远不会自我刷新"。`discoverModels` 是配置时端点探测而非目录刷新：目录 route 由安装目录直接作答（不发网络），未收录 route 才 `GET {baseURL}/models`（仅 openai-completions/openai-responses 两种协议可读，Azure/Codex 等明确排除），4MB 字节上限，探测 key 一次性使用不存储，结果只是给界面采纳的候选（`llm-pi-ai/src/discovery.ts`）。

## 5. Adapter、协议与请求组装

**流式词汇**：`StreamChunk` 是 closed 判别联合（`packages/llm/llm/src/types.ts:291`），变体如下：

```text
block-start / text-delta / reasoning-delta / tool-call-delta / block-end
usage / finish { stop | tool-calls | max-tokens | aborted | error }
```

`index` 关联交错块，`block-end` 携带完整块；工具参数端到端保持原始 JSON 字符串；usage 必须先于 finish，finish 之后不再有 chunk。ContentBlockMap（`types.ts:99`）定义 text、reasoning、image、tool-call、tool-result 五类块，可声明合并扩展。BlockAssembler（`assembler.ts`）是唯一的流 → 块折叠实现，agent-loop 把原始 chunk 落库的同时喂给 assembler。

**适配器契约**（`docs/subsystems/llm-streaming.md`）：两种错误路径——`stream()` 抛出（传输/协议）或流内 `finish {kind:'error'|'aborted'}`（provider 带内错误）；一次适配器调用 = 一次 provider 尝试；空闲看门狗默认 5 分钟只计时在途读；context 溢出统一到 `CONTEXT_WINDOW_EXCEEDED` 码；空完成（stop 但无内容块）是 `EMPTY_RESPONSE` 错误而非成功；每个请求带 attribution 头。

**直连适配器组装**：`POST {baseURL}/chat/completions`，SSE 由 eventsource-parser 定帧、`[DONE]` 哨兵终结（`llm-deepseek/src/sse.ts`），`stream_options.include_usage` 恒开。

思考模式序列化顶层 thinking 对象加 reasoning_effort，off 不跨线上传而映射为 `thinking.type: disabled`；带工具调用的回合把历史 reasoning_content 回传、无工具回合丢弃（省 token）。usage 映射把 prompt_tokens 中的缓存命中数减回，得到不相交计数（`translate.ts:53-62`）；非 2xx 状态码分类见 `httpErrorCode`（`adapter.ts:138-149`）：

```text
401/403 → AUTH           400 中上下文溢出 → CONTEXT_WINDOW_EXCEEDED
配额明细 → QUOTA          其余 400 → INVALID_REQUEST
其他 429 → RATE_LIMIT     5xx → SERVER
传输前失败 → TRANSPORT     其他 → HTTP_<status>
```

`Retry-After` 与 `x-request-id`/`x-deepseek-request-id` 作为失败事实透传；传输失败链上 `cause` 供 `errorChain` 渲染。

**pi-ai 适配器组装**：`toPiContext`（`llm-pi-ai/src/context.ts`）把 Harness 历史转成 pi-ai Context——`systemPrompt` 单槽，历史 system 折叠成 user 消息，工具结果拆成独立 `toolResult` 消息，`ToolSchema.parameters` 直赋 pi-ai 的 TSchema；图片内容经附件服务读出 base64（无附件服务则拒绝）。

streamSimple(model, context, options) 把 profile 的流选项（思考预算、缓存保留、传输方式、各类超时、请求头）透传，maxRetries 强制 0，reasoning 为 off 时省略选项（`llm-pi-ai/src/adapter.ts:82-99`）。toStreamChunks（`stream.ts:124-208`）把 pi-ai 的 AssistantMessageEvent 按内容索引 1:1 映射为 Harness chunk，事件对照如下：

| pi-ai 事件 | Harness chunk |
|---|---|
| text_start / thinking_start / toolcall_start | `block-start` |
| 对应各块 delta | `text-delta` / `reasoning-delta` / `tool-call-delta` |
| 各块 end 事件 | `block-end`（工具参数解析后重新 stringify） |
| done / error | `usage` + `finish` |

**pi-ai 错误分类**：pi-ai 把带内错误压平成 `error.message` 文本（源码注释记录的上游限制），dsh 只能按文本模式分类（`stream.ts:39-62`），对照如下：

| 错误文本特征 | 错误码 |
|---|---|
| 含 401/403 | `AUTH` |
| 配额/余额/额度明细 | `QUOTA` |
| 429 / rate limit | `RATE_LIMIT` |
| 400 / invalid request | `INVALID_REQUEST` |
| 5xx | `SERVER` |
| timeout / 流提前结束 / 连接类 | `TRANSPORT` |
| 其他 | `PI_AI_ERROR` |

`isContextOverflow` 与错误文本中的溢出识别统一归一为 `CONTEXT_WINDOW_EXCEEDED`（`stream.ts:73-113`）。pi-ai 的结束原因五值（stop、length、toolUse、aborted、error）直接映射为 finish 的对应 reason；stop 且无内容块 → `EMPTY_RESPONSE`。

**replay 状态**：成功的 assistant 响应在 `finish` chunk 携带版本化投影 `PiAiReplayState`（kind pi-ai、version 1，记录 api/provider/model、结束原因与各块签名；`llm-pi-ai/src/replay.ts:63-91`）。`LlmRuntime` 只在历史 provider 与目标 provider 当前属于同一 adapter 实例时把它传给目标（`index.ts:823-836`）；pi-ai 适配器验证后重建原生 pi-ai assistant 消息（恢复 responseId 与 provider 签名），无 replay 状态的历史按 provider-neutral 内容转成 api 为 dsh-foreign 的消息，绝不冒充原生响应。版本、provider/model 或块数不匹配报 `INVALID_REPLAY_STATE`。直连适配器无 replay 状态——它在历史序列化时自己回传 reasoning_content。

## 6. 运行时选择、绑定与路由

**模型来源**：新 Agent 的默认选择来自 `agent-default-model` 服务（`packages/core/agent-default-model/src/index.ts`）：组合入口配置（base bundle 中为 `deepseek-official`/`deepseek-v4-flash`）+ 同名 settings 节（provider、model、可选 reasoningEffort），Models 页通过 `saveSelection` 写入；消费端在 Agent 创建时读取 `currentSelection()`。

**选择注入**：`installModelSelection`（`packages/core/agent/src/model-selection.ts:39-75`）把可变选择耦合到两条瀑布：`system-prompt/assemble` 时快照选择并注入 `{{provider}}`/`{{model}}` 变量，`agent/request` 时覆盖请求 config 的 provider/model/effort——并发切换在下一个 step 生效，不劈开正在组装的两面。

**请求构建**：`buildRequest`（`packages/core/agent-loop/src/agent.ts:407-495`）先恢复持久化 request/header 中的 config（仅当 route 相同且该 effort 非 adapter 默认时才恢复），再走 `agent/request` 瀑布（可整体换 provider/model/effort/sampling），然后 `llm.prepareCall(config)`：一次精确模型解析，不支持的 effort 在 provider I/O 前拒绝，adapter 默认的输出上限与 effort 被 materialize 并标记（`adapterDefaults`）。

返回的 `PreparedLlmCall` 把 config、retry policy、context 与注册快照绑定为一次性句柄（复用或改字段报 `INVALID_PREPARED_CALL`；`llm/src/index.ts:779-814`）。随后 request/header 与 request/context 落日志，请求被 `markAgentLoopRequest` 加 `deepFreeze`（监听者只读）。

**瀑布与归一化**：`llm/stream` 瀑布可短路或包装任意请求（`index.ts:913-927`）；最终 `adapterStream` 把选择、迭代器构造与迭代的失败统一归一化为流内终态 `finish {kind:'error'|'aborted'}`（`index.ts:843-900`），中间件与消费者自己的失败保持抛出。

**路由依据**：显式 provider + model，无别名、无语义路由、无负载均衡。`agent/request` 的其他消费者本次只确认了 model-selection；session-title、compaction 等辅助调用同走 seam 但携带 `purpose` 标记。

## 7. 多 Key、限流、重试与故障转移

**多 Key 与限流**：无多 Key 池、无 Key 轮询、无冷却/熔断/健康状态持久化。每枚凭据按 `CredentialRef` 一粒存储，route 请求永远使用其解析出的那一个值。限流没有本地队列或 QPS 控制，`RATE_LIMIT` 只作为可重试错误码交给重试策略。与 Pi 相同，这些能力不存在而非未覆盖：本次搜索了 credentials、llm 与 agent-loop 的请求路径，未见 Key 数组或健康状态结构。

**策略模型**：`RetryPolicyConfig`（`packages/llm/llm/src/retry-policy.ts:56-79`）是 dsh-llm 自有的策略类型；注册 route 时解析为不可变 `ResolvedRetryPolicy` 并随注册捕获，供失败处理引用。两种模式与 normal 默认参数如下：

| 项 | 值 |
|---|---|
| 模式 | `normal`（有限重试次数、可重试码集、退避参数）或 `always`（无次数上限） |
| normal 默认重试次数 | 最多 2 次 |
| normal 默认退避 | 500ms 起、上限 10s、10% 对称抖动 |
| normal 默认可重试码 | `EMPTY_RESPONSE`、`RATE_LIMIT`、`SERVER`、`TIMEOUT`、`TRANSPORT` |

**执行位置**：`dsh-llm-retry`（`packages/llm/llm-retry/src/index.ts:99-226`）监听 agent-loop 的 `agent/request-error` 瀑布，携带失败 `LlmFailure`、该次调用的不可变策略与回合信号。normal 模式先查可重试码集，再按 (provider、策略键、回合、步) 从会话日志续接重试计数；provider 请求的 `providerRetryAfterMs` 不超过 `maxDelayMs` 时直接采用，超限时 normal 模式放弃、always 模式用本地退避。

等待开始前先落 `llm/retry` 事件（调度事实），等待完成再落 `llm/retry-started`，随后返回重试决定让 loop 关掉失败回合、开新回合重放同一请求。取消与插件销毁中止在途退避并排空活跃恢复。**重试边界是 agent 回合**：直连 `ctx.llm.stream()` 的调用者保持单次尝试，因为裸流无法在 durable 层切分已发出的 chunk。

**重复计费边界**：每次重试都是新的 provider 请求，可能重复输入计费（README 注明 normal 有限、always 无上限）。失败回合不提交 assistant 消息与工具副作用；`EMPTY_RESPONSE` 因"没有产生任何持久内容"而被默认视为安全重试。

**故障转移**：无模型 fallback、无跨 Provider failover。切换 provider/model 属于配置或会话级动作，不在失败路径内发生。与 Pi 一致，OpenRouter 类上游路由能力在这里不存在（本仓库没有 OpenRouter 适配器或路由参数透传）。

## 8. 连接检测、日志与可观测性

**连接检测**：没有独立"连接测试"真实请求路径。Models 页的 Provider 就绪状态来自 `credentials.describe`（configured/source/writable 布尔）与 settings 节存在性的静态组合（`packages/client/ui-settings-models/src/client/store.ts:161-184`）；真实网络探测只有配置时的 `discoverModels`（GET /models，见 §4），且其结果不进入运行时路由。认证失败只出现在真实请求的错误码上（`AUTH`/`INVALID_CREDENTIAL`/`MISSING_CREDENTIAL`）。

**会话日志（请求重建）**：`request/header` 记录完整调用配置（含 `adapterDefaults` 标记、渲染后的 system、工具顺序），`request/context` 记录 provider/model/contextWindow，`assistant/chunk` 按序落原始 chunk，`assistant/message` 落组装块 + usage + `sourceEventSeqs`。请求可完全从日志重建（见 docs/subsystems/session.md 的 request-header 语义与 2026-07-05-reconstructable-requests.md 笔记）；dev invariant 对每个 loop 请求重算该等式。

**token 计量**：`dsh-token-meter`（`packages/llm/token-meter/src/index.ts:74-156`）提供 `measure(session, requestHeader?)` 与 estimateMessage。固定启发式（4 字符/token + 角色/块/信封结构开销）；当最新成功调用的规范请求信封与测量信封一致时，优先复用 provider 报告的 usage 作为锚点，否则全量启发式估计。三个投影单元（真实 usage 汇总、上下文压力并可选项含外推的 `projectedTokens`、启发式组成）是独立 last-wins 记录，不是同一边界的一次原子观测；README 明确占用百分比只是参考值，compaction 走 `measure()` 而不是投影。**价格不参与**：pi-ai 侧 replay 把成本清零（"harness 从不读 pi-ai 的 cost 元数据"），直连适配器无价格表。

**错误与拓扑可观测**：`LlmError` 携带稳定 `code` + 可序列化 `failure`（status/providerRetryAfterMs/requestId），`errorChain` 渲染完整 cause 链供 UI/日志；pi-ai 路径拿不到 HTTP status（README 记录的限制）。拓扑变更经 `llm/adapters-updated` 事件与 listProviders/listModels/listConfigurableProviders/resolveModelInfo 等查询可见。遥测行 `session-telemetry-otel` 存在于基座组合，但本次未追到 LLM 请求路径的具体埋点。

## 9. pi-ai 复用边界

pi-ai 版本 `^0.82.1`（`packages/llm/llm-pi-ai/package.json:45`，lock 解析为 0.82.1，自带 openai/anthropic/bedrock/vertex/mistral/google 等 SDK，lazy 加载）。复用边界按"谁拥有行为"划分：

| 能力 | 归属 | 说明 |
|---|---|---|
| `Models` 集合与查询（`createModels`/`setProvider`/`getModel`/`getModels`/`streamSimple`） | pi-ai | dsh 只放入 Provider、取模型、调流 |
| 安装目录（`builtinProviders`/`getBuiltinModels`/`getBuiltinProviders`） | pi-ai | dsh 以 route 键查目录，作为 profile 默认 |
| `Provider`/`Model`/`Api` 类型与 `createProvider` | pi-ai | 目录 route 复用原 Provider（保留 Bedrock 等独立入口装载的 API 实现），其余用白名单工厂重建（`llm-pi-ai/src/provider.ts:144-192`） |
| 事件词汇 `AssistantMessageEvent`/`AssistantMessage`/`Usage`、`isContextOverflow` | pi-ai | dsh 只做 1:1 映射与错误码归一 |
| 思考等级 `ThinkingLevel`/`ModelThinkingLevel`/`ThinkingLevelMap`/`getSupportedThinkingLevels` | pi-ai | 等级是 pi-ai 的词汇；声明与线上拼写由 dsh 配置翻译 |
| 流选项 `SimpleStreamOptions`（`thinkingBudgets`/`cacheRetention`/`transport`/`timeoutMs`/`websocketConnectTimeoutMs`/`apiKey`/`headers`） | pi-ai | 类型来自 pi-ai；取值与透传策略在 dsh profile |
| `RetryPolicyConfig`/`ResolvedRetryPolicy` | **dsh 自有** | 与 pi-ai 无关（`packages/llm/llm/src/retry-policy.ts`），是 dsh-llm 的类型；执行在 dsh-llm-retry |
| 凭据解析、`CredentialRef`、key 校验与注入 | **dsh** | key 只以 `apiKey` 流选项进入 pi-ai，`Models` 无凭据库 |
| 认证与 OAuth 流程 | 未复用 | pi-ai 从已存储 OAuth 凭据解析，dsh 无存储与登录流，OAuth-only route 不可用（目录隐去） |
| 价格/成本元数据 | 未复用 | replay 构造时清零，无消费者 |
| SDK 自动重试 | 未复用 | `maxRetries` 强制 0，重试全部在 agent 回合边界 |
| 协议全集 | 部分复用 | 白名单只开 openai-completions/openai-responses/anthropic-messages（`provider.ts:47-51`）；Bedrock/Vertex/Azure/Codex 等目录 route 仍经其原生 Provider 可达，但不可显式声明 |
| 思考格式探测 | 部分复用 | `compat.thinkingFormat`/`supportsReasoningEffort` 两个开关暴露给配置，其余 compat 面保持 pi-ai 的 URL 自动探测 |
| 事件/错误语义 | 部分复用 | pi-ai 错误被压平成文本（上游限制），dsh 做文本分类而非读 code/cause |

**与 Pi 仓库的关系**：`@earendil-works/pi-ai` 即 pi 的模型 API 包（`packages/ai`，参照本目录《Pi LLM 渠道管理调查笔记》）；dsh 用到的 Provider、Model、getSupportedThinkingLevels 等与 pi 笔记中 `packages/ai/src/models.ts` 的接口同源。差异在于 pi 自己在运行时组合"内置 + models.json + 远端目录 + 扩展"四层目录并持有凭据存储，而 dsh 只取 pi-ai 的"单 Provider 单目录 + 流"内核，目录分层与凭据治理全部换成 dsh 自己的 settings/credentials seam。因此 pi-ai 升级对 dsh 的可见影响主要是：目录内容、思考等级集合、协议实现与事件词汇；dsh 侧有三个 drift gate（模态、思考等级、思考格式，`catalog.ts:42-112`）让升级新增的项在编译期失败并点名漂移键。

## 10. 设计取舍与已确认边界

- **twin adapters 钉住中性词汇**：两个实现（直连 fetch vs 库事件流）自始共享 `StreamChunk` 契约，任何词汇无法同时表达两个实现的行为都被视为核心词汇缺陷（Agent Note `2026-06-13-twin-llm-adapters.md`）；代价是双份适配器与双份 key 门控 e2e。
- **route 键即注册项**：没有用户渠道实体与实例管理，多账号/多网关靠多 route 键或多 profile 表达；pi-ai 一个实例可挂任意多 route，直连适配器单 route。
- **凭据引用而非存储**：配置永不落 key，换来"改 key 即热生效、配置可共享"；代价是每次请求一次 seam 解析，且 key 值只存在于进程内存与托管文档。
- **dormant 挂载 + settings 驱动注册**：组合决定"哪些适配器存在"，settings 文档决定"哪些 provider 运行"（基座 bundle 对 pi-ai 采用零 profile 休眠挂载）；route 集与 retry policy 是注册级事实，变化时同步原子 replace。
- **一次调用一次尝试**：SDK 重试被禁用，重试闭环全部在 agent 回合边界（durable `llm/retry` 事件可重建），避免"流已发出部分 chunk 后不可重放"的边界。
- **目录即配置**：模型目录来自 pi-ai 安装目录 + settings，无远端刷新；新模型上线必须写配置，换取确定性（与 Pi 的"构建期 + 远端叠加"策略相反）。
- **无跨渠道高可用**：无多 Key、无健康调度、无模型 fallback、无跨 Provider failover；`RATE_LIMIT`/`SERVER` 只在同一 route 内重试。
- **平台边界**：llm seam、凭据与 settings 全部在服务端进程；浏览器经 remote API（settings/credentials/llm 域）读写，Models 页负责把 key 写入托管文档、把 profile 写入 settings 节。`web-search-deepseek` 是独立搜索 provider（Anthropic-compatible `/messages` 端点、同一 `DEEPSEEK_API_KEY` 凭据、单独 baseURL 覆盖），不属于 LLM 渠道 seam，但复用同一凭据存储。
- **文档与实现一致性**：README、`docs/subsystems/llm-streaming.md` 与代码一致（抽查了错误码、默认值、route 名、限制清单）；`stream.ts:31-38` 的 `XXX(pi-ai upstream)` 注释如实记录上游把错误压平成文本的限制。

## 11. 未验证事项

- 未运行真实 Provider 请求与测试，pi-ai 错误文本分类（`classifyPiAiError`）与真实错误正文的匹配度未实测。
- `node_modules` 未安装，pi-ai 0.82.1 库内实现未直接核对；其内部行为依据 package.json、pnpm-lock、README 注释与 Pi 仓库笔记推断。
- settings-file/credentials-local 的 watcher 竞态与热重载行为仅静态阅读。
- web Models 页的完整交互（onboarding、store 刷新、CustomProvider 表单）只追到 API 调用点，未逐组件核对。
- 遥测（`session-telemetry-otel`）是否覆盖 LLM 请求路径未追完。
- `agent/request` 瀑布的消费者清单未穷举（除 model-selection 与 agent-loop 自身外）。
- 会话恢复（resume）时 `requestHeader` 恢复的具体行为仅在 `buildRequest` 静态阅读，未跑重放。

## 12. 关键源码索引

- `packages/llm/llm/src/index.ts:284`：`LlmRuntime`；`index.ts:338-413`：route 注册与原子 replace；`index.ts:779-814`：`prepareCall`；`index.ts:843-927`：adapterStream 与 `llm/stream` 瀑布
- `packages/llm/llm/src/types.ts:99`：`ContentBlockMap`；`types.ts:291`：`StreamChunk`；`types.ts:320`：`GenerateOptions`
- `packages/llm/llm/src/retry-policy.ts:56-79`：`RetryPolicyConfig` 与默认值；`error.ts`：`LlmError` 与共享错误码
- `packages/llm/llm/src/assembler.ts`：`BlockAssembler`
- `packages/llm/llm-deepseek/src/index.ts:161-198`：`resolveAdapterOptions`；`index.ts:200-276`：apply 与凭据解析
- `packages/llm/llm-deepseek/src/adapter.ts:138-149`：`httpErrorCode`；`adapter.ts:214-269`：stream 与看门狗；`serialize.ts:151-187`：请求体；`translate.ts`：chunk 翻译
- `packages/llm/llm-pi-ai/src/index.ts:150-312`：apply（目录、注册、settings 接线）
- `packages/llm/llm-pi-ai/src/config.ts:301-372`：`resolveProfiles`；`catalog.ts:446-546`：`resolveRouteModels`；`provider.ts:47-51,167-192`：协议白名单与 `buildProvider`
- `packages/llm/llm-pi-ai/src/adapter.ts:199-357`：snapshot 与 stream；`stream.ts:39-62,124-208`：错误分类与 chunk 映射；`replay.ts`：replay 投影与验证
- `packages/llm/llm-retry/src/index.ts:99-226`：`agent/request-error` 上的重试执行
- `packages/llm/token-meter/src/index.ts:74-156`：`measure`/`estimateMessage`；`usage-projection.ts`：投影单元
- `packages/credentials/credentials/src/index.ts:23-28,60-100`：`CredentialRef` 与抽象服务；`credentials-local/src/index.ts:265-403`：分层解析与 0600 文件写入
- `packages/settings/settings/src/index.ts`：namespace 合并与 `redactSecrets`
- `packages/core/agent-loop/src/agent.ts:332-401,407-495`：step 与 `buildRequest`
- `packages/core/agent/src/model-selection.ts:39-75`：`installModelSelection`
- `packages/core/agent-default-model/src/index.ts`：默认模型服务
- `packages/bundle/base/cordis.patch.yml:63-67,72-96,450-451`：默认模型、llm-retry、settings/credentials、dormant pi-ai、llm-deepseek
- `packages/web/web-search-deepseek/src/provider.ts:27-38`：搜索 provider 的独立端点与模型默认


