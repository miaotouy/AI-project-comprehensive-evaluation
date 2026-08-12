# Hermes Agent 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：直接阅读源码（Python Agent 会话运行时 run_agent.py / agent/ 包、tui_gateway JSON-RPC 网关、桌面端与 TUI 事件消费），所有符号与行号在 HEAD 快照处逐一核对；行为类结论区分源码事实与静态推断
>
> 调查范围：一次生成任务的提交入口、任务对象与状态机、历史选择与上下文拼装顺序、预算截断与压缩、Provider 交接、流式事件链、最终化与回写、停止重试续写、队列并发、外部能力注入点与退出恢复。会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目；工具执行循环内部语义属于 Agent 工具类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手。桌面端不运行 agent，而是自 spawn 一个无头 `hermes serve` 后端进程，renderer 通过 WebSocket 发起 `prompt.submit` 等 JSON-RPC 调用，后端在独立线程运行 `AIAgent.run_conversation`，把增量文本以 `message.delta`、终态以 `message.complete` 事件推回 UI。

主链路：composer → `prompt.submit`（WS）→ `methods_prompt.py` 校验/截断/busy 门控 → `_run_prompt_submit`（记录 turn marker、注册 `_stream` 回调、启动 run 线程，`server.py:9707`）→ `agent.run_conversation`（`conversation_loop.py:1422`，`build_turn_context` 组装上下文、循环调用 Provider，每 token 增量经 `_stream` 回发）→ `finalize_turn` 持久化 → `message.complete`（含 status/text/usage）。桌面端 delta 进入自适应节流队列（33ms 起、上限 250ms），complete 后合并终态并触发会话列表刷新（300ms 合并）。

## 系统边界与生成任务主链

一次发送的事件序列：

```text
桌面 composer ─ prompt.submit(WS)
   │  methods_prompt.py: handler（校验/busy 门控/truncate，:67-346）
   │  server.py: _run_prompt_submit(:9707)
   │    ├─ record_turn_start（崩溃标记）          (:9773)
   │    ├─ _emit("message.start", sid)            (:9741)
   │    ├─ run() 线程：agent.run_conversation(...) (:10024)
   │    │     build_turn_context → 调模型 → 每 token delta 调 _stream
   │    │       └→ _emit("message.delta", {text, rendered?})  (:9968-9976)
   │    ├─ history 替换（history_version 防抖）    (:10088-10150)
   │    ├─ _sync_session_key_after_compress        (:10158)
   │    └─ _emit("message.complete", {status, text, usage})  (:10196-10232)
   └─ 桌面 gateway-event.ts：
         message.start → flushQueuedDeltas / busy 置位
         message.delta → queueDelta（33-250ms 节流合批）
         message.complete → completeAssistantMessage（合并终态、触发列表刷新）
```

事件帧格式为 `{"jsonrpc":"2.0","method":"event","params":{"type", "session_id", "payload"}}`（`server.py:1566-1570` `_event_frame`，`_emit` 在 `:1573`）。WS 端对流式事件做 33ms 合批刷帧（`ws.py:44-60`，`_TOKEN_COALESCE_S = 0.033`），非流式帧先冲刷缓冲保证顺序。

边界：会话与消息如何持久化、分支数据语义属于会话与消息管理（`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`）；发送按钮、停止反馈、排队提示等用户可见状态属于 Chat UI（`../Chat UI/Hermes-Agent-ChatUI调查笔记.md`）；流式事件进入可见状态后的渲染属于消息渲染器类目。

## 1. 提交入口、任务对象与状态机

`methods_prompt.py:67-346`（入口为 `@method("prompt.submit")`，`:67-68`）：

| 参数 | 位置 | 用途 |
|---|---|---|
| `session_id` | :71 | 会话定位 |
| `text` | :72-73 | 经 `sanitize_user_prompt_text`（`hermes_cli/input_sanitize.py:65-70`：剥粘贴包裹符、折叠重复输入伪影） |
| `interrupted` | :105-110 | 语音 barge-in 标记 → `mark_speech_interrupted()` |
| `queued` | :147-150 | 队列排空专用，强制 queue 模式（`_handle_busy_submit` 收到即只排队不打断） |
| `truncate_before_user_ordinal` | :104, :175-303 | 编辑/回退：截断历史。截断提交必须显式携带 `confirm_truncate=true`，否则拒绝（:193-209，注释“make a history-dropping submit prove it meant to”）；空截断需 `confirm_empty_truncate` 显式确认，否则拒绝（:227-244，错误 4028） |
| `surface` | :120 | 桌面 HUD 窗口标记，写入 `session["client_surface"]` |

`display_type` 参数本次未找到（全树 grep 零命中）；`display_kind`/`display_metadata` 是 `_run_prompt_submit` 的内部关键字参数（`server.py:9713-9714`），仅 auto-continue、async-delegation 路径传入。桌面端实际发送 `{session_id, text, interrupted?, surface?, queued?}`（`submit.ts:619-633` `submitParams`）。

handler 顺序：busy 循环检查（`_handle_busy_submit`，`server.py:7598`，先锁内判 running、非 busy 才跳出，`methods_prompt.py:136-155`）→ truncate（先 `db.replace_messages` 写库、失败拒轮，再改内存历史并 `history_version += 1`，`methods_prompt.py:256-303`）→ `running=True` + `_start_inflight_turn`（`:304-307`）→ `_ensure_session_db_row` + `_persist_branch_seed`（`:322-326`）→ `_start_agent_build`（惰性构建，`server.py:2129`）→ `_wait_agent_for_prompt`（`agent.build_wait_timeout` 默认 600s cap，`server.py:2035-2058`；失败走 `_emit_terminal_turn_error` 终帧，`methods_prompt.py:354-368`）→ `_run_prompt_submit` → 启动 `threading.Thread(daemon=True)`（`:391-395`）→ 返回 `{status: "streaming"}`（`:396`）。

busy 处理（`_handle_busy_submit`，`server.py:7598-7679`）：按 `display.busy_input_mode`（默认 `interrupt`）分派——`steer` 模式走 `agent.steer()`（`:7637-7644`）、`interrupt` 模式且支持活动轮重定向时走 `agent.redirect()`（`_supports_active_turn_redirect`，`:7648-7663`），否则 `_enqueue_prompt` 入队并异步 interrupt（`:7667-7679`），返回 `{status: "queued"}` 或 `{status: "steered"/"redirected"}`。

## 2. 历史选择与上下文拼装顺序

### 2.1 build_turn_context

`agent/turn_context.py:430-1378`，约 30 个动作按功能分组：

1. 恢复轮转会话：`recover_rotated_compression_session`（`:463`，若会话已被压缩轮转则取回 child 历史）；
2. 轮间 MCP 工具刷新（`:501-527`，仅在已注册 MCP 且工具集变化时动）；`agent._stream_callback = stream_callback` 注册（`:536`）；
3. `messages = list(conversation_history)` 拷贝（`:607`）；追加本轮 `user_msg` 并记 `current_turn_user_idx`（`:662-664`）；合成轮（auto-continue/delegation）的 `display_kind`/`display_metadata` 在此盖章（`:657-660`）；
4. 系统提示词：缓存为空时 `_restore_or_build_system_prompt`（`conversation_loop.py:555`，DB 恢复 → `_stored_prompt_matches_runtime` 校验 → 命中复用，否则重建并 `update_system_prompt` 持久化，`:607-683`）；恢复后 `_cached_system_prompt` 生效（`:716-719`）；
5. DB session 行 `_ensure_db_session`（`:732-744`，**在压缩之前**，防 NULL system_prompt；压缩轮转/原地压缩都要引用父行）；
6. idle 压缩（`:763` 起，见 §3）；
7. preflight 压缩（`:841` 起，见 §3）；
8. 压缩后重锚 user idx（`:828-831`）；
9. `pre_llm_call` 插件钩子（`:1152-1204`）；gateway 必达注记消费；
10. 中断状态重闩；`_memory_manager.on_turn_start`（`:1248-1252`）；
11. 外部记忆 `prefetch_all`（`:1261-1266`）；
12. `api_content` sidecar 戳（`compose_user_api_content` `turn_context.py:53` = 记忆块 + 插件上下文追加到 API 副本，`:1269-1318`）；
13. crash 持久化：`_ensure_db_session` + 用户行一次写入（`:1327-1333`）；回合末 `_maybe_title_session_at_turn_start`（`:1363`，标题机制在会话与消息管理笔记 §2.4）。

### 2.2 系统提示词组装

`build_system_prompt_parts`（`agent/system_prompt.py:152-558`）产出三档 dict：

- `stable`（跨会话稳定）：SOUL/身份、task-completion、parallel-tool-call 指导、工具族指导、tool_use_enforcement、env hints 等；
- `context`（cwd 相关）：coding workspace、profile 提示、平台 hint、调用方 `system_message`、上下文文件（`build_context_files_prompt` 在 `agent/prompt_builder.py:2273`，调用点 `system_prompt.py:488-504`）；
- `volatile`（最易变）：skills index、内置记忆块（MemoryStore 格式化，`system_prompt.py:525-530`）、USER.md、外部记忆 provider 块、时间戳行（日期级粒度保字节稳定）。

`build_system_prompt`（`:569`）拼接并缓存 `_cached_system_prompt`（`:588`）；续会话从 DB 恢复；压缩后 `invalidate_system_prompt`（`:598`）置空并重载记忆磁盘。

记忆进上下文的两个通道：内置 MemoryStore 进 volatile 系统提示词；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息，轮后由 `_sync_external_memory_for_turn`（`run_agent.py:4173`）内 `sync_all` 写回（`:4222`）。

## 3. 预算、截断、摘要与压缩

- 无 token 级截断原语；`should_compress`（`agent/context_compressor.py:2906`）：`tokens >= threshold_tokens` 且未被 block；block 原因为压缩失败冷却（`_summary_failure_cooldown_until`）或连续两次无效。`threshold_tokens` 由 context_length 比例算出（`_compute_threshold_tokens` :2473），可被绝对 cap 覆盖。
- 入口 `_compress_context`（`run_agent.py:7448`）→ `compress_context`（`agent/conversation_compression.py:2150`）。状态模板集中在 `conversation_compression.py:125-164`（PRE_API/PREFLIGHT/IDLE_COMPACTION/CONTEXT_OVERFLOW_BLOCKED）。
- preflight（`turn_context.py:841-1096`）：廉价粗估门（`_should_run_preflight_estimate` :339）→ `should_compress` → 多 pass 重测，至多 `max_compression_attempts`（默认 3）轮；`_compression_warrants_another_preflight_pass`（:322）要求行数减少或 token 降幅 >5%；被 block 时提示 `CONTEXT_OVERFLOW_BLOCKED`。
- idle 压缩：墙上时间门（`compression_idle_compact_after_seconds`，`turn_context.py:763`），与 token 阈值正交，要求 token 数 > floor。
- **压缩内容保留面**：in-flight 工具链在压缩中保留（compress 后工具结果不悬空）；clarify 等非响应哨兵保留；`codex_reasoning_items` 陈旧行修剪；max-iteration nudge 视为合成行参与合并；压缩父会话无 continuation 时的孤儿恢复。原样压缩（in-place）与轮转的旧行保留语义不变（`active=0/compacted=1`，会话与消息管理笔记 §3.4）。
- **native 服务端压缩（`agent/native_compaction.py`）**：gpt-5.6 家族 + 直接 OpenAI 路由上，向 `/v1/responses` 请求注入 `context_management=[{type:"compaction", compact_threshold:N}]`（`:1-14, :109-144`，`_ELIGIBLE_MODEL_MARKER = "gpt-5.6"` :52），服务端把旧上下文压成 opaque `compaction` item 持久化/重放；本地压缩保持 armed 作为回退（native 阈值钳在本地触发值之下，native 不生效时本地照旧）。
- **缓存边界注册表（`agent/prompt_cache_boundary.py`）**：技能/Webhook/cron builder 在构造消息时声明 stable/volatile 字节边界，缓存规划器在边界放置断点而不是把整条消息当原子块缓存；进程本地注册表，miss 时回退整条消息策略。
- 轮转（rotation）：`conversation_compression.py`——生成新 session_id → `publish_compression_child` 单事务插入子行（继承 cwd/git/profile/gateway origin；标题不在 INSERT 列内，轮转后由 `conversation_compression.py:3343, 3393-3436` 在新行重写并保留 provenance）并写压缩后消息、父行 `end_reason='compression'`（`hermes_state.py:4670`）→ `agent.session_id` 切换 → flush 基线重置。轮转的数据语义（新 session_key、血缘链、`active=0/compacted=1` 保留旧行）在会话与消息管理笔记 §1.2 / §3.4。
- 原地（in-place）：`archive_and_compact` 不轮转 ID，软归档 `active=0, compacted=1`，同一会话 ID 贯穿一生（数据语义见会话与消息管理笔记 §3）。
- 压缩后系统提示词不变仍走缓存；压缩后消息列表与轮转前副本区分，防重复追加。

## 4. SDK、Provider、模型与协议交接

`run_conversation` 主循环（`agent/conversation_loop.py:1422` 起）：

- `build_turn_context`（见 §2）；
- 主循环：每轮顶部 interrupt 检查 → budget 消耗 → `/steer` 注入最后一个 tool 结果 → `api_messages` 构建（剥 sidecar 字段、当前轮 user 消息注入记忆 sidecar、历史消息重放 `api_content`；对长度续接标记做清洗——`api_msg.pop("_length_continuation_fragment"/"_length_continuation_nudge")`，`:1912-1914`，防止片段拼接粘连与续接标记外泄到 API 线）→ system 前置（`:1963-1965`）→ prompt-cache 计划（缓存边界注册表见 §3）→ pre-API 压缩压力闸 → `_use_streaming` 判定 → `_perform_api_call`（`agent/chat_completion_helpers.py`，`build_api_kwargs` :1330；每 token 调 `agent._stream_callback`）；
- 结束 `finalize_turn`（`agent/turn_finalizer.py:70`）：中断时 `close_interrupted_tool_sequence`（:291-292）、尾部 assistant 补齐保证“有 final_response 必有 assistant 行”（:309-334）、`_drop_trailing_empty_response_scaffolding`（:268）、`_persist_session`、transform/post_llm_call hooks、result dict（含 `final_response/messages/interrupted/error/model/tokens`，:657-690）、终局 `clear_interrupt`（:727）。
- **auto 路由身份**：auto 路由在运行时按请求时的 provider/model 解析（会话内保留，不回落配置默认）；`_resolve_auto_route` 是辅助任务（标题生成等）的独立路由函数（`agent/auxiliary_client.py:5633`）。reasoning 参数随 `agent.reasoning_config` 进入请求构建（`chat_completion_helpers.py:1348`），“按请求所用模型解析而非配置默认模型”的具体解析点未在本快照逐行核对。

## 5. 流式事件、缓冲、节流与顺序

`_run_prompt_submit`（`server.py:9707` 起）中的发射链：

1. `agent.clear_interrupt()`（每轮开头的清中断语义，`:9736-9740`）；
2. `record_turn_start`（崩溃标记，`:9773`）；
3. `_emit("message.start", sid)`，payload 为空（`:9741`）；
4. `_stream` delta 回调（`:9968-9976`）：`_append_inflight_delta` 维护 resume 快照（`server.py:7303`）→ payload `{text, rendered?}`（rendered 由 `make_stream_renderer` 产生）→ TTS 队列 → `_emit("message.delta")`。

WS 端对 `message.delta` 等高频帧做 token 合批（`ws.py:60`，`_TOKEN_COALESCE_S = 0.033`，约 30fps），任何非流式帧先冲刷缓冲保证顺序（`:145-159`）。

桌面端事件→状态层（`use-message-stream/gateway-event.ts`、`use-message-stream/index.ts`）：

- **流式节流**：`queueDelta` 按会话累加（`index.ts:331-342`）→ `scheduleDeltaFlush` 总是 setTimeout 而非 rAF（防后台窗口 rAF 挂起，`:235-329`；`Math.max(STREAM_DELTA_FLUSH_MS, 3×上次 flush 实测成本)` 上限 `MAX_STREAM_FLUSH_GAP_MS`，`use-message-stream/utils.ts:67, 73`）。flush 触发点：message.start/interim、tool.*、moa.*、review.summary、message.complete 等事件处理末尾（`gateway-event.ts:594/637-643/706/733/745/768/857/865/1190/1280`）。
- `message.start` → `flushQueuedDeltas` / busy 置位；`message.delta` → `queueDelta`；`message.complete` → `completeAssistantMessage`。

## 6. 完成、异常、半截流与最终回写

`_run_prompt_submit`（`server.py:9707` 起）的收尾链：

1. history 替换带 version 防抖（`:10088-10150`）：版本未变直接替换、仅 model-switch marker 时合并（`:10098-10134`）、真 desync 不写并打 warning（`:10135-10150`）；
2. 压缩轮转后 `_sync_session_key_after_compress` 重锚 session_key（调用点 `:10158`；定义 `:4919`：会话配额租约迁移、yolo 状态迁移）；
3. status 三态：`interrupted` / `error` / `complete`（`:10162-10167`）；interrupted 且文本以取消元数据前缀开头时清空（`:10185-10188`，防桌面把取消元数据画成回复）；无可见回复 + 真实错误时以 `Error: <detail>` 作为可见文本（`:10176-10179`）；
4. `_emit("message.complete", payload)`：`{text, usage, status, reasoning?, warning?, billing?, rendered?, error+recoverable?}`（`:10196-10232`）；error 时 `_fail_inflight_turn` 保留可重放快照（`:10214-10223`）；异常路径统一走 `_emit_terminal_turn_error`（`:7796`，同样保留快照 + `recoverable: true`，`partial` 时带部分文本）；
5. finally：`trim_memory`、TTS sentinel、`running=False`、settle 事件。

桌面端 complete 合并（`use-message-stream/index.ts`）：`completeAssistantMessage`（:538）→ `mergeFinalAssistantText` 删除所有流式 text part、以权威 final 重写，保留 reasoning（除非被 final 完全覆盖，`lib/chat-messages.ts:242-266`）；interim 气泡原位结算防双泡（`index.ts:506-530, 615-640`）；结束后 `scheduleSessionsRefresh` 300ms 合并（:153-173）+ 按需 `hydrateFromStoredSession` 兜底回填（:695-712；压缩轮转的 turn 跳过回填 `compactedTurnRef`，adopted turn 先水合）。

## 7. 停止、重试、续写与重新生成

- **中断（服务端）**：
  - 服务端检查点：主循环顶部、重试 backoff 等待、空响应重试等；流式 API 入口抛 `InterruptedError`（`agent/chat_completion_helpers.py:806/822/1319` 等）。
  - `interrupt()`（`run_agent.py:3091`）：置 `_interrupt_requested`、硬取消走压缩 commit fence、向执行线程/工具 worker/子代理传播。
  - `clear_interrupt(preserve_redirect=False)`（`run_agent.py:3237`）：`preserve_redirect=True` 时仅当存在 `_pending_redirect` 才清；redirect 竞争与终局调用点在 `conversation_loop.py` 与 `turn_finalizer.py:727`。
  - `redirect()`（`run_agent.py:3328`）：只打断 model request，不扩散到工具/子代理。
  - 服务端 `session.interrupt`（`methods_session.py:2942`）：`request_hard_interrupt` + `resolve_gateway_approval(deny, resolve_all=True)` 清审批。
  - **回合租约（turn lease）**：turn 租约超时 fail-closed、可配置（`gateway/turn_lease.py`）；shutdown 时中断每个 in-flight API turn。
- **停止（桌面端）**：桌面端（apps/desktop）没有名为 `interruptResponse` 的符号（TUI 有 `SessionInterruptResponse`，`ui-tui/src/gatewayTypes.ts:313`，桌面侧无同名）；`cancelRun` 先在本地定稿（`finalizeInterruptedMessages`，`rewind.ts:122`）再调 `session.interrupt` RPC；此后本地 `interrupted` 状态使迟到流事件拒收，complete 的 interrupted 分支只清 busy 保留部分文本。停止按钮的界面反馈见 Chat UI 笔记 §5。
- **重试**：三套实现共享“截断到最后一个真实 user turn 后重发”语义（真实 user turn 判定 `is_user_originated_turn` 与数据侧变更见会话与消息管理笔记 §4）：TUI `/retry`（`ui-tui/src/app/slash/commands/core.ts:745-768`：`session.undo` → `trimLastExchange` → 重发）、slash.exec 旧路由、桌面 reload/regenerate（`rewind.ts:140` `planReload`）。CLI 对照 `cli.py:8714` `retry_last()`。
- **续写**：无 `/continue` 命令、无独立 RPC，就是普通 `prompt.submit` 文本 “continue”（busy 时也只入队）；空响应恢复会重放 `assistant("(empty)")`，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`run_agent.py:1940`，`turn_finalizer.py:268`）。
- **编辑后发送**：桌面入口 `user-message.tsx:326-355`：点击进入编辑 composer，发送即“interrupt + rewind”（数据侧 truncate 语义在会话与消息管理笔记 §4，服务端要求 `confirm_truncate` 见 §1）。
- **运行中干预**：`session.steer` 运行中可调（`methods_session.py:3219`）：`apply_pending_steer_to_tool_results`（`agent/agent_runtime_helpers.py:3940`）把文本追加到本批次最后一条 tool 消息 content 尾部（不新增消息、不破坏角色交替）；无 tool 可挂时回存，未被消费的变 `result["pending_steer"]` 由调用方作为下一轮用户消息投递（`turn_finalizer.py:717-719`）。`session.redirect`（`methods_session.py:3252`）要求 `agent._supports_active_turn_redirect`（:3273）；agent 未就绪且 running 时入队（:3267-3270）。

## 8. 队列、多会话并发与后台生成

- 同会话 busy 时：`steer` 模式 `agent.steer()`、可重定向时 `agent.redirect()`，否则 `_enqueue_prompt` 入队并异步 `agent.interrupt()`，返回 `{status: "queued"}`（`_handle_busy_submit`，`server.py:7598-7679`）；`queued` 参数是队列排空专用，强制 queue 模式（`methods_prompt.py:147-150`）。队列由 `_drain_queued_prompt` 在 turn 结束后排空（`server.py:7682`，按 `_queued_prompt_generation` 防代际串扰）。
- `_wait_agent_for_prompt` 有 600s cap（`server.py:2035`，`agent.build_wait_timeout`）。
- 后台生成：auto-continue（`_maybe_schedule_auto_continue`，`server.py:7444`）与 async-delegation 路径会传 `display_kind`/`display_metadata`；AIAgent 有 `skip_background_review` 构造参数（cron 会话默认关后台复习）；子代理异步任务经 `delegate_task` 起独立会话执行（数据语义在会话与消息管理笔记 §8）。
- 多会话并发与同会话串行化的实际运行行为未验证（见未验证事项）。

## 9. Agent、工具、知识库与附件注入点

- 工具目录与执行：run_kwargs 传 `stream_callback=_stream`、`persist_user_message`、`task_id=session_key`（`server.py:9994-10015`，含合成 turn 的 `persist_user_display_kind` 与 `session.title` 事件钩子 `:10021-10023`）；每轮顶部 `/steer` 注入最后一个 tool 结果；轮间 MCP 工具刷新（`turn_context.py:501-527`）；`pre_llm_call` 插件钩子（`turn_context.py:1152-1204`）。
- 记忆：内置 MemoryStore 进 volatile 系统提示词；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息，轮后 `sync_all` 写回（`run_agent.py:4222`）。记忆机制内部语义不在本类目展开。
- 附件注入：`@file:`/`@context` 引用预处理在 `_run_prompt_submit` 内（`server.py:9821-9850`，被拒发 `error` 事件）；图片路由 `decide_image_input_mode`（`agent/image_routing.py`，调用点 `server.py:9858-9907`：native 像素直传 / text vision 预分析）；桌面端提交时 `syncAttachmentsForSubmit` → `uploadComposerAttachment`（`use-prompt-actions/`）：跨文件系统走 `file.attach`（data_url）/`image.attach_bytes`（base64），否则共享本地路径。`[[Image N]]` 指引本次未找到（全树 grep 零命中），图片指引是 `@image:<path>` 指令行；`input.detect_drop` 只存在于 `tui_gateway/methods_prompt.py:736`，仅 Ink TUI 调用，桌面 renderer 走 file/image attach RPC。拖放捕获与附件分流的界面工作流在 Chat UI 笔记 §3。

## 10. 退出恢复、日志与已确认边界

- 崩溃恢复：`turn_marker.py` 写 `<home>/desktop/interrupted_turns.json`（`record_turn_start:97`，上限 32 条/24h/64KB；`clear_turn_marker:124` 在任何“客户端已见到结果”的结局清）；`session.resume` 时按标记自动重跑，attempts 计数防崩溃循环；断连窗口的失败 turn 由 `_fail_inflight_turn` 快照在 `session.resume` 的 `inflight` payload 中恢复（`_emit_terminal_turn_error` docstring，`server.py:7796-7803`）。标记文件的数据语义在会话与消息管理笔记 §2.3 / §3.4。
- 桌面端请求层：`prompt.submit` 带 1800s 超时（`submit.ts:650` `PROMPT_SUBMIT_REQUEST_TIMEOUT_MS=1_800_000`，turn 完成靠流事件而非 RPC ACK）；`session not found`/超时 → resume 后重试一次、busy 按目标会话重试（`withSessionBusyRetry`/`withSessionNotFoundResume`，`use-prompt-actions/utils.ts:146, 244`）。
- 可观测性：`message.complete` 携带 `usage`/`billing`（`server.py:10196, 10206-10208`）；error 终帧带 `error`/`recoverable`/`partial`/`failure_reason`（`server.py:10226-10230, 7796-7829`）。任务级日志/trace 不在本次调查范围。
- 已确认边界：无 token 级截断原语（§3）；`display_type` 参数不存在（§1）；桌面端没有 `interruptResponse` 符号（§7）。

## 11. 未验证事项

- `display.busy_input_mode` 各模式（steer/redirect/queue）在真实 provider 上的行为未验证。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证（持久化入口在会话与消息管理笔记 §2.3）。
- 崩溃重放的端到端行为、多会话并发打到同一后端的表现未实测。

## 12. 关键源码索引

- prompt 方法：`tui_gateway/methods_prompt.py`（:67-346）；`hermes_cli/input_sanitize.py`（:65-70）。
- 网关：`tui_gateway/server.py`——`_run_prompt_submit`（:9707）、`_handle_busy_submit`（:7598）、`_drain_queued_prompt`（:7682）、`_sync_session_key_after_compress`（:4919）、`_emit_terminal_turn_error`（:7796）、`_wait_agent_for_prompt`（:2035）、`_maybe_schedule_auto_continue`（:7444）、`_event_frame`/`_emit`（:1566/:1573）、`_append_inflight_delta`（:7303）。
- session 方法：`tui_gateway/methods_session.py`——interrupt（:2942）、steer（:3219）、redirect（:3252）。
- 上下文构建：`agent/turn_context.py` `build_turn_context`（:430）、`compose_user_api_content`（:53）；系统提示词：`agent/system_prompt.py` `build_system_prompt_parts`（:152）。
- 主循环：`agent/conversation_loop.py` `run_conversation`（:1422）、`_restore_or_build_system_prompt`（:555）；收尾 `agent/turn_finalizer.py`（:70）。
- 压缩：`agent/context_compressor.py` `should_compress`（:2906）、`agent/conversation_compression.py` `compress_context`（:2150）、`agent/native_compaction.py`（gpt-5.6 native 服务端压缩）、`agent/prompt_cache_boundary.py`（stable/volatile 缓存边界注册表）。
- 运行与中断：`run_agent.py`——`interrupt`/`clear_interrupt`/`redirect`（:3091/:3237/:3328）、`_compress_context`（:7448）、`_sync_external_memory_for_turn`（:4173）。
- Provider 交接：`agent/chat_completion_helpers.py`（`build_api_kwargs` :1330、`InterruptedError` 抛出点 :806/:822/:1319）。
- 崩溃标记：`tui_gateway/turn_marker.py`。
- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :230）；`use-prompt-actions/submit.ts`（submitParams :619）、`rewind.ts`（finalizeInterruptedMessages :122、planReload :140）、`utils.ts`（:146/:244）；`use-message-stream/index.ts`（completeAssistantMessage :538、scheduleSessionsRefresh :153、hydrate/adoptedRunningTurn :695-712）、`gateway-event.ts`；`lib/chat-messages.ts`（mergeFinalAssistantText :242）；`apps/shared/src/json-rpc-gateway.ts`、`use-gateway-request.ts`（按需重连与失败重放）。
