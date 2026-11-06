# DeepSeek-Harness 会话与消息管理调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/core/session`、`packages/session/*`、`packages/core/agent-loop`、`packages/session-query/*`、`packages/workspace/*`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：静态源码阅读，以 `docs/subsystems/session.md`、`docs/subsystems/persistence.md`、`docs/session-format-status.md` 与生成目录 `docs/persistence-catalog.md` 为主轴，逐项核对 `packages/core/session` 类型与实现、`packages/session/*` 的格式、持久化、投影包，以及 agent-loop 的 resume 与 session-query 的检索接口；未运行测试或交互会话
>
> 调查范围：会话/消息数据模型、事件类型系统与格式版本、持久化后端与崩溃恢复、消息历史派生、投影、fork/resume/transcript 的日志派生、生命周期、列表与检索、外部对象绑定、会话日志上传；排除：模型请求的上下文拼装与适配器细节（对话请求与上下文类目）、压缩策略与标题/遥测的 LLM 生成、Chat UI 与 Web 客户端渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的会话仍是 append-only 事件日志，内存 Session 是交互历史的单一事实源，LLM 消息历史从日志派生，不存在独立消息表。当前实现的边界与以前不同：

- 逻辑格式为 v4。格式迁移按“相邻边”拆成独立包（`session-format-v0-to-v1` 至 `session-format-v3-to-v4`），由 `session-format-catalog` 在构建期静态组装成唯一读取器；读取旧代只在内存迁移，写打开才在同目录发布不可变的当前代后继文件，源文件字节不变。v4 的实质变化是把工具结果提升为 tool 角色消息、改写消息来源形状、收口证据化的中断回合并补齐父会话目录事实（`packages/session/session-format-v3-to-v4/README.md`）。
- 产生消息的表面事件从三类扩到五类：`system/message`、`developer/message`、`user/message`、`assistant/message`、`tool/result`（`packages/core/session/src/types.ts:447`）。system prompt 现在是表面节点 0，不再写进 `request/header`。
- 流式 chunk 不再是独立事件：`assistant/message` 内嵌紧凑的原始流（`stream`），未产生表面消息的失败、重试或取消尝试记为 `assistant/attempt`，因此每次模型尝试恰好有一个耐久收口。
- 持久化仍是 handle 契约加第一方 JSONL。`create`/`open` 返回读/写句柄，追加批次与 flush 屏障由句柄承担；跨进程写排斥由 POSIX flock 或 Windows 命名信号量提供，进程内单写者由后端保证。
- 投影仍分两层：`session-projection` 对已提交事件驱动纯函数单元，`session-projection-cache` 把结果存进独立 storage domain 供列表与统计冷读。新增的插件消息投影可在不改变表面节点成员的前提下改写既有消息内容。
- fork、resume、transcript 都从日志流派生：fork 用 `isSeeded` 与精确的 `inheritedEventCount` 表达血缘并追加带标记的 `session/end-seed` 边界；resume 走 prepare→修复未闭合回合→发布；人类可读 transcript 读 append-origin 事件，模型历史读表面（表面会遮蔽被压缩替换的范围）。

## 系统边界与数据主链

```text
用户/注入消息进入 inbox（queued input）
  -> AgentLoop.turn() append 'turn/start'
  -> preStep 认领 inbox；systemPrompt.assemble 后 append 'system/message'（表面节点 0）
  -> 进入 step 的每条消息 append 'user/message'（surfaceOp: append）
  -> buildRequest：session.deriveMessages() 取当前表面消息
     并 append 'request/header'（config + tools，无 system）与 'request/context'（容量 + 更新模式）
  -> checkpoint policy 在 llm/stream 前 await flush 屏障（session-checkpoint-policy/src/index.ts:72）
  -> 适配器流式输出 -> append 'assistant/message'（内嵌 stream、usage、provider/model）
      失败/取消的尝试 -> append 'assistant/attempt'（同样内嵌 stream，无表面消息）
  -> 工具：append 'tool/call'；执行前再 flush；完成 append 'tool/result'（v4 为 tool 角色消息）
  -> step/end、turn/end（原因枚举含 completed/aborted/blocked/error/max-tokens/interrupted/forked）
   -> 持久化：session/event 同步通知 -> 写句柄批量 append -> flush 形成耐久屏障
      close 排空并释放进程内 claim 与 kernel lease
  -> 投影：投影注册表同步驱动各单元；投影缓存周期性 checkpoint
  -> 下次请求 deriveMessages 复用缓存；崩溃后 resume 通过写句柄追加 interrupted closers 再发布
```

边界：模型请求如何拼装（系统提示、工具 schema 组装、retry）属于对话请求与上下文类目；会话侧栏、界面动作属于 Chat UI 类目；本笔记只覆盖“保存了什么、如何恢复、如何查询、如何导出”。

## 1. 会话单位与标识

- 会话 id 是 `Branded<'SessionId'>` 字符串。`SessionStore.create` 省略 id 时铸造计数器 id，显式 id 用于 resume/fork 的既有身份（`packages/core/session/src/index.ts:1127`）。
- 会话头现用 `isSeeded` 表达血缘，不再有 `seedLength`；精确的 fork 前缀长度作为存储值 `inheritedEventCount` 随日志单独保存（`types.ts:95-150`；`packages/core/session/src/index.ts:1403`）。
- 子 agent 会话在 header 上标记 `origin: 'subagent'` 与 `delegationDepth`（父深度 +1），供递归预算跨重启存活；两者都是展示/治理元数据，不证明子会话可继续。
- 工作区归属仍用 header 的绝对 `cwd` 判定；会话本体现在另有可变的会话工作目录（`packages/session/working-directory`），变更后旧进程保留自己的 cwd，新选择可重放并进入用户上下文。

## 2. 消息模型：事件日志与派生历史

- **日志结构**：`Session` 是 `SessionEvent[]` 数组，`seq` 恒等于 `log.length`（连续契约），事件深度冻结、不可修改。`turn/*` 与 `step/*` 是执行围栏：一个 turn 包住一次模型循环，step 是一次模型调用加其工具执行。
- **表面事件**：五类事件携带完整消息。`system/message` 承载渲染后的系统提示（表面节点 0；变更时替换 node 0 或在 in-history 路由上追加新节点）；`user/message` 承载人提示、`agent.inject()` 合成上下文与目标续写回合；`developer/message` 承载按 turn/step 记账的增量会话变更，工具新增时用 `headerSeq` 指向定义它的请求头；`assistant/message` 承载组装后的助手消息、usage 与内嵌流；`tool/result` 承载工具结果（v4 起为 tool 角色消息）。
- **表面与来源**：每条表面事件必须带 `surfaceOp`（`'append'` 或 `{ op: 'replace', startSeq, endSeq }`），可选 `sourceEventSeqs` 只能引用更早的事件且必须覆盖被遮蔽节点。`assistant/message` 不允许 `sourceEventSeqs`，其内嵌流就是流式证据。
- **派生规则**：`deriveEventMessage`（`packages/core/session/src/surface.ts:120`）把表面节点投影为消息；空 content 的 `assistant/message` 仍记账但不进模型历史；`assistant/attempt`、turn/step 边界与插件只记日志的事件都不产生消息。
- **插件消息投影**：声明 `@messageProjection` 的事件可注册纯函数定义（`ctx.sessions.registerMessageProjection()`），在提交前校验并改写既有消息内容，推进 `contentGeneration`；图像替换（`image/offload`）走这条路，且不会改变表面节点成员或消息身份。
- **缓存**：`Session.deriveMessages()` 沿表面节点折叠，每个节点只投影一次；表面替换或消息投影（`contentGeneration` 变化）才重建（`packages/core/session/src/index.ts:999`）。

## 3. 事件类型系统与格式版本

- **词汇表**：`SessionEventMap`（`types.ts:287`）声明核心事件，插件通过 declaration merging 追加（compaction、hook 桥、标题、计划模式、命令生命周期、job、schedule、goal 等）。生成目录 `docs/persistence-catalog.md` 逐条枚举仓库内全部 durable 事件，并为每个根类型给出规范化结构与 SHA-256 指纹，机读清单在 `docs/persistence-schema.json`；实验包的插件记录另见 `docs/experimental-persistence-catalog.md`。
- **信封**：每条事件为 `type/seq/time/data` 加可选 `ignorable: true`；表面事件额外带 `surfaceOp`/`sourceEventSeqs`，非表面事件禁止携带两者。`ignorable` 缺失意味着“必须理解”，读者遇到不认识的类型时必须拒绝重建而不是静默跳过。
- **版本机制**：`SESSION_FORMAT_VERSION = 4`（`types.ts:90`）。`docs/session-format-status.md` 记录 writer 常量、已接受的兼容基线与已发布格式：当前 finalization 与 release 记录均为 v4，发布证据是 tag `dsh-v0.2.0-rc.2`。同版本内的结构兼容变更需按 reader-compatibility 规则评审，不能复用 3→4 这条过渡。
- **迁移边**：`session-format-catalog` 在模块初始化时检查从最早支持版本到当前 writer 的完整无缺口链，并暴露物理分发、仅头部分类、单遍行恢复与当前记录编码（`packages/session/session-format-catalog/src/index.ts:3`）。读打开迁移到内存逻辑视图；写打开才在独占 claim 下发布当前代。

## 4. 事实源、持久化与派生历史不变量

- **三层数据**：内存事件日志是运行时权威；JSONL 持久化是磁盘投影；投影缓存是折叠捷径（可能过期，绝不会错误）。文档用“内存 log / durable log / cached projection”三个词分别称呼。
- **model-visible ⟺ logged**：任何到达模型请求的内容必须能从会话日志重建。支撑机制有三：每次请求的配置与工具 schema 以全量快照进 `request/header`，`foldRequestHeader` 选最新快照重建（`packages/core/session/src/request-header.ts:63`），而 system prompt 作为表面节点同样在日志里；seed/load 边界校验消息身份、来源与 provider/model，缺失即拒绝而非猜测；派生历史与外部重建器共用同一个 `deriveEventMessage`，不会与缓存分歧。
- **header 与日志分离**：`SessionHeader`（version/id/createdAt/cwd/parentSession/isSeeded/origin/delegationDepth/agentPreset）是存储元数据，不进事件日志、不进派生历史；`session.header` 总是存在（无 store 头时合成最小头）。
- **持久化契约**：抽象 `SessionPersistence` 负责 `create`、`open`、`stat`、`list`；会话级 read/append/flush/close 由 `SessionHandle` 承担。写句柄校验连续 seq，读句柄只暴露逻辑事件；句柄还携带 `inheritedEventCount` 与被撤销的策略化访问边界（`packages/session/session-persistence/src/handle.ts`）。

## 5. 持久化后端与格式代际

第一方只提供 JSONL。每个会话目录可同时保留多个不可变格式代：v0 使用 `session.jsonl(.zstd)`，后续代使用 `session.vN.jsonl(.zstd)`，运行时选择数字最大的规范代（`packages/session/session-format/src/filename.ts`）。当前 v4 每个事件一个物理行；默认用带校验的 Zstandard 帧，`compression: 'none'` 时退化为明文行。只有冻结的旧 codec 为历史读取保留 packed assistant delta 等旧表示。

迁移由 `session-format-catalog` 规划相邻链，历史头可只做头部迁移不读正文；需要正文恢复时先收集完整直接子会话事实，再单遍解码。读句柄返回迁移后的逻辑事件而不写文件；写句柄把结果编码到临时文件，经 Worker 验证和源 revision 复查后无覆盖发布当前代。源代不被改写，也没有自动降级。

持久化 seam 不再拥有共享 coordinator。provider 返回 `SessionHandle`，写句柄内部串行追加并承接 live event；`flush()` 是耐久屏障，`close()` 排空后释放所有权。JSONL 在进程内做单 writer claim，并用 kernel lease 排斥其它进程；网络文件系统上的 advisory flock 可靠性仍是已声明边界（`packages/session/session-persistence-jsonl/src/{storage,lease}.ts`）。

惰性物化：`create` 返回写句柄，首个 append 或 flush 才要求会话成为可列出的持久对象；未物化的空白会话可随句柄关闭而消失，崩溃前从未物化过的会话在其他进程看来从未存在。

## 6. 生命周期：创建、resume、fork、销毁与恢复

- **创建**：`SessionStore.create` = `prepare` + `enter` + `announce` 三步，append 在 `session/created` 完成前被拒绝（`index.ts:1127` 起）。agent 工厂把三步折叠进自己的唯一 effect，保证循环关闭事件在 store 摘除前落定。
- **resume**：`AgentLoop.resume`（`packages/core/agent-loop/src/index.ts:752`）经 `resumeWith` 用会话写句柄读取存储日志，先算出并追加 `interruptedTurnClosers`（缺失工具错误、未闭合 step 结束、合成 `turn/end { kind: 'interrupted' }`），再交给 store prepare 发布。持久化侧没有 prepared-session 缓存，冷读缓存归 session-query。
- **fork**：`SessionStore.fork(source, boundary?, childSessionId?)`（`index.ts:1403`）把源会话到 inclusive 边界的前缀深拷贝为种子，子会话 header 记 `isSeeded: true`、精确 `inheritedEventCount` 与继承的 cwd，但不写 `parentSession`（普通 fork 已不再以此表达血缘）。种子在 cut 处带 `session/end-seed { inherited: true }` 标记，仍开放的源回合以 `forked` 原因收口；有效事件边界可位于开放回合内，种子构造负责补齐 fork 收口事件（`index.ts:1403-1454`）。
- **销毁**：会话释放时，JSONL write handle 先排空 live buffer、flush，再释放 writer ownership。**本次未找到会话删除 API**：持久化 seam 与 JSONL provider 均无 delete 入口。归档由 workspace registry 持有（`archivedSessionIds`），Session Controller 用 `archived-session-gate` 阻止归档会话继续执行步骤，Web 设置页的 Archived sessions 负责恢复；归档只隐藏导航项，不删除会话日志。
- **崩溃恢复**：持久化不截断、不修复完整中断回合，只丢弃 torn 物理尾部（JSONL 会部分解码被截断帧并重写完整记录）；修复是读者的职责，由 resume 通过写句柄追加合成 closers。`interrupted` 是唯一循环本身不会发出的结束原因，`forked` 只由 fork 种子构造发出。

## 7. 消息操作与分支语义

- 日志是追加型且不可变：**本次未找到已落盘消息的就地编辑或删除 API**。历史修正以表面替换表达：`replace` 把旧表面范围影子化并插入新节点；替换事件必须引用被遮蔽的全部节点 seq。
- 替换的现有消费者是压缩：`compaction/*` 三事件为日志锁围栏，成功的压缩在 `compaction/end` 前追加一个带 replace 标记的 `user/message` 检查点节点；被影子化的旧事件仍留在原始日志，回放确定性保留。表面替换还允许“工具结果仅改 content”的单节点重写。
- 新的内容改写通道是插件消息投影：既不改变表面节点成员，也不改变消息身份，适合“把某条消息中的图像替换为占位符”这类只改内容的策略；第一方消费者是图像卸载。
- 分支即 fork（§6）；没有“移动 leaf 指针”式的活动路径切换——会话身份与日志绑定，分支是独立子会话。

## 8. 列表、索引与检索

- 会话列表：live `SessionStore.list()` 是内存创建序快照；持久化侧列表只读 JSONL 规范代的 header 与 revision，不扫描完整事件体；投影缓存让列表可零 I/O 读取缓存值。Session Controller 再把 header 与投影缓存合成浏览器列表，并提供服务端 `list` 与 `search` Remote（`packages/api/session-controller/src/index.ts:278,292`）。
- **查询服务**：`session-query` 仍是 live-preferred 的逻辑语料层，提供精确读取（会话、表面、事件、标题）、关系追踪、有界事件上下文与 provider 无关的过滤；事件读取方法复用核心表面折叠，把每个事件标记为 `current`/`shadowed`/`log-only` 三类。面向模型的 `tool-session-query` 已移入实验组。
- 全文检索：唯一具体实现仍是 `session-query-sqlite`，FTS5 分词、查询按字面短语转义、跨会话结果按最强命中事件分组并返回带 snippet 的分页（branded cursor，generation 变化即失效）；索引是派生的独立数据库，TEMP 表放 live 行、持久表放已落库行。检索按 `openAt` 配置为 opt-in，可设为启动打开、首次搜索打开或整体关闭。
- 标题与统计由投影单元提供：`session-title` 从首条合格人类消息、异步生成器或显式重命名给出可持久标题（标题永不进入模型输入，自动生成不阻塞主回复）；`session-stats` 折叠出整条日志的 turn/step 计数与 LLM、工具、首 token、解码耗时；`session-turn-outline` 新增整会话 turn 大纲，让历史客户端能导航尚未加载的回合并按精确事件 seq 向前翻页。三者都向 `SessionProjectionMap` 声明合并 key。

## 9. 缓存、一致性与并发写入

- 单进程单写者：`Session.append` 同步进内存日志、同步通知监听者（失败按监听器隔离，不改变提交结果），热路径不做 I/O。持久化在后台异步追：`session/event` 通知被路由进活动写句柄的 write-behind 窗口，首个待写事件开启固定批处理窗口，后续事件加入但不重置截止时间。
- 串行化与写批：每个 JSONL write handle 串行化 append；`flush()` 取消等待并排空到静止，是唯一的耐久与错误观察点；失败的后台写保留事件顺序并暂停自动路径，下一次显式 flush 重试并大声报错。`session/disposed` 与 `close()` 完成同样的最终排空。
- 跨进程：公共 seam 只保证同一 backend instance 的单写者；第一方 JSONL 另用内核 lease 做跨进程排斥。POSIX 依赖非阻塞 flock，Windows 使用按路径派生的命名信号量；NFSv3 等网络文件系统仍可能削弱 advisory flock 语义。
- 检查点语义（`session-checkpoint-policy`）：模型请求流开始前、顶层工具体执行前、每个 pre-step 边界各做一次 flush 屏障（`session-checkpoint-policy/src/index.ts:35,72,80`），请求前缀先于 adapter dispatch 落盘，失败即 fail-closed。
- 崩溃一致性：JSONL 规范代以校验帧检测 torn tail；格式迁移在临时文件完成，经 Worker 验证和源 revision 复查后以 no-clobber 方式发布。投影缓存遇到失配记录时忽略或备份，重放权威日志而不是迁移缓存。

## 10. 迁移与导入导出

- 受支持的 v0→v4 历史格式经相邻迁移链恢复；更新版本、目录外版本或无法无损解释的记录仍拒绝。当前格式恢复会保留已安装扩展与带 `ignorable` 的未知事件；v0/v1/v2 历史迁移拒绝未知类型，即使标了 `ignorable`。
- 读句柄迁移旧代只返回当前逻辑视图；写打开才发布新的当前代文件。崩溃 repair 仍通过普通 append 把合成 closers 写入当前代。
- 导出：`session-log-export` 在会话头“更多操作”菜单提供 `Download session log` 与 `Copy Session as Markdown`，`/export` 斜杠命令触发同一个 ZIP 下载；ZIP 从 persistence read handle 序列化当前逻辑日志，并收集图片与通用文件（细节见对话导出与分享类目）。
- 官方会话日志上传：`session-log-deepseek` 在启用官方 DeepSeek 请求元数据的部署里，把规范化会话日志作为请求字段增量上传，并以 `session-log-deepseek/delivery-accepted` 事件维护接受水位；插件可注册排除谓词让特定请求不贡献日志。上传只针对官方 API，禁用该插件即关闭。
- 导入/备份恢复：**本次未找到**会话级导入 API 或整包备份恢复机制（检查范围：持久化抽象、JSONL provider、store 与 agent resume 入口、session-log-export 的反向路径）。

## 11. 外部对象绑定

- **会话级（header）**：cwd、父会话、`isSeeded` 与 `inheritedEventCount`、subagent 标记与深度、agent preset 都随 header 持久化；preset 可恢复会话的工具与提示构成。
- **请求级（日志事件）**：每次请求的 config 与工具 schema 以全量快照进 `request/header`（reason 区分 initial/resume/change/series）；路由容量与 `systemPromptUpdate` 进 `request/context`（仅变化时记录），两者都是 log-only，不产生消息。system prompt 是表面事件而非请求头字段。
- **消息级**：`user/message.source` 区分人、注入与目标续写来源；`assistant/message` 携带 provider/model 与内嵌流；`tool/result` 携带 callId、可选失败身份与工具私有 `meta`（随日志持久化，回放时客户端可重建同一卡片）。
- 会话工作目录：`working-directory` 让单个会话切换 cwd，已有进程保留自己的目录，选择可重放并进入用户上下文；目录缺失时回退到仍可用的原项目目录。
- 引述：`message-quotes` 只在 Client 侧注册引用控件与引用块呈现，消息本身保持普通 Markdown，不写引述元数据或内容索引。
- 身份与作用域：匿名身份 `getOrCreateAnonymousUserId()` 是进程共享库（`$DSH_HOME/.anonymous-user-id`），只进遥测资源属性与 DeepSeek 请求头，不进会话数据；`dsh-scope` 提供 per-agent 作用域，session 事件经 `scopeTarget` 按作用域过滤派发。

## 12. 设计取舍与已确认边界

- **事件日志而非消息表**：全部对话状态可重放，投影按需派生；代价是日志只增不减。当前 JSONL 用 checksummed zstd frame、不可变格式代际与生成目录指纹控制体积与迁移风险。
- **system prompt 作为表面节点**：提示变更被表达为替换或追加系统消息，`request/header` 只保留 config 与工具，`headerEquals` 不必把提示文本差异当成请求信封变化；代价是表面折叠要额外守卫 node 0 的替换规则。
- **一次尝试一个收口**：把 chunk 内嵌进 `assistant/message`/`assistant/attempt`，后端只需保证一次尝试一条耐久记录，续读与重放都按尝试边界对齐；代价是单条事件变大，压缩与校验要在记录内部完成。
- **模型历史与 transcript 双投影**：surface 遮蔽替换范围、append-origin 事件保留人可见历史，两者同源于日志但语义刻意不同。
- **格式迁移显式化**：当前为 v4，历史变化由相邻边逐代迁移，每条边有独立的包、README 规格与拒绝规则；这样单条边的所有权和测试边界清晰，代价是包的个数随格式代数增长。
- **持久化与执行解耦**：`session/event` 同步通知、持久化异步追赶、checkpoint policy 只卡语义边界（模型请求、顶层工具、pre-step），不在 turn 边界强刷。
- **无删除、无导入；跨进程只仲裁写所有权**：本次未找到会话日志删除或导入 API。归档是导航层状态而非日志删除；JSONL 用 kernel lease 阻止同一会话并发写，没有多写者合并协议。

## 13. 未验证事项

- 未运行任何会话或持久化后端；崩溃恢复路径（torn tail 截断、部分 zstd 帧恢复、interrupted closers 合成）与 resume 往返来自静态阅读。
- v0～v3 真实历史日志经 3→4 迁移后的语义等价性未用样本验证；迁移只由包内单测与生成目录规格声明。
- POSIX flock、Windows 命名信号量与网络文件系统上的跨进程写排斥未运行验证。
- 插件消息投影在恢复路径上的缺失解释器拒绝、`contentGeneration` 对缓存失效的实际效果未运行验证。
- 会话日志上传的请求形态、接受水位推进与失败重试只在 README/源码层面确认，未对官方 API 发请求。
- FTS5 搜索的召回质量与 `DatabaseSync` 同步阻塞影响未运行验证；`openAt` 三档的实际生命周期未实测。
- 归档门禁对子会话、恢复页与跨标签页同步的实际行为未运行验证。
- 未覆盖标题生成、统计投影与 turn 大纲在超长会话与分页窗口下的缓存行为。

## 14. 关键源码索引

- `packages/core/session/src/types.ts`：`90`（SESSION_FORMAT_VERSION）、`95-150`（SessionHeader/isSeeded）、`246`（EpochHeader）、`287`（SessionEventMap）、`447`（SurfaceEventType）
- `packages/core/session/src/index.ts`：`999`（deriveMessages）、`1064`（SessionStore）、`1127`（create）、`1158`（prepare）、`1403`（fork）
- `packages/core/session/src/surface.ts`：`89`（isAppendSurfaceEvent）、`120`（deriveEventMessage）、`594`（foldSurface）、`612`（SurfaceManager）
- `packages/core/session/src/request-header.ts:63`（foldRequestHeader）、`repair.ts:209`（interruptedTurnClosers）
- `packages/session/session-persistence/src/handle.ts`（句柄契约）；`session-persistence-jsonl/src/{storage,generation,lease,migration-verifier}.ts`
- `packages/session/session-format/src/{catalog,chain,filename}.ts` 与 `session-format-catalog/src/{index,generated,children,message-projections}.ts`（格式链与读取器）
- `packages/session/session-format-v3-to-v4/README.md`（v4 迁移规格与拒绝条件）
- `packages/session/session-checkpoint-policy/src/index.ts:35,72,80`（检查点屏障）
- `packages/session/session-projection/src/index.ts:282`（投影注册表）、`session-projection-cache/README.md`（持久化检查点）
- `packages/session/{working-directory,message-quotes,session-title,session-stats,session-turn-outline,session-log-deepseek}/README.md`（会话组新增能力）
- `packages/session-query/session-query/README.md`、`session-query-sqlite/README.md`（查询与 FTS5）
- `packages/api/session-controller/src/index.ts:278,292,303`（list/search/create Remote）、`src/archived-session-gate.ts`（归档门禁）
- `packages/core/agent-loop/src/index.ts:752`（resume）、`packages/workspace/workspace/README.md`（工作区与归档集合）
- `docs/subsystems/session.md`、`docs/subsystems/persistence.md`、`docs/session-format-status.md`、`docs/persistence-catalog.md`、`docs/persistence-schema.json`
