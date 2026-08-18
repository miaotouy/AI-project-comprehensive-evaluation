# Risuai Agent 角色配置调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：只读核对角色与数据库类型定义、导入导出实现、发送链与提示词装配、lorebook 运行时、请求参数解析和角色配置界面；未修改被调查仓库源码，未运行应用
>
> 调查范围：角色数据模型与存储、创建/导入/选择/会话绑定、提示词字段与装配优先级、模型与生成参数归属、lorebook/记忆/资产/变量等外部能力挂接、角色卡导入导出兼容性、运行时可见性与消息快照；不覆盖插件 API 细节、MCP 工具执行边界、翻译与 TTS 内部实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 的"角色"是**独立持久化对象**，与聊天（会话）、全局数据库和预设（preset）四层分离。`character` 与 `groupChat` 两种对象都存放在单一数据库对象的 `characters` 数组里，用 `chaId`（UUID）标识；聊天是角色下的 `chats[]` 数组元素，每个聊天单独持有开场白索引、作者注、会话级 lorebook、绑定的用户档案和记忆状态。角色本身**不持有模型与生成参数**——模型、温度、上下文长度等全部是全局 Database 字段，由 botPreset（预设）成批切换，角色与聊天都不绑定预设。

提示词装配按全局装配顺序（或可选的模板卡片序列）把多个语义槽位拼成消息序列：`systemPrompt` 与 `replaceGlobalNote` 分别以占位符替换全局主提示词与备注，描述、人格、场景拼进描述槽，聊天作者注、向量检索出的附加文本、按深度插入的 `depth_prompt` 各占位置。开场白（`firstMessage` 与 `alternateGreetings`）**不写入历史**，渲染与提示装配每次都实时读取角色字段，由聊天级 `fmIndex` 选择，修改角色会直接影响既有会话的下一轮生成。

外部能力分层挂接：lorebook 由角色级、聊天级与全局模块三源合并激活，激活语义（关键词、正则、概率、延迟、深度、注入、递归）在运行时解析；记忆按角色开关与全局算法选择，状态回写聊天对象；MCP 工具注册在全局模块与插件层，角色没有工具字段，仅以 `lowLevelAccess` 门控脚本能力。导入导出覆盖 Tavern V2/V3、PNG（`chara`/`ccv3` 文本块与附加资产块）、JSON、CharX（ZIP）、Chub 下载与 Risu Hub（realm）深链，扩展数据存放在 `extensions.risuai`。

历史快照只覆盖生成元数据：每条消息保存 `generationInfo`（模型显示名、token 计数、上下文上限、分阶段耗时），开启 `promptInfoInsideChat` 后还保存预设名与 toggle 列表；采样参数、完整提示词正文默认不随消息落盘。重新生成（reroll/regenerate）是**破坏性重建**——弹出末尾助手消息后重新请求，旧回复只保存在界面内存中，刷新即丢失。

## 总体生效链路

发送入口 `sendChat`（`src/ts/process/index.svelte.ts:99`）的完整链路如下：

1. 读取当前角色（`selectedCharID` 下标）与当前聊天（`chatPage`），按装配顺序把主提示词、描述、人格、示例对话、历史、lorebook、备注、作者注、persona 各槽位填成 `OpenAIChat[]` 消息序列；角色字段的覆盖逻辑见 `index.svelte.ts:410-496`，槽位拼装见 `index.svelte.ts:1221-1468`。
2. 插入开场白、执行可选记忆压缩、按上下文上限截断，再把深度注入（角色 `depth_prompt` 与 lorebook 的 depth 条目）插入历史。
3. 调用 `requestChatData`（`src/ts/process/request/request.ts:205`）按当前预设选定的模型发起请求，流式结果逐段写入 `chat.message` 并附带 `generationInfo`。
4. 自动保存循环（500ms 防抖）把整库增量编码写进 `database/database.bin`（`src/ts/globalApi.svelte.ts:315-479`）。

## 1. 角色数据模型与存储

### 1.1 character 字段分组

`character` 接口定义在 `src/ts/storage/database.svelte.ts:1343-1499`，按职责可分成几组：

- 身份与元数据：`name`、`nickname`、`chaId`（唯一标识）、`tags/creator/characterVersion`（导出用 `additionalData` 镜像）、`creation_date/modification_date`、`source`、`license/private/realmId`（分享与 Hub 关联）、`trashTime`（软删除标记）。
- 提示词与人格：`desc`、`personality`、`scenario`、`exampleMessage`、`systemPrompt`、`replaceGlobalNote`、`additionalText`、`depth_prompt`、`firstMessage` 与 `alternateGreetings`、`firstMsgIndex`。
- 聊天集合：`chats[]`（`Chat` 类型，含 `message/note/localLore/fmIndex/bindedPersona/folderId` 与各记忆数据字段，`database.svelte.ts:1817-1839`）、`chatFolders`、`chatPage`。
- 外观与资产：`image`、`emotionImages`、`additionalAssets`、`ccAssets`（V3 资产表）、`largePortrait`、`backgroundHTML/backgroundCSS`、`viewScreen`（表情/图像生成模式）。
- 脚本与能力：`customscript`（正则脚本）、`triggerscript`（触发脚本）、`virtualscript`（导入时强制置空，见注释 "removed due to security issue"）、`lowLevelAccess`、`utilityBot`、`prebuiltAssetCommand`。
- 外部能力：`globalLore`（lorebook 条目数组）、`loreSettings/loreExt`（世界书预算与扫描设置）、`supaMemory`、`defaultVariables`、`modules/moduleNamespace/customModuleToggle`（模块挂接）、`coldstorage`（冷存储外置键）。

`groupChat`（`database.svelte.ts:1510-1580`）是另一种持久化对象：成员以 `characters`（chaId 数组）引用，另有发言权重、激活开关、自动模式、顺序发言、单次发言与是否使用成员角色 lorebook 等群聊专用字段，以及 `group_only_greetings`（V3 卡导出字段）。群聊是独立的角色集合容器，不是角色实体的聚合视图。

### 1.2 存储与迁移

整个数据库（含角色数组与全部聊天）经 msgpackr 序列化加 gzip 压缩成一个 `.bin` 文件：Tauri 写 `database/database.bin`（AppData），Web 端写入 LocalForage 同名键，每次保存另写一个时间戳备份。

增量保存由自动保存循环完成：`RisuSaveEncoder` 按块编码（root/preset/modules/loadouts/plugins/pluginStorage/characters/chat），变更追踪只标记当前选中角色与其当前聊天（`src/ts/storage/risuSave.ts:124-263`、`src/ts/globalApi.svelte.ts:315-479`）。大聊天可外置到 coldstorage（gzip 的独立 JSON 文件或账号侧远端存储，`src/ts/process/coldstorage.svelte.ts:40-80`），角色选中时再按需取回。

字段默认值与迁移集中在两处：整个库加载走 `setDatabase`（`database.svelte.ts:30-722`），角色对象走 `characterFormatUpdate`（`src/ts/characters.ts:533-646`），后者会补齐缺失字段并把旧字段迁移（例如把旧的后置指令字段合并进当前聊天的作者注，把 lorebook 的 v1 概率字段内联成 `@@probability` 内容前缀）。这意味着一部分"角色字段"是在加载时按需补全的，数据库中允许缺省。

## 2. 创建、选择与会话绑定

创建入口是 `addCharacter`（`characters.ts:842-874`）：提供"从零创建""创建群聊""导入文件""从 Realm 导入"四种路径；`createNewCharacter` 直接 push 一个 `createBlankChar()`（`characters.ts:667-719`，含默认触发脚本与空聊天）。没有独立的复制/克隆入口（全仓未找到 duplicate 相关符号）。

删除是双确认 + 三模式：`removeChar` 的 normal 模式只写 `trashTime`（软删除，角色仍在数组中），permanent/permanentForce 直接 splice（`characters.ts:809-840`）。

选择角色通过全局 store `selectedCharID`（`src/ts/stores.svelte.ts:27`，值是 `characters` 数组下标）驱动整个聊天界面；`changeChar`（`characters.ts:876-898`）在生成进行中拒绝切换，切换前若角色已冷存储则先取回数据，再跑字段补全。

会话（聊天）与角色是一对多：新建聊天只生成空的 `Chat` 对象并设置 `fmIndex = -1`，不复制角色字段。模型、采样参数与全局提示词字段的"当前值"在 Database 层，由 `botPresetsId` 指向预设（见第 4 节），角色切换不会触碰预设选择——这是静态确认：`changeChar` 与预设切换函数 `changeToPreset` 之间没有调用关系。

用户档案（Persona）可以在聊天级绑定：`Chat.bindedPersona` 保存 `RisuPersona.id`，UI 在侧栏与聊天列表中切换绑定（`SideChatList.svelte:276-289`）；解析用户名、头像、人格文本与档案大图时都先检查该绑定（`src/ts/util.ts:110-151`），有绑定则覆盖全局当前档案。

## 3. 提示词字段、优先级与输出契约

### 3.1 槽位与默认顺序

发送链先构造一组"未格式化"槽位（`index.svelte.ts:349-360`）：主提示词、jailbreak、历史、lorebook、备注、作者注、末条消息、描述、结尾区与 persona（键名见源码）。默认装配顺序如下，且结尾区恒追加到末尾（`index.svelte.ts:1222-1225`）：

```
['main','description','personaPrompt','chats','lastChat','jailbreak','lorebook','globalNote','authorNote']
```

若启用 `promptTemplate`（预设可携带），则完全按卡片序列装配，卡片类型如下（键名见源码），支持内联格式包裹与 `{{slot}}` 填充、角色转换与缓存点标记（`index.svelte.ts:676-820` 与 `1271-1461`）；`utilityBot` 角色强制使用一套精简模板（`index.svelte.ts:379-408`）。

```
persona / description / lorebook / chat / authornote / memory / cache / plain / jailbreak / cot / chatML / postEverything
```

### 3.2 角色字段到槽位的映射

| 角色/会话字段 | 槽位与行为 | 定位 |
| --- | --- | --- |
| `systemPrompt` | 非空时经 `{{original}}` 替换全局 `mainPrompt`，进入 main 槽 | `index.svelte.ts:411` |
| `desc` + `personality` + `scenario` | 依次拼接进 description 槽，`personality` 前加 "Description of {{char}}:"，`scenario` 前加场景引导语 | `index.svelte.ts:466-496` |
| `replaceGlobalNote` | 经 `{{original}}` 替换全局 `globalNote`，进入 globalNote 槽 | `index.svelte.ts:439`、`751-753` |
| `additionalText` | 每轮按最近 4 条消息做向量相似度检索，取前 3 段拼入描述 | `src/ts/process/embedding/addinfo.ts:5-35` |
| `chat.note` | 非空时作作者注进 authorNote 槽，否则回退全局作者注默认文本 | `index.svelte.ts:446-457` |
| `depth_prompt` | 以 system 消息插入到距历史末尾 `depth` 条的位置 | `index.svelte.ts:1484-1491` |
| `exampleMessage` | 按 `<START>` 与 `{{char}}:`/`{{user}}:` 前缀切成示例消息序列，置于历史之前 | `src/ts/process/exampleMessages.ts:5-68` |
| 全局 persona（或绑定档案） | 文本进入 personaPrompt 槽，参与变量解析 | `index.svelte.ts:560-565` |
| `firstMessage`/`alternateGreetings[fmIndex]` | 以 assistant 消息形式插在历史最前，来自实时角色字段而非历史 | `index.svelte.ts:868-884` |

### 3.3 变量与覆盖优先级

所有槽位文本都经 `risuChatParser` 解析（`src/ts/parser/parser.svelte.ts:1538` 起）：替换 `{{char}}`/`{{user}}`、执行 `{{...}}` 嵌套模板与 CBS 函数（条件、循环、读写变量），并支持 `{{//注释}}` 语法。

变量取值的优先级链是：会话已存值 > 角色默认变量 > 全局默认变量 > 空值，实现在 `getChatVar`（`src/ts/parser/chatVar.svelte.ts:5-39`），写入侧 `setChatVar` 把值存进会话的 `scriptstate`。

角色字段间的"覆盖"实际只有两处占位符替换：`systemPrompt` 覆盖主提示词、`replaceGlobalNote` 覆盖备注，其余字段是并列拼接。角色字段进入请求的最终契约是 `OpenAIChat[]` 消息序列，模型适配层再根据模型能力做合并与角色改写（`request.ts:348-432`）。

## 4. 模型、Provider 与生成参数

角色、聊天均不持有模型与采样参数（已核对两个接口定义）。模型与参数是 Database 全局字段（主模型 `aiModel`、辅助模型 `subModel`、温度与上下文上限等），由预设成批切换。

`botPreset`（`database.svelte.ts:1582-1685`）是这些全局值的成批快照，还包含提示词字段（主提示词、jailbreak、备注、装配顺序、模板）与渠道字段（API 类型、密钥、端点、代理）。保存与切换由 `saveCurrentPreset` 与 `changeToPreset` 实现，选中 id 为全局 `botPresetsId`（`database.svelte.ts:2036-2255`）。切换角色不改变预设，切换预设不改变角色——两者在数据层完全正交。

请求解析在 `requestChatDataMain`（`request.ts:435-458`）：主请求用 `db.aiModel`，辅助请求（记忆/表情/翻译等模式）用 `db.subModel`，开启分离模型时按模式覆盖；失败时按 `fallbackModels` 列表逐个重试。温度默认 `db.temperature / 100`。

消息里保存的模型显示名由 `getGenerationModelString` 生成（`src/ts/process/models/modelString.ts:3-24`），把 openrouter 前缀、Ollama 等可读字符串而非内部 id 记入历史。

## 5. 工具、知识库、记忆与子 Agent

**工具**：MCP 服务器注册在全局模块（`RisuModule.mcp` 字段）与插件层，`getTools()` 只是 `getMCPTools()` 的包装（`src/ts/process/mcp/mcp.ts:273-275`）。角色类型没有任何工具字段，也没有工具白名单——工具对角色全局可见，这与"角色卡只带内容"的取向一致；角色侧相关的只有 `lowLevelAccess`（是否允许脚本调用危险操作）与 `utilityBot`。工具的发现、schema 注入与执行细节归 Agent 工具类目，本篇不展开。

**知识库（lorebook）**：运行时 `loadLoreBookV3Prompt`（`src/ts/process/lorebook.svelte.ts:75-666`）把角色 `globalLore`、当前聊天 `localLore` 与全局模块 lorebook 三源合并后逐个求值：条目以关键词（支持正则、全词匹配、大小写敏感）与 `@@` 装饰符（概率、延迟、深度、角色、位置、注入、排除键、递归、激活后保持等）决定激活，另有子条目模式。

激活结果按插入序排序，受每角色 `loreSettings`（可回退全局 token 预算与扫描深度）约束，输出按注入位置分发到 lorebook 槽、描述前后、结尾区与历史深度位置（消费端在 `index.svelte.ts:498-611` 与 `1056-1195`）。数据库层遗留的全局 lorebook 页面（`db.loreBook` 多页）仍可编辑，但 UI 已注明移除（`LoreBookList.svelte:358-360`），运行时三源合并不包含它——这是源码确认的遗留边界。

**记忆**：角色只持有 `supaMemory` 布尔开关与每个聊天的记忆状态（`supaMemoryData/hypaV2Data/hypaV3Data`）；算法（SupaMemory/HypaV2/HypaV3/Hanurai）与模型、分配 token 都在全局设置。发送链在 `index.svelte.ts:1068-1140` 按开关执行对应算法，把压缩后的消息替换回历史并回写状态字段。

**子 Agent**：未找到角色级子 Agent 配置；群聊是对成员角色的发言调度（权重 `characterTalks`、`groupOrder` 排序），不是子 Agent 执行体。

## 6. 资产、变量、开场白与用户档案

**资产**：头像、表情图、附加资产与 V3 资产表等资产字段（键名见第 1.1 节）都以资产 id 存储：经 `saveAsset` 写入应用资产存储，卡内引用在导入导出时以 `__asset:N`、`embeded://`、`data:` 等前缀解析（见第 7 节）。消息文本中的 `{{asset_prompt::name}}` 占位可按名称把附加资产作为多模态图注入请求（`index.svelte.ts:1010-1037`）。

**变量**：角色 `defaultVariables` 提供键值默认（与全局 `templateDefaultVariables` 合并），`{{getvar}}/{{setvar}}` 读写会话 `scriptstate`；`globalChatVariables` 是全局变量（含 toggle 开关值）。三者分别由 `chatVar.svelte.ts` 与解析器消费，写入会在自动保存时随角色/聊天落盘。

**开场白**：`firstMessage` 与 `alternateGreetings` 不进入 `chat.message`，聊天界面按会话级 `fmIndex`（-1 = 默认开场白）显示与翻页（`DefaultChatScreen.svelte:837-872`），发送链同样按该索引实时取文本插入 prompt（`index.svelte.ts:868-884`）。

因此修改开场白或新增备选开场白会立即影响既有会话的显示与下一次生成；历史中不保存开场白快照，`fmIndex` 本身随聊天持久化。

**用户档案**：`personas` 数组（`RisuPersona`：name/icon/personaPrompt/note/largePortrait/id，`database.svelte.ts:792-800`）由全局 `selectedPersona` 指向当前档案，`changeUserPersona` 把选中项复制到全局用户名、人格文本、头像与备注字段（`src/ts/persona.ts:36-46`）。

档案可导出为带 `persona` PNG chunk 的图片、从图片导入（`persona.ts:54-141`），并可与角色双向转换（`src/ts/interchangeability.ts:122-193`，转换时把人格文本包成 `@@indicator` lorebook 条目，模块内嵌到档案的 `embeddedModule`）。

## 7. 导入、导出、迁移与兼容性

**格式与入口**：`importCharacterProcess`（`src/ts/characterCards.ts:52` 起）按扩展名分发：

- `.json`：V2/V3 卡或旧式 V1 字段
- `.png`：读取 `chara` 或 `ccv3` 文本块，附带 `chara-ext-asset_N` 资产块；`rcc||` 前缀的加密卡需密码或内置密钥解密
- `.charx/.jpg/.jpeg`：CharX ZIP，含 `card.json` 与可选 `module.risum`

另有 Chub API 下载（`charahub` 参数）、Risu Hub（realm）下载、URL 深链 `#import=`、PWA `launchQueue` 与 Tauri 打开文件等入口（`characterCards.ts:406-625`）。

导出 `exportCharacterCard`（`characterCards.ts:1245-1524`）默认 V3，可选 V2，输出 PNG/JSON/CharX/CharX 嵌入 JPEG；V3 CharX 包按资产类型（image/audio/video/model/ai/fonts/code）分目录写入并附 `x_meta` 元数据，同时把触发脚本与正则导出为内嵌模块文件；V2 走 PNG chunk，资产以 base64 写入附加 chunk。

**字段映射**：`importCharacterCardSpec`（`characterCards.ts:720-1036`）把卡 data 映射到角色对象，标准字段一一对应，关键映射包括：

- `post_history_instructions` → `replaceGlobalNote`
- `character_book` → `globalLore` 加 `loreSettings/loreExt`
- `alternate_greetings` → 备选开场白数组
- `extensions.risuai` → 本应用私有字段（表情、bias、视图模式、正则、trigger、utilityBot、SD 配置、背景、许可、附加文本、largePortrait、lorePlus、newGenData、VITS、defaultVariables、lowLevelAccess 等）
- `extensions` 其余键 → 原样保留到 `extentions`；`depth_prompt` 从扩展里拆出为顶层字段

`convertCharbook`（`characterCards.ts:1038-1143`）把 SillyTavern 风格的世界书扩展字段（概率、位置+深度+角色、选择逻辑、延迟、整词匹配）内联成 `@@` 装饰符写进内容前缀，把二次键语义转成排除键或附加键装饰符。

**兼容性边界**：旧 V1（无 `spec`）卡走 `convertOffSpecCards`（`characterCards.ts:628-687`）直接映射；V2 卡的 `system_prompt` 导入到角色 `systemPrompt` 并在运行时替换全局主提示词；未找到 BYAF 格式支持。

`lowLevelAccess` 卡与模块导入需要用户确认（`characterCards.ts:915-920`、`modules.ts:306-307`）；`virtualscript` 字段在导入时强制为空（安全原因）。

聊天本身可导入导出 JSON（`risuChat` v1/v2）、Tavern JSONL、HTML 与 TXT（`characters.ts:192-526`），角色与聊天文件相互独立。

## 8. 配置界面、输出契约与可见字段

角色配置界面 `CharConfig.svelte`（`src/lib/SideBars/CharConfig.svelte`）按子菜单分组：基本信息、资产与表情、高级设置（bias、示例对话、作者说明、主提示词覆盖、备注覆盖、附加文本、人格与场景、默认变量、深度提示词、备选开场白、`lowLevelAccess`、`utilityBot` 等，`1057-1288`）、lorebook 编辑器、脚本（正则、trigger、背景 HTML）、TTS 与图像生成配置。

界面字段与运行时消费基本对应：主提示词覆盖、备注覆盖、附加文本、深度提示词、默认变量与翻译备注（`translatorNote` 的消费点在 `translator.ts:523-536`）都已确认有消费链；`personality` 与 `scenario` 在 UI 中默认隐藏（长文本或打开高级开关时显示），但运行时总是拼接进描述槽。

运行时可见性分两层。消息快照：消息对象携带 `generationInfo`（模型、生成 id、输入/输出 token 计数、上下文上限、分阶段耗时，`database.svelte.ts:1862-1874`），在 `sendChat` 落盘时写入（`index.svelte.ts:1533-1545`、`1601-1610`）。

开启 `promptInfoInsideChat` 后，消息还保存 `promptInfo`（预设名、toggle 键值列表，`index.svelte.ts:267-285`），再配合 `promptTextInfoInsideChat` 可把本次拼装的消息文本存入 `promptText` 字段供对比。

界面可见性：聊天界面按 `fmIndex` 渲染开场白分页器，消息区展示模型/耗时信息——具体展示组件本次未逐项核对，见未验证事项。

## 9. 设计取舍与已确认边界

- **角色是纯内容容器，运行参数全部在外层**：与同类角色扮演应用把推理参数放卡外一致，Risuai 更进一步——连"预设选择"都全局化，角色与聊天都锚定不到某个预设。好处是角色切换零配置成本；代价是同一聊天内换角色会沿用上一预设的提示词与采样设置。
- **开场白是实时引用而非快照**：没有类似 SillyTavern tainted 的固化机制，`firstMessage` 修改后旧聊天下一次生成即用新文本；历史消息中也不存在开场白副本，导出聊天时开场白从角色字段现取（`characters.ts:292`）。
- **重新生成是破坏性重建**：reroll 从消息末尾弹回到最近一条用户消息后重新请求（`DefaultChatScreen.svelte:246-270`），旧回复只保存在界面内存的 `rerolls` 数组与 `prereroll.ts` 的 generationId 索引中，刷新或切换页面即丢失；多消息生成时同样只缓存当轮结果（`prereroll.ts:26-29`）。历史中没有任何 swipe/分支结构。
- **全局 lorebook 是遗留功能**：数据与编辑入口仍在，但 UI 明示移除、运行时未消费，属于可观察的未清理边界。
- **导入导出做了积极的方言兼容**：SillyTavern 扩展字段被内联成装饰符而非保留原结构，`@@` 语法即运行时语法；`extensions` 未知键整体保留但不保证被任何逻辑读取。
- **安全边界**：`lowLevelAccess` 需导入确认、`virtualscript` 被移除、资产导入只接受白名单 chunk 且单 chunk 限 20KB（`characters.ts:101-119`）、卡数据限 5MB。

## 10. 未验证事项

- 未运行应用：聊天界面渲染、开场白分页器交互、消息悬浮信息（模型/耗时）的展示方式均为静态推断，未做运行验证。
- `promptInfo.promptText` 与 `showPromptComparison` 的界面呈现组件未逐项核对。
- 群聊场景中 `bindedPersona`、`{{char}}` 解析与 `groupOrder` 权重算法的实际行为未验证。
- 温度等全局参数经各 Provider 适配层进入请求体的最终映射只确认了共享层（`request.ts:458`、`shared.ts:286`），各适配器内部细节未全部核对。
- MCP 工具在请求中的 schema 注入、执行与结果回注归 Agent 工具类目，本篇未覆盖。
- coldstorage 的自动触发阈值与恢复流程只确认了入口（`coldstorage.svelte.ts:529/576`），未追踪完整状态机。
- 聊天级 `chat.note` 与角色 `postHistoryInstructions` 的迁移合并（`characters.ts:586-590`）在真实旧数据上的表现未验证。

## 11. 关键源码索引

- `src/ts/storage/database.svelte.ts:1343-1499`：character 接口（字段全集）
- `src/ts/storage/database.svelte.ts:1510-1580`：groupChat 接口
- `src/ts/storage/database.svelte.ts:1817-1880`：Chat、Message、MessageGenerationInfo、MessagePresetInfo
- `src/ts/storage/database.svelte.ts:1582-1685` 与 `2036-2255`：botPreset 结构与保存/切换
- `src/ts/characters.ts:533-646`：角色字段默认值与迁移（characterFormatUpdate）
- `src/ts/characters.ts:809-898`：删除、创建、切换角色
- `src/ts/characterCards.ts:52-625`：导入入口与分发（importCharacterProcess）
- `src/ts/characterCards.ts:720-1036`：V2/V3 卡到角色的映射（importCharacterCardSpec）
- `src/ts/characterCards.ts:1038-1143`：世界书扩展字段到 @@ 装饰符的转换
- `src/ts/characterCards.ts:1147-1678`：导出构造（createBaseV2/createBaseV3/exportCharacterCard）
- `src/ts/process/index.svelte.ts:349-496`：槽位定义与主提示词/描述构建
- `src/ts/process/index.svelte.ts:1221-1491`：formatingOrder/promptTemplate 装配与 depth_prompt
- `src/ts/process/index.svelte.ts:1530-1610`：generationInfo 构造与消息落盘
- `src/ts/process/lorebook.svelte.ts:75-666`：lorebook 运行时求值与分发
- `src/ts/process/request/request.ts:435-519`：模型与参数解析（requestChatDataMain）
- `src/ts/storage/risuSave.ts:124-263` 与 `src/ts/globalApi.svelte.ts:315-479`：持久化与自动保存
- `src/lib/SideBars/CharConfig.svelte:1057-1288`：角色高级配置界面
- `src/lib/ChatScreens/DefaultChatScreen.svelte:218-301` 与 `837-872`：reroll 与开场白分页
