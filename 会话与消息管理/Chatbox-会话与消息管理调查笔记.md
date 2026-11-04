# Chatbox 会话与消息管理调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、renderer store、`@chatbox/core` 应用层与端口、SQLite 行存储与平台存储适配），符号对照当前 HEAD 核实，未运行应用
>
> 调查范围：会话与消息的持久化模型、生命周期、分支、索引与检索；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 以**单会话（Session）为存储单元**，会话与消息是本地持久化的业务对象：

- 会话列表（sidebar）只认识 `SessionMetaRecord`（标识、名称、置顶、归档与排序等元信息），完全不知道 thread、fork、summary 这些"消息级"结构的存在（见第 1 节证据）。
- 首页是一个"假会话"（id 固定为字符串 `'new'`），`Session` 记录直到用户发出第一条消息才被创建（第 3 节）。
- 消息事实源是**行式 SQL 存储**：消息按行写进 `session_messages`，线程按行写进 `session_threads`，会话头只保留 `activeThreadId`、`storageFormat: 'rows'`、`rowFormatVersion: 3` 这类提交身份；旧数组式 `Session` 对象降级为可修复投影。
- 会话列表元数据仍是独立的 `session_meta` 表，每会话一行；桌面/Web 用 IndexedDB 实现、移动端用 SQLite 实现，同一 `SessionMetaStorage` 接口由平台工厂注入。
- thread（同会话内历史区间）、fork（同一消息位置的平行分支，替代回复可折叠为分支组）、summary（消息级压缩标记）与 starred（置顶分组）仍是四个关注点，但落盘后收在同一棵消息树里：thread 对应树的一段根到叶路径，fork 对应父节点下的兄弟行加"激活子节点"，summary 是 `kind` 为 `summary` 的普通行，starred 只存在于 `session_meta`。唯一的会话级交叉点仍是"move thread to conversations"会把 thread 转成新的顶层会话（第 1 节）。
- 归档 = `hidden: true` + `archivedAt` 时间戳，不删除任何数据；恢复归档不会重置 `sortOrder`。
- 消息搜索没有持久化倒排索引，按分页读取完整 Session 后逐条扫描。
- 自动压缩触发阈值：按模型上下文窗口与 `compactionThreshold`（默认 0.6）计算 token 预算（第 1.4 节）。
- Work Mode 的待发送用户消息不先写入 Session，而是保存在独立的本地队列；只有实际投递或 steering 前才成为持久化会话消息。队列因此是草稿与 Session 之间的第三种事实对象。

## 系统边界与数据主链

```text
首页 'new' 假会话（纯 React state + 草稿 localStorage key 'new-chat'）
  -> 首条消息 -> SessionService.createSession 建 session_meta 行与会话头
  -> 消息以 MessageRow 树提交到 session_messages / session_threads
       （staging 表 + revision guard + 行头 revision 保证提交原子性）
  -> 会话页经 @chatbox/react 的 query 桥读取 SessionTree 投影
  -> 流式期间 UI cache 高频更新 + 节流提交（执行语义在对话请求与上下文）
  -> SessionList 经平台 SessionMetaStorage 游标分页 meta 行
  -> 置顶 / 归档 / 恢复 / 永久删除改 meta 行或删除整棵树
```

边界：请求体如何组装、流式节流落盘时机属于对话请求与上下文；界面上的拖放、菜单、搜索弹窗工作流属于 Chat UI；消息内容渲染属于消息渲染器（已有独立笔记，本文只记录数据形状）。

## 1. 会话、消息与分支数据模型

### 1.0 存储形态：行式消息树

本次快照把持久模型换成"会话头 + thread 行 + 消息行"的三段式，类型定义在 `packages/chatbox-core/src/session/session-tree/types.ts`：`SessionTree = { session: SessionRecordV2, threads: ThreadRow[], messages: MessageRow[] }`。消息行带 `parentMessageId`、`activeChildId`、`siblingOrder`、`kind`（`message`/`summary`）、`status`（`generating`/`settled`）与 `branchId`，树形拓扑本身就是权威数据；会话头只保留提交身份与可重建的展示摘要，`session/session-tree/decode.ts` 会拿行重新核对根、激活叶与摘要计数。

编码方向由 `session/session-tree/encode.ts` 承担：把旧的数组式 `Session`（`messages[]` + `threads[].messages[]` + `messageForksHash`）展开成行树，并在 `verifySessionTreeRoundTrip` 里校验往返一致；`application/session/compatibility/` 处理旧会话的加载与 row 格式转换。1.1 以下的 thread、fork、summary 语义说的是"用户可见的概念如何映射到这棵树"，字段级 schema 仍保留在 `src/shared/types/session.ts`，负责定义单条消息与 fork 视图的形状。

### 1.1 会话列表分组：只认 `starred`，不知道 thread/fork 存在

`SessionMetaSchema`（`src/shared/types/session.ts:390-400`，由 pick 挑选字段）只包含列表展示所需的元信息，**不包含** `threads`、`messageForksHash`、`messages` 等消息级结构。挑选的字段如下：

- `id`/`name`：标识与标题；
- `starred`/`hidden`/`archivedAt`：置顶与归档状态；
- `assistantAvatarKey`/`picUrl`/`backgroundImage`：展示图；
- `type`：会话类型。

`src/renderer/components/session/SessionList.tsx` 的分组逻辑只按 `starred` 分成 "Pinned" / "Chats" 两组。侧栏拿不到 thread/fork 数据，所以"会话列表分组"在数据结构层面就和 thread/fork 无关。

### 1.2 Thread：同一个 Session 内部的"历史区间"

`SessionThreadSchema`（`src/shared/types/session.ts:357-363`）：`{ id, name, messages, createdAt, compactionPoints? }`，存在 `session.threads: SessionThread[]` 里，是**同一个 Session 对象内部**的字段，不是独立记录。

产生 thread 的时机（renderer 入口在 `src/renderer/stores/session/threads.ts`，实际操作由 `@chatbox/core` 的 `ThreadService` 执行）：

- `switchThread(sessionId, threadId)`（`threads.ts:68-109`）：把**当前**消息打包成一个新 thread 塞进 `session.threads`，再把目标 thread 的消息换上来做当前消息——即"交换当前窗口与某个历史窗口"（经 `updateSessionWithMessages` 的队列 current 回调完成），且压缩点随各自消息列表一起交换（归档的 thread 保留当前会话的压缩点，恢复的会话取目标 thread 自己的压缩点，见 `threads.ts:89-106` 注释与代码）；
- `refreshContextAndCreateNewThread`/`startNewThread`（`threads.ts:115-148, 150-157`）：把当前消息整个存成一条新 thread，当前消息清空成只留 system prompt，`compactionPoints` 清空；
- `compressAndCreateThread`（`threads.ts:195-252`，上下文压缩/摘要功能触发）：同样把旧消息存成 thread，当前消息替换为"system prompt + 一条包含压缩摘要文本的 user 消息"，并清空 `messageForksHash` 与 `compactionPoints`。

Thread 边界在数据侧的呈现：`getCurrentThreadHistoryHash(session)`（`sessionHelpers.ts:1106-1132`）把每个 thread 的**第一条消息 id** 映射成一个 `SessionThreadBrief`（`session.ts:413-420`），作为渲染层插入 ThreadLabel 的依据（界面呈现见 Chat UI 笔记）。

### 1.3 Fork：某条消息之后的"平行分支"

`messageForksHash`（`src/shared/types/session.ts:386`）以**分叉点消息 id** 为 key，值为"各分支消息数组 + 当前激活分支下标 + 创建时间"；它挂在会话对象（或其 thread）上，和侧栏无关（`MessageForkSchema` 定义在 `session.ts:351-355`）。

纯变换逻辑在 `shared/session/message-forks.ts`，只导出"算出一个 `Partial<Session>`"的纯函数——切换分支、创建分支（含不切换的"备用分支"）、删除分支与展开分支各有对应的 patch 构造函数，另有消息定位函数；renderer 侧 `stores/session/forks.ts` 负责把 patch 应用到会话并写回。函数与行号清单见本节末尾。

- `shared/session/message-forks.ts`：`buildSwitchForkPatch`（:173）、`buildSwitchForkToPatch`（:181）、`buildCreateForkPatch`（:327）、`buildCreateInactiveForkPatch`（:391）、`buildDeleteForkPatch`（:446）、`buildExpandForkPatch`（:490）、`findMessageLocation`/`findMessageSourceThread` 等定位函数
- `stores/session/forks.ts`：`createNewFork`（:27）、`createInactiveFork`（:52，保存替代回复但不切换）、`switchFork`（:94）、`switchForkTo`（:117）、`deleteFork`（:140）、`expandFork`（:164）

`insertMessage`/`updateMessage`/`removeMessage`（renderer 写入入口在 `src/renderer/stores/session/messages.ts`，提交落 `RowBackedSessionRepository`）都要同时处理"消息可能在 `session.messages` 里，也可能在某个 thread 的消息里、或某个 fork list 里"三种情况——即 fork 和 thread 是可以叠加共存的两套坐标系。

`insertMessage` 在带 `previousId` 插入时还会跳过紧随其后的锚定摘要消息——"摘要紧贴其边界之后，两者之间不得插入其他消息"（`:625-631` 注释）。

`removeMessage` 会在全部分支列表里查找并删除目标消息（`removeMessageFromSavedForks`），同步清理该消息引用的压缩点，随后 `cleanupEmptyForkBranches` 在**同一个函数内**处理两条路径：root 消息层命中时改写消息数组并自动切换分支，thread 层命中时只更新 hash。

### 1.4 Summary：消息级压缩标记与压缩点

`Message.isSummary: boolean`（`src/shared/types/session.ts:331`），由自动压缩机制在某条消息上打标记，UI 用专门的 `SummaryMessage` 组件渲染，提供"删除摘要，恢复原始消息参与上下文计算"的操作。

压缩的数据语义：压缩不只打 `isSummary` 标记，还在 Session/thread 上持久化 `compactionPoints`（`CompactionPointSchema`，`session.ts:337-341`），每项以 `{ summaryMessageId, boundaryMessageId, createdAt }` 配对——boundary 是摘要覆盖范围的边界消息。

共享层 `shared/context/compaction-points.ts:19-40` 的 `findLatestApplicableCompactionPoint` 要求边界与摘要两条消息都存在于当前消息路径上才生效；fork 分支切换可能拆散最新契约，此时跳过并回退到更早仍完整的压缩点。

renderer 侧由 `src/renderer/packages/context-management/compaction-boundary.ts`（boundary 必须通过上下文合格性过滤且不能是摘要自身）负责挑选边界，提交动作走 `@chatbox/core` 的 `SessionService.commitSessionCompaction`（应用层在同一提交里写摘要行、压缩点与 thread 摘要）。

复制会话/挪 thread 成独立会话时，`remapCompactionPoints`（`src/shared/types.ts:313-337`）按完整 id 映射重映射压缩点，映射不上的点被丢弃（`stores/session/crud.ts:92-102`）。

**触发阈值**：`compaction-detector.ts` 的 `checkOverflow`（`:31-58`）按下式判定；其中固定输出预留 32,000 token，默认阈值系数 0.6，`compactionThreshold` 可经全局设置调整（常量定义与取值见 `:4-5、:49`）；未知模型（无法确定 contextWindow）不触发。

```text
isOverflow = tokens > max(contextWindow - 32000, contextWindow*0.5) * compactionThreshold
```

`compaction.ts`（`:57-125`）先按会话估算 token（带 react-query 缓存）再触发上述判定；压缩执行链（`runCompactionWithStreaming`，`:167-263`）：生成摘要（流式 UI 态）、打摘要标记、找 boundary、构建压缩点，最终原子提交；摘要流式期间 boundary 若被删除则放弃提交（`:240-247`，不报错，下次发送重试）。

### 1.5 ForkMarker：唯一真正打通"消息级"与"会话级"的地方

`Message.isForkMarker` + `forkedFromSessionId`（`src/shared/types/session.ts:332-333`）是第四个概念：把 thread 挪成独立会话、或复制会话时，复制流程（`crud.ts:53-123`）会在**新会话**顶部插入一条 `isForkMarker: true` 的助手消息，该字段指回源会话 id。**这是唯一一处"消息级分支"和"侧栏新增一个会话条目"产生真实关联的地方**——把一段 thread 历史"独立"出来，就是新建一个会话元记录。

**结论**：会话列表分组（starred）、thread（同会话内的历史区间）、fork（同一消息位置的平行分支）、summary（消息级压缩标记）是四套彼此独立的数据结构和交互面，唯一的交叉点是"move thread to conversations"这个操作会把 thread 数据转成一个新的顶层会话。

## 2. 事实源、索引与持久化

### 2.1 行式 SQL 事实源

消息与会话结构落在 SQLite 行表里。物理文件沿用 Capacitor 驱动为历史逻辑库名固定下来的四个名字：`chatboxSQLite.db`（键值）、`chatbox-session-metaSQLite.db`（会话元数据）、`chatbox-image-generationSQLite.db`、`chatbox-messagesSQLite.db`（行存储）。表定义集中在 `packages/chatbox-core/src/persistence/capacitor-compatible-schema.ts`。

- `session_meta`：每会话一行，包含标识、名称、置顶/隐藏/归档时间、头像与背景图、类型、`sort_order`、`created_at`、`recovery_archived`，以及迁移补上的 `folder_id`。
- `session_threads` / `session_messages`：thread 行与消息行；消息行带父子指针、激活子节点、兄弟序、类型、状态与完整消息 payload。
- `session_row_revision_guard`、`session_row_heads`、`session_row_staging_mutations`、`session_row_delete_receipts`：提交版本护栏、当前 revision 的行头、暂存 mutation 与删除 receipt。

行存储有意**不建外键和 CHECK 约束**：Capacitor 与原生驱动对 `foreign_keys` pragma 的默认值不一致，因此 `SqlSessionRowStore`（`packages/chatbox-core/src/persistence/session-row-sql.ts`）在每次写入前自行校验身份。单条消息的 payload 是"一条持久 JSON 值"；超过 16 KiB 时按 `sqlTextSlices` 切成传输分片（`session-row-sql-text.ts`），落盘仍是单一值。

### 2.2 应用层：端口、写队列与迁移

会话写入不再由 renderer 直接操作存储，而是经 `packages/chatbox-core` 的应用服务：`SessionService` 暴露列表、创建、复制、thread/fork 结构命令、压缩提交与 token 计划；`SessionWriteCoordinator` 统一写冲突与会话不存在错误；`SessionRowWriteQueue` 串行化同一会话的行提交；`RowBackedSessionRepository` 把端口调用翻译成 `SessionTree` 读写。存储以端口注入（`ports/session-row-store.ts`、`ports/session-row-repository.ts`、`ports/session-record-store.ts`），测试与内存场景用 `memory-session-row-store.ts`、`testing/InMemorySessionRowStore.ts`。

旧格式迁移由 `SessionRowMigration` 承担，分 source、validation、publication 三段执行，并用 `verifySessionTreeRoundTrip` 校验行树往返一致；`application/session/compatibility/` 负责旧数组式会话的加载与转换。

### 2.3 会话列表、索引与分页

侧栏列表只读 `session_meta`。可见列表用 partial index `idx_session_meta_list`（`starred, folder_id, sort_order DESC`，`WHERE hidden = 0`）与归档索引 `idx_session_meta_archived`（`archived_at DESC`，`WHERE archived_at IS NOT NULL`），避免归档行和子 agent 行把可见页与计数拖进全表扫描；另有早期的 `idx_session_meta_sort_order`。

排序语义由 `capacitorSessionListOrderBy(folderIds)` 生成：置顶行在前，其次按文件夹顺序，未归入文件夹的散会话在后，组内按 `sort_order` 降序。`sortSessionRecords`（`packages/chatbox-core/src/utils/session-sort.ts`）在市内存侧重排时保持同一语义。

分页实现按平台分流：桌面与 Web 是 IndexedDB（`src/renderer/storage/SessionMetaStorage.ts` 的 `IndexedDBSessionMetaStorage`），移动端是 SQLite（`SQLiteSessionMetaStorage.ts`），选择逻辑在 `src/renderer/platform/`。页大小与游标细节本次未逐常量复核。

### 2.4 排序落地：分数索引

`sort_order` 仍是分数索引：新建会话默认取当前时间戳，插入到指定位置时取相邻记录 `sortOrder` 的平均值；`SessionService.moveSessionToFolder` 可同时改文件夹与排序值。移动一项只改一行。拖拽入口是 `src/renderer/stores/session/crud.ts` 的 `reorderSessions(activeId, overId)`，参数已改为拖拽源/目标会话 id，由目标位置反算新分数。

### 2.5 存储 schema 的演进策略

会话元数据有两个实现、一套接口：桌面与 Web 用 IndexedDB，不主动指定 version，只做加法式 schema 变化，降级客户端遇到 `VersionError` 由 `src/renderer/storage/db-schema-guard.ts` 识别为升级墙并引导更新；移动端用 SQLite 表结构，随列迁移演进。行存储侧用 `rowFormatVersion`（当前 3）与 `SessionRowMigration` 表达格式变化。## 3. 创建、切换、归档、删除与恢复

### 3.1 惰性创建：首条消息才落地持久会话

首页仍是 `'new'` 假会话（React 状态 + `'new-chat'` 草稿 key）。`src/renderer/routes/index.tsx` 的 `handleSubmit` 在首条消息时完成落地：

1. 调 `SessionService.createSession` 建 `session_meta` 行与会话头，并把首页临时状态里的 agentMode、工作目录与全权限开关**直接内联进 `settings`** 一次写入。
2. 首页临时状态里若有知识库绑定：把绑定转移到真实 id，然后整体清空临时状态（工作目录与全权限已在第 1 步内联，清空不会丢数据）。
3. `sessionWebBrowsingMap.new` 存在时转到新 id 并清掉 `'new'` 项；`sessionAgentModeMap.new` 只需清键。
4. `switchCurrentSession(newSession.id)` 跳到真实会话，再删掉 `'new-chat'` 草稿 key（真实会话用 `draft-${sessionId}`）。

新会话默认延续上次使用的模型：`SessionService` 创建时先套一层上次模型记录，再用调用方 settings 覆盖；元数据更新也统一经应用层服务处理。

### 3.2 置顶 / 归档 / 恢复 / 永久删除

全部通过 `session_meta` 行上的字段完成，没有单独的归档表：

- **置顶**：`starred` 布尔位，写 meta 行后重排列表缓存。
- **归档**：`hidden: true` + `archived_at` 时间戳；主列表分页与计数都过滤隐藏行，归档页按 `archived_at` 独立索引倒序。**不删除任何数据**。
- **批量归档**（清空会话列表）与单个归档同路径，逐条改 meta 行；过程中会回收"meta 行存在但行存储缺失"的失效条目，并清理附件 RAG 索引与运行时状态。这仍是一处写在代码注释里的已知性能取舍。
- **恢复**：`hidden` 置回 false 并清掉 `archived_at`，**不重置 `sort_order`**——恢复后回到归档前的排序位置，可能落在列表很靠下的位置。
- **归档撤销**：侧栏归档成功后显示带 Undo 的 toast，撤销失败保留重试入口；归档页也可恢复或一次性删除全部归档。入口见 `src/renderer/components/session/SessionItem.tsx` 与同目录 `SessionList.tsx`。
- **永久删除**：删除整棵消息树与 `session_meta` 行，并清理该会话的附件 RAG 索引、主列表与归档列表缓存、UI map（网页浏览/知识库/agentMode）、解析与滚动缓存、未读活动与挂起队列；桌面端还会清理沙箱里该会话的落地文件。

删除确认只在桌面端、且仅当该会话在沙箱里有可下载产物（`platform.sandboxHasArtifacts`）时弹出，归档页的删除按钮复用同一确认。

**数据恢复**：meta 行损坏或缺失时，仍可从会话头与消息行重建列表；领域服务逐条容忍读不出的会话，把这类条目以仅元数据的 `recoveryArchived` 记录保留，便于稍后修复、导出或撤销恢复，正常完整写入会清除该标记。写入协调器把恢复归档与待处理的完整会话写串行化，避免恢复动作覆盖较新的队列写入。实现见 `packages/chatbox-core/src/application/session/SessionService.ts` 与 `SessionWriteCoordinator.ts`。
## 4. 编辑、重试、续写、回退与分支语义

- Fork 的数据语义见 1.3：重新生成/继续生成经 `src/renderer/stores/session/generation.ts` 触发结构命令，由行树上的兄弟行与 `activeChildId` 记录激活分支；`createInactiveFork` 保存替代回复但不切换（`forks.ts:52` 起，供"在下方继续回复"使用）。
- "把 thread 挪成独立会话"与"复制会话"都会 `copySession(...)` 在**新会话**顶部插入 `isForkMarker` 消息并指回源会话（1.5），即会话级复制在数据上就是新建一个 `SessionMetaRecord`。
- 分支清理存在 root 层与 thread 层两条相似但不完全对称的路径（`cleanupEmptyForkBranches`）：root 层命中时改写激活子节点并自动切换分支，thread 层命中时只更新 thread 上的分支投影。
- 编辑、删除、重试产生的数据变更入口是 `insertMessage`/`updateMessage`/`removeMessage`（`src/renderer/stores/session/messages.ts`）；重试、续写、再生成的**执行链**（如何选择起始上下文、重新调用模型）在对话请求与上下文笔记。

## 5. 列表、分页、搜索与定位

- **会话列表**：react-query 无限查询 + `session_meta` 游标分页（2.3）。`src/renderer/components/session/SessionList.tsx` 的触底回调触发翻页（`fetchNextPage()`），有下一页时挂加载脚注。
- **会话项活动指示（不持久化）**：侧栏的"生成中/回复完成未读"指示来自内存 zustand store（`sessionActivityStore.ts` + `stores/session/generation-runtime.ts`），以会话 id 为 key 的临时集合，**不写 `SessionMetaRecord`、不落盘**，重启即清空——`SessionMetaSchema` 仍是侧栏唯一的持久化认知（界面呈现见 Chat UI 笔记 1.2）。
- **消息搜索**：Chatbox 有一套独立于消息列表渲染的搜索实现。跨会话与跨 thread 的候选集由 `@chatbox/core` 的 `SessionSearchService` 读取搜索候选窗口（`ports/session-search-source.ts`、`application/session/row-search.ts`），匹配规则仍在 `src/shared/services/native-session-search.ts`，覆盖文本、推理、信息与工具调用状态及文件名。
  跨会话时按元数据分页取候选、逐页扫描命中，分页大小与结果上限本次未逐常量复核。这套实现**没有持久化倒排索引**，跨会话搜索仍是按页读取并逐条扫描；它不受 Virtuoso 虚拟窗口的 DOM 挂载范围限制。搜索入口与结果定位的工作流在 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

- **队列的持久性与因果锚点**：每个队列项保存完整用户消息、入队时间和入队时最新会话消息 ID。队列状态同步写入 localStorage；投递期间条目继续保留并标记 in-flight，写入完成后才移除，刷新恢复时会清掉过期的 in-flight 与 steering 请求。若因 fork/thread 切换导致锚点不再属于当前路径，队列暂停而不盲发。`src/renderer/stores/session/message-queue.ts:20-96,196-379`。
- **Steering 消息**：被显式提前发送的用户消息以 `steered: true` 写入 Session，再进入当前模型 step。字段契约见 `src/shared/types/session.ts:380-381`；先持久化再注入的顺序见 `src/renderer/stores/session/steering.ts:78-154`。
- **两条写路径**：缓存更新路径（`src/renderer/stores/session/messages.ts`）只改 react-query 缓存，**不碰存储**；`persistStreamingMessage(...)` 走每会话一个的写队列（`stores/updateQueue.ts`，基于微任务的串行合并队列，写入失败会回滚内存状态并拒绝本批全部更新），**真正落在行存储**。节流策略（2 秒定时 + tool-call 特例）属于对话请求与上下文笔记。
- **缓存合并保护**：元数据更新与磁盘快照回填都会带 `preserveCachedGeneratingMessages: true` 语义，实际合并逻辑仍是 `mergeCachedGeneratingMessages`：磁盘上读回较旧的会话快照要写回缓存时，若某条消息在缓存里处于生成中，就保留缓存里更新的内容，不用旧内容覆盖；合并覆盖消息、各 thread 消息与分支哈希三个层级。这是为了防止"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的内容。
- 删除生成中的消息同样走带合并保护的全量写路径，合并只映射仍然存在的消息，不会复活已删除消息。
- **删除时的状态清理**：删除路径统一清理 query 缓存、UI map、atom 缓存、滚动位置、未读活动与挂起队列（3.2）。

## 7. 迁移、导入导出与保留策略

- 平台存储的 schema 演进策略见 2.5：IndexedDB 只做加法式变更、不做 version 升级，SQLite 侧随列迁移演进。
- 备份导入不依赖 `crypto.randomUUID`（部分浏览器/WebView 环境缺失该 API 时用回退 id 生成），导入在移动/Web 端更稳（`stores/migration.ts` 与 `migration-error.ts` 负责迁移流程与错误上下文，本次未逐行展开迁移 schema 明细）。
- 导出：`exportChat` 已迁到 `packages/chatbox-core/src/backup-export/`，范围与格式枚举本次未逐函数复核，导出内容的界面入口在 Chat UI 类目。
- 导入导出、备份恢复、崩溃恢复与多窗口竞争在本类目范围内未做运行验证（见未验证事项）。

## 8. Agent、模型、知识库与附件绑定

- **首次创建时内联**：工作目录、全权限开关与 agentMode 在首条消息落地时（`routes/index.tsx` 的 `handleSubmit` 调 `SessionService.createSession`）直接内联进新会话的 `settings`（3.1）；正式会话的 agentMode 也有持久化路径：`setSessionAgentMode`（`stores/session/agent-mode.ts:101` 起）写 `session.settings.agentMode`。
- **知识库**：前端状态只存 `Pick<KnowledgeBase, 'id'|'name'>` 句柄（`uiStore.sessionKnowledgeBaseMap` 或新会话的 `newSessionState.knowledgeBase`），绑定以会话 id 为 key；真实检索发生在生成阶段（见对话请求与上下文笔记）。
- **Copilot**：选中 copilot 时把会话的 `copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`（`routes/index.tsx:211-234`）——创建出来的仍然是一个普通 chat 类型会话，只是多了该字段用于用量统计（`routes/index.tsx:302-306`）。
- **网页浏览**：`sessionWebBrowsingMap`（`uiStore.ts:36`）按会话 id 保存布尔开关。uiStore 使用 zustand 持久化中间件（`uiStore.ts:20-21`），`partialize` 只持久化下列五个字段（`:235-241`）：
  - `widthFull`
  - `showCopilotsInNewSession`
  - `sidebarWidth`
  - `agentModeSmartSwitchingDefault`
  - `sessionWebBrowsingMap`

  即网页浏览开关**跨重启保留**，而 `sessionKnowledgeBaseMap`、`sessionAgentModeMap`、`newSessionState` 不持久化、重启丢失。默认值规则（ChatboxAI provider 默认开、其他 provider 默认关）见 `stores/session/utils.ts:33-40`。

## 9. 设计取舍与已确认边界

- **批量归档故意不做性能优化**：代码注释直接承认逐条更新 meta 行、不针对超大批量归档做优化，是被记录在案、而非被忽略的工程取舍。
- **恢复归档会话不重置 `sortOrder`**：恢复后出现在归档前位置而非列表顶部，可能与用户预期不符。
- **Fork 清理双路径收敛**：`cleanupEmptyForkBranches` 合并为单一函数内的 root/thread 两条路径，root 层改写激活子节点并自动切换分支、thread 层只更新 thread 上的分支投影，两者行为仍不完全对称。
- **IndexedDB 无 version 升级**：兼容降级客户端的代价是 schema 只能加法演进（2.5），SQLite 侧则由列迁移承担。
- **首页临时状态耦合**：`newSessionState` 整体清空依赖"workingDirectories/agentFullAccess 已内联进 settings"这一隐式顺序（3.1），代码注释明确但不直观；`newSessionState.webBrowsing` 字段在类型中声明但全仓库无读写点（Chat UI 笔记 3.1）。
- **类目边界**：本笔记只回答数据语义；停止生成的半截消息最终如何落盘、重试如何选择上下文属于对话请求与上下文；列表虚拟化、滚动锚定与消息壳装配属于消息渲染器（`../消息渲染器/Chatbox-消息渲染调查笔记.md`）。

## 10. 未验证事项

- 压缩的**运行行为**（摘要质量、长会话下的触发频率、boundary 消失竞态的实际发生频率）未运行验证；触发阈值公式本次未逐常量复核（1.4）。
- provider 侧 token 截断策略、导入导出、崩溃恢复、多窗口并发写入需要运行验证。
- 平台存储迁移、行树 V1→V2 迁移的实际执行结果未验证（2.2、2.5）；队列大小、搜索分页与结果上限等常量本次未逐条复核。
- 侧栏"生成中/未读完成"指示为内存态，跨重启/多窗口的同步行为未验证（5）。
- 迁移模块（`src/renderer/stores/migration.ts`）的 schema 明细未逐行展开（7）。

## 11. 关键源码索引

- `packages/chatbox-core/src/session/session-tree/types.ts`（`SessionTree`/`SessionRecordV2`/`ThreadRow`/`MessageRow` 行树类型）
- `packages/chatbox-core/src/session/session-tree/encode.ts`、`decode.ts`、`normalize.ts`、`verify.ts`（数组式会话与行树互转、往返校验）
- `packages/chatbox-core/src/application/session/SessionService.ts`（列表、创建、复制、结构命令、压缩提交）
- `packages/chatbox-core/src/application/session/SessionWriteCoordinator.ts`、`SessionRowWriteQueue.ts`、`RowBackedSessionRepository.ts`、`SessionRowMigration.ts`（写协调、队列、行读写与迁移）
- `packages/chatbox-core/src/persistence/capacitor-compatible-schema.ts`（四库文件、`session_meta`/thread/消息行表与索引）
- `packages/chatbox-core/src/persistence/session-row-sql.ts`（`SqlSessionRowStore`）、`session-row-sql-text.ts`（16 KiB 分片）、`memory-session-row-store.ts`
- `packages/chatbox-core/src/ports/session-row-store.ts`、`session-row-repository.ts`、`session-record-store.ts`（存储端口）
- `packages/chatbox-core/src/utils/session-sort.ts`（`sortSessionRecords`、列表分组）
- `src/shared/types/session.ts`（`Message`/`SessionThread`/`MessageForkSchema`/`CompactionPointSchema`/`SessionMetaSchema`）
- `src/shared/session/message-forks.ts`、`src/shared/context/compaction-points.ts`（fork 纯变换与压缩点适用性）
- `src/renderer/storage/SessionMetaStorage.ts`、`SQLiteSessionMetaStorage.ts`、`db-schema-guard.ts`（平台 meta 存储与 schema 升级墙）
- `src/renderer/stores/session/threads.ts`、`forks.ts`、`crud.ts`、`messages.ts`、`generation.ts`、`message-queue.ts`、`steering.ts`
- `src/renderer/stores/sessionHelpers.ts`、`src/renderer/stores/updateQueue.ts`
- `src/renderer/packages/context-management/compaction-detector.ts`、`compaction.ts`、`compaction-boundary.ts`
- `src/renderer/components/session/SessionList.tsx`、`SessionItem.tsx`（列表分组与归档/恢复入口）
- `src/renderer/routes/index.tsx`（首页假会话与首条消息落地）
- `src/shared/services/native-session-search.ts`、`packages/chatbox-core/src/application/session/row-search.ts`（消息匹配与搜索窗口）
