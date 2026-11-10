# Codex LLM 渠道管理调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：只读静态阅读当前快照的配置层、model-provider、login、codex-api、models-manager、responses-api-proxy 及 CLI/TUI/app-server 入口；沿“配置加载 → Provider 合并 → 凭据解析 → 请求组装 → 流式响应”主链追踪。未运行构建、登录或真实模型请求。
>
> 调查范围：模型 Provider 实体、配置层级与 profile、管理入口、凭据来源与存储、模型目录、Responses 协议与请求组装、运行时选择、重试与故障转移、代理与诊断；不覆盖 ChatGPT 账号服务端、Codex Cloud 后端、桌面安装器内部实现，以及当前快照中不存在的渠道管理界面。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 没有“多 Provider 渠道面板”。它的“渠道”由三部分合成：`config.toml` 里的一条 `model_providers.<id>` 定义、当前生效的认证方式，以及请求中使用的模型标识。配置文件是主要管理面；CLI 负责登录/登出和一次性覆盖，TUI 与 app-server 只提供模型选择和通用配置写入，本次未找到 Provider 的增删改查界面。

当前快照的关键事实：

- **内置 Provider 六个**：OpenAI 兼容路线是 `openai`、`ollama`、`lmstudio`，Bedrock 有 `amazon-bedrock` 与 `amazon-bedrock-runtime` 两个变体，GCP 单独一个；内置表在构造时一次写入（`codex-rs/model-provider-info/src/lib.rs:753-786`）。
- **自定义 Provider 通过配置增加**，使用新的 ID；内置 ID 进入保留名单，无法整体覆盖（`codex-rs/config/src/config_toml.rs:952-983`）。
- **一个 Provider 只挂一个 `base_url`**，结构里没有端点数组；接入多个兼容端点时要拆成多个 Provider ID（`codex-rs/model-provider-info/src/lib.rs:145-236`）。
- **线协议只有 Responses**。配置写成 `wire_api = "chat"` 会在反序列化阶段直接报错，错误提示要求改用 `responses`（`codex-rs/model-provider-info/src/lib.rs:113-142`）。
- **凭据默认存 `$CODEX_HOME/auth.json`**，文件模式为明文 JSON；可选 keyring 或“keyring 加密 + 本地密文文件”（`codex-rs/login/src/auth/storage.rs:51-77、256-272`；`codex-rs/config/src/types.rs:136-148`）。
- **模型目录有内置快照、远端目录和磁盘缓存三层**，缓存文件是 `models_cache.json`，默认 TTL 300 秒（`codex-rs/models-manager/src/lib.rs:18-20`；`codex-rs/models-manager/src/manager.rs:41-42`）。
- **本次未找到多 Key 轮换、跨 Provider failover 或持久化健康状态**；重试发生在同一 Provider 内，另有每请求一次的 Provider 级 401 凭据刷新和 WebSocket→HTTP 的传输回退（`codex-rs/core/src/client.rs:776-794、2029-2067`；流式重试见下文）。
- **会话与 Provider 绑定**：恢复或继续一个会话时，当前配置的 Provider 与会话保存的 Provider 不一致，请求会直接返回结构化错误，历史不会被静默发往另一个后端（`codex-rs/app-server/src/config_manager.rs:437-455、596-610`）。

## 系统边界与总体调用链

一次模型请求的主链如下：

```text
CLI / TUI / app-server
  → 配置分层加载（打包默认、系统、企业、用户、profile、项目、会话覆盖）
  → 合并内置 Provider 与 config.model_providers
  → 解析 model_provider_id（策略要求 > 会话/CLI > config.model_provider > "openai"）
  → create_model_provider（OpenAI 兼容 / Bedrock / GCP 三种运行时实现）
  → 解析 Provider 级凭据或全局 Codex 认证
  → 组装 ApiProvider（base_url、query、Header、重试、流空闲超时）
  → ResponsesClient POST /responses，Accept: text/event-stream
  → SSE 事件流回到 core，转成会话事件与 token 用量
```

这条链路的配置解析落在 core 的配置模块：先合并内置 Provider 表与用户配置，再按“策略强制值 → 显式覆盖 → 配置值 → 默认 openai”的顺序确定 ID，最后取出该 ID 对应的 Provider 结构。请求侧由工厂函数按 Provider 类型选出 OpenAI 兼容、Bedrock 或 GCP 三种运行时之一，再组装成统一的请求描述对象 `ApiProvider`（`codex-rs/core/src/config/mod.rs:4059-4086`；`codex-rs/model-provider/src/provider.rs:449-472`；`codex-rs/model-provider-info/src/lib.rs:469-517`）。

## 1. 渠道实体与数据模型

### 概念对应

| 通用概念 | Codex 中的对应物 | 说明 |
|---|---|---|
| Provider | `model_providers` 表中的一个条目，或内置 ID | 键是用户可见的 Provider ID，值是 `ModelProviderInfo` |
| Endpoint | `ModelProviderInfo.base_url` | 单值；缺省时按认证方式选择 OpenAI 或 ChatGPT Codex 地址 |
| 模型 | `config.model` / `ModelInfo.slug` | 模型元数据独立于 Provider，来自模型目录 |
| 凭据 | `AuthMode` + `auth.json`、环境变量或命令式 auth | Provider 可选择复用全局 OpenAI 认证，也可自带 `env_key` |
| Profile | `ConfigProfile` 或 `<name>.config.toml` | 切换一组模型、Provider、推理和沙箱默认值 |

`ModelProviderInfo` 用一个对象描述一个 Provider，字段按用途分三组：

- 连接与目录：显示名、`base_url`、模型目录地址、`wire_api`、查询参数、静态与来自环境变量的 Header、请求与流重试参数和流空闲超时；
- 认证：`env_key` 与说明文字、实验性 Bearer、命令式 `auth`、网关 OAuth、AWS/GCP 配置和 `requires_openai_auth`；
- 传输与能力：能力覆盖标记、WebSocket 开关和独立 web search。

这些字段都以单值形式存在，没有端点列表。定义见 `codex-rs/model-provider-info/src/lib.rs:145-236`。

### 内置 Provider

内置表在构造时写入六个条目：

| ID | 运行时实现 | 默认认证 |
|---|---|---|
| `openai` | OpenAI 兼容 | `requires_openai_auth = true`，可走 ChatGPT 或 API Key |
| `amazon-bedrock` | Bedrock 专用实现 | AWS SigV4 或 Bedrock Key |
| `amazon-bedrock-runtime` | Bedrock 运行时变体 | 同上 |
| `gcp` | GCP 专用实现 | 默认 `gcloud` 命令取 access token |
| `ollama` | OpenAI 兼容 | 无认证，默认本机 11434 |
| `lmstudio` | OpenAI 兼容 | 无认证，默认本机 1234 |

内置 `openai` 的端点地址随认证方式变化：ChatGPT 类认证走 `https://chatgpt.com/backend-api/codex`，API Key 类认证走 `https://api.openai.com/v1`，用户显式配置了 `base_url` 时以配置为准。本地 OSS Provider 的地址和端口可以分别用环境变量 `CODEX_OSS_BASE_URL`、`CODEX_OSS_PORT` 覆盖（`codex-rs/model-provider-info/src/lib.rs:468-487、895-911`）。

### 自定义 Provider 的边界

配置里的同 ID 覆盖不是通用的。`openai` 只允许改 `model_catalog_url`，且必须是 HTTPS 的允许 ChatGPT 主机；Bedrock 只允许改端点、认证、AWS 配置和 Header；GCP 只允许改端点、认证、Header、项目、区域和凭据文件；其余新 ID 直接插入，已存在的同名项不会被覆盖（`codex-rs/model-provider-info/src/lib.rs:788-893`）。保留 ID 校验会拒绝把内置 ID 当作普通自定义 Provider 使用（`codex-rs/config/src/config_toml.rs:952-983`）。

因此，“同一 Provider 多 Endpoint”在本项目中不成立。可行的等价做法是：

- 为每个端点建立独立的 `model_providers.<自定义ID>`；
- 用 `model_provider` 或 profile 切换；
- 凭据可用各自的 `env_key`，也可共用全局 OpenAI 认证。

## 2. 配置生命周期与管理入口

### 配置分层与文件

Codex 的配置是带来源记录的分层结构，以下多层来源按优先级合并，单个文件只对应其中一层。优先级从低到高为：打包默认、MDM、系统、企业托管、用户、用户 profile、项目 `.codex`、会话覆盖、旧版托管配置（`codex-rs/config/src/config_layer_source.rs:39-62`）。用户配置文件名是 `config.toml`，位于 `$CODEX_HOME`（`codex-rs/config/src/lib.rs:57`）。

Profile 有两条路径：

- 旧式路径用 `profile` 键指向 `[profiles.<name>]` 表中的一组设置，字段定义见 `codex-rs/config/src/profile_toml.rs:18-67`；
- V2 路径由 `--profile <name>` 指定，直接加载 `$CODEX_HOME/<name>.config.toml`，该文件按带 profile 标记的用户层参与合并（`codex-rs/core/src/config/mod.rs:2154-2162`；`codex-rs/cli/src/main.rs:2009-2031`）。

CLI 的 `-p/--profile` 只对运行时命令、`codex mcp` 和迁移命令开放，配置管理类子命令会拒绝（`codex-rs/cli/src/main.rs:1956-1981`）。

### 默认配置与用户配置的合并

Provider 表先由内置构造函数按 OpenAI 基础地址生成，再与用户配置里的 Provider 表逐条合并。合成后的表决定配置指定的 Provider ID 能否解析：解析失败报“Provider not found”，旧 ID `ollama-chat` 另有专门的迁移提示（`codex-rs/core/src/config/mod.rs:4059-4086`）。Provider 条目的必填字段与保留 ID 在反序列化阶段就完成校验（`codex-rs/config/src/config_toml.rs:1025-1033`）。

### 各入口的实际操作覆盖

| 入口 | 查看 | 新增/编辑 | 复制/删除/启停 | 导入/导出/连接测试 |
|---|---|---|---|---|
| 配置文件 | 直接读取 `config.toml` 与 profile 文件 | 手工编辑 `model_providers`、`model_provider`、`profiles` | 删除即移除条目；启停靠切换 `model_provider` 或换 profile，没有 Provider 级 `enabled` 字段 | 本次未找到 Provider 配置导入/导出；测试见 `codex doctor` |
| CLI | `codex login status` 查看登录；`codex debug models` 输出模型目录 | `codex login` 写凭据；`-c` 覆盖任意配置键；`-p` 选 profile | `codex logout` 删除凭据；未找到 Provider 定义编辑、复制或启停子命令 | 未找到 Provider 配置导入/导出；`codex doctor` 提供认证与端点可达性检查 |
| TUI | 启动引导展示登录方式；`/model` 展示模型；设置页显示部分开关 | 引导流程写认证；`/model` 持久化模型；设置项写 `oss_provider`、feature、memory 开关 | 本次未找到 Provider 的创建、编辑、复制、删除或启停界面 | 未找到导入/导出；未找到 Provider 连接测试界面 |
| app-server / 桌面 | `config/read` 返回生效配置与层来源；`modelProvider/list` 返回只读的 Provider 摘要与可否编辑标记；`modelProvider/capabilities/read` 返回能力 | `config/value/write`、`config/batchWrite` 可按键路径写任意配置；`modelProvider/config/write` 按白名单字段给自定义网关、Bedrock、GCP 补丁 | 未找到 Provider 专用增删 RPC；编辑只到字段级补丁 | 未找到 Provider 导入/导出或专用连接测试 RPC；凭据恢复会发开始/完成通知 |
| 桌面端 | 当前快照没有桌面渲染器源码 | 未找到独立渠道管理实现；`codex app` 只负责启动安装器 | 未找到 | 未找到 |

CLI 的登录/登出分派在 `codex-rs/cli/src/main.rs:1641-1695`；`codex login --with-api-key` 从 stdin 读 key，`--with-access-token` 读访问令牌，默认走浏览器 OAuth，另有设备码流程（`codex-rs/cli/src/main.rs:516-556`）。

app-server 的通用写入参数是键路径加值，支持单值和批量；TUI 目前只用它写模型、服务档位、OSS Provider、feature 和 memory 设置，没有构造 Provider 对象（`codex-rs/app-server-protocol/src/protocol/v2/config.rs:1179-1214`；`codex-rs/tui/src/config_update.rs:56-152`）。

除此之外还多了一条**只读摘要 + 字段补丁**的通道。`modelProvider/list` 返回每个 Provider 的 id、显示名、端点和设置摘要，并给出“能否在当前用户层编辑”的标记；端点若不能安全展示就返回空值，调试输出里同样脱敏。`modelProvider/config/write` 只接受自定义网关、Bedrock、GCP 三组设置里的白名单字段，未知字段直接拒绝，写入目标是用户配置层（`codex-rs/app-server-protocol/src/protocol/v2/model_provider.rs:8-71`、`:238-250`；`codex-rs/app-server/src/config_manager_service_model_providers.rs:1-40`）。凭据恢复期间客户端还会收到开始与完成两条通知，用于在界面上提示重新登录而不是直接报错。

## 3. 凭据、Header 与代理边界

### 凭据来源与优先级

登录后的凭据统一表示为 `CodexAuth`，支持 API Key、ChatGPT OAuth、外部提供的 ChatGPT token、Header、Agent Identity、个人访问令牌、Bedrock Key 和 Bedrock 访问键（`codex-rs/login/src/auth/manager.rs:111-120`）。加载时的优先级是：

1. `CODEX_API_KEY` 环境变量（仅在该进程启用了这一入口时）；
2. 内存/外部注入的临时凭据；
3. `CODEX_ACCESS_TOKEN`，再分类为个人访问令牌或 Agent Identity JWT；
4. 配置指定的持久化存储（文件、keyring 或自动选择）。

这段顺序在 `codex-rs/login/src/auth/manager.rs:1591-1695`。`OPENAI_API_KEY` 另由登录命令和诊断读取，不作为自动请求凭据的同一入口（`codex-rs/login/src/auth/manager.rs:1036-1054`）。

Provider 自身还有一层优先级：如果配置了 `env_key` 且环境变量非空，它先于全局认证生效；其次是 `experimental_bearer_token`；然后才判断是否需要 OpenAI 认证。若 Provider 既不要求 OpenAI 认证也没有命令式 auth，则请求不带认证头；Bedrock 专用凭据遇到这种解析会被判为不支持的操作（`codex-rs/model-provider/src/auth.rs:296-314`、`:317-342`）。命令式 auth 会为该 Provider 单独构造一个只做外部 Bearer 的认证管理器。

Agent Identity 再叠一层解析顺序：当前认证已是 Agent Identity 时直接使用；策略要求引导时向认证管理器换取 Agent Identity 凭据；引导不可用则记录告警并在本会话退回 ChatGPT bearer，而不是让整条链路失败（`codex-rs/model-provider/src/auth.rs:344-405`）。

**另有两类自动化凭据。** 一类是 API workload identity：进程提供了工作负载身份令牌与联邦规则时，先把它交换成 API Key，再走常规 API Key 路径，令牌文件与上下文经环境变量传入（`codex-rs/login/src/auth/workload_identity.rs:1-40`）。另一类是运行时注册凭据：核心构建一份运行时凭据上下文供线程与第一方 API 客户端共享，它与 Provider 认证是两套对象（`codex-rs/core/src/runtime_auth.rs:1-30`）。

### 存储位置与加密

| 模式 | 位置 | 保护方式 |
|---|---|---|
| `file`（默认） | `$CODEX_HOME/auth.json` | 明文 JSON；Unix 上以 `0600` 创建 |
| `keyring` | 操作系统钥匙串 | 直接存序列化后的认证 JSON |
| `auto` | 优先 keyring，不可用则退回文件 | 运行时选择 |
| `ephemeral` | 仅当前进程内存 | 不落盘 |

模式定义在 `codex-rs/config/src/types.rs:136-148`。文件写入逻辑见 `codex-rs/login/src/auth/storage.rs:274-294`；keyring 还分“直接存钥匙串”和“钥匙串保存文件密钥、密文写本地 secrets 文件”两种后端，Windows 默认后者，其他平台默认前者（`codex-rs/config/src/types.rs:167-183`）。

落盘另有两道进程与权限保护：凭据提交通过一个稳定 sidecar 文件加锁串行化，使多个进程的写入可以按“先比较再保存”的语义排队，网络请求期间不持有该锁（`codex-rs/login/src/auth/storage_commit.rs:1-22`）；Windows 上替换凭据文件时先用目标文件自己的 DACL 创建新文件，再写入密文，避免新文件继承更宽的父目录权限（`codex-rs/login/src/auth/storage_file_windows.rs:1-26`）。

`AuthDotJson` 包含 `auth_mode`、`OPENAI_API_KEY`、OAuth token 集、最近刷新时间、Agent Identity、个人访问令牌、Bedrock 两类凭据（`codex-rs/login/src/auth/storage.rs:51-77`）。这是一个“当前账号”结构，不是多凭据列表，因此没有多 Key 池。

### Header 与脱敏

Provider 可配置静态 Header 和“Header 名 → 环境变量名”的动态 Header；动态 Header 在变量缺失或为空时被跳过（`codex-rs/model-provider-info/src/lib.rs:198-207、440-466`）。`base_url`、Header 值、查询参数和实验性 Bearer 使用 `RedactedString` 保存，调试输出不直接展开密钥（`codex-rs/model-provider-info/src/lib.rs:166-202`）。认证 Header 在网关 OAuth 组合路径中也会被标记为 sensitive（`codex-rs/model-provider/src/combined_auth.rs:69-96`）。

`responses-api-proxy` 划出另一条凭据边界：key 由使用方从 stdin 传入，进程只接受 `POST /v1/responses` 一种请求，转发时改写认证头与 `Host`。它的 dump 文件会把认证头和含 `cookie` 的头一并脱敏（`codex-rs/responses-api-proxy/README.md:31-55、150-152`）。

### 出站代理

Codex 的出站 HTTP 客户端有显式代理策略。`RespectSystemProxy` 的顺序是“系统/PAC/WPAD → 环境变量 → 直连”；环境变量回退会按目标 scheme 读取 `HTTPS_PROXY`、`HTTP_PROXY`、`ALL_PROXY` 等同一组代理变量（`codex-rs/http-client/src/outbound_proxy.rs:100-105、381-405`）。

是否启用这一顺序由 feature 开关 `respect_system_proxy` 决定，配置层按开关值为 HTTP 客户端工厂选定代理策略。代理 URL 与 no-proxy 值在调试输出中统一显示为 `<redacted>`（`codex-rs/core/src/config/mod.rs:1819-1824、3191-3197`；`codex-rs/http-client/src/outbound_proxy.rs:127-158`）。

## 4. 模型目录与能力元数据

模型目录是与 Provider 配置分开的数据源。内置快照编译进二进制，取自 `models.json`，为每个模型记录 slug、显示名、上下文窗口、最大上下文、自动压缩阈值、推理档位、工具类型和输入模态等元数据（`codex-rs/models-manager/src/lib.rs:18-20`；`codex-rs/models-manager/models.json:1-45`）。这些元数据中没有价格或计费字段，`ModelInfo` 结构同样没有 cost 字段（`codex-rs/protocol/src/openai_models.rs:428-497`）。

远端刷新走 Provider 的 `/models` 端点：

- 默认路径是 `base_url + "/models"`，可带 `client_version` 查询参数；
- 可配置 `model_catalog_url` 指向完整的 Codex 目录地址；
- OpenAI 在 API Key 且未设置端点时，目录请求改走 Codex 后端，而不是公共 `/v1/models`；
- 返回 ETag 用于条件刷新。

相关实现见 `codex-rs/model-provider/src/models_endpoint.rs:49、170-204` 与 `codex-rs/models-manager/src/manager.rs:755-794`。

磁盘缓存位于 `$CODEX_HOME/models_cache.json`，默认 TTL 300 秒；刷新失败时沿用上一次成功快照，缓存内容保持不变，失败不会被当成空目录（`codex-rs/models-manager/src/manager.rs:41-42、653-692`）。用户也可以用 `model_catalog_json` 指定一个本地 JSON 目录，启动时加载并覆盖常规目录来源（`codex-rs/core/src/config/mod.rs:2271-2298、4314`）。

目录条目还带来源标记：Provider 原始响应里的模型 id 在合并前单独记录，与生效目录共用一把锁；遍历目录时据此把条目区分为“来自 Provider”还是“内置快照”，缓存文件和目录线格式都不因此改变（`codex-rs/models-manager/src/catalog.rs:27-77`）。

模型选择规则是：显式 `model` 优先；没有显式值时从可用目录取默认模型。若开启“允许 Provider 模型回退”，请求的模型不在当前 Provider 目录中时会替换为该 Provider 的默认模型，并记录日志（`codex-rs/models-manager/src/manager.rs:996-1022`；`codex-rs/core/src/session/mod.rs:853-863`）。这是同一 Provider 内的模型回退，不是 Provider 之间的故障转移。

## 5. 协议、请求组装与流式传输

当前快照只实现 Responses 协议。`WireApi` 枚举只有 `Responses` 一个取值；`chat` 会在反序列化时触发带迁移说明的错误（`codex-rs/model-provider-info/src/lib.rs:113-142`）。因此本项目没有 OpenAI Chat Completions、Anthropic Messages 或 Gemini 原生协议的 Adapter 层；兼容性依靠“对方实现 Responses 兼容端点”。

请求体结构由 `ResponsesApiRequest` 定义，涵盖模型、流式开关、服务档位、输入项、工具与工具选择、并行工具调用、推理配置、存储标记与 include 列表、`prompt_cache_key`、文本控制、客户端元数据和访问程序等字段（`codex-rs/codex-api/src/common.rs:281-306`）。发送端把请求编码成 JSON，补上会话、线程和子代理相关的 Header，声明 `Accept: text/event-stream`，按需做 zstd 压缩，最后 POST 到 `/responses`（`codex-rs/codex-api/src/endpoint/responses.rs:70-157`）。

URL 与认证在 `EndpointSession` 一处收口：请求先按 Provider 提供的地址和路径拼出，发送前再由认证提供者补上 Header，配置了重试策略时就在同一份已构造的请求上重试。这些 Header、缺省地址和重试参数在组装 `ApiProvider` 时已经确定，缺省地址随认证模式变化（`codex-rs/codex-api/src/endpoint/session.rs:48-111`；`codex-rs/model-provider-info/src/lib.rs:469-517`）。

除 HTTP SSE 外，支持 WebSocket 的 Provider 还可以走 Responses WebSocket；客户端按 Provider 能力与会话回退状态选择，失败后可回退到 HTTP（`codex-rs/core/src/client.rs:1174-1183、2029-2067`）。这属于同一协议下的传输选择，不是另一套渠道协议。

Azure 没有独立 Adapter。它被识别为 Responses 兼容端点，通过自定义 `base_url` 和 `query_params` 表达部署名与 `api-version`；代码中只有 URL 识别辅助函数，没有单独的 Azure 请求体构造器（`codex-rs/codex-api/src/provider.rs:1-23`；`codex-rs/codex-api/src/endpoint/models.rs:220-248`）。

## 6. 运行时选择、会话绑定与策略

运行时选择分两步：先选 Provider ID，再选模型。Provider ID 的优先级是策略强制值、会话/CLI 显式覆盖、`config.model_provider`，最后默认 `openai`（`codex-rs/core/src/config/mod.rs:4072-4075`）。模型则由 `config.model`、profile 或目录默认值决定（`codex-rs/models-manager/src/manager.rs:996-1022`）。

TUI 在向 app-server 发请求时会区分“显式 Provider 选择”和“让服务端解析默认值”。只有会话标志或带 profile 的用户层显式写了 `model_provider`，才会作为显式值传出（`codex-rs/tui/src/app_server_session/provider_selection.rs:8-38`）。

会话是 Provider 锁定的。app-server 在恢复会话和接收新输入时会比较会话保存的 Provider 与当前配置；不一致返回 `ModelProviderMismatch`，Provider 不存在返回 `ModelProviderNotConfigured`，与组织策略冲突返回 `ModelProviderPolicyConflict`（`codex-rs/app-server/src/config_manager.rs:437-455、560-610`）。这使“切换 Provider 后继续旧会话”变成显式失败，而不是静默把历史发给另一个后端。

本次未找到别名、语义路由、加权负载均衡或按请求动态选 Provider 的实现。`model_provider` 是单一 ID；Provider 表是普通映射，没有路由器或权重字段。

## 7. 多 Key、限流、重试与故障转移

### 多 Key 与健康状态

凭据模型是单值：`AuthDotJson` 只有一个 API Key 字段和一组 OAuth token；`ModelProviderInfo.env_key` 也只指向一个环境变量（`codex-rs/login/src/auth/storage.rs:51-77`；`codex-rs/model-provider-info/src/lib.rs:167-168`）。本次未找到 Key 池、轮询、冷却、熔断或健康状态持久化。`codex doctor` 的检查是一次性诊断，不构成运行时健康状态。

### 重试层级

| 层级 | 行为 | 证据 |
|---|---|---|
| HTTP 请求重试 | 默认重试预算 4，循环含首次尝试最多 5 次；5xx 与传输错误重试，429 在 HTTP 层不重试；指数退避基数 200ms | `codex-rs/model-provider-info/src/lib.rs:496-502、540-545`；`codex-rs/codex-client/src/retry.rs:23-47、93-107` |
| 流式重连 | 默认最多 5 次；采样请求的连接失败另走独立连接退避（5 秒起、60 秒封顶），重连预算与请求预算分开 | `codex-rs/core/src/responses_retry.rs:23-24、32-166`；`codex-rs/model-provider-info/src/lib.rs:547-552` |
| 401 恢复 | 遇到可恢复的 401 时尝试刷新凭据并重放当前请求；Provider 可自定义是否可恢复 | `codex-rs/core/src/client.rs:1952-1978`；`codex-rs/model-provider/src/provider.rs:188-197` |
| 传输回退 | WebSocket 失败后关闭该会话的 WebSocket 并回退 HTTP | `codex-rs/core/src/client.rs:781-794` |

Provider 配置可以分别覆盖请求重试、流重连、流空闲超时和 WebSocket 连接超时（`codex-rs/model-provider-info/src/lib.rs:208-217`）。服务端返回的 `Retry-After` 会参与等待决策，但不会扩大配置的重试上限（`codex-rs/core/src/responses_retry.rs:55-166`）。

### 故障转移边界

跨 Provider failover 本次未找到。客户端持有的是单个 `SharedModelProvider`，请求失败后只会走同一 Provider 的重试/刷新路径；没有“候选 Provider 列表”或切换逻辑（`codex-rs/core/src/client.rs:1941-1990`）。会话层的 `allow_provider_model_fallback` 只影响模型选择，不改变 Provider（`codex-rs/core/src/session/mod.rs:853-863`）。因此多 Provider 配置只决定可选范围，运行时请求始终落在当前选定的那个 Provider 上。

## 8. 可观测性、诊断与连接检测

- **模型目录查看**：`codex debug models` 把二进制内置的原始模型目录 JSON 直接打到标准输出，用来核对当前目录内容（`codex-rs/cli/src/main.rs:261-263`）。
- **认证诊断**：`codex doctor` 的 auth 检查读取存储模式、`auth.json`、已设置的认证环境变量和存储中的凭据类型，逐项给出状态与修复提示（`codex-rs/cli/src/doctor.rs:1229-1321`）。
- **端点可达性**：doctor 用 Provider 的目录地址或基础地址发 HEAD/GET 探测，只看连通性和响应状态，不发送模型输入（`codex-rs/cli/src/doctor.rs:2740-2897`）。
- **限流与额度**：响应头里的 `x-codex-*` 字段被解析成限流快照，含主/次窗口、重置时间、credits 余额与促销信息（`codex-rs/codex-api/src/rate_limits.rs:23-100、195-259`）。
- **token 用量**：SSE 完成事件带回 usage，写入会话遥测并参与上下文预算计算（`codex-rs/core/src/client.rs:2646-2671`）。
- **日志边界**：请求 span 只记录模型 slug、线协议和传输类型，不带请求体；配置中的敏感值以 `RedactedString` 保存，调试输出不展开（`codex-rs/core/src/client.rs:1802-1813、2087-2098`）。

连接测试与真实请求是两条路径：doctor 的探测只验证 DNS/TCP/TLS/HTTP 可达性和 `/models` 响应状态，不会发送模型输入，也不会验证具体模型是否可用。

## 9. 设计取舍与已确认边界

- **配置驱动而非界面驱动**：Provider 的完整能力通过 TOML 暴露，换来了字段覆盖和分层策略，但没有 GUI 的表单校验、复制和连接测试。
- **单端点单凭据**：结构简单，适合“一个后端一个 ID”的用法；多端点、多 Key 需要用户在配置层自行拆分。
- **协议收敛到 Responses**：减少 Adapter 维护面，但也意味着非 Responses 兼容服务必须经过转换代理；仓库内提供的 `responses-api-proxy` 是转发代理，不是协议转换器。
- **会话 Provider 锁定**：避免历史被静默发往另一个后端，代价是切换 Provider 后旧会话不能直接继续。
- **内置目录与远端目录并存**：离线可用，但目录新鲜度依赖 TTL、ETag 和 Provider 的 `/models` 实现；目录失败时保留旧快照。
- **重试只在同一 Provider 内**：没有跨 Provider 的自动降级；高可用需要外部编排或用户手动切换。

## 10. 未验证事项

- 未运行真实的 ChatGPT OAuth、设备码、API Key、Bedrock 或 GCP 登录，未验证各平台 keyring 后端的实际可用性。
- 未对真实 Provider 发起 `/responses` 或 `/models` 请求，未验证 SSE 事件顺序、压缩兼容性、WebSocket 回退的实际触发条件。
- 未验证 `models.json` 与远端目录在真实账号下的差异，也未验证模型目录缺失时 `ModelInfo` 回退元数据的具体表现。
- 未验证 `codex doctor` 在不同网络环境下的探测结果，以及系统代理/PAC/WPAD 在各平台的实际行为。
- 未检查桌面端渲染器（当前快照没有对应源码），因此“桌面端没有渠道管理界面”只表示本次未找到，不是项目级结论。

## 11. 关键源码索引

- `codex-rs/model-provider-info/src/lib.rs`：Provider 结构、内置表、合并规则、`ApiProvider` 组装、重试默认值、OSS Provider。
- `codex-rs/config/src/config_toml.rs`：配置 schema、Provider 保留 ID 与校验。
- `codex-rs/config/src/config_layer_source.rs`：配置层来源与优先级。
- `codex-rs/core/src/config/mod.rs`：配置加载、Provider 合并、`model_provider_id` 解析、模型目录 JSON 加载。
- `codex-rs/model-provider/src/provider.rs`：运行时 Provider 选择与凭据解析入口。
- `codex-rs/model-provider/src/auth.rs`：Provider 级凭据优先级与认证提供者构造。
- `codex-rs/login/src/auth/manager.rs`：认证加载顺序、`CodexAuth` 变体。
- `codex-rs/login/src/auth/storage.rs`：`auth.json` 结构与文件/keyring 存储。
- `codex-rs/codex-api/src/endpoint/responses.rs`：`/responses` 流式请求。
- `codex-rs/codex-api/src/common.rs`：`ResponsesApiRequest` 字段契约。
- `codex-rs/models-manager/src/manager.rs`：目录缓存、刷新、默认模型与模型回退。
- `codex-rs/model-provider/src/models_endpoint.rs`：`/models` 目录端点与认证。
- `codex-rs/cli/src/main.rs`：登录/登出、profile、`debug models`。
- `codex-rs/cli/src/doctor.rs`：认证与端点可达性诊断。
- `codex-rs/app-server-protocol/src/protocol/v2/config.rs`：通用配置读写。
- `codex-rs/app-server/src/config_manager.rs`：会话 Provider 绑定与策略冲突。
- `codex-rs/responses-api-proxy/README.md`：代理边界与凭据处理。
