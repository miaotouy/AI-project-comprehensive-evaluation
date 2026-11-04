# Pi 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：静态源码阅读与全文检索（grep/glob），覆盖 `packages/ai`、`packages/agent`、`packages/durable`、`packages/coding-agent`、`apps/p2` 及 `packages/tui` 使用侧；未运行任何命令或测试
>
> 调查范围：生成式输出的对象模型、流式协议、文件写入与 diff 机制、代码执行位置、TUI 展示、会话持久化与恢复、模型回流、生命周期与验证体系；明确排除 Chat 上下文装配、Agent 工具调度语义、消息渲染器的普通 Markdown 呈现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 同时保留稳定的 coding-agent 运行链和实验性 durable harness。稳定链的模型输出仍是 text、thinking、toolCall 三种结构化 part，文件产物仍以工作区路径为身份，因此其生成式输出等级仍为 **G2（声明式交互对象）**。实验链没有引入 Artifact、画布或浏览器脚本对象，而是把会话、分支、lane、operation、工具结果和终端状态做成可恢复的持久运行状态；它提高的是执行持续性和远端投影能力，不改变输出对象等级。

## 系统边界与完整主链路

边界：`packages/ai`（provider 归一化与流协议）、`packages/agent`（agent 运行时）、`packages/durable`（持久 harness 与会话存储抽象）、`packages/coding-agent`（编码代理 CLI/TUI + 会话管理器 + 文件工具）、`packages/tui`（差分渲染终端组件库）。输出落盘后由用户自己的 Git/编辑器管理，Pi 不内置文件版本系统；README.md:38-46 明确"没有内置权限系统"，默认以启动用户权限运行。

主链路（触发→生成→展示→交互→保存→重开）：

1. 用户输入：编辑器提交（interactive-mode.ts:3015-3024）→ `AgentSession.prompt()`（agent-session.ts:1116）→ `agent.prompt()`。
2. 生成：`streamAssistantResponse`（packages/agent/src/agent-loop.ts:281-372）消费 `AssistantMessageEvent` 流，逐事件更新 partial 消息并发出 `message_start/message_update/message_end`。
3. 展示：TUI 订阅事件（interactive-mode.ts:3068-3129），assistant 文本进 `AssistantMessageComponent`（Markdown 实时渲染），每个 `toolCall` 建 `ToolExecutionComponent`（tool-execution.ts:13），edit 工具执行前异步计算 diff 预览（edit.ts:377-386）。
4. 执行：agent-loop 执行工具（executeToolCalls，agent-loop.ts:411）；write/edit 直接写宿主文件系统，bash 在本机 spawn shell（bash.ts:88-150）。
5. 保存：`message_end` 时按角色写入会话（agent-session.ts:640-657 → sessionManager.appendMessage），JSONL append 持久化（session-manager.ts:1173）。
6. 重新打开：`SessionManager.open()`（session-manager.ts:1530）→ `buildSessionContext()` → `agent.state.messages = existingSession.messages`（sdk.ts:363-364），模型在完整时间线上继续。另有 `/export`（HTML/JSONL）、`/import`、`/fork`、`/tree` 分支导航。

## 1. 触发方式、输出协议与对象模型

**触发方式**：全部为文本/工具调用，无 artifact 类特殊标记。入口包括：普通用户消息、`@file` 展开、粘贴图片、`!`/`!!` bash 命令（interactive-mode.ts:3009-3023，且同时只允许一个 bash 运行 :3013-3017）、扩展命令与 `/` 斜杠命令、steer/followUp 队列（agent-session.ts:1379-1408）。

**输出协议**：typed part 流。消息 part 只有 `TextContent`、`ThinkingContent`、`ToolCall`（packages/ai/src/types.ts:338-368）；事件协议为 `AssistantMessageEvent`，事件类型集合为：

```text
start / text_start / text_delta / text_end / thinking_* / toolcall_start / toolcall_delta / toolcall_end / done / error
```

（types.ts:523-539）。本次全文检索（pattern：`artifact|canvas|notebook`）未在输出协议中发现 HTML/notebook/artifact 类型对象 part；`artifact` 仅出现在 evals 包的测试产物与 agent types.ts 的扩展示例注释中（types.ts:304）。

**半截流与容错**：`toolcall_delta` 携带原始 JSON 片段，`partialJson` 累积并即时 `parseStreamingJson`（packages/agent/src/proxy.ts:322-336）；输出 token 截断时所有未完成工具调用统一标记错误、提示模型重发（agent-loop.ts:381-406）。thinking 被安全过滤时保留 `thinkingSignature` 供多轮连续（types.ts:343-351）。

**对象模型**：模型输出没有独立对象生命周期。会话内可寻址单元是 session entry（消息、compaction、label 等，session-manager.ts:46-153），工具执行对象以 `toolCallId` 为键在 TUI 中存活于当前渲染回合。事实源关系：会话 JSONL 是"恢复事实源"，agent 内存 transcript 是"运行事实源"，文件系统是"产物事实源"，三者在 message_end/工具执行时同步，无单对象级合并冲突管理。

## 2. 增量生成、更新与最终化

- 文本/thinking：逐 token 注入（text_delta 追加到 part，proxy.ts:252-264），TUI 每次事件重渲染 Markdown（interactive-mode.ts:3148-3151）。
- 工具参数：逐片段累积 JSON 并即时解析（proxy.ts:322-336）；参数完成前 TUI 即展示（tool-execution.ts:158-162）；`toolcall_end` 现在携带最终完整 `ToolCall` 并 `Object.assign` 覆盖 partial 累积结果（proxy.ts:338-345）。
- 文件更新：无 diff/patch 应用层，工具直接改文件：
  - `write` 全文覆盖（core/tools/write.ts:194-226，自动建父目录）；
  - `edit` 精确文本替换（core/tools/edit.ts:308-362）：每处 oldText 必须唯一、不重叠，先全部匹配原文件再倒序应用（edit-diff.ts:304-366）；支持模糊匹配（Unicode 引号/破折号/空白归一化，edit-diff.ts:33-54,206-244）并保留未改动行的原始字节（131-172）。
  - 失败收口为异常→错误工具结果（未找到/重复/重叠/无变化均有专门错误文案，edit-diff.ts:257-293）。
- bash 输出：流式累积，截断后完整输出存临时文件（bash.ts:349-480；OutputAccumulator）。
- 最终化：`done`/`error` 事件后 `response.result()` 取最终消息（agent-loop.ts:346-371）；同一文件并发写经按 realpath 的 mutation queue 串行化（file-mutation-queue.ts:32-61）。

## 3. 投影表面与多视图关系

- 主表面：终端 TUI 单聊视图（消息内嵌）。工具调用/结果以 Box 卡片呈现（tool-execution.ts:66-76），bash 另有带边框组件（components/bash-execution.ts:21-65）。
- 无消息旁侧栏、无独立标签页/画布/桌面投影。
- 外部投影：JSON 事件流模式（`--mode json`，print-mode.ts:108-117）、RPC 模式（stdin/stdout JSONL，`modes/rpc/rpc-types.ts`）以及 p2 的 Chord 对象引用（Web/TUI 多投影，`apps/p2/src/hosts/`）。这些是"会话投影"而非"对象投影"。
- 同一对象的多个同步投影：文件产物只有一个真实来源（磁盘文件）；会话在内存与 JSONL 间为单写者同步，无多实例并发同步。

## 4. 表现类型、依赖与运行环境

- 静态：Markdown（含代码高亮）、mermaid 经 `grok-mermaid` 渲染为终端 ASCII 图（components/mermaid.ts:59-88，宽度超限或流式中模式关闭时回退原文）、终端图片（kitty/iTerm/六块，tool-execution.ts:330-353，kitty 下非 PNG 会转码）。
- 声明式组件：工具渲染器（`renderCall`/`renderResult`，extensions/types.ts）由宿主按 schema 渲染，不执行模型任意脚本——属 G2 层。
- 无 HTML/CSS/JS、Canvas/WebGL、语言解释器或完整项目运行环境；本次未在 `packages/coding-agent/src` 全文检索到 iframe/webview 代码。容器化仅为部署文档（packages/coding-agent/docs/containerization.md，README.md:42-46 的 Gondolin micro-VM、Docker、OpenShell 三种模式），非运行时内置能力。

## 5. 用户交互、事件与错误反馈

- 用户可操作项：展开/折叠工具输出（`app.tools.expand`，keybindings.ts:86）、切换 thinking 显示（ctrl+t）、复制消息（ctrl+x）、粘贴图片、外部编辑器编辑输入框（ctrl+g，external-editor.ts:13）、会话树导航/标记/重命名（tree-selector.ts）、fork/resume/new。
- 事件回传：AgentEvent → AgentSessionEvent 全链路订阅（packages/agent/src/types.ts:428-443，agent-session.ts:141-183）；工具可经 `onUpdate` 流式回传部分结果（bash 节流 100ms，bash.ts:377-390）。
- 错误反馈：错误工具结果着色、abort/timeout/exit code 状态行（bash-execution.ts:171-204）；assistant 消息的 error/aborted/length 提示（assistant-message.ts:177-195）。
- 交互状态重载后恢复：TUI 内的展开状态不持久化（推断：状态在组件实例字段内，重载后重建）；会话树的 label、分支在会话文件中持久化（session-manager.ts:1232-1253）。无运行验证，静态代码可确认状态存放位置。

## 6. 编辑、diff、版本与协作

- 模型↔文件：模型是唯一修改者；用户不能直接编辑模型输出对象，也不能接受/拒绝 diff。`edit` 工具在 TUI 中先显示"预览 diff"再在结果区显示最终 diff（edit.ts:363-431），但这是展示，不是审批流。
- diff 形态：`generateDiffString` 生成带行号的展示 diff（edit-diff.ts:380-503），`generateUnifiedPatch` 生成标准 unified patch 存入 `details.patch` 供外部使用（edit-diff.ts:369-374，edit.ts:359）。
- 版本：文件层面依赖用户自己的 Git（Pi 仅在 package-manager 与 footer 分支显示处调用 git，未发现对生成产物的 git 版本管理）；会话层面有分支树（branch()、resetLeaf()、createBranchedSession()，session-manager.ts:1360-1512）、fork 独立会话文件、compaction/branch_summary 条目。
- 协作：无 CRDT、无并发编辑、无多用户。`file-mutation-queue.ts:32-61` 只串行化同一进程内的同文件写入。

## 7. 能力桥、执行位置与权限范围

- 执行位置：文件写与命令执行均在宿主本机进程/本机 shell（bash.ts:103-126，spawn + detached + 进程树清理 killProcessTree）。无 iframe/worker/容器内嵌运行。远端执行仅以可插拔 `operations` 接口形式存在（write.ts:25-40、edit.ts:74-92、bash.ts:56-74，注释指明 SSH 等场景），默认实现均为本机。
- 权限：无逐操作授权。`README.md:88-96` 明确无内置权限系统；`trust-manager.ts` 仅是"项目目录级信任"（决定是否在某 cwd 启动，trust-manager.ts:66-94），不审批具体写文件/执行命令。能力桥为全权（进程权限即代理权限）。
- 会话信息桥：bash 工具默认注入 `PI_SESSION_ID/PI_SESSION_FILE/PI_PROVIDER/PI_MODEL/PI_REASONING_LEVEL` 环境变量（bash.ts:165-191）。

## 8. 持久化、恢复、分享与导出

- 存储格式：append-only JSONL 会话树（v3），首行 header（id/version/timestamp/cwd/parentSession），每条 entry 带 id/parentId/timestamp；追加写，首次 assistant 消息后整文件 flush（session-manager.ts:1173）。
- 损坏容忍与原子发布：
  - durable 的 JSONL 存储加载时对末行语法错误判定 torn tail，并通过"临时文件 + 原子 rename"发布有效前缀修复（`packages/durable/src/storage/jsonl/`）；
  - durable 的 fork 以整文件原子发布，避免把源文件整段读入内存；
  - coding-agent 侧为逐行容错解析与 v1→v3 迁移（session-manager.ts:287-341,628）。
- 恢复：`SessionManager.open`（session-manager.ts:1777）、`continueRecent`（:1804）、CLI 会话选择器（interactive-mode.ts:5107-5134）；模型/thinking level 从会话 entry 恢复（sdk.ts:188-231）。
- 分享导出：`/export`（HTML 或 JSONL 副本，interactive-mode.ts:5997-6013）、`/import`（agent-session-runtime.ts:361-396）、`/share`（先尝试 Radius 组织可见 artifact，无 Radius provider 或凭据时退回私密 gist，见第 12 节）。HTML 导出为自包含单文件（模板 + base64 会话数据，core/export-html/index.ts:143-175），内置工具按模板渲染、自定义工具预渲染（178-230）。
- 独立后端：durable 在 `packages/durable/src/storage/sqlite/` 提供 SQLite 实现，与 JSONL、Memory、IndexedDB 并列，分两部分：
  - 后端实现：node:sqlite 适配、schema 与 migration；
  - 消息级 FTS 搜索移到 p2 的搜索插件：`apps/p2/plugins/search/db.ts` 在 SQLite 上建 FTS5 虚表，`query.ts` 负责把关键词转成 MATCH 表达式。
  coding-agent 当前仍使用 JSONL 路径；durable 的 `src/search.ts` 是工具检索（BM25），不是消息检索。

## 9. 模型回流、对象感知与持续维护

- 全量回流：resume 时 `agent.state.messages = existingSession.messages`（sdk.ts:363-364），模型看到完整历史，后续回合继续在同一会话文件追加。
- 对象感知与定向修改：模型通过 `read/find/grep/ls` 工具查询工作区，通过 `edit/write` 按路径定向修改（工具描述要求 oldText 唯一，edit-diff.ts:268-277 强制唯一性）。对象身份=文件路径；绑定到后续回合的是"会话 + 文件路径"，没有 artifact ID 之类的稳定对象句柄。
- 摘要回流：compaction 后旧消息被 `<summary>` 用户消息替换（messages.ts:11-17,176-183）；分支切换时 branch_summary 注入（19-24,170-175）；bash 执行可用 `!!` 排除出上下文（148-161）。
- 扩展注入：`custom_message` entry 可带内容进上下文（session-manager.ts:135-141,1171-1189），`custom` entry 仅存扩展状态不进上下文（98-108）。

## 10. 生命周期、资源治理与性能

- 会话级清理：`dispose()` 触发全部 abort（retry/compaction/bash）+ 会话资源清理（agent-session.ts:839-856）；`cleanupSessionResources` 为注册制（packages/ai/src/session-resources.ts:5-23，唯一注册点是 Codex WebSocket 会话，openai-codex-responses.ts:927）。
- 进程治理：bash 子进程 detached 跟踪（trackDetachedChildPid）、超时 killProcessTree、信号退出时清理（print-mode.ts:50-68）；交互模式限制同时一个 bash 命令（interactive-mode.ts:3013-3017）。
- 内存与截断：bash 输出按行/字节双上限截断并落临时文件（truncate.ts）；read 工具同样截断（DEFAULT_MAX_LINES/MAX_BYTES）；TUI 预览按视觉行缓存截断（visual-truncate.ts）。
- 长会话：自动 compaction（阈值 + overflow 恢复）与手动 `/compact`（compaction.ts），Token 估算决定时机。deferred（异步续答）仅在 model-runtime 有 provider 守卫（model-runtime.ts:647-660），本次检索 `deferred` 在 coding-agent 仅命中该两处及配置字面量，未见使用路径。
- 性能手段：TUI 差分渲染、渲染器按 width 缓存（bash.ts:272-295）、事件节流（bash 100ms）。

## 11. 测试、已确认边界与未验证事项

**测试体系（存在，本调查未运行）**：packages/agent/test 覆盖 jsonl codec/storage、compaction、branch-summarization、agent-loop；packages/coding-agent/test 覆盖 session-manager（save-entry/migration/tree-traversal/build-context）、edit-tool（legacy-input/no-full-redraw）、export-html（xss/whitespace/skill-block）、external-editor、agent-session（bash-persistence/compaction/queue/retry/runtime）、RPC。流式最终一致性（torn tail）、保存恢复、diff 展示均有对应单测文件，但本调查未运行任何测试，结论全部基于静态代码。

**已确认边界（检索范围：`packages/coding-agent/src`、`packages/agent/src`、`packages/ai/src` 全文 grep `iframe|webview|sandbox|notebook|artifact|canvas|CRDT|undo|approval|permission` 等）**：

- 未找到：iframe/WebView/notebook/画布/桌面投影；模型输出对象级编辑与接受/拒绝；文件写入撤销（仅编辑器输入区有 undo）；逐操作权限审批。
- 沙箱/容器仅存在于部署文档，非内置运行时。
- 用户消息本体可被编辑的入口为外部编辑器（针对输入框），与会话内已生成消息无关。

**未验证事项**：TUI 视觉行为（diff 着色、展开/折叠、滚动）需运行验证；流式编辑预览在长文件/高并发下的表现未运行；HTML 导出的浏览器端渲染行为未运行；sqlite 后端与 coding-agent 的集成路径未运行（README 仅描述 agent-core 用法）。

## 12. 会话投影的分享元数据

`/share` 有主备两条路径（`packages/coding-agent/src/modes/interactive/session-share.ts:46-203`）：主路径把当前分支导出为 JSONL，追加一条 `pi.share` custom entry 保存当前 system prompt 与激活工具定义，再把该 JSONL 上传为 Radius 组织可见 artifact（`exportSessionForShare` :25-43、`tryShareViaRadius` :91-150）；只有在 Radius provider 不可用或取不到凭据时才退回 `gh gist create --public=false`（`shareViaGist` :152-203），而退回路径导出的是 HTML 而非 JSONL（`shareSession` :46-89）。一旦命中 provider 与凭据，上传失败只报错、不再退回 gist。因此分享物仍是会话投影而非带独立 ID 的输出对象，却比普通 JSONL/HTML 导出多出复现该回合环境所需的文本和工具 schema；命令帮助文案仍写作向私密 gist 分享（`core/slash-commands.ts:27`），未反映 Radius 优先的实现。

## 13. Durable harness 的运行状态投影

durable harness 把一次执行拆成“接纳提交”和“按阶段驱动”两层持久边界。提交（submission）先落存储再开始执行；每个 Task 的每个 phase 结束都存 checkpoint，进程重启后 `resume()` 从最后一个 checkpoint 继续，睡着的任务不占用调用。该机制保存 transcript、工具结算、重试与尚未完成的提交等运行状态，不是可由用户直接编辑的 Artifact（`packages/durable/README.md` 的提交、任务与恢复章节、`packages/durable/src/harness/`）。

p2 把 worker 持有的会话投影成页面与 TUI 可观察的 Chord 对象引用，Chord 负责跨进程的引用、增量更新与订阅；每个会话一个 worker，崩溃后重启并把失败保留到重试，插件重载时对象与文档仍存活。它形成同一会话的 Web/TUI 多投影，但仍没有独立输出对象、用户接受/拒绝 diff 或脚本沙箱（`apps/p2/src/hosts/session-workers.ts`、`packages/chord/README.md`、`apps/p2/docs/p2-notes.md`）。

## 14. 关键源码索引

- 输出协议与消息类型：`packages/ai/src/types.ts:338-368`（part）、`:523-539`（AssistantMessageEvent）、`:415-430`（AssistantMessage）
- provider 归一化入口：`packages/ai/src/api/anthropic-messages.ts:590-617`、`openai-responses-shared.ts:462-502`、`pi-messages.ts:211-237`
- 流事件装配与容错：`packages/agent/src/proxy.ts:252-350`、`agent-loop.ts:281-406`
- 文件工具：`packages/coding-agent/src/core/tools/write.ts:194-226`、`edit.ts:308-431`、`edit-diff.ts:206-366,380-503`、`file-mutation-queue.ts:32-61`
- 执行工具：`packages/coding-agent/src/core/tools/bash.ts:88-150,349-480`
- TUI 展示：`modes/interactive/interactive-mode.ts:3068-3283`、`components/tool-execution.ts:13-377`、`components/bash-execution.ts:21-220`、`components/diff.ts:79-147`、`components/mermaid.ts:59-88`
- 会话持久化与恢复：`packages/coding-agent/src/core/session-manager.ts:1173`（落盘）、`core/agent-session-runtime.ts:196-224`（切换会话）、`packages/durable/src/storage/jsonl/`（原子发布与 torn-tail 修复）、`packages/durable/src/session/session.ts`（commit）
- 回流：`packages/coding-agent/src/core/messages.ts:148-194`、`core/compaction/compaction.ts`
- 导出与外部投影：`core/export-html/index.ts:143-175`（自包含 HTML）、`modes/print-mode.ts`、`modes/rpc/rpc-types.ts`、`apps/p2/src/hosts/session-workers.ts`
- 会话存储抽象与可选后端：`packages/durable/src/session/session.ts`、`packages/durable/src/storage/`（jsonl/sqlite/memory/indexeddb）
