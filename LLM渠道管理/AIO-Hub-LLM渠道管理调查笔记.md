# AIO Hub LLM 渠道管理调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改目标仓库
>
> 调查范围：LLM 渠道数据模型、配置生命周期与管理入口、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 把一条 LLM 渠道建模为一个 `LlmProfile`。Profile 同时持有协议类型、Base URL、多个 API Key、模型目录、自定义 Header、自定义端点、网络策略和 Provider 专属参数；业务侧用稳定的 `profileId + modelId` 明确选择请求目标。

这套方案把渠道配置集中起来，运行时显式路由，并在协议适配与网络传输上分层：

- 桌面端提供 21 种可见渠道类型，其中 4 种聚合渠道把渠道身份与线协议解耦；聚合渠道的默认协议只作为折叠的高级回退项，New API、Sub2API 与通用聚合渠道具有显式图标，其余不少类型最终复用 OpenAI-Compatible Adapter；
- 每条渠道可配置多个 Key，按轮询选择，并记录启停、连续错误、429 熔断和自动恢复状态；
- 模型属于渠道，既可手工维护，也可调用模型列表端点获取，再由模型元数据规则补全能力；
- Chat、Responses、Anthropic、Gemini、Embedding、Rerank、媒体生成和语音转写可以使用不同端点；
- Provider 请求构造/响应解析位于共享 TypeScript Core，桌面网络默认经本地 Rust 代理；
- Agent 默认绑定一个渠道和模型，单次发送、重试、续写时可临时覆盖；历史消息保存实际使用的渠道/模型快照。

它没有“同模型的多渠道池”、渠道权重、优先级、成本路由或跨渠道自动故障转移。Key 选择分两层：渠道层单次调用只选一次 Key，失败后更新健康状态并抛错；主聊天链路在应用层自带重试循环（默认最多重试 2 次、固定间隔 3 秒，429 追加 5 秒惩罚等待），每次重试重新走 Key 选择，已被 429 熔断或认证失败标坏的 Key 会被跳过，因此同渠道还有其他可用 Key 时重试会换 Key（详见第 5.3 节）。

- **模型执行路由**：请求分发先按操作查找模型保存的协议与端点绑定；没有绑定时，再把远端声明的唯一端点类型映射为协议。普通渠道随后回退到 Provider 默认协议，聚合渠道则继续查渠道级默认协议、内置模型路由表和静态操作默认。几条路径都落空时抛出 `UnresolvedModelRouteError`，把错误交给调用方，模型名不参与端点猜测。探测得到的候选绑定需要用户逐模型或批量确认后才写回。这套路由只在同一渠道内选择协议与端点，跨渠道改选属于另一层（`packages/llm-core/src/model-execution-routing.ts:371-449`、`src/views/Settings/llm-service/probe/route-application.ts`）。
- **audio.cpp 是一等本地音频渠道**：渠道预设同时声明 OpenAI 兼容 TTS 与 Whisper 风格 ASR 端点。模型声明 `asr` 能力且请求带转写输入时，通用请求入口改走 `/v1/audio/transcriptions` 的 multipart 提交流程，音频按文件上传处理，不进入 Chat 消息正文。桌面转写工具会先把非 WAV 输入转成 WAV（`src/composables/useLlmRequest.ts:226-262`、`src/tools/transcription/engines/audio.engine.ts:56-305`）。
- **凭据与渠道配置分开落盘**：API Key 与敏感自定义 Header 移入独立的混淆文件，桌面端路径是 `llm-service/secrets.dat`；`profiles.json` 里的 `apiKeys` 保持空数组，加载时再按 profile.id 注入内存。Key 健康状态的索引同样改为不可逆哈希，旧明文索引与配置在加载时迁移（第 2.6 节）。
- **虚拟渠道**：渠道配置可以声明 `virtualChannel`，由共享核心把一次请求展开为多个候选目标并按顺序尝试。执行侧把哪些真实渠道参与、各次尝试如何失败封装进执行对象，重试判定由同一个函数给出，配置错误与执行错误分成两类异常（`src/types/llm-profiles.ts:518`、`packages/llm-core/src/virtual-channel.ts`，细节在第 4 节）。
- **模型元数据可订阅外部来源**：内置目录与用户规则之外，设置页还能配置外部目录源，由服务层完成来源适配、目录拉取和自动更新，拉取结果经同一转换管线写成本地规则。配置入口是 `ModelMetadataSourcesDialog.vue`，服务实现在 `src/services/modelMetadataSourceService.ts`（第 3 节）。
- **预设模板共 43 个**：预设层只是创建渠道时的模板，不改变 Provider 类型清单；OpenCode Go、Sub2API、audio.cpp、Ollama Cloud、LM Studio 等条目都在其中。

## 总体结构

```text
设置页 / 配置导入
  -> useLlmProfiles
       -> llm-service/profiles.json
       -> LlmProfile[]
            type + baseUrl + apiKeys[] + models[]
            customHeaders + customEndpoints + options
            networkStrategy + TLS/HTTP flags

Agent / 临时模型 / 辅助任务
  -> 确定 profileId + modelId
  -> useLlmRequest.sendRequest()
       -> 校验渠道启用状态与渠道内模型
       -> useLlmKeyManager.pickKey()          Key 轮询/健康过滤
       -> filterParametersByCapabilities()   参数裁剪
       -> resolveModelExecution()            按操作解析协议/端点
       -> adapters[effectiveProfile.type]    协议与能力分派
       -> @aiohub/llm-core Provider Adapter
       -> desktopLlmTransport
       -> fetchWithTimeout
            -> Rust loopback proxy（默认）
            -> WebView fetch（显式 native）
       -> reportSuccess()/reportFailure()     更新 Key 状态
```

## 1. 渠道数据模型

核心类型位于 `src/types/llm-profiles.ts`。

### 1.1 Profile 是渠道管理的聚合根

`LlmProfile` 的关键字段如下：

| 字段 | 作用 |
|---|---|
| `id` / `name` | 稳定引用和用户显示名 |
| `type` | 选择 Provider 协议 Adapter |
| `baseUrl` | 渠道基础地址，可指向官方服务、中转或本地服务 |
| `apiKeys[]` | 同一渠道内的多凭据池 |
| `enabled` | 是否允许普通业务请求使用 |
| `models[]` | 该渠道可选模型及其能力、参数、价格等元数据 |
| `customHeaders` | 用户自定义请求头，支持预设值和高级兼容配置 |
| `customEndpoints` | 按 API 能力覆盖相对路径或完整 URL |
| `options` | Azure、Vertex 等 Provider 特有字段；聚合渠道还可保存按操作配置的 `routingDefaults` |
| `toolHandling` | 渠道工具处理声明（`callConsumer`：`aio`/`upstream`；`upstreamProtocol`：`provider-native`/`vcp-text`/`transparent`/`none`；`aioDistributedExposure`），供聊天工具编排判断"本机消费还是 VCP 上游消费"（消费方见 Agent 工具笔记 §12） |
| `networkStrategy` | `auto`、`proxy` 或 `native` |
| `virtualChannel` | 可选虚拟渠道配置：把一次请求展开为多个候选目标并按顺序尝试（见第 4.3 节） |
| `relaxIdCerts` / `http1Only` | Rust 网络层兼容选项 |

模型没有独立于渠道的全局实体。同名模型可以存在于多条 Profile 中，唯一标识是 `profileId:modelId`。这避免了只凭模型名猜测端点；跨渠道切换时则必须同时改变 Profile。

### 1.2 支持的 Provider 类型

`src/config/llm-providers.ts` 当前向设置页声明 21 种渠道类型：

- OpenAI、OpenAI-Compatible、OpenAI Responses；
- DeepSeek、Anthropic Claude、Google Gemini、Cohere；
- SiliconFlow、Groq、OpenRouter、xAI；
- Ollama；
- audio.cpp；
- Azure OpenAI、Vertex AI；
- Suno (NewAPI)、MiniMax Music；
- New API、Sub2API、通用聚合渠道与 OpenCode Go。

适配器注册入口再把这些渠道身份映射到实际协议实现。OpenAI-Compatible Adapter 还被 Groq、OpenRouter、Ollama、SiliconFlow 与 audio.cpp 复用；DeepSeek、Gemini、Anthropic、Cohere、Vertex 和媒体协议有专用实现。四种聚合渠道不是第五套线协议：执行路由先把它们解析为 OpenAI Chat/Responses、Anthropic、Gemini 等适配器，再将 `effectiveProfile.type` 改成实际协议类型（`src/llm-apis/adapters/index.ts:104-139`、`packages/llm-core/src/model-execution-routing.ts:404-441`）。

类型层、设置层和适配器注册层不是同一个声明源，现由完整类型约束避免遗漏。Ollama 使用 OpenAI 兼容端点，模型列表仍走原生 `/api/tags`，并声明工具参数支持（`src/config/llm-providers.ts`）。预设实现按渠道拆成 `src/config/llm-presets/presets/` 下独立模块，由 `index.ts` 统一注册；这属于维护边界，不改变 Profile 的持久化结构。

### 1.3 网络与安全默认值

默认 Profile 模板 `DEFAULT_LLM_PROFILE` 启用渠道，并把 `networkStrategy` 设为 `auto`。`fetchWithTimeout()` 把 `native` 之外的请求都交给 Rust 代理，因此 `auto` 的实际效果就是默认代理路径，两种传输之间没有探测择优的步骤。

`relaxIdCerts` 和 `http1Only` 默认都是 `true`。前者放宽无效证书校验，后者强制 HTTP/1.1；它们提高私有/老旧网关兼容性，但不是官方 HTTPS API 的保守安全与性能默认值。

## 2. 配置生命周期、管理入口与持久化

### 2.1 管理入口按平台的实际覆盖

渠道管理在代码里分成桌面端与移动端两套状态和配置实现，各自管理自己的 Profile，没有统一承载渠道管理的后端服务。桌面端由 `useLlmProfiles` 把配置写进 `llm-service/profiles.json`，入口是 Tauri WebView 里的 `LlmServiceSettings.vue`；移动端由 Pinia Store 写入独立的 `llm-profiles/llm_profiles.json`，入口是移动应用的 `LlmSettingsView.vue`。两边共享部分类型和 Provider Core，运行时配置各存一份（`src/composables/useLlmProfiles.ts:43-51`、`mobile/src/tools/llm-api/stores/llmProfiles.ts:27-32`）。

| 入口 | 源码确认的能力 | 边界与证据状态 |
|---|---|---|
| 配置文件 | 文件内容是包含 `profiles` 数组的 JSON；启动时加载、规范化旧字段并保存。直接编辑文件可以改变渠道的全部持久化字段，包含启停、模型、端点、Header 和凭据。桌面端还会从旧 `localStorage` 迁移一次。 | **源码确认**配置读写和迁移；配置文件没有单独的“复制/测试/删除”命令，直接改 JSON 属于手工配置，不是应用提供的管理工作流。桌面端文件为 `llm-service/profiles.json`，移动端为 `llm_profiles.json`，不是同一文件。 |
| CLI | 根 `package.json` 的脚本是构建、检查、测试、文档和 Tauri 启动等开发命令；本次在根脚本、`scripts/` 和渠道相关源码中未找到读取/新增/编辑/复制/启停/删除/导入/导出/连接测试 Profile 的 CLI 命令。 | **本次未找到**渠道管理 CLI。`scripts/version.ts` 等 `process.argv` 使用属于构建/版本脚本，不是渠道管理入口。 |
| TUI | 未找到 Ink、Blessed 或其他终端 UI 渠道列表/编辑器，也未找到 Profile 专用 TUI 命令。 | **本次未找到** TUI 渠道管理入口。 |
| Web | 代码使用 Vue 页面，但其桌面管理页依赖 Tauri 文件对话框和 Tauri FS 插件导出；未找到独立 Web 服务、HTTP 配置 API 或浏览器部署版的渠道管理页。 | **静态推断**当前 `src/` 页面属于桌面 Tauri WebView，不应把它概括为可远程访问的 Web 管理端；未启动浏览器或 Tauri 验证实际可达性。 |
| 桌面端 | 完整支持查看、新建、编辑、启停、删除、排序、配置导入、渠道包导出、模型列表获取、模型/Key/能力探测，以及模型级和批量协议路由绑定。侧边栏显示名称、渠道类型和模型数，编辑器显示当前 Profile 的完整配置。 | **源码确认**入口和事件绑定见 `src/views/Settings/llm-service/LlmServiceSettings.vue`、`components/ModelRoutingEditor.vue` 与 `BatchRouteBindingDialog.vue`；保存成功、文件对话框和真实请求结果本次未运行验证。 |
| 移动端 | 独立设置页支持查看、新建、预设创建、编辑、显式保存、启停、删除、请求头/端点/模型编辑、模型列表获取和模型/批量探测。 | **源码确认** UI 和 Store 事件绑定见 `mobile/src/tools/llm-api/views/LlmSettingsView.vue:31-100,115-179`、`mobile/src/tools/llm-api/components/ProfileEditor.vue:106-149,346-665`；本次未找到移动端渠道包导入、导出或复制入口。 |

配置文件层和 UI 层的“删除”语义也不同：桌面端删除调用 Profile Store 的 `deleteProfile` 后保存整个列表；移动端删除同时把选中 ID 指向列表首项或清空。两端都没有发现删除关联 Agent、会话历史或 Key 健康状态的级联清理代码；历史消息保留实际渠道快照的行为由聊天链路负责，删除动作作用于渠道配置本身，对历史引用的影响需在聊天链路另行核对（`src/composables/useLlmProfiles.ts:212-232`、`mobile/src/tools/llm-api/stores/llmProfiles.ts:106-112`）。

### 2.2 已有渠道与新建渠道的操作差异

桌面端新建有三条路径。空白创建生成新的 ID、默认 OpenAI 地址、启用状态、空模型列表和默认请求头；预设创建复制预设的 Provider、地址、默认模型、图标、端点和默认请求头；配置导入可以一次生成多个候选渠道。空白和预设创建后都会立即调用 `saveCurrentProfile`，所以新渠道先以可编辑对象落盘，再由表单变化触发后续自动保存（`src/views/Settings/llm-service/composables/useProfileEditor.ts:137-168`）。

已有桌面渠道被选中时，编辑器先深拷贝 Profile 到 `editForm`，避免输入过程直接修改列表对象；表单深度变化后等待 1 秒调用 `saveCurrentProfile`，而 API Key 输入框在失焦时才把逗号/换行文本拆成数组。因而“已有渠道编辑”是编辑副本加防抖保存，“新建渠道”是先保存初始对象再进入同一编辑流程（`useProfileEditor.ts:127-135,184-203`）。删除和启停直接作用于已存在 Profile；启停只翻转 `enabled` 并保存，不创建新的运行时实例。

桌面端没有看到独立的“复制渠道”按钮。复制效果存在于两条间接路径：导入一个带 `sourceProfile` 的候选时，如果 ID 冲突会生成新 ID，并把名称改为“副本”加序号；从已存在渠道打开“配置导入”时，导入草稿覆盖当前编辑副本，保留当前 ID，属于编辑/合并而不是复制。原生渠道包导入也会在 ID 冲突时按创建逻辑生成副本；因此应将“导入冲突复制”与“用户点击复制”区分记录（`LlmServiceSettings.vue:318-367,373-463`）。

桌面端已有渠道可以单独或批量导出，默认不包含 API Key、自定义鉴权 Header 等敏感值；勾选“包含敏感信息”才写出完整凭据。导入创建态支持多个候选批量创建，编辑态只应用一个草稿：带完整 `sourceProfile` 时替换除当前 ID 外的 Profile 数据，否则按字段合并到当前编辑表单。创建态导入会为冲突 ID 重新生成 ID，编辑态不会改变当前 ID（`src/views/Settings/llm-service/components/LlmProfileExportDialog.vue:112-171`、`LlmServiceSettings.vue:373-463`、`src/utils/llm-profile-transfer.ts:286-351`）。

移动端的新建渠道要等用户点击编辑器里的“保存”才写入 Store：预设创建和空白创建都只是先在内存中构造一份编辑对象并打开弹窗，保存事件再按 ID 判断该新增还是更新。已有渠道打开时会深拷贝一份再编辑。与桌面端相比，移动端新建必须显式保存，已有渠道也没有 1 秒防抖自动保存。移动端源码中未找到已有渠道复制按钮、渠道包导入导出或配置文件选择器（`mobile/src/tools/llm-api/views/LlmSettingsView.vue:31-89`、`mobile/src/tools/llm-api/components/ProfileEditor.vue:92-113`）。

### 2.3 查看、启停、模型获取与连接测试

“查看”在桌面端是侧边栏选择后展开完整 Profile 编辑器，在移动端是点击卡片后打开全屏编辑弹窗。两者都显示启用状态、地址和模型数量；桌面端还在列表中提供排序，移动端虽保留管理模式和多选状态字段，但当前设置页没有发现进入管理模式的按钮或批量动作绑定，因此**静态代码只能确认状态结构，不能确认批量管理入口可达**（`src/views/Settings/shared/ProfileSidebar.vue:1-150`、`mobile/src/tools/llm-api/views/LlmSettingsView.vue:20-22,102-108,146-161`）。

启停都是 Profile 级 `enabled` 字段，不是 Key 或单模型状态。桌面端普通请求会检查该字段，但设置页探测可以对当前编辑中的禁用渠道发起探测；移动端卡片开关直接调用 `updateProfile`。两端都没有发现“暂停后删除凭据”或“停用后禁止查看/编辑”的逻辑，已有渠道停用后仍可打开和修改。

连接测试是设置页的独立探测路径，覆盖模型列表、推理与 Key 三类探测，结果分别落在探测明细和 Key 健康状态两处，两处各自独立记录。桌面端“检查模型列表”调用 `channel-probe-service` 的 `model-list` 探测；模型编辑区可按模型、端点、流式模式和媒体成本确认执行推理探测，也可批量探测；Key 管理器可指定某个 Key 和模型测试，并把结果反馈给 Key 健康状态。探测若确认某个模型只有一种可用协议，可生成路由应用候选，由用户选择后写入模型绑定；模型列表返回的端点声明也可形成批量绑定候选。探测结果不会未经确认自动改变生产路由（`src/views/Settings/llm-service/probe/route-application.ts:1-58`、`components/ModelProbeDialog.vue:129-157,589-604`）。移动端编辑器提供模型列表获取、模型探测和批量探测，但本次未找到桌面端这套路由应用 UI。探测结果包含分类、耗时和响应摘要，反映单次探测请求的返回；真实聊天请求的成败需另行运行验证。

### 2.4 桌面端创建与编辑

`src/views/Settings/llm-service/LlmServiceSettings.vue` 是桌面渠道管理页，支持：

- 从 Provider 预设或空白 Profile 创建渠道；
- 启用、停用、排序、删除和编辑渠道；
- 配置 Base URL、多 Key、网络策略、自定义 Header 和端点；
- 手工添加/编辑模型，或获取远端模型列表；
- 对单个模型按操作绑定协议与自定义端点，或批量绑定 Chat 协议；
- 测试模型列表、指定模型、指定能力与指定端点；
- 批量检测模型，查看首字节和总耗时；
- 对图片/音频等可能计费的探测要求显式确认。

渠道停用只阻止普通 `useLlmRequest` 调用。设置页探测通过 `allowDisabledProfile` 或直接调用 Adapter，可以验证尚未启用的渠道。

### 2.5 多格式导入

`src/utils/llm-config-import/` 提供与 UI 解耦的解析层，可从以下内容生成一个或多个 `ParsedLlmProfileDraft`：

- cURL；
- 环境变量文本；
- JSON，包括 OpenCode 多 Provider 和 Codex `auth.json`；
- TOML，包括 Codex `config.toml`；
- 粘贴的混合文档或多个文件。

解析结果包含来源、置信度、警告和候选渠道。创建态可多选批量写入，编辑态只覆盖一个现有渠道；低置信度协议允许人工修正，相同 `providerType + normalizedBaseUrl` 会提示重复。占位 Key 不会当作真实凭据写入。

这种导入面向“迁移已有客户端配置”，不是运行时动态发现或远程配置中心。

除上述解析式导入外，还有**原生渠道导入导出**——`src/utils/llm-profile-transfer.ts` 定义 `LlmProfileBundle` 序列化格式，导出对话框（`LlmProfileExportDialog.vue`）支持搜索、多选、单渠道/批量导出，敏感信息自动检测与脱敏（导出时可选择是否包含凭据），导入时无损保留网络策略、自定义端点等完整配置；JSON 解析器支持 New API“复制连接信息”格式（`_type: "newapi_channel_conn"` → OpenAI-Compatible 渠道候选，无效 URL 校验且密钥不进入警告日志）。

### 2.6 凭据隔离与混淆存储

渠道配置与凭据由 `useLlmProfiles` 分开保存：`llm-service/profiles.json` 只存渠道配置，API Key 与敏感自定义 Header 移入独立的混淆文件，桌面端是 `llm-service/secrets.dat`，移动端是 `AppData/llm_service_secrets.dat`，加解密实现集中在 `src/utils/llm-secret/`。混淆文件用动态盐格式，形如 `AIOHUBVLT1.<base64 salt>.<base64 cipher>`，每次落盘的盐值不同。加载时按 profile.id 把凭据透明注入内存，落盘时配置文件的 `apiKeys` 保持空数组。这层保护属于静态混淆，能读到应用数据目录的一方仍可解码；通用配置文件、导出和日志里不再出现明文 Key。

Key 健康状态存放在独立的 `llm-service/key-states.json`，记录的索引是不可逆的 64 位稳定哈希：前缀 `k_` 加 16 位十六进制，由双段 FNV-1a 拼接而成，状态文件里因此看不到明文 Key。旧版本用明文 Key 作索引，加载时迁移并立即回写。持久化前，服务会把历史错误和上游返回中出现的当前明文 Key 替换为 `[redacted-key]`；首次加载还会把旧 `profiles.json` 里残留的明文 Key 迁进独立凭据文件（`src/utils/llm-secret/apiKeyHash.ts`、`src/utils/llm-secret/keyStates.ts`、`src/utils/llm-secret/profiles.ts`）。

边界：混淆算法与盐值都在客户端代码里，安全性来自"不与配置混存 + 不写入日志/导出"，不是强加密；移动端与桌面端各自维护自己的凭据文件，两者不互相解密。

## 3. 模型目录与元数据

### 3.1 远端模型获取

模型列表获取器先读取 Provider 是否支持模型列表及其默认端点，再通过共享适配器请求；入口见 `src/llm-apis/model-fetcher.ts`。请求会携带：

- Base URL；
- 指定 Key 或 Profile 第一个 Key；
- 自定义 Header；
- Profile 自定义的模型列表端点；
- Provider 类型；
- 桌面 Transport 与 60 秒默认超时。

模型列表请求当前显式使用 `strategy: "proxy"`，不遵循 Profile 的 `networkStrategy`。因此即便渠道配置为 `native`，获取模型列表仍走 Rust 代理。

远端结果被转换成渠道内的模型快照，保留模型 ID、名称、Provider、上下文长度、输出上限、输入/输出模态、支持参数和价格。OpenRouter 还会请求并保留更完整的输出模态信息。


- **能力合并不再“只由远端推导”**：转换逻辑先并入当前激活的模型元数据规则能力，再用 API 显式返回的能力覆盖；API 未返回某项能力时不再写入 `false`，视觉与思考能力只有在输入模态或支持参数明确给出时才写入。
- **路由信息随模型持久化**：远端返回的支持端点类型会写入模型 routing 字段，供执行路由的“端点类型唯一识别”分支使用（见第 4 节）。
- 模型身份与 Embedding 空间分离，为模型目录引入 canonical ID 概念，当前主要被 knowledge-base 的向量化空间消费；桌面渠道目录仍以模型快照为主。相关实现位于 `packages/llm-core/src/model-identity/`，模型编辑对话框只对检测到 Embedding 能力的模型显示专属身份配置区块。

### 3.2 模型能力是运行时路由依据

模型快照中的能力字段不只是 UI 标签，请求入口会据此选择：

- `embedding` Adapter；
- Rerank；
- 视频、图片、音频/音乐生成；
- 默认 Chat；
- `preferChat` 强制媒体能力仍走对话接口。

模型元数据规则在模型创建、导入、刷新或批量应用时写入模型对象。运行时读取模型快照，不应再实时用全局规则覆盖网络目标或能力。这样规则升级不会悄悄改变已有渠道的请求语义。

### 3.3 远端条目与本地规则是两套元数据

[`src/types/llm-profiles.ts`](../../aio-hub/src/types/llm-profiles.ts) 的 `LlmModelInfo` 是渠道内持久化的模型快照，主要字段包括：

| 类别 | 字段 |
|---|---|
| 身份与展示 | `id`、`name`、`group`、`provider`、`icon`、`description`、`version` |
| 能力 | `capabilities`，覆盖视觉、联网、工具、代码执行、思考、图像/视频/音频生成、Embedding、Rerank、JSON、文档等 |
| 限制 | `tokenLimits.output`、`contextLength`、`contextLengthRange` |
| 模态和协议提示 | `architecture.inputModalities/outputModalities`、`supportedFeatures.parameters/generationMethods` |
| 参数和费用 | `defaultParameters`、`pricing`、`customParameters` |
| 专用行为 | `defaultPostProcessingRules`、`mediaGenParams` |

远端 `/models` 结果经 [`src/llm-apis/model-fetcher.ts`](../../aio-hub/src/llm-apis/model-fetcher.ts) 转换时，会直接写入上下文、最大输出、输入/输出模态、支持参数和价格；能力对象合并时先附当前激活规则能力，再用 API 显式返回的 `vision`/`thinking` 覆盖（API 未返回时不写 `false`）。工具调用、文档、媒体生成等更细能力仍主要依赖预设规则或人工编辑。

另一套是 [`src/types/model-metadata.ts`](../../aio-hub/src/types/model-metadata.ts) 定义的 `ModelMetadataRule`。规则属性是开放对象，内置支持图标、Tokenizer、分组、能力、上下文、价格、描述、推荐用途、版本、发布日期、特性和媒体生成参数。它是对任意 Provider/模型 ID 生效的声明式补丁层，在模型目录之上补充元数据。

### 3.4 规则匹配与覆盖顺序

[`src/config/model-metadata.ts`](../../aio-hub/src/config/model-metadata.ts) 支持四种匹配类型：

- `provider`：Provider ID 不区分大小写的精确匹配；
- `model`：默认区分大小写的精确匹配，也可改用正则；
- `modelPrefix`：名称虽叫 Prefix，非正则模式实际是对完整模型 ID 做不区分大小写的 `includes`；
- `modelGroup`：已废弃，不参与匹配。

启用规则先按优先级从高到低排序。若命中独占规则，只保留优先级不低于最高独占规则的匹配项；随后按低优先级到高优先级深合并，所以高优先级字段最终覆盖低优先级字段，而不同规则中的嵌套能力可以累积。

内置规则按能力、Provider、模型家族、特定模型、图像/视频生成参数和图片输入限制分模块维护，汇总入口是 [`src/config/model-metadata-presets/index.ts`](../../aio-hub/src/config/model-metadata-presets/index.ts)。用户规则由 [`src/stores/modelMetadataStore.ts`](../../aio-hub/src/stores/modelMetadataStore.ts) 保存到 `model-metadata/metadata-rules.json`，并可从旧版 `localStorage` 的 `model-icon-configs` 迁移。

内置目录随应用版本自动同步：加载时若当前内置目录的版本或指纹与已存快照不同，就整体替换快照，用户对某条内置规则的本地覆盖、屏蔽（suppressedBuiltinRuleIds）和自定义规则都保留；被上游删除但本地改过的规则继续作为用户规则生效，不会静默丢失。刷新模型配置是把规则写入已保存模型的显式动作（`packages/model-metadata-core/src/migration.ts` 的 syncCatalogSnapshot、`src/stores/modelMetadataStore.ts`）。

### 3.5 元数据的实际消费者

这套元数据不是纯展示信息，消费路径至少有四类：

1. 渠道创建、模型导入和批量应用把分组、图标、描述、能力和媒体参数写入 `LlmModelInfo`。
2. 请求入口根据已保存模型的能力选择 Chat、Embedding、Rerank 或媒体生成 Adapter。
3. [`src/llm-apis/request-builder.ts`](../../aio-hub/src/llm-apis/request-builder.ts) 用模型能力过滤工具、思考等级等请求参数，同时读取活动规则的分组判定模型家族。
4. Token Calculator 读取规则中的 tokenizer，媒体生成器用媒体参数约束控件并剔除不支持的参数。

因此它并非严格的“只在导入时快照”模型：Adapter 大类和大部分 capability gate 依赖模型对象，但模型家族、Tokenizer 和部分工具仍会读取当前活动规则。修改规则可能不改变渠道网络目标，却仍可能改变参数序列化、Token 估算或媒体参数 UI。

### 3.6 数据边界与风险

- 远端 `pricing.prompt/completion` 使用每 token 字符串，规则层 `pricing.input/output` 声明为每百万 token 数值；二者结构和单位不同，没有统一归一化为一个权威费用模型。
- 同一能力在远端条目、模型快照和活动规则中都可能出现，不同写入入口的覆盖顺序并不完全相同。批量应用时通常保留模型已有字段，编辑器“应用预设”则可能用规则值覆盖能力子字段。
- `modelPrefix` 的实现是包含匹配，宽泛短串容易误命中命名空间中的其他模型；正则规则也只在运行时捕获错误并跳过，没有启动期阻断。
- 元数据规则可影响请求参数和 Adapter 选择，应按运行配置管理，不能只当作图标主题文件备份或分发。

这项能力的项目分类边界与横向核对，已归入本类目的横向对比。

### 3.7 外部元数据来源

模型元数据除了内置目录与用户规则，还能从外部来源订阅。服务层负责来源适配器注册、目录拉取、单次更新与自动更新，拉取结果经同一转换管线写成本地规则；配置入口是设置页的 `ModelMetadataSourcesDialog.vue`，服务实现在 `src/services/modelMetadataSourceService.ts`。外部来源更新按来源整体应用，不做逐条比对确认。外部目录、内置规则和用户规则构成三个写入面，优先级仍按第 3.4 节的独占与深合并规则处理，来源本身不携带优先级。

## 4. 运行时选择与路由

### 4.1 Agent 是主聊天的默认绑定点

Agent 配置保存 `profileId` 和 `modelId`。主聊天构造请求时先从 Agent 取默认组合；用户可对一次发送指定 `temporaryModel`，不会永久改写 Agent。

上下文预览和历史分支处理的优先级为：

```text
待发送消息的临时渠道/模型
  -> 目标历史节点 metadata 中的渠道/模型
  -> 当前 Agent 默认渠道/模型
```

助手消息 metadata 会记录 `profileId`、`modelId`，并快照 Profile 名、Provider 类型和模型名。即使用户之后重命名或删除渠道，历史消息仍能说明当时实际使用了什么。

翻译、话题命名、上下文压缩、多模态转写等辅助任务也使用 `profileId:modelId` 字符串或显式二元组配置；未单独配置时才回退全局默认模型或 Agent 模型。

### 4.2 通用请求入口

`src/composables/useLlmRequest.ts` 的请求流程是：

1. 按渠道 ID 读取 Profile 并检查启用状态，只在该渠道的模型列表中查找模型 ID。
2. 优先使用显式传入的 Key，否则从该渠道的凭据池选择一个；随后克隆 Profile 并缩成当前 Key，避免 Adapter 自行再选。
3. 按模型能力过滤不支持的生成参数，再叠加模型自定义参数。
4. 注入 Profile 的网络/TLS/HTTP 选项。
5. 按操作类型解析**执行路由**；`preferChat` 和 `_forceChatMode` 可强制走 chat。模型绑定优先，其次使用唯一端点声明。普通渠道再回退 Provider 默认；聚合渠道依次检查渠道默认、内置模型表和静态操作默认，仍无结果就显式报错。解析结果可能改写 Profile 类型与端点，并把适配器、路由来源和渠道类型写入 Inspector 上下文。
6. 用有效的 Profile 类型选择协议实现，再按模型能力选择 Chat、Embedding、Rerank、媒体或专用语音转写方法。
7. 成功或失败后按错误分类更新 Key 健康状态（见第 5 节），并把响应或异常交还调用方；聊天调用方会在应用层等待重试并重新选 Key（见第 5.3 节）。

路由是确定性的，没有读取 Profile 顺序、权重、延迟、剩余额度或价格来改选渠道——模型执行路由只做**渠道内的协议/端点选择**，不跨渠道改选。

### 4.3 虚拟渠道：一次请求的候选目标序列

虚拟渠道把用户看到的渠道与真实请求目标分开。Profile 上的 `virtualChannel` 声明一组候选目标，每个目标是一对渠道与模型；共享核心据此生成一次 `ChannelExecution`，按候选顺序逐次尝试，失败后是否继续由 `isChannelRetryableError` 统一判定，配置错误与执行错误则分别由两类异常区分。绑定关系还能按操作维度单独指定，让虚拟渠道里的真实模型各自解析到不同协议与端点。候选集合与顺序都来自用户的显式声明，运行时不会按健康度、成本或延迟重新挑选目标。细节与配置入口见 `docs/architecture/llm-execution-routing.md`，实现在 `packages/llm-core/src/virtual-channel.ts`。

## 5. 多 Key 轮询与熔断

Key 管理器为每条 Profile 保存以下状态，入口见 `src/composables/useLlmKeyManager.ts`：

| 状态 | 说明 |
|---|---|
| Key 手动启用 | 用户逐个 Key 的启停开关 |
| 失败状态 | 是否已标坏、连续错误次数与最近一次错误 |
| 时间记录 | 最近使用、最近失败和熔断时间 |
| 轮询下标 | 该 Profile 上次选中的 Key 位置 |
| 开关与恢复设置 | 按 Profile 隔离的 `enableAutoDisable`（默认 `false`）和 `autoRecoveryTime`（默认 60 秒），存储版本 `1.1.0` |

自动禁用与恢复设置早期存在全局字段里，迁移时归入各 Profile 的独立配置。全局值无法无歧义映射到具体渠道，迁移时直接丢弃，由各渠道按新默认值重新显式启用（`normalizeKeyStatesStorage`）。

### 5.1 选择策略

Key 选择逻辑先过滤手动禁用和已熔断项，再从上次下标之后轮询。默认自动恢复时间为 60 秒；到期的熔断项会被恢复并重新参与选择，入口是 `pickKey()`。

**没有可用 Key 时区分“全部被用户禁用”和“全部熔断”两种原因，并抛出 `ApiKeyUnavailableError`**；后者附最早可恢复时间 `retryAt`，不会把请求打到已知坏 Key 上。

### 5.2 失败判定

普通业务请求的错误处理已接入分类策略：请求入口调用错误分类策略，把错误分为五类动作；具体实现见 `src/llm-apis/key-health-policy.ts`，并复用 llm-core 的 `classifyProbeError`：

- `authentication-failure` → 认证失败强制标坏；
- `rate-limit-failure` → 429/限流立即熔断（沿用旧的即时熔断规则）；
- `transient-failure` → 按连续错误累计；
- `record-only` → 只记录，不计数也不自动禁用；
- `success`/`ignore` → 无操作。

本地 Rust 代理自身产生的错误（请求未到达目标服务、请求非法等）单独归为探测分类 `proxy`，再映射到 `record-only` 动作，代理故障因此不会把上游 provider 的 Key 标坏。判定依据是代理自产响应上的 `x-aio-proxy-origin: aiohub` 标记头，标记头由 Rust 代理写入，错误分类与动作映射见 `src/llm-apis/key-health-policy.ts:43-50` 与 `src-tauri/src/commands/llm_proxy.rs`。

请求失败时，通用请求入口会先用 `decorateLlmError` 给错误消息加上 `[渠道名 · 模型名]` 前缀再抛出，尽量原地修改 Error 以保留类型和 status/code，message 只读时回退为包装错误（`packages/llm-core/src/llm-error-context.ts`）。

旧的“429 立即熔断、其他错误累计 3 次熔断、成功清零”计数规则仍保留，但自动熔断现在多一个前提：**同渠道还有其他可用 Key**，且该 Profile 开启了自动禁用；最后一个可用 Key 不会因连续失败被自动熔断。设置页探测与普通请求共用同一份策略文件。

### 5.3 渠道层不重试，聊天应用层重试并重新选 Key

`useLlmRequest.sendRequest` 单次调用只选一次 Key 并调用一次 Adapter；失败后分类记录健康状态并立即把错误抛给调用方，渠道层内部没有重放、退避或跨 Profile 切换。

重试由调用方负责。llm-chat 主聊天链路在应用层跑了重试循环：默认最多重试 2 次（合计 3 次尝试），间隔固定 3 秒，也可切换为指数退避，遇到 429 再追加 5 秒惩罚等待。是否重试先看可重试状态码白名单：有明确状态码却不在白名单里就直接放弃，2xx、504 和 524 始终排除，网络错误或超时这类没有状态码的失败不受白名单限制。每次重试都重新调用发送入口，Key 选择随之重跑一遍——轮询下标继续推进，已熔断或已标坏的 Key 被过滤，同渠道还有可用 Key 时这次重试就换了 Key。流式响应收到首个 chunk 后再失败不重试，避免已输出内容重放；400 与参数非法错误、用户主动中止同样不重试（重试循环见 `src/tools/llm-chat/composables/chat/useSingleNodeExecutor.ts:557-660`，默认值见 `defaultSettings.ts:160-175`，白名单见 `utils/retryStatusCodes.ts`）。

媒体生成与媒体会话命名还有结构化输出降级尝试（`useMediaGenAILogic.ts:170-227`），每次也重新走 Key 选择，但那是解析兜底，不是网络失败重试；翻译、话题命名、上下文压缩等辅助任务本次未发现重试循环。

因此“负载均衡”仍是跨请求的 Key 轮询；“熔断”除了影响后续请求，也会被聊天链路的重试立刻利用——失败后等待并改选下一枚可用 Key。

## 6. Provider Adapter 与协议边界

应用层的适配器契约由 `src/llm-apis/adapters/index.ts` 定义，一个适配器要提供对话、Embedding、图片、音频和视频五类能力方法，语音转写方法可选。具体实现逐步下沉到 `packages/llm-core`：

- OpenAI-Compatible Chat Completions；
- OpenAI Responses；
- Anthropic Messages；
- Gemini / Vertex GenerateContent；
- Cohere Chat V2；
- Embedding、Rerank、模型列表和异步媒体任务；
- OpenAI/Whisper 风格的 multipart 语音转写。

共享 Core 使用 canonical request/response 和 `ProviderAdapter`，负责请求体、URL、Header、流式 Decoder 与 Provider 语义；它不读取 Vue Store，也不持有 Key 状态。桌面和移动端各自负责把 Profile 变成 Core DTO，并注入平台 Transport。

这个边界让协议兼容可以跨端复用，同时把系统代理、无效证书、本地文件流上传等平台行为留在 Rust/桌面 Transport。

Provider 层的原生工具调用编解码统一到 `LlmMessage` 契约上，消息可以携带工具角色、工具调用 ID、元数据字段和工具名。OpenAI 的两套接口分别编码 assistant 的 tool_calls 与工具结果续轮，Gemini 保留函数调用 ID 且流式聚合时不覆盖真实 ID，Cohere 同时支持 assistant 工具调用与并行工具结果编码，Ollama 走 OpenAI 兼容端点并声明工具与工具选择能力。OpenAI Responses 还会解析推理摘要并保持流式边界。LLM Inspector 能基于最终请求体给出原生工具声明与解码诊断，实现见 `src/llm-apis/tool-diagnostics.ts`。这些能力为后续原生工具编排（区别于 VCP 文本协议）打基础，模型通信层的工具协议仍以 VCP 为准（见 Agent 工具笔记第 3 节）。

## 7. 自定义端点与 Header

一个 Profile 可分别覆盖 Chat Completions、Responses、Anthropic Messages、Gemini GenerateContent、Completions、Models、Embeddings、Rerank、图片、语音生成、语音转写、审查和视频端点。

端点既可为相对路径，也可为完整 URL；部分端点支持 `{model}`、`{video_id}` 等占位符。Adapter 根据协议读取对应字段，Anthropic 还兼容用 `chatCompletions` 作为旧配置回退。

自定义 Header 在 Adapter 构造鉴权与协议 Header 后合并。设置页提供 OpenAI Codex、Claude Code 等客户端兼容预设，因此它不仅用于租户标记，也可改变鉴权、Beta 特性或网关识别行为。Header 值与 API Key 一样明文持久化。

## 8. 网络传输

共享 Core 产生 `WireRequest`，桌面 Transport 再把 JSON、文本、字节、Multipart 或本地文件引用序列化；相关入口为 `packages/llm-core` 和 `src/llm-apis/transports/desktop.ts`。

`fetchWithTimeout()` 的桌面策略为：

- `native` 且请求不含本地文件：WebView 直接 fetch；
- 其他情况：启动本机 loopback Rust 代理并转发；
- 本地文件、Multipart 文件和 tagged `LocalFileRef` 必须走 Rust，避免把本地路径或文件内容暴露给 WebView；
- 本地地址/IP 会由上层额外设置 `forceProxy`；
- 代理启动端口冲突时可换到可用端口，并使用进程内 capability token 校验请求。

这里没有从代理失败自动回退到 native，或反向回退。`auto` 也不做健康探测；当前实现是“除显式 native 外使用代理”。

## 9. 测试、探测与可观测性

渠道设置页的 probe 服务支持：

- 模型列表探测；
- Chat 流式/非流式探测；
- Embedding、Rerank、图片和音频能力探测；
- 自定义端点类型覆盖；
- 响应语义校验，而不只判断 HTTP 2xx；
- 首字节时间、总耗时、用量和响应摘要；
- 最多 8 并发的批量模型探测（默认 3）；
- 错误分类：认证、授权、限流、模型不可用、参数、网络、本地代理、超时、Provider 等；本地代理一类在探测详情与列表中显示为“本地代理/未连接”。

LLM Inspector 在统一的请求与传输入口上关联同一个 requestId，据此捕获请求内容、响应头、流式块和错误上下文。请求分发时，它会把渠道类型、实际生效的适配器、执行操作和路由来源写进 Inspector 上下文；工具意图（适配器 ID、请求中的工具数量、是否含原生工具）在能力过滤后先记录一次，响应返回后再用最终请求体的解码结果覆写。这些记录服务于单渠道诊断，自动渠道评分和动态路由都不读取它们（`src/composables/useLlmRequest.ts`、`src/llm-apis/tool-diagnostics.ts`）。

共享 Core 和应用 Adapter 均有协议 fixture、流式分帧、模型列表、Probe 与 Transport 单测。设置页也有导入和探测组件测试。

## 10. 能力边界与横向比较要点

### 已实现

- Profile 级渠道增删改查、启停和排序；
- 桌面端完整的渠道创建、编辑、删除、排序、启停、导入、导出和独立探测入口；移动端有独立的增删改、启停和探测入口，但配置包导入导出与复制未找到；
- 丰富的官方/兼容 Provider 预设；
- 多格式配置导入、重复提示与 New API"复制连接信息"、原生 `LlmProfileBundle` 导入导出（可脱敏）；
- 多 Key 轮询、手动启停、错误状态、按 Profile 隔离的熔断/恢复和分类化健康策略；
- 模型手工维护、远端发现（含能力合并与路由信息持久化）和能力元数据；
- 多协议、多能力 Adapter（含原生工具调用编解码与 Responses 推理摘要）；
- 模型执行路由：按操作类型把模型解析到协议 Adapter/端点（渠道内路由）；
- 自定义 Header、细粒度端点和 Provider options；
- Agent/辅助任务/临时请求的显式渠道模型选择；
- Rust 代理、网络兼容选项和请求 Inspector；
- 能力感知的连接测试和批量模型探测。

### 未实现或不应误判

- 没有跨 Profile 的同模型聚合或别名层；
- 没有渠道权重、优先级、配额、成本或延迟路由（模型执行路由是渠道内的协议/端点选择，不跨渠道改选）；
- 没有渠道层请求内 Key 重试（重试在 llm-chat 应用层，等待后重发并重新选 Key，见第 5.3 节）；
- 没有跨渠道 failover；
- 没有加密或系统凭据库；
- `auto` 网络策略不是自动择优；
- 模型列表请求固定走代理；
- 设置页可见 Provider 与运行时 Adapter 的单一注册源约束已通过 `defineAdapters<Record<LlmProviderType, LlmAdapter>>` 建立。
- 未找到面向渠道管理的 CLI、TUI、独立 Web 服务或 HTTP 配置 API；本节结论的检查范围限于仓库内脚本与源码。

## 11. 关键源码索引

- 渠道与模型类型：[`src/types/llm-profiles.ts`](../../aio-hub/src/types/llm-profiles.ts)
- Provider 声明：[`src/config/llm-providers.ts`](../../aio-hub/src/config/llm-providers.ts)
- 渠道预设注册：[`src/config/llm-presets/index.ts`](../../aio-hub/src/config/llm-presets/index.ts)
- Profile 持久化：[`src/composables/useLlmProfiles.ts`](../../aio-hub/src/composables/useLlmProfiles.ts)
- Key 状态与轮询：[`src/composables/useLlmKeyManager.ts`](../../aio-hub/src/composables/useLlmKeyManager.ts)
- 通用请求入口：[`src/composables/useLlmRequest.ts`](../../aio-hub/src/composables/useLlmRequest.ts)
- 模型执行路由：[`packages/llm-core/src/model-execution-routing.ts`](../../aio-hub/packages/llm-core/src/model-execution-routing.ts)
- Adapter 注册：[`src/llm-apis/adapters/index.ts`](../../aio-hub/src/llm-apis/adapters/index.ts)
- 模型列表：[`src/llm-apis/model-fetcher.ts`](../../aio-hub/src/llm-apis/model-fetcher.ts)
- 共享 Provider Core：[`packages/llm-core/src`](../../aio-hub/packages/llm-core/src)
- 桌面 Transport：[`src/llm-apis/transports/desktop.ts`](../../aio-hub/src/llm-apis/transports/desktop.ts)
- Rust 代理入口：[`src/llm-apis/common.ts`](../../aio-hub/src/llm-apis/common.ts)
- 设置页：[`src/views/Settings/llm-service/LlmServiceSettings.vue`](../../aio-hub/src/views/Settings/llm-service/LlmServiceSettings.vue)
- 桌面 Profile 编辑与自动保存：[`src/views/Settings/llm-service/composables/useProfileEditor.ts`](../../aio-hub/src/views/Settings/llm-service/composables/useProfileEditor.ts)
- 桌面渠道导出与序列化：[`src/views/Settings/llm-service/components/LlmProfileExportDialog.vue`](../../aio-hub/src/views/Settings/llm-service/components/LlmProfileExportDialog.vue)、[`src/utils/llm-profile-transfer.ts`](../../aio-hub/src/utils/llm-profile-transfer.ts)
- 渠道探测：[`src/views/Settings/llm-service/probe/channel-probe-service.ts`](../../aio-hub/src/views/Settings/llm-service/probe/channel-probe-service.ts)
- 路由编辑与探测结果应用：[`src/views/Settings/llm-service/components/ModelRoutingEditor.vue`](../../aio-hub/src/views/Settings/llm-service/components/ModelRoutingEditor.vue)、[`src/views/Settings/llm-service/probe/route-application.ts`](../../aio-hub/src/views/Settings/llm-service/probe/route-application.ts)
- 语音转写适配：[`src/llm-apis/adapters/openai/transcription.ts`](../../aio-hub/src/llm-apis/adapters/openai/transcription.ts)
- 凭据隔离与哈希索引：[`src/utils/llm-secret/`](../../aio-hub/src/utils/llm-secret/)（`storage.ts`、`codec.ts`、`profiles.ts`、`apiKeyHash.ts`、`keyStates.ts`）
- 虚拟渠道：[`packages/llm-core/src/virtual-channel.ts`](../../aio-hub/packages/llm-core/src/virtual-channel.ts)、路由说明 [`docs/architecture/llm-execution-routing.md`](../../aio-hub/docs/architecture/llm-execution-routing.md)
- 外部元数据来源：[`src/services/modelMetadataSourceService.ts`](../../aio-hub/src/services/modelMetadataSourceService.ts)、`src/views/Settings/llm-service/components/ModelMetadataSourcesDialog.vue`
- 输出预算裁剪与采样兼容：[`packages/llm-core/src/output-tokens.ts`](../../aio-hub/packages/llm-core/src/output-tokens.ts)、[`packages/llm-core/src/sampling-compatibility.ts`](../../aio-hub/packages/llm-core/src/providers/sampling-compatibility.ts)
- DeepSeek 网页工具端点：[`src/llm-apis/adapters/deepseek/tools.ts`](../../aio-hub/src/llm-apis/adapters/deepseek/tools.ts)
- 配置导入：[`src/utils/llm-config-import`](../../aio-hub/src/utils/llm-config-import)
- 移动端 Profile Store：[`mobile/src/tools/llm-api/stores/llmProfiles.ts`](../../aio-hub/mobile/src/tools/llm-api/stores/llmProfiles.ts)
- 移动端渠道设置页与编辑器：[`mobile/src/tools/llm-api/views/LlmSettingsView.vue`](../../aio-hub/mobile/src/tools/llm-api/views/LlmSettingsView.vue)、[`mobile/src/tools/llm-api/components/ProfileEditor.vue`](../../aio-hub/mobile/src/tools/llm-api/components/ProfileEditor.vue)
- Agent 运行时选择：[`src/tools/llm-chat/composables/chat/useChatExecutor.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useChatExecutor.ts)
- 聊天链路应用层重试：[`src/tools/llm-chat/composables/chat/useSingleNodeExecutor.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useSingleNodeExecutor.ts)

## 12. 未验证事项

1. 本次未启动 Tauri 桌面端，没有实测官方 Provider、自建网关和代理模式下的 TLS/HTTP 行为。
2. 未检查真实用户配置目录的文件 ACL；凭据文件为客户端混淆而非系统级加密，混淆格式可被同机代码解码，实际防泄漏强度未做运行验证。
3. 未实测 Azure 渠道的真实调用。
4. 未启动移动端 Tauri/Android 运行态；移动端配置文件路径、保存成功、真实模型探测和平台文件权限均为源码确认或静态推断，未做设备实测。
5. Suno、MiniMax 等异步媒体任务自身可能有任务轮询重试；这类重试作用于媒体任务内部，LLM Chat 的 Key/渠道故障转移属于另一条链路，本次未逐项展开。
6. 未运行桌面端或移动端 UI，因此桌面文件选择器、导出文件实际内容、导入后的提示/错误、移动端弹窗保存和探测结果展示均未验证；Web、CLI、TUI 的“未找到”结论也未覆盖仓库外部脚本或未来构建产物。
