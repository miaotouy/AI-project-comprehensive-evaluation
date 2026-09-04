# OpenClaw Agent 工具调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态阅读 `src/agents`、`src/agents/tools`、MCP 运行时与 `packages/agent-core` 的工具构建、策略、适配和执行循环；未运行 Agent 或实际连接外部 MCP 服务
>
> 调查范围：模型可调用工具的来源、发现、注入、协议适配、参数校验、编排、审批、执行域、结果回注和恢复；不覆盖产品结构与设计基因
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的工具面是一次运行时构建的集合，而非固定全局表。核心编码工具、OpenClaw 控制工具、渠道工具、插件工具和可选 MCP 工具先按运行上下文构造，再叠加沙箱、会话、发送者、模型与客户端能力策略，最后交给 Agent Core。模型发出标准 `toolCall` 后，Agent Core 负责参数验证、审批前置钩子、串行或并行执行、结果事件和下一轮请求。

工具权限具有多层收敛特征：配置和会话策略负责目录过滤，非所有者调用者会被移除控制面工具，工具执行前仍经过 `before_tool_call` 与可信策略链。MCP 工具使用安全化名称避免冲突，并把外部结果标记为不可信网络内容。工具调用结果回注为 `toolResult` 消息；失败、拒绝、取消和未启动调用均生成可观察的结果，不以静默丢弃结束。

## 总体调用链

```text
运行入口
  -> createOpenClawCodingToolsInternal
       组装 read/write/edit/exec/process、渠道工具、createOpenClawTools、插件工具、MCP/Tool Search
  -> 会话/沙箱/Provider/客户端能力与 allow/deny 策略过滤
  -> agentLoop 将工具定义放入 LLM Context
  -> Provider 返回 assistant.toolCall
  -> 参数准备与 schema 校验 -> before_tool_call/审批/权限重验证
  -> 本地、沙箱、Gateway、渠道、插件或 MCP 执行
  -> tool_execution_* 事件 + toolResult 消息
  -> 结果进入下一轮上下文，直至无工具调用、被中止或触发循环恢复终止
```

## 1. 工具定义、来源与注册

工具装配主入口是 `src/agents/agent-tools.ts:384-445` 的 `createOpenClawCodingToolsInternal`。它根据运行选项决定是否包含基础编码、shell、渠道、OpenClaw 和插件工具；编码工具由 `createCoreCodingTools` 提供，包含受工作区根目录约束的读写编辑和 shell 工具（`src/agents/core-coding-tools.ts:96-220`）。

OpenClaw 自有工具在 `src/agents/openclaw-tools.ts:92-180` 创建，工具族包括消息发送、节点/屏幕/计算机、定时任务、会话查询与派生、Gateway 配置读取、媒体与 Web 工具、TTS、目标渠道操作以及子 Agent。渠道插件可通过 `listChannelAgentTools` 提供登录等渠道专用工具。插件工具由 `resolveOpenClawPluginToolsForOptions` 按运行上下文物化；运行时注册的环零工具和 Tool Search 工具也可加入集合。

MCP 不是静态内置工具。`agent-bundle-mcp-runtime.ts:127-162` 通过 MCP `tools/list` 分页读取目录，并设置页数、条目数和字节上限；`agent-bundle-mcp-materialize.ts:429-471` 为一次运行取得目录、租约和执行闭包，再把目录投影为 Agent 工具。MCP 服务器可同时声明 resources/prompts，投影为对应的只读工具。

## 2. 工具发现、过滤与注入

装配后依次经过消息提供方过滤、模型提供方过滤和会话能力策略（`agent-tools.ts:918-962`）。策略来源包括全局/Agent profile、沙箱、群组会话、插件 allow/deny、发送者是否为 owner、运行时 allowlist、客户端 capabilities 与模型兼容性；非 owner 调用者还会应用 Gateway owner-only denylist（`agent-tools.ts:937-960`）。内存压缩触发的特殊运行只保留 `read` 与追加式 `write`（`agent-tools.ts:890-917`）。

通过过滤的工具绑定动作描述，并由 `toToolDefinitions` 转为会话级 `ToolDefinition`；工具集合随后作为 `AgentContext.tools` 进入模型流（`packages/agent-core/src/agent-loop.ts:515-542`）。当启用 Tool Search 时，搜索/描述/调用控制工具可替代一次性暴露完整目录；工具策略仍在最终授权阶段重算。子 Agent 可继承父运行最终授权后的 allowlist（`agent-tools.ts:963-989`），而非重新信任原始配置。

## 3. 模型调用表示与 Provider 适配

Agent Core 使用统一的 `AssistantMessage` 内容块；工具调用块类型为 `toolCall`，包含调用 id、名称和参数（`packages/agent-core/src/types.ts:45-46`）。`streamAssistantResponse` 将内部消息经 `convertToLlm` 转换为 Provider 请求，并把 Provider 流中的 tool-call start/delta/end 合并回 assistant 消息（`agent-loop.ts:515-600`）。Provider 的协议差异由 `StreamFn`/LLM runtime 适配层承担，Agent 工具本身不直接依赖某一厂商格式。

`src/agents/agent-tool-definition-adapter.ts:250-430` 把运行时 `AgentTool` 的 schema、描述、执行模式和更新回调转为会话工具定义，同时兼容新旧 execute 参数顺序。客户端托管工具在适配前检查名称冲突；与现有工具或彼此重复的规范化名称会被拒绝（同文件 `findClientToolNameConflicts`）。

## 4. 参数解析、校验与错误处理

各工具在创建时提供 TypeBox/JSON Schema；例如 `read` 的路径、offset、cursor 和 optional 字段由 `readToolInputSchema` 声明，执行体再次检查 offset/cursor 的整数范围和文件路径解析（`src/agents/sessions/tools/read.ts:464-550`）。MCP 输入 schema 从服务器目录标准化后直接放入投影工具；资源与 prompt 工具对 `uri`、`name` 和字符串参数执行运行时类型检查（`agent-bundle-mcp-materialize.ts:330-420`）。

Agent Core 在批量执行前按工具名解析并验证调用；找不到工具、参数无效或准备失败都会形成未执行的错误结果，而不会调用执行体（`packages/agent-core/src/agent-loop.ts:618-729`）。适配器会把非标准返回值强制转换为带 `content[]` 的结果；执行异常被记录并转成 `{status:"error", tool, error}` 文本结果，取消信号则向上抛出以进入中断路径（`agent-tool-definition-adapter.ts:180-248`）。

## 5. 编排循环、并发与终止条件

`packages/agent-core/src/agent-loop.ts:276-510` 是“模型响应—工具批次—下一轮模型”主循环。仅当 assistant 的 `stopReason` 为 `toolUse` 且含调用块时才执行工具；工具结果追加到下一轮上下文。批次默认可并行执行，但任一工具声明 `executionMode:"sequential"` 或配置要求串行时，批次切换为逐个预检、执行和回注（`agent-loop.ts:618-683`）。并行模式先顺序准备和审批，再并发启动允许的工具，执行事件按完成顺序发出，而 toolResult 消息按 assistant 原始顺序回注（`agent-loop.ts:865-1030`）。

工具执行前后都检查 abort；串行执行在每个调用前检查 steering 队列，队列消息会使未启动尾部调用生成 `skipped` 结果。工具循环检测在 `before_tool_call` 入口运行，首次 critical loop 可走一次恢复；再次检测到 critical loop 时生成终止消息且不执行被阻断调用（`agent-tools.before-tool-call.policy.ts:113-155`、`agent-loop.ts:1683-1720`）。

## 6. 审批、授权与执行边界

审批不是 UI 单层行为，而是执行前策略链的一部分。`runBeforeToolCallHook` 先做循环准入、技能工作台与语音确认，再执行可信策略和插件 hook；策略可改写参数、阻断或返回 `requireApproval`（`src/agents/agent-tools.before-tool-call.policy.ts:158-220`）。审批请求由 Gateway 或嵌入式 approval broker 承载，允许一次、始终允许、拒绝和超时等决策；超时和 Gateway 不可用默认 fail-closed（`src/agents/agent-tools.before-tool-call.approval.ts:1-35,130-220`）。

执行域按工具不同分布：读写编辑和 shell 运行在主机或 sandbox workspace；Gateway、消息和渠道工具经 Gateway/渠道适配器执行；MCP 经 stdio、SSE 或 streamable HTTP transport 执行（`agent-bundle-mcp-runtime.ts:77-103`）；节点、浏览器、计算机等工具需相应客户端能力。沙箱根、workspace-only/read-only、进程 scope key、超时和 safe-bin 策略在 `createCoreCodingTools` 与 `agent-tools.ts:500-640` 注入，阻止工具越过授权工作区；这些边界不等同于操作系统级隔离，实际隔离强度取决于运行配置与沙箱实现。

## 7. 结果回注、执行状态与恢复

工具返回 `AgentToolResult`，内容由文本或图片块组成，可附 `details`、进度和网络内容来源标记（`packages/agent-core/src/types.ts:529-584`）。Agent Core 为每个调用发出 `tool_execution_start/update/end`，再构造 `toolResult` 消息并按顺序交给下一轮模型（`agent-loop.ts:729-864`）。MCP 结果转换会删除 `_meta`，把结构化值序列化为 JSON 文本，并标记 `untrustedMcpOutput`；MCP 工具结果可附 MCP App 预览，但 requester-scoped 服务器不会创建跨运行视图（`agent-bundle-mcp-materialize.ts:429-520`）。

工具调用与结果主要作为运行时事件和会话消息交给上层持久化；工具状态本身不是独立数据库实体。未启动、被 steering 跳过、策略拒绝、参数错误、执行失败和取消均有对应 result/diagnostic，便于 UI 或渠道显示。MCP runtime 以 session 级租约管理连接，目录失败有重试/冷却常量，运行结束释放租约；重启后不会恢复正在执行的工具，新的运行需重新建目录与连接（MCP runtime `:77-103,95-103`，materialize `:434-446`）。

## 8. MCP、插件、Skill 与子 Agent

- **MCP**：服务器配置解析、传输连接、`tools/list` 分页和安全命名在 bundle MCP runtime；调用闭包在 materialize 阶段绑定，服务器声明的并行能力决定工具执行模式。服务器输出被视为不可信网络内容。
- **插件**：插件可贡献工具和 before-tool-call/trusted policy；工具元数据携带插件 id、MCP 信息和可选审批模式，随后仍经过核心策略流水线。插件工具 allowlist 会合并运行时授权 grant，而 denylist 与 owner-only 工具在最终过滤阶段生效。
- **Skill**：Skill 本身不是任意代码工具目录；其读取路径快照和 Skill Workshop 审批作为工具构建与 before-hook 的输入。memory 触发运行被限制为只读与追加写入。
- **子 Agent**：`sessions_spawn` 是 OpenClaw 工具，可创建 subagent 或 ACP 运行；子运行继承经过授权的工作区、工具 allow/deny 和执行身份，而不是父模型原始参数。`sessions_send`、`sessions_yield` 和并行等待工具受 embedded/swarm 等模式限制（`src/agents/openclaw-tools.ts:541-610`）。

## 9. 设计取舍与已确认边界

- 工具目录按运行上下文重建，使群组、发送者、模型能力、沙箱和客户端能力可以在同一入口收敛；代价是目录构建涉及多层策略和可选运行时。
- 核心工具、OpenClaw 工具、插件与 MCP 共享 Agent Core 的 toolCall/toolResult 契约，协议适配集中在流和定义适配器；工具实现只需遵守 `AgentTool`。
- 串行/并行是每批次动态决定的：并行提高吞吐，工具声明 sequential 可阻止不安全并发；结果事件顺序和消息回注顺序明确分离。
- 审批与策略均在执行边界前重验证，避免仅凭 UI 展示或模型输入授予权限；超时、无审批表面和 hook 失败默认阻断。
- MCP 连接以 session 租约和有限目录预算管理，外部结果显式标为不可信；本笔记未确认具体服务器是否自行执行额外鉴权。

## 10. 未验证事项

- 未运行真实 Provider 流，因此不同厂商 tool-call 增量拼接、并行批次和中止时序未做运行验证。
- 未运行 Gateway/嵌入式审批流程，审批 UI 呈现、超时实际文案和多设备 reviewer 路由仅由源码确认。
- 未连接 stdio/SSE/HTTP MCP 服务器，目录分页上限、连接冷却与 server `supportsParallelToolCalls` 的真实效果未实测。
- 沙箱、host/node 进程隔离、safe-bin 和跨平台路径边界未进行系统级安全验证；这里只记录调用方传入的策略边界。
- 工具结果持久化由上层 Agent/session 运行时负责，重启中断任务是否留下完整审计记录需结合会话与渠道专项运行调查。

## 11. 关键源码索引

- `src/agents/agent-tools.ts:384-445,687-989`：工具装配、运行上下文、插件与策略过滤
- `src/agents/core-coding-tools.ts:96-220`：读写编辑与 shell 工具构建、workspace/sandbox 边界
- `src/agents/openclaw-tools.ts:92-180,400-610`：OpenClaw 工具注册与子 Agent/渠道能力
- `src/agents/agent-tool-definition-adapter.ts:180-430`：定义适配、hook、结果归一化和客户端工具冲突
- `src/agents/agent-tools.before-tool-call.policy.ts:100-260`：循环准入、可信策略、hook 与审批顺序
- `src/agents/agent-tools.before-tool-call.approval.ts:1-220`：Gateway/嵌入式审批、超时和 fail-closed
- `src/agents/agent-bundle-mcp-runtime.ts:77-162`：MCP transport、目录分页与连接上限
- `src/agents/agent-bundle-mcp-materialize.ts:250-520`：MCP 工具安全命名、schema 投影、调用与不可信结果
- `packages/agent-core/src/types.ts:45-188,529-650`：toolCall、AgentTool、结果与事件契约
- `packages/agent-core/src/agent-loop.ts:276-510,515-600,618-1030`：模型流、工具批次、并发/串行和回注
- `src/agents/sessions/tools/read.ts:464-550`：典型工具 schema、参数校验、截断与图片结果
