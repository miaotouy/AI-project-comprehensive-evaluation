# RikkaHub Agent 角色（Assistant 配置）调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：只读核对 Assistant 数据类、Preferences DataStore 的读写与迁移、GenerationLoop 的请求装配、提示词转换器、工具工厂、助手配置界面与导入逻辑；未运行应用，未修改被调查仓库源码
>
> 调查范围：Assistant 能配置什么、如何持久化与选中、与会话的绑定和切换影响、提示词与模型生成参数字段、导入导出与内置预设；工具执行、记忆机制、注入管线、工作区与渠道合并等机制只记录助手侧字段及其归属
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的角色实体是 **Assistant**：一个可序列化的数据类，承载人格提示词、模型生成参数、上下文上限、工具与记忆开关、正则替换、注入绑定与聊天页外观。它不是模板或模型包装，而是被整体存进全局设置的一份配置快照，由助手决定除 Provider 凭据之外几乎全部运行时行为。

配置存储位置是 Preferences DataStore 的单个 JSON 键，而不是 Room 表：所有助手构成一个列表，序列化后写入 `assistants`，当前选中的助手另用一个键保存其 UUID。Role 配置随设置备份整体迁移，没有独立的助手仓储层。

选中助手是全局单值，但会话绑定的是创建时的助手 id，两者可以暂时不一致：打开会话会把全局选中助手改写成该会话的助手，而每条消息在生成前又按会话的助手 id 重新读取配置。因此“切换助手”几乎不影响既有会话的下一回合，真正改变会话归属的是显式的会话迁移操作。

助手的能力开关只决定是否把对应工具或上下文段纳入本次请求；工具执行、检索与记忆机制、注入管线、工作区与渠道凭据由相邻类目笔记记录，本笔记保留这些开关的字段、取值与助手侧失效边界。历史消息只保存模型 id 与生成时的模型响应，不保存助手配置快照。

## 总体生效链路

1. 会话首次打开时会话初始化把全局选中助手改写为该会话的助手；发送消息时按会话 `assistantId` 取助手（取不到回退全局选中值），用户输入先过该助手的用户侧正则，模型按 `chatModelId` 解析并在为空时回退全局默认模型（`ChatService.kt:330-347`、`458-462`、`662-667`）。
2. 工具集按助手的能力开关组合成一份工具表，装配入口见 `ChatToolFactory.kt:38-95`；工具的发现、schema 注入与执行归 [Agent 工具调查笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。
3. 请求装配把助手的 systemPrompt（或被会话覆盖的版本）、记忆段与工具提示拼成首条合成 system 消息，再截断历史并套用输入转换器链，随后由助手字段决定采样参数、由输出转换器链处理回复；装配顺序与变换器链归 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)（`GenerationLoop.kt:346-402`）。

## 1. 角色数据模型与存储

### 1.1 字段分类

`Assistant` 定义在 `data/model/Assistant.kt:15-54`，全部字段都有默认值，用 kotlinx.serialization 序列化。按语义可分为八类：

| 分类 | 字段 | 默认值 / 边界 |
|---|---|---|
| 身份与展示 | `id`、`name`、`avatar`、`useAssistantAvatar`、`tags` | id 随机 UUID；avatar 为 Dummy/Emoji/Image；tags 是 Tag id 列表 |
| 人格提示词 | `systemPrompt`、`messageTemplate`、`presetMessages` | 空串、`{{ message }}`、空列表 |
| 显式覆盖开关 | `allowConversationSystemPrompt`、`allowConversationPromptInjection` | 均默认 false |
| 模型与采样 | `chatModelId`、`temperature`、`topP`、`maxTokens`、`reasoningLevel`、`streamOutput` | 模型 id 为 null 表示用全局默认；温度/topP/maxTokens 为 null 表示交给模型默认；推理等级默认 AUTO；流式默认 true |
| 上下文 | `contextMessageLimit` | 0 表示不限制，正数表示保留的消息条数 |
| 注入与扩展 | `modeInjectionIds`、`lorebookIds`、`enabledSkills`、`enableTimeReminder`、`timeReminderIntervalMinutes` | 空集合/空集合、true 的注入自动启用、间隔默认 60 分钟 |
| 工具与能力 | `localTools`、`enableWebSearch`、`mcpServers`、`workspaceId`、`enableMemory`、`useGlobalMemory`、`enableRecentChatsReference` | 本地工具默认只开 TimeInfo；其余默认关闭 |
| 请求与聊天外观 | `customHeaders`、`customBodies`、`quickMessageIds`、`background`、`backgroundOpacity`、`useGradientBackground`、`regexes` | 背景为空表示无背景；不透明度默认 1.0 |

`Avatar` 是密封类，只有 Dummy、Emoji 与 Image 三种形态（`data/model/Avatar.kt:5-15`）。`useAssistantAvatar` 决定聊天消息显示助手头像还是模型图标，名称回退逻辑在 `ChatService.kt:669-673`。

### 1.2 助手内嵌的类型

同一文件还定义了四类与助手强相关、但不属于 `Assistant` 字段的类型：

- `QuickMessage`：id、标题、内容；实际存储在全局设置里，助手只保存 id 集合（`Assistant.kt:57-61`）。
- `AssistantMemory`：内存对象，id 为整型、内容为文本；实际持久化在 Room，助手只持有开关（`Assistant.kt:64-67`）。
- `AssistantRegex`：查找正则、替换串、影响范围集合、是否仅视觉生效（`Assistant.kt:76-84`）。
- `PromptInjection` 密封类、`ModeInjection`/`RegexInjection` 子类与 `Lorebook`：助手只保存 id 绑定，规则对象本身与注入管线归 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)（`Assistant.kt:153-211`）。

`AssistantAffectScope` 枚举只有 USER 与 ASSISTANT 两个值，决定正则作用于用户输入还是助手输出（`Assistant.kt:70-73`）。

### 1.3 存储位置与读写

助手整体保存在 Preferences DataStore 的 `assistants` 键中，当前选中助手保存在 `select_assistant` 键中（`PreferencesStore.kt:109-110`）。写入时把整个助手列表 JSON 序列化，读取时反序列化并补默认值（`PreferencesStore.kt:190-191`、`258-264`）。

读取管线还做三步归一化：补齐缺失的内置助手（列表为空时整体替换），因此内置助手删除后下次读取会重新补回；助手列表与模式注入、Lorebook、快捷消息列表按 id 去重；每个助手的相关 id 引用会过滤掉全局列表中不存在的悬空项（`PreferencesStore.kt:337-409`）。

设置更新统一走 `SettingsStore.update`，写入成功前先用内存中的 `settingsFlow` 覆盖，再落盘；针对单个助手的常用改动另有切换选中助手、改模型、改联网开关等便捷入口（`PreferencesStore.kt:419-430`、`432-515`）。

### 1.4 默认助手与内置预设

内置助手只有两个（`PreferencesStore.kt:730-756`）：

- `DEFAULT_ASSISTANT_ID`（`0950e2dc-9bd5-4801-afa3-aa887aa36b4e`）：名称与系统提示词均为空，是兜底助手；`Settings.assistantId` 的默认值也是它。
- 第二个助手（`3d47790c-c415-4b90-9388-751128adb0a0`）：名称同样为空，系统提示词是带占位变量的英文模板，声明自己是 `{{char}}`、基于 `{{model_name}}`。

`DEFAULT_ASSISTANTS_IDS` 由这两个 id 组成，界面据此禁止删除内置助手（`AssistantPage.kt:536`）。模式注入的默认值只有一条 Learning Mode，插入位置在系统提示词之后（`PreferencesStore.kt:775-782`）。`data/ai/prompts/` 还提供标题、建议、压缩、OCR、翻译五类默认提示词，它们是全局设置字段而非助手字段，只在后台生成时读取（`PreferencesStore.kt:250-257`）。

## 2. 创建、选择与会话绑定

### 2.1 选中助手的持久化

全局选中助手由 `Settings.assistantId` 表达，`getCurrentAssistant()` 按 id 查找，查不到时取列表第一个（`PreferencesStore.kt:687-689`）。切换入口是 `updateAssistant`，只写 `select_assistant` 单键，不触碰助手本体（`PreferencesStore.kt:432-436`）。

### 2.2 会话如何绑定助手

`Conversation.assistantId` 是必填字段，创建会话时写入，且会话还持有自己的会话级覆盖字段：`customSystemPrompt`、`modeInjectionIds`、`lorebookIds`、`workspaceCwd`、`folderId`（`data/model/Conversation.kt:16-35`）。发送消息时助手来源是会话而非全局选中值：按会话 `assistantId` 查助手并回退 `getCurrentAssistant()`，因此一个会话始终使用它自己绑定的助手配置（`ChatService.kt:460-461`、`664-665`）。存储上两者隔离：按助手查询、分页、搜索消息都可带 `assistantId` 过滤（`ConversationRepository.kt:55-77`）。

### 2.3 切换助手对进行中会话的影响

需要区分三种“切换”：

- 改全局选中助手（不进入某个会话）：只改 `select_assistant`，已创建的会话在下次发送时仍按自己的 `assistantId` 取配置。
- 打开一个会话：`initializeConversation` 会把全局选中助手改写为该会话的助手，因此“当前助手”会随最近打开的会话漂移（`ChatService.kt:333-335`）。
- 显式迁移会话：会话级操作改写 `assistantId`，同时清空 `folderId`，因为文件夹是助手内分组，跨助手后不可见（`ChatVM.kt:310-325`）。

由于每条消息在生成前才重新读取助手，修改助手配置会立即作用于该会话的下一次请求，属于“运行时引用”语义，没有版本化或冻结；正在运行的生成协程已在启动时取得助手与模型对象，本轮不受后续切换影响（`ChatService.kt:434-508`）。

### 2.4 复制与删除

复制助手会生成新 UUID、名称追加 ` (Clone)`，并把 Image 头像替换为 Dummy 以避免共用本地文件，背景原样保留（`AssistantVM.kt:70-84`）。删除助手会先删除其头像与背景文件，再移除助手记录，随后删除该助手的记忆与全部会话（`AssistantVM.kt:44-68`）。内置助手不显示删除入口（`AssistantPage.kt:536`）。

## 3. 提示词字段与覆盖开关

### 3.1 systemPrompt 与会话覆盖

systemPrompt 在请求装配时作为首条合成 system 消息加入（`GenerationLoop.kt:346-371`）。若 `allowConversationSystemPrompt` 为真且会话有非空 `customSystemPrompt`，则用会话版本整体替换助手版本，而不是拼接（`GenerationLoop.kt:348-356`）。

systemPrompt 的占位变量在发送前被替换；变量集合与写法规则见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。助手侧只确认界面以可点击标签列出这些变量（`AssistantPromptPage.kt:189-209`）。

### 3.2 messageTemplate

`messageTemplate` 默认 `{{ message }}`，是一条 Pebble 模板，逐条套用到非合成消息的文本部分（`TemplateTransformer.kt:21-56`）；渲染与缓存策略见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。助手侧要求模板必须包含 `{{ message }}`，缺失时界面高亮报错并提供一键重置（`AssistantPromptPage.kt:289-306`）。

### 3.3 presetMessages

`presetMessages` 是预设对话消息列表，每条有 role（仅 USER/ASSISTANT）和文本部分。新建会话时它们被写入会话的首批消息节点（`ChatService.kt:337-344`）。因此预设消息是“会话初始内容”，只影响新建会话，不是每次请求都注入的 system 文本。

### 3.4 提示词注入绑定

助手通过 `modeInjectionIds` 与 `lorebookIds` 绑定注入资源，前者按开关直接生效，后者按触发条件筛选。注入规则的匹配字段、位置枚举、优先级与插入点策略，均见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。助手侧只需记住绑定是 id 集合，悬空 id 在读取时被清理（见 1.3）。

### 3.5 会话级覆盖与优先级

两个布尔字段决定会话能否覆盖助手配置：

| 字段 | 作用 | 生效位置 |
|---|---|---|
| `allowConversationSystemPrompt` | 允许会话用 `customSystemPrompt` 整体替换助手系统提示词 | `GenerationLoop.kt:348-356` |
| `allowConversationPromptInjection` | 允许会话用自己的 mode/lorebook id 集合替换助手的绑定 | `PromptInjectionTransformer.kt:81-90` |

优先级可概括为：会话显式覆盖（在开关允许时）> 助手字段 > 全局设置默认。`allowConversationPromptInjection` 为假时，会话的注入 id 集合即使存在也不参与；Web 端在写入会话注入前会校验该开关，未开启则拒绝（`web/routes/ConversationRoutes.kt:210-214`）。

## 4. 模型、Provider 与生成参数

助手绑定的模型是 `chatModelId`，为 null 时回退全局 `chatModelId`（`PreferencesStore.kt:683-685`）；助手只保存模型 UUID，凭据与 baseUrl 归 Provider 所有，Provider 的导入、合并与去重见 [LLM 渠道管理调查笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

采样参数直接进入 `TextGenerationParams`（`GenerationLoop.kt:386-402`）：temperature、topP、maxTokens、reasoningLevel 均取自助手，`customHeaders` 与 `customBody` 分别是助手自定义项在前、模型自定义项在后的合并列表，因此覆盖顺序是助手 > 模型 > 协议默认。`streamOutput` 决定走流式还是整段返回（`GenerationLoop.kt:404-469`），`reasoningLevel` 默认 AUTO，界面用专门的按钮调整（`AssistantBasicPage.kt:473-485`）。

温度与 topP 的取舍设计是“null 即不发送”：为 null 时不会出现在请求参数里，界面用开关表达启用与否；温度允许 0–2，topP 允许 0–1，越界被拒绝而不是截断（`AssistantBasicPage.kt:278-317`）。`customHeaders` 与 `customBodies` 的编辑界面在请求页，与模型的同名字段合并后发送（`AssistantRequestPage.kt:79-101`）。

## 5. 工具、记忆与能力开关（助手侧字段）

### 5.1 开关字段与消费结论

各能力都由助手上的一个字段开关控制，为假（或空集合）时对应工具或上下文段不出现；下表只给助手侧结论，机制细节按“归属”列：

| 能力 | 助手字段与取值 | 助手侧结论 | 机制归属 |
|---|---|---|---|
| 记忆 | `enableMemory`（默认 false）、`useGlobalMemory` | 开启后注入记忆段并获得记忆读写工具，作用域分助手隔离与全局共享 | [检索增强与认知编排](../检索增强与认知编排/RikkaHub-检索增强与认知编排调查笔记.md) |
| 外部搜索 | `enableWebSearch`（默认 false） | 仅当模型自身未内置搜索能力时才注入外部搜索工具 | [Agent 工具](../Agent工具/RikkaHub-Agent工具调查笔记.md) |
| 本地工具 | `localTools`（默认只含 TimeInfo） | 按枚举展开为若干本地工具，屏幕时间与日历需系统权限 | [Agent 工具](../Agent工具/RikkaHub-Agent工具调查笔记.md) |
| 最近会话引用 | `enableRecentChatsReference`（默认 false） | 注入读取当前助手其他会话的工具 | [Agent 工具](../Agent工具/RikkaHub-Agent工具调查笔记.md) |
| 工作区 | `workspaceId`（可空） | 仅工作区 shell 就绪时注入工作区工具，目录来自会话的 `workspaceCwd` | [外部执行体与应用协作](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md) |
| Skill | `enabledSkills`（名称集合，可空） | 与磁盘扫描到的 Skill 元数据求交集后创建工具 | Agent 工具 |
| MCP | `mcpServers`（服务器 id 集合，可空） | 逐服务器、逐工具过滤 enabled 后加入，工具名带固定前缀 | Agent 工具 |
| 时间提醒 | `enableTimeReminder`、`timeReminderIntervalMinutes`（默认 60） | 距上一条消息达到间隔时注入一条时间提醒 | [上下文编译与提示词工程](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md) |

工具集按固定顺序追加：记忆、外部搜索、本地工具、最近会话引用、工作区、Skill、MCP（`ChatToolFactory.kt:38-95`）。本地工具的可选枚举有 JavaScript 引擎、时间信息、剪贴板、TTS、AskUser、屏幕时间、日历，其中日历展开成两个工具，需权限的两项由界面负责申请（`data/ai/tools/local/LocalToolOption.kt:7-34`）。模型不支持工具而助手又开了搜索或存在 MCP 工具时，会追加一条“工具不可用”的错误提示（`ChatService.kt:682-690`）。

### 5.2 MCP 过滤读取的是全局选中助手

MCP 服务器 id 存在助手字段 `mcpServers` 中，但实际可用工具的筛选读取的是 `getCurrentAssistant()`，只取服务器自身 enabled 且 id 属于当前全局选中助手的服务器（`McpManager.kt:106-116`）。这与生成链路按会话绑定助手取配置的来源不一致（见 2.2），因此在“打开 A 会话、全局选中仍为 B”的间隙里，MCP 工具可用性可能与该会话实际使用的助手错位。

### 5.3 子 Agent

本快照未找到“子 Agent”这一独立概念：助手之间没有委派或嵌套关系，任务编排止于单轮工具循环。完整论证与搜索范围归 [Agent 工具调查笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)（`GenerationLoop.kt:74-96` 的循环上限为 256 步）。

### 5.4 正则替换

`regexes` 是助手级正则列表，可拖拽排序（`AssistantPromptPage.kt:525-561`）。正则按 `affectingScope` 决定作用于用户输入还是助手输出，按 `visualOnly` 决定只影响界面显示还是同时影响发送内容（`Assistant.kt:106-123`、`86-97`）。输入与输出分别由输入、输出转换器链应用（`ChatService.kt:510-526`、`RegexOutputTransformer.kt:11-38`），时序见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。

## 6. 资产、变量、开场白与用户档案

- 头像与背景：`Avatar.Image` 保存本地或网络 URL，`Avatar.Emoji` 保存 emoji 文本；`background` 与 `backgroundOpacity` 控制聊天页背景，`useGradientBackground` 打开后改用动态渐变并忽略背景图，更新助手时旧头像与背景文件会被删除（`AssistantDetailVM.kt:207-227`）。用户头像与昵称属于全局 `DisplaySetting`，不在助手内，systemPrompt 的 `user`/`nickname` 占位变量即读取该昵称（`PreferencesStore.kt:599-637`）。
- 开场白：本快照未找到独立的开场白字段，SillyTavern 导入会把 `first_mes` 转成一条 assistant 角色的 `presetMessages`（`AssistantImporter.kt:186-192`），可视为开场白的事实载体。
- 快捷消息与环境变量：快捷消息以 `quickMessageIds` 引用全局 `quickMessages`，读取时按 id 求交集（`PreferencesStore.kt:695-696`）；占位变量是静态枚举加系统读取，没有用户可定义的键值环境变量表。

## 7. 导入、导出、迁移与兼容性

### 7.1 无助手导出

在 `ui/pages/assistant/` 与备份代码中未找到导出单个助手或分享助手的入口，助手也没有独立的导出格式；配置转移只能通过整体设置备份完成，备份包中的 `settings.json` 是完整 `Settings` 序列化结果，包含全部助手并在恢复时整体写回（`BackupManager.kt:37-46`、`75-139`）。会话导出（Markdown/图片分享）导出的只是会话消息（`ui/pages/chat/Export.kt:241-378`）。

### 7.2 SillyTavern 角色卡导入

导入支持 JSON 与 PNG（PNG 内嵌 base64 元数据），识别 `chara_card_v2` 与 `chara_card_v3` 两种规范（`AssistantImporter.kt:151-247`）。映射规则：

| 源字段 | 目标 |
|---|---|
| `name` | 助手名称 |
| `first_mes` | 一条 assistant 角色的 presetMessage |
| `system_prompt` + `description` + `personality` + `scenario` | 拼接进 systemPrompt |
| PNG 图片 | 助手背景 |

导入的提示词前会加上 `You are roleplaying as <name>.` 与各段小标题（`AssistantImporter.kt:169-191`）；未映射的字段不会保留，世界书需另行在提示词注入里手工重建。

### 7.3 Chatbox 会话导入

Chatbox 备份导入的是会话：所有会话挂到当前选中助手下，并按会话级 system 提示词的存在与否置位目标助手的 `allowConversationSystemPrompt`（`BackupVM.kt:111-152`）。随包导入的 Provider 合并与去重见 [LLM 渠道管理调查笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

### 7.4 数据版本迁移

数据版本号写在 `data_version` 键中，当前迁移链到 V3（`PreferencesStore.kt:76-78`）：

- V2 迁移修正 `presetMessages` 中消息部分的类型字面量，把旧的类名式类型统一成小写短名（`PreferenceStoreV2Migration.kt:66-126`）。
- V3 迁移把助手内联的 `quickMessages` 提升为全局快捷消息：为每条旧消息补新 UUID，收集到全局列表，助手侧改存 id 集合（`PreferenceStoreV3Migration.kt:55-108`）。

`SettingsJsonMigrator` 在备份恢复时也会跑一次同样的迁移，并用迁移后的结果回写备份中的设置文件（`BackupManager.kt:126-132`）。

## 8. 配置界面与可见字段

助手详情页把配置拆成基础、提示词、扩展、记忆、请求、MCP、本地工具七个子页，各页字段与 1.1 的分类一一对应（`AssistantDetailPage.kt:92-145`）：基础页放身份字段、工作区、模型与采样参数、上下文上限和外观，提示词页另有可点击的变量标签与 messageTemplate 实时预览，扩展页把快捷消息、模式注入、Lorebook、Skill 分成四页。聊天页的两个助手侧只读状态是联网开关与当前模型，都从全局选中助手推导，会话级覆盖入口受助手开关控制（`ChatVM.kt:113-121`、`ChatList.kt:372`）。助手列表页提供搜索、标签过滤、拖拽排序、复制与删除，排序结果写回 `settings.assistants` 顺序（`AssistantPage.kt:103-235`）。

## 9. 设计取舍与已确认边界

- 助手是纯数据对象：没有类方法，行为全部由外部服务读取字段后执行；配置以整体 JSON 存储而非关系表，使字段演进只需迁移函数，代价是每次读取都要做一遍去重与引用清理。
- “null 表示不设值”的约定让界面可以区分“启用并填写”与“交给模型默认”，避免把禁用状态伪装成具体数值。
- 助手与会话是弱引用关系：会话保存 id，不保存配置快照，因此修改助手会追溯影响历史会话的下一次请求，历史消息本身不受影响。
- 全局选中助手与会话绑定助手会互相影响：打开会话会改写全局选中值，而 MCP 工具可用性读取全局选中值，两者在“打开 A 会话但全局选中仍为 B”的间隙里可能不一致。
- 内置助手读时补齐，删除不是持久性的，`DEFAULT_ASSISTANTS_IDS` 同时被界面用于隐藏删除入口。

## 10. 未验证事项

- 未运行应用，以上关于请求装配顺序与正则生效范围的结论均来自代码路径，未在真实 Provider 上验证请求体形态。
- 聊天页背景、渐变、不透明度与气泡等外观字段的视觉效果未在设备上观察，只确认了字段绑定与取值范围。
- SillyTavern 的 PNG 元数据解析依赖 `ImageUtils.getTavernCharacterMeta`，容错边界未展开；Chatbox 导入的 fork 分支与图片落盘完整度只核对了计数器与调用点，未用真实备份验证。
- `contextMessageLimit` 的阶梯式截断算法在 `ai` 模块的 `limitContext` 中，本次仅确认调用点（`GenerationLoop.kt:372`）；时间提醒的间隔比较是否跨分支节点同样未验证。
- 助手各能力开关只核对了字段默认值与消费入口，未在设备上逐项开启并观察工具表与上下文段是否如实变化。

## 11. 关键源码索引

- `data/model/Assistant.kt:15-211`：Assistant 数据类、字段默认值、AssistantRegex 与影响范围枚举；注入位置枚举、PromptInjection 与 Lorebook。
- `data/model/Conversation.kt:16-36`：会话字段与助手绑定。
- `data/datastore/PreferencesStore.kt:109-110、190-191、258-264`：助手与选中助手的 DataStore 读写。
- `data/datastore/PreferencesStore.kt:337-409、432-515`：内置补齐、去重与悬空引用清理，以及单个助手的更新入口。
- `data/datastore/PreferencesStore.kt:683-696、730-782`：当前助手/当前模型/快捷消息解析与内置助手。
- `data/datastore/migration/PreferenceStoreV2Migration.kt`、`PreferenceStoreV3Migration.kt`：助手数据迁移。
- `service/ChatService.kt:330-347、458-462、658-747`：会话初始化、按会话取助手、解析模型与组装工具。
- `data/ai/GenerationLoop.kt:327-473`：system 消息装配、上下文截断与采样参数。
- `data/ai/tools/ChatToolFactory.kt:21-108`：助手开关到工具集的映射。
- `data/ai/mcp/McpManager.kt:106-116`：MCP 工具按当前选中助手过滤。
- `ui/pages/assistant/AssistantVM.kt:33-91`：助手增删、复制与记忆读取。
- `ui/pages/assistant/detail/AssistantImporter.kt:151-291`：SillyTavern 角色卡导入。
- `ui/pages/assistant/detail/AssistantPromptPage.kt:143-578`：提示词、模板、预设消息与正则界面。
- `ui/pages/chat/ChatVM.kt:113-121、310-325`：聊天页助手状态与会话迁移。
