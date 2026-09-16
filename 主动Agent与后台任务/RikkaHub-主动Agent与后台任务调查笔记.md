# RikkaHub 主动Agent与后台任务调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9a35e3f2f1e2820e95c37deb82ef8f5e1592e06f`（分支：`master`）
>
> 调查方式：只读复查 `AndroidManifest.xml`、`app/src/main/java/me/rerere/rikkahub/service/` 全部服务与通知实现、`data/sync/`、`web/` 嵌入服务、`videogen/` 模块及 DataStore 设置定义；对全仓 Kotlin 源码检索 `WorkManager`、`AlarmManager`、`JobScheduler`、`BroadcastReceiver`、`CoroutineWorker`、`WorkRequest` 等调度 API 的声明与调用点；并对照仓库自带的 `docs/references/chat-generation-pipeline.md`。未修改被调查项目。
>
> 调查范围：本类目聚焦"可在当前用户回合之外被触发并以独立运行状态完成/失败/取消"的工作单元。覆盖：生成过程中 App 退到后台的行为、前台服务与通知渠道、生成 Job 的调度/取消/恢复、是否存在 WorkManager/AlarmManager/广播等后台入口、以及"定时提醒"类功能的实际形态。不展开：消息生成管线内部的 Transformer 细节、Agent 工具权限模型、MCP/Workspace/Skill 的工具语义、WebDAV/S3 备份协议与图片生成页面。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是原生 Android 的 LLM 聊天客户端。就本类目的窗口期定义（触发不依赖当前用户即时发送的一条消息、有可识别的运行对象、结果交付到可识别目标）而言，本次未找到任何定时或周期性的主动运行：cron、heartbeat、WorkManager 的 Worker 与入队调用、AlarmManager、JobScheduler、广播接收器均无命中。检索范围与依据见下文"主动调度不存在的排除证明"。

本快照中真正属于本类目的对象是**会话级后台生成运行**：由用户动作或外部 HTTP 请求发起，运行期间由一个 `dataSync` 前台服务把进程钉在前台，使流式生成在 Activity 退到后台后继续；结果写入会话数据库，并可在 App 不在前台时投递系统通知。运行对象与状态权威都在内存中，进程结束即失效，没有补跑或恢复机制。

分型上它更接近"会话内续作"叠加一个进程内的串行工作队列，而非"隔离日程运行"或"条件唤醒"：每个会话有一个待发消息队列，生成 Job 只能串行推进；触发者只有三类且都需人工或外部请求介入——App 内发送/重生成、工具审批回调、局域网 Web API 请求，没有模型或系统条件自发启动的运行。另需区分：时间提醒是发送前的提示词注入，备份提醒与更新检查只在界面呈现且不投递通知，视频生成模块虽有任务状态机但 `app` 未引用。

## 系统边界与主链

本类目的对象是"退到后台仍继续、并以独立 Job 生命周期收尾"的生成运行。权威状态分两层：消息与分支结构持久化在 Room；"是否正在生成""当前 Job 是什么""队列里还有什么"只存在于进程内存中。

```text
触发（App 内发送/重生成、工具审批回调，或 Web API 三类端点）
  -> ChatService 把输入放入该会话的 MessageQueue 串行派发
  -> launchGenerationJob 先 acquire 前台服务（dataSync）再启动生成协程
  -> GenerationLoop 流式生成；onSuccess 落库，finally release 服务
```

请求侧的提交入口、生成循环、流式事件与停止/重试/续写等机制由 [对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md) 承担。运行期另有两个进程级支点：绑定 Application 的 `AppScope` 协程作用域，以及注册为 Koin 单例的事件订阅者 `ChatNotificationManager`（`di/AppModule.kt:70-79`）。

## 触发、调度与运行对象

### 触发来源

四类触发都必须有人或外部系统发起，未发现模型或系统条件自发启动的路径：

| 触发来源 | 入口 | 是否独立于当前回合 | 备注 |
| --- | --- | --- | --- |
| App 内发送 / 重生成 | `ChatService.sendMessage`、`regenerateAtMessage`（`service/ChatService.kt:405-413,530-574`） | 否（用户动作） | 后台继续 ≠ 触发独立 |
| 工具审批回调 | `ChatService.handleToolApproval`（`:578-654`） | 否（用户动作） | 审批后续跑 |
| 局域网 Web API | `web/routes/ConversationRoutes.kt:271-286,336-348,358-363` | 是（外部请求） | 复用同一 `ChatService` 路径 |
| 分享 / 翻译意图 | `RouteActivity.handleIntent`、`ui/pages/share/handler/ShareHandlerPage.kt` | 否 | 仅预填输入框，不自动发送 |

Web API 是唯一"不由本机界面发起"的生成入口，其 Ktor 服务与路由细节由 [外部执行体与应用协作笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md) 承担；与本类目相关的是它作为外部触发的唯一通道，以及流式端点用 `addConversationReference` 增加引用计数以免会话被提前回收。

### 运行对象与状态权威

运行对象的权威是内存中的 `ConversationSession`，持有引用计数、生成 Job 状态流、活跃 Job 集合与待发消息队列。`isInUse` 由引用计数、非空 Job、队列非空三者共同决定，会话据此在 5 秒空闲超时后回收（`service/ConversationSession.kt:19-56,114-127`；`service/ChatService.kt:211-250`），因此运行对象的生命周期上限就是进程生命周期。持久化形态与"数据侧无生成状态字段"这一事实见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

调度上是会话内串行而非并发池：`dispatchNextQueuedMessage` 在派发前检查该会话是否已有 Job 或待审批工具，命中任一条件就返回（`ChatService.kt:434-445`）；会话之间互不阻塞。

### 主动调度不存在的排除证明

以下 API 在全仓 Kotlin 源码中检索后没有命中声明或调用点（已排除 `.agents/`、`.claude/`、`build/`、`generated/` 与第三方原生库）：

- `AlarmManager`、`setExactAndAllowWhileIdle`、`setRepeating`、`setAlarmClock`
- `JobScheduler`、`JobService`、`JobInfo`
- `CoroutineWorker`、`: Worker`、`WorkRequest`、`enqueueUniqueWork`
- `BroadcastReceiver`、`registerReceiver`、`PendingIntent.getBroadcast`、`BOOT_COMPLETED`
- 定时表达式相关标识（`cron`、`heartbeat` 作为调度语义时）

AndroidManifest 中也没有 receiver 声明、没有 `RECEIVE_BOOT_COMPLETED` 权限；两个 Service 都返回 `START_NOT_STICKY`（`service/ChatGenerationForegroundService.kt:79`、`service/WebServerService.kt:52,86`）。

WorkManager 处于"已集成但未接线"的状态：依赖在 `app/build.gradle.kts:147,190` 声明，Manifest 移除了 `WorkManagerInitializer` 的默认初始化子节点（`AndroidManifest.xml:153-162`），`RikkaHubApp.onCreate` 启动 Koin 时调用 `workManagerFactory()`（`RikkaHubApp.kt:70-75`）。这套组合通常用于 Worker 依赖注入，但快照中不存在任何 Worker 实现或工作请求，只能结论为预置的初始化接缝；此为"本次未找到"，不等于项目永不具备该能力。

### 定时提醒类功能的实际形态

三个带"提醒"字样的功能都不是调度器：

- **时间提醒**：发送给模型前，按相邻用户消息的时间间隔（默认阈值 60 分钟）注入 `<time_reminder>` 合成消息；它是输入变换管道的一环，只在生成被触发时执行，不触发任何运行（`data/ai/transformers/TimeReminderTransformer.kt:19-59`）。
- **备份提醒**（`BackupReminderConfig`）：只有开关、间隔天数与上次备份时间戳三个配置项，默认关闭；界面组件用当前时间是否超过"上次备份 + 间隔"决定是否显示卡片（`data/datastore/PreferencesStore.kt:657-662`、`ui/components/ui/BackupReminderCard.kt:34-40`）。没有定时器与通知，备份创建只由备份页面的用户操作调用（`ui/pages/backup/BackupVM.kt:84,212`）。
- **更新提醒**：`stateIn(SharingStarted.Lazily)` 的懒加载流，只有被界面订阅时才请求一次，聊天页按设置中的暂停截止时间决定是否订阅（`utils/UpdateChecker.kt:24-65`、`ui/pages/chat/ChatVM.kt:186-199`）；下载交给系统 `DownloadManager`（`UpdateChecker.kt:67-90`），这是快照中唯一由系统托管的异步传输。

## 前台服务保活与结果交付

### 前台服务如何钉住生成

`launchGenerationJob` 用包装协程实现"生成期间保持前台"：进入时生成 `generationId`，调用 `ChatGenerationForegroundService.acquire` 启动前台服务并传入会话 ID，`finally` 中按同一 ID release（`ChatService.kt:304-326`）。服务不拥有生成逻辑，只维护"活跃生成集合"，集合非空就保持前台通知，清空后 `stopSelf`（`service/ChatGenerationForegroundService.kt:105-119,142-148`）。Android 14+ 走 `ServiceCompat.startForeground` 并声明 `FOREGROUND_SERVICE_TYPE_DATA_SYNC`，Manifest 中类型与权限一致（`:121-140`、`AndroidManifest.xml:15-16,121-124`）。

### 两类通知

进程启动时创建三个渠道：`chat_completed`（HIGH，生成完成）、`chat_live_update`（LOW，进度与前台服务通知）、`web_server`（LOW，本地 Web 服务）（`RikkaHubApp.kt:51-53,212-241`）。

进行中通知有两条来源。前台服务的常驻通知由服务在 `acquire` 时发布，只要生成在跑就存在，与 App 是否在前台无关（`ChatGenerationForegroundService.kt:150-159`）；带正文的进度更新由 `ChatNotificationManager` 订阅事件后发送，条件是 App 不在前台、`enableLiveUpdateNotification` 开启（默认关闭）并受每会话 1 秒节流限制（`service/ChatNotificationManager.kt:32,71-83,112-136`）。两者共用同一通知 ID（`NOTIFICATION_ID = 2002`），不会重复出现。

完成通知在生成结束（完成、失败或取消）时触发：管理器先取消进度通知，再要求预览非空、App 不在前台、总开关开启三者同时满足才投递，点击经 `PendingIntent` 打开对应会话；总开关默认关闭，因此默认不出现（`ChatNotificationManager.kt:85-110,187-198`）。

### 结果如何交付

对外交付面为会话数据库（始终）、Web API 的 SSE 流（客户端订阅时）与系统通知（默认关闭且需 App 不在前台）。落库由 chunk 增量更新加 `onCompletion` 兜底完成；随后的标题与建议生成不获取前台服务，若主生成已释放服务就在无前台保护下运行（`ChatService.kt:748-756,767-783,794-804`）。

## 并发、取消、失败与恢复

同一会话严格串行：生成期间进入的第二条消息留在队列等待，结束后由回调再触发派发，而不是取消当前运行；取消只发生在显式重生成与工具审批这两条成对 join 的路径上（`ChatService.kt:222-231`）。仓库文档"sendMessage 会取消上一个 Job"的描述与排队实现不符。

前台服务超时是另一条取消入口：`onTimeout` 把活跃生成集合里的会话逐个停止再停服务，把 Android 对 `dataSync` 型前台服务的时长上限转成了对生成时长的硬约束（`ChatGenerationForegroundService.kt:91-103`）。失败会暂停消息队列并要求用户显式恢复，网络类失败另有默认开启的 `IOException` 自动重试；这些请求侧细节见 [对话请求与上下文笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。

**重启与恢复**：没有恢复机制。生成状态、队列、Job 全在内存；消息虽随 chunk 渐进落库，但没有启动时"发现未完成运行并继续/补跑"的逻辑，`ChatService.cleanup()` 也无外部调用点。两个 Service 均为 `START_NOT_STICKY`（见上文），被杀后不会重建，因此进程死亡等价于该次后台运行静默终止，重启后只能看到已落库的部分消息。启动期另有备份恢复、临时目录清理与文件同步等一次性维护动作，不构成可识别的重复运行对象（`RikkaHubApp.kt:58-103,164-210`）。

## 相邻类目交接与已确认边界

- **对话请求与上下文**：提交入口、任务状态机、生成循环、流式节流与停止/重试/续写、队列与会话回收均由该类目承担，本笔记只引用其对后台生命周期的影响。
- **外部执行体与应用协作**：Ktor 服务的启动、端口、JWT 与路由由该类目承担；Web 服务是唯一不依赖本机界面的生成触发与观察通道，并与前台服务共享同一进程与 `ChatService`。
- **会话与消息管理**：运行对象即会话级生成 Job，结果写回会话消息树；数据侧不存在生成状态字段，可见性依赖会话是否仍被引用。
- **Agent 工具与记忆**：工具循环与审批属于 Agent 工具类目，本笔记只记录"审批把一次生成拆成两段独立 Job"这一生命周期影响；记忆是回合内由模型增删改的普通 CRUD 仓储（`data/repository/MemoryRepository.kt`），没有后台整理或抽取运行。
- **视频生成模块**：`videogen` 只做供应商协议适配，不负责持久化任务、下载视频与 UI 状态；`app` 模块依赖它但无调用点，异步任务模型与轮询 Flow 尚未接线（`videogen/README.md:13`）。

## 未验证事项

- Android 12+ 后台启动前台服务受限时，`acquire` 的异常会被 `runCatching` 吞掉并返回 false；此时生成是否继续但失去前台保护，属结构推断，未在真机验证。
- 前台服务 `dataSync` 超时（`onTimeout`）与生成期间进程被回收时，用户可观察到的最终状态未确认。
- App 不在前台时由 Web API 请求触发的生成能否正常进入前台服务、通知是否符合预期，未运行验证。
- Live Update 通知的 1 秒节流在高频 chunk 下的实际投递效果未验证；仓库文档的两处差异（`GenerationHandler` 类名、sendMessage 取消语义）对应的版本也未确认。

## 关键源码索引

- 启动、通知渠道与 WorkManager/Koin 初始化：`app/src/main/java/me/rerere/rikkahub/RikkaHubApp.kt:51-53,58-103,164-241`
- 前台服务与通知渠道声明：`app/src/main/AndroidManifest.xml:15-16,121-132,153-162`
- 生成期前台服务（acquire/release、活跃生成集合、超时）：`app/src/main/java/me/rerere/rikkahub/service/ChatGenerationForegroundService.kt:37-159`
- 生成 Job 派发、取消与状态写回：`service/ChatService.kt:211-250,304-326,434-445,748-804,1418-1427`
- 运行对象与队列：`service/ConversationSession.kt:19-135`、`service/MessageQueue.kt:21-118`、`service/ChatNotificationManager.kt:32-198`
- 设置项（通知开关、自动重试、备份提醒）：`data/datastore/PreferencesStore.kt:582,657-662`
- 提醒类功能的实际形态：`data/ai/transformers/TimeReminderTransformer.kt:19-59`、`ui/components/ui/BackupReminderCard.kt:34-40`、`utils/UpdateChecker.kt:24-90`
- 未接线的异步视频任务模型：`videogen/src/main/java/me/rerere/videogen/`（`provider/VideoGenerationManager.kt:35-47`、`model/VideoGeneration.kt:105-139`）
