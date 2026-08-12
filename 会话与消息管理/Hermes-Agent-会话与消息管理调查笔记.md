# Hermes-Agent 会话与消息管理调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：从 [`../Chat/Hermes-Agent-Chat调查笔记.md`](../Chat/Hermes-Agent-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据；对上一快照（`01a1037d`）之后的提交范围做增量核对（`git log`/`git diff`），受影响结论在 HEAD 处源码重新确认，失效行号已更新
>
> 调查范围：会话与消息的数据模型、生命周期与持久化、分支语义、列表检索与一致性；请求执行（上下文拼装、流式、压缩触发）与界面工作流分别进入对话请求与上下文、Chat UI 类目，内容渲染进入消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **后端是唯一真相源**。会话、消息全部落在 profile 作用域下单一 SQLite（`state.db`）；每会话 JSONL 消息日志已在 spec 002 移除（`gateway/session.py`）。桌面端所有会话原子只是后端真相的缓存，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的更新原则，该原则逐条对应 `apps/desktop/AGENTS.md`。
- **身份有两层**。进程内 UI 句柄 `sid`（8 位 hex，`methods_session.py:16`）与持久化 `session_key`（`YYYYMMDD_HHMMSS_uuid6`，响应里叫 `stored_session_id`，`methods_session.py:131`）。压缩轮转生成新 `session_key`，通过 `parent_session_id` + `end_reason='compression'` 连成轮转链；“跨轮转不变标识”不存在独立列，而是 `list_sessions_rich` 派生的只读字段 `_lineage_root_id`（`hermes_state.py:7464`），桌面端 pin、路由匹配都基于它（`session.ts:246-247`）。
- **每条消息同时是历史里的事件，也是数据库里的行**。关系表一行一条消息，`active`/`compacted` 分别表示软删与压缩归档；落盘用“单事务批量 + 内存 marker 去重”的原子配对契约（`run_agent.py:2010` 起）。崩溃中途不写库，痕迹只存在于 `turn_marker.py` 的中断标记文件，恢复会话时按标记自动重放。
- **子代理是真实会话**。`delegate_task` 创建占 DB 行的子会话（`source='subagent'`、`model_config._delegate_from` 标记），继承同一套创建、持久化语义，删除时沿标记级联。
- **惰性落行**：DB 行首次真实 turn 才创建，空草稿不留行（`run_agent.py:628`）。
- **标题有来源与即时性**（`f726090d`/`5566379f` 等提交大改）：会话在**首个 turn 开始**即获得“derived”即时标题（从开场消息确定性派生，无模型调用），随后后台小模型调用升级为 “llm” 标题；标题带 provenance（derived < llm < user，`set_auto_title` 单事务比较-交换），用户 `/title` 永不被自动标题覆盖，压缩轮转**携带标题不变**（不再对分支重编号，见 §2.4）。

## 系统边界与数据主链

后端是唯一真相源：会话、消息全部落在 profile 作用域下单一 SQLite（`state.db`）；每会话 JSONL 消息日志已在 spec 002 移除（`gateway/session.py:3383-3385`）。桌面端所有会话原子只是后端真相的缓存，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的更新原则（该原则在 Chat UI 笔记 §8 展开）。

状态权威分层（源笔记“系统边界与总体调用链”）：

- 后端权威：`state.db` 中的会话、消息、用量、标题、pin 等持久字段。
- 桌面端权威：原生/OS 性、窗口、流式渲染缓冲、发送前的乐观向量。
- 两者以事件流同步；桌面端把后端事件投影进本地状态，不做本地合成。

数据主链：

```text
首次 prompt（_ensure_session_db_row，惰性落行）
  -> turn 执行（执行语义在对话请求与上下文）
  -> _persist_session / _flush_messages_to_session_db_unlocked（单事务批量 + marker 去重）
  -> session.resume / session.history / session.list 等 RPC 读取
  -> 压缩轮转生成新 session_key（parent_session_id + end_reason='compression' 连链）
  -> 崩溃时中断标记文件 ~/.hermes/desktop/interrupted_turns.json，resume 时自动重放
```

边界：上下文拼装、Provider 调用、流式事件、压缩触发与中断属于对话请求与上下文（`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`）；会话侧栏、消息操作等界面工作流属于 Chat UI（<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>）；消息内容与列表渲染属于消息渲染器（`../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md`，本笔记只记录数据形状与数据分页接口）。

## 1. 会话、消息与分支数据模型

### 1.1 会话（Session）

`sessions` 表（`hermes_state_common.py:207-263`，`SCHEMA_VERSION=25`）核心字段：

- `id` 主键即持久 `session_key`；`source`（`cli`/`tui`/`telegram`/`subagent`…）；`parent_session_id` 外键，是血缘/轮转链的唯一关联字段（`:261`）；`display_name`、`title`、`started_at/ended_at/end_reason`。
- `model_config` JSON，内含 `_branched_from`/`_delegate_from` 标记；`system_prompt`/`system_prompt_hash`（v25 起提示词去重到 `system_prompts` 表）。
- `archived`/`pinned` 软状态；`message_count`/`tool_call_count`/token 用量聚合；`compression_failure_*` 压缩失败冷却字段；`cwd`/`git_branch`/`git_repo_root`。

会话 ID 生成统一为时间戳 + 6 位随机 hex（`agent_init.py:1497-1499`、`conversation_compression.py:3265-3268`）；gateway 消息平台用 8 位 hex（`gateway/session.py:2558, 2902`）。TUI 网关另有一套进程内句柄 `sid = uuid.uuid4().hex[:8]`（`methods_session.py:16`），返回给前端的是它，DB 行主键是 `stored_session_id`。

### 1.2 子会话与轮转链

子会话按来源区分（`hermes_state_common.py:85-114`）：

- 分支子会话：`_branched_from` 标记，或旧式父 `end_reason='branched'` 启发式；
- 压缩续链：父 `end_reason='compression'`；
- 子代理：`_delegate_from` 标记（可级联删除）。

链遍历工具：`get_compression_lineage`（`hermes_state.py:9425`）、`get_compression_tip`（`:7004`，只沿 compression 边）、`resolve_resume_session_id`（`:8566`）、`_session_lineage_root_to_tip`（`:9044`，上限 100 层）。

压缩轮转的数据语义：`conversation_compression.py`——生成新 session_id → `publish_compression_child` 单事务插入子行（继承 cwd/git/profile/gateway origin、携带标题与压缩后消息）并写压缩后消息、父行 `end_reason='compression'`（`hermes_state.py:4670` 起）→ `agent.session_id` 切换 → flush 基线重置。原地压缩 `archive_and_compact` 不轮转 ID，软归档 `active=0, compacted=1`（`hermes_state.py:8287`），同一会话 ID 贯穿一生。压缩的触发与预算语义在对话请求与上下文笔记 §3。

### 1.3 消息行（ChatMessage / SessionMessage）

后端 `messages` 表一行一条消息（`hermes_state_common.py:265-289`）：

- `role`（user/assistant/tool）、`content`、`tool_call_id`/`tool_calls`（JSON 数组）/`tool_name`/`effect_disposition`；
- `reasoning`/`reasoning_content`/`reasoning_details`、`codex_*`（JSON）；多模态 content 经 `_encode_content` JSON 编码（`hermes_state.py:7488`）；新增 `codex_reasoning_items` 压缩清理（`adf9549c`，见对话请求笔记）；
- `timestamp`、`finish_reason`、`token_count`；`platform_message_id`（网关平台侧 ID）；
- 状态：`active`（0 = rewind/undo 软删或压缩归档）、`compacted`（压缩归档，仍可搜索）、`observed`；`display_kind`/`display_metadata`（如 `model_switch`/`personality_switch` 时间线条目、`hidden`）；
- `api_content`：发给 API 的字节保真 sidecar，恢复时原样返回（`_rows_to_conversation:8721`）。

索引：`idx_messages_session(session_id, timestamp)`、assistant 且 tool_calls 非空的专用索引（`:366-367`）。工具结果与 assistant 调用靠 `tool_call_id` 关联，无独立子表。附件无表：图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成 `[screenshot]`（`run_agent.py:2206-2215`）。

桌面端模型 `ChatMessage`（`apps/desktop/src/lib/chat-messages.ts:13-32`）：`id`、`role`、`parts`（assistant-ui part 数组：text/reasoning/tool-call/图片）、`timestamp`、`pending`、`error`、`branchGroupId`、`hidden`、`interim`、`attachmentRefs`、`rowId`（对应后端 durable `messages.id`）、`reactions`。reasoning 是 part 类型而非顶层字段（`:132-134`）；模型名不在消息上，在 per-session runtime state。后端投影 `SessionMessage`（`types/hermes.ts:538-569`）经 `toChatMessages` 转为渲染模型（`:912-1099`：工具行折叠、`display_kind` 转 system 行、`@image:` 行提取回 attachmentRefs）。part 渲染细节见消息渲染器笔记。

## 2. 事实源、索引与持久化

### 2.1 事实源

`state.db` 是唯一规范存储；残余 JSONL（trajectory、moa-trace、spawn 树）均非消息主存储。`api_content` 是发给 API 的字节保真 sidecar，恢复时原样返回（`_rows_to_conversation:7367`）。桌面端各会话原子只是后端真相的缓存投影。

### 2.2 索引

`idx_messages_session(session_id, timestamp)` 与 assistant 且 tool_calls 非空的专用索引（`hermes_state_common.py:366-367`）；消息全文搜索走 FTS 三索引矩阵（unicode61 / bigram / trigram + LIKE 兜底），见 §5.3。

### 2.3 落盘与崩溃安全

- `_DB_PERSISTED_MARKER = "_db_persisted"`（`run_agent.py:279`）：内存消息 dict 上的去重标记（取代 `id(msg)` 集合，防 CPython 地址复用），`_` 前缀保证不上 API 线。
- `_flush_messages_to_session_db_unlocked`（`run_agent.py:2010` 起）：收集本轮新消息 → 单事务 `append_messages_batch` → 成功才盖章；失败不盖章、清空扫描前缀，下轮全量重扫。`append_messages_batch` 按 500 行分块事务（`hermes_state.py:7781`）。压缩轮转后 flush 基线重置（`conversation_compression.py`）。
- 工具执行增量落库：`_flush_session_db_after_tool_progress` 每批工具结果后立即 flush（`tool_executor.py:178` 附近），应对工具杀死进程的场景。
- 崩溃痕迹：`turn_marker.py` 写 `~/.hermes/desktop/interrupted_turns.json`（`record_turn_start:97`，上限 32 条/24h/64KB；`clear_turn_marker:124` 在任何“客户端已见到结果”的结局清）。`session.resume` 时按标记自动重跑，attempts 计数防崩溃循环。对"中断脚手架 ghost 行"做了两次清理（`0072969c`/`6bdeb2df`：API replay 不再带出已删除的 interrupt-scaffold 行，`68d1aea1` 保持其不落到 tool-tail 重定向占位）。

### 2.4 标题（`f726090d`/`5566379f` 等提交重做）

`agent/title_generator.py` 的命名现在是**两段式 + 带来源**：

- **即时标题（derived）**：会话首个 turn 的 prologue 内同步执行 `apply_instant_title`（`turn_context.py:250`，`title_generator.py:474`）——`derive_title`（`:250`，无模型调用、不失败）从开场消息取首个有效行、折叠空白、词边界截断（`MAX_DERIVED_TITLE_CHARS`），用户发出首条消息后毫秒级可见；斜杠命令等控制包装被剥离（按参数命名，`title_generator.py` `is_titleable_user_message`）。随后 `auto_title_session`（`:508`）在后台线程用小模型升级（aux `title_generation` 任务，约束 JSON `{"title": ...}`，禁用思考）。
- **来源与覆盖（provenance）**：`set_auto_title`（`hermes_state.py`）是"优先级检查 + 写入"的单事务 compare-and-swap，authority 序 `derived < llm < user`；用户 `/title`（`session.title` RPC，`methods_session.py:1022`）永不被自动标题覆盖，后台 `llm` 标题也不会覆盖用户标题；legacy NULL 行按 user 计，自动标题只填空。唯一索引冲突时经 `get_next_title_in_lineage`（`hermes_state.py:6969`）加 `#N`（derived 阶段 `dedupe=False` 让出冲突，交给后台重拾，`:421-471`）。
- **压缩轮转携带标题**：标题随压缩链迁移（`conversation_compression.py` + `hermes_state.py:137` 行级变更），不再对每个 fork/轮转重编号——旧行为"每次压缩轮转把 `xxx #N` 再推高一位"（提交信息原话：一份工作变成 'Smallville Map Architecture Plan #10'）已修复。
- 桌面/TUI 侧通过 `agent._on_session_title` 钩子收 `session.title` 事件即时刷新侧栏（`server.py:10021`、`gateway/run.py:4488-4535`）；未命名会话由新标题逻辑补名（`4fbbf0f1`），TTS 模型/脚手架回合不再触发命名（`53a40032`、`cedc933c`），模型切换 marker 不再当标题（`b684cbb0`）。

## 3. 创建、切换、归档、删除与恢复

### 3.1 创建与惰性落行

DB 行是惰性创建的：`AIAgent._ensure_db_session` 在首次 turn 时 INSERT-OR-IGNORE（`run_agent.py:628`）；TUI 侧 `_ensure_session_db_row` 也在首次 prompt 时落行，废弃草稿不留行。`SessionDB.create_session` → `_insert_session_row`（`hermes_state.py:3859, 3685`），ON CONFLICT 时从父行继承 cwd/git/profile。

### 3.2 resume / close / save

- `session.resume`（`methods_session.py:306-690`）：先 `resolve_resume_session_id`（`hermes_state.py:8566`）沿压缩链跳到活 tip，`reopen_session` 清 `ended_at/end_reason`（`hermes_state.py:4791`）；`get_resume_conversations`（`hermes_state.py:8854`）一次 SELECT 出两份投影——模型喂入用修复交替版、显示用原样版，`sanitize_replay_history` 去掉悬空 tool 尾巴。为 resume 增加**转录安全上限**：`transcript_safety_limits`（config-gate，`f0794640`）——超大转录防止内存耗尽（`c750d535`），守卫关闭时跳过计数（`edf2cb4b`），CLI mid-setup 路径同样生效（`5b4b9bbf`）；孤儿压缩父会话的恢复租约带过期围栏（`988f2baa`/`95a7058e`）。
- `session.close`（`methods_session.py:2748`）→ `_finalize_session`：flush 未写消息（明确不带 `conversation_history` 调 `_persist_session`，避免全部消息按身份视为已持久化而跳过）、调 `on_session_end` hook；`end_session` 只标记 `ended_at/end_reason`，first-reason-wins（`hermes_state.py:4773`），不删数据。
- `session.save` 不写 DB，导出 JSON 到 `~/.hermes/sessions/saved/`（`methods_session.py:2676`）。

### 3.3 删除与归档

- `session.delete`（`methods_session.py:972`）：拒绝删除进程内活跃会话（错误 4023）；`delete_session` 硬删除 messages + sessions 行（`hermes_state.py:9526`），delegate 子代理级联删，分支/压缩子会话则 `parent_session_id → NULL` 孤立保留；连带清理磁盘转录文件。
- 归档与删除并存：`archived=1` 软隐藏（默认列表不显示、消息保留），按压缩整链递归翻转（`set_session_archived`，`hermes_state.py:6750`）；无回收站，硬删除不可恢复。

### 3.4 恢复与保留语义

- 崩溃恢复：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹；`session.resume` 时按标记自动重放，attempts 计数防崩溃循环。
- 压缩轮转恢复：resume 沿压缩链跳到活 tip，`get_resume_conversations` 提供模型喂入与显示两份投影（3.2）；`_lineage_root_id` 提供跨轮转的稳定身份（`hermes_state.py:7464`），桌面端 pin、路由匹配都基于它（`session.ts:246-247`）。
- 保留语义：轮转与原地压缩都以 `active=0/compacted=1` 保留旧行，压缩归档行仍可搜索；`end_session` 只标记不删数据；硬删除无回收站。`/retry`、`/compress` 与 recall 红action 均改为**保留归档历史**的破坏性改写（`56fbac6b`/`30c1421a`/`2d9b809f`/`ee6d7964`，`replace_messages` 带 archive 语义），不再让旧轮次从消息列表蒸发。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑 = 截断 + 重发**。无 `session.edit`/`message.edit` RPC（检查范围：`tui_gateway` 全部 `@method` 注册表）。编辑经 `prompt.submit` + `truncate_before_user_ordinal`（桌面 `rewind.ts:37` `truncateSubmitParams`）；服务端先 `db.replace_messages`（单事务 DELETE+重插，压缩已结束会话抛 `CompressionSessionClosedError`，`hermes_state.py:8187`）再改内存历史。桌面入口 `user-message.tsx:326-356`：点击进入编辑 composer，发送即“interrupt + rewind”（执行链在对话请求与上下文笔记 §7）。
- **删除**：仅会话级，无单消息删除（检查范围：方法注册表 + 桌面 grep `deleteSession`）。软删原语 `rewind_to_message`（`hermes_state.py:9084`，id≥target 全部 `active=0`）只服务 `/rewind` 命令。
- **重试**：无 `session.retry`，`truncate_after` 概念本仓库不存在（grep 仅命中无关测试名）。三套实现共享“截断到最后一个真实 user turn 后重发”语义，真实 user turn 判定 = `role=="user" and not display_kind`（跳过 model_switch/auto_continue/personality_switch 等时间线条目，`methods_session.py` 近 :2442 处）：TUI `/retry`（`ui-tui/src/app/slash/commands/core.ts:744-768`：undo → trimLastExchange → 重发）、slash.exec 旧路由（`methods_tools.py`）、桌面 reload/regenerate（`rewind.ts:140` `planReload`）。CLI 对照 `cli.py:8398 retry_last()`。执行侧如何选择起始上下文在对话请求与上下文笔记 §7。
- **续写**：无 `/continue` 命令、无独立 RPC，就是普通 `prompt.submit` 文本 “continue”（busy 时也只入队）。空响应恢复会重放 `assistant("(empty)")`，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`turn_finalizer.py`）。
- **分支**：`session.branch`（`methods_session.py:2760` 起）：可选 `count` 截断复制历史 → 新 `session_key` + `model_config={"_branched_from": old_key}` + `parent_session_id=old_key` → `append_messages_batch` 分块复制（chunk 500，保留原 timestamp）→ 标题 `get_next_title_in_lineage` 生成 `"xxx #2"` → 父会话保持 live；返回 `{session_id, stored_session_id, parent, messages}`。分支种子在首次 prompt 时经 `_persist_branch_seed` 落库（`server.py:2859`）。桌面 fork：live 会话用 `session.branch`，无 live 源时 `session.create` + `parent_session_id` + messages 种子（`use-session-actions/index.ts:1178` `forkBranch`）。
- **版本切换**：无 checkpoint 版本 RPC。`session.history` 读含祖先的全量正序历史（`include_ancestors=True`，`methods_session.py:2442`）。`session.steer`（`:3219`）与 `session.redirect` 是运行中干预，不新增持久化对象，执行语义在对话请求与上下文笔记 §7。

## 5. 列表、分页、搜索与定位

### 5.1 会话列表

- TUI `session.list`（`methods_session.py:162-211`）：`limit` 默认 200、单页无 offset，超取后 Python 过滤 deny 列表 `{"kanban","tool"}`，按最近活跃排序。
- REST `GET /api/sessions`（`hermes_cli/web_routers/sessions.py:50-163`）：`limit`（默认 20、上限 100）、`offset`、`min_messages`、`archived`、`order=created|recent`、`source(s)` 过滤。
- 底层 `list_sessions_rich`（`hermes_state.py:7104`）：单查询 + 预览子查询（取首个 user 消息）；`include_pinned` 把被 LIMIT 挤出的置顶会话回填；最近活跃按压缩链递归 CTE 取 `effective_last_active` 并在 SQL 层 LIMIT；默认排除子代理会话（`_LISTABLE_CHILD_SQL` + `_delegate_from IS NULL`，`hermes_state_common.py:103`）。pin 增加后端持久化（`cef7d1a1`：REST 镜像 pin 不再 400）与列表层 `_lineage_root_id` 参与分页去重。
- 桌面侧栏走 `/api/profiles/sessions/sidebar` 分 profile 分片（`hermes.ts:427-640`），`SIDEBAR_SESSIONS_PAGE_SIZE` + `loadMoreSessions` 翻页（`use-session-list-actions.ts:264`）；侧栏界面工作流与虚拟列表呈现见 Chat UI 笔记 §2。

### 5.2 消息列表

- REST `GET /api/sessions/{id}/messages`（`sessions.py:598-630`）：`limit≤500`，正序 `ORDER BY id`（不用 timestamp，防 WSL2/NTP 时钟回拨打乱 tool_call 邻接，`hermes_state.py` 注释）。
- `get_messages_as_conversation`（`hermes_state.py:8655`）：`ORDER BY id` 正序；`include_ancestors` 先走 lineage 链；`repair_alternation` 供 LIVE REPLAY；祖先链同文 user 行去重。支持**键集分页**（`e8b05dc6`：dashboard 流式导出 keyset 分页）与 `show earlier` 数据侧（`31459ef0` 等，见 Chat UI 笔记）。
- 桌面端直播 transcript 不分页：resume 整段返回（`methods_session.py:545`）。

### 5.3 搜索

`search_messages`（`hermes_state_search.py:1410` → `_search_messages_impl` :1699）：

- 范围：全 `messages` 表 + FTS 索引，不搜 sessions 表；rewind/undo 行（`active=0 AND compacted=0`）默认隐藏，压缩归档行默认可见。
- 索引矩阵：`messages_fts`（unicode61）、`messages_fts_cjk`（bigram，绝大多数 CJK 查询）、`messages_fts_trigram`（≥3 CJK 字）、LIKE 兜底（短/混合 CJK 或 role=tool）。tool 行不进 cjk/trigram 索引（约 90% 字节是机器噪声）。
- 命中定位：FTS 路径 `snippet` 前后端标；LIKE 路径 `instr` + 前后字符切片；`context` 字段返回命中前后各 1 条；结果默认剥掉 `content` 只留 snippet。补充了 FTS5 特殊字符剥离（`c595dcb9`/`90311ee7`：非 CJK 查询剥离 `%` 等，防 sanitizer 漏网）。
- 会话 id 搜索：`search_sessions_by_id`（`:2283`）exact/prefix/substring 三级评分，`_lineage_root_id` 也参与匹配；REST `GET /api/sessions/search` 按压缩链 root 去重（`sessions.py:166-389`）。

### 5.4 列表窗口化边界

列表窗口化、滚动锚定、渲染预算与 `content-visibility` 属于消息渲染器笔记（`../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md`，§3 列表层）；本笔记只记录数据分页接口：REST `limit/offset`、`Show earlier` 分页的数据侧（resume 整段返回）与侧栏翻页接口。

## 6. 缓存、一致性、多窗口与并发写入

桌面端把后端事件投影进本地状态，三原则（合并而非覆盖 / 先乐观后诚实 / 拒绝乱序回写）对应的数据一致性语义：

- **合并而非覆盖**：`mergeSessionPage` 保留 working/pinned/刚 settle 行，按 `_lineage_root_id` 去重防压缩轮转后双行（`session.ts:393`）；`sessionsToKeep` 定义保留集（`use-session-list-actions.ts:58`）；刷新结果签名门控保持引用同一（:209-213）。
- **先乐观后诚实**：`seedOptimistic` 先插用户气泡、失败路径回滚并追加错误气泡；rewind/edit 失败回滚完整历史（`use-prompt-actions/index.ts:878-909`）。
- **拒绝乱序回写**：`refreshSessionsRequestRef` 请求代际单调递增、过期响应丢弃（`use-session-list-actions.ts:151-152, 190`）；视图发布只接受当前 active 会话 + rAF 合并、flush 前再验 sessionId（`use-session-state-cache.ts:210` 附近）。
- **多 profile 同步**：每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41`）；重连成功后丢弃过期 runtime id（`resetTileRuntimeBindings`），再 `refreshSessions` 重新同步（连接生命周期见 Chat UI 笔记）。
- **压缩轮转的数据一致性**：轮转后 flush 基线重置；`_sync_session_key_after_compress` 重锚 session_key（`server.py:4919`：会话配额租约迁移、yolo 状态迁移）。新增**回合租约（turn lease）**：session 层 turn 租约超时 fail-closed（`b3e9e917`/`29af112c`/`b2b681fe`，`gateway/turn_lease.py`），会话持久化失败按类型分类（锁竞争 vs 磁盘满，`2a9f5b34`），不再一律报 "unknown error"（`01bc8a87`）。

## 7. 迁移、导入导出与保留策略

- `SCHEMA_VERSION=25`（`hermes_state_common.py:207`）；v25 起系统提示词去重到 `system_prompts` 表（`system_prompt_hash`）。
- 导出：`session.save` 写 JSON 到 `~/.hermes/sessions/saved/`，不写 DB（3.2）。
- 保留：归档 `archived=1` 不删数据；硬删除无回收站不可恢复；`end_session` 只标记 `ended_at/end_reason`。
- 崩溃恢复语义见 §3.4；导入/备份恢复未在本次调查范围内验证。

## 8. Agent、模型、知识库与附件绑定

- **绑定粒度是会话级**。每次 `session.create/resume/branch` 都 `_make_agent`（`server.py:6489`）+ `_init_session`（`:6677`）；`model_override`/`create_reasoning_override` 为每会话字段（`methods_session.py:50-71, 96-98`）。运行中 `/model` 切换 = `_apply_model_switch`（`server.py:4484`）换 agent 客户端，工具集不中途更换；切换以 `model_switch` display_kind 时间线条目入史，不计入 user 轮计数。
- **子代理**：`delegate_tool.py:1305` 起 `_build_child_agent` 构造 `AIAgent(platform="subagent", session_db=父会话共享句柄, parent_session_id, skip_memory, quiet_mode)`；子代理有独立 session_id（`agent_init.py`），首轮惰性落行时写 `_delegate_from` 标记（`delegate_tool.py:1679`）。列表隐藏是双层：`_LISTABLE_CHILD_SQL` 排除无 `_branched_from` 的子会话（`hermes_state_common.py:103`）+ `_delegate_from IS NULL` 显式排除（`hermes_state.py:7197` 附近），父删除后孤儿化仍隐藏。删除时沿标记递归级联（`_collect_delegate_child_ids`，`hermes_state.py:287`，未标记子会话走“孤儿化不删”契约防环）。
- **工具调用的消息表示**：assistant 行带 `tool_calls`；结果经 `make_tool_result_message` 落 `{"role":"tool", tool_call_id, ...}` 行，高风险工具内容包 `<untrusted_tool_result>`（`tool_dispatch_helpers.py`）；中断/取消工具写 `effect_disposition="none"` 占位（`tool_executor.py`）。持久化映射见 §1（`run_agent.py`）；UI 投影 `_history_to_messages` 中 tool 行渲染为 `{role:"tool", name, context}`（`server.py:7136`），assistant 的 tool_calls 不单独成行。
- **附件（数据侧）**：无附件表，图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成 `[screenshot]`（`run_agent.py`）；`[[Image N]]` 指引本次未找到（全仓库 grep 零命中）。桌面拖放/上传管线属于 Chat UI 笔记 §3，提交注入点属于对话请求与上下文笔记 §9。

## 9. 设计取舍与已确认边界

- **惰性 DB 行**：首次真实 turn 才落行，空草稿不留痕；显式 `/title` 属明确意图，会现建行。
- **单事务批量落盘 + marker 去重**：一轮消息一次 `BEGIN IMMEDIATE/COMMIT`，失败不盖章、下轮全量重扫；`_finalize_session` 的关闭 flush 不带 `conversation_history`，防止“全部消息按身份视为已持久化”的丢尾。
- **轮转 vs 原地压缩**：轮转生成新 session_id 并连链（推荐路径），原地压缩同 ID 软归档；两者都以 `active=0/compacted=1` 保留旧行，压缩归档行仍可搜索。
- **双 ID 边界**：`sid` 进程内、`session_key` 持久；跨轮转稳定性由派生 `_lineage_root_id` 提供，桌面端把 pin/草稿作用域/路由匹配都键在 root 上。
- **编辑 = 截断重发**：无消息级原地编辑与单消息删除（本次未找到，检查范围见 §4）；软删只服务 `/rewind`。
- **崩溃恢复靠标记文件**：SQLite 只在 turn 结束写，`interrupted_turns.json` 是唯一中途痕迹，resume 时自动重放且 attempts 防循环。
- **FTS 排除 tool 行**：cjk/trigram 索引明确跳过 `role='tool'`（约 90% 字节为机器噪声），tool 内容走 LIKE 兜底。
- **JSONL 消息日志已移除**：`state.db` 是唯一规范存储；残余 JSONL（trajectory、moa-trace、spawn 树）均非消息主存储。
- **子代理级联删除契约**：标记子会话递归级联删除，未标记子会话“孤儿化不删”防环（§8）。

## 10. 未验证事项

- FTS 实际线上布局、触发重建与 trigram 命中效果未验证。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证。
- 崩溃恢复、多窗口并发写入、大数据量搜索需运行验证（静态代码只能确认事务、索引与写入入口）。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- REST 路由挂载点（`hermes_cli/web_server.py`）未逐行核对。
- 运行行为（视觉效果、时序、性能）全部为静态推断，未运行验证。

## 11. 关键源码索引

- Schema：`hermes_state_common.py`——`sessions`（:207）、`messages`（:265）、FTS、子会话判定（:85-114）、`SCHEMA_VERSION=25`（:167）。
- `hermes_state.py`：`create_session`（:3859）、`append_messages_batch`（:7781）、`replace_messages`（:8187）、`rewind_to_message`（:9084）、`set_session_archived`（:6750）、`delete_session`（:9526）、`get_messages_as_conversation`（:8655）、`list_sessions_rich`（:7104）、`get_resume_conversations`（:8854）、`publish_compression_child`（:4670）/`archive_and_compact`（:8287）、`_lineage_root_id` 派生（:7464）、`set_auto_title`（:6688，标题 provenance compare-and-swap）。
- 运行与持久化：`run_agent.py`——`_persist_session`（:1900）、`_flush_messages_to_session_db_unlocked`（:2010）、`_ensure_db_session`（:628）。
- session 方法：`tui_gateway/methods_session.py`——create（:14）、list（:162）、resume（:306）、delete（:972）、save（:2676）、close（:2748）、branch（:2760）、history（:2442）、title（:1022）、interrupt（:2942）、steer（:3219）。
- 崩溃标记：`tui_gateway/turn_marker.py`；标题：`agent/title_generator.py`（`derive_title` :250、`apply_instant_title` :474、`auto_title_session` :508）；搜索：`hermes_state_search.py` `search_messages`（:1410）、`search_sessions_by_id`（:2283）。
- 子代理：`tools/delegate_tool.py` `_build_child_agent`（:1305）、`_delegate_from` 标记（:1679）。
- 桌面端数据投影：`apps/desktop/src/types/hermes.ts`（`SessionMessage`）、`lib/chat-messages.ts`（`ChatMessage` :13、`toChatMessages`）、`store/session.ts`（`mergeSessionPage` :393、`sessionPinId` :246、`lineageAliases` :307）、`use-session-list-actions.ts`（:58、:151-152、:190、:264）。
