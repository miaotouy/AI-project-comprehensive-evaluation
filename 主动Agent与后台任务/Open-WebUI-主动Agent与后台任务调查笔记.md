# Open WebUI 主动 Agent 与后台任务调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`d3e8bf3405e848cfba377814d0aa7ba7290e414d`（分支：`main`）
>
> 调查方式：只读核对已有独特功能笔记，并追踪 `main.py` 生命周期、Automations 的路由/模型/调度器，以及 Calendar 事件与提醒路径；未启动服务，未修改被调查仓库
>
> 调查范围：Automations 的 rrule 无头运行与 Calendar 事件提醒；覆盖状态权威、执行、结果交付、启停/删除、失败与重启去重。普通日历 CRUD、模型工具参数和通用聊天执行细节仅作交接说明
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 在当前快照有一条 `主链确认` 的隔离日程运行，以及一条 `主链确认` 的条件通知链。

| 运行形态 | 触发与运行对象 | 状态权威 | 执行与交付 | 证据状态 |
| --- | --- | --- | --- | --- |
| 隔离日程运行：Automations | 用户保存的 prompt、model、rrule 自动化；到期后认领 | `automation` 为定义与下次运行事实源，`automation_run` 为每次终态 | 创建真实 chat 或 channel 消息，再无头进入完整聊天管线；Socket、运行记录和 chat/channel 是结果归属 | `主链确认` |
| 条件唤醒：Calendar alerts | 事件进入提醒窗口，且尚未记录 alerted | `calendar_event` 与 `meta.alerted_at` | 向用户 Socket 房间发 alert，并发布通知事件 | `主链确认` |

两条链由应用启动的同一个 async scheduler 驱动，但运行对象不同。Automations 是有独立 run 历史和聊天产物的 Agent 工作单元；Calendar 本身不是 Agent job，只有事件提醒构成符合本类目的后台条件唤醒。日历中的 “Scheduled Tasks” 只是把 Automation 的未来计划和历史运行投影到时间轴，不建立第二套调度状态。

## 系统边界与主链

应用 lifespan 在启动时创建 `scheduler_worker_loop` task，关闭时直接 cancel 该 task。调度器在每实例运行，分别受 `automations.enable` 与 `calendar.enable` 配置门控；其调度轮询默认十秒并加入随机抖动。聊天模型、工具、Filters、RAG 和消息保存仍使用既有聊天管线，本笔记只记录后台调用如何取得身份及如何把结果交接回该管线（`backend/open_webui/main.py:392-394,465-477`; `backend/open_webui/utils/automations.py:210-267`）。

### Automations：从规则到独立聊天

完整链路是：用户提交自动化定义 -> 路由校验权限、rrule、频率及数量 -> `automation` 行保存下次时间 -> scheduler 原子认领到期行并立即重算下次时间 -> `execute_automation` 复验 owner 权限、生成短期 owner token -> 创建真实 chat 或 channel 消息 -> 调用完整 `CHAT_COMPLETION_HANDLER` -> 写入 `automation_run`，以 Socket 和事件通知结果。该链最终的可观察产物是可打开的 chat 或频道消息，而不是仅有 worker 日志（`routers/automations.py:208-238`; `models/automations.py:289-332`; `utils/automations.py:489-684,772-780`）。

### Calendar alerts：从事件窗口到通知

完整链路是：用户或模型创建/更新事件并保存 `meta.alert_minutes` -> scheduler 搜索当前提醒窗口内且未取消的事件 -> 检查 `meta.alerted_at` 去重 -> 向用户房间发 `calendar:alert` -> 将该字段写回事件 -> 发布通用 Calendar notification event。事件本身和提醒去重标记都在数据库，因此没有另建的 alert queue 或 run 历史表（`models/calendar.py:53-95,660-753`; `utils/automations.py:692-769`）。

## 触发、调度与运行对象

### Automations 的定义、认领与并发

`automation` 行保存 owner、可选 folder、名称、JSON data 中的 prompt/model/rrule、活跃状态以及 `last_run_at` 和 `next_run_at`；`automation_run` 则保存 run id、automation id、可选 chat id、`success` 或 `error` 与错误文本。创建和更新会计算 next run；非管理员还受 feature 权限、最大数量和最小间隔约束。有限次数的 rrule 必须有 DTSTART 锚点，避免不完整规则无限运行（`models/automations.py:20-55,132-156,225-278`; `routers/automations.py:45-95,208-230`）。

调度器每轮最多认领十个到期自动化。`claim_due` 在数据库事务中筛选 `is_active` 且 `next_run_at <= now` 的记录；PostgreSQL 使用 `FOR UPDATE SKIP LOCKED`，随后立即写入 `last_run_at` 和新的 `next_run_at`。这使多个实例不会同时执行已认领的同一到期行；轮询抖动进一步降低同时争抢概率（`models/automations.py:289-332`; `utils/automations.py:210-255`）。

### Calendar alert 的状态对象

Calendar event 保存开始时间、可选 rrule、取消标记和可写 meta。`get_upcoming_events` 过滤已取消事件，以默认或每事件的 `alert_minutes` 计算窗口；负数表示不提醒。调度器对 `alerted_at` 已存在的事件跳过，成功发送后写回当前时间，因此去重状态随数据库跨重启、跨实例存留（`models/calendar.py:53-77,697-753`; `utils/automations.py:692-749`）。

## 执行、结果交付与状态更新

### Automations 的执行域

执行前，worker 重新读取 owner，并拒绝已删除、降权或失去 `features.automations` 权限的 owner；拒绝也写 error run 并发布失败事件。正常情况下，prompt 经模板渲染，worker 为该 owner 创建短期 bearer token，用来在无头请求中保留 owner 身份。默认目标会新建真实 chat：先保存 user 和空 assistant 占位消息及 `meta.automation_id`，再以 automation session id 调用完整聊天处理器。频道目标同样先插入用户与模型消息，再进入 channel 聊天处理器（`utils/automations.py:489-540,547-650`; `utils/automations.py:386-486`）。

成功时结果属于新 chat、频道模型消息和 `automation_run.chat_id` 三处可识别对象；worker 对 owner Socket room 发送 `automation:result`，同时发布完成事件。异常被捕获为最多 4000 字符的 error run、失败事件和失败通知，而不是让 scheduler loop 退出（`utils/automations.py:652-684,772-780`）。运行列表路由可按 automation 查询这些持久记录，Calendar 路由又把历史 run 投影为 Scheduled Tasks 时间线中的虚拟事件（`routers/automations.py:388-400`; `routers/calendar.py:195-269`）。

### Calendar alert 的交付

提醒的直接交付是用户 Socket room 的 `events` payload，类型为 `calendar:alert`；payload 含 event id、标题、开始时间、距开始分钟数和地点。随后以 scheduler 为 source 发布 Calendar notification event，是否还有配置的目标通知由通用通知系统承接。即使后续 notification publish 失败，代码仅记录 debug，不会撤销已经写回的 `alerted_at`（`utils/automations.py:721-769`）。

## 并发、取消、失败与恢复

### Automations

用户可 toggle，使 `is_active` 翻转且停用时将 `next_run_at` 清空；update 可重写规则和下次时间，delete 会先删除历史 `automation_run` 再删除定义。手动 `/run` 只用 `asyncio.create_task` 发起相同执行函数，不另建 run 的 queued/running 状态，因此本次静态调查未找到对“已经在执行的一次运行”的单独取消 API 或持久 running 状态（`models/automations.py:264-287`; `routers/automations.py:306-380`）。

认领时立即推进下次时间，重启后不会因同一个到期点反复认领；但应用关闭只 cancel scheduler task，当前已经由 `asyncio.create_task(execute_automation(...))` 启动的执行体的精确取消/等待语义未在本轮逐步验证。若执行抛出异常，run 会落 error；本次未找到自动重试或补跑 backlog 的实现证据，不能据此断言不存在于未读的基础设施层。

### Calendar alerts

取消事件或将 `alert_minutes` 设为负数可阻止未来提醒；删除事件也使其不再被查询。数据库 `alerted_at` 防止同一存储事件在重启或多实例下重复发送。当前实现按原 event 记录处理提醒；重复事件的实例展开与“每个重复实例各提醒一次”的详细契约不在本轮完整验证范围内。Socket 或通用通知系统的投递失败不会被保存为可重试 alert run，因此这条链的可靠性边界止于数据库去重与 best-effort 发布。

## 相邻类目交接与已确认边界

- Automations 创建真实聊天并进入标准聊天处理器；会话、消息和 streaming 的内部持久化属于 [会话与消息管理笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md) 与 [对话请求与上下文笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)。
- 无头自动化的模型工具、Filter、RAG 与终端配置沿用聊天管线；工具权限和调用机制属于 [Agent 工具笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)。
- Calendar CRUD、共享访问、RSVP 和模型管理日历的工具面是日程对象能力；本笔记仅纳入由 scheduler 驱动、向用户交付的提醒链。
- Persistent Memory 的每回合后台复盘在独特功能笔记已确认，但该对象是用户记忆写入，不在此重复计为 automation run。

## 未验证事项

- 未启动 Open WebUI，未验证实际 rrule 触发、数据库方言下的并发认领、Socket 推送、聊天流式结果或 channel 目标的端到端交付。
- 未验证进程关闭时已启动 automation task 的取消和最终 run 记录，也未验证多实例部署中 scheduler 与数据库事务的实际时序。
- 未对完整聊天管线中的工具审批、外部模型调用和终端服务进行运行验证；这里只确认无头请求携带 owner token 并调用该管线。
- Calendar 重复事件的提醒实例语义、通用通知系统的外部目标重试，以及 alert 发送失败后的恢复行为未验证。

## 关键源码索引

- `backend/open_webui/main.py:392-394,465-477`：scheduler 的应用生命周期创建与关闭。
- `backend/open_webui/models/automations.py:20-55,132-156,264-332,340-422`：Automation/AutomationRun 数据模型、启停、到期认领和运行历史。
- `backend/open_webui/routers/automations.py:45-95,208-380,388-400`：权限/频率治理、创建更新、手动运行、删除和 run 查询。
- `backend/open_webui/utils/automations.py:210-267,386-684,692-780`：调度循环、无头 chat/channel 执行、结果记录与 Calendar alert。
- `backend/open_webui/models/calendar.py:53-95,660-753`、`backend/open_webui/routers/calendar.py:87-109,143-269`：事件与提醒去重状态、Scheduled Tasks 时间线投影。
