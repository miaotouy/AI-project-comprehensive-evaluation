# Open WebUI Agent 工具调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：只读源码核对（utils/middleware.py 工具主循环、tools/builtin.py 内置工具、utils/tools.py、routers/tools.py、utils/filter.py、functions.py、utils/mcp、utils/subagents、代码解释器）；未修改目标仓库
>
> 调查范围：工具生态与注册、内置工具条件注入、工具调用执行循环、Filter/Pipeline、MCP、子代理、代码解释器、Valves 与插件加载、前端工具 UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.3 的工具调用主循环位于 `utils/middleware.py`，不在路由或 utils/chat.py：主入口 `process_chat_payload`（2055 行）负责编排，先连接外部工具服务器（`connect_mcp_server` 在 `utils/tools.py:201`，由中间件 2696 行调用），再执行单个工具（`execute_tool_call`，3092 行）、后处理结果（`process_tool_result`，729 行），随后重新请求模型进入下一轮。各步骤详细链路见第 3 节代码块。

- 工具分三大来源，统一注册成 `tools_dict`（middleware.py 2684-2775 行）：本地数据库工具（`get_tools`，utils/tools.py 365 行）、内置工具（`get_builtin_tools`，626 行）、外部 MCP/OpenAPI 工具服务器（`server:*` 前缀）；每条条目含 `{tool_id, callable, spec, type}`，类型为 builtin/external/mcp，另有 `direct` 标志（前端直连执行）；
- **内置工具按条件注入，不整批暴露**：共 64 个内置工具函数（tools/builtin.py，文件头明确警告只能经 utils/tools.py 封装使用），按 18 个类别做四重开关检查——模型 meta 的 `builtinTools` 类别开关、全局配置（`Config.get`）、模型能力（`get_model_capability`）、用户权限；
- 请求体显式携带 `tools` 键（含 `tools: []`）时以该键为工具来源、跳过服务端数据库工具解析（middleware.py 2096、2507、2901 行）；`use_builtin_tools` 判定见 2110 行；
- 工具参数校验是**白名单过滤**：`execute_tool_call` 从 `metadata['tools']` 按函数名取工具，用 spec 的 `parameters.properties` 键集过滤模型传入参数，解析失败返回错误文案；
- 多轮工具调用循环上限 `max_tool_call_iterations`（默认 `CHAT_RESPONSE_MAX_TOOL_CALL_ITERATIONS`）；每轮把 tool call 以 `function_call` 项加入输出、执行后加 `function_call_output` 项、再拼回消息重发；工具结果中的 base64 图片拆成 `input_image` 供 LLM 消费，前端展示则剥离，图片另附一条 user 消息；
- 仅四类知识/文件工具的结果经 `get_citation_source_from_tool_result` 转成引用来源（`view_knowledge_file`、`view_file`、`query_knowledge_files`、`query_chat_files`，middleware.py 457-600 行），再经 `event_emitter({'type': 'source'})` 发前端，并按 RAG 模板重写上下文注入（先恢复 pre-RAG 消息防重复）；网页检索结果的来源事件另由搜索链路发布，不走该函数；
- 代码解释器双引擎：`code_interpreter.engine` 为 `pyodide` 时通过 `event_caller({'type': 'execute:python'})` 推送前端浏览器执行；为 `jupyter` 时调用 `execute_code_jupyter`（utils/code_interpreter.py，WebSocket 连 Jupyter kernel）；`CODE_INTERPRETER_BLOCKED_MODULES` 会注入受限 `__import__` 包装代码；
- MCP 工具通过 `client.call_tool` 直接调用，工具名统一为 `{server_id}_{tool_spec["name"]}`；连接前做 `has_connection_access` 访问授权校验；
- 子代理（Sub-agents）是内部 API 重入：`delegate_task`（builtin.py 1774 行）→ `utils/subagents.py: delegate`（296 行）创建独立 chat（`internal_meta` type=subagent）→ `_build_request` 伪造带 `typ: 'subagent'` token 的内部请求 → 递归调用 `CHAT_COMPLETION_HANDLER`。后台模式用信号量限流（上限 `subagents.max_concurrent`/`max_async`）；子代理内部禁用写类 memory 工具（`MUTATING_MEMORY_TOOLS`）。
- Filter/Pipeline 是两条并行通道：本地函数插件经 `utils/filter.py` 的 `process_filter_functions` 按 inlet/stream/outlet 与 request 四类 handler 执行；远程 pipeline 服务器经 HTTP POST 到 `{url}/{filter_id}/filter/inlet|outlet`；能力注入顺序：Pipeline Inlet → Filter Inlet → Chat Memory → Web Search → Image Gen → Code Interpreter → Tools Function Calling → Files；消息定稿前还会跑一次 Filter `request`，工具审批恢复与每轮工具调用之后也会重跑该阶段；
- Valves 配置全部经 Fernet 加密存储（utils/valves.py），`WEBUI_SECRET_KEY` 派生密钥，`ENABLE_VALVE_ENCRYPTION` 开关；
- 工具审批可在请求参数中选择“完整访问”或“逐次询问”。后者由服务端把首个待执行调用持久化为 pending、其余调用标为 queued；恢复请求会拒绝已结算的调用，并沿原会话参数继续执行。`ask_user` 不进入这条审批暂停链：它必须是本轮唯一工具调用、且每轮只能有一个，混入其他工具或重复调用都判为非法——非法调用会被剔出本轮工具列表、各自留一条错误结果，然后该轮继续执行剩余调用（`utils/ask_user.py:9-27,90-160`、`utils/middleware.py:5707-5730`；审批链见 `utils/tool_approval.py`）。
- 前端工具 UI 在 `MessageInput/IntegrationsMenu.svelte`（集成菜单的 Tools tab），非独立 Tools.svelte；工作区管理页 `workspace/Tools.svelte` 负责上传/编辑/Valves。

## 1. 内置工具生态

[`tools/builtin.py`](../../open-webui/backend/open_webui/tools/builtin.py)（5043 行）定义 64 个内置工具，按类别与注入条件（utils/tools.py 719-923 行）：

| 类别 | 工具（builtin.py 行号） | 注入条件 |
|---|---|---|
| 时间 | `get_current_timestamp`(160)、`calculate_timestamp`(196) | time(:719-720) |
| 人工提问 | `ask_user`(535) | user_input(:722-723，默认开启) |
| 网页 | `search_web`(291，结果数受 `web.search.result_count` 限制)、`fetch_url`(330，`web.fetch.max_content_length` 截断) | web_search(:823-830) |
| 图像 | `generate_image`(365)、`edit_image`(447) | image_generation(:834-848) |
| 代码 | `execute_code`(650) | code_interpreter(:853-859) |
| 记忆 | `list_memory_paths`(815)、`read_memory_path`(846)、`search_memories`(880)、`add_memory`(938)、`update_memory`(978)、`replace_memory_content`(1019)、`delete_memory`(1068)、`list_memories`(1100) | memory(:802-820)；内部会话剔除写类工具 |
| 笔记 | `search_notes`(1140)、`view_note`(1241)、`write_note`(1313)、`replace_note_content`(1365) | notes(:863-867) |
| 聊天历史 | `search_chats`(1626)、`view_chat`(1706) | chats(:788-790) |
| 子代理 | `delegate_task`(1774，`background` 参数在 `subagents.background_enabled` 关闭时被剥离)、`timer`(1818) | subagents(:792-799) |
| 频道 | `search_channels`(1858)、`search_channel_messages`(1910)、`view_channel_message`(1991)、`view_channel_thread`(2052) | channels(:868-879) |
| 知识库 | `list_knowledge_bases`(2139)、`search_knowledge_bases`(2197)、`search_knowledge_files`(2257)、`grep_knowledge_files`(2722)、`view_knowledge_file`(2957)、`list_knowledge`(3165)、`query_knowledge_files`(3307)、`query_knowledge_bases`(3541)、`display_file`(3104) | knowledge(:748-786，分 `ENABLE_KB_EXEC` / 有挂载知识 / 无知识三种形态) |
| 聊天文件 | `list_chat_files`(2506)、`grep_chat_files`(2546)、`query_chat_files`(2602)、`view_file`(2843)、`display_file`(3104) | files(:736-746，需模型关 file_context 且有聊天文件) |
| 技能 | `view_skill`(3651)、`read_skill_file`(3711)、`grep_skill_files`(3789)、`update_skill_files`(3965)、`create_skill`(3911) | skills(:881-890，按是否绑定技能与 workspace.skills 权限分别注入) |
| 工具创建 | `create_tool`(3870) | tools(:891-897，需 `ENABLE_TOOLS` 与 workspace.tools 权限) |
| 任务 | `create_tasks`(4095)、`update_task`(4145) | tasks(:899-902，需已保存 chat) |
| 自动化 | `create_automation`(4209)、`update_automation`(4317)、`list_automations`(4421)、`toggle_automation`(4493)、`delete_automation`(4544) | automations(:904-911) |
| 日历 | `search_calendar_events`(4649)、`create_calendar_event`(4738)、`update_calendar_event`(4865)、`delete_calendar_event`(4986) | calendar(:913-917) |
| 通知 | `notify`(130) | notifications(:919-923，需 `ui.enable_user_webhooks` 与 webhooks 权限) |

另有一个特殊工具 `kb_exec`（[`tools/knowledge_fs.py`](../../open-webui/backend/open_webui/tools/knowledge_fs.py) 1171-1234 行）：把知识库当“文件系统”的类 shell 命令工具，支持 `ls/tree/cat/head/tail/sed/grep/find/wc/stat` 及管道。匹配预算由 `match_budget`（43 行）限制，输出超过 `KB_EXEC_MAX_OUTPUT_CHARS` 会被截断；是否注入它由 `ENABLE_KB_EXEC` 决定（关闭时改用传统组合工具）。

工具过多时，服务端不做全量暴露：一部分工具被标记为延迟加载，只把精简清单写进系统提示，模型用 `search_tools`(4025) 按需检索后再解析回真实工具调用（`utils/tool_search.py:41-160`）。这层与“按类别注入”正交——先决定候选集，再决定候选集中哪些立刻可见。

## 2. 工具注册与加载

### 2.1 数据库工具（utils/tools.py `get_tools` 365-624 行）

- 数据库工具按以下顺序加载（utils/tools.py `get_tools`）：批量读取 `Tools.get_tools_by_ids` → `AccessGrants.has_access` 授权校验 → `load_tool_module_by_id` 模块缓存 → Valves 注入 → spec 清洗（`str` 转 `string` 类型修正、剥离 `__` 前缀保留参数）→ `get_async_tool_function_and_apply_extra_params` 绑定 `__id__`/`__user__` → 函数名冲突时加 `{tool_id}_` 前缀；
- `server:` 前缀走 OpenAPI 工具服务器分支：`function_name_filter_list` 过滤、`execute_tool_server`（1797 行）发起 HTTP 调用；
- `Tool` 表（models/tools.py 26 行起）：id / user_id / name / content / specs / meta / valves / 时间戳；写入时同步 `AccessGrants.set_access_grants`。

### 2.2 内置工具 spec

- spec 生成用 `get_builtin_function_introspection` / `build_builtin_tool_spec_json`（utils/tools.py 1122、1131 行）：函数 → pydantic 模型 → OpenAI function spec，带缓存；
- `clean_openai_tool_schema`（1111 行）清洗输出；`get_tool_specs`（1154 行）负责用户自定义工具 spec。
- 工具与函数的多版本历史单独落表（`models/tool_history.py`、`models/function_history.py`），控制台提供 `GET /api/v1/tools/id/{id}/history` 系列端点与对比接口（routers/tools.py 1153-1193 行）。

## 3. 工具调用执行循环（utils/middleware.py）

```text
process_chat_payload (2055)
  -> payload_tools 为 None 时服务端解析 tool_ids
       server:mcp: 前缀 -> 逐服务器 connect_mcp_server + 注册（type='mcp'）
       其余 -> get_tools
  -> 请求发给上游，模型返回 tool_calls
  -> while tool_calls and iterations < max_tool_call_iterations (5667)
       parse_tool_params（JSON 解析失败回退 ast.literal_eval）
       execute_tool_call (3092)
         direct 工具 -> event_caller({'type': 'execute:tool'}) 推前端执行
         普通工具 -> get_updated_tool_function 绑定 __messages__/__files__ 后 await
       delegate_task 特殊并发收集
       process_tool_result (729) + 终端事件转发 + 引用提取 (457)
       function_call -> completed + function_call_output 回填
       引用 -> RAG 模板上下文重建
       convert_output_to_messages 拼回消息
       generate_chat_completion 再请求
  -> 迭代上限报错
```

- 工具结果中的 base64 图片拆成 `input_image` 供 LLM 消费、前端展示则剥离，图片另附一条 user 消息；
- `process_tool_result`（729 行）支持 `(HTMLResponse, result_context)` 元组：HTML 部分经 `tool_result_embeds` 直达前端 iframe 渲染；
- 代码解释器自动检测循环：`open_webui:code_interpreter` 输出项触发，`DETECT_CODE_INTERPRETER` 最多重试 5 次。引擎分发——pyodide 经 `event_caller({'type': 'execute:python'})` 推给前端浏览器，jupyter 调 `execute_code_jupyter`；`CODE_INTERPRETER_BLOCKED_MODULES` 注入受限 `__import__` 包装代码。
- Responses API 有状态模式与普通模式的拼接路径不同。

## 4. MCP 与外部工具服务器

- `connect_mcp_server`（utils/tools.py 201 行起，中间件 2696 行调用）的连接步骤：
  1. 查 `tool_server.connections` 中的 mcp 连接，做 `has_connection_access` 校验；
  2. `build_tool_server_headers` 组装鉴权头（bearer/session/oauth）；
  3. `MCPClient.connect` 建连（utils/mcp/client.py，`streamablehttp_client` + `OAuthClientProvider`）；
  4. `list_tool_specs` 拉取工具清单；
  5. `function_name_filter_list` 过滤。
- 工具名 `{server_id}_{tool_spec["name"]}`（utils/tools.py:576）；前端工具标识 `server:mcp:{id}`（routers/tools.py:173）；
- MCP 客户端默认不校验证书（`create_httpx_client`，utils/mcp/client.py 33-52 行），仅 `AIOHTTP_CLIENT_SESSION_TOOL_SERVER_SSL` 为真时走校验路径；
- 外部 OpenAPI 工具服务器经 `execute_tool_server` HTTP 调用，函数名前缀防冲突；
- 访问控制：DB 工具基于 `AccessGrants`（resource_type='tool'）；外部工具服务器基于连接级 access_grants + `has_connection_access`；`GET /api/v1/tools/` 对非 admin 返回可读工具（routers/tools.py:78）。

## 5. Filter / Pipeline 插件通道

### 5.1 本地函数插件

- `Function` 表（models/functions.py:21 行起）：id / user_id / name / type / content / meta / valves / is_active / is_global；
- 执行：`utils/filter.py` 先 `resolve_filter_pipeline` 解析活跃 filter——全局 filter + 模型 `filterIds`，`toggle` 控制活跃性，按 `Valves.priority` 排序；再经 `process_filter_functions` 按 handler 名执行，handler 必须可调用，除 inlet/stream/outlet 外新增 `request` 类型；
- 活跃 filter 列表与 Valves 缓存在请求作用域的 `FilterContext`（挂在 `request.state`，`get_filter_context` 惰性创建），同一请求内重复求值不再重复查库；`request` 在消息定稿前、工具审批恢复后、每轮工具调用之后各执行一次（`utils/filter.py:11-45,68-75,165-182`；`utils/middleware.py:5983-5995`）；
- Valves 注入、UserValves、`file_handler` 跳过文件的既有分支保留；
- 路由：`POST /sync`（routers/functions.py:158 行，批量 `replace_imports` + `load_function_module_by_id`）、`POST /create`（198 行）、Valves 系列。

### 5.2 远程 Pipeline

- `routers/pipelines.py`：`get_sorted_filters` 按 `pipeline.priority` 排序，再走 `process_pipeline_inlet_filter` 或 `process_pipeline_outlet_filter`（outlet 时模型自身 pipeline 排最前）；两者都 HTTP POST 到 `{base_url}/{filter_id}/filter/inlet|outlet`，没有候选过滤器时直接返回原 payload，不再建 HTTP 会话（`routers/pipelines.py:37,125`）；
- 管理路由：`GET /list`、`POST /upload`、`POST /add`、Valves 系列。

### 5.3 插件加载与 Valves

- `utils/plugin.py`：提供工具模块缓存、加载、import 替换与 Valves 动态 options 解析等函数（`load_tool_module_by_id` 208 行、`replace_imports` 189 行，以及 `get_tools_cache`/`get_tool_module_from_cache`/`resolve_valves_schema_options`）；插件加载行为受 `ENABLE_PLUGINS`、`OFFLINE_MODE`、`ENABLE_PIP_INSTALL_FRONTMATTER_REQUIREMENTS`、`PIP_OPTIONS` 四个开关控制；
- Valves 加密：`utils/valves.py` 用 `WEBUI_SECRET_KEY` 派生 Fernet 密钥，`ENABLE_VALVE_ENCRYPTION` 开关，`encrypt_valves`/`decrypt_valves` 被 models/tools.py 与 models/functions.py 复用；
- 工具 ZIP 上传路由：本版本**无** `/load/zip`，仅 `/load/url` 从 GitHub 拉取（routers/tools.py:422）。

## 6. 子代理（Sub-agents）

- `delegate_task`（builtin.py 1520-1554 行）→ `utils/subagents.py: delegate`（270-441 行）：
  - 读取 `subagents.*` 配置（289-300 行），并发上限（337-349 行）；
  - 创建独立 chat（`internal_meta` type=subagent，358-401 行）；
  - `_build_request`（47-69 行）伪造内部 POST `/api/v1/subagents/internal`，签发 1 小时 `typ: 'subagent'` token，递归调用 `CHAT_COMPLETION_HANDLER`；
  - `run_reserved`（413-441 行）组装子代理请求，系统提示词 = 父 prompt + `subagents.system_prompt`；
- `process_pending_internal_messages`（72-267 行）：父聊天合并待处理子代理/定时器消息批量回填（含 SQL `for_update` 行锁 92-94 行；`sio.emit('chat:reload')` 刷新前端 232-240 行）；
- `MUTATING_MEMORY_TOOLS`（34-39 行）= {add_memory, delete_memory, replace_memory_content, update_memory}，子代理内部禁用。

## 7. 前端工具 UI

- `MessageInput/IntegrationsMenu.svelte`：输入框「集成」菜单的 Tools tab（149-162 行切换、376-494 行工具开关列表，支持 MCP 未认证提示、UserValves 配置）；
- `workspace/Tools.svelte`：工作区工具管理页（上传/编辑/Valves）；
- `workspace/Models/ToolsSelector.svelte`：模型绑定工具选择器；
- 数据来自 `getTools` API（src/lib/apis/tools/index.ts 68 行 → `GET /api/v1/tools/`）；
- `MessageInput/Tools.svelte` **不存在**（MessageInput 目录无此文件）。

## 8. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| 内置工具 | 有（64 个） | 条件注入 + 四重开关 |
| 自定义 Python 工具 | 有 | DB 存储 + 动态加载 + Valves |
| MCP 工具服务器 | 有 | streamablehttp + OAuth，默认不校 TLS |
| OpenAPI 工具服务器 | 有 | server: 前缀 + HTTP 调用 |
| 多轮工具循环 | 有 | 上限 `max_tool_call_iterations` |
| 参数白名单过滤 | 有 | 按 spec properties 过滤 |
| 工具结果引用 | 有 | 6 类工具提取 source + RAG 重写 |
| 代码解释器 | 有 | pyodide（前端）/ jupyter（后端）双引擎 |
| 子代理 | 有 | 内部 API 重入 + 并发限流 |
| Filter 过滤器 | 有 | 本地插件 + 远程 pipeline |
| Valves 加密 | 有 | Fernet + 开关 |
| 工具访问控制 | 有 | AccessGrants |
| 工具社区同步 | 有 | /load/url 从 GitHub 拉取（无 zip 上传） |
| 前端工具选择 | 有 | IntegrationsMenu |

## 9. 关键源码索引

- 工具调用主循环：[`utils/middleware.py`](../../open-webui/backend/open_webui/utils/middleware.py)（`process_chat_payload` 2055、`process_tool_result` 729、`get_citation_source_from_tool_result` 457、`execute_tool_call` 3092）
- 内置工具实现：[`tools/builtin.py`](../../open-webui/backend/open_webui/tools/builtin.py)
- 审批状态、决议与恢复请求：[`utils/tool_approval.py`](../../open-webui/backend/open_webui/utils/tool_approval.py)（`resolve_tool_call_output`、`complete_tool_call`、`build_tool_approval_resume_payload`）
- kb_exec：[`tools/knowledge_fs.py`](../../open-webui/backend/open_webui/tools/knowledge_fs.py)（1171-1234 行）
- 工具加载/注入：[`utils/tools.py`](../../open-webui/backend/open_webui/utils/tools.py)（365、626、1122-1154 行）
- 工具 CRUD：[`routers/tools.py`](../../open-webui/backend/open_webui/routers/tools.py)
- Tool 表：[`models/tools.py`](../../open-webui/backend/open_webui/models/tools.py)
- 过滤器执行：[`utils/filter.py`](../../open-webui/backend/open_webui/utils/filter.py)（`get_filter_context` 38、`resolve_filter_pipeline` 68、`process_filter_functions` 212 行）
- 远程 pipeline：[`routers/pipelines.py`](../../open-webui/backend/open_webui/routers/pipelines.py)（37、125 行）
- 插件加载：[`utils/plugin.py`](../../open-webui/backend/open_webui/utils/plugin.py)（189、208 行）
- Valves 加密：[`utils/valves.py`](../../open-webui/backend/open_webui/utils/valves.py)
- 子代理：[`utils/subagents.py`](../../open-webui/backend/open_webui/utils/subagents.py)（36、65、296 行）
- MCP 客户端：[`utils/mcp/client.py`](../../open-webui/backend/open_webui/utils/mcp/client.py)
- 代码解释器：[`utils/code_interpreter.py`](../../open-webui/backend/open_webui/utils/code_interpreter.py)
- 任务工具后端：[`tasks.py`](../../open-webui/backend/open_webui/tasks.py)
- 前端工具 UI：[`src/lib/components/chat/MessageInput/IntegrationsMenu.svelte`](../../open-webui/src/lib/components/chat/MessageInput/IntegrationsMenu.svelte)
