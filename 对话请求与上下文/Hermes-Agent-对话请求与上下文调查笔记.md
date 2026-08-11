# Hermes-Agent 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-11
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：从 [`../Chat/Hermes-Agent-Chat调查笔记.md`](../Chat/Hermes-Agent-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：一次生成任务的提交入口、状态机、上下文拼装与压缩、Provider 交接、流式事件链、最终化与回写、中断与重试；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手。桌面端不运行 agent，而是自 spawn 一个无头 `hermes serve` 后端进程，renderer 通过 WebSocket 发起 `prompt.submit` 等 JSON-RPC 调用，后端在独立线程运行 `AIAgent.run_conversation`，把增量文本以 `message.delta`、终态以 `message.complete` 事件推回 UI。

主链路：composer → `prompt.submit`（WS）→ `methods_prompt.py` 校验/截断/busy 门控 → `_run_prompt_submit`（记录 turn marker、注册 `_stream` 回调、启动 run 线程，`server.py:9352`）→ `agent.run_conversation`（`conversation_loop.py:1233`，`build_turn_context` 组装上下文、循环调用 Provider，每 token 增量经 `_stream` 回发）→ `finalize_turn` 持久化 → `message.complete`（含 status/text/usage）。桌面端 delta 进入自适应节流队列（33ms 起、上限 250ms），complete 后合并终态并触发会话列表刷新（300ms 合并）。

## 系统边界与生成任务主链

一次发送的事件序列：

```
桌面 composer ─ prompt.submit(WS)
   │  methods_prompt.py: handler（校验/busy 门控/truncate）
   │  server.py: _run_prompt_submit(9352)
   │    ├─ record_turn_start（崩溃标记）
   │    ├─ _emit("message.start", sid)          (9386)
   │    ├─ run() 线程：agent.run_conversation(...)  (9662)
   │    │     build_turn_context → 调模型 → 每 token delta 调 _stream
   │    │       └→ _emit("message.delta", {text, rendered?})  (9622)
   │    ├─ finalize_turn（_persist_session 落库）
   │    ├─ history 替换（history_version 防抖）    (9729-9788)
   │    └─ _emit("message.complete", {status, text, usage})  (9870)
   └─ 桌面 gateway-event.ts：
         message.start → flushQueuedDeltas / busy 置位
         message.delta → queueDelta（33-250ms 节流合批）
         message.complete → completeAssistantMessage（合并终态、触发列表刷新）
```

事件帧格式为 `{"jsonrpc":"2.0","method":"event","params":{"type", "session_id", "payload"}}`（`server.py:1532-1540`）。WS 端对流式事件做 33ms 合批刷帧（`ws.py:53-60`）。

边界：会话与消息如何持久化、分支数据语义属于会话与消息管理（`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`）；发送按钮、停止反馈、排队提示等用户可见状态属于 Chat UI（<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>）；流式事件进入可见状态后的渲染属于消息渲染器（`../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

`methods_prompt.py:67-333`（入口为 `@method("prompt.submit")`，无独立 `_handle_submit` 符号）：

| 参数 | 位置 | 用途 |
|---|---|---|
| `session_id` | :71 | 会话定位 |
| `text` | :72 | 经 `sanitize_user_prompt_text`（`hermes_cli/input_sanitize.py:65-70`：剥粘贴包裹符、折叠重复输入伪影） |
| `interrupted` | :105-110 | 语音 barge-in 标记 → `mark_speech_interrupted()` |
| `queued` | :144 | 队列排空专用，强制 queue 模式 |
| `truncate_before_user_ordinal` | :104, :160-240 | 编辑/回退：截断历史 |
| `confirm_empty_truncate` | :187 | 空截断需显式确认，否则拒绝（4028） |

`display_type` 参数本次未找到（全树 grep 零命中）；`display_kind`/`display_metadata` 是 `_run_prompt_submit` 的内部关键字参数，仅 auto-continue、async-delegation 路径传入（`server.py:9358-9359`）。桌面端实际发送 `{session_id, text, interrupted?, queued?}`（`submit.ts:606-616`）。

handler 顺序：busy 检查（`_handle_busy_submit`）→ truncate（先 `db.replace_messages` 写库、失败拒轮，再改内存历史并 `history_version += 1`，:221-238）→ `running=True` → `_ensure_session_db_row` → `_start_agent_build`（惰性构建，`agent_ready` Event）→ `_wait_agent_for_prompt`（600s cap，`server.py:1976-2067`）→ `_run_prompt_submit` → 启动 `threading.Thread(daemon=True)` → 返回 `{status: "streaming"}`。

busy 处理（`_handle_busy_submit`，`server.py:7395-7476`）：按 `display.busy_input_mode`（默认 `interrupt`）分派——`steer` 模式走 `agent.steer()`、`interrupt` 模式且支持活动轮重定向时走 `agent.redirect()`，否则 `_enqueue_prompt` 入队并异步 `agent.interrupt()`，返回 `{status: "queued"}`。

## 2. 历史选择与上下文拼装顺序

### 2.1 build_turn_context

`agent/turn_context.py:337-1275`，连续约 30 个动作，按功能分组：

1. 恢复轮转会话：`recover_rotated_compression_session`（:370-372，若会话已被压缩轮转则取回 child 历史）；
2. 轮间 MCP 工具刷新（:418-434）；`agent._stream_callback = stream_callback` 注册（:443-462）；
3. `messages = list(conversation_history)` 拷贝（:514）；追加本轮 `user_msg` 并记 `current_turn_user_idx`（:564-577）；
4. 系统提示词：缓存为空时 `restore_or_build_system_prompt`（:622-626；DB 恢复 → `_stored_prompt_matches_runtime` 校验 → 命中复用，否则重建并 `update_system_prompt` 持久化，`conversation_loop.py:475-604`）；
5. DB session 行（:639-659，在压缩之前，防 NULL system_prompt）；
6. idle 压缩（:661-738，见 §3）；
7. preflight 压缩（:740-1044，见 §3）；
8. 压缩后重锚 user idx（:1046-1057）；
9. `pre_llm_call` 插件钩子（:1059-1111）；gateway 必达注记消费（:1119-1134）；
10. 中断状态重闩（:1142-1153）；`_memory_manager.on_turn_start`（:1156-1161）；
11. 外部记忆 `prefetch_all`（:1163-1174）；
12. `api_content` sidecar 戳（:1193-1230，`compose_user_api_content` :53-85 = 记忆块 + 插件上下文追加到 API 副本）；
13. crash 持久化：`_ensure_db_session` + `_persist_session`（:1239-1260，用户行一次写入）。

### 2.2 系统提示词组装

`build_system_prompt_parts`（`agent/system_prompt.py:152-558`）产出三档 dict：

- `stable`（跨会话稳定）：SOUL/身份、task-completion、parallel-tool-call 指导、工具族指导、tool_use_enforcement、env hints 等；
- `context`（cwd 相关）：coding workspace、profile 提示、平台 hint、调用方 `system_message`、上下文文件（`build_context_files_prompt`，:480-496）；
- `volatile`（最易变）：skills index、内置记忆块（`_memory_store.format_for_system_prompt("memory")`，:515-519）、USER.md、外部记忆 provider 块、时间戳行（日期级粒度保字节稳定）。

`build_system_prompt` 拼接并缓存 `_cached_system_prompt`（:561-587）；续会话从 DB 恢复（`conversation_loop.py:502-541`）；压缩后 `invalidate_system_prompt` 置空并重载记忆磁盘（:590-599）。

记忆进上下文的两个通道：内置 MemoryStore 进 volatile 系统提示词（:515-524）；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息（:1163-1230，`memory_manager.py:525-545`），轮后 `sync_all` 写回（`turn_finalizer.py:707-712`）。

## 3. 预算、截断、摘要与压缩

- 无 token 级截断原语；`should_compress`（`context_compressor.py:2588-2634`）：`tokens >= threshold_tokens` 且未被 block；block 原因为压缩失败冷却（`_summary_failure_cooldown_until`）或连续两次无效（`:2648-2656`）。`threshold_tokens` 由 context_length 比例算出（`_compute_threshold_tokens` :2211），可被绝对 cap 覆盖。
- 入口 `_compress_context`（`run_agent.py:7308`）→ `compress_context`（`conversation_compression.py:2129`）。常量模板集中在 `conversation_compression.py`：`PRE_API/PREFLIGHT/IDLE_COMPACTION/CONTEXT_OVERFLOW_BLOCKED`（:125-164）。
- preflight（`turn_context.py:740-1044`）：廉价粗估门（:246-271）→ `should_compress` → 多 pass 重测，至多 `max_compression_attempts`（默认 3）轮；`_compression_warrants_another_preflight_pass` 要求行数减少或 token 降幅 >5%（:229-243）；被 block 时 `_warn_context_overflow_blocked`（:951-962）。
- idle 压缩（:670-738）：墙上时间门（`compression_idle_compact_after_seconds`），与 token 阈值正交，要求 token 数 > floor。
- 轮转（rotation）：`conversation_compression.py:3265-3329`——生成新 session_id → `publish_compression_child` 单事务插入子行（继承 cwd/git/profile/gateway origin）并写压缩后消息、父行 `end_reason='compression'`（`hermes_state.py:3488-3589`）→ `agent.session_id` 切换 → flush 基线重置；失败回滚父会话（:3331-3375）。轮转的数据语义（新 session_key、血缘链、`active=0/compacted=1` 保留旧行）在会话与消息管理笔记 §1.2 / §3.4。
- 原地（in-place）：`archive_and_compact` 不轮转 ID，软归档 `active=0, compacted=1`（`hermes_state.py:6938-7010`），同一会话 ID 贯穿一生。
- 压缩后系统提示词不变仍走缓存；`conversation_history_after_compression`（:1846-1882）区分两种模式防重复追加。

## 4. SDK、Provider、模型与协议交接

`run_conversation` 主循环（`conversation_loop.py:1233`，本轮已从 `run_agent.py` 抽出）：

- `build_turn_context`（:1310-1331，见 §2）；
- 主循环 `while (api_call_count < max_iterations and budget.remaining > 0)`（:1415）：每轮顶部 interrupt 检查（:1430-1435）→ budget 消耗 → `/steer` 注入最后一个 tool 结果（:1498-1535）→ `api_messages` 构建（剥 sidecar 字段、当前轮 user 消息注入记忆 sidecar、历史消息重放 `api_content`，:1587-1692）→ system 前置（:1709-1713）→ prompt-cache 计划（:1854-1870）→ pre-API 压缩压力闸（:1940-2100）→ `_use_streaming` 判定（:2348-2381）→ `_perform_api_call`（:2383-2416，`chat_completion_helpers.py:2528+`，每 token 调 `agent._stream_callback`，:3281-3283）；
- 结束 `finalize_turn`（`turn_finalizer.py:69-756`）：中断时 `close_interrupted_tool_sequence`（:289-291）、尾部 assistant 补齐保证“有 final_response 必有 assistant 行”（:308-347）、micro-compaction（:364-408）、`_persist_session`（:410）、transform/post_llm_call hooks（:543-584）、result dict（:632-665，含 `final_response/messages/interrupted/error/model/tokens`）、终局 `clear_interrupt`（:693）。

## 5. 流式事件、缓冲、节流与顺序

`_run_prompt_submit`（`server.py:9352-10171`）中的发射链：

1. `agent.clear_interrupt()`（:9380-9385，每轮开头的清中断语义）；
2. `_emit("message.start", sid)`，payload 为空（:9386）；
3. `_stream` delta 回调（:9614-9622）：`_append_inflight_delta` 维护 resume 快照（:7100-7110）→ payload `{text, rendered?}` → TTS 队列 → `_emit("message.delta")`。

WS 端对 `message.delta` 等高频帧做 token 合批（`ws.py:53-60`，33ms 约 30fps），任何非流式帧先冲刷缓冲保证顺序。

桌面端事件→状态层（`gateway-event.ts`、`use-message-stream/index.ts`）：

- **流式节流**：`queueDelta` 按会话累加（`index.ts:331-343`）→ `scheduleDeltaFlush` 总是 setTimeout 而非 rAF（防后台窗口 rAF 挂起），间隔 `max(33ms, 3×上次 flush 实测成本)` 上限 250ms（:235-329；`STREAM_DELTA_FLUSH_MS=33`/`MAX_STREAM_FLUSH_GAP_MS=250`，`utils.ts:67, 73`）。flush 触发点：message.start/interim、tool.start/progress/complete、moa.*、review.summary、message.complete 及卸载/可见性事件。
- `message.start` → `flushQueuedDeltas` / busy 置位；`message.delta` → `queueDelta`（33-250ms 节流合批）；`message.complete` → `completeAssistantMessage`（合并终态、触发列表刷新）。

## 6. 完成、异常、半截流与最终回写

`_run_prompt_submit`（`server.py:9352-10171`）的收尾链：

1. history 替换带 version 防抖：版本未变直接替换、仅 model-switch marker 时合并、真 desync 不写并打 warning（:9729-9788）；
2. 压缩轮转后 `_sync_session_key_after_compress` 重锚 session_key（:9796-9798，实现 :4750-4837：会话配额租约迁移、yolo 状态迁移）；
3. status 三态：`interrupted` / `error` / `complete`（:9800-9805）；
4. `_emit("message.complete", payload)`：`{text, usage, status, reasoning?, warning?, billing?, rendered?}`（:9834-9870）；error 终帧统一走 `_emit_terminal_turn_error`（:7593-7626，`recoverable: true` 并保留可重放快照 `_fail_inflight_turn` :7140-7166）；
5. finally：`trim_memory`、TTS sentinel、`running=False`、settle 事件（:10045-10104）。

桌面端 complete 合并（`use-message-stream/index.ts`）：`completeAssistantMessage`（:538-704）→ `mergeFinalAssistantText` 删除所有流式 text part、以权威 final 重写，保留 reasoning（除非被 final 完全覆盖，`chat-messages.ts:241-266`）；error 帧 `partial` 时保留流式文本（:567）；interim 气泡原位结算防双泡（:603-654）；结束后 `scheduleSessionsRefresh` 300ms 合并（:151-173, 686）+ 按需 `hydrateFromStoredSession` 兜底回填（:692-694，压缩轮转后跳过）。

## 7. 停止、重试、续写与重新生成

- **中断（服务端）**：
  - 服务端检查点：主循环顶部（:1430-1435）、重试 backoff 等待（:2709-2732）、空响应重试（:6780-6795）等；流式 API 入口抛 `InterruptedError`（`chat_completion_helpers.py:2544`）。
  - `interrupt()`（`run_agent.py:3024-3157`）：置 `_interrupt_requested`、硬取消走压缩 commit fence、向执行线程/工具 worker/子代理传播。
  - `clear_interrupt(preserve_redirect=False)`（`run_agent.py:3170-3223`）：`preserve_redirect=True` 时仅当存在 `_pending_redirect` 才清；redirect 竞争与终局调用点见 `conversation_loop.py:2468/2718/3495/4272` 与 `turn_finalizer.py:693`。
  - `redirect()`（`run_agent.py:3261-3351`）：只打断 model request，不扩散到工具/子代理。
  - 服务端 `session.interrupt`（`methods_session.py:2824-2895`）：`request_hard_interrupt` + `resolve_gateway_approval(deny, resolve_all=True)` 清审批。
- **停止（桌面端）**：桌面端没有 `interruptResponse`（全仓库 grep 零命中）：`cancelRun` 先在本地定稿（`finalizeInterruptedMessages`，`rewind.ts:95-99`）再调 `session.interrupt` RPC；此后本地 `interrupted` 状态使迟到流事件在三处拒收（`index.ts:98-100, 547-557`、`gateway-event.ts`），complete 的 interrupted 分支只清 busy 保留部分文本。停止按钮的界面反馈见 Chat UI 笔记 §5。
- **重试**：三套实现共享“截断到最后一个真实 user turn 后重发”语义（真实 user turn 判定与数据侧变更见会话与消息管理笔记 §4）：TUI `/retry`（`ui-tui/src/app/slash/commands/core.ts:744-768`：undo → trimLastExchange → 重发）、slash.exec 旧路由（`methods_tools.py:702-740`）、桌面 reload/regenerate（`rewind.ts:113-142` `planReload`）。CLI 对照 `cli.py:8398 retry_last()`。
- **续写**：无 `/continue` 命令、无独立 RPC，就是普通 `prompt.submit` 文本 “continue”（busy 时也只入队，`test_tui_gateway_queue_on_busy.py:106`）；空响应恢复会重放 `assistant("(empty)")`，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`turn_finalizer.py:262-267`）。
- **编辑后发送**：桌面入口 `user-message.tsx:326-356`：点击进入编辑 composer，发送即“interrupt + rewind”（数据侧 truncate 语义在会话与消息管理笔记 §4）。
- **运行中干预**：`session.steer` 运行中可调：`apply_pending_steer_to_tool_results` 把文本追加到本批次最后一条 tool 消息 content 尾部（不新增消息、不破坏角色交替，`agent_runtime_helpers.py:3921-3982`）；无 tool 可挂时回存，未被消费的变 `result["pending_steer"]` 由调用方作为下一轮用户消息投递（`turn_finalizer.py:683-685`）。`session.redirect` 要求 `agent._supports_active_turn_redirect`（`methods_session.py:3088-3124`）。

## 8. 队列、多会话并发与后台生成

- 同会话 busy 时：`steer` 模式 `agent.steer()`、可重定向时 `agent.redirect()`，否则 `_enqueue_prompt` 入队并异步 `agent.interrupt()`，返回 `{status: "queued"}`（`_handle_busy_submit`，`server.py:7395-7476`）；`queued` 参数是队列排空专用，强制 queue 模式（`methods_prompt.py:144`）。
- `_wait_agent_for_prompt` 有 600s cap（`server.py:1976-2067`）。
- 后台生成：auto-continue（`_maybe_schedule_auto_continue`，`server.py:7241-7322`）与 async-delegation 路径会传 `display_kind`/`display_metadata`（`server.py:9358-9359`）；子代理异步任务经 `delegate_task` 起独立会话执行（数据语义在会话与消息管理笔记 §8）。
- 多会话并发与同会话串行化的实际运行行为未验证（见未验证事项）。

## 9. Agent、工具、知识库与附件注入点

- 工具目录与执行：run_kwargs 传 `stream_callback=_stream`、`persist_user_message`、`task_id=session_key`（:9640-9662）；每轮顶部 `/steer` 注入最后一个 tool 结果（:1498-1535）；轮间 MCP 工具刷新（`turn_context.py:418-434`）；`pre_llm_call` 插件钩子（:1059-1111）。
- 记忆：内置 MemoryStore 进 volatile 系统提示词；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息（`turn_context.py:1163-1230`），轮后 `sync_all` 写回（`turn_finalizer.py:707-712`）。记忆机制内部语义不在本类目展开。
- 附件注入：`@file:`/`@context` 引用预处理在 `_run_prompt_submit` 内（被拒发 `error` 事件，:9460-9489）；图片路由 `decide_image_input_mode`（:9496-9546）；桌面端提交时 `syncAttachmentsForSubmit` → `uploadComposerAttachment`（`use-prompt-actions/index.ts:298-356, :99-183`）：跨文件系统走 `file.attach`（data_url）/`image.attach_bytes`（base64），否则共享本地路径。`[[Image N]]` 指引本次未找到（全仓库 grep 零命中），图片指引是 `@image:<path>` 指令行；`input.detect_drop` 只存在于 `tui_gateway/methods_prompt.py:673-717`，仅 Ink TUI 调用（`ui-tui/src/app/useComposerState.ts:262`），桌面 renderer 走 file/image attach RPC。拖放捕获与附件分流的界面工作流在 Chat UI 笔记 §3。

## 10. 退出恢复、日志与已确认边界

- 崩溃恢复：`turn_marker.py` 写 `~/.hermes/desktop/interrupted_turns.json`（`record_turn_start:97`，上限 32 条/24h/64KB；`clear_turn_marker:124` 在任何“客户端已见到结果”的结局清）；`session.resume` 时 `_maybe_schedule_auto_continue` 按标记自动重跑（`server.py:7241-7322`），attempts 计数防崩溃循环。标记文件的数据语义在会话与消息管理笔记 §2.3 / §3.4。
- 桌面端请求层：`prompt.submit` 带 1800s 超时（`submit.ts:624-626`，turn 完成靠流事件而非 RPC ACK）；`session not found`/超时 → resume 后重试一次（:627-669）。
- 可观测性：`message.complete` 携带 `usage`/`billing`；error 终帧带 `failure_reason`（§6）。任务级日志/trace 不在本次调查范围。
- 已确认边界：无 token 级截断原语（§3）；`display_type` 参数不存在（§1）；桌面端没有 `interruptResponse`（§7）。

## 11. 未验证事项

- `display.busy_input_mode` 各模式（steer/redirect/queue）在真实 provider 上的行为未验证。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证（持久化入口在会话与消息管理笔记 §2.3）。
- 崩溃重放的端到端行为、多会话并发打到同一后端的表现未实测。

## 12. 关键源码索引

- prompt 方法：`tui_gateway/methods_prompt.py`（:67-333）；`tui_gateway/input_sanitize.py`（:65-70）。
- 网关：`tui_gateway/server.py`——`_run_prompt_submit`（:9352）、`_handle_busy_submit`（:7395）、`_sync_session_key_after_compress`（:4750）、`_emit_terminal_turn_error`（:7593）、`_wait_agent_for_prompt`（:1976）、`_emit`/事件帧（:1511-1540）。
- session 方法：`tui_gateway/methods_session.py`——interrupt（:2824）、steer（:3055）、redirect（:3088）。
- 上下文构建：`agent/turn_context.py` `build_turn_context`（:337）；系统提示词：`agent/system_prompt.py` `build_system_prompt_parts`（:152）。
- 主循环：`agent/conversation_loop.py` `run_conversation`（:1233）；收尾 `agent/turn_finalizer.py`（:69）。
- 压缩：`agent/context_compressor.py` `should_compress`（:2588）、`agent/conversation_compression.py` `compress_context`（:2129）。
- 运行与中断：`run_agent.py`——`interrupt`/`clear_interrupt`/`redirect`（:3024/:3170/:3261）、`_compress_context`（:7308）、`_append_inflight_delta` 所在 `server.py:7100`。
- Provider 交接：`agent/chat_completion_helpers.py`（:2528+，`_stream_callback` :3281-3283）。
- 崩溃标记：`tui_gateway/turn_marker.py`。
- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :229）；`use-prompt-actions/submit.ts`（:112）、`rewind.ts`；`use-message-stream/index.ts`（flushQueuedDeltas :201、completeAssistantMessage :538）、`gateway-event.ts`；`lib/chat-messages.ts`（mergeFinalAssistantText :241）；`apps/shared/src/json-rpc-gateway.ts`、`use-gateway-request.ts`（按需重连与失败重放 :48-145）。
