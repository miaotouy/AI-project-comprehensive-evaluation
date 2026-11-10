# Open WebUI Agent 角色配置调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：只读源码核对（models/models.py 数据模型、routers/models.py、utils/models.py 模型解析、main.py 参数合并、routers/openai.py 与 ollama.py 的角色生效、前端 ModelEditor/ModelSelector）；未修改目标仓库
>
> 调查范围：自定义模型（persona）数据模型、CRUD 与权限、模型解析与生效链路、system prompt 处理、默认模型与全局配置；排除多 agent 编排（子代理见 Agent 工具笔记）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.3 的「Agent 角色」载体是**自定义模型（Workspace Models）**：一个模型条目 = 上游基础模型 + system prompt + 推理参数 + 知识引用 + 工具/技能/过滤器绑定 + 访问授权。没有独立的 persona 实体。

- `Model` 表在 v0.11.3 已收敛为 8 列（`models/models.py:114-127`，列名见 1.1）：旧版四个独立字段（system、files、modelfile、meta_categories）全部删除，system prompt、知识引用与访问控制分别改由 params.system、meta.knowledge 与独立的 access_grants 表承担；
- 列表解析把自定义模型分成两种形态（`utils/models.py:157-242`）：**Override（覆盖型）** 不设 `base_model_id`，沿用上游模型的同一个 id，只覆盖名称与描述；**Preset（预设型）** 用 `base_model_id` 指向上游模型，生成全新 id，列表条目上带 `preset: true`；
- 模型 id 由用户名 slug 化生成（`ModelEditor.svelte:69-76`），限长 256（`routers/models.py:91-92`）；本版本没有 `user/modelid` 这样的前缀，旧式 `"model-id:params"` 内联参数语法也已取消，参数一律存 DB、由服务端合并后应用；
- 生效链路分请求与注入两层：
  - 请求侧：前端请求带上参数，main.py 按「全局默认 < 模型 params < 请求 params」做三层合并（`main.py:1086-1097`），随后 `process_chat_payload` 从中捕获 system 字段（`middleware.py:2286-2289`）；
  - 注入侧：真正的注入发生在路由层，openai 与 ollama 两个端点各自按 `model_id` 重读 DB，再应用参数与 system prompt（`routers/openai.py:1210-1232`、`routers/ollama.py:1124-1141`），每轮请求的 persona 都以 DB 记录为准；
- 权限是核心安全机制：只读调用者拿到的模型 `params`（含 system prompt）会被直接剥空（`routers/models.py:197-200、540-547`），写操作要求 owner、write-grant 或 admin 之一，`BYPASS_MODEL_ACCESS_CONTROL` 与 `BYPASS_ADMIN_ACCESS_CONTROL` 两个环境变量可整体绕过这层判断；
- 工具与能力默认开启：`capabilities` 与 `builtinTools` 缺失时按 True 处理（`utils/tools.py:533-540`），前端 `DEFAULT_CAPABILITIES` 使用同一组缺省值（`constants.ts:100-113`）；每个模型没有单独的 "eval" 开关，Evaluation 属于独立的竞技场功能；
- system prompt 支持变量模板：`resolve_system_prompt` 先渲染聊天变量、用户变量与元数据变量，最后套用旧式 `{{ }}` 模板（`utils/payload.py:13-39`）；模型 system 在出站时前置拼接到已有 system message 之前（`utils/misc.py:580-596`），聊天级 system 与模型人设因此可以并存。

## 1. 数据模型

### 1.1 Pydantic 定义（models/models.py）

| 类 | 关键点 |
|---|---|
| `ModelParams`（61-65 行） | `extra='allow'`，任何推理参数都能存 |
| `ModelMeta`（67-75 行） | `profile_image_url / description / capabilities / knowledge`，`extra='allow'`；字段处理细节见表格下方 |
| `Model` ORM（114-127 行） | `id` / `user_id` / `base_model_id` / `name` / `params`(JSON) / `meta`(JSON) / `is_active` / `updated_at` / `created_at` |
| `ModelModel`（130-147 行） | API 形状，含 `access_grants` 列表 |
| `ModelUserResponse` / `ModelAccessResponse`（150-155 行） | +user / +write_access |
| `ModelForm`（172-181 行） | 写模型：id / base_model_id / name / meta / params / access_grants / is_active，`extra='ignore'` |

`ModelMeta` 的字段处理：
- `knowledge` 写入前剥掉重复的 extracted text（26-55、93-96 行）；
- `tags` 归一化为 `{name}` 列表（98-111 行）；
- `profile_image_url` 校验防 SVG 注入（77-91 行）。

### 1.2 存储层（ModelsTable，184-654 行）

- 新增模型时，`insert_new_model` 先写模型表，再调用授权模块为它建立访问记录（`models/models.py:208-231`）；
- 上游模型行的判定条件是 `base_model_id` 为空，`get_base_models` 据此列出基础模型（`models/models.py:290-302`）；
- 搜索由 `search_models` 承担：分页、按名称/基础模型/用户模糊匹配、按名称或时间排序，访问过滤下沉到 SQL，tag 过滤按 JSON 文本模式匹配并为 SQLite 与 PostgreSQL 各写一套转义（`models/models.py:336-444`）；
- `sync_models` 负责与外部来源同步，按差量执行 upsert 与删除（`models/models.py:593-651`）。

### 1.3 默认/内置模型

无内置预设表。管理员的全局默认来自 Config keys（config.py 1633-1697、3047-3052 行）：

- 全局默认元数据来自配置项 `models.default_metadata`（环境变量 `DEFAULT_MODEL_METADATA`），列表解析时合并进每个模型的 `info.meta`，capabilities 按「默认打底、模型覆盖」处理（`utils/models.py:312-331`）；
- 默认推理参数来自 `models.default_params`（环境变量 `DEFAULT_MODEL_PARAMS`），作为每个模型参数合并的基线（`main.py:1087`）；
- Arena 评估所用的模型同为配置项，键分别是 `evaluation.arena.enable` 与 `evaluation.arena.models`（`config.py:3077-3078`）。

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

- 聊天选择器的选项直接取自 `$models` store，每个条目只取 id 与名称，支持多选、固定和设为默认（`src/lib/components/chat/ModelSelector.svelte:47-86`）；同级菜单组件负责从条目跳转到编辑页（`ModelItemMenu.svelte:48-67`）；
- 用户创建页分两层：`src/lib/components/workspace/Models.svelte` 负责列表，`src/lib/components/workspace/Models/ModelEditor.svelte` 负责编辑表单。id 随名称输入做 slug 化，提交时按类别把各类绑定写进 `meta`，system prompt 单独写入 `params.system` 并清掉空值（`ModelEditor.svelte:69-76、261-366`）：

| 绑定类别 | 写入 `meta` 的字段 |
|---|---|
| 工具 | `toolIds`、`builtinTools` |
| 技能与过滤器 | `skillIds`、`filterIds`、`defaultFilterIds` |
| 动作与默认功能 | `actionIds`、`defaultFeatureIds` |
| 其他 | `terminalId`、`knowledge`、`access_grants` |

  - 管理员页 `src/lib/components/admin/Settings/Models.svelte` 提供模型列表、启用/禁用、拖拽排序和 Public/Shared/Private 徽章；加载列表时另通过 `getModels(token, null, true)` 并入 provider 模型目录，以覆盖被隐藏或停用的上游条目（`:269-280`）；
  - 同一目录下的默认值面板 ModelDefaultsPanel.svelte 通过配置读写接口维护 `DEFAULT_MODEL_METADATA` 与 `DEFAULT_MODEL_PARAMS` 两组全局默认（`:82-116`）。

## 3. 模型解析与生效

### 3.1 列表解析（utils/models.py `get_all_models` 67-428 行）

```text
Ollama 基线查找：id.split(':')[0] 登记 + 精确 id 登记，精确优先（148-153 行）
  -> override：base_model_id is None -> 改写已存在模型的 name/info，is_active=False 则从列表移除（157-185 行）
  -> preset：base_model_id 非空 -> 生成新条目 preset: true，继承 owned_by/pipe/provider/loaded（187-242 行）
  -> info 中 params 一律删除（221-223 行）——列表 API 不暴露 system prompt 等敏感配置
  -> 全局默认 meta 合并（312-331 行）
  -> action/filter 解析并附到每个模型（filter_ids 先排序，保证内容签名跨进程稳定）
  -> 缓存进 request.app.state.MODELS
```

- 基础模型目录另有一层跨进程缓存：开启 `models.base_models_cache` 时先读 Redis 键 `{prefix}:models:base`，命中就直接作为 BASE_MODELS，未命中才回源并写回；refresh 会同时清本地与 Redis 缓存（`backend/open_webui/utils/models.py:32,69-105`）。OpenAI/Ollama 连接配置更新时共用同一套清缓存逻辑（`routers/openai.py:347-356`、`routers/ollama.py:321-327`）；

### 3.2 访问控制

- `check_model_access` 决定某个用户能否使用某个模型（`utils/models.py:431-472`）：arena 虚拟模型直接读 `meta.access_grants`；普通模型先检查模型自身的可读性，再沿 `base_model_id` 链逐跳校验每一层基模型，链上中间那层若没有 DB 记录则只对 admin 放行（`utils/access_control/__init__.py:301-339`）；
- 列表返回前还会再过滤一轮：当请求者是普通用户，或管理员没有开启全局 BYPASS，且 `BYPASS_MODEL_ACCESS_CONTROL` 也未开启时，结果只保留自己拥有的、可读的或自己有管理权限的模型（`utils/models.py:475-529`）；
- grant 模型：`AccessGrants` 表 `principal_type ∈ user/group/anyone`，`principal_id='*'` 为公开；空列表=私有；旧 `access_control` dict 有自动迁移（access_control/__init__.py 179-217 行）。

## 4. 角色在聊天请求中的生效链路

### 4.1 前端（Chat.svelte 3124-3192 行）

- 发请求前，前端先看模型参数里的流式开关决定是否按流式返回（`Chat.svelte:3032-3036`）；首条 system message 取模型的 `params.system`，模型未配置时回落到用户全局设置（`Chat.svelte:3039-3043`）；
- 选中模型时，聊天页从 `model.info.meta` 读取工具、技能、默认过滤器、默认功能与终端绑定，并按模型能力与用户权限生成功能开关，覆盖联网搜索、图像生成、代码解释器与记忆四项（`Chat.svelte:762-844`）。

### 4.2 后端合并（main.py 1052 行起）

```text
Models.get_model_by_id(model_id)（1074）
  -> check_model_access（1077-1081）
  -> params 三层合并 {**default_model_params, **model_info.params, **request_params}（1086-1097）
  -> 自定义模型基模型缺失时按 ENABLE_CUSTOM_MODEL_FALLBACK 回退（1099-1115）
  -> metadata 保留 function_calling 等（1199-1208）
```

### 4.3 路由层注入（权威来源）

- openai 端点的 `generate_chat_completion` 在一次请求里依次完成五件事（`routers/openai.py:1182-1230`）：
  1. 按 `base_model_id` 改写请求体里的模型名；
  2. 取出 `system` 并从参数中弹出；
  3. 用 `apply_model_params_to_body_openai` 把模型参数写进请求体；
  4. 未设置 `bypass_system_prompt` 时，用 `apply_system_prompt_to_body` 注入 system prompt；
  5. 做一次 `check_model_access` 校验。
- ollama 端点走同样的顺序（`routers/ollama.py:1086-1160`），参数应用换成 `apply_model_params_to_body_ollama`；
- 参数与 system 的实际处理都在 `utils/payload.py`，按职责分成三块：
  - `resolve_system_prompt` 按聊天、用户、元数据三层渲染变量模板（`utils/payload.py:13-39`）；
  - 参数应用函数把模型参数写进上游请求体：做类型强转，把 max_tokens 改名为 num_predict，解析 custom_params 里的 JSON，并把 Ollama 侧的 format、keep_alive、think 三项提升到请求体根级（`utils/payload.py:108-215`）；
  - 写请求体前还会先剔掉 stream_response、function_calling、reasoning_tags、system 等 WebUI 内部字段（`utils/payload.py:81-104`）。

### 4.4 middleware 中的角色处理（process_chat_payload 2248-2987 行）

- arena 场景先用随机子模型替换请求模型（`middleware.py:2260-2284`）；
- 把模型自带的 system prompt 捕获到 `model_system_prompt` 后从参数里弹出，避免后续重复注入（`middleware.py:2286-2289`）；
- 若当前对话挂在某个文件夹下，再叠加文件夹级 system prompt（`middleware.py:2449-2450`）；
- 知识注入按模式分流：legacy 模式把模型的知识引用展开成文件列表走 RAG，native FC 模式改调内置的知识检索工具，模型、聊天、笔记三处挂载的知识先汇总再注入（`middleware.py:2462-2502`，工具实现见 `utils/tools.py`）；
- 技能以 `<skill>` 片段与 `<available_skills>` 清单的形式注入（`middleware.py:2607-2685`）；
- 内置工具按模型启用的能力逐项注入（`middleware.py:2888-2900`）；
- 模型 system 解析后前置拼接到已有 system message 之前，结果存入 `metadata['system_prompt']`，供子代理、定时器和工具循环还原人设时取用（`middleware.py:2937-2948`，下游取用见 `main.py`、`utils/subagents.py`、`utils/timers.py`）。

## 5. System prompt 处理

- `utils/misc.py` 的一组工具函数负责系统消息的取值、替换、更新与合并，五个函数都位于 `utils/misc.py:514-596`：

| 函数 | 行为 |
|---|---|
| `get_system_message` | 取当前系统消息 |
| `replace_system_message_content` | 替换系统消息内容 |
| `update_message_content` | 更新消息内容 |
| `merge_system_messages` | 多条 system message 合并到位置 0，兼容 Qwen 等模板 |
| `add_or_update_system_message` | `append=False` 时前置写入 |

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
- `params` 对只读调用者剥空：列表 API 只暴露控件级参数，system prompt 只在请求路径上经 DB 读取注入，前端缓存因此不持有敏感人设。

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

## 8. 会话级快照与重新生成

会话与消息两层的持久化结构：

- chat 表用一个 chat JSON 列保存整段会话（id、title、models、history、params、files 六组），模型 id 藏在 `chatContent.models` 里，没有独立列；同表另有元数据、变量、任务、摘要和当前消息指针等列，表结构见 `models/chats.py:70-102`。前端加载会话时据此恢复（`Chat.svelte:1992-2026`），保存时由后端合并写入（`routers/chats.py:1358-1366`）；
- chat_message 表的 assistant 消息带 `model_id` 列，正文、输出、附件、来源、嵌入与用量等内容都放在 JSON 列里，没有 params 快照列，`meta` 只记录定时器、委派、状态这类内部标记（`models/chat_messages.py:128-172`）。

- **chat 级 params 是用户侧的覆盖层**：Chat Controls 把用户设置、聊天参数与 stop 合并进请求体（`Chat.svelte:3130-3134`），这份 `chat.params` 随会话 JSON 一起保存，也随每次请求发送，与模型自带的参数并存。会话表不存模型 system prompt 的快照，每轮注入仍按 `model_id` 从 DB 取（`routers/openai.py:1210-1232`）。
- **重新生成由前端完成**：后端没有 regenerate 接口，只有 `regenerate_response` 这一个权限开关（`config.py:1967`）。前端复用父级 user 消息的 id 再调一次发送流程（`Chat.svelte:3380`），结果是一条新 uuid 的 assistant 消息追加进 `parent.childrenIds`（`Chat.svelte:2809-2844`），形成新的兄弟分支，原消息保留；
- 多模型对话的回复靠 `message.model` 与 `modelIdx` 两个字段恢复（`Chat.svelte:3402-3408`）。
- **开场白与提示词分组**：Workspace Model 没有 greeting 或 opening 字段，后端 Python 代码全量搜索也没有模型侧命中；空聊天页的 Suggestions 与 Placeholder 属于静态引导 UI。`params.system` 是单个 textarea（`ModelEditor.svelte:78、427`），没有多段或逐段启停；模型可以整体导入导出（`routers/models.py:315-502`），没有段级导入导出。

## 9. 关键源码索引

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
