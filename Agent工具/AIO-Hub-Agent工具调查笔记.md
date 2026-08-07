# AIO Hub Agent 工具调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-07-30
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 调查方式：只读源码通读（`tool-calling`、`vcp-connector`、各工具 registry、Rust 侧 Tauri command、Tauri capability 配置），并结合 `VCPToolBox` 当前工作树源码核实协议契约；未修改被调查仓库任何文件
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 没有把 Agent 工具系统写成一条只服务于 VCP 的固定管线。`tool-calling` 将工具能力、运行时上下文、审批与执行、模型通信协议拆成不同层：工具通过 `ToolRegistry`/`AgentExtension` 接入，发现与执行层处理统一的内部对象，`ToolCallingProtocol` 再负责把这些对象转换成某种模型可读、可返回的调用表示。**当前产品在模型通信层只注册了 VCP 这一种协议实现，`ToolCallConfig.protocol` 的类型也只有 `"vcp"`，但 VCP 是现阶段落地，不是该架构给工具系统划定的上限。**

核心事实：

1. **工具发现是运行期反射，不是静态清单。** `toolRegistryManager` 收集所有已注册 `ToolRegistry`，`tool-calling/core/discovery.ts` 在生成 Prompt 时才遍历 `getMetadata()`，筛出 `agentCallable === true` 的方法。这意味着"工具列表"随注册表增删实时变化，且**同一 `getMetadata()` 调用会被多处触发**（Prompt 生成、执行器二次校验、VCP 分布式清单生成），没有统一缓存单一来源，一致性依赖各处都读同一份 `toolInstance.getMetadata()`。
2. **模型通信协议有明确的替换边界，目前唯一实现是 VCP。** `ToolCallingProtocol` 只要求实现工具定义生成、使用说明生成、调用请求解析和结果格式化四项能力；工具发现把统一元数据交给协议生成定义，协议解析出的统一请求再进入校验、审批和方法执行。新增协议仍需改动 `SUPPORTED_PROTOCOLS`、`resolveProtocol()` 和 `ToolCallConfig.protocol`，所以这是一处代码级扩展点，尚不是可由插件在运行期注册的协议市场。当前 VCP 解析器会跳过 Markdown code fence/inline code，执行器还会二次核验 `agentCallable`。
3. **工具能力也有多条接入路径。** 内建 registry、动态 `ToolRegistryFactory`、只注入环境信息的 `AgentExtension`、JS/Sidecar/Native 插件代理，以及把远端 manifest 包装成本地 registry 的 `VcpToolProxy`，最后都汇入同一发现和执行链。因而“目前只做了 VCP”准确地说只适用于**模型调用协议实现**，不适用于整个工具来源与扩展体系。
4. **审批状态机是 Promise-based 单例 store，不做持久化。** `useToolCallingStore` 用内存数组 + `resolve` 回调管理待批准请求；应用重启或页面刷新会丢失所有 pending 状态（异步任务另有磁盘持久化，见下）。自动批准的匹配粒度到"工具级"和"方法级"，方法级优先于工具级。
5. **`aio-file-operator` 的路径沙箱是纯前端字符串判断，无 Rust 侧兜底。** `security.ts` 用字符串 `startsWith` 判断白名单/黑名单，且明确"三段式"校验只在 `args.path` 单字段生效；Rust `file_operations.rs` 侧的 `read_text_file_force` / `write_text_file_force` 等命令不做任何路径限制，加上 Tauri capability 里 `fs:allow-*` 全部是 `{"path": "**"}`，说明**唯一的访问边界就是这段 TypeScript 校验**，一旦有其他工具（如 `directory-tree`、`dir-search`、`ffmpeg-tools`）不复用它，就没有沙箱。
6. **VCP 分布式节点是双向对等契约，已与 VCPToolBox 当前源码核实一致。** AIO 既能作为客户端拉取远端 manifest 并代理执行（`VcpToolProxy`），也能作为节点被远端 `execute_tool` 调用本机 `agentCallable`/`distributedExposed` 方法。`internal_request_file` **不是 AIO 内可用的工具**，而是为满足 VCP 分布式契约而实现的入向协议义务：它不在 `toolRegistryManager` 里注册，本机模型无法发现或调用它，只能由已连接的 VCP 主服务器通过 `execute_tool` 触发。它读取 `file://` 路径转 Base64 回传且**没有节点侧路径白名单**，信任边界完全落在"用户连接了哪个主服务器"上。

## 总体调用链

```text
ToolRegistry.getMetadata() (agentCallable 方法) / AgentExtension.getExtraPromptContext()
  -> tool-calling/core/discovery.ts: 发现统一的工具元数据 / 动态上下文
  -> ToolCallingProtocol.generateToolDefinitions() / generateUsageInstructions()
       （协议适配层；当前唯一实现为 VcpToolCallingProtocol）
  -> macro-engine: {{tools}} {{tool_usage}} {{tool_context}} 三个宏分别取值
  -> injection-assembler: 拼入 System Prompt（若 3 个宏都缺失且开启 autoInjectIfMacroMissing，则保底插入锚点消息）
  -> LLM 输出（可能含 <<<[TOOL_REQUEST]>>> 文本块）
  -> useToolCallOrchestrator.orchestrate() 每轮迭代:
       -> tool-calling/core/parser.ts -> ToolCallingProtocol.parseToolRequests() 解析为统一请求
       -> tool-calling/core/validator.ts 校验 registry/method/agentCallable（引擎路径）
       -> tool-calling/core/executor.ts:
            prepareRequestContext()  合并参数 + checkSecurityPolicy()
            -> block(死区，直接 denied) / approve(强制审批) / allow
            -> onToolCallPreview() 预览钩子（审批前）
            -> onBeforeExecute() -> toolCallingStore.requestApproval() -> Promise 挂起
            -> approved: withTimeout(method.call(toolInstance, mergedArgs, ToolContext))
            -> rejected: onToolCallDiscarded() 回调 + denied 结果
       -> 异步方法(executionMode==="async") -> taskManager.submitTask() 立即返回 taskId
  -> ToolCallingProtocol.formatToolResults()（当前 VCP 输出为 "[[AIO工具调用结果信息汇总: ...]]"）
  -> 追加为独立 role=tool 消息节点，回注下一轮 LLM 请求
  -> 达到 maxIterations / 全部 denied / isSilent 标记 -> 停止循环

VCP 分布式节点（可选，仅当 Agent 使用的 Profile baseUrl 与 vcp-connector wsUrl 同主机时联动）：
  VCPToolBox execute_tool -> vcpNodeProtocol.handleExecuteTool() -> 复用同一 ToolRegistry 实例 -> tool_result
  VCPToolBox tool_approval_request -> vcpNodeProtocol.handleToolApprovalRequest() -> 同一 toolCallingStore -> tool_approval_response
  AIO VcpBridgeFactory: get_vcp_manifests -> VcpToolProxy（本地包装远端插件为 ToolRegistry）-> execute_vcp_tool -> tool_result
```

## 1. 工具定义与注册

`ToolRegistry` 接口定义在 `../../aio-hub/src/services/types.ts:167`，核心字段：`id`、`getMetadata()`（可选但强烈推荐）、`checkSecurityPolicy?`、`onToolCallPreview?`/`onToolCallDiscarded?`、`settingsSchema?`、`runMode?`。所有工具方法签名统一为 `(args, context?: ToolContext) => Promise<string> | string`（`../../aio-hub/src/tools/tool-calling/ARCHITECTURE.md:507`），参数一律先降级为 `Record<string, string>`（VCP 解析结果），再由方法/actions 层自行转型。

注册路径是 Vite `import.meta.glob("../tools/**/*.registry.ts")`（`../../aio-hub/src/services/auto-register.ts:62`），扫描时机在应用启动 `autoRegisterServices()`；支持三种导出形态：单例对象、类构造函数、数组（多实例，如 `recall.registry.ts` 导出 `[recallBasic, recallAdmin]`，`llm-chat.registry.ts` 导出 `[llmChatMain, agentManagement]`）。工具 ID 冲突在初始化阶段直接 `throw`（`../../aio-hub/src/services/registry.ts:96`），热重载阶段则允许覆盖并打 warning——**这意味着开发环境下插件覆盖生产同名工具不会报错，需要人工关注日志**。

`agentCallable` 判定点有且只有一处语义来源：`MethodMetadata.agentCallable`（`../../aio-hub/src/services/types.ts:46`），但被三处独立读取：
- discovery 生成 Prompt 时（`../../aio-hub/src/tools/tool-calling/core/discovery.ts:242`，`methods.filter((method) => method.agentCallable === true)`）
- executor 执行前二次校验（`../../aio-hub/src/tools/tool-calling/core/executor.ts:314`，`methodMeta?.agentCallable !== true` 直接拒绝）
- validator（引擎路径，`../../aio-hub/src/tools/tool-calling/core/validator.ts:59`，仅在 `agentCallable === false` 时报错，与 executor 的严格 `!== true` 判断口径不完全一致——如果方法没有声明 `agentCallable` 字段（`undefined`），validator 认为合法但 executor 会拒绝执行，是一个潜在的行为不一致点）

方法命名与去重：VCP 协议路由 key 是 `tool_name`（对应 `toolId`）+ `command`（对应方法名，默认取 `method.name`，可通过 `protocolConfig.vcpCommand` 覆盖，`../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts:67`）。执行时 `${toolId}_${methodName}` 拼接为 flat key 用于 `methodToggles`/`autoApproveMethods`（`../../aio-hub/src/tools/tool-calling/core/executor.ts:203`）。**没有跨工具的方法名去重逻辑**——不同 `toolId` 下可以有同名方法，靠 `tool_name` 字段区分，若 LLM 在 VCP 块里漏填 `tool_name` 则回退为 `"unknown_tool"`（`vcp-protocol.ts:226`），随后在 executor `toolRegistryManager.hasTool("unknown_tool")` 必然为 false，返回“工具不存在”错误而不是崩溃。

静态声明 vs 动态生成：绝大多数工具的 `getMetadata()` 是静态硬编码方法列表（如 `directory-tree`、`json-formatter`）；但至少两类工具是**动态生成方法列表**：
- `media-generator`：按当前启用的 LLM Profile/Model 组合，为每个可用模型生成一个 `generate_<sanitized_model_id>` 方法（`../../aio-hub/src/tools/media-generator/services/buildAgentMethods.ts:754`），方法数随用户配置模型数量变化，`bindDynamicHandlers()` 把 handler 挂到 `this` 实例上。
- `skill-manager`（`SkillManagerProxy`，id `skill:system`）：为每个已启用 Skill 生成 `activate_<skillName>` 方法（`../../aio-hub/src/tools/skill-manager/services/SkillManagerProxy.ts:124`），同样是运行时挂载实例方法。
- `vcp-connector` 的 `VcpToolProxy`：为每个远端 VCP 插件命令动态挂载同名方法到实例上（`../../aio-hub/src/tools/vcp-connector/services/VcpToolProxy.ts:89`），且其 `getMetadata()` 里对**所有映射方法强制 `agentCallable: true`**（`VcpToolProxy.ts:119`），意味着远端插件暴露的每个命令天然可被本地 Agent 调用，白名单权在“是否接入该 VCP bridge manifest”，不在方法级。

**依据**：[`services/types.ts`](../../aio-hub/src/services/types.ts)、[`services/registry.ts`](../../aio-hub/src/services/registry.ts)、[`services/auto-register.ts`](../../aio-hub/src/services/auto-register.ts)、[`tool-calling/core/discovery.ts`](../../aio-hub/src/tools/tool-calling/core/discovery.ts)、[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`tool-calling/core/validator.ts`](../../aio-hub/src/tools/tool-calling/core/validator.ts)、[`media-generator/services/buildAgentMethods.ts`](../../aio-hub/src/tools/media-generator/services/buildAgentMethods.ts)、[`skill-manager/services/SkillManagerProxy.ts`](../../aio-hub/src/tools/skill-manager/services/SkillManagerProxy.ts)、[`vcp-connector/services/VcpToolProxy.ts`](../../aio-hub/src/tools/vcp-connector/services/VcpToolProxy.ts)。

## 2. 工具发现与注入

发现服务 `createToolDiscoveryService()`（`../../aio-hub/src/tools/tool-calling/core/discovery.ts:168`）提供 `generatePrompt()`（静态工具定义）和 `getAgentContexts()`（动态运行时上下文），两者刻意分离：

- `{{tools}}` 宏对应 `generatePrompt()`，结果按 `protocol|agentId|stableConfigHash` 做内存缓存（`discovery.ts:294`），命中缓存直接返回字符串。`stableStringifyConfig()` 对 `toolToggles`/`methodToggles`/`autoApproveTools`/`autoApproveMethods`/`overrides` 各自排序后 JSON 序列化作为 hash key，确保配置对象字段顺序不同也能命中同一缓存（`discovery.ts:103`）。
- `{{tool_context}}` 宏对应 `getAgentContexts()`，**不缓存**，每次都 `Promise.all` 并发调用所有已启用工具/扩展的 `getExtraPromptContext()`（`discovery.ts:445`），用 `<context_provider id="toolId">` 包裹拼接。
- `{{tool_usage}}` 宏对应协议使用说明，是静态字符串（`vcp-protocol.ts:314`），无缓存但本身开销可忽略。

三个宏在 `macro-engine/macros/tools.ts` 中注册（priority 分别 95/92/90），实际拼装位置由 Agent 的 preset message 决定；如果三个宏都缺失且 `toolCallConfig.autoInjectIfMacroMissing === true`，`injection-assembler.ts:378` 会在 `chat_history` 锚点之前插入一条固定内容 `"{{tools}}\n{{tool_usage}}\n{{tool_context}}"` 的系统消息兜底注入（`../../aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts:391`）。**没有发现显式的 Prompt Cache（如 Anthropic `cache_control` 或结构化 cache breakpoint）机制**；`{{tools}}` 与 `{{tool_context}}` 分离更多是为了让"工具定义"这部分内容在同一 Agent 配置下字符串完全稳定（利于依赖模型侧/网关侧对相同前缀的隐式缓存），而不是项目自己实现了显式缓存协议层。

过滤/开关的实际生效点集中在 `resolveToolEnabled()`（`discovery.ts:82`，工具级：`toolToggles[toolId]` 优先于 `defaultToolEnabled`）和 `generatePrompt()` 内联的方法级过滤（`discovery.ts:322`，`methodToggles[toolId_methodName] !== false` 才保留）。VCP 分布式的 `includeToolIds` 参数可以**无视** `config.enabled` 强制包含指定工具（`discovery.ts:302-308`），这是给 `vcp-connector` 手动暴露工具用的旁路，正常聊天 Agent 一般不会传这个参数。

**依据**：[`tool-calling/core/discovery.ts`](../../aio-hub/src/tools/tool-calling/core/discovery.ts)、[`llm-chat/macro-engine/macros/tools.ts`](../../aio-hub/src/tools/llm-chat/macro-engine/macros/tools.ts)、[`llm-chat/core/context-processors/injection-assembler.ts`](../../aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts)。

## 3. 协议抽象与当前实现（目前仅 VCP）

`tool-calling/core/protocols/base.ts` 定义的 `ToolCallingProtocol` 是模型通信层与工具执行内核之间的边界：

| 接口方法 | 负责内容 | 是否影响发现/执行语义 |
|---|---|---|
| `generateToolDefinitions()` | 把统一的工具元数据转换成模型可见定义 | 否 |
| `generateUsageInstructions()` | 生成协议使用说明 | 否 |
| `parseToolRequests()` | 把模型输出转换成 `ParsedToolRequest[]` | 只负责表示到内部对象的转换 |
| `formatToolResults()` | 把统一执行结果转换成下一轮上下文 | 否 |

解析后的注册表校验、`agentCallable` 复核、安全策略、人工审批、超时和真实方法调用仍由协议外的 parser/executor/engine 链处理。这使 AIO 可以增加另一种文本协议，同时复用现有工具目录与执行策略。这里的扩展范围也要说准：接口接收 `finalText: string`，工具定义与结果同样返回字符串，因此它目前是**多种文本协议的抽象**；若要直接接入模型 API 的结构化 `tool_calls`，还需扩展该接口及聊天消息编排链，不能视为现成能力。

目前这项扩展只完成了接口和路由骨架：`SUPPORTED_PROTOCOLS` 只有 `vcp`，`useToolCalling.resolveProtocol()` 对任何输入都回退到同一个 `VcpToolCallingProtocol`，`ToolCallConfig.protocol` 也被收窄为 `"vcp"`。因此，下面记录的是**当前 VCP 实现的行为**，不能据此把 AIO 的整体工具架构等同于 VCP。

### 3.1. VCP 文本块语法

协议实现集中在 `../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts`。语法要点：

- 三组标记：`<<<[TOOL_DEFINITION]>>>`/`<<<[END_TOOL_DEFINITION]>>>`（工具定义，注入 Prompt）、`<<<[TOOL_REQUEST]>>>`/`<<<[END_TOOL_REQUEST]>>>`（调用请求）、`<<<[TOOL_REQUEST_ESCAPE]>>>`/`<<<[END_TOOL_REQUEST_ESCAPE]>>>`（块级转义，用于嵌套调用）。
- 参数编码 `key:「始」value「末」`，还支持 `「始ESCAPE」...「末ESCAPE」` 和 `「始exp」...「末exp」` 两种转义变体，解析优先级 `ESCAPE/exp > 标准`（`vcp-protocol.ts:32-36`）：先扫描转义变体并记录匹配区间，再把这些区间在原文中"掏空"（替换为等长空格）后才跑标准正则，避免转义内容里的普通 `「始」「末」` 被二次误匹配（`vcp-protocol.ts:132-141`）。
- 批量调用：`command1`/`path1`、`command2`/`path2`… 数字后缀键会被识别为分组参数，一个 `TOOL_REQUEST` 块拆分为多个 `ParsedToolRequest`（`vcp-protocol.ts:200-268`）。`tool_name`、`request_id` 不参与分组。

**边界情况已确认**：

| 场景 | 行为 | 源码位置 |
|---|---|---|
| Markdown code fence / inline code 包含示例 TOOL_REQUEST | 复合正则 `scanner` 优先匹配 fence/inline code 整体跳过，避免解析伪请求 | `vcp-protocol.ts:356` |
| 嵌套 TOOL_REQUEST（一个请求块内文本又含另一个请求块） | 必须用 `TOOL_REQUEST_ESCAPE` 包裹整个内层块，否则外层 `indexOf(endMarker, ...)` 会在第一个 `END_TOOL_REQUEST` 处截断 | `vcp-protocol.ts:365-368` |
| 参数值本身含 `「始」`/`「末」` | 必须用 `「始ESCAPE」...「末ESCAPE」`包裹该参数值，否则标准正则会把值内的分隔符当作新参数边界 | 协议使用说明第 4 条，`vcp-protocol.ts:339` |
| 流式截断（末尾缺 `END_TOOL_REQUEST`） | `blockEnd === -1` 时记录 warning 并 `break`（整个扫描停止，之后的合法块也不再解析），返回已解析的请求列表，不抛异常 | `vcp-protocol.ts:374-383` |
| 参数缺少闭合 `「末」` | `RE_VCP_PENDING` 捕获未闭合的键值，仍尝试提取到 value，但在 `validation.errors` 里记录“未正确闭合” | `vcp-protocol.ts:166-172` |
| 缺少 `tool_name` 或 `command` | 分别 push 到 `errors`，`validation.isValid = false`；executor 遇到 `!isValid` 直接返回 error 结果，不会真正路由执行 | `vcp-protocol.ts:183-194`、`executor.ts:186-194` |
| 同一轮回复含多个 TOOL_REQUEST 块 | `scanner.lastIndex` 每次成功解析后跳到 `blockEnd + endMarker.length`，循环继续扫描剩余文本，支持多块 | `vcp-protocol.ts:395-397` |
| 值内含反斜杠双写（如 LLM 习惯性 JSON 转义 `\\`） | `sanitizeValue()` 尝试 `JSON.parse` 还原，失败则简单 `replace(/\\\\/g, "\\")` | `vcp-protocol.ts:43-59` |

渲染层（`rich-text-renderer`）里另有一份**独立的 Tokenizer 实现**同样解析 `<<<[TOOL_REQUEST]>>>`（`../../aio-hub/src/tools/rich-text-renderer/parser/Tokenizer.ts:564-685`），用于把工具调用块渲染为 `VcpToolNode` 组件；这份解析逻辑与 `tool-calling` 模块的解析器**代码完全独立、各自维护**（正则、转义处理逐字重复），是可读性/一致性债务点：若未来只改一处的转义规则，两处会产生行为分叉。

**依据**：[`tool-calling/core/protocols/base.ts`](../../aio-hub/src/tools/tool-calling/core/protocols/base.ts)、[`tool-calling/core/discovery.ts`](../../aio-hub/src/tools/tool-calling/core/discovery.ts)、[`tool-calling/composables/useToolCalling.ts`](../../aio-hub/src/tools/tool-calling/composables/useToolCalling.ts)、[`agent-manager/types/agent.ts`](../../aio-hub/src/tools/agent-manager/types/agent.ts)、[`tool-calling/core/protocols/vcp-protocol.ts`](../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts)、[`rich-text-renderer/parser/Tokenizer.ts`](../../aio-hub/src/tools/rich-text-renderer/parser/Tokenizer.ts)。

## 4. 参数校验与规范化

**没有 JSON Schema 校验。** `MethodParameter` 只是文档性的类型/必填声明（`services/types.ts:21`），不接入任何 schema 校验库（无 zod/ajv 依赖痕迹）；executor 唯一做的类型强转是对 `param.type === "boolean"` 和 `param.type === "number"` 两种基础类型的宽松转换（`executor.ts:140-153`，布尔用 `String(val).toLowerCase() === "true"`，数字用 `Number(val)` 并检查 `!isNaN`），其余类型（`string[]`、对象、枚举）**不做任何强制转换或校验**，全靠各工具自己在方法体内解析。

因此各工具普遍自建了参数规范化小工具：
- `../../aio-hub/src/utils/agentArgs.ts` 提供 `parseAgentBoolean()`/`coerceAgentBoolean()`/`normalizeAgentBooleanFields()`，把 LLM 可能传的 `"true"`/`"1"`/`"yes"`/`1`/`true` 等各种写法统一转布尔，被 `ffmpeg-tools`、`directory-janitor`、`recall`、`media-generator`、`aio-file-operator` 等 10+ 工具复用。
- 部分工具在 `getMetadata()` 里给出 `defaultValue`，但 **executor 不会自动把 defaultValue 补进最终参数**（除非工具自己的 `settingsSchema` 有对应 `modelPath`，见下）；如果 LLM 没传该字段，方法体内自己要 `?? defaultValue`。

参数合并优先级由 `prepareRequestContext()` 实现（`executor.ts:125-137`）：
```
mergedArgs = { ...schemaDefaults, ...agentPreset, ...cleanArgs }
```
其中 `schemaDefaults` 来自工具 `settingsSchema` 中带 `defaultValue` 的项（按 `modelPath` 映射，与 `MethodParameter.defaultValue` 是**两套不同的默认值来源**，容易混淆：一个是"UI 配置默认值"，一个是"方法参数文档默认值"，只有前者真正被合并进执行参数）；`agentPreset` 来自 `config.toolSettings[toolId]`（Agent 级预设，UI 上通过 Agent 设置面板配置）；`cleanArgs` 是剔除了 `command` 字段之后的 LLM 实参，优先级最高。

路径/命令类参数的处理：`aio-file-operator` 每个方法都以 `args.path` 为校验入口（`checkSecurityPolicy()` 只读取 `args.path`，ARCHITECTURE.md 中明确写了"如方法有多个路径参数需扩展 checkSecurityPolicy，避免只校验 args.path"——**这是一个已知但未处理的扩展面缺口**：如果未来给 `aio-file-operator` 加"复制/移动"类需要两个路径参数的方法，第二个路径字段不会被沙箱校验）。`ffmpeg-tools`、`skill-manager`（`skill_run_script` 的 `args` 字段直接拼进 shell 命令行参数）等工具的命令类参数**没有 shell 元字符过滤**，依赖 Rust 侧 `tokio::process::Command` 不经过 shell 解释（数组式参数传递，非字符串拼接执行），因此不存在传统的 shell 注入路径，但 `skill_run_script` 的 `args` 是先按引号感知分词再 push 进 `cmd_args` 数组（Rust `skill_manager.rs:556-576`），仍然是"进程参数传入"而非命令字符串拼接执行——可以传任意参数但不能靠分号/管道逃出目标程序本身。

**依据**：[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`utils/agentArgs.ts`](../../aio-hub/src/utils/agentArgs.ts)、[`aio-file-operator/ARCHITECTURE.md`](../../aio-hub/src/tools/aio-file-operator/ARCHITECTURE.md)、[`aio-file-operator/utils/security.ts`](../../aio-hub/src/tools/aio-file-operator/utils/security.ts)、[`skill_manager.rs`](../../aio-hub/src-tauri/src/commands/skill_manager.rs)。

## 5. 编排循环

`useToolCallOrchestrator.orchestrate()`（`../../aio-hub/src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts:70`）是聊天场景下的最外层循环：

- **最大迭代**：`executionAgent.toolCallConfig?.maxIterations ?? 5`（引擎默认 `DEFAULT_TOOL_CALL_CONFIG.maxIterations = 20`，两处默认值不同——orchestrator 的 `?? 5` 只在 `toolCallConfig` 整体缺失时才生效，正常配置下走 Agent 自己保存的 20 或用户自定义值）。循环体 `while (iterationCount < maxIterations)`，每轮先请求 LLM 再检测工具调用，检测到调用后创建新的 assistant 节点继续下一轮（`useToolCallOrchestrator.ts:114,379-417`）。
- **串/并行**：由 `config.parallelExecution` 控制，`true` 则 `Promise.all` 并发跑同一轮所有请求，`false` 则 `for` 循环串行（`executor.ts:503-526`）。审批阶段（`onBeforeExecute` 调用）**总是先并发发起**（`executeToolRequests` 内部先建立 `approvalCache`），执行阶段才区分串并行——这意味着即使 `parallelExecution: false`，同一轮多个请求的**审批 UI 会同时弹出**，只是真正执行时排队。
- **超时**：`config.timeout`（默认 30000ms）通过 `withTimeout()` 包装单次方法调用的 Promise（`executor.ts:51-75`），超时后 `reject`，被 catch 转成 `status: "error"` 结果，不会挂死循环。异步方法（`executionMode: "async"`）不受此超时限制，因为提交后立即返回 taskId，真正执行走 `TaskManager`/`TaskExecutor`，自身没有硬超时（依赖工具内部或用户手动取消）。
- **取消与静默取消**：审批结果三态 `approved`/`rejected`/其他（如未定义视为通过审批流程但不会被认成 rejected）。`rejected` 触发 `onToolCallDiscarded` 回调 + `denied` 结果。**代码搜索未找到 `silent_cancelled` 这个字面值的实际实现**——`tool-calling/ARCHITECTURE.md:323` 文档提到"支持 approved、rejected 和 silent_cancelled"，但 `ToolApprovalResult` 类型只有 `"approved" | "rejected"`（`tool-calling/types/index.ts:50`），`executor.ts` 判断逻辑也只有 `approvalResult === false || approvalResult === "rejected"` 一个分支。**这是文档与代码不一致，已确认为文档过时/描述超前于实现**：当前版本没有独立的"静默取消（不报错）"审批结果类型；真正的"静默"语义是另一个不同的机制——`toolNode.metadata.isSilent`（UI 上的"静默执行"开关，`ToolCallingApprovalBar.vue:39`），它控制的是**工具执行完成后是否继续下一轮迭代**（`isSilent || isAllDenied` 则 `break`，`useToolCallOrchestrator.ts:373`），不是审批阶段的取消状态。
- **流式期间的工具事件**：工具调用检测发生在**单次 LLM 请求完整结束之后**（`responseContent = response.content`，`useToolCallOrchestrator.ts:183`），不是在流式过程中逐 token 解析；因此模型输出到一半时不会触发工具调用，必须等本轮 assistant 消息流式结束。但渲染层（`rich-text-renderer`）会在流式过程中就把未闭合的 `TOOL_REQUEST` 块渲染成"执行中"状态的 `VcpToolNode`（纯 UI 反馈，不代表真实已执行）。
- **速率限制**：`rateLimitEnabled`/`rateLimitInterval` 控制多轮迭代之间的强制等待（`useToolCallOrchestrator.ts:129-157`），按"上一次请求开始"或"上一次流结束"两种基准计算延迟，用于避免 API 速率限制被触发。

**依据**：[`llm-chat/composables/chat/useToolCallOrchestrator.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts)、[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`tool-calling/types/index.ts`](../../aio-hub/src/tools/tool-calling/types/index.ts)、[`agent-manager/types/agent.ts`](../../aio-hub/src/tools/agent-manager/types/agent.ts)、[`llm-chat/components/message-input/ToolCallingApprovalBar.vue`](../../aio-hub/src/tools/llm-chat/components/message-input/ToolCallingApprovalBar.vue)。

## 6. 审批与策略

审批状态机由 `useToolCallingStore`（Pinia，`../../aio-hub/src/tools/llm-chat/stores/toolCallingStore.ts:30`）承担，本质是一个 `pendingRequests: PendingToolRequest[]` 内存数组，每条记录 `{ id, externalId?, sessionId, request, resolve }`。`requestApproval()` 返回一个永不 reject 的 Promise，靠 `approveRequest`/`rejectRequest`/`approveByIds`/`rejectByIds`/`handleExternalResponse` 调用 `resolve()` 才会 settle——**没有超时兜底**：如果用户既不点允许也不点拒绝，且没有关闭应用，这个 Promise 会永久挂起，对应的工具调用永远停在"等待审批"状态，聊天循环也会卡住（`processCycle` 内部 `await options.onBeforeExecute?.(request)` 会一直等）。

自动批准匹配语义（`shouldAutoApprove()`，`executor.ts:415-427`）：
```
isGlobalAuto = config.mode === "auto"
isToolAutoApprove = config.autoApproveTools[toolId] ?? config.defaultAutoApprove
isMethodAutoApprove = config.autoApproveMethods[toolId_methodName] ?? false
return isGlobalAuto && (isMethodAutoApprove || isToolAutoApprove)
```
粒度到方法级，且方法级优先于工具级（方法级为 true 即可绕过工具级 false）；但前提 `mode === "auto"` 是全局总闸，`mode === "manual"` 时无论工具/方法级配置如何都要求人工审批。此外还有 `checkSecurityPolicy()` 返回 `status: "approve"` 的**强制审批**通道（`prepareRequestContext()` 里的 `forceApproval`，`executor.ts:165-168`），这个优先级高于 `shouldAutoApprove()` 的结果（`executor.ts:234`，`forceApproval || !shouldAutoApprove(...)`）——即工具自己声明的安全策略可以覆盖用户的自动批准设置，`aio-file-operator` 的"审批区"规则即用此机制。

持久化位置：`ToolCallConfig`（含 `toolToggles`/`autoApproveTools`/`methodToggles`/`autoApproveMethods`/`overrides`/`toolSettings`）挂在 `ChatAgent.toolCallConfig` 字段上（`../../aio-hub/src/tools/agent-manager/types/agent.ts:537`），随 Agent 配置整体持久化到磁盘（`persistAgent()` -> `saveAgent()`，写入 Agent 目录下的配置文件）。**审批状态本身（pendingRequests）不持久化**，只有异步任务（`AsyncTaskMetadata`）通过 `TaskStore` 写盘（`persistImmediately()`/`persistDebounced()`），应用重启后 `markRunningTasksAsInterrupted()` 会把重启前处于 running/pending 的任务标记为 `interrupted`（`task-manager.ts:461-485`）。

绕过开关：`mode: "auto"` + 对应工具/方法 `autoApproveTools`/`autoApproveMethods` 组合可实现完全无人值守；`aio-file-operator` 的黑名单规则里 `type: "approve"` 明确标注"不被自动批准绕过"（`checkSecurityPolicy()` 返回 `forceApproval`，强制走审批分支，不受 `mode: "auto"` 影响）——但 `type: "block"`（死区）和 `approve`（审批区）都只作用于 `aio-file-operator` 自己，其它工具没有类似的强制策略钩子（`checkSecurityPolicy` 是可选接口，`../../aio-hub/src/tools` 目录里只有 `aio-file-operator` 一处实现）。

无人值守场景：VCP 分布式渠道下（`isVcpChannel === true`），本地 `tool-calling` 编排被跳过（`useToolCallOrchestrator.ts:187`，`if (executionAgent.toolCallConfig?.enabled && !isVcpChannel)`），审批改为走 `vcpNodeProtocol.handleToolApprovalRequest()`（本机作为 VCP 节点被远端调用时）或 VCPToolBox 服务端自己的 `toolApprovalManager`（`approveAll`/`approvalList` 配置，支持 `::SilentReject` 后缀实现"拒绝但不通知 AI"）——**这部分无人值守策略实际发生在 VCPToolBox 侧，不在 AIO Hub 本身**，AIO 只是转发/展示审批 UI。

**依据**：[`llm-chat/stores/toolCallingStore.ts`](../../aio-hub/src/tools/llm-chat/stores/toolCallingStore.ts)、[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`agent-manager/types/agent.ts`](../../aio-hub/src/tools/agent-manager/types/agent.ts)、[`tool-calling/core/async-task/task-manager.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-manager.ts)、[`aio-file-operator/utils/security.ts`](../../aio-hub/src/tools/aio-file-operator/utils/security.ts)、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)、VCPToolBox [`modules/toolApprovalManager.js`](../../VCPToolBox/modules/toolApprovalManager.js)（用于协议核实，未修改）。

## 7. 执行位置与隔离

所有本地工具方法运行在 **Tauri 前端渲染进程（WebView2/JS）**，通过 `@tauri-apps/api/core` 的 `invoke()` 调用 Rust `#[tauri::command]`。没有独立的"后端服务进程"或"沙箱子进程"承担工具执行——`tool-calling` 的 executor/parser/validator 全部是前端 TypeScript。真正跨进程边界发生在具体工具调用 Rust command 时（文件 IO、FFmpeg 子进程、脚本执行）。

- **文件类**：`aio-file-operator` -> `read_text_file_force`/`write_text_file_force`/`delete_file_to_trash` 等（`../../aio-hub/src-tauri/src/commands/file_operations.rs`）。这些 Rust 命令本身**不做路径策略限制**，安全边界完全在前端 `security.ts` 的白名单/黑名单判断（第 4 节、第 9 节表格详述）。
- **子进程类**：`ffmpeg-tools` 的 `process_media` command 用 `tokio::process::Command::new(ffmpeg_path)` + 数组式 `args`（不经过 shell），Windows 下设置 `CREATE_NO_WINDOW` 标志隐藏窗口（`ffmpeg_processor.rs:449-453`）；`skill-manager` 的 `run_skill_script` 同样用 `Command::new` + 引号感知分词的参数数组，`current_dir` 限定在 skill 的 `base_path`，脚本路径校验 `script_path.starts_with(base_path.join("scripts"))` 防止路径穿越到 skill 目录之外（`skill_manager.rs:542-544`）——这是本次调查中**唯一发现的 Rust 侧显式路径穿越防护**。
- **平台差异（Windows）**：`ffmpeg_processor.rs` 用 `#[cfg(target_os = "windows")]` 单独设置 `CREATE_NO_WINDOW`；`skill_manager.rs` 通过 `crate::utils::hide_child_process_window()` 统一隐藏子进程窗口。脚本运行时解析（`resolve_runtime()`）区分 `.ps1`（走 `powershell -File`）、`.sh`/`.bash`（走用户配置的 shell，Windows 上默认仍是 `bash` 字面量，若系统没装会直接 spawn 失败）、`.js`/`.ts`（`bun`优先，否则 `node`）、`.py`（`python`）——**Windows 环境下 `bash`/`sh` 类脚本不保证有可用运行时**，属于已知的平台断层，需用户显式在 `runtimeSettings` 里配置 WSL/Git Bash 路径。
- **`file://`/`appdata://` scheme 解析**：`internal_request_file`（VCP 分布式内置工具）用 `new URL(fileUrl)` 解析后处理 Windows 路径前导斜杠（`vcpNodeProtocol.ts:432-450`），随后直连 Rust `read_file_as_base64`/`get_file_mime_type`（`file_operations.rs:1155-1177`，两者也不做路径限制）。`appdata://` scheme 在 `media-generator`（`toAssetPath()`，`buildAgentMethods.ts:600-603`）等资产路径拼接里使用，最终由 Tauri asset protocol 或应用自己的资产解析服务映射到 `$APPDATA` 下的真实路径；Tauri capability 里 `opener:allow-open-path` 显式限制在 `$APPDATA/**` 与 `$DOWNLOAD/**`（`capabilities/default.json:11-18`），但这只管"用系统程序打开文件"，**不管 `read_file_as_base64`/`invoke` 类命令的读取范围**（这些命令走的是 `fs:allow-read-file` 权限，capability 配置为 `{"path": "**"}`，即无限制）。
- **网络访问范围**：Tauri `http:allow-fetch` 权限允许 `http://**`、`https://**`、`ws://**`、`wss://**`（`capabilities/default.json:79-88`），即**渲染进程可以对任意主机发起 HTTP/WS 请求**，`web-distillery`（网页蒸馏）、`vcp-connector`（WebSocket 到任意配置的 wsUrl）均依赖此权限，没有域名白名单限制在 Tauri capability 层。

**依据**：[`src-tauri/capabilities/default.json`](../../aio-hub/src-tauri/capabilities/default.json)、[`src-tauri/src/commands/file_operations.rs`](../../aio-hub/src-tauri/src/commands/file_operations.rs)、[`src-tauri/src/commands/ffmpeg_processor.rs`](../../aio-hub/src-tauri/src/commands/ffmpeg_processor.rs)、[`src-tauri/src/commands/skill_manager.rs`](../../aio-hub/src-tauri/src/commands/skill_manager.rs)、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)、[`vcp-connector/docs/internal-file-request.md`](../../aio-hub/src/tools/vcp-connector/docs/internal-file-request.md)、[`media-generator/services/buildAgentMethods.ts`](../../aio-hub/src/tools/media-generator/services/buildAgentMethods.ts)。

## 8. 结果处理与回注

结果格式统一为字符串（`ToolExecutionResult.result: string`）。executor 对非字符串返回值自动 `JSON.stringify(data ?? null)`（`executor.ts:387-388`）。三种失败形态：

- `denied`：审批拒绝或安全策略死区拦截，`result` 为固定提示文案（`"工具调用被拒绝：用户未授权"` 或策略自定义的 `blockMessage`）。
- `error`：方法抛异常、超时、工具/方法不存在、`agentCallable` 校验失败，`result` 为异常的 `message` 或错误描述字符串。
- `success`：包括异步任务提交成功（`result` 是 `{ type: "async_task", taskId, message }` 的 JSON 字符串，不代表任务真正完成）。

**没有截断机制**：`formatToolResults()`（VCP 协议实现，`vcp-protocol.ts:403-423`）直接把 `result.result` 原文拼进 `[[AIO工具调用结果信息汇总: ... ]]` 文本块，**不限制长度**。这意味着如果某个工具返回超大字符串（如 `directory-tree` 扫描大目录、`dir-search` 全文搜索），会整段回注下一轮 LLM 请求，可能撑爆上下文窗口或触发 API 报错——是否截断完全取决于各工具自己（例如 `dir-search` 有 `maxDisplayFiles`/`maxMatchesPerFile` 参数用于结果层面截断，但那是工具自愿实现，不是框架强制）。

多模态结果：框架层没有专门的多模态结果通道；`media-generator` 返回资产路径字符串（`appdata://` scheme），依赖渲染层/宏展开机制在正文里解析成图片；`internal_request_file` 返回的是 `{ fileData: base64, mimeType }` 结构（走 VCP 分布式协议，不进入本地 `ToolExecutionResult.result` 字符串通道）。

能否污染后续上下文：**能**。工具结果原文（包括错误信息、拒绝提示）都会作为新的 `role: "tool"` 消息节点持久化并进入下一轮上下文（`useToolCallOrchestrator.ts:316-353`）。如果工具返回内容本身包含类似 VCP 协议标记的文本（例如某网页内容里恰好含 `<<<[TOOL_REQUEST]>>>` 字面文本），会被渲染层的 Tokenizer 解析为新的工具调用块 UI（见第 13 节交叉点），存在"结果注入触发下一轮误解析"的潜在风险，但**这只影响渲染展示**，不会被 `tool-calling` 引擎重新解析执行（引擎只解析 LLM 自己产生的 assistant 文本，不会重新扫描 tool 角色消息）。

**依据**：[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`tool-calling/core/protocols/vcp-protocol.ts`](../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts)、[`llm-chat/composables/chat/useToolCallOrchestrator.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts)、[`dir-search/dir-search.registry.ts`](../../aio-hub/src/tools/dir-search/dir-search.registry.ts)。

## 9. 内建工具完整清单

以 `grep agentCallable: true` 结果为准（`../../aio-hub/src/tools/**/*.registry.ts` 及相关 service），逐个列出。"执行位置"标注最终落地的运行环境；"审批"标注默认是否受统一审批状态机管理（不含工具自身 `checkSecurityPolicy` 之外的隐藏逻辑）。

| 工具 ID | 方法 | 用途 | 执行位置 | 需审批（默认 manual 模式下） | 边界说明 |
|---|---|---|---|---|---|
| `aio-file-operator` | `read_file`/`write_file`/`append_file`/`delete_file`/`list_directory`/`apply_diff`/`create_directory`/`path_exists` | 本地文件读写、目录操作、Diff 修改 | 前端 + Tauri `file_operations.rs`（无 Rust 侧路径限制） | 是（受 `checkSecurityPolicy` 白名单/死区/审批区三态影响） | 沙箱仅前端字符串判断；`delete_file` 走回收站尚可恢复；多路径方法缺失时校验面会有缺口 |
| `directory-tree` | `generateTree` | 生成目录树（过滤/深度/大小统计） | 前端 + Tauri | 是 | 无路径沙箱，可枚举任意可达目录结构（只读，非破坏性） |
| `dir-search` | `searchDirectory`/`replaceInDirectory` | 全文搜索/正则批量替换文件内容 | 前端 + Tauri（流式 batch 事件） | 是 | `replaceInDirectory` 直接改磁盘文件且**不可撤销**（方法描述里自己标注了"⚠️ 此操作会直接修改磁盘文件，不可撤销"），无路径沙箱 |
| `directory-janitor` | `scanDirectory`/`cleanupItems`/`scanAndCleanup` | 扫描并清理过期/大文件（移入回收站） | 前端 + Tauri (`analyze_directory_for_cleanup`/`cleanup_items`) | 是 | 无独立路径沙箱，`scanAndCleanup` 一步到位自动清理扫描到的所有项 |
| `content-deduplicator` | `scanDuplicates` | 扫描目录查重（精确/规范化匹配） | 前端 + Tauri | 是 | 只读扫描；无路径沙箱 |
| `git-analyzer` | `getFormattedAnalysis`/`getAuthorCommits`/`getCommitDetail`/`getBranchList` | Git 仓库统计分析 | 前端 + Tauri（git2 库或子进程） | 是 | 只读操作 |
| `ffmpeg-tools` | `executeCommand`/`executePipeline`/`getMediaInfo` | 任意 FFmpeg 命令编排、媒体信息读取 | 前端 + Tauri 子进程（`tokio::process::Command`，数组式参数，非 shell） | 是（异步任务，需先提交任务） | `executeCommand`/`executePipeline` 允许 LLM 拼接**任意 FFmpeg CLI 参数数组**（如 `-f concat` 类可能读取任意路径的滤镜/协议参数），属于命令参数层面的高自由度，需 `hwaccel`/`args` 组合审查 |
| `text-diff` | `generatePatch` | 生成统一 diff 补丁（不写盘） | 纯前端 | 是（一般会配自动批准，因为无副作用） | 无副作用（不读写文件） |
| `json-formatter` | `formatJson` | JSON 格式化（支持 `filePath` 读取本地文件） | 前端 + Tauri（`filePath` 分支读盘） | 是 | `filePath` 无路径沙箱，可读任意可达路径下的文件内容并整段返回给模型 |
| `data-filter` | `applyFilter` | JSON/YAML 数组过滤（支持 `customScript` 自定义脚本条件） | 纯前端 JS（`new Function` 动态构造，运行在渲染进程主上下文，**已确认**） | 是 | **已确认**：`operator: "custom"` 时执行 `new Function("item", "value", "return " + cond.customScript)(item, cond.value)`（`logic/dataFilter.logic.ts:134-139`），`customScript` 完全由 LLM 生成的 VCP 参数决定，没有任何沙箱、白名单或 CSP 隔离，等价于让模型在应用主渲染进程里跑任意 JS（可访问 `window.__TAURI_INTERNALS__`，从而间接调用任意已注册的 Tauri command） |
| `media-info-reader` | `readImageMetadata` | 提取 AI 生图/角色卡元数据 | 前端（`@tauri-apps/plugin-fs` 读文件） | 是 | 无路径沙箱，只读 |
| `media-generator` | `generate_<model_id>`（动态，每个可用模型一个） | 调用配置好的图片/视频/语音/音乐生成模型 | 前端 + 远程模型 API（走用户配置的 LLM Profile） | 是（`isFast` 模型走 sync 立即返回，其余走 async 任务） | 生成资源消耗真实 API 额度；`prompt` 完全由 LLM 控制，无内容过滤 |
| `web-distillery` | `quickFetch`/`smartExtract` | 网页内容抽取（HTTP 直取 / 真实浏览器渲染） | 前端 + Tauri HTTP fetch 或内嵌浏览器实例 | 是 | `url` 参数无域名/协议白名单，可对任意地址发起请求（`http:allow-fetch` 权限本身放开 `http://**`/`https://**` 及局域网 IP 正则） |
| `web-canvas` | `read_canvas_file`/`apply_canvas_diff`/`write_canvas_file`/`commit_changes`/`discard_changes`/`list_canvas_files`/`create_canvas`/`clear_runtime_errors`（`open_window` 显式 `agentCallable:false`） | Agent 协作画布：多文件读写、Git 提交/丢弃、HTML 预览 | 前端 + 本地 Git 仓库（`GitInternalService`）+ iframe 预览 | 是（`apply_canvas_diff`/`write_canvas_file` 有 `onToolCallPreview` 自动预览：**审批前就已经写入物理磁盘**，拒绝后再 `git checkout` 回滚） | 预览钩子"先写盘再审批"意味着即使用户点"拒绝"，文件已短暂落盘过（虽会被 checkout 撤销）；写入的内容会被渲染为可执行 HTML/JS（iframe `allow-scripts allow-same-origin`，见消息渲染器笔记 7.3） |
| `recall`（`recall-basic`/`recall-admin`） | `searchEntries`/`upsertEntry`/`updateEntryContent`；`listRecallCollections`/`listEntriesMetadata`/`batchUpdateMetadata`/`deleteEntry` | 结构化知识库/记忆的检索与管理 | 前端 + 本地存储/向量库 | 是（`deleteEntry` 要求显式 `confirm` 参数） | `recall-admin` 可批量改元数据、删除条目；模型自己写入的条目后续又会被当作检索结果召回 |
| `skill:system`（`SkillManagerProxy`） | `skill_run_script`/`skill_read_file`/`skill_list_dir`；`activate_<skillName>`（动态） | 执行已安装 Skill 的私有脚本 / 读取资源 / 激活技能说明 | 前端 + Tauri 子进程（`run_skill_script`，限定 `scripts/` 子目录 + 路径穿越校验） | 是 | `skill_run_script` 本质是**受限的任意脚本执行**（js/ts/py/sh/ps1），影响取决于已安装 Skill 的来源信任度；env 变量可被 Skill 配置注入 |
| `git-committer` | 无 `agentCallable` 方法 | 纯 UI 工具，不对 Agent 暴露 | — | — | 不适用（消息渲染器笔记范围外的 UI 功能，已用 grep 确认无 `agentCallable: true`） |
| `symlink-mover` | 无 `agentCallable` 方法 | 纯 UI 工具 | — | — | 不适用 |
| `window-automator` | 无 `agentCallable` 方法（`runMode: "any"` 但未见 `getMetadata`） | 窗口自动化（点击/取色/截图/OCR），仅供人工在 UI 中编排动作流 | — | — | 不适用（未发现 Agent 可调用接口，属于纯 UI 功能，未列入 Agent 工具范围） |
| `llm-chat`（主实例） | 无 `agentCallable` 方法（`addContentToInput` 等是给其它工具跨模块调用的编程接口，非 LLM 直接可调用） | 输入框/附件/会话编程接口 | 前端 | — | 不计入 Agent 工具（`getMetadata()` 未定义，`services/executor.ts` 的 `execute()` 可被其他工具内部调用，但不出现在 VCP Prompt 里） |
| `llm-chat-agent-mgmt`（`llm-chat.registry.ts` 中的 `agentManagement` 实例） | `list_agents`/`search_agents`/`read_agent_config`/`export_agent_as_text`/`set_agent_field`/`find_replace_in_presets`/`add_preset_message`/`delete_preset_message`/`move_preset_message`/`import_agent_from_text` | 让 Agent 自己管理/编辑其他 Agent（或自身）的配置、预设消息 | 前端 + 本地 Agent 配置文件持久化 | 是 | **自我修改能力**：`set_agent_field` 有 `FIELD_BLACKLIST`（`id`/`createdAt`/`lastUsedAt`/`avatarHistory`）保护，但 `toolCallConfig`/`presetMessages`/`extensionConfig` 等敏感字段不在黑名单内，Agent 理论上可以通过工具调用**修改自己的工具调用权限配置**（如把 `mode` 改成 `auto` 或把某工具加入 `autoApproveTools`）。 |
| `tool-calling`（自身） | `getTaskStatus` 等（异步任务查询/取消接口） | 查询/管理异步任务状态 | 前端 | 视具体方法而定 | 属于框架自省能力 |
| `vcp:<pluginName>`（`VcpToolProxy`，动态，数量随远端 manifest） | 远端插件的每个 `command` | 桥接 VCPToolBox 插件到本地 Agent（如浏览器控制、检索、图像生成等，取决于远端启用的插件） | **远端** VCPToolBox/分布式节点（AIO 仅转发请求与展示审批） | 是（`onBeforeExecute` 走同一本地审批 store，但真正执行在远端，本地无法进一步限制远端行为） | 信任边界完全转移给远端节点；`getMetadata()` 对所有映射命令强制 `agentCallable: true`，没有方法级白名单二次过滤 |
| `internal_request_file`（VCP 内置，非 `ToolRegistry` 注册，硬编码在 `vcpNodeProtocol.ts`） | 读取本机任意 `file://`/`appdata://` 路径文件并转 Base64 回传远端 | 支持 VCPToolBox"超栈追踪"跨节点文件获取 | 前端 + Tauri `read_file_as_base64`/`get_file_mime_type`（无路径限制） | **否**（不经过 `toolCallingStore` 审批流程，是节点协议层的强制内置能力，收到 `execute_tool` 且 `toolName === "internal_request_file"` 直接执行，见 `handleExecuteTool` 分支） | **本笔记确认的机制**：任何能向已连接的 VCP 主服务器下发 `execute_tool(internal_request_file)` 请求的主体（取决于 VCPToolBox 侧鉴权），可无审批读取本机任意可达文件（含 `.env`、SSH key 等）并取得 Base64 内容 |

**依据**：所有 `agentCallable: true` 命中文件（见附录逐一 Read 记录）、[`vcp-connector/composables/useVcpDistributedNode.ts`](../../aio-hub/src/tools/vcp-connector/composables/useVcpDistributedNode.ts)（`BUILTIN_VCP_TOOLS` 常量）、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)（`handleExecuteTool`/`handleInternalRequestFile`）、[`agent-manager/services/agentManagementService.ts`](../../aio-hub/src/tools/agent-manager/services/agentManagementService.ts)（`FIELD_BLACKLIST`）、[`data-filter/logic/dataFilter.logic.ts`](../../aio-hub/src/tools/data-filter/logic/dataFilter.logic.ts)。

## 10. 扩展机制

这里需要区分两条互相正交的扩展轴：**协议扩展**决定模型如何描述调用，**能力扩展**决定有哪些工具和上下文进入系统。前者目前只有 VCP 实现；后者已经有四条实际入口：

1. **`ToolRegistry`/`ToolRegistryFactory`**：`ToolRegistry` 是所有可调用能力的统一边界；既可由 `import.meta.glob` 发现随源码打包的 registry，也可由 factory 在运行期批量生成实例。内建工具与动态桥接都能落到这一接口，不能把 `ToolRegistryFactory` 仅理解为“内建工具”。
2. **`AgentExtension`（`getExtraPromptContext()`）**：`ToolRegistry` 的基接口，不提供可调用方法，只提供只读上下文注入（如 `web-canvas` 的 Canvas 文件树信息、`skill:system` 的宿主环境信息）。生命周期：`initialize()`（注册时）/`dispose()`（注销/热重载时），由 `ToolRegistryManager` 统一调度（`services/registry.ts:102-115`）。
3. **JS/Sidecar/Native 插件系统（`plugin-loader.ts`/`plugin-manager.ts`）**：这是与 `tool-calling` 平行、更底层的扩展体系，本身**不是 Agent 工具协议的一部分**，但插件可以注册 `ToolRegistry` 从而进入 Agent 可调用范围。三种类型信任模型不同：
   - **JS 插件**：生产模式用 `convertFileSrc()` + 动态 `import()` 直接加载 `$APPDATA/plugins/<id>/` 下的 JS 模块（`plugin-loader.ts:404-431`），**在渲染进程主上下文里执行，与内建工具同权限**，能访问 `window.__TAURI_INTERNALS__`、Pinia store、`toolRegistryManager` 等一切全局对象。开发模式还会额外扫描项目根 `/plugins/*/index.ts`。
   - **Sidecar 插件**：外部可执行文件，按 `manifest.sidecar.executable[currentPlatform]` 配置路径启动，跨进程边界更明确，但本次未深入其 IPC 协议。
   - **Native 插件**：按平台加载动态库（`manifest.native.library[currentPlatform]`），是最高权限、最少隔离的扩展形式。
   - 兼容性校验（`validatePluginCompatibility()`）只做 **appVersion/apiVersion/platform 的语义检查并打警告，从不阻止加载**（`plugin-loader.ts:633-759`，注释明确"仅提示，不阻止加载"）——即使版本不兼容，插件仍会被执行。
   - 插件卸载 `uninstall_plugin` 走回收站（可恢复），`-dev` 后缀插件（开发模式加载）不允许通过 UI 卸载。
4. **VCP Proxy（`VcpToolProxy`/`VcpBridgeFactory`）**：本质是把远端 HTTP/WS 服务的能力映射为本地 `ToolRegistry`，信任边界完全转移到远端节点，AIO 自身只做协议转换，见第 12 节。

协议轴则由 `ToolCallingProtocol` 承担。增加新协议需要实现四个转换方法，并修改发现服务的 `SUPPORTED_PROTOCOLS`、Composable 的 `resolveProtocol()` 和 Agent 配置类型。这个边界已经把 VCP 细节从 parser/engine/executor 中抽离，但注册过程仍是源码内硬编码，当前不能由上述 JS/Sidecar/Native 插件动态添加一种协议。更准确的评价是：**AIO 已搭好多协议、异构工具来源和动态上下文的统一骨架，其中工具来源已经多样化，模型调用协议暂时只交付了 VCP。**

**依据**：[`services/plugin-loader.ts`](../../aio-hub/src/services/plugin-loader.ts)、[`services/plugin-manager.ts`](../../aio-hub/src/services/plugin-manager.ts)、[`services/types.ts`](../../aio-hub/src/services/types.ts)（`AgentExtension`/`ToolRegistryFactory`）、[`vcp-connector/services/VcpBridgeFactory.ts`](../../aio-hub/src/tools/vcp-connector/services/VcpBridgeFactory.ts)。

## 11. 子 Agent 与任务委派

**未发现 agent-as-tool 机制**：全仓库搜索 `delegate`/`subAgent`/`spawnAgent`/`callAgent` 等关键词均无命中；`llm-chat-agent-mgmt` 工具（第 9 节）只提供"编辑其他 Agent 配置文件"的能力（CRUD 预设消息、字段），**不提供"调用/触发另一个 Agent 对话"的能力**，即当前 Agent 不能把子任务派发给另一个 Agent 实例并等待其独立对话结果。

**后台任务**：`tool-calling/core/async-task`（`TaskManager`/`TaskExecutor`/`TaskStore`）是唯一的后台任务机制，服务于 `executionMode: "async"` 的方法（`ffmpeg-tools`、非 fast 模式的 `media-generator`）。任务状态机 `pending -> running -> completed/failed/cancelled/interrupted`，持久化到磁盘（`persistImmediately()`/`persistDebounced()`），支持取消（`AbortController`）、重试（`retryTask()`，仅限 `failed`/`interrupted` 状态）、进度上报（`reportProgress`）。应用重启后运行中的任务会被标记为 `interrupted`（不会自动恢复执行）。

**定时任务**：`ToolRegistry.startupConfig`/`onStartup()` 是唯一的"启动时自动执行"钩子（当前仅 `vcp-connector` 使用，实现启动自动连接），**没有 cron/定时循环调度机制**用于周期性触发 Agent 工具。

**嵌套调用**：VCP 协议支持"块级转义嵌套"（`TOOL_REQUEST_ESCAPE` 包裹另一个完整 `TOOL_REQUEST` 块），但这只是**文本层面的嵌套表示**，用于让 LLM 在一次输出中携带示例/嵌套请求文本而不被误解析；解析器实际展开为多个独立的 `ParsedToolRequest`（同一批次内平级执行），不是"工具调用触发另一个工具调用链"的运行时递归结构。

**依据**：[`tool-calling/core/async-task/task-manager.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-manager.ts)、[`tool-calling/core/async-task/task-executor.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-executor.ts)、[`vcp-connector/vcp-connector.registry.ts`](../../aio-hub/src/tools/vcp-connector/vcp-connector.registry.ts)、[`services/types.ts`](../../aio-hub/src/services/types.ts)（`startupConfig`/`onStartup`）。

## 12. 与 VCPToolBox 的真实联动

已结合 `VCPToolBox` 当前工作树源码核实，AIO 与 VCPToolBox 之间是**双向对等的 WebSocket 协议契约**，非单向调用：

**AIO 作为客户端（拉取远端能力）**：
- `VcpBridgeFactory.refreshManifests()` 发送 `get_vcp_manifests`（带 `requestId`、`client: "aio-hub"`、`features: ["configSchema"]`），VCPToolBox 侧响应 `vcp_manifest_response`。
- 收到的每个远端插件 manifest 被 `VcpToolProxy` 包装成本地 `ToolRegistry`，其 `getMetadata()` **对所有映射命令强制 `agentCallable: true`**（`VcpToolProxy.ts:119`）——本地没有二次过滤远端命令的白名单机制，影响面完全取决于远端 VCPToolBox 启用了哪些插件。
- 执行走 `execute_vcp_tool` 请求 -> VCPToolBox 侧路由到具体插件 -> `tool_result` 响应（`VcpBridgeFactory.executeRemote()`，30 秒本地超时）。

**AIO 作为分布式节点（暴露本机能力）**：
- 已与 VCPToolBox `WebSocketServer.js:729`（`register_tools` 分支）核实：AIO 发送的 `register_tools` 会被 VCPToolBox 存入 `distributedServers`，并**显式过滤掉 `internal_request_file`**（`externalTools = message.data.tools.filter(t => t.name !== 'internal_request_file')`），确认这个内置工具确实是协议层专属能力，不会出现在插件列表 UI 里，但仍可被服务端通过 `execute_tool` 直接调用。
- VCPToolBox 侧 `execute_tool` 消息经 `executeDistributedTool()` 按 `serverId`/`serverName` 查找已连接节点并转发（`WebSocketServer.js:866-896`），超时按插件 manifest 的 `communication.timeout` 或默认 60000ms。
- 本地暴露规则（`useVcpDistributedNode.ts:discoverTools()`）：自动模式暴露所有 `agentCallable === true || distributedExposed === true` 且未被禁用的方法；手动模式按 `exposedToolIds` 白名单；**排除 `vcp:` 前缀工具**（防止把桥接进来的远端工具二次暴露回去形成循环）。
- 审批协议往返（已用 AIO 与 VCPToolBox 双侧代码核实一致）：VCPToolBox `toolApprovalManager.getApprovalDecision()` 命中规则后发 `tool_approval_request`（含 `requestId`/`toolName`/`args`/`maid`），AIO `vcpNodeProtocol.handleToolApprovalRequest()` 转成本地 `ParsedToolRequest` 塞进 `toolCallingStore.requestApproval(sessionId, request, requestId)`（`sessionId = "vcp-" + maid`），用户在 AIO UI 里点允许/拒绝后回传 `tool_approval_response`。VCPToolBox 侧默认 `timeoutMinutes = 5`（本地无审批时会超时），AIO 侧本地审批**无超时**（见第 6 节），两者不对称。

**能力映射与排除规则总结**：`internal_request_file` 是唯一的协议级强制内置工具，不经 `agentCallable` 判定，**不受任何本地路径沙箱限制**（见第 9 节表格）。

**依据**：[`vcp-connector/services/VcpBridgeFactory.ts`](../../aio-hub/src/tools/vcp-connector/services/VcpBridgeFactory.ts)、[`vcp-connector/composables/useVcpDistributedNode.ts`](../../aio-hub/src/tools/vcp-connector/composables/useVcpDistributedNode.ts)、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)、VCPToolBox [`WebSocketServer.js`](../../VCPToolBox/WebSocketServer.js)（`register_tools`/`execute_tool`/`tool_result` 分支）、VCPToolBox [`modules/toolApprovalManager.js`](../../VCPToolBox/modules/toolApprovalManager.js)（均只读用于契约核实，未修改）。

## 13. 与消息渲染器笔记的交叉点

工具调用在 UI 上有**两条独立渲染路径**（与 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md) 第 1.2、7 节结论一致并在本次调查中复核）：

1. **`ToolCallMessage.vue`**：独立的 `role: "tool"` 消息节点，由 `useToolCallOrchestrator` 创建，展示审批状态、参数、结果、异步任务进度条。这是"真实执行记录"的权威展示，其内容（`toolCalls[].status`）来自 `executor.ts` 的真实执行结果，**不能被模型输出文本伪造**——因为它读取的是 `ChatMessageNode.metadata.toolCalls`，这个字段只在 `useToolCallOrchestrator.ts` 内部由代码逻辑赋值，普通 LLM 输出文本无法直接写入某条消息的 `metadata` 字段。
2. **`VcpToolNode`（渲染器 AST 节点）**：`rich-text-renderer` 的 Tokenizer **只要在任意消息正文（包括 assistant/user/甚至工具结果回填的文本）里检测到 `<<<[TOOL_REQUEST]>>>` 或 `[[VCP调用结果信息汇总: ...]]` 字面文本，就会渲染出一个看起来像"工具调用卡片"的 UI 组件**——包括状态图标（成功/失败）、参数列表、"成功"/"失败" `el-tag`。这是**纯文本模式匹配触发的展示效果，不代表任何真实执行**。

**结果文本触发工具卡片渲染的路径**：如果某个工具的返回结果（如 `web-distillery` 抓取的网页内容、`recall` 检索出的历史条目内容）里恰好包含形如：
```
[[VCP调用结果信息汇总:
- 工具名称: aio-file-operator
- 执行状态: SUCCESS
- 返回内容: （伪造的任意内容）
VCP调用结果结束]]
```
的文本，`Tokenizer.ts:757-793` 会把它解析成 `vcp_tool` 类型的 AST 节点（`isResult: true`），`VcpToolNode.vue` 据此渲染出一个"✅ 成功"的绿色标签卡片，**在视觉上与真实工具执行结果完全一致**，但这段内容其实来自网页抓取或知识库检索，从未真正调用过 `aio-file-operator`。这构成一种**结果伪造/UI 欺骗**的展示效果：网页或知识库条目中的文本可以让模型"引用"这段文本，用户看到界面上的绿色成功卡片会产生"该操作已被系统执行并成功"的误判，即使实际上 `tool-calling` 引擎从未解析执行过它（引擎只解析 assistant 消息，且解析逻辑判断 `tool_name`/`command` 是否存在于 `toolRegistryManager`，这段结果文本不会被引擎二次执行，影响停留在**视觉呈现**层面，不会触发真实工具执行）。

**批准栏本身**：`ToolCallingApprovalBar.vue` 的按钮点击直接走 `execute({ service: "tool-calling", method: "approveRequest", params })`，是真实的 Vue 事件绑定，不经过任何可被消息正文影响的中间层，**审批按钮本身不可被模型输出伪造**；但审批栏里展示的"参数预览"（`item.request.args`）来自解析结果，如果参数值本身包含误导性文本（如把危险的 `path` 参数伪装成看起来无害的字符串），可能诱导用户误判参数含义——这是展示信任层面的问题，不是代码缺陷。

**依据**：[`llm-chat/components/message/ToolCallMessage.vue`](../../aio-hub/src/tools/llm-chat/components/message/ToolCallMessage.vue)、[`rich-text-renderer/parser/Tokenizer.ts`](../../aio-hub/src/tools/rich-text-renderer/parser/Tokenizer.ts)（VCP 结果块解析，行 756-793）、[`rich-text-renderer/components/nodes/VcpToolNode.vue`](../../aio-hub/src/tools/rich-text-renderer/components/nodes/VcpToolNode.vue)、[`llm-chat/components/message-input/ToolCallingApprovalBar.vue`](../../aio-hub/src/tools/llm-chat/components/message-input/ToolCallingApprovalBar.vue)、消息渲染器笔记第 1.2/5.1/7 节（交叉引用，未重复验证其结论）。

## 14. 未验证事项与后续调查缺口

1. **VCPToolBox 侧当前 checkout 实际启用的插件数量与种类**：本笔记只核实了协议层（`WebSocketServer.js`、`toolApprovalManager.js`）与 AIO 的契约一致性，未逐一核对 VCPToolBox `Plugin/` 目录下实际启用了哪些插件清单，因此"接入某个 VCP 服务器后 AIO 实际能获得哪些远端能力"取决于对方部署，本笔记不做假设。
2. **VCP Proxy 方法级禁用颗粒度**（见第 9 节表格）。
3. **插件系统的安装信任流程**（首次安装警告/来源校验）。
4. **`smartExtract` 内嵌浏览器实例的网络/CSP 隔离细节**。
5. **`directory-janitor`/`dir-search` 等工具是否在 UI 层（而非 Agent 工具审批链路）有额外的破坏性操作二次确认**——本次只确认了 Agent 工具调用路径没有 `onToolCallPreview`，未深入这些工具面向人类用户直接操作时的 UI 交互流程（那部分不属于 Agent 工具范畴）。
6. **`skill` 系统的 `.env` 文件路径是否可能与 `aio-file-operator` 白名单目录重叠**。
7. **validator.ts 与 executor.ts 对 `agentCallable === undefined` 的判断分歧**是否在实际运行中造成过可观察的行为差异（本笔记基于静态代码分析指出该分歧存在，但未构造具体触发场景验证其后果）。
8. **移动端（`mobile/` 目录）是否有独立的 Agent 工具体系**——本次调查聚焦桌面 Tauri 端，未检查 `mobile/src/tools/tool-calling`（如存在）是否为独立实现或共享桌面端代码，需要专项确认（参考消息渲染器笔记已确认移动端消息渲染是独立轻量实现，Agent 工具层面是否同样分裂未在本次核实）。
9. **VCPToolBox 侧对分布式节点 `execute_tool` 请求发起方的鉴权模型**（谁能触发 `execute_tool`，是否任何连上 VCPToolBox 的客户端都能对某个已注册节点发起 `internal_request_file` 调用）——这决定 `internal_request_file` 的实际触发门槛，需要读取 VCPToolBox 更完整的鉴权/会话代码，本次超出"只读到能说明契约与边界为止"的既定范围，标记为后续调查缺口。
