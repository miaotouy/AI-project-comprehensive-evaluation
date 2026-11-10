# LobeHub Agent 工具调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`（monorepo，重点 `apps/server`、`apps/desktop`、`packages/agent-runtime`、`packages/builtin-tools`、`packages/context-engine`、`packages/types`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：只读源码梳理（Read/Grep/Glob + 后台子调查代理核实内建工具清单、扩展机制、子代理编排三个子领域）；未修改 LobeHub 仓库任何文件
>
> 调查范围：模型能够发现、请求并触发执行的工具（builtin / plugin / MCP / connector）；消息渲染器、纯 UI 功能与模型供应商自身能力属于相邻主题
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 把“模型能看到什么工具”“工具在哪执行”“谁批准执行”严格拆成三条独立的判定链，且服务端与前端复用同一套上下文引擎、Agent 运行时和内建工具实现。

1. **工具目录**是 `packages/builtin-tools/src/index.ts` 里一个 **42 项**的静态注册表（条目见维度 9），manifest 本体来自 39 个 `@lobechat/builtin-tool-*` 包（每包自带 `manifest.ts` 与 `resolveManifest`），注册表只做装配。每项声明标识符、manifest、隐藏/可发现状态和动态解析入口；manifest 类型 `builtin|default|markdown|mcp|standalone` 决定 schema 来源。注册表还导出七组 id 集合，供注入与分享判定按用途取用：

   | 用途 | 集合 |
   |---|---|
   | 默认工具与常驻工具 | `defaultToolIds`、`alwaysOnToolIds` |
   | 激活模式受控与手动模式排除 | `activationModeControlledToolIds`、`manualModeExcludeToolIds` |
   | chat 模式白名单与群组 supervisor 集 | `chatModeAllowedToolIds`、`groupSupervisorToolIds` |
   | 运行时托管与分享放行判定 | `runtimeManagedToolIds`、`isAgentShareAllowedBuiltinIdentifier` |

2. **注入到模型的可见集合**由 context-engine 的 `ToolsEngine.generateTools()` 统一裁剪（`packages/context-engine/src/engine/tools/ToolsEngine.ts`）：启用检查器先判断显式激活是否允许绕过，再做平台过滤，最后应用声明式规则表。服务端入口按三种模式分别给出规则与默认工具（`apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:332-347`）：chat mode 强制关闭显式激活，图像生成只有处于 pinned 状态才注入；agent mode 为 bot 会话补消息工具、为群组补 supervisor 编排工具，并应用 remote-device 锁定期规则。
3. **审批**由 `GeneralChatAgent.checkInterventionNeeded` 按固定顺序判定，阶段顺序本身带语义（明细见维度 6.2）：安全黑名单的 always 规则排在最前，任何模式都绕不过；其后依次是动态规则、headless 放行、required 规则、静态 always、自动运行、未知 manifest、白名单与 manual 配置。批准后进入 `waiting_for_human` 状态机，待审批工具消息持久化在数据库，前端依据工具调用 chunk 和审批事件渲染卡片。
4. **执行位置**由 `ToolExecutionService.executeTool` 分派（`apps/server/src/services/toolExecution/index.ts:82-179`）：
   - builtin 走服务端 builtin 执行器；
   - MCP 按连接类型分三路：

     | 连接类型 | 条件 | 执行位置 |
     |---|---|---|
     | cloud | — | market/discover gateway |
     | stdio | 设备网关已配置，且有活跃设备与用户身份 | 转发到用户设备 |
     | stdio（无设备网关）、http/sse | — | 本地 MCP client，在服务器进程内 spawn 或由桌面 Electron 主进程 spawn |

   - 所有路径执行前都先查 connector 权限表，disabled 一律硬拒绝，覆盖 MCP、market skills、Composio 与 qstash；
   - local-system 工具的客户端执行收敛到一个共享入口 `packages/tool-runtime/src/LocalSystemExecutionRuntime.ts`，cwd 注入也在其中，路径范围判定迁到 `tool-runtime/src/pathScope.ts`。桌面端另有 Local Sandbox 执行环境，`packages/device-sandbox` 提供沙箱环境创建、SRT 运行时与设备端安装，装配在 `src/helpers/localSandbox.ts`，执行时按 `executionTarget.ts` 的判定选择沙箱围栏或直接裸 spawn（沙箱能力探测、安装与工作目录的细节见维度 13 与生成式输出笔记）。
5. **结果回注**分两层：共享的 `truncateToolResult` 默认按 25,000 字符截断（`packages/prompts/src/toolResult/index.ts`，归档内容读取面列在 `ARCHIVE_BYPASS_IDENTIFIERS` 里作为例外），服务端再归档：把超长结果整体写入 topic document 虚拟文件系统（文件名取内容哈希前 32 位、写入后校验），只把窗口化片段加提示回注，归档内容可用同一套行号窗口分页读取。
6. **循环终止契约**由共享 `runAgentLoop` 承担。循环只负责停止条件与下一步上下文，服务端锁、持久化、hook、trace 和浏览器直跑仍由各宿主的 step 实现承担；统一停止原因覆盖正常完成、错误、中断、等待人工或异步工具、成本上限、调用方步数预算和无后续上下文。见 `packages/agent-runtime/src/loop/index.ts:5-28,130-166`。
7. **共享 Agent 访客工具面**在工具装配和实际执行两处都受门禁。分享配置只授予明确列入 `toolGrants` 的工具或 API；装配阶段按内置白名单判定与分享用的 manifest 裁剪可见集合，builtin dispatch 再经 `grants.ts` 与运行期的 `shareRunGate.ts` 复核，设备、凭据、子 Agent 与未授权数据工具不会因模型猜到名字而执行。

以下各节给出精确到代码行的证据；其中常驻工具集合 `alwaysOnToolIds` 只在 agent mode 生效（维度 2.1），`disabled` 工具在统一执行入口的 connector 权限表处拦截（维度 7.3）。

## ASCII 调用链图

```text
用户发消息 / API 调用
  -> apps/server AgentRuntimeService / execAgent
     -> createServerAgentToolsEngine (apps/server/src/modules/Mecha/AgentToolsEngine/index.ts)
        决定 executionPlan (local/sandbox/device/none) 与 chatMode/agentMode/customMode 规则
        -> createServerToolsEngine -> ToolsEngine (packages/context-engine)
           manifestSchemas = plugins ++ builtinManifests(resolveManifest per context) ++ additionalManifests
           enableChecker = createEnableChecker({ allowExplicitActivation, rules })
  -> ToolsEngine.generateToolsDetailed()
     -> filterEnabledPlugins (functionCallChecker 先判模型是否支持 FC)
     -> convertManifestsToTools -> ToolNameResolver.generate(identifier, apiName, type)
        "identifier____apiName[____type]"，超长/非法字符走 MD5HASH_ 压缩
  -> LLM Provider（原生 tool_calls / function_call）
  -> callLlmFinalizer.finalizeCallLlmTurn
     -> ToolNameResolver.resolve(toolCalls, manifests, offeredToolNames) -> ChatToolPayload[]
     -> sanitizeToolCallArguments 修复非法 JSON
  -> GeneralChatAgent.runner (phase: llm_result)
     -> checkInterventionNeeded()  [九阶段判定，见下文“审批”维度]
        -> toolsToExecute      -> call_tool / call_tools_batch (executors/tool.ts)
        -> toolsNeedingIntervention
             headless -> resolve_blocked_tools (BLOCKED_TOOL_CONTENT，success:false)
             其他模式 -> request_human_approve (executors/humanApprove.ts)
                持久化 pending tool message，status='waiting_for_human'
                前端渲染 Intervention 卡片，用户 approve/reject
                -> HumanInterventionHandler.process (apps/server/src/services/agentRuntime)
                   approve -> phase: human_approved_tool -> call_tool(skipCreateToolMessage)
                   reject  -> rejectAndContinue(phase:user_input) 或 rejectAndHalt(status:interrupted)
  -> call_tool/call_tools_batch 实际执行
     -> ToolExecutionService.executeTool
        0. getConnectorToolPermission -> disabled? 硬拒绝 (buildBlockedToolResponse)
        1. type==='mcp'   -> executeMCPTool
             mcpParams.type==='cloud' -> executeCloudMCPTool -> DiscoverService.callCloudMcpEndpoint (market gateway)
             mcpParams.type==='stdio' && deviceGateway.isConfigured && activeDeviceId -> executeMcpViaDevice (转发到用户设备)
             其余 -> mcpService.callTool (本地/服务器进程内 MCP client)
        2. type==='builtin' -> BuiltinToolsExecutor.execute -> serverRuntimes/<tool>.ts
     -> truncateToolResult(content, toolResultMaxLength ?? 25_000)
  -> 结果回写 tool message -> 下一轮 call_llm
```

## 1. 工具定义与注册

### 1.1 builtin registry 结构

`packages/builtin-tools/src/index.ts` 是一个 42 项的静态工具注册表（每项来自对应 `@lobechat/builtin-tool-*` 包导出的 manifest），每项包含以下字段：

- `identifier`：工具标识符，如 `lobe-web-browsing`
- `manifest`：静态工具描述
- `resolveManifest?`：按上下文动态生成描述，例如在子代理/群组内隐藏子代理调用
- `hidden?`：从用户界面隐藏，但仍可能被系统注入
- `discoverable?`：是否出现在发现/市场列表；浏览器和本地系统工具按桌面环境决定

`LobeBuiltinTool`/`BuiltinToolManifest` 类型定义在 `packages/types/src/tool/builtin.ts:231-357`。`meta`（avatar/description/tags/title）被 hoist 到顶层供 UI/discovery/token 估算读取；注册表尾部还导出安装态相关的 `defaultUninstalledBuiltinTools`。

### 1.2 manifest 类型语义差异

`ToolManifestType = 'builtin' | 'default' | 'markdown' | 'mcp' | 'standalone'`（`packages/types/src/tool/manifest.ts:5`）：

- **builtin**：框架内置工具，schema 硬编码在 `packages/builtin-tool-*/src/manifest.ts`，执行体位于服务端 `serverRuntimes/*.ts` 或桌面客户端执行器。
- **default**：用户导入的普通自定义插件，按 OpenAPI 或 simple 两种方式组装，参数定义直接取自导入的 manifest JSON；当前方式记录在 `CustomPluginParams.apiMode`（`packages/types/src/tool/plugin.ts:14`）。
- **mcp**：Model Context Protocol 工具，连接方式（stdio、http 或 cloud）记在 manifest 的 `customParams.mcp`（见维度 10）。
- **standalone**：独立 UI 插件，界面形态（内嵌 iframe 或前端 module）、地址与可选尺寸由 `ToolManifest.ui` 声明（`packages/types/src/tool/manifest.ts:32`）；这类工具向用户提供可交互界面，函数调用 API 属于可选。
- **markdown**：以 Markdown 文本描述能力的轻量插件类型，类型定义与 default 同构（`api[]` 加可选的 openapi），语义上不依赖 OpenAPI schema。

`ToolNameResolver.generate` 在生成模型可见的函数名时，会把非 builtin/default 类型编码进名字尾部（`packages/context-engine/src/engine/tools/ToolNameResolver.ts:92-95`），例如自定义 MCP 工具名形如 `custom_mcp____toolName____mcp`。

### 1.3 api 级与 manifest 级字段关系

`LobeChatPluginApi`（`packages/types/src/tool/builtin.ts:171-229`）每个 api 除 `name`/`description`/`parameters` 外，还可以带：

- `humanIntervention?: ExtendedHumanInterventionConfig`：api 级审批策略，优先级高于 manifest 级 `humanIntervention`（见维度 6）
- `defaultTimeoutMs?`：默认 120,000ms，服务端 clamp 到 `[1_000, 800_000]`（字段注释见 `builtin.ts:174-182`；clamp 实现见维度 5）
- `renderDisplayControl?`：`'collapsed'|'expand'|'alwaysExpand'`，纯 UI 展示行为，不影响模型
- `work?: PluginApiWorkConfig`：声明式 Work 注册（create/update/delete 一个 document/task 资源），执行成功后由 dispatch 层自动注册，不需要工具自己写注册代码

这些框架字段（humanIntervention 与 work）在生成模型可见 schema 时会被剥离：转换函数只取 api 的描述、名称与参数定义，框架字段不随 schema 发给模型（`packages/context-engine/src/engine/tools/ToolsEngine.ts:265-274`）。

**依据**：[builtin registry](../../lobehub/packages/builtin-tools/src/index.ts)、[各 builtin-tool 包](../../lobehub/packages/builtin-tool-lobe-agent/src/manifest.ts)、[manifest 类型](../../lobehub/packages/types/src/tool/manifest.ts)、[builtin 类型定义](../../lobehub/packages/types/src/tool/builtin.ts)、[plugin 类型](../../lobehub/packages/types/src/tool/plugin.ts)、[ToolNameResolver](../../lobehub/packages/context-engine/src/engine/tools/ToolNameResolver.ts)、[ToolsEngine](../../lobehub/packages/context-engine/src/engine/tools/ToolsEngine.ts)。

## 2. 工具发现与注入

### 2.1 agent mode / chat mode 白名单的具体判定代码

服务端入口 `createServerAgentToolsEngine`（`apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:149-347`）先解析三种模式：

```ts
const toolMode = resolveToolMode(agentConfig.chatConfig ?? undefined);  // 'agent' | 'chat' | 'custom'
const isChatMode = toolMode === 'chat';
const isCustomMode = toolMode === 'custom';
```

`resolveToolMode`（`src/helpers/executionTarget.ts:28-31`）：显式 `chatConfig.toolMode` 优先；否则 `enableAgentMode === false` → `'chat'`，其余为 `'agent'`。

三种模式对应不同的规则对象和默认工具集合（本快照 `index.ts:289-349`）：

- **chat 模式**（`index.ts:289-294`）：只有图像生成、知识库、记忆和网页浏览四个能力可能开启；其中图像生成**必须处于 pinned 状态才注入**。chat mode 不允许显式激活其他工具（`index.ts:392`）。
- **custom 模式**（`index.ts:300`）：工具集合严格等于 agent 声明的插件列表，不叠加常驻工具、默认工具或激活器，适用于聚焦型内建子代理（如 verify agent）。
- **agent 模式**（`index.ts:302-349`）：在用户插件和常驻工具之上，再按运行环境、设备代理、在线状态和锁定状态加入系统工具；bot 会话自动加入消息工具，群组 supervisor 使用统一的编排工具集。设备能力不可用时，构建阶段还会从 manifest 中物理剔除设备工具。

### 2.2 用户启用状态

用户在 agent 配置里选择的插件在 agent 模式下被展开成 `rules` 表中的启用项，custom 模式下则是唯一来源（`index.ts:251, 255`）。单个 connector 工具的启用与禁用另走 `connectorTools` 表，检查落在执行时，注入阶段不做过滤：被 connector 禁用的工具 schema 仍出现在模型的工具列表里，到调用时才被硬拒绝（见维度 7 的 `getConnectorToolPermission`）。

### 2.3 按模型能力过滤

`generateTools` 与 `generateToolsDetailed` 第一步调用注入的 function-call 检查器；模型不支持 function calling 时直接返回 `undefined`，不注入任何工具（`packages/context-engine/src/engine/tools/ToolsEngine.ts:161-171`）。服务端把这个检查器接到 `apps/server/src/services/aiAgent/index.ts:2784-2787`：

```ts
const isModelSupportToolUse = (m: string, p: string) => {
  const info = builtinModels.find((item) => item.id === m && item.providerId === p);
  return info?.abilities?.functionCall ?? true;
};
```

即按 model-bank 里的 `abilities.functionCall` 字段判断，未知模型默认认为支持。若模型支持 FC 但不支持某个具体 plugin（当前实现未见按 plugin 级能力二次过滤，只有整体开关），`filterEnabledPlugins`（`ToolsEngine.ts:176-248`）会把所有 `pluginIds` 标记为 `incompatible`。

### 2.4 注入到请求 tools 的位置

最终工具数组在每个 step 合并：operation 级快照、累积的 step 级激活（activator 动态激活、设备工具、@mention 工具）与当前 step 的新激活，再按本轮允许的工具名集合做二次过滤；超过 `maxSteps` 触发强制收尾时，这段逻辑把已激活工具整体清空，最后一轮模型调用因此不带任何工具（`packages/context-engine/src/engine/tools/ToolResolver.ts:29-120, 84-93`，含 `forceFinish` 分支）。

**依据**：[AgentToolsEngine](../../lobehub/apps/server/src/modules/Mecha/AgentToolsEngine/index.ts)、[builtin-tools 常量](../../lobehub/packages/builtin-tools/src/index.ts)、[executionTarget.resolveToolMode](../../lobehub/src/helpers/executionTarget.ts)、[ToolsEngine](../../lobehub/packages/context-engine/src/engine/tools/ToolsEngine.ts)、[ToolResolver](../../lobehub/packages/context-engine/src/engine/tools/ToolResolver.ts)、[execAgent 的 functionCall checker](../../lobehub/apps/server/src/services/aiAgent/index.ts)。

## 3. 模型调用表示与解析

### 3.1 identifier/apiName 的编解码

LobeHub 完全走**原生 tool call** 路径（OpenAI/Anthropic/Gemini 等 provider 的结构化 `tool_calls`/`function_call` 字段），没有观察到文本协议解析器。

编码由 `ToolNameResolver.generate` 完成：它把 identifier、apiName 与类型拼成 `identifier____apiName[____type]`，builtin 和 default 类型省略末尾的类型段。拼接前先净化每个片段，命中 `[\w-]` 以外字符（如中文、点号）的片段整段替换为 `MD5HASH_` 加 12 位 md5。拼好的名字达到 `TOOL_NAME_MAX_LENGTH` 上限（默认 64，对应 OpenAI 的名字长度限制，可用环境变量调整或设 0 关闭）时，先对 apiName 做哈希，仍然超长再对 identifier 做哈希。三个环节的实现见 `packages/context-engine/src/engine/tools/ToolNameResolver.ts:17-122`。

解码：按分隔符 `____` 切开名字；模型返回的名字缺分隔符时（部分模型只吐裸 apiName），只在“本轮实际发给模型的工具名集合”内做唯一匹配来恢复 identifier，这层白名单挡住模型猜出未启用工具、绕过注入过滤；哈希过的片段通过反查哈希表还原（`packages/context-engine/src/engine/tools/ToolNameResolver.ts:135-217, 149-178, 180-212`）。

### 3.2 流式期间的工具事件与 `tools_calling`

流式 LLM 调用完成后（`callLlmFinalizer.finalizeCallLlmTurn`，`packages/agent-runtime/src/executors/callLlmFinalizer.ts:258-379`）：

1. 发 `stream_end` 事件，携带 `toolsCalling: output.toolsCalling`（`callLlmFinalizer.ts:283-295`）
2. 若无工具调用且非 abort，额外发 `visible_output_end`（提示前端"最终答案已完整"，`callLlmFinalizer.ts:298-316`）
3. 持久化最终 assistant message（`tools: sanitizePersistedTools(output.toolsCalling)`），`nextContext.phase = 'llm_result'`，payload 含 `hasToolsCalling`/`toolsCalling`

工具真正执行时，单次与批量工具执行器在动手前发 `tool_start`、结束后发 `tool_end`；审批阶段由人工审批执行器发一条 `tools_calling` chunk，附带每个 tool call 的待批准消息 id 映射，前端据此先拉取占位消息，随后连发审批请求与待处理两个事件，pauseForTools 复用同一套序列。事件发送点与审批 chunk 在 `packages/agent-runtime/src/executors/tool.ts:238-659`，人工审批实现见同目录 `humanApprove.ts:187-206`。

### 3.3 参数解析与容错

模型返回的 `arguments` 是字符串。三层容错：

1. `sanitizeToolCallArguments`（`packages/utils/src/sanitizeToolCallArguments.ts:18-29`）：非法 JSON 先做部分解析，仍失败则整体替换为空对象，避免一条历史消息里的坏 JSON 让严格 provider（如 NVIDIA NIM）在回放整段历史时对整个请求返回 400。
2. `ToolArgumentsRepairer`（`packages/context-engine/src/engine/tools/ToolArgumentsRepairer.ts:56-137`）：修复部分模型（如 Claude haiku-4.5）把整个参数对象转义塞进第一个字段的畸形输出，按 schema 的必填字段名反向重建 JSON。
3. `parseToolArgs`（`packages/agent-runtime/src/executors/tool.ts:104-120`）：执行前再做一次保守解析，失败则回退空对象；这个失败不阻止执行，只影响 hook 预览用的参数快照。

**依据**：[ToolNameResolver](../../lobehub/packages/context-engine/src/engine/tools/ToolNameResolver.ts)、[callLlmFinalizer](../../lobehub/packages/agent-runtime/src/executors/callLlmFinalizer.ts)、[humanApprove executor](../../lobehub/packages/agent-runtime/src/executors/humanApprove.ts)、[tool executor](../../lobehub/packages/agent-runtime/src/executors/tool.ts)、[sanitizeToolCallArguments](../../lobehub/packages/utils/src/sanitizeToolCallArguments.ts)、[ToolArgumentsRepairer](../../lobehub/packages/context-engine/src/engine/tools/ToolArgumentsRepairer.ts)。

## 4. 参数校验与规范化

### 4.1 schema 校验点

LobeHub **没有在工具执行前对参数做 JSON Schema 结构校验**（未发现 ajv/zod 对 `arguments` 按 `api.parameters` 强制校验的代码路径；`ToolArgumentsRepairer`/`sanitizeToolCallArguments` 只保证字符串能被解析为合法 JSON，不校验字段类型/必填项是否符合 schema）。参数最终是否合法，由各工具自己的执行体（`serverRuntimes/*.ts`）在业务逻辑里判断，出错时返回 `{ success: false, error }`，再经 `classifyToolError` 分类。这与很多工具框架（如强制 ajv validate）不同，是一个**未做强类型校验**的设计选择。

`normalizeToolParameters`（`packages/context-engine/src/engine/tools/utils.ts:27-33`）只是把缺失的 required 字段补成空数组，用于兼容部分严格 provider 对 null 值的拒绝，跟安全校验无关。

### 4.2 参数错误的处理

`errorClassification.ts`（`apps/server/src/services/toolExecution/errorClassification.ts`）把工具执行错误归成 `ToolErrorKind = 'replan' | 'retry' | 'stop'` 三类，分别对应重新规划参数、重试和终止：

- `replan`：`BAD_REQUEST`、`INVALID_ARGUMENT`、`MANIFEST_NOT_FOUND` 等，提示模型重新规划参数
- `retry`：`RATE_LIMITED` 等
- `stop`：`FORBIDDEN`、`UNAUTHORIZED` 等

分类同时看错误 `code`、HTTP `status` 和消息关键词兜底。状态码的映射是 400/404/409/422 归 `replan`，401/403 归 `stop`，429/5xx 归 `retry`。

### 4.3 URL/路径类参数的处理面

路径类与 URL 类参数各有一套边界机制。本地文件工具用“越出工作目录就请人确认”的方式管住路径，网络工具则在请求层禁掉私网地址。

**本地文件路径**由 lobe-local-system 的 pathScopeAudit 动态解析器负责（`packages/builtin-tool-local-system/src/interventionAudit.ts:72-106`）。它从参数里取出路径候选，判断是否越出 `metadata.workingDirectory`：越界时签发 required 策略要求人工介入，未越界按 never 免审批。路径候选来自这些字段：

- `path`、`file_path`、`directory`、`oldPath`、`newPath`
- `pattern`：仅当取值以 `/` 开头时纳入

七个文件类 api 共用同一个 resolver：

- `readFile`、`writeFile`、`editFile`、`moveFiles`
- `searchFiles`、`grepContent`、`globFiles`

manifest 里的声明形如 `humanIntervention: { dynamic: { type: 'pathScopeAudit' } }`，在本节引用的 manifest 中多处出现（`packages/builtin-tool-local-system/src/manifest.ts:13-19`）。这套判断只作为**审批触发条件**，实际文件访问不受它拦截。越界判断函数 `isPathWithinWorkingDirectory` 的实现见 `interventionAudit.ts:19-32`。

`runCommand` 走另一条路：它不做路径提取，直接声明 `humanIntervention: 'required'`（`manifest.ts:229`），因此 shell 命令内嵌的任意路径不经过 `pathScopeAudit`，只靠通用的 required 审批和全局安全黑名单（维度 6）兜底。

**URL 类参数**的网络访问范围分两层。`lobe-web-browsing` 的默认爬虫 `naive` 通过 `ssrfSafeFetch`（`packages/ssrf-safe-fetch/index.ts:64-128`）发起请求，私有/内网地址会被拒绝并抛 `SSRF blocked` 错误；其余 crawler 实现只转发到固定的第三方服务域名，不直接对用户提供的 URL 发起请求：

- `jina`、`browserless`、`search1api`
- `tavily`、`exa`、`firecrawl`

SSRF 过滤把 `request-filtering-agent` 的 HTTP/HTTPS agent 接到 `fetch` 请求上，`allowPrivateIPAddress` 默认关闭，由环境变量 `SSRF_ALLOW_PRIVATE_IP_ADDRESS` 控制（`index.ts:72-83`）。

MCP 的 HTTP 客户端没有这一层：服务端 MCP HTTP client（`src/libs/mcp/client.ts:206-208`）与桌面 `MCPClient`（`apps/desktop/src/main/libs/mcp/client.ts:53-56`）用官方 `StreamableHTTPClientTransport` 直连用户配置的 MCP server URL，未包 `ssrfSafeFetch` 或等价的私网地址过滤；该第三方 SDK 自身是否有内建私网过滤未审查源码（列入未验证事项）。

**依据**：[interventionAudit.ts](../../lobehub/packages/builtin-tool-local-system/src/interventionAudit.ts)、[local-system manifest](../../lobehub/packages/builtin-tool-local-system/src/manifest.ts)、[errorClassification](../../lobehub/apps/server/src/services/toolExecution/errorClassification.ts)、[ToolsEngine utils](../../lobehub/packages/context-engine/src/engine/tools/utils.ts)。

## 5. 编排循环

循环外壳由 `runAgentLoop` 统一，宿主只提供单步函数。它在第一步前就检查已终止或 parked 状态，每步完成后再统一判断；调用方的 `maxSteps` 是宿主预算，和 Agent state 内用于强制收尾的 `state.maxSteps` 分开。停止语义在这一层统一，浏览器、服务端和设备各自的重复实现因此收敛；分布式锁、队列与持久化仍留在各宿主侧。见 `packages/agent-runtime/src/loop/index.ts:30-58,87-128,130-166`。

### 5.1 迭代/步数上限

步数预算耗尽分两段处理：先让已经发出的工具调用跑完，下一次模型调用时再把工具表清空，逼模型给出总结文本。

机制主体在 `AgentRuntime.step()` 里（`packages/agent-runtime/src/core/runtime.ts:82-262`）：每步自增步数计数，一旦超过 `maxSteps` 就把强制收尾标志打开。这个标志不打断当前步。

预算用尽后的下一次模型调用不再携带任何工具：step delta 把该步被停用的工具记为通配符 `'*'`，工具解析器据此清空工具表并注入总结提示；总结文本由 GeneralChatAgent 在 `state.forceFinish` 为真时产出，本轮 finish 的 reason 记为 `'max_steps_completed'`。清空与收尾分别落在 `packages/context-engine/src/engine/tools/ToolResolver.ts:84-93` 与 `packages/agent-runtime/src/agents/GeneralChatAgent.ts:389-428, 587-596`。

`maxSteps` 默认值 999（`apps/server/src/services/agentRuntime/AgentRuntimeService.ts:2911`：`const { maxSteps = 999, ... } = options ?? {}`），可由调用方（如 eval run）显式传入更小的值（schema 限制 `1~1000`，`apps/server/src/routers/lambda/evalRunConfig.schema.ts:66`）。

### 5.2 并发

`call_tools_batch` 执行器把批次内的工具调用一次性交给 `Promise.all` 并发执行，不设显式并发数上限，实际并行度由 Node 事件循环和下游 HTTP、进程连接池自然决定。单个工具失败只会转成一个 error 事件，不会抛异常中断同批其他工具的结果收集，除非该失败被标记为持久化致命（`isPersistFatal`）。批次按执行位置拆开：全部为 client 工具且当前宿主不支持 client 执行时整批挂起；否则先跑 server 部分，client 部分连同异步或 deferred 工具一起进入待定集合并挂起。以上分派与事件处理见 `packages/agent-runtime/src/executors/tool.ts:583-807`。

### 5.3 超时

`resolveToolTimeoutMs` 按三级优先取值：模型在 arguments.timeout 里显式指定、manifest 的 api 级默认值、全局默认 120_000ms。最终结果**始终** clamp 到 [1_000, 800_000] ms（`apps/server/src/modules/AgentRuntime/resolveToolTimeout.ts:8-23, 53-66`）——注释明确写"client 只是建议者，这个函数是唯一裁决者"，即模型或 manifest 想设置的超时不能绕过这个硬边界。上限 800_000ms 与云函数运行窗口（800s）对齐，防止单个 client-tool dispatch 活得比它所在的整次 run 还久。

### 5.4 取消（cancel/abort）

中断信号由 `AgentRuntime.getAbortController()`（`packages/agent-runtime/src/core/runtime.ts:70-75`）提供：它从 `config.getOperation(operationId).abortController` 取出当前 operation 的控制器，接到 LLM 与工具的传输层。

用户取消后，runtime 看到 `state.status === 'interrupted'` 就统一走 `handleAbort`（`GeneralChatAgent.ts:433-456`；该判断在 `runner()` 顶部优先执行，`GeneralChatAgent.ts:464-465`），再按当前有没有未解决的工具调用分两种收尾：

- **有未解决的调用**：phase 停在 `llm_result` 或 `human_abort` 且带工具调用，或停在工具结果 phase 而 `pluginIntervention.status` 仍是 pending 时，发 `resolve_aborted_tools` 指令，把这些工具的结果改写为“调用已被用户中止”、干预状态置为 aborted，随后整个操作转为完成（`packages/agent-runtime/src/executors/resolveTools.ts:179-256`）。
- **没有未解决的调用**：直接 `finish`。

`call_llm` 侧的中断检测走 `isOperationInterrupted`：每次重试前先读最新状态，已被标记中断就不再重试，把已收到的部分输出落盘并保留 `interruptedMidStream` 标记，供前端识别未完成的流式内容（`packages/agent-runtime/src/executors/callLlm.ts:51-62, 148-154, 168-186`；落盘实现在 `packages/agent-runtime/src/executors/callLlmFinalizer.ts:381-402`）。

### 5.5 错误回传

单个工具执行抛错时，单次与批量执行器把异常转成带 error 字段的 error 事件，同批其他工具照常跑完、结果照常收集，整条 operation 不会因此崩溃；唯一例外是标记为持久化致命的失败（`isPersistFatal`），这类错误必须向上抛出，避免数据库写入静默失效（`packages/agent-runtime/src/executors/tool.ts:568-713`）。回注给模型的错误内容另经服务端分类与规整，压成 code、kind、message 三元组，只取错误对象的 message 与 name，原始堆栈在这一步丢弃（`apps/server/src/services/toolExecution/index.ts:35-64`）。

### 5.6 headless 场景下无法等待人工的返回形态

后台任务与 API 调用没有界面可等人，默认落在 headless：服务端入口的默认配置就是 `{ approvalMode: 'headless' }`（`apps/server/src/services/aiAgent/index.ts:1174`）。审批模式配置为 headless 时，`GeneralChatAgent` 在 `llm_result` 阶段不发审批请求事件，改发阻塞工具解析指令（resolve_blocked_tools，`GeneralChatAgent.ts:551-558`）。

`resolveBlockedTools` 执行器（`packages/agent-runtime/src/executors/resolveTools.ts:78-173`）把每个待批准工具直接写成失败结果：

```ts
{ content: 'Blocked by security/privacy.', error: 'blocked_by_security_privacy', success: false }
```

同时持久化 `pluginIntervention: { status: 'rejected', rejectedReason: 'blocked_by_security_privacy' }`。之后照常进入 `tools_batch_result`，模型看到“这个工具被拒绝”并有机会重新规划，整个 operation 不挂起等待人工响应。

headless 下真正转成拒绝的只有需要人工介入的那部分工具（`toolsNeedingIntervention`）。`dynamicPolicy` 与全局审计里标记为可覆盖（非 `always`）的规则照常自动放行（`GeneralChatAgent.ts:200-204, 211-215, 229-234`）。

**依据**：[AgentRuntime.step](../../lobehub/packages/agent-runtime/src/core/runtime.ts)、[GeneralChatAgent.toLLMCall/forceFinish](../../lobehub/packages/agent-runtime/src/agents/GeneralChatAgent.ts)、[ToolResolver 的 deactivatedToolIds](../../lobehub/packages/context-engine/src/engine/tools/ToolResolver.ts)、[AgentRuntimeService 默认 maxSteps](../../lobehub/apps/server/src/services/agentRuntime/AgentRuntimeService/index.ts)、[resolveToolTimeout](../../lobehub/apps/server/src/modules/AgentRuntime/resolveToolTimeout.ts)、[call_tool/call_tools_batch 执行器](../../lobehub/packages/agent-runtime/src/executors/tool.ts)、[resolve_blocked_tools/resolve_aborted_tools](../../lobehub/packages/agent-runtime/src/executors/resolveTools.ts)、[callLlm 重试与中断检测](../../lobehub/packages/agent-runtime/src/executors/callLlm.ts)、[errorClassification 与 normalizeExecutionError](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[execAgent headless 默认值](../../lobehub/apps/server/src/services/aiAgent/index.ts)。

## 6. 审批与策略（重点）

### 6.1 API 级与 manifest 级 `humanIntervention` 合并规则

`GeneralChatAgent.getToolInterventionConfig`（`packages/agent-runtime/src/agents/GeneralChatAgent.ts:62-76`）：

```ts
const api = manifest.api?.find((a) => a.name === apiName);
return api?.humanIntervention ?? manifest.humanIntervention;
```

api 级配置存在则**完全覆盖** manifest 级（不是合并/叠加，是二选一，取第一个非空）。若某个 api 没声明 `humanIntervention`，才落到 manifest 级默认（`BuiltinToolManifest.humanIntervention`，默认 `'never'`，字段注释见 `packages/types/src/tool/builtin.ts:250-252`）。

`HumanInterventionConfig` 有三种形态，配置可以落在其中任一形态上：

| 形态 | 判定行为 |
|---|---|
| 简单策略字符串 | never、required、always 三值 |
| 参数级规则数组 | 按 `match` 字段值匹配后取对应的 policy，第一条命中即返回，全部不命中时默认 required（`packages/agent-runtime/src/core/InterventionChecker.ts:86-93`） |
| 动态解析器 | `{ dynamic: { type, policy?, default? } }`，其中 type 指向注册表中的 resolver key，当前只注册了 `pathScopeAudit`（`packages/builtin-tools/src/dynamicInterventionAudits.ts`） |

### 6.2 九阶段判定管道

`checkInterventionNeeded`（`GeneralChatAgent.ts:135-277`）对每个待判定工具调用按**固定顺序**跑以下阶段，命中即 `continue`：

| 阶段 | 代码位置 | 行为 |
|---|---|---|
| 1. 全局安全审计（`always`） | `GeneralChatAgent.ts:172-184` | 遍历 `globalInterventionAudits`（默认 `createDefaultGlobalAudits()`），命中且 `policy==='always'` → **无条件**要求人工介入，任何模式都不能绕过 |
| 2. 每工具 dynamic resolver | `GeneralChatAgent.ts:189-209` | 有 `{ dynamic }` 配置时先跑 resolver；返回 `'never'` 直接放行；`auto-run`/`headless` 且非 `'always'` 则放行；否则要求介入 |
| 3. headless 对全局审计的覆盖放行 | `GeneralChatAgent.ts:211-215` | headless 模式下，全局审计命中但 `policy !== 'always'`（即 `'required'`）→ 自动放行 |
| 4. 全局审计 `required` 的非 headless 处理 | `GeneralChatAgent.ts:217-221` | 非 headless 且全局审计命中 `required` → 要求人工介入 |
| 5. 静态 `always` 检查 | `GeneralChatAgent.ts:223-227`，`matchesAlwaysPolicy` | 工具自身 config 命中 `'always'`（字符串或规则数组里 `policy==='always'` 的规则）→ 要求人工介入，**这一步在 auto-run 分支之前**，是 `always` 不可绕过的核心实现点 |
| 6. headless 兜底放行 | `GeneralChatAgent.ts:229-234` | 走到这里说明前面都没拦截，headless 直接放行 |
| 7. `auto-run` 全放行 | `GeneralChatAgent.ts:236-240` | 用户配置为 `auto-run` 时直接放行（前提是没被前面的 `always` 拦住） |
| 8. 未知 manifest 强制拦截 | `GeneralChatAgent.ts:242-250` | `!manifest`（`state.toolManifestMap` 里找不到）时，**只在 manual/allow-list 模式下**强制要求介入（`console.warn` 打日志），`auto-run`/`headless` 已在前面分支放行，不受此约束 |
| 9a. `allow-list` 匹配 | `GeneralChatAgent.ts:252-260` | 检查 `"identifier/apiName"` 是否在 `userInterventionConfig.allowList` |
| 9b. `manual` 默认 | `GeneralChatAgent.ts:262-273` | 调用 `InterventionChecker.shouldIntervene`，用工具自身 config + 该次调用共用的 `securityBlacklist` |

这九阶段是**顺序判定的管道**，阶段顺序本身带有语义：例如"未知 manifest 强制审批"（阶段 8）只对 manual/allow-list 生效，`auto-run`/`headless` 用户被视为主动接受风险而不受此约束（`GeneralChatAgent.ts:244` 注释原文："auto-run users accept the risk"）。

### 6.3 四种审批模式的行为矩阵

核心差异：

| 模式 | 判定依据 | 行为 |
|---|---|---|
| `manual`（默认） | 只看工具自身的 `humanIntervention` 配置 | 命中 `'never'` 放行；`'required'`、`'always'` 以及规则未匹配时的默认 `'required'` 都要求人工介入 |
| `allow-list` | 只看 `"identifier/apiName"` 是否在用户白名单 | 白名单内的工具放行，工具自身的 `always` 与全局审计照常生效 |
| `auto-run` | 除 `always` 之外一律放行 | 工具级或全局审计命中的 `always` 不可绕过 |
| `headless` | 全部自动执行 | `always` 命中的工具经 `resolve_blocked_tools` 转成失败结果返回给模型 |

headless 这一行的措辞在类型注释与实现之间有出入：注释写的是 "security blacklist tools are skipped (not blocked)"（`packages/types/src/tool/intervention.ts:141-142`），代码走的是返回 `success: false` 的拒绝结果并把拒绝原因回传模型（`packages/agent-runtime/src/executors/resolveTools.ts:99-105`）。

### 6.4 `always` 不可绕过的实现点

两处代码是 `always` 语义的最终防线：

1. `matchesAlwaysPolicy`（`GeneralChatAgent.ts:86-109`）在 `auto-run`/`headless` 判断**之前**执行（阶段 5 在阶段 6/7 之前），确保无论用户设的模式多宽松，`always` 都先被拦下。
2. 全局安全审计的 `always` 检查（阶段 1，`GeneralChatAgent.ts:181-184`）比 dynamic resolver、headless 特判都靠前，且没有任何 `approvalMode` 分支能跳过它。

`HumanInterventionPolicy` 类型注释把 `'always'` 定义为 "Always need intervention (cannot be bypassed by auto-run mode)"（`packages/types/src/tool/intervention.ts:9`）。

### 6.5 未知 manifest 的强制审批

见 6.2 阶段 8。触发条件是 `state.toolManifestMap[identifier]` 查不到——例如工具的 manifest 因为过滤/裁剪没有出现在当前 turn 的 map 里，但模型仍然吐出了对应的 `identifier/apiName`（可能是历史遗留、模型幻觉，或者理论上的"注入绕过"尝试）。此时 manual/allow-list 模式强制要求人工介入，而不是静默执行或静默丢弃。

### 6.6 全局安全审计与动态规则的注入点

- **两条全局审计共用一份黑名单**：默认审计集由 `createDefaultGlobalAudits()` 装配两条审计，两者共用同一份 27 条规则的 `DEFAULT_SECURITY_BLACKLIST`，差别只在策略参数——一条取缺省的 always，另一条显式 required。单条规则可以用 policy 字段把自身从无条件拦截降为可覆盖，.env、SSH 私钥、AWS 凭证、.npmrc 一类敏感信息读取走的就是这条覆盖（装配 `packages/agent-runtime/src/audit/globalAudit.ts:5-8`，规则表 `packages/agent-runtime/src/audit/defaultSecurityBlacklist.ts:12-359`）。
- **规则覆盖面**：匹配对象是命令、路径等参数字段，按正则判断，覆盖下列几类操作：

  ```text
  删除家目录 / 根目录、fork bomb、dd 与 mkfs 写磁盘
  关闭防火墙、改 sshd_config、卸载系统包、改动内核参数、chown -R 系统目录、SUID shell
  读取 .env、SSH 私钥、AWS/Docker/K8s/Git/npm 凭证
  读取 history 文件、浏览器凭证、GCP 凭证
  ```

- **动态规则的注入点在 `GeneralChatAgent` 的构造参数上**：宿主通过 GeneralAgentConfig 的 dynamicInterventionAudits 传入一张 resolver 映射表，当前只挂了 `pathScopeAudit` 一个实现（行为见维度 4.3，注册表 `packages/builtin-tools/src/dynamicInterventionAudits.ts:4-6`）。
- **前端另有一层只做展示的提示**：审批卡片上的 SecurityBlacklistWarning 组件调用与后端同一套黑名单判断，把命中的风险点写成警告文案展示给用户，拦截判定本身由服务端与 agent-runtime 完成（`src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/SecurityBlacklistWarning.tsx:10-18`）。

### 6.7 `waiting_for_human` 状态机与持久化 pending message

状态转换（`packages/agent-runtime/src/executors/humanApprove.ts` + `apps/server/src/services/agentRuntime/HumanInterventionHandler.ts`）：

```text
running --[request_human_approve]--> waiting_for_human
  在此期间：
  - 为每个待批准工具创建 tool message，role='tool'，content=''，
    pluginIntervention={ status: 'pending' }（humanApprove.ts:161-182）
  - 发 chunkType:'tools_calling' + events:[human_approve_required, tool_pending]
用户 approve 单个工具 -> HumanInterventionHandler.approve
  - updateMessagePlugin(toolMessageId, { intervention: { status: 'approved' } })
  - newState.pendingToolsCalling 移除该工具
  - 若还有其他 pending -> 仍是 waiting_for_human；否则 -> running
  - nextContext.phase = 'human_approved_tool'，触发 runtime.step 里的
    "短路直连 call_tool（skipCreateToolMessage:true）"分支（runtime.ts:110-138）
用户 reject 单个工具 -> HumanInterventionHandler.reject
  - updateToolMessage(content='User reject this tool calling with reason: ...')
  - updateMessagePlugin(intervention:{ status:'rejected', rejectedReason })
  - rejectAndContinue: 若还有 pending 留在 waiting_for_human；全部解决后 phase:'user_input'
    （让模型把"用户拒绝了"当作新一轮输入处理，而不是直接把上一轮 LLM 结果当结果继续）
  - rejectAndHalt: status:'interrupted'，interruption.reason='human_rejected'（不可恢复）
```

干预状态的取值是 `'pending'|'approved'|'rejected'|'aborted'|'none'`（`packages/types/src/message/common/tools.ts:7-9`）。该字段随 tool message 持久化在 `messagePlugins.intervention` 列（`packages/types/src/message/db/item.ts:49`），进程重启或 serverless 冷启动后，等待人工的状态可据此从数据库恢复。恢复时当前轮扫描只取最近一条带工具调用的 assistant 消息之后的 pending 行，避免用户未处理就离开的历史遗留行劫持后续轮次（`GeneralChatAgent.ts:341-359`）。

approve 与 reject 走两个不同的 `nextContext.phase`（`human_approved_tool` 与 `user_input`）；reject 有继续等其他 pending 工具与整体终止两条子路径，后者让操作进入不可恢复的 `interrupted`，走哪条由前端调用时传的布尔值决定（`HumanInterventionHandler.ts:47,154-158`）。

**依据**：[GeneralChatAgent.checkInterventionNeeded](../../lobehub/packages/agent-runtime/src/agents/GeneralChatAgent.ts)、[InterventionChecker](../../lobehub/packages/agent-runtime/src/core/InterventionChecker.ts)、[globalAudit](../../lobehub/packages/agent-runtime/src/audit/globalAudit.ts)、[defaultSecurityBlacklist](../../lobehub/packages/agent-runtime/src/audit/defaultSecurityBlacklist.ts)、[intervention 类型](../../lobehub/packages/types/src/tool/intervention.ts)、[humanApprove executor](../../lobehub/packages/agent-runtime/src/executors/humanApprove.ts)、[HumanInterventionHandler](../../lobehub/apps/server/src/services/agentRuntime/HumanInterventionHandler.ts)、[ToolIntervention 类型](../../lobehub/packages/types/src/message/common/tools.ts)、[SecurityBlacklistWarning UI](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/SecurityBlacklistWarning.tsx)、[dynamicInterventionAudits 注册表](../../lobehub/packages/builtin-tools/src/dynamicInterventionAudits.ts)。

## 7. 执行位置与隔离

### 7.1 执行方分派条件

`ToolExecutionService.executeTool` 只做类型级分派（`apps/server/src/services/toolExecution/index.ts:138, 174-262`）：MCP 类 payload 交给 `executeMCPTool`，其余（含 builtin）交给内建工具执行器。真正的"在哪台机器上执行"由该函数内部再细分：

1. `mcpParams.type === 'cloud'` → `executeCloudMCPTool` → `DiscoverService.callCloudMcpEndpoint`（market/discover gateway）
2. `mcpParams.type === 'stdio' && deviceGateway.isConfigured && context.activeDeviceId && context.userId` → `executeMcpViaDevice`（转发到用户设备，`index.ts:228-235, 270-318`）——**这是唯一的判定条件**：网关配置了 + 有一个当前活跃设备 ID + 有 userId，三者同时满足才转发到设备；不满足则退回下一步
3. 其余（stdio 无设备网关、或 http/sse）→ `this.mcpService.callTool`（本地/服务器进程内 MCP client，`index.ts:238-242`）——服务器自身直接 spawn stdio 子进程或发 HTTP/SSE 请求

builtin 工具的 client 与 server 执行位置由 manifest 的 `executors` 字段声明（`packages/types/src/tool/builtin.ts:236-244`）：省略时默认只支持 server 端执行；声明了 client 的工具（如 local-system 包，`packages/builtin-tool-local-system/src/manifest.ts:7`）可在桌面 Electron 内置运行时里就地执行，不必经过设备网关。这条路径仅用于**无设备网关的独立 Electron 构建**，配置了设备网关的部署仍把同类工具走网关代理。

### 7.2 设备是否"在线"与是否"被路由"的判定

“设备工具能不能进模型”和“这次调用会不会真的发到某台设备”是两个独立判断。

是否注入看设备上下文：服务端工具引擎给 `local-system`/`browser` 放行注入的条件里包含 `deviceContext.deviceOnline && deviceContext.autoActivated`（`apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:268-273, 276-280`）。

是否真的路由由 `resolveExecutionPlan`（`src/helpers/executionTarget.ts:378-469`）在 run 开始时一次性决定，产出 `ExecutionPlan.kind` 的四种取值：

- `'device'`：已路由到 `deviceId`
- `'device-unrouted'`：设备能力上但没有可路由设备，原因见 `ExecutionPlanUnroutedReason`
- `'sandbox'`
- `'none'`

`auto` 模式只有恰好一台设备在线时才自动路由，多台在线则保持 unrouted，等模型通过 `remote-device` 工具主动选择（`executionTarget.ts:455-464`）。

设备池范围与 bot 场景的访问方防线：

- 设备池限定在调用者名下：`RemoteDeviceExecutionRuntime.queryDeviceList` 只返回该用户个人设备池与当前工作区的共享设备池，后续的设备激活以及本机系统、浏览器工具调用同样落在这一范围内，跨用户、跨工作区的枚举与激活都被挡住（`apps/server/src/services/toolExecution/serverRuntimes/remoteDevice.ts:26-58`）。
- bot 场景的设备访问另由 `resolveDeviceAccessPolicy` 判定：只有所有者本人与 bot 个人平台两类来源能使用设备工具，外部发送者一律拒绝；平台 webhook 未能解析出发送者外部 ID 时落到“owner 未配置”分支，同样拒绝，整体按失败即关闭处理。各平台 webhook 对该字段的解析本次未逐一验证（`apps/server/src/services/aiAgent/deviceAccessPolicy.ts:78-108`）。

### 7.3 connector 逐工具权限二次检查（`disabled` 的强制点）

connector 维度的工具开关在执行入口统一生效，数据库故障时按可用性优先放行。

判定本身分两步：`getConnectorToolPermission`（`src/libs/mcp/connectorPermissionCheck.ts:23-44`）先用 `ConnectorModel.resolveByIdentifiers([identifier], agentId)` 找到 connector 行，再用 `ConnectorToolModel.queryByConnector` 按 `toolName` 取出权限值。

这个检查放在 `ToolExecutionService.executeTool` 分派到任何执行分支之前（`index.ts:89-104`，源码注释为 "Check before any execution so that disabled tools are blocked universally"）。命中禁用取值时立即返回一条正常工具结果，内容是一句提示用户“该工具已被禁用，可在 Settings > Connectors 重新开启”的正常工具结果（`connectorPermissionCheck.ts:47-60`），success 为 true；模型会读到这段说明，不会触发错误重试。

检查覆盖所有执行路径，源码注释写明的范围是 "covers ALL paths + qstash: Lobehub market skills, Composio, MCP connectors, and execAgent/qstash alike"（`index.ts:83-88`）。查询过程抛数据库异常时，`getConnectorToolPermission` 捕获后返回 `null`（`connectorPermissionCheck.ts:41-43`，注释为 "never block execution due to DB error"），执行照常进行——数据库故障下选择放行，是明确以可用性优先的设计取舍。

### 7.4 桌面 MCP client 的隔离程度

已委托后台子调查代理核实 `apps/desktop/src/main/libs/mcp/client.ts` 的 stdio/Streamable HTTP transport 细节和是否有沙箱隔离,结论见维度 10。

**依据**：[ToolExecutionService](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[connectorPermissionCheck](../../lobehub/src/libs/mcp/connectorPermissionCheck.ts)、[executionTarget.resolveExecutionPlan](../../lobehub/src/helpers/executionTarget.ts)、[AgentToolsEngine 设备门](../../lobehub/apps/server/src/modules/Mecha/AgentToolsEngine/index.ts)、[builtin executors 字段](../../lobehub/packages/types/src/tool/builtin.ts)、[local-system manifest 的 client executor](../../lobehub/packages/builtin-tool-local-system/src/manifest.ts)、[remoteDevice 执行体](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/remoteDevice.ts)、[deviceAccessPolicy](../../lobehub/apps/server/src/services/aiAgent/deviceAccessPolicy.ts)。

## 8. 结果处理与回注

### 8.1 结果截断的配置与默认值

结果处理分“截断”与“归档”两步。截断逻辑在前后端共享模块 `packages/prompts/src/toolResult/index.ts` 中：默认上限是 `DEFAULT_TOOL_RESULT_MAX_LENGTH = 25,000` 字符，`sliceTextWindow` 按整行切出前段窗口，`appendTextWindowNotice` 给出展示区间与总长度，代理对边界由 `truncateSurrogateSafe` 处理。

服务端在截断之上再加归档：`archiveToolResult`（`apps/server/src/services/toolExecution/archiveToolResult.ts`）把超长结果写入 topic document 虚拟文件系统，文件名取内容哈希前缀，写后做内容校验，失败时不静默丢弃。回注给模型的是截断窗口加归档位置提示，模型可以再用文档读取工具按同一套行号窗口翻页。`ARCHIVE_BYPASS_IDENTIFIERS` 只列 `lobe-agent-documents`：它是归档内容的读取面，本身不能再被截断或归档。

### 8.2 截断后的标记

截断或窗口化后会在内容尾部追加共享提示（`packages/prompts/src/textWindow/index.ts` 的 `appendTextWindowNotice`）：

```text
[Showing lines a-b of N; window truncated. Full content archived at <path>]
```

模型能读到"内容被截断，原文多长，截了多少"，不会被误导为内容已完整。

### 8.3 错误/受阻/拒绝的结果形态

三种非成功结果在类型上大体同构，但触发路径和下游处理不同；connector 禁用与用户取消属于相邻的两类结局，一并列在下面：

| 场景 | 返回结果 | 下游处理 |
|---|---|---|
| 执行错误 | 带错误码、错误类别与消息的失败对象 | 类别决定后续是重试、重新规划还是终止（维度 5.5） |
| 审批拒绝 | 正文说明用户拒绝的原因 | 以普通工具结果回注，模型读到拒绝原因后继续规划 |
| 策略/安全阻断 | headless 下命中全局 always 审计或强制规则，返回失败的阻断结果 | 消息持久化为 rejected，并带阻断原因 |
| connector 禁用 | 返回 `success: true` 的正常完成结果 | 正文提示该工具已被禁用、可在 Settings > Connectors 重新开启 |
| 用户取消 | 正文说明操作由用户中止 | 消息状态记为 aborted |

源码定位：

```text
apps/server/src/services/toolExecution/index.ts:35-64
apps/server/src/services/agentRuntime/HumanInterventionHandler.ts:133-140
src/libs/mcp/connectorPermissionCheck.ts:47-60
packages/agent-runtime/src/executors/resolveTools.ts:99-133, 212-217
```

### 8.4 能否污染上下文

所有工具结果最终都以 tool 消息进入消息状态，并随下一次模型调用带入上下文；模型需要知道工具调用发生了什么，包括拒绝本身。潜在的“污染”风险点：

1. `content` 字段直接来自工具执行结果或 MCP 返回值，**没有观察到通用的输出内容安全过滤/脱敏层**（例如没有统一扫描工具结果里是否混入了 prompt injection 载荷，或工具结果本身携带的敏感数据）。截断只解决"过长"，不解决"内容本身是否可信"。
2. 持久化清洗逻辑（`callLlmFinalizer.ts:104-124`）只处理模型发出的工具调用参数，与工具返回内容无关。
3. MCP 和自定义插件返回的内容会作为普通工具文本回注模型，未观察到统一的输出安全过滤或注入检测层。截断逻辑只限制长度；部分工具在 `systemRole` 文案里提醒模型工具结果中的指令不可信，但覆盖率本次未逐一确认。

**依据**：[prompts/toolResult](../../lobehub/packages/prompts/src/toolResult/index.ts)、[prompts/textWindow](../../lobehub/packages/prompts/src/textWindow/index.ts)、[archiveToolResult](../../lobehub/apps/server/src/services/toolExecution/archiveToolResult.ts)、[ToolExecutionService](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[HumanInterventionHandler.reject](../../lobehub/apps/server/src/services/agentRuntime/HumanInterventionHandler.ts)、[resolveBlockedTools/resolveAbortedTools](../../lobehub/packages/agent-runtime/src/executors/resolveTools.ts)、[buildBlockedToolResponse](../../lobehub/src/libs/mcp/connectorPermissionCheck.ts)、[callLlmFinalizer 的 sanitize](../../lobehub/packages/agent-runtime/src/executors/callLlmFinalizer.ts)。

## 9. 内建工具完整清单

以下清单以 `packages/builtin-tools/src/index.ts` 的 42 项注册表为准；审批列按各工具 manifest 声明填写，省略时默认 never，执行位置则结合服务端运行时文件和 executors 字段判断：

| identifier | 主要 api（节选） | humanIntervention 默认 | 执行位置 | agent/chat 可见性 | 风险点 |
|---|---|---|---|---|---|
| `lobe-verify` | 内部校验回写 | 未声明（`never`） | server | `hidden`,`discoverable:false` | 框架内部工具，不面向用户 |
| `lobe-activator` | `activateTools` | `required`（`packages/builtin-tool-activator/src/manifest.ts:11`） | server | `alwaysOnToolIds`,`hidden` | 动态解锁其他工具的 schema，`allowExplicitActivation` 是唯一绕过 enable-rule 的口子 |
| `lobe-skills` | 按运行环境动态改写描述（`resolveManifest`） | 未在本节确认，需核对 `builtin-tool-skills` 包 | server/client | `alwaysOnToolIds`,`hidden` | 执行外部/生成代码，风险取决于 `executionEnv` |
| `lobe-skill-store` | 技能安装 | 未核实 | server | `alwaysOnToolIds`,`hidden` | 安装第三方技能内容 |
| `lobe-skill-maintainer` | 技能维护 | 未核实 | server | `hidden`,`discoverable:false` | 修改已安装技能 |
| `lobe-self-iteration`(`selfFeedbackIntentManifest`) | 自我迭代信号 | 未核实 | server | `hidden`,`discoverable:false` | 影响 agent 自身配置的反馈回路 |
| `agentSignalReview`/`Reflection`/`FeedbackIntent`/`SkillManagement`（agent-signal 系列） | 内部信号处理 | 未核实 | server | `hidden`,`discoverable:false` | 框架内部，非用户直接调用面 |
| `lobe-browser` | `navigate`/`snapshot`/`click`/`fill`/`press`/`scroll`/`screenshot`/`readPage` | **全部未声明 → 默认 `'never'`**（`packages/builtin-tool-browser/src/manifest.ts:6-140`，逐条核对无 `humanIntervention` 字段） | `executors:['client','server']`；`discoverable:isDesktop` | `runtimeManagedToolIds`,`hidden` | **点击/填表/导航零审批**，驱动的是用户真实设备上的浏览器会话 |
| `lobe-local-system` | `readFile`/`writeFile`/`editFile`/`moveFiles`/`searchFiles`/`grepContent`/`globFiles`/`runCommand`/`getCommandOutput`/`killCommand` | 文件类 api 走 `pathScopeAudit` dynamic（越界才 `required`）；`runCommand` 直接 `'required'`（`packages/builtin-tool-local-system/src/manifest.ts` 各处） | `executors:['client','server']`；`discoverable:isDesktop` | `runtimeManagedToolIds`,`hidden` | 本机文件系统 + shell，`pathScopeAudit` 只是审批触发条件不是访问控制 |
| `lobe-memory` | 用户记忆读写 | 未核实（`chatConfig.memory.toolPermission` 有 `read-only`/`read-write` 区分，见 `packages/types/src/agent/chatConfig.ts:19`） | server | `defaultToolIds`,`chatModeAllowedToolIds`,`runtimeManagedToolIds`,`hidden` | 跨会话持久化的用户隐私数据 |
| `lobe-web-browsing` | `search`/`crawlSinglePage`/`crawlMultiPages` | 未声明 → `'never'`（`packages/builtin-tool-web-browsing/src/manifest.ts:8-69`） | server | `defaultToolIds`,`chatModeAllowedToolIds`,`runtimeManagedToolIds`,`hidden` | 默认爬虫经 `ssrfSafeFetch` 请求、默认禁私网（维度 4.3）；`search`/`crawl*` 零审批 |
| `lobe-cloud-sandbox` | `executeCode`/`listFiles`/`readFile`/`searchFiles`/`moveFiles`/`writeFile`/`editFile`/`runCommand`/`getCommandOutput`/`killCommand`/`grepContent`/`globFiles`/`exportFile` | 写入/执行类（`executeCode`/`moveFiles`/`writeFile`/`editFile`/`runCommand`）`'required'`；只读类（`listFiles`/`readFile`/`searchFiles`/`grepContent`/`globFiles`/`getCommandOutput`/`killCommand`/`exportFile`）未声明→`'never'`（`packages/builtin-tool-cloud-sandbox/src/manifest.ts`） | server（云沙箱） | `defaultToolIds`,`runtimeManagedToolIds`,`hidden` | 隔离在云沙箱容器内执行任意代码/命令，出网范围未核实 |
| `lobe-agent-documents` | 文档归档读取 | 未核实 | server | 非 hidden | 结果**永不截断**（`ARCHIVE_BYPASS_IDENTIFIERS`），是归档内容读取面 |
| `lobe-creds` | `connectComposioService`/`initiateOAuthConnect`/`injectCredsToSandbox`/`saveCreds` | **全部未声明 → 默认 `'never'`**（`packages/builtin-tool-creds/src/manifest.ts:10-102`） | server（经 `MarketService.market.creds`） | 非 hidden | 保存/注入凭据、发起第三方 OAuth 授权，零审批（维度 10.5） |
| `lobe-knowledge-base` | 知识库检索 | 未核实 | server | `defaultToolIds`,`chatModeAllowedToolIds`,`runtimeManagedToolIds`,`hidden` | 读取用户知识库内容 |
| `lobe-image-generation` | 图像生成 | 未核实 | server | `chatModeAllowedToolIds`,`hidden` | chat mode 下必须 pinned 才注入，不做模型无原生 imageOutput 时的自动兜底 |
| `lobe-goal` | `createGoal`（创建并立即启动带可编辑验收计划的目标任务，**只允许 /goal 前缀触发**） | **`'always'`**（`packages/builtin-tool-goal/src/manifest.ts:13`） | server | 非 hidden（注册表项） | 创建/启动目标循环任务；`humanIntervention: 'always'` 保证创建必须人工确认，且仅在 `/goal` 命令注入（`conversationLifecycle.ts:323-328`），模型不能自行触发 |
| `lobe-page-agent` | 页面级子代理 | 未核实 | server | `hidden`,`discoverable:false` | 内部编辑器场景 |
| `lobe-agent-builder`/`lobe-group-agent-builder` | Agent/Group 成员 CRUD | 未核实 | server（`agentBuilder.ts`）；group-agent-builder **无 server runtime**（`packages/builtin-tools/src/index.ts:129-134` 注释明确） | `hidden`,`discoverable:false` | 创建/修改 Agent 配置本身 |
| `lobe-group-management` | `speak`/`broadcast`/`executeAgentTask`/`executeAgentTasks`/`vote` | `executeAgentTask`/`executeAgentTasks` = `'required'`（`packages/builtin-tool-group-management/src/manifest.ts:91,135`）；`speak`/`broadcast`/`vote` 未声明→`'never'` | server | `groupSupervisorToolIds`,非 hidden | 群组编排调度，`broadcast` 零审批且并发无上限（维度 11） |
| `lobe-agent-management` | Agent 管理（含 `callAgent`，30 分钟默认超时见 `agentManagement.ts:85`） | 未核实 | server | 非 hidden,`hidden`（依代码为 `hidden:true`） | 触发其他 Agent 执行 |
| `lobe-calculator` | 计算 | 未核实 | server | 非 hidden | 低风险 |
| `lobe-message` | `sendMessage`/`sendDirectMessage`/`createBot`/`updateBot`/`deleteBot`/`uninstallMessenger`/... | **全部 api 均未声明 humanIntervention → 默认 `'never'`**（`packages/builtin-tool-message/src/manifest.ts` 全文无 `humanIntervention` 字段） | server（`serverRuntimes/message/`） | `isBotConversation` 时注入,非 hidden | **零审批**下可 `updateBot`（改写 `allowFrom`/`dmPolicy`）、`uninstallMessenger`（断开工作区级 bot） |
| `lobe-remote-device` | `listOnlineDevices`/`activateDevice` | **manifest 级显式 `'never'`**（`packages/builtin-tool-remote-device/src/manifest.ts:33`） | server | `runtimeManagedToolIds`,`hidden` | 激活设备后打开 `local-system`/`browser` 的入口，本身零审批 |
| `lobe-web-onboarding` | 引导流程 | 未核实 | server | `discoverable:false`,`hidden` | 低风险 |
| `lobe-user-interaction` | `askUserQuestion` 等 | `always`（复用于 `lobe-agent.askUserQuestion`，`packages/builtin-tool-lobe-agent/src/manifest.ts:189`） | server | `discoverable:false`,`hidden` | 交互式提问，本身低风险 |
| `lobe-task` | `createTask(s)`/`listTasks`/`viewTask`/`editTask`/`runTask`/`runTasks`/`setTaskSchedule`/`setTaskVerify`/`updateTaskStatus`/`deleteTask`/评论类 | 未核实每条，`runTasks` **顺序执行**（manifest 描述："Each task is started sequentially in array order"，`packages/builtin-tool-task/src/manifest.ts:298-299`） | server（另有独立 server runtime `serverRuntimes/task.ts`（107 行）与 client executor `builtin-tool-task/src/client/executor/index.ts`（118 行），任务工具带客户端执行面） | `defaultToolIds`,非 hidden | 可配置 cron/heartbeat 定时任务（`setTaskSchedule`）；任务回调投递串行化、creator 回调持久化 |
| `lobe-brief` | 摘要生成 | 未核实 | server | `discoverable:false`,`hidden` | 低风险 |
| `lobe-agent`(`LobeAgentManifest`) | `analyzeVisualMedia`/`createPlan`/`updatePlan`/`createTodos`/`updateTodos`/`clearTodos`/`askUserQuestion`/`callSubAgent` | `createPlan`/`createTodos`/`clearTodos`=`'required'`；`askUserQuestion`=`'always'`；`updatePlan`/`updateTodos`/`analyzeVisualMedia`/`callSubAgent`=未声明→`'never'`（`packages/builtin-tool-lobe-agent/src/manifest.ts` 各处） | server | `defaultToolIds`,`alwaysOnToolIds`,`runtimeManagedToolIds`,`hidden` | `callSubAgent` **零审批**即可派生新的独立 Agent 执行（维度 11） |

**未核实项说明**：表中标注"未核实"的条目，是本次调查在时间与篇幅约束下没有逐一打开对应 `packages/builtin-tool-*/src/manifest.ts` 核对每个 api 的 `humanIntervention` 字段；已给出的 never、required、always 三类取值均逐条读取源码并附了定位，可直接复核。体量较大的 lobe-skills、lobe-skill-store、lobe-knowledge-base、lobe-memory、lobe-image-generation 等列入后续调查缺口（见维度 13）。

当前内置工具登记表共 42 项，逐条列在上表；`packages/locales` 仍保留 `lobe-topic-reference` 的文案词条，注册表中没有对应的工具 manifest。
**依据**：[builtin registry](../../lobehub/packages/builtin-tools/src/index.ts)、[browser manifest](../../lobehub/packages/builtin-tool-browser/src/manifest.ts)、[local-system manifest](../../lobehub/packages/builtin-tool-local-system/src/manifest.ts)、[web-browsing manifest](../../lobehub/packages/builtin-tool-web-browsing/src/manifest.ts)、[cloud-sandbox manifest](../../lobehub/packages/builtin-tool-cloud-sandbox/src/manifest.ts)、[creds manifest](../../lobehub/packages/builtin-tool-creds/src/manifest.ts)、[message manifest](../../lobehub/packages/builtin-tool-message/src/manifest.ts)、[remote-device manifest](../../lobehub/packages/builtin-tool-remote-device/src/manifest.ts)、[group-management manifest](../../lobehub/packages/builtin-tool-group-management/src/manifest.ts)、[lobe-agent manifest](../../lobehub/packages/builtin-tool-lobe-agent/src/manifest.ts)、[task manifest](../../lobehub/packages/builtin-tool-task/src/manifest.ts)、[agentManagement 服务端超时](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/agentManagement.ts)、[ARCHIVE_BYPASS_IDENTIFIERS](../../lobehub/packages/prompts/src/toolResult/index.ts)。

## 10. 扩展机制

### 10.1 自定义插件（OpenAPI/simple）现状

类型层仍保留 `CustomPluginParams.apiMode?: 'openapi' | 'simple'`（`packages/types/src/tool/plugin.ts:14`），实际执行路径由 connector 体系承担。旧版自定义插件（`customPlugin`）经迁移转成标准 connector，之后统一走 MCP connector 链路（`src/features/Connectors/CustomConnectorModal/legacyPluginMigration.ts:47-131`）。当前服务端工具执行目录未找到直接请求用户 API endpoint 的旧路径；PluginService 只负责安装、卸载和 manifest 更新（`src/services/plugin/index.ts:14-44`）。**结论（已确认）**：旧版 simple/OpenAPI 插件不再是一等执行路径。

### 10.2 MCP 三种 transport

`CustomPluginParams.mcp`（`packages/types/src/tool/plugin.ts:39-56`）声明三种 transport：http、stdio 和 cloud，并分别携带 URL、进程参数或云端点；认证支持 none、bearer 和 oauth2。

桌面端 MCP client（`apps/desktop/src/main/libs/mcp/client.ts:29-85`）使用官方 SDK：

- http transport 使用可流式 HTTP 传输，并把 bearer/oauth2 凭据放入 Authorization 请求头（`client.ts:43-51`）。
- stdio transport 将环境变量传给子进程并捕获 stderr；这是一个真实的本机子进程，未观察到额外沙箱或权限降级（`client.ts:61-96`）。
- 工具调用超时读取环境变量 `MCP_TOOL_TIMEOUT`，未见统一上限；服务端则有独立的强制区间（`client.ts:178`，服务端见维度 5.3）。

**结论（已确认）**：桌面 MCP client 对 stdio server **没有沙箱隔离**——它是官方 SDK 的直接子进程 spawn，风险等同于用户自己在终端里跑这个命令；http/streamable transport 也没有额外的出站过滤。

### 10.3 OAuth/bearer 存储与使用范围

connector 凭据表把加密内容与过期时间分开存放（`packages/database/src/schemas/connector.ts:59-74, 159-234`）：`credentials` 列存 AES-GCM 加密后的 blob，加解密经 `KeyVaultsGateKeeper`，与 `messengerInstallations` 共用同一套机制；`tokenExpiresAt` 单独放在明文列，供后台刷新任务按索引扫描。

`ConnectorCredentials` 支持两种形态（`connector.ts:59-74`）：

- `oauth2`：`accessToken`、`refreshToken`、`idToken`、`registrationAccessToken`
- `bearer`：`token`

token 的使用范围在解析阶段收窄：`getConnectorToolPermission`/`ConnectorModel.resolveByIdentifiers` 按 `(userId, identifier, workspaceId?, agentId?)` 解析出唯一一行 connector，再把凭据传给该 connector 对应的执行运行时（如 MCP client 的 auth header）。跨 connector 复用同一份 token 的代码路径**未发现**；运行时也没有按 scope 二次收窄，因此某个 OAuth scope 是否被下游 API 超范围使用，取决于第三方 API 自身的 scope 校验，LobeHub 侧只做 token 转发。

### 10.4 Market/Discover gateway

云端 MCP 调用经 `DiscoverService.callCloudMcpEndpoint`（`apps/server/src/services/toolExecution/index.ts:320-371, 341-345`），本次调查未深入 DiscoverService 内部实现细节（**需要进一步验证**：该 gateway 是否做速率限制、是否对请求参数做二次校验，还是纯转发）。可确认的是调用在进入 gateway 之前已经过 7.3 节的 connector 权限检查和维度 2 的工具注入过滤，gateway 属于分层防御的最后一环。

### 10.5 Composio 第三方 connector 信任边界

`CustomPluginParams.composio` 记录 connector 的授权元数据，字段包括应用标识、授权配置、已连接账户、连接者、回调地址与状态（`packages/types/src/tool/plugin.ts:19-31`）。

授权流程由 `lobe-creds.connectComposioService` 发起，覆盖 Gmail、Google Calendar、Slack 等服务（`packages/builtin-tool-creds/src/manifest.ts:12-27`）。该 api 没有声明 `humanIntervention`，按默认值 `'never'` 处理，因此模型可以在无审批的情况下发起一次第三方账户授权。浏览器里的 OAuth 同意页仍需用户本人完成，LobeHub 侧放行的只是"发起授权请求"这个动作。

字段 `linkedByUserId` 的注释说明了工作区场景下的信任边界（`plugin.ts:24-28`）：其他成员运行时会代表 owner 账号调用 Composio，注释原文为 passed as the Composio userId at runtime so a workspace member runs the owner's connection。也就是说，一个工作区成员可以借助 owner 已连接的账户执行操作，信任边界从"谁发起调用"下沉到"谁连接了这个账户"。

### 10.6 桌面 MCP client 隔离程度（兑现维度 7.4 的承诺）

结论已在 10.2 给出：无额外沙箱，等同本机子进程/直接网络请求。

**依据**：[plugin 类型定义](../../lobehub/packages/types/src/tool/plugin.ts)、[legacyPluginMigration](../../lobehub/src/features/Connectors/CustomConnectorModal/legacyPluginMigration.ts)、[PluginService](../../lobehub/src/services/plugin/index.ts)、[桌面 MCPClient](../../lobehub/apps/desktop/src/main/libs/mcp/client.ts)、[connector 数据库 schema](../../lobehub/packages/database/src/schemas/connector.ts)、[ToolExecutionService 的 cloud MCP 分支](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[creds manifest](../../lobehub/packages/builtin-tool-creds/src/manifest.ts)。

## 11. 子 Agent 与任务委派

### 11.1 `callSubAgent` 的调度模型：异步 deferred，不是同步等待

`LobeAgentExecutionRuntime.callSubAgent`（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts`）不阻塞等待子代理跑完。它调用 `ctx.subAgent.run({ description, instruction, timeout })`，拿到 `{ started, threadId, subOperationId, toolMessageId }` 后立即返回 `{ deferred: true, success: true, state: { status: 'pending', ... } }`（`lobeAgent.ts:174-199`）。

`SubAgentCallbacks.run` 的声明返回类型是同步的 `RunSubAgentResult`（`packages/types/src/tool/builtin.ts`），与运行时立即返回的行为存在差异。实际链路是：服务端 fork 一个独立 async operation，父操作转入 `waiting_for_async_tool`，完成后由回调把结果桥接回填到 tool message；调用侧从 deferred 分支接收（`packages/agent-runtime/src/executors/tool.ts:409-417, 636-641`）。启动阶段就失败时不走 deferred，直接返回普通失败结果，父操作拿到失败结果后继续推进，不阻塞在无回调的等待上；同文件注释说明了这个区分的原因。

这条链另有两处配套能力：

- `callSubAgent` 支持用 `subAgentId` 续接已有子 Agent。manifest 把这个参数描述为把 `instruction` 作为新消息发给同一子 Agent、保留其历史，可用于续跑失败任务或索取中间结果（`packages/builtin-tool-lobe-agent/src/manifest.ts:238-256`）。
- 子 Agent 的 LLM 调用可经由 `apps/server/src/services/aiAgent/subAgentLlmRelay.ts` 的 `openSubAgentLlmRelay` / `closeSubAgentLlmRelay` 转接；后台子 Agent 的完成回填由 `backgroundSubAgentDelivery.ts` 负责。

### 11.2 嵌套阻断的三层实现

1. **manifest 层**：工具描述解析函数 `resolveLobeAgentManifest` 在子代理上下文或群组上下文（scope 取 group 或 group_agent）里，从模型可见的 api 列表中删掉 callSubAgent，并把系统提示换成去掉子代理说明的版本，模型在这些场景看不到该工具（`packages/builtin-tool-lobe-agent/src/resolveManifest.ts:25-36`）。
2. **执行层防御**：manifest 过滤失效时（例如历史消息里残留的调用），执行体仍检查 `ctx.isSubAgent`，命中即返回 `NESTED_SUB_AGENT_NOT_ALLOWED` 错误（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:155-160`）。
3. **runtime 层兜底**：旧版 legacy 调用路径 execSubAgent 与 execSubAgents 在元数据标记为子代理时直接返回“子代理内不能再次发起子代理调用”的结果，不再往下调度（`packages/agent-runtime/src/executors/subAgent.ts:169-254`）。

三层防御的判定依据都是同一个 `isSubAgent` 标记（`BuiltinToolContext.isSubAgent`/`BuiltinToolResolveContext.isSubAgent`，`packages/types/src/tool/builtin.ts:314-315, 596-597`），由父 runtime 在创建子代理运行时上下文时设置——**只信任一个布尔位**，若该标记在某条路径上被遗漏赋值，三层防御中的第 1/3 层会同时失效，只剩第 2 层（执行体自检）兜底。

### 11.3 隔离 Thread 与 `inheritMessages`

子代理默认不继承父会话消息：`inheritMessages` 默认为 `false`（`packages/types/src/tool/builtin.ts:883, 906-913`），子代理在独立的 isolation thread 里运行。父会话的用量与成本统计挂在子代理首条工具消息的 `pluginState` 上回传，类型注释说明父会话的用量面板据此才能把子代理计入。

这个字段能否生效，取决于执行体有没有把它继续转发。manifest 为 callSubAgent 声明了 `inheritMessages` 参数（`packages/builtin-tool-lobe-agent/src/manifest.ts:242-246`），服务端执行体解构参数后只把描述、指令与超时三项传给子代理运行入口（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:174-178`），未见继续转发这个开关。它是否在其他层（服务端子代理传输或 legacy 回调内部）被消费，本次未确认；若没有其他消费点，该字段只在 client 路径生效。

### 11.4 超时与默认值

- **`lobe-agent.callSubAgent` 的超时默认值未在代码中兑现。** manifest 把默认值描述为 "Default is 30 minutes"（`packages/builtin-tool-lobe-agent/src/manifest.ts:254-257`），但执行体既没有显式兜底，也没有 clamp 代码，`timeout` 参数直接透传（`lobeAgent.ts:169-178`）。

  30 分钟这个硬编码默认值确实存在，落在另一个入口：`lobe-agent-management.callAgent` 写的是 `timeout || 1_800_000`（`apps/server/src/services/toolExecution/serverRuntimes/agentManagement.ts:85`）。两个子代理调度入口对"未传超时"的兜底行为因此可能不一致，`callSubAgent` 未传 `timeout` 时最终落到哪个默认值需要进一步验证。
- 工具调用本身（无论是否 sub-agent）的超时统一走 `resolveToolTimeoutMs`（维度 5.3），clamp 到 `[1_000, 800_000]` ms。

### 11.5 `runInClient`：桌面本机执行 vs 服务端沙箱

`TriggerExecuteTaskParams.runInClient`（`packages/types/src/tool/builtin.ts:788-789`）注释明确："MUST be true when task requires local-system tools. Default is false (server execution)"。这是群组编排 `executeAgentTask` 场景下，选择子任务在**发起用户的桌面客户端本机**执行还是**服务端**执行的显式开关——默认服务端（更安全，无法访问用户本机文件），需要访问本机资源才切到 `runInClient: true`。

### 11.6 并发上限

- 批量子代理的 legacy 路径 `execSubAgents` 把并发硬编码为 15（`packages/agent-runtime/src/executors/subAgent.ts:226-230`），与维度 5.2 批次执行器不设上限的做法形成对照。
- 群组编排的 `broadcast` 不设并发上限：成员列表有多长就同时对每个成员发起一次客户端 Agent 执行，成员很多的群组会一次性打满（`src/store/chat/agents/GroupOrchestration/createGroupOrchestrationExecutors.ts:315-328`）。

### 11.7 取消（abort）在客户端与服务端的不对称

- **client 路径**：`AgentRuntime.getAbortController()`（维度 5.4）从 operation 里取 `AbortController`，可由 UI 的取消按钮直接 `.abort()`，中断进行中的 fetch/stream。
- **server 路径**：`isOperationInterrupted`（`packages/agent-runtime/src/executors/callLlm.ts:51-62`）是**轮询式**检查——只在每次 LLM 重试前查一次数据库状态，**不能中断一个已经在飞行中、尚未失败/未到重试点的 LLM 调用本身**（即调用发出后，若 provider 一直不返回，取消信号要等到这次调用完成或超时才会被处理）。这是 client（同进程 AbortController 级联）和 server（跨请求边界，只能靠状态轮询）在取消能力上的**结构性差异**，标记为「已确认」（源码明确只在 attempt 之间检查，attempt 内部没有额外中断点）。

### 11.8 `lobe-task` 调度模型

`runTasks` 的 manifest 写明"Each task is started sequentially in array order; failures on individual tasks do not abort the batch"（`packages/builtin-tool-task/src/manifest.ts:298-299, 316-320`），即批量任务按数组顺序逐个启动、单任务失败不中止整批，与 legacy 批量子代理和群组 broadcast 的并发模型不同。定时能力上，`setTaskSchedule` 支持 cron（含时区）与 heartbeat（秒级间隔）两种模式，但真正驱动调度的**后端调度器**位置本次未定位到具体代码，列入维度 13 未验证事项。

**依据**：[lobeAgent.callSubAgent](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts)、[agentManagement.callAgent 默认超时](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/agentManagement.ts)、[resolveLobeAgentManifest](../../lobehub/packages/builtin-tool-lobe-agent/src/resolveManifest.ts)、[lobe-agent manifest](../../lobehub/packages/builtin-tool-lobe-agent/src/manifest.ts)、[execSubAgent/execSubAgents](../../lobehub/packages/agent-runtime/src/executors/subAgent.ts)、[SubAgentCallbacks/RunSubAgentParams 类型](../../lobehub/packages/types/src/tool/builtin.ts)、[call_tool 的 deferred 处理](../../lobehub/packages/agent-runtime/src/executors/tool.ts)、[群组编排 broadcast 执行器](../../lobehub/src/store/chat/agents/GroupOrchestration/createGroupOrchestrationExecutors.ts)、[callLlm 中断检测](../../lobehub/packages/agent-runtime/src/executors/callLlm.ts)、[task manifest](../../lobehub/packages/builtin-tool-task/src/manifest.ts)。

## 12. 与消息渲染器笔记的交叉点

参考 `LobeHub-消息渲染调查笔记.md` 第 13 节「工具渲染注册表」和第 9 节「AssistantGroup」。两条笔记在"工具调用如何呈现"上的交叉点：

### 12.1 工具调用与审批的呈现路径

工具卡片上的内容全部来自数据库/store 里的结构化字段：审批状态取自 `tool.intervention.status`，结果取自 `tool.result`，工具身份取自 `tool.apiName`/`identifier`。卡片组件直接从 `useConversationStore(dataSelectors.getToolInBlock(...))` 读取整个 tool 对象，没有解析模型输出的自然语言或 Markdown 文本（`src/features/Conversation/Messages/AssistantGroup/Tool/index.tsx:39-49`）。

审批卡片 `Intervention/index.tsx` 同样只读结构化的 intervention、result 与 args 三个字段。按钮点击后调用 store 的审批 action（`ApprovalActions.tsx:150-187`），这些 action 直连服务端的 `HumanInterventionHandler`，中间没有一步从消息文本里提取用户意图。

### 12.2 是否可被模型输出伪造/混淆

消息渲染器笔记第 11 节记录 Markdown 有一套自定义标签插件系统（Tool、Task、Skill、Mention 等）。其中 `<tool name="..." label="..." />` 标签只渲染成 ActionMention 展示 pill（`src/features/Conversation/Markdown/plugins/Tool/index.ts` 与同目录 `Render.tsx:19-24`），**不会**触发真实的工具调用或审批流程：它是纯装饰性标签，用户或模型在文本里写这个标签，页面只显示一个提及样式的徽章。

结论：**模型无法仅凭文本输出伪造出一个真实的、可被点击批准的工具审批卡片**，因为：

1. 审批卡片渲染依赖 `messagePlugins.intervention.status === 'pending'` 这个数据库字段，该字段只能由服务端 `humanApprove` 执行器写入（`packages/agent-runtime/src/executors/humanApprove.ts:161-173`），模型输出的普通文本内容不会被解析回写这个字段。
2. `Tool`/`Task` markdown 标签只是展示装饰,点击这些标签渲染出的 pill 不会触发 `approveToolCall`。
3. 唯一的潜在混淆点是**视觉钓鱼**：模型可以在普通文本正文里模仿审批卡片的措辞（比如输出"工具已获批准，执行中..."之类文本），欺骗用户以为某个危险操作已经过审批,但这属于内容层面的社会工程,不是绕过审批状态机本身——真实的工具执行结果仍然会依附在结构化的 tool 消息节点上,与被模仿的文本分离显示。这一点在代码层面未发现专门的防混淆机制（比如强制在助手正文和工具卡片之间加视觉分隔提示"以下内容为工具真实执行结果"），标记为**需要进一步验证**（UI 层是否有额外的视觉区分设计,需要设计稿/实际渲染截图确认,不能仅从组件代码判断视觉效果)。

**依据**：[Tool 卡片渲染](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/index.tsx)、[Intervention 卡片](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/index.tsx)、[ApprovalActions](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx)、[Tool markdown 标签](../../lobehub/src/features/Conversation/Markdown/plugins/Tool/index.ts)、[Tool markdown Render](../../lobehub/src/features/Conversation/Markdown/plugins/Tool/Render.tsx)、[humanApprove 执行器](../../lobehub/packages/agent-runtime/src/executors/humanApprove.ts)、[消息渲染调查笔记](../消息渲染器/LobeHub-消息渲染调查笔记.md)。

## 13. 未验证事项与后续调查缺口

1. **callSubAgent 超时的实际看门狗触发点**：服务端执行体没有为超时参数补默认值，也没有 clamp，直接透传给子代理运行入口，30 分钟这个默认值只出现在 manifest 的描述文字里；真正把 30 分钟写进代码的只有姊妹工具 `lobe-agent-management.callAgent`。未传超时值时最终落到哪个值、超时踢除由子代理运行入口内部的定时器完成还是靠父 operation 的轮询检查，本次未定位到具体代码（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:169-178`；同目录 `agentManagement.ts:85`）。
2. **client-tool 路径跳过截断后，结果在哪一层被限制**：服务端工具传输层对 client-tool 分发设置跳过结果截断的开关，绕过 `ToolExecutionService` 内的通用截断（`ServerToolTransport.ts:220`）；这条路径的结果是否在流式 chunk 层或消息持久化层另有长度限制，本次未核实。
3. **lobe-task 的调度由谁触发**：任务工具的计划设置接受 cron 表达式与秒级心跳间隔两种自动化模式，触发这两类调度的后台 worker 与轮询进程位置本次未定位。
4. **inheritMessages 在服务端 callSubAgent 路径是否被消费**：执行体调用子代理运行入口时没有转发这个字段（见维度 11.3），要确认是否生效需跟踪服务端子代理传输层及其上游 legacy 回调的完整实现（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:174-178`）。
5. **StreamableHTTPClientTransport 自身是否内建 SSRF 过滤**：该传输类来自 `@modelcontextprotocol/sdk`，依赖源码本次未审查，只确认 LobeHub 侧没有额外包一层私网地址防护（见维度 4.3）。
6. **lobe-cloud-sandbox 的网络隔离范围**：沙箱容器能否访问公网、是否有独立的出网白名单，本次未定位到沙箱运行时实现。
7. **文档与代码不一致（已确认一处）**：结果长度上限字段的注释仍写默认 6000，同一文件的配置 schema 默认 25000，与共享截断模块的常量一致——过期的是注释，实际生效值取 25000（`packages/types/src/agent/chatConfig.ts:207,314`、`packages/prompts/src/toolResult/index.ts`）。
8. **维度 9 表格里标注“未核实”的工具**：下列工具的 humanIntervention 取值本次没有逐条打开源码核对，只确认了它们在注册表中的存在与大致用途。

   ```text
   lobe-skills, lobe-skill-store, lobe-skill-maintainer
   lobe-knowledge-base, lobe-memory, lobe-image-generation
   lobe-page-agent, lobe-agent-builder, lobe-group-agent-builder
   lobe-agent-management, lobe-calculator, lobe-web-onboarding
   lobe-brief, lobe-channel, lobe-dashboard
   lobe-canvas, lobe-attachments, lobe-user-interaction
   lobe-auv, lobe-acceptance-evidence, agent-signal 系列
   lobe-self-iteration
   ```

9. **connector 权限表的取值全集**：ConnectorToolPermission 除 disabled 之外是否还有 enabled、ask 一类中间态，以及这些取值与 humanIntervention 如何叠加，本次未核实完整枚举。
10. **Local Sandbox 的围栏强度**：`packages/device-sandbox` 的 SRT 沙箱运行时本次未逐项验证，包括进程与网络隔离、writable roots 策略和 `srtWinStaging` 的 Windows 安装；客户端解析出的沙箱配置与网关侧执行上下文里的同名配置被要求保持一致，注释写明不一致时会出现“选了 Local Sandbox 却跑未围栏命令”的情况，这条一致性未做运行验证（`src/helpers/localSandbox.ts:29-35`）。
11. **callSubAgent 默认超时**：执行体直接透传超时值，没有硬编码兜底，与 manifest 声明的 30 分钟默认值存在出入，维持未核实（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:177-185`）。
