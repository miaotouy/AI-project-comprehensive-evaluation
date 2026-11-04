# Pi 会话与消息管理调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/coding-agent/src/core/session-manager.ts`、`packages/coding-agent/src/core/agent-session.ts`、`packages/durable/src/session/`、`packages/durable/src/storage/`、`apps/p2/plugins/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：直接阅读源码（`SessionManager` 全文件通读、durable 会话与存储模块、p2 搜索插件、TUI 删除入口），逐项核实并修正此前笔记中的符号引用与行号；未运行交互会话
>
> 调查范围：会话/消息/分支数据模型、JSONL 文件持久化与版本迁移、生命周期与分支指针、列表扫描与搜索、会话级绑定；发送执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的会话是"JSONL 追加型树"，持久化事实源是每个会话一个 `.jsonl` 文件：

- 每个会话一个 `.jsonl` 文件（`~/.pi/agent/sessions/--<编码cwd>--/`），每条记录带 `id/parentId` 形成树；`leafId` 指针标识当前位置，分支只移动指针不修改历史（`session-manager.ts:988`（类）与 `:1528`（append-only 注释））。
- 落盘发生在 message_end：第一条 assistant 消息落盘时创建文件，此前仅缓存（`_persist`，`session-manager.ts:1173`）。
- 消息是分块内容模型：user/assistant/toolResult 与 custom/bashExecution/compactionSummary/branchSummary 并存；assistant 内容是 `text/thinking/toolCall` 块数组。
- 编辑以分支表达：历史追加型不可就地修改；会话删除只在 UI 层做文件级删除（trash/unlink），`SessionManager` 类本身无删除方法。
- 会话列表搜索是一次性扫描（fuzzy/正则），无消息级索引；消息级全文检索只存在于 p2 的搜索插件（SQLite FTS5）里，CLI/TUI 路径未接入。
- 仓库还有第二套会话栈 `packages/durable`：不可变 entry + commit 落存储、崩溃后可 `resume()`、存储后端可在 Memory/JSONL/SQLite/IndexedDB 间替换；p2 建在它之上，CLI/TUI 仍用 `SessionManager`。

## 系统边界与数据主链

```text
AgentSession.prompt() -> Agent -> agentLoop（执行链 -> 对话请求与上下文）
  -> AgentSession._handleAgentEvent（core/agent-session.ts:1123）
       user/assistant/toolResult 消息 -> sessionManager.appendMessage
  -> _persist（session-manager.ts:1015-1042）：
       无 assistant 消息 -> 仅缓存
       第一条 assistant 消息 -> 整文件写出（flushed=true）
       此后 -> 逐条 append
  -> SessionManager.list / listAll（列表扫描，并发上限 10）
  -> buildSessionContext（读取时沿 leaf 回溯，执行侧 -> 对话请求与上下文）
```

边界：上下文构建、压缩与流式事件链属于对话请求与上下文（`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`）；命令面板、选择器与状态行的用户工作流属于 Chat UI（`<../Chat UI/Pi-ChatUI调查笔记.md>`）；消息内容渲染属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 会话、消息与分支数据模型

- **会话单位**：会话 id 由 `SessionManager` 构造时用 `uuidv7` 生成（`createSessionId`，`session-manager.ts:264`），其余命名规则分三点：
  - 文件名：`<ISO时间戳(冒号与句点替换为连字符)>_<id>.jsonl`（`session-manager.ts:1081`）；
  - 会话目录按 cwd 编码：`--<cwd 中 / \ : 替换为 ->--`（Windows 上 `E:\works\GitStudyNotes\pi` → `--E-works-GitStudyNotes-pi--`，`getDefaultSessionDirPath`，`session-manager.ts:590`）；
  - 文件首行：`SessionHeader { type, version(当前3), id, timestamp, cwd, parentSession? }`（`session-manager.ts:43`）。
- **条目类型**：`SessionEntry` 联合 `message/thinking_level_change/model_change/compaction/branch_summary/custom/custom_message/label/session_info`（`session-manager.ts:183`），用途分三类：
  - `custom`：扩展状态存储，不参与 LLM 上下文（`session-manager.ts:94-108` 注释）；
  - `custom_message`：参与上下文并控制 TUI 显示（`session-manager.ts:123-141`）；
  - `label`：条目书签；`session_info`：显示名（`session-manager.ts:110-121`）。
- **消息结构**：`AgentMessage` 是 `Message | CustomAgentMessages[...]` 的联合（`packages/agent/src/types.ts:374`），消息分三类：
  - assistant 消息：`AssistantMessage`（`packages/ai/src/types.ts:593`），含 `content` 块数组（text/thinking/toolCall）、`usage`、`stopReason`、`errorMessage`、`deferred` 句柄；
  - 工具结果：`ToolResultMessage`（role=toolResult，`packages/ai/src/types.ts:648`，含 toolCallId/toolName/isError）独立成消息；
  - coding-agent 扩展角色（`core/messages.ts:30-80`）：`bashExecution`（带 `excludeFromContext`）、`custom`、`branchSummary`、`compactionSummary`。
- **版本迁移**：读文件时若版本落后则自动迁移并重写（`session-manager.ts:343-344`），分两步：
  - v1→v2：生成 id/parentId 树，并把 compaction 的 `firstKeptEntryIndex` 转为 `firstKeptEntryId`；
  - v2→v3：把 `hookMessage` 角色改名为 `custom`（`migrateV1ToV2`/`migrateV2ToV3`，`session-manager.ts:287-341`）。

## 2. 事实源、索引与持久化

- 事实源：文件系统中的 `.jsonl` 文件；无数据库、无独立索引文件。
- 落盘时机：`_persist`（`session-manager.ts:1015-1042`）：没有 assistant 消息时只缓存；第一条 assistant 消息到达时以 `wx` 标志整文件写出（`flushed=true`），此后逐条 append。这保证了"没有模型回复的会话不产生文件"。
- 恢复：`loadEntriesFromFile` 全量读入内存（`session-manager.ts:628`，1MB 缓冲流式解析，跳过坏行；首条必须是合法 header 否则视为空）。header 快速发现另有 4KB 缓冲、1MB 上限的有界扫描（`readSessionHeader`，`session-manager.ts:686`），发现逻辑出错仅返回 null 不影响其它会话（`readSessionHeaderForDiscovery`，:615-623）。
- 列表索引：`SessionManager.list(cwd)`/`listAll()`（`session-manager.ts:1916`/`:1937`）扫描 `sessions/` 下各 cwd 目录的 `.jsonl`，机制分几点：
  - 信息提取：`buildSessionInfo` 流式读文件提取 id/cwd/name/messageCount/firstMessage/allMessagesText/最后活动时间（`session-manager.ts:800`）；
  - 并发与排序：并发上限 10（`buildSessionInfosWithConcurrency`，`session-manager.ts:925`），按修改时间倒序；
  - cwd 过滤：`--session-dir` 自定义目录时按 header.cwd 过滤（`list` 的 `filterCwd`，`session-manager.ts:1916-1930`；`continueRecent` 同逻辑 `:1804`）；
  - 最近会话：`findMostRecentSession` 只读各文件首行 header 并按 mtime 排序（`session-manager.ts:750`）。

## 3. 创建、切换、归档、删除与恢复

- **新建/继续/恢复**：`SessionManager.create/open/continueRecent/inMemory`（`session-manager.ts:1766-1825`）。`AgentSessionRuntime.newSession/switchSession` 先 `teardownCurrent`（abort 当前响应 → 发 `session_shutdown` 扩展事件 → dispose）再创建新 runtime（`core/agent-session-runtime.ts:167-178`、`:196-260`）。
- **命名**：`appendSessionInfo(name)` 记录 `session_info` 条目，空字符串清除名字（`session-manager.ts:1315`）；显示名取最新条目（`getSessionName`，`session-manager.ts:1329`）。选择器内重命名入口见 Chat UI 笔记 §2。
- **删除/归档**：`SessionManager` 类无删除方法（全文件通读确认，`session-manager.ts:988-2029` 无删除入口）；删除在 UI 层做文件级删除，分几个环节：
  - 删除执行：`deleteSessionFile`（trash 优先、unlink 兜底，`components/session-selector.ts:645-680`），挂到会话选择器的删除处理（`:832-856`）；
  - 入口：选择器内 Ctrl+D（`app.session.delete`，`core/keybindings.ts:147-150`）与 Ctrl+Backspace（`deleteSessionNoninvasive`，`:151-154`、`session-selector.ts:592-601`）；
  - 确认与保护：先进入确认状态（`session-selector.ts:394-405`、`:536-549`），当前活动会话不可删（`:399-402`）。
  - 注意：durable 的 JSONL 存储本次未找到文件级删除接口（检查范围 `packages/durable/src/storage/jsonl/`），与 coding-agent 的 `SessionManager` 是两套实现。
- **恢复语义**：中断后 assistant 消息以 `stopReason: "aborted"` 持久化（执行侧见对话请求与上下文笔记 §6），下次 `/resume` 恢复该消息；断网自动续传未找到。

## 4. 编辑、重试、续写、回退与分支语义

- **分支**：分支相关能力分四个方法（均在 `session-manager.ts`）：
  - `branch(branchFromId)`（`:1590`）：移动 leaf 指针；
  - `createBranchedSession`（`:1643`）：把"根到指定叶子"的路径抽成新文件，重链 label 条目并记 `parentSession`；
  - `forkFrom`（`:1826`）：跨目录复制整个会话到新 cwd 并记 `parentSession`；
  - `branchWithSummary`（`:1611`）：追加 `branch_summary` 摘要条目。
  - UI 层分支切换入口是 `navigateTree`（`agent-session.ts:4093`，支持可选的分支摘要生成）。
- **回退**：`resetLeaf` 把指针清空以便重发首条 user 消息（`session-manager.ts:1602`）。
- **消息编辑**：本次未找到对已落盘消息的就地编辑 API；历史是追加型，修改以分支形式表达（`getEntries` 注释明示 entries 不可修改/删除，`session-manager.ts:1528`）。
- **续写**：未找到"继续生成到当前消息末尾"的独立入口；续写通过分支/新消息实现。
- **重试执行**：重试如何选择起始上下文见对话请求与上下文笔记 §7；`/fork` 从指定 user 消息创建分支的入口见 Chat UI 笔记 §3。

## 5. 列表、分页、搜索与定位

- **会话列表**：`SessionManager.list/listAll` 全量扫描 + 并发上限 10（§2）；无分页游标。
- **搜索**：`session-selector-search.ts` 支持 token 模式（fuzzy/短语混合，`"node cve"` 引号）与 `re:` 正则模式，搜索文本是 `id + name + 全部消息文本 + cwd`（`getSessionSearchText`，`session-selector-search.ts:26-28`；解析 `parseSearchQuery` :39-114）；`/resume` 会话选择器内嵌搜索框（入口见 Chat UI 笔记 §2）。
- **消息级搜索**：coding-agent 的 TUI 路径仍只有会话级扫描，本次未找到按消息建索引的实现。相关能力现在分两处：
  - durable 自带的是工具检索而非消息检索：`packages/durable/src/search.ts` 提供 BM25 排序，供 codemode 的 `searchTools()` 与 `tool_search` 工具使用；
  - p2 有真正的消息全文检索：`apps/p2/plugins/search/` 在 SQLite 上建 `message_search` FTS5 虚表（`create virtual table ... content='messages'`），查询用 `MATCH` + bm25，`plugins/search/query.ts` 负责把用户输入转成安全的 MATCH 表达式，供历史工具与页面使用（`db.ts:43`、`:143`、`:170`）。
- **定位/统计**：`/session` 显示统计（用户/助手/工具消息数、token、成本，`getSessionStats`，`agent-session.ts:4317`）；`/tree` 树形导航带 label 书签（`getTree`，`session-manager.ts:1540`）。

## 6. 缓存、一致性、多窗口与并发写入

- 写入是单进程逐条 append；`_persist` 在"无 assistant 消息"阶段仅缓存（§2）。内存 `fileEntries` 数组是运行时权威，文件是磁盘投影；同进程内读改写（压缩、分支重链）走整文件重写（`_rewriteFile`，`session-manager.ts:1125`），期间不持有文件锁。
- 多实例并发写同一会话文件的合并语义未调查：会话文件本身无锁/事务证据（检查范围：`session-manager.ts` 全部写入入口均无 lockfile 调用）。设置文件例外：`settings.json` 写入使用 `proper-lockfile` 同步锁（`settings-manager.ts:195-262`），与会话文件无关。
- 单会话单 agent 循环（执行侧见对话请求与上下文笔记 §8），会话文件本身无并发写保护证据。
- **durable harness（packages/durable，p2 使用的另一套会话栈）**：会话是一段不可变 entry 的对话记录，外加对象拥有的命名文档；写入以 commit 为单位，先落存储再对外发布，进程中途死掉重开存储会接着跑（`packages/durable/README.md` 的 Persist and Resume）。存储后端可换：`MemoryStorage`（`storage/memory.ts:239`）、JSONL（`storage/jsonl/`）、SQLite（`storage/sqlite/`）与 IndexedDB（`storage/indexeddb.ts`），统一实现 `Storage` 接口（`types.ts:1331`）。
  - 会话身份：每个 conversation 有持久 UUIDv7，作为 `sessionId` 传给 pi-ai，用于 provider 的 prompt cache 与会话亲和；重开、重试、reset、压缩、换模型都不变，子会话与 fork 另取新 id。
  - 只读打开：另一个进程正在驱动同一会话时，可以 `readOnly: true` 打开，只做展示；任何写入、`resume()` 或会运行任务的调用都会以 `ReadOnlySession` 拒绝。
  - 与 coding-agent 的关系：两套实现互不引用，p2 的插件（agent、chat、sessions、search 等）建立在 durable 之上，而 `pi` CLI/TUI 仍走 `SessionManager`。

## 7. 迁移、导入导出与保留策略

- 版本迁移：读文件时落后版本自动迁移并重写（§1，`session-manager.ts:343-344`）。
- 一次性目录迁移：`migrateSessionsFromAgentRoot` 把历史版本误存到 `~/.pi/agent/*.jsonl` 的文件按 header.cwd 移到编码目录（`migrations.ts:84-131`，注释引用 issue #320）。
- **导出**：`/export` 支持 HTML（`core/export-html/`，vendor 的 marked、marked-cjk-friendly 与 highlight.js 生成静态页面，`export-html/index.ts:143-175`）与 JSONL（`exportToJsonl` 导出当前分支并重链 parentId 成线性序列，`agent-session.ts:4448`）。
- **导入**：`/import` 复制 JSONL 到会话目录后恢复（`importFromJsonl`，`agent-session-runtime.ts:359`）；`/share` 优先上传 Radius 组织 artifact，缺少 Radius 凭据时才回退 secret gist（`session-share.ts`、`gh gist create --public=false`）。
- 保留策略：压缩后旧条目仍在文件中但不再进上下文（执行侧见对话请求与上下文笔记 §3）；无自动清理/轮转策略的证据（检查范围：`session-manager.ts` 无删除/清理路径，配置项中未发现保留期限字段）。

## 8. Agent、模型、知识库与附件绑定

- **绑定层级**：模型与工具集都在会话状态上——
  - 模型与 thinking level：`agent.state.model/thinkingLevel`，切换写入 `model_change`/`thinking_level_change` 条目（`setModel`/`cycleModel`；`appendModelChange`/`appendThinkingLevelChange`，`session-manager.ts:1228-1254`）；
  - 工具启用集：会话级 `setActiveToolsByName`（`agent-session.ts:1562`），默认 `[read, bash, edit, write]`（`_buildRuntime` 的 `defaultActiveToolNames`，`agent-session.ts:2600-2602`），`--tools`/设置可增删。
- **Agent 形态**：`Agent` 是单活动运行（activeRun 守卫，`packages/agent/src/agent.ts:224`、`:365`）的工具循环 runtime，`AgentSession` 包一层事件/持久化/压缩。子 Agent 相关边界：
  - 根 `README.md:13-17` 明说跳过 sub-agents 这类特性，`packages/agent/README.md` 也未把它列为内置能力；
  - 子 Agent 目前由扩展自行实现（示例 `packages/coding-agent/examples/extensions/subagent/`），durable 文档把 subagents 与 abort 放在同一节讨论，但均非 `Agent` 内置能力；
  - 扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- **附件**：图片以 `ImageContent` 进 user 消息（剪贴板图片、`--image`、拖动/粘贴，入口见 Chat UI 笔记 §1）；`settings.images.autoResize`/`blockImages` 控制自动缩放与阻止发送（`settings-manager.ts:46-49`、`:1161-1185`）。工具结果中的图片可回注为上下文图像（`normalizeToolResultImages`，`agent-session.ts:727`）。
- **外部能力**：skills（`/skill:name` 展开为 `<skill>` 块 + 进 system prompt 索引）、prompt 模板（`/template`）、扩展注入的 custom 消息、`before_agent_start` 系统提示改写均在此链路生效（`agent-session.ts:1159-1261`；注入语义见对话请求与上下文笔记 §9）。

## 9. 设计取舍与已确认边界

- **追加型树会话**：不覆盖历史，编辑以分支表达；代价是单个文件持续增长，恢复时全量读入内存（`loadEntriesFromFile`，`session-manager.ts:628`）。
- **压缩是重写而非分页**：压缩后旧条目仍在文件中但不再进上下文，保留可回溯性（执行侧见对话请求与上下文笔记 §3）。
- **上下文边界明确**：`custom` 条目、`bashExecution(excludeFromContext)`、`custom_message(display=false)` 各自独立控制"是否进 LLM 上下文"与"是否可见"（执行侧见对话请求与上下文笔记 §2）。
- **"没有模型回复的会话不产生文件"**：落盘时机绑定 message_end（§2）。
- **两套并行的会话实现**：coding-agent 的 `SessionManager`（v3 header、JSONL 树）与 `packages/durable` 的 harness（不可变 entry + commit、四类存储后端）互不引用；CLI/TUI 走前者，p2 走后者，两套事实源未合并（§12）。

## 10. 未验证事项

- 多实例并发写同一会话文件、文件损坏与恢复未验证；durable 的崩溃恢复、`resume()` 重放与只读打开在真实进程崩溃下未运行验证。
- 长会话列表扫描（一次性全量读取）的性能未运行基准（`buildSessionInfo` 并发上限 10）。
- 版本迁移的边界情况（中断迁移、损坏文件）未验证。
- 未运行交互会话；结论来自静态源码。

## 11. 恢复与压缩边界

- 继续会话时，若既有 JSONL 文件末尾缺少换行，追加前会补齐分隔，避免后一条 entry 与前一条粘连；该恢复修正只作用于正常续写路径，不改变会话树的数据模型（`packages/coding-agent/CHANGELOG.md` 的 0.84.3 修复项）。
- 压缩和分支摘要不会向 provider 暴露可调用工具；若摘要在输出 token 上限处截断，结果不会写入会话。扩展还能收到带失败原因、重试状态和来源的 `session_compact_failed` 事件（`packages/coding-agent/CHANGELOG.md` 的 0.84.3 相关条目）。

## 12. 两套会话栈的成熟度

coding-agent 的 `SessionManager` 仍是 `pi` CLI/TUI 的事实源：版本 3 的 JSONL 树，落盘时机绑定 message_end，列表靠全量扫描。它的第 4 版格式与 Memory/JSONL/SQLite 三套可互换后端已经整体迁到 `packages/durable`，作为独立 harness 维护。

durable 的会话模型把对话记录（不可变 entry）、对象拥有的文档、以及运行任务分开：commit 是原子写入单位，任务与 phase 记录在存储里，崩溃后 `resume()` 从上次停下的地方继续，失败 phase 带固定错误分类（`task_faulted`/`task_failed`/`task_orphaned`）。它的 SQLite 后端自带 schema 与 migration，JSONL 后端面向单文件会话，IndexedDB 后端面向浏览器侧的 p2。

迁移关系仍有张力：旧 coding-agent v3 文件可以被 durable 一侧发现并作为只读会话打开，首次非空提交时升级；两套事实源未合并，同一台机器上 CLI 与 p2 各写各的。`packages/agent` 现在只剩 Agent 循环、类型与 provider 代理，不再承载 harness。

## 13. 关键源码索引

- `packages/coding-agent/src/core/session-manager.ts`：`:988` 类、`:1173` 落盘、`:1125` 整文件重写、`:1916`/`:1937` 列表、`:1590`/`:1643` 分支、`:1826` fork、`:287-341` 版本迁移、`:628` 读取；`:43` header、`:183` entry 类型
- `packages/coding-agent/src/core/agent-session.ts`：`:1123` message_end 落盘、`:1562` 工具集、`:4317` 统计、`:4448` JSONL 导出
- `packages/coding-agent/src/core/agent-session-runtime.ts`：`:167` 切换会话 teardown、`:359` 导入
- `packages/coding-agent/src/modes/interactive/components/session-selector.ts`、`session-selector-search.ts`（删除与搜索入口）
- `packages/durable/src/session/session.ts`、`entries.ts`、`documents.ts`、`storage/`（memory/jsonl/sqlite/indexeddb）、`README.md`（持久化与恢复语义）
- `apps/p2/plugins/search/db.ts`、`query.ts`（消息 FTS5 检索）
