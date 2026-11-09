# DeepSeek Harness 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：静态源码阅读，覆盖 subagent 服务与六个 provider、MCP 客户端/管理/资源包、ACP 服务器、hooks 双桥与 Claude Code mods 桥、subprocess/terminal/shell、PTC runtime、POSIX SSH provider 家族、forge/liveshare/webhook/plugin-market 等对外协作包；辅以 `docs/subsystems/` 与 `docs/upgrade-guide/`；未运行任何外部 Agent、真实 CLI 或协议往返
>
> 调查范围：进程外 subagent provider 的启动/通信/取消与激活模型、MCP 客户端桥、ACP 服务器反向主链、Claude Code/Codex hooks 桥与 mods 兼容层、持久化终端与进程/沙箱执行边界、SSH 远端执行世界、CLI 作为入口，以及 forge/liveshare/webhook 等对外协作面；排除复用宿主 runtime 的进程内 spawn/fork provider 内部细节、普通 LLM Provider、Web 应用、workflow 与 lsp
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 是 DeepSeek AI 官方的 agent harness，一切能力都是 Cordis 插件。本仓库的对外协作以四条互相独立的主链呈现，均达到主链确认（静态证据）：

- **外部执行体委派（宿主 → 外部进程 Agent）**：`ctx.subagents` 注册表下的 `acp`、`claude-code`、`codex`、`dsh-sdk` 四个后端把外部 Agent 作为**一次性执行体**启动、通信、取消并回收最终文本；每次委派统一返回「激活」句柄，模型立即拿到子 Agent id，最终答案以父 Agent 的完成通知回传（`packages/subagent/subagent/src/{index,manager}.ts`）。
- **反向控制表面（外部客户端 → 宿主 Agent）**：`packages/acp/acp` 的标准 ACP v1 服务器经 JSON-RPC stdio 暴露持久宿主会话，支持创建/恢复、模型与思考等级选择、挂载 MCP server、提交与取消、语义更新与独立关闭。
- **外部协议兼容层**：MCP 客户端桥把外部 server 工具以 `mcp__<serverName>__<rawName>` 注册进宿主工具表并带代际重连；hooks 双桥在扩展点上按 Claude Code/Codex 的 hooks.json 契约运行外部命令；新增的 Claude Code mods 兼容层把 mod 形式的 hooks 模块作为普通 DSH 插件挂载。
- **远端执行世界**：POSIX SSH provider 家族用一条部署自管的 OpenSSH 连接把 fs、subprocess、sandbox、terminal、LSP 与 PTC 映射到同一远端主机，Harness、模型传输与会话存储留在本机（`packages/ssh/*`、`docs/subsystems/ssh.md`）。E2B 远程沙箱已从仓库移除。

另有四条**对外协作面**（非 Agent 委派）：forge 读代码托管平台的变更请求、LiveShare 把单个会话共享给外部观看者、webhook 把已认证外部投递变成普通根会话、plugin-market 经市场索引分发插件包。它们都默认不装载，需要显式组合或 profile 选择。

## 接入角色与系统边界

| 接入角色 | 本仓库对象 | 协议方向与执行位置 |
|---|---|---|
| 外部执行体 | 四个进程外 subagent provider 的子进程 | 宿主启动、观察、取消外部 Agent；工具循环在子进程，结果一次性回传 |
| 外部控制表面（反向） | ACP 服务器暴露的宿主 Agent 会话 | 外部客户端经 stdio JSON-RPC 驱动宿主工具循环 |
| 外部工具服务 | MCP server（stdio 或 streamable-http） | 宿主桥接其工具与资源；凭据与状态由 mcp-manager 管理 |
| 外部命令执行体 | Claude Code/Codex hooks.json 中的命令、Claude Code mod 的 hooks 模块 | 宿主在扩展点按协议调度，经 `ctx.shell` 沙箱执行 |
| 外部协作端 | forge 托管平台、LiveShare 观看端、webhook 投递方 | 宿主按 provider 契约读写；不改变 Agent 循环 |

- 进程内 `spawn`/`fork` provider 创建普通宿主 Agent（独立 preset、深度、可续会话全部支持），与外部执行体分属两侧：前者复用宿主 agent-loop 与 durable 会话，后者各自拥有进程与工具循环且**只执行一次**。
- SSH 是"宿主进程之外的远端执行域"，但不是外部 Agent：它是 fs/subprocess/sandbox/terminal/PTC 的 provider 实现，属执行边界而非委派主链。
- hooks 命令本身是宿主调度的一次性命令进程，没有自己的 Agent 工具循环，作为"外部工具链协议兼容"样本记录，不单列主链。

## 完整主链

**主链 A：subagent 外部委派**（六个后端共享激活契约，以外部 provider 为代表）：

```text
模型调用 tool-subagent 注册的 subagent 工具
  -> ctx.subagents.startActivation({ provider, request: { parent, prompt, cwd? }, signal, delivery })
  -> 服务按能力旗标校验请求字段（外部 provider 的 agentOptions/continuable 均为 false）
  -> prepareContinuable（本地）或 start（外部）分派到 provider
  -> provider 经 ctx.subprocess 组装 spawn spec：argv/cwd/擦除后的 env，启动子进程
  -> 协议握手：ACP initialize -> session/new（可挂 MCP）-> prompt
  -> 子进程运行自身工具循环，文本块回流累加最终文本
  -> stopReason 映射为 SubagentResult（永不 reject，diagnostic 上限 4KB）
  -> 工具立即返回激活句柄与 subagentId；结算后向父 Agent 投递完成通知
  -> 取消：dispose()/中断 -> 本地先结算（保留部分文本）-> 远端 cancel -> stdin EOF
     -> 树级 SIGTERM -> grace -> SIGKILL，waitForExit 证明整树静止
```

外部 provider 只回传最终文本，不回流推理、工具事件或文件变化；本地 spawn/fork 子 Agent 拥有 durable 会话，可在结算后继续接收消息（`send_message`）。控制工具集中在 `tool-subagent-control`：`send_message`、`interrupt_agent`、`list_agents`、`wait_agent`。

**主链 B：ACP 服务器反向控制**：

```text
外部客户端（编辑器、脚本、或宿主自己的 subagent-acp provider）
  -> JSON-RPC stdio initialize（标准 ACP v1）
  -> session/new 或 session/load（恢复持久会话，可选 MCP server 与模型/思考等级）
  -> session/prompt -> 宿主 agent 进入 agent-loop 与工具循环
  -> 宿主 session/event 投影为语义更新（只发已提交文本与工具状态）
  -> turn/end 结算 stopReason 并返回
  -> session/cancel -> 结算为 cancelled
  -> 连接关闭 -> quiesce：逐会话 cancel -> 排水后代 -> dispose 全部 Agent
```

服务器只暴露标准 ACP v1 面：创建/恢复/列出/关闭会话、模型与思考等级、MCP 挂载、提交与取消。删除、fork、transcript 重放与附加目录不支持；每次 create 使用配置的默认 provider/model 或由请求监听器提供。

**主链 C：MCP 工具桥**：

```text
插件加载（mcp-client 实例，serverName 唯一性校验；状态由 mcp-manager 汇总）
  -> connection.ts：spawn stdio server 或连接 streamable-http，带 deadline 与 probe
  -> 两阶段换代同步：先取完整 tools/list 分页并构建定义（不动注册表）
     -> 再整代注册/注销，冲突回滚（全有或全无），generation 记录当前代
  -> 模型调用 mcp__<serverName>__<rawName>，执行器只把 rawName 发上 wire（tools/call）
  -> isError 结果转 throw -> ToolRuntime 产出 isError 结果
  -> 断线 -> 有界指数退避重连 -> 新代际重新同步；耗尽预算则注销工具并停止
  -> 资源面由 mcp-resources 暴露 list/read/template 三个共享工具
```

**主链 D：hooks 与 mods 兼容层**：

```text
profile 配置 hooks.json 来源（进程级一次性读取，configPath 单一来源）
  -> hook-protocol 解析 matcher 与 stdin/exit-code/stdout 编解码
  -> Claude Code / Codex 桥在宿主扩展点（pre/post tool、user prompt 等）匹配
  -> 经 ctx.shell 以沙箱执行外部命令，标准输入/输出按各自契约编码
  -> hook/invoked 与 hook/result 事件成对落盘，作为审计而非模型历史

Claude Code mod（defineMod({ name, version, root, userConfig, register })）
  -> 作为普通 DSH 插件行挂载，register 的 hooks 模块在注册期求值
  -> 不读 plugin.json/hooks.json；tier 一律按 user 处理，next.to 拒绝
  -> 宿主未触发的 hook 事件在 mod 加载时给出 warning；未实现的 $ 调用直接拒绝
```

## 1. 外部执行体：subagent 服务与后端

**服务契约**：一个委派契约、多种执行位置。`ctx.subagents` 持有子 Agent 树（祖先、运行时归属、通信），每个后端以配置名注册；委派工具每次只选一个 provider。能力旗标决定请求字段是否合法：外部后端的 `agentOptions`、`continuable`、`inheritsParentContext` 均为 false，因此模型选型与后续消息只对本地子 Agent 生效。

**激活语义**：所有后端都走 `startActivation`。本地 provider 只提供创建输入（`prepareContinuable()`），执行归服务；`delivery: 'caller'` 时可等待激活结果而不向父 Agent 注入消息，`delivery: 'parent'` 是模型工具使用的路径。回调收尾用 `dispose()`：启动 signal 在发布后不再拥有取消权，必须保留回执并按收据取消。

**外部 provider 四个加一个实验**：

| Provider | 外部对象 | 握手与结果 | 备注 |
|---|---|---|---|
| `acp` | 任意 ACP Agent | initialize → session/new → prompt；文本块累加 | 与本仓库 ACP 服务器互为镜像 |
| `claude-code` | Claude Code 真实 CLI | CLI 原生流式输出解析 | 需安装 CLI；目录配置经 working-directory 迁移 |
| `codex` | Codex app-server | app-server JSON-RPC | 一次性执行 |
| `dsh-sdk` | 另一个 harness 进程 | DSH 自有 JSON-RPC；要求目标二进制支持 `session/wait` | 可指向远端 harness |
| `oar`（实验） | OAR 运行时 | 由 `@botiverse/oar` 驱动的一次性执行 | `packages/experimental/subagent-oar` |

**进程与取消**：进程机制归 `dsh-subprocess` seam（spawn、环境擦除、受管范围 teardown），provider 只做协议与结果收口；诊断文本截断到 4096 字节。取消是"本地先结算、远端尽力"，随后按树级 SIGTERM → grace → SIGKILL 收尾，`waitForExit` 证明整树静止。

**深度与隔离**：委派深度由 delegation 配置与 `depth.ts` 管控；子 Agent 继承父的 permission roots（或钉死更严格档），启动时注入 delegation-scope 发布。委派策略固定、以 `source: 'delegation'` 写入子会话日志，可重放。

## 2. 反向控制：ACP 服务器

- **协议面**：标准 ACP v1，经 stdio JSON-RPC；stdout 只承载协议流量。实现文件 `packages/acp/acp/src/{codec,content,mcp,model-control,session,updates}.ts`。
- **会话生命周期**：创建、恢复、列出与独立关闭；持久化跨进程重启可用。每会话拥有自己的 Agent 与工具循环，关闭不依赖连接整体退出。
- **能力边界**：不支持删除、fork、transcript 重放与附加目录；不暴露 DSH 专有的呈现卡、plan、标题、todo、终端视图与 elicitation。需要这些内容的客户端应使用 Web/headless 面。
- **取消与静默**：`session/cancel` 结算为 cancelled；连接关闭触发 quiesce——逐会话 cancel、排水 continuable 后代、dispose 全部 Agent。

## 3. MCP：客户端桥、管理器与资源面

- **客户端桥**（`packages/mcp/mcp-client`）：每插件实例一个服务器，激活阻塞到首次连接与工具发现完成；传输支持 stdio 子进程与 streamable-http。源码按职责拆为 connection、generation、deadline、probe、transport、credentials、status、templates 等模块，工具同步集中在 `tools.ts`。
- **命名与冲突**：模型可见名 `mcp__<serverName>__<rawName>`，受长度与字符集约束并追加身份哈希；调用只发服务器原始名。同名工具冲突按整代回滚，不留半套注册。
- **重连**：断线后按有界指数退避重连，每代重新同步；消耗完预算则撤销该服务器全部工具并停止重试。
- **管理器**（`packages/mcp/mcp-manager`）：汇总各服务器状态与配置面，供设置界面与工具使用；凭据经 `credentials.ts` 走凭据 seam，不落明文配置。
- **资源面**（`packages/mcp/mcp-resources`）：`list_mcp_resources`、`list_mcp_resource_templates`、`read_mcp_resource` 三个共享工具；按调用 Agent 的 scope 解析服务器，文本与元数据进结果，base64 blob 只给长度说明。

## 4. hooks 双桥与 Claude Code mods 兼容层

- **协议共享**：`hook-protocol` 提供 matcher 引擎、stdin/exit-code/stdout 编解码、多 hook 合并与 `hook/invoked`、`hook/result` 事件；Claude Code 与 Codex 两个桥各自实现各自的事件名与字段映射。
- **执行方式**：hook 命令经 `ctx.shell` 在沙箱内执行，继承当前会话的目录与策略；`detached.ts` 处理需要脱离主流程的命令。
- **配置来源**：`configPath` 是进程级一次性读取，没有 per-session 项目内 hooks.json 发现；这是已确认的边界。
- **代码位置**：三包现在位于 `packages/experimental/{hook-protocol,hooks-claude-code,hooks-codex}`，包名仍为 `@deepseek-ai/dsh-hook-protocol`、`dsh-hooks-claude-code`、`dsh-hooks-codex`。
- **mods 兼容层**（新增，`packages/experimental/claude-code-mods`）：把 Claude Code mod 的 hooks 模块包成 `defineMod()` 规格，作为普通 DSH 插件行挂载。与 Claude Code 的差异集中记录在 `docs/subsystems/claude-code-mods.md`：不读 `plugin.json`/`hooks.json`，tier 一律按 user，`next.to` 拒绝，热重载与 `claude plugin` 系列命令没有对应物，测试用 `createModTestKit` 替代。

## 5. 执行边界：subprocess、PTY、沙箱与 PTC

- **subprocess seam**：`subprocess-local`（本机）与 `subprocess-ssh`（远端）共享同一 API；`win32-process` 提供 Windows 进程树控制。子进程输出保留尾窗口与完整流 spill 路径。
- **PTY**：`terminal` seam 加 `terminal-bash` 后端，模型面工具在 `packages/experimental/tool-terminal`；持久 shell 由 `tool-bash-persistent`/`tool-pwsh-persistent` 提供，挂在同一 PTY 之上。终端会话只在进程内存活，不进日志。
- **沙箱**：`sandbox` seam 与 `sandbox-local`（bwrap/Landlock/macOS Seatbelt/Windows ACL 受限令牌）按平台选后端、运行期拒绝 fail-closed；`sandbox-ssh` 把同一策略应用到远端主机。
- **PTC runtime**：`ptc-runtime` seam 加 Node 实现（`ptc-runtime-node`），Python 实现在 `packages/experimental/ptc-runtime-python`；工具呈现改造后由独立执行器插件驱动（见 Agent 工具笔记）。
- **SSH 远端世界**：`ssh`（部署自管连接与 helper）、`ssh-helper-runtime`（内嵌 Node 与 PTC worker 的 helper）、`fs-ssh`、`subprocess-ssh`、`sandbox-ssh` 五个包。管理面 RPC 走 helper 的 exec 流，普通数据流走单独认证的转发 Unix socket；路径语义、执行查找与语言服务器 URL 都指向远端主机，`processPathFromHostPath()` 在 SSH 下不可用。连接断开视为未确认结果，不重连重放。

## 6. 对外协作面

- **forge**（`packages/experimental/forge*`）：默认禁用的 capability seam，`ctx.forge` 读代码托管平台的变更请求（PR/MR），`forge-github` 是 GitHub provider，`forge-session` 把变更请求绑定到会话并经 `ctx.forgeSession` 提供，`client-ui-forge` 提供面板；伴随 `worktree` 服务与 `create_worktree` 工具。
- **LiveShare**（`packages/experimental/liveshare`）：把单个会话共享给外部观看者。观看者请求由宿主读入并以观看者自己的 Peer 派发，`share-viewer` 主体经 remote-access 策略裁决，并把共享会话的执行限制在授权工作区内；观看者不获得 owner 工具。
- **webhook**（`packages/experimental/webhook*`）：provider 适配器负责认证与 JSON 入库，程序化规则决定条件与外部调用，`ctx.webhookRuntime` 管回调生命周期与基于工作区的根会话创建；不保存投递或完成状态，delivery id 只记录不幂等去重。
- **plugin-market / plugin-inventory**：市场索引与已装插件清单，配合 `plugin_manager` 做安装与启停。
- **browser-use 与 computer-use**：`packages/browser-use-*`（Playwright/Chrome DevTools MCP/Stagehand native）与 `packages/computer-use-*`（Cua、Cua macOS、Cua driver MCP/native）构成实验性执行面，模型工具在 `packages/experimental/`。

## 7. 设计取舍与已确认边界

- **一次性外部执行 vs 可续本地子 Agent**：外部 Agent 只回传最终文本、不接受后续消息，换取对任意 CLI/协议的兼容；需要多轮追问时只能用本地 spawn/fork。
- **激活模型取代前后台二选一**：委派不再区分"前台结果"与"后台 job"，统一返回激活句柄加完成通知，并保留 `delivery: 'caller'` 供程序化调用等待；代价是结果消费方必须处理异步通知。
- **协议兼容层用宿主沙箱执行外部命令**：hooks 与 mods 的命令受会话沙箱与审批约束，不复刻 Claude Code 的 managed settings 层级。
- **SSH 是传输而非安全边界**：远端文件效应由被选中的远端沙箱 provider 执行；连接丢失时如实报告未确认结果，不重连重放可能已执行的动作。
- **对外协作面默认关闭**：forge、liveshare、webhook、plugin-market 都需要显式组合或 profile 选择，避免默认暴露网络面。
- **委派能力边界**：仓库不含 E2B 远程沙箱包族与独立 `subagent-in-process-driver` 包，也没有 `backgroundMode`、`enableRunInBackground`、`run_in_background` 参数与用 `job_output` 收集子 Agent 的路径。

## 8. 未验证事项

- 未运行任何外部 Agent、真实 CLI 或协议往返：ACP 握手、Codex app-server、CLI 流式解析、取消时序均为静态确认。
- MCP 端到端（stdio/streamable-http 连接、重连退避、换代冲突回滚、凭据解析）未实测。
- hooks 的 stdin/stdout 编解码与 detached 行为的实际语义未运行验证；mods 桥的兼容差异只读了文档表。
- SSH 家族的 helper 安装、转发 socket 认证与远端路径语义未运行验证。
- forge/liveshare/webhook 的安全裁决细节只读了子系统页与入口，未逐行核对实现。
- 终端 PTY 在 Windows（ConPTY）与远端 SSH 下的行为属于运行观察项。

## 9. 关键源码索引

- subagent：`packages/subagent/subagent/src/{index,manager,out-of-process,child-agent,descriptor,depth,activation,lifecycle}.ts`、`tool-subagent/src/{index,preset-selection}.ts`、`tool-subagent-control/src/*`
- 外部 provider：`packages/subagent/subagent-{acp,claude-code,codex,dsh-sdk}/src/index.ts`、`packages/experimental/subagent-oar/src/*`
- ACP 服务器：`packages/acp/acp/src/{index,session,updates,mcp,model-control,codec,content}.ts`
- MCP：`packages/mcp/mcp-client/src/{connection,generation,tools,transport,deadline,probe,credentials,status,templates}.ts`、`mcp-manager/src/*`、`mcp-resources/src/*`
- hooks：`packages/experimental/hook-protocol/src/{runner,merge,matcher,codec,events,detached}.ts`、`hooks-claude-code/src/index.ts`、`hooks-codex/src/index.ts`
- mods：`packages/experimental/claude-code-mods/src/{index,define-mod,engine,host-ops,surfaces,matcher,module}.ts`
- 执行边界：`packages/subprocess/subprocess/src/index.ts`、`subprocess-local/src/spawn.ts`、`packages/terminal/terminal/src/index.ts`、`terminal-bash/src/{index,session,sanitize}.ts`、`packages/sandbox/sandbox-local/src/*`
- SSH：`packages/ssh/ssh/src/index.ts`、`ssh-helper-runtime/src/*`、`fs-ssh/src/*`、`subprocess-ssh/src/*`、`sandbox-ssh/src/*`
- PTC：`packages/ptc-runtime/ptc-runtime/src/index.ts`、`ptc-runtime-node/src/index.ts`、`packages/experimental/ptc-runtime-python/src/index.ts`
- 对外协作：`packages/experimental/forge*/src/*`、`liveshare/src/host/fork-enforcement.ts`、`webhook/src/*`、`packages/boot/plugin-market/src/*`
- CLI/入口：`packages/boot/cmdline/src/index.ts`、`apps/cli/src/bin.ts`、`apps/cli/reference/README.md`
- 文档：`docs/subsystems/{subagent,ssh,mcp,approval,claude-code-mods,forge,liveshare,webhook}.md`
