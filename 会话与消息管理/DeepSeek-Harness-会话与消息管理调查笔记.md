# DeepSeek-Harness 会话与消息管理调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/core/session`、`packages/session/session-persistence`、`session-persistence-jsonl`、`session-format`、`session-projection`、`session-projection-cache`、`session-checkpoint-policy`、`packages/core/agent-loop`、`packages/session-query/session-query`、`session-query-sqlite`、`packages/workspace/workspace`、`packages/core/scope`）
>
> 调查更新日期：2026-09-16
>
> 代码快照：`0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`（分支：`master`）
>
> 调查方式：静态源码阅读（核心 session 与 surface、handle 持久化契约、JSONL provider、格式迁移链、checkpoint policy、投影与投影缓存、agent-loop 事件发射、session-query 及 workspace/scope/匿名身份包，配合 `docs/subsystems/session.md`、`persistence.md` 与生成目录 `docs/persistence-catalog.md` 交叉核对）；未运行测试或交互会话
>
> 调查范围：会话/消息数据模型、事件类型系统与格式版本、持久化后端与崩溃恢复、消息历史派生、投影、fork/resume/transcript 的日志派生、生命周期、列表与检索、外部对象绑定；排除：模型请求的上下文拼装与适配器细节（对话请求与上下文类目）、压缩策略与标题/遥测的 LLM 生成、Chat UI 与 Web 客户端渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的会话仍是 append-only SessionEvent 日志，内存 Session 是交互历史的单一事实源，LLM 消息历史从日志派生，不存在独立消息表。当前实现的持久化与格式治理已经重构：

- 事件类型通过 `SessionEventMap` 声明合并扩展，核心加插件共 24 个事件族（`docs/persistence-catalog.md` 逐条枚举）；只有 `user/message`、`assistant/message`、`tool/result` 三类消息事件（合称 `SurfaceEventType`）产生 LLM 消息并携带 `surfaceOp` 表面标记。
- 当前逻辑格式为 v3。格式目录把 v0、v1、v2 到 v3 的相邻迁移作为独立包注册；读取旧代时只在内存迁移，写打开才在同目录发布不可变的当前代后继文件，旧文件保持字节不变。当前版本内的未知必需事件仍 fail-closed，`ignorable` 只处理同版本词汇扩展（`packages/core/session/src/types.ts:88`；`packages/session/session-format/src/{catalog,chain}.ts`）。
- 第一方持久化只保留 JSONL 后端，SQLite 会话后端已经移除。公共 seam 改成 handle 契约：创建或打开返回读/写句柄，追加、读取、flush 与关闭都由句柄完成；JSONL provider 自己拥有写批、单写者与 live-event 路由。跨进程写排斥由 POSIX flock 或 Windows 命名信号量提供（`packages/session/session-persistence/src/{handle,storage-contract}.ts`；`session-persistence-jsonl/src/{storage,lease}.ts`）。
- 投影有两层：`session-projection` 对已提交事件驱动纯函数单元，`session-projection-cache` 把结果存进独立 storage domain；查询侧可用共享 observation 做冷读，缓存仍只是 fold 捷径而非权威。
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
   -> 持久化：会话绑定 JSONL write handle；append 进入 provider 的串行写批
      flush 在检查点形成耐久屏障，close 排空并释放进程内 claim 与 kernel lease
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
- **版本机制**：`SESSION_FORMAT_VERSION = 3`（`packages/core/session/src/types.ts:88`）。结构性变化通过 `session-format` 的相邻迁移边处理，当前目录注册 v0→v1、v1→v2、v2→v3；新增可忽略词汇仍可在同一格式版本内用 `ignorable` 扩展。读打开迁移逻辑视图，写打开才发布 v3 后继代，更新版本、目录外版本与未知必需事件均 fail-closed。

## 4. 事实源、持久化与派生历史不变量

- **三层数据**：内存事件日志是运行时权威；JSONL 持久化是磁盘投影；投影缓存是折叠捷径（可能过期，绝不会错误，`session-projection-cache/src/index.ts:9-13` 注释）。文档用“内存 log / durable log / cached projection”三个词分别称呼。
- **model-visible ⟺ logged**：仓库约定"任何到达模型请求的内容必须能从会话日志重建；新的 model-visible 输入必须落成 session event"。支撑机制有三：`request/header` 事件把每次请求的完整信封（config、system、tools）以全量快照记入日志，`foldRequestHeader` 选最新快照重建请求（`packages/core/session/src/request-header.ts`），使请求成为日志的纯函数；seed/load 边界校验消息身份、`source.kind`、provider/model 存在，缺失即拒绝而非猜测（`packages/core/session/src/index.ts:253-352`）；派生历史与外部重建器共用同一 `deriveEventMessage`，不会与缓存分歧。
- **header 与日志分离**：`SessionHeader`（version/id/createdAt/cwd/parentSession/seedLength/origin/delegationDepth/agentPreset）是存储元数据，不进事件日志、不进派生历史；`session.header` 总是存在（无 store 头时合成最小头）。
- **持久化契约**：抽象 `SessionPersistence` 负责 `create`、`open`、`stat`、`list` 与全服务 flush；会话级读、append、flush 和 close 由 `SessionHandle` 承担。写句柄校验连续 seq，读句柄只暴露逻辑事件，不暴露物理文件工件（`packages/session/session-persistence/src/{index,handle}.ts`）。

## 5. 持久化后端与格式代际

第一方只提供 JSONL。每个会话目录可同时保留多个不可变格式代：v0 使用 `session.jsonl(.zstd)`，后续代使用 `session.vN.jsonl(.zstd)`；运行时选择数字最大的规范代。当前 v3 每个事件一个物理行，连续 source seq 只在存储表示中压为区间；packed assistant delta 仅由冻结的 v0/v1 codec 为历史读取保留（`packages/session/session-persistence-jsonl/README.md:53-69,100`）。

迁移由 `session-format` 规划相邻链，格式目录组装当前 codec 与 v0→v1、v1→v2、v2→v3 三条边。读句柄可返回迁移后的逻辑事件而不写文件；写句柄把迁移结果编码到临时文件，经 Worker 验证和源 revision 复查后无覆盖发布当前代。源代不被改写，也没有自动降级（`packages/session/session-format/src/{catalog,chain}.ts`；`session-persistence-jsonl/src/{generation,migration-verifier}.ts`）。

持久化 seam 不再拥有共享 coordinator。provider 返回 `SessionHandle`，写句柄内部串行追加并承接 live event；`flush()` 是耐久屏障，`close()` 排空后释放所有权。JSONL 在进程内做单 writer claim，并用 kernel lease 排斥其它进程；网络文件系统上的 advisory flock 可靠性仍是已声明边界（`packages/session/session-persistence/src/handle.ts`；`session-persistence-jsonl/src/{storage,lease}.ts`）。

惰性物化：`create` 返回写句柄，首个 append 或 flush 才要求会话成为可列出的持久对象；未物化的空白会话可随句柄关闭而消失（`packages/session/session-persistence/src/index.ts:122-175`）。

## 6. 生命周期：创建、resume、fork、销毁与恢复

- **创建**：`SessionStore.create` = `prepare` + `enter` + `announce` 三步（`index.ts:830-841`），agent 工厂则把这三步折叠进自己唯一的 effect，保证循环关闭事件在 store 摘除前落定。
- **resume**：`AgentRegistry.resume` → 工厂 `persistence.prepare(id)`（`agent-loop/src/index.ts:653-702`）。协调器的 prepare 做 revision 稳定性往返（日志在"读/查"一圈内不变才算收敛），返回独占的未发布 `SessionPreparation`；`Session.fromRestore` 以所有权转移方式校验并冻结存储对象，发布后 dispose 释放预约。有 5 项 LRU 的已备会话缓存供重复读取复用。
- **fork**：`SessionStore.fork(source, boundary?, childId)`（`index.ts:1081-1095`）把源会话 0..boundary 前缀深拷贝为种子，子会话 header 记 `parentSession`、`seedLength` 与继承的 cwd。boundary 默认当前末事件，显式边界可以落在独立日志事件上，但落在开着的 turn 内会被拒绝（`OPEN_TURN`）而不是静默裁剪。fork 种子经 `session/created` 持久化一次。
- **销毁**：会话释放时，JSONL write handle 先排空 live buffer、flush，再释放 writer ownership。**本次未找到会话删除 API**：持久化 seam 与 JSONL provider 均无 delete 入口。Workspace 现已提供可逆归档集合与 Web 端 Archived sessions 恢复页，但归档只隐藏导航项，不删除会话日志（`packages/client/ui-settings-unarchive-sessions/README.md`）。
- **崩溃恢复**：`load` 对冷会话做修复——完整中断回合不截断，而是补合成 closers（缺失工具结果错误 `TOOL_NOT_STARTED`/`TOOL_OUTCOME_UNKNOWN` 加 step/end 与 turn/end 的 interrupted 结束，`repair.ts:27`、`index.ts:302-319`），torn 尾部丢弃；interrupted 是唯一循环本身不会发出的结束原因。live 会话不做修复：open turn 的 load 直接拒绝。

## 7. 消息操作与分支语义

- 日志是追加型且不可变：**本次未找到已落盘消息的就地编辑或删除 API**。历史修正以表面替换表达：`surfaceOp: { op: 'replace' }` 把旧表面范围影子化并插入新节点（替换事件必须引用被遮蔽的全部节点 seq，`surface.ts:210-243` 校验）。
- 替换的现有消费者是压缩：`compaction/*` 三事件为日志锁围栏，成功的压缩在 `compaction/end` 前追加一个带 replace 标记的 `user/message` 检查点节点；被影子化的旧事件仍留在原始日志，回放确定性保留（`packages/compaction/compaction/README.md` 的 Surface contract 一节）。表面替换还允许"工具结果仅改 content"的单节点重写（`surface.ts:287-318`）。
- 分支即 fork（§6）；没有"移动 leaf 指针"式的活动路径切换——会话身份与日志绑定，分支是独立子会话。

## 8. 列表、索引与检索

- 会话列表：live `SessionStore.list()` 是内存创建序快照；持久化侧列表只读 JSONL 规范代的 header 与 revision，不扫描完整事件体。Session Controller 再将 header 与投影缓存合成浏览器列表；列表无分页游标。
- **查询服务**：`session-query` 是 live-preferred 的逻辑语料层（`packages/session-query/session-query/README.md`），提供精确读取（会话、表面、事件、标题）、关系追踪与两类全文方法；事件读取方法复用核心表面折叠，把每个事件标记为 `current`/`shadowed`/`log-only` 三类。
- 全文检索：唯一具体实现是 `session-query-sqlite`，FTS5 + `unicode61` 分词，查询按字面短语转义（MATCH 语法当数据）；跨会话结果按最强命中事件分组，返回带 snippet 的分页（不透明 branded cursor，generation 变化即失效）；索引是派生的独立数据库，TEMP 表放 live 行、持久表放已落库行，revision 对比后只增量检查新变更日志。`openAt: never` 可整体关闭搜索。
- 标题与统计以投影单元提供：`session-stats` 折叠出 turn/step 计数与 LLM/工具耗时（`packages/session/session-stats/src/projection.ts`），标题单元折叠最新 `session/title` 事件；两者向 `SessionProjectionMap` 声明合并 key。

## 9. 缓存、一致性与并发写入

- 单进程单写者：`Session.append` 同步进内存日志、同步通知监听者（失败按监听器隔离，不改变提交结果），热路径不做 I/O（`index.ts:604-655`）。持久化在后台异步追。
- 串行化与写批：每个 JSONL write handle 串行化 append，provider 管理 live-event 路由和写批；`flush()` 等待该句柄此前接受的事件耐久落盘，service-wide flush 汇总所有活动写句柄。跨进程的同会话写打开由 kernel lease 拒绝（`packages/session/session-persistence/src/handle.ts`；`session-persistence-jsonl/src/{storage,lease}.ts`）。
- 检查点语义（`session-checkpoint-policy`）：模型请求流开始前、顶层工具体执行前、每个 pre-step 边界各做一次 flush 屏障（pre-step 屏障把上一步已提交的内容先落盘再进入本步请求），请求前缀先于 adapter dispatch 落盘，失败即 fail-closed（`session-checkpoint-policy/src/index.ts:63-83`）。
- 崩溃一致性：JSONL 规范代以校验帧检测 torn tail；格式迁移在临时文件完成，经 Worker 验证和源 revision 复查后以 no-clobber 方式发布。repair 通过普通写句柄追加合成 closers，不覆盖旧格式代。
- 多进程：公共 seam 只保证同一 backend instance 的单写者；第一方 JSONL 另用内核 lease 做跨进程排斥。POSIX 依赖非阻塞 flock，Windows 使用按路径派生的命名信号量；NFSv3 等网络文件系统仍可能削弱 advisory flock 语义。

## 10. 迁移与导入导出

- 受支持的 v0→v3 历史格式经相邻迁移链恢复；更新版本、目录外版本或无法无损解释的记录仍拒绝。投影缓存使用独立 storage domain 与版本，失配时重放权威日志而不是迁移缓存。
- 读句柄迁移旧代只返回当前逻辑视图；写打开才发布新的当前代文件。崩溃 repair 仍通过普通 append 把合成 closers 写入当前代。
- 导出：`/export` 与会话头菜单由 session-log-export 包直接注册认证 Fetch 路由，先 flush live 会话，再从 persistence read handle 序列化当前逻辑日志。它不再依赖 raw artifact，任何满足 handle 契约的后端都可导出；ZIP 同时收集图片和通用文件（`packages/session-query/session-log-export/src/{index,archive}.ts`）。
- 导入/备份恢复：**本次未找到**会话级导入 API 或备份机制（检查范围：持久化抽象、JSONL provider、store 与 agent resume 入口）。

## 11. 外部对象绑定

- **会话级（header）**：cwd、父会话、种子长度、subagent 标记与深度、agent preset 都随 header 持久化；preset 可恢复会话的工具与提示构成（`types.ts:61-99`）。
- **请求级（日志事件）**：每次请求的 config/system/tools 以全量快照进 `request/header`（reason 区分 initial/resume/change）；路由容量进 `request/context`（仅变化时记录），两者都是 log-only，不产生消息。
- **消息级**：`user/message.source` 区分人、注入与目标续写来源；`assistant/message.source` 携带 provider/model；`tool/result.message.source` 携带 callId 并与 `tool/call` 配对。附件（图片等）在消息 content 块内随消息持久化。
- 身份与作用域：匿名身份 `getOrCreateAnonymousUserId()` 是进程共享库（`$DSH_HOME/.anonymous-user-id`），只进遥测资源属性与 DeepSeek 请求头，不进会话数据（`packages/identity/anonymous-user-id/README.md`）；`dsh-scope` 提供 per-agent 作用域，session 事件经 `scopeTarget` 按作用域过滤派发，注册与生命周期绑定同一 fiber（`packages/core/scope/README.md`）。

## 12. 设计取舍与已确认边界

- **事件日志而非消息表**：全部对话状态可重放，投影按需派生；代价是日志只增不减。当前 JSONL 用 checksummed zstd frame、source seq 区间编码和不可变格式代际控制体积与迁移风险。
- **模型历史与 transcript 双投影**：surface 遮蔽替换范围、append-origin 事件保留人可见历史，两者同源于日志但语义刻意不同。
- **格式迁移显式化**：当前为 v3，支持的历史变化由相邻边逐代迁移；`ignorable` 只把同版本词汇增长与结构性迁移解耦。
- **持久化与执行解耦**：`session/event` 同步通知、持久化异步追、checkpoint policy 只卡语义边界（模型请求、顶层工具、pre-step），不在 turn 边界强刷。
- **惰性物化**：无消息的会话不产生文件；废弃 id 不留残骸，代价是 `list` 看不到"已创建未落盘"的会话。
- **无删除、无导入；跨进程只仲裁写所有权**：本次未找到会话日志删除或导入 API。JSONL 用 kernel lease 阻止同一会话并发写，但没有多写者合并协议。

## 13. 未验证事项

- 未运行任何会话或持久化后端；崩溃恢复路径（torn tail 截断、interrupted closers 合成）与 resume 往返来自静态阅读。
- POSIX flock、Windows 命名信号量与网络文件系统上的跨进程写排斥未运行验证。
- JSONL 顺序媒体下 `readFrom` 的全量解析代价、packed chunk 行的实际压缩率未实测。
- FTS5 搜索的召回质量与 `DatabaseSync` 同步阻塞影响未运行验证。
- `/export` ZIP 端到端、工作区启动分组、telemetry/标题的 LLM 生成链路未覆盖。

## 14. 关键源码索引

- `packages/core/session/src/types.ts`：`88`（SESSION_FORMAT_VERSION）、SessionEventMap 与 SessionEvent 信封
- `packages/core/session/src/index.ts`：`425-758`（Session 类）、`604-655`（append）、`726-747`（deriveMessages）、`830-841`（create）、`866`（id 铸造）、`1081-1095`（fork）
- `packages/core/session/src/surface.ts`：`83-114`（deriveEventMessage）、`210-318`（替换校验）、`398-460`（SurfaceManager）
- `packages/core/session/src/repair.ts:27`（interruptedTurnClosers）
- `packages/core/agent-loop/src/agent.ts`：`246-330`（turn）、`332-401`（step）、`407-495`（buildRequest）
- `packages/core/agent-loop/src/tool-calls.ts:263`、`281`（tool/call、tool/result）
- `packages/session/session-persistence/src/index.ts`、`handle.ts`、`storage-contract.ts`（持久化服务与 handle 契约）
- `packages/session/session-checkpoint-policy/src/index.ts:63-83`（检查点语义）
- `packages/session/session-persistence-jsonl/src/{storage,handle,generation,lease}.ts`（JSONL 读写、格式代际与写租约）
- `packages/session/session-format/src/{catalog,chain}.ts`（v0→v3 相邻迁移目录）
- `packages/session/session-projection/src/index.ts:171-426`（投影注册表）
- `packages/session/session-projection-cache/src/index.ts:71-300`（持久化投影缓存）、`spec.ts`（存储域声明）
- `packages/core/agent/src/index.ts:424-430`（resume 入口）、`packages/core/agent-loop/src/index.ts:653-702`（resumeWith）
- `docs/persistence-catalog.md`（生成的事件目录）、`docs/subsystems/session.md`、`docs/subsystems/persistence.md`
