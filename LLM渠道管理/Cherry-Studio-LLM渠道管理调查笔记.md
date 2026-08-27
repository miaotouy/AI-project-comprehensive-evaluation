# Cherry Studio LLM 渠道管理调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`88cfe5dd2b77e63464be22968f66ebcb1d429483`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改目标仓库；调查时无未提交修改
>
> 调查范围：LLM 渠道数据模型、配置生命周期与管理入口、协议适配、模型目录、凭据、重试、备份与可观测性；未将外部 CLI 自身的交互界面当作 Cherry 渠道管理入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 当前生产代码把一条 LLM 渠道表示为 SQLite 中的一条 `user_provider`。内置 Provider 由 `packages/provider-registry/data/` 提供预设，启动时只增不改地 seed 到用户表；用户配置只保存相对预设的差量，读取时再按“用户差量 > Registry > 应用默认值”合并成运行时 `Provider`。

这套设计的核心不是“一个 Provider ID 对应一种固定协议”，而是 **Provider 实例 + Endpoint Type + Adapter Family**：

- 同一 Provider 可以声明多个 Endpoint Type，例如 OpenAI Chat、OpenAI Responses、Anthropic Messages、Gemini GenerateContent；
- 每个 Endpoint Type 有独立 Base URL，并由 Registry 指定 `adapterFamily`；
- 模型可以用 `endpointTypes[0]` 覆盖 Provider 默认文本端点；
- 用户可以复制一个预设，创建继承同一 `presetProviderId` 的额外实例，因此同一家服务可有多条独立渠道；
- 模型的稳定标识包含 `providerId`，运行时不会只凭裸模型名猜测渠道。

凭据管理比多数纯客户端项目完整：一条 Provider 可保存多个带 ID、标签和启停状态的 API Key，并在请求之间 round-robin；OAuth、AWS、GCP、Azure 等认证也统一进入 `authConfig`。Renderer 读取普通 Provider 时看不到 Key 或 Token，真实凭据只在 Main/Data API 内部使用。

但高可用能力仍然有限（用户可配置的重试/fallback 默认关闭）：

- 多 Key 只是跨请求轮询，没有失败计数、Key 健康状态、429 熔断或自动恢复；
- 普通聊天默认 `maxRetries: 0`，除非调用方显式覆盖（AI SDK 层）；
- （`12498d68ec`）新增 **model-retry**：聊天调用入口用 ai-retry 的重试包装包住普通模型，同一模型的瞬态错误（429/503/529 等）按 `chat.retry.*` 偏好重试，并可配置按能力约束解析的 fallback 模型；但偏好 `chat.retry.enabled` **默认 false**，且请求级 `maxRetries: 0` 会显式关闭包装——即"默认不重试"不变，"没有跨 Provider failover"改为"**默认没有**，用户可在设置里开启同模型重试 + 模型 fallback"；
- 没有渠道权重、优先级、成本或延迟路由；
- 设置页的批量健康检查会测试每个模型与每个 Key 并显示延迟，但结果不参与运行时调度。

Provider Key、OAuth Token 和云 IAM 凭据以 SQLite JSON 文本字段落在 `<Electron userData>/cherrystudio.sqlite`，当前没有 SQLCipher、字段加密或系统 Keychain。**备份覆盖已接通 SQLite**（见 §3.4）：v7 直接备份的 full/slim 两种布局都包含 `cherrystudio.sqlite`，恢复时经 checkpoint + 崩溃安全 promotion 门落回数据库。

## 总体调用链

```text
packages/provider-registry/data/
  -> RegistryLoader
  -> PresetProviderSeeder（insert-only）
  -> user_provider / user_model（SQLite）

设置页创建、复制或编辑 Provider
  -> Data API
  -> ProviderService
       存用户差量、API Key、authConfig、排序和启停状态
  -> ProviderRegistryService
       合并预设端点、adapterFamily、模型目录和能力元数据

Assistant / 全局默认模型 / @模型
  -> UniqueModelId = providerId + modelId
  -> ModelService 获取 Provider 内模型
  -> resolveEffectiveEndpoint()
       model.endpointTypes[0]
       -> gateway model route
       -> provider.defaultChatEndpoint
  -> providerToAiSdkConfig()
       getRotatedApiKey()
       endpoint adapterFamily -> AI SDK Provider
       Base URL / Header / IAM / OAuth
  -> @cherrystudio/ai-core + AI SDK
  -> customFetch（应用代理感知）
```

## 1. Provider Registry 与用户实例

### 1.1 三层数据，而不是一份完整配置

内置 Provider 和模型目录的真源在 provider-registry 包的数据目录。预设 seeder 只插入数据库中不存在的 Provider，不覆盖用户已经修改的行。

用户 Provider 表并不复制 Registry 的完整定义。以 Endpoint 为例，数据库只持久化用户拥有的 `baseUrl` 覆盖；`modelsApiUrls` 和 `adapterFamily` 仍由 Registry 在读取时注入。这样 Registry 升级后，用户没有覆盖的协议元数据可以跟随更新。

有效配置优先级可以概括为：

```text
user_provider 用户差量
  > providers.json / provider-models.json 预设
  > 应用级默认值
```

`ProviderService.rowToRuntimeProvider()` 返回合并后的运行时 Provider，业务层通常不需要判断一个字段来自数据库还是 Registry。

### 1.2 一条用户行就是一条渠道

`user_provider` 的主要字段包括：

| 字段 | 作用 |
|---|---|
| `providerId` | 用户实例的唯一 ID，也是运行时路由键 |
| `presetProviderId` | 继承的预设；自定义 Provider 可为空 |
| `name` / `logoKey` | 显示名称和图标引用 |
| `endpointConfigs` | 用户拥有的各 Endpoint Base URL 差量 |
| `defaultChatEndpoint` | 默认文本生成协议 |
| `apiKeys` | 多 Key 数组，含 ID、值、标签和启停状态 |
| `authConfig` | OAuth 或云 IAM 等认证参数 |
| `apiFeatures` | 对 API 能力基线的差量覆盖 |
| `providerSettings` | Header、超时、服务等级等设置 |
| `isEnabled` / `orderKey` | 启停和展示排序 |

Provider 创建后默认 `isEnabled: false`。启用动作会把它移到同组前部；普通重复启用不会破坏用户排序。

### 1.3 预设可复制为多个渠道实例

设置页的复制流程会生成新的实例 ID，同时保留来源的预设 ID，并让用户重新填写名称、Base URL 和凭据。新实例继续继承同一预设的协议与模型元数据，但拥有独立的：

- API Key 池；
- Endpoint Base URL；
- Provider 设置；
- 启停状态和排序；
- 模型差量。

因此“官方 OpenAI + 两个 OpenAI 兼容中转”可以表达为三个 Provider 实例，而不是挤在一个 Provider 的上游数组中。

内置预设行不能删除；用户复制出的预设实例和纯自定义 Provider 可以删除。删除 Provider 时关联模型通过外键级联处理，模型 Pin 等引用也由服务层清理。

### 1.4 配置生命周期与管理入口

Cherry Studio 的渠道配置管理入口是 Electron 桌面端的 Provider Settings 页面。Renderer 通过 Data API 访问 Main 进程中的 ProviderService；ProviderService 再以 SQLite 的 `user_provider` 行为写入单位。设置页列表支持查看、搜索、按启用状态过滤和拖拽排序；详情页显示认证、模型列表、连接测试以及启停开关。列表项的上下文菜单和详情页 Header 分别提供编辑、复制、删除和启停入口，静态代码确认了这些事件绑定，但本次没有启动应用验证弹窗、保存后的刷新和不同平台上的实际表现（`src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderList.tsx:36-328`、`ProviderListItemWithContextMenu.tsx:43-80`、`ProviderHeader.tsx:16-91`）。

已有渠道和新建渠道的操作范围并不完全相同：

下表中的“源码确认”表示在当前快照中找到直接的入口、Schema 或服务实现；“静态推断”表示由调用关系或数据结构推导出的边界；“未找到”只表示本次搜索范围没有找到对应入口；“未验证”表示需要启动桌面端、实际读写文件或连接服务才能确认；“不适用”表示该对象或操作不属于这条流程。表中没有把“未找到”写成项目级绝对不支持。

| 对象或操作 | 已有渠道 | 新建渠道 | 依据与边界 |
|---|---|---|---|
| 查看 | **源码确认**：列表读有效 Provider，详情读单个 Provider、认证资源和模型资源 | **源码确认**：创建成功后选中并进入同一详情页 | `useProvider.ts` 的 `/providers`、`/providers/:providerId` 及子资源查询 |
| 新增 | **不适用**：已有行不能通过“新增”改变 ID | **源码确认**：可从空白自定义流程创建，也可复制一个 Provider 作为新实例；新 ID 由 Renderer 生成，数据库默认禁用 | `useProviderEditor.ts:21-53,136-149`；`ProviderService.create()` 默认 `isEnabled: false` |
| 编辑 | **源码确认**：可改名称、默认文本端点、认证配置、Endpoint 覆盖、Provider 设置、能力覆盖和 API Key；列表编辑抽屉当前只提交名称、默认端点和 Logo，Base URL/Key 等在详情页管理 | **源码确认**：创建表单可填写名称、首个 API Key、自定义 Endpoint；复制流程只把来源的预设关系和部分端点信息带入，不复制凭据 | `ProviderEditorDrawer.tsx:352-425`；`providers.ts:61-115`；`ProviderService.update():386-488` |
| 复制 | **源码确认**：预设实例可作为模板复制；复制后生成独立 API Key 池、Endpoint 覆盖、设置、模型差量、启停状态和排序 | **源码确认**：复制结果本身仍是新建流程，可继续选择预设实例来源 | `ProviderList.tsx:248-265`；`ProviderEditorDrawer.tsx:396-425` |
| 启用/停用 | **源码确认**：详情 Header 的 Switch 写入 `isEnabled`；从停用变启用时事务内移到同组首位；列表过滤只改变显示 | **源码确认**：创建后保持停用，需用户在详情页手动启用；**静态推断**：有模型时部分 onboarding 流程可自动启用 | `ProviderHeader.tsx:24-85`；`ProviderService.update():382-384,462-471`；`providerEnablement.ts` |
| 删除 | **源码确认**：自定义渠道和复制出的预设实例可删除；规范预设行被 Main 侧拒绝；删除同时清理关联模型 Pin 和 Logo 引用 | **源码确认**：新建但尚未成为规范预设的实例适用同一删除规则 | `ProviderService.delete():811-868`；删除前由 `ConfirmActionPopup` 二次确认 |
| 导入 | **未找到**通用文件导入；**源码确认**已找到 Provider deep link 导入，先确认再按 ID 新建或更新端点，并追加 API Key | **源码确认**：新 ID 走 create；已有 ID 走 update，因而不是纯新增操作 | `useProviderDeepLinkImport.ts:41-136` |
| 导出 | **未找到** Provider 专用导出按钮、导出 DTO 或导出文件格式；**源码确认**通用备份会包含 SQLite，因此属于数据库级备份而不是脱敏渠道导出 | **静态推断**：同样随 SQLite 备份，没有单独的新建渠道导出路径 | `LegacyBackupManager.ts` 的 v7 full/slim 备份路径；Provider API schema 未声明 export 路由 |
| 连接测试 | **源码确认**详情页可对单个渠道选择模型和 Key 发起最小请求，也可批量检查模型与 Key；**源码确认**诊断结果不改变启停或 Key 健康状态 | **源码确认**新建流程保存后才有正式 Provider ID；创建抽屉自身没有独立连接测试按钮 | `useProviderConnectionCheck.ts`、`checkModelsHealth.ts`；`ProviderEditorDrawer.tsx:508-516` |

这里的“配置文件”需要分成两种含义。SQLite 文件 `<Electron userData>/cherrystudio.sqlite` 是渠道和凭据的持久化文件，但源码没有把它暴露为面向用户的逐渠道编辑器；直接修改数据库属于未支持的外部操作。另一种是 Code CLI 的外部配置文件，例如 Claude、Codex、OpenCode、Gemini、Qwen、Kimi 和 Pi 的 JSON、TOML 或 dotenv 文件。Code 页面可以读取这些文件生成草稿，也可以在启用或编辑当前 CLI Provider 时写回文件；Main 侧只接受预先枚举的 target，并负责路径解析、原子写入、权限和回滚。这些文件表达的是“当前选中的 Provider/模型如何注入外部 CLI”，不是 `user_provider` 的替代存储，也没有 Provider 列表级的复制、删除或渠道健康测试（`src/shared/utils/cliConfig.ts:11-98`、`src/shared/ipc/schemas/codeCli.ts:61-82`、`src/renderer/pages/code/cliConfig/draft.ts:24-33,108-185`）。

Code CLI 的启停语义也不同于普通 Provider。选择外部 CLI Provider 时，页面先解析保存的模型和凭据、写入 CLI 配置文件，成功后才把该 Provider 记为当前项；取消选择时先清理 Cherry 管理的配置文件，再清除当前项。若没有可解析模型，启用操作会打开配置面板而不是创建一个新的 LLM Provider。所谓 own login 是外部 CLI 自己的登录配置，Cherry 会清理其管理的凭据和模型字段，但可以保留工具参数；这属于 CLI 连接选择，不是普通 Provider 的 `isEnabled` 开关（`useConfigPanelController.ts:222-325`）。

按入口归纳，本次源码范围得到以下边界：

- **配置文件**：SQLite 可确认是持久化真源；Code CLI 文件可读、编辑和写回，支持按工具批量写入以及 Codex `auth.json` 删除。未找到面向普通 Provider 的 JSON/YAML 导入导出文件格式，也未找到文件级渠道复制或连接测试。
- **CLI**：仓库中的 Code CLI 功能负责启动外部 Claude Code、Codex 等工具，并为其写入配置；未找到 Cherry 自身用于 Provider CRUD 的命令行入口。外部 CLI 的命令和登录界面属于外部项目，本次未调查。
- **TUI**：本仓库未找到 TUI 组件、终端渠道管理命令或 TUI Provider CRUD 入口；结论是“本次未找到”，不是对外部 CLI TUI 能力的否定。
- **Web**：API Gateway 是本地 HTTP 推理网关，提供 `/v1/models` 和聊天协议接口，读取已启用 Provider/模型；未找到通过 Web API 管理 `user_provider` 的 CRUD、导入导出或连接测试路由。它可以启停网关本身，但这不是渠道启停（`src/main/features/apiGateway/utils/models.ts:42-123`、`docs/references/api-gateway/README.md:80-98,213-283`）。
- **桌面端**：这是源码确认的完整渠道管理入口，覆盖查看、新增、编辑、复制、启停、删除、deep link 导入和连接检查；没有 Provider 专用导出，数据库级备份另见 §3.4。

默认预设与用户配置的生命周期是 insert-only seed 加读取时合并。应用启动或 Registry 变更不会覆盖用户行；未被用户覆盖的端点、适配器和模型元数据可以随 Registry 更新。新建自定义 Provider 没有 `presetProviderId` 时只拥有用户提交的配置，复制预设则继续继承来源的 Registry 元数据。更新 Endpoint 时服务层会把等于 Registry 基线的字段投影掉，避免一次普通编辑把默认值永久冻结到用户行（`ProviderService.ts:160-200,335-378,424-445`）。

## 2. Endpoint 与 Adapter 路由

### 2.1 Endpoint Type 是协议选择键

Endpoint 不只是 URL。每个 Endpoint Type 的有效配置包含三部分：基础 URL、按模型类别区分的模型列表 URL，以及决定协议解析方式的适配器族。

文本相关类型覆盖 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Google GenerateContent 和 Ollama Chat；自定义 Provider 创建页还可同时配置 OpenAI 图片生成与编辑端点。

运行时端点优先级是：

```text
model.endpointTypes[0]
  -> 多后端网关的按模型路由
  -> provider.defaultChatEndpoint
  -> undefined / OpenAI-Compatible 回退
```

随后解析器读取该端点的适配器族，生成 AI SDK Provider ID，必要时再选择 Chat 或 Responses 变体。这里是协议路由，不是错误发生后的容灾路由。

### 2.2 Base URL 与 Header

`providerToAiSdkConfig()` 按 Endpoint Type 格式化 URL：Gemini 补 `v1beta`，Ollama 使用自己的 Host 规则，部分服务禁止自动追加版本；端点解析函数再把 Base URL 与端点路径拆分。

`providerSettings.extraHeaders` 会与应用默认 Header、Provider 专用 Header 合并。Azure、Bedrock、Vertex、Copilot、CherryIN、Codex、Grok CLI 等有专门的配置 builder；其余已注册协议走通用 AI SDK Provider，最终才回退 OpenAI-Compatible。

网络请求默认注入 `customFetch`，以复用 Electron Session 的应用代理。个别 Provider 在此基础上增加签名、Body 改写或动态认证。

## 3. 凭据模型与安全边界

### 3.1 多种认证统一在 Provider 行中

`AuthConfig` 当前区分：

- `api-key`；
- `oauth`；
- `iam-aws`；
- `api-key-aws`；
- `iam-gcp`；
- `iam-azure`。

API Key 独立保存在 `apiKeys` 数组中；OAuth access/refresh token、AWS access key/secret、GCP credentials 则进入同一行的认证配置。Codex、Grok CLI、CherryIN 等 OAuth 路径由 `OAuthRuntimeService` 刷新或在 401 后强制刷新，并在请求时注入 Token。

外部 CLI 认证是另一类边界：Claude Code Agent Runtime 等可以依赖 SDK/CLI 自己的认证与重试事件，不应把它们当成普通 Chat Provider 的 API Key 路由能力。

### 3.2 Renderer 默认拿不到秘密

合并入口将 `apiKeys` 映射为不含 `key` 的运行时条目，只暴露 ID、标签和启停状态；认证配置也只投影为 `authType`。需要编辑凭据时，设置页调用专用 Data API 资源；普通 Provider 列表和聊天业务不会收到完整秘密。

这降低了 Renderer 泄露面，但不是静态加密：Main 进程仍从 SQLite 读取明文并构造请求。

### 3.3 SQLite 明文落盘

数据库路径由 Path Registry 固定为：

```text
<Electron userData>/cherrystudio.sqlite
```

`DbService` 用 `better-sqlite3` 直接打开文件，并配置 WAL、`synchronous=NORMAL`、外键和 5 秒 busy timeout。没有 SQLCipher 初始化、加密 Key、Keychain 或字段加密调用。

`user_provider.api_keys` 与 `auth_config` 都是 JSON 文本列，因此 Key、Token 和 IAM 凭据可从数据库直接恢复。Renderer 脱敏只保护进程边界，不保护磁盘副本、恶意本机进程或被复制的数据库文件。

### 3.4 备份已覆盖 SQLite

当前真实接线的备份引擎是 `LegacyBackupManager`——类名 `BackupManager`，文件头仍标注 `@deprecated LEGACY v1 CODE — retained as the active compatibility backup engine while v2 backup is unfinished`；（`220dff874f` 及后续）其 direct backup 升级为 **v7 full/slim 双布局**（`LegacyBackupManager.ts:1-15,192-230,292-406`）：

```text
full 布局：Data/ + IndexedDB/ + Local Storage/ + cache.json + metadata.json
slim 布局：Data/cherrystudio.sqlite + cache.json（可选）
```

也就是说 **`cherrystudio.sqlite`（含 Provider、模型、聊天等全部 v2 业务数据与凭据）现在会进入真实备份**——不再只是 IndexedDB/Local Storage/Data 三件套。恢复侧把归档里的 SQLite 先复制到 work 库，再经 `src/main/data/db/restore/` 的 checkpoint + 崩溃安全 promotion 门原子替换（`LegacyBackupManager.ts:972-973,1063`），失败时保留旧库。另有配套行为：备份前对 AI stream/agent/channel 写方做 quiesce（`BACKUP_ACTIVE_WRITERS_ERROR_CODE`，`e5a0c47a59`）、跳过 LevelDB `LOCK` 等被占用文件（`691970aba0`/`848993332d`）、自动备份间隔跨重启保持（`6f9ab1befc`）。

仍未改变的事实：凭据在备份文件里仍是明文 JSON 文本（备份与数据库一样无静态加密）；"备份会扩散 Provider 密钥"的风险现在真实存在，但这是产品设计使然，与 §3.3 的磁盘明文结论同源。

## 4. 多 Key 轮询

### 4.1 选择规则

`ProviderService.getRotatedApiKey(providerId)` 的规则很直接：

1. 过滤 `isEnabled=false` 的 Key；
2. 没有可用 Key时返回空字符串；
3. 只有一个 Key时直接返回；
4. 多个 Key时按 Key ID round-robin；
5. 上次使用的 Key ID保存在 Main `CacheService` 的 `settings.provider.<providerId>.last_used_key_id`。

SDK 配置构建入口每次构造配置时调用一次该方法。连接检查可传 `apiKeyOverride`，从而精确测试某一个 Key 而不受轮询影响。

### 4.2 没有健康状态或同请求换 Key

Key 条目没有错误次数、429 时间、熔断截止时间或健康分。普通请求失败后也没有调用 ProviderService 把该 Key 标坏。

因此多 Key 的准确语义是“请求之间平均分配”，不是：

- 当前请求 429 后换 Key；
- 自动跳过认证失败 Key；
- 按剩余额度、延迟或价格选择 Key；
- 熔断一段时间后自动恢复。

如果一个坏 Key 与一个好 Key同时启用，请求可能按轮询节奏持续交替失败和成功。

## 5. 模型目录与同步

### 5.1 Registry 与上游 API 合并

模型同步先通过 Main IPC `ai.provider.model.list` 请求上游模型列表。Main 读取数据库中的凭据和 Endpoint 配置，Renderer 不接触真实 Key。

拿到上游结果后，`fetchResolvedProviderModels()` 再调用 `/providers/:id/models:resolve`，用 Registry 补充：

- 名称、描述、分组和模型家族；
- capability 与输入/输出模态；
- Endpoint Type；
- 上下文和输出限制；
- 推理参数档位；
- 价格与归属方。

若 Provider 的 `modelListSource` 是 `registry`，则直接读取预设目录；这类目录 fallback 只影响“有哪些模型可选”，不影响推理请求失败后的渠道切换。

### 5.2 模型属于 Provider

模型 ID 使用 `UniqueModelId`，解析后得到 Provider ID 加模型 ID 的二元组合。相同裸模型名可以分别存在于多个 Provider 实例中；选择模型时已经选择了渠道。

模型可声明自己的端点类型，覆盖 Provider 默认协议。例如同一多协议网关中的 Claude 模型走 Anthropic Messages，而另一模型走 OpenAI Responses。该路由在请求前确定，不读取实时健康度。

### 5.3 Registry 把模型本体与 Provider 覆盖分开

[`packages/provider-registry/src/schemas/model.ts`](../../cherry-studio/packages/provider-registry/src/schemas/model.ts) 的基础模型定义保存模型固有信息：

- ID、名称、描述、family、`ownedBy`、开放权重；
- capability 与输入/输出模态；
- context、最大输入和最大输出；
- 输入、输出、缓存读写、按图和按分钟价格；
- reasoning 控制，包括 effort、token budget 和 toggle；
- temperature/top-p/top-k 等参数支持范围；
- 图像生成各 mode 的控件、范围、输入图数量和专用 transport。

[`packages/provider-registry/src/schemas/provider-models.ts`](../../cherry-studio/packages/provider-registry/src/schemas/provider-models.ts) 则描述 `(providerId, modelId)` 关系。这里可以声明真实 `apiModelId`、变体标签、capability 的 add/remove/force、模态、限制、价格、Endpoint Type、废弃替代项，以及按 Endpoint 区分的 reasoning wire contract。

这种拆分解决了两个常见混淆：能力和上下文通常属于模型本体；模型别名、某网关提供的价格、协议和推理参数编码则属于 Provider-模型组合。聚合平台不会因为复用了同一个基础模型，就被迫共享错误的 API ID 或协议元数据。

### 5.4 元数据在生成期汇集

[`packages/provider-registry/docs/architecture.md`](../../cherry-studio/packages/provider-registry/docs/architecture.md) 说明 registry 是代码生成流水线：creator/provider 的手工 TypeScript 声明，加上生成时实时读取的 models.dev 和 OpenRouter，产出：

| 文件 | 作用 |
|---|---|
| `data/models.json` | 模型本体及固有元数据 |
| `data/providers.json` | Provider 连接和协议定义 |
| `data/provider-models.json` | Provider-模型覆盖与别名 |

[`packages/provider-registry/scripts/upstream.ts`](../../cherry-studio/packages/provider-registry/scripts/upstream.ts) 用 Zod 逐条验证上游数据，格式漂移的条目会被跳过。跨来源合并不是简单选一个赢家：

- capability 和模态取并集；
- context 与最大输出取较大值；
- reasoning control 按种类合并，budget 范围放宽；
- 开放权重只要任一来源为真即为真；
- 定价按字段补齐，较早的 curated 来源在同字段冲突时优先；
- 若 `maxOutputTokens > contextWindow`，最终化阶段丢弃不可信的输出上限。

生成数据随应用发布。运行时 [`RegistryLoader`](../../cherry-studio/packages/provider-registry/src/registry-loader.ts) 只是从磁盘读入、建索引，并在 30 秒空闲后释放内存；下次访问重新读本地文件，不会重新请求 models.dev。所谓模型同步不能替代升级应用或重新生成 registry。

### 5.5 运行时三层覆盖

[`src/shared/data/types/model.ts`](../../cherry-studio/src/shared/data/types/model.ts) 明确给出最终优先级：

```text
用户 user_model 覆盖
  > provider-models.json 的 Provider 级覆盖
  > models.json 的基础模型定义
```

Registry 合并时，Provider override 可修改 capability、模态、context、输出上限、价格、参数支持和 Endpoint Type。随后 [`src/main/data/services/ModelService.ts`](../../cherry-studio/src/main/data/services/ModelService.ts) 应用用户 overlay；用户设置的 capability、模态、协议、限制、reasoning、参数支持和价格均可覆盖基线。`null/undefined` 表示不覆盖，显式空数组则保留，因而可以有意清空 capability 或 Endpoint Type。

最终运行时 `Model` 还包含启停、隐藏、废弃、替代模型和用户 notes。`imageGeneration` 是例外：它在读取时从 registry 注入，不持久化到 `user_model`，避免大块控件 schema 在每个用户数据库中复制。

远端 `/models` 返回的 ID 会用精确 ID、Provider API ID 和规范化 ID 查 registry。带参数规模的 Ollama 风格 ID 优先做保留尺寸的匹配；无法确认具体尺寸时宁可不套元数据，也不借用另一个尺寸变体的价格和限制。

### 5.6 元数据直接参与请求

元数据消费者不止模型选择器：

- 端点类型与 Provider 默认端点共同确定 OpenAI Chat、Responses、Anthropic、Gemini、Ollama 等 Adapter；
- reasoning 支持与端点的 wire contract 决定 UI 可选档位及最终序列化字段；
- `parameterSupport` 控制 temperature、top-p、max output 等参数是否发送和如何限幅；
- `maxOutputTokens` 参与助手参数裁剪，`contextWindow` 会传给 Ollama 的 `num_ctx`，也用于工具延迟暴露和 Claude 1M context 后缀；
- capability 决定工具调用、视觉、联网、图片/音视频工作流和模型筛选；
- pricing 用于模型详情和用量费用展示，但不参与渠道自动路由。

这套方案的主要代价是元数据错误会同时影响 UI 与 wire protocol，影响面大于普通展示目录。项目通过 schema、catalog invariant、source-sync 和禁止手改生成 JSON 的 CI 约束降低风险；但 live upstream 参与生成，重新生成可能顺带吸收与本次改动无关的价格或能力漂移，仍需审阅生成差异。

Registry 数据与路由继续演进（机制未变，仅条目/覆盖变化）：

- 新增 Radeon Cloud Provider（`7b0d7a8908` 等）；
- New API 的 embedding endpoint type（`11604e09cc`）；
- DeepSeek V4 Flash Responses 端点（`2a4e6a6882`）；
- Claude Opus 5/Sonnet 5 及 1M-context 变体（`bd2b5eefc6`）；
- Ollama Gemma 4 thinking（`03d266e029`）；
- OpenCode Go 按所服务协议路由（`bf66103a2a`）；
- DeepSeek/OpenRouter/Dashscope 内置联网搜索与可区分的解析后模型名（`da3b5f1921`）；
- Ollama 原生 thinking 能力探测（`d97277ee75`）；
- Doubao Responses 注解归一化（`584f154cc6`）；
- new-api 单主机多路由版本（`a502b21c3e`）；
- CLI 配置经统一网关支持 detailed models（`84a33e88bc`）。

## 6. 模型选择与多模型调用

Assistant 保存一个 `UniqueModelId` 模型 ID；无 Assistant 的 Topic 使用 `chat.default_model_id`。运行时按稳定二元标识精确查找 Provider 和模型。

聊天输入框支持 `@模型` 多选。持久会话中，一次发送可以解析出多个模型，为同一用户消息创建多个 Assistant placeholder，并并行执行多个模型，再以 siblings group 展示结果。这是“同一问题并行比较多个明确选择的模型”，不是某个模型失败后尝试下一个。

多模型还有明确限制：流式会话中的 steer continuation 和临时聊天只使用 `mentionedModelIds[0]`；重试/重新生成会尽量继承目标消息实际使用的模型，避免全局默认模型变化后悄悄漂移。

## 7. 连接检查与可观测性

### 7.1 单 Provider 连接检查

设置页打开连接检查时，先立即保存输入框中尚未完成 debounce 的 Key，再使用第一个可检查模型与 Key 覆盖参数发起最小请求。默认超时 15 秒，成功后可自动启用有模型的 Provider。

检查中途修改 Provider、Host 或 Key 会 Abort 旧请求，并用 run ID 防止旧回调污染新状态。

### 7.2 批量模型与多 Key 健康检查

`checkModelsHealth()` 可串行或并行检查多个模型；对每个模型，它会并行测试全部 Key 并记录：

- 每个 Key 成功或失败；
- 序列化错误；
- 延迟；
- 模型级成功、部分成功或失败汇总。

图片、视频、音频生成因为可能计费会被标记为生成成本风险，TTS/STT 当前不走这套探针。

这些结果是设置页的即时诊断数据，不会写回 Key 池，也不会改变运行时轮询的选择。因此“检测出坏 Key”与“运行时自动避开坏 Key”是两回事。

开发者模式还可对 HTTP 请求启用 Trace；普通运行时另有 Topic/Turn trace 和多模型子 Span，但没有以这些指标驱动渠道选择。

## 8. 重试、容错与网络

普通 AI SDK Chat 在 `buildAgentParams()` 中显式设置：

```ts
maxRetries: maxRetries ?? 0
```

即 SDK 层默认不重试（`buildAgentParams.ts:583`）。调用方可以通过 `requestOptions.maxRetries` 覆盖，但 SDK 重试仍绑定已经解析完成的同一 Provider、Endpoint、Key 和模型；它不会重新执行渠道决策。

**用户可配置重试/fallback（`12498d68ec`，model-retry）**：重试默认只作用于同一模型，失败后可在配置的候补模型中换兼容者接管。聊天生成入口用 ai-retry 的 `createRetryableWrap` 包住模型调用（`src/main/ai/runtime/aiSdk/retry/`），同一模型对 429/503/529 等瞬态 API 错误按策略重试；启用 fallback 时，由同目录的 `buildFallbackModels` 解析出的候补模型列表接管失败调用，解析时按能力过滤，function-calling、视觉、PDF、原生文件支持等不匹配的候补会被跳过。

重试与 fallback 的开关和参数都通过偏好配置控制，集中在偏好组 `chat.retry.*` 之下：`chat.retry.enabled` 默认关闭，`chat.retry.max_attempts` 默认 3、范围 1-10，另有退避开关与 fallback 模型 ID 列表两项。相关 schema 见 `retryPolicy.ts:14-25、preferenceSchemas.ts:194-200,616-619`。请求级 `maxRetries: 0` 会显式关闭该包装；包装激活时 SDK 侧同一参数被置 0，避免两层重试叠加（`AiService.ts:565-601`）。

重试与切换过程只在消息流中实时可见，持久化前会被剥离：该过程以瞬时 `data-retry` part 呈现在消息里（见消息渲染器笔记）。因此：

- "普通聊天默认不重试"（SDK 层）仍成立；
- "没有跨 Provider、跨模型自动 failover"改为：**默认没有**，但用户可配置"同模型重试 + 能力兼容的 fallback 模型"（fallback 仍属模型级，不按 Key/渠道池调度）；
- 重试与 fallback 不改变 Key 轮询、渠道权重、成本/延迟路由等缺失项。

Claude Code Agent Runtime 会接收其 SDK 的 `api_retry` 事件并向 UI 报告 attempt、delay 和错误类别。这属于外部 Agent Runtime 的重试机制，不能外推为普通聊天默认重试。

异步图片/视频任务的轮询、OAuth 401 强制刷新，以及模型列表请求的容错也都有各自用途；它们均不是跨 Provider 推理 failover。

网络层复用 Electron Session 代理。Provider 可以设置 `timeout` 与额外 Header，但没有单 Provider 的代理池、出口健康选择或自动切换。

## 9. 配置导入

Provider deep link 将 JSON 负载带入设置页，字段包含 ID、Key、Base URL、类型和名称。导入前弹窗确认，并校验 URL Scheme；新 ID 创建 Provider，已有 ID 更新端点，Key 通过专用 API 追加。

类型映射会把 Anthropic、OpenAI Responses、Gemini/Vertex 和 Ollama 解析到相应默认 Endpoint，其余回退 OpenAI Chat Completions。

这是一种用户确认后的配置迁移，不是远程动态配置中心。负载中的 API Key 会经过 URL/路由参数进入应用，调用方仍需考虑浏览器历史、聊天记录或日志对深链的暴露。

## 10. 当前渠道与模型适配补充

Provider Registry 增加 DeepSeek V4 Pro 的 Responses 路由与 DeepSeek V4 Flash Vision Exp 的图像能力目录；同时移除了已退役的 GitHub Models 集成。Pi 与 DSH 的模型选择不直接复用普通聊天的任意 endpoint，而是经过各自兼容性和默认 Chat endpoint 解析；LM Studio 预设已补齐该默认 endpoint。模型设置还可选择 token 上限预设，Ollama 的上下文窗口则从 `/api/show` 读取。

这些变化均在渠道解析、目录或 UI 选择层确认，第三方 endpoint 对所有组合的实际响应仍未运行验证。依据：`packages/provider-registry/src/providers/ollama.ts`、`src/shared/ai/piModelCompatibility.ts`、`src/shared/ai/dshModelCompatibility.ts`、`src/shared/data/presets/runtimeTransport.ts`、`src/renderer/components/ModelSelector`。

## 11. 能力边界与横向比较要点

### 已实现

- Registry 驱动的 Provider 与模型目录；
- 预设 insert-only seed 和运行时差量合并；
- 同一预设下创建多个独立 Provider 实例；
- 多 Endpoint Type 与 Adapter Family 协议路由；
- 独立 Base URL、额外 Header 和 Provider 专属配置；
- 多 API Key 管理与跨请求 round-robin；
- API Key、OAuth、AWS、GCP、Azure 与外部 CLI 认证；
- Main/Data API 凭据隔离和 Renderer 脱敏；
- 上游模型列表与 Registry 元数据合并；
- 单模型、多模型、多 Key 连接检查与延迟展示；
- `@模型` 并行比较；
- 应用代理、HTTP Trace 和取消控制。

### 未实现或不应误判

- 没有 Key 错误计数、熔断、自动恢复或配额感知；
- 多 Key 轮询不等于当前请求内换 Key；
- SDK 层普通聊天默认不重试（`maxRetries ?? 0`）；用户可配置的 model-retry 默认关闭；
- SDK 重试不等于重新选择 Provider；model-retry 的 fallback 是模型级、按能力过滤，不按 Key/渠道池调度；
- 默认没有跨 Provider、跨模型自动 failover（需用户开启 `chat.retry.*`）；
- 没有渠道权重、优先级、成本或延迟路由；
- 多 Endpoint 是协议路由，不是容灾路由；
- 模型目录 fallback 不等于推理请求 fallback；
- `@模型` 是并行显式调用，不是错误后的候补链；
- 健康检查结果不进入运行时调度；
- SQLite 凭据没有静态加密；
- 备份/恢复已覆盖 SQLite，但备份文件与数据库同样明文保存凭据。

## 12. 关键源码索引

- Provider Registry 设计：[`docs/references/provider-model/provider-registry.md`](../../cherry-studio/docs/references/provider-model/provider-registry.md)
- Registry 数据：[`packages/provider-registry/data/`](../../cherry-studio/packages/provider-registry/data/)
- Provider 表：[`src/main/data/db/schemas/userProvider.ts`](../../cherry-studio/src/main/data/db/schemas/userProvider.ts)
- Provider 服务与 Key 轮询：[`src/main/data/services/ProviderService.ts`](../../cherry-studio/src/main/data/services/ProviderService.ts)
- Registry 合并：[`src/main/data/services/ProviderRegistryService.ts`](../../cherry-studio/src/main/data/services/ProviderRegistryService.ts)
- Provider 类型与脱敏 Schema：[`src/shared/data/types/provider.ts`](../../cherry-studio/src/shared/data/types/provider.ts)
- Endpoint 解析：[`src/main/ai/provider/endpoint.ts`](../../cherry-studio/src/main/ai/provider/endpoint.ts)
- SDK 配置构建：[`src/main/ai/provider/config.ts`](../../cherry-studio/src/main/ai/provider/config.ts)
- 普通聊天重试参数：[`src/main/ai/runtime/aiSdk/params/buildAgentParams.ts`](../../cherry-studio/src/main/ai/runtime/aiSdk/params/buildAgentParams.ts)
- SQLite 初始化：[`src/main/data/db/DbService.ts`](../../cherry-studio/src/main/data/db/DbService.ts)
- 数据路径：[`src/main/core/paths/pathRegistry.ts`](../../cherry-studio/src/main/core/paths/pathRegistry.ts)
- 当前 legacy 备份：[`src/main/services/LegacyBackupManager.ts`](../../cherry-studio/src/main/services/LegacyBackupManager.ts)
- Renderer 备份入口：[`src/renderer/services/BackupService.ts`](../../cherry-studio/src/renderer/services/BackupService.ts)
- SQLite 恢复基础设施：[`src/main/data/db/restore/README.md`](../../cherry-studio/src/main/data/db/restore/README.md)
- 模型同步：[`src/renderer/pages/settings/ProviderSettings/utils/modelSync.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/utils/modelSync.ts)
- 连接检查：[`src/renderer/pages/settings/ProviderSettings/hooks/providerSetting/useProviderConnectionCheck.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/hooks/providerSetting/useProviderConnectionCheck.ts)
- 批量健康检查：[`src/renderer/pages/settings/ProviderSettings/ModelList/checkModelsHealth.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ModelList/checkModelsHealth.ts)
- 健康检查协议：[`src/renderer/pages/settings/ProviderSettings/utils/healthCheck.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/utils/healthCheck.ts)
- Provider 创建/复制：[`src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderEditorDrawer.tsx`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderEditorDrawer.tsx)
- Provider 列表操作：[`src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderList.tsx`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ProviderList/ProviderList.tsx)
- Provider 详情启停：[`src/renderer/pages/settings/ProviderSettings/components/ProviderHeader.tsx`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/components/ProviderHeader.tsx)
- Provider CRUD Schema：[`src/shared/data/api/schemas/providers.ts`](../../cherry-studio/src/shared/data/api/schemas/providers.ts)
- Code CLI 配置文件：[`src/shared/utils/cliConfig.ts`](../../cherry-studio/src/shared/utils/cliConfig.ts)、[`src/renderer/pages/code/cliConfig/draft.ts`](../../cherry-studio/src/renderer/pages/code/cliConfig/draft.ts)、[`src/renderer/pages/code/hooks/useConfigPanelController.ts`](../../cherry-studio/src/renderer/pages/code/hooks/useConfigPanelController.ts)
- API Gateway 管理边界：[`src/main/features/apiGateway/utils/models.ts`](../../cherry-studio/src/main/features/apiGateway/utils/models.ts)、[`src/main/features/apiGateway/ApiGatewayService.ts`](../../cherry-studio/src/main/features/apiGateway/ApiGatewayService.ts)
- 自定义多端点：[`src/renderer/pages/settings/ProviderSettings/ProviderList/customProviderCreation.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/ProviderList/customProviderCreation.ts)
- Deep Link 导入：[`src/renderer/pages/settings/ProviderSettings/hooks/useProviderDeepLinkImport.ts`](../../cherry-studio/src/renderer/pages/settings/ProviderSettings/hooks/useProviderDeepLinkImport.ts)
- 多模型解析：[`src/main/ai/streamManager/context/modelResolution.ts`](../../cherry-studio/src/main/ai/streamManager/context/modelResolution.ts)
- 持久会话多模型调度：[`src/main/ai/streamManager/context/PersistentChatContextProvider.ts`](../../cherry-studio/src/main/ai/streamManager/context/PersistentChatContextProvider.ts)

## 13. 未验证事项

1. 本次没有启动 Electron 应用，也没有向真实 Provider 发起付费或流式请求；连接检查、代理、OAuth 回调和多模型 UI 结论来自源码。
2. 没有枚举并实测 Registry 中每个 Provider 的全部协议组合；专用 Builder 仍可能有服务商级特殊限制。
3. 没有检查操作系统对 Electron `userData` 目录施加的账户级 ACL；“明文”结论只指应用没有额外静态加密。
4. 备份/恢复管线已接线（v7 full/slim 布局 + checkpoint/promotion 恢复门，见 §3.4），但恢复的端到端行为（quiesce 失败、损坏归档、promotion 失败回退）未运行验证；本笔记只描述静态确认的调用路径。
5. CherryIN、AiHubMix 等服务端可能在客户端不可见的位置做模型或上游容灾；本仓库客户端只把它们视为一个 Provider 实例，不能据此推断服务端内部没有 failover。
6. 本次未启动桌面端，未实测 Provider 列表的右键菜单、编辑抽屉、复制流程、删除确认、启停排序、deep link 弹窗确认和保存后的缓存刷新；相关结论是源码确认的入口与事件绑定，实际视觉和平台行为未验证。
7. 本次未实际读写 Claude、Codex、OpenCode、Gemini、Qwen、Kimi 或 Pi 的用户配置文件；Code CLI 文件的 target 白名单、草稿构建、写入前校验和 Main 侧写入边界来自源码，外部 CLI 是否按各自版本接受生成内容未验证。
8. “未找到 Cherry 自身 CLI/TUI Provider CRUD”和“未找到 Web Provider CRUD/导出/连接测试路由”来自本次对 `package.json`、`src/main`、`src/renderer`、`src/shared` 及 API Gateway 路由的静态搜索；未运行打包产物或外部 CLI，不能排除运行时动态加载或仓库外组件提供入口。
9. SQLite 级备份包含 Provider 凭据的结论已由备份实现静态确认，但本次未运行导出、恢复、损坏归档和跨版本迁移；因此不能据此确认每一种用户可见备份设置的界面提示和最终归档内容。
