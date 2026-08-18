# Pi Agent 工具调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/agent/src/agent-loop.ts`、`packages/coding-agent/src/core/tools/`、`core/extensions/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`534bcbffb7e1e7551d9ee3572dfeb278e203e493`（分支：`main`）
>
> 调查方式：只读源码梳理工具定义、注入、校验、编排循环与执行；未运行真实工具调用
>
> 调查范围：工具来源与注册、发现与注入、模型协议、参数校验、编排循环、审批授权、执行边界、结果回注、状态恢复与旁路能力
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的工具体系是“内置文件/命令工具 + 扩展注册工具”的本地执行模型，由 `packages/agent` 的 agent-loop 统一编排：

1. **工具是代码对象，不是独立持久化实体**：内置 7 个工具（read/bash/edit/write/grep/find/ls，`core/tools/index.ts:83-84`）；扩展经 `registerTool` 注册 `ToolDefinition`（`extensions/types.ts:449-498`），描述里含 TypeBox 参数 schema、prompt snippet、渲染回调与执行函数。**本次未找到 MCP 支持**——仅工具结果图片注释提到 “MCP bridges” 字样（`utils/tool-result-images.ts:15`），无协议实现。
2. **注入是会话级工具集 + 每轮上下文**：激活集存于 `agent.state.tools`（`agent-session.ts:928-943`），每轮 `prepareNextTurnWithContext` 把当前工具集快照注入请求上下文（`agent-session.ts:541-556`）；system prompt 的 Available tools 段只列出带一行 snippet 的工具（`system-prompt.ts:80-84`）。
3. **协议是 Provider 原生 tool_calls**：`Context.tools` 传入 `Provider.stream`，由各 API Adapter 转成 OpenAI function calling、Anthropic tools、Google functionDeclarations 等格式（`packages/ai/src/types.ts:492-506`）。`Tool` 的 `constrainedSampling` 可要求严格 JSON schema 或 Lark/regex grammar；`constrained-sampling.ts` 提供 `makeStrictJsonSchema`，在 Provider 支持 strict 模式时把 TypeBox schema 转换为 strict 子集（`constrained-sampling.ts:29-130`），不可转换时回退，`strict: "require"` 时直接报错。strict 子集转换规则为：

```text
禁用 $ref / allOf / oneOf 等组合关键词；可选属性包成 anyOf: [prop, null]；
强制 required 与 additionalProperties: false
```

`PI_EXPERIMENTAL=1` 时 read/bash/edit/write 内置工具启用 `{ type: "json_schema", strict: "prefer" }` 约束采样（`core/experimental.ts:3-10`、`tools/read.ts:222` 等）。
4. **校验集中在执行前**：`prepareToolCall`（`agent-loop.ts:600-664`）用 TypeBox 校验并做值转换（`packages/ai/src/utils/validation.ts:317-349`），未知工具与校验失败都转成 isError 工具结果回注给模型，而不是中断循环。
5. **循环由 agent-loop 驱动，无显式迭代上限**：内层 while 处理“工具调用 + steering 队列”，外层 while 排空 followUp 队列（`agent-loop.ts:155-275`）；并行工具调用并发执行、结果按序回注；`length`（输出截断）时所有工具调用统一按失败处理（`failToolCallsFromTruncatedMessage`，`agent-loop.ts:381-406`）。源码未发现 maxIterations 类上限。
6. **审批是回调钩子而非执行端强制**：`beforeToolCall` 返回 `block` 即拒绝执行（`agent-loop.ts:619-643`），扩展 `tool_call` 事件走同一钩子；没有按工具/风险分级的持久化审批策略。项目信任门不直接拦截 bash 执行，而是决定项目级 `.pi` 设置、资源、扩展与包是否加载（settings-manager.ts:355-356、resource-loader.ts:397-398）；只有当 shell 路径与命令前缀取自项目设置时，信任状态才间接影响 bash 的运行参数（project-trust.ts）。
7. **执行边界是本地进程**：文件工具直接操作 fs；bash 用 `spawn` 子进程、进程树终止、可选超时与输出截断（`tools/bash.ts:88-126`、`killProcessTree`）；工具可流式上报部分结果（`onUpdate`）。
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

- **统一接口**：`AgentTool`（`packages/agent/src/types.ts`）与扩展侧 `ToolDefinition`（`extensions/types.ts:449-498`）都是“name + description + TypeBox parameters + execute”。`ToolDefinition` 额外带：
  - `label`、`promptSnippet`、`promptGuidelines`、`constrainedSampling`；
  - `renderShell`、`prepareArguments`、`executionMode`、`renderCall`/`renderResult`。
- **内置工具**：`createAllToolDefinitions`（`tools/index.ts:156-166`）构造 7 个工具；默认激活集是 read/bash/edit/write（`agent-session.ts:211-212`），`--tools` 或设置可增删（由 `initialActiveToolNames`/`allowedToolNames`/`excludedToolNames` 三类名单控制，`agent-session.ts:213-217`）。
- **扩展注册**：`registerTool`（扩展 API）把 `ToolDefinition` 放进 `_toolRegistry`/`_toolDefinitions`，经 `wrapRegisteredTools`（extensions/wrapper.ts:43，调用于 agent-session.ts:2514-2523）转成 AgentTool；before/afterToolCall 钩子安装在 agent-session.ts:479-533。
- **Skill 与工具的关系**：skill 不是工具调用，是模型可见的文本资源（system prompt 索引 + `/skill:name` 全文注入），由模型以 read 工具或直接读取方式使用。
- **来源校验**：扩展加载时 `validateExtensionProvider` 等校验只针对 Provider；工具名冲突处理在扩展装载（`detectExtensionConflicts` 等，`resource-loader.ts:1059-1067`）与 `_toolRegistry` 覆盖语义中。

## 2. 工具发现、过滤与注入

- **激活集**：`agent.state.tools` 是当前请求可见的工具全集（会话级 `setActiveToolsByName`，`agent-session.ts:928-943`）。
- **每轮注入**：`prepareNextTurnWithContext`（挂在 `_installAgentNextTurnRefresh` 上）每轮把当前工具集快照注入 `Context.tools`（`agent-session.ts:541-556`）；`streamAssistantResponse` 再把它放进 LLM `Context`（`agent-loop.ts:297-302`）。
- **系统提示可见性**：Available tools 只列带一行 snippet 的工具（`system-prompt.ts:80-84`），guidelines 按激活工具集推导（如只有 bash 没有 grep/find/ls 时提示用 bash 做文件操作，`system-prompt.ts:97-113`）；扩展工具不带 snippet 时不进该段，但仍在请求的工具协议里。内置工具的 snippet/guidelines 常量化导出（`bashToolSystemPromptContribution`/`editToolSystemPromptContribution`/`readToolSystemPromptContribution` 等，`tools/bash.ts:46-50`、`tools/edit.ts:56-66`），供 `server/create-harness.ts` 的 harness 组合路径复用。
- **token 控制**：无工具级 token 预算或自动裁剪；工具描述/参数直接进请求。

## 3. 模型调用表示与 Provider 适配

- **传输结构**：`Context.tools: Tool[]`（`packages/ai/src/types.ts:502-513`），`Tool.name/description/parameters(TypeBox)/constrainedSampling`；`ToolCall` 新增 `namespace` 字段（OpenAI Responses 动态加载/命名空间工具，`types.ts:360-368`）。
- **Provider 适配**：各 API Adapter 把 Tool 转成协议格式；Anthropic 工具带 `cache_control`/strict schema 选项（`types.ts:617-671` 的 `AnthropicMessagesCompat`），OpenAI-compatible 支持 `strict` 与 grammar 工具（`types.ts:583-597`），Bedrock 有独立 `BedrockCompat`（`types.ts:673-677`）。
- **流式工具参数**：事件流支持 `toolcall_start/delta/end`（`types.ts:523-525`），部分 Provider（z.ai `zaiToolStream`）支持流式工具调用增量。

## 4. 参数解析、校验与错误处理

- **prepareArguments**：工具可先改写原始参数（兼容 shim，`extensions/types.ts:467-468`）。
- **校验**（`validateToolArguments`，`ai/src/utils/validation.ts:317-349`）按序执行：
  1. `normalizeOptionalNulls` 删除可选字段上的 `null`（与 strict schema 的 anyOf-null 包装配套，`validation.ts:240-271`）；
  2. 用 TypeBox `Value.Convert` 做类型转换；
  3. 使用缓存编译的校验器；
  4. 非 TypeBox schema 强制转换为 JSON Schema；
  5. 失败时抛出带路径与收到的参数的错误文本。
- **失败语义**：`prepareToolCall` 捕获一切异常并返回 `{ kind: "immediate", result: createErrorToolResult(...), isError: true }`（`agent-loop.ts:600-664`），即校验失败/未知工具以工具错误结果回注，模型可据此修正重试，不会中断 agent。

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
- **执行域**：全部本地进程内执行（文件工具直接 fs；bash spawn 子进程）。`BashOperations` 接口允许扩展替换执行后端（如 SSH 远程），`createLocalBashOperations` 是默认实现（接口在 `tools/bash.ts:56-74`，函数跨 88-150；默认兜底 bash.ts:326 `options?.operations ?? createLocalBashOperations`）。
- **资源限制**：bash 无默认超时（参数可选），进程树终止 `killProcessTree`、`detached` 平台差异（`tools/bash.ts:103-126`）；输出经 `OutputAccumulator` 截断并记录 `fullOutputPath`（`tools/bash.ts`、`truncate.ts`）。

## 7. 结果回注与 UI 状态

- **回注格式**：`ToolResultMessage { role: "toolResult", toolCallId, toolName, content: (text|image)[], details?, usage?, addedToolNames?, isError }`（`packages/ai/src/types.ts:437-454`）；`createToolResultMessage`（`agent-loop.ts:773-787`）把工具结果转成消息进入上下文与 `newMessages`。
- **图片处理**：`afterToolCall` 中 `normalizeToolResultImages` 自动缩放（`agent-session.ts:516-531`，`settings.images.autoResize` 默认 2000x2000）；`blockImages` 阻止图片发送（`settings-manager.ts:45-48`）。
- **UI 状态**：`tool_execution_start/update/end` 事件驱动 `ToolExecutionComponent`（流式输出、错误色、可展开），assistant 消息中的 toolCall 块逐步更新参数；中止/错误时组件显示原因（`interactive-mode.ts:3198-3208`）。
- **持久化**：toolResult 消息在 `message_end` 落盘（`agent-session.ts:650-657`）；进行中的工具（pendingToolCalls）不持久化，进程退出后不恢复执行现场，恢复会话时历史工具结果完整可用。

## 8. MCP、插件、Skill 与子 Agent

- **MCP**：本次在 `packages/coding-agent` 与 `packages/agent` 源码中未找到 MCP 客户端/协议实现；仅注释提及外部桥可返回图片（`utils/tool-result-images.ts:15`）。结论范围：本次代码快照未提供。
- **插件/扩展**：扩展可注册工具、改写 system prompt、注入 custom 消息、提供命令（`/xxx`）与自定义会话条目；扩展工具走与内置工具相同的循环。
- **Skill**：模型可发现（system prompt 索引），也可经 `/skill:name` 由用户/流程注入，属于文本侧能力。
- **子 Agent**：`createAgentSession`（`core/sdk.ts:169`）可被扩展用作子 Agent 循环，共享相同工具循环；无内置“把当前会话委托给子 Agent”的配置。

## 9. 设计取舍与已确认边界

- **本地优先、信任分界简单**：默认“以用户权限运行”，隔离依赖容器化（README 文档给出 Gondolin/Docker/OpenShell 三种模式，见 `../../pi/README.md:38-47`），不在工具层做沙箱。
- **审批在编排层**：beforeToolCall 是唯一拦截点且由扩展实现，执行端不二次鉴权——扩展未注册该钩子时任何工具直接执行（攻击面前提是扩展代码本身可信）。
- **无工具级预算**：token 与迭代次数都没有显式上限，长尾风险由上下文压缩与用户中断兜底。
- **技能与工具分离**：文本注入的 skill 与函数式工具协议并存，避免强 schema 化，但模型依赖提示指引来“记得读 skill”。

## 10. 未验证事项

- 未运行工具调用，bash 输出流式、图片回注等运行时行为未实测。
- 扩展 `tool_call/tool_result` 钩子与 `prepareArguments` 组合路径的边界情况未逐一覆盖。
- 容器化模式（Gondolin/Docker/OpenShell）未在本仓库代码内验证（README 指向文档）。

## 11. 关键源码索引

- `packages/agent/src/agent-loop.ts:155-275`：循环；`381-406`：截断失败；`433-554`：串/并行执行；`600-664`：prepareToolCall；`582-584`：批次终止判定
- `packages/coding-agent/src/core/tools/index.ts:83-84`：内置工具清单；`tools/bash.ts:88-126`：本地执行后端
- `packages/coding-agent/src/core/extensions/types.ts:449-498`：ToolDefinition
- `packages/ai/src/utils/validation.ts:317-349`：参数校验
- `packages/ai/src/types.ts:502-513`：Tool 接口；`437-454`：ToolResultMessage
- `packages/coding-agent/src/core/agent-session.ts:928-943`：激活工具集；`541-556`：每轮注入
- `packages/coding-agent/src/core/system-prompt.ts:80-84`：工具可见性
