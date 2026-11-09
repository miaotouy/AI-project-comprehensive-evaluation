# VCPChat 对话请求与上下文调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对与旧笔记刷新；原文自 [`../Chat/VCPChat-Chat调查笔记.md`](../Chat/VCPChat-Chat调查笔记.md) 迁移，并重新核对聊天流事件契约、发送/中断链路与 chatHandlers 当前实现
>
> 调查范围：一次生成任务的提交与中断入口、群聊调度与发言顺序、流式消费与超时、终态事件与回写、话题自动总结请求；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 的单聊请求由渲染侧统一组装器编成消息后，经 `send-to-vcp` 直连 VCP 服务器（`fetch(vcpServerUrl)`）；群聊由主进程 `groupchat.js` 编排多 Agent 串行发言。

- **单聊中止按钮已接上本地兜底**：`interrupt-vcp-request` 给远端 `/v1/interrupt` 请求加了 5 秒超时；上游拒绝或超时后，`finally` 分支用 `vcpStreamTasks.cancel(..., 'interrupt-local-fallback')` 关掉本次流的本地读取，因此按钮不再只依赖远端停流。上游正常受理时仍由上游发送终态（第 7 节）。`modules/ipc/chatHandlers.js:1561-1614`
- **主发送 fetch 仍无客户端超时**：`send-to-vcp` 只绑 sender 生命周期 signal，窗口存活且远端挂死时该请求会一直等待。`modules/ipc/chatHandlers.js:1369,1544-1560`
- 群聊超时改为分阶段弹性：等待响应头 120 秒、块间空闲 62 秒；工具审批挂起期间看门狗只续期不熔断。`Groupmodules/groupchat.js:1247-1362`、`Groupmodules/streamWatchdog.js:1-40`
- 流事件有七个名称和四种终态。契约只将 `completed` 标记为 durable，但实际写入判断允许失败与取消的部分结果落库，只有 discarded 跳过；该标记不能当作持久化白名单。终态先完成投影、释放发送状态，再提交历史；保存失败留下 `unsaved` 状态。依据：[事件声明](../../VCPChat/modules/chat/chatEventContract.js#L10-L18)、[实际持久化条件](../../VCPChat/modules/chat/streamCoordinator.js#L164-L189)、[终态消费](../../VCPChat/modules/renderer/mainChatStreamConsumer.js#L79-L125)。
- 话题自动总结的超时保护仍不对称：单聊 `topicSummarizer.js` 无超时，群聊 `topicTitleManager.js` 有明确 20 秒超时（第 3 节）。
- 群聊在同一 `handleGroupChatMessage` 调用内部严格串行（杜绝 chunk 交错），但多次调用之间无锁，写盘并发风险的数据语义见会话与消息管理笔记 6.1（第 8 节）。

## 系统边界与生成任务主链

```text
mainChatSendOwner 发送/中止按钮
  -> chatManager.handleSendMessage（单聊）或 groupChat.handleGroupChatMessage（群聊）
  -> 单聊：chatContextPipeline 组装消息 -> IPC send-to-vcp -> SenderTaskRegistry signal -> fetch(finalVcpUrl)
     -> 流事件按 chat.stream.* 契约回渲染进程 -> mainChatStreamConsumer 消费终态
  -> 群聊：主进程逐 agent 串行 fetch（TTFT 120 秒、块间空闲 62 秒、审批挂起时续期）
  -> 终态：projectTerminal 先做乐观投影并撤销流所有权 -> persistTerminal 提交历史 -> afterPersist 处理话题摘要等副作用
  -> 落盘：services.historyPersistence.commit(projected)；群聊由 groupchat.js 直接写 groupHistory
  -> 中断：群聊 controller.abort() + 远端 /v1/interrupt；单聊远端 5 秒超时，失败则本地取消流任务
```

边界：会话与消息如何持久化、写盘并发语义属于会话与消息管理（[`../会话与消息管理/VCPChat-会话与消息管理调查笔记.md`](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)）；发送/停止按钮状态、toast 反馈等界面工作流属于 Chat UI（[`<../Chat UI/VCPChat-ChatUI调查笔记.md>`](<../Chat UI/VCPChat-ChatUI调查笔记.md>)）；流式 DOM 更新与内容渲染属于消息渲染器（[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md)）。VCPChat 是 VCPToolBox 的官方桌面前端，其消息结构与 VCPToolBox 请求编排的对应关系见 [`../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)。

## 1. 提交入口、任务对象与状态机

- 单聊发送入口由 `chatManager` 调用 `singleChatRequestOrchestrator`，后者只做三件事：`buildRequest`（转调统一组装器）、`sendPrepared`（调用 `sendToVCP`）、`send`。消息编译主体在 `modules/chat/chatContextPipeline.js`。`modules/chat/singleChatRequestOrchestrator.js:7-40`、`modules/chat/chatContextPipeline.js:319-417`
- 发送/中止按钮的状态与分支集中在新模块 `mainChatSendOwner`：按钮模式在 `send` 与 `interrupt` 间切换，中止时群聊走 `chatAPI.interruptGroupRequest`，单聊走 `interruptHandler.interrupt`。`modules/renderer/mainChatSendOwner.js:74-121`
- 任务标识：单聊以 `messageId` 为任务引用（中断请求体 `{requestId: messageId}`）；群聊以 `messageIdForAgentResponse` 为 key 登记 `activeRequestControllers`。`modules/ipc/chatHandlers.js:1588-1590`、`Groupmodules/groupchat.js:42-92`
- 流事件名与终态是显式契约：`chat.stream.started/chunk/final` 非终态，`chat.stream.completed/failed/cancelled/discarded` 为终态，其中只有 `completed` 的 `durable` 为真；`normalizeChatTerminal` 把 `end/done/stop` 归一为 completed、`abort/cancel` 归一为 cancelled、`discard/stale` 归一为 discarded、`error/disconnect` 归一为 failed。`modules/chat/chatEventContract.js:10-34`

## 2. 历史选择与上下文拼装顺序

- 群聊：循环体内每个 agent 的上下文构建先按窗口配置截取最近 N 条（默认关闭，窗口 100、范围 1–10000），再基于**同一个内存变量 `groupHistory`** 的当前状态构建，而不是每次重新读盘。因此后发言的 agent 能看到前一个 agent 刚说的话（数据写入语义见会话与消息管理笔记 6.1）。`Groupmodules/groupContextWindow.js:11-39`、`Groupmodules/groupchat.js:972-975`
- 群聊系统提示词现在还会展开两类占位符：`{{VCPChatGroupSessionWatcher}}` 由主进程填入群会话监视信息，`{{VCPChatWorkSpace…}}` 按工作区索引展开为目录树，`{{VCPChatCanvas}}` 在当前用户消息里替换为最新画布内容。`Groupmodules/groupchat.js:44-60,953-1008`
- 单聊上下文顺序已集中到统一组装器：先解析会话快照与 Tavern 规则，从最近压缩检查点起截取历史并过滤 `isThinking`；逐消息构建附件 content parts 与文本变换，仅对当前用户消息应用 user suffix；随后展开 `{{AgentName}}` 与 `{{VCPChatWorkSpace…}}`，合成 system prompt 并应用 system suffix，最后插入 context inject。客户端组装器未执行 token 预算裁剪。`modules/chat/chatContextPipeline.js:319-417`

## 3. 预算、截断、摘要与压缩

摘要类能力有两条路径，超时保护不同；此外上下文压缩检查点提供了另一种“截断”手段。

### 3.1 单聊路径：无超时保护

`chatManager.js` 的 `attemptTopicSummarizationIfNeeded()`（`modules/chatManager.js:1491-1540`），触发时机是单聊流终态收尾且该消息属于当前可见视图时，然后在消息落盘后的 `afterPersist` 副作用里被调用。

- 触发条件：当前选中项类型是 agent、历史至少两轮对话（`currentChatHistory.length >= 4`）、且存在 `currentTopicId`；重新从磁盘拉取最新 agent 配置后，仅当 topic 名是默认名（`name === "主要对话"` 或以 `"新话题"` 开头）才调用 `messageRenderer.summarizeTopicFromMessages` 请求 AI 总结，成功后 `electronAPI.saveAgentTopicTitle` 落盘。`modules/chatManager.js:1491-1538`
- `modules/topicSummarizer.js` 的 `summarizeTopicFromMessages` 直接对 VCP 服务器发起 fetch（`:44`），没有 `AbortController`，也没有 `setTimeout` 兜底。服务器不响应时这个 `await fetch` 会一直挂着，没有机制探测或中止。

### 3.2 群聊路径：20 秒超时

`Groupmodules/topicTitleManager.js` 的 `generateTitleFromAI`（`:81-130`），**有明确的 20 秒超时**：创建 `AbortController` 并 `setTimeout(() => controller.abort(), 20000)`（`:92`），`finally` 里清理定时器。触发条件在 `triggerSummarizationIfNeeded`（`:184-210`）：

- `groupHistory.length >= MIN_MESSAGES_FOR_SUMMARY(=4)`，且当前话题名是默认名集合（`DEFAULT_TOPIC_NAMES = ["主要群聊"]`）中的一个，或以 `"新话题"` 开头（`:8-9`, `:193`）；
- 清洗逻辑 `cleanSummarizedTitle` 去掉标点、数字编号、常见前后缀，截断到 15 字符；清洗后为空则回退 `"AI总结话题"` 常量，且最终标题等于该回退值或与原标题相同时**不会**写回，避免把占位字符串当真标题存进配置（`:200-215`）。

### 3.3 上下文压缩检查点

压缩为单聊专用的旁路请求，需显式启用并配置压缩模型。入口包括手动压缩、发送前自动检查和 FlowLock 续写前检查。发送前阈值是 Agent 上下文上限的 85%；本地估算按非 ASCII 字符 1、其余字符 0.3 累加，并包含有效历史的 JSON、系统提示词与待发送文本。这是近似估算，未使用模型 tokenizer，也未覆盖随后读取的附件正文与所有后置注入。仅有一条检查点时跳过自动再压缩，避免无限压缩同一摘要。依据：[压缩预算判断](../../VCPChat/modules/chat/contextCompactionService.js#L6-L22)、[发送前入口](../../VCPChat/modules/chatManager.js#L1640-L1657)。

流中另有一次工具返回边界检查：消费到独立行 `<<<[END_ROLE_DIVIDE_USER]>>>` 后，用已接收回复重新估算；达到上下文上限时暂停 FlowLock，经普通中止通道结束当前生成，先保存半截回复，再读取历史并压缩。成功后仅在原话题仍可见且没有 FlowLock 锁定时自动接续。它按工具返回边界触发，并非逐 token 强制预算。依据：[边界消费](../../VCPChat/modules/renderer/mainChatStreamConsumer.js#L51-L61)、[中止、压缩与接续](../../VCPChat/modules/chatManager.js#L45-L136)。

压缩请求把最近检查点及其后新增历史作为独立消息发送；历史 system/developer 角色降为带原角色说明的 user 数据，日记由宿主提取并保留最新版本。请求固定非流式，并把 `/chatvcp/completions` 改为 `/chat/completions`，避免历史工具请求进入执行入口。检查点接受非空文本或纯文本 parts；标识符保真和未决项连续性审计只形成元数据与警告，不阻止落库，模型输出也无需严格匹配 XML 标签。依据：[压缩请求](../../VCPChat/modules/chat/contextCompactionService.js#L24-L57)、[消息与检查点构建](../../VCPChat/modules/chat/contextCompactionPrompts.js#L66-L152)、[正文校验](../../VCPChat/modules/chat/contextCompactionState.js#L197-L207)。

运行状态按话题保存在内存 Map，默认 180 秒超时；中止会立即 abort 本地请求，同时尽力调用远端中断。提交前先比较当前完整历史与启动快照，历史变化即拒绝结果；进入持久化交接后不再接受取消。成功是在历史末尾追加带版本元数据的 user 检查点，旧消息仍完整保留。后续请求从最新有效检查点起读取，其后的新增消息自然跟随；本实现没有额外保留固定尾部窗口。检查点元数据在主进程发送前剥离。

FlowLock 在压缩时暂停心跳并保留锁，只有持久化成功才按 Session 身份与 generation 恢复；取消、超时或失败后保持挂起。依据：[取消与提交](../../VCPChat/modules/chat/contextCompactionService.js#L75-L168)、[有效历史选择](../../VCPChat/modules/chat/contextCompactionState.js#L6-L25)、[心流暂停租约](../../VCPChat/Flowlockmodules/flowlock.js#L490-L520)。

总结结果写入 `topics[]` 元数据的数据语义见会话与消息管理笔记 2.3。

## 4. SDK、Provider、模型与协议交接

- 单聊请求在 `send-to-vcp` handler 内读取服务器地址与 API key，并直接 fetch，没有 Provider SDK 或 Adapter 层。发送前清理未设置参数、剥离思维链、按配置净化上下文并附加 `vcpchatExtensions`（逐条消息时间戳绑定 + sha256 摘要 + `requestContext`）；fetch 使用窗口生命周期任务的 signal。`modules/ipc/chatHandlers.js:74-153,1056-1360`
- 群聊：主进程按 agent 逐个发起 fetch，超时由分阶段定时器治理（见第 5 节）；群聊 assistant 消息记录 `model/modelSource`（`'group_unified'` 或 `'agent'`），说明请求携带的模型标识同时落盘为消息字段。`Groupmodules/groupchat.js:1452,1461`
- 渲染进程的聊天能力入口为 `preloads/api/chat.js`，preload 侧按窗口角色暴露 `chatAPI`/`utilityAPI`/`desktopAPI`。

## 5. 流式事件、缓冲、节流与顺序

- 单聊流式消费拿到 reader 后一直读取到终态、连接关闭、窗口生命周期取消或网络错误。主发送 fetch 没有客户端超时；窗口保持存活且远端挂死时仍可能无限等待（中断按钮的 5 秒超时只作用于中断请求本身）。`modules/ipc/chatHandlers.js:1056-1360`
- 流事件链：主进程把 chunk 作为流事件发回渲染进程，渲染侧由 `mainChatStreamConsumer` 归一化 chunk 并按终态类型分派；缓冲队列、30 FPS 合帧与 DOM 投影属于消息渲染器笔记（[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 第 6 节）。`modules/chat/contentRuntime.js`、`modules/renderer/mainChatStreamConsumer.js:35-78`
- 群聊流式改为分阶段弹性超时：等待响应头 120 秒（`GROUP_TTFT_TIMEOUT_MS`），收到响应后切换为块间空闲 62 秒（`GROUP_CHUNK_IDLE_TIMEOUT_MS`），超时以 `controller.abort('ttft_timeout'|'chunk_idle_timeout')` 熔断并在收尾文本里附看门狗说明。`Groupmodules/groupchat.js:1247-1362,1451`
- 工具审批挂起会暂停块间看门狗：`streamWatchdog` 记录待审批 requestId 与 maid，审批未回应期间该助手的空闲计时只续期；超过 15 分钟的记录会被清理，避免把“正在等用户点允许”误判为僵死。`Groupmodules/streamWatchdog.js:1-40`、`Groupmodules/groupchat.js:1451`

## 6. 完成、异常、半截流与最终回写

终态统一走 `mainChatStreamConsumer`，它把事件分成投影、渲染与持久化三段：

- `consume(event)` 判定终态（`completed`/`failed`/`cancelled`/`discarded`），先把终态分派给 Rendering（`dispatchTerminal`/`renderError`），再让投影 `settle`。流式错误文本以 `[!WARNING]` 追加“已保存已接收的部分内容”。`modules/renderer/mainChatStreamConsumer.js:45-78,87-89`
- 单聊分块累积时还会检查工具返回边界 `<<<[END_ROLE_DIVIDE_USER]>>>`，命中后异步触发上下文压缩边界检查，不阻塞流。`modules/renderer/mainChatStreamConsumer.js:51-62`
- `persist(value)` 先取 `outcome.persistence.value` 作为已落盘结果，再走 `projectTerminal` 做乐观 DOM 投影并撤销流所有权；随后 `persistTerminal` 提交历史，状态机依次为 `saving`→`saved`/`unsaved`，失败时保留可诊断的未保存状态并继续抛出。`modules/renderer/mainChatStreamConsumer.js:79-126`
- 历史提交落在 `services.historyPersistence.commit(projected)`；该 provider 负责读取当前历史、合并被投影的终态消息并写回仓库，临时上下文（`assistant_chat`）与群聊消息直接跳过。`modules/renderer/mainChatSurfaceAdapter.js:17-20`、`modules/chat/chatHistoryPersistence.js:12-42`
- 落盘成功后才执行 `afterPersist` 副作用（话题摘要等），副作用失败只记日志，不影响已提交的历史。`modules/renderer/mainChatStreamConsumer.js:120-124`、`modules/renderer/mainChatSurfaceAdapter.js:49-56`
- 群聊侧 `AbortError` 分支把已累积的响应连同 `interrupted:true` 写进 `groupHistory` 并发终态事件，即中断会停止本地流读取并落盘已生成部分。`Groupmodules/groupchat.js:1451-1481`

## 7. 停止、重试、续写与重新生成

### 7.1 中断请求的实际执行路径

按钮分支集中在 `mainChatSendOwner`：有可中断消息时走 `interrupt` 分支，群聊调用 `interruptGroupRequest`，单聊调用 `interruptHandler.interrupt`；按钮同时切换为方形中止图标并设置 `aria-busy`。`modules/renderer/mainChatSendOwner.js:74-121`

- **群聊**：`interruptGroupRequest`（`Groupmodules/groupchat.js:2478-2495`）从 `activeRequestControllers` 取到 controller 后调用 `controller.abort()` 中断本地 fetch/reader，再补发远端 `/v1/interrupt`；整组队列另有 `interruptGroupChatQueue` 按 `groupQueueCancellationVersions` 取消后续发言者。`Groupmodules/groupchat.js:42-92,2478-2495,2564`
- **单聊**：`interrupt-vcp-request` 只向远端发 `/v1/interrupt`，但这条请求本身带 5 秒超时；`finally` 里若上游未受理（拒绝、超时或抛错），立即用 `vcpStreamTasks.cancel(event.sender, messageId, 'interrupt-local-fallback')` 取消本地流任务。上游受理时保留“上游发终态、本地正常收尾”的路径。`modules/ipc/chatHandlers.js:1561-1614`、`modules/interruptHandler.js:18-42`

  因此单聊按钮现在两条路都能停止界面流：上游配合时由上游关闭响应流，上游不配合时本地兜底取消。主发送 fetch 本身仍无客户端超时，这与中断路径是两件事。

### 7.2 IPC 入口与超时边界

渲染进程的聊天能力经 `preloads/api/*` 声明式注册 IPC，按窗口角色区分。单聊发送 fetch 没有客户端总超时；群聊超时按阶段弹性控制，等待响应头 120 秒、块间空闲 62 秒。

### 7.3 重试与续写

“重新回复”会截断所选消息及其后的历史，再用同一组装器重建请求；Flowlock 续写按绑定 Agent/Topic 从持久历史读取并调用同一发送 API。两者在错误、切换话题和附件提取失败下是否完全一致仍未运行验证。

## 8. 队列、多会话并发与后台生成

### 8.1 群聊调度：四种模式入口

发言模式通过策略对象注册在 `CHAT_MODES`（`Groupmodules/groupchat.js:35-40`）：

- **sequential**（`Groupmodules/modes/sequentialMode.js`）：返回全部 active members，按 `modeSettings.sequential.speakerOrder` 排定；旧字段 `sequentialSpeakerOrder` 作为迁移来源，不在成员列表里的旧成员被过滤，新成员按成员顺序稳定追加。`Groupmodules/groupchat.js:467-483`
- **naturerandom**（`Groupmodules/modes/natureRandomMode.js`）：按优先级依次判定直接提及、tag 匹配（strict/natural 两种模式）、`@所有人`、基础概率与保底，最后按 tag 是否命中用户最新发言排序。`:68-265`
- **invite_only**（`Groupmodules/modes/inviteOnlyMode.js`）：返回空数组，只能通过“邀请发言”入口触发 `handleInviteAgentToSpeak`（`Groupmodules/groupchat.js:1565`）。
- **game**：只返回空发言者，游戏回合由游戏模块自行驱动。`Groupmodules/groupchat.js:39`

### 8.2 并发粒度

- 同一 `handleGroupChatMessage` 调用内部是**严格串行的 `for...of` await 循环**，不存在并发 fetch，天然不会有两个 agent 的 chunk 交错写入同一个 messageId；中止以整组队列为单位（`queueContext.isAborted()`）。`Groupmodules/groupchat.js:931-939`
- 后台会话的流式任务：渲染侧对不可见会话不创建气泡，但仍初始化占位消息、累积流文本并保存历史（细节见消息渲染器笔记 6.2）。
- 单聊与群聊之外的发送队列、同会话串行化约束**未在原调查中核实**。

## 9. Agent、工具、知识库与附件注入点

- 群聊：每个 agent 的上下文按成员配置单独构建，群聊消息落盘 `agentId/model/modelSource` 字段，说明“谁说了话、用的什么模型”在消息级快照保存。`Groupmodules/groupchat.js:975-1114,1452`
- 附件：user 消息携带 `attachments` 数组；组装器把提取文本加入文本 part，把图片与视频帧加入媒体 part，实时引用附件每次从源文件重新读取，失败回退快照。`modules/chat/chatContextPipeline.js:86-135`
- VCPChat 是 VCPToolBox 的官方桌面前端：消息结构、会话存储与 VCPToolBox 请求编排的对应关系见 [`../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)。

## 10. 当前流式任务协调

渲染侧现在分两层：`createStreamSession` 持有纯协议的会话状态（conversationKey、generation、chunk 计数与终态），`createStreamCoordinator` 负责串行 run/persist，主窗口另有 `mainChatStreamConsumer` 把事件映射到具体 Surface 的投影与历史提交。主进程 SenderTaskRegistry 为流请求绑定 sender 生命周期，在导航/销毁/渲染进程崩溃时取消。

依据：`modules/chat/streamSession.js:12-91`、`modules/chat/streamCoordinator.js:28-112`、`modules/chat/vcpStreamBridge.js:9-82`、`modules/renderer/mainChatStreamConsumer.js:1-128`、`modules/services/senderTaskRegistry.js:6-45`。

## 11. 退出恢复、日志与已确认边界

- sender 导航或销毁会由 SenderTaskRegistry 取消该窗口登记的流请求（主框架导航、渲染进程崩溃、销毁均会触发）；嵌入子框架加载不取消聊天。切换会话是否总会触发对应导航生命周期、应用强退时半截消息如何恢复仍未运行验证。`modules/services/senderTaskRegistry.js:20-32`
- 已确认边界：单聊主发送 fetch 无客户端超时；中断请求有 5 秒超时并在未受理时本地兜底取消；群聊按钮本地 abort + 分阶段弹性超时（TTFT 120 秒、空闲 62 秒）；话题自动总结单聊无超时、群聊 20 秒超时。

## 12. 未验证事项

- 远端 `/v1/interrupt` 未及时响应时单聊 UI 行为（本地兜底取消后的收尾表现）需要运行验证。
- 群聊多次调用之间并发覆盖写的风险未验证是否实际触发过（会话与消息管理笔记 6.1）。
- 重新生成、Flowlock 续写和语音窗口在错误及会话切换边界下是否完全复用普通单聊语义未运行验证。
- 切换会话是否必然触发 sender 导航清理、强制退出时半截流的落盘恢复未运行验证。
- 压缩检查点的触发阈值、压缩后信息保真程度与实际长会话效果未运行验证。

## 13. 关键源码索引

- `modules/renderer/mainChatSendOwner.js:74-121`：发送/中止按钮模式切换与分支。
- `modules/chat/chatEventContract.js:7-34`：流事件契约、终态种类与终态归一化。
- `modules/renderer/mainChatStreamConsumer.js:35-128`：终态消费、乐观投影、落盘状态机与副作用顺序。
- `modules/chat/chatHistoryPersistence.js:12-42`：终态历史合并与写回提供者。
- `modules/renderer/mainChatSurfaceAdapter.js:17-56`：`projectTerminal`/`persistTerminal`/`afterPersist` 接线。
- `modules/ipc/chatHandlers.js:74-153`：时间戳绑定、requestContext、内部元数据剥离、未设置参数省略。
- `modules/ipc/chatHandlers.js:1056-1360`：`send-to-vcp` 的请求体组装、sender 生命周期 signal 与流读取。
- `modules/ipc/chatHandlers.js:1561-1614`：单聊中断入口（5 秒超时 + 本地兜底取消）。
- `modules/services/senderTaskRegistry.js:6-45`：窗口导航/销毁时的任务取消权威。
- `modules/chat/chatContextPipeline.js:319-417`：单聊上下文组装入口。
- `modules/chat/contextCompactionState.js:6-25`：压缩检查点判定与发送侧历史截取。
- `modules/interruptHandler.js:18-42`：渲染侧中断转发。
- `modules/renderer/streamManager.js`：DOM 流投影工厂（`createStreamProjection`），负责缓冲、合帧与终态投影。
- `modules/topicSummarizer.js:11-109`：单聊话题摘要（无超时）。
- `Groupmodules/topicTitleManager.js:81-130,184-215`：群聊话题标题生成（20 秒超时）与触发条件。
- `Groupmodules/groupchat.js:35-40,931-1114,1247-1362`：模式注册、串行处理与分阶段弹性超时。
- `Groupmodules/groupchat.js:42-92,2478-2495,2564`：群聊请求登记、单请求中止与整组队列取消。
- `Groupmodules/streamWatchdog.js:1-40`：工具审批期间的空闲看门狗续期。
- `Groupmodules/groupContextWindow.js:11-39`：群聊上下文窗口。
- `Groupmodules/modes/{sequentialMode,natureRandomMode,inviteOnlyMode,jevDecisionMode}.js`：发言模式与 Jev 决策配置。
- `preloads/api/chat.js`：渲染进程聊天能力入口。
