# Pi 会话与消息管理调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/coding-agent/src/core/session-manager.ts`、`packages/coding-agent/src/core/agent-session.ts`、`packages/durable/src/session/`、`packages/durable/src/storage/`、`apps/p2/plugins/`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码与版本差异，定向跟踪首条输入落盘、分支选择、context_edit 校验及模型投影；durable 存储与搜索采用文中来源范围，未运行交互会话
>
> 调查范围：会话/消息/分支数据模型、JSONL 文件持久化与版本迁移、生命周期与分支指针、列表扫描与搜索、会话级绑定；发送执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的会话是"JSONL 追加型树"，持久化事实源是每个会话一个 `.jsonl` 文件：

- 每个会话对应一个 `.jsonl` 文件，放在 `~/.pi/agent/sessions/` 下按 cwd 编码的目录里；文件内每条记录带 id 与 parentId，因而构成一棵树，当前停留位置由 leafId 指针标记，切换分支只移动这个指针，历史记录保持原样（`session-manager.ts:988`、`:1528`）。
- 落盘发生在 message_end：第一条 user 或 assistant 消息落盘时创建文件，只有启动设置时留在内存；首轮尚无回复也保留提示（[持久化判定](../../pi/packages/coding-agent/src/core/session-manager.ts#L1161-L1206)）。
- 消息是分块内容模型：user/assistant/toolResult 与 custom/bashExecution/compactionSummary/branchSummary 并存；assistant 内容是 `text/thinking/toolCall` 块数组。
- 原历史追加保留，分支内 context_edit 可替换或排除模型投影内容（§4）；会话删除由 UI 负责文件级 trash/unlink，SessionManager 本身无删除方法。
- 会话列表搜索是一次性扫描（fuzzy/正则），无消息级索引；消息级全文检索只存在于 p2 的搜索插件（SQLite FTS5）里，CLI/TUI 路径未接入。
- 仓库还有第二套会话栈 `packages/durable`：不可变 entry + commit 落存储、崩溃后可 `resume()`、存储后端可在 Memory/JSONL/SQLite/IndexedDB 间替换；p2 建在它之上，CLI/TUI 仍用 `SessionManager`。

## 系统边界与数据主链

```text
AgentSession.prompt() -> Agent -> agentLoop（执行链 -> 对话请求与上下文）
  -> AgentSession._handleAgentEvent（core/agent-session.ts:1123）
       user/assistant/toolResult 消息 -> sessionManager.appendMessage
  -> _persist（session-manager.ts:1173-1206）：
       只有设置、没有 user/assistant 消息 -> 仅缓存
       第一条 user 或 assistant 消息 -> 整文件写出（flushed=true）
       此后 -> 逐条 append
  -> SessionManager.list / listAll（列表扫描，并发上限 10）
  -> buildSessionContext（读取时沿 leaf 回溯，执行侧 -> 对话请求与上下文）
```

边界：上下文构建、压缩与流式事件链属于对话请求与上下文（`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`）；命令面板、选择器与状态行的用户工作流属于 Chat UI（`<../Chat UI/Pi-ChatUI调查笔记.md>`）；消息内容渲染属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 会话、消息与分支数据模型

- **会话单位**：`SessionManager` 构造时用 uuidv7 为每个会话生成 id，文件名、目录名和文件首行都由这个 id 与创建时的 cwd 派生（`session-manager.ts:264`）。
  - 文件名由创建时的 ISO 时间戳（冒号与句点换作连字符）、该 id 与 `.jsonl` 后缀拼成（`session-manager.ts:1081`）。
  - 会话目录按 cwd 编码：把路径中的斜杠、反斜杠与冒号换成连字符，首尾各留两个连字符；Windows 上的 `E:\works\GitStudyNotes\pi` 因此落到 `--E-works-GitStudyNotes-pi--`（`session-manager.ts:590`）。
  - 文件首行是版本 3 的 header，字段依次为类型、版本、id、时间戳、cwd 与可选的父会话（`session-manager.ts:43`）。
- **条目类型**：SessionEntry 涵盖对话、模型与思考设置、usage、压缩与分支摘要、扩展状态与消息、上下文编辑、书签与名称（[联合定义](../../pi/packages/coding-agent/src/core/session-manager.ts#L183-L194)），各类条目的分工如下：
  - custom：给扩展存放状态，不进入 LLM 上下文（`session-manager.ts:94-108` 注释）；
  - custom_message：进入上下文，同时决定 TUI 是否显示（`session-manager.ts:123-141`）；
  - context_edit：替换或排除当前分支里的模型投影内容，usage 记录用量；
  - label 是条目书签，session_info 存放会话显示名（`session-manager.ts:110-121`）。
- **消息结构**：`AgentMessage` 把内置消息与 coding-agent 自定义消息合成一个联合类型（`packages/agent/src/types.ts:374`），实际出现的消息分三类：
  - assistant 消息：`AssistantMessage` 携带 content 块数组（text、thinking、toolCall）以及 usage、stopReason、errorMessage 与 deferred 句柄（`packages/ai/src/types.ts:593`）；
  - 工具结果：`ToolResultMessage` 以 role=toolResult 独立成一条消息，记录 toolCallId、toolName 与 isError（`packages/ai/src/types.ts:648`）；
  - coding-agent 扩展角色：bashExecution（可带 excludeFromContext）、custom、branchSummary 与 compactionSummary（`core/messages.ts:30-80`）。
- **版本迁移**：读取会话文件时，版本落后的内容会自动迁移并整份重写（`session-manager.ts:343-344`），迁移分两步：
  - v1→v2：为条目生成 id 与 parentId 的树结构，并把压缩条目的 firstKeptEntryIndex 换成 firstKeptEntryId；
  - v2→v3：把 hookMessage 角色改名为 custom（迁移实现见 `session-manager.ts:287-341`）。

## 2. 事实源、索引与持久化

- 事实源：文件系统中的 `.jsonl` 文件；无数据库、无独立索引文件。
- 落盘以首条用户或助手消息为界：单纯启动、模型和思考设置留在内存；首条对话消息触发独占创建并写出已缓存条目，此后追加。写入失败会回滚该条目的内存索引与 leaf，防止后续指向未落盘父条目；操作系统断电耐久性和半写恢复另需运行验证（[实现](../../pi/packages/coding-agent/src/core/session-manager.ts#L1161-L1206)）。
- 恢复：`loadEntriesFromFile` 全量读入内存（`session-manager.ts:628`，1MB 缓冲流式解析，跳过坏行；首条必须是合法 header 否则视为空）。header 快速发现另有 4KB 缓冲、1MB 上限的有界扫描（`readSessionHeader`，`session-manager.ts:686`），发现逻辑出错仅返回 null 不影响其它会话（`readSessionHeaderForDiscovery`，:615-623）。
- 列表索引：`SessionManager.list(cwd)`/`listAll()`（`session-manager.ts:1916`/`:1937`）扫描 `sessions/` 下各 cwd 目录的 `.jsonl`，机制分几点：
  - 信息提取：`buildSessionInfo` 流式读文件提取 id/cwd/name/messageCount/firstMessage/allMessagesText/最后活动时间（`session-manager.ts:800`）；
  - 并发与排序：并发上限 10（`buildSessionInfosWithConcurrency`，`session-manager.ts:925`），按修改时间倒序；
  - cwd 过滤：`--session-dir` 自定义目录时按 header.cwd 过滤（`list` 的 `filterCwd`，`session-manager.ts:1916-1930`；`continueRecent` 同逻辑 `:1804`）；
  - 最近会话：`findMostRecentSession` 只读各文件首行 header 并按 mtime 排序（`session-manager.ts:750`）。

## 3. 创建、切换、归档、删除与恢复

- **新建/继续/恢复**：`SessionManager` 提供四个构造入口，分别用于新建空会话、打开指定会话、续接最近会话和建立纯内存会话（`session-manager.ts:1766-1825`）。运行时的新建与切换都先 teardown 收尾：中止当前响应、向扩展发出 `session_shutdown` 事件、释放旧实例，之后才创建新的 runtime（`core/agent-session-runtime.ts:167-260`）。
- **命名**：命名通过追加 session_info 条目完成，空字符串表示清除，读取时取最新一条作为显示名（`session-manager.ts:1315-1329`）。选择器内重命名入口见 Chat UI 笔记 §2。
- **删除/归档**：`SessionManager` 类没有删除方法，通读整个类也找不到删除入口（`session-manager.ts:988-2029`）；删除由 UI 在文件级完成，流程分三个环节：
  - 执行删除时优先走 trash，失败再 unlink，动作由会话选择器的删除处理触发（`components/session-selector.ts:645-680`）；
  - 入口是选择器内的 Ctrl+D 与 Ctrl+Backspace（`core/keybindings.ts:147-154`）；
  - 删除前先进入确认状态，当前活动会话不能删（`session-selector.ts:394-405`）。
  - 注意：durable 的 JSONL 存储本次未找到文件级删除接口（检查范围 `packages/durable/src/storage/jsonl/`），它与 coding-agent 是两套实现。
- **恢复语义**：中断后 assistant 消息以 `stopReason: "aborted"` 持久化（执行侧见对话请求与上下文笔记 §6），下次 `/resume` 恢复该消息；断网自动续传未找到。

## 4. 编辑、重试、续写、回退与分支语义

- **分支**：分支相关能力由 `session-manager.ts:1590-1826` 一带的四个方法承担：
  - branch：只移动内存里的 leaf 指针，下一次追加才把所选分支写成父链；单独导航后直接退出不会留下新 leaf；
  - createBranchedSession：把从根到指定叶子的路径抽成新文件，重链 label 条目并记录父会话；
  - forkFrom：跨目录复制整个会话到新 cwd 并记录父会话；
  - branchWithSummary：追加一条 branch_summary 摘要条目。
  - UI 层的分支切换入口是 navigateTree，切换时可以一并生成分支摘要（`agent-session.ts:4093`）。
- **回退**：`resetLeaf` 把指针清空以便重发首条 user 消息（`session-manager.ts:1602`）。
- **消息与上下文编辑分层**：原始历史继续追加；context_edit 记录对当前分支既有模型可见条目的替换或排除，投影时取最后一次编辑，原条目保留。null 排除该内容，带 content 的值替换其模型投影；目标必须在当前分支且具有可编辑内容（[追加校验](../../pi/packages/coding-agent/src/core/session-manager.ts#L1370-L1408)、[投影](../../pi/packages/coding-agent/src/core/session-manager.ts#L519-L570)）。
- **续写**：未找到"继续生成到当前消息末尾"的独立入口；续写通过分支/新消息实现。
- **重试执行**：重试如何选择起始上下文见对话请求与上下文笔记 §7；`/fork` 从指定 user 消息创建分支的入口见 Chat UI 笔记 §3。

## 5. 列表、分页、搜索与定位

- **会话列表**：列表由一次全量扫描产出，并发上限 10（§2），不提供分页游标。
- **搜索**：选择器的搜索支持 token 与 `re:` 正则两种模式，token 模式把模糊匹配和加引号短语混用，例如 `"node cve"`；参与匹配的文本是会话 id、名称、全部消息文本与 cwd 的拼接，查询解析见 `session-selector-search.ts:26-114`。`/resume` 的会话选择器内嵌了搜索框（入口见 Chat UI 笔记 §2）。
- **消息级搜索**：coding-agent 的 TUI 路径仍只有会话级扫描，本次未找到按消息建索引的实现。相关能力分两处：
  - durable 自带的是工具检索：`packages/durable/src/search.ts` 提供 BM25 排序，供 codemode 的 `searchTools()` 与 `tool_search` 工具使用；
  - p2 侧有消息级全文检索：search 插件在 SQLite 上建一张内容指向 messages 表的 FTS5 虚表 message_search，查询走 MATCH 并用 bm25 排序，用户输入先由 query 模块转成安全的 MATCH 表达式，供历史工具与页面使用（`apps/p2/plugins/search/db.ts:43-170`）。
- **定位/统计**：`/session` 显示统计（用户/助手/工具消息数、token、成本，`getSessionStats`，`agent-session.ts:4317`）；`/tree` 树形导航带 label 书签（`getTree`，`session-manager.ts:1540`）。

## 6. 缓存、一致性、多窗口与并发写入

- 写入由单进程逐条追加完成；只有设置、还没有 user 或 assistant 消息时，落盘逻辑只把条目留在内存缓存里（§2）。运行时以内存中的条目数组为准，文件是它的磁盘投影；压缩、分支重链这类读改写会整份重写文件（`session-manager.ts:1125`），全程不持有文件锁。
- 多实例并发写同一会话文件时的合并语义未调查：会话文件一侧没有锁或事务的证据，写入入口都没有 lockfile 调用（检查范围 `session-manager.ts`）。设置文件是例外，settings.json 的写入用 proper-lockfile 取同步锁，与会话文件互不相干（`settings-manager.ts:195-262`）。
- 单会话单 agent 循环（执行侧见对话请求与上下文笔记 §8），会话文件本身无并发写保护证据。
- **durable harness（packages/durable，p2 使用的另一套会话栈）**：会话是一段不可变 entry 的对话记录，外加对象拥有的命名文档；写入以 commit 为单位，先落存储再对外发布，进程中途死掉重开存储会接着跑（`packages/durable/README.md` 的 Persist and Resume）。存储后端可在内存、JSONL、SQLite 与 IndexedDB 之间替换，四者统一实现 `Storage` 接口，各后端入口都在 `packages/durable/src/storage/` 下（`types.ts:1331`）。
  - 会话身份：每个 conversation 有持久 UUIDv7，作为 `sessionId` 传给 pi-ai，用于 provider 的 prompt cache 与会话亲和；重开、重试、reset、压缩、换模型都不变，子会话与 fork 另取新 id。
  - 只读打开：另一个进程正在驱动同一会话时，可以 `readOnly: true` 打开，只做展示；任何写入、`resume()` 或会运行任务的调用都会以 `ReadOnlySession` 拒绝。
  - 与 coding-agent 的关系：两套实现互不引用，p2 的插件（agent、chat、sessions、search 等）建立在 durable 之上，而 `pi` CLI/TUI 仍走 `SessionManager`。

## 7. 迁移、导入导出与保留策略

- 版本迁移在读文件时触发，落后的版本会被自动迁移并重写（§1，`session-manager.ts:343-344`）。
- 一次性目录迁移：早期版本把会话文件误存到 `~/.pi/agent/*.jsonl`，迁移函数按 header 里记录的 cwd 把它们移进编码目录（`migrations.ts:84-131`，注释引用 issue #320）。
- **导出**：`/export` 支持两种格式。HTML 导出借助 vendor 进来的 marked、marked-cjk-friendly 与 highlight.js 生成静态页面（`core/export-html/index.ts:143-175`）；JSONL 导出把当前分支写成线性序列，parentId 一并重链（`agent-session.ts:4448`）。
- **导入**：`/import` 把 JSONL 复制进会话目录再恢复（`agent-session-runtime.ts:359`）；`/share` 先尝试上传到 Radius 组织 artifact，缺凭据时回退到 secret gist（`session-share.ts`、`gh gist create --public=false`）。
- 保留策略：压缩后旧条目仍在文件中但不再进上下文（执行侧见对话请求与上下文笔记 §3）；无自动清理/轮转策略的证据（检查范围：`session-manager.ts` 无删除/清理路径，配置项中未发现保留期限字段）。

## 8. Agent、模型、知识库与附件绑定

- **绑定层级**：模型与工具集都挂在会话状态上。
  - 模型与 thinking level：读取自 agent.state 的 model 与 thinkingLevel 字段，切换时向会话追加 model_change 或 thinking_level_change 条目（`session-manager.ts:1228-1254`）。
  - 工具启用集：由会话级的 setActiveToolsByName 设定，默认是 read、bash、edit、write 四项，可通过 `--tools` 或设置增删（`agent-session.ts:1562`、`:2600-2602`）。
- **Agent 形态**：`Agent` 是只允许一个活动运行的工具循环 runtime，并发由 activeRun 守卫限制（`packages/agent/src/agent.ts:224-365`）；`AgentSession` 在其外包一层事件、持久化与压缩。子 Agent 相关边界：
  - 根 `README.md:13-17` 明说跳过 sub-agents 这类特性，`packages/agent/README.md` 也未把它列为内置能力；
  - 子 Agent 目前由扩展自行实现（示例 `packages/coding-agent/examples/extensions/subagent/`），durable 文档把 subagents 与 abort 放在同一节讨论，但均非 `Agent` 内置能力；
  - 扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- **附件**：图片以 ImageContent 形式进入 user 消息，来源包括剪贴板、`--image` 参数与拖放或粘贴（入口见 Chat UI 笔记 §1）；settings.images 下的 autoResize 与 blockImages 分别控制自动缩放和阻止发送（`settings-manager.ts:46-49`、`:1161-1185`）。工具结果里的图片可以回注成上下文图像（`agent-session.ts:727`）。
- **外部能力**：skills、prompt 模板、扩展注入的 custom 消息与 before_agent_start 的系统提示改写都在这条链路上生效；其中 skills 由 `/skill:name` 展开成 skill 块并进入 system prompt 索引，prompt 模板由 `/template` 调用（`agent-session.ts:1159-1261`；注入语义见对话请求与上下文笔记 §9）。

## 9. 设计取舍与已确认边界

- **追加型树会话**：原始条目一直保留，分支切换与 context_edit 只改变当前的模型投影；代价是单个文件持续增长，恢复时要把整份文件读进内存（`session-manager.ts:628`）。
- **压缩是重写而非分页**：压缩后旧条目仍在文件中但不再进上下文，保留可回溯性（执行侧见对话请求与上下文笔记 §3）。
- **上下文边界明确**：custom 条目、带 excludeFromContext 的 bashExecution 与 display=false 的 custom_message 各自独立控制"是否进 LLM 上下文"与"是否可见"（执行侧见对话请求与上下文笔记 §2）。
- **首条用户输入即可落盘**：无对话的启动不留文件；首轮无助手回复时，用户提示仍可从文件恢复（§2）。
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
