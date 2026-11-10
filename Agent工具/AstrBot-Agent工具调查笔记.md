# AstrBot Agent 工具调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：工具定义与 schema、注册机制、运行时工具集构建、调用执行链路、结果回填、安全限制、内置工具、MCP、子 Agent 与 UI 层
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的 Agent 工具体系以「统一执行器 + 多来源注册」为核心：所有工具（内置、插件、MCP、子 Agent Handoff）最终都归一为 FunctionTool 对象，由其执行方法（astr_agent_tool_exec.py:133-190）按类型分发，主 Agent runner ToolLoopAgentRunner 在循环中串行消费。工具系统横跨四个代码域：定义与 schema、注册与生命周期、执行分发和运行循环，入口分别见 core/agent/tool.py、core/provider/func_tool_manager.py + core/tools/registry.py、core/astr_agent_tool_exec.py、core/agent/runners/tool_loop_agent_runner.py。

关键事实：

- **三类协议 schema 由同一 ToolSet 导出**：ToolSet 上的三个导出方法分别生成 OpenAI、Anthropic 和 Google 需要的结构，各家适配器拿到的是同源数据。Google 那一份要多过一层递归转换器，逐项消化 JSON Schema 与 Gemini 格式的差异：list 类型、被去掉的 additionalProperties、array 缺省 items 的回退等（`astrbot/core/agent/tool.py:204-363`）。
- **四路注册汇合**：内置工具由 builtin_tool 装饰器登记，插件工具从 star 注册装饰器进入，MCP 工具由 data/mcp_server.json 描述后经初始化入口加入，子 Agent 一侧统一用 HandoffTool 表达。四类落点依次是 `astrbot/core/tools/registry.py:232-254`、`astrbot/core/star/register/star_handler.py:610-620`、`astrbot/core/provider/func_tool_manager.py:540-642` 和 `astrbot/core/agent/handoff.py:8-64`。
- **同名工具去重规则为「active 优先、同状态后覆盖」**：ToolSet 添加工具时先看新旧两方的 active 状态决定是否覆盖，管理器查找时再反向扫描注册列表取最后一个同名项（`astrbot/core/agent/tool.py:92-109`、`astrbot/core/provider/func_tool_manager.py:399-417`）。
- **执行串行无并行**：同一条响应里的多个 tool_call 由处理入口按出现顺序逐个等待完成，整条链路没有并发执行的分支（`astrbot/core/agent/runners/tool_loop_agent_runner.py:1108-1418`）。
- **工具返回 None 会结束 Agent，交付结果可以缺失**：本地执行器遇到空结果时先把事件里已有的结果发出去，结果为空或发送过程抛错时照样返回 None，runner 随即置为 DONE（`astrbot/core/astr_agent_tool_exec.py:619-637`、`astrbot/core/agent/runners/tool_loop_agent_runner.py:1377-1392`）。cron 与后台任务的完成都走同一套普通事件流水线，最大步骤取自同一份 InternalAgentSubStage 配置，默认 128 步，该入口只对布尔值做兼容回退（`astrbot/core/pipeline/process_stage/method/agent_sub_stages/internal.py:77-98`）。
- **权限代理取决于装配入口**：全量注册工具集里的工具装入时被代理包裹，每次调用都要先过一遍权限表；Persona 选中非空工具名单时改走 `get_func` 取原对象，这条分支拿到的工具没有代理。敏感内置工具另在自身实现里检查角色与运行环境（`astrbot/core/provider/func_tool_manager.py:399-513`、`astrbot/core/astr_main_agent/persona.py:132-148`）。
- **五种产物级防护**：工具超时、结果 token 溢出落盘、重复调用提示、MAX_STEPS 截断和 skills_like 双段 requery 各自拦住不同的失败形态，实现散落在 runner 的常量定义与执行分支中（`astrbot/core/agent/runners/tool_loop_agent_runner.py:111-1469`）。
- **本机隔离由角色策略决定**：Local runtime 按 member 与 admin 两档分别解析文件范围、执行和联网权限。整机文件访问与联网都放行时可直接以非隔离方式执行；只要需要收紧文件范围或联网，就要求有 OS 沙箱，后端探测失败则放弃这次执行。Linux、macOS、Windows 分别用 bubblewrap、Seatbelt、AppContainer 承载，Windows 上的受限执行只支持工作区范围，并用 Job Object 限制 CPU、内存和进程数，公共配置里的文件大小与打开文件数在该后端尚未落实（`astrbot/core/tools/computer_tools/util.py:41-309`、`astrbot/core/computer/process_sandbox/windows.py:435-474`）。
- **网页搜索包含 AnySearch**：把 `websearch_provider` 选为 anysearch 时会注入 `web_search_anysearch` 工具，普通搜索与垂直领域标签都支持；没有 Key 时放行一次匿名请求，配了 Key 则沿用错误驱动的多 key 轮换（`astrbot/core/tools/web_search_tools.py:1248-1448`）。
- **内置工具 5 组约 26 个 + shipyard_neo 14 个**，每组带 config 规则（`BuiltinToolConfigRule`），但**规则只驱动 WebUI 展示"可用状态"，不参与运行时注入**（唯一消费方 tools_service.py:533-569）。
- **MCP 生命周期自管理**：启动并行初始化（并发 task + `asyncio.gather`）、连接超时/启用超时双环境变量、幂等启动、同任务内清理（#9068 修复）、ModelScope 云端同步；**工具名对 LLM 侧清洗**（`[^A-Za-z0-9_-]+`→`_`），原名保留用于实际 MCP 调用（mcp_client.py:800-808，#9534）。
- **停止即取消**：`_await_or_stop` 把进行中的 LLM 请求和上下文压缩与 abort 信号放在一起竞速，收到停止请求就立刻取消等待；用户中断后按「Stop output.」与「Output stopped.」这对 user/assistant 消息回填（`astrbot/core/agent/runners/tool_loop_agent_runner.py:472-512`）。

## 总体调用链

```text
用户消息 → astr_main_agent.run_agent (astr_agent_run_util.py:120)
  → 构建 ProviderRequest + ToolSet（各 _apply_* 分支：_apply_kb / _apply_web_search_tools / persona 等）
  → ToolLoopAgentRunner.reset（携带 tool_schema_mode，默认 "full"）
  → step() 循环：
      provider.text_chat(func_tool=ToolSet)  → LLMResponse.tools_call_*
      → _handle_function_tools（tool_loop_agent_runner.py:1149-1418）
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
| ToolSchema | tool.py:20-38 | 工具名、描述和参数（JSON Schema）；模型校验器用 jsonschema 校验 parameters 是否符合 Draft 2020-12 元 schema（:32-37） |
| FunctionTool | tool.py:41-75 | 可调用工具，保存 handler、模块路径、active 和后台任务标志；默认 call() 抛出 NotImplementedError（:50-74） |
| ToolSet | tool.py:78-399 | 运行时工具集容器，负责增删查改、合并、三种协议 schema 导出和两个派生视图 |

### 1.2 ToolSet 去重规则（add_tool，tool.py:92-109）

- 同名冲突时，只有新工具 active 或旧工具 inactive 才覆盖（:105）；
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

- 工具注册时参数 schema 即被 jsonschema.validate 校验（tool.py:33-38），非法 schema 在构造时抛错，属于注册期失败而非运行期失败。
- spec_to_func（func_tool_manager.py:343-363）把插件声明的参数列表转成 object 类型的 properties 结构，类型在 :351 硬编码为 object。

## 2. 注册机制（四路汇合）

### 2.1 四路来源

| 来源 | 声明/入口 | 落点容器 | 特征 |
|---|---|---|---|
| 内置工具 | astrbot/core/tools/ 五模块的 builtin_tool | builtin_func_list（func_tool_manager.py:292，按类惰性实例化缓存） | 类定义即注册，实例由 get_builtin_tool 缓存（:419-441） |
| 插件工具 | star 插件 tool 装饰器 → `star/register/star_handler.py:610-620` | func_list（func_tool_manager.py:290） | 先移除同名项再追加，或由 spec_to_func 转换（:365-390、:678） |
| MCP 工具 | data/mcp_server.json → init_mcp_clients（func_tool_manager.py:540-642） | func_list 中的 MCPTool（:698-710） | 启动时并行初始化；供 LLM 使用的工具名清洗为 `[A-Za-z0-9_-]`，原名保留供实际调用（mcp_client.py:800-808）；重连时先清除同名项（:701-703） |
| 子 Agent | HandoffTool（handoff.py:8-64） | func_list | 名称按 transfer_to_{agent.name} 生成（handoff.py:26），由 `star/register/star_handler.py:715` 的 llm_tool 方法追加 |

### 2.2 `builtin_tool` 装饰器与 config 规则（registry.py）

- 装饰器先读类属性 name，再退回 dataclass 字段默认值，两处都没有就抛 ValueError；同名工具重复注册时同样抛该异常（:201-244）。
- 可选的 config 参数会被编译成配置规则写进规则表（:248-249）；规则支持 equals、in、truthy、custom 四种算子，取值支持点路径（:33-77）。
- 发送消息工具有一条独立规则：遍历 platform 配置，wecom 与 weixin_official_account 两个平台不接受主动消息，wecom_ai_bot 则要求 msg_push_webhook_url 非空（:121-181）。
- 工具模块按需惰性导入（:257-265），配置规则目前只有 WebUI 在读（:288-332）。

### 2.3 工具启停持久化（func_tool_manager.py:986-1043）

- 停用工具会将 active 置为 false，并写入 SharedPreferences 的 inactivated_llm_tools；启用时若所属插件未激活则抛出 ValueError，再恢复 active 并移除黑名单（:986-1043）。
- 插件侧 API 位于 star/context.py:413-424 和 :718。

## 3. 运行时工具集构建

### 3.1 get_full_tool_set（func_tool_manager.py:496-515）

- 新建空 ToolSet，把 func_list 中每个非内置工具包装为权限代理后加入；包装确保每次调用先经过权限检查，内置工具不包装而保留自身权限逻辑（:214-226）。

### 3.2 按调用点裁剪（astr_main_agent/ 各装配模块）

| 分支 | 行号 | 行为 |
|---|---|---|
| Persona 选择 | `persona.py:130-148` | 未指定名单时取全量注册工具代理；指定名单时按名称取原对象，再合并已有工具 |
| 知识库 | `knowledge_base.py:31-35` | agentic 模式向现有集合追加检索工具，仅集合为 None 时新建 |
| 联网 | `web_search.py:71-104` | 开启后按搜索源追加工具，保留既有工具 |
| Computer Use 与辅助工具 | `builder.py:117-133` | 按运行时及 cron、平台主动投递、群历史配置继续追加 |

- 运行中的 ToolSet 挂在 ProviderRequest.func_tool 上交给适配器，OpenAI 与 Anthropic 适配器各自把它转成协议格式；模型不支持 function calling 时，适配器去掉 tools 再重试（`astrbot/core/provider/entities.py:201`、`provider/openai_source.py:546-554,1171-1189`、`provider/anthropic_source.py:508-513`）。

### 3.3 skills_like 模式（tool_loop_agent_runner.py:300-318）

- tool_schema_mode 有 full 和 skills_like 两档：前者默认发送完整 schema，后者首轮只发送名称和描述以节省 token（#4681）。
- skills_like 下，首轮请求使用 light_set，同时保存原工具集和只含参数的集合（:303-307）；执行解析走原集合（:1137-1147），第二轮再用参数集合补全参数，失败后按更强指令重试（:136-144、1395-1469）。

## 4. 工具执行链路

### 4.1 执行器抽象与分发（astr_agent_tool_exec.py:133-190）

- 执行器基类 BaseFunctionToolExecutor 声明的 execute 是个只有 17 行的抽象接口，具体实现留给子类（`astrbot/core/agent/tool_executor.py:10-17`）。
- FunctionToolExecutor.execute 按工具类型分四路：HandoffTool 依 background_task 走前台或后台 handoff，MCPTool 直接调用 MCP 工具，标记为后台任务的工具建好 task 后立即返回带 task_id 的结果，其余进入本地执行（`astrbot/core/astr_agent_tool_exec.py:133-728`）。

### 4.2 _execute_local 细节（:647-728）

- 执行方法按优先级三选一：先用 handler，找不到再取类层级中重写的 call，最后是 run，三者都没有就抛 ValueError（:659-681）。统一包装层按类型传参，run 与装饰器处理器收到 event，call 收到 context（:762-767）。
- 异步生成器型工具被逐步消费，消息事件的结果先写进事件再以空值占位，普通协程则直接等待完成；参数对不上时按签名拼出可读的错误说明（:771-837）。
- 每次取结果都套一层 asyncio.wait_for 限时，默认读 run_context.tool_call_timeout，后台任务固定 3600 秒；工具没有返回值时，事件里的结果直接发给用户，同时以空值通知 runner 结束（:489-722）。

### 4.3 runner 侧消费（tool_loop_agent_runner.py:1149-1418）

- 每个工具调用先产出一条 tool_call 消息链供 UI 展示，链里的 Json 组件带 id、name、args、ts 四个字段；模型点名的工具找不到时，回填一段错误文本（:1118-1160）。
- **参数过滤**：有 handler 的工具只接收参数 schema 里声明过的键，多余的键记一条 warning 后丢弃；没有 handler 的工具（如 MCP）直接拿到全部参数（:1162-1188）。
- 工具开始时触发 on_tool_start hook，结束时触发 on_tool_end hook（:1190-1197,1312-1320）。
- 结果处理把 TextContent 拼成文本，ImageContent 经图片缓存落盘，并在给 LLM 的提示里要求改用 send_message_to_user；EmbeddedResource 的非图片资源照同样方式处理（:1205-1268）。超出上限的大结果单独落盘，空响应直接转成 AgentState.DONE（:1271-1298）。
- 异常统一转成错误文本回填，执行被中断的专用异常继续向上抛出（:1321-1331）。等待结果时同时监听 abort 信号，用户停止即可中断工具执行，进行中的 LLM 请求和上下文压缩也随之取消（:461-501,1526-1568）。

## 5. 工具结果处理与上下文回填

### 5.1 大结果落盘（:110-111、:369-441）

- 结果估算上限为 27,500 tokens，预览上限为 7,000（:110-111）。超限时预览截断，全文写入 tool_result_overflow_dir，文件名由净化后的调用 ID 和 uuid 后八位组成，并在回填文本中提示使用读文件工具查看（:168-173、369-441）。
- 写盘通过 asyncio.to_thread 执行（:394）。

### 5.2 重复调用守卫（:144-175、:723-748）

- 重复调用按同工具名和同参数连续计数（:723）；
- 阈值 3/4/5 三档，L1 温和提醒、L2 强调、L3 严正提醒，模板追加到 tool 结果尾部（:148-167）；
- 只有连续两次工具和参数都完全相同才累加。

### 5.3 回填与 UI 消息链

- 工具调用和结果都以 MessageChain 的形式产出，类型分别是 tool_call 与 tool_call_result，内容放在 Json 组件里（:1118-1348）。
- astr_agent_run_util.py 负责从消息链里取出 Json、截短 UI 预览、合并流式链并驱动循环；工具结果随后追加进上下文，参与下一轮 LLM 请求和上下文压缩（:30-115,1000）。

### 5.4 后台任务唤醒主 Agent（astr_agent_tool_exec.py:518-646）

- 后台结果通过 CronMessageEvent 模拟主动事件，重建主 Agent；步数来自配置档案的 `agent_runner.config.misc.max_steps`，非法或非正值经归一化收敛到可用下限（astr_agent_tool_exec.py:561-579）。
- 系统提示要求使用 send_message_to_user 交付结果；后台任务完成与 cron 任务改以唤醒事件重入流水线，对话历史由处理阶段的统一写入路径落库（`astr_agent_tool_exec.py:501-546`、`internal.py:445-504`）。

## 6. 安全与限制

### 6.1 权限模型（func_tool_manager.py:214-285、453-494）

- 权限代理不给包裹对象设置 handler，于是调用落到代理的 call 分支，权限检查就在那里发生；被直接取出的原对象绕开这层检查，Persona 非空名单走的正是这条路径（`astrbot/core/provider/func_tool_manager.py:228-285`、`astrbot/core/astr_main_agent/persona.py:138-148`）。
- 权限值来自全局 SharedPreferences 的 tool_permissions：先取 _default 键，再按工具名匹配覆盖，缺省是 member 档，即不做限制（:453-478）。需要 admin 的工具遇到非 admin 事件时，返回带发送者 ID 的错误（:485-496）。
- 内置工具不经过代理，在自身实现内检查 admin 权限或受限环境（:217-220）。

### 6.2 工具级防护汇总

| 类别 | 实现 | 位置 |
|---|---|---|
| 执行超时 | asyncio.wait_for（默认 tool_call_timeout，后台 3600s） | astr_agent_tool_exec.py:689-726 |
| 结果大小 | 27.5k tokens 落盘 + 7k 预览 | tool_loop_agent_runner.py:111-112、369-441 |
| 重复调用 | 3/4/5 档提示注入 | :146-175、723-748 |
| 步数上限 | 普通流水线读取配置档案最大步骤，缺省 128；达到上限后撤工具强收尾 | `pipeline/process_stage/method/agent_sub_stages/internal.py:77-98`；`tool_loop_agent_runner.py` 的 MAX_STEPS_REACHED_PROMPT 分支 |
| 用户中断 | request_stop() → abort 信号；等待逻辑立即取消进行中的 LLM/压缩请求，执行器读取同步可中断 | :461-501、1471-1476、1526-1568 |
| 参数白名单 | 仅传声明过的参数键 | tool_loop_agent_runner.py:1225-1251 |
| 图像引用净化 | `is_supported_image_ref` 过滤非法 image_urls | astr_agent_tool_exec.py:98-125 |
| 插件权限链路 | 插件未激活时 `activate_llm_tool` 抛错 | func_tool_manager.py:1020-1023 |
| 后台任务交接 | 进程内 task 完成后以 background_task 来源入普通事件队列，沿原会话流水线构建下一回合 | `astr_agent_tool_exec.py:517-546`；`astr_agent_wakeup.py:10-54` |

### 6.3 已知边界（静态推断）

- 权限黑名单持久化与插件热重载之间无联动：插件停用时 func_list 被清理，但 inactivated_llm_tools 条目残留；重启后同名插件重新注册时黑名单仍生效（star_manager.py:807-810、1916）。
- 全量工具集会新建权限代理，但权限值在每次 `call` 时重新读取，已构建的代理也能观察后续权限表变化。Persona 非空工具名单直接取原对象，该装配分支未经过此代理（`astrbot/core/provider/func_tool_manager.py:246-251,460-494`；`astr_main_agent/persona.py:138-148`）。
- 已读的执行器、权限代理与 Computer Use 权限路径采用即时允许或返回错误，没有等待用户逐次审批的挂起状态；WebUI 的 admin/member 权限配置与每次调用确认属于不同交互。
- 内置工具实例按类缓存，插件运行期修改内置工具类定义不生效（需重启）。

## 7. 内置工具清单

### 7.1 五组（core/tools/）

| 模块 | 工具（name） | config 规则条件 | 行号 |
|---|---|---|---|
| web_search_tools.py | 百度、Tavily、Bocha、Brave、Firecrawl、Exa 与 AnySearch 搜索/正文工具 | `provider_settings.web_search` + 对应 `websearch_provider` 匹配 | AnySearch 入口 `AnySearchWebSearchTool`（:1347-1448）；共享 `_KeyRotator` 做多 key 轮换 |
| message_tools.py | `send_message_to_user`（:81）`get_group_message_history`（:362） | send_message_to_user 用自定义 `_evaluate_send_message_tool`（registry.py:121-181）；历史记录上限 `group_message_history_max_cnt: 700` | :78-357、:357-560 |
| knowledge_base_tools.py | `astr_kb_search`（:93） | `provider_settings.kb` 相关（`_KNOWLEDGE_BASE_TOOL_CONFIG`） | :90- |
| cron_tools.py | `future_task`（:55，action: create/edit/delete/list，支持 cron 与一次性 run_at） | `provider_settings.proactive_capability.add_cron_tools`（:16-18） | :52- |
| computer_tools/ | 见下 | 各 runtime 条件 | — |

### 7.2 computer_tools/（按 runtime 分档）

| 工具 | name | 适用 runtime |
|---|---|---|
| `ExecuteShellTool` | `astrbot_execute_shell`（shell.py:61） | sandbox（booter 任意） |
| `PythonTool` | `astrbot_execute_ipython`（python.py:82） | sandbox |
| `LocalExecuteShellTool` | （继承 ExecuteShellTool，:183） | local |
| `ShellSessionTool` | `astrbot_shell_session`（shell.py:249） | local |
| `LocalPythonTool` | `astrbot_execute_python`（python.py:119） | local |
| `FileReadTool` / `FileWriteTool` / `FileEditTool` / `GrepTool` | `astrbot_file_read_tool` 等（fs.py:309、406、478、569） | sandbox + local |
| `FileUploadTool` / `FileDownloadTool` | `astrbot_upload_file` / `astrbot_download_file`（fs.py:814、871） | sandbox |
| `CuaScreenshotTool` / `CuaMouseClickTool` / `CuaKeyboardTypeTool` | `astrbot_cua_*`（cua.py:53、111、148） | sandbox + booter=cua |

- runtime 选择由 astr_agent_tool_exec.py:203-258 的运行时工具组装逻辑完成，依据 provider_settings.computer_use_runtime 和 sandbox booter 选择工具；该键在配置 schema 中的默认值为 none（core/config/default.py:182），读侧缺键时同样回退为 none（astr_agent_tool_exec.py:270）。sandbox 有 8 个，cua 有 3 个，local 有 7 个。

### 7.3 shipyard_neo（computer_tools/shipyard_neo/，14 个）

- 全部使用 builtin_tool 配置规则：browser.py 提供浏览器执行、批量执行和运行技能三个工具（:39、97、162）；neo_skills.py 提供执行历史、标注、payload、候选、发布、回滚和同步等 11 个工具（:74-506）；
- 属"技能流水线"管理类（执行历史、payload、候选、发布、回滚、同步）。

## 8. MCP 支持

### 8.1 配置与初始化（func_tool_manager.py:540-642）

- 服务清单放在 data/mcp_server.json 的 mcpServers 下，每项记录服务名，以及 command/args 或 url，另有 active 开关；文件缺失时会自动写入空配置（:567-573）。
- 初始化入口跳过 active=False 的条目，为每个服务建一个 mcp-init:{name} 任务，用 asyncio.gather 并行拉起，失败结果写进运行时表（:581-620）。
- 初始化和动态启用各有一个超时环境变量，分别是 ASTRBOT_MCP_INIT_TIMEOUT 与 ASTRBOT_MCP_ENABLE_TIMEOUT；全部服务都失败时按 raise_on_all_failed 抛 MCPAllServicesFailedError，日志只留可执行文件名和主机名，完整 command 与 url 不落日志（:91、:516-641）。

### 8.2 生命周期（:644-773+）

- 服务启动是幂等的：已在运行或正在启动的服务会被直接跳过（:657-664）。建立连接与保存工具列表放在同一个任务里完成，工具注册为 MCPTool，重连前先移除旧的同名条目（:698-710）。
- **清理必须在同一任务**：收到关闭信号后终止 MCP 客户端；跨任务使用 asyncio.shield 会因 anyio cancel scope 失败，取消吸收循环兼容 Py3.10（:719-740，#9068）。

### 8.3 WebUI 管理（dashboard/services/tools_service.py）

- WebUI 读取配置和运行时表合并 connected、tools、errlogs（:52-90）；新增服务时校验格式，配置失败则回滚（:41-50、106-120）。前端入口为 McpServersPage.vue 和 McpServersSection.vue。ModelScope 同步逻辑从 OpenAPI 拉取运行中的服务并合并本地配置（func_tool_manager.py:1074-1143）。

## 9. 子 Agent（Handoff）

- HandoffTool 的名称按 transfer_to_{agent.name} 的规则生成，参数固定为 input、image_urls 和 background_task；可选的 provider_id 用来单独指定子 Agent 的模型，优先级高于当前会话的 provider（handoff.py:8-64、astr_agent_tool_exec.py:355-356）。
- 构建子 Agent 的工具集时，tools 为 None 表示给全量工具，同时剔除其他 HandoffTool 以免递归，并追加当前 runtime 的电脑工具；给定列表则逐个解析（:250-306）。图片参数先与事件消息里的 Image 组件合并再净化，begin_dialogs 解析成 Message 列表，子 Agent 的对话历史不落库（:104-132,350-362）。
- 后台 handoff 立即返回 task_id，完成后唤醒主 Agent（:388-477）。

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
- **执行器按类型分发而非注册表**：四路来源靠 `isinstance` 分流（astr_agent_tool_exec.py:144-189），新增来源需改分发点；
- **权限默认开放**：非内置工具 member 起步，admin 收紧（反向安全模型）；
- **工具失败不中断会话**：异常转 tool 结果回填 LLM，由模型决定下一步；
- **None 即结束**：工具空结果触发完成；执行器只尝试交付已有结果，因此完成状态本身不足以证明用户已收到回复；
- **双段 skills_like schema**：省 token 优先，参数第二轮补全，带修复重试；
- **结果物化分三级**：内联 → 预览+落盘 → 提示工具读取。

### 11.2 取舍（平衡决策）

- 权限代理不在包裹对象上设 handler，调用一律走 call()，再由执行器的 MRO 检查接住；这层保护只对经代理装配的工具成立，Persona 非空名单分支拿的是原对象（func_tool_manager.py:221-226、astr_agent_tool_exec.py:561-578）。
- 内置工具权限硬编码在实现内，与通用权限表双轨并存（:217-220）。工具停用同时写入黑名单和 active 标志，保证跨重启持久（func_tool_manager.py:986-1013）。
- MCP 重连前先清掉同名工具，避免热更新时累积重复声明；后台任务完成后复用 CronMessageEvent 驱动唤醒（:550-557,731-740）。

### 11.3 静态推断的潜在问题（未实测）

- **串行 + 后台分离不彻底**：后台工具在 execute 内创建 task 后立即返回 task_id，主循环照常结束；同一响应中的后续工具仍串行等待，结果依赖唤醒机制兜底。
- **权限检查只查 admin 两态**：tool_permissions 目前只有 admin/member 语义，无 per-user 白名单/黑名单维度。
- **图片参数收集不递归**：嵌套结构中的图片 URL 不提取（astr_agent_tool_exec.py:57-75）。
- **超时只包单次 anext**：多次 yield 的工具每次独立计时，总时长可能超过 tool_call_timeout 的 N 倍。
- **结果上限使用估计器**（:247）：对中文或多字节文本可能低估。

## 12. 关键文件索引

- 工具定义：`astrbot/core/agent/tool.py`（ToolSchema :19-37 / FunctionTool :40-74 / ToolSet :77-366）、`tool_executor.py`（抽象执行器 :10-17）、`handoff.py`（:8-64）
- 注册与生命周期：`astrbot/core/tools/registry.py`（builtin_tool :232-254、config 规则 :26-198、状态计算 :288-332）、`astrbot/core/provider/func_tool_manager.py`（_PermissionGuardedTool :214-285、add/remove/get :365-417、get_full_tool_set :496-515、权限 :453-494、MCP :540-773、启停 :986-1045、ModelScope :1074-1143）
- 执行分发：`astrbot/core/astr_agent_tool_exec.py`（execute :133-190、_execute_local :647-728、call_local_llm_tool :743-837、handoff :307-477、后台唤醒 :518-646、runtime 电脑工具 :192-249）
- 主循环：`astrbot/core/agent/runners/tool_loop_agent_runner.py`（reset/skills_like :207-327、_await_or_stop :461-501、大结果 :396-460、_handle_function_tools :1089-1355、requery :1395-1469、中断读取 :1526-1568）
- 工具集裁剪与装配：`astrbot/core/astr_main_agent/`（plugins.filter_tools :53、knowledge_base.apply_knowledge_base :17、persona.apply_persona :32、computer_use.apply_computer_use :248、builder.build_main_agent :57）
- 本机进程沙箱：`astrbot/core/computer/process_sandbox/`（后端探测 `__init__.py:22-104`、公共限制 `base.py:9-68`、Windows AppContainer 启动与 Job 限制 `windows.py:407-620`）；策略判断：`astrbot/core/tools/computer_tools/util.py:93-198,246-309`。
- 内置工具：`astrbot/core/tools/`（web_search_tools / message_tools / knowledge_base_tools / cron_tools / computer_tools/）
- 插件工具入口：`astrbot/core/star/register/star_handler.py:610-620`、`star/context.py:413-424,718`
- MCP：`astrbot/core/agent/mcp_client.py`、`astrbot/dashboard/services/tools_service.py`（:36-120+）、`astrbot/dashboard/api/tools.py`
- UI：`dashboard/src/components/extension/componentPanel/components/ToolTable.vue`、`McpServersSection.vue`、`components/chat/message_list_comps/ToolCallCard.vue`、`IPythonToolBlock.vue`
- 文档：`docs/zh/use/function-calling.md`、`mcp.md`、`agent-runner.md`、`subagent.md`、`computer.md`、`context-compress.md`

## 13. 未验证事项

1. 未实测各工具在真实平台的执行结果（沙箱/本地 runtime、CUA、wecom 等平台差异）。
2. shipyard_neo 14 个工具的实际触发路径与 server 端行为未逐个核对。
3. 权限表在 WebUI 的完整读写链路（api/tools.py → ToolTable.vue）未逐行验证。
4. `mcp_server.json` 热更新（enable/disable 动态启停）运行时行为未实测。
5. 后台任务唤醒在并发多任务下的顺序与丢消息风险未实测。
