# Pi Agent 工具调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/agent/src/agent-loop.ts`、`packages/coding-agent/src/core/tools/`、`core/extensions/`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码梳理工具定义、注入、校验、编排循环与执行；未运行真实工具调用
>
> 调查范围：工具来源与注册、发现与注入、模型协议、参数校验、编排循环、审批授权、执行边界、结果回注、状态恢复与旁路能力
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的工具体系是“内置文件/命令工具 + 扩展注册工具”的本地执行模型，由 `packages/agent` 的 agent-loop 统一编排：

1. **工具是代码对象，没有独立的持久化实体**：内置 8 个工具（read/bash/powershell/edit/write/grep/find/ls，`core/tools/index.ts:48-57`）；扩展经 `registerTool` 注册 `ToolDefinition`（`extensions/types.ts:599`），描述里含 TypeBox 参数 schema、prompt snippet、渲染回调与执行函数。`powershell` 是 Windows 可选工具，优先调用 `pwsh.exe`，否则 Windows PowerShell；它与 bash 一样按启动用户权限执行，只是向命令加入 UTF-8 输出设置（`core/tools/powershell.ts:16-46`）。MCP 与 codemode 均已作为可替换内建扩展装配，连接工具和脚本工具需与八个基础文件/命令工具分别理解（[装配表](../../pi/packages/coding-agent/src/extensions/index.ts#L1-L14)）。
2. **注入是会话级工具集 + 每轮上下文**：激活集存于 `agent.state.tools`（`agent-session.ts:928-943`），每轮 `prepareNextTurnWithContext` 把当前工具集快照注入请求上下文（`agent-session.ts:541-556`）；system prompt 的 Available tools 段只列出带一行 snippet 的工具（`system-prompt.ts:80-84`）。
3. **协议是 Provider 原生 tool_calls**：`Context.tools` 传入 `Provider.stream`，由各 API Adapter 转成 OpenAI function calling、Anthropic tools、Google functionDeclarations 等格式（`packages/ai/src/types.ts:492-506`）。`Tool` 的 `constrainedSampling` 可要求严格 JSON schema 或 Lark/regex grammar；`constrained-sampling.ts` 提供 `makeStrictJsonSchema`，在 Provider 支持 strict 模式时把 TypeBox schema 转换为 strict 子集（`constrained-sampling.ts:29-130`），不可转换时回退，`strict: "require"` 时直接报错。strict 子集转换规则为：

```text
禁用 $ref / allOf / oneOf 等组合关键词；可选属性包成 anyOf: [prop, null]；
强制 required 与 additionalProperties: false
```

read/bash/edit/write 内置工具默认启用 `{ type: "json_schema", strict: "prefer" }` 约束采样；Provider 不支持 strict 时仍按兼容策略回退（`tools/read.ts:73-78`、`tools/bash.ts:234-239`）。
4. **校验集中在执行前**：`prepareToolCall`（`agent-loop.ts:718`）用 pi-schema 编译出的校验器做校验并做值转换（`packages/ai/src/utils/validation.ts`），未知工具与校验失败都转成 isError 工具结果回注给模型，而不是中断循环。
5. **循环由 agent-loop 驱动，无显式迭代上限**：内层 while 处理“工具调用 + steering 队列”，外层 while 排空 followUp 队列（`agent-loop.ts:155-275`）；并行工具调用并发执行、结果按序回注；`length`（输出截断）时所有工具调用统一按失败处理（`failToolCallsFromTruncatedMessage`，`agent-loop.ts:381-406`）。源码未发现 maxIterations 类上限。
6. **审批是回调钩子，不在执行端强制**：`beforeToolCall` 返回 `block` 即拒绝执行（`agent-loop.ts:619-643`），扩展 `tool_call` 事件走同一钩子；没有按工具/风险分级的持久化审批策略。项目信任门不直接拦截 bash 执行，而是决定项目级 `.pi` 设置、资源、扩展与包是否加载（settings-manager.ts:355-356、resource-loader.ts:397-398）；只有当 shell 路径与命令前缀取自项目设置时，信任状态才间接影响 bash 的运行参数（project-trust.ts）。
7. **基础工具执行边界是本地进程**：文件工具直接操作 fs；bash 用 `spawn` 子进程、进程树终止、可选超时与输出截断（`tools/bash.ts:88-126`、`killProcessTree`）；工具可流式上报部分结果（`onUpdate`）。
8. **结果回注是 toolResult 消息**：内容支持文本+图片（图片自动缩放，`normalizeToolResultImages`），`isError` 标记失败，`addedToolNames` 支持 Provider 原生延迟工具加载（`packages/ai/src/types.ts:437-454`）。

## 总体调用链

```text
模型 -> toolCall 块 (assistant 消息)
  -> runLoop (agent-loop.ts:155-275)
      toolCalls.length > 0 ?
        stopReason==="length" -> 全部失败回注
        否则 executeToolCalls (并行/顺序按 executionMode)
           prepareToolCall: 查找工具 + prepareArguments + validateToolArguments
           beforeToolCall 钩子 (可 block) / 扩展 tool_call
           tool.execute(id, args, signal, onUpdate)
           afterToolCall 钩子 / 扩展 tool_result
           -> ToolResultMessage 回注上下文
  -> 下一轮 LLM 调用 (工具结果进 context)
```

## 1. 工具定义、来源与注册

- **统一接口**：`AgentTool`（`packages/agent/src/types.ts`）与扩展侧 `ToolDefinition`（`extensions/types.ts:599`）都是“name + description + JSON Schema parameters + execute”。`ToolDefinition` 额外带：
  - `label`、`promptSnippet`、`promptGuidelines`、`constrainedSampling`；
  - `renderShell`、`prepareArguments`、`executionMode`、`renderCall`/`renderResult`。
- **内置工具**：`createAllToolDefinitions`（`tools/index.ts:113-124`）构造 8 个工具；默认激活集仍是 read/bash/edit/write。`defaultTools` 可按全局或项目设置替换启动时启用的内置工具，空数组可关闭全部内置工具，同时保留扩展和 SDK 注册的自定义工具；`--tools` 仍以所有工具的严格允许名单覆盖此选择（`core/sdk.ts:259-263`、`docs/settings.md:225-243`）。
- **扩展注册**：`registerTool`（扩展 API）把 `ToolDefinition` 放进 `_toolRegistry`/`_toolDefinitions`，经 `wrapRegisteredTools`（extensions/wrapper.ts:43，调用于 agent-session.ts:2514-2523）转成 AgentTool；before/afterToolCall 钩子安装在 agent-session.ts:479-533。
- **Skill 与工具的关系**：skill 不是工具调用，是模型可见的文本资源（system prompt 索引 + `/skill:name` 全文注入），由模型以 read 工具或直接读取方式使用。
- **来源校验**：扩展加载时 `validateExtensionProvider` 等校验只针对 Provider；工具名冲突处理在扩展装载（`detectExtensionConflicts` 等，`resource-loader.ts:1059-1067`）与 `_toolRegistry` 覆盖语义中。

## 2. 工具发现、过滤与注入

- **激活集**：`agent.state.tools` 是当前请求可见的工具全集（会话级 `setActiveToolsByName`，`agent-session.ts:928-943`）。
- **每轮注入**：`prepareNextTurnWithContext`（挂在 `_installAgentNextTurnRefresh` 上）每轮把当前工具集快照注入 `Context.tools`（`agent-session.ts:541-556`）；`streamAssistantResponse` 再把它放进 LLM `Context`（`agent-loop.ts:297-302`）。
- **系统提示可见性**：Available tools 只列带一行 snippet 的工具（`system-prompt.ts:80-84`），guidelines 按激活工具集推导（如只有 bash 没有 grep/find/ls 时提示用 bash 做文件操作，`system-prompt.ts:97-113`）；扩展工具不带 snippet 时不进该段，但仍在请求的工具协议里。内置工具的 snippet/guidelines 常量化导出（`bashToolSystemPromptContribution`/`editToolSystemPromptContribution`/`readToolSystemPromptContribution` 等，`tools/bash.ts:46-50`、`tools/edit.ts:56-66`），供 `server/create-harness.ts` 的 harness 组合路径复用。
- **token 控制**：无工具级 token 预算或自动裁剪；工具描述/参数直接进请求。

## 3. 模型调用表示与 Provider 适配

- **传输结构**：`Context.tools: Tool[]`（`packages/ai/src/types.ts:502-513`），`Tool.name/description/parameters(JSON Schema)/constrainedSampling`；`ToolCall` 新增 `namespace` 字段（OpenAI Responses 动态加载/命名空间工具，`types.ts:360-368`）。
- **Provider 适配**：各 API Adapter 把 Tool 转成协议格式；Anthropic 工具带 `cache_control`/strict schema 选项（`types.ts:617-671` 的 `AnthropicMessagesCompat`），OpenAI-compatible 支持 `strict` 与 grammar 工具（`types.ts:583-597`），Bedrock 有独立 `BedrockCompat`（`types.ts:673-677`）。
- **流式工具参数**：事件流支持 `toolcall_start/delta/end`（`types.ts:523-525`），部分 Provider（z.ai `zaiToolStream`）支持流式工具调用增量。

## 4. 参数解析、校验与错误处理

- **prepareArguments**：工具可先改写原始参数（兼容 shim，`extensions/types.ts:467-468`）。
- **校验**（`validateToolArguments`，`ai/src/utils/validation.ts:54`）按序执行：
  1. 工具调用自带 `argumentsError` 时直接抛错，不再尝试修复；
  2. 参数先 `structuredClone`，避免工具改写参数时污染 transcript 里的原调用；
  3. 交给缓存校验器 `parse()`：校验器由 pi-schema 的 `compile` 生成（`coerce: true`，模型常把数字写成字符串、把单值写成数组或把可选字段写成 `null`），对悬空 `$ref` 只拒绝该位置；任何 JSON Schema 都可以（pi-schema builders、TypeBox 或普通对象）；
  4. 失败时抛出带点号路径与收到的参数的错误文本。
- **失败语义**：`prepareToolCall` 捕获一切异常并返回 `{ kind: "immediate", result: createErrorToolResult(...), isError: true }`（`agent-loop.ts:718`），即校验失败/未知工具以工具错误结果回注，模型可据此修正重试，不会中断 agent。

## 5. 编排循环、并发与终止条件

- **循环结构**：`runLoop`（`agent-loop.ts:155-275`）内层 while 以“还有工具调用或待处理消息”为继续条件，外层排空 followUp 队列；`shouldStopAfterTurn` 钩子可提前终止；`turn_end` 事件带 `toolResults`、`agent_end` 只带 `messages`（types.ts:425-428）。
- **并发**：默认并行执行同批工具调用，`Promise.all` 并发、结果按调用顺序回注（`executeToolCallsParallel`，`agent-loop.ts:489-554`）；`config.toolExecution === "sequential"` 或任一工具 `executionMode: "sequential"` 时改为串行（`agent-loop.ts:419-425`）。
- **终止规则**：`shouldTerminateToolBatch`：所有结果 `terminate: true` 时结束（`agent-loop.ts:582-584`）；`length` 截断时工具全部失败（`agent-loop.ts:210-214`）；abort 信号在工具间传播。
- **迭代上限**：源码未发现 maxIterations/轮次上限；终止依赖模型 stopReason、shouldStopAfterTurn 与队列排空。
- **超时/取消**：AbortSignal 贯穿 `execute`（`agent-loop.ts:478-481`）；bash 工具支持按参数 timeout。

## 6. 审批、授权与执行边界

- **审批钩子**：`beforeToolCall`（`agent-loop.ts:619-648`）返回 `{ block, reason? }` 即拒绝并回注错误；AgentSession 把它接到扩展 `tool_call` 事件（`agent-session.ts:480-499`）。block 结果可带 `terminate: true`——当本批所有最终化工具结果都置 terminate 时，批次提前终止（`shouldTerminateToolBatch`，`agent-loop.ts:582-584`），扩展侧 `ToolCallEventResult` 同步支持该字段（`extensions/types.ts:1072-1078`）。
- **结果改写钩子**：`afterToolCall` 可改结果内容、isError、usage 与 terminate（`agent-loop.ts:724-754`），扩展 `tool_result` 事件走同一路径。
- **信任门**：项目信任状态（`trust-manager.ts`、`project-trust.ts`）决定 `.pi` 资源与 bash 等是否可用；`/trust` 命令保存决定。**未发现按工具/风险分级的常驻审批策略**，确认框式的授权 UI 本次未找到。
- **执行域**：基础文件工具直接 fs，bash spawn 本地子进程；MCP 连接远端/子进程服务器，codemode 有 QuickJS worker，按各自路径判断权限（§8/§11）。`BashOperations` 接口允许扩展替换执行后端（如 SSH 远程），`createLocalBashOperations` 是默认实现（接口在 `tools/bash.ts:56-74`，函数跨 88-150；默认兜底 bash.ts:326 `options?.operations ?? createLocalBashOperations`）。
- **资源限制**：bash 无默认超时（参数可选），进程树终止 `killProcessTree`、`detached` 平台差异（`tools/bash.ts:103-126`）；输出经 `OutputAccumulator` 截断并记录 `fullOutputPath`（`tools/bash.ts`、`truncate.ts`）。

## 7. 结果回注与 UI 状态

- **回注格式**：`ToolResultMessage { role: "toolResult", toolCallId, toolName, content: (text|image)[], details?, usage?, addedToolNames?, isError }`（`packages/ai/src/types.ts:437-454`）；`createToolResultMessage`（`agent-loop.ts:773-787`）把工具结果转成消息进入上下文与 `newMessages`。
- **图片处理**：`afterToolCall` 中 `normalizeToolResultImages` 自动缩放（`agent-session.ts:516-531`，`settings.images.autoResize` 默认 2000x2000）；`blockImages` 阻止图片发送（`settings-manager.ts:45-48`）。
- **UI 状态**：`tool_execution_start/update/end` 事件驱动 `ToolExecutionComponent`（流式输出、错误色、可展开），assistant 消息中的 toolCall 块逐步更新参数；中止/错误时组件显示原因（`interactive-mode.ts:3198-3208`）。
- **持久化**：toolResult 消息在 `message_end` 落盘（`agent-session.ts:650-657`）；进行中的工具（pendingToolCalls）不持久化，进程退出后不恢复执行现场，恢复会话时历史工具结果完整可用。

## 8. MCP、插件、Skill 与子 Agent

- **MCP 已接入 coding-agent**：配置和扩展注册形成服务器目录，连接后把工具转换为带命名空间的普通扩展定义；目录变化隐藏已消失工具，执行时再次检查服务器启用与工具可用性。默认由 codemode 脚本发现调用，也可延迟由 tool_search 加载、直接暴露或隐藏（[定义注册与执行检查](../../pi/packages/coding-agent/src/extensions/mcp/index.ts#L387-L454)、[暴露模式](../../pi/packages/coding-agent/src/core/mcp-servers.ts#L52-L88)）。
- MCP 调用携带取消、超时和进度，结果转换成文本/图片并限界。读请求的瞬时 HTTP 错误可重试一次，可能已执行的工具调用不按该规则重试；明确的 session-expired 响应可新建会话后再试一次（[调用桥](../../pi/packages/coding-agent/src/extensions/mcp/tools.ts#L249-L287)、[重试边界](../../pi/packages/coding-agent/src/extensions/mcp/runtime.ts#L247-L301)）。p2 的 MCP 则由 server 管连接、worker 提供 durable 扩展，采用独立装配（[worker 入口](../../pi/apps/p2/plugins/mcp/worker.ts#L54-L83)）。
- **插件/扩展**：扩展可注册工具、改写 system prompt、注入 custom 消息、提供命令（`/xxx`）与自定义会话条目；扩展工具走与内置工具相同的循环。
- **Skill**：模型可发现（system prompt 索引），也可经 `/skill:name` 由用户/流程注入，属于文本侧能力。
- **子 Agent**：`createAgentSession`（`core/sdk.ts:169`）可被扩展用作子 Agent 循环，共享相同工具循环；无内置“把当前会话委托给子 Agent”的配置。

## 9. 设计取舍与已确认边界

- **本地优先、信任分界简单**：默认“以用户权限运行”，基础 shell/文件工具的操作系统隔离依赖外部部署，codemode 另有 VM 资源边界，调用其中的本地工具仍沿用进程权限。容器化文档列出 Gondolin/Docker/OpenShell（[README](../../pi/README.md#L88-L96)），本调查未部署验证。
- **审批在编排层**：beforeToolCall 是唯一拦截点且由扩展实现，执行端不二次鉴权——扩展未注册该钩子时任何工具直接执行（攻击面前提是扩展代码本身可信）。
- **无工具级预算**：token 与迭代次数都没有显式上限，长尾风险由上下文压缩与用户中断兜底。
- **技能与工具分离**：文本注入的 skill 与函数式工具协议并存，避免强 schema 化，但模型依赖提示指引来“记得读 skill”。

## 10. 未验证事项

- 未运行工具调用，bash 输出流式、图片回注等运行时行为未实测。
- 扩展 `tool_call/tool_result` 钩子与 `prepareArguments` 组合路径的边界情况未逐一覆盖。
- 容器化模式（Gondolin/Docker/OpenShell）未在本仓库代码内验证（README 指向文档）。

## 11. Durable 工具执行与注册校验

durable 的工具执行把每次调用记成 entry 先提交，再按原调用顺序进入 transcript；重启复用已提交结果；已记录 intent 而结果未提交时，只重跑存储与当前声明同时 replay-safe 的调用，默认 unsafe 调用结算 interrupted 并提示可能已部分运行。副作用与本地提交之间仍有不确定窗口（[重放策略](../../pi/packages/durable/src/harness/tool.ts#L177-L227)）。取消、参数截断与批次终止都有各自的记录（`packages/durable/src/harness/`、`packages/durable/src/entries.ts`）。

durable 自带一套 bash/read/write/edit/image 工具（`packages/durable/src/tools/`），与 coding-agent 的工具分属两套装配，但共享“有限视图 + 完整输出旁路”的原则；shell 输出由执行环境在源侧限界，超限时返回截断元数据并尽力保留临时文件路径。

codemode 已通过内建扩展接入 coding-agent：注册默认不激活，工具集配置或 MCP 发现可激活。脚本在 QuickJS worker 中运行，嵌套调用仍经过统一校验与工具钩子，模型只收到脚本输出与返回值；成功的 store 写入分支局部 custom entry（[注册](../../pi/packages/coding-agent/src/extensions/codemode/index.ts#L32-L45)、[执行桥](../../pi/packages/coding-agent/src/extensions/codemode/execute.ts#L519-L550)、[成功提交](../../pi/packages/coding-agent/src/extensions/codemode/execute.ts#L603-L624)）。

稳定扩展加载器拒绝参数 schema 根节点不是 object 的工具；read/bash/edit/write 默认请求 strict-prefer JSON schema 采样。实际参数仍在执行前经 pi-schema 校验，因此采样约束不替代执行端校验（`packages/coding-agent/src/core/extensions/loader.ts`、`packages/coding-agent/src/core/tools/read.ts`、`packages/ai/src/utils/validation.ts:54`）。

## 12. 关键源码索引

- `packages/agent/src/agent-loop.ts:47`：agentLoop；`:111`：runAgentLoop；`:518`/`:540`/`:596`：工具执行与串/并行；`:718`：prepareToolCall
- `packages/coding-agent/src/core/tools/index.ts:83-84`：内置工具清单；`tools/bash.ts:88-126`：本地执行后端
- `packages/coding-agent/src/core/extensions/types.ts:599`：ToolDefinition
- `packages/ai/src/utils/validation.ts:37`/`:54`：工具与参数校验、pi-schema 编译缓存
- `packages/ai/src/types.ts:779`：Tool 接口；`:648`：ToolResultMessage
- `packages/coding-agent/src/core/agent-session.ts:1562`：激活工具集；`packages/durable/src/tools/`、`packages/codemode/README.md`：durable 与脚本工具装配
- `packages/coding-agent/src/core/system-prompt.ts:80-84`：工具可见性
