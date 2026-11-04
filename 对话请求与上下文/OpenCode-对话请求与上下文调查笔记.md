# OpenCode 对话请求与上下文调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：直接阅读源码（Core 发送受理、执行器、上下文与压缩、重试、AI 层请求循环），按新 HEAD 复核文件与符号；未运行构建与真实模型调用
>
> 调查范围：提交入口与队列语义、上下文拼装、预算与压缩、Provider 交接、流式事件、工具回合、最终化与回写、重试与中断、并发；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

一次生成由客户端提交（Composer → `POST /api/session/:id/prompt`）进入 Core 的 `SessionPrompt.prepare`，先把用户输入连同附件、技能引用整理成 `SessionInbox` 条目（delivery 为 `steer` 或 `queue`），再唤醒会话执行。执行器 `SessionRunner.drain` 逐轮推进：装载上下文（历史 + 指令 + 工具定义）→ 构造模型请求 → `@opencode/ai` 发起流式调用 → 把 LLM 事件转成 durable 会话事件（文本/推理/工具/步骤/usage）→ 执行工具回合 → 直到结束或需要压缩/重试。

关键事实：

- **输入有两条投递语义**：`steer` 插入当前轮，`queue` 在轮结束后作为下一轮输入；两者都持久化在 inbox，执行器按 seq 消费，并发布 `session.inbox.*` 事件。
- **上下文按"指令 + 历史 + 工具"三段拼装**：系统提示来自 `packages/core/src/session/runner/prompt/system.txt` 与指令系统（项目/全局 AGENTS 文件、内置指令，`packages/core/src/instructions/`），历史来自 `SessionContext`/`SessionHistory`（按压缩边界裁剪），工具定义由 Tool 服务按权限规则集生成快照。
- **压缩支持自动、溢出与手动三种触发**：`SessionCompaction` 依据剩余窗口与保留余量决定是否压缩，支持后台预计算摘要、本地摘要与 provider 原生窗口（`native.messages`）两种形态；压缩期间会话行标记压缩时间并产生 compaction 消息（running/completed/failed）。
- **重试在下层策略中判定**：`runner/retry.ts` 依据 AI 错误与状态判定是否重试并给出退避延迟，重试状态写入 assistant 消息的 `retry` 字段；没有独立的重试端点，用户侧"重试"是再次提交。
- **步骤有上限**：达到最大步骤后注入固定收束提示（`runner/max-steps.ts`），要求只回文本并总结进度。

## 系统边界与生成任务主链

```text
Composer 提交（packages/app/src/composer/submit.ts）
  -> client.sessions.prompt -> POST /api/session/:id/prompt（protocol/src/groups/session.ts:337）
  -> SessionPrompt.prepare（core/src/session/prompt.ts:34）：整理附件（blob）、技能、metadata
       -> SessionInbox 条目（delivery: steer/queue，schema/src/session-inbox.ts:11）
  -> 执行器认领会话（session.execution.started）
  -> SessionRunner.drain（core/src/session/runner/index.ts）
       -> SessionContext.select/load（session/context.ts:126/168）
       -> SessionModelRequest 构造请求（session/model-request.ts:106 baseTranscript）
       -> LLMClient 流式调用（packages/ai/src/llm.ts、loop.ts）
       -> SessionStep 消费 LLM 事件（runner/step.ts:65）：session.text.delta / reasoning.delta / tool.input.delta
       -> Tool 服务执行工具（core/src/tool.ts，含权限判定与 Code Mode）
       -> 步骤收口（session.step.ended）-> 下一轮或 idle
  -> durable 事件落库（projector）与 SSE 广播（server/src/event-feed.ts）
```

边界：事件如何落到 SQLite 与客户端投影属于会话与消息管理；渲染属于消息渲染器；输入框工作流与审批条属于 Chat UI；工具本身的能力面属于 Agent 工具。

## 1. 提交入口、任务对象与状态机

- **客户端提交**：App 的 `createComposerSubmit`（`packages/app/src/composer/submit.ts`）把 text、文件附件、上下文项、模型选择、delivery 组装为 prompt 请求；slash 命令在客户端先行解析（`composer/client-slash-command.ts`），命令类请求走 `session.command`，shell 模式走 `session.shell`。
- **服务端受理**：`POST /api/session/:id/prompt`（`packages/protocol/src/groups/session.ts:337`）→ `SessionPrompt.prepare` 生成 inbox 条目；`POST /api/session/:id/command`、`/shell`、`/synthetic`、`/compact` 分别对应命令、shell、注入消息与手动压缩。
- **执行对象**：每个会话同时只有一个执行者；执行认领是会话表上的租约（`time_suspended`/`resume_attempts`），认领失败则保持空闲。执行器 `drain` 会处理"位置切换/需要重载"等返回（`DrainResult.Complete/Moved/Reloaded`），必要时在新位置继续。
- **状态表达**：`session.execution.started/succeeded/failed/interrupted` 事件标记执行生命周期，`idle` 消息标记一轮结束（带 succeeded/failed/interrupted 结果），不设独立的 busy/retry 三态事件。
- **并发**：不同会话可并行执行；同会话输入经 inbox 串行化，`steer` 语义让用户在生成中追加指导而不打断当前步骤。

## 2. 上下文拼装

- **系统提示**：`runner/prompt/system.txt` 定义 agent 身份、Markdown 渲染约定、并行工具调用偏好等；运行时把工具指引片段注入（`OPENCODE_TOOL_GUIDANCE`）。
- **指令层**：`packages/core/src/instructions/` 汇总内置指令与项目/全局 AGENTS 文件，按会话与路径解析；`SessionInstructionState`/`instruction_state` 表以 epoch 与 `through_seq` 记录增量，避免每轮重复注入相同指令。
- **历史层**：`SessionHistory.load` 读取消息与部分内容，按压缩边界（`latest`/`local`/目标模型）决定起点；`SessionContext.select` 产出当前会话的选择结果，`load` 物化为可发送的上下文。
- **工具层**：Tool 服务按权限规则集生成当轮工具定义快照（`core/src/tool.ts` 的 `snapshot`）；Code Mode 工具另有受控目录（`codemode/catalog.ts`）供模型在受限执行环境里调用。
- **附件**：用户附件在受理时物化为 blob，模型请求阶段按需读取为 base64 或 `media:` 引用，避免历史消息里重复内联大对象。

## 3. 预算、压缩与溢出

- **触发**：`SessionCompaction` 区分 `auto`、`overflow`、`manual` 三种原因；`auto` 依据模型窗口与保留余量决定（窗口未知时不自动触发），`overflow` 由上游上下文溢出错误驱动，`manual` 来自 `/compact` 或客户端按钮。
- **形态**：压缩结果是 compaction 消息，状态 running → completed/failed；completed 可带本地摘要或 provider 原生窗口（`native.messages`），后者只在目标模型声明可回放时参与历史读取。
- **预计算**：上下文接近阈值时可在后台预生成摘要，等自动压缩触发时直接换入，避免同步阻塞。
- **历史改写**：压缩后的历史以摘要（或原生窗口）替换旧消息段；旧工具输出被裁掉，模型看到的是压缩边界之后的消息加摘要。
- **输出预算**：请求构造阶段按模型 limit 计算输出上限（`model-request.ts:96 outputLimit`），并对不支持的部件与图片数量做收敛（`unsupportedParts`、`boundImages`）。

## 4. Provider 交接与流式事件

- **模型解析**：`runner/model.ts` 把会话的 agent/model 解析成具体 provider 配置（含 variant），交给 AI 层。
- **请求与传输**：`session/model-request.ts` 负责把上下文转成 AI 层消息（含系统提示、工具定义、历史），`model-transport.ts` 负责实际传输与错误归一；Provider 协议实现与适配器在 `packages/ai/src/providers/`。
- **流式事件**：AI 层产出统一 LLM 事件（文本增量、推理增量、工具调用增量、usage、结束原因），`runner/publish-llm-event.ts` 转成 durable 会话事件，因此客户端看到的流式内容与落库内容是同一套事件。
- **收尾**：步骤结束时记录快照与文件变更（`session.step.ended` 带 snapshot/files），usage 通过 `session.usage.recorded` 汇总到会话统计。

## 5. 工具回合、权限与终止

- **工具执行**：`SessionStep` 把模型返回的工具调用交给 Tool 服务，执行结果按工具事件流回注（`session.tool.called/progress/success/failed`），模型在下一轮看到工具结果。
- **权限**：`core/src/permission.ts` 以规则集（action/resource/effect）评估每次调用，`Unattended` 模式为无人值守场景提供默认规则；需要人工确认时发出审批请求，等待客户端回复。Agent 与会话各自持有规则集并合并使用。
- **Code Mode**：模型可写一段受限程序一次调用多个工具（`packages/codemode`），执行仍受整工具权限过滤与各工具自身策略约束。
- **终止**：步骤数达到 agent 上限时注入收束提示（`runner/max-steps.ts`）；上下文溢出转压缩；输出被截断或流不完整时使用续写提示继续（`runner/llm.ts` 的两条 CONTINUE 文案）。

## 6. 重试、中断与恢复

- **重试**：`runner/retry.ts` 的策略输入是 AI 错误与重试次数，输出是否重试与延迟；`model-retry.ts` 处理模型层面的可重试错误；重试状态在 assistant 消息上可见，客户端据此展示等待。
- **中断**：取消执行会把进行中的工具与步骤标记为 aborted（"Tool execution interrupted"/"Step interrupted"），并发布 `session.execution.interrupted`；未完成的 assistant 消息保持可识别状态。
- **恢复**：执行中断后会话行的租约与 `resume_attempts` 支持重启续跑；`execution/restart.ts` 负责重建执行。
- **无独立重试端点**：重试由执行器内部完成，用户重发是新的输入。

## 7. 设计取舍与已确认边界

- **输入先入 inbox**：把"受理"与"执行"解耦，才能在生成中安全地 steer/queue，并让崩溃后仍有待处理输入。
- **事件即写入**：模型输出、工具状态、usage 全部走 durable 事件，客户端与服务端看到同一份流。
- **压缩分层**：自动压缩 + 溢出兜底 + 手动按钮，兼顾成本与可控性；provider 原生窗口优先于本地摘要。
- **重试只有一层可见状态**：模型错误、网络错误与容量错误共用一条重试通道，没有按错误类型分叉的用户选项。
- **边界**：上下文分析（发送前预览）与工具审批 UI 属于其他类目；本次未找到"按消息片段重新生成"的独立端点。

## 8. 未验证事项

1. 真实 provider 下的流式体验、重试退避与中断恢复未实测。
2. 自动压缩的阈值、预计算时机与原生窗口回放在真实长会话中的表现未验证。
3. Code Mode 的多工具调用与权限过滤组合未运行验证。
4. TUI 与 Web 的提交入口差异（delivery 默认值、命令解析）未逐项实测。

## 9. 关键源码索引

- `packages/core/src/session/prompt.ts`：受理与 inbox 条目生成
- `packages/core/src/session/{context.ts,history.ts}`：上下文选择与历史装载
- `packages/core/src/session/runner/{index.ts,llm.ts,step.ts,model.ts,retry.ts,to-llm-message.ts,max-steps.ts}`：执行器与步骤
- `packages/core/src/session/{model-request.ts,model-transport.ts}`：请求构造与传输
- `packages/core/src/session/compaction.ts`：压缩策略与原生窗口
- `packages/core/src/permission.ts`：权限评估与审批
- `packages/core/src/tool.ts`、`tool/plugin/`：工具快照与内建工具
- `packages/ai/src/{llm.ts,loop.ts,providers/}`：AI 层请求循环与 Provider
- `packages/protocol/src/groups/session.ts`：提交与执行端点
