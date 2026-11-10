# Codex Agent 工具调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：只读源码静态梳理工具注册、目录构建、暴露过滤、调用解析、调度、审批、执行与结果回注链路；未运行构建、未实际发起模型请求或工具调用
>
> 调查范围：内置工具、MCP 工具、扩展工具、动态客户端工具、托管模型工具、Code Mode 与工具搜索；参数校验、并发模型、审批与沙箱、结果回注与取消；不含 TUI 工具卡呈现、遥测后端与各具体工具的完整业务实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的工具系统是“中央注册表 + 分层暴露策略 + 回合内并行调度”。模型看到的工具目录在每个 step 构建一次，由内置 handler、MCP、扩展、动态工具与托管工具汇合，再按 `ToolExposure` 决定是直接出现在请求里、只能通过工具搜索发现、只对 Code Mode 可见，还是完全隐藏。

关键事实：

- 每个 step 开始时，目录构建入口 `build_tool_router` 按固定顺序合并各路注册来源，构建本 step 的工具目录，见 `codex-rs/core/src/tools/spec_plan.rs:122-218`。
- 一次工具调用先进入执行入口 `ToolRegistry::dispatch_any_with_state`，前置 hook、环境解析、审批与原生复核都在这里汇合，见 `codex-rs/core/src/tools/registry.rs:724-1033`。
- 采样循环每收到一个 `response.output_item.done` 事件就调用 `build_tool_call` 解析，命中工具后落历史并启动一个执行 future，见 `codex-rs/core/src/stream_events_utils.rs:327-381`。
- 并发能力由工具声明决定：声明支持并行的工具拿读锁，其余工具拿写锁，并行批次里因此仍夹着独占段，见 `codex-rs/core/src/tools/parallel.rs:292-304`。
- 审批在工具执行端统一处理：先运行 permission hook，再在人工审批与 Guardian 自动复核之间选择，见 `codex-rs/core/src/tools/approvals.rs:548-703`。
- 工具结果按调用产生的顺序回注历史，完成时间先后不影响写入次序；采样流结束后用 `FuturesOrdered` 统一 drain，见 `codex-rs/core/src/session/turn.rs:2779-2807、3665-3675`。
- 没有固定的工具迭代次数上限；循环由 `needs_follow_up`、待处理输入、token 预算与自动压缩共同控制。

## 总体调用链

```text
step 开始
  → build_tool_router（spec_plan.rs:122-218）
      ├─ add_core_tool_sources：shell / MCP 资源 / 通用 / 协作（spec_plan.rs:1218-1238）
      ├─ append_mcp_tools + apply_mcp_tool_exposure_policy（spec_plan.rs:153-169、200-292）
      ├─ append_extension_tool_executors（spec_plan.rs:170-198）
      ├─ append_dynamic_tool_runtimes（spec_plan.rs:199）
      └─ finalize_tool_router：冲突处理、工具搜索、Code Mode（spec_plan.rs:401-586）
  → model_visible_specs 进入请求（spec_plan.rs:660-684）
  → 模型返回 FunctionCall / CustomToolCall / ToolSearchCall
  → build_tool_call 解析为 ToolCall（router.rs:271-340）
  → handle_output_item_done 落历史并起执行 future（stream_events_utils.rs:335-380）
  → ToolCallRuntime.handle_tool_call：准入、并行锁、dispatch（parallel.rs:108-448）
  → ToolRegistry.dispatch_any_with_state：hook、审批、执行、生命周期（registry.rs:724-1033）
  → AnyToolResult.into_response 生成 FunctionCallOutput 等（registry.rs:294-317）
  → drain_in_flight 按序回注历史（turn.rs:2779-2807）
  → needs_follow_up 决定是否再来一轮（turn.rs:3236、742）
```

## 1. 工具来源与注册

### 1.1 注册表

所有工具都以 `ToolExecutor` 实现加一条注册表条目存在。条目携带运行时、暴露级别和是否原生复核等信息；注册表本身还持有宿主下发的 `ToolPolicy`（`codex-rs/core/src/tools/registry.rs`、`codex-rs/ext/extension-api/src/tool_policy.rs:10-44`）。

`ToolPolicy` 是启动时的上限，不是会话身份：它可以给出工具白名单、要求托管沙箱、要求统一执行器、是否暴露附加权限参数（`tool_policy.rs:10-21`）。白名单按“命名空间 + 名字”匹配，普通名走默认命名空间（`tool_policy.rs:35-43`）。

### 1.2 核心工具分组

`add_core_tool_sources` 只做四件事（`spec_plan.rs:1218-1238`）：

| 分组 | 主要内容 | 入口 |
|---|---|---|
| shell | `exec_command`、`write_stdin`；统一执行器关闭时退化为一次性执行 | `spec_plan.rs:1275-1306` |
| MCP 资源 | `list_mcp_resources`、`list_mcp_resource_templates`、`read_mcp_resource` | `spec_plan.rs:1309-1324` |
| 通用 | 计划、等待环境、用户提问、权限申请、上下文窗口、时间、睡眠、插件安装、补丁、图片、测试同步 | `spec_plan.rs:1327-1485` |
| 协作 | 多 Agent 的 spawn/send/resume/close/wait/list，以及 Code Mode 执行器 | `spec_plan.rs:1488-1631` |

这些工具大多受 feature 或模型能力双重门控。例如 shell 组要求 `ShellTool` feature 且模型没有把 shell 类型设为禁用；统一执行器关闭时只注册一次性执行，不暴露可恢复进程与 `write_stdin`（`spec_plan.rs:1279-1305`）。

宿主还可以限制线程的根能力：`request_user_input` 的异步变体与向用户发消息的工具在 `root_capabilities_restricted` 为真时不注册这些工具（`spec_plan.rs:1357-1394`）。

### 1.3 MCP 工具

MCP 工具由 MCP 绑定统一追加，随后单独做暴露策略（`spec_plan.rs:153-169`）。服务器级配置决定哪些工具能进入注册表：

| 配置 | 作用 |
|---|---|
| `enabled` | 为 false 时跳过整个服务器 |
| `required` | 初始化失败是否让 `codex exec` 直接失败 |
| `startup_timeout_sec` / `tool_timeout_sec` | 启动与单次调用超时 |
| `enabled_tools` / `disabled_tools` | 先白名单后黑名单 |
| `omit_tools_from` | 从 Direct、Deferred 或 Code Mode 表面移除 |
| `default_tools_approval_mode` | 该服务器默认审批模式 |
| `tool_input_schema_max_bytes` | 单个工具输入 schema 的压缩阈值 |
| `environment_id` | 在哪个执行环境启动该服务器 |
| `supports_parallel_tool_calls` | 是否把该服务器工具标记为可并行 |

字段定义见 `codex-rs/config/src/mcp_types.rs:231-314`。单工具级还有 `tools.<name>` 覆盖。

### 1.4 扩展、动态与托管工具

扩展工具来自扩展注册表，动态工具来自线程声明，两者在目录构建的后段加入注册表（`spec_plan.rs:170-199`）。动态工具的延迟加载标记直接决定它是 `Deferred` 还是 `Direct`（`core/src/tools/handlers/dynamic.rs:75-102`）。

托管工具（例如 web 搜索、图像生成）不进入注册表，而是作为 `hosted_specs` 直接拼进模型可见列表，由模型提供方执行（`spec_plan.rs:200-209`、`:373`）。因此它们不受本地审批与沙箱链路约束，属于模型侧旁路。

网页搜索有原生搜索与 MCP 搜索等执行来源，提供方在每个 step 解析。宿主 MCP 搜索的访问模式通常由宿主策略与本地配置取交集；开启 `HostedSearchPolicy` 且本地模式为 Disabled 时，可以采用宿主模式，但仍须通过受管配置约束（[访问策略](<../../codex/codex-rs/core/src/model_search.rs#L250-L299>)、[提供方选择](<../../codex/codex-rs/core/src/model_search.rs#L303-L430>)）。

目录构建按选择结果收窄搜索入口：原生搜索生效或搜索被禁用时，移除 MCP 模型搜索工具；没有原生模式时，移除独立的 `web.run` 工具，并不生成原生托管搜索声明。宿主 MCP 的发现结果与线程所有者状态还决定能否走原生回退（[目录过滤](<../../codex/codex-rs/core/src/tools/spec_plan.rs#L176-L209>)、[发现与回退条件](<../../codex/codex-rs/core/src/model_search.rs#L404-L444>)）。

搜索所有者按**提供方**仲裁：同一线程已有预留时，同提供方的并发调用共享该预留，另一提供方申请才会失败。搜索调用准入会在线程状态中保留所有者；若只是为原生回退临时预留、尚无搜索调用将其固定，最后一个临时持有者随调用或采样请求结束时释放占位（[SearchOwner](<../../codex/codex-rs/core/src/model_search.rs#L78-L145>)）。这项仲裁本身不串行化或去重同提供方的搜索，实际工具并行仍受第 5.2 节的调度规则约束。

MCP 跳过路径只覆盖宿主管理的模型搜索工具：该 step 选择宿主 MCP 搜索、但线程已被原生搜索占用时，调用返回“该线程正在使用原生搜索”，且不会到达 MCP 对端或取得 MCP attribution。原生回退一侧也会检查同一预留，冲突时移除托管搜索声明，独立网页工具则返回可回注错误（[MCP 调用门](<../../codex/codex-rs/core/src/mcp_tool_call.rs#L491-L522>)、[原生回退预留](<../../codex/codex-rs/core/src/model_search.rs#L104-L141>)、[独立网页工具入口](<../../codex/codex-rs/core/src/tools/handlers/extension_tools.rs#L67-L78>)）。

## 2. 工具发现、过滤与暴露

### 2.1 六个暴露级别

`ToolExposure` 决定工具出现在哪一层（`codex-rs/tools/src/tool_executor.rs:49-99`）：

| 级别 | 初始请求可见 | 工具搜索可发现 | Code Mode 可用 |
|---|---|---|---|
| `Direct` | 是 | 否 | 是 |
| `DirectModelOnly` | 是 | 否 | 否 |
| `Deferred` | 否 | 是 | 是 |
| `DeferredModelOnly` | 否 | 是 | 否 |
| `CodeModeOnly` | 否 | 否 | 是 |
| `Hidden` | 否 | 否 | 否 |

“可见”与“可执行”分离：隐藏工具仍留在注册表里可被调度，只是模型看不到。

### 2.2 暴露计算

MCP 与应用工具的暴露由位集合运算得出（`spec_plan.rs:229-321`）。起点是三种表面的全集，先减掉 `omit_tools_from`，再按命名空间与模型能力调整：

- 命名空间一旦列入 `code_mode.direct_only_tool_namespaces`，其下的工具就失去 Deferred 与 Code Mode 两个表面，只剩直接可见。
- 模型支持工具搜索时，暴露计算优先去掉 Direct 表面，让工具转由搜索发现；在只允许 Code Mode 的会话里，这条规则只对同时保留 Code Mode 表面的工具生效，其余工具改为去掉 Deferred（`spec_plan.rs:297-305`）。
- 开启 `code_mode_only_strict_3p_tools` 后，第三方工具强制留在 Deferred，并忽略 MCP 与应用配置的 `omit_tools_from` 冲突（`spec_plan.rs:273-282、634-657`）。

### 2.3 工具搜索的合成

工具搜索不是常驻工具。只有当模型支持搜索、工具策略允许、并且至少有一个 Deferred 工具能提供搜索元数据时，才合成 `tool_search`（`spec_plan.rs:424-449`）。合成时会移除同名冲突工具，以及占用同名命名空间的工具（`spec_plan.rs:450-477`）。

### 2.4 冲突处理

注册表记录命名冲突。若 `tool_registry.error_on_tool_collisions` 开启，构建阶段直接返回工具冲突错误；否则冲突工具被移除并记录（`spec_plan.rs:508-513`）。Code Mode 的执行器与等待工具也走同一套移除与冲突记录（`spec_plan.rs:414-423`）。

## 3. 模型协议与调用表示

模型侧使用原生工具调用，不依赖文本协议。解析入口 `build_tool_call` 处理三类响应项（`router.rs:271-340`）：

| 响应项 | 载荷 | 说明 |
|---|---|---|
| `FunctionCall` | `ToolPayload::Function` | 普通函数工具，参数是 JSON 字符串 |
| `CustomToolCall` | `ToolPayload::Custom` | 自由文本输入的自定义工具 |
| `ToolSearchCall` | `ToolPayload::ToolSearch` | 仅接受 `execution == "client"` |

工具名由可选命名空间与名字组成；缺省命名空间在比较和注册时统一补齐（`router.rs:284-285`）。如果工具被标记为需要原生复核，解析时会保留原始响应项，供复核链路读取（`router.rs:286-302`）。

Provider 差异被收敛在模型信息与请求构造层：工具类型、是否支持搜索、是否使用精简响应格式等由 `ModelInfo` 决定，工具注册表本身不区分 Provider。

## 4. 参数解析、校验与错误处理

注册表层只校验“工具是否存在”和“载荷类型是否匹配”。工具不存在时返回 `RespondToModel` 文本，让模型自己改正；载荷类型不匹配则视为致命错误（`registry.rs:768-818`）。

具体参数 schema 由各 handler 自己解析。以 `exec_command` 为例，JSON 解析失败会转成可回注错误，并把中间截断后的错误文本回给模型（`core/src/tools/handlers/unified_exec/exec_command.rs:271`）。Code Mode 的源码解析失败同样走可回注错误（`core/src/tools/code_mode/execute_handler.rs:48`）。

错误分两类：

- `RespondToModel`：写回一条工具输出，回合继续，模型有机会重试。
- `Fatal`：向上抛 `CodexErr::Fatal`，终止当前请求。

`handle_output_item_done` 对 `RespondToModel` 的处理是先记录原始工具调用项，再追加一条工具输出（`stream_events_utils.rs:426-452`）。

## 5. 编排循环、并发与终止条件

### 5.1 循环驱动

`try_run_sampling_request` 消费模型流。每遇到一个完成的输出项就交给输出项处理器；如果产生工具 future，就压入 `in_flight`，并置需要继续回合的标记（`turn.rs:3222-3236`）。

采样流结束后，运行循环若发现还有未完成的工具调用，就进入 drain 阶段：逐个等待其完成，再按顺序写入历史（`turn.rs:2779-2807、3665-3675`）。

外层回合循环在模型要求继续或仍有待处理输入时再次发起采样（`turn.rs:644、758`）。

### 5.2 并发模型

工具声明是否支持并行，决定调度时给它读锁还是写锁：读锁可以重叠，写锁独占（`parallel.rs:183、292-304`）。命令执行与写入标准输入都声明支持并行，因此多个命令能同时执行（`unified_exec/exec_command.rs:121-123`、`write_stdin.rs:56`）。

MCP 工具的并行判定是“服务器配置声明支持，或工具注解声明只读”（`core/src/tools/handlers/mcp.rs:172-184`）。动态工具默认支持并行（`handlers/dynamic.rs:87-90`）。

### 5.3 取消与终止

`ToolCallRuntime` 为每次调用建独立任务。取消时若工具声明“取消后仍需完成”，或调用已经到达终态，就等待任务收尾；否则 abort 任务并合成一条“aborted by user”的工具输出（`parallel.rs:368-435`）。

循环没有固定的工具轮数上限：本次在 `core/src/session/turn.rs`、`core/src/config/mod.rs` 与 `config_toml.rs` 中未找到 `max_tool_calls` 或等价字段。代码注释直接说明，只要压缩能把上下文降下来，就不担心中间循环过多（`turn.rs:715`）。实际约束来自 token 预算、自动压缩、用户取消和模型不再发起工具调用。

## 6. 审批、授权与执行边界

### 6.1 审批入口

审批统一收口在 `ApprovalStore::request_approval`（`approvals.rs:548-683`）：

1. 先检查当前审批要求，不满足直接拒绝。
2. 运行 permission request hook；hook 的拒绝优先于一切放行。
3. hook 放行但需要人工确认时，仍进入复核。
4. 需要人工审批就走用户审批，否则尝试 Guardian 自动复核；Guardian 不可用再回落到用户（`approvals.rs:685-703`）。

自动复核覆盖的对象不只是命令执行：补丁、通过 `exec_command` 触发的补丁改写与权限申请都走同一条复核链路。MCP 工具调用还会把准备阶段解析好的环境与文件系统沙箱上下文随审批动作交给复核方，使复核看到的权限与工具实际执行环境一致，无需重新解析（`approvals.rs:402-420`、`mcp_tool_call.rs:1707-1717`）。

用户审批入口已拆成可注入提问过程的形式：审批编排接收一个 `user_prompt` future，把“问谁、怎么问”留给调用方。网络访问审批据此按目标端点串行提问，并在发起该访问的调用结束时统一结算（`approvals.rs:548-583`、`network_approval.rs:887-911`）。

审批策略有四种（`codex-rs/protocol/src/protocol.rs:1163-1186`）：

- `UnlessTrusted`：不可信项目下，除显式策略规则外都要审批。
- `OnRequest`：由模型决定何时请求审批。
- `Granular`：按沙箱升级、规则提示、技能脚本、权限申请、MCP elicitation 五类细分。
- `Never`：不向用户提问，失败直接回给模型。

### 6.2 MCP 审批语义

MCP 工具是否要审批，先看服务器或工具的审批模式（`core/src/mcp_tool_call.rs:2692-2704`）：

| 模式 | 行为 |
|---|---|
| `auto` | 按工具注解推断 |
| `prompt` | 一律审批 |
| `writes` | 非只读就审批 |
| `approve` | 一律放行 |

`auto` 的推断规则（`mcp_tool_call.rs:2673-2690`）：

- 明确标记为破坏性：审批。
- 明确标记为只读：放行。
- 其余情况：只要破坏性或开放世界任一提示缺省为真，就审批。

也就是说，没有注解的 MCP 工具默认按“可能有害”处理。

审批模式还会叠加宿主对连接的更严格要求；`auto` 与 `writes` 互不可比时收敛为 `prompt`（`codex-rs/config/src/mcp_types.rs:42-50`）。普通模式下，权限配置允许自动批准、工具模式/注解免审批或命中会话记忆时，可提前进入执行分支；只有确实需要新决定时才进入第 6.1 节的权限 hook 和人工/Guardian 复核。严格自动复核会跳过这些免审与会话记忆捷径，不能把中央审批入口的 hook 顺序泛化成每次 MCP 调用必经流程（[MCP 审批准入](../../codex/codex-rs/core/src/mcp_tool_call.rs#L1634-L1737)）。

由插件选择建立的 MCP 注册关闭持久批准选项，会话记忆仍按工具身份与审批模式计算；普通服务器在满足策略与提问特性时可提供持久批准。记忆键只在 `auto` 模式下建立；应用服务器还要求存在 connector 身份。键包含服务器、插件/连接身份和工具名，不含本次参数；`prompt` 和 `writes` 下的记忆型决定会归一化为单次批准（[记忆条件](../../codex/codex-rs/core/src/mcp_tool_call.rs#L1922-L1950)、[决定归一化](../../codex/codex-rs/core/src/mcp_tool_call.rs#L2438-L2451)）。

持久批准尝试写入用户配置，成功后重载该层并记入会话缓存；写入失败会记录错误并退为会话记忆，仍允许当前已批准调用。拒绝、超时和取消会产生跳过结果，获批或免审才交给准备好的 MCP 调用执行（[决定与执行分派](../../codex/codex-rs/core/src/mcp_tool_call.rs#L280-L413)、[记忆与持久化](../../codex/codex-rs/core/src/mcp_tool_call.rs#L2465-L2529)）。

### 6.3 执行边界

工具执行发生在会话绑定的执行环境里，而不是统一在宿主进程内。每次调用先解析目标环境，再交给 handler（`registry.rs:847-854`）。

sandbox 相关决策集中在 `core/src/tools/sandboxing.rs`：默认审批要求、原生沙箱强制、首次尝试的沙箱覆盖、无沙箱执行许可、Windows 沙箱级别选择都在这里（`sandboxing.rs:200-330`、`:407-470`）。审批与沙箱分管两层判断：审批决定“是否允许这次升级或例外”，沙箱决定“实际以什么权限执行”；前者通过后，实际执行权限仍由后者设定。

### 6.4 原生复核

部分工具被标记为 `NativeReview::Required`，在审批前后还会走一次原生复核（`registry.rs:888-892`）。多 Agent 历史相关工具在特定 feature 下会启用这一标记（`spec_plan.rs:1501-1509`）。

## 7. 结果回注、执行状态与恢复

### 7.1 结果形状

输出项形状由原始载荷决定（`registry.rs:294-317`）：

- 工具搜索：`ToolSearchOutput`。
- 自定义工具：`CustomToolCallOutput`。
- 其他函数工具：`FunctionCallOutput`。

失败路径在 `parallel.rs:460-485` 单独构造，同样带 `success: false`。

模型可见的输出会被截断。`FunctionToolOutput` 依据模型信息里的截断策略处理字节或 token 预算，并预留序列化开销（`core/src/tools/context.rs:177-260`、`:428-537`）。

### 7.2 生命周期状态

每次调用有独立的 `ToolCallState`，记录是否已到达终态、是否已经交付助手消息等（`parallel.rs:119-157`）。注册表在开始与结束时发出通知，但没有执行 handler 就被拒绝的调用会走 `notify_tool_finish_if_unclaimed`，避免状态悬挂（`registry.rs:1036-1043`）。

取消、失败、完成分别映射到 `Aborted`、`Failed`、`Completed` 三种生命周期结果（`registry.rs:982-996`）。

### 7.3 恢复语义

工具调用项在派发前就写入历史，因此即使进程在工具执行中中断，恢复时仍能看到“调用过什么”。如果取消发生在派发前，执行 future 会补一条中断结果，而不是让调用悬空（`stream_events_utils.rs:358-380`）。

## 8. MCP、动态工具、工具搜索与 Code Mode

### 8.1 MCP

MCP 既提供工具，也提供资源工具。工具调用走 `McpHandler`，审批按第 6.2 节规则，超时与并行能力来自服务器配置。资源工具（列举、读取模板）由核心直接注册，不依赖具体服务器是否提供同名工具。

宿主还能在请求发出前改写 MCP 调用元数据：注册了请求元数据钩子时，钩子在元数据定稿后追加字段；线程声明了元数据接收方时，还会注入根回合 id 与访问计划标识（`mcp_tool_call.rs:566-640`）。这使宿主侧的 MCP 服务能识别调用来自哪个根回合，而核心工具系统不感知具体字段含义。

### 8.2 动态工具

动态工具由客户端在启动线程时声明，handler 把调用转回客户端执行（`handlers/dynamic.rs:122-140`）。它的 schema 与描述完全由客户端提供，因此属于“客户端扩展模型能力”的通道，而不是本地内置能力。

### 8.3 工具搜索

`tool_search` 只暴露搜索接口，不直接暴露全部 Deferred 工具。模型先搜索，拿到工具定义后再发起真实调用。搜索实现由 `ToolSearchHandlerCache` 按注册表内容缓存构建（`spec_plan.rs:1667-1682`）。

### 8.4 Code Mode

Code Mode 把一组嵌套工具塞进单个 `exec` 工具，由 JS 运行时回调 `delegate` 执行（`core/src/tools/code_mode/delegate.rs:306`）。可进入 Code Mode 的暴露级别只有三类（`tool_executor.rs:92-98`）：

- `Direct`
- `Deferred`
- `CodeModeOnly`

两个 `*ModelOnly` 与 `Hidden` 不可用。

`direct_only_tool_namespaces`、`code_mode_only_strict_3p_tools` 与 `omit_tools_from` 都会改变 Code Mode 的可用集合，因此“模型能直接调用的工具”和“JS 里能调用的工具”并不总是同一份。

### 8.5 子 Agent

多 Agent 工具本身也是工具，受同一套注册、暴露与审批约束。它们的特殊之处在于会派生新线程，并可能携带父会话的工具目录或动态工具快照。子 Agent 的工具权限不会因为 spawn 而扩大。

## 9. 设计取舍与已确认边界

- **注册与暴露分离**。隐藏工具仍可被内部或 Code Mode 调用，减少“为了内部使用而暴露给模型”的需要。
- **目录按 step 构建**。模型、feature、命名空间策略或 MCP 目录变化后，下一 step 的目录可以不同。
- **并行按工具声明**。默认不并行，只有明确声明可并行的工具才拿读锁；这避免把文件写入类工具混进并行批次。
- **顺序回注**。结果按调用顺序写入历史，保证同一轮工具调用的因果顺序稳定，即使实际完成顺序不同。
- **审批与沙箱分离**。审批解决“是否允许例外”，沙箱解决“实际权限”，两者都不因工具声明而自动放宽。
- **无固定迭代上限**。循环终止依赖模型行为、token 预算与压缩，而不是硬编码轮数。

## 未验证事项

- 未构建或运行 Codex，未观察真实模型请求中的工具 schema 大小、工具搜索命中率与并行批次形状。
- 未启动 MCP 服务器，未验证 `auto` 审批在真实注解缺失或矛盾时的实际提示。
- 未验证 Code Mode 在真实 JS 运行时中的嵌套调用、超时与取消传播。
- 未验证 app-server 客户端提供的动态工具在断线、重连与多客户端场景下的行为。
- 未验证各 Provider 对托管工具与 `tool_search` 的实际支持差异。

## 关键源码索引

- `codex-rs/core/src/tools/spec_plan.rs`：目录构建、来源注册、暴露策略、工具搜索与 Code Mode 合成。
- `codex-rs/core/src/tools/registry.rs`：注册表、调度、hook、生命周期。
- `codex-rs/core/src/tools/router.rs`：模型响应项到 `ToolCall` 的解析。
- `codex-rs/core/src/tools/parallel.rs`：并行锁、取消与结果封装。
- `codex-rs/core/src/tools/approvals.rs`：审批路由、hook 与 Guardian。
- `codex-rs/core/src/tools/sandboxing.rs`：沙箱选择与审批要求。
- `codex-rs/core/src/mcp_tool_call.rs:2673-2704`：MCP 审批推断。
- `codex-rs/core/src/model_search.rs`：搜索提供方仲裁与所有者预留。
- `codex-rs/tools/src/tool_executor.rs:49-99`：暴露级别定义。
- `codex-rs/ext/extension-api/src/tool_policy.rs`：宿主工具策略。
- `codex-rs/core/src/stream_events_utils.rs:327-460`：输出项完成处理。
- `codex-rs/core/src/session/turn.rs:2779-2807`、`:2817-3310`、`:3665-3675`：采样循环与结果 drain。
- `codex-rs/config/src/mcp_types.rs:231-314`：MCP 服务器配置字段。
