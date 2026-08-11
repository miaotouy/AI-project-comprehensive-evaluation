# Pi 对话请求与上下文调查笔记

> 调查对象：`../../pi`（重点 `packages/coding-agent/src/core/`、`packages/agent/src/`）
>
> 调查更新日期：2026-08-11
>
> 代码快照：`6b461b75b39b5a19b378dc42fbfbd1655bc446a6`（分支：`main`）
>
> 调查方式：从 [`../Chat/Pi-Chat调查笔记.md`](../Chat/Pi-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：发送主链路（prompt 输入处理）、上下文投影与 system prompt 组装、token 估算与自动压缩、agentLoop 工具循环、流式事件链、abort/重试/steer/followUp；会话持久化与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的生成任务由 `AgentSession.prompt()` 编排、`Agent`/`agentLoop` 执行：

1. 输入先经扩展命令/input 钩子/skill 与模板展开，再校验模型与认证，预压缩后组装 user 消息进入 agent 循环。
2. 上下文沿 leaf 沿 parent 链回溯构建；compaction/branch_summary 被投影为摘要消息，普通 custom 条目不参与；system prompt 由工具列表、项目上下文文件、skills、自定义提示组装。
3. 自动压缩基于 token 估算与 `contextWindow - reserveTokens` 阈值；溢出走"压缩并自动重试一次"。
4. 流式事件链：`streamAssistantResponse` 把细粒度 delta 转成 `message_start/update/end`，UI 全量重建（DOM 侧归消息渲染器）。
5. 并发粒度是单会话单 agent 循环：steer（打断）与 followUp（排队）是运行中投递通道；abort 后以 `stopReason: "aborted"` 落盘。

## 系统边界与生成任务主链

```text
TUI/输入 -> AgentSession.prompt() (core/agent-session.ts:1116)
   扩展命令 / input 钩子 / skill+模板展开 / 模型+认证校验 / 预压缩检查
  -> Agent.prompt() (packages/agent/src/agent.ts)
  -> runAgentLoop (agent-loop.ts:95-118) -> runLoop
     内层: streamAssistantResponse -> AssistantMessageEventStream
           工具调用 -> executeToolCalls(并行/顺序) -> ToolResultMessage
           外层: steer/followUp 队列排空 -> agent_end
  -> 事件订阅: AgentSession._handleAgentEvent (core/agent-session.ts:610-681)
       message_end 落盘 -> 自动压缩/自动重试判定（落盘语义 -> 会话与消息管理）
```

边界：消息与条目的持久化形状、JSONL 落盘时机属于会话与消息管理（`../会话与消息管理/Pi-会话与消息管理调查笔记.md`）；命令面板、选择器与状态行的用户工作流属于 Chat UI（`<../Chat UI/Pi-ChatUI调查笔记.md>`）；流式组件的 DOM 重建与渲染节流属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

**输入处理顺序**（`prompt()`，`agent-session.ts:1116-1273`）：扩展 `/command` 立即执行 → `input` 扩展钩子（可 handled/transform）→ `_expandSkillCommand` 展开 `/skill:name` 为 `<skill>` 块 → `expandPromptTemplate` 展开文件模板 → 若正在流式则入 steer/followUp 队列 → 校验模型与认证 → `_checkCompaction` 预压缩 → 组装 user 消息 + 挂起的 nextTurn 自定义消息 → `before_agent_start` 扩展事件（可改 systemPrompt、注入 custom 消息）→ `_runAgentPrompt`。

任务对象：没有独立的"任务记录"；运行状态在 `Agent`/`AgentSession` 内，事件（`message_start/update/end`、`agent_start/end`、`queue_update`）是唯一对外通道。

## 2. 历史选择与上下文拼装顺序

- **上下文投影**：`buildSessionContext`（`session-manager.ts:461-470`）→ `buildContextEntries`（`session-manager.ts:418-454`）：沿 leaf 回溯得到路径，路径中若含 compaction 条目，则用"compaction 摘要消息 + firstKeptEntryId 起的保留条目 + 其后所有条目"替代完整历史；`sessionEntryToContextMessages` 把 compaction/branch_summary/custom_message 条目分别投影为摘要消息（`session-manager.ts:383-408`）。普通 `custom` 条目不参与（其数据语义见会话与消息管理笔记 §1）。
- **LLM 转换**：`convertToLlm`（`core/messages.ts:148-195`）把自定义角色转成 user 文本（bash 执行、custom、摘要消息），输出 `packages/ai` 的 `Message[]`。
- **system prompt**：`buildSystemPrompt`（`core/system-prompt.ts:28-162`）：自定义 prompt（`customPrompt`，来自 `.pi/system-prompt.md` 等）替换默认模板，追加 `appendSystemPrompt`、`<project_context>` 文件、skills 区块、cwd；默认模板含工具列表（带一行 snippet 的工具才显示）、guidelines（含按工具集推导的提示）、Pi 自身文档指引。

## 3. 预算、截断、摘要与压缩

- **token 估算**：`estimateTokens` 基于字符/块长度估算（`core/compaction/utils.ts`、`agent-session.ts:286-292`），配合模型 `contextWindow`。
- **压缩触发**：`shouldCompact`：`contextTokens > contextWindow - reserveTokens`（`compaction.ts:235-237`，默认 reserve 16384、keepRecent 20000，`settings-manager.ts:12-16`）。两条路径：`_handlePostAgentRun` 的 `_checkCompaction`（`agent-session.ts:1962-2049`）和发送前检查；溢出（`isContextOverflow`/可恢复 length）走"压缩并自动重试一次"（实现在 `_checkCompaction` 的 overflow 分支 :1994-2021 与 `_runAutoCompaction("overflow", willRetry)` :2058+；无独立 `_handleOverflowRecovery` 函数），压缩本身也是 LLM 调用并复用 `settings.retry`（`compaction.ts:557-580`）。
- **压缩执行**：`compact`（`compaction.ts` 纯函数）以 `SUMMARIZATION_SYSTEM_PROMPT` 生成摘要、记录 `firstKeptEntryId`/`tokensBefore`/文件操作清单（`CompactionDetails`），`SessionManager.appendCompaction` 落盘（`session-manager.ts:1097-1119`）；`/compact` 手动触发（slash-commands.ts:38，入口见 Chat UI 笔记 §1）。
- 压缩是重写而非分页：旧条目仍在文件中但不再进上下文（持久化形状见会话与消息管理笔记 §9）。

## 4. SDK、Provider、模型与协议交接

- `Agent.prompt()` → `runAgentLoop`（`agent-loop.ts:95-118`）→ `runLoop`（`agent-loop.ts:155-275`）；`convertToLlm` 输出 `packages/ai` 的 `Message[]`。
- 模型在会话状态绑定（`agent.state.model/thinkingLevel`，数据侧见会话与消息管理笔记 §8）；具体 provider adapter/协议层本次未展开（属于 LLM 渠道管理类目）。
- `Agent` 是单循环 runtime（"No sub-agents"），无多 Agent 编排（数据侧见会话与消息管理笔记 §8）。

## 5. 流式事件、缓冲、节流与顺序

- `streamAssistantResponse`（`agent-loop.ts:281-372`）把 `AssistantMessageEventStream` 的 `start/text_*/thinking_*/toolcall_*` 逐事件转成 `message_start/message_update`，结束统一发 `message_end`。
- UI 在 `message_update` 时整体重建 assistant 组件内容（`interactive-mode.ts:3114-3146`），TUI 渲染由 `requestRender` 节流（`packages/tui/src/tui.ts:765-817`，`MIN_RENDER_INTERVAL_MS` 内合并帧）——组件重建与节流的 DOM 侧见消息渲染器笔记 §2。
- **工具增量**：`tool_execution_start/update/end` 事件驱动 `ToolExecutionComponent` 的流式输出（`interactive-mode.ts:3193-3234`）；assistant 消息里的 `toolCall` 块在 `message_update` 时同步建组件并逐步更新参数（`interactive-mode.ts:3119-3144`）。

## 6. 完成、异常、半截流与最终回写

- **落盘**：`AgentSession._handleAgentEvent` 对 user/assistant/toolResult 消息调用 `sessionManager.appendMessage`（`core/agent-session.ts:640-657`）；文件在第一条 assistant 消息落盘时创建（`_persist`，落盘时机见会话与消息管理笔记 §2）。
- **中断语义**：`AgentSession.abort()` 中止当前 agent 运行与工具；中断后 assistant 消息以 `stopReason: "aborted"` 持久化（`agent-loop.ts:196-200` 提前结束分支），下次 `/resume` 恢复该消息（恢复语义见会话与消息管理笔记 §3）。
- 完成/错误：`stopReason` 还区分 length/error；错误消息触发自动重试判定（§7）。

## 7. 停止、重试、续写与重新生成

- **重试**：`_prepareRetry`（`agent-session.ts:2686-2737`）用同一 `settings.retry` 预算，对最后一个 assistant 错误消息 sleep 后退避并 `agent.continue()`；`_willRetryAfterAgentEnd` 判定（`agent-session.ts:683-696`）；溢出类错误不重试走压缩（§3）。
- **自动重试中止**：自动重试期间 Esc 中止重试（`interactive-mode.ts:3308-3318`，入口见 Chat UI 笔记 §4）。
- **续写**：未找到"继续生成到当前消息末尾"的独立入口；续写通过分支/新消息实现（分支数据语义见会话与消息管理笔记 §4）。
- **steer/followUp**：运行中投递 steer（当前工具回合结束后、下一次 LLM 调用前注入）与 followUp（agent 结束后处理）两种队列（§8）。

## 8. 队列、多会话并发与后台生成

- **并发粒度是单会话单 agent 循环**：运行中可投递 steer（打断）与 followUp（排队）消息（`agent-session.ts:1379-1408`），无多会话并行 UI；`agent_settled` 事件通知 UI 进入空闲。
- `followUp` 队列在 agent 自然结束前排空（`agent-loop.ts:262-272`）。
- 队列 UI 显示由 `queue_update` 事件驱动（`agent-session.ts:319-323, 569-575`，界面见 Chat UI 笔记 §4）。

## 9. Agent、工具、知识库与附件注入点

- 工具列表进 system prompt（默认模板，`buildSystemPrompt`，§2）；会话级工具启用集见会话与消息管理笔记 §8。
- 附件/图片：`ImageContent` 进 user 消息；工具结果图片经 `normalizeToolResultImages` 回注为上下文图像（`agent-session.ts:517-531`，数据侧见会话与消息管理笔记 §8）。
- 外部能力注入点（均在 `prompt()` 链路，`agent-session.ts:1159-1261`）：`/skill:name` 展开、`/template` 文件模板、扩展注入的 custom 消息、`before_agent_start` 改写 system prompt（§1）。
- 知识库：本次未发现独立知识库注入机制（源笔记未覆盖），不虚构。

## 10. 退出恢复、日志与已确认边界

- **退出保留**：`dispose()` 先 abort 再清理；切换会话前 `teardownCurrent` 保证进行中响应（含工具结果）先持久化到原会话（`agent-session-runtime.ts:167-178`）。
- 已确认边界：输入处理顺序、压缩阈值与重试预算为源码确认；RPC 模式（`modes/rpc/`）与 server/client 包的会话通道仅从调用关系推断，未展开。
- 可观测性：`/session` 统计 token/成本（数据侧见会话与消息管理笔记 §5）；日志/trace 关联到具体任务的机制未调查。

## 11. 未验证事项

- 流式视觉行为（节流、滚动、闪烁）未实测。
- `estimateTokens` 与真实计费的偏差未验证。
- 压缩后消息的模型侧多轮一致性（thinking signature、cache 语义）未实测。
- abort 的网络级取消与断网重连未验证。
- 未运行交互会话；结论来自静态源码（与源笔记一致）。

## 12. 关键源码索引

- `packages/coding-agent/src/core/agent-session.ts:1116-1273`：prompt 主链路；`610-681`：事件处理与落盘；`2686-2737`：重试；`1379-1408`：steer/followUp
- `packages/coding-agent/src/core/session-manager.ts:418-470`：上下文构建
- `packages/coding-agent/src/core/system-prompt.ts:28-162`：system prompt 拼装
- `packages/coding-agent/src/core/messages.ts:148-195`：LLM 消息转换
- `packages/coding-agent/src/core/compaction/compaction.ts:235-237`：压缩阈值；`557-580`：压缩即 LLM 调用
- `packages/agent/src/agent-loop.ts:95-275`：agentLoop；`281-372`：流式转事件
- `packages/coding-agent/src/core/agent-session-runtime.ts:167-178`：teardownCurrent
