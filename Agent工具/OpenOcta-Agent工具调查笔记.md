# OpenOcta Agent 工具调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态阅读 `chat.send` 工具装配、Eino DeepAgent 构建、工具中间件、参数守卫、审批中断与恢复、MCP 客户端、本地 CLI Agent、结果回注和检查点代码；未连接真实模型，也未执行工具
>
> 调查范围：模型可见工具的来源、目录发现、参数校验、编排循环、审批与执行边界、结果回注、MCP/Skill/子 Agent 旁路；排除单个业务工具的完整参数语义、前端工具卡渲染、Provider 传输细节和真实沙箱能力
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 工具循环由 Eino ADK 的 DeepAgent 和 Runner 驱动；OpenOcta 在这条链上装配工具集合、注入中间件、提供执行后端，并消费流式事件。Agent 的构建入口在 `src/pkg/agent/eino/engine.go:63-155`，网关从 `src/pkg/gateway/handlers/chat.go:1730` 开始消费流式输出。
- 模型可用的工具由多个来源合并而成：文件读写、编辑和 Shell 执行来自 Eino DeepAgent 自带的能力，网关配置、浏览器、本地 CLI Agent、MCP 工具、蜂群工具和知识库检索由 OpenOcta 追加，联网工具在编译期被开关关闭。
- 工具目录由 toolsearch 中间件动态暴露。触发阈值为 1，所以只要存在动态工具，基础工具列表就为空，全部工具都走动态检索路径；装配见 `src/pkg/agent/eino/engine.go:91-109`，阈值配置见 `src/pkg/agent/eino/context_middleware.go:149-155`。
- 参数校验插在模型调用与真实执行之间。守卫中间件规范化文件路径别名、校验 `execute` 的命令长度，并把无效 JSON 或截断参数当作工具输出回给模型，聊天层不抛中断；实现见 `src/pkg/agent/eino/tool_arguments_guard.go:22-128`。
- 审批只覆盖 `execute` 一个工具，且仅在审批队列配置显式开启时生效。命中后工具调用经 Eino 的中断机制暂停，等 `chat.resume` 带回批准结果再恢复执行；工具名登记在 `src/pkg/agent/eino/engine.go:100-102`，中断与恢复细节见 `src/pkg/agent/eino/approval_middleware.go:45-85`。
- 命令策略只把 deny 规则转成执行前校验器；allow 和 ask 规则在 Eino 路径中本次未找到查询点。旧实现中的 `EvaluateCommand` 只在测试中被引用。
- 工具执行发生在 Gateway 宿主进程的环境里。Shell 以当前用户的权限通过 `cmd.exe /c` 或系统 shell 启动，没有容器或操作系统级沙箱；文件写入时，相对路径和 Windows 盘根文件会被重定向到 workspace，`execute` 的工作目录却仍是 Gateway 进程的当前目录。
- 迭代上限为 50。聊天请求超时默认 10 分钟，可由环境变量或 `agents.defaults.timeoutSeconds` 覆盖；引擎内部的 RunContext 预算只读环境变量。检查点持久化在状态目录的 `checkpoints/` 下，支撑审批恢复和会话清理。

## 总体调用链

一次带工具的聊天回合可以概括为以下步骤：

1. `chat.send` 请求进入 `ChatSendHandler`，处理器解析会话键和模型，并确定 workspace、MCP 配置、员工 Prompt 与请求级资源过滤范围。
2. 处理器算出运行时指纹，据此从运行时池取出已有实例或新建一个。装配工具时先取默认工具，再依次追加本地 CLI Agent、MCP 和蜂群工具；见 `src/pkg/gateway/handlers/chat.go:2251-2315`。
3. `runtime.New` 完成工具过滤、系统提示、命令校验器和技能目录的准备工作，随后调用引擎构造函数；见 `src/pkg/agent/runtime/runtime.go:40-149`。
4. 引擎构造时创建本地文件系统与 Shell 后端，包装动态工具，搭好中间件链，再把 Agent 和检查点存储交给 Runner；见 `src/pkg/agent/eino/engine.go:76-146`。
5. Runner 执行 DeepAgent，模型产生工具调用后，中间件依次完成参数校验、审批中断和实际执行。
6. 工具结果以流事件回到 `ChatSendHandler`，处理器广播工具事件、写入 transcript 的 toolResult，再把最终文本和附件合并进助手消息；见 `src/pkg/gateway/handlers/chat.go:2644-2843`。

## 1. 工具来源与注册

### 来源总表

| 来源 | 代表工具 | 注册位置 | 生效条件 |
|---|---|---|---|
| Eino DeepAgent 内置 | 文件读取、写入、编辑、Shell 执行 | DeepAgent 构建 | 工具未整体禁用 |
| OpenOcta 桥接 | `gateway_config` | `DefaultToolsWithInvoker` | 存在 Gateway invoker |
| 浏览器 | `browser` | `BrowserToolsFromConfig` | 浏览器未显式禁用，默认启用 |
| MCP | 各服务器暴露的工具 | MCP Manager 与上下文工具回调 | 配置了启用的服务器 |
| 本地 CLI Agent | `local_agent` | `AppendLocalAgentToolsForSession` | `localAgents` 默认启用 |
| 蜂群 | `swarm_member_create`、`swarm_message_send` | `SwarmTools` | Agent-to-Agent 开启 |
| 知识库 | `memory_search` | `KnowledgeTools` | 知识库配置启用 |
| 联网 | `web_search`、`web_fetch` | 定义存在但被关闭 | 编译期常量恒为 false |

### DeepAgent 内置工具

`engine.go` 把本地后端同时作为文件系统、Shell 和流式 Shell 传给 DeepAgent。文件读写、编辑和命令执行由 Eino 的 DeepAgent 提供，OpenOcta 不逐个注册这些工具；后端实现见 `src/pkg/agent/eino/localbackend/backend.go:13-45`，装配见 `src/pkg/agent/eino/engine.go:116-131`。

`write_todos` 默认关闭，只有环境变量 `OPENOCTA_DEEP_AGENT_TODOS` 为真时才启用，见 `src/pkg/agent/eino/engine.go:125` 与 `157-163`。

### OpenOcta 自有工具

`DefaultToolsWithInvoker` 当前只返回 `gateway_config`，没有返回文档中描述的 echo、cron 或 sessions 工具，见 `src/pkg/agent/tools/bridge.go:62-74`。这三个工具类型仍存在于 `src/pkg/agent/tools`，但 `chat.send` 主链没有注册它们。

`browser` 工具默认可用，除非配置显式关闭浏览器，见 `src/pkg/agent/tools/browser_tool.go:40-52` 与 `src/pkg/agent/runtime/runtime.go:367-372`。

### 联网工具

`web_search` 和 `web_fetch` 的工具实现仍在仓库中，但 `webToolsEnabled` 是编译期常量 false，运行时注册函数也直接返回 false，见 `src/pkg/agent/tools/web_tools.go:47-52` 与 `src/pkg/agent/runtime/runtime.go:362-365`。按当前快照，模型无法通过这两个工具访问网络。

### MCP 工具

MCP 工具进入运行时有两条路径：上下文回调提供的工具，以及运行时池创建阶段由 MCP Manager 新建连接后列出的工具。两者都会去重后加入同一工具列表，见 `src/pkg/gateway/handlers/chat.go:2278-2302`。

### 本地 CLI Agent 与蜂群

`local_agent` 在 `localAgents` 启用时追加，默认启用，见 `src/pkg/agent/tools/local_agent_tool.go:162-176`。蜂群工具只在 Agent-to-Agent 开启时追加，见 `src/pkg/gateway/handlers/chat.go:2304-2308`。

## 2. 工具发现、过滤与注入

### 动态检索

中间件配置中 `minToolSearchTools` 为 1，`enableToolSearch` 默认为 true，见 `src/pkg/agent/eino/context_middleware.go:30-36` 与同文件 `98-112`。因此只要动态工具数量达到 1，检索开关就为真，基础工具列表为空，全部工具交给 toolsearch 中间件，见 `src/pkg/agent/eino/engine.go:91-109`。

这意味着模型看到的检索结果由中间件按需暴露，工具按需检索，而不是一次性注入完整工具目录。目录规模和 token 控制由该中间件负责，`chat.send` 只提供候选工具集合。

### 请求级过滤

请求资源先筛选技能候选和 MCP 服务，但结果并非执行端白名单。MCP 筛选结果只要非空，后续合并就重新补入全部全局启用服务；上下文工具回调也只由“名单是否非空”控制，没有逐服务筛选（`src/pkg/gateway/handlers/chat_runtime_pool.go:55-77`、`chat.go:2278-2302`）。

技能侧先筛条目、最后只把目录传给中间件：普通会话可能返回整个工作区技能根，员工分支先返回某个技能自身目录。条目名单未传入中间件，实际可见集合不能仅据请求键推断，详见角色笔记（`src/pkg/agent/eino/skills.go:18-65`）。

### 技能中间件

技能不是普通工具，但会向模型注入技能说明和调用入口。运行时解析技能目录后，Eino 构建技能中间件；见 `src/pkg/agent/eino/context_middleware.go:157-169`。如果技能中间件未激活，运行时会把技能段落直接拼进系统提示作为回退，见 `src/pkg/agent/runtime/runtime.go:87-93`。

### 文档差异

`docs/tools-openocta.md` 声称默认工具包含 echo、cron、gateway_config 和 sessions；`docs/tools-builtin.md` 则引用不存在的内置工具文件和 agentsdk-go 工具集。当前代码快照使用 Eino DeepAgent，而不是文档描述的 agentsdk-go 内置工具层；本笔记以可执行路径为准。

## 3. 模型调用表示与 Provider 适配

工具调用使用 Eino 的原生工具调用表示，由 Provider Adapter 转换为各模型的 `tool_calls` 或等价结构。OpenOcta 不实现文本协议解析，也不在聊天层重新解析模型输出。

聊天处理器消费 `content_block_start` 中的 `tool_use` 块和 `tool_execution_start` 事件，把工具名、调用 ID 和参数写入助手消息，并广播给前端；见 `src/pkg/gateway/handlers/chat.go:2691-2750`。参数在写入前会经过 `NormalizeToolCallArgumentsRaw`，避免把畸形 JSON 直接交给前端。

Provider 差异集中在模型工厂和 Eino 适配层，工具循环本身不区分 Provider。此次未展开各 Provider 对并行工具调用、思考块和流式增量格式的差异。

## 4. 参数解析、校验与错误处理

### 校验位置

工具参数在进入实际工具前经过守卫中间件。核心函数 `PrepareToolCallArgumentsJSON` 先检查空值和 JSON 合法性，再对 `execute` 与文件系统工具做专项处理，见 `src/pkg/agent/eino/tool_arguments_guard.go:22-45`。

### 规则

| 工具类别 | 处理 |
|---|---|
| 所有工具 | 空参数或非法 JSON 被判为无效 |
| `execute` | `command` 不能为空，长度上限 4096 个字符 |
| `read_file`、`write_file`、`edit_file` | 把 `path`、`file`、`filename` 等别名统一为 `file_path` |
| 文件工具 | 拒绝空路径、`.` 和当前目录 |

规则实现见 `src/pkg/agent/eino/tool_arguments_guard.go:53-112`。`execute` 的超长错误会提示模型先写脚本文件再执行，见同文件 `105-110`。

### 失败反馈

参数错误不会抛出到聊天层，而是被格式化为工具输出返回模型。代码会区分截断 JSON 和一般非法 JSON，并生成不同的提示文本，见 `src/pkg/agent/eino/tool_arguments_guard.go:114-128`。因此模型有机会在同一回合内修正参数并重试。

### 退出码语义

Shell 非零退出码不会作为 Go 错误向上抛出。Windows 后端把退出码、stdout 和 stderr 组合成正常输出并返回 `ExecuteResponse`，见 `src/pkg/agent/eino/localbackend/shell_windows.go:50-75`。模型需要从输出文本和退出码自行判断失败；聊天层不会自动把非零退出标记为工具错误。

## 5. 编排循环、并发与终止

### 循环所有者

循环由 Eino Runner 和 TurnLoop 驱动。`Engine.RunStream` 构造消息并调用 Runner，`ResumeStream` 用检查点 ID 恢复中断的回合，见 `src/pkg/agent/eino/runner.go:60-98`。

运行时池按 sessionKey 和指纹复用实例，因此同一会话的工具循环状态可以跨请求保留在检查点中。并发请求使用不同的 run ID 和中断控制器；`ChatSendHandler` 为每个 run 注册中止函数，见 `src/pkg/gateway/handlers/chat.go:2374-2379`。

### 上限

| 限制项 | 取值 | 覆盖方式与实现位置 |
|---|---|---|
| 迭代上限 | 固定 50 | 运行时构造和引擎构造都写入该值；`src/pkg/agent/runtime/runtime.go:136`、`src/pkg/agent/eino/engine.go:111-114` |
| 聊天请求超时 | 默认 10 分钟 | 可用环境变量 `OPENOCTA_AGENT_RUN_TIMEOUT` 或配置项 `agents.defaults.timeoutSeconds` 覆盖；`src/pkg/gateway/handlers/chat.go:2018-2040`、`src/pkg/agent/runtime/timeouts.go:11-27` |
| 引擎运行预算 | 运行时选项优先，其次读环境变量，最后回退 10 分钟 | 配置字段不参与这条路径；`src/pkg/agent/runtime/runtime.go:461-470` |
| 预算传递 | 经 RunContext 包装 | 传入 TurnLoop；`src/pkg/agent/eino/session_turn_loop.go:477-481` |

### 取消与超时

聊天层通过上下文取消和中止控制器结束运行。工具执行本身没有统一的逐工具超时；`execute` 继承运行上下文，MCP 调用没有读取配置中的请求超时，本地 CLI Agent 有独立的默认超时。

## 6. 审批、授权与执行边界

### 审批触发

审批中间件只登记 `execute` 一个工具名，见 `src/pkg/agent/eino/engine.go:100-102`。它不按风险分级，也不按命令内容判断，只要审批开关打开且工具名为 `execute`，首次调用就会触发 interrupt。

审批开关来自 `security.approvalQueue.enabled` 显式为 true，见 `src/pkg/agent/runtime/runtime.go:189-195` 与 `src/pkg/gateway/handlers/chat.go:2343`。

### 中断与恢复

中间件在首次调用时保存参数并返回 `StatefulInterrupt`。恢复时读取审批结果：批准则用保存的参数执行，拒绝则把拒绝原因作为工具输出返回模型，见 `src/pkg/agent/eino/approval_middleware.go:58-85`。

`chat.resume` 接收运行 ID、批准结果、理由以及中断目标与上下文，构造 `TurnApproval` 后调用运行时恢复流，见 `src/pkg/gateway/handlers/chat.go:3709-3725` 与 `3812-3818`。恢复要求目标集合非空，见 `src/pkg/agent/eino/runner.go:79-81`。

### 命令策略

命令策略在运行时构造时转换为执行前校验器，只把 deny 规则和参数限制写入校验器，见 `src/pkg/agent/runtime/runtime.go:104-114` 与 `src/pkg/agent/runtime/command_policy.go:305-327`。

`EvaluateCommand` 和 `EvaluateCommandAccess` 可以返回 allow、ask 或 deny，但本次只在测试中找到调用，未在 Eino 执行路径中找到生产调用者。审批队列开启时，allow、ask、deny 列表还会被写入 workspace 下的 `.claude/settings.json`，见 `src/pkg/agent/runtime/runtime.go:151-159` 与 `400-450`；该文件服务于旧 SDK 兼容，不是当前 Eino 审批中间件的输入。

### 执行域与隔离

Shell 后端直接使用当前进程用户的权限启动命令。Windows 使用 `cmd.exe /c`，见 `src/pkg/agent/eino/localbackend/shell_windows.go:22-44`；Unix 交给 Eino 本地后端，见 `src/pkg/agent/eino/localbackend/shell_unix.go:12-25`。

后端没有容器、命名空间、用户切换或系统调用过滤。`Options.EnableSandbox` 字段存在，但检查 `src/pkg/agent/runtime` 与 `src/pkg/agent/eino` 的构建路径后未找到读取点；`runtime.Options` 中的同名布尔值也没有参与引擎构建。文件写入的相对路径会解析到 workspace，Windows 盘根文件会被重定向到 workspace，见 `src/pkg/agent/eino/localbackend/paths.go:15-77`；这属于路径整理，不是执行隔离。

`execute` 的 `cmd.Dir` 没有被设置，因此命令运行在 Gateway 进程的当前目录，而不是 Agent workspace。命令在启动前还会被折叠为单行：Windows 把换行替换为空格，Unix 用 `&&` 连接多行，见 `src/pkg/agent/eino/localbackend/command_normalize.go:14-37`。文件工具与 Shell 的工作目录语义因此并不一致。

### 本地 CLI Agent 的审批缺口

本地 CLI Agent 的委派由 `local_agent` 工具发起，而审批中间件只登记了 `execute`，因此这条路径不会触发审批中断。配置里虽有 `localAgents.requireApproval` 字段，但检查 `src/pkg/localagents`、`src/pkg/agent/tools` 与 `src/pkg/gateway/handlers` 后，三处都没有找到读取它的代码。

## 7. 结果回注、状态与恢复

### 事件到消息

工具执行开始时，处理器记录开始时间并写入工具调用块。执行结束时，处理器格式化输出、广播 `tool_result`，并生成一条 `role: toolResult` 的 transcript 记录，见 `src/pkg/gateway/handlers/chat.go:2730-2806`。

工具结果中的附件标记会被剥离，可交付文件会转换成附件块同时进入助手消息和工具结果，见 `src/pkg/gateway/handlers/chat.go:2774-2791`。这使写入文件或生成图片的工具结果可以在聊天中直接展示。

### 错误与中断

工具错误通过 `isError` 字段进入事件和 transcript，而不是终止整个回合。审批中断会广播 `EventRunInterrupted` 并把 `stopReason` 设为 interrupt，见 `src/pkg/gateway/handlers/chat.go:2811-2817`。

如果历史中的工具调用回合缺少结果，Eino 适配层会插入占位工具结果，避免下一次请求因消息结构不完整失败，见 `src/pkg/agent/eino/tool_call_arguments.go:63-110`。

### 检查点

检查点存储默认使用文件实现，位于状态目录的 `checkpoints/`，见 `src/pkg/agent/eino/file_checkpoint_store.go:12-27`。Runner 和 TurnLoop 使用不同前缀的检查点 ID，会话清理时同时删除两类记录，见 `src/pkg/agent/eino/checkpoint.go:14-46`。

### 输出长度

聊天层在写入 transcript 和广播时没有统一的工具输出长度上限，`formatStreamToolResultOutput` 只是把字符串、map 或 JSON 转成文本，见 `src/pkg/gateway/handlers/chat.go:255-289`。上下文长度控制由 Eino 的压缩和裁剪中间件负责，而不是工具结果落盘层。

## 8. MCP、插件、Skill 与子 Agent

### MCP

MCP 客户端支持 stdio 与 URL 连接。URL 路径以 `/sse` 结尾时使用 SSE，否则优先 streamable HTTP，连接失败后再回退 SSE，见 `src/pkg/acp/mcp/client.go:72-126`。

Manager 逐个连接启用的服务器，单个失败只记录日志并跳过，见 `src/pkg/acp/mcp/manager.go:27-48`。工具名支持可选前缀，但 `NewManager` 没有给 `m.cfg` 赋值，前缀查询始终返回空，见同文件 `19-22`、`125-143`。因此同名工具跨服务器时可能冲突，实际去重行为取决于工具列表合并顺序。

MCP 配置中的全局请求超时和工具调用超时字段本次未找到使用点；`acp/mcp` 包内没有读取这些配置。

### Skill

技能通过 Eino 技能中间件向模型提供说明和调用入口，目录由 `ResolveSkillsDir` 解析，见 `src/pkg/agent/eino/skills.go:12-65`。技能本身可以指示模型调用 `execute` 或脚本，因此它不是独立执行域，仍受同一审批和命令校验约束。

### 子 Agent

蜂群工具由 `SwarmTools` 提供，包含创建直接子成员和发送消息两个入口，见 `src/pkg/gateway/handlers/swarm_tools.go:17-125`。硬上限为每个成员 5 个直接子成员、10 层树深、每个工作区 55 个成员，见 `src/pkg/swarm/limits.go:5-10`。

子 Agent 复用宿主运行时和工具链，不是外部进程。其 sessionKey 由蜂群专用构造函数生成，见 `src/pkg/swarm/session_key.go:11-46`。

### 本地 CLI Agent

`local_agent` 支持状态探测、单任务执行和多任务并行执行，见 `src/pkg/agent/tools/local_agent_tool.go:22-78`。执行器通过 PATH 和常见安装路径探测可执行文件，见 `src/pkg/localagents/probe.go:51-110`；实际调用使用 `exec.CommandContext` 并缓冲 stdout/stderr，见 `src/pkg/localagents/runner.go:63-110`。

默认超时为 10 分钟，可由 `localAgents.timeoutSeconds` 覆盖，见 `src/pkg/localagents/runner.go:22-29`。输出在进程结束后一次性返回，没有流式回传、会话映射、取消到真实子进程之外的恢复机制，也没有逐次审批。

## 9. 设计取舍与已确认边界

- **循环交给框架**：执行、迭代和中断恢复都由 Eino 负责，OpenOcta 只在中间件层补充策略。好处是协议适配和检查点能力集中，代价是工具行为受框架中间件顺序约束。
- **动态目录优先**：toolsearch 阈值设为 1，实际效果是所有工具都走动态检索。上下文占用因此可控，而当前请求实际注入了哪些工具，要观察运行时检索结果才能确定。
- **参数错误软失败**：非法参数作为工具输出返回模型，模型可以在同一回合修正，聊天层不会出现显式错误状态。模型若忽略错误文本，可能继续生成看似成功的回复。
- **审批粒度粗**：只按工具名拦截 `execute`，不区分命令内容、工作目录或风险级别。`local_agent`、MCP 工具和文件写入都不在审批范围内。
- **策略分层不完整**：deny 规则进入执行前校验器，allow 和 ask 规则只写入旧 SDK 设置文件，Eino 路径实际只执行“deny 拦截 + execute 全量审批”两种控制。
- **执行边界是宿主进程**：没有容器、用户隔离或资源配额。文件路径整理只改变写入位置，读取位置不受限制；`execute` 还能访问工作区之外的路径。
- **结果预算后置**：工具输出在本层不截断，长度控制交给上下文压缩。大输出可能先占住上下文，再交给压缩中间件处理。
- **文档滞后于实现**：内置工具文档仍按 agentsdk-go 工具集描述默认工具，把 echo、cron 和 sessions 列为默认注册项；当前实现使用 Eino DeepAgent，默认工具集为空。

## 10. 未验证事项

- 未连接真实模型，未验证 toolsearch 中间件实际暴露的工具目录、检索提示和模型选择行为。
- 未验证审批中断在真实 UI 中的待处理状态、超时和多次恢复行为。
- 未验证 MCP 服务器连接失败、工具名冲突和长时调用的实际表现。
- 未验证 `local_agent` 在各平台探测路径、参数拼接和并行执行时的真实输出。
- 未验证 Windows 下 `cmd.exe /c` 对多行命令、引号和编码的处理。
- 未验证命令策略 deny 规则对复合命令、管道和参数的实际拦截范围。
- 未验证检查点在进程重启后的恢复成功率，以及不同 Eino 版本间的兼容性。

## 关键源码索引

- 聊天入口与工具装配：`src/pkg/gateway/handlers/chat.go:1730`、`2251-2315`
- 运行时构造与预算：`src/pkg/agent/runtime/runtime.go:40-149`、`461-470`
- DeepAgent 与中间件：`src/pkg/agent/eino/engine.go:63-155`
- 动态工具检索与技能中间件：`src/pkg/agent/eino/context_middleware.go:30-36`、`138-169`
- 参数守卫：`src/pkg/agent/eino/tool_arguments_guard.go:22-128`
- 审批中间件：`src/pkg/agent/eino/approval_middleware.go:25-123`
- 审批恢复入口：`src/pkg/gateway/handlers/chat.go:3677-3839`
- 流式事件与结果落盘：`src/pkg/gateway/handlers/chat.go:2644-2843`
- 本地执行后端：`src/pkg/agent/eino/localbackend/backend.go:13-45`、`shell_windows.go:22-75`、`paths.go:15-77`
- MCP：`src/pkg/acp/mcp/manager.go:27-143`、`client.go:72-126`
- 本地 CLI Agent：`src/pkg/agent/tools/local_agent_tool.go:22-176`、`src/pkg/localagents/runner.go:22-110`
- 蜂群工具与上限：`src/pkg/gateway/handlers/swarm_tools.go:17-125`、`src/pkg/swarm/limits.go:5-10`
- 检查点：`src/pkg/agent/eino/file_checkpoint_store.go:12-27`、`src/pkg/agent/eino/checkpoint.go:14-46`
