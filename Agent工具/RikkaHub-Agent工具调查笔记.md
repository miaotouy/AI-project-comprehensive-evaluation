# RikkaHub Agent 工具调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：只读源码梳理。按 `ai/src/main/java/me/rerere/ai/agent/`、`app/src/main/java/me/rerere/rikkahub/data/ai/`、`workspace/src/main/java/me/rerere/workspace/` 三层逐入口复查；关键结论以当前快照可执行路径为准，未运行构建或测试。
>
> 调查范围：工具来源与注册顺序、schema 与 systemPrompt 注入、模型协议适配、调用解析、审批状态机、执行与结果回注、Step 循环、输出截断、错误处理、MCP 客户端发现与命名、Workspace/Skill/记忆工具的执行边界。不覆盖 UI 渲染细节、会话持久化 schema 与检索模块内部实现。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的工具体系由 `ai` 模块定义协议、`app` 模块组装具体工具、`workspace` 模块提供沙箱执行环境。关键特征有四点。

第一，工具协议是一个极简的自定义数据类，不绑定任何 SDK。每个工具由名称、描述、参数 schema 提供器、systemPrompt 生成器、审批判定器和挂起执行器组成（`ai/src/main/java/me/rerere/ai/core/Tool.kt`）。参数 schema 只有 `InputSchema.Obj` 一种对象形态，不表达数组、枚举等嵌套的完整 JSON Schema 能力，具体细节由各工具在构造时用 `buildJsonObject` 手工拼出。

第二，工具结果就地写入触发它的助手消息的 parts，会话中不额外生成 TOOL 角色消息。循环每轮把执行完的工具 part 回写到末尾助手消息，再发起下一轮模型调用；循环本体位于 `ai` 模块的 AgentLoop，与 UI、通知、持久化保持解耦，预处理、预览与收尾统一由 AgentHooks 注入（`ai/src/main/java/me/rerere/ai/agent/AgentLoop.kt`、`app/src/main/java/me/rerere/rikkahub/data/ai/ChatRequestFactory.kt`）。协议序列化时才按工具边界重新分组，把工具调用拆成 `assistant.tool_calls`，工具结果紧随其后写进 role 为 tool 的消息（`ai/src/main/java/me/rerere/ai/provider/providers/openai/ChatCompletionsAPI.kt`）。

第三，审批是编排层状态机，执行端不做鉴权。工具执行前先看它是否要求审批，要求审批时把该工具的状态由自动改成待审批并中断本轮，等用户动作后再从待审批继续；用户拒绝或填写答案这两种结论由编排层直接合成结果，不进入工具自身实现。终止原因被显式建模为完成、等待审批与步数耗尽三种（`ai/agent/AgentLoop.kt` 的 `AgentFinishReason`）。

第四，工具来源有七个，注册顺序在 `ChatToolFactory.createTools` 中固定为：记忆、搜索、本地、会话、工作区、Skill、MCP（`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt`）。这一顺序与 `docs/references/chat-generation-pipeline.md` 第四阶段的描述不一致，文档把搜索排在第一位且把 Memory 排在最后；当前快照以源码为准。

横向比较可注意四点：工具目录是每轮生成现算的，没有持久化缓存；MCP 工具命名采用 `mcp__{server}__{tool}` 且服务名有字符白名单校验，非法名会让整次生成直接报错，不会静默丢弃；输出截断放在工具装配层统一包装，除搜索工具外所有工具都受 32KB 上限约束，但只有在会话具备可读本地 Rootfs 的工作区时才启用；记忆工具是六个独立工具，按文件路径与版本号操作。

## 系统边界与总体调用链

一次带工具的生成请求，工具相关部分的主链路如下。

```text
ChatService.handleMessageComplete()
  -> chatToolFactory.createTools(settings, assistant, model, workspaceCwd)
       -> memory / search / local / conversation / workspace / skills / mcp
       -> 若工作区具备本地 Rootfs，则对每个工具包装输出截断（search_web 除外）
  -> ChatRequestFactory.createAgent(...).run()  （AgentLoop，maxSteps 默认 256）
       for step in 0 until maxSteps:
         - 末尾消息里有可恢复审批的工具？有则跳过模型调用直接执行
         - 否则 generateStep() -> hooks.prepareStep()/finishStep() -> Provider.streamText()
         - 检查最新消息中未执行的 Tool
              - 无 -> finish(Completed)
              - 需审批且状态 Auto -> 置 Pending，emit，finish(AwaitingApproval)
              - 已审批 -> 执行或合成结果
         - 结果回写末尾助手消息 parts -> emit -> 下一 Step
  -> onSuccess: saveConversation / generateTitle / generateSuggestion
```

入口在 `ChatService.handleMessageComplete`（`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt`），它先构造工具集，再把工具列表与生成参数交给 `ChatRequestFactory` 构造的 Agent，循环本体在 `ai` 模块执行。循环通过 `AgentEvent.Messages` 等事件把最新消息推给服务层，后者更新会话状态并触发通知。

模型能否真正看到工具，还取决于 provider 的序列化条件。OpenAI 兼容实现只在模型声明支持工具能力、且工具列表非空时，才把工具写进请求的 tools 字段（`ChatCompletionsAPI.kt`）。注册与注入是两个层面：模型不支持工具时，`ChatService` 还会额外发一条提示性错误（`ChatService.kt`）。

## 1. 工具定义、来源与注册

### 1.1 工具数据契约

工具以序列化数据类 `Tool` 描述，字段固定六项：

- 名称；
- 描述；
- 可空参数 schema 提供器；
- systemPrompt 生成器；
- 审批判定器；
- 挂起执行器。

参数与系统提示都由函数提供，每次构建请求时重新求值，因此能读到当次会话的模型与消息。参数 schema 只有对象一种形态，即 `InputSchema.Obj`，带 properties 与一个可选 required 列表（`ai/src/main/java/me/rerere/ai/core/Tool.kt`）。

执行器的返回类型是 `List<UIMessagePart>`，不是字符串。这允许工具直接产出图片等非文本内容，工作区读图片工具就利用了这一点（`app/src/main/java/me/rerere/rikkahub/data/ai/tools/WorkspaceTools.kt`）。

### 1.2 七个工具来源

`ChatToolFactory.createTools` 是唯一的总装入口，按固定顺序累积工具。下表按源码顺序列出各来源的启用条件与实现位置。

| 顺序 | 来源 | 启用条件 | 实现位置 |
|---|---|---|---|
| 1 | 记忆工具 | `assistant.enableMemory` | `buildMemoryTools`，`tools/MemoryTools.kt` |
| 2 | 搜索工具 | `assistant.enableWebSearch` 且模型未内置搜索 | `createSearchTools`，`tools/SearchTools.kt` |
| 3 | 本地工具 | 助手 `localTools` 列表中包含对应项 | `LocalTools.getTools`，`tools/local/LocalTools.kt` |
| 4 | 会话工具 | `assistant.enableRecentChatsReference` | `createConversationTools`，`tools/ConversationTools.kt` |
| 5 | 工作区工具 | 助手绑定 workspace 且 shell 状态为 READY | `createWorkspaceToolsIfReady`，`ChatToolFactory.kt` |
| 6 | Skill 工具 | `assistant.enabledSkills` 非空 | `createSkillTools`，`tools/SkillsTools.kt` |
| 7 | MCP 工具 | 服务器启用、助手订阅且该工具 enable | `McpManager.getAllAvailableTools`，`mcp/McpManager.kt` |

几处实现细节。记忆工具的存储目标是全局记忆还是助手私有记忆，由 `assistant.useGlobalMemory` 在构造回调时决定（`ChatToolFactory.kt`）。搜索工具的启用条件除开关外，还要判断模型自身是否已内置搜索能力，避免重复注入（`ChatToolFactory.kt`）。工作区工具不只看配置存在与否，还要求数据库中的 shell 状态等于 `READY`，否则直接跳过（`ChatToolFactory.kt`）。

### 1.3 各来源的工具清单

本地工具是选项驱动的，`LocalToolOption` 定义了八种：JS 引擎、时间、剪贴板、TTS、询问用户、屏幕时间、日历、图表展示（`tools/local/LocalToolOption.kt`）。日历选项一次产出查询和创建两个工具，因此本地工具实际最多九个。

搜索工具最多两个。`search_web` 总是添加，`scrape_web` 只在当前搜索服务的 `scrapingParameters` 非空时添加（`SearchTools.kt`）。抓取能力由搜索服务自身能力决定，不单独由开关控制。

会话工具固定两个：`recent_chats` 列最近会话标题与日期，`conversation_search` 对历史消息做全文检索（`ConversationTools.kt`）。注释明确说明这是为了不把近期聊天静态注入 system prompt 以保持提示缓存（`ConversationTools.kt`）。

工作区工具固定四个：读文件、写文件、编辑文件、shell。Skill 工具固定一个 `use_skill`。记忆工具为六个独立工具：读、写、唯一子串替换、追加、删除与列目录，读写以文件路径与版本号为契约（`tools/MemoryTools.kt`、`data/repository/MemoryRepository.kt`）。

### 1.4 MCP 服务名白名单

MCP 工具在注册前会做一次服务名校验：所有可用工具的去重服务名必须非空且只含字母数字（`ChatToolFactory.kt`）。校验失败抛出 `InvalidMcpServerNamesException`，`ChatService` 捕获后暂停消息队列并报错，整次生成不会开始（`ChatService.kt`）。这是一个“宁可失败也不生成非法工具名”的取舍。

## 2. 工具发现、过滤与注入

### 2.1 目录构建时机

工具目录在每次 `handleMessageComplete` 调用时现算，不在启动时构建（`ChatService.kt`）。因此助手配置、工作区 shell 状态、MCP 连接状态的变化都会在下次生成时自然生效，不需要额外的失效逻辑。代价是每轮生成都重新组装列表，且工作区和 MCP 工具构建涉及数据库或网络状态查询。

### 2.2 MCP 工具的过滤链

MCP 工具可见性由三层条件叠加：服务器自身 `commonOptions.enable` 为真、服务器 id 出现在当前助手的 `mcpServers` 订阅集合中、单个工具 `enable` 为真（`McpManager.kt`）。这三层分别对应“服务器是否启用”“该助手是否订阅”“该工具是否被用户勾选”。

### 2.3 systemPrompt 注入

工具对系统提示的贡献在组装 system 消息时逐条拼接：助手提示、记忆块、以及每个工具的 `systemPrompt(model, messages)` 输出（`data/ai/ChatRequestFactory.kt` 的 `buildStep`）。记忆块由 `buildMemoryPrompt` 生成：核心文件（画像与偏好）给出全文，其余文件只给路径、描述、别名与版本组成的目录，格式与写入规则共享给后台整理进程（`data/ai/prompts/MemoryPrompts.kt`）。

目前只有两类本地工具实现了非空 systemPrompt。一是 Skill 工具，它把可用技能的名字与描述以 `<available_skills>` XML 块形式注入，让模型知道有哪些技能可加载（`SkillsTools.kt`）。二是 TTS 工具，它把当前 TTS provider 的语气引导注入 system prompt，若 provider 没有硬编码引导则为空（`tools/local/TextToSpeechTool.kt`）。

### 2.4 参数 schema 注入

参数 schema 在 Provider 序列化时求值。OpenAI 兼容实现把 `tool.parameters()` 的结果直接编码进 `function.parameters`，为空时退化为一个空的 `InputSchema.Obj`（`ChatCompletionsAPI.kt`）。工具必须自行保证 schema 合法，框架不做校验或补全。

## 3. 模型调用表示与 Provider 适配

### 3.1 原生 tool_calls

RikkaHub 使用 provider 原生工具协议，不是文本协议。工具以函数形式写入请求的 `tools` 数组（`ChatCompletionsAPI.kt`），流式响应的工具调用由 `StreamChunkHandler` 按 `toolCallId` 增量合并（`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt`）。

### 3.2 结果回传时的分组

回传给模型时，助手消息的 parts 先按工具边界切段：已执行完的工具 part 归入工具组，其余归入内容组，保证每条工具调用后面紧跟对应的结果消息（`ai/src/main/java/me/rerere/ai/provider/providers/ProviderMessageUtils.kt`）。以文本与工具交替的序列为例，`[Text1, Tool1, Tool2, Text2, Tool3]` 会被切成内容、工具、内容、工具四段。OpenAI 实现按组输出：每个工具组先发一条带工具调用的 assistant 消息，再逐条发角色为 tool 的结果消息（`ChatCompletionsAPI.kt`）。

### 3.3 工具结果的模态降级

工具结果中的图片只有在模型支持图片输入时才作为多模态内容回传，否则替换为文本占位（`ChatCompletionsAPI.kt`）。同一段逻辑对只有文本结果的常见情况做了优化：全部是文本时直接拼成字符串，避免退化成内容数组（`ChatCompletionsAPI.kt`）。

### 3.4 残缺参数的归一化

流式生成中断可能留下不完整的工具参数 JSON。序列化时调用 `inputAsJson()` 归一化原始字符串，解析失败则退化为空对象（`ChatCompletionsAPI.kt`，`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt`）。这样即使模型输出被截断，回传的 `arguments` 仍是合法 JSON。

### 3.5 其他 Provider

除 OpenAI 兼容实现外，`ai` 模块还提供 Claude、Google 等 provider 实现（`ai/src/main/java/me/rerere/ai/provider/providers/`）。本次调查以 OpenAI 兼容路径为主线逐行核对，其他 provider 的工具序列化细节未逐行阅读。

## 4. 参数解析、校验与错误处理

### 4.1 框架层解析

框架只在执行前做一次解析：把 `tool.input` 字符串解析为 `JsonElement`，空白输入按 `{}` 处理，解析失败抛出带工具名的错误（`AgentLoop.kt` 的参数解析）。框架不校验参数结构、必填字段或类型，全部交给工具自己。

### 4.2 工具层校验

参数校验由各工具分别实现，三处风格差异如下：

- 会话搜索：缺少查询词时直接抛错，并把结果条数钳制在允许范围内（`ConversationTools.kt`）；
- 记忆：按路径与版本参数分支，路径非法、替换原文为空或不唯一、版本冲突都写成可读的错误结果返回（`MemoryTools.kt`、`MemoryRepository.kt`）；
- 工作区：用一组私有扩展函数提取路径与字符串，路径必须是以 `/` 开头的 Rootfs 绝对路径，含空字节或非绝对路径都会失败（`WorkspaceTools.kt`）。

日历工具的校验最重，它对时间格式按 epoch 毫秒、带偏移日期时间、Instant、本地日期时间、本地日期的顺序依次尝试解析，并额外校验区间合法性，失败时返回结构化的错误 JSON 而不是抛异常（`tools/local/CalendarTool.kt`、`CalendarTool.kt`）。

### 4.3 执行错误处理

工具执行被 `runCatching` 包裹。取消异常必须向上传播，否则停止生成会被误报为工具执行错误；其他异常被打印并合成为带异常类名、消息和完整堆栈的 JSON 错误结果（`AgentLoop.kt` 的 `runTool` 与错误合成）。普通工具错误不中断循环，只作为工具输出回注给模型，让模型有机会自我修正。

有一类错误在更早的层被处理：工作区工具内部的 `runRootfsCommand` 会把超时、非零退出码和输出截断统一转成异常，再由外层合成为错误结果（`WorkspaceTools.kt`）。

## 5. 编排循环、并发与终止条件

### 5.1 循环结构

`AgentLoop.run` 是一个受步数上限约束的循环，上限由构造 Agent 时的 `maxSteps` 决定（默认 256）。每轮先判断末尾消息是否已有可恢复执行的工具，没有才调用模型。这个分支是审批恢复的关键：用户审批后重新进入生成入口，循环看到已被批准、拒绝或已回答的工具就直接跳过模型调用，进入执行阶段（`ai/agent/AgentLoop.kt` 的 `requestApprovals`/`executeTools` 分支）。

循环只负责步进、执行工具与发布事件，起始消息、每步请求装配、流式重试、预览转换与收尾统一交给 `AgentHooks` 实现。网络重试策略由构造方注入，默认对网络异常启用（`data/ai/ChatRequestFactory.kt` 的 retryPolicy、`ai/agent/Retry.kt`）。终止原因分完成、等待审批与步数耗尽三种，调用方据此决定落库与提示方式（`ai/agent/Agent.kt` 的 AgentFinishReason）。

### 5.2 无工具时终止

模型返回后，循环取末尾消息中未执行的 Tool。若为空，直接 break，生成结束（`AgentLoop.kt` 的 `finish(Completed)` 分支）。否则进入审批判定。

### 5.3 审批判定与中断

审批扫描对末尾消息里每个尚未执行的工具按名称找到对应定义，再根据是否需要审批与当前状态决定去向：

- 需要审批且状态为自动：改成待审批，并记下本轮存在待审工具；
- 已经是待审批：保持原状，继续等待用户；
- 其他状态：不做改动。

只要有工具被置为待审批，循环就更新消息、发出事件并结束本轮，等用户操作（`AgentLoop.kt` 的审批扫描与等待审批收尾）。

### 5.4 并发与取消

工具执行是顺序的：循环用 forEach 逐个跑完待处理列表（`AgentLoop.kt` 的 `executeTools`）。审批处理按会话串行化，`ChatService.handleToolApproval` 用 synchronized 包住同一会话的审批，并在启动新 Job 前确认没有其他待审批工具，全部处理完才继续生成（`ChatService.kt`）。停止生成走协程取消，循环捕获到的取消异常会重新抛出，把中断交给上层处理（`AgentLoop.kt` 的取消重抛）。

### 5.5 无结果时的兜底终止

如果一轮下来 `executedTools` 为空（例如全部工具仍是 `Pending`），循环 break，避免死循环（`AgentLoop.kt` 的无进展兜底）。

## 6. 审批、授权与执行边界

### 6.1 审批状态机

审批状态定义在 `ai` 模块的工具 part 上，共五个取值：自动、待审批、已批准、已拒绝与已回答，后两者分别携带拒绝原因和用户答案（`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt`）。只有已批准、已拒绝、已回答三种状态可以恢复执行，判定由 `canResumeToolExecution` 完成，与状态定义在同一文件。

| 状态 | 进入方式 | 循环行为 |
|---|---|---|
| Auto | 默认 | `needsApproval` 为真时转 Pending，否则直接执行 |
| Pending | 框架置位 | 中断本轮等待用户 |
| Approved | 用户批准 | 执行工具 |
| Denied | 用户拒绝 | 合成 `Tool execution denied by user` 错误 JSON |
| Answered | 用户填写答案 | 直接把答案文本作为工具输出 |

用户拒绝或填写答案时，对应的工具不会被执行，结果由编排层直接合成（`AgentLoop.kt` 的 `Denied`/`Answered` 合成）。`ask_user` 工具依赖这一机制：它恒定要求审批，自身执行函数只抛出错误，真实答案来自人工审批流程（`tools/local/AskUserTool.kt`）。

### 6.2 审批入口与恢复

用户动作从 UI 进入 `ChatVM.handleToolApproval` 或 handleToolAnswer（`app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatVM.kt`），再调用 `ChatService.handleToolApproval`。后者会忽略重复点击和对已完成工具的操作：只有目标工具仍是 `Pending` 时才处理（`ChatService.kt`）。

### 6.3 审批策略的来源

审批判定由每个工具自带的函数决定，不是全局开关。工作区工具有一套默认表：读、写、编辑默认不需审批，shell 默认需要审批（`WorkspaceTools.kt`）。工作区还可以按名称覆盖默认值（`WorkspaceTools.kt`）。

写文件与编辑文件还有一个额外的强制审批条件：路径落在可写安全区之外时，无论默认值如何都必须审批（`WorkspaceTools.kt`）。可写安全区定义为 `/workspace`、`/tmp`、`/skills` 三个前缀（`WorkspaceTools.kt`）。

MCP 工具的审批来自服务器同步下来的 needsApproval 字段，默认 false（`mcp/McpConfig.kt`、`ChatToolFactory.kt`）。本地工具中目前只有 ask_user 与日历创建显式需要审批（`AskUserTool.kt`、`CalendarTool.kt`）。

### 6.4 执行边界

工具按物理执行位置分三类：

- 纯本地计算（JS 引擎、时间、剪贴板）：在 Android 进程内直接执行；
- 系统集成（日历、屏幕时间、TTS）：经 Android 的 ContentResolver、UsageStatsManager 或事件总线执行，权限不足时返回结构化错误，屏幕时间工具还会主动打开系统设置页（`tools/local/ScreenTimeTool.kt`）；
- 工作区：命令包成对 `/bin/bash -l -c` 的调用后交给 PRoot 沙箱，工作区文件区通过 bind mount 挂到 `/workspace`，/dev、/proc、/sys 三个内核伪文件系统一并挂入（`workspace/src/main/java/me/rerere/workspace/ProotShellRunner.kt`、`workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt`）。

沙箱的隔离来自 PRoot 的 `--root-id`、`--link2symlink`、`--kill-on-exit` 参数以及 Rootfs 根目录，环境变量被显式重置为最小集合（`ProotShellRunner.kt`）。命令文本通过位置参数传入，避免转义问题（`ProotShellRunner.kt`）。

### 6.5 沙箱外的路径解析

工作区读文件工具支持 Rootfs 内绝对路径：路径解析把 `/workspace` 前缀映射回宿主机的 files 目录，把 bind mount 目标映射到宿主机源目录，三个内核伪文件系统路径（/dev、/proc、/sys）的按文件读取一律拒绝并提示改用 shell（`WorkspaceManager.kt`）。读文件大小上限 8MB，超限时报错并建议用 shell 分段读取（`WorkspaceTools.kt`）。

### 6.6 shell 的超时与输出上限

shell 命令默认超时 30 秒，可由模型通过 `timeout` 参数指定，最大 600 秒（`WorkspaceTools.kt`）。单个输出流保留上限 128KB，超出后继续读到 EOF 但丢弃内容，防止管道写满阻塞子进程（`workspace/src/main/java/me/rerere/workspace/WorkspaceShellRunner.kt`、`WorkspaceShellRunner.kt`）。

## 7. 结果回注、执行状态与恢复

### 7.1 结果内联，不生成 TOOL 消息

执行结果被写回触发它的 `UIMessagePart.Tool.output`，整个助手消息用 `copy(parts = ...)` 替换（`AgentLoop.kt` 的 `updateTool`）。文档注释明确写了“NOT create TOOL message”（`AgentLoop.kt` 文件头注释）。这种表示让同一助手消息可以同时承载文本、推理和多个工具调用及其结果，代价是每次回注都要重建整个消息。

### 7.2 输出截断

截断不分工具类型，而是在工具集装配完成后统一包装：只要会话绑定的工作区具备可读的本地 Rootfs，除搜索工具外的每个工具都会被套上一层输出上限；输出文本总长超过 32KB 才触发，搜索工具因 UI 与引用跳转依赖完整 JSON 结构而被排除（`data/ai/tools/ChatToolFactory.kt` 的 `withOutputTruncation`、`TOOLS_WITHOUT_OUTPUT_TRUNCATION`）。

截断行为是：完整文本写入 `filesDir/tool_outputs/{uuid}.txt`，消息中只保留前 4KB 预览，并在预览前附加总字符数、文件路径以及用 cat 与 grep 检索的 shell 指令提示；提示里的路径是 Rootfs 内的 `/tool_outputs/...`，只有本地挂载该目录的工作区能读到，远程工作区读不到。非文本 part（如图片）不受截断影响，会原样追加在文本之后（`data/ai/tools/ChatToolFactory.kt`、`data/files/FileFolders.kt`）。

### 7.3 中断与恢复

三条路径共同保证工具状态不悬空：

- 每次生成前，`checkInvalidMessages` 清理仍带未解决审批的节点，但保留可恢复状态和全部已执行的工具；
- 发送新消息时，`finishInterruptedPendingTools` 把上次被打断的待执行工具标记为取消结果；
- `cancelToolByUser` 合成的取消 JSON 带 `status:cancelled` 字段。

三处逻辑都在 `ChatService.kt`。

### 7.4 持久化

工具调用、结果与审批状态都是 `UIMessagePart.Tool` 的一部分，随会话消息一起被 `saveConversation` 持久化。审批发生时 `handleToolApproval` 会先更新并保存会话再决定是否继续生成（`ChatService.kt`）。完整的消息 schema 与恢复语义属于“会话与消息管理”类目，本笔记只记录工具侧的字段契约。

## 8. MCP、插件、Skill 与子 Agent

### 8.1 MCP 客户端架构

MCP 子系统分三层：`McpManager` 是公共入口，协调配置、OAuth、连接注册表与 UI 内容转换；`McpSessionRegistry` 管理单服务器连接状态机与重连；`McpOAuthCoordinator` 处理 OAuth 协议细节（`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpManager.kt`）。

### 8.2 传输类型

支持两种传输：SSE 和 Streamable HTTP，由配置的密封类区分（`mcp/McpConfig.kt`、`mcp/McpSessionRegistry.kt`）。HTTP 客户端配置了 20 秒连接超时、10 分钟读超时、120 秒写超时，并启用 SSE 插件（`McpManager.kt`）。

### 8.3 工具发现与同步

连接成功后会调用 `listTools` 并把服务器返回的工具合并进本地配置。合并不是全量替换：已有同名工具保留本地 `enable` 开关并更新描述与 schema，新工具默认启用（`McpSessionRegistry.kt`）。这是为了让用户在配置界面上的勾选在服务器更新后不丢失。

### 8.4 重连策略

传输关闭或出错会触发重连，最多 5 次，退避从 1 秒指数增长到 30 秒上限（`McpSessionRegistry.kt`）。同一会话同时只允许一个重连任务。重连是否必要由连接参数决定，工具开关和 schema 变化不触发重连。

### 8.5 命名与调用

MCP 工具名格式为 `mcp__{serverName}__{toolName}`（`ChatToolFactory.kt`）。调用时把参数对象透传给服务器的 callTool，请求超时 120 秒（`McpSessionRegistry.kt`）。返回值按内容类型转换：文本直接成为文本 part，图片解码后保存为本地文件并转为图片 part，其他内容编码为 JSON 文本（`McpManager.kt`）。

客户端不可用时返回文本错误结果，不抛异常（`McpManager.kt`），这与框架对普通工具错误的处理方式一致，都让错误作为工具输出回到模型。

### 8.6 Skill 工具

Skill 工具从助手启用的技能集合与磁盘上的技能列表求交集，交集为空则不注册（`SkillsTools.kt`）。执行时省略 `path` 参数读取 `SKILL.md` 的正文（去掉 frontmatter），提供 `path` 时解析为技能目录内相对路径，越界或不存在都会报错（`SkillsTools.kt`）。

技能目录有两条来源：用户技能放在应用私有目录的 skills 目录下，内置技能随 APK 打包在 assets 中，首次使用时解压到内置技能目录并与用户技能合并；技能元数据来自 `SKILL.md` 的 frontmatter，必须有 name 和 description 才会被识别，非法目录会被单独列出并可删除。助手的启用名单会在技能被删除或改名后做一次游离清理（`data/skills/SkillManager.kt`、`data/skills/SkillValidator.kt`、`data/skills/BuiltinSkills.kt`）。

### 8.7 子 Agent

本次调查未在源码中找到子 Agent 或工具内再起生成循环的实现。工具的 `execute` 签名只接收参数并返回 parts，没有回调生成器的通道。旁路能力仅体现在 MCP 工具的“返回内容类型可扩展”和工作区 shell 的“命令内容不受控”两点上，这两者都仍在统一的注册、审批与回注路径内。

## 9. 设计取舍与已确认边界

### 9.1 已确认的实现取舍

工具协议极简，把参数校验完全下放给工具，框架不做统一 schema 校验。这让新增工具成本低，但也意味着各工具的错误风格不统一，有的抛异常有的返回错误 JSON。

工具目录每轮现算，不做缓存，牺牲少量重复计算换取配置变更立即生效。

结果内联在助手消息，不生成独立 TOOL 消息；这简化了消息树与分支逻辑，代价是协议序列化时需要重新分组。

审批判定放在编排层，`Denied` 和 `Answered` 由框架合成结果，只有真正执行的工具才进入实现。这让审批流程对所有工具统一；审批结论只覆盖是否允许本次调用，执行端的重新鉴权由工具实现自行承担（日历和屏幕时间工具就各自检查了系统权限）。

### 9.2 已确认的边界

截断只在工作区具备可读本地 Rootfs 时启用，且搜索工具被排除；没有工作区或工作区为远程模式时，超大输出原样进入上下文。

MCP 服务名有字符白名单，非法名会让整次生成失败，不会丢弃该服务器。

工作区 shell 默认需要审批，但该默认值可被工作区配置覆盖，覆盖后 shell 可以免审批执行。

`inputAsJson` 在解析失败时静默退化为空对象，模型收到的可能是一个参数为空的工具调用，不会收到解析错误。

### 9.3 文档与实现的不一致

`docs/references/chat-generation-pipeline.md` 第四阶段列出的注册顺序是搜索、本地、会话、工作区、Skill、MCP、记忆，而当前快照的实际顺序是记忆、搜索、本地、会话、工作区、Skill、MCP（`ChatToolFactory.kt`）。文档还把 Memory 描述为内置于某个生成处理器，实际由 `ChatToolFactory` 构造、循环由 `ai` 模块的 `AgentLoop` 承担。以源码为准。

## 10. 未验证事项

- Claude、Google 等非 OpenAI 兼容 provider 的工具序列化与工具结果解析未逐行核对，本笔记关于协议适配的结论仅对 OpenAI 兼容路径成立。
- 未运行构建、单元测试或真机验证；沙箱 shell 在真实 Android 设备上的 PRoot 行为、内核伪文件系统挂载效果属于需要在目标环境观察的维度。
- 未核对工作区工具中 `readImageInRootfs` 走 `getKoin().get<FilesManager>()` 这一服务定位器用法在非 UI 上下文中的可用性边界。
- 未核对 MCP OAuth 授权码流程的具体实现（`McpOAuthCoordinator`、`McpOAuthDiscoveryClient` 未逐行阅读）。
- 未确认“工具输出超过 32KB 且工作区为远程模式或未绑定”时是否存在其他兜底截断路径；本次只找到 `ChatToolFactory` 中的一处截断实现。
- 未核对 `AgentLoop` 的 `AgentHooks` 在预览、重试与收尾各阶段的实际调用顺序与错误传播，也未验证 JS 工具的超时与日志截断在真实脚本下的行为。
- 未核对图表展示工具（`chart_display`）与消息渲染层的交互契约，其工具卡渲染属于消息渲染器类目。
- 未核对各 provider 对工具结果中图片的支持差异，`toToolResultContent` 的模态降级只在 OpenAI 兼容实现中确认。
- 未确认 UI 侧工具卡片的渲染、折叠与错误展示细节，属于消息渲染器类目的调查范围。

## 11. 关键源码索引

- 工具协议定义：`ai/src/main/java/me/rerere/ai/core/Tool.kt`
- 审批状态与工具 part：`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt`
- 工具总装入口：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt`
- 生成循环与审批判定：`ai/src/main/java/me/rerere/ai/agent/AgentLoop.kt`
- 输出截断：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt` 的 `withOutputTruncation`/`truncateOutput`
- systemPrompt 与记忆注入：`data/ai/ChatRequestFactory.kt`、`data/ai/prompts/MemoryPrompts.kt`
- 编排入口与审批恢复：`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt`、`data/ai/ChatRequestFactory.kt`
- 无效工具清理与中断结算：`service/ChatService.kt` 的 `checkInvalidMessages`、`finishInterruptedPendingTools`、`cancelToolByUser`
- OpenAI 协议序列化：`ai/src/main/java/me/rerere/ai/provider/providers/openai/ChatCompletionsAPI.kt`
- 消息分组：`ai/src/main/java/me/rerere/ai/provider/providers/ProviderMessageUtils.kt`
- 流式工具合并：`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt`
- 本地工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/LocalTools.kt`
- 搜索工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/SearchTools.kt`
- 会话工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ConversationTools.kt`
- 工作区工具与审批默认值：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/WorkspaceTools.kt`
- 文本替换策略：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/TextReplacers.kt`
- Skill 工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/SkillsTools.kt`
- 记忆工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/MemoryTools.kt`
- MCP 入口与工具发现：`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpManager.kt`
- MCP 连接与重连：`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpSessionRegistry.kt`
- 工作区沙箱执行：`workspace/src/main/java/me/rerere/workspace/ProotShellRunner.kt`
- 工作区路径解析与配置：`workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt`
- 进程输出采集与上限：`workspace/src/main/java/me/rerere/workspace/WorkspaceShellRunner.kt`
