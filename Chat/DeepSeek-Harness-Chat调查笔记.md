# DeepSeek Harness Chat 概览

> 调查对象：`../../deepseek-harness`（重点 `packages/core/agent-loop`、`packages/core/agent`、`packages/core/session`、`docs/architecture.md`、`docs/agent-lifecycle.md`、`docs/subsystems/core.md`）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：只读静态源码阅读，并以官方文档（architecture.md 的 turn flow、agent-lifecycle.md 时序图、subsystems/core.md 的 the-agent-handle 一节）交叉核对；未运行交互会话
>
> 调查范围：agent loop 的 turn/step 生命周期与事件流、事件域划分、inbox 与唤醒、取消与错误恢复、guard 与交互插件对循环的影响、headless 运行模式、与 pi 的关系；排除 GUI 与 SDK/ACP 传输细节、会话持久化后端实现、系统提示词与工具流水线的完整机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness（dsh）是构建在 vendored Cordis 插件框架上的 agent harness，"一切皆插件"：模型适配器、工具注册表、会话日志、agent 循环本身都是插件。对话运行的核心是 `packages/core/agent-loop` 的 `ReactLoopAgent`，它是 `Agent` 接口的唯一具体实现，驱动"turn 打开 → step 循环 → turn 关闭"的过程：

1. **step 与 turn**：step 是一次模型请求加它调用的工具；turn 是零或多个 step，在首次 claim 输入前打开、在模型不再欠任何回复时关闭。turn/step 边界全部是 durable session 事件（`turn/start`、`step/start`、`step/end`、`turn/end` 等）。
2. **输入入口**：所有输入经一条 inbox（`next-turn` 与 `next-step` 两个 pending 列表）投递，每次 claim 取"全部 next-step 输入加一条 queued 消息"；followup/steer 唤醒驱动，inject 只排队不唤醒（`agent.ts:113-132`）。
3. **事件三域**：session 事件（durable、可重放）、agent/* 事件（live、按 agent 作用域过滤）、capability 事件（策略/适配器 seam）。"模型可见 ⟺ 已记录"是硬约束。
4. **循环控制全在插件层**：守卫（repeat-tool-reminder、timeout-policy）、审批、人类问答、命令都通过事件与工具 seam 影响循环，不改驱动本身。
5. **取消是协作式**：`cancel(cause)` 清 inbox（除非 `keepInbox`）并 abort 当前活动；错误经 `agent/request-error` waterfall 可重试，未投递的工具调用获得合成错误结果。
6. **headless**：`dsh --profile headless "task"` 一键运行——创建 agent、投递任务、等待静止、flush、打印最终文本并按 `turn/end` 原因退出。

## 产品表面与系统边界

- **产品表面**：`dsh` CLI 以 profile 启动不同组合：`--profile web`（浏览器 GUI，本次排除）、`--profile headless`（无服务器一键任务）；另有 ACP 自动化服务器与 Python SDK/JSON-RPC 通道。本笔记只涉及它们共同的运行核心：agent 与用户消息之间的一轮轮对话执行。
- **系统边界**：模型推理由外部 provider 经 `ctx.llm` seam 完成；会话事实源是内存中的 append-only 事件日志（`Session`），持久化是订阅 `session/event` 的插件后端；单 agent 单驱动循环，进程内可并行存在多个 live agent（`ctx.agents` 注册表）。循环不依赖任何 UI，UI 只是 `session/event` 与 agent/* 事件的消费者。

## 端到端聊天主链（一次完整对话回合）

```text
调用方（headless runner / ACP / Web 等）
  -> agent.followup(UserMessage)
     inbox 写入 -> agent/inbox/spliced（durable）+ agent/inbox/inserted（live）
     wakeDriver -> agent/status running
  -> driver 打开 turn：turn/start（durable）
     preStep：claim 全部 next-step 输入 + 一条 next-turn 消息
       （纯删除 splice + 每条 agent/inbox/claimed）
       组装系统提示词与工具 schema -> agent/pre-step（waterfall）
       reject 或空 enter -> turn 无 step 关闭
     step/start（durable）；进入的消息逐条记 user/message（durable）
     构建请求：agent/request（waterfall）-> request/header（durable）
       -> ctx.llm.prepareCall -> llm/stream（waterfall）
       -> assistant/chunk*（durable）-> assistant/message（durable）
     工具调用：tool/call* -> tools/pre-execute|execute|post-execute
       -> tool/result*（durable）
       工具结果 additionalContexts 暂存进 next-step inbox
     模型不再欠回复 -> step/end（durable）
     next-step 为空 -> agent/turn-stopping（serial，可 steer 续命）
     turn/end（durable，含 reason）
  -> 驱动收敛 idle -> agent/status idle；调用方读 session/event 或 flush
```

关键交接点：输入进入 inbox 时 durable 事件先于 live 投影提交；驱动在 turn 打开后于 preStep 阶段完成 claim，并重新组装提示词与工具 schema；请求配置每步经 `agent/request` waterfall 重新决定，这是模型路由可插拔的落点（`agent.ts:225-401`）。

## 核心对象与状态权威

- **Session（事件日志）**：append-only 的 `SessionEvent` 列表，是唯一事实源；模型历史由 `deriveMessages()` 从日志派生，不单独存储（`docs/subsystems/session.md`）。事件类型经 `SessionEventMap` 声明合并扩展。
- **Agent（live 句柄）**：`ReactLoopAgent` 暴露 id、session、inbox、status、ctx 与投递/取消/等待一组方法（`runtime-types.ts:64-144`）；内部 phase 状态机为 idle / maintenance / running（`agent.ts:38-46`）。
- **AgentRegistry（ctx.agents）**：注册表加 initiator 作用域（进程内因果归属，AsyncLocalStorage）；`create()/resume()` 经 AgentFactory 委托给 agent-loop；返回的 `AgentHandle` 是消费者端唯一的 teardown 能力（`agent/index.ts:256-430`）。
- **Inbox**：两条 pending 列表的 durable 投影，从 `agent/inbox/spliced` 事件重建（`inbox.ts:25-40`）。
- **状态权威**：turn/step 编号、消息内容、工具结果都在日志里；`agent/status`、inbox 的 live 通知只是投影。

## 事件域划分

| 域 | 事件（举例） | 特征 |
|---|---|---|
| Session（durable） | `turn/start`、`turn/end`、`step/start`、`step/end`、`user/message`、`assistant/chunk`、`assistant/message`、`tool/call`、`tool/result`、`request/header`、`request/context`、`todo/write`、`session/end-seed`；插件合并的 `agent/inbox/spliced`、`compaction/*`、`hook/*`、`command/run`、`approval/asked` 等 | 追加进日志、经 `session/event` 广播、可重放重建；`SessionEventMap` 声明合并扩展 |
| Agent（live） | `agent/created/disposed/status/session-start/error`、`agent/inbox/inserted/claimed/discarded`（emit）；`agent/pre-step`、`agent/request`、`agent/request-error`（waterfall）；`agent/turn-stopping`（serial） | 携带 live `Agent` 主体、按 agent 作用域过滤、不持久化（`runtime-types.ts:147-291`） |
| Capability（policy/adapter） | `llm/stream`、`tools/pre-execute/execute/post-execute/result`、`fs/*`、`approval/request`、`system-prompt/assemble` | 挂在能力 seam 上，不带 agent 语义；waterfall 必须 `next()` 委托 |

判定准则：能改变模型可见输入的必须是 durable 事件；能改变运行中行为的用 live 事件或 waterfall。完整的生产者/消费者矩阵见 `docs/event-producer-consumer.md`。

## turn/step 生命周期与事件流

**turn()** 是驱动的主循环（`agent.ts:246-330`）：打开 turn 边界后由 preStep 阶段完成 claim、提示词组装与 `agent/pre-step` 决策；reject 或首步 enter 为空时，turn 以无 step 状态关闭。退出条件是"模型不再欠回复"与"next-step 已空"同时成立，此时先走 `agent/turn-stopping`（监听者可投递 steer 续命，机器随后重读队列）再记 `turn/end`；若队列仍非空，turn 返回 true，驱动换新 AbortController 继续下一轮。

每个 step 在日志里留下固定的 durable 序列（`agent.ts:279-293`）：

```text
step/start -> user/message（进入批次） -> assistant/chunk* -> assistant/message
  ->（模型调了工具时）tool/call* -> tool/result* -> step/end
```

`step()` 的语义要点（`agent.ts:332-401`）：请求配置每步经 `agent/request` 重新决定并冻结，变化记入 `request/header`；每个成功 finish 恰好落一个 `assistant/message` 锚点，空内容也记但不进派生历史，其 sourceEventSeqs 精确指向 chunk 序列。工具按 executionMode 分 exclusive 屏障与并行池（默认 10、可设 1 串行），结果按模型顺序提交；max-tokens 结论 sticky，后续正常 step 不降级；工具结果带 concludesTurn 时本步即完成，否则模型欠回复，下一轮以空 claim 继续（工具结果已在日志中、派生历史可见）。

`turn/end` 的原因集合（`session/types.ts:155-177`）：

- `completed`：正常结束
- `aborted`：取消，携带调用方原因
- `blocked`：pre-step 拒绝
- `error`：结构化失败（LlmFailure）
- `max-tokens`：输出截断且 sticky
- `interrupted`：只由崩溃恢复合成，loop 从不发出

## inbox 与唤醒

inbox 的每个变更都先落一条 `agent/inbox/spliced`（标准化 splice 坐标，durable）再改 live 投影，同步观察者能重建被删消息；两个 pending 列表内消息 id 全局唯一。`claim(target, turn)` 以纯删除 splice 取出全部 next-step 输入，turn 边界再加一条 next-turn 消息，并逐条发出 claimed 通知（`inbox.ts:71-78, 139-219`）。

三种投递预设（`agent.ts:113-132`）只组合两个维度：投递目标与是否唤醒。

| 预设 | 目标列表 | 唤醒驱动 |
|---|---|---|
| `followup` | next-turn | 是（成为自己 turn 的唯一普通消息） |
| `steer` | next-step | 是（最近一次 step 边界消费） |
| `inject` | next-step | 否（等别的消息唤醒） |

唤醒机制（`agent.ts:172-193`）：idle 时直接开 driver；maintenance 或已 abort 的活动把唤醒暂存，收敛后再放行；disposed 取消不暂存。取消之后到达的唤醒输入被改投 next-turn。idle 时即使消息随后被清掉，唤醒也照样开一个 turn 边界（出现 transient 的 idle→running→idle 状态对）。

## 取消与错误恢复

`cancel()` 除非 `keepInbox`，先清空两条 pending 列表（记 canceled splice）再 abort 当前活动的信号（`agent.ts:134-140`）。取消原因只存在于 AbortSignal.reason 里，turn/end 只保留粗粒度 aborted；想记录"谁"需要独立 durable 事件（`subsystems/core.md` the-agent-handle 一节）。

错误路径分三段。驱动把每步失败结构化：`LlmError` 保留事实，其余拍平为 UNKNOWN 文本，随后记 turn/end error；agent/error 在 live 边界报告一次后由 driver 兜底（`agent.ts:203-223, 302-323`）。模型请求失败走 agent/request-error waterfall：监听者返回 retry 时 step 内原地重试，dsh-llm-retry 与 dsh-compaction-basic 是现成消费者（`agent.ts:354-371`）。取消中断的工具调用中，已启动的排干并提交结果，未启动的补合成 call/result 错误对（ABORTED_BEFORE_DISPATCH），保证重放自洽（`tool-calls.ts:237-259`）。

`whenIdle()` 观察整个 agent（跟随 driver 与维护任务），`runMaintenance()` 在 true idle 占位运行非 turn 任务（如压缩），期间状态保持 idle（`agent.ts:142-162, 195-200`）。

## guard 与循环控制

- **repeat-tool-reminder**：在 `tools/post-execute` 中按"工具名 + 参数规范化字符串"对连续重复调用计数，命中阈值（默认 3/5/8）时把提醒文本作为 `additionalContexts` 注入，随工具结果进入下一步的 inbox 输入，模型下一步即可看到；用户来源消息进入 pre-step 时重置计数。只观察不否决（`src/index.ts:189-232`）。
- **timeout-policy**：包装 `tools/execute`，给声明了 `timeoutMs` 的工具套 deadline，超时替换为结构化的 `TOOL_TIMEOUT` 错误结果（`src/index.ts:55-80`）。

两者都通过事件/工具 seam 改变"下一步模型看到什么"，驱动本体不变。

## 与运行的交互（approval / commands / ask-user）

- **user-approval**（`ctx.approval`）：一次性的 `approval/request` waterfall；工具流水线的 ask 决策路由到这里，缺应答者时 fail closed；审计事件 `approval/asked`/`approval/decided` 是 log-only，模型只看到工具结果。请求必须处于 open turn（`packages/interaction/user-approval/README.md`）。
- **tool-ask-user**（`ask_user_question` 工具）：经 `ctx.userQuestions.ask()` 暂停该工具调用，等人类回答；答案作为普通 `tool/result` 回注，循环本身无需改动（README："a tool call awaits a promise, and the tool result resumes the normal agent loop"）。
- **commands**：人类斜杠命令在命令平面执行，不产生模型回合；`command/run`/`command/done` 是 standalone durable 记录。注册表自己不把命令文本投给 agent；producer 可显式使用 agent（如 plan-mode 的 `/plan [message]` 通过 `agent.steer()` 提交）。

## headless 运行模式

`dsh --profile headless "task"` 由 dsh-headless bundle 实现：不挂 Host/HTTP/browser，headless-runner 插件创建 agent、投递任务文本、等待静止、flush 落盘后从事件日志折叠出最后一个非空 assistant 文本打印到 stdout；`turn/end` 为 completed 退出 0，否则退出 1，error 原因再写一行 stderr（`src/index.ts:96-134`）。agent-spine-demo 是组成这套脊柱的最小参考 bundle：会话、提示词、工具注册表、agent 注册表、agent-loop 与 invariants，外加可选的 jobs/goals/skills/bash 子装配（`src/index.ts:212-265`）。

## 与 pi 的关系

在 agent-loop 与 agent 两个核心包中未找到对 earendil-works/pi 的任何引用：对 `packages/` 下全部 `*.ts` 搜索 earendil 字样与来自 pi 的导入，唯一命中是 `packages/llm/llm-pi-ai`。该包把 `@earendil-works/pi-ai` 的模型目录与流式能力适配为 dsh 的 LLM provider seam 之一（强制 SDK 重试为 0，重试预算归 dsh-llm-retry）。因此 dsh 与 pi 的关联只在 LLM 适配器层；agent loop 是 dsh 自己的设计，`ReactLoopAgent` 与 pi 的 loop 无继承证据。概念上"steer 运行中输入、循环直到停止"与 pi 相似，但这是无证据的横向印象，不构成继承结论。

## 专项导航

本仓库的会话管理、上下文构建、消息渲染、Chat UI 等均未建立专项调查笔记（本次仅覆盖运行核心），对应模块归属如下，后续拆分专项时补充链接。

| 专项 | 归属模块 |
|---|---|
| 会话与持久化 | `packages/core/session`、`packages/session/session-persistence` |
| 上下文与请求 | `packages/core/system-prompt`、`packages/llm`、`packages/compaction` |
| 消息渲染与 Chat UI | `apps/web`、`packages/client/*` |

## 关键能力与已确认边界

- 支持：每 agent 一个独立驱动，进程内多 agent 并行；运行中 `steer`/`inject`；`keepInbox` 取消；resume 持久化会话续跑（turn 编号接续）；step 内并行工具池；空 claim 的工具续步。
- 已确认边界：内置无 turn 预算——"tool calls or steering continue the current turn"（agent-loop README Known Limitations），需要限流的策略从 `agent/turn-stopping` 等扩展点自行取消；`followup()` 无返回句柄，收据到静止的区间由调用方自己界定；配置声明的 agent 无 per-agent persona 与 setup 钩子；工具并发分类是 unary 的，不能做兄弟间比较。
- 事件词汇边界：`steering/message` 作为 durable 事件类型只存在于 pre-react-loop 旧格式（持久化协调器按 legacy 处理，`session-persistence/src/coordinator.ts:328-357`），当前 steer 以普通 `user/message` 落日志。

## 未验证事项

- 未运行任何交互会话：流式输出、取消竞态（wake latch、abort 收敛）、headless 实际执行与退出码均未实测。
- resume/崩溃恢复路径（`interrupted` 合成、修复后接续）只做了静态阅读。
- Web GUI 与 ACP 的具体接线（事件消费、命令适配器）未深入。
- `llm-pi-ai` 适配器的行为依据其 README 与源码推断，未用真实 API 验证。

## 关键源码索引

- `packages/core/agent-loop/src/agent.ts`：`ReactLoopAgent` 全部——`send`/投递预设 `:113-132`、`cancel` `:134-140`、`wakeDriver` `:172-193`、`preStep` `:225-243`、`turn` `:246-330`、`step` `:332-401`、`buildRequest` `:407-495`
- `packages/core/agent-loop/src/tool-calls.ts:59-259`：工具调度（屏障/并行池、abort 合成结果）
- `packages/core/agent-loop/src/index.ts:296-711`：AgentLoop 工厂/事务/配置 agent 启动；`constants.ts` 并行上限默认值
- `packages/core/agent/src/inbox.ts:25-219`：inbox 投影与 splice 语义；`types.ts:13-26` 声明 `agent/inbox/spliced`
- `packages/core/agent/src/index.ts:256-704`：AgentRegistry、initiator、register/enter/announce
- `packages/core/agent/src/runtime-types.ts:64-291`：Agent 接口、`AgentOptions`、`PreStepDecision`、agent/* 事件契约
- `packages/core/agent/src/dispatch.ts:107-149`：fused dispatcher（主体注入 + 作用域 carrier）
- `packages/core/session/src/types.ts:236-332`：`SessionEventMap`；`types.ts:143-177`：`AgentCancelCause` 与 `TurnEndReasonMap`
- `packages/bundle/headless/src/index.ts:96-134`：headless 一键运行；`cordis.patch.yml` 组合
- `packages/guard/repeat-tool-reminder/src/index.ts:189-232`、`packages/guard/timeout-policy/src/index.ts:55-80`
- 文档：`docs/architecture.md`（turn flow 与事件域）、`docs/agent-lifecycle.md`（时序图）、`docs/subsystems/core.md`（the-agent-handle）、`docs/subsystems/session.md`（事件词汇与派生规则）
