# AIO Hub LLM 渠道管理调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-18
>
> 代码快照：`2ddbb19288c08bda1c080fc9a5f2e71149feaebc`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改目标仓库
>
> 调查范围：LLM 渠道数据模型、配置生命周期与管理入口、协议适配、模型目录、凭据、重试、备份与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 把一条 LLM 渠道建模为一个 `LlmProfile`。Profile 同时持有协议类型、Base URL、多个 API Key、模型目录、自定义 Header、自定义端点、网络策略和 Provider 专属参数；业务侧用稳定的 `profileId + modelId` 明确选择请求目标。

这套方案的特点是“**渠道配置集中、运行时显式路由、协议适配与网络传输分层**”：

- 桌面端提供 21 种可见渠道类型，其中 4 种聚合渠道把渠道身份与线协议解耦，其余不少类型最终复用 OpenAI-Compatible Adapter；
- 每条渠道可配置多个 Key，按轮询选择，并记录启停、连续错误、429 熔断和自动恢复状态；
- 模型属于渠道，既可手工维护，也可调用模型列表端点获取，再由模型元数据规则补全能力；
- Chat、Responses、Anthropic、Gemini、Embedding、Rerank、媒体生成和语音转写可以使用不同端点；
- Provider 请求构造/响应解析位于共享 TypeScript Core，桌面网络默认经本地 Rust 代理；
- Agent 默认绑定一个渠道和模型，单次发送、重试、续写时可临时覆盖；历史消息保存实际使用的渠道/模型快照。

它没有“同模型的多渠道池”、渠道权重、优先级、成本路由或跨渠道自动故障转移。多 Key 也不是请求级重试器：某次调用失败后只会更新 Key 健康状态并把错误抛给上层，下一次请求才可能选择另一个 Key。

- **模型执行路由已落地**：请求分发先查模型按操作保存的协议/端点绑定，再尝试把远端声明的唯一端点类型映射为协议。普通渠道随后回退到 Provider 默认协议；聚合渠道则继续查渠道级默认协议、内置模型路由表和静态操作默认。仍无法解析时抛出 `UnresolvedModelRouteError`，不根据模型名静默猜测。探测结果可由用户逐模型或批量确认并写回绑定；这是**同一渠道内的模型到协议/端点路由**，不是跨渠道故障转移（`packages/llm-core/src/model-execution-routing.ts:371-449`、`src/views/Settings/llm-service/probe/route-application.ts`）。
- **audio.cpp 成为一等本地音频渠道**：渠道预设同时声明 OpenAI 兼容 TTS 与 Whisper 风格 ASR 端点。模型带 `asr` 能力且请求提供转写输入时，通用请求入口改走 `/v1/audio/transcriptions` multipart，而不是把音频塞入 Chat 消息；桌面转写工具会先把非 WAV 输入转换为 WAV（`src/composables/useLlmRequest.ts:226-262`、`src/tools/transcription/engines/audio.engine.ts:56-305`）。

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

类型层、设置层和适配器注册层不是同一个声明源，历史上产生过漂移；当前已用完整类型约束避免遗漏。Ollama 改用 OpenAI 兼容端点，模型列表仍走原生 `/api/tags`，并声明工具参数支持（`src/config/llm-providers.ts`，提交 `27e899483`）。预设实现已从单个大文件拆成 `src/config/llm-presets/presets/` 下按渠道独立模块，由 `index.ts` 统一注册；这是维护边界变化，不改变 Profile 的持久化结构。

### 1.3 网络与安全默认值

`DEFAULT_LLM_PROFILE` 默认启用渠道，并把 `networkStrategy` 设为 `auto`。当前 `fetchWithTimeout()` 的真实解释是：除显式 `native` 外都走 Rust 代理，所以 `auto` 实际等同于默认代理路径，而不是运行时在两种传输间探测择优。

`relaxIdCerts` 和 `http1Only` 默认都是 `true`。前者放宽无效证书校验，后者强制 HTTP/1.1；它们提高私有/老旧网关兼容性，但不是官方 HTTPS API 的保守安全与性能默认值。

## 2. 配置生命周期、管理入口与持久化

### 2.1 管理入口按平台的实际覆盖

当前代码把渠道管理分成桌面端和移动端两套状态/配置实现，并没有一个由 CLI、TUI、Web 服务统一承载的 Profile 管理后端。桌面端 `useLlmProfiles` 保存到 `llm-service/profiles.json`，移动端 Pinia Store 保存到独立的 `llm-profiles/llm_profiles.json`；二者共享部分类型和 Provider Core，但不是同一份运行时配置。桌面端入口是 Tauri WebView 中的 `LlmServiceSettings.vue`，移动端入口是移动应用的 `LlmSettingsView.vue`（`src/composables/useLlmProfiles.ts:43-51`、`mobile/src/tools/llm-api/stores/llmProfiles.ts:27-32`）。

| 入口 | 源码确认的能力 | 边界与证据状态 |
|---|---|---|
| 配置文件 | 文件内容是包含 `profiles` 数组的 JSON；启动时加载、规范化旧字段并保存。直接编辑文件可以改变渠道的全部持久化字段，包含启停、模型、端点、Header 和凭据。桌面端还会从旧 `localStorage` 迁移一次。 | **源码确认**配置读写和迁移；配置文件没有单独的“复制/测试/删除”命令，直接改 JSON 属于手工配置，不是应用提供的管理工作流。桌面端文件为 `llm-service/profiles.json`，移动端为 `llm_profiles.json`，不是同一文件。 |
| CLI | 根 `package.json` 的脚本是构建、检查、测试、文档和 Tauri 启动等开发命令；本次在根脚本、`scripts/` 和渠道相关源码中未找到读取/新增/编辑/复制/启停/删除/导入/导出/连接测试 Profile 的 CLI 命令。 | **本次未找到**渠道管理 CLI；不能据此断言仓库未来版本或外部脚本不存在。`scripts/version.ts` 等 `process.argv` 使用属于构建/版本脚本，不是渠道管理入口。 |
| TUI | 未找到 Ink、Blessed 或其他终端 UI 渠道列表/编辑器，也未找到 Profile 专用 TUI 命令。 | **本次未找到** TUI 渠道管理入口。 |
| Web | 代码使用 Vue 页面，但其桌面管理页依赖 Tauri 文件对话框和 Tauri FS 插件导出；未找到独立 Web 服务、HTTP 配置 API 或浏览器部署版的渠道管理页。 | **静态推断**当前 `src/` 页面属于桌面 Tauri WebView，不应把它概括为可远程访问的 Web 管理端；未启动浏览器或 Tauri 验证实际可达性。 |
| 桌面端 | 完整支持查看、新建、编辑、启停、删除、排序、配置导入、渠道包导出、模型列表获取、模型/Key/能力探测，以及模型级和批量协议路由绑定。侧边栏显示名称、渠道类型和模型数，编辑器显示当前 Profile 的完整配置。 | **源码确认**入口和事件绑定见 `src/views/Settings/llm-service/LlmServiceSettings.vue`、`components/ModelRoutingEditor.vue` 与 `BatchRouteBindingDialog.vue`；保存成功、文件对话框和真实请求结果本次未运行验证。 |
| 移动端 | 独立设置页支持查看、新建、预设创建、编辑、显式保存、启停、删除、请求头/端点/模型编辑、模型列表获取和模型/批量探测。 | **源码确认** UI 和 Store 事件绑定见 `mobile/src/tools/llm-api/views/LlmSettingsView.vue:31-100,115-179`、`mobile/src/tools/llm-api/components/ProfileEditor.vue:106-149,346-665`；本次未找到移动端渠道包导入、导出或复制入口。 |

配置文件层和 UI 层的“删除”语义也不同：桌面端删除调用 Profile Store 的 `deleteProfile` 后保存整个列表；移动端删除同时把选中 ID 指向列表首项或清空。两端都没有发现删除关联 Agent、会话历史或 Key 健康状态的级联清理代码；历史消息保留实际渠道快照的行为仍由聊天链路负责，不能推断删除会清理历史引用（`src/composables/useLlmProfiles.ts:212-232`、`mobile/src/tools/llm-api/stores/llmProfiles.ts:106-112`）。

### 2.2 已有渠道与新建渠道的操作差异

桌面端新建有三条路径。空白创建生成新的 ID、默认 OpenAI 地址、启用状态、空模型列表和默认请求头；预设创建复制预设的 Provider、地址、默认模型、图标、端点和默认请求头；配置导入可以一次生成多个候选渠道。空白和预设创建后都会立即调用 `saveCurrentProfile`，所以新渠道先以可编辑对象落盘，再由表单变化触发后续自动保存（`src/views/Settings/llm-service/composables/useProfileEditor.ts:137-168`）。

已有桌面渠道被选中时，编辑器先深拷贝 Profile 到 `editForm`，避免输入过程直接修改列表对象；表单深度变化后等待 1 秒调用 `saveCurrentProfile`，而 API Key 输入框在失焦时才把逗号/换行文本拆成数组。因而“已有渠道编辑”是编辑副本加防抖保存，“新建渠道”是先保存初始对象再进入同一编辑流程（`useProfileEditor.ts:127-135,184-203`）。删除和启停直接作用于已存在 Profile；启停只翻转 `enabled` 并保存，不创建新的运行时实例。

桌面端没有看到独立的“复制渠道”按钮。复制效果存在于两条间接路径：导入一个带 `sourceProfile` 的候选时，如果 ID 冲突会生成新 ID，并把名称改为“副本”加序号；从已存在渠道打开“配置导入”时，导入草稿覆盖当前编辑副本，保留当前 ID，属于编辑/合并而不是复制。原生渠道包导入也会在 ID 冲突时按创建逻辑生成副本；因此应将“导入冲突复制”与“用户点击复制”区分记录（`LlmServiceSettings.vue:318-367,373-463`）。

桌面端已有渠道可以单独或批量导出，默认不包含 API Key、自定义鉴权 Header 等敏感值；勾选“包含敏感信息”才写出完整凭据。导入创建态支持多个候选批量创建，编辑态只应用一个草稿：带完整 `sourceProfile` 时替换除当前 ID 外的 Profile 数据，否则按字段合并到当前编辑表单。创建态导入会为冲突 ID 重新生成 ID，编辑态不会改变当前 ID（`src/views/Settings/llm-service/components/LlmProfileExportDialog.vue:112-171`、`LlmServiceSettings.vue:373-463`、`src/utils/llm-profile-transfer.ts:286-351`）。

移动端的新建渠道只在点击编辑器中的“保存”后进入 Store；预设和空白创建只是先构造内存中的 `editingProfile` 并打开编辑弹窗。已有渠道打开时会深拷贝到 `innerProfile`，保存事件再按 ID 判断调用 `addProfile` 或 `updateProfile`。因此移动端与桌面端的差异是：桌面端新建立即落盘并自动保存，移动端新建需要显式保存；移动端已有渠道也没有桌面端的 1 秒自动保存。移动端源码中未找到已有渠道复制按钮、渠道包导入导出或配置文件选择器（`mobile/src/tools/llm-api/views/LlmSettingsView.vue:31-89`、`mobile/src/tools/llm-api/components/ProfileEditor.vue:92-113`）。

### 2.3 查看、启停、模型获取与连接测试

“查看”在桌面端是侧边栏选择后展开完整 Profile 编辑器，在移动端是点击卡片后打开全屏编辑弹窗。两者都显示启用状态、地址和模型数量；桌面端还在列表中提供排序，移动端虽保留管理模式和多选状态字段，但当前设置页没有发现进入管理模式的按钮或批量动作绑定，因此**静态代码只能确认状态结构，不能确认批量管理入口可达**（`src/views/Settings/shared/ProfileSidebar.vue:1-150`、`mobile/src/tools/llm-api/views/LlmSettingsView.vue:20-22,102-108,146-161`）。

启停都是 Profile 级 `enabled` 字段，不是 Key 或单模型状态。桌面端普通请求会检查该字段，但设置页探测可以对当前编辑中的禁用渠道发起探测；移动端卡片开关直接调用 `updateProfile`。两端都没有发现“暂停后删除凭据”或“停用后禁止查看/编辑”的逻辑，已有渠道停用后仍可打开和修改。

连接测试不是一个单一的健康字段，而是设置页的独立探测路径。桌面端“检查模型列表”调用 `channel-probe-service` 的 `model-list` 探测；模型编辑区可按模型、端点、流式模式和媒体成本确认执行推理探测，也可批量探测；Key 管理器可指定某个 Key 和模型测试，并把结果反馈给 Key 健康状态。探测若确认某个模型只有一种可用协议，可生成路由应用候选，由用户选择后写入模型绑定；模型列表返回的端点声明也可形成批量绑定候选。探测结果不会未经确认自动改变生产路由（`src/views/Settings/llm-service/probe/route-application.ts:1-58`、`components/ModelProbeDialog.vue:129-157,589-604`）。移动端编辑器提供模型列表获取、模型探测和批量探测，但本次未找到桌面端这套路由应用 UI。探测结果包含分类、耗时和响应摘要，不能据此推断真实聊天请求一定成功。

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

除上述解析式导入外，还有**原生渠道导入导出**——`src/utils/llm-profile-transfer.ts` 定义 `LlmProfileBundle` 序列化格式，导出对话框（`LlmProfileExportDialog.vue`）支持搜索、多选、单渠道/批量导出，敏感信息自动检测与脱敏（导出时可选择是否包含凭据），导入时无损保留网络策略、自定义端点等完整配置（提交 `17ed5f04b`）；JSON 解析器新增 New API“复制连接信息”格式（`_type: "newapi_channel_conn"` → OpenAI-Compatible 渠道候选，无效 URL 校验且密钥不进入警告日志，提交 `8ddbbedfa`）。

### 2.6 明文配置文件

`useLlmProfiles` 使用 `createConfigManager` 将全部 Profile 保存到应用配置目录下的：

```text
llm-service/profiles.json
```

`ConfigManager.save()` 直接对对象执行 `JSON.stringify()` 并通过 Tauri FS 写文本文件，没有调用系统 Keychain、Stronghold 或字段级加密。因而 `apiKeys[]`、自定义鉴权 Header 和 Provider `options` 中的敏感值均以可读 JSON 落盘。

Key 健康状态另存于：

```text
llm-service/key-states.json
```

该文件以完整 Key 字符串作为状态 Map 的键，所以即使未来只加密 `profiles.json`，当前健康状态文件仍会重复暴露凭据。日志只展示 Key 前 8 位，但配置文件不是脱敏存储。

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
- 模型身份与 Embedding 空间分离，为模型目录引入 canonical ID 概念，当前主要被 knowledge-base 的向量化空间消费；桌面渠道目录仍以模型快照为主。相关实现位于 `packages/llm-core/src/model-identity/`。

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

另一套是 [`src/types/model-metadata.ts`](../../aio-hub/src/types/model-metadata.ts) 定义的 `ModelMetadataRule`。规则属性是开放对象，内置支持图标、Tokenizer、分组、能力、上下文、价格、描述、推荐用途、版本、发布日期、特性和媒体生成参数。它不是另一张模型目录，而是对任意 Provider/模型 ID 应用的声明式补丁层。

### 3.4 规则匹配与覆盖顺序

[`src/config/model-metadata.ts`](../../aio-hub/src/config/model-metadata.ts) 支持四种匹配类型：

- `provider`：Provider ID 不区分大小写的精确匹配；
- `model`：默认区分大小写的精确匹配，也可改用正则；
- `modelPrefix`：名称虽叫 Prefix，非正则模式实际是对完整模型 ID 做不区分大小写的 `includes`；
- `modelGroup`：已废弃，不参与匹配。

启用规则先按优先级从高到低排序。若命中独占规则，只保留优先级不低于最高独占规则的匹配项；随后按低优先级到高优先级深合并，所以高优先级字段最终覆盖低优先级字段，而不同规则中的嵌套能力可以累积。

内置规则按能力、Provider、模型家族、特定模型、图像/视频生成参数和图片输入限制分模块维护，汇总入口是 [`src/config/model-metadata-presets/index.ts`](../../aio-hub/src/config/model-metadata-presets/index.ts)。用户规则由 [`src/stores/modelMetadataStore.ts`](../../aio-hub/src/stores/modelMetadataStore.ts) 保存到 `model-metadata/metadata-rules.json`，并可从旧版 `localStorage` 的 `model-icon-configs` 迁移。

升级时“合并内置”只按规则 ID 添加缺失项，不覆盖已有同 ID 规则。这能保留用户修改，但也意味着已落盘的旧内置规则不会自动吸收同 ID 的字段修订；需要重置或人工调整才能完全追上新版预设。

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

关于这项能力在项目分类中的边界，以及与其他项目的横向核对，见[模型元数据规则可配置边界研究](../独特功能/模型元数据规则可配置边界研究.md)。

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
7. 成功或失败后按错误分类更新 Key 健康状态（见第 5 节），并把响应或异常交还调用方。

路由是确定性的，没有读取 Profile 顺序、权重、延迟、剩余额度或价格来改选渠道——模型执行路由只做**渠道内的协议/端点选择**，不跨渠道改选。

## 5. 多 Key 轮询与熔断

Key 管理器为每条 Profile 保存以下状态，入口见 `src/composables/useLlmKeyManager.ts`：

- 每个 Key 的手动启用状态；
- `isBroken`、连续错误次数和最近错误；
- 最近使用、失败和熔断时间；
- Profile 上次选择的 Key 下标；
- **按 Profile 隔离的开关与恢复设置**（`profileSettings`）——`enableAutoDisable`（默认 `false`）与 `autoRecoveryTime`（默认 60 秒）从旧版全局字段迁到每个 Profile 独立配置；存储版本升至 `1.1.0`，旧全局设置无法无歧义映射到具体渠道，迁移时丢弃并让各渠道按新默认值重新显式启用（`normalizeKeyStatesStorage`，提交 `5cb13afed`/`3ac5e99bf`）。

### 5.1 选择策略

Key 选择逻辑先过滤手动禁用和已熔断项，再从上次下标之后轮询。默认自动恢复时间为 60 秒；到期的熔断项会被恢复并重新参与选择，入口是 `pickKey()`。

**“全部不可用回退第一个 Key”已移除**——没有可用 Key 时区分“全部被用户禁用”和“全部熔断”两种原因，并抛出 `ApiKeyUnavailableError`；后者附最早可恢复时间 `retryAt`，不再把请求打到已知坏 Key 上（提交 `54b528984`）。

### 5.2 失败判定

普通业务请求的错误处理已接入分类策略：请求入口调用错误分类策略，把错误分为五类动作；具体实现见 `src/llm-apis/key-health-policy.ts`，并复用 llm-core 的 `classifyProbeError`：

- `authentication-failure` → 认证失败强制标坏；
- `rate-limit-failure` → 429/限流立即熔断（沿用旧的即时熔断规则）；
- `transient-failure` → 按连续错误累计；
- `record-only` → 只记录，不计数也不自动禁用；
- `success`/`ignore` → 无操作。

旧的“429 立即熔断、其他错误累计 3 次熔断、成功清零”计数规则仍保留，但自动熔断现在多一个前提：**同渠道还有其他可用 Key**，且该 Profile 开启了自动禁用；最后一个可用 Key 不会因连续失败被自动熔断。设置页探测与普通请求共用同一份策略文件。

### 5.3 没有请求内换 Key 重试

一次发送只选择一次 Key 并调用一次 Adapter；失败后分类记录健康状态并立即把错误交还调用方。它不会在同一请求中：

- 换下一个 Key 重放；
- 判断流是否已经输出部分内容；
- 对 429/5xx 做退避；
- 切换到另一条 Profile。

因此这里的“负载均衡”更准确地说是跨请求的 Key 轮询；“熔断”也是影响后续请求的状态管理，不是当前请求的高可用恢复。

## 6. Provider Adapter 与协议边界

`src/llm-apis/adapters/index.ts` 定义应用层 `LlmAdapter`，能力方法包括 `chat`、`embedding`、`image`、`audio`、`video` 和可选的 `transcribe`。具体实现逐步下沉到 `packages/llm-core`：

- OpenAI-Compatible Chat Completions；
- OpenAI Responses；
- Anthropic Messages；
- Gemini / Vertex GenerateContent；
- Cohere Chat V2；
- Embedding、Rerank、模型列表和异步媒体任务；
- OpenAI/Whisper 风格的 multipart 语音转写。

共享 Core 使用 canonical request/response 和 `ProviderAdapter`，负责请求体、URL、Header、流式 Decoder 与 Provider 语义；它不读取 Vue Store，也不持有 Key 状态。桌面和移动端各自负责把 Profile 变成 Core DTO，并注入平台 Transport。

这个边界让协议兼容可以跨端复用，同时把系统代理、无效证书、本地文件流上传等平台行为留在 Rust/桌面 Transport。

Provider 层的原生工具调用编解码已修补（提交 `27e899483`）——统一 `LlmMessage` 契约支持 `tool` 角色、`toolCallId`、`metadata` 与工具名；OpenAI Chat/Responses 补齐 assistant `tool_calls` 与 tool 结果续轮编码，Gemini 保留函数调用 ID（流式聚合不再覆盖真实 ID），Cohere 支持 assistant 工具调用与并行 tool 结果编码；Ollama 切换 OpenAI 兼容端点并声明 `tools`/`toolChoice` 能力。OpenAI Responses 新增推理摘要解析并保持流式边界（`edf251a9c`）。LLM Inspector 增加基于最终请求体的原生工具声明/解码诊断（`src/llm-apis/tool-diagnostics.ts`）。这些修补为后续原生工具编排（区别于 VCP 文本协议）打基础，但模型通信层的工具协议仍以 VCP 为准（见 Agent 工具笔记第 3 节）。

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
- 错误分类：认证、授权、限流、模型不可用、参数、网络、超时、Provider 等。

LLM Inspector 可在统一请求/Transport 入口关联 `requestId`，捕获请求、响应头、流式块和错误上下文。请求分发时会把 `channelType`/`effectiveAdapterId`/`executionOperation`/`routeSource` 写入 Inspector 上下文，工具意图（`toolDiagnostics`：adapterId、requestToolCount、hasNativeTools）在能力过滤后记录、响应返回后以最终请求体解码结果覆写（`useLlmRequest.ts`、`tool-diagnostics.ts`）。它改善单渠道诊断，但结果不会进入自动渠道评分或动态路由。

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
- 没有当前请求内 Key 重试；
- 没有跨渠道 failover；
- 没有加密或系统凭据库；
- `auto` 网络策略不是自动择优；
- 模型列表请求固定走代理；
- 设置页可见 Provider 与运行时 Adapter 的单一注册源约束已通过 `defineAdapters<Record<LlmProviderType, LlmAdapter>>` 建立。
- 未找到面向渠道管理的 CLI、TUI、独立 Web 服务或 HTTP 配置 API；这表示本次调查范围内没有这些管理入口，不等于外部脚本或未来版本绝对不存在。

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
- 配置导入：[`src/utils/llm-config-import`](../../aio-hub/src/utils/llm-config-import)
- 移动端 Profile Store：[`mobile/src/tools/llm-api/stores/llmProfiles.ts`](../../aio-hub/mobile/src/tools/llm-api/stores/llmProfiles.ts)
- 移动端渠道设置页与编辑器：[`mobile/src/tools/llm-api/views/LlmSettingsView.vue`](../../aio-hub/mobile/src/tools/llm-api/views/LlmSettingsView.vue)、[`mobile/src/tools/llm-api/components/ProfileEditor.vue`](../../aio-hub/mobile/src/tools/llm-api/components/ProfileEditor.vue)
- Agent 运行时选择：[`src/tools/llm-chat/composables/chat/useChatExecutor.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useChatExecutor.ts)

## 12. 未验证事项

1. 本次未启动 Tauri 桌面端，没有实测官方 Provider、自建网关和代理模式下的 TLS/HTTP 行为。
2. 未检查真实用户配置目录的文件 ACL；“明文落盘”基于序列化与写入实现，不等于配置文件一定对其他系统账户可读。
3. 未实测 Azure 渠道的真实调用。
4. 未启动移动端 Tauri/Android 运行态；移动端配置文件路径、保存成功、真实模型探测和平台文件权限均为源码确认或静态推断，未做设备实测。
5. Suno、MiniMax 等异步媒体任务自身可能有任务轮询重试；它们不等于 LLM Chat 的 Key/渠道故障转移，本次未逐项展开。
6. 未运行桌面端或移动端 UI，因此桌面文件选择器、导出文件实际内容、导入后的提示/错误、移动端弹窗保存和探测结果展示均未验证；Web、CLI、TUI 的“未找到”结论也未覆盖仓库外部脚本或未来构建产物。
