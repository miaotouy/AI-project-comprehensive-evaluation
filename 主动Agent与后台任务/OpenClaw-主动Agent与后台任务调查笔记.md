# OpenClaw 主动 Agent 与后台任务调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：只读复查 cron service、heartbeat wake/runner、Gateway hooks、后台 exec、detached subagent、task ledger、SQLite schema 和 durable channel delivery 的可执行调用链；结合对应作用域规则与同类调查笔记，未启动 Gateway 或定时器
>
> 调查范围：覆盖持久自动化、条件唤醒、外部 hook、后台 CLI 进程、detached subagent 及其结果交付、取消、失败、重试和重启恢复；普通当前回合工具调用、内建 Agent 循环、外部 ACP 内部调度和普通同步消息不作为独立主链展开
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前代码快照中的主动运行不是单一任务系统，而是几种共享 Gateway 生命周期和结果交付设施的运行形态：

| 运行形态 | 触发与运行对象 | 状态事实源 | 执行与结果归属 | 证据状态 |
| --- | --- | --- | --- | --- |
| 持久隔离日程运行：automations/cron | 用户或 Agent 通过 `automations` 工具、Gateway RPC 或 CLI 保存 job；到期后由 `CronService` 认领一次运行 | SQLite `cron_jobs` 加 job 状态、`cron_run_receipts` 和 `task_runs` | `main` 目标进入 heartbeat/主会话；`isolated` 或 `current` 使用 detached cron run session；可执行 Agent、command 或 script | 主链确认（静态证据） |
| 条件唤醒：heartbeat | 系统拥有的 `heartbeat:<agentId>` monitor job 或 hook、事件、后台任务等 wake 请求 | monitor job 与 agent session 的持久字段；最近结构化结果在 agent DB 的 `heartbeat_outcomes` | 重新进入配置 Agent 的 heartbeat 回合，可静默、发消息或写入内部结果 | 主链确认（静态证据） |
| 外部事件：hooks/webhooks | Gateway HTTP hook 认证后产生 wake，或合成一次性 Agent cron job | HTTP 层只有进程内幂等缓存；实际运行沿用 cron receipt、task ledger 和 session 状态 | wake 注入 heartbeat；agent hook 进入隔离 Agent runner，同一 session 串行 | 主链确认（静态证据） |
| 后台 CLI exec | Agent 的 exec 在 yield/background 后把受监管的进程 session 登记为 task run | 进程 session registry 为进程事实；`task_runs` 为任务投影；两者均受进程生命周期影响 | ProcessSupervisor 持续托管进程；完成时可写 system event 并请求 heartbeat，也可由 process poll 取回 | 主链确认（静态证据） |
| Detached subagent | `sessions_spawn` 创建子 session 并登记 run；Gateway 接受后异步执行 | SQLite `subagent_runs`、关联 `task_runs` 和 session delivery queue | 子 Agent 在独立 session 运行，结果直接交付、注入 requester steering，或在所有子项结束后唤醒 requester | 主链确认（静态证据） |

最持久、最完整的后台任务主链是 cron：定义、排程、运行 fence、执行结果、交付结果和恢复都由 Gateway/SQLite 共同拥有。heartbeat 的周期 monitor 实际投影为系统拥有的 cron job，但具体 Agent 回合和忙碌退避由 heartbeat wake/runner 管理。hook agent 不是另造一套 worker，而是把外部事件转换成一次性 cron run。后台 exec 的进程本身仍由进程监管器和内存 registry 托管，SQLite 任务记录主要提供客户端可见的运行投影；detached subagent 则有更完整的持久注册、结果冻结、交付和重启恢复链。

## 系统边界与主链

### 统一的 cron 主链

Gateway 首次需要 cron 时通过 lazy loader 创建一个 `CronService`；`cron.enabled` 未显式设为 `false` 且没有 `OPENCLAW_SKIP_CRON=1` 时，服务允许自动运行。启动阶段先加载并校验 SQLite 中的 job，修复仍带有 queued/running marker 的非终态 receipt，再处理重启 catch-up，最后按最近的 `nextRunAtMs` 设置 timer。timer tick 在 Gateway root work admission 中运行，读取到期 job，取得并持久化 queued reservation 和 running receipt，然后进入统一执行与终态写入路径（`src/gateway/server-cron-lazy.ts:34-89`、`src/gateway/server-cron.ts:388-407`、`src/cron/service/ops-lifecycle.ts:119-211`、`src/cron/service/timer-scheduler.ts:49-169`）。

```text
automations/cron 工具、Gateway cron.* RPC、CLI 或系统 monitor
  -> SQLite cron_jobs 中的 job 定义和 nextRunAtMs
  -> timer / 手动 run / event watcher 发现候选
  -> cron_run_receipts + job.queuedAtMs 取得 durable reservation
  -> receipt.startedAtMs + job.runningAtMs 完成激活
  -> task_runs 记录 cron 运行；按 sessionTarget 执行 command、script、heartbeat 或 Agent turn
  -> 写入 run history、job 最近状态和 delivery trace
  -> durable channel、webhook、system event 或 heartbeat 交付结果
  -> 完成 receipt；循环任务计算下一次运行，一次性任务按策略禁用或删除
```

### 运行形态的分界

`CronJob` 的 `sessionTarget` 决定是否重新进入主会话、指定会话或 detached run session；`runsDetachedFromMainSession` 还把 script 和 skill collection review 视为需要独立 task/lifecycle 处理的运行。`main` job 不是直接调用 Agent，而是把 system event 放入目标会话，再请求 heartbeat runner；其他目标交给 detached cron runner。这个分界见 `src/cron/types.ts:54-64`、`src/cron/service/timer-execution-timeout.ts:139-177` 和 `src/cron/service/timer-execution.ts:218-237`。

system event、follow-up 和 steering queue 是结果进入下一回合的传输层，不是独立持久任务。system event 队列要求显式 session key，最多保留 20 项，运行时只存在进程内；它会在 heartbeat 或下一次会话提示构造时被筛选、消费。`src/infra/system-events.ts:1-4,38-47,122-205` 明确说明该队列故意不持久化，因此只能承接已有主动运行的提示或终态，不能单独承担重启后的任务恢复。

## 触发、调度与运行对象

### Automations/cron 的创建与排程

Agent 面向的工具名是 `automations`。它提供 scheduler status/list/get/add/update/remove/run/runs/next_check/wake 等动作，创建和修改最终通过 Gateway `cron.*` RPC 进入 CronService；工具默认宣传 `at`、`every`、`cron` 三种时间调度，触发 watcher、stream 和 script 受 `cron.triggers.enabled` 控制。一次性 `at` 任务运行后不再继续排程，循环任务保留下一次时间；`current` 会在创建时绑定 session key，避免后续当前会话切换改变任务归属（`src/agents/tools/cron-tool.ts:170-211,221-230,595-637`、`src/cron/session-target.ts:31-59`）。

持久定义和运行状态由同一 SQLite state database 的多个 owner-native 表共同表达：

| 对象 | 主要内容 | 作用 |
| --- | --- | --- |
| `cron_jobs` | job owner、schedule、session target、payload、delivery 及最近运行字段 | 定义和最近状态的权威行 |
| `cron_run_receipts` | receipt、job、config revision、owner pid/start time、running/terminal status | 一次运行的 durable fence 和执行事实 |
| `task_runs` | runtime、task kind、run id、状态、错误、进度和终态摘要 | 客户端任务列表与运行投影 |
| `cron_job_runtime_authorities` / `cron_job_scratch` | 工具运行权威与脚本/trigger scratch | 与 job 配置分离的运行时状态 |

表结构和 active receipt 的唯一 job 约束见 `src/state/openclaw-state-schema.sql:1331-1452,1527-1571`。receipt store 将生命周期分为 queued reservation、active running、settling 和 terminal；非终态 receipt 必须由当前 owner 持有，或能被其他 Gateway 进程判断为 stale 后恢复，见 `src/cron/store/run-receipt-store.ts:30-44`。

调度器不会只依赖内存 timer 判断一次运行是否已经发生。到期候选先从持久 `nextRunAtMs` 读取，之后在 SQLite 写入 receipt 和 queued marker；激活时再次比较 marker、配置 revision 和 job 当前状态。并发 mutation、删除、禁用或重排会使旧 reservation 被 fence 或 terminalize，避免旧 snapshot 在新 job 上写回结果（`src/cron/service/timer-scheduler.ts:187-264`、`src/cron/service/run-admission.ts:221-357,363-471`、`src/cron/service/ops-mutations.ts:167-255`）。

### 时间、事件和外部触发

cron 支持以下运行触发边界：

- `at` 是保持到成功终态或明确处理的一次性时间任务。
- `every` 按 anchor 和上次运行时间计算下一次周期。
- `cron` 按时区表达式计算，支持确定性 stagger，避免多个任务在同一时刻集中启动。
- `on-exit` 不靠时间到期，而由 Gateway `ProcessSupervisor` 在 Gateway 外层托管被观察的命令；命令退出后把退出结果送入普通 cron run pipeline。
- `stream` 由 Gateway watcher 托管 argv，按 line/match 和 batch 边界把输出交给 cron 执行；其 source identity 在禁用、删除、替换时轮换。

`on-exit` watcher 在 spawn 尚未完成时就占用 job slot，取消或替换会使迟到的 child 被杀掉；spawn/wait 失败按递增退避重新 arm，未知 wait 结果不会直接触发 job。观察命令的 24 小时上限、重试间隔和 ownership token 见 `src/gateway/cron-exit-watchers.ts:7-15,86-109,111-137,180-231,251-259`。时间 timer、stream watcher 和 exit watcher 的 reconciler 都会在 job mutation 或 Gateway 生命周期变化后重读持久 job；其内部 watcher 状态不替代 cron receipt。

### Heartbeat monitor 与 wake bus

heartbeat 周期不是另一个散落的 timer，而是由 `heartbeat:<agentId>` declaration key 标识的 system-owned cron job。配置解析默认周期是 `30m`；按 Agent 配置、显式 heartbeat owner 或环境中的 ambient owner 生成 monitor，monitor 的 `sessionTarget` 为 `main`，`wakeMode` 为 `next-heartbeat`。Gateway convergence 会创建、更新或删除这些系统 job，系统 job 不能由普通客户端 payload 直接创建或编辑（`src/auto-reply/heartbeat.ts:6-18`、`src/infra/heartbeat-config.ts:22-80`、`src/cron/heartbeat-monitor.ts:32-145`、`src/cron/types.ts:296-324`）。

monitor job 执行时不直接完成模型回合，而是把 scheduled wake 送入 heartbeat wake bus。hook、cron main job、后台 task、exec completion 和手动请求也可以进入同一个 bus。wake bus 以 agent/session target 分组，每个 target 同时最多一个活跃 heartbeat turn；不同 target 可并行，跨 target 的 wake fan-out 上限为 4。相同 target 的 task、scheduled、event wake 会合并，保留优先级、顺序和待处理 task；busy、preempted 和请求在途的可重试跳过会在 wake 层保留或重新排程（`src/infra/heartbeat-wake.ts:38-121,144-211,214-337`）。

Heartbeat runner 在真正调用 `runOnce` 前检查：全局 heartbeat 开关、目标是否已配置、quiet hours、主 lane 请求、其他 cron/cron-nested/hook-dispatch 活跃工作、同 Agent 的 reply/embedded run、目标 session lane 和 pending final delivery。普通 interval tick 在忙碌时返回 retryable skip；manual/immediate wake 的优先级更高。调度状态保存在 runner 的进程内 cooldown/flood ring buffer，monitor cadence 本身由持久 cron job 提供（`src/infra/heartbeat-runner-scheduler.ts:50-141,191-234,250-374`、`src/infra/heartbeat-runner-execution.ts:149-388`）。

### 外部 hooks/webhooks

Gateway hook HTTP handler 的职责是认证和 admission，不是直接执行模型。它要求 POST、Bearer 或 `X-OpenClaw-Token`，限制 body 大小，解析 `wake` 或 `agent` payload，并检查 Agent allowlist、session key 允许前缀、持久 session 的必要条件和 delivery 字段。配置 mapping 可以将一个外部 payload fan-out 为多个 wake/agent action；重复的 agent dispatch 使用 token、路径、dispatch scope 和 idempotency key 组成的进程内 replay cache，fan-out 没有显式 idempotency key 时从 action scope 派生稳定身份（`src/gateway/server/hooks-request-handler.ts:314-411,427-565,568-704`）。

`wake` hook 把文本放进目标 session 的 system event 队列；`mode=now` 进一步请求 heartbeat immediate wake，`next-heartbeat` 只等待后续 heartbeat。`agent` hook 则创建一个当前时刻的 `at` cron job：persistent 模式使用 `session:<sessionKey>`，默认 isolated 模式使用独立 detached run；payload 是 `agentTurn`，并把 model、thinking、timeout、external content source 和 delivery 一并冻结在 job 中（`src/gateway/server/hooks.ts:266-293,295-328`）。

真正的 hook agent dispatch 使用同一 session key 的进程内串行队列，避免多个 hook 同时对同一 session 争夺 lifecycle claim；不同 session 可并行。默认 admission 起始等待上限为 15 秒，fan-out action 可声明 `admissionMode=background`，让 producer redelivery 与 replay cache 而不是 HTTP start deadline 承担慢 admission 的重试。执行从 lazy-loaded isolated cron runner 进入 `CommandLane.HookDispatch`，并在 runner 启动或 lane 等待结束时向 HTTP 调用方确认 admission（`src/gateway/server/hooks.ts:58-63,174-193,239-264,404-523`）。

hook run 完成后，如果要求 delivery 但 run 没有自行交付，dispatcher 将摘要写入目标 session 的 system event，并按 `wakeMode` 请求 heartbeat；失败同样写入错误 event。外部 plugin 的 `dispatchHookAgentTurn` 只接受 `hook:` session key、`externalContentSource=email` 和 isolated 模式，然后复用上述 hook cron pipeline，idempotency key 仍只保留在进程内（`src/gateway/server/hooks.ts:524-617,626-717`）。因此 hook HTTP 层本身不提供跨重启的 replay ledger；一旦已创建 run，后续事实由 cron/session/task 运行记录负责。

### 后台 CLI exec

exec 的 continuation 选项是 Agent 回合中的后台化动作，不等同于 cron。`yieldMs` 到期或 `background=true` 时，exec pipeline 先将 ProcessSession 标为 backgrounded，再创建 `runtime="cli"`、`taskKind="exec"` 的 task run；如果进程在 yield timer 之前已经结束，则不登记后台 task。原始进程由 `ProcessSupervisor` 托管，内存 registry 保存 running/finished session、有限输出、PID、退出码和 notify-on-exit 状态（`src/agents/bash-tools.exec-run.ts:683-719`、`src/agents/bash-tools.exec-task-tracking.ts:15-55`、`src/agents/bash-process-registry.ts:135-179,266-296,343-400`）。

进程结束时，sandbox finalization 先完成，随后通过 `onSettledBeforeNotify` 把退出结果映射为 `succeeded`、`failed`、`timed_out` 或 `cancelled` 并写入 task ledger。若后台 session 尚未被 terminal poll 观察，且 `notifyOnExit` 开启，exec 会把紧凑输出写入 system event，并请求目标 heartbeat；空输出成功默认不通知，手动取消且无输出也不通知。subagent session 不走这一 heartbeat fallback，因为其结果由 process poll 和 subagent announce flow 交付（`src/agents/bash-tools.exec-runtime.ts:344-415,815-859`、`src/agents/bash-tools.exec-task-tracking.ts:58-105`）。

取消必须到达真实进程：后台 process control 检查 session 仍为 backgrounded、未退出且未 finalizing，再调用 `ProcessSupervisor.cancel(..., "manual-cancel")`。exec task ledger 的持久记录和进程 registry 都是 Gateway 进程内能力；本次未在该路径找到一个可跨 Gateway 重启重新连接原始 CLI child 的持久 worker owner，所以 task 记录能保留终态投影，但不能单独证明原进程在重启后仍可恢复（`src/agents/bash-process-control.ts:5-20`、`src/agents/bash-process-registry.ts:29-30,333-400`）。

### Detached subagent 与 requester continuation

`sessions_spawn` 的主链是：解析 requester/target Agent、depth、模型、sandbox、thread 和 completion policy；创建并持久化 child session；准备 context engine、附件和 prompt；向 native Gateway `agent` dispatch；Gateway 接受后登记 child run；完成时由 registry 捕获结果并交付 requester。spawn pipeline 区分 initialize、dispatch、register 和 cleanup 阶段；Gateway 已接受但 registry 注册失败时会尝试终止 accepted child，避免出现无人持有的运行（`src/agents/subagents/spawn/subagent-spawn.ts:97-205,333-403`、`src/agents/subagents/spawn/subagent-spawn.ts:427-518`）。

每个 detached subagent 有 `runId`、child session key、requester session、task、model、workspace、timeout、spawn mode、completion expectation 和 delivery state。核心事实持久在 `subagent_runs`，关联 task ledger 可提供统一任务/flow 展示；schema 同时保存 `endedAt`、outcome、pause/kill、announce retry、frozen result、pending final delivery 以及 requester settle wake 字段（`src/state/openclaw-state-schema.sql:1573-1644`）。

子 Agent 结束后，registry 根据 outcome 生成 completion payload。若 requester 正在运行，结果可以先进入 steering queue：queue item 按完成时间稳定排序，单项结果和合并 prompt 都有字符上限；注入 requester 前标为 `in_progress`，注入成功变为 `delivered`，失败或 stale lease 则释放回 pending/suspended。该队列的作用是把子 Agent 结果作为 runtime data 回注下一次 requester turn，而不是伪装成用户指令（`src/agents/agent-steering-queue.ts:11-24,39-91,94-124,184-275`）。

如果 requester 使用 `sessions_yield` 等待子任务，registry 会持久化 requester settle wake state。最后一个直接或后代子 Agent 进入 terminal settle 后，系统冻结同一批次，确认所需 completion 已交付且没有未结算 descendant，然后构造“所有子 Agent 已 settle”的内部 wake，使用稳定 idempotency key 重入 requester session。该 wake 最多执行有限次，区分普通失败和 transport ambiguous replay；`requester-settle-wake` 还会避免 cron requester 获得不适合的二次唤醒（`src/agents/subagents/announce/subagent-announce.requester-settle-wake.ts:189-333,401-546`）。

子 Agent 的 direct completion 交付优先复用 requester origin 或 requester session；无法直接投递时进入 session delivery queue。对需要生成媒体或必须跨 restart 保持的 session handoff，先持久化 `agentTurn` queue entry，再由 session delivery runtime 重新执行或 dead-letter；已发送但终态结算不明时保留 durable ownership，避免 live path 与 recovery 同时发布终态（`src/agents/subagents/announce/subagent-announce-delivery.ts:77-105,110-220`、`src/infra/session-delivery-queue-storage.ts:20-98,146-220,268-355`）。

## 执行、结果交付与状态更新

### Cron 的执行域、Agent、模型与工具

cron run 激活后先创建 `runtime="cron"` 的 task ledger record，记录 job、Agent、run id、开始时间和进度；随后由 `executeJobCoreWithTimeout` 统一包住 payload 执行、主 webhook、超时 watchdog、取消和 receipt settlement。每次 run 都有 active job marker；隔离 Agent 还绑定 session lifecycle claim、run context、plugin registry generation 和 session work admission，最终在 session persistence、delivery construction 和 receipt finalization 之后释放内存引用（`src/cron/service/run-admission.ts:474-642`、`src/cron/service/task-runs.ts:139-159,285-341`、`src/cron/isolated-agent/run.ts:144-275,326-358,399-466`）。

`isolated` Agent turn 的准备阶段解析有效 Agent、Agent directory/workspace、session key、当前或 detached run session、skills snapshot、delivery plan、模型和 thinking selection。payload 可以指定 model、fallbacks、thinking、timeout、light context 和 `toolsAllow`；执行时将已解析的 provider/model、工具策略、plugin registry 和 scheduled tool policy 传给 embedded Agent runner。cron 运行携带的 runtime authority 与创建时的工具 allowlist 绑定，执行运行时若候选 runtime 不匹配会拒绝，不通过普通 job 字段重新猜测权限（`src/cron/isolated-agent/run-prepare.ts:140-240,241-355`、`src/cron/isolated-agent/run-executor.ts:84-98,246-324`）。

main job 的 payload 实际上只能形成 system event 文本。它写入目标 session 的 event 队列，并按 `wakeMode` 立即运行 heartbeat 或等待下一次 heartbeat；`wakeMode=now` 遇到同一 cron marker 之外的竞争工作时，会在有限等待窗口内重试，超时则重新请求 wake 而不把 event 丢掉。isolated job 的 `command` 不启动模型，直接使用 `runCommandWithTimeout`；`agentTurn` 进入 isolated runner；script 则由 script runtime 执行，成功后可产生 notify、wake、next_check 和 script state（`src/cron/service/timer-execution.ts:240-357,360-480,482-565`）。

### Cron 结果和状态

执行结果与交付结果分开记录。`CronRunStatus` 是 `ok`、`error` 或 `skipped`；delivery 另有 `delivered`、`not-delivered`、`unknown` 和 `not-requested`。最终 job state 保存最近运行时间、状态、错误、持续时间、连续错误/跳过次数、下一次运行、delivery status/error 和 failure notification delivery，run history/task ledger 则保存本次运行的 session、model、provider、usage、diagnostics 和摘要（`src/cron/types.ts:114-160,229-244,398-475`）。

隔离 Agent 的 finalize 顺序是：读取模型/usage/diagnostics，更新 session runtime model、context token 和 CLI binding，持久化 session entry；解析 payload 是否有可交付文本或结构化结果；按 delivery plan 发送；最后由 cron service 在 receipt-owned transaction 中把结果应用到 authoritative job row、更新 task ledger、发出 finished event，并计算下一次运行。一次性 run 的 detached session 可在交付后清理，persistent session 则保留 session 生命周期（`src/cron/isolated-agent/run-finalize.ts:58-177,301-395`、`src/cron/isolated-agent/run.ts:347-466`）。

cron delivery 支持 `none`、`announce` 和 `webhook`。announce 会解析 channel、target、account、thread 和 session route，使用 durable message sender；current session 的交付还要求最终 transcript commit，不能只因平台发送成功就把 run 标为已完成。primary webhook 在执行结果 settled 后发送 finished-run event；webhook delivery 自身也受同一 run abort/receipt current 检查保护（`src/cron/types.ts:64-112`、`src/cron/delivery.ts:39-139`、`src/cron/service/timer-job-runner.ts:57-159`）。

command payload 的默认超时为 10 分钟；script payload 默认 300 秒、上限 900 秒，默认 tool budget 为 50、上限 200。script 和 trigger 是否可用由 `cron.triggers.enabled` 控制；trigger 是无模型的 headless evaluator，结果中的 `fire=false` 只更新 trigger state，`fire=true` 才执行 payload，且失败/超时也会进入 run failure 语义。依据见 `src/cron/command-runner.ts:9-20,77-111`、`src/cron/script-payload.ts:3-31`、`src/cron/service/timer-execution.ts:482-565`。

### Heartbeat 回合与结果

heartbeat runner 先通过 wake stage 解析 Agent、heartbeat prompt、scheduled tasks、session 和目标 delivery；然后检查忙碌与生命周期条件，创建普通或 `isolatedSession` heartbeat session。孤立 heartbeat 每次使用新的 session ID 和空 transcript，但仍从 base session 解析 last route，因此减少重复发送完整历史的成本（`src/infra/heartbeat-runner-execution.ts:394-418,487-559`）。

模型结果经过 heartbeat outcome classifier：纯 `HEARTBEAT_OK`、短 acknowledgment 或静默结果不打扰用户；可见文本、媒体或 heartbeat response tool 的 notify=true 才进入 channel delivery。成功的结构化 heartbeat response 会写入每个 agent session 一行的 `heartbeat_outcomes`，保留 outcome、summary、priority、next check、task names、wake source/reason、run session 和 claim 信息；这份结果是内部状态，不等同于用户消息（`src/infra/heartbeat-runner-delivery.ts:173-304,306-369`、`src/infra/heartbeat-outcome-store.ts:91-156`、`src/state/openclaw-agent-schema.sql:343-359`）。

heartbeat channel 发送同样使用 `sendDurableMessageBatchCore`。失败通知可走 channel 或 indicator；可见发送成功后更新 `lastHeartbeatText`/`lastHeartbeatSentAt` 并清理所拥有的 pending final delivery。因无路由、channel 未就绪、重复内容或 alerts disabled 而不发送时，runner 仍返回 `ran` 或 typed `skipped`，并写 heartbeat event 说明原因（`src/infra/heartbeat-runner-run.ts:35-191`、`src/infra/heartbeat-runner-delivery.ts:323-463`）。

### 统一 durable channel delivery

channel 发送的 write-ahead 边界位于 prepared payload 之后：先按 delivery intent 和 channel 能力准备 payload，再将 `delivery_queue_entries` 写入 SQLite，之后才调用平台 adapter；成功后删除 pending row，或按 completion retention 保留 completed tombstone。发送过程具有 producer lease、platform-send lease、retry count、last error、recovery state 和 `unknown_after_send` 等字段，平台调用已开始但结果不明时不会盲目重新发送（`src/infra/outbound/deliver-queue.ts:205-244,245-313,351-407`、`src/infra/delivery-queue-sqlite.ts:34-46,218-264,284-338`）。

`sendDurableMessageBatchCore` 将 payload 结果分为 sent、suppressed、partial_failed 和 failed，并保留 `sentBeforeError` 事实；这使 cron、heartbeat、task/subagent completion 能区分“没有发送”“部分发送”与“可能已经到达 recipient”。channel 层的 runtime barrel 只暴露 durable sender 和 recipient ambiguity helper，真正的 transport 由 outbound queue/runtime 处理（`src/channels/message/send.ts:36-107,109-177,232-374`、`src/channels/message/runtime.ts:1-15`）。

## 并发、取消、失败与恢复

### Cron 并发与取消

cron service 的默认并发上限是 8，timer 不会在容量耗尽时无限保留一个异步 tick，而是将候选 job 的 durable reservation 保留到 capacity release 或 bounded safety recheck；容量释放会立即触发重新检查。Gateway 还把 `cron-nested` 与 `hook-dispatch` 放入同一 aggregate group，hooks 开启时预留一个 hook slot，保证外部 hook 不被 cron inner work 饥饿，同时不超过 cron 总预算（`src/config/cron-limits.ts:1-14`、`src/cron/service/run-admission-capacity.ts:1-104`、`src/gateway/server-lanes.ts:28-94`）。

job disable、remove、schedule edit 和 trigger edit 都是带 ownership 语义的持久 mutation。禁用会请求 exact active marker 取消；删除会把 active marker 标记为 removed 并取消真实 controller；配置 revision 或 trigger mutation 会阻止旧 run 把结果覆盖到新定义。取消不是只改数据库：isolated Agent 的 abort signal、cron lane task、ProcessSupervisor child 和 session lifecycle claim 都会在各自 owner 边界收到取消或 replacement（`src/cron/active-jobs.ts:90-182,224-300`、`src/cron/service/active-run-cancellation.ts:38-117,162-177`、`src/cron/service/ops-mutations.ts:206-255`）。

超时路径会先给运行创建 abort controller，再通过 watchdog 监听 detached Agent 的 setup/runner phase；如果模型或工具忽略 abort，底层 Promise 仍保留在 settlement tracking 中，避免 Gateway 认为资源已经空闲而让旧 core 继续写状态。执行结束后才释放 task/receipt/active marker，session work admission 和 browser/MCP 生命周期也在 final persistence/delivery 后释放（`src/cron/service/timer-job-runner.ts:187-243,319-437`、`src/cron/service/active-run-cancellation.ts:11-35,94-159`）。

### Cron 失败、退避与告警

执行失败后，循环 cron 使用连续错误次数和固定 backoff schedule 计算下一次重试，默认退避为 30 秒、60 秒、5 分钟、15 分钟、1 小时，之后保持末项。一次失败同时更新 `lastError`、diagnostics、duration、delivery 状态和 task/run history；delivery failure 与 Agent execution failure 分开记录，必要时可走 alternate failure route（`src/cron/service/jobs-scheduling.ts:48-102`、`src/cron/types.ts:398-475`、`src/cron/service/failure-alerts.ts:24-37,92-191`）。

显式或继承的 failure alert 默认在连续 2 次失败后告警，默认 cooldown 为 1 小时；可选择 announce 或 webhook、channel/account/recipient，并可决定是否计入 skipped。time-based recurring job 连续 10 次执行失败会自动禁用，写入 `autoDisabled` 和 operator-visible notification；system-owned heartbeat monitor 等 job 不由该规则自动禁用，因为它们由 Gateway convergence 重新投影（`src/cron/service/failure-alerts.ts:24-25,178-191`、`src/cron/service/auto-disable.ts:11-63,66-85`）。

### 重启、重复触发与 catch-up

Gateway 启动时读取所有 queued/running marker，结合 receipt owner PID 和 process start time 判断当前 owner 是否仍然存活。确认 owner stale 后，恢复流程按 receipt identity、job marker、config revision 和 task ledger 重新读取：如果 task ledger 已有完整终态，恢复该终态；否则把 run 记为 `interrupted`，恢复 schedule state、failure notification 和下一次运行；job 已删除时仍可保留并结束 receipt。receipt 是 CAS/fence，单靠相同 job ID 或毫秒时间戳不足以让旧 owner 继续写入（`src/cron/service/run-recovery.ts:66-230,251-301`、`src/cron/store/run-receipt-store.ts:298-340`）。

启动 catch-up 会对 missed jobs 排序，默认最多立即运行 5 个，并以 5 秒间隔 stagger；超出即时容量的任务持久化 deferred state。Agent turn missed jobs 默认延后 2 分钟，避免 Gateway 启动时同时承担模型和工具 bootstrap；执行中止或 finalization 失败时释放未激活 reservation，并保留可重算的下一次运行时间。该策略倾向于一次有边界的补跑，而不是重放所有错过的时刻（`src/cron/service/timer-execution-timeout.ts:23-40,98-137`、`src/cron/service/timer-catchup.ts:195-343`）。

重复的 Gateway tick、手动 force run、配置 A→B→A 和禁用→启用由不同层的 identity 共同约束：queued/running marker 防止同一 job 在本进程重入，SQLite active receipt 防止跨进程重入，config revision 防止旧定义写回，stream source identity 防止旧 watcher 的 batch 被新 watcher 接收。timer 自身最多将下一次 wake 延后到 60 秒，并对立即过去的时间点施加 refire gap，防止 event loop 被 `setTimeout(0)` 热循环占满（`src/cron/service/timer-scheduler.ts:49-103`、`src/cron/service/jobs-scheduling.ts:216-270`）。

### Heartbeat 忙碌、失败与恢复

heartbeat 的 busy 不是丢弃任务：requests-in-flight、cron-in-progress 和 preempted 等 skip reason 会由 wake layer 作为可重试 wake 保留；没有 pending event 的 exec completion 则是已确认的非重试情况。runner 的 cooldown、minimum spacing 和 flood guard 限制事件唤醒频率；scheduled tick 携带 authoritative cadence，不会被普通事件 cooldown 改写。runOnce 抛错返回 `failed`，heartbeat event 记录失败原因；channel 失败也会保留失败通知路径或在下一次恢复中再次处理（`src/infra/heartbeat-wake.ts:38-50`、`src/infra/heartbeat-runner-scheduler.ts:241-374`、`src/infra/heartbeat-runner-run.ts:143-187`）。

heartbeat monitor job 本身借用 cron 的 receipt、startup recovery 和调度状态，但 heartbeat wake bus 的 pending wake、cooldown 和 active target 是进程内状态。代码快照可确认 monitor job 会在 Gateway convergence 时重新生成，且事件触发可在未启用 recurring interval 时针对已配置 Agent 一次性运行；未运行验证跨 Gateway restart 时进程内 pending wake 是否在所有入口都能得到等价重建。

### Hook、exec、subagent 和交付恢复

- hook HTTP replay cache、plugin hook replay map 和 same-session dispatch tails 都是进程内协调状态。它们防止同一 Gateway 生命周期中重复 admission，但不是 durable queue；已创建 hook cron run 的恢复交给 cron receipt/task/session 记录。
- 后台 exec 的 `ProcessSession` 和 ProcessSupervisor child 是进程内 owner。task ledger 的终态写入有失败日志，但没有看到从 SQLite task row 重新取得原始 child 的通用重启恢复路径；进程重启后的结果取决于具体 host/Gateway lifecycle 和外部进程 owner，不能从 task row 单独推断可恢复。
- subagent registry 在启动时从 SQLite 恢复 rows，先 reconcile orphaned run、补齐 requester owner、更新 archive deadline，再启动 listener/sweeper；未结束 run 重新等待或走 restart recovery，已结束但未交付 run 走 announce/delivery resume。恢复失败会按 1 秒起步、最多 30 秒的 retry timer 重试（`src/agents/subagents/registry/subagent-registry-restore.ts:48-49,110-146,149-207,295-349`）。
- subagent completion announce 对临时 transport error 使用有限重试，看到已有 platform send evidence 时不重放；required completion 的 retry/deadline 与普通 announce expiry 分开。跨 session 的 durable handoff 使用 SQLite session delivery queue，失败会增加 retry metadata，最终可移到 failed/dead-letter，而不是静默删除（`src/agents/subagents/announce/subagent-announce-delivery-retry.ts:15-37,145-175,227-265`、`src/infra/session-delivery-queue-storage.ts:358-425`）。
- channel outbound queue 在 provider 调用前持有 SQLite row 和 producer/platform lease。发送成功后删除或保留 tombstone，部分失败和 unknown-after-send 交给 recovery；因此断线、重启或重复 producer redelivery 可以查到同一 delivery identity，而不是只依赖日志。

## 相邻类目交接与已确认边界

- **会话与消息管理。** cron main、heartbeat、hook wake 和 background task 都通过 session key、system event 或 heartbeat 重新进入会话；isolated cron、hook agent 和 subagent 则创建或使用 detached session。session entry、transcript、lifecycle claim、pending final delivery 和 session cleanup 属于会话管理边界，本笔记只记录它们如何承接主动运行身份。
- **Agent 工具。** `automations`、`exec`、`process`、`sessions_spawn` 和 `sessions_yield` 是触发或控制入口；工具 schema、sandbox、approval、MCP/tool allowlist 和模型循环留在 Agent 工具类目。本笔记只记录自动化运行在执行前如何冻结 Agent/model/tools authority，以及后台控制是否能到达真实执行体。
- **外部执行体。** on-exit/stream watcher、ProcessSupervisor、node host 和外部 ACP 是 OpenClaw 与执行体之间的交接点。外部 ACP 自身的调度、内部恢复和身份绑定不在本次范围；OpenClaw 侧只记录 spawn/dispatch、run identity、结果回收和交付。
- **Follow-up/steering queue。** follow-up runner 负责当前进程中一个已排队回合的 admission、执行、accounting 和 delivery；执行完成后即使 presentation/accounting/delivery 失败，也不会重新 replay 已产生副作用的模型/工具执行。它是会话内续作和主动运行之间的交接，不是独立的持久日程（`src/auto-reply/reply/followup-runner.ts:27-61,78-137,138-187`）。
- **System events。** system event 适合承接“下一回合需要看到的完成/失败提醒”，但队列本身不持久化，不能单独回答“任务是否运行过”。cron receipt、task row、heartbeat outcome 和 session delivery queue 才是相应运行形态的状态 owner。
- **通知与平台交付。** cron/heartbeat/subagent/task 的 channel-visible 结果统一进入 durable message/outbound delivery 层。平台 adapter 的具体能力、账号和线程路由不在本笔记展开；本文把 queue custody、delivery status、partial failure 和 unknown send 作为主动运行的结果边界记录。
- **独特功能与记忆。** heartbeat scratch、script state、skill collection review 和上下文/记忆注入可以被主动运行驱动，但它们各自的内容语义属于相邻类目；这里仅记录其作为 cron/heartbeat payload 的触发、状态和交付承载。
- **未找到的独立 worker。** 在本次检查的 cron、heartbeat、hooks、exec、subagent 和 task/delivery 路径中，未找到一个统一的跨进程通用 worker queue；持久性由 cron receipt、subagent registry、session delivery queue 和 outbound delivery queue 分别承担，不能把它们合并称为单一后台队列。

## 未验证事项

- 未启动实际 Gateway、Channel adapter、Provider 或 ProcessSupervisor；cron 的真实到期时刻、heartbeat 的平台消息、hook HTTP round trip、command 子进程终止和 channel 账号/线程投递仍是静态代码结论。
- 未验证多个 Gateway 进程同时读取同一 state DB 时的 receipt owner 判断、PID start time 观测、跨进程锁和 foreign receipt monitor 的真实时序。
- 未验证启动 catch-up 在真实长停机、系统时钟回拨、模型 provider 不可用和大量 deferred Agent jobs 下的端到端行为；代码已确认默认上限、延迟和 reservation 清理路径。
- 未验证 heartbeat 的进程内 pending wake、cooldown/flood 状态在 Gateway restart、配置 reload、Agent owner 变化和 isolated heartbeat session 迁移后的实际表现。
- 未验证 hook producer 在 HTTP 503、fan-out deadline、重复 redelivery 和 Gateway 重启之间的实际交互；代码已确认 replay cache 仅为进程内状态，fan-out action 会使用 background admission。
- 未验证后台 exec 在 Gateway 重启、node host 执行、shell 进程树和 sandbox finalization 失败时的真实 operator-visible 终态；代码可确认正常完成、超时、手动取消和 notify-on-exit 的映射。
- 未验证 detached subagent 在 provider 迟到完成、requester session 被归档、多个后代同时 settle、restart recovery launch 失败和 delivery dead-letter 后的实际消息可见性；代码可确认持久 registry、steering lease、settle wake 和 session delivery queue 的设计路径。
- 未运行测试套件；本笔记引用了与这些路径相邻的测试文件作为源码索引线索，但没有把测试名称当作真实部署行为证明。

## 关键源码索引

- `src/gateway/server-cron-lazy.ts:34-100`、`src/gateway/server-cron.ts:388-407,768-769`：Gateway cron lazy loading、enabled 判定和 CronService 构造。
- `src/cron/service/ops-lifecycle.ts:119-211`、`src/cron/service/timer-scheduler.ts:49-169,171-264`：启动恢复、timer tick、due job reservation 和重排。
- `src/cron/service/run-admission.ts:221-357,363-471,474-664`、`src/cron/service/run-admission-capacity.ts:1-104`：receipt reservation、激活、并发槽和统一执行。
- `src/cron/store/run-receipt-store.ts:30-44,298-340`、`src/state/openclaw-state-schema.sql:1331-1452,1527-1644`：cron receipt、job/task/subagent 的 SQLite 权威结构。
- `src/cron/service/timer-execution.ts:36-237,240-357,360-565`、`src/cron/isolated-agent/run.ts:144-275,347-466`：payload 分派、main/detached session、Agent run lifecycle 和 cleanup。
- `src/cron/isolated-agent/run-prepare.ts:140-355`、`src/cron/isolated-agent/run-executor.ts:84-98,246-324`、`src/cron/isolated-agent/run-finalize.ts:58-177,301-395`：Agent/model/tools 准备、执行与终态持久化。
- `src/cron/delivery.ts:39-139`、`src/cron/isolated-agent/delivery-dispatch.ts:75-233`、`src/cron/service/timer-job-runner.ts:57-159,187-437`：announce、webhook、durable delivery 和 timeout/cancel。
- `src/cron/service/jobs-scheduling.ts:48-102,216-270`、`src/cron/service/timer-catchup.ts:195-343`、`src/cron/service/run-recovery.ts:66-230`、`src/cron/service/startup-run-repair.ts:18-230`：backoff、missed-job catch-up、stale owner recovery 和 interrupted run repair。
- `src/cron/heartbeat-monitor.ts:32-145`、`src/auto-reply/heartbeat.ts:6-18`、`src/infra/heartbeat-config.ts:22-84`：system-owned heartbeat monitor、默认周期和 Agent enrollment。
- `src/infra/heartbeat-wake.ts:38-121,214-337`、`src/infra/heartbeat-runner-scheduler.ts:50-141,191-374`、`src/infra/heartbeat-runner-execution.ts:149-388`：wake coalescing、并发、busy skip、cooldown 和执行 preflight。
- `src/infra/heartbeat-runner-run.ts:35-191`、`src/infra/heartbeat-runner-delivery.ts:173-304,306-463`、`src/infra/heartbeat-outcome-store.ts:91-156`：heartbeat 回合、静默/可见结果、channel 交付和结构化 outcome。
- `src/gateway/server/hooks-request-handler.ts:314-565,568-755`、`src/gateway/server/hooks.ts:266-328,404-617,626-717`：HTTP hook 认证、mapping/fan-out、幂等、wake 和 hook-agent cron dispatch。
- `src/agents/bash-tools.exec-run.ts:683-719`、`src/agents/bash-tools.exec-task-tracking.ts:15-105`、`src/agents/bash-tools.exec-runtime.ts:344-415,815-859`：后台 exec task registration、终态和 notify-on-exit。
- `src/agents/bash-process-control.ts:5-20`、`src/agents/bash-process-registry.ts:135-179,266-400`：后台进程取消、session registry 和有限 retention。
- `src/agents/subagents/spawn/subagent-spawn.ts:97-205,333-403,427-518`：subagent session、spawn pipeline、Gateway dispatch 和失败清理。
- `src/agents/subagents/registry/subagent-registry.ts:107-171,228-323`、`src/agents/subagents/registry/subagent-registry-restore.ts:149-349`：subagent lifecycle registry、delivery resume 和启动恢复。
- `src/agents/agent-steering-queue.ts:39-91,94-124,184-275`、`src/agents/subagents/announce/subagent-announce.requester-settle-wake.ts:189-333,401-546`：结果 steering、settle wake、批次冻结和重试。
- `src/agents/subagents/announce/subagent-announce-delivery.ts:77-105,110-220`、`src/agents/subagents/announce/subagent-announce-delivery-retry.ts:145-175,227-265`：subagent completion direct/queued delivery 和 retry policy。
- `src/infra/system-events.ts:1-4,38-47,122-205`、`src/auto-reply/reply/followup-runner.ts:27-61,78-187`：非持久 system event、follow-up queue 和会话续作边界。
- `src/infra/outbound/deliver-queue.ts:205-244,245-313,351-407`、`src/infra/delivery-queue-sqlite.ts:218-338`、`src/channels/message/send.ts:36-177,232-374`：统一 durable channel queue、lease、partial/ambiguous send 和消息结果分类。
