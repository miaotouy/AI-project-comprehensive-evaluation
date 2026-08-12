# Pi 会话与消息管理调查笔记

> 调查对象：`../../pi`（重点 `packages/coding-agent/src/core/`、`packages/agent/src/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`534bcbffb7e1e7551d9ee3572dfeb278e203e493`（分支：`main`）
>
> 调查方式：从 [`../Chat/Pi-Chat调查笔记.md`](../Chat/Pi-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据；按提交范围核对 harness 侧 JSONL/搜索变更（search 迁移、原子写、按 cwd 限定 id、名称清除），coding-agent 的 SessionManager 未变
>
> 调查范围：会话/消息数据模型、JSONL 文件持久化与版本迁移、生命周期与分支指针、列表扫描与搜索、会话级绑定；发送执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的会话是"JSONL 追加型树"，持久化事实源是每个会话一个 `.jsonl` 文件：

- 每个会话一个 `.jsonl` 文件（`~/.pi/agent/sessions/<编码cwd>/`），每条记录带 `id/parentId` 形成树；`leafId` 指针标识当前位置，分支只移动指针不修改历史（`core/session-manager.ts:844-854` 类注释）。
- 落盘发生在 message_end：第一条 assistant 消息落盘时创建文件，此前仅缓存（`_persist`，`session-manager.ts:1015-1042`）。
- 消息是分块内容模型：user/assistant/toolResult 与 custom/bashExecution/compactionSummary/branchSummary 并存；assistant 内容是 `text/thinking/toolCall` 块数组。
- 编辑以分支表达：历史追加型不可就地修改；删除只在 UI 层（trash/unlink 文件）。
- 搜索是列表页一次性扫描（fuzzy/正则），无消息级索引。

## 系统边界与数据主链

```text
AgentSession.prompt() -> Agent -> agentLoop（执行链 -> 对话请求与上下文）
  -> AgentSession._handleAgentEvent（core/agent-session.ts:640-657）
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

- **会话单位**：`SessionManager` 构造时生成 `uuidv7` 会话 id（`session-manager.ts:208-210`）；文件名为 `<ISO时间戳(冒号与句点替换为连字符)>_<id>.jsonl`（`session-manager.ts:952-953`，`timestamp.replace(/[:.]/g, "-")`）。文件首行是 `SessionHeader { type, version(当前3), id, timestamp, cwd, parentSession? }`（`session-manager.ts:32-39`）。
- **条目类型**：`SessionEntry` 联合 `message/thinking_level_change/model_change/compaction/branch_summary/custom/custom_message/label/session_info`（`session-manager.ts:144-153`）。其中 `custom` 是扩展状态存储（不参与 LLM 上下文），`custom_message` 参与上下文并控制 TUI 显示（`session-manager.ts:94-141`）。
- **消息结构**：`AgentMessage` 由 `packages/agent/src/types.ts` 定义；assistant 消息复用 `AssistantMessage`（`packages/ai/src/types.ts:415-430`），含 `content` 块数组、`usage`、`stopReason`、`errorMessage`、`deferred` 句柄。工具结果以 `ToolResultMessage`（role=toolResult，`types.ts:437-454`）独立成消息。
- **版本迁移**：v1→v2 生成 id/parentId 树，v2→v3 把 `hookMessage` 角色改名为 `custom`（`session-manager.ts:230-291`）；读文件时若版本落后则迁移并重写文件（`session-manager.ts:917-919`）。

## 2. 事实源、索引与持久化

- 事实源：文件系统中的 `.jsonl` 文件；无数据库、无独立索引文件。
- 落盘时机：`_persist`（`session-manager.ts:1015-1042`）：没有 assistant 消息时只缓存；第一条 assistant 消息到达时整文件写出（`flushed=true`），此后逐条 append。这保证了"没有模型回复的会话不产生文件"。
- 恢复：`loadEntriesFromFile` 全量读入内存（`session-manager.ts:514-556`，1MB 缓冲流式解析）。
- 列表索引：`SessionManager.list(cwd)`/`listAll()`（`session-manager.ts:1638-1713`）扫描 `sessions/` 下各 cwd 目录的 `.jsonl`，`buildSessionInfo` 流式读文件提取 id/cwd/name/messageCount/firstMessage/allMessagesText，并发上限 10（`session-manager.ts:771-809`），按修改时间倒序。`--session-dir` 自定义目录时按 header.cwd 过滤（`session-manager.ts:1641-1646`）。

## 3. 创建、切换、归档、删除与恢复

- **新建/继续/恢复**：`SessionManager.create/open/continueRecent/inMemory`（`session-manager.ts:1519-1570`）。`AgentSessionRuntime.newSession/switchSession` 先 `teardownCurrent`（abort 当前响应 → 发 `session_shutdown` 扩展事件 → dispose）再创建新 runtime（`core/agent-session-runtime.ts:167-260`）。
- **命名**：`appendSessionInfo(name)` 记录 `session_info` 条目，空字符串清除名字（`session-manager.ts:1136-1147`）；显示名取最新条目（`getSessionName`，`session-manager.ts:1150-1161`）。
- **删除/归档**：SessionManager 类无删除方法，但 UI 层存在持久化删除：`session-selector.ts:645` 的 `deleteSessionFile`（trash 优先、unlink 兜底，:832 挂到会话选择器删除处理），快捷键 Ctrl+D（`app.session.delete`）与 Ctrl+Backspace（`deleteSessionNoninvasive`，keybindings.ts:147-154、267-268）；`/clone` 是复制当前会话（slash-commands.ts:32），`/tree` 切换分支。删除入口的工作流见 Chat UI 笔记 §2。
- **恢复语义**：abort 后消息以 `stopReason: "aborted"` 持久化，下次 `/resume` 会恢复该消息（执行侧见对话请求与上下文笔记 §6；断网自动续传未找到）。

## 4. 编辑、重试、续写、回退与分支语义

- **分支**：`branch(branchFromId)` 移动 leaf 指针（`session-manager.ts:1360-1365`）；`createBranchedSession` 把"根到指定叶子"的路径抽成新文件并重链 label 条目（`session-manager.ts:1412-1512`）；`forkFrom` 跨目录复制整个会话到新 cwd 并记 `parentSession`（`session-manager.ts:1579-1630`）。`branchWithSummary` 追加 `branch_summary` 摘要条目（`session-manager.ts:1381-1405`）。
- **回退**：`resetLeaf` 把指针清空以便重发首条 user 消息（`session-manager.ts:1372-1374`）。
- **消息编辑**：本次未找到对已落盘消息的就地编辑 API；历史是追加型，修改以分支形式表达。
- **续写**：未找到"继续生成到当前消息末尾"的独立入口；续写通过分支/新消息实现。
- **重试执行**：重试如何选择起始上下文见对话请求与上下文笔记 §7；`/fork` 从指定 user 消息创建分支的入口见 Chat UI 笔记 §2。

## 5. 列表、分页、搜索与定位

- **会话列表**：`SessionManager.list/listAll` 全量扫描 + 并发上限 10（§2）；无分页游标。
- **搜索**：`session-selector-search.ts` 支持 token 模式（fuzzy/短语混合，`"node cve"` 引号）与 `re:` 正则模式，搜索文本是 `id + name + 全部消息文本 + cwd`（`session-selector-search.ts:26-57`）；`/resume` 会话选择器内嵌搜索框（入口见 Chat UI 笔记 §2）。
- **消息级搜索**：本次未找到（消息全文不建索引，列表页一次性扫描；另存 harness SDK 的 `createScanningSessionSearch`，位于 `packages/agent/src/search/`（scanning.ts + index.ts，2026-08 从 `harness/session/search.ts` 迁出）——可对可读存储逐条目分页扫描，接口为异步迭代器 `search(text, options): AsyncIterable<Hit>`（`entryTypes`/`limit`/`signal`，`search/index.ts:13-31`），未接入 TUI/AgentSession 路径）。
- **定位/统计**：`/session` 显示统计（用户/助手/工具消息数、token、成本）；`/tree` 树形导航带 label 书签（`getTree`，`session-manager.ts:1310-1348`）。

## 6. 缓存、一致性、多窗口与并发写入

- 写入是单进程逐条 append；`_persist` 在"无 assistant 消息"阶段仅缓存（§2）。
- 多实例并发写同一会话文件的合并语义未调查（无锁/事务证据）。
- 单会话单 agent 循环（执行侧见对话请求与上下文笔记 §8），会话文件本身无并发写保护证据。

## 7. 迁移、导入导出与保留策略

- 版本迁移：读文件时落后版本自动迁移并重写（§1，`session-manager.ts:917-919`）。
- **导出**：`/export` 支持 HTML（`core/export-html/`，marked+highlight.js 静态页面）与 JSONL；HTML 导出的渲染细节见消息渲染器笔记 §7。
- **导入**：`/import` 复制 JSONL 到会话目录后恢复（`agent-session-runtime.ts:361-396`）；`/share` 以 GitHub secret gist 分享。
- 保留策略：压缩后旧条目仍在文件中但不再进上下文（执行侧见对话请求与上下文笔记 §3）；无自动清理/轮转策略的证据。
- **harness 侧（packages/agent）JSONL 增强**（coding-agent 的 `SessionManager` 未变）：会话列表改为只读各文件首行 header 提取元数据（`listJsonlSessionMetadata`，`harness/session/jsonl/repo.ts:65-87`）；会话 id 的重复检查限定在目标 cwd 目录内（`sessionIdExists(id, cwd)`，`repo.ts:226-234`，#6282221）；同进程同 cwd+id 的并发 create/fork 直接拒绝（`claimCreateDestination`，`repo.ts:174-191`，#9d090bc）；fork 改为"整文件临时文件 + 原子 rename 发布"（`publishFileAtomically`/`fork`，`harness/session/jsonl/storage.ts:33-57, 110-118`，torn-tail 截断同样走原子发布 :84-94，#a838c06）；会话名称可显式清除（`setName(undefined)`，`state.ts:19, 22-24`，#7bdb16c）。

## 8. Agent、模型、知识库与附件绑定

- **绑定层级**：模型与 thinking level 绑定在会话状态（`agent.state.model/thinkingLevel`），切换模型写入 `model_change` 条目；工具启用集在会话级（`setActiveToolsByName`，`agent-session.ts:928-943`），默认 `[read, bash, edit, write]`（`agent-session.ts:211-212`），`--tools`/设置可增删。
- **Agent 形态**：`Agent` 是单循环 runtime（`packages/agent/src/agent.ts`，仅导出 `Agent` 类，README 明确 "No sub-agents"），`AgentSession` 包一层事件/持久化/压缩。子 Agent：扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- **附件**：图片以 `ImageContent` 进 user 消息（剪贴板图片、`--image`、拖动/粘贴，`interactive-mode.ts` 相关入口）；`settings.images` 控制自动缩放与阻止发送（`settings-manager.ts:45-48`）。工具结果中的图片可回注为上下文图像（`normalizeToolResultImages`，`agent-session.ts:517-531`）。
- **外部能力**：skills（`/skill:name` 展开为 `<skill>` 块 + 进 system prompt 索引）、prompt 模板（`/template`）、扩展注入的 custom 消息、`before_agent_start` 系统提示改写均在此链路生效（`agent-session.ts:1159-1261`；注入语义见对话请求与上下文笔记 §9）。

## 9. 设计取舍与已确认边界

- **追加型树会话**：不覆盖历史，编辑以分支表达；代价是单个文件持续增长，恢复时全量读入内存（`loadEntriesFromFile`，`session-manager.ts:514-556`，1MB 缓冲流式解析）。
- **压缩是重写而非分页**：压缩后旧条目仍在文件中但不再进上下文，保留可回溯性（执行侧见对话请求与上下文笔记 §3）。
- **上下文边界明确**：`custom` 条目、`bashExecution(excludeFromContext)`、`custom_message(display=false)` 各自独立控制"是否进 LLM 上下文"与"是否可见"（执行侧见对话请求与上下文笔记 §2）。
- **"没有模型回复的会话不产生文件"**：落盘时机绑定 message_end（§2）。

## 10. 未验证事项

- 多实例并发写同一会话文件、文件损坏与恢复未验证（agent 侧 JSONL 已有 torn-tail 原子截断与同进程 create/fork 冲突拒绝，但均未运行验证）。
- 长会话列表扫描（一次性全量读取）的性能未运行基准（`buildSessionInfo` 并发上限 10）。
- 版本迁移的边界情况（中断迁移、损坏文件）未验证。
- 未运行交互会话；结论来自静态源码（与源笔记一致）。

## 11. 关键源码索引

- `packages/coding-agent/src/core/session-manager.ts`：`844-854`（树模型）、`1015-1042`（落盘时机）、`1638-1713`（列表扫描）、`1360-1412`（分支）、`1579-1630`（forkFrom）、`230-291`（版本迁移）、`514-556`（读取）
- `packages/coding-agent/src/core/agent-session.ts`：`640-657`（message_end 落盘）、`928-943`（工具集）、`1159-1261`（外部能力链路）
- `packages/coding-agent/src/core/agent-session-runtime.ts:167-260`（切换会话）
- `packages/coding-agent/src/modes/interactive/session-selector.ts:645`（deleteSessionFile）
- `packages/coding-agent/src/modes/interactive/session-selector-search.ts:26-57`（搜索）
- `packages/coding-agent/src/core/keybindings.ts:147-154`、`:267-268`（删除快捷键）
- `packages/agent/src/search/scanning.ts`、`search/index.ts`（createScanningSessionSearch，未接入 TUI/AgentSession）
