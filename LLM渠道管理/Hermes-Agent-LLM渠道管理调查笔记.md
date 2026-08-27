# Hermes-Agent（hermes-agent）LLM 渠道管理调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 调查方式：全量源码静态阅读 + git 历史核查；补查 CLI、TUI、Web、Electron Desktop 的渠道管理入口；未运行程序、未发起真实请求
>
> 调查范围：Provider 注册与插件发现、自定义端点配置、配置文件/CLI/TUI/Web/Desktop 的查看与管理操作、凭据存储/访问/脱敏/导出、模型目录来源、transport 协议适配、运行时 Provider 解析与 fallback 链、credential pool 多 Key 轮换与冷却、连接检测与可观测性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **无“LLM 渠道”实体**。本仓库没有独立的“渠道（channel）”概念：LLM 提供方在代码里是**声明式 ProviderProfile 标识（`providers/base.py:38`）+ 凭据表（`hermes_cli/auth.py:195` 的 `PROVIDER_REGISTRY`）**，用户不创建“Provider 实例”。
- **自定义端点即渠道等价物**。用户在配置里实例化的是 `providers:`/`custom_providers:` 端点（`providers` 是 v12+ 的键控 schema，`hermes_cli/config_defaults.py:7-11`），每个端点带 base_url、key_env/api_key 与可选 extra_headers。因此“渠道”在本项目中实际等于「Provider 标识 + 一个 base_url + 一份凭据」的组合；一个内置 Provider 默认一支独苗（一个 config block），多端点通过多个 custom_providers 条目表达。
- **管理入口并不对称**。配置文件和 Desktop 的自定义端点页可以直接管理端点；CLI/TUI/Web 主要管理 Provider 凭据、模型选择或整个 Profile，未找到针对 `providers.<name>` 的同等端点 CRUD 页面。Desktop 的“Use”是当前主模型启用/切换，不是端点自身的独立 enabled 开关。
- **运行时可动态切换，但启动解析与聊天链路走不同代码路径**。真实聊天流经 `resolve_runtime_provider()`（`hermes_cli/runtime_provider.py:1665`）产出运行时 dict，再交由 transport 组装请求；而桌面/Web 设置页的“连接测试/凭据校验”走独立 HTTP 探针（`hermes_cli/web_server.py:7507 /api/providers/validate` 与 `:7479 /api/providers/custom-endpoints/validate`），并不复用真实 resolver 链路 —— 二者的探测面与失败语义不一致（详见 §8）。
- **凭据是层化存储、高度可配置、卸载时全链路清理**：
  - API Key 默认存放 `.env`（`config.py:3703 load_env` / `:3924 save_env_value`），OAuth/多渠道凭据存放在 `auth.json`（`auth.py:1038` `_auth_file_path`、`AUTH_STORE_VERSION=1`）；
  - 任意 `.env` 值可被“借用”进 credential pool（`auth.json` 的 `credential_pool` 键，`auth.py:1574/1688` 读写）；
  - 所有子进程环境都会被脱敏（输出白名单），日志、UI、备份均做脱敏（§3）。
- **模型目录是【静态表 + 远端拉取 + 用户输入】三层**：
  - 静态快照 `_PROVIDER_MODELS`（`hermes_cli/models.py:221`）；
  - OpenRouter/Nous Portal 拉取（`models.py:1504/955`，带 `provider_models_cache.json` 磁盘缓存 `models.py:3197`）；
  - 用户可任选手动输入；
  - custom 端点 `/v1/models` 探活另有磁盘缓存（`models.py:4737`）。
  能力/上下文长度元数据集中 `agent/model_metadata.py`（provider 前缀实时查注册表）。
- **协议适配集中在 transport 层**：`agent/transports/` 按 `api_mode` 注册与分发（`__init__.py:21 register_transport`、`:26 get_transport`），覆盖 OpenAI 兼容、Anthropic、Responses、Bedrock 等模式（清单见 5.1）；profile 存在时由 profile 驱动 `build_kwargs`（`chat_completions.py:375-420`、`:599 _build_kwargs_from_profile`）。Provider 本身不持有运行时客户端。
- **重试、Key 轮换、模型 fallback、跨渠道 failover 分四层**：应用层重试（`agent.api_max_retries`，默认 3，`hermes_cli/config_defaults.py:71`）→ 同 Provider 多 Key 的 credential pool 轮换（429/401/供应商错误）→ 跨渠道 fallback 链（`fallback_config.py:80` 读取、`chat_completion_helpers.py:1923` 推进）→ 会话层 `restore_primary_runtime` 恢复主通道（`agent_runtime_helpers.py:1459`）。各层的触发条件与完整定位见 §7。
- **可观测性**：`hermes doctor` 连接健康检查（`hermes_cli/doctor.py:2475 _probe_apikey_provider`；`hermes doctor --live` 真实元数据探针见 §8）、日志脱敏（`agent/redact.py`）、全局 `provider_models_cache.json` 缓存、用量/成本由各自的 provider resolution + usage tracker 处理（本次不在范围）。

---

## 概念模型（本项目的 Provider / 渠道 / Endpoint / 模型 / 凭据 / Profile）

为避免跨层混淆，先定义本项目各概念含义（均为静态代码确认）：

- **Provider（提供方标识）**：代码/插件注册声明的 `ProviderProfile`（`providers/base.py:38`），字段：

  ```
  name / api_mode / aliases / env_vars / base_url / auth_type / display_name /
  description / signup_url / default_aux_model / supports_health_check
  ```

  它是声明性的：`providers/base.py:7-9` 明确写出“不持有客户端构造、凭据轮换、流式”。Provider 不是用户实例，也不是运行时连接。
- **渠道 / Endpoint（端点实例，即“渠道”等价物）**：用户在配置中定义的 `providers:<name>:`（字段见下），或 legacy `custom_providers` 列表条目（`hermes_cli/config.py:1532 get_compatible_custom_providers` 把两者合并为统一视图）。运行时会为每个条目解析出一个具体 base_url + 凭据通道：

  ```
  base_url / key_env / api_key / model / max_output_tokens / extra_headers
  ```

  同一厂商可配置多个端点（多 custom 条目），但内置 Provider 各自只有一套指定 base_url / 凭据 env（由 `PROVIDER_REGISTRY` 描述）。
- **Profile（HERMES_HOME）**：当前活动配置目录（`hermes_constants.get_hermes_home()`）。所有凭据、配置、缓存均按 Profile 隔离；`agent/secret_scope.py` 提供 `set_secret_scope`/`build_profile_secret_scope` 装配入口，网关 multiplex 多 Profile 时经 `set_multiplex_active` 强制限定环境变量访问范围（`agent/secret_scope.py:40-52`）。
- **Model（模型 ID）**：`model:` 配置中的 `default:`，或者每个 fallback 条目里的 `model:`。可为任意用户输入字符串，也来自静态表 / 远端拉取。
- **Credential（凭据）**：API Key / access_token；存放于 `.env`（key `api_key`）、`auth.json`（provider 状态）、config.yaml 内嵌 api_key（不推荐），或外部进程/OAuth 文件。凭据的“借用”进入 credential pool 即复制一份放入 `auth.json`，由 `PooledCredential`（`agent/credential_pool.py`）管理。
- **Fallback 链（故障转移“跨渠道”）**：可在配置里定义 `fallback_providers` / legacy `fallback_model`（顶层，见 `cli-config.yaml.example` 与 `hermes_cli/fallback_config.py:80 get_fallback_chain`）。每条 fallback 条目 = provider + model + base_url + api_key/key_env；运行时按顺序尝试，属于**跨渠道（端点）故障转移**，不是同渠道重试。

---

## 总体调用链

以 CLI 真实对话为例（静态代码路径）：

1. CLI 组装 `AIAgent`（`cli.py` 内 `create_agent` / `agent/agent_init.py`）接收 provider、model、base_url、api_key、credential_pool 等参数。
2. 构造输入之一来自 `load_config`：`cli.py:4546 _fallback_model = get_fallback_chain(CLI_CONFIG)` 在启动时读 fallback 链。
3. `AIAgent` 内经 `resolve_runtime_provider`（`hermes_cli/runtime_provider.py:1665`）决定具体 provider + api_mode + base_url + api_key，并生成 transport 组件。
4. transport：`get_transport(api_mode)`（`agent/transports/__init__.py:26`）拿到对应 transport 实现，`build_kwargs` 组装请求体（`agent/transports/chat_completions.py:356`，profile 分支 `:599`）。
5. 会话循环处理 retry / 429 / credential pool 恢复；池用尽后调用 `try_activate_fallback`（`agent/chat_completion_helpers.py:1730`）推进 fallback 链并重建 transport（`create_openai_client`，`agent/agent_runtime_helpers.py:2241`）。
6. 输出响应 → `agent.conversation_loop` 返回 `result_to_console`。

Gateway/TUI 复用同样的 `load_config` / `resolve_runtime_provider` 路径（`hermes_cli/runtime_provider.py` 文档注释即宣称“共用”）；multiplex 时每请求装配 profile secret scope（`gateway/run.py:1911`）。

---

## 1. Provider 注册、渠道数据模型与配置

### 1.1 Provider 注册（插件化）

- **扫描机制**：`providers/__init__.py` 中懒发现扫描（`_discover_providers()`，`providers/__init__.py:147`），入口为 `register_provider()`（`:54`）、`get_provider_profile()`（`:68`）、`list_providers()`（`:79`）。
- **扫描顺序**：仓库 `plugins/model-providers/<name>/` → `$HERMES_HOME/plugins/model-providers/<name>/` → legacy `providers/<name>.py`（兼容，docstring 见 `providers/__init__.py:1-22`）。用户同名插件后注册覆盖内置（last-writer-wins）。
- 仓库内模型提供插件共 35 个目录（`plugins/model-providers/`：anthropic、openrouter、gemini、custom、azure-foundry、bedrock 等）。示例：
  - `plugins/model-providers/anthropic/__init__.py:47`：`api_mode="anthropic_messages"`, env `ANTHROPIC_API_KEY/ANTHROPIC_TOKEN/CLAUDE_CODE_OAUTH_TOKEN`, `base_url https://api.anthropic.com`, `auth_type="api_key"`。
  - `plugins/model-providers/custom/__init__.py`：`api_mode="chat_completions"`，用于自定义/OLLAMA 类本地服务，包含 `build_extra_body` / `build_api_kwargs_extras` 处理（如 Ollama `num_ctx` 等）。
  - `plugins/model-providers/gemini/__init__.py`：docstring 与实现声明 `api_mode="chat_completions"` 但实际用 GeminiNativeClient 绕过标准 transport（`plugins/model-providers/gemini/__init__.py:3-9`）——说明 api_mode 只指导 transport，真正 client 由插件/运行时决定。
  - `plugins/model-providers/openrouter/__init__.py`：为一代理，展示自定义 `fetch_models`。

### 1.2 统一 Provider 目录（可观察源）

`hermes_cli/provider_catalog.py:57` `ProviderDescriptor`；`provider_catalog()` 从 `CANONICAL_PROVIDERS`（`hermes_cli/models.py`，provider 全量枚举）+ `PROVIDER_REGISTRY` 的 auth_type/凭据 env + profile 的 display 元数据组装，驱动 CLI/TUI 的模型选择器和桌面 Settings → Providers 两个 Tab（Accounts / API keys），`provider_catalog.py` 声明该 parity 契约（docstring 开头）。

### 1.3 配置 schema（用户可创建多个 Endpoint）

顶层（`cli-config.yaml.example` 及各行）三类配置键：

```text
model.default / model.provider / model.base_url / model.api_key    # 主模型
fallback_providers: [ {provider, model, base_url, key_env/api_key}... ]  # fallback 链
providers.<name>: （v12+）与 legacy custom_providers: [...]         # 自定义端点
```

`providers.<name>:` 与 legacy `custom_providers` 二者由 `get_compatible_custom_providers()`（`hermes_cli/config.py:1532`）去重合并为同一视图，供设计层与 UI。

### 1.4 配置加载与合并

- `load_config()`（`hermes_cli/config.py:3150`）先合并 `DEFAULT_CONFIG`（`hermes_cli/config_defaults.py:7-11`）再合并用户 YAML；`load_config_readonly()`（config.py:3167）返回只读 dict 避免触发迁移。迁移逻辑在 `hermes_cli/config_migrations.py`（版本号逐步抬到 12+）。

---

## 2. 配置创建、持久化与迁移

- **自定义端点创建/删除**：Desktop Settings 的 Custom endpoints 视图经由 `POST /api/providers/custom-endpoints`（`hermes_cli/web_server.py:7522`）、`DELETE .../:id`（`:7575`）、`POST .../:id/activate`（`:7541`），写回 `config.yaml`（`providers`）。Web Dashboard 当前只使用同一服务中的 `/api/env`、模型和 OAuth 页面；本次未找到它调用这些 custom-endpoints 路由的页面代码。

   — 校验：`POST /api/providers/custom-endpoints/validate`（`:7600`）与 `POST /api/providers/validate`（`:7628`），均由 web_server 直接 `httpx` 探活 endpoint `/models`（规则见 §8）。
- **`.env` 写入**：`PUT /api/env` → `hermes_cli.credential_lifecycle.save_provider_env_credential`（`hermes_cli/credential_lifecycle.py:213`）写 `.env` + 同步 config.yaml 镜像。
- **`.env` 删除**：`DELETE /api/env` → `remove_provider_env_credential`（`credential_lifecycle.py:245`）清理 `.env` 条目 + pool 内 env-seeded 条目 + `model.api_key` 等镜像（`purge_env_credential_references`，`:178`）。
- **读取编码**：`auth.json`/`.env` 的读取统一为 UTF-8（BOM 容错），避免 Windows 代码页损坏导致凭据丢失（`hermes_cli/auth.py`、`env_loader.py`，如 `762f1c58` 系列）。
- **auth.json**：版本 `AUTH_STORE_VERSION = 1`（`hermes_cli/auth.py:109`）；路径 `_auth_file_path`（`auth.py:1038`）→ `~/.hermes/auth.json`。结构至少含：

  ```
  {"version":1, "providers": {...}}   # 必选
  credential_pool: {provider_id: [entry, ...]}   # 可选，写回时合并
  ```

  池的读写见 §7；env 凭据刷新后池条目 id 会重新绑定（`bf7c7166`，`agent/agent_runtime_helpers.py`）。
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
- **新建自定义 Endpoint**是 `providers.<id>` 的用户配置块。Desktop 可以填写名称、Provider ID、URL、默认模型、上下文长度、是否发现模型、是否作为新聊天默认值，并保存、编辑、激活、删除。后端用稳定的配置 key 生成 `custom:<id>` 运行时身份；更新时保留 UI 未展示的协议和 header 字段（`hermes_cli/web_server.py:7410-7500`）。
- **直接手工配置的已有 Endpoint**会被 Desktop 标记为 `source: "direct-config"`，可以查看和编辑，但删除按钮被隐藏；这是“已有配置可管理但不完全可删除”的具体差异。其实际是否来自 legacy 迁移、主模型字段还是另一条兼容路径，当前 UI 只按 source 区分，未进一步验证。
- **配置文件与 UI 的 schema 不完全相同**：Desktop 表单只覆盖常用字段，后端保存时合并保留 `api_mode`、`key_env`/`api_key_env`、`extra_headers`、`request_overrides` 等手工字段。因此 UI 编辑不会按表单重建整个端点，但也没有 UI 控制这些高级字段。

---

## 3. 凭据、Header 与边界

### 3.1 存储与边界

- `.env`：仅存秘密（API keys、tokens）。`get_env_path`（`hermes_cli/config.py:698`），`load_env`（`config.py:3703`）/`save_env_value`（`config.py:3924`）。UI 写 `.env` 走 `save_env_value_secure`（`config.py:4131`）。
- `auth.json`（provider 级 access_token / refresh_token / agent_key），写权限：`auth.py:1322 _save_auth_store`。
- `config.yaml` 可含 `api_key` 内联值（不推荐的历史习惯）；`.env` 与 config 镜像通过 `config_migrations` 逐步清理。
- **`.env` 禁止包含行为性配置**（`AGENTS.md` 声明 .env 只放 secrets）。

### 3.2 进入请求

- API Key 选择顺序（`hermes_cli/auth.py:668 _resolve_api_key_provider_secret`）：PROVIDER_REGISTRY 声明的 env_vars 优先序 → custom provider 配置 api_key → pool。
- **Header 附加**：`providers.<name>.extra_headers` 用于注入自定义头（注释 `cli-config.yaml.example:96-110` 明确其值常携带凭据、禁止记录，属渗透性威胁）；`_lift_extra_headers`（`hermes_cli/runtime_provider.py:658`）把校验后的 dict 并入运行时结果，再经 OpenAI client 的 `default_headers` 生效（`agent/agent_runtime_helpers.py:2241`，SDK 层实际注入点未逐行验证）。

### 3.3 脱敏

- **Subprocess**：`_sanitize_subprocess_env`（`tools/environments/local.py:456`）剥离 Hermes 管理的 secrets（API_KEYS 等）再传给 CLI 子进程（如 bang `!` 命令）；CLI 持有全部 API key 于 `os.environ`，子进程不被外泄（`bang_shell.py:131-141`）。
- **日志脱敏**：`agent/redact.py` 全局用正则替换常见 API key / token pattern（`agent/redact.py:68-76`，HERMES_REDACT_SECRETS 与 config.yaml `security.redact_secrets` 均可关闭），另有控制字符剥离与跨行跨度处理（`e9d1551e`、`9377c5a5`、`8969ebac`）；`redact_key()`（`hermes_cli/config.py:4243`）对 UI / 导出生效。
- **MCP server env**：`agent_import.py:85-100 is_secret_key` + `sanitize_mcp_env`。
- **UI front-end**：`GET /api/env` 返回 `redacted_value` 字段（`hermes_cli/web_server.py:7053`），明文字只在 `POST /api/env/reveal`（`:7597`，带 rate-limit 5/30s + audit）回报。
- **备份导出**：`_SECRET_FILE_NAMES`（`hermes_cli/backup.py:128`）标记以下文件，导出时脱敏：

  ```
  .env、auth.json、state.db
  ```

### 3.4 进程间传递（Profile / Gateway）

- Gateway 多平台、每平台后台；multiplex 时 `build_profile_secret_scope` → `set_secret_scope`（`gateway/run.py:1911`），`get_secret`（`agent/secret_scope.py:132`）读 env 时先查 scope；scope 为空且 multiplex 激活则 fail-closed（`agent/secret_scope.py:40-...`）。

---

## 4. 模型目录与能力元数据

### 4.1 来源

- **静态表**：`_PROVIDER_MODELS`（`hermes_cli/models.py:221`）与 `CANONICAL_PROVIDERS`（`models.py:1116`，模型的 canonical 元组）、`OPENROUTER_MODELS` 快照（远程拉取失败兜底，models.py:49）。
- **远端拉取**：`fetch_openrouter_models()`（`models.py:1504`）、`fetch_nous_recommended_models`（`models.py:955`）；结果缓存至 `provider_models_cache.json`（路径 `models.py:3197-3199`，TTL 1h、stale-serve 7d，`:3131-3141`），另有 `clear_provider_models_cache` 负责清缓存（`models.py:3358`）。
- **自定义端点探活缓存**（`cached_fetch_api_models`，`models.py:4737`）：custom provider 的 `/v1/models` 探活原本每次都直连，现按 `custom:<base_url>` 键 + 凭据指纹（blake2b）做 TTL 磁盘缓存，与一等 Provider 的 `cached_provider_model_ids`（`:3308`）对齐（`fb435aae`）。
- 适用对象：命名 `custom_providers` 行、bare `provider: custom`、endpoint-map 条目。
- **用户输入**：模型 picker 中可自由输入 `model:`；custom provider 的 `model` 字段可主推默认模型。

### 4.2 能力元数据

- `agent/model_metadata.py` 提供模型上下文长度 / max_tokens 等（`DEFAULT_CONTEXT...` 等 dict）。此模块独立于 provider 注册；“provider 前缀识别”改为**实时查询 provider 注册表**（`get_provider_profile(prefix_lower)`，`d143bf7a`/`19e51d2c`，model-metadata 修复），注册表后注册的 provider 不再漏判。另新增 `agent/reasoning_summaries.py`（gpt-5.x 推理摘要 parts 的服务端分割，见消息渲染器笔记）。

---

## 5. Adapter、协议与请求组装

### 5.1 transport 注册表

- `agent/transports/__init__.py`：
  - `register_transport(api_mode, cls)` — 注册；
  - `get_transport(api_mode)` — 懒发现导入全 transport 模块；返回实例；
  - `_discover_transports()` — import `agent.transports.*`。
- 实现：
  - `agent/transports/chat_completions.py` — OpenAI-compat，`build_kwargs`；存在 profile 时 delegate `_build_kwargs_from_profile`（`:599`），否则 legacy 标志（`is_openrouter`/`is_nous`…）。
  - `agent/transports/anthropic.py` — Message API。
  - `agent/transports/codex.py` — Responses API。
  - `agent/transports/bedrock.py` — Bedrock Converse。
- Provider 自己也可覆盖：Gemini plugin 返回 `GeminiNativeClient`（不走标准 transport）。

### 5.2 Base URL / Header / 请求体

- 由 `build_kwargs`（transport）+ profile 方法（`build_extra_body` 等）组装；自定义端点 header 由 `custom_provider["extra_headers"]` 注入（`runtime_provider.py:1168-1172` 注释明确“Values may carry credentials — NEVER log them”）属 `_lift_extra_headers`（`:658`）。
- runtime provider 输出 dict 包含 `api_key/base_url/api_mode/extra_headers/request_overrides`，transport 用之调用 OpenAI-SDK。

---

## 6. 运行时选择、绑定与路由

### 6.1 `resolve_runtime_provider`（`hermes_cli/runtime_provider.py:1665`）

三步决策（静态代码确认注释）：
1. `resolve_requested_provider(requested)`（`:592`）——传入 requested（None=auto）确定整体 provider标识；
2. `resolve_provider` 或直接查 `PROVIDER_REGISTRY` / pool 决定 api_mode+base_url+key；
3. `resolve_runtime_provider` 返回 dict：`provider, api_mode, base_url, api_key/access_token, source="custom_provider:..."`。

- 入口调用方：CLI（`cli.py`）/ `agent/agent_import.py` / cron / gateway tools。
- 四条 resolver 层级（源码注释顺序）：
  - custom_provider 精确（`_resolve_named_custom_runtime`，`:1049`），否则池 `load_pool(provider)`；
  - `_resolve_openrouter_runtime`（`:1181`）；
  - `_resolve_azure_foundry_runtime`（`:1323`）；
  - `resolve_provider` 兜底。

### 6.2 别名与语义路由

- `ProviderProfile.aliases`；`PROVIDER_REGISTRY[_alias] = pconfig`（`auth.py:538-539` 自动扩表）。
- `resolve_requested_provider` 就做别名归一。
- OpenRouter 聚合内部路由由服务端决定（`provider_routing` 配置，`cli-config.yaml:165` 为 OpenRouter 端选项，note：不是 Hermes 自身）。
- 负载均衡：无；同一 provider pool 是多 Key 轮换，不跨 base_url 均衡。
- **运行时 `/model` 切换**（`hermes_cli/model_switch.py`）经多次提交修复了三类问题：
  - 凭据作用域：picker/`switch_model` 的用户 provider key 读取改走 per-profile secret scope（`_scoped_key_env`，`0569c001`/`0c97a883`），multiplex 下不再误取他 profile 的 key；
  - 歧义别名：如 `/model opus` 命中多个目录模型时，改为列出候选而非启发式猜测（`b79e8382`）；
  - 日期型快照排序：`_model_sort_key` 把 YYYYMMDD 日期戳从版本元组中拆出，修复 claude-opus-4-20250514 被当作版本号 20,250,514 排序的错误（`21bc9ba3`）。

---

## 7. 多 Key、限流、重试与故障转移

分层（`agent/agent_runtime_helpers.py` 与 `agent/chat_completion_helpers.py`）：

| 层级 | 机制 | 触发 | 位置 |
|---|---|---|---|
| L0 | OpenAI SDK 内建重试 | 网络瞬时错误 | SDK |
| L1 | Hermes 全链重试 | API error（连接、5xx） | `agent/conversation_loop.py`（循环 `recover_...`） |
| L2 | **同 provider 多 Key 轮换** | 429 / 401 / rate-limit | `agent/agent_runtime_helpers.py:926 recover_with_credential_pool` → `:1025 _rotate_failed_credential` → `credential_pool.mark_exhausted_and_rotate`（`:2031`）；`agent/credential_pool.py:1769 select` 选下一个可变 Key |
| L3 | **模型 fallback（同渠道换模型）** | 模型 400 / context overflow / 单模型报错 | `agent/conversation_loop.py`；通过 `agent.model` 切换 |
| L4 | **跨渠道 fallback 链**（不同 provider/provider endpoint） | L1-L3 后仍在失败 / 明确 error | `agent/chat_completion_helpers.py:1923 try_activate_fallback` → `agent/agent_runtime_helpers.py:1459 restore_primary_runtime` 恢复主通道 |

- credential pool 持久化：`write_credential_pool`（`hermes_cli/auth.py:1688`）与 `read_credential_pool`（`:1574`）；条目含 `last_status`/`quota`/`cooldown`，冷却结束后自动恢复，选择逻辑见 `_cooldown_remaining`（`agent/credential_pool.py` 约 `:729`，未逐行确认）。
- 是否重复计费/重复生成：同一请求 429 时 `recover_with_credential_pool` 只换 Key 重发（同一 `api_kwargs`，不重建 messages）；`try_activate_fallback` 则重建 transport 并重新发送同一消息，通常会产生第二次调用费用——重复生成风险在 L4 切换后显著存在（`chat_completion_helpers.py:1923-1990` 附近注释说明 switch 后继续同一任务）。是否重复计费取决于 Provider 撤回策略，笔记无法定论——标注为“**存在重复计费可能（推断）**”。
- `cli.py:4546`/`agent/chat_completion_helpers` 都从 `get_fallback_chain` 读取 `fallback_model`/`fallback_providers`。

---

## 8. 连接检测、日志与可观测性

### 8.1 设置页测试 vs 真实链路

- **真实聊天链路**：`resolve_runtime_provider` → transport → SDK call。
- **设置页/凭据测试**：
  - `POST /api/providers/validate`（web_server.py:7628）：对 `_CREDENTIAL_PROBES`（:7240，仅 OPENROUTER/OPENAI/GEMINI/XAI 四组 header 规则的 /models 端点）直接 `httpx` GET 验证 key；**只探活不测全部 Provider**（对其他 provider 返回 reachable=False）。
  - `POST /api/providers/custom-endpoints/validate`（:7600）：对用户输入 base_url + 可选 key 探 `GET {base_url}/models`，可返回该 endpoint 模型列表。
  - `doctor.py:_probe_apikey_provider`（`hermes_cli/doctor.py:2475`）对已配置 API-key provider 逐查询 `/models`（部分 provider `supports_health_check=False` 跳过）。
  - **`hermes doctor --live`**（`hermes_cli/doctor_live.py`）：opt-in 的真实网络探针，逐个（顺序、每项 ~10s 超时）请求**元数据端点**——firecrawl 用量、fal 模型列表、openai/groq /models、elevenlabs voices——只读、失败隔离、未配置后端跳过（`doctor_live.py:1-40` 模块不变量）。与设置页探活同属"非真实聊天链路"，但覆盖的是**外部托管后端**而非 Provider 端点。
- **结论**：设置页测试使用独立请求路径，只验证 endpoint 可达 + 单模型 URL 探活；**不经过真实 resolver、不经过 credential pool、不经过 fallback 链**。真实聊天还可能失败于 transport 组装 / 认证头注入 / 模型名不匹配等。因此不能从“设置页测试通过”推断真实聊天一定可用（指南事项 3 已确认成立）。

### 8.2 日志与错误

- `agent/redact.py` 全局脱敏（如上）；`hermes_cli/logging.py setup_logging`；`/logs` 可审计。
- 错误归一：`format_runtime_provider_error`（`hermes_cli/runtime_provider.py:2295`）；`agent/` 下错误分类见 `agent/error_classifier.py`（`FailoverReason`，`agent/error_classifier.py:24`）。（本次为浅览。）

### 8.3 用量/成本

- `agent/account_usage.py`、`agent/usage_tracker.py` 存在（本次未深入），桌面 billing 独立做显示。

---

## 9. 平台边界（桌面 / Web / 服务端 / 本地模型服务）

- Electron 桌面（apps/desktop）：`apps/desktop/AGENTS.md` 是 scoped 架构说明；渲染层通过 `@hermes/shared` 的 JsonRpcGatewayClient + WS 与 `tui_gateway` 后端通信。Providers Settings 通过 Desktop API bridge 调用 REST；Custom endpoints 表单是当前唯一找到的端点 CRUD UI。
- **Web dashboard（web/）**：`EnvPage` 展示 `GET /api/env`（redacted），支持 `.env` key 的新增/替换/清除/ reveal；OAuth 卡片调用 `/api/providers/oauth`。模型页使用 `/api/model/options`。本次未找到 Web Dashboard 的 Custom endpoints 页面或调用 `/api/providers/custom-endpoints` 的代码，因此服务端路由存在不等于 Web UI 可达。
- **TUI（ui-tui + tui_gateway）**：`modelPicker.tsx` 调用 `model.options` 展示全 Provider 目录；未认证的 API-key Provider 可在选择器内输入 key，由 `model.save_key` 写入 `.env`；Ctrl+D 通过 `model.disconnect` 清除认证。它操作的是已有 Provider 的认证和模型选择，不创建/编辑/删除 `providers.<name>` 端点。
- **服务端（gateway）**：`gateway/run.py` 用 `resolve_runtime_provider`；multiplex profile 时 `set_secret_scope`。
- **本地模型服务**（Ollama / LM Studio）：`model.provider=custom` + `base_url`（本机）；key 可选（`no-key-required`），custom provider 配置 `api_key` 或在 custom provider 配置 `extra_headers`。

---

## 设计取舍与已确认边界

1. **声明式 Provider 标识 vs 运行时端到端组装分离**：`ProviderProfile` 只描述，不共构建 client（`providers/base.py:7-9`），transport 层负责请求/应答边界——清晰，但也意味着 profile 无法独立决定底层 Client 行为（Gemini 通过覆盖 build_extra_body / native client 绕过）。
2. **多 Provider ≠ 自动故障转移**：默认只有 1 个 primary；`fallback_providers` 需用户在配置中显式声明链。Provider 支持与 failover 能力两者解耦（指南 §2 提醒得到确认）。
3. **凭据多路复用是显式策略**：多 Key 同 Provider 用 credential pool（authed_cli 的平行用户故事）；跨 Provider failover 用 fallback 链；模型级回退另用 `fallback_model`。三机制正交。
4. **前端看不到原始 Key**：redacted 值 + reveal 限控；即使暴露也仅对 .env / OAuth 会话。
5. **测试链路隔离**：设置页探活不触发完整 transport 集（高可探测、假阳性风险）。
6. **Repeat 收费的可能**：跨端点 failover 会重建并重发（重复生成与计费风险存在，但具体由上游服务端判定）——推断性结论。
7. **No channel concept**：未发现 `channel` 作为 LLM Provider 语义的关键词（检索 `hermes_cli/` `agent/` 后只有消息平台 channel）。若行业中其他项目把“一个 baseURL+key 组合”叫渠道，本项目的对应物就是**custom provider 条目 / provider_pool 条目**。

---

## 当前 Provider 发现与参数边界

Provider 注册新增 pip entry-point 来源，但仍受插件启用配置约束：发现器只加载已启用的 `hermes_agent.plugins` 条目，失败记录为诊断而不是隐式启用（`providers/__init__.py:149-251`、`287-301`）。自定义 `base_url` 在模型拉取时优先于 `models_url`，减少自建兼容端点把模型查询错误导向目录地址的风险。推理强度也按具体模型的 wire vocabulary 转换；因此配置中相同的抽象级别不再可假定会向所有 Provider 发送同一字面值。

## 未验证事项（本次未覆盖/未能确认）

- 真实运行验证：未实际执行任何请求，所有能力基于静态代码路径（尤其 SDK 重试、Pool 冷却持久化后的跨进程行为）。
- `agent/credential_pool.py` 的 `_cooldown_remaining` 等细节行号（约 `:729`）未逐行确认；`agent/usage_tracker.py`、`agent/account_usage.py` 未深读。
- `models.py:731-1019` Nous 推荐模型拉取（`fetch_nous_recommended_models`）与 `provider_models_cache.json` 结构（`models.py:3145` 是否存在 schema）未逐一验证。
- `hermes_cli/config_migrations.py` 迁移纵深（_migrate_to_12 → _migrate_to_33 等）内容未逐条阅读。
- Provider 插件与 deferred 注入的执行时机依赖（懒 import）未运行验证。
- 没有启动 CLI、TUI、Web 或 Electron Desktop，未验证保存/删除后的实际刷新、配置文件权限、浏览器/桌面 API bridge、Windows 平台行为和真实网络结果。
- 本次未逐条阅读 `hermes_cli/profiles.py` 的导出实现正文；Profile 导出/导入命令入口和备份敏感文件名单已确认，但单个 Profile archive 是否对每个 `providers` 字段逐项脱敏、恢复后端点和 key 的精确结果未验证。
- Web Dashboard 的“未找到 custom endpoint UI”结论来自 `web/src/pages`、`web/src/lib/api.ts` 的静态搜索；不排除插件或运行时注入页面提供额外入口。

---

## 关键源码索引

| 主题 | 位置 |
|---|---|
| ProviderProfile（声明式标识） | `providers/base.py:38` |
| provider 注册/懒发现 | `providers/__init__.py:43-70`（`register_provider` `:54`、`get_provider_profile` `:68`） |
| Provider 插件目录（35 个） | `plugins/model-providers/<name>/__init__.py` |
| 4 类 transport 注册与分发 | `agent/transports/__init__.py:21-67` |
| OpenAI-compat transport 组装 | `agent/transports/chat_completions.py:356-420`、`:599 _build_kwargs_from_profile` |
| 运行时取舍决策 | `hermes_cli/runtime_provider.py:1665 resolve_runtime_provider`（多分支：custom/openrouter/azure/pool） |
| 运行时 `/model` 切换 | `hermes_cli/model_switch.py`（secret scope key 读取、歧义别名候选、`_model_sort_key` 日期拆分） |
| fallback 链读取 | `hermes_cli/fallback_config.py:80 get_fallback_chain` / `cli.py:4546` |
| credential pool 轮换 | `agent/agent_runtime_helpers.py:926 recover_with_credential_pool`、`:1025 _rotate_failed_credential`、`credential_pool.py:1769 select/`:2031 mark_exhausted_and_rotate` |
| credential 持久化 | `hermes_cli/auth.py:1574/1688 read/write_credential_pool`、`_save_auth_store` `:1322` |
| .env 读写/镜像清理 | `hermes_cli/credential_lifecycle.py:213/:245`、`hermes_cli/config.py:3703 load_env / :3924 save_env_value` |
| 桌面/Web 设置页测试端点 | `hermes_cli/web_server.py:7522 custom-endpoints POST`、`:7575 DELETE`、`:7541 activate`、`:7600 validate custom`、`:7628 validate`、`:7721 reveal` |
| Desktop 自定义端点表单 | `apps/desktop/src/app/settings/custom-endpoints-settings.tsx:77-403`；REST bridge `apps/desktop/src/hermes.ts:913-950` |
| Desktop Provider Accounts/API keys | `apps/desktop/src/app/settings/providers-settings.tsx:47-506` |
| TUI Provider/模型/Key 操作 | `ui-tui/src/components/modelPicker.tsx:68-441`；`tui_gateway/methods_complete.py:357-509` |
| Web `.env` 凭据页面 | `web/src/pages/EnvPage.tsx:609-1009`；`web/src/lib/api.ts:577-589` |
| CLI 配置、认证和 Profile 命令 | `hermes_cli/subcommands/config.py:12-68`、`subcommands/auth.py:12-98`、`subcommands/profile.py:12-145` |
| doctor 健康探测 | `hermes_cli/doctor.py:2475 _probe_apikey_provider`；`hermes_cli/doctor_live.py`（`--live` 真实元数据端点探针） |
| 子进程 env 脱敏 | `tools/environments/local.py:456 _sanitize_subprocess_env`、`bang_shell.py:131` |
| 日志/错误脱敏 | `agent/redact.py:68-76` 起；`hermes_cli/logging.py` |
| MCP env 脱敏 | `hermes_cli/agent_import.py:367 sanitize_mcp_env`、`:85 is_secret_key` |
| profile scope / multiplex | `agent/secret_scope.py:40 set_multiplex_active`、`:72 set_secret_scope`、`:272 build_profile_secret_scope`、`:132 get_secret`、`gateway/run.py:1911` |
| 模型目录静态表+拉取 | `hermes_cli/models.py:221` `_PROVIDER_MODELS`、`:1504` fetch、`provider_models_cache.json` 引用 `models.py:3197`；`:4737 cached_fetch_api_models`（custom 端点探活缓存） |
| 元数据（上下文长度） | `agent/model_metadata.py`（provider 前缀实时查注册表） |
