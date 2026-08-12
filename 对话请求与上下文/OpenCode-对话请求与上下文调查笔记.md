# OpenCode 对话请求与上下文调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：从 [`../Chat/OpenCode-Chat调查笔记.md`](../Chat/OpenCode-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据；按提交范围 b8bd889..HEAD 核对重试上限/抖动、压缩序列化与孤儿工具判定改动
>
> 调查范围：提交入口与状态机、上下文拼装、预算与压缩、Provider 交接、流式事件链、最终化与回写、停止重试、并发后台、外部能力注入；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的一次生成任务由 `api.session.prompt` 进入 `SessionPrompt.prompt`，经 loop → processor → `LLM.stream`（AI SDK `streamText`）执行，每轮从数据库重读历史。LLM 事件流经 `LLMAISDK.toLLMEvents` 转统一事件，`SessionProcessor.handleEvent` 逐个 `updateMessage`/`updatePart` 发布事件，经 SSE 推送客户端。

关键事实（快照 1f94d8a）：

- **上下文压缩是"重写历史"**：compaction 生成 [compaction-user, summary-assistant, tail, continue-user] 重排，旧 tool 输出被清空并标记 compacted；快照 1f94d8a 起压缩请求的对话历史改为**文本序列化**（`[User]/[Assistant]/[Assistant tool call]/[Tool result]` 前缀，结果截断、compacted 标 `[Old tool result content cleared]`），拼进 summary 请求（compaction.ts:52-83、:387、:427-438），不再经 `toModelMessagesEffect` 的 stripMedia 媒体剥离。
- **中断语义**：pending/running 的 tool part 标记为 `"Tool execution aborted"`，重放时以错误回注（processor.ts:577-593、message-v2.ts:349-360）。
- **流式落盘频率分三层**：delta 走 `updatePartDelta` 发增量事件、完整 part 在 end 事件时落库、tool part 状态迁移即时落库（processor.ts:499-532）。
- **自动重试**：`SessionRetry.policy` 判定 5xx/429/超时/网络错误，context overflow 不重试；上限 5 次、指数退避带 0.25 随机抖动（retry.ts:28-31、76-81、:192）；无独立重试端点。
- **V1/V2 双轨**：V1 走 `POST /session/:id/prompt_async`；V2 走生成客户端 `POST /api/session/{id}/prompt`。

## 系统边界与生成任务主链

```text
App 输入（components/prompt-input/submit.ts） → api.session.prompt（{sessionID,id,agent,model,variant,text,files,agents}）
  → POST /session/:id/prompt_async（V1）或 /api/session/:id/prompt（V2）
  → SessionPrompt.prompt（prompt.ts:1052-1071）：
      revert.cleanup → createUserMessage（写 user message + parts，:1046-1047）
      → loop → processor.create → handle.process（processor.ts:627-683）
      → llm.stream（llm.ts:357-381，AI SDK streamText）
  → LLMEvent 流（llm/ai-sdk.ts）→ SessionProcessor.handleEvent（processor.ts:278-537）
  → session.updateMessage/updatePart 发布事件（session.ts:631-645）
  → EventV2Bridge → SSE /event（handlers/event.ts）
  → App server-sdk.tsx 读取循环 → 投影到 store（渲染细节在消息渲染器）
```

边界：会话与消息如何持久化、消息删除/revert/fork 的数据语义属于会话与消息管理；SSE 到 store 的投影与渲染属于消息渲染器（`../消息渲染器/OpenCode-消息渲染调查笔记.md`）；TUI/Web 的发送、停止按钮与排队提示属于 Chat UI。

## 1. 提交入口、任务对象与状态机

- **发送链**：App `createPromptSubmit.handleSubmit`（submit.ts:318-639）→ `sendFollowupDraft`（:58-208）→ `api.session.prompt`（:168-199）；V1 走 `POST /session/:id/prompt_async`（groups/session.ts:96）、V2 走生成客户端 `POST /api/session/{id}/prompt`（client/src/generated/client.ts:370-375）。
- **V1 端点**：`POST /session/:id/message`（handlers/session.ts:295-309）→ `SessionPrompt.prompt`（prompt.ts:1052-1071）：`revert.cleanup` → `createUserMessage`（:635-1050）→ `loop`（:1081-1341）→ processor。
- **任务对象**：每 session 一个 `Runner`（run-state.ts:52-69），同会话串行、不同会话并行（effect/runner.ts:115-138 状态机 Idle/Running/Shell/ShellThenRun :33-37）；V2 用 `SessionRunCoordinator`（run-coordinator.ts:24-104）。
- **状态机**：`SessionStatusEvent.Info` 只有 `idle/retry/busy` 三态（schema/src/session-status-event.ts:9-32），**没有 queued/running/paused/complete 字面状态**；V2 把非 idle 合成映射为 `{type:"running"}`（packages/server/src/handlers/session.ts:81-89）。

## 2. 历史选择与上下文拼装顺序

messages 组装（prompt.ts:1257-1286）：

1. `sys.environment`（system.ts:60-95）
2. `instruction.system()`（AGENTS.md，instruction.ts:155-169）
3. `sys.mcp`（system.ts:112-128）
4. `sys.skills`（:98-110）
5. `MessageV2.toModelMessagesEffect` 历史转换（message-v2.ts:131-415：user text/file/compaction/subtask :198-242；assistant text/tool/reasoning/step-start :244-401；媒体抽离为合成 user 消息 :382-399）
6. `LLMRequestPrep.prepare` 拼 system 头（llm/request.ts:104-112）

历史每轮从数据库重读（`MessageV2.hydrate`），上下文来源与顺序以最终请求为准。

## 3. 预算、截断、摘要与压缩

- **溢出检测**：`isOverflow`（src/session/overflow.ts:22-34，`tokens.total >= usable`）；`usable = model.limit.input - reserved`（默认保留 20k，:10-20）。
- **compaction 流程**：step-finish 检查溢出置 `needsCompaction`（processor.ts:477-482）→ `result === "compact"` → `compaction.create` 插入带 `compaction` part 的 user 消息（prompt.ts:1320-1328）→ `compaction.process`（compaction.ts:289-511）：`select` 按 `tail_turns`（默认 2）与 `preserve_recent_tokens` 预算挑尾部（:32、80-85）、`splitTurn` 可半轮截断（:105-128）、`prune` 清空旧 tool 输出并标 `time.compacted`（:243-287，`PRUNE_MINIMUM=20k`/`PRUNE_PROTECT=40k`）。压缩请求本身不再逐消息转 AI SDK 消息，而是用 `serialize` 把选中历史拼成纯文本随 `nextPrompt` 一起发出（compaction.ts:52-83、:385-438）。
- **重排**：`filterCompacted` 把 [compaction-user, summary-assistant, tail, continue-user] 重排供模型（message-v2.ts:521-572）；其中 `latest` 判定按 `time.created` 排序、id 仅作决胜（:582-604，导入消息 id 不保证单调）；上下文长度用 `Token.estimate` 估算（compaction.ts:180-186）。压缩改写历史而非删历史（保留语义见会话与消息管理笔记 9）。

## 4. SDK、Provider、模型与协议交接

`llm.stream`（llm.ts:357-381）使用 AI SDK `streamText`；`LLMRequestPrep.prepare` 拼 system 头（llm/request.ts:104-112）。LLM 流经 `LLMAISDK.toLLMEvents` 转统一事件（llm/ai-sdk.ts:76-286）：`text-start/delta/end`、`reasoning-start/delta/end`、`tool-input-start/delta/end`、`tool-call`、`tool-result`、`tool-error`、`step-start/finish`、`finish`。具体各 provider 的协议 Adapter 层本次未展开。

## 5. 流式事件、缓冲、节流与顺序

- **服务端事件产生**：delta 用 `updatePartDelta` 发 `message.part.delta`（processor.ts:499-510；session.ts:879-887 定义 delta 事件 `{sessionID,messageID,partID,field,delta}`）；`text-end` 才完整写 part 并触发插件 `experimental.text.complete`（:512-532）。reasoning 同理（:280-313）。
- **SSE 投递**：`handlers/event.ts:25-87`，`Queue.unbounded` + `Stream.fromQueue` 按目录过滤，先发 `server.connected`，每 10 秒 `server.heartbeat`。
- **App 读取循环**：`server-sdk.tsx:260-317`，`for await` 逐事件；`coalesceServerEvents` 拼接连续 delta（:79-139），`flush()` 每 16ms 批量分发（:227-245），断线 250ms 重连。
- **Store 投影**：`message.part.updated` 按 id 二分插入/替换、`message.part.delta` 写入 `part_text_accum_delta` 并就地 append、v2 事件投影回 v1 形态（server-session.ts、server-session-v2-reducer.ts）——投影与 DOM 更新的详细实现见消息渲染器笔记。

## 6. 完成、异常、半截流与最终回写

- **最终化**：完整 part 在 end 事件时落库（processor.ts:512-532）；`finish` 事件收口，assistant message 的 `time.completed` 与 `finish` 字段随消息落库。
- **异常/半截流**：`cleanup`（processor.ts:539-597）把未完成 text/reasoning/tool part 置终态（工具标 `"Tool execution aborted"` + `interrupted:true`，:577-593），重放时以错误回注（message-v2.ts:349-360）。
- **错误归一化**：`fromError`（message-v2.ts:603-731）映射 8 种错误类型（数据语义见会话与消息管理笔记 1）。

## 7. 停止、重试、续写与重新生成

- **停止**：App `abort()`（submit.ts:259-278）→ `POST /session/:id/abort`（groups/session.ts:253-264）→ `SessionRunState.cancel`（run-state.ts:77-86）→ `Effect.onInterrupt` 置 aborted 走 `halt(AbortError)`（processor.ts:648-655）；随后 `cleanup` 置终态（第 6 节）。界面入口（TUI 双击 Esc / Web 中断按钮）见 Chat UI 笔记。
- **重试**：`SessionRetry.policy`（src/session/retry.ts:175-198）：`retryable` 判定 5xx/429/超时/网络错误（:77-147），context overflow 不重试；`delay` 尊重 retry-after 头、指数退避 2s 起并加 0.25 随机抖动（:28-31、46-81），`attempt > 5` 停止（:192）；接入 processor 的 `Effect.retry`（processor.ts:660-674），每次尝试发布 `retry` 状态。
- **重试与重新生成的区别**：无独立重试端点；前端对失败消息的重试本质是再次发送（续写语义见会话与消息管理笔记 4）。

## 8. 队列、多会话并发与后台生成

- **并发粒度**：每 session 一个 `Runner`（run-state.ts:52-69），同会话串行、不同会话并行（effect/runner.ts:115-138）；V2 用 `SessionRunCoordinator`（run-coordinator.ts:24-104）。
- **再次发送**：同 session 追加即续写；V2 有 `delivery: "steer"`（打断当前轮）与 `"queue"`（排队，core/src/session/input.ts:245-287）。
- **后台生成**：`BackgroundJob` 服务本体在 src/background/job.ts（run-state.ts:111-143 是 `cancelBackgroundJobs`）；"detach 子 agent 到后台"端点 `POST /experimental/session/:id/background`（handlers/experimental.ts:159-188）。

## 9. Agent、工具、知识库与附件注入点

- **工具集解析**：`SessionTools.resolve`（tools.ts:41-134）→ `ToolRegistry.tools({modelID,providerID,agent,permission})`（:92-97）→ request 层权限过滤（llm/request.ts:208-214）。MCP 工具、skill 在此挂载（tools.ts:390-490）。
- **附件**：App 端 `blobDataUrl(blob, mime)` 把图片转 data URL（submit.ts:101、:117）；服务端把 `file:` 读成 `data:` base64 的是 `resolveUserPart`（prompt.ts:949-969，file: 分支约 :808-970），`resolvePromptParts`（:157-191）只做 markdown 模板解析产生 `file:` URL part；MCP 资源也转 data URL（prompt.ts:754-768）；tool 结果附件同样内联（tools.ts:426-462）。存储形状（data URL 内联、无独立附件目录）见会话与消息管理笔记 8。
- **todo 回注**：模型经 `todowrite` 工具写入，列表 JSON 作为 tool result 回注（tool/todo.ts:36-42）——回注靠工具返回值，会话历史无额外 todo 注入（静态推断）。

## 10. 退出恢复、日志与已确认边界

- **退出恢复**：消息/parts 均逐步落库，退出后从 SQLite 恢复；进程内运行态（Runner/status）在 InstanceState 中随实例清理（run-state.ts:35-49）。V2 post-crash continuation recovery 标注为未来工作（runner/llm.ts:86）。
- **可观测性**：日志、trace、用量（session.cost/tokens 列）与任务关联本次未在源笔记中展开。
- **V1/V2 双轨执行差异**：V1 为生产主路径；V2 的 prompt 先写 durable `session_input` 再 wake（AGENTS.md "V2 Session Core"），两轨端点不同（第 1 节）。双轨数据模型差异见会话与消息管理笔记 1。
- **已确认边界**：静态代码确认入口、顺序与状态分支；取消效果、退出恢复、并发竞态和长上下文行为需要运行验证。

## 11. 未验证事项

1. 未运行构建与真实对话；流式渲染、中断、重试的实际用户体验未实测。
2. V2 事件溯源链路（session_input/event 表、projector、coordinator）未运行验证。
3. `part_text_accum_delta` 在断线重连与事件乱序下的行为未实测。
4. 附件 data URL 在超长上下文与工具结果中的实际 token 成本未实测。

## 12. 关键源码索引

- `packages/opencode/src/session/prompt.ts`：发送主链路（prompt :1052-1071、loop/runLoop :1081-1341、createUserMessage :635-1050）
- `packages/opencode/src/session/processor.ts`：流式事件消费（:278-537）、重试（:660-674）、清理（:539-597）
- `packages/opencode/src/session/llm.ts`、`src/session/llm/ai-sdk.ts`：模型请求与事件转换
- `packages/opencode/src/session/compaction.ts`、`overflow.ts`：上下文压缩
- `packages/opencode/src/session/retry.ts`、`run-state.ts`、`run-coordinator.ts`、`status.ts`
- `packages/opencode/src/session/tools.ts`、`llm/request.ts`：工具解析与权限过滤
- `packages/opencode/src/session/message-v2.ts`：历史转换与错误归一化
- `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`、`event.ts`：HTTP/SSE 端点
- `packages/app/src/context/server-sdk.tsx`：App 读取循环与批量 flush
