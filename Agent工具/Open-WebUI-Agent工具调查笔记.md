# Open WebUI Agent 工具调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：只读源码核对（utils/middleware.py 工具主循环、tools/builtin.py 内置工具、utils/tools.py、routers/tools.py、utils/filter.py、functions.py、utils/mcp、utils/subagents、代码解释器）；未修改目标仓库
>
> 调查范围：工具生态与注册、内置工具条件注入、工具调用执行循环、Filter/Pipeline、MCP、子代理、代码解释器、Valves 与插件加载、前端工具 UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 当前快照的工具调用主循环由 `utils/middleware.py` 承担，路由层与 utils/chat.py 不承载这段循环。编排入口 `process_chat_payload` 串起一轮调用：先连接外部工具服务器，再执行模型选中的单个工具，随后处理工具结果，再带着结果重新请求模型进入下一轮；三个阶段分别对应 `connect_mcp_server`、`execute_tool_call` 与 `process_tool_result`（utils/tools.py:201，middleware.py 2055、2696、3092、729 行）。各步骤详细链路见第 3 节代码块。

- 中间件把三类来源的工具统一注册成 `tools_dict`：本地数据库工具由 `get_tools` 读取，内置工具由 `get_builtin_tools` 提供，外部 MCP 与 OpenAPI 工具服务器以 `server:` 前缀区分（utils/tools.py 365、626 行；middleware.py 2684-2775 行）。每个注册条目包含工具 id、可调用对象、spec 与来源类型，来源类型取 builtin、external、mcp 三种值，`direct` 标志表示该工具交给前端直连执行；
- **内置工具按条件注入，不整批暴露**：共 64 个内置工具函数（tools/builtin.py，文件头明确警告只能经 utils/tools.py 封装使用），按 18 个类别做四重开关检查——模型 meta 的 `builtinTools` 类别开关、全局配置（`Config.get`）、模型能力（`get_model_capability`）、用户权限；
- 请求体显式携带 `tools` 键时以该键为工具来源，空数组同样算显式指定，这条路径跳过服务端数据库工具解析；内置工具是否参与另由 `use_builtin_tools` 判定（middleware.py 2096、2110、2507、2901 行）；
- 工具参数先做 JSON 解析，失败尝试 Python 字面量解析，并要求根值为对象。除 MCP 交给远端校验外，其余工具按 schema 属性白名单过滤多余参数；包装函数还进行少量标量类型转换。这些步骤不构成通用完整 JSON Schema 校验（[`utils/middleware.py:3092-3132`](../../open-webui/backend/open_webui/utils/middleware.py#L3092-L3132)、[`utils/tools.py:286-326`](../../open-webui/backend/open_webui/utils/tools.py#L286-L326)）；
- 多轮工具调用循环上限 `max_tool_call_iterations`（默认 `CHAT_RESPONSE_MAX_TOOL_CALL_ITERATIONS`）；每轮把 tool call 以 `function_call` 项加入输出、执行后加 `function_call_output` 项、再拼回消息重发；工具结果中的 base64 图片拆成 `input_image` 供 LLM 消费，前端展示则剥离，图片另附一条 user 消息；
- 引用来源只由四类知识/文件工具的结果产生：`view_knowledge_file`、`query_knowledge_files` 针对知识库文件，`view_file`、`query_chat_files` 针对聊天文件，转换由 `get_citation_source_from_tool_result` 完成；来源再以 source 类型事件发给前端，并按 RAG 模板重写上下文注入（先恢复 pre-RAG 消息防重复）。网页检索结果的来源事件另由搜索链路发布，不经过该函数（middleware.py 457-600 行）；
- 代码解释器双引擎：`code_interpreter.engine` 为 `pyodide` 时通过前端事件推给浏览器执行；为 `jupyter` 时调用后端函数、经 WebSocket 连 Jupyter kernel；模块黑名单会注入受限的 `__import__` 包装代码（utils/code_interpreter.py）；
- MCP 工具通过 `client.call_tool` 直接调用，工具名统一为 `{server_id}_{tool_spec["name"]}`；连接前做 `has_connection_access` 访问授权校验；
- 子代理（Sub-agents）通过内部 API 重入实现：内置工具 `delegate_task` 接到调用后转给子代理模块的 `delegate`，后者创建一条独立 chat（内部标记为 subagent 类型），再伪造带 subagent 类型 token 的内部请求，递归调用 `CHAT_COMPLETION_HANDLER`（builtin.py 1774 行、subagents.py 296 行）。后台模式用信号量限流，并发与异步两个上限由 `subagents` 配置控制；子代理内部禁用写类 memory 工具。
- Filter/Pipeline 是两条并行通道：本地函数插件经 `utils/filter.py` 的 `process_filter_functions` 按 inlet/stream/outlet 与 request 四类 handler 执行；远程 pipeline 服务器经 HTTP POST 到 `{url}/{filter_id}/filter/inlet|outlet`；能力注入顺序：Pipeline Inlet → Filter Inlet → Chat Memory → Web Search → Image Gen → Code Interpreter → Tools Function Calling → Files；消息定稿前还会跑一次 Filter `request`，工具审批恢复与每轮工具调用之后也会重跑该阶段；
- Valves 配置全部经 Fernet 加密存储（utils/valves.py），`WEBUI_SECRET_KEY` 派生密钥，`ENABLE_VALVE_ENCRYPTION` 开关；
- 工具审批可选择完整访问或逐次询问。持久聊天的逐次询问把首个调用置为 pending、其余置为 queued，并保存恢复所需参数；决议和实际执行认领在服务端事务内完成，已批准或已结算调用返回冲突。人工提问的语义是收集答案，持久聊天中与审批共用暂停落库和 resolve 端点；答案回填为工具结果后继续模型生成，完整访问也不会代答。临时聊天则使用在线 Socket 回调，普通工具必须收到严格的 true 才视为批准（[`utils/middleware.py:3134-3150,3188-3393`](../../open-webui/backend/open_webui/utils/middleware.py#L3134-L3393)、[`utils/tool_approval.py:67-185`](../../open-webui/backend/open_webui/utils/tool_approval.py#L67-L185)）。
- `ask_user` 要求当前批次仅有一个调用，问题数为 1–3、每题 2–3 个选项；该校验读取当前批次，没有累计整个生成回合的提问次数。非法调用各自写入错误结果后从执行列表剔除，其他工具仍继续；问题卡的作答与超时经 answer 动作结算（[`utils/ask_user.py:9-81,85-151`](../../open-webui/backend/open_webui/utils/ask_user.py#L9-L151)、[`utils/middleware.py:5707-5730`](../../open-webui/backend/open_webui/utils/middleware.py#L5707-L5730)）。
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

另有一个特殊工具 `kb_exec`，把知识库当作文件系统来执行类 shell 命令，支持 ls、tree、cat、head、tail、sed、grep、find、wc、stat 与管道组合（[`tools/knowledge_fs.py`](../../open-webui/backend/open_webui/tools/knowledge_fs.py) 1171-1234 行，单次匹配预算由 43 行的 `match_budget` 限制）。输出超过 `KB_EXEC_MAX_OUTPUT_CHARS` 会被截断；是否注入该工具由 `ENABLE_KB_EXEC` 决定，关闭时改用传统组合工具。

### 延迟目录与两阶段调用

延迟目录按单个 schema 的序列化字符长度判定，并非工具数量阈值。启用工具检索后，服务端从已授权候选集中选出超过阈值、未命中常驻名称模式的工具；内置工具是否参与另有开关。候选名称若与检索器或分派器保留名称冲突，则本请求跳过延迟机制。被延迟的 schema 从上游 tools 数组移除，名称与最多 100 字符描述写入系统提示（[`utils/tool_search.py:25-131`](../../open-webui/backend/open_webui/utils/tool_search.py#L25-L131)、[`utils/middleware.py:2898-2904`](../../open-webui/backend/open_webui/utils/middleware.py#L2898-L2904)）。

模型先用 `search_tools` 获取完整定义，再用 `call_tool` 包装目标名称及 JSON 字符串参数执行。检索结果作为普通工具结果返回，**不会动态扩充上游 tools 数组**。排序先处理精确名称，再用 BM25 与词项重叠分数；默认返回 5 项、最多 20 项（[`tools/builtin.py:4025-4049`](../../open-webui/backend/open_webui/tools/builtin.py#L4025-L4049)、[`utils/tool_search.py:179-220`](../../open-webui/backend/open_webui/utils/tool_search.py#L179-L220)）。

分派器在审批与人工提问检查前解包为真实工具调用，同时保留 `provider_function` 供协议历史重放。它校验包装字段、目标可用性和参数对象，执行仍经过目标工具的原有审批与执行域；这里没有“必须先检索成功”的授权状态，授权候选集才是执行边界（[`utils/tool_search.py:134-164`](../../open-webui/backend/open_webui/utils/tool_search.py#L134-L164)、[`utils/middleware.py:5672-5705`](../../open-webui/backend/open_webui/utils/middleware.py#L5672-L5705)）。

## 2. 工具注册与加载

### 2.1 数据库工具（utils/tools.py `get_tools` 365-624 行）

- 数据库工具由 `get_tools` 按固定顺序装载（utils/tools.py）：
  1. 批量读取 `Tools.get_tools_by_ids`；
  2. 经 `AccessGrants.has_access` 做授权校验；
  3. 通过 `load_tool_module_by_id` 取模块缓存；
  4. 注入 Valves；
  5. 清洗 spec：把 `str` 修正成 `string` 类型，剥离 `__` 前缀并保留参数；
  6. 由 `get_async_tool_function_and_apply_extra_params` 绑定 `__id__` 与 `__user__`；
  7. 函数名冲突时加 `{tool_id}_` 前缀；
- 带 `server:` 前缀的工具走 OpenAPI 工具服务器分支：名称先经 `function_name_filter_list` 过滤，再由 `execute_tool_server` 发起 HTTP 调用（1797 行）；
- `Tool` 表保存自定义工具的定义（models/tools.py 26 行起），字段覆盖 id、user_id、name、content、specs、meta、valves 与创建、更新时间戳；写入时同步调用 `AccessGrants.set_access_grants`。

### 2.2 内置工具 spec

- 内置工具的 spec 由 `get_builtin_function_introspection` 与 `build_builtin_tool_spec_json` 生成：函数先转成 pydantic 模型，再输出成 OpenAI function spec，结果带缓存（utils/tools.py 1122、1131 行）；
- 生成结果再经 `clean_openai_tool_schema` 清洗；用户自定义工具的 spec 由 `get_tool_specs` 负责（1111、1154 行）。
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

- 工具结果里的 base64 图片会被拆成 `input_image` 交给 LLM 消费，前端展示时剥离这部分内容，并另附一条 user 消息承载图片；
- 结果处理函数 `process_tool_result` 还支持 `(HTMLResponse, result_context)` 元组：元组里的 HTML 部分经 `tool_result_embeds` 送到前端，由 iframe 直接渲染（middleware.py 729 行）；
- 代码解释器结果会触发自动检测循环：输出项出现 `open_webui:code_interpreter` 时启动，`DETECT_CODE_INTERPRETER` 最多重试 5 次。执行位置按引擎分发：pyodide 引擎推给前端浏览器执行，jupyter 引擎走后端执行路径；此外还会按 `CODE_INTERPRETER_BLOCKED_MODULES` 注入受限的 `__import__` 包装代码。
- Responses API 有状态模式与普通模式的拼接路径不同。

## 4. MCP 与外部工具服务器

- 中间件在 2696 行调用 `connect_mcp_server`（utils/tools.py 201 行起），连接一个 MCP 服务器依次完成以下步骤：
  1. 查 `tool_server.connections` 中的 mcp 连接，做 `has_connection_access` 校验；
  2. `build_tool_server_headers` 组装鉴权头（bearer/session/oauth）；
  3. `MCPClient.connect` 建连（utils/mcp/client.py，`streamablehttp_client` + `OAuthClientProvider`）；
  4. `list_tool_specs` 拉取工具清单；
  5. `function_name_filter_list` 过滤。
- 服务端把每个 MCP 工具命名为 `{server_id}_{tool_spec["name"]}`，前端则用 `server:mcp:{id}` 标识同一个服务器（utils/tools.py:576、routers/tools.py:173）；
- MCP 客户端默认不校验证书（`create_httpx_client`，utils/mcp/client.py 33-52 行），仅 `AIOHTTP_CLIENT_SESSION_TOOL_SERVER_SSL` 为真时走校验路径；
- 外部 OpenAPI 工具服务器经 `execute_tool_server` HTTP 调用，函数名前缀防冲突；
- 访问控制分两层：数据库工具基于 `AccessGrants`（resource_type 为 tool），外部工具服务器在连接级 access_grants 之上再加 `has_connection_access` 校验；工具列表接口 `GET /api/v1/tools/` 对非 admin 用户只返回可读工具（routers/tools.py:78）。

## 5. Filter / Pipeline 插件通道

### 5.1 本地函数插件

- `Function` 表保存每个函数插件的定义与状态（models/functions.py:21 行起）：标识与归属是 id、user_id，名称与类型是 name、type，源码与元数据是 content、meta，此外还有 valves 配置和 is_active、is_global 两个状态位；
- 执行时，`utils/filter.py` 先解析出活跃 filter：全局 filter 与模型绑定的 `filterIds` 合并，`toggle` 控制单项是否活跃，结果按 `Valves.priority` 排序；随后按 handler 名逐个调用，handler 必须可调用，类型覆盖 inlet、stream、outlet 与 `request` 四种；
- 活跃 filter 列表与 Valves 缓存在请求作用域的 `FilterContext` 中（挂在请求状态对象上，首次访问时创建），同一请求内重复求值不再重复查库；`request` handler 在消息定稿前、工具审批恢复后、每轮工具调用之后各执行一次（`utils/filter.py:11-45,68-75,165-182`、`utils/middleware.py:5983-5995`）；
- Valves 注入、UserValves 与 `file_handler` 跳过文件这三种处理分支照常生效；
- 路由方面，`POST /sync` 批量执行 `replace_imports` 与 `load_function_module_by_id`，`POST /create` 负责创建，另有 Valves 系列端点（routers/functions.py:158、198 行）。

### 5.2 远程 Pipeline

- 远程 pipeline 的执行集中在 `routers/pipelines.py`：`get_sorted_filters` 先按 `pipeline.priority` 排出候选顺序，再分 inlet、outlet 两阶段各自 HTTP POST 到 `{base_url}/{filter_id}/filter/inlet` 或对应 outlet 端点，outlet 阶段把模型自身的 pipeline 排在最前；候选过滤器为空时直接返回原 payload，不建立 HTTP 会话（37、125 行）；
- 管理路由：`GET /list`、`POST /upload`、`POST /add`、Valves 系列。

### 5.3 插件加载与 Valves

- `utils/plugin.py` 同时承担插件模块缓存、加载、import 替换与 Valves 动态 options 解析：模块加载与 import 替换分别由 `load_tool_module_by_id`、`replace_imports` 完成，缓存读取与 options 解析另有辅助函数（189、208 行）。插件加载行为受四个开关控制：插件总开关、离线模式、frontmatter 依赖安装与 pip 选项；
- Valves 配置的加解密在 `utils/valves.py` 内完成：`WEBUI_SECRET_KEY` 用来派生 Fernet 密钥，`ENABLE_VALVE_ENCRYPTION` 控制开关，`encrypt_valves` 与 `decrypt_valves` 被 models/tools.py、models/functions.py 复用；
- 工具 ZIP 上传路由：本版本**无** `/load/zip`，仅 `/load/url` 从 GitHub 拉取（routers/tools.py:422）。

## 6. 子代理（Sub-agents）

- 子代理调用从 `delegate_task` 进入，收到请求后转交 `utils/subagents.py` 的 `delegate` 执行（builtin.py 1520-1554 行、subagents.py 270-441 行）：
  - 读取 `subagents.*` 配置与并发上限（289-300、337-349 行）；
  - 创建独立 chat（`internal_meta` type=subagent，358-401 行）；
  - `_build_request`（47-69 行）伪造内部 POST `/api/v1/subagents/internal`，签发 1 小时 `typ: 'subagent'` token，递归调用 `CHAT_COMPLETION_HANDLER`；
  - `run_reserved`（413-441 行）组装子代理请求，系统提示词 = 父 prompt + `subagents.system_prompt`；
- `process_pending_internal_messages` 把待处理的子代理与定时器消息合并回填到父聊天，回填过程中用 SQL `for_update` 行锁保护待处理记录，完成后经 `sio.emit('chat:reload')` 让前端重新加载（utils/subagents.py 72-267、92-94、232-240 行）；
- `MUTATING_MEMORY_TOOLS`（34-39 行）= {add_memory, delete_memory, replace_memory_content, update_memory}，子代理内部禁用。

## 7. 前端工具 UI

- 输入框的「集成」菜单实现在 `MessageInput/IntegrationsMenu.svelte`，Tools tab 的切换在 149-162 行，工具开关列表在 376-494 行，列表中包含 MCP 未认证提示与 UserValves 配置；
- `workspace/Tools.svelte`：工作区工具管理页（上传/编辑/Valves）；
- `workspace/Models/ToolsSelector.svelte`：模型绑定工具选择器；
- 工具数据由 `getTools` 从 `GET /api/v1/tools/` 获取，请求封装在 src/lib/apis/tools/index.ts 68 行；
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
