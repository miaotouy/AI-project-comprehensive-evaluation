# OpenCode 已调查能力汇总

> 汇总对象：`opencode`（远端仓库 `https://github.com/anomalyco/opencode`）
>
> 汇总更新日期：2026-08-27
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时共 14 份单项目调查笔记（代码快照均为 `c2eacd72afc4a4984564c393e15ab30011057269`，dev 分支）；另引用 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)
>
> 汇总方法：阅读各来源笔记的"结论摘要"与关键章节，按功能主题合并重复能力，保留来源笔记的证据状态与边界表述，逐条链接来源；未进行新的源码调查
>
> 汇总范围：覆盖上述 14 个类目中与 OpenCode 相关的全部已调查能力；仓库分布、应用界面基础设施的结论单列于"工程与基础设施摘要"；不做跨项目横向比较，不填写其他项目的能力空格
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

OpenCode 是 Bun/TypeScript monorepo，交付 CLI/TUI、Web、桌面端、server、SDK、plugin 与 Slack 客户端。它以「服务端 SQLite 权威 + 事件发布 + 客户端投影」为会话数据核心，消息模型为 Session → Message → Part 三层、Part 共 12 种类型；模型请求主链为「发送入口 → SessionPrompt 处理循环 → 处理器 → AI SDK streamText」，工具循环整体让渡给 AI SDK 原生 tool_calls，opencode 侧承担参数校验、allow/ask/deny 审批、执行截断与 ToolPart 状态持久化。产品表面是 TUI（opentui + Solid）与 Web App（Solid + Kobalte + Tailwind）双渲染栈、桌面 Electron 复用 app 渲染层并经 sidecar 运行同一 server。生成式输出以真实文件系统为事实源（G4 可编辑工作区），撤销为整条消息粒度的 Git 快照回滚。V1 为生产主路径，V2 事件溯源架构双轨并存、迁移未完成。

## 完成度速览

| 证据状态 | 条目数 |
|---|---|
| 主链确认（静态证据/静态源码） | 23 |
| 静态源码确认 | 17 |
| 已确认能力合计 | 40 |
| 入口确认（未走通完整链路） | 4 |
| 归并已有类目 | 6 |
| 声明不符 | 0 |
| 暂缓 | 0 |
| 介绍候选 | 0 |

已确认能力 40 项占功能能力条目的约 91%，未闭合的入口确认 4 项约占 9%；归并已有类目 6 项为正常归类、不计入能力计数。功能能力正文只陈述已确认事实，异常与边界细节集中在文末"已知边界与待验证事项"。

口径说明：本汇总所有"主链确认/静态源码确认"均基于对当前代码快照的源码贯通，在编译型桌面应用或完整本地主链中视为完成交付态；"未运行验证"仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。全部来源笔记采用只读源码静态梳理方法，未运行构建与真实对话，因此"需运行验证"是方法学约束而非缺陷提示。

## 功能能力摘要

### 角色与上下文

- **Agent 角色配置体系**：Agent 是由配置构建的只读内存对象，本身不落库，持久化的只是 session 表上的 agent 名字引用；来源为 `opencode.json` 的 `agent` 字段与 `{agent,agents}/**/*.md`、`{mode,modes}/*.md` 角色文件（mode 强制 primary）。配置加载按十一步顺序合并（远程 well-known → 全局 → OPENCODE_CONFIG → 项目 → `.opencode/` → OPENCODE_CONFIG_CONTENT → Console/Org → 企业托管 → mode 并入 → OPENCODE_PERMISSION → 全局 tools），选择优先级为会话保存值 → default_agent → build → 列表第一个。内置 7 个 agent：build/plan（primary）、general/explore（subagent）、compaction/title/summary（primary+hidden）。`tools` 字段已废弃（仅布尔表、并入 permission）；无导入导出，唯一生成路径是 `opencode agent create`。证据状态：静态源码确认。[Agent 角色配置调查笔记](../Agent角色/OpenCode-Agent角色配置调查笔记.md)

- **system prompt 两段式拼装与指令加载**：第一段按 env（工作目录/平台/日期/引用）→ AGENTS.md 指令 → MCP 指令 → skills 顺序拼接，第二段由 `agent.prompt ?? provider 风格提示` 前缀后合并 user.system 与结构化输出提示；agent 自定义 prompt 完全覆盖 provider 风格模板。AGENTS.md 按全局 → 项目祖先链（AGENTS.md/CLAUDE.md，CONTEXT.md 已废弃）→ config.instructions 顺序加载，每条带来源头。指令加载与拼装链见 `src/session/instruction.ts`、`src/session/prompt.ts:1257-1271`、`src/session/llm/request.ts:56-66`。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/OpenCode-Agent角色配置调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 2 节

- **模型与生成参数解析**：生效顺序 `input.model ?? agent.model ?? currentModel(session)`，`currentModel` 依次查 session 表 model 字段、最近带 model 的 user 消息、`provider.defaultModel()`；参数合并顺序 temperature/topP 优先取 agent 值、`options` 按 base(provider) → model → agent → variant 合并。切换 agent 默认继承上一模型（V1），V2 `switchAgent` 不改 session.model。证据状态：静态源码确认。[Agent 角色配置调查笔记](../Agent角色/OpenCode-Agent角色配置调查笔记.md) 第 4 节、[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 6 节

- **上下文拼装、预算、压缩与溢出**：历史每轮从数据库重读，溢出判定 `count >= usable`（usable = 模型输入上限减 reserved，reserved 默认 min(20k, maxOutputTokens)）；compaction 是"重写历史"而非删除——把历史重排为 [compaction-user, summary-assistant, tail, continue-user] 四段、清空旧 tool 输出并标 `time.compacted`，压缩请求把选中历史按 [User]/[Assistant]/[Assistant reasoning]/[Assistant tool call]/[Tool result]/[Tool error] 六种前缀文本序列化拼进 summary 请求（不再经媒体剥离）。`filterCompacted` 重排供模型、`latest` 按 `time.created` 排序 id 仅作决胜。证据状态：主链确认（静态源码）；触发阈值未实测（见末尾小节）。[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 3 节、[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 1、9 节

- **按 agent 的 MCP/Skill 运行时过滤**：配置层无 per-agent 挂接字段，MCP 工具可见性与 Skill 可用性全部在运行时按合并后的权限规则过滤（`Permission.evaluate` 不为 deny）；工具最终可见性在请求组装时按 agent 权限与会话权限合并结果过滤。证据状态：静态源码确认。[Agent 角色配置调查笔记](../Agent角色/OpenCode-Agent角色配置调查笔记.md) 第 5 节

### 会话与消息

- **会话/消息/part 三层数据模型**：SQLite（`Global.Path.data/opencode.db`）是会话与消息唯一事实源；消息按 user/assistant 两种角色区分，Part 共 12 种类型（text/subtask/reasoning/file/tool/step-start/step-finish/snapshot/patch/agent/retry/compaction）且独立存表、读取时 `MessageV2.hydrate` 批量组装。ID 前缀分层：会话 `ses_`（降序、新会话在前）、消息 `msg_`、part `prt_`。ToolPart 状态机为 pending/running/completed/error，completed 可带 `time.compacted`。`snapshot` 字段是 git tree 哈希（回合级版本，非文件提交级）。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/OpenCode-Chat调查笔记.md)

- **事件即写入的持久化与客户端投影**：`updateMessage`/`updatePart` 本身只发布事件，DB 写入由事件投影器完成，事件顺序即持久化顺序；三类事件（message.updated / message.part.updated / message.part.delta）经 SSE 推送，Web App 以 16ms 周期批量合并增量后投影到 Solid store。流式落盘分三层：delta 发增量事件、完整 part 在 end 事件落库、tool part 状态迁移即时落库。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 2 节、[Chat 调查笔记](../Chat/OpenCode-Chat调查笔记.md)

- **会话生命周期**：创建经 `POST /session` → createNext 生成 ses_ id、slug 与默认标题（首轮后由小模型 `ensureTitle` 生成标题）；重命名、归档（`time.archived` 字段，列表默认排除）、删除（级联删子会话与消息、取消后台任务）各有端点；惰性创建（App 首次发送且无 id 时才调用 create）。V2 走 `POST /api/session`。证据状态：静态源码确认。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 3 节

- **消息编辑、删除、revert 与 fork**：删除消息/part 各有端点并发布 removed 事件；回退（revert）是整条消息粒度的文件回滚——定位目标、记录回退状态、按 PatchPart 从影子 git 仓库 checkout 恢复文件，下次 prompt 时 `revert.cleanup` 物理删除目标之后的消息/part，可 unrevert；目标与范围用 findIndex+slice 定位（不用 id 比较，兼容导入的非单调 id）。分支（fork）新建会话复制消息并重映射 parentID 与 tail_start_id，无消息树；无整体编辑消息端点，只能逐个 PATCH part；重试无独立端点，前端重试本质是再次发送。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 4 节、[生成式输出与运行时调查笔记](../生成式输出与运行时/OpenCode-生成式输出与运行时调查笔记.md) 第 6 节

- **列表、分页与搜索**：侧栏按项目目录查询、10 条递增分页；命令面板跨目录查顶层会话限量 50 条；消息分页用 base64url 游标 `{id,time}`、limit+1 探测、带 `Link: rel="next"`。搜索仅会话标题 LIKE 匹配，无消息内容全文搜索（见末尾小节）。证据状态：静态源码确认。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 5 节、[Chat 调查笔记](../Chat/OpenCode-Chat调查笔记.md)

- **附件与 Todo**：附件以 `data:` URL 内联在 FilePart.url 随消息持久化，无独立附件目录；MCP 资源结果附件同样内联（二进制有 mime 白名单与 10MB 上限）。TodoTable 主键 `(session_id, position)`，事务更新整表重写后按 position 重插并发布更新事件。证据状态：静态源码确认。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 2、8 节

- **Chat UI 双表面工作台**：TUI（opentui + Solid，键盘为第一交互协议，单页会话控制器）与 Web App（Solid + 虚拟化 timeline + Composer 区域）共享同一服务端会话、SQLite 与 SSE 事件流，UI 状态事实源是服务端事件流；生成状态只有 idle/retry/busy 三态。Web Composer 按需挂载提问、审批、待办、回退、追问等 dock；TUI 承担 shell 模式（`!` 进入）、自定义命令、双击 Esc 中断。桌面 Electron renderer 复用 `@opencode-ai/app`，窗口级差异仅草稿 SQLite 持久化与 last-active URL 恢复。证据状态：静态源码确认。[Chat UI 调查笔记](<../Chat UI/OpenCode-ChatUI调查笔记.md>)、[Chat 调查笔记](../Chat/OpenCode-Chat调查笔记.md)

- **发送、排队、流式反馈与停止**：Web 提交集中在 `createPromptSubmit.handleSubmit`，含命令、shell 与普通发送三条路径；`shouldQueue`（settings followup=queue 且 busy 且未被审批阻塞）排队进 followup dock、空闲补发。流式事件 16ms 批量 flush 后由 timeline 渲染，重试状态由 SessionRetry 组件展示；中断按钮直接调 `api.session.interrupt`（TUI 为双击 Esc，两次 5 秒内）。无参数级（temperature 等）发送前配置界面（静态推断不存在，见末尾小节）。证据状态：静态源码确认。[Chat UI 调查笔记](<../Chat UI/OpenCode-ChatUI调查笔记.md>) 第 3、5 节

- **消息操作、审批与提问交互**：用户消息底部 revert + copy、assistant 文本 part 底部 copy + meta（agent · model · 时长 · interrupted）；审批 Dock 提供"拒绝/始终允许/允许一次"三种回复（TUI 侧含 diff 预览）；提问 Dock 支持 Mark/Option 单选多选 + 自定义答案；todo Dock 提供隐藏/清空/打开/关闭视图动作。TUI 复制在 tmux 下同时 OSC52 直写与透传。证据状态：静态源码确认。[Chat UI 调查笔记](<../Chat UI/OpenCode-ChatUI调查笔记.md>) 第 6 节

- **消息渲染管线**：渲染核心独立成 `packages/session-ui` 包；markdown 管线为「marked 切块 → Web Worker 解析 + shiki 高亮（主题 OpenCode，无行号）→ 主线程 DOMPurify 清洗 → morphdom/增量 token span 写 DOM」，流式文本有 PacedMarkdown 节流（≤512 字符立即显示，否则 24ms 步进且在标点处截断）；列表用 `@tanstack/solid-virtual` 虚拟化（overscan 50、行复用、自动滚动），katex 支持、Mermaid 不支持、无行号。工具组件经 ToolRegistry 注册 14 个，连续上下文工具（read/glob/grep/list）合并为一个 context 组渲染。证据状态：静态源码确认。[消息渲染调查笔记](../消息渲染器/OpenCode-消息渲染调查笔记.md)

- **草稿与现场恢复**：Web 草稿（文本与图片 blob）经 IndexedDB `opencode-drafts` 持久化，桌面端按窗口持久化到 SQLite `drafts.sqlite`，TUI 端仅进程内记录；会话与消息全量落库、再次进入经 SSE 订阅恢复（Web 断线 250ms 重连，桌面端额外恢复 last-active URL）。证据状态：静态源码确认。[Chat UI 调查笔记](<../Chat UI/OpenCode-ChatUI调查笔记.md>) 第 3 节、第 2 节

### 生成与创作

- **生成任务主链与状态机**：`api.session.prompt` 进入 `SessionPrompt.prompt`（revert.cleanup → createUserMessage 立即落库 → runLoop → processor → `LLM.stream`/AI SDK streamText），每轮从数据库重读历史；LLM 事件流经 toLLMEvents 转统一事件、processor 逐个更新消息/部件。每 session 一个 Runner，同会话串行（busy 报 SessionBusyError）、不同会话并行；状态机只有 idle/retry/busy 三态，无 queued/running/paused 字面状态。V2 先写 durable `session_input` 再 wake，由 SessionRunCoordinator 驱动 drain。证据状态：主链确认（静态源码）。[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 1 节、[Chat 调查笔记](../Chat/OpenCode-Chat调查笔记.md)

- **流式落库、最终化与异常收口**：文本/reasoning 的 delta 走 `updatePartDelta` 发增量事件、完整 part 在 end 事件落库；step-finish 累计 usage/cost、写 patch part、后台触发摘要；finish 事件收口写入 `time.completed` 与 finish 字段。中断/异常走 cleanup（未完成 part 置终态、tool part 标 "Tool execution aborted" + interrupted）、halt（错误归一化并发布 session.error），context overflow 在 auto compaction 开启时置 needsCompaction 而非直接失败。错误归一化为 8 种类型（AuthError/APIError/ContextOverflowError/AbortedError/StructuredOutputError/ContentFilterError/UnknownError/OutputLengthError）。证据状态：主链确认（静态源码）。[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 5、6 节

- **停止、中断、自动重试与续写**：停止链路为 abort 端点 → SessionPrompt.cancel → Runner.cancel 中断 fiber → onInterrupt 置 aborted 走 halt；被中断的 tool part 重放为 `[Tool execution was interrupted]` 错误回注，不重执行（避免重复副作用）。自动重试 `SessionRetry.policy` 覆盖 5xx/429/超时、已识别网络错误及“稍后重试/容量不足”提示，context overflow 不重试，上限 5 次、指数退避 2s 起带 0.25 随机抖动，尊重 retry-after 头；无独立重试端点，重试本质是重发。续写即同 session 追加，V2 有 `delivery: "steer"`（打断当前轮）与 `"queue"`（排队）。重试可能重复计费为静态推断（见末尾小节）。证据状态：主链确认（静态源码）。[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 7 节、第 1 节、[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 7 节

- **自动标题与摘要**：首轮 prompt 后 `ensureTitle` 调小模型生成标题（title agent 自带 temperature 0.5）；step-finish 后后台触发摘要并把回合 diff 预计算进用户消息 summary（`summary.diffs`）。证据状态：静态源码确认。[会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md) 第 3 节、[生成式输出与运行时调查笔记](../生成式输出与运行时/OpenCode-生成式输出与运行时调查笔记.md) 第 1 节

- **生成式输出与文件工作区（G4）**：模型通过结构化工具调用（write/edit/apply_patch）直接落盘文件，逐条工具调用成为带状态机的 ToolPart 写入 SQLite；回合边界用影子 Git 仓库（`Global.Path.data/snapshot/<project>/<hash>`）记录文件树快照并生成 PatchPart。文件系统是产物最终事实源、SQLite 是消息/Part 事实源、影子 git 是文件版本事实源；三份 diff 并存（工具卡 metadata diff / summary.diffs / vcs.diff 工作区实时）。用户侧投影为时间线工具卡片（内嵌 diff）、"最近回合"审查面板与 Git 工作区审查。模型经 read/glob/grep 读文件、edit 的 oldString 定位实现定向修改；跨回合对象身份由稳定 PartID 与快照哈希绑定。能力等级主体 G4，部分 G5 特征；无对象级托管、细粒度接受/拒绝与 CRDT，G0–G3 隔离可执行 Artifact 层未找到（见末尾小节）。证据状态：主链确认（静态源码）。[生成式输出与运行时调查笔记](../生成式输出与运行时/OpenCode-生成式输出与运行时调查笔记.md)

### Agent 运行时与外部协作

- **工具系统（Effect 服务 + AI SDK 原生 tool_calls）**：所有工具统一为 `Tool.Def`，经 ToolRegistry、SessionTools 包装后交给 AI SDK `streamText` 执行，工具选择、执行与结果回注由 SDK 承担，opencode 只消费 fullStream 事件。内置工具 16+1 个（shell/read/glob/grep/edit/write/task/webfetch/todowrite/websearch/skill/apply_patch/question/lsp/plan_exit/execute + invalid），按模型、provider、client 与实验 flag 过滤；另有自定义目录 `{tool,tools}/*.js|ts`、插件 `tool` hook、MCP 工具与 MCP 资源工具四类来源。Skill 是经 `skill` 工具按名加载的文本资源，不是工具注册来源。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md)

- **工具过滤、注入与参数校验**：`SessionTools.resolve` 把 registry + MCP + 资源工具包装为 AI SDK 工具表，`LLMRequestPrep.resolveTools` 按 user.tools 禁用与权限全量禁用集合二次过滤（`*` + deny 时整工具移除，edit/write/apply_patch 共享 edit 权限）；参数校验在 `Tool.wrap` 统一完成（Effect Schema 解码，失败转 `InvalidArgumentsError`，其 message 即模型可见的"请重写输入"回注）；AI SDK `experimental_repairToolCall` 修正工具名大小写、无法修复时重定向到 invalid 工具。插件事件 `tool.definition` 可改写 description/parameters。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 2、4 节

- **编排循环与终止条件**：`SessionPrompt.runLoop` 无限 while，上限为 agent 的 steps 配置（默认 Infinity），最后一轮注入 MAX_STEPS_PROMPT 强制收尾；只有 finish 既非 `tool-calls` 也非 `unknown` 且无未执行工具 part 时才退出。doom-loop 检测同一工具连续 3 次相同入参触发审批；`experimental.continue_loop_on_deny` 决定审批拒绝后是否继续循环；未设置 toolParallelism，单 step 内工具并行由 AI SDK 默认行为决定。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 5 节

- **审批授权与执行边界**：权限求值为 allow/ask/deny 三档规则，多条 ruleset 平铺后 `findLast` 匹配（后写优先），ask 阻塞在无超时的 Deferred 上等待 UI 回复（reply 支持 reject/once/always，always 写入 approved 并级联放行）。工具执行全部在 node 主进程内：shell 为普通子进程、无沙箱（默认 2 分钟超时 + `external_directory` 工作区外检查兜底，前置用 tree-sitter WASM 解析 bash/PowerShell AST 提取权限 pattern）；MCP stdio 服务器退出时递归杀进程树；code-mode 在独立沙箱解释器执行受限脚本。结果统一按默认 2000 行/50KB 截断落盘 `tool-output/`（7 天保留、每小时清理），超限提示用 Task/Grep/Read 接力。ask 无超时意味着 UI 不响应则调用永久挂起（见末尾小节）。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 6、7 节

- **结果回注与重放**：ToolPart 状态机 pending → running → completed/error，每次更新落库并发布事件；重放时 completed/error 工具转 tool-* result 消息、未完成 part 转 output-error 且 `[Tool execution was interrupted]`；`metadata.providerExecuted` 的调用重放时不要求再执行。媒体回注对不支持携带图片/PDF 的 provider 抽离为独立 user 消息。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 7 节

- **MCP 双运输与目录**：`local` 走 stdio 子进程，`remote` 依次尝试 StreamableHTTP → SSE，支持 OAuth；工具命名 `server_tool`，调用前全名审批；能力声明只含 roots，`tools/list_changed` 触发重拉并发布 ToolsChanged 事件；服务器 getInstructions 进系统提示 `<mcp_instructions>`。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 8.1 节

- **TaskTool 子 agent 与后台任务**：TaskTool 创建子会话（新 Session）执行子 agent，权限收窄继承（父会话 deny 规则 + external_directory 规则，再强制追加 todowrite/task deny），`subagent_depth` 限制嵌套（默认 1）；子会话的 assistant 错误或末尾工具错误会被转为父任务的失败结果。`background=true` 时立即返回、完成后向父会话注入合成 user 消息。后台任务经 BackgroundJob 服务（进程内注册表，重启丢失状态）；`POST /experimental/session/:id/background` 可把阻塞会话的同步子 agent 转后台继续，TUI 快捷键 ctrl+b。证据状态：主链确认（静态证据）。[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 8.3 节、[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 8 节

- **外部执行体与应用协作**：OpenCode 主要不是托管其他 CLI Agent，而是把自身 runtime 通过 HTTP/SSE、ACP、CLI、TUI、Web、Desktop 与 Slack 客户端暴露出去。外部客户端发现或启动 server（localhost、mDNS `opencode.local`、远程 URL），HTTP 创建/选择 session、SSE 订阅事件、prompt 写入、断线重连后 replay、必要时 steal 写所有权，cancel/revert/fork 回传服务端。身份经 HTTP 密码鉴权、sidecar 用户名密码与 CORS 白名单绑定；另有 PTY 终端 WebSocket attach（connect token + 一次性 ticket）与远程 TUI 控制接口（appendPrompt/submitPrompt/controlNext/controlResponse）。工具与文件权限由 OpenCode runtime 承担，外部宿主只经 ACP/HTTP 审批面参与放行。mDNS 与远端 workspace 路由为 `入口确认`，真实多客户端运行未实测（见末尾小节）。证据状态：主链确认（静态证据）。[外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenCode-外部执行体与应用协作调查笔记.md)

### 渠道与调度

- **Provider 运行时组装与凭据**：Provider 是「代码注册的模型目录 + 用户凭据/配置的运行时实例」的合成体，运行时按固定顺序组装 models.dev 目录、插件 hook、config `provider` 字段、环境变量、auth.json 凭据；内置 Provider ID 11 个（opencode/anthropic/openai/google/google-vertex/github-copilot/amazon-bedrock/azure/openrouter/mistral/gitlab）。凭据存 `~/.local/share/opencode/auth.json`（0o600 明文）不写 opencode.json，另有 SQLite credential 表明文 JSON；无加密、无系统 keyring、无 UI 打码。同 provider 多 Endpoint 不支持（config provider 为单对象），多端点需注册多个自定义 provider id；无多 Key 轮询、无跨 provider failover（见末尾小节）。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 1、3 节

- **模型目录三级数据源**：模型目录来自 `https://models.opencode.ai/api.json` 拉取与缓存，三级数据源为磁盘缓存 → 构建期快照（OPENCODE_MODELS_DEV）→ 网络，TTL 5 分钟、每小时刷新、文件锁防并发；`OPENCODE_MODELS_URL`/`OPENCODE_DISABLE_MODELS_FETCH` 可控制。元数据含 cost（tiers）/limit/modalities/status 等，`experimental.modes` 展开为 `modelID-mode` 变体；无硬编码内置清单。证据状态：静态源码确认。[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 4 节

- **协议适配与请求组装**：主路径为 AI SDK `streamText`（内置 BUNDLED_PROVIDERS 表 + 表外包名 npm 动态安装、`file://` URL 直接 import），另有 opt-in 的 native 协议实现（`packages/llm/src/protocols/`，仅 openai/opencode/anthropic 且非 OAuth 时经 `OPENCODE_EXPERIMENTAL_NATIVE_LLM` 切换，不支持则回退 AI SDK）；ollama/lmstudio/deepseek 等统一走 `@ai-sdk/openai-compatible`。请求参数经 ProviderTransform 输出 options/providerOptions/temperature/topP/maxOutputTokens/schema；Anthropic/Bedrock 家族自动 `cacheControl: ephemeral` prompt caching（可 `setCacheKey` 关）。无 `@`/`#`/`:latest` 模型语法（"latest"仅作排序权重）。证据状态：静态源码确认。[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 5、6 节

- **重试三层与故障边界**：重试分三层——会话级 `Effect.retry`（5xx/429/超时、已识别网络错误与容量提示，context overflow 不重试，上限 5 次、指数退避 2s 起带 0.25 随机抖动、尊重 retry-after 头）+ SDK 级 maxRetries + native 级 MAX_RETRIES=2；三层都不改变目标 Provider/模型/Key。错误归一化识别 context_length_exceeded/insufficient_quota 等映射为 ContextOverflowError/APIError。无多 Key 轮询、无跨 provider failover、无候选池与健康状态；登录流程无专门连接测试请求（仅插件 prompt 的 validate 回调与 GitLab discoverModels 真实调 API）；重试可能重复计费为静态推断（见末尾小节）。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 7、8 节

- **可观测性与用量成本**：usage/cost 按 model.cost tiers 乘 token 数算并投影到 session 表 cost/tokens 列，删除消息/part 回滚 usage；OTel 在 `OTEL_EXPORTER_OTLP_ENDPOINT` 时启用日志与 trace 导出；`packages/stats` 消费 tokens 聚合；重试状态经 SessionStatus 广播 `{type:"retry", attempt, message, action, next}`，UI 渲染倒计时卡片。Provider 日志只记 providerID/modelID 不含 key。证据状态：静态源码确认。[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 8 节

- **渠道管理入口覆盖**：配置文件可完整查看/新增/修改/启停（`disabled_providers`/`enabled_providers`）Provider 定义；CLI `providers list/login/logout` 管理凭据、`opencode models` 查看模型；TUI `/connect` 新增凭据；Web/桌面设置页列出已连接 Provider、内置支持 API Key/OAuth、V1 自定义表单可新增 Provider/Base URL/模型/Header。OAuth 授权由 server 端插件发起、浏览器只显示授权 URL。界面中已有内置渠道只能 Disconnect、不能载入表单编辑已保存定义，无 Provider 配置导入/导出、无保存后的通用连接测试请求（见末尾小节）。证据状态：静态源码确认（"未找到"按本次检查范围表述）。[LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) 第 2 节

- **多会话并发、排队与后台调度**：每 session 一个 Runner，同会话串行、不同会话并行；再次发送即续写；Web 客户端级排队（shouldQueue → followup dock → 空闲补发），V2 有服务端 `delivery: "steer"`/`"queue"`；子 agent 可后台运行、后台任务完成后结果经合成 user 消息回注。无全局"正在生成"汇总标记（界面按会话呈现运行状态）。证据状态：静态源码确认。[对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) 第 8 节、[Chat UI 调查笔记](<../Chat UI/OpenCode-ChatUI调查笔记.md>) 第 7 节

### 独特与差异化能力

- **能力一：多表面会话连续性（事件源同步 + 所有权接管）** — `主链确认`（静态证据）：headless server + 事件溯源同步（单写者、seq 全序、owner_id）+ `/sync` 的重放/接管（steal），TUI、Web、Desktop、WSL、局域网（mdns `opencode.local`）与云端 workspace 共享同一批会话与进行中的任务；断线按事件日志重放恢复，任一表面可接管继续。事件日志为唯一事实源。贡献统计建议：主贡献（F27 扩充计入理由）。（`packages/core/src/event/sql.ts`、`packages/opencode/src/server/.../handlers/sync.ts`、`cli/cmd/serve.ts`、`cli/cmd/attach.ts`、`packages/desktop/src/main/sidecar.ts`）[独特功能调查笔记](../独特功能/OpenCode-独特功能调查笔记.md) 能力一、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenCode-外部执行体与应用协作调查笔记.md)

- **能力二：CodeMode 受限 JS 编排** — `主链确认`（静态证据）：模型经 `execute` 工具用一小段受限 JavaScript（分支/循环/并行/数据变换）编排多个 MCP 工具，解释执行在 `packages/codemode`（无 eval 解释器、plain-data 边界、调用次数/超时/输出字节上限、并发上限 8、busy-loop 中断、子调用逐条审计）；是直接工具调用、任务分派之外的第三类执行范式。贡献统计建议：新能力族（F43）。（`packages/codemode/`、`packages/opencode/src/tool/code-mode.ts`）[独特功能调查笔记](../独特功能/OpenCode-独特功能调查笔记.md) 能力二、[Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md) 第 8 节

- **能力三：会话档案闭环（导出/脱敏/分享/PR 续作）** — `主链确认`（静态证据）：整段会话导出为可移植 JSON（CLI `export --sanitize` 全字段脱敏；Web 等价下载）、从文件或 `opncd.ai/share/...` 链接导入重建、远端实时分享同步（`share-next.ts` 去抖批量 POST）、PR body 内嵌分享链接供 `opencode pr` 自动导入续作——会话成为可流动的"档案对象"。分享服务端在仓库外（本地只有 HTTP 客户端与 session_share 表，见末尾小节）；`--sanitize` 仅 CLI 导出、分享与 Web 导出无脱敏；`config.share: manual/auto/disabled` 与 `OPENCODE_DISABLE_SHARE` 可关闭。贡献统计建议：新能力族（F44 研究轨迹聚类第三样本）。（`cli/cmd/export.ts`、`cli/cmd/import.ts`、`cli/cmd/pr.ts`、`share/share-next.ts`）[独特功能调查笔记](../独特功能/OpenCode-独特功能调查笔记.md) 能力三、[对话导出与分享调查笔记](../对话导出与分享/OpenCode-对话导出与分享调查笔记.md)

- **能力四：ACP 服务端** — `主链确认`（静态证据）：让 Claude Code、Cursor、Gemini CLI 等 ACP 宿主把 OpenCode 当 agent 调用——new/load/resume/fork session、prompt、cancel、权限回调、MCP 能力广播；与自身 GitHub Copilot 渠道构成"消费 Copilot + 服务 ACP"的双向互操作。贡献统计建议：辅助贡献（F45）。（`packages/opencode/src/acp/service.ts`、`cli/cmd/acp.ts`、`acp/permission.ts`）[独特功能调查笔记](../独特功能/OpenCode-独特功能调查笔记.md) 能力四、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenCode-外部执行体与应用协作调查笔记.md)

- **已归并到现有类目的能力**（[独特功能调查笔记](../独特功能/OpenCode-独特功能调查笔记.md) 标记 `归并已有类目`，不重复展开）：
  - build/plan/general Agent、`agent create`：归并 Agent 角色类目
  - Git 快照 + 会话级撤销/回退（snapshot track/restore/revert + session/revert）：归并生成式输出与运行时类目（统计 F24 既有主贡献，文件/Git 事实源与回滚闭环）
  - 后台子代理 + 任务续作：归并 Agent 工具类目（统计 F30 既有辅助贡献）
  - Skill 市场（远程 index.json）、权限规则集与 question 对话框、命令系统（/init、/review、自定义命令）：归并 Agent 工具、Chat UI 类目
  - GitHub Copilot 渠道、多 Provider（Zen/xAI OAuth）：归并 LLM 渠道类目
  - V2 事件溯源会话核心（Context Epoch/压缩 checkpoint、durable admission inbox）：归并会话与消息管理、对话请求与上下文类目

- **能力等级与特色统计口径**：主链确认的四个候选均为静态证据；独特功能笔记明确"不重复计数"Git 快照回退、后台子代理、Skill/权限/渠道归并项。贡献统计中 OpenCode 的计入条目见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)（F27 多表面连续性、F43 CodeMode、F44 会话档案、F45 ACP 服务端，以及 F24/F30 既有贡献）。另有 4 项 `入口确认` 候选（Session Review、Git worktree、mDNS 局域网发现、云端 workspace 同步）未走通完整链路，详见末尾小节。[特色功能贡献统计](../AI客户端特色功能贡献统计.md)

## 工程与基础设施摘要

- **仓库分布**：以 `packages` 为中心的 Bun/TypeScript monorepo，同时交付 CLI/TUI、桌面、Web、server、SDK、plugin、console 与共享 UI。Git 跟踪文件 6,510 个、可识别源码 3,580 文件 / 721,582 行（TypeScript 93.5%）、文档 820 文件（主要来自文档站及其多语言副本）、测试 955 文件。源码规模最大的是核心 `packages/opencode`（762/176,788）与 `packages/app`（642/172,930），其次 `packages/core`、`console`、`ui`、`tui`、`sdk`、`session-ui`、`stats`、`llm`。CLI/TUI 通过同一核心包支持 Windows/macOS/Linux；桌面应用在 `packages/desktop`，Web UI 在 `packages/app`/`packages/web`，是独立入口共享包而非同一外壳。证据状态：Git 跟踪文件机械统计 + Bun workspace/构建配置复核。[仓库分布调查笔记](../仓库分布/OpenCode-仓库分布调查笔记.md)

- **应用界面基础设施（双表面两套栈）**：TUI 基于 opentui + Solid（无 React/Ink），自建单栈对话框栈（single-flight replace、Esc/Ctrl+C 双键关闭、焦点归还）、单条 Toast、崩溃屏与启动加载；Web 基于 Solid + Kobalte + Tailwind CSS 4 + solid-sonner，DialogProvider 命令式弹窗栈（owner 继承 + 100ms 退场）、Toast 双代按新旧布局静态切换、通知中心（localStorage 持久化、30 天 TTL）+ 浏览器 Notification 系统通知。主题运行时解析：TUI 从终端 palette 派生 system 主题（内置 33 JSON + 插件 + 自定义文件）、Web 从 37 个内置 DesktopTheme JSON 生成 CSS 变量并缓存 localStorage、preload 脚本防首屏闪烁；库级 registerTheme/loader.ts 主题 API 存在但 App 未接线。桌面 Electron 主进程维护窗口注册表/几何恢复/原生菜单/无响应恢复；renderer 复用 `@opencode-ai/app`、sidecar 进程内运行同一 opencode server。无托盘与全局快捷键，无主题市场/壁纸/自定义 CSS，fontSize 设置暂无消费方，TUI 无上下文菜单，移动端 768px 硬断点（见末尾小节）。证据状态：静态源码核对。[应用界面基础设施调查笔记](../应用界面基础设施/OpenCode-应用界面基础设施调查笔记.md)

## 已知边界与待验证事项


### 暂缓与外部依赖

- 分享服务端在仓库外（默认 `https://opncd.ai`、enterprise/console 的 `/api/shares`），本地只有 HTTP 客户端与 `session_share` 表；分享服务的行为（认证、保留期、data 端点、公开页渲染、URL 可枚举性）无法从本仓库确认。
- cloud/enterprise 面（`packages/console`、control-plane 服务端侧）只核到客户端握手与同步层，云端托管细节为外部服务边界，不进入特色统计。
- 独特功能四个候选均为静态证据、未运行验证：多设备 steal/重放、mdns 局域网发现、云端 workspace 同步、CodeMode 真实模型编排、分享服务与 PR 续作、与真实 ACP 宿主互通均未实测。
- 分享/PR 续作存在静态发现的格式不一致：`pr.ts` 只匹配 legacy 格式 `opncd.ai/s/<id>`，而 import 端 URL 解析只接受新格式 `/share/<slug>`，GitHub Actions 张贴的 `opencode.ai/s/<id>` 两个正则都不匹配（行为未运行验证）。

### 入口确认未闭合

- Session Review 行内评论：session-ui review 组件与 review.txt 模板存在，"评论→修改"的端到端服务端闭环未逐点核对，不单独提案。
- Git worktree 隔离工作区：worktree/index.ts + control-plane worktree 适配器存在，作为多表面会话连续性的支撑机制，资源回收语义未展开，不单独提案。
- mDNS 局域网发现与云端 control-plane workspace 同步：`入口确认`，真实局域网发现与云端同步未运行验证。
- 外部执行体类目的 mDNS 与远端 workspace 路由同样为 `入口确认`，完整部署边界（网络暴露、远程 server 鉴权、云 control-plane）未展开，不能因 localhost 默认路径推断所有部署均为本机可信。

### 未覆盖类目（已确认边界）

- 无消息内容全文搜索，仅会话标题 LIKE 匹配（检查范围：opencode/core/app 三包未发现对消息/part 内容的全文查询）。
- 无整体编辑消息端点，只能逐个 PATCH part；无参数级（temperature 等）发送前配置界面（静态推断不存在）。
- 无 shell 沙箱（普通子进程，靠权限审批 + 外部目录检查 + 超时兜底）；审批 ask 无超时，UI 不响应则调用永久挂起。
- 无 Agent/Provider 配置导入导出（CLI export/import 只处理会话）；界面中已有内置渠道只能 Disconnect、不能载入表单编辑已保存定义；无保存后的通用连接测试请求；同 provider 多 Endpoint、多 Key 轮询、跨 provider failover 均不支持。
- 生成式输出无 hunk 级接受/拒绝、冲突解决或 CRDT；无 artifact/canvas/notebook/iframe 隔离运行时；工具参数流式中间态不落盘。
- 界面基础设施无主题市场/壁纸/自定义 CSS、fontSize 设置暂无消费方、TUI 无上下文菜单、移动端 768px 硬断点、桌面无托盘与全局快捷键。

### 共性未验证

- 全部来源笔记均未运行构建、真实对话或真实 Provider/模型请求；UI 视觉、键盘可用性、无障碍、流式体验与跨平台行为均为静态代码结论。
- V2 事件溯源链路（session_input/event 表、projector、run-coordinator、drain）未运行验证；post-crash continuation recovery 明确标注为未来工作。
- 附件 data URL 在超长上下文中的 token 成本、`part_text_accum_delta` 断线重连与事件乱序行为、重试可能重复计费、快照跨重启 diff/revert 有效性（受 7 天 prune 影响）、上下文压缩触发阈值均未实测。
- code-mode 沙箱隔离强度、MCP `tools/list_changed` 热重连、npm 动态安装在离线/代理环境的行为、AI SDK 内部工具并行度与 `experimental_repairToolCall` 实际行为未实测。
- 来源笔记的调查对象路径此前存在不一致（改名前的 `E:\works\git\opencode` 本地不存在），已统一为远端链接 `https://github.com/anomalyco/opencode`；不影响结论。
- 本次汇总的 14 份来源笔记文件均存在且"结论摘要"章节完整可识别，无缺失或无法识别的情况。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/OpenCode-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/OpenCode-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/OpenCode-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/OpenCode-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/OpenCode-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/OpenCode-会话与消息管理调查笔记.md)
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenCode-外部执行体与应用协作调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/OpenCode-对话导出与分享调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/OpenCode-应用界面基础设施调查笔记.md)
- [消息渲染调查笔记](../消息渲染器/OpenCode-消息渲染调查笔记.md)
- [独特功能调查笔记](../独特功能/OpenCode-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/OpenCode-生成式输出与运行时调查笔记.md)
