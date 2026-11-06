# AIO Hub Agent 工具调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：对照源码快照差异，只读复核VCP执行解析、文件与Agent字段策略、审批仲裁、Skill进程、子Agent派遣/追加/取消/恢复和媒体回传；既有跨仓协议结论保留其来源，未重新运行外部服务器，未修改源码或启动应用
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的 Agent 工具系统按层拆分。`tool-calling` 将工具能力、运行时上下文、审批与执行、模型通信协议拆成不同层：工具经统一注册接口接入，发现与执行层处理统一的内部对象，`ToolCallingProtocol` 再负责把这些对象转换成某种模型可读、可返回的调用表示。**当前产品在模型通信层只注册了 VCP 这一种协议实现，Agent 配置里的协议类型也只有 `"vcp"` 一种取值；VCP 是现阶段落地，不是该架构给工具系统划定的上限。**

核心事实：

1. **工具发现是运行期反射，不是静态清单。** 所有已注册的 `ToolRegistry` 由管理器统一收集，`tool-calling/core/discovery.ts` 在生成 Prompt 时才遍历每个 registry 的元数据，筛出标记为可被 Agent 调用的方法。工具列表随注册表增删实时变化；同一份元数据调用会被 Prompt 生成、执行器二次校验、VCP 分布式清单生成多处触发，没有统一缓存单一来源，一致性依赖各处都读取同一 registry 实例。
2. **模型通信协议有明确的替换边界，目前唯一实现是 VCP。** `ToolCallingProtocol` 只要求实现工具定义生成、使用说明生成、调用请求解析和结果格式化四项能力；工具发现把统一元数据交给协议生成定义，协议解析出的统一请求再进入校验、审批和方法执行。新增协议仍需改动 `SUPPORTED_PROTOCOLS`、`resolveProtocol()` 和 `ToolCallConfig.protocol`，所以这是一处代码级扩展点，尚不是可由插件在运行期注册的协议市场。当前 VCP 解析器会跳过 Markdown code fence/inline code，执行器还会二次核验 `agentCallable`。
3. **工具能力也有多条接入路径。** 内建 registry、动态 `ToolRegistryFactory`、只注入环境信息的 `AgentExtension`、JS/Sidecar/Native 插件代理，以及把远端 manifest 包装成本地 registry 的 `VcpToolProxy`，最后都汇入同一发现和执行链。因而“目前只做了 VCP”准确地说只适用于**模型调用协议实现**，不适用于整个工具来源与扩展体系。
4. **审批状态机是 Promise-based 单例 store，不做持久化。** `useToolCallingStore` 用内存数组 + `resolve` 回调管理待批准请求；应用重启或页面刷新会丢失所有 pending 状态（异步任务另有磁盘持久化，见下）。自动批准的匹配粒度到"工具级"和"方法级"，方法级优先于工具级。审批支持可配置超时（默认无限等待，开启后按秒级配置自动拒绝）与 AbortSignal/会话清理取消，见第 6 节。
5. **`aio-file-operator` 的路径沙箱已加固**：路径校验改为先经 Rust 命令把目标及规则路径解析成**真实路径**（防符号链接逃逸、处理 Windows 扩展前缀），再做目录包含关系判断（修复前缀碰撞）；Rust 侧另新增一组外部传输专用命令，为 VCP 文件读取提供二次沙箱/规则/大小校验与审计日志（见第 7/9 节）。普通强制读写命令本身仍不做路径限制，前端校验仍是主要边界。
6. **VCP 分布式节点是双向对等契约，已与 VCPToolBox 当前源码核实一致。** AIO 既能作为客户端拉取远端 manifest 并代理执行，也能作为节点被远端 `execute_tool` 调用本机标记为可调用或可分布暴露的方法。`internal_request_file` **不是 AIO 内可用的工具**，而是为满足 VCP 分布式契约实现的入向协议义务：它不在注册表里登记，本机模型无法发现或调用，只能由已连接的 VCP 主服务器通过 `execute_tool` 触发。它读取 `file://` 路径转 Base64 回传，但已接入 aio-file-operator 沙箱/审批区与 Rust 侧复校验（见第 9 节），并非无限制读取。
7. **子智能体已成为可调用工具。** `sub-agent` 工具提供 `ask`、`get_task_status`、`get_task_activity`、`send_task_message`、`cancel_task` 等方法，把任务委派给拥有独立子会话的另一个 Agent，并由 `BackgroundTaskRegistry` 维护任务状态与可观测性（第 11 节）。这与此前"只能编辑其他 Agent 配置、不能调用"的结论相反。
8. **审批链新增自动仲裁层。** 静态自动批准之后、人工审批之前，注入的 `ApprovalArbiter` 会先给出 approve/deny/escalate 判定并留下审计快照；只有 escalate 或判定失败才落到人工审批条，仲裁引擎分 JEV 与普通 LLM 两种，配置分全局与 Agent 两层（第 6 节）。

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

`ToolRegistry` 是工具的统一接口，定义在 `../../aio-hub/src/services/types.ts:167`，除标识用的 `id` 外还声明了以下可选能力字段：

- `getMetadata()`（可选但强烈推荐）：向发现/执行层提供方法元数据；
- `checkSecurityPolicy?`：路径沙箱等安全策略判断（文件操作与 Agent 配置编辑均有实现，见第 4/6 节）；
- `onToolCallPreview?`/`onToolCallDiscarded?`：执行前预览与拒绝回调；
- `settingsSchema?`：UI 配置模式，其中带默认值的项会进入执行参数（见第 4 节）；
- `runMode?`：执行模式声明。

所有工具方法签名统一为 `(args, context?: ToolContext) => Promise<string> | string`（`../../aio-hub/src/tools/tool-calling/ARCHITECTURE.md:507`），参数先降级为 `Record<string, string>`（VCP 解析结果），再由方法/actions 层自行转型。

注册走 Vite 的 `import.meta.glob` 通配扫描（`../../aio-hub/src/services/auto-register.ts:62`），在应用启动时执行。registry 文件支持三种导出形态：

- 单例对象；
- 类构造函数；
- 数组（多实例），例如 `recall.registry.ts` 导出 `[recallBasic, recallAdmin]`、`llm-chat.registry.ts` 导出 `[llmChatMain, agentManagement]`。

工具 ID 冲突在初始化阶段直接 `throw`（`../../aio-hub/src/services/registry.ts:96`），热重载阶段则允许覆盖并打 warning——**意味着开发环境下插件覆盖生产同名工具不会报错，需要人工关注日志**。

`agentCallable` 判定点有且只有一处语义来源：`MethodMetadata.agentCallable`（`../../aio-hub/src/services/types.ts:46`），但被三处独立读取：
- discovery 生成 Prompt 时（`../../aio-hub/src/tools/tool-calling/core/discovery.ts:242`，`methods.filter((method) => method.agentCallable === true)`）
- executor 执行前二次校验（`../../aio-hub/src/tools/tool-calling/core/executor.ts:314`，`methodMeta?.agentCallable !== true` 直接拒绝）
- validator（引擎路径，`../../aio-hub/src/tools/tool-calling/core/validator.ts:59`）只在字段为 `false` 时报错，口径比 executor 的严格 `!== true` 判断宽松——方法未声明该字段（取值为 `undefined`）时 validator 认为合法，executor 却会拒绝执行，是潜在的行为不一致点

方法路由由两个字段共同定位：`tool_name` 对应 `toolId`，`command` 对应方法名（默认取方法名，可经 `protocolConfig.vcpCommand` 覆盖，见 `vcp-protocol.ts:67`）；执行阶段把两者拼成 `${toolId}_${methodName}` 形式的 flat key，作为 `methodToggles`/`autoApproveMethods` 的索引键（`executor.ts:203`）。

**没有跨工具的方法名去重逻辑**：不同 `toolId` 下可以有同名方法，靠 `tool_name` 区分。LLM 在 VCP 块里漏填 `tool_name` 时回退为 `"unknown_tool"`（`vcp-protocol.ts:226`），该名字在注册表中必然查不到，于是返回“工具不存在”错误而不是崩溃。

静态声明 vs 动态生成：绝大多数工具的 `getMetadata()` 是静态硬编码方法列表（如 `directory-tree`、`json-formatter`）；但至少两类工具是**动态生成方法列表**：
- `media-generator`：按当前启用的 LLM Profile/Model 组合，为每个可用模型生成一个 `generate_<sanitized_model_id>` 方法（`../../aio-hub/src/tools/media-generator/services/buildAgentMethods.ts:754`），方法数随用户配置模型数量变化，`bindDynamicHandlers()` 把 handler 挂到 `this` 实例上。
- `skill-manager`（`SkillManagerProxy`，id `skill:system`）：为每个已启用 Skill 生成 `activate_<skillName>` 方法（`../../aio-hub/src/tools/skill-manager/services/SkillManagerProxy.ts:124`），同样是运行时挂载实例方法。
- `vcp-connector` 的 `VcpToolProxy`：为每个远端 VCP 插件命令动态挂载同名方法到实例上（`VcpToolProxy.ts:89`），且元数据里对所有映射方法**强制标记为可被 Agent 调用**（`VcpToolProxy.ts:119`）——远端插件暴露的每个命令天然可被本地 Agent 调用，白名单权在“是否接入该 VCP bridge manifest”，不在方法级。

**依据**：[`services/types.ts`](../../aio-hub/src/services/types.ts)、[`services/registry.ts`](../../aio-hub/src/services/registry.ts)、[`services/auto-register.ts`](../../aio-hub/src/services/auto-register.ts)、[`tool-calling/core/discovery.ts`](../../aio-hub/src/tools/tool-calling/core/discovery.ts)、[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`tool-calling/core/validator.ts`](../../aio-hub/src/tools/tool-calling/core/validator.ts)、[`media-generator/services/buildAgentMethods.ts`](../../aio-hub/src/tools/media-generator/services/buildAgentMethods.ts)、[`skill-manager/services/SkillManagerProxy.ts`](../../aio-hub/src/tools/skill-manager/services/SkillManagerProxy.ts)、[`vcp-connector/services/VcpToolProxy.ts`](../../aio-hub/src/tools/vcp-connector/services/VcpToolProxy.ts)。

## 2. 工具发现与注入

发现服务 `createToolDiscoveryService()`（`../../aio-hub/src/tools/tool-calling/core/discovery.ts:168`）提供 `generatePrompt()`（静态工具定义）和 `getAgentContexts()`（动态运行时上下文），两者刻意分离：

- `{{tools}}` 宏对应 `generatePrompt()`，结果按 `protocol|agentId|stableConfigHash` 做内存缓存（`discovery.ts:294`），命中缓存直接返回字符串。缓存键由 `stableStringifyConfig()` 对工具/方法开关、自动批准、覆盖等五类配置项各自排序后序列化而成（`discovery.ts:103`），保证字段顺序不同也能命中同一缓存。
- `{{tool_context}}` 宏对应 `getAgentContexts()`，**不缓存**，每次都并发调用所有已启用工具/扩展的 `getExtraPromptContext()`（`discovery.ts:445`），用 `<context_provider id="toolId">` 包裹拼接。
- `{{tool_usage}}` 宏对应协议使用说明，是静态字符串（`vcp-protocol.ts:314`），无缓存但本身开销可忽略。

三个宏的位置通常由作者预设决定；实际有效正文缺少三个宏且允许自动补位时，组装器才补入工具说明。启用上下文缓存优化且存在安全历史落点时，自动工具定义/用法留在前部 system 消息，运行环境改放尾部附近的 user 参考块；否则合并补位到历史前。显式宏不会被自动迁移。此机制改善前缀稳定性，当前聊天主链未找到主动生成 `cache_control` 断点的路径；Gemini 适配器存在低层缓存引用透传也不能等同本工具目录已创建显式缓存（`core/context-processors/injection-assembler.ts:261-379`；`core/context-utils/runtime-context.ts`）。

过滤/开关集中在发现阶段生效：工具级由 `resolveToolEnabled()` 判断（`discovery.ts:82`，`toolToggles[toolId]` 优先于 `defaultToolEnabled`），方法级在 `generatePrompt()` 内联过滤（`discovery.ts:322`，仅 `methodToggles[toolId_methodName] !== false` 保留）。

VCP 分布式的 `includeToolIds` 参数可以无视 `config.enabled` 强制包含指定工具（`discovery.ts:302-308`），是给 `vcp-connector` 手动暴露工具用的旁路，正常聊天 Agent 一般不会传这个参数。

**依据**：[`tool-calling/core/discovery.ts`](../../aio-hub/src/tools/tool-calling/core/discovery.ts)、[`llm-chat/macro-engine/macros/tools.ts`](../../aio-hub/src/tools/llm-chat/macro-engine/macros/tools.ts)、[`llm-chat/core/context-processors/injection-assembler.ts`](../../aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts)。

## 3. 协议抽象与当前实现（目前仅 VCP）

`tool-calling/core/protocols/base.ts` 定义的 `ToolCallingProtocol` 是模型通信层与工具执行内核之间的边界：

| 接口方法 | 负责内容 | 是否影响发现/执行语义 |
|---|---|---|
| `generateToolDefinitions()` | 把统一的工具元数据转换成模型可见定义 | 否 |
| `generateUsageInstructions()` | 生成协议使用说明 | 否 |
| `parseToolRequests()` | 把模型输出转换成 `ParsedToolRequest[]` | 只负责表示到内部对象的转换 |
| `formatToolResults()` | 把统一执行结果转换成下一轮上下文 | 否 |

解析后的注册表校验、`agentCallable` 复核、安全策略、人工审批、超时和真实方法调用仍由协议外的 parser/executor/engine 链处理。这使 AIO 可以增加另一种文本协议，同时复用现有工具目录与执行策略。接口接收 `finalText: string`，工具定义与结果同样返回字符串，因此它目前是**多种文本协议的抽象**；若要直接接入模型 API 的结构化 `tool_calls`，还需扩展该接口及聊天消息编排链，不能视为现成能力。

目前这项扩展只完成了接口和路由骨架：协议注册表里只有 `vcp`，`useToolCalling.resolveProtocol()` 对任何输入都回退到同一个 `VcpToolCallingProtocol`，Agent 配置里的协议类型也被收窄为 `"vcp"`。下面记录的只是当前 VCP 实现的行为，不能据此把 AIO 的整体工具架构等同于 VCP。

### 3.1. VCP 文本块语法

协议实现集中在 `../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts`。语法要点：

- 工具定义标记用于 Prompt；只有标准 `TOOL_REQUEST`/`END_TOOL_REQUEST` 块具备执行入口。`TOOL_REQUEST_ESCAPE` 仅供参数内引用请求字面量，参数提取后还原，不产生另一条执行请求（`vcp-protocol.ts:327-370`）。
- 参数编码 `key:「始」value「末」`，还支持 `「始ESCAPE」...「末ESCAPE」` 和 `「始exp」...「末exp」` 两种转义变体，解析优先级 `ESCAPE/exp > 标准`（`vcp-protocol.ts:32-36`）：先扫描转义变体并记录匹配区间，再把这些区间在原文中"掏空"（替换为等长空格）后才跑标准正则，避免转义内容里的普通 `「始」「末」` 被二次误匹配（`vcp-protocol.ts:132-141`）。
- 批量调用：`command1`/`path1`、`command2`/`path2`… 数字后缀键会被识别为分组参数，一个 `TOOL_REQUEST` 块拆分为多个 `ParsedToolRequest`（`vcp-protocol.ts:200-268`）。`tool_name`、`request_id` 不参与分组。

**边界情况已确认**：

| 场景 | 行为 | 源码位置 |
|---|---|---|
| Markdown code fence / inline code 包含示例 TOOL_REQUEST | 复合正则 `scanner` 优先匹配 fence/inline code 整体跳过，避免解析伪请求 | `vcp-protocol.ts:356` |
| 坏块后又出现标准 TOOL_REQUEST | 丢弃被后续标准请求中断的坏块，从新起点继续；转义请求标记不作为独立恢复/执行入口。这是结构恢复，不修复损坏参数后执行 | `vcp-protocol.ts:380-408` |
| 参数值本身含协议分隔符或请求标记 | 用 `「始ESCAPE」...「末ESCAPE」` 包裹参数值；边界扫描会跳过完整 ESCAPE 区域，其中的请求标记不会中断外层块。冒号后允许可选空白 | `vcp-protocol.ts:32-37,116-141`、`src/utils/vcpBlockBoundary.ts:29-81` |
| 流式截断（末尾缺 `END_TOOL_REQUEST`，且没有后续恢复起点） | 记录 warning 并停止扫描，返回此前已解析的请求列表，不抛异常 | `vcp-protocol.ts:399-407` |
| 参数缺少闭合 `「末」` | `RE_VCP_PENDING` 捕获未闭合的键值，仍尝试提取到 value，但在 `validation.errors` 里记录“未正确闭合” | `vcp-protocol.ts:166-172` |
| 缺少 `tool_name` 或 `command` | 分别 push 到 `errors`，`validation.isValid = false`；executor 遇到 `!isValid` 直接返回 error 结果，不会真正路由执行 | `vcp-protocol.ts:183-194`、`executor.ts:186-194` |
| 同一轮回复含多个 TOOL_REQUEST 块 | `scanner.lastIndex` 每次成功解析后跳到 `blockEnd + endMarker.length`，循环继续扫描剩余文本，支持多块 | `vcp-protocol.ts:395-397` |
| 值内含反斜杠双写（如 LLM 习惯性 JSON 转义 `\\`） | `sanitizeValue()` 尝试 `JSON.parse` 还原，失败则简单 `replace(/\\\\/g, "\\")` | `vcp-protocol.ts:43-59` |

渲染层仍由自己的 Tokenizer 把同一文本块转换为 `VcpToolNode`，参数提取与 AST 生成没有与执行解析器合并；两侧现在只共享 `findVcpBlockBoundary()` 的块边界扫描。渲染侧另外允许可关闭的模糊恢复：当模型用普通 `「末」` 错误关闭 ESCAPE 字段时，只在候选唯一且后缀结构完整的条件下修复显示并给出警告；执行侧继续严格解析，这种错误调用返回空列表、不会执行（`rich-text-renderer/parser/vcpFenceRecovery.ts:154-232`、`tool-calling/__tests__/tool-calling.test.ts:243-250`）。因此两侧有意维持“显示容错、执行严格”的不同契约。

**依据**：[`tool-calling/core/protocols/base.ts`](../../aio-hub/src/tools/tool-calling/core/protocols/base.ts)、[`tool-calling/core/discovery.ts`](../../aio-hub/src/tools/tool-calling/core/discovery.ts)、[`tool-calling/composables/useToolCalling.ts`](../../aio-hub/src/tools/tool-calling/composables/useToolCalling.ts)、[`agent-manager/types/agent.ts`](../../aio-hub/src/tools/agent-manager/types/agent.ts)、[`tool-calling/core/protocols/vcp-protocol.ts`](../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts)、[`rich-text-renderer/parser/Tokenizer.ts`](../../aio-hub/src/tools/rich-text-renderer/parser/Tokenizer.ts)。

## 4. 参数校验与规范化

**没有 JSON Schema 校验。** `MethodParameter` 只是文档性的类型/必填声明（`services/types.ts:21`），不接入任何 schema 校验库（无 zod/ajv 依赖痕迹）。executor 只对 `boolean` 与 `number` 两类基础参数做宽松转换（`executor.ts:140-153`）：布尔按小写字符串是否等于 `"true"`，数字经 `Number()` 转换并拒绝 NaN。其余类型（`string[]`、对象、枚举）**不做任何强制转换或校验**，全靠各工具在方法体内自行解析。

因此各工具普遍自建了参数规范化小工具：
- 参数规范化：`../../aio-hub/src/utils/agentArgs.ts` 提供布尔归一化辅助函数 `parseAgentBoolean()`/`coerceAgentBoolean()`/`normalizeAgentBooleanFields()`，把 LLM 可能传的多种布尔写法统一转布尔，例如：
  ```
  "true" | "1" | "yes" | 1 | true
  ```
  被 `ffmpeg-tools`、`directory-janitor`、`recall`、`media-generator`、`aio-file-operator` 等 10+ 工具复用。
- 部分工具在 `getMetadata()` 里给出参数默认值，但 executor **不会自动把默认值补进最终参数**（除非工具自己的 `settingsSchema` 有对应项，见下）；LLM 没传该字段时，方法体内要自己回退到默认值。

参数合并优先级由 `prepareRequestContext()` 实现（`executor.ts:125-137`）：
```
mergedArgs = { ...schemaDefaults, ...agentPreset, ...cleanArgs }
```
其中"配置默认值"来自工具 `settingsSchema` 中带 `defaultValue` 的项（按 `modelPath` 映射），与 `MethodParameter.defaultValue` 是**两套不同的默认值来源**——前者是 UI 配置默认值、真正被合并进执行参数，后者只是方法参数文档里的声明，容易混淆；"Agent 预设"来自 `config.toolSettings[toolId]`（Agent 级，UI 上通过 Agent 设置面板配置）；"实参"是剔除 `command` 字段后的 LLM 参数，优先级最高。

文件策略收集五类路径参数，逐一解析真实路径并求值；任一路径 block 则整体拒绝，有 approve 则整体要求审批。复制、移动和删除还调用 Rust `inspect_file_operation` 检查目录/递归操作，检查失败直接阻断。复制/移动已有模型可调用方法，源和目标共同决定整次操作的审批或拒绝结果（`aio-file-operator/utils/security.ts:258-313`；`aio-file-operator.registry.ts:269-309,440-461`）。

Agent 配置编辑也实现了安全策略钩子：设置 `toolCallConfig` 或其点路径子项返回强制审批，注册表把它交给统一执行器；该路径可编辑，但不能用当前静态自动批准配置静默修改。是否可自动仲裁通过还受仲裁模式影响，见第 6 节（`agent-manager/services/agentManagementService.ts:103-130`；`llm-chat/llm-chat.registry.ts:271-272`）。

`ffmpeg-tools`、`skill-manager`（`skill_run_script` 的 `args` 直接拼进命令行参数）等命令类工具**没有 shell 元字符过滤**，安全性依赖 Rust 侧 `tokio::process::Command` 数组式传参、不经 shell 解释，因此不存在传统 shell 注入路径；`skill_run_script` 的 `args` 先按引号感知分词再放入参数数组（`skill_manager.rs:556-576`），仍是“进程参数传入”而非命令字符串拼接——可以传任意参数，但不能靠分号/管道逃出目标程序。

**依据**：[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`utils/agentArgs.ts`](../../aio-hub/src/utils/agentArgs.ts)、[`aio-file-operator/ARCHITECTURE.md`](../../aio-hub/src/tools/aio-file-operator/ARCHITECTURE.md)、[`aio-file-operator/utils/security.ts`](../../aio-hub/src/tools/aio-file-operator/utils/security.ts)、[`skill_manager.rs`](../../aio-hub/src-tauri/src/commands/skill_manager.rs)。

## 5. 编排循环

`useToolCallOrchestrator.orchestrate()`（`../../aio-hub/src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts:70`）是聊天场景下的最外层循环：

- **最大迭代**：默认 5，引擎兜底默认 20，两处默认值不同——`?? 5` 只在 `toolCallConfig` 整体缺失时才生效，正常配置下走 Agent 保存的 20 或用户自定义值。循环体每轮先请求 LLM 再检测工具调用，检测到调用后创建新的 assistant 节点继续下一轮（`useToolCallOrchestrator.ts:114,379-417`）。
- **串/并行**：由 `config.parallelExecution` 控制，开则同轮请求并发执行，关则串行（`executor.ts:503-526`）。审批阶段**总是先并发发起**，执行阶段才区分串并行——即使配置为串行，同一轮多个请求的**审批 UI 也会同时弹出**，只是真正执行时排队。
- **超时**：单次方法调用经 `config.timeout`（默认 30000ms）包装（`executor.ts:51-75`），超时后转为 `status: "error"` 结果，不会挂死循环；超时回调先中止底层请求再返回错误（`executor.ts:63-67,394-396`）。异步方法（`executionMode: "async"`）不受此超时限制——提交后立即返回 taskId，真正执行走任务管理器，自身没有硬超时（依赖工具内部或用户手动取消）。
- **可取消**：`ToolContext` 携带 `requestId`/`agent`/`signal`，可取消工具监听 `context.signal` 释放底层资源（IPC/文件扫描），避免外层 Promise 结束后资源空转；该约束记录在 `tool-calling/ARCHITECTURE.md` 第 10 节，分布式调用还支持 `cancel_tool` 帧与断线批量终止（声明 `capabilities.cancelTool`）。
- **取消**：审批结果三态 `approved`/`rejected`/其他，执行器只把显式 `approved` 判为通过（`executor.ts:264-266`），未显式通过（含 `undefined`）一律走拒绝回调 + `denied` 路径。
- **“静默”语义**：代码搜索仍未找到 `silent_cancelled` 字面值的实现——`tool-calling/ARCHITECTURE.md:326` 仍写“支持 approved、rejected 和 silent_cancelled”，但 `ToolApprovalResult` 类型只有 `"approved" | "rejected"`，**文档与代码不一致依然存在**。真正的“静默”是 `toolNode.metadata.isSilent`（UI 上“静默执行”开关）：它控制工具执行完成后是否继续下一轮迭代（静默或全被拒则停止），不是审批阶段的取消状态。
- **流式期间的工具事件**：工具调用检测发生在**单次 LLM 请求完整结束之后**（`responseContent = response.content`，`useToolCallOrchestrator.ts:183`），不是在流式过程中逐 token 解析；因此模型输出到一半时不会触发工具调用，必须等本轮 assistant 消息流式结束。但渲染层（`rich-text-renderer`）会在流式过程中就把未闭合的 `TOOL_REQUEST` 块渲染成"执行中"状态的 `VcpToolNode`（纯 UI 反馈，不代表真实已执行）。
- **速率限制**：`rateLimitEnabled`/`rateLimitInterval` 控制多轮迭代之间的强制等待（`useToolCallOrchestrator.ts:129-157`），按"上一次请求开始"或"上一次流结束"两种基准计算延迟，用于避免 API 速率限制被触发。

**依据**：[`llm-chat/composables/chat/useToolCallOrchestrator.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts)、[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`tool-calling/types/index.ts`](../../aio-hub/src/tools/tool-calling/types/index.ts)、[`agent-manager/types/agent.ts`](../../aio-hub/src/tools/agent-manager/types/agent.ts)、[`llm-chat/components/message-input/ToolCallingApprovalBar.vue`](../../aio-hub/src/tools/llm-chat/components/message-input/ToolCallingApprovalBar.vue)。

## 6. 审批与策略

审批状态机由 `useToolCallingStore`（Pinia，`../../aio-hub/src/tools/llm-chat/stores/toolCallingStore.ts:30`）承担，实现是一个内存数组：每条待批准请求记录 id、外部 id、会话 id、请求本体、创建/过期时间、是否用默认超时与一个 `resolve` 回调。`requestApproval()` 返回一个 Promise，只有用户批准/拒绝（含按 id 批量）或外部响应进来后调用 `resolve()` 才会结束等待；审批带超时兜底——

- 默认仍是无限等待：设置项 `uiPreferences.toolApprovalTimeoutEnabled` 默认 `false`；开启后按 `toolApprovalTimeoutSeconds`（范围 5 秒–24 小时，默认 60 秒）定时自动 `settleRequest(..., "rejected", "审批超时")`；
- 调用方可通过 `requestApproval(..., options)` 显式传 `timeoutMs`（正数）或 `null`（显式禁用），显式值不跟随全局开关变化；
- 支持 `AbortSignal`：中止/会话清理（`cancelBySession`）/窗口关闭会拒绝并清理请求，`expiresAt`/`createdAt` 供 UI 倒计时展示（审批条见 Chat UI 5.3）；
- 每次请求有独立生命周期槽（timer/signal 监听），settle 时统一清理。

自动批准匹配语义（`shouldAutoApprove()`，`executor.ts:415-427`）：
```
isGlobalAuto = config.mode === "auto"
isToolAutoApprove = config.autoApproveTools[toolId] ?? config.defaultAutoApprove
isMethodAutoApprove = config.autoApproveMethods[toolId_methodName] ?? false
return isGlobalAuto && (isMethodAutoApprove || isToolAutoApprove)
```
粒度到方法级，且方法级优先于工具级（方法级为真即可绕过工具级为假）；但 `mode === "auto"` 是全局总闸，`mode === "manual"` 时无论工具/方法级配置如何都要求人工审批。此外还有 `checkSecurityPolicy()` 返回 `status: "approve"` 的**强制审批**通道（`prepareRequestContext()` 里的 `forceApproval`，`executor.ts:165-168`），优先级高于自动批准结果（`executor.ts:234`）——工具自己声明的安全策略可以覆盖用户的自动批准设置，`aio-file-operator` 的“审批区”规则即用此机制。

**配置持久化**：`ToolCallConfig`（含 `toolToggles`/`autoApproveTools`/`methodToggles`/`autoApproveMethods`/`overrides`/`toolSettings` 六类配置项）挂在 `ChatAgent.toolCallConfig` 字段上（`../../aio-hub/src/tools/agent-manager/types/agent.ts:537`），随 Agent 配置整体写入磁盘（`persistAgent()` → `saveAgent()`）。

**审批状态不持久化**：待批准请求只存在于内存，应用重启或页面刷新即丢失；只有异步任务通过任务存储写盘（`persistImmediately()`/`persistDebounced()`），应用重启后 `markRunningTasksAsInterrupted()` 会把重启前处于 running/pending 的任务标记为 `interrupted`（`task-manager.ts:461-485`）。

静态自动批准只在全局 auto 模式与工具/方法匹配时生效；安全策略的 block 先行拒绝，approve 则跳过静态放行进入审批链。文件操作和 Agent 工具配置编辑都实现了这一钩子。这里的“强制审批”表示静态规则不能直接放行，后续仍可能经过自动仲裁，不能概括为任何场景都必须手点确认（`tool-calling/core/executor.ts:229-285`）。

无人值守场景：VCP 分布式渠道下，本地 `tool-calling` 编排被跳过（`useToolCallOrchestrator.ts:187`），审批改由 VCP 节点协议处理（本机作为节点被远端调用时），或交给 VCPToolBox 服务端自己的 `toolApprovalManager`（`approveAll`/`approvalList` 配置，支持 `::SilentReject` 后缀实现“拒绝但不通知 AI”）——**这部分无人值守策略实际发生在 VCPToolBox 侧，不在 AIO Hub 本身**，AIO 只是转发/展示审批 UI。

**AI 自动审批仲裁**：需要进入审批链的请求，按目标 Agent 的仲裁 enabled 开关决定是否调用已注入仲裁器，未启用直接人工等待。仅有配置对象并不足以启用：运行时门禁读取其 enabled 字段，配置编辑器对象存在性开关与这一值应分别核实。静态危险特征、重复升级、渠道缺失、并发上限或无效模型均升级人工；保守模式对强制审批直接转人工，激进模式才允许继续评估。普通 LLM 引擎要严格解析裁决，低风险且符合意图才可能批准，外部来源默认需人工，强制审批还要求明确授权；JEV 引擎按问卷/阈值求值。故强制审批不受静态白名单绕过，但激进仲裁仍是一条可自动批准路径（`decision-arbiter/index.ts:209-278`；`llmApproval.ts:172-193`）。

审批 store 调用注入的仲裁器，批准时直接结算，升级或判定失败时才等待人工；拒绝同样有独立结果，审计快照随请求保留。注入入口见 `stores/toolCallingStore.ts:92-97`，引擎实现位于 `src/services/decision-arbiter/`。

决策渠道与模型归全局配置，Agent 保存仲裁策略；两者的编辑与启用边界见角色笔记第 6.5 节。前台审批条、消息卡片和后台任务详情按引擎区分呈现，共享批准与拒绝语义。

**依据**：[`llm-chat/stores/toolCallingStore.ts`](../../aio-hub/src/tools/llm-chat/stores/toolCallingStore.ts)、[`src/services/decision-arbiter/`](../../aio-hub/src/services/decision-arbiter/)、[`docs/architecture/tool-approval-arbitration.md`](../../aio-hub/docs/architecture/tool-approval-arbitration.md)、[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`agent-manager/types/agent.ts`](../../aio-hub/src/tools/agent-manager/types/agent.ts)、[`tool-calling/core/async-task/task-manager.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-manager.ts)、[`aio-file-operator/utils/security.ts`](../../aio-hub/src/tools/aio-file-operator/utils/security.ts)、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)、VCPToolBox [`modules/toolApprovalManager.js`](../../VCPToolBox/modules/toolApprovalManager.js)（用于协议核实，未修改）。

## 7. 执行位置与隔离

所有本地工具方法运行在 **Tauri 前端渲染进程（WebView2/JS）**，通过 `@tauri-apps/api/core` 的 `invoke()` 调用 Rust `#[tauri::command]`。没有独立的"后端服务进程"或"沙箱子进程"承担工具执行——`tool-calling` 的 executor/parser/validator 全部是前端 TypeScript。真正跨进程边界发生在具体工具调用 Rust command 时（文件 IO、FFmpeg 子进程、脚本执行）。

- **文件类**：`aio-file-operator` 走 Tauri 的 `read_text_file_force`/`write_text_file_force`/`delete_file_to_trash` 等命令（`file_operations.rs`）。这些 Rust 命令本身不做路径策略限制，安全边界在前端 `security.ts` 的白名单/黑名单判断（第 4、9 节详述）：校验前先经 Rust 命令把目标与规则路径解析成真实路径（含符号链接），再做 `isPathWithinRoot` 边界比较。
- **外部传输专用命令**：`inspect_file_for_external_transfer`/`read_file_for_external_transfer` 是唯一在 Rust 侧再次校验沙箱/规则/大小的读取命令，专供 VCP 外部文件传输，不暴露给 Agent 工具（见第 9 节）。
- **子进程类**：FFmpeg 和 Skill 由 Rust 子进程执行。Skill 使用参数数组、以技能目录为工作目录，脚本入口做存在性和词法前缀检查；此处未先 canonicalize，不能据此认定是真实路径隔离。执行进程继承宿主权限，没有 OS 文件/网络沙箱；超时包装结束等待，但本路径未设置 kill_on_drop，也未跟踪并终止子进程树，不能把“超时返回”解释为进程已被杀死（`skill_manager.rs:565-635`）。本次只描述边界，不构造绕过或运行危险脚本。
- **平台差异（Windows）**：`ffmpeg_processor.rs` 用 `#[cfg(target_os = "windows")]` 单独设置 `CREATE_NO_WINDOW`；`skill_manager.rs` 通过公共工具函数统一隐藏子进程窗口。
- **脚本运行时解析**：优先用户显式命令，缺省 JavaScript/TypeScript 取 Bun 再 Node；Python 在 Windows 优先 python，其它平台优先 python3；Shell 按 bash、sh 探测；PowerShell 在 Windows 优先 powershell，其它平台优先 pwsh。探测不负责安装依赖，候选均不可用仍会在进程启动时报错（`skill_manager.rs:459-527`）。
- **`file://` 解析（VCP 内置工具）**：`internal_request_file` 已收紧：`parseLocalFileUrl()` 只接受格式正确的 `file://` URL，拒绝凭据/端口/查询参数/片段，拒绝 UNC 与远程主机路径（`vcpNodeProtocol.ts`）；读取改走 `inspectFileForExternalTransfer` → `readFileForExternalTransfer`（aio-file-operator 的 Rust 加固命令），在审批区要求用户审批、Rust 侧重新校验沙箱/规则/文件大小并写审计日志，另有 60 秒速率窗口（`EXTERNAL_FILE_RATE_WINDOW_MS`）。
- **`appdata://` 资产映射**：`media-generator` 等工具在资产路径拼接里使用该 scheme（`buildAgentMethods.ts:600-603`），最终由 Tauri asset protocol 或应用自己的资产解析服务映射到 `$APPDATA` 下的真实路径。
- **Capability 权限范围**：`opener:allow-open-path` 显式限制在 `$APPDATA/**` 与 `$DOWNLOAD/**`（`capabilities/default.json:11-18`），但这只管“用系统程序打开文件”，**不管 `read_file_as_base64`/`invoke` 类命令的读取范围**（这些命令走 `fs:allow-read-file` 权限，capability 配置为 `{"path": "**"}`，即无限制）。
- **网络访问范围**：Tauri `http:allow-fetch` 放开 `http://**`/`https://**`/`ws://**`/`wss://**`（`capabilities/default.json:79-88`），渲染进程可对任意主机发起 HTTP/WS 请求；`web-distillery`、`vcp-connector` 都依赖此权限，Tauri capability 层没有域名白名单。

**依据**：[`src-tauri/capabilities/default.json`](../../aio-hub/src-tauri/capabilities/default.json)、[`src-tauri/src/commands/file_operations.rs`](../../aio-hub/src-tauri/src/commands/file_operations.rs)、[`src-tauri/src/commands/ffmpeg_processor.rs`](../../aio-hub/src-tauri/src/commands/ffmpeg_processor.rs)、[`src-tauri/src/commands/skill_manager.rs`](../../aio-hub/src-tauri/src/commands/skill_manager.rs)、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)、[`vcp-connector/docs/internal-file-request.md`](../../aio-hub/src/tools/vcp-connector/docs/internal-file-request.md)、[`media-generator/services/buildAgentMethods.ts`](../../aio-hub/src/tools/media-generator/services/buildAgentMethods.ts)。

## 8. 结果处理与回注

结果格式统一为字符串（`ToolExecutionResult.result`）。executor 对非字符串返回值自动序列化（`executor.ts:387-388`）。工具可返回 `{ result, executionMetadata }` 信封：`result` 面向 LLM 回注，`executionMetadata` 进入结果元数据（可用于审计来源/实际策略/降级原因）；带 `code` 的异常记录为结构化 `failureType`（`executor.ts:430-433`）。三种失败形态：

- `denied`：审批拒绝或安全策略死区拦截，`result` 为固定提示文案（`"工具调用被拒绝：用户未授权"` 或策略自定义的 `blockMessage`）。
- `error`：方法抛异常、超时、工具/方法不存在、`agentCallable` 校验失败，`result` 为异常的 `message` 或错误描述字符串。
- `success`：包括异步任务提交成功（`result` 是 `{ type: "async_task", taskId, message }` 的 JSON 字符串，不代表任务真正完成）。

**没有截断机制**：结果格式化（VCP 协议实现，`vcp-protocol.ts:403-423`）直接把工具返回值原文拼进汇总文本块，**不限制长度**。工具返回超大字符串（如 `directory-tree` 扫描大目录、`dir-search` 全文搜索）会整段回注下一轮请求，可能撑爆上下文窗口或触发 API 报错；是否截断完全取决于各工具自己（如 `dir-search` 有 `maxDisplayFiles`/`maxMatchesPerFile` 参数做结果层面截断，但那是工具自愿实现，不是框架强制）。

多模态结果：框架层没有专门的多模态结果通道；`media-generator` 返回资产路径字符串（`appdata://` scheme），依赖渲染层/宏展开机制在正文里解析成图片；`internal_request_file` 返回的是 `{ fileData: base64, mimeType }` 结构（走 VCP 分布式协议，不进入本地 `ToolExecutionResult.result` 字符串通道）。

能否污染后续上下文：**能**。工具结果原文（包括错误信息、拒绝提示）都会作为新的 `role: "tool"` 消息节点持久化并进入下一轮上下文（`useToolCallOrchestrator.ts:316-353`）。如果工具返回内容本身包含类似 VCP 协议标记的文本（例如某网页内容里恰好含 `<<<[TOOL_REQUEST]>>>` 字面文本），会被渲染层的 Tokenizer 解析为新的工具调用块 UI（见第 13 节交叉点），存在"结果注入触发下一轮误解析"的潜在风险，但**这只影响渲染展示**，不会被 `tool-calling` 引擎重新解析执行（引擎只解析 LLM 自己产生的 assistant 文本，不会重新扫描 tool 角色消息）。

**依据**：[`tool-calling/core/executor.ts`](../../aio-hub/src/tools/tool-calling/core/executor.ts)、[`tool-calling/core/protocols/vcp-protocol.ts`](../../aio-hub/src/tools/tool-calling/core/protocols/vcp-protocol.ts)、[`llm-chat/composables/chat/useToolCallOrchestrator.ts`](../../aio-hub/src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts)、[`dir-search/dir-search.registry.ts`](../../aio-hub/src/tools/dir-search/dir-search.registry.ts)。

## 9. 内建工具完整清单

以 `grep agentCallable: true` 结果为准（`../../aio-hub/src/tools/**/*.registry.ts` 及相关 service），逐个列出。"执行位置"标注最终落地的运行环境；"审批"标注默认是否受统一审批状态机管理（不含工具自身 `checkSecurityPolicy` 之外的隐藏逻辑）。

| 工具 ID | 方法 | 用途 | 执行位置 | 需审批（默认 manual 模式下） | 边界说明 |
|---|---|---|---|---|---|
| `aio-file-operator` | `read_file`/`write_file`/`append_file`/`delete_file`/`copy_file`/`move_file`/`list_directory`/`apply_diff`/`create_directory`/`path_exists` | 本地文件读写、目录操作、Diff 修改 | 前端 + Tauri `file_operations.rs`（普通 force 命令无 Rust 侧路径限制；专用外部传输命令在 Rust 侧复校验） | 是（受 `checkSecurityPolicy` 白名单/死区/审批区三态影响） | 沙箱已加固——前端经 `resolve_path_for_security` 解析真实路径（符号链接）后按 `isPathWithinRoot` 边界判断，白名单/规则路径同样解析；`delete_file` 走回收站尚可恢复；复制/移动的源和目标均校验，目录操作另有 Rust 递归检查 |
| `retrieval` | `search`（Recall/Knowledge/mixed 模式主动检索） | 按 Agent 授权主动检索内容 | 前端 + Recall/Knowledge 检索服务 | 是 | 与 `recall-basic` 的占位符即时召回不同，这是显式检索工具（参数规范化后按授权集合过滤） |
| `directory-tree` | `generateTree` | 生成目录树（过滤/深度/大小统计） | 前端 + Tauri | 是 | 无路径沙箱，可枚举任意可达目录结构（只读，非破坏性） |
| `dir-search` | `searchDirectory`/`replaceInDirectory` | 全文搜索/正则批量替换文件内容 | 前端 + Tauri（流式 batch 事件） | 是 | Agent 搜索路径带硬资源限制——`maxDepth` 默认 5（上限 20）、最多扫描 50,000 个文件/2GB、30 秒截止、结果上限 10,000、上下文行上限 20（`actions.ts` 的 `AGENT_*` 常量），并绑定 `dir_search_cancel` 取消生命周期（AbortSignal→Rust 取消）；`replaceInDirectory` 直接改磁盘文件且**不可撤销**（方法描述里自己标注了"⚠️ 此操作会直接修改磁盘文件，不可撤销"），无路径沙箱 |
| `directory-janitor` | `scanDirectory`/`cleanupItems`/`scanAndCleanup` | 扫描并清理过期/大文件（移入回收站） | 前端 + Tauri (`analyze_directory_for_cleanup`/`cleanup_items`) | 是 | 无独立路径沙箱，`scanAndCleanup` 一步到位自动清理扫描到的所有项 |
| `content-deduplicator` | `scanDuplicates` | 扫描目录查重（精确/规范化匹配） | 前端 + Tauri | 是 | 只读扫描；无路径沙箱 |
| `git-analyzer` | `getFormattedAnalysis`/`getAuthorCommits`/`getCommitDetail`/`getBranchList` | Git 仓库统计分析 | 前端 + Tauri（git2 库或子进程） | 是 | 只读操作 |
| `ffmpeg-tools` | `executeCommand`/`executePipeline`/`getMediaInfo` | 任意 FFmpeg 命令编排、媒体信息读取 | 前端 + Tauri 子进程（`tokio::process::Command`，数组式参数，非 shell） | 是（异步任务，需先提交任务） | `executeCommand`/`executePipeline` 允许 LLM 拼接**任意 FFmpeg CLI 参数数组**（如 `-f concat` 类可能读取任意路径的滤镜/协议参数），属于命令参数层面的高自由度，需 `hwaccel`/`args` 组合审查 |
| `text-diff` | `generatePatch` | 生成统一 diff 补丁（不写盘） | 纯前端 | 是（一般会配自动批准，因为无副作用） | 无副作用（不读写文件） |
| `json-formatter` | `formatJson` | JSON 格式化（支持 `filePath` 读取本地文件） | 前端 + Tauri（`filePath` 分支读盘） | 是 | `filePath` 无路径沙箱，可读任意可达路径下的文件内容并整段返回给模型 |
| `data-filter` | `applyFilter` | JSON/YAML 数组过滤（UI 界面路径支持 `customScript` 自定义脚本条件） | 纯前端 JS（`new Function` 动态构造，运行在渲染进程主上下文，**已确认**） | 是 | **Agent 路径已隔离自定义脚本**——`parseFilterOptions()` 对 `operator: "custom"` 或含 `customScript` 字段的 conditions 直接返回错误"Agent 调用不支持 custom 操作符或 customScript"，只允许声明式操作符白名单（eq/ne/contains/truthy/falsy/gt/ge/lt/le）；`new Function` 执行只保留在**用户手动操作**的 DataFilter.vue 界面路径，LLM 生成的 VCP 参数不再能触发任意 JS。`applyFilter` 的方法描述同步改为"Agent 路径禁止 custom/customScript" |
| `media-info-reader` | `readImageMetadata` | 提取 AI 生图/角色卡元数据 | 前端（`@tauri-apps/plugin-fs` 读文件） | 是 | 无路径沙箱，只读 |
| `media-generator` | `generate_<model_id>`（动态，每个可用模型一个） | 调用配置好的图片/视频/语音/音乐生成模型 | 前端 + 远程模型 API（走用户配置的 LLM Profile） | 是（`isFast` 模型走 sync 立即返回，其余走 async 任务） | 生成资源消耗真实 API 额度；`prompt` 完全由 LLM 控制，无内容过滤 |
| `web-distillery` | `quickFetch`/`smartExtract` | 网页内容抽取（HTTP 直取 / 真实浏览器渲染） | 前端 + Tauri HTTP fetch 或内嵌浏览器实例 | 是 | `url` 参数无域名/协议白名单，可对任意地址发起请求（`http:allow-fetch` 权限本身放开 `http://**`/`https://**` 及局域网 IP 正则） |
| `web-canvas` | `read_canvas_file`/`apply_canvas_diff`/`write_canvas_file`/`commit_changes`/`discard_changes`/`list_canvas_files`/`create_canvas`/`clear_runtime_errors`（`open_window` 显式 `agentCallable:false`） | Agent 协作画布：多文件读写、Git 提交/丢弃、HTML 预览 | 前端 + 本地 Git 仓库（`GitInternalService`）+ iframe 预览 | 是（`apply_canvas_diff`/`write_canvas_file` 走 `onToolCallPreview` 内存覆盖层：审批前不写物理文件，批准后才执行；拒绝只移除候选层，不用 Git checkout 覆盖已有未提交修改） | 画布预览可执行 HTML/JS；iframe 仅 allow-scripts，使用 opaque origin 并校验消息来源，CSP 仍保留网络访问，边界见生成式输出与运行时第 7 节 |
| `recall`（`recall-basic`/`recall-admin`） | `searchEntries`/`upsertEntry`/`updateEntryContent`；`listRecallCollections`/`listEntriesMetadata`/`batchUpdateMetadata`/`deleteEntry` | 结构化知识库/记忆的检索与管理 | 前端 + 本地存储/向量库 | 是（`deleteEntry` 要求显式 `confirm` 参数） | `recall-admin` 可批量改元数据、删除条目；模型自己写入的条目后续又会被当作检索结果召回 |
| `skill:system`（`SkillManagerProxy`） | `skill_run_script`/`skill_read_file`/`skill_list_dir`；`activate_<skillName>`（动态） | 执行已安装 Skill 的私有脚本 / 读取资源 / 激活技能说明 | 前端 + Rust 启动本机脚本进程（入口存在性/词法前缀校验，非 OS 沙箱） | 是 | `skill_run_script` 本质是**受限的任意脚本执行**（js/ts/py/sh/ps1），影响取决于已安装 Skill 的来源信任度；env 变量可被 Skill 配置注入 |
| `git-committer` | 无 `agentCallable` 方法 | 纯 UI 工具，不对 Agent 暴露 | — | — | 不适用（消息渲染器笔记范围外的 UI 功能，已用 grep 确认无 `agentCallable: true`） |
| `symlink-mover` | 无 `agentCallable` 方法 | 纯 UI 工具 | — | — | 不适用 |
| `window-automator` | 无 `agentCallable` 方法（`runMode: "any"` 但未见 `getMetadata`） | 窗口自动化（点击/取色/截图/OCR），仅供人工在 UI 中编排动作流 | — | — | 不适用（未发现 Agent 可调用接口，属于纯 UI 功能，未列入 Agent 工具范围） |
| `llm-chat`（主实例） | 无 `agentCallable` 方法（`addContentToInput` 等是给其它工具跨模块调用的编程接口，非 LLM 直接可调用） | 输入框/附件/会话编程接口 | 前端 | — | 不计入 Agent 工具（`getMetadata()` 未定义，`services/executor.ts` 的 `execute()` 可被其他工具内部调用，但不出现在 VCP Prompt 里） |
| `llm-chat-agent-mgmt`（`llm-chat.registry.ts` 中的 `agentManagement` 实例） | `list_agents`/`search_agents`/`read_agent_config`/`export_agent_as_text`/`set_agent_field`/`find_replace_in_presets`/`add_preset_message`/`delete_preset_message`/`move_preset_message`/`import_agent_from_text` | 让 Agent 自己管理/编辑其他 Agent（或自身）的配置、预设消息 | 前端 + 本地 Agent 配置文件持久化 | 是 | 支持辅助编辑自身/其它 Agent 配置；字段黑名单之外还对 toolCallConfig 及点路径子项返回强制审批，无法仅凭当前静态自动批准配置静默修改权限。该钩子属于模型工具调用路径，普通用户配置编辑有独立交互语义。 |
| `tool-calling`（自身） | `getTaskStatus` 等（异步任务查询/取消接口） | 查询/管理异步任务状态 | 前端 | 视具体方法而定 | 属于框架自省能力 |
| `sub-agent` | `list_available_agents`/`ask`/`get_task_status`/`get_task_activity`/`send_task_message`/`cancel_task` | 委派子智能体独立对话、查询任务状态与活动、追加指导、叫停 | 主 WebView 异步链 + 标准子会话真实推理 | 是（子任务工具调用同样进审批 store，后台任务详情可接管审批） | 委派目标必须先在 Agent 的 `subAgentConfig` 中启用；子任务拥有自己的一轮上下文与审批线，结果以任务消息回到父会话，父 Agent 不直接看到子会话全部细节 |
| `vcp:<pluginName>`（`VcpToolProxy`，动态，数量随远端 manifest） | 远端插件的每个 `command` | 桥接 VCPToolBox 插件到本地 Agent（如浏览器控制、检索、图像生成等，取决于远端启用的插件） | **远端** VCPToolBox/分布式节点（AIO 仅转发请求与展示审批） | 是（`onBeforeExecute` 走同一本地审批 store，但真正执行在远端，本地无法进一步限制远端行为） | 信任边界完全转移给远端节点；`getMetadata()` 对所有映射命令强制 `agentCallable: true`，没有方法级白名单二次过滤 |
| `internal_request_file`（VCP 内置，非 `ToolRegistry` 注册，硬编码在 `vcpNodeProtocol.ts`） | 读取本机 `file://` 路径文件并转 Base64 回传远端 | 支持 VCPToolBox"超栈追踪"跨节点文件获取 | 前端 + Tauri `inspect_file_for_external_transfer`/`read_file_for_external_transfer`（不再直连无限制的 `read_file_as_base64`） | **部分**：文件位于 aio-file-operator 白名单内（policy=allow）时直接读取；位于审批区（policy=approve）时经 `toolCallingStore` 以 `vcp-external-file-transfer` 工具 ID 发起用户审批，拒绝则中止；另有 60 秒速率窗口与审计日志 | 只接受格式正确的 `file://` URL（拒绝凭据/端口/查询/片段与 UNC/远程主机路径），Rust 侧重新校验沙箱/规则/文件大小后才返回内容；沙箱之外的目录（非白名单且非审批区）会被 Rust 侧拦截，不能无审批读取任意文件 |

**依据**：所有 `agentCallable: true` 命中文件（见附录逐一 Read 记录）、[`vcp-connector/composables/useVcpDistributedNode.ts`](../../aio-hub/src/tools/vcp-connector/composables/useVcpDistributedNode.ts)（`BUILTIN_VCP_TOOLS` 常量）、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)（`handleExecuteTool`/`handleInternalRequestFile`）、[`agent-manager/services/agentManagementService.ts`](../../aio-hub/src/tools/agent-manager/services/agentManagementService.ts)（`FIELD_BLACKLIST`）、[`data-filter/logic/dataFilter.logic.ts`](../../aio-hub/src/tools/data-filter/logic/dataFilter.logic.ts)。

### 9.1 本地媒体工具结果与分布式回传

文件读取等方法可返回结构化本地媒体引用，和文本结果一起交给聊天层；引用进入工具消息后，在后续请求中转换为多模态附件，执行器自身不把媒体二进制塞进结果字符串。分布式节点则需要进一步物化：识别返回值中的 localMedia，经独立外传文件规则/审批重新读取，确认 MIME 仍为图片、音频或视频，再生成带 MIME 的 data URL 内容；本地发送许可不会自动变成外传许可（`vcp-connector/services/vcpNodeProtocol.ts:469-520`）。

服务端消费顶层 content，混合批次因此按调用顺序平铺文本与媒体。该回传依赖现有连接和外传边界，未知媒体类型或中止信号会结算错误，不把本地路径直接交给远端当作可读取文件（同文件 `:545-600`）。

## 10. 扩展机制

扩展轴有两条，互相正交：**协议扩展**决定模型如何描述调用，**能力扩展**决定有哪些工具和上下文进入系统。前者目前只有 VCP 实现；后者已经有四条实际入口：

1. **`ToolRegistry`/`ToolRegistryFactory`**：`ToolRegistry` 是所有可调用能力的统一边界；既可由 `import.meta.glob` 发现随源码打包的 registry，也可由 factory 在运行期批量生成实例。内建工具与动态桥接都能落到这一接口，不能把 `ToolRegistryFactory` 仅理解为“内建工具”。
2. **`AgentExtension`**：`ToolRegistry` 的基接口，不提供可调用方法，只提供只读上下文注入（如 `web-canvas` 的 Canvas 文件树、`skill:system` 的宿主环境信息），入口为 `getExtraPromptContext()`。生命周期：注册时初始化、注销/热重载时销毁，由 `ToolRegistryManager` 统一调度（`services/registry.ts:102-115`）。
3. **JS/Sidecar/Native 插件系统（`plugin-loader.ts`/`plugin-manager.ts`）**：这是与 `tool-calling` 平行、更底层的扩展体系，本身**不是 Agent 工具协议的一部分**，但插件可以注册 `ToolRegistry` 从而进入 Agent 可调用范围。三种类型信任模型不同：
   - **JS 插件**：生产模式用 `convertFileSrc()` + 动态 `import()` 加载 `$APPDATA/plugins/<id>/` 下的模块（`plugin-loader.ts:404-431`），**在渲染进程主上下文执行，与内建工具同权限**，能访问 Tauri 内部 API、Pinia store、工具注册表等一切全局对象；开发模式还额外扫描项目根 `/plugins/*/index.ts`。
   - **Sidecar 插件**：外部可执行文件，按 `manifest.sidecar.executable[currentPlatform]` 配置路径启动，跨进程边界更明确，但本次未深入其 IPC 协议。
   - **Native 插件**：按平台加载动态库（`manifest.native.library[currentPlatform]`），是最高权限、最少隔离的扩展形式。
   - **兼容性校验**（`validatePluginCompatibility()`）：引入结构化诊断（`PluginDiagnostic`，字段 code/title/severity/resolution），严重问题记 `hardErrors` 并置 `proxy.isBroken = true`。调用点注释仍写“仅提示，不阻止加载”，但 API v3 插件（`apiVersion >= 3` 且 `requiresStrictPluginCompatibility`）会触发严格检查——应用版本范围无效、API 版本不兼容、平台二进制缺失等成为 hard error（版本常量见 `plugin-api-version.ts`：`CURRENT_PLUGIN_API_VERSION = 3`、`CURRENT_SIDECAR_PROTOCOL_VERSION = 3`；`plugin-loader.ts` 用 `@tauri-apps/plugin-os` 的真实 OS/arch 替换 navigator 嗅探）。加载不被阻止，但 broken 标记与诊断会落到插件对象上，是否执行取决于消费方；
   - 插件卸载 `uninstall_plugin` 走回收站（可恢复），`-dev` 后缀插件（开发模式加载）不允许通过 UI 卸载。
4. **VCP Proxy（`VcpToolProxy`/`VcpBridgeFactory`）**：把远端 HTTP/WS 服务的能力映射为本地 `ToolRegistry`，信任边界完全转移到远端节点，AIO 自身只做协议转换，见第 12 节。

协议轴则由 `ToolCallingProtocol` 承担。增加新协议需要实现四个转换方法，并修改发现服务的 `SUPPORTED_PROTOCOLS`、Composable 的 `resolveProtocol()` 和 Agent 配置类型。这个边界已经把 VCP 细节从 parser/engine/executor 中抽离，但注册过程仍是源码内硬编码，当前不能由上述 JS/Sidecar/Native 插件动态添加一种协议。总体上，**AIO 已搭好多协议、异构工具来源和动态上下文的统一骨架，其中工具来源已经多样化，模型调用协议暂时只交付了 VCP。**

**依据**：[`services/plugin-loader.ts`](../../aio-hub/src/services/plugin-loader.ts)、[`services/plugin-manager.ts`](../../aio-hub/src/services/plugin-manager.ts)、[`services/types.ts`](../../aio-hub/src/services/types.ts)（`AgentExtension`/`ToolRegistryFactory`）、[`vcp-connector/services/VcpBridgeFactory.ts`](../../aio-hub/src/tools/vcp-connector/services/VcpBridgeFactory.ts)。

## 11. 子 Agent 与任务委派

**agent-as-tool 已落地**：`src/tools/sub-agent`（工具 ID `sub-agent`）把"调用另一个 Agent 独立对话"实现成标准工具，六个可调用方法覆盖发现、委派、观测、追加指导与叫停：

| 方法 | 作用 |
|---|---|
| `list_available_agents` | 列出可委派的子智能体 |
| `ask` | 缺省等待子会话结果；background 模式立即返回任务句柄 |
| `get_task_status` | 查询任务状态 |
| `get_task_activity` | 查看任务活动时间轴 |
| `send_task_message` | 沿子会话执行车道追加消息并持久化，不自动发起新一轮 |
| `cancel_task` | 紧急叫停 |

它取代了此前"只有 Agent 配置编辑、没有 Agent 调用"的能力空白：

- **双轨数据**：子会话的聊天数据仍是标准 `ChatSessionDetail`，由 llm-chat 写入；任务调度、状态机与进度由 `BackgroundTaskRegistry` 独立维护（`src/services/background-tasks/registry.ts`），并通过 `approvalBridge.ts` 把子会话的待审批请求关联回任务。
- **后台归属**：background 模式在主 WebView 里启动不阻塞父调用的异步链，显式指定 detached 子会话发送，不切换主会话；同一子会话的 Promise 车道串行生成，繁忙时新任务状态为 queued。独立 background-runtime 的 dispatch 当前只实现 ping/getInfo，未承接子Agent runner，不能据此断言关闭主窗口后继续执行（`sub-agent.registry.ts:1020-1141`；`src/background-runtime/main.ts:27-49`）。
- **追加与取消**：追加指导先校验任务归属，等待同一执行车道后重新读取子会话，把消息挂在当时叶子并保存，返回 append_only；兼容 delivery 字段没有产生安全点消费或自动下一轮的保证。独立 deliveryQueue 有队列、执行链和通知的数据模型，但本方法不走其消费 runner。取消通过 registry 订阅中止子会话并清待审批；终态取消幂等（`sub-agent.registry.ts:1304-1342,1426-1519,1552-1600`）。
- **审批闭环**：子任务的工具调用仍走统一审批入口，后台任务承接人工审批与仲裁状态回放；`BackgroundTaskApprovalBridge` 用子会话 + 执行车道解析 `taskId`，无法唯一确定时不强行关联。
- **目标、模型和深度**：入口按需释出内置基线，目标必须开启允许被调用。允许同 ID 分身但受传递的委派深度上限控制；模型解析按 prefer_self/inherit_caller 选择单一绑定组，所选不可用即报错，没有跨组自动回退（`sub-agent.registry.ts:715-762`；`services/subAgentModelResolver.ts:19-30`）。
- **恢复与可观测性**：快照含当前操作、最近 8 条活动与最多 10 条审批审计，持久任务最多 50 项；启动把非终态标为 interrupted/stale，保留结果与子会话定位，未接自动继续推理。运行时执行归属登记到共享 registry，审批桥接仅在能唯一识别执行任务时绑定，排队任务不会抢走同会话审批归属（`services/background-tasks/registry.ts:55-65,737-807`；`sub-agent.registry.ts:329-362`）。

**后台任务**：`tool-calling/core/async-task` 仍是工具层异步任务机制，服务于 `executionMode: "async"` 的方法（`ffmpeg-tools`、非 fast 模式的 `media-generator`）。任务状态机为 `pending -> running -> completed/failed/cancelled/interrupted`，结果持久化到磁盘，支持取消、重试（仅限 failed/interrupted 状态）与进度上报。应用重启后运行中的任务会被标记为 `interrupted`，不会自动恢复执行。它与 sub-agent 的后台任务是两套：前者按工具方法粒度提交，后者按子智能体会话粒度调度；两者都复用审批 store，但持久化文件不同。

**依据**：[`sub-agent/ARCHITECTURE.md`](../../aio-hub/src/tools/sub-agent/ARCHITECTURE.md)、[`sub-agent/sub-agent.registry.ts`](../../aio-hub/src/tools/sub-agent/sub-agent.registry.ts)、[`services/background-tasks/`](../../aio-hub/src/services/background-tasks/)（`registry.ts`、`approvalBridge.ts`、`deliveryQueue.ts`）、[`background-runtime/`](../../aio-hub/src/background-runtime/)、[`tool-calling/core/async-task/task-manager.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-manager.ts)。

**定时任务**：`ToolRegistry.startupConfig`/`onStartup()` 是唯一的"启动时自动执行"钩子（当前仅 `vcp-connector` 使用，实现启动自动连接），**没有 cron/定时循环调度机制**用于周期性触发 Agent 工具。

**引用与执行分离**：转义请求标记只在参数中表达请求字面量，不会被展开为额外独立调用。一个标准块可用数字后缀拆成多条平级请求；运行时递归委派则是 sub-agent 工具自身的执行能力，受深度链控制。服务端工具结果批次先被遮蔽，结果里的请求示例不进入本地执行扫描（`vcp-protocol.ts:358-427`）。

**依据**：[`tool-calling/core/async-task/task-manager.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-manager.ts)、[`tool-calling/core/async-task/task-executor.ts`](../../aio-hub/src/tools/tool-calling/core/async-task/task-executor.ts)、[`vcp-connector/vcp-connector.registry.ts`](../../aio-hub/src/tools/vcp-connector/vcp-connector.registry.ts)、[`services/types.ts`](../../aio-hub/src/services/types.ts)（`startupConfig`/`onStartup`）。

## 12. 与 VCPToolBox 的真实联动

已结合 `VCPToolBox` 当前工作树源码核实，AIO 与 VCPToolBox 之间是**双向对等的 WebSocket 协议契约**，非单向调用：

**AIO 作为客户端（拉取远端能力）**：
- `VcpBridgeFactory.refreshManifests()` 发送 `get_vcp_manifests`（带 `requestId`、`client: "aio-hub"`、`features: ["configSchema"]`），VCPToolBox 侧响应 `vcp_manifest_response`。
- 收到的每个远端插件 manifest 被 `VcpToolProxy` 包装成本地 `ToolRegistry`，其 `getMetadata()` **对所有映射命令强制 `agentCallable: true`**（`VcpToolProxy.ts:119`）——本地没有二次过滤远端命令的白名单机制，影响面完全取决于远端 VCPToolBox 启用了哪些插件。
- 执行走 `execute_vcp_tool` 请求 -> VCPToolBox 侧路由到具体插件 -> `tool_result` 响应（`VcpBridgeFactory.executeRemote()`，30 秒本地超时）。

**AIO 作为分布式节点（暴露本机能力）**：
- 已与 VCPToolBox `WebSocketServer.js:729`（`register_tools` 分支）核实：AIO 发送的 `register_tools` 会被存入 `distributedServers`，并**显式过滤掉 `internal_request_file`**（服务端按工具名做不等过滤），确认它确实是协议层专属能力，不会出现在插件列表 UI 里，但仍可被服务端通过 `execute_tool` 直接调用。
- VCPToolBox 侧 `execute_tool` 消息经 `executeDistributedTool()` 按 `serverId`/`serverName` 查找已连接节点并转发（`WebSocketServer.js:866-896`），超时按插件 manifest 的 `communication.timeout` 或默认 60000ms。
- 本地暴露规则（`useVcpDistributedNode.ts:discoverTools()`）：自动模式暴露所有 `agentCallable === true || distributedExposed === true` 且未被禁用的方法；手动模式按 `exposedToolIds` 白名单；**排除 `vcp:` 前缀工具**（防止把桥接进来的远端工具二次暴露回去形成循环）。
- 审批协议往返（AIO 与 VCPToolBox 双侧代码已核实一致）：VCPToolBox 的 `toolApprovalManager.getApprovalDecision()` 命中规则后发 `tool_approval_request`（含 `requestId`/`toolName`/`args`/`maid`）；AIO `vcpNodeProtocol.handleToolApprovalRequest()` 把它转成本地请求塞进审批 store（`sessionId = "vcp-" + maid`），用户点允许/拒绝后回传 `tool_approval_response`。VCPToolBox 侧默认 `timeoutMinutes = 5`；AIO 侧本地审批支持可配置超时（默认关闭，见第 6 节），不再存在“一边有超时一边永久挂起”的差异。
- VCP 文本协议支持**索引化批量调用**——`splitIndexedToolArgs()` 把 `command1/path1, command2/path2` 这类数字后缀参数拆成多个独立调用，每个调用分配 `requestId_1/requestId_2...`（`vcpNodeProtocol.ts`）。
- 渠道判定：`useIsVcpChannel` 从“API baseUrl 与 wsUrl 同主机启发式”改为 `resolveChannelToolHandling`（`llm-chat/core/tool-calling/channel-tool-handling.ts`）：LLM Profile 显式 `toolHandling` 声明（`callConsumer`/`upstreamProtocol`/`aioDistributedExposure`）优先，未声明的旧 Profile 保留同主机启发式回退。

**能力映射与排除规则总结**：`internal_request_file` 是唯一的协议级强制内置工具，不经 `agentCallable` 判定；它**受 aio-file-operator 沙箱与审批区约束**（白名单直读、审批区需用户审批、Rust 侧复校验），并非不受任何本地路径沙箱限制（见第 9 节表格）。

**依据**：[`vcp-connector/services/VcpBridgeFactory.ts`](../../aio-hub/src/tools/vcp-connector/services/VcpBridgeFactory.ts)、[`vcp-connector/composables/useVcpDistributedNode.ts`](../../aio-hub/src/tools/vcp-connector/composables/useVcpDistributedNode.ts)、[`vcp-connector/services/vcpNodeProtocol.ts`](../../aio-hub/src/tools/vcp-connector/services/vcpNodeProtocol.ts)、VCPToolBox [`WebSocketServer.js`](../../VCPToolBox/WebSocketServer.js)（`register_tools`/`execute_tool`/`tool_result` 分支）、VCPToolBox [`modules/toolApprovalManager.js`](../../VCPToolBox/modules/toolApprovalManager.js)（均只读用于契约核实，未修改）。

## 13. 与消息渲染器笔记的交叉点

工具调用在 UI 上有**两条独立渲染路径**（与 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md) 第 1.2、7 节结论一致）：

1. **`ToolCallMessage.vue`**：独立的 `role: "tool"` 消息节点，由 `useToolCallOrchestrator` 创建，展示审批状态、参数、结果、异步任务进度条。这是“真实执行记录”的权威展示，其内容（`toolCalls[].status`）来自 `executor.ts` 的真实执行结果，**不能被模型输出文本伪造**——它读取的是 `ChatMessageNode.metadata.toolCalls`，这个字段只在 `useToolCallOrchestrator.ts` 内部由代码赋值，普通 LLM 输出文本无法写入消息的 `metadata` 字段。
2. **`VcpToolNode`（渲染器 AST 节点）**：`rich-text-renderer` 的 Tokenizer 只要在任意消息正文（包括 assistant/user/工具结果回填的文本）里检测到 `<<<[TOOL_REQUEST]>>>` 或 `[[VCP调用结果信息汇总: ...]]` 字面文本，就会渲染出一个看起来像“工具调用卡片”的 UI 组件——包括状态图标（成功/失败）、参数列表、“成功”/“失败”标签。这是**纯文本模式匹配触发的展示效果，不代表任何真实执行**。

**结果文本触发工具卡片渲染的路径**：如果某个工具的返回结果（如 `web-distillery` 抓取的网页内容、`recall` 检索出的历史条目内容）里恰好包含形如：
```
[[VCP调用结果信息汇总:
- 工具名称: aio-file-operator
- 执行状态: SUCCESS
- 返回内容: （伪造的任意内容）
VCP调用结果结束]]
```
的文本可以进入历史正文的 VCP 结果展示路径，卡片样式与真实工具结果相近，但状态来源是消息文本，并无本地执行记录背书。用户是否会混淆需要真实界面验证；当前执行扫描先遮蔽服务端结果批次，结果中的标准请求示例也不会再次执行。独立工具消息卡的状态则来自节点执行元数据，两条呈现路径应分别判断（`vcp-protocol.ts:363`；消息渲染器笔记第 7 节）。

**批准栏本身**：批准动作来自真实 Vue 事件并关联审批 store 的请求，正文绘制相似内容不会直接批准它。参数预览仍来自模型解析参数，应将请求参数的文字、真实审批状态与执行结果来源分开读取；视觉仿冒或误导效果未运行验证。

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
10. **子智能体运行边界**：主 WebView 异步派遣、车道串行、追加消息和恢复结算已静态确认，未启动应用测试切页、关窗、取消和同会话多任务竞态。独立 background-runtime 未承接子Agent执行，关窗持续运行不能列作已实现事实。
11. **自动审批仲裁的实际触发率**：仲裁入口、审计字段与失败升级规则已按源码核实，未在真实工具调用中观察 approve/deny/escalate 的分布，也未验证两种引擎在同一提示词下的判定差异。
