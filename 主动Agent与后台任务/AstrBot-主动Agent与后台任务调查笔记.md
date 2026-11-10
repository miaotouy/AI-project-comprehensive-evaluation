# AstrBot 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：只读复查 cron 数据模型、APScheduler 管理器、主动 Agent 唤醒与后台工具执行路径；并对照既有独特功能笔记，未修改 AstrBot 源码
>
> 调查范围：持久化主动 cron、后台工具/后台 handoff 的触发、状态、交付、取消/失败/重启语义；补充群聊概率主动回复的边界，不展开沙箱和平台适配细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的主动能力包含两种不同的运行形态，不能合并为同一种“后台任务”。第一种是持久化的 active-agent cron：任务定义与最近运行状态在 SQLite 等数据库实现中保存，启动时恢复到进程内 APScheduler，到期后用合成事件重新进入目标会话的主 Agent，并将历史和可选主动消息交付回会话。它满足本类目的完整静态主链。

第二种是模型发起的后台工具或后台 handoff：调用立刻返回一个 UUID，实际协程由 `asyncio.create_task` 在当前进程中执行，并由活跃事件注册表按会话持有；完成或捕获异常后经同一唤醒通道把结果交回主 Agent。两类唤醒现已共用一条通道：管理器或执行器只构造 `AgentWakeupEvent` 放入事件队列，由普通流水线完成配置选择、取锁、上下文构建、执行与发送，因此模型、Persona、安全模式、压缩、最大步骤和工具超时不再与普通会话分叉（`astrbot/core/astr_agent_wakeup.py:10-51`；`astrbot/core/platform/agent_wakeup_event.py:25-129`）。后台任务由此获得可被会话停止取消的共享停止信号，但仍没有持久化运行记录；cron 行在唤醒排队后即记为 dispatched，不再等待 Agent 完成。

## 系统边界与主链

cron 的事实对象是 `cron_jobs` 表中的 `CronJob`，见 `astrbot/core/db/po.py:186-216`。同一行同时保存工作定义与最近一次派发状态：

- 定义字段：job ID、任务类型、cron 或单次时间、时区、payload，以及 enabled、persistent、run_once。
- 最近状态字段：状态、上次/下次运行时间和错误。

持久化工作定义及其可观察的最近状态因此不依赖 APScheduler 内存。

active-agent cron 主链如下：

```text
主 Agent 使用 future_task 创建任务（或其他 API / basic 注册来源）
  -> cron_jobs 持久化定义、目标会话和发送者信息
  -> CronJobManager 启动时同步 persistent + enabled 的任务到 APScheduler
  -> APScheduler 到期调用 _run_job，先写 running
  -> _run_active_agent_job 解析目标 UMO、调用者角色与 cron 上下文提示
  -> wake_main_agent 构造 AgentWakeupEvent 放入事件队列，job 记为 dispatched
  -> 普通流水线：选会话配置 -> session lock -> 历史与工具 -> 主 Agent -> Respond 发送
  -> 单次任务删除；循环任务留待下个 cron 时点
```

## 触发、调度与运行对象

**创建与权限范围。** 启用 `provider_settings.proactive_capability.add_cron_tools` 后，主 Agent 获得 `future_task`。它可创建循环 cron 或一次性 `run_at`，创建 payload 时保存当前统一消息会话、发送者、指令 note 和来源，见 `astrbot/core/tools/cron_tools.py:105-199`。编辑只允许任务创建者；删除允许创建者或 AstrBot 管理员；列表在私聊中只返回本人任务并提示同会话还有他人任务，在群聊中则返回该群全部任务并标注创建者（`cron_tools.py:200-398`）。这套控制的作用域限于会话与发送者，鉴权依据是创建者与管理员身份。

**调度与权威状态。** 管理器启动时只把数据库中已启用且标记为持久的任务装回调度器，为每个五段 cron 或日期触发器挂上统一的运行入口，并把下次运行时间异步写回数据库。每次触发都先重读任务行：已禁用的任务直接跳过，其余任务先标记为运行中、更新上次运行时间并清空旧错误；收尾阶段按任务类型写入终态，同时记录错误信息和下次运行时间：

- `dispatched`：唤醒事件已入队，等待普通流水线执行
- `completed`：任务本次执行完成
- `failed`：执行失败，错误写入任务行
- `cancelled`：运行被取消

主动 Agent 任务只负责把唤醒事件放进队列，`dispatched` 记录的就是入队动作本身。数据库是工作定义和最近派发状态的权威来源；正在运行的执行体没有单独的持久化记录，Agent 回合的结果落在会话历史与 trace 里，任务行只保留任务层面的状态（`astrbot/core/cron/manager.py:128-142,310-415,426-473`）。

**一次性与重启。** `run_once` 使用日期 trigger，派发后即删除 job；只有运行被取消时才保留，见 `astrbot/core/cron/manager.py:391-409`。循环任务继续保留。核心生命周期在启动时创建 CronJobManager 并异步调用其 `start`，停止时关闭 scheduler；这确认了持久任务会在应用启动时被重装，但未确认宕机期间错过的 cron 是否补跑，见 `astrbot/core/core_lifecycle.py:254-271,325-328,410-411`。

**条件唤醒补充。** 群聊上下文启用时，非 @/唤醒命令、白名单允许的群消息可按 `possibility_reply` 的随机概率让常规对话生成回复。该路径没有独立任务或结果记录，故不作为后台任务主链，见 `astrbot/builtin_stars/astrbot/group_chat_context.py:112-130` 与 `main.py:206-239`。

## 执行、结果交付与状态更新

cron 到期后，管理器从任务载荷中取回目标会话标识和指令 note，再根据载荷记录的来源、发送者是否管理员确定调用者角色；随后把任务 ID、名称、描述、note、开始时间和目标会话组装成一段 `<system_reminder>` 形式的用户提示，交给唤醒入口入队（`astrbot/core/cron/manager.py:426-473`；`astrbot/core/astr_main_agent_resources.py:101-115`）。被唤醒的 Agent 由普通流水线构建：按会话标识选择配置档案、加载当前对话历史并取得会话锁，唤醒来源的请求跳过 provider 唤醒前缀检查；回复经 Respond 阶段发回原会话，流式输出合并成一条完整消息再投递（`astrbot/core/astr_agent_wakeup.py:10-51`；`astrbot/core/platform/agent_wakeup_event.py:87-129`）。会话历史的持久化和发送成功后的记账仍由流水线承担。

job 行只保存任务层面的派发状态、时间与最后错误；Agent 回合的成败不会回写到 `cron_jobs`。因此排查某次主动运行的结果要结合会话历史与 trace，而不是 job 行状态。

因此 cron 是“会话内续作”而非 LobeHub 式新任务 topic：它以合成事件重新进入同一会话的主 Agent，结果归属为该会话的主动消息与对话历史；`CronJob` 只保存任务层面的最近状态、时间和最后错误。它现在与后台任务共用同一唤醒通道，差异只在触发来源、角色解析和提示内容。模型、工具和平台发送实现分别属于 Agent 工具与消息渠道类目。平台是否支持主动消息仍受 `support_proactive_message` 元数据和发送工具的实际平台实现约束。

## 进程内后台工具任务

模型在回合内调用标记为后台任务的普通 FunctionTool，或调用带后台标记的 handoff 时，工具执行器先生成一个 UUID 并立即返回“已提交”提示，真正的工具调用或子 Agent 交给 `asyncio.create_task` 在当前事件循环执行。任务连同所属事件登记到活跃事件注册表，按目标会话持有到执行结束，后台工具超时为 3600 秒。执行结束后触发一次唤醒：正常结果收集为文本，异常转为错误文本，以后台任务为来源经唤醒入口重新进入主 Agent，提示中携带任务 ID、工具名、参数、结果与 note，并附带共享停止信号（`astrbot/core/astr_agent_tool_exec.py:165-193,399-546`）。被唤醒的 Agent 走普通流水线并取得原会话历史，普通文本回复同样经过 Respond 阶段投递；提示只把 `send_message_to_user` 列为发送图片、文件等产物的工具，实际发送由唤醒事件转交目标平台，发送成功才记账（`astrbot/core/astr_main_agent_resources.py:117-128`；`astrbot/core/platform/agent_wakeup_event.py:93-129`）。

运行身份仍是返回文本加内存中的 coroutine 与注册表条目。检查范围覆盖 `astrbot/` 下 background 与 cancel 相关实现：没有按 task ID 查询状态、持久化、队列认领或重启恢复的路径；取消能力来自会话级停止信号（下节）。进程退出或事件循环取消时，不能从已读代码推断会有可靠的用户终态交付。

## 并发、取消、失败与恢复

**cron 任务。** 删除 job 会先从调度器移除，取消并等待该 job 正在运行的 `_run_job` task，再删除数据库行；删除期间新开始的运行会直接返回。更新 job 先用新定义构建 trigger 校验，把无效编辑挡在持久化和已有调度之外，再移除旧调度并注册新定义；禁用 job 在运行前检查中直接返回，见 `astrbot/core/cron/manager.py:202-246,360-415`。这里的取消只覆盖到“唤醒事件入队”这一步：一旦 active-agent 回合已作为独立事件进入流水线，删除 job 不会中断它。

APScheduler 注册任务时覆盖同名旧条目，错过触发的宽限时间设为 300 秒；任务实例上限、错过触发合并和分布式锁都没有配置，因此单进程下同一任务的重叠派发、多副本部署的重复运行，以及超过宽限期后的行为都需要运行验证。执行异常写入任务的 `last_error`，循环任务保留到下个触发时点，单次任务在派发后即被删除，一次性失败没有内置重试，也没有可重跑的错误任务。手动触发入口 `run_job_now` 忽略任务的启用状态，同样不删除一次性任务（`astrbot/core/cron/manager.py:357-358`）。

**后台工具与 handoff。** 会话停止时，`stop_all` 与 `request_agent_stop_all` 会置位该会话的停止信号并取消已登记的后台 task；注册时若所属事件已停止则立即取消；`wake_main_agent` 在入队前检查停止信号，因此被停止的会话不会产生迟到的主动回复。平台删除时按平台前缀停止该平台的全部会话与后台任务（`astrbot/core/utils/active_event_registry.py:57-189`）。除此之外没有独立的后台任务取消 API、状态查询或持久化记录。

## 相邻类目交接与已确认边界

- cron 与后台完成都以 `AgentWakeupEvent` 重入既有会话；会话历史由会话管理组件持久化，平台发送由消息渠道处理。唤醒来源类型还声明了 plugin 一种，本次未找到除 cron 与 background_task 以外的调用点。
- `future_task` 是 Agent 工具面，工具注册、模型循环与 `send_message_to_user` 的权限/平台细节应回链 Agent 工具及 LLM 渠道笔记。
- 概率主动回复是群聊条件唤醒，没有事实任务对象、终态或独立交付记录，未计入本类主链。
- 沙箱、MCP、普通同步工具调用不是本笔记对象；它们只有被标记为后台工具时才通过上述进程内分支交接。

## 未验证事项

- SQLite 之外数据库实现的 cron 持久化与时间字段表现，以及应用重启后错过触发的补跑/跳过语义。
- APScheduler 对同一 job 的并发、misfire 和派发后删除在真实部署中的表现；多进程/多副本去重未确认。
- cron 或后台结果在各 IM 平台上的实际主动投递，特别是平台能力元数据与 webhook 等外部条件。
- 应用停止或重启时，已入队唤醒事件与已登记后台 task 的实际中断或丢失语义；本笔记只确认了会话级停止信号与删除 job 的取消路径。
- 后台 task UUID 是否只用于当前模型回合展示，以及任务完成后主 Agent/消息发送失败时用户的实际可见结果。
- 群聊任务列表共享与管理员删除在真实多用户群中的可观察行为。

## 关键源码索引

- cron 事实模型与数据库契约：`astrbot/core/db/po.py:186-216`、`astrbot/core/db/__init__.py:728-782`。
- cron 创建、会话归属和编辑/删除：`astrbot/core/tools/cron_tools.py:38-398`。
- 调度、状态、失败和单次删除：`astrbot/core/cron/manager.py:128-415`。
- 唤醒事件与入队：`astrbot/core/platform/agent_wakeup_event.py:25-129`、`astrbot/core/astr_agent_wakeup.py:10-51`。
- cron 派发与上下文提示：`astrbot/core/cron/manager.py:426-473`、`astrbot/core/astr_main_agent_resources.py:101-129`。
- 后台工具/handoff 与结果唤醒：`astrbot/core/astr_agent_tool_exec.py:165-193,399-546`；停止信号：`astrbot/core/utils/active_event_registry.py:57-189`。
- 条件主动回复：`astrbot/builtin_stars/astrbot/group_chat_context.py:112-130`。
