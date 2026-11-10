# VCPToolBox Agent 工具运行时调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：只读源码核对，并结合近期提交与 diff 重新定位关键结论，重点覆盖浏览器协议 v3、RiverMemo、多媒体、分布式取消；未修改被调查仓库
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 是 VCP 生态里唯一真正执行工具、转发分布式调用并托管审批状态机的服务端。核心事实：

1. VCP 文本协议的解析交给一个状态机扫描器，模糊匹配由 `fuzzyToolMatching` 开关控制。默认的严格模式只认精确的请求块标记与始末标记；打开模糊模式后还能容忍半角花括号、短尖括号一类变体，等于给协议加了一档可配置的宽松匹配。
2. 审批系统拦在工具执行之前，属于人工控制环节。审批请求要求 WebSocket 服务已经存在，且当时至少有一个人类或终端连接；等待超时按**拒绝执行**处理，服务端尚未初始化时，判定需要审批的那一刻直接抛错，同样不执行。请求广播给所有已认证的日志客户端，批准或拒绝只需回一条审批响应，任何持有全局密钥的客户端都能对任意请求作答：审批身份既未绑定发起者，也没有“谁有权批准”这道独立校验。
3. 管理员权限声明只负责把验证码送到插件手里：stdio 插件从环境变量读取解密后的验证码，hybridservice 与 direct 插件从调用上下文取用，比对动作都在插件内部完成。调用是否放行由插件自行判断，主服务端在这一层只做传递。四个声明了管理员权限的插件（PowerShell 执行器、Linux 执行器、插件管理器、媒体渲染器）都已确认自己做了比对，这属于插件自律，框架层没有强制。
4. 分布式节点鉴权共用一层全局 `VCP_Key`，在 WebSocket 升级时校验，节点级独立密钥或证书没有出现。连上来的节点可以通过注册消息声明新工具，已存在的同名工具会被跳过、无法覆盖，这挡住了直接冒名；注册一个原本不存在的诱导性名字（如 FileOperator2）来钓鱼，这套检查管不到。
5. 两个 Shell 插件的安全边界差着一个量级。`PowerShellExecutor` 的校验只有关键字黑名单，外加命中关键字时索要验证码；命令拼接完成后直接交给表达式求值，语法层不做检查，变量拼接、编码之类的写法理论上能绕开字符串匹配。Linux 侧执行器叠了八层校验：黑名单正则、AST 基线、沙箱后端（bubblewrap、firejail、docker 三选一）、资源限制和审计日志等。两者在 manifest 里同样声明管理员权限，实际受约束程度并不对等。

6. **推理内容双通道**：流式与非流式处理器共用一套适配，只处理“回注给客户端”的那份副本，把 `reasoning_content` 等推理字段改写成 `<think>` 标签正文，供不认识推理字段的前端显示，改写范围受模型白名单 `ReasoningToContentModel` 约束（默认示例 kimi、claude）。内部的 VCP 循环、OneRing 入库与日记持久化继续读原始正文，两条通道各走各的；适配函数与调用点见 `modules/reasoningContentAdapter.js:128`、`modules/handlers/nonStreamHandler.js:270`。
7. **工具解析的思考块剥离**：`ToolCallParser` 先移除思考块，再进入工具块扫描，覆盖 `<think>`/`<thinking>` 的大小写、空白与属性变体，以及同类标签的嵌套；开始标签没有闭合时保守丢弃其后全部内容，结束标签没有配对时只移除标签本身（`modules/vcpLoop/toolCallParser.js:22-70`）。
8. **工具结果隐私脱敏**：`toolApprovalConfig.json` 的 `privacyProtection.enabled` 开启后，工具结果在回注 AI 前按敏感键名模式、`sk-`/`ghp_` 等高置信 token 模式和环境变量赋值行做掩码（默认关闭，`modules/toolResultPrivacyGuard.js`）。
9. **分布式取消与结果归属绑定**：分布式执行的 pending 项绑定目标 `serverId`，`tool_result` 只接受目标节点返回；节点声明 `capabilities.cancelTool=true` 时，超时会 best-effort 发送一帧 `cancel_tool`，目标节点断线则立即 reject 其全部 pending（`WebSocketServer.js:876-1002`）。
10. **插件热重载精细化**：manifest 变更分“元数据刷新”与“完整重载”两级——direct 常驻插件只合并展示字段、运行时变更提示需重启；static 插件按签名增量刷新并清理失效占位符与 cron；加载插件的流程串行化并增加重载前 manifest 预校验。
11. **浏览器协议 v3 与托管运行时**：ChromeBridge 使用协议 v3，提供 Grounded Markdown 的 Agent 视图、稳定内容 Hash、快照去重、动作验证、默认敏感 DOM 脱敏与运行指标；`modules/browserRuntimeManager.js` 提供扩展 staging 清单的 hash 完整性校验、运行时实例 ID 与上次关闭原因；`UrlFetch` 的 managed Chrome backend 已接线，默认关闭。
12. **插件面**：当前目录 96 个，启用 77 个、禁用 19 个（清单见第 11 节）。代表性插件包括复用托管 Chrome 持久化 Profile 的免 API 搜索、可编程渲染加 Windows 光标主题的 MediaRenderer（光标链会校验角色、热点和帧数再编码，且需要管理员验证码），以及占位符索引与编辑工具。偏外部服务桥与协议实验的一条线则包括并行与 You.com 搜索、经 MCP 发布生成页面、带管理界面的模拟交易沙盒、工具链暂停语义、字幕时间轴配音，以及把记忆区内容搬运成预处理消息的插件。

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

同轮多个工具调用由执行器用 `Promise.all` 并发处理（并发代码在 `toolExecutor.js:370-400` 的第 396-400 行）；单个调用失败时，内部会捕获异常并返回错误结果，其他调用照常继续。

依据：[toolCallParser.js](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[toolExecutor.js](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)、[Plugin.js](../../VCPToolBox/Plugin.js)、[nonStreamHandler.js](../../VCPToolBox/modules/handlers/nonStreamHandler.js)、[streamHandler.js](../../VCPToolBox/modules/handlers/streamHandler.js)。

## 1. VCP 文本协议：精确语法与解析实现

### 1.1 块级标记

解析器的精确标记常量定义 `<<<[TOOL_REQUEST]>>>` 与结束标记 `<<<[END_TOOL_REQUEST]>>>`（`modules/vcpLoop/toolCallParser.js:5-8`）。是否容忍变体由审批配置里的 `fuzzyToolMatching` 开关决定，默认关闭（`modules/toolApprovalManager.js:55-64`）。

- 关闭模糊匹配时：找块起止标记直接调 `content.indexOf(canonicalMarker, cursor)`，逐字符精确比对（`toolMarkerFuzzyMatcher.js:37-46`）。
- 开启模糊匹配时：块标记改用忽略大小写的正则 `<{2,4}\[LABEL\]>{2,4}`，匹配 2-4 个尖括号包裹的请求与结束标记；字段标记放宽到半角与全角括号混用、任意非换行字符组成的“始……末”对，`{始}`、`「始}`、`{始」` 这类混搭都算数（`toolMarkerFuzzyMatcher.js:48-51,82-108`）。这套降级匹配冲着模型输出格式漂移设计，代价是用户输入被误触发的面变大：普通对话里写出的始末对同样可能被解析成字段。

### 1.2 字段扫描（`「始」value「末」`）

字段扫描由逐字符状态机完成，顺序固定：跳过空白与逗号，按 `/^[\w_]+/` 读出 `key`，要求紧跟 `:`，再匹配起始标记，一直扫到对应的结束标记（`toolCallParser.js:198-277`）。关键细节：

- **参数值里的分隔符**：值取起始标记与结束标记之间的任意字符，解析器不做嵌套计数。值内部出现结束标记会被截断在第一次出现处；起始标记在值里没有特殊处理，所以「始」…「始」…「末」…「末」这种嵌套写法无效，第一个结束标记就结束字段。
- **转义机制**：两个定制的转义变体让值里可以放入本会被当成控制符的文本，提取完成后再把转义映射还原成字面量。参数里确实要写始末标记时得用这套变体；模型直接输出裸标记，仍会被当成新字段的起点。
- **同轮多块**：解析流程循环查找下一个工具块，支持同一响应中出现多个请求块，逐个解析并加入调用数组。
- **思考块剥离**：解析前移除思考块，覆盖 `<think>`/`<thinking>` 两种标签及大小写、标签内空白、属性与同类嵌套；**未闭合的开始标签会保守丢弃其后全部内容**（防止潜藏的工具调用被执行），**未配对的结束标签只移除标签本身、不吞掉其后正文**。标签形态须能被正则识别，非标准变体按普通文本处理。
- **code fence**：解析器不识别 Markdown 代码块围栏，模型在围栏里写出的示例性请求块仍会被当作真实调用解析执行。同一协议的客户端 VCPChat 在展示层会保护围栏内容，服务端解析层没有等价保护。这是**已确认**的边界情况。
- **畸形块处理**：找不到匹配的结束标记时，工具块提取返回空值，整体解析直接停止扫描——一个未闭合的畸形块会连带丢弃其后本应能解析的块。
- **流式截断**：解析发生在完整拼接后的本轮内容上，不逐 chunk 解析，因此半截的流式片段不会被误触发；流被提前中断时，未闭合的工具块永远不会被执行，属于预期行为。
- **大小写/空白容忍**：模糊模式下的标记匹配忽略大小写；扫描器跳过任意空白与逗号分隔符，字段间多余空格、换行与逗号缺失都能容忍。这些扫描细节集中在 `modules/vcpLoop/toolCallParser.js:10-15,22-70,81-96,279-301`。

依据：[toolCallParser.js](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[toolMarkerFuzzyMatcher.js](../../VCPToolBox/modules/vcpLoop/toolMarkerFuzzyMatcher.js)、[toolApprovalManager.js:55-64](../../VCPToolBox/modules/toolApprovalManager.js)。

## 2. 工具定义与上下文注入

### 2.1 占位符体系

插件管理器的描述构建逻辑（`Plugin.js:1027-1062`）遍历所有已加载插件，把每个插件的调用说明拼接为文本并存入 Map，键为 `VCP<PluginName>`（如 `VCPFileOperator`）。这些说明通过 `{{VCP<PluginName>}}` 占位符注入 system prompt，替换逻辑见 `modules/messageProcessor.js:783-806`。因此**模型看到的工具描述就是插件作者在 manifest 中写的原始中文自然语言文本**，包括调用格式示例，没有结构化 JSON Schema 或 function-calling 格式的转换层。

### 2.2 `static` 插件的上下文注入与刷新周期

static 类型插件（如 `WeatherReporter`、`ScheduleBriefing`、`UserAuth` 等）通过 `staticPlaceholderValues` 这个 Map 提供占位符值，生命周期见 `Plugin.js:402-438`：

1. 启动时先把占位符设为 "正在加载中" 的占位文本；
2. 立即触发一次后台更新（fire-and-forget，不阻塞启动）；
3. 若 manifest 声明 `refreshIntervalCron`，用 `node-schedule` 按 cron 表达式周期性重新执行插件 stdio 进程并更新值；
4. 插件本轮无输出或超时不算错误，保留旧值（stale-while-revalidate 语义），除非从未成功过一次才置为 "unavailable"。

`{{VCP<PluginName>}}`（工具描述）与 `{{VCPxxx}}`（static 数据占位符）是两套不同的占位符命名空间，前者来自调用说明，后者来自 `systemPromptPlaceholders`，替换逻辑分别在消息处理器的不同代码段（约 748-806 行）处理。

依据：[Plugin.js:791-826,402-438](../../VCPToolBox/Plugin.js)、[messageProcessor.js:616-806](../../VCPToolBox/modules/messageProcessor.js)。

## 3. 调用链细节：并发、失败处理、迭代上限

- **迭代上限**：流式与非流式处理器都把工具调用触发的 LLM 重新推理循环限制为最多 5 轮，两个上限分别由环境变量 `MaxVCPLoopStream` 与 `MaxVCPLoopNonStream` 设定。它约束的是“每轮响应再触发下一轮 LLM 请求”的次数，单轮内的工具调用数量另算：单轮可以解析出任意数量的工具块，全部并发执行。
- **同轮并发语义**：工具执行器用 Promise.all 并发所有工具调用。单次执行的异常被捕获成错误结果，不向上冒泡成 reject，整批流程不会因单个工具失败而中断，各工具结果互相独立回注（`toolExecutor.js:370-400`）。
- **超时**：stdio 插件里同步调用默认 60 秒、异步调用默认 1800 秒（30 分钟），两者都能被 manifest 的通信超时字段覆盖；分布式工具默认同为 60 秒，取值同样来自目标插件 manifest 的该字段（`Plugin.js:292-325,1598`、`WebSocketServer.js:913`）。
- **重试**：**未发现**自动重试机制。工具调用失败后，错误文本直接回注给模型，由模型自己决定是否重新发起调用；这是有意设计，让 AI 依据错误回执自愈。
- **进程终止**：stdio 插件超时后会强杀整个进程树，避免子进程残留：Windows 侧执行 taskkill 的树形强制终止，失败时回退 process.kill；Linux/macOS 侧先用 detached 建立进程组（仅非 Windows），再对进程组发 SIGKILL，进程组不存在时回退到杀单进程。PowerShell 执行器内部另有一份等价的强杀实现。

依据：[streamHandler.js:70](../../VCPToolBox/modules/handlers/streamHandler.js)、[nonStreamHandler.js:303](../../VCPToolBox/modules/handlers/nonStreamHandler.js)、[server.js:1202](../../VCPToolBox/server.js)。

## 4. 参数校验

**未发现**任何形式的 JSON Schema 或类型系统校验。字段扫描逻辑把所有字段值都解析为**字符串**（`toolCallParser.js:198-277`，具体写入在 `:267`），插件收到的 `args` 对象里所有值都是字符串，类型转换（转数字、转布尔）完全由各插件自己在内部做，例如 PowerShell 执行器直接比较执行类型，Linux 执行器自行调用 `parseInt`。

manifest 里没有 `parameters`/`schema` 字段声明参数类型或必需性；`capabilities.invocationCommands[].description` 是纯自然语言文本，模型是否提供了正确参数、参数是否缺失，只能在插件运行时暴露（插件自己 `throw new Error('缺少必需参数...')`）。这意味着：

- **路径参数**：文件操作器判断路径是否落在允许目录内，先把路径解析归一，再做大小写不敏感的前缀比较（`Plugin/FileOperator/FileOperator.js:61-91`）。边界有三处：
  - 未配置 `ALLOWED_DIRECTORIES` 时默认放行所有路径；示例配置的默认值是仓库根目录上两级，代码注释写明未配置即允许所有操作。
  - 只读操作（读文件、取文件信息）对绝对路径有豁免，可绕过允许目录直接读取任意绝对路径文件。
  - **已确认**：插件启用且允许目录设置宽松时，模型能让它读取沙箱目录之外的任意文件；可读范围还取决于运行插件进程的操作系统用户权限。
- **命令参数**：PowerShell 执行器对命令参数只做关键字黑名单的子串匹配，名单分 `FORBIDDEN_COMMANDS` 与 `AUTH_REQUIRED_COMMANDS` 两份，判断用大小写不敏感的子串查找（`PowerShellExecutor.js:150-158`）。这里没有 AST 或语法分析，字符串拼接、别名、编码变体理论上都能绕开匹配，例如 Remove-Item 的别名 ri 不在默认黑名单里。Linux 执行器走另一套：黑名单正则加 AST 语义基线，再叠沙箱后端（第 6 节详述）。
- **URL 参数**：UrlFetch、TavilySearch 等插件的 URL 参数未在本次调查中逐一复核是否对内网地址、重定向做了过滤，列入未验证事项。

依据：[toolCallParser.js:220](../../VCPToolBox/modules/vcpLoop/toolCallParser.js)、[FileOperator.js:61-91](../../VCPToolBox/Plugin/FileOperator/FileOperator.js)、[PowerShellExecutor.js:150-158](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)。

## 5. 审批系统（重点）

### 5.1 `toolApprovalConfig.json` 规则语法

配置结构见 `modules/toolApprovalManager.js:10-19,25-53`：

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

规则语义见审批判定逻辑（`toolApprovalManager.js:144-225`）：

- `enabled=false`：整个审批系统关闭，所有调用直接执行，审批判定直接返回 `requiresApproval:false`。
- `approveAll=true`：忽略 `approvalList`，所有工具调用一律需要审批。
- `approvalList` 每一项是一条规则字符串，规则解析逻辑根据后缀 `::SilentReject` 决定拒绝时是否通知 AI（`notifyAiOnReject`）。
- **匹配语义**：规则与调用参数做精确字符串相等比较，通配符 `*` 不参与匹配。规则分两级：
  - 工具级 `ToolName`，命中该工具的所有调用；
  - 命令级 `ToolName:command文本`，仅当从参数里取出的 `command`/`command1`/`command2`... 与冒号后半部分**完全相等**时命中。
  命中顺序上，命令级规则压过工具级规则；同优先级时，`notifyAiOnReject:false`（静默拒绝）的规则排在前。
- **默认行为（无命中）**：判定返回 `requiresApproval:false`，调用直接执行。`approvalList` 起黑名单式管控作用：名单内的工具才需要审批，名单外一律放行。

以上规则的解析、匹配与优先级比较集中在 `toolApprovalManager.js:117-205`。

### 5.2 状态机与广播

插件管理器处理工具调用时（`Plugin.js:1205-1279`）：

1. 调用审批判定逻辑判断是否需要审批；
2. 若需要，生成请求 ID（时间戳加 Math.random 派生串，取 7 位，**随机性弱于密码学随机数**），创建一个 Promise 并存入待审批表；
3. 通过 WebSocket 服务把审批请求**广播给所有已连接的日志类型客户端**；
4. 定时器按配置的超时分钟数（默认 5 分钟）设置超时，超时后从待审批表删除并 reject，即超时一律按拒绝执行处理。
5. 若 WebSocket 服务未初始化（理论上不会发生，因为它在初始化阶段先于插件加载完成注入），同样从待审批表删除并抛错，按拒绝执行处理（`Plugin.js:1205-1279`）。

### 5.3 审批响应的身份绑定

WebSocket 服务收到 `tool_approval_response` 后直接进入审批处理，消息来自哪个已认证连接都可以（`clientType==='VCPLog'` 不作为条件，通用分支同样不按客户端类型过滤，`WebSocketServer.js:484-494`）。处理时只用 `requestId` 查找待处理项；批准者与审批上下文是否匹配、发送者有没有独立的“审批权限”角色，这两项检查都没有做（`Plugin.js:1786-1826`）。

WebSocket 鉴权只有一份全局共享的 `VCP_Key`（第 9 节详述），所以批复权实际跟着 Key 走：任何持有该 Key 的客户端都能在收到广播的 `requestId` 后发一条 `tool_approval_response`，批准或拒绝任意一个审批请求，包括只做日志展示的 `VCPLog` 只读消费者、Chrome 控制与管理面板客户端。请求标识随同一广播发给所有日志客户端，连上该通道就能看到并回发。这是**已确认**的机制：持 Key 且已连接的客户端都可以对广播请求作答。

### 5.4 静默拒绝与用户备注

`notifyAiOnReject=false` 的规则被拒绝时，审批结果会标记为静默拒绝；工具处理流程检测到该标记后返回空值（`Plugin.js:1254-1274`），意味着这次调用对 AI 完全不可见，只有人工审批者留下的 reason 备注会被记录到日志。这是一个隐蔽性设计，用于防止 AI 反复尝试同一被拒绝的敏感操作。

### 5.5 关机清理与结果隐私脱敏

- **关机清理**：关机流程先清除插件文件 watcher，再对待审批表中所有项执行 reject，避免这些 Promise 悬挂到重启。
- **结果隐私脱敏**：开关是 `privacyProtection.enabled`（默认关闭），打开后工具的成功与错误结果在回注 AI 前统一过一遍脱敏，实现于 `modules/toolResultPrivacyGuard.js`；调用点与关机清理的实现见 `Plugin.js:113-123,671-706,1433,1459`。掩码按三类模式进行：

| 模式 | 匹配对象 | 处理 |
|---|---|---|
| 敏感键名 | api_key、token、password、credential 等 | 掩掉键值 |
| 高置信 token | sk-、sk-proj-、xoxb、ghp_、AKIA 等前缀 | 掩掉 token 中段 |
| 环境变量赋值 | KEY=value 形式的行 | 掩掉取值 |

以 data: 开头的 base64 URI 整体保留；掩码保留前后各 4 个字符，短于 8 个字符的值不掩码。

依据：[toolApprovalManager.js:10-225](../../VCPToolBox/modules/toolApprovalManager.js)、[Plugin.js:113-123,671-706,1205-1230,1786-1826](../../VCPToolBox/Plugin.js)、[WebSocketServer.js:484-494](../../VCPToolBox/WebSocketServer.js)、[toolResultPrivacyGuard.js](../../VCPToolBox/modules/toolResultPrivacyGuard.js)。

## 6. 插件模型：manifest 字段、类型与执行协议

### 6.1 manifest 加载与生命周期

插件加载从扫描 `Plugin/` 下各子目录的 manifest 开始。`name`、`pluginType`、`entryPoint` 三个字段缺任何一个，manifest 会被静默跳过；消息预处理器另起一轮发现，两轮发现与字段判断集中在 `Plugin.js:796,885-893,1043`。

禁用插件靠改名：把目录内的 manifest 改成 `plugin-manifest.json.block` 即可，禁用清单由 `Plugin.js:1115` 的 `_discoverDisabledPluginManifests` 汇总（当前 HEAD 有 19 个插件处于此状态，见第 11 节插件清单）。

插件生命周期变化见 `Plugin.js`：

- **重载串行化**：加载流程以 `pluginLoadPromise` 串行执行，重载期间再次到来的请求并入同一次执行，并发重载互相破坏插件表的情况因此不会出现。
- **重载前预校验**：加载前先并行解析全部启用清单，任一 manifest 解析失败即抛错中止本轮，编辑中的半截 JSON 不会把正常运行的注册表破坏为部分加载状态。
- **两级热更新**：变更清单先算出运行时签名再比较：仅展示字段变化时刷新元数据，不重启任何模块，direct 常驻插件的运行字段保持内存版本；运行字段变化时 direct 插件提示需重启、其余插件走完整重载。
- **static 插件增量刷新**：static 插件按入口、通信、定时、配置结构与占位符声明五类信息算出一份签名，再据此判断是否需要刷新。新增、删除、禁用插件或定时变更会精确取消失效 job、清理已删除占位符，分布式占位符仍由节点标识的生命周期管理。
- **watcher 启动时机与范围**：文件 watcher 在初始化末尾显式启动，启动阶段的文件写入不会触发多余重载；监听范围限定在单个插件目录一层，且只接受 manifest 文件（含禁用态的改名文件）的变更，插件运行期数据目录（如托管浏览器 Profile）不进入监听。关机流程会关闭 watcher 并结算全部待审批项。这几项生命周期实现在 `Plugin.js:521,726,796-835,2556-2600`，watcher 启动点在 `server.js:1518`。

### 6.2 六种插件类型的生命周期差异

| 类型 | 触发方式 | 进程模型 | 结果返回 |
|---|---|---|---|
| `static` | cron 定时 + 启动时立即触发一次 | 每次执行都是独立 stdio 子进程 | stdout 整体作为占位符值，失败保留旧值 |
| `synchronous` | AI 发起 VCP 调用 | 每次调用 spawn 一个新 stdio 子进程 | 等待进程退出，解析 stdout 中的 JSON |
| `asynchronous` | AI 发起 VCP 调用 | spawn 子进程，等待"首个 JSON 响应"后立即 resolve，子进程可继续在后台运行 | 首次 JSON 走同步返回；后续结果通过 `POST /plugin-callback/:pluginName/:taskId` 回调主服务器，写入 `VCPAsyncResults/` 目录文件，再由 `{{VCP_ASYNC_RESULT::Plugin::id}}` 占位符异步读取展示 |
| `service` | 服务器启动时 `initializeServices()` 一次性加载 | 进程内模块，常驻内存，可挂载 Express 路由（`hasApiRoutes`） | 不通过 `processToolCall` 触发工具调用（无 `invocationCommands` 语义） |
| `messagePreprocessor` | 每次对话请求前 | 进程内模块方法调用（`protocol:'direct'`），无独立子进程 | 直接修改 `messages` 数组 |
| `hybridservice` | 既是常驻服务又可被 AI 直接调用 | 进程内模块，`processToolCall` 方法被直接调用（无子进程开销） | 直接返回 JS 对象 |

`isDistributed` 是一个独立于 `pluginType` 的标记，任何类型的插件都可能来自远程节点注册；这类插件的执行走 `WebSocketServer.executeDistributedTool()`，本地 spawn 与 direct 调用都不经过。

### 6.3 执行协议实现差异

- **stdio 插件**：执行入口用 spawn 拉起子进程，创建、调用与超时计算都在同一段流程里。这里带着 `shell: true`，入口命令会先交给系统 shell 解析。当前该字符串固定来自 manifest 静态配置，运行期参数拼不进去，风险有限；一旦后续有代码路径把用户输入拼到入口命令，就会直接构成 shell 注入，本次**未发现**这种拼接。非 Windows 平台 spawn 带 detached 建立进程组，配合进程树强杀逻辑（见第 7 节）。stdio 执行与 direct 加载的实现在 `Plugin.js:856-871,1472-1598`。
- **direct 插件**：manifest 声明入口脚本，加载流程用动态 require 加载该模块到进程内，模块需暴露初始化、处理工具调用与关闭等约定方法。direct 协议插件与主服务进程**同权限、同内存空间**运行，进程隔离对它不适用。
- **distributed 插件**：不在本地 spawn 任何进程，转发到远程节点的 WebSocket 连接（详见第 8 节）。

### 6.4 Node/Python/native 入口

Node 插件在 manifest 中以 `entryPoint.type: nodejs` 声明入口类型，并用 `command: "node xxx.js"` 指定启动命令。主服务随后按协议类型把该命令拆成可执行文件与参数后 spawn 子进程（`Plugin.js:1577`）。

Python 插件在 manifest 中通过入口类型声明语言，执行方式与 Node 插件一致、同样由主服务 spawn 子进程，差别在于多一步预热：服务器启动阶段调用 `prewarmPythonPlugins()`（`Plugin.js:583` 起），为 `SciCalculator` spawn 一个 python 子进程预先导入 sympy、scipy、numpy 等科学计算库，避免首次调用时的导入耗时。

`rust-vexus-lite` 是原生模块特例，加载完全绕开 manifest 的入口声明：它在镜像构建阶段被编译为 `.node`（N-API addon），运行时由主进程直接 `require`，供记忆与向量检索相关模块使用。

另有两类 Rust 二进制插件不把原生二进制直接作为 manifest 入口，而以 Node 包装器为入口，由包装器负责拉起原生进程：

- **`CodeSearcher`**：入口是 `node CodeSearcher.js`，包装器按操作系统与架构（win32/linux/darwin 与 x64/arm64）组合在候选路径中定位原生二进制再 spawn（`Plugin/CodeSearcher/CodeSearcher.js:10-61`）。
- **`DailyNoteSearcher`**：`hybridservice` 常驻模式，JS 桥在进程内启动并管理 Rust HTTP 服务，同样按操作系统与架构选择二进制，并以 instance-id 与关闭令牌做健康检查与优雅退出（`Plugin/DailyNoteSearcher/DailyNoteSearcher.js:42-87,290-345`）。

主服务 spawn 子进程插件时，除插件自身的 `config.env` 外，还会按三类条件追加环境变量，合并逻辑见 `Plugin.js:1494-1566`：

| 类别 | 追加的环境变量 |
|---|---|
| 运行上下文 | `PROJECT_BASE_PATH`、`VCP_REQUEST_IP`、`SERVER_PORT`、`PYTHONIOENCODING=utf-8` |
| 管理员校验（`requiresAdmin`） | `DECRYPTED_AUTH_CODE` |
| 异步回调（`asynchronous`） | `CALLBACK_BASE_URL`、`PLUGIN_NAME_FOR_CALLBACK` |

### 6.5 `requiresAdmin` 的实际生效点

**已确认**：主框架对管理员权限声明只做传递，不做拦截。它把解密后的验证码放进 stdio 插件的环境变量（`Plugin.js:1657`），也放进常驻插件的调用上下文，然后由插件自己决定是否比对。已复核的四个声明需要管理员权限的插件（PowerShell 执行器、Linux 执行器、插件管理器、媒体渲染器）都在自己代码里校验了六位验证码，媒体渲染器甚至在启动子进程前强制比对；但这是这些插件各自实现的结果，不是框架给出的保证。装上第三方或自写插件却忘记比对时，这个声明不构成任何约束。

依据：[Plugin.js:1657](../../VCPToolBox/Plugin.js)、[PowerShellExecutor.js](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)、[PluginManager.js:35-50](../../VCPToolBox/Plugin/PluginManager/PluginManager.js)、[MediaRenderer.js:452-458](../../VCPToolBox/Plugin/MediaRenderer/MediaRenderer.js)。

### 6.6 工具结果批量协议、生命周期事件与执行桥

一轮内多个工具的返回结果不再各自独立成段，而是由 `modules/toolResultBatch.js` 统一包裹成一个带时间戳的批量块，开始与结束标记共用同一时刻，因此相邻两批可以区分。角色重排器在拆分角色块之前先按批量边界扫描，避免把同一批结果切断到不同角色段；流式与非流式处理器在返回上游前还会做一次投影，把标记改写成模型可读的说明文字。

工具执行过程本身会产生生命周期事件：`modules/toolLifecycleVcpInfo.js` 为每次调用构造上下文，并按开始、成功、失败、超时四个阶段广播 `TOOL_LIFECYCLE` 事件（创建与四处发射见 `Plugin.js:1458-1591`），超时阶段由上下文实际耗时改写。前端与分布式订阅者因此能观察到工具正在运行还是已失败，而不只看到最终文本。

工具执行路径还可替换：`modules/pluginBridgeRegistry.js` 提供两个按优先级排序的注册表，分别用于依赖解析与执行接管，默认注册表由 `createDefaultDependencyBridgeRegistry` 构造，RAG 时间线并行等场景可注册自己的桥。

### 6.7 JEV 虚拟调用与第三方声明消费

JEV 是工具执行器识别的虚拟工具名。模型仍输出普通 VCP 工具块，参数中的表达式交给规划器，按配置目录、工具选择和参数规则展开成一个或多个真实插件调用，再递归进入同一执行链。它没有独立插件进程；展开结果会沿用调用上下文和审批约束（`modules/vcpLoop/toolExecutor.js:198-231`；`modules/jevToolCallExp.js:278-343`）。

第三方插件的 manifest `jev` 段会被注册表校验，合格声明供规划器选命令并构造参数；存在歧义时可请求外部决策模型，未配置或失败时按声明的默认值回退，无法确定则返回规划错误。声明错误只影响 JEV 注册，不阻止普通插件加载。因此“纯提示词素材”只描述声明本身没有执行代码，而这些按声明展开的工具字段在运行时由规划器消费（`modules/jevThirdPartyRegistry.js:3-26`；`modules/jevToolCallExp.js:991-1055`）。

展开调用继承发起者、工具口令和调用级投递元数据。真实插件进入 `processToolCall` 后逐个执行审批判定，审批超时仍拒绝；一次虚拟调用展开多项时由执行器汇总成功或部分失败结果（`modules/jevToolCallExp.js:957-979`；`Plugin.js:1346-1393`）。外部决策模型的实际选择效果未运行验证。

仓库侧校验与示例规范化另由两个脚本承担：`validate-plugin-json.js` 只做 JSON 语法校验；`normalize-plugin-examples.js` 规范化示例并备份。两者与运行时 JEV 注册和规划路径分离。

### 6.8 VCPSleep 的等待与取消边界

VCPSleep 是同步 stdio 插件，子进程用定时器等待后返回醒来时间和 tips，单次时长大于零且至多 12 小时；manifest 超时为 43,500,000 毫秒，给最长等待留出五分钟余量。它占住当前工具等待链，不会创建持久化调度任务（`Plugin/VCPSleep/VCPSleep.js:101-169`；`Plugin/VCPSleep/plugin-manifest.json:8-16`）。

已读执行链没有把请求的 AbortSignal 传给同步 stdio 子进程：客户端中止能结束响应和阻止后续回灌，睡眠进程仍依赖自身定时器或插件超时结束。通用超时会强杀进程树；direct 插件超时走独立的 AbortController，VCPSleep 的结束由自身定时器或插件超时决定（`Plugin.js:1190-1215,1728-1766`；`modules/vcpLoop/toolExecutor.js:431-434`）。可选做梦联动与睡眠计时并行，且要求启用 AgentDream；做梦失败不延长睡眠（`Plugin.js:1235-1283`）。

## 7. 执行位置与隔离

- **stdio 插件**：独立子进程，和主 Node 进程同机、同一操作系统用户权限。spawn 调用没有降权参数，Windows 平台上也没有等价机制，OS 级沙箱、chroot、容器隔离与降权一概没有。它能访问的文件范围只由插件自身逻辑约束（如文件操作器的允许目录），操作系统不提供强制边界。
- **direct/hybridservice 插件**：与主服务进程同一内存空间、同一权限，属于主进程的一部分，进程隔离对它不适用。
- **例外——`LinuxShellExecutor`**：这是唯一实现了实际沙箱后端的插件，config.env 里有两组开关，隔离由插件自带，框架层不统一提供（`LinuxShellExecutor/config.env:15-30`）：

| 开关 | 取值 | 作用 |
|---|---|---|
| 沙箱后端 | none（默认）、bubblewrap、firejail、docker | 选择隔离实现，none 表示不隔离 |
| 资源限制 | CPU、文件大小、进程数、文件描述符、虚拟内存 | 约束单次命令的资源用量 |

- **Docker 部署**：Dockerfile 与 compose 把整个 VCPToolBox（含所有插件）当成**单一容器**跑。compose 将整个仓库目录 bind-mount 进容器；Dockerfile 里的降权用户那行被注释掉（`Dockerfile:187`），容器内进程默认以 root 运行。边界只到容器这一层，容器内插件之间没有进一步隔离。Linux 执行器若在容器内把沙箱后端设为 docker，会牵出 docker-in-docker 或挂载 docker socket 的额外风险；该配置在容器化部署下是否真的可用，本次**未验证**。
- **超时与僵尸进程**：超时后的强杀由进程树终止函数与 PowerShell 执行器内部的等价实现负责，避免子进程残留为僵尸/孤儿进程。平台差异如下：
  - Windows：执行 `taskkill /F /T /PID` 做树形强制终止，失败时回退到单进程 kill；
  - Linux/macOS：对进程组发 SIGKILL，进程组不存在时回退到杀单进程。
  通用执行路径在非 Windows 平台以 detached spawn 建立进程组，进程树终止函数因此有 Unix 进程组等价物；Linux 执行器对自己管理的命令另有一套进程生命周期管理（`Plugin.js:325,405,1753-1758`）。

依据：[Plugin.js:325,1753](../../VCPToolBox/Plugin.js)、[PowerShellExecutor.js:47-58](../../VCPToolBox/Plugin/PowerShellExecutor/PowerShellExecutor.js)、[LinuxShellExecutor/config.env](../../VCPToolBox/Plugin/LinuxShellExecutor/config.env)、[Dockerfile:187,191](../../VCPToolBox/Dockerfile)、[docker-compose.yml](../../VCPToolBox/docker-compose.yml)。

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

WebSocket 升级时校验 URL 路径里的 `VCP_Key` 是否等于服务器配置的**全局唯一** `vcpKey`（`WebSocketServer.js:230-236`）。鉴权只有这一层：节点级独立密钥、证书与双向 TLS 都没有，日志、分布式、Chrome 控制与管理面板等全部连接类型共用同一个 Key。持有 Key 的一方可以注册分布式工具、对审批请求批准或拒绝，也可以作为管理面板客户端连接。这是**已确认**的机制：各通道共享同一份鉴权凭据，没有按通道区分的独立密钥。

### 8.3 节点声明工具的可信度

分布式工具注册流程（`Plugin.js:1888` 起）对新工具做的唯一检查是名称是否已存在于插件表；若已存在则跳过（不覆盖），否则接受并标记为分布式工具，记录 serverId，并在 displayName 前加 `[云端]`。**已确认**：分布式节点**不能覆盖已存在的本地或其他节点的工具名**，但**可以自由注册任意新名字的工具**，包括故意构造与知名本地插件高度相似的名字（如 `FileOperatorPro`、`FileOperator_v2`）来诱导模型误选。manifest 内容（包括调用说明文本、是否 `requiresAdmin`）完全由远程节点自行提供，主服务器不做任何 schema 或内容审查就直接采纳并注入到 system prompt 描述中。

### 8.4 转发调用的审批是否仍然生效

**已确认生效**：工具处理流程中的审批判定发生在“是否为分布式插件”的分支**之前**（`Plugin.js:1205`），因此只要 `toolApprovalConfig.json` 中把该工具名列入 `approvalList`，分布式转发调用同样会先触发人工审批流程，审批通过后才会转发执行。

### 8.5 取消传播与结果归属绑定

`WebSocketServer.js` 有三项分布式加固：

- **结果归属绑定**：待处理请求条目携带目标 `serverId`，收到结果时若消息来源节点不是目标节点，则记录警告并**忽略**该消息、不完成对应 Promise（`WebSocketServer.js:508-971`）。这堵上了任何节点用同一请求标识完成或伪造结果的缺口；分布式回调转发的来源节点绑定仍未加（见第 10 节）。
- **取消传播**：节点注册工具时可声明支持取消；转发超时时，若目标连接仍开放且节点声明了该能力，则 best-effort 发送一帧取消消息。未声明能力的旧节点收不到这一帧，节点侧自己的本地超时与中止信号仍独立生效，架构文档把两者都列为必要边界。
- **断线清理**：节点断开时立即 reject 该节点全部待处理请求，请求不会悬挂到超时；发送消息失败同样立即 reject。对应测试覆盖在分布式取消用例中（`tests/distributedToolCancellation.test.js`）。

依据：[WebSocketServer.js:191-236,508-511,851-985](../../VCPToolBox/WebSocketServer.js)、[Plugin.js:1205,1669-1694](../../VCPToolBox/Plugin.js)、[docs/DISTRIBUTED_ARCHITECTURE.md](../../VCPToolBox/docs/DISTRIBUTED_ARCHITECTURE.md)。

## 9. HTTP 接口与鉴权

`/v1/*` 的鉴权由全局中间件统一把关：除 `/admin_api`、`/AdminPanel`、图片/文件服务路径与 `/plugin-callback` 外，其余路径一律要求 Bearer token（`server.js:853-877`）。各路径的具体口径如下：

| 路径 | 鉴权方式 | 说明 |
|---|---|---|
| `/v1/chat/completions`、`/v1/chatvcp/completions`、`/v1/models`、`/v1/schedule_task`、`/v1/interrupt` | `Authorization: Bearer <serverKey>`（`serverKey=process.env.Key`，`server.js:654,876`） | 走上述全局 Bearer 中间件 |
| `/v1/human/tool` | `Authorization: Bearer <serverKey>` | 该路由定义在 Bearer 中间件**之后**（第 1249-1250 行 > 第 853 行），**已确认需要 Bearer 鉴权** |
| `/admin_api/*`、`/AdminPanel/*` | HTTP Basic Auth（`basic-auth` 库）或 Cookie 里的 `admin_auth`（`server.js:658-747`），凭据来自 `AdminUsername`/`AdminPassword` 环境变量；未配置这两个变量时管理面板整体 503 禁用 | 有登录失败次数限制与临时 IP 封禁（`tempBlocks`），少数只读监控端点（`/admin_api/system-monitor` 等）豁免封禁计数但仍需通过 Basic Auth |
| `/pw=<key>/images/*`、`/pw=<key>/files/*` | URL 路径内嵌的 key（由 `ImageServer` 插件生成/校验，未在本次调查中逐行复核该 key 比对逻辑的强度） | 豁免全局 Bearer 中间件（`server.js:859-868`） |
| `/plugin-callback/:pluginName/:taskId` | **无鉴权**（`server.js:870-872` 显式豁免 Bearer 检查） | 见第 10 节"回调伪造"分析 |
| WebSocket `/VCPlog/VCP_Key=`、`/vcpinfo/VCP_Key=`、`/vcp-distributed-server/VCP_Key=`、`/vcp-chrome-control/VCP_Key=`、`/vcp-chrome-observer/VCP_Key=`、`/vcp-admin-panel/VCP_Key=` | 全局共享 `VCP_Key`（第 8.2 节） | 所有通道共用同一个 Key，无按通道区分的细粒度权限 |

- **CORS**：`app.use(cors({origin:'*'}))`（`server.js:556`），对所有来源开放跨域——若浏览器端脚本获得受害者浏览器执行环境（如 XSS）且知道 Bearer token，可跨域调用任意 `/v1/*` 接口；即使不知道 token，`/plugin-callback/*` 无鉴权路径也可被任意来源的网页直接 POST。
- **默认监听地址**：`app.listen(port, ...)` 未指定 host 参数（`server.js:1685`），Node.js 此时默认监听所有网络接口（`0.0.0.0` 与 `::`），意味着容器化部署下端口映射出去即对公网可达，未观察到把默认绑定收紧到 127.0.0.1 的配置。这是**已确认**的默认监听行为，实际可达性取决于反向代理/防火墙/端口映射策略。

依据：[server.js:556,658-747,853-877,1249-1300,1460-1504,1685](../../VCPToolBox/server.js)。

## 10. 结果处理与回注

- **结果格式**：回注内容统一包成 `{type:'text', text}` 块。格式化入口先看结果里有没有富内容数组（两种字段形态都认），有则按块取用，没有则把整个对象 JSON 序列化后转成字符串（`toolExecutor.js:448-473`）。长度不设上限：执行器层**未发现**截断逻辑，工具返回多长就原样拼回对话上下文，单次输出理论上能把上下文窗口占满，是否截断由各插件自己决定。回注前还有一道可选的隐私脱敏（见 5.5）。
- **推理内容不进入工具循环**：工具循环累计的只有正文，推理字段另走日志。流式与非流式入口的处理一致：
  - 日志字段：`reasoning_content` 等推理字段写进消息的推理槽位，正文累计变量始终只累计正文；
  - 写入位置：流式入口在增量追加处、非流式入口在可见内容提取处分别落实（`streamHandler.js:158-218`、`nonStreamHandler.js:272-276`）；
  - 客户端展示：展示转换开关打开后，转换在独立副本上进行，结果只进发给客户端的 SSE，不进 VCP 循环、OneRing 入库或日记。
- **错误形态**：同步执行错误统一包装成字符串化 JSON 抛出，上层 catch 后再尝试解析还原结构化错误对象；解析失败则退化为一条通用错误文本。
- **异步回调接收**：异步插件用回调路由回传结果，这条路径显式豁免 Bearer 检查。服务器先写结果文件，再检查插件是否存在：写失败仍会继续广播，插件缺失则返回 404。该入口没有签名、来源或任务归属验证。
- **回调结果消费**：任务 ID 由插件自行生成，获知插件名和任务 ID 的调用方可以覆盖对应的 JSON 结果文件；下一次请求中的异步结果占位符会读取该文件并拼入文本。插件声明启用推送时，同一份回调正文还会广播给指定客户端类型。
- **路径防护范围**：路径安全辅助模块已接入若干管理路由，回调路由直接把参数和结果文件名拼进路径，其他路由的路径校验没有覆盖到这个端点。
- **分布式插件回调转发**：分布式回调转发走 WebSocket 的转发消息类型，同样只检查插件名与任务 ID 字段是否存在，来源节点与任务归属都不做绑定校验——任何已连接的分布式节点只要获知目标任务 ID，就能为**不属于自己**的任务发送这条转发消息（`WebSocketServer.js:95-144`）。

依据：[server.js:870-1402,1460-1504](../../VCPToolBox/server.js)、[messageProcessor.js:828-867](../../VCPToolBox/modules/messageProcessor.js)。

## 11. 插件清单

以下为**当前 HEAD（`Plugin/` 目录，96 个子目录）实际存在的 manifest** 逐一读取的结果。启用判定标准：目录下存在 `plugin-manifest.json`；禁用态是把同一文件改名为 `plugin-manifest.json.block`。共 77 个启用、19 个禁用，无第三种状态。这与 `docs/PLUGIN_ECOSYSTEM.md` 声称的“总计 79 活跃插件”**不一致**：文档统计把仓库内所有插件目录（含禁用态）都算作“活跃”，与本 checkout 的 77 启用、19 禁用、合计 96 对不上，说明文档的插件统计是历史快照，**不能作为当前启用状态的依据**，以下表格为准。清单里三处版本与入口值得单独记一笔：

- `ChromeBridge` 为 2.4.0：Grounded Markdown 增加正文图片/视频画面语义标注与 `get_page_image` 命令、Popup 人工 Managed 选择，agent 不再隐式控制托管运行时；
- `CodeSearcher` 入口为 `node CodeSearcher.js`：Node 包装器按平台选原生二进制；
- `UrlFetch` 为 0.3.0：PDF 文本解析与 50MB 上限，本地 `file://` 亦支持 .pdf。

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
| DeedPage | DeedPage | synchronous | stdio | 启用 | 否 |
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
| MemoryThinkingTray | MemoryThinkingTray | messagePreprocessor | direct | 启用 | 否 |
| MimoDubbing | MimoDubbing | asynchronous | stdio | 启用 | 否 |
| NCBIDatasets | NCBIDatasets | synchronous | stdio | 禁用 | 否 |
| NanoBananaGen2 | NanoBananaGen2 | synchronous | stdio | 启用 | 否 |
| OneRing | OneRing | messagePreprocessor | direct | 启用 | 否 |
| OpenHerPersona | OpenHerPersona | hybridservice | direct | 启用 | 否 |
| PaperReader | PaperReader | synchronous | stdio | 禁用 | 否 |
| ParallelSearch | ParallelSearch | synchronous | stdio | 启用 | 否 |
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
| VCPSleep | VCPSleep | synchronous | stdio | 启用 | 否 |
| VCPTaskAssistant | VCPTaskAssistant | hybridservice | direct | 启用 | 否 |
| VCPTavern | VCPTavern | hybridservice | direct | 启用 | 否 |
| VCPTimeLine | VCPTimeLine | hybridservice | direct | 启用 | 否 |
| VCPToolBridge | VCPToolBridge | hybridservice | direct | 启用 | 否 |
| VTrade | VTrade | hybridservice | direct | 启用 | 否 |
| VSearch | VSearch | synchronous | stdio | 启用 | 否 |
| VideoGenerator | Wan2.1VideoGen | asynchronous | stdio | 启用 | 否 |
| WeatherInfoNow | WeatherInfoNow | static | stdio | 启用 | 否 |
| WeatherReporter | WeatherReporter | static | stdio | 启用 | 否 |
| YouSearch | YouSearch | synchronous | stdio | 启用 | 否 |
| ZImageGen2 | ZImageGen2 | synchronous | stdio | 禁用 | 否 |
| ZImageTurboGen | ZImageTurboGen | synchronous | stdio | 启用 | 否 |

依据：以上表格数据来自对 `Plugin/*/plugin-manifest.json`（或 `.block`）的逐一读取；[docs/PLUGIN_ECOSYSTEM.md:50-60](../../VCPToolBox/docs/PLUGIN_ECOSYSTEM.md)（文档声称的插件统计，与实测不一致处已在上文指出）。

## 12. 子 Agent 与任务委派

`AgentAssistant` 插件（`hybridservice`/`direct`）承担 Agent 间通讯与任务委派：

- **即时通讯与定时联络**：一次联络用 `agent_name` 加提示词发起，对象是某个配置好的 Agent；`timely_contact` 把同一次调用推迟到未来时间点，复用通用定时机制，先把任务写入定时联络目录，再由调度器到点执行。系统按响应里的模型字段判断是否启用展示转换，启用时连带剥离从主总线转换到正文的思考标签块（含未闭合块），避免推理标签污染会话历史（`AgentAssistant.js:181-1128`）。
- **异步委托**：委托开关打开后，AgentAssistant 内部维护委派状态；`delegationMaxRounds`（默认 15 轮，来自 config.json）是自主循环的轮数上限，单轮超时另有配置项限制。循环驱动被委托 Agent 反复推理，直到它自行判定完成或触到上限；达到上限时不报错，改为生成一条“达到最大轮数限制，任务尚未自动上报完成”的报告。
- **临时工具注入**：发起方可以为单次委托把额外工具的说明文本临时拼到被委托 Agent 的 system 提示词尾部（`inject_tools`）。manifest 明确声明这不影响 Agent 的长期固定系统提示词，但发起方（可能是另一个 AI）能在运行时临时扩大某个 Agent 会话内可见的工具面：任何能调用 AgentAssistant 的角色，都可以给任意配置好的下游 Agent 塞进任意已加载的工具描述，唯一约束是该工具本身是否需要审批或管理员校验。
- **ScheduleManager、TimedTaskQuery、ScheduleBriefing** 等插件另行提供独立于 AgentAssistant 的定时任务能力，本次调查未逐一深入其后台调度实现（列入未验证事项）。

依据：[AgentAssistant.js:181,647-711,1016-1128](../../VCPToolBox/Plugin/AgentAssistant/AgentAssistant.js)、[AgentAssistant/plugin-manifest.json:6,28](../../VCPToolBox/Plugin/AgentAssistant/plugin-manifest.json)、[toolExecutor.js:491-543](../../VCPToolBox/modules/vcpLoop/toolExecutor.js)。

## 13. 未验证事项与后续调查缺口

| # | 事项 | 本次未覆盖的部分 |
|---|---|---|
| 1 | PowerShell 执行器的命令校验强度 | 校验是对关键字黑名单的子串匹配，变量拼接、表达式求值间接调用与别名对校验结果的影响未逐一验证 |
| 2 | 与 aio-hub 解析器的兼容性 | 本次范围内未深入验证 |
| 3 | 网络类插件的地址校验 | UrlFetch、TavilySearch、AnySearch、VCPEverything、BrowserSearch 对内网地址、重定向与协议类型是否过滤，未逐一验证；BrowserSearch 声明网页内容为不可信数据并做区域重定向观测，其 URL 过滤细节未逐行复核 |
| 4 | Linux 执行器的分层校验 | 代码近 3000 行，本次仅确认存在分层校验与可选沙箱后端，未逐层验证每层对异常输入的完整处理 |
| 5 | 容器化部署下 `SANDBOX_BACKEND=docker` 的可用性 | 是否需要挂载 docker socket、在容器内能否真正可用，未在容器化环境实测 |
| 6 | `ImageServer`（ImageFileServer 插件）图片与文件路径的 key 校验 | 未逐行复核该 key 的生成与比对 |
| 7 | 定时任务插件的后台调度实现 | ScheduleManager、TimedTaskQuery、ScheduleBriefing 的持久化与到点执行路径未深入，只确认通用定时机制；VCPTaskAssistant 的调度链在独特功能笔记中单独确认 |
| 8 | 重点复核插件之外的其余插件 | 未逐一审查各插件内部的参数校验、路径处理与命令拼接，其余插件的分类基于功能类别的合理推断（生成类通常只调用外部 API），未读取全部源码 |
| 9 | 外部抓取内容混入上下文后是否被当作工具调用 | 未做端到端测试：构造含 VCP 协议文本的网页内容，经 UrlFetch、FlashDeepSearch、BrowserSearch 等抓取插件混入上下文后观察解析器行为。当前默认防护是 `toolApprovalConfig.json` 中审批开启且名单含 PowerShell 执行器与文件操作器，该开关本身可关闭 |
| 10 | 敏感环境变量的日志输出 | 未逐一检查各插件 debug 日志是否打印解密验证码与 API Key 等值 |
| 11 | `ChromeBridge` 协议 v3 与托管运行时的运行级验证 | tests/chromeBridge 目录下已有冒烟与运行时用例；本机未运行真实 Chrome，页面观察、动作验证与进程回收的实机行为需运行验证，静态代码只确认了入口、状态与事件绑定 |
| 12 | `ReasoningToContent` 展示转换 | 只确认转换在转发副本上进行、不进 VCP 循环；Gemini reasoning、Claude thinking、OpenAI reasoning 三类上游字段形态的兼容性未逐项运行验证 |
