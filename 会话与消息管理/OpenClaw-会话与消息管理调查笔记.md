# OpenClaw 会话与消息管理调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：直接阅读当前代码快照中的 Gateway 会话 RPC、Agent SessionManager、per-agent SQLite schema/accessor、transcript 投影与搜索、生命周期和迁移模块；未运行交互会话或测试
>
> 调查范围：会话/消息/分支数据模型、SQLite 事实源与派生索引、创建读取修改持久化恢复主链、列表分页与搜索、并发一致性、旧格式迁移、Agent/模型/Provider/工具/附件等会话级绑定；Provider 调用、流式执行、取消重试和 Chat UI 工作流留在相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 当前的会话存储是“逻辑会话节点 + 可轮换 transcript generation + 追加型事件树”的组合。逻辑会话以 `sessionKey` 寻址，`session_nodes.entry_json` 保存会话记录，`current_session_id` 指向当前 transcript；一个逻辑会话可以保留多个 `session_windows`，每个 window 对应一代 transcript。当前代码的主要事实源是 per-agent SQLite，活动路径、消息序号和全文搜索均是从 transcript 事件派生的投影，而不是另一份独立消息主库。总体 schema 版本为 17，transcript entry 的文件协议版本为 3。依据见 `src/state/openclaw-agent-schema.sql:1-3`、`src/state/openclaw-agent-db-contract.ts:5-22` 和 `src/config/sessions/version.ts`。

消息不是简单的线性数组。每条可索引 entry 带有 `id`、`parentId` 和时间戳，形成父子链/DAG；活动 leaf 和追加游标决定当前可见路径。分支切换、回退和 fork 通过新增 transcript generation 或 leaf 控制改变活动路径，原始事件通常仍然保留。写入消息必须经过带 parent、幂等和脱敏处理的消息追加入口，不能把缺少 `parentId` 的 message 行直接作为普通事件写入。依据见 `src/agents/sessions/session-manager-types.ts:19-32`、`src/config/sessions/transcript-tree.ts:69-116` 和 `src/gateway/server-methods/AGENTS.md:1`。

生命周期操作同时保护逻辑身份和 transcript 身份。删除会先处理运行中工作、并发期望值、归档和关联对象；reset、rewind、branch switch 等操作会轮换当前 `sessionId`，使旧 generation 成为可追踪的历史，而不是让旧 manager 继续覆盖新路径。写入和生命周期变化通过 per-store writer queue、同步 SQLite transaction、`sessionId`/`lifecycleRevision` 比较以及 post-commit 事件串联起来。

检索分成两条路径：会话列表面向 `session_nodes` 记录及其轻量字段，支持偏移分页、固定排序、归档和 owner 等过滤；`sessions.search` 面向当前活动 transcript 中的 user/assistant 文本 FTS。聊天历史则读取活动路径，并在 compaction/reset 边界处补入展示所需的控制消息。搜索索引落后时会返回 `indexing` 并后台 reconcile，不会把可能包含已回退文本的旧 FTS 行当作可靠结果。

## 系统边界与数据主链

本类目只追踪“会话和消息保存了什么、用户操作改变了什么、重新打开如何恢复”。上下文拼装、Provider 请求、流式事件和取消属于“对话请求与上下文”；侧栏、搜索面板、分支导航和确认流程属于 Chat UI；文件差异只在本笔记记录其 session-level 绑定，不展开 Git 操作。

```text
频道或 Gateway 请求上下文
  -> deriveSessionKey / resolveSessionKey 计算逻辑 sessionKey
  -> resolve session store target，定位 agent 与 SQLite 数据库
  -> sessions.create 或首次追加建立 session_nodes、session_windows 和 transcript header
  -> appendTranscriptMessage / SessionManager.appendMessage 追加带 parentId 的消息 entry
  -> transcript_events 保存原始事件，identity 表保存事件身份与幂等索引
  -> 同事务前向更新活动路径/FTS，歧义路径标记 dirty 后由 reconcile 重建
  -> sessions.list、sessions.describe、chat.history、sessions.get、sessions.search 读取
  -> patch、reset、rewind、fork、branch switch、delete、recover 或 checkpoint restore 改变状态
  -> commit 后失效缓存并发布 session/transcript 变化，重新打开时按 sessionKey 解析当前 sessionId
```

创建入口是 `sessions.create`。它先校验 key、agent、模型、权限、工作目录、附件和父会话，然后由 `createGatewaySession` 以生命周期 fence 包住 session entry 与 transcript 的创建；如果请求带初始 message，则 commit 完成后再通过 `chat.send` 启动首轮。入口和后置初始 turn 见 `src/gateway/server-methods/sessions-create.ts:62-149`、`:516-620`。

已有会话的消息追加由 `SessionManager` 或 storage-neutral accessor 完成。写入 SQLite 时，消息事件进入 `transcript_events`，事件身份写入 `transcript_event_identities`，会话记录和 transcript mutation watermark 在需要时一并更新。读取时不会依据单独的内存数组重建权威状态，而是从当前逻辑节点和当前 transcript window 解析活动路径。主写入入口见 `src/config/sessions/session-accessor.sqlite-transcript-write.ts:488-540`，事务化回合入口见同文件 `:354-459`。

## 1. 会话、消息与分支数据模型

### 会话单位与标识

| 对象 | 语义 | 主要关联 |
|---|---|---|
| 逻辑会话 | 可被用户或路由持续寻址的 session node | `session_nodes.session_key` 为主键，`entry_json` 保存逻辑会话记录 |
| Transcript window | 某一代消息历史及其运行身份 | `session_windows.session_id` 为主键，属于一个 `session_key` |
| Transcript event | header、message、控制 entry 或扩展记录 | `transcript_events(session_id, seq)` 按顺序保存 |
| 活动路径 | 当前 leaf 到根的可见父链 | `session_transcript_active_events` 和 leaf 控制派生 |
| 会话关联会话 | 渠道地址、thread 或 delivery 关系 | `conversations`、`session_conversations`、`conversation_deliveries` |

`sessionKey` 负责逻辑寻址，`sessionId` 负责 transcript generation 身份。对直接会话，非 global 的消息上下文通常归并到所选 agent 的 main bucket；group/channel 会保留独立的 agent-namespaced key；显式 `SessionKey` 经过兼容规范化。global scope 直接使用 `global`。实现见 `src/config/sessions/session-key.ts:13-67`。

默认 agent session 目录位于 state 目录下的 `agents/<agentId>/sessions`。`sessions.json` 仍由路径和兼容代码识别，但当前主要 session/transcript 访问通过 agent SQLite；incognito key 则强制解析到独立的 incognito SQLite 路径，不能因为传入了 durable store path 而落回文件存储。实现见 `src/config/sessions/paths.ts:12-35`、`:324-365` 和 `src/config/sessions/session-store-path.ts:13-31`。

会话 entry 的 session ID 是 opaque identity。Agent SessionManager 的新 session 使用 UUIDv7，见 `src/agents/sessions/session-manager-id.ts:4-5`；Gateway 的 fork、rewind、checkpoint、recovery 等不同 owner 还会在各自的事务中生成新的 UUID，因此不应把所有 session ID 概括成同一种生成函数。entry ID 默认是经过冲突检查的 8 位随机 UUID 前缀，连续碰撞 100 次后退回完整 UUID，见 `src/agents/sessions/session-manager-id.ts:8-17`。

### 消息与控制 entry

标准 message entry 的外层形状是 `type: "message"`、`id`、`parentId`、`timestamp` 和 `message`。可读角色包括 user、assistant、toolResult，以及 custom、bashExecution 等扩展角色；assistant 内容可以是文本或内容块数组，工具结果带 tool call 标识、工具名、错误标志和内容。契约与兼容解析见 `src/agents/sessions/session-manager-codec.ts:20-53`、`:59-118`。

transcript 还保存不直接等价于聊天气泡的控制 entry：

| entry 类型 | 保存的会话语义 |
|---|---|
| `thinking_level_change` | 后续回合的 thinking level 变化 |
| `model_change` | provider/model 的历史切换点 |
| `compaction` | 摘要、保留起点和压缩前 token 信息 |
| `reset` | new、reset、idle 等历史窗口边界 |
| `branch_summary` | 分支导航或摘要文本 |
| `custom` | 持久化扩展状态，SessionManager 标注为不进入模型上下文 |
| `custom_message` | 扩展消息内容，并带是否展示的标志 |
| `label` | 对指定 entry 的书签或标签变更 |
| `session_info` | 会话名称等信息 |

这些类型由 `src/agents/sessions/session-manager-types.ts:33-110` 定义。消息 role、entry type、上下文可见性和 UI 展示性是不同维度，不能把所有 transcript 行都当成要发送给模型的消息。

### 树、leaf 与活动路径

正常追加使用当前 append parent 作为新 entry 的 `parentId`，并移动 leaf。side append 保留追加游标但不移动可见 leaf。显式 leaf 控制记录以 `targetId` 选择活动 leaf，`appendParentId` 决定后续追加位置；它本身是导航控制，不会作为可见消息进入活动路径。解析和路径选择见 `src/config/sessions/transcript-tree.ts:69-116`、`:166-289` 和 `:292-366`。

SessionManager 在加载时同时维护 canonical entry、opaque parent、logical parent、append parent 和 leaf。遇到跨 reset 边界、旧 parent 或插件元数据插入造成的游标差异时，会把物理追加关系与可见逻辑父关系分开处理。`appendMode: "side"` 的 entry 不推进可见 leaf，见 `src/agents/sessions/session-manager-core.ts:213-330`。

## 2. 事实源、索引与持久化

### SQLite 事实源

Agent SQLite schema 的注释明确规定：`session_nodes.entry_json` 是逻辑 session record 的 canonical source，promoted columns 只是查询投影；`session_windows` 及其子表拥有 transcript generations。`writeSessionEntry` 会在一个持久化边界内写 entry JSON、查询列、session window 和 conversation 关联，并发布缓存失效，见 `src/state/openclaw-agent-schema.sql:1-46` 和 `src/config/sessions/session-accessor.sqlite-entry-store.ts:575-741`。

transcript 相关表的职责如下：

| 表 | 事实或派生内容 |
|---|---|
| `transcript_events` | 按 `session_id + seq` 保存完整 event JSON，是 transcript 原始事件源 |
| `transcript_event_identities` | 保存 event id、type、parent、message 幂等键及 seq，供定位和约束查询 |
| `transcript_rewrite_watermarks` | 保存 generation 和更新时间，标识重写后的 transcript 身份 |
| `session_transcript_active_events` | 活动路径的 event/消息位置投影 |
| `session_transcript_index_state` | 投影进度、leaf、活动事件/消息计数和 dirty 标志 |
| `session_transcript_fts` | user/assistant 可搜索文本的 FTS5 派生索引 |
| `session_transcript_archives` | 删除或 reset 后的冷归档元数据和压缩 blob |

表结构见 `src/state/openclaw-agent-schema.sql:376-417`、`:446-470` 和 `:649-683`。当前 transcript 的“消息详情”来自 `transcript_events.event_json`，活动路径和 FTS 不拥有独立的消息正文副本。

追加 transcript event 时，代码先规范化可持久化的用户媒体，再按 session window 分配递增 seq；有身份的 event 同时写 identity row。message event 只能通过 `appendTranscriptMessage` 路径追加，`appendTranscriptEvent` 会拒绝直接写 `type: "message"`，以避免绕过 parent、幂等、脱敏和媒体规范化。实现见 `src/config/sessions/session-accessor.sqlite-transcript-store.ts:50-145` 和 `src/config/sessions/session-accessor.sqlite-transcript-write.ts:676-687`。

### 活动路径投影与 FTS

如果新 event 明确延续当前 leaf，accessor 会在同一事务中前向更新活动路径和 FTS；leaf 控制、side append、旧 flat 记录与新树模型混合等无法安全猜测的情况则将 `needs_rebuild` 置为真。重建从完整 transcript event 集合重新选择可见路径，删除旧派生行，再写入新的活动位置、消息位置、文本索引和 watermark。实现见 `src/config/sessions/session-transcript-index.ts:233-350`、`:388-464`。

小型重建可同步完成，阈值是约 4,000 行和 4 MiB；较大的重建交给后台 reconcile。dirty 状态是持久化的，post-commit kick 丢失时可以由启动或搜索时的 reconcile 发现。阈值和 reconcile 逻辑见 `src/config/sessions/session-transcript-index.ts:58-99`、`:466-509` 以及 `src/config/sessions/session-accessor.sqlite-transcript-store.ts:147-164`。

### 内存状态与非权威投影

SessionManager 在运行时保留 entry map、leaf、labels 和 append cursor，用于快速构造上下文；持久化 manager 重新加载时仍从 SQLite transcript target 读取。Gateway 的 session list cache、branch cache、reset-window cache 以及 FTS 都是可失效或可重建的派生状态，不取代 SQLite 原始 event 和 entry。

当前回合的 in-flight run snapshot、运行中的队列和部分临时 UI 状态会与 `chat.history` 的持久化消息一起返回，但本次调查未把它们视为 transcript 事实源。`chat.history` 明确把 in-flight snapshot 作为另一个投影字段处理，见 `src/gateway/server-methods/chat-history-handler.ts:435-448`、`:490-531`。

## 3. 创建、切换、归档、删除与恢复

### 创建与惰性物化

`SessionsCreateParamsSchema` 表明创建请求可以携带 key、agentId、label/category、model、thinking、权限/工具覆盖、incognito、visibility、parent、spawn depth、fork、project、worktree、exec node、message 和 attachments。见 `packages/gateway-protocol/src/schema/sessions-create.ts:11-93`。

省略 key 时会先选择指定 agent 的 main alias，而不是简单复用兼容 owner 的 alias。没有显式 parent 的 durable dashboard session 在 `dmScope: "main"` 等条件下会挂到 agent main；incognito session 不建立 durable parent lineage。`createGatewaySession` 的条件见 `src/gateway/session-create-service.ts:648-683`。

真正创建还是采用已有 key，是事务回调中以是否存在 `existingEntry` 判断的。已有 key 可以被采用，但不会重新盖写一次性创建 provenance，也不会伪造 `created` 事件。新 entry 写入后，如果请求包含初始消息，`sessions.create` 的 `afterCreate` 再通过 `chat.send` 追加消息并启动回合。实现见 `src/gateway/session-create-service.ts:913-1031`、`:1144-1233` 和 `src/gateway/server-methods/sessions-create.ts:575-620`。

物理上为空的 SQLite transcript 可以由 SessionManager 延迟初始化 header；但含有 opaque 或损坏结构的非空 transcript 不会被当成全新会话静默替换。旧版本 transcript 在持久化 runtime target 上需要先经过 doctor/import migration，见 `src/agents/sessions/session-manager-core.ts:99-127`。

### 列表切换与 metadata 生命周期

会话切换本质是客户端重新以 key 读取当前 entry 和 current sessionId。Gateway 通过 `sessions.list`、`sessions.describe`、`sessions.preview`、`sessions.get`、`chat.startup` 和 `chat.history` 提供不同粒度的读取；客户端事件在 commit 后收到 session identity 或 row 变化，再合并新的投影。

`sessions.patch` 和 `sessions.patchMany` 修改会话级 metadata 与路由覆盖，包含 label、icon、category、Control UI face、短状态、attention、TTL、archived、pinned、unread、model/context/thinking、tool overrides、权限、exec 和 send policy 等字段。patch engine 会先准备归档/权限/owner/CAS 条件，再通过 canonical replacement 写回 entry 和 SQLite 投影，见 `packages/gateway-protocol/src/schema/sessions-patch.ts:18-80` 和 `src/gateway/server-methods/sessions-patch-engine.ts:128-277`、`:467-586`。

归档由 `archivedAt` 时间戳表达，列表默认排除归档项；取消归档属于 metadata mutation。置顶由 `pinnedAt` 表达，默认排序时先按 pinned，再按更新时间。未读状态同时有 `markedUnreadAt` 和 `lastReadAt` 等字段，读取确认带 expected marker 时可以拒绝过期确认。

### Reset、删除、归档与回收

reset 由 `resetSessionEntryLifecycle` 负责。若新的 session entry 与旧 generation 不同，它会在旧 transcript 上追加 reset boundary，并写入新的当前 entry；旧 window 不会立即从数据库消失，历史回收由后续 disk-budget maintenance 处理。实现见 `src/config/sessions/session-accessor.sqlite-lifecycle.ts:175-271`。

delete 默认执行 archive-then-delete：在删除逻辑 entry 前，为仍被引用的 transcript generation 准备一致快照，在 SQLite 事务中写 `session_transcript_archives`，删除 transcript 派生状态、delivery artifacts、board rows 和 session node，提交后再发布归档文件。归档文件使用 identity 或 zstd 编码，带 SHA-256 和发布重试状态。主生命周期见 `src/gateway/server-methods/sessions-delete.ts:233-445`，归档表和文件发布见 `src/state/openclaw-agent-schema.sql:385-410`、`src/config/sessions/session-accessor.sqlite-archive-store.ts:27-90`、`:113-225`。

incognito session 不走 durable transcript archive，并按 incognito 规则删除其 transcript。main/global session 受 Gateway 删除保护；`archivedOnly` 则要求目标已归档，形成明确的 archive-then-delete 约束。判断见 `src/gateway/server-methods/sessions-delete.ts:93-155` 和 `:414-445`。

### Restart recovery

restart recovery 只接受带 restart tombstone 的 source。Gateway 会检查 source ownership、活动工作和 worker placement，然后为同一 agent 生成 successor key/sessionId；SQLite recovery 在一个事务内复制 source transcript、创建 successor、把 source 标记为 archived，并在 tombstone 中记录 successor key/id。提交后才启动 continuation，且 continuation 使用 successor 的幂等键。实现见 `src/gateway/session-recovery-service.ts:60-76`、`:143-290` 和 `src/config/sessions/session-accessor.sqlite-recovery.ts:49-237`。

## 4. 编辑、重试、续写、回退与分支语义

### 追加、幂等和 parent rebasing

SessionManager 新建 message entry 时把当前 append parent 写入 `parentId`；SQLite accessor 还会在事务内处理 active-branch append。若调用方带来的 parent 是当前 tail 的已知祖先，active append 会 rebasing 到最新 tail，以免旧 manager snapshot 把新消息接到过时位置；刻意指定其他分支 parent 时则保留显式 parent。实现见 `src/config/sessions/session-accessor.sqlite-transcript-parent.ts:8-54`。

user message 可带幂等键。数据库对同一 session 的 message 幂等键建立唯一索引；重复请求会返回已存在消息及其 anchor，timestamp 不参与 replay 内容比较；同一幂等键对应不同消息内容时抛出 admission conflict。实现见 `src/config/sessions/session-accessor.sqlite-transcript-message-append.ts:23-40`、`:59-153` 和 `src/state/openclaw-agent-schema.sql:446-460`。

### Rewind、fork 与 branch switch

这三种消息操作都由 `session-accessor.sqlite-message-cut.ts` 负责，但修改对象不同：

| 操作 | 目标 key | 持久化效果 |
|---|---|---|
| rewind | 原逻辑 key | 创建新 transcript generation，复制完整原始事件并追加 leaf control，使活动路径停在指定 user message 之前；返回编辑器文本/图片 |
| fork | 新 dashboard key | 创建新的逻辑 session，复制指定 user message 之前的活动路径，并记录 `forkSource`、父 key 和父 sessionId |
| branch switch | 原逻辑 key | 创建新 generation，复制事件并把 leaf 指向另一个 branch tip |

代码会拒绝不在活动路径上的 rewind 目标、非 user message、非 branch tip 的 switch，以及 session 已有活动工作时的这些操作。新 generation 的写入和当前 entry 更新在同一 agent 数据库 transaction 中完成，见 `src/config/sessions/session-accessor.sqlite-message-cut.ts:274-383`、`:386-448` 和 `src/gateway/server-methods/sessions-rewind.ts:276-345`。

分支列表不是单独的 branch 表，而是扫描 transcript tree 后找没有后继引用的 tip；当前 leaf 排在最前，其余按事件位置倒序。分支摘要缓存由 transcript generation 和 max seq 校验，最多保留 32 个 session cache entry。实现见 `src/config/sessions/session-accessor.sqlite-message-cut.ts:83-165`、`:404-448`。

带 upstream link 的外部 harness session 不进入本地 branch graph。它们不能在本地 rewind 或 switch，只有在存在唯一注册 fork harness 时才允许 fork；这样 fork 的实际 owner 仍是外部会话系统。Gateway 判断见 `src/gateway/server-methods/sessions-rewind.ts:247-255`、`:371-433`。

### Parent fork 与 checkpoint

`parentSessionKey` 关联父逻辑会话，`fork: true` 则复制父会话的活动路径。存储 owner 先选择用于 token admission 和复制的同一 source，避免大小判断和实际复制看到不同 tail；跨 agent 或跨数据库 fork 先读取父路径，再在目标 agent 数据库写 child transcript，代码明确承认两库之间没有一个共同 transaction。实现见 `src/config/sessions/session-accessor.sqlite-parent-session.ts:56-127`、`:351-437`。

compaction checkpoint 保存 pre/post transcript 引用、leaf、摘要和 token 数。当前 SQLite checkpoint branch/restore 优先从 checkpoint 引用的 session window 和 boundary event 读取，复制结果生成新 transcript；branch 写新 key，restore 保持原逻辑 key 但替换当前 sessionId。checkpoint 操作需要 expected sessionId/lifecycleRevision，并在活动工作、locked model 或边界丢失时拒绝。实现见 `src/config/sessions/session-accessor.sqlite-checkpoint.ts:98-208`、`:211-357` 和 `src/gateway/server-methods/sessions-compaction-checkpoints.ts:54-189`、`:397-463`。

### 编辑、删除、重试与续写边界

在本次检查的 Gateway sessions protocol、handlers 和 SQLite accessor 中，没有找到面向用户的通用“就地编辑一条已落盘 message”或“按 message id 删除 message” RPC。内部存在按 anchor 做精确 event JSON rewrite 的能力，但它用于受保护的 transcript repair/维护，不应等同于聊天编辑。精确 rewrite 入口见 `src/config/sessions/session-accessor.sqlite-transcript-write.ts:123-153` 和 `src/config/sessions/session-accessor.sqlite-transcript-store.ts:422-466`。

续写通常是对当前逻辑 key 继续追加新的 user/assistant turn；`sessions.send` 的协议入口只负责把 message 投入既有 key，Provider 的执行、队列和重试策略属于对话请求类目。回退后的编辑器内容由 message-cut 读取原 user message 的文本和受限图片内容返回，见 `src/config/sessions/session-accessor.sqlite-message-cut.ts:471-510`、`:571-627`。

## 5. 列表、分页、搜索与定位

### 会话列表

`sessions.list` 默认返回活动 session，归档参数为 `true` 时只看归档，`"all"` 时包含两者；global 和 unknown 默认排除，需通过对应选项纳入，cron run 行则在该列表过滤路径中直接排除。可选过滤包括 agent、label、board face、search、activeMinutes、requireLastInteraction、creator、owner、involvingMe、spawnedBy 和配置中的 agent 范围。过滤逻辑见 `src/gateway/session-utils-list.ts:176-362`。

列表默认 limit 为 100，支持 offset。默认排序先按 pinned 时间降序，再按 updatedAt 降序；`sortBy: "lastInteractionAt"` 时改用最后交互时间且不先提升 pinned；时间相同时按 key 稳定排序。实现见 `src/gateway/session-utils-list.ts:151-174` 和 `src/gateway/session-list-order.ts:10-64`。

响应区分当前页 `count`、过滤后的 `totalCount`、`offset`、`nextOffset` 和 `hasMore`。`ownerFirst` 只在第一页把当前 viewer 的 owner rows 放到普通结果前面，owner window 有独立上限，不改变共享结果的 offset 计算。选择与响应结构见 `src/gateway/session-utils-list.ts:374-417`、`:498-535`。

列表行可以按需读取 transcript 的 derived title、last message preview 和 bounded usage，但这些字段不是 session node 的另一份事实源。异步列表每 10 行让出事件循环，并批量读取 transcript 头尾，见 `src/gateway/session-utils-list.ts:66-75`、`:593-704`。

### Chat history 分页与定位

`chat.history` 使用活动 transcript 的逻辑消息序号，不直接暴露包含 header/control 行的 raw seq。默认从最新尾部读取；数字 offset 表示从最新方向跳过的消息数量，页面通过 `totalMessages`、`offset`、`nextOffset` 和 `hasMore` 继续向更旧方向读取。历史读取还受最大 entry 数、总 JSON 字节数、单消息字节数和展示文本长度限制。入口见 `src/gateway/server-methods/chat-history-handler.ts:285-368`，页读取见 `src/gateway/server-methods/chat-history-pages.ts:210-347`。

消息级 `messageId` anchor 读取会把目标置于页面中间，并在容量允许时向两侧扩展；它可以回退到 reset archive。因为数字 offset 不能编码“命中了哪一份历史 archive”，anchor 响应不带普通分页元数据。实现见 `src/config/sessions/session-accessor.sqlite-history-events.ts:421-465` 和 `src/gateway/server-methods/chat-history-pages.ts:34-49`、`:320-330`。

返回给聊天展示层的 message 带 `__openclaw.id` 等 metadata。compaction/reset boundary 作为逻辑 history marker 插入显示序列，活动路径消息和控制边界的逻辑位置与 raw event seq 分开维护，见 `src/config/sessions/session-accessor.sqlite-history-events.ts:42-107`、`:166-195`。

活动消息 delta cursor 包含 agent、session、transcript generation 和 event/message 位置。sessionId、generation、anchor 或 admission fence 不匹配时返回 reset 而不是猜测增量；当前绑定 CLI session 或无法解析持久化 target 时也会让客户端重新取完整历史。实现见 `src/config/sessions/session-accessor.sqlite-active-events.ts:328-415` 和 `src/gateway/server-methods/chat-history-handler.ts:449-504`。

### 会话搜索与预览

会话列表的 `search` 主要检查显示名、label、subject、sessionId、category、key 及可解析的模型字段，不扫描完整消息正文。需要正文时使用 `sessions.search`，它查询 per-agent FTS5，默认 limit 为 10、协议最大为 25，query 最大 4,096 字符；查询词按空白分词并以 AND 组合，结果按 FTS rank、时间和 message id 排序。实现见 `src/config/sessions/session-transcript-search.ts:14-50`、`:68-145`。

FTS 只索引活动路径中 user/assistant message 的可读文本块，工具结果、reasoning、图片二进制和不在活动路径的 branch text 不成为普通命中。索引 dirty 时旧行会被排除，返回 `indexing` 或 `truncated` 状态；Gateway 跨 store 合并时按 sessionKey/sessionId/messageId 去重，见 `src/gateway/server-methods/sessions-read.ts:89-218`。

`sessions.preview` 针对显式 key 读取受限数量和字符数的 transcript 尾部，返回 `ok`、`empty`、`missing` 或 `error` 状态，不把完整历史放进列表响应。入口见 `src/gateway/server-methods/sessions-read.ts:541-612`。

## 6. 缓存、一致性、多窗口与并发写入

### 写入串行化与 CAS

SQLite session write 由 per-store exclusive writer queue 包住，实际 transaction 只包含同步 SQLite commit 区间；文件读取、archive materialization、插件 hook 和其他异步准备在 transaction 外完成。提交前会重新读取 authoritative session row、transcript snapshot、alias rows 和 lifecycle revision，避免准备阶段的旧快照覆盖新状态。

transcript batch 追加可以同时检查 expected sessionId、lifecycleRevision、writer run id 和 turn state；发现 session rebound 时返回受控结果。删除、reset、patch、fork 和 recovery 也使用 expected identity 或 snapshot compare，相关契约见 `src/config/sessions/session-accessor.sqlite-contract.ts:22-56`、`:126-145` 和 `src/config/sessions/session-accessor.sqlite-entry-store.ts:185-218`、`:340-359`。

生命周期 mutation 还会在 transcript 操作前检查 active work admission 和 worker placement。删除会先 drain work admission；rewind、fork、branch switch 和 checkpoint restore 在 agent 工作时通常拒绝，避免一个运行中的 writer 与路径重写互相覆盖。删除流程的 drain/recheck 见 `src/gateway/server-methods/sessions-delete.ts:233-381`，消息 cut 的 active-run 拦截见 `src/gateway/server-methods/sessions-rewind.ts:276-328`。

### 幂等、缓存和索引一致性

message 幂等键的唯一约束、event identity 和 append result 共同解决重复请求。重复追加可以返回原 message 的活动 anchor；如果同一 key 的 payload 不一致，则显式报冲突，而不是把第二条消息静默合并。assistant idempotency lookup 另有扫描路径，但仍通过 transcript message 读取逻辑完成。

活动路径和 FTS 的正常顺序追加与 raw event 写入在同一 transaction 中更新，因此 commit 后不会出现“event 已提交而 forward index 尚未提交”的半状态。无法从新增行安全推出活动路径时，代码保留旧派生行但用 dirty watermark 隐藏它们，之后完整重建。实现见 `src/config/sessions/session-transcript-index.ts:233-306`。

session entry 写入会发布缓存失效，生命周期/身份变化会发布 committed identity diff，Gateway 在成功响应后发布 `emitSessionsChanged`。这些事件用于多客户端刷新 session row 和 transcript 状态，但本次没有运行多个窗口来验证乱序事件下的客户端行为。

SessionManager 还会在 SQLite append 返回 effective parent 与本地 snapshot 不同的情况下 reload transcript，再继续维护内存 leaf；这使过期 manager 不会把本地旧 parent 当成新活动路径。实现见 `src/agents/sessions/session-manager-entries.ts:36-101` 和 `src/agents/sessions/session-manager-persistence.ts:156-256`。

### 流式与临时状态边界

已提交的 user/assistant/toolResult 消息最终进入 transcript；生成中的内容和 in-flight run snapshot 仍由运行时状态管理，并可在 `chat.history` 中作为额外字段返回。SessionEntry 还定义了 pending final delivery、pending transcript repair、abort cutoff 和运行状态等 durable metadata，但这些字段表达的是交付/恢复状态，不替代已提交消息的 parent-linked transcript。执行循环、流式 delta、取消和重试的具体时序不在本笔记范围内。

## 7. 迁移、导入导出与保留策略

### Transcript 协议迁移

当前 SessionManager transcript version 为 3。旧 header version 小于 2 时，迁移会为 entry 生成 id 和 parentId，并把 compaction 的 `firstKeptEntryIndex` 转成 entry id；小于 3 时会把旧的 `hookMessage` role 归一为 custom/hook。迁移函数见 `src/agents/sessions/session-manager-codec.ts:154-221`。

带持久化 target 的 runtime 不会在读取时悄悄把 legacy transcript 当作当前协议继续写，而是要求 doctor/import 先完成迁移。codec 对 legacy 内容仍保留宽松解析和 opaque entry 分区，以便迁移阶段保留不能作为标准 indexed entry 的结构记录，见 `src/agents/sessions/session-manager-core.ts:99-127` 和 `src/agents/sessions/session-manager-codec.ts:286-430`。

### Agent SQLite schema 迁移

Agent database 的当前版本是 17。版本注释显示，会话节点/window、transcript watermark、active path、session provenance、conversation/delivery、board/session sharing 等能力逐步并入 canonical schema；旧的 session/transcript 搜索派生结构会被丢弃并重新 reconcile，派生 memory index 也按其缓存性质重建。版本和迁移入口见 `src/state/openclaw-agent-db-contract.ts:5-22`、`src/state/openclaw-agent-db-schema.ts:76-106`、`:168-200`。

### Legacy import 与 canonical repair

`importSqliteSessionRows` 是内部 doctor/migration 入口，不是普通运行时消息写入接口。它可以按一个 store 批量导入 legacy session entry 和 transcript rows，支持 trusted exact ordered rows 或已解析的 TranscriptEvent 列表；导入完成后会重建 transcript index、更新时间 watermark，并发布 entry cache invalidation。实现见 `src/config/sessions/session-accessor.sqlite-import.ts:32-77`、`:80-201`、`:204-229`。

导入阶段允许暂存旧 key alias，canonical repair 随后负责 key normalization、重复节点合并、session window rehome 和旧 alias 删除。正常 runtime writer 则拒绝非 canonical persisted key，并要求先走迁移路径。相关边界见 `src/config/sessions/session-accessor.sqlite-entry-store.ts:256-359`、`:527-573`。

### 归档与保留

删除或 reset 产生的 transcript archive 以 sessionId + generation 标识，内容在 SQLite archive row 中先形成 canonical cold-tier 记录，再由 worker 发布到受控目录；发布失败会保留 pending row 和重试计数，避免已经删除的逻辑 entry 让历史完全不可追踪。归档 retention 只在对应文件已不存在且 row 已发布时删除 canonical archive row，见 `src/config/sessions/session-accessor.sqlite-archive-store.ts:229-315`。

本次检查的 Gateway sessions protocol、session accessor 和 migration 代码中未找到面向用户的通用 sessions export/import RPC。已确认的 `importSqliteSessionRows` 属于内部 doctor/migration；阅读、传播和发布格式的导出与分享属于相邻“对话导出与分享”类目。完整数据库备份恢复流程不在本次已读范围内。

## 8. Agent、模型、知识库与附件绑定

| 外部对象 | 保存粒度与当前证据 |
|---|---|
| Agent | 数据库按 agentId 隔离，session key 在多 agent 情况下 namespaced；session row/window 保存 agent、scope、parent/spawn 和 provenance 投影 |
| Model/Provider | `providerOverride`、`modelOverride`、`agentRuntimeOverride`、auth profile override 等在 SessionEntry 中保存；window 还有 model/provider 投影，模型切换也可通过 transcript control entry 记录 |
| Harness/CLI/ACP | SessionEntry 保存 `agentHarnessId`、`cliSessionBindings`、ACP metadata；window 保存 ACP ownership 和 plugin owner，locked session 防止已有 transcript 被移到不兼容 harness |
| Tool policy | `toolOverrides`、permission mode、inherited allow/deny 和 completion owner 是 session/spawn lineage metadata；具体 tool call/result 是消息级 transcript 内容 |
| Channel/Conversation | `conversations` 保存 channel/account/kind/peer/thread/delivery target，`session_conversations` 保存 session 与 conversation 的关系及 route context，delivery operation 另有 durable row |
| Worktree/exec | worktree、sessionRoot、spawnedCwd、execNode/execCwd 等以 session 级绑定保存，并由生命周期清理 owner 处理 |
| Attachment/media | create/send 接受 attachments；持久化 message content 可含 image block，媒体规范化在 transcript append 时执行；当前检查的 session schema 中未找到独立 session-level attachment 表 |
| Knowledge/memory | schema 有独立 `memory_index_*` 和 `memory_entry_origins`，后者可记录来源 sessionId；本次未找到通用 session-to-knowledge-base 绑定，不能据 memory 表推断为历史快照 |

会话 entry 类型把 delivery state、channel origin、group/thread、participants、owner 和模型覆盖保存在同一逻辑记录中，同时把适合查询和外键约束的事实投影到 session window、conversation、participant 等表。Entry 字段与 session-level binding 定义见 `src/config/sessions/types.ts:44-140`、`:309-379`、`:430-622`。

消息媒体不是纯粹的 session metadata。`canonicalizePersistedUserMessageMedia` 在 transcript event 持久化前处理用户消息中的媒体形状；rewind/fork 返回 editor attachments 时还会限制图片数量和 base64 大小，并从受控 media store 读取 media refs。相关代码见 `src/config/sessions/session-accessor.sqlite-transcript-store.ts:643-658` 和 `src/config/sessions/session-accessor.sqlite-message-cut.ts:57-89`、`:587-627`。因此，当前证据支持“附件随消息内容或媒体 store 引用关联”，不支持“存在独立的会话附件表”。

## 9. 设计取舍与已确认边界

- **逻辑 key 与 transcript generation 分离**：同一个可寻址 session 可以轮换当前 transcript，同时保留 predecessor 的 window、generation 和 lineage，便于 reset、rewind、recovery 及 stale-writer 拦截；代价是读取必须区分逻辑 session、当前 sessionId 和历史 generation。
- **原始事件与活动投影分离**：`transcript_events` 保留追加顺序和树关系，active path/FTS 为可重建投影；分支操作不需要把所有历史物理删除，代价是需要 watermark、dirty reconcile 和 reset-window 计算。
- **SessionEntry JSON 与 promoted columns 并存**：entry JSON 保留灵活的 session metadata，promoted columns 支持排序、过滤和 owner/provenance 查询；writer 必须维护两者一致，并通过 `entry_valid` 和 cache invalidation 识别待修复行。
- **追加型消息树而非线性覆盖**：parentId、leaf control 和 append parent 允许分支、side append 与历史保留；直接写无 parent 的 message 会破坏活动路径，所以 Gateway scoped guide 明确禁止该写法。
- **归档先于回收**：删除会先生成可验证的 cold archive，再删除逻辑节点及 delivery/board 关联；归档 worker、pending row 和 SHA 校验把文件发布故障与逻辑删除分离。
- **运行态与持久态分层**：active run、in-flight snapshot、队列和 provider 执行不等价于已提交 transcript；可恢复的 session identity、pending delivery/repair 和 restart tombstone 才进入 session-level durable state。
- **兼容迁移集中在 doctor/import**：runtime 主要消费当前 SQLite canonical shape；旧 JSONL、旧 alias 和旧 schema 通过迁移、canonical repair 或 index rebuild 进入当前形状，而不是在每个热路径叠加 fallback。

本次调查没有把 session-level owner、conversation、worktree、CLI/ACP harness binding 等字段解释成 Provider 或 Agent 实体本身。它们是会话保存的引用、归属或路由快照；实体配置、凭据、工具执行和模型调用分别由其他 owner 管理。

## 10. 未验证事项

1. 未运行真实 Gateway、Control UI 或多窗口场景，因此 session change 事件乱序、客户端 delta merge、断线重连和 in-flight snapshot 恢复行为仍是静态推断。
2. 未进行崩溃、进程中断、SQLite worker 失败或 archive publish 中途退出测试；代码提供 generation、archive pending row 和 reconcile 路径，但不能仅凭静态阅读证明所有故障序列都能恢复。
3. 未对大规模 session list、长 transcript、FTS reconcile、archive worker 和跨 agent fork 做性能或并发基准。
4. 未完整运行 legacy `sessions.json`/旧 transcript 到当前 per-agent SQLite 的 doctor migration；已确认内部 import 与 canonical repair 入口，但没有验证真实旧数据集合的端到端迁移结果。
5. 未找到通用 sessions export/import RPC，但本次未覆盖所有 CLI、插件和相邻导出类目，不能据此断言项目完全不存在其他交换入口。
6. 未确认 session-level knowledge-base 绑定是否由某个未读插件或外部 catalog owner 保存；已检查 canonical agent schema、session types 和 memory index 相关表，当前只能记录“本次未找到”。
7. 未运行附件经过 media store、transcript rewrite、rewind/fork 和历史分页后的完整 round trip；当前结论只来自媒体规范化、受限读取和 schema 代码。
8. 未验证损坏 JSON、未知 event、旧 alias 与重复 logical node 在所有 runtime 读取路径中的最终用户可见行为；codec 和 doctor path 的容错/拒绝边界已静态确认。

## 11. 关键源码索引

- `src/config/sessions/session-key.ts`：消息上下文到逻辑 session key 的 derivation 与 agent namespacing
- `src/config/sessions/paths.ts`、`src/config/sessions/session-store-path.ts`：agent session 目录、legacy sessions.json 路径与 incognito store 选择
- `src/state/openclaw-agent-schema.sql`、`src/state/openclaw-agent-db-contract.ts`：Agent SQLite canonical schema 与版本 17
- `src/config/sessions/session-accessor.ts`：storage-neutral session/transcript accessor barrel 与公开入口
- `src/config/sessions/session-accessor.sqlite-entry-store.ts`：session_nodes 事实源、promoted projection、alias/rehome 和缓存失效
- `src/config/sessions/session-accessor.sqlite-transcript-store.ts`、`session-accessor.sqlite-transcript-write.ts`：event/message append、rewrite、transaction 和 writer fence
- `src/config/sessions/session-accessor.sqlite-transcript-message-append.ts`、`session-accessor.sqlite-transcript-parent.ts`：message 幂等、脱敏、parent 解析和 active-branch rebasing
- `src/agents/sessions/session-manager-types.ts`、`session-manager-core.ts`、`session-manager-entries.ts`、`session-manager-persistence.ts`：entry 类型、内存树、append、上下文和 SQLite persistence adapter
- `src/config/sessions/transcript-tree.ts`：leaf control、活动树扫描、路径选择和 opaque parent 处理
- `src/config/sessions/session-transcript-index.ts`、`session-transcript-projection-rebuild.ts`、`session-transcript-search.ts`：活动路径、FTS 派生投影、自愈和搜索
- `src/config/sessions/session-accessor.sqlite-active-events.ts`、`session-accessor.sqlite-history-events.ts`、`session-accessor.sqlite-reset-window.ts`：bounded active read、history page、boundary 和 visible message ordinal
- `src/gateway/server-methods/sessions-create.ts`、`src/gateway/session-create-service.ts`：Gateway 创建、采用已有 key、初始 turn、父链接和 fork
- `src/gateway/server-methods/sessions-read.ts`、`src/gateway/session-utils-list.ts`、`src/gateway/session-list-order.ts`：会话列表、预览、详情、过滤、offset 与排序
- `src/gateway/server-methods/chat-history-handler.ts`、`src/gateway/server-methods/chat-history-pages.ts`：chat.history/startup、字节预算、offset、anchor 和 delta cursor
- `src/gateway/server-methods/sessions-mutations.ts`、`src/gateway/server-methods/sessions-patch-engine.ts`：metadata patch、archive/pin/unread、owner 和 canonical replacement
- `src/gateway/server-methods/sessions-rewind.ts`、`src/config/sessions/session-accessor.sqlite-message-cut.ts`：rewind、fork、branch list/switch 和 message cut
- `src/config/sessions/session-accessor.sqlite-parent-session.ts`、`session-accessor.sqlite-checkpoint.ts`：父会话 fork 与 compaction checkpoint branch/restore
- `src/config/sessions/session-accessor.sqlite-lifecycle.ts`、`session-accessor.sqlite-archive.ts`、`session-accessor.sqlite-archive-store.ts`：reset、delete、transcript archive 与 retention
- `src/gateway/session-recovery-service.ts`、`src/config/sessions/session-accessor.sqlite-recovery.ts`：restart tombstone successor recovery
- `src/config/sessions/session-accessor.sqlite-import.ts`、`src/agents/sessions/session-manager-codec.ts`、`src/state/openclaw-agent-db-schema.ts`：legacy import、transcript version migration 与 SQLite schema migration
- `src/config/sessions/types.ts`、`packages/gateway-protocol/src/schema/sessions.ts`、`sessions-create.ts`、`sessions-patch.ts`、`sessions-row.ts`：durable SessionEntry、Gateway RPC 和 public session row 契约
