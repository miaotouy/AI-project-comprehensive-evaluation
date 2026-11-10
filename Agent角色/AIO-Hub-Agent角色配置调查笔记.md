# AIO Hub Agent / 角色配置调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：静态追踪 Agent 类型、编辑器、预设组合编译、存储与请求交接，核对开场白、角色卡、世界书与实时引用机制。未启动应用或执行交互测试
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

聊天侧边栏的“参数”页也是 Agent 配置入口：它编辑当前 ChatAgent，模型选择、采样参数、上下文限制/压缩和预设消息随角色持久化，后续其它会话引用同一角色时也会读取这些配置。

在 AIO Hub 中，一体化 Agent 预设的配置与编辑集中在一个 Agent 对象及其编辑器里：消息配方、模型与参数、知识、工具、变量、资产和显示规则都在其中。这里评价的是“一个 Agent 内能表达什么，以及用户能否在同一编辑流程里理解和切换”，不是社区资产数量。SillyTavern 的角色卡生态和兼容格式更成熟，但角色卡、推理 Preset、Prompt Manager、Advanced Formatting、World Info 和扩展字段分属不同层。

AIO 对酒馆角色卡的处理覆盖导入、编辑与运行时注入：当前快照有独立的世界书管理器、条目编辑器、导入导出服务和进入真实请求管道的 `worldbook-processor`。它实现的是一套可编辑、可绑定 Agent/User Profile、可条件激活并注入上下文的 **SillyTavern 兼容子集**。SillyTavern 仍领先于社区资产规模、扩展/事件协议和 World Info 全语义覆盖；差距落在生态与兼容完整度上，角色创作与世界书运行能力在 AIO 侧已经具备。

它的会话继承也不是单一的“快照”或“全局覆盖”：开场白在会话真正开始后固化，旧消息和旧回复保持不变；后续发送、续写与重新生成则读取 Agent 当前配置，并以新分支保存结果。这一混合语义偏向调试效率，允许用户在同一段历史上修改配置后立即重试比较。

需要区分两种对象：

- AgentPreset 是文件或内置资源中的模板，不包含具体 profileId、modelId。
- ChatAgent 是用户实际使用的实例，额外保存 id、profileId、modelId、创建时间和最近使用时间。

当前角色配置的几个关键机制是：

- **预设正文可组合**：一条消息可保存多个片段，每片段有可选择的正文版本，按顺序拼成一条模型消息。消息组控制“选哪条消息”，片段版本控制“这条消息由哪些正文组成”，两层身份独立（第 3 节）。
- **配置入口按作用域拆分**：完整编辑器把模型参数与上下文分为独立页面；聊天侧栏直接修改当前 Agent，完整编辑弹窗则先维护草稿。审批模型虽显示在角色编辑页中，保存作用域是全局（第 2、6 节）。
- **子智能体声明与调用授权分开**：`subAgentConfig` 声明当前 Agent 是否允许被调用、使用哪组模型绑定和嵌套深度；调用方是否能派发还受其工具配置约束（第 6.4 节）。
- **Agent 可由工具辅助编辑**：管理服务对 `toolCallConfig` 前缀的字段写入标记为需审批，最终是否交给人工还受仲裁模式约束。普通用户的编辑器保存采用另一条入口（第 6.5 节）。
- **知识访问与召回分开**：`knowledgeAccess` 授权资料访问，Recall 配置承担自动召回；创建与更新时剥离遗留知识字段。

总体链路为：编辑器或参数侧栏修改 Agent → 独立角色文件与列表索引持久化 → 后续请求读取当前角色 → 校验消息组、编译当前片段版本 → 交给宏、附件和上下文注入管道。历史生成消息保留既有内容，角色配方通常实时引用。

## 2. 配置入口与文件格式

### 2.1 内置预设的加载方式

预设登记文件 `src/config/agent-presets/index.ts` 只登记元数据：id、名称、描述、图标、分类、标签和 configUrl。完整配置按 ID 放在 `public/agent-presets/{id}/`，可附带 icon.jpg 和 assets/ 目录。加载器支持：

- `config.json`：适合字段较少的静态助手；
- `config.yaml`：适合多行 system prompt、角色扮演和复杂消息结构。

当前内置样本包括 code-assistant、creative-writer、translator 三个 JSON 预设，以及长门有希、凤凰院凶真、岸边露伴、坂田银时、智慧之王和艾尔德拉大陆等 YAML 角色/世界模拟预设。

### 2.2 编辑器实际分组

完整编辑器将配置分成十一页，页面归属也决定设置搜索如何定位目标：

| 页面 | 主要内容 |
|---|---|
| 基础设定、角色设定 | 身份与配置版本、用户档案、快捷操作、世界书、开场白与预设消息 |
| 模型参数 | 选择模型、采样、高级/自定义参数、模型特殊能力与安全设置 |
| 上下文 | 历史限制、压缩、后处理、缓存优化和图片压缩 |
| 功能扩展、会话变量 | 资产、虚拟时间、子智能体声明，以及变量定义 |
| 思绪、知识库 | Recall 召回绑定与 Knowledge 访问授权，各自独立 |
| 工具调用、环境增强 | 工具与审批策略、上下文扩展 |
| 输出与显示 | 分支发送、工具折叠、流式特效、媒体音量、正则、思考块与视觉指南 |

模型与上下文两页复用同一参数组件，按分组只展示本页设置。搜索项也会按当前模型能力过滤，选中后切换页面并滚动、高亮对应控件；模型专属选项的可见性由渠道支持信息和所选模型共同决定（[导航配置:48–245](<../../aio-hub/src/tools/agent-manager/components/agent-editor/agentEditConfig.ts#L48-L245>)、[模型配置页:58–91](<../../aio-hub/src/tools/agent-manager/components/agent-editor/sections/ModelConfigSection.vue#L58-L91>)、[搜索与定位:156–234](<../../aio-hub/src/tools/agent-manager/components/agent-editor/AgentEditor.vue#L156-L234>)）。

完整弹窗先把 Agent 配置复制到表单，保存时发出包含预设、模型参数、工具与子智能体等字段的更新。它与侧栏直接更新角色的方式有时间边界差异；资产物理文件变化另会触发静默保存（[弹窗保存:329–395](<../../aio-hub/src/tools/agent-manager/components/management/EditAgentDialog.vue#L329-L395>)、[资产变更绑定:344–354](<../../aio-hub/src/tools/agent-manager/components/agent-editor/AgentEditor.vue#L344-L354>)）。

### 2.3 聊天侧边栏也是 Agent 配置入口

LLM Chat 的右侧栏（LeftSidebar.vue，组件类名为 right-sidebar）有“智能体”和“参数”两个页签。切到“参数”页后，实际可直接修改：

- 当前 Agent 绑定的 profileId:modelId；
- 预设消息树（紧凑版 AgentPresetEditor）；
- ModelParametersEditor 中按模型能力筛选出的生成参数、上下文管理、上下文压缩、后处理、图片压缩、安全设置和思考/联网等特殊参数。

侧栏改动写入当前 Agent，作用域跨越当前会话。模型、参数和消息列表的双向绑定直接调用角色更新，内存随即生效，再进入按 Agent 排队的异步文件写入；新入口还可从磁盘刷新当前 Agent。已有单条消息保存另走修订比对路径，保存成功后才采纳落盘状态，避免用过期编辑覆盖其它位置的新选择。页签激活状态仍属于 UI，不写入角色文件（[侧栏绑定与刷新:64–155](<../../aio-hub/src/tools/llm-chat/components/sidebar/ParametersSidebar.vue#L64-L155>)、[消息保存:539–602](<../../aio-hub/src/tools/agent-manager/stores/agentStore.ts#L539-L602>)）。

需要特别区分“模型选择”和“模型定义”：侧边栏的模型选择只写 Agent 的 profileId、modelId；旁边的“编辑模型配置”按钮修改的是所选 LLM Profile 中的模型元数据，随后由 useLlmProfiles().saveProfile 写回 LLM 配置文件，不会把整个模型定义复制进 Agent。

## 3. 人格、消息与对话行为

### 3.1 基础身份

可配置字段：

| 字段 | 作用 |
| --- | --- |
| `name` | 内部名称，也用于宏替换；实例稳定标识另有 `id` |
| `displayName` | UI 显示名，可与内部 ID 不同 |
| `description` | 角色/助手简介 |
| `icon` | Emoji、图标路径或相对文件名 |
| `category` | `assistant`、`character`、`expert`、`creative`、`workflow`、`other` |
| `tags` | UI 筛选和分组标签 |
| `agentVersion` / `version` | 角色版本与配置格式版本 |

实例还可绑定 `userProfileId`，覆盖全局用户档案；模型实例使用 `profileId`（渠道/配置）和 `modelId`（模型）。这两个字段不在内置预设中固定，创建 Agent 时由用户选择。

### 3.2 `presetMessages`：核心人格载体

首次出现的 presetMessages 是 ChatMessageNode[]；每个节点还有 id、parentId、childrenIds、role、content、status 和 isEnabled。它可以表达：

| 类型 | 用途 |
| --- | --- |
| `system` | 角色设定、规则、知识和输出约束 |
| `user` / `assistant` | few-shot 示例、开场对话和角色口吻 |
| `chat_history` | 实际会话历史的插入锚点 |
| `user_profile` | 用户档案注入锚点 |
| `presetAttachments` | 引用 Agent 专属资产作为预设消息附件 |
| `groupId` | 把消息放进可整体开关的预设组 |

消息可以按数组默认顺序注入，也可以使用 `injectionStrategy`：

| 注入策略 | 插入行为 |
| --- | --- |
| `default` | 按默认上下文顺序 |
| `depth` | 相对聊天历史末尾按深度插入 |
| `advanced_depth` | 用 `N`、`N1,N2` 或 `S~I` 等语法在多个深度重复注入 |
| `anchor` | 相对于 `chat_history`、`user_profile` 等锚点前后插入，并用 `order` 排序 |

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

组状态在编辑、保存、导入与送模几个边界分别处理。编辑器关组时记住原启用成员，开组时恢复；角色保存会协调单选成员，选中新项时让同组其它成员失效。请求前再次按组校验：禁用组覆盖成员开关，启用的单选组若同时存在多条启用消息会报配置错误，避免双重注入。因此，外部写入造成的组/成员不一致也受到送模边界约束（[编辑器组状态:37–62](<../../aio-hub/src/tools/agent-manager/components/assets/presetGroupState.ts#L37-L62>)、[共享归一化:192–219](<../../aio-hub/packages/agent-preset-core/src/index.ts#L192-L219>)、[请求入口:216–258](<../../aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts#L216-L258>)）。

### 3.4 组合消息：片段与正文版本

组合消息在同一个预设节点内保存正文结构，而普通消息直接保存文本。每个片段具有稳定 ID、启停状态和一组正文版本；每片段最多选中一个版本，也可以留空。版本序号只用于界面展示，持久化选择依据 ID；这些版本属于正文备选项，与基础设定中的配置版本、消息组中的消息选择各有独立语义（[共享结构:1–31](<../../aio-hub/packages/agent-preset-core/src/index.ts#L1-L31>)）。

用户可直接新建组合消息，把普通正文转为初始片段，或选中一段正文提取可变片段。片段可排序、启停和增加/复制版本，编译预览按原样、换行或空行连接当前所选文本；转换回普通消息会先警告，再将当前选择展平，保存后丢弃其它版本。普通正文的选区落在宏内部时会扩展到完整宏，并要求确认（[消息转换:669–743](<../../aio-hub/src/tools/agent-manager/components/editors/PresetMessageEditor.vue#L669-L743>)、[组合编辑器:43–110](<../../aio-hub/src/tools/agent-manager/components/editors/PresetCompositionEditor.vue#L43-L110>)）。

单选消息组还有“转换为组合消息”入口：从组内文本提议共用前后缀和差异版本，由用户选择沿用哪条消息的角色、注入、匹配与附件设置。转换后将组合节点放在第一个成员位置、删除其它成员与原组；若原成员已经是组合消息，其内部备选版本只按当前正文展平。原消息变化会阻止套用转换；转换撤销仅在转换后没有其它修改时恢复本地快照（[转换预览:25–128](<../../aio-hub/src/tools/agent-manager/components/assets/PresetCompositionConversion.vue#L25-L128>)、[转换与撤销:604–651](<../../aio-hub/src/tools/agent-manager/components/assets/AgentPresetEditor.vue#L604-L651>)）。

送模先校验组状态，再按模型匹配筛选，随后编译组合正文，之后才检测工具宏、展开宏和解析附件。只有启用片段的当前版本参与拼接，未选版本留在角色配置中，不进入本次提示词；运行时另带来源片段/版本标识用于结构化编辑。结构错误会抛出配置异常，编译预览不会静默改写保存的原结构（[编译与物化:155–190](<../../aio-hub/packages/agent-preset-core/src/index.ts#L155-L190>)、[送模交接:218–254](<../../aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts#L218-L254>)）。

### 3.5 预设编辑器与保存边界

AIO 的预设能力不只体现在数据字段数量，还体现在编辑器把高阶字段组织成了可操作流程：

- 消息列表支持拖拽排序、分页、逐条启停、复制、复制到下方、粘贴覆盖和批量管理；
- 单条消息可设置显示名称、`system/user/assistant` 角色、所属消息组、模型/渠道匹配和四种注入策略；
- 内容编辑使用 Monaco，并提供编辑、宏处理后纯文本预览和 Markdown/富文本渲染预览三种模式；
- 工具栏可插入宏、会话变量和 Recall/知识库占位符（占位符编辑器为 RecallPlaceholderEditor，按集合 ID 配置），也能为消息选择 Agent 私有资产附件；
- 预设消息可独立复制或以 JSON/YAML 导入导出；普通消息使用 v2 的分组/消息包，包含组合正文时升级 v3 并声明所需结构特性，兼容导出可只保留当前编译文本；
- 导入 SillyTavern Prompt Preset 时先解析 system、injection 和 unordered prompt，再由选择对话框确认写入，不把来源字段直接摊到主编辑器中。

消息编辑器有保存与保留编辑快捷键，也提供保存后关闭。受保护草稿退出时可选择继续编辑、保存或丢弃；保存失败会保留草稿并显示原因。对于已有消息，聊天侧栏接入专门的保存回调：先比较内存原消息，再重读磁盘比较修订内容，合并其余并发字段后持久化。它保护单条消息编辑的过期覆盖；完整 Agent 弹窗先更新本地表单，仍需外层保存，其余角色字段的跨窗口事务由各自的保存路径分别处理，需另行检查（[草稿与保存:639–779](<../../aio-hub/src/tools/agent-manager/components/editors/PresetMessageEditor.vue#L639-L779>)、[角色消息提交:539–602](<../../aio-hub/src/tools/agent-manager/stores/agentStore.ts#L539-L602>)）。

## 4. 模型与输出偏好

### 4.1 模型参数

parameters 使用 LlmParameters，至少支持 temperature、maxTokens，默认模板还包含 topP、topK、frequencyPenalty、presencePenalty 等可选项。内置预设的取向如下：

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

参数界面已按所选模型及其支持元数据裁剪可见项。采样兼容与输出预算在请求侧另有规范化，角色参数是否显示、是否启用及最终如何发送需要分层判断；详细协议映射见[LLM 渠道管理](<../LLM渠道管理/AIO-Hub-LLM渠道管理调查笔记.md>)。工具配置的字段审批保护用于 Agent 经工具修改权限的路径，普通用户编辑保存及仲裁模式的边界见第 6.5 节。

### 4.3 模型参数编辑器的实际分组与语义

侧边栏和完整编辑器共用参数组件，但展示方式不同：侧栏保留折叠分组，完整编辑器将模型与上下文分为两页。两者复用模型上下文解析，读取渠道类型、模型 ID、能力、Token 上限与支持特性来决定可编辑范围。分组如下（[分组与可见性:25–115](<../../aio-hub/src/tools/agent-manager/components/parameters/parameterEditorConfig.ts#L25-L115>)）：

| UI 分组 | 主要字段 | 说明 |
| --- | --- | --- |
| 基础参数 | `temperature`、`maxTokens`、`topP`、`topK`、`frequencyPenalty`、`presencePenalty` | 采样和输出长度；`maxTokens` 会受模型输出上限约束 |
| 高级参数 | `seed`、`stop`、`maxCompletionTokens`、`logprobs`、`topLogprobs` | 只有 Provider/模型支持时才发送 |
| 上下文管理 | `contextManagement.enabled`、`maxContextTokens`、`retainedCharacters` | 发送前截断过长历史；这是截断上限，不是摘要压缩 |
| 上下文压缩 | `contextCompression` | 见下节 |
| 上下文后处理 | `contextPostProcessing.rules` | 合并 system、合并连续角色、角色交替等管道规则 |
| 上下文缓存优化 | `contextCacheOptimization` | 为自动注入等动态内容配置复用时间窗口，执行细节见请求上下文笔记 |
| 图片压缩 | `imageCompression` | 发送多模态图片前缩放，可保留原格式或转 JPEG/WebP |
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
| `countUnit` | `message` | 按消息条数计数，可切为 `user-turn` 用户回合 |
| `countThreshold` | `50` | 按当前计数单位计算的触发阈值 |
| `minHistoryCount` | `15` | 允许压缩前至少积累的单位数 |
| `protectRecentCount` | `10` | 本次压缩保护的最近单位数 |
| `compressCount` | `20` | 每次取最旧的多少个单位合并成摘要 |
| `countsByUnit` | 未设置 | 分别记忆两种计数方式的数量配置 |
| `summaryRole` | `system` | 摘要节点插入时使用的消息角色 |
| `summaryModel` | 未设置 | 可指定独立的摘要模型；缺省使用当前 Agent 模型 |
| `summaryTemperature` | `0.3` | 摘要生成随机性 |
| `summaryMaxTokens` | `4096` | 摘要输出上限 |
| `summaryPrompt` / `continueSummaryPrompt` | 空字符串 | 首次摘要/在既有摘要上续写的模板；空值使用内置模板 |

计数方式不仅改变阈值含义，也影响保护范围和每次压缩范围；旧配置缺少计数单位时沿用消息条数。字段与默认值见[压缩类型:384–445](<../../aio-hub/src/tools/llm-chat/types/llm.ts#L384-L445>)。压缩保留原消息，以摘要节点改变后续请求的有效历史；执行与分支语义见[请求上下文笔记](<../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md>)。保存 Agent 时，空值或等于内置模板的摘要提示词会被剥离，运行时再回退默认模板。

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
| 降级映射或兼容边界 | Before/After Char、AN、EM 等锚点会映射到 AIO 的消息结构，语义落在 AIO 自身的位置模型上；酒馆扩展事件、脚本协议和全部 World Info 字段本次未找到等价运行时 |

字段存在与界面可编辑之间还有几处落差，都需要真实 V2/V3 样本做往返验证，目前记为兼容风险：

- 标签过滤：`characterFilter.tags` 在类型和运行时都存在，当前编辑器只绑定 `names`；
- 概率开关：`useProbability` 会被运行时检查，界面主要暴露概率值；
- 键名归一化：导入读取 `key` 和 `keysecondary`，导出使用常见 ST 的 `keys` 和 `secondary_keys`；`character_filter` 的 snake_case 归一化也未见完整覆盖。

### 5.2 知识库与思绪（Recall/Knowledge 双域）

思绪页配置 Recall 自动召回，知识库页配置资料访问授权。两者都可跟随角色保存，授权资料库本身不会触发自动检索或目录注入。角色更新会剥离遗留知识字段，避免旧参数混入新访问模型。

| 配置 | 保存和执行交接 |
|---|---|
| `recallConfig` | 总开关、集合绑定、展示分组与缺少宏时的自动注入位置。集合 ID 是运行时目标，集合名仅供展示 |
| 每项 Recall 绑定 | 选择常驻、门控、回合或静态激活方式，配置数量/分数阈值与检索预设；产品级预设有算法型和综合型，旧画像字段作为迁移输入保留 |
| `recallSettings` | 默认检索设置、总字符预算、结果/空结果模板、门控扫描深度与缓存偏好 |
| `knowledgeAccess` | 授权当前角色可访问哪些 Knowledge 资料库，访问与自动召回分离 |
| 迁移诊断 | 保留旧配置无法直接映射的字段和值，供编辑与恢复流程查看 |

Recall 的正文入口为 `{{recall}}` 宏或 `【recall::...】` 占位符；旧知识占位符只作废弃识别和告警。绑定字段见[Recall 类型:95–150](<../../aio-hub/src/tools/agent-manager/types/agent.ts#L95-L150>)，检索和注入过程见[请求上下文笔记](<../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md>)。

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

默认工具配置是关闭总开关、关闭新工具默认启用和自动批准、最大迭代 20、超时 30 秒、串行执行、VCP 协议。创建 Agent 后不会因为存在工具注册表就自动获得全部工具，需要显式打开 Agent 配置和相应工具。

### 6.3 工具来源与边界

工具并不只来自固定内置列表：内建 ToolRegistry、动态注册工厂、Skill、插件代理和远端 VCP 工具都可以进入同一注册表。模型只能看到标记为 agentCallable 的方法；执行器还会在实际调用前再次校验工具、方法和可调用标记。

当前模型通信协议实现只有 VCP 文本协议：工具定义注入 system prompt，模型回复中输出 `<<<[TOOL_REQUEST]>>>` 块，执行结果再以工具结果消息回注。架构上 ToolCallingProtocol 留出了替换协议的接口，但 ToolCallConfig.protocol 目前没有其他可选值。

### 6.4 子智能体配置（`subAgentConfig`）

功能扩展页的“允许被调用”控制当前 Agent 是否可作为后台协作目标，默认关闭。开启后，可选择跟随父会话模型或使用自身模型，设置 1–3 层最大派发深度（缺省 1），并选择是否仅子智能体侧可见。后者隐藏主聊天列表中的专项角色，智能体管理与子任务目标仍可访问；内置基线标识独立保存（[配置声明:220–263](<../../aio-hub/src/tools/agent-manager/types/agent.ts#L220-L263>)、[编辑入口:268–309](<../../aio-hub/src/tools/agent-manager/components/agent-editor/sections/CapabilitiesSection.vue#L268-L309>)）。

这些字段声明“谁可被调用、被调用时如何绑定”；调用方能否派发还取决于其工具启用和方法权限。深度限制由子任务执行端读取并夹在全局上限内。角色配置和工具能力共同形成授权边界，单独勾选目标角色的“允许被调用”不会给调用方增加工具（[子任务列表过滤:533–549](<../../aio-hub/src/tools/sub-agent/sub-agent.registry.ts#L533-L549>)、[深度检查:280–304](<../../aio-hub/src/tools/sub-agent/sub-agent.registry.ts#L280-L304>)）。

模型偏好采用显式分支：跟随模式读取父请求的渠道/模型，自身模式读取目标 Agent 的引用，选定的一组必须存在于启用渠道和模型列表中。UI 提示“自身失效自动回退父模型”，当前解析器实际直接报错；渠道内部的故障转移由渠道管理承担，与两组绑定之间的回退不同（[模型解析:14–32](<../../aio-hub/src/tools/sub-agent/services/subAgentModelResolver.ts#L14-L32>)、[提示文案:282–289](<../../aio-hub/src/tools/agent-manager/components/agent-editor/sections/CapabilitiesSection.vue#L282-L289>)）。执行生命周期见[Agent 工具笔记](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)。

### 6.5 AI 自动审批：角色策略与全局模型

工具调用页分“工具配置”和“AI 自动审批”两个子页，工具总开关控制这一区域。角色级策略实际保存在 `toolCallConfig.decisionArbitration` 内，随角色保存；全局审批模型组件虽嵌在同页，却独立保存并立即供所有启用仲裁的角色使用。只取消角色弹窗不会撤回已保存的全局模型配置（[工具页:523–641](<../../aio-hub/src/tools/agent-manager/components/agent-editor/sections/ToolCallingSection.vue#L523-L641>)、[全局模型保存:85–115](<../../aio-hub/src/tools/tool-calling/components/ApprovalModelSettings.vue#L85-L115>)）。

| 配置所有者 | 保存内容 | 作用域与界面 |
|---|---|---|
| 当前 Agent | 启用状态、灰区/激进模式、JEV 风险/意图/置信阈值、外部来源是否可自动批准 | 跟随角色文件；JEV 阈值在该引擎下显示，普通 LLM 使用离散风险与授权评估 |
| 全局审批模块 | JEV/普通 LLM 引擎、模型引用、超时、重试与普通 LLM 补充审批规则 | 独立的审批渠道文件；切换引擎会清空模型引用，并设置对应默认模型名/超时 |

灰区模式跳过安全策略强制审批的自动仲裁，激进模式允许这类请求进入更严格判断。自动批准、自动拒绝与升级人工的执行规则见[Agent 工具笔记](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)，角色配置中的阈值只作为仲裁输入，独立权限屏障由决策仲裁层承担（[策略与默认值:136–187](<../../aio-hub/src/services/decision-arbiter/types.ts#L136-L187>)、[全局持久化:32–68](<../../aio-hub/src/services/decision-arbiter/channelConfig.ts#L32-L68>)）。

**开关状态的接线差异。** 页面用“仲裁对象存在”表示开关开启，打开时复制默认对象；默认对象中的 `enabled` 却为 false。执行端检查该字段，因此仅创建默认对象仍不会触发模型仲裁。修改模式或阈值也未在该页同步把它设为 true；外部配置或工具写入显式启用值时，才满足执行端开关条件。该差异来自当前静态接线，实际交互表现尚未运行验证（[UI 开关:120–132](<../../aio-hub/src/tools/agent-manager/components/agent-editor/sections/ToolCallingSection.vue#L120-L132>)、[默认对象:154–163](<../../aio-hub/src/services/decision-arbiter/types.ts#L154-L163>)、[执行检查:209–225](<../../aio-hub/src/services/decision-arbiter/index.ts#L209-L225>)）。

**工具辅助编辑的安全策略。** 管理工具给 `toolCallConfig` 前缀的字段写入标记为需审批，注释描述为不可被自动批准绕过的本地确认；实际激进仲裁仍可处理强制审批请求，最终结果依赖仲裁配置与判断。普通用户的角色保存路径直接提交表单，这个工具安全钩子的作用范围限于管理工具的字段写入路径（[字段策略:103–130](<../../aio-hub/src/tools/agent-manager/services/agentManagementService.ts#L103-L130>)、[仲裁强制审批处理:250–255](<../../aio-hub/src/services/decision-arbiter/index.ts#L250-L255>)、[表单保存:329–391](<../../aio-hub/src/tools/agent-manager/components/management/EditAgentDialog.vue#L329-L391>)）。

## 7. 资产、变量与环境增强

### 7.1 Agent 专属资产

assetGroups 和 assets 允许为一个 Agent 管理图片、音频、视频和文件。资产字段包括：

| 字段 | 作用 |
| --- | --- |
| `id` | 宏引用用的 handle |
| `path`、`filename`、`type` | 物理位置、文件名与媒体类型 |
| `description`、`group`、`usage` | 描述、分组与用途，usage 取 `inline` 或 `background` |
| `autoplay`、`loop`、`muted` | 音视频自动播放、循环与静音 |
| 封面和样式选项 | 音视频封面图与展示样式 |

预设消息可用附件引用这些资产，也可在内容中使用 `agent-asset://{group}/{id}.{ext}`。资产随 Agent 导入导出，可选择放入 ZIP/文件夹或 PNG 内嵌包。

资产管理器支持缩略图引用、单项及批量描述生成；描述写回当前资产元数据，用于后续引用和提示词说明。描述请求读取独立转写配置中的媒体模型，按媒体能力校验，与 Agent 的对话模型选择分开。生成结果仅在资产身份和原描述仍与任务快照相符时合入编辑草稿，用户同时手改描述会使旧结果跳过；物理文件增删另走资产变更保存路径（[描述绑定:101–167](<../../aio-hub/src/tools/agent-manager/services/agentAssetDescriptionService.ts#L101-L167>)、[结果合入:635–653](<../../aio-hub/src/tools/agent-manager/components/assets/useAgentAssetsManager.ts#L635-L653>)）。

### 7.2 输出样式的角色覆盖

输出与显示页可为角色选择流式文字特效，默认跟随全局；另有工具卡默认折叠、媒体音量和视觉输出指南。角色文件保存样式偏好，渲染端仍受全局动画开关和系统减少动态效果偏好约束。它们影响显示方式，工具权限和模型能力由各自配置负责（[角色特效入口:58–77](<../../aio-hub/src/tools/agent-manager/components/agent-editor/sections/OutputDisplaySection.vue#L58-L77>)）。

### 7.3 会话变量

variableConfig 用于定义会话变量及其约束；配置向导说明可通过 `{{getvar::path}}` 和 `{{setvar::path::op::value}}` 读取、更新。它适合保存角色扮演中的状态、任务进度或用户偏好，但变量的具体 schema 由 sessionVariable.ts 定义，不应把它当作模型长期记忆。

### 7.4 虚拟时间线

virtualTimeConfig 可设置虚拟基准时间、现实基准时间和 timeScale。启用后，{{time}}、{{date}}、{{datetime}}、{{shichen}} 等宏按虚拟时间计算。艾尔德拉大陆预设将虚拟时间设为圣历 1024 年，并把流速设置为现实的 2 倍，用于驱动世界模拟中的昼夜、商店和事件节奏。

### 7.5 扩展与快捷操作

extensionConfig 提供 Agent 级扩展总开关、按扩展 ID 的开关以及新扩展默认状态；quickActionSetIds 关联快捷操作组。它们是环境/交互能力的入口，具体工具是否可用另由工具级配置与仲裁决定。

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

用户创建或修改的 Agent 采用分离式文件存储，内存状态通过以下路径写入角色文件：

1. 普通角色更新先修改内存状态，再按角色 ID 串行排队写入；写入前协调单选消息组，落盘时读取最新内存快照；
2. 存储层将角色配置写入 `agent-manager/agents/{agentId}/agent.json`，并维护 `agent-manager/agents-index.json` 中的列表展示元数据；
3. 已有单条预设编辑使用可等待的专用保存路径，比较内存与磁盘修订后先落盘再合入最新状态，冲突会明确报错并留住编辑草稿。

前两步的普通保存返回时，文件写入可能仍在队列中，不能把侧栏的成功提示等同于磁盘写入完成；单消息专用路径的可等待性也未扩展为所有角色字段的事务保证（[普通更新:315–340](<../../aio-hub/src/tools/agent-manager/stores/agentStore.ts#L315-L340>)、[排队持久化:698–719](<../../aio-hub/src/tools/agent-manager/stores/agentStore.ts#L698-L719>)）。

实际根目录由 getAppConfigDir() 决定（Tauri 的 AppData 目录，支持便携模式），所以笔记中的 agent-manager/... 是相对于应用配置目录的路径。Agent 资产也放在对应目录，配置中的 icon 等字段可以用相对文件名或 appdata://agent-manager/agents/... 引用。资产存储路径已从旧 llm-chat/agents/ 统一迁移到 agent-manager/agents/；useAgentStorage 通过版本化数据迁移（cross-module-v2，runVersionedDataMigration）补充复制旧目录、校验目录子集与迁移标记，迁移完成后经通知中心发送成功通知；跨会话搜索的 Agent 目录也随之改为 agent-manager/agents/（会话与消息管理笔记 5.1）。

这解释了为什么侧边栏看起来像“设置”，但内容仍属于角色配置：侧边栏只是编辑入口，持久化边界由 ChatAgent 文件决定。导出 Agent 时，parameters（包括模型参数、上下文限制、压缩和图片压缩）会随配置导出；本地实例字段 id、profileId、创建/使用时间的处理仍遵循导出格式定义。

### 9.2 与 LLM Profile 配置的边界

Agent 文件只保存所选渠道和模型的引用（profileId、modelId）以及 Agent 级参数。渠道的 API 地址、密钥、请求头、模型列表和模型能力元数据由独立的 LLM Profile 配置管理。侧边栏“编辑模型配置”修改后调用 saveProfile 写回 Profile 存储；删除或更换 Profile 可能使 Agent 的引用失效，需要重新选择模型。不要把 Agent 的 parameters.temperature 等采样参数与 Profile 中的模型元数据混为一谈。

“编辑模型配置”弹窗修改的是模型条目本身，例如模型 ID/显示名/分组/图标/描述、输入上下文和输出 Token 上限、模型能力（文本/图片/音频/视频、联网、思考模式）、思考等级选项、默认后处理规则、模型专属参数规则及价格元数据。这里的 tokenLimits 和 capabilities 会反过来约束 Agent 参数侧边栏可显示的控件和滑块上限，但它们不属于 Agent 的 parameters。

Agent 导出结构 AIO_Agent_Export 会剥离本地实例字段（id、profileId、创建/使用时间），保留大部分配置。导出选项可包含：

- JSON 或 YAML 配置；
- Agent 资产；
- 关联世界书，选择独立文件或内嵌内容；
- ZIP、文件夹、单文件或带数据的 PNG 包。

包含组合正文的 Agent 导出采用外层 v2 并声明 `preset-composition-v1`，普通 Agent 包仍为 v1。独立预设包则分别使用 v3/v2，两者的外层格式版本有独立意义。导入会校验组合结构，清空持久化的编译正文，并规范组状态；兼容展平导出只保留当前选择的文本，重导入无法恢复其它版本（[Agent 导出:166–183](<../../aio-hub/src/tools/agent-manager/services/agentExportService.ts#L166-L183>)、[独立预设导出:80–105](<../../aio-hub/src/tools/agent-manager/components/assets/usePresetImportExport.ts#L80-L105>)、[Agent 导入:61–71](<../../aio-hub/src/tools/agent-manager/services/agentImportService.ts#L61-L71>)）。

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

| 配置项 | 内容 |
| --- | --- |
| 基础字段 | `name`、`description`、`icon`、`category`、`tags` |
| 人格消息 | 一条明确的 `system` 预设消息 |
| 对话锚点 | `chat_history`，必要时加入 `user_profile` |
| 口吻示例 | 需要稳定口吻时，加入 1 至 3 组 user/assistant 示例 |
| 采样参数 | 设置合适的 `temperature` 和 `maxTokens` |

如果目标是创建一个“Agent”，再按需求增加：

- 工具调用总开关、工具/方法白名单和审批策略；
- 知识库绑定与召回阈值；
- 世界书或会话变量；
- 资产与视觉化输出指南；
- 虚拟时间和分支交互。

最重要的边界是：**提示词决定角色怎么说，工具/知识/资产/运行时字段决定它能接触什么；visualGuideline 只指导输出形式，不自动扩大系统权限。**

## 11. 主要源码依据

- [Agent 类型](<../../aio-hub/src/tools/agent-manager/types/agent.ts>)：角色字段、子智能体、工具策略与资产契约。
- [完整编辑器](<../../aio-hub/src/tools/agent-manager/components/agent-editor/AgentEditor.vue>)、[编辑弹窗](<../../aio-hub/src/tools/agent-manager/components/management/EditAgentDialog.vue>)、[聊天参数侧栏](<../../aio-hub/src/tools/llm-chat/components/sidebar/ParametersSidebar.vue>)：草稿编辑、角色提交与直接绑定。
- [预设列表编辑器](<../../aio-hub/src/tools/agent-manager/components/assets/AgentPresetEditor.vue>)、[消息编辑器](<../../aio-hub/src/tools/agent-manager/components/editors/PresetMessageEditor.vue>)、[组合正文编辑器](<../../aio-hub/src/tools/agent-manager/components/editors/PresetCompositionEditor.vue>)：分组、片段版本、转换、预览与草稿保护。
- [预设共享核心](<../../aio-hub/packages/agent-preset-core/src/index.ts>)、[结构撤销](<../../aio-hub/packages/agent-preset-core/src/structureUndo.ts>)：校验、编译、来源映射、宏边界和撤销。
- [角色存储](<../../aio-hub/src/tools/agent-manager/stores/agentStore.ts>)、[文件存储](<../../aio-hub/src/tools/agent-manager/composables/storage/useAgentStorage.ts>)：串行写入、单消息修订比较与列表索引。
- [Agent 导入](<../../aio-hub/src/tools/agent-manager/services/agentImportService.ts>)、[Agent 导出](<../../aio-hub/src/tools/agent-manager/services/agentExportService.ts>)、[预设导入导出](<../../aio-hub/src/tools/agent-manager/components/assets/usePresetImportExport.ts>)：外层格式、结构特性与兼容展平。
- [注入组装器](<../../aio-hub/src/tools/llm-chat/core/context-processors/injection-assembler.ts>)、[开场白服务](<../../aio-hub/src/tools/llm-chat/services/greetingService.ts>)、[发送入口](<../../aio-hub/src/tools/llm-chat/composables/chat/useChatHandler.ts>)、[执行配置合并](<../../aio-hub/src/tools/llm-chat/composables/chat/useChatExecutor.ts>)：角色配置进入会话与请求的交接。
- [世界书类型](<../../aio-hub/src/tools/st-worldbook-manager/types/worldbook.ts>)、[详情编辑](<../../aio-hub/src/tools/st-worldbook-manager/components/WorldbookDetail.vue>)、[运行处理器](<../../aio-hub/src/tools/llm-chat/core/context-processors/worldbook-processor.ts>)：兼容字段、UI 覆盖与激活注入。
- [配置向导](<../../aio-hub/src/config/agent-presets/agent-config-wizard.ts>)、[内置预设目录](<../../aio-hub/public/agent-presets/>)：角色模板与场景样本。

## 12. 调查边界

角色配置、工具执行和渲染效果分属不同层。本篇追踪到配置持久化与送模交接，工具执行、文件权限和分布式 VCP 边界见[Agent 工具笔记](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)；内置角色名称只能说明预设意图，实际能力由本地绑定决定。

尚未运行验证的事项包括：组合消息跨窗口同时编辑及磁盘冲突、转换与撤销往返、快捷键和退出保护、资产批量描述与缩略图、审批开关实际界面表现、子智能体失效模型绑定，以及真实 V2/V3 角色卡与世界书的导入—编辑—执行—导出往返。代码可确认入口、字段、校验和事件交接，显示质量与平台行为仍需在 Tauri 环境观察。
