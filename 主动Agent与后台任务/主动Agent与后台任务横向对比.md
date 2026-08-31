# 主动 Agent 与后台任务横向对比

> 对比对象：VCPChat、VCPToolBox、Hermes Agent、Open WebUI、LobeHub、AstrBot
>
> 对比更新日期：2026-08-31
>
> 依据：同目录六份基于各项目当前源码快照的单项目调查笔记
>
> 对比方法：先按运行对象是否隔离、触发来源和结果归属划分运行形态，再比较状态权威、并发、取消、失败和恢复；不按定时器名称、模型能力或任务数量排名
>
> 对比范围：脱离当前用户即时输入而触发，且具备可识别运行状态与结果交付的 Agent 运行或后台任务；当前回合内工具、外部执行体接入、单纯消息同步和仅有计时器的实现排除
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

六个样本均已确认至少一条主动运行主链，但它们的工作单元并不相同。Hermes、Open WebUI、LobeHub 与 VCPToolBox 都有独立日程或任务对象；VCPChat、Hermes 与 AstrBot 还能把触发重新接入既有会话；VCPToolBox、Open WebUI 与 AstrBot 另有邮件、日历或群聊等条件唤醒。比较时，触发脱离用户回合是共同条件，不代表各样本都有同样的耐久性、取消能力或结果可见性。

隔离日程运行最适合比较持久状态与恢复。Hermes 的 cron 以 profile 文件、执行账本和认领协议隔离运行；Open WebUI 把每次 Automation 记录为运行历史并生成真实 chat 或 channel；LobeHub 将任务、task topic 和 Brief 放入 PostgreSQL；VCPToolBox 则以 JSON 任务规则和 history 汇总 Agent 派发结果。AstrBot 的 cron 定义和最近状态持久化，但没有单独的运行账本，运行仍重新进入原会话。

会话内续作强调连续性而非后台队列。VCPChat FlowLock 的运行 Session 只在渲染进程内存在，能恢复尚未认领的跨 Topic 请求，不能恢复已运行 Session。Hermes heartbeat 把下一次触发状态保存到会话数据库，但需要 CLI 或 Gateway 轮询器继续运行。AstrBot cron 也以合成事件延续原消息会话，和前两者不同的是其触发定义由持久 cron job 管理。

取消语义普遍分为“阻止下一轮”与“中断当前执行”两层。六个样本都能从静态代码确认前者的至少一部分；Hermes cron 已追踪到取消事件进入 Agent/脚本执行路径。其余样本对已开始的模型流、Agent 或外部工具是否被完整中断，均保留为未验证或未追踪边界。

## 分型地图

```text
隔离日程运行
  |- Hermes Agent: profile cron job -> execution/output/delivery
  |- Open WebUI: Automation -> run -> chat or channel
  |- LobeHub: task -> task topic -> Brief
  `- VCPToolBox: TaskAssistant -> Agent dispatch -> task history

会话内续作
  |- VCPChat: FlowLock -> original Topic message
  |- Hermes Agent: heartbeat -> original session turn
  `- AstrBot: cron -> CronMessageEvent -> original session

条件唤醒或进程内后台工作
  |- VCPToolBox: mail event -> AgentAssistant
  |- Open WebUI: calendar alert -> Socket/notification
  `- AstrBot: background tool or handoff -> follow-up Agent turn
```

同一项目可落入多个分型。例如 Hermes 同时具有会话 heartbeat 与隔离 cron；VCPToolBox 的邮件投递不是 TaskAssistant 的任务记录；AstrBot 的后台工具有运行 ID，却没有可恢复的持久任务对象。

## 核心比较矩阵

| 项目 | 已确认主链分型 | 运行状态权威 | 执行与结果归属 | 重启或重复触发边界 |
| --- | --- | --- | --- | --- |
| [VCPChat](VCPChat-主动Agent与后台任务调查笔记.md) | 会话内续作 | FlowLock Session 在 renderer 内存；跨 Topic 请求落在 Topic 元数据 | 继续写作回原 Topic；任务台只代理 VCPToolBox | Session 重启丢失；pending 跨 Topic 请求可重认领 |
| [VCPToolBox](VCPToolBox-主动Agent与后台任务调查笔记.md) | 后台工作队列、邮件条件唤醒 | TaskAssistant JSON/history；邮件去重文件；Dream 日志 | 任务 runtime/history、AgentAssistant 输入或梦境待审记录 | 任务启动重建；邮件去重可恢复；Dream 默认不加载 |
| [Hermes Agent](Hermes-Agent-主动Agent与后台任务调查笔记.md) | 会话内续作、隔离日程运行 | SessionDB heartbeat；profile job 文件、execution 与 output | 原会话消息；或独立 cron session、输出与投递 | heartbeat 需活跃 poller；cron 以认领和保守 catch-up 避免重复 |
| [Open WebUI](Open-WebUI-主动Agent与后台任务调查笔记.md) | 隔离日程运行、条件通知 | 数据库 automation/run；calendar event 的提醒标记 | 新 chat/channel、run 历史与 Socket；或日历通知 | 原子认领及标记去重；执行中 task 的关闭语义未确认 |
| [LobeHub](LobeHub-主动Agent与后台任务调查笔记.md) | 隔离日程运行、会话式 heartbeat | PostgreSQL task、task topic 与 Brief | 无头 Agent 的 task topic、handoff 与 Brief | 投递后重验状态；本地 heartbeat 计时器不持久化 |
| [AstrBot](AstrBot-主动Agent与后台任务调查笔记.md) | 会话内 cron、进程内后台工作 | 数据库 cron job 的定义和最近状态；后台工具只有内存协程 | 原会话主动消息与历史；后台工具通过后续 Agent 回合交付 | cron 启动重装；后台工具无持久化、查询或恢复链 |

## 调度、并发与控制

| 项目 | 调度与去重 | 已确认的取消或暂停 | 失败、重试与恢复 |
| --- | --- | --- | --- |
| VCPChat | 每 Agent 一个 FlowLock Session；generation 防旧计时器复活 | 可停止 Session 与未来续作 | 最多三次续写重试；运行 Session 不恢复 |
| VCPToolBox | TaskAssistant 跳过 running 任务；邮件内存锁与文件去重；Dream 全局单运行门 | 停用/删除停止未来任务或关闭监听 | Task 记录错误或部分成功；邮件投递未见自动重试；Dream 无进行中取消 |
| Hermes Agent | cron tick 锁、fire claim 与每 job 运行集合；heartbeat 忙碌时跳过 | heartbeat pause/clear；cron pause 和运行期 cancel event | cron 保存终态并回收失主 claim；heartbeat 不补积压 tick |
| Open WebUI | 数据库事务认领到期 Automation；每轮限额 | toggle/delete 阻止后续；未找到独立的运行中取消 API | error run 持久化；未确认自动重试或 backlog 补跑 |
| LobeHub | task topic 冲突拒绝；旧投递由数据库状态和 heartbeat token 拒绝 | paused/终态阻止下一轮 | 连续失败触发 fuse；生产投递重试和运行中中断未验证 |
| AstrBot | APScheduler 单进程注册；未确认分布式锁 | 更新/删除/禁用阻止后续 cron | 最近错误写 job；一次性任务失败后删除；后台工作无恢复 |

上述“已确认的取消”不应理解为全部执行已被终止。除 Hermes cron 外，单项目笔记均未静态走通从控制面到已在运行的模型、工具或外部执行体的完整中断链。

## 相邻类目边界

- Agent 工具记录模型如何发现、审批和调用工具。本类只记录主动运行在何时重新进入该工具链，以及工具执行能否被任务取消。
- 会话与消息管理记录消息、Topic 和会话的整体事实源。本类记录主动运行是否复用、创建或交付到这些对象。
- 外部执行体与应用协作记录独立外部 Agent、账号和交互表面的身份绑定与双向协议。VCPChat 的任务台和 VCPToolBox 的 AgentAssistant 交接不因此改写为客户端后台任务。
- 检索增强与认知编排记录记忆、索引和写回对象。VCPToolBox AgentDream 与 Open WebUI Persistent Memory 只有在说明独立调度时被引用，记忆语义仍留在该类目。

## 已确认边界与未验证事项

- 本类目的“主链确认”均基于静态源码走读；未运行实际 cron、休眠、断线、平台消息投递、QStash、Socket 或多实例部署。
- 分布式去重强度不同：Hermes 与 Open WebUI 已确认持久认领或数据库事务；LobeHub 会在执行端重验状态；AstrBot 本次未确认跨副本锁；VCPChat FlowLock 只管理单个 renderer 内存状态。
- 任务结果的可见表面不同。Open WebUI 和 LobeHub 有独立 run/chat/topic 记录，VCPToolBox 有任务 history，Hermes 有 execution/output；VCPChat 与 AstrBot 会话续作主要借用常规消息历史。
- 本次未将候选清单中尚未建立同等主链证据的项目写为“不支持”；其状态应继续以独特功能清单和相邻类目笔记为准。

## 关键来源索引

- [调查指南](调查指南.md)：准入条件、分型与调查字段。
- [VCPChat 单项目笔记](VCPChat-主动Agent与后台任务调查笔记.md)：FlowLock 与跨 Topic 交接。
- [VCPToolBox 单项目笔记](VCPToolBox-主动Agent与后台任务调查笔记.md)：TaskAssistant、邮件唤醒与 AgentDream。
- [Hermes Agent 单项目笔记](Hermes-Agent-主动Agent与后台任务调查笔记.md)：heartbeat 与 cron 账本。
- [Open WebUI 单项目笔记](Open-WebUI-主动Agent与后台任务调查笔记.md)：Automations 与 Calendar alert。
- [LobeHub 单项目笔记](LobeHub-主动Agent与后台任务调查笔记.md)：Schedule、heartbeat、task topic 与 Brief。
- [AstrBot 单项目笔记](AstrBot-主动Agent与后台任务调查笔记.md)：active-agent cron 与进程内后台工具。
