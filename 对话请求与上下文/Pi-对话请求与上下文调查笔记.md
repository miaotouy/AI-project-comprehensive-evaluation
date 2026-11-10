# Pi 对话请求与上下文调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/coding-agent/src/core/agent-session.ts`、`packages/coding-agent/src/core/compaction/`、`packages/coding-agent/src/core/system-prompt.ts`、`packages/agent/src/agent.ts`、`packages/agent/src/agent-loop.ts`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码与版本差异，定向跟踪会话投影、事件落盘、steer 消费边界及 durable 工具重放；其余请求与压缩机制采用文中来源范围，未运行交互会话
>
> 调查范围：发送主链路（prompt 输入处理）、上下文投影与 system prompt 组装、token 估算与自动压缩、agentLoop 工具循环、流式事件链、abort/重试/steer/followUp；会话持久化与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的生成任务由 `AgentSession.prompt()` 编排、`Agent`/`agentLoop` 执行：

1. 输入先经扩展命令/input 钩子/skill 与模板展开，再校验模型与认证，预压缩后组装 user 消息进入 agent 循环。
2. 上下文沿 leaf 经 parent 链回溯构建；compaction/branch_summary 被投影为摘要消息，普通 custom 条目不参与；system prompt 由工具列表、项目上下文文件、skills、自定义提示组装。
3. 自动压缩基于 token 估算与 `contextWindow - reserveTokens` 阈值；溢出走"压缩并自动重试一次"。
4. 流式事件链：`streamAssistantResponse` 把细粒度 delta 转成 `message_start/update/end`，UI 全量重建（DOM 侧归消息渲染器）。
5. 并发粒度是单会话单 agent 循环：steer（回合边界转向）与 followUp（排队）是运行中投递通道；abort 后以 `stopReason: "aborted"` 落盘。

## 系统边界与生成任务主链

```text
TUI/输入 -> AgentSession.prompt() (core/agent-session.ts:1116)
   扩展命令 / input 钩子 / skill+模板展开 / 模型+认证校验 / 预压缩检查
  -> Agent.prompt() (packages/agent/src/agent.ts:347)
  -> runAgentLoop (agent-loop.ts:95-118) -> runLoop (agent-loop.ts:155-275)
     内层: streamAssistantResponse -> 工具调用(并行/顺序) -> ToolResultMessage
     外层: steer/followUp 队列排空 -> agent_end
  -> 事件订阅: AgentSession._handleAgentEvent (core/agent-session.ts:610-681)
       message_end 落盘 -> 自动压缩/自动重试判定（落盘语义 -> 会话与消息管理）
```

边界：消息与条目的持久化形状、JSONL 落盘时机属于会话与消息管理（`../会话与消息管理/Pi-会话与消息管理调查笔记.md`）；命令面板、选择器与状态行的用户工作流属于 Chat UI（`<../Chat UI/Pi-ChatUI调查笔记.md>`）；流式组件的 DOM 重建与渲染节流属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

**输入处理顺序**由 `prompt()` 统一编排（`packages/coding-agent/src/core/agent-session.ts:1063-1333`），依次执行：
1. 命中 `/command` 时立即交给扩展执行（`_tryExecuteExtensionCommand`）；
2. 交给 `input` 扩展钩子，扩展可以标记已处理（handled），也可以改写输入（transform）；
3. `_expandSkillCommand` 把 `/skill:name` 展开为 `<skill>` 块；
4. `expandPromptTemplate` 展开提示词文件模板；
5. 会话正在流式输出时，输入转入 steer 或 followUp 队列等待；
6. 校验模型与认证信息；
7. `_checkCompaction` 执行发送前压缩检查；
8. 组装 user 消息，并带上挂起的 nextTurn 自定义消息；
9. 触发 `before_agent_start` 扩展事件，扩展可以改 system prompt 或注入 custom 消息；
10. `_runAgentPrompt` 循环调用 `agent.prompt()`，处理回合结束后的 `_handlePostAgentRun`，必要时用 `agent.continue()` 续跑。

以上展开受 `PromptOptions.expandPromptTemplates`（默认 true，`:1117`）控制；扩展 API 的 `sendUserMessage` 新增同名选项（默认 false，与 `deliverAs` 并列，`agent-session.ts:1481-1511`），扩展可按需复用命令/skill/模板展开。

任务对象：没有独立的"任务记录"；运行状态在 `Agent`/`AgentSession` 内，事件（`message_start/update/end`、`agent_start/end`、`queue_update`）是唯一对外通道。

## 2. 历史选择与上下文拼装顺序

历史先按分支与 compaction 确定范围，再应用该范围内最新的 context_edit。编辑可替换内容或从模型上下文排除条目，原始文件仍保留；恢复因此得到当前投影，进入模型上下文的只到投影这一层，替换与排除均在此层生效（[buildSessionProjection](../../pi/packages/coding-agent/src/core/session-manager.ts#L519-L570)）。

- **上下文投影**：`buildSessionContext` 是投影入口，沿当前叶节点的 parent 链回溯出路径，再转成条目列表（`packages/coding-agent/src/core/session-manager.ts:383-470`）。路径中出现 compaction 条目时，完整历史会被替换为一段压缩摘要、自 `firstKeptEntryId` 起的保留条目以及其后所有条目；compaction、branch_summary 与 custom_message 三类条目经条目转换投影为摘要消息，普通 `custom` 条目不参与（其数据语义见会话与消息管理笔记 §1）。
- **LLM 转换**：`convertToLlm` 把自定义角色转成 user 文本，bash 执行结果按 `excludeFromContext` 跳过，custom 与摘要消息则加上前缀/后缀包裹，最终输出 `packages/ai` 的 `Message[]` 数组（`packages/coding-agent/src/core/messages.ts:148-195`）。
- **system prompt**：默认模板只展示带一行 snippet 的工具，guidelines 随工具集推导，另外附上 Pi 自身的文档指引；拼装入口 `buildSystemPrompt` 的入参由 `_rebuildSystemPrompt` 汇总（`packages/coding-agent/src/core/system-prompt.ts:28-162`、`agent-session.ts:1023-1057`）。

  覆盖顺序：自定义 prompt（`customPrompt`，来自 `.pi/system-prompt.md` 等）替换默认模板，其后追加 `appendSystemPrompt`、`<project_context>` 文件、skills 区块与 cwd。

## 3. 预算、截断、摘要与压缩

- **token 估算**：按字符/块长度分角色估算，采用 chars/4 启发式，再加总到模型上下文窗口上（`compaction/compaction.ts:266-306`、`agent-session.ts:286-292`）。

  函数分工：单条估算用 `estimateTokens`，批量求和用 `estimateMessagesTokens`，窗口上限来自模型 `contextWindow`。

  定位更正：token 估算的实现位于 `compaction.ts`，`compaction/utils.ts` 只有文件操作清单与 `SUMMARIZATION_SYSTEM_PROMPT`（`compaction/utils.ts:156`）；此前笔记把估算位置标在了 `utils.ts`。
- **压缩触发**：`shouldCompact` 的判定条件是 `contextTokens > contextWindow - reserveTokens`，默认 reserve 16384、keepRecent 20000（`packages/coding-agent/src/core/compaction/compaction.ts:132-238`、`settings-manager.ts:780-786`）。命中后分两条路径：
  - **常规检查**：`_handlePostAgentRun` 里的 `_checkCompaction` 与发送前检查共用这个阈值，阈值路径的压缩完成后不重试（`agent-session.ts:1962-2053`）；
  - **溢出恢复**：溢出（`isContextOverflow` 命中，或 length 结束可恢复）时改为压缩并自动重试一次，`_overflowRecoveryAttempted` 只允许一次，随后调用 `_runAutoCompaction("overflow", willRetry)`（`agent-session.ts:1993-2022`）。
- **压缩执行**：先算切点再生成摘要——切点只落在上下文可见条目上，toolResult 不被切开，turn 内部允许分割；摘要记录保留起点、压缩前 token 数与文件操作清单。

  - 切点：`prepareCompaction` 调用 `findCutPoint` 计算切点位置（`packages/coding-agent/src/core/compaction/compaction.ts:403-789`）。
  - 摘要：`compact` 以 `SUMMARIZATION_SYSTEM_PROMPT` 生成摘要，写出保留起点、压缩前 token 数与文件操作清单 `CompactionDetails`（`compaction.ts:817-919`）。
  - 模型调用：摘要本身也是一次独立的 LLM 调用，统一走 `completeSummarization` 并复用 `settings.retry` 预算，结果由 `SessionManager.appendCompaction` 落盘（`compaction.ts:562-581`、`packages/coding-agent/src/core/session-manager.ts:1097-1119`）。
  - 手动入口：`/compact` 直接调用 `compact()`（`agent-session.ts:1790-1933`；入口见 Chat UI 笔记 §1）。
- 压缩是重写而非分页：旧条目仍在文件中但不再进上下文（持久化形状见会话与消息管理笔记 §9）。

## 4. SDK、Provider、模型与协议交接

- 调用链：会话层的 `Agent.prompt()` 交给 `runAgentLoop` 建立循环，内层由 `runLoop` 驱动（`packages/agent/src/agent.ts:347-358`、`agent-loop.ts:95-275`）。
- 请求组装：`streamAssistantResponse` 依次做上下文转换、LLM 消息转换与流式请求，输出 `packages/ai` 的 `Message[]` 数组（`packages/agent/src/agent-loop.ts:288-312`）。
- 模型与思考等级挂在会话状态上（`agent.state.model`、`thinkingLevel`，数据侧见会话与消息管理笔记 §8）；请求认证由 `_getRequiredRequestAuth` 解析 apiKey、headers 与环境变量（`agent-session.ts:409-444`）；具体 provider adapter 与协议层属于 LLM 渠道管理类目，本次未展开。
- `Agent` 是单活动运行的工具循环 runtime：运行中再次调用 prompt 会被拒绝，由 activeRun 守卫兜住（`packages/agent/src/agent.ts:347-489`）；内置没有多 Agent 编排（数据侧见会话与消息管理笔记 §8）。

## 5. 流式事件、缓冲、节流与顺序

- 事件链：`streamAssistantResponse` 消费 `AssistantMessageEventStream`，把其中的文本、思考与工具调用三类细粒度事件归一（`packages/agent/src/agent-loop.ts:281-372`）。
- 归一口径：开始、文本、思考、工具调用四类细粒度事件统一转成 `message_start` 与 `message_update` 两种对外事件。
- 结束事件：流结束时统一补发 `message_end`。
- 工具调用：`toolcall_end` 携带完整的 `ToolCall`，用它覆盖 partial 累积结果，partialJson 解析失败时另走兜底（`proxy.ts:322-351`）。
- UI 在收到 `message_update` 时整体重建 assistant 组件内容，TUI 渲染由 `requestRender` 节流，`MIN_RENDER_INTERVAL_MS` 为 16ms，间隔内的渲染请求合并成一帧（`interactive-mode.ts:3148-3181`、`packages/tui/src/tui.ts:343-817`）——组件重建与节流的 DOM 侧见消息渲染器笔记 §2。
- **工具增量**：`tool_execution_start/update/end` 三个事件驱动 `ToolExecutionComponent` 的流式输出；assistant 消息里的 `toolCall` 块在 `message_update` 时同步建组件并逐步更新参数（`interactive-mode.ts:3153-3268`）。

## 6. 完成、异常、半截流与最终回写

- **落盘**：agent 事件到达后，`_handleAgentEvent` 把 user、assistant 与工具结果消息交给 `sessionManager.appendMessage` 写入（`packages/coding-agent/src/core/agent-session.ts:640-657`）。会话文件在首条 user 或 assistant 消息落盘时创建，首轮没有回复也保留用户输入（[事件落盘](../../pi/packages/coding-agent/src/core/agent-session.ts#L1170-L1190)、[创建判定](../../pi/packages/coding-agent/src/core/session-manager.ts#L1161-L1189)）。
- **中断语义**：`abort()` 中止当前 agent 运行与正在执行的工具（`agent-session.ts:1550-1554`）。中断后的 assistant 消息以 `stopReason: "aborted"` 持久化：failure 消息在错误处理路径中构造，循环里另有一条提前结束分支（`packages/agent/src/agent.ts:511-527`、`agent-loop.ts:196-200`），下次恢复会话时载入该消息（恢复语义见会话与消息管理笔记 §3）。
- 完成/错误：`stopReason` 区分 stop、length、toolUse 与 error；length 截断时整批工具调用都不执行，改为以错误结果回注（`failToolCallsFromTruncatedMessage`，`agent-loop.ts:381-406`）；错误消息进入自动重试判定（§7）。

## 7. 停止、重试、续写与重新生成

- **重试**：会话层针对最后一个 assistant 错误消息，按 `settings.retry` 的预算退避后调用 `agent.continue()` 重跑（`agent-session.ts:2686-2736`）；默认启用、最多 3 次、初始延迟 2000ms 指数退避（`settings-manager.ts:820-826`）。是否重试先由结束判定决定，溢出类错误转走压缩（§3）。
- **自动重试中止**：自动重试等待期间按 Esc 可以中止，界面侧入口在 `interactive-mode.ts:3342-3353`（路径见 Chat UI 笔记 §5），会话侧对应 `abortRetry`（`agent-session.ts:2741-2743`）。
- **续写**：未找到"继续生成到当前消息末尾"的独立入口，续写通过分支或新消息实现（分支数据语义见会话与消息管理笔记 §4）。`Agent.continue()` 只服务于重试与队列续跑，遇到以 assistant 消息结尾的状态会拒绝执行（`packages/agent/src/agent.ts:360-388`）。
- **steer/followUp**：steer 与 followUp 是运行中的两条投递通道：steer 在当前工具回合结束后、下一次 LLM 调用前注入，followUp 留到 agent 结束后再处理（§8）。

## 8. 队列、多会话并发与后台生成

- **并发粒度是单会话单 agent 循环**：运行中可投递 steer（回合边界转向）与 followUp（排队）消息，两者分别由 `_queueSteer` 与 `_queueFollowUp` 接收（`packages/coding-agent/src/core/agent-session.ts:1343-1408`）。
- 队列消费模式有 `all` 与 `one-at-a-time` 两种，默认一次只取一个（`packages/agent/src/agent.ts:125-232`）；agent 结算事件通知 UI 回到空闲（`agent-session.ts:596-604`）。界面没有多会话并行。
- `followUp` 队列在 agent 自然结束前被排空；steer 在当前助手回复与工具批次结束后、下次请求发出前被消费，准备阶段还会补查一次。两者只入队，不会 abort 已在执行的模型流或工具（[队列入口与 abort](../../pi/packages/agent/src/agent.ts#L307-L351)、[循环边界](../../pi/packages/agent/src/agent-loop.ts#L267-L315)）。
- 队列 UI 的显示由 `queue_update` 事件驱动，`_steeringMessages` 与 `_followUpMessages` 两个数组追踪各自的排队消息（`agent-session.ts:319-575`；界面见 Chat UI 笔记 §5）。

## 9. Agent、工具、知识库与附件注入点

- 工具列表经默认模板进入 system prompt（拼装入口 `buildSystemPrompt`，见 §2）；会话级工具启用集见会话与消息管理笔记 §8；工具调用前后的 `beforeToolCall` / `afterToolCall` 钩子由扩展 runner 与图片规范化挂接（`packages/coding-agent/src/core/agent-session.ts:479-533`）。
- 附件与图片：`ImageContent` 在组装 user 消息时直接进入消息体；工具结果里的图片经 `normalizeToolResultImages` 回注为上下文图像（`agent-session.ts:517-1224`，数据侧见会话与消息管理笔记 §8）。
- 外部能力注入点都挂在 `prompt()` 链路上：`/skill:name` 展开、`/template` 文件模板、扩展注入的 custom 消息（含 nextTurn 挂起消息）、`before_agent_start` 改写 system prompt（`agent-session.ts:1159-1261`，机制见 §1）。
- 知识库：本次未发现独立的知识库注入机制，检查范围是 `prompt()` 链路与 system prompt 组装入口。

## 10. 退出恢复、日志与已确认边界

- **退出保留**：`dispose()` 依次中止重试、压缩、分支摘要与 bash 任务，最后才 abort agent（`agent-session.ts:839-856`）；切换会话前，`teardownCurrent` 先把进行中的响应（含工具结果）持久化到原会话（`agent-session-runtime.ts:167-178`）。
- 已确认边界：输入处理顺序、压缩阈值与重试预算已由源码确认；RPC 模式（`modes/rpc/`）与 server/client 包的会话通道由调用关系推断，本次未展开。`Agent.reset()` 在活动运行中会直接抛错（`packages/agent/src/agent.ts:333-345`）。
- 可观测性：`/session` 统计 token 与成本，数据取自 `getSessionStats`（数据侧见会话与消息管理笔记 §5）；日志与 trace 如何关联到具体任务本次未调查。

## 11. 未验证事项

- 流式视觉行为（节流、滚动、闪烁）未实测。
- `estimateTokens` 与真实计费的偏差未验证。
- 压缩后消息的模型侧多轮一致性（thinking signature、cache 语义）未实测。
- abort 的网络级取消与断网重连未验证。
- 未运行交互会话；结论来自静态源码。

## 12. 摘要请求与扩展消息顺序

压缩与分支摘要走独立的简单完成请求，不再强制传入 `toolChoice: "none"`，但摘要请求本身也不会附带工具目录；这避免了部分 provider 对显式工具选择的兼容问题，同时保持摘要模型不能发起本轮工具调用的边界。扩展以 `triggerTurn: false` 记录的 custom 消息，若发生在工具执行中的回合，会在该回合工具结果之后追加，保证回放给 provider 的工具调用与结果保持相邻（`packages/coding-agent/CHANGELOG.md` 的 Unreleased 修复项）。

## 13. Durable harness 请求链

durable 把一次输入拆成接纳与执行两层。`submit()` 先把输入持久化为 Submission 再开始执行，Task 按 phase 推进；run 是从一次输入到最终答案的 turn 序列，turn 是一次模型响应及其工具调用。每个 phase 结束都存 checkpoint，重启后 `resume()` 从最后一个 checkpoint 继续，等待中的任务以 phase 形式睡在存储里，不占用调用（`packages/durable/README.md` 的 Task 与 Resume 章节、`packages/durable/src/harness/scheduler.ts`）。

该链的上下文从存储中的 conversation 投影，工具结果先成为已结算 entry 再按调用顺序进入 transcript；shell 输出在源侧按行数和字节数限界，截断时尽力保留完整输出文件。它为进程重启提供恢复语义，服务于 p2。工具调用另在执行前提交 intent；重启只在存储与当前声明同时为 replay-safe 时重跑，默认 unsafe 的未完成调用结算 interrupted 并提示可能已部分运行，已提交结果复用。这是显式重放策略，无法推导为外部副作用恰好一次（[ToolTask](../../pi/packages/durable/src/harness/tool.ts#L177-L227)）。默认 coding-agent 的 `AgentSession.prompt()` 主链仍然存在（`packages/durable/src/harness/context.ts`、`packages/durable/src/harness/generation.ts`、`packages/durable/src/tools/`）。

稳定链的 compaction 设置支持按精确 `provider/modelId` 覆盖 reserveTokens 与 keepRecentTokens；两个字段分别回退到普通设置和内置默认值，模型切换后的下一次检查即采用新预算（`packages/coding-agent/src/core/settings-manager.ts:867-899`、`packages/coding-agent/docs/compaction.md:422-444`）。

## 14. 关键源码索引

- `packages/coding-agent/src/core/agent-session.ts:2121`：prompt 主链路；`:1123`：事件处理与落盘；`:2322`/`:2338`：steer/followUp；`:3203`：压缩判定
- `packages/coding-agent/src/core/session-manager.ts:418-470`：上下文构建
- `packages/coding-agent/src/core/system-prompt.ts:28-162`：system prompt 拼装
- `packages/coding-agent/src/core/messages.ts:148-195`：LLM 消息转换
- `packages/coding-agent/src/core/compaction/compaction.ts:235-238`：压缩阈值；`266-306`：token 估算；`562-581`：压缩即 LLM 调用；`817-919`：compact
- `packages/agent/src/agent.ts:347-358`、`:486-489`：单活动运行守卫；`333-345`：reset 守卫
- `packages/agent/src/agent-loop.ts`：agentLoop；`:390`：streamAssistantResponse
- `packages/coding-agent/src/core/agent-session-runtime.ts:167`：teardownCurrent
- `packages/durable/src/harness/`：scheduler、generation、context、compaction（durable 请求链）
