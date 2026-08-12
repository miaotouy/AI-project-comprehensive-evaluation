# OpenCode 对话请求与上下文调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：直接阅读源码（TypeScript 服务端生成任务执行链、事件流与 TUI/Web 客户端提交路径），核对快照 HEAD 全部符号与行号
>
> 调查范围：提交入口与状态机、上下文拼装、预算与压缩、Provider 交接、流式事件链、最终化与回写、停止重试、并发后台、外部能力注入；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的一次生成任务由 `api.session.prompt` 进入 `SessionPrompt.prompt`，经 loop → processor → `LLM.stream`（AI SDK `streamText`）执行，每轮从数据库重读历史。LLM 事件流经 `LLMAISDK.toLLMEvents` 转统一事件，`SessionProcessor.handleEvent` 逐个 `updateMessage`/`updatePart` 发布事件，经 SSE 推送客户端。

关键事实（快照 1f94d8a）：

- **上下文压缩是"重写历史"**：compaction 生成 [compaction-user, summary-assistant, tail, continue-user] 重排，旧 tool 输出被清空并标记 compacted；压缩请求的对话历史改为**文本序列化**（`[User]/[Assistant]/[Assistant reasoning]/[Assistant tool call]/[Tool result]/[Tool error]` 前缀，结果截断、compacted 标 `[Old tool result content cleared]`），拼进 summary 请求（compaction.ts:52-86、:385-441），不再经 `toModelMessagesEffect` 的 stripMedia 媒体剥离（该选项保留但无调用方）。
- **中断语义**：pending/running 的 tool part 标记为 `"Tool execution aborted"` + `interrupted:true`，重放时以错误回注（processor.ts:577-593、message-v2.ts:351-360）。
- **流式落盘频率分三层**：delta 走 `updatePartDelta` 发增量事件、完整 part 在 end 事件时落库、tool part 状态迁移即时落库（事件产生与各事件语义见 5；落库的数据形状见会话与消息管理笔记 §3）。
- **自动重试**：`SessionRetry.policy` 判定 5xx/429/超时/网络错误，context overflow 不重试；上限 5 次、指数退避 2s 起带 0.25 随机抖动（retry.ts:26-31、:79-82、:192）；无独立重试端点。
- **V1/V2 双轨**：V1 走 `POST /session/:id/prompt_async`；V2 走生成客户端 `POST /api/session/{id}/prompt`。

## 系统边界与生成任务主链

```text
App 输入（components/prompt-input/submit.ts） → api.session.prompt（{sessionID,id,agent,model,variant,parts}）
  → POST /session/:id/prompt_async（V1，groups/session.ts:96）或 /api/session/:id/prompt（V2，client/src/generated/client.ts:370-375）
  → SessionPrompt.prompt（prompt.ts:1052-1071）：
      revert.cleanup → createUserMessage（写 user message + parts，:1046-1047）
      → loop → runLoop（:1081-1341）→ processor.create → handle.process（processor.ts:627-683）
      → llm.stream（llm.ts:357-381，AI SDK streamText）
  → LLMEvent 流（llm/ai-sdk.ts:76-286）→ SessionProcessor.handleEvent（processor.ts:278-537）
  → session.updateMessage/updatePart 发布事件（session.ts:631-645）
  → EventV2Bridge → SSE /event（handlers/event.ts）
  → App server-sdk.tsx 读取循环（16ms 批量 flush）→ 投影到 store（渲染细节在消息渲染器）
```

边界：会话与消息如何持久化、消息删除/revert/fork 的数据语义属于会话与消息管理；SSE 到 store 的投影与渲染属于消息渲染器；TUI/Web 的发送、停止按钮与排队提示属于 Chat UI。

## 1. 提交入口、任务对象与状态机

- **发送链**：App `createPromptSubmit.handleSubmit`（submit.ts:318-639）→ `sendFollowupDraft`（:58-208）→ `api.session.prompt`（:168-199，V2 协议路径，经 server-compat 兼容层）；命令前缀走 `api.session.command`（:88-105）、shell 模式走 `api.session.shell`（:491-510）。TUI 端 `component/prompt/index.tsx`：普通发送 :1092-1121、shell 模式 :1059-1070、自定义命令 :1071-1091。
- **V1 端点**：`POST /session/:id/prompt_async`（groups/session.ts:96；handlers/session.ts:311-329 后台 fork 执行，错误经 `session.error` 事件回传）→ `SessionPrompt.prompt`（prompt.ts:1052-1071）：`revert.cleanup` → `createUserMessage`（:635-1050）→ `loop`（:1343-1347，`state.ensureRunning`）→ `runLoop`（:1081-1341）→ processor。
- **V2 端点**：`POST /api/session/{id}/prompt`（client.ts:370-375）→ `V2Session.prompt`（core/src/session.ts:360-386）：先 `SessionInput.admit` 写 durable `session_input`（:368-379，id/session/delivery 冲突则 PromptConflictError），再 `execution.wake`（:382）；运行由 `SessionRunCoordinator` 驱动 drain。
- **任务对象**：每 session 一个 `Runner`（run-state.ts:52-69），同会话串行、不同会话并行（effect/runner.ts 状态机 Idle/Running/Shell/ShellThenRun :33-37，ensureRunning :115-138，cancel :171-202）；V2 用 `SessionRunCoordinator`（run-coordinator.ts `make` :24-104：同 key 串行 :67-79、wake 合并 :81-92、interrupt :94-101）。
- **状态机**：`SessionStatusEvent.Info` 只有 `idle/retry/busy` 三态（schema/src/session-status-event.ts:9-32），**没有 queued/running/paused/complete 字面状态**（retry 带 attempt/message/action/next）；V2 把非 idle 合成映射为 `{type:"running"}`（packages/server/src/handlers/session.ts:80-89）。状态仅存进程内 InstanceState Map（status.ts:26-48）。

## 2. 历史选择与上下文拼装顺序

messages 组装（prompt.ts:1257-1286）：

1. `sys.environment`（system.ts:63-99，含工作目录/git/日期/引用列表）
2. `instruction.system()`（AGENTS.md 等指令文件，instruction.ts:155-169）
3. `sys.mcp`（system.ts:115-131）
4. `sys.skills`（system.ts:101-113）
5. `MessageV2.toModelMessagesEffect` 历史转换（message-v2.ts:131-415：user text/file/compaction/subtask :198-242；assistant text/tool/reasoning/step-start :244-401；工具结果媒体抽离为合成 user 消息 :382-399；pending/running tool 以 `[Tool execution was interrupted]` 错误回注 :351-360）
6. `LLMRequestPrep.prepare` 拼 system 头（llm/request.ts:56-206，system 合并为单条 :58-66、非 workflow 时前置 system 消息 :101-112）

历史每轮从数据库重读（`MessageV2.filterCompactedEffect` + `latest`，prompt.ts:1092-1096），上下文来源与顺序以最终请求为准。首轮并行触发自动标题与摘要生成（prompt.ts:1133-1139、:1252-1253，fork 后台）。

## 3. 预算、截断、摘要与压缩

- **溢出检测**：`isOverflow`（src/session/overflow.ts:22-34，`count >= usable`；count 优先用 `tokens.total`）；`usable = model.limit.input - reserved`，reserved 默认 `min(20_000, maxOutputTokens)`（:8-20，可被 `cfg.compaction.reserved` 覆盖）。step-finish 检查溢出置 `needsCompaction`（processor.ts:477-482），loop 里 `lastFinished` 溢出也触发（prompt.ts:1161-1168）。
- **compaction 流程**：`compaction.create` 插入带 `compaction` part 的 user 消息（compaction.ts:552-575）→ `compaction.process`（:325-550）：`select` 按 `tail_turns`（默认 2）与 `preserve_recent_tokens` 预算（2k-8k 或 usable×25%）挑尾部（:224-275、:116-121）、`splitTurn` 可半轮截断（:141-164）、`prune` 清空旧 tool 输出并标 `time.compacted`（:279-323，`PRUNE_MINIMUM=20k`/`PRUNE_PROTECT=40k` :28-29）。压缩请求本身不再逐消息转 AI SDK 消息，而是用 `serialize` 把选中历史拼成纯文本，随 `nextPrompt`（`buildPrompt`，core/src/session/compaction.ts:161-168）一起作为单条 user 消息发出（compaction.ts:52-86、:385-441）。
- **重排**：`filterCompacted` 把 [compaction-user, summary-assistant, tail, continue-user] 重排供模型（message-v2.ts:521-572）；`latest` 判定按 `time.created` 排序、id 仅作决胜（:582-604）；上下文长度用 `Token.estimate` 估算（compaction.ts:216-222）。压缩改写历史而非删历史（保留语义见会话与消息管理笔记 9）。
- **V2 压缩**：core/src/session/compaction.ts 独立实现（`compactIfNeeded`/`compactAfterOverflow` :170-240，SUMMARY_TEMPLATE :16-46，同样 serialize 文本化 :86-112）。

## 4. SDK、Provider、模型与协议交接

- `llm.stream`（llm.ts:357-381）使用 AI SDK `streamText`（:280-353）；请求先经 `LLMRequestPrep.prepare`（llm/request.ts:56-206：system/消息/tools/参数/headers，工具按权限过滤 :208-214）。
- **运行时选择**：默认 AI SDK 路径；`OPENCODE_EXPERIMENTAL_NATIVE_LLM` 时先试 `LLMNativeRuntime.stream`（llm.ts:226-269），不支持则回退 AI SDK（native-runtime.ts）。
- LLM 流经 `LLMAISDK.toLLMEvents` 转统一事件（llm/ai-sdk.ts:76-286）：`start-step/finish-step`、`text-start/delta/end`、`reasoning-start/delta/end`、`tool-input-start/delta/end`、`tool-call`、`tool-result`、`tool-error`、`finish`、`error`、`raw`。具体各 provider 的协议 Adapter 层本次未展开。

## 5. 流式事件、缓冲、节流与顺序

- **服务端事件产生**：delta 用 `updatePartDelta` 发 `message.part.delta`（processor.ts:499-510；session.ts:879-887 定义 delta 事件 `{sessionID,messageID,partID,field,delta}`）；`text-end` 才完整写 part 并触发插件 `experimental.text.complete`（:512-532）。reasoning 同理（:280-313，start 落库、delta 发增量、end 收口）。tool 状态迁移（pending→running→completed/error）即时 `updatePart`（:216-253、:331-414）。
- **SSE 投递**：handlers/event.ts:25-87，`Queue.unbounded` + `Stream.fromQueue` 按目录/workspace 过滤，先发 `server.connected`，每 10 秒 `server.heartbeat`，实例 disposed 时收流（:42-62）。
- **App 读取循环**：server-sdk.tsx:260-317，`for await` 逐事件；`coalesceServerEvents` 拼接连续 delta（:79-139），`flush()` 每 16ms 批量分发（:227-245），断线 250ms 重连（:308）。TUI 端同样 16ms 批量（tui/src/context/sdk.tsx:54-80），断线指数退避 1s→30s（:112-114）。
- **Store 投影**：`message.part.updated` 按 id 二分插入/替换、`message.part.delta` 写入 `part_text_accum_delta` 并就地 append、V2 事件投影回 V1 形态（server-session.ts、server-session-v2-reducer.ts）——投影与 DOM 更新的详细实现见消息渲染器笔记。

## 6. 完成、异常、半截流与最终回写

- **最终化**：完整 part 在 end 事件时落库（processor.ts:512-532）；`step-finish` 累计 usage/cost 并写 step-finish part、按快照 diff 写 patch part、后台触发摘要（:435-484、:471-476）；`finish` 事件收口，assistant message 的 `time.completed` 与 `finish` 字段随消息落库（runLoop 退出判定 :1111-1130、cleanup :595-596）。
- **异常/半截流**：`cleanup`（processor.ts:539-597）把未完成 text/reasoning part 置终态、tool part 标 `"Tool execution aborted"` + `interrupted:true`（:577-593），重放时以 `[Tool execution was interrupted]` 错误回注（message-v2.ts:351-360）；`halt`（processor.ts:599-625）归一化错误并发布 `session.error`，context overflow 在 auto compaction 开启时置 `needsCompaction` 而非直接失败（:607-618）。
- **错误归一化**：`fromError`（message-v2.ts:606-734）映射 8 种错误类型（数据语义见会话与消息管理笔记 1）。content-filter / 结构化输出失败在 runLoop 收口为错误消息（prompt.ts:1301-1316）。

## 7. 停止、重试、续写与重新生成

- **停止**：App `abort()`（submit.ts:259-278，含排队草稿 abort）→ `POST /session/:id/abort`（groups/session.ts:253-264）→ `SessionPrompt.cancel`（prompt.ts:152-155）→ `SessionRunState.cancel`（run-state.ts:77-86）→ `Runner.cancel`（runner.ts:171-202）中断 fiber → `onInterrupt` 置 aborted 走 `halt(DOMException AbortError)`（processor.ts:648-654）→ 随后 `cleanup` 置终态（第 6 节）。界面入口（TUI 双击 Esc / Web 中断按钮）见 Chat UI 笔记。
- **重试**：`SessionRetry.policy`（src/session/retry.ts:182-206）：`retryable` 判定 5xx/429/超时/网络错误（:84-154），context overflow 不重试（:86）；`delay` 尊重 retry-after 头、指数退避 2s 起加 0.25 随机抖动（:26-31、:46-82），`meta.attempt > RETRY_MAX_RETRIES(5)` 停止（:192）；接入 processor 的 `Effect.retry`（processor.ts:660-674），每次尝试发布 `{type:"retry",attempt,message,next}` 状态（:664-672）。
- **重试与重新生成的区别**：无独立重试端点；前端对失败消息的重试本质是再次发送（续写语义见会话与消息管理笔记 4）。

## 8. 队列、多会话并发与后台生成

- **并发粒度**：每 session 一个 `Runner`（run-state.ts:52-69），同会话串行（busy 时 prompt 报 `SessionBusyError`）、不同会话并行（runner.ts:115-138）；V2 用 `SessionRunCoordinator`（run-coordinator.ts:24-104）。
- **再次发送**：同 session 追加即续写；V2 有 `delivery: "steer"`（打断当前轮，admitted 后等安全边界 promote，input.ts:245-266）与 `"queue"`（排队至空闲，promoteNextQueued :268-288）。App 另有客户端级排队：`shouldQueue`（settings followup=queue 且 busy 时，pages/session.tsx:1754-1757）→ followup dock 暂存 → 空闲后补发（sendFollowupDraft）。
- **后台生成**：`BackgroundJob` 服务（src/background/job.ts → core/src/background-job.ts，进程内注册表，重启丢失状态 :115-119）；子 agent 可通过 task 工具后台运行（tool/task.ts:256-286，metadata.background + jobId）；`POST /experimental/session/:id/background` 把当前阻塞会话的同步子 agent 任务转后台继续（handlers/experimental.ts:159-172，OpenAPI 描述 "Detach any synchronous subagents currently blocking the session..."，groups/experimental.ts:235-245）。TUI 快捷键 ctrl+b（config/keybind.ts:98）。

## 9. Agent、工具、知识库与附件注入点

- **工具集解析**：`SessionTools.resolve`（tools.ts:41-134）→ `ToolRegistry.tools({modelID,providerID,agent,permission})`（:92-97；registry.ts:286-309 按模型/权限过滤）→ request 层权限过滤（llm/request.ts:208-214）。内置工具含 shell/read/glob/grep/edit/write/task/fetch/todo/search/skill/patch/question/lsp 等（registry.ts:204-247）；MCP 工具在此挂载（tools.ts:390-490，逐调用 `ctx.ask` 权限）。
- **MCP 资源**：用户输入中的 MCP resource part 由 `resolveUserPart` 读取并转 text/file part（prompt.ts:703-783，blob 转 `data:` URL，超 10MB 或不支持类型则文本占位）；MCP 资源工具（list/read_mcp_resource 等）在 tools.ts:136-385，结果附件同样内联 data URL（:426-462）。
- **附件**：App 端 `blobDataUrl(blob, mime)` 把图片转 data URL（submit.ts:101、:117）；服务端把 `file:` 读成 `data:` base64 的是 `resolveUserPart`（prompt.ts:808-970，text/plain 走 Read 工具 :830-907、目录 :909-947、二进制 :949-970），`resolvePromptParts`（:157-191）只做 markdown 模板解析产生 `file:` URL part；tool 结果附件同样内联（tools.ts:426-462）。存储形状（data URL 内联、无独立附件目录）见会话与消息管理笔记 8。
- **todo 回注**：模型经 `todowrite` 工具写入，列表 JSON 作为 tool result 回注（tool/todo.ts:22-43）——回注靠工具返回值，会话历史无额外 todo 注入（静态推断）。
- **system 注入点**：environment/skills/mcp 指令（system.ts:63-131）、AGENTS.md 指令（instruction.ts:155-169）、structured output 系统提示（prompt.ts:1271、:74-82）。

## 10. 退出恢复、日志与已确认边界

- **退出恢复**：消息/parts 均逐步落库，退出后从 SQLite 恢复；进程内运行态（Runner/status/BackgroundJob）不落库，随实例清理（run-state.ts:35-50、background-job.ts:115-119）。V2 post-crash continuation recovery 标注为未来工作（core/src/session/runner/llm.ts:86）。
- **可观测性**：Effect span（`Session.run`/`SessionProcessor.process` 等命名，工具执行带属性 tools.ts:410-419）；OpenTelemetry 开关 `cfg.experimental.openTelemetry`（llm.ts:208-222、:344-352）；用量与成本累计到 `session.cost/tokens` 列（session.ts getUsage :338-407、projector.ts:90-110）。
- **V1/V2 双轨执行差异**：V1 为生产主路径；V2 的 prompt 先写 durable `session_input` 再 wake（core/src/session.ts:360-386，AGENTS.md "V2 Session Core"），两轨端点不同（第 1 节）。双轨数据模型差异见会话与消息管理笔记 1。
- **已确认边界**：静态代码确认入口、顺序与状态分支；取消效果、退出恢复、并发竞态和长上下文行为需要运行验证。

## 11. 未验证事项

1. 未运行构建与真实对话；流式渲染、中断、重试的实际用户体验未实测。
2. V2 事件溯源链路（session_input/event 表、projector、run-coordinator、drain）未运行验证。
3. `part_text_accum_delta` 在断线重连与事件乱序下的行为未实测。
4. 附件 data URL 在超长上下文与工具结果中的实际 token 成本未实测。
5. native LLM 运行时（OPENCODE_EXPERIMENTAL_NATIVE_LLM）路径未验证。

## 12. 关键源码索引

- `packages/opencode/src/session/prompt.ts`：发送主链路（prompt :1052-1071、runLoop :1081-1341、createUserMessage :635-1050）
- `packages/opencode/src/session/processor.ts`：流式事件消费（:278-537）、清理（:539-597）、重试接入（:660-674）
- `packages/opencode/src/session/llm.ts`、`src/session/llm/{ai-sdk,request,native-runtime}.ts`：模型请求、事件转换与运行时选择
- `packages/opencode/src/session/compaction.ts`、`overflow.ts`、`retry.ts`：上下文压缩与自动重试
- `packages/opencode/src/session/{run-state.ts,status.ts}`、`src/effect/runner.ts`：会话运行状态机
- `packages/core/src/session/{run-coordinator.ts,input.ts,session.ts}`：V2 执行协调与 durable 输入
- `packages/opencode/src/session/tools.ts`、`src/tool/registry.ts`、`src/tool/{task,todo}.ts`：工具解析与注入
- `packages/app/src/components/prompt-input/submit.ts`、`src/context/server-sdk.tsx`：App 提交与事件读取
- `packages/opencode/src/server/routes/instance/httpapi/handlers/{session,event,experimental}.ts`：HTTP/SSE 端点
