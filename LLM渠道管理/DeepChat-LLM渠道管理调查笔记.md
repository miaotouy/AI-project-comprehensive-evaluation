# DeepChat LLM 渠道管理调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7f3379524da3ac629918d35682e38833ad5c203e`（分支：`dev`）
>
> 调查方式：只读源码、CLI 指南和路由契约梳理 Provider 配置生命周期、桌面端管理入口、CLI 管理面、配置导入、模型目录和连接测试；未修改 DeepChat 仓库，也未运行桌面 UI、CLI 或真实 API 请求
>
> 调查范围：配置存储、默认渠道与用户渠道、桌面端和 CLI 的查看/新增/编辑/复制/启停/删除/导入/导出/连接测试、TUI/Web 边界、模型目录、凭据、协议适配、运行时选择、限流和故障处理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 中的“渠道”主要是持久化的 `LLM_PROVIDER` 用户实例。默认 Provider 是应用内置的配置模板和注册表条目；用户可以新增 `custom: true` 的实例，也可以修改已有 Provider 的部分字段。运行时再依据 Provider 的 `id`、`apiType`、凭据和模型配置创建具体连接实例。

1. **桌面端是完整管理入口**：设置页可以查看 Provider 列表和详情，新增自定义 Provider，编辑名称、API Key、部分 Base URL，启停、排序、删除自定义 Provider，刷新模型、启停模型和编辑模型配置。源码没有找到 Provider 复制按钮或 Provider 导出入口。
2. **CLI 是本地控制面，不是独立配置编辑器**：`provider list/test/add/update/set-credential/clear-credential/remove` 已实现。CLI 依赖正在运行的 DeepChat main 进程，公共返回值脱敏，凭据通过 stdin 写入 main。CLI 没有 Provider 导入、导出、复制或专门的 enable/disable 命令，启停通过 `provider update --enabled` 完成。
3. **TUI 不适用，远程 Web 管理未找到**：CLI V1 文档明确把 TUI/交互 shell 列为不包含能力；本次在 `src`、CLI surface 和文档中未找到独立 Web server 或浏览器端 Provider 管理 API。桌面 renderer 使用 Vue，但它属于 Electron 桌面端，不单列为远程 Web 前端。
4. **导入是桌面设置页的数据迁移向导**：Provider import service 从 CC Switch、Alma、Cherry Studio、Hermes、OpenClaw 的本地数据中扫描配置，先预览和映射，再按选择创建或更新内置/自定义 Provider，并导入模型。它不是通用的 DeepChat Provider 导出/导入文件格式。
5. **默认渠道与用户渠道的可操作范围不同**：默认 Provider 会参与初始化合并；内置 Provider 通常保留身份和协议，只允许修改凭据、启停及特定可编辑字段。自定义 Provider 可编辑 Base URL，并可从桌面端删除。CLI 还显式禁止修改内置 Provider 的 `apiType`，只允许删除自定义 Provider。
6. **渠道请求可附加用户配置 Header**：Header 作为独立的 Provider 配置契约进入请求组装；APIMart、Synthorai 与 OpenAI Codex 图像生成均有 Provider 接线，模型目录和能力判断不能只按早期内置 Provider 集合理解（`src/main/provider/providerHeaders.ts`、`providers/apimartProvider.ts`、`openaiCodexAdapter.ts`）。

## 1. Provider、渠道与 Endpoint 数据模型

`LLM_PROVIDER`（`src/shared/types/provider.ts:74-106`）是渠道实例的主要数据结构，包含 `id`、名称、`apiType`、API Key/OAuth token、`baseUrl`、模型集合、模型启停状态、`enable`、`custom`、网站信息和限流配置等。`provider.id + modelId` 构成运行时选择的基本身份；同名模型在不同 Provider 下可以对应不同 Base URL、凭据和能力。

Provider 不是单纯的代码注册项，也不是每次请求临时创建的连接。`ProviderSettings` 持有用户配置，`ProviderInstanceManager` 按 Provider ID 创建并缓存 `BaseLLMProvider` 实例；配置变化时通过 Provider change event 触发实例更新或重建（`src/main/provider/managers/providerInstanceManager.ts:31-207`）。

一个 Provider 实例只有一个持久化 `baseUrl` 字段，本次未找到在同一个 `LLM_PROVIDER` 内维护多个 Endpoint 或 Endpoint 列表的模型。若要使用同一协议的多个地址，实际做法是创建多个 Provider 实例；它们可以共享同一 `apiType`，但各自保存自己的 URL 和凭据。

## 2. 配置存储、初始化与生命周期

### 2.1 存储边界

源码显示 Provider 配置存在两条相互协作的存储路径：

- 传统/运行时设置路径使用 Electron Store 的 `providers` 键，`ProviderHelper` 通过 `getSetting`/`setSetting` 读写完整 Provider 数组（`src/main/provider/providerHelper.ts:18-51`、`:169-244`）。
- 当前 Provider 数据库使用 SQLite 的 `providers` 表，同时保存 `id`、名称、`api_type`、`api_key`、`base_url`、启用标记、custom 标记、排序、最后使用时间和 `provider_json`；删除时还级联清理 Provider 模型、模型状态和模型配置（`src/main/provider/data/settingsTable.ts:156-223`）。

因此，“配置文件”在源码层面不是一个用户可直接编辑的 `providers.json`。Provider 的主配置由 Electron Store/SQLite-backed settings 管理，Provider DB 模型目录另有本地缓存目录；本次未找到面向用户的 YAML/TOML/JSON Provider 配置编辑文件。

### 2.2 默认配置与用户配置合并

`ProviderSettings` 初始化时连接 settings store 和 Provider database，执行旧配置迁移、清理 deprecated Provider，并将新增默认 Provider 合并到已有配置（`src/main/provider/settings.ts:322-412`）。`getDefaultProviders` 单独返回默认渠道，用于 UI 展示默认网站、默认 Base URL 等元数据；当前用户 Provider 列表则由 `getProviders` 返回。

新增自定义 Provider 时，桌面端生成 `nanoid` ID，设置 `custom: true`，然后调用 `addProviderAtomic`。更新、添加、删除和排序都会发布 Provider change event，renderer 的 `providerStore` 收到事件后刷新列表。

### 2.3 配置操作矩阵

下表表示**源码入口已找到的可达能力**。静态源码只能确认入口、参数和事件绑定，保存成功后的实际 UI 体验仍未运行验证。

| 操作 | 配置/底层 | 桌面端 renderer | CLI | TUI | 远程 Web |
|---|---|---|---|---|---|
| 查看 | `providers.list`、`providers.listSummaries`、`providers.listDefaults` | 设置页列表、详情和模型页 | `provider list`，返回脱敏公共 DTO | 不适用：CLI V1 明确不含 TUI | 未找到独立 Web 管理入口 |
| 新增 | `providers.add`；CLI 另有 `providers.addPublic` | `AddCustomProviderDialog`，填写名称、apiType、API Key、Base URL、启用状态 | `provider add`，只能新增无凭据 custom Provider，凭据另行设置 | 不适用 | 未找到 |
| 编辑 | `providers.update`、`providers.setById` | 可改名称；API Key 和部分 Base URL；Provider 专属高级配置 | `provider update` 可改名称、apiType、Base URL、enabled；内置 Provider 的 apiType 被拒绝 | 不适用 | 未找到 |
| 复制 | 未找到 Provider clone/duplicate route | 未找到复制按钮或复制流程 | 未找到复制命令 | 不适用 | 未找到 |
| 启停 | 更新 `enable` 字段；更新会按字段判断是否需要重建实例 | Provider 列表 Switch；启用/禁用后调整排序和打开详情 | 没有独立命令；`provider update --enabled true/false` 可完成 | 不适用 | 未找到 |
| 删除 | `providers.remove`，并清理模型状态/模型存储 | 详情页仅 custom Provider 显示删除按钮，确认后删除 | `provider remove`，CLI 路径只允许 custom Provider | 不适用 | 未找到 |
| 导入 | `providers.import.scan/apply`；无通用 DeepChat 导入文件契约 | 数据设置页的扫描、来源选择、Provider 选择、冲突预览和应用向导 | 未找到 Provider import 命令 | 不适用 | 未找到 |
| 导出 | 仅找到模型配置 `models.exportConfigs`，未找到 Provider 导出 | 未找到 Provider 导出入口 | 未找到 Provider export 命令 | 不适用 | 未找到 |
| 连接测试 | `providers.testConnection`，可选 modelId | “验证 API Key”打开模型检查流程；部分 Provider OAuth 成功后自动验证 | `provider test`，5 秒 CLI 公共测试超时 | 不适用 | 未找到 |
| 模型刷新 | `providers.refreshModels`、模型目录和 custom model route | 连接页和模型页都有刷新模型入口 | CLI Provider surface 未暴露 refresh models；可用 `model list` 查看运行时模型 | 不适用 | 未找到 |

### 2.4 已有渠道与新建渠道

已有内置 Provider 和新建 custom Provider 共用 Provider 列表、模型管理、启停、连接测试和运行时实例机制，但字段可编辑性不同：

- 桌面端通过 `EDITABLE_BASE_URL_PROVIDER_IDS` 和 `provider.custom` 决定 Base URL 是否直接可编辑；非列表内置 Provider 默认锁定 Base URL，用户可以在 UI 中点击解锁，但本次未验证解锁后的保存行为。
- 删除按钮只在 `provider.custom` 时渲染。底层 route 对 renderer caller 没有同样的 custom 检查，但 UI 入口没有提供内置 Provider 删除；CLI route 则明确拒绝删除内置 Provider。
- 新增对话框只创建 custom Provider，apiType 选项包含 OpenAI、OpenAI Completions、Gemini、Anthropic、Ollama、Mistral；Ollama 可不填 API Key，并默认 Base URL 为 `http://localhost:11434`。
- 内置 Provider 可能拥有 OAuth、专用凭据、Provider DB 元数据和特殊高级设置；新建 custom Provider 不自动获得这些内置身份能力，只按所选 `apiType` 进入通用 runtime。

## 3. 配置入口的具体行为

### 3.1 桌面端

Provider 设置路由是 `settings-provider`，主界面左侧按启用/禁用分组显示 Provider，支持搜索和拖拽排序。点击 Provider 后进入连接、模型、advanced 三个页签（`src/renderer/settings/components/ModelProviderSettings.vue:24-247`、`ProviderSettingsShell.vue:21-55`）。

连接页可以编辑 API Key，密码输入默认脱敏但有显示切换；自定义 Provider 可以删除；部分内置 Provider 提供 OAuth 登录组件。Base URL 的变更通常在 blur 或 Enter 时写入 `updateProviderApi`，API Key 也在 blur 时写入（`src/renderer/settings/components/ProviderApiConfig.vue:15-55`、`:120-203`、`:341-370`）。

模型页区分 Provider 模型和 custom model。模型可以单独启停，禁用模型需要确认；模型列表支持刷新，模型能力配置由相邻的模型配置入口维护。Provider 详情的“验证”调用 `providerStore.checkProvider`，成功后刷新该 Provider 的模型列表（`src/renderer/settings/components/ModelProviderSettingsDetail.vue:217-243`、`:361-403`）。

Provider import 位于数据设置页而非 Provider 详情页。向导先扫描来源，再按来源查看 Provider 预览，显示脱敏 API Key、Base URL、模型数量、目标内置/自定义类型和警告，最后应用选择并显示 created/updated/skipped/overwritten 结果。

### 3.2 CLI

CLI 是随桌面应用提供的本地 thin client。DeepChat 启动时自动启动 control plane；DeepChat 未运行时命令返回 unavailable，CLI 不持有 Provider 状态（`docs/guides/cli.md:1-20`）。命令和参数由 `src/cli/args.ts:234-240` 定义：

```text
deepchat provider list [--enabled-only] [--json]
deepchat provider test --provider <id> [--model <id>]
deepchat provider add --name <name> --api-type <type> --base-url <url>
deepchat provider update --provider <id> [--name ...] [--api-type ...] [--base-url ...] [--enabled ...]
deepchat provider set-credential --provider <id> --stdin
deepchat provider clear-credential --provider <id>
deepchat provider remove --provider <id>
```

CLI 的公共 Provider DTO 只返回 Provider ID、名称、apiType、启用状态、custom 标记、是否已配置凭据和模型摘要，不返回 API Key。`provider add` 先创建空凭据 custom Provider；`set-credential` 单独从 stdin 接收 API Key。CLI surface 将新增、编辑、凭据和删除分别标为需要 policy approval 的 mutation，连接测试是 human-only 的 compute 操作（`src/main/cli/surface.ts:603-670`）。

CLI 不是桌面端所有操作的镜像：它不暴露 Provider import/export、复制、模型刷新、Provider 排序、OAuth 登录、Provider 专属高级字段或任意配置读写。模型启停和模型配置有独立的 `model` 命令域。

### 3.3 TUI 与 Web

- **TUI：不适用/源码确认未包含**。CLI 指南在 V1 明确列出“ TUI/交互 shell”不包含在能力范围内（`docs/guides/cli.md:251-257`）。本次未找到 Provider TUI 页面或交互命令。
- **远程 Web：未找到**。本次检查了 `src/renderer`、`src/main/cli`、route contracts 和文档，找到的是 Electron renderer 通过 preload/IPC 访问 main 的桌面设置页，没有找到独立 HTTP Web 管理服务或远程 Provider 管理 API。浏览器视觉、网络监听和跨平台部署未运行验证，因此该结论限定为“本次源码范围未找到”。

## 4. 凭据、Header 与代理边界

普通 Provider 的 API Key、Base URL 和 Provider JSON 会写入 settings store/SQLite Provider 表；`settingsTable.ts` 的 `api_key` 列和 INSERT/UPDATE 参数显示普通 API Key 明文作为数据库字段保存。数据库依赖 `better-sqlite3-multiple-ciphers`，但本次未确认运行时数据库密钥配置以及普通 API Key 是否由数据库层加密。

OpenAI Codex 和 xAI Grok OAuth 使用独立 credential store，并通过 Electron `safeStorage` 加密；不可用时存在 file storage fallback（`src/main/provider/auth/openaiCodex/credentialStore.ts:22-43` 及 xAI 对应实现）。AWS Bedrock credential 另由 settings store 的 `awsBedrockCredential` 键保存（`src/main/provider/settings.ts:962-977`）。

桌面端 API Key 输入默认是 password 类型，仅在当前表单中显示/隐藏；Provider summary、CLI 公共 DTO 和 Provider import 预览对 API Key 脱敏。导入预览使用掩码值，导入 apply 才把原始凭据写入目标 Provider。请求 trace 使用 `redact.ts` 对 authorization、api-key、token、secret、password 等字段脱敏；本次未验证导出、备份和崩溃日志是否包含普通 Provider 凭据。

请求 runtime 从 Provider definition 和 settings 取得 Base URL、凭据、默认 headers，再交给 AI SDK provider factory。HTTP(S) 代理依赖 `https-proxy-agent`，但本次未逐个 Provider 实测代理注入和自定义 Header 行为。

## 5. 模型目录与能力元数据

模型来源至少包括三类：Provider 内置/远端模型列表、Provider DB 聚合目录和用户 custom models。`BaseLLMProvider` 负责获取、缓存和写回 Provider models；`ProviderModelHelper` 与 Provider DB loader 负责本地目录和刷新。UI 通过 `providers.listModels` 同时取得 Provider models 和 custom models。

用户添加 custom model 时保存模型 ID、名称、分组和 Provider 归属，并可启停、编辑和删除。模型启停状态单独保存在 `model_status`，Provider 删除时清理相关状态和模型配置。模型配置由 `ModelConfig` 保存上下文长度、最大输出、采样参数、vision、function call、reasoning、endpoint 和媒体能力；有效配置由 Provider facts、Provider DB 和用户覆盖合并得到。

Provider 刷新模型是 Provider 级操作。Provider DB-backed Provider 在刷新时还会刷新/同步元数据；这与用户在 UI 中直接新增的 custom model 不同，后者是本地输入，不要求上游 `/models` 接口。

## 6. Adapter、协议与请求组装

`providerRegistry.ts` 将 Provider ID 优先、apiType 次之映射到 AI SDK runtime definition。definition 包含 runtime kind、behavior preset、模型来源、连通性检查、credential strategy、route strategy、embedding strategy 和默认 headers（`src/main/provider/providerRegistry.ts:50-80`、`:684-690`）。

因此，同一 OpenAI-compatible apiType 可以复用统一适配器，同时保留每个 Provider 自己的 Base URL、API Key 和模型目录。Anthropic、Gemini、OpenAI Responses、OpenAI Completions、Vertex、Bedrock、Ollama 等特殊协议在 provider factory/AI SDK provider 中组装 endpoint、headers 和协议请求体；上层 runtime 统一消息、工具、reasoning、媒体和 embedding 的调用接口。

DeepSeek 官方 Responses endpoint 的原生 Web Search 是 Provider ID、模型 ID 和官方 endpoint 三重条件下的特殊 adapter 路径；它不改变 Provider 管理数据模型。ACP 的 `apiType: acp` 走 Agent backend，不是普通聊天 Provider 的通用 AI SDK endpoint。

## 7. 运行时选择、限流、重试与故障转移

会话/Agent 层保存 Provider ID 和 model ID；请求运行时按 Provider ID 从 `ProviderInstanceManager` 取得实例，再由 registry 和 apiType 选择 adapter。源码未找到基于名称语义、成本、延迟或权重的 Provider 负载均衡器，也未找到一个 Provider 内多 API Key 轮询器。

每个 Provider 可独立配置 QPS。`RateLimitManager` 维护 Provider 级队列，按 `1 / qpsLimit` 间隔释放请求，支持排队状态、队列长度、Abort 和事件通知；这是限流，不是健康检查或 failover。

聊天 Agent loop 另有按失败分类的重试和 context recovery/fallback 逻辑。根据当前已读入口，本次未发现 Provider 层自动跨渠道 failover；模型 fallback 若发生，由 Agent/session attempt 管线驱动。重试是否导致上游重复计费取决于具体请求已经提交到上游的时机，本次未做真实请求验证。

## 8. 连接检测、日志与可观测性

桌面和普通 IPC 连接测试走 `providers.testConnection` -> `ProviderService.testConnection` -> `providerRuntime.check`，ProviderService 设置 5 秒查询超时（`src/main/provider/providerService.ts:18-61`）。如果提供 modelId，`ProviderRuntime.check` 使用真实 completions 请求发送测试消息；不提供 modelId 时使用 Provider 自己的 `check()`（`src/main/provider/index.ts:863-930`）。因此源码确认设置页连接测试复用真实 Provider 执行链，而不是 mock。

CLI 的 public connection route 再包一层 5 秒 scheduler timeout，并把失败统一返回为 `isOk: false, errorMsg: 'Provider connection failed'`，不向 CLI 暴露内部错误（`src/main/cli/providerModelAdminRoutes.ts:119-140`）。桌面端 IPC route 则返回 ProviderService 的 `{ isOk, errorMsg }`。

Provider change、模型变化、限流排队/执行和 Provider DB 刷新通过 typed events 通知 renderer。Provider 请求 trace 可记录 Provider ID、模型、endpoint、headers/body 摘要和 logical round，经脱敏后是否落盘由调用方注入的 trace context 决定。源码中未找到统一的跨 Provider 成本、延迟和用量看板；部分渠道有独立 key status 查询，UI 可显示 usage 或剩余额度，但不是所有 Provider 都有。

## 9. 导入来源与冲突处理

`ProviderImportService` 当前扫描以下本地来源：

- CC Switch：SQLite `cc-switch.db`，并解析 Claude、Gemini、OpenCode、OpenClaw、Hermes 配置；
- Alma：SQLite `providers` 表；
- Cherry Studio：LevelDB 中的 `persist:cherry-studio` 数据；
- Hermes：`~/.hermes/config.yaml`；
- OpenClaw：`~/.openclaw/gateway.yaml`。

扫描结果区分 `found`、`not_found`、`error`、`unsupported_platform`，Provider 预览包括来源 ID、目标 Provider、掩码凭据、Base URL、模型预览、是否已配置和警告。映射优先尝试 Base URL/provider alias 命中已有内置 Provider；OpenAI-compatible 且未命中内置渠道时规划为 custom Provider。应用阶段以目标 Provider 为单位合并，结果可以是 created、updated、skipped 或 overwritten；同一目标的后选项会覆盖先前规划项，扫描 session 10 分钟后过期。

导入已有内置 Provider 时通常会写入凭据、Base URL、启用状态和来源模型；某些 CC Switch 协议不匹配的内置渠道采用 `credentials_only`，保留当前 Base URL 和模型配置。导入 custom Provider 时按 Base URL + API Key 指纹复用已有 custom Provider，否则生成唯一 ID，并将来源模型作为 custom models 添加。

## 10. 设计取舍与已确认边界

- Provider 身份、模型目录/能力和请求 runtime 分层，允许多个 Provider 共享协议适配而保留独立 endpoint/key。
- 默认 Provider 作为应用内置能力和元数据来源，用户配置作为可变状态；默认渠道不能简单等同于当前已配置渠道。
- Provider 级 QPS 队列解决单渠道节流，但源码未显示健康权重、成本路由或多 Key 轮换。
- 普通 Provider API Key 在 Provider settings/SQLite 字段中可见于 main 侧持久化对象；前端展示、CLI DTO、导入预览和 trace 使用脱敏或不返回原值。OAuth 凭据有单独 safeStorage 路径。
- “支持导入”是桌面端从外部应用本地数据迁移的能力；本次未找到对称的 Provider export，因此不能据此推断用户可以从 DeepChat 导出完整渠道配置。
- 底层 `providers.remove` 对 renderer caller 没有内置/custom 限制，但当前桌面删除按钮只对 custom Provider 显示；CLI 路径明确增加了内置 Provider 拒删校验。这是不同管理入口的行为差异。

## 11. 未验证事项

- 未运行 Electron 设置页，未验证表单 blur 保存、Base URL 解锁、删除确认、导入应用后的刷新和错误提示在实际平台上的行为。
- 未运行 CLI，未验证 DeepChat 未启动、approval pending、权限失败、超时和退出码在当前打包版本中的实际表现。
- 未运行 TUI 或远程 Web，因为源码和 CLI 文档显示 TUI 不包含，且本次未找到独立 Web 管理服务；这不是对所有未来分支或外部集成的绝对否定。
- 未执行真实 Provider 连接测试，未逐渠道验证 endpoint suffix、默认 headers、代理、OAuth、模型刷新、媒体和 embedding 的上游兼容性。
- 未确认 Electron Store 的底层文件位置、SQLite 数据库加密 key、备份/同步/导出文件中的凭据处理，也未运行数据库迁移。
- 未验证 Provider 删除时已有 session/provider 引用如何恢复，以及 Provider 实例、限流队列和正在进行请求在删除/禁用时的边界行为。
- 未找到 Provider 复制、Provider 导出、CLI Provider 导入和 CLI Provider 导出实现；仅找到模型配置的导入/导出 route，不能把它们扩大解释为渠道配置导入/导出。

## 12. 关键源码索引

- Provider 类型与模型配置：`src/shared/types/provider.ts:74-106`、`:370-413`
- Provider 设置初始化与默认合并：`src/main/provider/settings.ts:322-412`
- Provider helper CRUD/排序：`src/main/provider/providerHelper.ts:154-244`
- SQLite Provider 表 CRUD：`src/main/provider/data/settingsTable.ts:156-223`
- Provider route contracts：`src/shared/contracts/routes/providers.routes.ts:79-124`、`:182-275`、`:429-515`
- 桌面 Provider store：`src/renderer/src/stores/providerStore.ts:150-278`
- 桌面 Provider 列表与新增入口：`src/renderer/settings/components/ModelProviderSettings.vue:24-247`、`:764-799`
- 桌面连接配置与删除按钮：`src/renderer/settings/components/ProviderApiConfig.vue:15-55`、`:120-203`
- 桌面连接测试、模型管理和删除：`src/renderer/settings/components/ModelProviderSettingsDetail.vue:217-243`、`:361-445`
- Provider 导入数据模型与 service：`src/shared/providerImport.ts`、`src/main/provider/providerImportService.ts:48-83`、`:375-513`、`:1033-1457`
- Provider import 桌面向导：`src/renderer/settings/components/ProviderConfigImportDialog.vue:32-417`、`:645-807`
- CLI 命令定义：`src/cli/args.ts:234-240`、`:598-712`
- CLI Provider 管理 route：`src/main/cli/providerModelAdminRoutes.ts:119-287`
- CLI surface 权限与操作边界：`src/main/cli/surface.ts:603-670`
- CLI V1 能力边界：`docs/guides/cli.md:1-20`、`:76-93`、`:251-257`
- Provider registry 与实例路由：`src/main/provider/providerRegistry.ts:50-80`、`:684-690`、`src/main/provider/managers/providerInstanceManager.ts:31-207`
- 连接测试：`src/main/provider/providerService.ts:18-61`、`src/main/provider/index.ts:863-930`
- QPS 限流：`src/main/provider/managers/rateLimitManager.ts:24-190`、`:284-385`
- 凭据与脱敏：`src/main/provider/auth/openaiCodex/credentialStore.ts:22-43`、`src/main/provider/data/settingsTable.ts:168-199`、`src/main/lib/redact.ts:4-40`
