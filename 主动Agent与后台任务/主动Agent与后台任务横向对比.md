# 主动 Agent 与后台任务横向对比

> 对比对象：VCPChat、VCPToolBox、Hermes Agent、Open WebUI、LobeHub、AstrBot、OpenClaw、RikkaHub
>
> 对比更新日期：2026-11-05
>
> 依据：同目录八份单项目调查笔记；调查更新日期、代码快照和静态确认范围以各篇元数据为准，未运行真实调度、模型或平台投递
>
> 对比方法：先按运行对象是否隔离、触发来源和结果归属划分运行形态，再比较状态权威、并发、取消、失败和恢复；不按定时器名称、模型能力或任务数量排名
>
> 对比范围：脱离当前用户即时输入而触发，且具备可识别运行状态与结果交付的 Agent 运行或后台任务；当前回合内工具、外部执行体接入、单纯消息同步和仅有计时器的实现排除
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

八个样本均已确认至少一条主动运行主链，工作单元各异。RikkaHub 的回合后记忆整理符合条件唤醒：它有独立模型循环、运行状态和记忆写回，用户日程与系统级定时唤醒仍未在其已查范围找到。Hermes、Open WebUI、LobeHub、VCPToolBox 与 OpenClaw 都有独立日程或任务对象；VCPChat、Hermes、AstrBot 与 OpenClaw 还能把触发重新接入既有会话；VCPToolBox、Open WebUI 与 AstrBot 另有邮件、日历或群聊等条件唤醒，OpenClaw 另有 hook/webhook 外部事件唤醒。比较时，触发脱离用户回合是共同条件；耐久性、取消能力与结果可见性需按各样本分别比较。

隔离日程运行可比较持久认领与结果交付。Hermes 保存 profile 级执行账本，LobeHub 保存任务、运行话题和 Brief，VCPToolBox 保存任务定义与派发历史；OpenClaw 以日程 receipt 管理运行权威，另持久化日程历史。

终态含义仍需按目标区分。Open WebUI 的持久 chat 等生成结束并复验消息，channel 则在入口返回后记成功；AstrBot 的 dispatched 只证明唤醒事件入队，后续 Agent 回合成败另看会话与 trace。

会话内续作强调连续性而非后台队列。VCPChat FlowLock 的运行 Session 只在渲染进程内存在，能恢复尚未认领的跨 Topic 请求，不能恢复已运行 Session。Hermes heartbeat 把下一次触发状态保存到会话数据库，但需要 CLI 或 Gateway 轮询器继续运行。OpenClaw 的 cron main 与 heartbeat 也走会话续作：main job 只把 system event 放入目标会话再请求 heartbeat，heartbeat 的调度与状态判断已收进 auto-reply 主题模块与 gateway state owner 两侧，触发定义与投递结果（run receipt、heartbeat outcome）仍然持久化。AstrBot cron 也以合成事件延续原消息会话，和前者不同的是其触发定义由持久 cron job 管理，且 cron 与后台唤醒现在共用同一套唤醒事件对象。

取消语义普遍分为“阻止下一轮”与“中断当前执行”两层。各样本都能从静态代码确认前者的至少一部分；Hermes cron 与 OpenClaw 的 cron/hook 运行取消、后台 exec 的进程终止都已追踪到取消事件进入 Agent/脚本执行或真实进程路径。其余样本对已开始的模型流、Agent 或外部工具是否被完整中断，均保留为未验证或未追踪边界。

还有一种不进入后台队列的主动形态：VCPToolBox 的 VCPSleep 让当前工具链原地等待到指定时间（单次上限 12 小时），醒来后把当前时间交还给调用方；若管理员开启联动且 AgentDream 已启用，执行器会在等待期间异步请求一次梦，梦境失败不影响睡眠本身。它因此是挂在模型工具调用上的同步等待，调度身份由外层工具调用持有。

## 分型地图

```text
隔离日程运行
  |- Hermes Agent: profile cron job -> execution/output/delivery
  |- Open WebUI: Automation -> run -> chat or channel
  |- LobeHub: task -> task topic -> Brief
  |- VCPToolBox: TaskAssistant -> Agent dispatch -> task history
  `- OpenClaw: cron job -> receipt/task run -> isolated/detached run session 或 main heartbeat 回合

会话内续作
  |- VCPChat: FlowLock -> original Topic message
  |- Hermes Agent: heartbeat -> original session turn
  |- AstrBot: cron -> AgentWakeupEvent -> original session
  `- OpenClaw: cron main/heartbeat -> system event -> main session

条件唤醒或进程内后台工作
  |- VCPToolBox: mail event -> AgentAssistant
  |- Open WebUI: calendar alert -> Socket/notification
  |- AstrBot: background tool or handoff -> follow-up Agent turn
  |- VCPChat: 桌宠闲时条件 -> 旁路生成 -> 闲聊话题与气泡
  |- RikkaHub: 回合后空闲/轮数/生命周期 -> 独立整理 -> 记忆文件与结果
  `- OpenClaw: hook/webhook -> 一次性 cron run 或 wake -> heartbeat/isolated run
```

同一项目可落入多个分型。例如 Hermes 同时具有会话 heartbeat 与隔离 cron；VCPToolBox 的邮件投递不是 TaskAssistant 的任务记录；AstrBot 的后台工具有运行 ID，却没有可恢复的持久任务对象。OpenClaw 的分型差异由 sessionTarget 决定：同一份 cron 定义既可回主会话（main）也可走独立 run session（isolated/current），heartbeat 的调度与状态判断则分布在 auto-reply 主题模块与 gateway state owner 两处，不再是单一的 runner 文件。

## 核心比较矩阵

| 项目 | 已确认主链分型 | 运行状态权威 | 执行与结果归属 | 重启或重复触发边界 |
| --- | --- | --- | --- | --- |
| [VCPChat](VCPChat-主动Agent与后台任务调查笔记.md) | 会话内续作、桌宠条件唤醒 | FlowLock Session 与桌宠计时在内存；pending 跨 Topic 请求持久化 | 原 Topic 续写；桌宠写闲聊话题再发气泡；任务台代理外部服务 | 运行与桌宠计时重启丢失；pending 请求可重认领，已有话题消息保留 |
| [VCPToolBox](VCPToolBox-主动Agent与后台任务调查笔记.md) | 后台工作队列、邮件条件唤醒、工具链内睡眠 | TaskAssistant JSON/history；邮件去重文件；Dream 日志；VCPSleep 的同步等待 | 任务 runtime/history、AgentAssistant 输入、梦境待审记录；睡眠结果回到当前工具链 | 任务启动重建；邮件去重可恢复；Dream 默认不加载；睡眠上限 12 小时，梦只是可选联动 |
| [Hermes Agent](Hermes-Agent-主动Agent与后台任务调查笔记.md) | 会话内续作、隔离日程运行 | SessionDB heartbeat；profile job 文件、execution 与 output | 原会话消息；或独立 cron session、输出与投递 | heartbeat 需活跃 poller；cron 以认领和保守 catch-up 避免重复 |
| [Open WebUI](Open-WebUI-主动Agent与后台任务调查笔记.md) | 隔离日程运行、条件通知 | 数据库 automation/run；Calendar 标记与收件箱同事务写入 | 持久 chat 复验 done/error；channel 仅派发后记成功；通知另有在线 Socket | 认领先推进下次时间，终态 run 后写；跨实例认领强度取决数据库方言 |
| [LobeHub](LobeHub-主动Agent与后台任务调查笔记.md) | 隔离日程运行、会话式 heartbeat | PostgreSQL task、task topic 与 Brief（`task_activities` 仅作变更历史，不替代当前状态） | 无头 Agent 的 task topic、handoff 与 Brief | 投递后重验状态；本地 heartbeat 计时器不持久化 |
| [AstrBot](AstrBot-主动Agent与后台任务调查笔记.md) | 会话内 cron、进程内后台工作 | 数据库定义和最近派发状态；后台工具为内存协程 | 两者均排队唤醒普通流水线，回复回原会话；dispatched 只证明入队 | cron 启动重装，错过触发的实况未确认；后台任务无持久查询或恢复链 |
| [OpenClaw](OpenClaw-主动Agent与后台任务调查笔记.md) | 隔离日程、会话续作、事件唤醒、后台进程与子 Agent | cron 定义/receipt/日程历史、子 Agent 与更新账本分别持久化；后台进程由 registry 托管 | main 回主会话，其他目标走独立 run session；经 durable channel 或 requester wake 交付 | cron 有 owner fence 与有界补跑，子 Agent 有恢复链；后台进程部分 durable 句柄的重启接管尚未下钻 |
| [RikkaHub](RikkaHub-主动Agent与后台任务调查笔记.md) | 回合后记忆维护的条件唤醒 | 内存调度与运行状态；记忆文件、整理进度与历史落库 | 独立模型循环写记忆库，界面显示改动、耗时与错误 | 启动按数据库进度重建待整理列表；进程被杀期间无系统唤醒，聊天 Job 本身不恢复 |

## 调度、并发与控制

| 项目 | 调度与去重 | 已确认的取消或暂停 | 失败、重试与恢复 |
| --- | --- | --- | --- |
| VCPChat | 每 Agent 一个 FlowLock Session；桌宠默认关闭，条件/冷却筛选且执行器全局单运行 | 停止 Session 与未来续作；关闭桌宠停止后续 tick，已在途请求未接通中止 | FlowLock 最多三次续写重试；桌宠失败冷却，重启重新计时，运行不恢复 |
| VCPToolBox | TaskAssistant 跳过 running 任务；邮件内存锁与文件去重；Dream 全局单运行门 | 停用/删除停止未来任务或关闭监听 | Task 记录错误或部分成功；邮件投递未见自动重试；Dream 无进行中取消 |
| Hermes Agent | cron tick 锁、fire claim 与每 job 运行集合；heartbeat 忙碌时跳过 | heartbeat pause/clear；cron pause 和运行期 cancel event | 未认领的 pending slot 可在失主后恢复；已认领执行不盲目重放；heartbeat 不补积压 tick |
| Open WebUI | 每轮最多认领十项；PostgreSQL 行锁跳过已锁项，其他方言需验证；Calendar 标记与收件箱事务去重 | 停用/删除阻止后续；聊天任务可停止，持久 chat 取消记 error | 无失败立即重试；执行前已推进下次时间，进程中断可能尚无终态 run |
| LobeHub | task topic 冲突拒绝；状态与 heartbeat token 拒绝旧投递 | 暂停/归档/删除阻止后续；删除请求中断关联运行，撤销不会复活该运行 | 连续失败到阈值才暂停；通常留待下个日程，生产投递和真实中断未验证 |
| AstrBot | APScheduler 注册有五分钟宽限，未确认跨副本锁；群聊列表共享、私聊按创建者过滤 | 删除仅取消 cron 派发阶段；会话停止信号可取消后台工具并挡迟到唤醒 | Agent 回合失败不回写 cron 行；一次性任务派发后删除，失败无内置重试；后台任务不恢复 |
| OpenClaw | cron 默认并发八项；marker、receipt 和配置 revision 分别约束本进程、跨进程及旧定义；heartbeat 同目标单运行 | 禁用/删除/编辑请求取消真实 controller；超时向 Agent 传播 abort，后台进程经 supervisor 或 durable 句柄取消 | cron 退避及阈值停用，启动按失主 receipt 恢复并有界补跑；子 Agent 和消息有持久交付链，进程接管需按执行模式另查 |
| RikkaHub | 自动记忆整理默认开启；按记忆库互斥，回合后由空闲、轮数或生命周期触发 | 关闭自动整理后只积累待办，供手动消费；运行中统一取消入口未在本篇确认 | 自动失败不立即重试，留待后续回合或手动处理；重启重建待办，不接管旧模型循环 |

取消需按 owner 分层理解：Hermes 与 OpenClaw 已追到执行取消信号，AstrBot 可取消已登记后台任务并挡住迟到唤醒，LobeHub 删除会请求关联运行中断；这些静态接线仍需按真实模型、工具与进程观察完成情况。停止未来派发、请求中断和确认执行终止是三种状态。

## 相邻类目边界

- Agent 工具记录模型如何发现、审批和调用工具。本类只记录主动运行在何时重新进入该工具链，以及工具执行能否被任务取消。
- 会话与消息管理记录消息、Topic 和会话的整体事实源。本类记录主动运行是否复用、创建或交付到这些对象。
- 外部执行体与应用协作记录独立外部 Agent、账号和交互表面的身份绑定与双向协议。VCPChat 的任务台和 VCPToolBox 的 AgentAssistant 交接不因此改写为客户端后台任务。
- 检索增强与认知编排记录记忆、索引和写回对象。VCPToolBox AgentDream、Open WebUI Persistent Memory 与 RikkaHub 记忆整理只有在说明独立调度时被引用，记忆语义仍留在该类目。

## 已确认边界与未验证事项

- 本类目的“主链确认”均基于静态源码走读；未运行实际 cron、休眠、断线、平台消息投递、QStash、Socket 或多实例部署。
- OpenClaw 的 cron/heartbeat/hook/exec/subagent 主链均基于静态走读，未启动真实 Gateway、Channel adapter、Provider 或 ProcessSupervisor，未验证多 Gateway 同库时 receipt owner 判断与真实长停机 catch-up。
- OpenClaw 各状态 owner 分别持久化日程历史、子 Agent、更新账本与消息交付。`task_runs` 表仍作为 cron 专属历史使用，已移除的是通用 tasks RPC/注册表；媒体 operation 和后台进程的可恢复性需分别检查。内部 outcome 与已发送消息是两份记录，前者只描述运行结果。
- 分布式去重强度不同：Hermes 与 Open WebUI 已确认持久认领或数据库事务；LobeHub 会在执行端重验状态；AstrBot 本次未确认跨副本锁；VCPChat FlowLock 只管理单个 renderer 内存状态。
- 任务结果的可见表面不同。Open WebUI 和 LobeHub 有独立 run/chat/topic 记录，VCPToolBox 有任务 history，Hermes 有 execution/output；VCPChat 与 AstrBot 会话续作主要借用常规消息历史。
- 本次未将候选清单中尚未建立同等主链证据的项目写为“不支持”；其状态应继续以独特功能清单和相邻类目笔记为准。

## 关键来源索引

- [调查指南](调查指南.md)：准入条件、分型与调查字段。
- [VCPChat 单项目笔记](VCPChat-主动Agent与后台任务调查笔记.md)：FlowLock、跨 Topic 交接与桌宠条件唤醒。
- [VCPToolBox 单项目笔记](VCPToolBox-主动Agent与后台任务调查笔记.md)：TaskAssistant、邮件唤醒与 AgentDream。
- [Hermes Agent 单项目笔记](Hermes-Agent-主动Agent与后台任务调查笔记.md)：heartbeat 与 cron 账本。
- [Open WebUI 单项目笔记](Open-WebUI-主动Agent与后台任务调查笔记.md)：Automations 与 Calendar alert。
- [LobeHub 单项目笔记](LobeHub-主动Agent与后台任务调查笔记.md)：Schedule、heartbeat、task topic 与 Brief。
- [AstrBot 单项目笔记](AstrBot-主动Agent与后台任务调查笔记.md)：active-agent cron 与进程内后台工具。
- [OpenClaw 单项目笔记](OpenClaw-主动Agent与后台任务调查笔记.md)：cron、heartbeat、hooks、后台 exec、detached subagent 与 durable delivery。
- [RikkaHub 单项目笔记](RikkaHub-主动Agent与后台任务调查笔记.md)：回合后记忆整理的条件唤醒、运行与待办恢复；会话和媒体任务的后台保活边界。
