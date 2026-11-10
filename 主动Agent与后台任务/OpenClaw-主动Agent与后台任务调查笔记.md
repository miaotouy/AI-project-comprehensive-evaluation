# OpenClaw 主动 Agent 与后台任务调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：只读复查 cron service、heartbeat wake/runner、Gateway hooks、后台 exec、detached subagent、task ledger、SQLite schema 和 durable channel delivery 的可执行调用链；结合对应作用域规则与同类调查笔记，未启动 Gateway 或定时器
>
> 调查范围：覆盖持久自动化、条件唤醒、外部 hook、后台 CLI 进程、detached subagent 及其结果交付、取消、失败、重试和重启恢复；普通当前回合工具调用、内建 Agent 循环、外部 ACP 内部调度和普通同步消息不作为独立主链展开
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前代码快照中的主动运行由几种运行形态组成，它们共享 Gateway 生命周期和结果交付设施：

| 运行形态 | 触发与运行对象 | 状态事实源 | 执行与结果归属 | 证据状态 |
| --- | --- | --- | --- | --- |
| 持久隔离日程运行：automations/cron | 用户或 Agent 通过 `automations` 工具、Gateway RPC 或 CLI 保存 job；到期后由 `CronService` 认领一次运行 | SQLite `cron_jobs` 加 job 状态与 `cron_run_receipts` | `main` 目标进入 heartbeat/主会话；`isolated` 或 `current` 使用 detached cron run session；可执行 Agent、command 或 script | 主链确认（静态证据） |
| 条件唤醒：heartbeat | 系统拥有的 `heartbeat:<agentId>` monitor job 或 hook、事件、后台任务等 wake 请求 | monitor job 与 agent session 的持久字段；最近结构化结果在 agent DB 的 `heartbeat_outcomes` | 重新进入配置 Agent 的 heartbeat 回合，可静默、发消息或写入内部结果 | 主链确认（静态证据） |
| 外部事件：hooks/webhooks | Gateway HTTP hook 认证后产生 wake，或合成一次性 Agent cron job | HTTP 层只有进程内幂等缓存；实际运行沿用 cron receipt、task ledger 和 session 状态 | wake 注入 heartbeat；agent hook 进入隔离 Agent runner，同一 session 串行 | 主链确认（静态证据） |
| 后台 CLI exec | Agent 的 exec 在 yield/background 后保留受监管的 process session，并返回后续控制身份 | 进程 session registry 为进程事实；session async-task 状态为任务投影；两者均受进程生命周期影响 | ProcessSupervisor 持续托管进程；完成时可写 system event 并请求 heartbeat，也可由 process poll 取回 | 主链确认（静态证据） |
| Detached subagent | `sessions_spawn` 创建子 session 并登记 run；Gateway 接受后异步执行 | SQLite `subagent_runs` 与 session delivery queue | 子 Agent 在独立 session 运行，结果直接交付、注入 requester steering，或在所有子项结束后唤醒 requester | 主链确认（静态证据） |

最持久、最完整的后台任务主链是 cron：定义、排程、运行 fence、执行结果、交付结果和恢复都由 Gateway/SQLite 共同拥有。heartbeat 的周期 monitor 实际投影为系统拥有的 cron job，但具体 Agent 回合和忙碌退避由 heartbeat wake/runner 管理。hook agent 把外部事件转换成一次性 cron run，复用同一套 cron worker。后台 exec 的进程本身仍由进程监管器和内存 registry 托管，SQLite 任务记录主要提供客户端可见的运行投影；detached subagent 则有更完整的持久注册、结果冻结、交付和重启恢复链。

## 系统边界与主链

### 统一的 cron 主链

Gateway 首次出现 cron 需求时，才由 lazy loader 构造一个 `CronService`；只要 cron.enabled 没有被显式关掉，环境中也没有 OPENCLAW_SKIP_CRON=1，这个服务就允许自动运行。启动阶段先把 SQLite 里的 job 读出来并校验，把仍带 queued/running marker 的非终态 receipt 修复掉，再处理重启 catch-up，最后按最近一次 nextRunAtMs 设好 timer。每次 tick 都在 Gateway root work admission 内执行：读取到期 job，取得并持久化 queued reservation 与 running receipt，然后进入统一的执行和终态写入路径（`src/gateway/server-cron-lazy.ts`、`src/gateway/server-cron.ts`、`src/cron/service/ops-lifecycle.ts`、`src/cron/active-jobs.ts`）。

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

job 的 sessionTarget 字段决定一次运行落在哪里：main 目标把 system event 放进目标会话，再请求 heartbeat runner 接管；指定会话与其他目标交给 detached cron runner，其中 `session:<key>` 复用指定持久会话，isolated/current 目标使用独立 run session。runsDetachedFromMainSession 另外把 script 和 skill collection review 判定为需要独立 task 与 lifecycle 处理的运行。目标解析与运行会话准备分别见 `src/cron/session-target.ts:22-37` 和 `src/cron/isolated-agent/run-prepare.ts:190-283`。

system event、follow-up 和 steering queue 是结果进入下一回合的传输层，不是独立持久任务。system event 队列要求显式 session key，最多保留 20 项，运行时只存在进程内；它会在 heartbeat 或下一次会话提示构造时被筛选、消费。`src/infra/system-events.ts` 明确说明该队列故意不持久化，因此只能承接已有主动运行的提示或终态，不能单独承担重启后的任务恢复。

## 触发、调度与运行对象

### 持久更新运行

软件更新也形成独立后台运行对象。每次更新先在共享 SQLite 的 `update_runs` 中创建 running 记录，保存触发源、目标、更新前后事实、阶段步骤、验证、修复记录和终态；步骤有数量上限，关键恢复步骤会保留。驱动进程必须显式 adopt 运行，读取或预留记录不会自动取得执行权；启动或人工修复时可识别死亡驱动、遗留无身份运行和已保存 recovery，再决定继续、恢复或标记 abandoned。该机制把候选准备、安装、验证、回滚与重启交接纳入可查询账本，而不是只依赖安装进程日志。实现见 `src/infra/update-run-ledger.ts`、`src/infra/update-run-activity.ts`、`src/infra/update-run-record.ts`。

### Automations/cron 的创建与排程

Agent 面向的日程工具叫 `automations`。它的动作覆盖查看调度器状态、列举与读取 job、新增、修改、删除、立即运行、查看运行历史、计算下次检查时间和主动唤醒；新增与修改最终都经 Gateway 的 cron RPC 进入 CronService。工具默认对外声明 at、every 和 cron 三种时间调度，事件型的 watcher、stream 与 script 触发另由 cron.triggers.enabled 开关。at 任务运行一次后不再排程，循环任务保留下一次运行时间；current 目标在创建时就绑定当时的 session key，此后当前会话切换不会改变任务归属（`src/agents/tools/cron-tool.ts`、`src/cron/session-target.ts`）。

持久定义和运行状态由同一 SQLite state database 的多个 owner-native 表共同表达：

| 对象 | 主要内容 | 作用 |
| --- | --- | --- |
| `cron_jobs` | job owner、schedule、session target、payload、delivery 及最近运行字段 | 定义和最近状态的权威行 |
| `cron_run_receipts` | receipt、job、config revision、owner pid/start time、running/terminal status | 一次运行的 durable fence 和执行事实 |
| `task_runs` | cron 运行的状态、错误、终态摘要与运行详情 | 由 cron history owner 读写的日程历史；媒体和 exec 不据此建立通用任务行 |
| `cron_job_runtime_authorities` / `cron_job_scratch` | 工具运行权威与脚本/trigger scratch | 与 job 配置分离的运行时状态 |

cron history 仍借用 task_runs 表名，但写入明确限定 runtime=cron，历史记录不授权执行或 receipt 接管，见 [recordCronRunInDatabase](<../../openclaw/src/cron/store/run-history.kernel.ts#L180-L233>)。表结构和 active receipt 的唯一 job 约束见 `src/state/openclaw-state-schema.sql`。receipt store 将生命周期分为 queued reservation、active running、settling 和 terminal；非终态 receipt 必须由当前 owner 持有，或能被其他 Gateway 进程判断为 stale 后恢复，见 `src/cron/store/run-receipt-store.ts`。

调度器不会只依赖内存 timer 判断一次运行是否已经发生。到期候选先从持久 `nextRunAtMs` 读取，之后在 SQLite 写入 receipt 和 queued marker；激活时再次比较 marker、配置 revision 和 job 当前状态。并发 mutation、删除、禁用或重排会使旧 reservation 被 fence 或 terminalize，避免旧 snapshot 在新 job 上写回结果（`src/cron/active-jobs.ts`、`src/cron/execution-context-admission.ts`、`src/cron/service/ops-mutations.ts`）。

### 时间、事件和外部触发

cron 支持以下运行触发边界：

| 触发类型 | 判定依据 | 运行边界 |
| --- | --- | --- |
| `at` | 一次性时间任务 | 保持到成功终态或被明确处理 |
| `every` | anchor 与上次运行时间 | 每次运行后重新计算下一周期 |
| `cron` | 时区表达式 | 支持确定性 stagger，避免多个任务在同一时刻集中启动 |
| `on-exit` | Gateway `ProcessSupervisor` 托管的命令退出 | 命令由 Gateway 在自身外层托管，退出结果送入普通 cron run pipeline |
| `stream` | Gateway watcher 托管的 argv 输出 | 按 line/match 和 batch 边界交给 cron 执行，source identity 在禁用、删除、替换时轮换 |

`on-exit` watcher 在 spawn 尚未完成时就占用 job slot，取消或替换会使迟到的 child 被杀掉；spawn/wait 失败按递增退避重新 arm，未知 wait 结果不会直接触发 job。观察命令的 24 小时上限、重试间隔和 ownership token 见 `src/gateway/cron-exit-watchers.ts`。时间 timer、stream watcher 和 exit watcher 的 reconciler 都会在 job mutation 或 Gateway 生命周期变化后重读持久 job；其内部 watcher 状态不替代 cron receipt。

### Heartbeat monitor 与 wake bus

heartbeat 的周期由系统自有的 cron job 承载，每个 job 用 declaration key `heartbeat:<agentId>` 标识它属于哪个 Agent。配置解析给出的默认周期是 30 分钟；monitor 按 Agent 配置、显式 heartbeat owner 或环境里的 ambient owner 生成，其 sessionTarget 为 main，wakeMode 为 next-heartbeat。Gateway 收敛时会创建、更新或删除这些系统 job，普通客户端的 payload 无法直接创建或编辑它们（`src/cron/heartbeat-monitor.ts`、`src/infra/heartbeat-config.ts`、`src/cron/types.ts`）。

monitor job 执行时不直接完成模型回合，而是把 scheduled wake 送入 heartbeat wake bus。hook、cron main job、后台 task、exec completion 和手动请求也可以进入同一个 bus。wake bus 以 agent/session target 分组，每个 target 同时最多一个活跃 heartbeat turn；不同 target 可并行，跨 target 的 wake fan-out 上限为 4。相同 target 的 task、scheduled、event wake 会合并，保留优先级、顺序和待处理 task；busy、preempted 和请求在途的可重试跳过会在 wake 层保留或重新排程（`src/infra/heartbeat-wake.ts`）。

Heartbeat runner 在真正调用 `runOnce` 前检查：全局 heartbeat 开关、目标是否已配置、quiet hours、主 lane 请求、其他 cron/cron-nested/hook-dispatch 活跃工作、同 Agent 的 reply/embedded run、目标 session lane 和 pending final delivery。普通 interval tick 在忙碌时返回 retryable skip；manual/immediate wake 的优先级更高。heartbeat 运行入口与事件发布现集中在 auto-reply 与 state owner 侧模块，调度状态的具体载体（进程内 cooldown 或持久 record）本次未逐行复核（`src/auto-reply/heartbeat.ts`、`src/infra/gateway-state-owner-heartbeat.ts`、`src/infra/heartbeat-events.ts`）。

### 外部 hooks/webhooks

Gateway hook HTTP handler 的职责是认证和 admission，不是直接执行模型。它要求 POST、Bearer 或 `X-OpenClaw-Token`，限制 body 大小，解析 `wake` 或 `agent` payload，并检查 Agent allowlist、session key 允许前缀、持久 session 的必要条件和 delivery 字段。配置 mapping 可以将一个外部 payload fan-out 为多个 wake/agent action；重复的 agent dispatch 使用 token、路径、dispatch scope 和 idempotency key 组成的进程内 replay cache，fan-out 没有显式 idempotency key 时从 action scope 派生稳定身份（`src/gateway/server/hooks-request-handler.ts`）。

wake 类型的 hook 只把文本写进目标 session 的 system event 队列，是否立刻打扰 Agent 取决于 mode：now 会额外请求一次 heartbeat immediate wake，next-heartbeat 则等下一次 heartbeat 再处理。agent 类型的 hook 改为创建一个当前时刻生效的一次性 cron job：persistent 模式把 sessionTarget 设成 `session:<sessionKey>` 并回到该会话，默认的 isolated 模式使用独立 detached run；job 的 payload 类型是 agentTurn，创建时把 model、thinking、timeout、外部内容来源和 delivery 一并冻结在 job 中（`src/gateway/server/hooks.ts`）。

真正的 hook agent dispatch 使用同一 session key 的进程内串行队列，避免多个 hook 同时对同一 session 争夺 lifecycle claim；不同 session 可并行。默认 admission 起始等待上限为 15 秒，fan-out action 可声明 `admissionMode=background`，让 producer redelivery 与 replay cache 而不是 HTTP start deadline 承担慢 admission 的重试。执行从 lazy-loaded isolated cron runner 进入 `CommandLane.HookDispatch`，并在 runner 启动或 lane 等待结束时向 HTTP 调用方确认 admission（`src/gateway/server/hooks.ts`）。

hook run 完成后，如果要求 delivery 但 run 没有自行交付，dispatcher 将摘要写入目标 session 的 system event，并按 `wakeMode` 请求 heartbeat；失败同样写入错误 event。外部 plugin 的 `dispatchHookAgentTurn` 只接受 `hook:` session key、`externalContentSource=email` 和 isolated 模式，然后复用上述 hook cron pipeline，idempotency key 仍只保留在进程内（`src/gateway/server/hooks.ts`）。因此 hook HTTP 层本身不提供跨重启的 replay ledger；一旦已创建 run，后续事实由 cron/session/task 运行记录负责。

### 后台 CLI exec

exec 的后台化动作发生在当前工具调用内。yield timer 与进程结束竞争：未结束、未中止且未 finalizing 时，把 ProcessSession 标为 backgrounded，停止本次工具的流式更新并返回 process session 身份；更早结束则返回前台结果。当前链路没有创建 runtime=cli 的通用 task row。进程与输出保留由 ProcessSupervisor、process activity 和 registry 协作。依据见 [exec yield](<../../openclaw/src/agents/bash-tools.exec-run.ts#L665-L716>)、[进程 registry](<../../openclaw/src/agents/bash-process-registry.ts>)。

进程结束后 sandbox finalization 先跑完，退出结果再由 `onSettledBeforeNotify` 映射成 succeeded、failed、timed_out 或 cancelled 四种终态，一并写入 task ledger。如果后台 session 还没有被 terminal poll 观察，且 notifyOnExit 处于开启状态，exec 会把紧凑输出写入 system event 并请求一次目标 heartbeat；成功但输出为空默认不通知，手动取消且无输出同样不通知。subagent session 不走这条 heartbeat fallback，它的结果由 process poll 和 subagent announce flow 交付（`src/agents/bash-tools.exec-runtime.ts`、`src/agents/bash-tools.exec-task-tracking.ts`）。

取消入口检查后台状态、退出/finalizing 标记及 process activity 是否已结算。带 durable 句柄的进程调用该句柄的取消操作；普通进程调用 supervisor 的 manual-cancel，再记录已请求取消。真正停止以进程自身的终止原因和清理完成为准，取消已请求记录的是请求状态。依据见 [process control](<../../openclaw/src/agents/bash-process-control.ts#L24-L85>)。registry 本身在内存，durable 句柄后端的重启接管没有在本条链完整下钻，因此不从内存 registry 推导全部执行模式的恢复能力。

### Detached subagent 与 requester continuation

`sessions_spawn` 的主链是：解析 requester/target Agent、depth、模型、sandbox、thread 和 completion policy；创建并持久化 child session；准备 context engine、附件和 prompt；向 native Gateway `agent` dispatch；Gateway 接受后登记 child run；完成时由 registry 捕获结果并交付 requester。spawn pipeline 区分 initialize、dispatch、register 和 cleanup 阶段；Gateway 已接受但 registry 注册失败时会尝试终止 accepted child，避免出现无人持有的运行（`src/agents/subagents/spawn/subagent-spawn.ts`、`src/agents/subagents/spawn/subagent-spawn.ts`）。

每个 detached subagent 创建时都带上一组身份与策略字段：运行标识、子 session key、requester session、任务描述、模型、workspace、超时、spawn 模式、完成期望和交付状态。这些事实的权威副本落在 `subagent_runs` 表中；在 `src/tasks/` 目录与 `tasks.cancel` RPC 的检查范围内都没有找到通用 task ledger，任务展示改由 session async-task 状态与子 Agent 运行记录承担。schema 同时保存 `endedAt`、outcome、pause/kill、announce retry、frozen result、pending final delivery 以及 requester settle wake 字段（`src/state/openclaw-state-schema.sql`）。

子 Agent 结束后，registry 根据 outcome 生成 completion payload。若 requester 正在运行，结果可以先进入 steering queue：queue item 按完成时间稳定排序，单项结果和合并 prompt 都有字符上限；注入 requester 前标为 `in_progress`，注入成功变为 `delivered`，失败或 stale lease 则释放回 pending/suspended。该队列的作用是把子 Agent 结果作为 runtime data 回注下一次 requester turn，而不是伪装成用户指令（`src/agents/sessions/steering-message-identity.ts`、`src/auto-reply/reply/steering-delivery-preparation.ts`、`src/gateway/server-methods/chat-send-steering-commit.ts`）。

如果 requester 使用 `sessions_yield` 等待子任务，registry 会持久化 requester settle wake state。最后一个直接或后代子 Agent 进入 terminal settle 后，系统冻结同一批次，确认所需 completion 已交付且没有未结算 descendant，然后构造“所有子 Agent 已 settle”的内部 wake，使用稳定 idempotency key 重入 requester session。该 wake 最多执行有限次，区分普通失败和 transport ambiguous replay；`requester-settle-wake` 还会避免 cron requester 获得不适合的二次唤醒（`src/agents/subagents/announce/subagent-announce.requester-settle-wake.ts`）。

子 Agent 的 direct completion 交付优先复用 requester origin 或 requester session；无法直接投递时进入 session delivery queue。对需要生成媒体或必须跨 restart 保持的 session handoff，先持久化 `agentTurn` queue entry，再由 session delivery runtime 重新执行或 dead-letter；已发送但终态结算不明时保留 durable ownership，避免 live path 与 recovery 同时发布终态（`src/agents/subagents/announce/subagent-announce-delivery.ts`、`src/infra/session-delivery-queue-storage.ts`）。

## 执行、结果交付与状态更新

### Cron 的执行域、Agent、模型与工具

cron run 激活后先创建 `runtime="cron"` 的 task ledger record，记录 job、Agent、run id、开始时间和进度；随后由 `executeJobCoreWithTimeout` 统一包住 payload 执行、主 webhook、超时 watchdog、取消和 receipt settlement。每次 run 都有 active job marker；隔离 Agent 还绑定 session lifecycle claim、run context、plugin registry generation 和 session work admission，最终在 session persistence、delivery construction 和 receipt finalization 之后释放内存引用（`src/cron/service/run-admission.ts`、`src/cron/service/task-runs.ts`、`src/cron/isolated-agent/run.ts`）。

`isolated` Agent turn 的准备阶段解析有效 Agent、Agent directory/workspace、session key、当前或 detached run session、skills snapshot、delivery plan、模型和 thinking selection。payload 可以指定 model、fallbacks、thinking、timeout、light context 和 `toolsAllow`；执行时将已解析的 provider/model、工具策略、plugin registry 和 scheduled tool policy 传给 embedded Agent runner。cron 运行携带的 runtime authority 与创建时的工具 allowlist 绑定，执行运行时若候选 runtime 不匹配会拒绝，不通过普通 job 字段重新猜测权限（`src/cron/isolated-agent/run-prepare.ts`、`src/cron/isolated-agent/run-executor.ts`）。

main 目标的 payload 最终只能落成一段 system event 文本。这段文本被写入目标 session 的 event 队列，随后按 wakeMode 决定是立刻跑一轮 heartbeat 还是等下一次；wakeMode=now 若碰上同一 cron marker 之外的竞争工作，会在有限的等待窗口内重试，等到超时就重新请求一次 wake，event 本身仍留在队列里。isolated 目标按 payload 类型分派：command 不启动模型，直接走 runCommandWithTimeout；agentTurn 进入 isolated runner；script 交给 script runtime 执行，成功后可以产生通知、唤醒、下次检查和脚本状态（`src/cron/service/timer-execution.ts`）。

### Cron 结果和状态

执行结果与交付结果分开记录，两者的取值集合不同：

| 维度 | 字段 | 取值 |
| --- | --- | --- |
| 执行结果 | `CronRunStatus` | `ok`、`error`、`skipped` |
| 交付结果 | delivery | `delivered`、`not-delivered`、`unknown`、`not-requested` |

最终 job state 保存最近运行时间、状态、错误、持续时间、连续错误/跳过次数、下一次运行、delivery status/error 和 failure notification delivery；run history/task ledger 另存本次运行的 session、model、provider、usage、diagnostics 和摘要（`src/cron/types.ts`）。

隔离 Agent 的 finalize 顺序是：读取模型/usage/diagnostics，更新 session runtime model、context token 和 CLI binding，持久化 session entry；解析 payload 是否有可交付文本或结构化结果；按 delivery plan 发送；最后由 cron service 在 receipt-owned transaction 中把结果应用到 authoritative job row、写入 cron history、发出 finished event，并计算下一次运行。一次性 run 的 detached session 可在交付后清理，persistent session 则保留 session 生命周期（`src/cron/isolated-agent/run-finalize.ts`、`src/cron/isolated-agent/run.ts`）。

cron 的结果交付分 none、announce 和 webhook 三种。announce 先解析 channel、target、account、thread 和 session route，再交给 durable message sender 真正发送；交付目标是 current session 时，平台侧发送成功之后还要等最终 transcript commit 落定，run 才会结束。primary webhook 在执行结果 settled 之后发出 finished-run event，webhook 自身的发送同样受这次 run 的 abort 与 receipt current 检查约束（`src/cron/delivery.ts`、`src/cron/types.ts`、`src/cron/service/timer-job-runner.ts`）。

不同 payload 各有自己的预算：command 默认超时 10 分钟；script 默认 300 秒、上限 900 秒，默认 tool budget 为 50、上限 200。script 和 trigger 是否可用统一由 cron.triggers.enabled 控制。trigger 是无模型的 headless evaluator：结果里 fire=false 时它只更新 trigger state，fire=true 才会执行 payload，而它自身失败或超时同样归入 run failure。依据见 `src/cron/command-runner.ts`、`src/cron/script-payload.ts:3-31` 和 `src/cron/service/timer-execution.ts`。

### Heartbeat 回合与结果

heartbeat runner 先通过 wake stage 解析 Agent、heartbeat prompt、scheduled tasks、session 和目标 delivery；然后检查忙碌与生命周期条件，创建普通或 `isolatedSession` heartbeat session。孤立 heartbeat 每次使用新的 session ID 和空 transcript，但仍从 base session 解析 last route，因此减少重复发送完整历史的成本（`src/auto-reply/heartbeat.ts`、`src/infra/gateway-state-owner-heartbeat.ts`）。

模型结果经过 heartbeat outcome classifier：纯 `HEARTBEAT_OK`、短 acknowledgment 或静默结果不打扰用户；可见文本、媒体或 heartbeat response tool 的 notify=true 才进入 channel delivery。成功的结构化 heartbeat response 会写入每个 agent session 一行的 `heartbeat_outcomes`，保留 outcome、summary、priority、next check、task names、wake source/reason、run session 和 claim 信息；这份结果写入内部状态，用户可见消息经 channel delivery 另行投递（`src/infra/heartbeat-events.ts`、`src/state/openclaw-agent-schema.sql`；outcome 表的列组成未逐列复核）。

heartbeat 的 channel 发送复用同一个 durable 发送内核 `sendDurableMessageBatchCore`，失败通知可以走 channel，也可以走 indicator。可见消息发送成功后，runner 更新 lastHeartbeatText 与 lastHeartbeatSentAt，并清理自己持有的 pending final delivery。遇到没有路由、channel 尚未就绪、内容重复或 alerts 关闭这类不发送的情况，runner 仍返回 ran 或带类型的 skipped，并写一条 heartbeat event 记录原因（`src/auto-reply/heartbeat.ts`、`src/infra/heartbeat-events.ts`）。

### 统一 durable channel delivery

channel 发送的 write-ahead 边界位于 prepared payload 之后：先按 delivery intent 和 channel 能力准备 payload，再将 `delivery_queue_entries` 写入 SQLite，之后才调用平台 adapter；成功后删除 pending row，或按 completion retention 保留 completed tombstone。发送过程具有 producer lease、platform-send lease、retry count、last error、recovery state 和 `unknown_after_send` 等字段，平台调用已开始但结果不明时不会盲目重新发送（`src/infra/outbound/deliver-queue.ts`、`src/infra/delivery-queue-sqlite.ts`）。

`sendDurableMessageBatchCore` 将 payload 结果分为 sent、suppressed、partial_failed 和 failed，并保留 `sentBeforeError` 事实；这使 cron、heartbeat、task/subagent completion 能区分“没有发送”“部分发送”与“可能已经到达 recipient”。channel 层的 runtime barrel 只暴露 durable sender 和 recipient ambiguity helper，真正的 transport 由 outbound queue/runtime 处理（`src/channels/message/send.ts`、`src/channels/message/runtime.ts`）。

## 并发、取消、失败与恢复

### Cron 并发与取消

cron service 的默认并发上限是 8，timer 不会在容量耗尽时无限保留一个异步 tick，而是将候选 job 的 durable reservation 保留到 capacity release 或 bounded safety recheck；容量释放会立即触发重新检查。Gateway 还把 `cron-nested` 与 `hook-dispatch` 放入同一 aggregate group，hooks 开启时预留一个 hook slot，保证外部 hook 不被 cron inner work 饥饿，同时不超过 cron 总预算（`src/config/cron-limits.ts`、`src/cron/execution-context-admission.ts`、`src/gateway/server-lanes.ts`）。

job disable、remove、schedule edit 和 trigger edit 都是带 ownership 语义的持久 mutation。禁用会请求 exact active marker 取消；删除会把 active marker 标记为 removed 并取消真实 controller；配置 revision 或 trigger mutation 会阻止旧 run 把结果覆盖到新定义。取消不是只改数据库：isolated Agent 的 abort signal、cron lane task、ProcessSupervisor child 和 session lifecycle claim 都会在各自 owner 边界收到取消或 replacement（`src/cron/active-jobs.ts`、`src/cron/service/active-run-cancellation.ts`、`src/cron/service/ops-mutations.ts`）。

超时路径会先给运行创建 abort controller，再通过 watchdog 监听 detached Agent 的 setup/runner phase；如果模型或工具忽略 abort，底层 Promise 仍保留在 settlement tracking 中，避免 Gateway 认为资源已经空闲而让旧 core 继续写状态。执行结束后才释放 task/receipt/active marker，session work admission 和 browser/MCP 生命周期也在 final persistence/delivery 后释放（`src/cron/service/timer-job-runner.ts`、`src/cron/service/active-run-cancellation.ts`）。

### Cron 失败、退避与告警

执行失败后，循环 cron 使用连续错误次数和固定 backoff schedule 计算下一次重试，默认退避为 30 秒、60 秒、5 分钟、15 分钟、1 小时，之后保持末项。一次失败同时更新 `lastError`、diagnostics、duration、delivery 状态和 task/run history；delivery failure 与 Agent execution failure 分开记录，必要时可走 alternate failure route（`src/cron/service/jobs-scheduling.ts`、`src/cron/types.ts`、`src/cron/service/failure-alerts.ts`）。

显式或继承的 failure alert 默认在连续 2 次失败后告警，默认 cooldown 为 1 小时；可选择 announce 或 webhook、channel/account/recipient，并可决定是否计入 skipped。time-based recurring job 连续 10 次执行失败会自动禁用，写入 `autoDisabled` 和 operator-visible notification；system-owned heartbeat monitor 等 job 不由该规则自动禁用，因为它们由 Gateway convergence 重新投影（`src/cron/service/failure-alerts.ts`、`src/cron/service/auto-disable.ts`）。

### 重启、重复触发与 catch-up

Gateway 启动时读取所有 queued/running marker，结合 receipt owner PID 和 process start time 判断当前 owner 是否仍然存活。确认 owner stale 后，恢复流程按 receipt identity、job marker、config revision 和 task ledger 重新读取：如果 task ledger 已有完整终态，恢复该终态；否则把 run 记为 `interrupted`，恢复 schedule state、failure notification 和下一次运行；job 已删除时仍可保留并结束 receipt。receipt 是 CAS/fence，单靠相同 job ID 或毫秒时间戳不足以让旧 owner 继续写入（`src/cron/service/run-recovery.ts`、`src/cron/store/run-receipt-store.ts`）。

启动 catch-up 会对 missed jobs 排序，默认最多立即运行 5 个，并以 5 秒间隔 stagger；超出即时容量的任务持久化 deferred state。Agent turn missed jobs 默认延后 2 分钟，避免 Gateway 启动时同时承担模型和工具 bootstrap；执行中止或 finalization 失败时释放未激活 reservation，并保留可重算的下一次运行时间。该策略倾向于一次有边界的补跑，而不是重放所有错过的时刻（`src/cron/service/timer-execution-timeout.ts`、`src/cron/service/timer-catchup.ts`）。

重复的 Gateway tick、手动 force run、配置 A→B→A 和禁用→启用由不同层的 identity 共同约束：queued/running marker 防止同一 job 在本进程重入，SQLite active receipt 防止跨进程重入，config revision 防止旧定义写回，stream source identity 防止旧 watcher 的 batch 被新 watcher 接收。timer 自身最多将下一次 wake 延后到 60 秒，并对立即过去的时间点施加 refire gap，防止 event loop 被 `setTimeout(0)` 热循环占满（`src/cron/active-jobs.ts`、`src/cron/service/jobs-scheduling.ts`）。

### Heartbeat 忙碌、失败与恢复

heartbeat 的 busy 不是丢弃任务：requests-in-flight、cron-in-progress 和 preempted 等 skip reason 会由 wake layer 作为可重试 wake 保留；没有 pending event 的 exec completion 则是已确认的非重试情况。runner 的 cooldown、minimum spacing 和 flood guard 限制事件唤醒频率；scheduled tick 携带 authoritative cadence，不会被普通事件 cooldown 改写。runOnce 抛错返回 `failed`，heartbeat event 记录失败原因；channel 失败也会保留失败通知路径或在下一次恢复中再次处理（`src/infra/heartbeat-wake.ts`、`src/infra/heartbeat-runner-scheduler.ts`、`src/infra/heartbeat-runner-run.ts`）。

heartbeat monitor job 本身借用 cron 的 receipt、startup recovery 和调度状态，但 heartbeat wake bus 的 pending wake、cooldown 和 active target 是进程内状态。代码快照可确认 monitor job 会在 Gateway convergence 时重新生成，且事件触发可在未启用 recurring interval 时针对已配置 Agent 一次性运行；未运行验证跨 Gateway restart 时进程内 pending wake 是否在所有入口都能得到等价重建。

### Hook、exec、subagent 和交付恢复

- hook HTTP replay cache、plugin hook replay map 和 same-session dispatch tails 都是进程内协调状态。它们防止同一 Gateway 生命周期中重复 admission，但不是 durable queue；已创建 hook cron run 的恢复交给 cron receipt/task/session 记录。
- 后台 exec 的 `ProcessSession` 和 ProcessSupervisor child 是进程内 owner。task ledger 的终态写入有失败日志，但没有看到从 SQLite task row 重新取得原始 child 的通用重启恢复路径；进程重启后的结果取决于具体 host/Gateway lifecycle 和外部进程 owner，不能从 task row 单独推断可恢复。
- subagent registry 在启动时从 SQLite 恢复 rows，先 reconcile orphaned run、补齐 requester owner、更新 archive deadline，再启动 listener/sweeper；未结束 run 重新等待或走 restart recovery，已结束但未交付 run 走 announce/delivery resume。恢复失败会按 1 秒起步、最多 30 秒的 retry timer 重试（`src/agents/subagents/registry/subagent-registry-restore.ts`）。
- subagent completion announce 对临时 transport error 使用有限重试，看到已有 platform send evidence 时不重放；required completion 的 retry/deadline 与普通 announce expiry 分开。跨 session 的 durable handoff 使用 SQLite session delivery queue，失败会增加 retry metadata，最终可移到 failed/dead-letter，而不是静默删除（`src/agents/subagents/announce/subagent-announce-delivery-retry.ts`、`src/infra/session-delivery-queue-storage.ts`）。
- channel outbound queue 在 provider 调用前持有 SQLite row 和 producer/platform lease。发送成功后删除或保留 tombstone，部分失败和 unknown-after-send 交给 recovery；因此断线、重启或重复 producer redelivery 可以查到同一 delivery identity，而不是只依赖日志。

## 相邻类目交接与已确认边界

- **会话与消息管理。** cron main、heartbeat、hook wake 和 background task 都通过 session key、system event 或 heartbeat 重新进入会话；isolated cron、hook agent 和 subagent 则创建或使用 detached session。session entry、transcript、lifecycle claim、pending final delivery 和 session cleanup 属于会话管理边界，本笔记只记录它们如何承接主动运行身份。
- **Agent 工具。** 触发与控制入口集中在 automations、exec、process、sessions_spawn 和 sessions_yield 这五个工具上；它们的 schema、sandbox、approval、MCP/tool allowlist 和模型循环留在 Agent 工具类目。本笔记只记录自动化运行在执行前如何冻结 Agent/model/tools authority，以及后台控制是否能到达真实执行体。
- **外部执行体。** on-exit/stream watcher、ProcessSupervisor、node host 和外部 ACP 是 OpenClaw 与执行体之间的交接点。外部 ACP 自身的调度、内部恢复和身份绑定不在本次范围；OpenClaw 侧只记录 spawn/dispatch、run identity、结果回收和交付。
- **Follow-up/steering queue。** follow-up runner 负责当前进程中一个已排队回合的 admission、执行、accounting 和 delivery；执行完成后即使 presentation/accounting/delivery 失败，也不会重新 replay 已产生副作用的模型/工具执行。它是会话内续作和主动运行之间的交接，不是独立的持久日程（`src/auto-reply/reply/followup-runner.ts`）。
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

- `src/gateway/server-cron-lazy.ts`、`src/gateway/server-cron.ts`：Gateway cron lazy loading、enabled 判定和 CronService 构造。
- `src/cron/service/ops-lifecycle.ts`、`src/cron/active-jobs.ts`：启动恢复、活动 job 与 timer 重排。
- `src/cron/execution-context.ts`、`src/cron/execution-context-admission.ts`：receipt reservation、执行上下文准入与并发槽。
- `src/cron/store/run-receipt-store.ts`、`src/state/openclaw-state-schema.sql`：cron receipt、job/task/subagent 的 SQLite 权威结构。
- `src/cron/service/timer-execution.ts`、`src/cron/isolated-agent/run.ts`：payload 分派、main/detached session、Agent run lifecycle 和 cleanup。
- `src/cron/isolated-agent/run-prepare.ts`、`src/cron/isolated-agent/run-executor.ts`、`src/cron/isolated-agent/run-finalize.ts`：Agent/model/tools 准备、执行与终态持久化。
- `src/cron/delivery.ts`、`src/cron/isolated-agent/delivery-dispatch.ts`、`src/cron/service/timer-job-runner.ts`：announce、webhook、durable delivery 和 timeout/cancel。
- `src/cron/service/jobs-scheduling.ts`、`src/cron/service/timer-catchup.ts`、`src/cron/service/run-recovery.ts`、`src/cron/service/startup-run-repair.ts`：backoff、missed-job catch-up、stale owner recovery 和 interrupted run repair。
- `src/auto-reply/heartbeat.ts`、`src/auto-reply/heartbeat-filter.ts`、`src/infra/heartbeat-events.ts`：heartbeat 回合、过滤与事件发布。
- `src/infra/gateway-state-owner-heartbeat.ts`、`src/commands/doctor-heartbeat-*.ts`：state owner 侧 heartbeat 运行、监控修复与迁移（含 heartbeat 任务与旧状态迁移）。
- `src/infra/heartbeat-compat.ts`、`src/commands/doctor-heartbeat-session.ts`：heartbeat 兼容层、会话目标解析与 outcome 迁移。
- `src/gateway/server/hooks-request-handler.ts`、`src/gateway/server/hooks.ts`：HTTP hook 认证、mapping/fan-out、幂等、wake 和 hook-agent cron dispatch。
- `src/agents/bash-tools.exec-run.ts`、`src/agents/bash-tools.exec-runtime.ts`、`src/agents/session-async-task-status.ts`：后台 exec 运行、终态与 async-task 投影。
- `src/agents/bash-process-control.ts`、`src/agents/bash-process-registry.ts`：后台进程取消、session registry 和有限 retention。
- `src/agents/subagents/spawn/subagent-spawn.ts`：subagent session、spawn pipeline、Gateway dispatch 和失败清理。
- `src/agents/subagents/registry/subagent-registry.ts`、`src/agents/subagents/registry/subagent-registry-restore.ts`：subagent lifecycle registry、delivery resume 和启动恢复。
- `src/agents/sessions/steering-message-identity.ts`、`src/auto-reply/reply/steering-delivery-preparation.ts`、`src/gateway/server-methods/chat-send-steering-commit.ts`、`src/agents/subagents/announce/subagent-announce.requester-settle-wake.ts`：结果 steering 身份、投递准备与提交、settle wake。
- `src/agents/subagents/announce/subagent-announce-delivery.ts`、`src/agents/subagents/announce/subagent-announce-delivery-retry.ts`：subagent completion direct/queued delivery 和 retry policy。
- `src/infra/system-events.ts`、`src/auto-reply/reply/followup-runner.ts`：非持久 system event、follow-up queue 和会话续作边界。
- `src/infra/outbound/deliver-queue.ts`、`src/infra/delivery-queue-sqlite.ts`、`src/channels/message/send.ts`：统一 durable channel queue、lease、partial/ambiguous send 和消息结果分类。
