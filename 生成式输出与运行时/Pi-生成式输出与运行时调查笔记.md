# Pi 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码与版本差异，定向跟踪 codemode 内建装配、QuickJS worker、嵌套工具回注、会话投影及 durable 重放；其余输出机制采用文中来源范围，未运行应用、工具调用或测试
>
> 调查范围：生成式输出的对象模型、流式协议、文件写入与 diff 机制、代码执行位置、TUI 展示、会话持久化与恢复、模型回流、生命周期与验证体系；明确排除 Chat 上下文装配、Agent 工具调度语义、消息渲染器的普通 Markdown 呈现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 同时保留稳定的 coding-agent 运行链和实验性 durable harness。稳定链的模型输出仍是 text、thinking、toolCall 三种结构化 part，文件产物仍以工作区路径为身份，因此其生成式输出等级仍为 **G2（声明式交互对象）**。durable 使用 Conversation、Submission 与 Task 保存运行状态；coding-agent 另已接入可激活的 codemode QuickJS 脚本工具。工具脚本具有受控执行环境，聊天展示与路径文件仍维持 G2 对象分型，二者应分开比较（[内建装配](../../pi/packages/coding-agent/src/extensions/index.ts#L7-L14)）。

## 系统边界与完整主链路

边界：`packages/ai`（provider 归一化与流协议）、`packages/agent`（agent 运行时）、`packages/durable`（持久 harness 与会话存储抽象）、`packages/coding-agent`（编码代理 CLI/TUI + 会话管理器 + 文件工具）、`packages/tui`（差分渲染终端组件库）。输出落盘后由用户自己的 Git/编辑器管理，Pi 不内置文件版本系统；README.md:38-46 明确"没有内置权限系统"，默认以启动用户权限运行。

主链路（触发→生成→展示→交互→保存→重开）：

1. 用户输入：编辑器把输入交给 `AgentSession.prompt()`，再由它下传到 `agent.prompt()`（`interactive-mode.ts:3015-3024`、`agent-session.ts:1116`）。
2. 生成：agent 循环的 `streamAssistantResponse` 消费 `AssistantMessageEvent` 流，逐事件更新 partial 消息，并按开始、更新、结束三个阶段向外发出事件（`packages/agent/src/agent-loop.ts:281-372`）。
3. 展示：TUI 订阅事件流，assistant 文本进入 `AssistantMessageComponent` 做 Markdown 实时渲染，每个 `toolCall` 再建一个 `ToolExecutionComponent`；edit 工具在执行前还会异步算好 diff 预览（`interactive-mode.ts:3068-3129`、`tool-execution.ts:13`、`edit.ts:377-386`）。
4. 执行：agent-loop 通过 `executeToolCalls` 执行工具调用，write 与 edit 直接写宿主文件系统，bash 在本机启动 shell（`agent-loop.ts:411`、`bash.ts:88-150`）。
5. 保存：`message_end` 到达时按角色把消息写入会话，再由 session manager 追加到 JSONL（`agent-session.ts:640-657`、`session-manager.ts:1173`）。
6. 重新打开：`SessionManager.open()` 打开会话后，`buildSessionContext()` 重建上下文，再把既有消息整体赋给 `agent.state.messages`，模型据此在完整时间线上继续。另提供导出（`/export`）、导入（`/import`）、fork（`/fork`）与会话树导航（`/tree`）四项命令（`session-manager.ts:1530`、`sdk.ts:363-364`）。

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

- 文本与 thinking：模型每产生一个 token 就追加到对应的 part，TUI 收到事件后重渲染 Markdown（`proxy.ts:252-264`、`interactive-mode.ts:3148-3151`）。
- 工具参数：JSON 片段逐个累积并即时解析，参数还没补全时 TUI 就已经开始展示；结束时 `toolcall_end` 携带完整的 `ToolCall`，用 `Object.assign` 覆盖此前累积的部分结果（`proxy.ts:322-336,338-345`、`tool-execution.ts:158-162`）。
- 文件更新：没有 diff/patch 应用层，工具直接改写文件：
  - write 全文覆盖目标文件，父目录不存在时自动创建（`core/tools/write.ts:194-226`）。
  - edit 做精确文本替换：每处 oldText 必须唯一且互不重叠，工具先在整个原文件里匹配全部目标，再倒序应用；匹配支持 Unicode 引号、破折号与空白归一化的模糊形式，未改动的行保留原始字节（`core/tools/edit.ts:308-362`、`edit-diff.ts:33-54,131-172,206-244,304-366`）。
  - 失败统一收口为异常并转成错误工具结果，未找到、重复、重叠与无变化各有专门文案（`edit-diff.ts:257-293`）。
- bash 输出：流式累积，超过显示上限的部分被截断，完整输出另存临时文件，由输出累积器负责（`bash.ts:349-480`）。
- 最终化：`done` 或 `error` 事件到达后调用 `response.result()` 取最终消息；同一文件的并发写入经按 realpath 的变更队列串行化（`agent-loop.ts:346-371`、`file-mutation-queue.ts:32-61`）。

## 3. 投影表面与多视图关系

- 主表面：终端 TUI 单聊视图（消息内嵌）。工具调用/结果以 Box 卡片呈现（tool-execution.ts:66-76），bash 另有带边框组件（components/bash-execution.ts:21-65）。
- 无消息旁侧栏、无独立标签页/画布/桌面投影。
- 外部投影：JSON 事件流模式（`--mode json`，print-mode.ts:108-117）、RPC 模式（stdin/stdout JSONL，`modes/rpc/rpc-types.ts`）以及 p2 的 Chord 对象引用（Web/TUI 多投影，`apps/p2/src/hosts/`）。这些是"会话投影"而非"对象投影"。
- 同一对象的多个同步投影：文件产物只有一个真实来源（磁盘文件）；会话在内存与 JSONL 间为单写者同步，无多实例并发同步。

## 4. 表现类型、依赖与运行环境

- 静态：Markdown（含代码高亮）、mermaid 经 `grok-mermaid` 渲染为终端 ASCII 图（components/mermaid.ts:59-88，宽度超限或流式中模式关闭时回退原文）、终端图片（kitty/iTerm/六块，tool-execution.ts:330-353，kitty 下非 PNG 会转码）。
- 声明式组件：工具渲染器（`renderCall`/`renderResult`，extensions/types.ts）由宿主按 schema 渲染，不执行模型任意脚本——属 G2 层。
- TUI 消息内未接入浏览器 HTML/Canvas 运行表面。模型可用 codemode 在 QuickJS worker 中写异步 JavaScript，间接调用已授权工具；VM 无直接 Node、文件、网络或计时器 API，嵌套工具仍有其本地/远端执行权限。注册默认不激活，MCP 发现可按配置激活；VM heap 上限 256 MiB，每进程默认允许两个脚本 worker，候位至多 60 秒（[资源边界](../../pi/packages/coding-agent/src/extensions/codemode/execute.ts#L49-L69)）（[工具语义](../../pi/packages/coding-agent/src/extensions/codemode/tool.ts#L1-L21)、[实际执行](../../pi/packages/coding-agent/src/extensions/codemode/execute.ts#L519-L604)）。容器化仅为部署文档（packages/coding-agent/docs/containerization.md，README.md:42-46 的 Gondolin micro-VM、Docker、OpenShell 三种模式），非运行时内置能力。

## 5. 用户交互、事件与错误反馈

- 用户可操作项：工具输出可以展开或折叠（按键绑定 `app.tools.expand`），thinking 显示、消息复制与图片粘贴各有快捷键（ctrl+t、ctrl+x 与粘贴），输入框可交给外部编辑器（ctrl+g），会话树支持导航、标记和重命名，另有 fork、resume 与 new 三个会话入口（`keybindings.ts:86`、`external-editor.ts:13`、`tree-selector.ts`）。
- 事件回传：AgentEvent 到 AgentSessionEvent 之间有全链路订阅，工具还能通过 `onUpdate` 流式回传部分结果，bash 对此按 100ms 节流（`packages/agent/src/types.ts:428-443`、`agent-session.ts:141-183`、`bash.ts:377-390`）。
- 错误反馈：错误工具结果带颜色，abort、timeout 与退出码各有状态行；assistant 消息会按 error、aborted 或 length 给出提示（`bash-execution.ts:171-204`、`assistant-message.ts:177-195`）。
- 交互状态重载后恢复：TUI 的展开状态不持久化，推断其存放在组件实例字段里，重载后随组件重建；会话树的 label 与分支则写入会话文件（`session-manager.ts:1232-1253`）。该结论来自静态代码，未经运行验证。

## 6. 编辑、diff、版本与协作

- 模型与文件：模型是唯一修改者，用户无法直接编辑模型输出对象，也不能接受或拒绝一次 diff。`edit` 工具在 TUI 中先显示"预览 diff"，执行后在结果区显示最终 diff，两处都只承担展示，工具随后照常写盘（`edit.ts:363-431`）。
- diff 形态：`generateDiffString` 生成带行号的展示用 diff，`generateUnifiedPatch` 生成标准 unified patch 并存入 `details.patch` 供外部使用（`edit-diff.ts:369-374,380-503`、`edit.ts:359`）。
- 版本：文件版本依赖用户自己的 Git，Pi 只在 package-manager 与 footer 的分支显示处调用 git，未发现针对生成产物的版本管理。会话层面有分支树，可创建分支、重置叶子并生成分支会话，fork 会产出独立会话文件，compaction 与 branch_summary 则作为条目记录（`session-manager.ts:1360-1512`）。
- 协作：协作能力限于单机单进程，文件写入由变更队列串行化，CRDT、并发编辑与多用户机制均不存在（`file-mutation-queue.ts:32-61`）。

## 7. 能力桥、执行位置与权限范围

- 执行位置：文件写入与命令执行都发生在宿主本机，bash 通过 spawn 起子进程、以 detached 方式跟踪并做进程树清理。基础文件与命令工具不在 VM 内运行，codemode 的 QuickJS worker 是另一条独立的工具执行路径（§4 已述）。这些工具预留了可插拔的 `operations` 接口用于远端后端，注释举的是 SSH 场景，默认实现全部落在本机（`bash.ts:56-126`、`write.ts:25-40`、`edit.ts:74-92`）。
- 权限：没有逐操作授权，README 明确项目不内置权限系统；`trust-manager.ts` 只做"项目目录级信任"，决定是否在某个 cwd 启动，不审批具体的写文件或执行命令。能力桥拿到的是完整进程权限（`README.md:88-96`、`trust-manager.ts:66-94`）。
- 会话信息桥：bash 工具默认向子进程注入一组环境变量，供它识别当前会话与模型配置（`bash.ts:165-191`）：
  - PI_SESSION_ID 与 PI_SESSION_FILE 标识会话本身；
  - PI_PROVIDER、PI_MODEL 标识 provider 与模型；
  - PI_REASONING_LEVEL 标识推理等级。

## 8. 持久化、恢复、分享与导出

- 存储格式：会话以 append-only 的 JSONL 会话树保存到 v3 格式：首行 header 记录会话 id、版本、时间戳、cwd 与父会话，其后每条 entry 自带 id、parentId 与时间戳。写入方式为追加，首条 user 或 assistant 消息触发整文件 flush，之后只追加，纯启动设置留在内存（[实现](../../pi/packages/coding-agent/src/core/session-manager.ts#L1161-L1189)）。
- 损坏容忍与原子发布：
  - durable 的 JSONL 存储加载时把末行语法错误判为 torn tail，修复时先写临时文件、再以原子 rename 发布有效前缀（`packages/durable/src/storage/jsonl/`）。
  - durable 的 fork 以整文件原子发布，源文件不必整段读入内存。
  - coding-agent 侧按行容错解析，并提供 v1→v3 迁移（`session-manager.ts:287-341,628`）。
- 恢复：`SessionManager.open` 与 `continueRecent` 负责打开既有会话，CLI 会话选择器提供交互入口，模型与 thinking level 再从会话 entry 读回（`session-manager.ts:1777,1804`、`interactive-mode.ts:5107-5134`、`sdk.ts:188-231`）。
- 分享导出：导出、导入与分享各有一条命令。`/export` 负责导出 HTML 或 JSONL 副本，`/import` 读回外部会话，`/share` 先尝试把会话发布成 Radius 组织可见 artifact，在没有 Radius provider 或凭据时退回私密 gist（第 12 节）。HTML 导出是自包含单文件，模板内嵌 base64 会话数据，内置工具按模板渲染、自定义工具预渲染（`interactive-mode.ts:5997-6013`、`agent-session-runtime.ts:361-396`、`core/export-html/index.ts:143-175,178-230`）。
- 独立后端：durable 的 SQLite 实现与 JSONL、Memory、IndexedDB 并列，代码分两部分（`packages/durable/src/storage/sqlite/`）：
  - 后端实现：node:sqlite 适配、schema 与 migration。
  - 消息级 FTS 搜索由 p2 的搜索插件承担，它在 SQLite 上建 FTS5 虚表，并把关键词转成 MATCH 表达式（`apps/p2/plugins/search/db.ts`、`query.ts`）。
  coding-agent 当前仍走 JSONL 路径；消息检索落在上述 p2 插件，durable 自身的 `src/search.ts` 只做工具检索（BM25）。

## 9. 模型回流、对象感知与持续维护

- 当前投影回流：resume 时把既有会话消息整体赋给 `agent.state.messages`，模型看到的是按分支、压缩与 context_edit 计算出的当前投影，原始条目仍然保留，后续回合在其后继续追加（`sdk.ts:363-364`，[投影](../../pi/packages/coding-agent/src/core/session-manager.ts#L519-L570)）。
- 对象感知与定向修改：模型先用 read、grep、ls 等只读工具定位工作区里的目标，再用 edit 或 write 按路径修改；工具描述要求 oldText 唯一，edit-diff 层同样强制这一约束。对象身份落在文件路径上，后续回合绑定的是"会话 + 文件路径"，没有 artifact ID 这类稳定对象句柄（`edit-diff.ts:268-277`）。
- 摘要回流：compaction 之后旧消息被 `<summary>` 用户消息替换，分支切换时注入 branch_summary，用 `!!` 执行的 bash 命令可以排除出上下文（`messages.ts:11-24,148-183`）。
- 扩展注入：`custom_message` entry 会把内容带进上下文，`custom` entry 只保存扩展状态（`session-manager.ts:98-108,135-141,1171-1189`）。

## 10. 生命周期、资源治理与性能

- 会话级清理：`dispose()` 会 abort 掉所有进行中的 retry、compaction 与 bash 任务，并清理会话资源；资源清理走注册制，目前唯一的注册点是 Codex WebSocket 会话（`agent-session.ts:839-856`、`packages/ai/src/session-resources.ts:5-23`、`openai-codex-responses.ts:927`）。
- 进程治理：bash 子进程以 detached 方式跟踪，超时调用 killProcessTree 终止整棵进程树，收到退出信号时也会清理；交互模式同一时刻只允许运行一个 bash 命令（`print-mode.ts:50-68`、`interactive-mode.ts:3013-3017`）。
- 内存与截断：bash 输出按行数与字节数双上限截断，超出部分落到临时文件；read 工具用同样的上限截断，TUI 预览则按视觉行缓存截断（`truncate.ts`、`visual-truncate.ts`）。
- 长会话：compaction 分自动与手动两条路径，自动模式在阈值触发并支持 overflow 恢复，手动入口是 `/compact`，时机由 Token 估算决定。deferred（异步续答）只在 model-runtime 有 provider 守卫，coding-agent 侧本次检索仅命中这两处与配置字面量，未找到使用路径（`compaction.ts`、`model-runtime.ts:647-660`）。
- 性能手段：TUI 采用差分渲染，渲染器按 width 缓存，bash 输出事件按 100ms 节流（`bash.ts:272-295`）。

## 11. 测试、已确认边界与未验证事项

**测试体系（存在，本调查未运行）**：packages/agent/test 覆盖 jsonl codec/storage、compaction、branch-summarization、agent-loop；packages/coding-agent/test 覆盖 session-manager（save-entry/migration/tree-traversal/build-context）、edit-tool（legacy-input/no-full-redraw）、export-html（xss/whitespace/skill-block）、external-editor、agent-session（bash-persistence/compaction/queue/retry/runtime）、RPC。流式最终一致性（torn tail）、保存恢复、diff 展示均有对应单测文件，但本调查未运行任何测试，结论全部基于静态代码。

**已确认边界（检索范围：`packages/coding-agent/src`、`packages/agent/src`、`packages/ai/src` 全文 grep `iframe|webview|sandbox|notebook|artifact|canvas|CRDT|undo|approval|permission` 等）**：

- 未找到：iframe/WebView/notebook/画布/桌面投影；模型输出对象级编辑与接受/拒绝；文件写入撤销（仅编辑器输入区有 undo）；逐操作权限审批。
- 基础 shell/文件工具未内建操作系统隔离；codemode 有 QuickJS VM 与 worker 资源限制，嵌套工具仍使用各自执行权限。容器化部署的真实隔离效果未验证。
- 输入框可使用外部编辑器；会话中 context_edit 可以追加记录替换模型可见内容，保留原始消息，相关分支投影见会话笔记 §4。

**未验证事项**：TUI 视觉行为（diff 着色、展开/折叠、滚动）需运行验证；流式编辑预览在长文件/高并发下的表现未运行；HTML 导出的浏览器端渲染行为未运行；sqlite 后端与 coding-agent 的集成路径未运行（README 仅描述 agent-core 用法）。

## 12. 会话投影的分享元数据

`/share` 有主备两条路径，实现集中在 `packages/coding-agent/src/modes/interactive/session-share.ts:25-203`。主路径先把当前分支导出为 JSONL，再追加一条 `pi.share` custom entry 保存当前 system prompt 与激活工具定义，最后把该 JSONL 上传为 Radius 组织可见 artifact。只有 Radius provider 不可用或取不到凭据时，才退回 `gh gist create --public=false`，这条退回路径导出的是 HTML。一旦 provider 与凭据都能拿到，上传失败只报错，不再退回 gist。分享物因此仍是会话投影，没有独立 ID 这类对象身份，却比普通 JSONL/HTML 导出多出复现该回合环境所需的文本和工具 schema；命令帮助文案仍写作向私密 gist 分享（`core/slash-commands.ts:27`），未反映 Radius 优先的实现。

## 13. Durable harness 的运行状态投影

工具结果已提交时重开复用；执行 intent 已提交而结果未提交时，默认 unsafe 调用结算为可能已部分运行的 interrupted，只有旧 intent 与当前工具都声明 safe 才重跑。phase checkpoint 提供恢复位置，外部副作用仍须按重放策略判断（[ToolTask](../../pi/packages/durable/src/harness/tool.ts#L177-L227)）。

durable harness 把一次执行拆成“接纳提交”和“按阶段驱动”两层持久边界。提交（submission）先落存储再开始执行；每个 Task 的每个 phase 结束都存 checkpoint，进程重启后 `resume()` 从最后一个 checkpoint 继续，睡着的任务不占用调用。该机制保存 transcript、工具结算、重试与尚未完成的提交等运行状态，不是可由用户直接编辑的 Artifact（`packages/durable/README.md` 的提交、任务与恢复章节、`packages/durable/src/harness/`）。

p2 把 worker 持有的会话投影成页面与 TUI 可观察的 Chord 对象引用，Chord 负责跨进程的引用、增量更新与订阅；每个会话一个 worker，崩溃后重启并把失败保留到重试，插件重载时对象与文档仍存活。它形成同一会话的 Web/TUI 多投影；模型工具脚本的 QuickJS 沙箱属于 codemode 链，不能据聊天对象分型概括为全仓无脚本沙箱（`apps/p2/src/hosts/session-workers.ts`、`packages/chord/README.md`、`apps/p2/docs/p2-notes.md`）。

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
