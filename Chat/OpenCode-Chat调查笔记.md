# OpenCode Chat 概览

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读源码静态梳理会话数据模型、发送链路、执行与事件流；未运行构建与真实对话
>
> 调查范围：会话/消息数据模型、SQLite 持久化、发送主链、执行与中断、事件到客户端的投影、上下文压缩、消息操作、列表与检索、外部能力绑定；TUI/Web/桌面差异只核实入口；不覆盖各专项笔记的细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 的 Chat 体系以「Core 服务 + durable 事件日志 + 客户端投影」为核心。服务端把会话、消息、工具步骤的每次变化写成 durable 事件（`session.created`、`session.step.started/ended`、`session.text.delta`、`session.tool.success` 等，定义在 `packages/schema/src/session-event.ts`），由事件投影器落 SQLite（`session_v2`、`session_message`、`session_part`、`session_inbox`、`blob`），再经 Server 的 EventFeed 以 SSE 广播；App 客户端订阅事件流投影到 Solid store 渲染 timeline。

消息模型收敛为 Session → Message → 内容三层：Message 是带类型的联合（user、assistant、synthetic、system、skill、shell、compaction、idle、agent-switched、model-switched、location-switched），assistant 的正文不再是独立 part 表行，而是内嵌的内容数组（text、reasoning、tool 三种，工具状态流式/running/完成/失败），`session_part` 只是内容数组的投影副本。发送主链为「Composer 提交 → `POST /api/session/:id/prompt` → Prompt 服务生成 inbox 条目（steer 或 queue）→ 执行器认领会话 → AI 层流式调用 → durable 事件」。会话表以 `session_v2` 为唯一主路径。

## 产品表面与系统边界

- **产品表面**：Web App（`packages/app`，Solid，虚拟化 timeline）、TUI（`packages/tui`，Solid/TypeScript 终端界面）、Electron 桌面（`packages/desktop`，主进程在 `src/main`，renderer 复用 app 包）、CLI（`packages/cli`）。会话渲染组件独立在 `packages/session-ui`，`packages/app` 负责路由、状态与数据装载。
- **系统边界**：SQLite 会话库是会话数据的唯一事实源；Core 服务（`packages/core`）持会话、工具、权限、Provider 等运行时；模型推理由外部 provider 完成；HTTP 路由由 `packages/server` 定义在 `packages/protocol` 的契约下，SSE 是事件通道；`packages/sdk` 可在进程内直接执行同一路由（不发网络请求）。

## 端到端聊天主链

```text
Composer 提交（packages/app/src/composer/submit.ts）
  -> client.sessions.prompt（packages/client）
  -> POST /api/session/:sessionID/prompt（packages/protocol/src/groups/session.ts）
  -> SessionPrompt.prepare（packages/core/src/session/prompt.ts:34）
       生成 SessionInbox 条目（delivery: steer / queue），附件先物化为 blob
  -> 会话执行器认领（session.execution.started）
       packages/core/src/session/runner/{index,llm,step,to-llm-message}.ts
       -> @opencode/ai 流式请求（packages/ai/src/llm.ts、loop.ts）
  -> durable 事件：session.step.started / session.text.delta / session.tool.* / session.step.ended
  -> 投影器写库（packages/core/src/session/projector.ts、message-updater.ts）
  -> Server EventFeed SSE（packages/server/src/event-feed.ts）
  -> App 事件源与 timeline store（packages/app/src/runtime/server/client.tsx、src/session/timeline/）
  -> session-ui 渲染（packages/session-ui/src/timeline/session-timeline.tsx）
```

## 核心对象与状态权威

- **Session**：带项目/工作区绑定、标题、分享地址、摘要、成本与 token 统计、回退状态、权限规则集、agent 与 model 列、归档/忙碌/空闲等时间戳（`packages/core/src/session/sql.ts:28-84`）。fork 关系用 `fork_session_id` 与 `fork_boundary` 记录。
- **Message**：`SessionMessage.Info` 是 11 种类型的联合（`packages/schema/src/session-message.ts:47-285`），按 `seq` 在会话内有序；assistant 的消息体带 `content` 数组、快照起止、finish、usage、错误和重试标记。
- **Inbox**：用户输入先进入 `session_inbox`（`SessionInboxTable`，`sql.ts:130-151`），带 delivery 语义；执行器按 seq 取用后写成正式消息，事件里表现为 `session.inbox.enqueued/delivered/cancelled`。
- **附件与文本对象**：附件经 blob 表按内容哈希存储、`blob_ref` 关联会话与消息（`sql.ts:185-215`），不再以 data URL 直接内联进消息；渲染侧仍可用 `media:` 引用让客户端按需取字节。
- **权威源**：SQLite（服务端）；客户端 store 是投影；每会话的「执行认领」状态是运行态权威（`time_suspended`/`resume_attempts` 支持重启后续跑）。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/OpenCode-会话与消息管理调查笔记.md`](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md`](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/OpenCode-ChatUI调查笔记.md>`](<../Chat UI/OpenCode-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/OpenCode-消息渲染调查笔记.md`](../消息渲染器/OpenCode-消息渲染调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- 支持：durable 事件驱动的流式落库（文本/推理按 delta 事件、工具状态按 `session.tool.*` 事件、步骤按 `step.started/ended` 收口）；输入可 **steer**（插入当前轮）或 **queue**（排队）并持久化在 inbox；上下文压缩（compaction 消息带 running/completed/failed 三态，支持本地摘要与 provider 原生窗口两种）；回退（revert 记录 + 再次 prompt 时清理目标之后的消息）；fork 新会话并复制消息；会话归档、重命名、移动、跨项目列表；Shell 模式与 Skill 激活作为独立消息类型。
- 事件层：durable 事件按会话聚合，客户端可经 SSE 全量订阅；执行进度、工具状态、usage 均在同一事件流上广播。
- 已确认边界：消息内容没有全文搜索，只有会话标题等字段筛选；会话忙碌/空闲由 `session.execution.*` 事件与 idle 消息共同表达，重试记录在 assistant 消息的 `retry` 字段而不是独立事件；`POST /api/session/:id/prompt` 是异步受理，客户端靠事件观察完成；provider 原生 compaction 的窗口只在目标模型可回放时参与历史读取。
- 运行态未验证：真实流式体验、durable 事件断线重放、桌面端与 TUI 的差异表现。

## 未验证事项

- 未运行构建与真实对话：流式渲染、工具审批、压缩与回退的实际体验未实测。
- durable 事件在断线重连、事件乱序与多窗口并发下的行为未实测。
- provider 原生 compaction（`native.messages` 回放）未用真实 provider 验证。
- blob 附件在超长上下文与工具结果中的实际 token 成本未实测。

## 关键源码索引

- `packages/schema/src/session-message.ts`：Message 联合与 assistant 内容结构
- `packages/schema/src/session-event.ts`：durable 事件定义
- `packages/core/src/session/sql.ts`：会话库表结构
- `packages/core/src/session/prompt.ts`、`runner/`：发送受理与执行
- `packages/core/src/session/projector.ts`、`message-updater.ts`：事件投影落库
- `packages/protocol/src/groups/session.ts`：HTTP 契约
- `packages/server/src/event-feed.ts`：SSE 广播
- `packages/app/src/composer/submit.ts`、`src/session/timeline/`：客户端提交与时间线投影
