# Pi 会话与消息管理调查笔记

> 调查对象：`../../pi`（重点 `packages/coding-agent/src/core/session-manager.ts`、`packages/coding-agent/src/core/agent-session.ts`、`packages/agent/src/harness/session/`、`packages/agent/src/search/`、`packages/session-backends/sqlite-node/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`534bcbffb7e1e7551d9ee3572dfeb278e203e493`（分支：`main`）
>
> 调查方式：直接阅读源码（`SessionManager` 全文件通读、harness JSONL 后端、搜索模块、sqlite 后端包、TUI 删除入口），逐项核实并修正此前笔记中的符号引用与行号；未运行交互会话
>
> 调查范围：会话/消息/分支数据模型、JSONL 文件持久化与版本迁移、生命周期与分支指针、列表扫描与搜索、会话级绑定；发送执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的会话是"JSONL 追加型树"，持久化事实源是每个会话一个 `.jsonl` 文件：

- 每个会话一个 `.jsonl` 文件（`~/.pi/agent/sessions/--<编码cwd>--/`），每条记录带 `id/parentId` 形成树；`leafId` 指针标识当前位置，分支只移动指针不修改历史（`session-manager.ts:844-854` 类注释）。
- 落盘发生在 message_end：第一条 assistant 消息落盘时创建文件，此前仅缓存（`_persist`，`session-manager.ts:1015-1042`）。
- 消息是分块内容模型：user/assistant/toolResult 与 custom/bashExecution/compactionSummary/branchSummary 并存；assistant 内容是 `text/thinking/toolCall` 块数组。
- 编辑以分支表达：历史追加型不可就地修改；会话删除只在 UI 层做文件级删除（trash/unlink），`SessionManager` 类本身无删除方法。
- 会话列表搜索是一次性扫描（fuzzy/正则），无消息级索引；消息级搜索只存在于独立的搜索模块与独立的 sqlite 后端包中，均未接入 TUI/AgentSession 路径。

## 系统边界与数据主链

```text
AgentSession.prompt() -> Agent -> agentLoop（执行链 -> 对话请求与上下文）
  -> AgentSession._handleAgentEvent（core/agent-session.ts:610-681）
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

- **会话单位**：`SessionManager` 构造时用 `uuidv7` 生成会话 id（`createSessionId`，`session-manager.ts:208-210`）；文件名为 `<ISO时间戳(冒号与句点替换为连字符)>_<id>.jsonl`（`session-manager.ts:951-953`）。会话目录按 cwd 编码：`--<cwd 中 / \ : 替换为 ->--`（Windows 上 `E:\works\git\pi` → `--E-works-git-pi--`，`getDefaultSessionDirPath`，`session-manager.ts:476-481`）。文件首行是 `SessionHeader { type, version(当前3), id, timestamp, cwd, parentSession? }`（`session-manager.ts:32-39`）。
- **条目类型**：`SessionEntry` 联合 `message/thinking_level_change/model_change/compaction/branch_summary/custom/custom_message/label/session_info`（`session-manager.ts:144-153`）。`custom` 是扩展状态存储（不参与 LLM 上下文，`session-manager.ts:94-108` 注释）；`custom_message` 参与上下文并控制 TUI 显示（`session-manager.ts:123-141`）；`label` 是条目书签，`session_info` 是显示名（`session-manager.ts:110-121`）。
- **消息结构**：`AgentMessage` 是 `Message | CustomAgentMessages[...]` 的联合（`packages/agent/src/types.ts:321-325`）；assistant 消息为 `AssistantMessage`（`packages/ai/src/types.ts:415-435`），含 `content` 块数组（text/thinking/toolCall）、`usage`、`stopReason`、`errorMessage`、`deferred` 句柄。工具结果以 `ToolResultMessage`（role=toolResult，`packages/ai/src/types.ts:437-453`，含 toolCallId/toolName/isError）独立成消息。coding-agent 扩展角色在 `core/messages.ts:29-77`：`bashExecution`（带 `excludeFromContext`）、`custom`、`branchSummary`、`compactionSummary`。
- **版本迁移**：v1→v2 生成 id/parentId 树并把 compaction 的 `firstKeptEntryIndex` 转为 `firstKeptEntryId`，v2→v3 把 `hookMessage` 角色改名为 `custom`（`migrateV1ToV2`/`migrateV2ToV3`，`session-manager.ts:231-275`）；读文件时若版本落后则迁移并重写文件（`session-manager.ts:917-919`）。

## 2. 事实源、索引与持久化

- 事实源：文件系统中的 `.jsonl` 文件；无数据库、无独立索引文件。
- 落盘时机：`_persist`（`session-manager.ts:1015-1042`）：没有 assistant 消息时只缓存；第一条 assistant 消息到达时以 `wx` 标志整文件写出（`flushed=true`），此后逐条 append。这保证了"没有模型回复的会话不产生文件"。
- 恢复：`loadEntriesFromFile` 全量读入内存（`session-manager.ts:514-556`，1MB 缓冲流式解析，跳过坏行；首条必须是合法 header 否则视为空）。header 快速发现另有 4KB 缓冲、1MB 上限的有界扫描（`readSessionHeader`，`session-manager.ts:571-613`），发现逻辑出错仅返回 null 不影响其它会话（`readSessionHeaderForDiscovery`，:615-623）。
- 列表索引：`SessionManager.list(cwd)`/`listAll()`（`session-manager.ts:1638-1647`/`:1654-1713`）扫描 `sessions/` 下各 cwd 目录的 `.jsonl`，`buildSessionInfo` 流式读文件提取 id/cwd/name/messageCount/firstMessage/allMessagesText/最后活动时间（`session-manager.ts:687-765`），并发上限 10（`buildSessionInfosWithConcurrency`，`session-manager.ts:769-809`），按修改时间倒序。`--session-dir` 自定义目录时按 header.cwd 过滤（`list` 的 `filterCwd`，`session-manager.ts:1640-1643`；`continueRecent` 同逻辑 :1559-1560）。`findMostRecentSession` 只读各文件首行 header 并按 mtime 排序（`session-manager.ts:635-656`）。

## 3. 创建、切换、归档、删除与恢复

- **新建/继续/恢复**：`SessionManager.create/open/continueRecent/inMemory`（`session-manager.ts:1519-1570`）。`AgentSessionRuntime.newSession/switchSession` 先 `teardownCurrent`（abort 当前响应 → 发 `session_shutdown` 扩展事件 → dispose）再创建新 runtime（`core/agent-session-runtime.ts:167-178`、`:196-260`）。
- **命名**：`appendSessionInfo(name)` 记录 `session_info` 条目，空字符串清除名字（`session-manager.ts:1136-1147`）；显示名取最新条目（`getSessionName`，`session-manager.ts:1150-1161`）。选择器内重命名入口见 Chat UI 笔记 §2。
- **删除/归档**：`SessionManager` 类无删除方法（全文件通读确认，`session-manager.ts:855-1714` 无删除入口）；删除在 UI 层做文件级删除：`deleteSessionFile`（trash 优先、unlink 兜底，`components/session-selector.ts:645-680`），挂到会话选择器的删除处理（`:832-856`），入口为选择器内 Ctrl+D（`app.session.delete`，`core/keybindings.ts:147-150`）与 Ctrl+Backspace（`deleteSessionNoninvasive`，`:151-154`、`session-selector.ts:592-601`），先进入确认状态（`session-selector.ts:394-405`、`:536-549`），当前活动会话不可删（:399-402）。注意：harness 侧的 `JsonlSessionRepo` 有 `delete()`（文件级 remove，`packages/agent/src/harness/session/jsonl/repo.ts:138-140`），与 coding-agent 的 `SessionManager` 是两套实现。
- **恢复语义**：中断后 assistant 消息以 `stopReason: "aborted"` 持久化（执行侧见对话请求与上下文笔记 §6），下次 `/resume` 恢复该消息；断网自动续传未找到。

## 4. 编辑、重试、续写、回退与分支语义

- **分支**：`branch(branchFromId)` 移动 leaf 指针（`session-manager.ts:1360-1365`）；`createBranchedSession` 把"根到指定叶子"的路径抽成新文件，重链 label 条目并记 `parentSession`（`session-manager.ts:1412-1512`）；`forkFrom` 跨目录复制整个会话到新 cwd 并记 `parentSession`（`session-manager.ts:1579-1630`）；`branchWithSummary` 追加 `branch_summary` 摘要条目（`session-manager.ts:1381-1405`）。UI 层分支切换入口是 `navigateTree`（`agent-session.ts:2905-3095`，支持可选的分支摘要生成）。
- **回退**：`resetLeaf` 把指针清空以便重发首条 user 消息（`session-manager.ts:1372-1374`）。
- **消息编辑**：本次未找到对已落盘消息的就地编辑 API；历史是追加型，修改以分支形式表达（`getEntries` 注释明示 entries 不可修改/删除，`session-manager.ts:1296-1303`）。
- **续写**：未找到"继续生成到当前消息末尾"的独立入口；续写通过分支/新消息实现。
- **重试执行**：重试如何选择起始上下文见对话请求与上下文笔记 §7；`/fork` 从指定 user 消息创建分支的入口见 Chat UI 笔记 §3。

## 5. 列表、分页、搜索与定位

- **会话列表**：`SessionManager.list/listAll` 全量扫描 + 并发上限 10（§2）；无分页游标。
- **搜索**：`session-selector-search.ts` 支持 token 模式（fuzzy/短语混合，`"node cve"` 引号）与 `re:` 正则模式，搜索文本是 `id + name + 全部消息文本 + cwd`（`getSessionSearchText`，`session-selector-search.ts:26-28`；解析 `parseSearchQuery` :39-114）；`/resume` 会话选择器内嵌搜索框（入口见 Chat UI 笔记 §2）。
- **消息级搜索**：本次未找到接入 TUI/AgentSession 路径的实现。搜索能力以独立模块存在：`packages/agent/src/search/` 定义 `SessionSearch` 接口（`search(text, options): AsyncIterable<Hit>`，`entryTypes`/`limit`/`signal`，`search/index.ts:14-31`）与扫描实现 `createScanningSessionSearch`（对可读存储分页扫描，`search/scanning.ts:135-176`）；另有独立包 `packages/session-backends/sqlite-node/` 提供 SQLite 会话仓库与 FTS5 全文搜索（`createSqliteSessionSearch`，`sqlite/search-backend.ts:98-194`，`session_search_fts MATCH` + bm25 排序）。两者仅在本包测试中使用（`packages/agent/test/harness/session/search.test.ts`、`sqlite-node/test/search.test.ts`），未发现被 coding-agent/TUI 引用。
- **定位/统计**：`/session` 显示统计（用户/助手/工具消息数、token、成本，`getSessionStats`，`agent-session.ts:3122-3172`）；`/tree` 树形导航带 label 书签（`getTree`，`session-manager.ts:1310-1348`）。

## 6. 缓存、一致性、多窗口与并发写入

- 写入是单进程逐条 append；`_persist` 在"无 assistant 消息"阶段仅缓存（§2）。内存 `fileEntries` 数组是运行时权威，文件是磁盘投影；同进程内读改写（压缩、分支重链）走整文件重写（`_rewriteFile`，`session-manager.ts:979-989`），期间不持有文件锁。
- 多实例并发写同一会话文件的合并语义未调查：会话文件本身无锁/事务证据（检查范围：`session-manager.ts` 全部写入入口均无 lockfile 调用）。设置文件例外：`settings.json` 写入使用 `proper-lockfile` 同步锁（`settings-manager.ts:195-262`），与会话文件无关。
- 单会话单 agent 循环（执行侧见对话请求与上下文笔记 §8），会话文件本身无并发写保护证据。
- **harness 侧（packages/agent）JSONL 后端**（与 coding-agent 的 `SessionManager` 是并行实现，header version 4、seq 编号、lanes 指针）：会话列表只读各文件首行 header 提取元数据（`listJsonlSessionMetadata`，`harness/session/jsonl/repo.ts:65-87`）；会话 id 的重复检查限定在目标 cwd 目录内（`sessionIdExists(id, cwd)`，`repo.ts:226-232`）；同进程同 cwd+id 的并发 create/fork 直接拒绝（`claimCreateDestination`，`repo.ts:174-188`）；fork 以"整文件临时文件 + 原子 rename"方式发布（`publishFileAtomically`/`fork`，`harness/session/jsonl/storage.ts:33-46`、`:110-120`），加载时发现 torn-tail 半截追加则原子发布有效前缀截断修复（`storage.ts:84-92`）；会话名称可显式清除（`setName(undefined)`，`storage.ts:227-233`，mutation 类型 `fact/name: string | undefined` 见 `state.ts:21-22`、应用见 :159-166）。

## 7. 迁移、导入导出与保留策略

- 版本迁移：读文件时落后版本自动迁移并重写（§1，`session-manager.ts:917-919`）。
- 一次性目录迁移：`migrateSessionsFromAgentRoot` 把历史版本误存到 `~/.pi/agent/*.jsonl` 的文件按 header.cwd 移到编码目录（`migrations.ts:84-131`，注释引用 issue #320）。
- **导出**：`/export` 支持 HTML（`core/export-html/`，vendor 的 marked v18.0.5 + highlight.js 生成静态页面，`export-html/index.ts:148-173`）与 JSONL（`exportToJsonl` 导出当前分支并重链 parentId 成线性序列，`agent-session.ts:3249-3280`）。
- **导入**：`/import` 复制 JSONL 到会话目录后恢复（`importFromJsonl`，`agent-session-runtime.ts:361-396`）；`/share` 以 GitHub secret gist 分享（`interactive-mode.ts:5862-5951`，`gh gist create --public=false`）。
- 保留策略：压缩后旧条目仍在文件中但不再进上下文（执行侧见对话请求与上下文笔记 §3）；无自动清理/轮转策略的证据（检查范围：`session-manager.ts` 无删除/清理路径，配置项中未发现保留期限字段）。

## 8. Agent、模型、知识库与附件绑定

- **绑定层级**：模型与 thinking level 绑定在会话状态（`agent.state.model/thinkingLevel`），切换写入 `model_change`/`thinking_level_change` 条目（`setModel`/`cycleModel`，`agent-session.ts:1586-1673`；`appendModelChange`/`appendThinkingLevelChange`，`session-manager.ts:1070-1094`）。工具启用集在会话级（`setActiveToolsByName`，`agent-session.ts:928-943`），默认 `[read, bash, edit, write]`（`_buildRuntime` 的 `defaultActiveToolNames`，`agent-session.ts:2600-2602`），`--tools`/设置可增删。
- **Agent 形态**：`Agent` 是单活动运行（activeRun 守卫，`packages/agent/src/agent.ts:347-358`、`:486-489`）的工具循环 runtime，`AgentSession` 包一层事件/持久化/压缩。此前笔记所称 README 中 "No sub-agents" 的表述本次未在 `packages/agent/README.md` 找到；子 Agent 目前由扩展自行实现（示例 `packages/coding-agent/examples/extensions/subagent/`），harness 文档提到 lanes 可支撑 subagents（`packages/agent/docs/harness.md:98`），但均非 `Agent` 内置能力。扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- **附件**：图片以 `ImageContent` 进 user 消息（剪贴板图片、`--image`、拖动/粘贴，入口见 Chat UI 笔记 §1）；`settings.images.autoResize/blockImages` 控制自动缩放与阻止发送（`settings-manager.ts:46-49`、`:1161-1185`）。工具结果中的图片可回注为上下文图像（`normalizeToolResultImages`，`agent-session.ts:517-531`）。
- **外部能力**：skills（`/skill:name` 展开为 `<skill>` 块 + 进 system prompt 索引）、prompt 模板（`/template`）、扩展注入的 custom 消息、`before_agent_start` 系统提示改写均在此链路生效（`agent-session.ts:1159-1261`；注入语义见对话请求与上下文笔记 §9）。

## 9. 设计取舍与已确认边界

- **追加型树会话**：不覆盖历史，编辑以分支表达；代价是单个文件持续增长，恢复时全量读入内存（`loadEntriesFromFile`，`session-manager.ts:514-556`）。
- **压缩是重写而非分页**：压缩后旧条目仍在文件中但不再进上下文，保留可回溯性（执行侧见对话请求与上下文笔记 §3）。
- **上下文边界明确**：`custom` 条目、`bashExecution(excludeFromContext)`、`custom_message(display=false)` 各自独立控制"是否进 LLM 上下文"与"是否可见"（执行侧见对话请求与上下文笔记 §2）。
- **"没有模型回复的会话不产生文件"**：落盘时机绑定 message_end（§2）。
- **两套并行的会话实现**：coding-agent 的 `SessionManager`（v3 header）与 `packages/agent` 的 harness JSONL 后端（v4 header、seq/lanes）互不引用；搜索接口与 sqlite 包也未接入主链路（§5）。

## 10. 未验证事项

- 多实例并发写同一会话文件、文件损坏与恢复未验证（agent 侧 JSONL 已有 torn-tail 原子截断与同进程 create/fork 冲突拒绝，但均未运行验证）。
- 长会话列表扫描（一次性全量读取）的性能未运行基准（`buildSessionInfo` 并发上限 10）。
- 版本迁移的边界情况（中断迁移、损坏文件）未验证。
- 未运行交互会话；结论来自静态源码。

## 11. 关键源码索引

- `packages/coding-agent/src/core/session-manager.ts`：`844-854`（树模型注释）、`1015-1042`（落盘时机）、`1638-1713`（列表扫描）、`1360-1512`（分支）、`1579-1630`（forkFrom）、`231-291`（版本迁移）、`514-556`（读取）
- `packages/coding-agent/src/core/agent-session.ts`：`610-681`（message_end 落盘）、`928-943`（工具集）、`1159-1261`（外部能力链路）、`3122-3172`（统计）
- `packages/coding-agent/src/core/agent-session-runtime.ts:167-178`（切换会话 teardown）、`361-396`（导入）
- `packages/coding-agent/src/modes/interactive/components/session-selector.ts:645-680`、`:832-856`（删除入口）
- `packages/coding-agent/src/modes/interactive/components/session-selector-search.ts:26-114`（搜索）
- `packages/coding-agent/src/core/keybindings.ts:147-154`（删除快捷键）
- `packages/agent/src/harness/session/jsonl/repo.ts`、`storage.ts`（harness JSONL 后端）
- `packages/agent/src/search/scanning.ts:135-176`、`search/index.ts:14-31`（搜索接口，未接入）
- `packages/session-backends/sqlite-node/src/sqlite/search-backend.ts:98-194`（FTS5 搜索，未接入）
