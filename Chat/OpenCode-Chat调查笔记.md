# OpenCode Chat 调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`b8bd88901a4870ef3a5752840f4e23e11d54e24e`（分支：`dev`）
>
> 调查方式：只读源码静态梳理会话数据模型、发送链路、事件流与持久化；未运行构建与真实对话
>
> 调查范围：会话/消息/part 数据模型、生命周期与 SQLite 持久化、发送主链路、流式与中断、上下文构建与压缩、消息操作、列表与检索、外部能力绑定、TUI 与 Web 交互；桌面端（Electron）窗口/草稿差异仅核实边界；V2 事件溯源架构并行对照
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/OpenCode-会话与消息管理调查笔记.md`](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md)（数据模型、生命周期与持久化、消息操作与分支语义、列表检索、V1/V2 双轨）
> - 对话请求与上下文：[`../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md`](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md)（发送主链、上下文拼装与压缩、流式与中断、并发后台、能力注入）
> - Chat UI：[`../Chat UI/OpenCode-ChatUI调查笔记.md`](<../Chat UI/OpenCode-ChatUI调查笔记.md>)（TUI/Web 双表面工作台、Composer、生成反馈与停止、审批与消息操作工作流、多窗口连续性）
> - 消息渲染：[`../消息渲染器/OpenCode-消息渲染调查笔记.md`](../消息渲染器/OpenCode-消息渲染调查笔记.md)（已有独立笔记）
>
> 本文件第 10 节扩展调查中的多窗口同步与桌面端窗口差异已迁入 Chat UI/会话与消息管理笔记；Slack bot（转发型客户端）与主题相关内容迁移期内保留于此。

## 结论摘要

OpenCode 的 Chat 体系以「SQLite 持久化 + 事件发布 + 客户端投影」为核心。服务端把每次增量落库并发布 `message.updated` / `message.part.updated` / `message.part.delta` 事件（`src/session/session.ts:631-645`），经 SSE 推送，Web App 用 16ms 批量 flush 与 delta 拼接后投影到 Solid store（`app/src/context/server-sdk.tsx`、`server-session.ts`）。消息模型为 Session → Message（role: user/assistant）→ Part（12 种类型）三层，part 独立存表、读取时组装（`core/src/session/sql.ts`、`src/session/message-v2.ts`）。模型请求主链路为 `SessionPrompt.prompt → loop → processor → LLM.stream`（AI SDK `streamText`），每轮从数据库重读历史。

关键事实（快照 b8bd889）：

- **ID 体系**：Session `ses_` + 降序（新会话排序在前）、Message `msg_`、Part `prt_`，时间戳×0x1000+计数器编码 + 14 字节随机 base62（`packages/schema/src/identifier.ts:6-29`）。
- **Part 12 种类型**：text/subtask/reasoning/file/tool/step-start/step-finish/snapshot/patch/agent/retry/compaction（`schema/src/v1/session.ts:357-370`）。
- **流式落盘频率分三层**：reasoning/text 的 delta 走 `updatePartDelta` 发增量事件（processor.ts:499-510）、完整 part 在 end 事件时落库（:512-532）、tool part 状态迁移即时落库。
- **上下文压缩是「重写历史」**：compaction 生成 [compaction-user, summary-assistant, tail, continue-user] 重排，旧 tool 输出被清空并标记 compacted（src/session/compaction.ts）。
- **中断语义**：pending/running 的 tool part 标记为 `"Tool execution aborted"`，重放时以错误回注（processor.ts:577-593、message-v2.ts:349-360）。
- **无消息内容全文搜索**：仅会话标题 LIKE 搜索（session.ts:957-1010、:993-995）。
- **附件为 data URL 内联**：本快照未发现独立 attachments 目录，文件以 `data:` URL 存于 part.url（v1/session.ts:171-179）。
- **V1/V2 双轨**：V1（Legacy）为生产主路径；V2 为事件溯源新架构（`core/src/session.ts` + `session_input`/`event` 表），客户端按协议协商切换（app/src/utils/server-compat.ts:86-92）。

## 系统边界与总体调用链

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
  → App server-sdk.tsx 读取循环 → event-reducer / server-session 投影到 store
  → 虚拟化 timeline 渲染（pages/session/timeline/message-timeline.tsx）
```

## 1. 会话与消息数据模型

- **Session 字段**（core/src/session/sql.ts:22-66）：`id/project_id/workspace_id/parent_id/slug/directory/path/title/version/share_url/summary_*/metadata/cost/tokens_{input,output,reasoning,cache_read,cache_write}/revert/permission/agent/model{id,providerID,variant}/time_{created,updated,compacting,archived}`。
- **Message 表**：`data` 列存 `Omit<SessionV1.Info,"id"|"sessionID">`（sql.ts:77、V1MessageData 定义 :18-20），**不含 parts**；parts 独立存 `part` 表（sql.ts:82-98，仅 `message_id` 带 `onDelete: cascade` 外键 :86-89，`session_id` 为普通列、级联经 message_id 传递），读取时 `MessageV2.hydrate` 批量组装（src/session/message-v2.ts:98-123）。
- **Message 判别**：`User`（role:"user"，含 summary/agent/model/system/tools，v1/session.ts:332-354）与 `Assistant`（role:"assistant"，含 parentID/modelID/providerID/mode/agent/path/cost/tokens/finish/error/structured，:453-485）；`Info = Union`（:490-491）。
- **finish 字段**：`"tool-calls"|"stop"|"error"` 等（:453-485）；`error` 归一化类型联合共 8 种：AuthError/APIError/ContextOverflowError/AbortedError/StructuredOutputError/ContentFilterError/UnknownError（NamedError.Unknown）/OutputLengthError（v1/session.ts:385-394）。
- **`snapshot` 语义是 git 快照**：step-start/step-finish part 与 session.revert 上的 `snapshot` 字段为 git 提交哈希（v1/session.ts:233-257、src/snapshot/index.ts:39-42、349-406）。
- **V2 消息**：事件溯源模型 `SessionMessage`（schema/src/session-message.ts:200-212，type: user/assistant/synthetic/system/shell/agent-switched/model-switched/compaction），存 `session_message` 表（sql.ts:119-138），由 projector 从事件投影（core/src/session/projector.ts:350-395）。
- **`MessageV2` 是转换层而非新模型**：提供分页（page，:425-467）、历史转 AI SDK 消息（toModelMessagesEffect，:131-415）、过滤压缩（filterCompacted，:521-572）、错误归一化（fromError，:603-731）。

## 2. 会话生命周期与持久化

- **创建**：`POST /session`（server/routes/instance/httpapi/groups/session.ts:203-214）→ `Session.create`（session.ts:669-691）→ `createNext`（:501-540）：`id = SessionID.descending()`、`slug = Slug.create()`、默认标题 `New session - <ISO时间>`（:523），发布 `session.created`（:537）。V2：`POST /api/session`（packages/server/src/handlers/session.ts:67-79）→ `V2Session.create`（core/src/session.ts:208-262）。
- **重命名**：`PATCH /session/:id`（handlers/session.ts:183-204）→ `setTitle`（session.ts:755-757）。
- **删除**：`DELETE /session/:id`（handlers :178-181）→ `Session.remove`（session.ts:608-629）：取消后台任务、递归删子会话、发 `session.deleted`。
- **数据写入时机（V1 主链路）**：
  - prompt：user message 与 parts 立即落库（prompt.ts:1046-1047），agent/model 同步到 session 行（:672-689）。
  - stream：assistant message 进入循环时先落库（prompt.ts:1186-1201）；流式 part 由 processor 逐个 `updatePart`/`updatePartDelta`（processor.ts:278-537）。
  - `Session.updateMessage/updatePart` 本身只发布事件，DB 写入由事件投影器完成（session.ts:631-645；core/src/session/projector.ts:262-330 的 `message.updated`→upsert message 表、`part.updated`→upsert part 表）。
- **SQLite 位置**：`join(Global.Path.data, "opencode.db")`（core/src/database/database.ts:43-55），启动设置 WAL 等 PRAGMA 并执行迁移（:27-33）；迁移文件在 core/src/database/migration/（38 个，含 V2 会话相关）。

## 3. 发送、流式更新与中断

- **发送链**：App `createPromptSubmit.handleSubmit`（submit.ts:318-639）→ `sendFollowupDraft`（:58-208）→ `api.session.prompt`（:168-199）；V1 走 `POST /session/:id/prompt_async`（groups/session.ts:96）、V2 走生成客户端 `POST /api/session/{id}/prompt`（client/src/generated/client.ts:370-375）。
- **V1 端点**：`POST /session/:id/message`（handlers/session.ts:295-309）→ `SessionPrompt.prompt`（prompt.ts:1052-1071）：`revert.cleanup` → `createUserMessage`（:635-1050）→ `loop`（:1081-1341）→ processor。
- **流式事件**：LLM 流经 `LLMAISDK.toLLMEvents` 转统一事件（llm/ai-sdk.ts:76-286）：`text-start/delta/end`、`reasoning-start/delta/end`、`tool-input-start/delta/end`、`tool-call`、`tool-result`、`tool-error`、`step-start/finish`、`finish`。
- **文本流式写库分层**：delta 用 `updatePartDelta` 发 `message.part.delta`（processor.ts:499-510；session.ts:879-887 定义 delta 事件 `{sessionID,messageID,partID,field,delta}`）；`text-end` 才完整写 part 并触发插件 `experimental.text.complete`（:512-532）。reasoning 同理（:280-313）。
- **SSE 投递**：`handlers/event.ts:25-87`，`Queue.unbounded` + `Stream.fromQueue` 按目录过滤，先发 `server.connected`，每 10 秒 `server.heartbeat`。
- **App 读取循环**：`server-sdk.tsx:260-317`，`for await` 逐事件；`coalesceServerEvents` 拼接连续 delta（:79-139），`flush()` 每 16ms 批量分发（:227-245），断线 250ms 重连。
- **Store 投影**：`server-session.ts`：`message.part.updated` 按 id 二分插入/替换（:1095-1152）；`message.part.delta` 写入 `part_text_accum_delta` 并就地 append（:1215-1231）；`message.updated`（:1031-1063）。v2 事件经 `createV2SessionReducer` 投影回 v1 形态（server-session-v2-reducer.ts）。
- **中断**：App `abort()`（submit.ts:259-278）→ `POST /session/:id/abort`（groups/session.ts:253-264）→ `SessionRunState.cancel`（run-state.ts:77-86）→ `Effect.onInterrupt` 置 aborted 走 `halt(AbortError)`（processor.ts:648-655）；`cleanup`（:539-597）把未完成 text/reasoning/tool part 置终态（工具标 `"Tool execution aborted"` + `interrupted:true`，:577-593）。
- **重试**：`SessionRetry.policy`（src/session/retry.ts:175-198）：`retryable` 判定 5xx/429/超时/网络错误（:77-147），context overflow 不重试；`delay` 尊重 retry-after 头、指数退避 2s 起（:26-29、44-75）；接入 processor 的 `Effect.retry`（processor.ts:660-674），每次尝试发布 `retry` 状态。
- **应用退出**：消息/parts 均逐步落库；进程内运行态（Runner/status）在 InstanceState 中随实例清理（run-state.ts:35-49）。

## 4. 上下文构建、截断与压缩

- **messages 组装**（prompt.ts:1257-1286）：`sys.environment`（system.ts:60-95）→ `instruction.system()`（AGENTS.md，instruction.ts:155-169）→ `sys.mcp`（system.ts:112-128）→ `sys.skills`（:98-110）→ `MessageV2.toModelMessagesEffect` 历史转换（message-v2.ts:131-415：user text/file/compaction/subtask :198-242；assistant text/tool/reasoning/step-start :244-401；媒体抽离为合成 user 消息 :382-399）→ `LLMRequestPrep.prepare` 拼 system 头（llm/request.ts:104-112）。
- **溢出检测**：`isOverflow`（src/session/overflow.ts:22-34，`tokens.total >= usable`）；`usable = model.limit.input - reserved`（默认保留 20k，:10-20）。
- **compaction 流程**：step-finish 检查溢出置 `needsCompaction`（processor.ts:477-482）→ `result === "compact"` → `compaction.create` 插入带 `compaction` part 的 user 消息（prompt.ts:1320-1328）→ `compaction.process`（compaction.ts:289-511）：`select` 按 `tail_turns`（默认 2）与 `preserve_recent_tokens` 预算挑尾部（:32、80-85）、`splitTurn` 可半轮截断（:105-128）、`prune` 清空旧 tool 输出并标 `time.compacted`（:243-287，`PRUNE_MINIMUM=20k`/`PRUNE_PROTECT=40k`）。
- **重排**：`filterCompacted` 把 [compaction-user, summary-assistant, tail, continue-user] 重排供模型（message-v2.ts:521-572）；上下文长度用 `Token.estimate` 估算（compaction.ts:180-186）。

## 5. 编辑、重试、续写与分支

- **编辑**：无整体 edit message 端点；`PATCH /session/:id/message/:messageID/part/:partID` 更新单个 part（groups/session.ts:433-444、handlers/session.ts:397-411）。
- **删除**：`DELETE .../message/:messageID`（:409-421，需 `assertNotBusy`）与 `DELETE .../part/:partID`（:422-432）→ 发 `message.removed`/`message.part.removed` 事件（session.ts:855-877），投影器删行并回滚 usage（projector.ts:276-311）。OpenAPI 描述明确 "without reverting file changes"（groups/session.ts:419）。
- **重试**：无独立重试端点；进程内自动重试（见第 3 节），前端对失败消息的重试本质是再次发送。
- **回复/回退**：`POST /session/:id/revert`（groups/session.ts:369-382）→ `SessionRevert.revert`（revert.ts:38-88）：定位目标消息/part，记录 revert 状态（含 git snapshot），`snap.revert(patches)` 回滚文件；再次 prompt 前 `revert.cleanup`（:100-134）删除目标之后的消息——无 partID 时连目标消息本身一起删（`msg.info.id >= messageID`），有 partID 时保留目标消息、仅删其 partID 起的 parts（:107-132）。改的是原消息树（删除），不是新建分支节点。
- **分支**：`POST /session/:id/fork`（session.ts:693-734）：新建会话并复制截至某消息的全部消息/parts（parentID 重映射 :712-718）。
- **续写**：同 session 继续 prompt 追加即可；V2 有 `delivery: "steer"`（打断当前轮）与 `"queue"`（排队，core/src/session/input.ts:245-287）。

## 6. 列表、搜索与定位

- **Sidebar 列表**：`directory-sync.ts:124-134` 用 `session.list({directory, limit, order:"desc"})`，`fetch(count=10)` 递增分页；命令面板跨目录 `session.list({parentID:null, search, limit:50})`（command-palette.ts:149）。
- **V1 列表实现**：`listByProject`（session.ts:957-1010）：按 project_id + 可选 directory/path/workspaceID/roots/start/search 过滤，`LIKE title` 搜索（:993-995），orderBy desc(time_updated) limit 默认 100。
- **消息分页**：`GET /session/:id/message?limit&before=`（handlers/session.ts:106-145）→ `MessageV2.page` 用 base64url 游标 {id,time}（message-v2.ts:63-78、425-467），响应带 `Link: rel="next"` + `X-Next-Cursor`。V2 面 `session.history` 按 seq 分页读 `event` 表（server handlers/session.ts:332-356）。
- **搜索**：仅会话标题搜索；**消息内容全文搜索本次未找到实现**（全局 grep 无匹配）。
- **消息渲染**：App timeline `message-timeline.tsx`（虚拟化、`loadOlder` 分页加载，timeline/model.ts:66）；store `server-session.ts`（`initialMessagePageSize=20`，:31，消息/part 分开存，乐观更新 :108-135）。

## 7. Agent、模型、工具与附件

- **会话级绑定**：`session.agent` 与 `session.model` 列（sql.ts:51-56）；发送时不一致自动 `setAgentModel` 更新（prompt.ts:672-689、session.ts:767-778）。工具集按 agent+permission 解析：`SessionTools.resolve`（tools.ts:41-134）→ `ToolRegistry.tools({modelID,providerID,agent,permission})`（:92-97）→ request 层权限过滤（llm/request.ts:208-214）。MCP 工具、skill 在此挂载（tools.ts:390-490）。
- **附件**：文件以 `data:` URL 内联在 part.url（v1/session.ts:171-179 的 FilePart）。App 端 `blobDataUrl(blob, mime)` 把图片转 data URL（submit.ts:101、:117）；服务端把 `file:` 读成 `data:` base64 的是 `resolveUserPart`（prompt.ts:949-969，file: 分支约 :808-970），`resolvePromptParts`（:157-191）只做 markdown 模板解析产生 `file:` URL part；MCP 资源也转 data URL（prompt.ts:754-768）；tool 结果附件同样内联（tools.ts:426-462）。**本快照未发现独立 attachments 上传目录**。

## 8. 核心 UI 交互

- **TUI**：发送 `component/prompt/index.tsx:1093-1110`；shell 模式 :1060-1068；自定义命令 :1070-1090；**中断为双击 Esc**（两次 5 秒内按 Esc，:407-418）；消息渲染 `routes/session/index.tsx`（subagent footer、permission 对话框、fork 对话框）；事件经 `context/sdk.tsx:82-117` 订阅。
- **Web App**：发送 submit.ts；中断按钮直接 `api.session.interrupt`（pages/session.tsx:1823）；排队发送（`shouldQueue`，submit.ts:482-487）与 followup dock（composer/session-followup-dock.tsx）；`SessionComposerRegion`（session-composer-region.tsx）挂载 permission/question/todo/followup/revert dock。
- **多会话并发**：每 session 一个 `Runner`（run-state.ts:52-69），同会话串行、不同会话并行（effect/runner.ts:115-138 状态机 Idle/Running/Shell/ShellThenRun :33-37）；V2 用 `SessionRunCoordinator`（run-coordinator.ts:24-104）。
- **后台生成**：`BackgroundJob` 服务本体在 src/background/job.ts（run-state.ts:111-143 是 `cancelBackgroundJobs`）；"detach 子 agent 到后台"端点 `POST /experimental/session/:id/background`（handlers/experimental.ts:159-188）。
- **todo**：`Todo.update` 事务内 delete 全表 + 按 position 重插并发布 `todo.updated`（src/session/todo.ts:29-51；TodoTable sql.ts:100-117）；模型经 `todowrite` 工具写入，列表 JSON 作为 tool result 回注（tool/todo.ts:36-42）——回注靠工具返回值，会话历史无额外 todo 注入（静态推断）。App 侧 `session-todo-dock.tsx` 与 todoState 状态机（session-composer-state.ts:13-22）。
- **状态机**：`SessionStatusEvent.Info` 只有 `idle/retry/busy` 三态（schema/src/session-status-event.ts:9-32），**没有 queued/running/paused/complete 字面状态**；V2 把非 idle 合成映射为 `{type:"running"}`（packages/server/src/handlers/session.ts:81-89）。

## 9. 设计取舍与已确认边界

- **事件即写入**：`updateMessage/updatePart` 只发事件，DB 由投影器消费——写入与广播强耦合，简化一致性问题，代价是事件顺序即持久化顺序。
- **delta 通道独立于 part 存储**：流式期间前端用 `part_text_accum_delta` 累积，结束事件才完整替换——UI 更新频率高于落库频率（符合指南区分的三种频率）。
- **压缩改写历史而非删历史**：compaction 消息保留在链中，通过重排与 `time.compacted` 标记控制模型可见性。
- **revert 删除而非分支**：回退直接删消息，fork 才复制新会话。
- **消息内容不建全文索引**：仅标题搜索，长会话依赖分页与虚拟化。
- **V1/V2 双轨并存**：本快照 V1 为生产主路径；V2 的 prompt 先写 durable `session_input` 再 wake（AGENTS.md "V2 Session Core" 明确要求），但 post-crash continuation recovery 明确标注为未来工作（runner/llm.ts:86）。

## 10. 扩展调查（可选）

- **markdown/代码块渲染、虚拟化滚动**：见 `消息渲染器/OpenCode-消息渲染调查笔记.md`。
- **多窗口同步**：SSE 事件全量广播，多个窗口各自订阅同一事件流，无专门同步层（静态推断）。
- **桌面端（Electron）**：会话链路与 Web 相同——renderer 以源码方式复用 `@opencode-ai/app`（desktop/src/renderer/index.tsx:1-17），sidecar 进程内运行同一 opencode server（main/server.ts:57-184，Basic auth）；差异仅在窗口级：每窗口 MemoryRouter 与 last-active URL 恢复（index.tsx:85-111）、草稿 SQLite 持久化（main/ipc.ts:143-150 draft-*）、首启引导（onboarding）。另有单文件 Slack bot 入口（packages/slack/src/index.ts，145 行）：`@slack/bolt` socket-mode 按 channel+thread 建 opencode session 转发文本，属转发型客户端，不承载完整会话 UI。
- **主题与响应式**：本快照未展开调查。

## 11. 未验证事项

1. 未运行构建与真实对话；流式渲染、中断、重试的实际用户体验未实测（静态代码只确认事件与状态绑定）。
2. V2 事件溯源链路（session_input/event 表、projector、coordinator）未运行验证。
3. `part_text_accum_delta` 在断线重连与事件乱序下的行为未实测。
4. 附件 data URL 在超长上下文与工具结果中的实际 token 成本未实测。

## 12. 关键源码索引

- `packages/opencode/src/session/session.ts`：Session 服务（createNext :501-540、updateMessage/updatePart :631-645、remove :608-629、fork :693-734、setTitle :755-757）
- `packages/opencode/src/session/prompt.ts`：发送主链路（prompt :1052-1071、loop/runLoop :1081-1341、createUserMessage :635-1050）
- `packages/opencode/src/session/processor.ts`：流式事件消费（:278-537）、重试（:660-674）、清理（:539-597）
- `packages/opencode/src/session/llm.ts`、`src/session/llm/ai-sdk.ts`：模型请求与事件转换
- `packages/opencode/src/session/message-v2.ts`：历史转换与分页（:131-415、:425-467）
- `packages/opencode/src/session/compaction.ts`、`overflow.ts`：上下文压缩
- `packages/opencode/src/session/retry.ts`、`revert.ts`、`run-state.ts`、`status.ts`、`todo.ts`
- `packages/core/src/session/sql.ts`：表结构
- `packages/app/src/context/server-sdk.tsx`、`server-session.ts`、`server-session-v2-reducer.ts`：客户端事件投影
- `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`、`event.ts`：HTTP/SSE 端点
