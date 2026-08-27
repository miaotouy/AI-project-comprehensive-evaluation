# OpenCode Agent 工具调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`c2eacd72afc4a4984564c393e15ab30011057269`（分支：`dev`）
>
> 调查方式：只读源码静态梳理，追踪工具注册、注入、执行与回注全链路；未运行构建与工具调用
>
> 调查范围：工具定义与注册、注入过滤、模型协议、参数校验、编排循环、审批授权、执行边界、结果回注、MCP、Skill、子 Agent 旁路；V2 运行器仅作并行对照；桌面端（Electron）壳层仅核实边界
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的工具系统以「Effect 服务 + AI SDK 原生 tool_calls」为核心：所有工具统一为 `Tool.Def`，经 `ToolRegistry`、`SessionTools` 包装后交给 AI SDK 的 `streamText` 执行（`packages/opencode/src/tool/tool.ts:55-65`）。

工具执行与结果回注由 AI SDK 完成，opencode 侧只消费 `fullStream` 事件。

工具来源有五类：内置、自定义目录 `{tool,tools}/*.js|ts`、插件 `tool` hook、MCP 工具与 MCP 资源工具；Skill 是经 `skill` 工具按名加载的文本资源，不是工具注册来源。审批采用 allow/ask/deny 三档规则求值（`src/permission/index.ts`），执行发生在 node 进程内（shell 为普通子进程、无沙箱），结果统一截断落盘（`src/tool/truncate.ts`）。

关键事实（快照 1f94d8a）：

- **内置工具 16+1 个**，按模型、provider、client 与实验 flag 过滤（registry.ts:226-244、286-335）。
- **参数校验在 `Tool.wrap` 统一完成**：Effect Schema 解码失败转 `InvalidArgumentsError`，其 message 即模型可见的「重写输入」反馈（tool.ts:99-149）。
- **编排循环是 `SessionPrompt.runLoop` 无限 while**，上限为 agent 的 steps 配置，最后一轮注入 `MAX_STEPS_PROMPT`（prompt.ts:1178-1181、1281）。
- **审批阻塞在 Deferred 上**：`Permission.ask` 发布事件等 UI 回复，reply 支持 reject/once/always（permission/index.ts:67-167）。
- **结果截断默认 2000 行 / 50KB**，超限写入 `tool-output/` 目录并提示用 Task/Grep/Read 接力（truncate.ts:13-16、85-141）。
- **TaskTool 是唯一“旁路”**：创建子会话（新 Session）执行子 agent，权限收窄继承；子会话返回 assistant 错误或末尾工具错误时，TaskTool 将其转为包含子会话 ID 的失败结果，而非把空文本当作成功（`packages/opencode/src/tool/task.ts:214-224`）。
- **MCP 双运输**：stdio 与 StreamableHTTP/SSE，工具命名 `server_tool`，调用前全名审批（src/mcp/index.ts、catalog.ts）。
- **Skill 不是工具注册**：系统提示列出 `<available_skills>` + `skill` 工具按名加载（system.ts:98-110、tool/skill.ts）。

## 总体调用链

```text
模型请求 → SessionTools.resolve（src/session/tools.ts:41-493）
  ├─ ToolRegistry.tools()（registry.ts:286-335）：内置/自定义/插件工具按模型与 flag 过滤
  ├─ mcp.tools() → McpCatalog.convertTool（tools.ts:390-490）：MCP 工具并入
  └─ 资源工具 list_mcp_resources 等（tools.ts:27-31、136-139）
→ LLMRequestPrep.resolveTools（llm/request.ts:208-214）：按 user.tools 禁用与权限全量禁用过滤
→ AI SDK streamText({ tools, ... })（llm.ts:318）：AI SDK 内部驱动工具选择与执行
→ fullStream 事件（llm/ai-sdk.ts:76-286）：
    tool-input-start/delta/end → tool-call → tool-result / tool-error
→ SessionProcessor.handleEvent（processor.ts:278-537）：
    ensureToolCall 创建 pending part → updateToolCall 置 running → completeToolCall 置 completed
→ 重放（message-v2.ts:290-360）：ToolPart → AI SDK tool-<name> part 回注模型
```

## 1. 工具定义、来源与注册

### 1.1 核心接口（tool.ts）

- `Tool.Def`：`id`、`description`、`parameters`（Effect Schema Decoder）、`jsonSchema`、`execute`、`formatValidationError`（tool.ts:55-65）。
- `Tool.Context`：`sessionID/messageID/agent/abort/messages` + `metadata()` 与 `ask()`（tool.ts:36-46），`ask` 即工具侧审批入口。
- `Tool.Info`：`{id, init}` 惰性定义（tool.ts:71-77）；`Tool.define`（:151-169）与 `Tool.init`（:171-181）完成实例化。

### 1.2 内置工具清单（registry.ts:204-244）

| id | 定义文件 | 说明 |
|---|---|---|
| `invalid` | src/tool/invalid.ts:9-20 | 恒在列表首位，参数 `{tool, error}`，输出 "Do not use" |
| `shell` | src/tool/shell.ts（`ShellID.ToolID`，shell/id.ts） | 执行 bash/powershell |
| `read` | src/tool/read.ts:64-69 | 读文件/目录 |
| `glob` | src/tool/glob.ts:17-18 | glob 匹配 |
| `grep` | src/tool/grep.ts:20-21 | 正则搜索 |
| `edit` | src/tool/edit.ts:58-59 | 文本替换编辑 |
| `write` | src/tool/write.ts:27-28 | 整文件写入 |
| `task` | src/tool/task.ts:81 | 子 agent 派发 |
| `webfetch` | src/tool/webfetch.ts:24-25 | 网页抓取转 markdown |
| `todowrite` | src/tool/todo.ts:14-15 | 更新会话 todo |
| `websearch` | src/tool/websearch.ts:99-100 | 网络搜索（exa/parallel） |
| `skill` | src/tool/skill.ts:12-13 | 加载 skill |
| `apply_patch` | src/tool/apply_patch.ts:22-23 | 补丁应用 |
| `question` | src/tool/question.ts:14 | 向用户提问 |
| `lsp` | src/tool/lsp.ts:37-38 | LSP 操作（实验 flag） |
| `plan_exit` | src/tool/plan.ts:15-16 | 计划模式退出（实验 flag + cli） |
| `execute` | src/tool/code-mode.ts:188 | code-mode 沙箱脚本（实验 flag） |

条件注册：

| 工具 | 注册条件 | 定位 |
|---|---|---|
| `execute` | `flags.experimentalCodeMode` | registry.ts:113-114、221 |
| `lsp` | `experimentalLspTool` | :242 |
| `plan_exit` | `experimentalPlanMode && client==="cli"` | :243 |
| `question` | `["app","cli","desktop"].includes(flags.client) \|\| flags.enableQuestionTool` | :202、228 |

另有三类 MCP 资源工具 `list_mcp_resources` / `list_mcp_resource_templates` / `read_mcp_resource`，在任一台已连接 MCP 服务器声明 `resources` 能力时按需注入（src/session/tools.ts:27-31、136-139），不经过 registry 的 builtin 列表。

### 1.3 自定义工具（registry.ts:178-192）

- 扫描 `{tool,tools}/*.{js,ts}`（Glob.scanSync，cwd 为每个 `config.directories()` 目录，:178-181）；有匹配文件时先 `config.waitForDependencies()`（:182）。
- 动态 `import(pathToFileURL(match))`（Windows 兼容，:186-187）。
- 每个命名导出若形如 `{args, description, execute}`（`isPluginTool` 判定，:350-352）即注册为工具；`default` 导出用文件名作命名空间（:190）。
- 名称：`id === "default" ? namespace : namespace_id`（:190）。

### 1.4 插件工具（registry.ts:194-199、120-176）

- `plugin.list()` 的每个 `p.tool` 条目经 `fromPlugin` 包装，参数 schema 按以下分支处理：
  - 全为 Zod（`def.args`）：归一为 `z.object` 并生成 JSON Schema（`zodJsonSchema`，:369-376）；
  - 含非 Zod 项：回退 `legacyJsonSchema`（:358-367，所有 properties 置 required）。
- 包装层把宿主 Effect 的 `ask` 桥接为 Promise（:140-148），并对输出统一截断（:153-163）。
- 参数 schema 兼容注释：pre-1.14.49 曾 `z.object(undefined)` 静默容忍（#27451、#27630），现归一为 `{}`（:124-126）。

## 2. 工具发现、过滤与注入

### 2.1 `ToolRegistry.tools()` 过滤（registry.ts:286-335）

| 条件 | 行为 |
|---|---|
| `websearch` | 仅 `providerID === opencode` 或 `flags.exa/parallel`（:58-60、288-290） |
| `apply_patch` vs `edit/write` | `modelID.includes("gpt-") && !oss && !gpt-4` 时用 patch 隐藏 edit/write，反之隐藏 patch（:292-295） |
| `execute` | 仅当 `describeCodeMode` 返回非空描述（MCP 工具经权限可见非空，:275-284、300-303） |
| 其余 | 恒暴露（:297） |

- `task` 工具描述动态追加可调用的子 agent 清单（`describeTask`，:260-273）：列出非 primary 且权限求值非 deny 的 agent，按名称排序。
- 每个可见工具触发插件 `tool.definition` 事件（:313），插件可改写 `description`/`parameters`；改动后采用插件版 JSON Schema（:314-317）。
- description 还会追加 task/code-mode 的附加说明（:320-326）。

### 2.2 注入路径

1. `SessionTools.resolve`（src/session/tools.ts:41-493）把 registry 工具 + MCP 工具 + 资源工具包装为 AI SDK `Record<string, AITool>`，在 `prompt.ts:1226-1241` 注入。
2. `LLM.StreamInput.tools`（llm.ts:45）；processor 以 `handle.process` 传入（prompt.ts:1272-1286）。
3. `LLMRequestPrep.resolveTools` 二次过滤（llm/request.ts:208-214）：prompt 请求的 `user.tools` 可显式禁用单个工具。
4. `Permission.disabled` 全量禁用集合进一步隐藏：`pattern==="*" && deny` 时整工具移除（src/permission/index.ts:204-214）；edit/write/apply_patch 共享 `edit` 权限、MCP 资源工具共享 `read` 权限。
5. AI SDK `streamText({ tools: prepared.tools })`（llm.ts:318）。

### 2.3 插件事件

- `tool.definition`（plugin/src/index.ts:334）触发于 registry.ts:313。
- `tool.execute.before/after`（plugin/src/index.ts:266-281）在工具执行前后触发，覆盖 registry 工具、MCP 工具与 MCP 资源工具；各触发点定位合并进文末源码索引（见 tools.ts 条目）。

## 3. 模型调用表示与 Provider 适配

- 直接使用 AI SDK `streamText` 原生 `tool_calls` 协议（llm.ts:280-353），opencode 不实现自定义工具协议。
- 工具调用事件流：`tool-input-start/delta/end → tool-call → tool-result/tool-error`（llm/ai-sdk.ts:190-262），统一转为 `LLMEvent`。
- 工具执行出错时 AI SDK 把错误消息作为该 tool call 的结果回注给模型；`InvalidArgumentsError.message` 即模型可见文案（tool.ts:31-33）。
- `experimental_repairToolCall`（llm.ts:296-312）：工具名大小写不匹配时自动修正；无法修复时改写参数为 `{tool, error}` 并重定向到 `invalid` 工具。
- provider 对媒体回注的适配：不支持在 tool result 携带图片/PDF 的 provider，媒体被抽离为独立 user 消息注入（message-v2.ts:147-159、298-304、380-399）。

## 4. 参数解析、校验与错误处理

- 每个工具 init 时编译一次 `Schema.decodeUnknownEffect(toolInfo.parameters)` 闭包并复用（tool.ts:107-111），避免每次调用重复编译。
- `execute` 包装层先 `decode(args)`，失败经 `Effect.mapError` 转 `InvalidArgumentsError({tool, detail})`（tool.ts:121-129）。
- `formatValidationError` 可自定义格式（:126、64），默认 `String(error)`。
- 校验失败不中断循环：错误作为工具结果回注模型，提示「Please rewrite the input so it satisfies the expected schema.」（:32）。
- 包装统一 `Effect.orDie` + `Tool.execute` span，span 带 tool.name/session.id/message.id/call_id 属性（tool.ts:114-119、145）。

## 5. 编排循环、并发与终止条件

- **驱动者**：`SessionPrompt.loop` → `runLoop`（prompt.ts:1081-1341）无限 `while`，每轮创建一个 assistant 消息与 processor handle，`handle.process` 消费一次 LLM 流；工具选择与执行在 AI SDK 内部。
- **迭代上限**：`maxSteps = agent.steps ?? Infinity`，最后一轮把 `MAX_STEPS_PROMPT` 追加进请求（prompt.ts:1178-1179、1281），提示模型已达最大步数、禁止再调用工具，只输出文本总结（该提示位于 core/src/session/runner/max-steps.ts）。
- **退出条件**：`lastAssistant.finish` 不为 `"tool-calls"` 或 `"unknown"`，且无未执行工具 part 时才退出；把 unknown 视为可继续，使带工具调用的非标准完成原因仍能回传工具结果（`packages/opencode/src/session/prompt.ts:1108-1131`）。
- processor 返回 `stop`（:1319）；compaction 任务触发（:1149-1159）。
- **并发**：单会话由 `SessionRunState.ensureRunning` 保证串行（run-state.ts:88-94、96-105、:71-75；排队等待语义见 effect/runner.ts:115-138）：忙时排队等前一轮完成、不抛错，只有 `startShell` 与 `assertNotBusy` 抛 `Session.BusyError`。opencode 未设置 `toolParallelism`，单 step 内的工具并行由 AI SDK 默认行为决定。
- **超时**：llm.ts:361-364 每流创建 AbortController；shell 工具另有默认 2 分钟超时（见第 7 节）。
- **取消**：processor 在 `Effect.onInterrupt` 时置 `aborted=true` 走 `halt(AbortError)`（processor.ts:648-655）。
- `cleanup` 等待运行中工具（每 Deferred 最多 250ms，:571-575），未完成 tool part 标 `error: "Tool execution aborted"` 与 `interrupted:true`（:577-593）。
- **doom-loop 检测**：同一工具连续 3 次相同入参触发 `doom_loop` 权限审批（processor.ts:29、356-380）。
- **上下文溢出**：step-finish 时 `isOverflow` 置 `needsCompaction`，`Stream.takeUntil` 中断流，process 返回 `"compact"`，由 runLoop 创建 compaction 任务（processor.ts:477-482、679；prompt.ts:1320-1328）。
- **拒绝后行为**：`experimental.continue_loop_on_deny` 配置决定审批拒绝后是否继续循环（processor.ts:200-201、633）。
- **恢复**：V1 无独立 checkpoint，全量依赖 SQLite 持久化；每次循环从 DB 重读历史（prompt.ts:1092-1094）；被打断的 ToolPart 重放为 `[Tool execution was interrupted]`，`metadata.providerExecuted` 的调用重放时不要求再执行（message-v2.ts:321-360）。V2 运行器有显式 `failInterruptedTools`（core/src/session/runner/llm.ts:119-139）。

## 6. 审批、授权与执行边界

### 6.1 权限求值（src/permission/index.ts）

- `evaluate`：多条 ruleset 平铺后 `findLast` 匹配（后写优先），默认 `{action:"ask"}`（:28-38）。
- `ask`（:67-107）按条件求值：
  - 任一 pattern 为 `deny`：立即抛 `DeniedError`；
  - 全部 `allow`：直接通过；
  - 其他：生成 `Request` 进 pending Map、发布 `Event.Asked`，经 `Deferred.await` 阻塞等待。
- `reply`（:109-167）按回复类型处理：
  - `reject`：`Deferred.fail(RejectedError)` 或带反馈的 `CorrectedError`，并级联拒绝同 session 其他 pending；
  - `once`：仅放行当前；
  - `always`：规则写入 `approved`，级联放行同 session 满足条件的 pending。
- 策略分级：动作仅 `allow`/`ask`/`deny` 三档。
- 来源为 config 的 `permission` 字段（`fromConfig`，:186-198，支持 `~`/`$HOME` 展开）；agent 与 session 权限用 `merge` 拼接（:200-202）。
- 生命周期：pending Map 在 InstanceState 内，finalizer 拒绝所有挂起项（:54-61）。
- 工具接入：`Tool.Context.ask` 由 tools.ts:81-89 实现，自动补充 `sessionID`、`tool:{messageID,callID}` 与 `ruleset: merge(agent.permission, session.permission)`。
- 每个工具声明自己的权限与 pattern：edit 工具为 `permission:"edit"` + 相对路径 patterns + `always:["*"]`（edit.ts:102-110）；shell 用 `external_directory` 与 `shell` 权限（shell.ts:263-291）。

### 6.2 执行域与隔离

- **shell**：
  - 启动：`ChildProcess.make`（effect/unstable/process，非 node-pty）；Windows+PowerShell 参数为 `[shell, -NoLogo,-NoProfile,-NonInteractive,-Command, command]`，其余平台 `ChildProcess.make(command, [], {shell, cwd, env, stdin:"ignore", detached: 非win32})`（shell.ts:293-310）；
  - 超时与中止：默认 `flags.bashDefaultTimeoutMs ?? 2*60*1000`（:347），超时/中止后 `handle.kill({forceKillAfter:"3 seconds"})`（:548-555）；
  - 隔离兜底：**无沙箱**，靠权限审批 + `external-directory.ts:15-45` 的 `containsPath` 工作区外检查；前置扫描用 tree-sitter wasm 解析 bash/PowerShell AST 提取命令生成权限 pattern（:311-336、permission/arity.ts）；
  - 输出：超限流式落盘（:481-531，`limits.maxBytes*2` 环形缓冲）。
- **MCP 本地子进程**：stdio transport（mcp/index.ts:340-370），退出时 finalizer 用 `pgrep -P` 递归收集后代 SIGTERM 再 `client.close()`（:418-440、531-556）。
- **code-mode**：`execute` 工具在 `@opencode-ai/codemode` 沙箱解释器中执行受限脚本（code-mode.ts:239-274），MCP 工具作为沙箱子工具调用（:134-186）。
- **桌面端（Electron）**：无独立工具执行域——主进程经 `utilityProcess.fork` 启动 sidecar 运行同一 opencode server（desktop/src/main/server.ts:57-184），工具全部在 sidecar 内执行。
- 审批/提问 UI 复用共享 app 组件（app/src/pages/session/composer/session-permission-dock.tsx、session-question-dock.tsx）；question 工具注册含 `client==="desktop"`（registry.ts:202），桌面请求带 `x-opencode-client: desktop`（llm/request.ts:193）。
- desktop 包独有能力仅原生附件选择（desktop/src/main/ipc.ts:165-197）与 Windows WSL 终端 pty（main/wsl/runtime.ts:4）。

## 7. 结果回注与 UI 状态

- **ToolPart 状态机**（schema/src/v1/session.ts:259-325）：`pending`（input/raw）→ `running`（+title/metadata/time.start）→ `completed`（+output/metadata/time.end）或 `error`（+error/metadata）。
- **持久化**：processor 经 `ensureToolCall` 创建 pending（processor.ts:216-253），`tool-call` 事件置 running（:331-351），`tool-result`/`tool-error` 置 completed/error（:383-419）。
- 每次更新经 `session.updatePart` 落库并发布 `message.part.updated`。
- **重放回注**：`MessageV2.toModelMessagesEffect`（message-v2.ts:290-360）把 ToolPart 转 AI SDK `tool-<name>` part（`toolCallId/input/output/errorText/state`），未完成 part 转 `output-error`。
- **截断**：`truncate.output`（src/tool/truncate.ts:85-141）默认 `MAX_LINES=2000`、`MAX_BYTES=50KB`（:15-16，config `tool_output.max_lines/max_bytes` 可覆盖，:75-83）。
- 超限时全量写入 `<xdgData>/opencode/tool-output/tool_<id>`（truncation-dir.ts），返回截断预览与提示：agent 有 `task` 权限时建议用 Task 工具委派，否则建议 Grep/Read（:129-131）。
- 输出保留 7 天，每小时清理一次，按文件 mtime 判定过期（:12、:53-63、:143-145），不再解析文件名时间戳（d468201）。
- **附件**：工具可返回 `attachments`（tool.ts:48-53），tools.ts:112-120 补 id 后随 tool result 持久化；processor 对超大图片附件剔除并计数（processor.ts:390-411）；重放经 `toModelOutput`（message-v2.ts:161-193）转媒体 part 或独立 user 消息。
- **UI 状态**：`message.part.updated` 驱动前端 part 渲染（详见消息渲染器笔记）；pending/running 显示 shimmer 与进度。

## 8. MCP、插件、Skill 与子 Agent

### 8.1 MCP（src/mcp/）

- **配置**：`opencode.json` 的 `mcp` 字段（core/src/v1/config/mcp.ts）：`local`（type/command/cwd/environment/enabled/timeout）、`remote`（type/url/enabled/headers/oauth/timeout，oauth 可为对象或 false）。
- **客户端**：`local` 走 `StdioClientTransport`（mcp/index.ts:340-370）；`remote` 依次尝试 StreamableHTTP → SSE（:269-284），支持 OAuth（`McpOAuthProvider`，:251-267）；连接超时 `mcp.timeout ?? 30_000`（:286）。
- 能力声明只含 `roots`（:39-50）。
- **目录获取**：`McpCatalog.listTools` 分页获取（catalog.ts:145-162；常量 `MAX_LIST_PAGES=1000`、`DEFAULT_TIMEOUT=30s` 位于 :11-12），outputSchema 校验失败降级为宽松 schema 重试（:164-168）。
- `tools/list_changed` 触发重拉并发布 `ToolsChanged` 事件（mcp/index.ts:461-471）；启动时并行连接全部服务器（:505-529）。
- **工具 schema 注入**：`convertTool` 强制 `type:"object"`、`additionalProperties:false`（catalog.ts:42-48），再经 `ProviderTransform.schema` 按模型转换（tools.ts:395-397）；OpenAI 系强制 `strict:false`（llm/request.ts:152-158）。
- **调用**：调用前 `ctx.ask({permission: 工具全名, patterns:["*"], always:["*"]})`（tools.ts:408）；结果归一化 text/image/resource 三类 content，二进制资源有 mime 白名单与 10MB 上限（:426-462）。
- **命名**：`sanitize(clientName)_sanitize(toolName)`（catalog.ts:117-119）。
- **指令注入**：服务器 `getInstructions()` 进系统提示 `<mcp_instructions>`（system.ts:112-128），整服务器工具全被禁用时隐藏。

### 8.2 Skill（src/skill/、src/tool/skill.ts）

- **发现**，按来源：
  - 全局：`~/.claude/skills/**/SKILL.md`、`~/.agents/skills/**/SKILL.md`（skill/index.ts:21-23、186-194）；
  - 项目：沿目录树查找同样的两个外部目录（:196-202）；
  - 配置目录：`{skill,skills}/**/SKILL.md`（:24、205-208）；
  - config 显式路径：`skills.paths`（:211-220）；
  - 网络：`skills.urls` 的 index.json（:222-227 + skill/discovery.ts:49-132，带版本缓存）；
  - 内置：`customize-opencode`（:32-35、276-283）。
- **可见性**：`Permission.evaluate("skill", name, agent.permission) !== "deny"`（:310-315）。
- **暴露**：系统提示输出 `<available_skills>` 清单（system.ts:98-110）；`skill` 工具仅一个参数 `name`，调用前 `ctx.ask({permission:"skill", patterns:[name], always:[name]})`（tool/skill.ts:27-32）。
- 工具输出 `<skill_content>` 与 `<skill_files>` 两部分（ripgrep 抽样 limit 10，:36-66）。

### 8.3 子 Agent（src/tool/task.ts）

- 参数 `description/prompt/subagent_type/task_id/command/background`（task.ts:43-62）。
- **新 Session**：`sessions.create({parentID, title, agent: subagent_type, permission})`（:156-172）；子会话权限 = 父会话 deny 规则 + `external_directory` 规则（agent/subagent-permissions.ts:14-27），再强制追加 `todowrite`/`task` deny（除非子 agent 显式允许）+ `experimental.primary_tools` deny（task.ts:139-155）。
- 模型：`next.model ?? 父消息模型`（:181-190）；深度限制 `subagent_depth ?? 1`（:106-117）；`task_id` 复用恢复同一子会话（:136-138）。
- 旁路语义：`ctx.extra.bypassAgentCheck`（用户显式 `agent:` part）跳过 task 审批（:119-129）。
- 执行：`ops.prompt` 对子 session 发起一轮（:200-214）；`background=true`（需 `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS`）立即返回，完成后向父会话注入合成 user 消息（:216-254）；前台用 `Effect.raceFirst` 等待，abort 级联取消子会话（:313-347）。

## 9. 设计取舍与已确认边界

- **AI SDK 承担工具循环**：opencode 不做自定义协议，代价是循环控制、并行度、重试语义部分让渡给 SDK。
- **权限默认 ask、可全 deny**：与内置 agent 的 `*:allow` 默认（agent.ts:119-136）形成「模型可见 vs 执行允许」两层过滤。
- **无沙箱的 shell**：以权限审批 + 外部目录检查 + 超时兜底，隔离强度依赖用户配置。
- **执行结果统一截断落盘**：控制上下文膨胀，7 天保留策略。
- **ToolPart 全量持久化**：中断后重放为错误而不是重执行，避免重复副作用；`providerExecuted` 标记防重复调用。
- **V1/V2 双轨并存**：本快照 V1 为生产主路径，V2 运行器（core/src/session/runner/）部分实现，其工具循环与权限模型（core/src/permission.ts 默认全 deny）与 V1 存在语义差异，迁移未完成。

## 10. 未验证事项

1. 未运行构建与真实模型调用；AI SDK 内部工具并行度、`experimental_repairToolCall` 的实际行为未实测。
2. 静态代码只能确认审批入口与事件绑定；UI 弹窗交互、键盘可用性需运行验证。
3. code-mode 沙箱解释器的隔离强度未验证。
4. `tools/list_changed` 重拉与 MCP 服务器热重连在真实服务器上的行为未实测。
5. doom-loop 与截断阈值（2000 行/50KB）的实际触发效果未实测。

## 11. 关键源码索引

- `packages/opencode/src/tool/tool.ts`：Tool.Def/Info/Context（:36-91）、参数校验与截断包装（:99-149）
- `packages/opencode/src/tool/registry.ts`：内置/自定义/插件工具注册（:116-249）、注入过滤（:286-335）
- `packages/opencode/src/session/tools.ts`：AI SDK 工具包装与 MCP 工具并入（:41-493）；工具执行事件触发点（:106-125、:175-215、:258-299、:338-384、:402-424、code-mode.ts:141-184）
- `packages/opencode/src/session/prompt.ts`：runLoop 主循环（:1081-1341）
- `packages/opencode/src/session/processor.ts`：LLMEvent 消费与 ToolPart 状态机（:278-537）
- `packages/opencode/src/permission/index.ts`：权限求值与审批（:28-214）
- `packages/opencode/src/tool/truncate.ts`：输出截断与落盘（:13-148）
- `packages/opencode/src/mcp/index.ts`、`src/mcp/catalog.ts`：MCP 客户端与目录
- `packages/opencode/src/skill/index.ts`、`src/tool/skill.ts`：Skill 机制
- `packages/opencode/src/session/llm.ts`、`src/session/llm/request.ts`：模型请求与工具注入
