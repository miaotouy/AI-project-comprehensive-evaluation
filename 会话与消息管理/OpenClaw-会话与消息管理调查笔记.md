# OpenClaw 会话与消息管理调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：直接阅读当前代码快照中的 Gateway 会话 RPC、Agent SessionManager、agent store schema/accessor（SQLite 与 PostgreSQL 双引擎适配层）、transcript 投影与搜索、生命周期和迁移模块；未运行交互会话或测试
>
> 调查范围：会话/消息/分支数据模型、SQLite/PostgreSQL 事实源与派生索引、创建读取修改持久化恢复主链、列表分页与搜索、并发一致性、旧格式迁移、Agent/模型/Provider/工具/附件等会话级绑定；Provider 调用、流式执行、取消重试和 Chat UI 工作流留在相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 当前的会话存储由逻辑会话节点、可轮换的 transcript generation 和追加型事件树三层组成。逻辑会话以 `sessionKey` 寻址，会话记录保存在 `session_nodes.entry_json`，`current_session_id` 指向当前使用的 transcript；同一逻辑会话可以保留多个 `session_windows`，每个 window 对应一代 transcript。事实源默认是 per-agent SQLite，同一套 store 契约也可以运行在 PostgreSQL 上：state、agent、workboard、logbook、team-reports 五类 store family 各自选择引擎，一个 Gateway 内可以混用，适配层负责连接、schema 准入、事务与提交通知，store 本身的数据与操作契约保持不变（`docs/reference/database-engines.md`、`docs/gateway/postgresql.md`）。活动路径、消息序号和全文搜索都是从 transcript 事件派生的投影，消息正文在 transcript 里只存一份。agent schema 版本为 40，并按能力分出冷归档、文本搜索、向量检索、轨迹存储等多组特性版本常量；transcript entry 协议版本为 4，最低可读版本为 3。依据见 `src/state/openclaw-agent-schema.sql`、openclaw-schema-versions.ts、openclaw-agent-db-contract.ts 和 `src/config/sessions/version.ts`。

消息按树形结构保存：每条可索引 entry 都带自己的 id、parentId 和时间戳，彼此构成父子链或 DAG，活动 leaf 与追加游标共同决定当前可见路径。分支切换、回退和 fork 通过新增 transcript generation 或写入 leaf 控制来改变活动路径，原始事件通常保留下来。写入消息只能走带 parent 校验、幂等判断和脱敏处理的消息追加入口，缺少 `parentId` 的 message 行无法作为普通事件写入。依据见 `src/agents/sessions/session-manager-types.ts`、`src/config/sessions/transcript-tree.ts` 和 `src/gateway/server-methods/AGENTS.md`。

生命周期操作同时保护逻辑身份和 transcript 身份。删除会先做删除计划与 receipt、处理运行中工作、并发期望值、归档和关联对象；reset、rewind、branch switch 等操作会轮换当前 `sessionId`，使旧 generation 成为可追踪的历史，旧 manager 无法继续覆盖新路径。写入和生命周期变化通过 per-store writer queue、worker 协调层（请求、准入、传输）、同步事务、`sessionId`/`lifecycleRevision` 比较以及 post-commit 状态事件串联起来，生命周期 mutation 统一走 session controller 的 mutation 入口。

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
  -> patch、reset、rewind、fork、branch switch、delete、restart resume 或手动压缩改变状态
  -> commit 后失效缓存并发布 session/transcript 变化，重新打开时按 sessionKey 解析当前 sessionId
```

创建入口是 `sessions.create`。它先校验 key、agent、模型、权限、工作目录、附件和父会话，然后由 `createGatewaySession` 以生命周期 fence 包住 session entry 与 transcript 的创建；如果请求带初始 message，则 commit 完成后再通过 `chat.send` 启动首轮。入口和后置初始 turn 见 `src/gateway/server-methods/sessions-create.ts`、`:516-620`。

已有会话的消息追加由 `SessionManager` 或 storage-neutral accessor 完成。写入 SQLite 时，消息事件进入 `transcript_events`，事件身份写入 `transcript_event_identities`，会话记录和 transcript mutation watermark 在需要时一并更新。读取时不会依据单独的内存数组重建权威状态，而是从当前逻辑节点和当前 transcript window 解析活动路径。主写入入口见 `src/config/sessions/session-accessor.sqlite-transcript-write.ts`，事务化回合入口见同文件 `:354-459`。

## 1. 会话、消息与分支数据模型

### 会话单位与标识

| 对象 | 语义 | 主要关联 |
|---|---|---|
| 逻辑会话 | 可被用户或路由持续寻址的 session node | `session_nodes.session_key` 为主键，`entry_json` 保存逻辑会话记录 |
| Transcript window | 某一代消息历史及其运行身份 | `session_windows.session_id` 为主键，属于一个 `session_key` |
| Transcript event | header、message、控制 entry 或扩展记录 | `transcript_events(session_id, seq)` 按顺序保存 |
| 活动路径 | 当前 leaf 到根的可见父链 | `session_transcript_active_events` 和 leaf 控制派生 |
| 会话关联会话 | 渠道地址、thread 或 delivery 关系 | `conversations`、`session_conversations`、`conversation_deliveries` |

`sessionKey` 负责逻辑寻址，`sessionId` 负责 transcript generation 身份。对直接会话，非 global 的消息上下文通常归并到所选 agent 的 main bucket；group/channel 会保留独立的 agent-namespaced key；显式 `SessionKey` 经过兼容规范化。global scope 直接使用 `global`。实现见 `src/config/sessions/session-key.ts`。

默认 agent session 目录位于 state 目录下的 `agents/<agentId>/sessions`。兼容路径仍识别旧 sessions.json，持久会话由数据库 owner 访问；incognito 则由 session actor 的 memory backend 持有，没有对应 SQLite 数据库或 worker。旧的路径名称仍可作为作用域标识，不能据名称推断数据落盘。依据见 [memory owner](<../../openclaw/src/config/sessions/session-actor-memory.ts#L59-L69>) 与 [storage acquisition](<../../openclaw/src/config/sessions/session-actor-storage-acquisition.ts>)。

incognito 的完整主链分为四步：

1. Web 新建界面把可见性设置为 incognito，提交创建请求；Gateway 检查 web-only key、新会话身份及 durable key 冲突，再选定 Agent 和目标。来源见 [创建目标准入](<../../openclaw/src/gateway/session-create-target.ts#L78-L173>)。
2. 显式创建以 create 权限获取 memory actor。后续读取只 acquireExisting，缺失对象不会因查询而创建；入口在异步链上保留已选 actor，子操作消费同一 storage binding。
3. memory owner 串行接纳状态与 transcript 操作，保留 generation、版本、幂等结果和历史 window；数据库模式和内存模式共享业务契约，内存对象始终以 actor 状态为权威，不被驱逐到磁盘。来源见 [memory backend](<../../openclaw/src/config/sessions/session-actor-memory.ts>)。
4. 删除或到期回收以预期 sessionId 关闭精确会话并结束相关传输；owner 关闭会清空内存。进程退出后没有持久 transcript 可供恢复。到期观察器按已提交 actor 元数据调度，元数据编辑不续期，失败回收会重试。来源见 [incognito lifetime](<../../openclaw/src/gateway/session-incognito-lifetime.ts>)。

incognito 排除在持久会话发现和常驻 durable roster 之外，授权的按 key 读取可以消费 actor 内存事实。这解释了“能够在当前运行期继续读取”与“重启后恢复历史”两种不同的保留语义。实际关闭竞态与浏览器重连没有运行验证。

会话 entry 的 session ID 是 opaque identity。Agent SessionManager 的新 session 使用 UUIDv7，见 `src/agents/sessions/session-manager-id.ts:4-5`；Gateway 的 fork、rewind、checkpoint、recovery 等不同 owner 还会在各自的事务中生成新的 UUID，因此不应把所有 session ID 概括成同一种生成函数。entry ID 默认是经过冲突检查的 8 位随机 UUID 前缀，连续碰撞 100 次后退回完整 UUID，见 `src/agents/sessions/session-manager-id.ts:8-17`。

### 消息与控制 entry

标准 message entry 由五部分构成：固定的 message 类型标记、消息 `id`、指向父节点的 `parentId`、时间戳和消息体。可读角色有 user、assistant、toolResult，以及 custom、bashExecution 等扩展角色；assistant 内容可以是纯文本或内容块数组，工具结果带工具调用标识、工具名、错误标志和内容。契约与兼容解析见 `src/agents/sessions/session-manager-codec.ts`、`:59-118`。

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

这些类型由 `src/agents/sessions/session-manager-types.ts` 定义。消息 role、entry type、上下文可见性和 UI 展示性是不同维度，不能把所有 transcript 行都当成要发送给模型的消息。

### 树、leaf 与活动路径

追加新消息时，正常路径把当前 append parent 写进新 entry 的 parentId，并把 leaf 移到该 entry；side append 只保留追加游标，可见 leaf 停在原处。显式的 leaf 控制记录用 targetId 选出活动 leaf，再用 appendParentId 指定后续追加位置；这种记录只承担导航控制，不会作为可见消息进入活动路径。解析和路径选择见 `src/config/sessions/transcript-tree.ts:166-366`。

SessionManager 在加载时同时维护 canonical entry、opaque parent、logical parent、append parent 和 leaf。遇到跨 reset 边界、旧 parent 或插件元数据插入造成的游标差异时，会把物理追加关系与可见逻辑父关系分开处理。`appendMode: "side"` 的 entry 不推进可见 leaf，见 `src/agents/sessions/session-manager-core.ts`。

## 2. 事实源、索引与持久化

### 事实源：SQLite 与 PostgreSQL 双引擎

agent store schema 的注释明确规定：`session_nodes.entry_json` 是逻辑 session record 的 canonical source，promoted columns 只是查询投影；`session_windows` 及其子表拥有 transcript generations。写 entry 的路径会在一个持久化边界内写 entry JSON、查询列、session window 和 conversation 关联，并发布缓存失效，见 `src/state/openclaw-agent-schema.sql` 和 `src/config/sessions/session-accessor.sqlite-entry-store.ts`。

引擎选择不影响这套契约：SQLite 与 PostgreSQL 共用同一 accessor 接口，差异落在连接、schema 准入、事务与提交通知的适配层；schema 版本注释里出现 PostgreSQL 全文分词对齐、索引键排序对齐和向量候选投影等改动，说明两侧都要保持同一投影语义（`src/state/openclaw-schema-versions.ts`、`docs/gateway/postgresql.md`）。`accessor` 本身已经是 facade + 兄弟模块结构：entry 读写、transcript 写入、归档与回收、worker 协调、pending input 等各自独立成文件。

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

表结构见 `src/state/openclaw-agent-schema.sql`、`:446-470` 和 `:649-683`。当前 transcript 的“消息详情”来自 `transcript_events.event_json`，活动路径和 FTS 不拥有独立的消息正文副本。

追加 transcript event 时，代码先规范化可持久化的用户媒体，再按 session window 分配递增 seq；有身份的 event 同时写 identity row。message event 只能通过 `appendTranscriptMessage` 路径追加，`appendTranscriptEvent` 会拒绝直接写 `type: "message"`，以避免绕过 parent、幂等、脱敏和媒体规范化。实现见 `src/config/sessions/session-accessor.sqlite-transcript-store.ts` 和 `src/config/sessions/session-accessor.sqlite-transcript-write.ts`。

### 活动路径投影与 FTS

如果新 event 明确延续当前 leaf，accessor 会在同一事务中前向更新活动路径和 FTS；leaf 控制、side append、旧 flat 记录与新树模型混合等无法安全猜测的情况则将 `needs_rebuild` 置为真。重建从完整 transcript event 集合重新选择可见路径，删除旧派生行，再写入新的活动位置、消息位置、文本索引和 watermark。实现见 `src/config/sessions/session-transcript-index.ts`、`:388-464`。

小型重建可同步完成，阈值是约 4,000 行和 4 MiB；较大的重建交给后台 reconcile。dirty 状态是持久化的，post-commit kick 丢失时可以由启动或搜索时的 reconcile 发现。阈值和 reconcile 逻辑见 `src/config/sessions/session-transcript-index.ts`、`:466-509` 以及 `src/config/sessions/session-accessor.sqlite-transcript-store.ts`。

### 内存状态与非权威投影

SessionManager 在运行时保留 entry map、leaf、labels 和 append cursor，用于快速构造上下文；持久化 manager 重新加载时仍从 SQLite transcript target 读取。Gateway 的 session list cache、branch cache、reset-window cache 以及 FTS 都是可失效或可重建的派生状态，不取代 SQLite 原始 event 和 entry。

当前回合的 in-flight run snapshot、运行中的队列和部分临时 UI 状态会与 `chat.history` 的持久化消息一起返回，但本次调查未把它们视为 transcript 事实源。`chat.history` 明确把 in-flight snapshot 作为另一个投影字段处理，见 `src/gateway/server-methods/chat-history-handler.ts`、`:490-531`。

## 3. 创建、切换、归档、删除与恢复

会话现在还有独立的共享可见性与成员关系。可见性可为 shared、read-only、suggest 或 draft，允许集合由 Gateway 配置收窄；角色按 admin、owner、member、viewer 解析，draft 只允许 owner/admin 管理，incognito 会话对非所有者表现为不存在。授权每次从 canonical session metadata 与成员存储重算，并把 session generation、lifecycle revision、创建者和可见性变化视为读权限失效边界。实现见 `src/gateway/session-sharing-policy.ts`、`packages/gateway-protocol/src/schema/sessions-sharing.ts`。

### 创建与惰性物化

`SessionsCreateParamsSchema` 表明创建请求可以携带 key、agentId、label/category、model、thinking、权限/工具覆盖、incognito、visibility、parent、spawn depth、fork、project、worktree、exec node、message 和 attachments。见 `packages/gateway-protocol/src/schema/sessions-create.ts`。

省略 key 时会先选择指定 agent 的 main alias，而不是简单复用兼容 owner 的 alias。没有显式 parent 的 durable dashboard session 在 `dmScope: "main"` 等条件下会挂到 agent main；incognito session 不建立 durable parent lineage。`createGatewaySession` 的条件见 `src/gateway/session-create-service.ts`。

创建请求走新建 key 还是复用已有 key，取决于事务回调里能否读到 existing entry：读到就采用该会话，但不会重写一次性创建的 provenance，也不会伪造 created 事件。新 entry 落库后，若请求携带初始消息，创建入口会在 afterCreate 阶段通过 chat.send 追加消息并启动首个回合。实现见 `src/gateway/session-create-service.ts:1144-1233` 和 `src/gateway/server-methods/sessions-create.ts`。

物理上为空的 SQLite transcript 可以由 SessionManager 延迟初始化 header；但含有 opaque 或损坏结构的非空 transcript 不会被当成全新会话静默替换。旧版本 transcript 在持久化 runtime target 上需要先经过 doctor/import migration，见 `src/agents/sessions/session-manager-core.ts`。

### 列表切换与 metadata 生命周期

会话切换在客户端表现为按 key 重新读取当前 entry 和当前 sessionId。Gateway 为此提供多种粒度的读取入口，覆盖会话列表、单会话详情、transcript 预览、按 key 取单条会话、启动态和历史分页；客户端在提交后收到会话身份或行变化事件，再合并新的投影。

`sessions.patch` 和 `sessions.patchMany` 修改会话级 metadata 与路由覆盖，包含 label、icon、category、Control UI face、短状态、attention、TTL、archived、pinned、unread、model/context/thinking、tool overrides、权限、exec 和 send policy 等字段。patch engine 会先准备归档/权限/owner/CAS 条件，再通过 canonical replacement 写回 entry 和 SQLite 投影，见 `packages/gateway-protocol/src/schema/sessions-patch.ts` 和 `src/gateway/server-methods/sessions-patch-engine.ts`、`:467-586`。

归档由 `archivedAt` 时间戳表达，列表默认排除归档项；取消归档属于 metadata mutation。置顶由 `pinnedAt` 表达，默认排序时先按 pinned，再按更新时间。未读状态同时有 `markedUnreadAt` 和 `lastReadAt` 等字段，读取确认带 expected marker 时可以拒绝过期确认。

### Reset、删除、归档与回收

reset 由 `resetSessionEntryLifecycle` 负责。若新的 session entry 与旧 generation 不同，它会在旧 transcript 上追加 reset boundary，并写入新的当前 entry；旧 window 不会立即从数据库消失，历史回收由后续 disk-budget maintenance 处理。实现见 `src/config/sessions/session-accessor.sqlite-lifecycle.ts`。

delete 默认执行 archive-then-delete：在删除逻辑 entry 前，为仍被引用的 transcript generation 准备一致快照，在 SQLite 事务中写 `session_transcript_archives`，删除 transcript 派生状态、delivery artifacts、board rows 和 session node，提交后再发布归档文件。归档文件使用 identity 或 zstd 编码，带 SHA-256 和发布重试状态。主生命周期见 `src/gateway/server-methods/sessions-delete.ts`，归档表和文件发布见 `src/state/openclaw-agent-schema.sql`、`src/config/sessions/session-accessor.sqlite-archive-store.ts`、`:113-225`。

incognito session 不走 durable transcript archive，并按 incognito 规则删除其 transcript。main/global session 受 Gateway 删除保护；`archivedOnly` 则要求目标已归档，形成明确的 archive-then-delete 约束。判断见 `src/gateway/server-methods/sessions-delete.ts` 和 `:414-445`。

### Restart recovery

Gateway 进程重启后，恢复流程由 restart resume 模块族接管。恢复入口先按各 store target 清点持久化 lifecycle 投影，用 restart resume 跳过原因判断会话能否续跑；可续跑的会捕获并中断孤立的 pending input、恢复排队输入，再确认运行中的 bash 进程与 subagent 根会话仍然存活，会话状态变化通过 session event handoff 交给下一轮消费。实现见 `src/gateway/session-restart-resume.ts` 及其 failure、log 兄弟模块，以及 `src/config/sessions/` 下的 lifecycle 投影与 pending input 撤回模块。

## 4. 编辑、重试、续写、回退与分支语义

### 追加、幂等和 parent rebasing

SessionManager 新建 message entry 时把当前 append parent 写入 `parentId`；SQLite accessor 还会在事务内处理 active-branch append。若调用方带来的 parent 是当前 tail 的已知祖先，active append 会 rebasing 到最新 tail，以免旧 manager snapshot 把新消息接到过时位置；刻意指定其他分支 parent 时则保留显式 parent。实现见 `src/config/sessions/session-accessor.sqlite-transcript-parent.ts`。

user message 可带幂等键。数据库对同一 session 的 message 幂等键建立唯一索引；重复请求会返回已存在消息及其 anchor，timestamp 不参与 replay 内容比较；同一幂等键对应不同消息内容时抛出 admission conflict。实现见 `src/config/sessions/session-accessor.sqlite-transcript-message-append.ts`、`:59-153` 和 `src/state/openclaw-agent-schema.sql`。

### Rewind、fork 与 branch switch

这三种消息操作都由 `session-accessor.sqlite-message-cut.ts` 负责，但修改对象不同：

| 操作 | 目标 key | 持久化效果 |
|---|---|---|
| rewind | 原逻辑 key | 创建新 transcript generation，复制完整原始事件并追加 leaf control，使活动路径停在指定 user message 之前；返回编辑器文本/图片 |
| fork | 新 dashboard key | 创建新的逻辑 session，复制指定 user message 之前的活动路径，并记录 `forkSource`、父 key 和父 sessionId |
| branch switch | 原逻辑 key | 创建新 generation，复制事件并把 leaf 指向另一个 branch tip |

代码会拒绝不在活动路径上的 rewind 目标、非 user message、非 branch tip 的 switch，以及 session 已有活动工作时的这些操作。新 generation 的写入和当前 entry 更新在同一 agent 数据库 transaction 中完成，见 `src/config/sessions/session-accessor.sqlite-message-cut.ts`、`:386-448` 和 `src/gateway/server-methods/sessions-rewind.ts`。

分支列表没有单独的 branch 表：扫描 transcript tree 找没有后继引用的 tip，当前 leaf 排在最前，其余按事件位置倒序。分支摘要缓存由 transcript generation 和 max seq 校验，最多保留 32 个 session cache entry。实现见 `src/config/sessions/session-accessor.sqlite-message-cut.ts`、`:404-448`。

带 upstream link 的外部 harness session 不进入本地 branch graph。它们不能在本地 rewind 或 switch，只有在存在唯一注册 fork harness 时才允许 fork；这样 fork 的实际 owner 仍是外部会话系统。Gateway 判断见 `src/gateway/server-methods/sessions-rewind.ts`、`:371-433`。

### Parent fork 与手动压缩

`parentSessionKey` 关联父逻辑会话，`fork: true` 则复制父会话的活动路径。存储 owner 先选择用于 token admission 和复制的同一 source，避免大小判断和实际复制看到不同 tail；跨 agent 或跨数据库 fork 先读取父路径，再在目标 agent 数据库写 child transcript，代码明确承认两库之间没有一个共同 transaction。实现见 `src/config/sessions/session-accessor.sqlite-parent-session.ts`、`:351-437`。

压缩只提供手动入口 sessions.compact：Gateway 的会话方法目录里没有面向检查点 branch/restore 的独立 RPC，也没有 compaction checkpoint 方法。该入口先做 transcript 预检与裁剪，再用 persistCompactionBoundaryWithSessionEntryAsync 写入压缩边界，并通过 recordSessionCompacted 发布会话状态事件；mutation 统一走 session controller，要求有效的 device authority 与 operator run authority，存在活动工作或 lifecycle 变化时返回受控错误。实现见 `src/gateway/server-methods/sessions-compact.ts`、`sessions-compaction-runner.ts` 和 `src/config/sessions/` 下的 compaction accessor 与 runtime 模块。

### 编辑、删除、重试与续写边界

在本次检查的 Gateway sessions protocol、handlers 和 SQLite accessor 中，没有找到面向用户的通用“就地编辑一条已落盘 message”或“按 message id 删除 message” RPC。内部存在按 anchor 做精确 event JSON rewrite 的能力，但它用于受保护的 transcript repair/维护，不应等同于聊天编辑。精确 rewrite 入口见 `src/config/sessions/session-accessor.sqlite-transcript-write.ts` 和 `src/config/sessions/session-accessor.sqlite-transcript-store.ts`。

续写通常是对当前逻辑 key 继续追加新的 user/assistant turn；`sessions.send` 的协议入口只负责把 message 投入既有 key，Provider 的执行、队列和重试策略属于对话请求类目。回退后的编辑器内容由 message-cut 读取原 user message 的文本和受限图片内容返回，见 `src/config/sessions/session-accessor.sqlite-message-cut.ts`、`:571-627`。

## 5. 列表、分页、搜索与定位

### 会话列表

`sessions.list` 默认返回活动 session，归档参数为 `true` 时只看归档，`"all"` 时包含两者；global 和 unknown 默认排除，需通过对应选项纳入，cron run 行则在该列表过滤路径中直接排除。可选过滤包括 agent、label、board face、search、activeMinutes、requireLastInteraction、creator、owner、involvingMe、spawnedBy 和配置中的 agent 范围。过滤逻辑见 `src/gateway/session-utils-list.ts`。

列表默认 limit 为 100，支持 offset。默认排序先按 pinned 时间降序，再按 updatedAt 降序；`sortBy: "lastInteractionAt"` 时改用最后交互时间且不先提升 pinned；时间相同时按 key 稳定排序。实现见 `src/gateway/session-utils-list.ts` 和 `src/gateway/session-list-order.ts`。

响应的分页信息按口径分开：count 是当前页条数，totalCount 是过滤后的总条数，offset 与 nextOffset 分别指向本页和下一页，hasMore 表示是否还有更多。ownerFirst 只在第一页把当前 viewer 的 owner 行提到普通结果之前，owner window 有独立上限，共享结果的 offset 计算不受影响。选择与响应结构见 `src/gateway/session-utils-list.ts:498-535`。

列表行可以按需读取 transcript 的 derived title、last message preview 和 bounded usage，但这些字段不是 session node 的另一份事实源。异步列表每 10 行让出事件循环，并批量读取 transcript 头尾，见 `src/gateway/session-utils-list.ts`、`:593-704`。

### Chat history 分页与定位

chat.history 面向活动 transcript 的逻辑消息序号，把 header 和控制行占用的 raw seq 留在内部。读取默认从最新尾部开始，数字 offset 表示从最新方向跳过的消息条数；返回体用 totalMessages 给出总消息数，用 offset 与 nextOffset 标出本页和下一页位置，用 hasMore 表示是否还有更多。历史读取还受最大 entry 数、总 JSON 字节数、单消息字节数和展示文本长度限制。入口见 `src/gateway/server-methods/chat-history-handler.ts`，分页读取见同目录的 chat-history-pages.ts。

消息级 `messageId` anchor 读取会把目标置于页面中间，并在容量允许时向两侧扩展；它可以回退到 reset archive。因为数字 offset 不能编码“命中了哪一份历史 archive”，anchor 响应不带普通分页元数据。实现见 `src/config/sessions/session-accessor.sqlite-history-events.ts` 和 `src/gateway/server-methods/chat-history-pages.ts`、`:320-330`。

返回给聊天展示层的 message 带 `__openclaw.id` 等 metadata。compaction/reset boundary 作为逻辑 history marker 插入显示序列，活动路径消息和控制边界的逻辑位置与 raw event seq 分开维护，见 `src/config/sessions/session-accessor.sqlite-history-events.ts`、`:166-195`。

活动消息 delta cursor 包含 agent、session、transcript generation 和 event/message 位置。sessionId、generation、anchor 或 admission fence 不匹配时返回 reset 而不是猜测增量；当前绑定 CLI session 或无法解析持久化 target 时也会让客户端重新取完整历史。实现见 `src/config/sessions/session-accessor.sqlite-active-events.ts` 和 `src/gateway/server-methods/chat-history-handler.ts`。

### 会话搜索与预览

会话列表的 `search` 主要检查显示名、label、subject、sessionId、category、key 及可解析的模型字段，不扫描完整消息正文。需要正文时使用 `sessions.search`，它查询 per-agent FTS5，默认 limit 为 10、协议最大为 25，query 最大 4,096 字符；查询词按空白分词并以 AND 组合，结果按 FTS rank、时间和 message id 排序。实现见 `src/config/sessions/session-transcript-search.ts`、`:68-145`。

FTS 只索引活动路径中 user/assistant message 的可读文本块，工具结果、reasoning、图片二进制和不在活动路径的 branch text 不成为普通命中。索引 dirty 时旧行会被排除，返回 `indexing` 或 `truncated` 状态；Gateway 跨 store 合并时按 sessionKey/sessionId/messageId 去重，见 `src/gateway/server-methods/sessions-read.ts`。

预览接口 sessions.preview 按显式 key 读取 transcript 尾部，读取条数和字符数都有上限，结果状态为 ok、empty、missing 或 error 之一，列表响应里只带这段受限尾部。入口见 `src/gateway/server-methods/sessions-read.ts`。

## 6. 缓存、一致性、多窗口与并发写入

### 写入串行化与 CAS

SQLite session write 由 per-store exclusive writer queue 包住，实际 transaction 只包含同步 SQLite commit 区间；文件读取、archive materialization、插件 hook 和其他异步准备在 transaction 外完成。提交前会重新读取 authoritative session row、transcript snapshot、alias rows 和 lifecycle revision，避免准备阶段的旧快照覆盖新状态。

批量追加 transcript 时，一次准入可以同时核对期望的 sessionId、lifecycleRevision、writer run id 和 turn 状态；发现 session 已被 rebound 就返回受控结果。删除、reset、patch、fork 和 recovery 同样用期望身份或快照比较做前置校验，契约见 `src/config/sessions/session-accessor.sqlite-contract.ts` 和同目录的 entry store 模块。跨 worker 的请求、准入与传输由 worker coordination、request 与 admission 三个模块分工，持久排队输入记在 pending inputs 模块里。

生命周期 mutation 还会在 transcript 操作前检查 active work admission 和 worker placement。删除会先 drain work admission；rewind、fork、branch switch 和 checkpoint restore 在 agent 工作时通常拒绝，避免一个运行中的 writer 与路径重写互相覆盖。删除流程的 drain/recheck 见 `src/gateway/server-methods/sessions-delete.ts`，消息 cut 的 active-run 拦截见 `src/gateway/server-methods/sessions-rewind.ts`。

### 幂等、缓存和索引一致性

message 幂等键的唯一约束、event identity 和 append result 共同解决重复请求。重复追加可以返回原 message 的活动 anchor；如果同一 key 的 payload 不一致，则显式报冲突，而不是把第二条消息静默合并。assistant idempotency lookup 另有扫描路径，但仍通过 transcript message 读取逻辑完成。

活动路径和 FTS 的正常顺序追加与 raw event 写入在同一 transaction 中更新，因此 commit 后不会出现“event 已提交而 forward index 尚未提交”的半状态。无法从新增行安全推出活动路径时，代码保留旧派生行但用 dirty watermark 隐藏它们，之后完整重建。实现见 `src/config/sessions/session-transcript-index.ts`。

session entry 写入会发布缓存失效，生命周期/身份变化会发布 committed identity diff，Gateway 在成功响应后发布 `emitSessionsChanged`。这些事件用于多客户端刷新 session row 和 transcript 状态，但本次没有运行多个窗口来验证乱序事件下的客户端行为。

SessionManager 还会在 SQLite append 返回 effective parent 与本地 snapshot 不同的情况下 reload transcript，再继续维护内存 leaf；这使过期 manager 不会把本地旧 parent 当成新活动路径。实现见 `src/agents/sessions/session-manager-entries.ts` 和 `src/agents/sessions/session-manager-persistence.ts`。

### 流式与临时状态边界

已提交的 user/assistant/toolResult 消息最终进入 transcript；生成中的内容和 in-flight run snapshot 仍由运行时状态管理，并可在 `chat.history` 中作为额外字段返回。SessionEntry 还定义了 pending final delivery、pending transcript repair、abort cutoff 和运行状态等 durable metadata，但这些字段表达的是交付/恢复状态，不替代已提交消息的 parent-linked transcript。执行循环、流式 delta、取消和重试的具体时序不在本笔记范围内。

## 7. 迁移、导入导出与保留策略

### Transcript 协议迁移

当前 SessionManager transcript version 为 3。旧 header version 小于 2 时，迁移会为 entry 生成 id 和 parentId，并把 compaction 的 `firstKeptEntryIndex` 转成 entry id；小于 3 时会把旧的 `hookMessage` role 归一为 custom/hook。迁移函数见 `src/agents/sessions/session-manager-codec.ts`。

带持久化 target 的 runtime 不会在读取时悄悄把 legacy transcript 当作当前协议继续写，而是要求 doctor/import 先完成迁移。codec 对 legacy 内容仍保留宽松解析和 opaque entry 分区，以便迁移阶段保留不能作为标准 indexed entry 的结构记录，见 `src/agents/sessions/session-manager-core.ts` 和 `src/agents/sessions/session-manager-codec.ts`。

### Agent SQLite schema 迁移

Agent store 的当前 schema 版本是 40，并拆出多组特性版本常量（冷归档导航、冷归档分块、文本搜索、向量检索、轨迹存储、内存版本等），说明 schema 演进已按能力分片而非单一全局号（`src/state/openclaw-schema-versions.ts`、`src/state/openclaw-agent-db-contract.ts`）。版本注释显示，会话创建 receipt、冷 transcript 归档分块、PostgreSQL 全文分词与索引键排序、memory 精确路径候选等逐步并入 canonical schema；旧的 session/transcript 搜索派生结构会被丢弃并重新 reconcile，派生 memory index 按其缓存性质重建。迁移入口见 `src/state/openclaw-agent-db-schema.ts`。

### Legacy import 与 canonical repair

`importSqliteSessionRows` 是内部 doctor/migration 入口，不是普通运行时消息写入接口。它可以按一个 store 批量导入 legacy session entry 和 transcript rows，支持 trusted exact ordered rows 或已解析的 TranscriptEvent 列表；导入完成后会重建 transcript index、更新时间 watermark，并发布 entry cache invalidation。实现见 `src/config/sessions/session-accessor.sqlite-import.ts`、`:80-201`、`:204-229`。

导入阶段允许暂存旧 key alias，canonical repair 随后负责 key normalization、重复节点合并、session window rehome 和旧 alias 删除。正常 runtime writer 则拒绝非 canonical persisted key，并要求先走迁移路径。相关边界见 `src/config/sessions/session-accessor.sqlite-entry-store.ts`、`:527-573`。

### 归档与保留

删除或 reset 产生的 transcript archive 以 sessionId + generation 标识，内容在 SQLite archive row 中先形成 canonical cold-tier 记录，再由 worker 发布到受控目录；发布失败会保留 pending row 和重试计数，避免已经删除的逻辑 entry 让历史完全不可追踪。归档 retention 只在对应文件已不存在且 row 已发布时删除 canonical archive row，见 `src/config/sessions/session-accessor.sqlite-archive-store.ts`。

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

会话 entry 类型把 delivery state、channel origin、group/thread、participants、owner 和模型覆盖保存在同一逻辑记录中，同时把适合查询和外键约束的事实投影到 session window、conversation、participant 等表。Entry 字段与 session-level binding 定义见 `src/config/sessions/types.ts`、`:309-379`、`:430-622`。

消息媒体不是纯粹的 session metadata。`canonicalizePersistedUserMessageMedia` 在 transcript event 持久化前处理用户消息中的媒体形状；rewind/fork 返回 editor attachments 时还会限制图片数量和 base64 大小，并从受控 media store 读取 media refs。相关代码见 `src/config/sessions/session-accessor.sqlite-transcript-store.ts` 和 `src/config/sessions/session-accessor.sqlite-message-cut.ts`、`:587-627`。因此，当前证据支持“附件随消息内容或媒体 store 引用关联”，不支持“存在独立的会话附件表”。

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
2. 未进行崩溃、进程中断、SQLite worker 失败或 archive publish 中途退出测试；代码提供 generation、archive pending row 和 reconcile 路径，各故障序列的实际恢复效果属于运行验证范围。
3. 未对大规模 session list、长 transcript、FTS reconcile、archive worker 和跨 agent fork 做性能或并发基准。
4. 未完整运行 legacy `sessions.json`/旧 transcript 到当前 per-agent SQLite 的 doctor migration；已确认内部 import 与 canonical repair 入口，但没有验证真实旧数据集合的端到端迁移结果。
5. 通用 sessions export/import RPC 在已读的源码入口中未找到；本次没有逐一覆盖所有 CLI、插件和相邻导出类目。
6. 未确认 session-level knowledge-base 绑定是否由某个未读插件或外部 catalog owner 保存；已检查 canonical agent schema、session types 和 memory index 相关表，当前只能记录“本次未找到”。
7. 未运行附件经过 media store、transcript rewrite、rewind/fork 和历史分页后的完整 round trip；当前结论只来自媒体规范化、受限读取和 schema 代码。
8. 未验证损坏 JSON、未知 event、旧 alias 与重复 logical node 在所有 runtime 读取路径中的最终用户可见行为；codec 和 doctor path 的容错/拒绝边界已静态确认。

## 11. 关键源码索引

- `src/config/sessions/session-key.ts`：消息上下文到逻辑 session key 的 derivation 与 agent namespacing
- `src/config/sessions/paths.ts`、`src/config/sessions/session-store-path.ts`：agent session 目录、legacy sessions.json 路径与 incognito store 选择
- `src/state/openclaw-agent-schema.sql`、`src/state/openclaw-schema-versions.ts`、`src/state/openclaw-agent-db-contract.ts`：agent store canonical schema、schema 版本 40 与特性版本常量
- `docs/reference/database-engines.md`、`docs/gateway/postgresql.md`：SQLite/PostgreSQL 双引擎、五类 store family 与混用边界
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
- `src/config/sessions/session-accessor.sqlite-parent-session.ts`、`session-accessor.sqlite-parent-fork.ts`：父会话 fork\n- `src/gateway/server-methods/sessions-compact.ts`、`sessions-compaction-runner.ts`、`src/config/sessions/session-accessor.sqlite-compaction.ts`：手动压缩与压缩边界写入
- `src/config/sessions/session-accessor.sqlite-lifecycle.ts`、`session-accessor.sqlite-deletion-plan.ts`、`session-accessor.sqlite-deletion-receipts.ts`：reset、删除计划与删除 receipt\n- `src/config/sessions/session-accessor.sqlite-archive-store.ts`、`session-accessor.sqlite-archive.worker.ts`、`session-accessor.sqlite-reclamation.ts` 及 `session-accessor.sqlite-maintenance-*.ts`：transcript 冷归档、归档 worker、回收与保留策略
- `src/gateway/session-restart-resume.ts`、`session-restart-resume-failure.ts`、`src/config/sessions/session-run-lifecycle-projection.ts`、`session-pending-input-withdrawal.ts`：重启续跑判定、孤立 pending input 收口与 resumed turn 交接
- `src/config/sessions/session-accessor.sqlite-import.ts`、`src/agents/sessions/session-manager-codec.ts`、`src/state/openclaw-agent-db-schema.ts`：legacy import、transcript version migration 与 SQLite schema migration
- `src/config/sessions/types.ts`、`packages/gateway-protocol/src/schema/sessions.ts`、`sessions-create.ts`、`sessions-patch.ts`、`sessions-row.ts`：durable SessionEntry、Gateway RPC 和 public session row 契约\n- `src/config/sessions/session-accessor.sqlite-worker-coordination.ts`、`session-accessor.sqlite-worker-request.ts`、`session-accessor.sqlite-pending-inputs.ts`：worker 协调/准入/传输与 pending input\n- `src/sessions/session-controller.lifecycle.ts`、`src/sessions/session-state-events.ts`：session lifecycle mutation 入口与 session 状态事件
