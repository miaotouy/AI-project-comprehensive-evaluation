# Hermes Agent 会话与消息管理调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（git 仓库）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：直接阅读源码（Python Agent 会话运行时、`hermes_state` 兄弟模块、SQLite 存储、JSON-RPC 契约、桌面端与 TUI 前端实现），符号按当前快照逐一复核；行号只在复核过的位置给出，其余用文件加符号定位；行为类结论区分源码事实与静态推断
>
> 调查范围：会话、消息与分支的数据模型、事实源与持久化、单写者与回合租约、生命周期（创建/切换/归档/删除/恢复）、编辑重试与分支语义、列表分页搜索、一致性并发、迁移导入导出与外部对象绑定粒度。请求执行（上下文拼装、流式、压缩触发与中断）与界面工作流分别进入对话请求与上下文、Chat UI 类目；消息渲染器类目记录内容渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **后端是唯一真相源**。会话与消息全部落在 profile 作用域下的单一 SQLite（`state.db`），schema 版本 32。桌面端各会话原子只是这份真相的缓存，更新时遵循合并、先乐观后诚实、拒绝乱序回写三条原则（`apps/desktop/AGENTS.md`）。
- **写入者已收敛为单写者**。经典 CLI 不再直接持有写句柄：`HermesCLI._session_db` 被替换成「只读 `state.db` 读取器 + gateway 动词」的组合，读取走只读连接；尚未接入 gateway 的写入直接抛 `GatewayClientError`（`hermes_cli/gateway_session_store.py`）。写入按四个网关动词分流（模块 docstring）：
  - `session.create`
  - `session.resume`
  - `session.mutate`
  - `session.detach`
- **身份分两层**。进程内 UI 句柄是 `sid`（8 位 hex），落库主键是 `session_key`（时间戳 + 6 位 hex），后者在响应里称作 `stored_session_id`。
  - `sid` 在 `tui_gateway/methods_session.py` 生成，`session_key` 由 `tui_gateway/session_registry.py` 的 `_new_session_key` 生成。
  - 压缩轮转生成新 key，新旧会话经 `parent_session_id` 与 `end_reason='compression'` 连链；跨轮转稳定的标识是派生字段 `_lineage_root_id`。
- **子会话有四类**：分支、压缩续链、子代理与重置，各由来源标记判定，列表可见性也按此区分（判定 SQL 见 §1.2）。分支用 `_branched_from`，压缩续链看父行的结束原因，子代理用 `_delegate_from`，重置用 `_reset_from`；重置出的会话在列表里独立可见，仍保留 `parent_session_id` 维持血缘（`hermes_state_common.py:228-247`）。
- **消息持久化与执行受理分层**。关系表一行一条消息，软状态区分活动和压缩归档；Agent 增量 flush 使用内存 marker 去重。规范网关另持久化输入受理与执行代际：同主体、目标会话、请求 id 的相同 payload 返回原回执，变更 payload 报冲突；owner 重启把已开始的旧代际工作结算为 unknown，阻塞后续队列，避免自动重复副作用（[受理事务](../../hermes-agent/hermes_state_runtime.py#L130-L177)、[恢复](../../hermes-agent/hermes_state_runtime.py#L453-L464)）。
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
  -> 规范输入账本：重启后已开始输入变 unknown，后续队列暂停等待明确处置
  -> legacy tui_gateway 另有 desktop/interrupted_turns.json 恢复路径
```

边界：上下文拼装、Provider 调用、流式事件、压缩触发与中断属于对话请求与上下文（`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`）；会话侧栏、消息操作等界面工作流属于 Chat UI；消息内容与列表渲染属于消息渲染器类目，本笔记只记录数据形状与数据分页接口。

以下 sid、legacy 方法与中断标记细节按 tui_gateway 桥解释；规范网关另外拥有 profile/会话授权引用、输入受理账本与执行代际，恢复边界见摘要。静态复核覆盖两者入口差异，未穷尽所有客户端迁移分支。

## 1. 会话、消息与分支数据模型

### 1.1 会话（Session）

`sessions` 表 DDL 在 `hermes_state_common.py:461`，`SCHEMA_VERSION = 32`（`hermes_state_common.py:289`）。字段按用途分六组：

| 字段组 | 字段 | 说明 |
|---|---|---|
| 标识与血缘 | `id`、`parent_session_id` | `id` 主键即持久 `session_key`；`parent_session_id` 是血缘与轮转链的唯一关联字段 |
| 入口 | `source` | 取 `cli`/`tui`/`telegram`/`subagent` 等入口值 |
| 生命周期 | `started_at`、`ended_at`、`end_reason` | 会话起止时间与结束原因 |
| 标题与配置 | `title`、`title_source`、`model_config` | `model_config` 为 JSON，含 `_branched_from`/`_delegate_from`/`_reset_from` 标记 |
| 提示词 | `system_prompt`、`system_prompt_hash` | v25 起提示词去重到 `system_prompts` 表（`hermes_state_common.py:456`） |
| 软状态与聚合 | `archived`、`pinned`、`message_count`、`tool_call_count` | 软状态与计数，另含 token 计数与压缩冷却字段 |
| 工作环境 | `cwd`、`git_branch`、`git_repo_root`、`last_activity_at` | 工作目录、git 仓库与最近活动时间 |

会话 ID 生成统一为"时间戳 + 6 位随机 hex"：网关实现 `_new_session_key`（`tui_gateway/session_registry.py:392`），gateway 消息平台用 8 位 hex（`gateway/session.py`）。

TUI/桌面另有进程内句柄 `sid`，返回给前端的是它，DB 行主键是 `stored_session_id`（`tui_gateway/methods_session.py`）。

### 1.2 子会话与轮转链

子会话按来源判定，SQL 片段集中在 `hermes_state_common.py:171-247`：

- 分支子会话：`_branched_from` 标记，或旧式父 `end_reason='branched'` 启发式（`_BRANCH_CHILD_SQL`）；
- 压缩续链：父 `end_reason='compression'`（`_COMPRESSION_CHILD_SQL`）；
- 重置子会话：`_reset_from` 标记，或旧式同 key 回退（`_RESET_CHILD_SQL`），代表一次"从同一会话分出新对话"；
- 子代理：`_delegate_from` 标记，可级联删除（`_ephemeral_child_sql`）。

标记与父 id 绑定：续链会话原样继承 `model_config`，因此指向别行的标记属继承而非 fork（`_LINEAGE_MARKER_SQL` 的 docstring）。列表可见行 = 根 + 分支/重置子会话（`_LISTABLE_CHILD_SQL`），不含子代理与压缩续链。

链遍历工具由兄弟模块提供：

- `get_compression_lineage`（`hermes_state_compression.py:916`）：沿压缩链取全链；
- `get_compression_tip`（`:897`）：只沿 compression 边取 tip；
- `resolve_resume_session_id`（`hermes_state_messages.py:1452`）：解析 resume 目标；
- `_session_lineage_root_to_tip`（`hermes_state_sessions.py:1526`）：root→tip 遍历（上限 100 层）。

压缩轮转与原地压缩的对照：

- **轮转**：生成新 session_id → `publish_compression_child`（`hermes_state_compression.py:373`）单事务插入子行（继承 cwd/git/profile/gateway origin、携带标题与压缩后消息）并写压缩后消息、父行 `end_reason='compression'` → 切换 `agent.session_id` → flush 基线重置；
- **原地压缩**：`archive_and_compact`（`hermes_state_messages.py:907`）不轮转 ID，软归档 `active=0, compacted=1`，同一会话 ID 贯穿一生。

压缩的触发与预算语义在对话请求与上下文笔记 §3。

### 1.3 消息行（ChatMessage / SessionMessage）

后端 `messages` 表 DDL 在 `hermes_state_common.py:531`，一行一条消息，字段按用途分六组：

| 字段组 | 字段 | 说明 |
|---|---|---|
| 角色与内容 | `role`、`content` | `role` 取 user/assistant/tool |
| 工具关联 | `tool_call_id`、`tool_calls`、`tool_name`、`effect_disposition` | `tool_calls` 为 JSON 数组 |
| 推理与多模态 | `reasoning`、`reasoning_content`、`reasoning_details`、`codex_reasoning_items`、`codex_message_items` | 多模态 content 经 `_encode_content` 做 JSON 编码（`hermes_state_messages.py:140`） |
| 时序与外部标识 | `timestamp`、`finish_reason`、`token_count`、`platform_message_id` | `platform_message_id` 是网关平台侧 ID |
| 软状态 | `active`、`compacted`、`observed` | 三个软状态位 |
| 展示投影 | `display_kind`、`display_metadata` | `display_metadata` 承载 `model_switch`/`personality_switch` 等时间线条目与 `hidden` |
| API 保真 | `api_content` | 发给 API 的字节保真 sidecar，恢复时原样返回（`_rows_to_conversation`，`hermes_state_messages.py:1571`） |

重建历史时，过期的 `api_content` 由 `drop_stale_api_content`（`agent/turn_context.py`）丢弃。

索引：主索引 `idx_messages_session(session_id, timestamp)` 与 `idx_messages_session_id(session_id, id)`、assistant 且 `tool_calls` 非空的专用部分索引、`idx_messages_session_active` 延迟索引段，均在 `hermes_state_common.py` 的索引定义区。

工具结果与 assistant 调用靠 `tool_call_id` 关联，无独立子表。附件无表：图片经 `@image:` 指令或 vision 预分析转文本，落库时多模态图片部分被压成占位（`agent/tool_dispatch_helpers.py`）。

桌面端的渲染模型是 `ChatMessage`（`apps/desktop/src/lib/chat-messages/index.ts`），字段分为身份与角色、parts、状态（pending/error/hidden/interim）与外部引用（attachmentRefs/rowId/reactions）四组；后端的 `SessionMessage`（`apps/desktop/src/types/hermes.ts`）经 `toChatMessages` 转成该模型。part 渲染细节见消息渲染器笔记。

## 2. 事实源、单写者与持久化

### 2.1 事实源与写者

`state.db` 是唯一规范存储。当前快照的写入路径有三层：

- **Agent 进程内**：`_persist_session` 与 `_flush_messages_to_session_db_unlocked`（`agent/session_persistence.py:509, 548`）直接写 SessionDB；
- **网关单写者**：`hermes_cli/gateway_session_store.py` 用只读 reader 做读取，把写入翻译成 gateway 动词；未覆盖的写入抛 `GatewayClientError`（模块 docstring 与 `delete_session`/`end_session` 等适配方法）；
- **worker 持久化 facade**：`agent/runtime_session_store.py` 明确"显式 worker 持久化入口，从不打开规范 SQLite"，并注明尚未切换现有 cron/child/compute 消费者（模块 docstring）。

消息读路径只依赖 SQLite：代码中没有每会话 JSON 快照写入器（其门控为 `sessions.write_json_snapshots`，默认关闭），JSON 产物仅剩调试与观察类（trajectory、moa-trace、spawn 树）。`session.save` 仍会把会话导出成 JSON，落到 `~/.hermes/sessions/saved/hermes_conversation_<ts>.json`（`tui_gateway/methods_session.py:2160`）。

`api_content` 是发给 API 的字节保真 sidecar；桌面端各会话原子只是后端真相的缓存投影。

### 2.2 落盘与崩溃安全

- 内存消息 dict 上有一个去重标记 `_DB_PERSISTED_MARKER`，取值为 `_db_persisted`；下划线前缀保证它不会被送上 API 线。这个标记取代了按对象身份集合去重的做法，压缩路径引用的是同一常量（`agent/context_compressor.py:326`、`agent/context_compressor_prune.py`）。
- 落盘由 `_flush_messages_to_session_db_unlocked` 完成：先收集本回合新增的消息，再在单事务里批量调用 `append_messages_batch`，需要时分块写入，成功后才给消息盖章；失败则不盖章并清空扫描前缀，下回合全量重扫。完成、出错、关闭三条退出路径都会调用它，调用方是 `_persist_session`（`hermes_state_messages.py:430`）。
- 工具执行过程中会增量落库：`_flush_session_db_after_tool_progress` 在多个工具批次点被调用，用来应对工具杀死进程的场景（`agent/tool_executor.py:201`）。
- 崩溃痕迹是一个 JSON 标记文件，由 `tui_gateway/turn_marker.py` 读写。

  路径为 `<home>/desktop/interrupted_turns.json`（由 `_marker_path` 生成）：回合开始写标记，凡「客户端已见到结果」的结局都清除标记；写入与清除两个入口同在 `tui_gateway/turn_marker.py:124,140`。

  `session.resume` 的自动续跑读这个文件，据此判断是否需要重放。

  标记上限 32 条 / 24 小时 / 64KB 提示词，写入时取跨进程文件锁（`hermes_cli.auth._file_lock`），避免同机多后端互相复活标记；每条标记带写入者 pid 与启动时间，用来区分「标记存在」与「写者已死」（`#94778`）。
- 中途断连的另一层恢复是 `_fail_inflight_turn`（`tui_gateway/session_history.py:447`）保留的可重放快照，经 `session.resume` 的 `inflight` payload 承载，见对话请求笔记 §6。

### 2.3 标题（两段式 + 带来源）

`agent/title_generator.py` 的命名是两段式 + 带来源：

- **即时标题（derived）**：会话首个 turn 的 prologue 里同步生成一个占位标题，不调用模型、不会失败。入口是 `_maybe_title_session_at_turn_start`（`agent/turn_context.py:201`），经 `maybe_auto_title` 派发到标题模块（`agent/title_generator.py:333-736`）：
  - `apply_instant_title` 调 `derive_title` 取开场消息的首个有效行、折叠空白，并按 `MAX_DERIVED_TITLE_CHARS=48` 在词边界截断，用户发出首条消息后立即可见；
  - 斜杠命令等控制包装先由 `is_titleable_user_message` 剥离；
  - 随后 `auto_title_session` 在后台线程用小模型升级标题，输出约束为 JSON `{"title": ...}`。
- **来源与覆盖**：标题来源按 derived、llm、user 由低到高排序，覆盖判断与写入在同一条事务内完成，相当于一次带优先级比较的 compare-and-swap。自动标题入口是 `set_auto_title`，只在来源优先级更高时改写，内部经 `_set_session_title` 与 `_set_session_title_in_transaction` 落库（`hermes_state_titles.py:83-170`）。

  用户 `/title` 记为 `user` 来源，此后自动标题不再覆盖；legacy 的 NULL 来源行按 user 计，自动标题只填空缺。同链重名时由 `get_next_title_in_lineage`（`hermes_state_titles.py:222`）加 `#N` 后缀。
- **压缩轮转携带标题**：轮转前取父标题，轮转后在新会话行重写同一标题并恢复原 provenance，不再对每个 fork/轮转重编号。
- 桌面/TUI 侧通过 `session.title` 事件即时刷新侧栏；未命名会话由新标题逻辑补名，TTS 模型/脚手架回合不触发命名。

## 3. 创建、切换、归档、删除与恢复

### 3.1 契约与实现分层

JSON-RPC 方法在 `tui_gateway/contracts/sessions.py` 中以声明式契约定义（`method("session.resume" …)` 等，参数与结果各有 schema），实现分散在 `tui_gateway/session_*.py` 兄弟模块：

- 会话注册模块 `session_registry.py` 负责注册会话、用 `_new_session_key` 生成 `session_key`，并等待 agent 构建完成；
- 工作目录模块 `session_workdir.py` 负责首次 prompt 的 DB 行落库与分支种子持久化（`_ensure_session_db_row`、`_persist_branch_seed`，`:588-682`）；
- 生命周期模块 `session_lifecycle.py` 负责会话关闭的收尾路径（`_finalize_session`，`:430`）；
- 压缩模块 `session_compression.py` 负责轮转之后的 key 重锚等衔接动作（`_sync_session_key_after_compress`，`:313`）；
- 历史模块 `session_history.py` 负责历史投影与中断回合快照（`_history_to_messages`、`_fail_inflight_turn`，`:297-447`）；
- 模型切换模块 `model_switch.py` 负责运行中换模型的落地（`_apply_model_switch`，`:311`）。

`tui_gateway/methods_session.py` 仍是方法实现的主要落点（`session.save` 的 JSON 导出于 `:2160`）。契约由 `scripts/gen_gateway_contracts.py` 生成/校验。

### 3.2 创建与惰性落行

- 后端：`AIAgent._ensure_db_session`（`run_agent.py:315`）在首次 turn 时调用 `create_session` 及其插入辅助函数，失败保活、下轮重试（`hermes_state_sessions.py:369,416`）；
- TUI：`_ensure_session_db_row`（`tui_gateway/session_workdir.py:588`）也在首次 prompt 时落行，废弃草稿不留行。

`create_session` 在 ON CONFLICT 时从父行继承 cwd/git/profile。

### 3.3 resume / close / save

- `session.resume` 恢复会话时先沿压缩链定位活跃 tip，再重开会话取出两份历史投影，最后检查转录条数上限：
  1. `resolve_resume_session_id` 沿压缩链跳到活的 tip；
  2. `reopen_session` 清除 `ended_at` 与 `end_reason`（`hermes_state_sessions.py:519`）；
  3. 取恢复历史时由 `get_resume_conversations` 一次 SELECT 出两份投影——模型喂入用修复交替版、显示用原样版，悬空的 tool 尾巴由 `sanitize_replay_history` 去掉（`hermes_state_messages.py:1452-1667`、`agent/replay_cleanup.py:147`）；
  4. resume 受转录安全上限约束：配置键 `sessions.max_resume_messages` 默认 20,000、设 0 关闭，取值经 `resolved_max_resume_messages` 解析（`hermes_state.py:109`）。

     超限时抛 `SessionResumeTooLargeError`（`hermes_state.py:117`），错误信息把用户指向导出与 `max_resume_messages` 调参；导出侧另有 `sessions.max_export_messages`，取值由 `resolved_max_export_messages` 解析。
- `session.close` 的收尾由 `_finalize_session` 完成，它经 `_teardown_popped_session` 转发，依次做三件事（`tui_gateway/session_lifecycle.py:430`）：
  - flush 未写消息，此处特意不传 `conversation_history`，否则全部消息会按对象身份被当成已持久化而跳过；
  - 调 `on_session_end` hook；
  - 由 `end_session` 写入 `ended_at`/`end_reason`。

  结束原因按 first-reason-wins 保留首个，gateway 来源的会话不归 TUI 所有、不标记。这一步全程只改状态，不删数据。
- `session.save` 不写库，只把会话连同 system prompt 导出成 JSON，落在 `~/.hermes/sessions/saved/`（`tui_gateway/methods_session.py:2160`）。

### 3.4 删除与归档

- `session.delete` 拒绝删除进程内仍在活跃的会话；实际删除由 `delete_session` 执行，它在同一轮操作里硬删 `messages` 与 `sessions` 行，并分三类处理关联：
  - 子代理按 delegate 标记递归级联（`_collect_delegate_child_ids`）；
  - 分支、压缩、重置产生的子会话把 `parent_session_id` 置空后保留；
  - 磁盘上的转录文件一并清理（`hermes_state_sessions.py:193`）。
- 归档与删除并存：`archived=1` 只做软隐藏，默认列表不显示但消息保留，`set_session_archived` 会沿整条压缩链递归翻转该标记（`hermes_state_sessions.py:953`）；系统没有回收站，硬删除后不可恢复。
- 空会话清理：`delete_session_if_empty` 在单条事务里判断会话既无消息、也无用户标题和子会话，再由 CLI 退出或轮转路径调用（`hermes_state_sessions.py:1791`）；网关侧的同语义适配在 `hermes_cli/gateway_session_store.py:337`。

### 3.5 恢复与保留语义

- 崩溃恢复：规范网关保存一份输入受理账本，重启后旧 owner 已经开始处理的输入被标为 unknown，后续输入先阻塞等待明确处置；legacy 的 tui_gateway 则在 resume 时消费中断标记。Agent 的 flush 发生在工具进展与回合终结两个时点，回合结束写库只覆盖后者（[代际恢复](../../hermes-agent/hermes_state_runtime.py#L453-L464)）。
- 压缩轮转后的恢复：resume 沿压缩链跳到活跃 tip，`get_resume_conversations` 同时给出模型喂入与显示两份投影；跨轮转稳定的身份来自派生字段 `_lineage_root_id`，桌面端的 pin 与路由匹配都以它为基准（`hermes_state_local.py:381`、`hermes_state_search.py:1432`）。
- 保留语义：轮转与原地压缩都用 `active=0` 和 `compacted=1` 保留旧行，压缩归档行仍可被搜索；`end_session` 只写结束标记，硬删除没有回收站。
- `/retry` 与编辑/rewind 截断都以破坏性改写的方式保留归档历史：`replace_messages` 接收 `active_only` 与 `archive_dropped` 两个开关，被替换的轮次落盘为可搜索的归档行（`hermes_state_messages.py:720`）。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑 = 截断 + 重发**：桌面端编辑消息时没有专用 RPC 入口（`session.edit` 与 `message.edit` 均不存在，检查范围是 `tui_gateway/contracts/sessions.py` 的方法声明与桌面端消息操作代码），实际动作分三处完成：
  1. 桌面端点开编辑 composer 后发送，等于「中断再回退」（interrupt + rewind）；
  2. 请求参数带 `truncate_before_user_ordinal`，把历史截断到目标轮次；
  3. 服务端以单事务 DELETE + 重插替换消息（`db.replace_messages`），随后改写内存历史并把 `history_version` 加一；压缩已结束的会话在这一步抛 `CompressionSessionClosedError`（`hermes_state_messages.py:720`）。
- **删除**：仅会话级，没有单消息删除（检查范围同上）。软删原语 `rewind_to_message` 把 id 大于等于目标的记录全部置 `active=0`，只服务 `/rewind` 命令；`session.undo` 是进程内的历史截断（`hermes_state_messages.py:1850`）。
- **重试**：TUI 的 `/retry` 与 slash 命令、桌面 reload/regenerate、CLI 的重试入口都执行同一种重试，即截断到最后一个真实 user turn 后重发。真实 user turn 的判据是角色为 user、没有 `display_kind`、且不属于压缩摘要或合成轮，判据函数见 `agent/context_compressor.py:5735`；`session.retry` 不存在（检查范围同上）。
- **续写**：用户续写时直接发送 `prompt.submit` 文本即可，没有 `/continue` 命令与独立 RPC。空响应恢复会重放空的 assistant 消息，持久化前由 `_drop_trailing_empty_response_scaffolding` 删除（`agent/session_persistence.py:530`）。
- **分支**：分支从现有会话派生出一个新会话，父会话保持 live，接口返回 `{session_id, stored_session_id, parent, messages}`，契约在 `tui_gateway/contracts/sessions.py` 的 `session.branch`。执行分四步：
  1. 可选按 `count` 截断后复制历史；
  2. 生成新 `session_key`，写入 `model_config={"_branched_from": old_key}` 与 `parent_session_id=old_key`；
  3. 用 `append_messages_batch` 分块复制消息，保留原 timestamp；
  4. 标题经 `get_next_title_in_lineage` 生成 `"xxx #2"`。

  分支种子在首次 prompt 时经 `_persist_branch_seed`（`tui_gateway/session_workdir.py:682`）落库；桌面 fork 在没有 live 源时改走 `session.create`，加 `parent_session_id` 与消息种子。
- **版本切换与邻近操作**：检查点版本没有独立 RPC，现有历史读取、运行中干预与撤销分别承担不同职责：
  - 历史读取通过 `session.history` 返回含祖先链的全量消息。
  - 运行中干预中的 steer 作为独立 user 行加入并持久化，已有工具结果保持原样（`agent/agent_runtime_helpers.py:3668-3705`）；redirect 与具体执行语义见对话请求与上下文笔记 §7。
  - 撤销通过 `session.undo` 截断进程内历史并递增 history_version；运行中拒绝调用，截断仍按真实用户轮判据处理。

## 5. 列表、分页、搜索与定位

### 5.1 会话列表

- TUI 的 `session.list` 默认取 200 条、单页没有 offset，多取的部分由 Python 侧按 deny 列表 `{"kanban","tool"}` 过滤，结果按最近活跃排序。
- REST 接口 `GET /api/sessions` 支持分页与过滤（`hermes_cli/web_routers/sessions.py`）：
  - 分页：`limit` 默认 20、上限 100，配合 `offset` 使用；
  - 过滤：`min_messages`、`archived`、`source(s)`。
- 底层列表由 `list_sessions_rich` 用一条查询完成：预览取首个 user 消息，`include_pinned` 把被 LIMIT 挤出的置顶会话回填，再按压缩链递归 CTE 取 tip 的最近活跃时间（`effective_last_active`）并在 SQL 层 LIMIT（`hermes_state_sessions.py:1303`）。
- 列表默认排除子代理与压缩续链会话：`_LISTABLE_CHILD_SQL` 负责子会话判定，之后还要求 `_delegate_from IS NULL` 才能入列；压缩链的 root 投影到活跃 tip 做逻辑去重。网关侧的同语义适配在 `hermes_cli/gateway_session_store.py:448`。
- 桌面侧栏走 `/api/profiles/sessions/sidebar`，按 profile 分片请求，包含 recents、cron、messaging 三个切片并带旧端点兼容回退，`SIDEBAR_SESSIONS_PAGE_SIZE` 与 `loadMoreSessions` 负责翻页（`apps/desktop/src/hermes.ts` 的 `listAllProfileSessions`）。侧栏界面工作流与虚拟列表呈现见 Chat UI 笔记 §1。

### 5.2 消息列表

- REST `GET /api/sessions/{id}/messages`：`limit` 上限 500，`order=oldest` 从头翻页、缺省/`latest` 返回最新一页；请求 id 先经 `resolve_session_id`，再沿压缩链归一到活跃 tip。
- `get_messages_as_conversation`（`hermes_state_messages.py:1517`）：`ORDER BY id` 正序（不用 timestamp，防 WSL2/NTP 时钟回拨打乱 tool_call 邻接）；`include_ancestors` 先走 lineage 链；`repair_alternation` 供 LIVE REPLAY。
- 桌面端直播 transcript 不分页：resume 整段返回。

### 5.3 搜索

- 搜索范围覆盖整张 `messages` 表及其 FTS 索引，不查 sessions 表；rewind/undo 留下的行（`active=0 AND compacted=0`）默认隐藏，压缩归档行默认可见。
- 索引按四路分工，tool 行不进 trigram 索引（约 90% 字节是机器噪声）：
  - `messages_fts`：fts5 unicode61 基表；
  - `messages_fts_cjk`：bigram 分词，承担绝大多数 CJK 查询；
  - `messages_fts_trigram`：≥3 个 CJK 字时使用，经排除 tool 行的视图；
  - LIKE 兜底：短或混合 CJK 查询、role=tool 时使用。
- 命中定位：FTS 路径用 `snippet(..., 40)` 截取片段，LIKE 路径用 `instr` 加前后字符切片；`context` 字段返回命中前后各 1 条，结果默认剥掉 `content` 只留 snippet。
- 入口是 `search_messages` 与会话 id 检索函数，后者按 exact、prefix、substring 三级评分并让 `_lineage_root_id` 参与匹配（`hermes_state_search.py:1257-1432`）；REST `GET /api/sessions/search` 按压缩链 root 去重，原生 SQLite 侧另有 `native/fts5_cjk` 扩展包承担 CJK 分词。

### 5.4 列表窗口化边界

列表窗口化、滚动锚定、渲染预算与 `content-visibility` 属于消息渲染器笔记（§3 列表层）；本笔记只记录数据分页接口：REST `limit/offset`、侧栏翻页接口、resume 整段返回。

## 6. 缓存、一致性、多窗口与并发写入

- **回合租约**：`gateway/turn_lease.py` 把「载入历史 → 运行 → flush」整段锁在解析后的 session_id 上。路由键与转录所有权是多对一关系（`switch_session()` 会让 key→id 多对一），租约用于防止两份 flush 在同一条转录上交叉。获取发生在转录载入之前，释放在分发层的 `finally` 里并做持有者身份校验；等待超时抛 `TurnLeaseTimeoutError` 并 fail-closed；空闲条目按 oldest-first 淘汰，活动租约永不淘汰，上限 512。
- **单写者**：经典 CLI 的写句柄被替换为「只读 reader + gateway 动词」，写入统一落到 gateway 进程，同一个库只保留这一个写者。
- **桌面端三原则**：
  - 合并分页时保留 working、pinned 与刚 settle 的行，并按 `_lineage_root_id` 去重，防止压缩轮转后出现双行（`mergeSessionPage`）；
  - 乐观插入先放用户气泡，失败时回滚并追加错误气泡（`seedOptimistic`）；
  - 请求代际单调递增，过期响应直接丢弃，视图发布只接受当前 active 会话并在 flush 前复验 sessionId（`refreshSessionsRequestRef`）。

  对应的实现模块是 `apps/desktop/src/store/session.ts`、`use-session-list-actions.ts` 与 `use-session-state-cache.ts`。
- **多 profile 同步**：每个活跃 profile 持有一条独立的二级 socket；重连成功后先丢弃过期的 runtime id 再 `refreshSessions` 重新同步（`apps/desktop/src/store/gateway.ts`、`use-gateway-boot.ts` 的 `resetTileRuntimeBindings`）。
- **压缩轮转的数据一致性**：轮转后 flush 基线重置，`_sync_session_key_after_compress` 重锚 session_key 并迁移会话配额租约与 yolo 状态；会话持久化失败按锁竞争与磁盘满两类处理，桌面端据此映射 "disk full" 提示（`tui_gateway/session_compression.py:313`）。

## 7. 迁移、导入导出与保留策略

- schema 目前是版本 32（`hermes_state_common.py:289`），系统提示词从 v25 起去重到 `system_prompts` 表。FTS 存储布局有自己的版本号 `FTS_STORAGE_VERSION`，与 schema 分开演进；旧库会一直停留在旧布局，直到用户执行 `hermes sessions optimize-storage`（版本比对见 `hermes_cli/session_recovery.py:21`）。schema 25 到 32 之间各版本的具体迁移步骤本次未逐版核对。
- 导出：`session.save` 把会话写成 JSON 放到 `~/.hermes/sessions/saved/`，不写数据库；CLI 另有 `hermes sessions export` 支持 md/html（见对话导出与分享笔记）。
- 保留：归档只隐藏不删数据，硬删除没有回收站，`end_session` 只写标记，`/retry` 与 rewind 的截断行落为归档行。
- 导入：`hermes_cli/session_recovery.py` 负责旧库恢复与版本修补（本次未逐行核对）。桌面端另外支持 Claude Code 与 Codex CLI 会话导入：发现器只读各工具本地会话目录，先返回按仓库、时间和标题整理的预览；确认后把外部 turns 归一成 Hermes 消息写入当前 profile 的 SQLite，metadata 保留来源与原会话身份，外部历史被标记为不可信静态内容（`hermes_cli/foreign_sessions.py`、`apps/desktop/src/app/session-import/index.tsx`）。

## 8. Agent、模型、知识库与附件绑定

- **绑定粒度是会话级**：每次创建、恢复或分支会话都会构造一个独立 Agent，并在 `_init_session_state` 里初始化会话状态；`model_override` 与 `create_reasoning_override` 都是每会话字段（`agent/agent_init.py:1096`）。
- **运行中 `/model` 切换**：`_apply_model_switch` 只替换 agent 客户端，工具集不在中途更换；这次切换以 `model_switch` 的 `display_kind` 时间线条目进入历史，不计入 user 轮计数（`tui_gateway/model_switch.py:311`）。
- **子代理**：`_build_child_agent` 为每种子代理构造独立的 Agent 实例，platform 记为 subagent；它共享父会话句柄与 `parent_session_id`，但有独立的 `session_id`，首轮惰性落行时写入 `_delegate_from` 标记（`tools/delegate_tool.py:203`）。

  列表隐藏由两层条件叠加：先按 `_LISTABLE_CHILD_SQL` 过滤，再要求 `_delegate_from IS NULL`。删除时沿 `_delegate_from` 标记递归级联（`_collect_delegate_child_ids`），未带标记的子会话只做孤儿化保留，以防删除成环。
- **工具调用的消息表示**：持久化层上，assistant 行携带 `tool_calls`，每条结果单独落一行 tool 角色记录；高风险工具的内容包在 `<untrusted_tool_result>` 里（`agent/tool_dispatch_helpers.py`），被中断或取消的工具写 `effect_disposition="none"` 占位（`agent/tool_executor.py`）。

  UI 投影里这些行改渲染为 `{role:"tool", name, context}`（`_history_to_messages`，`tui_gateway/session_history.py:297`），assistant 的 `tool_calls` 不单独成行。
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

索引按层归集：存储层是 schema 定义与 SessionDB 兄弟模块，运行层是 `agent/` 下的持久化、标题与工具实现，网关层是 `tui_gateway/` 的契约与适配，桌面投影在 `apps/desktop/src/`。符号后附的行号是当前快照中的定义位置，范围表示一段实现。

### 存储层

```text
hermes_state_common.py            Schema 与表结构
  SCHEMA_VERSION=32        :289
  system_prompts           :456
  sessions                 :461
  messages                 :531
  子会话 SQL 片段          :171-247

hermes_state_sessions.py          会话行创建、归档、删除与列表
  create_session           :416
  _insert_session_row      :369
  reopen_session           :519
  set_session_archived     :953
  list_sessions_rich       :1303
  _session_lineage_root_to_tip  :1526
  delete_session_if_empty  :1791
  _collect_delegate_child_ids   :193

hermes_state_messages.py          消息读写、截断与历史投影
  append_messages_batch    :430
  replace_messages         :720
  archive_and_compact      :907
  resolve_resume_session_id     :1452
  get_messages_as_conversation  :1517
  _rows_to_conversation    :1571
  get_resume_conversations :1667
  rewind_to_message        :1850

hermes_state_compression.py       压缩轮转与链遍历
  publish_compression_child     :373
  get_compression_tip      :897
  get_compression_lineage  :916

hermes_state_titles.py            标题来源与去重
  _set_session_title       :83
  set_auto_title           :170
  get_next_title_in_lineage     :222

hermes_state_search.py
  search_messages          :1257
  search_sessions_by_id    :1432

hermes_state_local.py
  _lineage_root_id 使用    :381
```

### 运行、持久化与工具

```text
run_agent.py
  _ensure_db_session       :315

agent/session_persistence.py
  _persist_session         :509
  _flush_messages_to_session_db_unlocked    :548
  _drop_trailing_empty_response_scaffolding :530

agent/context_compressor.py
  _DB_PERSISTED_MARKER     :326
  is_user_originated_turn  :5735

agent/tool_executor.py
  _flush_session_db_after_tool_progress     :201

agent/replay_cleanup.py
  sanitize_replay_history  :147

agent/runtime_session_store.py    worker 持久化 facade

agent/title_generator.py
  MAX_DERIVED_TITLE_CHARS  :54
  is_titleable_user_message     :333
  derive_title             :343
  apply_instant_title      :621
  auto_title_session       :642
  maybe_auto_title         :736

agent/turn_context.py      :201

tools/delegate_tool.py
  _build_child_agent       :203
```

### 网关契约与方法

```text
tui_gateway/contracts/sessions.py    方法契约
tui_gateway/session_{registry,workdir,lifecycle,compression,history}.py
tui_gateway/model_switch.py
tui_gateway/methods_session.py       session.save :2160
tui_gateway/turn_marker.py
  record_turn_start        :124
  clear_turn_marker        :140

hermes_cli/gateway_session_store.py  单写者适配
gateway/turn_lease.py                回合租约
hermes_cli/foreign_sessions.py       外部会话导入
hermes_cli/session_recovery.py       旧库恢复与版本修补
apps/desktop/src/app/session-import/index.tsx
```

### 桌面端数据投影

```text
apps/desktop/src/types/hermes.ts              SessionMessage
apps/desktop/src/lib/chat-messages/index.ts   ChatMessage、toChatMessages
apps/desktop/src/store/session.ts             mergeSessionPage、sessionPinId、lineageAliases
apps/desktop/src/app/session/hooks/use-session-list-actions.ts
```
