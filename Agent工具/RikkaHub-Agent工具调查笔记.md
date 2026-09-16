# RikkaHub Agent 工具调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：只读源码梳理。按 `app/src/main/java/me/rerere/rikkahub/data/ai/`、`ai/src/main/java/me/rerere/ai/`、`workspace/src/main/java/me/rerere/workspace/` 三层逐入口复查；关键结论以当前快照可执行路径为准，未运行构建或测试。
>
> 调查范围：工具来源与注册顺序、schema 与 systemPrompt 注入、模型协议适配、调用解析、审批状态机、执行与结果回注、Step 循环、输出截断、错误处理、MCP 客户端发现与命名、Workspace/Skill/记忆工具的执行边界。不覆盖 UI 渲染细节、会话持久化 schema 与检索模块内部实现。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的工具体系由 `ai` 模块定义协议、`app` 模块组装具体工具、`workspace` 模块提供沙箱执行环境。关键特征有四点。

第一，工具协议是一个极简的自定义数据类，不绑定任何 SDK。每个工具由名称、描述、参数 schema 提供器、systemPrompt 生成器、审批判定器和挂起执行器组成（`ai/src/main/java/me/rerere/ai/core/Tool.kt:11-19`）。参数 schema 只有 `InputSchema.Obj` 一种对象形态，不表达数组、枚举等嵌套的完整 JSON Schema 能力，具体细节由各工具在构造时用 `buildJsonObject` 手工拼出。

第二，工具结果写入触发它的 ASSISTANT 消息的 parts，不创建 TOOL 角色消息。循环每轮把执行完的 `UIMessagePart.Tool` 回写到末尾助手消息，再进入下一轮模型调用（`app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt:304-322`）。协议序列化时才按工具边界重新分组，把工具调用拆成 `assistant.tool_calls` 加紧随其后的 `role:"tool"` 消息（`ai/src/main/java/me/rerere/ai/provider/providers/openai/ChatCompletionsAPI.kt:499-521`）。

第三，审批是编排层状态机，执行端不做鉴权。工具执行前先检查 `needsApproval`，命中则把 `ToolApprovalState` 从 `Auto` 改成 `Pending` 并中断本轮，等用户动作后再从 `Pending` 恢复；`Denied` 和 `Answered` 在编排层直接合成结果，不进入工具自身实现（`GenerationLoop.kt:172-297`）。

第四，工具来源有七个，注册顺序在 `ChatToolFactory.createTools` 中固定为：记忆、搜索、本地、会话、工作区、Skill、MCP（`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt:43-95`）。这一顺序与 `docs/references/chat-generation-pipeline.md` 第四阶段的描述不一致，文档把搜索排在第一位且把 Memory 排在最后；当前快照以源码为准。

横向比较可注意三点：工具目录是每轮生成现算的，没有持久化缓存；MCP 工具命名采用 `mcp__{server}__{tool}` 且服务名有字符白名单校验，非法名会让整次生成直接报错，不会静默丢弃；输出截断依赖“当前工具集中存在 workspace_shell”这一条件，不按输出类型判断。

## 系统边界与总体调用链

一次带工具的生成请求，工具相关部分的主链路如下。

```text
ChatService.handleMessageComplete()
  -> chatToolFactory.createTools(settings, assistant, model, workspaceCwd)
       -> memory / search / local / conversation / workspace / skills / mcp
  -> GenerationLoop.generateText(tools = tools, maxSteps = 256)
       for step in 0 until maxSteps:
         - 末尾消息里有 canResumeExecution 工具？有则跳过模型调用直接执行
         - 否则 generateInternal()
              - 组装 system：助手提示 + 记忆 + 每个工具的 systemPrompt
              - limitContext() 裁剪历史 -> InputTransformers -> TextGenerationParams(tools)
              - Provider.streamText() / generateText()
         - 检查最新消息中未执行的 Tool
              - 无 -> break
              - 需审批且状态 Auto -> 置 Pending，emit，break
              - 已审批 -> 执行或合成结果
         - 结果回写末尾助手消息 parts -> emit -> 下一 Step
  -> onSuccess: saveConversation / generateTitle / generateSuggestion
```

入口在 `ChatService.handleMessageComplete`（`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt:658-805`），它先构造工具集，再把工具列表和生成参数一并交给 `GenerationLoop`。循环本身是一个 `flow`，每个 Step 通过 `GenerationChunk.Messages` 把最新消息列表推给 `ChatService`，后者更新会话状态并触发通知（`ChatService.kt:767-783`）。

模型是否真正看到工具，还取决于 provider 的序列化条件。OpenAI 兼容实现在 `params.model.abilities` 包含 `ModelAbility.TOOL` 且工具列表非空时才写入 `tools` 字段（`ChatCompletionsAPI.kt:420-439`）。“已注册”与“已注入”是两个不同层面，`ChatService` 在模型不支持工具时会额外发一条提示性错误（`ChatService.kt:682-690`）。

## 1. 工具定义、来源与注册

### 1.1 工具数据契约

`Tool` 是一个序列化数据类，包含六个字段：名称、描述、可空参数 schema 提供器、systemPrompt 生成器、审批判定器、挂起执行器（`Tool.kt:11-19`）。参数与 systemPrompt 都是函数，每次构建请求时重新求值，因此可以读取当次会话的 `Model` 和 `Messages`。参数 schema 的唯一形态是 `InputSchema.Obj`，带 `properties` 和一个可选 `required` 列表（`Tool.kt:21-29`）。

执行器的返回类型是 `List<UIMessagePart>`，不是字符串。这允许工具直接产出图片等非文本内容，工作区读图片工具就利用了这一点（`app/src/main/java/me/rerere/rikkahub/data/ai/tools/WorkspaceTools.kt:295-312`）。

### 1.2 七个工具来源

`ChatToolFactory.createTools` 是唯一的总装入口，按固定顺序累积工具。下表按源码顺序列出各来源的启用条件与实现位置。

| 顺序 | 来源 | 启用条件 | 实现位置 |
|---|---|---|---|
| 1 | 记忆工具 | `assistant.enableMemory` | `buildMemoryTools`，`tools/MemoryTools.kt` |
| 2 | 搜索工具 | `assistant.enableWebSearch` 且模型未内置搜索 | `createSearchTools`，`tools/SearchTools.kt` |
| 3 | 本地工具 | 助手 `localTools` 列表中包含对应项 | `LocalTools.getTools`，`tools/local/LocalTools.kt:31-56` |
| 4 | 会话工具 | `assistant.enableRecentChatsReference` | `createConversationTools`，`tools/ConversationTools.kt` |
| 5 | 工作区工具 | 助手绑定 workspace 且 shell 状态为 READY | `createWorkspaceToolsIfReady`，`ChatToolFactory.kt:97-108` |
| 6 | Skill 工具 | `assistant.enabledSkills` 非空 | `createSkillTools`，`tools/SkillsTools.kt` |
| 7 | MCP 工具 | 服务器启用、助手订阅且该工具 enable | `McpManager.getAllAvailableTools`，`mcp/McpManager.kt:106-116` |

几处实现细节。记忆工具的存储目标是全局记忆还是助手私有记忆，由 `assistant.useGlobalMemory` 在构造回调时决定（`ChatToolFactory.kt:44-58`）。搜索工具的启用条件除开关外，还要判断模型自身是否已内置搜索能力，避免重复注入（`ChatToolFactory.kt:21-23`）。工作区工具不只看配置存在与否，还要求数据库中的 shell 状态等于 `READY`，否则直接跳过（`ChatToolFactory.kt:100-106`）。

### 1.3 各来源的工具清单

本地工具是选项驱动的，`LocalToolOption` 定义了七种：JS 引擎、时间、剪贴板、TTS、询问用户、屏幕时间、日历（`tools/local/LocalToolOption.kt:6-35`）。其中日历选项一次产出查询和创建两个工具，因此本地工具实际最多八个（`LocalTools.kt:31-56`）。

搜索工具最多两个。`search_web` 总是添加，`scrape_web` 只在当前搜索服务的 `scrapingParameters` 非空时添加（`SearchTools.kt:89-124`）。抓取能力由搜索服务自身能力决定，不单独由开关控制。

会话工具固定两个：`recent_chats` 列最近会话标题与日期，`conversation_search` 对历史消息做全文检索（`ConversationTools.kt:23-111`）。注释明确说明这是为了不把近期聊天静态注入 system prompt 以保持提示缓存（`ConversationTools.kt:19-22`）。

工作区工具固定四个：读文件、写文件、编辑文件、shell（`WorkspaceTools.kt:47-52`）。Skill 工具固定一个 `use_skill`（`SkillsTools.kt:21-79`）。记忆工具固定一个 `memory_tool`，用 `action` 参数区分创建、编辑、删除（`MemoryTools.kt:25-101`）。

### 1.4 MCP 服务名白名单

MCP 工具在注册前会做一次服务名校验：所有可用工具的去重服务名必须非空且只含字母数字（`ChatToolFactory.kt:77-83`）。校验失败抛出 `InvalidMcpServerNamesException`，`ChatService` 捕获后暂停消息队列并报错，整次生成不会开始（`ChatService.kt:703-715`）。这是一个“宁可失败也不生成非法工具名”的取舍。

## 2. 工具发现、过滤与注入

### 2.1 目录构建时机

工具目录在每次 `handleMessageComplete` 调用时现算，不在启动时构建（`ChatService.kt:696-702`）。因此助手配置、工作区 shell 状态、MCP 连接状态的变化都会在下次生成时自然生效，不需要额外的失效逻辑。代价是每轮生成都重新组装列表，且工作区和 MCP 工具构建涉及数据库或网络状态查询。

### 2.2 MCP 工具的过滤链

MCP 工具可见性由三层条件叠加：服务器自身 `commonOptions.enable` 为真、服务器 id 出现在当前助手的 `mcpServers` 订阅集合中、单个工具 `enable` 为真（`McpManager.kt:106-116`）。这三层分别对应“服务器是否启用”“该助手是否订阅”“该工具是否被用户勾选”。

### 2.3 systemPrompt 注入

工具对系统提示的贡献在 `generateInternal` 组装 system 消息时逐条拼接：助手提示、记忆块、以及每个工具的 `systemPrompt(model, messages)` 输出（`GenerationLoop.kt:346-371`）。记忆块由 `buildMemoryPrompt` 生成，把记忆列表编码成 JSON 并包在 `**Memories**` 标题下（`app/src/main/java/me/rerere/rikkahub/data/ai/GenerationPrompts.kt:9-26`）。

目前只有两类工具实现了非空 systemPrompt。一是 Skill 工具，它把可用技能的名字与描述以 `<available_skills>` XML 块形式注入，让模型知道有哪些技能可加载（`SkillsTools.kt:28-42`）。二是 TTS 工具，它把当前 TTS provider 的语气引导注入 system prompt，若 provider 没有硬编码引导则为空（`tools/local/TextToSpeechTool.kt:29-34`）。

### 2.4 参数 schema 注入

参数 schema 在 Provider 序列化时求值。OpenAI 兼容实现把 `tool.parameters()` 的结果直接编码进 `function.parameters`，为空时退化为一个空的 `InputSchema.Obj`（`ChatCompletionsAPI.kt:428-434`）。工具必须自行保证 schema 合法，框架不做校验或补全。

## 3. 模型调用表示与 Provider 适配

### 3.1 原生 tool_calls

RikkaHub 使用 provider 原生工具协议，不是文本协议。工具以函数形式写入请求的 `tools` 数组（`ChatCompletionsAPI.kt:420-439`），流式响应的工具调用由 `StreamChunkHandler` 按 `toolCallId` 增量合并（`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:155-176`）。

### 3.2 结果回传时的分组

回传给模型时，助手消息的 parts 会先按工具边界分组，保证 `tool_calls` 后面紧跟 `tool` 结果消息（`ai/src/main/java/me/rerere/ai/provider/providers/ProviderMessageUtils.kt:26-58`）。分组规则是：已执行的 Tool part 归入 Tools 组，其他 part 归入 Content 组；`[Text1, Tool1, Tool2, Text2, Tool3]` 会拆成 Content、Tools、Content、Tools 四段。OpenAI 实现据此为每个 Tools 组先输出一条带 `tool_calls` 的 assistant 消息，再逐条输出 `role:"tool"` 结果消息（`ChatCompletionsAPI.kt:481-521`）。

### 3.3 工具结果的模态降级

工具结果中的图片只有在模型支持图片输入时才作为多模态内容回传，否则替换为文本占位（`ChatCompletionsAPI.kt:669-680`）。同一段逻辑对只有文本结果的常见情况做了优化：全部是文本时直接拼成字符串，避免退化成内容数组（`ChatCompletionsAPI.kt:673-680`）。

### 3.4 残缺参数的归一化

流式生成中断可能留下不完整的工具参数 JSON。序列化时调用 `inputAsJson()` 归一化原始字符串，解析失败则退化为空对象（`ChatCompletionsAPI.kt:619-621`，`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt:201-204`）。这样即使模型输出被截断，回传的 `arguments` 仍是合法 JSON。

### 3.5 其他 Provider

除 OpenAI 兼容实现外，`ai` 模块还提供 Claude、Google 等 provider 实现（`ai/src/main/java/me/rerere/ai/provider/providers/`）。本次调查以 OpenAI 兼容路径为主线逐行核对，其他 provider 的工具序列化细节未逐行阅读。

## 4. 参数解析、校验与错误处理

### 4.1 框架层解析

框架只在执行前做一次解析：把 `tool.input` 字符串解析为 `JsonElement`，空白输入按 `{}` 处理，解析失败抛出带工具名的错误（`GenerationLoop.kt:262-266`）。框架不校验参数结构、必填字段或类型，全部交给工具自己。

### 4.2 工具层校验

各工具用不同的方式做参数校验，风格并不统一。会话搜索工具在缺少 `query` 时直接 `error`，并对 `limit` 做范围钳制（`ConversationTools.kt:91-94`）。记忆工具对 `action` 做白名单分支，未知动作抛错，缺失字段抛错（`MemoryTools.kt:74-98`）。工作区工具用一套私有扩展函数处理路径与字符串提取，路径必须是以 `/` 开头的 Rootfs 绝对路径，含空字节或非绝对路径都会失败（`WorkspaceTools.kt:399-405`）。

日历工具的校验最重，它对时间格式按 epoch 毫秒、带偏移日期时间、Instant、本地日期时间、本地日期的顺序依次尝试解析，并额外校验区间合法性，失败时返回结构化的错误 JSON 而不是抛异常（`tools/local/CalendarTool.kt:109-138`、`CalendarTool.kt:430-437`）。

### 4.3 执行错误处理

工具执行被 `runCatching` 包裹。取消异常必须向上传播，否则停止生成会被误报为工具执行错误；其他异常被打印并合成为带异常类名、消息和完整堆栈的 JSON 错误结果（`GenerationLoop.kt:257-295`）。普通工具错误不中断循环，只作为工具输出回注给模型，让模型有机会自我修正。

有一类错误在更早的层被处理：工作区工具内部的 `runRootfsCommand` 会把超时、非零退出码和输出截断统一转成异常，再由外层合成为错误结果（`WorkspaceTools.kt:343-366`）。

## 5. 编排循环、并发与终止条件

### 5.1 循环结构

`GenerationLoop.generateText` 是一个 `for (stepIndex in 0 until maxSteps)` 循环，默认上限 256（`GenerationLoop.kt:83`、`GenerationLoop.kt:96`）。每轮先判断末尾消息是否已有可恢复执行的工具，没有才调用模型。这个分支是审批恢复的关键：用户审批后重新进入 `handleMessageComplete`，循环看到 `Approved`/`Denied`/`Answered` 的工具就直接跳过模型调用，进入执行阶段（`GenerationLoop.kt:99-107`）。

### 5.2 无工具时终止

模型返回后，循环取末尾消息中未执行的 Tool。若为空，直接 break，生成结束（`GenerationLoop.kt:166-170`）。否则进入审批判定。

### 5.3 审批判定与中断

对每个未执行工具，框架查找同名的 `Tool` 定义。若该工具 `needsApproval` 为真且当前状态是 `Auto`，则改为 `Pending` 并标记有待审批；已是 `Pending` 的保持等待；其他状态不动（`GenerationLoop.kt:172-191`）。若有任何工具被置为 `Pending`，更新消息后 emit 并 break，等用户操作（`GenerationLoop.kt:193-211`）。

### 5.4 并发与取消

工具执行是顺序的，`toolsToProcess.forEach` 逐个执行（`GenerationLoop.kt:222`）。`ChatService.handleToolApproval` 通过 `synchronized` 串行化同一会话的审批处理，并在启动新 Job 前检查是否还有其他待审批工具，只有全部处理完才继续生成（`ChatService.kt:584-642`）。停止生成通过协程取消实现，循环内的 `CancellationException` 会被重新抛出（`GenerationLoop.kt:275`）。

### 5.5 无结果时的兜底终止

如果一轮下来 `executedTools` 为空（例如全部工具仍是 `Pending`），循环 break，避免死循环（`GenerationLoop.kt:299-302`）。

## 6. 审批、授权与执行边界

### 6.1 审批状态机

状态定义在 `ai` 模块：`Auto`、`Pending`、`Approved`、`Denied(reason)`、`Answered(answer)`（`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt:11-32`）。`canResumeToolExecution` 只对 `Approved`、`Denied`、`Answered` 返回真（`UIMessagePart.kt:34-43`）。

| 状态 | 进入方式 | 循环行为 |
|---|---|---|
| Auto | 默认 | `needsApproval` 为真时转 Pending，否则直接执行 |
| Pending | 框架置位 | 中断本轮等待用户 |
| Approved | 用户批准 | 执行工具 |
| Denied | 用户拒绝 | 合成 `Tool execution denied by user` 错误 JSON |
| Answered | 用户填写答案 | 直接把答案文本作为工具输出 |

`Denied` 与 `Answered` 都不执行工具实现，结果在编排层合成（`GenerationLoop.kt:224-251`）。`ask_user` 工具正是依赖 `Answered`：它的 `needsApproval` 恒为真，`execute` 直接抛错，因为真实结果来自 HITL 流程（`tools/local/AskUserTool.kt:72-75`）。

### 6.2 审批入口与恢复

用户动作从 UI 进入 `ChatVM.handleToolApproval` 或 `handleToolAnswer`（`app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatVM.kt:263-278`），再调用 `ChatService.handleToolApproval`。后者会忽略重复点击和对已完成工具的操作：只有当目标工具仍是 `Pending` 时才处理（`ChatService.kt:601-604`）。

### 6.3 审批策略的来源

审批判定由每个工具自带的函数决定，不是全局开关。工作区工具有一套默认表：读、写、编辑默认不需审批，shell 默认需要审批（`WorkspaceTools.kt:26-31`）。工作区还可以按名称覆盖默认值（`WorkspaceTools.kt:33-34`、`WorkspaceTools.kt:42-43`）。

写文件与编辑文件还有一个额外的强制审批条件：路径落在可写安全区之外时，无论默认值如何都必须审批（`WorkspaceTools.kt:126`、`WorkspaceTools.kt:169`）。可写安全区定义为 `/workspace`、`/tmp`、`/skills` 三个前缀（`WorkspaceTools.kt:407-420`）。

MCP 工具的审批来自服务器同步下来的 `McpTool.needsApproval` 字段，默认 false（`mcp/McpConfig.kt:54-60`、`ChatToolFactory.kt:90`）。本地工具中目前只有 `ask_user` 与日历创建显式需要审批（`AskUserTool.kt:72`、`CalendarTool.kt:233`）。

### 6.4 执行边界

工具的物理执行位置可以分为三类。纯本地计算类（JS 引擎、时间、剪贴板）直接在 Android 进程内执行。系统集成类（日历、屏幕时间、TTS）通过 Android ContentResolver、UsageStatsManager 或事件总线执行，权限不足时返回结构化错误，屏幕时间工具还会主动打开系统设置页（`tools/local/ScreenTimeTool.kt:79-91`）。工作区类工具通过 PRoot 沙箱执行，命令被包成对 `/bin/bash -l -c` 的调用，工作区文件区通过 bind mount 挂到 `/workspace`，内核伪文件系统 `/dev`、`/proc`、`/sys` 也被挂入（`workspace/src/main/java/me/rerere/workspace/ProotShellRunner.kt:64-117`、`workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt:251-255`）。

沙箱的隔离来自 PRoot 的 `--root-id`、`--link2symlink`、`--kill-on-exit` 参数以及 Rootfs 根目录，环境变量被显式重置为最小集合（`ProotShellRunner.kt:68-116`）。命令文本通过位置参数传入，避免转义问题（`ProotShellRunner.kt:110-114`）。

### 6.5 沙箱外的路径解析

工作区读文件工具支持 Rootfs 内绝对路径，路径解析会把 `/workspace` 前缀映射回宿主机的 files 目录，把 bind mount 目标映射到宿主机源目录，并显式拒绝对 `/dev`、`/proc`、`/sys` 的按文件读取，提示改用 shell（`WorkspaceManager.kt:121-146`）。读文件大小上限 8MB，超限时报错并建议用 shell 分段读取（`WorkspaceTools.kt:24`、`WorkspaceTools.kt:289-291`）。

### 6.6 shell 的超时与输出上限

shell 命令默认超时 30 秒，可由模型通过 `timeout` 参数指定，最大 600 秒（`WorkspaceTools.kt:23`、`WorkspaceTools.kt:253-256`）。单个输出流保留上限 128KB，超出后继续读到 EOF 但丢弃内容，防止管道写满阻塞子进程（`workspace/src/main/java/me/rerere/workspace/WorkspaceShellRunner.kt:40`、`WorkspaceShellRunner.kt:112-134`）。

## 7. 结果回注、执行状态与恢复

### 7.1 结果内联，不生成 TOOL 消息

执行结果被写回触发它的 `UIMessagePart.Tool.output`，整个助手消息用 `copy(parts = ...)` 替换（`GenerationLoop.kt:304-311`）。文档注释明确写了“NOT create TOOL message”（`GenerationLoop.kt:65`）。这种表示让同一助手消息可以同时承载文本、推理和多个工具调用及其结果，代价是每次回注都要重建整个消息。

### 7.2 输出截断

截断只在两个条件同时满足时触发：工具输出文本总长超过 32KB，且当前工具集中存在名为 `workspace_shell` 的工具（`GenerationLoop.kt:536-545`）。注意这里判断的是“工具集中有 shell”而不是“这个工具是 shell”，因此任何大输出都可能被截断，前提是会话启用了工作区 shell。

截断行为是：完整文本写入 `filesDir/tool_outputs/{toolCallId}.txt`，消息中只保留前 4KB 预览，并在预览前附加总字符数、文件路径、`cat` 读取和 `grep` 搜索的 shell 指令提示（`GenerationLoop.kt:549-567`）。常量定义在文件顶部（`GenerationLoop.kt:55-56`），目录名常量来自 `FilesManager`（`app/src/main/java/me/rerere/rikkahub/data/files/FilesManager.kt:513-517`）。非文本 part（如图片）不受截断影响，会原样追加在文本之后（`GenerationLoop.kt:542`、`GenerationLoop.kt:567`）。

### 7.3 中断与恢复

三种路径共同保证工具状态不悬空。`checkInvalidMessages` 在每次生成前清理仍然带有未解决审批的节点，但保留可恢复状态和全部已执行的工具（`ChatService.kt:809-855`）。`finishInterruptedPendingTools` 在发送新消息时把上次被打断的待执行工具标记为取消结果（`ChatService.kt:867-884`）。`cancelToolByUser` 合成的取消 JSON 带 `status:cancelled` 字段（`ChatService.kt:857-865`）。

### 7.4 持久化

工具调用、结果与审批状态都是 `UIMessagePart.Tool` 的一部分，随会话消息一起被 `saveConversation` 持久化。审批发生时 `handleToolApproval` 会先更新并保存会话再决定是否继续生成（`ChatService.kt:611-641`）。完整的消息 schema 与恢复语义属于“会话与消息管理”类目，本笔记只记录工具侧的字段契约。

## 8. MCP、插件、Skill 与子 Agent

### 8.1 MCP 客户端架构

MCP 子系统分三层：`McpManager` 是公共入口，协调配置、OAuth、连接注册表与 UI 内容转换；`McpSessionRegistry` 管理单服务器连接状态机与重连；`McpOAuthCoordinator` 处理 OAuth 协议细节（`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpManager.kt:36-97`）。

### 8.2 传输类型

支持两种传输：SSE 和 Streamable HTTP，由配置的密封类区分（`mcp/McpConfig.kt:62-95`、`mcp/McpSessionRegistry.kt:432-444`）。HTTP 客户端配置了 20 秒连接超时、10 分钟读超时、120 秒写超时，并启用 SSE 插件（`McpManager.kt:47-66`）。

### 8.3 工具发现与同步

连接成功后会调用 `listTools` 并把服务器返回的工具合并进本地配置。合并不是全量替换：已有同名工具保留本地 `enable` 开关并更新描述与 schema，新工具默认启用（`McpSessionRegistry.kt:499-512`）。这是为了让用户在配置界面上的勾选在服务器更新后不丢失。

### 8.4 重连策略

传输关闭或出错会触发重连，最多 5 次，退避从 1 秒指数增长到 30 秒上限（`McpSessionRegistry.kt:45-47`、`McpSessionRegistry.kt:452-455`）。同一会话同时只允许一个重连任务（`McpSessionRegistry.kt:347-379`）。重连是否必要由连接参数决定，工具开关和 schema 变化不触发重连（`McpSessionRegistry.kt:465-486`）。

### 8.5 命名与调用

MCP 工具名格式为 `mcp__{serverName}__{toolName}`（`ChatToolFactory.kt:84-94`）。调用时把 `JsonObject` 参数透传给 `callTool`，请求超时 120 秒（`McpSessionRegistry.kt:139-167`）。返回值按内容类型转换：文本直接成为文本 part，图片解码后保存为本地文件并转为图片 part，其他内容编码为 JSON 文本（`McpManager.kt:118-133`）。

客户端不可用时返回文本错误结果，不抛异常（`McpManager.kt:123-125`），这与框架对普通工具错误的处理方式一致，都让错误作为工具输出回到模型。

### 8.6 Skill 工具

Skill 工具从助手启用的技能集合与磁盘上的技能列表求交集，交集为空则不注册（`SkillsTools.kt:18-20`）。执行时省略 `path` 参数读取 `SKILL.md` 的正文（去掉 frontmatter），提供 `path` 时解析为技能目录内相对路径，越界或不存在都会报错（`SkillsTools.kt:61-77`）。技能元数据来自 `SKILL.md` 的 frontmatter，必须有 `name` 和 `description` 才会被识别（`app/src/main/java/me/rerere/rikkahub/data/files/SkillManager.kt:189-205`）。

### 8.7 子 Agent

本次调查未在源码中找到子 Agent 或工具内再起生成循环的实现。工具的 `execute` 签名只接收参数并返回 parts，没有回调生成器的通道。旁路能力仅体现在 MCP 工具的“返回内容类型可扩展”和工作区 shell 的“命令内容不受控”两点上，这两者都仍在统一的注册、审批与回注路径内。

## 9. 设计取舍与已确认边界

### 9.1 已确认的实现取舍

工具协议极简，把参数校验完全下放给工具，框架不做统一 schema 校验。这让新增工具成本低，但也意味着各工具的错误风格不统一，有的抛异常有的返回错误 JSON。

工具目录每轮现算，不做缓存，牺牲少量重复计算换取配置变更立即生效。

结果内联在助手消息，不生成独立 TOOL 消息；这简化了消息树与分支逻辑，代价是协议序列化时需要重新分组。

审批判定放在编排层，`Denied` 和 `Answered` 由框架合成结果，只有真正执行的工具才进入实现。这让审批流程对所有工具统一，但也意味着“审批通过”不等于“执行端重新鉴权”，工具实现内部若还有权限检查需要自己处理（日历和屏幕时间工具就各自检查了系统权限）。

### 9.2 已确认的边界

截断依赖 `workspace_shell` 是否在工具集中，不按输出类型判断，因此没有工作区时超大输出不会被截断。

MCP 服务名有字符白名单，非法名会让整次生成失败，不会丢弃该服务器。

工作区 shell 默认需要审批，但该默认值可被工作区配置覆盖，覆盖后 shell 可以免审批执行。

`inputAsJson` 在解析失败时静默退化为空对象，模型收到的可能是一个参数为空的工具调用，不会收到解析错误。

### 9.3 文档与实现的不一致

`docs/references/chat-generation-pipeline.md` 第四阶段列出的注册顺序是搜索、本地、会话、工作区、Skill、MCP、记忆，而当前快照的实际顺序是记忆、搜索、本地、会话、工作区、Skill、MCP（`ChatToolFactory.kt:43-95`）。文档还把 Memory 描述为内置于 `GenerationHandler`，实际由 `ChatToolFactory` 构造。以源码为准。

## 10. 未验证事项

- Claude、Google 等非 OpenAI 兼容 provider 的工具序列化与工具结果解析未逐行核对，本笔记关于协议适配的结论仅对 OpenAI 兼容路径成立。
- 未运行构建、单元测试或真机验证；沙箱 shell 在真实 Android 设备上的 PRoot 行为、内核伪文件系统挂载效果属于需要在目标环境观察的维度。
- 未核对工作区工具中 `readImageInRootfs` 走 `getKoin().get<FilesManager>()` 这一服务定位器用法在非 UI 上下文中的可用性边界。
- 未核对 MCP OAuth 授权码流程的具体实现（`McpOAuthCoordinator`、`McpOAuthDiscoveryClient` 未逐行阅读）。
- 未确认“工具输出超过 32KB 且无 shell 工具”时是否存在其他兜底截断路径；本次只在 `GenerationLoop` 找到一处截断实现。
- 未核对各 provider 对工具结果中图片的支持差异，`toToolResultContent` 的模态降级只在 OpenAI 兼容实现中确认。
- 未确认 UI 侧工具卡片的渲染、折叠与错误展示细节，属于消息渲染器类目的调查范围。

## 11. 关键源码索引

- 工具协议定义：`ai/src/main/java/me/rerere/ai/core/Tool.kt:11-29`
- 审批状态与工具 part：`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt:11-43`、`UIMessagePart.kt:182-216`
- 工具总装入口：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt:38-108`
- 生成循环与审批判定：`app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt:74-325`
- 输出截断：`GenerationLoop.kt:536-568`
- systemPrompt 与记忆注入：`GenerationLoop.kt:346-371`、`GenerationPrompts.kt:9-26`
- 编排入口与审批恢复：`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt:578-654`、`ChatService.kt:658-805`
- 无效工具清理与中断结算：`ChatService.kt:809-884`
- OpenAI 协议序列化：`ai/src/main/java/me/rerere/ai/provider/providers/openai/ChatCompletionsAPI.kt:420-439`、`ChatCompletionsAPI.kt:475-536`、`ChatCompletionsAPI.kt:669-714`
- 消息分组：`ai/src/main/java/me/rerere/ai/provider/providers/ProviderMessageUtils.kt:26-58`
- 流式工具合并：`ai/src/main/java/me/rerere/ai/ui/StreamChunkHandler.kt:155-176`
- 本地工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/LocalTools.kt:31-56`
- 搜索工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/SearchTools.kt:20-126`
- 会话工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ConversationTools.kt:23-111`
- 工作区工具与审批默认值：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/WorkspaceTools.kt:26-52`、`WorkspaceTools.kt:203-270`、`WorkspaceTools.kt:399-420`
- 文本替换策略：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/TextReplacers.kt:26-30`
- Skill 工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/SkillsTools.kt:14-79`
- 记忆工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/MemoryTools.kt:20-101`
- MCP 入口与工具发现：`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpManager.kt:106-133`
- MCP 连接与重连：`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpSessionRegistry.kt:139-167`、`McpSessionRegistry.kt:202-271`、`McpSessionRegistry.kt:452-512`
- 工作区沙箱执行：`workspace/src/main/java/me/rerere/workspace/ProotShellRunner.kt:18-136`
- 工作区路径解析与配置：`workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt:121-146`、`WorkspaceManager.kt:245-258`
- 进程输出采集与上限：`workspace/src/main/java/me/rerere/workspace/WorkspaceShellRunner.kt:39-144`
