# DeepSeek Harness Chat 概览

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/core/agent-loop`、`packages/core/agent`、`packages/core/tools`、`packages/core/session`、`docs/architecture.md`、`docs/agent-lifecycle.md`、`docs/subsystems/core.md`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：只读静态源码阅读，并以官方文档（architecture.md 的 turn flow 与 session log 两节、agent-lifecycle.md 时序图、subsystems/core.md 的 the-agent-handle 一节）交叉核对；未运行交互会话
>
> 调查范围：agent loop 的 turn/step 生命周期与事件流、事件域划分、inbox 与唤醒、取消与错误恢复、guard 与交互插件对循环的影响、工具执行器边界、headless 运行模式、与 pi 的关系；排除 GUI 与 SDK/ACP 传输细节、会话持久化后端实现、系统提示词与工具流水线的完整机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness（dsh）是构建在 vendored Cordis 插件框架上的 agent harness，"一切皆插件"：模型适配器、工具注册表、会话日志、agent 循环本身都是插件。对话运行的核心仍是 `packages/core/agent-loop` 的 `ReactLoopAgent`，它是 `Agent` 接口的默认具体实现，驱动"turn 打开 → step 循环 → turn 关闭"的过程：

1. **step 与 turn**：驱动每发起一次模型请求、并执行这次请求调用的工具，就走完一个 step；一个 turn 由零个或多个 step 组成，从第一次认领输入之前打开，到模型不再欠任何回复时关闭。打开 turn 记 `turn/start`，关闭时记 `turn/end`；单个 step 的起止同样各记一条事件，四类边界都进入可重放的事件日志。
2. **输入入口**：所有输入都经同一条 inbox 投递，内部按 `next-turn` 与 `next-step` 两份待处理列表分开；每次认领取走全部 next-step 输入，再加一条排队的 next-turn 消息。`followup` 与 `steer` 写入时唤醒驱动，`inject` 只排队、等别的消息来触发。inbox 由 `agent/inbox/spliced` 事件折叠重建，所以没有活动 agent 时也能从日志里读出待办输入。
3. **事件三域**：会话事件落盘并可重放，agent 事件只在进程内按 agent 作用域推送，能力事件挂在策略与适配器的接缝上。约定是模型看得到的内容必然已经记录在案；流式过程只走进程内推送，落盘的是内嵌完整流的 `assistant/message`，或没有表面消息时的 `assistant/attempt`。
4. **工具调度**：循环只把原始批次与并发上限交给工具接口，分发、并发、取消和调用记录由选定的执行器负责，可选原生执行器或 PTC 执行器；agent-loop 自身不再持有工具池实现。
5. **循环控制**：重复工具提醒、超时策略、审批、向人提问与斜杠命令都作为插件挂在事件或工具接缝上，靠改变下一步模型看到的输入或工具结果来影响循环，驱动本体保持不变。
6. **取消**：`cancel(cause)` 先清掉 inbox 里未消费的输入（除非设置 `keepInbox`），再中止当前活动；已经流出的文本带着中断标记收口成一条 `assistant/message`，尚未分派的工具调用补上合成的错误结果。
7. **headless**：`dsh --profile headless "task"` 用一条任务文本直接跑完整会话；加 `--json` 输出事件流，加 `--session-id` 可续跑同一会话。turn 正常完成时退出码为 0，被取消或出错时为 1。

## 产品表面与系统边界

- **产品表面**：CLI 用 `--profile` 选择启动组合，指定 web 起浏览器 GUI，指定 headless 起跑单条任务的无服务器进程；桌面端、ACP 自动化服务器和 Python SDK 的 JSON-RPC 通道共用同一套核心。本笔记只涉及这份共同核心，即 agent 与用户消息之间的一轮轮对话执行，GUI 一侧的接线留给专项笔记。
- **系统边界**：模型推理由外部 provider 经 `ctx.llm` 接缝完成，会话事实源是内存里的 append-only 事件日志，持久化交给订阅 `session/event` 的插件后端。每个 agent 有自己的驱动循环，进程内可以同时存在多个 agent，`ctx.agents` 负责登记它们。循环不依赖任何 UI，界面层只消费会话事件、流式帧和 agent 状态变化。

## 端到端聊天主链（一次完整对话回合）

```text
调用方（headless runner / ACP / Web 等）
  -> agent.followup(UserMessage)
     inbox 写入 -> agent/inbox/spliced（durable，投影可读）
     wakeDriver -> agent/status running
  -> driver 打开 turn：turn/start（durable）
     preStep：claim 全部 next-step 输入 + 一条 next-turn 消息
       快照会话模型选择并组装提示词 sections 与工具 schema
       -> agent/pre-step（waterfall）；reject 或首次 enter 为空 -> 无 step 关闭 turn
     step/start（durable）
       reconcile system/message（surface node 0）
       进入批次逐条记 user/message（durable）
       agent/request（waterfall，仅调整控制项）-> prepareCall
       request/header、request/context（durable，按需）
       deriveMessages 冻结模型历史 -> llm/stream（waterfall）
       agent/assistant-stream start/chunk* -> assistant/message 或 assistant/attempt
       tool/call* -> tools/pre-execute|execute|post-execute -> tool/result*（durable）
     step/end（durable）
     仍欠回复或有 next-step 新输入 -> 下一 step；否则 agent/turn-stopping（serial）
     turn/end（durable，含 reason）
  -> 驱动收敛 idle -> agent/status idle；调用方读 session/event 或 flush
```

关键交接点：输入进入 inbox 时 durable 事件先于任何 live 派生提交；驱动在 turn 打开后于 preStep 阶段完成 claim，并重新组装提示词与工具 schema；请求配置每步经 `agent/request` 重新决定，这是模型路由可插拔的落点。系统提示词以 `system/message` 表面节点协调（空文本清除、可路由追加、其余路由归并到首节点）。

## 核心对象与状态权威

- **Session（事件日志）**：一条 append-only 的 `SessionEvent` 列表，充当整个系统唯一的事实源；模型历史每次由 `deriveMessages()` 从日志现推，不另存副本。事件类型通过 `SessionEventMap` 的声明合并来扩展。
- **Agent（live 句柄）**：`ReactLoopAgent` 对外暴露 id、session、inbox、status、ctx，以及投递、取消、等待三类方法；内部用 idle、maintenance、running 三个 phase 描述自身状态（`packages/core/agent-loop/src/agent.ts:112`）。
- **AgentRegistry（ctx.agents）**：注册表登记进程内的 agent，并用 initiator 作用域（AsyncLocalStorage）记录因果归属；创建和恢复入口都委托给 agent-loop 的工厂，返回的 `AgentHandle` 是消费者唯一能用来拆除 agent 的对象。注册表还经 `turnBoundaryOf(session)` 提供 turn 与 step 状态的查询，并托管归档准入、已消费工作与投影等会话级治理点（`packages/core/agent/src/{index,archive-admission,consumed-work,projection}.ts`）。
- **Inbox**：两条待处理列表的可折叠投影，由 `agent/inbox/spliced` 事件重建，live agent 与没有 agent 的读取面共用同一份投影定义；splice 与 claim 的实现见 `packages/core/agent-loop/src/inbox.ts:108-166`。
- **状态权威**：turn/step 编号、消息内容、工具结果都以日志为准；`agent/status` 与流式帧只反映派生结果。

## 事件域划分

| 域 | 事件（举例） | 特征 |
|---|---|---|
| Session（durable） | `turn/start`、`turn/end`、`step/start`、`step/end`、`system/message`、`user/message`、`developer/message`、`assistant/message`、`assistant/attempt`、`tool/call`、`tool/result`、`request/header`、`request/context`、`agent/inbox/spliced`、`session/end-seed`；插件合并的 `compaction/*`、`hook/*`、`job/*`、`command/run`、`approval/asked` 等 | 追加进日志、经 `session/event` 广播、可重放重建；`SessionEventMap` 声明合并扩展 |
| Agent（live） | `agent/created/disposed/status/error`；`agent/pre-step`、`agent/request`、`agent/request-error`（waterfall）；`agent/assistant-stream`（start/chunk/end 帧）；`agent/turn-stopping`（serial） | 携带 live `Agent` 主体、按 agent 作用域过滤、不持久化（`packages/core/agent/src/runtime-types.ts:290-429`） |
| Capability（policy/adapter） | `llm/stream`、`tools/pre-execute/execute/post-execute/result`、`fs/*`、`approval/request`、`system-prompt/assemble` | 挂在能力 seam 上，不带 agent 语义；waterfall 必须 `next()` 委托 |

判定准则：能改变模型可见输入的必须是 durable 事件；能改变运行中行为的用 live 事件或 waterfall。流式增量是 live 事实，耐久化发生在每次尝试的收口处；`agent/assistant-stream` 的 Web Session-follow 适配器是它唯一的远程消费者。完整的生产者/消费者矩阵见 `docs/event-producer-consumer.md`。

## turn/step 生命周期与事件流

**turn()** 是驱动的主循环（`agent.ts:327`）：打开 turn 边界后由 preStep 阶段完成 claim、提示词组装与 `agent/pre-step` 决策（`agent.ts:283`）；reject 或首步 enter 为空时，turn 以无 step 状态关闭。退出条件是"模型不再欠回复"与"next-step 已空"同时成立，此时先走 `agent/turn-stopping`（监听者可投递 steer 续命，机器随后重读队列）再记 `turn/end`；若队列仍非空，turn 返回 true，驱动换新 AbortController 继续下一轮。

每个 step 在日志里留下固定的 durable 序列：

```text
step/start -> system/message（按需协调）-> user/message（进入批次）
  -> assistant/message（内嵌完整流与 usage）| assistant/attempt（无表面消息）
  ->（模型调了工具时）tool/call* -> tool/result* -> step/end
```

`step()` 的语义要点（`agent.ts:435`）：请求配置每步经 `agent/request` 重新决定并冻结（该钩子现在只调整控制项，不改 provider/model/effort 选择）；每个成功 finish 恰好落一个 `assistant/message` 锚点，空内容也记但不进派生历史，其内嵌流就是重放证据；工具按执行器的批次策略执行（原生执行器默认并行上限 10、可设 1 串行，`maxParallelToolCalls` 是可在运行期改的易变配置，改动对下一批生效），结果按模型顺序提交；max-tokens 结论 sticky，后续正常 step 不降级；工具结果带 concludesTurn 时本步即完成，否则模型欠回复，下一轮以空 claim 继续。

`turn/end` 的原因集合（`packages/core/session/src/types.ts` 的 TurnEndReasonMap）：

| 原因 | 含义 | 产生方 |
|---|---|---|
| completed | 正常运行到结束 | 循环 |
| aborted | 调用方取消，原因随取消信号传入（导入的旧数据为粗粒度取值） | 循环 |
| blocked | pre-step 阶段被拒绝 | 循环 |
| error | 结构化失败（LlmFailure） | 循环 |
| max-tokens | 输出被截断，结论保持 sticky | 循环 |
| interrupted | 崩溃恢复时合成 | 恢复流程 |
| forked | 分叉种子构造时发出，用于收口分叉边界上仍开着的源回合 | 分叉流程 |

## inbox 与唤醒

inbox 的每个变更都先落一条 `agent/inbox/spliced`（标准化 splice 坐标，durable），再更新投影；两个 pending 列表内消息 id 全局唯一。`claim(target, turn)` 以纯删除 splice 取出全部 next-step 输入，turn 边界再加一条 next-turn 消息（`inbox.ts:108`）。由于 inbox 是纯投影，重启后的 Session 也能直接重建待办输入，无需 live Agent。

三种投递预设（`agent.ts:179` 起的 followup/steer/inject）只组合两个维度：投递目标与是否唤醒。

| 预设 | 目标列表 | 唤醒驱动 |
|---|---|---|
| `followup` | next-turn | 是（成为自己 turn 的唯一普通消息） |
| `steer` | next-step | 是（最近一次 step 边界消费） |
| `inject` | next-step | 否（等别的消息唤醒） |

唤醒机制（`agent.ts:230`）：idle 时直接开 driver；maintenance 或已 abort 的活动把唤醒暂存，收敛后再放行；disposed 取消不暂存。取消之后到达的唤醒输入被改投 next-turn。idle 时即使消息随后被清掉，唤醒也照样开一个 turn 边界（出现 transient 的 idle→running→idle 状态对）。

## 取消与错误恢复

`cancel()` 除非 `keepInbox`，先清空两条 pending 列表（记 canceled splice）再 abort 当前活动的信号（`agent.ts:191`）。取消原因只存在于 AbortSignal.reason 里，turn/end 只保留粗粒度 aborted；想记录"谁"需要独立 durable 事件。

错误路径分三段。驱动把每步失败结构化：`LlmError` 保留事实，其余拍平为 UNKNOWN 文本，随后记 turn/end error；agent/error 在 live 边界报告一次后由 driver 兜底。模型请求失败走 agent/request-error waterfall：监听者返回 retry 时 step 内原地重试，`dsh-llm-retry` 与 `dsh-compaction-basic` 是现成消费者。取消中断的工具调用由执行器收口：已启动的排干并提交结果，未启动的补合成 call/result 错误对，保证重放自洽。取消前已流出的文本不会丢失，而是以 `interrupted: true` 的 `assistant/message` 提交。

`whenIdle()` 观察整个 agent（跟随 driver 与维护任务），`runMaintenance()` 在 true idle 占位运行非 turn 任务（如压缩），期间状态保持 idle（`agent.ts:199,253`）。

## guard 与循环控制

- **repeat-tool-reminder**：在 `tools/post-execute` 中按"工具名 + 参数规范化字符串"对连续重复调用计数，命中阈值（默认 3/5/8）时把提醒文本作为 `additionalContexts` 注入，随工具结果进入下一步的 inbox 输入，模型下一步即可看到；用户来源消息进入 pre-step 时重置计数。只观察不否决。
- **timeout-policy**：包装 `tools/execute`，给声明了 `timeoutMs` 的工具套 deadline，超时替换为结构化的 `TOOL_TIMEOUT` 错误结果。

两者都通过事件/工具 seam 改变"下一步模型看到什么"，驱动本体不变。工具侧的取消与并发由执行器统一处理，策略插件只在 seam 上叠加。

## 与运行的交互（approval / commands / ask-user）

- **user-approval**（`ctx.approval`）：一次性的 `approval/request` waterfall；工具流水线把 ask 决策路由到这里，没有应答者时按失败关闭处理。审计用的 `approval/asked` 与 `approval/decided` 只进日志，模型看到的仍是最终的工具结果。这类请求必须落在 open turn 内。
- **tool-ask-user**（`ask_user_question` 工具）：经 `ctx.userQuestions.ask()` 暂停该工具调用，等人类回答；答案作为普通 `tool/result` 回注，循环本身无需改动。
- **commands**：人类输入的斜杠命令在命令平面执行，不产生模型回合，执行记录以 `command/run` 与 `command/done` 单独落盘。注册表不会把命令文本投给 agent，需要时由命令的生产方显式使用 agent，例如 plan-mode 的 `/plan [message]` 通过 `agent.steer()` 提交。
- **Agent Teams**：为根 Session 启用后提供任务策略与共享任务板；普通 subagent 控制仍负责身份、消息、发现、中断与 inbox 等待。

## 工具执行器边界

循环不再内建工具池。`ctx.tools.execute(input)` 按 agent 选择执行器，并把原始批次、并发上限与取消信号交给它（`packages/core/tools/src/index.ts:375`）；执行器负责分发顺序、并行池、取消与调用记录，原生执行器提供带作用域工具的有界批次执行，PTC 执行器把同一批次放进沙箱化 Node 运行时。这条边界让"工具怎么执行"与"循环怎么驱动"可以独立替换，代价是循环侧只能通过 `tools/*` 事件观察执行细节。

## headless 运行模式

`dsh --profile headless "task"` 由 dsh-headless bundle 实现：不挂 Host/HTTP/browser，headless-runner 插件创建 agent、投递任务文本、等待静止、flush 落盘后从事件日志折叠出最后一个非空 assistant 文本打印到 stdout；`--json` 输出 machine-readable 事件流，`--session-id` 用于续跑同一会话。turn/end 为 completed 时退出 0，aborted 或 error 退出 1 并把原因写到 stderr。agent-spine-demo 是组成这套脊柱的最小参考 bundle：会话、提示词、工具注册表、agent 注册表、agent-loop 与 invariants，外加可选的 jobs/goals/skills/bash 子装配。

## 与 pi 的关系

在 agent-loop 与 agent 两个核心包中未找到对 earendil-works/pi 的任何引用：对 `packages/` 下全部 `*.ts` 搜索 earendil 字样与来自 pi 的导入，唯一命中是 `packages/llm/llm-pi-ai`。该包把 `@earendil-works/pi-ai` 的模型目录与流式能力适配为 dsh 的 LLM provider seam 之一（强制 SDK 重试为 0，重试预算归 dsh-llm-retry）。因此 dsh 与 pi 的关联只在 LLM 适配器层；agent loop 是 dsh 自己的设计，与 pi 的 loop 无继承证据。概念上"steer 运行中输入、循环直到停止"与 pi 相似，但这是无证据的横向印象，不构成继承结论。

## 专项导航

本仓库的会话管理、上下文构建、消息渲染、Chat UI 与导出分享已建立专项笔记；本概览只保留责任边界与导航，不再重复专项实现。

| 专项 | 归属模块 |
|---|---|
| 会话与持久化 | `packages/core/session`、`packages/session/*` |
| 上下文与请求 | `packages/core/system-prompt`、`packages/llm`、`packages/compaction`、`packages/context` |
| 消息渲染与 Chat UI | `apps/web`、`packages/client/*`、`packages/api/*` |
| 导出与分享 | `packages/session-query/session-log-export` |

## 关键能力与已确认边界

- 支持：
  - 每个 agent 一个独立驱动，进程内可并行多个 agent；
  - 运行中可以用 `steer` 或 `inject` 追加输入；
  - 取消时可用 `keepInbox` 保留未消费的输入；
  - resume 持久化会话后接着跑，turn 编号继续递增；
  - step 内的工具批次并发可配置：默认 10，可设为 1 串行；
  - 工具结果要求续步时，以空 claim 继续下一 step；
  - 取消前已流出的部分输出保留为中断消息。
- 已确认边界：
  - 内置没有 turn 预算，agent-loop 的 README 在 Known Limitations 里写的是 "tool calls or steering continue the current turn"，需要限流的策略得从 `agent/turn-stopping` 一类扩展点自行取消；
  - `followup()` 不返回句柄，从拿到收据到 agent 静止这段区间由调用方自己界定；
  - 配置声明的 agent 没有 per-agent persona，也没有 setup 钩子；
  - 工具并发分类是 unary 的，兄弟工具之间无法比较；
  - `agent/assistant-stream` 是进程内 live 事件，只有 Web Session-follow 适配器消费它。
- 事件词汇边界：`steering/message` 只作为 v0 冻结格式的历史表示存在于 `session-format-v0-to-v1` 的迁移与校验代码中；当前 steer 以普通 `user/message` 落日志。

## 未验证事项

- 未运行任何交互会话：流式输出、取消竞态（wake latch、abort 收敛）、headless 实际执行与退出码均未实测。
- resume/崩溃恢复路径（`interrupted` 合成、`forked` 收口、修复后接续）只做了静态阅读。
- 工具执行器的并行批次、PTC 沙箱执行与超时替换未运行验证。
- Web GUI 与 ACP 的具体接线（事件消费、命令适配器）未深入。
- `llm-pi-ai` 适配器的行为依据其 README 与源码推断，未用真实 API 验证。

## 关键源码索引

- `packages/core/agent-loop/src/agent.ts`：`ReactLoopAgent`——`:112` 类、`:179` 投递预设、`:191` cancel、`:230` wakeDriver、`:253` whenIdle、`:283` preStep、`:327` turn、`:435` step、`:656` buildRequest
- `packages/core/agent-loop/src/inbox.ts`：durable inbox 投影与 splice/claim 语义
- `packages/core/agent-loop/src/assistant-stream.ts`：尝试流的组装与收口
- `packages/core/tools/src/index.ts:375`：`execute()` 与执行器选择
- `packages/core/tool-executor-native/`、`packages/core/tool-executor-ptc/`：两种执行器
- `packages/core/agent/src/index.ts`（AgentRegistry）、`runtime-types.ts:290-429`（agent/* 事件契约）、`{archive-admission,consumed-work,projection,model-selection}.ts`
- `packages/core/session/src/types.ts`：`SessionEventMap`、`TurnEndReasonMap`
- `packages/guard/repeat-tool-reminder/src/index.ts`、`packages/guard/timeout-policy/src/index.ts`
- `packages/bundle/headless/src/{index,json-stream}.ts`：headless 一键运行与 JSON 事件流
- 文档：`docs/architecture.md`（turn flow、session log）、`docs/agent-lifecycle.md`（时序图）、`docs/subsystems/core.md`（the-agent-handle）、`docs/subsystems/session.md`（事件词汇与派生规则）、`docs/tool-execution-pipeline.md`
