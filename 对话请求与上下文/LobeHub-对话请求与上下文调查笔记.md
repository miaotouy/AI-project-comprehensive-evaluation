# LobeHub 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：从 [`../Chat/LobeHub-Chat调查笔记.md`](../Chat/LobeHub-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据；按 5952f4c3..HEAD 提交范围核对受影响结论并修正行号引用（发送入口重构为主要变更），未重新全量调查代码
>
> 调查范围：发送入口与消息构建、历史选择、上下文拼装、预算与压缩、Runtime/Provider 交接、工具审批与任务恢复、完成回写副作用；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的一次生成任务从会话级 store 的发送 action 进入全局 ChatStore，创建 operation 与临时消息后按 runtime 类型分流到本地 client agent 或服务端 Gateway：

- **主链**：`sendMessage.ts`（已重构为 106 行薄包装——前置 hook/abort 检查后转发全局 `ChatStore.sendMessage`）→ 全局 `ChatStore.sendMessage`（`conversationLifecycle.ts:265` 起：提取 skills/tools/mentions/文件引用、Command Bus 处理内置命令、构造 operationContext）→ 生成 user/assistant 临时消息和 operation → client agent 或 Gateway（`route.ts` 初始化 `ModelRuntime` 并调用 `modelRuntime.chat`）。
- **前端任务与服务端任务的交接以 operation 为载体**：审批/干预在 Gateway 分支发起**新的** Gateway op 携带 `resumeApproval`，让服务端读目标工具消息、落库干预决定并派发工具；本地分支用 `internal_createAgentState` 重建 agent 状态继续跑客户端 runtime。
- 压缩：`/compact` 由 Command Bus（`processCommands`，`conversationLifecycle.ts:410-433`）转为独立 compression operation，`ClientCompressionTransport` 处理待摘要消息；常规请求的 token 截断由 Agent runtime/Gateway 负责，预算算法本次未展开。
- 完成副作用：`runAgent.ts:250-258` 停止 loading 后同批触发桌面通知与 Topic 未读标记。
- **重要边界（如实标注）**：原调查主要是前端代码；`ModelRuntime` 实现、各 provider adapter、Gateway resume 的服务端逻辑均未覆盖，本笔记不虚构其细节。

## 系统边界与生成任务主链

```text
Chat UI 发送（界面入口见 Chat UI 笔记）
  -> 局部 ConversationStore.sendMessage（读 composer 参数与 displayMessages，过滤 isLocalOnlyMessage；本快照为 106 行薄包装）
  -> 全局 ChatStore.sendMessage（conversationLifecycle.ts:265 起：提取 editorData、预加载 skill/tool、Command Bus、构造 operationContext）
  -> 生成 user/assistant 临时消息 + operation（conversationLifecycle.ts 内创建；客户端铸造消息/topic id 见 4230dcddd）
  -> 分流：client agent（本地 runtime）| Gateway（webapi/chat/[provider]/route.ts -> ModelRuntime.chat）
  -> 流式回写（渲染侧见消息渲染器笔记）
  -> 完成：runAgent.ts 停止 loading + 桌面通知 + markTopicUnread
  -> 审批/干预：conversationControl.ts 按 #shouldUseGatewayResume 二分（Gateway resume 新 op / 本地 executeClientAgent / IPC-tRPC 异构干预）
```

边界：消息如何分桶存储与同步属于会话与消息管理（[`../会话与消息管理/LobeHub-会话与消息管理调查笔记.md`](../会话与消息管理/LobeHub-会话与消息管理调查笔记.md)）；Composer 输入、发送按钮状态、审批入口等界面工作流属于 Chat UI；流式事件如何进入可见状态、Markdown 增量渲染属于消息渲染器。

## 1. 提交入口、任务对象与状态机

1. **输入与 UI 消息对象**：`src/features/Conversation/store/slices/message/action/sendMessage.ts:1-106`（原约 700 行的发送逻辑已重构外迁，本文件只做 `onBeforeSendMessage` hook/abort 检查、清空输入与转发，并透传 `onTopicCreated`）→ 全局 `ChatStore.sendMessage`。`src/store/chat/slices/agentRun/actions/entries/conversationLifecycle.ts:317-333` 从 editorData 提取 skills、tools、mentions 和文件引用；`:323-328` 新增 goal 提示检测——`/goal` 前缀消息会把 `lobe-goal` 注入选定工具列表；`:353-370` 新增单 Agent 直接 @mention 执行路由（`parseSingleAgentMentionDirectRoute`，被提及 Agent 直接成为执行者，不走 supervisor 回合）；`:398-408` 运行时选择统一走 `selectRuntimeType`（含 `forceRuntime` 覆盖，任务话题可强制服务端运行）。
2. **历史筛选与当前分支**：`conversationLifecycle.ts` sendMessage 内（`sendMessageWithContext` 参数 `messages`/`contextSelections`）优先使用调用方传入的 messages，否则按 context key 读取 display messages；`parentId` 由输入值或最后一条 display message 的真实 id 确定。该发送层以当前 display messages 为输入，不主动把其它显示分支拼入请求；持久化分支的具体解析留在消息服务和运行时层。`30daf9e20` 让 context selections 按会话 key 隔离（`contextSelections` 与 `operationContext` 绑定到具体 conversation），避免多会话间串扰。
3. **任务对象与前后端交接（LobeHub 特殊处理的交接点）**：发送在 `conversationLifecycle.ts` 内生成 user/assistant 临时消息和 operation（`operationContext` 构造在 :510 起；客户端铸造消息/topic id 见会话与消息管理笔记 §3.1），再按 runtime 类型分流到 client agent 或 Gateway。operation（`src/store/chat/slices/operation/types.ts:410-489`）是前端任务与服务端任务交接的载体：Gateway 分支的干预（审批等）通过**发起新 Gateway op 并携带 `resumeApproval`** 交接给服务端（见第 7 节），本地分支则直接重建 client runtime 状态继续执行。

## 2. 历史选择与上下文拼装顺序

- 历史选择：以当前 display messages 为输入（发送层不主动把其它显示分支拼入请求），`parentId` 由输入值或最后一条 display message 的真实 id 确定；`isLocalOnlyMessage` 在入口处被过滤，本地专属消息不进入请求（过滤在局部 `sendMessage.ts:73` 与全局 sendMessage 两处执行，见 `src/store/chat/utils/localMessages.ts`）。
- **system prompt、记忆、附件与工具**：`conversationLifecycle.ts` sendMessage 内构造运行上下文、文件 id 列表、图片/视频预览和 user message metadata；预加载被选中的 skill/tool 内容（`:552` 起 `resolveSelectedSkillsWithContent`，经 `SelectedSkillInjector`/`SelectedToolInjector` 注入，不再伪造工具调用占位消息）。
- **operationContext**：可承载 group、thread、page document 等运行上下文（构造在 `conversationLifecycle.ts:510` 起），供 client agent 或 Gateway 继续注入 system prompt、工具和页面资源。

## 3. 预算、截断、摘要与压缩

- 发送层支持 `/compact`：现由 Command Bus（`processCommands`，`conversationLifecycle.ts:410-422`）识别，`:423-433` 在无进行中压缩 operation（`hasRunningCompressionOperation`）时转独立 compression operation（`executeCompression`）；客户端压缩还通过 `ClientCompressionTransport` 处理待摘要消息。
- 常规请求的最终 token 截断由 Agent runtime/Gateway 负责，本次未将每个模型 runtime 的预算算法展开——未核实。

## 4. SDK、Provider、模型与协议交接

- Gateway 侧在 `src/app/(backend)/webapi/chat/[provider]/route.ts:24` 初始化 `ModelRuntime`，并在 `:38-42` 调用 `modelRuntime.chat(data, ...)`。
- 客户端 agent 则以当前 messages、parent id、metadata 和 context 启动本地 runtime。
- **边界**：Provider 最终 HTTP 字段由 `ModelRuntime`/各 provider adapter 生成，未逐一核对；`ModelRuntime` 自身实现（服务端 Agent runtime）在原调查中未覆盖，本笔记不虚构其细节。

## 5. 流式事件、缓冲、节流与顺序

- 原调查没有展开流式事件链的缓冲/节流/顺序实现（流式事件进入渲染状态后的路径属于消息渲染器笔记的流式 Markdown 部分）；本次可确认的流式相关交接只有两处：`ClientCompressionTransport`（压缩任务的流式传输）与临时消息的乐观更新路径（`internal_dispatchMessage` 的即时重算，数据层见会话与消息管理笔记）。
- 流式增量如何从执行端回到状态层、是否有缓冲合并与节流，本次标注未调查，不虚构。

## 6. 完成、异常、半截流与最终回写

- **完成事件副作用**：`src/store/chat/slices/aiAgent/actions/runAgent.ts:250-253` 在“停止 loading”之后同批触发 `notifyDesktopAgentCompleted`（桌面通知）与 `markTopicUnread`（255-263 行，把该 Topic 标记未读）——桌面通知和“Topic 未读点”是同一个完成事件驱动的两个并行副作用（通知的深链与呈现见 Chat UI 笔记）。
- **审批回写**：Gateway 分支的审批恢复由服务端读目标工具消息、落库 `intervention=approved`、派发工具、流回结果（见第 7 节）——即干预决定持久化在服务端，前端只发起交接。
- 半截流/异常/超时的收口实现原调查未覆盖，未验证。

## 7. 停止、重试、续写与重新生成（工具审批 / 拒绝 / 干预）

工具审批/拒绝/干预属于执行层任务控制，全部集中在全局 ChatStore 的 `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（`ConversationControlActionImpl`）。局部 store 只是薄转发层（数据层事实见会话与消息管理笔记 3.4）：

- `approveToolCalling`（374-526 行）：先用 `startOperation` 建一个携带 `context` 的临时 op（为了让乐观更新落到正确的 messageMapKey 分桶），再判断 `#shouldUseGatewayResume`（69 行，根据 agent 的执行目标/异构 provider 决定走 Gateway 还是本地 client runtime）——**两条完全独立的实现分叉**：
  - Gateway 分支（440-471 行）：不在原 op 上恢复，而是发起一个**新的** Gateway op，携带 `resumeApproval: {decision:'approved', toolCallId, parentMessageId}`，让服务端去读目标工具消息、落库 `intervention=approved`、派发工具、流回结果；
  - 本地 client 分支（473-526 行）：用 `internal_createAgentState` 重建 agent 状态，`phase: 'human_approved_tool'`，调 `executeClientAgent` 从工具消息位置继续跑本地 runtime。
- `submitToolInteraction`（527-774 行）、`skipToolInteraction`（776-901 行）逻辑类似，还多一步“是否要插入一条合成的 user 消息”的分叉（`shouldCreateUserMessage`，第 657-708 行 vs 710-774 行）。
- `rejectToolCalling`/`rejectAndContinueToolCalling`（1175-1440 行）同样区分 Gateway resume（用 `decision:'rejected_continue'`）vs 本地 `phase:'user_input'` 继续执行。
- `submitHeteroIntervention`（974-1114 行）专门处理异构 Agent（Claude Code CLI 等）的 AskUser 类中断：不走 `executeClientAgent`，而是通过 IPC（本地 desktop CC）或 tRPC（远程 sandbox/device）把答案送回正在阻塞的子进程/远端执行（1080-1097 行区分 `execHeterogeneousAgent` 本地 vs 其它远程）。

**调用链总结**：UI 组件（如 `AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx`）→ 局部 `useConversationStore().approveToolCall` → 局部 `tool/action.ts` 转发 → 全局 `useChatStore().approveToolCalling` → `conversationControl.ts` 里做乐观更新 + 派发 Gateway/本地 runtime。

**已知限制**：`INPUT_LOADING_OPERATION_TYPES` 的注释（`operation/types.ts:452-472`）自己承认了一个已知限制：审批类“过渡态” op 在 Gateway 分支下没有转发 `parentOperationId`，导致这个窗口期按 Stop 不会真正中断请求（“loading briefly flickers, generation proceeds”）。

**普通停止/重试/重新生成**：原调查未展开普通停止按钮的 abort 层级与重新生成的任务链（停止入口与按钮状态见 Chat UI 笔记；网络级取消效果未验证）。

## 8. 队列、多会话并发与后台生成

- 全局 `operations`/`operationsByContext`/`operationsByMessage` 刻意保持全局，就是为了让“多个 Agent/Topic 同时跑生成任务”可行——`ConversationProvider.tsx:70-76` 注释直接写：“Operations are kept global to support multiple agents/topics running in parallel.”（存储布局见会话与消息管理笔记 2.4。）
- 同会话内是否串行、再次发送是排队/替换/报错，以及后台生成管理：原调查未覆盖，未验证。

## 9. Agent、工具、知识库与附件注入点

- 本次任务在发送层取得的注入物：`conversationLifecycle.ts` sendMessage 内构造的运行上下文、文件 id 列表、图片/视频预览、user message metadata；`:552` 起经 `resolveSelectedSkillsWithContent` 预加载被选中的 skill/tool 内容（`SelectedSkillInjector`/`SelectedToolInjector` 注入）；`operationContext` 承载 group/thread/page document 供 client agent 或 Gateway 注入 system prompt、工具和页面资源。
- 工具目录构建、知识库检索、记忆等能力的**内部机制**属于 Agent 工具等专项类目，原调查未覆盖；本笔记只记录发送层的注入交接点。

## 10. 退出恢复、日志与已确认边界

- 切换会话、关闭窗口、应用退出、网络重连时的任务处理：原调查未覆盖，未验证。
- **后端覆盖边界（如实标注）**：原调查主要是前端代码。`ModelRuntime` 实现、各 provider adapter 的请求字段生成、Gateway resume 的服务端处理（读工具消息、落库 intervention、派发工具）均只观察到前端交接点（`route.ts:24,38-42` 与 `resumeApproval` 载荷），服务端内部未调查。
- 可观测性：任务级日志/trace/用量关联本次未调查；完成事件的可观察出口（桌面通知深链、未读点）在 Chat UI 笔记。

## 11. 未验证事项

- Gateway resume 与本地 client runtime 两条审批路径在所有边界情况下是否真正行为等价，只能从代码结构上判断“两套独立实现”，未做运行时验证（迁移自原调查未核实事项）。
- Provider 最终 HTTP 字段、token 截断预算算法（第 3、4 节）。
- 普通停止的网络级取消效果、重试/重新生成的任务链、队列与并发行为（第 7、8 节）。
- 流式事件链的缓冲/节流/顺序实现（第 5 节）。
- 服务端 ModelRuntime 与 Gateway resume 内部实现（第 10 节）。

## 12. 关键源码索引

- `src/features/Conversation/store/slices/message/action/sendMessage.ts`（1-106，薄包装）
- `src/store/chat/slices/agentRun/actions/entries/conversationLifecycle.ts`（sendMessage 265-，editorData 提取 317-333，goal 注入 323-328，@mention 路由 353-370，运行时选择 398-408，Command Bus 410-433，operationContext 510，skill 预加载 552，executeClientAgent 2002）
- `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（39-1441，尤其 69, 374-526, 527-774, 776-901, 974-1114, 1175-1440）
- `src/store/chat/slices/operation/types.ts`（410-489；INPUT_LOADING 注释 452-472）
- `src/store/chat/slices/aiAgent/actions/runAgent.ts`（250-258, 303）
- `src/app/(backend)/webapi/chat/[provider]/route.ts`（24, 38-42）
- `src/features/Conversation/store/slices/tool/action.ts`（13-142）
- `src/hooks/useOperationState.ts`（23-144）
- `src/store/chat/slices/message/actions/publicApi.ts`（36-278）

