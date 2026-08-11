# Pi Chat 调查笔记

> 调查对象：`../../pi`（重点 `packages/coding-agent/src/core/`、`packages/agent/src/`）
>
> 调查更新日期：2026-08-10
>
> 代码快照：`6b461b75b39b5a19b378dc42fbfbd1655bc446a6`（分支：`main`）
>
> 调查方式：只读源码梳理 AgentSession、SessionManager、agent-loop 与交互模式的事件流；未运行交互会话
>
> 调查范围：会话/消息数据模型、生命周期与持久化、发送与流式主链路、上下文构建与压缩、分支与重试、列表检索、Agent/模型/工具绑定、核心 UI 交互；RPC/服务端模式的会话通道只说明调用关系
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/Pi-会话与消息管理调查笔记.md`](../会话与消息管理/Pi-会话与消息管理调查笔记.md)（JSONL 树模型、落盘时机、生命周期与分支指针、列表搜索与绑定）
> - 对话请求与上下文：[`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)（prompt 主链路、上下文投影、压缩与重试、agentLoop 与事件链）
> - Chat UI：[`../Chat UI/Pi-ChatUI调查笔记.md`](<../Chat UI/Pi-ChatUI调查笔记.md>)（命令面板、选择器、状态行与键盘工作流）
> - 消息渲染：[`../消息渲染器/Pi-消息渲染器调查笔记.md`](../消息渲染器/Pi-消息渲染器调查笔记.md)（已有独立笔记）

## 结论摘要

Pi 是命令行编码 Agent，对话能力由 `packages/coding-agent` 的 `AgentSession`（会话编排）与 `packages/agent` 的 `Agent`/`agentLoop`（LLM 工具循环）共同实现，交互层有 TUI 与 print/json 三种模式：

1. **会话是 JSONL 追加型树**：每个会话一个 `.jsonl` 文件（`~/.pi/agent/sessions/<编码cwd>/`），每条记录带 `id/parentId` 形成树；`leafId` 指针标识当前位置，分支只移动指针不修改历史（`core/session-manager.ts:844-854` 类注释）。
2. **消息是分块内容模型**：`AgentMessage`（`packages/agent/src/types.ts`）区分 user/assistant/toolResult 与 custom/bashExecution/compactionSummary/branchSummary；assistant 内容是 `text/thinking/toolCall` 块数组，流式事件逐块上报（`packages/ai/src/types.ts:515-531`）。
3. **落盘发生在 message_end**：`AgentSession._handleAgentEvent` 对 user/assistant/toolResult 消息调用 `sessionManager.appendMessage`（`core/agent-session.ts:640-657`）；文件在第一条 assistant 消息落盘时创建，此前仅缓存（`session-manager.ts:1015-1042` 的 `_persist`）。
4. **发送主链路**：输入 → `session.prompt()`（扩展命令/input 钩子/skill 与模板展开/steer-followUp 队列）→ `agent.prompt()` → `agentLoop` 驱动“流式生成—工具执行—结果回注”直到 agent_end（`packages/agent/src/agent-loop.ts:155-275`）。
5. **上下文构建**：`buildSessionContext` 从叶子沿 parent 链回溯，compaction/branch_summary 条目被投影为摘要消息，普通 custom 条目不参与；system prompt 由 `buildSystemPrompt` 组装（工具列表、项目上下文文件、skills、自定义提示）。自动压缩基于 token 估算与 `contextWindow - reserveTokens` 阈值（`core/compaction/compaction.ts:235-237`）。
6. **并发粒度是单会话单 agent 循环**：运行中可投递 steer（打断）与 followUp（排队）消息（`agent-session.ts:1379-1408`），无多会话并行 UI；`agent_settled` 事件通知 UI 进入空闲。

## 系统边界与总体调用链

```text
TUI/输入 (modes/interactive/interactive-mode.ts)
  -> AgentSession.prompt() (core/agent-session.ts:1116)
     扩展命令 / input 钩子 / skill+模板展开 / 模型+认证校验 / 预压缩检查
  -> Agent.prompt() (packages/agent/src/agent.ts)
  -> runAgentLoop (agent-loop.ts:95-118) -> runLoop
     内层: streamAssistantResponse -> AssistantMessageEventStream
           工具调用 -> executeToolCalls(并行/顺序) -> ToolResultMessage
           外层: steer/followUp 队列排空 -> agent_end
  -> 事件订阅:
     AgentSession._handleAgentEvent (core/agent-session.ts:610-681)
       扩展事件 -> 用户监听 -> message_end 落盘 -> 自动压缩/自动重试判定
     UI 订阅: 流式更新组件 -> TUI requestRender (节流)
```

## 1. 会话与消息数据模型

- **会话单位**：`SessionManager` 构造时生成 `uuidv7` 会话 id（`session-manager.ts:208-210`）；文件名为 `<ISO时间戳(冒号与句点替换为连字符)>_<id>.jsonl`（`session-manager.ts:952-953`，`timestamp.replace(/[:.]/g, "-")`）。文件首行是 `SessionHeader { type, version(当前3), id, timestamp, cwd, parentSession? }`（`session-manager.ts:32-39`）。
- **条目类型**：`SessionEntry` 联合 `message/thinking_level_change/model_change/compaction/branch_summary/custom/custom_message/label/session_info`（`session-manager.ts:144-153`）。其中 `custom` 是扩展状态存储（不参与 LLM 上下文），`custom_message` 参与上下文并控制 TUI 显示（`session-manager.ts:94-141`）。
- **消息结构**：`AgentMessage` 由 `packages/agent/src/types.ts` 定义；assistant 消息复用 `AssistantMessage`（`packages/ai/src/types.ts:412-427`），含 `content` 块数组、`usage`、`stopReason`、`errorMessage`、`deferred` 句柄。工具结果以 `ToolResultMessage`（role=toolResult，`types.ts:429-445`）独立成消息。
- **版本迁移**：v1→v2 生成 id/parentId 树，v2→v3 把 `hookMessage` 角色改名为 `custom`（`session-manager.ts:230-291`）；读文件时若版本落后则迁移并重写文件（`session-manager.ts:917-919`）。

## 2. 会话生命周期与持久化

- **新建/继续/恢复**：`SessionManager.create/open/continueRecent/inMemory`（`session-manager.ts:1519-1570`）。`AgentSessionRuntime.newSession/switchSession` 先 `teardownCurrent`（abort 当前响应 → 发 `session_shutdown` 扩展事件 → dispose）再创建新 runtime（`core/agent-session-runtime.ts:167-260`）。
- **分支**：`branch(branchFromId)` 移动 leaf 指针（`session-manager.ts:1360-1365`）；`createBranchedSession` 把“根到指定叶子”的路径抽成新文件并重链 label 条目（`session-manager.ts:1412-1512`）；`forkFrom` 跨目录复制整个会话到新 cwd 并记 `parentSession`（`session-manager.ts:1579-1630`）。`branchWithSummary` 追加 `branch_summary` 摘要条目（`session-manager.ts:1381-1405`）。
- **删除/归档**：SessionManager 类无删除方法，但 UI 层存在持久化删除：`session-selector.ts:645` 的 `deleteSessionFile`（trash 优先、unlink 兜底，:832 挂到会话选择器删除处理），快捷键 Ctrl+D（`app.session.delete`）与 Ctrl+Backspace（`deleteSessionNoninvasive`，keybindings.ts:147-154、267-268）；`/clone` 是复制当前会话（slash-commands.ts:32），`/tree` 切换分支。
- **命名**：`appendSessionInfo(name)` 记录 `session_info` 条目，空字符串清除名字（`session-manager.ts:1136-1147`）；显示名取最新条目（`getSessionName`，`session-manager.ts:1150-1161`）。
- **落盘时机**：`_persist`（`session-manager.ts:1015-1042`）：没有 assistant 消息时只缓存；第一条 assistant 消息到达时整文件写出（`flushed=true`），此后逐条 append。这保证了“没有模型回复的会话不产生文件”。
- **导入导出**：`/export` 支持 HTML（`core/export-html/`，marked+highlight.js 静态页面）与 JSONL；`/import` 复制 JSONL 到会话目录后恢复（`agent-session-runtime.ts:361-396`）；`/share` 以 GitHub secret gist 分享。

## 3. 发送、流式更新与中断

- **输入处理顺序**（`prompt()`，`agent-session.ts:1116-1273`）：扩展 `/command` 立即执行 → `input` 扩展钩子（可 handled/transform）→ `_expandSkillCommand` 展开 `/skill:name` 为 `<skill>` 块 → `expandPromptTemplate` 展开文件模板 → 若正在流式则入 steer/followUp 队列 → 校验模型与认证 → `_checkCompaction` 预压缩 → 组装 user 消息 + 挂起的 nextTurn 自定义消息 → `before_agent_start` 扩展事件（可改 systemPrompt、注入 custom 消息）→ `_runAgentPrompt`。
- **流式事件**：`streamAssistantResponse`（`agent-loop.ts:281-372`）把 `AssistantMessageEventStream` 的 `start/text_*/thinking_*/toolcall_*` 逐事件转成 `message_start/message_update`，结束统一发 `message_end`。UI 在 `message_update` 时整体重建 assistant 组件内容（`interactive-mode.ts:3114-3146`），TUI 渲染由 `requestRender` 节流（`packages/tui/src/tui.ts:765-817`，`MIN_RENDER_INTERVAL_MS` 内合并帧）。
- **工具增量**：`tool_execution_start/update/end` 事件驱动 `ToolExecutionComponent` 的流式输出（`interactive-mode.ts:3193-3234`）；assistant 消息里的 `toolCall` 块在 `message_update` 时同步建组件并逐步更新参数（`interactive-mode.ts:3119-3144`）。
- **中断语义**：`AgentSession.abort()` 中止当前 agent 运行与工具；中断后 assistant 消息以 `stopReason: "aborted"` 持久化（`agent-loop.ts:196-200` 提前结束分支），UI 显示中止原因（`interactive-mode.ts:3154-3161`）。自动重试期间 Esc 中止重试（`interactive-mode.ts:3308-3318`）。
- **退出保留**：`dispose()` 先 abort 再清理；切换会话前 `teardownCurrent` 保证进行中响应（含工具结果）先持久化到原会话（`agent-session-runtime.ts:167-178`）。

## 4. 上下文构建、截断与压缩

- **上下文投影**：`buildSessionContext`（`session-manager.ts:461-470`）→ `buildContextEntries`（`session-manager.ts:418-454`）：沿 leaf 回溯得到路径，路径中若含 compaction 条目，则用“compaction 摘要消息 + firstKeptEntryId 起的保留条目 + 其后所有条目”替代完整历史；`sessionEntryToContextMessages` 把 compaction/branch_summary/custom_message 条目分别投影为摘要消息（`session-manager.ts:383-408`）。
- **LLM 转换**：`convertToLlm`（`core/messages.ts:148-195`）把自定义角色转成 user 文本（bash 执行、custom、摘要消息），输出 `packages/ai` 的 `Message[]`。
- **system prompt**：`buildSystemPrompt`（`core/system-prompt.ts:28-162`）：自定义 prompt（`customPrompt`，来自 `.pi/system-prompt.md` 等）替换默认模板，追加 `appendSystemPrompt`、`<project_context>` 文件、skills 区块、cwd；默认模板含工具列表（带一行 snippet 的工具才显示）、guidelines（含按工具集推导的提示）、Pi 自身文档指引。
- **token 估算**：`estimateTokens` 基于字符/块长度估算（`core/compaction/utils.ts`、`agent-session.ts:286-292`），配合模型 `contextWindow`。
- **压缩触发**：`shouldCompact`：`contextTokens > contextWindow - reserveTokens`（`compaction.ts:235-237`，默认 reserve 16384、keepRecent 20000，`settings-manager.ts:12-16`）。两条路径：`_handlePostAgentRun` 的 `_checkCompaction`（`agent-session.ts:1962-2049`）和发送前检查；溢出（`isContextOverflow`/可恢复 length）走“压缩并自动重试一次”（实现在 `_checkCompaction` 的 overflow 分支 :1994-2021 与 `_runAutoCompaction("overflow", willRetry)` :2058+；无独立 `_handleOverflowRecovery` 函数），压缩本身也是 LLM 调用并复用 `settings.retry`（`compaction.ts:557-580`）。
- **压缩执行**：`compact`（`compaction.ts` 纯函数）以 `SUMMARIZATION_SYSTEM_PROMPT` 生成摘要、记录 `firstKeptEntryId`/`tokensBefore`/文件操作清单（`CompactionDetails`），`SessionManager.appendCompaction` 落盘（`session-manager.ts:1097-1119`）；`/compact` 手动触发（slash-commands.ts:38）。

## 5. 编辑、重试、续写与分支

- **重试**：`_prepareRetry`（`agent-session.ts:2686-2737`）用同一 `settings.retry` 预算，对最后一个 assistant 错误消息 sleep 后退避并 `agent.continue()`；`_willRetryAfterAgentEnd` 判定（`agent-session.ts:683-696`）；溢出类错误不重试走压缩。
- **分支/回退**：`/fork` 从指定 user 消息创建分支（`agent-session-runtime.ts:262-352`，`position: before|at`）；`/tree` 导航分支；`navigateTree` 支持 summarize/自定义指令/替换指令/label（`sdk.ts` 附近）。`resetLeaf` 把指针清空以便重发首条 user 消息（`session-manager.ts:1372-1374`）。
- **续写**：未找到“继续生成到当前消息末尾”的独立入口；续写通过分支/新消息实现。`followUp` 队列在 agent 自然结束前排空（`agent-loop.ts:262-272`）。
- **消息编辑**：本次未找到对已落盘消息的就地编辑 API；历史是追加型，修改以分支形式表达。

## 6. 列表、搜索与定位

- **会话列表**：`SessionManager.list(cwd)`/`listAll()`（`session-manager.ts:1638-1713`）扫描 `sessions/` 下各 cwd 目录的 `.jsonl`，`buildSessionInfo` 流式读文件提取 id/cwd/name/messageCount/firstMessage/allMessagesText，并发上限 10（`session-manager.ts:771-809`），按修改时间倒序。`--session-dir` 自定义目录时按 header.cwd 过滤（`session-manager.ts:1641-1646`）。
- **搜索**：`session-selector-search.ts` 支持 token 模式（fuzzy/短语混合，`"node cve"` 引号）与 `re:` 正则模式，搜索文本是 `id + name + 全部消息文本 + cwd`（`session-selector-search.ts:26-57`）；`/resume` 会话选择器内嵌搜索框。消息级搜索本次未找到（消息全文不建索引，列表页一次性扫描；另存 harness SDK 的 `ScanningSessionSearch`（packages/agent/src/harness/session/search.ts）可逐条目全文扫描 JSONL，未接入 TUI/AgentSession 路径）。
- **定位**：`/session` 显示统计（用户/助手/工具消息数、token、成本）；`/tree` 树形导航带 label 书签（`getTree`，`session-manager.ts:1310-1348`）。

## 7. Agent、模型、工具与附件

- **绑定层级**：模型与 thinking level 绑定在会话状态（`agent.state.model/thinkingLevel`），切换模型写入 `model_change` 条目；工具启用集在会话级（`setActiveToolsByName`，`agent-session.ts:928-943`），默认 `[read, bash, edit, write]`（`agent-session.ts:211-212`），`--tools`/设置可增删。
- **Agent 形态**：`Agent` 是单循环 runtime（`packages/agent/src/agent.ts`，仅导出 `Agent` 类，README 明确 "No sub-agents"），`AgentSession` 包一层事件/持久化/压缩。子 Agent：扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- **附件**：图片以 `ImageContent` 进 user 消息（剪贴板图片、`--image`、拖动/粘贴，`interactive-mode.ts` 相关入口）；`settings.images` 控制自动缩放与阻止发送（`settings-manager.ts:45-48`）。工具结果中的图片可回注为上下文图像（`normalizeToolResultImages`，`agent-session.ts:517-531`）。
- **外部能力**：skills（`/skill:name` 展开为 `<skill>` 块 + 进 system prompt 索引）、prompt 模板（`/template`）、扩展注入的 custom 消息、`before_agent_start` 系统提示改写均在此链路生效（`agent-session.ts:1159-1261`）。

## 8. 核心 UI 交互

- **输入区**：底部多行 editor（`packages/tui/src/components/editor.ts`），支持 autocomplete（fuzzy）、`/` 命令补全、快捷键（Ctrl+P 模型循环、Ctrl+G 外部编辑器等，`core/keybindings.ts`）。
- **流式反馈**：正在生成时 footer 显示模型/状态，retry/compaction 有专用状态指示器（`status-indicator.ts`：Working/Retry/Compaction/BranchSummary/Idle）；可配置 OSC 9;4 终端进度条（`settings-manager.ts:42`）。
- **运行中投递**：steer（当前工具回合结束后、下一次 LLM 调用前注入）与 followUp（agent 结束后处理）两种队列，`queue_update` 事件驱动 UI 显示待处理列表（`agent-session.ts:319-323, 569-575`）。
- **bash 执行**：`!` 前缀直跑命令，`!!` 排除上下文；`BashExecutionComponent` 流式显示输出（`components/bash-execution.ts`），`bash_execution_update` 事件增量刷新。
- **退出**：`/quit`、双击 Esc（`doubleEscapeAction: fork|tree|none`，`settings-manager.ts:122`）。

## 9. 设计取舍与已确认边界

- **追加型树会话**：不覆盖历史，编辑以分支表达；代价是单个文件持续增长，恢复时全量读入内存（`loadEntriesFromFile`，`session-manager.ts:514-556`，1MB 缓冲流式解析）。
- **事件驱动但全量重渲染**：`message_update` 每 delta 触发组件重建，TUI 以帧节流兜底；没有增量 AST 或虚拟列表。
- **压缩是重写而非分页**：压缩后旧条目仍在文件中但不再进上下文，保留可回溯性；token 估算基于启发式，非 Provider 真值。
- **单会话单循环**：steer/followUp 队列缓解了运行中交互，但不支持同一 TUI 内多会话并行生成。
- **上下文边界明确**：`custom` 条目、`bashExecution(excludeFromContext)`、`custom_message(display=false)` 各自独立控制“是否进 LLM 上下文”与“是否可见”。

## 10. 扩展调查（可选）

- **离线/异常恢复**：abort 后消息以 aborted 状态持久化，下次 `/resume` 会恢复该消息；未找到断网重连后的自动续传。
- **导出**：HTML 导出为自包含页面（marked + highlight.js + ANSI 转换，`core/export-html/`），支持工具调用展开渲染（`tool-renderer.ts`）。
- **性能**：会话列表读取有并发上限，但长会话首屏渲染为全量重建；未运行基准。

## 11. 未验证事项

- 未运行交互会话，流式视觉行为（节流、滚动、闪烁）未实测。
- `estimateTokens` 与真实计费的偏差未验证。
- 压缩后消息的模型侧多轮一致性（thinking signature、cache 语义）未实测。
- RPC 模式（`modes/rpc/`）与 server/client 包的会话通道仅从调用关系推断。

## 12. 关键源码索引

- `packages/coding-agent/src/core/agent-session.ts:1116-1273`：prompt 主链路；`610-681`：事件处理与落盘
- `packages/coding-agent/src/core/session-manager.ts:844-854`：会话树模型；`1015-1042`：落盘时机；`461-470`：上下文构建
- `packages/agent/src/agent-loop.ts:155-275`：工具循环；`281-372`：流式转事件
- `packages/coding-agent/src/core/compaction/compaction.ts:235-237`：压缩阈值
- `packages/coding-agent/src/core/system-prompt.ts:28-162`：system prompt 拼装
- `packages/coding-agent/src/core/messages.ts:148-195`：LLM 消息转换
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts:3090-3234`：流式 UI 更新
- `packages/coding-agent/src/core/settings-manager.ts:12-34`：压缩/重试设置
