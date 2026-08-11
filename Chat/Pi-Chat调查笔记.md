# Pi Chat 概览

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

> 迁移状态（2026-08-11）：本文件已压缩为概览。内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/Pi-会话与消息管理调查笔记.md`](../会话与消息管理/Pi-会话与消息管理调查笔记.md)（JSONL 树模型、落盘时机、生命周期与分支指针、列表搜索与绑定）
> - 对话请求与上下文：[`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)（prompt 主链路、上下文投影、压缩与重试、agentLoop 与事件链）
> - Chat UI：[`../Chat UI/Pi-ChatUI调查笔记.md`](<../Chat UI/Pi-ChatUI调查笔记.md>)（命令面板、选择器、状态行与键盘工作流）
> - 消息渲染：[`../消息渲染器/Pi-消息渲染器调查笔记.md`](../消息渲染器/Pi-消息渲染器调查笔记.md)（已有独立笔记）
>
> 2026-08-11 本文件已压缩为概览

## 结论摘要

Pi 是命令行编码 Agent，对话能力由 `packages/coding-agent` 的 `AgentSession`（会话编排）与 `packages/agent` 的 `Agent`/`agentLoop`（LLM 工具循环）共同实现，交互层为 TUI（键盘工作流）与 print/json 两种非交互模式：

1. **会话是 JSONL 追加型树**：每个会话一个 `.jsonl` 文件（`~/.pi/agent/sessions/<编码cwd>/`），记录带 `id/parentId` 形成树，`leafId` 指针标识当前位置；分支只移动指针不修改历史（`core/session-manager.ts:844-854`）。
2. **消息是分块内容模型**：`AgentMessage` 区分 user/assistant/toolResult 与 custom/bashExecution/compactionSummary/branchSummary；assistant 内容是 `text/thinking/toolCall` 块数组，流式事件逐块上报。
3. **落盘在 message_end**：文件在第一条 assistant 消息时创建（此前仅缓存），此后逐条 append（`session-manager.ts:1015-1042`）。
4. **主链路**：`session.prompt()`（扩展命令/钩子/skill 展开）→ `agent.prompt()` → `agentLoop` 驱动“流式生成—工具执行—结果回注”直到 `agent_end`（`agent-loop.ts:155-275`）。

## 产品表面与系统边界

- **产品表面**：终端 TUI（底部多行 editor、`/` 命令与 fuzzy autocomplete、Ctrl+P 模型循环、状态行指示 Working/Retry/Compaction、可选 OSC 9;4 进度条）；另有 print/json 非交互模式与 RPC 服务模式（RPC 仅从调用关系推断）。
- **系统边界**：模型推理由外部 provider 经 `packages/ai` 完成；会话事实源是磁盘 JSONL；单会话单 agent 循环，运行中可投递 steer/followUp，无多会话并行 UI；`bash` 执行内建于工具循环。

## 端到端聊天主链

```text
TUI 输入（interactive-mode.ts）
  -> AgentSession.prompt()（core/agent-session.ts:1116）
     扩展命令 / input 钩子 / skill+模板展开 / 模型认证校验 / 预压缩检查
  -> Agent.prompt()（packages/agent/src/agent.ts）
  -> runAgentLoop（agent-loop.ts:95-118）
     内层：streamAssistantResponse -> 工具执行（并行/顺序）-> ToolResultMessage
     外层：steer/followUp 队列排空 -> agent_end
  -> AgentSession._handleAgentEvent（agent-session.ts:610-681）
     扩展事件 -> 用户监听 -> message_end 落盘 -> 自动压缩/自动重试判定
  -> TUI requestRender 节流渲染（message_update 全量重建 assistant 组件）
```

## 核心对象与状态权威

- **SessionEntry 树**（`session-manager.ts:144-153`）：`message/thinking_level_change/model_change/compaction/branch_summary/custom/custom_message/label/session_info`；`custom` 不参与 LLM 上下文，`custom_message` 参与并控制 TUI 显示。
- **AgentMessage/AssistantMessage**（`packages/ai/src/types.ts:412-445`）：含 `content` 块数组、usage、stopReason、errorMessage；工具结果以独立 `ToolResultMessage` 成消息。
- **权威源**：磁盘 JSONL（`SessionManager` 追加写）；`leafId` 是分支位置权威指针；模型/thinking level 与会话级工具启用集（默认 `[read, bash, edit, write]`）绑定在会话状态；UI 状态行只是投影。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/Pi-会话与消息管理调查笔记.md`](../会话与消息管理/Pi-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/Pi-ChatUI调查笔记.md>`](<../Chat UI/Pi-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/Pi-消息渲染器调查笔记.md`](../消息渲染器/Pi-消息渲染器调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- 支持：分支（`branch`/`createBranchedSession`/`forkFrom`/`branchWithSummary`）、`/tree` 树导航与 label 书签、compaction 自动压缩（`contextTokens > contextWindow - reserveTokens`，默认 reserve 16384/keepRecent 20000）与溢出“压缩+自动重试”、自动重试（sleep 退避）、steer/followUp 运行中投递、会话删除（trash 优先）、HTML/JSONL 导出与 gist 分享、列表并发扫描（上限 10）与 fuzzy/re: 搜索。
- 已确认边界：历史是追加型，无消息就地编辑（修改以分支表达）；续写无独立入口；消息级搜索未接入（`ScanningSessionSearch` 在 harness SDK，未接 TUI/AgentSession 路径）；压缩是“重写上下文而非删历史”，旧条目保留可回溯；`custom`/`bashExecution(excludeFromContext)`/`custom_message(display=false)` 各自独立控制“是否进 LLM 上下文”与“是否可见”。

## 未验证事项

- 未运行交互会话：流式节流、滚动、闪烁等视觉行为未实测。
- `estimateTokens` 与真实计费的偏差未验证；压缩后模型侧多轮一致性（thinking signature、cache 语义）未实测。
- RPC 模式（`modes/rpc/`）与 server/client 包会话通道仅从调用关系推断。

## 关键源码索引

- `packages/coding-agent/src/core/agent-session.ts:1116-1273`：prompt 主链路；`:610-681` 事件处理与落盘；`:2686-2737` 自动重试
- `packages/coding-agent/src/core/session-manager.ts:844-854`：会话树；`:1015-1042` 落盘时机；`:461-470` 上下文构建；`:1638-1713` 列表
- `packages/agent/src/agent-loop.ts:155-275`：工具循环；`:281-372` 流式转事件
- `packages/coding-agent/src/core/compaction/compaction.ts:235-237`：压缩阈值；`core/system-prompt.ts:28-162`：system prompt 拼装
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts:3090-3234`：流式 UI 更新；`core/settings-manager.ts:12-34`：压缩/重试设置
