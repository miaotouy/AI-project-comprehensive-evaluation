# OpenClaw 对话请求与上下文调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：直接阅读 Gateway、auto-reply、embedded-agent-runner、Context Engine、Agent Core、转录持久化和流式事件处理源码；以可执行调用关系核对入口、状态转移和结果处理，未运行真实 Provider 或对话场景
>
> 调查范围：提交入口与准入、历史和上下文拼装、预算与压缩、Provider/Agent 交接、流式事件、最终回写、停止重试、队列并发、工具/记忆/附件注入、退出恢复与可观测性；会话存储 schema、Chat UI 工作流、工具内部执行语义和具体渠道适配分别保留在相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的一次可见对话由 Gateway `chat.send` 负责请求规范化、会话解析、运行准入和 ACK。ACK 前完成需要同步确认的身份、幂等、路由、附件预处理和取消边界；ACK 后把用户 turn 交给脱离 RPC 生命周期的 dispatch，继续完成回复路由、Agent run、流式投影和终态持久化。主入口见 `src/gateway/server-methods/chat-send-handler.ts:38-303`。

嵌入式 Agent 的上下文来源分成几条边界：SQLite-backed transcript 经 `SessionManager` 恢复并清理；工作区 bootstrap、skills、渠道/发送者元数据、记忆插件、项目记忆和工具目录进入 system prompt 或运行时消息；当前用户的持久化文本与发给模型的文本可以不同，后者在 LLM boundary 统一加入时间和发送者投影。工具、MCP、客户端工具和附件在 attempt 准备阶段按当前运行权限构建，工具循环由 Agent Core 驱动。

上下文预算分为“预检诊断”和“实际恢复”两层。预检根据模型上下文上限、reserve、system prompt、当前 prompt、历史和工具结果估算压力，并区分只截断工具结果与需要压缩的路线；它本身只记录状态，不直接执行压缩。实际压缩由 AgentSession 或外层 embedded recovery 在 provider overflow、阈值、超时恢复等条件下调用，并通过 Context Engine 接口或 legacy delegate 重写/压缩 transcript。

输出有三条不同频率的路径：Agent Core 更新内存中的消息和工具状态，embedded subscriber 将消息事件转换为回复 payload 与 `infra/agent-events`，Gateway `server-chat` 再向 Control UI、节点和渠道投影 `chat`/`agent` 事件。正常 Agent assistant turn 已由 SessionManager 写入 transcript，Gateway 主要负责实时发送；非 Agent 回复和 Agent 产生的媒体补充有单独的 transcript finalization 分支，以避免重复 assistant 行。

## 系统边界与生成任务主链

```text
Gateway chat.send
  -> normalizeChatSendRequest
  -> prepareChatSendSession
  -> runChatSendPreAdmission
  -> admitChatSend
       pending dedupe + session work admission + abort registration
  -> prepareChatSendAttachments
       parse/offload/sandbox stage before ACK
  -> prepareChatSendUserTurn + user-turn recorder
  -> pre-ACK reply-context/message injection
  -> ACK { runId, status: "started" }
  -> detached startChatDispatch
       reply dispatch + source routing + queue/follow-up handling
  -> dispatchInboundMessageWithProjectedDispatcher
  -> dispatchReplyFromConfig
  -> executePreparedReplyRun / executeAgentTurn
  -> runEmbeddedAgent
       session lane -> global lane -> prepared runtime
  -> runPreparedEmbeddedLoop
       attempt setup -> history/context assembly -> prompt preflight
       -> AgentSession.prompt -> Agent Core loop -> Provider stream
       -> tool calls / next turns / compaction / fallback / terminal recovery
  -> embedded subscriber
       AgentSession events -> reply payloads + infra agent events
  -> server-chat
       delta/status/tool/agent projection -> chat final/error/aborted
  -> SessionManager/transcript + session lifecycle persistence
```

本笔记从 Gateway 已接管的 `chat.send` 开始。会话行、transcript entry 的完整 schema、SQLite accessor 和分支数据语义属于会话与消息管理；工具目录的来源、参数校验、审批、执行和结果内部语义见 [OpenClaw Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)。外部运行时、插件或应用的独立生命周期只在本链路的交接点记录。

## 1. 提交入口、任务对象与状态机

### 请求规范化与会话选择

`normalizeChatSendRequest` 先验证 Gateway 协议字段，再清理消息、解析显式来源、系统 provenance、停止命令和附件。系统 provenance、显式 originating route、命令解释抑制和浏览器 copilot 工具绑定都有独立的权限或配对客户端检查；Gateway 只负责配对客户端准入，浏览器插件负责绑定 schema 的具体验证。规范化结果同时保留原始文本、用于 Agent 的文本、turn kind、附件和重连恢复标记，见 `src/gateway/server-methods/chat-send-request.ts:83-194`。

`prepareChatSendSession` 通过 canonical session accessor 读取会话行。在非全局 scope 下，裸 `global` 配合 agent id 会先映射到该 Agent 的 main session，避免重连时创建另一个字面量 `global` transcript。随后解析 selected agent、session id、model、auth provider、timeout、expected leaf 和 restart-safe request 条件，见 `src/gateway/server-methods/chat-send-session.ts:33-212`。

### 运行身份与状态投影

一次 `chat.send` 使用请求的 `idempotencyKey` 作为 `clientRunId`。准入阶段先写入带 attempt id、owner connection/device、过期时间和 `accepted` 状态的 pending dedupe row，再进入 session work admission；锁内会重新读取 reservation、生命周期 generation、session routing、active leaf 和 restart claim。准入成功后再注册 abort controller，并把 Gateway run context 绑定到 session。主要状态和所有权逻辑见 `src/gateway/server-methods/chat-send-admission.ts:48-322`、`:325-563`。

同一个请求在不同层有不同身份：

| 层 | 主要身份 | 可观察状态或作用 |
|---|---|---|
| Gateway | `clientRunId` / `idempotencyKey` | pending、started、终态 dedupe、abort marker |
| Reply operation | session key + operation object | queued、waiting for maintenance/global lane、running、aborted、completed、failed |
| Agent Core | `runId` 和 `activeRun` | `isStreaming`、message/tool lifecycle、`agent_end` |
| Session lifecycle | session row 的 lifecycle run id | running、done、timeout、killed、failed |
| Gateway chat stream | `chat` event state | status、delta、final、error、aborted |

运行入口还会注册 `replyRunRegistry` operation。它以 session key 占用同会话运行槽，挂接 backend、上游 abort signal、tool authority 和 successor barrier；成功或失败清理必须等到对应 terminal/delivery barrier，避免同一 session 的后续 turn 在旧 owner 仍写 transcript 时进入。见 `src/auto-reply/reply/reply-run-registry.operation.ts:55-219`、`:475-723`。

## 2. 历史选择与上下文拼装顺序

### ACK 前的输入上下文

附件解析在 Gateway 准入之后、ACK 之前执行。文本中的附件标记先由 `parseMessageWithAttachments` 解析，图片能力由当前 session model 或显式 plugin/ACP route 决定；非图片文件可预先放入 sandbox workspace，managed PDF 在特定条件下保留 host-readable path。永久附件错误在 ACK 前返回 invalid request，暂时的 staging 错误以 unavailable 返回，未引用的 offloaded media 由 admission cleanup 丢弃。见 `src/gateway/server-methods/chat-send-attachments.ts:65-179`、`:181-305`。

`createGatewayChatUserTurnController` 创建一份带原始文本、到达时间、`${runId}:user` 幂等键、sender、owner 标记、reply-to 和 provenance 的用户 turn。`prepareChatSendUserTurn` 再把图片持久化 promise、媒体 facts、媒体布局和 portable `MsgContext` 绑定起来。普通 turn 的 transcript persistence 可推迟到 ACK 后；restart-safe Control UI turn 会在 ACK 前完成 durable admission，以便 Gateway 重启后重试时能够识别同一个用户 turn。见 `src/gateway/server-methods/chat-user-turn-recorder.ts:33-143`、`src/gateway/server-methods/chat-send-user-turn.ts:186-269`。

### Agent attempt 中的历史恢复

每个 embedded attempt 都有自己的 SessionManager 视图，但它指向被准入锁和 session target 保护的同一 SQLite transcript。`prepareEmbeddedAttemptSessionManager` 读取已有 transcript、解析当前 runtime 的 transcript policy，并通过 `guardSessionManager` 限制允许的工具、合成 tool result、当前 user turn persistence 和错误消息持久化。SessionManager 的消息 append 会创建带 `parentId` 的 transcript entry，并以当前 active branch 维护 leaf；带幂等键的 user entry 可以被已有 canonical entry adoption。见 `src/agents/embedded-agent-runner/run/attempt-session-prepare.ts:396-585`、`src/agents/sessions/session-manager-entries.ts:36-170`。

历史进入模型前大致经过以下顺序：

1. SessionManager 恢复 active branch；raw model run 则清空 Agent 内存历史并只保留原始 probe prompt。
2. 普通 attempt 对历史做 sanitize 和 replay validation，移除不允许重放的结构，修复工具调用与结果配对。
3. quota recovery、heartbeat artifact 过滤、历史 turn 上限和再次的 tool-use/result pairing repair 依次作用于模型候选历史。
4. 若 session 正在 quota resuming，加入 hierarchy reinforcement；活动 subagent 信息可以追加到 system prompt。
5. Context Engine 若存在，则接收当前候选消息、可用工具、memory citation mode、model、prompt 和 token budget，返回组装后的消息及可选 system prompt addition。
6. prompt assembly 再加入当前 turn 的 inbound context、runtime context、heartbeat outcome、hook context、steering 和 inter-session provenance。
7. LLM boundary 最后把时间 envelope、群组 sender context 和当前 user turn 的持久化 metadata 投影到 provider-facing messages，然后由 `convertToLlm` 转成 Provider 消息。

历史清理和 Context Engine assemble 的实际入口见 `src/agents/embedded-agent-runner/run/attempt-history.ts:396-641`；单一 LLM boundary 的安装见 `src/agents/embedded-agent-runner/run/attempt-session-prepare.ts:290-389`。

### transcript prompt 与 model prompt

OpenClaw 保留两个当前 turn 文本：`promptForSession` 用于 transcript 语义，`promptForModel` 用于模型语义。普通用户 turn 尽量持久化 bare prompt，当前 inbound metadata 以 runtime-context custom message 或模型边界投影传递；runtime-only turn 没有 bare user entry，inbound context 会内联到模型和 transcript prompt。prompt build hook 的 prepend/append context 可以只进入 model prompt，避免把动态 hook 内容写成用户原文。该分流由 `prepareEmbeddedAttemptPromptContext` 完成，见 `src/agents/embedded-agent-runner/run/attempt-prompt-build.ts:478-684`。

当前用户 timestamp、sender context 和 transcript message 的关联使用 object identity 优先、timestamp/text 结构匹配作为后备；这使同一用户 turn 在“当前 prompt”和“下一次历史重放”时获得相同的 LLM-boundary 表示，同时保留 transcript 的 bare bytes。sender projection 仅对已有 persisted sender metadata 生效，且 inter-session provenance 会保留在模型可见文本的首要安全位置，见 `src/agents/embedded-agent-runner/run/attempt-history.ts:102-186`、`:309-340`。

## 3. 预算、截断、摘要与压缩

### 预算来源

embedded runtime 先根据 model catalog、配置 context cap 和 provider/harness 的实际能力解析 `contextTokenBudget`。若配置 cap 小于模型原始 context window，effective model 的 context window 也会被收窄，使 AgentSession 的 compaction 判断和 provider 请求使用同一上限。预算解析见 `src/agents/embedded-agent-runner/run/setup.ts:202-284`、`:287-310`。

每个 prompt 使用 compaction reserve。历史 assemble 的 message budget 约为 `contextTokenBudget - reserveTokens - rendered system/prompt pressure`；工具结果还有按 context window 计算的单项和 aggregate 字符上限。Provider dispatch 前再次对 provider message history 执行 tool-result truncation，并在 `markSessionUserTurnsSent` 后阻止迟到的媒体结果改写已经跨过 Provider boundary 的 prompt-cache tail。见 `src/agents/embedded-agent-runner/run/attempt-history.ts:555-603`、`src/agents/embedded-agent-runner/run/attempt-prompt-submit.ts:100-131`。

### 预检与截断路线

`shouldPreemptivelyCompactBeforePrompt` 对消息边界、system prompt、当前 prompt、tool result、branch/compaction summary 和 provider context usage 做估算；有 provider context usage 时优先使用其已知总量，再估算新边界。结果分类为：

| 路线 | 含义 |
|---|---|
| `fits` | 当前估算未超过扣除 reserve 后的 prompt budget |
| `truncate_tool_results_only` | 可裁减的工具结果足以覆盖压力 |
| `compact_only` | 没有足够可裁减工具结果，需要压缩 |
| `compact_then_truncate` | 先压缩，再继续处理工具结果压力 |

这一步写入 `contextBudgetStatus` 和诊断日志，但当前实现明确把它作为 pressure diagnostic；它不会在 `prepareEmbeddedAttemptPromptPreflight` 内直接执行压缩或删除历史。实际 preflight 与中途请求的路由见 `src/agents/embedded-agent-runner/run/preemptive-compaction.ts:216-407`、`src/agents/embedded-agent-runner/run/attempt-prompt-preflight.ts:160-275`。

工具结果还可能由 context pruning 的 cache-TTL 模式清理，历史图片在 prompt transform 阶段按模型输入能力和 workspace/sandbox 根重新加载或裁减。这些 transform 作用于本次 provider context，持久化 transcript 的具体语义由上层 SessionManager 保留。

### 实际压缩和恢复

AgentSession 的 compaction 检查发生在 agent turn 结束后以及下一次 prompt 前。对于同 model 的 context overflow error/length response，若当前 owner 允许 session 侧恢复，会移除错误 assistant 的模型上下文、执行 compact 并自动 retry；达到 context threshold 时执行 auto-compaction，但不会因为普通阈值压缩自动重跑已经完成的 prompt。`src/agents/sessions/agent-session-compaction.ts:278-459` 展示了两种分支。

embedded runner 在 context budget 已由 caller 明确解析时，把 overflow recovery owner 设为 caller。外层 recovery 会构造带 provider/model/auth、当前 token count、prompt cache、workspace、工具策略和 session target 的 Context Engine runtime context，使用安全超时调用 `compact(..., force: true, compactionTarget: "budget")`，然后采用压缩返回的 successor session target、session id 或 legacy locator，再重试当前 transcript。见 `src/agents/embedded-agent-runner/run/compaction-runtime.ts:71-180`、`src/agents/embedded-agent-runner/run/attempt-session-prepare.ts:203-209`。

压缩结果写入 compaction entry 后，SessionManager 重建 active branch context，并以 replay-safe 消息替换 Agent 内存历史。压缩后的 attempt 如果没有形成最终可见回答，terminal resolution 还可追加一次“从压缩 transcript 继续完成回答”的内部 prompt；若已有工具副作用或 replay 不安全，则不会把普通 provider retry 当作无副作用重放。终态恢复逻辑见 `src/agents/embedded-agent-runner/run/terminal-resolution.ts:271-477`。

### Context Engine 边界

Context Engine 是插件化生命周期接口，包含可选的 bootstrap、maintain、afterTurn/ingest、commitTurn、assemble、compact 和 subagent lifecycle。Host 通过 `ContextEngineHostCapability` 声明 bootstrap、assemble-before-prompt、after-turn、compact 等能力；录制用户 turn 的 host 还要求当前 turn fence 与 atomic idempotent advancement。见 `src/context-engine/types.ts:346-505`、`src/agents/harness/context-engine-logical-turn.ts:123-239`。

当前逻辑 turn 先解析 configured engine，再根据 Agent harness 的 host support 选择；不兼容的非 legacy engine 会在本轮降级到 fallback engine，下一轮重新尝试 configured engine，配置本身不被修改。bootstrap/maintenance 在 transcript read fence 下执行，assemble 也会使用当前 turn fence。见 `src/agents/harness/context-engine-logical-turn.ts:65-121`、`src/agents/harness/context-engine-lifecycle.ts:98-225`。

legacy engine 的职责很窄：`ingest` 不写入自己的存储，`assemble` 原样返回 messages 且 `estimatedTokens` 为 0，已有的 sanitize、validate、limit、repair 管线仍由 attempt 负责；`compact` delegate 到 OpenClaw 内置 compaction runtime。见 `src/context-engine/legacy.ts:7-39`。因此，legacy assemble 的透传不能被解释为“没有上下文预算”，预算和 provider-boundary precheck 仍在 runner 中执行。

非 legacy engine 在成功、非 abort、非 prompt error 的 turn 后接收 `afterTurn`；没有该方法时 host 对新增消息调用 `ingestBatch` 或逐条 `ingest`，随后运行 maintenance。若 engine 声明 durable turn advancement，host 可以把用户 admission anchor 和 terminal anchor作为 `commitTurn` 的候选交给 engine，而非让 engine自行猜测 transcript leaf。见 `src/agents/harness/context-engine-lifecycle.ts:263-400`、`src/agents/embedded-agent-runner/run/attempt-finalize.ts:228-333`。

## 4. SDK、Provider、模型与协议交接

### Reply runtime 到 embedded runner

`dispatchReplyFromConfig` 依次完成 request gather、delivery、operation context、operation prepare、route selection、execution prepare 和最终 audit/delivery。对 Gateway 内部 webchat，`dispatchInboundMessageWithProjectedDispatcher` 使用 projected message delivery hooks，把 Agent 运行结果交给 Gateway 自己的 `ReplyDispatcher`，见 `src/auto-reply/dispatch.ts:198-266`、`:472-482`、`src/auto-reply/reply/dispatch-from-config.ts:23-113`。

`executePreparedReplyRun` 把当前 turn 固化为 `FollowupRun`：它携带 transcript prompt、当前 inbound context、媒体、channel admission evidence、工具 allowlist、skills snapshot、source route、发送者/群组字段、provider/model、thinking/verbose/fast mode、sandbox 和 `sessionKey`。这些字段随后交给 `runReplyAgent`，从 auto-reply 进入 channel/embedded Agent runner 的交接点见 `src/auto-reply/reply/get-reply-run-execute.ts:57-618`。

`runEmbeddedAgent` 解析有效 session target，先等待同 session lane，再等待 global lane；已准备的 deferred context maintenance 在进入 global lane 前完成。之后选择 CLI backend 或 native embedded backend，解析 workspace、agent directory、model candidate chain、plugin metadata snapshot 和 prepared model runtime。一次 run 的 provider/model/harness/auth admission 在进入 retry loop 前建立，retry/fallback 使用同一 admitted run context，不重新创建另一份 authority。见 `src/agents/embedded-agent-runner/run-orchestrator.ts:83-218`、`:219-343`，以及 `src/agents/embedded-agent-runner/run-loop.ts:94-149`。

### Agent Core 与 Provider

每个 attempt 的 transport 由 `prepareEmbeddedAttemptTransport` 安装：它解析额外参数、provider stream registration、API key、prompt-cache state、provider text transforms、媒体 materialization、transport override 和必要的 native web-search wrapper，然后把最终 stream function 放到 `AgentSession.agent`。见 `src/agents/embedded-agent-runner/run/attempt-stream-settle.ts:448-646`。

Agent Core 的模型交接固定为：

1. 读取 Agent 内存中的 system prompt、transcript messages 和 tools。
2. 执行 `transformContext`，包括 provider history tool-result truncation、cache-TTL、图片和 computer frame 等运行时 projection。
3. `normalizeCoreContextMessages` 后调用 `convertToLlm`，得到 Provider-facing `Message[]`。
4. 以 `Context { systemPrompt, messages, tools }` 调用 `streamFn(model, context, options)`；API key 在请求时解析，abort signal 随请求传递。
5. 将 Provider 的 start、text/thinking/toolcall 增量、done/error 重新组合为 assistant message 和 AgentSession events。

对应实现见 `packages/agent-core/src/agent-loop.ts:515-613`。`Agent` 本身持有当前 transcript、system prompt、tools、active run 和两个队列，并在 `runWithLifecycle` 中设置 streaming 状态；`agent_end` 事件监听器全部 settle 后才清除 active run，见 `packages/agent-core/src/agent.ts:209-298`、`:466-575`。

### Harness 分界

默认 OpenClaw harness 使用上述 Agent Core 工具、SessionManager 和 Provider stream。若 model runtime 选择非 OpenClaw harness，`runAgentHarnessAttempt` 接管该 attempt；host 仍传入 session target、transcript recorder、context engine、tool authority、媒体和 lifecycle callback。plugin harness 可以拥有自己的 transport 和 tool materialization，host 只保留通用准入、终态和审计边界。attempt backend bridge 见 `src/agents/embedded-agent-runner/run/backend.ts:12-43`。

## 5. 流式事件、缓冲、节流与顺序

### AgentSession 内部事件

Agent Core 在 prompt 开始时发出 `agent_start`、`turn_start` 和用户 `message_start/message_end`；每次模型响应发出 assistant message start/update/end，工具执行发出 start/update/end，回合结束发出 `turn_end`，最终发出 `agent_end`。assistant `message_end` 会先进入 AgentSession 内存消息，再由监听器继续处理。Agent Core 的主循环在 `packages/agent-core/src/agent-loop.ts:226-509`，消息状态归约和监听器等待在 `packages/agent-core/src/agent.ts:604-656`。

embedded subscriber 为一个 AgentSession 安装事件处理器。大多数事件进入串行的 `pendingEventChain`，以保证异步格式化、block flush、usage 和回复 payload 按事件顺序收口；`tool_execution_end` 使用 detached 调度，因为工具终态已经由执行生命周期记录，不能阻塞核心结束事件。见 `src/agents/embedded-agent-subscribe.handlers.ts:28-157`。

assistant message handler 维护 raw text、可见 text、thinking、reply directive、media、block chunk 和 usage。Provider 可能在 `text_end` 重复发送完整文本或迟到发送，处理器只追加未见过的 suffix，并在 message start 作为新的 usage/可见文本边界；message end 再统一完成 directive 解析、可见 payload、reasoning 和 block flush。见 `src/agents/embedded-agent-subscribe.handlers.messages.stream.ts:271-440`、`src/agents/embedded-agent-subscribe.handlers.messages.lifecycle.ts:118-325`。

### Agent event 与 Gateway chat 投影

subscriber 的 lifecycle、assistant、thinking、tool、compaction、usage 等运行信息通过 `emitAgentEvent` 进入 `infra/agent-events`，同时把 reply payload 交给 auto-reply/Gateway dispatcher。`server-chat` 对每个 run 维护 sequence、chat buffer、agent text buffer、plan/progress snapshot 和 tool-event recipients，并拒绝 lifecycle generation 或 owner claim 已失效的事件，见 `src/gateway/server-chat.ts:435-487`。

Gateway 的可见投影有几层：

| 事件来源 | Gateway 行为 |
|---|---|
| assistant visible text | 合并 cumulative text 和 delta，写入 chat buffer，再生成 `chat` state `delta` |
| thinking/assistant agent event | Control UI 走 `agent` stream；75ms 内的文本事件按 stream 合并 |
| tool event | 具备 tool-events capability 的 WS recipient 收到完整 agent event；渠道/节点是否收到详情由 verbose 控制 |
| run status | `preparing_workspace`、`preparing_context`、`starting_model` 等转成 `chat` status |
| lifecycle start/end/error | 更新 session lifecycle、结束 chat run，并触发 final/error/aborted projection |

文本节流常量为 75ms。收到新文本时，如果仍以前缀开头则只发送 suffix；若 Provider 返回的文本不再以前次 broadcast 文本开头，则发送 `replace`，避免乱序或 cumulative/full-content 事件造成重复。工具或 item start、终态前会先 flush 待发送的文本。见 `src/gateway/server-chat.ts:877-1031`、`:1162-1259`、`:1453-1647`。

### 订阅范围

Control UI 可按 session 注册 tool-event recipient；session-scoped subscribers 可以在运行开始后加入，并从 `session.tool` 镜像工具生命周期。普通 channel/node subscriber 主要接收根据 verbose 策略过滤后的 tool payload、assistant live chat 和最终回复。heartbeat run 的 ACK/noise 和 tool event 可按 heartbeat visibility 被隐藏，但其 lifecycle 仍进入内部状态。见 `src/gateway/server-chat.ts:1453-1607`。

## 6. 完成、异常、半截流与最终回写

### 消息持久化

AgentSession 对 `message_end` 做扩展 hook 和持久化。用户、assistant、toolResult 通过 `SessionManager.appendMessage` 写入 `SessionMessageEntry`；custom message 走 `appendCustomMessageEntry`。用户 message 的 publish 发生在 append 成功之后，assistant entry 写入后还会把持久化的 message metadata 回填到当前内存对象。见 `src/agents/sessions/agent-session-base.ts:346-459`。

`SessionManager.appendMessageWithTranscriptAnchor` 为 entry 生成 `parentId`、时间和消息 id；如果当前 active branch 已有同一 user idempotency key，则 adoption 该 user entry，而不会再追加平行 turn。所有 agent transcript message 必须经过这一类 SessionManager/accessor 封装，不能直接写缺少 `parentId` 的 JSONL message。见 `src/agents/sessions/session-manager-entries.ts:128-170`，以及 `src/sessions/user-turn-transcript.ts:251-321`。

Gateway user-turn recorder 是 Gateway 侧的幂等包装器。它串行化自身和嵌套 transcript write，记录 admission anchor，等待图片/media promise，并根据目标 session 的 expected id/session state 调用 `persistSessionTranscriptTurn`。如果用户文本已经跨过 Provider boundary 后才得到额外媒体，recorder 会保留先前的 admitted message，再以 late-media entry 追加媒体，避免改写已经发送的 prompt-cache tail。见 `src/sessions/user-turn-transcript.ts:363-706`。

### Attempt settle 与 after-turn

attempt settle 会等待 completion-required async tools、compaction retry 和待处理 subscriber events；如果 timeout 发生在 compaction 中，使用 pre-compaction snapshot，避免把半写入的压缩视图作为终态。随后收集 assistant/tool snapshot、usage、prompt cache、tool-search transcript projection，并在 prompt error 时追加 `openclaw:prompt-error` custom entry。见 `src/agents/embedded-agent-runner/run/attempt-stream-settle.ts:103-445`。

无 prompt error、abort 或 yield 时，Context Engine 的 after-turn/ingest 和 maintenance 先运行；随后可以记录完整 bootstrap 已完成的 custom entry，并执行 Agent end side effects。attempt 最后生成带 terminal outcome、usage、prompt、system prompt report、tool summary、fallback trace、compaction count 和 delivery evidence 的结果。transcript writes 由 attempt transcript lifecycle 串行化，cleanup 有 30 秒 teardown budget。见 `src/agents/embedded-agent-runner/run/attempt-finalize.ts:228-406`、`src/agents/embedded-agent-runner/run/attempt-transcript-lifecycle.ts:21-209`。

### Gateway finalization

detached dispatch 完成后，Gateway 检查 reply payload 和 Agent run 是否已启动：

- Agent run 已启动时，正常 assistant turn 由 Agent runtime 写入 SessionManager；Gateway 只投影 live/source replies，避免把同一个 assistant turn再次 append。
- 没有 Agent run 的 command/non-agent 分支由 `finalizeChatSendNonAgentReplies` 先追加 assistant transcript，再广播最终回复。
- Agent 产生的 webchat media payload 根据 owned idempotency key 或 assistant message index rewrite 已存在的 assistant row；找不到安全的 owned row 时才使用带 run id 的 media fallback identity。
- 返回的 Agent error payload 会转成 Gateway `chat` error；成功路径写入 `chat:<clientRunId>` dedupe entry，后续相同幂等请求可以拿到缓存终态。

这组分支见 `src/gateway/server-methods/chat-send-agent-dispatch.ts:409-529` 和 `src/gateway/server-methods/chat-send-reply-dispatch.ts:132-410`。

`server-chat` 观察到 lifecycle `end/error` 后，根据统一 terminal outcome 分类为 success、timeout、cancellation 或 failure，再映射为 chat `done`、`error` 或 `aborted`。它先 flush 最后一段 paced text，再清理 chat state、run registry、event sequence 和 run context；session lifecycle persistence 在 Gateway session accessor 中写入，写入成功后才广播 `sessions.changed`，使订阅者看到的是写后的 canonical session row。见 `src/gateway/server-chat.ts:652-855`、`:1058-1121`，以及 `src/gateway/session-lifecycle-state.ts:179-225`、`:337-421`。

## 7. 停止、重试、续写与重新生成

### 停止和中断层级

`chat.abort` 先验证 session/agent scope 和 requester 权限，然后按 run id 查找 active controller、pre-registered dedupe、queued followup 或 worker inference。active run 的 abort 会先写 abort marker、关闭 session active projection、保留 terminal persistence ownership、释放 run delegated authority，再 abort controller；Gateway 随即广播带 partial text 的 `chat:aborted`，并发出 lifecycle end/cancelled。可见 partial text 的 transcript persistence 由 handler 另行调用。见 `src/gateway/server-methods/chat-abort-handler.ts:64-356`、`src/gateway/chat-abort.ts:619-705`。

attempt 把上游 abort relay 到 lane task 和 attempt controller，再转到 AgentSession.abort；若 compaction 正在进行，也会调用 `abortCompaction`。timeout 与用户 abort 共用 run abort owner，但 terminal outcome 记录不同的 phase，例如 prompt、compaction 或 tool execution。见 `src/agents/embedded-agent-runner/run/attempt-finalize.ts:450-625`。

Agent Core 收到 abort 后会创建 aborted assistant failure message，关闭当前 turn，并在不是 handoff abort 时追加 interrupted-turn message，最后仍发 `agent_end`。因此，停止既改变实时 chat projection，也可能留下可供后续历史恢复的中断 transcript evidence。见 `packages/agent-core/src/agent-loop.ts:295-327`、`:378-385`，以及 `packages/agent-core/src/agent.ts:577-587`。

### Provider、认证和上下文恢复重试

embedded run 的外层 retry loop 共享一个 run retry budget。认证 profile、provider fallback、同模型 timeout、provider overload、live model switch、Codex app-server recovery、context overflow 和 prompt failure 由不同 recovery controller 判定；可重试 attempt 会回到同一个 run loop，保留原始 session、run authority、usage accumulator 和 replay state。`normalizeEmbeddedRunAttempt` 先处理 preflight recovery，`recoverEmbeddedRunAttempt` 再处理 timeout/overflow/prompt failure，见 `src/agents/embedded-agent-runner/run-loop.ts:315-474`、`src/agents/embedded-agent-runner/run/attempt-normalization.ts:103-305`、`src/agents/embedded-agent-runner/run/attempt-recovery.ts:41-414`。

终态层还处理几种“模型没有形成可见终答”的情况：reasoning-only、空响应、缺失 assistant terminal、压缩后没有继续回答、`before_agent_finalize` 要求修订等。每类都有独立的 retry state 和上限；当 replay 不安全、已有副作用、已经向渠道发送消息或已有不可逆工具状态时，不会把该 turn 当作普通无副作用重放。见 `src/agents/embedded-agent-runner/run/terminal-resolution.ts:271-477`。

### 续写、steer 和 follow-up

Agent Core 的 `steer` 消息在下一次未启动的模型/工具边界前注入，运行中的工具可完成；`followUp` 在 Agent 原本即将结束时排空并开启后续 turn。串行工具批次会在每个调用前检查 steering，尚未启动的尾部调用生成 skipped tool result；并行批次也会为未启动调用生成可观察结果。见 `packages/agent-core/src/agent.ts:333-365`、`packages/agent-core/src/agent-loop.ts:330-506`。

OpenClaw 的 `chat.send` 额外支持当前运行中的 message injection、interrupt、followup 和 collect。Gateway 会在发送前或 queue admission 时捕获精确的 backend target；如果当前运行已经清除，该 target 不会重新解析 successor。Reply operation 通过 `attachBackend`、`abortByUser`、`supersede` 和 terminal barrier 管理这一层的 stop/steer 竞态，见 `src/auto-reply/reply/reply-run-registry.registry.ts:112-201`、`src/auto-reply/reply/reply-run-registry.operation.ts:445-559`。

## 8. 队列、多会话并发与后台生成

### 并发粒度

embedded runner 先按 session lane 串行，再进入 global lane；同 session 的 transcript、tool state 和 active Agent 不能并发写入。不同 session 可以在 global lane 的容量和其他准入条件允许时并行。Reply operation registry 以 canonical session key 维护 active slot，Gateway 的 session work admission 还覆盖 session alias、backing session id 和 transcript write owner。

### queue mode

`resolveActiveRunQueueAction` 将运行中新消息分为 run-now、enqueue-followup 或 drop：没有 active run 且无 pending queue 时立即运行；heartbeat 新 turn 在 active 状态下丢弃；reset 优先 interrupt/run-now；其余根据 followup/queue mode 入队。见 `src/auto-reply/reply/queue-policy.ts:4-33`。

followup queue 以 message id、route identity、reply anchor、chat type 和 queue policy 做去重和容量控制。steer candidate 会先获得一个 acceptance barrier；在 steer 尚未决定时到达的普通消息会停在 anchor 后面，避免旧 steer 的 fallback 判定期间丢失新消息。队列可按 drop-new、drop-old 或 summarize 处理容量压力，见 `src/auto-reply/reply/queue/enqueue.ts:124-283`。

collect mode 会按 delivery context、授权 participant、媒体、工具策略、provider/model、客户端 capability、source reply mode 和 turn lifecycle 分组。兼容的消息被合成为 `[Queued messages while agent was busy]` prompt，并用独立的 collected user turn transcript；跨渠道、runtime-only metadata、特殊 skill revision 或不同 admission owner 会拆成多个 group 或逐条 drain。实现见 `src/auto-reply/reply/queue/drain.ts:230-337`、`:431-515`、`:1263-1517`。

队列 drain 在 debounce、重试和 successor admission 期间可能已经脱离最初的请求。它创建 independent root work continuation，并在 drain 时重新取得当前 prepared model runtime generation；因此 parked turn 不继承前一个 run 的过期 generation。Gateway 为 ACK 后仍在 queue 中的 turn 保留 `chatQueuedTurns` cancel identity，使 `chat.abort` 能按原 run id 取消 queued work；collect aggregate 被 admission 后，取消权转移给 aggregate owner。见 `src/auto-reply/reply/queue/drain.ts:1551-1563`、`src/gateway/chat-queued-turns.ts:1-169`。

## 9. Agent、工具、知识库与附件注入点

### Agent、bootstrap 与 skills

Agent/harness 是 prepared model runtime 的一部分。attempt setup 先解析工作区、sandbox、permission root、effective cwd，再加载 skill snapshot、skill environment overrides、code-mode skill 和 bootstrap context files。bootstrap 文件可能来自 Agent workspace、执行 workspace 或 session-specific workspace；上下文文件和 truncation notice随后进入 system prompt。见 `src/agents/embedded-agent-runner/run/attempt-setup.ts:109-160`、`src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts:27-184`。

system prompt 构建会取得 runtime machine/model/channel 信息、渠道 action 与 message-tool hints、sandbox status、OpenClaw reference paths、tool schema directory、watched sessions、project memory bootstrap、skills prompt、bootstrap context files、owner/quiet/reasoning guidance 和 provider system-prompt contribution，再调用 `buildEmbeddedSystemPrompt`，最后执行 provider-specific system prompt transform。见 `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:54-378`、`src/agents/embedded-agent-runner/run/attempt-system-prompt.ts:23-59`。

### 工具目录

当前 attempt 的工具目录按运行上下文构建，而非从固定全局表直接复制：

1. 根据 model tool capability、disable/raw mode、runtime allowlist 和 message-tool/source-reply mode 决定要创建的 core tool family。
2. 构建 OpenClaw coding tools、channel/plugin tools、client tools、bundle MCP 和 bundle LSP runtime。
3. 创建 conversation capability profile，把 session、sender、group、channel、sandbox、workspace、skills、input provenance 和 model facts 传入工具构建。
4. 应用 final effective policy、local-model lean、runtime schema projection 和 tool execution allowlist。
5. 如果启用 Tool Search 或 Code Mode，把部分工具放入 run-scoped catalog，必要时在模型发出 deferred call 后再 hydrate。
6. 将最终工具和 deferred resolver 交给 AgentSession，再由 Agent Core 放入 `Context.tools`。

注入入口分别位于 `src/agents/embedded-agent-runner/run/attempt-tool-prepare.ts:58-241`、`src/agents/embedded-agent-runner/run/attempt-bundle-tools.ts:28-258`、`src/agents/embedded-agent-runner/run/attempt-tool-catalog.ts:42-217`。工具内部过滤、审批和执行语义见 [OpenClaw Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)。

### 记忆、知识库与项目信息

legacy/full prompt surface 会调用 `prepareAgentMemoryPrompt`，向 memory plugin 传递规范化的 available tools、citations mode、agent/session key 和 sandbox 状态；返回的 prepared memory prompt section 再作为 system prompt 的一部分。非 legacy Context Engine assemble 则在 `runWithPreparedMemoryPromptSection` 作用域中获得同一份 prepared memory context，避免 prompt builder 与 context engine 使用不同的工具集合。见 `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:230-257`、`src/agents/memory-prompt-prepare.ts:8-31`、`src/agents/harness/context-engine-lifecycle.ts:208-224`。

当前代码快照还在 full prompt path 发现 project memory bootstrap、project memory write instruction 和 watched sessions prompt。它们是本次 request 的注入交接点；memory corpus 的实际检索、索引和命中条件由 memory plugin/context engine 实现。本次没有把某个独立全局 RAG 服务确认成每个对话必经步骤，也没有据此推断每次请求都会发生检索。memory plugin registry 的 prompt/corpus 边界见 `src/plugins/memory-state.ts:70-245`。

### 附件与媒体

Gateway 先将 RPC attachments 归一化，解析出的图片可直接作为当前 turn image；无法进入模型 image input 的文件会以 structured media facts 和预 staged path 传递。用户 turn recorder 会把 durable media facts、image slots 和 omission marker 写入 transcript。attempt prompt execution 再根据 prompt 中的媒体引用、persisted media facts、image order、MAX_IMAGE_BYTES、尺寸限制、workspace-only 和 sandbox bridge 加载图片；provider transport 最终把可用媒体 materialize 成 Provider context。

plugin harness 的媒体路径更严格：host 只准备结构化 image input，任何无法 hydrate 的 structured image attachment 会使该 attempt 抛错，而不是让模型悄悄收到缺失附件。相关交接见 `src/agents/embedded-agent-runner/run/attempt-prompt-submit.ts:317-377`、`src/agents/embedded-agent-runner/run/run-attempt-dispatch.ts:201-245`、`src/agents/embedded-agent-runner/run/attempt-stream-settle.ts:514-533`。

## 10. 退出恢复、日志与已确认边界

### Gateway 重启、重连与生命周期 generation

Agent event、reply operation、abort controller 和 active embedded run 都带有 lifecycle generation 或等价 owner claim。Gateway restart 会使旧 generation 的 reply operations 被 eviction/abort；`server-chat` 对旧 generation 或不再 active 的 context claim 事件不再投影，以免旧进程的迟到 terminal 覆盖 successor。见 `src/auto-reply/reply/reply-run-registry.registry.ts:413-472`、`src/gateway/server-chat.ts:457-468`、`:1316-1335`。

普通 active run 的执行不会因为 Gateway 进程退出而继续拥有有效的 in-memory authority。可恢复的数据主要是 transcript 和 session lifecycle row。Control UI 的一部分简单 main turn满足 restart-safe 条件时，会为 message 与 owner 标记生成 HMAC request fingerprint，提交 durable restart claim；重启后的相同 request 通过 fingerprint、run id 和 expected session state adoption，而不会再次提交不同的用户 turn。恢复 claim、terminalization 和 retry 检查见 `src/gateway/server-methods/chat-restart-recovery.ts:105-220`、`:298-460`。

`server-chat` 的 terminal lifecycle persistence 先更新 session row 的 status、started/ended time、runtime、last error、last run id 和 lifecycle ownership，再广播 `sessions.changed`。如果客户端切换会话时仍有 visible chat-send run，`resolveInFlightRunSnapshot` 会从 active abort controllers 和 chat buffer 取得运行 id、partial text、plan 和 progress events；snapshot 与历史消息一起有 byte cap，超过时按 run adoption、timing、progress、plan、text 的顺序收缩。见 `src/gateway/chat-abort.ts:340-495`。

### 日志、trace、用量与诊断

请求会记录 Gateway diagnostics timeline span，例如 session load、attachment preparation、user transcript persistence、dispatch 和 post-dispatch；trace attributes带 run id、session key、agent、provider、model、附件和 client 信息。embedded attempt 发出 `run.started`/`run.completed` trusted diagnostic events，记录 prompt/system report、trajectory、compaction、usage、fallback attempts、prompt cache 和 terminal outcome。Provider usage 会累积到 attempt/run result，并按 lifecycle generation 发 usage agent event。对应入口见 `src/gateway/server-methods/chat-send-handler.ts:232-271`、`src/agents/embedded-agent-runner/run/attempt-setup.ts:590-636`、`src/agents/embedded-agent-subscribe.ts:208-253`。

### 设计取舍与已确认边界

- ACK 与 detached dispatch 分离，使客户端尽快获得稳定 run id，同时让 dispatch 继续持有 session admission、transcript persistence 和终态 cleanup。
- Transcript 使用 SQLite accessor、SessionManager 和 explicit parent chain；Gateway 的 user-turn recorder 只负责把入口输入适配到这条 canonical 写入路径。
- 当前 turn 的 bare transcript prompt 与 model-only context 分开，动态 inbound metadata、hook context、sender projection 和 runtime context不会自动污染用户原文。
- Context Engine 可以拥有 assemble/compaction/after-turn，但 host 仍负责 transcript fence、run authority、bounded timeout 和不兼容时的本轮降级。
- Provider stream 的原始事件、Agent Core message lifecycle、Gateway `agent` event 和 Gateway `chat` payload 是不同投影面；一个面上的更新频率不能代替另外两个面的持久化语义。
- 正常 assistant transcript 与 Gateway live reply 分离；非 Agent reply、媒体补写、abort partial 和 source reply mirror 使用专门 finalization 路径来维持幂等。
- 工具循环允许并行/串行批次、steer、follow-up 和 collect，但 session transcript/write admission 仍是串行 owner；跨 route 或不同授权上下文的 queued items 不会被强行聚合。

## 11. 未验证事项

1. 未运行真实 `chat.send`、Provider stream、tool call、MCP、plugin harness、channel delivery 或 Control UI 重连场景；上述行为来自当前代码快照的静态路径。
2. 未验证不同 Provider 对 cumulative `text_end`、thinking/tool-call 增量、媒体 materialization、abort 和 timeout 的实际事件时序。
3. 未验证 session lane/global lane 在实际配置下的并发容量、长时间工具调用和 queue collect 的端到端可见顺序。
4. 未运行 context overflow、自动压缩、Context Engine 降级、压缩后 continuation、timeout salvage 或 restart-safe Control UI retry。
5. 未连接 memory plugin、项目记忆或独立 Context Engine，因此只确认 prompt/corpus/assemble 交接点，不能确认具体检索命中率、索引内容或每次请求的实际检索结果。
6. 未验证图片、PDF、late-media、sandbox staging 和 provider image input 在真实模型请求中的字节/token 成本及失败文案。
7. 未验证 Gateway 退出时 terminal session persistence、trajectory flush、pending async tool settlement 和 successor admission 的竞态。
8. `agent-core` 工具循环的参数校验、审批、并行结果回注和工具恢复细节只在本链路确认调用位置；完整工具语义留在相邻调查笔记。

## 12. 关键源码索引

- `src/gateway/server-methods/chat-send-handler.ts:38-303`：`chat.send` 准入、ACK 和 detached dispatch handoff
- `src/gateway/server-methods/chat-send-request.ts:83-194`、`chat-send-session.ts:33-212`：请求规范化、session/model/agent 解析
- `src/gateway/server-methods/chat-send-admission.ts:48-563`：dedupe、session work admission、abort owner、restart claim
- `src/gateway/server-methods/chat-send-attachments.ts:181-305`、`chat-send-user-turn.ts:186-269`：附件与 Gateway user turn 构建
- `src/gateway/server-methods/chat-send-agent-dispatch.ts:219-401`、`:409-559`：ACK 后的 reply dispatch、Agent run callbacks 和最终投影
- `src/auto-reply/dispatch.ts:198-266`、`src/auto-reply/reply/dispatch-from-config.ts:23-113`：auto-reply dispatch pipeline
- `src/auto-reply/reply/get-reply-run-context.ts:63-487`、`get-reply-run-admission.ts:59-651`、`get-reply-run-execute.ts:57-618`：prompt envelope、queue admission、FollowupRun 与 Agent runner 交接
- `src/agents/embedded-agent-runner/run-orchestrator.ts:83-484`、`run-loop.ts:71-725`：prepared runtime、session/global lane、attempt retry loop
- `src/agents/embedded-agent-runner/run/attempt.ts:57-579`、`attempt-execution-phase.ts:25-254`：单 attempt 的 setup、history、prompt、stream 和 settle 编排
- `src/agents/embedded-agent-runner/run/attempt-session-prepare.ts:273-585`：SessionManager、LLM boundary、transcript policy 和当前 user turn 关联
- `src/agents/embedded-agent-runner/run/attempt-history.ts:396-641`、`attempt-prompt-build.ts:110-424,478-684`：历史清理、Context Engine assemble、hook/runtime/model prompt 分流
- `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:54-378`、`attempt-tool-prepare.ts:58-241`、`attempt-bundle-tools.ts:28-258`：system prompt、工具和外部能力准备
- `src/agents/embedded-agent-runner/run/preemptive-compaction.ts:216-407`、`attempt-prompt-preflight.ts:160-275`：预算预检和压力路线
- `src/agents/sessions/agent-session-compaction.ts:278-459`、`src/agents/embedded-agent-runner/run/compaction-runtime.ts:71-180`：session/outer compaction recovery
- `src/context-engine/types.ts:346-505`、`src/agents/harness/context-engine-lifecycle.ts:98-400`、`src/context-engine/legacy.ts:7-39`：Context Engine 合同、host lifecycle 与 legacy delegate
- `packages/agent-core/src/agent.ts:209-298,398-479,552-656`、`packages/agent-core/src/agent-loop.ts:226-613`：Agent 状态、Provider 请求和工具/回合循环
- `src/agents/embedded-agent-subscribe.ts:57-755`、`embedded-agent-subscribe.handlers.ts:28-157`、`embedded-agent-subscribe.handlers.messages.lifecycle.ts:118-325`：AgentSession 事件订阅、usage、可见回复和工具状态
- `src/gateway/server-chat.ts:435-875,877-1121,1288-1729`、`server-methods/chat-broadcast.ts:88-179`：Gateway agent/chat 事件、缓冲、终态和广播
- `src/agents/sessions/agent-session-base.ts:346-459`、`src/agents/sessions/session-manager-entries.ts:128-170`、`src/sessions/user-turn-transcript.ts:251-321,363-706`：消息 end 持久化、parent chain 和 user-turn 幂等
- `src/gateway/chat-abort.ts:619-705`、`src/gateway/server-methods/chat-abort-handler.ts:64-356`：active/queued abort、partial persistence 和授权
- `src/auto-reply/reply/queue-policy.ts:4-33`、`queue/enqueue.ts:124-283`、`queue/drain.ts:1263-1563`、`src/gateway/chat-queued-turns.ts:1-249`：队列策略、collect/steer、独立 drain 和取消身份
- `src/gateway/server-methods/chat-restart-recovery.ts:105-220,298-460`、`src/gateway/session-lifecycle-state.ts:179-225,337-421`：restart-safe claim、生命周期持久化和恢复边界
