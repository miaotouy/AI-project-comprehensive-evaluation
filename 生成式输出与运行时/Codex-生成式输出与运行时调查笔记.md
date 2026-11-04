# Codex 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：对 `codex-rs` 工作区做静态源码调查，沿工具调用、审批、沙箱、事件投影、rollout 持久化与恢复路径逐层核对；以 `apply_patch` 与 `unified_exec` 两条执行链为主线，交叉检索 `TurnItem`、`FileChange`、`PatchApply`、`rollout`、`sandbox`、`approval`、`inline-vis` 等关键词；未运行构建、测试或交互
>
> 调查范围：模型输出的对象模型与事件协议、文件补丁的解析/审批/落盘/diff 投影、命令执行与沙箱能力、会话回放与恢复、无头 exec 事件流、终端内 HTML 可视化产物；明确排除：模型路由与上下文装配、MCP 工具生态细节、消息渲染器的纯排版实现、多代理协作语义、桌面应用界面
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的生成式输出以**真实文件系统加事件流**为核心：模型产物没有独立的“富对象存储”，而是统一为带稳定 `id` 的 `TurnItem` 事件（19 个变体），文件改动通过自由文本 `apply_patch` 协议进入解析、安全评估、审批、落盘和 diff 记录，会话事实源是 rollout JSONL 中 `ResponseItem` 与 `EventMsg` 的混合日志。

三条主链覆盖了不同投影：交互式 TUI 消费 app-server 的 v2 通知，把补丁渲染成带回合计数的 diff 卡片；无头 `codex exec` 把同一通知流压平成 `ThreadEvent` JSONL；恢复会话时按最近一次压缩点重放 rollout 重建历史，再从完成态 item 重绘 transcript。

能力等级以 **G4（可编辑工作区）** 为主：模型与用户围绕同一批真实文件工作，具备补丁预览、逐次审批、按回合聚合的 diff 和完整事件留痕；但撤销只到“截断会话历史”，没有文件级回滚、hunk 级接受/拒绝、版本分支或 CRDT。另有一个窄口径的 **G3** 面：模型可输出 HTML 可视化指令，由 TUI 物化为本地 viewer 文件并在浏览器沙箱 iframe 中运行。不存在通用 Artifact/Notebook 运行时。

## 系统边界与完整主链路

本类目接手的位置是“工具参数或文本已声明要修改/生成内容”。上下文装配、发送与流式任务调度属于对话请求类目；工具注册、审批队列与执行器调度属于 Agent 工具类目；气泡与 Markdown 排版属于消息渲染器类目。本文只在“输出获得对象身份、执行环境或持久化语义”处展开。

**主链一：补丁从模型文本到可审阅文件改动。**

1. 模型以自由文本发出补丁，工具参数以 `ToolPayload::Custom` 承载整段 patch 文本（`codex-rs/core/src/tools/handlers/apply_patch.rs:305-337`），而不是 JSON 字段。
2. 处理器先解析补丁文法，再以当前环境的文件系统校验每个目标文件，得到带工作目录与逐文件变更的补丁动作对象（`prepare_patch_request`，同文件 `464-507`）。
3. 校验后的补丁再依据权限配置计算每个目标路径的可写性，把越界路径折算成“额外权限”请求，然后做安全评估，得出自动通过、询问或拒绝三种结论（`core/src/safety.rs:67-136`、`core/src/tools/handlers/apply_patch.rs:523-583`）。
4. 需要询问时，会话把 `ApplyPatchApprovalRequest` 事件发给客户端并挂起等待审批决定（`core/src/session/mod.rs:3354-3397`）；TUI 以审批浮层呈现，选项为“执行 / 本次会话内这些文件不再询问 / 拒绝并说明改法”（`tui/src/bottom_pane/approval_overlay.rs:1042-1059`）。
5. 执行由编排器统一负责“审批 → 选择沙箱 → 运行 → 沙箱拒绝时按策略重试”，补丁运行时最终把变更写入目标文件系统（`core/src/tools/orchestrator.rs:125`、`core/src/tools/runtimes/apply_patch.rs:172-262`）。
6. 执行前后各发一次 item 事件：开始时是状态为空的文件改动项，结束时带补丁应用状态与 `stdout/stderr`；同时把提交过的增量喂给回合 diff 跟踪器（`core/src/tools/events.rs:241-378`、`core/src/turn_diff_tracker.rs:92-120`）。
7. app-server 把该事件转成 v2 的 `item/started`、`item/completed` 通知（`app-server-protocol/src/protocol/event_mapping.rs:410-439`），TUI 据此生成 diff 卡片，完成态 item 再写入 rollout（`rollout/src/policy.rs:232-287`）。
8. 重开会话时，rollout 被重放成对话历史，UI 侧从完成态 `FileChange` item 重新画出同一张卡片（`tui/src/chatwidget/replay.rs:250-271`）。

**主链二：命令作为可持续交互的进程对象。**

`unified_exec` 把 shell 命令建成带 `process_id` 的 PTY 会话，输出按上限缓冲并分块回传；模型可在后续步骤用 `write_stdin` 向同一进程写入输入（`core/src/unified_exec/process_manager.rs:892-906`）。命令的开始、输出增量、结束分别映射为 `CommandExecutionItem` 的 started、output delta 与 completed 通知，退出码与聚合输出随完成事件落到 rollout。

**主链三：无头执行的事件流。**

无头 exec 命令是 app-server 的进程内客户端，把服务端通知逐条压平为顶层线程事件，以 JSONL 输出；事件覆盖线程与回合的开始/完成/失败、item 的开始/更新/完成，以及不可恢复错误（`exec/src/exec_events.rs:11-37`、`event_processor_with_jsonl_output.rs:424-624`）。无头模式不做交互审批：审批策略默认取“从不询问”，所有审批请求都以“exec 模式不支持”直接拒绝（`exec/src/lib.rs:595-598`、`2146-2193`）。

## 1. 触发方式、输出协议与对象模型

**触发面有两条。** 文件改动既可由专用补丁工具触发，也可由模型在 shell 里执行 `apply_patch` heredoc 被拦截后走同一实现：命令处理器在真正 spawn 前做补丁拦截，命中则改为原生补丁执行，而不再当普通 shell 命令跑（`core/src/tools/handlers/unified_exec/exec_command.rs:180`、`handlers/apply_patch.rs:423-476`）。这条兼容路径说明补丁不是“只认工具名”的私有通道。拦截实现已拆成“准备”与“执行”两段：准备阶段只解析并校验补丁、产出待执行请求，不启动任何命令进程，因此宿主可以把待审补丁直接交给自动复核（`handlers/apply_patch.rs:425-479`）。

**协议是行导向的自由文本。** 首行与末行分别是补丁开始与结束标记，中间按 hunk 声明新增、删除或更新文件；更新块用 `@@` 定位上下文，另有改名与“文件尾”两个可选标记（`codex-rs/apply-patch/src/parser.rs:37-45`）。多环境场景还有一个环境标识头，用于指定补丁落到哪个执行环境（`apply-patch/src/streaming_parser.rs:20`）。

这种设计的直接后果是：非法输入、半截输入和“看起来像补丁但不是”的输入都需要单独处理。解析失败会以“补丁校验失败”的文本回喂模型，属于可重试的模型错误；而 shell 解析阶段失败则退化为普通命令，不报补丁错误（`core/src/tools/handlers/apply_patch.rs:465-475`）。

**对象模型是扁平 item 列表，不是树。** 所有产出共用一个 `TurnItem` 枚举，覆盖消息、推理、计划、命令执行、文件改动、MCP 调用、网页搜索、图片查看与生成、扩展、上下文压缩等 19 类；各变体并列，首字段都是同一个稳定身份 `id`（`protocol/src/items.rs:50-82`）。完整变体清单见该枚举定义。

| 对象 | 身份来源 | 生命周期字段 | 事实源 |
|---|---|---|---|
| 助手消息 | Responses API item id | 流式 delta 与完成事件共用同一 `item_id` | rollout `ResponseItem` |
| 文件改动 | 工具 `call_id` | `PatchApplyStatus`：完成/失败/被拒 | 工作区文件 + rollout 完成态 item |
| 命令执行 | 工具 `call_id` 或 `process_id` | 进行中/完成/失败/被拒 | 进程实际退出状态 + 完成态 item |
| 图片生成 | item id | 状态字符串加已保存路径 | 保存到本地的图片文件 |
| HTML 可视化 | 指令里的相对文件名 | 无（一次性产物） | `CODEX_HOME` 下的 viewer 文件 |

`FileChange` 只有三种取值：新增（带全文）、删除（带旧全文）、更新（带 unified diff 与可选改名目标）（`protocol/src/protocol.rs:4541-4552`）。因此“变更”在这一层已经是可审阅的文本 diff，而不是待计算的编辑操作序列。

**能力声明不在对象上。** item 不带权限字段，权限在执行期由会话设置、权限配置、沙箱后端和审批缓存共同决定；对象只反映结果状态。

完成态 item 的 v2 通知另带一个可选的内容 token 数：助手消息完成时附上 `contentTokenCount`，缺失或为 null 都合法，item 结构本身不变（`app-server-protocol/src/protocol/event_mapping.rs:421-431`）。

## 2. 增量生成、更新与最终化

**文本是逐段追加。** 助手文本以带 `item_id` 的增量事件发出，客户端按该 id 追加到同一气泡（`core/src/session/turn.rs:2518-2525`）。同一段流里若出现“计划”标记，会被切成普通文本与计划两部分，计划走独立通道并生成独立 item，两者不混在一条消息里（`turn.rs:2482-2545`）。

**补丁有真正的半截流处理，但只到“已完成行”粒度。** 流式解析器按行推进状态机，凑齐一个 hunk 才产出；解析结果转成补丁更新事件，以 500ms 间隔节流，最后一个待发事件在结束时补发（`core/src/tools/handlers/apply_patch.rs:64`、`111-147`）。该能力受特性开关 `ApplyPatchStreamingEvents` 控制（同文件 `93-99`）。

这类中间事件不持久化：rollout 策略把它列为瞬时事件，只保留完成态的 item（`rollout/src/policy.rs:161-190`）。它在线上的名字是 `item/fileChange/patchUpdated`（`app-server-protocol/src/protocol/common.rs:2080`）。TUI 侧本次也未找到消费点——该通知落在聊天控件的忽略分支中（`tui/src/chatwidget/protocol.rs:384-426`）。因此“补丁流式预览”在协议层存在，在终端投影层未接入。

**最终化由执行结果决定，而不是由解析成功决定。** `ToolEmitter::finish` 把执行输出折算成三种收口：exit code 为 0 走成功并附增量；非 0 仍发完成态 item，但把格式化输出作为模型错误返回；沙箱拒绝另走一条带输出的失败路径（`core/src/tools/events.rs:392-473`）。

**部分提交也被显式考虑。** 补丁可能在写入若干文件后才因沙箱拒绝失败，运行时保留“已提交前缀”的增量，事件层在这种情形下复用“带输出的成功路径”让可见 item 失败而回合 diff 仍消费该前缀（`core/src/tools/runtimes/apply_patch.rs:204-232`、`core/src/tools/events.rs:421-436`）。这属于实现层对失败原子性的取舍：补丁应用不是全有或全无。

## 3. 投影表面与多视图关系

**消息内是唯一默认表面。** 补丁卡片由文件变更表生成：单文件时标题直接写“Added / Deleted / Edited + 路径 + 行数增减”，多文件时写文件数与总计；正文按文件展开 unified diff，带语法高亮与换行处理（`tui/src/diff_render.rs:442-520`、`tui/src/history_cell/patches.rs:14-86`）。

diff 的两种粒度并存：卡片正文是内容级 diff；卡片首行是“符号 + 行数”的统计级摘要。搜索索引和折叠预览使用前者截断后的版本（`diff_render.rs:383-390`）。

**没有独立的回合审查面板。** 服务端确实会发 `TurnDiffUpdated`，但 TUI 的处理只有日志与刷新状态栏，未渲染成面板（`tui/src/chatwidget/protocol_requests.rs:168-171`）。跨文件、跨工具的整回合视图因此只存在于事件与统计中，不构成用户可操作对象。

**审批浮层是同一份 diff 的第二投影。** 审批 RPC 只带 item 引用而不重复 diff，TUI 从线程事件缓存里回查该 item 的 `FileChange` 列表再构造审批视图（`tui/src/app/file_change_approvals.rs:1-30`）。这形成“transcript 卡片 + 审批浮层”两处同源投影，源都是同一个 item。

**完成态与进行态的显示约定不同。** 重放时 `InProgress` 的 `FileChange` 被直接跳过，只有 `Completed` 且变更为非空才补画 diff 卡片（`tui/src/chatwidget/replay.rs:250-271`、`405-409`）。也就是说历史里保留的是“编辑结果”，不是“编辑过程”。

**其它表面。** 无头 exec 输出 `FileChangeItem`（路径、变更类型、状态），不含 diff 正文（`exec/src/exec_events.rs:168-198`）；HTML 可视化在消息中只留下一个指向 `file://` viewer 的链接，实际内容交给浏览器（见第 10 节）。

## 4. 表现类型、依赖与运行环境

终端能直接表达的类型有限：Markdown、语法高亮代码块、unified diff、ASCII 图表。Codex 把 Mermaid 图在本地渲染成字符图后再进入消息，属于消息内的静态渲染，不产生可交互对象（`tui/src/markdown_render.rs:1155-1170`、`codex-rs/mermaid/src/lib.rs:54-63`）。

图片分两类。模型可通过 `view_image` 查看本地图片，也可生成图片并把结果保存到本地路径，item 中带 `saved_path` 与状态（`protocol/src/items.rs:407-417`）。在拥有 Kitty 图形或 Sixel 能力的终端里，全屏 transcript 会用原生图形协议显示像素预览，并为其预留布局行（`tui/src/transcript_image.rs:1-12`、`tui/src/pets/image_protocol.rs:28-40`）。同一套有界预览也服务输入框里的本地图片缩略图，解码时按 EXIF 方向纠正并同时限制编码字节与解码后分配（`transcript_image.rs:80-112`）。字符终端下这些图片退化为路径与元信息。

真正的“可执行产物”只有一条窄路径：模型在回答中写入一条内联可视化指令，指向本线程可视化目录里的 HTML 片段；TUI 把片段包进固定 viewer 模板、复制到 `CODEX_HOME` 的 viewer 目录，再把消息里的指令改写成指向该文件的链接（`tui/src/inline_visualization.rs:30-31`、`116-148`、`185-260`）。

这条路径的安全边界由三层约束叠加：片段大小上限 2 MiB，viewer 以只带脚本权限的 iframe 沙箱承载（不授予同源），CSP 禁止外部连接、表单与 object（`tui/src/inline_visualization/viewer.rs:20-22`、`78-95`）。运行发生在用户浏览器，不在 Codex 进程内。

## 5. 用户交互、事件与错误反馈

**审批是唯一的阻塞式交互。** 补丁审批、命令审批、权限授予和 MCP 征询共用同一个浮层与队列；新请求到达时若已有浮层，会入队而不是覆盖（`tui/src/bottom_pane/approval_overlay.rs:185-241`）。

审批缓存的粒度是“会话内相同键”。命令按环境与命令前缀做键，补丁按环境与路径做键，只有用户选择“本会话不再询问”才写入缓存，命中后直接返回已批准（`core/src/tools/sandboxing.rs:72-115`、`core/src/tools/approvals.rs:899-936`）。选择“拒绝并说明改法”会把拒绝原因回喂模型，模型据此改写补丁或命令。

**运行态反馈。** 命令执行期间输出以增量通知进入当前 item，TUI 把它追加到执行卡片；后台进程数量与运行状态另有底栏汇总（`tui/src/chatwidget/protocol.rs:182-190`）。

**错误分层。** 解析/校验失败、沙箱拒绝、用户拒绝、执行非零退出是四类不同结局：前两类以文本回喂模型重试，用户拒绝以“patch rejected by user”这类规范化短语回喂，非零退出把格式化输出作为错误内容返回（`core/src/tools/events.rs:398-470`）。沙箱拒绝还会被启发式识别并上报违规遥测，以便与普通失败区分（`core/src/tools/runtimes/apply_patch.rs:241-257`）。

## 6. 编辑、diff、版本与协作

**用户不直接编辑产物。** diff 卡片只读；要修改就继续对话，或在外部编辑器改文件。Codex 没有内嵌的补丁编辑器，也没有在卡片上接受/拒绝单个 hunk 的入口。

**版本只有一种：会话历史截断。** `ThreadRolledBack` 事件携带“回退多少回合”，历史投影据此丢弃末尾若干回合并记录被移除的 turn id（`app-server-protocol/src/protocol/thread_history.rs:1547-1571`）。代码中本次未找到任何 `git checkout`/`git restore` 形式的文件恢复路径（检索范围：core 与 tui 两个 crate 全量搜索相关命令字符串）。因此回退改变的是对话与展示，不改变工作区文件；这与“基于快照回滚文件”的实现属于不同机制。

**协作维度为空。** 没有 CRDT、没有多人并发编辑、没有分支式补丁表达；并发体现在多个线程/代理各自操作工作区，冲突由文件系统与后续补丁失败暴露。

## 7. 能力桥、执行位置与权限范围

执行位置全部在本机（或用户配置的远端执行器），没有浏览器内 JS 运行时供代码执行使用。命令与补丁都在宿主机上以子进程/文件操作完成，差异只在沙箱后端。

| 平台 | 沙箱标识 | 实现要点 |
|---|---|---|
| macOS | `MacosSeatbelt` | 生成 Seatbelt profile，用系统 `sandbox-exec` 包裹命令 |
| Linux | `LinuxSeccomp` | `codex-linux-sandbox` 入口，Landlock 文件规则 + seccomp + 可选 bubblewrap 与 PID 命名空间 |
| Windows | `WindowsRestrictedToken` / `WindowsMxc` | 受限令牌（可升级为 AppContainer 式）或 MXC 容器 |
| 其它 | `None` | 不做系统级隔离 |

沙箱类型由 `get_platform_sandbox` 按目标平台选择（`sandboxing/src/manager.rs:48-62`），枚举定义在 `protocol/src/sandbox.rs:27-35`。实际执行前会把“程序 + 参数”整体重写成沙箱启动器命令行（`manager.rs:375-476`）。

**权限模型是“文件系统策略 + 网络策略 + 审批”三件套。** 补丁路径越界会先被折算成对该路径父目录的额外写权限请求，再交给审批；沙箱不可用且策略禁止沙箱豁免时直接拒绝（`core/src/tools/handlers/apply_patch.rs:229-277`、`core/src/safety.rs:96-136`）。网络访问在受管模式下经本地代理与域名规则放行，与文件沙箱相互独立。

**能力桥的范围**：文件（读写受沙箱约束）、命令（PTY 子进程）、网络（代理）、MCP 工具（外部服务器）、图片（本地读取）。模型不能自行获得额外的宿主能力，除非通过审批扩大权限。

## 8. 持久化、恢复、分享与导出

**事实源是追加式 JSONL。** 每条记录由时间戳、可选序号与一个 rollout item 组成；item 分几类：会话元数据、模型响应、事件消息、压缩点、回合上下文、用量记录与世界状态（`history/src/lib.rs:226-249`）。写入由 `RolloutRecorder` 负责，先入内存队列，在 persist/flush 时落盘（`rollout/src/recorder.rs:1073-1103`）。

**哪些事件进日志有明确策略。** `TurnItem` 完成事件在分页历史模式下全量保留，但命令聚合输出超过 64 KiB 会截断并加标记；MCP 结果同样截断。瞬时事件（流式补丁更新、命令输出结束、错误、警告等）不写入，网络审批结算事件也归入瞬态（`rollout/src/policy.rs:17-52`、`128-190`、`200-206`、`231-286`）。

**恢复是重放而非反序列化对象。** 重放先选“最新且完整”的压缩点，只回放其后的记录，并向后扫描恢复回合上下文、世界状态基线与未完成回合 id（`core/src/session/rollout_reconstruction.rs:62-72`、`206-232`）。压缩点之前的对话以摘要形式存在，不能逐条展开。

**UI 重开走的是另一条路。** TUI 不直接读 JSONL，而是向 app-server 请求分页的线程 item（`tui/src/app_server_session.rs:1-22`），再把完成态 item 逐条重绘成 transcript；这也是为什么“历史里看不到流式过程”。

**分享与导出**：无头 exec 支持 `--output-last-message` 写出最终回答、`--output-schema` 约束结构化输出（`exec/src/cli.rs:58-80`）；会话本身以 rollout 文件形式存在，可作为线程被其他客户端列出、检索与恢复。

## 9. 模型回流、对象感知与持续维护

模型看不到 `TurnItem`，它看到的是由 `ResponseItem` 与工具输出转换来的对话消息。补丁成功后，模型从工具返回文本得知“哪些文件被改了”；下一回合要精确修改时，靠重新读取文件，而不是查询补丁对象。

跨回合的身份绑定依靠 `call_id` 与 `ResponseItem` id：工具调用与结果按 id 配对，助手消息的流式片段与完成态共用同一 `item_id`（`app-server-protocol/src/protocol/event_mapping.rs:371-380`、`core/src/session/mod.rs:2951-2966`）。

对象感知能力因此是“文件级”而非“对象级”：没有“列出本会话产出的补丁”“读取某个补丁的完整 diff”这类协议；模型可选择重新打开文件、重新执行命令来观察状态。

## 10. 生命周期、资源治理与性能

**进程与输出都有硬上限。** 统一执行同时最多保留 64 个进程，单流输出上限 1 MiB（约 10k token），单次让出时间在 250ms 到 30s 之间钳制，后台终端默认 5 分钟超时（`core/src/unified_exec/mod.rs:66-75`）。输出超限按头尾保留截断，并附原始 token 数提示（`core/src/unified_exec/output.rs:25-61`）。

**diff 计算有时间预算。** 回合 diff 跟踪器对单次渲染设 100ms 超时，超时后退化为粗粒度但仍内容精确的 diff，避免拖住工具完成（`core/src/turn_diff_tracker.rs:15-17`）。超过增量精度的补丁会直接标记跟踪器失效，不再提供回合 diff。

**HTML 可视化的资源治理**：片段 2 MiB 上限、viewer 目录禁止符号链接、同一片段内容未变化时复用已生成文件（`tui/src/inline_visualization.rs:144-148`、`tui/src/inline_visualization/viewer.rs:20-62`）。

## 11. 测试、已确认边界与未验证事项

**测试（源码存在，本次未运行）**：用例覆盖文法、增量解析、diff 跟踪、终端投影、事件压平与持久化筛选几层。

- `apply-patch` crate：parser、streaming_parser、file_update 单测，以及含流式事件断言的集成用例（`core/tests/suite/apply_patch_cli.rs:1732`）
- `core/src/turn_diff_tracker_tests.rs`：增量、失效与超时
- `tui/src/history_cell/patches_tests.rs`、`tui/src/diff_render` 快照：卡片与 diff 渲染
- `exec/src/event_processor_with_jsonl_output_tests.rs`：事件压平
- `rollout/src/policy_tests.rs`：持久化筛选

**已确认边界**

- 补丁不是全有或全无：可能部分提交后失败，且失败 item 仍会消耗已提交前缀。
- 撤销只有会话级截断，没有文件回滚；本次未找到工作区恢复路径。
- 无 hunk 级接受/拒绝、无补丁版本树、无协作冲突解决。
- 流式补丁差异已上线协议，但终端投影未消费。
- 通用 Artifact/Notebook/iframe 沙箱运行时不存在；唯一可执行 HTML 面是绑定线程目录的 inline visualization viewer，且只在浏览器中运行。

**未验证事项**

- 补丁流式事件在真实客户端中的表现（TUI 未消费，其它 app-server 客户端是否消费未验证）。
- Windows 受限令牌与 MXC 两条后端在真实机器上的隔离效果与降级行为。
- 部分提交后失败时，模型收到的文本与用户看到的卡片是否始终一致（依赖错误路径与格式化输出的组合）。
- 会话压缩点之后重放对 diff 卡片顺序的影响（静态看是逐条重绘，实际长会话未观测）。
- 图片在 Kitty/Sixel 终端的实际布局与滚动行为。

## 12. 关键源码索引

- `codex-rs/core/src/tools/handlers/apply_patch.rs`：补丁协议入口、流式差异、审批准备与执行收口
- `codex-rs/core/src/tools/runtimes/apply_patch.rs`：沙箱内实际落盘与增量收集
- `codex-rs/apply-patch/src/parser.rs`、`streaming_parser.rs`：补丁文法与增量解析
- `codex-rs/core/src/safety.rs`：补丁安全判定与拒绝原因
- `codex-rs/core/src/tools/orchestrator.rs`：审批、沙箱选择与重试
- `codex-rs/core/src/tools/events.rs`：item 开始/结束事件与状态映射
- `codex-rs/core/src/turn_diff_tracker.rs`：回合 diff 增量与预算
- `codex-rs/protocol/src/items.rs`、`protocol.rs`：TurnItem 与 FileChange 契约
- `codex-rs/app-server-protocol/src/protocol/event_mapping.rs`：旧事件到 v2 通知的投影
- `codex-rs/exec/src/exec_events.rs`、`event_processor_with_jsonl_output.rs`：无头事件流
- `codex-rs/rollout/src/policy.rs`、`recorder.rs`：持久化策略与写入
- `codex-rs/core/src/session/rollout_reconstruction.rs`：恢复重放
- `codex-rs/core/src/unified_exec/`：PTY 进程对象、输出上限与 stdin 交互
- `codex-rs/sandboxing/src/manager.rs`、`protocol/src/sandbox.rs`：沙箱后端选择
- `codex-rs/tui/src/diff_render.rs`、`history_cell/patches.rs`：终端 diff 投影
- `codex-rs/tui/src/inline_visualization.rs`、`inline_visualization/viewer.rs`：HTML 可视化产物
