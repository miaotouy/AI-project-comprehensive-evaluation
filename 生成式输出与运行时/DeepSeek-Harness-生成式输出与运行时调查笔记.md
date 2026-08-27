# DeepSeek-Harness 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`（分支：`master`）
>
> 调查方式：静态源码阅读与全文检索（grep/glob），覆盖 `packages/llm`（llm、llm-retry、token-meter）、`packages/core`（session、agent-loop、tools）、`packages/session`（session-persistence 及其 jsonl/sqlite 后端、session-checkpoint-policy、session-projection）、`packages/terminal`、`packages/shell`、`packages/subprocess`、`packages/spill`、`packages/attachment`、`packages/feedback`、`packages/util/output-retention`、`packages/client`（runtime 与 ui-conversation 消费侧）及 `docs/subsystems` 的 llm-streaming.md、tools.md、persistence.md 等页面；未运行任何命令或测试
>
> 调查范围：流式词汇与折叠、输出事件落盘与持久化、工具结果输出契约、终端/shell/附件/spill/消息反馈/令牌计量等输出形态、客户端流式消费概览；明确排除 Chat UI 的 DOM 渲染细节、工具管道的审批与调度语义、对话请求与上下文的装配细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 是插件化 agent harness，输出链路以"会话事件日志"为核心。模型输出没有独立 artifact 对象：原始形态是闭合的 `StreamChunk` 流协议（起止块、文本/推理/工具调用三类 delta、usage 与 finish 七个变体，`packages/llm/llm/src/types.ts:291-303`），adapter 契约要求 usage 先于 finish、工具参数端到端保持原始 JSON 字符串、失败归一化为可序列化的失败事实。

流式折叠由唯一的 `BlockAssembler` 承担（`packages/llm/llm/src/assembler.ts:36-164`）：agent 循环把每条原始 chunk 先落日志（`assistant/chunk` 事件）再喂给折叠器，流结束后把折叠出的不可变 assistant 消息连同 usage 一起追加为 assistant/message 事件，并以 sourceEventSeqs 引用组成它的全部 chunk 事件。

会话日志是唯一事实源，模型历史经表面折叠派生（`deriveMessages()`），因此日志同时支撑精确回放与请求可重建。

输出对象身份分四类：消息（稳定 `MessageId`）、工具调用/结果（`CallId` 配对）、磁盘文件（spill 文件、内容寻址附件）、运行实例（终端会话 `TerminalSessionId`，仅进程内存活，不进日志）。工具结果契约是"规范 JSON 值 + 纯投影渲染"：执行产生的 value 只在进程内存在，落盘的只有渲染后的内容、错误信息和展示 meta。

超长文本经两级处理：shell/subprocess 保留尾窗口并给出完整流 spill 文件路径；`spill-policy` 把超过 `maxInlineBytes` 的纯文本结果整体存为会话私有文件，模型只见 head/tail 预览加定位提示。持久化为 write-behind 批量 + `session/flush` 检查点，JSONL（默认 zstd 帧，chunk 运行打包压缩）或 SQLite 行存储两种后端，含 torn-tail 修复与 interrupted turn 平衡。

能力总评 **G1（富静态结果）**：文本/推理/图片与工具卡片在消息内投影，文件产物可寻址复用；终端 PTY 与后台 job 提供"模型可跨调用定向维护的活对象"（G5 的局部形态），但既不入日志也不持久化，进程终止即失。模型输出本身没有 G2 声明式控件、没有 G3 专用运行环境（本机 shell/PTY 执行属于工具执行边界）；用户不能编辑模型输出对象，无 diff 应用层与协作机制。

## 系统边界与完整主链路

边界按职责划分：

- `packages/llm/llm` 定义 provider 无关的流与消息词汇并归一化所有 adapter；
- `packages/core/session` 提供事件日志与表面派生，`packages/core/agent-loop` 是唯一循环消费者（驱动 turn/step、装配请求、执行工具），`packages/core/tools` 提供工具注册与结果契约；
- `packages/session/*` 负责持久化、检查点与投影；
- terminal/shell/subprocess/spill/attachment/feedback/token-meter 分别提供输出形态与治理；
- 客户端（`packages/client`）经 RPC/SSE 帧订阅 `session/event`，在对象层重建会话视图。

主链路（一次模型生成从 `llm/stream` 到 `assistant/chunk` 落日志再到最终 `assistant/message`）：

1. 输入：`inbox.splice` 插入用户消息并 `wakeDriver()`（agent.ts:113-120），驱动器 turn 流程追加 `turn/start`，preStep 认领消息并追加 `user/message`（surface 标记为 append，agent.ts:246-290）。
2. 装配：buildRequest 追加 `request/header`（EpochHeader 全量快照）与 `request/context`，经 `llm.prepareCall` 绑定 adapter 注册并冻结请求（agent.ts:407-495）。
3. 生成：循环 `for await` 消费 `llm/stream` 瀑布（adapter 抛出与迭代失败被归一化为终态 finish chunk，index.ts:843-927）；每条 chunk 先以 `assistant/chunk` 事件记录 seq，再喂给折叠器（agent.ts:347-351）。
4. 最终化：流结束后读折叠器的装配结果与 usage，以 createAssistantMessage 冻结消息并追加 `assistant/message`（携带 usage 与引用全部 chunk 的 `sourceEventSeqs`，agent.ts:373-390）；finish 为 error/aborted 时经 `agent/request-error` 瀑布决定重试或抛错（llm-retry 负责退避与可重试码）。
5. 工具执行：`tool/call` 记录原始参数 JSON（tool-calls.ts:262-265），调度器经 `tools/pre-execute → guards → tools/execute → tools/post-execute → finalizeContent` 后追加 `tool/result`（渲染内容 + 可选 error/meta，sourceEventSeqs 指向 call 事件，tool-calls.ts:268-289）。
6. 收口与持久化：`step/end`、`turn/end`（结构化原因）依序追加；`session/flush` 检查点把已提交事件批量写入后端（write-behind 默认 200ms 批窗）；resume 时后端 `prepare` 恢复日志并重建内存 Session。

## 1. 触发方式、输出协议与对象模型

**触发方式**：无 artifact 类特殊标记。输出全部由用户文本、注入上下文（`agent.inject`）与模型工具调用触发；模型侧唯一的"结构"入口是工具调用（原始 arguments JSON 字符串），文本与推理块没有受控语法。

**输出协议**：消息是一组 typed block，`ContentBlockMap` 可合并扩展，含文本、推理、图片、工具调用与工具结果五种（types.ts:99-110）。流协议是**闭合**判别联合（switch 以 `assertNever` 收尾，新变体必须改编译）；`index` 把各 delta 关联到块，`block-end` 携带已装配好的完整块，消费者不必自行拼接。协议容错点：delta-only provider（无块起止标记）被折叠器容忍；块已关闭后的迟到 delta 被忽略；半截工具参数以原始 JSON 片段累积，不做流式解析。

**对象模型**：`Message` 是唯一不可变消息表示（id、role、content、source，message.ts:128-138），跨送达/持久化/请求三种表示保持同一 id。assistant 消息的 source 记录 kind/model/provider 与 adapter 私有的 `replayState`（用于跨请求重放，仅同一 adapter 实例拥有历史 provider 与目标 provider 时透传，llm-streaming.md §Replay state）。source 的 kind 回答"谁产生"，可选 form 回答"这是什么信息"——六个语义值（如 snapshot 表示"后来快照覆盖先前快照"、notice 表示一次性告知）与视觉无关，完整词汇表见 message.ts:48-60。没有独立 artifact 类型；工具调用凭 `CallId` 在日志中与结果配对，文件产物凭路径寻址。

**事实源关系**：会话事件日志是对话事实源（`Session` 的 append-only log）；磁盘文件系统是产物事实源（spill、附件、工具写的文件）；终端会话是运行事实源（仅进程内）。三者在事件落盘时点同步，无对象级合并冲突管理。

## 2. 增量生成、更新与最终化

**折叠算法**：`BlockAssembler` 按 `index` 维护 partial 状态，text/reasoning delta 追加字符串、tool-call delta 追加 arguments 片段；`block-end` 的完整块是权威值且"先到先得"；`blocks()` 按首次出现顺序装配。usage 与 replayState 只在流末位生效，finish 缺省视为 stop。

**max-tokens 收口**：finish 为 max-tokens 时丢弃所有未完成的 tool-call 块（不可安全执行，assembler.ts:134-139），文本/推理块从已累积 delta 装配。

**更新粒度**：文本/推理为逐 token 注入；块边界用整块替换。没有对文本的 diff/patch 应用层。`assistant/message` 落盘后即最终化：消息被冻结、进入 surface、派生进下一次请求；compaction 是唯一的"改写"路径——以 `surfaceOp: {op:'replace'}` 的摘要 `user/message` 遮蔽旧表面节点（surface.ts:362-379）。

**失败收口**：adapter 抛出或迭代失败统一转为终态 finish chunk（`adapterFailureChunk`，index.ts:930-939）；finish error/aborted 进入 `agent/request-error` 瀑布，`llm-retry` 依据注册时捕获的不可变重试策略调度退避（可重试码、指数退避加抖动，llm-retry/src/index.ts:99+）。

放弃重试则回合以结构化失败事实记录 error 原因（agent.ts:309-314）；空完成（`EMPTY_RESPONSE`）与上下文溢出（`CONTEXT_WINDOW_EXCEEDED`）是规范化的可重试码。

**中止收口**：中止的回合为未启动的调用合成错误结果（`TOOL_ABORTED_BEFORE_DISPATCH`），保证回放时调用/结果配对完整（tool-calls.ts:249-259）。

**结果预算**：每步请求的输出上限来自 `AgentOptions.maxTokens` 或 adapter 的 `defaultMaxTokens`（`prepareCall` 物化），finish 为 max-tokens 时回合结果被 sticky 标记为 max-tokens（agent.ts:391）。

只有 usage 的空内容 assistant/message 依然落盘，但被 `deriveEventMessage` 跳过，不进派生历史（surface.ts:99-105）。

**工具结果契约**：工具声明 `output`（JSON Schema + 纯投影 `render(args, value) → ContentBlock[]` + 可选 `presentationMeta`，tools.md §ToolDefinition）。执行结果分成功（value + 内容）与失败（错误 + 内容），value 仅执行本地，持久化只保留渲染内容、错误信息与展示 meta（tool/code-dispatch 只存渲染内容）。

`finalizeContent` 是最后一道同步内容边界，注册时快照、每次结果物化前恰好调用一次（如 tool-terminal 用它把结果钳制在 256KiB 内）。工具卡片的展示意图（generic/terminal/diff/search/read/web 六种）由 `presentCall`/`presentResult` 以纯函数方式声明，UI 桥按 schema 投影，不做模型任意脚本渲染。

## 3. 投影表面与多视图关系

主投影是会话日志本身：`Session.surface` 是消息产生事件的线性序列（append 或 replace），`deriveMessages()` 增量折叠出模型历史（index.ts:726-747）。Web 客户端不读后端数据库，而是经连接帧订阅 `session/event`，以 `session/subscribed.lastSeq` 为基线做差距检测（runtime/sessions/session.ts:469-479）。

客户端的对象层 `PartialAccumulator` 把 `assistant/chunk` 逐块折叠成 `AssistantBlock[]`（partial.ts:22），ui-conversation 的 conversation-node 以相同折叠维护流式状态并消费 usage 与首 token 计时（assistant.ts:80-132）。工具结果在消息内以卡片投影（terminal/diff/search/read/web 卡）；bash 前台调用的退出标记在结果渲染阶段被解析成卡片的 exit pill（tool-bash/render.ts:124-136）。

终端会话与后台 job 是宿主侧对象：终端有独立面板与增量读取，但**不进会话日志**，模型只通过工具结果文本中的会话 id 感知它们。同一对象的多视图：一条 assistant 消息同时在日志（权威）、派生历史（请求输入）、客户端折叠状态（展示）三处存在，以事件 seq 对齐；spill 文件同时存在于磁盘与模型提示中的定位行。

## 4. 表现类型、依赖与运行环境

**表现层级**：text/reasoning 由客户端 Markdown 渲染（含代码高亮），image 块引用内容寻址附件；没有为模型输出提供 HTML/JS、Canvas 或脚本运行环境（本次全文检索未在输出协议中发现 artifact/canvas/notebook 类对象）。`packages/code-runtime` 与 e2b 属于 `run_code` 工具的执行环境，是工具边界而非输出运行时，本次未深入。

**终端输出**：`TerminalSendResult` 携带本次发送的渲染 viewport、四种等待原因之一、会话状态与 truncated 标志（terminal/types.ts:82-91）；backend 用字节+行双上限的 `BoundedTextBuffer` 保留尾窗口（terminal-bash/session.ts:40-75），scrollback 按页读取并带行窗口与截断标记。

tool-terminal 的六个工具（open/send/read/signal/close/list）用内容收口回调把单次结果钳制在 256KiB 默认上限内；后台发送转交 `ctx.jobs` 的 `pty-send` job，并带 `outputLimitBytes` 输出上限。

**shell 输出**：`CollectedOutput` = 内存尾窗口文本 + truncated 标志 + 完整流 spill 文件路径（subprocess/types.ts:22-29）；捕获模式 `SubprocessCollect` 提供整流 spill 文件（默认 bash 形态）或仅诊断尾（LSP 形态）。bash 结果渲染为"stdout + [stderr] 段 + 退出/超时/沙箱标记行"，截断时附完整输出定位行（tool-bash/render.ts:12-63）；非零退出是报告而非错误结果——只有基础设施失败才以错误结果呈现。

**附件**：`ImageBlock` 携带内容寻址的 `ImageAttachmentRef`（sha256 附件 id、媒体类型、字节数与宽高，attachment/types.ts:11-24）；本地后端在 `DSH_HOME/attachments/v1` 下按内容寻址落盘（0600/0700、目录 fsync、防 symlink 种植，store.ts:136-150），读回时校验字节与引用一致。当前生产 adapter 声明 text-only 输出，图片仅出现在用户消息侧。

**spill 长文本溢出**：`SpillStore` 服务定义只承诺 `saveText`——存全文、返回定位符与检索提示，具体后端 `spill-local` 落在会话私有目录的 0600 文件里（spill/src/index.ts:45-56）。

溢出策略在 `spill-policy` 插件：`tools/post-execute` 把超过 `maxInlineBytes` 的纯文本结果替换为"head/tail 预览 + 省略字节数 + 全文定位行"，并预留提示行字节预算保证替换品不超上限（spill-policy/src/index.ts:94-231）。嵌套调用跳过模型侧手臂（避免 read→spill→read 循环），其持久化日志副本改由 `tools/code-dispatch-log` 瀑布钳制；无会话/无后端/存储失败一律 best-effort 保留原文。

## 5. 用户交互、事件与错误反馈

用户可操作项：消息反馈（正/负评分 + 可选 note）、沙箱升级审批（bash `sandbox_permissions` + justification）、终端信号与关闭、后台 job 取消与增量读取、会话级命令（compaction/retry 等，属命令子系统）。

反馈经 `message-feedback` 服务以 sidecar 域存储：每条 assistant 消息一个 item（按 messageId 键、version 乐观并发、以会话创建时间与 cwd 隔离生命周期），写入前先对目标日志前缀执行 `session/flush` 屏障（message-feedback/src/index.ts:205-263, 328-339）——反馈永不改动日志本身，且只接受"最终化且 append 起源"的 assistant 消息。

错误反馈回传：错误工具结果带结构化错误码，回合以结构化原因收口，客户端以独立节点渲染 turn-error/turn-max-tokens。交互状态重载后恢复：终端/作业为运行时态，重启不恢复；消息展开/折叠等视觉状态属 Chat UI 范围，未验证。

## 6. 编辑、diff、版本与协作

模型是输出的唯一写者；用户不能编辑消息或工具结果，没有接受/拒绝/撤销流程。文件工具的 diff 属于工具执行边界（fs 工具把结果时 diff 放进 tool/result 的 meta 供卡片重放）。版本与协作：会话日志无迁移承诺（`SESSION_FORMAT_VERSION = 0`，只增事件类型靠 `ignorable` 标记兼容）；compaction 以表面替换表达"历史改写"，但没有对象级版本/分支（会话 fork 属会话管理类目）。反馈以版本冲突表达并发（失败码 `version-conflict` 带回当前项），不是日志内协作。

## 7. 能力桥、执行位置与权限范围

模型输出的"执行位置"分三类：文本/图片在客户端宿主渲染（无脚本执行）；工具结果的内容由宿主按声明式卡片投影（无任意代码）；bash/pwsh 在本机或沙箱进程执行（沙箱执行属工具边界，本次未验证）。终端 PTY 在后端本地进程（terminal-bash 基于 subprocess 终端原语），信号仅限固定的五个成员（如 SIGINT、SIGTERM、SIGKILL，完整集合见 terminal/types.ts:36）且只对前台进程组。

权限授予在工具层（pre-execute/approval/sandbox 策略，属工具语义，不展开）；spill 与附件存储以 0600/0700 私有文件 + 不可预测文件名保证其他本地用户不可读；bash 工具向子进程注入托管 `DSH_*` 环境事实。模型输出本身没有请求宿主能力的能力桥（无 artifact 级网络/存储授权）。

## 8. 持久化、恢复、分享与导出

**写入路径**：`session/event` 同步通知，持久化插件把事件克隆进每会话 write-behind 队列（固定 200ms 批窗；`session/flush` 取消等待并排空到静止，失败保留事件并暂停自动重试，write-behind.ts:22-159）。

`session-checkpoint-policy` 在三个边界建立持久性屏障：模型请求分发前（llm/stream 首块前 flush）、顶层工具体执行前、下一步骤请求前（checkpoint-policy/src/index.ts:63-83）。事件 append 时即做 lossless-JSON 校验与冻结，坏事件在源点拒绝。

**JSONL 后端**：每会话一个追加日志文件，默认 zstd 帧 + 校验和编码；`packChunks` 把连续同类 delta 运行打包为三个存储行类型之一（chunk-rows.ts:192-221，源码注释声称体积约 -60%），读取端无条件展开；原子发布（临时文件 + rename），torn-tail 截断修复。**SQLite 后端**：node:sqlite 同步 API，每事件一行（seq/type/time/data + surface 元数据列），SCHEMA_VERSION pragma 门控。

**崩溃恢复**：冷加载发现未闭合的 turn 时**不截断**，而是以合成的 `turn/end {kind:'interrupted'}` 关闭并补缺失工具错误（persistence.md §Crash recovery）；只丢弃物理 torn 的末记录。格式拒绝分两种错误类型（损坏 vs 本构建无法解释），未知必需事件不静默跳过。恢复路径：`agentLoop.resume` → 持久化 `prepare`（保留冷 Session 于有界 LRU 供复用）→ 原地校验冻结 → 发布为活 agent。分享/导出无独立能力（会话导出属会话管理，本次排除）。

## 9. 模型回流、对象感知与持续维护

回流为全量派生：每次请求前 `session.deriveMessages()` 从表面重建消息数组（agent.ts:341），所以模型总是看到与日志一致的历史；compaction 用摘要替换表面段后，下一次请求自动基于摘要继续。对象感知与定向维护：模型经 `read/grep` 定位 spill 文件（检索提示明确指示 read with offset/limit 或 grep）；经终端工具按会话 id 定向发送/读取/关闭；token-meter 的上下文压力投影（provider 采样 + 表面启发式差价）与用量累计（`tokenUsage` 不相交桶，usage 先于消息落账、同步覆盖去重）为下一回合提供资源视野（usage-projection.ts:107-206）。

对象身份绑定：消息 id、CallId、文件路径、终端会话 id 各自在后续回合延续；没有跨回合的 artifact 句柄。反馈 sidecar 按 messageId 关联且可被服务端/客户端查询，但不进模型上下文。

## 10. 生命周期、资源治理与性能

turn/step 事件括号定义回合生命周期，abort 以合成工具结果收口并保持日志配对完整；回合结束原因是可合并扩展的六值联合（completed/aborted/error/max-tokens 等，types.ts:155-177）。资源治理：终端会话按 owner agent 隔离，`terminal_close` 幂等关闭进程树，服务 dispose 时统一排空；后台 job 有输出上限与取消；write-behind 在 dispose 做最终排空。

输出预算贯穿全链：请求层 maxTokens、工具结果层（保留器、spill 上限、finalizeContent）、子进程层（内存尾 + 整流 spill 上限）、终端层（viewport/scrollback 双上限）。性能手段：`TextRetainer` 只保留前缀与单块尾窗（大流不累积内存）、chunk 运行打包、表面派生增量缓存、客户端按动画帧批量通知与节流视觉更新。会话级不可见对象无冻结/卸载机制——终端/作业持续占用直至关闭或进程退出。

## 11. 设计取舍与已确认边界

代码执行输出现可由 Python provider 承接：运行时协议把控制消息与程序标准输出分开传输，执行结果仍回到既有工具结果和会话事件模型，并未引入可独立编辑、版本化的代码 artifact。图像附件也保持为消息内容的一部分，附件服务负责内容寻址与规范化，LLM adapter 只在请求构建时解析它们（`packages/code-runtime/code-runtime-python/src/protocol.ts`、`packages/attachment/attachment-local/src/{store,normalization}.ts`）。

- **日志即事实源**：连原始 token 级 chunk 都落日志，换取精确回放与"请求可从日志重建"的强不变量；代价是存储体积，用 zstd + chunk 打包缓解。usage 附着在 assistant/message 上而不是单独记录，保证计量与消息同生同灭。
- **流协议闭合、词汇可合并**：StreamChunk 用闭合联合强制消费者处理新变体；ContentBlock 与 MessageSource 用可合并映射允许插件扩展。新 block 类型要求 adapter、UI、compaction、重放全链路支持（llm-streaming.md §Content blocks）。
- **工具结果"值不落盘"**：canonical value 仅执行本地，持久化只留渲染内容——重放能重建展示，不能重建中间值；这是"日志可重建请求"不变量与工具内部状态解耦的边界。
- **spill/保留策略刻意分离**：spill-policy 只决定何时溢出，TextRetainer 只回答"留了什么丢了多少"，SpillStore 只负责存储——三个包按能力缝拆分，配置缺失时策略自动退化为 no-op。
- **终端与附件选择不同持续性**：附件内容寻址入日志引用（可跨会话复用、读回校验），终端会话则完全在日志外（模型靠结果文本中的 id 感知，进程重启即失）——两者同为"活对象"但持久性层级不同。
- **已确认边界（检索范围：`packages/core`、`packages/llm`、`packages/terminal`、`packages/shell`、`packages/spill`、`packages/attachment`、`packages/feedback` 的 src 与 docs/subsystems 对应页面）**：未找到 artifact/canvas/notebook 输出类型、模型输出专用运行环境、输出对象编辑/接受-拒绝/diff 应用层、CRDT 协作；反馈不写日志；max-tokens 时未完成工具调用被丢弃而非补全重发（重发由模型侧在后续回合自行处理，依据：assembler 的过滤行为）。

## 12. 测试体系、未验证事项

**测试体系（存在，本次未运行）**：仓库以 vitest 单测 + 每文件 100% 覆盖率门禁 + 真实 API e2e（需 DEEPSEEK_API_KEY）+ keyless 快照回放分层；持久化后端共享 `runPersistenceContract` 契约套件；GUI 三层测试（数据层、渲染机制、组件）由 `test:gui` 与浏览器快照回放覆盖。流式折叠（BlockAssembler 的 delta-only/max-tokens/迟到 delta）、chunk 打包往返、torn-tail 修复、interrupted turn 平衡均有对应单测文件；全部结论基于静态阅读，未运行任何测试。

**未验证事项**：任何运行时行为（流式渲染、PTY 交互与 inferred_idle 判定、zstd 压缩率、快照回放）；bash/pwsh 沙箱执行路径与 landlock 原生模块；`code-runtime`/e2b 的 run_code 执行环境；跨进程并发写同一会话（设计为单写者，未见多写者协议）；"~60% 日志体积缩减/约 56 倍 envelope 开销"等数字来自代码注释声称的真实会话测量，未实测；客户端 DOM 层视觉与节流行为。

## 13. 关键源码索引

- 流协议与消息类型：`packages/llm/llm/src/types.ts:291-303`（StreamChunk）、`:99-110`（ContentBlockMap）、`message.ts:128-138`（Message）、`assembler.ts:36-164`（BlockAssembler）
- 运行时流入口：`packages/llm/llm/src/index.ts:843-927`（adapterStream/stream）、`:930-939`（adapterFailureChunk）、`packages/llm/llm-retry/src/index.ts:99+`（重试策略执行）
- 循环消费与事件落盘：`packages/core/agent-loop/src/agent.ts:332-401`（step：chunk→assembler→assistant/message）、`:407-495`（buildRequest/header）、`tool-calls.ts:249-289`（tool/call、tool/result 落盘与合成结果）
- 会话日志与表面：`packages/core/session/src/types.ts:236-333`（SessionEventMap）、`index.ts:604-655`（append）、`surface.ts:83-114`（deriveEventMessage）、`index.ts:726-747`（deriveMessages）
- 工具结果契约：`packages/core/tools/src/presentation.ts`（卡片意图）、docs/subsystems/tools.md §ToolDefinition/执行管道
- 终端与 shell 输出：`packages/terminal/terminal/src/types.ts:82-91`、`terminal-bash/src/session.ts:40-75`、`tool-terminal/src/index.ts:152-155`（finalizeContent 上限）、`packages/shell/tool-bash/src/render.ts:12-63`、`packages/subprocess/subprocess/src/types.ts:22-52`（CollectedOutput/SubprocessCollect）
- spill/附件/保留器：`packages/spill/spill-policy/src/index.ts:94-231`、`spill-local/src/index.ts:37-63`、`packages/util/output-retention/src/index.ts:146-387`、`packages/attachment/attachment-local/src/store.ts:136-150`
- 持久化：`packages/session/session-persistence/src/write-behind.ts:22-159`、`session-persistence-jsonl/src/index.ts:121-180`、`core/session/src/chunk-rows.ts:192-221`、`session-persistence-sqlite/src/index.ts:99-150`、`session-checkpoint-policy/src/index.ts:63-83`
- 反馈与计量：`packages/feedback/message-feedback/src/index.ts:189-263`、`spec.ts:84-90`、`packages/llm/token-meter/src/usage-projection.ts:107-206`、`estimate.ts:26-49`
- 客户端消费：`packages/client/runtime/src/client/sessions/session.ts:469-479`（帧处理）、`partial.ts:22`（PartialAccumulator）、`packages/client/ui-conversation/src/client/conversation-nodes/assistant.ts:80-132`（updateChunk）
