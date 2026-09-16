# RikkaHub 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9a35e3f2f1e2820e95c37deb82ef8f5e1592e06f`（分支：`master`）
>
> 调查方式：只读复核仓库源码与单元测试，按 `docs/references/chat-generation-pipeline.md` 给出的管道顺序逐项对照可执行路径；规则对象的读取、绑定与消费点以 `data/datastore`、`data/model`、`data/ai/transformers`、`service/ChatService.kt`、`data/ai/GenerationLoop.kt` 为准，未运行 App
>
> 调查范围：覆盖助手与对话两个层级的可编辑规则（ModeInjection、Lorebook）、注入作用域与编译顺序、Pebble 模板与占位符展开、助手正则的请求层与显示层分流、Workspace 与时间提醒注入、以及输入/输出两类转换器在三个时机上的调用。明确排除：Provider payload 构造与传输、流式 chunk 合并与重试、会话与消息的存储 schema/迁移、检索与工具执行内部语义
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的上下文编译集中在一次模型调用前的一次性消息变换上：每条请求先在本轮消息列表前拼出一条内部 SYSTEM 消息（助手系统提示 + 记忆 + 各工具说明），再按固定顺序跑七个输入转换器，然后把结果交给 Provider；本轮会话历史与这条 SYSTEM 消息都只在请求期间存在，注入结果不写回会话（`data/ai/GenerationLoop.kt:346-383`）。

可编辑规则有两类载体。ModeInjection 是全局定义、按 ID 绑定到助手或对话的常驻块；Lorebook 是全局定义、按 ID 绑定的条目集合，条目按关键词或正则对最近若干条非 SYSTEM 消息做匹配后才注入。两者的注入位置共用同一套枚举，共五种作用域，其中三种以独立消息插入并自带角色（`data/model/Assistant.kt:128-199`）。

规则对象没有独立的编译阶段，也没有优先级之外的冲突仲裁：所有命中项放在一起按 priority 降序稳定排序，再按位置和深度分组，同组内容用换行拼接进同一条消息（`PromptInjectionTransformer.kt:60-66`、`231-243`）。

Pebble 模板与占位符是两套并行的展开机制，且处理对象不同：`{{key}}` 形式的占位符对所有消息（含合成消息）生效，Pebble 的 `{{ message }}`/`{{ role }}`/`{{ time }}`/`{{ date }}` 只作用于非合成消息，因此不作用于系统提示与前四种注入块（`PlaceholderTransformer.kt:153-158`、`TemplateTransformer.kt:27-28`）。

助手正则按 `visualOnly` 分成互斥的两组：非 visualOnly 的在生成结束时作用于助手消息并写回会话，visualOnly 的只在 UI 渲染时替换文本，两条路径都不会改变模型输入（`data/model/Assistant.kt:99-123`、`RegexOutputTransformer.kt:10-38`、`ui/components/message/ChatMessage.kt:376-409`）。

## 系统边界与规则编译主链

本笔记只记录规则对象从配置到请求、权威消息或显示结果的链路。消息 schema 与持久化留在会话与消息管理；Markdown/DOM 渲染留在消息渲染器；Provider 调用、重试与流式消费留在对话请求与上下文。

```
ChatService.sendMessage / sendQueuedMessage
  -> preprocessUserInputParts：助手正则 USER 组，改写待入库的用户消息
  -> handleMessageComplete -> GenerationLoop.generateText（每轮最多 256 个 step）
       -> generateInternal
            system = 助手/对话系统提示 + 记忆块 + 各工具 systemPrompt
            internalMessages = [system] + messages.limitContext(contextMessageLimit)
            internalMessages.fold(输入转换器)      // 七个，固定顺序
              TimeReminder -> PromptInjection -> Placeholder -> DocumentAsPrompt
              -> Ocr -> Template -> WorkspaceReminder
            -> providerImpl.streamText / generateText
       -> 流式期间：输出转换器.transform（真实）与 .visualTransform（展示）
       -> 生成结束：visualTransform 结果写回 messages + onGenerationFinish + 标记 finishedAt
       -> 有工具调用则执行并追加结果，回到下一个 step
```

转换器按接口分成两类，调用时机也随之不同：`InputMessageTransformer` 只覆盖 `transform`，在每次模型调用前对完整消息列表生效；`OutputMessageTransformer` 在 `transform` 之外还提供 `visualTransform` 与 `onGenerationFinish`，后两者在调度时会检查接口类型，输入类转换器不会被调用（`Transformer.kt:38-62`、`90-105`、`107-122`）。三个时机的分工是：`transforms` 为真实变换，`visualTransform` 面向流式展示，`onGenerationFinish` 在生成完全结束后做收尾。

七个输入转换器的实际顺序由 `ChatService` 组装：文件级列表先放五个固定项，再追加模板与工作区两个有状态实例（`service/ChatService.kt:134-150`、`741-745`）。因此项目文档把顺序写成 TimeReminder 起、WorkspaceReminder 止与代码一致，但两处命名和描述与当前快照有出入：文档称核心生成类为 `GenerationHandler`，实际类名是 `GenerationLoop`；文档说时间提醒注入到系统消息，实际注入的是一条独立的 USER 消息（`TimeReminderTransformer.kt:61-73`）。

## 1. 规则对象、权威源与作用域

规则定义保存在应用级 Settings，绑定关系保存在助手或对话上，二者都是可序列化模型。

| 对象 | 权威源与字段 | 绑定关系 | 启停 |
|---|---|---|---|
| ModeInjection | `Settings.modeInjections` | 助手 `modeInjectionIds`，或对话 `modeInjectionIds` | 自身 `enabled` |
| Lorebook | `Settings.lorebooks`，内含 `entries` | 助手 `lorebookIds`，或对话 `lorebookIds` | Lorebook 与条目各自的 `enabled` |

两个全局列表经 DataStore Preferences 以 JSON 字符串整体存取，键名分别是 `mode_injections` 与 `lorebooks`；读取时按 ID 去重，并在加载后清掉助手侧指向已不存在对象的绑定，避免悬空引用（`data/datastore/PreferencesStore.kt:299-304`、`355-410`）。系统预置一条学习模式 ModeInjection（`PreferencesStore.kt:775-782`、`data/ai/prompts/LearningMode.kt`），其内容来自常量而非用户输入。

注入位置的五个作用域定义在 `InjectionPosition`：BEFORE_SYSTEM_PROMPT 与 AFTER_SYSTEM_PROMPT 并入第一条 SYSTEM 消息；TOP_OF_CHAT、BOTTOM_OF_CHAT 与 AT_DEPTH 生成独立消息，此时才使用注入自带的 `role`（`Assistant.kt:128-144`；`ui/pages/extensions/PromptPage.kt:538-545` 按此决定是否显示角色选择器）。

ModeInjection 与 RegexInjection 共享同一组字段：名称、启用、优先级、位置、内容、`injectDepth`、角色。Lorebook 条目额外有 `keywords`、`useRegex`、`caseSensitive`、`scanDepth`、`constantActive`（`Assistant.kt:152-211`）。

导入导出以单对象 JSON 为单位，外层是 `{version, type, data}`。ModeInjection 的类型标记是 `mode_injection`，Lorebook 是 `lorebook`；导入时统一重新生成 ID，Lorebook 还会为每个条目换新 ID，并且可以识别 SillyTavern 世界书格式并把 position、order、disable、scanDepth 等字段映射过来（`data/export/ExportSerializer.kt:65-186`）。编辑入口是全局提示词页的两个分页，支持拖拽排序、逐个启用开关与导入导出（`PromptPage.kt:107-165`）；绑定入口是助手扩展页和对话内的扩展选择器（`ui/pages/assistant/detail/AssistantExtensionsPage.kt:140-173`、`ui/components/ui/ExtensionSelector.kt:59-70`）。

## 2. 选择条件、优先级与编译顺序

**作用域选择**：生效 ID 集合在助手与对话之间二选一，而不是并集。助手的 `allowConversationPromptInjection` 打开且当前存在对话时，只用对话的绑定集合；否则用助手的绑定集合（`PromptInjectionTransformer.kt:81-90`）。这条规则对 ModeInjection 和 Lorebook 同时生效，单元测试专门覆盖了"助手绑定在对话模式下被忽略"的行为（`app/src/test/.../PromptInjectionTransformerTest.kt:220-250`）。对话侧的绑定在写入前会校验 ID 存在于全局定义，并在助手未开启该开关时直接拒绝（`web/routes/ConversationRoutes.kt:464-485`、`494-507`）。

**ModeInjection 命中条件**：自身 enabled 且 ID 在生效集合中，无其他条件（`PromptInjectionTransformer.kt:93-95`）。

**Lorebook 条目命中条件**：条目 enabled；`constantActive` 为真时无条件命中；关键字为空则永不命中；否则任一关键字命中即可。关键字支持正则或纯文本包含，大小写敏感可配，正则编译失败按未命中处理（`Assistant.kt:219-240`）。

**扫描上下文**：按条目自己的 `scanDepth` 取最近 N 条消息拼成文本，取的是消息的全部文本部件；参与匹配的消息先过滤掉 SYSTEM 角色（`PromptInjectionTransformer.kt:103-112`、`Assistant.kt:249-256`）。因为时间提醒转换器排在本转换器之前，扫描文本里可能已含有它插入的 `<time_reminder>` 块——这是按管道顺序推断，未做运行验证。

**排序与合并**：全部命中项先按 priority 降序做稳定排序，再按位置分组；同位置内容按此顺序用换行拼接，因此同优先级时保持收集顺序（先 ModeInjection 的定义顺序，再各 Lorebook 的条目顺序）（`PromptInjectionTransformer.kt:60-66`）。AT_DEPTH 额外按 `injectDepth` 分组，并按深度从大到小处理，避免插入导致索引漂移；同深度内容合并为一条消息（`PromptInjectionTransformer.kt:208-222`）。

**插入位置**：两种系统提示作用域替换第一条 SYSTEM 消息的文本部件（把原有文本部件合并成一个）；不存在 SYSTEM 消息时新建一条插到最前。TOP_OF_CHAT 取第一条 USER 之前，BOTTOM_OF_CHAT 取最后一条消息之前，AT_DEPTH 取倒数第 depth 条之前，三者都经过一次"安全位置回退"——若目标位置正好落在 USER 与其后带工具调用的 ASSISTANT 之间，就向前移一位（`PromptInjectionTransformer.kt:121-225`、`251-272`）。

## 3. 请求层编译与模型可见结果

进入请求的消息列表是本轮临时构造的：系统提示、记忆块与工具说明先合成一条 SYSTEM 消息，历史消息经 `limitContext` 做阶梯式裁剪后接在其后，然后整体过输入转换器（`GenerationLoop.kt:346-383`、`ai/src/main/java/me/rerere/ai/ui/Message.kt:149-162`）。作用域选择中的对话 ID 集合经 `generateText` 与 `transforms` 一路传入转换上下文（`GenerationLoop.kt:113-119`、`ChatService.kt:733-735`）。每个 step 都会重新构造一次，因此注入内容既不会累积，也不会进入下一步的输入基线。

系统提示的来源由助手开关决定：允许对话覆盖且对话系统提示非空时用对话的，否则用助手的；记忆块仅在助手开启记忆时追加，内容是一条 JSON 数组；工具说明按工具顺序逐条追加（`GenerationLoop.kt:347-368`、`data/ai/GenerationPrompts.kt:9-26`）。

**占位符**展开覆盖所有文本部件，不分角色，也不排除合成消息，因此系统提示与注入块里的占位符同样会被替换。可用键为 cur_date、model_id、model_name、locale、timezone、system_version、device_info、battery_level、nickname、char、user，值分别取系统日期、模型标识与显示名、系统语言、时区、Android 版本、设备厂商型号、电池电量，以及用户昵称，其中昵称/角色名留空时回退为 user/assistant。替换同时接受 `{{key}}` 和 `{key}` 两种写法且忽略大小写（`PlaceholderTransformer.kt:59-115`、`140-161`）。`{{ key }}` 这种带空格的写法不在替换范围内，它与 Pebble 语法并不冲突。

**模板**用 Pebble 逐条渲染消息的每一个文本部件，可用变量是 `message`、`role`（角色名小写）、`time`、`date`。模板正文取助手 `messageTemplate`，由自定义 Loader 按助手 ID 从 Settings 读取，引擎关闭了自动转义；变量时间取消息自身的 `createdAt` 而非当前时间，以便同一历史在多轮请求中渲染稳定、不破坏提示词缓存。`isSynthetic` 为真的消息直接跳过（`TemplateTransformer.kt:17-56`、`58-86`、`di/DataSourceModule.kt:52-64`）。由于系统消息在构造时就被标记为合成消息，模板实际只作用于会话历史（含对话创建时写入的预设消息），不作用于系统提示与注入块。

**文档与 OCR**：文档部件被换成 `<UploadFile name=... path=...>` 文本并插到该消息部件列表最前；图片 OCR 只在模型不具备图像输入能力且存在本地 file 图片时触发，把图片部件替换成 `<image_file_ocr>` 文本，结果按 URL 缓存三天，缓存文件在应用缓存目录（`DocumentAsPromptTransformer.kt:15-44`、`OcrTransformer.kt:47-80`、`109-122`）。两者都在占位符与模板之前/之后有固定相对位置，因此它们插入的文本不会再被占位符替换，但会被随后的模板渲染——这是按管道顺序推断，未做运行验证。

**工作区提醒**：仅当助手绑定了工作区且该工作区的 shell 状态为 READY 时生效；它把 `<workspace>` 说明块追到第一条 SYSTEM 消息末尾（没有则新建系统消息），随后读取 /root/.agents/AGENTS.md、/workspace/AGENTS.md 与会话当前目录下的 AGENTS.md，逐个限制在 64KB 内，再包进 `<workspace_instructions>` 追加（`WorkspaceReminderTransformer.kt:21-47`、`49-92`）。它排在模板之后，所以这段内容既不做占位符替换也不做模板渲染。

## 4. 消息生命周期变换与交接

跨请求层与权威消息层的只有助手正则。用户消息在入库前先跑一遍 `AssistantAffectScope.USER` 作用域、非 visualOnly 的正则，因此写进会话的用户文本是替换后的结果；发送队列路径与编辑消息路径共用同一处理函数（`ChatService.kt:510-526`、`462`、`1241`）。助手输出侧的正则不在模型调用前运行，而是在生成收尾时由输出转换器处理。

三处正则处理点的分工可以按"是否写回会话"区分：

- 用户输入、visualOnly 关闭：改写用户消息并持久化，见 `preprocessUserInputParts`。
- 助手输出、visualOnly 关闭：在生成结束时替换助手消息的文本与推理部件，替换结果作为 `messages` 参与 emit，最终经会话更新写回，见 `RegexOutputTransformer.visualTransform`（`RegexOutputTransformer.kt:10-38`、`GenerationLoop.kt:146-152`、`ChatService.kt:767-783`）。
- 任意角色、visualOnly 打开：只在 UI 渲染时替换，不进入请求也不写回（见下节）。

生成结束的收尾顺序固定为：visualTransform、onGenerationFinish、写入 finishedAt、emit（`GenerationLoop.kt:146-164`）。因此 base64 图片落盘与 think 标签拆分都发生在权威消息落地之前。

## 5. 显示层投影与消息渲染器交接

`visualOnly` 为正则的显隐开关：`replaceRegexes` 只在 `regex.visualOnly == visual` 时应用，因此显示层（`visual=true`）只跑 visualOnly 为真的正则，管道层（`visual=false`）只跑 visualOnly 为假的正则，两组互斥、不会重复替换（`Assistant.kt:99-123`）。

显示层调用点有三处：助手气泡文本、用户气泡文本、推理内容，都按消息自身角色选择 USER 或 ASSISTANT 作用域后替换，再交给 Markdown 渲染（`ui/components/message/ChatMessage.kt:376-409`、`ui/components/message/ChatMessageReasoning.kt:172-176`）。同一份正则配置在请求层与显示层有不同去向，不能因为共用对象就推断显示替换会进入模型输入。

输出转换器的流式表现单独说明：流式 chunk 到达时先跑一次真实 `transform`（当前三个输出转换器都未覆盖该方法，实际是空操作），再把 `visualTransform` 的结果 emit 给 UI 展示，展示副本不回写；生成结束时 `visualTransform` 的结果则被赋回消息列表并 emit，因而会落进会话（`GenerationLoop.kt:112-131`、`146-164`）。项目文档"visualTransforms 不影响实际存储"的说法只适用于流式阶段。

## 6. 调试、预览与可解释性

本次未找到查看编译后系统提示、最终消息数组或注入命中明细的界面或日志入口。可观察的间接信号有：OCR 转换期间写入处理状态供界面展示（`OcrTransformer.kt:62`、`77`），消息模型自带 token 用量字段，以及设置里保存了 `developerMode` 标志——本次在应用模块内未找到该标志的消费点，web-ui 侧也只有类型声明（`data/datastore/PreferencesStore.kt:86`、`525`）。

模板有就地预览：助手提示词页用同一 `TemplateTransformer` 对两条示例消息求值并把结果交给消息组件渲染；失败时以错误态展示异常信息（`ui/pages/assistant/detail/AssistantPromptPage.kt:357-402`）。这是编辑器预览，与真实请求携带的内容不是同一证据。

规则配置界面能表达的信息有限：ModeInjection 卡片展示位置、优先级与禁用标记，Lorebook 卡片展示条目数与禁用标记；两者都不展示本次是否命中，也不展示注入后的最终系统提示（`PromptPage.kt:300-391`、`711-806`）。

## 7. 失败、更新与已确认边界

助手正则有较完整的错误收口：编译结果（含失败）被缓存以避免流式期间反复编译，编译失败按空处理；替换字符串引用不存在的分组时捕获异常并返回原字符串，不会中断生成（`Assistant.kt:86-123`）。Lorebook 的正则关键字编译失败按未命中处理（`Assistant.kt:225-231`）。

输入转换器管道本身没有逐项隔离：`transforms` 用 fold 串行执行，链路上没有针对单个转换器的 try/catch，异常会向上冒泡到生成任务的失败处理并转成用户可见错误（`Transformer.kt:85-87`、`GenerationLoop.kt:373-383`）。这意味着占位符或模板展开失败与正则失败的收口策略不同。

已确认的边界：注入只存在于请求期间，不写回会话，也不进入下一步的输入基线；对话级绑定是替换而非叠加助手绑定；系统提示作用域的第一条 SYSTEM 消息文本部件会被合并为一个文本部件，原有非文本部件不会保留；合成消息标记是 `@Transient`，不参与序列化（`ai/src/main/java/me/rerere/ai/ui/Message.kt:28-30`、`PromptInjectionTransformer.kt:137-158`）。

规则定义的版本化只有导入导出外层的 `version` 字段，当前恒为 1，未见按版本迁移规则对象的逻辑（`ExportSerializer.kt:18-23`）。设置变更会清空 Pebble 模板缓存，保证模板改动能立刻生效（`PreferencesStore.kt:411-413`）。

## 8. 未验证事项

- 规则命中与注入结果的运行验证：多作用域同时命中时的实际消息顺序、`findSafeInsertIndex` 在多条注入连续插入时的整体效果，均只在单元测试覆盖的样例上确认。
- 时间提醒插入的 `<time_reminder>` 是否真的会被 Lorebook 的扫描上下文命中（由管道顺序推断，未运行）。
- 文档/OCR 插入文本被 Pebble 模板渲染的实际后果（例如内容中恰好含 `{{ }}` 时的表现）。
- 模板求值失败在生成链路上的具体表现，与模板缓存失效时机的并发行为。
- `contextMessageLimit` 阶梯裁剪与注入插入的交互：AT_DEPTH/TOP_OF_CHAT 的插入发生在裁剪之后，裁剪基准是否因此偏移未验证。
- 对话级绑定在两个平台（原生界面与 Web/内置 Web 服务的会话更新接口）上的写入一致性；Web 端只做了 ID 校验路径的源码阅读。
- 是否存在其他绕过 `preprocessUserInputParts` 的用户消息写入路径（例如导入、同步、语音），本次只确认了发送队列与编辑两条。

## 9. 关键源码索引

- `app/src/main/java/me/rerere/rikkahub/data/ai/transformers/Transformer.kt`：`MessageTransformer` 接口与 `InputMessageTransformer`/`OutputMessageTransformer` 两类（22-36）、三个扩展函数（64-88、90-105、107-122）。
- `app/src/main/java/me/rerere/rikkahub/data/ai/transformers/PromptInjectionTransformer.kt`：收集与排序（38-67、72-116）、按位置应用（121-225）、同角色合并（231-243）、安全插入（251-272）。
- `app/src/main/java/me/rerere/rikkahub/data/model/Assistant.kt`：正则与 scope（70-123）、注入位置（128-144）、注入模型（152-199）、Lorebook（204-211）、触发与扫描（219-256）。
- `app/src/main/java/me/rerere/rikkahub/data/datastore/PreferencesStore.kt`：规则列表的读写与清理（299-304、355-410）、Settings 字段（519-574）、默认注入（775-782）。
- `app/src/main/java/me/rerere/rikkahub/service/ChatService.kt`：转换器装配（134-150、741-746）、用户输入正则（510-526）。
- `app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt`：系统提示构造与输入管道（346-383）、流式与收尾的三种变换（96-164）。
- `app/src/main/java/me/rerere/rikkahub/data/ai/transformers/TemplateTransformer.kt` 与 `PlaceholderTransformer.kt`：两套展开机制及其作用对象。
- `app/src/main/java/me/rerere/rikkahub/data/ai/transformers/WorkspaceReminderTransformer.kt`、`TimeReminderTransformer.kt`、`RegexOutputTransformer.kt`、`ThinkTagTransformer.kt`、`DocumentAsPromptTransformer.kt`、`OcrTransformer.kt`、`Base64ImageToLocalFileTransformer.kt`：其余转换器实现。
- `app/src/main/java/me/rerere/rikkahub/data/export/ExportSerializer.kt`：规则对象的导入导出与 SillyTavern 映射（65-186）。
- `app/src/main/java/me/rerere/rikkahub/ui/pages/extensions/PromptPage.kt`、`ui/components/ui/ExtensionSelector.kt`、`ui/pages/assistant/detail/AssistantPromptPage.kt`：编辑、绑定与模板预览界面。
- `app/src/test/java/me/rerere/rikkahub/data/ai/transformers/PromptInjectionTransformerTest.kt`：作用域、深度、优先级与扫描深度的行为样例。
- `app/src/main/java/me/rerere/rikkahub/web/routes/ConversationRoutes.kt`：Web 侧对话绑定的校验与写入（200-225、464-521）。
