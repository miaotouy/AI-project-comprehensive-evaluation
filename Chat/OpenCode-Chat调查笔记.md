# OpenCode Chat 概览

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：只读源码静态梳理会话数据模型、发送链路、事件流与持久化；未运行构建与真实对话
>
> 调查范围：会话/消息/part 数据模型、生命周期与 SQLite 持久化、发送主链路、流式与中断、上下文构建与压缩、消息操作、列表与检索、外部能力绑定、TUI 与 Web 交互；桌面端（Electron）窗口/草稿差异仅核实边界；V2 事件溯源架构并行对照
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的 Chat 体系以「服务端 SQLite 权威 + 事件发布 + 客户端投影」为核心：服务端把每次增量落库并发布 `message.updated`/`message.part.updated`/`message.part.delta` 事件（`src/session/session.ts:631-645`），经 SSE 推送，Web App 以 16ms 批量 flush 与 delta 拼接后投影到 Solid store（`app/src/context/server-sdk.tsx`、`server-session.ts`）。消息模型为 Session → Message（role: user/assistant）→ Part（12 种类型）三层，part 独立存表、读取时组装（`core/src/session/sql.ts`、`src/session/message-v2.ts`）；模型请求主链路 `SessionPrompt.prompt → loop → processor → LLM.stream`（AI SDK `streamText`），每轮从数据库重读历史。V1 为生产主路径，V2 事件溯源双轨并存。

## 产品表面与系统边界

- **产品表面**：Web App（Solid，虚拟化 timeline）+ TUI（Go）双渲染栈；Electron 桌面（renderer 复用 `@opencode-ai/app`，sidecar 进程内运行同一 opencode server）；另有单文件 Slack bot（`packages/slack/src/index.ts`，145 行，socket-mode 按 channel+thread 建 session 转发文本）——属转发型客户端，不承载完整会话 UI。
- **系统边界**：SQLite（`Global.Path.data/opencode.db`）是会话与消息唯一事实源，客户端 store 是投影；模型推理由外部 provider 完成；HTTP 端点与 SSE `/event` 是唯一写入与事件通道。

## 端到端聊天主链

```text
App submit（components/prompt-input/submit.ts） -> api.session.prompt
  -> POST /session/:id/prompt_async（V1）
  -> SessionPrompt.prompt（prompt.ts:1052-1071）
     revert.cleanup -> createUserMessage（user message + parts 立即落库）
     -> loop -> processor.create -> handle.process（processor.ts:627-683）
     -> llm.stream（llm.ts:357-381，AI SDK streamText）
  -> LLMEvent 流（llm/ai-sdk.ts）-> SessionProcessor.handleEvent（processor.ts:278-537）
  -> session.updateMessage/updatePart 发布事件（session.ts:631-645）
  -> EventV2Bridge -> SSE /event（handlers/event.ts）
  -> App server-sdk.tsx 读取循环 -> event-reducer / server-session 投影到 store
  -> 虚拟化 timeline 渲染（pages/session/timeline/message-timeline.tsx）
```

## 核心对象与状态权威

- **Session/Message/Part 三层**：Session 带 `agent/model/summary_*/cost/tokens_*/revert` 等字段；Message 的 `data` 列不含 parts（part 独立存表，仅 `message_id` 带 cascade 外键），读取时 `MessageV2.hydrate` 批量组装；Part 12 种类型（text/subtask/reasoning/file/tool/step-start/step-finish/snapshot/patch/agent/retry/compaction）。ID 体系：Session `ses_`（降序，新会话在前）、Message `msg_`、Part `prt_`。
- **权威源**：SQLite（服务端唯一事实源）；客户端 `server-session.ts` 是投影；`SessionRunState`/`Runner`（每 session 一个，Idle/Running/Shell）是运行状态权威。
- **写入与广播强耦合**：`updateMessage/updatePart` 只发事件，DB 写入由事件投影器完成——事件顺序即持久化顺序。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/OpenCode-会话与消息管理调查笔记.md`](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md`](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/OpenCode-ChatUI调查笔记.md>`](<../Chat UI/OpenCode-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/OpenCode-消息渲染调查笔记.md`](../消息渲染器/OpenCode-消息渲染调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- 支持：流式三层落库频率（delta 事件 / end 时完整写 part / tool 状态即时落库）、上下文压缩（compaction 生成 [compaction-user, summary-assistant, tail, continue-user] 重排并标记旧 tool 输出 `time.compacted`；压缩请求的对话历史以文本序列化拼接，`compaction.ts:52-83`、:387、:427-438）、revert 回退（删除目标之后消息，以 `findIndex`+`slice` 定位，`revert.ts:74-75`、:106-114）、fork 复制新会话、多会话并发（不同 session 并行、同 session 串行）、后台任务与 detach 子 agent、中断（pending/running tool part 标 "Tool execution aborted"）、自动重试（5xx/429/超时，context overflow 不重试，上限 5 次、指数退避带 0.25 抖动，`retry.ts:28-31`、:192）。
- 已确认边界：无消息内容全文搜索（仅会话标题 LIKE，session.ts:993-995）；附件为 `data:` URL 内联（无独立附件目录）；无整体 edit message 端点（只能 PATCH 单个 part）；前端对失败消息的重试本质是再次发送；`SessionStatusEvent.Info` 只有 idle/retry/busy 三态；V2 post-crash continuation recovery 明确标注为未来工作。

## 未验证事项

- 未运行构建与真实对话：流式渲染、中断、重试的实际体验未实测。
- V2 事件溯源链路（session_input/event 表、projector、run-coordinator）未运行验证。
- `part_text_accum_delta` 在断线重连与事件乱序下的行为未实测。
- 附件 data URL 在超长上下文与工具结果中的实际 token 成本未实测。

## 关键源码索引

- `packages/opencode/src/session/session.ts`：Session 服务（updateMessage/updatePart :631-645、remove :608-629、fork :693-734）
- `packages/opencode/src/session/prompt.ts:1052-1071`：发送主链；`processor.ts:278-537` 流式事件消费、`:660-674` 重试
- `packages/opencode/src/session/{compaction.ts,overflow.ts,retry.ts,revert.ts,run-state.ts,todo.ts}`
- `packages/core/src/session/sql.ts`：表结构；`packages/app/src/context/server-sdk.tsx`、`server-session.ts`：客户端投影
- `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`、`event.ts`：HTTP/SSE 端点
