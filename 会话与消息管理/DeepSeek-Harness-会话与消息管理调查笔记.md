# DeepSeek-Harness 会话与消息管理调查笔记

> 调查对象：`../../deepseek-harness`（重点 `packages/core/session`、`packages/session/session-persistence`、`session-persistence-jsonl`、`session-persistence-sqlite`、`session-projection`、`session-projection-cache`、`session-checkpoint-policy`、`packages/core/agent-loop`、`packages/session-query/session-query`、`session-query-sqlite`、`packages/workspace/workspace`、`packages/core/scope`）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：静态源码阅读（核心 session 与 surface、持久化协调器与两个后端、checkpoint policy、投影与投影缓存、agent-loop 事件发射、session-query 及 workspace/scope/匿名身份包，配合 `docs/subsystems/session.md`、`persistence.md` 与生成目录 `docs/persistence-catalog.md` 交叉核对）；未运行测试或交互会话
>
> 调查范围：会话/消息数据模型、事件类型系统与格式版本、持久化后端与崩溃恢复、消息历史派生、投影、fork/resume/transcript 的日志派生、生命周期、列表与检索、外部对象绑定；排除：模型请求的上下文拼装与适配器细节（对话请求与上下文类目）、压缩策略与标题/遥测的 LLM 生成、Chat UI 与 Web 客户端渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的会话是"append-only SessionEvent 日志"，内存中的 `Session` 是交互历史的单一事实源，LLM 消息历史完全从日志派生，不存在独立的消息表：

- 事件类型通过 `SessionEventMap` 声明合并扩展，核心加插件共 24 个事件族（`docs/persistence-catalog.md` 逐条枚举）；只有 `user/message`、`assistant/message`、`tool/result` 三类消息事件（合称 `SurfaceEventType`）产生 LLM 消息并携带 `surfaceOp` 表面标记。
- 格式版本 `SESSION_FORMAT_VERSION` 固定为 `0`，未发布期无兼容承诺：版本不匹配直接拒绝（带方向性提示）而非迁移；新增事件类型不 bump 版本，由信封上的 `ignorable` 标记覆盖词汇增长。
- 持久化是同一抽象契约下的两个可互换后端：JSONL（每会话一个文件，默认 zstd 帧压缩 + packed chunk 行，原子物化、追加+fsync、torn tail 截断修复）与 SQLite（`node:sqlite`，每事件一行，WAL 事务，按 seq 定位读取）。写路径由共享协调器驱动：per-session 串行链 + 固定 200ms 写合并窗口 + `session/flush` 显式屏障 + checkpoint policy 的语义检查点。
- 投影有两层：`session-projection` 对每个已提交事件 eager drive 注册的纯函数单元（如统计、标题），`session-projection-cache` 把单元状态按节流写进存储域（`session_projcache`），缓存只是 fold 捷径，从不权威。
- fork、resume、transcript 都从日志流派生：fork 复制种子并记 `parentSession`/`seedLength`；resume 走 prepare→load→崩溃修复→发布；人类可读 transcript 读 append-origin 事件，而模型历史读表面（surface 会遮蔽被压缩替换的范围）。

## 系统边界与数据主链

```text
用户/注入消息进入 inbox（queued input）
  -> AgentLoop.turn() append 'turn/start'（agent.ts:246-330）
  -> preStep 认领 inbox -> append 'step/start' -> 逐条 append 'user/message'（surfaceOp: append，agent.ts:283）
  -> buildRequest：session.deriveMessages() 取当前表面消息（agent.ts:340-342）
     并 append 'request/header'（initial/resume/change）与 'request/context'（agent.ts:458-483）
  -> checkpoint policy 在 llm/stream 前 await ctx.sessions.flush()（session-checkpoint-policy/src/index.ts:63-68）
  -> 流式输出：每条 chunk append 'assistant/chunk'（agent.ts:349）
  -> 组装完成 append 'assistant/message'（sourceEventSeqs=chunkSeqs，agent.ts:381-390）
  -> 工具：append 'tool/call'（tool-calls.ts:263）；tools/execute 前再 flush；完成 append 'tool/result'（tool-calls.ts:281）
  -> finally 中 append 'step/end'（agent.ts:292）；回合结束 append 'turn/end'（agent.ts:319）
  -> 持久化：coordinator 监听 session/event，事件入 per-session 写队列
     （200ms 窗口后 appendBatch：JSONL 追加 zstd 帧 / SQLite 事务 INSERT，coordinator.ts:1086-1137）
  -> 投影：SessionProjectionRegistry 同步驱动各单元（session-projection/src/index.ts:181）
     -> sessionProjectionCache 在 turn/end 与 dispose 强制 checkpoint（session-projection-cache/src/index.ts:205-230）
  -> 下次请求 deriveMessages 重新投影；崩溃后 load 做 torn tail 截断 + 合成 interrupted closers
```

边界：模型请求如何拼装（系统提示、工具 schema 组装、retry）属于对话请求与上下文类目；会话侧栏、界面动作属于 Chat UI 类目；本笔记只覆盖"保存了什么、如何恢复、如何查询"。

## 1. 会话单位与标识

- 会话 id 是 `Branded<'SessionId'>` 字符串（`packages/core/session/src/types.ts:22-31`）。`SessionStore` 省略 id 时铸造 `session-<n>` 计数器 id（`packages/core/session/src/index.ts:866`），显式 id 用于 resume/fork 的既有身份。
- 一个 agent 恰好持有一个会话：注册时强校验 `agent.id === agent.session.id`（`packages/core/agent/src/index.ts:476-478`）。
- 子 agent 会话在 header 上标记 `origin: 'subagent'` 与 `delegationDepth`（父深度 +1），供递归预算跨重启存活；这属于展示元数据，不证明子会话可继续。
- 工作区归属用 header 的绝对 `cwd` 判定：`Workspace.attachSession(id)` 校验会话 cwd 与工作区路径匹配后记账（`packages/workspace/workspace/README.md`）；会话本体不感知工作区。

## 2. 消息模型：事件日志与派生历史

- **日志结构**：`Session` 是 `SessionEvent[]` 数组，`seq` 恒等于 `log.length`（连续契约），事件深度冻结、不可修改。`turn/*` 与 `step/*` 是执行围栏：一个 turn 包住一次模型循环（可能多个 step），step 是一次模型调用加其工具执行。
- **消息事件**：三个 `SurfaceEventType` 类型各自携带完整消息，分别承载人机三种角色：
  - `user/message`：完整 `UserMessage`，人提示、`agent.inject()` 合成上下文、目标续写回合共用同一表示，`source` 区分来源；
  - `assistant/message`：组装后的 `AssistantMessage` 加可选 `usage`（token 记账随消息同行，无独立 usage 记录）；
  - `tool/result`：`ToolResultMessage`（user 角色、单个 `tool-result` 块），`callId` 与 `tool/call` 配对。
- **表面与来源**：每条消息事件必须带 `surfaceOp`（`'append'` 或 `{ op: 'replace', start, end }`）与可选 `sourceEventSeqs`。表面是消息产生事件的可见序列，也是派生历史的唯一来源；`assistant/chunk`、turn/step 边界、`llm/retry` 等结构性事件不进表面。
- **派生规则**：`user/message` 原样投影为用户消息；`assistant/message` 投影为助手消息（空 content 的 max-tokens 记账消息跳过）；`tool/result` 投影为带工具结果块的 user 角色消息；其余返回 null（`deriveEventMessage`，`packages/core/session/src/surface.ts:83-114`）。
- **缓存**：`Session.deriveMessages()` 沿表面节点折叠，每节点投影一次，`replaceGeneration` 变化时整缓存重建（`packages/core/session/src/index.ts:726-747`）。

## 3. 事件类型系统与格式版本

- **词汇表**：`SessionEventMap`（`packages/core/session/src/types.ts:236-333`）声明 13 个核心事件；插件通过 declaration merging 追加自己的类型（compaction 三件套、hook 桥、标题、计划模式、命令生命周期等）。`docs/persistence-catalog.md` 由 `scripts/gen-persistence-catalog.ts` 生成，逐条枚举全部 24 个族及其载荷、surface 徽标与声明位置；`KNOWN_SESSION_EVENT_TYPES`（`packages/core/session/src/known-event-types.ts`）是同一生成的运行时集合。
- **信封**：每条事件为 `type/seq/time/data` 加可选 `ignorable: true`；surface 事件额外带 `surfaceOp`/`sourceEventSeqs`（`types.ts:404-436`）。`ignorable` 缺失意味着"必须理解"：读者遇到不认识的类型且无该标记时必须拒绝重建，而不是静默跳过。
- **版本机制**：`SESSION_FORMAT_VERSION = 0`（`types.ts:56`）。bump 判据只取决于写方能否被旧运行时正确读：header 形状、事件信封、核心事件语义、surface 机制的结构性变化才 bump；新增普通事件类型不 bump。加载时版本不匹配抛方向感知的 `SessionFormatUnsupportedError`（新日志→提示升级 harness，旧日志→声明无升级路径，`coordinator.ts:77-81`），JSONL 后端在解码任何事件行之前就从首行版本号拒绝。
- **遗留形状归一化**：当前构建仍读取若干 pre-identity 时代的日志形状并在读路径迁移，同时拒绝已删除的词汇：
  - 升级为当前形状：`steering/message` 转 `user/message`（注入 `legacy-message:<id>:<seq>` 身份）、`turn/start` 移除 trigger、`turn/end` 的 disposed 原因并入 aborted/legacy，error 扁平化；
  - 直接拒绝：`request/header-delta` 事件与 `request/header` 的 `fallback` 原因。
  - 实现见 `coordinator.ts:273-290` 与 `migrateLegacy*` 系列。

## 4. 事实源、持久化与派生历史不变量

- **三层数据**：内存事件日志是运行时权威；持久化后端是磁盘投影（两个后端都承诺"逐事件无损持久化，含 chunk，seq 连续"）；投影缓存是折叠捷径（可能过期，绝不会错误，`session-projection-cache/src/index.ts:9-13` 注释）。文档用"内存 log / durable log / cached projection"三个词分别称呼。
- **model-visible ⟺ logged**：仓库约定"任何到达模型请求的内容必须能从会话日志重建；新的 model-visible 输入必须落成 session event"。支撑机制有三：`request/header` 事件把每次请求的完整信封（config、system、tools）以全量快照记入日志，`foldRequestHeader` 选最新快照重建请求（`packages/core/session/src/request-header.ts`），使请求成为日志的纯函数；seed/load 边界校验消息身份、`source.kind`、provider/model 存在，缺失即拒绝而非猜测（`packages/core/session/src/index.ts:253-352`）；派生历史与外部重建器共用同一 `deriveEventMessage`，不会与缓存分歧。
- **header 与日志分离**：`SessionHeader`（version/id/createdAt/cwd/parentSession/seedLength/origin/delegationDepth/agentPreset）是存储元数据，不进事件日志、不进派生历史；`session.header` 总是存在（无 store 头时合成最小头）。
- **持久化契约**：抽象 `SessionPersistence`（`packages/session/session-persistence/src/index.ts:84-241`）定义 `locate/create/append/prepare/load/inspect/readFrom/list/listSnapshots`，`readRaw` 默认拒绝。追加批次的首个 `seq` 必须等于存储的 next-seq（load 先持久化关闭中断回合）。

## 5. 持久化后端：JSONL 与 SQLite

两个后端实现同一 PersistenceBackend 钩子集（loadStored/readStoredRevision/appendBatch/commitRepair/list），共享持久化协调器的缓冲、串行化、修复与 dispose 编排，并过同一契约测试套件；选型是 cordis.yml 配置层面的互换，不能同时挂两个。

| 维度 | JSONL（`session-persistence-jsonl`） | SQLite（`session-persistence-sqlite`） |
|---|---|---|
| 布局 | 每会话一个目录 `<root>/<projectKey(cwd)>/<encodedId>/session.jsonl(.zstd)` | 一个数据库：`sessions` 表一行 header + `events` 表一行一事件 |
| 物理编码 | 默认 zstd 帧（header 独占一帧），`packChunks` 把连续 chunk 打包成存储行（约小 60%）；可切纯文本 | 事件行 `(session_id, seq, type, time, data, source_event_seqs, surface_op, ignorable)` 与信封 1:1 |
| 原子性 | 首写物化用临时文件 + `link()` 发布（EEXIST 防并发覆盖）；追加失败回滚 truncate 到原长度 | append 批次与 repair 各是一个事务；`revision` 每次写入 +1 |
| 读取 | 顺序媒体：`readFrom` 解析全文件再跳过；列表只读首行 header | 按 seq 直接 SELECT 后缀（`loadStoredFrom` 钩子），列表读 `sessions` 表 |
| 崩溃修复 | 截断 torn 尾部到字节偏移 + 补 recovered events 与 closers | DELETE `seq >= tornFrom` + INSERT closers |
| 产物 | `supportsRawArtifacts = true`，`readRaw` 返回逐字节原文（ZIP 导出依赖它） | `false`，无每会话独立产物 |

关键实现定位：JSONL 后端的 `appendBatch`/`commitRepair`/`materialize` 见 `packages/session/session-persistence-jsonl/src/index.ts:422-626`，SQLite 后端事务写入见 `packages/session/session-persistence-sqlite/src/index.ts:284-338`。

惰性物化：`create` 只记意图，首个 append 才落盘，废弃会话不留文件（`coordinator.ts:645-658`）。

## 6. 生命周期：创建、resume、fork、销毁与恢复

- **创建**：`SessionStore.create` = `prepare` + `enter` + `announce` 三步（`index.ts:830-841`），agent 工厂则把这三步折叠进自己唯一的 effect，保证循环关闭事件在 store 摘除前落定。
- **resume**：`AgentRegistry.resume` → 工厂 `persistence.prepare(id)`（`agent-loop/src/index.ts:653-702`）。协调器的 prepare 做 revision 稳定性往返（日志在"读/查"一圈内不变才算收敛），返回独占的未发布 `SessionPreparation`；`Session.fromRestore` 以所有权转移方式校验并冻结存储对象，发布后 dispose 释放预约。有 5 项 LRU 的已备会话缓存供重复读取复用。
- **fork**：`SessionStore.fork(source, boundary?, childId)`（`index.ts:1081-1095`）把源会话 0..boundary 前缀深拷贝为种子，子会话 header 记 `parentSession`、`seedLength` 与继承的 cwd。boundary 默认当前末事件，显式边界可以落在独立日志事件上，但落在开着的 turn 内会被拒绝（`OPEN_TURN`）而不是静默裁剪。fork 种子经 `session/created` 持久化一次。
- **销毁**：会话随 owner fiber dispose；coordinator 对 `session/disposed` 做退休排空（flush + 释放状态，`coordinator.ts:1140-1161`），自身 dispose 先 drain 全部 live 会话再 `close` 后端。**本次未找到会话删除 API**：抽象契约、两个后端、store、协调器均无 delete 入口；workspace 的登记删除与归档只移除分组索引，日志与文件保留（`packages/workspace/workspace/README.md` 明示会话删除与目录删除是独立缺失能力）。
- **崩溃恢复**：`load` 对冷会话做修复——完整中断回合不截断，而是补合成 closers（缺失工具结果错误 `TOOL_NOT_STARTED`/`TOOL_OUTCOME_UNKNOWN` 加 step/end 与 turn/end 的 interrupted 结束，`repair.ts:27`、`index.ts:302-319`），torn 尾部丢弃；interrupted 是唯一循环本身不会发出的结束原因。live 会话不做修复：open turn 的 load 直接拒绝。

## 7. 消息操作与分支语义

- 日志是追加型且不可变：**本次未找到已落盘消息的就地编辑或删除 API**。历史修正以表面替换表达：`surfaceOp: { op: 'replace' }` 把旧表面范围影子化并插入新节点（替换事件必须引用被遮蔽的全部节点 seq，`surface.ts:210-243` 校验）。
- 替换的现有消费者是压缩：`compaction/*` 三事件为日志锁围栏，成功的压缩在 `compaction/end` 前追加一个带 replace 标记的 `user/message` 检查点节点；被影子化的旧事件仍留在原始日志，回放确定性保留（`packages/compaction/compaction/README.md` 的 Surface contract 一节）。表面替换还允许"工具结果仅改 content"的单节点重写（`surface.ts:287-318`）。
- 分支即 fork（§6）；没有"移动 leaf 指针"式的活动路径切换——会话身份与日志绑定，分支是独立子会话。

## 8. 列表、索引与检索

- 会话列表：live `SessionStore.list()` 是内存创建序快照；持久化侧 `list`/`listSnapshots` 只读元数据（JSONL 各文件首行、SQLite `sessions` 表），列表随会话数伸缩而不随日志大小，`listSnapshots` 附带不透明 revision token 供变更检测。无分页游标。
- **查询服务**：`session-query` 是 live-preferred 的逻辑语料层（`packages/session-query/session-query/README.md`），提供精确读取（会话、表面、事件、标题）、关系追踪与两类全文方法；事件读取方法复用核心表面折叠，把每个事件标记为 `current`/`shadowed`/`log-only` 三类。
- 全文检索：唯一具体实现是 `session-query-sqlite`，FTS5 + `unicode61` 分词，查询按字面短语转义（MATCH 语法当数据）；跨会话结果按最强命中事件分组，返回带 snippet 的分页（不透明 branded cursor，generation 变化即失效）；索引是派生的独立数据库，TEMP 表放 live 行、持久表放已落库行，revision 对比后只增量检查新变更日志。`openAt: never` 可整体关闭搜索。
- 标题与统计以投影单元提供：`session-stats` 折叠出 turn/step 计数与 LLM/工具耗时（`packages/session/session-stats/src/projection.ts`），标题单元折叠最新 `session/title` 事件；两者向 `SessionProjectionMap` 声明合并 key。

## 9. 缓存、一致性与并发写入

- 单进程单写者：`Session.append` 同步进内存日志、同步通知监听者（失败按监听器隔离，不改变提交结果），热路径不做 I/O（`index.ts:604-655`）。持久化在后台异步追。
- 串行化：协调器对每个会话 id 维护一条 promise 链，同一会话的写操作永不交错（`coordinator.ts:1010-1033`）；公开方法与内部 `*Core` 分离防死锁。
- 写合并：首个待写事件启动固定 200ms 窗口，后续事件不重置截止；到期落一个批次。`session/flush` 取消等待并 drain 到静默点（并发调用共享同一屏障，`write-behind.ts:63-72`）。后台写失败保留事件并暂停自动重试，新事件开启新窗口；显式 flush 立即重试并把失败报给 `agent/error` 与日志，不以 session event 形式越过已关闭的 turn。
- 检查点语义（`session-checkpoint-policy`）：模型请求流开始前、顶层工具体执行前、每个 pre-step 边界各做一次 flush 屏障（pre-step 屏障把上一步已提交的内容先落盘再进入本步请求），请求前缀先于 adapter dispatch 落盘，失败即 fail-closed（`session-checkpoint-policy/src/index.ts:63-83`）。
- 崩溃一致性：`readStableFile` 用 stat 往返（读前后 revision 一致才返回，JSONL `index.ts:292-304`）；JSONL 物化用 `link()` 防并发覆盖（POSIX）或 Win32 专用发布路径；`commitRepair` 不必原子（文件端两步 fsync，SQLite 端单事务）。
- 多进程：日志本身无跨进程锁；文档明确"容忍并发写者需要日志之外的 liveness 信号"。revision token 只用于检测外部变更并触发重读，不能仲裁。

## 10. 迁移与导入导出

- 版本策略是"拒绝"而非"迁移"：header 版本不符 → `SessionFormatUnsupportedError`；未知事件类型且非 ignorable → 同一拒绝（`coordinator.ts:1061-1066`）。SQLite 另有 `SCHEMA_VERSION` 门控整库结构。投影缓存域 `session_projcache` 自己的 `version: 3`，版本不符时整介质丢弃（缓存语义：多花一次重放，不会给错值）。
- 读路径上的遗留形状归一化（§3）只在内存视图完成；`load` 的 repair 才会把修复合成的 closers 写回。
- 导出：`/export` 命令经 apiproxy 以 ZIP 流式下载会话原始日志（先 flush live 会话，再 `readRaw` 读逐字节原文）；仅 JSONL 后端支持，SQLite 明确不包含导出（`packages/session-query/session-log-export/README.md`）。人类 transcript 由客户端从 append-origin 事件重建（`isAppendSurfaceEvent`，`surface.ts:51-55`），与模型历史刻意不同源：替换拷贝只服务模型，不吞掉用户已见过的对话。
- 导入/备份恢复：**本次未找到**会话级导入 API 或备份机制（检查范围：持久化抽象与两个后端、store、agent resume 入口）。

## 11. 外部对象绑定

- **会话级（header）**：cwd、父会话、种子长度、subagent 标记与深度、agent preset 都随 header 持久化；preset 可恢复会话的工具与提示构成（`types.ts:61-99`）。
- **请求级（日志事件）**：每次请求的 config/system/tools 以全量快照进 `request/header`（reason 区分 initial/resume/change）；路由容量进 `request/context`（仅变化时记录），两者都是 log-only，不产生消息。
- **消息级**：`user/message.source` 区分人、注入与目标续写来源；`assistant/message.source` 携带 provider/model；`tool/result.message.source` 携带 callId 并与 `tool/call` 配对。附件（图片等）在消息 content 块内随消息持久化。
- 身份与作用域：匿名身份 `getOrCreateAnonymousUserId()` 是进程共享库（`$DSH_HOME/.anonymous-user-id`），只进遥测资源属性与 DeepSeek 请求头，不进会话数据（`packages/identity/anonymous-user-id/README.md`）；`dsh-scope` 提供 per-agent 作用域，session 事件经 `scopeTarget` 按作用域过滤派发，注册与生命周期绑定同一 fiber（`packages/core/scope/README.md`）。

## 12. 设计取舍与已确认边界

- **事件日志而非消息表**：全部对话状态可重放，投影按需派生；代价是日志只增不减，chunk 级保真使体积增长，JSONL 用 zstd 帧 + packed chunk 行缓解（`format.ts` 的 `eventLines`），SQLite 则是另一介质选项。
- **模型历史与 transcript 双投影**：surface 遮蔽替换范围、append-origin 事件保留人可见历史，两者同源于日志但语义刻意不同。
- **格式版本零迁移**：未发布期接受"拒绝旧日志"而非迁移链；`ignorable` 把词汇增长与结构性变更解耦。
- **持久化与执行解耦**：`session/event` 同步通知、持久化异步追、checkpoint policy 只卡语义边界（模型请求、顶层工具、pre-step），不在 turn 边界强刷。
- **惰性物化**：无消息的会话不产生文件；废弃 id 不留残骸，代价是 `list` 看不到"已创建未落盘"的会话。
- **无删除、无导入、无跨进程并发仲裁**：本次未找到对应能力，均以"append-only + revision 检测 + 目录/登记删除分离"的形态存在。

## 13. 未验证事项

- 未运行任何会话或持久化后端；崩溃恢复路径（torn tail 截断、interrupted closers 合成）与 resume 往返来自静态阅读。
- 多进程并发写同一 JSONL 文件或 SQLite 库的实际行为未验证（代码只有 revision 检测与物化期的 EEXIST 防线）。
- JSONL 顺序媒体下 `readFrom` 的全量解析代价、packed chunk 行的实际压缩率未实测。
- FTS5 搜索的召回质量与 `DatabaseSync` 同步阻塞影响未运行验证。
- `/export` ZIP 端到端、工作区启动分组、telemetry/标题的 LLM 生成链路未覆盖。

## 14. 关键源码索引

- `packages/core/session/src/types.ts`：`56`（SESSION_FORMAT_VERSION）、`236-333`（SessionEventMap）、`404-436`（SessionEvent 信封）
- `packages/core/session/src/index.ts`：`425-758`（Session 类）、`604-655`（append）、`726-747`（deriveMessages）、`830-841`（create）、`866`（id 铸造）、`1081-1095`（fork）
- `packages/core/session/src/surface.ts`：`83-114`（deriveEventMessage）、`210-318`（替换校验）、`398-460`（SurfaceManager）
- `packages/core/session/src/repair.ts:27`（interruptedTurnClosers）
- `packages/core/agent-loop/src/agent.ts`：`246-330`（turn）、`332-401`（step）、`407-495`（buildRequest）
- `packages/core/agent-loop/src/tool-calls.ts:263`、`281`（tool/call、tool/result）
- `packages/session/session-persistence/src/index.ts:84-241`（抽象 seam）
- `packages/session/session-persistence/src/coordinator.ts`：`588`（协调器）、`645-658`（惰性创建）、`1010-1033`（串行链）、`1061-1066`（未知类型拒绝）、`1086-1137`（写路径）
- `packages/session/session-persistence/src/write-behind.ts:45`、`63-72`（写合并与 flush 屏障）
- `packages/session/session-checkpoint-policy/src/index.ts:63-83`（检查点语义）
- `packages/session/session-persistence-jsonl/src/index.ts`：`121`（后端）、`292-304`（revision 稳定读）、`422-444`（appendBatch/commitRepair）、`514-626`（物化）
- `packages/session/session-persistence-sqlite/src/index.ts`：`99`（后端）、`225-238`（seek 后缀读）、`284-338`（事务写入与修复）
- `packages/session/session-projection/src/index.ts:171-426`（投影注册表）
- `packages/session/session-projection-cache/src/index.ts:71-300`（持久化投影缓存）、`spec.ts`（存储域声明）
- `packages/core/agent/src/index.ts:424-430`（resume 入口）、`packages/core/agent-loop/src/index.ts:653-702`（resumeWith）
- `docs/persistence-catalog.md`（生成的事件目录）、`docs/subsystems/session.md`、`docs/subsystems/persistence.md`
