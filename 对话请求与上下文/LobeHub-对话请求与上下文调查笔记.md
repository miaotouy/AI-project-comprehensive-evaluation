# LobeHub 对话请求与上下文调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：直接阅读源码（会话级 ConversationStore 发送 action、全局 ChatStore 的 agentRun/operation/aiAgent slices、Gateway HTTP 路由、工具审批与恢复链）+ grep 检索调用点，全部行号按当前 HEAD 逐一核对；未运行应用
>
> 调查范围：发送入口与消息构建、同会话队列、历史选择、上下文拼装、命令总线与压缩、Runtime/Gateway 交接、流式事件处理、完成回写副作用、工具审批与任务恢复、页面重载后的 Gateway 重连；Provider adapter 内部字段、服务端 Agent runtime 与 Gateway resume 服务端实现未覆盖
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的一次生成任务从会话级 store 的发送 action 进入全局 ChatStore，铸造消息/topic id、创建 operation 与临时消息后按 runtime 类型分流到本地 client agent、服务端 Gateway 或异构 CLI：

- **主链**：会话级 store 的发送 action 先做 hook 与 abort 前置检查，随即把请求转给全局 ChatStore 的发送入口 `sendMessage`（`conversationLifecycle/index.ts`）。该入口在一次调用里完成请求准备：提取 skills/tools/mentions 与文件引用、注入 Goal、处理 @mention 直连路由、按 `selectRuntimeType` 选定运行位置、交给 Command Bus 处理 `/compact` 等命令、检查同会话消息队列，随后铸造 topic/message id、构造 operationContext 与乐观消息。准备完成后按 runtime 类型分流，路由与执行入口集中在 `agentRun/actions/dispatch/agentDispatcher.ts`：
  - 异构 CLI 交给 `execHeterogeneousAgent`（`transports/hetero/`）；
  - Gateway 交给 `executeGatewayAgent`（`transports/gateway/`，携带 `clientIds`）；
  - client agent 先把消息落库再本地执行，即 `sendMessageInServer` 加 `executeClientAgent`（`transports/client/streamingExecutor.ts`）。
- **同会话串行靠 operation 队列**：`QUEUE_BLOCKING_OPERATION_TYPES`（含 sendMessage、三类 AI runtime、上传语音、审批类过渡 op）运行期间，新的发送会 `enqueueMessage` 排队（含新建 topic 的 `_new` 桶与铸造中 topic 桶双重探测），QueueTray 提供“立即发送”取消排队。
- **前后端任务交接以 operation 为载体**：审批/干预在 Gateway 分支发起**新的** Gateway op 携带 `resumeApproval`/`resumeToolResult`，让服务端读目标工具消息、落库干预决定并派发工具；本地分支用 `internal_createAgentState` 重建 agent 状态继续跑客户端 runtime；异构 Agent 的 AskUser 中断经 IPC（本地）/tRPC（远程）回送答案。
- **压缩**：`/compact` 由 Command Bus（`processCommands`）转为独立 `contextCompression` operation，`executeCompression` 先建服务端压缩组、再走 LLM 摘要流式回填、`finalizeCompression` 收口。
- **完成副作用**：运行生命周期统一在 `agentRun/actions/lifecycle/buildRunLifecycle.ts` 收口：停止 loading 后同批触发桌面通知与 Topic 未读标记；审批需人工时触发角标通知并置 `waitingForHuman` 状态。
- **退出恢复（Gateway 路径）**：topic 的 `metadata.runningOperation` 在页面加载时被 `useGatewayReconnect` 捕获，经 `reconnectToGatewayOperation` 刷新 JWT、新建 WebSocket 并回放事件，把 UI 重新挂到仍在跑的服务端任务上。
- **共享上下文工程**：浏览器 client agent 与服务端不再各自决定 Agent 配置、上下文事实和模型参数。`packages/mecha` 提供宿主无关的配置解析、事实快照、MessagesEngine 参数构造和模型参数决策；浏览器与服务端各自只负责从本地 store 或数据库采集事实，再把冻结快照交给共享规则。见 `packages/mecha/src/index.ts:1-9`、`packages/mecha/src/contextEngineering/index.ts:8-19` 与 `src/services/chat/mecha/agentConfigResolver.ts:1-73`。
- **Gateway 排队续作**：前端会把当前 context 是否仍有排队消息同步给运行中的服务端 operation。Agent 在下一个决策点以 `queued_message_interrupt` 结束当前 turn，交还给输入队列；这使排队消息不必等整个长工具循环自然结束。该标记只用于顶层 Gateway run，并采用 best-effort 同步。见 `src/store/chat/slices/agentRun/actions/transports/gateway/queuedMessagesFlag.ts:52-70` 与 `packages/agent-runtime/src/agents/GeneralChatAgent.ts:900,932-977`。
- **重要边界**：本次调查主要是前端执行链；`ModelRuntime` 实现、各 provider adapter、Gateway resume 的服务端逻辑均未覆盖。

## 系统边界与生成任务主链

```text
Chat UI 发送（界面入口见 Chat UI 笔记）
  -> 局部 ConversationStore.sendMessage（106 行薄包装：hook/abort 检查后转发）
  -> 全局 ChatStore.sendMessage（agentRun/actions/entries/conversationLifecycle/index.ts）
       - 提取 editorData（skills/tools/mentions/文件引用）+ Goal 注入 + @mention 直连路由
       - selectRuntimeType 分流决策 -> Command Bus（/compact /newTopic /goal）-> 消息队列检查
       - 铸造 topic/message id -> operationContext -> user/assistant 乐观消息 + 乐观 topic 行
       - dispatch/agentDispatcher 按 runtime 分流：
         * hetero：sendMessageInServer 落库 -> execHeterogeneousAgent op（IPC/子进程）
         * gateway：executeGatewayAgent（clientIds 让服务端按客户端 id 落库）
         * client：sendMessageInServer 落库 -> executeClientAgent 本地 runtime
  -> 流式回写（agentEventRouter 分发事件；生命周期收口在 lifecycle/buildRunLifecycle）
  -> 完成：buildRunLifecycle 停止 loading + 桌面通知 + markTopicUnread
  -> 审批/干预：conversationControl 按 resolveGatewayResume 二分（Gateway resume 新 op / 本地 executeClientAgent / IPC-tRPC 异构干预）
  -> 页面重载恢复：topic.metadata.runningOperation -> useGatewayReconnect -> reconnectToGatewayOperation（新 WS + 事件回放）
```

边界：消息如何分桶存储与同步属于会话与消息管理（[`../会话与消息管理/LobeHub-会话与消息管理调查笔记.md`](../会话与消息管理/LobeHub-会话与消息管理调查笔记.md)）；Composer 输入、发送按钮状态、审批入口等界面工作流属于 Chat UI；流式事件如何进入可见状态、Markdown 增量渲染属于消息渲染器；工具执行循环内部语义属于 Agent 工具专项。

## 1. 提交入口、任务对象与状态机

1. **输入与 UI 消息对象**：会话级 store 的发送 action 位于 `src/features/Conversation/store/slices/message/action/sendMessage.ts:33-105`，只做前置检查与转发。它先跑发送前 hook 的 abort 检查（`throwIfAborted`），未设置保留输入框标记时清空输入框，并过滤掉本地独有消息。随后把调用转给全局 ChatStore 的发送入口，透传话题创建回调、调用方 ConversationProvider 所拥有的编辑器实例与消息列表；inputEditor 可为 null，表示本次发送没有 composer 编辑器（`conversationLifecycle/index.ts:156-162`）。发送结束后依次触发消息创建后与发送后两个回调。
2. **全局发送入口**：`conversationLifecycle/index.ts` 的 `sendMessage`（约 2,180 行）分阶段推进一次发送：
   - 前置解析：从编辑器数据中取出选中的 skills/tools、被提及的 agents 与本地文件引用；`/goal` 前缀把 `lobe-goal` 注入选定工具列表；被提及的单个 Agent 经 `parseSingleAgentMentionDirectRoute` 直接成为执行者，跳过 supervisor 回合；运行位置最终由 `selectRuntimeType` 统一决定，`forceRuntime`（任务话题可强制服务端运行）、workspace 成员设备与异构 provider 恢复都会覆盖默认选择。
   - Command Bus：`processCommands` 从编辑器数据中抽取内建命令，`/compact`（见第 3 节）与 `/newTopic`（可注入 `<refer_topic>` 节点）等命令在这一步处理。
   - 预留话题身份：需要创建普通新话题时，先铸出 topic id 并构造 operationContext，后续队列探查也使用该 context（`conversationLifecycle/index.ts:544-579`）。
   - 消息队列检查：按当前 context 与正在创建的话题桶检查阻塞 operation，命中排队条件时提前返回，见第 8 节（`conversationLifecycle/index.ts:636-660`）。
   - 建立乐观状态：通过队列检查后，再铸临时 user/assistant 消息 id 并调用 `startOperation`，写入乐观消息、关联 operation、生成乐观 topic 行并切换话题，同时把编辑器 JSON 存进 operation metadata 供取消时恢复（`conversationLifecycle/index.ts:507-1146`）。
   - 按 runtime 三分流执行，见第 4 节。
3. **任务对象**：operation（`src/store/chat/slices/operation/types.ts`）是前端任务与服务端任务交接的载体，四组常量（`types.ts:438-513`）分别对应执行、交接窗口、输入 loading 与发送队列四种判断：
   - `AI_RUNTIME_OPERATION_TYPES`：`execAgentRuntime`/`execHeterogeneousAgent`/`execServerAgentRuntime`，代表真实执行；
   - `INTERIM_LOADING_OPERATION_TYPES`：approve/submit/skip/regenerate，代表交接窗口；
   - `INPUT_LOADING_OPERATION_TYPES`：驱动输入 loading 与停止按钮；
   - `QUEUE_BLOCKING_OPERATION_TYPES`：驱动发送队列。

## 2. 历史选择与上下文拼装顺序

- 历史选择：发送层直接以当前 display messages 作为历史输入——优先采用调用方传入的 `inputMessages`，否则按 context key 读取 display messages 并过滤本地独有消息；尾部消息若属于 `taskCallback` 轮次会被排除，`parentId` 取输入值或由 `findLastMessageId` 回溯确定。发送层不拼接其它显示分支，持久化分支的解析留给消息服务与运行时层（`conversationLifecycle/index.ts:685-711`）。
- **system prompt、记忆、附件与工具**：发送层把文件引用列表与 user message metadata 一并带入请求构造，后者承载 contextSelections、pageSelections 与本地 system 工具快照（`conversationLifecycle/index.ts:523-548`）。
- **skill/tool 预加载**：被选中的 skill/tool 内容在发送前预加载，由 `SelectedSkillInjector`/`SelectedToolInjector` 注入，不生成伪造的工具调用占位消息（源码注释写作 “no fake tool-call preload messages”）；client 分支随后把去重后的 skill/tool 上下文拼进持久化的 user 消息正文，使选中工具跨轮次存活（`conversationLifecycle/index.ts:550-562,1611-1635`）。
- **operationContext**：在发送层构造，承载 group（supervisor 标记）、thread（新建 thread 时清空 threadId 交给服务端创建）、page document（从 page runtime 取当前文档 id 注入）与铸造好的 topicId，供 client agent 或 Gateway 继续注入 system prompt、工具和页面资源；`contextSelections` 与 `operationContext` 都绑定具体 conversation，多会话之间互不串扰（`conversationLifecycle/index.ts:481-521`）。
- **User memory**：发送时 `setActiveMemoryContext` 把 agent meta、当前 topic、最近 user 消息与新消息喂给 user memory store；这里只记录注入点，记忆检索的内部机制属于 Agent 角色/记忆专项（`conversationLifecycle/index.ts:700-705`）。

## 3. 预算、截断、摘要与压缩

- 发送层支持 `/compact`：Command Bus 识别到该命令后，在没有进行中的压缩 operation 时转入独立的 compression operation。该 operation 由 `executeCompression` 驱动：先选出待压缩消息、在服务端建立压缩组，再走 LLM 摘要并把结果流式回填到压缩组内容，最后由压缩收尾步骤定稿；中途 abort 会删掉临时组（`conversationLifecycle/index.ts:410-433,2046-2148`）。
- 常规请求的最终 token 截断由 Agent runtime/Gateway 负责；`ChatInput` 侧的 Token 预算明细条只是发送前估算（`useTokenBreakdown`，见 Chat UI 笔记第 3 节），与截断算法各走一条路径。当前 Agent runtime 在压缩完成后保留 prompt headroom，并用运行时标记抑制同一上下文重复压缩，这段实现只确认了避免连续压缩的收口策略，各模型 runtime 的预算算法未逐一展开（`packages/agent-runtime/src/agents/GeneralChatAgent.ts`）。

## 4. SDK、Provider、模型与协议交接

- **Gateway 侧**：provider 级 HTTP 入口在 `src/app/(backend)/webapi/chat/[provider]/route.ts`，请求先由 `initModelRuntimeFromDB` 初始化 `ModelRuntime`，再调用 `modelRuntime.chat(data, { user, traceOptions, signal: req.signal })`（`route.ts:24,38-42`）。该路由服务直连模型的调用类请求。
- **执行交接（三种 runtime）**：
  - **异构 CLI**（`runtimeType === 'hetero'` 且存在异构 provider）：先落库 user/assistant 行并携带铸造 id，解析服务端 topic 后把队列条目与语音占位行搬进新桶，用 `replaceMessages` 收敛乐观态，然后以异构执行 op 类型开启 operation，并经 IPC 驱动本地 CLI 子进程；恢复时按 cwd 是否变化决定是否追加 `--resume`（`conversationLifecycle/index.ts:1150-1478`）。
  - **Gateway**（`runtimeType === 'gateway'` 且非 @mention 直连路由）：Gateway 执行入口携带 `clientIds`（assistant 消息、topic 与 user 消息三类客户端铸造 id，服务端据此落库），新建 topic 时从 context 中去掉 topicId 交给服务端创建，另传选中的工具与提及 Agent 列表，让服务端 supervisor 启用对应工具与委派；任务完成后生成话题标题（`conversationLifecycle/index.ts:1481-1596`）。
  - **client**（默认路径）：先由 `sendMessageInServer` 落库（携带铸造 id 与新建 topic/thread 标记），解析最终 topic/thread 后 `replaceMessages`，自动置空遗留的 pending 干预，最后由客户端执行入口以本地 Agent runtime 从 user 消息位置继续；handoff 让 sendMessage op 等子 runtime 就绪后才 complete，队列屏障因此保持连续（`conversationLifecycle/index.ts:1598-2031`）。
- **边界**：Provider 最终 HTTP 字段由 `ModelRuntime`/各 provider adapter 生成，未逐一核对；`ModelRuntime` 自身实现（服务端 Agent runtime）未覆盖。

## 5. 流式事件、缓冲、节流与顺序

- 本笔记可确认的流式交接点：
  - 事件消费按 transport 分：Gateway 分支在 `src/store/chat/slices/agentRun/actions/transports/gateway/`（事件路由在 `gatewayEventRouter.ts`，另有 `gatewayEventBuffer.ts` 负责缓冲、`muxRegistry.ts` 负责连接复用），client 分支在 `transports/client/streamingExecutor.ts`；三个事件在两条链上语义一致：
  - `step_start`：用服务端推送的 `uiMessages` 快照整体替换消息（注释说明 DB 扇出异步落后于 WS 推送，refetch 会拿回过期占位行，“the pushed payload as Source of Truth instead of refetching from DB”）；
  - `visible_output_end`：只退休“可见 loading”；
  - `agent_runtime_end` 之前的最终 `replaceMessages` 才是落库快照。
  - 局部 store `useFetchMessages` 的 `onData` 对流式期间到达的 SWR 快照做了丢弃兜底，避免 DB 扇出窗口内的过期 refetch 折叠流式内容（`data/action.ts:289-303`）。
  - 压缩任务的流式传输：`executeCompression` 内的 `fetchPresetTaskResult` 逐 chunk 更新压缩组内容（`conversationLifecycle/index.ts:2100-2112`）。
- 流式增量如何从执行端回到状态层的缓冲/合并/节流/顺序保证（除上述整体快照替换外）：本次未调查完整链路，未验证。
- Gateway 事件处理器以内部 Promise 队列顺序消费事件，保证工具占位消息拉取、后续 chunk 与终态刷新不会相互越过，高频更新另由缓冲器承接。实验开关 `enableGatewayMux` 开启时，同一 gateway URL 与访问身份复用一个 `GatewayMuxClient`，owner 与不同分享访客仍各用独立连接（`gatewayEventHandler.ts:393-516`、`muxRegistry.ts:17-66`）。

## 6. 完成、异常、半截流与最终回写

- **完成事件副作用**：运行生命周期在 `src/store/chat/slices/agentRun/actions/lifecycle/buildRunLifecycle.ts` 收口：停止 loading 之后同批触发桌面通知 `notifyDesktopAgentCompleted`，随后同批调用 `markTopicUnread` 把该 Topic 标记为未读——桌面通知和“Topic 未读点”由同一个完成事件并行驱动（通知的深链与呈现见 Chat UI 笔记第 9 节）。
- **审批需人工**：`step_start` 命中人工审批条件时，依次写入 needsHumanInput 与 pendingApproval 两份元数据、触发桌面审批通知、把 Topic 状态置为 `waitingForHuman`（`buildRunLifecycle.ts:295-321`）。
- **审批回写**：Gateway 分支的审批恢复由服务端读目标工具消息、落库 `intervention=approved`、派发工具、流回结果（见第 7 节）——即干预决定持久化在服务端，前端只发起交接。
- **半截流/异常/超时收口**：发送链的失败路径统一由 `failOperation`、`cleanupTempMessages` 与 `rollbackOptimisticTopic` 收口，hetero、gateway、client 三条分支在各自的收尾段调用；本地分支还会把编辑器 JSON 从 operation metadata 恢复回输入框。用户取消（abort）时由 `cancelOperation` 处理，保留已落库消息并把 operation 置为 complete。服务端侧的半截流落库收口未调查（`conversationLifecycle/index.ts:1215-1869`）。

## 7. 停止、重试、续写与重新生成（工具审批 / 拒绝 / 干预）

工具审批/拒绝/干预属于执行层任务控制，全部集中在全局 ChatStore 的 `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（1626 行）。局部 store 只是薄转发层（数据层事实见会话与消息管理笔记 4.3）：

- **停止**：`stopGenerateMessage` 按 `AI_RUNTIME_OPERATION_TYPES` 与 running 状态取消当前 context 下全部运行时 op；`cancelSendMessageInServer` 取消仍停在 `sendMessage` 阶段的 op，并把编辑器内容恢复回来（`conversationControl.ts:228-293`）。
- **审批通过**：`approveToolCalling` 先用 `startOperation` 建一个携带完整 context 的过渡 op，让乐观更新落到正确的 messageMapKey 分桶；再按 `#shouldUseGatewayResume` 的判断结果分流到两套独立实现，该判断会依据 Agent 的执行目标、异构 provider 与 gateway 开关重新跑一次 `selectRuntimeType`（`conversationControl.ts:374-532`）。
  - Gateway 分支：在暂停的 op 之外新发一个 Gateway op，携带 `resumeApproval`（决定为 approved，并带工具调用 id 与父消息 id），由服务端读目标工具消息、落库 `intervention=approved`、派发工具并流回结果；为避免服务端结束事件延迟导致 loading 卡死，先快照暂停的 op，等 resume 成功后才退休它们。
  - 本地 client 分支：用 `internal_createAgentState` 重建 agent 状态并置 `phase: 'human_approved_tool'`，再调 `executeClientAgent` 从工具消息位置继续跑本地 runtime。
- **工具交互的提交、跳过与取消**：提交、跳过与取消三个入口沿用同一套分流结构。submit 多一步“是否插入合成 user 消息”的分叉：先按判定结果决定是否乐观创建一轮 user 消息再继续；Gateway 分支带 `resumeToolResult`，本地 tool-result-only 分支以 `phase: 'tool_result'` 继续，不重执行工具（`conversationControl.ts:699-1077`）。
- **拒绝**：两个拒绝入口的 Gateway 分支统一使用 `decision: 'rejected_continue'`；源码注释说明服务端对拒绝与拒绝后继续两种决定走同一路径，前端因此不再区分两者，本地分支同样重建状态继续（`conversationControl.ts:1355-1626`）。
- **异构 Agent 干预**：`submitHeteroIntervention` 专门处理异构 Agent（Claude Code CLI 等）的 AskUser 类中断：先定位真正持有 AskUser bridge 的执行 op，再按 op 类型分流——本地桌面 CC 走 IPC 调用异构 Agent 服务的提交方法；远程执行或 op 已被 GC 的情况走 tRPC `lambdaClient.aiAgent.submitHeteroIntervention`，后者经 Redis stream → 长轮询 → bridge 解析回送答案（`conversationControl.ts:1148-1294`）。

**调用链总结**：UI 组件（如 `AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx`）→ 局部 `useConversationStore().approveToolCall` → 局部 `tool/action.ts` 转发 → 全局 `useChatStore().approveToolCalling` → `conversationControl.ts` 乐观更新 + 派发 Gateway/本地 runtime。

**已知限制**：`INPUT_LOADING_OPERATION_TYPES` 的注释（`operation/types.ts:483-491`）说明：审批类“过渡态” op 在 Gateway 分支下没有转发 `parentOperationId`，导致这个窗口期按 Stop 不会真正中断请求（“loading briefly flickers, generation proceeds”）；而 `regenerate` 分支有转发（因为 retry guard 依赖它，488-491 行）。

**普通重试/重新生成**：`INTERIM_LOADING_OPERATION_TYPES` 含 `regenerate`（460-465 行），说明“重新生成”也是经过渡 op 的恢复流程；具体 regenerate 的任务链（从哪条消息重建请求）本次未展开——未验证。普通停止按钮的界面状态见 Chat UI 笔记；网络级取消效果未运行验证。

## 8. 队列、多会话并发与后台生成

- **并发布局**：全局 store 把三个 operation 索引（`operations`、`operationsByContext`、`operationsByMessage`）都保持为全局状态，目的是让多个 Agent 与 Topic 同时跑生成任务。源码注释写得直接：“Operations are kept global to support multiple agents/topics running in parallel.”（`ConversationProvider.tsx:86-91`；存储布局见会话与消息管理笔记 2.4）。
- **同会话串行（队列）**：一次发送到达时，发送入口先探测候选消息桶——当前桶、新建 topic 场景下的临时桶，以及所有正在铸造 topic 的桶；随后在这些桶里查找运行中的阻塞 op（语音上传自身豁免）；一旦命中就把新消息 `enqueueMessage` 排队（软中断模式，带文件预览快照）并直接返回（`conversationLifecycle/index.ts:578-670`）。
  排队条目由 QueueTray 呈现，“立即发送”会取消排队中的阻塞 op；阻塞 op 的类型集合与过滤实现见 `operation/selectors.ts:279-290` 的注释。
- **后台生成**：Topic 的 `status` 与 `metadata.runningOperation` 由 `#writeTopicStatus` 在执行链写回，侧栏据此显示运行/等待人工图标，完成时再由 `markTopicUnread` 标记未读（见第 6 节）。多会话并行的调度粒度（是否逐 context 隔离执行线程）由 operation 状态机决定，并发竞态行为本次未验证（`conversationControl.ts:209-226`）。

## 9. Agent、工具、知识库与附件注入点

- 发送层在 `conversationLifecycle/index.ts` 中取得的注入物：
  - 运行上下文、`fileIdList`、图片/视频/音频预览与 user message metadata（523-548 行）；
  - 被选中 skill/tool 内容的预加载，由 `SelectedSkillInjector`/`SelectedToolInjector` 注入（552-562 行）；
  - `operationContext`，承载 group/thread/page document，供 client agent 或 Gateway 注入 system prompt、工具和页面资源；
  - `agentRuntimeInitialContext`，在 @mention 场景把 `mentionedAgents`/`createCallAgentManifest` 注入 client runtime 的 `initialContext`（1986-2000 行）；
  - user memory 的 `setActiveMemoryContext`（700-705 行）。
- 工具目录构建、知识库检索、记忆检索等能力的**内部机制**属于 Agent 工具/Agent 角色等专项类目，本次未覆盖；本笔记只记录发送层的注入交接点。

## 10. 退出恢复、日志与已确认边界

- **页面重载/重新进入的 Gateway 恢复**：topic 的 `metadata.runningOperation`（写点在执行链，本笔记只确认读取端）由会话区组件读取后交给 Gateway 重连 hook（`src/hooks/useGatewayReconnect.ts:29-67`，SWR key 为 operationId，借此去重），内部再调 Gateway 重连入口（`transports/gateway/gateway.ts:891-1004+`）完成恢复：刷新 JWT（NOT_FOUND 时清掉本地过期标记）、跳过已建立的连接与更新的 op、重建本地 op 并锚定真实 startTime、把取消转发为服务端中断任务、新建 WebSocket 并回放事件。**这是本次确认到的唯一“退出后恢复”路径（仅 Gateway 模式）**；client 本地 runtime 在页面重载后不恢复（进程内状态丢失），异构 CLI 依赖 `--resume` 会话。
- **切换会话/关闭窗口**：切 topic 时 `switchTopic` 的 epoch 防竞态与 op 清理见第 8 节与 operation 状态机；关闭窗口/应用退出时的任务处理未调查。
- **后端覆盖边界**：本笔记的证据集中在前端代码。`ModelRuntime` 实现、各 provider adapter 的请求字段生成、Gateway resume 的服务端处理（读工具消息、落库 intervention、派发工具）都只观察到前端交接点，即 `route.ts:24,38-42` 与服务端载荷 `resumeApproval`/`resumeToolResult`，服务端内部逻辑未调查。
- **可观测性**：任务级日志/trace/用量关联本次未调查；完成事件的可观察出口（桌面通知深链、未读点、waitingForHuman 图标）记录在 Chat UI 笔记第 9 节与 Topic 侧栏。

## 11. 未验证事项

- Gateway resume 与本地 client runtime 两条审批路径在所有边界情况下是否真正行为等价，只能从代码结构上判断“两套独立实现”，未做运行时验证。
- Provider 最终 HTTP 字段、token 截断预算算法（第 3、4 节）。
- 普通停止的网络级取消效果（WS abort 是否传达到服务端执行循环）、regenerate 的重建请求链、队列并发竞态行为（第 7、8 节）。
- Gateway 之外的 client/异构流式链完整缓冲、节流与顺序实现；Gateway 的顺序队列、事件缓冲与 Mux 注册表已静态确认，但未运行压力验证。
- 服务端 ModelRuntime、Gateway resume、压缩组创建/finalize 的服务端实现（第 4、10 节）。
- 客户端本地 runtime 页面重载后的恢复行为（静态推断为不恢复，未验证）。
- 本轮按引用路径核对了发送链、事件消费与恢复模块的归位（aiAgent/runAgent 已拆为 agentRun 的 dispatch/lifecycle/transports），未逐行重读约 2,180 行的发送主链；行号引用以模块级定位为准。

## 12. 关键源码索引

- `src/features/Conversation/store/slices/message/action/sendMessage.ts`（33-105，薄包装）
- `src/store/chat/slices/agentRun/actions/entries/conversationLifecycle/index.ts`（265-2040 sendMessage；317-333 editorData；323-328 goal；353-358 @mention；398-408 runtime 选择；410-456 Command Bus；507-521 铸造 id/operationContext；552-562 skill 预加载；578-670 队列；713-720 临时 id；807-874 乐观消息；1150-1478 hetero；1481-1596 gateway；1598-2031 client；2046-2148 executeCompression）
- `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（69-81 `#shouldUseGatewayResume`；228-293 停止；374-532 approve；563-605 stopPendingApproval；699-948 submitToolInteraction；1148-1294 submitHeteroIntervention；1355-1626 reject 系列）
- `src/store/chat/slices/operation/types.ts`（438-513 各类 op 常量）
- `src/store/chat/slices/agentRun/actions/lifecycle/buildRunLifecycle.ts`（完成副作用与运行生命周期）
- `src/store/chat/slices/agentRun/actions/dispatch/agentDispatcher.ts`、`directMentionExecutor.ts`、`newThreadIntent.ts`
- `src/store/chat/slices/agentRun/actions/transports/{gateway,client,hetero}/`（事件处理、流式执行、异构进程）
- `src/app/(backend)/webapi/chat/[provider]/route.ts`（24, 38-42）
- `src/hooks/useGatewayReconnect.ts`（29-67）
- `src/store/chat/slices/agentRun/actions/transports/gateway/gateway.ts`（891-1004+ reconnectToGatewayOperation）
- `src/features/Conversation/store/slices/tool/action.ts`（18-208 转发层）
- `src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`（98-108 重连/定时任务挂载）
