# Codex 会话与消息管理调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：静态源码走读 + 检索，未运行构建与测试
>
> 调查范围：Thread 标识与元数据、消息/事件的持久化形状、rollout JSONL 与 SQLite 事实源、创建/恢复/归档/删除/回退/分支语义、列表分页与检索、并发写入与迁移；单次请求的上下文拼装与执行见「对话请求与上下文」笔记，导出与分享见对应类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的会话单位是 Thread（`ThreadId`，UUIDv7），消息不是行式消息表，而是一条**由若干类记录组成的追加式事件日志**：模型项、UI 项、轮次上下文、上下文快照、压缩检查点与协议事件共同写入同一个 rollout 文件。权威历史是该 JSONL 文件（可选 zstd 压缩），SQLite 中的线程表与分页投影是可重建的索引。

关键事实：

- **一个线程一个 rollout 文件**，路径为 `~/.codex/sessions/…/rollout-<时间>-<thread_id>.jsonl`；回退会为新历史另建一个 rollout 文件，文件名追加独立 rollout id（`codex-rs/rollout/src/rollout_file_name.rs:3-45`、`codex-rs/rollout/src/lib.rs:86-87`）。
- **没有消息树**：历史是一条只知道追加顺序的序列，分支靠 `thread/fork` 新建线程并复制/引用父历史；回退靠 `thread/revert` 截断并切换 SQLite 中的 rollout 指针（第 4 节）。
- **写入与广播解耦**：核心把内核事件持久化为 `RolloutItem::EventMsg`，同时把同一事件发往事件队列；因此 rollout 里同时存在模型项与协议事件两种视角（`codex-rs/core/src/session/mod.rs:2848-2890`）。
- **列表与搜索是两套机制**：列表主要读 SQLite 或用 rollout 头部补齐元数据；全文搜索直接调用 ripgrep 扫 JSONL，而不是 SQL 索引（`codex-rs/rollout/src/search.rs:44-110`）。
- **`history_mode` 区分 Legacy 与 Paginated**，决定读历史走整文件回放还是分页投影；`thread/revert` 只支持 Paginated（`codex-rs/protocol/src/protocol.rs:947-953`、`codex-rs/app-server/src/request_processors/thread_processor.rs:2268-2272`）。

## 系统边界与数据主链

```text
thread/start | thread/resume | turn/start
  -> app-server thread_processor / turn_processor（RPC 校验、配置快照）
  -> core ThreadManager::start_thread -> Session::new（分配或复用 ThreadId）
  -> 首次落盘前 rollout 延迟创建（RolloutRecorder::new，deferred_creation）
  -> 用户输入：record_user_prompt_and_emit_turn_item（写 ResponseItem + 发 Item*
  -> 采样：流式 OutputItemAdded/Done 逐项 record_conversation_items -> persist_rollout_items
  -> Compacted / WorldState / TurnContext / TokenUsageRecord / EventMsg 各自按需追加
  -> TurnComplete 后 flush rollout（durability barrier）
  -> thread/list / thread/search / thread/turns/list / thread/items/list 读 SQLite 或 rollout
```

边界：一次请求如何拼装上下文、调用 Provider、消费流和收口属于「对话请求与上下文」；TUI 侧栏、面板与确认流程属于 Chat UI；消息如何渲染属于消息渲染器。

## 1. 会话、消息与分支数据模型

### 会话标识

| 标识 | 语义 | 生成与关系 |
|---|---|---|
| `ThreadId` | 线程标识，也是会话标识 | UUIDv7；rollout 文件名使用它（`codex-rs/protocol/src/thread_id.rs:13-35`） |
| `SessionId` | 会话标识 | 与 `ThreadId` 同一 UUID，可双向转换；`SessionMeta.session_id` 等于根线程 id（`codex-rs/protocol/src/session_id.rs:14-59`、`codex-rs/protocol/src/protocol.rs:3461-3463`） |
| `RolloutId` | rollout 文件标识 | 普通线程等于 `ThreadId`；`thread/revert` 生成的新文件用独立 rollout id（`codex-rs/protocol/src/thread_id.rs:28-31`） |

线程之间还有三类关系字段：`forked_from_id`（逻辑分叉父线程）、`parent_thread_id`（控制/派生父线程）、`attached_thread`（作为父线程附属线程隐藏于普通列表）。`agent_path` 与 `agent_role` 记录多 Agent 子线程身份（`codex-rs/protocol/src/protocol.rs:3464-3499`）。

### SessionMeta：线程级头部

rollout 第一行是 `SessionMetaLine`，记录创建时的 cwd、来源、CLI 版本、模型 Provider、base instructions、动态工具目录、能力根、历史模式与初始上下文窗口等信息（`codex-rs/protocol/src/protocol.rs:3454-3570`）。它是“创建当时的快照”，恢复时作为默认值，后续可变状态另有记录。

### RolloutItem：持久化记录的种类

`RolloutItem` 是写入 rollout 的顶层枚举，共 13 个变体（`codex-rs/history/src/lib.rs:228-249`）：

```text
SessionMeta / DynamicToolsUpdated / ResponseItem / InterAgentCommunication /
InterAgentCommunicationMetadata / Compacted / TurnContext / TokenUsageRecord /
WorldState / SecurityRiskScore / RetainedContext / EventMsg / RealtimeItem
```

其中消息相关的主干只有两类：`ResponseItem` 承载模型可见内容（用户消息、assistant 消息、reasoning、工具调用与工具输出），`EventMsg` 承载协议事件（项开始与完成、轮完成、错误等）。`Compacted` 保存压缩后的替代历史与恢复元数据，`WorldState` 保存上下文基线差异，二者都不是用户消息。

### ResponseItem 与 TurnItem 是两种视角

模型可见项是 `ResponseItem`（Responses API 形状），UI 可见项是 `TurnItem`。`TurnItem` 有 19 个变体（`codex-rs/protocol/src/items.rs:50-82`）：

```text
UserMessage / FunctionCallOutput / HookPrompt / AgentMessage / Plan / Reasoning /
CommandExecution / DynamicToolCall / CollabAgentToolCall / SubAgentActivity /
WebSearch / ImageView / Extension / ImageGeneration / EnteredReviewMode /
ExitedReviewMode / FileChange / McpToolCall / ContextCompaction
```

`parse_turn_item` 在记录模型项时派生出对应的 UI 项，并发出开始与完成事件（`codex-rs/core/src/session/mod.rs:5728-5747`）。用户消息是例外：它从用户输入派生 UI 项以保留字符区间，同时另写一条模型消息进历史（`codex-rs/core/src/session/mod.rs:5749-5812`）。

### 线程索引表

SQLite `threads` 表保存列表所需字段（`codex-rs/state/migrations/0001_threads.sql`）：

```text
id / rollout_path / created_at / updated_at / source / model_provider / cwd /
title / sandbox_policy / approval_mode / tokens_used / has_user_event /
archived / archived_at / git_sha / git_branch / git_origin_url
```

后续迁移补入预览、显式名称、置顶、最近活跃时间、历史模式、分组与来源、创建者身份与附属父线程等列（同目录 `0032`、`0039`–`0056`、`0062`），并新增独立的已读回执表（`0061`）。

分页历史另有两张投影表与一张位点表：`thread_turns`（每轮状态、错误、起止时间、首个用户项与最终 assistant 项）、`thread_items`（按 `rollout_ordinal` 排序的项 JSON）、`thread_history_projection_state`（下一次扫描的字节偏移与序号）。主键与唯一索引保证同一线程内序号唯一（`codex-rs/state/thread_history_migrations/0001_thread_history.sql`）。

## 2. 事实源、索引与持久化

**rollout 是权威源。** 写入由一个持有文件句柄的后台任务串行完成，核心侧只向 256 容量的通道投递记录；`persist()` 触发文件物化并回放缓冲，`flush()` 作为持久化屏障（`codex-rs/rollout/src/recorder.rs:1023-1127`）。新线程的文件创建是延迟的：未收到第一条可持久化记录前只预计算路径与元数据，因此“列表里出现线程”与“盘上存在文件”不是同一时刻（`:913-1005`）。

**SQLite 是索引与投影。** `rollout/src/state_db.rs` 负责打开状态库、执行迁移并做启动回填；扫描 rollout 时会用提取到的元数据 `upsert_thread`（`codex-rs/rollout/src/state_db.rs:44-90`、`:555-592`）。回填只播种缺失行，不覆盖已有行的 `rollout_path`——因为回退后同一线程可能有多个 rollout 文件，扫描无法判断哪个是当前版本（`:559-568`）。

**名称有独立小索引。** `session_index.jsonl` 以追加方式记录 `{id, thread_name, updated_at}`，读取时从文件尾部向前找最新一条；重命名和删除都在文件锁内完成（`codex-rs/rollout/src/session_index.rs:18-107`）。这解释了为什么改名不需要重写 rollout。

**标题与预览的来源分三层。** 手动重命名走 `thread/name/set`，同时更新 SQLite 元数据与名称索引（`codex-rs/app-server/src/request_processors/thread_processor.rs:1960-1988`）；列表预览来自 rollout 头部的首条用户消息或显式标题（`codex-rs/rollout/src/list.rs:69-77`）；TUI 的自动标题是另起的隐藏结构化线程，用固定模型生成不超过 36 字符的标题，而不是在同线程里追加消息（`codex-rs/tui/src/app/thread_title.rs:31-34`、`:64-127`）。

**一致性策略是“读修复 + 可跳过扫描”。** 读取线程时若磁盘与 SQLite 不一致，会按需要补写或修复行；`thread/list` 提供 `use_state_db_only` 直接读库、不扫 JSONL，用于避免大规模扫描（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:1492-1496`、`codex-rs/thread-store/src/local/list_threads.rs:50-67`）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：入口先解析模型、cwd、权限、动态工具、环境与 `history_mode`，再交给线程管理器启动会话；`ephemeral: true` 的线程不落盘（`codex-rs/app-server/src/request_processors/thread_processor.rs:1249`、`codex-rs/core/src/thread_manager.rs:1198`、`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:114-116`）。
- **恢复**：`thread/resume` 按线程读取 rollout，构造 `InitialHistory::Resumed`（`codex-rs/history/src/lib.rs:406-412`）；核心再用 `reconstruct_rollout` 把记录回放成运行期历史，处理压缩检查点与窗口（`codex-rs/core/src/session/rollout_reconstruction.rs:191-284`）。`InitialHistory` 另有 `New`、`Cleared`、`Forked` 三态。
- **恢复的账号门**：账号检查受 `cli_resume_account_check` 特性控制，当前默认关闭；启用后也只适用于客户端名为 `codex-tui` 或 `codex_exec` 的请求。检查还要求线程已有 rollout 路径、至少记录一个创建者身份字段，并且当前使用 ChatGPT 认证；其余场景直接通过这项检查（[特性默认值](<../../codex/codex-rs/features/src/lib.rs#L1129-L1133>)、[账号检查条件与结果](<../../codex/codex-rs/app-server/src/request_processors/thread_resume_account.rs#L18-L45>)）。

  满足条件时，任一已记录的创建者用户或账号/工作区 ID 与当前身份不匹配，都会拒绝并要求登录原账号。冷恢复与附加到已运行线程均调用该检查；由请求直接提供历史的恢复走另一分支（[冷恢复入口](<../../codex/codex-rs/app-server/src/request_processors/thread_processor.rs#L4025-L4054>)、[运行中线程入口](<../../codex/codex-rs/app-server/src/request_processors/thread_processor.rs#L4696-L4702>)）。
- **归档**：把 rollout 文件移动到 `archived_sessions` 目录，并在同一次加锁流程里更新 SQLite 的归档标记；支持批量归档与解档（`codex-rs/thread-store/src/local/archive_thread.rs:15-79`）。列表默认只返回未归档线程（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:1463-1466`）。
- **删除**：先做“存在附属线程则拒绝”的检查，再在生命周期锁与写锁下删除该线程的全部 rollout 文件，最后删 SQLite 行与名称索引；文件先于行删除，使失败可重试（`codex-rs/thread-store/src/local/delete_thread.rs:1-10`、`:25-45`）。
- **组织**：线程可归入 section（独立持久化的分组，可排序）与 project；这两者与置顶标记都是 SQLite 元数据，不写入 rollout（`codex-rs/thread-store/src/local/move_thread_to_section.rs`、`codex-rs/state/migrations/0045_threads_section.sql`、`codex-rs/state/migrations/0043_threads_is_pinned.sql`）。跨分组移动走 `thread/section/move`，成功后向所有已连接客户端广播带线程 id 与目标分组的事件，使多窗口看到同一分组状态（`codex-rs/app-server-protocol/src/protocol/common.rs:708-712`、`codex-rs/app-server/src/request_processors/thread_processor.rs:825-845`）。
- **异常恢复**：`Op::RecoverTurn` 允许在守护进程重启后恢复指定 turn 的起始选项；捕获条件要求该轮输入已写入 rollout（`codex-rs/core/src/session/handlers.rs:629-646`、`codex-rs/core/src/session/daemon_recovery.rs:16-56`）。被中断的轮次会在历史中写入一个中断标记并先 flush，再发出 `TurnAborted`（`codex-rs/core/src/tasks/mod.rs:1098-1117`）。
- **保留策略**：归档是内建的“移出主列表但保留文件”机制；按时间自动清理或过期删除本次未找到。检索覆盖 `state/`、`thread-store/`、`rollout/` 三个目录，关键词为 retention、cleanup、expire、ttl，只见到 SQLite 空闲页回收与日志维护。

## 4. 编辑、重试、续写、回退与分支语义

- **没有消息级编辑或删除端点。** 在 `app-server-protocol` 的请求枚举中检索 `item/delete`、`item/update`、`message/edit` 未找到结果；可变的只有线程元数据、设置与历史边界（`codex-rs/app-server-protocol/src/protocol/common.rs:567-798`）。
- **回退是“换一条物理历史”**：`thread/revert` 指定 `beforeTurnId`，该轮及其后所有轮被排除。实现要求线程使用 Paginated 历史，先停掉活线程，再基于保留前缀生成新的不可变 rollout 文件；旧文件保留，SQLite 的 `rollout_path` 指针一次性切到新文件（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:1314-1318`、`codex-rs/thread-store/src/local/revert_thread.rs:15-134`）。
- **分支是新建线程并继承边界**：`thread/fork` 用 `lastTurnId`（含该轮）与 `beforeTurnId`（不含该轮）两种边界新建线程，内部再映射为三态分叉边界；分叉可携带父线程的“历史基址”以引用而非复制前缀（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:544-583`、`codex-rs/thread-store/src/local/paginated_fork.rs:18-135`，边界类型见 `thread-store/src/types.rs:208-224`）。
- **附属分支**：`attachToSource` 生成隐藏于普通列表、但被父线程“拥有”的线程；父线程存在附属线程时不可删除（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:626-631`、`codex-rs/thread-store/src/local/delete_thread.rs:37-53`）。
- **续写不需要特殊对象**：同一线程再发一轮即可，历史由 `ContextManager` 在内存中保留并持续追加。发送时若线程正忙，输入会被分流为 steer（并入当前轮）或拒绝；轮次收尾阶段接受的 steer 也不会丢失，落盘后会继续采样（`codex-rs/core/src/tasks/mod.rs:430-460`）。具体判定见「对话请求与上下文」第 1、8 节。
- **重试不修改消息**：流式失败的重试发生在采样循环内部，重试成功后仍产生新的 `ResponseItem`；不存在“把已有 assistant 消息标记为失败再替换”的持久化语义（`codex-rs/core/src/responses_retry.rs:55-140`）。

## 5. 列表、分页、搜索与定位

**线程列表**：`thread/list` 的游标是不透明串，内部是“时间戳 + 线程 id”，用于在扫描或 SQL 排序中稳定续页；文件系统分页也改用同一二元比较，创建时间相同的线程不会在续页时被跳过（`codex-rs/rollout/src/recorder.rs:1351-1360`）。支持按创建时间、更新时间、最近活跃排序，以及 provider、来源、归档、section、project、cwd、父线程关系过滤。文件扫描版实现有硬上限：最多扫描 10000 个文件，并返回 `reached_scan_cap` 提示继续翻页（`codex-rs/rollout/src/list.rs:49-58`、`:168-195`、`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:1432-1507`）。

**本地历史可按账号筛选**：新建本地线程把 `account_scoped` 写为 true；列表和搜索是否应用账号筛选，由请求的 `current_account_only` 决定，两个接口都默认 false。仅在该选项为 true、使用本地线程存储且当前认证不是 API key 时，app-server 才构造身份过滤器（[列表参数](<../../codex/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1429-L1432>)、[搜索参数](<../../codex/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1520-L1523>)、[过滤器入口](<../../codex/codex-rs/app-server/src/request_processors/thread_processor.rs#L6006-L6019>)）。

筛选时逐个比对线程已记录的创建者 ID；未标记为账号范围的旧线程仍共享，未记录身份的字段不形成限制。若旧版回退文件丢失了标记，会追到原 rollout 读取；缺失路径、头部不可读或线程 ID 不匹配则不纳入结果。这是发现结果的过滤，恢复/附加的账号门使用第 3 节的独立条件（[匹配与兼容逻辑](<../../codex/codex-rs/thread-store/src/local_history_account.rs#L18-L65>)、[创建时标记](<../../codex/codex-rs/thread-store/src/local/create_thread.rs#L42-L46>)）。

**轮次与项分页**：Paginated 线程通过 `thread/turns/list` 与 `thread/items/list` 直接读两张投影表，游标绑定投影序号，并额外返回反向游标供反向水合（`codex-rs/app-server-protocol/src/protocol/v2/thread.rs:472-529`、`codex-rs/thread-store/src/local/thread_history/segment_paging.rs:45-345`）。

**搜索**：全局搜索先用 ripgrep 以固定字符串、忽略大小写扫描 rollout 目录，无 ripgrep 时退化为进程内扫描，再把命中的文件按列表顺序分页并附带片段（`codex-rs/rollout/src/search.rs:44-110`、`codex-rs/thread-store/src/local/search_threads.rs:36-100`）。线程内定位则基于投影项做子串匹配并给出字符区间，游标记录线程 id、搜索词、下一个投影序号与出现序号（`codex-rs/thread-store/src/local/thread_history/search.rs:38-60`）。

**没有 SQL 全文索引**：`threads` 表只有普通列与 B-tree 索引，没有 FTS 表；标题类过滤是子串匹配，正文命中依赖外部 ripgrep（`codex-rs/state/migrations/0001_threads.sql`、`codex-rs/state/migrations/0036_threads_visible_sort_indexes.sql`）。

## 6. 缓存、一致性、多窗口与并发写入

- **单写者**：每个线程的文件写入由 writer lock 保护；同一线程已有活动 writer 时，归档、删除或回退会返回冲突，而不是并发写同一文件（`codex-rs/thread-store/src/local/archive_thread.rs:30-46`、`codex-rs/rollout/src/writer_lock.rs`）。
- **写入是批量的**：一次 `record_conversation_items` 可能把多条 `ResponseItem` 与一条初始设置事件合成一个批次提交，减少 I/O 次数（`codex-rs/core/src/session/mod.rs:4076-4087`）。
- **持久化屏障在轮收尾之前**：任务结束后先 `flush_rollout` 把 writer 缓冲落盘，再做轮次收尾与排队工作；私有复核线程例外，它把 transcript 与终态事件一起保存（`codex-rs/core/src/tasks/mod.rs:400-460`）。
- **回退的一致性靠 CAS 式指针检查**：切换前读出 SQLite 记录的 rollout 路径作为期望值，生成新文件后只在“仍等于期望值”时替换指针；不匹配就删除新文件并返回冲突（`codex-rs/thread-store/src/local/revert_thread.rs:39-50`、`:139-154`）。
- **多连接共享线程运行时**：app-server 内多个连接通过 `ThreadManager` 复用同一个 `CodexThread`，事件由该连接的监听器分发；空闲卸载由线程状态与配置控制，不依赖客户端缓存（`codex-rs/app-server/src/request_processors/thread_processor.rs:2291-2314`）。
- **客户端侧没有“乐观写入数据库”**：TUI/app-server 客户端只消费事件流，不能直接改历史；因此多窗口看到的是同一事件序列，差异只可能来自订阅时机（静态推断）。

## 7. 迁移、导入导出与保留策略

- **SQLite 迁移**：状态库按内嵌迁移集推进（本次快照 62 个），并对“数据库已被更新版二进制迁移”的情况放宽为忽略未知版本，仍校验已知版本 checksum（`codex-rs/state/src/migrations.rs:9-46`）。分页历史另有 8 个专用迁移。
- **Legacy → Paginated 迁移**：存在 `rollout_migration` 子系统，含解析、规范化、发布、回滚与启动扫描；它把旧格式 rollout 投影到 `thread_turns`/`thread_items`，并记录迁移状态用于回退（`codex-rs/thread-store/src/local/rollout_migration/`、`codex-rs/state/migrations/0047_rollout_migration_state.sql`）。
- **压缩存储**：rollout 可被压缩为 `.jsonl.zst`，读取层对 `.jsonl` 与 `.jsonl.zst` 透明解码；压缩过程写临时文件、校验后再替换（`codex-rs/rollout/src/compression.rs:26-93`、`:889-1045`）。
- **导出**：app-server 协议层存在 rollout 导出相关模块（`codex-rs/app-server-protocol/src/protocol/v2/rollout.rs`），面向阅读/传播的格式与分享流程属于「对话导出与分享」类目，本文不展开。
- **备份与未知字段**：导入外部会话的通用恢复路径本次未找到；`SessionMeta`、`RolloutItem` 的多数字段带 `serde(default)`，未知行解析失败会计数并跳过，而不是中止整个文件（`codex-rs/rollout/src/recorder.rs:1144-1170`）。

## 8. Agent、模型、知识库与附件绑定

- **模型与提示词快照**：`SessionMeta` 记录 `model_provider`、`base_instructions` 及其来源；最新模型与 reasoning effort 另存 SQLite 列，用于列表显示（`codex-rs/protocol/src/protocol.rs:3500-3504`、`codex-rs/state/migrations/0020_threads_model_reasoning_effort.sql`）。
- **工具目录快照**：`DynamicToolsUpdated` 保存完整动态工具目录，`SessionMeta.dynamic_tools` 保存创建时快照；两者共同用于恢复时重建工具面（`codex-rs/history/src/lib.rs:230-234`、`codex-rs/core/src/session/mod.rs:4807-4816`）。
- **多 Agent 绑定**：子线程用第 1 节列出的父子/分叉关系字段、Agent 路径与角色字段关联到父线程，`multi_agent_version` 记录协作协议版本；`thread_spawn_edges` 表承载派生边（`codex-rs/state/migrations/0021_thread_spawn_edges.sql`）。
- **附件**：用户图片/音频以用户输入进入模型项，图片经 `AttachmentStore` 处理后可成为文件引用；`InlineAttachmentStore` 是内联实现，具体后端由调用方注入（`codex-rs/attachment-store/src/lib.rs:27-45`、`:194`）。`thread_attachments` 表记录线程与外部对象的引用关系（`codex-rs/state/migrations/0055_thread_attachments.sql`）。音频除内联负载外还支持文件引用，被拒绝的上传会记录文件 id：拒绝事实随轮次完成错误与压缩恢复元数据一路持久化，重建历史时重新收集，因此冷启动后不会重复上传同一被拒文件（`codex-rs/protocol/src/items.rs:638-676`、`codex-rs/core/src/session/rollout_reconstruction.rs:215-240`）。
- **记忆**：`memory_mode` 只在关闭生成时写为 `disabled` 并随 `SessionMeta` 持久化，开启时该字段留空（`codex-rs/rollout/src/recorder.rs:986-988`）。

## 9. 设计取舍与已确认边界

- **选择追加式 JSONL 而非消息表**：好处是可整文件回放、可直接用文本工具检索、压缩与迁移都能按文件处理；代价是列表与检索依赖扫描，需要 SQLite 投影做加速。
- **“事件日志里既有模型项又有协议事件”**：这样恢复与回放能同时重建模型输入和 UI 历史，但同一语义可能有两份表示（`ResponseItem` 与派生 `TurnItem`），读取方必须明确取哪一层。
- **回退不删旧文件**：旧 rollout 保留，只切换指针。这让回退可审计、失败可回滚，也意味着磁盘占用不会因回退而下降。
- **分支与回退是两套机制**：分支产生新线程与新会话对象，回退保持同一线程 id 但更换物理文件。
- **标题不是历史的一部分**：名称索引与 SQLite 列都不进 rollout，因此修改标题不会影响历史回放。

## 10. 未验证事项

1. SQLite 与 rollout 在崩溃窗口内的不一致程度（例如文件已写、行未更新）未通过故障注入验证。
2. `revert` 在多进程并发、压缩同胞文件与附属线程组合下的行为未实测。
3. Legacy → Paginated 迁移的中断恢复与回滚路径未运行验证。
4. ripgrep 搜索在超大历史量级下的分页稳定性与内存占用未实测。
5. `AttachmentStore` 的实际默认后端由宿主注入，本次未追踪各宿主的具体实现。

## 11. 关键源码索引

- `codex-rs/protocol/src/thread_id.rs`、`session_id.rs`：线程/会话标识
- `codex-rs/protocol/src/protocol.rs`：`SessionMeta`、`ThreadHistoryMode`、`Op`、`EventMsg`
- `codex-rs/history/src/lib.rs`：`RolloutItem`、`CompactedItem`、`InitialHistory`
- `codex-rs/protocol/src/items.rs`：`TurnItem` 及各项载荷
- `codex-rs/rollout/src/recorder.rs`：rollout 写入、延迟创建、加载、persist/flush
- `codex-rs/rollout/src/rollout_file_name.rs`、`compression.rs`：文件命名与 zstd 压缩
- `codex-rs/rollout/src/state_db.rs`、`state/migrations/`、`state/thread_history_migrations/`：SQLite 索引与投影
- `codex-rs/rollout/src/session_index.rs`：线程名称索引
- `codex-rs/rollout/src/list.rs`、`search.rs`：列表扫描、游标与 ripgrep 搜索
- `codex-rs/thread-store/src/store.rs`、`local/`：创建、恢复、分叉、回退、归档、删除
- `codex-rs/core/src/session/mod.rs`：记录入口与历史/事件回写
- `codex-rs/core/src/session/rollout_reconstruction.rs`：从 rollout 重建历史
- `codex-rs/app-server-protocol/src/protocol/v2/thread.rs`：线程 RPC 契约
- `codex-rs/app-server/src/request_processors/thread_processor.rs`：RPC 到核心的转接
