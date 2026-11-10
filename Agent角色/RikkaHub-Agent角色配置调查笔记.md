# RikkaHub Agent 角色（Assistant 配置）调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：只读核对 Assistant 数据类、ConversationConfig、Preferences DataStore 的读写与迁移、ChatRequestFactory 的请求装配、提示词转换器、工具工厂、助手配置界面与导入逻辑；未运行应用，未修改被调查仓库源码
>
> 调查范围：Assistant 能配置什么、如何持久化与选中、与会话的绑定和切换影响、提示词与模型生成参数字段、导入导出与内置预设；工具执行、记忆机制、注入管线、工作区与渠道合并等机制只记录助手侧字段及其归属
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 的角色实体是 **Assistant**：一个可序列化的数据类，承载人格提示词、模型生成参数、上下文上限、工具与记忆开关、正则替换、注入绑定与聊天页外观，整体存入全局设置。

会话落库时从助手取得部分配置快照：模型、推理强度、两种搜索、MCP、工作区与技能存入 `ConversationConfig`，注入绑定另随会话保存。聊天页之后可继续修改这份会话配置，只影响当前会话；系统提示词、采样参数、本地工具、记忆与外观等其余字段仍在每轮读取助手当前值，助手修改会影响已有会话的后续请求。见 [会话覆盖与写回分流](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/model/ConversationConfig.kt#L41-L120)、[请求消费](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/ai/ChatRequestFactory.kt#L97-L119)。

配置存储位置是 Preferences DataStore 的单个 JSON 键，而不是 Room 表：所有助手构成一个列表，序列化后写入 `assistants`，当前选中的助手另用一个键保存其 UUID。Role 配置随设置备份整体迁移，没有独立的助手仓储层。

选中助手是全局单值，但会话绑定的是创建时的助手 id，两者可以暂时不一致：打开会话会把全局选中助手改写成该会话的助手，而每条消息在生成前又按会话的助手 id 重新读取配置。因此“切换助手”几乎不影响既有会话的下一回合，真正改变会话归属的是显式的会话迁移操作。

助手的能力开关只决定是否把对应工具或上下文段纳入本次请求；工具执行、检索与记忆机制、注入管线、工作区与渠道凭据由相邻类目笔记记录，本笔记保留这些开关的字段、取值与助手侧失效边界。历史消息只保存模型 id 与生成时的模型响应，不保存助手配置快照。

## 总体生效链路

1. 打开会话会同步全局选中助手；生成时按会话归属读取助手，再叠加会话固定字段。模型优先解析会话配置，未固定或固定模型已失效时回退助手/全局聊天模型；用户输入使用解析后助手的正则。见 [会话视角解析](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/model/ConversationConfig.kt#L94-L119)。
2. 工具集按助手的能力开关组合成一份工具表，装配入口见 `ChatToolFactory.kt`；工具的发现、schema 注入与执行归 [Agent 工具调查笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。
3. 请求装配把助手的 systemPrompt（或被会话覆盖的版本）、记忆段与工具提示拼成首条合成 system 消息，再截断历史并套用输入转换器链，随后由助手字段决定采样参数、由输出转换器链处理回复；装配在 `ChatRequestFactory` 中完成，循环本体是 `ai` 模块的 `AgentLoop`，装配顺序与变换器链归 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)（`data/ai/ChatRequestFactory.kt`）。

## 1. 角色数据模型与存储

### 1.1 字段分类

`Assistant` 定义在 `data/model/Assistant.kt`，全部字段都有默认值，用 kotlinx.serialization 序列化。按语义可分为八类：

| 分类 | 字段 | 默认值 / 边界 |
|---|---|---|
| 身份与展示 | `id`、`name`、`avatar`、`useAssistantAvatar`、`tags` | id 随机 UUID；avatar 为 Dummy/Emoji/Image；tags 是 Tag id 列表 |
| 人格提示词 | `systemPrompt`、`messageTemplate`、`presetMessages` | 空串、`{{ message }}`、空列表 |
| 系统提示覆盖开关 | `allowConversationSystemPrompt` | 默认 false；注入绑定随会话配置保存，无独立许可开关 |
| 模型与采样 | `chatModelId`、`temperature`、`topP`、`maxTokens`、`reasoningLevel`、`streamOutput` | 模型 id 为 null 表示用全局默认；温度/topP/maxTokens 为 null 表示交给模型默认；推理等级默认 AUTO；流式默认 true |
| 上下文 | `contextMessageLimit` | 0 表示不限制，正数表示保留的消息条数 |
| 注入与扩展 | `modeInjectionIds`、`lorebookIds`、`enabledSkills`、`enableTimeReminder`、`timeReminderIntervalMinutes` | 空集合/空集合、true 的注入自动启用、间隔默认 60 分钟 |
| 工具与能力 | `localTools`、`enableWebSearch`、`mcpServers`、`workspaceId`、`enableMemory`、`useGlobalMemory`、`enableRecentChatsReference` | 本地工具默认只开 TimeInfo；其余默认关闭 |
| 请求与聊天外观 | `customHeaders`、`customBodies`、`quickMessageIds`、`background`、`backgroundOpacity`、`useGradientBackground`、`regexes` | 背景为空表示无背景；不透明度默认 1.0 |

`Avatar` 是密封类，只有 Dummy、Emoji 与 Image 三种形态（`data/model/Avatar.kt`）。`useAssistantAvatar` 决定聊天消息显示助手头像还是模型图标，名称回退逻辑在 `ChatService.kt`。

### 1.2 助手内嵌的类型

同一文件还定义了三组与助手关联、但单独存储的类型：

| 类型 | 内容与存储 |
|---|---|
| `QuickMessage` | id、标题、内容三部分；实体存在全局设置里，助手只保存 id 集合 |
| `AssistantRegex` | 查找正则、替换串、影响范围集合与仅视觉开关 |
| `PromptInjection` 密封类（含 `ModeInjection`、`RegexInjection` 子类）与 `Lorebook` | 助手只保存 id 绑定；规则对象与注入管线见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md) |

三组类型与 `Assistant` 同处 `Assistant.kt`。

`AssistantAffectScope` 枚举只有 USER 与 ASSISTANT 两个值，决定正则作用于用户输入还是助手输出（`Assistant.kt`）。

### 1.3 存储位置与读写

助手整体保存在 Preferences DataStore 的 `assistants` 键中，当前选中助手保存在 `select_assistant` 键中（`PreferencesStore.kt`）。写入时把整个助手列表 JSON 序列化，读取时反序列化并补默认值（`PreferencesStore.kt`、`258-264`）。

读取管线还做三步归一化：补齐缺失的内置助手（列表为空时整体替换），因此内置助手删除后下次读取会重新补回；助手列表与模式注入、Lorebook、快捷消息列表按 id 去重；每个助手的相关 id 引用会过滤掉全局列表中不存在的悬空项（`PreferencesStore.kt`）。

设置更新统一走 `SettingsStore.update`，写入成功前先用内存中的 `settingsFlow` 覆盖，再落盘；针对单个助手的常用改动另有切换选中助手、改模型、改联网开关等便捷入口（`PreferencesStore.kt`、`432-515`）。

### 1.4 默认助手与内置预设

内置助手只有两个（`PreferencesStore.kt`）：

| 助手 | UUID | 取值 |
|---|---|---|
| 常量 `DEFAULT_ASSISTANT_ID` | `0950e2dc-9bd5-4801-afa3-aa887aa36b4e` | 名称与系统提示词均为空，充当兜底助手；`Settings.assistantId` 的默认值也是它 |
| 第二个内置助手 | `3d47790c-c415-4b90-9388-751128adb0a0` | 名称同样为空，系统提示词是带占位变量的英文模板，声明自己扮演 `{{char}}`、基于 `{{model_name}}` |

`DEFAULT_ASSISTANTS_IDS` 由这两个 id 组成，界面据此禁止删除内置助手（`AssistantPage.kt`）。模式注入的默认值只有一条 Learning Mode，插入位置在系统提示词之后（`PreferencesStore.kt`）。`data/ai/prompts/` 还提供标题、建议、压缩、OCR、翻译五类默认提示词，它们是全局设置字段而非助手字段，只在后台生成时读取（`PreferencesStore.kt`）。

## 2. 创建、选择与会话绑定

### 2.1 选中助手的持久化

全局选中助手由设置里的 `Settings.assistantId` 记录。读取助手时按这个 id 在列表中查找，找不到就退回列表第一个。切换入口是 `updateAssistant`，它只写选中 id 这一个键，助手本体的数据保持原样（`PreferencesStore.kt`）。

### 2.2 会话如何绑定助手

会话在创建时写入必填的助手 id（`Conversation.assistantId`），同时保存一组只属于该会话的覆盖字段：

- `customSystemPrompt`：会话自己的系统提示词
- `modeInjectionIds`、`lorebookIds`：模式注入与 Lorebook 的绑定集合
- `workspaceCwd`、`folderId`：工作区目录与所属文件夹

这批字段定义在 `data/model/Conversation.kt`。发送消息时助手来源由会话决定：先按会话绑定的 id 查找，查不到再回退全局选中的助手，因此一个会话始终使用它自己绑定的那份配置（`ChatService.kt`、`664-665`）。两者在存储上彼此独立，按助手查询、分页和搜索消息都可以带上该 id 过滤（`ConversationRepository.kt`）。

### 2.3 切换助手对进行中会话的影响

切换助手有三条路径，各自的影响不同：

- 改全局选中助手（不进入某个会话）：只写选中 id 这一个键，已创建的会话在下次发送时仍按自己绑定的助手取配置。
- 打开一个会话：`initializeConversation` 会把全局选中助手改写成该会话的助手，因此当前助手会随最近打开的会话漂移（`ChatService.kt`）。
- 显式迁移会话：会话级操作改写绑定的助手 id，同时清空所属文件夹，因为文件夹是助手内部的分组，跨助手后不可见（`ChatVM.kt`）。

每轮解析同时使用助手引用与会话局部快照：提示词、采样参数、本地工具和记忆等未固定字段在下一轮反映助手修改；模型、推理、搜索和工具接入等已固定字段继续读取会话值，除非用户修改会话配置或引用失效。正在生成的协程使用启动时取得的对象。见 [ConversationConfig 解析与失效回退](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/model/ConversationConfig.kt#L94-L140)。

### 2.4 复制与删除

复制助手会生成新 UUID、名称追加 ` (Clone)`，图片头像改用默认头像、背景保留；可选把原助手 id 下的记忆文件记录复制到新 id。删除时清理头像/背景、移除助手，再按该助手 id 删除记忆记录和会话；全局记忆使用另一共享 id，这个删除调用不清空全局库。见 [AssistantVM](../../rikkahub/app/src/main/java/me/rerere/rikkahub/ui/pages/assistant/AssistantVM.kt#L40-L80)、[记忆作用域](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/repository/MemoryRepository.kt#L160-L162)。内置助手不显示删除入口（`AssistantPage.kt`）。

## 3. 提示词字段与覆盖开关

### 3.1 systemPrompt 与会话覆盖

systemPrompt 在请求装配时作为首条合成 system 消息加入。若 `allowConversationSystemPrompt` 为真且会话有非空 `customSystemPrompt`，则用会话版本整体替换助手版本，而不是拼接（`data/ai/ChatRequestFactory.kt`）。

systemPrompt 的占位变量在发送前被替换；变量集合与写法规则见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。助手侧只确认界面以可点击标签列出这些变量（`AssistantPromptPage.kt`）。

### 3.2 messageTemplate

`messageTemplate` 默认 `{{ message }}`，是一条 Pebble 模板，逐条套用到非合成消息的文本部分（`TemplateTransformer.kt`）；渲染与缓存策略见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。助手侧要求模板必须包含 `{{ message }}`，缺失时界面高亮报错并提供一键重置（`AssistantPromptPage.kt`）。

### 3.3 presetMessages

`presetMessages` 是预设对话消息列表，每条有 role（仅 USER/ASSISTANT）和文本部分。新建会话时它们被写入会话的首批消息节点（`ChatService.kt`）。因此预设消息是“会话初始内容”，只影响新建会话，不是每次请求都注入的 system 文本。

### 3.4 提示词注入绑定

助手通过 `modeInjectionIds` 与 `lorebookIds` 绑定注入资源，前者按开关直接生效，后者按触发条件筛选。注入规则的匹配字段、位置枚举、优先级与插入点策略，均见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。助手侧只需记住绑定是 id 集合，悬空 id 在读取时被清理（见 1.3）。

### 3.5 会话级覆盖与优先级

系统提示词覆盖单独受 `allowConversationSystemPrompt` 控制：开启且会话有自定义系统提示时整体替换助手提示，否则使用助手值，消费位置为 `ChatRequestFactory.buildStep`。

注入绑定随会话配置固定，当前助手数据类没有独立的注入覆盖许可字段。会话已绑定配置时，请求读取会话自己的模式注入与 Lorebook 集合；聊天页修改也写当前会话，悬空资源 id 在解析时过滤。未绑定的新会话先读取助手默认绑定，绑定时还会保留旧会话已有的非空集合。见 [ConversationConfig.withConversation/getAssistantOf/bindConfig](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/model/ConversationConfig.kt#L50-L140)。

## 4. 模型、Provider 与生成参数

助手绑定的模型是 `chatModelId`，为 null 时回退全局 `chatModelId`（`PreferencesStore.kt`）；助手只保存模型 UUID，凭据与 baseUrl 归 Provider 所有，Provider 的导入、合并与去重见 [LLM 渠道管理调查笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

请求参数按会话视角的助手装配。温度、topP 与 maxTokens 取助手的当前值，推理强度则受会话固定配置覆盖（`data/ai/ChatRequestFactory.kt`、`data/model/ConversationConfig.kt`）。自定义请求头与请求体分别合并两份来源，助手自定义项在前、模型自定义项在后，覆盖顺序依次为助手、模型、协议默认。`streamOutput` 决定走流式还是整段返回，`reasoningLevel` 默认 AUTO，界面用专门的按钮调整（`AssistantBasicPage.kt`）。

温度与 topP 的取舍设计是“null 即不发送”：为 null 时不会出现在请求参数里，界面用开关表达启用与否；温度允许 0–2，topP 允许 0–1，越界被拒绝而不是截断（`AssistantBasicPage.kt`）。`customHeaders` 与 `customBodies` 的编辑界面在请求页，与模型的同名字段合并后发送（`AssistantRequestPage.kt`）。

## 5. 工具、记忆与能力开关（助手侧字段）

### 5.1 开关字段与消费结论

各能力由解析后的助手开关控制；搜索、工作区、技能与 MCP 优先使用会话固定值，其余读取助手当前值。下表记录助手侧字段及消费边界，机制细节按“归属”列：

| 能力 | 助手字段与取值 | 助手侧结论 | 机制归属 |
|---|---|---|---|
| 记忆 | `enableMemory`（默认 false）、`useGlobalMemory`、`autoConsolidateMemory`（默认 true） | 开启后注入记忆目录与核心文件正文并获得六个记忆工具，作用域分助手隔离与全局共享；后台整理可单独关闭，关闭后只能手动整理 | [检索增强与认知编排](../检索增强与认知编排/RikkaHub-检索增强与认知编排调查笔记.md) |
| 外部搜索 | `enableWebSearch`（默认 false） | 仅当模型自身未内置搜索能力时才注入外部搜索工具 | [Agent 工具](../Agent工具/RikkaHub-Agent工具调查笔记.md) |
| 本地工具 | `localTools`（默认只含 TimeInfo） | 按枚举展开为若干本地工具，屏幕时间、日历与图表展示各有前置条件 | [Agent 工具](../Agent工具/RikkaHub-Agent工具调查笔记.md) |
| 最近会话引用 | `enableRecentChatsReference`（默认 false） | 注入读取当前助手其他会话的工具 | [Agent 工具](../Agent工具/RikkaHub-Agent工具调查笔记.md) |
| 工作区 | `workspaceId`（可空） | 仅工作区 shell 就绪时注入工作区工具，目录来自会话的 `workspaceCwd` | [外部执行体与应用协作](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md) |
| Skill | `enabledSkills`（名称集合，可空） | 与磁盘扫描到的 Skill 元数据求交集后创建工具 | Agent 工具 |
| MCP | `mcpServers`（服务器 id 集合，可空） | 逐服务器、逐工具过滤 enabled 后加入，工具名带固定前缀 | Agent 工具 |
| 时间提醒 | `enableTimeReminder`、`timeReminderIntervalMinutes`（默认 60） | 距上一条消息达到间隔时注入一条时间提醒 | [上下文编译与提示词工程](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md) |

工具集按固定顺序追加：记忆、外部搜索、本地工具、最近会话引用、工作区、Skill、MCP（`ChatToolFactory.kt`）。本地工具的可选枚举有 JavaScript 引擎、时间信息、剪贴板、TTS、AskUser、屏幕时间、日历、图表展示八项，其中日历展开成两个工具，需权限的项由界面负责申请（`data/ai/tools/local/LocalToolOption.kt`）。模型不支持工具而助手又开了搜索或存在 MCP 工具时，会追加一条“工具不可用”的错误提示（`ChatService.kt`）。

### 5.2 MCP 过滤按传入助手进行

MCP 服务器 id 存在助手字段 `mcpServers` 中，可用工具的筛选由调用方把助手实例传进 `getAllAvailableTools`，只保留服务器自身 enabled 且 id 在该助手 `mcpServers` 内的条目（`McpManager.kt`）。会话配置固定后，工具装配使用的是会话配置里的服务器集合，与生成链路按会话取助手的来源一致。

### 5.3 子 Agent

本快照未找到“子 Agent”这一独立概念：助手之间没有委派或嵌套关系，任务编排止于单轮工具循环。完整论证与搜索范围归 [Agent 工具调查笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)（`ai/agent/AgentLoop.kt` 的循环上限由 `maxSteps` 注入，默认 256 步）。

### 5.4 正则替换

每个助手带一份正则列表 `regexes`，可在提示词页拖拽排序（`AssistantPromptPage.kt`）。每条正则按 `affectingScope` 决定作用于用户输入还是助手输出，按 `visualOnly` 决定只改变界面显示还是同时改写发送内容（`Assistant.kt`、`86-97`）。输入侧与输出侧分别由两条转换器链应用（`ChatService.kt`、`RegexOutputTransformer.kt`），先后时序见 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。

## 6. 资产、变量、开场白与用户档案

- 头像与背景：助手头像分图片与 emoji 两种形态，图片存本地或网络 URL，emoji 直接存文本。聊天页背景由背景图和不透明度控制，打开动态渐变后改用渐变并忽略背景图；更新助手时，旧的头像与背景文件会被删除（`AssistantDetailVM.kt`）。用户头像与昵称来自全局显示设置，系统提示词的 `user`、`nickname` 占位变量读取的就是这个昵称（`PreferencesStore.kt`）。
- 开场白：本快照未找到独立的开场白字段；SillyTavern 导入会把角色卡的 `first_mes` 写成一条 assistant 角色的预设消息，开场白实际上由它承载（`AssistantImporter.kt`）。
- 快捷消息与环境变量：助手用 id 集合引用全局快捷消息，读取时按 id 求交集（`PreferencesStore.kt`）；占位变量来自静态枚举与系统读取，没有用户可定义的键值环境变量表。

## 7. 导入、导出、迁移与兼容性

### 7.1 无助手导出

本次在 `ui/pages/assistant/` 与备份代码中未找到导出单个助手或分享助手的入口，助手也没有独立的导出格式。把配置迁移到另一台设备只能走整体设置备份：备份包里的 `settings.json` 是完整的设置序列化结果，包含全部助手，恢复时整体写回（`BackupManager.kt`、`75-139`）。会话导出（Markdown 与图片分享）只包含会话消息（`ui/pages/chat/Export.kt`）。

### 7.2 SillyTavern 角色卡导入

导入支持 JSON 与 PNG（PNG 内嵌 base64 元数据），识别 `chara_card_v2` 与 `chara_card_v3` 两种规范（`AssistantImporter.kt`）。映射规则：

| 源字段 | 目标 |
|---|---|
| `name` | 助手名称 |
| `first_mes` | 一条 assistant 角色的 presetMessage |
| `system_prompt` + `description` + `personality` + `scenario` | 拼接进 systemPrompt |
| PNG 图片 | 助手背景 |

导入的提示词前会加上 `You are roleplaying as <name>.` 与各段小标题（`AssistantImporter.kt`）；未映射的字段不会保留，世界书需另行在提示词注入里手工重建。

### 7.3 Chatbox 会话导入

Chatbox 备份导入的是会话：所有会话挂到当前选中助手下，并按会话级 system 提示词的存在与否置位目标助手的 `allowConversationSystemPrompt`（`BackupVM.kt`）。随包导入的 Provider 合并与去重见 [LLM 渠道管理调查笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

### 7.4 数据版本迁移

数据版本号写在 `data_version` 键中，当前迁移链到 V3（`PreferencesStore.kt`）：

- V2 迁移修正 `presetMessages` 中消息部分的类型字面量，把旧的类名式类型统一成小写短名（`PreferenceStoreV2Migration.kt`）。
- V3 迁移把助手内联的 `quickMessages` 提升为全局快捷消息：为每条旧消息补新 UUID，收集到全局列表，助手侧改存 id 集合（`PreferenceStoreV3Migration.kt`）。

`SettingsJsonMigrator` 在备份恢复时也会跑一次同样的迁移，并用迁移后的结果回写备份中的设置文件（`BackupManager.kt`）。

## 8. 配置界面与可见字段

助手详情按基础、提示词、扩展、记忆、请求、MCP、本地工具七个子页组织。基础页放身份、工作区、模型与采样、上下文上限和外观；提示词页提供变量标签与消息模板预览；扩展页再分快捷消息、模式注入、Lorebook、Skill 四页（`AssistantDetailPage.kt`）。

聊天页把设置流与当前会话组合成会话视角的助手、模型。模型和联网可从聊天页修改，写入助手默认或当前会话由是否已有配置快照决定，见 [ChatVM](../../rikkahub/app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatVM.kt#L181-L205)。

助手列表提供搜索、标签过滤、拖拽排序、复制与删除，排序写回设置中的助手列表顺序（`AssistantPage.kt`）。

## 9. 设计取舍与已确认边界

- 助手是纯数据对象：没有类方法，行为全部由外部服务读取字段后执行；配置以整体 JSON 存储而非关系表，使字段演进只需迁移函数，代价是每次读取都要做一遍去重与引用清理。
- “null 表示不设值”的约定让界面可以区分“启用并填写”与“交给模型默认”，避免把禁用状态伪装成具体数值。
- 会话保存助手引用与局部配置快照。模型、工具接入及注入绑定按会话覆盖，其余助手字段继续动态读取；历史消息本身不随助手修改而重写。
- 全局选中助手负责新会话默认值；既有会话请求经会话视角解析，MCP 过滤使用解析后的助手实例，不直接用全局选择值，见 [ChatRequestFactory.createContext](../../rikkahub/app/src/main/java/me/rerere/rikkahub/data/ai/ChatRequestFactory.kt#L97-L119)。
- 内置助手读时补齐，删除不是持久性的，`DEFAULT_ASSISTANTS_IDS` 同时被界面用于隐藏删除入口。

## 10. 未验证事项

- 应用未运行，以上关于请求装配顺序与正则生效范围的结论来自代码路径，请求体的实际形态未在真实 Provider 上验证。
- 聊天页背景、渐变、不透明度与气泡等外观字段只确认了绑定与取值范围，视觉效果未在设备上观察。
- SillyTavern 的 PNG 元数据解析依赖 `ImageUtils.getTavernCharacterMeta`，容错边界未展开；Chatbox 导入的 fork 分支与图片落盘完整度只核对了计数器与调用点，未用真实备份验证。
- 上下文截断：`contextMessageLimit` 的阶梯式截断算法位于 `ai` 模块的 `limitContext`（`ai/src/main/java/me/rerere/ai/util/ContextUtil.kt`），本次仅确认调用点；时间提醒的间隔比较是否跨分支节点同样未验证。
- 助手各能力开关只核对了默认值与消费入口，未在设备上逐项开启并观察工具表与上下文段是否随之变化。

## 11. 关键源码索引

- `data/model/Assistant.kt`：Assistant 数据类、字段默认值、AssistantRegex 与影响范围枚举；注入位置枚举、PromptInjection 与 Lorebook。
- `data/model/Conversation.kt`：会话字段与助手绑定。
- `data/datastore/PreferencesStore.kt、190-191、258-264`：助手与选中助手的 DataStore 读写。
- `data/datastore/PreferencesStore.kt、432-515`：内置补齐、去重与悬空引用清理，以及单个助手的更新入口。
- `data/datastore/PreferencesStore.kt、730-782`：当前助手/当前模型/快捷消息解析与内置助手。
- `data/datastore/migration/PreferenceStoreV2Migration.kt`、`PreferenceStoreV3Migration.kt`：助手数据迁移。
- `service/ChatService.kt、458-462、658-747`：会话初始化、按会话取助手、解析模型与组装工具。
- `data/ai/ChatRequestFactory.kt`：system 消息装配、上下文截断与采样参数；`data/model/ConversationConfig.kt`：会话固定配置。
- `data/ai/tools/ChatToolFactory.kt`：助手开关到工具集的映射。
- `data/ai/mcp/McpManager.kt`：MCP 工具按当前选中助手过滤。
- `ui/pages/assistant/AssistantVM.kt`：助手增删、复制与记忆读取。
- `ui/pages/assistant/detail/AssistantImporter.kt`：SillyTavern 角色卡导入。
- `ui/pages/assistant/detail/AssistantPromptPage.kt`：提示词、模板、预设消息与正则界面。
- `ui/pages/chat/ChatVM.kt、310-325`：聊天页助手状态与会话迁移。
