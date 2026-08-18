# AIO Hub Agent / 角色配置调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：只读核对 Agent 类型定义、预设消息与消息组编辑器、开场白状态机、上下文与重新生成链路、SillyTavern 角色卡及世界书的导入、编辑、导出与运行时处理器、默认模板、内置预设和 Agent/工具/Skill 架构文档，并结合作者对会话实时引用设计目的的说明；未修改被调查仓库源码
>
> 调查范围：Agent/角色能配置什么、实际拥有什么能力、内置角色偏好的方向，以及预设如何导入和运行
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

AIO Hub 的 Agent 是一个可保存、可切换的对话配置集合。它把以下几层合并到 AgentBaseConfig：

1. **人格与上下文**：名称、描述、分类、标签、预设消息树、开场白、用户档案、世界书、会话变量。
2. **模型偏好**：指定模型/渠道（实例字段）、temperature、maxTokens 以及其他 LLM 参数、思考块识别、上下文后处理和富文本显示规则。
3. **外部能力**：知识库召回、VCP 工具调用、Skill/扩展开关、快捷操作。
4. **沉浸式运行时**：图片/音频/视频/文件资产、虚拟时间线、视觉化输出指南、分支发送和媒体音量。

因此，AIO Hub 的“角色”可以同时是普通助手、固定人格、专家工作流、世界模拟器或带工具的 Agent。角色气质主要由预设消息和示例对话决定；工具、知识库和虚拟时间等字段则决定它在运行时能做什么。

从产品界面看，聊天侧边栏的“参数”页也是 Agent 编辑器的一部分：它编辑的是当前 ChatAgent，模型选择、采样参数、上下文限制/压缩和预设消息随 Agent 配置持久化，不在当前聊天窗口临时生效。

在本次十六个项目的统一调查范围内，AIO Hub 是**一体化 Agent 预设配置能力最强、编辑入口最完整**的项目。这里评价的是“一个 Agent 内能表达什么，以及用户能否在同一编辑流程里理解和切换”，不是社区资产数量。SillyTavern 的角色卡生态和兼容格式更成熟，但角色卡、推理 Preset、Prompt Manager、Advanced Formatting、World Info 和扩展字段分属不同层；AIO 则把消息配方、模型与参数、知识、工具、变量、资产和显示规则集中在同一个 Agent 对象及其编辑器中。

这里也不能把 AIO 概括为“只导入酒馆角色卡”。当前快照有独立的世界书管理器、条目编辑器、导入导出服务和进入真实请求管道的 `worldbook-processor`。它实现的是一套可编辑、可绑定 Agent/User Profile、可条件激活并注入上下文的 **SillyTavern 兼容子集**。SillyTavern 仍领先于社区资产规模、扩展/事件协议和 World Info 全语义覆盖；这是生态与兼容完整度的差距，不等于 AIO 缺少角色创作或世界书运行能力。

它的会话继承也不是单一的“快照”或“全局覆盖”：开场白在会话真正开始后固化，旧消息和旧回复保持不变；后续发送、续写与重新生成则读取 Agent 当前配置，并以新分支保存结果。这一混合语义明显偏向调试效率，允许用户在同一段历史上修改配置后立即重试比较。

需要区分两种对象：

- AgentPreset 是文件或内置资源中的模板，不包含具体 profileId、modelId。
- ChatAgent 是用户实际使用的实例，额外保存 id、profileId、modelId、创建时间和最近使用时间。

## 2. 配置入口与文件格式

### 2.1 内置预设的加载方式

预设登记文件 `src/config/agent-presets/index.ts` 只登记元数据：id、名称、描述、图标、分类、标签和 configUrl。完整配置按 ID 放在 `public/agent-presets/{id}/`，可附带 icon.jpg 和 assets/ 目录。加载器支持：

- `config.json`：适合字段较少的静态助手；
- `config.yaml`：适合多行 system prompt、角色扮演和复杂消息结构。

当前内置样本包括 code-assistant、creative-writer、translator 三个 JSON 预设，以及长门有希、凤凰院凶真、岸边露伴、坂田银时、智慧之王和艾尔德拉大陆等 YAML 角色/世界模拟预设。

### 2.2 编辑器实际分组

编辑器配置文件 `components/agent-editor/agentEditConfig.ts` 将配置分成：

- 基础设定
- 角色设定
- 功能扩展
- 会话变量
- 知识库
- 工具调用
- 环境增强
- 输出与显示

编辑器已把"知识库"区拆为 **Recall 与 Knowledge 两个独立标签页**（RecallSection.vue/KnowledgeLibrarySection.vue，提交 342d42dd3）——Recall 承担上下文即时召回绑定（recallConfig.bindings），Knowledge 承担资料库访问授权（knowledgeAccess）与资料引用；旧 KnowledgeSection.vue（723 行）已删除，KnowledgeBaseItem/PlaceholderEditor 相应改名为 RecallBindingItem/RecallPlaceholderEditor（占位符编辑器改为按集合 ID 配置）。这份编辑器目录是判断"用户界面明确支持哪些设置"的主要依据；类型文件则包含导入、兼容或高级功能可能用到的字段。

### 2.3 聊天侧边栏也是 Agent 配置入口

LLM Chat 的右侧栏（LeftSidebar.vue，组件类名为 right-sidebar）有“智能体”和“参数”两个页签。切到“参数”页后，实际可直接修改：

- 当前 Agent 绑定的 profileId:modelId；
- 预设消息树（紧凑版 AgentPresetEditor）；
- ModelParametersEditor 中按模型能力筛选出的生成参数、上下文管理、上下文压缩、后处理、图片压缩、安全设置和思考/联网等特殊参数。

这里不是仅对当前会话生效的临时覆盖层。ParametersSidebar 的双向绑定 setter 调用 agentStore.updateAgent，并立即持久化。因此从侧边栏改动的模型选择、参数和预设消息都会进入当前 Agent 的持久化配置；重新打开 Agent 或重启应用后仍会保留。侧边栏页签本身的激活状态属于 UI 状态，由 useLlmChatUiState 管理，不属于 Agent 配置。

需要特别区分“模型选择”和“模型定义”：侧边栏的模型选择只写 Agent 的 profileId、modelId；旁边的“编辑模型配置”按钮修改的是所选 LLM Profile 中的模型元数据，随后由 useLlmProfiles().saveProfile 写回 LLM 配置文件，不会把整个模型定义复制进 Agent。

## 3. 人格、消息与对话行为

### 3.1 基础身份

可配置字段：

| 字段 | 作用 |
| --- | --- |
| `name` | 稳定 ID，也用于宏替换的一部分 |
| `displayName` | UI 显示名，可与内部 ID 不同 |
| `description` | 角色/助手简介 |
| `icon` | Emoji、图标路径或相对文件名 |
| `category` | `assistant`、`character`、`expert`、`creative`、`workflow`、`other` |
| `tags` | UI 筛选和分组标签 |
| `agentVersion` / `version` | 角色版本与配置格式版本 |

实例还可绑定 `userProfileId`，覆盖全局用户档案；模型实例使用 `profileId`（渠道/配置）和 `modelId`（模型）。这两个字段不在内置预设中固定，创建 Agent 时由用户选择。

### 3.2 `presetMessages`：核心人格载体

首次出现的 presetMessages 是 ChatMessageNode[]；每个节点还有 id、parentId、childrenIds、role、content、status 和 isEnabled。它可以表达：

- `system`：角色设定、规则、知识和输出约束；
- `user` / `assistant`：few-shot 示例、开场对话和角色口吻；
- `chat_history`：实际会话历史的插入锚点；
- `user_profile`：用户档案注入锚点；
- `presetAttachments`：引用 Agent 专属资产作为预设消息附件；
- `groupId`：把消息放进可整体开关的预设组。

消息可以按数组默认顺序注入，也可以使用 `injectionStrategy`：

- `default`：按默认上下文顺序；
- `depth`：相对聊天历史末尾按深度插入；
- `advanced_depth`：用 `N`、`N1,N2` 或 `S~I` 等语法在多个深度重复注入；
- `anchor`：相对于 `chat_history`、`user_profile` 等锚点前后插入，并用 `order` 排序。

消息还可用 modelMatch 按模型 ID 或渠道正则决定是否生效，支持 any / all 和排除模式。也就是说，同一个角色可以为不同模型准备不同的提示词片段。

配置向导明确要求实际配置包含 chat_history 锚点，否则没有位置放入真实对话；通常也应提供 user_profile 锚点。内置 YAML 角色普遍通过 system 角色设定、user/assistant 示例和 chat history 形成角色卡式上下文。

### 3.3 开场白与分组

greetings 独立于 presetMessages，每条开场白包含 id、可选 name、content、role（user 或 assistant）和附件。defaultGreetingId 选择默认开场白，displayPresetCount 控制聊天界面展示多少条预设消息。

开场白采用“开始前同步、开始后固化”的两阶段语义：

1. 创建会话时，insertLiveGreetings() 把所有可用开场白实例化为根节点下的兄弟分支，展开宏、深拷贝附件，并写入开场白标记、greetingId、live 状态和 Agent/模型元数据；默认开场白只决定当前选中的分支。
2. 用户尚未发送第一条消息时，切回会话会调用 refreshLiveGreetingsIfNeeded()；若 Agent 的开场白、附件、名称、头像或模型引用变化，live greeting 会被重建。此时切换 Agent 也可以整体替换这些候选开场白。
3. 用户第一次从会话继续发送消息时，solidifyGreetings() 在创建消息对之前把所有根级开场白的 greetingLive 置为 false。从此这些节点成为会话历史的一部分，不再跟随 Agent 后续修改；未固化的 live greeting 则不计入会话有效消息数。

因此，“开场白会在会话中固化”与“Agent 配置会影响既有会话”并不冲突：固化的是已经作为对话起点出现的具体消息内容，后续请求使用的预设、模型参数、工具与知识配置仍可读取 Agent 当前值。

presetGroups 可以把若干消息做成复选组（checkbox）或单选组（radio），并通过组级 enabled 开关决定是否参与上下文。适合把“说话风格”“当前场景”“可选身份”“输出协议”等提示块做成可切换模块。

组会改变有效提示词集合：

- **多选组**：组内每条消息保留独立开关，可启用任意组合；
- **单选组**：切换一条消息时，同组其他消息会被关闭，组内同时最多一条生效；
- **组级开关**：关闭组时，编辑器将当前启用成员统一设为禁用，并在消息 metadata.lastEnabledState 中记录原状态；重新打开组时只恢复之前启用的成员；
- **紧凑入口**：聊天侧边栏使用 AgentPresetEditor 的 compact 模式，直接显示每组的单选/多选类型、已启用数/总数和组开关，不必进入完整 Agent 管理页；
- **成员管理**：消息可在卡片上加入、移动或脱离组；删除组时可以选择“仅解散组”或“连同组内消息彻底删除”。

实现上，injection-assembler 最终仍只按每条消息的 isEnabled 过滤，并不直接读取 presetGroups.enabled。正常 UI 路径会由 applyPresetGroupEnabledState() 把组状态投影到消息状态，因此组开关会真实影响送模上下文；但手工编辑或外部导入若构造出“组已禁用、成员仍启用”的不一致配置，运行时以成员状态为准，本次未找到请求前的再次归一化。

### 3.4 预设编辑器的配置与交互密度

AIO 的预设能力不只体现在数据字段数量，还体现在编辑器把高阶字段组织成了可操作流程：

- 消息列表支持拖拽排序、分页、逐条启停、复制、复制到下方、粘贴覆盖和批量管理；
- 单条消息可设置显示名称、`system/user/assistant` 角色、所属消息组、模型/渠道匹配和四种注入策略；
- 内容编辑使用 Monaco，并提供编辑、宏处理后纯文本预览和 Markdown/富文本渲染预览三种模式；
- 工具栏可插入宏、会话变量和 Recall/知识库占位符（占位符编辑器为 RecallPlaceholderEditor，按集合 ID 配置），也能为消息选择 Agent 私有资产附件；
- 预设消息本身可独立复制或导入导出为 JSON/YAML；v2 格式同时保存 `groups` 与 `messages`，不必导出整个 Agent；
- 导入 SillyTavern Prompt Preset 时先解析 system、injection 和 unordered prompt，再由选择对话框确认写入，不把来源字段直接摊到主编辑器中。

这解释了 AIO 与 SillyTavern 的体验差异：酒馆的 Prompt Manager 也支持拖拽、逐条开关、角色、相对/深度注入、注入顺序和 generation trigger，表达力并不弱；但它还同时暴露 `marker`、`system_prompt`、`forbid_overrides`、extension source 等内部语义，并与角色卡和采样 Preset 分离。AIO 的字段同样很多，但大部分被包装成消息、组、匹配规则和注入策略四类直接可见对象，用户更容易理解“当前到底启用了哪套上下文”。

## 4. 模型与输出偏好

### 4.1 模型参数

parameters 使用 LlmParameters，至少支持 temperature、maxTokens，默认模板还包含 topP、topK、frequencyPenalty、presencePenalty 等可选项。内置预设的取向很明显：

| 预设 | temperature | 主要方向 |
| --- | ---: | --- |
| 长门有希 | 0.1 | 极度稳定、简洁、技术型 |
| 代码助手 | 0.5 | 工程支持与结构化输出 |
| 智慧之王 / 翻译专家 | 0.3 | 精准解析和翻译 |
| 创意写作 | 0.8 | 创意发散 |
| 艾尔德拉大陆 | 0.85 | 沉浸式叙事和世界模拟 |
| 坂田银时 | 0.9 | 松散、即兴、强口吻角色扮演 |

这些数值是样本偏好，不是系统强制范围。

### 4.2 思考、上下文和显示

可配置：

- llmThinkRules：识别 `<think>`、`<thinking>` 等思考块，控制是否折叠显示；
- contextCompression：按 Token/消息规模触发非破坏性摘要压缩；
- contextPostProcessing：合并 system 消息、合并连续角色、把 system 转 user、强制 user/assistant 交替；
- contextManagement：最大上下文 Token 和截断时保留字符数；
- imageCompression：发送前图片格式、质量和最大尺寸；
- richTextStyleOptions：Markdown/富文本渲染样式；
- regexConfig：对请求或渲染消息做正则清理、替换和宏处理；
- defaultToolCallCollapsed：工具调用消息默认是否折叠。

Agent 模型参数与渠道/模型的适配规则有独立草案文档（`docs/Plan/agent-model-parameter-rules-draft.md`，提交 e2e3a825f），讨论按模型能力裁剪/映射 Agent 参数与渠道元数据的规则，目前是设计草案，尚未见注册到运行时参数过滤的实现。另外聊天侧栏与 Agent 编辑器对工具策略 toolCallConfig 的修改会强制二次确认（提交 f5e834e3c），防止误改自动批准配置。

### 4.3 模型参数编辑器的实际分组与语义

侧边栏和 Agent 编辑器共用 `ModelParametersEditor`，界面根据 Profile 类型和模型 `capabilities` 动态过滤可见字段。分组如下：

| UI 分组 | 主要字段 | 说明 |
| --- | --- | --- |
| 基础参数 | `temperature`、`maxTokens`、`topP`、`topK`、`frequencyPenalty`、`presencePenalty` | 采样和输出长度；`maxTokens` 会受模型输出上限约束 |
| 高级参数 | `seed`、`stop`、`maxCompletionTokens`、`logprobs`、`topLogprobs` | 只有 Provider/模型支持时才发送 |
| 上下文管理 | `contextManagement.enabled`、`maxContextTokens`、`retainedCharacters` | 发送前截断过长历史；这是截断上限，不是摘要压缩 |
| 上下文压缩 | `contextCompression` | 见下节 |
| 上下文后处理 | `contextPostProcessing.rules` | 合并 system、合并连续角色、角色交替等管道规则 |
| 图片压缩 | `imageCompression` | 发送多模态图片前缩放/转 JPEG 或 WebP |
| 特殊功能 | `webSearchEnabled`、`thinkingEnabled`、`thinkingBudget`、`reasoningEffort`、`includeThoughts` | 联网和不同模型的思考配置，按能力显示 |
| Provider 专属 | `safetySettings` 等 | 例如 Gemini 安全阈值 |

每个标准参数旁有启用开关。编辑器会维护 enabledParameters；存在该数组时，只有数组中的参数才会发给 API。旧 Agent 没有该字段时，组件会根据非 undefined 的值推断启用项，以兼容旧数据。custom.enabled 与 custom.params 则承载 Provider 不在标准列表中的自定义键值。

### 4.4 上下文压缩配置（`parameters.contextCompression`）

压缩设置确实属于 Agent 的 `parameters`，由侧边栏“参数 → 上下文压缩”直接编辑，不属于聊天全局设置。可持久化字段及默认值为：

| 字段 | 默认值 | 作用 |
| --- | --- | --- |
| `enabled` | `false` | 总开关 |
| `autoTrigger` | `true` | 是否在发送前自动检查并压缩 |
| `triggerMode` | `token` | 按 Token、消息条数或 `both` 触发 |
| `tokenThreshold` | `80000` | Token 触发阈值 |
| `countThreshold` | `50` | 消息条数触发阈值 |
| `minHistoryCount` | `15` | 允许压缩前至少要有的历史消息数 |
| `protectRecentCount` | `10` | 永不纳入本次压缩的最近消息数 |
| `compressCount` | `20` | 每次取最旧的多少条合并成摘要 |
| `summaryRole` | `system` | 摘要节点插入时使用的消息角色 |
| `summaryModel` | 未设置 | 可指定独立的摘要模型；缺省使用当前 Agent 模型 |
| `summaryTemperature` | `0.3` | 摘要生成随机性 |
| `summaryMaxTokens` | `4096` | 摘要输出上限 |
| `summaryPrompt` / `continueSummaryPrompt` | 空字符串 | 首次摘要/在既有摘要上续写的模板；空值使用内置模板 |

压缩是非破坏性的：摘要节点隐藏原消息参与请求，但原始消息仍保存在会话数据中。保存 Agent 时，如果提示词为空或等于内置模板，存储层会主动剥离这两个字段，运行时再回退到内置模板，避免每个 `agent.json` 重复保存大段默认提示词。

### 4.5 视觉化输出

`visualGuideline` 是注入上下文的专属提示词，用来规定 Agent 何时使用 Markdown、HTML/CSS/JS、Mermaid、KaTeX、按钮等输出形式。凤凰院凶真预设把它用于“视觉化重构”：

- 布局模式：HTML 与 Markdown 混排；
- 应用构建模式：`html` 代码块内运行完整 JS，放在 iframe 沙箱；
- 原生模式：普通 Markdown、Mermaid、KaTeX。

这属于输出指导，不等价于给 Agent 新增文件、网络或系统权限。

## 5. 外部知识与记忆来源

### 5.1 世界书

Agent 可以关联 `worldbookIds`，并配置：

- `disableRecursion`：是否禁用递归扫描；
- `defaultScanDepth`：默认扫描深度。

世界书适合角色背景、地点、人物和世界规则等按关键词动态注入的 lore。

这条链不止保存 worldbookIds 引用。st-worldbook-manager 提供本地持久化、列表和详情编辑、JSON/`.lorebook` 导入导出，并可从 SillyTavern PNG 角色卡或 AIO Bundle 提取世界书；世界书还能绑定 Agent 与 User Profile，通过跨窗口事件同步修改。聊天请求中的 worldbook-processor 会合并全局、用户档案与 Agent 绑定，再完成扫描、激活、递归和位置注入。因此它应判断为“有独立编辑器和运行时的兼容实现”，不是导入后只保留数据。

为避免把“字段存在”“UI 可编辑”和“在 AIO 中生效”混为一谈，当前静态证据可分为四层：

| 兼容状态 | 已确认范围 |
| --- | --- |
| 可编辑且运行时生效 | 主/次关键词、正则关键词、selective 逻辑、constant、概率、扫描深度、大小写与全词匹配、角色名/名称/标签过滤、递归激活、`preventRecursion`、延迟递归层级、包含组与加权选择、group override，以及严格 `depth` 注入 |
| 运行时生效，但当前编辑器未提供完整控件 | `sticky`、`cooldown`、`delay`；类型与处理器已消费，详情编辑器未找到对应操作项 |
| 可保存或部分可编辑，但未确认被运行时消费 | `automationId`、trigger filtering、`excludeRecursion`、`ignoreBudget`、`useGroupScoring`、vectorized 状态；`Outlet` 可编辑/导出并保留在共享数据中，但未找到按 `outletName` 继续消费的注入链 |
| 降级映射或兼容边界 | Before/After Char、AN、EM 等锚点会映射到 AIO 的消息结构，不能视为酒馆原位置语义的逐项复刻；酒馆扩展事件、脚本协议和全部 World Info 字段也没有形成等价运行时 |

还有几个 UI/类型差异需要保留：`characterFilter.tags` 在类型和运行时存在，当前编辑器只绑定 `names`；`useProbability` 会被运行时检查，但 UI 主要暴露概率值。导入归一化当前读取 `key`/`keysecondary`，导出则使用常见 ST 的 `keys`/`secondary_keys`，`character_filter` 的 snake_case 归一化也未见完整覆盖。它们需要用真实 V2/V3 样本做往返验证，目前只能记为兼容风险，不能据此断言所有导入都会失败。

### 5.2 知识库与思绪（Recall/Knowledge 双域）

旧 knowledgeBaseConfig/knowledgeSettings 字段已从 AgentBaseConfig 移除，拆为三个字段（`agent-manager/types/agent.ts:464-470`）：

- `recallConfig`：思绪（Recall）绑定——总开关 `enabled`、绑定列表 `bindings`（每条含 `recallId`/`recallName`、激活模式 `always`/`gate`/`turn`/`static`、`whenParams`、召回数量 `limit`、最低相关分数 `minScore`、检索画像 `profile`（`semantic`/`associative`）、预设 `presetId`（`algorithmic`/`comprehensive`））与自动注入位置（`autoInjectIfMacroMissing` + `autoInjectPosition`）；
- `recallSettings`：默认预设、默认画像、`maxRecallChars` 上限、`defaultLimit`/`defaultMinScore`、结果模板、空结果文本、gate 扫描深度与缓存开关；
- `knowledgeAccess`：Knowledge 资料库的**访问权限**（授权库 ID 等）——类型注释明确"授权不会触发自动检索或目录注入"，与 Recall 的自动召回是两条独立链路；
- recallMigrationIssues：旧配置版本化迁移留下的可恢复诊断（RecallMigrationIssue）。

占位符协议同步迁移：知识库通过 `{{recall}}` 宏或 `【recall::...】` 占位符显式触发（严格参数协议，见对话请求与上下文笔记 9.6）；旧 `{{kb}}`/`【kb::...】` 占位符在管道中被识别为"已废弃"并告警、不再执行检索。`{{kb}}` 宏已从宏注册表移除，新增 `{{recall}}`/`{{recall_list}}`（宏总数 72 → 74，见独特功能笔记能力五）。

## 6. 工具调用与可执行能力

### 6.1 Agent 是工具策略控制中心

AIO Hub 的架构文档把三层分得很清楚：

1. ChatAgent.toolCallConfig 决定哪些工具可见、如何批准以及循环边界；
2. tool-calling 负责发现 agentCallable 方法、解析 VCP 请求、路由、审批、执行和结果回注；
3. skill-manager 通过 ToolRegistryFactory 把 Skill 暴露成同一套工具方法。

### 6.2 可配置项

toolCallConfig 支持：

| 字段 | 含义 |
| --- | --- |
| `enabled` | Agent 工具调用总开关 |
| `mode` | `auto` 自动批准，或 `manual` 每次请求等待用户审批 |
| `toolToggles` | 按工具 ID 启用/禁用 |
| `methodToggles` | 按 `toolId_methodName` 启用/禁用具体方法 |
| `autoApproveTools` / `autoApproveMethods` | 工具级/方法级自动批准策略 |
| `defaultToolEnabled` / `defaultAutoApprove` | 新发现工具的默认启用和批准行为 |
| `maxIterations` | 单次请求最多循环多少轮，防止工具调用死循环 |
| `timeout` | 单次工具执行超时（默认模板为 30000 ms） |
| `parallelExecution` | 同轮工具调用是否并行 |
| `protocol` | 当前类型只允许 `vcp` |
| `toolSettings` | 按工具保存配置快照，执行时参与参数合并 |
| `overrides` | 覆盖工具/方法的显示名、描述、示例和启用状态 |
| `autoInjectIfMacroMissing` | 缺少 `{{tools}}` 等宏时是否自动插入工具定义 |
| `rateLimitEnabled` / `rateLimitInterval` | 工具调用结束后的请求频率限制 |
| `convertToolRoleToUser` | 是否把 tool 角色结果转成 user 角色 |
| `showMethodsCount` | UI 是否显示工具方法数量 |

默认工具配置是关闭总开关、关闭新工具默认启用和自动批准、最大迭代 20、超时 30 秒、串行执行、VCP 协议。由此可见，创建 Agent 后不会因为存在工具注册表就自动获得全部工具；需要显式打开 Agent 配置和相应工具。

### 6.3 工具来源与边界

工具并不只来自固定内置列表：内建 ToolRegistry、动态注册工厂、Skill、插件代理和远端 VCP 工具都可以进入同一注册表。模型只能看到标记为 agentCallable 的方法；执行器还会在实际调用前再次校验工具、方法和可调用标记。

当前模型通信协议实现只有 VCP 文本协议：工具定义注入 system prompt，模型回复中输出 `<<<[TOOL_REQUEST]>>>` 块，执行结果再以工具结果消息回注。架构上 ToolCallingProtocol 留出了替换协议的接口，但 ToolCallConfig.protocol 目前没有其他可选值。

## 7. 资产、变量与环境增强

### 7.1 Agent 专属资产

assetGroups 和 assets 允许为一个 Agent 管理图片、音频、视频和文件。资产字段包括：

- `id`：宏引用用的 handle；
- `path`、`filename`、`type`；
- `description`、`group`、`usage`（`inline` / `background`）；
- 音视频 `autoplay`、`loop`、`muted`、封面和样式选项。

预设消息可用 presetAttachments 引用这些资产，也可在内容中使用 agent-asset://{group}/{id}.{ext}。资产随 Agent 导入导出，可选择放入 ZIP/文件夹或 PNG 内嵌包。

### 7.2 会话变量

variableConfig 用于定义会话变量及其约束；配置向导说明可通过 `{{getvar::path}}` 和 `{{setvar::path::op::value}}` 读取、更新。它适合保存角色扮演中的状态、任务进度或用户偏好，但变量的具体 schema 由 sessionVariable.ts 定义，不应把它当作模型长期记忆。

### 7.3 虚拟时间线

virtualTimeConfig 可设置虚拟基准时间、现实基准时间和 timeScale。启用后，{{time}}、{{date}}、{{datetime}}、{{shichen}} 等宏按虚拟时间计算。艾尔德拉大陆预设将虚拟时间设为圣历 1024 年，并把流速设置为现实的 2 倍，用于驱动世界模拟中的昼夜、商店和事件节奏。

### 7.4 扩展与快捷操作

extensionConfig 提供 Agent 级扩展总开关、按扩展 ID 的开关以及新扩展默认状态；quickActionSetIds 关联快捷操作组。它们是环境/交互能力的入口，不等于某个具体工具已经被批准。

## 8. 内置角色的方向画像

从 public/agent-presets/ 的实际配置看，AIO Hub 的角色预设大致分为四类：

| 类型 | 样本 | 主要配置手段 | 偏好方向 |
| --- | --- | --- | --- |
| 工具型助手 | 代码助手、翻译专家、创意写作大师 | 单一 system prompt + 低/中/高 temperature | 任务边界清晰、输出格式明确 |
| 角色人格 | 长门有希、凤凰院凶真、岸边露伴、坂田银时、智慧之王 | 长 system prompt + 角色示例对话 + `character` 分类 | 口吻、价值观、称呼和行为准则稳定 |
| 世界/场景模拟 | 艾尔德拉大陆 | 世界观百科 + NPC 档案 + 行动选项 + 虚拟时间 | 连续叙事、状态一致性、沉浸感 |
| 配置向导 | `agent-config-wizard.ts` | 结构化 system prompt + 工具策略 + 读写审批拆分 | 解释、创建、导入和修改其他 Agent |

典型偏好没有独立的 `personality` 字段，分散在 system prompt、few-shot、温度、开场白、世界书/知识库和输出指南中。

## 9. 持久化、导入导出与会话绑定

### 9.1 本地持久化链路

用户创建或修改的 Agent 采用分离式文件存储，不是只放在 Pinia 内存或聊天会话里：

1. agentStore.updateAgent 修改内存中的 ChatAgent；
2. persistAgent 调用 useAgentStorage，将完整配置序列化为 agent-manager/agents/{agentId}/agent.json；
3. 同时更新 agent-manager/agents-index.json，索引只保留列表展示所需的元数据（名称、图标、Profile/模型 ID、标签、时间等）。

实际根目录由 getAppConfigDir() 决定（Tauri 的 AppData 目录，支持便携模式），所以笔记中的 agent-manager/... 是相对于应用配置目录的路径。Agent 资产也放在对应目录，配置中的 icon 等字段可以用相对文件名或 appdata://agent-manager/agents/... 引用。资产存储路径已从旧 llm-chat/agents/ 统一迁移到 agent-manager/agents/；useAgentStorage 通过版本化数据迁移（cross-module-v2，runVersionedDataMigration）补充复制旧目录、校验目录子集与迁移标记，迁移完成后经通知中心发送成功通知（提交 f852e6b2d/d12533a49/1537e29f9）；跨会话搜索的 Agent 目录也随之改为 agent-manager/agents/（会话与消息管理笔记 5.1）。

这解释了为什么侧边栏看起来像“设置”，但内容仍属于角色配置：侧边栏只是编辑入口，持久化边界由 ChatAgent 文件决定。导出 Agent 时，parameters（包括模型参数、上下文限制、压缩和图片压缩）会随配置导出；本地实例字段 id、profileId、创建/使用时间的处理仍遵循导出格式定义。

### 9.2 与 LLM Profile 配置的边界

Agent 文件只保存所选渠道和模型的引用（profileId、modelId）以及 Agent 级参数。渠道的 API 地址、密钥、请求头、模型列表和模型能力元数据由独立的 LLM Profile 配置管理。侧边栏“编辑模型配置”修改后调用 saveProfile 写回 Profile 存储；删除或更换 Profile 可能使 Agent 的引用失效，需要重新选择模型。不要把 Agent 的 parameters.temperature 等采样参数与 Profile 中的模型元数据混为一谈。

“编辑模型配置”弹窗修改的是模型条目本身，例如模型 ID/显示名/分组/图标/描述、输入上下文和输出 Token 上限、模型能力（文本/图片/音频/视频、联网、思考模式）、思考等级选项、默认后处理规则、模型专属参数规则及价格元数据。这里的 tokenLimits 和 capabilities 会反过来约束 Agent 参数侧边栏可显示的控件和滑块上限，但它们不属于 Agent 的 parameters。

Agent 导出结构 AIO_Agent_Export 会剥离本地实例字段（id、profileId、创建/使用时间），保留大部分配置。导出选项可包含：

- JSON 或 YAML 配置；
- Agent 资产；
- 关联世界书，选择独立文件或内嵌内容；
- ZIP、文件夹、单文件或带数据的 PNG 包。

配置向导还说明了 SillyTavern 角色卡的兼容路径：可导入 JSON/PNG 角色卡、嵌入式 Character Book、Context Preset 和 Regex Scripts，并映射为 AIO Hub 的预设消息、世界书和正则配置。世界书并非导入后静态存档，独立管理器可继续编辑和导出，受支持字段会由 worldbook-processor 在后续请求中激活和注入。导入后的模型选择仍需在 AIO Hub 实例侧解决，不应假定来源角色卡携带的模型 ID 在本地存在；未被 AIO 运行时消费的扩展字段即使得到保留，也不会自动获得酒馆中的行为。

### 9.3 既有会话实时读取 Agent 当前配置

AIO 的会话保存消息树、当前显示 Agent ID 和每条生成消息的元数据，但不保存一份完整的 Agent 配置副本。发送新消息、重新生成和续写时，执行链都会再次读取当前 Agent 配置，再与 ChatAgent 合并成当次 executionAgent。因此修改 Agent 的预设消息、消息组、模型参数、工具、知识、世界书等配置后，既有会话的下一次请求会使用新配置；具体读取入口见源码索引。

重新生成也不是覆盖旧回复：createRegenerateBranch() 复用同一用户节点和到该节点为止的历史路径，创建新的助手兄弟分支；useSingleNodeExecutor 同时把当次实际请求参数写入新节点的 metadata.requestParameters。这使用户可以在完全相同的会话历史上修改 Agent 后立即重试，对比新旧回复，而不必新建会话或搬运聊天记录。

据作者说明，这种实时引用是有意的产品设计，主要服务于 Agent 调试与迭代，不应简单归类为“配置修改静默污染旧会话”。更准确的边界是：

- **历史消息固化**：已经产生的用户/助手消息、已开始对话的开场白以及生成节点的 Agent/模型/请求参数元数据保留；
- **未来执行实时**：下一次发送、续写或重新生成读取当前 Agent 配置，并可在相同历史节点上形成新分支；
- **完整配置版本未固化**：消息虽保存部分执行快照，但本次未找到完整 Agent revision 或完整上下文配方快照，因此仅凭会话文件未必能复原过去某次生成时的全部 Agent 配置。

## 10. 实际使用时的判断

如果目标是创建一个“角色”，最小可靠配置是：

1. `name`、`description`、`icon`、`category`、`tags`；
2. 一个明确的 `system` 预设消息；
3. `chat_history` 锚点，必要时加入 `user_profile`；
4. 若需要稳定口吻，加入 1 至 3 组 user/assistant 示例；
5. 设置合适的 `temperature` 和 `maxTokens`。

如果目标是创建一个“Agent”，再按需求增加：

- 工具调用总开关、工具/方法白名单和审批策略；
- 知识库绑定与召回阈值；
- 世界书或会话变量；
- 资产与视觉化输出指南；
- 虚拟时间和分支交互。

最重要的边界是：**提示词决定角色怎么说，工具/知识/资产/运行时字段决定它能接触什么；visualGuideline 只指导输出形式，不自动扩大系统权限。**

## 11. 主要源码依据

- `aio-hub/src/tools/agent-manager/types/agent.ts`：Agent、预设、消息、资产、知识库、工具调用、扩展配置类型。
- `aio-hub/src/tools/llm-chat/components/sidebar/LeftSidebar.vue`：聊天侧边栏的“智能体/参数”页签入口。
- `aio-hub/src/tools/llm-chat/components/sidebar/ParametersSidebar.vue`：侧边栏模型选择、预设消息和 Agent 参数的双向绑定；参数修改直接调用 `agentStore.updateAgent`。
- `aio-hub/src/tools/agent-manager/components/parameters/ModelParametersEditor.vue`：基础/高级参数、上下文管理、压缩、后处理、图片压缩和模型能力过滤。
- `aio-hub/src/tools/llm-chat/types/llm.ts`：`LlmParameters`、`ContextCompressionConfig`、默认压缩配置及默认提示词剥离逻辑。
- `aio-hub/src/tools/llm-chat/types/message.ts`：消息节点、注入策略、模型匹配和预设附件引用。
- `aio-hub/src/tools/agent-manager/components/assets/AgentPresetEditor.vue`：完整/紧凑预设编辑器、拖拽、批量管理、独立导入导出和侧边栏消息组开关。
- `aio-hub/src/tools/agent-manager/components/assets/PresetGroupPanel.vue`：消息组创建、单选/多选、组级启停、成员管理和删除语义。
- `aio-hub/src/tools/agent-manager/components/assets/presetGroupState.ts`：组开关向成员 `isEnabled` 的状态投影与恢复。
- `aio-hub/src/tools/agent-manager/components/assets/usePresetImportExport.ts`：预设消息 v1/v2 JSON/YAML 格式及 SillyTavern Prompt Preset 导入。
- `aio-hub/src/tools/agent-manager/components/editors/PresetMessageEditor.vue`：角色、组、模型匹配、注入策略、宏/变量/知识库/附件和三态预览。
- `aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts`：按消息 `isEnabled`、模型匹配和注入策略构建最终上下文。
- `aio-hub/src/tools/llm-chat/services/greetingService.ts`：开场白实例化、live 同步、Agent 切换和首次发送后的固化状态机。
- `aio-hub/src/tools/llm-chat/composables/session/useSessionManager.ts`：创建会话时插入全部开场白分支。
- `aio-hub/src/tools/llm-chat/stores/session/sessionLifecycleManager.ts`：切换会话时刷新尚未固化的开场白。
- `aio-hub/src/tools/llm-chat/composables/chat/useChatHandler.ts`：发送、重新生成和续写时读取当前 Agent 配置；首次发送前固化开场白。
- `aio-hub/src/tools/llm-chat/composables/chat/useChatExecutor.ts`：将当前 Agent 与参数片段合并为当次 `executionAgent`。
- `aio-hub/src/tools/llm-chat/composables/chat/useSingleNodeExecutor.ts`：记录当次实际请求参数快照。
- `aio-hub/src/tools/llm-chat/composables/session/useNodeManager.ts`：重新生成复用同一用户节点并创建助手兄弟分支。
- `aio-hub/src/tools/agent-manager/config/defaultAgentTemplate.ts`：新建 Agent 默认身份和模型参数。
- `aio-hub/src/tools/st-worldbook-manager/types/worldbook.ts`：世界书、条目、位置、过滤、递归与兼容字段类型。
- `aio-hub/src/tools/st-worldbook-manager/components/WorldbookDetail.vue`：世界书详情与条目编辑面；可据此区分类型支持和 UI 控件覆盖。
- `aio-hub/src/tools/st-worldbook-manager/services/worldbookImportService.ts`：JSON、`.lorebook`、PNG 角色卡与 AIO Bundle 导入、字段归一化。
- `aio-hub/src/tools/st-worldbook-manager/services/worldbookExportService.ts`：AIO/ST 格式导出与字段映射。
- `aio-hub/src/tools/llm-chat/core/context-processors/worldbook-processor.ts`：世界书合并、扫描、条件激活、递归、组选择与上下文注入主链。
- `aio-hub/src/tools/agent-manager/stores/agentStore.ts`：Agent 更新与持久化调用链。
- `aio-hub/src/tools/agent-manager/composables/storage/useAgentStorage.ts`：`agent.json`、索引文件和 AppData 路径。
- `aio-hub/src/tools/agent-manager/components/agent-editor/agentEditConfig.ts`：编辑器实际配置分组。
- `aio-hub/src/config/agent-presets/README.md`：JSON/YAML 预设格式、资产路径和基本示例。
- `aio-hub/src/config/agent-presets/agent-config-wizard.ts`：高级字段、宏、角色卡导入和向导自身的工具审批策略。
- `aio-hub/public/agent-presets/*/config.json|config.yaml`：内置角色的实际人格、温度和场景样本。
- `aio-hub/docs/architecture/agent-tool-skill-integration.md`：Agent、工具调用和 Skill 的运行时分层与 VCP 调用闭环。

## 12. 调查边界

本篇关注“配置模型与角色能力”，没有把具体工具 registry 的每一个方法当作 Agent 配置字段逐项展开；工具的本地执行位置、文件权限和分布式 VCP 风险应以 [AIO-Hub-Agent工具调查笔记](../Agent工具/AIO-Hub-Agent工具调查笔记.md) 为准。内置预设也没有为每个 Agent 配置完整的工具清单，因此不能从角色名称推断它一定拥有某项工具能力。SillyTavern 兼容结论来自静态类型、编辑器和处理器核对，尚未使用一组真实 V2/V3 角色卡与世界书完成导入、编辑、运行、导出、再导入的往返测试。
