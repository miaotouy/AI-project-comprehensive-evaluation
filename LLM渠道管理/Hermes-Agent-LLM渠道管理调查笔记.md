# Hermes-Agent（hermes-agent）LLM 渠道管理调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：全量源码静态阅读 + git 历史核查；补查 CLI、TUI、Web、Electron Desktop 的渠道管理入口；未运行程序、未发起真实请求
>
> 调查范围：Provider 注册与插件发现、自定义端点配置、配置文件/CLI/TUI/Web/Desktop 的查看与管理操作、凭据存储/访问/脱敏/导出、模型目录来源、transport 协议适配、运行时 Provider 解析与 fallback 链、credential pool 多 Key 轮换与冷却、连接检测与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **无“LLM 渠道”实体**。本仓库用两层声明表示 LLM 提供方：`providers/base.py` 的 ProviderProfile 说明它是什么，`hermes_cli/auth.py` 的凭据表 `PROVIDER_REGISTRY`（当前实现为按 profile home 分层的 `HomeScopedRegistry`）说明它有哪些凭据。用户配置时只引用这两层已有声明，不会创建 Provider 实例，代码里也没有“渠道（channel）”这一概念。
- **自定义端点承担渠道角色**。用户实际创建的是配置中的端点条目：新 schema 从 v12 起用键控的 `providers:`，旧写法用 `custom_providers:` 列表（默认值定义在 `hermes_cli/config_defaults.py`），每个条目记录 base_url、凭据来源 key_env 或 api_key，以及可选的 extra_headers。因此“渠道”在本项目中落成「Provider 标识 + 一个 base_url + 一份凭据」的组合；一个内置 Provider 默认对应一个配置块，需要多端点时用多条 custom_providers 条目表达。
- **管理入口并不对称**。配置文件与 Desktop 的自定义端点页可以直接查看并增删改端点；CLI、TUI 和 Web 主要管理 Provider 凭据、模型选择或整个 Profile，其中未找到针对 `providers.<name>` 的同等端点增删改页面。Desktop 的“Use”把某个端点设为当前主模型，端点自身没有独立的启用开关。
- **运行时可动态切换，启动解析与聊天链路走不同代码路径**。真实聊天由 `resolve_runtime_provider()`（`hermes_cli/runtime_provider.py`）解析出运行时参数，再交给 transport 组装请求；桌面和 Web 设置页的连接测试则走独立的 HTTP 探测，由 `hermes_cli/web_routers/config_env.py` 的 `/api/providers/validate` 与 `/api/providers/custom-endpoints/validate` 直接请求端点，这条路径不经过真实 resolver，两者探测的范围和失败语义并不一致（详见 §8）。
- **凭据分层存储、可按需配置，删除与卸载时清理整条链路**：
  - API Key 默认写入 `.env`，读写由 `hermes_cli/config.py` 统一承担；OAuth 和跨渠道凭据写入 `auth.json`，路径与版本定义在 `hermes_cli/auth.py` 的 `_auth_file_path`；
  - `.env` 中的任意值都可以借入 credential pool，池条目存放在 `auth.json` 的 `credential_pool` 键下，读写入口见 `hermes_cli/auth.py:1688`；
  - 子进程的环境变量按白名单脱敏后才交付，日志、UI 和备份导出同样脱敏（§3）。
- **模型目录由静态表、远端拉取和用户输入三层构成**：
  - 静态快照存放在 `hermes_cli/models.py` 的 `_PROVIDER_MODELS`；
  - OpenRouter 与 Nous Portal 的模型列表从远端拉取，结果缓存到 `provider_models_cache.json`，拉取与缓存逻辑同在该文件（`models.py:955`）；
  - 用户也可以在模型选择器里手动填写模型名；
  - 自定义端点的 `/v1/models` 探活结果另有一份磁盘缓存，实现在同一文件。
  能力与上下文长度等元数据集中在 `agent/model_metadata.py`，provider 前缀在那里实时查询注册表。
- **协议适配集中在 transport 层**：`agent/transports/__init__.py` 按 `api_mode` 注册和分发实现，对外提供注册与获取两个入口，覆盖 OpenAI 兼容、Anthropic、Responses、Bedrock 等模式（清单见 5.1）。请求参数由 transport 的 `build_kwargs` 组装，profile 存在时交给 `agent/transports/chat_completions.py` 按 profile 字段重建参数。Provider 本身不持有运行时客户端。
- **重试、Key 轮换、模型 fallback、跨渠道 failover 分四层**，各层的触发条件与完整定位见 §7：
  - 应用层重试：由配置项 `agent.api_max_retries` 控制，默认 3 次，定义在 `hermes_cli/config_defaults.py`；
  - 同 Provider 多 Key 轮换：遇到 429、401 或供应商报错后，由 credential pool 换用下一个 Key；
  - 跨渠道 fallback 链：由 `fallback_config.py` 读取链，`chat_completion_helpers.py` 逐项推进；
  - 会话层恢复：由 `restore_primary_runtime` 切回主通道（`agent/agent_runtime_helpers.py`）。
- **可观测性**：`hermes doctor` 负责连接健康检查，具体探测在 `hermes_cli/doctor_connectivity.py`，`--live` 的真实元数据探针见 §8；日志脱敏在 `agent/redact.py`；模型目录使用全局的 `provider_models_cache.json` 缓存。用量与成本由各自的 provider resolution 和 usage tracker 处理，本次不在范围内。

---

## 概念模型（本项目的 Provider / 渠道 / Endpoint / 模型 / 凭据 / Profile）

为避免跨层混淆，先定义本项目各概念含义（均为静态代码确认）：

- **Provider（提供方标识）**：代码/插件注册声明的 `ProviderProfile`（`providers/base.py`），字段：

  ```
  name / api_mode / aliases / env_vars / base_url / auth_type / display_name /
  description / signup_url / default_aux_model / supports_health_check
  ```

  它是声明性的：`providers/base.py` 明确写出“不持有客户端构造、凭据轮换、流式”。Provider 不是用户实例，也不是运行时连接。
- **渠道 / Endpoint（端点实例，即“渠道”等价物）**：用户在配置中定义的 `providers:<name>:`（字段见下），或 legacy `custom_providers` 列表条目（`hermes_cli/config.py get_compatible_custom_providers` 把两者合并为统一视图）。运行时会为每个条目解析出一个具体 base_url + 凭据通道：

  ```
  base_url / key_env / api_key / model / max_output_tokens / extra_headers
  ```

  同一厂商可以配置多个端点，对应多条 custom 条目；内置 Provider 是例外，每个只有一套预设的 base_url 和凭据环境变量，这些预设由 `PROVIDER_REGISTRY` 声明。
- **Profile（HERMES_HOME）**：当前活动配置目录，由 `hermes_constants.get_hermes_home()` 读取。所有凭据、配置、缓存均按 Profile 隔离；`agent/secret_scope.py` 提供 scope 装配入口，网关 multiplex 多 Profile 时以 `set_multiplex_active` 强制限定环境变量访问范围。
- **Model（模型 ID）**：`model:` 配置中的 `default:`，或者每个 fallback 条目里的 `model:`。可为任意用户输入字符串，也来自静态表 / 远端拉取。
- **Credential（凭据）**：API Key / access_token；存放于 `.env` 的 `api_key`、`auth.json` 的 provider 状态、config.yaml 内嵌 api_key（不推荐），或外部进程/OAuth 文件。凭据的“借用”进入 credential pool 即复制一份放入 `auth.json`，由 `agent/credential_pool.py` 的 PooledCredential 管理。
- **Fallback 链（故障转移“跨渠道”）**：可在配置里定义 `fallback_providers` / legacy `fallback_model`（顶层，见 `cli-config.yaml.example` 与 `hermes_cli/fallback_config.py get_fallback_chain`）。每条 fallback 条目 = provider + model + base_url + api_key/key_env；运行时按顺序尝试，属于**跨渠道（端点）故障转移**，不是同渠道重试。

---

## 总体调用链

以 CLI 真实对话为例（静态代码路径）：

1. CLI 组装 AIAgent，并向它传入 provider、model、base_url、api_key 和 credential_pool 等参数；组装入口在 `cli.py` 的 `create_agent`，初始化代码在 `agent/agent_init.py`。
2. 启动时的输入之一来自 `load_config`：`cli.py` 用 `get_fallback_chain(CLI_CONFIG)` 读出 fallback 链，存入 `_fallback_model`。
3. AIAgent 内部调用 `resolve_runtime_provider`（`hermes_cli/runtime_provider.py`），确定可用的 provider、api_mode、base_url 和 api_key，并据此生成 transport 组件。
4. transport 组件由 `get_transport(api_mode)`（`agent/transports/__init__.py`）取得，随后 `build_kwargs` 组装请求体；profile 存在时走 `agent/transports/chat_completions.py` 的 profile 分支。
5. 会话循环处理重试、429 和 credential pool 恢复；池用尽后调用 `try_activate_fallback`（`agent/chat_completion_helpers.py`）推进 fallback 链，并用 `create_openai_client` 重建 transport（`agent/agent_runtime_helpers.py`）。
6. 响应输出后，由 `agent.conversation_loop` 交给 `result_to_console` 展示。

Gateway/TUI 复用同样的 `load_config` / `resolve_runtime_provider` 路径（`hermes_cli/runtime_provider.py` 文档注释即宣称“共用”）；multiplex 时每请求装配 profile secret scope（`gateway/run.py`）。

---

## 1. Provider 注册、渠道数据模型与配置

### 1.1 Provider 注册（插件化）

- **扫描机制**：Provider 注册采用懒发现，`providers/__init__.py` 的 `_discover_providers()` 在被查询时才扫描可用插件；对外入口是该文件的 `register_provider()`、`get_provider_profile()` 和 `list_providers()`。
- **扫描顺序**：先查仓库内的 `plugins/model-providers/<name>/`，再查 `$HERMES_HOME/plugins/model-providers/<name>/`，最后回退到 legacy 的 `providers/<name>.py`（兼容逻辑见 `providers/__init__.py` 的 docstring）。后注册的同名插件覆盖先前的注册，以最后写入者为准。
- 仓库内共 40 个模型提供插件目录，位于 `plugins/model-providers/` 下，包含 anthropic、openrouter、gemini、custom、azure-foundry、bedrock 等。示例：
  - anthropic 插件使用 `anthropic_messages` 模式，凭据取 `ANTHROPIC_API_KEY/ANTHROPIC_TOKEN/CLAUDE_CODE_OAUTH_TOKEN` 三个环境变量，base_url 为 `https://api.anthropic.com`，认证类型是 `api_key`；定义见 `plugins/model-providers/anthropic/__init__.py`。
  - custom 插件（`plugins/model-providers/custom/__init__.py`）面向自定义和 Ollama 类本地服务，使用 `chat_completions` 模式，并实现 `build_extra_body` 与 `build_api_kwargs_extras` 两个扩展点来处理 Ollama 的 `num_ctx` 等参数。
  - gemini 插件的 docstring 与实现都声明 `chat_completions` 模式，实际却用 GeminiNativeClient 绕过标准 transport（`plugins/model-providers/gemini/__init__.py`）。这说明 api_mode 只用于挑选 transport，最终 client 仍由插件和运行时决定。
  - openrouter 插件充当代理，并实现了自定义的 `fetch_models`（`plugins/model-providers/openrouter/__init__.py`）。

### 1.2 统一 Provider 目录（可观察源）

`provider_catalog()` 在 `hermes_cli/provider_catalog.py` 中把 provider 全量枚举（`hermes_cli/models.py` 的 `CANONICAL_PROVIDERS`）与 `PROVIDER_REGISTRY` 的 auth_type、凭据 env、profile 的 display 元数据组装成统一目录，驱动 CLI/TUI 的模型选择器和桌面 Settings → Providers 两个 Tab（Accounts / API keys）；该文件 docstring 声明这份 parity 契约。

### 1.3 配置 schema（用户可创建多个 Endpoint）

顶层（`cli-config.yaml.example` 及各行）三类配置键：

```text
model.default / model.provider / model.base_url / model.api_key    # 主模型
fallback_providers: [ {provider, model, base_url, key_env/api_key}... ]  # fallback 链
providers.<name>: （v12+）与 legacy custom_providers: [...]         # 自定义端点
```

`providers.<name>:` 与 legacy `custom_providers` 二者由 `get_compatible_custom_providers()`（`hermes_cli/config.py`）去重合并为同一视图，供设计层与 UI。

### 1.4 配置加载与合并

- 配置加载由 `hermes_cli/config.py` 的 load_config 先合并 `hermes_cli/config_defaults.py` 的 `DEFAULT_CONFIG`，再合并用户 YAML；同文件的只读变体返回只读 dict，避免触发迁移。迁移逻辑在 `hermes_cli/config_migrations.py`，版本号逐步抬到 12+。

---

## 2. 配置创建、持久化与迁移

- **自定义端点创建/删除**：Desktop Settings 的 Custom endpoints 视图经由 `hermes_cli/web_routers/config_env.py` 提供的 custom-endpoints 路由完成创建、删除与激活，写回 `config.yaml` 的 `providers` 段。Web Dashboard 当前只使用同一服务中的 `/api/env`、模型和 OAuth 页面；本次未找到它调用这些 custom-endpoints 路由的页面代码。

  - 校验：`POST /api/providers/custom-endpoints/validate` 与 `POST /api/providers/validate` 两个路由都由 web_server 直接用 httpx 向端点的 `/models` 发探活请求，判定规则见 §8。
- **`.env` 写入**：收到 `PUT /api/env` 后，服务端调用 `save_provider_env_credential` 写入 `.env`，并同步更新 config.yaml 里的镜像值；实现在 `hermes_cli/credential_lifecycle.py`。
- **`.env` 删除**：收到 `DELETE /api/env` 后，服务端清掉 `.env` 条目、池中由环境变量播种的条目，以及 `model.api_key` 等镜像值和相关引用；实现在 `hermes_cli/credential_lifecycle.py`。
- **读取编码**：`auth.json`/`.env` 的读取统一为 UTF-8（BOM 容错），避免 Windows 代码页损坏导致凭据丢失（`hermes_cli/auth.py`、`env_loader.py`）。
- **auth.json**：版本 `AUTH_STORE_VERSION = 1`（`hermes_cli/auth.py`）；路径 `_auth_file_path`（`auth.py`）→ `~/.hermes/auth.json`。结构至少含：

  ```
  {"version":1, "providers": {...}}   # 必选
  credential_pool: {provider_id: [entry, ...]}   # 可选，写回时合并
  ```

  池的读写见 §7；env 凭据刷新后池条目 id 会重新绑定（`agent/agent_runtime_helpers.py`）。
- **迁移**：`hermes_cli/config_migrations.py` 处理 config schema 升级；`AUTH_STORE_VERSION=1` 固定。

### 2.1 配置文件与各平台操作覆盖

以下矩阵针对“渠道等价物”（`providers.<name>` / legacy `custom_providers`）和其凭据管理分别记录。静态源码能够确认入口和写入目标；是否在具体安装、浏览器权限或平台环境中成功执行，本笔记未运行验证。

| 入口 | 查看 | 新增 | 编辑 | 复制 | 启用/停用 | 删除 | 导入/导出 | 连接测试 |
|---|---|---|---|---|---|---|---|---|
| `config.yaml` / `.env` / `auth.json` | **源码确认**：手工查看；`config.yaml` 保存模型和端点，`.env` 保存密钥，`auth.json` 保存 OAuth/pool | **源码确认**：手工添加 `providers.<name>`、legacy `custom_providers` 或 `.env` 键 | **源码确认**：手工修改；`hermes config edit/set/unset` 也写配置 | **未找到**专门的端点复制语法；可由用户手工复制配置块，但不属于 Hermes 的原子操作 | **源码确认**：把端点写入主 `model.provider` 等字段即可作为当前端点；未找到端点级 `enabled: false` 生命周期 | **源码确认**：手工删除配置块和相关凭据；自动清理只在 API/CLI 的对应删除路径中成立 | **不适用**于单个端点；Profile/archive 可整体导入导出，见下行 | **不适用**；文件编辑本身不发起探测 |
| CLI（经典 CLI/子命令） | **源码确认**：`hermes config show/get`、`hermes auth list/status`、`hermes profile show`、`hermes model` | **源码确认**：`hermes auth add <provider>` 添加池凭据；自定义端点没有专门 CRUD 子命令，需 `hermes config set` 或编辑 YAML | **源码确认**：`hermes config edit/set/unset`；`hermes auth add` 可追加/轮换凭据 | **未找到**Provider/端点复制命令；`hermes profile create --clone/--clone-all` 复制的是整个 Profile，不是单个端点 | **源码确认**：`hermes model` / `/model` 选择当前 Provider+模型；`hermes auth reset` 清除耗尽状态；未找到端点级启停命令 | **源码确认**：`hermes auth remove <provider> <index|id|label>`、`hermes auth logout <provider>` 删除/注销凭据；未找到单个 custom endpoint 删除命令 | **源码确认**：`hermes profile export/import` 与 `/export`、`/import`；另有 `hermes backup` 全 Home ZIP。它们是 Profile/Home 级，不是端点级 | **源码确认**：`hermes doctor` / `hermes doctor --live`；未找到专门的“测试当前自定义端点”CLI 命令 |
| TUI（`hermes --tui`） | **源码确认**：模型选择器通过 `model.options` 展示 Provider、当前状态、模型列表和未配置提示 | **源码确认**：对 API-key Provider 输入 key，调用 `model.save_key` 写 `.env`；未找到新建 `providers.<name>` Endpoint 表单 | **不适用**于端点字段编辑；可重新保存 API key，模型选择通过 `model` 选择器完成 | **未找到** | **源码确认**：选择模型并以会话或 `--global` 持久化；Ctrl+D 进入 disconnect；未找到独立 endpoint enabled 开关 | **源码确认**：`model.disconnect` 清理 API key/OAuth 状态和关联缓存；不是删除 Provider 注册项或配置端点 | **未找到**TUI 的 Profile/端点导入导出界面；Profile 命令属于 CLI 层 | **未找到**专门的连接测试按钮；`model.options` 可刷新/拉取模型，属于目录获取而非独立健康测试 |
| Web Dashboard | **源码确认**：`EnvPage` 查看 Provider 分组、脱敏 key、OAuth 状态；`ModelsPage`/`/api/model/options` 查看模型目录 | **源码确认**：可新增任意自定义 `.env` 键；未找到 Web 页面新增 `providers.<name>` 自定义端点表单 | **源码确认**：编辑/替换/清除 `.env` key，OAuth 登录/注销；未找到端点字段编辑 UI | **未找到** | **源码确认**：模型页可选择当前模型/Provider；未找到端点级启停 | **源码确认**：删除 `.env` key、OAuth provider；未找到 Web 自定义端点删除 UI | **未找到**Web Dashboard 的端点或 Profile 导入导出页面；服务端仍有 REST/命令层能力 | **源码确认**：凭据 UI 的 `/api/providers/validate` 只覆盖少数内置 key；自定义 `.env` key 未配置 probe 时返回不可验证但不阻断。未找到自定义端点表单测试入口 |
| Electron Desktop Settings | **源码确认**：Providers 的 Accounts、API keys、Custom endpoints 三个视图；端点列表显示 URL、模型、key 预览、当前状态 | **源码确认**：`CustomEndpointsSettings` 的 Add Endpoint 表单，POST `/api/providers/custom-endpoints` | **源码确认**：点击已有端点载入表单后保存；后端合并保留未被 UI 展示的 `api_mode`、`key_env`、`extra_headers` 等字段 | **未找到**专门复制按钮；可点击已有端点后用“New endpoint”重新填写，但不是复制 | **源码确认**：Use 调用 `.../:id/activate`，写入主 `model`；未找到端点级停用，当前端点始终有一个主模型绑定语义 | **源码确认**：非 `direct-config` 端点可删除；删除同时移除关联环境变量并解绑当前主模型。直接由 `model` 配置推导的 `direct-config` 条目不提供删除按钮 | **未找到**Desktop 端点/Profile 导入导出 UI；可通过嵌入终端使用 CLI | **源码确认**：Test 调用 `/api/providers/custom-endpoints/validate`，对 `base_url + /models` 发 GET，返回 reachable、错误信息和模型列表；内置 key 另有 `/api/providers/validate` |

### 2.2 已有渠道与新建渠道的差异

- **已有内置 Provider**是注册表/模型目录中的固定标识，不能由用户在 UI 中删除或复制；可查看模型和认证状态，API-key Provider 可替换或清除 key，OAuth Provider 通过登录/注销管理。TUI 的 `model.disconnect` 只清凭据与关联状态，不删除 Provider 定义。
- **新建自定义 Endpoint**是 `providers.<id>` 的用户配置块。Desktop 可以填写名称、Provider ID、URL、默认模型、上下文长度、是否发现模型、是否作为新聊天默认值，并保存、编辑、激活、删除。后端用稳定的配置 key 生成 `custom:<id>` 运行时身份；更新时保留 UI 未展示的协议和 header 字段（`hermes_cli/web_routers/config_env.py`）。
- **直接手工配置的已有 Endpoint**会被 Desktop 标记为 `source: "direct-config"`，可以查看和编辑，但删除按钮被隐藏；这是“已有配置可管理但不完全可删除”的具体差异。其实际是否来自 legacy 迁移、主模型字段还是另一条兼容路径，当前 UI 只按 source 区分，未进一步验证。
- **配置文件与 UI 的 schema 不完全相同**：Desktop 表单只覆盖常用字段，后端保存时合并保留 `api_mode`、`key_env`/`api_key_env`、`extra_headers`、`request_overrides` 等手工字段。因此 UI 编辑不会按表单重建整个端点，但也没有 UI 控制这些高级字段。

---

## 3. 凭据、Header 与边界

### 3.1 存储与边界

- `.env` 只保存秘密，例如 API key 和 token。文件定位、读取与写入都由 `hermes_cli/config.py` 承担，读写入口是 `load_env` 与 `save_env_value`，UI 侧用 `save_env_value_secure` 落盘。
- `auth.json` 保存 provider 级的 access_token、refresh_token 和 agent_key，写入入口是 `hermes_cli/auth.py` 的 `_save_auth_store`。
- `config.yaml` 允许写入内联 `api_key`，这是历史遗留的不推荐做法；`.env` 与 config 之间的镜像值由 `config_migrations` 逐步清理。
- **`.env` 只放 secret**：行为性配置归 config 层，`AGENTS.md` 已明确这一划分。

### 3.2 进入请求

- API Key 选择顺序（`hermes_cli/auth.py _resolve_api_key_provider_secret`）：PROVIDER_REGISTRY 声明的 env_vars 优先序 → custom provider 配置 api_key → pool。
- **Header 附加**：`providers.<name>.extra_headers` 用于注入自定义头（`cli-config.yaml.example` 的注释明确其值常携带凭据、禁止记录，属渗透性威胁）；`hermes_cli/runtime_provider.py` 把校验后的 dict 并入运行时结果，再经 OpenAI client 的 `default_headers` 生效（`agent/agent_runtime_helpers.py`，SDK 层实际注入点未逐行验证）。

### 3.3 脱敏

- **子进程**：CLI 拉起子进程（例如 bang `!` 命令）之前，`tools/environments/local.py` 的 `_sanitize_subprocess_env` 先剥离 Hermes 管理的 secret（API key 等）再传入环境。CLI 自己把全部 API key 放在 `os.environ` 中，这些值不会泄露到子进程（`bang_shell.py`）。
- **日志脱敏**：`agent/redact.py` 用正则全局替换常见的 API key 与 token 形式，同时剥离控制字符、处理跨行片段；该行为可通过环境变量 `HERMES_REDACT_SECRETS` 或 config.yaml 的 `security.redact_secrets` 关闭。UI 和导出侧另用 `hermes_cli/config.py` 的 `redact_key()`。
- **MCP server env**：本次在 `agent_import.py` 里没有找到原有的 `is_secret_key` 与 `sanitize_mcp_env`。secret 来源侧改用 `agent/secret_sources/`，外部命令型 secret source 的键名通过 `HERMES_SECRET_KEY` 以数据方式传入。MCP env 当前的脱敏归属未逐行核对。
- **UI front-end**：`GET /api/env` 返回 `redacted_value` 字段，明文只在 `POST /api/env/reveal` 的响应里出现；该路由位于 `hermes_cli/web_routers/config_env.py`，带 5/30s 的限流与审计。
- **备份导出**：`_SECRET_FILE_NAMES`（`hermes_cli/backup.py`）标记以下文件，导出时脱敏：

  ```
  .env、auth.json、state.db
  ```

### 3.4 进程间传递（Profile / Gateway）

- Gateway 多平台、每平台后台；multiplex 时由 `gateway/run.py` 先装配 Profile scope 再设为活动 scope，`agent/secret_scope.py` 的 get_secret 读 env 时先查 scope；scope 为空且 multiplex 激活则 fail-closed。

---

## 4. 模型目录与能力元数据

### 4.1 来源

- **静态表**：`hermes_cli/models.py` 中有三份静态数据——`_PROVIDER_MODELS` 记录各 provider 的模型列表，`CANONICAL_PROVIDERS` 定义模型的 canonical 元组，`OPENROUTER_MODELS` 是远端拉取失败时的兜底快照。
- **远端拉取**：`fetch_openrouter_models()` 与 `fetch_nous_recommended_models` 从远端获取列表，结果写入 `provider_models_cache.json` 磁盘缓存（TTL 1 小时，过期后最多再服务 7 天），缓存清理由 `clear_provider_models_cache` 负责；以上都在 `hermes_cli/models.py`。
- **自定义端点探活缓存**：`hermes_cli/models.py` 的 `cached_fetch_api_models` 为 custom provider 的 `/v1/models` 探活结果建 TTL 磁盘缓存，缓存键由 `custom:<base_url>` 加凭据指纹（blake2b）组成，与一等 Provider 使用的 `cached_provider_model_ids` 对齐。
- 这套缓存覆盖命名 `custom_providers` 行、只写 `provider: custom` 的配置，以及 endpoint-map 条目。
- **用户输入**：模型 picker 允许直接填写 `model:`，custom provider 的 `model` 字段则用来指定该端点的默认模型。

### 4.2 能力元数据

- `agent/model_metadata.py` 提供模型上下文长度 / max_tokens 等（`DEFAULT_CONTEXT...` 等 dict）。此模块独立于 provider 注册；“provider 前缀识别”通过**实时查询 provider 注册表**（`get_provider_profile(prefix_lower)`），注册表后注册的 provider 不会漏判。另有 `agent/reasoning_summaries.py`（gpt-5.x 推理摘要 parts 的服务端分割，见消息渲染器笔记）。

---

## 5. Adapter、协议与请求组装

### 5.1 transport 注册表

- 注册与获取都在 `agent/transports/__init__.py` 中完成：
  - `register_transport(api_mode, cls)` 按 api_mode 注册 transport 类；
  - `get_transport(api_mode)` 返回对应实例，第一次调用时才导入全部 transport 模块；
  - `_discover_transports()` 负责导入 `agent.transports.*` 下的模块。
- 现有实现覆盖四类协议：
  - `agent/transports/chat_completions.py` 处理 OpenAI 兼容接口，由 `build_kwargs` 组装请求；存在 profile 时交给 `_build_kwargs_from_profile`，否则沿用 `is_openrouter`、`is_nous` 等 legacy 标志。
  - `agent/transports/anthropic.py` 处理 Anthropic 的 Message API。
  - `agent/transports/codex.py` 处理 Responses API。
  - `agent/transports/bedrock.py` 处理 Bedrock Converse。
- Provider 插件可以自行覆盖 client：Gemini 插件返回 `GeminiNativeClient`，绕过标准 transport。

### 5.2 Base URL / Header / 请求体

- 由 `build_kwargs`（transport）+ profile 方法（`build_extra_body` 等）组装；自定义端点 header 由 `custom_provider["extra_headers"]` 注入（`runtime_provider.py` 注释明确“Values may carry credentials — NEVER log them”）属 `_lift_extra_headers`。
- runtime provider 输出 dict 包含 `api_key/base_url/api_mode/extra_headers/request_overrides`，transport 用之调用 OpenAI-SDK。

---

## 6. 运行时选择、绑定与路由

### 6.1 `resolve_runtime_provider`（`hermes_cli/runtime_provider.py`）

三步决策（静态代码确认注释）：
1. `resolve_requested_provider(requested)`——传入 requested（None=auto）确定整体 provider标识；
2. `resolve_provider` 或直接查 `PROVIDER_REGISTRY` / pool 决定 api_mode+base_url+key；
3. `resolve_runtime_provider` 返回 dict：`provider, api_mode, base_url, api_key/access_token, source="custom_provider:..."`。

- 入口调用方：CLI（`cli.py`）/ `agent/agent_init.py` / cron / gateway tools；各调用点本次未逐条复核。
- 四条 resolver 层级（源码注释顺序）：
  - custom_provider 精确（`_resolve_named_custom_runtime`，在 `hermes_cli/runtime_provider_custom.py`），否则池 `load_pool(provider)`；
  - `_resolve_openrouter_runtime`（`hermes_cli/runtime_provider_backends.py`）；
  - `_resolve_azure_foundry_runtime`（`hermes_cli/runtime_provider_backends.py`）；
  - `resolve_provider` 兜底。

### 6.2 别名与语义路由

- ProviderProfile 的 aliases 字段列出同一 Provider 的其他名字，`hermes_cli/auth.py` 在注册时把这些别名一并写入 `PROVIDER_REGISTRY`，使别名与主名指向同一份配置。
- 请求进来后，`resolve_requested_provider` 先把别名归一为主名。
- OpenRouter 聚合层内部的模型路由由服务端决定，配置项 `provider_routing` 是 OpenRouter 侧的选项，按 `cli-config.yaml` 的说明属于上游行为。
- 本项目没有实现跨 base_url 的负载均衡；同一 provider pool 只做多 Key 轮换。
- **运行时 `/model` 切换**（`hermes_cli/model_switch.py`）要处理三类问题：
  - 凭据作用域：模型选择器和 `switch_model` 读取用户 provider key 时走 per-profile secret scope（`_scoped_key_env`），multiplex 场景下不会取到其他 profile 的 key；
  - 歧义别名：`/model opus` 命中多个目录模型时列出候选让用户选择，避免用启发式规则猜测；
  - 日期型快照排序：`_model_sort_key` 把 YYYYMMDD 日期戳从版本元组中拆出来，`claude-opus-4-20250514` 不会被当成版本号 20,250,514 参与排序。

---

## 7. 多 Key、限流、重试与故障转移

分层（`agent/agent_runtime_helpers.py` 与 `agent/chat_completion_helpers.py`）：

| 层级 | 机制 | 触发 | 位置 |
|---|---|---|---|
| L0 | OpenAI SDK 内建重试 | 网络瞬时错误 | SDK |
| L1 | Hermes 全链重试 | API error（连接、5xx） | `agent/conversation_loop.py`（循环 `recover_...`） |
| L2 | **同 provider 多 Key 轮换** | 429 / 401 / rate-limit | `agent/agent_runtime_helpers.py` 的 `recover_with_credential_pool` → `agent/credential_pool.py` 的 `mark_exhausted_and_rotate`/`select` 选下一个可变 Key |
| L3 | **模型 fallback（同渠道换模型）** | 模型 400 / context overflow / 单模型报错 | `agent/conversation_loop.py`；通过 `agent.model` 切换 |
| L4 | **跨渠道 fallback 链**（不同 provider/provider endpoint） | L1-L3 后仍在失败 / 明确 error | `agent/chat_completion_helpers.py try_activate_fallback` → `agent/agent_runtime_helpers.py restore_primary_runtime` 恢复主通道 |

- credential pool 的条目读写入口在 `hermes_cli/auth.py:1688`，每个条目记录 `last_status`、`quota` 和 `cooldown`。冷却到期后条目自动恢复可用，具体选择逻辑在 `agent/credential_pool.py`，未逐行确认。
- 环境变量本身就能给池提供凭据：对注册表声明的每个基础变量，种子逻辑依次读取 `VAR_2`、`VAR_3` 直至第一个缺口，OpenRouter 与通用 Provider 走同一套候选生成器。秘密留在 `.env` 或 secret manager，池文件只持久化 `env:VAR_N` 这类引用，加载时再水化回真实值。编号必须连续，中间缺号时后续编号不会被发现（`agent/credential_pool.py`）。
- 是否重复计费/重复生成：同一请求 429 时 `recover_with_credential_pool` 只换 Key 重发（同一 `api_kwargs`，不重建 messages）；`try_activate_fallback` 则重建 transport 并重新发送同一消息，通常会产生第二次调用费用，重复生成风险出现在 L4 切换之后（`chat_completion_helpers.py` 附近注释说明 switch 后继续同一任务）。是否重复计费取决于 Provider 撤回策略，笔记无法定论——标注为“**存在重复计费可能（推断）**”。
- `cli.py` 与 `agent/chat_completion_helpers` 都通过 `get_fallback_chain` 读取 `fallback_model` 与 `fallback_providers`。

---

## 8. 连接检测、日志与可观测性

### 8.1 设置页测试 vs 真实链路

- **真实聊天链路**：先由 `resolve_runtime_provider` 解析出运行时参数，再交给 transport 组装请求，最后由相应协议的 SDK 发出；Anthropic Messages 路径使用 Anthropic client（`agent/client_lifecycle.py:987-998`）。
- **设置页/凭据测试**：
  - `POST /api/providers/validate`：直接向 `_CREDENTIAL_PROBES` 中登记的四组 `/models` 端点（OPENROUTER、OPENAI、GEMINI、XAI）发 httpx GET 请求验证 key，其余 provider 一律返回 reachable=False；实现在 `hermes_cli/web_routers/config_env.py`。
  - `POST /api/providers/custom-endpoints/validate` 用用户填写的 base_url（可选带 key）请求 `GET {base_url}/models`，命中后返回该端点的模型列表。
  - `_probe_apikey_provider` 对每个已配置的 API-key provider 逐个查询 `/models`，其中 `supports_health_check=False` 的 provider 会被跳过（`hermes_cli/doctor_connectivity.py`）。
  - `hermes doctor --live` 是显式开启的真实网络探针：按顺序逐个请求外部托管后端的元数据端点，每项约 10 秒超时，覆盖 firecrawl 用量、fal 模型列表、openai 与 groq 的 `/models` 以及 elevenlabs voices。探针只读、单个失败不影响其余项，未配置的后端直接跳过（`hermes_cli/doctor_live.py` 的模块不变量）。它同样不经过真实聊天链路，探测的是外部托管后端。
- **结论**：设置页测试使用独立请求路径，只验证 endpoint 可达并做单模型 URL 探活，路径上跳过真实 resolver、credential pool 和 fallback 链。真实聊天还可能失败于 transport 组装、认证头注入或模型名不匹配。设置页测试通过只覆盖这条测试路径，真实聊天是否可用要按完整链路单独确认（指南事项 3 已确认成立）。

### 8.2 日志与错误

- `agent/redact.py` 全局脱敏（如上）；`hermes_cli/logging.py setup_logging`；`/logs` 可审计。
- 错误归一：`format_runtime_provider_error`（`hermes_cli/runtime_provider.py`）；错误分类见 `agent/error_classifier.py` 的 `FailoverReason`。（本次为浅览。）

### 8.3 用量/成本

- 用量/计费面本次按模块名盘点：`agent/` 下的 turn_usage、billing_usage、usage_pricing、usage_gauges、usage_anchor、account_usage 六个模块均未深入，桌面 billing 独立做显示。

---

## 9. 平台边界（桌面 / Web / 服务端 / 本地模型服务）

- **Electron 桌面（apps/desktop）**：架构说明见 `apps/desktop/AGENTS.md`；渲染层通过 `@hermes/shared` 的 JsonRpcGatewayClient 建立 WS 连接，与 tui_gateway 后端通信。Providers Settings 经 Desktop API bridge 调用 REST 接口，Custom endpoints 表单是本次唯一找到的端点增删改入口。
- **Web dashboard（web/）**：EnvPage 读取 `GET /api/env` 并展示脱敏后的值，支持新增、替换、清除 `.env` 键和 reveal；OAuth 卡片调用 `/api/providers/oauth`，模型页使用 `/api/model/options`。本次没有找到 Web Dashboard 的 Custom endpoints 页面，也没有找到调用 `/api/providers/custom-endpoints` 的代码，服务端路由与 Web UI 的可达性需要分别确认。
- **TUI（ui-tui + tui_gateway）**：`modelPicker.tsx` 通过 `model.options` 拿到完整 Provider 目录并展示；未认证的 API-key Provider 可在选择器内直接输入 key，存入 `.env`；Ctrl+D 断开认证并清理关联状态。它覆盖已有 Provider 的认证与模型选择，`providers.<name>` 端点在这里没有对应表单。
- **服务端（gateway）**：`gateway/run.py` 调用 `resolve_runtime_provider`，multiplex 场景下再用 `set_secret_scope` 限定凭据作用域。
- **本地模型服务（Ollama、LM Studio）**：把 `model.provider` 设为 custom 并给出本机 `base_url` 即可接入；key 可以省略（`no-key-required`），也可以在 custom provider 配置里填 `api_key` 或 `extra_headers`。

---

## 设计取舍与已确认边界

1. **声明式 Provider 标识 vs 运行时端到端组装分离**：`ProviderProfile` 只描述，不构建 client（`providers/base.py`），transport 层负责请求/应答边界；代价是 profile 无法独立决定底层 Client 行为（Gemini 通过覆盖 build_extra_body / native client 绕过）。
2. **多 Provider ≠ 自动故障转移**：默认只有 1 个 primary；`fallback_providers` 需用户在配置中显式声明链。Provider 支持与 failover 能力两者解耦（指南 §2 提醒得到确认）。
3. **凭据多路复用是显式策略**：多 Key 同 Provider 用 credential pool（authed_cli 的平行用户故事）；跨 Provider failover 用 fallback 链；模型级回退另用 `fallback_model`。三机制正交。
4. **编号环境变量是最小池配置**：设置基础变量及连续的 `_2`、`_3` 即可参与轮换，无需把秘密复制进配置或 `auth.json`；首个编号缺口终止自动发现。
5. **前端看不到原始 Key**：redacted 值 + reveal 限控；即使暴露也仅对 .env / OAuth 会话。
6. **测试链路隔离**：设置页探活不触发完整 transport 集（高可探测、假阳性风险）。
7. **Repeat 收费的可能**：跨端点 failover 会重建并重发（重复生成与计费风险存在，但具体由上游服务端判定）——推断性结论。
8. **No channel concept**：未发现 `channel` 作为 LLM Provider 语义的关键词（检索 `hermes_cli/` `agent/` 后只有消息平台 channel）。若行业中其他项目把“一个 baseURL+key 组合”叫渠道，本项目的对应物就是**custom provider 条目 / provider_pool 条目**。

---

## 当前 Provider 发现与参数边界

Provider 注册新增 pip entry-point 来源，但仍受插件启用配置约束：发现器只加载已启用的 `hermes_agent.plugins` 条目，失败记录为诊断而不是隐式启用（`providers/__init__.py`、`287-301`）。自定义 `base_url` 在模型拉取时优先于 `models_url`，减少自建兼容端点把模型查询错误导向目录地址的风险。推理强度也按具体模型的 wire vocabulary 转换，因此配置中相同的抽象级别不会向所有 Provider 发送同一字面值。

## 未验证事项（本次未覆盖/未能确认）

- 真实运行：没有执行任何请求，所有结论取自静态代码路径，SDK 重试与 Pool 冷却持久化后的跨进程行为尤其缺少运行证据。
- `agent/credential_pool.py` 的冷却与选择细节未逐行确认，`agent/turn_usage.py` 等用量模块未深读。
- `hermes_cli/models.py` 中 Nous 推荐模型的拉取逻辑，以及 `provider_models_cache.json` 是否定义 schema，均未逐一验证。
- `hermes_cli/config_migrations.py` 的迁移纵深（`_migrate_to_12` 到 `_migrate_to_33` 等）未逐条阅读。
- Provider 插件与 deferred 注入的执行时机依赖懒 import，未运行验证。
- CLI、TUI、Web 与 Electron Desktop 都没有启动，保存或删除后的实际刷新、配置文件权限、浏览器与桌面 API bridge、Windows 平台行为以及真实网络结果都未验证。
- `hermes_cli/profiles.py` 的导出实现正文未逐条阅读；Profile 导出与导入的命令入口、备份敏感文件名单已经确认，单个 Profile archive 是否对每个 `providers` 字段逐项脱敏、恢复后端点与 key 的精确结果仍未验证。
- Web Dashboard 缺少 custom endpoint UI 的结论来自 `web/src/pages` 与 `web/src/lib/api.ts` 的静态搜索，插件或运行时注入的页面仍可能提供额外入口。

---

## 关键源码索引

| 主题 | 位置 |
|---|---|
| ProviderProfile（声明式标识） | `providers/base.py` |
| provider 注册/懒发现 | `providers/__init__.py`（`register_provider` 、`get_provider_profile` ） |
| Provider 插件目录（40 个） | `plugins/model-providers/<name>/__init__.py` |
| 4 类 transport 注册与分发 | `agent/transports/__init__.py` |
| OpenAI-compat transport 组装 | `agent/transports/chat_completions.py`（`build_kwargs`、`_build_kwargs_from_profile`） |
| 运行时取舍决策 | `hermes_cli/runtime_provider.py resolve_runtime_provider`（多分支：custom/openrouter/azure/pool） |
| 运行时 `/model` 切换 | `hermes_cli/model_switch.py`（secret scope key 读取、歧义别名候选、`_model_sort_key` 日期拆分） |
| fallback 链读取 | `hermes_cli/fallback_config.py get_fallback_chain` / `cli.py` |
| credential pool 轮换 | `agent/agent_runtime_helpers.py`（`recover_with_credential_pool`）、`agent/credential_pool.py`（`select`、`mark_exhausted_and_rotate`） |
| 编号环境变量种子 | `agent/credential_pool.py` `_env_key_var_candidates` / `_seed_from_env` |
| credential 持久化 | `hermes_cli/auth.py/1688 read/write_credential_pool`、`_save_auth_store`  |
| .env 读写/镜像清理 | `hermes_cli/credential_lifecycle.py`（`save_provider_env_credential`/`remove_provider_env_credential`）、`hermes_cli/config.py`（`load_env`/`save_env_value`） |
| 桌面/Web 设置页测试端点 | `hermes_cli/web_routers/config_env.py`（`/api/providers/custom-endpoints` 的 GET/POST/DELETE/activate、`/validate`、`/api/providers/validate`、`/api/env/reveal`） |
| Desktop 自定义端点表单 | `apps/desktop/src/app/settings/custom-endpoints-settings.tsx`；REST bridge `apps/desktop/src/hermes.ts` |
| Desktop Provider Accounts/API keys | `apps/desktop/src/app/settings/providers-settings.tsx` |
| TUI Provider/模型/Key 操作 | `ui-tui/src/components/modelPicker.tsx`；`tui_gateway/methods_complete.py` |
| Web `.env` 凭据页面 | `web/src/pages/EnvPage.tsx`；`web/src/lib/api.ts` |
| CLI 配置、认证和 Profile 命令 | `hermes_cli/subcommands/config.py`、`subcommands/auth.py`、`subcommands/profile.py` |
| doctor 健康探测 | `hermes_cli/doctor_connectivity.py`（`_probe_apikey_provider`）；`hermes_cli/doctor_live.py`（`--live` 真实元数据端点探针） |
| 子进程 env 脱敏 | `tools/environments/local.py _sanitize_subprocess_env`、`hermes_cli/bang_shell.py` |
| 日志/错误脱敏 | `agent/redact.py` 起；`hermes_cli/logging.py` |
| 外部命令型 secret source | `agent/secret_sources/`（`command.py` 用 `HERMES_SECRET_KEY` 传键名、值只走管道） |
| profile scope / multiplex | `agent/secret_scope.py`（`set_multiplex_active`/`set_secret_scope`/`build_profile_secret_scope`/`get_secret`）、`gateway/run.py` |
| 模型目录静态表+拉取 | `hermes_cli/models.py`（`_PROVIDER_MODELS`、`fetch_openrouter_models`、`cached_fetch_api_models`）、`provider_models_cache.json` |
| 元数据（上下文长度） | `agent/model_metadata.py`（provider 前缀实时查注册表） |
