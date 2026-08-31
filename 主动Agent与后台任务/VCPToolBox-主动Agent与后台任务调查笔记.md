# VCPToolBox 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`e2762e4dab5c70952d88f96689fba1270624e5ef`（分支：`main`）
>
> 调查方式：静态走读 TaskAssistant、VCPClawMail 和 AgentDream 的 manifest、初始化、状态、调度、执行与关闭路径，并参照 VCPChat 的任务面交接；未运行 Node 服务、上游 LLM 或 ClawMail SDK
>
> 调查范围：具名任务派发、邮件事件驱动投递、非对话梦境调度；不展开请求内工具调用、AgentAssistant 的通用委托实现和外部邮箱 SDK 内部行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前快照确认三种不同形态的主动运行。TaskAssistant 是持久化的后台任务队列：规则由 `task-center-data.json` 持有，node-schedule 触发后向具名 Agent 派发提示词，结果写回任务运行字段和有上限的历史。其全局开关默认关闭。`Plugin/VCPTaskAssistant/vcp-task-assistant.js:10-36, 281-484, 697-734`

VCPClawMail 是条件唤醒：常驻 WebSocket 收到邮件事件后刷新邮箱缓存；若该邮箱绑定子邮箱和 Agent，插件用已处理邮件记录去重、读取正文与附件，再交给 AgentAssistant。低频轮询是 WebSocket 的后备，不是为每封公共邮箱邮件创建任务对象。`Plugin/VCPClawMail/VCPClawMail.js:1738-1786, 1847-2039, 2041-2181`

AgentDream 是另一条具备独立状态和审批产物的定时运行链，但其 manifest 为 `plugin-manifest.json.block`，因此在当前仓库的加载约定下默认禁用。启用且配置梦 Agent 后，调度器才每 15 分钟按时间窗、冷却和概率串行触发。`Plugin/AgentDream/AgentDream.js:755-913, 922-957`；`Plugin/AGENTS.md:24-31`

TaskAssistant 调用 AgentAssistant、VCPClawMail 将邮件交给 AgentAssistant、AgentDream 直接调用聊天完成接口，这些是主动运行与 Agent 执行域的交接。任务调度器只负责何时和以什么输入唤醒 Agent；模型循环、工具权限、委托状态机及其实际取消语义属于 Agent 工具和外部执行体协调，不在本笔记重复归因。

## 系统边界与主链

### TaskAssistant：后台工作队列

主链为：管理面或工具保存任务规则 -> 任务数据写入插件目录 JSON -> 初始化时重建 node-schedule 作业 -> 到期后创建运行状态并构造提示词 -> 顺序唤醒目标 Agent -> 汇总成功、部分成功或错误 -> 写回运行字段和历史。任务可为论坛巡航或自定义提示词；后者直接使用模板，前者先读取论坛帖子列表填充模板。`Plugin/VCPTaskAssistant/vcp-task-assistant.js:177-215, 259-484, 608-614, 715-853`

任务对象内含启用状态、调度规则、目标 Agent、派发参数和 runtime 字段；runtime 记录 running、开始/完成时间、上次结果/错误、耗时、计数和下一次运行。`task-center-data.json` 才是该对象与历史的权威，内存 `activeTimers` 只保存当前进程的 node-schedule Job。`Plugin/VCPTaskAssistant/vcp-task-assistant.js:10-36, 86-170, 486-510`

### VCPClawMail：邮件条件唤醒

主链为：初始化加载已处理邮件状态，启动 WebSocket 和后备轮询 -> WebSocket 的 `mailId` 事件触发缓存刷新 -> 若命中已启用的子邮箱绑定，先检查并写入去重记录 -> 读取邮件及有限附件 -> 构造含邮箱槽位和安全提示的多模态输入 -> 调用 AgentAssistant -> 将投递结果摘要或错误写入内存缓存和占位符。`Plugin/VCPClawMail/VCPClawMail.js:1851-1895, 1897-2039, 2154-2181`

运行身份是“子邮箱槽位 + mailId”，而非通用任务表。短时内存锁避免同一进程并发处理，`submail-processed.json` 将每个槽位已处理 ID 持久化并默认只保留最近 500 个，因此重启后可抑制已见邮件的重复投递。公共邮箱轮询只更新 `mailbox-cache.json` 和系统提示词占位符。`Plugin/VCPClawMail/VCPClawMail.js:1738-1768, 1847-1895, 1967-2020`

### AgentDream：隔离的定时记忆整理

主链为：插件初始化读取并恢复上次成功梦境时间 -> 定时检查符合时间窗、冷却和概率的 Agent -> 串行 `triggerDream` -> 生成梦境叙事和待审操作 -> 写入 `dream_logs/`；成功后持久化每个 Agent 的最后梦境时间。调度运行中以单个 `isDreamingInProgress` 门阻止重叠，并在多 Agent 间等待 30 秒。`Plugin/AgentDream/AgentDream.js:53-109, 198-361, 755-913, 922-957`

梦操作以 `pending_review` 记录落盘，意图由管理路由审批后影响日记和索引。插件导出的 approve/reject 函数仍返回 `not_implemented`，因此不能把它们当作可从插件工具面完成审批的链路；审批执行域在管理路由，具体路由运行未验证。`Plugin/AgentDream/AgentDream.js:467-633, 995-1001`；`Plugin/AgentDream/README.md:30-38, 99-108`

## 调度、并发、取消与恢复

| 运行形态 | 调度与并发 | 取消/失败 | 重启语义与默认状态 |
| --- | --- | --- | --- |
| TaskAssistant | interval 最小 10 分钟，另支持 cron、once、manual；同一任务 `running` 时跳过，超过 10 分钟会重置为卡死。目标 Agent 在单次任务中按顺序派发。 | 删除或停用会取消未来 Job；代码未向正在执行的 `wakeUpAgent` 传 AbortSignal。单个 Agent 失败可形成 partial_success，全部失败为 error；每次 interval 不论结果都会再调度。 | 启动把遗留 running 置为 false 并记错误，再按数据重建 Job；不补跑错过时间。`globalEnabled` 默认 false。 |
| VCPClawMail | WebSocket 优先，断线按退避定时重连；低频轮询有下限。每封子邮件有内存锁和文件去重。 | shutdown 停轮询、清重连计时器并断开 WebSocket；本次未找到已进入 AgentAssistant 的邮件处理取消传播。读取或投递错误写缓存，但已在读取前标记 processed，是否重投取决于人工/外部输入而非自动重试。 | 关闭保存缓存与去重状态，初始化加载去重状态并重连；需配置 SDK、邮箱及绑定，实时监听默认启用。 |
| AgentDream | 每 15 分钟检查，默认 1-6 点、8 小时冷却、0.6 概率；全局单运行门与串行 Agent 减少并发。 | 关闭插件或服务可停止后续检查；本次未找到进行中 LLM 请求的任务级取消或失败自动重试。 | 保存最后成功时间避免重启立即重触发；但插件 manifest 为 `.block`，默认不加载。 |

TaskAssistant 的 `once` 作业执行后自动禁用；cron 的下一次时间取自 Job，interval 则在本轮完成后重新安排。运行历史最多保留配置的数量，默认上限 200；状态更新函数当前只输出调试日志，所以管理面需要轮询而非从该插件接收实时推送。`Plugin/VCPTaskAssistant/vcp-task-assistant.js:45-51, 512-605, 697-711`

VCPClawMail 的 WebSocket 连接若稳定足够久会重置重连计数；断开后以抖动退避重新连接。该代码可确认连接生命周期管理，不能确认外部 SDK 实际是否保证事件投递顺序、是否会重复或遗漏 mailId。`Plugin/VCPClawMail/VCPClawMail.js:1795-1845, 2041-2152`

## 结果交付、资源与治理边界

TaskAssistant 的结果归属任务自身的 runtime 和 history，并不直接回写某个聊天 Topic。它调用 AgentAssistant 时可选择普通临时联系或 `task_delegation`；后者的独立执行状态、最终报告和取消由 AgentAssistant 持有。VCPChat 任务台只是通过 HTTP 读取该后端的任务状态，并另行展示 AgentAssistant 委托。`Plugin/VCPTaskAssistant/vcp-task-assistant.js:227-257, 358-450`；`VCPChat/Agenttaskmodules/task.js:646-870`

VCPClawMail 的直接交付是 AgentAssistant 输入和邮件缓存/占位符。子邮箱可选异步委托；普通模式使用稳定 session ID，使邮件进入绑定 Agent 的持续上下文。邮件正文中的绕过安全、泄密、删除或未授权外部操作指令被放入提示词中的拒绝要求，但这是一段模型提示而非代码级邮箱内容隔离。附件数量在自动投递时受配置限制，具体内容解析和 Agent 实际执行未运行验证。`Plugin/VCPClawMail/VCPClawMail.js:1897-1965, 1967-2017`

AgentDream 的可观察结果是梦境会话日志和待审操作，不是聊天窗口消息。其破坏性记忆修改的设计边界是管理审批；静态代码显示梦插件本身的审批导出为占位，故本次不能确认“生成 pending_review 后必能在已部署管理面结算”的端到端结果。`Plugin/AgentDream/AgentDream.js:467-633, 973-1001`

## 未验证事项

- 未运行 TaskAssistant，未验证 node-schedule 对 cron、时区、进程休眠和错过触发的实际处理。
- 未走读 AgentAssistant 的执行与取消实现，故不确认派发成功是否等同于目标 Agent 已完成工作。
- 未连接 ClawMail SDK，未验证 WebSocket、轮询、附件解析、退避重连及重复邮件下的实际投递。
- 未启用 AgentDream；未验证梦境生成、管理路由审批、日记/索引修改和中途进程停止后的结算。
- 未调查各插件管理 API 的鉴权与前端可见性，除本笔记直接引用的运行对象和交接外不作安全结论。

## 关键源码索引

- `Plugin/VCPTaskAssistant/vcp-task-assistant.js:177-215, 227-484, 512-614, 697-853`：任务持久化、执行、调度、状态与管理命令。
- `Plugin/VCPClawMail/VCPClawMail.js:1738-2181, 2269-2280`：轮询、WebSocket、去重、邮件投递、初始化和关闭。
- `Plugin/AgentDream/AgentDream.js:53-109, 198-361, 755-957, 995-1001`：梦境执行、调度状态和审批接口边界。
- `VCPChat/Agenttaskmodules/task.js:619-670, 853-870`：VCPChat 对后端任务及异步委托的外部管理交接。
