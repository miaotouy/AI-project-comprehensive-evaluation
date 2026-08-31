# AstrBot 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`8ea8ce613a0bee4ddb48b21490afe23418277c75`（分支：`master`）
>
> 调查方式：只读复查 cron 数据模型、APScheduler 管理器、主动 Agent 唤醒与后台工具执行路径；并对照既有独特功能笔记，未修改 AstrBot 源码
>
> 调查范围：持久化主动 cron、后台工具/后台 handoff 的触发、状态、交付、取消/失败/重启语义；补充群聊概率主动回复的边界，不展开沙箱和平台适配细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的主动能力包含两种不同的运行形态，不能合并为同一种“后台任务”。第一种是持久化的 active-agent cron：任务定义与最近运行状态在 SQLite 等数据库实现中保存，启动时恢复到进程内 APScheduler，到期后用合成事件重新进入目标会话的主 Agent，并将历史和可选主动消息交付回会话。它满足本类目的完整静态主链。

第二种是模型发起的后台工具或后台 handoff：调用立刻返回一个 UUID，实际协程由 `asyncio.create_task` 在当前进程中执行，完成或捕获异常后再次唤醒主 Agent 发送结果。它有运行 ID 和交付链，但当前代码未见持久化运行记录、取消 API 或重启恢复，因此只能作为进程内后台工作单元记录。群聊概率主动回复是条件唤醒，不创建独立任务对象，作为主动触发边界补充而非主链。

## 系统边界与主链

cron 的事实对象是 `cron_jobs` 表中的 `CronJob`，含 job ID、任务类型、cron 或单次时间、时区、payload、enabled、persistent、run_once、状态、上次/下次时间和错误。持久化工作定义及其可观察的最近状态因此不依赖 APScheduler 内存，见 `astrbot/core/db/po.py:181-209`。

active-agent cron 主链如下：

```text
主 Agent 使用 future_task 创建任务（或其他 API / basic 注册来源）
  -> cron_jobs 持久化定义、目标会话和发送者信息
  -> CronJobManager 启动时同步 persistent + enabled 的任务到 APScheduler
  -> APScheduler 到期调用 _run_job，先写 running
  -> CronMessageEvent 以原会话为目标重建主 Agent 上下文
  -> Agent 执行并可用 send_message_to_user 主动投递
  -> 对话历史持久化；job 写 completed / failed、last_error、next_run
  -> 单次任务删除；循环任务留待下个 cron 时点
```

## 触发、调度与运行对象

**创建与权限范围。** 启用 `provider_settings.proactive_capability.add_cron_tools` 后，主 Agent 获得 `future_task`。它可创建循环 cron 或一次性 `run_at`，创建 payload 时保存当前统一消息会话、发送者、指令 note 和来源；编辑、删除、列出均要求 job 同时属于当前会话和发送者，见 `astrbot/core/tools/cron_tools.py:16-18,52-191,193-321`。这提供的是会话/发送者范围的控制，不等同于通用的任务权限系统。

**调度与权威状态。** `CronJobManager.start` 仅将 enabled 且 persistent 的数据库任务恢复至 APScheduler；调度器将五段 cron 或日期 trigger 注册为 `_run_job`，并把下次运行时间异步写回数据库。运行时先重读 job，禁用项不运行，随后写 `running`、`last_run_at` 和清空旧错误，finally 写 `completed` 或 `failed`、错误和下次时间，见 `astrbot/core/cron/manager.py:98-144,225-349`。数据库是工作定义和最近状态的权威，但“当前正在运行”的执行体没有单独持久化 run 对象。

**一次性与重启。** `run_once` 使用日期 trigger，执行 finally 后无论成功或失败都删除 job。循环任务继续保留。核心生命周期在启动时创建 CronJobManager 并异步调用其 `start`，停止时关闭 scheduler；这确认了持久任务会在应用启动时被重装，但未确认宕机期间错过的 cron 是否补跑，见 `astrbot/core/core_lifecycle.py:236-255,298-337,383-395`。

**条件唤醒补充。** 群聊上下文启用时，非 @/唤醒命令、白名单允许的群消息可按 `possibility_reply` 的随机概率让常规对话生成回复。该路径没有独立任务或结果记录，故不作为后台任务主链，见 `astrbot/builtin_stars/astrbot/group_chat_context.py:112-130` 与 `main.py:206-239`。

## 执行、结果交付与状态更新

cron 到期后，管理器从 payload 取回目标会话和 note，构造 `CronMessageEvent`。该事件保留原 `MessageSession`，其 `send` 通过原会话发送；管理器读取原会话的对话历史、加入 scheduled-task 系统提示并运行主 Agent。若存在目标投递会话，会将 `send_message_to_user` 加入工具集；最终无论是否有显式发送，都会把执行摘要与上下文持久化到对话历史，见 `astrbot/core/cron/events.py:14-64` 与 `astrbot/core/cron/manager.py:360-509`。

因此 cron 是“会话内续作”而非 LobeHub 式新任务 topic：它以合成事件重新进入同一会话的主 Agent，结果归属为该会话的主动消息与对话历史；`CronJob` 只保存任务层面的最近状态、时间和最后错误。模型、工具和平台发送实现分别属于 Agent 工具与消息渠道类目。平台是否支持主动消息仍受 `support_proactive_message` 元数据和发送工具的实际平台实现约束。

## 进程内后台工具任务

标记 `is_background_task` 的普通 FunctionTool，或带 `background_task` 的 handoff，会在模型回合内生成 UUID 后立即返回“已提交”。随后 `asyncio.create_task` 在当前事件循环执行工具或子 Agent；完成时收集文本，异常也转为结果文本，再创建 `CronMessageEvent` 唤醒主 Agent。被唤醒的 Agent 取得原会话历史，并被提示必须通过 `send_message_to_user` 直接交付，否则用户看不到结果；之后同样持久化历史摘要，见 `astrbot/core/astr_agent_tool_exec.py:143-184,381-618`。

此形态的运行身份只有返回文本和内存中的 coroutine。检查范围覆盖 `astrbot/` 下 background 与 cancel 相关实现，本次未找到按该 task ID 查询状态、取消、持久化、队列认领或重启恢复的路径；故工具运行时异常会被捕获并尝试作为结果上报，但进程退出、事件循环取消或唤醒 Agent 构建失败时，不能从已读代码推断会有可靠的用户终态交付。

## 并发、取消、失败与恢复

**cron 任务。** 更新 job 会先从 APScheduler 移除旧调度再按新定义注册，删除会移除调度并删除数据库行；禁用 job 在运行前检查中直接返回。这确认了“阻止后续启动”的取消/修改语义，见 `astrbot/core/cron/manager.py:204-224,311-349`。未确认删除或禁用发生在 `_run_active_agent_job` 已开始后，是否能取消正在运行的 Agent。

APScheduler 注册时使用 `replace_existing=True` 和 30 秒 `misfire_grace_time`，但代码未在此处设置显式并发数、coalesce 或分布式锁；单进程部署下的重叠执行、应用多副本时的重复运行和超过宽限期的错过触发行为需要运行验证。异常被写入 job 的 `last_error`，循环 job 保留到下个 trigger，单次 job 则仍删除，意味着一次性失败没有内置重试或错误保留任务供稍后重跑。

**后台工具与 handoff。** 普通后台工具把异常捕获为错误结果；外围 coroutine 也只记录日志。它没有持久化并发控制和取消面，进程停止时由事件循环如何处理这些无引用 task 未在该链中确认。后台结果的第二次 Agent 运行同样可能失败，代码记录日志但没有可查询的任务状态行。

## 相邻类目交接与已确认边界

- cron 与后台完成都以 `CronMessageEvent` 重入既有会话；会话历史由会话管理组件持久化，平台发送由消息渠道处理。
- `future_task` 是 Agent 工具面，工具注册、模型循环与 `send_message_to_user` 的权限/平台细节应回链 Agent 工具及 LLM 渠道笔记。
- 概率主动回复是群聊条件唤醒，没有事实任务对象、终态或独立交付记录，未计入本类主链。
- 沙箱、MCP、普通同步工具调用不是本笔记对象；它们只有被标记为后台工具时才通过上述进程内分支交接。

## 未验证事项

- SQLite 之外数据库实现的 cron 持久化与时间字段表现，以及应用重启后错过触发的补跑/跳过语义。
- APScheduler 对同一 job 的并发、misfire 和单次失败删除在真实部署中的表现；多进程/多副本去重未确认。
- cron 或后台结果在各 IM 平台上的实际主动投递，特别是平台能力元数据与 webhook 等外部条件。
- 删除、禁用或停止应用对已经运行的 cron Agent、后台工具和后台 handoff 的真实中断传播。
- 后台 task UUID 是否只用于当前模型回合展示，以及任务完成后主 Agent/消息发送失败时用户的实际可见结果。

## 关键源码索引

- cron 事实模型与数据库契约：`astrbot/core/db/po.py:181-209`、`astrbot/core/db/__init__.py:701-736`。
- cron 创建、会话归属和编辑/删除：`astrbot/core/tools/cron_tools.py:52-321`。
- 调度、状态、失败和单次删除：`astrbot/core/cron/manager.py:98-349`。
- 合成事件、会话投递与历史：`astrbot/core/cron/events.py`、`astrbot/core/cron/manager.py:360-509`。
- 后台工具/handoff 与结果唤醒：`astrbot/core/astr_agent_tool_exec.py:143-184,381-618`。
- 条件主动回复：`astrbot/builtin_stars/astrbot/group_chat_context.py:112-130`。
