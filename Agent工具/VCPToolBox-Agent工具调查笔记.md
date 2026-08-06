# VCPToolBox Agent 工具运行时调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-07-30
>
> 代码快照：`eca06251f5687a52fbcd353cb8b04f42157882d0`（分支：`main`）
>
> 调查方式：只读源码梳理（`server.js`、`Plugin.js`、`WebSocketServer.js`、`modules/vcpLoop/*`、`modules/toolApprovalManager.js`、`Plugin/*`、`docs/*`），未修改本仓库任何文件
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

参照笔记：本笔记为 [Agent 工具横向调查与对比](Agent工具横向对比.md) 的 VCPToolBox 单项目复核依据。

## 结论摘要

VCPToolBox 是 VCP 生态里唯一真正执行工具、转发分布式调用并托管审批状态机的服务端。核心事实：

1. VCP 文本协议的解析不是简单正则，而是带模糊匹配开关（`fuzzyToolMatching`）的状态机扫描器；默认严格模式只认精确的 `<<<[TOOL_REQUEST]>>>` / `「始」...「末」`，开启模糊模式后能容忍 `{始}`、`<<[TOOL_REQUEST]>>` 等变体，这是一个需要谨慎评估的“协议宽松开关”。
2. 审批系统是本项目安全模型的核心，但存在**结构性 fail-open**：审批请求依赖 `webSocketServer` 存在且当时至少有人/终端连接；超时后的默认行为是**拒绝执行**（reject，不是自动通过），因此不是传统意义的 fail-open。但如果 `WebSocketServer` 未初始化，则在判定需要审批的那一刻直接抛错拒绝执行——这一点上是安全的。真正的风险点在于：审批请求通过 WebSocket **广播**给所有已认证的 `VCPLog` 客户端，任何持有同一个全局 `VCP_Key` 的客户端都可以发送 `tool_approval_response` 批准或拒绝任意请求，审批身份没有绑定发起者、没有二次身份区分“谁有权批准”。
3. `requiresAdmin` 不是纯声明字段：对 `stdio` 插件会被注入 `DECRYPTED_AUTH_CODE` 环境变量，插件自己必须在内部比对；对 `hybridservice`/`direct` 插件会通过 `directContext.decryptedAuthCode` 传入。两条路径都要求插件自己做比对——**主服务端本身不会因为 requiresAdmin 而拒绝调用**，实际执行权掌握在插件代码手中。已确认 `PowerShellExecutor`、`LinuxShellExecutor`、`PluginManager` 插件内部确实做了比对，但这是插件自律，不是框架强制。
4. 分布式节点鉴权只有一层全局 `VCP_Key`（WebSocket 升级时校验），没有节点级别的独立密钥或证书；`register_tools` 消息可以让任意已连接的分布式节点注册新工具，但**同名工具会被跳过**（不能覆盖已存在工具），一定程度上防止了工具名冒充，但没有防止“注册一个从未存在过的、诱导性命名”的工具（如 `FileOperator2`）来钓鱼。
5. Shell/命令类插件的安全边界差异巨大：`PowerShellExecutor` 只有关键字黑名单 + 关键字驱动的验证码要求，没有语法级校验，命令拼接后直接 `Invoke-Expression`，理论上存在关键字绕过空间（如变量拼接、编码回避黑名单字符串匹配）；`LinuxShellExecutor` 则有更复杂的八层校验（黑名单正则、AST 基线、沙箱后端 bubblewrap/firejail/docker、资源限制、审计日志），安全工程量级明显更高。这两个插件在同一份 manifest 字段（`requiresAdmin`）下的实际风险等级并不对等，横向笔记中笼统提到“PowerShell、图像生成等能力”时未区分这一点，本笔记予以纠正。

## 调用链总览

```text
上游 LLM 文本响应 (含 <<<[TOOL_REQUEST]>>> 块)
  -> ToolCallParser.parse()                (modules/vcpLoop/toolCallParser.js)
       -> extractNextToolBlock()           逐块扫描，忽略 <think> 内容
       -> parseBlock() -> _scanFields()     状态机式字段扫描，兼容 ESCAPE 转义
  -> ToolCallParser.separate()             拆分 normal / archery(异步无阻塞) 调用
  -> streamHandler.js / nonStreamHandler.js  do-while 循环，maxVCPLoopStream/NonStream（默认 5）
       -> ToolExecutor.execute() / executeAll()   (modules/vcpLoop/toolExecutor.js)
            -> river/vref 上下文注入
            -> tool_password 验证码校验（如配置 VCPToolCode）
            -> PluginManager.processToolCall()      (Plugin.js)
                 -> file:// 参数预拉取（非分布式插件）
                 -> ToolApprovalManager.getApprovalDecision()
                      需审批 -> WebSocketServer.broadcast('tool_approval_request', 'VCPLog')
                             -> 等待 tool_approval_response 或超时（默认 5 分钟，reject）
                 -> 按 pluginType + communication.protocol 分发：
                      stdio (synchronous/asynchronous)  -> child_process.spawn(shell:true)
                      direct (service/hybridservice/messagePreprocessor) -> 进程内模块方法调用
                      distributed (isDistributed=true)  -> WebSocketServer.executeDistributedTool()
  -> 结果格式化 -> WebSocketServer.broadcast('vcp_log', 'VCPLog')
  -> 回注下一轮 LLM 上下文 / plugin-callback 异步补写占位符
```

同轮多个工具调用：`ToolExecutor.executeAll()` 用 `Promise.all` 并发执行所有工具（第 396-400 行），任一失败不会中断其他调用（`execute()` 内部 catch 后返回 `_createErrorResult`，永不 reject 出 `executeAll`）。

依据：[toolCallParser.js](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[toolExecutor.js](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)、[Plugin.js](../../VCPToolBox/Plugin.js)、[nonStreamHandler.js](../../VCPToolBox/modules/handlers/nonStreamHandler.js)、[streamHandler.js](../../VCPToolBox/modules/handlers/streamHandler.js)。

## 1. VCP 文本协议：精确语法与解析实现

### 1.1 块级标记

`ToolCallParser.MARKERS` 定义精确标记 `<<<[TOOL_REQUEST]>>>` / `<<<[END_TOOL_REQUEST]>>>`（`modules/vcpLoop/toolCallParser.js:5-8`）。是否容忍变体标记完全取决于 `toolMarkerFuzzyMatcher` 的 `enabled` 状态，该状态由 `toolApprovalConfig.json` 的 `fuzzyToolMatching` 字段驱动（`modules/toolApprovalManager.js:55-64`），默认 `false`。

- 关闭模糊匹配时：`findBlockStartMarker`/`findBlockEndMarker` 走 `content.indexOf(canonicalMarker, cursor)`，要求逐字符精确匹配（`toolMarkerFuzzyMatcher.js:37-46`）。
- 开启模糊匹配时：块标记用正则 `<{2,4}\[LABEL\]>{2,4}`（忽略大小写）匹配 2-4 个尖括号包裹的 `[TOOL_REQUEST]`/`[END_TOOL_REQUEST]`（`toolMarkerFuzzyMatcher.js:48-51`），字段标记额外接受 `{始}`、`「始}`、`{始」` 等半角/全角括号混用形式，以及任意非换行字符组成的“始……末”对（`toolMarkerFuzzyMatcher.js:82-108`）。这是专门为容忍模型输出格式漂移设计的降级匹配，但同时扩大了被精心构造的用户输入误触发的面（例如用户在普通对话中写 `{始}xxx{末}` 也可能被解析为字段）。

### 1.2 字段扫描（`「始」value「末」`）

`_scanFields()` 是逐字符状态机（`toolCallParser.js:151-230`）：先跳过空白/逗号，用 `/^[\w_]+/` 匹配 key，要求紧跟 `:`，再匹配起始标记，扫描到匹配的结束标记为止。关键细节：

- **参数值中含分隔符**：值内容被视为 `startMarker` 与 `endMarker` 之间的任意字符（不做嵌套计数），所以如果值本身包含 `「末」` 会被错误截断在第一个出现处；反过来说，值中出现 `「始」` 不会被特殊处理（因为扫描的是 end marker 而不是 nested start），因此嵌套 `「始」...「始」...「末」...「末」` 不被支持，第一个 `「末」` 就会结束字段。
- **转义机制**：`ESCAPE_MARKERS`（`「始ESCAPE」`/`「末ESCAPE」`）允许在值内容中放入本会被误判为控制符的文本，`_restoreEscapedLiterals()` 在提取后把转义映射还原为字面量（`toolCallParser.js:15-20,232-240`）。这解决了“参数中确实需要写出 `「始」`/`「末」` 字面文本”的问题，但要求模型正确使用 ESCAPE 变体，模型若直接输出裸 `「始」` 仍会被当作新字段起始。
- **同轮多块**：`parse()` 用 `while (searchOffset < length)` 循环调用 `extractNextToolBlock`，支持同一响应中出现多个 `<<<[TOOL_REQUEST]>>>...<<<[END_TOOL_REQUEST]>>>` 块，逐个解析并加入 `toolCalls` 数组（`toolCallParser.js:34-44`）。
- **`<think>` 剥离**：解析前先用 `/<think>[\s\S]*?<\/think>/g` 移除思考块内容（`toolCallParser.js:30`），这意味着模型在 `<think>` 内“演练”的工具调用不会被执行——但这依赖标签精确闭合，若思考块未闭合（被截断的流式输出）则该保护失效。
- **code fence**：解析器本身**不识别** Markdown 代码块围栏，即模型如果在 ```` ``` ```` 代码块里写出示例性的 `<<<[TOOL_REQUEST]>>>` 文本，仍会被当作真实调用解析执行。这是与 VCPChat 前端渲染器形成对照的关键差异——前端在展示时会保护 code fence 内容不被当协议解释，但服务端解析层没有等价保护。这是**已确认**的边界情况，之前的横向笔记未提及。
- **畸形块处理**：若找不到匹配的结束标记（`_findBlockEnd` 返回 `null`），`extractNextToolBlock` 返回 `null`，整体 `parse()` 直接 `break` 停止扫描——意味着一个畸形的未闭合块会导致其后所有本应能解析的块也被丢弃（不会跳过继续扫描）。
- **流式截断**：解析发生在完整拼接后的 `currentAIContentForLoop` 上（`nonStreamHandler.js`/`streamHandler.js` 的循环变量），而不是逐 chunk 解析，因此半截的流式片段不会被误触发；但也意味着若流被提前中断（`abortController` 触发），未闭合的工具块永远不会被执行，这是预期行为而非 bug。
- **大小写/空白容忍**：模糊模式下标记匹配用 `i` 修饰符忽略大小写；`_skipWhitespace`/`_skipWhitespaceAndCommas` 用 `\s`/`[\s,]` 跳过任意空白与逗号分隔符，容忍字段间多余空格、换行和逗号缺失（`toolCallParser.js:242-254`）。

### 1.3 与 aio-hub 解析器的等价性

aio-hub 的 VCP 解析器（横向笔记第 76 行提到）同样采用 `<<<[TOOL_REQUEST]>>>` + `「始」/「末」` 语法，但**未在本次调查范围内重新验证 aio-hub 侧实现细节**（按任务要求不深入 aio-hub 代码）。可以确认的兼容风险点：VCPToolBox 支持的模糊匹配、ESCAPE 转义、`river`/`vref`/`archery`/`ink` 等扩展字段（见下）是 VCPToolBox 特有扩展；如果 aio-hub 的解析器没有实现同样的模糊匹配和转义规则，两端对“边界格式”（如半角括号、多重转义）的解析结果可能不一致，属于**需进一步验证**的协议兼容风险，不作为已确认结论。

依据：[toolCallParser.js](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[toolMarkerFuzzyMatcher.js](../../VCPToolBox/modules/vcpLoop/toolMarkerFuzzyMatcher.js)、[toolApprovalManager.js:55-64](../../VCPToolBox/modules/toolApprovalManager.js)。

## 2. 工具定义与上下文注入

### 2.1 占位符体系

`PluginManager.buildVCPDescription()`（`Plugin.js:765-800`）遍历所有已加载插件，把每个插件 `capabilities.invocationCommands[].description` 拼接为一段说明文本，存入 `individualPluginDescriptions` Map，键为 `VCP<PluginName>`（如 `VCPFileOperator`）。这些说明文本通过 `{{VCP<PluginName>}}` 占位符注入到 system prompt——具体替换逻辑在 `modules/messageProcessor.js:783-806`，对 system prompt 文本做 `replaceAll('{{VCPxxx}}', description)`。这意味着**模型看到的工具描述就是插件作者在 `plugin-manifest.json` 里写的原始中文自然语言文本**，包括调用格式示例，没有结构化 JSON Schema 或 function-calling 格式的转换层。

### 2.2 `static` 插件的上下文注入与刷新周期

`static` 类型插件（如 `WeatherReporter`、`ScheduleBriefing`、`UserAuth`、`EmojiListGenerator`）通过 `staticPlaceholderValues` Map 提供占位符值。生命周期（`Plugin.js:376-412`）：

1. 启动时先把占位符设为 "正在加载中" 的占位文本；
2. 立即触发一次后台更新（fire-and-forget，不阻塞启动）；
3. 若 manifest 声明 `refreshIntervalCron`，用 `node-schedule` 按 cron 表达式周期性重新执行插件 stdio 进程并更新值；
4. 插件本轮无输出或超时不算错误，保留旧值（stale-while-revalidate 语义），除非从未成功过一次才置为 "unavailable"。

`{{VCP<PluginName>}}`（工具描述）与 `{{VCPxxx}}`（static 数据占位符）是两套不同的占位符命名空间，前者来自 `invocationCommands`，后者来自 `systemPromptPlaceholders`，替换逻辑分别在 `messageProcessor.js` 的不同代码段（约 748-806 行）处理。

依据：[Plugin.js:765-800,376-412](../../VCPToolBox/Plugin.js)、[messageProcessor.js:616-806](../../VCPToolBox/modules/messageProcessor.js)。

## 3. 调用链细节：并发、失败处理、迭代上限

- **迭代上限**：`streamHandler.js:55` 与 `nonStreamHandler.js:275` 都定义 `maxRecursion = maxVCPLoopStream/NonStream || 5`，即工具调用触发的 LLM 重新推理循环最多 5 轮（可通过环境变量 `MaxVCPLoopStream`/`MaxVCPLoopNonStream` 配置，`server.js:1191-1192`）。这是"每轮响应中工具调用触发下一轮 LLM 请求"的上限，不是"单轮内工具调用数量"的上限——单轮内 `ToolCallParser.parse()` 可以解析出任意数量的工具块，全部通过 `Promise.all` 并发执行。
- **同轮并发语义**：`ToolExecutor.executeAll()`（`toolExecutor.js:396-400`）用 `Promise.all` 并发所有工具调用；由于 `execute()` 内部把所有异常都 catch 并转成 `_createErrorResult` 返回值而不是 reject（`toolExecutor.js:370-390`），`Promise.all` 永远不会因为单个工具失败而整体 reject，各工具结果互相独立回注。
- **超时**：stdio 插件默认超时 `synchronous` 60 秒、`asynchronous` 1800 秒（30 分钟），均可被 manifest 的 `communication.timeout` 覆盖（`Plugin.js:1345`）。分布式工具默认超时也是 60 秒，取自目标插件 manifest 的 `communication.timeout`（`WebSocketServer.js:869`）。
- **重试**：**未发现**任何自动重试机制——工具调用失败后直接把错误文本回注给模型，由模型自己决定是否重新发起调用。这是明确设计（回注错误让 AI 自愈），不是缺陷。
- **进程终止**：stdio 插件超时后调用 `_killProcessTree`（Windows 上用 `taskkill /F /T`）强杀整个进程树，防止子进程残留（`PowerShellExecutor.js` 内部也有等价的 `forceKillProcessTree`）。

依据：[toolExecutor.js:392-400](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)、[streamHandler.js:55](../../VCPToolBox/modules/handlers/streamHandler.js)、[nonStreamHandler.js:275](../../VCPToolBox/modules/handlers/nonStreamHandler.js)、[server.js:1191-1192](../../VCPToolBox/server.js)。

## 4. 参数校验

**未发现**任何形式的 JSON Schema 或类型系统校验。`ToolCallParser._scanFields()` 把所有字段值都解析为**字符串**（`fields.push({ key, value: restoredValue })`，`toolCallParser.js:220`），插件收到的 `args` 对象里所有值都是字符串，类型转换（转数字、转布尔）完全由各插件自己在内部做（例如 `PowerShellExecutor.js` 用 `args.executionType` 直接做字符串比较,`LinuxShellExecutor` 内部自行 `parseInt`）。

manifest 里没有 `parameters`/`schema` 字段声明参数类型或必需性；`capabilities.invocationCommands[].description` 是纯自然语言文本，模型是否提供了正确参数、参数是否缺失，只能在插件运行时暴露（插件自己 `throw new Error('缺少必需参数...')`）。这意味着：

- **路径参数**：如 `FileOperator` 的 `isPathAllowed()`（`Plugin/FileOperator/FileOperator.js:61-91`）用 `path.resolve` + 大小写不敏感前缀比较判断路径是否在 `ALLOWED_DIRECTORIES` 内；若未配置 `ALLOWED_DIRECTORIES`（`config.env.example` 默认值是 `../..`，即 VCPToolBox 根目录的上两级），则"允许所有路径"（`FileOperator.js:75-78`，注释明确写"如果没有配置允许的目录，则允许所有操作"）。只读操作（`ReadFile`/`FileInfo`）对绝对路径有豁免，可绕过 `ALLOWED_DIRECTORIES` 边界直接读取任意绝对路径文件（`FileOperator.js:82-86`）——这是一个**已确认**的信息泄露面：只要该插件被启用且未设置严格的 `ALLOWED_DIRECTORIES`，模型可以让它读取沙箱目录之外任意文件（取决于运行插件进程的操作系统用户权限）。
- **命令参数**：`PowerShellExecutor` 对 `command` 只做关键字黑名单子串匹配（`FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS`，均为大小写不敏感的 `includes()` 判断，`PowerShellExecutor.js:150-158`），没有 AST 或语法分析，理论上可以用字符串拼接、别名、编码变体规避关键字匹配（例如 `Remove-Item` 别名 `ri` 不在默认黑名单里）。`LinuxShellExecutor` 相反有完整的黑名单正则 + AST 语义基线 + 沙箱后端（第 6 节详述）。
- **URL 参数**：`UrlFetch`、`TavilySearch` 等插件的 URL 参数未在本次调查中逐一复核是否有 SSRF 防护（如内网地址黑名单），列入未验证事项。

依据：[toolCallParser.js:220](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[FileOperator.js:61-91](../../VCPToolBox/Plugin/FileOperator/FileOperator.js)、[PowerShellExecutor.js:150-158](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)。

## 5. 审批系统（重点）

### 5.1 `toolApprovalConfig.json` 规则语法

配置结构（`modules/toolApprovalManager.js:10-19,25-53`）：

```json
{
  "enabled": false,
  "timeoutMinutes": 5,
  "approveAll": false,
  "approvalList": ["ToolName", "ToolName:具体command文本", "ToolName::SilentReject"],
  "fuzzyToolMatching": false,
  "privacyProtection": { "enabled": false }
}
```

规则语义（`getApprovalDecision()`,`toolApprovalManager.js:144-225`）：

- `enabled=false`：整个审批系统关闭，所有调用直接执行，`getApprovalDecision` 直接返回 `requiresApproval:false`（第 152-154 行）。
- `approveAll=true`：忽略 `approvalList`，所有工具调用一律需要审批（第 156-164 行）。
- `approvalList` 每一项是一条规则字符串，`parseApprovalRule()` 解析后缀 `::SilentReject` 决定拒绝时是否通知 AI（`notifyAiOnReject`）（第 117-142 行）。
- **匹配语义**是精确字符串相等，不支持通配符（`*`）：规则可以是 `ToolName`（工具级，命中所有该工具的调用）或 `ToolName:command文本`（命令级，仅当 `extractCommands()` 从参数中提取出的 `command`/`command1`/`command2`... 值与规则冒号后半部分**完全相等**时命中）（第 194-205 行）。**命中优先级**：命令级（specificity=2）优先于工具级（specificity=1）；同优先级下，`notifyAiOnReject:false`（静默拒绝）的规则优先于会通知 AI 的规则（第 174-192 行）。
- **默认行为（无命中）**：`requiresApproval:false`，即未在名单里的工具调用默认放行，不需要审批——这是**白名单式豁免、黑名单式管控**的语义：`approvalList` 里列出的才需要审批，不在列表里的默认自动执行。这与直觉上"审批清单=需要人工批准的工具清单"一致，但需要强调：**不是 allow-list（只放行清单内工具）**，而是 deny-by-default-approve（清单外全部自动放行）。

### 5.2 状态机与广播

`PluginManager.processToolCall()` 中（`Plugin.js:984-1058`）：

1. 调 `toolApprovalManager.getApprovalDecision()` 判定是否需要审批；
2. 若需要，生成 `requestId`（`approve-${Date.now()}-${random}`，**不是密码学安全的随机数**，仅用 `Math.random().toString(36)` 取 7 位——`Plugin.js:987`），创建一个 Promise 并存入 `this.pendingApprovals` Map（`Plugin.js:994-1009`）；
3. 通过 `webSocketServer.broadcast({type:'tool_approval_request', data:{...}}, 'VCPLog')` 把请求**广播给所有已连接的 `VCPLog` 类型客户端**（`Plugin.js:1011-1026`）；
4. `setTimeout` 按 `timeoutMinutes`（默认 5 分钟）设置超时，超时后从 `pendingApprovals` 删除并 `reject`（`Plugin.js:995-1001`）——**超时后的默认动作是拒绝执行（fail-closed），不是自动放行**，这是关键安全结论，纠正了任务描述中需要重点核实的"fail-open 风险"猜测：本项目在"超时"这一单一维度上是 fail-closed 的。
5. 若 `webSocketServer` 未初始化（理论上不会发生，因为它在 `initialize()` 中先于插件加载完成注入），会直接从 `pendingApprovals` 删除并 throw，同样是拒绝执行而非放行（`Plugin.js:1027-1030`）。

### 5.3 审批响应的身份校验——已确认的薄弱点

`WebSocketServer.js:484-494` 收到 `tool_approval_response` 消息时，**只要消息来自任意已认证的 WebSocket 连接**（不限定 `clientType==='VCPLog'`，代码里判断的是 `parsedMessage.type === 'tool_approval_response'`，位于 `else if` 链的通用分支，未按 `ws.clientType` 过滤），就会调用 `pluginManager.handleApprovalResponse(requestId, approved, reason)`。`handleApprovalResponse()`（`Plugin.js:1535-1571`）只用 `requestId` 从 `pendingApprovals` 中查找待处理项，**没有校验发起批准的客户端身份与发起该审批请求的上下文是否匹配**，也没有校验发送者是否具备"审批权限"这一独立角色。

结合 WebSocket 鉴权只有一个全局共享的 `VCP_Key`（第 9 节详述），**任何持有 `VCP_Key` 的客户端（包括本应只用于日志展示的 `VCPLog` 只读消费者、`ChromeControl`、`AdminPanel` 等）都能猜测或截获 `requestId` 后主动发送 `tool_approval_response` 抢先批准或拒绝一个审批请求**。`requestId` 本身会通过广播发给所有 `VCPLog` 客户端，因此"截获"门槛很低——只要客户端连接了 `VCPLog` 通道就能看到 `requestId` 并回发批准。这是**已确认**的审批绕过面：不是"绕过审批要求"，而是"任何持 Key 的客户端都能代替预期审批人做出批准/拒绝决定"，把审批的最终决定权从"应该批准的人"稀释为"任何已连接的合法客户端"。

### 5.4 静默拒绝与用户备注

`notifyAiOnReject=false` 的规则被拒绝时，`approval.resolve({silentRejected:true})`，`PluginManager.processToolCall` 检测到 `silentRejected===true` 时返回 `undefined`（`Plugin.js:1034-1052`），意味着这次调用对 AI 完全不可见（AI 既不知道被拒绝也不知道调用发生过），只有人工审批者留下的 `reason` 备注会被记录到日志。这是一个隐蔽性设计，用于防止 AI 反复尝试同一被拒绝的敏感操作。

依据：[toolApprovalManager.js:10-225](../../VCPToolBox/modules/toolApprovalManager.js)、[Plugin.js:984-1058,1535-1571](../../VCPToolBox/Plugin.js)、[WebSocketServer.js:484-494](../../VCPToolBox/WebSocketServer.js)。

## 6. 插件模型：manifest 字段、类型与执行协议

### 6.1 manifest 加载与生命周期

`PluginManager.loadPlugins()`（`Plugin.js:536-763`）扫描 `Plugin/` 下每个子目录的 `plugin-manifest.json`；缺少 `name`/`pluginType`/`entryPoint` 任一字段的 manifest 会被静默跳过（`Plugin.js:585`）。禁用插件的方式是把文件改名为 `plugin-manifest.json.block`（本次 checkout 有 20 个插件处于此状态，见第 11 节插件清单）。热重载时（`hotReloadPluginsAndOrder`）会先关闭旧的本地插件模块（调用其 `shutdown()`），保留分布式插件不受影响（`Plugin.js:544-568`）；`direct` 协议的常驻插件在文件变更时**不会**自动热重载以维持稳定性（`Plugin.js:2135-2137`）。

### 6.2 六种插件类型的生命周期差异

| 类型 | 触发方式 | 进程模型 | 结果返回 |
|---|---|---|---|
| `static` | cron 定时 + 启动时立即触发一次 | 每次执行都是独立 stdio 子进程 | stdout 整体作为占位符值，失败保留旧值 |
| `synchronous` | AI 发起 VCP 调用 | 每次调用 spawn 一个新 stdio 子进程 | 等待进程退出，解析 stdout 中的 JSON |
| `asynchronous` | AI 发起 VCP 调用 | spawn 子进程，等待"首个 JSON 响应"后立即 resolve，子进程可继续在后台运行 | 首次 JSON 走同步返回；后续结果通过 `POST /plugin-callback/:pluginName/:taskId` 回调主服务器，写入 `VCPAsyncResults/` 目录文件，再由 `{{VCP_ASYNC_RESULT::Plugin::id}}` 占位符异步读取展示 |
| `service` | 服务器启动时 `initializeServices()` 一次性加载 | 进程内模块，常驻内存，可挂载 Express 路由（`hasApiRoutes`） | 不通过 processToolCall 触发工具调用（无 invocationCommands 语义） |
| `messagePreprocessor` | 每次对话请求前 | 进程内模块方法调用（`protocol:'direct'`），无独立子进程 | 直接修改 messages 数组 |
| `hybridservice` | 既是常驻服务又可被 AI 直接调用 | 进程内模块，`processToolCall` 方法被直接调用（无子进程开销） | 直接返回 JS 对象 |

`isDistributed` 是一个独立于 `pluginType` 的标记，任何类型的插件都可能来自远程节点注册，此时执行走 `WebSocketServer.executeDistributedTool()` 而不是本地 spawn/direct 调用。

### 6.3 执行协议实现差异

- **`stdio`**：`_executePluginWithTimeout`（`Plugin.js:1327` 起）用 `child_process.spawn(command, args, {cwd: plugin.basePath, shell: true, env: finalEnv, windowsHide: true})`。**注意 `shell: true`**——这意味着 `entryPoint.command` 字符串会经过系统 shell 解析，如果该字符串本身可控（目前是 manifest 固定值，不受运行期参数拼接），风险有限，但这是命令注入的潜在放大面，若未来任何代码路径允许拼接用户输入到 `entryPoint.command`，将直接构成 shell 注入。当前**未发现**此类拼接（`command` 固定来自 manifest 静态配置）。
- **`direct`**：manifest 声明 `entryPoint.script`，`loadPlugins()` 用 `require()` 动态加载该模块到进程内（`Plugin.js:603-617`），模块需暴露 `initialize()`/`processToolCall()`/`shutdown()` 等约定方法。这意味着 `direct` 协议插件与主服务进程**同权限、同内存空间**运行，没有任何进程隔离。
- **`distributed`**：不在本地 spawn 任何进程，转发到远程节点的 WebSocket 连接（详见第 8 节）。

### 6.4 Node/Python/native 入口

`entryPoint.type` 可以是 `nodejs`（`command: "node xxx.js"`）；仓库内也存在 Python 插件（如 `SciCalculator` 有专门的预热逻辑 `prewarmPythonPlugins()`，`Plugin.js:414-439`，用 `spawn('python', ['-c', 'import sympy...'])` 预热科学计算库）和 Rust 原生模块（`rust-vexus-lite`，通过 Dockerfile 编译为 `.node` N-API addon，供向量检索使用，不是通过 `plugin-manifest.json` 的 `entryPoint` 机制加载，而是被 Node 主进程直接 `require`）。环境变量传递给子进程插件时，除插件自身 `config.env` 外，主服务额外注入 `PROJECT_BASE_PATH`、`VCP_REQUEST_IP`、`SERVER_PORT`、`PYTHONIOENCODING=utf-8`,若 `requiresAdmin` 则注入 `DECRYPTED_AUTH_CODE`，若为 `asynchronous` 类型则注入 `CALLBACK_BASE_URL`/`PLUGIN_NAME_FOR_CALLBACK`（`Plugin.js:1240-1326`）。

### 6.5 `requiresAdmin` 的实际生效点

**已确认**：主框架本身对 `requiresAdmin` 只做两件事——(a) 给 stdio 插件注入 `DECRYPTED_AUTH_CODE` 环境变量；(b) 给 `hybridservice`/`direct` 插件的 `directContext` 注入 `decryptedAuthCode` 字段（`Plugin.js:1096-1105,1257-1267`）。**框架不会因为 `requiresAdmin:true` 而拦截调用本身**——如果插件代码忘记比对这个值，`requiresAdmin` 就形同虚设。已复核的三个 `requiresAdmin:true` 插件（`PowerShellExecutor`、`LinuxShellExecutor`、`PluginManager`）都在自己代码里做了比对，但这是"插件作者自律 + 现有插件确实做了"的经验事实，不是框架层面的强制保证；若安装第三方或自写的 `requiresAdmin:true` 插件但忘记校验，攻击者无需任何验证码即可直接调用。

依据：[Plugin.js:536-763,1096-1105,1240-1326,1327-1533](../../VCPToolBox/Plugin.js)、[PowerShellExecutor.js](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)、[PluginManager.js:35-50](../../VCPToolBox/Plugin/PluginManager/PluginManager.js)。

## 7. 执行位置与隔离

- **stdio 插件**：与主 Node 进程同一台机器、同一操作系统用户权限下运行的独立子进程。**没有**任何 OS 级沙箱、chroot、容器隔离或降权（`spawn` 调用未指定 `uid`/`gid`，Windows 平台本身也没有等价机制）。子进程能访问的文件系统范围仅受该插件代码自身逻辑（如 `FileOperator` 的 `ALLOWED_DIRECTORIES`）限制，不是操作系统强制边界。
- **`direct`/`hybridservice` 插件**：与主服务进程同一内存空间、同一权限，本质上是主进程的一部分，没有任何隔离概念。
- **例外——`LinuxShellExecutor`**：这是唯一实现了实际沙箱后端的插件，`config.env` 中 `SANDBOX_BACKEND` 可选 `bubblewrap`/`firejail`/`docker`/`none`（默认 `none`，即不隔离），并配置 CPU/文件大小/进程数/文件描述符/虚拟内存的 `RLIMIT_*` 资源限制（`LinuxShellExecutor/config.env:15-30`）。这是插件自带的隔离能力，不是框架统一提供的。
- **Docker 部署**：`Dockerfile`/`docker-compose.yml` 显示整个 VCPToolBox（含所有插件）作为**单一容器**运行，`docker-compose.yml` 把整个仓库目录 bind-mount 进容器（`- .:/usr/src/app`），`Dockerfile` 里 `USER appuser` 那行是**被注释掉的**（`Dockerfile:187`，`# USER appuser`），即容器内进程默认以 root 运行。容器本身是唯一的"边界"，容器内所有插件之间没有进一步隔离；`LinuxShellExecutor` 若在容器内设 `SANDBOX_BACKEND=docker`，则涉及 docker-in-docker 或挂载 docker socket 的额外风险（**未在本次调查中验证该配置在容器化部署下是否真的可用**）。
- **超时与僵尸进程**：`_killProcessTree()`(`Plugin.js`) 及 `PowerShellExecutor.js` 里的 `forceKillProcessTree()` 均在超时后用 `taskkill /F /T /PID` (Windows) 强杀整个进程树，防止子进程残留为僵尸/孤儿进程。Linux 侧未在本次调查中找到等价的进程组强杀逻辑用于通用 stdio 插件（`LinuxShellExecutor` 自身对其管理的命令有独立的进程生命周期管理，但通用 `_executePluginWithTimeout` 路径下 Linux 系统调用等价物未被单独确认）。

依据：[Plugin.js:1327-1533](../../VCPToolBox/Plugin.js)、[PowerShellExecutor.js:47-58](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)、[LinuxShellExecutor/config.env](../../VCPToolBox/Plugin/LinuxShellExecutor/config.env)、[Dockerfile:187,191](../../VCPToolBox/Dockerfile)、[docker-compose.yml](../../VCPToolBox/docker-compose.yml)。

## 8. 分布式节点协议

### 8.1 协议流程

```text
分布式节点 (远端 VCPToolBox 实例或自定义客户端)
  -> WebSocket 连接 wss://host:port/vcp-distributed-server/VCP_Key=<key>
  -> register_tools { tools: [manifest, ...] }     声明其能提供的工具（过滤掉内部 internal_request_file）
  主服务器
  -> 收到 AI 对某分布式工具的调用
  -> executeDistributedTool(serverId, toolName, args, timeout)
       -> { type: 'execute_tool', data: { requestId, toolName, toolArgs } }  经 WS 发给该节点
  分布式节点执行完毕
  -> { type: 'tool_result', data: { requestId, status, result/error } }
  主服务器 pendingToolRequests.get(requestId) -> resolve/reject
```

### 8.2 节点鉴权

WebSocket 升级请求时校验 URL 路径里的 `VCP_Key` 参数是否等于服务器配置的**全局唯一** `vcpKey`（`WebSocketServer.js:230-236`）。**没有节点级别的独立密钥、证书或双向 TLS**——所有连接类型（`VCPLog`、`DistributedServer`、`ChromeControl`、`AdminPanel` 等）共用同一个 `VCP_Key`。这意味着持有该 Key 的任何一方既可以伪装成分布式节点注册工具，也可以伪装成审批客户端批准/拒绝请求，也可以伪装成 AdminPanel 客户端——**Key 泄漏的爆炸半径覆盖了所有 WebSocket 通道的所有能力**，这是比"节点鉴权"更大范围的架构性风险。

### 8.3 节点声明工具的可信度

`registerDistributedTools()`（`Plugin.js:1637-1662`）对新注册工具做的唯一检查是"名称是否已存在于 `this.plugins`"——若已存在则跳过（不覆盖），否则接受并标记 `isDistributed:true`、`serverId`，displayName 加 `[云端]` 前缀。**已确认**：分布式节点**不能覆盖已存在的本地或其他节点的工具名**，但**可以自由注册任意新名字的工具**，包括故意构造与知名本地插件高度相似的名字（如 `FileOperatorPro`、`FileOperator_v2`）来诱导模型误选。manifest 内容（包括 `invocationCommands` 里的调用说明文本、是否 `requiresAdmin`）完全由远程节点自行提供，主服务器不做任何 schema 或内容审查就直接采纳并注入到 system prompt 描述中。

### 8.4 转发调用的审批是否仍然生效

**已确认生效**：`PluginManager.processToolCall()` 中审批判定逻辑（`toolApprovalManager.getApprovalDecision`）发生在分支判断"是否为分布式插件"**之前**（`Plugin.js:985` 位于 `if (plugin.isDistributed)` 判断的 `Plugin.js:1063` 之前），因此只要 `toolApprovalConfig.json` 中把该工具名列入 `approvalList`，分布式转发调用同样会先触发人工审批流程，审批通过后才会转发执行。

依据：[WebSocketServer.js:191-236,722-864,866-910](../../VCPToolBox/WebSocketServer.js)、[Plugin.js:985,1063-1069,1637-1662](../../VCPToolBox/Plugin.js)。

## 9. HTTP 接口暴露面

| 路径 | 鉴权方式 | 说明 |
|---|---|---|
| `/v1/chat/completions`、`/v1/chatvcp/completions`、`/v1/models`、`/v1/schedule_task`、`/v1/interrupt`、`/v1/human/tool` | `Authorization: Bearer <serverKey>`（`server.js:867-870`，`serverKey=process.env.Key`） | 全局中间件在 `/admin_api`、`/AdminPanel`、图片/文件服务路径、`/plugin-callback` 之外的所有路径强制要求 Bearer token（`server.js:845-872`），`/v1/human/tool` 定义在该中间件**之后**（第 1239 行 > 第 845 行），故**已确认需要 Bearer 鉴权**，不是无鉴权端点 |
| `/admin_api/*`、`/AdminPanel/*` | HTTP Basic Auth（`basic-auth` 库）或 Cookie 里的 `admin_auth`（server.js:650-747），凭据来自 `AdminUsername`/`AdminPassword` 环境变量；未配置这两个变量时管理面板整体 503 禁用 | 有登录失败次数限制与临时 IP 封禁（`tempBlocks`），少数只读监控端点（`/admin_api/system-monitor` 等）豁免封禁计数但仍需通过 Basic Auth |
| `/pw=<key>/images/*`、`/pw=<key>/files/*` | URL 路径内嵌的 key（由 `ImageServer` 插件生成/校验，未在本次调查中逐行复核该 key 比对逻辑的强度） | 豁免全局 Bearer 中间件（`server.js:851-860`） |
| `/plugin-callback/:pluginName/:taskId` | **无鉴权**（`server.js:863-865` 显式豁免 Bearer 检查） | 见第 10 节"回调伪造"分析 |
| WebSocket `/VCPlog/VCP_Key=`、`/vcpinfo/VCP_Key=`、`/vcp-distributed-server/VCP_Key=`、`/vcp-chrome-control/VCP_Key=`、`/vcp-chrome-observer/VCP_Key=`、`/vcp-admin-panel/VCP_Key=` | 全局共享 `VCP_Key`（第 8.2 节） | 所有通道共用同一个 Key，无按通道区分的细粒度权限 |

- **CORS**：`app.use(cors({origin:'*'}))`（`server.js:548`），对所有来源开放跨域——若浏览器端脚本获得受害者浏览器执行环境（如 XSS）且知道 Bearer token，可跨域调用任意 `/v1/*` 接口；即使不知道 token，`/plugin-callback/*` 无鉴权路径也可被任意来源的网页直接 POST。
- **默认监听地址**：`app.listen(port, ...)`（`server.js:1670`），**未指定 host 参数**，Node.js `http.Server.listen(port)` 默认监听所有网络接口（`0.0.0.0`/`::`），意味着容器化部署下端口映射出去即对公网可达，未观察到默认绑定 `127.0.0.1` 的收紧配置。这是**已确认**的默认暴露面，实际风险取决于反向代理/防火墙/端口映射策略。

依据：[server.js:548,650-747,845-872,1239-1289,1460-1504,1670](../../VCPToolBox/server.js)。

## 10. 结果处理与回注

- **结果格式**：`ToolExecutor._formatResult()`（`toolExecutor.js:448-473`）优先识别 `result.data.content`/`result.content` 形式的富内容数组（`[{type:'text', text:...}]`），否则把对象 `JSON.stringify(result, null, 2)` 或直接转字符串，包装为统一的 `{type:'text', text}` 内容块回注给 LLM。**未发现**任何长度截断逻辑在 `ToolExecutor` 层——工具返回多长的文本就原样拼回对话上下文，可能导致单次工具调用输出把上下文窗口占满（这与横向笔记里 LobeHub"截断结果"的设计形成对照，VCPToolBox 在框架层没有等价保护，是否截断取决于各插件自身实现）。
- **错误形态**：同步执行错误统一包装为 `throw new Error(JSON.stringify({plugin_error: message, ...}))` 字符串化 JSON，上层 catch 后再 `JSON.parse` 尝试还原结构化错误对象（`server.js:1279-1284`）；解析失败则退化为 `{error:'Internal Server Error', details: error.message}`。
- **异步插件回调注入路径**：`asynchronous` 类型插件的后续结果通过 **无鉴权** 的 `POST /plugin-callback/:pluginName/:taskId` 端点回传（`server.js:1460-1504`，该路径在 Bearer 鉴权中间件里被显式豁免，`server.js:863-865`）。服务器收到请求后：(1) 直接把 `req.body` 原样写入 `VCPAsyncResults/${pluginName}-${taskId}.json` 文件；(2) 若该插件 manifest 声明了 `webSocketPush.enabled`，则把回调内容原样广播给对应 WebSocket 客户端类型。**未做任何签名、来源校验或 taskId 随机性强度检查**——`taskId` 由插件自身生成（多数用 `crypto.randomUUID()`，如 `PowerShellExecutor.js` 的后台任务 ID），只要攻击者能猜到或获知 `pluginName`+`taskId`，就可以伪造回调内容覆盖该任务的"真实结果"，进而通过 `{{VCP_ASYNC_RESULT::Plugin::id}}` 占位符把伪造内容注入到下一轮系统提示词/对话历史中（`modules/messageProcessor.js:828-867` 直接读取该 JSON 文件内容拼入回复文本，不做二次校验）。这是**已确认**的回调伪造攻击面，详见第 13 节。
- **分布式插件回调转发**：`handleDistributedPluginCallback()`（`WebSocketServer.js:95-144`）走 WebSocket `plugin_callback_forward` 消息类型，同样只检查 `pluginName`/`taskId` 字段是否存在，不做任何来源节点与任务归属的绑定校验——原则上任何已连接的分布式节点都可以为**不属于自己**的 `taskId` 伪造 `plugin_callback_forward` 消息，只要猜中或获知目标 taskId。

依据：[toolExecutor.js:448-473](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)、[server.js:863-865,1460-1504](../../VCPToolBox/server.js)、[messageProcessor.js:828-867](../../VCPToolBox/modules/messageProcessor.js)、[WebSocketServer.js:95-144](../../VCPToolBox/WebSocketServer.js)。

## 11. 插件清单

以下为**当前 checkout（`Plugin/` 目录，85 个子目录，不含 `AGENTS.md`）实际存在的 manifest** 逐一读取的结果。启用判定标准：存在 `plugin-manifest.json`（非 `.block`）。共 65 个启用、20 个禁用（`.block`）。这与 `docs/PLUGIN_ECOSYSTEM.md` 声称的"总计 79 活跃插件"**不一致**——文档统计口径把仓库内所有插件目录（含 `.block` 禁用态）都算作"活跃"，而实际当前 checkout 启用的插件数是 65，禁用（`.block`）20 个，两者之和 85 也与文档的 79 不完全对应，说明文档的插件类型分布统计（`static`~10、`service`~8 等）是历史快照，**不能作为当前启用状态的依据**，本笔记以下表格为准。

| 插件目录 | manifest name | pluginType | 协议 | 状态 | requiresAdmin |
|---|---|---|---|---|---|
| AICodeWorker | AICodeWorker | synchronous | stdio | 启用 | 否 |
| AgentAssistant | AgentAssistant | hybridservice | direct | 启用 | 否 |
| AgentDream | AgentDream | hybridservice | direct | 禁用 | 否 |
| AgentMessage | AgentMessage | synchronous | stdio | 启用 | 否 |
| AgnesGen | AgnesGen | synchronous | stdio | 启用 | 否 |
| AgnesVideoGen | AgnesVideoGen | asynchronous | stdio | 启用 | 否 |
| AnimeFinder | AnimeFinder | synchronous | stdio | 禁用 | 否 |
| AnySearch | AnySearch | synchronous | stdio | 启用 | 否 |
| ArtistMatcher | ArtistMatcher | synchronous | stdio | 启用 | 否 |
| ArxivDailyPapers | ArxivDailyPapers | static | stdio | 禁用 | 否 |
| BilibiliFetch | BilibiliFetch | synchronous | stdio | 启用 | 否 |
| CapturePreprocessor | CapturePreprocessor | messagePreprocessor | direct | 启用 | 否 |
| ChromeBridge | ChromeBridge | hybridservice | direct | 启用 | 否 |
| CodeSearcher | ServerCodeSearcher | synchronous | stdio | 启用 | 否 |
| ComfyUIGen | ComfyUIGen | synchronous | stdio | 禁用 | 否 |
| ContextFoldingV2 | ContextFoldingV2 | messagePreprocessor | direct | 启用 | 否 |
| CrossRefDailyPapers | CrossRefDailyPapers | static | stdio | 禁用 | 否 |
| DMXDoubaoGen | DMXDoubaoGen | synchronous | stdio | 启用 | 否 |
| DailyHot | DailyHot | static | stdio | 禁用 | 否 |
| DailyNote | DailyNote | hybridservice | direct | 启用 | 否 |
| DailyNoteManager | DailyNoteManager | hybridservice | direct | 启用 | 否 |
| DailyNotePanel | DailyNotePanelRouter | service | direct | 禁用 | 否 |
| DailyNoteSearcher | DailyNoteSearcher | hybridservice | direct | 启用 | 否 |
| DeepWikiVCP | DeepWikiVCP | synchronous | stdio | 启用 | 否 |
| DigitalOracle | DigitalOracle | synchronous | stdio | 启用 | 否 |
| DoubaoGen | DoubaoGen | synchronous | stdio | 启用 | 否 |
| DynamicToolBridge | DynamicToolBridge | synchronous | stdio | 启用 | 否 |
| EmojiListGenerator | EmojiListGenerator | static | stdio | 启用 | 否 |
| FileListGenerator | FileListGenerator | static | stdio | 禁用 | 否 |
| FileOperator | ServerFileOperator | synchronous | stdio | 启用 | 否 |
| FileTreeGenerator | FileTreeGenerator | static | stdio | 禁用 | 否 |
| FlashDeepSearch | FlashDeepSearch | synchronous | stdio | 启用 | 否 |
| FluxGen | FluxGen | synchronous | stdio | 启用 | 否 |
| GPTImageGen | GPTImageGen | synchronous | stdio | 启用 | 否 |
| GeminiImageGen | GeminiImageGen | synchronous | stdio | 启用 | 否 |
| ImageFileServer | ImageServer | service | direct | 启用 | 否 |
| ImageProcessor | ImageProcessor | messagePreprocessor | direct | 启用 | 否 |
| LightMemo | LightMemo | hybridservice | direct | 启用 | 否 |
| LinuxLogMonitor | LinuxLogMonitor | hybridservice | direct | 禁用 | 否 |
| LinuxLogMonitorServer | LinuxLogMonitorServer | service | direct | 禁用 | 否 |
| LinuxShellExecutor | LinuxShellExecutor | hybridservice | direct | 启用 | **是** |
| MagiAgent | MagiAgent | hybridservice | direct | 启用 | 否 |
| NCBIDatasets | NCBIDatasets | synchronous | stdio | 禁用 | 否 |
| NanoBananaGen2 | NanoBananaGen2 | synchronous | stdio | 启用 | 否 |
| OneRing | OneRing | messagePreprocessor | direct | 启用 | 否 |
| OpenHerPersona | OpenHerPersona | hybridservice | direct | 启用 | 否 |
| PaperReader | PaperReader | synchronous | stdio | 禁用 | 否 |
| PluginManager | PluginManager | hybridservice | direct | 启用 | **是** |
| PluginSourceViewer | ServerPluginSourceViewer | synchronous | stdio | 启用 | 否 |
| PowerShellExecutor | ServerPowerShellExecutor | synchronous | stdio | 启用 | **是** |
| QwenImageGen | QwenImageGen | synchronous | stdio | 启用 | 否 |
| RAGDiaryPlugin | RAGDiaryPlugin | hybridservice | direct | 启用 | 否 |
| RiverTestPlugin | RiverTestPlugin | synchronous | stdio | 禁用 | 否 |
| SSHManagerService | SSHManagerService | service | direct | 禁用 | 否 |
| ScheduleBriefing | ScheduleBriefing | static | stdio | 启用 | 否 |
| ScheduleManager | ScheduleManager | synchronous | stdio | 启用 | 否 |
| SciCalculator | SciCalculator | synchronous | stdio | 启用 | 否 |
| SemanticGroupEditor | SemanticGroupEditor | synchronous | stdio | 启用 | 否 |
| SkillBridge | SkillBridge | static | process_stdio | 启用 | 否 |
| SnowBridge | SnowBridge | hybridservice | direct | 禁用 | 否 |
| TarotDivination | TarotDivination | synchronous | stdio | 启用 | 否 |
| TavilySearch | TavilySearch | synchronous | stdio | 启用 | 否 |
| ThoughtClusterManager | ThoughtClusterManager | synchronous | stdio | 启用 | 否 |
| TimedTaskQuery | TimedTaskQuery | synchronous | stdio | 启用 | 否 |
| ToolCallRecordQuery | ToolCallRecordQuery | synchronous | stdio | 启用 | 否 |
| UrlFetch | UrlFetch | synchronous | stdio | 启用 | 否 |
| UserAuth | UserAuth | static | (未声明) | 启用 | 否 |
| VCPBridgeServer | VCPBridgeServer | service | direct | 启用 | 否 |
| VCPClawMail | VCPClawMail | hybridservice | direct | 启用 | 否 |
| VCPEverything | ServerSearchController | synchronous | stdio | 启用 | 否 |
| VCPForum | VCPForum | synchronous | stdio | 启用 | 否 |
| VCPForumLister | ForumLister | static | stdio | 启用 | 否 |
| VCPForumOnline | VCPForumOnline | synchronous | stdio | 禁用 | 否 |
| VCPForumOnlinePatrol | VCPForumOnlinePatrol | static | stdio | 禁用 | 否 |
| VCPLog | VCPLog | service | direct | 启用 | 否 |
| VCPTaskAssistant | VCPTaskAssistant | hybridservice | direct | 启用 | 否 |
| VCPTavern | VCPTavern | hybridservice | direct | 启用 | 否 |
| VCPTimeLine | VCPTimeLine | hybridservice | direct | 启用 | 否 |
| VCPToolBridge | VCPToolBridge | hybridservice | direct | 启用 | 否 |
| VSearch | VSearch | synchronous | stdio | 启用 | 否 |
| VideoGenerator | Wan2.1VideoGen | asynchronous | stdio | 启用 | 否 |
| WeatherInfoNow | WeatherInfoNow | static | stdio | 禁用 | 否 |
| WeatherReporter | WeatherReporter | static | stdio | 启用 | 否 |
| ZImageGen2 | ZImageGen2 | synchronous | stdio | 禁用 | 否 |
| ZImageTurboGen | ZImageTurboGen | synchronous | stdio | 启用 | 否 |

**风险等级标注**（基于本次调查复核的重点插件，非全量逐一审计）：

- **高风险（已确认命令/代码执行能力，且校验强度有限）**：`PowerShellExecutor`（黑名单子串匹配，可能被字符串拼接/别名规避）、`FileOperator`（未配置 `ALLOWED_DIRECTORIES` 时无限制，只读操作对绝对路径豁免）。
- **中高风险（有执行能力但校验较完善）**：`LinuxShellExecutor`（八层校验+可选沙箱后端，但 `SANDBOX_BACKEND` 默认 `none`）、`PluginManager`（可管理其他插件的启用/禁用，`requiresAdmin` 且有校验）、`ChromeBridge`/`ChromeControl`（可控制浏览器，间接具备任意网页交互能力）。
- **中风险（网络请求/外部数据可控）**：`UrlFetch`、`TavilySearch`、`AnySearch`、`FlashDeepSearch`、`VCPEverything`（未逐一验证 SSRF 防护，列入未验证事项）。
- **低风险（纯生成/查询类，无本地系统副作用）**：图像生成类（`FluxGen`/`GPTImageGen`/`GeminiImageGen`/`DoubaoGen`/`QwenImageGen`/`NanoBananaGen2`/`ZImageTurboGen`/`AgnesGen`/`AgnesVideoGen`/`VideoGenerator`）、`SciCalculator`、`TarotDivination`、`DigitalOracle` 等。

依据：以上表格数据来自对 `Plugin/*/plugin-manifest.json`（或 `.block`）的逐一读取；[docs/PLUGIN_ECOSYSTEM.md:50-60](../../VCPToolBox/docs/PLUGIN_ECOSYSTEM.md)（文档声称的插件统计，与实测不一致处已在上文指出）。

## 12. 子 Agent 与任务委派

`AgentAssistant` 插件（`hybridservice`/`direct`）承担 Agent 间通讯与任务委派：

- **即时通讯/定时联络**：`agent_name`+`prompt` 直接发起一次对某配置好的 Agent 的调用，`timely_contact` 可延迟到未来时间点（复用 `ToolExecutor._scheduleTimedToolCall` 的通用定时机制，写入 `VCPTimedContacts/` 目录由任务调度器到点执行）。
- **异步委托（`task_delegation:true`）**：`AgentAssistant.js` 内维护 `activeDelegations` Map，`delegationMaxRounds`（默认 15 轮，来自 `config.json` 的 `delegationMaxRounds`，`AgentAssistant.js:170`）是委托任务的自主循环轮数上限，`while (state.currentRound < DELEGATION_MAX_ROUNDS)`（`AgentAssistant.js:990`）驱动被委托 Agent 反复推理直到自行判定完成或达到轮数上限；`delegationTimeout` 限制单轮超时。达到最大轮数后**不会**报错，而是生成"达到最大轮数限制，任务尚未自动上报完成"的报告（`AgentAssistant.js:1101`）。
- **临时工具注入（`inject_tools`）**：允许发起方为单次委托临时拼接额外工具的说明文本到被委托 Agent 的 system 提示词尾部，manifest 明确声明"不影响 Agent 的长期固定系统提示词"，但这意味着发起方（可能是另一个 AI）可以在运行时临时扩大某个 Agent 会话内可见的工具面，这是一个**未做权限限制**的能力扩展点——任何能调用 `AgentAssistant` 的角色都能给任意配置好的下游 Agent 临时"塞"任意已加载的工具描述,只受限于"该工具本身是否需要审批/管理员校验"这一层。
- **`ScheduleManager`/`TimedTaskQuery`/`ScheduleBriefing`** 等插件提供了独立于 `AgentAssistant` 的定时任务能力，本次调查未逐一深入其后台调度实现细节（列入未验证事项）。

依据：[AgentAssistant.js:170,520,990-1101](../../VCPToolBox/Plugin/AgentAssistant/AgentAssistant.js)、[AgentAssistant/plugin-manifest.json:6,28](../../VCPToolBox/Plugin/AgentAssistant/plugin-manifest.json)、[toolExecutor.js:491-543](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)。

## 13. 安全审计（重点）

| # | 攻击路径 | 可利用性 | 前提条件 | 确认状态 |
|---|---|---|---|---|
| 1 | `PowerShellExecutor` 命令注入/黑名单绕过 | 中——需构造规避 `FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS` 子串匹配的命令变体（别名、拼接、编码） | 模型被诱导调用该插件（prompt injection 或用户直接要求） | 已确认存在设计上的黑名单绕过面；具体绕过 payload 未逐一验证 |
| 2 | `FileOperator` 路径穿越/任意文件读取 | 高——若插件启用且 `ALLOWED_DIRECTORIES` 未配置（默认模板值指向仓库根两级目录，宽松）或使用只读操作绕过白名单 | 插件启用；`ReadFile`/`FileInfo` 操作 + 绝对路径参数 | 已确认（第 4 节代码逻辑） |
| 3 | 审批身份混淆——任意 `VCP_Key` 持有者可批准/拒绝审批请求 | 高——只需持有全局 `VCP_Key` 并连接 WebSocket（不要求是"应批准者" | `toolApprovalConfig.enabled=true` 且已连接至少一个 WebSocket 客户端 | 已确认（第 5.3 节代码逻辑） |
| 4 | 审批系统 fail-closed 而非 fail-open（超时/无连接均拒绝） | N/A（这是安全特性，非漏洞） | — | 已确认：超时 reject，WS 未初始化直接 throw，均为拒绝执行 |
| 5 | 分布式节点冒充/工具名抢注 | 中——不能覆盖已存在工具名,但可注册任意新名字诱导选择 | 持有全局 `VCP_Key` 并以 `DistributedServer` 身份连接 | 已确认（第 8.3 节） |
| 6 | 异步插件回调伪造（`/plugin-callback/:pluginName/:taskId` 无鉴权） | 高——路径参数已知即可 POST 任意内容覆盖任务结果，进而注入下一轮对话上下文 | 知道/猜测 `pluginName` + `taskId`；`taskId` 多为 UUID,若插件自定义为可预测格式则风险更高 | 已确认端点无鉴权（第 9、10 节）；taskId 可预测性未逐一验证每个 async 插件 |
| 7 | 分布式插件回调转发未绑定来源（`plugin_callback_forward`） | 中——任意已连接分布式节点可为不属于自己的 taskId 伪造结果 | 持有全局 `VCP_Key` 并以 `DistributedServer` 身份连接；知道目标 taskId | 已确认代码未做归属校验（第 10 节） |
| 8 | `/v1/human/tool` 未鉴权猜测 | 已排除——实际需要 `Bearer serverKey`（中间件顺序已核实） | — | 已确认不是未鉴权端点，纠正可能的错误猜测 |
| 9 | CORS `origin:'*'` + 默认监听所有接口 | 中——扩大攻击面，具体可利用性取决于部署时的网络暴露与是否有反代收紧 | 服务暴露在可达的网络（容器端口映射/无防火墙） | 已确认代码层面无收紧（第 9 节） |
| 10 | prompt 注入直达高危插件 | 高——只要 system prompt 中包含 `{{VCP<PluginName>}}` 描述且该插件对应的调用文本混入模型上下文（如从网页抓取内容、工具返回结果中被模型误当作指令执行），模型可能在没有真实用户意图的情况下发起 `PowerShellExecutor`/`LinuxShellExecutor`/`FileOperator` 调用 | 依赖模型本身对注入内容的抵抗力,不是 VCPToolBox 独有问题,但 VCPToolBox 的纯文本协议（无结构化 tool schema 强约束）使"看起来像协议"的注入内容更容易被误解析 | 需进一步验证——未做端到端 prompt injection 测试,风险成立与否高度依赖上游模型行为 |
| 11 | `requiresAdmin` 非强制点——第三方/自定义插件可能忘记校验 `DECRYPTED_AUTH_CODE`/`decryptedAuthCode` | 中——取决于插件作者是否遵循约定 | 安装未经审查的第三方 `requiresAdmin:true` 插件 | 已确认框架层面不做强制校验（第 6.5 节）；当前仓库内三个已启用的 `requiresAdmin` 插件本身都正确校验 |
| 12 | 密钥与环境变量泄漏面 | 中——`DECRYPTED_AUTH_CODE`、`IMAGESERVER_IMAGE_KEY`/`IMAGESERVER_FILE_KEY` 等敏感值通过环境变量传给 stdio 子进程；若插件自身有日志泄漏或被攻破,这些值可能外泄 | 插件进程被攻破或插件自身调试日志包含环境变量 | 需进一步验证——未逐一检查所有 65 个启用插件是否有敏感值打日志的行为 |
| 13 | `approve-${Date.now()}-${Math.random()}` 审批 requestId 弱随机性 | 低——`requestId` 本身会被广播出去,不依赖其不可预测性作为安全边界,但若设计意图是"仅持有请求详情者可回应",弱随机性会略微放大风险 | 结合第 3 项已确认的身份校验缺失,该弱随机性影响有限（身份校验缺失是更主要的问题） | 已确认代码使用非密码学安全随机数（第 5.2 节） |

依据：见各节引用；本表综合第 4、5、6、8、9、10、12 节的代码证据。

## 14. 未验证事项与后续调查缺口

1. **PowerShellExecutor 黑名单绕过的具体 payload**：未实际构造并验证能规避 `FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS` 子串匹配的命令示例（如变量拼接、`Invoke-Expression` 间接调用、别名）。
2. **aio-hub VCP 解析器与本项目的逐字节等价性**：任务要求不深入 aio-hub 代码，因此“兼容风险”停留在结构性推断（模糊匹配/ESCAPE/扩展字段是否对称实现），未做实际互操作测试。
3. **`UrlFetch`/`TavilySearch`/`AnySearch`/`VCPEverything` 等网络类插件的 SSRF 防护**：未逐一审查是否有内网地址黑名单、重定向限制、协议白名单。
4. **`LinuxShellExecutor` 的 AST 语义基线与八层校验的绕过面**：因代码量大（近 3000 行）且是本项目安全工程投入最重的模块,本次仅确认其存在分层校验和可选沙箱后端,未逐层验证每一层校验逻辑本身是否有逃逸漏洞。
5. **Docker 部署下 `SANDBOX_BACKEND=docker` 的实际可用性**：是否需要挂载 docker socket、是否构成 docker-in-docker 逃逸面,未在容器化环境实测。
6. **`ImageServer`（`ImageFileServer` 插件）的 `/pw=<key>/images/*`、`/pw=<key>/files/*` key 校验强度**：未逐行复核该 key 的生成、比对与是否可枚举。
7. **`ScheduleManager`/`TimedTaskQuery`/`ScheduleBriefing` 等定时任务插件的后台调度实现**：未深入其持久化与到点执行的具体代码路径,只确认了 `ToolExecutor._scheduleTimedToolCall` 这一条通用定时机制。
8. **65 个启用插件中除本笔记重点复核的十余个之外的其余插件**：本次未逐一审查每个插件内部的参数校验、路径处理、命令拼接细节,风险等级表中的“低风险”分类基于插件功能类别的合理推断（生成类插件通常只调用外部 API），未逐一读取全部源码。
9. **prompt 注入到高危插件调用的端到端可行性**：未做实际的红队式测试（构造包含 VCP 协议文本的第三方网页内容,验证是否会被 `UrlFetch`/`FlashDeepSearch` 等插件抓取后混入上下文并被误解析为工具调用）。
10. **敏感环境变量在插件日志中的泄漏面**：未逐一检查各插件的 debug 日志输出是否会打印 `DECRYPTED_AUTH_CODE`、API Key 等敏感值。
