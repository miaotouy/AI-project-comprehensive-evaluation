# LobeHub 对话请求与上下文调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7c559cbd4d92a54289bce3a8aab96e057d0ce8c5`（分支：`canary`）
>
> 调查方式：直接阅读源码（会话级 ConversationStore 发送 action、全局 ChatStore 的 agentRun/operation/aiAgent slices、Gateway HTTP 路由、工具审批与恢复链）+ grep 检索调用点，全部行号按当前 HEAD 逐一核对；未运行应用
>
> 调查范围：发送入口与消息构建、同会话队列、历史选择、上下文拼装、命令总线与压缩、Runtime/Gateway 交接、流式事件处理、完成回写副作用、工具审批与任务恢复、页面重载后的 Gateway 重连；Provider adapter 内部字段、服务端 Agent runtime 与 Gateway resume 服务端实现未覆盖
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的一次生成任务从会话级 store 的发送 action 进入全局 ChatStore，铸造消息/topic id、创建 operation 与临时消息后按 runtime 类型分流到本地 client agent、服务端 Gateway 或异构 CLI：

- **主链**：局部 `sendMessage.ts`（106 行薄包装：前置 hook/abort 检查后转发）→ 全局 `ChatStore.sendMessage`（`conversationLifecycle.ts:265` 起）依次做：提取 skills/tools/mentions/文件引用、Goal 注入、@mention 直连路由、`selectRuntimeType`、Command Bus 处理 `/compact` 等命令、消息队列检查、铸造 topic/message id、构造 operationContext 与乐观消息；随后按 runtime 三分流：
  - 异构 CLI：`execHeterogeneousAgent`；
  - Gateway：`executeGatewayAgent`（带 `clientIds`）；
  - client agent：`sendMessageInServer` 落库 + `executeClientAgent` 本地跑。
- **同会话串行靠 operation 队列**：`QUEUE_BLOCKING_OPERATION_TYPES`（含 sendMessage、三类 AI runtime、上传语音、审批类过渡 op）运行期间，新的发送会 `enqueueMessage` 排队（含新建 topic 的 `_new` 桶与铸造中 topic 桶双重探测），QueueTray 提供“立即发送”取消排队。
- **前后端任务交接以 operation 为载体**：审批/干预在 Gateway 分支发起**新的** Gateway op 携带 `resumeApproval`/`resumeToolResult`，让服务端读目标工具消息、落库干预决定并派发工具；本地分支用 `internal_createAgentState` 重建 agent 状态继续跑客户端 runtime；异构 Agent 的 AskUser 中断经 IPC（本地）/tRPC（远程）回送答案。
- **压缩**：`/compact` 由 Command Bus（`processCommands`）转为独立 `contextCompression` operation，`executeCompression` 先建服务端压缩组、再走 LLM 摘要流式回填、`finalizeCompression` 收口。
- **完成副作用**：`runAgent.ts:250-263` 停止 loading 后同批触发桌面通知与 Topic 未读标记；审批需人工时触发角标通知并置 `waitingForHuman` 状态。
- **退出恢复（Gateway 路径）**：topic 的 `metadata.runningOperation` 在页面加载时被 `useGatewayReconnect` 捕获，经 `reconnectToGatewayOperation` 刷新 JWT、新建 WebSocket 并回放事件，把 UI 重新挂到仍在跑的服务端任务上。
- **重要边界（如实标注）**：本次调查主要是前端执行链；`ModelRuntime` 实现、各 provider adapter、Gateway resume 的服务端逻辑均未覆盖，本笔记不虚构其细节。

## 系统边界与生成任务主链

```text
Chat UI 发送（界面入口见 Chat UI 笔记）
  -> 局部 ConversationStore.sendMessage（106 行薄包装：hook/abort 检查后转发）
  -> 全局 ChatStore.sendMessage（conversationLifecycle.ts:265 起）
       - 提取 editorData（skills/tools/mentions/文件引用）+ Goal 注入 + @mention 直连路由
       - selectRuntimeType 分流决策 -> Command Bus（/compact /newTopic /goal）-> 消息队列检查
       - 铸造 topic/message id -> operationContext -> user/assistant 乐观消息 + 乐观 topic 行
       - 三分流：
         * hetero：sendMessageInServer 落库 -> execHeterogeneousAgent op（IPC/子进程）
         * gateway：executeGatewayAgent（clientIds 让服务端按客户端 id 落库）
         * client：sendMessageInServer 落库 -> executeClientAgent 本地 runtime
  -> 流式回写（agent_runtime_end/step_start 等事件驱动；渲染侧见消息渲染器笔记）
  -> 完成：runAgent.ts 停止 loading + 桌面通知 + markTopicUnread
  -> 审批/干预：conversationControl.ts 按 #shouldUseGatewayResume 二分（Gateway resume 新 op / 本地 executeClientAgent / IPC-tRPC 异构干预）
  -> 页面重载恢复：topic.metadata.runningOperation -> useGatewayReconnect -> reconnectToGatewayOperation（新 WS + 事件回放）
```

边界：消息如何分桶存储与同步属于会话与消息管理（[`../会话与消息管理/LobeHub-会话与消息管理调查笔记.md`](../会话与消息管理/LobeHub-会话与消息管理调查笔记.md)）；Composer 输入、发送按钮状态、审批入口等界面工作流属于 Chat UI；流式事件如何进入可见状态、Markdown 增量渲染属于消息渲染器；工具执行循环内部语义属于 Agent 工具专项。

## 1. 提交入口、任务对象与状态机

1. **输入与 UI 消息对象**：`src/features/Conversation/store/slices/message/action/sendMessage.ts:33-105` 只做前置检查与转发：
   - `onBeforeSendMessage` hook 的 abort 检查（9-15 行 `throwIfAborted`）；
   - 非 `preserveComposer` 时清空输入（66 行）；
   - 过滤 `isLocalOnlyMessage`（73 行）；
   - 转发全局 `ChatStore.sendMessage`（83-89 行，透传 `onTopicCreated`/`inputEditor`/`messages`）；
   - 发送后触发 `onAfterMessageCreate`/`onAfterSendMessage`（91-104 行）。
2. **全局发送入口**：`src/store/chat/slices/agentRun/actions/entries/conversationLifecycle.ts` 的 `sendMessage`（265-2040 行），一次发送的状态机大致为：
   - 前置（317-333 行）：从编辑器数据解析选中的 skills/tools、被提及的 agents 与本地文件引用（`parseSelectedSkillsFromEditorData`/`parseSelectedToolsFromEditorData`/`parseMentionedAgentsFromEditorData`/`parseLocalFileReferencesFromEditorData`）；`/goal` 前缀把 `lobe-goal` 注入选定工具列表（323-328 行）；单 Agent 直接 @mention 成为执行路由（`parseSingleAgentMentionDirectRoute`，353-358 行，被提及 Agent 直接成为执行者，不走 supervisor 回合，359-370 行按被提及 Agent 解析配置）；运行时选择统一走 `selectRuntimeType`（398-408 行，含 `forceRuntime` 覆盖——任务话题可强制服务端运行，以及 workspace 成员设备覆盖 374-379 行、异构 provider 恢复 393-397 行）。
   - Command Bus：`processCommands`（410-421 行）从 editorData 抽取内建命令 → `/compact`（423-433 行，见第 3 节）/`/newTopic`（435-456 行，可注入 `<refer_topic>` 节点）/goal 等。
   - 消息队列检查（578-670 行，见第 8 节）。
   - 铸造 id 与乐观状态（507-521 行 `mintedTopicId`/`operationContext`；719-720 行 `tempId`/`tempAssistantId`；721-729 行 `startOperation`；807-870 行乐观 user/assistant 消息；873-874 行 `associateMessageWithOperation`；903-923 行乐观 topic 行 + `switchTopic`；1139-1146 行把编辑器 JSON 存进 operation metadata 供取消时恢复）。
   - 三分流执行（见第 4 节）。
3. **任务对象**：operation（`src/store/chat/slices/operation/types.ts`）是前端任务与服务端任务交接的载体，按用途分四组常量：
   - `AI_RUNTIME_OPERATION_TYPES`（438-442 行）：`execAgentRuntime`/`execHeterogeneousAgent`/`execServerAgentRuntime`，代表真实执行；
   - `INTERIM_LOADING_OPERATION_TYPES`（460-465 行）：approve/submit/skip/regenerate，代表交接窗口；
   - `INPUT_LOADING_OPERATION_TYPES`（472-493 行）：驱动输入 loading/停止按钮；
   - `QUEUE_BLOCKING_OPERATION_TYPES`（505-513 行）：驱动发送队列。

## 2. 历史选择与上下文拼装顺序

- 历史选择：发送层以当前 display messages 为输入（`conversationLifecycle.ts:685-691`：优先调用方传入的 `inputMessages`，否则按 context key 读 display messages，过滤 `isLocalOnlyMessage`）；`lastMessage` 排除 `taskCallback` 轮次（697-698 行，避免把 callback 分支当对话尾巴）；`parentId` 由输入值或 `findLastMessageId(lastMessage.id)` 确定（707-711 行）。发送层不主动把其它显示分支拼入请求；持久化分支的具体解析留在消息服务和运行时层。
- **system prompt、记忆、附件与工具**：发送层把文件引用列表（523 行）与 `userMessageMetadata`（537-548 行：contextSelections/pageSelections/localSystemToolSnapshots 进 metadata）随请求构造；预加载被选中的 skill/tool 内容（552-562 行，经 `SelectedSkillInjector`/`SelectedToolInjector` 注入，不伪造工具调用占位消息——注释 550-551 行 “no fake tool-call preload messages”）；client 分支再把去重后的 skill/tool 上下文**拼进持久化的 user 消息内容**（1611-1635 行：`previouslyMentionedSkills` 去重，`formatSelectedSkillsContext` 追加到 `persistedContent`），使选中工具跨轮次存活。
- **operationContext**：构造在 510-521 行，可承载 group（supervisor 标记 514-518 行）、thread（创建新 thread 时清 threadId 交给服务端 513 行）、page document（481-484 行从 page runtime 取当前文档 id 注入 519 行）、铸造 topicId（520 行），供 client agent 或 Gateway 继续注入 system prompt、工具和页面资源；`contextSelections`/`operationContext` 都绑定具体 conversation（多会话间不串扰）。
- **User memory**：发送时 `setActiveMemoryContext`（700-705 行）把 agent meta、当前 topic、最近 user 消息与新消息喂给 user memory store——只记录注入点，记忆检索内部机制属于 Agent 角色/记忆专项。

## 3. 预算、截断、摘要与压缩

- 发送层支持 `/compact`：现由 Command Bus（`processCommands`，410-421 行）识别，423-433 行在无进行中压缩 operation（`hasRunningCompressionOperation`）时转独立 compression operation（`executeCompression`，2046-2148 行），流程为：选待压缩消息（`getCompressionCandidateMessageIds`，2055 行）→ 服务端建压缩组（`messageService.createCompressionGroup`，2084-2093 行）→ 走 LLM 摘要并流式回填压缩组内容（`fetchPresetTaskResult`，2096-2112 行）→ 收口（`finalizeCompression`，2117-2126 行），abort 时删临时组（2130-2136 行）。
- 常规请求的最终 token 截断由 Agent runtime/Gateway 负责：`ChatInput` 侧的 Token 预算明细条是发送前估算（`useTokenBreakdown`，见 Chat UI 笔记第 3 节），与实际截断算法不是同一条路径。当前 Agent runtime 在压缩完成后保留 prompt headroom，并用运行时标记抑制同一上下文重复压缩；这只确认了避免连续压缩的收口策略，未逐一展开每个模型 runtime 的预算算法（`packages/agent-runtime/src/agents/GeneralChatAgent.ts`，提交 `718a960fb`）。

## 4. SDK、Provider、模型与协议交接

- **Gateway 侧**：`src/app/(backend)/webapi/chat/[provider]/route.ts:24` 由 `initModelRuntimeFromDB` 初始化 `ModelRuntime`，`:38-42` 调用 `modelRuntime.chat(data, { user, traceOptions, signal: req.signal })`；该路由是 provider 级 HTTP 入口（用于直连模型调用类请求）。
- **执行交接（三种 runtime）**：
  - **异构 CLI**（`runtimeType === 'hetero' && heterogeneousProvider`，1150-1478 行）：先落库 user/assistant 行（1164-1214 行，携带铸造 id），解析服务端 topic 并把队列条目、语音占位行搬到新桶（`moveQueuedMessages`/`moveVoiceMessages`，1239-1262 行），`replaceMessages` 收敛乐观态（1272-1275 行），然后 `startOperation({ type: 'execHeterogeneousAgent' })`（1376-1382 行）并 `executeHeterogeneousAgent`（1422-1434 行，经 IPC 驱动本地 CLI 子进程）；`resolveHeteroResume` 按 cwd 是否变化决定是否带 `--resume`（1414-1420 行）。
  - **Gateway**（`runtimeType === 'gateway' && !directMentionRoute`，1481-1596 行）：`executeGatewayAgent` 携带 `clientIds`（assistantMessageId/topicId/userMessageId，1492-1496 行，服务端按客户端铸造 id 落库），`context` 在建新 topic 时去掉 topicId 让服务端创建（1502-1504 行），另传 `selectedToolIds`/`mentionedAgents` 让服务端 supervisor 启用对应工具与委派（1515-1524 行）；完成后 `afterUserMessagePersisted` 生成话题标题（1544-1556 行）。
  - **client**（默认，1598-2031 行）：`sendMessageInServer` 落库（1636-1689 行，同样携带铸造 id 与 `newTopic`/`newThread`），解析最终 topic/thread 并 `replaceMessages`（1691-1794 行），自动置空遗留 pending 干预（1898-1940 行），最后 `executeClientAgent`（2002-2013 行）以本地 Agent runtime 从 user 消息位置继续；`handoffSendOperation`（1944-1953 行）让 sendMessage op 在子 runtime 就绪后才 complete，保持队列屏障连续。
- **边界**：Provider 最终 HTTP 字段由 `ModelRuntime`/各 provider adapter 生成，未逐一核对；`ModelRuntime` 自身实现（服务端 Agent runtime）未覆盖，本笔记不虚构其细节。

## 5. 流式事件、缓冲、节流与顺序

- 本笔记可确认的流式交接点：
  - `runAgent.ts` 是 client 分支事件消费端，三个事件各司其职：
    - `step_start`（280-325 行）：用服务端推的 `uiMessages` 快照整体替换消息（290-293 行，注释：DB 扇出异步落后于 WS 推送，refetch 会拿回过期占位行，“the pushed payload as Source of Truth instead of refetching from DB”）；
    - `visible_output_end`（267-278 行）：只退休“可见 loading”；
    - `agent_runtime_end` 前的最终 `replaceMessages` 才是落库快照（`query.ts` 的写穿条件注释：`agent_runtime_end` 先清运行标记再写穿）。
  - 局部 store `useFetchMessages` 的 `onData` 有“流式期间丢弃 SWR 快照”的兜底（`data/action.ts:289-303`，避免 DB 扇出窗口内的过期 refetch 折叠流式内容）。
  - 压缩任务的流式传输：`executeCompression` 的 `fetchPresetTaskResult` 逐 chunk 更新压缩组内容（2100-2112 行）。
- 流式增量如何从执行端回到状态层的缓冲/合并/节流/顺序保证（除上述整体快照替换外）：本次未调查完整链路，未验证。

## 6. 完成、异常、半截流与最终回写

- **完成事件副作用**：`src/store/chat/slices/aiAgent/actions/runAgent.ts:250-253` 在“停止 loading”之后同批触发 `notifyDesktopAgentCompleted`（桌面通知），`:255-263` 同批 `markTopicUnread`（把该 Topic 标记未读）——桌面通知和“Topic 未读点”是同一个完成事件驱动的两个并行副作用（通知的深链与呈现见 Chat UI 笔记第 9 节）。
- **审批需人工**：`step_start` 命中 `human_approval && requiresApproval` 时（295-321 行）依次：置 `needsHumanInput`/`pendingApproval` 元数据、触发 `notifyDesktopHumanApprovalRequired`（303 行）、`updateTopicStatus('waitingForHuman')`（304-317 行）。
- **审批回写**：Gateway 分支的审批恢复由服务端读目标工具消息、落库 `intervention=approved`、派发工具、流回结果（见第 7 节）——即干预决定持久化在服务端，前端只发起交接。
- **半截流/异常/超时收口**：发送链的失败路径有 `failOperation` + `cleanupTempMessages` + `rollbackOptimisticTopic`（hetero 1215-1228 行、gateway 1568-1595 行、client 1809-1843 行），并会把编辑器 JSON 从 operation metadata 恢复回输入框（1820-1832 行）；用户取消（abort）时 `cancelOperation` 处理（1859-1869 行保留已落库消息并 complete）。服务端侧的半截流落库收口未调查。

## 7. 停止、重试、续写与重新生成（工具审批 / 拒绝 / 干预）

工具审批/拒绝/干预属于执行层任务控制，全部集中在全局 ChatStore 的 `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（1626 行）。局部 store 只是薄转发层（数据层事实见会话与消息管理笔记 4.3）：

- **停止**：`stopGenerateMessage`（228-243 行）按 `AI_RUNTIME_OPERATION_TYPES` + running 状态取消当前 context 的全部运行时 op；`cancelSendMessageInServer`（245-293 行）取消 `sendMessage` 阶段 op 并恢复编辑器。
- `approveToolCalling`（374-532 行）：先用 `startOperation` 建一个携带完整 context 的过渡 op（396-407 行，让乐观更新落到正确的 messageMapKey 分桶），再按 `#shouldUseGatewayResume`（69-81 行，按 agent 的执行目标/异构 provider/gateway 开关重新 `selectRuntimeType`）分流——**两条完全独立的实现分叉**：
  - Gateway 分支（440-478 行）：不在原 op 上恢复，而是发起一个**新的** Gateway op，携带 `resumeApproval`（`decision:'approved'`、`toolCallId`、`parentMessageId`，460-464 行），让服务端读目标工具消息、落库 `intervention=approved`、派发工具并流回结果；`#getRunningServerOps`（91-106 行）先快照暂停的 op，`#completeOpsById`（204-207 行）在 resume 成功后才退休它们（防服务端 `agent_runtime_end` 延迟导致 loading 卡死）。
  - 本地 client 分支（480-531 行）：用 `internal_createAgentState` 重建 agent 状态，`phase: 'human_approved_tool'`，调 `executeClientAgent` 从工具消息位置继续跑本地 runtime。
- `submitToolInteraction`（699-948 行）、`skipToolInteraction`（948 行起）、`cancelToolInteraction`（1077 行起）逻辑类似；submit 还多一步“是否要插入一条合成的 user 消息”的分叉（`shouldCreateUserMessage`：735 行；Gateway 分支 782-821 行带 `resumeToolResult`；本地 tool-result-only 分支 829-880 行 `phase: 'tool_result'`，不重执行工具；默认分支 882-908 行起先 `optimisticCreateMessage` 合成 user 轮次再继续）。
- `rejectToolCalling`（1355-1456 行）/`rejectAndContinueToolCalling`（1458-1626 行）：Gateway 分支统一用 `decision: 'rejected_continue'`（1441-1446 行，注释 1414-1418 行说明服务端 `rejected` 与 `rejected_continue` 同路径，故不再区分）；本地分支重建状态继续。
- `submitHeteroIntervention`（1148-1294 行）专门处理异构 Agent（Claude Code CLI 等）的 AskUser 类中断：经 `#resolveHeteroInterventionExecutionOperation`（108-136 行）找到真正拥有 AskUser bridge 的执行 op，再按 op 类型分流——本地桌面 CC（`execHeterogeneousAgent`）走 IPC `heterogeneousAgentService.submitIntervention`（1262-1270 行）；远程（`execServerAgentRuntime` 或 op 已被 GC）走 tRPC `lambdaClient.aiAgent.submitHeteroIntervention`（1272-1276 行，注释说明经 Redis stream → 长轮询 → `bridge.resolve()`）。

**调用链总结**：UI 组件（如 `AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx`）→ 局部 `useConversationStore().approveToolCall` → 局部 `tool/action.ts` 转发 → 全局 `useChatStore().approveToolCalling` → `conversationControl.ts` 乐观更新 + 派发 Gateway/本地 runtime。

**已知限制**：`INPUT_LOADING_OPERATION_TYPES` 的注释（`operation/types.ts:483-491`）自己承认：审批类“过渡态” op 在 Gateway 分支下没有转发 `parentOperationId`，导致这个窗口期按 Stop 不会真正中断请求（“loading briefly flickers, generation proceeds”）；而 `regenerate` 分支有转发（因为 retry guard 依赖它，488-491 行）。

**普通重试/重新生成**：`INTERIM_LOADING_OPERATION_TYPES` 含 `regenerate`（460-465 行），说明“重新生成”也是经过渡 op 的恢复流程；具体 regenerate 的任务链（从哪条消息重建请求）本次未展开——未验证。普通停止按钮的界面状态见 Chat UI 笔记；网络级取消效果未运行验证。

## 8. 队列、多会话并发与后台生成

- **并发布局**：全局 `operations`/`operationsByContext`/`operationsByMessage` 刻意保持全局，就是为了让“多个 Agent/Topic 同时跑生成任务”可行——`ConversationProvider.tsx:86-91` 注释直接写：“Operations are kept global to support multiple agents/topics running in parallel.”（存储布局见会话与消息管理笔记 2.4）。
- **同会话串行（队列）**（conversationLifecycle.ts:578-670）：
  - 候选桶：当前桶 + 新建 topic 场景下的 `_new` 桶 + 所有 `creatingTopicIds` 对应的铸造中桶（590-602 行）；
  - 阻塞判定：`findRunningBlockingOp`（603-631 行）在 `QUEUE_BLOCKING_OPERATION_TYPE_SET` 中找 running op（语音上传自身豁免，605-613、624-629 行）；
  - 命中则 `enqueueMessage` 排队（653-667 行，`interruptMode: 'soft'`，带文件预览快照 645-651 行）并返回。
  排队条目由 QueueTray 呈现，“立即发送”会取消排队中的阻塞 op（`operation/selectors.ts:279-290` 的注释与 `QUEUE_BLOCKING_OPERATION_TYPES` 过滤）。
- **后台生成**：Topic 的 `status`/`metadata.runningOperation` 由执行链写回（`#writeTopicStatus`，`conversationControl.ts:209-226`），侧栏据此显示运行/等待人工图标；完成时 `markTopicUnread`（见第 6 节）。多会话并行的调度粒度（是否逐 context 隔离执行线程）由 operation 状态机决定，本次未验证并发竞态行为。

## 9. Agent、工具、知识库与附件注入点

- 本次任务在发送层取得的注入物（conversationLifecycle.ts）：
  - 运行上下文、`fileIdList`、图片/视频/音频预览与 user message metadata（523-548 行）；
  - 被选中的 skill/tool 内容预加载（552-562 行，`SelectedSkillInjector`/`SelectedToolInjector` 注入）；
  - `operationContext` 承载 group/thread/page document，供 client agent 或 Gateway 注入 system prompt、工具和页面资源；
  - `agentRuntimeInitialContext`（1986-2000 行）在 @mention 场景注入 `mentionedAgents`/`createCallAgentManifest` 到 client runtime 的 `initialContext`；
  - user memory 的 `setActiveMemoryContext`（700-705 行）。
- 工具目录构建、知识库检索、记忆检索等能力的**内部机制**属于 Agent 工具/Agent 角色等专项类目，本次未覆盖；本笔记只记录发送层的注入交接点。

## 10. 退出恢复、日志与已确认边界

- **页面重载/重新进入的 Gateway 恢复**：topic 的 `metadata.runningOperation`（写点在执行链，本笔记只确认读取端）由 `ConversationArea.tsx:98-103` 读取后交给 `useGatewayReconnect`（`src/hooks/useGatewayReconnect.ts:29-67`，SWR key 为 operationId 保证去重），内部调 `reconnectToGatewayOperation`（`gateway.ts:891-1004+`）完成：刷新 JWT（931-945 行，NOT_FOUND 时清本地过期标记）、跳过已建立的连接与更新的 op（920-929、950-952 行）、重建本地 op 并锚定真实 startTime（980-989 行）、把取消转发为服务端 `interruptTask`（993-997 行）、新建 WebSocket 并回放事件。**这是本次确认到的唯一“退出后恢复”路径（仅 Gateway 模式）**；client 本地 runtime 在页面重载后不恢复（进程内状态丢失），异构 CLI 依赖 `--resume` 会话。
- **切换会话/关闭窗口**：切 topic 时 `switchTopic` 的 epoch 防竞态与 op 清理见第 8 节与 operation 状态机；关闭窗口/应用退出时的任务处理未调查。
- **后端覆盖边界（如实标注）**：本次调查主要是前端代码。`ModelRuntime` 实现、各 provider adapter 的请求字段生成、Gateway resume 的服务端处理（读工具消息、落库 intervention、派发工具）均只观察到前端交接点（`route.ts:24,38-42` 与 `resumeApproval`/`resumeToolResult` 载荷），服务端内部未调查。
- **可观测性**：任务级日志/trace/用量关联本次未调查；完成事件的可观察出口（桌面通知深链、未读点、waitingForHuman 图标）在 Chat UI 笔记第 9 节与 Topic 侧栏。

## 11. 未验证事项

- Gateway resume 与本地 client runtime 两条审批路径在所有边界情况下是否真正行为等价，只能从代码结构上判断“两套独立实现”，未做运行时验证。
- Provider 最终 HTTP 字段、token 截断预算算法（第 3、4 节）。
- 普通停止的网络级取消效果（WS abort 是否传达到服务端执行循环）、regenerate 的重建请求链、队列并发竞态行为（第 7、8 节）。
- 流式事件链的缓冲/节流/顺序实现（第 5 节，除 step_start 整体快照替换外）。
- 服务端 ModelRuntime、Gateway resume、压缩组创建/finalize 的服务端实现（第 4、10 节）。
- 客户端本地 runtime 页面重载后的恢复行为（静态推断为不恢复，未验证）。

## 12. 关键源码索引

- `src/features/Conversation/store/slices/message/action/sendMessage.ts`（33-105，薄包装）
- `src/store/chat/slices/agentRun/actions/entries/conversationLifecycle.ts`（265-2040 sendMessage；317-333 editorData；323-328 goal；353-358 @mention；398-408 runtime 选择；410-456 Command Bus；507-521 铸造 id/operationContext；552-562 skill 预加载；578-670 队列；713-720 临时 id；807-874 乐观消息；1150-1478 hetero；1481-1596 gateway；1598-2031 client；2046-2148 executeCompression）
- `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（69-81 `#shouldUseGatewayResume`；228-293 停止；374-532 approve；563-605 stopPendingApproval；699-948 submitToolInteraction；1148-1294 submitHeteroIntervention；1355-1626 reject 系列）
- `src/store/chat/slices/operation/types.ts`（438-513 各类 op 常量）
- `src/store/chat/slices/aiAgent/actions/runAgent.ts`（250-263 完成副作用；280-325 step_start）
- `src/app/(backend)/webapi/chat/[provider]/route.ts`（24, 38-42）
- `src/hooks/useGatewayReconnect.ts`（29-67）
- `src/store/chat/slices/agentRun/actions/transports/gateway/gateway.ts`（891-1004+ reconnectToGatewayOperation）
- `src/features/Conversation/store/slices/tool/action.ts`（18-208 转发层）
- `src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`（98-108 重连/定时任务挂载）
