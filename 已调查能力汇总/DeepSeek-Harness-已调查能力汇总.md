# DeepSeek-Harness 已调查能力汇总

> 汇总对象：`DeepSeek-Harness`（远端仓库 `https://github.com/deepseek-ai/deepseek-harness`，npm 包族 `@deepseek-ai/dsh-*`，产品命令 `dsh`）
>
> 汇总更新日期：2026-08-27
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时共 14 个类目的 DeepSeek-Harness 调查笔记（完整清单见文末来源笔记索引），全部基于同一代码快照 `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`（分支 `master`）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态并链接来源；未做新的源码调查与跨项目横向比较
>
> 汇总范围：上述 14 个类目的既有调查结论；仓库分布与应用界面基础设施两个工程向类目单列于"工程与基础设施摘要"小节；排除跨项目横向比较、评分与排序
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

DeepSeek-Harness 是 DeepSeek AI 官方的开源 agent harness，构建在 vendored Cordis 插件框架上，以"一切皆插件"为架构主张：模型适配器、工具注册表、会话日志、agent 循环本身都是插件。产品面有 `dsh` CLI（`--profile web` / `headless` / `acp` 等组合）、本地 Web GUI（浏览器第二条 cordis 插件树）与进程外 JSON-RPC/Python SDK。核心运行模型是三条相互咬合的设计：会话事件日志为唯一事实源（"模型可见 ⟺ 已落盘"）、能力以 Service Definition / Provider / Consumer 三角色的插件 seam 扩展（循环驱动本身不改）、角色与工具组合按 per-session 的 agent preset 拼装。本次汇总覆盖 14 个类目的调查结论，证据全部来自静态源码阅读。

## 完成度速览

- 主链确认（含静态源码确认）：51 项（功能能力 43 项 + 工程与基础设施 8 项）
- 入口确认（机制）：3 项（workflow/ralph、jobs、bundle 与 invariants）
- 归并已有类目：2 项（skill provider 注册表、feedback/attachment）
- 暂缓：1 项（e2b 远程执行 POC）
- 声明不符：0 项

异常条目（入口确认未闭合 3、暂缓 1、未覆盖 1）共 5 项，占全部 58 项约 9%；其余条目均以主链或静态源码确认完成。异常详情集中放在文末"已知边界与待验证事项"，正文仅保留必要的非加粗指认。

证据口径：本汇总的“主链确认/静态源码确认”表示已在当前代码快照复查入口、状态、执行与结果处理构成的实现路径。DeepSeek-Harness 的 agent 循环、会话日志、工具执行与 Web UI 均在本仓库内。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效；后续黑盒验证是补充观察。

## 功能能力摘要

- **实验性 Agent Teams 与可续接子 Agent**：团队运行时、成员和协作工具均以插件组合，并把相关会话事件写入持久化目录；进程内持久 child session 使用单一 activation 和 FIFO inbox，父 Agent 可选择 quiet 注入或在下一步唤醒。该能力不等同于成熟的团队管理界面或跨账户协作服务。证据状态：静态源码确认。来源：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。

### 角色与上下文

- **per-session agent 组合（preset 角色体系）**：无传统角色卡。preset 是存放一份 `agent.cordis.yml` 插件行列表的目录，目录名即 preset id；每个 preset 在进程内只挂载一次（standing mount），会话经 scope 父链加入组合，插件内部按 Session/Agent 键隔离状态。preset 不绑定模型，默认模型与生成参数由独立插件提供。证据：静态源码确认。链接：[Agent 角色调查笔记](../Agent角色/DeepSeek-Harness-Agent角色调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)、[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)。
- **系统提示词按 scope 分层组装**：`system-prompt` 是按 scope 分层的注册表（section / context / tools / variables），组装时按 agent → preset standing → global 的链就近覆盖；`{{variable}}` 严格插值，`complete` section 可整篇替换（minimal preset 靠它只留 persona 一句话）。证据：静态源码确认。链接：[Agent 角色调查笔记](../Agent角色/DeepSeek-Harness-Agent角色调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- **模型历史从事件日志派生（"模型可见 ⟺ 已落盘"）**：模型历史唯一来源是 `Session.deriveMessages()` 从 append-only 事件日志的表面投影派生，从不单独存储；新的 model-visible 输入必须先落成 session event；每次请求的完整 config/system/tools 以 `request/header` 全量快照落盘，请求可从日志重建。证据：静态源码确认。链接：[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/DeepSeek-Harness-Chat调查笔记.md)。
- **请求组装与模型路由（agent/request 瀑布）**：buildRequest 每步合并 system prompt、工具 schema 与派生历史为一次 `llm/stream` 调用；请求配置每步经 `agent/request` 瀑布重新决定并冻结，是模型路由可插拔的落点；`prepareCall` 物化默认 effort 与 maxTokens。证据：静态源码确认。链接：[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)、[Chat 调查笔记](../Chat/DeepSeek-Harness-Chat调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。
- **工作区指令与动态运行时上下文注入**：`AGENTS.md`/`CLAUDE.md`（及 `.local` 变体）按候选加载，作为带 `agent-instructions` 来源的 user 角色消息进入请求，文件被 read/write/edit 触碰后增量更新；`time-context`、`tmux-context`、`session-reference` 为 opt-in；运行时上下文投影与上一快照比较，仅变化时注入候选消息。证据：静态源码确认。链接：[Agent 角色调查笔记](../Agent角色/DeepSeek-Harness-Agent角色调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- **上下文压缩（compaction）**：可选能力 seam。`compaction/start`/`summary`/`end` 三个 log-only 事件记录事务，真正的替换是一次 `surfaceOp: replace` 的摘要 `user/message`；触发分"步骤压力"（默认 contextWindow×0.8）与 CONTEXT_WINDOW_EXCEEDED 溢出恢复两条路径；`tool-result-pruner` 是可选的无模型剪枝。证据：静态源码确认。链接：[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)。
- **长文本 spill 溢出**：`tools/post-execute` 策略把超过 `maxInlineBytes`（base 组合默认 50000）的纯文本工具结果落盘为会话私有文件，模型只见 head/tail 预览与读取提示；spill 文件本体不进会话导出。证据：静态源码确认。链接：[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)。

### 会话与消息

- **会话即 append-only 事件日志**：内存中的 `Session` 是交互历史的单一事实源，`seq` 恒等于 `log.length`；事件类型经 `SessionEventMap` 声明合并扩展，核心加插件共 24 个事件族；`SESSION_FORMAT_VERSION` 固定为 0，未知事件类型无 `ignorable` 标记即拒绝重建而非迁移；chunk 级保真落盘换取精确回放。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)、[Chat 调查笔记](../Chat/DeepSeek-Harness-Chat调查笔记.md)。
- **消息模型与 surface 双投影**：仅 `user/message`、`assistant/message`、`tool/result` 三类 SurfaceEventType 派生 LLM 消息；每条消息事件带 `surfaceOp` 与可选 `sourceEventSeqs`。表面分 append-origin（人可见对话）与 replacement（仅模型可见）两类，模型历史与人类 transcript 语义刻意不同。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/DeepSeek-Harness-对话导出与分享调查笔记.md)。
- **持久化双后端（JSONL / SQLite）**：同一抽象契约下的两个可互换后端。JSONL 每会话一个文件，默认 zstd 帧 + packed chunk 行、原子物化、torn-tail 截断修复；SQLite 每事件一行、WAL 事务、按 seq 定位。写路径由共享协调器驱动：per-session 串行链 + 固定 200ms 写合并窗口 + `session/flush` 屏障 + checkpoint policy 的语义检查点。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)。
- **会话生命周期（create/resume/fork/崩溃恢复）**：create 为 prepare+enter+announce 三步；resume 走 prepare→load→崩溃修复→发布（有 LRU 已备会话缓存）；fork 深拷贝 0..boundary 前缀为种子并记 `parentSession`/`seedLength`；崩溃恢复对完整中断回合补合成 closers（interrupted 收口与缺失工具错误），torn 尾部丢弃。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **消息操作与分支**：日志追加型且不可变，没有已落盘消息的就地编辑/删除 API；历史改写以 `surfaceOp: replace` 表达（压缩是现有消费者）；分支即 fork，UI 分支按钮传消息 seq 以该 turn 为边界分叉；未提供针对单条消息的续写或重新生成 API，见末尾小节。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- **会话列表与全文检索**：`session-query` 是 live-preferred 的逻辑语料层（精确读取、关系追踪、事件标记 current/shadowed/log-only）；全文检索唯一实现是 `session-query-sqlite`（FTS5 + unicode61 分词、带 snippet 的分页、revision 增量索引、`openAt: never` 可关闭）。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)。
- **对话回合执行（turn/step、inbox、协作式取消）**：`ReactLoopAgent` 是 `Agent` 接口的唯一实现，驱动"turn 打开 → step 循环 → turn 关闭"，turn/step 边界全部是 durable 事件；所有输入经一条 inbox 投递（followup/steer 唤醒、inject 只排队不唤醒）；`cancel` 清 inbox 并 abort 当前活动，未投递的工具调用补合成错误结果保证回放自洽；`dsh --profile headless "task"` 一键运行。证据：静态源码确认。链接：[Chat 调查笔记](../Chat/DeepSeek-Harness-Chat调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- **会话导出（ZIP）与无分享**：唯一导出能力是 Web 端 Session log 下载（会话头按钮与 `/export` 斜杠命令共用下载控制器，流式 ZIP 打包持久化工件的逐字原文，含子代理后代与去重图片媒体，不写 manifest）；内容口径是全量原始日志（含被 surface 遮蔽的旧节点），不做过滤或脱敏；没有任何分享形态、无导入入口；仅 JSONL 后端支持（SQLite 部署端点 501）。证据：静态源码确认，归为 E1 数据交换。链接：[对话导出与分享调查笔记](../对话导出与分享/DeepSeek-Harness-对话导出与分享调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)。

### 生成与创作

- **流式输出协议与折叠**：`StreamChunk` 是闭合判别联合（block-start / 三类 delta / block-end / usage / finish 七个变体），adapter 契约要求 usage 先于 finish、工具参数端到端保持原始 JSON 字符串、失败归一化为可序列化失败事实；`BlockAssembler` 是唯一折叠实现，agent-loop 先把每条 chunk 落 `assistant/chunk` 再喂折叠器，`assistant/message` 携带 usage 与 `sourceEventSeqs`。证据：静态源码确认。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)、[消息渲染器调查笔记](../消息渲染器/DeepSeek-Harness-消息渲染器调查笔记.md)。
- **消息渲染管线（Markdown/代码/数学）**：自建 mdast→React 直接渲染管线；流式用纯 GFM（无数学与高亮）、收口全量重解析；shiki 懒加载语法、KaTeX 经 DOMParser 映射为 React 元素；raw HTML 以字面文本输出、链接与图片仅放行 http(s)/mailto；增量解析只重解析尾部两块并冻结块缓存。UI 呈现行为属运行验证范围，见末尾小节。证据：静态源码确认。链接：[消息渲染器调查笔记](../消息渲染器/DeepSeek-Harness-消息渲染器调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **工具卡片渲染（六类）**：`presentCall`/`presentResult` 是无 I/O 的 args 纯函数；结果期卡片按 shape/kind 分 generic/terminal/diff/search/read/web 六类；结构化事实经 `output.presentationMeta` 随日志持久化、回放时重算；client 侧按工具名键控槽 `tool.call.toolview` 分派，未注册落 `GenericToolCard` 兜底。证据：静态源码确认。链接：[消息渲染器调查笔记](../消息渲染器/DeepSeek-Harness-消息渲染器调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **输出对象身份与活对象**：输出对象分四类——消息（稳定 MessageId）、工具调用/结果（CallId 配对）、磁盘文件（spill、内容寻址附件）、运行实例（终端会话，仅进程内存活、不进日志）；终端 PTY 与后台 job 是模型可跨调用定向维护的活对象；能力总评 G1（富静态结果），无 G2 声明式控件、无 G3 专用运行环境，用户不能编辑模型输出对象。证据：静态源码确认。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- **消息反馈 sidecar**：正/负评分 + 可选 note，按 messageId 键存独立 sidecar 域、version 乐观并发；写入前对目标日志前缀执行 `session/flush` 屏障；永不改动日志本身，也不进模型上下文。Host 侧契约已存在，UI 端到端链未闭合，见末尾小节。证据：静态源码确认。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)、[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。
- **Web Chat UI（双插件树与四象限 RPC）**：浏览器运行第二条 cordis 插件树；对象层 React-free 持全部业务状态、`useSyncExternalStore` 快照喂组件；四象限 RPC（上行 HTTP POST、下行两条 WebSocket 事件流，`assistant/chunk` 即令牌流本身、无独立 delta 帧）；重连即重建（无 resume 游标）。证据：静态源码确认。链接：[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)、[应用界面基础设施调查笔记](../应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md)。
- **Composer 输入状态机与 slash 管线**：InputMachine 四阶段（plain/adjudicating/claimed/submitting），命令模式绝不从草稿文本派生，由选择路径显式建立 claim；支持 chip 引用、自管理撤销（100 条环形日志）、IME 合成保护、Ctrl+Enter 换行；slash 管线按注册顺序轮询、命令目录宿主权威；Web 无 steer 入口，见末尾小节。证据：静态源码确认。链接：[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **会话导航、工作区与现场恢复**：会话列表/工作区浏览器支持分组树/平铺、拖拽排序与宿主全文搜索；blank 会话复用与创建语义由宿主权威判定；Session 常驻后台吃帧，切走再切回即时渲染快照；同一 host 可服务多标签页（blank 位、会话、运行状态经帧广播对齐），草稿/当前会话无跨标签页同步，见末尾小节。证据：静态源码确认。链接：[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。

### Agent 运行时与外部协作

- **工具注册与执行管线**：工具是注册在内存 registry 的代码对象（ToolDefinition：模型可见 schema、强制 output 契约、execute 与可选回调），注册即 effect、返回卸载 disposer、无独立持久化实体；执行走固定管线——策略瀑布（允许/拒绝/询问）→ 单调 guard → 调度瀑布（超时等包装）→ 工具体 → 结果策略 → 内容终结与最终通知；`tool/call` 与 `tool/result` 执行前后落盘。证据：静态源码确认。链接：[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)、[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。
- **工具作用域与过滤**：作用域是层链而非单一目录（全局层 + 每 agent 一个 scope 层）；agent 层同名 shadow 全局，`restrict` 的 allow/deny 只过滤继承面、自身层注册不受限；Code Mode 的 `run_code` 是保留传输（native/code/both 三种呈现）。证据：静态源码确认。链接：[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **capability seam 三角色**：seam = Service Definition（接口）+ Provider（实现）+ Consumer（模型工具）；工具包只拥有 schema、校验与呈现，provider 可整体替换（fs/shell/web/subagents/jobs 等映射）而模型可见 schema 不变。证据：静态源码确认。链接：[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)、[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。
- **工具 guard 机制**：timeout-policy 是 tools/execute 包装器，把声明的超时预算变成 `TOOL_TIMEOUT` 结构化错误；repeat-tool-reminder 是 post-execute 观察者，经 additionalContexts 注入重复调用提醒，只提醒不否决。证据：静态源码确认。链接：[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **ACP 服务器（反向控制表面）**：自动化 ACP 服务器经 JSON-RPC stdio 把宿主 Agent 会话暴露给程序化客户端，支持建会话、发 prompt、回传已提交文本、取消与一次性权限应答；宿主审批 waterfall 对 ACP 会话转成 `session/request_permission` 一次性选项；无鉴权、无并发限制（除每会话单 in-flight prompt），安全模型依赖本地 stdio + 可信调用方。证据：主链确认（静态）。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。
- **MCP 工具桥**：MCP server 工具以 `mcp__<serverName>__<rawName>` 命名注册进宿主工具表；syncTools 先拉完整 tools/list 再整代注册/注销（冲突回滚、全有或全无）；带断线重连监督器与有界指数退避；只保存工具目录，无账号/凭据/资源对象、无跨重启持久连接。证据：主链确认（静态）。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **hooks 双桥**：在宿主扩展点上按 Claude Code/Codex 的 hooks.json 契约运行外部命令，经 `ctx.shell` 沙箱执行；审批语义按协议最严格合并（deny > ask > allow）；每次调用写 `hook/invoked` 与 `hook/result` 事件对审计。configPath 是进程级一次性读取，无 per-session 项目内 hooks.json 发现，细节见末尾小节。证据：静态源码确认。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。
- **外部执行体委派（子代理多 provider）**：四个进程外 provider（ACP、Claude Code、Codex、dsh-sdk）把外部 Agent 作为一次性执行体启动、通信、取消并回收最终文本，共享"一次性 run、永不 reject 的结果、整树静止 teardown"契约；结果只回传最终文本，不回流推理/工具事件/文件变化；取消是"本地优先、远端尽力"；子进程环境擦除凭据形状变量与 DSH_* 名。委派策略细节与六 provider 能力族见"独特与差异化能力"中"多 provider 子代理能力族"条目。证据：主链确认（静态）。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)、[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。

### 渠道与调度

- **LLM 渠道：中性流式词汇 + 双适配器**：Provider 是注册键（route）而非用户实体，同一 adapter 实例可注册多条 route，注册与替换全有或全无且同步原子；`dsh-llm-deepseek`（直连 fetch + SSE）与 `dsh-llm-pi-ai`（经 pi-ai 库）作为 twin 双实现验证同一 `StreamChunk` 契约，route 名刻意区分，一份组合可同时挂两个 DeepSeek 路径。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)、[仓库分布调查笔记](../仓库分布/DeepSeek-Harness-仓库分布调查笔记.md)。
- **凭据引用模型**：配置只携带 `apiKeyEnv` 之类引用，key 永不进配置文件；凭据 seam 每次请求解析，分层为继承环境 > 托管文档（`$DSH_HOME/.credentials.yaml`，0600 + 文件锁）> 项目/用户 .env；非法值报 `INVALID_CREDENTIAL`、引用未命中报 `MISSING_CREDENTIAL`，错误消息只命名引用、绝不回显 key。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。
- **模型目录与能力元数据**：目录是配置而非远端刷新（"catalog never refreshes itself"）；直连适配器模型为配置列表（默认 V4 Flash/Pro、100 万上下文），pi-ai 以安装目录为默认、models 整表替换、modelOverrides 逐模型微调；未列出的模型 id 在直连侧仍可请求（pass-through）、pi-ai 侧报 `UNKNOWN_MODEL`；`discoverModels` 是配置时端点探测而非目录刷新。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。
- **重试与限流**：重试在 agent 回合边界而不在 SDK：`dsh-llm-retry` 监听 `agent/request-error` 瀑布执行 provider-owned 策略（normal 默认对五个可重试码最多 2 次、500ms→10s 指数退避 + 10% 抖动；always 无上限）；一次 adapter 调用 = 一次 provider 尝试。无多 Key、无 Key 轮换、无跨渠道 failover，`RATE_LIMIT` 只作为可重试码，属已确认的边界。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。
- **默认模型与会话级模型选择**：默认模型在基座 bundle（`deepseek-official`/`deepseek-v4-flash`），`agent-default-model` 插件经 settings 分层提供；会话级选择挂在 `system-prompt/assemble`（注入变量）与 `agent/request`（改写请求路由）两个 waterfall，读取优先级为"本次进程内已选 > 会话日志最近的请求 header > 默认"。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)、[Agent 角色调查笔记](../Agent角色/DeepSeek-Harness-Agent角色调查笔记.md)。
- **渠道管理入口覆盖**：配置文件（patch/settings/凭据文件、watcher 热重载）与 Web Models 设置页（catalog route / custom route 新增、ProviderEditor、`discoverModels` 探测）是源码确认的渠道管理入口，支持查看/新增/编辑/按来源删除与热生效。CLI/TUI/桌面端存在未覆盖项，见末尾小节。证据：静态源码确认（未覆盖项见末尾小节）。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。

### 独特与差异化能力

以下能力卡保留[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)的能力卡标题与证据状态。六项主机制均达主链确认（静态证据）；它们共享三条架构模式：能力缝三角、会话事件日志为唯一持久权威、日志完整不变量。

- **能力一：自引用插件运行时（self-modification）**：让模型在会话中直接检查自己所在 Cordis 进程的插件与服务，并把自己写的插件包定义、运行、停止、删除（入口为七组 inspect/define/run/stop/undefine 工具与 `@<pluginId>` 引用注入）；定义与运行只存在于进程内存，重启即失、仅定义它的会话可见。vm 沙箱明确"不是安全边界"，Node 的 require/timers/fetch 被陷阱化重定向到能力 seam（项目自述边界，见末尾小节）。证据：主链确认（静态）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **能力二：进程沙箱（sandbox）**：给"同世界子进程"施加文件效应策略（read-only / workspace-write / danger-full-access 三档），策略按每次调用经 `ctx.sandbox.confine` 携带；后端按平台链选择（Linux bwrap 优先、探针失败再 Landlock；macOS Seatbelt；Windows ACL 受限令牌 runner），运行期拒绝 fail-closed；无静默无沙箱回退，选不出后端抛 `SANDBOX_UNAVAILABLE`。真实内核行为属平台运行验证项，见末尾小节。证据：主链确认（静态）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。
- **能力三：同会话目标驱动循环（goal）**：把长期目标做成事件溯源状态（`goal/change` 会话事件 + 严格递增 revision），`goal-round-driver` 在会话内自动续跑；激活（armed）是分离的、从不持久化的进程内标志；完成/阻塞由模型自报（连续 N 轮同一条件默认 3 判定 blocked）；轮次预算默认上限 256。证据：主链确认（静态）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **能力四：plan mode 作为日志化协作状态**：`plan/mode` 是 log-only、整值替换的会话事件，`foldPlanMode` 纯折叠出状态、无 live mirror；激活时把 `plan:policy` 提示段（order 50）加入每轮请求；`exit_plan_mode` 工具要求完整 Markdown 计划并经 user-questions 缝审批；沙箱与审批策略独立强制执行、互不读写该状态。证据：主链确认（静态）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **能力五：session-local 定时调度（schedule）**：`schedule/change` 事件是唯一持久权威，timer 只是可弃投影；after（一次性延迟）/ at（绝对时刻）/ every（最小 5 分钟）三变体；到期且 agent 完全 idle 时以普通对话回合回到原会话。交付边界固定 session-local，无冷会话调度器、无外部通知通道，投递是尽力而为的 at-least-once（项目自述边界，见末尾小节）。证据：主链确认（静态）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **能力六：多 provider 子代理能力族（subagent）**：一个委派契约（`ctx.subagents`）、六种执行位置（同进程 spawn、同进程 fork、进程外 ACP、Claude Code、Codex、dsh SDK）；可续子代理拥有持久子会话 + 至多一个进程内 Activation，冷恢复直接从持久会话重建；委派策略固定（快照父沙箱 override、子代理审批钉死 never、注入 delegation-scope 声明），策略以 `source: 'delegation'` 事件写入子会话日志可重放。证据：主链确认（静态）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **skill provider 注册表**：已归并到 Agent 工具类目（工具侧）；注册表本身是 scope 分层的中立发现机制（本地文件、嵌入、远端均可），发现与加载分离。证据：归并已有类目。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- **feedback / attachment**：已归并到既有类目（反馈属生成输出 sidecar，附件属内容寻址附件存储）；feedback 分命令反馈（日志备注）与消息反馈（独立 sidecar，均不进模型上下文）两种契约，附件落 `$DSH_HOME` 下。证据：归并已有类目（普通能力）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)。

另有 workflow/ralph、jobs、bundle 与 invariants 等入口确认（机制）的支撑能力，以及暂缓的 e2b 远程执行 POC，见文末"已知边界与待验证事项"。

## 工程与基础设施摘要

**仓库分布（结构、构建、文档、测试、平台）**

- **仓库形态与规模**：单一 TypeScript monorepo（pnpm workspace、tsc -b 双编译面 + tsdown 构建、vitest 测试），46 组 226 个可独立发布的 npm 包；Git 跟踪文件 7,412 个、源码文件 2,756 个 / 590,509 行，TypeScript 占 95.5%；产品 API 脊柱集中在 `packages/core` 五包，`packages/client` 组 153,754 行为最大区域（39 个 `ui-*` 界面插件）。证据：Git 跟踪文件机械统计 + 源码复核（静态）。链接：[仓库分布调查笔记](../仓库分布/DeepSeek-Harness-仓库分布调查笔记.md)。
- **框架层"双持有"与 twin 实现**：Cordis 全家被 vendored 进 `vendor/`（9 包、18 项本地修改清单、产品包以 peer dependency 解析到 vendored 源码）；`@earendil-works/pi-ai` 以普通 npm 依赖被消费（消费不持有），`llm-pi-ai` 与 `llm-deepseek` 是同一 LLM 缝隙的 twin 双实现。证据：静态确认。链接：[仓库分布调查笔记](../仓库分布/DeepSeek-Harness-仓库分布调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。
- **文档与测试体系**：docs/ 215 文件（中英双语"三件套" + 六个生成目录）、`.agents/notes` 1,386 篇双语 Agent Notes、226 包全部带 README 三件套；测试 1,772 文件 / 307,244 行，含 Web e2e、examples 快照回放与 scripts 仓库自检，门禁声明"按文件 100% 覆盖率"（覆盖率声明属运行验证项，见末尾小节）。证据：静态统计。链接：[仓库分布调查笔记](../仓库分布/DeepSeek-Harness-仓库分布调查笔记.md)。
- **跨平台与发布组织**：四个对外运行面（CLI、Web GUI、进程外 JSON-RPC/Python SDK、ACP/MCP 自动化协议）；平台差异按"同缝隙多 provider 包"组织而非条件编译；`native/` 含 Landlock C 启动器与 Windows ACL C++ 探针；发布按 npm 产品族 / vendor 族 / Python wheel / Landlock 四族资产组织。证据：静态确认。链接：[仓库分布调查笔记](../仓库分布/DeepSeek-Harness-仓库分布调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。

**应用界面基础设施**

- **双 cordis 插件树与启动链**：宿主进程一条 cordis 树、浏览器第二条 client 树；`window.__DSH_BOOT__` 清单交给 shell，自研懒 CJS 模块表 + vendored Loader 装配，全部条目 ACTIVE 后一次性翻转真实界面；插件包永不进入 vite 打包图（以运行时 bundle 到达），dev 模式拒绝裸 vite serve。证据：静态源码确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **传输、连接与信任模型**：上行仅 HTTP 一元 RPC、下行两条 WebSocket 事件流（`/api/events.mux` 与 `/api/events.host`），四象限 RPC 协议（谁发起谁铸造 rpcId）；重连即重建（指数退避 500ms 起、封顶 10s、握手要求双流 open + `host.describe` 成功）；请求信任栅栏（loopback/trustedHosts 校验、sec-fetch-site 与 Origin 检查、拒绝 `--host 0.0.0.0`）。证据：静态源码确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **状态所有权与 UI 基础设施**：对象层（React-free）持全部业务状态、渲染机制（web-react 桥）完成 ctx↔React 集成、表现组件纯 props 三层分工；插槽系统（slot map 声明合并、kind 四类、会话作用域）是唯一组件组合通道；store 只装视图状态；主题（light/dark/system、防首屏闪烁、语义 token 别名）、国际化（中文回退、双语注册强制）、两级错误边界、schema-form 表单引擎、模态/Toast/浮层公共组件。证据：静态源码确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。
- **协议生成与 BFF**：Typert 编译器从 TypeScript 类型图生成协议描述符与 zod 编解码器，网关据此分发 `/api` 调用，客户端无需手工维护协议代码；Typert 网关把业务服务上 `@Remote` 标记的方法暴露为规范端点；`packages/api/remotes` 是 BFF 上层；`packages/sdk` 是独立的进程外 stdio JSON-RPC 通道，与 Web 四象限协议无关。证据：静态源码确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)。

## 已知边界与待验证事项

**声明不符**：0 项。14 篇来源笔记均未确认文档与实现相矛盾的"声明不符"；下列为项目自述边界（来源笔记如实转述，不是缺陷结论）。

**暂缓与外部依赖**

- e2b 远程执行 POC：实验性 provider 组合，只实现 fs 与 subprocess 两个 OS 适配器，依赖外部 E2B 服务，未运行验证，标暂缓。证据：入口确认（暂缓）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。
- 进程沙箱真实内核行为（bwrap/Landlock/Seatbelt/Windows ACL 与 Windows 进程树终止）需平台运行验证；vm 逃逸面未验证。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。

**入口确认未闭合（支撑机制）**

- workflow / ralph：模型可提交编排脚本给 `ctx.workflowEngine`，worker-thread provider 在隔离线程执行（明确非安全边界）；`ralph` 是固定 fresh-agent 策略。机制入口与契约已确认，未展开主链验证。证据：入口确认（机制）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- jobs 后台任务：owner 隔离的后台任务协议（观察、取消、等待、完成通知），`job_list`/`job_output`/`job_kill` 为模型面。机制入口与契约已确认，未展开主链验证。证据：入口确认（机制）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)。
- bundle profile patch-layer 与 invariants 运行时不变式：npm 包 manifest 声明 `dsh.bundle.patch` 即成 profile 可安装补丁层（`dsh-base` 为第一层）；每个 npm 包发布 `./invariant` 伴侣向 `ctx.invariants` 注册运行时检查。机制入口与契约已确认，未展开主链验证。证据：入口确认（机制）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。

**未覆盖类目（笔记已声明检索范围）**

- 会话级删除、导入、备份 API 未找到；日志本身无跨进程锁，revision token 只用于检测外部变更并触发重读，不能仲裁。链接：[会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)。
- 针对单条消息的续写或重新生成 API 未找到（分支以 fork 表达）。链接：[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- 渠道管理：CLI 无渠道向导与连接测试；TUI 渠道管理页与桌面端应用未找到；渠道复制、导入导出、行级启停按钮未找到；HTTP 代理配置未找到。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)。
- 分享能力未找到（仅浏览器本地下载文件）；独立知识库注入机制未找到（用户知识经 AGENTS.md 指令与文件内容进入上下文）。链接：[对话导出与分享调查笔记](../对话导出与分享/DeepSeek-Harness-对话导出与分享调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)。
- hooks 双桥无 per-session 项目内 hooks.json 发现（configPath 为进程级一次性读取），部分协议语义（updatedInput、systemMessage、continue:false 停轮）未生效或未实现。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)。
- 消息反馈 sidecar 的 UI 端到端链未闭合（Host 侧契约已存在）。链接：[独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)。

**共性未验证**

- 全部 14 篇来源笔记均为静态源码阅读，未运行应用、测试或真实模型请求；同一代码快照为 rc.5 状态（32 条提交的浅克隆），快照之外的历史未纳入。
- 运行时行为待黑盒补充确认：LLM 重试与 pi-ai 错误文本分类的真实匹配度、ACP/Codex/Claude Code 真实子进程往返、goal 多轮续跑竞态、schedule 定时器唤醒与崩溃窗口、Web GUI 视觉/键盘/无障碍/流式性能、消息渲染 DOM 呈现、覆盖率门禁"按文件 100%"声明。
- 已确认的项目边界（正文已述，此处汇总）：vm 沙箱"不是安全边界"；无冷会话调度器与外部通知通道；SQLite 部署下会话导出端点 501；导出不含 spill 文件本体；Web 端无 steer 入口、草稿/当前会话无跨标签页同步；无跨渠道高可用（多 Key/轮换/failover）。

与特色贡献统计的衔接：goal、plan mode、schedule、self-modification 可计为产品特性，sandbox 与子代理委派策略按机制贡献单列，见[特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/DeepSeek-Harness-Agent工具调查笔记.md)：工具定义/注册、作用域与过滤、发现与注入、执行管线、guard、capability seam、Code Mode、UI 呈现。
- [Agent 角色调查笔记](../Agent角色/DeepSeek-Harness-Agent角色调查笔记.md)：preset 角色体系、system prompt 组装、模型与生成参数、子 Agent、资产与变量、与 pi 的关系。
- [Chat 调查笔记](../Chat/DeepSeek-Harness-Chat调查笔记.md)：agent loop 的 turn/step 生命周期、事件域、inbox 与唤醒、取消与错误恢复、headless 运行。
- [Chat UI 调查笔记](<../Chat UI/DeepSeek-Harness-ChatUI调查笔记.md>)：Web Chat UI 双插件树、四象限 RPC、会话导航、Composer 输入状态机、设置表单、流式渲染、工具卡片、多会话与跨窗口。
- [LLM 渠道管理调查笔记](../LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md)：LLM seam、twin 适配器、凭据与配置、模型目录、重试限流、默认模型、渠道管理入口覆盖、pi-ai 复用边界。
- [仓库分布调查笔记](../仓库分布/DeepSeek-Harness-仓库分布调查笔记.md)：仓库形态与量级、语言与运行时分工、文档/测试分布、跨平台与发布组织。
- [会话与消息管理调查笔记](../会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md)：事件日志数据模型、持久化双后端、生命周期、消息操作与分支、列表检索、迁移与导入导出边界。
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md)：进程外 subagent provider、ACP 服务器、MCP 桥、hooks 桥、执行与取消语义、权限与治理。
- [对话导出与分享调查笔记](../对话导出与分享/DeepSeek-Harness-对话导出与分享调查笔记.md)：Session log ZIP 导出、内容口径、附件/spill 处理、无分享结论、性能与失败语义。
- [对话请求与上下文调查笔记](../对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md)：请求主链、历史派生、compaction、spill、上下文注入插件、提问能力、与 pi 无代码继承。
- [应用界面基础设施调查笔记](../应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md)：启动加载链、前端运行时、传输连接、Typert 协议、主题国际化、信任模型。
- [消息渲染器调查笔记](../消息渲染器/DeepSeek-Harness-消息渲染器调查笔记.md)：消息与内容块模型、流式更新链、列表滚动、Markdown/代码/数学管线、呈现意图与工具卡片、扩展机制。
- [独特功能调查笔记](../独特功能/DeepSeek-Harness-独特功能调查笔记.md)：自引用插件运行时、进程沙箱、goal、plan mode、schedule、子代理能力族六项主机制，以及 workflow/jobs/bundle/invariants/e2b/skill 等支撑机制盘点。
- [生成式输出与运行时调查笔记](../生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md)：流式词汇与折叠、输出事件落盘、工具结果契约、终端/shell/附件/spill/反馈/令牌计量、持久化与恢复。
