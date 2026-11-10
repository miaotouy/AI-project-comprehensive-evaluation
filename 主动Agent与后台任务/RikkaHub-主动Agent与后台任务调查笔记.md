# RikkaHub 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：只读复查 `AndroidManifest.xml`、`app/src/main/java/me/rerere/rikkahub/service/` 全部服务与通知实现、`data/ai/MemoryConsolidationScheduler.kt`、`data/sync/`、`web/` 嵌入服务、`mediagen/` 模块及 DataStore 设置定义；对全仓 Kotlin 源码检索 `WorkManager`、`AlarmManager`、`JobScheduler`、`BroadcastReceiver`、`CoroutineWorker`、`WorkRequest` 等调度 API 的声明与调用点；并对照仓库自带的 `docs/references/chat-generation-pipeline.md`。未修改被调查项目。
>
> 调查范围：本类目聚焦"可在当前用户回合之外被触发并以独立运行状态完成/失败/取消"的工作单元。覆盖：生成过程中 App 退到后台的行为、前台服务与通知渠道、生成 Job 的调度/取消/恢复、媒体创作的后台任务、记忆库的后台整理（“做梦”）、悬浮窗、是否存在 WorkManager/AlarmManager/广播等后台入口，以及"定时提醒"类功能的实际形态。不展开：消息生成管线内部的 Transformer 细节、Agent 工具权限模型、MCP/Workspace/Skill 的工具语义、WebDAV/S3 备份协议与媒体创作页面本身。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是原生 Android 的 LLM 聊天客户端，具备由回合后空闲、累计轮数与应用生命周期条件唤醒的后台记忆维护：调度器在当前聊天回合之外发起独立模型循环，结果写入记忆文件记录，并向界面交付运行状态、改动与错误。它符合本类目的条件唤醒形态；已读源码中未找到用户可配置的 cron/heartbeat 任务或系统级定时唤醒。两种边界分开记录。

后台工作分为三类：

- **会话级后台生成**：用户动作或外部 HTTP 请求都可以发起一次生成，生成期间 `ChatGenerationForegroundService` 把进程钉在前台；结果写入会话数据库，完成事件带有内容预览、App 不在前台且用户已开启生成通知时，才投递系统通知。运行对象与状态权威都留在内存，进程结束即失效，没有补跑。
- **媒体创作任务**：用户提交后，`MediaCreationService` 在后台完成提交、轮询与下载，`MediaCreationForegroundService` 负责保活；记录连同 `taskId` 一起落库，应用重启后可凭 `taskId` 继续查询（见 [媒体创作笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)）。
- **记忆库整理（“做梦”）**：一轮对话结束后，`MemoryConsolidationScheduler` 先记下待整理轮数，并在空闲计时到点（默认 2 分钟）、累计轮数到上限（6 轮）、应用切后台、用户离开会话或应用重启时启动一次整理，后台调用模型把对话内容写进记忆库；应用不可见时由 `MemoryDreamForegroundService` 保活。它仍由用户活动驱动，不是独立日程。

另有两项与后台体验相关：后台生成时可选显示**悬浮窗**（默认关闭，需悬浮窗权限），支持查看进度与快速回复；时间提醒、备份提醒与更新检查都不启动运行。媒体创作页已接入视频生成，聊天内模型侧仍只覆盖图片。

## 系统边界与主链

本类目的对象是"退到后台仍继续、并以独立 Job 生命周期收尾"的运行。权威状态分三层：消息、媒体创作记录与记忆文件记录持久化在 Room，媒体实体文件在私有文件目录；"是否正在生成""当前 Job 是什么""队列里还有什么""哪几次对话待整理"只存在于进程内存；媒体创作记录额外把 `taskId` 落库以便恢复。

```text
【会话生成】
触发（App 内发送/重生成、工具审批回调，或 Web API 端点）
  -> ChatService 把输入放入该会话的 MessageQueue 串行派发
  -> launchGenerationJob 先 acquire 前台服务（dataSync）再启动生成协程
  -> ai 模块 runAgent 流式生成；整轮结束兜底落库，finally release 服务
  -> 轮次结束后异步生成标题/建议，并通知 MemoryConsolidationScheduler.onTurnFinished

【记忆整理】
onTurnFinished -> 记下待整理轮数 -> 空闲计时（2 分钟）或攒到 6 轮 -> 后台调用模型整理
  -> 应用不可见时 acquire MemoryDreamForegroundService 保活 -> 写入记忆文件

【媒体创作】
MediaCreationService.submit -> 提交厂商接口 / 创建任务 -> 轮询 + 下载 -> 更新记录状态
```

请求侧的提交入口、生成循环、流式事件与停止/重试/续写等机制由 [对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md) 承担。运行期另有两个进程级支点：绑定 Application 的 `AppScope` 协程作用域，以及注册为 Koin 单例的事件订阅者 `ChatNotificationManager`。

## 触发、调度与运行对象

### 触发来源

聊天与媒体提交由用户或外部请求发起；记忆维护可由回合后的系统条件自行触发：

| 触发来源 | 入口 | 是否独立于当前回合 | 备注 |
| --- | --- | --- | --- |
| App 内发送 / 重生成 | `ChatService.sendMessage`、`regenerateAtMessage` | 否（用户动作） | 后台继续 ≠ 触发独立 |
| 工具审批回调 | `ChatService.handleToolApproval` | 否（用户动作） | 审批后续跑 |
| 局域网 Web API | `web/routes/ConversationRoutes.kt` | 是（外部请求） | 复用同一 `ChatService` 路径 |
| 媒体创作提交 / 重试 | `MediaCreationService.submit`、`retry` | 否（用户动作） | 提交后脱离当前页面运行 |
| 记忆整理 | 空闲计时、攒轮阈值、切后台、离开会话、启动恢复 | 是（待处理内容源于既有回合，维护独立运行） | 有进行中/结果/错误状态，结果交付到记忆库 |
| 分享 / 翻译意图 | `RouteActivity.handleIntent`、`ui/pages/share/handler/ShareHandlerPage.kt` | 否 | 仅预填输入框，不自动发送 |

Web API 是唯一"不由本机界面发起"的生成入口，其 Ktor 服务与路由细节由 [外部执行体与应用协作笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md) 承担；与本类目相关的是它作为外部触发的唯一通道，以及流式端点用 `addConversationReference` 增加引用计数以免会话被提前回收。

### 运行对象与状态权威

会话运行的权威是内存中的 `ConversationSession`，持有引用计数、生成 Job 状态流、活跃 Job 集合与待发消息队列。`isInUse` 由引用计数、非空 Job、队列非空三者共同决定，会话据此在 5 秒空闲超时后回收（`service/ConversationSession.kt`、`service/ChatService.kt`），因此会话运行对象的生命周期上限就是进程生命周期。持久化形态与"数据侧无生成状态字段"这一事实见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

媒体创作把运行对象落到了数据层：记录状态（准备/排队/运行/下载/成功/失败/取消）与 `taskId` 存在 Room 里，内存只保存运行中的 Job 映射（`service/MediaCreationService.kt`、`data/model/MediaCreation.kt`）。

记忆整理没有持久任务对象，只有"某记忆库下各对话待整理的轮数"与运行状态：待整理轮数从数据库按对话推算，整理结果写进记忆文件与运行历史；进程重启后靠 `resumePending()` 重新发现未整理的对话。

调度上，聊天与媒体创作都是会话/记录内串行而非并发池：`dispatchNextQueuedMessage` 在派发前检查该会话是否已有 Job 或待审批工具，命中任一条件就返回；媒体创作按记录注册 Job，同一记录不会重复运行；记忆整理按记忆库加互斥锁，每次只跑一批。

### 用户日程与系统级定时唤醒的检查范围

以下 API 在全仓 Kotlin 源码中检索后没有命中声明或调用点（已排除 `.agents/`、`.claude/`、`build/`、`generated/` 与第三方原生库）：

| API 类别 | 具体接口 |
| --- | --- |
| 闹钟 | `AlarmManager`、`setExactAndAllowWhileIdle`、`setRepeating`、`setAlarmClock` |
| 作业调度 | `JobScheduler`、`JobService`、`JobInfo` |
| WorkManager | `CoroutineWorker`、`: Worker`、`WorkRequest`、`enqueueUniqueWork` |
| 广播与开机自启 | `BroadcastReceiver`、`registerReceiver`、`PendingIntent.getBroadcast`、`BOOT_COMPLETED` |
| 定时表达式 | `cron`、`heartbeat`（按调度语义计） |

AndroidManifest 中也没有 receiver 声明、没有 `RECEIVE_BOOT_COMPLETED` 权限；服务均返回 `START_NOT_STICKY`。

WorkManager 仍处于"已集成但未接线"的状态：依赖在 `app/build.gradle.kts` 声明，Manifest 移除了 `WorkManagerInitializer` 的默认初始化子节点，`RikkaHubApp.onCreate` 启动 Koin 时调用 `workManagerFactory()`。这套组合通常用于 Worker 依赖注入，而按上述范围检索全仓 Kotlin 源码未找到任何 Worker 实现或工作请求，因此本次调查把它判为预置的初始化接缝。

### 记忆整理：回合后的条件唤醒

`MemoryConsolidationScheduler` 在轮次结束后登记“待整理轮数”，触发条件有四类：空闲计时到点（默认 2 分钟）、累计轮数达到上限（默认 6 轮）、应用切到后台（`onAppHidden`）、用户离开当前会话（`onConversationLeft`）。应用启动时 `resumePending()` 按记忆库重新发现未整理的对话并重启计时器；用户在记忆页手动整理则先处理全部待整理对话再整体清理记忆库（`data/ai/MemoryConsolidationScheduler.kt`）。

调度器维护进行中、最后结果、耗时和错误；计时器到期后调用整理 worker，worker 在独立 Agent 循环中读取既有对话并调用记忆工具写入记录，随后推进已整理位置。自动运行只增改，手动完整整理才提供删除工具。见 [调度与结果状态](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/ai/MemoryConsolidationScheduler.kt#L221-L300)、[模型执行与进度写回](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/ai/MemoryConsolidator.kt#L150-L239)。

约束与边界：

- 同一记忆库按进程内 Mutex 串行，不同记忆库持有不同锁；不据此推断全局只跑一个批次。
- 自动整理失败后不自动重试，避免模型持续出错时反复调用；待整理内容保留到下一轮对话结束或用户手动触发。
- 自动整理要求待整理对象允许自动运行；关闭助手的自动整理后仍登记轮数，但仅手动整理会消费。空闲倒计时可在停止聊天后触发；进程被杀期间没有系统唤醒，重启时按数据库进度重新发现待办。
- 应用不可见时用 `MemoryDreamForegroundService`（`dataSync` 型、通知 ID 2004）保住进程，否则空闲计时可能走不完。

### 悬浮窗：后台生成的可见化

`ChatFloatingTracker` 决定“是否显示、显示哪个会话、是否展开”，窗口本身在 `ui/components/ui/FloatingWindow.kt` 与聊天页渲染。规则是：仅在设置开关打开（`displaySetting.enableFloatingChatWindow`，默认关闭）且应用在后台时工作；切后台时正在生成的会话、以及之后开始生成的会话成为目标，生成结束后继续显示以便直接回复推进，用户关闭后等下一个开始生成的会话；回到前台全部重置（`service/ChatFloatingTracker.kt`）。开关位于通知偏好设置页，打开时会检查悬浮窗权限，无权限时提示授权。

### 定时提醒类功能的实际形态

三个带"提醒"字样的功能都不是调度器：

- **时间提醒**：发送给模型前，`TimeReminderTransformer` 按相邻用户消息的时间间隔（默认阈值 60 分钟）注入一条 `<time_reminder>` 合成消息；它属于输入变换管道的一环，只在生成被触发时执行，不启动任何运行（`data/ai/transformers/TimeReminderTransformer.kt`）。
- **备份提醒**：界面组件用当前时间是否超过“上次备份时间 + 间隔天数”决定是否显示卡片，背后只有 `BackupReminderConfig` 的开关、间隔天数与上次备份时间戳三项配置，功能默认关闭，没有定时器与通知（`data/datastore/PreferencesStore.kt`、`ui/components/ui/BackupReminderCard.kt`）。
- **更新提醒**：检查器把更新状态做成懒加载流，界面订阅时才请求一次，聊天页再按设置里的暂停截止时间决定是否订阅，下载交给系统下载管理器 `DownloadManager`（`utils/UpdateChecker.kt`）。这是快照中唯一由系统托管的异步传输。

## 前台服务与通知

### 四个前台服务

| 服务 | 类型 | 生命周期来源 | 通知 ID |
| --- | --- | --- | --- |
| `ChatGenerationForegroundService` | `dataSync` | 生成期间 acquire/release，活跃生成集合非空即保持前台 | 2002 |
| `MediaCreationForegroundService` | `dataSync` | 媒体创作任务有活动记录时保活 | 2003 |
| `MemoryDreamForegroundService` | `dataSync` | 记忆整理期间保活，`holdId` 引用计数 | 2004 |
| `WebServerService` | `specialUse` | 内嵌 Web 服务器运行期间 | 由服务自行发布 |

四个前台服务都只保活并发布通知，具体业务由各自的调用方承担：聊天生成归 `ChatService`，媒体创作归 `MediaCreationService`，记忆整理归整理调度器。Android 14+ 通过 `ServiceCompat.startForeground` 启动，Manifest 中声明的服务类型与对应权限一致，其中包括 `FOREGROUND_SERVICE_SPECIAL_USE`（`AndroidManifest.xml`）。

### 五个通知渠道

进程启动时在 `RikkaHubApp.kt` 中一次性创建五个通知渠道：

| 渠道 ID | 重要性 | 用途 |
| --- | --- | --- |
| `chat_completed` | HIGH | 生成完成 |
| `chat_live_update` | LOW | 进度与聊天前台服务通知 |
| `web_server` | LOW | 本地 Web 服务 |
| `media_creation` | DEFAULT | 媒体创作 |
| `memory_dream` | LOW | 记忆整理 |

聊天进行中通知有两条来源：前台服务的常驻通知由服务在 `acquire` 时发布，只要生成在跑就存在；带正文的进度更新由 `ChatNotificationManager` 订阅事件后发送，条件是 App 不在前台、`enableLiveUpdateNotification` 开启（默认关闭）并受每会话 1 秒节流限制。两者共用同一通知 ID，不会重复出现。完成通知在生成结束（完成、失败或取消）时触发，要求预览非空、App 不在前台、总开关开启三者同时满足。

媒体创作通知由 `MediaCreationService` 与前台服务发布：进行中显示任务进度，完成后可点按直达对应会话（`RouteActivity` 读取通知里的会话 id）。记忆整理通知只在前台服务保活时出现，标题为“正在整理记忆”。

### 结果如何交付

聊天生成的对外交付面为会话数据库（始终）、Web API 的 SSE 流（客户端订阅时）、系统通知（默认关闭且需 App 不在前台）与悬浮窗（默认关闭且需权限）。落库由 chunk 增量更新加整轮收尾兜底完成；标题与建议生成不获取前台服务，主生成释放后可能在无前台保护下运行。

媒体创作的交付面是 Room 记录 + 本地文件 + 通知。记忆整理的交付面是记忆库文件与运行结果（改动文件清单、耗时、错误），记忆页可查看状态与手动触发。

## 并发、取消、失败与恢复

同一会话严格串行：生成期间进入的第二条消息留在队列等待，结束后由回调再触发派发，而不是取消当前运行；取消只发生在显式重生成与工具审批这两条成对 join 的路径上（`ChatService.kt`）。仓库文档“sendMessage 会取消上一个 Job”的描述与排队实现不符。

前台服务超时是另一条取消入口：`onTimeout` 把活跃生成集合里的会话逐个停止再停服务，把 Android 对 `dataSync` 型前台服务的时长上限转成了对生成时长的硬约束。失败会暂停消息队列并要求用户显式恢复，网络类失败另有默认开启的 `IOException` 自动重试；这些请求侧细节见 [对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。

媒体创作的取消只停止本地等待：已提交给服务端的任务无法撤回，`taskId` 保留，之后可重试接着查询；删除会话会级联删除记录，媒体文件的删除逻辑在仓储与服务内（`MediaCreationService.kt`、`MediaCreationRepository.kt`）。

**重启与恢复**：聊天生成没有恢复机制——生成状态、队列、Job 全在内存，进程死亡等价于该次后台运行静默终止，重启后只能看到已落库的部分消息。媒体创作与记忆整理有各自的启动恢复：前者 `resumePending()` 对带 `taskId` 的记录重新轮询，后者 `resumePending()` 从数据库重建待整理列表。启动期另有备份恢复、临时目录清理与文件同步等一次性维护动作，不构成可识别的重复运行对象（`RikkaHubApp.kt`）。

## 相邻类目交接与已确认边界

- **对话请求与上下文**：提交入口、Agent 循环、流式节流与停止/重试/续写、队列与会话回收均由该类目承担，本笔记只引用其对后台生命周期的影响。
- **外部执行体与应用协作**：Ktor 服务的启动、端口、JWT 与路由由该类目承担；Web 服务是唯一不依赖本机界面的生成触发与观察通道，并与前台服务共享同一进程与 `ChatService`。
- **会话与消息管理**：运行对象即会话级生成 Job，结果写回会话消息树；数据侧不存在生成状态字段，可见性依赖会话是否仍被引用。
- **Agent 工具与记忆**：工具循环与审批属于 Agent 工具类目；记忆侧包含回合内工具 CRUD 与回合后后台整理，整理本身由调度器驱动、用模型调用完成，涉及的文件模型与写入规则归 [检索增强与认知编排笔记](../检索增强与认知编排/RikkaHub-检索增强与认知编排调查笔记.md)。
- **媒体创作**：媒体生成的任务状态机、轮询、下载与恢复由 [媒体创作笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md) 承担，本笔记只记录它的前台服务与后台生命周期。

## 未验证事项

- Android 12+ 后台启动前台服务受限时，`acquire` 的异常会被 `runCatching` 吞掉并返回 false；此时生成是否继续但失去前台保护，属结构推断，未在真机验证。
- 前台服务 `dataSync` 超时（`onTimeout`）与生成期间进程被回收时，用户可观察到的最终状态未确认。
- 记忆整理的实际触发时序与数据库轮数统计在真实使用中的误差（空闲计时、攒轮阈值、切后台三条路径的竞争），未运行验证。
- 悬浮窗在无悬浮窗权限、系统限制后台弹窗（如国产 ROM）与多任务切换下的行为，未在设备上验证。
- 媒体创作任务在应用被杀后凭 `taskId` 恢复的成功率与厂商任务过期时间，未验证。
- App 不在前台时由 Web API 请求触发的生成能否正常进入前台服务、通知是否符合预期，未运行验证。
- Live Update 通知的 1 秒节流在高频 chunk 下的实际投递效果未验证。

## 关键源码索引

- 启动、通知渠道与 WorkManager/Koin 初始化：`app/src/main/java/me/rerere/rikkahub/RikkaHubApp.kt`
- 前台服务与权限声明：`app/src/main/AndroidManifest.xml`
- 四个前台服务：`app/src/main/java/me/rerere/rikkahub/service/`（`ChatGenerationForegroundService.kt`、`MediaCreationForegroundService.kt`、`MemoryDreamForegroundService.kt`、`WebServerService.kt`）
- 生成 Job 派发、取消、后台保活与状态写回：`service/ChatService.kt`；运行对象与队列：`service/ConversationSession.kt`、`service/MessageQueue.kt`
- 通知：`service/ChatNotificationManager.kt`、`service/MediaCreationService.kt`
- 悬浮窗：`service/ChatFloatingTracker.kt`、`ui/components/ui/FloatingWindow.kt`、`ui/pages/setting/SettingPreferencesNotificationPage.kt`（开关与权限引导）
- 记忆整理调度：`data/ai/MemoryConsolidationScheduler.kt`、`data/ai/MemoryConsolidator.kt`
- 媒体创作后台执行：`service/MediaCreationService.kt`、`data/repository/MediaCreationRepository.kt`
- 设置项（通知开关、自动重试、备份提醒、悬浮窗）：`data/datastore/Settings.kt`、`data/datastore/PreferencesStore.kt`
- 提醒类功能的实际形态：`data/ai/transformers/TimeReminderTransformer.kt`、`ui/components/ui/BackupReminderCard.kt`、`utils/UpdateChecker.kt`
