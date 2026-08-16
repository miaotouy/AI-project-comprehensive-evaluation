# DeepSeek-Harness Agent 工具调查笔记

> 调查对象：`../../deepseek-harness`（重点 `packages/core/tools/`、`packages/core/agent-loop/`、`packages/core/session/`、`packages/core/system-prompt/` 与各 `packages/*/tool-*` 工具包）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：静态源码阅读；辅以仓库自带架构文档（docs/architecture.md、docs/subsystems/tools.md、docs/tool-catalog.md、docs/tool-execution-pipeline.md、docs/capability-seams.md 生成图）；未运行真实工具调用
>
> 调查范围：工具定义与注册、作用域与过滤、发现与注入、模型协议、参数校验、编排循环与并发、审批授权、执行边界、结果回注与 session log、guard 机制（timeout-policy、repeat-tool-reminder）、capability seam 与工具的关系、MCP 桥、Code Mode 旁路、UI 呈现纯函数；排除项：各工具包的执行细节、LLM adapter 内部映射、web UI 组件、headless/ACP 宿主侧
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的工具系统是建立在 vendored Cordis 插件框架上的注册-执行管线，核心是 `packages/core/tools` 提供的 `ToolRuntime`（`ctx.tools`）：

1. **工具是注册在内存 registry 中的代码对象**：`ToolDefinition` 由模型可见 schema 字段、强制 `output` 输出契约、`execute` 执行函数与若干可选回调（内容终结、超时声明、并发分类、UI 呈现）组成（`packages/core/tools/src/index.ts:221-288`）。注册即 effect，返回的 disposer 可卸载，无独立持久化实体。
2. **作用域是层链而非单一目录**：全局层加每个 agent 一个 scope 层（`ScopedLayers`）；agent 层注册同名 shadow 全局，restrict 的 allow/deny 只过滤继承面，自身层注册不受限；Code Mode 的 `run_code` 是保留传输。
3. **执行走固定管线**：策略瀑布（允许/拒绝/询问，询问经 `ctx.approval` seam 放行）→ 单调 guard → 围绕调度瀑布（超时等包装）→ 工具体 → 结果策略（接受/阻断/替换）→ 内容终结与最终通知。
4. **模型可见 ⟺ 已记录**：`tool/call` 在执行前落盘、`tool/result` 落盘，`deriveMessages` 从 session log 投影模型历史；canonical 规范值只存在于执行局部，不落盘。
5. **编排由 agent-loop 驱动**：调度器按 `executionMode` 分类（exclusive 屏障 / parallel 滚动池，默认并发 10），结果按模型顺序提交；abort 时未启动调用合成 `ABORTED_BEFORE_DISPATCH` 错误结果，保证回放有效。
6. **capability seam 三角色与工具的关系**：seam = Service Definition（声明接口）+ Provider（实现）+ Consumer（模型工具）；工具包只拥有 schema、校验与呈现，provider 可整体替换而模型可见 schema 不变。
7. **guard 机制**：timeout-policy 是 tools/execute 包装器，把声明的超时预算变成 `TOOL_TIMEOUT` 结构化错误；repeat-tool-reminder 是 post-execute 观察者，经 additionalContexts 注入重复调用提醒，只提醒不否决。
8. **UI 呈现是纯函数**：`presentCall`/`presentResult` 返回带 card 标签的渲染意图（通用/终端/diff/搜索/读取/网页六类卡片），live 流式与日志回放共用，与执行完全分离。

## 系统边界与总体调用链

一次完整工具调用从注册到执行到结果入日志：

```text
模型请求（request/header 携带 tool schemas，system prompt 含各 section）
  → llm/stream 流式返回 assistant 消息（含 tool-call 块，arguments 为原始 JSON 字符串）
  → step() 循环（agent-loop/src/agent.ts:339-401）
      session.append('tool/call', {callId, name, arguments})   ← 执行前落盘
      executeToolCalls（agent-loop/src/tool-calls.ts:59-101）
        executionMode 分类 → exclusive 屏障 / parallel 滚动池（默认 10）
        prepare: 参数解析物化冻结 → tools/pre-execute 瀑布 → 单调 guard → approval ask
        dispatch: tools/execute 瀑布（timeout 包装）→ 工具体 execute → 快照/校验/render
        finalize: tools/post-execute 瀑布 → finalizeContent → 物化
        tools/result emit（冻结最终结果）
        session.append('tool/result', {message, error?, meta?})  ← 结果落盘
        additionalContexts → 注入下一 step 的 inbox（FIFO）
  → 无更多 tool-call 或结果带 concludesTurn → step/end → turn/end
  → 下一请求 deriveMessages 从日志投影（tool/result 投影为 user-role 工具结果消息）
```

## 1. 工具定义、来源与注册

**定义接口**：`ToolDefinition` 是 pipeline 作者类型；`output` 声明规范输出契约（schema + 纯 render 投影 + 可选 presentationMeta）。工具 body 返回 lossless JSON 值，registry 先校验其符合 `output.schema`，再渲染成模型可见内容（`index.ts:1793-1823`）。

**defineTool**（`schema.ts:545-617`）：一等公民工具用统一 schema DSL 声明参数（`ValueSchemaSpec`，含标量、数组、对象、自由 json 与 oneOf 等节点），编译进受约束的 JSON Schema 子集，并用类型推断把参数与输出绑定到声明。execute 前先 `validateArgs`，失败抛 `ToolArgsError`（`INVALID_ARGS`）；UI 呈现与并发分类回调对回放场景做软校验，失败静默回退（触发通用呈现）而不抛错。

**注册 API**（`index.ts:946-1116`）：

- `register(definition)`：必填 output、校验 raw schema、timeoutMs 须为正有限数、保留名 `run_code` 拒绝注册；返回卸载 disposer。
- `restrict(filter)`：仅限 agent 作用域，allow/deny 以交集生效，不能命名 `run_code`，未知名字注册时失败。
- `guard(guard)`：注册单调守卫（全局或 agent 层）。
- `presentAs(mode)`：为调用 scope 声明 native/code/both 呈现模式，由 core/agent-tool-presentation 插件从 preset 行挂载（`presentation.ts` 词汇表在 core/tools，见 §7 UI 呈现）。

**工具来源清单**（base bundle 默认行与 opt-in 包，工具名可由 load-time config 改变，故文档以生成目录 tool-catalog.md 为准）：

| 包 | 模型可见工具 | 备注 |
|---|---|---|
| `@deepseek-ai/dsh-tools` | `run_code` | 保留传输，注册/限制均不可占用 |
| `dsh-tool-bash` / `dsh-tool-pwsh` | `bash` / `pwsh` | 按平台条件加载（win32 与排除互斥） |
| `dsh-tool-fs` | `read` / `read_image` / `write` / `edit` | `read_image` 无 attachments 服务时不注册 |
| `dsh-tool-fs-search` | `glob` / `grep` | 打包 ripgrep，经 ctx.subprocess |
| `dsh-tool-web` | `web_search` / `web_fetch` | fetch 默认关闭，provider 在 ctx.web |
| `dsh-tool-terminal` | `terminal_open/list/read/send/close/signal` | opt-in |
| `dsh-tool-skill` | `skill` | 加载 session skill 目录全文 |
| `dsh-tool-session-query` | `session_search` / `session_event_*` | opt-in，工作区授权 |
| `dsh-tool-todo` | `todo_write` | 会话状态 |
| `dsh-tool-goal` | `create/get/update_goal` | 执行时授权检查 |
| `dsh-tool-workflow` / `dsh-tool-ralph` | `workflow` / `ralph` | 工作流引擎 Consumer |
| `dsh-tool-jobs` | `job_list` / `job_output` / `job_kill` | 后台任务控制 |
| `dsh-tool-ask-user` | `ask_user_question` | 挂起等待人类回答 |
| `dsh-tool-subagent`(+fork) | `subagent` / `subagent_fork` | 每后端实例一个工具名 |
| `dsh-tool-subagent-control` | `send_message` / `interrupt_agent` / `list_agents` | 全局控制工具 |
| `dsh-tool-subagent-report` | `report` | 仅在连续子 agent 内注册 |
| `dsh-plan-mode` | `exit_plan_mode` | 计划模式出口 |
| `dsh-tool-str-replace-editor` | `str_replace_editor` | opt-in |
| `dsh-tool-lsp` / `dsh-schedule` | `lsp` / `schedule_*` | opt-in，来自生成目录 |
| `dsh-tool-cordis` | `cordis_define/run/stop/undefine/inspect_*` | 动态插件，opt-in |
| `dsh-mcp-client` | `mcp__<server>__<name>` | 运行时发现注册，见 §8 |

**capability seam 与工具的关系**：seam 是三角色契约，Consumer 通常就是模型工具——工具包只持有模型面（schema、校验、呈现），provider 决定执行位置（`docs/architecture.md:98-102`），同 seam 的 provider 可整体替换（如把文件、shell、子进程能力指向 E2B 远程沙箱）而模型可见 schema 不变。主要映射：

| Seam | Provider 实现 | 工具 Consumer |
|---|---|---|
| `ctx.fs` | fs-local / fs-sandbox / fs-e2b | tool-fs、tool-str-replace-editor |
| `ctx.shell` | bash-local / bash-sandbox / pwsh-local | tool-bash、tool-pwsh |
| `ctx.web` | web-search-*（exa/perplexity/deepseek）、web-fetch-http | tool-web |
| `ctx.subprocess` | subprocess-local / subprocess-e2b | tool-fs-search（rg）、bash、terminal 等 |
| `ctx.terminals` | terminal-bash | tool-terminal、tool-bash-persistent |
| `ctx.subagents` | spawn / fork / acp / codex / claude-code / dsh-sdk | tool-subagent、tool-subagent-control、tool-ralph |
| `ctx.workflowEngine` | workflow-worker-thread | tool-workflow、tool-ralph |
| `ctx.jobs` | jobs-local | 后台 bash/PTY/子 agent + tool-jobs 控制 |
| `ctx.userQuestions` | UI 前端提供 | tool-ask-user |
| `ctx.sessionQuery` | session-query-sqlite | tool-session-query |
| `ctx.skills` | skill-filesystem、skill-badge | tool-skill |
| `ctx.approval` | acp（answerer）等 | tools registry 的 ask 决策 |
| `ctx.sandbox` | sandbox-local | （无直接模型工具，供 bash/fs/terminal provider 消费） |

## 2. 工具发现、过滤与注入

**schema 装配**：ToolRuntime 构造时经 `ctx.systemPrompt.tools()` 注册提供者（`index.ts:832`），每次 prompt assembly 按调用 scope 投影。`schemas()` 只输出白名单字段 name/description/parameters，执行与呈现回调永不上模型请求（`index.ts:1256-1267`）。

**注入路径**：装配入口 `ctx.systemPrompt.assemble` 产出含 tools 数组的 `PromptAssembly`；loop 在 preStep 组装、buildRequest 把工具 schema 写入请求头并随 llm 请求发出（`agent.ts:230,462-490`）。`toolOrder` 配置可定顺序，缺省按字典序（`system-prompt/src/index.ts:164-178`）。

**作用域过滤**：`view()` 单次层遍历解析可见集（`index.ts:1152-1193`）：继承面为全局层加祖先链，同名条目就近覆盖，restriction 以交集过滤继承面，自身层注册不受限；Code Mode 呈现时在过滤面之外追加 `run_code` 传输。

**token 控制**：未找到工具级 token 预算或 schema 自动裁剪；工具描述与参数 schema 直接进请求。

## 3. 模型调用表示与 Provider 适配

传输结构是原生 tool-call 块（`ToolCallBlock`，`llm/src/types.ts:77-93`）：id + 工具名 + 模型产出的原始 JSON 参数字符串，落盘与传输都不改原文。模型可见 schema 是 `ToolSchema`（name/description/parameters 三字段，`types.ts:312-317`）；适配层位于 llm seam（`llm/stream` 流与 ContentBlock 词表），adapter（如 llm-deepseek）把词表映射到厂商协议，本轮未深入其内部映射。

Code Mode（`index.ts:980-1001`、`code-mode.ts`）：配置 native/code/both 三种呈现——native 发送全部可见 schema；code 只发 `run_code` 并附加 `tools:sdk` 生成的 SDK 提示段（TypeScript 与 Python 渲染器）；both 两者都发。运行时的语言决定 run_code 的 schema 文案与 SDK 段。

## 4. 参数解析、校验与错误处理

循环层把参数原始 JSON 字符串解析为对象（失败保留原文，空输入映射 `{}`），并在进入策略管线前做 lossless 快照与冻结（`tool-calls.ts:104-110`、`index.ts:1412-1416`）。参数一经物化不可改写，保证历史、审计、UI 与执行四方一致。

校验位置：

1. `defineTool` 包装的 execute 内 `validateArgs`（`schema.ts:568,585-589`）——失败抛 `ToolArgsError`（`INVALID_ARGS`）。
2. 输出侧 `createSuccessResult` 对 body 返回值校验 `output.schema`——失败抛 `ToolOutputError`（`INVALID_TOOL_OUTPUT`）；render/presentationMeta 投影异常同样转为输出错误。
3. 未知工具：`ToolNotFoundError`（`UNKNOWN_TOOL` 结构化错误）；code collapse 拒绝的直接调用也在策略管线之前被拒为 `UNKNOWN_TOOL` 并附带正确调用路径。

失败语义：一切错误（校验失败、未知工具、监听器抛错、输出非法）都物化为 isError 工具结果回注给模型（"Error: ..." 文本 + 结构化 error.info），回合不中断，模型可修正重试。

## 5. 编排循环、并发与终止条件

**turn/step 结构**：step 是「一个模型请求 + 它请求的工具执行」，`step()` 内 while 循环直到消息不再含 tool-call 块或结果带 `concludesTurn`（`agent.ts:393-399`），每轮重新组装请求并落盘 step 起止事件；turn 在无待处理输入时关闭，`agent/turn-stopping` 瀑布可提前终止。

**调度器**（`tool-calls.ts:59-246`）：

- 并发分类：`executionMode` 只有 `isConcurrencySafe` 精确返回 true 才并行，否则 exclusive（fail-closed）。
- exclusive 调用形成屏障单独执行；parallel 用滚动池，池上限 `maxParallelToolCalls`（默认 10，`constants.ts:6`）。
- 池内后启动的调用在启动前重新分类（注册变化可产生新屏障）；结果与附加上下文按模型顺序提交（`commitReady` 只推进连续槽位）。

**abort 语义**：中止停止补池、排干已启动调用（不放弃其 promise，quiescence 后结算）、未启动调用逐个落盘 tool/call 并合成 `ABORTED_BEFORE_DISPATCH` 错误结果，保证回放有效（`tool-calls.ts:237-259`）。

**终止与超时**：终止依赖模型 stop 原因、max-tokens 粘性、`concludesTurn` 标记与 turn-stopping 瀑布；源码未发现显式迭代上限。超时通过工具声明的 `timeoutMs` 由 timeout-policy 包装器实现（见 §6 guard 机制）。

## 6. 审批、授权与执行边界

**审批发生在 registry 执行端**：策略瀑布返回 ask 决策时，`serviceAsk` 经 approval seam 发起 `approval/request` 瀑布（`index.ts:1689-1729`）。唯一放行结果是 `allowed-once`；拒绝、取消、通道不可用都转为可区分的拒绝原因，没有审批服务或调用无 agent 时也拒绝。每次问答以 `approval/asked` 与 `approval/decided` 事件成对落盘，属日志审计而非模型历史（`user-approval/src/index.ts:36-58`）。

**策略粒度**：会话级审批策略只有 ask 与 never 两种取值，never 下一切请求确定性拒绝；permission-presets 预设（workspace-write、danger-full-access）同时捆绑沙箱模式与审批策略（`cordis.patch.yml:198-205`）；per-agent 守卫与策略瀑布监听器可做更细粒度的工具级判定。

**执行端落地**：拒绝与询问决策最终都由 registry 在分发前物化为错误结果，UI 只作为审批问答的应答方参与，执行端不存在二次放行缝隙；单调守卫只能拒绝不能放行，监听器顺序无法翻盘。

**guard 机制两个实例**：timeout-policy 是 tools/execute 瀑布的包装器——工具声明 `timeoutMs` 时替换 signal 施加截止时间，计时器胜出时把结果换成 `TOOL_TIMEOUT` 结构化错误（`packages/guard/timeout-policy/src/index.ts:55-80`）。

repeat-tool-reminder 挂在 tools/post-execute：按 agent 维护连续相同调用的链（参数规范化为键），命中配置阈值（默认 3/5/8）时经 additionalContexts 注入温和或详细提醒；只观察不否决，用户介入会重置链（`packages/guard/repeat-tool-reminder/src/index.ts:162-233`）。

**执行边界**：工具与 provider 同进程执行；文件、shell、子进程能力以 seam 提供者抽象（本地/沙箱/E2B 后端可互换）。tool-fs 逐调用解析沙箱策略，并经 fs 事件门（写入意图、编辑意图、已观察三种事件）配合读改写策略。个别工具在执行时自带授权检查：tool-goal 要求调用者处于根 agent 的开放回合且当前回合含人类来源输入（`tool-goal/src/authority.ts:50-108`）。

## 7. 结果回注、执行状态与恢复

**结果契约**：`ToolExecutionResult` 是 isError 判别联合：成功结果携带执行局部的规范值、模型可见内容与可选 meta/additionalContexts/concludesTurn；失败结果携带结构化错误（消息与可选身份码）。meta 是工具私有展示负载（如文件工具的结果期 diff），随日志落盘供回放复现。

**持久化**：durable `tool/result` 事件只保存模型可见消息、结构化错误身份与 meta——规范值明确不落盘（`index.ts:556-566`），回放能复现呈现但不能重建中间值。会话不变式要求结果必须对应本 step 先落盘的 `tool/call`（`packages/core/session/src/invariant.ts:122-140`）。

**模型历史**：`deriveMessages` 从有序 surface 投影模型历史，surface 只含三类消息事件：user/message、assistant/message、tool/result（`session/src/index.ts:726-747`）。工具结果消息是 user 角色、内容为单个 tool-result 块、source 携带 callId（`llm/src/message.ts:152-241`）——这就是"模型可见 ⟺ 已记录"不变式的落点：新增模型可见输入必须新增 session 事件类型。

**附加上下文与长度控制**：工具体内 `deferContext` 与 post-execute 决策附带的 additionalContexts 在批次全部结算后按 FIFO 注入下一 step（`agent.ts:395-399`）。超长结果由 base bundle 的 spill-policy（默认 50KB 内联上限）与 tool-result-pruner 在 post-execute/compaction 阶段改写，本轮未深入其实现（`cordis.patch.yml:346-365`）。

**恢复**：session log 是 append-only 日志，重启可重建历史；进行中的工具执行不持久化，进程退出后不恢复执行现场（恢复后历史工具结果完整可用）。

**UI 呈现**：工具的 UI 呈现与执行完全分离——`presentCall`/`presentResult` 是只依赖参数的纯函数，返回带 card 标签的渲染意图（通用/终端/diff/搜索/读取/网页六类卡片），live 流式与日志回放共用同一份结果（`tools/src/presentation.ts:46-140`）。呈现回调与执行函数同列在 `ToolDefinition` 上，但 schema 投影白名单保证它们永不上模型请求。一个易混淆点：渲染意图词汇表位于 core/tools 的 presentation.ts，而 core/agent-tool-presentation 插件只负责为 preset 行声明 agent 的工具呈现模式（调用 `presentAs`），本身不渲染任何卡片。

## 8. MCP、插件、Skill 与子 Agent

**MCP**（`packages/mcp/mcp-client`）：每个插件实例连接一个服务器（stdio 子进程或 streamable-http 两种传输），插件激活阻塞到初始连接与工具发现完成。工具经两阶段换代同步注册——先全量取服务器工具列表并构建定义，成功后整体替换上一代注册，注册冲突回滚为零工具（`tools.ts:128-174`）。模型可见名按 `mcp__<serverName>__<rawName>` 生成，受 64 字符与字符集约束，发生改写时追加身份哈希防止不同服务器工具名碰撞（`tools.ts:96-102`）。调用时发服务器原始名；服务器返回 isError 时执行器抛错，转入常规工具错误回注。

**插件自举**：tool-cordis 让模型定义与运行动态 Cordis 插件（刻意 opt-in，不在任何 shipped tree）：运行中的包可注册额外模型可见工具，工具集变化经变更请求头日志记录。

**Skill**：Skill 是文本侧能力：会话级 skill 目录以 catalog 形式上下文注入（source 标记 skill-catalog），模型用 skill 工具按名加载全文，不是函数式工具注册。

**子 Agent 与旁路**：子 agent 由 tool-subagent（两个后端分别注册）、全局控制工具组（发消息、中断、列列表）与子 agent 内注册的 report 工具构成闭环。Code Mode 是主要旁路面：code 呈现下模型直接调用只能命名 `run_code`，程序内 SDK 子调用带 parent 令牌走完整守卫管线并逐条落盘 code-dispatch 事件；该日志副本可被瀑布改写，但程序收到的值与模型可见结果不变。

## 9. 设计取舍与已确认边界

- **一切皆插件，注册即 effect**：无特权核心；工具注册、restrict、guard 与呈现模式都是配置行可替换的 effect，卸载自动撤销。
- **执行与呈现分离**：呈现函数是 args/result 的纯函数，live 与回放共用；UI 只能消费 card 意图，不能干预执行。
- **规范值不落盘**：控制日志体积，代价是回放无法重建中间值。
- **参数不可改写**：策略层不支持改写参数，保证历史、审计、UI 与执行四方一致。
- **单调 guard + 失败关闭的审批**：guard 只能拒绝；审批通道缺失或不可答时默认拒绝。
- **code collapse 在策略管线之前终结**：被折叠的直接调用不让 pre-execute/审批/guard 观察到，避免"被审批后必然失败"的调用进入审批面；未知工具则保留进入策略管线，让监听器看到每个到达的名字。
- **无工具级 token 预算，未发现显式迭代上限**：长尾终止依赖模型停止原因、结论标记与用户中断，上下文压缩兜底。
- **文档与实现一致性**：tool-catalog 等目录为生成并启动验证（boot 各工具包读取真实 schema），工具名可配置（如 tool-subagent 的 toolName），说明文档是运行期快照而非静态抄写。

## 10. 未验证事项

- 未运行真实工具调用：流式 chunk、并行调度时序、timeout/abort 的实际行为均未实测。
- MCP 端到端（连接、重连、注册冲突回滚、task-based 拒绝）未实测。
- tool-terminal、tool-session-query、tool-lsp、schedule、plan-mode、spill-policy、tool-result-pruner 等包的执行细节未逐包深入。
- run_code/Code Mode 运行时（code-runtime-worker-thread）未调查。
- approval 的 ACP answerer、headless 模式、web UI 如何消费 ToolCallView/ToolResultView（属消息渲染器类目）未覆盖。
- LLM adapter 内部如何把 ToolSchema 映射到厂商 tool 协议未验证。

## 11. 关键源码索引

- `packages/core/tools/src/index.ts`：ToolDefinition（221-288）、注册/restrict/guard/presentAs（946-1116）、view 解析（1152-1193）、wireSchemas（980-1001）、execute 全管线（1342-1863）、serviceAsk（1689-1729）、createSuccessResult（1793-1823）
- `packages/core/tools/src/schema.ts`：schema DSL、defineTool（545-617）、validateArgs（478）
- `packages/core/tools/src/code-mode.ts`：run_code 传输（20、80-130）
- `packages/core/tools/src/presentation.ts`：card 渲染意图词汇表（15、46-140）
- `packages/core/agent-loop/src/tool-calls.ts`：调度器（59-246）、tool/call 与 tool/result 落盘（262-289）
- `packages/core/agent-loop/src/agent.ts`：step 循环（332-401）、buildRequest（407-495）
- `packages/core/session/src/types.ts`：tool/call（279）、tool/result（291-297）
- `packages/core/session/src/surface.ts`：deriveEventMessage（83-114）
- `packages/llm/llm/src/message.ts`：ToolResultMessage（152-241）
- `packages/guard/timeout-policy/src/index.ts`：tools/execute 包装（55-80）
- `packages/guard/repeat-tool-reminder/src/index.ts`：post-execute 观察（162-233）
- `packages/mcp/mcp-client/src/tools.ts`：syncTools（128-174）、publicToolName（96-102）
- `packages/interaction/user-approval/src/index.ts`：approval/request 瀑布与策略（30-118）
- `packages/goal/tool-goal/src/authority.ts`：执行时授权（50-108）
- `packages/bundle/base/cordis.patch.yml`：shipped 工具行（198-451）
