# Hermes Agent Agent 工具调查笔记

> 调查对象：`E:\works\git\hermes-agent`
>
> 调查更新日期：2026-08-07
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：只读源码定位目录构建、工具执行链、审批与回注路径；结合仓库 AGENTS.md 与工具 docstring 核验设计意图
>
> 调查范围：覆盖本地仓库 `hermes-agent` 的 Agent 工具全链路（核心工具、插件、MCP、导出工具集、execute_code 沙箱 RPC），主题为工具输入输出两侧全校验与调试点；首次调查，正文为静态代码阅读结论
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes 是一个聚合多种工具来源的 Agent 核心，其工具面由多层来源组成：仓库自带 `tools/` 目录的自动导入注册、`plugins/` 目录的插件工具、MCP 客户端动态发现工具、`skills/`+`optional-skills/` 的指令文本工具，以及 `toolsets.py` 的按平台工具集装配。

整个工具链沿 `run_agent.py` → `model_tools.py` → `tools/registry.py` 三层组织，工具的定义、发现、审批、执行和回注均发生在 Python 主进程内。

核心执行链路为：

```text
AIAgent.run_conversation(conversation_loop.py:1233)
  → API 请求组装（chat_completion_helpers.build_api_kwargs）
  → 模型返回 assistant.tool_calls
  → 工具名/JSON 校验（conversation_loop.py: 5960-6320）
  → agent._execute_tool_calls（run_agent.py: 7589，单/并发/分段三路）
  → agent._invoke_tool（run_agent.py: 7665 → agent_runtime_helpers.invoke_tool: 2803）
  → tool_request middleware → pre_tool_call 审批门 → registry.dispatch
  → 结果回注（tool 消息）→ 继续循环
```

### 关键结论

1. **工具注册集中在 `tools/registry.py`**，所有普通工具文件在 import 时 `registry.register()`；agent-level 工具（`todo`/`memory`/`session_search`/`delegate_task`）由 `_AGENT_LOOP_TOOLS`（model_tools.py: 680）与执行框架特判拦截，不进入 registry 分发。新建内建工具仍遵守仓库 AGENTS.md 的约定：工具文件负责 `registry.register()`，还要在 `toolsets.py` 的工具集里显式启用，否则会出现“注册成功但不可发现”或“可发现但调用失败”的不一致。

2. **工具参数校验的收敛点**：模型回吐的 JSON 工具参数先经 `handle_function_call` 里的 `_sanitize_tool_error`/`tool_error` 统一输出错误 JSON；并行路径在 `tool_executor._parse_tool_arguments` 处先把非 JSON_object 参数判定为 `Invalid tool arguments`。参数类型校验依赖 `coerce_tool_args` 与 `_normalize_json_strings_for_schema`（string→number/bool 转换），不存在独立的“schema 强制校验器”。`enabled_tools` / `enabled_toolsets` 过滤只发生在 `get_tool_definitions`（发现阶段），注册表 `dispatch` 不按会话复验工具名归属，子代理/delegate 路径的工具集归属依赖各 agent 实例的 `valid_tool_names`（未完全证实，见未验证事项）。

3. **“前端确认框”不等于执行端鉴权。** CLI 交互审批（`prompt_dangerous_approval`）只是 `check_dangerous_command` 的一环，且 `HERMES_YOLO_MODE` 冻结或会话 yolo 开启时整个审批门可被跳过（approval.py: 3290-3291）。真正的执行端是 `tools/registry.py: dispatch`，其 handler 只收到校验过的参数，不重新核对审批标记。另：`execute_code` 沙箱的 `_rpc_server_loop`（code_execution_tool.py: 649）直接调用 `model_tools.handle_function_call` 执行已授权子工具（allow-list 由 `enabled_tools`/`_last_resolved_tool_names` 提供，执行危险命令不另走审批门），是一条独立于编排层的工具调用旁路（详见第 8 节）。

4. **结果回注**：`tool_result_storage.py` 维护三层持久化预算（per-tool 上限、per-turn 聚合预算、preview），超出上限的结果落盘到沙箱临时目录并用 preview + 文件引用回填；大小限制只控制上下文膨胀，不构成输出内容过滤。未发现与“工具输出无过滤”相对的输出侧信任标记。

执行边界：同库携带 `tools/environments/`（local/ssh/docker/modal/daytona/singularity/vercel_sandbox 等后端），容器类有 `container_cpu/memory/disk` 配置上限，本地执行无强制 sandbox。

### 总体调用链

顶层入口 `agent/conversation_loop.py: run_conversation`（1233）接受 `stream_callback`、`persist_user_message`、`moa_config` 等参数。循环局部状态（1353 起）包括 `max_compression_attempts=3`、`_pending_verification_response`、`_pending_verification_response_previewed`（#65919）。循环条件为 `api_call_count < max_iterations and iteration_budget.remaining > 0`，外加 `_budget_grace_call` 一次宽限。

- **API 请求组装**：`run_agent._build_api_kwargs`（6990）→ `agent.chat_completion_helpers.build_api_kwargs`，把 `agent.tools` attach 到 `tools=`。
- **返回校验**：对每个 `assistant_message.tool_calls`：id 去重（`_uniquify_tool_call_ids`）；name 不在 `agent.valid_tool_names` 时 `_repair_tool_call` 近似修复；JSON 解析失败进入 `_invalid_json_retries < 3` 重试，超限则注入 recovery 工具结果并追加 `recovery_assistant` 消息保持角色交替。
- **执行**：`agent._execute_tool_calls`（run_agent.py: 7589）按 model 返回的 tool_calls 数量分级：≤1 直接 sequential；多工具先 `_plan_tool_batch_segments` 分成“平行安全段 + 顺序障碍”，可并发段走 `execute_tool_calls_concurrent`。
- **回注**：`tool_dispatch_helpers.make_tool_result_message` 生成 `role=tool` 消息；`maybe_persist_tool_result` 决定是否落盘；之后回到压缩检查。
- **终止**：`max_iterations` 上限；`iteration_budget` 耗尽触发强制压缩/退出；`/stop` 或新消息在并发等待循环中被轮询落地。

## 2. 工具定义、来源与注册

### 注册表（`tools/registry.py`）

- `ToolEntry` 存 `name/toolset/schema/handler/check_fn/requires_env/is_async/description/emoji/max_result_size_chars/dynamic_schema_overrides`（line 160-189）。schema 是 `{"type": "function", "function": {...}}` 的 Python dict，不含执行对象。
- `register()`（521）在**模块 import 时**被各工具调用（仓库 AGENTS.md 明确“类型/注册/装配三处”）。跨 toolset 同名的二次注册默认 rejected（除非 `override=True`）；插件覆盖内建需要 `plugins.entries.<id>.allow_tool_override: true`.
- `deregister()`（605）校验“插件只能删自己拥有的工具”，MCP 工具（`mcp-*`）豁免——MCP 更新工具列表时 nuke-and-repave 合法。
- `get_definitions(names)`（676）**静态快照**：同时过滤 `check_fn` 缓存（30s TTL）、动态 schema override、别名。`get_max_result_size`（796）返回 per-tool 上限，缺省则 `DEFAULT_RESULT_SIZE_CHARS`。
- `dispatch(name, args)`（760）是唯一真正执行 handler 的入口，统一 `_run_async` 桥接与 `_normalize_handler_result` 结果契约。

函数级组件（model_tools.py）：

- `_AGENT_LOOP_TOOLS = {"todo","memory","session_search","delegate_task"}`（680）在 `handle_function_call` 直接短路返回错误，必须由 `run_conversation` 内联执行。
- `get_tool_definitions`（305）返回 openai 格式数组；`_last_resolved_tool_names`（进程级 list，561-562）记录 name 供 execute_code 沙箱 allow-list 备份。
- `sanitize_tool_schemas`（tools/schema_sanitizer.py: 120）；
- `handle_function_call`（1123）规定统一入口：先 `coerce_tool_args` 类型洗边缘，再 tool_request middleware → pre_tool_call 审批门 → execute_code 旁路 → `registry.dispatch`，最终 `tool_error(...)` 固定错误外壳。

## 3. 工具发现、过滤与注入

核心 `get_tool_definitions()`（model_tools.py: 305）签名：

```python
def get_tool_definitions(
    enabled_toolsets=None, disabled_toolsets=None,
    quiet_mode=False, skip_tool_search_assembly=False,
) -> list[dict]:
```

顺序：

1. 白/黑名单 toolset 过滤；browser_navigate 描述裁剪（541-552）。
2. `_tool_defs_cache`：按 `(enabled, disabled, quiet, skip_ts)` 元组指纹缓存，上限 `_TOOL_DEFS_CACHE_MAX=8`（issue #19251）；超过 8 组组合会逐步清空旧条目。`_clear_tool_defs_cache()` 在动态依赖变化时被调用。
3. 生成 `tools`，最后更新进程级 `_last_resolved_tool_names = [n.name]`。
4. 覆盖清理 `sanitize_tool_schemas`（tools/schema_sanitizer.py: 120）：剔除不适用的参数字段（如远端模型无法消费的执行后端开关），避免 schema 与执行端不符。
5. **注入形态**：全量 tools 数组随每次 API 调用发送。Hermes 的 prompt caching 只缓存 system prompt 前缀（不缓存 tools 数组），仓库文档明确“每个模型工具的 schema 都随每次 API 调用发送”，这是工具集保持小而窄的设计原因。

可用性过滤：

- `registry.get_definitions` 对每个 tool 调用 `_check_fn_cached(check_fn)`（TTL 30s，吸收探针抖动，失败短暂窗口内沿用上次成功结果）。同轮 per-call 缓存避免重复 probe。
- `dynamic_schema_overrides`（如 delegate_task 描述随 `delegation.max_concurrent_children` 变化）运行时改写 schema；缓存键依赖 config mtime+size，改动自动失效。
- 工具输出预算：`tools/budget_config.py` 为每工具 result 提供 pin 层（`PINNED_THRESHOLDS={"read_file": inf}`）、per-tool override、registry 值三层；`DEFAULT_RESULT_SIZE_CHARS=100_000`、`DEFAULT_TURN_BUDGET_CHARS=200_000`、`DEFAULT_PREVIEW_SIZE_CHARS=1_500`。

## 4. 模型调用表示与 Provider 适配

`get_tool_definitions()` 输出已含 `{"type":"function", ...}` 数组，`build_api_kwargs` 直接挂 `tools=`（OpenAI 兼容）。Provider 适配分布在 `agent/transports/chat_completions.py`（原生 tool_calls）、`agent/anthropic_adapter.py`（tool_use / 结果重建）、`agent/codex_responses_adapter.py`、`agent/bedrock_adapter.py` 与 `agent/auxiliary_client.py`（session_search 等旁路 side-LLM 工件）。`_supports_reasoning_extra_body`（run_agent.py: 6994）按宿主/供应商判定 `reasoning_effort` 附加字段：Nous Portal、ai-gateway.vercel.sh、GitHub models（经 `github_model_reasoning_efforts`）、LM Studio（仅 off）、Ollama Cloud（/api/show 能力探测）。

`agent/auxiliary_client.py` 是独立的 side-LLM 胶水（session_search、title 等旁路任务），不参与主工具循环。

## 5. 编排循环、并发与终止条件

循环耦合 tool-call 校验（conversation_loop.py: 5960-6320）：

1. **id 去重**：`_uniquify_tool_call_ids`。
2. **name 校验**：不在 `agent.valid_tool_names` → `_repair_tool_call`（近似修复）；无法修复进 `invalid_tool_calls`。
3. **JSON 修复**：`json.loads` 失败重试 ≤3 次（`_invalid_json_retries`）；超限注入 recovery 工具结果。
4. 混合批处理（tool_calls + 文本）：工具调用与文本回复并存时按段处理。
5. `agent._tool_guardrails`（`ToolCallGuardrailController`）在每工具执行后检查结果，`_append_guardrail_observation` 追加护栏观测。

### 并发执行

- `execute_tool_calls_concurrent`（tool_executor.py: 686）用 `DaemonThreadPoolExecutor`，`max_workers=_max_workers_for_tool_batch`（默认 `_MAX_TOOL_WORKERS=8`；image_generate 时 4）。
- 顺序门 `ConcurrentToolAuthorizationGate` 把放行（含 `resolve_pre_tool_block` 审批回调）串行化到“开始序”位置：每次只允许按提交序的下一个 worker 放行，避免审批与副作用顺序错乱；`_start_order_gate_timeout`（默认 120s）防卡死。批若被 abandon，排队的 worker 被唤醒并退出，不会执行已算作超时/取消的工具。
- 批超时 `HERMES_CONCURRENT_TOOL_TIMEOUT_S` 环境变量可覆盖（默认 420s），到期取消未启动 future、`_abandon_batch()` 释放 gate workers。
- 中断：`agent._interrupt_requested` 时 `f.cancel()` + 等 3s 优雅退出；worker 注册到 `agent._tool_worker_threads` 供 interrupt 逐线程 `_set_interrupt(True, tid)`。中断/超时后不再写 `results[index]`（防重复上报 tool_call）。
- worker 退出时必须清理 `_tool_worker_threads` 中的 tid 并复位中断位，避免复用线程带脏状态。

### 顺序路径

`execute_tool_calls_sequential` 特判 `session_search`、memory 工具，其余同样通过 `_run_agent_tool_execution_middleware`。每工具校验消息按顺序命名。

## 6. 审批、授权与执行边界

### 审批（tools/approval.py）

- `prompt_dangerous_approval`（2561）：CLI 交互，`once/session/always/deny/timeout` 五选一，`allow_permanent` 控制是否显示 `[a]lways` 选项；`approval_callback` 由 CLI 注册（`terminal_tool.set_approval_callback`）。
- `check_dangerous_command`（3248）：终端执行前总入口；先查容器/host 跳过条件（`_should_skip_container_guards`，仅 `has_host_access=False` 生效）；yolo 模式跳过；allowlist 直接放行；危险 pattern 命中则进 `_run_approval_gate`。
- `request_tool_approval`（3318）：插件 `action: approve` 的路由；`rule_key` 粒度、`[a]lways` 允许清单基于 `tool+reason` 哈希隔离。
- fail-closed：无交互用户、非网关、无 callback、超时，全部 deny（`fail_closed_when_no_human=True`）。cron 走 `approvals.cron_mode` 配置。
- 免审批路径：`HERMES_YOLO_MODE` 冻结（启动参数）；gateway /yolo 会话级开关；tirith 扫描告警时禁止 `always` 宽授（`allow_permanent=False`）。

### 执行边界

```text
execute_code 内部工具 → _rpc_server_loop（父进程线程）→ model_tools.handle_function_call
  → tool_error/registry.dispatch → role 返回
```

- `execute_code` 复用 terminal 环境（`_get_or_create_env`），任务级容器/目录隔离；RPC server 运行在**父进程线程**，sandbox 脚本每次需要工具时用新行 JSON 请求；`terminal` 调用会剥离 `background/pty/notify_on_complete/watch_patterns` 参数。
- allow-list= `enabled_tools`（若传入）否则 `_last_resolved_tool_names`；所以“模型可用的工具”与“execute_code 沙箱可调用的工具”一致，但**它绕过编排层的工具名校验与审批链**（只受 allow-list 限制，不重复审批）。

### 执行位置

```text
CLI/主进程执行所有工具；execute_code 的 code 在沙箱（本机=临时目录+子进程，容器/远程=环境容器）
```

- 本机 `local` backend 裸执行代码，无 sandbox 强制。
- Docker/Modal/Daytona/Singularity/Vercel Sandbox 提供定义了资源的容器环境。
- `tools/environments/` 的容器资源上限为 `container_cpu/container_memory/container_disk` 等 config 字段。

## 7. 结果回注与 UI 状态

- `make_tool_result_message` 生成 `role=tool` 消息；`maybe_persist_tool_result` 按 `registry.get_max_result_size` 决定落盘；preview `<persisted-output>` 标记写临时目录，模型用 `read_file` 取全文。
- `enforce_turn_budget` 在聚合末尾把最大未持久化结果 spill，直到聚合 < `DEFAULT_TURN_BUDGET_CHARS`（200K）。
- 失败/错误使用 `tool_error` 外壳统一输出，`_detect_tool_failure` 识别错误状态入日志/UI。
- 无输出内容过滤层（结果中 prompt 注入可直通模型的 tools 触发面，同其余项目）。

## 8. MCP、插件、Skill 与子 Agent

### 插件

- `hermes_cli/plugins.py`: `discover_plugins()` 在 import `model_tools` 时副作用触发；`PluginManager` 从 `~/.hermes/plugins/`、`./.hermes/plugins/`、pip 入口发现。
- `ctx.register_tool`（413）同时把工具注册进全局 registry，并跟踪 `_plugin_tool_names`；`override=True` 需要信任门。
- hooks：`pre_tool_call`/`post_tool_call`/`pre_llm_call`/`post_llm_call`/`on_session_start/end`；`invoke_hook` / `has_hook`。
- `resolve_pre_tool_block`（2252）是**每个工具分发点的单一安全入口**：对 `approve` action 调 `request_tool_approval`，任何错误 fail-closed；`block` 直接返回消息；其他 `proceed`。并发/顺序/分段路径都统一调用它，避免复制粘贴的安全错误。
- `plugins/platforms/` 适配网关 20+ 平台；`plugins/memory/` 与模型 Provider 插件是独立 discovery 机制（`_discover_providers` 懒扫描）。

### MCP（`tools/mcp_tool.py`）

- `register_mcp_servers(servers)` 把 config `mcp_servers` 的每个 server 注册为 toolset `mcp-<name>`；动态 `notifications/tools/list_changed` 触发 nuke-and-repave。
- include/exclude 过滤（fnmatch glob，include 优先），`_should_register` 检查后 `check_fn=_make_check_fn(name)`。
- 每工具 schema 通过 `_convert_mcp_schema`；不安全描述经 `_scan_mcp_description`（threat pattern）过滤。
- 传输 stdio/HTTP/SSE；`timeout/connect_timeout/keepalive_interval/idle_timeout_seconds/max_lifetime_seconds` 生命周期回收受支持。
- 每 server 可声明 `supports_parallel_tool_calls`。

### 技能

- 仓库自带 `skills/`（默认启用）+ `optional-skills/`（`hermes skills install`）；`SKILL.md` frontmatter metadata。
- `skills_tool.py`/`skills_hub.py`/`curator`：agent 可创建自定义技能，被 `curator` 自动归档（从不删除）。技能是文本指令而非权限沙箱。

### 子代理（`tools/delegate_tool.py`）

- `_subagent_auto_deny` 是默认；`delegation.subagent_auto_approve: true` 时改用 `_subagent_auto_approve`；threadlocal callback 通过 `_set_subagent_approval_cb` 注入。
- `_run_single_child`（1971）：保存/恢复 `model_tools._last_resolved_tool_names`（避免子代理污染父进程 global）；凭据池租借/移除；heartbeat 线程让父代理在 gateway 中不判死。
- 会话隔离：子代理 `session_key`/terminal独立；`inherit_mcp_toolsets` 子代理可选继承父 MCP 工具。

## 9. 设计取舍与已确认边界

- **prompt caching 前提**：tools 数组每次全量发送，system prompt 是唯一缓存前缀；因此工具集变更（插 plugin、切 toolset）通常是下一会话生效（`--now` 才强制立即生效）。这是与“core narrow”并存的设计。
- **override 门**：`allow_tool_override` 配置是内建工具被替换的唯一信任凭据（#23194）。
- **统一审批与分叉**：`resolve_pre_tool_block` 是统一网关，但 `execute_code` 沙箱的 `handle_function_call` 旁路跳过它——两条执行入口的覆盖不一。
- **统一错误外壳**：`tool_error(...)` 固定错误 JSON，全部 handler 必须返回 JSON 字符串；`_normalize_handler_result` 强制该契约。
- **容器风险豁免**：`_should_skip_container_guards` 仅在容器且 `has_host_access=False`（无 host 挂载）时跳过危险命令审批，本地执行无此豁免。
- **持久化在副作用前**：内存中的 assistant.tool_calls 块在所有工具副作用前写入 `session_db`（conversation_loop.py: 6320-6351），崩溃/重启后恢复仍看到该批次；工具期间 session_db 不可写时 `_turn_exit_reason="session_persistence_failed"` 中断。

## 未验证事项

- 子代理执行时其 `enabled_tools` 是否在 `dispatch` 执行阶段被逐次复验（当前静态代码显示过滤只在 `get_tool_definitions` 内做）。
- `_should_skip_container_guards` 与 `has_host_access`（docker bind-mount host 路径）的运行时关系。
- `DANGEROUS_PATTERNS`（docker/podman 远端 daemon 重定向 792-827 等）与实际检测集在 i18n 多语言下是否完整。
- `.env` 密钥工具（`set-credential`/自带）是否走审批。
- Anthropic/Bedrock/Codex adapter 对自定义 `tool_calls` 字段的处理细节。
- 结果持久化跨进程（gateway 长期会话）大结果恢复后再取回，`read_file` 的路径代理校正。

## 关键源码索引

- `run_agent.py`：`_execute_tool_calls`（7589）、`_invoke_tool`（7666）、`_supports_reasoning_extra_body`（6994）、`_build_api_kwargs`（6990）。
- `agent/agent_runtime_helpers.py`：`invoke_tool`（2803），统一工具入口转发。
- `model_tools.py`：`get_tool_definitions`（305）；`handle_function_call`（1123）；`_AGENT_LOOP_TOOLS`（680）；`coerce_tool_args`/`_normalize_json_strings_for_schema`（859）。
- `tools/registry.py`：`register`（521）、`get_definitions`（676）、`get_max_result_size`（796）、`dispatch`（760）、`deregister`（605）、`register_toolset_alias`（446）。
- `tools/budget_config.py`：三层持久化预算。
- `tools/tool_result_storage.py`：`maybe_persist_tool_result`/`enforce_turn_budget`。
- `tools/approval.py`：`prompt_dangerous_approval`（2561）、`check_dangerous_command`（3248）、`request_tool_approval`（3318）、dangerous patterns（~792-827）。
- `hermes_cli/plugins.py`：`register_tool`（413）、`discover_plugins`（2062）、`resolve_pre_tool_block`（2252）。
- `hermes_cli/middleware.py`：`apply_tool_request_middleware`/`run_tool_execution_middleware`。
- `agent/tool_executor.py`：`execute_tool_calls_concurrent`（686）、`_run_agent_tool_execution_middleware`（410）、`_begin_tool_execution`（593）。
- `agent/conversation_loop.py`：校验与恢复（5960-6320）、持久化（6320-6351）。
- `tools/delegate_tool.py`：`_run_single_child`（1971）、auto-approve/deny。
- `tools/mcp_tool.py`：`register_mcp_servers`（6221）、include/exclude 过滤（5839+）、`_make_check_fn`。
- `tools/code_execution_tool.py`：`_rpc_server_loop`（649）、`execute_code` 注册（2076）。
- `tools/terminal_tool.py`：`set_approval_callback`（280）、注册（3411）。