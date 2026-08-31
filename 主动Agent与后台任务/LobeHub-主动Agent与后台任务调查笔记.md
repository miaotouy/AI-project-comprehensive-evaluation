# LobeHub 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`7c559cbd4d92a54289bce3a8aab96e057d0ce8c5`（分支：`canary`）
>
> 调查方式：只读复查 Schedule 的 PostgreSQL schema、QStash/本地调度入口、任务运行器与生命周期回调；并对照既有独特功能笔记，未修改 LobeHub 源码
>
> 调查范围：Schedule 与 heartbeat 自动化任务的触发、状态、执行、交付、取消/失败/恢复语义；不展开 Goals、记忆工作流、外部 Agent 托管及工具细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的 Schedule 属于“隔离日程运行”：持久化任务在到期后创建一个新的 task topic，由无头 Agent 执行，再回写任务、运行记录与 Brief。`tasks` 及其 topic/brief 关联对象是权威状态，QStash 或本地定时器仅负责投递；因此暂停、取消或改自动化模式后，即使旧投递抵达也会被执行端再次核验并跳过。

同一任务模型还承载 heartbeat。它不是 cron 扫描，而是按间隔续接下一轮；两者共享运行器、并发冲突处理、人工等待门和生命周期回调。静态主链已确认，生产 QStash 的投递、实际中断正在执行的模型运行以及进程重启期间的时间精度尚未运行验证。

## 系统边界与主链

本次对象是 LobeHub 后端的任务自动化，而非普通会话中的 Agent 工具调用。任务定义、指派、自动化配置和状态保存在 PostgreSQL 的 `tasks` 行；每次执行关联一个 `taskTopics` 运行记录，完成后可生成 `briefs` 供 Home Inbox 消费。`tasks` 记录了 `automationMode`、cron 与时区、heartbeat 时间、当前 topic、错误及任务生命周期状态，见 `packages/database/src/schemas/task.ts:26-104`。

Schedule 主链如下：

```text
用户配置 schedule task
  -> PostgreSQL tasks（schedulePattern、timezone、status）
  -> QStash 中央 schedule-dispatch 扫描到期任务
  -> 每项投递 schedule-execute；本地模式直接调用 tick
  -> tick 重新读取 tasks 并做状态、人工等待、配额和并发检查
  -> TaskRunnerService 创建 task topic，headless execAgent 执行
  -> on-topic-complete 更新 topic / task / handoff，生成 Brief
  -> scheduled 状态等待下一轮，或 completed / paused
```

## 触发、调度与运行对象

**触发与到期判定。** 生产中央派发器每次调用读取可派发的 schedule 任务，以 cron、时区和上次心跳时间判断是否到期，再向每项任务发布独立 QStash 消息；队列功能未启用时，直接在本进程执行 tick。该设计将“扫到期”和“跑任务”拆开，单项发布失败不会阻塞其他到期项，见 `apps/server/src/router-hono/workflows/task/handlers/scheduleDispatch.ts:28-38,44-65,101-151`。调度器自身注册频率与实际 QStash 配置属于外部接线，本次未确认。

**运行状态权威。** `tasks.status` 的常用值包括 backlog、running、paused、completed、failed、canceled；自动化模式为 schedule 或 heartbeat。Schedule tick 不信任已投递消息，而是按任务 ID 和创建者从数据库重读：任务不存在、模式已改、没有表达式、处于终态或已暂停均跳过。它也在启动前检查未解决的紧急 Brief，避免 Agent 等待人工输入时继续运行，见 `apps/server/src/services/taskRunner/scheduleTick.ts:31-79`。

**并发与配额。** `TaskRunnerService` 先查已有 task topic；同一任务已有 running topic 时抛出冲突，tick 将冲突作为 `in-flight` 跳过。Schedule 的最大执行次数通过已记录的 schedule 触发 topic 计数；达到上限即写 completed，手动运行不消耗此配额，见 `apps/server/src/services/taskRunner/index.ts:118-143` 与 `scheduleTick.ts:81-130`。

**Heartbeat 分型。** heartbeat 也是独立 task topic 运行，但由延迟 tick 续接而非 cron 扫描。其 tick token 与任务 context 中当前 token 不同便视为陈旧消息；同样重读模式、终态、间隔和人工等待条件。生产走 QStash 延迟 HTTP 消息，本地以 `setTimeout` 保存待执行句柄；后者仅在进程内有效，见 `apps/server/src/services/taskRunner/heartbeatTick.ts:29-104`、`apps/server/src/services/taskScheduler/impls/local.ts:13-62`。

## 执行、结果交付与状态更新

执行器将任务转为无头 Agent 运行：解析或回退执行 Agent，组合任务指令与上下文，固定任务的模型快照，在 headless 审批模式调用 `AiAgentService.execAgent`，并把 topic 与 operation ID 写入 task topic 记录。任务 skill 被挂载；Brief 工具只在遗留 agent 模式挂载，默认由生命周期服务程序化合成 Brief，见 `apps/server/src/services/taskRunner/index.ts:70-279`。具体模型、工具和审批规则属于 Agent 工具类目。

完成 hook 可通过 QStash webhook 回到 `TaskLifecycleService.onTopicComplete`。成功时，topic 标为 completed，最后回复写入 handoff 内容，最佳努力生成交接摘要与用户 Brief；自动化任务回到 `scheduled` 等待下一轮，若达到 schedule 配额则写 completed。真正由 schedule tick 触发的成功还尝试发送完成通知，但该通知失败不会改变任务生命周期，见 `apps/server/src/services/taskLifecycle/index.ts:164-250,267-338`。因此交付至少落在 task topic 的运行结果和 Brief；通知是附加通道。

## 并发、取消、失败与恢复

**暂停、取消和修改。** 任务状态是对后续自动化的控制面。已发出的 Schedule 消息在 tick 时重新核验数据库，paused 与终态直接跳过，模式变更也跳过；heartbeat 额外以 token 防止旧延迟消息复活。这确认了“停止后不再启动新一轮”的语义。任务 UI/API 到实际 Agent operation 的中断链本次没有逐段复查，不能据此断言取消会终止已经 running 的执行体。

**失败与重试。** 启动阶段失败时，自动化任务恢复为 `scheduled` 并保存错误，非自动化任务暂停。完成回调收到错误时，运行 topic 标为 failed 且创建 urgent error Brief；schedule 的连续失败会累加到任务 context，未达到 failure fuse 时保持 scheduled 以待下个正常 cron 时点，达到阈值才暂停。该机制不是立即、密集的队列重试，见 `apps/server/src/services/taskRunner/index.ts:280-303` 与 `apps/server/src/services/taskLifecycle/index.ts:390-476`。

**重启与重复投递。** 权威任务、topic、Brief 和错误信息持久化在 PostgreSQL，QStash 投递抵达后仍会重验状态，降低重复或延迟消息造成重复运行的风险。Schedule 的到期过滤使用上次执行时间，运行器又拒绝同任务并发 topic。LobeHub 本地 heartbeat 调度器的待执行 `setTimeout` 不持久化，进程重启会丢失该内存句柄；生产端如何补发、QStash 的精确重试和 webhook 重投效果未运行验证。

## 相邻类目交接与已确认边界

- 与会话管理的交点是每轮生成或续接 task topic，而不是在原用户消息回合内同步完成。
- 与 Agent 工具的交点是 headless `execAgent`、Task skill 和可选 Brief 工具；本笔记不重复工具权限与工具调用执行细节。
- Brief 是后台结果对人的主要异步交接面。未解决的紧急 Brief 反向阻止下一自动化轮次，形成显式人工介入边界。
- Goals、verify、项目依赖和 Personal Memory 可能复用任务或异步基础设施，但其对象语义超出本笔记范围。

## 未验证事项

- 生产 QStash 的中央调度注册、消息重试、重复投递与服务重启后的实际时间语义。
- 用户取消 running task 时到真实 Agent operation、模型调用或外部工具的中断是否完整传播。
- Schedule 完成通知的具体业务实现与各客户端可见性；代码明确其失败不影响状态，但未运行投递。
- heartbeat 在本地进程重启后是否由其他启动恢复逻辑补建；本次只确认本地 scheduler 自身为内存 `setTimeout`。

## 关键源码索引

- 任务事实模型：`packages/database/src/schemas/task.ts:26-129`。
- Schedule 派发与执行适配器：`apps/server/src/router-hono/workflows/task/handlers/scheduleDispatch.ts`、`scheduleExecute.ts`。
- 状态重验与并发/配额：`apps/server/src/services/taskRunner/scheduleTick.ts`、`index.ts:70-303`。
- 完成、交付、失败与状态流转：`apps/server/src/services/taskLifecycle/index.ts:140-476`。
- heartbeat 与本地调度：`apps/server/src/services/taskRunner/heartbeatTick.ts`、`apps/server/src/services/taskScheduler/impls/local.ts`。
