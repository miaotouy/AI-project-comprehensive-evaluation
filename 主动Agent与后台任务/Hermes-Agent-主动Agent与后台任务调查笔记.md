# Hermes Agent 主动 Agent 与后台任务调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 调查方式：只读核对仓库根 `AGENTS.md`、已有独特功能笔记，以及 `hermes_cli/heartbeat.py`、CLI/Gateway 驱动、`cron/jobs.py` 与 `cron/scheduler.py` 的可执行链；未启动服务，未修改被调查仓库
>
> 调查范围：会话内 heartbeat 续作与 cron 隔离日程运行；覆盖触发、状态权威、执行、交付、取消和恢复。后台复习、curator、委派与终端后台进程仅在相邻类目交接中说明，不重复调查
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前快照中，Hermes 有两种不能混同的主动运行形态，均达到 `主链确认`（静态证据）。

| 运行形态 | 触发与运行对象 | 状态权威 | 执行与交付 | 证据状态 |
| --- | --- | --- | --- | --- |
| 会话内续作：heartbeat | 用户设置的单个会话心跳，到期且空闲时产生一条普通用户消息 | SessionDB 的 `state_meta`，键为 `heartbeat:<session_id>` | 重入原会话；结果按普通聊天回合回到当前 CLI 或网关来源 | `主链确认` |
| 隔离日程运行：cron | 用户或模型保存的 job，到期后由 ticker 认领并创建 execution | 每 profile 的 `cron/jobs.json` 与执行账本；输出另存文件 | 独立 cron session 或纯脚本运行；输出保存并按目标投递 | `主链确认` |

heartbeat 的设计目标是持续推进**同一个**会话，不创建独立任务；它要求 CLI 或 Gateway 进程持续运行。cron 则以独立会话、文件化 job 存储和跨进程锁实现可跨重启的日程运行，故适合需要耐久性的自动化。两者均不是当前用户回合内的工具调用。

## 系统边界与主链

Hermes 的 Python 核心同时服务 CLI、消息 Gateway、TUI 和桌面端。此处只记录实际承接主动运行身份及终态的 heartbeat 与 cron。Agent 的工具权限、模型循环和消息适配细节已由 [Agent 工具笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md) 覆盖；后台记忆/技能复习属于 [独特功能笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md) 的学习闭环，不作为本类目的独立用户可管理任务重写。

### Heartbeat：会话内续作

完整链路是：`/heartbeat` 配置提示词与间隔 -> `HeartbeatState` 写入 SessionDB -> CLI 守护线程或 Gateway 轮询器发现到期且会话空闲 -> 先记录本次 fire，再把渲染后的 heartbeat prompt 当普通用户消息入队 -> 原会话进入正常 Agent 回合 -> 回复由既有 CLI/平台消息通道交付。状态对象与驱动分离：状态可随 `/resume` 找回，但正在运行的轮询器仍是进程内对象（`hermes_cli/heartbeat.py:1-26,100-131,161-192`）。

### Cron：隔离日程运行

完整链路是：`hermes cron`、`/cron` 或 `cronjob` 保存 job -> gateway ticker 每 60 秒在 tick 锁内读取到期 job -> 预推进循环 job 的下次时间、创建执行记录并领取 fire claim -> 线程池运行 `run_one_job` -> 生成独立 cron session 或执行纯脚本 -> 输出落入 profile 的 cron output 目录并投递到 job 配置的目标 -> job 与 execution 写入终态。存储路径随 profile 的 `HERMES_HOME` 切换，避免凭据、技能和 cron job 跨 profile 混用（`cron/jobs.py:68-99,141-191`; `cron/scheduler.py:7556-7782`）。

## 触发、调度与运行对象

### Heartbeat 的触发与状态权威

一个 `HeartbeatState` 包含 prompt、间隔、`active`/`paused`/`cleared` 状态、创建与上次触发时间和触发次数。`set`、`pause`、`resume`、`clear` 都立即写回 SessionDB；恢复时重置锚点，避免暂停期间积累的到期 tick 立即触发（`hermes_cli/heartbeat.py:100-137,241-280`）。最小间隔为 60 秒。

CLI 驱动每五秒检查当前会话。仅当没有 Agent 正在运行、没有语音录制或处理，且输入队列为空时才调用 `due_prompt`；真实用户输入因此优先。Gateway 使用单个异步轮询器，并以来源和 session id 注册 watch；会话仍在运行时跳过本轮。忙碌期间不会排队多个 tick：fire 时将 `last_fired_at` 更新为当前时间，所以空闲后至多补一次（`cli.py:12778-12818`; `gateway/run.py:21914-21959`; `hermes_cli/heartbeat.py:284-298`）。

### Cron 的触发与状态权威

cron job 的持久定义在 `jobs.json`，包含 schedule、启停和终态字段；其 job id 也是输出目录和认领协议的标识。日程可为一次、固定间隔或 cron 表达式。单次任务允许 120 秒宽限；循环任务在停机后将积压压缩为一次 catch-up，而不连续补发全部错过的时刻（`cron/jobs.py:1-6,732-829,3314-3329`）。

`tick` 以 `.tick.lock` 防止多个进程同时扫描。到期的循环任务会先持久化推进 `next_run_at`，再进入线程池；每个实际运行进一步取得带 owner token 的 `fire_claim`。这样同一 job 的并发 fire 被拒绝，且 claim 的心跳能证明长期运行仍属当前执行者（`cron/scheduler.py:7556-7624,7717-7727,7756-7782`; `cron/jobs.py:3098-3192,3281-3311`）。

## 执行、结果交付与状态更新

### Heartbeat 的执行域与结果归属

heartbeat 不换系统提示、不替换工具集，只把预设文本包装为普通 user turn；因此沿用原会话的模型、权限和聊天记录。CLI 把 prompt 放入 `_pending_input`，Gateway 则构造 `MessageEvent` 并进入该来源的 FIFO 队列。结果没有单独的 heartbeat run 表，而是作为会话中的常规 assistant 消息交付；`fire_count` 和最近触发时间提供了可识别的续作状态，但不保存每次结果的专用摘要（`hermes_cli/heartbeat.py:1-18,284-298`; `cli.py:12802-12812`; `gateway/run.py:21935-21957`）。

### Cron 的执行域与结果归属

Agent 型 cron job 建立 id 为 `cron_<job_id>_<timestamp>` 的独立会话，默认跳过记忆；其上下文不伪装成原始网关用户会话，异步委派也被限制为在 job 内同步收束。纯脚本 job 可用 `no_agent` 绕过 LLM，标准输出就是最终交付内容（`cron/scheduler.py:5310-5465,5677-5739`）。cron 运行还会禁用交互型 messaging 和 clarify toolset；默认也禁用 cronjob，防止 job 自行扩张调度循环。具体工具审批与权限链属于 Agent 工具类目（`cron/scheduler.py:464-495`）。

`run_one_job` 的顺序是执行、保存 Markdown 输出、按 job origin 或目标投递、最后更新 job 和 execution。`[SILENT]` 只抑制投递，不抑制输出归档；失败则保留错误并走失败交付。job 终态保存 `last_run_at`、`last_status`、`last_error`、独立的 `last_delivery_error` 和失败连续次数；有限单次任务完成后保留 completed 记录一段时间，而不是立即抹去结果（`cron/scheduler.py:6919-6937,7137-7160`; `cron/jobs.py:2657-2801`）。

## 并发、取消、失败与恢复

### Heartbeat

用户可通过 heartbeat 命令暂停、恢复或 clear；clear 后持久状态标为 `cleared` 并从当前 manager 移除。每次触发在实际执行前持久化，重叠轮询不会对同一个到期点重复注入。会话压缩产生新 session 时，有迁移函数复制状态并清除旧记录。它不提供跨进程常驻调度：进程停止期间没有独立 worker 接管，恢复后的可执行性取决于会话被恢复且对应 CLI/Gateway poller 再次运行（`hermes_cli/heartbeat.py:258-321`）。

### Cron

暂停、恢复、编辑、删除和手动运行属于 cron 管理面；调度器同时检查 `enabled` 与 pause 标记，外部旧回调不能通过普通认领复活已暂停 job。全局 `hermes pause` 会停止新的 cron 派发，但不修改正在执行的 job（`cron/jobs.py:604-635,3123-3144`; `cron/scheduler.py:7626-7640`）。

运行期取消经组合 cancel event 传入 Agent 和脚本执行路径；Gateway 关闭可将运行记为 interrupted，失去 fire-claim 所有权的迟到结果会被丢弃，不覆写后来所有者的状态。每 job 的运行集合也阻止同一 job 在前一轮未结束时再次入池（`cron/scheduler.py:6919-6969,7097-7126,7796-7905`）。

恢复策略偏向避免重复副作用：循环 job 预推进下次运行，进程崩溃可能漏掉一次而非重放；有限单次 job 在副作用前计入 dispatch，获得 at-most-times 语义。死 owner 的 execution 会被周期性标为 unknown 并回收；过期的一次性 claim 可释放。超过宽限仍未触发的一次性 job 会留下诊断输出后退役，而非在重启后无限补跑（`cron/jobs.py:2883-2962,2997-3022,3025-3078`; `cron/scheduler.py:7642-7671`）。

## 相邻类目交接与已确认边界

- heartbeat 是会话内续作，cron 是隔离日程运行；前者不应按“持久 cron”比较，后者的结果也不会镜像为原 Gateway 会话中的普通消息。
- cron 的独立 session、消息落库和恢复浏览与 [会话与消息管理笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md) 交接；模型工具、脚本、审批和投递适配与 [Agent 工具笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md) 交接。
- 计数触发的后台记忆/技能复习具备后台线程和文件结果，但其核心对象是记忆与技能演化；本笔记不把它重复列作用户可管理的 cron job，详见独特功能笔记。
- 本次未把 curator、Kanban dispatcher、后台 delegation 或终端完成通知展开为本类别主链，尽管仓库中存在相关机制；它们需要独立核对各自任务身份、终态和恢复契约。

## 未验证事项

- 未实际运行 CLI、Gateway 或定时器，五秒/六十秒轮询、平台消息投递和进程关闭时的中断时序均为静态代码结论。
- 未验证 heartbeat 恢复后是否在所有表面自动重新注册 watch；代码可确认持久状态与 CLI/Gateway 注册路径，未覆盖跨表面切换操作。
- 未验证 cron 的外部 delivery adapter、模型/工具审批、长时间运行时 fire claim 心跳以及多进程文件锁在真实部署中的行为。
- 未验证 cron execution 账本的完整查询界面和保留/清理时间；已确认 job 状态与输出文件的保存链。

## 关键源码索引

- `hermes_cli/heartbeat.py:1-26,100-137,161-321`：heartbeat 的状态模型、SessionDB 持久化、到期判定、暂停/清除和会话迁移。
- `cli.py:12754-12818`、`gateway/run.py:21914-21974`：CLI 与 Gateway 的空闲判定、轮询和普通消息重入。
- `cron/jobs.py:68-99,732-829,2552-2801,2883-3192,3314-3329`：profile 存储、日程解析、终态、认领及到期/catch-up 处理。
- `cron/scheduler.py:464-495,5310-5465,6910-7126,7556-7905`：cron 工具边界、Agent/脚本执行、输出与交付、取消和线程池派发。
