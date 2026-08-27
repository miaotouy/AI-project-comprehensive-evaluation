# Open WebUI LLM 渠道管理调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`d3e8bf3405e848cfba377814d0aa7ba7290e414d`（分支：`main`）
>
> 调查方式：只读核对当前快照的 Python 后端、Svelte Web 界面、TypeScript API 封装、环境变量示例、CLI 入口、变更记录和仓库文件分布；未运行服务，未修改项目源码
>
> 调查范围：配置文件、数据库配置、管理员 Web Connections、用户 Direct Connections、CLI、TUI、桌面端、模型目录、连接测试、协议适配、凭据、启停、删除、导入导出、路由和故障处理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 当前把服务端 LLM 渠道表示为 OpenAI 兼容连接或 Ollama 后端的配置行，而不是一个独立的 Provider 实体。每条连接至少由 URL 和按索引关联的配置对象组成；OpenAI 连接另有同索引的 API Key，Ollama 的 Key 放在该连接配置对象中。一个服务端可以配置多个 OpenAI 兼容 URL 和多个 Ollama URL，但没有通用的渠道复制、导入单条连接或导出单条连接操作。

- 环境变量是启动默认值。`OPENAI_API_BASE_URL(S)`、`OPENAI_API_KEY(S)`、`OLLAMA_BASE_URL(S)` 和对应配置在启动配置中形成默认配置；当前代码的 `Config.seed_defaults` 只向数据库补入不存在的 key，已有数据库值优先。
- 服务端运行时配置保存于数据库 `config` 表，按配置 key 分行存储，连接数组和连接配置字典分别保存为 `openai.api_base_urls`、`openai.api_keys`、`openai.api_configs`、`ollama.base_urls`、`ollama.api_configs`。管理员 Web Connections 的保存直接更新这些值。
- `config.json` 仅保留旧版本迁移用途：首次发现 `DATA_DIR/config.json` 时读入数据库并改名为 `old_config.json`。本次未找到把当前连接配置持续写回配置文件的路径。
- 管理员 Web Connections 支持查看、添加、编辑、启用/停用、删除和连接测试；没有复制单条连接入口。保存后会清模型目录缓存并重新拉取模型列表，但这不是连接测试。
- 用户 Web Direct Connections 是另一套用户设置中的 OpenAI 兼容连接列表。管理员只控制 `ENABLE_DIRECT_CONNECTIONS` 开关；用户可以查看、添加、编辑、启用/停用、删除并在浏览器中直接测试。它不进入服务端 `Config` 表，也不提供 Ollama、服务端代理、管理员导入导出或跨用户共享。
- OpenAI 和 Ollama 的连接测试都是独立的管理员后端 `/verify` 路径：OpenAI 通常请求 `{url}/models`，Azure 请求模型端点，Anthropic 使用专用模型请求；Ollama 请求 `{url}/api/version`。模型列表刷新则使用 `/models` 或 `/api/tags`，不能用来替代连接测试。
- OpenAI 模型在合并时通常由首次出现的连接占用固定 `urlIdx`，没有通用跨连接 failover；Ollama 同名模型记录多个后端索引，请求时随机选择后端。代码中未找到 LLM 请求失败后的通用重试循环。
- CLI 入口只有 `serve`、`dev` 和 `--version` 等启动相关命令，没有渠道查看、新增、编辑或测试子命令。本仓库内未找到 TUI。变更记录提到独立的 `open-webui/desktop` 桌面仓库，但该仓库不在本次调查范围内，因此桌面端连接管理能力未验证。

## 系统边界与总体调用链

这里的“渠道”指一个可被 Open WebUI 代理访问的模型服务连接；Provider 是连接配置中的适配提示，例如 Azure、LiteLLM 或 llama.cpp，不是可独立创建的注册实体；Endpoint 是 URL；模型是上游模型目录中的条目或 Open WebUI 数据库中的 workspace model；凭据是 API Key、会话/OAuth 令牌或自定义 Header。

管理员服务端链路如下：

```text
环境变量/默认配置
  -> 启动时 seed_defaults 或旧 config.json 迁移
  -> 数据库 Config 表
  -> 管理员 Web Settings > Connections
  -> /openai/config/update 或 /ollama/config/update
  -> 清理模型缓存并拉取 /models 或 /api/tags
  -> 根据模型元数据记录的 urlIdx 路由真实聊天请求
```

用户直连链路不同：

```text
用户 Settings > Connections
  -> 浏览器保存到用户设置中的 directConnections
  -> 允许时直接请求用户填写的 OpenAI 兼容 URL
```

管理员 Web 读取 `/openai/config`、`/ollama/config` 和 `/configs/connections`；保存连接分别调用 `/openai/config/update`、`/ollama/config/update`。后端路由使用管理员依赖保护这些服务端配置接口。实现见 `backend/open_webui/routers/openai.py:392-429`、`backend/open_webui/routers/ollama.py:288-348` 和 `backend/open_webui/routers/configs.py:139-160`。

## 1. Provider、渠道与 Endpoint 数据模型

### 1.1 服务端连接

OpenAI 兼容连接由三个并行数组/字典组成：URL 列表、Key 列表和按数字索引保存的配置字典。读取连接时先按数字索引查配置，只有旧数据才回退到以 URL 为 key 的格式。后端会将 Key 列表裁剪或补空，使其长度与 URL 列表一致。Ollama 使用 URL 列表和配置字典；其中 `config.key` 是该后端的 Key。

每个连接配置可保存启用状态、模型白名单、模型 ID 前缀、标签、连接类型、认证类型、自定义 Header、Provider、Azure 参数、API 类型和允许透传的参数。OpenAI 可选择 Chat Completions 或 Responses API；Azure 的部署名称通过 `model_ids` 录入。字段契约见 `backend/open_webui/models/config.py:38-53`，表单组装见 `src/lib/components/AddConnectionModal.svelte:198-214`。

同一类连接可以创建多个 Endpoint。OpenAI 合并同名模型时保留首次出现的连接并记录 `urlIdx`；Ollama 合并同名模型时保留所有后端索引，之后由随机选择逻辑挑选后端。分别见 `backend/open_webui/routers/openai.py:529-711` 和 `backend/open_webui/routers/ollama.py:351-366`。

### 1.2 用户 Direct Connections

Direct Connections 只允许用户填写 OpenAI 兼容 Endpoint。每个用户设置对象仍然使用 URL、Key 和按索引的配置字典，但这些值属于用户设置，管理员 Web 连接和服务端数据库配置不会自动合并进去。用户端组件明确把配置放入 `saveSettings({ directConnections: config })`，见 `src/lib/components/chat/Settings/Connections.svelte:22-63`。

## 2. 配置生命周期、管理入口与持久化

### 2.1 配置文件和数据库

`.env.example` 展示的 `OLLAMA_BASE_URL`、`OPENAI_API_BASE_URL` 和 `OPENAI_API_KEY` 是部署时的环境变量入口。完整默认配置在 `backend/open_webui/config.py` 中组装，并通过 `DEFAULT_CONFIG` 提供给配置模型。环境变量不会像 Web 表单一样提供逐连接编辑器；要修改它们需改部署环境并重启。

当前配置模型每个 key 使用一行数据库记录，列为 `key`、JSON `value` 和更新时间。`Config.get`/`get_many` 在持久化配置开启时先查数据库，缺失时回退默认值；`seed_defaults` 只插入不存在的默认 key。因此环境变量是种子/回退来源，数据库是运行时权威来源，而不是每次启动都覆盖数据库。见 `backend/open_webui/models/config.py:99-165`、`196-218`、`239-264`。

旧版 `DATA_DIR/config.json` 会在启动迁移函数中整体写入数据库，然后重命名为 `old_config.json`。这是迁移路径，不是当前连接的文件编辑协议。见 `backend/open_webui/config.py:82-89`。

### 2.2 管理员 Web Connections 操作矩阵

| 操作 | OpenAI/Ollama 管理员 Connections | 证据与边界 |
|---|---|---|
| 查看已有渠道 | 支持 | 页面加载两个 `/config` 接口，按 URL 行渲染；Key 通过敏感输入展示。 |
| 新增渠道 | 支持 | `Add Connection` 弹窗追加 URL 和对应配置索引，随后保存到服务端。 |
| 编辑已有渠道 | 支持 | 每行的配置按钮打开编辑弹窗；URL 在行内只读，但编辑弹窗可修改。 |
| 复制渠道 | 未找到 | 检查 Connections、AddConnectionModal 和连接 API，未找到复制已有连接并生成新索引的入口。 |
| 启停 | 支持 | 全局 OpenAI/Ollama 开关控制整类服务；每行 `config.enable` 控制单连接。 |
| 删除 | 支持 | 删除 URL、Key 并重排配置索引，随后调用对应更新接口。 |
| 导入单条渠道 | 未找到 | 未找到连接专用导入格式或导入按钮。 |
| 导出单条渠道 | 未找到 | 未找到连接专用导出按钮。 |
| 连接测试 | 支持 | 新建/编辑弹窗的 Verify Connection 调用独立 `/verify`；测试不保存配置。 |

管理员页面由 `src/lib/components/admin/Settings/Connections.svelte:54-139` 负责保存和新增，由 `:257-334` 负责已有连接的编辑、删除和启停。编辑器的验证、字段校验和删除确认见 `src/lib/components/AddConnectionModal.svelte:74-230`、`:741-788`。

### 2.3 用户 Web Direct Connections 操作矩阵

| 操作 | Direct Connections | 证据与边界 |
|---|---|---|
| 查看已有渠道 | 支持 | 用户设置加载 `settings.directConnections` 并逐行显示。 |
| 新增渠道 | 支持 | 用户设置中的 Add Connection 复用连接弹窗。 |
| 编辑渠道 | 支持 | 复用编辑弹窗，保存整个用户连接配置。 |
| 复制渠道 | 未找到 | 用户连接组件和弹窗未提供复制入口。 |
| 启停 | 支持 | 每行 `config.enable` 由 Switch 修改。 |
| 删除 | 支持 | 删除 URL、Key 并重排配置索引；需要之后提交用户设置。 |
| 导入/导出 | 未找到 | 本次未在用户连接组件或其 API 中找到连接导入导出。 |
| 连接测试 | 支持 | `direct=true` 时浏览器直接请求 `{url}/models`，依赖上游 CORS；不是服务端 `/verify`。 |

Direct Connections 的总开关位于管理员 Connections 页面，保存为 `direct.enable`；默认值来自 `ENABLE_DIRECT_CONNECTIONS`。这个开关只决定能力是否开放，不把用户连接写进管理员的 OpenAI 连接列表，见 `backend/open_webui/routers/configs.py:42-45` 和 `src/lib/components/admin/Settings/Connections.svelte:352-383`。

### 2.4 通用管理员配置导入导出

管理员 Database 设置提供通用配置 JSON 导入导出，而非连接专用格式。`GET /configs/export` 返回 `Config.get_all()`，`POST /configs/import` 将传入字典直接 upsert；前端把导出结果保存为 `config-<timestamp>.json`。因此从静态实现看，通用导出可能包含 OpenAI/Ollama 连接配置及凭据，且本次未找到对 API Key 的导出排除或加密处理。相关路径为 `backend/open_webui/routers/configs.py:97-121`、`src/lib/components/admin/Settings/Database.svelte:85-118`。

这项通用导入可以改变数据库配置，但不等同于 Web Connections 页面中的逐条新增、编辑、删除，也没有在本次静态调查中确认导入后前端缓存和正在运行的连接状态如何更新。

## 3. 凭据、Header 与代理边界

服务端 OpenAI Key 与 URL 并列保存在数据库配置 JSON 中；Ollama Key 保存在对应连接配置中。连接读取接口向管理员前端返回配置，前端使用 `SensitiveInput` 进行界面展示。`Config` 模型本身是普通 JSON 列，没有显示加密字段或密钥专用存储逻辑；通用配置导出也直接返回全部配置。因此源码确认了 UI 敏感输入，但没有确认静态存储加密、导出脱敏或日志中全面排除凭据。

请求前，后端按 `auth_type` 组装 Bearer、无认证、会话凭据、系统 OAuth 或 Azure 身份凭据；自定义 Header 模板和用户信息 Header 也在此阶段处理。OpenAI 连接测试复用这套 Header/Cookie 组装逻辑，Ollama 验证只接收 URL 和 Key。真实聊天请求随后按连接 Provider 处理 Azure、Anthropic、Responses 或普通 OpenAI 兼容路径。入口见 `backend/open_webui/routers/openai.py:795-880` 和 `backend/open_webui/routers/ollama.py:247-285`。

用户 Direct Connections 的 Key 直接由浏览器发送给用户填写的 Endpoint，并且 OpenAI 测试也是浏览器直接访问 `{url}/models`。代码和界面均提示需要上游正确配置 CORS；这与管理员连接由 Open WebUI 服务端代发请求的边界不同。

## 4. 模型目录与能力元数据

OpenAI 连接默认从 `{url}/models` 拉模型；Ollama 从 `{url}/api/tags` 拉模型。连接配置提供 `model_ids` 白名单：有白名单时后端不必依赖完整上游目录，可直接或筛选出指定模型。前缀、标签、连接类型和 Provider 会注入统一模型条目。模型目录缓存由后端维护，保存连接后会清空相关缓存并重新获取模型。

`/models`、`/api/tags` 以及页面加载时的模型刷新只回答“有哪些模型”或更新缓存，不验证聊天生成能力。连接验证是单独的请求：OpenAI 普通连接请求 `/models`，Azure 和 Anthropic 有专用分支；Ollama 请求 `/api/version`。因此即使模型列表刷新成功，也不能据此记录为连接测试成功。

workspace 模型是另一层数据库实体，可以覆盖基础模型或基于基础模型生成预设，也有独立的模型编辑、克隆、导入导出和删除能力。本笔记不把 workspace 模型的克隆/导入导出算作渠道复制/导入导出；其路由位于 `backend/open_webui/routers/models.py`，与 Connections 配置分开。

## 5. Adapter、协议与请求组装

统一聊天入口根据模型元数据选择 Pipelines、Ollama 或 OpenAI 兼容路径。OpenAI 兼容路由会根据模型条目的 `urlIdx` 取得 URL、Key 和配置，剥离 `prefix_id`，再按 Provider 和认证类型组装请求。Azure 会改写模型部署路径和 API 版本；Anthropic 使用专用 Header/模型目录处理；Responses API 可由连接配置选择。

Ollama 既提供原生 `/api/chat` 等路径，也提供 OpenAI 风格 `/v1/chat/completions`、Anthropic Messages 和 Responses 适配路径。统一聊天工具会在 Ollama 模型与 OpenAI 风格请求之间转换请求参数和响应格式。连接类型字段主要影响元数据和请求策略，不创建独立 Provider 注册表。

## 6. 运行时选择、绑定与路由

聊天请求携带模型 ID。Open WebUI 先解析 workspace 模型与基础模型关系，再从已拉取的模型目录查找具体连接。OpenAI 模型条目保存一个 `urlIdx`，因此同名模型合并后的首个连接获胜；连接失败不会自动切换到同名的其他 OpenAI 连接。Ollama 同名模型保存多个 `urls` 索引，请求时随机选取一个后端；这是随机分摊，不是失败后重新选择的通用 failover。

`prefix_id` 可避免不同连接的模型 ID 冲突；展示和路由使用带前缀的 ID，出站请求前剥离该前缀。`tags`、`connection_type`、模型白名单和访问授权影响目录展示及可访问性，但本次未找到按价格、延迟或语义自动路由的实现。

## 7. 多 Key、限流、重试与故障转移

OpenAI Key 与 URL 按索引一一对应，没有在连接管理或请求路径中找到 Key 轮换、冷却或多 Key 负载均衡。Ollama 每个 URL 配一个可选 Key；多个后端同名模型随机选择后端，但未找到失败后重试另一后端的逻辑。

连接配置的 `enable` 会在拉取模型和请求时排除该连接；全局开关会关闭整类后端。请求使用统一超时和连接池设置，模型列表还有单独的较短超时。源码检索当前 OpenAI/Ollama 代理及聊天工具路径未找到 LLM 调用级重试循环；错误会归一化为连接错误或按上游状态返回，并发布模型提供方失败事件。

因此当前能力边界为：

| 能力 | 结论 |
|---|---|
| 多 OpenAI Endpoint | 支持，固定模型到 `urlIdx` |
| 多 Ollama Endpoint | 支持，同名模型随机选择后端 |
| Key 轮换 | 未找到 |
| 请求重试 | 未找到 LLM 调用级重试 |
| 跨 OpenAI 渠道 failover | 未找到 |
| Ollama 失败后跨后端 failover | 未找到；随机选择不等于 failover |
| 持久化健康状态 | 未找到 |
| 手动连接测试 | 支持，独立 `/verify` |

## 8. 连接检测、日志与可观测性

管理员新增/编辑弹窗中的 Verify Connection 不保存连接。OpenAI 后端验证普通 Endpoint 的模型列表接口，Azure 使用对应 Azure 模型接口，Anthropic 使用专用模型获取逻辑；Ollama 验证版本接口。测试结果以返回数据或错误提示呈现，未发现把验证结果作为持久化健康状态保存。

管理员保存连接后，前端主动刷新模型列表；后端更新接口清理缓存、清空应用状态中的基础/Provider 模型，并发布配置更新事件。这是配置变更后的目录刷新，不是连接测试。模型拉取失败也可能只表现为目录缺少模型，不能据此推断 `/verify` 的结果。

运行时上游失败会发布 `MODEL_PROVIDER_REQUEST_FAILED` 事件并按状态码分类，例如模型不存在、认证失败、限流和服务端错误；请求错误通常仍以 HTTP 错误体或连接错误返回。用量、成本和延迟不作为本次渠道管理结论，静态检查未在 Connections 管理页发现专门的连接级成本/延迟面板。

## 9. 平台与入口矩阵

| 入口 | 查看 | 新增/编辑 | 复制 | 启停/删除 | 导入/导出 | 连接测试 | 结论 |
|---|---|---|---|---|---|---|---|
| 环境变量/配置文件 | 可通过部署文件或环境读取 | 手工改环境并重启；旧 `config.json` 仅迁移 | 未找到 | 由配置值控制全局或连接 | 当前连接无专用文件格式；通用 JSON 迁移/导出走 Web API | 未找到文件/CLI 测试 | 配置种子和迁移来源，不是交互管理器 |
| CLI | 仅启动、开发、版本 | 未找到渠道子命令 | 未找到 | 未找到 | 未找到 | 未找到 | `backend/open_webui/__init__.py` 只有 `serve`、`dev` 和版本选项 |
| TUI | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 未找到 | 本仓库文件和依赖中本次未找到 TUI 入口；不是“确认不支持整个项目”的绝对结论 |
| 管理员 Web Connections | 支持 | 支持 | 未找到 | 支持 | 单条未找到；通用管理员配置 JSON 支持 | 支持 `/verify` | 服务端 OpenAI/Ollama 渠道的主要管理入口 |
| 用户 Web Direct Connections | 支持 | 支持 OpenAI 兼容连接 | 未找到 | 支持 | 未找到 | 支持，浏览器直连 `/models` | 用户级设置，依赖 CORS，不等同管理员渠道 |
| 桌面端 | 未验证 | 未验证 | 未验证 | 未验证 | 未验证 | 未验证 | 变更记录指向独立 `open-webui/desktop` 仓库，本地未提供其源码 |

桌面端的已确认事实仅限于当前仓库的 `CHANGELOG.md`：0.9.0 条目说明存在独立原生桌面应用，可运行本地 Open WebUI 或连接远程实例。该描述没有证明桌面端是否复用管理员 Web Connections、是否能管理连接，因此这些项目在本次调查中标记为未验证。

## 10. 设计取舍与已确认边界

- 服务端配置采用数据库逐 key 持久化，使环境变量可以作为首次启动默认值，同时避免每次启动覆盖管理员在 Web 中的修改。
- OpenAI 和 Ollama 共享相似的 URL 列表加连接配置结构，但连接测试协议不同：一个以模型目录为主，另一个以版本接口为主。
- 管理员连接通过服务端代理访问上游，用户 Direct Connections 直接从浏览器访问上游；两者在凭据暴露、CORS 和权限范围上有明确差异。
- 连接行的 `enable`、模型白名单、前缀和标签属于目录/路由配置；它们不等于上游服务本身的运行状态，也不产生持久化健康检查。
- 通用配置导入导出覆盖数据库中的全部配置 key，不能当作安全的单条连接分享格式。源码确认存在凭据返回和导出路径，但本次未验证实际部署数据库加密、备份保护或日志内容。
- Ollama 的随机后端选择提供了简单分摊，OpenAI 的固定 `urlIdx` 提供了确定性路由；二者都不能概括为通用的自动故障转移。

## 11. 未验证事项

- 未运行 WebUI，因此未验证浏览器实际视觉交互、保存失败时的界面状态、CORS、上游认证、缓存刷新时序和不同权限用户的可见结果。
- 未运行 `/verify`、`/models` 或 `/api/tags`，连接测试与模型刷新结论来自静态请求路径。
- 未对 SQLite、PostgreSQL 或其他部署方式实际检查数据库文件权限、备份内容和凭据是否由外部存储层加密。
- 未调查独立 `open-webui/desktop` 仓库，因此桌面端连接管理、导入导出和多服务器切换不能从本仓库推断。
- 本仓库内未找到 TUI 和渠道 CLI；这表示本次搜索范围内未找到实现，不将其扩展为对外部发行版或外部脚本的绝对否定。
- 未将模型刷新、workspace 模型克隆、Ollama 模型下载/复制/删除与 LLM 渠道的复制、导入、导出混同；这些是模型实体或上游模型管理操作。

## 12. 关键源码索引

- 环境变量、默认配置和旧配置迁移：`backend/open_webui/config.py:82-89`、`:217-357`
- 数据库配置模型、默认种子和持久化优先级：`backend/open_webui/models/config.py:99-165`、`:196-264`
- OpenAI 配置读取、保存和模型索引：`backend/open_webui/routers/openai.py:267-305`、`:392-429`、`:529-711`
- OpenAI 连接测试：`backend/open_webui/routers/openai.py:795-880`
- Ollama 配置读取、保存和连接测试：`backend/open_webui/routers/ollama.py:213-348`
- Ollama 多后端模型合并：`backend/open_webui/routers/ollama.py:351-366`、`:386-451`
- 管理员 Connections 页面：`src/lib/components/admin/Settings/Connections.svelte:54-139`、`:209-401`
- 连接新增/编辑/验证/删除弹窗：`src/lib/components/AddConnectionModal.svelte:74-230`、`:270-788`
- 管理员 OpenAI/Ollama 行组件：`src/lib/components/admin/Settings/Connections/OpenAIConnection.svelte`、`OllamaConnection.svelte`
- 用户 Direct Connections：`src/lib/components/chat/Settings/Connections.svelte:22-150`、`Connections/Connection.svelte`
- 通用配置导入导出：`backend/open_webui/routers/configs.py:97-121`、`src/lib/components/admin/Settings/Database.svelte:85-118`
- CLI 入口：`backend/open_webui/__init__.py:11-107`
- 桌面端线索：`CHANGELOG.md:885-890`，指向外部 `open-webui/desktop` 仓库
