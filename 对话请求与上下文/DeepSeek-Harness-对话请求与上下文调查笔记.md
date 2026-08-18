# DeepSeek-Harness 对话请求与上下文调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/core/session`、`packages/core/system-prompt`、`packages/core/agent-loop`、`packages/compaction/`、`packages/spill/`、`packages/context/`、`packages/interaction/`）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：静态源码阅读。先读 `docs/architecture.md`、`docs/agent-lifecycle.md` 及 `docs/subsystems/` 下 session、system-prompt、compaction、spill、core 页面，再逐包核对实现（agent-loop 主循环全量、session surface/deriveMessages、compaction-basic 全量、spill-policy、context 四插件、user-questions），并对 `packages/context`、`packages/compaction`、`packages/core` 全文检索 `@earendil-works`/pi 引用；未运行任何交互会话
>
> 调查范围：覆盖——请求主链路（inbox 领取 → pre-step → 上下文与工具 schema 组装 → 模型请求 → 流式回写）、日志派生历史（surface/deriveMessages）、compaction 三件套与 token-meter、spill 三件套、request-context 插件、提问能力、与 pi 的继承关系检索。排除——持久化后端与落盘时机（会话与消息管理类目）、UI 工作流与渲染（Chat UI/消息渲染器类目）、工具注册与执行细节（Agent 工具类目）、LLM 适配器协议与渠道（LLM 渠道管理类目）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness（下文称 dsh）基于 vendored Cordis，"一切皆插件"：请求组装不是单一模块，而是循环（`dsh-agent-loop`）在若干可替换服务与事件瀑布上的编排。核心结论：

1. **上下文唯一来源是会话事件日志**：模型历史由 `Session.deriveMessages()` 从 append-only 事件日志的表面投影派生，从不单独存储；"模型可见即已落盘"是不变量。上下文增量（文件指令、时间、tmux、运行时上下文）都以 `user/message` 事件落盘后再进请求。
2. **请求组装分两半**：system prompt 与工具 schema 由 `ctx.systemPrompt.assemble()` 从插件注册的 sections/contexts/tools/variables 组装；消息历史由日志派生；两者在每步 `buildRequest` 中合并为一次 `llm/stream` 调用，请求头（config+system+tools）本身也以 `request/header` 事件落盘。
3. **compaction 是可选能力 seam**：`compaction/start`/`summary`/`end` 三个 log-only 事件记录事务，真正的替换是一次 `surfaceOp: replace` 的 `user/message`（摘要节点）。触发分"步骤压力"与"context-overflow 恢复"两条路径，压力默认阈值为 contextWindow×0.8。
4. **spill 是另一可选能力 seam**：`tools/post-execute` 策略把超 `maxInlineBytes`（base 组合默认 50000）的纯文本工具结果落盘为会话私有文件，模型只见 head/tail 预览与读取提示。
5. **与 pi 无代码继承**：相关包源码检索零命中，仓库唯一的 pi 关系是 LLM 适配器 `dsh-llm-pi-ai` 对 `@earendil-works/pi-ai` 库的依赖（另有补丁过的 `@earendil-works/pi-tui`）；compaction/上下文概念有对应物，但架构与实现均为独立设计。

## 系统边界与生成任务主链

```text
调用方 -> agent.followup(createUserMessage)  (ReactLoopAgent, core/agent-loop/src/agent.ts:113-132)
   入 Inbox.next-turn，落盘 agent/inbox/spliced，唤醒 driver
  -> turn(): turn/start 落盘
  -> preStep(): inbox.claim(next-turn) 领取批次
       systemPrompt.assemble() -> renderContextSections -> runtimeContext.project()
       -> agent/pre-step 瀑布（可 reject / 改写消息；compaction 压力压缩、指令/时间/tmux 上下文在此挂接）
  -> step/start 落盘，进入的每条消息 append user/message（surfaceOp: append）
  -> step(): renderPrompt(assembly) -> buildRequest():
       deriveMessages()（日志派生历史）+ system + tools + agent/request 瀑布 + prepareCall
       -> request/header、request/context 落盘 -> llm/stream（preparedCall.stream 或 llm.stream）
  -> 逐 chunk append assistant/chunk -> BlockAssembler -> assistant/message 落盘
  -> tool/call -> tools 调度执行 -> tool/result 落盘
  -> 有工具调用或 next-step 新输入则下一 step；否则 agent/turn-stopping -> turn/end
```

边界：事件日志的持久化（JSONL/SQLite 后端、`session/flush` 检查点、crash 修复）属于会话与消息管理类目；inbox 提交按钮、命令面板、Web 客户端工作流属于 Chat UI；工具执行管线细节（approval、沙箱、超时）属于 Agent 工具类目。

## 1. 提交入口、任务对象与状态机

**入口**：`Agent` 接口的 `send(message, target, wakeup)` 是统一投递点，followup、steer、inject 三个方法（见下）是固定预设别名（`packages/core/agent/src/types.ts:61-141`）。

**路由语义**：followup 放入 `next-turn` 并唤醒 driver；steer 放入 `next-step` 并唤醒（最近步骤边界消费）；inject 只放入 `next-step` 不唤醒，等下一次唤醒的步骤边界才被领取。

**实现**：具体类是 `ReactLoopAgent`（`packages/core/agent-loop/src/agent.ts:64-97`）：`Inbox.splice` 先以 `agent/inbox/spliced` 事件落盘，再更新内存双列表，通知由 `agent/inbox/*` 事件对外发布。

**无独立任务记录对象**：运行状态在 `phase`（idle/maintenance/running 三态），对外只经 `agent/status` 事件可见（`agent.ts:99-111`）。turn/step 编号是日志中的事件坐标：`turn/start` 在领取前落盘，被拒绝或空消息的首个 claim 也会以"无 step 的 turn"关闭（`agent.ts:246-330`）。

**inbox 语义**：`Inbox.claim(target, turn)` 一次取出全部 `next-step` 输入；当 target 是 `next-turn` 时再取一个 `next-turn` 消息（`packages/core/agent/src/inbox.ts:71-78`）。

**取消**（`cancel`，可保留 inbox 内容）：清空两个列表并中止当前活动；取消原因分为用户、父 agent、hook、销毁四类。

## 2. 历史选择与上下文拼装顺序

**历史派生**：`Session.deriveMessages()` 遍历 `Session.surface.nodes`（由 `surfaceOp` 标记维护的模型可见序列），逐节点调用 `deriveEventMessage`（`packages/core/session/src/surface.ts:83-114`）。只有三类事件派生消息，规则如下：

- `user/message` 原样投影为 user 消息，不添加任何框架文本（框架由生产方自己写进 content）；
- `assistant/message` 投影为 assistant 消息，**空内容跳过**——只为承载 usage 的 max-tokens 步不进请求；
- `tool/result` 投影为带 tool-result 块的 user 消息。

chunk、turn/step 边界、log-only 记录一律不投影。派生带缓存：`replaceGeneration` 变化（一次 compaction replace）即整体重建（`packages/core/session/src/index.ts:701-747`）。surface 折叠有严格校验：replace 的范围必须是当前 surface 节点、`sourceEventSeqs` 必须覆盖全部被遮蔽节点（`surface.ts:210-243`）。

**组装顺序**（`preStep`，`agent-loop/src/agent.ts:225-243`）：领取批次 → `systemPrompt.assemble` → 渲染动态上下文并投影为候选 user 消息 → `agent/pre-step` 瀑布（默认决策把候选上下文追加在领取批次之后）。进入 step 后按序逐条 `user/message` 落盘，故日志中的顺序即模型看到的顺序：直接提示在前，各插件注入的上下文随后。

**system prompt 组装**：`SystemPrompt.assemble` 先按注册的 scope 层级合并 sections、contexts、tools、variables，其中 sections 按 `order` 升序（-100 为 harness 身份、0 为 persona 槽位），再跑 `system-prompt/assemble` 专家瀑布（`packages/core/system-prompt/src/index.ts:467-542`）。

**渲染与完整覆盖**：`renderPrompt` 做 `{{variable}}` 严格插值并丢弃空 section；`complete: true` 的 section 成为唯一 prompt 文本。

**工具 schema**：由各 `tools()` 提供者收集，参数经 `structuredClone` 脱附，再按配置 `toolOrder` 排序（未列名工具插入 `<unlisted-tools>` 槽位，无配置则字典序，`system-prompt/src/index.ts:164-178`）。

**动态运行时上下文**：assembly 的 `contexts` 渲染后由 `RuntimeContextProjection` 与上一份快照比较，仅变化时产出候选 `user/message`；被 compaction 遮蔽或清空时写入"Current runtime context: none"标记（`agent-loop/src/runtime-context.ts:64-75`）。它作为 pre-step 默认批次的尾巴进入请求，由 `includeRuntimeContext` 配置可关闭。

## 3. 预算、截断、摘要与压缩

**定价**：`ctx.tokenMeter` 重放日志增量折叠，启发式定价为每 4 字符 1 token、每块 4 token 结构开销、每消息 4 token 角色开销（`estimate.ts:12-19`）。最近一次成功的 `assistant/message` 若带 usage 且其请求头与当前一致，则以 provider usage 为锚；否则整表启发式重估。预算不预留固定 reserve：压力阈值是 contextWindow×thresholdRatio（默认 0.8），保留尾部是 ×retainRatio（默认 0.16）或绝对 retainTokens（`compaction-basic/src/config.ts:20-23,144-154`），均可按 provider/model 精确覆盖。

**两条触发路径**（`compaction-basic/src/index.ts:137-224`）：
- **压力路径**：`agent/pre-step` 串行监听器在请求派生前调用 `compactIfNeeded(agent, 'pressure', signal)`（`auto` 默认 true）。路由模型容量来自 `llm.resolveModelInfo`；未配置 contextWindow 则抛配置错误仅告警不阻断。
- **溢出路径**：`agent/request-error` 收到 `CONTEXT_WINDOW_EXCEEDED_CODE` 失败时，强制做一次平衡压缩，仅当 surface `replaceGeneration` 前进才返回 `{ kind: 'retry' }` 重开步骤；重试计数受 `maxOverflowRetries`（默认 1）限制，成功响应会重置该计数。

**压缩事务**（`compaction-basic/src/region.ts:152-254`）按以下顺序执行：
1. `compaction/start` 落盘，即取得事务锁；
2. 快照定价与区域消息，调用 summarizer；
3. 稳定性复查（自动路径要求整个 surface 未变，手动路径只要求所选区间未变）；
4. `compaction/summary` 记录落盘，随后以 `surfaceOp: replace` 追加摘要 `user/message`（`sourceEventSeqs` 覆盖 start/summary/全部被遮蔽节点），最后 `compaction/end` 释放锁。

区域选择是头锚定的（从 surface 头到保留尾部为止），绝不在 tool-call/result 对之间切割（`toolPairingBalancedBefore`/`After`）。

**汇总调用**：压缩本身是一次 `ctx.llm.stream()` 调用：以 `request/header` 里的 system+tools+区域消息为前缀、compaction 指令为最后一个 user 消息，以复用 KV cache（`summarizer.ts:121-182`）。默认 summarization 目标 = 显式配置 > 最近路由 > agent options。

**输出契约**：必须满足 compacted-summary 标签包裹的固定 Markdown 结构，且摘要定价必须小于被遮蔽内容（`framedSummaryTokenCount < shadowedTokenCount`），否则压缩失败。

**手动 `/compact`**：`command-compact` 在空闲期以维护任务执行一次压缩，使用独立于回合的锁括号（`turn: null`），成功后 `session.flush` 才放行后续唤醒输入（`compaction-basic/src/index.ts:368-420`）。

失败按六类预期错误码分类（如 busy、changed、summary），命令层映射为人类可读文案，全部错误码见 `docs/subsystems/compaction.md`。

**无模型剪枝**：`ctx.toolResultPruner`（可选）按 Unicode code point 对超阈值工具结果做 head/middle/tail 裁剪，替换只允许改 `content`（surface 层强制校验）。压力路径先剪枝再测再选摘要区，溢出路径剪枝后强制选择；每次替换前写 `compaction/prune` 影子价格事件（`compaction-tool-result-pruner/src/index.ts:136-184`）。压缩不可逆：旧事件仍在日志，只是被 surface 遮蔽；唯一可回放的是被剪枝工具结果的原始 seq（`sourceEventSeqs` 保留）。

## 4. SDK、Provider、模型与协议交接

`buildRequest`（`agent-loop/src/agent.ts:407-495`）按以下顺序组装一次冻结请求：

1. 首个请求的配置来自 agent options，之后从日志折叠的 `request/header` 提出提案（剥离 adapter 标记为默认的字段）；
2. `agent/request` 瀑布可替换配置；
3. `llm.prepareCall` 解析 exact-model 默认值；
4. 组装 `EpochHeader`（config+adapterDefaults+system+tools），与上一快照比较，变化时落盘 `request/header`（reason 为 initial/resume/change），路由容量变化时落盘 `request/context`；
5. 最终 `GenerateOptions` 带 messages（派生历史）、`sessionId`、`signal` 交给 `preparedCall.stream()` 或 `llm/stream` 瀑布。

请求头是日志状态而非内存字段，任意请求可从日志重建（`docs/subsystems/session.md#the-request-header-event`）。协议适配器在 `packages/llm`（`llm-deepseek` 直连 SSE、`llm-pi-ai` 走 pi-ai 库），属于 LLM 渠道管理类目，本次不展开。

## 5. 流式事件、缓冲、节流与顺序

**流式消费**：`step()` 逐 chunk 处理，保证两条顺序契约（`agent-loop/src/agent.ts:343-390`）：

- 每个 `StreamChunk` 原样落盘为 `assistant/chunk`（保持日志无损、可重放），同时喂 `BlockAssembler`；
- 流结束后一次性落盘 `assistant/message`，携带 `usage` 与 `sourceEventSeqs = chunkSeqs`。

`tool/call` 先于对应 `tool/result`，且由 `sourceEventSeqs` 引用强制校验。

**工具调度**：按 executionMode 分组——顺序调用成屏障、并行调用走有界滚动池（`maxParallelToolCalls` 默认 10），结果按模型顺序提交；abort 时为未启动调用补合成错误结果，保证重放有效（`agent-loop/src/tool-calls.ts:59-101,237-259`）。

## 6. 完成、异常、半截流与最终回写

步骤结束原因只有 completed/max-tokens，且 max-tokens 粘性传播到 turn（`agent.ts:290,391`）。turn 结束原因完整映射如下（`packages/core/session/src/types.ts` TurnEndReasonMap）：

- `completed`：自然完成；`max-tokens`：至少一步触顶，即使后续继续也保留；
- `aborted`：携带取消 cause；`blocked`：pre-step 拒绝；
- `error`：结构化 `LlmFailure`；`interrupted`：仅 crash 修复产生，循环本身不发出。

错误路径：流 finish 为 error/aborted → `agent/request-error` 瀑布（返回 retry 才继续，否则 throw `LlmError`）→ `turn/end` 记 error。

**回写即落盘**：每条模型可见事实都在 append 时同步完成，持久化后端经 `session/event` 异步消费，`session-checkpoint-policy` 提供请求前耐久检查点（持久化细节归会话类目）。

## 7. 停止、重试、续写与重新生成

- **停止**：`cancel(cause, {keepInbox})` 中止当前 turn 的信号，工具与 LLM 调用都携带该信号；abort 后 turn 以 `aborted` 收口，唤醒输入排队到下一 turn。
- **重试有两层**：适配器注册的 `retryPolicy`（`llm-retry` 插件处理 `llm/retry`，LLM 渠道类目）与 `agent/request-error` 返回 retry（compaction 溢出恢复专用，§3）。两者触发者与预算不同。
- **续写/重新生成**：未找到针对单条消息的续写或重新生成 API；分支能力是 `ctx.sessions.fork`（按边界 seq 复制日志前缀），恢复是 `ctx.agents.resume` 从持久化 seed 重建（两者都属会话类目）。

## 8. 队列、多会话并发与后台生成

并发粒度是"一个 agent 一个 driver"：单 agent 内 turn 串行（driver 循环 `while (await this.turn())`），多 agent 各自独立 driver 并行。steer 消息在最近步骤边界消费，inject 排队不唤醒，followup 独占下一 turn。后台工作经 jobs 插件（`job_*` 工具，属 Agent 工具类目）。subagent 是独立子 agent（spawn/fork 两种 provider，Agent 工具类目）。

## 9. Agent、工具、知识库与附件注入点

- 工具目录：各能力包向 `ctx.tools` 注册 `ToolDefinition`，其 schema 经 `ctx.systemPrompt.tools()` 进入每次组装（`packages/core/system-prompt/src/index.ts:430-436`）；执行在 loop 内调度（§5）。
- request-context 插件（`packages/context/README.md`）：`agent-instructions` 是 base 组合默认挂载（maxBytes 65536），在 pre-step 折叠 AGENTS.md 基线并在文件被读取、写入或编辑后异步重投影到 inbox；`time-context`、`tmux-context`、`session-reference` 均为 opt-in（时间读数、tmux 位置、他会话快照，各自带节流与字节预算）。
- 提问：`tool-ask-user` 把 `ask_user_question` 工具调用转成 `ctx.userQuestions.ask`，UI 回答作为普通工具结果回注（`packages/interaction/tool-ask-user/src/index.ts:80-99`）；仅根 agent 允许（`packages/interaction/user-questions/src/index.ts:92-140`）。
- 附件：attachment 能力包在 base 组合中（`dsh-attachment-local`），附件作为工具结果内容进入上下文；其细节属 Agent 工具类目。
- 知识库：本次未找到独立的"知识库注入"机制（检查范围：pre-step 链、assemble 注册点、base 组合行）；用户知识经 AGENTS.md 指令与文件内容进入上下文。

## 10. 与 Pi 的关系

**无代码继承**。检索证据如下：

- 源码检索：`packages/context`、`packages/compaction`、`packages/core` 下所有 `*.ts` 全文检索 `earendil|pi-ai|pi-cortex`，零命中；
- 依赖关系：仓库内唯一 pi 相关依赖是 LLM 适配器 `dsh-llm-pi-ai`（使用 `@earendil-works/pi-ai@0.82.1` 库）与依赖补丁 `@earendil-works/pi-tui`（见 `pnpm-workspace.yaml` 与 `THIRD_PARTY_NOTICES.md`）；
- 结论：这是库级复用，不是 harness 功能对 pi coding-agent 的继承。

**概念对应而非实现继承**，对照如下：

| pi（coding-agent） | dsh 对应物 | 差异 |
|---|---|---|
| leaf-parent 链回溯投影 + compaction 摘要消息 + `firstKeptEntryId` 保留起点 | 事件日志 surface 投影 + `surfaceOp: replace` 摘要节点 | dsh 以 replace 遮蔽代替起点游标，旧事件仍留在日志中 |
| `/compact` 手动压缩 | `command-compact` | 语义相近，事务锁与失败分类不同 |
| 阈值 `contextWindow - reserveTokens` | `contextWindow × thresholdRatio` | 前者绝对预留，后者比例化，均可用配置覆盖 |
| token 估算（chars/4 启发式） | token-meter（chars/4 + usage 锚定） | 估算密度相同，dsh 另以 provider usage 校准 |

dsh 的请求头落盘（`request/header` 可重建性）与"模型可见即已落盘"不变量在 pi 中无对应物。dsh 自身文档也把 pi 仅作为外部参照引用（如重试边界决策笔记引用 pi 的 settings 文档）。

## 11. 未验证事项

- 未运行交互会话：压缩触发、溢出重试、KV cache 复用收益、token 估算与真实计费偏差需真实模型端到端验证。
- `time-context`/`tmux-context`/`session-reference` 未在默认组合中挂载，其运行行为（时区推导、tmux 查询、跨会话快照）未实测。
- 持久化后端、崩溃修复（`interrupted` 收口）与 Web 客户端流式渲染未展开。
- 多 agent 并行、subagent 上下文继承（preset 组合）的实际行为仅从代码推断。

## 12. 关键源码索引

- `packages/core/agent-loop/src/agent.ts:113-132`：send/followup/steer/inject 入口；`:225-243`：preStep 组装；`:246-330`：turn 状态机；`:332-401`：step 与流式；`:407-495`：buildRequest
- `packages/core/session/src/surface.ts:83-114`：deriveEventMessage 投影规则；`packages/core/session/src/index.ts:701-747`：deriveMessages 缓存
- `packages/core/system-prompt/src/index.ts:467-542`：assemble；`:212-255`：渲染与插值
- `packages/core/agent-loop/src/runtime-context.ts:64-75`：动态上下文快照
- `packages/compaction/compaction-basic/src/index.ts:137-224`：两条触发路径；`region.ts:152-254`：压缩事务；`summarizer.ts:121-182`：KV 缓存复用汇总调用
- `packages/compaction/compaction-tool-result-pruner/src/index.ts:136-184`：无模型剪枝
- `packages/llm/token-meter/src/estimate.ts:12-19`：启发式定价；`src/index.ts:116-147`：usage 锚定
- `packages/spill/spill-policy/src/index.ts:190-231`：溢出落盘替换
- `packages/core/agent/src/inbox.ts:71-78`：claim 语义
- `packages/context/agent-instructions/src/index.ts:322-348`：pre-step 指令注入
