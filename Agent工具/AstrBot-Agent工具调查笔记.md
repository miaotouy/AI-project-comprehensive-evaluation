# AstrBot Agent 工具调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：工具定义与 schema、注册机制、运行时工具集构建、调用执行链路、结果回填、安全限制、内置工具、MCP、子 Agent 与 UI 层
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的 Agent 工具体系以「统一执行器 + 多来源注册」为核心：所有工具（内置、插件、MCP、子 Agent Handoff）最终都归一为 `FunctionTool` 对象，由 `FunctionToolExecutor.execute`（astr_agent_tool_exec.py:130-187）按类型分发执行，主 Agent runner `ToolLoopAgentRunner` 在循环中串行消费。工具系统横跨四个代码域：定义与 schema（`core/agent/tool.py`）、注册与生命周期（`core/provider/func_tool_manager.py` + `core/tools/registry.py`）、执行分发（`core/astr_agent_tool_exec.py`）、运行循环（`core/agent/runners/tool_loop_agent_runner.py`）。

关键事实（快照 a9bb8a6）：

- **三类协议 schema 由同一 `ToolSet` 导出**：`openai_schema()`（tool.py:203-218）、`anthropic_schema()`（:220-232）、`google_schema()`（:234-330），后者含 90 行递归转换器，处理 JSON Schema → Gemini 格式的兼容细节（list 类型、`additionalProperties` 删除、array 缺省 `items` 回退等）。
- **四路注册汇合**：内置工具（`@builtin_tool` 装饰器，registry.py:232-254）、插件工具（star_handler.py:670-724 的 `add_func`/`spec_to_func`）、MCP 工具（`mcp_server.json` → `init_mcp_clients`，func_tool_manager.py:540-642）、子 Agent（`HandoffTool`，handoff.py:8-64）。
- **同名工具去重规则为「active 优先、同状态后覆盖」**：`ToolSet.add_tool`（tool.py:91-108），`get_func` 反向扫描配合（func_tool_manager.py:399-417）。
- **执行串行无并行**：`_handle_function_tools`（tool_loop_agent_runner.py:1089-1355）对同一响应中的多个 tool_call 用 `zip` 顺序 for + 逐个 await（:1108-1112）。
- **工具返回 None = 结束 Agent**：`_execute_local` 中工具直接给用户发消息后 yield None（astr_agent_tool_exec.py:680-697），runner 收到 None 转 `AgentState.DONE`（tool_loop_agent_runner.py:1283-1298）。
- **安全分层**：非内置工具经 `_PermissionGuardedTool` 透明代理按 `tool_permissions`（SharedPreferences `_default` 键）查权限（func_tool_manager.py:214-285；`_check_tool_permission` 异步化，:460-494，经 `sp.global_get` 读取 :472），默认 member 不限制；内置敏感工具在自身实现内硬编码检查。
- **五种产物级防护**：工具超时（`asyncio.wait_for`）、结果 token 溢出落盘（>27.5k tokens 写文件，tool_loop_agent_runner.py:110-111、369-441）、重复调用提示守卫（同工具同参连续 ≥3 次注入系统提示，:146-175、723-748）、`MAX_STEPS` 截断（:1060-1088）、`skills_like` 双段 requery（:289-307、1395-1469）。
- **内置工具 5 组约 26 个 + shipyard_neo 14 个**，每组带 config 规则（`BuiltinToolConfigRule`），但**规则只驱动 WebUI 展示"可用状态"，不参与运行时注入**（唯一消费方 tools_service.py:533-569）。
- **MCP 生命周期自管理**：启动并行初始化（并发 task + `asyncio.gather`）、连接超时/启用超时双环境变量、幂等启动、同任务内清理（#9068 修复）、ModelScope 云端同步；**工具名对 LLM 侧清洗**（`[^A-Za-z0-9_-]+`→`_`），原名保留用于实际 MCP 调用（mcp_client.py:800-808，#9534）。
- **停止即取消**：`_await_or_stop`（tool_loop_agent_runner.py:461-501）把进行中的 LLM 请求/上下文压缩与 abort 信号竞速，停止请求立即取消等待而不再等其自然返回；中断回填从长提示改为 user「Stop output.」+ assistant「Output stopped.」消息对（:116-117、1483-1516，#9602）。

## 总体调用链

```text
用户消息 → astr_main_agent.run_agent (astr_agent_run_util.py:115)
  → 构建 ProviderRequest + ToolSet（各 _apply_* 分支：_apply_kb / _apply_web_search_tools / persona 等）
  → ToolLoopAgentRunner.reset（携带 tool_schema_mode，默认 "full"）
  → step() 循环：
      provider.text_chat(func_tool=ToolSet)  → LLMResponse.tools_call_*
      → _handle_function_tools（tool_loop_agent_runner.py:1089-1355）
          for 每个 tool_call（串行）：
            查工具（skills_like 模式查 raw set，否则查 req.func_tool）
            参数过滤（仅传 parameters.properties 声明过的键，:1162-1188）
            on_tool_start hook → FunctionToolExecutor.execute 分发：
              HandoffTool → _execute_handoff[_background]
              MCPTool     → _execute_mcp
              is_background_task → asyncio.create_task + 立即返回 task_id
              其他       → _execute_local（handler / call / run 三选一）
            → _iter_tool_executor_results（abort 信号可中断，:1526-1568）
            结果处理：TextContent 拼接 / ImageContent 缓存 / 大结果落盘
            → tool 消息 + tool_call 消息回填 run_context.messages
      → 再次请求 LLM，直到无 tool_call 或工具返回 None
  → step_until_done(max_step) 强制截断（:1060-1088）
```

## 1. 工具定义模型

### 1.1 三个核心类（tool.py）

| 类 | 行号 | 职责 |
|---|---|---|
| `ToolSchema` | tool.py:19-37 | 工具名 + 描述 + 参数（JSON Schema），`model_validator` 用 `jsonschema` 校验 parameters 是否符合 Draft 2020-12 元 schema（:32-37） |
| `FunctionTool` | tool.py:40-74 | 可调用工具：`handler`、`handler_module_path`（为保留 handler 模块路径防止 partial 包装后丢失，:50-55）、`active`（AstrBot 特有字段，:56-60）、`is_background_task`（:61-65）；`call()` 默认抛 `NotImplementedError`（:70-74） |
| `ToolSet` | tool.py:77-366 | 运行时工具集容器：`add_tool`/`remove_tool`/`get_tool`/`merge` + 三种协议 schema 导出 + 两个派生视图 |

### 1.2 ToolSet 去重规则（add_tool，tool.py:91-108）

- 同名冲突时：`new_active or not existing_active` 才覆盖（:105）；
- 即**新工具 active 或旧工具 inactive** → 覆盖；否则保留旧的；
- 结果语义：后加载的 inactive 工具不会覆盖已激活工具；MCP 工具（active 默认 True）可覆盖被禁用的内置工具。

### 1.3 派生工具集（供 LLM 消费）

| 方法 | 行号 | 内容 |
|---|---|---|
| `get_light_tool_set()` | :121-139 | 仅 name/description，parameters 置空 object，跳过 inactive |
| `get_param_only_tool_set()` | :141-160 | 仅 name/parameters，description 清空 |
| `openai_schema()` | :203-218 | `{"type":"function","function":{...}}`，`omit_empty_parameter_field` 控制空参数是否省略 |
| `anthropic_schema()` | :220-232 | `name` + `input_schema{type,properties,required}` |
| `google_schema()` | :234-330 | `function_declarations`；`convert_schema` 递归：list 类型取首个非 null（:266-267）、不支持的 type → `"null"`（:277）、删 `default`/`additionalProperties`（:296-300，引用 #5217）、array 无 items 时回退 `{"type":"string"}`（:306-314） |

### 1.4 schema 校验

- 工具注册时参数 schema 即被 `jsonschema.validate` 校验（tool.py:32-37），非法 schema 在构造时抛错——**注册期失败而非运行期失败**。
- `spec_to_func`（func_tool_manager.py:343-363）把插件声明的 `[{type,name,description}]` 列表转成 `{type:"object", properties}` 结构（`type` 硬编码 object，:351）。

## 2. 注册机制（四路汇合）

### 2.1 四路来源

| 来源 | 声明/入口 | 落点容器 | 特征 |
|---|---|---|---|
| 内置工具 | `astrbot/core/tools/` 五模块 `@builtin_tool` | `builtin_func_list`（func_tool_manager.py:292，按类惰性实例化缓存） | 类定义即注册；`get_builtin_tool` 缓存实例（:419-441） |
| 插件工具 | star 插件 `@tool` 装饰器 → `star_handler.py:670-724` | `func_list`（func_tool_manager.py:290） | `add_func`（:365-390，先 `remove_func` 同名再追加）或 `spec_to_func`（:678） |
| MCP 工具 | `data/mcp_server.json` → `init_mcp_clients`（:540-642） | `func_list`（`MCPTool` 包装，:698-710；构造时把工具名清洗为 `[A-Za-z0-9_-]` 供 LLM 侧使用，原名保留于 `mcp_tool.name` 供实际调用，mcp_client.py:800-808） | 启动时并行初始化；重连时先清除同名 MCPTool（:701-703） |
| 子 Agent | `HandoffTool(agent=...)`（handoff.py:8-64） | `func_list` | 名字 `transfer_to_{agent.name}`（handoff.py:26），star_handler.py:724 追加 |

### 2.2 `builtin_tool` 装饰器与 config 规则（registry.py）

- `_resolve_builtin_tool_name`（:201-213）：取类属性 `name`，否则取 dataclass 字段默认值，否则 `ValueError`；
- 同名冲突抛 `ValueError`（:239-244）；
- `config` 参数（可选）构建 `BuiltinToolConfigRule` 写入 `_BUILTIN_TOOL_CONFIG_RULES`（:248-249）；
- 规则算子四种：`equals` / `in` / `truthy` / `custom`（`BuiltinToolConfigCondition.evaluate`，:33-57），点路径取配置值（`_get_config_value`，:71-77）；
- 特殊规则 `_evaluate_send_message_tool`（:121-181）：遍历 platform 配置，wecom/weixin_official_account 不支持主动消息，wecom_ai_bot 需 `msg_push_webhook_url` 非空；
- `ensure_builtin_tools_loaded`（:257-265）惰性 import 五模块（:12-18）；
- 消费方仅 WebUI：`get_builtin_tool_config_statuses`（:288-321）/`get_builtin_tool_config_tags`（:324-332）。

### 2.3 工具启停持久化（func_tool_manager.py:986-1043）

- `deactivate_llm_tool`（:986-1013）：置 `active=False` + 写入 SharedPreferences `inactivated_llm_tools`；
- `activate_llm_tool`（:1016-1043）：若工具属插件且插件未激活则抛 `ValueError`（:1020-1023），置 active 并移除黑名单；
- 插件侧 API：`star/context.py:372-383`（`activate_llm_tool`/`deactivate_llm_tool`），`register_llm_tool`（:718）。

## 3. 运行时工具集构建

### 3.1 get_full_tool_set（func_tool_manager.py:496-515）

- 新建空 `ToolSet`，把 `func_list` 中每个非内置工具用 `_PermissionGuardedTool` 包装后 `add_tool`；
- 注释明示：包装使每次调用都先过权限检查；**内置工具不包装**（保留自身硬编码权限逻辑，:214-226）。

### 3.2 按调用点裁剪（astr_main_agent.py 各分支）

| 分支 | 行号 | 行为 |
|---|---|---|
| `_apply_kb` | :278-320 | 知识库启用时 `ToolSet()` 重建，只放检索工具（:304） |
| `_ensure_persona_and_skills` | :580-592 | persona 未指定 tools 时 `tmgr.get_full_tool_set()` 全量（:580、:592） |
| `_apply_web_search_tools` | :1231-1264 | 按 `web_search` 开关决定是否注入搜索工具集（:1244） |
| 其他 `req.func_tool = ToolSet()` 点 | :433、:636、:1068、:1131、:1226、:1600、:1615 | 按各能力开关重建工具集 |

- 运行中代理：`ToolSet` 经 `ProviderRequest.func_tool`（entities.py:102）传给适配器；openai_source.py:538-546、anthropic_source.py:501-506 转协议格式；模型不支持 function calling 时自动去 tools 重试（openai_source.py:1158-1176）。

### 3.3 skills_like 模式（tool_loop_agent_runner.py:289-307）

- `tool_schema_mode` 两档：`"full"`（默认，完整 schema）、`"skills_like"`（LLM 首轮只见 name/description 的 light schema，省 token，引用 #4681）；
- skills_like 下：`req.func_tool` 被替换为 light_set（:307），另存 `_skill_like_raw_tool_set`（原集，:303）与 `_tool_schema_param_set`（param-only 集，:305）；
- 执行时工具解析走 raw set（:1137-1147）；第二轮以 param-only schema requery 参数（`_resolve_tool_exec`，:1395-1469，含失败后更强指令重试 `SKILLS_LIKE_REQUERY_REPAIR_INSTRUCTION` :136-144）。

## 4. 工具执行链路

### 4.1 执行器抽象与分发（astr_agent_tool_exec.py:130-187）

- `BaseFunctionToolExecutor.execute` 仅 17 行抽象（tool_executor.py:10-17）；
- `FunctionToolExecutor.execute` 按 `isinstance` 分四路：
  1. `HandoffTool` → 检查 `background_task` 参数，`_execute_handoff_background`（:379-420）或 `_execute_handoff`（:304-377）；
  2. `MCPTool` → `_execute_mcp`（:705-715，直接 `tool.call`）；
  3. `tool.is_background_task` → `asyncio.create_task` 后台跑 + 立即 yield `CallToolResult` 含 task_id（:159-183）；
  4. 其他 → `_execute_local`（:621-703）。

### 4.2 _execute_local 细节（:621-703）

- 方法解析三选一（:634-656）：`handler`（decorator_handler）→ 类 MRO 中重写了 `call`（:634-638 的 MRO 检查）→ `run`；都没有则抛 `ValueError`；
- `call_local_llm_tool`（:718-812）统一包装：`run`/`decorator_handler` 传 `(event, *args)`，`call` 传 `(context, *args)`（:737-740）；
- 返回类型分支（:784-812）：asyncgen 逐步 yield（`MessageEventResult` 写入 `event.set_result` 再 yield None 占位）；协程直接 await；
- 参数不匹配时 `inspect.signature` 提取签名生成友好错误（:745-776）；
- 超时：`asyncio.wait_for(anext(wrapper), timeout)`（:664-668），默认 `run_context.tool_call_timeout`，后台任务用 3600s（:481）；
- **yield None 分支**（:679-697）：工具无返回值时把 `event.get_result()` 的 chain 以 `tool_direct_result` 类型直接发送给用户，再 yield None 通知 runner 结束。

### 4.3 runner 侧消费（tool_loop_agent_runner.py:1089-1355）

- 逐个工具：先 yield `tool_call` 消息链（:1118-1132，Json 含 id/name/args/ts），供 UI 展示；
- 未找到工具：yield `error: Tool X not found. Available tools are: ...`（:1154-1160）；
- **参数过滤**（:1162-1188）：有 handler 时只传 `parameters.properties` 声明过的键，多余键记 warning 忽略；无 handler（MCP 等）用全部参数；
- `on_tool_start` / `on_tool_end` hooks（:1190-1197、:1312-1320）；
- 结果处理（:1205-1310）：
  - `TextContent` → 文本拼接；
  - `ImageContent` → `tool_image_cache.save_image` 缓存（base64 落盘），给 LLM 的文本提示"Review the image below. Use send_message_to_user..."（:1221-1238）；
  - `EmbeddedResource`（Text/Blob）同规则，非图片资源回"不支持的数据类型"（:1239-1268）；
  - 大结果 `_materialize_large_tool_result`（:1271-1274）落盘；
  - `resp is None` → 转 `AgentState.DONE`（:1283-1298）；
- 异常兜底：任何执行异常以 `error: {e}` 作为 tool 结果回填（:1321-1331），`_ToolExecutionInterrupted` 特殊重抛；
- `_iter_tool_executor_results`（:1526-1568）：`asyncio.wait` 竞争 next_result 与 abort 信号，用户停止可中断工具执行；进行中的 LLM 请求/上下文压缩则由 `_await_or_stop`（:461-501）竞速 abort 信号立即取消（#9602）。

## 5. 工具结果处理与上下文回填

### 5.1 大结果落盘（:110-111、:369-441）

- `TOOL_RESULT_MAX_ESTIMATED_TOKENS = 27_500`、`TOOL_RESULT_PREVIEW_MAX_ESTIMATED_TOKENS = 7000`（:110-111）；
- `_materialize_large_tool_result`（:396-441）：估算 token 超限 → 预览截断到 7000 + 全文写入 `tool_result_overflow_dir`（文件名 = 净化后的 tool_call_id + uuid 后 8 位，:369-394），回填文本附 `TOOL_RESULT_OVERFLOW_NOTICE_TEMPLATE` 提示用读文件工具查看（:168-173）；
- 写盘用 `asyncio.to_thread`（:394）。

### 5.2 重复调用守卫（:144-175、:723-748）

- `_track_tool_call_streak`（:723）：同工具名 + 同参数连续调用计数；
- 阈值 3/4/5 三档，L1 温和提醒、L2 强调、L3 严正提醒，模板追加到 tool 结果尾部（:148-167）；
- 参数序列化比较：连续两次完全相同的工具+参数才累加。

### 5.3 回填与 UI 消息链

- 工具调用/结果以 `MessageChain(type="tool_call")` / `type="tool_call_result"`（Json 组件）yield 出去（:1118-1132、:1333-1348）；
- `astr_agent_run_util.py`：`_extract_chain_json_data`（:40）取链中首个 Json；`_truncate_tool_result`（:30）截 70 字符供 UI；`_merge_buffered_llm_chains`（:102）合并流式链；`run_agent`（:115）驱动循环；
- `append_tool_calls_result`（:1000）把 tool 结果消息追加进上下文，参与下一轮 LLM 请求与上下文压缩。

### 5.4 后台任务唤醒主 Agent（astr_agent_tool_exec.py:509-619）

- `_wake_main_agent_for_background_result`：构造 `CronMessageEvent`（:542-548）模拟主动事件，重建主 Agent（`build_main_agent`，:589），`step_until_done(30)` 跑完（:597）；
- 注入 `BACKGROUND_TASK_RESULT_WOKE_SYSTEM_PROMPT` + 强制要求用 `send_message_to_user` 交付结果（:572-582）；
- 结果经 `persist_agent_history` 写回对话历史（:611-616，utils/history_saver.py:9-27）。

## 6. 安全与限制

### 6.1 权限模型（func_tool_manager.py:214-285、453-494）

- `_PermissionGuardedTool`：透明代理，`handler` 刻意留 None（:233-234）使执行器走 `is_override_call` 分支调用 `call()`（:246-285），保证**所有调用路径**先过 `_check_tool_permission`；
- 权限读取：SharedPreferences `tool_permissions`（global scope）→ `_default` 键 → 工具名（:472-478，`await sp.global_get`）；默认 `_default_permission` = `"member"`（:453-458）即不限制；
- `admin` 要求：非 admin 事件返回错误字符串含发送者 ID 与提示（:485-496）；
- 内置工具不包装（:217-220），在各自实现内硬编码 `check_admin_permission` / `_is_restricted_env`。

### 6.2 工具级防护汇总

| 类别 | 实现 | 位置 |
|---|---|---|
| 执行超时 | `asyncio.wait_for`（默认 `tool_call_timeout`，后台 3600s） | astr_agent_tool_exec.py:664-701 |
| 结果大小 | 27.5k tokens 落盘 + 7k 预览 | tool_loop_agent_runner.py:110-111、369-441 |
| 重复调用 | 3/4/5 档提示注入 | :146-175、723-748 |
| 步数上限 | `MAX_STEPS`（max_agent_step 默认 30）+ `MAX_STEPS_REACHED_PROMPT` 拔工具强收尾 | :125、1060-1088 |
| 用户中断 | `request_stop()` → abort 信号；`_await_or_stop` 立即取消进行中的 LLM/压缩请求，执行器读取同步可中断 | :461-501、1471-1476、1526-1568 |
| 参数白名单 | 仅传声明过的参数键 | tool_loop_agent_runner.py:1162-1188 |
| 图像引用净化 | `is_supported_image_ref` 过滤非法 image_urls | astr_agent_tool_exec.py:101-128 |
| 插件权限链路 | 插件未激活时 `activate_llm_tool` 抛错 | func_tool_manager.py:1020-1023 |
| 后台任务隔离 | 独立 task + 独立主 Agent 实例 + 结果走 cron 事件 | astr_agent_tool_exec.py:509-619 |

### 6.3 已知边界（静态推断）

- 权限黑名单持久化与插件热重载之间无联动：插件停用时 `func_list` 由 star_manager 清理（star_manager.py:804-807、1916），但 `inactivated_llm_tools` 黑名单条目残留（仅名字，不清理）——重启后同名插件重新注册时黑名单仍生效；
- `_PermissionGuardedTool` 每次 `get_full_tool_set()` 都新建包装实例，无缓存；权限变更需下次构建工具集才生效；
- 内置工具实例按类缓存（`builtin_func_list`），插件运行期修改内置工具类定义不生效（需重启）。

## 7. 内置工具清单

### 7.1 五组（core/tools/）

| 模块 | 工具（name） | config 规则条件 | 行号 |
|---|---|---|---|
| web_search_tools.py | `web_search_baidu` `web_search_tavily` `tavily_extract_web_page` `web_search_bocha` `web_search_brave` `web_search_firecrawl` `firecrawl_extract_web_page` `web_search_exa` `exa_get_contents`（共 9 个，:16-26） | `provider_settings.web_search` + 对应 `websearch_provider` 匹配（:27-50） | 类 :587-1253；`_KeyRotator` 多 key 轮换（:61-90） |
| message_tools.py | `send_message_to_user`（:81）`get_group_message_history`（:362） | send_message_to_user 用自定义 `_evaluate_send_message_tool`（registry.py:121-181）；历史记录上限 `group_message_history_max_cnt: 700` | :78-357、:357-560 |
| knowledge_base_tools.py | `astr_kb_search`（:93） | `provider_settings.kb` 相关（`_KNOWLEDGE_BASE_TOOL_CONFIG`） | :90- |
| cron_tools.py | `future_task`（:55，action: create/edit/delete/list，支持 cron 与一次性 run_at） | `provider_settings.proactive_capability.add_cron_tools`（:16-18） | :52- |
| computer_tools/ | 见下 | 各 runtime 条件 | — |

### 7.2 computer_tools/（按 runtime 分档）

| 工具 | name | 适用 runtime |
|---|---|---|
| `ExecuteShellTool` | `astrbot_execute_shell`（shell.py:62） | sandbox（booter 任意） |
| `PythonTool` | `astrbot_execute_ipython`（python.py:83） | sandbox |
| `LocalExecuteShellTool` | （继承 ExecuteShellTool，:183） | local |
| `ShellSessionTool` | `astrbot_shell_session`（shell.py:256） | local |
| `LocalPythonTool` | `astrbot_execute_python`（python.py:119） | local |
| `FileReadTool` / `FileWriteTool` / `FileEditTool` / `GrepTool` | `astrbot_file_read_tool` 等（fs.py:309、406、478、569） | sandbox + local |
| `FileUploadTool` / `FileDownloadTool` | `astrbot_upload_file` / `astrbot_download_file`（fs.py:805、871） | sandbox |
| `CuaScreenshotTool` / `CuaMouseClickTool` / `CuaKeyboardTypeTool` | `astrbot_cua_*`（cua.py:53、111、148） | sandbox + booter=cua |

- runtime 选择：`_get_runtime_computer_tools`（astr_agent_tool_exec.py:189-245）按 `provider_settings.computer_use_runtime`（默认 `"local"`，:257）与 sandbox booter 组装；sandbox 8 个 + cua 3 个；local 7 个。

### 7.3 shipyard_neo（computer_tools/shipyard_neo/，14 个）

- 全部 `@builtin_tool(config=_SHIPYARD_NEO_TOOL_CONFIG)`：
  - browser.py：`BrowserExecTool`（:39）、`BrowserBatchExecTool`（:97）、`RunBrowserSkillTool`（:162）；
  - neo_skills.py：`GetExecutionHistoryTool`（:74）、`AnnotateExecutionTool`（:121）、`CreateSkillPayloadTool`（:159）、`GetSkillPayloadTool`（:207）、`CreateSkillCandidateTool`（:234）、`ListSkillCandidatesTool`（:288）、`EvaluateSkillCandidateTool`（:326）、`PromoteSkillCandidateTool`（:367）、`ListSkillReleasesTool`（:438）、`RollbackSkillReleaseTool`（:479）、`SyncSkillReleaseTool`（:506）；
- 属"技能流水线"管理类（执行历史、payload、候选、发布、回滚、同步）。

## 8. MCP 支持

### 8.1 配置与初始化（func_tool_manager.py:540-642）

- 配置文件 `data/mcp_server.json`，格式 `{"mcpServers": {name: {command/args 或 url, active}}}`；缺失时自动写默认空配置（:567-573）；
- `init_mcp_clients`：过滤 `active=False`（:581-585），每个服务一个 task（name=`mcp-init:{name}`）`asyncio.gather` 并行（:592-604），失败记录并弹运行时表（:619-620）；
- 双超时：`ASTRBOT_MCP_INIT_TIMEOUT`（初始化）与 `ASTRBOT_MCP_ENABLE_TIMEOUT`（动态启用），默认值 `_resolve_timeout` 解析（:91）；
- 全部失败时按 `raise_on_all_failed` 抛 `MCPAllServicesFailedError`（:637-641）；
- 日志脱敏：`_log_safe_mcp_debug_config` 只记录可执行文件名/主机名不记录 command/url 全文（:516）。

### 8.2 生命周期（:644-773+）

- `_start_mcp_server` 幂等：已运行/启动中则忽略（:657-664）；
- 连接 + `list_tools_and_save` 在同一任务内完成，工具注册为 `MCPTool` 进 `func_list`（:698-710），重连前先移除旧同名 MCPTool（:701-703）；
- **清理必须在同一任务**：`shutdown_event.wait()` 后 `_terminate_mcp_client`（:719-740），注释引用 #9068——`asyncio.shield` 跨任务退出 anyio cancel scope 会失败；取消吸收循环兼容 Py3.10 无 `uncancel`（:731-740）。

### 8.3 WebUI 管理（dashboard/services/tools_service.py）

- `get_mcp_servers`（:52-90）：读配置 + 运行时表（`mcp_server_runtime_view`）合并 connected/tools/errlogs；
- `add_mcp_server`（:106-120）校验格式（`validate_mcp_stdio_config`）；`rollback_mcp_server`（:41-50）配置失败回滚；
- 前端：`McpServersPage.vue` + `components/extension/McpServersSection.vue`；
- `sync_modelscope_mcp_servers`（func_tool_manager.py:1074-1143）：ModelScope OpenAPI 拉取操作中服务并合并本地配置。

## 9. 子 Agent（Handoff）

- `HandoffTool`（handoff.py:8-64）：`transfer_to_{agent.name}`；参数固定三件套 `input` / `image_urls` / `background_task`（:38-60）；
- 可选 `provider_id` 单独指定子 Agent 模型（:34，执行时优先于当前会话 provider，astr_agent_tool_exec.py:341-343）；
- `_build_handoff_toolset`（:247-302）：tools=None 时全量但**排除其他 HandoffTool**（防递归，:273-281）并追加 runtime 电脑工具；tools 列表按 `get_func` 逐个解析（:290-302）；
- 图片传递：`_collect_handoff_image_urls`（:101-128）合并参数与事件消息中的 `Image` 组件，`is_supported_image_ref` 净化（临时目录无扩展名文件特例）；
- 上下文：`begin_dialogs` 解析为 Message 列表（:346-358）；子 Agent 对话历史不持久化；
- 后台 handoff：立即返回 task_id + 完成后走 `_wake_main_agent_for_background_result` 唤醒主 Agent（:379-467）。

## 10. UI 层

| 界面 | 位置 | 内容 |
|---|---|---|
| 工具启停/权限表 | `dashboard/src/components/extension/componentPanel/components/ToolTable.vue` | 列：name/description/origin/origin_name/permission/actions（:18-25）；切换 `toggle-tool`、更新权限 `update-permission`（admin/member，:13-16）；内置工具显示 config tag 状态（`enabledConfigTags` :70-73）；权限颜色 admin=error/member=success（:75-80） |
| 工具配置条件展示 | ToolTable.vue :42-68 | 将 `BuiltinToolConfigCondition`（truthy/equals/in）渲染为人类可读条件文本 |
| 组件面板 | `componentPanel/index.vue` | 集成 ToolTable / CommandTable / DetailsDialog |
| MCP 服务管理 | `McpServersPage.vue` + `McpServersSection.vue` | 服务器 CRUD、连接状态、工具列表、错误日志 |
| 聊天工具调用卡片 | `components/chat/message_list_comps/ToolCallCard.vue`、`ToolCallItem.vue`、`IPythonToolBlock.vue` | 渲染 `tool_call`/`tool_call_result` 消息链；`IPythonToolBlock` 渲染 Python 执行结果 |
| 搜索工具结果折叠 | `MessageListDEPRECATED.vue:290-307` | 对 web_search_baidu/tavily/bocha/brave/firecrawl 折叠展示（DEPRECATED 组件） |
| 子 Agent / 定时任务 | `SubAgentPage.vue`、`CronJobPage.vue` | handoff 目标管理与 future_task 任务视图 |

## 11. 设计取舍与边界

### 11.1 已确认的设计（代码事实）

- **同一 ToolSet 三协议导出**：适配器零转换差异，Anthropic/Gemini 适配器直接消费 `anthropic_schema`/`google_schema`；
- **串行执行优先于吞吐**：避免平台并发与 LLM 竞态，代价是多工具任务延迟叠加；
- **执行器按类型分发而非注册表**：四路来源靠 `isinstance` 分流（astr_agent_tool_exec.py:142-187），新增来源需改分发点；
- **权限默认开放**：非内置工具 member 起步，admin 收紧（反向安全模型）；
- **工具失败不中断会话**：异常转 tool 结果回填 LLM，由模型决定下一步；
- **None 即结束**：工具直接回复用户后终止循环，主 Agent 不再追问；
- **双段 skills_like schema**：省 token 优先，参数第二轮补全，带修复重试；
- **结果物化分三级**：内联 → 预览+落盘 → 提示工具读取。

### 11.2 取舍（平衡决策）

- `_PermissionGuardedTool` handler 留 None 强制走 `call()` 与执行器 MRO 检查联动（func_tool_manager.py:221-226）——用隐式约定保证全路径权限检查，但依赖 `_execute_local` 的 `is_override_call` 探测逻辑（astr_agent_tool_exec.py:634-638）；
- 内置工具权限硬编码在实现内，与通用权限表双轨并存（不包装原因在注释中说明 :217-220）；
- `inactivated_llm_tools` 黑名单与 `active` 标志双写（func_tool_manager.py:986-1013），保证跨重启持久；
- MCP 重连先清同名工具（:701-703），保证热更新不累积重复声明；
- 后台任务用 `CronMessageEvent` 伪造事件驱动唤醒（:542-548），复用 cron 管道而非另建通道。

### 11.3 静态推断的潜在问题（未实测）

- **串行 + 后台分离不彻底**：`is_background_task` 工具在 `execute` 内 `create_task` 后立即返回 task_id，主循环照常结束——但若同一响应含多个 tool_call，后续工具仍串行等待，背景任务可能在主循环结束后才完成，结果依赖唤醒机制兜底；
- **权限检查只查 admin 两态**：`tool_permissions` 目前只有 admin/member 语义，无 per-user 白名单/黑名单维度；
- **`_collect_image_urls_from_args` 不递归**：嵌套结构中的图片 URL 不提取（astr_agent_tool_exec.py:57-74）；
- **超时只包单次 anext**：多次 yield 的工具每次独立计超时，总时长可超过 `tool_call_timeout` 的 N 倍；
- **`TOOL_RESULT_MAX_ESTIMATED_TOKENS` 用估计器**（`EstimateTokenCounter`，:247）：对中文/多字节文本可能低估。

## 12. 关键文件索引

- 工具定义：`astrbot/core/agent/tool.py`（ToolSchema :19-37 / FunctionTool :40-74 / ToolSet :77-366）、`tool_executor.py`（抽象执行器 :10-17）、`handoff.py`（:8-64）
- 注册与生命周期：`astrbot/core/tools/registry.py`（builtin_tool :232-254、config 规则 :26-198、状态计算 :288-332）、`astrbot/core/provider/func_tool_manager.py`（_PermissionGuardedTool :214-285、add/remove/get :365-417、get_full_tool_set :496-515、权限 :453-494、MCP :540-773、启停 :986-1045、ModelScope :1074-1143）
- 执行分发：`astrbot/core/astr_agent_tool_exec.py`（execute :130-187、_execute_local :621-703、call_local_llm_tool :718-812、handoff :304-467、后台唤醒 :509-619、runtime 电脑工具 :189-245）
- 主循环：`astrbot/core/agent/runners/tool_loop_agent_runner.py`（reset/skills_like :207-327、_await_or_stop :461-501、大结果 :396-460、_handle_function_tools :1089-1355、requery :1395-1469、中断读取 :1526-1568）
- 工具集裁剪：`astrbot/core/astr_main_agent.py`（_apply_kb :278、_ensure_persona_and_skills :580-592、_apply_web_search_tools :1231-1264）
- 内置工具：`astrbot/core/tools/`（web_search_tools / message_tools / knowledge_base_tools / cron_tools / computer_tools/）
- 插件工具入口：`astrbot/core/star/star_handler.py:670-724`、`star/context.py:372-383,718`
- MCP：`astrbot/core/agent/mcp_client.py`、`astrbot/dashboard/services/tools_service.py`（:36-120+）、`astrbot/dashboard/api/tools.py`
- UI：`dashboard/src/components/extension/componentPanel/components/ToolTable.vue`、`McpServersSection.vue`、`components/chat/message_list_comps/ToolCallCard.vue`、`IPythonToolBlock.vue`
- 文档：`docs/zh/use/function-calling.md`、`mcp.md`、`agent-runner.md`、`subagent.md`、`computer.md`、`context-compress.md`

## 13. 未验证事项

1. 未实测各工具在真实平台的执行结果（沙箱/本地 runtime、CUA、wecom 等平台差异）。
2. shipyard_neo 14 个工具的实际触发路径与 server 端行为未逐个核对。
3. 权限表在 WebUI 的完整读写链路（api/tools.py → ToolTable.vue）未逐行验证。
4. `mcp_server.json` 热更新（enable/disable 动态启停）运行时行为未实测。
5. 后台任务唤醒在并发多任务下的顺序与丢消息风险未实测。
