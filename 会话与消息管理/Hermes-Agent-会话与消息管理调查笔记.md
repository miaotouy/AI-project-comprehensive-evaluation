# Hermes Agent 会话与消息管理调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 调查方式：直接阅读源码（Python Agent 会话运行时 run_agent.py / hermes_state、SQLite 存储、事件协议、桌面端与 TUI 前端实现），所有符号与行号在 HEAD 快照处逐一核对；行为类结论区分源码事实与静态推断
>
> 调查范围：会话、消息与分支的数据模型、事实源与持久化、生命周期（创建/切换/归档/删除/恢复）、编辑重试与分支语义、列表分页搜索、一致性并发、迁移导入导出与外部对象绑定粒度。请求执行（上下文拼装、流式、压缩触发与中断）与界面工作流分别进入对话请求与上下文、Chat UI 类目；消息渲染器类目记录内容渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **后端是唯一真相源**。会话、消息全部落在 profile 作用域下单一 SQLite（`state.db`）。桌面端所有会话原子只是后端真相的缓存，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的更新原则，该原则逐条对应 `apps/desktop/AGENTS.md`。不存在每会话消息日志主存储：残余 JSON 仅剩一个默认关闭的可选快照写入器（见 §2.1）。
- **身份有两层**：进程内 UI 句柄与持久化主键分开，跨压缩轮转的稳定性靠派生字段提供：
  - 进程内 UI 句柄 `sid`（`uuid4().hex[:8]`，`methods_session.py:16`）；
  - 持久化 `session_key`（`YYYYMMDD_HHMMSS_uuid4.hex[:6]`，`server.py:6797`，响应里叫 `stored_session_id`，`methods_session.py:131`）；
  - 压缩轮转生成新 `session_key`，通过 `parent_session_id` + `end_reason='compression'` 连成轮转链；
  - "跨轮转不变标识"不存在独立列，而是 `list_sessions_rich` 派生的只读字段 `_lineage_root_id`（`hermes_state.py:7464`），桌面端 pin、路由匹配、草稿作用域都基于它（`session.ts:246-247`）。
- **每条消息同时是历史里的事件，也是数据库里的行**。关系表一行一条消息，`active`/`compacted` 分别表示软删与压缩归档；落盘用“单事务批量 + 内存 marker 去重”的原子配对契约（`run_agent.py:2010` 起）。崩溃中途不写库，痕迹只存在于 `turn_marker.py` 的中断标记文件，恢复会话时按标记自动重放。
- **子代理是真实会话**。`delegate_tool.py:1305` 起 `_build_child_agent` 构造独立 AIAgent，首轮惰性落行时写 `model_config._delegate_from` 标记（`:1679`），继承同一套创建、持久化语义；删除时沿标记级联，分支/压缩子会话则“孤儿化不删”。
- **惰性落行**：DB 行首次真实 turn 才创建，空草稿不留行（`run_agent.py:628`；`methods_session.py:113-118` 注释明示“只为画 composer 就建行会留下 Untitled 空会话”）。
- **标题有来源与即时性**：会话在**首个 turn 的 turn_context prologue** 即获得 derived 即时标题（从开场消息确定性派生，无模型调用），随后后台线程用小模型升级为 llm 标题；标题带 provenance（derived < llm < user，`set_auto_title` 单事务比较-交换），用户 `/title` 永不被自动标题覆盖，压缩轮转携带标题不变。

## 系统边界与数据主链

状态权威分层：

- 后端权威：`state.db` 中的会话、消息、用量、标题、pin 等持久字段。
- 桌面端权威：原生/OS 性、窗口、流式渲染缓冲、发送前的乐观向量。
- 两者以事件流同步；桌面端把后端事件投影进本地状态，不做本地合成。

数据主链：

```text
首次 prompt（_ensure_db_session / _ensure_session_db_row，惰性落行）
  -> turn 执行（执行语义在对话请求与上下文笔记）
  -> _persist_session / _flush_messages_to_session_db_unlocked（单事务批量 + marker 去重）
  -> session.resume / session.history / session.list 等 RPC 读取
  -> 压缩轮转生成新 session_key（parent_session_id + end_reason='compression' 连链）
  -> 崩溃时中断标记文件 ~/.hermes/desktop/interrupted_turns.json，resume 时自动重放
```

边界：上下文拼装、Provider 调用、流式事件、压缩触发与中断属于对话请求与上下文（`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`）；会话侧栏、消息操作等界面工作流属于 Chat UI（`../Chat UI/Hermes-Agent-ChatUI调查笔记.md`）；消息内容与列表渲染属于消息渲染器类目，本笔记只记录数据形状与数据分页接口。

## 1. 会话、消息与分支数据模型

### 1.1 会话（Session）

`sessions` 表（`hermes_state_common.py:207-264`，`SCHEMA_VERSION = 25` 在 `:167`）核心字段：

- 标识与血缘：`id` 主键即持久 `session_key`；`parent_session_id`（`:222`，外键 `:262-263`）是血缘/轮转链的唯一关联字段；
- 入口与生命周期：
  - `source`：入口来源（`cli`/`tui`/`telegram`/`subagent`…，`:209`）；
  - `started_at`/`ended_at`/`end_reason`：生命周期（`:223-225`）。
- 标题与配置：`title`/`title_source`（`:244-245`）承载标题 provenance；`model_config` JSON（`:219`）内含 `_branched_from`/`_delegate_from` 标记；
- 提示词：`system_prompt`/`system_prompt_hash`（`:220-221`，v25 起提示词去重到 `system_prompts` 表 `:202-205`）。
- 软状态与聚合：
  - 软状态：`archived`/`pinned`（`:259-260`）；
  - 用量聚合：`message_count`/`tool_call_count`/token 计数（`:226-243`）；
  - 压缩冷却：`compression_failure_cooldown_until` 等（`:253-256`）；
  - 运行环境：`cwd`/`git_branch`/`git_repo_root`（`:233-235`）、`last_activity_at`（`:246`）。

会话 ID 生成统一为"时间戳 + 6 位随机 hex"（`%Y%m%d_%H%M%S` + `uuid4().hex[:6]`）：

- 标准实现：`tui_gateway/server.py:6797`（`_new_session_key`）、`agent/agent_init.py:1512-1519`、`agent/conversation_compression.py:3346-3347`；
- gateway 消息平台例外：用 8 位 hex（`gateway/session.py:2711, 3218`）。

TUI/桌面网关另有进程内句柄 `sid`（`uuid4().hex[:8]`，`methods_session.py:16`），返回给前端的是它，DB 行主键是 `stored_session_id`。

### 1.2 子会话与轮转链

子会话按来源判定（`hermes_state_common.py:85-114`）：

- 分支子会话：`_branched_from` 标记，或旧式父 `end_reason='branched'` 启发式（`_BRANCH_CHILD_SQL`，`:85-91`）；
- 压缩续链：父 `end_reason='compression'`（`_COMPRESSION_CHILD_SQL`，`:94-98`）；
- 子代理：`_delegate_from` 标记（可级联删除；`_ephemeral_child_sql`，`:106-114`）。

链遍历工具（均在 `hermes_state.py`）：

- `get_compression_lineage`（`:9425`）：沿压缩链取全链；
- `get_compression_tip`（`:7004`）：只沿 compression 边取 tip；
- `resolve_resume_session_id`（`:8566`）：解析 resume 目标会话；
- `_session_lineage_root_to_tip`（`:9044`）：root→tip 遍历，`range(100)` 上限 100 层（`:9052`）。

压缩轮转的数据语义（`agent/conversation_compression.py`）与原地压缩对照：

- **轮转**：生成新 session_id → `publish_compression_child` 单事务插入子行（继承 cwd/git/profile/gateway origin、携带标题与压缩后消息）并写压缩后消息、父行 `end_reason='compression'`（`hermes_state.py:4670` 起）→ `agent.session_id` 切换 → flush 基线重置；
- **原地压缩**：`archive_and_compact` 不轮转 ID，软归档 `active=0, compacted=1`（`hermes_state.py:8287`），同一会话 ID 贯穿一生。

压缩的触发与预算语义在对话请求与上下文笔记 §3。

### 1.3 消息行（ChatMessage / SessionMessage）

后端 `messages` 表一行一条消息（`hermes_state_common.py:266-290`）：

- `role`（user/assistant/tool）、`content`、`tool_call_id`/`tool_calls`（JSON 数组）/`tool_name`/`effect_disposition`；
- `reasoning`/`reasoning_content`/`reasoning_details`、`codex_reasoning_items`/`codex_message_items`；多模态 content 经 `_encode_content` JSON 编码（`hermes_state.py:7488`）；
- `timestamp`、`finish_reason`、`token_count`；`platform_message_id`（网关平台侧 ID）；
- 状态：`active`（0 = rewind/undo 软删或压缩归档）、`compacted`（压缩归档，仍可搜索）、`observed`；`display_kind`/`display_metadata`（`model_switch`/`personality_switch` 等时间线条目、`hidden`）；
- `api_content`：发给 API 的字节保真 sidecar，恢复时原样返回（`_rows_to_conversation:8721`；持久化入口见 `run_agent.py:2206-2213` 的“sanitize 会改写的字节才存 sidecar”判定）。

索引（`hermes_state_common.py`）：

- 主索引：`idx_messages_session(session_id, timestamp)`（`:359`）与 `idx_messages_session_id(session_id, id)`（`:360`）；
- 专用部分索引：assistant 且 `tool_calls` 非空（`:366-368`）；
- 延迟索引段：`idx_messages_session_active(session_id, active, timestamp)`（`:382-383`）。

工具结果与 assistant 调用靠 `tool_call_id` 关联，无独立子表。附件无表：图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成 `[screenshot]` 占位（`run_agent.py:2214-2227`，`agent/tool_dispatch_helpers.py:515-526` 同样处理）。

桌面端模型 `ChatMessage`（`apps/desktop/src/lib/chat-messages.ts:13-32`）字段分几类（`rowId` 对应后端 durable `messages.id`）：

- 身份与角色：`id`、`role`、`timestamp`、`branchGroupId`；
- 内容：`parts`（assistant-ui part 数组：text/reasoning/tool-call/图片）；
- 状态：`pending`、`error`、`hidden`、`interim`；
- 外部引用：`attachmentRefs`、`rowId`、`reactions`。

reasoning 是 part 类型而非顶层字段（`:133-134`）；模型名不在消息上，在 per-session runtime state。后端投影 `SessionMessage`（`apps/desktop/src/types/hermes.ts:544-582`）经 `toChatMessages` 转为渲染模型（`chat-messages.ts:922` 起：工具行折叠、`display_kind` 转 system 行、`@image:` 行提取回 attachmentRefs）。part 渲染细节见消息渲染器笔记。

## 2. 事实源、索引与持久化

### 2.1 事实源

`state.db` 是唯一规范存储。残余 JSON 均非消息主存储：

- trajectory / moa-trace / spawn 树等 JSONL 是调试与观察产物，不在消息读路径上；
- 每会话 JSON **快照**写入器 `_save_session_log`（`run_agent.py:2997`）由 `sessions.write_json_snapshots` 门控（**默认 False**，`hermes_cli/config_defaults.py:2798`），开启时在每个持久化点把消息列表重写为 `~/.hermes/sessions/session_{sid}.json` 供外部工具消费，并带“不覆盖更大日志”的截断保护——它不是读路径的数据源。

`api_content` 是发给 API 的字节保真 sidecar，恢复时原样返回。桌面端各会话原子只是后端真相的缓存投影。

### 2.2 索引

`idx_messages_session(session_id, timestamp)` 与 assistant 且 tool_calls 非空的专用部分索引（`hermes_state_common.py:359-360, 366-368`）；消息全文搜索走 FTS 矩阵（unicode61 基表 + CJK bigram `messages_fts_cjk` + trigram 排除 tool 行 + LIKE 兜底），见 §5.3。

### 2.3 落盘与崩溃安全

- `_DB_PERSISTED_MARKER = "_db_persisted"`（`run_agent.py:279`）：内存消息 dict 上的去重标记（`_` 前缀保证不上 API 线），取代按 `id(msg)` 集合去重，防 CPython 地址复用。`agent/context_compressor.py:158` 同款常量供压缩路径复刻标记。
- 落盘走 `_flush_messages_to_session_db_unlocked`（`run_agent.py:2010` 起）：收集本轮新消息 → 单事务 `append_messages_batch` → 成功才盖章；失败不盖章、清空扫描前缀，下轮全量重扫。`append_messages_batch` 支持按 `chunk_rows` 分块事务（`hermes_state.py:7781, 7818-7823`，分支复制用 500 行/块）。`_persist_session`（`run_agent.py:1900`）在每处退出路径（完成、错误、关闭）调用它。
- 工具执行增量落库：`_flush_session_db_after_tool_progress`（`agent/tool_executor.py:178`）在多个工具批次点调用（`800/1504/1645/1677/2269/2340`），应对工具杀死进程的场景。
- 崩溃痕迹：`tui_gateway/turn_marker.py` 写 `<home>/desktop/interrupted_turns.json`，`session.resume` 时按标记自动重跑，attempts 计数防崩溃循环。标记文件管理分三段（上限 32 条/24h/64KB）：
  - 写入：`record_turn_start`（`:97`）；目录/文件名常量 `_MARKER_DIR`/`_MARKER_FILE`（`:34-35`，上限 `:36-40`）；
  - 清理：`clear_turn_marker`（`:124`）在任何"客户端已见到结果"的结局清。
  - 中途断连的另一层恢复是 `_fail_inflight_turn` 保留的可重放快照（`server.py:7343`，`session.resume` 的 `inflight` payload 承载，见对话请求笔记 §6）。

### 2.4 标题（两段式 + 带来源）

`agent/title_generator.py` 的命名现在是**两段式 + 带来源**：

- **即时标题（derived）**：会话首个 turn 的 prologue 内同步执行（`turn_context.py:188` 的 `_maybe_title_session_at_turn_start`，经 `maybe_auto_title` `:234-255` 派发），无模型调用、不失败：
  - `apply_instant_title`（`title_generator.py:474`）调 `derive_title`（`:250`）从开场消息取首个有效行、折叠空白、词边界截断（`MAX_DERIVED_TITLE_CHARS=48`，`:64`），用户发出首条消息后毫秒级可见；
  - 斜杠命令等控制包装被剥离（`is_titleable_user_message`，`:236`）；
  - 随后 `auto_title_session`（`:508`）在后台线程用小模型升级（约束 JSON `{"title": ...}`）。
- **来源与覆盖（provenance）**：标题来源按 `derived(0) < llm(1) < user(2)` 排序（`:6479-6485`），写入是"优先级检查 + 写入"的单事务 compare-and-swap：
  - `set_auto_title`（`hermes_state.py:6688`，实现 `_set_session_title` `:6587-6668`）：只有更高来源才覆盖；
  - 用户 `/title`（`session.title` RPC，`methods_session.py:1022`，`set_session_title` 记 `user` 来源）永不被自动标题覆盖，后台 `llm` 标题也不会覆盖用户标题；
  - legacy NULL 行按 user 计，自动标题只填空（`:6499`）；
  - 唯一索引冲突时经 `get_next_title_in_lineage`（`:6969`）加 `#N`；derived 阶段 `dedupe=False` 让出冲突，交给后台重拾（`title_generator.py:421-471`）。
- **压缩轮转携带标题**：轮转前 `get_session_title` 取父标题（`conversation_compression.py:3343`），轮转后在新会话行上重写同一标题并恢复原 provenance（`:3393-3436`；`publish_compression_child` 的 INSERT 本身不携带 title 列，`hermes_state.py:4720-4753`），不再对每个 fork/轮转重编号。
- 桌面/TUI 侧通过 `agent._on_session_title` 钩子收 `session.title` 事件即时刷新侧栏（`server.py:10021-10023`、`gateway/run.py:4488-4535`）；未命名会话由新标题逻辑补名，TTS 模型/脚手架回合不触发命名。

## 3. 创建、切换、归档、删除与恢复

### 3.1 创建与惰性落行

DB 行是惰性创建的，后端与 TUI 各有入口：

- 后端：`AIAgent._ensure_db_session` 在首次 turn 时执行 `create_session` INSERT（`run_agent.py:628-667`，失败保活下轮重试）；
- TUI：`_ensure_session_db_row`（`server.py:2727`）也在首次 prompt 时落行，废弃草稿不留行（`methods_session.py:113-118` 注释）。

底层 `SessionDB.create_session` → `_insert_session_row`（`hermes_state.py:3859, 3685`），ON CONFLICT 时从父行继承 cwd/git/profile。

### 3.2 resume / close / save

- `session.resume`（`methods_session.py:306` 起）的恢复流程：
  1. `resolve_resume_session_id`（`hermes_state.py:8566`）沿压缩链跳到活 tip（`:374`）；
  2. `reopen_session` 清 `ended_at`/`end_reason`（`hermes_state.py:4791`）；
  3. `get_resume_conversations`（`:8854`）一次 SELECT 出两份投影——模型喂入用修复交替版、显示用原样版（`methods_session.py:545, 631`），`sanitize_replay_history` 去掉悬空 tool 尾巴（`:554, 642`）。
  - resume 还有**转录安全上限**：`sessions.max_resume_messages`（config-gate，默认 20000，0 关闭；`hermes_state.py:89-127` 的 `MAX_SAFE_RESUME_MESSAGES`/`resolved_max_resume_messages`，`config_defaults.py:2836`），在 reopen 前计数整条压缩链（`methods_session.py:381-410`，超限错误 4130）。
- `session.close`（`methods_session.py:2748`）→ `_teardown_popped_session`（`server.py:905`）→ `_finalize_session`（`server.py:661`），做三件事：
  1. flush 未写消息：明确**不带** `conversation_history` 调 `_persist_session`，避免全部消息按身份视为已持久化而跳过（`:686-703`）；
  2. 调 `on_session_end` hook（`:711-725`）；
  3. `end_session` 标记 `ended_at`/`end_reason`（`:737-761`，first-reason-wins；gateway 来源会话不归 TUI 所有不标记，`hermes_state.py:4773`）。

  全程不删数据。
- `session.save` 不写 DB，导出 JSON 到 `~/.hermes/sessions/saved/hermes_conversation_<ts>.json`（`methods_session.py:2676-2743`，含 system prompt）。

### 3.3 删除与归档

- `session.delete`（`methods_session.py:972`）：拒绝删除进程内活跃会话（错误 4023，`:1002-1003`）。`delete_session` 硬删除 messages + sessions 行（`hermes_state.py:9526-9583`），并处理三类关联：
  - delegate 子代理级联删（`:9566`）；
  - 分支/压缩子会话则 `parent_session_id → NULL` 孤立保留（`:9568-9572`）；
  - 连带清理磁盘转录文件（`:9580-9582`）。
- 归档与删除并存：`archived=1` 软隐藏（默认列表不显示、消息保留），按压缩整链递归翻转（`set_session_archived`，`hermes_state.py:6750`）；无回收站，硬删除不可恢复。
- 空会话清理：`delete_session_if_empty`（`hermes_state.py:9585`，单事务判空：无消息、无用户标题、无子会话）由 CLI 退出/轮转路径调用，防止“开了就退”的空会话堆积。

### 3.4 恢复与保留语义

- 崩溃恢复：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹；`session.resume` 时按标记自动重放，attempts 计数防崩溃循环。
- 压缩轮转恢复：resume 沿压缩链跳到活 tip，`get_resume_conversations` 提供模型喂入与显示两份投影（3.2）；`_lineage_root_id` 提供跨轮转的稳定身份（`hermes_state.py:7464`），桌面端 pin、路由匹配都基于它（`session.ts:246-247`）。
- 保留语义：
  - 轮转与原地压缩都以 `active=0`/`compacted=1` 保留旧行，压缩归档行仍可搜索；`end_session` 只标记不删数据；硬删除无回收站。
  - `/retry`、编辑/rewind 截断均改为**保留归档历史**的破坏性改写：`replace_messages` 带 `active_only=True, archive_dropped=True` 语义（`methods_prompt.py:264-286` 注释引 #70516/#80763/#82756），旧轮次不再从消息列表蒸发、但落盘为可搜索归档行。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑 = 截断 + 重发**。无 `session.edit`/`message.edit` RPC（检查范围：`tui_gateway` 全部 `@method` 注册表，`session.*`/`message.*` 方法列表中无编辑项；桌面侧无对应调用）。编辑的数据变更分三处：
  - 桌面入口：`user-message.tsx:326-355`，点击进入编辑 composer，发送即"interrupt + rewind"（执行链在对话请求与上下文笔记 §7）；
  - 参数构造：`prompt.submit` + `truncate_before_user_ordinal`（`rewind.ts:37` 的 `truncateSubmitParams`）；
  - 服务端改写：先 `db.replace_messages`（单事务 DELETE+重插，压缩已结束会话抛 `CompressionSessionClosedError`，`hermes_state.py:2023, 8241`）再改内存历史并 `history_version += 1`（`methods_prompt.py:175-303`）。
- **删除**：仅会话级，无单消息删除（检查范围：方法注册表 + 桌面端消息操作代码，无 message-level delete RPC）。软删原语 `rewind_to_message`（`hermes_state.py:9084`，id≥target 全部 `active=0`）只服务 `/rewind` 命令；`session.undo` 是进程内历史截断（见下）。
- **重试**：无 `session.retry`（检查范围：`@method` 注册表）；`truncate_after` 概念本仓库不存在（全树 grep 仅命中无关测试名）。三套实现共享"截断到最后一个真实 user turn 后重发"语义，真实 user turn 由 `is_user_originated_turn` 判定（`agent/context_compressor.py:7368-7386`：`role=="user" and not display_kind` 且非压缩摘要/合成轮）。执行细节见对话请求与上下文笔记 §7，入口有四类：
  - TUI `/retry` 与 `slash.exec`；
  - 桌面 reload/regenerate；
  - CLI `retry_last()`（`cli.py:8714`）。
- **续写**：无 `/continue` 命令、无独立 RPC，就是普通 `prompt.submit` 文本 "continue"（busy 时也只入队）。空响应恢复会重放空 assistant 消息，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`run_agent.py:1940`，`turn_finalizer.py:268` 调用）。
- **分支**：`session.branch`（`methods_session.py:2760` 起）的流程分四步：
  1. 可选 `count` 截断复制历史；
  2. 建新 `session_key` + `model_config={"_branched_from": old_key}` + `parent_session_id=old_key`（`:2793-2813`）；
  3. `append_messages_batch` 分块复制（chunk 500，保留原 timestamp，`:2817-2842`）；
  4. 标题 `get_next_title_in_lineage` 生成 `"xxx #2"`（`:2788-2792`）。

  父会话保持 live，返回 `{session_id, stored_session_id, parent, messages}`。分支种子的落库与桌面 fork 分两路：

  - 分支种子在首次 prompt 时经 `_persist_branch_seed` 落库（`server.py:2859`，`methods_prompt.py:326`）；
  - 桌面 fork：live 会话用 `session.branch`，无 live 源时 `session.create` + `parent_session_id` + messages 种子（`use-session-actions/index.ts:1178` `forkBranch`）。
- **版本切换**：无 checkpoint 版本 RPC。相关能力分三类：
  - 读取全量历史：`session.history`（`include_ancestors=True`，`methods_session.py:2442-2463`）；
  - 运行中干预：`session.steer`（`:3219`）与 `session.redirect`（`:3252`）不新增持久化对象，执行语义在对话请求与上下文笔记 §7；
  - 撤销：`session.undo`（`methods_session.py:2466-2501`）拒绝 running 中调用（错误 4009），按 `is_user_originated_turn` 找最后一个真实 user turn 截断进程内历史并 `history_version += 1`。

## 5. 列表、分页、搜索与定位

### 5.1 会话列表

- TUI `session.list`（`methods_session.py:162-211`）：`limit` 默认 200、单页无 offset，超取后 Python 过滤 deny 列表 `{"kanban","tool"}`，按最近活跃排序。
- REST `GET /api/sessions`（`hermes_cli/web_routers/sessions.py:54-163`）支持多类过滤参数：`limit`（默认 20、上限 100，`:58`）、`offset`、`min_messages`、`archived`、`source(s)`。
- 底层 `list_sessions_rich`（`hermes_state.py:7104`）单查询完成多件事：
  - 预览：子查询取首个 user 消息；
  - 置顶回填：`include_pinned` 把被 LIMIT 挤出的置顶会话回填（`:7164-7170`）；
  - 最近活跃排序：按压缩链递归 CTE 取 tip 的 `effective_last_active` 并在 SQL 层 LIMIT（`:7144-7150`）；
  - 逻辑去重：压缩链 root 投影到活 tip，一条逻辑会话一条目（`:7136-7142`）；
  - 默认排除子代理与压缩续链会话（`_LISTABLE_CHILD_SQL` + `_delegate_from IS NULL`，`:7182-7198`，`hermes_state_common.py:103`）。
- 桌面侧栏走 `/api/profiles/sessions/sidebar` 分 profile 分片（`hermes.ts:427` `listAllProfileSessions`、`:455-640` 批量 sidebar 请求，含 recents/cron/messaging 三切片与旧端点兼容回退），`SIDEBAR_SESSIONS_PAGE_SIZE` + `loadMoreSessions` 翻页（`use-session-list-actions.ts:264`）；侧栏界面工作流与虚拟列表呈现见 Chat UI 笔记 §1。

### 5.2 消息列表

- REST `GET /api/sessions/{id}/messages`（`sessions.py:601-635`）：
  - 分页：`limit` 上限 500（`:629`），`order=oldest` 从头翻页、缺省/`latest` 返回最新一页（`:627-628`）；
  - 会话解析：先 `resolve_session_id` + `resolve_resume_session_id` 沿压缩链解析（`:618-621`）。
- `get_messages_as_conversation`（`hermes_state.py:8655`）：
  - 排序：`ORDER BY id` 正序（不用 timestamp，防 WSL2/NTP 时钟回拨打乱 tool_call 邻接，注释在 `:8691-8698`）；
  - 祖先：`include_ancestors` 先走 lineage 链（`:8682-8683`）；
  - 交替修复：`repair_alternation` 供 LIVE REPLAY（`:8671-8679`）。
- 桌面端直播 transcript 不分页：resume 整段返回（`methods_session.py:545`）。

### 5.3 搜索

`search_messages`（`hermes_state_search.py:1410` → `_search_messages_impl` :1699）：

- 范围：全 `messages` 表 + FTS 索引，不搜 sessions 表；rewind/undo 行（`active=0 AND compacted=0`）默认隐藏，压缩归档行默认可见（`(m.active = 1 OR m.compacted = 1)`，`:1372/:1560/:1793-1795`）。
- 索引矩阵（四路）：
  - `messages_fts`：fts5 unicode61 基表（`hermes_state_common.py:417`）；
  - `messages_fts_cjk`：bigram（`cjk_unicode61`，`hermes_state.py:1930`），绝大多数 CJK 查询走它；
  - `messages_fts_trigram`：≥3 CJK 字（`hermes_state_common.py:486-492`，通过排除 tool 行的视图 `messages_fts_trigram_src` `:481`）；tool 行不进 trigram 索引（注释明示约 90% 字节是机器噪声，`:471-479`）；
  - LIKE 兜底：短/混合 CJK 或 role=tool。

  路由路径分类 `_describe_search_path`（`hermes_state_search.py:1460-1482`：fts5 / fts_cjk / trigram / like_scan）在 `_search_messages_impl` 内按同类条件分派。
- 命中定位分四类行为：
  - FTS 路径：`snippet(...,40)` 前后端标（`:1387`/`:1820`）；
  - LIKE 路径：`instr` + 前后字符切片（`:1580`）；
  - `context` 字段：返回命中前后各 1 条（`:1625-1685`）；
  - 结果默认剥掉 `content` 只留 snippet（`:1687`）。
  - FTS5 特殊字符剥离（`:1237-1239`：非 CJK 查询剥 `%` 等）。
- 会话 id 搜索：`search_sessions_by_id`（`:2283`）exact/prefix/substring 三级评分，`_lineage_root_id` 也参与匹配（`:2296-2322`）；REST `GET /api/sessions/search` 按压缩链 root 去重（`sessions.py:169-391`）。

### 5.4 列表窗口化边界

列表窗口化、滚动锚定、渲染预算与 `content-visibility` 属于消息渲染器笔记（§3 列表层）；本笔记只记录数据分页接口：REST `limit/offset`、侧栏翻页接口、resume 整段返回。

## 6. 缓存、一致性、多窗口与并发写入

桌面端把后端事件投影进本地状态，三原则（合并而非覆盖 / 先乐观后诚实 / 拒绝乱序回写）对应的数据一致性语义：

- **合并而非覆盖**：`mergeSessionPage` 保留 working/pinned/刚 settle 行，按 `_lineage_root_id` 去重防压缩轮转后双行（`session.ts:393`，`store/session.test.ts:208-263` 有对应用例）；`sessionsToKeep` 定义保留集（`use-session-list-actions.ts:58`）；刷新结果签名门控保持引用同一。
- **先乐观后诚实**：`seedOptimistic` 先插用户气泡、失败路径回滚并追加错误气泡；rewind/edit 失败回滚完整历史（`use-prompt-actions/index.ts:877-948`）。
- **拒绝乱序回写**：`refreshSessionsRequestRef` 请求代际单调递增、过期响应丢弃（`use-session-list-actions.ts:86, 151-152, 190`）；视图发布只接受当前 active 会话 + rAF 合并、flush 前再验 sessionId（`use-session-state-cache.ts:210-267`）。
- **多 profile 同步**：每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41, 219`）；重连成功后丢弃过期 runtime id（`resetTileRuntimeBindings`，`use-gateway-boot.ts:190`），再 `refreshSessions` 重新同步（连接生命周期见 Chat UI 笔记）。
- **压缩轮转的数据一致性**：轮转后 flush 基线重置；`_sync_session_key_after_compress` 重锚 session_key（`server.py:4919`：会话配额租约迁移、yolo 状态迁移）。session 层有回合租约（turn lease）超时 fail-closed（`gateway/turn_lease.py`）；会话持久化失败按类型分类（锁竞争 vs 磁盘满），桌面端可映射“disk full”提示（`methods_prompt.py:319-345`）。

## 7. 迁移、导入导出与保留策略

- `SCHEMA_VERSION = 25`（`hermes_state_common.py:167`）。v25 起系统提示词去重到 `system_prompts` 表（`system_prompt_hash`，`:202-205, 221`）；FTS 存储布局版本独立于 schema（`FTS_STORAGE_VERSION`，`:170-178`），legacy DB 在用户执行 `hermes sessions optimize-storage` 前停留在旧布局。
- 导出：`session.save` 写 JSON 到 `~/.hermes/sessions/saved/`，不写 DB（3.2）。
- 保留：归档 `archived=1` 不删数据；硬删除无回收站不可恢复；`end_session` 只标记 `ended_at/end_reason`；`/retry`/rewind 的截断行落为 `active=0` 归档（§3.4）。
- 崩溃恢复语义见 §3.4；导入/备份恢复路径（`hermes sessions export/import`、`session_recovery.py` 等）未在本次调查范围内验证。

## 8. Agent、模型、知识库与附件绑定

- **绑定粒度是会话级**：每次创建/恢复/分支会话都 `_make_agent`（`server.py:6489`）+ `_init_session`（`:6677`）；`model_override`/`create_reasoning_override` 为每会话字段（`methods_session.py:50-71, 96-98`）。

  运行中 `/model` 切换 = `_apply_model_switch`（`server.py:4484`）换 agent 客户端，工具集不中途更换；切换以 `model_switch` 的 `display_kind` 时间线条目入史，不计入 user 轮计数。
- **子代理**：`_build_child_agent`（`delegate_tool.py:1305` 起）构造独立 `AIAgent`（platform 为 subagent，共享父会话句柄与 `parent_session_id`），子代理有独立 `session_id`（`agent_init.py:1512-1519`），首轮惰性落行时写 `_delegate_from` 标记（`:1679`）。

  列表隐藏是双层：`_LISTABLE_CHILD_SQL` 排除无 `_branched_from` 的子会话（`hermes_state_common.py:103`）+ `_delegate_from IS NULL` 显式排除（`hermes_state.py:7198`），父删除后孤儿化仍隐藏。删除时沿标记递归级联（`_collect_delegate_child_ids`，`hermes_state.py:287`），未标记子会话走"孤儿化不删"契约防环。
- **工具调用的消息表示**：
  - 持久化：assistant 行带 `tool_calls`；结果经 `make_tool_result_message` 落 `{"role":"tool", tool_call_id, ...}` 行，高风险工具内容包 `<untrusted_tool_result>`（`agent/tool_dispatch_helpers.py`）；中断/取消工具写 `effect_disposition="none"` 占位（`agent/tool_executor.py`）；
  - UI 投影：`_history_to_messages` 中 tool 行渲染为 `{role:"tool", name, context}`（`server.py:7136`），assistant 的 `tool_calls` 不单独成行。
- **附件（数据侧）**：无附件表，图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成 `[screenshot]`（`run_agent.py:2214-2227`）；`[[Image N]]` 指引本次未找到（全树 grep 零命中）。桌面拖放/上传管线属于 Chat UI 笔记 §3，提交注入点属于对话请求与上下文笔记 §9。

## 9. 设计取舍与已确认边界

- **惰性 DB 行**：首次真实 turn 才落行，空草稿不留痕；显式 `/title` 属明确意图，会现建行。
- **单事务批量落盘 + marker 去重**：一轮消息一次批量写，失败不盖章、下轮全量重扫；`_finalize_session` 的关闭 flush 不带 `conversation_history`，防止“全部消息按身份视为已持久化”的丢尾。
- **轮转 vs 原地压缩**：轮转生成新 session_id 并连链（推荐路径），原地压缩同 ID 软归档；两者都以 `active=0/compacted=1` 保留旧行，压缩归档行仍可搜索。
- **双 ID 边界**：`sid` 进程内、`session_key` 持久；跨轮转稳定性由派生 `_lineage_root_id` 提供，桌面端把 pin/草稿作用域/路由匹配都键在 root 上。
- **编辑 = 截断重发**：无消息级原地编辑与单消息删除（本次未找到，检查范围见 §4）；软删只服务 `/rewind`；截断重发带 `active_only+archive_dropped` 归档语义，且要求显式 `confirm_truncate` 证明意图。
- **崩溃恢复靠标记文件**：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹，resume 时自动重放且 attempts 防循环。
- **FTS 排除 tool 行**：trigram 索引明确跳过 `role='tool'` 行（约 90% 字节为机器噪声），tool 内容走 LIKE 兜底。
- **state.db 是唯一规范存储**：可选 JSON 快照写入默认关闭；残余 JSONL（trajectory、moa-trace、spawn 树）均非消息主存储。
- **子代理级联删除契约**：标记子会话递归级联删除，未标记子会话“孤儿化不删”防环（§8）。

## 当前重连与 profile 归属

桌面/TUI 客户端的 JSON-RPC 连接维护每个会话的事件序号水位；重连后只请求水位之后的事件，并把回放帧交给通常的事件分发路径（`apps/shared/src/json-rpc-gateway.ts:110-121`、`522-523`）。桌面端的会话请求同时带有 profile/connection 作用域，跨 profile 的同名 session 不应再按单独 ID 合并（`apps/desktop/src/api/sessions.ts:16-31`、`334-413`）。这改变的是缓存和恢复时的身份判定，不改变 SQLite 是会话与消息事实源的结论。

## 10. 未验证事项

- FTS 实际线上布局、触发重建与 trigram 命中效果未验证。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证。
- 崩溃恢复、多窗口并发写入、大数据量搜索需运行验证（静态代码只能确认事务、索引与写入入口）。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- REST 路由挂载点（`hermes_cli/web_server.py`）除 `mount_spa` 外未逐行核对。
- 运行行为（视觉效果、时序、性能）全部为静态推断，未运行验证。

## 11. 关键源码索引

- Schema：`hermes_state_common.py`——`sessions`（:207）、`messages`（:266）、FTS 表与触发器（:417-618）、子会话判定（:85-114）、`SCHEMA_VERSION=25`（:167）。
- `hermes_state.py`：`create_session`（:3859）、`append_messages_batch`（:7781）、`replace_messages`（:8187）、`rewind_to_message`（:9084）、`set_session_archived`（:6750）、`delete_session`（:9526）、`delete_session_if_empty`（:9585）、`get_messages_as_conversation`（:8655）、`list_sessions_rich`（:7104）、`get_resume_conversations`（:8854）、`publish_compression_child`（:4670）/`archive_and_compact`（:8287）、`_lineage_root_id` 派生（:7464）、`set_auto_title`（:6688，标题 provenance compare-and-swap）。
- 运行与持久化：`run_agent.py`——`_persist_session`（:1900）、`_flush_messages_to_session_db_unlocked`（:2010）、`_ensure_db_session`（:628）、`_save_session_log`（:2997）。
- session 方法：`tui_gateway/methods_session.py`——create（:14）、list（:162）、resume（:306）、undo（:2466）、delete（:972）、save（:2676）、close（:2748）、branch（:2760）、history（:2442）、title（:1022）、interrupt（:2942）、steer（:3219）、redirect（:3252）。
- 崩溃标记：`tui_gateway/turn_marker.py`；标题：`agent/title_generator.py`（`derive_title` :250、`apply_instant_title` :474、`auto_title_session` :508）；搜索：`hermes_state_search.py` `search_messages`（:1410）、`search_sessions_by_id`（:2283）。
- 子代理：`tools/delegate_tool.py` `_build_child_agent`（:1305）、`_delegate_from` 标记（:1679）。
- 桌面端数据投影：`apps/desktop/src/types/hermes.ts`（`SessionMessage` :544）、`lib/chat-messages.ts`（`ChatMessage` :13、`toChatMessages` :922）、`store/session.ts`（`mergeSessionPage` :393、`sessionPinId` :246、`lineageAliases` :307）、`use-session-list-actions.ts`（:58、:151-152、:190、:264）。
