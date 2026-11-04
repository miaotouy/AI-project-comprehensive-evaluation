# Codex 对话请求与上下文调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c9750d7f50052b29f53def02b5cf2160ae49a3d9`（分支：`main`）
>
> 调查方式：静态源码走读 + 检索，未运行构建与测试
>
> 调查范围：turn 提交入口与状态判定、上下文拼装顺序、token 预算与压缩、Provider/协议交接、流式事件与工具派发、最终化与回写、中断/重试/续写、并发与后台任务、外部能力注入点、退出恢复与可观测性；会话 schema 与索引/迁移见「会话与消息管理」笔记
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的一次生成由 `turn/start` RPC 进入 app-server，转换为核心的 `Op::TurnInput`；核心在 `turn_input::handle` 一处判定“开始新 turn、并入当前 turn、或拒绝”，之后由常规任务循环驱动。上下文不是拼成一条 system prompt 后直接发请求，而是先在历史中追加一组**世界状态（world state）片段**，再归一化为 Responses API 输入，最后组装工具、base instructions 与输出 schema。

关键事实：

- **turn 输入只有一个决策点**：`turn_input::handle` 决定 Started / Steered / NotSubmitted，并把拒绝原因作为结构化返回值（`codex-rs/core/src/session/turn_input.rs:233-468`、`codex-rs/protocol/src/turn_input.rs:291-323`）。
- **上下文以“增量片段写入历史”的方式维护**：首轮注入完整上下文，后续只写入与上一基线的差异（`WorldState` 与 `TurnContextItem` 比较），并把这些片段持久化为 rollout 记录（`codex-rs/core/src/session/mod.rs:5137-5230`）。
- **压缩是重写历史**：生成摘要后构造新的 `ResponseItemEnvelope` 序列，把规范化的初始上下文重新插到最后一个真实用户消息之前，再以 `RolloutItem::Compacted` 落盘；旧历史不再可见（`codex-rs/core/src/compact.rs:640-712`、`codex-rs/core/src/session/mod.rs:4434-4621`）。
- **工具调用先落历史再执行**：模型给出调用后立即把 `FunctionCall` 写入历史，再异步派发工具；该响应流结束后才统一等待在途工具，然后决定是否继续下一轮（`codex-rs/core/src/stream_events_utils.rs:324-369`、`codex-rs/core/src/session/turn.rs:3503-3514`）。
- **同线程严格串行**：一个 Session 同时最多一个运行任务；再次发送要么并入当前轮的待处理输入，要么返回拒绝，不会并行开第二轮（`codex-rs/core/src/session/session.rs:59-60`）。

## 系统边界与生成任务主链

```text
turn/start（app-server turn_processor.rs:546-767）
  -> CodexThread::start_or_steer_turn（core/codex_thread.rs:473）
  -> SessionIo::submit_turn_input -> Op::TurnInput（core/session/mod.rs:1121-1149）
  -> submission_loop 分发（core/session/handlers.rs:598-610）
  -> turn_input::handle：Steered 或 Started（spawn_task RegularTask）
  -> RegularTask::run：emit TurnStarted -> （可选）pre-turn 压缩 -> 捕获 StepContext
  -> record_context_updates_and_set_reference_context_item（世界状态/上下文片段入历史）
  -> 记录用户输入 -> 采样循环
       -> ContextManager::for_prompt -> build_prompt -> ModelClientSession::stream
       -> ResponseEvent 流：Item started/delta/done -> 记录项 -> 工具派发
  -> 无待跟进且无排队输入 -> break
  -> TurnComplete/TurnAborted -> 清活动 turn -> flush rollout
```

边界：会话文件、索引与 CRUD 属于「会话与消息管理」；消息渲染属于消息渲染器；工具内部执行与审批语义属于 Agent 工具；模型与渠道清单属于 LLM 渠道管理。

## 1. 提交入口、任务对象与状态机

**入口**：app-server 的 `turn/start` 做输入大小、图片 URL、cwd 与环境、线程设置覆盖、模型 Provider 可用性校验，然后把输入请求交给 `start_or_steer_turn`（`codex-rs/app-server/src/request_processors/turn_processor.rs:546-716`）。核心侧把该请求包成提交对象，经 `tx_sub` 进入会话的提交队列（`codex-rs/core/src/session/mod.rs:1121-1149`）。

**任务对象**：`ActiveTurn` 持有当前任务、含取消令牌与待处理输入的轮次状态，以及取消句柄；任务由 `spawn_task`/`start_task` 一类入口挂到活动轮上（`codex-rs/core/src/tasks/mod.rs:273-300`、`codex-rs/core/src/state/turn.rs`）。轮次上下文的 id 直接沿用提交 id，root turn 与子 turn 通过根轮 id 关联（`codex-rs/protocol/src/protocol.rs:2406-2429`）。

**状态机是隐式的**：没有 `running/queued` 枚举，状态由“是否存在 ActiveTurn 及其 task 字段”表达；对外只暴露 `TurnInputSubmission` 三态与一组拒绝原因。拒绝原因覆盖了并发与模式约束（`codex-rs/protocol/src/turn_input.rs:291-323`）：

```text
Superseded / ServerDraining / NotIdle / PendingTriggerTurn / PlanMode /
NoActiveTurn / ExpectedTurnMismatch / ActiveTurnNotSteerable /
ActiveTurnOutputSchemaMismatch / EmptyInput
```

**输入模式**有四种，区别在于“何时接受新输入、何时拒绝”（`codex-rs/protocol/src/turn_input.rs:192-202`）：

| 模式 | 行为 |
|---|---|
| `StartOrSteer` | 空闲则开始，否则并入当前轮 |
| `StartIfIdle` | 忙则拒绝 |
| `ContinueIfIdle` | 要求上一轮匹配 |
| `Steer` | 仅当指定 turn 仍活动时并入 |

## 2. 历史选择与上下文拼装顺序

上下文工作分三段完成，顺序以最终写入历史的顺序为准。

**第一段是 step 捕获**：`capture_step_context` 在 active_turn 与 state 两把锁下读取本步模型/推理强度/服务层，快照环境，解析 token 预算，刷新 AGENTS.md，并构建工具路由（`codex-rs/core/src/session/mod.rs:4005-4130`）。工具目录来自 MCP、连接器、动态工具、插件与技能，构建入口是 `built_tools`（`codex-rs/core/src/session/turn.rs:1942-2023`）。

**第二段是世界状态渲染**：`build_world_state_for_step` 按固定顺序装配上下文区块（`codex-rs/core/src/session/world_state.rs:59` 起）：

| 顺序 | 区块 | 作用 |
|---|---|---|
| 1 | 顶层工具声明（增量工具模式下） | 工具 schema 走历史而非请求字段 |
| 2 | 模型指令 | base instructions 与新模型提示 |
| 3 | token 预算 / 上下文窗口提示 | 上下文占用与压缩指引 |
| 4 | realtime、AGENTS.md、权限 | 运行环境与沙箱边界 |
| 5 | 协作模式、持久执行模式 | 模式约束与后台执行说明 |
| 6 | 环境、环境指令、apps、插件 | cwd/日期/子 Agent 与连接器状态 |
| 7 | 工具命名空间、扩展贡献区块 | 延迟加载与第三方扩展 |
| 8 | 多 Agent 模式、使用提示、模型目录、受管开发者指令 | 子 Agent 与平台约束 |

首轮把完整快照转成 developer/contextual-user 消息；后续只把与 `reference_context_item` 的差异写成片段。首次注入时还会把 token 预算说明、多 Agent 模式、guardian 策略等作为独立消息插入，以免与聚合的 developer 包混在一起（`codex-rs/core/src/session/mod.rs:4719-4990`）。

**第三段是用户输入与最终请求**。用户消息在上下文片段之后写入历史，模型项与派生 UI 项同时产生（`codex-rs/core/src/session/mod.rs:5504-5567`）。每步采样前还会追加世界状态差异、reasoning effort 覆盖与时间提醒（`codex-rs/core/src/session/turn.rs:548-571`）。最终请求的输入就是 `ContextManager::for_prompt` 的输出，它按模型支持的模态剥离不支持的图片/音频，并把不可解析的图片引用替换为文本占位（`codex-rs/core/src/context_manager/history.rs:600-631`）。

顺序上有一个容易误判的点：**base instructions 不在历史里，而在 `Prompt` 的独立字段**；历史里的“模型指令”区块是给模型看的上下文副本，两者可能同时存在（`codex-rs/core/src/session/turn.rs:1700-1729`、`codex-rs/core/src/client_common.rs:21-42`）。

## 3. 预算、截断、摘要与压缩

**预算判定**集中在 `context_window_token_status`（`codex-rs/core/src/session/context_window.rs:26-130`）：

- 活跃 token 取自会话累计用量；
- 自动压缩作用域可选 `Total`（全量上下文）或 `BodyAfterPrefix`（只算初始前缀之后的增量），后者以窗口预填 token 为基线；
- 模型上下文窗口按 `effective_context_window_percent` 折算成硬上限；
- 达到“缓冲后的自动压缩上限”或“硬上限”即 `token_limit_reached`；
- 另有 `turn_end_compaction_threshold_reached`，由 `model_post_turn_compact_threshold_percent` 控制，用于轮末提前压缩。

**触发点有四处**：

- 轮前：`run_pre_sampling_compact`，在用户输入写入历史之前执行（`turn.rs:203-243`）。
- 轮中：需要跟进且达到阈值时由 `run_auto_compact` 滚动（`:683-740`）。
- 轮末：超过 `model_post_turn_compact_threshold_percent` 后压缩（`:805-848`）。
- 异步：`async_compaction::maybe_start` 在采样后预压缩（`:439-455`、`:631-644`）。

轮前压缩失败时会先把输入补记入历史再报错（`:212-243`）。

**压缩实现**：用摘要提示（或配置的 `compact_prompt`）发起一次专用请求，然后收集历史中的真实用户消息，构造“摘要 + 用户消息”的替代历史（`codex-rs/core/src/compact.rs:117-152`、`:394-424`、`:701-712`）。替代历史不保留工具输出；若上下文仍超限，压缩请求本身会从最旧项开始逐条丢弃并重试（`:362-374`）。

**重新注入初始上下文**：`build_compaction_replacement_history` 重新渲染一份完整世界状态，并把上下文插到最后一个真实用户/Agent 消息之前；若只剩摘要或压缩项，则插在其前以保持最后一项仍是压缩项（`codex-rs/core/src/compact.rs:84-115`、`:640-699`）。

**落盘**：`replace_compacted_history` 同时替换内存历史、推进压缩窗口、写入 `RolloutItem::Compacted`（含替代历史、保留上下文、窗口 id、恢复元数据）、`WorldState`、`TurnContext` 与设置事件（`codex-rs/core/src/session/mod.rs:4434-4621`）。旧历史没有删除标记，只是不再属于当前历史。

**另一条压缩路径**：启用 `TokenBudget` feature 时不做摘要，而是重置上下文窗口（`codex-rs/core/src/compact_token_budget.rs`）；支持远端压缩的 Provider 走 `compact_remote_v2`，失败时按 `CompactionFallback` 决定是否前台压缩（`codex-rs/core/src/session/turn.rs:1580-1625`）。

## 4. SDK、Provider、模型与协议交接

核心不直接用 OpenAI SDK，而是经 `codex-api`/`codex-client` 生成的 Responses 请求。一次 turn 复用一个 `ModelClientSession`，以便在重试间保留 WebSocket 连接与粘性路由状态（`codex-rs/core/src/session/turn.rs:197-198`、`:466-467`）。

**请求对象**是 `Prompt`：输入项、工具定义、`parallel_tool_calls`、base instructions、输出 schema 与严格校验开关、cyber access program（`codex-rs/core/src/client_common.rs:21-42`）。`build_prompt` 在增量工具模式下把工具置空、把 base instructions 清空，因为这两者已由历史中的区块提供（`codex-rs/core/src/session/turn.rs:1700-1729`）。

**传输选择**在 `ModelClientSession::stream` 内完成：`WireApi::Responses` 下若启用 WebSocket 则先走 WS，失败可切回 HTTP；否则直接走 HTTP 流式执行器（`codex-rs/core/src/client.rs:2497-2552`）。请求构造由 `build_responses_request` 负责，附加请求级遥测、压缩选项与 headers（`codex-rs/core/src/client.rs:1021`、`:1903-1985`）。

**协议字段与模型参数**：模型 slug、reasoning effort、summary、service tier 均来自本步设置，而不是会话创建时的快照；服务端返回的模型不一致会产生一次告警事件（`codex-rs/core/src/session/turn.rs:3209-3221`）。

## 5. 流式事件、缓冲、节流与顺序

**事件形状**：`ResponseEvent` 覆盖响应创建、项新增与完成、文本增量、工具参数增量、reasoning 增量、完成、限流与服务端模型信息。核心逐事件处理并即时转发，本次未在 core 与 app-server 的投递路径中找到面向客户端的批量合并或节流层；唯一的内容缓冲出现在 Plan 模式解析中，按行判定文本属于计划还是普通回复（`codex-rs/core/src/session/turn.rs:2942-3469`、`:2172-2190`）。

**项生命周期**：

- `OutputItemAdded` 分配缺失 id、预留 assistant 消息顺序，并在需要时立即发出 `ItemStarted`；文本/推理项的初始内容会先做一次“种子”解析，避免首段文本丢失（`codex-rs/core/src/session/turn.rs:3125-3207`）。
- 文本 delta 转成 `AgentMessageContentDelta` 事件，app-server 映射为 `item/agentMessage/delta`；reasoning 的 summary 与 raw content 分别走不同事件（`codex-rs/core/src/session/turn.rs:3322-3468`、`codex-rs/app-server-protocol/src/protocol/common.rs:2054-2086`）。
- `OutputItemDone` 才把完整项写入历史并发出 `ItemCompleted`；工具调用在写入后立即派发（`codex-rs/core/src/stream_events_utils.rs:324-369`）。

**顺序保证**：同一响应内事件按到达顺序处理；工具执行是并发的，收集到 `FuturesOrdered` 后在该响应流结束、`Completed` 处理完毕时才统一等待（`codex-rs/core/src/session/turn.rs:2816`、`:3503-3514`）。因此“模型看到工具结果”必然发生在下一轮请求之前，而工具之间可以并行。

**realtime 与普通流共用通道**：协议事件在发出前可能先被 realtime 历史消费以生成转写，再落 rollout 与投递客户端（`codex-rs/core/src/session/mod.rs:2748-2790`）。

## 6. 完成、异常、半截流与最终回写

**完成的判定**：`ResponseEvent::Completed` 携带 `end_turn`；`end_turn == false` 置 `needs_follow_up`。工具调用也会置 `needs_follow_up`（`codex-rs/core/src/session/turn.rs:3269-3320`、`codex-rs/core/src/stream_events_utils.rs:368`）。

**单次采样的收尾**按固定顺序进行：刷新未完成的 assistant 文本段 → 等待在途工具 → 发 `TokenCount` → 取消检查 → 发 `TurnDiff`（`codex-rs/core/src/session/turn.rs:3495-3537`）。

**轮循环**：`run_turn` 内层循环在“需要跟进或有排队输入”时继续；外层 `RegularTask::run` 在 `run_turn` 返回后检查是否仍有待处理输入，有则再次调用（`codex-rs/core/src/session/turn.rs:598-851`、`codex-rs/core/src/tasks/regular.rs:112-135`）。

**终态事件**：任务收口时依据 abort 原因发出 `TurnAborted` 或 `TurnComplete`，后者包含 `last_agent_message`、错误、起止时间与首 token 时间；随后清空 ActiveTurn、发线程空闲生命周期、flush rollout，并尝试启动排队工作（`codex-rs/core/src/tasks/mod.rs:831-924`）。

**异常分类**：

- 上下文超限 → 标记上下文已满并返回错误（`codex-rs/core/src/session/turn.rs:1843-1846`）；guardian 评审路径则在开启自动摘要时先压缩、再重试一次（`:853-883`、`:345-387`）；
- 内容过滤 → 记录引导片段后按重试策略处理（`codex-rs/core/src/responses_retry.rs:68-83`）；
- 非法图片 → 直接发 `Error` 并结束本轮（`codex-rs/core/src/session/turn.rs:887-909`）；
- 其它错误 → 归一化为协议错误、上报生命周期，并发 `Error` 后 break，让用户可以继续对话（`:910-926`）。

**半截流**：若 `OutputItemDone` 未到达就断流，已流出的文本只在对应项完成时才进历史；中断轮次会额外写入一个中断标记，且先 flush 再发 `TurnAborted`（`codex-rs/core/src/tasks/mod.rs:1015-1034`）。

## 7. 停止、重试、续写与重新生成

**停止**：客户端的 `turn/interrupt` 映射为核心的中断 Op，经 `interrupt_task` 进入“取消全部任务”分支，先取消令牌再 abort 任务句柄（`codex-rs/core/src/session/handlers.rs:530-533`、`codex-rs/core/src/tasks/mod.rs:573`）。若同时开启流内中断特性并使用 Responses Lite 流，取消时会向该流发送带 1 秒截止的 Cancel，否则直接丢弃流（`codex-rs/core/src/session/turn.rs:2807-2812`、`:3471-3477`）。

**重试**分两层：传输/流错误在采样循环内按 Provider 配置的流重试次数处理，遵循错误给出的 `retry_after`；WebSocket 重试耗尽后可切 HTTP 并清零计数；开启 `UnboundedConnectionRetries` 时连接失败可无限退避（`codex-rs/core/src/session/turn.rs:1771`、`codex-rs/core/src/responses_retry.rs:92-140`）。另一层是用户重新发送，那会创建新的 turn。

**续写**即在同一线程再发一轮；历史在内存中保留，模型下一轮自然看到上一轮结果。

**重新生成/编辑**：本次未找到“对指定 assistant 消息重新生成”或“编辑消息后重发”的独立 RPC；`thread/revert` 截断到某轮之前，再由客户端重新提交，是等价路径（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:1300-1304`）。

## 8. 队列、多会话并发与后台生成

**同线程串行**：`Session` 的注释明确“同一时刻最多一个运行任务”，`start_if_idle` 会在 active_turn 已存在时返回 `NotIdle`（`codex-rs/core/src/session/session.rs:59-60`、`codex-rs/core/src/session/turn_input.rs:530-546`）。

**并入当前轮**：`steer_input` 把新输入挂到当前 turn 的待处理队列；`run_turn` 在每次采样前 drain，作为“用户补充”记录，随后与新的世界状态一起进入下一次请求（`codex-rs/core/src/session/turn_input.rs:861`、`codex-rs/core/src/session/turn.rs:479-498`）。

**邮箱消息可抢占**：来自其他 Agent 的消息在 assistant 输出 commentary/partial answer 或 reasoning 时可能中断当前响应，以便尽快送达；`DeferMailboxPreemption` 可改为在当前响应结束后再处理（`codex-rs/core/src/session/turn.rs:3047-3123`）。

**不同线程并行**：每个线程一个 Session 与独立任务，线程管理器负责启动/恢复；并发上限与容量淘汰由 Agent 运行时控制（详见多 Agent 与工具类目）。

**后台任务**：模型启动预热、MCP 预热与刷新、异步压缩都在主轮之外运行；每次开始新一轮且有用户输入时，app-server 还会为已配置主环境的线程启动记忆生成流水线；TUI 的自动标题另起隐藏的临时结构化线程，不与用户线程共用消息历史（`codex-rs/app-server/src/request_processors/turn_processor.rs:737-750`、`codex-rs/tui/src/app/thread_title.rs:64-127`）。预热与压缩入口见关键源码索引。

## 9. Agent、工具、知识库与附件注入点

- **工具目录**：`built_tools` 汇总 MCP 工具、连接器工具、动态工具、插件与技能，构建 `ToolRouter`；工具 schema 直接进入 `Prompt.tools`，或在增量工具模式下进入历史区块（`codex-rs/core/src/session/turn.rs:1942-2023`、`:1700-1714`）。
- **AGENTS.md 与指令文件**：每步刷新，结果进入世界状态的环境区块；失败只发警告，不阻断本轮（`codex-rs/core/src/session/mod.rs:4113-4121`）。
- **技能与插件上下文**：在采样前构建注入项并写入历史，随后才发请求（`codex-rs/core/src/session/turn.rs:331-341`、`:430-437`）。
- **记忆**：读取侧由 memories 扩展在线程上下文构建时贡献一段 developer 指令，说明记忆目录与检索方式，并可按配置注册专用读取工具，模型随后自行访问该目录；生成侧是独立的后台流水线，从历史 rollout 分阶段抽取，由 app-server 在新轮开始时触发。`SessionMeta.memory_mode` 记录该线程是否参与生成，具体抽取与合并算法属于记忆类目（`codex-rs/ext/memories/src/extension.rs:56-104`、`codex-rs/app-server/src/request_processors/turn_processor.rs:737-750`）。
- **附件与图片**：用户图片先经 `AttachmentStore` 预处理，再以文件引用或内联内容进入历史；模型不支持图片时会从请求中剥离（`codex-rs/core/src/session/mod.rs:3786-3806`、`codex-rs/core/src/context_manager/history.rs:600-631`）。

## 10. 退出恢复、日志与已确认边界

- **切换/关闭**：切线程不迁移运行任务；线程空闲后由 app-server 决定是否卸载。`Op::Shutdown` 先关闭运行时与线程持久化，再发关闭完成事件；`SuspendTurnAndShutdown` 只在历史已持久化、writer 已关闭时才允许退出（`codex-rs/core/src/session/handlers.rs:385-436`、`:629-641`、`:759`）。
- **中断恢复**：守护进程重启后可依据已记录的 turn 输入恢复该轮（`Op::RecoverTurn`）；要求输入已进入 rollout，否则不接管（`codex-rs/core/src/session/daemon_recovery.rs:16-56`）。
- **可观测性**：turn 级 timing（首 token、工具阻塞）、token 用量按模型聚合、`rollout_thread_trace` 记录协议事件与推理 trace、OTel 指标贯穿采样与工具阶段（`codex-rs/core/src/tasks/mod.rs:790-846`、`codex-rs/core/src/session/mod.rs:2783-2785`）。
- **已知边界**：核心不做跨会话的请求合并；不同 Provider 的协议 Adapter 细节未展开；远端压缩与 realtime 路径只记录了交接点，内部语义未深入。

## 11. 未验证事项

1. 中断的实际网络效果（Cancel 是否被 Provider 接受、工具进程是否被完全终止）未运行验证。
2. 压缩后缓存命中率与长上下文下的截断行为未实测；`BodyAfterPrefix` 作用域的实际收益未评估。
3. 工具并发度、`FuturesOrdered` 等待顺序对端到端延迟的影响未实测。
4. 邮箱抢占与 steer 同时发生时的事件顺序未通过并发测试确认。
5. 守护进程重启恢复在“输入已写、响应未完成”组合下的行为未做故障注入。

## 12. 关键源码索引

- `codex-rs/app-server/src/request_processors/turn_processor.rs`：turn/start 校验与提交
- `codex-rs/app-server-protocol/src/protocol/v2/thread.rs`、`turn.rs`：RPC 契约
- `codex-rs/app-server-protocol/src/protocol/common.rs`、`event_mapping.rs`：事件到通知的映射
- `codex-rs/core/src/codex_thread.rs`：线程门面与 `start_or_steer_turn`
- `codex-rs/core/src/session/handlers.rs`：`submission_loop` 与 Op 分发
- `codex-rs/core/src/session/turn_input.rs`：Started/Steered/拒绝判定与 steer 队列
- `codex-rs/core/src/session/input_queue.rs`：待处理输入与邮箱
- `codex-rs/core/src/tasks/regular.rs`、`tasks/mod.rs`：turn 循环、终止与排队
- `codex-rs/core/src/session/turn.rs`：上下文捕获、采样循环、流处理、工具等待
- `codex-rs/core/src/session/world_state.rs`、`session/mod.rs`：世界状态区块与上下文注入
- `codex-rs/core/src/context_manager/history.rs`：`for_prompt` 归一化
- `codex-rs/core/src/client_common.rs`、`client.rs`：`Prompt` 与 Responses 传输
- `codex-rs/core/src/stream_events_utils.rs`：项完成、工具派发与记录
- `codex-rs/core/src/session/context_window.rs`、`compact.rs`：预算与压缩
- `codex-rs/core/src/session/startup_prewarm.rs`、`mcp_prewarm.rs`：主轮之外的模型与 MCP 预热
- `codex-rs/core/src/session/token_budget.rs`、`async_compaction.rs`：阈值与异步压缩
- `codex-rs/core/src/responses_retry.rs`：重试与传输回退
- `codex-rs/ext/memories/src/extension.rs`、`memories/write/src/`：记忆读取注入与后台生成
- `codex-rs/core/src/session/daemon_recovery.rs`：中断轮次恢复
