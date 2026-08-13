# AI 客户端完整体验栈与模块组合构想

> 对比对象：`AIO Hub`、`AstrBot`、`Chatbox`、`Cherry Studio`、`DeepChat`、`Hermes Agent`、`Jan`、`LobeHub`、`Manifold Desktop`、`NextChat`、`Open WebUI`、`OpenCode`、`Pi`、`SillyTavern`、`VCPChat`、`VCPToolBox`
>
> 对比更新日期：2026-08-13
>
> 依据：各单项目调查笔记（Agent 工具、Agent 角色、Chat、LLM 渠道管理、仓库分布、消息渲染器、生成式输出与运行时类目）及横向对比
>
> 对比方法：先从十六个项目中提炼尚无人完整实现的能力空白，再反推产品形态；组合方案属于设计推导，不表示任一项目已经完整实现
>
> 对比范围：本地优先的桌面 AI 客户端，覆盖会话壳、生成式输出与运行时、多 Provider、Agent 角色、上下文编排、工具与安全；不覆盖云端多租户计费、组织管理和 IM 平台适配
>
> 文档定位：从既有调查中抽象完整客户端的特色能力层，作为新客户端的产品构想与架构决策输入；事实证据见各横向对比文档，本文不重复引用

## 产品定位

面向重度使用者的本地 AI 工作台，目标用户同时从事角色扮演、长项目维护、多模型调度和 Agent 自动化——他们已经被迫在 SillyTavern、OpenCode、VCPChat 和 Hermes 之间手动切换，因为没有一个工具把这四种工作模式放在同一个可信运行环境里。

核心承诺：**模型生成的东西可以持续存在、被操作、被维护，而不是每次都从一段文字重新开始。**

## 结论摘要

十六个项目各有机制上的独到之处，但没有一个在"消息即运行时""对象跨轮次持续""语义渠道路由""角色即可移植生态"和"后台认知与记忆演化"这五个维度上同时做到。这五件事是当前市场的真实空白，也是下一个客户端值得存在的理由。

基础设施层（会话壳、Composer、持久化、取消链）已有多个项目提供了可组合的参考实现。本文以空白能力为主体，把基础设施降格为支撑条件，把安全降格为兜底约束，不让两者反客为主。

## 一、五个特色能力层

以下五项是调查范围内无一项目完整实现、但各项目已有可组合原型的能力。它们是本构想的主体，其余模块均为支撑。

### 1. 消息即运行时

**当前空白**：AIO Hub 和 VCPChat 各自把消息推进到可执行运行时，但前者的 canvas 错误无法回到主 Agent，后者把模型脚本放在主页面；LobeHub 的 conversation-flow 是最干净的声明式方案，但缺乏跨工具状态和取消语义。没有任何项目同时做到：消息内组件由宿主原生渲染（不执行模型脚本）、工具状态驱动组件生命周期、审批卡是一次性 token 而非前端布尔值。

**组合逻辑**：

- 正文走 AIO 的 stable/pending AST + keyed Patch，尾部收口用权威全文替换；运行时状态（DOM 焦点、动画帧）在稳定区内不被清除。
- 声明式交互组件（流程节点、工具状态、选择器、候选回复切换条）由宿主按注册表原生渲染，对应 LobeHub 的 conversation-flow 思路；模型 payload 只声明意图，不直接触发 handler。
- 需要任意 HTML/CSS/JS 的内容进入独立 Artifact realm（opaque origin，无 preload，禁直接宿主 API），对应 VCPChat 的能力目标但替换运行域。
- `MessagePart` 生命周期：`discovered → streaming → stable | waiting → approved/denied → completed | failed | cancelled`；每个 part 有稳定 ID、renderer 类型和可用动作集合，重启和重放产生同一组 parts。

**用户体验**：审批卡不会因刷新消失；工具失败后直接在时间线上重试；候选回复在同一消息气泡内切换不产生新消息；Artifact 里的计时器不会因消息列表滚动被清除。

### 2. 对象跨轮次持续

**当前空白**：VCPChat 的桌面挂件最接近 G5（独立 ID、文件持久化、模型 create/replace/query），但 widgetFS 桥接方法是宽能力模型，缺少版本和权限档位。OpenCode 的文件工作区闭环最干净，但没有用户可见的对象列表和状态面板。LobeHub 的文档是最强的结构化 G4，但 ArtifactDeploymentActions 是空桩。VCPChat 新增的 Scriptorium 文坊是样本中第一个“按对象身份继续修改”的通道（Agent 以可审阅 PR 提交到既有 VDOC 工程，文脉带版本与审批语义），但合并仍是整份 source 替换 + 人工裁决，没有定向 patch、运行状态读取（只有 GetVisualContext/GetViewportSource 层面的感知）或能力档位。没有任何项目实现：模型可以列举当前活动对象、读取其运行状态、定向 patch 同一对象。

**组合逻辑**：

- 对象注册表：每个 Artifact/文档/工作区文件在 Host 层有稳定 `objectId`、类型、来源消息、当前 revision、能力档位（`prose / active / trusted`）和生命周期状态。
- 三档能力：`prose`（静态渲染，无脚本）、`active`（独立 realm 内脚本，可选网络，无宿主原生 API）、`trusted`（版本化 runtime SDK，可请求文件/工具/会话事件，每项仍由宿主校验）。
- 文件工作区事实源对应 OpenCode/Cherry：工具调用落 SQLite Part，文件系统是工作区，影子 Git 记录回合快照，模型通过 read/glob/grep 再次读取。
- 文档对象对应 LobeHub：DB 行 + Redis 编辑锁 + 节点级寻址 + diff 逐项接受/拒绝 + saveSource 区分 llm_call；但 ArtifactDeploymentActions 必须真正落地。
- 模型上下文回流：下一轮请求前自动注入对象列表摘要（id/type/status/lastModified）；`trusted` 档对象可提供 `serializeState()` 接口。

**用户体验**：用户说"继续改那个表格"，模型不需要重新生成；桌面挂件在用户再次打开应用后恢复运行状态；文档编辑冲突在界面上明确标出而不是静默覆盖。

### 3. 语义路由与渠道自愈

**当前空白**：调查的十六个项目均记录了成本、延迟和配额数据，但无一项目让这些数据真正参与选路。Hermes 是唯一实现跨 Provider failover 的项目，但路由决策基于失败触发，不是任务语义。VCPToolBox 的语义虚拟模型（自然语言 description 做向量余弦相似度选模）是唯一的语义选路原型，但没有健康感知和成本约束。AIO 的 Key 状态机持久化是最完整的 Key 层健康管理，但不影响模型选择（AIO 已落地渠道内的模型执行路由 `resolveModelExecution`——模型→协议/端点选择；仍不跨渠道改选，成本/延迟数据依旧不参与选路）。

**组合逻辑**：

- 四层失败分离（照搬 Hermes）：同请求重试 → Key 轮换 → 同 Provider 模型 fallback → 跨 Provider failover；每层记录不同事件，分配不同预算，声明流开始后是否可安全重放。
- 语义路由（照搬 VCPToolBox 原理，加约束）：每个 Agent 可声明任务类型标签（coding/roleplay/search/summarize/multimodal），每个 Provider 实例可声明适配标签和成本/延迟基线；路由器按余弦相似度 + 实时健康分 + 预算约束打分，结果写入 `RouteDecisionEvent`（候选链、实际模型、分数、路由原因）。
- Key 健康状态机（照搬 AIO Hub）：每个 Key 有 `active/cooling/exhausted/dead` 状态，按 429/503/401 响应转换；状态持久化到 SQLite，重启后不重置。
- 配额门控：每个 Provider 实例可设置每日 token 预算上限和成本上限；超限时路由器降级到其他 Provider 而不是静默失败。
- 成本/延迟感知选路：路由器在用户可设置的"优先成本"/"优先延迟"/"优先质量"三个策略下，把实时健康分和历史分位数纳入评分；策略变更记录审计事件。

**用户体验**：角色扮演任务自动路由到延迟低的廉价模型；编码任务路由到工具能力强的模型；某个 Key 触发 429 时无感切换，不打断当前会话；月度预算快用完时提前警告而不是在关键时刻失败。

### 4. 角色即可移植生态

**当前空白**：SillyTavern 有最成熟的角色卡生态（PNG/CharX/BYAF + Character Book）、传统角色扮演工作流和完整 World Info/扩展协议，但角色内部没有字段级继承，角色卡、推理 Preset、Prompt Manager 与 Advanced Formatting 分离。AIO Hub 的 Agent 包格式最全面（ZIP/JSON/YAML/PNG 四种），也是当前样本中最完整的一体化预设编辑原型：消息可按模型和注入位置配置，还能组成多选组、单选组并使用组级总开关。AIO 对 ST 世界书的支持已覆盖独立编辑、导入导出和实际条件注入运行时，不只是格式转换；部分扩展字段仅保留/编辑或降级映射，因此仍是可执行子集。它对进行中会话采用有意的实时引用，修改 Agent 后可基于同一历史立即重新生成做对比；开场白则在首次发送后固化。真正缺少的是可见的绑定模式、完整配置 revision 和可复原的生成快照，而不是“旧会话必须永远不受修改影响”。Hermes 的 Profile 包（config/SOUL.md/skills/记忆）是最完整的"可迁移运行环境"，但 personas 字段无导入承载（人格选择收敛为 `display.personality` 权威名称 + 单一所有者渲染模块，仍是命名模板而非版本化实体）。没有任何项目同时支持角色 prompt 版本 diff、跨角色字段级继承、显式 live/pinned 绑定、可追溯行为 A/B 测试和注入内容的分段 token 预算。

**组合逻辑**：

- 角色实体分层（吸收 Chatbox/Jan 的快照思路 + Hermes 的 Profile 结构）：
  ```
  AgentTemplate（可共享，有 revision history）
    ├─ PersonaRevision      身份/语气/开场/示例，有 git-style diff
    ├─ ContextRecipeRef     提示词配方引用（见第五节）
    ├─ CapabilityPolicyRef  工具/MCP/Skill 与审批模式
    ├─ KnowledgePolicyRef   知识库与召回规则
    └─ MemoryPolicyRef      读写权限/命名空间/压缩策略
  ```
- 会话绑定显式区分两种模式：`live` 每次执行读取 Agent 当前 revision，服务于 AIO 式同历史即时调试；`pinned` 固定 `AgentRevisionSnapshot`，服务于长期会话复现。两种模式都不能隐式切换，且每个生成节点记录实际 revision、ContextRecipe 编译 hash 和请求参数。
- 角色字段级继承（填补全局空白）：角色 B 可声明 `extends: A`，只覆盖差异字段；编译器在运行时展平，用户界面显示继承链。
- `ContextRecipe` 保留 AIO 的可操作消息配方：每个 block 可独立启停、声明 role/anchor/depth/model match；多个 block 可组成 `multi` 或 `single` 选择组，并有组级开关。组状态直接参与编译，不依赖 UI 把状态回写到各成员。
- 生态资产格式统一入口（对应 SillyTavern/AIO Hub 的社区生态）：PNG/JSON/CharX/AIO ZIP/LobeAgent JSON 在导入时一次性编译为内部 IR；外部格式只在导入层存在，不进入主存储和运行时契约。
- 版本化 runtime SDK 允许角色在 `trusted` Artifact 内查询和修改自身的 MemoryPolicy（对应 VCPToolBox AgentDream 的能力目标，但写入须经过 gate）。

**用户体验**：把 SillyTavern 角色卡拖进来，World Info 条目转换为 ContextRecipe 中的 `match` 触发 block；用户可以在聊天侧栏将“叙事视角”设为单选、将“文风修饰”设为多选，并一键关闭整组背景规则；调试会话使用 `live` 模式，修改人格后直接在同一用户消息上重新生成并并排比较，旧回复不会消失；长期剧情会话使用 `pinned` 模式，除非用户主动迁移 revision，否则行为保持不变。

### 5. 后台认知与记忆演化

**当前空白**：VCPToolBox 的 AgentDream 梦系统是唯一让 Agent 在非对话时段自主整理记忆的实现（从知识库抽种子 → 语义关联碎片 → 生成叙事 → 管理员审批后执行）。Hermes 的 compaction-as-fork（压缩生成新 session_id + lineage_root_id，稳定跨轮转）是唯一保留谱系的压缩实现（Hermes 新增 gpt-5.6 直连 OpenAI 路由的 native 服务端压缩，本地 compaction-as-fork 保持为回退，谱系语义不变）。但两者均不能在后台任务中感知对象运行状态，也没有预算约束和显式取消语义。

**组合逻辑**：

- `BackgroundJob` 实体：每个任务有类型（memory_consolidation/compaction/scheduled_agent/cron）、预算（token上限、时间上限）、触发条件（时间/事件/用户授权）、取消令牌和审计尾。与前台 Agent Loop 完全分离，不共用同一个对话上下文。
- 记忆整理（照搬 AgentDream 架构，加门控）：非对话时段，Agent 可提交 `MemoryWriteProposal`（合并/删除/感悟）；所有操作生成 JSON 索引后进入审批队列；默认需要用户审批，可配置为自动批准低风险操作（如去重合并）但高风险操作（如删除）始终需要人工。
- compaction-as-fork（照搬 Hermes）：压缩时生成新 session_id + lineage_root_id；原始 transcript 通过 lineage 仍可寻址；压缩摘要保存为带 `compaction_revision` 标签的 summary block，记录覆盖范围。
- 定时 Agent（照搬 Hermes cron）：用户可以为 Agent 设置 cron 计划，在空闲时段执行；执行结果落 BackgroundJob 日志，不自动注入主会话（除非用户选择"同步到会话"）。
- 子 Agent 真实会话（照搬 Hermes 子代理是真实子会话）：后台子 Agent 有独立 session_id，与父 session 通过 lineage 关联；子 Agent 的工具调用走独立审批链，不继承父 session 的审批状态。

**用户体验**：用户睡觉时 Agent 自动整理记忆，早上看到"有 12 条记忆整理提案，待审批"；长会话压缩后仍能从历史谱系中找到三周前的某条工具调用；可以为"每天早上总结新闻"设置一个定时 Agent，结果作为卡片出现在下次打开应用时。

## 二、体验骨架

特色能力需要一套骨架才能让用户触达。骨架不是目的，但缺了它五项特色能力无处落地。

### 会话壳

侧栏承载工作区/项目/Agent/最近活动/搜索导航；会话头部常驻显示 Agent revision、绑定模式（live/pinned）、Provider/model、上下文占用、生成状态和权限摘要——这些不能藏在设置页里。主视图保持对话连续性，Context Inspector、工具时间线、对象面板放入可折叠侧栏，不把调试信息塞进消息气泡。

同一会话可在"聊天/研究/编码/角色扮演/工作台"之间切换投影，不切换事实源；模式差异体现在 Composer、渲染器和可用工具上。

### Composer

typed input parts（文本/图片/文件/语音/结构化字段）；发送前展示将使用的 Context block 列表、预计 token 占用和需要审批的动作；记忆/知识/World Info 触发开关直接在工具栏，不要求用户手写注入语法；草稿/队列/停止/重试/分支一键可达。

### MessagePart 渲染注册表

渲染器消费事件流，不等完整字符串。正文走 stable/pending AST + keyed Patch；工具/审批/候选/流程节点/Artifact 入口卡由专用 renderer 处理；对象实际内容（文档、文件树、挂件预览）承载在右侧对象面板，消息气泡只放入口卡片。

| Part | 必须支持的操作 |
|---|---|
| `text / reasoning` | 复制、编辑、引用、折叠；reasoning 不混入正文 |
| `tool-call / tool-result` | 查看参数、审批/拒绝、取消、重试；结果可展开原文和重新注入 |
| `approval` | 允许/拒绝/修改范围；一次性 token，刷新后不消失 |
| `candidate-group` | swipe、保留候选、从候选创建分支 |
| `conversation-flow` | 暂停、跳过、继续、回放 |
| `artifact` | 对象面板入口（类型/状态/能力档位/全屏/导出/能力升级） |
| `error` | 重试、切换渠道、复制诊断、恢复会话 |

## 三、核心事实模型

### Provider 实体

```text
ProviderPreset -> ProviderInstance(adapterFamily, endpoints, authRef)
  -> CredentialPool(keyRef[], health[active/cooling/exhausted/dead], policy)
  -> ModelCatalog(capabilities, costBaseline, latencyP50)
  -> TaskProfile(semanticTags, preferredFor)
```

Key 健康状态机按 429/503/401 响应转换，持久化到 SQLite，重启后不重置；路由器在打分时把健康分纳入权重，写入 `RouteDecisionEvent`（候选链/实际模型/分数/路由原因）。

### Agent 实体

```text
AgentTemplate(revisionHistory, extends?)
  ├─ PersonaRevision       有 git-style diff 的版本化人格
  ├─ ContextRecipeRef      提示词配方（可跨 Agent 共享）
  ├─ CapabilityPolicyRef   工具/MCP/Skill/Plugin 与审批模式
  ├─ KnowledgePolicyRef    知识库与召回规则
  └─ MemoryPolicyRef       读写权限/命名空间/压缩策略

Session -> AgentBinding(mode: live | pinned)
  live   -> AgentTemplate.currentRevision（每次执行解析）
  pinned -> AgentRevisionSnapshot（显式迁移才更新）
```

### Session / Message / Part

```text
Session -> Branch(activeNodeId)
  -> Turn(orderSeq, parentId, status)
     -> Message(role, lifecycle, provenance)
        -> MessagePart[](id, type, lifecycle, rendererHint, actions[])
```

`parentId` 表达分支，`orderSeq` 表达单次运行内稳定顺序；多模型并列结果用 `siblingsGroupId` 建模，与分支分开。

### Object Registry

```text
OutputObject(objectId, type, sourceMessageId, capabilityTier, status, currentRevision)
  -> RevisionHistory[]
  -> RuntimeState(serializableSnapshot?)
  -> grantedCapabilities[]
```

capabilityTier：`prose`（静态渲染）/ `active`（独立 realm 内脚本）/ `trusted`（版本化 runtime SDK，每项能力仍由宿主校验）。

### ToolInvocation 状态机

```text
discovered → exposed → proposed → policy_checked
  → awaiting_approval | denied | executing
  → completed | failed | cancelled | timed_out
  → result_normalized → context_injected
```

审批 token：短时、单次、消息级绑定；执行端重新核对工具版本、参数摘要和调用者，不凭 Renderer 回传的布尔值放行。

## 四、主链路

```text
用户输入
  -> Composer 生成 typed input parts
  -> Host 创建 turn + pending message
  -> Context Recipe Compiler -> ContextManifest（可预览/可重放/可审计）
  -> 语义路由器（taskTags + 健康分 + 预算约束）选 Provider/Key/Model
  -> Provider Adapter -> normalized stream events
  -> Agent Loop
       text/reasoning delta -> stable/pending AST overlay
       tool proposal -> policy_checked -> approval/deny -> executor
       tool result -> normalize/delimit -> ContentEnvelope -> 下一轮 context
       object create/update -> Object Registry -> 对象面板
  -> Renderer projection（注册表按 part 类型分派）
  -> final snapshot + Object Registry 更新 + FTS 索引 + audit events 原子结算
```

取消链反向贯穿：UI stop → turn cancellation token → Provider abort → Agent loop → executor cancel/kill → BackgroundJob propagation → 终态事务。六个环节均须收到取消信号并完成终态结算。

## 五、上下文编排

### Context Recipe 模型

```text
ContextRecipe(id, revision, parentRevision?, extends?)
  -> ContextBlock[](id, source, slot, condition, tokenBudget, overflowPolicy, trustPolicy)
```

**分段 token 预算**是十六个项目均未实现的能力空白：每个 ContextBlock 有独立 `tokenBudget`（固定 token 或总预算百分比）；超预算时按优先级裁剪——先移除低优先级召回，再压缩旧 turns，保留最近完整交互；工具调用完整保留，不整体截断。这与 AIO Hub/LobeHub/NextChat 的"整体历史压缩"机制完全不同。

`slot` 取具名语义位置（安全前言/身份/环境/记忆/历史前/历史/历史后/当前输入前/输入后/工具尾）；`condition` 支持 `always/manual/match/retrieve/event/dependency`。

三档编辑体验（基础/高级/专家）共享同一结构化模型。Context Inspector 在发送前和历史回放时均可打开，显示 block 顺序、token 占比、激活原因和降级记录。

三项内容不参与普通拖拽覆盖：宿主安全前言固定最前；真实工具调用/结果的 role 和调用 ID 由运行时生成；不可信来源不能通过调整位置取得 system 指令地位。

### World Info 的 ContextRecipe 映射

World Info 条目映射为 `condition: match` + 关键词检索的 `ContextBlock`；递归激活在编译期求值，不在运行时循环；`at_depth` 位置映射到具名 slot，不依赖历史数组偏移量。这样 SillyTavern/AIO 格式可以在导入时一次性转换为内部 IR，不需要运行时再解析文本标记。

## 六、安全默认值

安全是兜底约束，不是产品卖点。以下是非协商的默认值：

1. Provider 密钥在主进程或系统凭据库中静态加密，Renderer 只看脱敏引用；备份不带解密材料。
2. 工具未声明策略时默认不暴露；已暴露工具未命中明确自动执行规则时默认请求审批。
3. 高影响类别（凭据读取、宿主设置修改、跨工作区写入、权限扩大）始终需要用户在场，"全自动"不能绕过。
4. shell/文件/网络/MCP/原生插件使用不同 capability；命令字符串白名单不能代替最终路径和进程校验。
5. 外部网页/RAG/MCP/工具结果默认是数据，不获得 system 指令优先级；写入记忆前再次检查。
6. 普通 Markdown 不执行 raw HTML；链接/SVG/Mermaid/媒体分别用协议白名单和专用 sanitizer。
7. `active` 档 Artifact 默认 opaque origin、无 preload、禁宿主 DOM；`trusted` 档按版本化 runtime SDK 逐项授权。
8. MCP HTTP 默认验证 TLS 并做 DNS/IP/重定向检查；stdio 进程有工作目录、环境变量和生命周期边界。
9. 所有审批、拒绝、路由、重试、记忆写入和 Artifact capability 请求进入审计流。
10. 安全策略解析失败或执行端无法验证 token 时 fail-closed；普通渲染与历史阅读仍可降级工作。

## 七、不应照搬的路线

- **VCPChat 主文档脚本执行 + 宽 widgetFS 桥**：保留能力目标，替换运行域和权限档位。
- **AIO canvas 的审批双执行 + HEAD 回滚**：这两个闭环断点需在设计阶段堵上，不是可接受的"当前限制"。
- **SillyTavern 字符串/DOM 扩展契约作为内部协议**：只在导入层做一次性转换，不让外部格式进入运行时契约。
- **AIO Hub "Agent 拥有一切"的单体配置**：保留丰富能力，拆成版本化引用。
- **Open WebUI 的 history JSON 与消息行双写**：事实源必须唯一。
- **LobeHub "未声明 humanIntervention 即自动执行"的默认方向**：策略解析失败时 fail-closed。
- **Provider failover/Key 轮换/模型 fallback/跨渠道 failover 共用一个模糊开关**：四层失败必须分别建模。
- **整 JSON/JSONL 覆盖作为长会话主存储**：SQLite 邻接树 + append-only turn 事件。

## 依据索引

- [Agent 工具横向对比](Agent工具/Agent工具横向对比.md)
- [Agent 角色横向对比](Agent角色/Agent角色横向对比.md)
- [Chat 横向对比](Chat/Chat横向对比.md)
- [LLM 渠道管理横向对比](LLM渠道管理/LLM渠道管理横向对比.md)
- [仓库分布横向对比](仓库分布/仓库分布横向对比.md)
- [消息渲染器横向对比](消息渲染器/消息渲染器横向对比.md)
- [生成式输出与运行时横向对比](生成式输出与运行时/生成式输出与运行时横向对比.md)

人类评价：~~还没看完，有写笔记在修订，到时候再评~~ 果然还是要区分下体验方向，目前这个主要的问题是把工作空间和娱乐空间混为一谈且更偏向工作空间了，下次应该改名成类似 工作型agent客户端模块组合构想 之类的，然后在娱乐型方面单开一个。
