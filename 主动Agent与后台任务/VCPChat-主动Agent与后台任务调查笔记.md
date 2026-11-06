# VCPChat 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：静态走读 FlowLock、TopicSponsor 交接与认领、桌宠闲时执行器及话题写入，并核对任务台与 VCPToolBox 的 HTTP 交接；未运行 Electron、定时触发或后端服务
>
> 调查范围：会话内与跨话题续作、桌宠条件唤醒及提醒交付、外部任务管理面；VCPToolBox 内部调度与当前回合内工具执行链接对应类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前代码快照确认两类主动运行：FlowLock 按已完成回复的控制协议续写同一话题，桌宠则在用户仍在电脑前且一段时间未交谈时旁路生成闲聊。前者是会话内续作，后者是条件唤醒；两者的调度状态各自在内存中持有，输出均可进入普通话题历史。

FlowLock 的运行对象是渲染进程按 Agent 索引的 Session；每 Agent 最多一个活动 Session，多个 Agent 可并行。状态环和心跳动画是内存状态的可视化。依据：[FlowLock 运行与调度](../../VCPChat/Flowlockmodules/flowlock.js#L69-L110)、[桌宠执行器](../../VCPChat/modules/deskpet/idleRunner.js#L29-L109)。

该运行对象不跨应用重启持久化。页面清理会取消定时器并清空 Session Map；因而 FlowLock 仍不是可在进程重启后补跑的后台队列。页面加载后的 `recoverPendingRequests()` 会枚举 TopicSponsor 预先持久化的 pending 请求，并重新认领唯一候选；这使跨 Topic 的交接请求可恢复，但不持久化已经运行的 Session。`Flowlockmodules/flowlock.js:264-323,810-824`；`modules/ipc/chatHandlers.js:211-309`

任务台不是 VCPChat 自己的调度器。它以 HTTP 读取、保存和手动触发 VCPToolBox 的 TaskAssistant，并以另一组 HTTP 接口展示及取消 AgentAssistant 异步委托。因此任务规则、运行状态、历史和真正执行体的权威均在外部 VCPToolBox；本笔记只记录客户端交接。`Agenttaskmodules/task.js:619-644, 853-869, 985-1065`

## 系统边界与主链

FlowLock 的完整静态主链如下：用户可从聊天标题启动或立即启动，或者模型在已完成的 assistant 消息中输出 `Start` 控制行；管理器创建绑定 Agent 与 Topic 的内存 Session。后续最终消息会被解析为终止、下次延迟或下次提示词指令；无终止指令时，管理器在延迟后调用既有的续写函数，新的回复仍回到这个 Topic。`Flowlockmodules/flowlock.js:43-110, 293-449, 457-577`；协议解析范围见 `Flowlockmodules/flowlock-protocol.js:18-26`。

这条链的触发不依赖一条新的用户消息，且 Session 有轮次、运行消息 ID、下一次心跳、错误和重试计数，因此符合本类的主动运行对象。模型控制文本只有在最终消息完成后才影响状态机；工具请求、工具结果和代码块受协议解析器保护，避免流式半截文本或嵌入内容直接启动续作。静态代码可确认该保护与调用顺序，实际流式边界仍未运行验证。`Flowlockmodules/README.md:11, 46-52, 251-280`；`Flowlockmodules/flowlock.js:293-334`

### 跨 Topic 交接

模型通过外部 TopicSponsor 工具创建 FlowLock 话题时，插件先写入新 Topic 的初始历史和 `flowlockRequest`，其状态为 `pending`，并且不立即切换当前话题。该持久化对象位于 Agent 的配置和 UserData 话题历史中，属于客户端文件事实源。`VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js:102-148, 345-443`

在当前回复正常落盘后，渲染进程请求主进程认领。主进程按 Agent 串行化，检查请求仍为 pending、请求者身份匹配且话题历史存在；恰有一个候选才将状态改为 `consumed` 并返回交接资料。若前端创建新 Session 失败，会把该请求恢复为 pending；多候选会拒绝隐式选择。`modules/ipc/chatHandlers.js:170-185, 211-314, 317-339`；`Flowlockmodules/flowlock.js:169-260`

## 触发、状态与执行

| 维度 | FlowLock 静态事实 |
| --- | --- |
| 触发来源 | 用户启动、最终回复的控制协议，或已持久化的跨 Topic pending 请求。 |
| 状态权威 | 运行中 Session 在渲染进程 Map；跨 Topic 请求在 Agent 配置的 Topic 元数据。 |
| 执行位置 | Electron 渲染进程定时器调用注入的 `continueWritingForContext`；实际 LLM 请求继续走既有聊天链。 |
| 结果归属 | 同一 Topic 的普通 assistant 消息；侧栏和标题状态是显示，不是独立任务记录。 |
| 默认启用 | 未发现启动即自动创建 Session 的路径；需用户、模型协议或待认领请求触发。 |

每次 Session 的下一跳延迟默认来自全局设置或 5 秒，模型可在协议中覆盖为 1 至 86400 秒。调度前会清除已有计时器并捕获 generation；停止、完成、失败或交接都会递增 generation，过期回调不会复活旧运行。`Flowlockmodules/flowlock.js:66-90, 116-149, 457-480, 595-614`

## 并发、取消、失败与恢复

并发边界按 Agent 划分：一个 Agent 启动新 Session 时先停止旧 Session，不同 Agent 的 Session 可同时存在。续写请求有活动消息 ID，只处理自己触发、且仍属于绑定 Topic 的完成事件，避免普通用户消息或其他话题推进运行。`Flowlockmodules/flowlock.js:54-58, 313-334, 486-577`

停止会清除待执行计时器并删除 Session。模型可用 Stop、Complete 或 Fail 终止，优先级为 Fail、Complete、Stop；继续请求或最终消息错误时，默认最多重试三次，达到上限后停止。这里的“取消”只覆盖尚未触发的客户端计时器和后续续写安排；本次未在 FlowLock 路径中确认它会向已在进行的 LLM HTTP 流或工具执行体发送取消。`Flowlockmodules/flowlock.js:350-379, 385-449, 555-577`

重启语义分为两层。运行 Session 在页面 `cleanup()` 时消失，因而没有已运行任务的恢复或补跑；但页面加载后的 `recoverPendingRequests()` 会列出并重新认领唯一的 pending 跨 Topic 请求。请求已被 consumed 而进程在前端 Session 创建后异常退出的后续处理，本次未找到专门的结算或补偿扫描；恢复链只覆盖仍为 pending 的持久化交接对象。`Flowlockmodules/flowlock.js:264-323,810-824`

## 桌宠闲时搭话：条件唤醒与话题交付

桌宠提供另一条独立主动链：启用闲时搭话后，主进程每分钟挑选一个可见桌宠，优先最近交谈的 Agent，决定是否发起旁路生成。默认开关关闭；可选间隔为 10、30、60 分钟，默认 30 分钟。运行对象是每 Agent 的活动/尝试/失败时间与活动计数，执行器用一个全局 running 标记防止自身重叠。它不轮询所有候选：首个候选被跳过时，本次 tick 直接结束。依据：[实际接线](../../VCPChat/modules/deskpet/petHandlers.js#L138-L151)、[执行器](../../VCPChat/modules/deskpet/idleRunner.js#L29-L109)、[候选顺序](../../VCPChat/modules/deskpet/petCommands.js#L137-L145)。

触发需满足间隔已到、桌宠可见、免打扰关闭、系统未锁定且键鼠空闲不足五分钟，并避开本地 23:00–08:00。生成失败另有十分钟冷却，但最近尝试时间也参与正常间隔判断。生成使用 Agent 当前模型与三模式人设，读取配置前 30 个话题中文件修改时间最新的一份历史，取最后八条有效对话、每条最多约 600 字符，发一次非流式 HTTP 请求，45 秒超时；不走普通聊天的完整上下文编译器。依据：[条件与消息构建](../../VCPChat/modules/deskpet/idleChat.js#L8-L92)、[请求](../../VCPChat/modules/deskpet/idleChat.js#L119-L137)、[近期历史选择](../../VCPChat/modules/deskpet/idleRunner.js#L67-L82)。

交付前重新检查可见性、免打扰和活动计数，用户在生成期间交谈则丢弃本次结果；主窗口位置无法取得，或已打开该 Agent 的闲聊话题时也跳过。有效回复清理工具块、思维链与控制标记，裁至约 160 字符后，先创建或复用带 creatorSource 的“桌宠闲聊”话题并追加 assistant 消息，再发送桌宠气泡事件；点击气泡可进入该话题。配置与历史分别提交，气泡发送失败也可能已经留下持久消息，没有跨两份文件及窗口事件的事务。依据：[清理与落盘](../../VCPChat/modules/deskpet/idleChat.js#L95-L171)、[交付时复查](../../VCPChat/modules/deskpet/idleRunner.js#L111-L164)。

运行计时与冷却保存在进程内存，重启从新桌宠活动时间重新计时；已有闲聊话题和消息继续保留。关闭功能或退出时停止 interval，但 stop 没有中断已在途的 HTTP 请求，交付前也未复查开关与退出标志；全局 running 只约束本执行器，不能据此推断与普通聊天、FlowLock 全局互斥。静态源码已确认这些控制边界，实际退出和多窗口时序未运行验证。

桌宠还观察分布式工具结果，将 TopicSponsor 创建的话题显示为气泡，并在 VCPAlarm 成功返回后登记最多 50 个、最远七天的内存闹钟；相同提醒与角色、到期时间差不足一分钟时去重。闹钟到期可显示隐藏桌宠，话题通知仍遵循可见性与免打扰；退出清空这些定时器，未发现闹钟恢复扫描。此处是工具结果的展示与本地提醒交接，外部工具自身调度另行调查。依据：[工具结果与闹钟](../../VCPChat/modules/deskpet/petProactive.js#L131-L186)、[窗口投递](../../VCPChat/modules/deskpet/petProactive.js#L19-L26)。

## 外部任务面与相邻类目交接

VCPChat 的任务台将配置/状态请求发至 `/task-assistant/config`、`/task-assistant/status` 和 `/task-assistant/trigger`；保存操作也把任务列表及全局开关送至同一服务。它是后端任务的配置与结果查看面，而非客户端任务存储或 worker。后端 TaskAssistant 的规则持久化、调度、派发、历史和重启处理见 VCPToolBox 的同类笔记。`Agenttaskmodules/task.js:623-644, 985-995, 1045-1065`

同一界面另轮询 `/agent-assistant/delegations`，展示运行中/近期委托并将用户取消请求 POST 到后端。该对象属于 VCPToolBox AgentAssistant 的外部执行体协调；VCPChat 不保有其状态，也不负责取消能否抵达实际 Agent 或工具。`Agenttaskmodules/task.js:646-705, 764-870`

FlowLock 触发的继续写作可使用既有 Agent、模型与工具配置，但 FlowLock 自身不决定工具权限。工具调用和当前回合内的模型循环属于 Agent 工具/对话请求类目；TopicSponsor 只在其创建可交接 Topic 的位置纳入本笔记。

## 未验证事项

- 未运行 Electron，未验证定时器在最小化、休眠、窗口关闭或渲染进程异常时的真实时间语义。
- 未验证 `continueWritingForContext` 对实际聊天请求、流中断和工具取消的传播。
- 未验证跨 Topic 的 pending/consumed/恢复链在真实文件竞争、重启和多个窗口下的行为。
- 未验证任务台与 VCPToolBox 服务的鉴权、网络失败提示和实际取消效果。

## 关键源码索引

- `Flowlockmodules/flowlock.js:8-505`：Session 状态机、调度、终止和重试。
- `Flowlockmodules/flowlock.js:264-323,810-824`：pending Flowlock 请求的页面加载恢复与认领。
- `Flowlockmodules/flowlock-protocol.js:18-26`：控制协议和受保护内容的解析入口。
- `modules/ipc/chatHandlers.js:170-339`：跨 Topic 请求的串行认领与恢复。
- `preloads/api/flowlock.js`：渲染端可用的 Flowlock 能力声明。
- [idleRunner](../../VCPChat/modules/deskpet/idleRunner.js)：桌宠按条件运行、提交前复查与气泡投递。
- [idleChat](../../VCPChat/modules/deskpet/idleChat.js)：条件判定、消息编译、45 秒请求与闲聊话题写入。
- `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js:102-148, 345-443`：pending 请求、Topic 与历史落盘。
- `Agenttaskmodules/task.js:619-670, 853-1065`：外部任务及异步委托管理面。
