# Open WebUI LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读源码核对（config.py 环境变量、models/config.py 持久化配置、routers/openai.py 与 routers/ollama.py、utils/models.py 模型解析、main.py 路由挂载）；未修改目标仓库
>
> 调查范围：渠道配置来源、统一模型解析、OpenAI 兼容代理与 Ollama 代理、密钥与多后端、认证与流式转发、错误归一化与重试、前端管理页
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.0 把「渠道」建模为**一条 Base URL 一行**的配置行（OpenAI 兼容与 Ollama 各有独立的 URL 列表），并在运行时统一成一个 OpenAI 风格模型目录，对客户端暴露 `/api/chat/completions` 单入口。

- 配置双轨制：环境变量只是启动种子（`DEFAULT_CONFIG`），运行时逐 key 持久化在数据库 `Config` 表，`ENABLE_PERSISTENT_CONFIG` 默认开启使 DB 优先于环境变量；
- 多渠道用分号分隔的列表表达：`OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS` / `OLLAMA_BASE_URLS` 均按 `;` 拆分，每条 URL 配一个序号 idx，`OPENAI_API_CONFIGS` 以 `"0"`/`"1"` 为 key（兼容以 URL 为 key 的旧格式）；单个 `OPENAI_API_KEY`/`OPENAI_API_BASE_URL` 只代表「官方 OpenAI 渠道」；
- OpenAI 兼容渠道按「模型 id → urlIdx」**固定路由**（模型目录合并时首见渠道获胜），渠道失效即该模型 404，无故障转移；
- Ollama 多后端若托管同名模型，`merge_models_lists` 记录 `urls: [idx,...]`，请求时 `random.choice(urls)` 随机选一台——这是仓库中唯一的渠道级分摊/冗余逻辑；
- 模型解析统一在 `utils/models.py`：`get_all_base_models` 并发拉 OpenAI + Ollama + 函数模型，`base_model_lookup` 对 Ollama 先按 `id.split(':')[0]` 再按精确 id 匹配，自定义模型分「覆盖（base_model_id=None）」与「预设（preset）」两种形态并入列表；
- OpenAI 兼容层功能全：同一 `generate_chat_completion` 支持 OpenAI 原生、任意兼容服务、Azure（deployments 重写）、Anthropic（`x-api-key` 头）、Responses API 转换；`provider=='litellm'` 与 Anthropic URL 判定为 passthrough；
- 每连接 `auth_type` 支持 bearer / none / session / system_oauth / azure_ad / microsoft_entra_id，外加自定义 headers 模板（可引用 `{{USER_ID}}` 等变量）；
- **LLM 调用路径无 retry**：openai.py / ollama.py / utils/chat.py 均无重试循环，只有超时（默认 300s）、模型列表 10s 超时与错误归一化事件（`MODEL_PROVIDER_REQUEST_FAILED`，按状态码分类并记录 key 末四位）；
- 模型 id 语法：v0.11.0 不强制 `user.model` 命名，workspace 模型 id 是任意 ≤256 字符唯一串；上游 `prefix_id` 前缀在出站时剥离。

## 1. 渠道配置来源

### 1.1 环境变量（config.py）

**Ollama（224-302 行）**：

| 变量 | 行为 |
|---|---|
| `ENABLE_OLLAMA_API` | 默认 True |
| `OLLAMA_API_BASE_URL` | 默认 `http://localhost:11434/api` |
| `OLLAMA_BASE_URL` | 由 API 地址去 `/api` 推导；为空时 `_resolve_ollama_base_url`（255-277 行）并发探测 11434/12434 端口 |
| `OLLAMA_BASE_URLS` | `;` 拆分列表，多后端 |
| `OLLAMA_API_CONFIGS` | JSON 解析为 `{idx: {...}}` |

**OpenAI（304-357 行）**：

| 变量 | 行为 |
|---|---|
| `ENABLE_OPENAI_API` | 默认 True |
| `OPENAI_API_KEY` / `OPENAI_API_BASE_URL` | 单数变量，默认官方 `https://api.openai.com/v1` |
| `OPENAI_API_KEYS` / `OPENAI_API_BASE_URLS` | `;` 拆分列表；空项补官方地址 |
| `OPENAI_API_CONFIGS` | JSON 对象，key 为序号或旧式 URL |
| 351-357 行特殊行为 | 解析完成后单数变量被重置为官方渠道对应值；真正多渠道路由全部走复数列表 |

- 下游（RAG、图片、音频）引用单数变量，多渠道路由引用复数列表（DB key `openai.api_base_urls` 等）；
- 种子注册：`seed_registered_defaults` → `Config.seed_defaults`（models/config.py 239-264 行），`DEFAULT_CONFIG` 在 config.py 2788-3183 行；
- 迁移：`migrations/versions/3ff2c63645b8_reshape_config_to_per_key_rows.py` 把旧扁平 key 折叠为逐行配置，`API_CONFIG_FIELDS` 覆盖 enable/key/prefix_id/tags/model_ids/connection_type/provider/auth_type/headers/azure/api_type/api_version/extra_params/passthrough_params。

### 1.2 运行时配置（models/config.py）

- `ENABLE_PERSISTENT_CONFIG`（默认 True）使 DB 优先：`Config.get_many` 先读 DB 逐 key 存储，缺失回退环境变量；
- 前端管理页「Connections」按行渲染每条 URL 连接，每条可独立 enable、配置 auth/headers/model_ids 等——即「连接行 = 渠道」。

## 2. 统一模型解析（utils/models.py）

- `fetch_ollama_models`（33-48 行）：`/api/tags` 的 `model/name` 归一成 OpenAI 风格 `{id, name, owned_by:'ollama', connection_type, tags}`；
- `get_all_base_models`（56-64 行）：并发拉 OpenAI + Ollama + 函数模型，顺序为 functions + openai + ollama；
- `get_all_models`（67-428 行）：
  - 缓存：`request.app.state.BASE_MODELS`（开关 `models.base_models_cache`），最终结果写 `request.app.state.MODELS`；
  - `base_model_lookup`（149-153 行）：Ollama 模型先用 `id.split(':')[0]`（去 tag）登记，再按精确 id 登记，**精确优先**；
  - 自定义模型（157-242 行）：`base_model_id is None` → 对基础模型**覆盖**（同名覆盖 name/info/actions/filters）；`base_model_id` 存在 → 生成新条目 `{id: custom_model.id, owned_by: 继承, preset: True, ...}`；基础模型查找有 `split(':')[0]` 回退；`params` 被删除避免泄露给列表 API；
  - 全局默认 meta 合并（312-332 行）、actions/filters 装配（360-414 行）；
- `check_model_access`（431-472 行）：arena 走 access_grants，普通模型查 `Models.get_model_by_id` + `AccessGrants` + `has_base_model_access`（沿 base_model_id 链逐跳）；
- 排序/去重在 `main.py /api/models`（839-887 行）：按 `ui.model_order_list` 排序、按 id 去重、过滤 pipeline 类型、去 profile_image_url；
- 失败兜底：`ENABLE_CUSTOM_MODEL_FALLBACK`（默认 False）时自定义模型的 base_model 缺失则回退 `ui.default_models` 第一项（main.py 1100-1115 行）。

## 3. OpenAI 兼容代理路由（routers/openai.py，挂载 `/openai`）

### 3.1 连接与模型目录

- `get_openai_connection(idx)`（300-305 行）：按序号取 `(url, key, api_config)`，config 查找顺序 `configs[str(idx)]` → `configs[url]`（旧兼容）；
- `get_all_models_responses`（528-612 行）：对每个启用渠道并发 `GET {url}/models`（Anthropic 走专用拉取）；`model_ids` 白名单存在时**不请求上游**直接构造列表；`prefix_id` 加前缀（599-600 行）、tags/connection_type/provider 注入；
- `get_all_models`（646-711 行，aiocache TTL=`MODELS_CACHE_TTL` 默认 1s）：`get_merged_models` 按 model_id 去重，**首见渠道获胜**（683 行），`urlIdx` 记录来源；`api.openai.com` 主机过滤不支持关键词（babbage/dall-e/davinci/embedding/tts/whisper）；
- `GET /models` 与 `/models/{url_idx}`（714-785 行）：单渠道直连测试。

### 3.2 chat/completions 转发（1182-1435 行）

```text
enabled 检查
  -> base_model_id 解析（改写 payload['model']）
  -> apply_model_params_to_body_openai + apply_system_prompt_to_body
  -> 查 OPENAI_MODELS 定 urlIdx（模型 id -> 渠道固定路由）
  -> strip_provider_model_prefix（剥离 prefix_id 前缀）
  -> 推理模型参数处理（is_openai_new_model）
  -> headers/cookies（auth_type 分支）
  -> Azure 分支（convert_to_azure_payload + api-key 头 + api-version）
     / Responses 分支（convert_to_responses_payload）
  -> aiohttp 转发（超时 get_client_timeout(stream=...)）
  -> SSE 检测 text/event-stream 流式透传（stream_wrapper + stream_chunks_handler）
  -> 非 2xx 归一化返回 + publish_model_provider_request_failed
```

- 流式转发剔除 `Content-Encoding/Content-Length/Transfer-Encoding`（80-87 行）；超大 chunk 超过 `CHAT_STREAM_RESPONSE_CHUNK_MAX_BUFFER_SIZE` 时输出空 `{}` 并跳过（utils/misc.py 1152-1198 行）；
- 其它端点：`/embeddings`（1438）、`/responses`（1564）、`/verify`（795-880 行，管理员手动测连接）、`/audio/speech`（455）、`/config` + `/config/update`（392-452 行，更新后清缓存并发 `MODEL_PROVIDER_CONFIG_UPDATED` 事件）、`/{path:path}` 透传代理（1674-1793 行，默认 403，`ENABLE_OPENAI_API_PASSTHROUGH` 开关）。

### 3.3 Ollama 代理（routers/ollama.py，挂载 `/ollama`）

- `send_request`（96-196 行）：POST/GET 统一转发，失败时 `publish_model_provider_request_failed`（142-162 行）；
- `merge_models_lists`（351-366 行）：多后端同名模型去重，`urls` 记录所有后端 idx；
- `get_all_models`（386-451 行）：对每个后端 `GET {url}/api/tags`（可带 key），prefix_id/tags/connection_type/model_ids 过滤后合并，失败后端记入 `failed_idxs` 并在 `/api/ps` 中跳过；
- `/api/chat`（1086-1160 行）：模型权限 → base_model 解析 → `apply_model_params_to_body_ollama` → `get_ollama_url`（1068-1083 行，`random.choice(models[model]['urls'])`）→ `strip_provider_model_prefix` → 转发；`validate_ollama_backend_idx`（1055-1065 行）限制普通用户不能指定任意后端；
- 其它：`/api/tags`、`/api/ps`、`/api/version`（多后端取最低版本）、`/api/generate`、`/api/embed(s)`、`/api/pull/push/create/copy/delete/show/unload`。

### 3.4 统一归一（utils/chat.py 282-307 行）

```text
模型元数据分流：
  pipe -> pipelines 函数
  owned_by=='ollama' -> OpenAI payload 转 Ollama 格式，调 /ollama/api/chat，响应再转回 OpenAI 格式
  否则 -> /openai/chat/completions
```

- 格式转换：`convert_payload_openai_to_ollama`（utils/payload.py 299-387 行，`max_tokens→num_predict`、options 映射）、`convert_response_ollama_to_openai` / `convert_streaming_response_ollama_to_openai`（utils/response.py 215-275 行，Ollama `thinking`→reasoning_content、`data: [DONE]` 收尾）。

## 4. 密钥管理与多后端

- key 列表归一化：`normalize_openai_api_keys`（openai.py 290-297 行）与 `/config/update`（408-411 行）把 key 列表裁剪/补齐到与 URL 列表等长；
- **OpenAI 侧无轮换、无故障转移**：模型 id → urlIdx 固定（首见获胜），渠道挂了该模型即 404（1244-1247 行）；无健康检查端点（仅 `POST /verify` 是手动测连接）；
- **Ollama 侧随机选择**：多后端同名模型 `random.choice(urls)`——这是唯一的冗余/分摊逻辑；选中后端失败即报错，无重试（推测：该行为从代码推断，未实测）；
- 请求失败事件 `publish_model_provider_request_failed`（events.py 1182-1250 行）：按状态码分类（404→model_not_found、401/403→authentication_failed、429→rate_limited、≥500→server_failed），记录 `api_key_suffix`（末 4 位）并发布 `MODEL_PROVIDER_REQUEST_FAILED` 事件。

## 5. 认证、流式、错误归一化、重试、超时

### 5.1 认证（openai.py `get_headers_and_cookies` 156-219 行）

| auth_type | 行为 |
|---|---|
| bearer（默认） | `Authorization: Bearer` |
| none | 无 token |
| session | 透传会话 cookie + JWT |
| system_oauth | `oauth_manager` 取 access_token |
| azure_ad / microsoft_entra_id | `DefaultAzureCredential` |

- 自定义 headers 模板可引用 `{{USER_ID}}` 等变量（utils/headers.py 87-141 行）；`ENABLE_FORWARD_USER_INFO_HEADERS` 时附加用户头/签名 JWT（37-62 行）；
- openrouter 特供 `HTTP-Referer`/`X-Title`（168-174 行）；
- Ollama：`Authorization: Bearer {key}`（ollama.py 76-81、116-119 行）；
- Anthropic：`x-api-key` + `anthropic-version`（utils/anthropic.py 49-52 行）；main.py `/api/message`（1881-1954 行）把 Anthropic Messages 请求转 OpenAI 再转回。

### 5.2 错误归一化与超时

- 上游错误体尽量原样回传（JSONResponse/PlainTextResponse），同时分类记录；连接异常 → HTTPException 500 `SERVER_CONNECTION_ERROR`；SSE 且 ≥400 时先读 body 再返回 JSON 错误（1352-1390 行）；
- 超时（env.py）：`AIOHTTP_CLIENT_TIMEOUT` 默认 300s（574-578 行）、流式 `sock_read` 空闲超时默认不限制（581-591 行）、模型列表 `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` 默认 10s（610-617 行）；
- 共享连接池 `AIOHTTP_POOL_CONNECTIONS`/`_PER_HOST`/`DNS_TTL`（664-688 行）；`MODELS_CACHE_TTL` 默认 1s（968-975 行）；SSL `AIOHTTP_CLIENT_SESSION_SSL`（597 行）；
- **Retry：无**（grep 确认 openai.py/ollama.py/utils/chat.py 无 LLM 调用级重试）；检索/向量库/Redis 有各自重试，与渠道无关。

## 6. 前端管理

- `src/lib/components/admin/Settings/Connections.svelte`：OpenAI/Ollama 各自逐 URL 行渲染、增删（删除后 config 序号重排 267-277 行）、`/openai/config/update` 与 `/ollama/config/update`；`ENABLE_DIRECT_CONNECTIONS` 与 `ENABLE_BASE_MODELS_CACHE` 开关；
- `AddConnectionModal.svelte`：每连接的 `enable/tags/prefix_id/model_ids/connection_type/auth_type/headers/passthrough_params`；Azure 需要 `api_version` + deployment `model_ids`；`provider='azure'` 与 URL 探测联动；
- `OpenAIConnection.svelte` / `OllamaConnection.svelte`：行组件（Ollama key 存 `config.key`）；
- `Settings/Models.svelte`：模型 upsert（覆盖式写 `base_model_id:null`）、克隆（`base_model_id=model.id, id='xxx-clone'`）、隐藏/公开/排序；
- API 封装：`src/lib/apis/openai/index.ts`、`src/lib/apis/ollama/index.ts`。

## 7. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| OpenAI 兼容多渠道 | 有 | URL 列表 + 序号配置 |
| Ollama 多后端 | 有 | 同名模型随机选择 |
| 按模型固定渠道路由 | 有 | urlIdx 固定，无 failover |
| 渠道故障转移 | 无 | 渠道失效即模型不可用 |
| 渠道健康状态 | 无 | 仅手动 verify 与失败事件 |
| Key 轮换/分摊 | 无（OpenAI）/ 随机（Ollama） | Ollama 后端随机为唯一分摊逻辑 |
| 请求重试 | 无 | LLM 调用路径无 retry |
| 超时控制 | 有 | 300s 默认，模型列表 10s |
| 自定义认证 | 有 | 6 种 auth_type + headers 模板 |
| Azure 适配 | 有 | deployments 重写 |
| Anthropic 适配 | 有 | 头 + 格式转换 |
| Responses API | 有 | 可选转换 |
| 上游错误归一化 | 有 | 分类事件 + 原样回传 |
| 模型目录缓存 | 有 | TTL 1s |
| prefix_id 前缀 | 有 | 出站剥离 |
| 透传代理 | 可选 | `ENABLE_OPENAI_API_PASSTHROUGH` |

## 8. 关键源码索引

- Ollama 环境变量：[`config.py`](../../open-webui/backend/open_webui/config.py)（224-302 行）
- OpenAI 环境变量：[`config.py`](../../open-webui/backend/open_webui/config.py)（304-357 行）
- 持久化配置：[`models/config.py`](../../open-webui/backend/open_webui/models/config.py)（99-265 行）
- 配置迁移：[`migrations/versions/3ff2c63645b8_reshape_config_to_per_key_rows.py`](../../open-webui/backend/open_webui/migrations/versions/3ff2c63645b8_reshape_config_to_per_key_rows.py)
- 统一模型解析：[`utils/models.py`](../../open-webui/backend/open_webui/utils/models.py)（56-428 行）
- OpenAI 代理：[`routers/openai.py`](../../open-webui/backend/open_webui/routers/openai.py)（300、528、1182 行）
- Ollama 代理：[`routers/ollama.py`](../../open-webui/backend/open_webui/routers/ollama.py)（351-451、1086-1160 行）
- 统一分流：[`utils/chat.py`](../../open-webui/backend/open_webui/utils/chat.py)（282-307 行）
- 参数转换：[`utils/payload.py`](../../open-webui/backend/open_webui/utils/payload.py)（299-387 行）
- 响应转换：[`utils/response.py`](../../open-webui/backend/open_webui/utils/response.py)（215-275 行）
- Anthropic 适配：[`utils/anthropic.py`](../../open-webui/backend/open_webui/utils/anthropic.py)
- 连接池与超时：[`utils/session_pool.py`](../../open-webui/backend/open_webui/utils/session_pool.py)
- 失败事件：[`events.py`](../../open-webui/backend/open_webui/events.py)（1182-1250 行）
- 前端连接管理：[`src/lib/components/admin/Settings/Connections.svelte`](../../open-webui/src/lib/components/admin/Settings/Connections.svelte)
- 连接编辑器：[`src/lib/components/AddConnectionModal.svelte`](../../open-webui/src/lib/components/AddConnectionModal.svelte)
