# Pi 已调查能力汇总

> 汇总对象：`Pi（https://github.com/earendil-works/pi）`
>
> 汇总更新日期：2026-08-27
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时共 13 个类目的 Pi 调查笔记（完整清单见文末来源笔记索引），均基于同一代码快照 `e86823096c5bad39e1ca282ec24bc5eb9bec745b`（分支：`main`）；另引用 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)
>
> 汇总方法：阅读各来源笔记的"结论摘要"与关键章节，按功能主题合并重复能力，保留来源笔记的证据状态与边界表述，逐条链接来源；未进行新的源码调查与跨项目横向比较
>
> 汇总范围：上述 13 个类目的既有调查结论；仓库分布与应用界面基础设施两个工程向类目单列于"工程与基础设施摘要"小节；排除跨项目横向比较、评分与排序
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Pi 是命令行编码 Agent（产品命令 `pi`），按可发布能力拆包的 TypeScript monorepo。`packages/coding-agent`（AgentSession 会话编排 + CLI/TUI）、`packages/agent`（Agent/agentLoop 工具循环 + harness SDK）、`packages/ai`（Provider 归一化与流协议）、`packages/tui`（自研差分渲染终端库）构成主体，server/client/protocol/session-backends/telemetry 提供可组合边界。产品表面是终端 TUI（键盘工作流）与 print/json 两种非交互模式，另有 RPC 与 server 模式（仅从调用关系推断）；仓库内无 Web/桌面 GUI。会话事实源是每个会话一个追加型 JSONL 树文件；模型推理经外部 Provider 完成；bash 执行内建于工具循环。全部 13 篇来源笔记均为静态源码阅读，未运行应用、测试或真实模型请求。

## 完成度速览

本汇总功能能力条目按证据状态的计数（含归并子项与暂缓项，共 34 项）：

| 证据状态 | 条目数 | 说明 |
| --- | ---: | --- |
| 主链确认 | 14 | 源码贯通确认的完整主链 |
| 静态源码确认 | 14 | 含"只读源码确认""静态源码阅读确认"等同级标记 |
| 入口确认 | 1 | 会话数据生产与分享（研究轨迹候选，发布端外部依赖） |
| 归并已有类目 | 4 | 独特功能类目标记，已归并至既有类目 |
| 暂缓 | 1 | HF 数据集发布（外部依赖，未验证） |
| 声明不符 | 0 | 无 |

已确认项（主链确认 + 静态源码确认）约占功能条目 82%；异常项（入口确认未闭合 + 暂缓）约占 6%，其余为归并项与已确认边界。所有异常与未验证细节集中在本文件末尾"已知边界与待验证事项"小节，正文只保留必要的指认。

**证据口径**：本汇总的“主链确认/静态源码确认”表示已在当前代码快照（`e868230…`，分支 `main`）复查入口、状态、执行与结果处理构成的实现路径；Pi 的 CLI/TUI 与本地进程执行构成完整本地主链。未进行黑盒运行、真实终端或端到端操作，只保留视觉、焦点、性能、平台行为及外部依赖等需在目标环境观察的维度，不使实现结论失效。

## 功能能力摘要

### 角色与上下文

- **角色能力（无独立角色实体）**：角色由四条可配置链路在会话启动时按 cwd 解析、每轮请求前拼装进 system prompt——`.pi/SYSTEM.md`/`~/.pi/agent/SYSTEM.md` 整篇替换默认模板、`APPEND_SYSTEM.md` 追加、AGENTS/CLAUDE 上下文文件链（全局 → 祖先目录 → 当前，`AGENTS.override.md` 覆盖仓库版本）、Skills 与 prompts 模板、扩展 `before_agent_start` 每轮改写（优先级最高且仅当轮有效）。文件即配置、零数据库零版本字段，删除文件即失效；无角色复制/导入导出。证据：静态源码确认。链接：[Agent 角色调查笔记](../Agent角色/Pi-Agent角色配置调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)。

- **system prompt 拼装与工具可见性**：`buildSystemPrompt` 分自定义/默认模板两形态；Available tools 段只列带一行 snippet 的激活工具，guidelines 按工具集推导（如无 grep/find/ls 时提示用 bash 做文件操作）；skills 生成 XML `<available_skills>` 索引区，全文经 `/skill:name` 注入。system prompt 本体不进会话文件，仅 HTML 导出时快照。证据：静态源码确认。链接：[Agent 角色调查笔记](../Agent角色/Pi-Agent角色配置调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。

- **模型与思考等级会话级绑定**：模型/思考等级存在 `agent.state.model/thinkingLevel`，切换写入 `model_change`/`thinking_level_change` 会话条目；默认 Provider/模型/思考等级来自全局与项目 `settings.json` 深合并，思考等级默认 `"medium"`。生成参数（samplingParams、thinkingBudgets）绑定在模型元数据/设置，不绑定在角色上。证据：静态源码确认。链接：[Agent 角色调查笔记](../Agent角色/Pi-Agent角色配置调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。

- **上下文构建、预算与压缩**：上下文沿 leaf 经 parent 链回溯构建，compaction/branch_summary 投影为摘要消息、普通 custom 条目不参与；`estimateTokens` 按字符/块长度启发式估算，`contextTokens > contextWindow - reserveTokens`（默认 reserve 16384 / keepRecent 20000）触发自动压缩；溢出走"压缩并自动重试一次"（`_overflowRecoveryAttempted` 只允许一次）。压缩是"重写上下文而非删历史"，旧条目保留可回溯。证据：主链确认（静态源码）。链接：[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md)。

### 会话与消息

- **会话数据模型（JSONL 追加型树）**：每个会话一个 `.jsonl` 文件（`~/.pi/agent/sessions/<编码cwd>/`），记录带 `id/parentId` 形成树，`leafId` 指针标识当前位置，分支只移动指针不修改历史；条目九类型（message/thinking_level_change/model_change/compaction/branch_summary/custom/custom_message/label/session_info），`custom` 不进 LLM 上下文、`custom_message` 参与并控制显示；消息是分块内容模型，assistant 内容为 text/thinking/toolCall 块数组。证据：主链确认（静态源码）。链接：[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/Pi-Chat调查笔记.md)。

- **持久化时机与事实源**：落盘绑定 `message_end`——第一条 assistant 消息时创建文件（此前仅缓存，无模型回复的会话不产生文件），此后逐条 append；恢复时全量读入内存，读文件时版本落后自动迁移（v1→v2 生成 id/parentId 树，v2→v3 改 hookMessage 角色名）。证据：主链确认（静态源码）。链接：[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md)。

- **分支、fork、clone 与树导航**：分支四入口 `branch`/`createBranchedSession`/`forkFrom`/`branchWithSummary`（跨目录复制记 `parentSession`、追加 branch_summary 摘要条目）；`/tree` 树形导航带 label 书签与可选分支摘要生成，`/fork` 从指定 user 消息开新分支，`/clone` 复制当前会话；`/copy` 复制最后一条助手消息。历史是追加型，编辑以分支表达；无独立续写入口，细节见末尾小节。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)、[Chat 调查笔记](../Chat/Pi-Chat调查笔记.md)。

- **会话列表、检索与搜索**：列表全量扫描 + 并发上限 10、按修改时间倒序；`/resume` 选择器内嵌搜索（fuzzy/短语/`re:` 正则，搜索文本含全部消息文本与 cwd）。消息级搜索的独立实现（扫描器与 SQLite FTS5 后端）本次未接入主路径，细节见末尾小节。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)。

- **删除、命名与恢复**：删除在 UI 层做文件级删除（trash 优先、unlink 兜底），确认式、当前活动会话不可删；命名写 `session_info` 条目，空字符串清除；中断后 assistant 消息以 `stopReason: "aborted"` 持久化，`/resume` 恢复。`SessionManager` 类本身无删除方法，删除入口只存在于 UI 层。证据：静态源码确认。链接：[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)。

- **对话导出与分享（E1/E4/E5 交接侧）**：`/export` 按后缀分流——JSONL 导出把当前分支线性化（重排 parentId，侧枝不进入），HTML 导出嵌入完整树（全条目 + leafId + system prompt + 工具定义，base64 JSON 内嵌的自包含单文件，默认按当前分支渲染、查看器侧栏可切换分支）；`/import` 复制 JSONL 到会话目录续跑（往返可用，分支关系已线性化）；`/share` 优先把带 system prompt 与激活工具 schema 的当前分支 JSONL 上传为 Radius 组织 artifact，缺少 Radius provider 或凭据时才以 `gh gist create --public=false` 回退；`/copy` 复制最后一条助手文本。HTML 端做了输入侧硬化（marked 禁 HTML、scheme 白名单、HTML 转义）。分享治理仍无内容确认、脱敏与本地撤销，外部平台的可见性和留存语义需单独验证。证据：静态源码确认（HTML、Radius 和 Gist 平台行为未运行验证）。链接：[对话导出与分享调查笔记](../对话导出与分享/Pi-对话导出与分享调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)。

- **消息渲染体系（终端组件树）**：渲染是"Markdown 文本 → 终端行"管线——marked 解析（strikethrough + LaTeX 扩展）→ 主题函数着色 → ANSI 感知换行 → 边距填充；代码高亮为 highlight.js scope → 主题函数 → ANSI；消息壳层按 role/类型分派（user/assistant/bashExecution/compactionSummary/branchSummary 等），流式时每 `message_update` 全量重建 assistant 组件；性能策略是 Markdown 按 text+width 缓存 + TUI 16ms 帧节流；终端渲染不产生 HTML，无运行时 HTML 注入面。聊天区是普通 Container 无虚拟化，超长会话渲染成本线性增长。证据：静态源码确认（视觉/滚动行为需运行验证）。链接：[消息渲染器调查笔记](../消息渲染器/Pi-消息渲染器调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)。

### 生成与创作

- **生成任务主链与输入处理**：`AgentSession.prompt()` 依次执行扩展命令、input 钩子、`/skill:name` 展开、`/template` 模板展开、流式中入队（steer/followUp）、模型与认证校验、预压缩检查、user 消息组装、`before_agent_start` 扩展事件，再进 `Agent.prompt()` → `runAgentLoop`；无独立"任务记录"对象，运行状态在 Agent/AgentSession 内，事件是唯一对外通道。证据：主链确认（静态源码）。链接：[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)、[Chat 调查笔记](../Chat/Pi-Chat调查笔记.md)。

- **流式协议与对象模型（能力等级 G2）**：模型输出只有 text/thinking/toolCall 三种结构化 part（外加工具结果中的 image），经统一 `AssistantMessageEvent` delta 事件归一化所有 provider；工具调用凭 `toolCallId` 成为 TUI 中可展开/折叠的声明式执行对象（G2），写盘产物凭文件路径成为工作区普通文件。`toolcall_delta` 携带原始 JSON 片段即时解析，输出 token 截断时所有未完成工具调用统一标记错误回注；thinking 被过滤时保留 `thinkingSignature`。无独立 artifact 对象（能力总评为 G2，模型输出未进入专用运行环境）。证据：主链确认（静态源码）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。

- **文件写入与 diff**：write 全文覆盖（自动建父目录）、edit 精确文本替换（每处 oldText 必须唯一、模糊匹配、保留未改动行原始字节）、bash 在宿主本机 shell 子进程执行（spawn + 进程树终止 + 可选超时 + 输出截断落临时文件）；edit 工具在 TUI 先显示 diff 预览再显示最终 diff，`details.patch` 存标准 unified patch；同文件并发写按 realpath 串行化。模型是文件唯一修改者，无接受/拒绝 diff、无撤销、无 CRDT；沙箱/容器仅是部署文档而非内置运行时（容器化未做运行验证，见末尾小节）。证据：主链确认（静态源码）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。

- **会话恢复与模型回流**：resume/import/fork 后经 `buildSessionContext` 全量恢复到 `agent.state.messages`，模型在完整时间线上继续；compaction 后旧消息被 `<summary>` 用户消息回流；对象身份=文件路径，绑定到后续回合的是"会话 + 文件路径"。无 artifact ID 类稳定对象句柄。证据：主链确认（静态源码）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)。

- **停止、重试、steer/followUp**：自动重试用 `settings.retry` 预算（默认 maxRetries 3、指数退避），对最后一个 assistant 错误消息 `continue()` 重跑；溢出类错误不重试走压缩；运行中可投递 steer（打断，当前工具回合结束后注入）与 followUp（排队，agent 结束后处理）两种队列；abort 后以 `stopReason: "aborted"` 落盘，`/resume` 恢复。无独立"续写到消息末尾"入口（续写经分支/新消息），细节见末尾小节。证据：主链确认（静态源码）。链接：[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)、[Chat 调查笔记](../Chat/Pi-Chat调查笔记.md)。

### Agent 运行时与外部协作

- **工具系统（内置 + 扩展注册，本地执行模型）**：内置 8 个工具（read/bash/powershell/edit/write/grep/find/ls），扩展经 `registerTool` 注册 `ToolDefinition`（TypeBox 参数 schema + prompt snippet + 渲染回调 + 执行函数）；PowerShell 是 Windows 上可选的本地执行工具。默认激活集仍为 [read, bash, edit, write]，但 `defaultTools` 可按全局或项目设置替换内置启动集且不关闭扩展/SDK 自定义工具，`--tools` 再以严格允许名单覆盖；工具是代码对象非独立持久化实体，全部本地进程内执行。MCP 客户端/协议实现本次未找到，细节见末尾小节。证据：主链确认（静态源码）。链接：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。

- **工具注入与模型协议**：激活集存于 `agent.state.tools`，每轮 `prepareNextTurnWithContext` 把当前工具集快照注入 `Context.tools`，由各 API Adapter 转成 OpenAI function calling、Anthropic tools、Google functionDeclarations 等格式；`Tool.constrainedSampling` 可要求严格 JSON schema（TypeBox schema 转 strict 子集，不可转换时回退或报错）或 Lark/regex grammar；`PI_EXPERIMENTAL=1` 时内置工具启用 strict 约束采样。无工具级 token 预算或自动裁剪。证据：主链确认（静态源码）。链接：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。

- **参数校验与编排循环**：`prepareToolCall` 在执行前集中校验并做值转换（normalizeOptionalNulls → TypeBox Convert → 缓存校验器），未知工具与校验失败都转成 isError 工具结果回注给模型而非中断循环；`runLoop` 双 while（内层处理工具调用 + steering 队列、外层排空 followUp 队列），默认并行执行同批工具调用、结果按序回注，可按 `executionMode` 转串行；`length` 截断时整批工具调用统一按失败回注。循环无显式迭代上限（源码未发现 maxIterations），终止依赖模型 stopReason 与队列排空。证据：主链确认（静态源码）。链接：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)。

- **审批与执行边界**：审批是回调钩子而非执行端强制——`beforeToolCall` 返回 `block` 即拒绝并回注，`afterToolCall` 可改写结果，扩展 `tool_call`/`tool_result` 事件走同一路径；项目信任门决定项目级 `.pi` 设置、资源、扩展与包是否加载（不直接拦截 bash 执行，仅当 shell 路径与命令前缀取自项目设置时间接影响运行参数）。执行全部为本地进程内：文件工具直接 fs，bash spawn 子进程、进程树终止、可选超时、输出截断；`BashOperations` 接口允许扩展替换执行后端（如 SSH 远程），默认本地实现。按工具/风险分级的常驻审批策略未发现，细节见末尾小节。证据：主链确认（静态源码）。链接：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。

- **扩展体系（自扩展 Agent harness）**：扩展可注册工具、改写 system prompt（`before_agent_start`）、注入 custom/custom_message 条目、提供 `/xxx` 命令与自定义会话条目；Pi Packages 经 npm/git 安装分享；Skill 是模型可见的文本资源（system prompt 索引 + `/skill:name` 全文注入），不是工具调用。harness SDK 的搜索接口未接入 TUI 主路径，细节见末尾小节。证据：主链确认（静态源码）。链接：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)、[Agent 角色调查笔记](../Agent角色/Pi-Agent角色配置调查笔记.md)、[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)。

- **子 Agent 与多会话边界**：`createAgentSession` 可被扩展用作子 Agent 循环（共享相同工具循环），子 Agent 默认继承分发会话的当前模型与思考等级；单会话单 agent 循环（activeRun 守卫），运行中可投递 steer/followUp。无内置"把当前会话委托给子 Agent"的配置，UI 层面无多 Agent 编排与多会话并行，细节见末尾小节。证据：静态源码确认。链接：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)。

### 渠道与调度

- **LLM 渠道与 Provider 管理**：Provider 是代码注册项而非可多实例化用户实体（每 Provider 固定 id，`providers/all.ts` 构造 40 个，KnownProvider 枚举 40 个），Radius 网关是唯一多实例入口（`radiusProvider({ id })` 工厂）；模型目录四层合并（构建期内置目录 gitignore → 启动期 pi.dev 远端目录 ETag 叠加 → 用户 `models.json` 定义与 modelOverrides → 扩展注册）；Endpoint 不是独立实体，只是 `Model.baseUrl` 字段；`~/.pi/agent/models.json` 是唯一直接定义 Provider 的持久化入口，TUI 的 `/login`、`/logout`、`/model`、`/reload` 处理凭据、模型选择与重载。渠道配置编辑器与 Web/桌面端渠道管理未找到，细节见末尾小节。证据：静态源码确认（"未找到"按本次检索范围表述）。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。

- **凭据、Header 与安全边界**：凭据按 Provider 一粒存于 `~/.pi/agent/auth.json`（0600 权限 + proper-lockfile 文件锁，每 Provider 一文件记录 api_key 或 oauth access/refresh/expires）；解析优先级为显式 apiKey > 已存凭据 > 环境变量/ambient（AWS profile/ADC），已存凭据刷新失败不回退环境变量；models.json 内嵌凭据支持明文/`$VAR` 插值/`!command` 取值三条路径。凭据静态未加密；`auth print-api-key`/`print-bearer-token` 是显式导出路径，静态存储与日志未见自动脱敏。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。

- **协议适配与请求组装**：`packages/ai/src/api/` 下 11 个协议实现（openai-completions/openai-responses/openai-codex-responses/azure-openai-responses/anthropic-messages/bedrock-converse-stream/google-generative-ai/google-vertex/mistral-conversations/pi-messages/cloudflare-gateway-binding），每个模块导出 `stream`/`streamSimple`；OpenAI-compatible 按 provider 名 + baseUrl 特征自动探测兼容开关（developer role、thinking 格式、cache 控制等），`compat` 可显式覆盖；订阅制标记（GitHub Copilot/Kimi Code/OpenAI Codex/xAI 的 OAuth 标记 isSubscription），footer 只对已知订阅制显示 `(sub)`。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。

- **重试、限流与故障转移**：重试分层且范围明确——SDK 层 `retryProviderRequest`（镜像 OpenAI/Anthropic 策略，408/409/429/5xx，指数退避 + 抖动）+ 消息层 `retryAssistantCall`（按错误文本分类）+ 会话级 `auto_retry`（同一预算内 `continue()` 重跑）；OpenRouter/Vercel Gateway 的上游路由是把路由策略作为请求字段交给聚合服务执行；上下文溢出不重试、走"压缩一次并自动重试一次"。无跨 Provider 自动故障转移、无多 Key 池与轮询，细节见末尾小节。证据：主链确认（静态源码）。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)。

- **模型选择与解析**：模型保存在会话状态、以 `model_change` 条目落会话并回放恢复；`resolveCliModel` 支持 `--provider/--model`、`provider/model` 规范引用、裸模型 id（歧义报错或按唯一已认证 Provider 消歧）、部分匹配优先 alias 再取最新日期版本；`--models`/作用域支持 glob 模式与 `:thinkingLevel` 后缀；初始选择优先级为 CLI 参数 > scoped models > 设置默认 > `defaultModelPerProvider` 匹配首个可用 > 第一个可用模型。无本地语义路由（上游路由策略由聚合服务执行）。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。

- **连接检测与可观测性**：`checkAuth` 检查凭据完整性（存储/环境/命令源），CLI `pi auth check` 返回 ready/not_ready/invalid；用量与成本按模型价格表 `calculateCost` 计算，footer 展示 token/成本、`/session` 输出统计；`packages/telemetry` 是无 exporter、无全局 span 状态的 vendor-neutral 契约包，无会话数据上报路径。无独立真实连接测试入口（checkAuth 不发真实请求），细节见末尾小节。证据：静态源码确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)、[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)。

### 独特与差异化能力

以下能力卡保留[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)的证据状态。五个第三批候选中四个已由现有通用类目完整覆盖（归并已有类目），补查新确认的产品面是"会话数据生产与分享"。

- **会话数据生产与分享（研究轨迹聚类候选）**：`入口确认`（仓库内主链）/ `外部依赖`（发布端）。把真实 OSS 编码 Agent 会话变成可发布的训练/评估数据——根 README 设专门章节"Share your OSS coding agent sessions"，`docs/usage.md` 明确可用伴生工具 `badlogic/pi-share-hf` 发布为 Hugging Face 数据集用于"model, prompt, tool, and evaluation research"。仓库内主链（JSONL 会话树 → `/export` JSONL/HTML → `/share` Radius artifact，缺少凭据时回退私密 Gist）达静态源码确认；HF 发布一步位于仓库外（外部依赖，未验证），细节见末尾小节。建议以 `入口确认` 列入研究轨迹聚类候选，暂不单独计为主贡献。链接：[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/Pi-对话导出与分享调查笔记.md)。

- **已归并到现有类目的能力**（状态：`归并已有类目`，不重复展开）：
  - **自扩展 Agent harness**：扩展系统（registerTool、before_agent_start、custom 条目、Pi Packages）归并 Agent 工具/Agent 角色类目；harness 会话存储抽象在会话与消息管理笔记有交接记录。
  - **终端组件树**：pi-tui 差分渲染库是消息渲染器笔记核心内容。
  - **分支会话**：归并会话与消息管理类目（branch/createBranchedSession/forkFrom/branchWithSummary）。
  - **容器化**：README 与 `docs/containerization.md` 的三种模式（Gondolin 扩展、Plain Docker、OpenShell）是部署文档而非内置运行时，归并 Agent 工具/生成式输出类目。
  - 链接：[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)。

## 工程与基础设施摘要

**仓库分布**

- Pi 是按可发布能力拆包的 TypeScript monorepo，而非 GUI 客户端仓库；coding-agent、统一模型 API（ai）、TUI、agent runtime 四个包构成主体，server/client/protocol/session backend 提供可组合边界。Git 跟踪文件 1,366；可识别源码 1,176 文件 / 268,499 行；文档 97 文件 / 32,624 行；测试 500 文件 / 114,906 源码行（测试/源码比 42.5%，主要包都有独立测试区）；TypeScript 256,665 行（95.6%）。平台形态是 Node/Bun 可运行的 CLI/TUI、库和服务协议，无本仓原生桌面或移动 GUI；coding-agent 的 sandbox/container 文档包含 Linux 隔离方案，但那是可选执行边界。证据：Git 跟踪文件机械统计 + npm workspace/构建入口复核（未运行构建与测试）。链接：[仓库分布调查笔记](../仓库分布/Pi-仓库分布调查笔记.md)。

**应用界面基础设施**

- **自研 TUI 框架**：`packages/tui` 是差分渲染终端 UI 库（不采用 Ink/blessed/react），提供 regular 与 fullscreen 两种屏幕模式、overlay 栈和单焦点模型；常规选择器通过编辑器插槽替换显示（showSelector 把编辑器换成选择器组件），真正悬浮的 overlay 只用于 fullscreen 搜索框与扩展 API；渲染调度为 16ms 最小帧间隔节流 + 输入路径立即渲染。
- **反馈、主题与输入基础设施**：反馈分聊天区状态文本（showError/showWarning/showStatus，连续状态复用末行防刷屏）、fullscreen flash（Toast 等价物，仅 TuiAltScreen 提供）与 OSC 9;4 终端进度条三类；主题使用 JSON token + 全局单例（跨模块加载器共享），支持终端色彩降级（24bit/256 色）、var 引用与循环检测、`light/dark` 自动模式（三级终端主题检测：DSR 996/OSC 2031 通知、OSC 11 背景色、COLORFGBG 兜底）、自定义主题文件热重载；主题来源为内置、`~/.pi/agent/themes`、设置 themes 键、`--theme`、npm 包与扩展六路，选择走"预览不落盘、确认才持久化"。
- **键盘与剪贴板**：键盘由统一注册表管理（TUI 层 + coding-agent 层模块声明合并），支持 `keybindings.json` 用户覆盖与同键冲突检测，组件只经 `keybindings.matches` 消费不硬编码；剪贴板在 native 插件、平台命令与 OSC 52 之间多层回退，图片按 Kitty/iTerm2 能力渲染、无协议时文本替代；终端能力探测保守（tmux/screen 下关闭图片与 OSC 8 超链接）；错误兜底为进程级 uncaughtException 恢复终端与 EIO 紧急退出，渲染层超宽行写 crash log 后 throw，无组件级错误恢复。无主题市场/壁纸/字体/密度/圆角设置。
- 证据状态：静态源码核对（视觉/焦点/键盘/终端能力需运行验证）。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Pi-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)、[消息渲染器调查笔记](../消息渲染器/Pi-消息渲染器调查笔记.md)。

## 已知边界与待验证事项

**声明不符**

- 本汇总无"声明不符"项（0 项）；来源笔记未记载文档/注释与实现不一致且以可执行路径为准的案例。

**暂缓与外部依赖**

- **HF 数据集发布（暂缓）**：`badlogic/pi-share-hf` 不在本仓库，其读取格式、去重与推送行为未验证；"研究轨迹"闭环完整度依赖仓库外消费事实，本仓库只承担"生产与导出"侧，无法在本仓库验证。来源：[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/Pi-对话导出与分享调查笔记.md)。
- **Radius artifact 与 Gist 平台语义**：Radius 的组织可见 artifact 的实际访问范围、留存和删除路径，以及私密 Gist 回退路径的匿名可访问性、保留期与删除路径，都属于外部平台行为，需实际运行 `/share` 验证。来源：[对话导出与分享调查笔记](../对话导出与分享/Pi-对话导出与分享调查笔记.md)。

**未覆盖类目（仓库内本次未找到，按来源笔记检索范围表述）**

- MCP 客户端/协议实现（仅工具结果图片注释提及 MCP bridges 字样，无协议实现）。来源：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。
- 按工具/风险分级的常驻审批策略与确认框式授权 UI（审批仅 `beforeToolCall` 回调钩子，扩展未注册时工具直接执行）。来源：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)。
- 渠道配置编辑器与 Web/桌面端渠道管理（TUI 只处理凭据/模型选择/重载；仓库内无 Web/桌面 GUI，server/client 协议只有模型快照与会话操作）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。
- 跨 Provider 自动故障转移、多 Key 池与轮询（重试闭环在同一 Provider/模型内，`--api-key` 是临时运行时 key）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。
- 消息级搜索接入主路径（扫描器与 SQLite FTS5 后端独立存在，仅在本包测试中使用）；harness 搜索接口未接入 TUI。来源：[会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)、[独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)。
- 内置子 Agent 委托配置与 UI 层多 Agent 编排（子 Agent 仅由扩展经 `createAgentSession` 自建，无内置委托入口；单会话单 agent 循环，无多会话并行 UI）。来源：[Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)。
- 导出/分享无隐私提示、无脱敏：HTML/JSONL 原样携带 system prompt、thinking 全文、bash 命令与输出、文件路径与图片；Radius 分享还附加激活工具 schema。`/share` 前无内容确认或警告；来源笔记判断"隐私无护栏是有意为之还是疏漏，本次无从判断"。来源：[对话导出与分享调查笔记](../对话导出与分享/Pi-对话导出与分享调查笔记.md)。
- 独立"续写到消息末尾"入口（续写经分支/新消息）、`/system-prompt` 查看命令、消息就地编辑（历史追加型）、独立真实连接测试入口（`checkAuth` 不发真实请求）、`/settings` 之外无渠道级配置 UI。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)、[Agent 角色调查笔记](../Agent角色/Pi-Agent角色配置调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)。

**尚待运行观察的共性维度**

- 全部 13 篇来源笔记均基于当前代码快照，未运行应用、测试或真实模型请求；Pi 是完整本地主链，相关运行表现仍待在目标环境观察（口径见“完成度速览”）。
- TUI 视觉/键盘/焦点/IME/OSC 序列与图片能力/终端模拟器差异需运行验证；流式帧率、闪烁与长会话滚动性能未测量。
- `/share` 端到端 Radius artifact 流程与 Gist 回退流程（后者依赖本机 gh 与 GitHub 账号）、HTML 导出浏览器端行为（template.js）、`estimateTokens` 与真实计费偏差、压缩后模型侧多轮一致性、多实例并发写会话文件、sqlite 后端集成路径均未运行验证。
- 容器化模式（Gondolin/Docker/OpenShell）在仓库内仅有部署文档，未做运行验证；`/trust` 各入口对资源加载的完整影响未逐条验证。
- 与特色贡献统计的衔接：独特功能笔记建议将"会话数据生产与分享"以 `入口确认` 列入研究轨迹聚类候选，暂不单独计为主贡献；相关聚类与比较维度见[特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Pi-Agent工具调查笔记.md)：工具定义/注册/注入/协议/校验/编排/审批/执行边界/结果回注，MCP 未找到。
- [Agent 角色调查笔记](../Agent角色/Pi-Agent角色配置调查笔记.md)：角色数据模型、SYSTEM/AGENTS 文件链、提示词拼装、模型与生成参数、运行时可见性。
- [Chat 调查笔记](../Chat/Pi-Chat调查笔记.md)：端到端聊天主链、核心对象与状态权威、压缩/重试/分支/导出概览与横向对比索引。
- [Chat UI 调查笔记](<../Chat UI/Pi-ChatUI调查笔记.md>)：TUI 工作台、输入区与命令面板、会话选择器与搜索、树导航、fullscreen、状态行、steer/followUp 界面、bash 交互、退出。
- [LLM 渠道管理调查笔记](../LLM渠道管理/Pi-LLM渠道管理调查笔记.md)：Provider/Endpoint/凭据概念模型、配置与各管理入口、协议 Adapter、运行时选路、重试与故障转移、可观测性。
- [仓库分布调查笔记](../仓库分布/Pi-仓库分布调查笔记.md)：仓库形态与量级、语言与文档/测试分布、跨平台组织。
- [会话与消息管理调查笔记](../会话与消息管理/Pi-会话与消息管理调查笔记.md)：会话/消息/分支数据模型、JSONL 持久化与迁移、生命周期、列表搜索、一致性、绑定与导入导出。
- [对话导出与分享调查笔记](../对话导出与分享/Pi-对话导出与分享调查笔记.md)：HTML/JSONL 导出口径、导入往返、Radius artifact 与 Gist 回退分享、HF 发布交接、隐私与安全、测试。
- [对话请求与上下文调查笔记](../对话请求与上下文/Pi-对话请求与上下文调查笔记.md)：发送主链路、上下文拼装、token 估算与自动压缩、agentLoop 工具循环、流式事件、abort/重试/steer/followUp。
- [应用界面基础设施调查笔记](../应用界面基础设施/Pi-应用界面基础设施调查笔记.md)：自研 TUI 装配、overlay/浮层、通知与错误反馈、主题 token 体系、响应式、剪贴板/图片/键盘基础设施。
- [消息渲染器调查笔记](../消息渲染器/Pi-消息渲染器调查笔记.md)：终端组件树、事件驱动全量重建、Markdown/代码/LaTeX 管线、工具与附件节点、性能策略与扩展机制。
- [独特功能调查笔记](../独特功能/Pi-独特功能调查笔记.md)：会话数据生产与分享（研究轨迹候选）及归并项盘点、telemetry 契约说明。
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md)：输出协议与对象模型（G2）、文件写入与 diff、执行环境、持久化恢复、模型回流、生命周期与缺失项。
