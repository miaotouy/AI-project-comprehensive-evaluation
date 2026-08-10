# Hermes-Agent Chat 调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-10
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：静态阅读 Python（tui_gateway / agent / run_agent / hermes_state）与 TypeScript（apps/desktop、apps/shared、ui-tui）源码；以函数行号精确引用；未运行任何组件。
>
> 调查范围：以桌面端（Electron + React）为观察界面，追踪一条消息从输入到持久化的主链路；覆盖会话/消息数据模型、生命周期、发送与流式、上下文构建与压缩、消息操作、列表检索、Agent/工具绑定、UI 交互与中断语义。本次未调查 CLI 交互模式细节、gateway 消息平台接入、cron/kanban/插件体系、Web 端。运行行为（视觉效果、时序、性能）以静态推断标注，未验证。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手。桌面端不运行 agent，而是自 spawn 一个无头 `hermes serve` 后端进程，renderer 通过 WebSocket 发起 `prompt.submit` 等 JSON-RPC 调用，后端在独立线程运行 `AIAgent.run_conversation`，把增量文本以 `message.delta`、终态以 `message.complete` 事件推回 UI。

关键分界：

- **后端是唯一真相源**。会话、消息全部落在 profile 作用域下单一 SQLite（`state.db`）；每会话 JSONL 消息日志已在 spec 002 移除（`gateway/session.py:3383-3385`）。桌面端所有会话原子只是后端真相的缓存，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的更新原则，该原则逐条对应 `apps/desktop/AGENTS.md`。
- **身份有两层**。进程内 UI 句柄 `sid`（8 位 hex，`methods_session.py:16`）与持久化 `session_key`（`YYYYMMDD_HHMMSS_uuid6`，响应里叫 `stored_session_id`，`methods_session.py:131`）。压缩轮转生成新 `session_key`，通过 `parent_session_id` + `end_reason='compression'` 连成轮转链；“跨轮转不变标识”不存在独立列，而是 `list_sessions_rich` 派生的只读字段 `_lineage_root_id`（`hermes_state.py:6150`），桌面端 pin、路由匹配都基于它（`session.ts:243-252`）。
- **每条消息同时是历史里的事件，也是数据库里的行**。关系表一行一条消息，`active`/`compacted` 分别表示软删与压缩归档；落盘用“单事务批量 + 内存 marker 去重”的原子配对契约（`run_agent.py:2257-2281`）。崩溃中途不写库，痕迹只存在于 `turn_marker.py` 的中断标记文件，恢复会话时按标记自动重放。
- **子代理是真实会话**。`delegate_task` 创建占 DB 行的子会话（`source='subagent'`、`model_config._delegate_from` 标记），继承同一套创建、持久化语义，删除时沿标记级联。

主链路：composer → `prompt.submit`（WS）→ `methods_prompt.py` 校验/截断/busy 门控 → `_run_prompt_submit`（记录 turn marker、注册 `_stream` 回调、启动 run 线程，`server.py:9352`）→ `agent.run_conversation`（`conversation_loop.py:1233`，`build_turn_context` 组装上下文、循环调用 Provider，每 token 增量经 `_stream` 回发）→ `finalize_turn` 持久化 → `message.complete`（含 status/text/usage）。桌面端 delta 进入自适应节流队列（33ms 起、上限 250ms），complete 后合并终态并触发会话列表刷新（300ms 合并）。

## 系统边界与总体调用链

### 三界面一核心

| 界面 | 进程模型 | 与后端传输 |
|---|---|---|
| 桌面端 Electron | renderer 进程 → WebSocket → 后端 | JSON-RPC over WS（`apps/desktop/src/hermes.ts` + `apps/shared`） |
| TUI（`hermes --tui`，Node/Ink） | Node 前端进程 → stdio → 后端 | 换行分隔 JSON-RPC over stdio |
| gateway / CLI | 同进程 | 直接调用 |

三者的后端是同一个 `tui_gateway/server.py` + `AIAgent` 核心。桌面端 spawn 参数为 `['serve','--host','127.0.0.1','--port','0']`（`electron/backend-command.ts:18-22`）；`backendSupportsServe()` 先读 `dashboard.py` 源码探测、失败再 `serve --help` 探针（`electron/main.ts:1893-1948`），旧 runtime 回退为 `dashboard --no-open`（`main.ts:1953-1955`）。`HERMES_SERVE_HEADLESS=1` 由 headless 分支设置（`hermes_cli/main.py:10402-10405`），`mount_spa()` 据此只挂 JSON-RPC/WS/API 面（`hermes_cli/web_server.py:16054`）。

### 一次发送的事件序列

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

### 桌面连接生命周期

- `JsonRpcGatewayClient`（`apps/shared/src/json-rpc-gateway.ts:72-429`）：请求按 `frame.id` 匹配 pending Map，默认超时 120s；事件帧按 `params.type` 分发。`HermesGateway` 子类把超时改为 30s（`hermes.ts:229-239`）。
- `resolveGatewayWsUrl`（`websocket-url.ts:39-94`）：OAuth 模式每次拨号重新铸造一次性 ticket。
- 重连（`use-gateway-boot.ts`）：全抖动指数退避，300ms 基、15s 上限；连续失败 45s 后升级为可恢复错误覆盖层；power/online/visibilitychange 触发立即重连。重连成功后丢弃过期 runtime id（`resetTileRuntimeBindings`），再 `refreshSessions` 重新同步。请求层自带按需重连与失败重放（`use-gateway-request.ts:48-145`）。
- 多 profile 场景每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41`）。

### 状态权威分层

- 后端权威：`state.db` 中的会话、消息、用量、标题、pin 等持久字段。
- 桌面端权威：原生/OS 性、窗口、流式渲染缓冲、发送前的乐观向量。
- 两者以事件流同步；桌面端把后端事件投影进本地状态，不做本地合成。

## 1. 会话与消息数据模型

### 会话（Session）

`sessions` 表（`hermes_state_common.py:207-263`，`SCHEMA_VERSION=25`）核心字段：

- `id` 主键即持久 `session_key`；`source`（`cli`/`tui`/`telegram`/`subagent`…）；`parent_session_id` 外键，是血缘/轮转链的唯一关联字段（`:261`）；`display_name`、`title`、`started_at/ended_at/end_reason`。
- `model_config` JSON，内含 `_branched_from`/`_delegate_from` 标记；`system_prompt`/`system_prompt_hash`（v25 起提示词去重到 `system_prompts` 表）。
- `archived`/`pinned` 软状态；`message_count`/`tool_call_count`/token 用量聚合；`compression_failure_*` 压缩失败冷却字段；`cwd`/`git_branch`/`git_repo_root`。

会话 ID 生成统一为时间戳 + 6 位随机 hex（`agent_init.py:1497-1499`、`conversation_compression.py:3265-3268`）；gateway 消息平台用 8 位 hex（`gateway/session.py:2558, 2902`）。TUI 网关另有一套进程内句柄 `sid = uuid.uuid4().hex[:8]`（`methods_session.py:16`），返回给前端的是它，DB 行主键是 `stored_session_id`。

子会话按来源区分（`hermes_state_common.py:85-114`）：

- 分支子会话：`_branched_from` 标记，或旧式父 `end_reason='branched'` 启发式；
- 压缩续链：父 `end_reason='compression'`；
- 子代理：`_delegate_from` 标记（可级联删除）。

链遍历工具：`get_compression_lineage`（`hermes_state.py:7951`）、`get_compression_tip`（`:5719`，只沿 compression 边）、`resolve_resume_session_id`（`:7176`）、`_session_lineage_root_to_tip`（`:7570`，上限 100 层）。

### 消息行（ChatMessage / SessionMessage）

后端 `messages` 表一行一条消息（`hermes_state_common.py:265-289`）：

- `role`（user/assistant/tool）、`content`、`tool_call_id`/`tool_calls`（JSON 数组）/`tool_name`/`effect_disposition`；
- `reasoning`/`reasoning_content`/`reasoning_details`、`codex_*`（JSON）；多模态 content 经 `_encode_content` JSON 编码（`hermes_state.py:6174-6208`）；
- `timestamp`、`finish_reason`、`token_count`；`platform_message_id`（网关平台侧 ID）；
- 状态：`active`（0 = rewind/undo 软删或压缩归档）、`compacted`（压缩归档，仍可搜索）、`observed`；`display_kind`/`display_metadata`（如 `model_switch` 时间线条目、`hidden`）；
- `api_content`：发给 API 的字节保真 sidecar，恢复时原样返回（`_rows_to_conversation:7367`）。

索引：`idx_messages_session(session_id, timestamp)`、assistant 且 tool_calls 非空的专用索引（`:366-367`）。工具结果与 assistant 调用靠 `tool_call_id` 关联，无独立子表。附件无表：图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成 `[screenshot]`（`run_agent.py:2206-2215`）。

桌面端模型 `ChatMessage`（`apps/desktop/src/lib/chat-messages.ts:13-32`）：`id`、`role`、`parts`（assistant-ui part 数组：text/reasoning/tool-call/图片）、`timestamp`、`pending`、`error`、`branchGroupId`、`hidden`、`interim`、`attachmentRefs`、`rowId`（对应后端 durable `messages.id`）、`reactions`。reasoning 是 part 类型而非顶层字段（`:132-134`）；模型名不在消息上，在 per-session runtime state。后端投影 `SessionMessage`（`types/hermes.ts:538-569`）经 `toChatMessages` 转为渲染模型（`:912-1099`：工具行折叠、`display_kind` 转 system 行、`@image:` 行提取回 attachmentRefs）。

## 2. 会话生命周期与持久化

### 创建与惰性落行

DB 行是惰性创建的：`AIAgent._ensure_db_session` 在首次 turn 时 INSERT-OR-IGNORE（`run_agent.py:621-666`）；TUI 侧 `_ensure_session_db_row` 也在首次 prompt 时落行，废弃草稿不留行（`server.py:2601-2730`）。`SessionDB.create_session` → `_insert_session_row`（`hermes_state.py:3098, 2931`），ON CONFLICT 时从父行继承 cwd/git/profile（`:3033-3092`）。

### resume / close / save

- `session.resume`（`methods_session.py:306-690`）：先 `resolve_resume_session_id` 沿压缩链跳到活 tip，`reopen_session` 清 `ended_at/end_reason`（`hermes_state.py:3609`）；`get_resume_conversations` 一次 SELECT 出两份投影——模型喂入用修复交替版、显示用原样版（`hermes_state.py:7464`；`methods_session.py:503-509`），`sanitize_replay_history` 去掉悬空 tool 尾巴（`:518`）。
- `session.close`（`methods_session.py:2660-2669`）→ `_finalize_session`（`server.py:655`）：flush 未写消息（`:691-697`，明确不带 `conversation_history` 调 `_persist_session`，避免全部消息按身份视为已持久化而跳过）、调 `on_session_end` hook；`end_session` 只标记 `ended_at/end_reason`，first-reason-wins（`hermes_state.py:3591-3607`），不删数据。
- `session.save` 不写 DB，导出 JSON 到 `~/.hermes/sessions/saved/`（`methods_session.py:2588-2657`）。

### 删除与归档

- `session.delete`（`methods_session.py:887-934`）：拒绝删除进程内活跃会话（错误 4023）；`delete_session` 硬删除 messages + sessions 行（`hermes_state.py:8052-8109`），delegate 子代理级联删（`:8092`），分支/压缩子会话则 `parent_session_id → NULL` 孤立保留（`:8094-8098`）；连带清理磁盘转录文件（`:8009-8033`）。
- 归档与删除并存：`archived=1` 软隐藏（默认列表不显示、消息保留），按压缩整链递归翻转（`set_session_archived`，`hermes_state.py:5465-5513`）；无回收站，硬删除不可恢复。

### 落盘与崩溃安全

- `_DB_PERSISTED_MARKER = "_db_persisted"`（`run_agent.py:279`）：内存消息 dict 上的去重标记（取代 `id(msg)` 集合，防 CPython 地址复用），`_` 前缀保证不上 API 线。
- `_flush_messages_to_session_db_unlocked`（`run_agent.py:1999-2281`）：收集本轮新消息 → 单事务 `append_messages_batch`（`:2257-2264`）→ 成功才盖章；失败不盖章、清空扫描前缀，下轮全量重扫（`:2277-2281`）。`append_messages_batch` 按 500 行分块事务（`hermes_state.py:6454`）。压缩轮转后 flush 基线重置（`conversation_compression.py:3323-3329`）。
- 工具执行增量落库：`_flush_session_db_after_tool_progress` 每批工具结果后立即 flush（`tool_executor.py:152-173`），应对工具杀死进程的场景。
- 崩溃痕迹：`turn_marker.py` 写 `~/.hermes/desktop/interrupted_turns.json`（`record_turn_start:97`，上限 32 条/24h/64KB；`clear_turn_marker:124` 在任何“客户端已见到结果”的结局清）。`session.resume` 时 `_maybe_schedule_auto_continue` 按标记自动重跑（`server.py:7241-7322`），attempts 计数防崩溃循环。

### 标题

`title_generator.py`：首轮完成后异步生成（`maybe_auto_title:356-402`，后台 daemon 线程，要求 3-7 词同语言），`set_auto_title_if_empty` 原子写、手动 `/title` 抢先则不覆盖；唯一索引冲突时 `get_next_title_in_lineage` 加 `#N` 后缀（`:226-233`）。TUI 触发点仅在 `status=="complete"` 且文本非空（`server.py:9952-9990`）。手动 `session.title` RPC 直写（`methods_session.py:937-1018`）。

## 3. 发送、流式更新与中断

### prompt.submit 参数与处理

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

### _run_prompt_submit

`server.py:9352-10171`：

1. `agent.clear_interrupt()`（:9380-9385，每轮开头的清中断语义）；
2. `_emit("message.start", sid)`，payload 为空（:9386）；
3. run 线程闭包：`record_turn_start` 写崩溃标记（:9393-9412）；
4. `@file:`/`@context` 引用预处理（被拒发 `error` 事件，:9460-9489）；图片路由 `decide_image_input_mode`（:9496-9546）；
5. `_stream` delta 回调（:9614-9622）：`_append_inflight_delta` 维护 resume 快照（:7100-7110）→ payload `{text, rendered?}` → TTS 队列 → `_emit("message.delta")`；
6. run_kwargs：`conversation_history`、`stream_callback=_stream`、`persist_user_message`、`task_id=session_key`（:9640-9662）；
7. `agent.run_conversation` 同步阻塞（:9662）；
8. history 替换带 version 防抖：版本未变直接替换、仅 model-switch marker 时合并、真 desync 不写并打 warning（:9729-9788）；
9. 压缩轮转后 `_sync_session_key_after_compress` 重锚 session_key（:9796-9798，实现 :4750-4837：会话配额租约迁移、yolo 状态迁移）；
10. status 三态：`interrupted` / `error` / `complete`（:9800-9805）；
11. `_emit("message.complete", payload)`：`{text, usage, status, reasoning?, warning?, billing?, rendered?}`（:9834-9870）；error 终帧统一走 `_emit_terminal_turn_error`（:7593-7626，`recoverable: true` 并保留可重放快照 `_fail_inflight_turn` :7140-7166）；
12. finally：`trim_memory`、TTS sentinel、`running=False`、settle 事件（:10045-10104）。

### run_conversation 主循环

`conversation_loop.py:1233`（本轮已从 `run_agent.py` 抽出）：

- `build_turn_context`（:1310-1331，见 §4）；
- 主循环 `while (api_call_count < max_iterations and budget.remaining > 0)`（:1415）：每轮顶部 interrupt 检查（:1430-1435）→ budget 消耗 → `/steer` 注入最后一个 tool 结果（:1498-1535）→ `api_messages` 构建（剥 sidecar 字段、当前轮 user 消息注入记忆 sidecar、历史消息重放 `api_content`，:1587-1692）→ system 前置（:1709-1713）→ prompt-cache 计划（:1854-1870）→ pre-API 压缩压力闸（:1940-2100）→ `_use_streaming` 判定（:2348-2381）→ `_perform_api_call`（:2383-2416，`chat_completion_helpers.py:2528+`，每 token 调 `agent._stream_callback`，:3281-3283）；
- 结束 `finalize_turn`（`turn_finalizer.py:69-756`）：中断时 `close_interrupted_tool_sequence`（:289-291）、尾部 assistant 补齐保证“有 final_response 必有 assistant 行”（:308-347）、micro-compaction（:364-408）、`_persist_session`（:410）、transform/post_llm_call hooks（:543-584）、result dict（:632-665，含 `final_response/messages/interrupted/error/model/tokens`）、终局 `clear_interrupt`（:693）。

### 中断

- 服务端检查点：主循环顶部（:1430-1435）、重试 backoff 等待（:2709-2732）、空响应重试（:6780-6795）等；流式 API 入口抛 `InterruptedError`（`chat_completion_helpers.py:2544`）。
- `interrupt()`（`run_agent.py:3024-3157`）：置 `_interrupt_requested`、硬取消走压缩 commit fence、向执行线程/工具 worker/子代理传播。
- `clear_interrupt(preserve_redirect=False)`（`run_agent.py:3170-3223`）：`preserve_redirect=True` 时仅当存在 `_pending_redirect` 才清；redirect 竞争与终局调用点见 `conversation_loop.py:2468/2718/3495/4272` 与 `turn_finalizer.py:693`。
- `redirect()`（`run_agent.py:3261-3351`）：只打断 model request，不扩散到工具/子代理。
- 服务端 `session.interrupt`（`methods_session.py:2824-2895`）：`request_hard_interrupt` + `resolve_gateway_approval(deny, resolve_all=True)` 清审批。
- 桌面端没有 `interruptResponse`（全仓库 grep 零命中）：`cancelRun` 先在本地定稿（`finalizeInterruptedMessages`，`rewind.ts:95-99`）再调 `session.interrupt` RPC；此后本地 `interrupted` 状态使迟到流事件在三处拒收（`index.ts:98-100, 547-557`、`gateway-event.ts`），complete 的 interrupted 分支只清 busy 保留部分文本。

## 4. 上下文构建、截断与压缩

### build_turn_context

`agent/turn_context.py:337-1275`，连续约 30 个动作，按功能分组：

1. 恢复轮转会话：`recover_rotated_compression_session`（:370-372，若会话已被压缩轮转则取回 child 历史）；
2. 轮间 MCP 工具刷新（:418-434）；`agent._stream_callback = stream_callback` 注册（:443-462）；
3. `messages = list(conversation_history)` 拷贝（:514）；追加本轮 `user_msg` 并记 `current_turn_user_idx`（:564-577）；
4. 系统提示词：缓存为空时 `restore_or_build_system_prompt`（:622-626；DB 恢复 → `_stored_prompt_matches_runtime` 校验 → 命中复用，否则重建并 `update_system_prompt` 持久化，`conversation_loop.py:475-604`）；
5. DB session 行（:639-659，在压缩之前，防 NULL system_prompt）；
6. idle 压缩（:661-738，见下）；
7. preflight 压缩（:740-1044，见下）；
8. 压缩后重锚 user idx（:1046-1057）；
9. `pre_llm_call` 插件钩子（:1059-1111）；gateway 必达注记消费（:1119-1134）；
10. 中断状态重闩（:1142-1153）；`_memory_manager.on_turn_start`（:1156-1161）；
11. 外部记忆 `prefetch_all`（:1163-1174）；
12. `api_content` sidecar 戳（:1193-1230，`compose_user_api_content` :53-85 = 记忆块 + 插件上下文追加到 API 副本）；
13. crash 持久化：`_ensure_db_session` + `_persist_session`（:1239-1260，用户行一次写入）。

### 系统提示词组装

`build_system_prompt_parts`（`agent/system_prompt.py:152-558`）产出三档 dict：

- `stable`（跨会话稳定）：SOUL/身份、task-completion、parallel-tool-call 指导、工具族指导、tool_use_enforcement、env hints 等；
- `context`（cwd 相关）：coding workspace、profile 提示、平台 hint、调用方 `system_message`、上下文文件（`build_context_files_prompt`，:480-496）；
- `volatile`（最易变）：skills index、内置记忆块（`_memory_store.format_for_system_prompt("memory")`，:515-519）、USER.md、外部记忆 provider 块、时间戳行（日期级粒度保字节稳定）。

`build_system_prompt` 拼接并缓存 `_cached_system_prompt`（:561-587）；续会话从 DB 恢复（`conversation_loop.py:502-541`）；压缩后 `invalidate_system_prompt` 置空并重载记忆磁盘（:590-599）。

记忆进上下文的两个通道：内置 MemoryStore 进 volatile 系统提示词（:515-524）；外部 provider 经 `prefetch_all` → `compose_user_api_content` → `api_content` sidecar 注入当前 user 消息（:1163-1230，`memory_manager.py:525-545`），轮后 `sync_all` 写回（`turn_finalizer.py:707-712`）。

### 截断与压缩

- 无 token 级截断原语；`should_compress`（`context_compressor.py:2588-2634`）：`tokens >= threshold_tokens` 且未被 block；block 原因为压缩失败冷却（`_summary_failure_cooldown_until`）或连续两次无效（`:2648-2656`）。`threshold_tokens` 由 context_length 比例算出（`_compute_threshold_tokens` :2211），可被绝对 cap 覆盖。
- 入口 `_compress_context`（`run_agent.py:7308`）→ `compress_context`（`conversation_compression.py:2129`）。常量模板集中在 `conversation_compression.py`：`PRE_API/PREFLIGHT/IDLE_COMPACTION/CONTEXT_OVERFLOW_BLOCKED`（:125-164）。
- preflight（`turn_context.py:740-1044`）：廉价粗估门（:246-271）→ `should_compress` → 多 pass 重测，至多 `max_compression_attempts`（默认 3）轮；`_compression_warrants_another_preflight_pass` 要求行数减少或 token 降幅 >5%（:229-243）；被 block 时 `_warn_context_overflow_blocked`（:951-962）。
- idle 压缩（:670-738）：墙上时间门（`compression_idle_compact_after_seconds`），与 token 阈值正交，要求 token 数 > floor。
- 轮转（rotation）：`conversation_compression.py:3265-3329`——生成新 session_id → `publish_compression_child` 单事务插入子行（继承 cwd/git/profile/gateway origin）并写压缩后消息、父行 `end_reason='compression'`（`hermes_state.py:3488-3589`）→ `agent.session_id` 切换 → flush 基线重置；失败回滚父会话（:3331-3375）。
- 原地（in-place）：`archive_and_compact` 不轮转 ID，软归档 `active=0, compacted=1`（`hermes_state.py:6938-7010`），同一会话 ID 贯穿一生。
- 压缩后系统提示词不变仍走缓存；`conversation_history_after_compression`（:1846-1882）区分两种模式防重复追加。

## 5. 编辑、重试、续写与分支

- **编辑 = 截断 + 重发**。无 `session.edit`/`message.edit` RPC（检查范围：`tui_gateway` 全部 `@method` 注册表）。编辑经 `prompt.submit` + `truncate_before_user_ordinal`（`rewind.ts:52-92, 223-250`）；服务端先 `db.replace_messages`（单事务 DELETE+重插，压缩已结束会话抛 `CompressionSessionClosedError`，`hermes_state.py:6866, 6900-6905`）再改内存历史。桌面入口 `user-message.tsx:326-356`：点击进入编辑 composer，发送即“interrupt + rewind”。
- **删除**：仅会话级，无单消息删除（检查范围：方法注册表 + 桌面 grep `deleteSession`）。软删原语 `rewind_to_message`（`hermes_state.py:7610`，id≥target 全部 `active=0`）只服务 `/rewind` 命令。
- **重试**：无 `session.retry`，`truncate_after` 概念本仓库不存在（grep 仅命中无关测试名）。三套实现共享“截断到最后一个真实 user turn 后重发”语义，真实 user turn 判定 = `role=="user" and not display_kind`（跳过 model_switch/auto_continue 等时间线条目，`methods_session.py:2406`）：TUI `/retry`（`ui-tui/src/app/slash/commands/core.ts:744-768`：undo → trimLastExchange → 重发）、slash.exec 旧路由（`methods_tools.py:702-740`）、桌面 reload/regenerate（`rewind.ts:113-142` `planReload`）。CLI 对照 `cli.py:8398 retry_last()`。
- **续写**：无 `/continue` 命令、无独立 RPC，就是普通 `prompt.submit` 文本 “continue”（busy 时也只入队，`test_tui_gateway_queue_on_busy.py:106`）。空响应恢复会重放 `assistant("(empty)")`，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`turn_finalizer.py:262-267`）。
- **分支**：`session.branch`（`methods_session.py:2672-2821`）：可选 `count` 截断复制历史 → 新 `session_key` + `model_config={"_branched_from": old_key}` + `parent_session_id=old_key`（:2714-2715）→ `append_messages_batch` 分块复制（chunk 500，保留原 timestamp，:2729-2742）→ 标题 `get_next_title_in_lineage` 生成 `"xxx #2"`（:2699-2704）→ 父会话保持 live；返回 `{session_id, stored_session_id, parent, messages}`。分支种子在首次 prompt 时经 `_persist_branch_seed` 落库（`server.py:2733-2782`）。桌面 fork：live 会话用 `session.branch`，无 live 源时 `session.create` + `parent_session_id` + messages 种子（`use-session-actions/index.ts:1122-1179`）。
- **版本切换**：无 checkpoint 版本 RPC。`session.history` 读含祖先的全量正序历史（`include_ancestors=True`，`methods_session.py:2357-2378`）。`session.steer` 运行中可调：`apply_pending_steer_to_tool_results` 把文本追加到本批次最后一条 tool 消息 content 尾部（不新增消息、不破坏角色交替，`agent_runtime_helpers.py:3921-3982`）；无 tool 可挂时回存，未被消费的变 `result["pending_steer"]` 由调用方作为下一轮用户消息投递（`turn_finalizer.py:683-685`）。`session.redirect` 要求 `agent._supports_active_turn_redirect`（`methods_session.py:3088-3124`）。

## 6. 列表、搜索与定位

### 会话列表

- TUI `session.list`（`methods_session.py:162-211`）：`limit` 默认 200、单页无 offset，超取后 Python 过滤 deny 列表 `{"kanban","tool"}`，按最近活跃排序。
- REST `GET /api/sessions`（`hermes_cli/web_routers/sessions.py:50-163`）：`limit`（默认 20、上限 100）、`offset`、`min_messages`、`archived`、`order=created|recent`、`source(s)` 过滤。
- 底层 `list_sessions_rich`（`hermes_state.py:5790`）：单查询 + 预览子查询（取首个 user 消息，:6016-6022）；`include_pinned` 把被 LIMIT 挤出的置顶会话回填（:5850-5856）；最近活跃按压缩链递归 CTE 取 `effective_last_active` 并在 SQL 层 LIMIT（:5933-6023）；默认排除子代理会话（`_LISTABLE_CHILD_SQL` + `_delegate_from IS NULL`，:5883-5884）。
- 桌面侧栏走 `/api/profiles/sessions/sidebar` 分 profile 分片（`hermes.ts:541-585`），`SIDEBAR_SESSIONS_PAGE_SIZE` + `loadMoreSessions` 翻页（`layout.ts`、`use-session-list-actions.ts:242-268`）。

### 消息列表

- REST `GET /api/sessions/{id}/messages`（`sessions.py:598-630`）：`limit≤500`，正序 `ORDER BY id`（不用 timestamp，防 WSL2/NTP 时钟回拨打乱 tool_call 邻接，`hermes_state.py:7044`）。
- `get_messages_as_conversation`（`hermes_state.py:7265-7319`）：`ORDER BY id` 正序；`include_ancestors` 先走 lineage 链；`repair_alternation` 供 LIVE REPLAY；祖先链同文 user 行去重（`:7593-7604`）。
- 桌面端直播 transcript 不分页：resume 整段返回（`methods_session.py:545`）。

### 搜索

`search_messages`（`hermes_state_search.py:1308` → `_search_messages_impl` :1380）：

- 范围：全 `messages` 表 + FTS 索引，不搜 sessions 表（:1392-1421）；rewind/undo 行（`active=0 AND compacted=0`）默认隐藏，压缩归档行默认可见（:1416-1421）。
- 索引矩阵：`messages_fts`（unicode61）、`messages_fts_cjk`（bigram，绝大多数 CJK 查询）、`messages_fts_trigram`（≥3 CJK 字）、LIKE 兜底（短/混合 CJK 或 role=tool，:1545-1772）。tool 行不进 cjk/trigram 索引（约 90% 字节是机器噪声，:1529-1533）。
- 命中定位：FTS 路径 `snippet(..., '>>>', '<<<', ...)` 前后端标 40 字符（:1486），前端按标记高亮；LIKE 路径 `instr` + 前后 40 字符切片（:1755-1758）。`context` 字段返回命中前后各 1 条（:1874-1939）。结果默认剥掉 `content` 只留 snippet（:1941-1943）。
- 会话 id 搜索：`search_sessions_by_id` exact/prefix/substring 三级评分，`_lineage_root_id` 也参与匹配（:2026-2077）；REST `GET /api/sessions/search` 按压缩链 root 去重（`sessions.py:166-389`，:273-312）。

### 桌面虚拟化

- 侧栏：TanStack `@tanstack/react-virtual`（`package.json:90`；`virtual-session-list.tsx:66-78`，行估计 28px、overscan 12、动态测量）。无 Virtuoso（全仓库零命中）。
- 正文：无 virtualizer，`RENDER_BUDGET=300` 成本单位 + “Show earlier” 翻页 + `content-visibility` 活跃尾部（`LIVE_TAIL_PARTS=40`，`thread/list.tsx:52-64, 171-212`）。

## 7. Agent、模型、工具与附件

- **绑定粒度是会话级**。每次 `session.create/resume/branch` 都 `_make_agent`（`server.py:6293`）+ `_init_session`（`:6480`）；`model_override`/`create_reasoning_override` 为每会话字段（`methods_session.py:50-71, 96-98`）。运行中 `/model` 切换 = `_apply_model_switch`（`server.py:4315`）换 agent 客户端，工具集不中途更换；切换以 `model_switch` display_kind 时间线条目入史（`:3823`），不计入 user 轮计数。
- **子代理**：`delegate_tool.py:1512-1552` `_build_child_agent` 构造 `AIAgent(platform="subagent", session_db=父会话共享句柄, parent_session_id, skip_memory, quiet_mode)`；子代理有独立 session_id（`agent_init.py:1492-1499`），首轮惰性落行时写 `_delegate_from` 标记（`delegate_tool.py:1572-1574`）。列表隐藏是双层：`_LISTABLE_CHILD_SQL` 排除无 `_branched_from` 的子会话（`hermes_state_common.py:103`）+ `_delegate_from IS NULL` 显式排除（`hermes_state.py:5883-5884`），父删除后孤儿化仍隐藏。删除时沿标记递归级联（`_collect_delegate_child_ids`，`hermes_state.py:212-256`，未标记子会话走“孤儿化不删”契约防环）。
- **工具调用的消息表示**：assistant 行带 `tool_calls`（`conversation_loop.py:6042-6043`）；结果经 `make_tool_result_message` 落 `{"role":"tool", tool_call_id, ...}` 行，高风险工具内容包 `<untrusted_tool_result>`（`tool_dispatch_helpers.py:533-576`）；中断/取消工具写 `effect_disposition="none"` 占位（`tool_executor.py:706-727`）。持久化映射见 §1（`run_agent.py:2225-2248`）；UI 投影 `_history_to_messages` 中 tool 行渲染为 `{role:"tool", name, context}`（`server.py:6939, 6971-6979`），assistant 的 tool_calls 不单独成行。
- **附件（桌面端）**：拖放捕获 `useFileDropZone`（`chat/hooks/use-file-drop-zone.ts:33-146`）；`partitionDroppedFiles` 分流（`use-composer-actions.ts:240-256`）——应用内路径（工作区相对）直接转内联 `@file:`/`@line:` ref 插入文本，OS 拖入（本机绝对路径）走附件管线：目录 → `@folder:`、图片 → `attachImagePath`（base64 缩略图，:404-435）、文件 → `@file:` 相对 ref（:382-402）。提交时 `syncAttachmentsForSubmit` → `uploadComposerAttachment`（`use-prompt-actions/index.ts:298-356, :99-183`）：跨文件系统走 `file.attach`（data_url）/`image.attach_bytes`（base64），否则共享本地路径。`[[Image N]]` 指引本次未找到（全仓库 grep 零命中），图片指引是 `@image:<path>` 指令行；`input.detect_drop` 只存在于 `tui_gateway/methods_prompt.py:673-717`，仅 Ink TUI 调用（`ui-tui/src/app/useComposerState.ts:262`），桌面 renderer 走 file/image attach RPC。

## 8. 核心 UI 交互

- **状态原子**（`apps/desktop/src/store/session.ts`）：`$sessions`（:422）、`$messages`（:468，当前视图镜像）、`$activeSessionId`/`$selectedStoredSessionId`（:454-455）、`$activeSessionStoredIdRotation`（:467）、`$busy`/`$awaitingResponse`（:479-480）。per-session 真实状态在 `sessionStateByRuntimeIdRef`（`use-session-state-cache.ts:84`），经 `syncSessionStateToView` 发布（:210-267）。
- **合并而非覆盖**：`mergeSessionPage` 保留 working/pinned/刚 settle 行，按 `_lineage_root_id` 去重防压缩轮转后双行（`session.ts:334-381`）；`sessionsToKeep` 定义保留集（`use-session-list-actions.ts:49-67`）；刷新结果签名门控保持引用同一（:200-204）。
- **先乐观后诚实**：`seedOptimistic` 先插用户气泡（`submit.ts:338-370`）、失败路径回滚并追加错误气泡（:696-716）；rewind/edit 失败回滚完整历史（`use-prompt-actions/index.ts:855-870, 920-927`）。
- **拒绝乱序回写**：请求代际 token 单调递增、过期响应丢弃（`use-session-list-actions.ts:142-143, 181`）；视图发布只接受当前 active 会话 + rAF 合并、flush 前再验 sessionId（`use-session-state-cache.ts:166-168, 221-223`）。
- **发送路径**：`submitText`（`use-prompt-actions/index.ts:541-558`）→ `useSubmitPrompt`（`submit.ts:112-747`）：`sanitizeComposerInput`、busy 门控（:163-170）、storedId/runtimeId 配对校验（:200-234）、session 切换 drift 守卫（:270-287）、无 runtime 时路由 resume（:436-528）或 `createBackendSessionForSend`（:530-584）、`prompt.submit` 带 1800s 超时（:624-626，turn 完成靠流事件而非 RPC ACK）、`session not found`/超时 → resume 后重试一次（:627-669）。
- **流式节流**：`queueDelta` 按会话累加（`index.ts:331-343`）→ `scheduleDeltaFlush` 总是 setTimeout 而非 rAF（防后台窗口 rAF 挂起），间隔 `max(33ms, 3×上次 flush 实测成本)` 上限 250ms（:235-329；`STREAM_DELTA_FLUSH_MS=33`/`MAX_STREAM_FLUSH_GAP_MS=250`，`utils.ts:67, 73`）。flush 触发点：message.start/interim、tool.start/progress/complete、moa.*、review.summary、message.complete 及卸载/可见性事件。
- **complete 合并**：`completeAssistantMessage`（`index.ts:538-704`）→ `mergeFinalAssistantText` 删除所有流式 text part、以权威 final 重写，保留 reasoning（除非被 final 完全覆盖，`chat-messages.ts:241-266`）；error 帧 `partial` 时保留流式文本（:567）；interim 气泡原位结算防双泡（:603-654）；结束后 `scheduleSessionsRefresh` 300ms 合并（:151-173, 686）+ 按需 `hydrateFromStoredSession` 兜底回填（:692-694，压缩轮转后跳过）。
- **压缩轮转的 UI 反馈**：`ActiveSessionStoredIdRotation` 在发布时发现 storedSessionId 变化且 runtime 为 active 才发（`session-states.ts:137-148`；`use-session-state-cache.ts:118-129` 双通道），路由跟随消费后清空（`use-session-actions/index.ts:236`）；`status.update kind=compacting/compacted` 驱动 `$sessionCompacting`（`gateway-event.ts:1093-1098`）。
- **pin**：`sessionPinId = session._lineage_root_id ?? session.id`（`session.ts:243-244`，压缩轮转后 pin 仍存活），持久化到 localStorage（`layout.ts:75`），后端镜像 `PATCH /api/sessions/{id}`，`session-pin-sync.ts` 双向同步（push 先行带围栏防旧页回滚，pull 以后端为权威，boot 时重断言全量）。

## 9. 设计取舍与已确认边界

- **惰性 DB 行**：首次真实 turn 才落行，空草稿不留痕；显式 `/title` 属明确意图，会现建行。
- **单事务批量落盘 + marker 去重**：一轮消息一次 `BEGIN IMMEDIATE/COMMIT`，失败不盖章、下轮全量重扫；`_finalize_session` 的关闭 flush 不带 `conversation_history`，防止“全部消息按身份视为已持久化”的丢尾。
- **轮转 vs 原地压缩**：轮转生成新 session_id 并连链（推荐路径），原地压缩同 ID 软归档；两者都以 `active=0/compacted=1` 保留旧行，压缩归档行仍可搜索。
- **双 ID 边界**：`sid` 进程内、`session_key` 持久；跨轮转稳定性由派生 `_lineage_root_id` 提供，桌面端把 pin/草稿作用域/路由匹配都键在 root 上。
- **编辑 = 截断重发**：无消息级原地编辑与单消息删除（本次未找到，检查范围见 §5）；软删只服务 `/rewind`。
- **steer 不新增消息**：修正文本注入 tool 结果尾部，避免破坏角色交替。
- **崩溃恢复靠标记文件**：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹，resume 时自动重放且 attempts 防循环。
- **FTS 排除 tool 行**：cjk/trigram 索引明确跳过 `role='tool'`（约 90% 字节为机器噪声），tool 内容走 LIKE 兜底。
- **JSONL 消息日志已移除**：`state.db` 是唯一规范存储；残余 JSONL（trajectory、moa-trace、spawn 树）均非消息主存储。

## 10. 未验证事项

- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- `display.busy_input_mode` 各模式（steer/redirect/queue）在真实 provider 上的行为未验证。
- FTS 实际线上布局、触发重建与 trigram 命中效果未验证。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- REST 路由挂载点（`hermes_cli/web_server.py`）未逐行核对。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证。

## 11. 关键源码索引

- 后端入口：`tui_gateway/server.py`——`_emit`/事件帧（:1511-1540）、`_finalize_session`（:655）、`_run_prompt_submit`（:9352）、`_handle_busy_submit`（:7395）、`_sync_session_key_after_compress`（:4750）、`_history_to_messages`（:6939）。
- prompt 方法：`tui_gateway/methods_prompt.py`（:67-333）。
- session 方法：`tui_gateway/methods_session.py`——create（:14）、list（:162）、resume（:306）、delete（:887）、save（:2588）、close（:2660）、branch（:2672）、interrupt（:2824）、history（:2357）、steer（:3055）。
- 上下文构建：`agent/turn_context.py` `build_turn_context`（:337）。
- 主循环：`agent/conversation_loop.py` `run_conversation`（:1233）；收尾 `agent/turn_finalizer.py`（:69）。
- 压缩：`agent/context_compressor.py` `should_compress`（:2588）、`agent/conversation_compression.py` `compress_context`（:2129）、`hermes_state.py` `publish_compression_child`（:3488）/`archive_and_compact`（:6938）。
- 系统提示词：`agent/system_prompt.py` `build_system_prompt_parts`（:152）。
- 运行与持久化：`run_agent.py`——`_persist_session`（:1889）、`_flush_messages_to_session_db_unlocked`（:1999）、`interrupt`/`clear_interrupt`/`redirect`（:3024/:3170/:3261）、`_ensure_db_session`（:621）；`hermes_state.py`——`create_session`（:3098）、`append_messages_batch`（:6454）、`replace_messages`（:6866）、`rewind_to_message`（:7610）、`get_messages_as_conversation`（:7265）、`list_sessions_rich`（:5790）、`get_resume_conversations`（:7464）。
- Schema：`hermes_state_common.py`——`sessions`（:207）、`messages`（:265）、FTS（:415-534）、子会话判定（:85-114）。
- 搜索：`hermes_state_search.py` `search_messages`（:1308）、`search_sessions_by_id`（:2026）。
- 崩溃标记：`tui_gateway/turn_marker.py`。
- 子代理：`tools/delegate_tool.py` `_build_child_agent`（:1512）。
- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :229、listSessions :373）；`store/session.ts`（mergeSessionPage :334、sessionPinId :243）；`use-message-stream/index.ts`（flushQueuedDeltas :201、completeAssistantMessage :538）、`gateway-event.ts`；`use-prompt-actions/submit.ts`（:112）、`rewind.ts`；`lib/chat-messages.ts`（ChatMessage :13、mergeFinalAssistantText :241）；`electron/backend-command.ts`（:18）；`types/hermes.ts`（SessionMessage :538）；`store/gateway.ts`（多 profile socket :30）。
