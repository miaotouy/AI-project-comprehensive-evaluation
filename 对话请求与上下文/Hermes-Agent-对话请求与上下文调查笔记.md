# Hermes-Agent 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：从 [`../Chat/Hermes-Agent-Chat调查笔记.md`](../Chat/Hermes-Agent-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据；对上一快照（`01a1037d`）之后的提交范围做增量核对（`git log`/`git diff`），受影响结论在 HEAD 处源码重新确认，失效行号已更新
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
| `truncate_before_user_ordinal` | :104, :160-240 | 编辑/回退：截断历史。截断提交必须显式携带 `confirm_truncate=true`，否则拒绝（:197-206，"make a history-dropping submit prove it meant to"，`c24ff38c`） |
| `confirm_empty_truncate` | :230 | 空截断需显式确认，否则拒绝（4028） |

`display_type` 参数本次未找到（全树 grep 零命中）；`display_kind`/`display_metadata` 是 `_run_prompt_submit` 的内部关键字参数，仅 auto-continue、async-delegation 路径传入。桌面端实际发送 `{session_id, text, interrupted?, queued?}`（`submit.ts:606-616` 附近）。

handler 顺序：busy 检查（`_handle_busy_submit`，`server.py:7598`）→ truncate（先 `db.replace_messages` 写库、失败拒轮，再改内存历史并 `history_version += 1`）→ `running=True` → `_ensure_session_db_row` → `_start_agent_build`（惰性构建，`agent_ready` Event）→ `_wait_agent_for_prompt`（600s cap，`server.py:2035`）→ `_run_prompt_submit` → 启动 `threading.Thread(daemon=True)` → 返回 `{status: "streaming"}`。

busy 处理（`_handle_busy_submit`，`server.py:7598-7676`）：按 `display.busy_input_mode`（默认 `interrupt`）分派——`steer` 模式走 `agent.steer()`、`interrupt` 模式且支持活动轮重定向时走 `agent.redirect()`（`_supports_active_turn_redirect`，`:7653`），否则 `_enqueue_prompt` 入队并异步 `agent.interrupt()`，返回 `{status: "queued"}`。

## 2. 历史选择与上下文拼装顺序

### 2.1 build_turn_context

`agent/turn_context.py:430-1380`，连续约 30 个动作，按功能分组：

1. 恢复轮转会话：`recover_rotated_compression_session`（若会话已被压缩轮转则取回 child 历史）；
2. 轮间 MCP 工具刷新；`agent._stream_callback = stream_callback` 注册；
3. `messages = list(conversation_history)` 拷贝；追加本轮 `user_msg` 并记 `current_turn_user_idx`；
4. 系统提示词：缓存为空时 `restore_or_build_system_prompt`（DB 恢复 → `_stored_prompt_matches_runtime` 校验 → 命中复用，否则重建并 `update_system_prompt` 持久化，`conversation_loop.py:555-604`）；`finalize_turn` 改为 import 时绑定（`a9f94022`），并在新 live turn 前取消 in-flight 后台复习（`71435fa0`）；
5. DB session 行（在压缩之前，防 NULL system_prompt）；
6. idle 压缩（见 §3）；
7. preflight 压缩（见 §3）；
8. 压缩后重锚 user idx；
9. `pre_llm_call` 插件钩子；gateway 必达注记消费；
10. 中断状态重闩；`_memory_manager.on_turn_start`；
11. 外部记忆 `prefetch_all`；
12. `api_content` sidecar 戳（`compose_user_api_content` `turn_context.py:53` = 记忆块 + 插件上下文追加到 API 副本）；
13. crash 持久化：`_ensure_db_session` + `_persist_session`（用户行一次写入）。

### 2.2 系统提示词组装

`build_system_prompt_parts`（`agent/system_prompt.py:152-558`）产出三档 dict：

- `stable`（跨会话稳定）：SOUL/身份、task-completion、parallel-tool-call 指导、工具族指导、tool_use_enforcement、env hints 等；
- `context`（cwd 相关）：coding workspace、profile 提示、平台 hint、调用方 `system_message`、上下文文件（`build_context_files_prompt`，:480-496）；
- `volatile`（最易变）：skills index、内置记忆块（`_memory_store.format_for_system_prompt("memory")`，:515-519）、USER.md、外部记忆 provider 块、时间戳行（日期级粒度保字节稳定）。

`build_system_prompt` 拼接并缓存 `_cached_system_prompt`（:561-587）；续会话从 DB 恢复（`conversation_loop.py:502-541`）；压缩后 `invalidate_system_prompt` 置空并重载记忆磁盘（:590-599）。

记忆进上下文的两个通道：内置 MemoryStore 进 volatile 系统提示词（:515-524）；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息（:1163-1230，`memory_manager.py:525-545`），轮后 `sync_all` 写回（`turn_finalizer.py:707-712`）。

## 3. 预算、截断、摘要与压缩

- 无 token 级截断原语；`should_compress`（`context_compressor.py:2906`）：`tokens >= threshold_tokens` 且未被 block；block 原因为压缩失败冷却（`_summary_failure_cooldown_until`）或连续两次无效。`threshold_tokens` 由 context_length 比例算出（`_compute_threshold_tokens` :2473），可被绝对 cap 覆盖。
- 入口 `_compress_context`（`run_agent.py:7448`）→ `compress_context`（`conversation_compression.py:2150`）。常量模板集中在 `conversation_compression.py`：`PRE_API/PREFLIGHT/IDLE_COMPACTION/CONTEXT_OVERFLOW_BLOCKED`（:125-164）。
- preflight（`turn_context.py`）：廉价粗估门 → `should_compress` → 多 pass 重测，至多 `max_compression_attempts`（默认 3）轮；`_compression_warrants_another_preflight_pass` 要求行数减少或 token 降幅 >5%；被 block 时 `_warn_context_overflow_blocked`。
- idle 压缩：墙上时间门（`compression_idle_compact_after_seconds`），与 token 阈值正交，要求 token 数 > floor。
- **压缩内容保留面**：压缩不再丢东西——in-flight 工具链在压缩中保留（`788b8ab4`，compress 后工具结果不悬空）、clarify 等非响应哨兵保留（`d6511aec`/`39056e8d`，含伪造 clarify 摘要拒绝 `3090e9e8`）、`codex_reasoning_items` 陈旧行修剪（`adf9549c`）、max-iteration nudge 视为合成行参与合并（`aed114a6`）、压缩父会话无 continuation 时的孤儿恢复（`71dc211b`，会话笔记 §3.2）；原样压缩（in-place）与轮转的旧行保留语义不变。
- **native 服务端压缩（`agent/native_compaction.py`，`5e1b5011`）**：gpt-5.6 家族 + 直接 OpenAI 路由（api.openai.com / Codex OAuth）上，向 `/v1/responses` 请求注入 `context_management=[{type:"compaction", compact_threshold:N}]`，服务端把旧上下文压成 opaque `compaction` item（随 `codex_reasoning_items` sidecar 持久化/重放）；本地压缩保持 armed 作为回退（native 阈值钳在本地触发值之下，native 不生效时本地照旧）。
- **缓存边界注册表（`agent/prompt_cache_boundary.py`，`214f2b82`）**：技能/Webhook/cron builder 在构造消息时声明 stable/volatile 字节边界，缓存规划器在边界放置断点而不是把整条消息当原子块缓存；进程本地注册表，miss 时回退整条消息策略。
- 轮转（rotation）：`conversation_compression.py`——生成新 session_id → `publish_compression_child` 单事务插入子行（继承 cwd/git/profile/gateway origin、携带标题）并写压缩后消息、父行 `end_reason='compression'`（`hermes_state.py:4670`）→ `agent.session_id` 切换 → flush 基线重置。轮转的数据语义（新 session_key、血缘链、`active=0/compacted=1` 保留旧行）在会话与消息管理笔记 §1.2 / §3.4。
- 原地（in-place）：`archive_and_compact` 不轮转 ID，软归档 `active=0, compacted=1`（`hermes_state.py:8287`），同一会话 ID 贯穿一生。
- 压缩后系统提示词不变仍走缓存；`conversation_history_after_compression` 区分两种模式防重复追加。

## 4. SDK、Provider、模型与协议交接

`run_conversation` 主循环（`conversation_loop.py:1422`，本轮已从 `run_agent.py` 抽出）：

- `build_turn_context`（见 §2）；
- 主循环 `while (api_call_count < max_iterations and budget.remaining > 0)`：每轮顶部 interrupt 检查 → budget 消耗 → `/steer` 注入最后一个 tool 结果 → `api_messages` 构建（剥 sidecar 字段、当前轮 user 消息注入记忆 sidecar、历史消息重放 `api_content`；对**长度续接标记**做清洗——`strip length-continuation marks` 与续接片段分离，`c8c8cfbf`/`4cc3ea01`，防止片段拼接粘连与续接标记外泄到 API 线）→ system 前置 → prompt-cache 计划（缓存边界注册表见 §3）→ pre-API 压缩压力闸 → `_use_streaming` 判定 → `_perform_api_call`（`chat_completion_helpers.py`，每 token 调 `agent._stream_callback`）；
- 结束 `finalize_turn`（`turn_finalizer.py:70`）：中断时 `close_interrupted_tool_sequence`、尾部 assistant 补齐保证“有 final_response 必有 assistant 行”、micro-compaction、`_persist_session`、transform/post_llm_call hooks、result dict（含 `final_response/messages/interrupted/error/model/tokens`）、终局 `clear_interrupt`。
- **auto 路由身份保留**：`_resolve_auto_route` 生效范围扩到 relay/logging/endpoint 检测（`c95a1b71`），auto 路由的 provider 身份在会话内保留（`293e6732`）；reasoning 按**请求所用模型**解析而非 `model.default`（`93964fda`）。

## 5. 流式事件、缓冲、节流与顺序

`_run_prompt_submit`（`server.py:9707` 起）中的发射链：

1. `agent.clear_interrupt()`（每轮开头的清中断语义）；
2. `_emit("message.start", sid)`，payload 为空；
3. `_stream` delta 回调（:9968-9976）：`_append_inflight_delta` 维护 resume 快照（:7303）→ payload `{text, rendered?}` → TTS 队列 → `_emit("message.delta")`。

WS 端对 `message.delta` 等高频帧做 token 合批（`ws.py:53-60`，33ms 约 30fps），任何非流式帧先冲刷缓冲保证顺序。

桌面端事件→状态层（`gateway-event.ts`、`use-message-stream/index.ts`）：

- **流式节流**：`queueDelta` 按会话累加（`index.ts:331-343`）→ `scheduleDeltaFlush` 总是 setTimeout 而非 rAF（防后台窗口 rAF 挂起），间隔 `max(33ms, 3×上次 flush 实测成本)` 上限 250ms（:235-329；`STREAM_DELTA_FLUSH_MS=33`/`MAX_STREAM_FLUSH_GAP_MS=250`，`utils.ts:67, 73`）。flush 触发点：message.start/interim、tool.start/progress/complete、moa.*、review.summary、message.complete 及卸载/可见性事件。
- `message.start` → `flushQueuedDeltas` / busy 置位；`message.delta` → `queueDelta`（33-250ms 节流合批）；`message.complete` → `completeAssistantMessage`（合并终态、触发列表刷新）。

## 6. 完成、异常、半截流与最终回写

`_run_prompt_submit`（`server.py:9707` 起）的收尾链：

1. history 替换带 version 防抖：版本未变直接替换、仅 model-switch marker 时合并、真 desync 不写并打 warning；
2. 压缩轮转后 `_sync_session_key_after_compress` 重锚 session_key（:4919：会话配额租约迁移、yolo 状态迁移）；
3. status 三态：`interrupted` / `error` / `complete`（:10162-10167）；interrupted 且文本以取消元数据前缀开头时清空（:10180-10188，防桌面把取消元数据画成回复）；
4. `_emit("message.complete", payload)`：`{text, usage, status, reasoning?, warning?, billing?, rendered?, error+recoverable?}`（:10196-10232）；error 终帧统一走 `_emit_terminal_turn_error`（:7796，`recoverable: true` 并保留可重放快照 `_fail_inflight_turn`）；
5. finally：`trim_memory`、TTS sentinel、`running=False`、settle 事件。

桌面端 complete 合并（`use-message-stream/index.ts`）：`completeAssistantMessage`（:210 类型定义，实现于 `index.ts` 与 `gateway-event.ts`）→ `mergeFinalAssistantText` 删除所有流式 text part、以权威 final 重写，保留 reasoning（除非被 final 完全覆盖，`chat-messages.ts:241-266`）；error 帧 `partial` 时保留流式文本；interim 气泡原位结算防双泡；结束后 `scheduleSessionsRefresh` 300ms 合并 + 按需 `hydrateFromStoredSession` 兜底回填（压缩轮转后跳过，adopted turn 先水合）。

## 7. 停止、重试、续写与重新生成

- **中断（服务端）**：
  - 服务端检查点：主循环顶部、重试 backoff 等待、空响应重试等；流式 API 入口抛 `InterruptedError`（`chat_completion_helpers.py:806/822/1319` 等）。
  - `interrupt()`（`run_agent.py:3091`）：置 `_interrupt_requested`、硬取消走压缩 commit fence、向执行线程/工具 worker/子代理传播。
  - `clear_interrupt(preserve_redirect=False)`（`run_agent.py:3237`）：`preserve_redirect=True` 时仅当存在 `_pending_redirect` 才清；redirect 竞争与终局调用点见 `conversation_loop.py` 与 `turn_finalizer.py:70`。
  - `redirect()`（`run_agent.py:3328`）：只打断 model request，不扩散到工具/子代理。
  - 服务端 `session.interrupt`（`methods_session.py:2942`）：`request_hard_interrupt` + `resolve_gateway_approval(deny, resolve_all=True)` 清审批。
  - **回合租约（turn lease）**：turn 租约超时 fail-closed、可 yaml 配置（`b3e9e917`/`29af112c`/`b2b681fe`，`gateway/turn_lease.py`）；shutdown 时中断每个 in-flight API turn（`d9ddfb23`/`51fa7db4`）。
- **停止（桌面端）**：桌面端没有 `interruptResponse`（全仓库 grep 零命中）：`cancelRun` 先在本地定稿（`finalizeInterruptedMessages`，`rewind.ts:122`）再调 `session.interrupt` RPC；此后本地 `interrupted` 状态使迟到流事件拒收，complete 的 interrupted 分支只清 busy 保留部分文本。停止按钮的界面反馈见 Chat UI 笔记 §5。
- **重试**：三套实现共享“截断到最后一个真实 user turn 后重发”语义（真实 user turn 判定与数据侧变更见会话与消息管理笔记 §4）：TUI `/retry`（`ui-tui/src/app/slash/commands/core.ts:744-768`：undo → trimLastExchange → 重发）、slash.exec 旧路由、桌面 reload/regenerate（`rewind.ts:140` `planReload`）。CLI 对照 `cli.py:8714 retry_last()`。
- **续写**：无 `/continue` 命令、无独立 RPC，就是普通 `prompt.submit` 文本 “continue”（busy 时也只入队）；空响应恢复会重放 `assistant("(empty)")`，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`turn_finalizer.py`）。
- **编辑后发送**：桌面入口 `user-message.tsx:326-356`：点击进入编辑 composer，发送即“interrupt + rewind”（数据侧 truncate 语义在会话与消息管理笔记 §4，服务端要求 `confirm_truncate` 见 §1）。
- **运行中干预**：`session.steer` 运行中可调（`methods_session.py:3219`）：`apply_pending_steer_to_tool_results`（`agent_runtime_helpers.py:3940`）把文本追加到本批次最后一条 tool 消息 content 尾部（不新增消息、不破坏角色交替）；无 tool 可挂时回存，未被消费的变 `result["pending_steer"]` 由调用方作为下一轮用户消息投递（`turn_finalizer.py:717-719`）。`session.redirect`（`methods_session.py:3252`）要求 `agent._supports_active_turn_redirect`（:3273）。

## 8. 队列、多会话并发与后台生成

- 同会话 busy 时：`steer` 模式 `agent.steer()`、可重定向时 `agent.redirect()`，否则 `_enqueue_prompt` 入队并异步 `agent.interrupt()`，返回 `{status: "queued"}`（`_handle_busy_submit`，`server.py:7598-7676`）；`queued` 参数是队列排空专用，强制 queue 模式（`methods_prompt.py:144` 附近）。
- `_wait_agent_for_prompt` 有 600s cap（`server.py:2035`）。
- 后台生成：auto-continue（`_maybe_schedule_auto_continue`，`server.py:7444`）与 async-delegation 路径会传 `display_kind`/`display_metadata`；`AIAgent` 新增 `skip_background_review` 构造参数（`eaeba647`，cron 会话默认关后台复习）；子代理异步任务经 `delegate_task` 起独立会话执行（数据语义在会话与消息管理笔记 §8）。
- 多会话并发与同会话串行化的实际运行行为未验证（见未验证事项）。

## 9. Agent、工具、知识库与附件注入点

- 工具目录与执行：run_kwargs 传 `stream_callback=_stream`、`persist_user_message`、`task_id=session_key`（`server.py:9994-10015`，含合成 turn 的 `persist_user_display_kind` 与 `session.title` 事件钩子 `:10021`）；每轮顶部 `/steer` 注入最后一个 tool 结果；轮间 MCP 工具刷新（`turn_context.py`）；`pre_llm_call` 插件钩子。
- 记忆：内置 MemoryStore 进 volatile 系统提示词；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息，轮后 `sync_all` 写回。记忆机制内部语义不在本类目展开。
- 附件注入：`@file:`/`@context` 引用预处理在 `_run_prompt_submit` 内（被拒发 `error` 事件）；图片路由 `decide_image_input_mode`（`server.py:9861-9868`）；桌面端提交时 `syncAttachmentsForSubmit` → `uploadComposerAttachment`（`use-prompt-actions/`）：跨文件系统走 `file.attach`（data_url）/`image.attach_bytes`（base64），否则共享本地路径。`[[Image N]]` 指引本次未找到（全仓库 grep 零命中），图片指引是 `@image:<path>` 指令行；`input.detect_drop` 只存在于 `tui_gateway/methods_prompt.py:736`，仅 Ink TUI 调用，桌面 renderer 走 file/image attach RPC。拖放捕获与附件分流的界面工作流在 Chat UI 笔记 §3。

## 10. 退出恢复、日志与已确认边界

- 崩溃恢复：`turn_marker.py` 写 `~/.hermes/desktop/interrupted_turns.json`（`record_turn_start:97`，上限 32 条/24h/64KB；`clear_turn_marker:124` 在任何“客户端已见到结果”的结局清）；`session.resume` 时 `_maybe_schedule_auto_continue` 按标记自动重跑（`server.py:7444`），attempts 计数防崩溃循环。标记文件的数据语义在会话与消息管理笔记 §2.3 / §3.4。
- 桌面端请求层：`prompt.submit` 带 1800s 超时（`submit.ts:650` `PROMPT_SUBMIT_REQUEST_TIMEOUT_MS=1_800_000`，turn 完成靠流事件而非 RPC ACK）；`session not found`/超时 → resume 后重试一次、busy 按目标会话重试（`withSessionBusyRetry`/`withSessionNotFoundResume`，`utils.ts:146,244`）。
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
- 网关：`tui_gateway/server.py`——`_run_prompt_submit`（:9707）、`_handle_busy_submit`（:7598）、`_sync_session_key_after_compress`（:4919）、`_emit_terminal_turn_error`（:7796）、`_wait_agent_for_prompt`（:2035）、`_maybe_schedule_auto_continue`（:7444）、`_emit`/事件帧（:1573）。
- session 方法：`tui_gateway/methods_session.py`——interrupt（:2942）、steer（:3219）、redirect（:3252）。
- 上下文构建：`agent/turn_context.py` `build_turn_context`（:430）；系统提示词：`agent/system_prompt.py` `build_system_prompt_parts`（:152）。
- 主循环：`agent/conversation_loop.py` `run_conversation`（:1422）；收尾 `agent/turn_finalizer.py`（:70）。
- 压缩：`agent/context_compressor.py` `should_compress`（:2906）、`agent/conversation_compression.py` `compress_context`（:2150）、`agent/native_compaction.py`（gpt-5.6 native 服务端压缩）、`agent/prompt_cache_boundary.py`（stable/volatile 缓存边界注册表）。
- 运行与中断：`run_agent.py`——`interrupt`/`clear_interrupt`/`redirect`（:3091/:3237/:3328）、`_compress_context`（:7448）；`_append_inflight_delta` 所在 `server.py:7303`。
- Provider 交接：`agent/chat_completion_helpers.py`（`build_api_kwargs` :1330、`InterruptedError` :806/1319）。
- 崩溃标记：`tui_gateway/turn_marker.py`。
- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :229）；`use-prompt-actions/submit.ts`（:97）、`rewind.ts`（finalizeInterruptedMessages :122、planReload :140）、`utils.ts`（:146/:244）；`use-message-stream/index.ts`（completeAssistantMessage、hydrate/adoptedRunningTurn :656-676）、`gateway-event.ts`；`lib/chat-messages.ts`（mergeFinalAssistantText :241）；`apps/shared/src/json-rpc-gateway.ts`、`use-gateway-request.ts`（按需重连与失败重放 :48-145）。
