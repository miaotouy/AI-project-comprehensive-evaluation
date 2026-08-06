# Open WebUI Agent 角色配置调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读源码核对（models/models.py 数据模型、routers/models.py、utils/models.py 模型解析、main.py 参数合并、routers/openai.py 与 ollama.py 的角色生效、前端 ModelEditor/ModelSelector）；未修改目标仓库
>
> 调查范围：自定义模型（persona）数据模型、CRUD 与权限、模型解析与生效链路、system prompt 处理、默认模型与全局配置；排除多 agent 编排（子代理见 Agent 工具笔记）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.0 的「Agent 角色」载体是**自定义模型（Workspace Models）**：一个模型条目 = 上游基础模型 + system prompt + 推理参数 + 知识引用 + 工具/技能/过滤器绑定 + 访问授权。没有独立的 persona 实体。

- `Model` 表在 v0.11.0 已重构为 8 列：`id / user_id / base_model_id / name / params(JSON) / meta(JSON) / is_active / updated_at / created_at`（models/models.py 114-127 行）；旧版的 `system`、`files`、`modelfile`、`meta_categories` 独立字段已删除——system prompt 现在存于 `params.system`，知识库改为 `meta.knowledge` 引用列表，`access_control` 被独立的 `access_grants` 表取代；
- 自定义模型有两种形态（utils/models.py 157-242 行）：**Override（覆盖型）** `base_model_id = NULL`，沿用上游模型的同一个 id 只覆盖 name/info；**Preset（预设型）** `base_model_id = 上游id`，生成全新 id 且列表带 `preset: true`；
- 模型 id 语法：本版本**没有** `user/modelid` 前缀，也没有旧式 `"model-id:params"` 内联参数语法；id 是用户名的 slug 化（ModelEditor.svelte 69-76 行），限长 256（routers/models.py 91-92 行），参数一律存 DB、由服务端合并应用；
- 生效链路是**双层合并**：前端请求 body 带 `params` → `main.py` 三层合并「全局默认 < 模型params < 请求params」（1086-1097 行）→ `process_chat_payload` 捕获 `system`（middleware.py 2286-2289 行）→ 真正的注入在**路由层**：openai/ollama 端点各自按 `model_id` 重新读 DB，`apply_model_params_to_body_*` + `apply_system_prompt_to_body`（routers/openai.py 1210-1232 行、routers/ollama.py 1124-1141 行）——即「persona 的权威来源是 DB，而不是前端缓存」；
- 权限是核心安全机制：模型 `params`（含 system prompt）对**只读调用者直接剥空**（routers/models.py 197-200、540-547 行）；写操作要求 owner / write-grant / admin；`BYPASS_MODEL_ACCESS_CONTROL`、`BYPASS_ADMIN_ACCESS_CONTROL` 两个环境变量全局绕过；
- 工具/能力默认全部开启：`capabilities` 与 `builtinTools` 缺失时默认 True（utils/tools.py 533-540 行），前端 `DEFAULT_CAPABILITIES` 同名默认（constants.ts 100-113 行）；没有 per-model 的 "eval" 开关——Evaluation 是独立的竞技场功能；
- system prompt 支持变量模板：`resolve_system_prompt`（utils/payload.py 13-39 行）依次渲染 chat.variables → user.variables → metadata.variables → 旧式 `{{ }}` 模板；模型 system 在出站时**前置拼接**到已有 system message 之前（`add_or_update_system_message`，utils/misc.py 580-596 行），实现「模型人设 + 聊天级 system 并存」。

## 1. 数据模型

### 1.1 Pydantic 定义（models/models.py）

| 类 | 关键点 |
|---|---|
| `ModelParams`（61-65 行） | `extra='allow'`，任何推理参数都能存 |
| `ModelMeta`（67-75 行） | `profile_image_url / description / capabilities / knowledge`，`extra='allow'`；`knowledge` 写入前剥掉重复的 extracted text（26-55、93-96 行）；`tags` 归一化为 `{name}` 列表（98-111 行）；profile_image_url 校验防 SVG 注入（77-91 行） |
| `Model` ORM（114-127 行） | 上述 8 列 |
| `ModelModel`（130-147 行） | API 形状，含 `access_grants` 列表 |
| `ModelUserResponse` / `ModelAccessResponse`（150-155 行） | +user / +write_access |
| `ModelForm`（172-181 行） | 写模型：id / base_model_id / name / meta / params / access_grants / is_active，`extra='ignore'` |

### 1.2 存储层（ModelsTable，184-654 行）

- `insert_new_model`（208-231 行）：写表 + `AccessGrants.set_access_grants`；
- `get_base_models`（290-302 行）：`base_model_id IS NULL` 即「上游模型行」；
- `search_models`（336-444 行）：分页、模糊匹配 name/base_model_id/用户、SQL 级 access filter（367-373 行）、tag 按 JSON 文本模式匹配（SQLite/PostgreSQL 两种转义）、排序 name/created_at/updated_at；
- `sync_models`（593-651 行）：外部同步（差量 upsert + 删除）。

### 1.3 默认/内置模型

无内置预设表。管理员的全局默认来自 Config keys（config.py 1633-1697、3047-3052 行）：

- `models.default_metadata`（env `DEFAULT_MODEL_METADATA`）→ 合并进每个模型的 `info.meta`，capabilities 以「默认打底、模型覆盖」（utils/models.py 312-331 行）；
- `models.default_params`（env `DEFAULT_MODEL_PARAMS`）→ 作为每个模型 params 的基线（main.py 1087 行）；
- Arena 评估模型也是配置（`evaluation.arena.enable/models`，config.py 3077-3078 行）。

## 2. 路由与 API（routers/models.py）

| 端点 | 说明 |
|---|---|
| `GET /list`（131-206 行） | 30 条/页分页；`add_chat_variables_schema` 依据 `params.system` 生成前端表单 schema（52-57 行）；`write_access = admin(BYPASS) or owner or write-grant`，非写者 `params={}`（192-201 行） |
| `GET /base`、`/base/tags`、`GET /tags` | 基础模型列表与标签（214-241 行） |
| `POST /create`（249-307 行） | `workspace.models` 权限；id 唯一/长度校验；**knowledge 文件读权限校验**（95-118、279-283 行）；`filter_allowed_access_grants` 过滤越权 grant |
| `POST /import` / `/export` / `/sync`（315-502 行） | 导入逐条校验 knowledge 文件访问（402-413 行）与写权限（417-428 行） |
| `GET /model?id=`（514-561 行） | 非写者 `params={}`（540-547 行） |
| `GET /model/profile/image`（569-642 行） | 外链转发受 `ENABLE_PROFILE_IMAGE_URL_FORWARDING` 限制，data-URI 仅允许白名单 MIME |
| `POST /model/toggle` / `update` / `access/update` / `delete`（650-890 行） | 全部走 owner/write-grant/admin 校验；`access/update` 对无 DB 行的外部模型自动建最小条目（786-801 行） |

- 排序：`/api/models` 按 `ui.model_order_list` 排序、未列出的按 name（main.py 872-881 行）。

### 前端

- 聊天选择器：`src/lib/components/chat/ModelSelector.svelte`（items 直接来自 `$models` store，取 `model.id/name`，支持多选/固定/设为默认，47-86 行）；子组件 `ModelItemMenu.svelte` 跳编辑页（48-67 行）；
- 用户创建页：`src/lib/components/workspace/Models.svelte` + `Models/ModelEditor.svelte`。ID 由名字 slug 化（69-76 行）；提交时把 `system/toolIds/skillIds/filterIds/defaultFilterIds/actionIds/defaultFeatureIds/builtinTools/terminalId/knowledge/access_grants` 全部塞进 `meta`，`system` 塞 `params.system` 并清空空值（261-366 行）；
- 管理员页：`Settings/Models.svelte`（列表、启用/禁用、排序拖拽、Public/Shared/Private 徽章 107-123 行）；`Settings/Models/ModelDefaultsPanel.svelte` 通过 `getModelsConfig/setModelsConfig` 读写 `DEFAULT_MODEL_METADATA`/`DEFAULT_MODEL_PARAMS`（82-116 行）。

## 3. 模型解析与生效

### 3.1 列表解析（utils/models.py `get_all_models` 67-428 行）

```text
Ollama 基线查找：id.split(':')[0] 登记 + 精确 id 登记，精确优先（148-153 行）
  -> override：base_model_id is None -> 改写已存在模型的 name/info，is_active=False 则从列表移除（157-185 行）
  -> preset：base_model_id 非空 -> 生成新条目 preset: true，继承 owned_by/pipe/provider/loaded（187-242 行）
  -> info 中 params 一律删除（221-223 行）——列表 API 不暴露 system prompt 等敏感配置
  -> 全局默认 meta 合并（312-331 行）
  -> action/filter 解析并附到每个模型（244-414 行）
  -> 缓存进 request.app.state.MODELS
```

### 3.2 访问控制

- `check_model_access`（utils/models.py 431-472 行）：arena 读 `meta.access_grants`；普通模型查 `AccessGrants.has_access(read)` + `has_base_model_access` 沿 `base_model_id` 链逐跳校验（utils/access_control/__init__.py 301-339 行，中间无 DB 行的基模型只放行 admin）；
- `get_filtered_models`（475-529 行）：用户或 admin（未开 BYPASS）且未开 `BYPASS_MODEL_ACCESS_CONTROL` 时，只返回 owner/可读/admin 的模型；
- grant 模型：`AccessGrants` 表 `principal_type ∈ user/group/anyone`，`principal_id='*'` 为公开；空列表=私有；旧 `access_control` dict 有自动迁移（access_control/__init__.py 179-217 行）。

## 4. 角色在聊天请求中的生效链路

### 4.1 前端（Chat.svelte 3124-3192 行）

- `model.info.params.stream_response` 决定流式（3032-3036 行）；`params.system || $settings.system` 作为 `messages[0]` 发送（3039-3043 行）；
- 选中模型时从 `model.info.meta` 读 `toolIds / skillIds / defaultFilterIds / defaultFeatureIds / terminalId`（762-844 行）；`features`（web_search/image_generation/code_interpreter/memory）按 `capabilities` 与用户权限生成（816-841 行）。

### 4.2 后端合并（main.py 1052 行起）

```text
Models.get_model_by_id(model_id)（1074）
  -> check_model_access（1077-1081）
  -> params 三层合并 {**default_model_params, **model_info.params, **request_params}（1086-1097）
  -> 自定义模型基模型缺失时按 ENABLE_CUSTOM_MODEL_FALLBACK 回退（1099-1115）
  -> metadata 保留 function_calling 等（1199-1208）
```

### 4.3 路由层注入（权威来源）

- `routers/openai.py generate_chat_completion`（1182 行起）：`base_model_id` 改写 `payload['model']`（1214-1219 行）→ `system = params.pop('system')`（1224 行）→ `apply_model_params_to_body_openai`（1226 行）→ 非 `bypass_system_prompt` 时 `apply_system_prompt_to_body`（1227-1228 行）→ `check_model_access`（1230 行）；
- `routers/ollama.py generate_chat_completion`（1086-1160 行）：同样逻辑 + `apply_model_params_to_body_ollama`（1132-1137 行）；
- `utils/payload.py`：`resolve_system_prompt`（13-39 行）渲染变量；`apply_model_params_to_body_openai/ollama`（108-219 行）含参数类型强转、`max_tokens→num_predict`、`custom_params` JSON 解析、Ollama 根级 `format/keep_alive/think` 提升（205-215 行）；`remove_open_webui_params` 剔除 `stream_response/function_calling/reasoning_tags/system` 等内部字段（81-104 行）。

### 4.4 middleware 中的角色处理（process_chat_payload 2248-2987 行）

- arena 子模型随机解析（2260-2284 行）；
- 捕获 `model_system_prompt` 后再 pop params（2286-2289 行）；
- 文件夹级 system_prompt 注入（2449-2450 行）；
- legacy 模式下模型 `meta.knowledge` 展开成 `files` 做 RAG（2462-2502 行）；native FC 模式下知识走内置工具 `query_knowledge_files` 等（utils/tools.py 602-638 行，`get_attached_knowledge` 汇总 model/chat/note 知识 460-517 行）；
- 技能 `<skill>` 注入 / `<available_skills>` 清单（2607-2685 行）；
- 内置工具按能力注入（2888-2900 行）；
- 模型 system 解析后**前置拼接**到已有 system message 内容，存入 `metadata['system_prompt']`（2937-2948 行），供子代理/定时器/工具循环还原用（main.py 1692、utils/subagents.py 321、utils/timers.py 111 行）。

## 5. System prompt 处理

- `utils/misc.py`：`get_system_message`（514-518 行）、`replace_system_message_content`（572-577 行）、`add_or_update_system_message`（580-596 行，`append=False` 时前置）、`update_message_content`（556-569 行）、`merge_system_messages`（529-553 行，多个 system 合并到位置 0，兼容 Qwen 等模板）；
- `utils/task.py`：`prompt_template`（旧式 API `{{ ... }}`）、`prompt_variables_template`（WebUI 元数据变量）——由 `resolve_system_prompt` 串联；
- Chat Controls（用户侧 system）走 `apply_system_prompt_to_body(..., replace=True)` 渲染变量后替换（middleware.py 2387-2394 行）；
- Ollama 侧：system 若落在 options 里会被提升为根级 `system` 字段（payload.py 361-366 行）。

## 6. 与其他项目的对比点

| 维度 | Open WebUI v0.11（自定义 Model） | LobeHub Agent | OpenAI Custom GPT |
|---|---|---|---|
| persona 载体 | 模型本身：同一 id 同时是「上游模型 + 人设 + 参数包」（override 或 preset） | Agent 实体，内选任意模型 | GPT 实体，与基础模型解耦 |
| System prompt | `params.system`（DB 存储），支持 chat/user 变量模板 | `systemRole` | `instructions` |
| 推理参数 | 任意参数（`extra='allow'`）+ `custom_params`，随模型持久化，每请求三层合并 | 仅常用项 | 不可配置 |
| 工具绑定 | `meta.toolIds`（默认选中）、`skillIds`、`filterIds`、`builtinTools` 分类开关、MCP/函数 | plugins/tools 列表 | Web Browsing / DALL·E / Code Interpreter 三开关 |
| 知识 | `meta.knowledge` 引用集合/文件 | files/knowledge base | knowledge 文件 |
| 权限 | access_grants（user/group/anyone），只读者 params 剥空 | workspace 隔离 | 拥有者管理 |

- 与 LobeHub 相比，Open WebUI 把 persona 直接折叠进模型 id，路由/目录/权限全部复用模型体系，没有独立的 agent 生命周期；
- `params` 对只读调用者剥空是值得记录的设计：列表 API 只暴露控件级参数，system prompt 只在请求路径上经 DB 读取注入，避免前端缓存持有敏感人设。

## 7. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| 自定义模型（persona） | 有 | override / preset 两形态 |
| System prompt | 有 | `params.system` + 变量模板 + 前置拼接 |
| 推理参数持久化 | 有 | params JSON + 三层合并 |
| 知识绑定 | 有 | `meta.knowledge` 引用集合/文件 |
| 工具/技能/过滤器绑定 | 有 | meta 内 toolIds/skillIds/filterIds 等 |
| 能力开关 | 有 | capabilities/builtinTools，缺失默认开 |
| 访问控制 | 有 | access_grants + base_model 链校验 |
| 全局默认参数 | 有 | `DEFAULT_MODEL_METADATA` / `DEFAULT_MODEL_PARAMS` |
| 模型克隆 | 有 | base_model_id 复制 |
| 导入/导出 | 有 | 逐条校验 knowledge 与写权限 |
| 自定义头像 | 有 | 外链转发限制 + data-URI 白名单 |

## 8. 关键源码索引

- 数据模型：[`models/models.py`](../../open-webui/backend/open_webui/models/models.py)（61-181 行）
- 存储层：[`models/models.py`](../../open-webui/backend/open_webui/models/models.py)（184-654 行）
- CRUD 路由：[`routers/models.py`](../../open-webui/backend/open_webui/routers/models.py)
- 模型解析：[`utils/models.py`](../../open-webui/backend/open_webui/utils/models.py)（67-428、431-529 行）
- 参数合并：[`main.py`](../../open-webui/backend/open_webui/main.py)（1052-1115 行）
- 路由层注入：[`routers/openai.py`](../../open-webui/backend/open_webui/routers/openai.py)（1182-1232 行）、[`routers/ollama.py`](../../open-webui/backend/open_webui/routers/ollama.py)（1086-1141 行）
- 参数/system 处理：[`utils/payload.py`](../../open-webui/backend/open_webui/utils/payload.py)（13-219 行）、[`utils/misc.py`](../../open-webui/backend/open_webui/utils/misc.py)（514-596 行）
- 访问控制：[`utils/access_control/__init__.py`](../../open-webui/backend/open_webui/utils/access_control/__init__.py)（179-339 行）
- 前端编辑器：[`src/lib/components/workspace/Models/ModelEditor.svelte`](../../open-webui/src/lib/components/workspace/Models/ModelEditor.svelte)
- 前端选择器：[`src/lib/components/chat/ModelSelector.svelte`](../../open-webui/src/lib/components/chat/ModelSelector.svelte)
- 管理员模型页：[`src/lib/components/admin/Settings/Models.svelte`](../../open-webui/src/lib/components/admin/Settings/Models.svelte)
