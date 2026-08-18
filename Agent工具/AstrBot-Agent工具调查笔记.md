# AstrBot Agent 工具调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
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

AstrBot 的 Agent 工具体系以「统一执行器 + 多来源注册」为核心：所有工具（内置、插件、MCP、子 Agent Handoff）最终都归一为 FunctionTool 对象，由其执行方法（astr_agent_tool_exec.py:130-187）按类型分发，主 Agent runner ToolLoopAgentRunner 在循环中串行消费。工具系统横跨四个代码域：定义与 schema、注册与生命周期、执行分发和运行循环，入口分别见 core/agent/tool.py、core/provider/func_tool_manager.py + core/tools/registry.py、core/astr_agent_tool_exec.py、core/agent/runners/tool_loop_agent_runner.py。

关键事实（快照 a9bb8a6）：

- **三类协议 schema 由同一 ToolSet 导出**：三个导出方法分别生成 OpenAI、Anthropic 和 Google 格式，位置为 tool.py:203-330。Google 格式包含递归转换器，处理 JSON Schema 到 Gemini 格式的兼容细节，如 list 类型、删除 additionalProperties、array 缺省 items 回退等。
- **四路注册汇合**：内置工具由 builtin_tool 装饰器注册（registry.py:232-254），插件工具从 star_handler.py:670-724 进入，MCP 工具由 mcp_server.json 配置并经初始化入口加入，子 Agent 则使用 HandoffTool（handoff.py:8-64）。
- **同名工具去重规则为「active 优先、同状态后覆盖」**：工具集的添加逻辑见 tool.py:91-108，查找时再由管理器反向扫描（func_tool_manager.py:399-417）。
- **执行串行无并行**：工具处理入口（tool_loop_agent_runner.py:1089-1355）对同一响应中的多个 tool_call 按顺序逐个等待执行（:1108-1112）。
- **工具返回 None = 结束 Agent**：本地执行器中，工具直接给用户发消息后返回空结果（astr_agent_tool_exec.py:680-697），runner 将其转换为完成状态（tool_loop_agent_runner.py:1283-1298）。
- **安全分层**：非内置工具经过权限代理，按 tool_permissions 的 SharedPreferences 默认键查权限（func_tool_manager.py:214-285、:460-494）；默认 member 不限制，内置敏感工具则在自身实现内检查。
- **五种产物级防护**：包括工具超时、结果 token 溢出落盘、重复调用提示、MAX_STEPS 截断和 skills_like 双段 requery，具体位置分别见 tool_loop_agent_runner.py:110-111、146-175、289-307、1060-1088、1395-1469。
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
| ToolSchema | tool.py:19-37 | 工具名、描述和参数（JSON Schema）；模型校验器用 jsonschema 校验 parameters 是否符合 Draft 2020-12 元 schema（:32-37） |
| FunctionTool | tool.py:40-74 | 可调用工具，保存 handler、模块路径、active 和后台任务标志；默认 call() 抛出 NotImplementedError（:50-74） |
| ToolSet | tool.py:77-366 | 运行时工具集容器，负责增删查改、合并、三种协议 schema 导出和两个派生视图 |

### 1.2 ToolSet 去重规则（add_tool，tool.py:91-108）

- 同名冲突时，只有新工具 active 或旧工具 inactive 才覆盖（:105）；
- 即**新工具 active 或旧工具 inactive** → 覆盖；否则保留旧的；
- 结果语义：后加载的 inactive 工具不会覆盖已激活工具；MCP 工具（active 默认 True）可覆盖被禁用的内置工具。

### 1.3 派生工具集（供 LLM 消费）

| 方法 | 行号 | 内容 |
|---|---|---|
| get_light_tool_set() | :121-139 | 仅保留 name/description，参数置空 object，跳过 inactive |
| get_param_only_tool_set() | :141-160 | 仅保留 name/parameters，清空 description |
| openai_schema() | :203-218 | 导出 function 结构，omit_empty_parameter_field 控制是否省略空参数 |
| anthropic_schema() | :220-232 | 导出 name 和 input_schema（含 type、properties、required） |
| google_schema() | :234-330 | 导出 function_declarations；递归转换器处理 list 类型、不支持的 type、default、additionalProperties 和缺失 items（:266-314） |

### 1.4 schema 校验

- 工具注册时参数 schema 即被 jsonschema.validate 校验（tool.py:32-37），非法 schema 在构造时抛错，属于注册期失败而非运行期失败。
- spec_to_func（func_tool_manager.py:343-363）把插件声明的参数列表转成 object 类型的 properties 结构，类型在 :351 硬编码为 object。

## 2. 注册机制（四路汇合）

### 2.1 四路来源

| 来源 | 声明/入口 | 落点容器 | 特征 |
|---|---|---|---|
| 内置工具 | astrbot/core/tools/ 五模块的 builtin_tool | builtin_func_list（func_tool_manager.py:292，按类惰性实例化缓存） | 类定义即注册，实例由 get_builtin_tool 缓存（:419-441） |
| 插件工具 | star 插件 tool 装饰器 → star_handler.py:670-724 | func_list（func_tool_manager.py:290） | 先移除同名项再追加，或由 spec_to_func 转换（:365-390、:678） |
| MCP 工具 | data/mcp_server.json → init_mcp_clients（func_tool_manager.py:540-642） | func_list 中的 MCPTool（:698-710） | 启动时并行初始化；供 LLM 使用的工具名清洗为 `[A-Za-z0-9_-]`，原名保留供实际调用（mcp_client.py:800-808）；重连时先清除同名项（:701-703） |
| 子 Agent | HandoffTool（handoff.py:8-64） | func_list | 名称按 transfer_to_{agent.name} 生成（handoff.py:26），由 star_handler.py:724 追加 |

### 2.2 `builtin_tool` 装饰器与 config 规则（registry.py）

- 装饰器先解析类属性 name 或 dataclass 字段默认值，均不存在时抛出 ValueError（:201-213）；同名冲突也抛出该异常（:239-244）。
- 可选的 config 参数构建配置规则并写入规则表（:248-249）；规则支持 equals、in、truthy、custom 四种算子和点路径取值（:33-77）。
- 发送消息工具有特殊规则：遍历 platform 配置，wecom/weixin_official_account 不支持主动消息，wecom_ai_bot 需要 msg_push_webhook_url 非空（:121-181）。
- 工具模块采用惰性导入（:257-265），配置规则目前只有 WebUI 消费（:288-332）。

### 2.3 工具启停持久化（func_tool_manager.py:986-1043）

- 停用工具会将 active 置为 false，并写入 SharedPreferences 的 inactivated_llm_tools；启用时若所属插件未激活则抛出 ValueError，再恢复 active 并移除黑名单（:986-1043）。
- 插件侧 API 位于 star/context.py:372-383 和 :718。

## 3. 运行时工具集构建

### 3.1 get_full_tool_set（func_tool_manager.py:496-515）

- 新建空 ToolSet，把 func_list 中每个非内置工具包装为权限代理后加入；包装确保每次调用先经过权限检查，内置工具不包装而保留自身权限逻辑（:214-226）。

### 3.2 按调用点裁剪（astr_main_agent.py 各分支）

| 分支 | 行号 | 行为 |
|---|---|---|
| `_apply_kb` | :278-320 | 知识库启用时 `ToolSet()` 重建，只放检索工具（:304） |
| `_ensure_persona_and_skills` | :580-592 | persona 未指定 tools 时 `tmgr.get_full_tool_set()` 全量（:580、:592） |
| `_apply_web_search_tools` | :1231-1264 | 按 `web_search` 开关决定是否注入搜索工具集（:1244） |
| 其他 `req.func_tool = ToolSet()` 点 | :433、:636、:1068、:1131、:1226、:1600、:1615 | 按各能力开关重建工具集 |

- 运行中的 ToolSet 经 ProviderRequest.func_tool（entities.py:102）传给适配器，由 OpenAI 和 Anthropic 适配器转成各自协议（openai_source.py:538-546、anthropic_source.py:501-506）；模型不支持 function calling 时自动去掉 tools 重试（openai_source.py:1158-1176）。

### 3.3 skills_like 模式（tool_loop_agent_runner.py:289-307）

- tool_schema_mode 有 full 和 skills_like 两档：前者默认发送完整 schema，后者首轮只发送名称和描述以节省 token（#4681）。
- skills_like 下，首轮请求使用 light_set，同时保存原工具集和只含参数的集合（:303-307）；执行解析走原集合（:1137-1147），第二轮再用参数集合补全参数，失败后按更强指令重试（:136-144、1395-1469）。

## 4. 工具执行链路

### 4.1 执行器抽象与分发（astr_agent_tool_exec.py:130-187）

- BaseFunctionToolExecutor.execute 是 17 行抽象接口（tool_executor.py:10-17）。
- FunctionToolExecutor.execute 按类型分四路：HandoffTool 根据 background_task 选择前台或后台 handoff（:304-420）；MCPTool 直接调用 MCP 工具；后台工具创建 task 后立即返回含 task_id 的结果；其他工具进入本地执行（:130-187、:621-715）。

### 4.2 _execute_local 细节（:621-703）

- 方法解析按 handler、类层级中重写的 call、run 三选一，都不存在时抛出 ValueError（:634-656）。统一包装时，run 和装饰器处理器接收 event，call 接收 context（:718-812）。
- 异步生成器逐步产出结果，消息事件结果会写入事件后以空值占位；普通协程直接等待完成（:784-812）。参数不匹配时从签名生成可读错误（:745-776）。
- 每次取结果都用 asyncio.wait_for 限时，默认使用 run_context.tool_call_timeout，后台任务为 3600 秒（:664-668、:481）。工具无返回值时直接把事件结果发送给用户，并以空值通知 runner 结束（:679-697）。

### 4.3 runner 侧消费（tool_loop_agent_runner.py:1089-1355）

- 逐个工具先产出 tool_call 消息链（:1118-1132，Json 含 id/name/args/ts）供 UI 展示；找不到工具时回填错误文本（:1154-1160）。
- **参数过滤**（:1162-1188）：有 handler 时只传参数 schema 声明过的键，多余键记录 warning 后忽略；无 handler 的工具（如 MCP）使用全部参数。
- 工具开始和结束时分别触发 on_tool_start、on_tool_end hook（:1190-1197、:1312-1320）；
- 结果处理将 TextContent 拼接为文本，ImageContent 通过图片缓存落盘并向 LLM 提示使用 send_message_to_user，EmbeddedResource 按同样规则处理非图片资源（:1205-1268）。大结果另行落盘；空响应转为 AgentState.DONE（:1271-1298）。
- 异常统一以错误文本回填，工具执行被中断的专用异常继续向上抛出（:1321-1331）。结果迭代同时等待下一个结果和 abort 信号，用户停止可中断工具执行；LLM 请求和上下文压缩也会立即取消（:461-501、1526-1568，#9602）。

## 5. 工具结果处理与上下文回填

### 5.1 大结果落盘（:110-111、:369-441）

- 结果估算上限为 27,500 tokens，预览上限为 7,000（:110-111）。超限时预览截断，全文写入 tool_result_overflow_dir，文件名由净化后的调用 ID 和 uuid 后八位组成，并在回填文本中提示使用读文件工具查看（:168-173、369-441）。
- 写盘通过 asyncio.to_thread 执行（:394）。

### 5.2 重复调用守卫（:144-175、:723-748）

- 重复调用按同工具名和同参数连续计数（:723）；
- 阈值 3/4/5 三档，L1 温和提醒、L2 强调、L3 严正提醒，模板追加到 tool 结果尾部（:148-167）；
- 只有连续两次工具和参数都完全相同才累加。

### 5.3 回填与 UI 消息链

- 工具调用和结果以 tool_call、tool_call_result 类型的 MessageChain（Json 组件）产出（:1118-1132、:1333-1348）。
- astr_agent_run_util.py 负责提取链中 Json、截短 UI 预览、合并流式链并驱动循环（:30、40、102、115）；工具结果随后追加进上下文，参与下一轮 LLM 请求和上下文压缩（:1000）。

### 5.4 后台任务唤醒主 Agent（astr_agent_tool_exec.py:509-619）

- 后台结果通过 CronMessageEvent 模拟主动事件，重建主 Agent 并运行最多 30 步（:542-548、589、597）。
- 系统提示要求使用 send_message_to_user 交付结果，完成后经 persist_agent_history 写回对话历史（:572-582、611-616，utils/history_saver.py:9-27）。

## 6. 安全与限制

### 6.1 权限模型（func_tool_manager.py:214-285、453-494）

- 权限代理刻意不设置 handler（:233-234），使执行器通过 call() 分支调用并确保所有路径先经过权限检查（:246-285）。
- 权限从全局 SharedPreferences 的 tool_permissions 读取，按 _default 键再匹配工具名（:472-478）；默认权限为 member，即不限制（:453-458）。需要 admin 时，非 admin 事件返回含发送者 ID 的错误（:485-496）。
- 内置工具不经过代理，在自身实现内检查 admin 权限或受限环境（:217-220）。

### 6.2 工具级防护汇总

| 类别 | 实现 | 位置 |
|---|---|---|
| 执行超时 | asyncio.wait_for（默认 tool_call_timeout，后台 3600s） | astr_agent_tool_exec.py:664-701 |
| 结果大小 | 27.5k tokens 落盘 + 7k 预览 | tool_loop_agent_runner.py:110-111、369-441 |
| 重复调用 | 3/4/5 档提示注入 | :146-175、723-748 |
| 步数上限 | MAX_STEPS（max_agent_step 默认 30）+ MAX_STEPS_REACHED_PROMPT 拔工具强收尾 | :125、1060-1088 |
| 用户中断 | request_stop() → abort 信号；等待逻辑立即取消进行中的 LLM/压缩请求，执行器读取同步可中断 | :461-501、1471-1476、1526-1568 |
| 参数白名单 | 仅传声明过的参数键 | tool_loop_agent_runner.py:1162-1188 |
| 图像引用净化 | `is_supported_image_ref` 过滤非法 image_urls | astr_agent_tool_exec.py:101-128 |
| 插件权限链路 | 插件未激活时 `activate_llm_tool` 抛错 | func_tool_manager.py:1020-1023 |
| 后台任务隔离 | 独立 task + 独立主 Agent 实例 + 结果走 cron 事件 | astr_agent_tool_exec.py:509-619 |

### 6.3 已知边界（静态推断）

- 权限黑名单持久化与插件热重载之间无联动：插件停用时 func_list 被清理，但 inactivated_llm_tools 条目残留；重启后同名插件重新注册时黑名单仍生效（star_manager.py:804-807、1916）。
- 每次构建完整工具集都会新建权限代理，无缓存；权限变更需下次构建工具集才生效。
- 内置工具实例按类缓存，插件运行期修改内置工具类定义不生效（需重启）。

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

- runtime 选择由 astr_agent_tool_exec.py:189-245 的运行时工具组装逻辑完成，依据 provider_settings.computer_use_runtime（默认 local，:257）和 sandbox booter 选择工具；sandbox 有 8 个，cua 有 3 个，local 有 7 个。

### 7.3 shipyard_neo（computer_tools/shipyard_neo/，14 个）

- 全部使用 builtin_tool 配置规则：browser.py 提供浏览器执行、批量执行和运行技能三个工具（:39、97、162）；neo_skills.py 提供执行历史、标注、payload、候选、发布、回滚和同步等 11 个工具（:74-506）；
- 属"技能流水线"管理类（执行历史、payload、候选、发布、回滚、同步）。

## 8. MCP 支持

### 8.1 配置与初始化（func_tool_manager.py:540-642）

- 配置文件为 data/mcp_server.json，使用 mcpServers 映射服务名及 command/args 或 url、active 字段；缺失时自动写入空配置（:567-573）。
- 初始化入口过滤 active=False，为每个服务创建 mcp-init:{name} 任务并通过 asyncio.gather 并行运行（:581-604）；失败写入运行时表（:619-620）。
- 初始化和动态启用分别使用 ASTRBOT_MCP_INIT_TIMEOUT、ASTRBOT_MCP_ENABLE_TIMEOUT 两个超时环境变量（:91）；全部失败时按 raise_on_all_failed 抛出 MCPAllServicesFailedError（:637-641）。日志只记录可执行文件名和主机名，不记录完整 command/url（:516）。

### 8.2 生命周期（:644-773+）

- MCP 服务启动具备幂等性，已运行或启动中的服务会被忽略（:657-664）。连接和工具列表保存放在同一任务中，注册为 MCPTool；重连前先移除旧的同名工具（:698-710、:701-703）。
- **清理必须在同一任务**：收到关闭信号后终止 MCP 客户端；跨任务使用 asyncio.shield 会因 anyio cancel scope 失败，取消吸收循环兼容 Py3.10（:719-740，#9068）。

### 8.3 WebUI 管理（dashboard/services/tools_service.py）

- WebUI 读取配置和运行时表合并 connected、tools、errlogs（:52-90）；新增服务时校验格式，配置失败则回滚（:41-50、106-120）。前端入口为 McpServersPage.vue 和 McpServersSection.vue。ModelScope 同步逻辑从 OpenAPI 拉取运行中的服务并合并本地配置（func_tool_manager.py:1074-1143）。

## 9. 子 Agent（Handoff）

- HandoffTool 的名称按 transfer_to_{agent.name} 生成，参数固定为 input、image_urls、background_task（handoff.py:8-64）。可选 provider_id 可单独指定子 Agent 模型，并优先于当前会话 provider（:34，astr_agent_tool_exec.py:341-343）。
- 构建子 Agent 工具集时，tools=None 表示全量工具，但会排除其他 HandoffTool 以防递归，并追加 runtime 电脑工具；指定列表则逐个解析（:247-302）。图片参数会与事件消息中的 Image 组件合并并净化；begin_dialogs 解析为 Message 列表，子 Agent 历史不持久化（:101-128、346-358）。
- 后台 handoff 立即返回 task_id，完成后唤醒主 Agent（:379-467）。

## 10. UI 层

| 界面 | 位置 | 内容 |
|---|---|---|
| 工具启停/权限表 | dashboard/src/components/extension/componentPanel/components/ToolTable.vue | 展示工具基本信息、启停和 admin/member 权限操作；内置工具显示配置标签状态，权限使用不同颜色（:13-25、70-80） |
| 工具配置条件展示 | ToolTable.vue :42-68 | 将 BuiltinToolConfigCondition 的 truthy/equals/in 条件渲染为可读文本 |
| 组件面板 | componentPanel/index.vue | 集成 ToolTable、CommandTable、DetailsDialog |
| MCP 服务管理 | McpServersPage.vue + McpServersSection.vue | 服务器 CRUD、连接状态、工具列表、错误日志 |
| 聊天工具调用卡片 | components/chat/message_list_comps/ToolCallCard.vue、ToolCallItem.vue、IPythonToolBlock.vue | 渲染 tool_call/tool_call_result 消息链和 Python 执行结果 |
| 搜索工具结果折叠 | MessageListDEPRECATED.vue:290-307 | 折叠展示多个搜索工具结果（DEPRECATED 组件） |
| 子 Agent / 定时任务 | SubAgentPage.vue、CronJobPage.vue | handoff 目标管理与 future_task 任务视图 |

## 11. 设计取舍与边界

### 11.1 已确认的设计（代码事实）

- **同一 ToolSet 三协议导出**：适配器零转换差异，Anthropic/Gemini 适配器直接消费对应 schema；
- **串行执行优先于吞吐**：避免平台并发与 LLM 竞态，代价是多工具任务延迟叠加；
- **执行器按类型分发而非注册表**：四路来源靠 `isinstance` 分流（astr_agent_tool_exec.py:142-187），新增来源需改分发点；
- **权限默认开放**：非内置工具 member 起步，admin 收紧（反向安全模型）；
- **工具失败不中断会话**：异常转 tool 结果回填 LLM，由模型决定下一步；
- **None 即结束**：工具直接回复用户后终止循环，主 Agent 不再追问；
- **双段 skills_like schema**：省 token 优先，参数第二轮补全，带修复重试；
- **结果物化分三级**：内联 → 预览+落盘 → 提示工具读取。

### 11.2 取舍（平衡决策）

- 权限代理的 handler 留空，强制走 call() 并与执行器的 MRO 检查联动（func_tool_manager.py:221-226、astr_agent_tool_exec.py:634-638）；这种隐式约定保证全路径权限检查。
- 内置工具权限硬编码在实现内，与通用权限表双轨并存（:217-220）。工具停用同时写入黑名单和 active 标志，保证跨重启持久（func_tool_manager.py:986-1013）。
- MCP 重连先清除同名工具，避免热更新累积重复声明；后台任务复用 CronMessageEvent 驱动唤醒（:542-548、701-703）。

### 11.3 静态推断的潜在问题（未实测）

- **串行 + 后台分离不彻底**：后台工具在 execute 内创建 task 后立即返回 task_id，主循环照常结束；同一响应中的后续工具仍串行等待，结果依赖唤醒机制兜底。
- **权限检查只查 admin 两态**：tool_permissions 目前只有 admin/member 语义，无 per-user 白名单/黑名单维度。
- **图片参数收集不递归**：嵌套结构中的图片 URL 不提取（astr_agent_tool_exec.py:57-74）。
- **超时只包单次 anext**：多次 yield 的工具每次独立计时，总时长可能超过 tool_call_timeout 的 N 倍。
- **结果上限使用估计器**（:247）：对中文或多字节文本可能低估。

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
