# VCPToolBox Agent 工具运行时调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：只读源码核对（对照 `eca06251f5687a52fbcd353cb8b04f42157882d0` 至当前 HEAD 的 38 个提交与 diff 重新定位关键结论，重点覆盖浏览器协议 v3、RiverMemo、多媒体、分布式取消）；未修改被调查仓库
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 是 VCP 生态里唯一真正执行工具、转发分布式调用并托管审批状态机的服务端。核心事实：

1. VCP 文本协议的解析不是简单正则，而是带模糊匹配开关（`fuzzyToolMatching`）的状态机扫描器；默认严格模式只认精确的 `<<<[TOOL_REQUEST]>>>` / `「始」...「末」`，开启模糊模式后能容忍 `{始}`、`<<[TOOL_REQUEST]>>` 等变体，这是一个可配置的“协议宽松开关”。
2. 审批系统是执行前的人工控制环节：审批请求依赖 `webSocketServer` 存在且当时至少有人/终端连接；超时后的默认行为是**拒绝执行**（reject，不是自动通过）。如果 `WebSocketServer` 未初始化，则在判定需要审批的那一刻直接抛错拒绝执行。审批请求通过 WebSocket **广播**给所有已认证的 `VCPLog` 客户端，任何持有同一个全局 `VCP_Key` 的客户端都可以发送 `tool_approval_response` 批准或拒绝任意请求——审批身份没有绑定发起者，也没有二次身份区分“谁有权批准”。
3. `requiresAdmin` 不是纯声明字段：对 `stdio` 插件会被注入 `DECRYPTED_AUTH_CODE` 环境变量，插件自己必须在内部比对；对 `hybridservice`/`direct` 插件会通过 `directContext.decryptedAuthCode` 传入。两条路径都要求插件自己做比对——**主服务端本身不会因为 requiresAdmin 而拒绝调用**，实际执行权掌握在插件代码手中。已确认 `PowerShellExecutor`、`LinuxShellExecutor`、`PluginManager`、`MediaRenderer` 插件内部确实做了比对，但这是插件自律，不是框架强制。
4. 分布式节点鉴权只有一层全局 `VCP_Key`（WebSocket 升级时校验），没有节点级别的独立密钥或证书；`register_tools` 消息可以让任意已连接的分布式节点注册新工具，但**同名工具会被跳过**（不能覆盖已存在工具），一定程度上防止了工具名冒充，但没有防止“注册一个从未存在过的、诱导性命名”的工具（如 `FileOperator2`）来钓鱼。
5. Shell/命令类插件的安全边界差异巨大：`PowerShellExecutor` 只有关键字黑名单 + 关键字驱动的验证码要求，没有语法级校验，命令拼接后直接 `Invoke-Expression`，理论上存在关键字绕过空间（如变量拼接、编码回避黑名单字符串匹配）；`LinuxShellExecutor` 则有更复杂的八层校验（黑名单正则、AST 基线、沙箱后端 bubblewrap/firejail/docker、资源限制、审计日志），安全工程量级明显更高。这两个插件在同一份 manifest 字段（`requiresAdmin`）下，实际受约束程度并不对等。

6. **推理内容双通道**：`reasoningContentAdapter.js` 让 `streamHandler`/`nonStreamHandler` 在“回注给客户端”的副本上把 `reasoning_content` 等字段按模型白名单（`ReasoningToContentModel`，默认示例 `kimi,claude`）改写为 `<think>` 标签正文，供不支持推理字段的前端显示；内部 VCP 循环、OneRing 入库与日记持久化仍只使用原始 `content`，两通道互不污染（`modules/handlers/streamHandler.js:172-218,332,375`）。
7. **工具解析的思考块剥离**：`ToolCallParser.stripReasoningBlocks()` 支持 `<think>`/`<thinking>` 大小写、空白、属性变体与同类嵌套；未闭合的开始标签会保守丢弃其后全部内容，未配对的结束标签只移除标签本身（`modules/vcpLoop/toolCallParser.js:22-70`）。
8. **工具结果隐私脱敏**：`toolApprovalConfig.json` 的 `privacyProtection.enabled` 开启后，工具结果在回注 AI 前按敏感键名模式、`sk-`/`ghp_` 等高置信 token 模式和环境变量赋值行做掩码（默认关闭，`modules/toolResultPrivacyGuard.js`）。
9. **分布式取消与结果归属绑定**：`executeDistributedTool()` 的 pending 项绑定目标 `serverId`，`tool_result` 只接受目标节点返回；节点声明 `capabilities.cancelTool=true` 时，超时会 best-effort 发送 `cancel_tool` 帧；目标节点断线会立即 reject 其全部 pending（`WebSocketServer.js:876-1002`）。
10. **插件热重载精细化**：manifest 变更分“元数据刷新”与“完整重载”两级——direct 常驻插件只合并展示字段、运行时变更提示需重启；static 插件按签名增量刷新并清理失效占位符与 cron；`loadPlugins()` 串行化并增加重载前 manifest 预校验（`Plugin.js:734-786,1067-1206,2326-2412`）。
11. **浏览器协议 v3 与托管运行时**：ChromeBridge 使用协议 v3（Grounded Markdown Agent 视图、稳定内容 Hash、快照去重、动作验证、默认敏感 DOM 脱敏、指标），`modules/browserRuntimeManager.js` 提供扩展 staging 清单 hash 完整性校验、运行时实例 ID 与上次关闭原因；`UrlFetch` 的 managed Chrome backend 已接线但默认关闭。
12. **插件面**：当前启用 69 个、禁用（`.block`）20 个（清单见第 11 节），含 `BrowserSearch`（复用托管 Chrome 持久化 Profile 的免 API 搜索）、`MediaRenderer`（HTML/SVG 渲染、FFmpeg 动画、程序音乐合成，`requiresAdmin`）、`PlaceholderExplorer` + `PlaceholderExplorerCommand`（占位符索引/编辑/预览）。

## 调用链总览

```text
上游 LLM 文本响应 (含 <<<[TOOL_REQUEST]>>> 块)
  -> ToolCallParser.parse()                (modules/vcpLoop/toolCallParser.js)
       -> stripReasoningBlocks()           剥离 <think>/<thinking>（支持嵌套与未闭合保护）
       -> extractNextToolBlock()           逐块扫描
       -> parseBlock() -> _scanFields()     状态机式字段扫描，兼容 ESCAPE 转义
  -> ToolCallParser.separate()             拆分 normal / archery(异步无阻塞) 调用
  -> streamHandler.js / nonStreamHandler.js  do-while 循环，maxVCPLoopStream/NonStream（默认 5）
       （可选）reasoningContentAdapter 为客户端展示副本改写 <think> 标签，不进内部循环
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
                                                            超时/断线 -> cancel_tool（节点声明时）或 reject
  -> 结果格式化（可选 toolResultPrivacyGuard 脱敏）-> WebSocketServer.broadcast('vcp_log', 'VCPLog')
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

`_scanFields()` 是逐字符状态机（`toolCallParser.js:198-277`）：先跳过空白/逗号，用 `/^[\w_]+/` 匹配 key，要求紧跟 `:`，再匹配起始标记，扫描到匹配的结束标记为止。关键细节：

- **参数值中含分隔符**：值内容被视为 `startMarker` 与 `endMarker` 之间的任意字符（不做嵌套计数），所以如果值本身包含 `「末」` 会被错误截断在第一个出现处；反过来说，值中出现 `「始」` 不会被特殊处理（因为扫描的是 end marker 而不是 nested start），因此嵌套 `「始」...「始」...「末」...「末」` 不被支持，第一个 `「末」` 就会结束字段。
- **转义机制**：`ESCAPE_MARKERS`（`「始ESCAPE」`/`「末ESCAPE」`）允许在值内容中放入本会被误判为控制符的文本，`_restoreEscapedLiterals()` 在提取后把转义映射还原为字面量（`toolCallParser.js:10-15,279-287`）。这解决了“参数中确实需要写出 `「始」`/`「末」` 字面文本”的问题，但要求模型正确使用 ESCAPE 变体，模型若直接输出裸 `「始」` 仍会被当作新字段起始。
- **同轮多块**：`parse()` 用 `while (searchOffset < contentWithoutThink.length)` 循环调用 `extractNextToolBlock`，支持同一响应中出现多个 `<<<[TOOL_REQUEST]>>>...<<<[END_TOOL_REQUEST]>>>` 块，逐个解析并加入 `toolCalls` 数组（`toolCallParser.js:81-96`）。
- **`<think>` 剥离**：解析前调用 `stripReasoningBlocks()`（`toolCallParser.js:22-70`）移除思考块。支持 `<think>`/`<thinking>` 两种标签、大小写/标签内空白/属性变体、同类与混合标签嵌套计数；**未闭合的开始标签会保守丢弃其后全部内容**（防止潜藏的工具调用被执行），**未配对的结束标签只移除标签本身、不吞掉其后正文**。但标签形态必须可被正则识别（如模型输出非标准变体标签则仍按普通文本处理）。
- **code fence**：解析器本身**不识别** Markdown 代码块围栏，即模型如果在 ```` ``` ```` 代码块里写出示例性的 `<<<[TOOL_REQUEST]>>>` 文本，仍会被当作真实调用解析执行。VCPToolBox 是 VCP 协议的服务端解析与执行方，VCPChat 则是同一协议的客户端展示方：前端在展示时会保护 code fence 内容不被当协议解释，但服务端解析层没有等价保护。这是**已确认**的边界情况。
- **畸形块处理**：若找不到匹配的结束标记（`_findBlockEnd` 返回 `null`），`extractNextToolBlock` 返回 `null`，整体 `parse()` 直接 `break` 停止扫描——意味着一个畸形的未闭合块会导致其后所有本应能解析的块也被丢弃（不会跳过继续扫描）。
- **流式截断**：解析发生在完整拼接后的 `currentAIContentForLoop` 上（`nonStreamHandler.js`/`streamHandler.js` 的循环变量），而不是逐 chunk 解析，因此半截的流式片段不会被误触发；但也意味着若流被提前中断（`abortController` 触发），未闭合的工具块永远不会被执行，这是预期行为而非 bug。
- **大小写/空白容忍**：模糊模式下标记匹配用 `i` 修饰符忽略大小写；`_skipWhitespace`/`_skipWhitespaceAndCommas` 用 `\s`/`[\s,]` 跳过任意空白与逗号分隔符，容忍字段间多余空格、换行和逗号缺失（`toolCallParser.js:289-301`）。

依据：[toolCallParser.js](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[toolMarkerFuzzyMatcher.js](../../VCPToolBox/modules/vcpLoop/toolMarkerFuzzyMatcher.js)、[toolApprovalManager.js:55-64](../../VCPToolBox/modules/toolApprovalManager.js)。

## 2. 工具定义与上下文注入

### 2.1 占位符体系

`PluginManager.buildVCPDescription()`（`Plugin.js:1027-1062`）遍历所有已加载插件，把每个插件 `capabilities.invocationCommands[].description` 拼接为一段说明文本，存入 `individualPluginDescriptions` Map，键为 `VCP<PluginName>`（如 `VCPFileOperator`）。这些说明文本通过 `{{VCP<PluginName>}}` 占位符注入到 system prompt——具体替换逻辑在 `modules/messageProcessor.js:783-806`，对 system prompt 文本做 `replaceAll('{{VCPxxx}}', description)`。这意味着**模型看到的工具描述就是插件作者在 `plugin-manifest.json` 里写的原始中文自然语言文本**，包括调用格式示例，没有结构化 JSON Schema 或 function-calling 格式的转换层。

### 2.2 `static` 插件的上下文注入与刷新周期

`static` 类型插件（如 `WeatherReporter`、`ScheduleBriefing`、`UserAuth`、`EmojiListGenerator`）通过 `staticPlaceholderValues` Map 提供占位符值。生命周期（`Plugin.js:402-438`）：

1. 启动时先把占位符设为 "正在加载中" 的占位文本；
2. 立即触发一次后台更新（fire-and-forget，不阻塞启动）；
3. 若 manifest 声明 `refreshIntervalCron`，用 `node-schedule` 按 cron 表达式周期性重新执行插件 stdio 进程并更新值；
4. 插件本轮无输出或超时不算错误，保留旧值（stale-while-revalidate 语义），除非从未成功过一次才置为 "unavailable"。

`{{VCP<PluginName>}}`（工具描述）与 `{{VCPxxx}}`（static 数据占位符）是两套不同的占位符命名空间，前者来自 `invocationCommands`，后者来自 `systemPromptPlaceholders`，替换逻辑分别在 `messageProcessor.js` 的不同代码段（约 748-806 行）处理。

依据：[Plugin.js:791-826,402-438](../../VCPToolBox/Plugin.js)、[messageProcessor.js:616-806](../../VCPToolBox/modules/messageProcessor.js)。

## 3. 调用链细节：并发、失败处理、迭代上限

- **迭代上限**：`streamHandler.js:70` 与 `nonStreamHandler.js:303` 都定义 `maxRecursion = maxVCPLoopStream/NonStream || 5`，即工具调用触发的 LLM 重新推理循环最多 5 轮（可通过环境变量 `MaxVCPLoopStream`/`MaxVCPLoopNonStream` 配置，`server.js:1202`）。这是"每轮响应中工具调用触发下一轮 LLM 请求"的上限，不是"单轮内工具调用数量"的上限——单轮内 `ToolCallParser.parse()` 可以解析出任意数量的工具块，全部通过 `Promise.all` 并发执行。
- **同轮并发语义**：`ToolExecutor.executeAll()`（`toolExecutor.js:396-400`）用 `Promise.all` 并发所有工具调用；由于 `execute()` 内部把所有异常都 catch 并转成 `_createErrorResult` 返回值而不是 reject（`toolExecutor.js:370-390`），`Promise.all` 永远不会因为单个工具失败而整体 reject，各工具结果互相独立回注。
- **超时**：stdio 插件默认超时 `synchronous` 60 秒、`asynchronous` 1800 秒（30 分钟），均可被 manifest 的 `communication.timeout` 覆盖（`Plugin.js:1598`）。分布式工具默认超时也是 60 秒，取自目标插件 manifest 的 `communication.timeout`（`WebSocketServer.js:913`）。
- **重试**：**未发现**任何自动重试机制——工具调用失败后直接把错误文本回注给模型，由模型自己决定是否重新发起调用。这是明确设计（回注错误让 AI 自愈），不是缺陷。
- **进程终止**：stdio 插件超时后调用 `_killProcessTree`（`Plugin.js:270-310`）强杀整个进程树：Windows 用 `taskkill /T /F /PID`（taskkill 失败时回退 `process.kill`），Linux/macOS 对以 `detached`（非 Windows）启动的进程组发 `process.kill(-pid, 'SIGKILL')`（进程组不存在时回退杀单进程，`Plugin.js:292-302`），防止子进程残留（`PowerShellExecutor.js` 内部也有等价的 `forceKillProcessTree`）。

依据：[toolExecutor.js:392-400](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)、[streamHandler.js:70](../../VCPToolBox/modules/handlers/streamHandler.js)、[nonStreamHandler.js:303](../../VCPToolBox/modules/handlers/nonStreamHandler.js)、[server.js:1202](../../VCPToolBox/server.js)。

## 4. 参数校验

**未发现**任何形式的 JSON Schema 或类型系统校验。`ToolCallParser._scanFields()` 把所有字段值都解析为**字符串**（`fields.push({ key, value: restoredValue })`，`toolCallParser.js:198-277`，push 在 `:267`），插件收到的 `args` 对象里所有值都是字符串，类型转换（转数字、转布尔）完全由各插件自己在内部做（例如 `PowerShellExecutor.js` 用 `args.executionType` 直接做字符串比较,`LinuxShellExecutor` 内部自行 `parseInt`）。

manifest 里没有 `parameters`/`schema` 字段声明参数类型或必需性；`capabilities.invocationCommands[].description` 是纯自然语言文本，模型是否提供了正确参数、参数是否缺失，只能在插件运行时暴露（插件自己 `throw new Error('缺少必需参数...')`）。这意味着：

- **路径参数**：如 `FileOperator` 的 `isPathAllowed()`（`Plugin/FileOperator/FileOperator.js:61-91`）用 `path.resolve` + 大小写不敏感前缀比较判断路径是否在 `ALLOWED_DIRECTORIES` 内；若未配置 `ALLOWED_DIRECTORIES`（`config.env.example` 默认值是 `../..`，即 VCPToolBox 根目录的上两级），则"允许所有路径"（`FileOperator.js:75-78`，注释明确写"如果没有配置允许的目录，则允许所有操作"）。只读操作（`ReadFile`/`FileInfo`）对绝对路径有豁免，可绕过 `ALLOWED_DIRECTORIES` 边界直接读取任意绝对路径文件（`FileOperator.js:82-86`）——**已确认**：只要该插件被启用且未设置严格的 `ALLOWED_DIRECTORIES`，模型可以让它读取沙箱目录之外任意文件（取决于运行插件进程的操作系统用户权限）。
- **命令参数**：`PowerShellExecutor` 对 `command` 只做关键字黑名单子串匹配（`FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS`，均为大小写不敏感的 `includes()` 判断，`PowerShellExecutor.js:150-158`），没有 AST 或语法分析，理论上可以用字符串拼接、别名、编码变体规避关键字匹配（例如 `Remove-Item` 别名 `ri` 不在默认黑名单里）。`LinuxShellExecutor` 相反有完整的黑名单正则 + AST 语义基线 + 沙箱后端（第 6 节详述）。
- **URL 参数**：`UrlFetch`、`TavilySearch` 等插件的 URL 参数未在本次调查中逐一复核是否对内网地址、重定向等做了过滤，列入未验证事项。

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

`PluginManager.processToolCall()` 中（`Plugin.js:1205-1279`）：

1. 调 `toolApprovalManager.getApprovalDecision()` 判定是否需要审批；
2. 若需要，生成 `requestId`（`approve-${Date.now()}-${random}`，**不是密码学安全的随机数**，仅用 `Math.random().toString(36)` 取 7 位——`Plugin.js:1207`），创建一个 Promise 并存入 `this.pendingApprovals` Map（`Plugin.js:1214-1229`）；
3. 通过 `webSocketServer.broadcast({type:'tool_approval_request', data:{...}}, 'VCPLog')` 把请求**广播给所有已连接的 `VCPLog` 类型客户端**（`Plugin.js:1231-1252`）；
4. `setTimeout` 按 `timeoutMinutes`（默认 5 分钟）设置超时，超时后从 `pendingApprovals` 删除并 `reject`（`Plugin.js:1215-1221`）——**超时后的默认动作是拒绝执行（fail-closed），不是自动放行**，本项目在"超时"这一单一维度上是 fail-closed 的。
5. 若 `webSocketServer` 未初始化（理论上不会发生，因为它在 `initialize()` 中先于插件加载完成注入），会直接从 `pendingApprovals` 删除并 throw，同样是拒绝执行而非放行（`Plugin.js:1247-1252`）。

### 5.3 审批响应的身份绑定

`WebSocketServer.js:484-494` 收到 `tool_approval_response` 消息时，**只要消息来自任意已认证的 WebSocket 连接**（不限定 `clientType==='VCPLog'`，代码里判断的是 `parsedMessage.type === 'tool_approval_response'`，位于 `else if` 链的通用分支，未按 `ws.clientType` 过滤），就会调用 `pluginManager.handleApprovalResponse(requestId, approved, reason)`。`handleApprovalResponse()`（`Plugin.js:1786-1826`）只用 `requestId` 从 `pendingApprovals` 中查找待处理项，**没有校验发起批准的客户端身份与发起该审批请求的上下文是否匹配**，也没有校验发送者是否具备"审批权限"这一独立角色。

结合 WebSocket 鉴权只有一个全局共享的 `VCP_Key`（第 9 节详述），**任何持有 `VCP_Key` 的客户端（包括本应只用于日志展示的 `VCPLog` 只读消费者、`ChromeControl`、`AdminPanel` 等）收到广播的 `requestId` 后都可以主动发送 `tool_approval_response` 批准或拒绝一个审批请求**。`requestId` 本身通过广播发给所有 `VCPLog` 客户端，因此只要客户端连接了 `VCPLog` 通道就能看到 `requestId` 并回发批准。这是**已确认**的机制：审批的最终决定权不限定在"应批准的人"，任何持 Key 的已连接客户端都可以对广播的审批请求作出批准或拒绝响应。

### 5.4 静默拒绝与用户备注

`notifyAiOnReject=false` 的规则被拒绝时，`approval.resolve({silentRejected:true})`，`PluginManager.processToolCall` 检测到 `silentRejected===true` 时返回 `undefined`（`Plugin.js:1254-1274`），意味着这次调用对 AI 完全不可见（AI 既不知道被拒绝也不知道调用发生过），只有人工审批者留下的 `reason` 备注会被记录到日志。这是一个隐蔽性设计，用于防止 AI 反复尝试同一被拒绝的敏感操作。

### 5.5 关机清理与结果隐私脱敏

- **关机清理**：`shutdownAllPlugins()` 会先清除插件文件 watcher，并对 `pendingApprovals` 中所有待审批项执行 reject（`Plugin.js:671-706`），避免待审批 Promise 悬挂到重启。
- **结果隐私脱敏**：`PluginManager.processToolCall` 的成功与错误结果在回注 AI 前统一经过 `_sanitizeToolResultForAi()`（`Plugin.js:113-123,1433,1459`），调用 `modules/toolResultPrivacyGuard.js`。开启 `toolApprovalConfig.json` 的 `privacyProtection.enabled`（默认 `false`）后：按敏感键名模式（`api_key`/`token`/`password`/`credential` 等）掩码键值、按 `sk-`/`sk-proj-`/`xoxb`/`ghp_`/`AKIA` 等模式掩码高置信 token、按 `KEY=value` 行模式掩码环境变量赋值；`data:...;base64` URI 整体保留。掩码保留前后 4 个字符，`minSecretLength=8` 以下不掩码。

依据：[toolApprovalManager.js:10-225](../../VCPToolBox/modules/toolApprovalManager.js)、[Plugin.js:671-706,113-123,1205-1230,1786-1826](../../VCPToolBox/Plugin.js)、[WebSocketServer.js:484-494](../../VCPToolBox/WebSocketServer.js)、[toolResultPrivacyGuard.js](../../VCPToolBox/modules/toolResultPrivacyGuard.js)。

## 6. 插件模型：manifest 字段、类型与执行协议

### 6.1 manifest 加载与生命周期

`PluginManager.loadPlugins()`（`Plugin.js:757` 起）扫描 `Plugin/` 下每个子目录的 `plugin-manifest.json`；缺少 `name`/`pluginType`/`entryPoint` 任一字段的 manifest 会被静默跳过（`Plugin.js:838`）。禁用插件的方式是把文件改名为 `plugin-manifest.json.block`（当前 HEAD 有 20 个插件处于此状态，见第 11 节插件清单）。

插件生命周期变化（`Plugin.js`）：

- **重载串行化**：`loadPlugins()` 通过 `pluginLoadPromise` 串行执行并合并“重载期间再次请求”的场景（`Plugin.js:757-786`），不再出现并发重载互相破坏插件表。
- **重载前预校验**：`_validateLocalPluginManifestsBeforeReload()` 在关闭任何现有模块前先对全部启用清单做 JSON 解析校验，编辑中的半截 JSON 不会把正常运行的注册表破坏为部分加载状态（`Plugin.js:734-753`）。
- **两级热更新**：`_flushPluginManifestChanges()`（`Plugin.js:2472` 起）先对变更清单做运行时签名比较：仅展示字段变化时走 `refreshPluginManifestMetadata` 元数据刷新（不重启任何模块，direct 常驻插件的运行字段保持内存版本）；运行字段变化时 direct 插件提示需重启、其余插件走完整重载。
- **static 插件增量刷新**：`initializeStaticPlugins()`（`Plugin.js:477` 起）按 `_getStaticPluginSignature()`（entryPoint/communication/cron/configSchema/占位符声明）判断是否需要刷新；新增/删除/禁用插件或 cron 变更会精确取消失效 job、清理已删除占位符，分布式占位符仍由 serverId 生命周期管理。
- **watcher 启动时机**：`startPluginWatcher()` 改为在初始化末尾显式调用（`server.js:1628-1631`），避免启动阶段文件写入触发多余重载；`shutdownAllPlugins()` 会关闭 watcher 并结算全部待审批项。

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

- **`stdio`**：`executePlugin`（`Plugin.js:1472` 起，spawn 调用在 `:1577`，超时计算在 `:1598`）用 `child_process.spawn(command, args, {cwd: plugin.basePath, shell: true, env: finalEnv, windowsHide: true, detached: process.platform !== 'win32'})`。**注意 `shell: true`**——这意味着 `entryPoint.command` 字符串会经过系统 shell 解析，如果该字符串本身可控（目前是 manifest 固定值，不受运行期参数拼接），风险有限，但这是命令注入的潜在放大面，若未来任何代码路径允许拼接用户输入到 `entryPoint.command`，将直接构成 shell 注入。当前**未发现**此类拼接（`command` 固定来自 manifest 静态配置）。非 Windows 平台 spawn 带 `detached` 建立进程组，配合 `_killProcessTree` 的 Unix 进程组强杀（见第 7 节）。
- **`direct`**：manifest 声明 `entryPoint.script`，`loadPlugins()` 用 `require()` 动态加载该模块到进程内（`Plugin.js:856-871`），模块需暴露 `initialize()`/`processToolCall()`/`shutdown()` 等约定方法。这意味着 `direct` 协议插件与主服务进程**同权限、同内存空间**运行，没有任何进程隔离。
- **`distributed`**：不在本地 spawn 任何进程，转发到远程节点的 WebSocket 连接（详见第 8 节）。

### 6.4 Node/Python/native 入口

`entryPoint.type` 可以是 `nodejs`（`command: "node xxx.js"`）；仓库内也存在 Python 插件（如 `SciCalculator` 有专门的预热逻辑 `prewarmPythonPlugins()`，`Plugin.js:583` 起，用 `spawn('python', ['-c', 'import sympy...'])` 预热科学计算库）和 Rust 原生模块（`rust-vexus-lite`，通过 Dockerfile 编译为 `.node` N-API addon，供向量检索使用，不是通过 `plugin-manifest.json` 的 `entryPoint` 机制加载，而是被 Node 主进程直接 `require`）。另有两类 Rust **二进制插件**以 Node 包装器为 manifest 入口：`CodeSearcher`（`c4c4d00`→`1ae9b63c` 起 entryPoint 由直接执行 exe 改为 `node CodeSearcher.js`，包装器按 `win32/linux/darwin × x64/arm64` 三元组在候选路径中选原生二进制再 spawn，`Plugin/CodeSearcher/CodeSearcher.js:10-61`）与 `DailyNoteSearcher`（hybridservice 常驻 Rust HTTP 服务，JS 桥同样按平台选二进制并带 instance-id/关闭令牌的健康与优雅退出，`Plugin/DailyNoteSearcher/DailyNoteSearcher.js:42-87,290-345`）。环境变量传递给子进程插件时，除插件自身 `config.env` 外，主服务额外注入 `PROJECT_BASE_PATH`、`VCP_REQUEST_IP`、`SERVER_PORT`、`PYTHONIOENCODING=utf-8`,若 `requiresAdmin` 则注入 `DECRYPTED_AUTH_CODE`，若为 `asynchronous` 类型则注入 `CALLBACK_BASE_URL`/`PLUGIN_NAME_FOR_CALLBACK`（`Plugin.js:1494-1566`）。

### 6.5 `requiresAdmin` 的实际生效点

**已确认**：主框架本身对 `requiresAdmin` 只做两件事——(a) 给 stdio 插件注入 `DECRYPTED_AUTH_CODE` 环境变量（`Plugin.js:1506-1507`）；(b) 给 `hybridservice`/`direct` 插件的 `directContext` 注入 `decryptedAuthCode` 字段（`Plugin.js:1318-1327`）。**框架不会因为 `requiresAdmin:true` 而拦截调用本身**——如果插件代码忘记比对这个值，`requiresAdmin` 就形同虚设。已复核的四个 `requiresAdmin:true` 插件（`PowerShellExecutor`、`LinuxShellExecutor`、`PluginManager`、`MediaRenderer`）都在自己代码里做了比对（`MediaRenderer.js:452-458` 在启动合成子进程前强制校验 6 位管理员验证码），但这是"插件作者自律 + 现有插件确实做了"的经验事实，不是框架层面的强制保证；若安装第三方或自写的 `requiresAdmin:true` 插件但忘记校验，`requiresAdmin` 对其调用不再构成任何约束。

依据：[Plugin.js:1472-1632,1318-1327,1506-1507](../../VCPToolBox/Plugin.js)、[PowerShellExecutor.js](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)、[PluginManager.js:35-50](../../VCPToolBox/Plugin/PluginManager/PluginManager.js)、[MediaRenderer.js:452-458](../../VCPToolBox/Plugin/MediaRenderer/MediaRenderer.js)。

## 7. 执行位置与隔离

- **stdio 插件**：与主 Node 进程同一台机器、同一操作系统用户权限下运行的独立子进程。**没有**任何 OS 级沙箱、chroot、容器隔离或降权（`spawn` 调用未指定 `uid`/`gid`，Windows 平台本身也没有等价机制）。子进程能访问的文件系统范围仅受该插件代码自身逻辑（如 `FileOperator` 的 `ALLOWED_DIRECTORIES`）限制，不是操作系统强制边界。
- **`direct`/`hybridservice` 插件**：与主服务进程同一内存空间、同一权限，本质上是主进程的一部分，没有任何隔离概念。
- **例外——`LinuxShellExecutor`**：这是唯一实现了实际沙箱后端的插件，`config.env` 中 `SANDBOX_BACKEND` 可选 `bubblewrap`/`firejail`/`docker`/`none`（默认 `none`，即不隔离），并配置 CPU/文件大小/进程数/文件描述符/虚拟内存的 `RLIMIT_*` 资源限制（`LinuxShellExecutor/config.env:15-30`）。这是插件自带的隔离能力，不是框架统一提供的。
- **Docker 部署**：`Dockerfile`/`docker-compose.yml` 显示整个 VCPToolBox（含所有插件）作为**单一容器**运行，`docker-compose.yml` 把整个仓库目录 bind-mount 进容器（`- .:/usr/src/app`），`Dockerfile` 里 `USER appuser` 那行是**被注释掉的**（`Dockerfile:187`，`# USER appuser`），即容器内进程默认以 root 运行。容器本身是唯一的"边界"，容器内所有插件之间没有进一步隔离；`LinuxShellExecutor` 若在容器内设 `SANDBOX_BACKEND=docker`，则涉及 docker-in-docker 或挂载 docker socket 的额外风险（**未在本次调查中验证该配置在容器化部署下是否真的可用**）。
- **超时与僵尸进程**：`_killProcessTree()`（`Plugin.js:270-310`）及 `PowerShellExecutor.js` 里的 `forceKillProcessTree()` 均在超时后强杀整个进程树，防止子进程残留为僵尸/孤儿进程：Windows 用 `taskkill /F /T /PID`（taskkill 失败回退 `process.kill`），Linux/macOS 用 `process.kill(-pid, 'SIGKILL')` 杀进程组（进程组不存在时回退杀单进程）。通用 `executePlugin` 路径在非 Windows 平台以 `detached` spawn 建立进程组，`_killProcessTree` 即有 Unix 进程组等价物（`Plugin.js:292-302,335-340,1577-1582`）；`LinuxShellExecutor` 自身对其管理的命令仍有独立的进程生命周期管理。

依据：[Plugin.js:1472-1632](../../VCPToolBox/Plugin.js)、[PowerShellExecutor.js:47-58](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)、[LinuxShellExecutor/config.env](../../VCPToolBox/Plugin/LinuxShellExecutor/config.env)、[Dockerfile:187,191](../../VCPToolBox/Dockerfile)、[docker-compose.yml](../../VCPToolBox/docker-compose.yml)。

## 8. 分布式节点协议

### 8.1 协议流程

```text
分布式节点 (远端 VCPToolBox 实例或自定义客户端)
  -> WebSocket 连接 wss://host:port/vcp-distributed-server/VCP_Key=<key>
  -> register_tools { tools: [manifest, ...], capabilities: {...} }     声明工具与能力
   主服务器
  -> 收到 AI 对某分布式工具的调用
  -> executeDistributedTool(serverId, toolName, args, timeout)
       -> { type: 'execute_tool', data: { requestId, toolName, toolArgs } }  经 WS 发给该节点
   分布式节点执行完毕
  -> { type: 'tool_result', data: { requestId, status, result/error } }
   主服务器 pendingToolRequests.get(requestId) -> resolve/reject
  （超时且节点声明 capabilities.cancelTool=true）
  -> { type: 'cancel_tool', data: { requestId } }   best-effort 发送一次
```

### 8.2 节点鉴权

WebSocket 升级请求时校验 URL 路径里的 `VCP_Key` 参数是否等于服务器配置的**全局唯一** `vcpKey`（`WebSocketServer.js:230-236`）。**没有节点级别的独立密钥、证书或双向 TLS**——所有连接类型（`VCPLog`、`DistributedServer`、`ChromeControl`、`AdminPanel` 等）共用同一个 `VCP_Key`。这意味着所有连接类型共用同一个 Key：持有该 Key 的任何一方既可以注册分布式工具，也可以对审批请求作出批准/拒绝响应，也可以作为 AdminPanel 客户端连接——这是**已确认**的机制：所有 WebSocket 通道共享同一份鉴权凭据，没有按通道区分的独立密钥。

### 8.3 节点声明工具的可信度

`registerDistributedTools()`（`Plugin.js:1888` 起）对新注册工具做的唯一检查是"名称是否已存在于 `this.plugins`"——若已存在则跳过（不覆盖），否则接受并标记 `isDistributed:true`、`serverId`，displayName 加 `[云端]` 前缀。**已确认**：分布式节点**不能覆盖已存在的本地或其他节点的工具名**，但**可以自由注册任意新名字的工具**，包括故意构造与知名本地插件高度相似的名字（如 `FileOperatorPro`、`FileOperator_v2`）来诱导模型误选。manifest 内容（包括 `invocationCommands` 里的调用说明文本、是否 `requiresAdmin`）完全由远程节点自行提供，主服务器不做任何 schema 或内容审查就直接采纳并注入到 system prompt 描述中。

### 8.4 转发调用的审批是否仍然生效

**已确认生效**：`PluginManager.processToolCall()` 中审批判定逻辑（`toolApprovalManager.getApprovalDecision`）发生在分支判断"是否为分布式插件"**之前**（`Plugin.js:1205` 位于 `if (plugin.isDistributed)` 判断之前），因此只要 `toolApprovalConfig.json` 中把该工具名列入 `approvalList`，分布式转发调用同样会先触发人工审批流程，审批通过后才会转发执行。

### 8.5 取消传播与结果归属绑定

`WebSocketServer.js` 有三项分布式加固（提交 `a8e4e41d` 等）：

- **`tool_result` 归属绑定**：`pendingToolRequests` 的条目携带 `serverId`，收到 `tool_result` 时若消息来源节点不是目标节点，则记录警告并**忽略**该消息，不完成 Promise（`WebSocketServer.js:851-869`），关闭了“任何节点都可以用同一个 requestId 完成/伪造结果”的缺口；`plugin_callback_forward` 的来源节点绑定仍未加（见第 10 节）。
- **取消传播**：节点在 `register_tools` 时可声明 `capabilities.cancelTool: true`；`executeDistributedTool()` 超时时，若目标 socket 仍 OPEN 且节点声明了该能力，则 best-effort 发送一次 `cancel_tool` 帧（`sendCancelToolIfSupported`，`WebSocketServer.js:876-892`）。旧节点未声明能力时收不到该帧，但节点侧自己的本地 deadline/AbortController 仍独立生效——文档明确两者都是必要边界（`docs/DISTRIBUTED_ARCHITECTURE.md`）。
- **断线清理**：节点断开时 `rejectPendingToolRequestsForServer()` 立即 reject 该节点全部 pending，不会让请求悬挂到超时；`executeDistributedTool()` 发送消息失败也会立即 reject（`WebSocketServer.js:508-511,900-908,944-971`）。配套新增 `tests/distributedToolCancellation.test.js`。

依据：[WebSocketServer.js:191-236,508-511,851-985](../../VCPToolBox/WebSocketServer.js)、[Plugin.js:1205,1669-1694](../../VCPToolBox/Plugin.js)、[docs/DISTRIBUTED_ARCHITECTURE.md](../../VCPToolBox/docs/DISTRIBUTED_ARCHITECTURE.md)。

## 9. HTTP 接口与鉴权

| 路径 | 鉴权方式 | 说明 |
|---|---|---|
| `/v1/chat/completions`、`/v1/chatvcp/completions`、`/v1/models`、`/v1/schedule_task`、`/v1/interrupt`、`/v1/human/tool` | `Authorization: Bearer <serverKey>`（`server.js:654,876`，`serverKey=process.env.Key`） | 全局中间件在 `/admin_api`、`/AdminPanel`、图片/文件服务路径、`/plugin-callback` 之外的所有路径强制要求 Bearer token（`server.js:853-877`），`/v1/human/tool` 定义在该中间件**之后**（第 1249-1250 行 > 第 853 行），故**已确认需要 Bearer 鉴权**，不是无鉴权端点 |
| `/admin_api/*`、`/AdminPanel/*` | HTTP Basic Auth（`basic-auth` 库）或 Cookie 里的 `admin_auth`（server.js:658-747），凭据来自 `AdminUsername`/`AdminPassword` 环境变量；未配置这两个变量时管理面板整体 503 禁用 | 有登录失败次数限制与临时 IP 封禁（`tempBlocks`），少数只读监控端点（`/admin_api/system-monitor` 等）豁免封禁计数但仍需通过 Basic Auth |
| `/pw=<key>/images/*`、`/pw=<key>/files/*` | URL 路径内嵌的 key（由 `ImageServer` 插件生成/校验，未在本次调查中逐行复核该 key 比对逻辑的强度） | 豁免全局 Bearer 中间件（`server.js:859-868`） |
| `/plugin-callback/:pluginName/:taskId` | **无鉴权**（`server.js:870-872` 显式豁免 Bearer 检查） | 见第 10 节"回调伪造"分析 |
| WebSocket `/VCPlog/VCP_Key=`、`/vcpinfo/VCP_Key=`、`/vcp-distributed-server/VCP_Key=`、`/vcp-chrome-control/VCP_Key=`、`/vcp-chrome-observer/VCP_Key=`、`/vcp-admin-panel/VCP_Key=` | 全局共享 `VCP_Key`（第 8.2 节） | 所有通道共用同一个 Key，无按通道区分的细粒度权限 |

- **CORS**：`app.use(cors({origin:'*'}))`（`server.js:556`），对所有来源开放跨域——若浏览器端脚本获得受害者浏览器执行环境（如 XSS）且知道 Bearer token，可跨域调用任意 `/v1/*` 接口；即使不知道 token，`/plugin-callback/*` 无鉴权路径也可被任意来源的网页直接 POST。
- **默认监听地址**：`app.listen(port, ...)`（`server.js:1685`），**未指定 host 参数**，Node.js `http.Server.listen(port)` 默认监听所有网络接口（`0.0.0.0`/`::`），意味着容器化部署下端口映射出去即对公网可达，未观察到默认绑定 `127.0.0.1` 的收紧配置。这是**已确认**的默认监听行为，实际可达性取决于反向代理/防火墙/端口映射策略。

依据：[server.js:556,658-747,853-877,1249-1300,1460-1504,1685](../../VCPToolBox/server.js)。

## 10. 结果处理与回注

- **结果格式**：`ToolExecutor._formatResult()`（`toolExecutor.js:448-473`）优先识别 `result.data.content`/`result.content` 形式的富内容数组（`[{type:'text', text:...}]`），否则把对象 `JSON.stringify(result, null, 2)` 或直接转字符串，包装为统一的 `{type:'text', text}` 内容块回注给 LLM。**未发现**任何长度截断逻辑在 `ToolExecutor` 层——工具返回多长的文本就原样拼回对话上下文，可能导致单次工具调用输出把上下文窗口占满（VCPToolBox 在框架层没有结果截断保护，是否截断取决于各插件自身实现）。回注前经 `_sanitizeToolResultForAi` 可选隐私脱敏（见 5.5）。
- **推理内容不进入工具循环**：`reasoning_content`/`reasoning`/`thinking` 等字段在 `streamHandler` 的 `appendDelta`（`streamHandler.js:158-170`）与 `nonStreamHandler` 的 `extractVisibleContent`（`nonStreamHandler.js:272-276`）中都只写入日志字段 `message.reasoning_content`，`collectedContentThisTurn`/`currentAIContentForLoop` 始终只累计正文 `content`。`ReasoningToContentEnabled` 的客户端展示转换在独立的 `transformParsedDataForClient` 副本上进行（`streamHandler.js:172-218`，调用于 `:332`/`:375`），转换结果只影响转发给客户端的 SSE，不进入 VCP 循环、OneRing 入库或日记。
- **错误形态**：同步执行错误统一包装为 `throw new Error(JSON.stringify({plugin_error: message, ...}))` 字符串化 JSON，上层 catch 后再 `JSON.parse` 尝试还原结构化错误对象（`server.js:1279-1284`）；解析失败则退化为 `{error:'Internal Server Error', details: error.message}`。
- **异步插件回调注入路径**：`asynchronous` 类型插件的后续结果通过 **无鉴权** 的 `POST /plugin-callback/:pluginName/:taskId` 端点回传（`server.js:1460-1504`，该路径在 Bearer 鉴权中间件里被显式豁免，`server.js:870-872`）。服务器收到请求后：(1) 直接把 `req.body` 原样写入 `VCPAsyncResults/${pluginName}-${taskId}.json` 文件；(2) 若该插件 manifest 声明了 `webSocketPush.enabled`，则把回调内容原样广播给对应 WebSocket 客户端类型。**未做任何签名、来源校验或 taskId 随机性强度检查**——`taskId` 由插件自身生成（多数用 `crypto.randomUUID()`，如 `PowerShellExecutor.js` 的后台任务 ID），只要调用方获知 `pluginName`+`taskId`，就可以用自定义内容覆盖该任务的"结果"，进而通过 `{{VCP_ASYNC_RESULT::Plugin::id}}` 占位符把该内容注入到下一轮系统提示词/对话历史中（`modules/messageProcessor.js:828-867` 直接读取该 JSON 文件内容拼入回复文本，不做二次校验）。这是**已确认**的机制：该端点对回调内容不做签名或来源校验。
- **分布式插件回调转发**：`handleDistributedPluginCallback()`（`WebSocketServer.js:95-144`）走 WebSocket `plugin_callback_forward` 消息类型，同样只检查 `pluginName`/`taskId` 字段是否存在，不做任何来源节点与任务归属的绑定校验——任何已连接的分布式节点都可以为**不属于自己**的 `taskId` 发送 `plugin_callback_forward` 消息，只要获知目标 taskId。

依据：[toolExecutor.js:448-473](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)、[server.js:870-872,1460-1504](../../VCPToolBox/server.js)、[messageProcessor.js:828-867](../../VCPToolBox/modules/messageProcessor.js)、[WebSocketServer.js:95-144](../../VCPToolBox/WebSocketServer.js)。

## 11. 插件清单

以下为**当前 HEAD（`1ae9b63c`，`Plugin/` 目录，89 个子目录，不含 `AGENTS.md`）实际存在的 manifest** 逐一读取的结果。启用判定标准：存在 `plugin-manifest.json`（非 `.block`）。共 69 个启用、20 个禁用（`.block`）。这与 `docs/PLUGIN_ECOSYSTEM.md` 声称的"总计 79 活跃插件"**不一致**——文档统计口径把仓库内所有插件目录（含 `.block` 禁用态）都算作"活跃"，而实际当前 checkout 启用的插件数是 69，禁用（`.block`）20 个，两者之和 89 也与文档的 79 不完全对应，说明文档的插件类型分布统计（`static`~10、`service`~8 等）是历史快照，**不能作为当前启用状态的依据**，本笔记以下表格为准。其中 `ChromeBridge` 为 2.4.0（Grounded Markdown 增加正文图片/视频画面语义标注与 `get_page_image` 命令、Popup 人工 Managed 选择、agent 不再隐式控制托管运行时）、`CodeSearcher` 入口为 `node CodeSearcher.js`（Node 包装器按平台选原生二进制）、`UrlFetch` 为 0.3.0（PDF 文本解析与 50MB 上限，本地 `file://` 亦支持 .pdf）。

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
| BrowserSearch | BrowserSearch | hybridservice | direct | 启用 | 否 |
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
| MediaRenderer | MediaRenderer | hybridservice | direct | 启用 | **是** |
| NCBIDatasets | NCBIDatasets | synchronous | stdio | 禁用 | 否 |
| NanoBananaGen2 | NanoBananaGen2 | synchronous | stdio | 启用 | 否 |
| OneRing | OneRing | messagePreprocessor | direct | 启用 | 否 |
| OpenHerPersona | OpenHerPersona | hybridservice | direct | 启用 | 否 |
| PaperReader | PaperReader | synchronous | stdio | 禁用 | 否 |
| PluginManager | PluginManager | hybridservice | direct | 启用 | **是** |
| PluginSourceViewer | ServerPluginSourceViewer | synchronous | stdio | 启用 | 否 |
| PlaceholderExplorer | PlaceholderExplorer | static | stdio | 启用 | 否 |
| PlaceholderExplorerCommand | PlaceholderExplorerCommand | synchronous | stdio | 启用 | 否 |
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

依据：以上表格数据来自对 `Plugin/*/plugin-manifest.json`（或 `.block`）的逐一读取；[docs/PLUGIN_ECOSYSTEM.md:50-60](../../VCPToolBox/docs/PLUGIN_ECOSYSTEM.md)（文档声称的插件统计，与实测不一致处已在上文指出）。

## 12. 子 Agent 与任务委派

`AgentAssistant` 插件（`hybridservice`/`direct`）承担 Agent 间通讯与任务委派：

- **即时通讯/定时联络**：`agent_name`+`prompt` 直接发起一次对某配置好的 Agent 的调用，`timely_contact` 可延迟到未来时间点（复用 `ToolExecutor._scheduleTimedToolCall` 的通用定时机制，写入 `VCPTimedContacts/` 目录由任务调度器到点执行）。`removeVCPThinkingChain()` 按 `responseFromVCP.data.model` 判断是否启用 `ReasoningToContent`，启用时会一并剥离主总线转换到正文的 `<think>`/`<thinking>` 标签块（含未闭合块），防止推理标签污染 AA 会话历史（`AgentAssistant.js:307-349,888-895`）。
- **异步委托（`task_delegation:true`）**：`AgentAssistant.js` 内维护 `activeDelegations` Map，`delegationMaxRounds`（默认 15 轮，来自 `config.json` 的 `delegationMaxRounds`，`AgentAssistant.js:181`）是委托任务的自主循环轮数上限，`while (state.currentRound < DELEGATION_MAX_ROUNDS)`（`AgentAssistant.js:1016`）驱动被委托 Agent 反复推理直到自行判定完成或达到轮数上限；`delegationTimeout` 限制单轮超时。达到最大轮数后**不会**报错，而是生成"达到最大轮数限制，任务尚未自动上报完成"的报告（`AgentAssistant.js:1128`）。
- **临时工具注入（`inject_tools`）**：允许发起方为单次委托临时拼接额外工具的说明文本到被委托 Agent 的 system 提示词尾部，manifest 明确声明"不影响 Agent 的长期固定系统提示词"，但这意味着发起方（可能是另一个 AI）可以在运行时临时扩大某个 Agent 会话内可见的工具面，这是一个**未做权限限制**的能力扩展点——任何能调用 `AgentAssistant` 的角色都能给任意配置好的下游 Agent 临时"塞"任意已加载的工具描述,只受限于"该工具本身是否需要审批/管理员校验"这一层。
- **`ScheduleManager`/`TimedTaskQuery`/`ScheduleBriefing`** 等插件提供了独立于 `AgentAssistant` 的定时任务能力，本次调查未逐一深入其后台调度实现细节（列入未验证事项）。

依据：[AgentAssistant.js:181,647-711,1016-1128](../../VCPToolBox/Plugin/AgentAssistant/AgentAssistant.js)、[AgentAssistant/plugin-manifest.json:6,28](../../VCPToolBox/Plugin/AgentAssistant/plugin-manifest.json)、[toolExecutor.js:491-543](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)。

## 13. 未验证事项与后续调查缺口

1. **PowerShellExecutor 的命令校验强度**：其命令校验基于 `FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS` 子串匹配，本次未逐一验证各命令变体（如变量拼接、`Invoke-Expression` 间接调用、别名）对校验结果的影响。
2. **与 aio-hub 解析器的兼容性**：未在本次范围内深入验证。
3. **网络类插件的地址校验**：`UrlFetch`/`TavilySearch`/`AnySearch`/`VCPEverything`/`BrowserSearch` 等是否对内网地址、重定向、协议类型有过滤，未逐一验证（`BrowserSearch` 的 manifest 声明"网页内容是不可信数据"并做区域重定向观测，但其 URL 过滤细节未逐行复核）。
4. **`LinuxShellExecutor` 的分层校验**：因代码量大（近 3000 行），本次仅确认其存在分层校验和可选沙箱后端，未逐层验证每一层校验逻辑对异常输入的完整处理。
5. **Docker 部署下 `SANDBOX_BACKEND=docker` 的实际可用性**：是否需要挂载 docker socket、在容器化部署下是否真正可用，未在容器化环境实测。
6. **`ImageServer`（`ImageFileServer` 插件）的 `/pw=<key>/images/*`、`/pw=<key>/files/*` key 校验逻辑**：未逐行复核该 key 的生成与比对。
7. **`ScheduleManager`/`TimedTaskQuery`/`ScheduleBriefing` 等定时任务插件的后台调度实现**：未深入其持久化与到点执行的具体代码路径,只确认了 `ToolExecutor._scheduleTimedToolCall` 这一条通用定时机制；`VCPTaskAssistant` 的调度链已在新笔记（独特功能）中单独确认。
8. **除本笔记重点复核的插件之外的其余插件**：本次未逐一审查每个插件内部的参数校验、路径处理、命令拼接细节，其余插件的分类基于功能类别的合理推断（生成类插件通常只调用外部 API），未逐一读取全部源码。
9. **外部抓取内容混入上下文后是否会被解析为工具调用**：未做实际端到端测试（构造包含 VCP 协议文本的网页内容，验证其被 `UrlFetch`/`FlashDeepSearch`/`BrowserSearch` 等插件抓取混入上下文后是否会被解析器当作工具调用）。`toolApprovalConfig.json` 当前 `enabled: true` 且名单含 `PowerShellExecutor`/`FileOperator` 是当前默认防护，但 `enabled` 可被关闭。
10. **敏感环境变量的日志输出**：未逐一检查各插件的 debug 日志输出是否会打印 `DECRYPTED_AUTH_CODE`、API Key 等值。
11. **ChromeBridge 协议 v3 与托管运行时的运行级验证**：`tests/chromeBridge/` 下有 `smoke-check.js` 及 `c4c4d00`→`1ae9b63c` 新增的 `runtime-core-test.js`、`page-runtime-handle-test.js`、`page-runtime-image-test.js`、`contenteditable-reply-editor-test.js`，但本机未运行真实 Chrome；页面观察、动作验证、进程回收的实机行为需运行验证（静态代码只确认了入口、状态与事件绑定）。
12. **`ReasoningToContent` 展示转换**：只确认了转换在转发副本上进行、不进 VCP 循环；不同上游（Gemini reasoning/Claude thinking/OpenAI reasoning）字段形态的兼容性未逐项运行验证。
