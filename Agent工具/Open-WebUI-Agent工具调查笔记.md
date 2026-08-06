# Open WebUI Agent 工具调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读源码核对（utils/middleware.py 工具主循环、tools/builtin.py 内置工具、utils/tools.py、routers/tools.py、utils/filter.py、functions.py、utils/mcp、utils/subagents、代码解释器）；未修改目标仓库
>
> 调查范围：工具生态与注册、内置工具条件注入、工具调用执行循环、Filter/Pipeline、MCP、子代理、代码解释器、Valves 与插件加载、前端工具 UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.0 的工具调用主循环位于 `utils/middleware.py`，而不是路由或 utils/chat.py：`process_chat_payload`（2248 行）编排 → `connect_mcp_server`（2197 行）连接外部工具服务器 → `execute_tool_call`（4969 行）执行单个工具 → `process_tool_result`（871 行）后处理结果 → 重新 `generate_chat_completion` 发起下一轮。

- 工具分三大来源，统一注册成 `tools_dict`（middleware.py 2732 行起）：本地数据库工具（`get_tools`，utils/tools.py 267 行）、内置工具（`get_builtin_tools`，520 行）、外部 MCP/OpenAPI 工具服务器（`server:*` 前缀）；每条工具条目为 `{tool_id, callable, spec, type}`，`type ∈ {builtin, external, mcp}`，另有 `direct` 标志（前端直连执行）；
- **内置工具是条件注入而非全量暴露**：共 54 个内置工具函数（tools/builtin.py，文件头明确警告只能经 utils/tools.py 封装使用），按 16 个类别做四重开关检查——模型 meta 的 `builtinTools` 类别开关、全局配置（`Config.get`）、模型能力（`get_model_capability`）、用户权限；
- 请求体显式携带 `tools` 键（含 `tools: []`）时完全跳过服务端工具解析（middleware.py 2720-2723 行）；`use_builtin_tools` 判定见 2643-2649 行；
- 工具参数校验是**白名单过滤**：`execute_tool_call` 从 `metadata['tools']` 按函数名取工具，用 spec 的 `parameters.properties` 键集过滤模型传入参数，解析失败返回错误文案；
- 多轮工具调用循环上限 `max_tool_call_iterations`（默认 `CHAT_RESPONSE_MAX_TOOL_CALL_ITERATIONS`）；每轮把 tool call 以 `function_call` 项加入输出、执行后加 `function_call_output` 项、再拼回消息重发；工具结果中的 base64 图片拆成 `input_image` 供 LLM 消费，前端展示则剥离，图片另附一条 user 消息；
- 仅 `search_web / fetch_url / view_file / view_knowledge_file / query_knowledge_files / query_chat_files` 六类工具的结果提取引用来源（`get_citation_source_from_tool_result`），经 `event_emitter({'type': 'source'})` 发前端，并按 RAG 模板重写上下文注入（先恢复 pre-RAG 消息防重复）；
- 代码解释器双引擎：`code_interpreter.engine` 为 `pyodide` 时通过 `event_caller({'type': 'execute:python'})` 推送前端浏览器执行；为 `jupyter` 时调用 `execute_code_jupyter`（utils/code_interpreter.py，WebSocket 连 Jupyter kernel）；`CODE_INTERPRETER_BLOCKED_MODULES` 会注入受限 `__import__` 包装代码；
- MCP 工具通过 `client.call_tool` 直接调用，工具名统一为 `{server_id}_{tool_spec["name"]}`；连接前做 `has_connection_access` 访问授权校验；
- 子代理（Sub-agents）是内部 API 重入：`delegate_task`（builtin.py 1520 行）→ `utils/subagents.py: delegate`（270 行）创建独立 chat（`internal_meta` type=subagent）→ `_build_request` 伪造带 `typ: 'subagent'` token 的内部请求 → 递归调用 `CHAT_COMPLETION_HANDLER`；后台模式用信号量限流，上限 `subagents.max_concurrent`/`max_async`；子代理内部禁用 memory 写类工具（`MUTATING_MEMORY_TOOLS`）；
- Filter/Pipeline 是两条并行通道：本地函数插件经 `utils/filter.py` 的 `process_filter_functions`（197 行）按 inlet/stream/outlet handler 执行；远程 pipeline 服务器经 HTTP POST 到 `{url}/{filter_id}/filter/inlet|outlet`；执行顺序：Pipeline Inlet → Filter Inlet → Chat Memory → Web Search → Image Gen → Code Interpreter → Tools Function Calling → Files；
- Valves 配置全部经 Fernet 加密存储（utils/valves.py），`WEBUI_SECRET_KEY` 派生密钥，`ENABLE_VALVE_ENCRYPTION` 开关；
- 前端工具 UI 在 `MessageInput/IntegrationsMenu.svelte`（集成菜单的 Tools tab），非独立 Tools.svelte；工作区管理页 `workspace/Tools.svelte` 负责上传/编辑/Valves。

## 1. 内置工具生态

[`tools/builtin.py`](../../open-webui/backend/open_webui/tools/builtin.py)（4362 行）定义 54 个内置工具，按类别与注入条件（utils/tools.py 577-770 行）：

| 类别 | 工具（builtin.py 行号） | 注入条件 |
|---|---|---|
| 通知/时间 | `notify`(122)、`get_current_timestamp`(149)、`calculate_timestamp`(185) | time(:577) |
| 网页 | `search_web`(282，结果数受 `web.search.result_count` 限制)、`fetch_url`(321，`web.fetch.max_content_length` 截断) | web_search(:673-680) |
| 图像 | `generate_image`(358)、`edit_image`(423) | image_generation(:684-699) |
| 代码 | `execute_code`(496) | code_interpreter(:703-710) |
| 记忆 | `list_memory_paths`(663)、`read_memory_path`(694)、`search_memories`(728)、`add_memory`(786)、`update_memory`(826)、`replace_memory_content`(867)、`delete_memory`(916)、`list_memories`(948) | memory(:653-670)；内部会话剔除写类工具 |
| 笔记 | `search_notes`(990)、`view_note`(1087)、`write_note`(1149)、`replace_note_content`(1198) | notes(:718-721) |
| 聊天历史 | `search_chats`(1367)、`view_chat`(1450) | chats(:641) |
| 子代理 | `delegate_task`(1520，`background` 参数在 `subagents.background_enabled` 关闭时被剥离)、`timer`(1557) | subagents(:644-650) |
| 频道 | `search_channels`(1599)、`search_channel_messages`(1651)、`view_channel_message`(1732)、`view_channel_thread`(1793) | channels(:724-732) |
| 知识库 | `list_knowledge_bases`(1882)、`search_knowledge_bases`(1940)、`search_knowledge_files`(2000)、`list_knowledge`(2850)、`query_knowledge_files`(2992)、`query_knowledge_bases`(3211)、`grep_knowledge_files`(2468)、`view_knowledge_file`(2704) | knowledge(:603-638，分 `ENABLE_KB_EXEC` / 有挂载知识 / 无知识三种形态) |
| 聊天文件 | `list_chat_files`(2251)、`grep_chat_files`(2291)、`query_chat_files`(2346)、`view_file`(2588) | files(:590-597，需模型关 file_context 且有聊天文件) |
| 技能 | `view_skill`(3321) | skills(:735) |
| 任务 | `create_tasks`(3421)、`update_task`(3471) | tasks(:740-741，需已保存 chat) |
| 自动化 | `create_automation`(3537)、`update_automation`(3639)、`list_automations`(3739)、`toggle_automation`(3810)、`delete_automation`(3861) | automations(:744-751) |
| 日历 | `search_calendar_events`(3965)、`create_calendar_event`(4058)、`update_calendar_event`(4185)、`delete_calendar_event`(4305) | calendar(:754-757) |
| 通知 | notify | notifications(:759-764) |

另有一个特殊工具 `kb_exec`（[`tools/knowledge_fs.py`](../../open-webui/backend/open_webui/tools/knowledge_fs.py) 1125-1183 行）：把知识库当"文件系统"的类 shell 命令工具，支持 `ls/tree/cat/head/tail/sed/grep/find/wc/stat` 及管道；`match_budget`（55 行）限制匹配预算，输出超 `KB_EXEC_MAX_OUTPUT_CHARS` 截断；`ENABLE_KB_EXEC` 决定注入它还是传统组合工具。

## 2. 工具注册与加载

### 2.1 数据库工具（utils/tools.py `get_tools` 267-478 行）

- 批量 `Tools.get_tools_by_ids`（281 行）→ `AccessGrants.has_access` 校验（287-299 行）→ `load_tool_module_by_id` 缓存（301-307 行）→ Valves 注入（314-320 行）→ spec 清洗（`str`→`string` 类型修正、剥离 `__` 前缀保留参数）→ `get_async_tool_function_and_apply_extra_params` 绑定 `__id__`/`__user__` → 函数名冲突时前缀 `{tool_id}_`（365-369 行）；
- `server:` 前缀走 OpenAPI 工具服务器分支（372-476 行）：`function_name_filter_list` 过滤（414-426 行）、`execute_tool_server` HTTP 调用（439-451 行）；
- `Tool` 表（models/tools.py 21-34 行）：id / user_id / name / content / specs / meta / valves / 时间戳；写入时同步 `AccessGrants.set_access_grants`（135 行）。

### 2.2 内置工具 spec

- spec 生成用 `get_builtin_function_introspection` / `build_builtin_tool_spec`（utils/tools.py 943-959 行）：函数 → pydantic 模型 → OpenAI function spec，`@cache` 缓存；
- `clean_openai_tool_schema`（932-939 行）；`get_tool_specs`（974-982 行）负责用户自定义工具 spec。

## 3. 工具调用执行循环（utils/middleware.py）

```text
process_chat_payload (2248)
  -> payload_tools is None 时服务端解析 tool_ids（2720-2807）
       server:mcp: 前缀 -> 逐服务器 connect_mcp_server + 注册（2757-2779, type='mcp'）
       其余 -> get_tools
  -> 请求发给上游，模型返回 tool_calls
  -> while tool_calls and iterations < max_tool_call_iterations（4916-5314）
       parse_tool_params（4954，JSON 解析失败回退 ast.literal_eval）
       execute_tool_call（4969）
         direct 工具 -> event_caller({'type': 'execute:tool'}) 推前端执行（4983-4995）
         普通工具 -> get_updated_tool_function 绑定 __messages__/__files__ 后 await（4997-5004）
       delegate_task 特殊并发收集（5009-5023）
       process_tool_result（5041-5049）+ 终端事件转发 + 引用提取（5058-5081）
       function_call -> completed + function_call_output 回填（5092-5127）
       引用 -> RAG 模板上下文重建（5140-5200）
       convert_output_to_messages 拼回消息（5239-5262）
       generate_chat_completion 再请求（5278-5283）
  -> 迭代上限报错（5316-5323）
```

- 工具结果中的 base64 图片拆成 `input_image` 供 LLM 消费、前端展示则剥离（5106-5115、5202-5211 行），图片另附一条 user 消息（5264-5276 行）；
- `process_tool_result`（871 行）支持 `(HTMLResponse, result_context)` 元组：HTML 部分经 `tool_result_embeds` 直达前端 iframe 渲染（详见信息污染源笔记）；
- 代码解释器自动检测循环（5325-5395 行）：`open_webui:code_interpreter` 输出项触发，`DETECT_CODE_INTERPRETER` 最多 5 次重试；引擎分发：pyodide → `event_caller({'type': 'execute:python'})`；jupyter → `execute_code_jupyter(url, code, token/password)`；`CODE_INTERPRETER_BLOCKED_MODULES` 注入受限 `__import__` 包装代码（5350-5368 行）；
- Responses API 有状态模式（5230-5237 行）与普通模式（5239-5277 行）的拼接路径不同。

## 4. MCP 与外部工具服务器

- `connect_mcp_server`（middleware.py 2197-2245 行）：查 `tool_server.connections` 中的 mcp 连接 → `has_connection_access` → `build_tool_server_headers`（bearer/session/oauth）→ `MCPClient.connect`（utils/mcp/client.py，`streamablehttp_client` + `OAuthClientProvider`）→ `list_tool_specs` 拉取工具清单 → `function_name_filter_list` 过滤（2237-2243 行）；
- 工具名 `{server_id}_{tool_spec["name"]}`（2770-2773 行）；前端工具标识 `server:mcp:{id}`（routers/tools.py 143 行）；
- MCP 客户端默认 `verify=False`（`create_insecure_httpx_client`，client.py 55-56 行），仅 `AIOHTTP_CLIENT_SESSION_TOOL_SERVER_SSL` 为真时走校验路径（70-72 行）；
- 外部 OpenAPI 工具服务器经 `execute_tool_server` HTTP 调用，函数名前缀防冲突；
- 访问控制：DB 工具基于 `AccessGrants`（resource_type='tool'）；外部工具服务器基于连接级 access_grants + `has_connection_access`；`GET /api/v1/tools/` 对非 admin 返回可读工具（routers/tools.py 168-195 行）。

## 5. Filter / Pipeline 插件通道

### 5.1 本地函数插件

- `Function` 表（models/functions.py 19-34 行）：id / user_id / name / type / content / meta / valves / is_active / is_global；
- 执行：`utils/filter.py` `resolve_filter_pipeline`（56 行，全局 filter + 模型 `filterIds`，`toggle` 属性控制活跃性，`Valves.priority` 排序 76-91 行）→ `process_filter_functions`（197 行）按 inlet/stream/outlet handler 执行；
- Valves 注入（108-120 行）、UserValves（135-144 行）、`file_handler` 跳过文件（172-174、229-233 行）；
- 路由：`POST /sync`（routers/functions.py 162 行，批量 `replace_imports` + `load_function_module_by_id`）、`POST /create`（199 行）、Valves 系列（458-641 行）。

### 5.2 远程 Pipeline

- `routers/pipelines.py`：`get_sorted_filters`（41-54 行，按 `pipeline.priority` 排序）→ `process_pipeline_inlet_filter`（63 行）/ `process_pipeline_outlet_filter`（126 行，outlet 时模型自身 pipeline 排最前）——都 HTTP POST 到 `{base_url}/{filter_id}/filter/inlet|outlet`；
- 管理路由：`GET /list`、`POST /upload`、`POST /add`、Valves 系列。

### 5.3 插件加载与 Valves

- `utils/plugin.py`：`get_tools_cache` / `get_tool_module_from_cache` / `load_tool_module_by_id` / `replace_imports` / `resolve_valves_schema_options`（27 行，Valves 动态 options）；受 `ENABLE_PLUGINS / OFFLINE_MODE / ENABLE_PIP_INSTALL_FRONTMATTER_REQUIREMENTS / PIP_OPTIONS` 控制；
- Valves 加密：`utils/valves.py` 用 `WEBUI_SECRET_KEY` 派生 Fernet 密钥，`ENABLE_VALVE_ENCRYPTION` 开关，`encrypt_valves`/`decrypt_valves` 被 models/tools.py 与 models/functions.py 复用；
- 工具 ZIP 上传路由：本版本**无** `/load/zip`，仅 `/load/url` 从 GitHub 拉取（routers/tools.py 264 行）。

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
- `MessageInput/Tools.svelte` **不存在**（MessageInput 目录无此文件，这是与旧版本/其他项目的差异点）。

## 8. 能力矩阵

| 能力 | 当前实现 | 说明 |
|---|---|---|
| 内置工具 | 有（54 个） | 条件注入 + 四重开关 |
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

- 工具调用主循环：[`utils/middleware.py`](../../open-webui/backend/open_webui/utils/middleware.py)（2248、2197、4969、871、5325-5395 行）
- 内置工具实现：[`tools/builtin.py`](../../open-webui/backend/open_webui/tools/builtin.py)
- kb_exec：[`tools/knowledge_fs.py`](../../open-webui/backend/open_webui/tools/knowledge_fs.py)（1125-1183 行）
- 工具加载/注入：[`utils/tools.py`](../../open-webui/backend/open_webui/utils/tools.py)（267、520、943-982 行）
- 工具 CRUD：[`routers/tools.py`](../../open-webui/backend/open_webui/routers/tools.py)
- Tool 表：[`models/tools.py`](../../open-webui/backend/open_webui/models/tools.py)
- 过滤器执行：[`utils/filter.py`](../../open-webui/backend/open_webui/utils/filter.py)（56、197 行）
- 远程 pipeline：[`routers/pipelines.py`](../../open-webui/backend/open_webui/routers/pipelines.py)（63、126 行）
- 插件加载：[`utils/plugin.py`](../../open-webui/backend/open_webui/utils/plugin.py)（27 行）
- Valves 加密：[`utils/valves.py`](../../open-webui/backend/open_webui/utils/valves.py)
- 子代理：[`utils/subagents.py`](../../open-webui/backend/open_webui/utils/subagents.py)（47、72、270 行）
- MCP 客户端：[`utils/mcp/client.py`](../../open-webui/backend/open_webui/utils/mcp/client.py)
- 代码解释器：[`utils/code_interpreter.py`](../../open-webui/backend/open_webui/utils/code_interpreter.py)
- 任务工具后端：[`tasks.py`](../../open-webui/backend/open_webui/tasks.py)
- 前端工具 UI：[`src/lib/components/chat/MessageInput/IntegrationsMenu.svelte`](../../open-webui/src/lib/components/chat/MessageInput/IntegrationsMenu.svelte)
