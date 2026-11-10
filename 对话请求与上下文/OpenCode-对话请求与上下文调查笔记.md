# OpenCode 对话请求与上下文调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：直接阅读源码（Core 发送受理、执行器、上下文与压缩、重试、AI 层请求循环），按新 HEAD 复核文件与符号；未运行构建与真实模型调用
>
> 调查范围：提交入口与队列语义、上下文拼装、预算与压缩、Provider 交接、流式事件、工具回合、最终化与回写、重试与中断、并发；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

一次生成从客户端提交开始：Composer 把用户输入、附件与技能引用发往 `POST /api/session/:id/prompt`，Core 的受理入口 `SessionPrompt.prepare` 把这些内容整理成一条 inbox 条目（投递方式为 steer 或 queue），随后唤醒该会话的执行器。执行器 `SessionRunner.drain` 逐轮推进：装载历史、指令与工具定义，构造模型请求，经 `@opencode/ai` 发起流式调用，把模型事件转成持久会话事件（文本、推理、工具、步骤、用量），执行工具回合，直到结束或转入压缩、重试。

关键事实：

- **输入先持久受理，再择机投递**：用户输入先落成 inbox 条目，再由执行器在合适的时点取用。默认投递方式为 `steer`，在安全步骤边界插入；`queue` 只在空闲边界进入，每推进一条就重新判断下一条。`steer` 里的压缩可以提到首个位置切换之前，其余条目仍按入队顺序，因此先到达的条目未必先被取用。取用与消费在同一事务内完成，条目随即变成可见消息（[inbox.ts 的 promote/pendingSteers](../../opencode/packages/core/src/session/inbox.ts#L562-L625)）。
- **上下文按"指令 + 历史 + 工具"三段拼装**：系统提示取自 `runner/prompt/system.txt`，指令系统（`packages/core/src/instructions/`）在其上叠加项目与全局 AGENTS 文件、内置指令；历史由上下文与历史服务按压缩边界裁剪后装载；工具定义由 Tool 服务按权限规则集为当轮生成快照。
- **压缩支持自动、溢出与手动三种触发**：`SessionCompaction` 依据剩余窗口与保留余量决定是否压缩，支持在后台预计算摘要，产物形态有本地摘要与 provider 原生窗口两种（后者记为 `native.messages`）；压缩期间会话行标记压缩时间，并产生状态为 running、completed 或 failed 的 compaction 消息。
- **重试在下层策略中判定**：`runner/retry.ts` 依据 AI 错误与会话状态判定是否重试，并给出退避延迟，结果写入 assistant 消息的 `retry` 字段；重试在服务端内部完成，用户侧的"重试"就是再提交一次输入，没有单独的重试端点。
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
       -> Tool 快照分派工具（叶子策略授权，含 Code Mode）
       -> 步骤收口（session.step.ended）-> 下一轮或 idle
  -> durable 事件落库（projector）与 SSE 广播（server/src/event-feed.ts）
```

边界：事件如何落到 SQLite 与客户端投影属于会话与消息管理；渲染属于消息渲染器；输入框工作流与审批条属于 Chat UI；工具本身的能力面属于 Agent 工具。

## 1. 提交入口、任务对象与状态机

- **客户端提交**：App 的提交入口 `createComposerSubmit` 把用户文本、文件附件、上下文项、模型选择与投递方式组装成一次 prompt 请求；以斜杠开头的命令先在客户端解析，命令类请求走 `session.command`，shell 模式走 `session.shell`。组装逻辑在 `packages/app/src/composer/submit.ts`，命令解析在同目录的 `client-slash-command.ts`。
- **服务端受理**：`POST /api/session/:id/prompt` 交给 `SessionPrompt.prepare` 生成 inbox 条目（`packages/protocol/src/groups/session.ts:337`）。同一路由组下还有四个端点，各自对应一种入口：
  - `/command`：命令类请求；
  - `/shell`：shell 模式；
  - `/synthetic`：注入消息；
  - `/compact`：手动压缩。
- **执行对象**：全局执行服务在当前进程内按会话协调，同会话显式恢复会加入已有执行，提示唤醒可合并，不同会话可并行。runner、工具和模型解析绑定工作位置；位置切换或重载后重新选取该位置的服务。数据库执行 claim 记录忙碌期的恢复意图，不提供分布式租约、跨进程互斥或副作用恰好一次保证（[execution.ts](../../opencode/packages/core/src/session/execution.ts#L73-L146)）。
- **状态表达**：执行生命周期由 `session.execution.*` 的 started、succeeded、failed、interrupted 四个事件标记；一轮结束时另发 `idle` 消息，结果取 succeeded、failed、interrupted 之一。busy 与 retry 三态没有单独的事件。
- **并发**：不同会话可并行执行；同会话输入经 inbox 串行化，`steer` 语义让用户在生成中追加指导而不打断当前步骤。

## 2. 上下文拼装

- **系统提示**：`runner/prompt/system.txt` 定义 agent 身份、Markdown 渲染约定、并行工具调用偏好等；运行时把工具指引片段注入（`OPENCODE_TOOL_GUIDANCE`）。
- **指令层**：`packages/core/src/instructions/` 汇总内置指令与项目、全局 AGENTS 文件，按会话与当前路径解析；结果写进 `instruction_state` 表，以 epoch 与 `through_seq` 记录增量，下一轮只补新增部分，避免重复注入相同指令。
- **历史层**：历史服务按最新适用的已完成压缩边界选择读取起点。`latest` 允许模型无关的读取者采用原生压缩窗口；`local` 只采用本地摘要边界；指定目标模型时，原生窗口还须符合该模型的回放条件（`packages/core/src/session/history.ts:25-84`）。上下文服务再选出本轮内容，并物化为可发送的上下文，入口见 `packages/core/src/session/context.ts`。
- **工具层**：Tool 服务按权限规则集生成当轮工具定义快照（`core/src/tool.ts` 的 `snapshot`）；Code Mode 工具另有受控目录（`codemode/catalog.ts`）供模型在受限执行环境里调用。
- **附件**：用户附件在受理时物化为 blob，模型请求阶段按需读取为 base64 或 `media:` 引用，避免历史消息里重复内联大对象。

## 3. 预算、压缩与溢出

- **触发**：`SessionCompaction` 按三种原因分流：
  - `auto`：依据模型窗口与保留余量判定，窗口未知时不自动触发；
  - `overflow`：由上游的上下文溢出错误驱动；
  - `manual`：来自 `/compact` 命令或客户端按钮。
- **形态**：压缩结果是 compaction 消息，状态 running → completed/failed；completed 可带本地摘要或 provider 原生窗口（`native.messages`），后者只在目标模型声明可回放时参与历史读取。
- **预计算**：上下文接近阈值时可在后台预生成摘要，等自动压缩触发时直接换入，避免同步阻塞。
- **历史改写**：压缩后的历史以摘要（或原生窗口）替换旧消息段；旧工具输出被裁掉，模型看到的是压缩边界之后的消息加摘要。
- **输出预算**：请求构造阶段按模型 limit 计算输出上限（`model-request.ts:96 outputLimit`），并对不支持的部件与图片数量做收敛（`unsupportedParts`、`boundImages`）。

## 4. Provider 交接与流式事件

- **模型解析**：执行器先把会话绑定的 agent 与 model 解析成具体的 provider 配置（含 variant），再交给 AI 层发起请求（`runner/model.ts`）。
- **请求与传输**：请求构造层把上下文转成 AI 层消息，含系统提示、工具定义与历史；传输层负责实际发送与错误归一。两层分别在 `session/{model-request.ts,model-transport.ts}`，Provider 协议实现与适配器在 `packages/ai/src/providers/`。
- **流式事件**：AI 层产出统一 LLM 事件（文本增量、推理增量、工具调用增量、usage、结束原因），`runner/publish-llm-event.ts` 转成 durable 会话事件，因此客户端看到的流式内容与落库内容是同一套事件。
- **收尾**：步骤结束时记录快照与文件变更（`session.step.ended` 带 snapshot/files），usage 通过 `session.usage.recorded` 汇总到会话统计。

## 5. 工具回合、权限与终止

- **工具执行**：步骤执行器把模型返回的工具调用交给 Tool 服务，执行过程按 `session.tool.*` 事件流回注，分为调用、进度、成功、失败四类；模型在下一轮读到这些结果。
- **权限**：每次工具调用都经权限层按规则集评估，规则由动作、资源与效果三段组成；无人值守场景使用 `Unattended` 模式的默认规则。命中需要人工确认的调用时发出审批请求，等待客户端回复；agent 与会话各自持有规则集并合并使用（`core/src/permission.ts`）。
- **Code Mode**：模型可写一段受限程序一次调用多个工具（`packages/codemode`），执行仍受整工具权限过滤与各工具自身策略约束。
- **终止**：步骤数达到 agent 上限时注入收束提示（`runner/max-steps.ts`）；上下文溢出转压缩；输出被截断或流不完整时使用续写提示继续（`runner/llm.ts` 的两条 CONTINUE 文案）。

## 6. 重试、中断与恢复

- **重试**：`runner/retry.ts` 的策略输入是 AI 错误与重试次数，输出是否重试与延迟；`model-retry.ts` 处理模型层面的可重试错误；重试状态在 assistant 消息上可见，客户端据此展示等待。
- **中断**：取消执行会把进行中的工具与步骤标记为 aborted（"Tool execution interrupted"/"Step interrupted"），并发布 `session.execution.interrupted`；未完成的 assistant 消息保持可识别状态。
- **恢复**：成功、失败和用户主动中断释放执行 claim；服务关闭中断及进程死亡保留它。启动恢复扫描顶层会话的遗留 claim，并在续跑前持久增加次数，默认每次执行最多自动恢复 10 次，超额终结。恢复具有至少一次语义，崩溃前已发生的外部副作用可能重复；托管服务的前任进程退出与注册锁承担进程交接约束（[restart.ts](../../opencode/packages/core/src/session/execution/restart.ts#L24-L83)）。
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
