# OpenClaw 对话请求与上下文调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：直接阅读 Gateway、auto-reply、embedded-agent-runner、Context Engine、Agent Core、转录持久化和流式事件处理源码；以可执行调用关系核对入口、状态转移和结果处理，未运行真实 Provider 或对话场景
>
> 调查范围：提交入口与准入、历史和上下文拼装、预算与压缩、Provider/Agent 交接、流式事件、最终回写、停止重试、队列并发、工具/记忆/附件注入、退出恢复与可观测性；会话存储 schema、Chat UI 工作流、工具内部执行语义和具体渠道适配分别保留在相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的一次可见对话由 Gateway `chat.send` 负责请求规范化、会话解析、运行准入和 ACK。ACK 前完成需要同步确认的身份、幂等、路由、附件预处理和取消边界；ACK 后把用户 turn 交给脱离 RPC 生命周期的 dispatch，继续完成回复路由、Agent run、流式投影和终态持久化。主入口见 `src/gateway/server-methods/chat-send-handler.ts`。

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

`normalizeChatSendRequest` 是入口处的规范化工序：先校验 Gateway 协议字段，再把消息正文、来源标记、停止命令和附件整理成统一结构。有几类输入需要额外授权，各自另走检查——系统注入的 provenance、显式声明的 originating route、命令解释抑制和浏览器 copilot 工具绑定，分别对应权限检查或配对客户端检查；其中配对客户端由 Gateway 判定，绑定 schema 的具体校验落在浏览器插件。整理结果同时保留原始文本、发给 Agent 的文本、turn 类型（turn kind）、附件和重连恢复标记，见 `src/gateway/server-methods/chat-send-request.ts`。

`prepareChatSendSession` 通过 session accessor 读出会话行。请求不在全局 scope 时，如果客户端只给了一个裸 `global` 再配上 agent id，系统会先把它映射到该 Agent 的 main session，免得重连时又建出一份字面量为 `global` 的 transcript。接下来这一层要定下目标 Agent 与 session、用哪个模型和认证 provider、超时多久、预期的 leaf，以及这次请求能否按 restart-safe 处理，见 `src/gateway/server-methods/chat-send-session.ts`。

### 运行身份与状态投影

一次 `chat.send` 直接拿请求里的 `idempotencyKey` 当本次运行的 clientRunId。准入阶段先在去重表里占位：写入一条 pending 记录，带上 attempt 编号、占位所用的连接与设备、过期时间和 `accepted` 状态，写完才去申请会话运行权。拿到准入锁后，代码把这条请求重新核对一遍——reservation 是否仍归它、生命周期 generation 有没有换代、会话路由与 active leaf 是否还对得上、restart claim 有没有被别人认领。全部通过才注册 abort controller，并把 Gateway 的 run context 绑到 session 上。状态与所有权逻辑见 `src/gateway/server-methods/chat-send-admission.ts:325-563`。

同一个请求在不同层有不同身份：

| 层 | 主要身份 | 可观察状态或作用 |
|---|---|---|
| Gateway | `clientRunId` / `idempotencyKey` | pending、started、终态 dedupe、abort marker |
| Reply operation | session key + operation object | queued、waiting for maintenance/global lane、running、aborted、completed、failed |
| Agent Core | `runId` 和 `activeRun` | `isStreaming`、message/tool lifecycle、`agent_end` |
| Session lifecycle | session row 的 lifecycle run id | running、done、timeout、killed、failed |
| Gateway chat stream | `chat` event state | status、delta、final、error、aborted |

运行入口还会在 `replyRunRegistry` 里登记一个 operation。这个 operation 以 session key 占住同会话的运行槽，同时挂上 backend、上游 abort signal、tool authority 和 successor barrier；它的清理要等对应的 terminal/delivery barrier 到达才能做，这样同一 session 的后续 turn 就不会在旧 owner 还在写 transcript 时挤进来。见 `src/auto-reply/reply/reply-run-registry.operation.ts`、`:475-723`。

## 2. 历史选择与上下文拼装顺序

### ACK 前的输入上下文

附件解析落在 Gateway 准入之后、ACK 之前。`parseMessageWithAttachments` 先把文本里的附件标记拆出来；图片能不能进模型，由当前 session 的模型或显式指定的 plugin/ACP route 决定。非图片文件可以预先放进 sandbox workspace，managed PDF 在特定条件下保留 host-readable path。附件本身有永久错误时，ACK 之前就返回 invalid request；只是暂存失败则返回 unavailable；offload 出去但正文没有引用的媒体，由准入清理阶段丢弃。附件准备的主要入口见 `src/gateway/server-methods/chat-send-attachments.ts`、`:181-305`。

`createGatewayChatUserTurnController` 把用户这次输入包成一个 turn 对象，原始文本、到达时间、幂等键 `${runId}:user`、发送者、owner 标记、回复目标和 provenance 都随对象一起保存。另一处入口 `prepareChatSendUserTurn` 再往这个 turn 上绑定图片的持久化 promise、媒体信息、媒体布局和可移植的消息上下文。普通 turn 的 transcript 写入可以推迟到 ACK 之后；restart-safe 的 Control UI turn 必须在 ACK 前完成 durable admission，Gateway 重启后重试才能认出是同一个用户 turn。见 `src/gateway/server-methods/chat-user-turn-recorder.ts` 和 `src/gateway/server-methods/chat-send-user-turn.ts`。

### Agent attempt 中的历史恢复

每个 embedded attempt 都拿到一份自己的 SessionManager 视图，不过它们背后是同一份 SQLite transcript，由准入锁和 session target 保护。准备阶段（`prepareEmbeddedAttemptSessionManager`）先把已有 transcript 读出来，解析当前 runtime 的 transcript policy，再用 `guardSessionManager` 把能力收窄：允许哪些工具、如何合成 tool result、当前 user turn 怎么持久化、错误消息怎么落库，都在这层限定。向 SessionManager 追加消息时会新建一条带 `parentId` 的 transcript entry，leaf 跟着当前 active branch 走；如果新 user entry 自带幂等键，而分支上已经有对应的 canonical entry，就改为复用那条已有条目。见 `src/agents/embedded-agent-runner/run/attempt-session-prepare.ts`、`src/agents/sessions/session-manager-entries.ts`。

历史进入模型前大致经过以下顺序：

1. SessionManager 恢复 active branch；raw model run 则清空 Agent 内存历史并只保留原始 probe prompt。
2. 普通 attempt 先对历史做 sanitize 和 replay validation：去掉不允许重放的结构，修好工具调用与结果之间的配对。
3. 接着轮到模型候选历史，依次受 quota recovery、heartbeat artifact 过滤、历史 turn 数量上限和又一次 tool-use/result 配对修复影响。
4. session 正处于 quota resuming 时，会加入 hierarchy reinforcement；活动 subagent 的信息可以追加到 system prompt。
5. 如果存在 Context Engine，它接收当前候选消息、可用工具、memory citation mode、model、prompt 和 token budget，返回组装好的消息，以及可选的 system prompt addition。
6. prompt assembly 再叠加当前 turn 的 inbound context、runtime context、heartbeat outcome、hook context、steering 和 inter-session provenance。
7. LLM boundary 最后一步，把时间 envelope、群组 sender context 和当前 user turn 的持久化 metadata 投影到面向 provider 的 messages，再交给 `convertToLlm` 转成 Provider 消息。

历史清理和 Context Engine assemble 的实际入口见 `src/agents/embedded-agent-runner/run/attempt-history.ts`；单一 LLM boundary 的安装见 `src/agents/embedded-agent-runner/run/attempt-session-prepare.ts`。

### transcript prompt 与 model prompt

同一个当前 turn，OpenClaw 留了两份文本。一份是要落进 transcript 的，叫 `promptForSession`，它代表用户当时说的话；另一份是要发给模型的，叫 `promptForModel`，可以比前者多带运行时上下文。普通用户 turn 尽量只把裸 prompt（bare prompt）存进 transcript，当前这轮的 inbound metadata 则通过 runtime-context custom message 或模型边界投影交给模型；runtime-only turn 根本没有对应的裸 user entry，inbound context 只能同时内联进模型 prompt 和 transcript prompt。prompt build hook 在前后加的 context 也可以只进 model prompt，这样动态 hook 内容不会变成用户原文。该分流由 `prepareEmbeddedAttemptPromptContext` 完成，见 `src/agents/embedded-agent-runner/run/attempt-prompt-build.ts`。

要把当前用户的 timestamp、sender context 与某条 transcript message 对上，代码先比对象身份，对不上再拿 timestamp 和文本做结构匹配。这样同一个用户 turn 在“当前这次 prompt”和“下一次重放历史”两个时刻会得到同一份 LLM-boundary 表示，transcript 里存的裸字节（bare bytes）保持原样。sender projection 只在已有持久化 sender metadata 的 turn 上生效；inter-session provenance 则固定放在模型可见文本的首要安全位置，见 `src/agents/embedded-agent-runner/run/attempt-history.ts`、`:309-340`。

## 3. 预算、截断、摘要与压缩

### 预算来源

embedded runtime 解析上下文预算 `contextTokenBudget` 时看三样东西：model catalog、配置里的 context cap，以及 provider/harness 实际能处理多少。如果配置 cap 比模型原始 context window 还小，effective model 的窗口会一并收窄，于是 AgentSession 判断要不要压缩、以及真正发给 provider 的请求，用的是同一个上限。预算解析见 `src/agents/embedded-agent-runner/run/setup.ts`、`:287-310`。

每个 prompt 都会预留一段 compaction reserve。历史组装时可用的 message 预算，大致是 `contextTokenBudget` 减去 `reserveTokens`，再减去渲染后的 system/prompt 压力；工具结果另有字符上限，单项和累计都按 context window 计算。发给 Provider 之前，还会对 provider message history 再做一次 tool-result truncation；`markSessionUserTurnsSent` 之后，迟到的媒体结果不能再改写已经越过 Provider 边界的 prompt-cache tail。见 `src/agents/embedded-agent-runner/run/attempt-history.ts`、`src/agents/embedded-agent-runner/run/attempt-prompt-submit.ts`。

### 预检与截断路线

`shouldPreemptivelyCompactBeforePrompt` 做的是压力估算，输入包括消息边界、system prompt、当前 prompt、工具结果、分支/压缩摘要，以及 provider 侧报告过的 context usage。只要拿到 provider 给出的已知总量，就先信这个数，再往上估新边界。估算结果落在四条路线之一：

| 路线 | 含义 |
|---|---|
| `fits` | 当前估算未超过扣除 reserve 后的 prompt budget |
| `truncate_tool_results_only` | 可裁减的工具结果足以覆盖压力 |
| `compact_only` | 没有足够可裁减工具结果，需要压缩 |
| `compact_then_truncate` | 先压缩，再继续处理工具结果压力 |

这一步会写入 `contextBudgetStatus` 和诊断日志；当前实现把它定位成压力诊断（pressure diagnostic），`prepareEmbeddedAttemptPromptPreflight` 只负责判断和分流，真正的压缩和历史删除留给后续阶段执行。实际 preflight 与中途请求的路由见 `src/agents/embedded-agent-runner/run/preemptive-compaction.ts`、`src/agents/embedded-agent-runner/run/attempt-prompt-preflight.ts`。

工具结果还会被 context pruning 的 cache-TTL 模式清掉一部分；历史图片则在 prompt transform 阶段，按模型能否读图以及 workspace/sandbox 根重新加载或裁减。这些 transform 只作用于本次 provider context，落盘的 transcript 由上层 SessionManager 决定保留什么。

### 实际压缩和恢复

AgentSession 检查 compaction 的时机有两个：agent turn 结束后，以及下一次 prompt 之前。遇到同 model 的 context overflow error/length response 时，如果当前 owner 允许 session 侧恢复，它会把错误 assistant 的模型上下文移除，compact 一次再自动 retry。平时达到 context threshold 也会执行 auto-compaction，不过普通阈值压缩只影响后续请求，已经完成的 prompt 不会因此重跑。`src/agents/sessions/agent-session-compaction.ts` 展示了这两种分支。

如果 context budget 已经由 caller 明确算好，embedded runner 就把 overflow recovery 的 owner 记成 caller。外层恢复流程会先给 Context Engine 准备一份 runtime context，里面带着 provider/model/auth、当前 token 数、prompt cache、workspace、工具策略和 session target，然后在安全超时内调用 `compact(..., force: true, compactionTarget: "budget")`；压缩返回的 successor session target、session id 或 legacy locator 会被采用，接着重试当前 transcript。见 `src/agents/embedded-agent-runner/run/compaction-runtime.ts`、`src/agents/embedded-agent-runner/run/attempt-session-prepare.ts`。

压缩结果写入 compaction entry 之后，SessionManager 会重建 active branch 的上下文，再用 replay-safe 的消息替换 Agent 内存里的历史。压缩过的 attempt 如果没有产出最终可见回答，terminal resolution 还会追加一次内部 prompt，意思是“从压缩后的 transcript 接着把回答写完”；一旦已有工具副作用，或者重放不安全，普通 provider retry 就不再按无副作用重放处理。终态恢复逻辑见 `src/agents/embedded-agent-runner/run/terminal-resolution.ts`。

### Context Engine 边界

Context Engine 是插件化的生命周期接口，把一轮 turn 拆成若干可介入的钩子：bootstrap、maintain、afterTurn/ingest、commitTurn、assemble、compact，以及 subagent 生命周期。Host 通过 `ContextEngineHostCapability` 声明自己支持哪几项，比如 bootstrap、assemble-before-prompt、after-turn、compact；如果 host 还负责录制用户 turn，则额外要求当前 turn fence 与原子化的幂等推进。见 `src/context-engine/types.ts`、`src/agents/harness/context-engine-logical-turn.ts`。

一个逻辑 turn 开始时，先解析配置里指定的 engine，再看当前 Agent harness 支持哪些 host 能力来决定用谁。如果配置的是非 legacy engine 而 harness 不兼容，本轮就降级到 fallback engine，下一轮再试配置的那个，配置本身原样保留。bootstrap 和 maintenance 都在 transcript read fence 下执行，assemble 同样受当前 turn fence 约束。见 `src/agents/harness/context-engine-logical-turn.ts`、`src/agents/harness/context-engine-lifecycle.ts`。

legacy engine 的职责很窄：`ingest` 不写自己的存储；`assemble` 把 messages 原样返回，`estimatedTokens` 固定为 0；sanitize、validate、limit、repair 这批管线仍由 attempt 负责；`compact` 则 delegate 到 OpenClaw 内置的 compaction runtime。所以 assemble 的透传只说明这一层不做组装，预算和 provider-boundary precheck 依然在 runner 里执行。见 `src/context-engine/legacy.ts`。

非 legacy engine 只在 turn 成功、没被 abort、也没有 prompt error 时收到 `afterTurn`。engine 没有实现这个方法时，host 改为把新增消息批量或逐条摄入，再跑一次 maintenance。如果 engine 声明支持 durable turn advancement，host 就会把用户的 admission anchor 和 terminal anchor 作为 `commitTurn` 的候选交给它，engine 不必自己再猜 transcript leaf。见 `src/agents/harness/context-engine-lifecycle.ts` 和 `src/agents/embedded-agent-runner/run/attempt-finalize.ts`。

## 4. SDK、Provider、模型与协议交接

### Reply runtime 到 embedded runner

回复派发入口 `dispatchReplyFromConfig` 把一次回复拆成串行流水线：先收集请求并确定投递方式，再准备 operation 及其上下文，然后选择路由、准备执行，最后做 audit 与 delivery。Gateway 内部的 webchat 走另一条入口，改用 projected message delivery hooks，把 Agent 运行结果交给 Gateway 自己的 `ReplyDispatcher`。两个入口见 `src/auto-reply/dispatch.ts:472-482` 和 `src/auto-reply/reply/dispatch-from-config.ts`。

`executePreparedReplyRun` 把当前 turn 固化成一个 `FollowupRun`，字段大致分三组：文本与媒体（transcript prompt、当前 inbound context、媒体）、权限与路由（渠道准入证据、工具 allowlist、skills 快照、来源路由、发送者与群组字段）、运行参数（provider/model、thinking/verbose/fast 模式、sandbox 和 `sessionKey`）。整份对象随后交给 `runReplyAgent`，从 auto-reply 进入 channel/embedded Agent runner 的交接点见 `src/auto-reply/reply/get-reply-run-execute.ts`。

`runEmbeddedAgent` 先确定有效的 session target，然后排队：同 session lane 在前，global lane 在后；已经准备好的 deferred context maintenance 在进 global lane 之前跑完。轮到它之后，再决定走 CLI backend 还是 native embedded backend，并解析 workspace、agent directory、model candidate chain、plugin metadata snapshot 和 prepared model runtime。provider/model/harness/auth 的准入在进入 retry loop 前一次性建立，后面的 retry 和 fallback 都复用这份 admitted run context，authority 不会另建一份。见 `src/agents/embedded-agent-runner/run-orchestrator.ts`、`:219-343`，以及 `src/agents/embedded-agent-runner/run-loop.ts`。

### Agent Core 与 Provider

每个 attempt 的 transport 由 `prepareEmbeddedAttemptTransport` 装好。它依次处理额外参数、provider stream 注册、API key、prompt-cache 状态、provider 文本 transform、媒体 materialization 和 transport override，必要时再包一层 native web-search；最后把得到的 stream function 挂到 `AgentSession.agent` 上。见 `src/agents/embedded-agent-runner/run/attempt-stream-settle.ts`。

Agent Core 的模型交接固定为：

1. 读取 Agent 内存中的 system prompt、transcript messages 和 tools。
2. 跑一遍 `transformContext`，对 provider 历史做工具结果截断、cache-TTL 清理，并投影图片、computer frame 等运行时内容。
3. 把消息结构规整后调用 `convertToLlm`，得到面向 Provider 的消息数组。
4. 以 `Context` 对象调用 `streamFn`，API key 在请求时解析，abort signal 随请求传递。
5. 把 Provider 的 start、text/thinking/toolcall 增量、done/error，重新组合成 assistant message 和 AgentSession 事件。

上面几步落在 `packages/agent-core/src/agent-loop.ts`。`Agent` 对象自己持有当前 transcript、system prompt、tools、active run 和两个队列；它在 `runWithLifecycle` 里设置 streaming 状态，等 `agent_end` 事件的监听器全部 settle 之后才清除 active run，见 `packages/agent-core/src/agent.ts:466-575`。

### Harness 分界

默认的 OpenClaw harness 直接用上面这套 Agent Core 工具、SessionManager 和 Provider stream。model runtime 选了别的 harness 时，该 attempt 交给 `runAgentHarnessAttempt`；host 依旧把 session target、transcript recorder、context engine、tool authority、媒体和 lifecycle callback 递过去。plugin harness 可以自带 transport 和 tool materialization，host 这边留下通用准入、终态和审计边界。attempt backend bridge 见 `src/agents/embedded-agent-runner/run/backend.ts`。

## 5. 流式事件、缓冲、节流与顺序

### AgentSession 内部事件

prompt 开始时，Agent Core 先发 `agent_start` 和 `turn_start`，并为用户消息补一对 message start/end；模型每响应一次，assistant 消息走一遍 start、update、end，工具执行同样走三段；回合收尾发 turn end，整次 run 的收尾是 `agent_end` 事件。assistant 的 message end 先落进 AgentSession 的内存消息，再交给监听器往下处理。主循环与事件归约的实现见 `packages/agent-core/src/agent-loop.ts` 和 `packages/agent-core/src/agent.ts`。

embedded subscriber 给每个 AgentSession 装一套事件处理器。大多数事件排进串行的 `pendingEventChain`，让异步格式化、block flush、usage 和回复 payload 都按事件顺序收口；`tool_execution_end` 走 detached 调度，工具终态在执行生命周期里已经记下，不必卡在核心结束事件前面。见 `src/agents/embedded-agent-subscribe.handlers.ts`。

assistant message handler 手上维护几样状态：raw text、可见 text、thinking、reply directive、media、block chunk 和 usage。Provider 有可能在 `text_end` 重复发送整段文本，也可能迟到发送；处理器只追加没见过的后缀，并把 message start 当作新的 usage 与可见文本边界。到 message end，再统一完成 directive 解析、可见 payload、reasoning 和 block flush。见 `src/agents/embedded-agent-subscribe.handlers.messages.stream.ts`、`src/agents/embedded-agent-subscribe.handlers.messages.lifecycle.ts`。

### Agent event 与 Gateway chat 投影

subscriber 把 lifecycle、assistant、thinking、tool、compaction、usage 这些运行信息交给 `emitAgentEvent`，由它写入 `infra/agent-events`；reply payload 另走 auto-reply/Gateway dispatcher。`server-chat` 为每个 run 维护序号、chat buffer、agent 文本缓冲、plan/progress 快照和 tool-event 订阅者，generation 或 owner claim 已经失效的事件会被直接丢掉，见 `src/gateway/server-chat.ts`。

Gateway 的可见投影有几层：

| 事件来源 | Gateway 行为 |
|---|---|
| assistant visible text | 合并 cumulative text 和 delta，写入 chat buffer，再生成 `chat` state `delta` |
| thinking/assistant agent event | Control UI 走 `agent` stream；75ms 内的文本事件按 stream 合并 |
| tool event | 具备 tool-events capability 的 WS recipient 收到完整 agent event；渠道/节点是否收到详情由 verbose 控制 |
| run status | `preparing_workspace`、`preparing_context`、`starting_model` 等转成 `chat` status |
| lifecycle start/end/error | 更新 session lifecycle、结束 chat run，并触发 final/error/aborted projection |

文本节流的窗口是 75ms。新文本如果仍以已广播内容为前缀，就只补发新增后缀；Provider 返回的文本一旦不再以前次 broadcast 内容开头，就发 `replace`，免得乱序或 cumulative/full-content 事件把内容重复一遍。工具或 item 开始、以及终态之前，会先把待发文本 flush 出去。见 `src/gateway/server-chat.ts`、`:1162-1259`、`:1453-1647`。

### 订阅范围

Control UI 可以按 session 注册 tool-event 订阅者；这类 session-scoped 订阅者能在运行开始后再加入，从 `session.tool` 镜像工具生命周期。普通 channel/node 订阅者主要拿到三类内容：按 verbose 策略过滤后的 tool payload、assistant live chat 和最终回复。heartbeat run 的 ACK/noise 和 tool event 会按 heartbeat visibility 隐藏，但它的 lifecycle 仍然进入内部状态。见 `src/gateway/server-chat.ts`。

## 6. 完成、异常、半截流与最终回写

### 消息持久化

AgentSession 在 `message_end` 上挂扩展 hook，并负责持久化。用户消息、assistant 消息和 toolResult 都经 `SessionManager.appendMessage` 写入 `SessionMessageEntry`；custom message 换走 `appendCustomMessageEntry`。用户消息要等 append 成功之后才 publish；assistant entry 落盘后，持久化的 message metadata 会回填到当前内存对象。见 `src/agents/sessions/agent-session-base.ts`。

`SessionManager.appendMessageWithTranscriptAnchor` 给 entry 补上 `parentId`、时间和消息 id。如果当前 active branch 上已经有同一 user idempotency key 的条目，就 adopt 那条 user entry，不再追加平行 turn。agent transcript message 一律经过 SessionManager/accessor 这层封装写入，缺少 `parentId` 的 JSONL message 不在允许的写入路径上。见 `src/agents/sessions/session-manager-entries.ts`，以及 `src/sessions/user-turn-transcript.ts`。

Gateway 这一侧的幂等包装器是 user-turn recorder。它把自身与嵌套的 transcript 写入串行化，记下 admission anchor，等图片/媒体 promise 就绪，再按目标 session 的 expected id 和 session state 调用 `persistSessionTranscriptTurn`。如果用户文本已经跨过 Provider boundary 之后才补来媒体，recorder 会保留先前 admitted 的那条 message，另以 late-media entry 追加媒体记录，已经发出去的 prompt-cache tail 因此保持原样。见 `src/sessions/user-turn-transcript.ts`。

### Attempt settle 与 after-turn

attempt settle 要等三样东西收口：必须完成的异步工具（completion-required async tools）、compaction retry，以及还没处理完的 subscriber 事件。timeout 恰好落在 compaction 中时，它改用 pre-compaction snapshot，半写入的压缩视图不会成为终态。之后收集 assistant/tool snapshot、usage、prompt cache 和 tool-search transcript projection；遇到 prompt error 则追加一条 `openclaw:prompt-error` custom entry。见 `src/agents/embedded-agent-runner/run/attempt-stream-settle.ts`。

只有当 turn 没有 prompt error、没有被 abort、也没有 yield 时，Context Engine 的 after-turn/ingest 和 maintenance 才会先跑起来。接着可以记一条表示 bootstrap 已完成的 custom entry，并执行 Agent end 的 side effects。attempt 最终产出一份结果，里面带 terminal outcome、usage、prompt、system prompt 报告、tool summary、fallback trace、compaction 次数和 delivery 证据。transcript 的写入由 attempt transcript lifecycle 串行化，cleanup 有 30 秒的 teardown 预算。见 `src/agents/embedded-agent-runner/run/attempt-finalize.ts`、`src/agents/embedded-agent-runner/run/attempt-transcript-lifecycle.ts`。

### Gateway finalization

detached dispatch 完成后，Gateway 检查 reply payload 和 Agent run 是否已启动：

- Agent run 已经启动时，正常的 assistant turn 由 Agent runtime 写进 SessionManager，Gateway 只做 live/source reply 投影，同一个 assistant turn 不会再次 append。
- 没有 Agent run 的 command/non-agent 分支由 `finalizeChatSendNonAgentReplies` 先追加 assistant transcript，再广播最终回复。
- Agent 产出的 webchat 媒体 payload，会按自己持有的 idempotency key 或 assistant message index 去改写已存在的 assistant row；只有找不到属于自己的安全 row 时，才退到带 run id 的 media fallback identity。
- 返回的 Agent error payload 会转成 Gateway `chat` error；成功路径写入 `chat:<clientRunId>` dedupe entry，后续相同幂等请求可以拿到缓存终态。

这组分支见 `src/gateway/server-methods/chat-send-agent-dispatch.ts` 和 `src/gateway/server-methods/chat-send-reply-dispatch.ts`。

server-chat 收到 lifecycle 的 end 或 error 后，先把结果归成 success、timeout、cancellation 或 failure，再映射到 chat 侧的 `done`、`error`、`aborted` 三种终态。收尾时它先 flush 最后一段 paced text，清掉 chat state、run registry、event sequence 和 run context；session lifecycle 由 Gateway session accessor 持久化，写成功之后才广播 `sessions.changed`，订阅者拿到的是写后的 canonical session row。实现见 `src/gateway/server-chat.ts:1058-1121` 和 `src/gateway/session-lifecycle-state.ts:337-421`。

## 7. 停止、重试、续写与重新生成

### 停止和中断层级

`chat.abort` 先看 session/agent scope 与请求者权限过不过，再按 run id 去找 active controller、pre-registered dedupe、queued followup 或 worker inference。命中 active run 时，中止动作按顺序做四件事：写 abort marker、关闭 session 的 active projection、保留 terminal persistence 的所有权、释放 run 的 delegated authority，最后才 abort controller。Gateway 随即广播带 partial text 的 `chat:aborted`，并发 lifecycle 的 end/cancelled。可见 partial text 的 transcript 落库由 handler 另外调用。见 `src/gateway/server-methods/chat-abort-handler.ts`、`src/gateway/chat-abort.ts`。

attempt 把上游 abort 逐层 relay 到 lane task 和 attempt controller，最后落到 AgentSession.abort；compaction 正在跑时，还会调用 `abortCompaction`。timeout 与用户 abort 共用同一个 run abort owner，区别在于 terminal outcome 会记下不同的 phase，例如 prompt、compaction 或 tool execution。见 `src/agents/embedded-agent-runner/run/attempt-finalize.ts`。

Agent Core 收到 abort 后，先造一条 aborted assistant failure message，关掉当前 turn；只要这次不是 handoff abort，还会补一条 interrupted-turn message，最后照样发 `agent_end`。所以停止操作既改变了实时 chat projection，也可能在 transcript 里留下中断证据，供后续历史恢复使用。见 `packages/agent-core/src/agent-loop.ts`、`:378-385`，以及 `packages/agent-core/src/agent.ts`。

### Provider、认证和上下文恢复重试

embedded run 的外层 retry loop 共用一个 run retry budget。几类失败各有自己的 recovery controller 判定：认证 profile、provider fallback、同模型 timeout、provider overload、live model switch、Codex app-server recovery、context overflow 和 prompt failure。判定为可重试的 attempt 回到同一个 run loop，原来的 session、run authority、usage accumulator 和 replay state 都保留。`normalizeEmbeddedRunAttempt` 先做 preflight recovery，`recoverEmbeddedRunAttempt` 再处理 timeout/overflow/prompt failure，见 `src/agents/embedded-agent-runner/run-loop.ts`、`src/agents/embedded-agent-runner/run/attempt-normalization.ts`、`src/agents/embedded-agent-runner/run/attempt-recovery.ts`。

终态层另外处理几种“模型没形成可见终答”的情况：只有 reasoning、空响应、缺 assistant terminal、压缩后没继续回答、`before_agent_finalize` 要求修订等。每类都有独立的 retry state 和次数上限。一旦 replay 不安全、已有副作用、消息已经发到渠道，或者工具状态不可逆，这个 turn 就不按普通的无副作用重放处理。见 `src/agents/embedded-agent-runner/run/terminal-resolution.ts`。

### 续写、steer 和 follow-up

Agent Core 的 `steer` 消息会挑下一次尚未启动的模型/工具边界注入，正在跑的工具可以自然完成；`followUp` 则等 Agent 原本就要结束时排空，再开启一个后续 turn。串行工具批次在每个调用前都会检查 steering，没来得及启动的尾部调用生成 skipped tool result；并行批次同样会给未启动的调用补一份可观察结果。见 `packages/agent-core/src/agent.ts`、`packages/agent-core/src/agent-loop.ts`。

`chat.send` 除普通发送外，还支持运行中注入消息、interrupt、followup 和 collect。Gateway 在发送前或排队准入时就把精确的 backend target 捕获下来；当前运行一旦清除，这个 target 保持原样，不再解析 successor。这一层的 stop/steer 竞态由 Reply operation 统一管理，backend 挂接、按用户中止、supersede 与 terminal barrier 都在同一个 operation 对象上完成，见 `src/auto-reply/reply/reply-run-registry.registry.ts` 和 `src/auto-reply/reply/reply-run-registry.operation.ts`。

## 8. 队列、多会话并发与后台生成

### 并发粒度

embedded runner 的并发先按 session lane 收紧，再进 global lane：同一个 session 的 transcript、tool state 和 active Agent 只能串行写入。不同 session 能否并行，取决于 global lane 的容量和其他准入条件。Reply operation registry 以 canonical session key 维护 active slot，Gateway 的 session work admission 还额外管住 session alias、backing session id 和 transcript write owner。

### queue mode

`resolveActiveRunQueueAction` 决定运行中新到的消息是 run-now、enqueue-followup 还是 drop。当前没有 active run、队列也空着时直接开跑；heartbeat 新 turn 碰上 active 状态直接丢；reset 优先走 interrupt/run-now；剩下的按 followup/queue mode 入队。见 `src/auto-reply/reply/queue-policy.ts`。

followup queue 拿 message id、route identity、reply anchor、chat type 和 queue policy 一起去重并控制容量。steer candidate 会先拿到一个 acceptance barrier；steer 还没定下来时到达的普通消息停在 anchor 后面，旧 steer 的 fallback 判定期间新消息不会丢。容量压力有三条出路：drop-new、drop-old 或 summarize，见 `src/auto-reply/reply/queue/enqueue.ts`。

collect mode 按 delivery context、授权 participant、媒体、工具策略、provider/model、客户端 capability、source reply mode 和 turn lifecycle 分组。彼此兼容的消息合成为一条 `[Queued messages while agent was busy]` prompt，配独立的 collected user turn transcript；跨渠道、runtime-only metadata、特殊 skill revision 或不同 admission owner 则拆成多个 group，或者逐条 drain。实现见 `src/auto-reply/reply/queue/drain.ts`、`:431-515`、`:1263-1517`。

队列 drain 经过 debounce、重试和 successor admission，可能已经和最初的请求脱开。它为此创建 independent root work continuation，并在 drain 时重新取当前 prepared model runtime 的 generation，所以 parked turn 带的是新 generation，不会沿用上一个 run 过期的那个。Gateway 会给 ACK 后仍留在队列里的 turn 保留 `chatQueuedTurns` 取消身份，`chat.abort` 因此能按原 run id 取消 queued work；collect aggregate 被 admission 之后，取消权转给 aggregate owner。见 `src/auto-reply/reply/queue/drain.ts`、`src/gateway/chat-queued-turns.ts`。

## 9. Agent、工具、知识库与附件注入点

### Agent、bootstrap 与 skills

Agent/harness 属于 prepared model runtime 的一部分。attempt setup 先把工作区、sandbox、permission root 和 effective cwd 定下来，再加载 skill snapshot、skill environment overrides、code-mode skill 和 bootstrap context files。bootstrap 文件可能来自 Agent workspace、执行 workspace 或 session-specific workspace；这些上下文文件和 truncation notice 随后进入 system prompt。见 `src/agents/embedded-agent-runner/run/attempt-setup.ts`、`src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts`。

system prompt 的构建分三步。先分三路收齐素材：运行环境（runtime 的 machine/model/channel 信息、sandbox 状态、OpenClaw reference paths、tool schema 目录）、会话与记忆（watched sessions、project memory bootstrap、skills prompt、bootstrap context files）、行为与渠道提示（渠道 action、message-tool hints、owner/quiet/reasoning 指引，以及 provider 自带的 system-prompt contribution）。再交给 `buildEmbeddedSystemPrompt`，最后跑一次 provider-specific 的 system prompt transform。见 `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`、`src/agents/embedded-agent-runner/run/attempt-system-prompt.ts`。

### 工具目录

当前 attempt 的工具目录按运行上下文构建，而非从固定全局表直接复制：

1. 根据 model tool capability、disable/raw mode、runtime allowlist 和 message-tool/source-reply mode 决定要创建的 core tool family。
2. 构建 OpenClaw coding tools、channel/plugin tools、client tools、bundle MCP 和 bundle LSP runtime。
3. 创建 conversation capability profile，把 session、sender、group、channel、sandbox、workspace、skills、input provenance 和 model facts 传入工具构建。
4. 应用 final effective policy、local-model lean、runtime schema projection 和 tool execution allowlist。
5. 如果启用 Tool Search 或 Code Mode，把部分工具放入 run-scoped catalog，必要时在模型发出 deferred call 后再 hydrate。
6. 将最终工具和 deferred resolver 交给 AgentSession，再由 Agent Core 放入 `Context.tools`。

注入入口分别位于 `src/agents/embedded-agent-runner/run/attempt-tool-prepare.ts`、`src/agents/embedded-agent-runner/run/attempt-bundle-tools.ts`、`src/agents/embedded-agent-runner/run/attempt-tool-catalog.ts`。工具内部过滤、审批和执行语义见 [OpenClaw Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)。

### 记忆、知识库与项目信息

legacy/full prompt surface 会调用 `prepareAgentMemoryPrompt`，把规范化后的 available tools、citations mode、agent/session key 和 sandbox 状态交给 memory plugin，返回的 prepared memory prompt section 再并进 system prompt。非 legacy 的 Context Engine assemble 则在 `runWithPreparedMemoryPromptSection` 作用域里拿到同一份 prepared memory context，这样 prompt builder 和 context engine 用的是同一套工具集合。见 `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`、`src/agents/memory-prompt-prepare.ts`、`src/agents/harness/context-engine-lifecycle.ts`。

当前代码快照在 full prompt path 上还看到 project memory bootstrap、project memory write instruction 和 watched sessions prompt 三处，它们是本次 request 的注入交接点；memory corpus 的实际检索、索引和命中条件由 memory plugin/context engine 实现。本次调查确认的范围到这些交接点为止，独立全局 RAG 服务是否成为每个对话的必经步骤、每次请求是否真的发生检索，都还没有验证。memory plugin registry 的 prompt/corpus 边界见 `src/plugins/memory-state.ts`。

### 附件与媒体

Gateway 先把 RPC attachments 归一化；解析出来的图片可以直接充当当前 turn 的 image。进不了模型 image input 的文件，则以 structured media facts 加预 staged path 的形式传递。用户 turn recorder 会把 durable media facts、image slots 和 omission marker 写进 transcript。等到 attempt 执行 prompt 时，再按 prompt 里的媒体引用、持久化的 media facts、image order、MAX_IMAGE_BYTES、尺寸限制、workspace-only 和 sandbox bridge 去加载图片；provider transport 最终把可用媒体 materialize 成 Provider context。

plugin harness 的媒体路径更严格：host 只准备结构化的 image input，只要某个 structured image attachment 无法 hydrate，该 attempt 就直接抛错，模型不会悄悄收到缺了附件的输入。相关交接见 `src/agents/embedded-agent-runner/run/attempt-prompt-submit.ts`、`src/agents/embedded-agent-runner/run/run-attempt-dispatch.ts`、`src/agents/embedded-agent-runner/run/attempt-stream-settle.ts`。

## 10. 退出恢复、日志与已确认边界

### Gateway 重启、重连与生命周期 generation

Agent event、reply operation、abort controller 和 active embedded run 都带 lifecycle generation 或等价的 owner claim。Gateway 重启时，旧 generation 的 reply operation 会被 eviction/abort；`server-chat` 也不再投影旧 generation 或已失活 context claim 的事件，旧进程迟到的 terminal 因此盖不住 successor。见 `src/auto-reply/reply/reply-run-registry.registry.ts`、`src/gateway/server-chat.ts`、`:1316-1335`。

Gateway 进程退出后，普通 active run 的执行不再持有有效的 in-memory authority；能留下来的主要是 transcript 和 session lifecycle row。Control UI 里有一部分简单 main turn 满足 restart-safe 条件，会针对 message 与 owner 标记生成 HMAC request fingerprint，提交一份 durable restart claim。重启后收到相同 request 时，系统凭 fingerprint、run id 和 expected session state 做 adoption，同一个用户 turn 不会被重复提交成另一份。恢复 claim、terminalization 和 retry 检查见 `src/gateway/server-methods/chat-restart-recovery.ts`、`:298-460`。

`server-chat` 写入 terminal lifecycle 时，先更新 session row 的 status、started/ended time、runtime、last error、last run id 和 lifecycle ownership，然后才广播 `sessions.changed`。客户端切走会话时如果还有 visible chat-send run，`resolveInFlightRunSnapshot` 会从 active abort controller 和 chat buffer 里取得运行 id、partial text、plan 与 progress event；snapshot 和历史消息合计受 byte cap 约束，超出时按 run adoption、timing、progress、plan、text 的先后顺序压缩。见 `src/gateway/chat-abort.ts`。

### 日志、trace、用量与诊断

Gateway 用 diagnostics timeline 记录请求的各个 span，比如 session load、附件准备、user transcript 持久化、dispatch 和 post-dispatch；trace attributes 带上 run id、session key、agent、provider、model、附件和 client 信息。embedded attempt 发出 `run.started`/`run.completed` 两类 trusted diagnostic event，记录 prompt/system report、trajectory、compaction、usage、fallback attempt、prompt cache 和 terminal outcome。Provider usage 会累积到 attempt/run result，再按 lifecycle generation 发 usage agent event。对应入口见 `src/gateway/server-methods/chat-send-handler.ts`、`src/agents/embedded-agent-runner/run/attempt-setup.ts`、`src/agents/embedded-agent-subscribe.ts`。

### 设计取舍与已确认边界

- ACK 与 detached dispatch 分离，使客户端尽快获得稳定 run id，同时让 dispatch 继续持有 session admission、transcript persistence 和终态 cleanup。
- Transcript 使用 SQLite accessor、SessionManager 和 explicit parent chain；Gateway 的 user-turn recorder 只负责把入口输入适配到这条 canonical 写入路径。
- 当前 turn 的裸 transcript prompt 与 model-only context 分开，动态的 inbound metadata、hook context、sender projection 和 runtime context 不会自动写入用户原文。
- Context Engine 可以拥有 assemble/compaction/after-turn，但 host 仍负责 transcript fence、run authority、bounded timeout 和不兼容时的本轮降级。
- Provider stream 的原始事件、Agent Core message lifecycle、Gateway `agent` event 和 Gateway `chat` payload 是几个不同的投影面；更新频率只在各自面内有效，持久化语义按各自那一层看。
- 正常 assistant transcript 与 Gateway live reply 分离；非 Agent reply、媒体补写、abort partial 和 source reply mirror 使用专门的 finalization 路径来维持幂等。
- 工具循环允许并行/串行批次、steer、follow-up 和 collect，但 session transcript/write admission 仍是串行 owner；跨 route 或不同授权上下文的 queued item 保持各自分组。

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

- `src/gateway/server-methods/chat-send-handler.ts`：`chat.send` 准入、ACK 和 detached dispatch handoff
- `src/gateway/server-methods/chat-send-request.ts`、`chat-send-session.ts:33-212`：请求规范化、session/model/agent 解析
- `src/gateway/server-methods/chat-send-admission.ts`：dedupe、session work admission、abort owner、restart claim
- `src/gateway/server-methods/chat-send-attachments.ts`、`chat-send-user-turn.ts:186-269`：附件与 Gateway user turn 构建
- `src/gateway/server-methods/chat-send-agent-dispatch.ts`、`:409-559`：ACK 后的 reply dispatch、Agent run callbacks 和最终投影
- `src/auto-reply/dispatch.ts`、`src/auto-reply/reply/dispatch-from-config.ts`：auto-reply dispatch pipeline
- `src/auto-reply/reply/get-reply-run-context.ts`、`get-reply-run-admission.ts:59-651`、`get-reply-run-execute.ts:57-618`：prompt envelope、queue admission、FollowupRun 与 Agent runner 交接
- `src/agents/embedded-agent-runner/run-orchestrator.ts`、`run-loop.ts:71-725`：prepared runtime、session/global lane、attempt retry loop
- `src/agents/embedded-agent-runner/run/attempt.ts`、`attempt-execution-phase.ts:25-254`：单 attempt 的 setup、history、prompt、stream 和 settle 编排
- `src/agents/embedded-agent-runner/run/attempt-session-prepare.ts`：SessionManager、LLM boundary、transcript policy 和当前 user turn 关联
- `src/agents/embedded-agent-runner/run/attempt-history.ts`、`attempt-prompt-build.ts:110-424,478-684`：历史清理、Context Engine assemble、hook/runtime/model prompt 分流
- `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`、`attempt-tool-prepare.ts:58-241`、`attempt-bundle-tools.ts:28-258`：system prompt、工具和外部能力准备
- `src/agents/embedded-agent-runner/run/preemptive-compaction.ts`、`attempt-prompt-preflight.ts:160-275`：预算预检和压力路线
- `src/agents/sessions/agent-session-compaction.ts`、`src/agents/embedded-agent-runner/run/compaction-runtime.ts`：session/outer compaction recovery
- `src/context-engine/types.ts`、`src/agents/harness/context-engine-lifecycle.ts`、`src/context-engine/legacy.ts`：Context Engine 合同、host lifecycle 与 legacy delegate
- `packages/agent-core/src/agent.ts`、`packages/agent-core/src/agent-loop.ts`：Agent 状态、Provider 请求和工具/回合循环
- `src/agents/embedded-agent-subscribe.ts`、`embedded-agent-subscribe.handlers.ts:28-157`、`embedded-agent-subscribe.handlers.messages.lifecycle.ts:118-325`：AgentSession 事件订阅、usage、可见回复和工具状态
- `src/gateway/server-chat.ts`、`server-methods/chat-broadcast.ts:88-179`：Gateway agent/chat 事件、缓冲、终态和广播
- `src/agents/sessions/agent-session-base.ts`、`src/agents/sessions/session-manager-entries.ts`、`src/sessions/user-turn-transcript.ts`：消息 end 持久化、parent chain 和 user-turn 幂等
- `src/gateway/chat-abort.ts`、`src/gateway/server-methods/chat-abort-handler.ts`：active/queued abort、partial persistence 和授权
- `src/auto-reply/reply/queue-policy.ts`、`queue/enqueue.ts:124-283`、`queue/drain.ts:1263-1563`、`src/gateway/chat-queued-turns.ts`：队列策略、collect/steer、独立 drain 和取消身份
- `src/gateway/server-methods/chat-restart-recovery.ts`、`src/gateway/session-lifecycle-state.ts`：restart-safe claim、生命周期持久化和恢复边界
