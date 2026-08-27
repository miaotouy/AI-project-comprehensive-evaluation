# DeepSeek Harness 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`（分支：`master`）
>
> 调查方式：静态源码阅读，覆盖 subagent 六个 provider、MCP 客户端桥、ACP 服务器、hooks 双桥与 hook-protocol、subprocess/terminal/shell 执行世界、code-runtime、E2B、boot/cmdline 与 apps/cli 入口及示例组装；未运行任何外部 Agent、真实 CLI 或协议往返
>
> 调查范围：进程外 subagent provider（ACP、Claude Code、Codex、dsh-sdk）的启动/通信/取消、MCP 客户端桥、ACP 服务器反向主链、Claude Code/Codex hooks 桥、持久化终端与进程/沙箱执行边界、CLI 作为入口；排除复用宿主 runtime 的进程内 spawn/fork provider、普通 LLM Provider、Web 应用、workflow 与 lsp
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 是 DeepSeek AI 官方的 agent harness，一切能力都是 Cordis 插件。本仓库的外部协作以三条互相独立的主链呈现，均达到 `主链确认`（静态证据）：

- **外部执行体委派（宿主 -> 外部进程 Agent）**：`ctx.subagents` 注册表下的四个进程外 provider 分别把外部 ACP Agent、Claude Code 真实 CLI、Codex app-server、自家 JSON-RPC 子进程作为一次性执行体启动、通信、取消并回收最终文本（准确包名见 `subagent` 组目录与文末索引）。进程内 `spawn`/`fork` 两个 provider 复用宿主 runtime，按类目规则属于宿主内建子 Agent，不进入本类目。
- **反向控制表面（外部客户端 -> 宿主 Agent）**：`packages/acp/acp` 的自动化 ACP 服务器经 JSON-RPC stdio 把全新宿主 Agent 会话暴露给程序化客户端，支持建会话、发 prompt、回传已提交文本、取消与一次性权限应答。
- **外部协议兼容层**：MCP 客户端桥把外部 server 工具以 `mcp__<serverName>__<rawName>` 命名注册进宿主工具表，带重连监督器；hooks 双桥在宿主扩展点上按 Claude Code/Codex 的 hooks.json 契约运行外部命令。

执行世界边界由 subprocess seam（进程树生命周期、SIGTERM->SIGKILL 升级、环境凭据擦除）、sandbox 策略、持久化 PTY 终端服务、code-runtime worker 与 E2B 远程沙箱 POC 共同承担；CLI（`dsh --profile headless|web` 与 `dsh plugin`）是部署入口。四进程外 provider 共享同一套"一次性 run、永不 reject 的结果、整树静止 teardown"契约，差异集中在各自协议与权限处理上。

## 接入角色与系统边界

| 接入角色 | 本仓库对象 | 协议方向与执行位置 |
|---|---|---|
| 外部执行体 | 四个进程外 subagent provider 的子进程 | 宿主启动、观察、取消外部 Agent；工具循环在子进程 |
| 外部控制表面（反向） | ACP 服务器暴露的宿主 Agent 会话 | 外部客户端经 stdio JSON-RPC 驱动宿主工具循环 |
| 外部工具服务 | MCP server（stdio 或 streamable-http） | 宿主桥接其工具；无账号/凭据/资源对象 |
| 外部命令执行体 | Claude Code/Codex hooks.json 中的命令 | 宿主在扩展点按协议调度，经 `ctx.shell` 沙箱执行 |

- 进程内 `spawn`/`fork` provider 创建普通宿主 Agent（深度、工具过滤、persona、continuable 全部支持），与外部执行体分属两侧：前者复用宿主 runtime 的 agent-loop，后者各自拥有进程与工具循环。
- E2B 是"宿主进程之外"的远程 Linux 沙箱执行域（fs/subprocess 适配器共享一个 sandbox 生命周期），但不是外部 Agent，属执行边界而非委派主链。
- hooks 命令本身是宿主调度的一次性命令进程，没有自己的 Agent 工具循环，作为"外部工具链协议兼容"样本记录，不单列主链。

## 完整主链

**主链 A：subagent 外部委派**（四 provider 共享骨架，以 ACP provider 为代表）：

```text
模型调用 tool-subagent 注册的 subagent 工具
  -> ctx.subagents.start('acp', { prompt, parent, signal })
  -> 服务校验能力（进程外 provider 全部能力为 false）、解析一次性 descriptor
  -> provider 组装 spawn spec：argv/cwd/擦除后的 env，经 ctx.subprocess.spawn 启动子进程
  -> 协议握手：ACP initialize -> session/new -> prompt
  -> 子进程运行自身工具循环，agent_message_chunk 回流累加最终文本
  -> stopReason 映射为 SubagentResult（result 永不 reject）
  -> 工具层 settleRun 落为 JobOutcome（completed/killed/failed）
  -> 取消：signal abort -> 本地先结算（保留部分文本）-> 远程 cancel -> stdin EOF
     -> 树级 SIGTERM -> grace -> SIGKILL，waitForExit 证明整树静止
```

**主链 B：ACP 服务器反向控制**：

```text
外部客户端（Zed/编辑器、脚本、或宿主自己的 subagent-acp provider）
  -> JSON-RPC stdio initialize（声明无 prompt 可选能力）
  -> session/new { cwd } -> agents.create 新建宿主 Agent 会话
  -> session/prompt -> agent.followup 进入宿主 agent-loop 与工具循环
  -> 宿主 session/event 投影为 agent_message_chunk（只发已提交文本）
  -> turn/end 关联 + whenIdle 结算 stopReason 并返回
  -> session/cancel -> agent.cancel，结算为 cancelled
  -> 连接关闭 -> quiesce：逐会话 cancel -> 排水 continuable 后代 -> dispose 全部 Agent
```

**主链 C：MCP 工具桥**：

```text
插件加载（mcp-client 实例，serverName 唯一性校验）
  -> startConnection：spawn stdio server 或连接 streamable-http，initialize 握手
  -> syncTools 两阶段：先拉完整 tools/list 分页（不动注册表）
     -> 再整代注册/注销，冲突回滚（全有或全无）
  -> 模型调用 mcp__<serverName>__<rawName>，执行器只把 rawName 发上 wire（tools/call）
  -> isError 结果转 throw -> ToolRuntime 产出 isError 结果
  -> 断线 -> 有界指数退避重连 -> 新代际重新同步工具；耗尽预算则注销工具并停止
```

## 身份、协议与状态映射

### subagent 委派侧

外部执行体的身份由两层组成：provider 在注册表中的注册名（即下文 provider 差异表格的行键），以及父命名空间为每次 run 铸造的 `SessionId(randomUUID())`。进程外 provider 返回的 run id 只是生命周期 id，`localAgent` 为 undefined，子进程内部的原生会话 id（ACP sessionId、Codex thread id、SDK child session）不映射到宿主任何持久对象，因此不参与宿主 session 的持久化枚举。

四个进程外 provider 全部是 one-shot：`SubagentRuntime.start()` 只承载单次委派，run 无 resume、无 steering；continuable 子 Agent 的 `prepareContinuable` 能力只对进程内 provider 开放（`subagent/index.ts:433-446`）。每次委派把版本化 `subagent/descriptor` 事件（当前版本 2，`descriptor.ts:47`）写入会话日志作为持久身份，但进程外 provider 不追加它——该机制只为进程内会话式子 Agent 服务。

子进程工作目录来自父 session workspace（配置 `cwd` 覆盖优先，`out-of-process.ts:114-120`），是外部执行体的事实边界：外部 Agent 在本工作区下做文件操作，宿主不为其建立额外资源映射。

### ACP 服务器侧

外部客户端身份只到"stdin/stdout 连接"一层：`authenticate` 直接返回成功、`authMethods` 为空数组（`acp/index.ts:247-282`），无令牌或账户概念。协议状态与宿主状态一一对应：`session/new` 返回的会话 id 就是宿主 `agents.create` 创建的 Agent session id。每会话同一时刻只允许一个 in-flight prompt，会话没有持久化恢复——连接关闭后 quiesce 释放全部 Agent。

### MCP 桥侧

`serverName` 是插件配置中的稳定本地命名空间（正则约束 1-32 字符）。进程内唯一性由 `activeServerNames` 按 app 根维护，重复加载即配置错误（`mcp-client/index.ts:148-161`）。桥只保存"serverName + rawName"的工具目录，不保存账号或资源状态，也没有跨重启持久连接。

## 执行、回流与控制语义

### 四 provider 差异

四进程外 provider 共用一套发布骨架（`out-of-process.ts` 的 `settleRunResult` 与 `subprocessRunHandle`）：发布后的结果永不 reject，子进程失败一律折叠为 error 停止原因并经日志 sink 保留原始错误。差异集中在启动方式、权限处理和回流选择：

| provider | 启动与协议 | 权限/提问处理 | 结果选择 | 取消与 teardown |
|---|---|---|---|---|
| `acp` | spawn 配置命令，ACP ndjson over stdio（`subagent-acp/run.ts:199-368`） | `session/request_permission` 按 `allow`/`reject` 配置自动应答，`allow` 选第一个 allow_once/allow_always 选项，否则 cancelled | 累积 assistant 文本；thoughts/工具调用丢弃 | `conn.cancel` 尽力而为；stdin EOF（6s 宽限）-> 树终止 |
| `claude-code` | 官方 Agent SDK `query()`，`spawnClaudeCodeProcess` 钩子把真实 CLI 纳入共享 subprocess owner；Windows 走 cmd 批处理 shim（`subagent-claude-code/run.ts:177-290`、`process.ts:51-74`） | `disallowedTools: ['AskUserQuestion']`，无审批通道 | 只消费 SDK result 消息，严格 success（is_error/空结果即失败） | AbortController 取消 SDK；query.close + 树终止 |
| `codex` | spawn `codex app-server --stdio`，私有 JSON-RPC：initialize/initialized、`thread/start`（ephemeral）、`turn/start`、`turn/completed`（`subagent-codex/wire.ts:83-374`） | 无头自动应答：命令/文件审批选 cancel 或 decline，权限给空集，`item/tool/requestUserInput` 回空答案，MCP 询答 decline | `item/completed` 中 agentMessage 的 final_answer 文本优先，commentary 丢弃 | `turn/interrupt` 尽力而为；wire.close + stdin EOF + 树终止 |
| `dsh-sdk` | SDK client 自管 spawn `dsh-jsonrpc-agent` 子进程（subprocess seam 的例外），initialize 握手后 `session.run`，`session.event` 通知回流（`subagent-dsh-sdk/run.ts:112-206`） | 无 wire 级权限通道；子进程自带 harness 策略 | `AssistantOutputFold` 按最终 assistant 消息选文 | 无 wire 取消；本地先结算，`shutdown` 协议（1s 上限）+ EOF 宽限 + 树终止 |

共同点：启动失败（握手/建会话失败）由 provider 自拥进程并回收后才 reject；发布后的失败只落结果。结果只回传最终文本，不回流 reasoning、工具事件、文件变化或结构化提问——这是与 LobeHub 统一事件模型最本质的差异。

### 取消语义

取消是"本地优先、远端尽力"：request signal abort 后各 provider 先让 result 以 `aborted` 结算（保留已收集的部分文本），随后才发起远端 cancel 或 interrupt，最终 teardown 以整树静止为完成条件（`out-of-process.ts:156-175`）。所有子进程终止统一走 subprocess seam 的 `terminate()`——SIGTERM -> 配置宽限 -> SIGKILL，跨平台树级生效（`subprocess-local/spawn.ts:446-456`）。

### 回流与持久化

宿主侧可见回流只有两种：run 的最终 `SubagentResult`，以及 `subagent/start` 与 `subagent/end` 生命周期事件对（scope 按委派父 Agent 过滤）。工具层把结果映射为后台 JobOutcome：completed 带最终文本、aborted 为 killed、其余为 failed，非 completed 一律转 `isError` 工具结果，部分文本仍附加在错误详情中。进程内 continuable 子 Agent 的 `report` 通道和 settled 通知属于另一套消息源词汇，不适用于进程外路径。

## 权限、凭据与治理边界

- **凭据隔离**：所有子进程环境以 `scrubbedParentEnv()` 为基：凭据形状的变量名（KEY/PASSWORD/SECRET/TOKEN）与全部 `DSH_*` 名被擦除（`subprocess/index.ts:44-66`），provider 配置的显式 env 在擦除后合并，子进程自带的 API key 必须显式注入。
- **外部 Agent 的权限自治**：Claude Code 与 Codex 子进程拥有完整工具执行权，宿主只做协议层的权限应答——Claude Code 直接禁用提问工具，Codex 全部自动应答且不把审批提升给人类。ACP provider 的 `permission` 配置（默认 reject）是唯一可配置的自动审批策略。
- **ACP 服务器是机器权限通道**：宿主审批 waterfall（`approval/request`）对 ACP 拥有的 Agent 转成 `session/request_permission`，只提供 allow-once/reject-once 一次性选项，未知客户端响应不推断长期授权（`acp/index.ts:215-229`）。
- **MCP 与 hooks 的执行边界**：MCP server 命令与 hooks 命令都在宿主沙箱之外运行（CLI 参考文档明确说明每条 MCP server 命令是受信任可执行代码，故默认不启用任何 server）。hooks 经 `ctx.shell` 执行，可以受 bash-sandbox 策略约束；其审批语义按协议最严格合并（deny > ask > allow，`continue:false` 粘住，`hook-protocol/merge.ts:34-100`）。
- **审计**：hook 每次调用写入 `hook/invoked` 与 `hook/result` 事件对（含超时、stderr 摘要上限）到会话日志；subagent 生命周期事件对提供委派审计。
- **未授权外部表面**：ACP 服务器无鉴权、无并发限制（除每会话单 in-flight prompt），其安全模型依赖"本地 stdio + 可信调用方"。

## 相邻类目交接

- 进程内 `spawn`/`fork` provider 与 continuable 子 Agent 属于 Agent 角色与多 Agent 编排类目（宿主内建），本次只在区分边界时提及。子 Agent 侧的 `report`、`send_message` 工具同理归工具编排类目。
- `run_code` 传输、bash/pwsh 工具、terminal 六工具与 MCP 工具注册都属于 Agent 工具执行面（定义见 `core/tools/src/code-mode.ts:20`），本笔记只在"执行位置与外部边界"意义上引用它们。
- 持久化终端（terminal 服务、terminal-bash PTY 后端与 tool-terminal 六工具）是宿主内执行域，不属于外部协作；但其 owner=Agent 的归属模型与 subagent 的 parent 概念一致，可作横向比较素材。
- CLI headless 是一次性宿主执行入口（`dsh --profile headless "task"`），web profile 是交互表面；`dsh plugin` 安装外部 bundle 是"发现/安装外部对象"的轻量样本，不构成独立主链。

## 已确认边界与未验证事项

进程内可续接子 Agent 的生命周期已进一步明确：持久 child session 在进程内至多对应一个 activation；首次提交只在 inbox 接收后返回 child/message id，后续 follow-up 继续使用同一 FIFO inbox。子 Agent 可以选择向直接父 Agent 报告，`quiet` 只注入消息，`next-step` 会在父 Agent 空闲或下一步边界唤醒；运行时另以独立来源记录最终结算，避免将管理器的事实归因给子 Agent。该机制不改变进程外 ACP、Claude Code、Codex 与 dsh-sdk provider 的 one-shot 边界（`docs/subsystems/subagent.md:114-159, 191-234`）。

- 本仓库没有 GUI 产品表面：外部执行体状态、子进程工作目录与连接状态只体现在会话日志事件、CLI 输出和 stderr 诊断中，不存在图形化的执行位置/接管入口。
- 四条主链均为静态走通；未运行真实 Claude Code/Codex/外部 ACP 子进程，CLI 版本兼容、SDK 版本行为（Codex 协议锁定 0.147.0）与真实进程终止未验证。
- `subagent-acp` 的 test fixture 用脚本化 ACP 子进程，真实 ACP 子进程往返仅在快照层级，`TODO(acp-subagent-replay)` 表明快照覆盖未落地。
- ACP 服务器只接受 text/resource_link prompt，image/audio 能力未声明；停止原因映射把 max-tokens 与 hook 中止都归一为 end_turn，客户端无法区分（源码注释明确该选择，未运行验证）。
- hooks 双桥的 configPath 是进程级一次性读取，无 per-session 项目内 hooks.json 发现（源码 TODO）；`updatedInput`、`systemMessage`、`continue:false` 停轮语义未生效或被忽略，与 Claude Code 原版行为有差异。
- MCP 重连的真实网络断线、stable 窗口重置预算行为、streamable-http 传输未运行验证；E2B 沙箱（`e2b@2.29.1`）是 POC，无模板/卷/快照/网络策略。
- 进程内 provider 的 continuable/resume 冷恢复、Windows 进程树终止、`DSH_PERMISSION_MODE` 与 sandbox 组合行为未实测。

## 关键源码索引

- `packages/subagent/subagent/src/index.ts`（注册表与 start/startContinuable/followup/interrupt）、`out-of-process.ts`（进程外契约）、`descriptor.ts`、`run-settlement.ts`
- `packages/subagent/subagent-acp/src/{index,run}.ts`
- `packages/subagent/subagent-claude-code/src/{index,run,process}.ts`
- `packages/subagent/subagent-codex/src/{index,run,wire}.ts`
- `packages/subagent/subagent-dsh-sdk/src/{index,run}.ts`
- `packages/subagent/tool-subagent/src/index.ts`
- `packages/mcp/mcp-client/src/{index,tools,connection,transport}.ts`
- `packages/acp/acp/src/{index,codec}.ts`
- `packages/hooks/hook-protocol/src/{runner,merge,matcher,codec,events,detached}.ts`
- `packages/hooks/hooks-claude-code/src/index.ts`、`packages/hooks/hooks-codex/src/index.ts`
- `packages/subprocess/subprocess/src/index.ts`、`packages/subprocess/subprocess-local/src/spawn.ts`
- `packages/terminal/terminal/src/index.ts`、`packages/terminal/terminal-bash/src/{index,session,sanitize}.ts`、`packages/terminal/tool-terminal/src/index.ts`
- `packages/code-runtime/code-runtime/src/index.ts`、`packages/code-runtime/code-runtime-worker-thread/src/index.ts`
- `packages/e2b/e2b/src/index.ts`
- `packages/boot/cmdline/src/index.ts`、`apps/cli/src/bin.ts`、`apps/cli/reference/README.md`
- `packages/examples/acp-demo/src/bin.ts`、`examples/acp-agent/cordis.yml`、`examples/acp-agent/product-subagent-both.cordis.yml`、`examples/mcp-memory/*.cordis.yml`
- `docs/subsystems/{subagent,subprocess,approval}.md`
