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

1. **工具是代码对象，没有独立的持久化实体**：内置工具固定为 8 个，分别是 read、bash、powershell、edit、write、grep、find、ls。扩展通过 `registerTool` 注册的 `ToolDefinition` 同样只存在于运行时的注册表；扩展工具的描述里带 TypeBox 参数 schema、prompt snippet、渲染回调与执行函数（`core/tools/index.ts:48-57`、`extensions/types.ts:599`）。powershell 是 Windows 下的可选工具，优先调用 pwsh.exe，找不到时退回 Windows PowerShell；它和 bash 一样以启动用户权限执行命令，区别只在向命令注入 UTF-8 输出设置（`core/tools/powershell.ts:16-46`）。MCP 与 codemode 都已作为可替换的内建扩展装配，连接工具与脚本工具需要和八个基础文件、命令工具分开理解（[装配表](../../pi/packages/coding-agent/src/extensions/index.ts#L1-L14)）。
2. **注入是会话级工具集加每轮上下文**：会话把当前可用的工具全集放在 `agent.state.tools`，每轮开始时 `prepareNextTurnWithContext` 取它的快照注入请求上下文，system prompt 的 Available tools 段只列出一句话说明（snippet）的工具（`agent-session.ts:541-556`、`:928-943`、`system-prompt.ts:80-84`）。
3. **协议是 Provider 原生 tool_calls**：`Context.tools` 随 Provider 的 stream 调用下发给各 API Adapter，由 Adapter 转成 OpenAI function calling、Anthropic tools、Google functionDeclarations 等格式。工具上的 `constrainedSampling` 字段可以要求严格 JSON schema 或 Lark/regex grammar：Provider 支持 strict 模式时，把 TypeBox schema 转换为其接受的 strict 子集，转换失败就回退，要求必须 strict 时直接报错。strict 子集转换规则为（`packages/ai/src/types.ts:492-506`、`constrained-sampling.ts:29-130`）：

```text
禁用 $ref / allOf / oneOf 等组合关键词；可选属性包成 anyOf: [prop, null]；
强制 required 与 additionalProperties: false
```

read、bash、edit、write 四个内置工具默认以 `{ type: "json_schema", strict: "prefer" }` 约束采样，Provider 不支持 strict 时按兼容策略回退（`tools/read.ts:73-78`、`tools/bash.ts:234-239`）。
4. **校验集中在执行前**：`prepareToolCall` 先交给 pi-schema 编译出的校验器做校验和值转换，未知工具与校验失败都变成 isError 的工具结果回注给模型，循环照常继续（`agent-loop.ts:718`、`packages/ai/src/utils/validation.ts`）。
5. **循环由 agent-loop 驱动，没有显式迭代上限**：内层 while 处理工具调用与 steering 队列，外层 while 排空 followUp 队列，同批并行调用并发执行、结果按调用顺序回注；模型输出被截断（`length`）时，该轮工具调用统一按失败处理。源码未发现 maxIterations 一类的轮次上限（`agent-loop.ts:155-275`、`:381-406`）。
6. **审批是回调钩子，执行端不做二次校验**：`beforeToolCall` 返回 block 就拒绝执行，扩展的 tool_call 事件走同一个钩子，项目里没有按工具或风险分级的持久化审批策略（`agent-loop.ts:619-643`）。项目信任门决定项目级 .pi 设置、资源、扩展与包是否加载，bash 执行不在它的拦截路径上；只有当 shell 路径与命令前缀取自项目设置时，信任状态才间接影响 bash 的运行参数（`settings-manager.ts:355-356`、`resource-loader.ts:397-398`、`project-trust.ts`）。
7. **基础工具执行边界是本地进程**：文件工具直接操作 fs，bash 用 `spawn` 拉起子进程并支持进程树终止、可选超时与输出截断，执行过程中可以通过 `onUpdate` 流式上报部分结果（`tools/bash.ts:88-126`）。
8. **结果回注是 toolResult 消息**：内容支持文本与图片，图片会自动缩放，失败以 `isError` 标记，`addedToolNames` 用于 Provider 原生的延迟工具加载（`packages/ai/src/types.ts:437-454`）。

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

- **统一接口**：内置工具实现 `AgentTool`，扩展工具实现 `ToolDefinition`，两者都提供名称、描述、JSON Schema 参数与执行函数，循环以同样的方式调用。`ToolDefinition` 在此基础上多带两组字段（`packages/agent/src/types.ts`、`extensions/types.ts:599`）：
  - 提示与采样：`label`、`promptSnippet`、`promptGuidelines`、`constrainedSampling`；
  - 渲染与执行：`renderShell`、`prepareArguments`、`executionMode`、`renderCall` 与 `renderResult`。
- **内置工具**：八个工具由统一构造函数生成，默认激活集是 read、bash、edit、write 四个（`tools/index.ts:113-124`）。`defaultTools` 可以在全局或项目设置里替换启动时启用的内置工具，空数组会关掉全部内置工具并保留扩展和 SDK 注册的自定义工具；`--tools` 以所有工具的严格允许名单覆盖这项选择（`core/sdk.ts:259-263`、`docs/settings.md:225-243`）。
- **扩展注册**：扩展 API 的 `registerTool` 把 `ToolDefinition` 放进扩展注册表，再由包装层转成循环统一调用的工具对象；before/afterToolCall 钩子在会话安装阶段接入（`extensions/wrapper.ts:43`、`agent-session.ts:479-533、2514-2523`）。
- **Skill 与工具的关系**：skill 走文本注入路径，模型看到的是 system prompt 里的索引与 `/skill:name` 展开的全文，和函数式工具协议分属两条通道；使用时由模型通过 read 工具或直接读取完成。
- **来源校验**：扩展加载阶段的校验（`validateExtensionProvider` 等）只针对 Provider；工具名冲突在扩展装载时由 `detectExtensionConflicts` 一类逻辑处理，并受 `_toolRegistry` 的覆盖语义影响（`resource-loader.ts:1059-1067`）。

## 2. 工具发现、过滤与注入

- **激活集**：`agent.state.tools` 保存当前请求可见的工具全集，会话通过 `setActiveToolsByName` 整体替换这份集合（`agent-session.ts:928-943`）。
- **每轮注入**：会话在每轮开始时由 `prepareNextTurnWithContext` 把工具集快照写进 `Context.tools`（`agent-session.ts:541-556`）。请求发出前，这份上下文再交给 LLM（`agent-loop.ts:297-302`）。
- **系统提示可见性**：Available tools 段只列出带一行 snippet 的工具，guidelines 由当前激活的工具集推导，例如只有 bash 而没有 grep、find、ls 时提示用 bash 完成文件操作；扩展工具不带 snippet 就不进这一段，仍照常出现在请求的工具协议里（`system-prompt.ts:80-84`、`:97-113`）。
- **提示复用**：内置工具的 snippet 与 guidelines 以常量形式导出，供 `server/create-harness.ts` 的 harness 组合路径复用（`tools/bash.ts:46-50`、`tools/edit.ts:56-66`）。
- **token 控制**：无工具级 token 预算或自动裁剪；工具描述/参数直接进请求。

## 3. 模型调用表示与 Provider 适配

- **传输结构**：`Context.tools` 是一个 Tool 数组，每项带名称、描述、JSON Schema 参数与 `constrainedSampling` 采样约束；工具调用另有 `namespace` 字段，对应 OpenAI Responses 的动态加载与命名空间工具（`packages/ai/src/types.ts:360-368、502-513`）。
- **Provider 适配**：各 API Adapter 把 Tool 转成自家的协议格式：Anthropic 侧支持 `cache_control` 与 strict schema 选项，OpenAI-compatible 侧支持 `strict` 与 grammar 工具，Bedrock 走独立的兼容类型（`types.ts:583-597`、`:617-671`、`:673-677`）。
- **流式工具参数**：事件流支持 `toolcall_start/delta/end`（`types.ts:523-525`），部分 Provider（z.ai `zaiToolStream`）支持流式工具调用增量。

## 4. 参数解析、校验与错误处理

- **prepareArguments**：工具可以先改写模型给出的原始参数，用来兼容历史的调用格式（`extensions/types.ts:467-468`）。
- **校验**：`validateToolArguments` 按固定顺序执行（`ai/src/utils/validation.ts:54`）。
  1. 工具调用自带 `argumentsError` 时直接抛错，不再尝试修复；
  2. 参数先 `structuredClone`，避免工具改写参数时污染 transcript 里的原调用；
  3. 交给缓存的校验器 `parse()`：校验器由 pi-schema 的 `compile` 生成并开启 `coerce` 值转换，容纳模型把数字写成字符串、把单值写成数组、把可选字段写成 `null` 这类偏差；遇到悬空 `$ref` 只拒绝该位置，pi-schema builders、TypeBox 或普通对象提供的 JSON Schema 都可以用；
  4. 失败时抛出带点号路径与收到的参数的错误文本。
- **失败语义**：`prepareToolCall` 捕获一切异常，返回 kind 为 `"immediate"`、`isError: true` 的工具错误结果；未知工具与校验失败都以这种结果回注，模型可以据此修正重试，循环继续（`agent-loop.ts:718`）。

## 5. 编排循环、并发与终止条件

- **循环结构**：`runLoop` 用两层 while 驱动，内层在还有工具调用或待处理消息时继续，外层排空 followUp 队列（`agent-loop.ts:155-275`）。shouldStopAfterTurn 钩子可以提前结束，回合结束事件带 `toolResults`，会话结束事件只带 `messages`（`types.ts:425-428`）。
- **并发**：同一批次默认并行执行，结果按调用顺序回注；配置把 `toolExecution` 设为 `"sequential"`，或任一工具的 `executionMode` 同为 sequential 时，整批改为串行（`agent-loop.ts:419-425、489-554`）。
- **终止规则**：整批结果的 `terminate` 都为 true 时提前结束；模型输出被截断（`length`）时该批工具调用全部按失败处理；abort 信号在工具之间传播（`agent-loop.ts:210-214`、`:582-584`）。
- **迭代上限**：源码未发现 maxIterations/轮次上限；终止依赖模型 stopReason、shouldStopAfterTurn 与队列排空。
- **超时与取消**：AbortSignal 贯穿每次工具执行，bash 工具还能按参数设置超时（`agent-loop.ts:478-481`）。

## 6. 审批、授权与执行边界

- **审批钩子**：`beforeToolCall` 返回带 block 的判定结果就拒绝本次执行，并把错误回注给模型；AgentSession 把这层钩子接到扩展的 `tool_call` 事件上（`agent-loop.ts:619-648、582-584`、`agent-session.ts:480-499`）。拒绝结果还能带终止标记：当本批所有最终化的工具结果都置该标记时，批次提前结束，扩展侧的 ToolCallEventResult 也支持这个字段（`extensions/types.ts:1072-1078`）。
- **结果改写钩子**：`afterToolCall` 在工具返回后改写内容、`isError`、usage 与 terminate，扩展的 `tool_result` 事件走同一条路径（`agent-loop.ts:724-754`）。
- **信任门**：项目信任状态决定 `.pi` 资源与 bash 等是否可用，`/trust` 命令保存这项决定；bash 执行不在它的拦截路径上，只有当 shell 路径与命令前缀取自项目设置时，信任状态才间接影响 bash 的运行参数。按工具或风险分级的常驻审批策略本次未找到，确认框式的授权界面同样未出现（`trust-manager.ts`、`project-trust.ts`）。
- **执行域**：基础文件工具直接操作 fs，bash 拉起本地子进程；MCP 连接远端或子进程服务器，codemode 在 QuickJS worker 中运行，权限按各自路径判断（§8、§11）。`BashOperations` 接口允许扩展替换执行后端，例如换成 SSH 远程，默认实现走本地子进程，未注入时回落到它（`tools/bash.ts:56-74、88-150、326`）。
- **资源限制**：bash 没有默认超时，只有参数显式指定才启用；进程树终止与 `detached` 的平台差异另有处理。输出经 `OutputAccumulator` 截断，完整内容记到 `fullOutputPath`（`tools/bash.ts:103-126`、`truncate.ts`）。

## 7. 结果回注与 UI 状态

- **回注格式**：执行结果被转成 `ToolResultMessage` 放进上下文，并追加到新消息列表。消息字段固定为 role（取值 `"toolResult"`）、toolCallId、toolName、content（文本或图片数组），以及可选的 details、usage、addedToolNames 和 isError（`agent-loop.ts:773-787`、`packages/ai/src/types.ts:437-454`）。
- **图片处理**：工具结果里的图片在 `afterToolCall` 阶段自动缩放，默认上限 2000x2000，可由 `settings.images.autoResize` 调整（`agent-session.ts:516-531`）。`blockImages` 打开时图片不随结果发送（`settings-manager.ts:45-48`）。
- **UI 状态**：`tool_execution_start/update/end` 三个事件驱动 `ToolExecutionComponent` 展示流式输出、错误色与可展开内容，assistant 消息里的 toolCall 块随参数逐步更新，中止或出错时组件显示原因（`interactive-mode.ts:3198-3208`）。
- **持久化**：toolResult 消息在 `message_end` 时落盘，进行中的工具调用（pendingToolCalls）留在内存，进程退出后不恢复执行现场；重新打开会话时，历史工具结果完整可用（`agent-session.ts:650-657`）。

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
