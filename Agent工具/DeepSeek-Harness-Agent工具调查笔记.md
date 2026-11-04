# DeepSeek-Harness Agent 工具调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/core/tools/`、`packages/core/tool-executor-native/`、`packages/core/tool-executor-ptc/`、`packages/core/agent-loop/`、`packages/core/system-prompt/` 与各 `packages/*/tool-*`、`packages/*/mcp-*` 包）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：静态源码阅读；辅以仓库自带生成文档（`docs/tool-catalog.md`、`docs/tool-execution-pipeline.md`、`docs/subsystems/tools.md`、`docs/capability-seams.md`）与 `docs/upgrade-guide/` 的迁移说明；未运行真实工具调用
>
> 调查范围：工具定义与注册、step 级工具准入、作用域与过滤、执行器缝隙与批次调度、模型协议、参数校验、审批与守卫、执行边界、结果回注与 session log、MCP 桥、PTC 旁路与 UI 呈现；排除项：各工具包的业务实现细节、LLM adapter 内部映射、Web 客户端渲染器实现、headless/ACP 宿主侧
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

工具系统是建立在 vendored Cordis 插件框架上的注册-执行管线，由 `packages/core/tools` 的 `ToolsService`（`ctx.tools`）持有注册表与执行器选择，执行本体则交给可替换的执行器插件：

1. **工具是注册即 effect 的代码对象**：`ToolDefinition` 由模型可见 schema、强制 `output` 输出契约（`schema` + 纯 `render` + 可选 `presentationMeta`）、`execute` 与若干宿主侧可选回调组成（`packages/core/tools/src/contracts.ts:26-101`）。`schemas()` 用显式白名单投影模型面字段，执行与呈现回调永不上模型请求。
2. **执行器是独立缝隙**：`ctx.tools.execute()` 把整个原始调用批次委派给最近的 scoped `ToolExecutor`；内置 native 与 PTC 两个执行器插件分别负责解析、调度、取消与 `tool/call`、`tool/result` 落盘（`packages/core/tools/src/executor.ts:64-85`、`packages/core/tool-executor-native/src/index.ts`）。
3. **工具可见性按 step 准入**：注册可带 `when` 条件，agent-loop 每步用 `ctx.tools.resolve()` 求值一次得到 `ResolvedToolSet`，该集合同时决定该步的模型声明、dispatch、PTC 绑定与嵌套调用；条件求值抛错以 `TOOL_ACTIVATION_FAILED` 结束回合。
4. **执行走固定管线**：`tools/pre-execute` 瀑布（allow/deny/cancel/ask）→ 单调 guard → `tools/execute` 环绕瀑布 → 工具体 → `projectContent` → `tools/post-execute` 瀑布 → `finalizeContent` → `tools/result` 通知（`packages/core/tools/src/pipeline.ts:190-420`）。
5. **模型可见 ⟺ 已记录**：`tool/call` 在执行前落盘、`tool/result` 落盘，均由执行器批次结算提交；`deriveMessages` 从 session log 投影模型历史。canonical 规范值只存在于执行局部。
6. **PTC 只剩一种呈现**：`run_code` 是保留传输名，PTC 执行器只向模型暴露它并附生成式 SDK；模型的直接调用必须命名 `run_code`，程序内子调用带 parent 令牌走同一守卫管线。
7. **审批在 registry 执行端**：策略瀑布返回 ask 时经 `ctx.approval` 发起一次性审批，只有 `allowed-once` 放行；守卫只能拒绝。
8. **Web 呈现由客户端派生**：工具定义仍可保留 `presentCall`/`presentResult` 纯函数呈现意图，但内置 Web 客户端不再消费该视图，改从原始参数、结果内容与持久化 meta 自行派生卡片（`packages/client/ui-tool/`）。

## 系统边界与总体调用链

一次完整工具调用从注册到执行到结果入日志：

```text
模型请求（request/header 携带 tool schemas，system prompt 含各 section）
  → llm/stream 流式返回 assistant 消息（含 tool-call 块，arguments 为原始 JSON 字符串）
  → 每步开头 agent-loop 求值准入：
      toolSet = await ctx.tools.resolve({ agent, modelSelection, signal })   ← 每步一次
      组装 section/tools 时经 tools provider → selected executor.describe(definitions)
  → step() 循环（packages/core/agent-loop/src/agent.ts:400-760）
      ctx.tools.execute({ calls, signal, agent, log: { turn, step }, toolSet })
        选中执行器（native 或 ptc），执行器负责：解析、物化、调度、取消、落盘
        prepare: 物化冻结参数 → tools/pre-execute 瀑布 → 单调 guard → approval ask
        dispatch: tools/execute 环绕瀑布（超时包装）→ 工具体 execute
        complete: projectContent → tools/post-execute → finalizeContent → tools/result
        batch 结算：session.append('tool/call' …) → session.append('tool/result' …)
        additionalContexts → 注入下一 step 的 inbox（FIFO）
  → 无更多 tool-call 或结果带 concludesTurn → step/end → turn/end
  → 下一请求 deriveMessages 从日志投影（tool/result 投影为 user-role 工具结果消息）
```

调度与落盘都从 agent-loop 移出：本地调度器位于 `packages/core/tools/src/batch.ts:50`，`tool/call` 与 `tool/result` 的追加同在该文件 `:236-264`；执行期间若 step 失败，agent-loop 用 `ToolCallRecovery` 补写已结算但未落盘的结果（`agent.ts:360-390`）。

## 1. 工具定义、来源与注册

**定义接口**：`execute` 只返回 lossless JSON 值，registry 校验其符合 `output.schema` 后调用纯投影得到模型可见内容。两个内容回调分工明确：`projectContent` 在 `tools/post-execute` 之前安装执行期准备好的文本与图片（`:49`），`finalizeContent` 是同步的最后一公里变换，对每个归一化结果恰好调用一次——包括绕过 post-execute 的管线失败（`:61`）。

**defineTool**（`packages/core/tools/src/schema.ts`）：一等公民工具用统一 schema DSL 声明参数与输出（标量、数组、对象、`json`、`oneOf`），编译进受约束的 JSON Schema 子集，并把参数与输出绑定到类型推断。`validateArgs` 失败抛 `ToolArgsError`（`INVALID_ARGS`）；输出非法抛 `ToolOutputError`（`INVALID_TOOL_OUTPUT`）。

**注册 API**（`packages/core/tools/src/index.ts`）：

- `register(definition, options?)`（`:128`）：必填 output、校验 raw schema、`timeoutMs` 须为正有限数、保留名 `run_code` 拒绝注册；`options.when` 声明 step 级准入条件（`:115-123`）。返回卸载 disposer。
- `restrict(filter)`（`:162`）：仅限 agent 作用域，allow/deny 以交集生效；空过滤器、未知名字、scope 本地名与保留传输名都会失败。
- `guard(guard)`（`:384`）：注册单调守卫；`checkGuards`（`:393`）在 pre-execute 与审批之后复查。
- `get`（`:239`）/`executable`（`:251`）/`definitions`（`:305`）/`schemas`（`:316`）：按 scope 与 step 准入解析可见与可执行定义。
- `setExecutor(executor)`（`:325`）：为当前 scope 提供执行器；未作用域的贡献即部署默认。
- `execute(input)`（`:375`）：把整批原始调用交给选中的执行器。

**工具来源清单**（base bundle 默认行与 opt-in 包；工具名可由 load-time config 改变，以生成目录 `docs/tool-catalog.md` 为准）：

| 包 | 模型可见工具 | 备注 |
|---|---|---|
| `dsh-tool-executor-ptc` | `run_code` | 保留传输，PTC 模式下唯一的模型直调工具 |
| `dsh-tool-fs` | `read` / `read_image` / `write` / `edit` / `apply_patch` | `apply_patch` 需 `applyPatch: true`；`read_image` 无 attachments 时不注册 |
| `dsh-tool-fs-search` | `glob` / `grep` | 打包 ripgrep，经 `ctx.subprocess` 前台执行 |
| `dsh-tool-bash` / `dsh-tool-pwsh` | `bash` / `pwsh` | `ctx.shell` 的模型面；有 jobs 时带 `run_in_background` |
| `dsh-tool-bash-persistent` / `-pwsh-persistent` | `bash` / `pwsh` | PTY 持久会话版本，与一次性版本互斥装载 |
| `dsh-tool-terminal` | `terminal_open/list/read/send/close/signal` | opt-in |
| `dsh-tool-web` | `web_search` / `web_fetch` | provider 在 `ctx.web` |
| `dsh-tool-skill` | `skill` | 会话 skill 目录按需加载全文 |
| `dsh-tool-workspace-dependencies` | `load_workspace_dependencies` | 载入工作区依赖清单 |
| `dsh-tool-session-query` | `session_search` 与四个 `session_event_*`/`session_trace` | opt-in，按调用者会话授权 |
| `dsh-tool-todo` | `todo_write` | 会话状态 |
| `dsh-tool-goal` | `create_goal` / `get_goal` / `update_goal` | 执行时校验根 Agent 开放回合 |
| `dsh-tool-schedule` | `schedule_create/edit/list/view` | 委派子 Agent 不可调用 |
| `dsh-tool-working-directory` | `working_directory` | 改变会话执行目录 |
| `dsh-tool-workflow` / `dsh-tool-ralph` | `workflow` / `ralph` | 工作流引擎 Consumer |
| `dsh-tool-jobs` | `job_list` / `job_output` / `job_kill` | 后台任务控制 |
| `dsh-tool-ask-user` | `ask_user_question` | 阻塞或 timed 模式 |
| `dsh-tool-subagent` | `subagent` / `subagent_fork` / `list_subagent_models` | 每后端实例一个工具名 |
| `dsh-tool-subagent-control` | `send_message` / `interrupt_agent` / `list_agents` / `wait_agent` | 共享控制工具 |
| `dsh-tool-agent-team` | `team_task_create/get/list/update` | 团队任务板，根会话开启 Team 模式时可用 |
| `dsh-plugin-manager` / `dsh-plugin-market` | `plugin_manager` / `plugin_market` | 需要 danger-full-access 或逐次审批 |
| `dsh-tool-cordis` | `cordis_inspect_list` / `cordis_inspect_query` | 只读运行时查询 |
| `dsh-tool-present`（deliverables） | `present` | 把文件声明为交付物 |
| `dsh-plan-mode` | `exit_plan_mode` | 只在会话进入过 plan 模式后声明 |
| `dsh-tool-str-replace-editor` / `dsh-tool-lsp` / `dsh-experimental-tool-worktree` | `str_replace_editor` / `lsp` / `create_worktree` | opt-in |
| `dsh-mcp-client` | `mcp__<server>__<name>` | 运行时发现注册，见 §8 |
| `dsh-mcp-resources` | `list_mcp_resources` / `list_mcp_resource_templates` / `read_mcp_resource` | 按调用者 scope 解析 server |

**capability seam 与工具的关系**：seam 仍是三角色契约（Service Definition / Provider / Consumer），工具包只持有模型面与校验，provider 决定执行位置（`docs/architecture.md`）。同一 seam 的 provider 可整体替换而模型 schema 不变：

| Seam | Provider 实现 | 工具 Consumer |
|---|---|---|
| `ctx.fs` | fs-local / fs-sandbox / fs-ssh | tool-fs、tool-str-replace-editor |
| `ctx.shell` | bash-local / bash-sandbox / pwsh-local / pwsh-sandbox | tool-bash、tool-pwsh、persistent 版本 |
| `ctx.web` | web-search-deepseek、web-deepseek-api、web-fetch-http | tool-web |
| `ctx.subprocess` | subprocess-local / subprocess-ssh | tool-fs-search（rg）、shell、terminal |
| `ctx.terminals` | terminal-bash（及 pwsh PTY 后端） | tool-terminal、persistent shell |
| `ctx.subagents` | spawn / fork / acp / codex / claude-code / dsh-sdk | tool-subagent、tool-subagent-control、tool-ralph |
| `ctx.workflowEngine` | workflow / workflow-ptc | tool-workflow、tool-ralph |
| `ctx.jobs` | jobs-local | 后台 bash/PTY/子 agent + tool-jobs |
| `ctx.userQuestions` | UI 前端提供 | tool-ask-user、plan-mode 审批 |
| `ctx.sessionQuery` | session-query-sqlite | tool-session-query |
| `ctx.skills` | skill-filesystem、skill-office | tool-skill |
| `ctx.approval` | user-approval、ACP answerer 等 | tools registry 的 ask 决策 |
| `ctx.sandbox` | sandbox-local（含 bwrap/Landlock/Seatbelt/Windows ACL 后端） | 无直接模型工具，供 bash/fs/terminal 消费 |
| `ctx.browserUse` / `ctx.computerUse` | Playwright/Chrome DevTools/Stagehand、Cua Driver | 实验性 browser/computer-use 工具 |

## 2. 工具发现、准入与注入

**schema 装配**：`ToolsService` 构造时向 `ctx.systemPrompt.tools()` 注册 provider，每次组装按 scope 与 step 准入取可见定义，再交给当前执行器的 `describe()`（`index.ts:111-117`）。`system-prompt/assemble` 瀑布本身不再携带工具数组，监听器返回的 `tools` 字段被忽略。

**step 级准入**：agent-loop 在 prompt 组装与 `agent/pre-step` 之前调用 `ctx.tools.resolve({ agent, modelSelection, signal })`（`agent.ts:292`），得到本步的 `ResolvedToolSet`；`preStep` 的每个出口都会 `dispose()` 该集合（`agent.ts:300-360`）。条件为假时工具从声明与 dispatch 中同时消失；未持有准入集合的调用、集合已释放后的调用、以及注册在 step 中被替换或移除的待执行调用，都返回 `UNKNOWN_TOOL`。

**作用域过滤**：`view()` 单次层遍历解析可见集（`index.ts:239-305`）：继承面为全局层加祖先链，同名条目就近覆盖，restriction 以交集过滤继承面，自身层注册不受限。PTC 模式下执行器在过滤面之外追加 `run_code`。

**token 控制**：未找到工具级 token 预算或 schema 自动裁剪；工具描述与参数 schema 直接进请求。PTC 模式以"只发 `run_code` 加 SDK 文本"换取调用面压缩。

## 3. 模型调用表示与执行器协议

传输结构是原生 tool-call 块（`ToolCallBlock`，`packages/llm/llm/src/types.ts`）：id + 工具名 + 模型产出的原始 JSON 参数字符串，落盘与传输都不改原文。模型可见 schema 仍是 name/description/parameters 三字段投影，适配层位于 llm seam，adapter 把它映射到厂商协议。

执行器协议（`packages/core/tools/src/executor.ts`）：

- `describe(definitions)` → `{ schemas, knownNames }`，决定该 scope 的模型声明与工具序校验（`:72`）。
- `execute(ToolBatchInput)` → `ToolBatchResult`（`:85`）。输入携带原始 `calls`、`signal`、可选 `agent`、可选 `log: { turn, step }`（`:19`）与批次级 `maxParallelToolCalls` 覆盖；输出按输入顺序回报结果、延迟上下文与 `concluded`（`:57`）。
- 内部失败在排干已启动工作后以 `ToolBatchExecutionError` 拒绝，并保留已提交结果与上下文（`:90`）。

内置实现两个：`NativeToolExecutor` 直接执行可见能力并把批次交给共享管线（默认并发 10，`packages/core/agent-loop/src/constants.ts:6`）；PTC 执行器只描述 `run_code`，并在程序内把子调用按提交顺序送入同一管线，并发安全体最多重叠 `maxParallelSubCalls` 个（`packages/core/tool-executor-ptc/src/index.ts`）。旧配置项 `mode` 与 `maxParallelSubCalls` 已被注册表以 `z.never()` 拒绝，自定义组合必须显式挂载执行器行。

**PTC 呈现**：模式只有 `native` 与 `ptc`，旧的 `both` 被移除，`DSH_TOOLS_MODE` 环境变量开关同样不再生效。PTC 运行时 `programFormat` 新增 `script`（支持语句与顶层 await），跨调用记忆由 `retainsState` 显式上报，而非靠格式推断（`packages/ptc-runtime/ptc-runtime-node/`）。子调用事件成对落盘为 `tool/ptc-dispatch-start` 与 `tool/ptc-dispatch`，持久副本可由 `tools/ptc-dispatch-log` 瀑布改写而程序已收到的值不变（`packages/core/tool-executor-ptc/src/{ptc,types,runtime-types}.ts`）。

## 4. 参数解析、校验与错误处理

循环层把参数原始 JSON 字符串解析为对象（失败保留原文，空输入映射 `{}`），执行管线在进入策略前做 lossless 物化、冻结并拒绝非 JSON 输入（`pipeline.ts:190-260`）。参数一经物化不可改写，保证历史、审计、UI 与执行四方一致。

校验位置：

1. `defineTool` 包装的 execute 内 `validateArgs`——失败抛 `ToolArgsError`（`INVALID_ARGS`）。
2. 输出侧 `createSuccessResult` 校验 `output.schema`（`pipeline.ts:537-583`）——失败为 `ToolOutputError`（`INVALID_TOOL_OUTPUT`），render 或 `presentationMeta` 投影异常同样转为输出错误。
3. 未知工具：`ToolNotFoundError`（`UNKNOWN_TOOL`）；PTC 模式下无 parent 令牌的模型直调在策略管线之前被拒为 `UNKNOWN_TOOL`；`run_code` 被调用者取消时错误码由 `CODE_RUN_FAILED` 改为 `ABORTED`，运行时自身失败仍保留前者。

失败语义：一切错误（校验失败、未知工具、监听器抛错、输出非法、管线快照失败）都物化为 isError 工具结果回注给模型，回合不中断。候选结果在 `finalizeContent` 之前先做一次物化快照，快照失败也被归一化成 isError 并仍进入该回调（`pipeline.ts:336-420`）。

## 5. 编排循环、并发与终止条件

**turn/step 结构**：step 是"一个模型请求 + 它请求的工具执行"；每步重新组装请求并落盘 step 起止事件，turn 在无待处理输入时关闭，`agent/turn-stopping` 瀑布可提前终止。工具批次结束后才 `step/end`，准入集合也在此时释放。

**调度**：并发分类只认 `isConcurrencySafe` 精确返回 true，其余一律 exclusive（fail-closed）。exclusive 调用形成屏障单独执行；parallel 调用进滚动池，上限默认 10 且可按批次覆盖。池内后启动的调用在启动前重新分类（注册变化可产生新屏障），结果与附加上下文按模型顺序提交——`commitReady` 只推进连续槽位（`batch.ts:129-232`）。

**abort 语义**：中止停止补池、排干已启动调用并在 quiescence 后结算，未启动调用逐个落盘 `tool/call` 并合成可区分错误结果，保证回放配对完整。因批次结算与落盘在同一处，执行器不会在 step 内抛出半截状态。

**终止与超时**：终止依赖模型 stop 原因、max-tokens 粘性、`concludesTurn` 标记与 turn-stopping 瀑布；源码未发现显式迭代上限。超时由工具声明的 `timeoutMs` 经 `tools/execute` 包装器实现（见 §6）。

## 6. 审批、授权与执行边界

**审批发生在 registry 执行端**：pre-execute 决策返回 `ask` 时，`serviceAsk` 经 approval seam 发起一次性审批（`pipeline.ts:432-520`）。只有 `allowed-once` 放行；拒绝、取消、通道不可用都转为可区分的拒绝原因，无审批服务或调用无 agent 时也拒绝。决策里的 `reason` 是审计理由，`displayReason` 是本地化提示文本（`docs/subsystems/tools.md`）。每次问答以 `approval/asked` 与 `approval/decided` 事件成对落盘，属日志审计而非模型历史。

**决策词汇**：pre-execute 可返回 allow / deny / cancel / ask；deny 可附带结构化错误身份与用户可见细节而不改模型可见理由。post-execute 可接受、只替换 content、只替换 value（重新校验并重算 content）或以 block 把纠正反馈转成 isError；content 与 value 互斥。参数不可被任何策略改写。

**策略粒度**：permission-presets 同时捆绑沙箱模式与审批策略；per-agent 守卫与 pre-execute 监听器可做更细粒度的工具级判定。单调守卫只能拒绝不能放行，监听器顺序无法翻盘。

**guard 机制两个实例**：timeout-policy 是 `tools/execute` 环绕包装器，工具声明预算时替换 signal 施加截止时间，计时器胜出时把结果换成 `TOOL_TIMEOUT` 结构化错误，且包装器只能替换 signal、不能移除调用者取消（`packages/guard/timeout-policy/src/index.ts`）。

repeat-tool-reminder 挂在 `tools/post-execute`：按 agent 维护连续相同调用的链（参数规范化为键），命中阈值（默认 3/5/8）时经 additionalContexts 注入提醒；只观察不否决，用户介入会重置链（`packages/guard/repeat-tool-reminder/src/index.ts`）。

**执行边界**：工具与 provider 同进程执行；文件、shell、子进程能力以 seam provider 抽象，可在本地、沙箱或远端 SSH 主机间替换。tool-fs 的可选写前观察策略由独立插件 `dsh-fs-observation-policy` 经 `fs/*` 事件门实现，shipped 组合默认关闭该行。个别工具在执行时自带授权检查：tool-goal 要求调用者处于根 agent 的开放回合且当前回合含人类来源输入（`packages/goal/tool-goal/src/authority.ts`）。

## 7. 结果回注、执行状态与恢复

**结果契约**：`ToolExecutionResult` 是 isError 判别联合：成功结果携带执行局部的 canonical 值、模型可见内容与可选 meta/additionalContexts/concludesTurn；失败结果携带结构化错误（消息与可选身份码）。meta 是工具私有展示负载，随日志落盘供回放复现。

**持久化**：durable `tool/result` 只保存模型可见消息、结构化错误身份与 meta——规范值明确不落盘。批次结算处同时负责两条事件的表面标记（`batch.ts:236-264`），会话不变式要求结果必须对应本 step 先落盘的 `tool/call`。

**模型历史**：`deriveMessages` 从有序 surface 投影模型历史，surface 只含 user/message、assistant/message、tool/result 三类事件（`packages/core/session/src/index.ts`）。工具结果消息是 user 角色、内容为单个 tool-result 块、source 携带 callId——"模型可见 ⟺ 已记录"不变式的落点。

**附加上下文与长度控制**：工具体内 `deferContext` 与 post-execute 决策附带的 additionalContexts 在该执行自身结果到达 loop 之后按 FIFO 注入下一步（`docs/subsystems/tools.md` 执行章节）。超长结果由 base bundle 的 spill-policy（默认 50KB 内联上限）与 `tool-result-pruner` 在 post-execute/compaction 阶段改写；PTC 子调用的日志副本另由 `tools/ptc-dispatch-log` 钳制。

**恢复**：session log 是 append-only 日志，重启可重建历史；进行中的工具执行不持久化，进程退出后不恢复执行现场。

**UI 呈现**：`presentCall`/`presentResult` 仍是只依赖参数（结果侧再加持久化投影）的纯函数，返回带 card 标签的渲染意图——generic/terminal/diff 三类调用卡与 generic/terminal/diff/search/read/web 六类结果卡（`packages/core/tools/src/presentation.ts`）。但内置 Web 客户端已改为自行派生工具卡，按 `tool.call.toolview` 选择业务渲染器，宿主不再计算 presenter 视图。

## 8. MCP、插件、Skill 与子 Agent

**MCP**（`packages/mcp/mcp-client`）：每个插件实例连接一个服务器（stdio 子进程或 streamable-http 两种传输），激活阻塞到初始连接与工具发现完成。工具经两阶段换代同步注册——先全量取服务器工具列表并构建定义，成功后整体替换上一代注册，注册冲突回滚为零工具（`tools.ts`）。模型可见名按 `mcp__<serverName>__<rawName>` 生成，受 64 字符与字符集约束，改写时追加身份哈希防碰撞。调用时发服务器原始名；服务器返回 isError 时执行器抛错，转入常规工具错误回注。

MCP 资源由独立 `mcp-resources` consumer 提供三项共享工具：列资源、列模板与按 URI 读取。工具要求显式 server 名，按调用 Agent 的 scope 解析 provider；文本与元数据进入结果，base64 blob 只给模型一个长度说明。

**插件自举**：模型的自我扩展路径改为"安装持久 plugin/bundle"——`plugin_manager` 负责列插件与 bundle、启停、安装与移除，`plugin_market` 读取用户配置的市场索引；两者都要求 danger-full-access 或逐次审批，变更影响整个 profile。`tool-cordis` 只剩两项只读检查工具，读运行时服务/事件目录与 Loader 条目及其 Config 状态，不再由模型定义并运行动态插件。

**Skill**：会话级 skill 目录以 catalog 形式上下文注入，模型用 skill 工具按名加载全文，不作为函数式工具注册。

**子 Agent 与旁路**：委派侧由 `tool-subagent`（一次性 `subagent`、继承历史的 `subagent_fork`、可选的模型路由发现）与 `tool-subagent-control`（`send_message`/`interrupt_agent`/`list_agents`/`wait_agent`）构成；每次委派立即返回子 Agent id，本地子 Agent 接受后续消息，外部后端只执行一次。`tool-agent-team` 在同一棵树根会话上叠加四项任务板工具。PTC 是主要旁路面：ptc 呈现下模型的直接调用只能命名 `run_code`，程序内 SDK 子调用带 parent 令牌走完整守卫管线并成对落盘 dispatch 事件。

## 9. 设计取舍与已确认边界

- **一切皆插件，注册即 effect**：工具注册、restrict、guard、准入条件与执行器选择都是可替换的配置行 effect，卸载自动撤销。
- **执行器可替换而注册表稳定**：批次解析、调度、取消与落盘被抽到 `ToolExecutor` 缝隙，自定义执行器只需实现 `describe` 与 `execute`；代价是"工具可见性"与"调度策略"分属两个包，组合必须同时挂载执行器行。
- **每步准入换取条件工具**：条件只求值一次并被该步的声明、dispatch、PTC 绑定与嵌套调用共用，避免同一步内声明与执行不一致；代价是监听器不能再在组装瀑布里增删工具声明。
- **规范值不落盘**：控制日志体积，代价是回放无法重建中间值。
- **参数不可改写**：策略层不支持改写参数，保证历史、审计、UI 与执行四方一致。
- **单调 guard + 失败关闭的审批**：guard 只能拒绝；审批通道缺失或不可答时默认拒绝。
- **呈现与执行分离，且呈现词汇只作参考**：呈现函数是 args/result 的纯函数，live 与回放共用；内置 Web 客户端按自己的渲染器派生卡片，工具作者声明的卡片意图不是渲染契约。
- **无工具级 token 预算，未发现显式迭代上限**：长尾终止依赖模型停止原因、结论标记与用户中断，上下文压缩兜底。

## 10. 未验证事项

- 未运行真实工具调用：流式 chunk、并行调度时序、timeout/abort 与准入释放的实际行为均未实测。
- MCP 端到端（连接、重连、注册冲突回滚、task-based 拒绝）未实测；`mcp-manager` 的入口与配置面只做了目录级确认。
- tool-terminal、tool-session-query、tool-lsp、schedule、worktree、spill-policy、tool-result-pruner 等包的执行细节未逐包深入。
- `run_code` 的 Node/Python PTC 运行时、`script` 格式与 `retainsState` 语义未做运行验证。
- 审批的 ACP answerer、headless 模式、Web 客户端如何消费 `ToolCallView`/`ToolResultView` 未覆盖。
- `plugin_manager` 的安装与启停幂等性、市场索引解析、danger 档权限的真实边界未运行验证。
- LLM adapter 内部如何把 `ToolSchema` 映射到厂商 tool 协议未验证。

## 11. 关键源码索引

- `packages/core/tools/src/index.ts`：ToolsService（99）、tools provider（111）、register（128）、restrict（162）、get/executable（239/251）、resolve（264）、definitions/schemas（305/316）、setExecutor（325）、execute（375）、guard/checkGuards（384/393）
- `packages/core/tools/src/contracts.ts`：ToolOutputDefinition（16）、ToolDefinition（26-101）、projectContent（49）、finalizeContent（61）、ToolActivationContext（105）、ToolRegistrationOptions（115）、RUN_CODE_NAME（12）
- `packages/core/tools/src/executor.ts`：ToolBatchInput（19）、ToolBatchResult（57）、ToolExecutor（64）、ToolBatchExecutionError（90）
- `packages/core/tools/src/pipeline.ts`：ToolExecutionPipeline（62）、prepare（190）、dispatch（295）、complete（336）、serviceAsk（432）、createSuccessResult（537）、executeToolBatch 再导出（771）
- `packages/core/tools/src/batch.ts`：滚动池调度（50-232）、事件落盘（236-264）
- `packages/core/tools/src/events.ts`、`presentation.ts`、`schema.ts`、`json-schema.ts`：事件目录、卡片词汇、schema DSL、raw JSON Schema 子集
- `packages/core/tool-executor-native/src/index.ts`：NativeToolExecutor 与默认并发 10
- `packages/core/tool-executor-ptc/src/{index,ptc,ptc-calls,types,runtime-types}.ts`：run_code 传输、子调用桥、dispatch 事件与 `tools/ptc-dispatch-log`
- `packages/core/agent-loop/src/agent.ts`：准入求值（292）、toolSet 释放（300-360）、批次执行（590）、结果补写（360-390）
- `packages/core/agent-loop/src/constants.ts`：DEFAULT_MAX_PARALLEL_TOOL_CALLS
- `packages/core/agent-tool-presentation/src/index.ts`：已弃用的 native/ptc 选择器兼容层
- `packages/guard/timeout-policy/src/index.ts`、`packages/guard/repeat-tool-reminder/src/index.ts`：两个 guard 实例
- `packages/mcp/mcp-client/src/tools.ts`、`packages/mcp/mcp-resources/src/*`：MCP 工具桥与资源面
- `packages/interaction/user-approval/src/index.ts`：审批瀑布与策略
- `packages/boot/plugin-manager/src/tools.ts`、`packages/boot/plugin-market/src/tools.ts`：插件自举入口
- `docs/tool-catalog.md`、`docs/tool-execution-pipeline.md`、`docs/subsystems/tools.md`：生成目录与管线文档
