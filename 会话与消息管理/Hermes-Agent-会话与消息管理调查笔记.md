# Hermes Agent 会话与消息管理调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（git 仓库）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：直接阅读源码（Python Agent 会话运行时、`hermes_state` 兄弟模块、SQLite 存储、JSON-RPC 契约、桌面端与 TUI 前端实现），符号按当前快照逐一复核；行号只在复核过的位置给出，其余用文件加符号定位；行为类结论区分源码事实与静态推断
>
> 调查范围：会话、消息与分支的数据模型、事实源与持久化、单写者与回合租约、生命周期（创建/切换/归档/删除/恢复）、编辑重试与分支语义、列表分页搜索、一致性并发、迁移导入导出与外部对象绑定粒度。请求执行（上下文拼装、流式、压缩触发与中断）与界面工作流分别进入对话请求与上下文、Chat UI 类目；消息渲染器类目记录内容渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **后端是唯一真相源**。会话、消息全部落在 profile 作用域下单一 SQLite（`state.db`），schema 版本 32。桌面端所有会话原子只是后端真相的缓存，遵循"合并而非覆盖、先乐观后诚实、拒绝乱序回写"的更新原则（`apps/desktop/AGENTS.md`）。
- **写入者已收敛为单写者**：经典 CLI 不再直接持有写句柄。`hermes_cli/gateway_session_store.py` 把 `HermesCLI._session_db` 换成"只读 `state.db` 读取器 + gateway 动词"：读走只读连接，写走 `session.create`/`session.resume`/`session.mutate`/`session.detach`，尚未上 gateway 的写入直接抛 `GatewayClientError`（模块 docstring）。
- **身份有两层**：进程内 UI 句柄 `sid`（8 位 hex，`tui_gateway/methods_session.py`）与持久化 `session_key`（时间戳 + 6 位 hex，`tui_gateway/session_registry.py` 的 `_new_session_key`，响应里叫 `stored_session_id`）；压缩轮转生成新 key，经 `parent_session_id` + `end_reason='compression'` 连链，跨轮转稳定标识是派生字段 `_lineage_root_id`。
- **子会话有四类**：分支（`_branched_from`）、压缩续链（父 `end_reason='compression'`）、子代理（`_delegate_from`）、以及本快照新增的重置（`_reset_from`）。重置在列表里作为独立会话可见，但仍保留 `parent_session_id` 以维持血缘（`hermes_state_common.py:228-247`）。
- **每条消息同时是历史里的事件与数据库里的行**。关系表一行一条消息，`active`/`compacted` 分别表示软删与压缩归档；落盘走"单事务批量 + 内存 marker 去重"，崩溃中途只在 `desktop/interrupted_turns.json` 留标记，恢复会话时按标记自动重放。
- **写区段按 session_id 串行**：`gateway/turn_lease.py` 的回合租约把"[载入历史 → 运行 → flush]"整段锁在解析后的 session_id 上，路由键多对一（第二次 /resume、委派钉住、topic tip 走查）时防止两份 flush 交叉；等待超时 fail-closed。
- **惰性落行**：DB 行首次真实 turn 才创建，空草稿不留行；子代理首轮落行时写 `_delegate_from` 标记，删除时沿标记级联，分支/压缩子会话则"孤儿化不删"。
- **标题两段式 + 带来源**：首个 turn 的 prologue 内派生即时标题（无模型调用），随后后台线程用小模型升级；来源按 derived < llm < user 排序做单事务比较-交换，用户 `/title` 永不被覆盖，压缩轮转携带标题不变。

## 系统边界与数据主链

状态权威分层：`state.db` 持有会话、消息、用量、标题、pin 等持久字段；桌面端持有原生窗口、流式渲染缓冲与发送前的乐观向量；两者以事件流同步，桌面端只投影不本地合成。

数据主链：

```text
首次 prompt（_ensure_db_session / _ensure_session_db_row，惰性落行）
  -> 回合租约获取（gateway/turn_lease.py，按解析后的 session_id）
  -> turn 执行（执行语义在对话请求与上下文笔记）
  -> _persist_session / _flush_messages_to_session_db_unlocked（单事务批量 + marker 去重）
  -> append_messages_batch（hermes_state_messages.py，支持分块事务）
  -> session.resume / session.history / session.list 等 RPC 读取
  -> 压缩轮转生成新 session_key（parent_session_id + end_reason='compression' 连链）
  -> 崩溃时中断标记 desktop/interrupted_turns.json，resume 时自动重放
```

边界：上下文拼装、Provider 调用、流式事件、压缩触发与中断属于对话请求与上下文（`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`）；会话侧栏、消息操作等界面工作流属于 Chat UI；消息内容与列表渲染属于消息渲染器类目，本笔记只记录数据形状与数据分页接口。

## 1. 会话、消息与分支数据模型

### 1.1 会话（Session）

`sessions` 表 DDL 在 `hermes_state_common.py:461`，`SCHEMA_VERSION = 32`（`hermes_state_common.py:289`）。核心字段：

- 标识与血缘：`id` 主键即持久 `session_key`；`parent_session_id` 是血缘/轮转链的唯一关联字段；
- 入口与生命周期：`source`（`cli`/`tui`/`telegram`/`subagent`…）、`started_at`/`ended_at`/`end_reason`；
- 标题与配置：`title`/`title_source`、`model_config` JSON（含 `_branched_from`/`_delegate_from`/`_reset_from` 标记）；
- 提示词：`system_prompt`/`system_prompt_hash`，v25 起提示词去重到 `system_prompts` 表（`hermes_state_common.py:456`）；
- 软状态与聚合：`archived`/`pinned`、`message_count`/`tool_call_count`/token 计数、压缩冷却字段、`cwd`/`git_branch`/`git_repo_root`/`last_activity_at`。

会话 ID 生成统一为"时间戳 + 6 位随机 hex"：网关实现 `_new_session_key`（`tui_gateway/session_registry.py:392`），gateway 消息平台用 8 位 hex（`gateway/session.py`）。

TUI/桌面另有进程内句柄 `sid`，返回给前端的是它，DB 行主键是 `stored_session_id`（`tui_gateway/methods_session.py`）。

### 1.2 子会话与轮转链

子会话按来源判定，SQL 片段集中在 `hermes_state_common.py:171-247`：

- 分支子会话：`_branched_from` 标记，或旧式父 `end_reason='branched'` 启发式（`_BRANCH_CHILD_SQL`）；
- 压缩续链：父 `end_reason='compression'`（`_COMPRESSION_CHILD_SQL`）；
- 重置子会话：`_reset_from` 标记，或旧式同 key 回退（`_RESET_CHILD_SQL`），代表一次"从同一会话分出新对话"；
- 子代理：`_delegate_from` 标记，可级联删除（`_ephemeral_child_sql`）。

标记与父 id 绑定：续链会话原样继承 `model_config`，因此指向别行的标记属继承而非 fork（`_LINEAGE_MARKER_SQL` 的 docstring）。列表可见行 = 根 + 分支/重置子会话（`_LISTABLE_CHILD_SQL`），不含子代理与压缩续链。

链遍历工具（实现已迁到兄弟模块）：

- `get_compression_lineage`（`hermes_state_compression.py:916`）：沿压缩链取全链；
- `get_compression_tip`（`:897`）：只沿 compression 边取 tip；
- `resolve_resume_session_id`（`hermes_state_messages.py:1452`）：解析 resume 目标；
- `_session_lineage_root_to_tip`（`hermes_state_sessions.py:1526`）：root→tip 遍历（上限 100 层）。

压缩轮转与原地压缩的对照：

- **轮转**：生成新 session_id → `publish_compression_child`（`hermes_state_compression.py:373`）单事务插入子行（继承 cwd/git/profile/gateway origin、携带标题与压缩后消息）并写压缩后消息、父行 `end_reason='compression'` → 切换 `agent.session_id` → flush 基线重置；
- **原地压缩**：`archive_and_compact`（`hermes_state_messages.py:907`）不轮转 ID，软归档 `active=0, compacted=1`，同一会话 ID 贯穿一生。

压缩的触发与预算语义在对话请求与上下文笔记 §3。

### 1.3 消息行（ChatMessage / SessionMessage）

后端 `messages` 表 DDL 在 `hermes_state_common.py:531`，一行一条消息：

- `role`（user/assistant/tool）、`content`、`tool_call_id`/`tool_calls`（JSON 数组）/`tool_name`/`effect_disposition`；
- `reasoning`/`reasoning_content`/`reasoning_details`、`codex_reasoning_items`/`codex_message_items`；多模态 content 经 `_encode_content` JSON 编码（`hermes_state_messages.py:140`）；
- `timestamp`、`finish_reason`、`token_count`；`platform_message_id`（网关平台侧 ID）；
- 状态：`active`、`compacted`、`observed`；`display_kind`/`display_metadata`（`model_switch`/`personality_switch` 等时间线条目、`hidden`）；
- `api_content`：发给 API 的字节保真 sidecar，恢复时原样返回（`_rows_to_conversation`，`hermes_state_messages.py:1571`）；重建历史时由 `drop_stale_api_content`（`agent/turn_context.py`）丢弃过期 sidecar。

索引：主索引 `idx_messages_session(session_id, timestamp)` 与 `idx_messages_session_id(session_id, id)`、assistant 且 `tool_calls` 非空的专用部分索引、`idx_messages_session_active` 延迟索引段，均在 `hermes_state_common.py` 的索引定义区。

工具结果与 assistant 调用靠 `tool_call_id` 关联，无独立子表。附件无表：图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成占位（`agent/tool_dispatch_helpers.py`）。

桌面端模型 `ChatMessage` 在 `apps/desktop/src/lib/chat-messages/index.ts`（原单文件已拆成目录），字段分身份与角色、parts、状态（pending/error/hidden/interim）、外部引用（attachmentRefs/rowId/reactions）；后端投影 `SessionMessage`（`apps/desktop/src/types/hermes.ts`）经 `toChatMessages` 转为渲染模型。part 渲染细节见消息渲染器笔记。

## 2. 事实源、单写者与持久化

### 2.1 事实源与写者

`state.db` 是唯一规范存储。当前快照的写入路径有三层：

- **Agent 进程内**：`_persist_session` 与 `_flush_messages_to_session_db_unlocked`（`agent/session_persistence.py:509, 548`）直接写 SessionDB；
- **网关单写者**：`hermes_cli/gateway_session_store.py` 用只读 reader 做读取，把写入翻译成 gateway 动词；未覆盖的写入抛 `GatewayClientError`（模块 docstring 与 `delete_session`/`end_session` 等适配方法）；
- **worker 持久化 facade**：`agent/runtime_session_store.py` 明确"显式 worker 持久化入口，从不打开规范 SQLite"，并注明尚未切换现有 cron/child/compute 消费者（模块 docstring）。

原有的每会话 JSON 快照写入器（`sessions.write_json_snapshots` 门控、默认关闭）已不在代码中；JSON 产物只剩调试与观察类（trajectory、moa-trace、spawn 树），不在消息读路径上。`session.save` 仍导出 JSON 到 `~/.hermes/sessions/saved/hermes_conversation_<ts>.json`（`tui_gateway/methods_session.py:2160`）。

`api_content` 是发给 API 的字节保真 sidecar；桌面端各会话原子只是后端真相的缓存投影。

### 2.2 落盘与崩溃安全

- `_DB_PERSISTED_MARKER = "_db_persisted"`（`agent/context_compressor.py:326`）：内存消息 dict 上的去重标记（`_` 前缀保证不上 API 线），取代按对象身份集合去重；压缩路径引用同一常量（`agent/context_compressor_prune.py`）。
- 落盘走 `_flush_messages_to_session_db_unlocked`：收集本轮新消息 → 单事务 `append_messages_batch`（`hermes_state_messages.py:430`，支持 `chunk_rows` 分块事务）→ 成功才盖章；失败不盖章、清空扫描前缀，下轮全量重扫。`_persist_session` 在每处退出路径（完成、错误、关闭）调用它。
- 工具执行增量落库：`_flush_session_db_after_tool_progress`（`agent/tool_executor.py:201`）在多个工具批次点调用，应对工具杀死进程的场景。
- 崩溃痕迹：`tui_gateway/turn_marker.py` 写 `<home>/desktop/interrupted_turns.json`（`_marker_path`），`record_turn_start`（`:124`）写入、`clear_turn_marker`（`:140`）在任何"客户端已见到结果"的结局清除，`session.resume` 的自动续跑读它。标记上限 32 条/24 小时/64KB 提示词，并用跨进程文件锁（`hermes_cli.auth._file_lock`）避免同机多后端互相复活标记；每条标记带写入者 pid 与启动时间，用于区分"标记存在"与"写者已死"（`#94778`）。
- 中途断连的另一层恢复是 `_fail_inflight_turn`（`tui_gateway/session_history.py:447`）保留的可重放快照，经 `session.resume` 的 `inflight` payload 承载，见对话请求笔记 §6。

### 2.3 标题（两段式 + 带来源）

`agent/title_generator.py` 的命名是两段式 + 带来源：

- **即时标题（derived）**：会话首个 turn 的 prologue 内同步执行（`agent/turn_context.py:201` 的 `_maybe_title_session_at_turn_start`，经 `maybe_auto_title`（`agent/title_generator.py:736`）派发），无模型调用、不失败：
  - `apply_instant_title`（`agent/title_generator.py:621`）调 `derive_title`（`:343`）从开场消息取首个有效行、折叠空白、按 `MAX_DERIVED_TITLE_CHARS=48`（`:54`）词边界截断，用户发出首条消息后立即可见；
  - 斜杠命令等控制包装被剥离（`is_titleable_user_message`，`:333`）；
  - 随后 `auto_title_session`（`:642`）在后台线程用小模型升级（约束 JSON `{"title": ...}`）。
- **来源与覆盖**：标题来源按 derived < llm < user 排序，写入是"优先级检查 + 写入"的单事务 compare-and-swap：`set_auto_title`（`hermes_state_titles.py:170`，内部 `_set_session_title` `:83` 与 `_set_session_title_in_transaction` `:94`）只在更高来源时覆盖；用户 `/title` 记 `user` 来源且永不被覆盖；legacy NULL 行按 user 计，自动标题只填空；唯一索引冲突时经 `get_next_title_in_lineage`（`hermes_state_titles.py:222`）加 `#N`。
- **压缩轮转携带标题**：轮转前取父标题，轮转后在新会话行重写同一标题并恢复原 provenance，不再对每个 fork/轮转重编号。
- 桌面/TUI 侧通过 `session.title` 事件即时刷新侧栏；未命名会话由新标题逻辑补名，TTS 模型/脚手架回合不触发命名。

## 3. 创建、切换、归档、删除与恢复

### 3.1 契约与实现分层

JSON-RPC 方法在 `tui_gateway/contracts/sessions.py` 中以声明式契约定义（`method("session.resume" …)` 等，参数与结果各有 schema），实现分散在 `tui_gateway/session_*.py` 兄弟模块：

- `session_registry.py`：会话注册、`_new_session_key`、agent 构建等待；
- `session_workdir.py`：`_ensure_session_db_row`（`:588`）、`_persist_branch_seed`（`:682`）；
- `session_lifecycle.py`：`_finalize_session`（`:430`）等关闭路径；
- `session_compression.py`：`_sync_session_key_after_compress`（`:313`）等轮转衔接；
- `session_history.py`：`_history_to_messages`（`:297`）、`_fail_inflight_turn`（`:447`）；
- `model_switch.py`：`_apply_model_switch`（`:311`）。

`tui_gateway/methods_session.py` 仍是方法实现的主要落点（`session.save` 的 JSON 导出于 `:2160`）。契约由 `scripts/gen_gateway_contracts.py` 生成/校验。

### 3.2 创建与惰性落行

- 后端：`AIAgent._ensure_db_session`（`run_agent.py:315`）在首次 turn 时执行 `create_session`（`hermes_state_sessions.py:416` → `_insert_session_row` `:369`），失败保活下轮重试；
- TUI：`_ensure_session_db_row`（`tui_gateway/session_workdir.py:588`）也在首次 prompt 时落行，废弃草稿不留行。

`create_session` 在 ON CONFLICT 时从父行继承 cwd/git/profile。

### 3.3 resume / close / save

- `session.resume` 的恢复流程：
  1. `resolve_resume_session_id`（`hermes_state_messages.py:1452`）沿压缩链跳到活 tip；
  2. `reopen_session` 清 `ended_at`/`end_reason`（`hermes_state_sessions.py:519`）；
  3. `get_resume_conversations`（`hermes_state_messages.py:1667`）一次 SELECT 出两份投影——模型喂入用修复交替版、显示用原样版，`sanitize_replay_history`（`agent/replay_cleanup.py:147`）去掉悬空 tool 尾巴；
  4. resume 有转录安全上限：`sessions.max_resume_messages`（默认 20,000，0 关闭；`resolved_max_resume_messages` 在 `hermes_state.py:109`），超限抛 `SessionResumeTooLargeError`（`hermes_state.py:117`），错误信息指向导出与 `max_resume_messages` 调参。导出侧另有 `sessions.max_export_messages`（`resolved_max_export_messages`）。
- `session.close` → `_teardown_popped_session` → `_finalize_session`（`tui_gateway/session_lifecycle.py:430`）做三件事：flush 未写消息（明确不带 `conversation_history`，避免全部消息按身份视为已持久化而跳过）、调 `on_session_end` hook、`end_session` 标记 `ended_at`/`end_reason`（first-reason-wins；gateway 来源会话不归 TUI 所有不标记）。全程不删数据。
- `session.save` 不写 DB，导出 JSON 到 `~/.hermes/sessions/saved/`（`tui_gateway/methods_session.py:2160`，含 system prompt）。

### 3.4 删除与归档

- `session.delete` 拒绝删除进程内活跃会话；`delete_session` 硬删除 messages + sessions 行并处理三类关联：delegate 子代理级联删（`_collect_delegate_child_ids`，`hermes_state_sessions.py:193`）、分支/压缩/重置子会话 `parent_session_id → NULL` 孤立保留、连带清理磁盘转录文件。
- 归档与删除并存：`archived=1` 软隐藏（默认列表不显示、消息保留），`set_session_archived`（`hermes_state_sessions.py:953`）按压缩整链递归翻转；无回收站，硬删除不可恢复。
- 空会话清理：`delete_session_if_empty`（`hermes_state_sessions.py:1791`，单事务判空：无消息、无用户标题、无子会话）由 CLI 退出/轮转路径调用；网关侧同语义实现在 `hermes_cli/gateway_session_store.py:337`。

### 3.5 恢复与保留语义

- 崩溃恢复：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹；`session.resume` 时按标记自动重放，attempts 计数防崩溃循环。
- 压缩轮转恢复：resume 沿压缩链跳到活 tip，`get_resume_conversations` 提供模型喂入与显示两份投影；`_lineage_root_id` 提供跨轮转稳定身份（`hermes_state_local.py:381`、`hermes_state_search.py:1432`），桌面端 pin、路由匹配都基于它。
- 保留语义：轮转与原地压缩都以 `active=0`/`compacted=1` 保留旧行，压缩归档行仍可搜索；`end_session` 只标记不删数据；硬删除无回收站。
- `/retry`、编辑/rewind 截断均改为保留归档历史的破坏性改写：`replace_messages` 带 `active_only`/`archive_dropped` 语义（`hermes_state_messages.py:720`），旧轮次不再从消息列表蒸发、但落盘为可搜索归档行。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑 = 截断 + 重发**。无 `session.edit`/`message.edit` RPC（检查范围：`tui_gateway/contracts/sessions.py` 的方法声明与桌面端消息操作代码）。数据变更分三处：桌面入口点开编辑 composer 后发送即"interrupt + rewind"；参数构造带 `truncate_before_user_ordinal`；服务端先 `db.replace_messages`（`hermes_state_messages.py:720`，单事务 DELETE+重插，压缩已结束会话抛 `CompressionSessionClosedError`）再改内存历史并 `history_version += 1`。
- **删除**：仅会话级，无单消息删除（检查范围同上）。软删原语 `rewind_to_message`（`hermes_state_messages.py:1850`，id≥target 全部 `active=0`）只服务 `/rewind` 命令；`session.undo` 是进程内历史截断。
- **重试**：无 `session.retry`（检查范围同上）；三套实现共享"截断到最后一个真实 user turn 后重发"语义，真实 user turn 由 `is_user_originated_turn` 判定（`agent/context_compressor.py:5735`：`role=="user"` 且无 `display_kind`、非压缩摘要/合成轮）。入口有 TUI `/retry` 与 slash、桌面 reload/regenerate、CLI `retry_last()`。
- **续写**：无 `/continue` 命令与独立 RPC，就是普通 `prompt.submit` 文本。空响应恢复会重放空 assistant 消息，持久化前由 `_drop_trailing_empty_response_scaffolding`（`agent/session_persistence.py:530`）删除。
- **分支**：`session.branch`（契约在 `tui_gateway/contracts/sessions.py`）分四步：可选 `count` 截断复制历史 → 建新 `session_key` + `model_config={"_branched_from": old_key}` + `parent_session_id=old_key` → `append_messages_batch` 分块复制（保留原 timestamp）→ 标题经 `get_next_title_in_lineage` 生成 `"xxx #2"`。父会话保持 live，返回 `{session_id, stored_session_id, parent, messages}`。分支种子在首次 prompt 时经 `_persist_branch_seed`（`tui_gateway/session_workdir.py:682`）落库；桌面 fork 在无 live 源时走 `session.create` + `parent_session_id` + messages 种子。
- **版本切换**：无 checkpoint 版本 RPC。相关能力分三类：读取全量历史 `session.history`（`include_ancestors=True`）；运行中干预 `session.steer`/`session.redirect`（不新增持久化对象，执行语义在对话请求与上下文笔记 §7）；撤销 `session.undo`（拒绝 running 中调用，按 `is_user_originated_turn` 找最后一个真实 user turn 截断进程内历史并 `history_version += 1`）。

## 5. 列表、分页、搜索与定位

### 5.1 会话列表

- TUI `session.list`：`limit` 默认 200、单页无 offset，超取后 Python 过滤 deny 列表 `{"kanban","tool"}`，按最近活跃排序。
- REST `GET /api/sessions`（`hermes_cli/web_routers/sessions.py`）支持 `limit`（默认 20、上限 100）、`offset`、`min_messages`、`archived`、`source(s)` 等过滤。
- 底层 `list_sessions_rich`（`hermes_state_sessions.py:1303`）单查询完成：预览取首个 user 消息；`include_pinned` 把被 LIMIT 挤出的置顶会话回填；按压缩链递归 CTE 取 tip 的 `effective_last_active` 并在 SQL 层 LIMIT；压缩链 root 投影到活 tip 做逻辑去重；默认排除子代理与压缩续链会话（`_LISTABLE_CHILD_SQL` + `_delegate_from IS NULL`）。网关侧同语义适配在 `hermes_cli/gateway_session_store.py:448`。
- 桌面侧栏走 `/api/profiles/sessions/sidebar` 分 profile 分片（`apps/desktop/src/hermes.ts` 的 `listAllProfileSessions` 与批量 sidebar 请求，含 recents/cron/messaging 三切片与旧端点兼容回退），`SIDEBAR_SESSIONS_PAGE_SIZE` + `loadMoreSessions` 翻页；侧栏界面工作流与虚拟列表呈现见 Chat UI 笔记 §1。

### 5.2 消息列表

- REST `GET /api/sessions/{id}/messages`：`limit` 上限 500，`order=oldest` 从头翻页、缺省/`latest` 返回最新一页；先 `resolve_session_id` + `resolve_resume_session_id` 沿压缩链解析。
- `get_messages_as_conversation`（`hermes_state_messages.py:1517`）：`ORDER BY id` 正序（不用 timestamp，防 WSL2/NTP 时钟回拨打乱 tool_call 邻接）；`include_ancestors` 先走 lineage 链；`repair_alternation` 供 LIVE REPLAY。
- 桌面端直播 transcript 不分页：resume 整段返回。

### 5.3 搜索

- 范围：全 `messages` 表 + FTS 索引，不搜 sessions 表；rewind/undo 行（`active=0 AND compacted=0`）默认隐藏，压缩归档行默认可见。
- 索引矩阵四路：`messages_fts`（fts5 unicode61 基表）、`messages_fts_cjk`（bigram，绝大多数 CJK 查询）、`messages_fts_trigram`（≥3 CJK 字，经排除 tool 行的视图）、LIKE 兜底（短/混合 CJK 或 role=tool）。tool 行不进 trigram 索引（约 90% 字节是机器噪声）。
- 命中定位：FTS 路径用 `snippet(..., 40)`；LIKE 路径用 `instr` 加前后字符切片；`context` 字段返回命中前后各 1 条；结果默认剥掉 `content` 只留 snippet。
- 入口：`search_messages`（`hermes_state_search.py:1257`）与 `search_sessions_by_id`（`:1432`，exact/prefix/substring 三级评分，`_lineage_root_id` 参与匹配）；REST `GET /api/sessions/search` 按压缩链 root 去重。原生 SQLite 侧另有 `native/fts5_cjk` 扩展包承担 CJK 分词。

### 5.4 列表窗口化边界

列表窗口化、滚动锚定、渲染预算与 `content-visibility` 属于消息渲染器笔记（§3 列表层）；本笔记只记录数据分页接口：REST `limit/offset`、侧栏翻页接口、resume 整段返回。

## 6. 缓存、一致性、多窗口与并发写入

- **回合租约**：`gateway/turn_lease.py` 按解析后的 session_id 串行化"[载入历史 → 运行 → flush]"整段；路由键与转录所有权多对一（`switch_session()` 使 key→id 多对一），租约防两份 flush 在同一条转录上交叉；获取在转录载入前、释放走分发层 `finally`；释放做身份校验；等待超时抛 `TurnLeaseTimeoutError`（fail-closed）；空闲条目按 oldest-first 淘汰，活动租约永不淘汰（上限 512）。
- **单写者**：经典 CLI 的写句柄被替换为"只读 reader + gateway 动词"，写入统一落到 gateway 进程，避免同库双写者。
- **桌面端三原则**：`mergeSessionPage` 保留 working/pinned/刚 settle 行并按 `_lineage_root_id` 去重防压缩轮转后双行；`seedOptimistic` 先插用户气泡、失败回滚并追加错误气泡；`refreshSessionsRequestRef` 请求代际单调递增、过期响应丢弃，视图发布只接受当前 active 会话并在 flush 前复验 sessionId（`apps/desktop/src/store/session.ts`、`use-session-list-actions.ts`、`use-session-state-cache.ts`）。
- **多 profile 同步**：每个活跃 profile 一条独立二级 socket（`apps/desktop/src/store/gateway.ts`）；重连成功后丢弃过期 runtime id（`resetTileRuntimeBindings`，`use-gateway-boot.ts`），再 `refreshSessions` 重新同步。
- **压缩轮转的数据一致性**：轮转后 flush 基线重置，`_sync_session_key_after_compress`（`tui_gateway/session_compression.py:313`）重锚 session_key 并迁移会话配额租约与 yolo 状态；会话持久化失败按类型分类（锁竞争 vs 磁盘满），桌面端可映射"disk full"提示。

## 7. 迁移、导入导出与保留策略

- schema 版本 32（`hermes_state_common.py:289`），v25 起系统提示词去重到 `system_prompts` 表；FTS 存储布局版本独立于 schema（`FTS_STORAGE_VERSION`，见 `hermes_cli/session_recovery.py:21` 的导入与版本比对），legacy DB 在用户执行 `hermes sessions optimize-storage` 前停留在旧布局。25 之后各版本的具体迁移步骤未在本次范围内逐版核对。
- 导出：`session.save` 写 JSON 到 `~/.hermes/sessions/saved/`，不写 DB；CLI 侧有 `hermes sessions export`（md/html，见对话导出与分享笔记）。
- 保留：归档不删数据；硬删除无回收站；`end_session` 只标记；`/retry`/rewind 的截断行落为归档行。
- 导入：`hermes_cli/session_recovery.py` 负责旧库恢复与版本修补（本次未逐行核对）；桌面另有 Claude Code 与 Codex CLI 会话导入，发现器只读各工具本地会话目录，先返回按仓库、时间和标题整理的预览；确认后把外部 turns 归一成 Hermes 消息写入当前 profile 的 SQLite，metadata 保留来源与原会话身份，外部历史被标记为不可信静态内容（`hermes_cli/foreign_sessions.py`、`apps/desktop/src/app/session-import/index.tsx`）。

## 8. Agent、模型、知识库与附件绑定

- **绑定粒度是会话级**：每次创建/恢复/分支会话都构造独立 Agent 并初始化会话状态（`agent/agent_init.py:1096` 的 `_init_session_state`）；`model_override`/`create_reasoning_override` 为每会话字段。
- **运行中 `/model` 切换** = `_apply_model_switch`（`tui_gateway/model_switch.py:311`）换 agent 客户端，工具集不中途更换；切换以 `model_switch` 的 `display_kind` 时间线条目入史，不计入 user 轮计数。
- **子代理**：`_build_child_agent`（`tools/delegate_tool.py:203`）构造独立 `AIAgent`（platform 为 subagent，共享父会话句柄与 `parent_session_id`），子代理有独立 `session_id`，首轮惰性落行时写 `_delegate_from` 标记。列表隐藏是双层：`_LISTABLE_CHILD_SQL` 加 `_delegate_from IS NULL`；删除时沿标记递归级联（`_collect_delegate_child_ids`），未标记子会话走"孤儿化不删"防环。
- **工具调用的消息表示**：持久化上 assistant 行带 `tool_calls`，结果落 `{"role":"tool", tool_call_id, ...}` 行，高风险工具内容包 `<untrusted_tool_result>`（`agent/tool_dispatch_helpers.py`），中断/取消工具写 `effect_disposition="none"` 占位（`agent/tool_executor.py`）；UI 投影里 tool 行渲染为 `{role:"tool", name, context}`（`_history_to_messages`，`tui_gateway/session_history.py:297`），assistant 的 `tool_calls` 不单独成行。
- **附件（数据侧）**：无附件表，图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成占位；桌面拖放/上传管线属于 Chat UI 笔记 §3，提交注入点属于对话请求与上下文笔记 §9。

## 9. 设计取舍与已确认边界

- **惰性 DB 行**：首次真实 turn 才落行，空草稿不留痕；显式 `/title` 属明确意图，会现建行。
- **单事务批量落盘 + marker 去重**：一轮消息一次批量写，失败不盖章、下轮全量重扫；关闭 flush 不带 `conversation_history`，防止"全部消息按身份视为已持久化"的丢尾。
- **单写者 + 回合租约**：把并发写入收敛到一个进程、再按 session_id 串行整段回合，换取转录不被交叉 flush 破坏；代价是租约超时 fail-closed，长回合需要放宽等待。
- **轮转 vs 原地压缩**：轮转生成新 session_id 并连链（推荐路径），原地压缩同 ID 软归档；两者都保留旧行且可搜索。
- **四类子会话**：分支、压缩续链、子代理、重置各有标记与列表可见性；重置使"从同一会话分出新对话"不必伪装成分支。
- **双 ID 边界**：`sid` 进程内、`session_key` 持久；跨轮转稳定性由派生 `_lineage_root_id` 提供。
- **编辑 = 截断重发**：无消息级原地编辑与单消息删除（本次未找到，检查范围见 §4）；软删只服务 `/rewind`；截断重发带归档语义并要求显式确认意图。
- **崩溃恢复靠标记文件**：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹；标记用跨进程文件锁与写入者身份区分,避免多后端互踩。
- **FTS 排除 tool 行**：trigram 索引跳过 `role='tool'` 行，tool 内容走 LIKE 兜底。
- **契约声明化**：`tui_gateway/contracts/*.py` 是方法/事件的单一契约源，由脚本生成校验，实现拆到兄弟模块。

## 10. 当前重连与 profile 归属

桌面/TUI 客户端的 JSON-RPC 连接维护每个会话的事件序号水位；重连后只请求水位之后的事件，并把回放帧交给通常的事件分发路径（`apps/shared/src/json-rpc-gateway.ts`）。桌面端的会话请求同时带有 profile/connection 作用域，跨 profile 的同名 session 不按单独 ID 合并（`apps/desktop/src/api/sessions.ts`）。这改变的是缓存和恢复时的身份判定，不改变 SQLite 是会话与消息事实源的结论。

## 11. 未验证事项

- 行号级锚点只在本次复核过的符号上给出；`hermes_cli/web_routers/sessions.py`、`tui_gateway/methods_session.py` 内部的其余行号与接口细节未逐条重核。
- schema 25 → 32 各版本的迁移步骤、`hermes_cli/session_recovery.py` 的旧库修补路径未逐行核对。
- FTS 实际线上布局、触发重建与 trigram 命中效果未验证；`native/fts5_cjk` 扩展的编译与加载未运行验证。
- 工具执行增量 flush 在工具杀死进程场景、回合租约超时与 rebase 竞态、多后端标记锁的实际行为未运行验证。
- 单写者模式下 `session.mutate`/`detach` 动词的完整覆盖范围未逐项核对（`gateway_session_store.py` 明确"尚未上 gateway 的写入抛错"）。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- Claude Code/Codex 的大批量发现、重复导入和损坏 JSONL 恢复未运行验证。

## 12. 关键源码索引

- Schema：`hermes_state_common.py`——`SCHEMA_VERSION=32`（:289）、`system_prompts`（:456）、`sessions`（:461）、`messages`（:531）、子会话 SQL 片段（:171-247）。
- SessionDB 兄弟模块：`hermes_state_sessions.py`（`create_session` :416、`_insert_session_row` :369、`reopen_session` :519、`set_session_archived` :953、`list_sessions_rich` :1303、`_session_lineage_root_to_tip` :1526、`delete_session_if_empty` :1791、`_collect_delegate_child_ids` :193）、`hermes_state_messages.py`（`append_messages_batch` :430、`replace_messages` :720、`archive_and_compact` :907、`resolve_resume_session_id` :1452、`get_messages_as_conversation` :1517、`_rows_to_conversation` :1571、`get_resume_conversations` :1667、`rewind_to_message` :1850）、`hermes_state_compression.py`（`publish_compression_child` :373、`get_compression_tip` :897、`get_compression_lineage` :916）、`hermes_state_titles.py`（`_set_session_title` :83、`set_auto_title` :170、`get_next_title_in_lineage` :222）、`hermes_state_search.py`（`search_messages` :1257、`search_sessions_by_id` :1432）、`hermes_state_local.py`（`_lineage_root_id` 使用 :381）。
- 运行与持久化：`run_agent.py`（`_ensure_db_session` :315）、`agent/session_persistence.py`（`_persist_session` :509、`_flush_messages_to_session_db_unlocked` :548、`_drop_trailing_empty_response_scaffolding` :530）、`agent/context_compressor.py`（`_DB_PERSISTED_MARKER` :326、`is_user_originated_turn` :5735）、`agent/tool_executor.py`（`_flush_session_db_after_tool_progress` :201）、`agent/replay_cleanup.py`（`sanitize_replay_history` :147）、`agent/runtime_session_store.py`（worker 持久化 facade）。
- 单写者与租约：`hermes_cli/gateway_session_store.py`、`gateway/turn_lease.py`。
- 网关方法：`tui_gateway/contracts/sessions.py`（方法契约）、`tui_gateway/session_{registry,workdir,lifecycle,compression,history}.py`、`tui_gateway/model_switch.py`、`tui_gateway/methods_session.py`（`session.save` :2160）。
- 崩溃标记：`tui_gateway/turn_marker.py`（`record_turn_start` :124、`clear_turn_marker` :140）。
- 标题：`agent/title_generator.py`（`MAX_DERIVED_TITLE_CHARS` :54、`is_titleable_user_message` :333、`derive_title` :343、`apply_instant_title` :621、`auto_title_session` :642、`maybe_auto_title` :736）、`agent/turn_context.py:201`。
- 子代理：`tools/delegate_tool.py`（`_build_child_agent` :203）。
- 外部会话导入：`hermes_cli/foreign_sessions.py`、`hermes_cli/session_recovery.py`、`apps/desktop/src/app/session-import/index.tsx`。
- 桌面端数据投影：`apps/desktop/src/types/hermes.ts`（`SessionMessage`）、`apps/desktop/src/lib/chat-messages/index.ts`（`ChatMessage`、`toChatMessages`）、`apps/desktop/src/store/session.ts`（`mergeSessionPage`、`sessionPinId`、`lineageAliases`）、`apps/desktop/src/app/session/hooks/use-session-list-actions.ts`。
