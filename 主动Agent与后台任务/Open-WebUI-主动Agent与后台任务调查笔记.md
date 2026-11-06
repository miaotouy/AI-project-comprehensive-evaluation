# Open WebUI 主动 Agent 与后台任务调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：只读对照旧新源码，追踪应用生命周期、自动化路由/模型/调度器、聊天完成交接与 Calendar 提醒事务；未启动服务
>
> 调查范围：Automations 的 rrule 无头运行与 Calendar 提醒，覆盖定义、认领、执行、交付、终态、启停及去重；普通日历 CRUD 与完整工具执行细节仅作交接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

| 运行形态 | 触发与运行对象 | 状态权威 | 执行与交付 | 证据状态 |
|---|---|---|---|---|
| 隔离日程运行：Automations | 用户保存的 prompt、模型与 rrule；到期认领或手动触发 | automation 保存定义与下次时间；automation_run 保存 success/error 终态 | 新建 chat 或频道消息，再进入聊天管线；运行记录与 Socket 提供返回入口 | 主链确认，静态证据 |
| 条件通知：Calendar alerts | 事件进入提醒窗口且该开始时间尚未提醒 | calendar_event 与 meta.alerted_at；notification 保存收件箱交付 | 同事务记录提醒标记与收件箱，提交后发通用事件与 Socket | 主链确认，静态证据 |

两条链共享 scheduler，但 Calendar 没有独立 Agent run；日历中的 Scheduled Tasks 也只是自动化计划与历史的时间轴投影。调度器还处理一次性聊天 timer，其独立运行语义留在工具调查范围，本篇未展开。

## 系统边界与主链

应用 lifespan 创建 scheduler task，关闭时 cancel；每实例运行同一循环。timer 默认每秒检查，Automations 与 Calendar 默认每十秒加 0–2 秒抖动检查，各有功能开关。调度器认领后以独立 asyncio task 执行自动化（[`main.py`](../../open-webui/backend/open_webui/main.py) 的 lifespan、[`utils/automations.py:54-125`](../../open-webui/backend/open_webui/utils/automations.py#L54-L125)）。

```text
自动化 UI/工具创建定义
  -> 权限、rrule、频率及数量校验
  -> automation 保存 next_run_at
  -> claim_due 认领并推进下次时间
  -> 复验 owner、签发短期 token
  -> 创建 chat 或频道消息 -> 完整聊天处理器
  -> automation_run、Socket 与通知事件

Calendar 提醒窗口
  -> 事务内重读事件并查去重标记
  -> 同事务写提醒标记与 notification
  -> commit -> 通知变化/通用事件 -> 即时 Socket alert
```

## 触发、认领与状态权威

### Automations

定义包含 owner、可选 folder、名称、JSON 中的 prompt/model/rrule、活跃状态及上次/下次时间；run 只有运行 id、自动化 id、可选 chat id、终态与错误文本，没有 queued/running 持久状态。创建、更新、启停、手动运行与历史查询入口位于 [`routers/automations.py`](../../open-webui/backend/open_webui/routers/automations.py)。

非管理员受功能权限、最大数量与最小间隔约束。有限次数规则要求 DTSTART，规则计算统一进入 recurrence 工具；到期认领批量读取 owner 时区重算下一次时间，求值超时则跳过该行。每轮最多十项，PostgreSQL 使用 `FOR UPDATE SKIP LOCKED`；其它方言走普通事务读写，跨实例单次执行保证需结合方言验证，不能仅从调度抖动推断（[`models/automations.py:297-348`](../../open-webui/backend/open_webui/models/automations.py#L297-L348)、[`utils/recurrence.py`](../../open-webui/backend/open_webui/utils/recurrence.py)）。

认领在执行前就推进 last/next 时间，因此运行失败后仍按下一次规则触发。本次在调度循环中未找到失败自动重试或逐个补跑停机期间所有到期点的逻辑。

### Calendar alerts

事件保存开始时间、重复规则、取消标记与提醒分钟数；负数关闭提醒。重复频率校验下限为 24 小时。查询提醒窗口后，处理器会锁定并重读数据库事件，校验事件仍存在、未取消、开始时间未变，且 `alerted_at` 尚未记录本次开始时间（[`models/calendar.py`](../../open-webui/backend/open_webui/models/calendar.py)、[`utils/automations.py:542-593`](../../open-webui/backend/open_webui/utils/automations.py#L542-L593)）。

去重标记保存的是事件开始时间，改期后允许再次提醒；它没有表达每个重复实例的独立 alert run。重复实例展开、特殊排除规则与每实例提醒的完整关系尚未逐项确认。

## 执行、权限与结果交付

### 自动化进入聊天管线

执行时重新读取 owner，要求角色仍为 user/admin 且保留自动化权限，再检查 Auths 账号活跃性；短期 token 带 automation 类型与账号 session stamp。模型目录为空时先加载。模型默认工具、过滤器、终端与允许的联网/图像能力由服务端解析；聊天目标还按“用户设置 → 界面默认 → 全局开关”继承记忆偏好。需要浏览器的代码解释器特性未被默认开启（[`utils/automations.py:163-196,349-495`](../../open-webui/backend/open_webui/utils/automations.py#L163-L495)）。

| 目标 | 执行与终态边界 |
|---|---|
| 持久 chat | 先创建用户消息和助手占位，再调用聊天处理器；主入口等待已注册的生成任务完成，执行器再读助手消息，要求无 error 且 done 才写 success。异常、未完成和取消写 error，并保留已创建 chat 的回链 |
| channel | 复验频道功能/权限，走频道消息创建入口保存两条消息，再调用聊天处理器；返回后即写 success。主入口的等待条件仅覆盖持久 chat，此分支缺少同样的消息 done/error 复验，success 表示派发成功的边界更宽 |

证据：[`utils/automations.py:247-346`](../../open-webui/backend/open_webui/utils/automations.py#L247-L346)、[`utils/automations.py:497-536`](../../open-webui/backend/open_webui/utils/automations.py#L497-L536)、[`main.py:1858-1866`](../../open-webui/backend/open_webui/main.py#L1858-L1866)。普通 chat 与频道终态差异属于静态调用路径事实；具体后台执行时序尚未运行验证。

成功时发布 automation:result 与完成事件，run 可由自动化历史查询并投影到日历时间轴；失败记录与失败通知由 run 模型插入路径承接。notification 收件箱保存可补看的通知，即时 Socket 则承接在线反馈（[`models/automations.py:354-427`](../../open-webui/backend/open_webui/models/automations.py#L354-L427)、[`routers/notifications.py`](../../open-webui/backend/open_webui/routers/notifications.py)）。

代码中另有 `_set_terminal_cwd` 辅助函数，但本次在本文件的自动化执行路径未找到调用点，故不把它记为已经接线的执行前切目录行为（[`utils/automations.py:199-244`](../../open-webui/backend/open_webui/utils/automations.py#L199-L244)）。

### Calendar 的事务性交付

处理器按“事件 id + 开始时间”构造稳定通知 id，把收件箱消费与 alerted_at 更新放在同一数据库事务。提交后依次发布收件箱变化、通用事件，最后才发送即时 calendar:alert；后续发布失败不会回滚已提交的收件箱与标记。因此数据库内交付与在线通知是不同可靠性边界（[`utils/automations.py:582-630`](../../open-webui/backend/open_webui/utils/automations.py#L582-L630)）。

## 并发、取消、失败与恢复

用户可停用定义、修改规则或删除自动化；手动 run 用独立 asyncio task 调相同执行器，没有另建 queued/running 行。停用只影响未来认领，当前已启动执行没有在自动化路由中找到单独取消入口。生成 task 可以通过聊天任务系统停止；持久 chat 的取消最终进入 error run，执行器随后重抛取消（[`routers/automations.py`](../../open-webui/backend/open_webui/routers/automations.py)、[`utils/automations.py:531-536`](../../open-webui/backend/open_webui/utils/automations.py#L531-L536)）。

应用关闭时取消 scheduler；已派发自动化任务的统一等待/清算机制，本次在 lifespan 和 scheduler 交接中未找到。认领后进程中断可能留下“下次时间已推进、当前 run 尚未写入”的间隔，精确重启行为需要运行观察。

Calendar 取消事件、关闭提醒或删除事件会阻止未来查询；去重标记与收件箱跨进程保存。提醒发送失败没有单独的可重试 alert run，PostgreSQL 行锁与 SQLite 等方言下的并发行为需分别验证。

## 相邻类目与未验证事项

- 自动化创建的聊天与消息属于[会话与消息管理](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)，生成/取消与审批恢复属于[对话请求与上下文](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)，工具域属于[Agent 工具](../Agent工具/Open-WebUI-Agent工具调查笔记.md)。
- Calendar CRUD、共享、RSVP 与模型管理日程属于日程对象能力；Persistent Memory 复盘属于记忆写入，不重复计为 automation run。
- 本篇为非穷尽静态复核，未运行模型、Socket、真实日程、外部终端、数据库并发与进程中断场景；真实触发时刻、消息时序、外部推送及重复事件实例提醒仍需在目标环境观察。

## 关键源码索引

- [scheduler 与执行器](../../open-webui/backend/open_webui/utils/automations.py)：调度、owner token、chat/channel 交接、提醒事务。
- [自动化模型](../../open-webui/backend/open_webui/models/automations.py)：定义、认领、运行记录与失败通知。
- [自动化路由](../../open-webui/backend/open_webui/routers/automations.py)：创建、规则预览、启停、手动执行与历史。
- [聊天主入口](../../open-webui/backend/open_webui/main.py#L1858-L1866)：自动化持久 chat 等待生成结束。
