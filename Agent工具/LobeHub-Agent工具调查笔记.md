# LobeHub Agent 工具调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`（monorepo，重点 `apps/server`、`apps/desktop`、`packages/agent-runtime`、`packages/builtin-tools`、`packages/context-engine`、`packages/types`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：只读源码梳理（Read/Grep/Glob + 后台子调查代理核实内建工具清单、扩展机制、子代理编排三个子领域）；未修改 LobeHub 仓库任何文件
>
> 调查范围：只统计模型能够发现、请求并触发执行的工具（builtin / plugin / MCP / connector），不把消息渲染器、纯 UI 功能或模型供应商自身能力计入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 把“模型能看到什么工具”“工具在哪执行”“谁批准执行”严格拆成三条独立的判定链，且服务端与前端复用同一套上下文引擎、Agent 运行时和内建工具实现。

1. **工具目录**是 `packages/builtin-tools/src/index.ts:166-399` 里一个 35 项的静态注册表（条目见维度 9），每项声明标识符、manifest、隐藏/可发现状态和动态解析入口；manifest 类型 `builtin|default|markdown|mcp|standalone` 决定 schema 来源。注册表还定义群组编排工具集，以及手动 skill 激活模式下的排除项和专属控件（`index.ts:87-97,139`）。
2. **注入到模型的可见集合**由 `ToolsEngine.generateTools()`（`packages/context-engine/src/engine/tools/ToolsEngine.ts`）统一裁剪，规则由启用检查器执行：先判断显式激活是否允许绕过，再做平台过滤，最后应用声明式规则表。服务端入口位于 `apps/server/src/modules/Mecha/AgentToolsEngine/index.ts`；三种模式使用不同规则和默认工具，chat mode 强制关闭显式激活。chat mode 的图像生成必须 **pinned 才注入**（`bb406736f`）；agent mode 会为 bot 会话注入消息工具，为群组注入 supervisor 编排工具，并应用 remote-device 锁定期规则（`index.ts:332-347`）。
3. **审批**是由 `GeneralChatAgent.checkInterventionNeeded` 执行的固定顺序判定：安全黑名单的 always 规则优先且不可绕过，其后依次处理动态规则、headless 特殊放行、required 规则、静态 always、自动运行、未知 manifest、白名单和 manual 配置。批准后进入 `waiting_for_human` 状态机，待审批工具消息持久化在数据库，前端依据工具调用 chunk 和审批事件渲染卡片。
4. **执行位置**在 `ToolExecutionService.executeTool`（`apps/server/src/services/toolExecution/index.ts:82-179`）分派：builtin 走 `BuiltinToolsExecutor`；MCP 按 `mcpParams.type` 分三路——`cloud` 走 market/discover gateway，`stdio` 在 `deviceGateway.isConfigured && activeDeviceId` 时转发到用户设备，否则走本地 `mcpService.callTool`（服务器进程内 spawn，或桌面 Electron 主进程内 spawn）。**所有路径执行前**都先查 connector 权限表，`disabled` 一律硬拒绝，覆盖 MCP/market skills/Composio/qstash。local-system 工具的客户端执行经 `20afc09c7` 收敛为共享运行时入口 `packages/tool-runtime/src/LocalSystemExecutionRuntime.ts`（+cwd 注入，`pathScope` 迁入 `tool-runtime/src/pathScope.ts`）；桌面端另有 **Local Sandbox 执行环境**（`packages/device-sandbox`：`createSandboxEnv`/`SrtSandboxRuntime`/`installDeviceSandbox` + `src/helpers/localSandbox.ts`，`e9b6d00ab`/`9b4f944cb`/`95dfa1d38`），`executionTarget.ts` 用 `isLocalSandboxEnabled` 判定——本地命令可在沙箱围栏内执行，也可“裸 spawn”执行（沙箱能力探测/安装/工作目录的细节见维度 13 与生成式输出笔记）。
5. **结果回注**统一走 `truncateToolResult`（默认 25,000 字符，`lobe-agent-documents` 例外），截断附带明确的 "[Content truncated...]" 提示文本,防止模型误判内容完整。

以下各节对工具目录、注入、审批、执行边界给出精确到代码行的证据，其中几处细节需要单独强调：alwaysOnToolIds 只在 agent mode 生效（维度 2.1）；审批检查是固定顺序的多阶段判定管道，不是简单的“合并”（维度 6.2）；disabled 工具在统一执行入口的 connector 权限表处拦截（维度 7.3）。

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

`packages/builtin-tools/src/index.ts:163-387` 是一个约 30 项的静态工具注册表，每项包含以下字段：

- `identifier`：工具标识符，如 `lobe-web-browsing`
- `manifest`：静态工具描述
- `resolveManifest?`：按上下文动态生成描述，例如在子代理/群组内隐藏子代理调用
- `hidden?`：从用户界面隐藏，但仍可能被系统注入
- `discoverable?`：是否出现在发现/市场列表；浏览器和本地系统工具按桌面环境决定（`packages/builtin-tools/src/index.ts:238,245`）

`LobeBuiltinTool`/`BuiltinToolManifest` 类型定义在 `packages/types/src/tool/builtin.ts:231-357`。`meta`（avatar/description/tags/title）被 hoist 到顶层供 UI/discovery/token 估算读取（`packages/builtin-tools/src/index.ts:400-406`）。

### 1.2 manifest 类型语义差异

`ToolManifestType = 'builtin' | 'default' | 'markdown' | 'mcp' | 'standalone'`（`packages/types/src/tool/manifest.ts:5`）：

- `builtin`：框架内置工具，schema 硬编码在 `packages/builtin-tool-*/src/manifest.ts`，执行体在 `apps/server/.../serverRuntimes/*.ts` 或桌面客户端执行器
- `default`：普通自定义插件（OpenAPI 或 simple 模式），`api[].parameters` 直接来自用户导入的 manifest JSON；`CustomPluginParams.apiMode` 区分 `'openapi' | 'simple'`（`packages/types/src/tool/plugin.ts:14`）
- `mcp`：Model Context Protocol 工具，manifest 携带 `customParams.mcp`（stdio/http/cloud，见维度 10）
- `standalone`：独立 UI 插件，`ToolManifest.ui = { mode: 'iframe'|'module', url, width?, height? }`（`packages/types/src/tool/manifest.ts:32`），工具本体不一定提供函数调用 API，而是提供一个可交互界面
- `markdown`：以 Markdown 文本描述能力的轻量插件类型（类型层面与 `default` 同构，`api[]` + `openapi?`，但语义上不依赖 OpenAPI schema）

`ToolNameResolver.generate` 在生成模型可见的函数名时，会把非 builtin/default 类型编码进名字尾部（`packages/context-engine/src/engine/tools/ToolNameResolver.ts:92-95`），例如自定义 MCP 工具名形如 `custom_mcp____toolName____mcp`。

### 1.3 api 级与 manifest 级字段关系

`LobeChatPluginApi`（`packages/types/src/tool/builtin.ts:171-229`）每个 api 除 `name`/`description`/`parameters` 外，还可以带：

- `humanIntervention?: ExtendedHumanInterventionConfig`：api 级审批策略，优先级高于 manifest 级 `humanIntervention`（见维度 6）
- `defaultTimeoutMs?`：默认 120,000ms，服务端 clamp 到 `[1_000, 800_000]`（字段注释见 `builtin.ts:174-182`；clamp 实现见维度 5）
- `renderDisplayControl?`：`'collapsed'|'expand'|'alwaysExpand'`，纯 UI 展示行为，不影响模型
- `work?: PluginApiWorkConfig`：声明式 Work 注册（create/update/delete 一个 document/task 资源），执行成功后由 dispatch 层自动注册，不需要工具自己写注册代码

这些框架字段（`humanIntervention`/`work`）在生成模型可见 schema 时会被剥离——`ToolsEngine.convertManifestsToTools` 只读 `api.description`/`api.name`/`api.parameters`（`packages/context-engine/src/engine/tools/ToolsEngine.ts:265-274`），不会泄露给 LLM。

**依据**：[builtin registry](../../lobehub/packages/builtin-tools/src/index.ts)、[manifest 类型](../../lobehub/packages/types/src/tool/manifest.ts)、[builtin 类型定义](../../lobehub/packages/types/src/tool/builtin.ts)、[plugin 类型](../../lobehub/packages/types/src/tool/plugin.ts)、[ToolNameResolver](../../lobehub/packages/context-engine/src/engine/tools/ToolNameResolver.ts)、[ToolsEngine](../../lobehub/packages/context-engine/src/engine/tools/ToolsEngine.ts)。

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

- **chat 模式**（`index.ts:289-294`）：只有图像生成、知识库、记忆和网页浏览四个能力可能开启；其中图像生成**必须 pinned 才注入**（`bb406736f`）。chat mode 不允许显式激活其他工具（`index.ts:392`）。
- **custom 模式**（`index.ts:300`）：工具集合严格等于 agent 声明的插件列表，不叠加常驻工具、默认工具或激活器，适用于聚焦型内建子代理（如 verify agent）。
- **agent 模式**（`index.ts:302-349`）：在用户插件和常驻工具之上，再按运行环境、设备代理、在线状态和锁定状态加入系统工具；bot 会话自动加入消息工具，群组 supervisor 使用统一的编排工具集。设备能力不可用时，构建阶段还会从 manifest 中物理剔除设备工具。

### 2.2 用户启用状态

用户在 agent 配置里选择的插件（`agentConfig.plugins`）在 agent 模式下被展开为 `rules` 表的 `true` 项（`index.ts:255`），custom 模式下就是唯一来源（`index.ts:251`）。用户对单个 connector 工具的启用/禁用（区别于"插件是否安装"）走另一张表 `connectorTools`，在**执行时**而非**注入时**被检查（见维度 7 的 `getConnectorToolPermission`）——也就是说一个被 connector 禁用的工具，schema 仍会出现在模型的 `tools` 列表里，只是调用时会被硬拒绝，而不是在注入阶段被过滤掉。

### 2.3 按模型能力过滤

`ToolsEngine.generateTools`/`generateToolsDetailed` 第一步是 `checkFunctionCallSupport`（`packages/context-engine/src/engine/tools/ToolsEngine.ts:161-171`），调用注入的 `functionCallChecker`；若模型不支持 function calling，直接返回 `undefined`（不注入任何工具）。服务端把这个 checker 接到 `apps/server/src/services/aiAgent/index.ts:2784-2787`：

```ts
const isModelSupportToolUse = (m: string, p: string) => {
  const info = builtinModels.find((item) => item.id === m && item.providerId === p);
  return info?.abilities?.functionCall ?? true;
};
```

即按 model-bank 里的 `abilities.functionCall` 字段判断，未知模型默认认为支持。若模型支持 FC 但不支持某个具体 plugin（当前实现未见按 plugin 级能力二次过滤，只有整体开关），`filterEnabledPlugins`（`ToolsEngine.ts:176-248`）会把所有 `pluginIds` 标记为 `incompatible`。

### 2.4 注入到请求 tools 的位置

最终工具数组由 `ToolResolver.resolve()`（`packages/context-engine/src/engine/tools/ToolResolver.ts:29-120`）在每个 step 合并：operation 级快照 `operationToolSet.tools` + 累积的 step 级激活 `accumulatedActivations`（例如 activator 动态激活的工具、设备工具、`@mention` 工具）+ 当前 step 的新激活，再按 `allowedToolNames` 做二次过滤（用于把已激活但本轮又被收紧的工具排除）。`stepDelta.deactivatedToolIds.includes('*')` 是 `forceFinish`（超过 `maxSteps`）时的强制清空开关（`ToolResolver.ts:84-93`），确保强制收尾的最后一轮 LLM 调用不带任何工具。

**依据**：[AgentToolsEngine](../../lobehub/apps/server/src/modules/Mecha/AgentToolsEngine/index.ts)、[builtin-tools 常量](../../lobehub/packages/builtin-tools/src/index.ts)、[executionTarget.resolveToolMode](../../lobehub/src/helpers/executionTarget.ts)、[ToolsEngine](../../lobehub/packages/context-engine/src/engine/tools/ToolsEngine.ts)、[ToolResolver](../../lobehub/packages/context-engine/src/engine/tools/ToolResolver.ts)、[execAgent 的 functionCall checker](../../lobehub/apps/server/src/services/aiAgent/index.ts)。

## 3. 模型调用表示与解析

### 3.1 identifier/apiName 的编解码

LobeHub 完全走**原生 tool call** 路径（OpenAI/Anthropic/Gemini 等 provider 的结构化 `tool_calls`/`function_call` 字段），没有观察到文本协议解析器。

编码：`ToolNameResolver.generate(identifier, apiName, type)`（`packages/context-engine/src/engine/tools/ToolNameResolver.ts:92-122`）拼接为 `identifier____apiName[____type]`（`type` 省略 `builtin`/`default`）。若含非 `[\w-]` 字符（如中文/点号），整段替换为 `MD5HASH_<12位md5>`（`normalizeComponent`，`ToolNameResolver.ts:79-83`）。若拼接后总长 ≥ `TOOL_NAME_MAX_LENGTH`（默认 64，OpenAI 限制，可用环境变量调整或设 0 关闭，`ToolNameResolver.ts:17-51`），先 hash apiName，仍超长再 hash identifier。

解码：`ToolNameResolver.resolve(toolCalls, manifests, offeredToolNames)`（`ToolNameResolver.ts:135-217`）按 `____` 切分；若模型返回的名字缺失分隔符（部分模型会吐出裸 apiName），会在 `offeredToolNames`（本轮实际发给模型的工具名集合）范围内做唯一匹配兜底恢复 identifier（`ToolNameResolver.ts:149-178`）——这个白名单限制正是防止模型"猜出"一个未被启用工具的调用从而绕过工具注入过滤。哈希后的 identifier/apiName 通过反查 `genHash(id) === identifierMd5` 还原（`ToolNameResolver.ts:180-212`）。

### 3.2 流式期间的工具事件与 `tools_calling`

流式 LLM 调用完成后（`callLlmFinalizer.finalizeCallLlmTurn`，`packages/agent-runtime/src/executors/callLlmFinalizer.ts:258-379`）：

1. 发 `stream_end` 事件，携带 `toolsCalling: output.toolsCalling`（`callLlmFinalizer.ts:283-295`）
2. 若无工具调用且非 abort，额外发 `visible_output_end`（提示前端"最终答案已完整"，`callLlmFinalizer.ts:298-316`）
3. 持久化最终 assistant message（`tools: sanitizePersistedTools(output.toolsCalling)`），`nextContext.phase = 'llm_result'`，payload 含 `hasToolsCalling`/`toolsCalling`

工具执行阶段的事件：`call_tool`/`call_tools_batch` 执行器在真正跑之前发 `tool_start`，跑完发 `tool_end`（`packages/agent-runtime/src/executors/tool.ts:386-390, 424-436, 627-631, 647-659`）。**审批阶段**的关键 chunk 是 `chunkType: 'tools_calling'`（`packages/agent-runtime/src/executors/humanApprove.ts:187-192` 和 `tool.ts:238-243`，pauseForTools 复用），附带 `toolMessageIds`（tool_call_id → 已创建的 pending tool message id 映射，供前端拉取占位消息）；随后发 `human_approve_required` 和 `tool_pending` 两个 `AgentEvent`（`humanApprove.ts:194-206`）。

### 3.3 参数解析与容错

模型返回的 `arguments` 是字符串。三层容错：

1. `sanitizeToolCallArguments`（`packages/utils/src/sanitizeToolCallArguments.ts:18-29`）：非法 JSON 先尝试 `partial-json` 部分解析，仍失败则整体替换为 `"{}"`，防止一条历史消息里的坏 JSON 让严格 provider（如 NVIDIA NIM）在回放整段历史时对整个请求返回 400。
2. `ToolArgumentsRepairer`（`packages/context-engine/src/engine/tools/ToolArgumentsRepairer.ts:56-137`）：修复部分模型（如 Claude haiku-4.5）把整个参数对象错误地转义塞进第一个字段的畸形输出，按 schema `required` 字段名反向重建 JSON。
3. `parseToolArgs`（`packages/agent-runtime/src/executors/tool.ts:104-120`）：执行时再做一次保守 `JSON.parse`，失败则回退空对象——这个失败**不阻止执行**，只影响 hook 预览用的参数快照。

**依据**：[ToolNameResolver](../../lobehub/packages/context-engine/src/engine/tools/ToolNameResolver.ts)、[callLlmFinalizer](../../lobehub/packages/agent-runtime/src/executors/callLlmFinalizer.ts)、[humanApprove executor](../../lobehub/packages/agent-runtime/src/executors/humanApprove.ts)、[tool executor](../../lobehub/packages/agent-runtime/src/executors/tool.ts)、[sanitizeToolCallArguments](../../lobehub/packages/utils/src/sanitizeToolCallArguments.ts)、[ToolArgumentsRepairer](../../lobehub/packages/context-engine/src/engine/tools/ToolArgumentsRepairer.ts)。

## 4. 参数校验与规范化

### 4.1 schema 校验点

LobeHub **没有在工具执行前对参数做 JSON Schema 结构校验**（未发现 ajv/zod 对 `arguments` 按 `api.parameters` 强制校验的代码路径；`ToolArgumentsRepairer`/`sanitizeToolCallArguments` 只保证字符串能被解析为合法 JSON，不校验字段类型/必填项是否符合 schema）。参数最终是否合法，由各工具自己的执行体（`serverRuntimes/*.ts`）在业务逻辑里判断，出错时返回 `{ success: false, error }`，再经 `classifyToolError` 分类。这与很多工具框架（如强制 ajv validate）不同，是一个**未做强类型校验**的设计选择。

`normalizeToolParameters`（`packages/context-engine/src/engine/tools/utils.ts:27-33`）只是把缺失的 required 字段补成空数组，用于兼容部分严格 provider 对 null 值的拒绝，跟安全校验无关。

### 4.2 参数错误的处理

`errorClassification.ts`（`apps/server/src/services/toolExecution/errorClassification.ts`）把工具执行错误分成三类 `ToolErrorKind = 'replan' | 'retry' | 'stop'`：`BAD_REQUEST`/`INVALID_ARGUMENT`/`MANIFEST_NOT_FOUND` 等归 `replan`（提示模型重新规划参数），`RATE_LIMITED` 等归 `retry`，`FORBIDDEN`/`UNAUTHORIZED` 等归 `stop`。分类同时看错误 `code`、HTTP `status`（400/404/409/422 → replan，401/403 → stop，429/5xx → retry）和消息关键词兜底。

### 4.3 URL/路径类参数的处理面

- **本地文件路径**（`lobe-local-system`）：`pathScopeAudit` dynamic resolver（`packages/builtin-tool-local-system/src/interventionAudit.ts:72-106`）从 `path`/`file_path`/`directory`/`oldPath`/`newPath`/`pattern`（若以 `/` 开头）等字段提取路径候选，判断是否越出 `metadata.workingDirectory`（`isPathWithinWorkingDirectory`，`interventionAudit.ts:19-32`），越界则要求人工介入（`policy: 'required'`），否则免审批（`default: 'never'`，manifest 声明见 `packages/builtin-tool-local-system/src/manifest.ts:13-19` 等多处 `humanIntervention: { dynamic: { type: 'pathScopeAudit' } }`）。但这只是**审批触发条件**，不是硬性访问控制——`readFile`/`writeFile`/`editFile`/`moveFiles`/`searchFiles`/`grepContent`/`globFiles` 均走同一 resolver。`runCommand`（shell 命令）不做路径提取，直接 `humanIntervention: 'required'`（`manifest.ts:229`），意味着 shell 命令内嵌的任意路径不经过 `pathScopeAudit`，只靠通用的 `required` 审批 + 全局安全黑名单（维度 6）兜底。
- **URL 类参数的网络访问范围**：
  - `lobe-web-browsing` 默认爬虫 `naive` 通过 `ssrfSafeFetch`（`packages/ssrf-safe-fetch/index.ts:64-128`）发起请求，底层用 `request-filtering-agent` 的 `RequestFilteringHttpAgent`/`RequestFilteringHttpsAgent` 挂到 `fetch` 的 `agent`，默认 `allowPrivateIPAddress: false`（受环境变量 `SSRF_ALLOW_PRIVATE_IP_ADDRESS` 控制，`index.ts:72-83`），私有/内网地址请求会被拒绝并抛 `SSRF blocked` 错误；其余 crawler 实现（`jina`/`browserless`/`search1api`/`tavily`/`exa`/`firecrawl`）只转发到固定的第三方服务域名，不直接对用户提供的 URL 发起请求。
  - 服务端 MCP HTTP client（`src/libs/mcp/client.ts:206-208`）与桌面 `MCPClient`（`apps/desktop/src/main/libs/mcp/client.ts:53-56`）用官方 `StreamableHTTPClientTransport` 直连用户配置的 MCP server URL，未包 `ssrfSafeFetch` 或等价的私网地址过滤；该第三方 SDK 自身是否有内建私网过滤未审查源码（列入未验证事项）。

**依据**：[interventionAudit.ts](../../lobehub/packages/builtin-tool-local-system/src/interventionAudit.ts)、[local-system manifest](../../lobehub/packages/builtin-tool-local-system/src/manifest.ts)、[errorClassification](../../lobehub/apps/server/src/services/toolExecution/errorClassification.ts)、[ToolsEngine utils](../../lobehub/packages/context-engine/src/engine/tools/utils.ts)。

## 5. 编排循环

### 5.1 迭代/步数上限

`AgentRuntime.step()`（`packages/agent-runtime/src/core/runtime.ts:82-262`）每步自增 `state.stepCount`，一旦 `stepCount > maxSteps` 就置 `forceFinish = true`（`runtime.ts:92-102`）——不是立刻硬停，而是允许当前已发出的工具调用跑完，下一次 `call_llm` 会通过 `buildStepToolDelta`/`ToolResolver` 的 `deactivatedToolIds: ['*']` 把工具全部摘除并注入总结提示，逼模型给出最终文本答案（`GeneralChatAgent.toLLMCall`，`packages/agent-runtime/src/agents/GeneralChatAgent.ts:389-428` 对 `state.forceFinish` 的处理；`ToolResolver.resolve`，`ToolResolver.ts:84-93`）。`finish` 的 `reason` 会标记为 `'max_steps_completed'`（`GeneralChatAgent.ts:587,595-596`）。

`maxSteps` 默认值 999（`apps/server/src/services/agentRuntime/AgentRuntimeService.ts:2911`：`const { maxSteps = 999, ... } = options ?? {}`），可由调用方（如 eval run）显式传入更小的值（schema 限制 `1~1000`，`apps/server/src/routers/lambda/evalRunConfig.schema.ts:66`）。

### 5.2 并发

`call_tools_batch` 执行器（`packages/agent-runtime/src/executors/tool.ts:583-807`）用 `Promise.all(toolsToExecute.map(...))` 并发跑一批工具（`tool.ts:616`），没有显式并发数上限（依赖 Node 事件循环和下游 HTTP/进程连接池自然限流）。单个工具失败只 `push` 一个 `error` 事件，不 `throw`（除非标记为 `isPersistFatal`），不会阻塞同批其他工具的结果收集（`tool.ts:706-713`）。批内一部分工具走 client executor、一部分走 server 时，`clientTools`/`serverTools` 被拆开：如果全部是 client 且当前 host 不支持 client 工具执行，整批 pause（`tool.ts:600-607`）；否则先跑 server 部分，client 部分连同异步/deferred 工具一起进入 `pendingTools` 并 pause（`tool.ts:770-786`）。

### 5.3 超时

`resolveToolTimeoutMs`（`apps/server/src/modules/AgentRuntime/resolveToolTimeout.ts:53-66`）三级优先：模型在 `arguments.timeout` 里显式指定 > `manifest.api[apiName].defaultTimeoutMs` > 全局默认 `GLOBAL_DEFAULT_TIMEOUT_MS = 120_000`。最终结果**始终** clamp 到 `[MIN_TIMEOUT_MS=1_000, MAX_TIMEOUT_MS=800_000]`（`resolveToolTimeout.ts:8,13,20,22-23`）——注释明确写"client 只是建议者，这个函数是唯一裁决者"，即模型或 manifest 想设置的超时不能绕过这个硬边界。`MAX_TIMEOUT_MS=800_000` 与云函数运行窗口（800s）对齐，防止单个 client-tool dispatch 活得比它所在的整次 run 还久。

### 5.4 取消（cancel/abort）

`AgentRuntime.getAbortController()`（`packages/agent-runtime/src/core/runtime.ts:70-75`）从 `config.getOperation(operationId).abortController` 取，供 LLM/工具传输层接线。用户取消时，runtime 检查 `state.status === 'interrupted'` 并统一走 `handleAbort`（`GeneralChatAgent.ts:433-456`，在 `runner()` 顶部优先判断，`GeneralChatAgent.ts:464-465`）：若当前有未解决的工具调用（`llm_result`/`human_abort` phase 下的 `hasToolsCalling`，或 `tool_result`/`tools_batch_result` phase 下扫描 `pluginIntervention.status==='pending'` 的消息），发出 `resolve_aborted_tools` 指令，把这些工具持久化为 `content: 'Tool execution was aborted by user.'`、`pluginIntervention.status: 'aborted'`（`packages/agent-runtime/src/executors/resolveTools.ts:179-256`），随后整个操作 `status = 'done'`；否则直接 `finish`。

`call_llm` 侧的中断检测走 `isOperationInterrupted`（`packages/agent-runtime/src/executors/callLlm.ts:51-62`），在每次重试前调用 `operationStore.loadState` 查最新状态，若已被标记 `interrupted` 则不再重试并把当前已收到的部分输出通过 `persistInterruptedCallLlmResult` 落盘（`callLlm.ts:148-154, 168-186`；`callLlmFinalizer.ts:381-402`），保留 `metadata.interruptedMidStream: true` 供前端识别未完成的流式内容。

### 5.5 错误回传

工具执行异常在 `call_tool`/`callToolsBatch` 里被捕获，除非标记为 `isPersistFatal`（数据库持久化失败，必须向上抛避免静默丢数据）都会转成 `{ error, type: 'error' }` 事件而不是让整条 operation 崩溃（`tool.ts:568-579, 706-713`）。真正返回给模型上下文的错误内容经过 `classifyToolError`/`normalizeExecutionError`（`apps/server/src/services/toolExecution/index.ts:35-64`）规范化为 `{ code, kind, message }`，**不包含原始堆栈**（`error instanceof Error` 分支只取 `error.message`/`error.name`，不序列化 `error.stack`，`index.ts:41-46`）。

### 5.6 headless 场景下无法等待人工的返回形态

`userInterventionConfig.approvalMode === 'headless'` 时（后台任务/API 无 UI 场景，`apps/server/src/services/aiAgent/index.ts:1174` 默认就是 `{ approvalMode: 'headless' }`），`GeneralChatAgent`（`llm_result` phase）不会发 `request_human_approve`，而是发 `resolve_blocked_tools`（`GeneralChatAgent.ts:551-558`）。这个指令由 `resolveBlockedTools` 执行器（`packages/agent-runtime/src/executors/resolveTools.ts:78-173`）处理：把每个待批准工具直接标记为失败结果 `{ content: 'Blocked by security/privacy.', error: 'blocked_by_security_privacy', success: false }`，`pluginIntervention: { status: 'rejected', rejectedReason: 'blocked_by_security_privacy' }`，然后照常进入 `tools_batch_result` 让模型看到"这个工具被拒绝"并有机会重新规划——而不是让整个 operation 挂起等待一个不存在的人工响应。headless 下真正会被拒绝的只是"需要人工介入"的那部分工具（`toolsNeedingIntervention`），对 `dynamicPolicy`/全局审计中标记为可覆盖（非 `always`）的规则是**自动放行**而非拒绝（`GeneralChatAgent.ts:200-204, 211-215, 229-234`）——headless 不是"全部工具都拒绝"，而是"能自动放行的照常放行，必须人工的转为拒绝结果"。

**依据**：[AgentRuntime.step](../../lobehub/packages/agent-runtime/src/core/runtime.ts)、[GeneralChatAgent.toLLMCall/forceFinish](../../lobehub/packages/agent-runtime/src/agents/GeneralChatAgent.ts)、[ToolResolver 的 deactivatedToolIds](../../lobehub/packages/context-engine/src/engine/tools/ToolResolver.ts)、[AgentRuntimeService 默认 maxSteps](../../lobehub/apps/server/src/services/agentRuntime/AgentRuntimeService.ts)、[resolveToolTimeout](../../lobehub/apps/server/src/modules/AgentRuntime/resolveToolTimeout.ts)、[call_tool/call_tools_batch 执行器](../../lobehub/packages/agent-runtime/src/executors/tool.ts)、[resolve_blocked_tools/resolve_aborted_tools](../../lobehub/packages/agent-runtime/src/executors/resolveTools.ts)、[callLlm 重试与中断检测](../../lobehub/packages/agent-runtime/src/executors/callLlm.ts)、[errorClassification 与 normalizeExecutionError](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[execAgent headless 默认值](../../lobehub/apps/server/src/services/aiAgent/index.ts)。

## 6. 审批与策略（重点）

### 6.1 API 级与 manifest 级 `humanIntervention` 合并规则

`GeneralChatAgent.getToolInterventionConfig`（`packages/agent-runtime/src/agents/GeneralChatAgent.ts:62-76`）：

```ts
const api = manifest.api?.find((a) => a.name === apiName);
return api?.humanIntervention ?? manifest.humanIntervention;
```

api 级配置存在则**完全覆盖** manifest 级（不是合并/叠加，是二选一，取第一个非空）。若某个 api 没声明 `humanIntervention`，才落到 manifest 级默认（`BuiltinToolManifest.humanIntervention`，默认 `'never'`，字段注释见 `packages/types/src/tool/builtin.ts:250-252`）。

`HumanInterventionConfig` 有三种形态：简单策略字符串（`'never'|'required'|'always'`）、参数级规则数组（`HumanInterventionRule[]`，按 `match` 字段值匹配后取对应 `policy`，第一条匹配即返回，未匹配任何规则时**默认返回 `'required'`**——`InterventionChecker.shouldIntervene`，`packages/agent-runtime/src/core/InterventionChecker.ts:86-93`）、动态解析器（`{ dynamic: { type, policy?, default? } }`，`type` 是注册在 `GeneralChatAgent.dynamicInterventionAudits`/`packages/builtin-tools/src/dynamicInterventionAudits.ts` 里的 resolver key，目前唯一注册的是 `pathScopeAudit`）。

### 6.2 九阶段判定管道（不是简单"合并"）

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

- `manual`（默认）：仅工具自身 `humanIntervention` 配置决定，命中 `'never'` 放行，其余（`'required'`/`'always'`/规则未匹配的默认 `'required'`）都要求介入
- `allow-list`：忽略工具自身配置（除 `always`/全局审计仍然生效），只看 `"identifier/apiName"` 是否在用户白名单
- `auto-run`：全部放行，除了 `always`（工具级或全局审计）不可绕过
- `headless`：全部自动执行，`always` 命中的工具**不是拒绝执行，也不是等待**，而是转成 `resolve_blocked_tools` 的**失败结果**返回给模型（"security blacklist tools are skipped (not blocked)" —— `packages/types/src/tool/intervention.ts:141-142` 的类型注释原话，但代码实际行为是返回 `success:false` 的拒绝结果而非静默跳过，见 `resolveTools.ts:99-105`；这里类型注释与实现的措辞略有出入，注释说 "skipped"，实现是显式拒绝并把拒绝原因回传模型）

### 6.4 `always` 不可绕过的实现点

两处代码是 `always` 语义的最终防线：

1. `matchesAlwaysPolicy`（`GeneralChatAgent.ts:86-109`）在 `auto-run`/`headless` 判断**之前**执行（阶段 5 在阶段 6/7 之前），确保无论用户设的模式多宽松，`always` 都先被拦下。
2. 全局安全审计的 `always` 检查（阶段 1，`GeneralChatAgent.ts:181-184`）比 dynamic resolver、headless 特判都靠前，且没有任何 `approvalMode` 分支能跳过它。

对应到用户可见文档语义：`HumanInterventionPolicy` 类型注释——`'always'` = "Always need intervention (cannot be bypassed by auto-run mode)"（`packages/types/src/tool/intervention.ts:9`）。

### 6.5 未知 manifest 的强制审批

见 6.2 阶段 8。触发条件是 `state.toolManifestMap[identifier]` 查不到——例如工具的 manifest 因为过滤/裁剪没有出现在当前 turn 的 map 里，但模型仍然吐出了对应的 `identifier/apiName`（可能是历史遗留、模型幻觉，或者理论上的"注入绕过"尝试）。此时 manual/allow-list 模式强制要求人工介入，而不是静默执行或静默丢弃。

### 6.6 全局安全审计与动态规则的注入点

- `createDefaultGlobalAudits()`（`packages/agent-runtime/src/audit/globalAudit.ts:5-8`）默认注册两条：`createSecurityBlacklistGlobalAudit()`（`policy` 缺省即 `'always'`）和 `createSecurityBlacklistGlobalAudit('required')`。两者共享同一份 `DEFAULT_SECURITY_BLACKLIST`（27 条规则，`packages/agent-runtime/src/audit/defaultSecurityBlacklist.ts:12-359`），差异只是 `policy`，暗示黑名单里部分规则用 `always`、部分用 `required`（规则自身可通过 `policy: 'required'` 字段覆盖默认的 `always`，见文件里多条 `policy: 'required'` 的规则，如 `.env`/SSH 私钥/AWS 凭证/`.npmrc` 等敏感信息读取类）。
- 黑名单规则按 `command`/`path` 等参数字段做正则匹配（`ArgumentMatcher`），覆盖：删除家目录/根目录、fork bomb、`dd`/`mkfs` 写磁盘、关闭防火墙、改 sshd_config、卸载系统包、内核参数、`chown -R` 系统目录、SUID shell、读取 `.env`/SSH 私钥/AWS/Docker/K8s/Git/npm 凭证/history 文件/浏览器凭证/GCP 凭证等。
- 动态规则（dynamic audit）注入点是 `GeneralAgentConfig.dynamicInterventionAudits`（构造 `GeneralChatAgent` 时传入的 map），当前唯一实现是 `pathScopeAudit`（维度 4.3），注册表在 `packages/builtin-tools/src/dynamicInterventionAudits.ts:4-6`。
- 前端还有一层**纯展示性**的黑名单提示：`SecurityBlacklistWarning.tsx`（`src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/SecurityBlacklistWarning.tsx:10-18`）在审批卡片上调用同一个 `InterventionChecker.checkSecurityBlacklist` 给用户看警告文案，但这只是 UI 提示，真正拦截逻辑仍在服务端/`agent-runtime`。

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

`pluginIntervention.status` 枚举：`'pending'|'approved'|'rejected'|'aborted'|'none'`（`packages/types/src/message/common/tools.ts:7-9`）。这个字段持久化在 `messagePlugins.intervention` 数据库列（`packages/types/src/message/db/item.ts:49`），意味着即使进程重启/serverless 冷启动，`waiting_for_human` 状态可以从数据库恢复——`GeneralChatAgent.getCurrentTurnPendingToolMessages`（`GeneralChatAgent.ts:341-359`）专门处理"重新水化后 pending 行还留着"的场景，且明确把扫描范围限制在**当前轮**（最近一条带 `tool_calls` 的 assistant 消息之后），防止历史遗留的 pending 行（用户从未点击过 approve/reject 就离开）劫持后续所有轮次。

approve 与 reject 走两个不同的 `nextContext.phase`（`human_approved_tool` vs `user_input`）；reject 有 `rejectAndContinue`（继续等其他 pending 工具）和 `rejectAndHalt`（整个操作进入不可恢复的 `interrupted`）两种子路径，由前端调用时传的 `rejectAndContinue` 布尔值决定（`HumanInterventionHandler.ts:47,154-158`）。

**依据**：[GeneralChatAgent.checkInterventionNeeded](../../lobehub/packages/agent-runtime/src/agents/GeneralChatAgent.ts)、[InterventionChecker](../../lobehub/packages/agent-runtime/src/core/InterventionChecker.ts)、[globalAudit](../../lobehub/packages/agent-runtime/src/audit/globalAudit.ts)、[defaultSecurityBlacklist](../../lobehub/packages/agent-runtime/src/audit/defaultSecurityBlacklist.ts)、[intervention 类型](../../lobehub/packages/types/src/tool/intervention.ts)、[humanApprove executor](../../lobehub/packages/agent-runtime/src/executors/humanApprove.ts)、[HumanInterventionHandler](../../lobehub/apps/server/src/services/agentRuntime/HumanInterventionHandler.ts)、[ToolIntervention 类型](../../lobehub/packages/types/src/message/common/tools.ts)、[SecurityBlacklistWarning UI](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/SecurityBlacklistWarning.tsx)、[dynamicInterventionAudits 注册表](../../lobehub/packages/builtin-tools/src/dynamicInterventionAudits.ts)。

## 7. 执行位置与隔离

### 7.1 执行方分派条件

`ToolExecutionService.executeTool`（`apps/server/src/services/toolExecution/index.ts:75-172`）按 `payload.type` 分派：`'mcp'` → `executeMCPTool`，其余（含 `'builtin'`）→ `builtinToolsExecutor.execute`。这是**类型级**分派；真正的"执行在哪台机器上"由 `executeMCPTool` 内部再细分（`index.ts:174-262`）：

1. `mcpParams.type === 'cloud'` → `executeCloudMCPTool` → `DiscoverService.callCloudMcpEndpoint`（market/discover gateway，`index.ts:219-220, 330-345`）
2. `mcpParams.type === 'stdio' && deviceGateway.isConfigured && context.activeDeviceId && context.userId` → `executeMcpViaDevice`（转发到用户设备，`index.ts:228-235, 270-318`）——**这是唯一的判定条件**：网关配置了 + 有一个当前活跃设备 ID + 有 userId，三者同时满足才转发到设备；不满足则退回下一步
3. 其余（stdio 无设备网关、或 http/sse）→ `this.mcpService.callTool`（本地/服务器进程内 MCP client，`index.ts:238-242`）——服务器自身直接 spawn stdio 子进程或发 HTTP/SSE 请求

builtin 工具的 `client`/`server` 执行位置由 manifest 的 `executors?: ('client'|'server')[]` 声明（`packages/types/src/tool/builtin.ts:240-244`）：省略时默认只支持 server 端执行；声明 `'client'` 的工具（如 `lobe-local-system`，`packages/builtin-tool-local-system/src/manifest.ts:7`）可以在桌面 Electron 内置运行时里就地执行,不需要经过设备网关——这条路径只用于**无设备网关的独立 Electron 构建**（类型注释：`packages/types/src/tool/builtin.ts:236-238`，"Used only by standalone builds without a device-gateway. Deployments with DEVICE_GATEWAY route the same tools through the device-gateway proxy instead"）。

### 7.2 设备是否"在线"与是否"被路由"的判定

服务端工具引擎判断 `local-system`/`browser` 是否注入模型的条件里包含 `deviceContext.deviceOnline && deviceContext.autoActivated`（`apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:268-273, 276-280`）；而具体某次调用会不会真的转发到某台设备，由 `resolveExecutionPlan`（`src/helpers/executionTarget.ts:378-469`）在 run 开始时**一次性**决定，产出 `ExecutionPlan.kind`：`'device'`（已路由到 `deviceId`）/`'device-unrouted'`（设备能力上但没有可路由设备，原因见 `ExecutionPlanUnroutedReason`）/`'sandbox'`/`'none'`。`auto` 模式只有恰好一台设备在线时才自动路由，多台在线则保持 unrouted 等模型通过 `remote-device` 工具主动选择（`executionTarget.ts:455-464`）。

设备池范围与 bot 场景的访问方防线：

- `RemoteDeviceExecutionRuntime.queryDeviceList` 只枚举当前 `userId` 的个人设备池 ∪ 当前 workspace 的共享设备池（`apps/server/src/services/toolExecution/serverRuntimes/remoteDevice.ts:26-58`），不能跨用户/跨工作区枚举或激活他人设备——`activateDevice` 以及后续 `local-system`/`browser` 调用被限定在同一账户/工作区成员范围内。
- `resolveDeviceAccessPolicy`（`apps/server/src/services/aiAgent/deviceAccessPolicy.ts:78-108`）在 bot 场景只允许 `isOwner`/`bot-personal-platform` 使用设备工具，外部发送者（`bot-external-sender`）被拒绝；若某平台 webhook 未能解析出 `senderExternalUserId`，会落到 `bot-owner-not-configured` 分支同样拒绝，属 fail-closed 设计（各平台 webhook 的该字段解析本次未逐一验证）。

### 7.3 connector 逐工具权限二次检查（`disabled` 的强制点）

`getConnectorToolPermission`（`src/libs/mcp/connectorPermissionCheck.ts:23-44`）查 `ConnectorModel.resolveByIdentifiers([identifier], agentId)` 找到 connector 行，再查 `ConnectorToolModel.queryByConnector` 按 `toolName` 找权限值。`ToolExecutionService.executeTool` 在**分派到任何执行分支之前**（`index.ts:89-104`，"Check before any execution so that disabled tools are blocked universally"）先做这个检查：`permission === ConnectorToolPermission.disabled` → 立即返回 `buildBlockedToolResponse(apiName)`（`connectorPermissionCheck.ts:47-60`），内容是提示用户"该工具已被禁用，可在 Settings > Connectors 重新开启"，**success: true**（不是错误，是一个正常的、内容为拒绝说明的工具结果，模型会读到但不会触发错误重试逻辑）。这一道检查覆盖 **所有** 执行路径——注释明确写"covers ALL paths + qstash: Lobehub market skills, Composio, MCP connectors, and execAgent/qstash alike"（`index.ts:83-88`），查询失败（DB 异常）时 `getConnectorToolPermission` 捕获异常返回 `null`（`connectorPermissionCheck.ts:41-43`，"never block execution due to DB error"）——即数据库故障时**默认放行**而不是默认拒绝，这是一个显式的可用性优先设计取舍。

### 7.4 桌面 MCP client 的隔离程度

已委托后台子调查代理核实 `apps/desktop/src/main/libs/mcp/client.ts` 的 stdio/Streamable HTTP transport 细节和是否有沙箱隔离,结论见维度 10。

**依据**：[ToolExecutionService](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[connectorPermissionCheck](../../lobehub/src/libs/mcp/connectorPermissionCheck.ts)、[executionTarget.resolveExecutionPlan](../../lobehub/src/helpers/executionTarget.ts)、[AgentToolsEngine 设备门](../../lobehub/apps/server/src/modules/Mecha/AgentToolsEngine/index.ts)、[builtin executors 字段](../../lobehub/packages/types/src/tool/builtin.ts)、[local-system manifest 的 client executor](../../lobehub/packages/builtin-tool-local-system/src/manifest.ts)、[remoteDevice 执行体](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/remoteDevice.ts)、[deviceAccessPolicy](../../lobehub/apps/server/src/services/aiAgent/deviceAccessPolicy.ts)。

## 8. 结果处理与回注

### 8.1 结果截断的配置与默认值

结果截断由 `truncateToolResult` 统一处理（`apps/server/src/utils/truncateToolResult.ts:26-50`），默认上限为 25,000 字符。每个 agent 可通过 chat 配置覆盖上限；实现还会处理 UTF-16 代理对边界，避免截断 emoji 后生成非法转义（默认值与边界处理见同一文件）。上下文也可以整体跳过截断（服务端调用点见 `apps/server/src/services/toolExecution/index.ts:127-129,166`）。归档读取工具在 `ARCHIVE_BYPASS_IDENTIFIERS` 中列为例外，结果永不截断。

### 8.2 截断后的标记

截断后会在内容尾部追加明确提示（`truncateToolResult.ts:47`）：

```text
[Content truncated: {N} characters omitted to prevent context overflow. Original length: {M} characters]
```

模型能读到"内容被截断，原文多长，截了多少"，不会被误导为内容已完整。

### 8.3 错误/受阻/拒绝的结果形态

三种非成功结果在类型上大体同构，但触发路径和下游处理不同：

- **执行错误**：返回带 code、kind、message 的失败对象，经 `normalizeExecutionError`（`apps/server/src/services/toolExecution/index.ts:35-64`）规整；kind 决定后续是重试、重新规划还是终止（维度 5.5）。
- **审批拒绝**（用户主动 reject）：`content: 'User reject this tool calling with reason: ...'`，`pluginIntervention.status:'rejected'`（`HumanInterventionHandler.ts:133-140`）——这条走的是**普通工具结果**通道，不是 error，模型看到的是一段说明用户拒绝原因的文本
- **策略/安全阻断**（headless 下命中全局 always 审计，或其他强制规则）：返回失败的 blocked 结果，并在消息中持久化 rejected 状态和阻断原因（`packages/agent-runtime/src/executors/resolveTools.ts:99-105,130-133`）。
- **connector 禁用**：`buildBlockedToolResponse`（`src/libs/mcp/connectorPermissionCheck.ts:47-60`）返回 `success: true`（不是失败，是一个正常完成的"提示用户已禁用"的结果）
- **用户取消（abort）**：结果正文说明由用户中止，消息状态记为 aborted（`resolveTools.ts:212-217`）。

### 8.4 能否污染上下文

所有工具结果最终都以 tool 消息进入消息状态，并随下一次模型调用带入上下文；模型需要知道工具调用发生了什么，包括拒绝本身。潜在的“污染”风险点：

1. `content` 字段直接来自工具执行结果或 MCP 返回值，**没有观察到通用的输出内容安全过滤/脱敏层**（例如没有统一扫描工具结果里是否混入了 prompt injection 载荷，或工具结果本身携带的敏感数据）。截断只解决"过长"，不解决"内容本身是否可信"。
2. 持久化清洗逻辑（`callLlmFinalizer.ts:104-124`）只处理模型发出的工具调用参数，与工具返回内容无关。
3. MCP 和自定义插件返回的内容会作为普通工具文本回注模型，未观察到统一的输出安全过滤或注入检测层。截断逻辑只限制长度；部分工具的 systemRole 文案会提醒模型工具结果中的指令不可信，但覆盖率本次未逐一确认。

**依据**：[truncateToolResult](../../lobehub/apps/server/src/utils/truncateToolResult.ts)、[ToolExecutionService 截断调用点](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[HumanInterventionHandler.reject](../../lobehub/apps/server/src/services/agentRuntime/HumanInterventionHandler.ts)、[resolveBlockedTools/resolveAbortedTools](../../lobehub/packages/agent-runtime/src/executors/resolveTools.ts)、[buildBlockedToolResponse](../../lobehub/src/libs/mcp/connectorPermissionCheck.ts)、[callLlmFinalizer 的 sanitize](../../lobehub/packages/agent-runtime/src/executors/callLlmFinalizer.ts)。

## 9. 内建工具完整清单

以下清单以 `packages/builtin-tools/src/index.ts:163-387` 注册表为准；审批列按各工具 manifest 声明填写，省略时默认 never，执行位置则结合服务端运行时文件和 executors 字段判断：

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
| `lobe-image-generation` | 图像生成 | 未核实 | server | `chatModeAllowedToolIds`,`hidden` | chat mode 下必须 pinned 才注入（`bb406736f`），不做模型无原生 imageOutput 时的自动兜底 |
| `lobe-goal` | `createGoal`（创建并立即启动带可编辑验收计划的目标任务，**只允许 /goal 前缀触发**） | **`'always'`**（`packages/builtin-tool-goal/src/manifest.ts:13`） | server | 非 hidden（注册表项） | 创建/启动目标循环任务；`humanIntervention: 'always'` 保证创建必须人工确认，且仅在 `/goal` 命令注入（`conversationLifecycle.ts:323-328`），模型不能自行触发 |
| `lobe-page-agent` | 页面级子代理 | 未核实 | server | `hidden`,`discoverable:false` | 内部编辑器场景 |
| `lobe-agent-builder`/`lobe-group-agent-builder` | Agent/Group 成员 CRUD | 未核实 | server（`agentBuilder.ts`）；group-agent-builder **无 server runtime**（`packages/builtin-tools/src/index.ts:129-134` 注释明确） | `hidden`,`discoverable:false` | 创建/修改 Agent 配置本身 |
| `lobe-group-management` | `speak`/`broadcast`/`executeAgentTask`/`executeAgentTasks`/`vote` | `executeAgentTask`/`executeAgentTasks` = `'required'`（`packages/builtin-tool-group-management/src/manifest.ts:91,135`）；`speak`/`broadcast`/`vote` 未声明→`'never'` | server | `groupSupervisorToolIds`,非 hidden | 群组编排调度，`broadcast` 零审批且并发无上限（维度 11） |
| `lobe-agent-management` | Agent 管理（含 `callAgent`，30 分钟默认超时见 `agentManagement.ts:85`） | 未核实 | server | 非 hidden,`hidden`（依代码为 `hidden:true`） | 触发其他 Agent 执行 |
| `lobe-calculator` | 计算 | 未核实 | server | 非 hidden | 低风险 |
| `lobe-message` | `sendMessage`/`sendDirectMessage`/`createBot`/`updateBot`/`deleteBot`/`uninstallMessenger`/... | **全部 api 均未声明 humanIntervention → 默认 `'never'`**（`packages/builtin-tool-message/src/manifest.ts` 全文无 `humanIntervention` 字段） | server（`serverRuntimes/message/`） | `isBotConversation` 时注入,非 hidden | **零审批**下可 `updateBot`（改写 `allowFrom`/`dmPolicy`）、`uninstallMessenger`（断开工作区级 bot） |
| `lobe-remote-device` | `listOnlineDevices`/`activateDevice` | **manifest 级显式 `'never'`**（`packages/builtin-tool-remote-device/src/manifest.ts:33`） | server | `runtimeManagedToolIds`,`hidden` | 激活设备后打开 `local-system`/`browser` 的入口，本身零审批 |
| `lobe-topic-reference` | 话题引用 | 未核实 | server | `discoverable:false`,`hidden` | 低风险 |
| `lobe-web-onboarding` | 引导流程 | 未核实 | server | `discoverable:false`,`hidden` | 低风险 |
| `lobe-user-interaction` | `askUserQuestion` 等 | `always`（复用于 `lobe-agent.askUserQuestion`，`packages/builtin-tool-lobe-agent/src/manifest.ts:189`） | server | `discoverable:false`,`hidden` | 交互式提问，本身低风险 |
| `lobe-task` | `createTask(s)`/`listTasks`/`viewTask`/`editTask`/`runTask`/`runTasks`/`setTaskSchedule`/`setTaskVerify`/`updateTaskStatus`/`deleteTask`/评论类 | 未核实每条，`runTasks` **顺序执行**（manifest 描述："Each task is started sequentially in array order"，`packages/builtin-tool-task/src/manifest.ts:298-299`） | server（另有独立 server runtime `serverRuntimes/task.ts`（+107 行）与 client executor `builtin-tool-task/src/client/executor/index.ts`（+118 行），任务工具带客户端执行面） | `defaultToolIds`,非 hidden | 可配置 cron/heartbeat 定时任务（`setTaskSchedule`）；任务回调投递串行化（`51e24a0e9`）、creator 回调持久化（`975e21cf8`） |
| `lobe-brief` | 摘要生成 | 未核实 | server | `discoverable:false`,`hidden` | 低风险 |
| `lobe-agent`(`LobeAgentManifest`) | `analyzeVisualMedia`/`createPlan`/`updatePlan`/`createTodos`/`updateTodos`/`clearTodos`/`askUserQuestion`/`callSubAgent` | `createPlan`/`createTodos`/`clearTodos`=`'required'`；`askUserQuestion`=`'always'`；`updatePlan`/`updateTodos`/`analyzeVisualMedia`/`callSubAgent`=未声明→`'never'`（`packages/builtin-tool-lobe-agent/src/manifest.ts` 各处） | server | `defaultToolIds`,`alwaysOnToolIds`,`runtimeManagedToolIds`,`hidden` | `callSubAgent` **零审批**即可派生新的独立 Agent 执行（维度 11） |
| `lobe-delivery-checker` | 交付检查 | 未核实 | server | 非 hidden | 低风险 |

**未核实项说明**：表中标注"未核实"的条目，是本次调查在时间/篇幅约束下没有逐一打开对应 `packages/builtin-tool-*/src/manifest.ts` 核对每个 api 的 `humanIntervention` 字段；已给出的 `'never'`/`'required'`/`'always'` 判定均逐条读取了源码文件并给出行号，可直接复核。`lobe-skills`/`lobe-skill-store`/`lobe-knowledge-base`/`lobe-memory`/`lobe-image-generation` 等因体量较大列入后续调查缺口（见维度 13）。

**依据**：[builtin registry](../../lobehub/packages/builtin-tools/src/index.ts)、[browser manifest](../../lobehub/packages/builtin-tool-browser/src/manifest.ts)、[local-system manifest](../../lobehub/packages/builtin-tool-local-system/src/manifest.ts)、[web-browsing manifest](../../lobehub/packages/builtin-tool-web-browsing/src/manifest.ts)、[cloud-sandbox manifest](../../lobehub/packages/builtin-tool-cloud-sandbox/src/manifest.ts)、[creds manifest](../../lobehub/packages/builtin-tool-creds/src/manifest.ts)、[message manifest](../../lobehub/packages/builtin-tool-message/src/manifest.ts)、[remote-device manifest](../../lobehub/packages/builtin-tool-remote-device/src/manifest.ts)、[group-management manifest](../../lobehub/packages/builtin-tool-group-management/src/manifest.ts)、[lobe-agent manifest](../../lobehub/packages/builtin-tool-lobe-agent/src/manifest.ts)、[task manifest](../../lobehub/packages/builtin-tool-task/src/manifest.ts)、[agentManagement 服务端超时](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/agentManagement.ts)、[truncateToolResult 的归档白名单](../../lobehub/apps/server/src/utils/truncateToolResult.ts)。

## 10. 扩展机制

### 10.1 自定义插件（OpenAPI/simple）现状

类型层仍保留 `CustomPluginParams.apiMode?: 'openapi' | 'simple'`（`packages/types/src/tool/plugin.ts:14`），但独立的自定义插件直连执行路径已被 connector 体系取代。迁移逻辑把旧 customPlugin 转成标准 connector，之后统一走 MCP connector 链路（`src/features/Connectors/CustomConnectorModal/legacyPluginMigration.ts:47-131`）。当前服务端工具执行目录未找到直接请求用户 API endpoint 的旧路径；PluginService 只负责安装、卸载和 manifest 更新（`src/services/plugin/index.ts:14-44`）。**结论（已确认）**：旧版 simple/OpenAPI 插件不再是一等执行路径。

### 10.2 MCP 三种 transport

`CustomPluginParams.mcp`（`packages/types/src/tool/plugin.ts:39-56`）声明三种 transport：http、stdio 和 cloud，并分别携带 URL、进程参数或云端点；认证支持 none、bearer 和 oauth2。

桌面端 MCP client（`apps/desktop/src/main/libs/mcp/client.ts:29-85`）使用官方 SDK：

- http transport 使用可流式 HTTP 传输，并把 bearer/oauth2 凭据放入 Authorization 请求头（`client.ts:43-51`）。
- stdio transport 将环境变量传给子进程并捕获 stderr；这是一个真实的本机子进程，未观察到额外沙箱或权限降级（`client.ts:61-96`）。
- 工具调用超时读取环境变量 `MCP_TOOL_TIMEOUT`，未见统一上限；服务端则有独立的强制区间（`client.ts:178`，服务端见维度 5.3）。

**结论（已确认）**：桌面 MCP client 对 stdio server **没有沙箱隔离**——它是官方 SDK 的直接子进程 spawn，风险等同于用户自己在终端里跑这个命令；http/streamable transport 也没有额外的出站过滤。

### 10.3 OAuth/bearer 存储与使用范围

connector 凭据表（`packages/database/src/schemas/connector.ts:59-74, 159-234`）：`credentials` 列存 AES-GCM 加密的 blob（经 `KeyVaultsGateKeeper`，与 `messengerInstallations` 同一套加密机制，注释见 `connector.ts:60-63`），`tokenExpiresAt` 单独提出到明文列供后台刷新任务按索引扫描（`connector.ts:163-164, 234`）。`ConnectorCredentials` 支持 `oauth2`（`accessToken`/`refreshToken`/`idToken`/`registrationAccessToken`）和 `bearer`（`token`）两种形态（`connector.ts:59-74`）。token 的**使用范围**由 `getConnectorToolPermission`/`ConnectorModel.resolveByIdentifiers` 按 `(userId, identifier, workspaceId?, agentId?)` 解析出唯一一行 connector，再传给该 connector 对应的执行运行时（如 MCP client 的 auth header）——**未发现跨 connector 复用同一份 token 的代码路径**，但也未发现对 token 使用范围的运行时二次收窄（例如某个 OAuth scope 是否被下游 API 调用超范围使用，取决于第三方 API 本身的 scope 校验，LobeHub 侧只是转发 token）。

### 10.4 Market/Discover gateway

云端 MCP 调用经 `DiscoverService.callCloudMcpEndpoint`（`apps/server/src/services/toolExecution/index.ts:341-345`），本次调查未深入 `DiscoverService` 内部实现细节（**需要进一步验证**：该 gateway 是否做速率限制、是否对 `apiParams` 做二次校验，还是纯转发）。可确认的是它在 `ToolExecutionService.executeCloudMCPTool`（`index.ts:320-371`）之前已经过 7.3 节的 connector 权限检查和维度 2 的工具注入过滤，即 gateway 本身不是唯一的权限边界，是分层防御的最后一环。

### 10.5 Composio 第三方 connector 信任边界

`CustomPluginParams.composio`（`packages/types/src/tool/plugin.ts:19-31`）记录 `appSlug`/`authConfigId`/`connectedAccountId`/`linkedByUserId`/`redirectUrl`/`status`。`lobe-creds.connectComposioService`（`packages/builtin-tool-creds/src/manifest.ts:12-27`）触发 OAuth 授权第三方服务（Gmail/Google Calendar/Slack 等），**该 api 未声明 `humanIntervention`（默认 `'never'`）**——模型可以在无审批的情况下发起一次第三方账户授权流程（授权本身仍需用户在浏览器完成 OAuth 同意页，但"发起授权请求"这个动作本身不经过 LobeHub 侧审批）。`linkedByUserId` 字段的注释（`plugin.ts:24-28`）说明工作区场景下，其他成员运行时会**代表 owner 账号**调用 Composio（"passed as the Composio `userId` at runtime so a workspace member runs the owner's connection"）——即一个工作区成员可以借助 owner 已连接的 Composio 账户执行操作，信任边界从"谁发起调用"下沉到"谁连接了这个账户"。

### 10.6 桌面 MCP client 隔离程度（兑现维度 7.4 的承诺）

结论已在 10.2 给出：无额外沙箱，等同本机子进程/直接网络请求。

**依据**：[plugin 类型定义](../../lobehub/packages/types/src/tool/plugin.ts)、[legacyPluginMigration](../../lobehub/src/features/Connectors/CustomConnectorModal/legacyPluginMigration.ts)、[PluginService](../../lobehub/src/services/plugin/index.ts)、[桌面 MCPClient](../../lobehub/apps/desktop/src/main/libs/mcp/client.ts)、[connector 数据库 schema](../../lobehub/packages/database/src/schemas/connector.ts)、[ToolExecutionService 的 cloud MCP 分支](../../lobehub/apps/server/src/services/toolExecution/index.ts)、[creds manifest](../../lobehub/packages/builtin-tool-creds/src/manifest.ts)。

## 11. 子 Agent 与任务委派

### 11.1 `callSubAgent` 的调度模型：异步 deferred，不是同步等待

`LobeAgentExecutionRuntime.callSubAgent`（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:151-200`）不会阻塞等待子代理跑完，而是调用 `ctx.subAgent.run({ description, instruction, timeout })` 拿到 `{ started, threadId, subOperationId, toolMessageId }` 后立即返回 `{ deferred: true, success: true, state: { status: 'pending', ... } }`（`lobeAgent.ts:174-199`）。这与 `packages/types/src/tool/builtin.ts` 里 `SubAgentCallbacks.run` 返回 `RunSubAgentResult`（同步结果）的类型注释描述的"直接跑完返回结果"语义不完全一致——**实际服务端实现是 fork 一个独立 async operation，父操作转入 `waiting_for_async_tool`，由完成回调桥接回填 tool message**（`packages/agent-runtime/src/executors/tool.ts` 里 `execution.result.deferred` 分支，`tool.ts:409-417, 636-641`）。若调用失败于"启动阶段"（`started:false`），则**不**走 deferred，直接返回普通失败结果，避免父操作永久卡在等待一个不存在的完成回调（`lobeAgent.ts:180-189` 注释明确说明这个区分的原因）。

### 11.2 嵌套阻断的三层实现

1. **manifest 层**：`resolveLobeAgentManifest`（`packages/builtin-tool-lobe-agent/src/resolveManifest.ts:25-36`）在 `context.isSubAgent === true` 或 `context.scope` 为 `'group'|'group_agent'` 时，从模型可见的 `api[]` 里直接**删除** `callSubAgent`，同时替换 `systemRole` 为不含子代理说明的版本——模型在这些场景下根本看不到这个工具。
2. **执行层防御**：即使 manifest 过滤失效（如历史消息残留的 tool_calls），`callSubAgent` 执行体自己也检查 `ctx.isSubAgent`，命中则返回 `NESTED_SUB_AGENT_NOT_ALLOWED` 错误（`lobeAgent.ts:155-160`）。
3. **runtime 层兜底**：`execSubAgent`/`execSubAgents`（旧版 legacy 调用路径，`packages/agent-runtime/src/executors/subAgent.ts:169-208, 210-254`）在 `state.metadata?.isSubAgent === true` 时直接返回"Sub-agent calls cannot be triggered from within another sub-agent."的结果，不再往下调度。

三层防御的判定依据都是同一个 `isSubAgent` 标记（`BuiltinToolContext.isSubAgent`/`BuiltinToolResolveContext.isSubAgent`，`packages/types/src/tool/builtin.ts:314-315, 596-597`），由父 runtime 在创建子代理运行时上下文时设置——**只信任一个布尔位**，若该标记在某条路径上被遗漏赋值，三层防御中的第 1/3 层会同时失效，只剩第 2 层（执行体自检）兜底。

### 11.3 隔离 Thread 与 `inheritMessages`

`RunSubAgentParams.inheritMessages`（`packages/types/src/tool/builtin.ts:883`）控制子代理是否继承父会话消息，默认 `false`。子代理运行在独立的 isolation thread（`RunSubAgentResult.threadId`），父会话的 `usage`/`totalCost` 等统计通过挂在子代理**首条工具消息的 `pluginState`** 上回传（`packages/types/src/tool/builtin.ts:906-913` 注释："lands on the tool message's pluginState... the parent's usage tray accounts for a sub-agent at all"）。`lobe-agent.callSubAgent` 的 `inheritMessages` 参数在 manifest 中声明（`packages/builtin-tool-lobe-agent/src/manifest.ts:242-246`），但**服务端 `callSubAgent` 执行体的参数解构未见转发这个字段到 `ctx.subAgent.run()` 调用**（`lobeAgent.ts:174-178` 只传了 `description`/`instruction`/`timeout`）——需要进一步验证 `inheritMessages` 是否在其他层（如 `ServerSubAgentTransport`/`execSubAgent` 回调内部）被消费，抑或这是一个 server 路径未实现、只在 client 路径生效的字段。

### 11.4 超时与默认值

- `lobe-agent.callSubAgent`：manifest 描述"Default is 30 minutes"（`packages/builtin-tool-lobe-agent/src/manifest.ts:254-257`），但**实际默认值的 clamp/fallback 代码**在 `callSubAgent`（`lobeAgent.ts:169-178`）里未见 `|| 1_800_000` 式的显式兜底，`timeout` 直接从 `params` 转发；真正的 `1_800_000`（30 分钟）硬编码默认值确认存在于 `lobe-agent-management.callAgent`（`apps/server/src/services/toolExecution/serverRuntimes/agentManagement.ts:85`：`timeout: timeout || 1_800_000`）——即两个不同的子代理调度入口（`lobe-agent.callSubAgent` vs `lobe-agent-management.callAgent`）对"未传超时"的兜底行为可能不一致，**需要进一步验证** `lobe-agent.callSubAgent` 未传 `timeout` 时最终落到哪个默认值。
- 工具调用本身（无论是否 sub-agent）的超时统一走 `resolveToolTimeoutMs`（维度 5.3），clamp 到 `[1_000, 800_000]` ms。

### 11.5 `runInClient`：桌面本机执行 vs 服务端沙箱

`TriggerExecuteTaskParams.runInClient`（`packages/types/src/tool/builtin.ts:788-789`）注释明确："MUST be true when task requires local-system tools. Default is false (server execution)"。这是群组编排 `executeAgentTask` 场景下，选择子任务在**发起用户的桌面客户端本机**执行还是**服务端**执行的显式开关——默认服务端（更安全，无法访问用户本机文件），需要访问本机资源才切到 `runInClient: true`。

### 11.6 并发上限

- `execSubAgents`（批量子代理，legacy 路径）用 `pMap(tasks, executeTask, { concurrency: 15 })`（`packages/agent-runtime/src/executors/subAgent.ts:226-230`）——**硬编码 15**，与维度 5.2 的 `call_tools_batch` 用 `Promise.all` 无并发上限形成对比。
- 群组编排 `broadcast`（`src/store/chat/agents/GroupOrchestration/createGroupOrchestrationExecutors.ts:315-328`）用 `Promise.all(agentIds.map(...))`，**没有并发数上限**——若 `agentIds` 很长（例如群组成员很多），会同时对每个成员发起一次 `executeClientAgent`。

### 11.7 取消（abort）在客户端与服务端的不对称

- **client 路径**：`AgentRuntime.getAbortController()`（维度 5.4）从 operation 里取 `AbortController`，可由 UI 的取消按钮直接 `.abort()`，中断进行中的 fetch/stream。
- **server 路径**：`isOperationInterrupted`（`packages/agent-runtime/src/executors/callLlm.ts:51-62`）是**轮询式**检查——只在每次 LLM 重试前查一次数据库状态，**不能中断一个已经在飞行中、尚未失败/未到重试点的 LLM 调用本身**（即调用发出后，若 provider 一直不返回，取消信号要等到这次调用完成或超时才会被处理）。这是 client（同进程 AbortController 级联）和 server（跨请求边界，只能靠状态轮询）在取消能力上的**结构性差异**，标记为「已确认」（源码明确只在 attempt 之间检查，attempt 内部没有额外中断点）。

### 11.8 `lobe-task` 调度模型

`runTasks` manifest 描述"Each task is started sequentially in array order; failures on individual tasks do not abort the batch"（`packages/builtin-tool-task/src/manifest.ts:298-299`）——即批量任务触发是**顺序**（非并发）启动，与 `execSubAgents`/群组 `broadcast` 的并发模型不同。`setTaskSchedule` 支持 cron（`schedulePattern`+`scheduleTimezone`）和 heartbeat（`heartbeatInterval` 秒）两种自动化模式（`packages/builtin-tool-task/src/manifest.ts:316-320` 一带），但触发这些调度的**后端调度器**（cron worker / heartbeat 轮询进程位置）本次未定位到具体代码，列入维度 13 未验证事项。

**依据**：[lobeAgent.callSubAgent](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts)、[agentManagement.callAgent 默认超时](../../lobehub/apps/server/src/services/toolExecution/serverRuntimes/agentManagement.ts)、[resolveLobeAgentManifest](../../lobehub/packages/builtin-tool-lobe-agent/src/resolveManifest.ts)、[lobe-agent manifest](../../lobehub/packages/builtin-tool-lobe-agent/src/manifest.ts)、[execSubAgent/execSubAgents](../../lobehub/packages/agent-runtime/src/executors/subAgent.ts)、[SubAgentCallbacks/RunSubAgentParams 类型](../../lobehub/packages/types/src/tool/builtin.ts)、[call_tool 的 deferred 处理](../../lobehub/packages/agent-runtime/src/executors/tool.ts)、[群组编排 broadcast 执行器](../../lobehub/src/store/chat/agents/GroupOrchestration/createGroupOrchestrationExecutors.ts)、[callLlm 中断检测](../../lobehub/packages/agent-runtime/src/executors/callLlm.ts)、[task manifest](../../lobehub/packages/builtin-tool-task/src/manifest.ts)。

## 12. 与消息渲染器笔记的交叉点

参考 `LobeHub-消息渲染调查笔记.md` 第 13 节「工具渲染注册表」和第 9 节「AssistantGroup」。两条笔记在"工具调用如何呈现"上的交叉点：

### 12.1 工具调用与审批的呈现路径

工具卡片的展示驱动数据完全来自**数据库/store 里的结构化字段**（`tool.intervention.status`、`tool.result`、`tool.apiName`/`identifier`），不是从模型输出的自然语言/Markdown 文本解析出来的（`src/features/Conversation/Messages/AssistantGroup/Tool/index.tsx:39-49` 直接从 `useConversationStore(dataSelectors.getToolInBlock(...))` 读取结构化 tool 对象）。审批卡片 `Intervention/index.tsx` 同样只读 `intervention`/`result`/`args`（结构化），审批按钮（`ApprovalActions.tsx:150-187`）点击后调用 store action `approveToolCall`/`rejectAndContinueToolCall`，这些 action 直连服务端的 `HumanInterventionHandler`，不经过任何"从消息文本里提取用户意图"的环节。

### 12.2 是否可被模型输出伪造/混淆

消息渲染器笔记第 11 节提到 Markdown 有自定义标签插件系统（`Tool`/`Task`/`Skill`/`Mention` 等），其中 `<tool name="..." label="..." />` 标签（`src/features/Conversation/Markdown/plugins/Tool/index.ts`）只是渲染成一个 `ActionMention` 展示 pill（`Render.tsx:19-24`），**不会**触发真实的工具调用或审批流程——这是纯装饰性标签,用户/模型在文本里写 `<tool>` 标签只是展示一个提及样式的徽章。

结论：**模型无法仅凭文本输出伪造出一个真实的、可被点击批准的工具审批卡片**，因为：

1. 审批卡片渲染依赖 `messagePlugins.intervention.status === 'pending'` 这个数据库字段，该字段只能由服务端 `humanApprove` 执行器写入（`packages/agent-runtime/src/executors/humanApprove.ts:161-173`），模型输出的普通文本内容不会被解析回写这个字段。
2. `Tool`/`Task` markdown 标签只是展示装饰,点击这些标签渲染出的 pill 不会触发 `approveToolCall`。
3. 唯一的潜在混淆点是**视觉钓鱼**：模型可以在普通文本正文里模仿审批卡片的措辞（比如输出"工具已获批准，执行中..."之类文本），欺骗用户以为某个危险操作已经过审批,但这属于内容层面的社会工程,不是绕过审批状态机本身——真实的工具执行结果仍然会依附在结构化的 tool 消息节点上,与被模仿的文本分离显示。这一点在代码层面未发现专门的防混淆机制（比如强制在助手正文和工具卡片之间加视觉分隔提示"以下内容为工具真实执行结果"），标记为**需要进一步验证**（UI 层是否有额外的视觉区分设计,需要设计稿/实际渲染截图确认,不能仅从组件代码判断视觉效果)。

**依据**：[Tool 卡片渲染](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/index.tsx)、[Intervention 卡片](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/index.tsx)、[ApprovalActions](../../lobehub/src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx)、[Tool markdown 标签](../../lobehub/src/features/Conversation/Markdown/plugins/Tool/index.ts)、[Tool markdown Render](../../lobehub/src/features/Conversation/Markdown/plugins/Tool/Render.tsx)、[humanApprove 执行器](../../lobehub/packages/agent-runtime/src/executors/humanApprove.ts)、[消息渲染调查笔记](../消息渲染器/LobeHub-消息渲染调查笔记.md)。

## 13. 未验证事项与后续调查缺口

1. **`callSubAgent` 每调用超时的实际看门狗触发点**：manifest 声称"默认 30 分钟"，但服务端 `callSubAgent` 执行体（`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:169-178`）没有显式的 `|| 1_800_000` 兜底代码，真正的 30 分钟硬编码只在姊妹工具 `lobe-agent-management.callAgent`（`agentManagement.ts:85`）确认存在。`lobe-agent.callSubAgent` 未传 `timeout` 时最终使用哪个值、由谁在何处实现超时踢除（是否是 `ctx.subAgent.run` 内部某个 setTimeout，还是父 operation 的轮询检查），未定位到具体代码。
2. **`context.skipResultTruncation:true` 时结果实际在哪一层被截断**：确认 `ServerToolTransport.ts:220` 对 client-tool dispatch 路径设置 `skipResultTruncation:true`（跳过 `ToolExecutionService` 内的通用截断），但该路径的结果是否在别处（如流式 chunk 层、消息持久化层）另有独立的长度限制，未核实。
3. **`lobe-task` 的 cron/heartbeat 调度后端位置**：`setTaskSchedule` 支持 `schedulePattern`（cron）和 `heartbeatInterval`（秒），但触发这些调度的后台 worker/轮询进程的具体代码位置本次未定位。
4. **`inheritMessages` 参数在服务端 `callSubAgent` 路径是否真的被消费**：`lobeAgent.ts:174-178` 的 `ctx.subAgent.run()` 调用未转发这个字段（见维度 11.3），需要跟踪 `ServerSubAgentTransport`/其上游 `execSubAgent` 回调的完整实现才能确认。
5. **`StreamableHTTPClientTransport`（`@modelcontextprotocol/sdk`）自身是否有内建 SSRF 过滤**：未审查该第三方依赖源码，只确认 LobeHub 没有额外包一层防护（见维度 4.3）。
6. **`lobe-cloud-sandbox` 的网络隔离范围**：沙箱容器是否可以访问公网、是否有独立的出网白名单，未定位到具体沙箱运行时实现代码。
7. **文档与代码不一致（已确认的具体一处）**：`packages/types/src/agent/chatConfig.ts:194-199` 的 `toolResultMaxLength` 字段 JSDoc 写"`@default 6000`"，但同文件 `AgentChatConfigSchema` 的 zod 定义（`chatConfig.ts:298`）实际是 `z.number().default(25000)`——与 `truncateToolResult` 的 `DEFAULT_TOOL_RESULT_MAX_LENGTH = 25_000`（`apps/server/src/utils/truncateToolResult.ts:10`）一致，说明 **JSDoc 注释过期，实际生效值是 25000 不是 6000**。
8. **本笔记维度 9 表格中标注"未核实"的工具**（`lobe-skills`/`lobe-skill-store`/`lobe-skill-maintainer`/`lobe-knowledge-base`/`lobe-memory`/`lobe-image-generation`/`lobe-page-agent`/`lobe-agent-builder`/`lobe-group-agent-builder`/`lobe-agent-management`/`lobe-calculator`/`lobe-topic-reference`/`lobe-web-onboarding`/`lobe-brief`/`lobe-delivery-checker`/agent-signal 系列/`lobe-self-iteration`）：其 `humanIntervention` 逐条取值未在本次调查中逐一打开源码核对，仅确认了它们在 registry 中的存在和大致用途。
9. **connector 权限表 `ConnectorToolPermission` 除 `disabled` 外的其他取值**（如是否存在 `enabled`/`ask` 等中间态）及其与 `humanIntervention` 的叠加关系，未完整核实枚举全集。
10. **Local Sandbox 的围栏强度**：`packages/device-sandbox` 的 SRT 沙箱运行时（进程/网络隔离、writable roots 策略、`srtWinStaging` 的 Windows 安装）未逐项验证；`resolveClientLocalSandbox` 与网关侧 `ToolExecutionContext.localSandbox` 的一致性（`src/helpers/localSandbox.ts:29-35` 注释明确要求两边一致，否则会出现“选了 Local Sandbox 却跑未围栏命令”）未运行验证。
11. **`callSubAgent` 默认超时**：`apps/server/src/services/toolExecution/serverRuntimes/lobeAgent.ts:177-185` 是 `timeout` 直接透传给 `ctx.subAgent.run()`，未见 `|| 1_800_000` 式显式兜底，与 manifest“默认 30 分钟”的出入维持未核实状态。
