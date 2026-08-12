# OpenCode 生成式输出与运行时调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：源码静态调查，grep/glob 关键词交叉验证（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、snapshot、revert、pty、execution），并通读核心链路文件；未运行构建、测试或交互
>
> 调查范围：模型生成输出的对象模型与持久化、流式更新、文件 diff/快照版本、投影表面（app/TUI/CLI/desktop）、执行位置（shell/LSP/PTY）、revert 闭环、模型回流；明确排除：插件与 MCP 工具细节、消息渲染器的纯展示层、会话调度与代理角色、控制台/统计类投影
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的"生成式输出"以**真实文件系统为事实源**：模型通过结构化工具调用（write/edit/apply_patch）直接落盘文件，逐条工具调用成为带状态机的 ToolPart 写入 SQLite，回合边界用"影子 Git 仓库"（`Global.Path.data/snapshot/<project>/<hash>`）记录文件树快照哈希并生成 PatchPart。用户侧的投影分为三类：时间线内的工具卡片（含内嵌 diff）、"最近回合"审查面板（读用户消息 summary 中预计算的文件 diff）和 Git 工作区审查（vcs.diff）。撤销是**整条消息粒度**的文件回滚（revert），配合快照 diff 与恢复，无 CRDT 或选区级冲突解决。代码执行全部发生在本机进程（shell 子进程、LSP 服务器、node-pty 终端、WebSocket 重放），未找到任何隔离沙箱、Artifact 或 Notebook 运行时。模型回流通过持久化会话历史重载（tool part → tool result 消息）与 read/glob/grep 等文件读取工具完成，跨回合对象身份由稳定 PartID 与快照哈希绑定。能力等级：主体 **G4（可编辑工作区）**，并部分具备 G5 特征（真实文件作为跨会话活对象、模型可感知与定向修改），但缺少对象级托管、细粒度接受/拒绝与 CRDT；G0–G3 中的隔离可执行 Artifact 层未找到。

## 系统边界与完整主链路

本类目覆盖从"模型输出"到"活对象"的链路：工具参数 → 文件系统写入/快照 → Part 持久化 → SSE 事件投影 → diff 审查 → revert → 历史回流。Chat 类目接手消息调度、中止、重试与上下文装配；消息渲染器接手 Markdown/工具卡外观；Agent 工具类目接手工具注册与审批调度。交接点：本文只记录工具结果被物化为可操作对象的机制（ToolPart、PatchPart、快照、revert），工具执行内部的任务调度（task 子代理）不展开。

**主链路（触发 → 生成 → 展示 → 编辑 → 保存 → 重开）：**

1. 用户输入经 `SessionPrompt.prompt/loop` 进入 `SessionProcessor.create`（`packages/opencode/src/session/processor.ts:98`），在 LLM 流开始前先 `snapshot.track()` 预捕获文件树哈希（`processor.ts:102`）。
2. `LLM.stream`（`packages/opencode/src/session/llm.ts:357`）以 AI SDK `streamText` 为主运行时（`llm.ts:280`），工具执行由 SDK 在进程内调度；事件经 `LLMAISDK.toLLMEvents` 归一化为 LLMEvent 流（`llm.ts:372-378`）。
3. 处理器把事件落为数据库 Part：text-delta 追加文本、reasoning、tool（pending→running→completed/error）、step-start/step-finish（各带快照哈希）、patch（`processor.ts:424-484`）。
4. 文件工具（write/edit/apply_patch）先计算 diff 提交权限审批，再写文件、发文件系统事件、触 LSP 取诊断（`packages/opencode/src/tool/write.ts:53-101`）。
5. step-finish 时再 `snapshot.track()`，对比前后哈希，生成 PatchPart `{hash, files}`（`processor.ts:435-470`），并把回合 diff 预计算进用户消息 summary（`packages/opencode/src/session/summary.ts:102-127`）。
6. 服务端经 SSE `/event` 订阅（`packages/opencode/src/server/routes/instance/httpapi/groups/event.ts:14`）推送 PartUpdated/PartDelta/Diff 事件，app/TUI 各自投影（`packages/app/src/context/server-sdk.tsx:279`）。
7. 用户在 app 审查面板（git 工作区 / 最近回合）或 TUI diff 查看器查看 diff；点击"撤销消息"触发 `SessionRevert.revert`，按 PatchPart 从影子仓库 checkout 恢复文件（`packages/opencode/src/session/revert.ts:38-88`）。
8. 重新打开：会话/消息/Part 从 SQLite 重载（`packages/opencode/src/session/message-v2.ts:98-123`）；再次输入时 `filterCompactedEffect` 重载历史并 `toModelMessagesEffect` 转成模型消息回流（`packages/opencode/src/session/prompt.ts:1092`、`message-v2.ts:131-415`）。

**模型继续维护闭环（查询 → 读取 → 定向修改）：** 模型在同一回合内经工具结果回流直接获得新文件状态；跨回合则通过 `read/glob/grep` 读取（`packages/opencode/src/tool/read.ts:28-36` 等），配合 `edit` 的 oldString 定位（`packages/opencode/src/tool/edit.ts:682-737`）实现定向修改。此闭环基于静态代码确认，未运行验证。

## 1. 触发方式、输出协议与对象模型

- **触发方式**：模型输出不是自由文本解析，而是 **AI SDK 结构化工具调用**。工具参数 schema（Effect Schema / JSON Schema）经 `ToolRegistry.tools` 过滤组装后交给 `streamText`（`packages/opencode/src/tool/registry.ts:286-335`）。参数校验失败由 `InvalidArgumentsError` 以"请重写输入"消息回喂模型（`packages/opencode/src/tool/tool.ts:24-34`）；SDK 的 `experimental_repairToolCall` 兜底（`llm.ts:296-312`）。半截流：`tool-input-start/delta/end` 事件只保证 part 存在，最终参数在 `tool-call` 时一次性写入 `ToolStateRunning.input`（`processor.ts:331-351`）；`ToolStatePending.raw` 字段在已读代码中未见写入流式 JSON，即参数中间态不落盘（本次静态确认）。
- **对象模型（Part）**：统一 `Part` 联合类型（`packages/schema/src/v1/session.ts:357-383`），全部带稳定 `PartID`（`prt_` 前缀单调 ID，`session.ts:23-26`）。与生成式输出直接相关的类型：
  - `ToolPart`：`callID` + 四态状态机 `pending/running/completed/error`，completed 携带 `output/title/metadata/attachments`（`session.ts:259-325`）；metadata 中存 diff、诊断、截断标记等工具自报信息。
  - `StepStartPart/StepFinishPart`：各自携带回合前后快照哈希（`session.ts:233-257`）。
  - `SnapshotPart`、`PatchPart {hash, files}`：回合文件树版本与变更文件清单（`session.ts:87-100`）。
  - `FilePart`：模型产物附件（图片/PDF/文本），带 mime、url、source（`session.ts:171-179`）。
- **事实源**：三层。**文件系统**是模型产物的最终事实源（工具直接写盘，无中间 AST/对象层）；**SQLite**（`packages/core/src/session/sql.ts:22-99` 的 SessionTable/MessageTable/PartTable）是消息与 Part 的事实源；**影子 Git 仓库**（`Global.Path.data/snapshot/<projectID>/<Hash.fast(worktree)>`，`packages/opencode/src/snapshot/index.ts:66-73`）是文件版本事实源。三者不同步覆盖：Part 只保存 diff 文本与哈希，内容以影子仓库对象库为准；快照损坏或超期则 diff 为空（`summary.ts:98-99` 返回 `[]`）。
- **能力声明**：Part 无显式能力声明；能力经权限系统在工具执行时逐项授予（见第 7 节）。

## 2. 增量生成、更新与最终化

- **文本**：逐 token 追加并广播 `PartDelta`（`message.part.delta` 事件，`processor.ts:499-510`、`schema/v1/session.ts:632-641`），服务端持久化整段文本。
- **工具参数**：不逐 token 落盘，最终完整 JSON 一次性写入（见上节）。
- **文件修改**：三种粒度——`write` 全文覆盖（`write.ts:64`）、`edit` 按 oldString 定位替换（含 9 种 Replacer 容错策略与相似度锚点，`edit.ts:244-737`）、`apply_patch` 按 hunk 块应用（`apply_patch.ts:220-258`，底层 `packages/opencode/src/patch/index.ts:185-241` 解析 `*** Begin Patch` 标记与 add/update/delete/move hunk）。diff 均由 jsdiff `createTwoFilesPatch` 生成并 trim（`edit.ts:646-680`）。**更新粒度轴**：工具级目标选择器（oldString/文件路径）为主，无 AST 节点级 patch。
- **版本记录**：`snapshot.track()` 用影子 git `add → write-tree` 得到哈希（`snapshot/index.ts:318-347`）；`patch(hash)` 用 `git diff --cached --name-only` 出文件清单（`snapshot/index.ts:349-380`）；`diffFull(from,to)` 用 name-status/numstat + `cat-file --batch` 批量取内容生成全文件 diff（`snapshot/index.ts:546-759`）。
- **最终化与失败**：step-finish 收口（写完成快照、补 patch part、更新 usage 与 summary）；中断/异常走 `cleanup`（把未完成工具标 error + interrupted，`processor.ts:539-597`）与 `halt`（写 assistant 错误）。失败工具以 `ToolStateError.error` 文本回流模型（`message-v2.ts:325-348`）。

## 3. 投影表面与多视图关系

- **消息内**（app/desktop/console 共用 session-ui）：`PART_MAPPING` 按 part 类型注册组件（`packages/session-ui/src/components/message-part.tsx:250`、1534+）；`renderable()` 过滤隐藏工具与空文本（`message-part.tsx:711-720`）。edit/write/patch 工具卡以手风琴内嵌 diff（`message-part.tsx:2203-2259`、2261-2319、2321-2523），diff 来源是工具 metadata（`filediff`/`files`），经 `session-diff.ts:31-48` 的 `resolveFileDiff` 用 `@pierre/diffs` 解析渲染。
- **侧栏审查面板**（app）：`session.tsx:703-708` 三种模式——git 工作区（`api.vcs.diff`）、分支、最近回合（读 `lastUserMessage()?.summary?.diffs`，`session.tsx:652`）。`review-tab.tsx:47` 支持 unified/split、行注释、打开文件。
- **TUI**：`routes/session/index.tsx:1702-1782` 按工具类型渲染 Shell/Write/Edit/ApplyPatch 等卡片；独立 diff 查看器（`packages/tui/src/feature-plugins/system/diff-viewer.tsx:114-130`）支持 git/branch/last-turn 三源、split/unified、文件树与已审标记。
- **CLI 非交互**：`run.ts` 以原始事件流输出（step_start/step_finish/tool_use/text 等，`packages/opencode/src/cli/cmd/run.ts:717-784`）。
- **多视图同步**：同一 Part 经 SSE 事件广播到各端（`event-reducer.ts:312-318` 处理 `message.part.updated`）；patch/step-start/step-finish 三种 part 被各端 reducer **跳过不投影**（`packages/app/src/context/global-sync/event-reducer.ts:19-30`、`sync.tsx:7`），仅服务端用于版本与撤销。
- **三份 diff 并存**：工具卡 metadata diff（当次调用）、summary.diffs（回合边界、服务端快照计算）、vcs.diff（工作区实时）——是同一文件不同时点/来源的三份投影，各自独立生成，无统一对象。

## 4. 表现类型、依赖与运行环境

- **层级**：Markdown 渲染（含 worker 队列化流式渲染）、代码高亮、图片/PDF 附件（file part，图片有尺寸归一化，`processor.ts:391-411`）、行级 diff 视图。**未找到** HTML/JS 沙箱、Canvas/WebGL、语言解释器或 Notebook 运行时：在 `packages/**/*.ts` 中搜索 `artifact|canvas|notebook|webview` 仅命中桌面 webview 缩放、构建产物与代码生成器命名等无关匹配。
- **依赖提供**：无运行时依赖注入；产物运行即真实进程（见第 7 节）。

## 5. 用户交互、事件与错误反馈

- **运行状态回传**：shell 工具通过 `ctx.metadata` 流式回传输出预览与退出码（`packages/opencode/src/tool/shell.ts:475-529`），app 以 shell 子消息动画展示；超时/中止以 `<shell_metadata>` 注明（`shell.ts:561-584`）。
- **交互式对象**：`question` 工具向用户提问，答案格式化回流模型（`packages/opencode/src/tool/question.ts:24-40`），时间线以问答卡展示（`message-part.tsx:2577+`）；`todowrite` 生成只读复选框清单（`message-part.tsx:2525-2560`）。
- **权限交互**：工具 `ctx.ask` → Permission 服务 → 各端审批 UI → 回复；拒绝时 `PermissionV1.RejectedError` 标记并可选暂停回合（`processor.ts:200-202`）。
- **错误反馈**：工具错误卡（`tool-error-card.tsx`）、诊断条（LSP 错误随工具输出附回）、assistant 消息级错误。重载后交互状态：工具卡展开状态本地 UI 状态；Part 状态本身从数据库恢复。

## 6. 编辑、diff、版本与协作

- **用户编辑**：OpenCode 内部无文本编辑器写入；用户修改发生在外部编辑器/IDE，经 watcher 事件与 vcs.diff 呈现（`reviewDiffs` git 模式）。
- **版本**：快照仓库提供**回合级**版本（write-tree 哈希），非文件提交级；`revert` 以消息为粒度：收集目标之后全部 PatchPart，按各自 hash `git checkout <hash> -- <file>` 恢复（`snapshot/index.ts:408-524`），可 `unrevert` 还原，下一次 prompt 时 `cleanup` 删除被撤销消息/Part（`revert.ts:90-134`）。快照 1f94d8a 起目标消息与撤销范围改用 `findIndex`+`slice` 定位（`revert.ts:74-75`、:106-114），不再按 id 大小比较（导入消息 id 可能非单调）。app 有专门 revert dock（`packages/app/src/pages/session/composer/session-revert-dock.tsx`），TUI 在消息对话框内触发（`packages/tui/src/routes/session/dialog-message.tsx:27`）。
- **接受/拒绝**：仅整条消息级 revert；**未找到** hunk 级接受/拒绝、冲突解决、CRDT 或分支表达（`revert` 是唯一撤销机制；fork 属会话级）。

## 7. 能力桥、执行位置与权限范围

- **文件**：本机文件系统（FSUtil），路径越界由 `assertExternalDirectoryEffect` 拦截（`packages/opencode/src/tool/external-directory.ts`），写文件需 `permission: "edit"` 审批并附 diff 预览（`write.ts:54-62`）。
- **命令执行**：本机子进程，**无沙箱/容器/远端**。shell 工具用 tree-sitter（bash/PowerShell WASM）解析命令提取权限模式（`shell.ts:257-291、392-414`），spawn 本地 shell（`shell.ts:293-310`），超时/中止 kill（`shell.ts:533-558`）；输出超限截断落盘并提示路径（`shell.ts:568-584`、`packages/opencode/src/tool/truncate.ts:68-73`，默认 2000 行/50KB，`truncate.ts:15-16`）。
- **终端**：用户交互终端是独立于 shell 工具的 PTY——`node-pty`（`packages/core/src/pty/pty.node.ts:1`）进程跑在 opencode 服务器进程内，经 WebSocket `/pty/:id/connect` 连接，支持输出重放（cursor）与会话 ticket 鉴权（`packages/opencode/src/server/routes/instance/httpapi/handlers/pty.ts:163-272`）。
- **LSP**：本地 LSP 服务器子进程（typescript/rust 等，`packages/opencode/src/lsp/server.ts`），`touchFile` 后 `waitForDiagnostics`，诊断随工具输出回流模型（`lsp.ts:344-375`）；LSP 还供 app 的 hover/定义/符号检索（`lsp.ts:377-495`）。
- **网络/模型**：webfetch/websearch 工具；模型无自调用能力桥（task 子代理属 Agent 角色类目）。

## 8. 持久化、恢复、分享与导出

- **持久化**：消息/Part/Todo 存 SQLite（drizzle，`packages/core/src/session/sql.ts`）；文件版本存影子 git 仓库（数据目录内，跨进程会话持久，`snapshot/index.ts:71`）；截断输出存临时目录（7 天保留，清理按文件 mtime 判定，`truncate.ts:12、54-63`，d468201 由文件名时间戳改为 stat mtime）。
- **恢复**：`MessageV2.page/hydrate` 分页重载消息与 Part（`message-v2.ts:98-123、425-467`）；快照哈希落库后 diff/revert 可在重开后继续（依赖影子仓库对象存活，gc prune 7 天，`snapshot/index.ts:23、761-766`——静态推断，未实测跨重启）。
- **分享/导出**：会话 share URL；CLI export（含对快照/Part 的脱敏，`packages/opencode/src/cli/cmd/export.ts:131-186`）、import。
- **删除/迁移**：会话删除级联消息；快照目录清理由定时 gc 负责。

## 9. 模型回流、对象感知与持续维护

- **历史回流**：每回合 `filterCompactedEffect`（压缩感知的排序重载）→ `toModelMessagesEffect`（`message-v2.ts:131-415`）——completed/error 工具转 `tool-*` result 消息、reasoning 转思考块、错误文本转 errorText、中断工具补 `[Tool execution was interrupted]`；快照/step/patch Part 不进上下文。
- **对象感知**：模型不直接读 Part/快照，而是经 read/glob/grep 读文件（文件系统即对象本体）；`todowrite` 维护会话 todo 清单（`packages/opencode/src/tool/todo.ts:23-43`）；LSP 诊断随写文件回流。
- **身份绑定**：`callID` 保证工具调用-结果配对跨回合稳定（`message-v2.ts:318-322`）；快照哈希提供回合间文件版本连续性；无"对象清单"式查询协议——模型无法枚举会话产出的对象列表，只能读工作区文件。

## 10. 生命周期、资源治理与性能

- **资源释放**：shell 子进程超时/中止强杀（`shell.ts:548-558`）；LSP 客户端随 InstanceState 释放关闭（`lsp.ts:198-202`）；PTY 会话运行态管理（`handlers/pty.ts:64-67` 仅列 running）；影子仓库定时 gc（prune 7 天，`snapshot/index.ts:761-766`）；截断文件 7 天清理。
- **限额**：工具输出截断（`truncate.ts:15-16`）、`MAX_PROJECT_DIAGNOSTICS_FILES=5`（`write.ts:18`）、doom loop 检测（`processor.ts:356-380`）、压缩自动触发。不可见对象无冻结/暂停机制（本类目无长驻可视化对象）。

## 11. 测试、已确认边界与未验证事项

**测试（源码存在，本次未运行）：** `packages/opencode/test/patch/patch.test.ts`（parsePatch/maybeParseApplyPatch/applyPatch 及边界）；`packages/opencode/test/snapshot/snapshot.test.ts`（约 1200 行：track/patch/diff/revert、子目录、ignore 语义、非 Windows 专属用例）；`test/session/revert-compact.test.ts`、`test/session/snapshot-tool-race.test.ts`、`test/server/session-diff-missing-patch.test.ts`；`packages/core/test/patch.test.ts`、`test/tool-apply-patch.test.ts`；app 端 e2e 时间线 fixture 与 `session-ui` 的 apply-patch-file/session-diff 单元测试。

**已确认边界：**
- 无 artifact/canvas/notebook/iframe/WebView 隔离运行时（搜索范围：`packages/**/*.ts` 关键词 artifact|canvas|notebook|webview，仅桌面 webview 缩放等无关命中）；无 G2 式宿主 schema 渲染注册表（question/todo 是工具结果的 UI 投影）。
- 撤销粒度为整条消息；无 hunk 级接受/拒绝、冲突解决或 CRDT（搜索 `revert|patch` 于 `packages/opencode/src/session`、`packages/schema/src`，未找到相关机制）。
- 工具参数流式中间态不落盘（`ToolStatePending.raw` 未见写入点）。

**未验证事项（需运行确认）：** 主链与 revert 闭环的真实运行表现；跨进程重启后快照 diff/revert 的有效性（受 7 天 prune 影响）；TUI/app 各端视觉与键盘行为；desktop（Electron 外壳加载同一 web app，`packages/desktop/src/main/server.ts:57` 起本地服务器）与 WSL 场景下的投影差异；性能基准。

## 12. 关键源码索引

- `packages/opencode/src/session/processor.ts`：生成回合的 Part 落库、快照捕获、工具结果与最终化（102、424-484、499-510、539-597）
- `packages/opencode/src/session/llm.ts`：AI SDK 流与工具调度（280-353、357-381）
- `packages/opencode/src/session/message-v2.ts`：SQLite 重载与模型消息转换（98-123、131-415）
- `packages/opencode/src/session/prompt.ts`：回合主循环与历史回流（1081-1130）
- `packages/opencode/src/tool/{write,edit,apply_patch}.ts`：文件落盘、diff、LSP 诊断回流
- `packages/opencode/src/patch/index.ts`：apply_patch 协议解析与应用（185-241、514-561）
- `packages/opencode/src/snapshot/index.ts`：影子 git 快照/版本/恢复（66-73、318-380、408-524、546-759）
- `packages/opencode/src/session/{revert,summary}.ts`：撤销闭环与回合 diff 预计算
- `packages/schema/src/v1/session.ts`：Part/状态机对象模型（87-100、233-325、357-383）
- `packages/session-ui/src/components/message-part.tsx`、`session-diff.ts`：各端工具卡与 diff 渲染
- `packages/app/src/pages/session.tsx`、`review-tab.tsx`、`composer/session-revert-dock.tsx`：app 审查与撤销
- `packages/tui/src/routes/session/index.tsx`、`feature-plugins/system/diff-viewer.tsx`：TUI 投影
- `packages/opencode/src/server/routes/instance/httpapi/handlers/pty.ts`：终端能力桥
- `packages/opencode/src/tool/shell.ts`、`truncate.ts`：本机执行与输出截断
