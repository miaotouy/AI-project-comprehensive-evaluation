# AI 客户端完整体验栈与模块组合构想

> 对比对象：`AIO Hub`、`AstrBot`、`Chatbox`、`Cherry Studio`、`DeepChat`、`Hermes Agent`、`Jan`、`LobeHub`、`Manifold Desktop`、`NextChat`、`Open WebUI`、`SillyTavern`、`VCPChat`、`VCPToolBox`
>
> 对比更新日期：2026-08-07
>
> 依据：本目录下 Agent 工具、Agent 角色、Chat、LLM 渠道管理、仓库分布和消息渲染器调查笔记及横向对比
>
> 对比方法：先按事实源、运行时、权限域和持久化边界拆分能力，再组合各项目中已经核实的机制；组合方案属于设计推导，不表示任一项目已经完整实现
>
> 对比范围：本地优先的桌面 AI 客户端，覆盖会话壳、Composer、消息交互呈现、多 Provider、结构化聊天、Agent、工具、知识与记忆、可执行 Artifact、安全和可观测性；不覆盖云端多租户计费、组织管理和 IM 平台适配
>
> 文档定位：从既有调查中抽象完整客户端的体验层、运行时和安全边界，作为新客户端的模块划分与架构决策输入，不作为对现有项目的总排名或整改方案

## 结论摘要

在本次调查范围内，尚未发现能同时满足这些目标的单一项目。建议采用一套边界明确的组合：

- 以 **Cherry Studio / DeepChat** 的结构化消息、主进程权威会话和 SQLite 事务模型作为事实底座；
- 以 **Chatbox / LobeHub / Cherry Studio** 的会话壳、侧栏、编辑器和设置工作流作为客户端骨架；
- 以 **AIO Hub** 的 stable/pending AST 与增量 Patch 作为流式正文内核，并保留 **VCPChat / AIO Hub** 的可执行消息、流程卡和交互式小应用语义；
- 以消息渲染注册表和交互状态机承接文本、推理、工具、审批、引用、附件、错误、候选回复、分支、Artifact 等内容，不把它们压扁成 Markdown 加一个额外 Artifact；
- 以 **LobeHub** 的 Agent 工作流投影、工具渲染注册表和可观察重试作为运行时骨架；
- 以 **Cherry Studio** 的 Provider 实例分层、**AIO Hub** 的 Key 健康状态、**LobeHub** 的凭据加密和错误分类组成渠道模块；
- 以 **Chatbox** 的不可绕过审批类别、**Hermes Agent** 的 fail-closed 执行闸门和不可信内容定界组成安全底线；
- 以 **VCPChat** 的可执行消息能力作为上限，但放入 **Chatbox / LobeHub** 式低权限独立运行域；
- 以 **SillyTavern / AIO Hub** 的内容生态兼容作为导入适配层，不让旧文本协议成为内部事实模型。

本文以 **任务是否顺手、状态是否看得懂、会话是否可恢复、权限是否可解释、流式性能是否可控、模块是否可替换和高级能力是否可扩展** 作为评估标准。这里的“客户端”指一个完整的交互产品，不是把后端事实模型套上 Markdown 列表；面向轻量聊天、单网关接入或完全自由的角色扮演页面时，这套组合的复杂度通常超过收益。

## 一、先定义客户端体验层

原命题的偏差在于把“模块”默认为 Provider、Agent、Context、Storage、Executor 等后台对象，漏掉了用户每天真正操作的界面和反馈。一个能独立使用的 AI 客户端至少要同时回答四个问题：

1. 用户如何找到会话、切换 Agent、回到分支，并知道当前运行模式和权限范围？
2. 用户如何输入文字、文件、图片、语音、结构化参数或一条临时上下文，而不被迫手写协议？
3. 模型输出发生在流式生成、思考、调用工具、等待审批、产出文件和生成小应用时，界面如何让每一种状态都可读、可操作、可恢复？
4. 用户如何编辑、重试、分支、比较、引用、导出和回放，而不破坏原始事实记录？

因此，产品层应先定义一条完整的体验闭环：

```text
导航与会话壳
  -> Composer 输入工作台
  -> MessagePart 渲染注册表
  -> 流式状态与操作反馈
  -> 侧栏/面板承载上下文、审批、引用和 Artifact
  -> 分支、重试、编辑、回放与导出
```

### 1. 会话壳与工作区

- **会话导航**：工作区、项目、Agent、标签、收藏、搜索和最近活动应能在侧栏完成；长会话用虚拟列表，当前分支和运行状态始终可见。
- **会话头部**：显示 Agent revision、Provider/model、上下文占用、运行模式（普通、Agent、工作台）和权限摘要；这些不是设置页里的隐藏状态。
- **主视图与辅助面板**：主视图保持对话连续性，Context Inspector、工具时间线、引用来源、Artifact 预览和审计详情放入可折叠的侧栏或底部面板，不把每项调试信息塞进气泡正文。
- **工作区切换**：同一会话可在“聊天”“研究”“编码”“角色扮演”“小应用”之间切换投影，不切换事实源；模式差异体现在 Composer、渲染器和可用动作上。

### 2. Composer 输入工作台

Composer 不是一个只能发送纯文本的输入框，应支持：

- 文本、图片、文件、语音转写、粘贴的表格和结构化表单字段，统一生成 typed input parts；
- Agent、模型、上下文配方、记忆/知识开关、工作区和工具权限的可见选择；
- 发送前预览将使用的上下文 block、附件解析结果、预计预算和需要审批的动作；
- 草稿、队列、停止、继续、重试、编辑后重发、从此处创建分支等高频操作；
- 对角色卡、世界书、提示词片段和变量提供可视化引用入口，而不是要求用户记忆字符串注入语法。

### 3. 消息渲染不是 Markdown 的附属功能

`MessagePart` 应被视为用户可阅读、可定位、可操作的内容单元。至少需要以下 part 和对应交互：

消息渲染器横向调查已经确认，AIO Hub V2 把 `think`、VCP 工具、角色、日记、交互按钮、HTML、媒体和样式作为业务 AST 节点，VCPChat 则把消息的产品单位推进到可持续运行的界面。它们解决的不是“多渲染几种 Markdown”，而是让模型输出具备界面结构、状态和动作。组合方案需要保留这个产品目标，再按内容权限选择宿主原生组件或隔离运行时。

| Part | 用户看到的形态 | 必须支持的操作 |
|---|---|---|
| `text` | Markdown/HTML 安全正文、代码块、表格、数学和 Mermaid | 复制、编辑、折叠、引用、重新渲染 |
| `reasoning` | 可折叠思考区，显示生成中/完成/截断状态 | 展开、隐藏、复制，不混入正文语义 |
| `tool-call` | 工具名称、参数摘要、权限级别和时间线节点 | 查看参数、审批/拒绝、取消、重试 |
| `tool-result` | 结构化结果、日志、文件变化和失败原因 | 展开原文、筛选、引用、重新注入上下文 |
| `approval` | 明确的风险说明、影响范围和一次性确认入口 | 允许、拒绝、修改范围、查看策略 |
| `attachment` | 图片/音频/文件预览和解析状态 | 下载、替换、重新解析、查看来源 |
| `citation` | 来源卡片、片段和可信度 | 打开来源、定位上下文、取消引用 |
| `error` | 可理解的失败卡片，区分可重试/需修复/已取消 | 重试、切换渠道、复制诊断、恢复会话 |
| `candidate-group` | 多个候选回复的切换条和比较视图 | swipe、保留候选、从候选创建分支 |
| `conversation-flow` | AIO/VCP 式流程节点、角色回合、状态条和导演控制 | 暂停、跳过、重排、继续、回放 |
| `artifact` | 独立运行的小应用、图表、画布或交互卡片 | 全屏、刷新、导出、授权能力、卸载 |

其中 `artifact` 只是高能力内容的一种呈现。AIO/VCP 的颠覆性不应被削成“Markdown 正文 + 额外 Artifact”：流程消息、可交互控件、工具状态、候选回复、角色回合、媒体和结构化结果都应在同一消息时间线上拥有稳定节点，并能从实时投影恢复为最终快照。

### 4. 渲染状态与交互状态机

渲染器需要消费事件，而不是等待一段完整字符串：

```text
part discovered -> streaming -> stable | waiting -> approved/denied
                              \-> failed | cancelled | replaced
```

每个 part 有稳定 ID、生命周期、来源和可用动作。文本使用 stable/pending AST + keyed Patch；工具、审批、Artifact 和流程节点使用专用 renderer；长内容按节点虚拟化。实时态允许局部不完整，但重启、重放和重新加载必须得到同一组 parts 与节点状态。

### 5. “客户端感”的验收问题

在进入数据库和权限验收前，先用真实任务检查：用户能否在 10 秒内开始一次对话？能否看懂模型正在做什么？审批后能否继续而不重复执行？能否在工具失败后定位原因并恢复？能否从一条回复创建分支、比较候选并回到原分支？能否把一个 Artifact 当作产品内容使用，同时知道它获得了哪些能力？如果这些问题没有答案，模块组合还不能称为一个客户端。

## 二、目标形态：一个客户端，四个运行域

```text
┌──────────────────── Renderer / UI 域 ────────────────────┐
│ 会话视图、编辑器、结构化消息、审批 UI、设置、搜索         │
│ 只持有投影状态，不持有 Provider 密钥或宿主执行能力         │
└───────────────────────┬───────────────────────────────────┘
                        │ typed IPC / event stream
┌──────────────────── Host / Agent 域 ─────────────────────┐
│ 权威会话、Agent loop、上下文构建、Provider、工具策略、存储 │
│ 所有高影响动作在执行端重新鉴权，统一写审计事件             │
└───────────────┬──────────────────────────┬────────────────┘
                │ capability RPC           │ sandboxed web IPC
┌──────────── Executor 域 ────────┐  ┌──── Artifact 域 ─────┐
│ shell/file/MCP/plugin/sidecar   │  │ HTML/CSS/JS/WebGL     │
│ 最小权限、按工作区隔离、可终止  │  │ opaque origin、默认禁网│
└────────────────────────────────┘  └───────────────────────┘
```

UI、Agent 编排、工具执行和模型生成的小应用需要处于不同权限域。Manifold Desktop 和 VCPChat 的调查表明，模型内容一旦与宿主桥或主页面脚本共处同一环境，渲染缺陷就会扩大为本地能力风险。单靠 Markdown 清洗无法提供 AIO/VCP 展示的消息内交互，因此这里保留两条路径：流程卡、选择器、工具状态和候选切换由 Renderer 按声明式 schema 原生渲染；需要任意 HTML/CSS/JS 的小应用进入独立 Artifact 域。前者不执行模型脚本，后者不取得宿主权限。

## 三、推荐模块组合

| 模块 | 推荐机制 | 主要来源 | 不带入的边界 |
|---|---|---|---|
| 桌面壳与进程边界 | Electron/TypeScript 主进程承载权威服务，Renderer 只读投影；高风险能力进入独立 executor | Cherry Studio、DeepChat、Chatbox | 不让 Renderer 直持密钥、shell 和数据库写权限 |
| 客户端壳与导航 | 工作区/项目/会话侧栏、会话头部、模式切换、辅助面板和虚拟列表共享一套投影状态 | Chatbox、Cherry Studio、LobeHub | 不把当前 Agent、分支、权限和生成状态藏在设置页 |
| Composer 输入工作台 | typed input parts、附件、结构化字段、草稿/队列/停止/重试、发送前上下文预览 | Chatbox、Cherry Studio、SillyTavern、AIO Hub | 不把所有输入降级成一段字符串，不要求用户手写注入协议 |
| 领域模型 | Provider、Agent revision、Session、MessagePart、ToolInvocation 都有稳定 ID 和版本 | Cherry Studio、DeepChat、AIO Hub | 不用显示名、裸 model id 或 DOM 节点充当身份 |
| 渠道管理 | Provider 预设与用户实例分离；显式 Adapter Family；Key 池带健康状态；凭据静态加密 | Cherry Studio、AIO Hub、LobeHub | 不从 URL 猜协议，不把重试、模型 fallback 和 Provider failover 混称容灾 |
| Agent 配置 | Persona、Runtime Profile、Capability Policy、Memory Policy 分层；会话绑定不可变 revision | Chatbox、AstrBot、DeepChat、Jan/NextChat | 不把人格文本本身当授权，不让模板修改静默改变旧会话 |
| 上下文编排 | 版本化 Context Recipe；来源、插槽、条件、预算、溢出策略和变换链可组合，发送前可预览 | AIO Hub、SillyTavern、VCPToolBox、Hermes Agent、DeepChat | 不把自由排序变成权限提升，不允许不可信内容伪装 system/tool 消息 |
| Chat 存储 | SQLite 邻接树 + append-only turn/block 事件；活动分支用指针；终态事务提交 | Cherry Studio、DeepChat、Hermes Agent | 不整文件覆盖，不用 DOM 或 Renderer store 作事实源 |
| 流式状态 | transport event -> live overlay -> 低频 checkpoint -> final snapshot | Cherry Studio、Chatbox、DeepChat | 不让每个 delta 直接重写完整消息或整会话 |
| 消息渲染与交互 | MessagePart renderer registry 覆盖正文、推理、工具、审批、引用、附件、错误、候选、流程和 Artifact；正文走 stable/pending AST + keyed Patch | Cherry Studio、AIO Hub、LobeHub、VCPChat | 不把 AIO/VCP 消息削成 Markdown 加 Artifact，不把工具和状态编码进 Markdown 私有标记 |
| 交互状态与操作反馈 | part 生命周期、工具时间线、审批卡、候选切换、分支操作、错误恢复和面板联动均由 typed events 驱动 | AIO Hub、VCPChat、LobeHub、Chatbox | 不让 UI 只展示最终文本，或用前端 busy 状态冒充运行时状态 |
| 长会话 | 列表窗口化，live tail 独立；重型节点有 pause/resume/serialize 生命周期 | Cherry Studio、LobeHub、VCPChat | 不让全部媒体、编辑器和可执行 DOM 永久常驻 |
| 工具运行时 | Catalog、Exposure、Policy、Approval、Executor、Result 六层分离；执行端重新鉴权 | Cherry Studio、Chatbox、Hermes Agent | 不把前端确认框当授权，不让子 Agent、代码沙箱 RPC 成为旁路 |
| MCP / Skill / Plugin | 三种扩展类型分别建模和提示信任级别；MCP 进程/网络、Skill 文本、Plugin 代码使用不同策略 | Agent 工具横向对比 | 不使用一个“已启用”开关概括三种权限模型 |
| 知识与记忆 | 原文、索引、召回结果、长期记忆和用户画像分库；每条内容保留来源与信任标签 | LobeHub、DeepChat、Hermes Agent | RAG 命中不直接取得 system 指令地位，记忆写入不绕过审查 |
| Artifact | 独立 realm 执行 HTML/CSS/JS/Canvas/Three.js，经版本化 capability bridge 请求宿主动作 | VCPChat、Chatbox、LobeHub | 不在宿主主文档运行模型脚本，不暴露完整 preload |
| 搜索 | SQLite FTS5 索引规范化后的所有 MessagePart，跨会话和跨分支返回 message id 并直接定位 | Chatbox、Hermes Agent，结合现有对比缺口 | 不搜索虚拟 DOM，不只返回会话标题 |
| 可观测性 | Provider 重试、Agent step、工具审批、上下文裁剪、持久化和取消统一为 typed events | LobeHub、DeepChat、Hermes Agent | 不依赖散落日志推断当前状态 |
| 验证体系 | 人工流式测试台 + 事件重放 + AST/DOM/截图/性能/安全基线 | AIO Hub、Cherry Studio | 不以手工观感替代 CI oracle，也不以单元测试替代运行时验证 |

## 四、五个核心事实模型

### 1. Provider：可运行的渠道实体

```text
ProviderPreset
  -> ProviderInstance(id, adapterFamily, endpoints, authRef)
       -> CredentialPool(keyRef[], policy, health[])
       -> ModelCatalog(providerId + modelId + capabilities)
       -> RouteCandidate(health, latency, cost, quota, taskFit)
```

请求失败处理分为四层：同请求重试、Key 切换、同 Provider 模型 fallback、跨 Provider failover。已调查的七项渠道实现尚未形成完整闭环，因此组合方案从一开始就应为四类行为记录不同事件、分配不同预算，并声明流开始后是否可以安全重放。成本、延迟和配额作为可观察输入；路由策略变更需要明确记录其触发条件。

### 2. Agent：版本化配置集合

```text
AgentTemplate
  ├─ PersonaRevision       身份、语气、开场和示例
  ├─ RuntimeProfileRef     Provider、模型、参数和上下文预算
  ├─ CapabilityPolicyRef   工具、MCP、Skill、Plugin 与审批模式
  ├─ KnowledgePolicyRef    知识库、召回与引用规则
  └─ MemoryPolicyRef       读写权限、命名空间、压缩和演化策略

Session -> AgentRevisionSnapshot + explicit session overrides
```

该模型吸收 Chatbox/AstrBot 的人格与运行环境解耦，以及 Jan/NextChat 的会话可复现性。用户修改模板后，应明确选择“只影响新会话”或“创建新 revision 并迁移当前会话”；旧会话不能在下一轮静默改变人格、模型或工具面。Profile 用于隔离完整运行环境，但不能取代 Agent revision。

### 3. Session 是权威 transcript，Message 是结构化 parts

```text
Session
  -> Branch / activeNodeId
  -> Turn(orderSeq, parentId, status)
       -> Message(role, lifecycle, provenance)
            -> MessagePart[]
                  text | reasoning | tool-call | tool-result
                  approval | attachment | citation | error
                  candidate-group | conversation-flow | artifact
```

Cherry Studio 的数据库树适合编辑、重试和分支；DeepChat 的 turn/block 模型适合流式过程和 Agent 工具链。组合模型同时保留两者：`parentId` 表达分支关系，`orderSeq` 表达单次运行内的稳定顺序，分别服务导航和事件结算。多模型并列结果使用 `siblingsGroupId`，与分支关系分开建模。

`MessagePart` 还应携带 renderer 类型、生命周期、来源、可用动作和布局提示。持久化的是事实与状态，Renderer 根据注册表投影成气泡、时间线、侧栏、流程节点或独立 Artifact；同一 part 可以在普通会话和工作台模式中使用不同投影，但不能因此生成两套互相矛盾的事实。

### 4. ToolInvocation 是受策略约束的状态机

```text
discovered
  -> exposed
  -> proposed
  -> policy_checked
  -> awaiting_approval | denied | executing
  -> completed | failed | cancelled | timed_out
  -> result_normalized
  -> context_injected
```

每次调用都绑定 `sessionId + turnId + invocationId + toolVersion + argumentsHash + approvalToken`。审批 token 必须短时、单次、消息级绑定，执行器核对工具版本、参数摘要、工作区和调用者；仅靠 Renderer 回传 `approved=true` 不构成授权。子 Agent 和 `execute_code` 内部再调用工具时，必须创建新的 invocation 或继承一个显式、可审计的 capability grant，不能直接调用底层 handler。

### 5. 外部内容带来源和信任标签

```text
ContentEnvelope
  = payload
  + source(web | file | mcp | memory | user | plugin | tool)
  + trust(untrusted | user_trusted | system_trusted)
  + provenance(uri, toolCallId, timestamp, digest)
  + findings[]
  + handling(block | delimit | sanitize | render-isolated)
```

Hermes Agent 的威胁扫描、BLOCKED 占位和 `<untrusted_tool_result>` 定界可作为基线，但正则扫描本身不能证明内容安全。组合方案同时采用结构化角色隔离、定界符去势、来源元数据、记忆写入闸门和 UI 可见标记。危险内容应被阻断、作为数据保留，或进入隔离渲染域，取决于其内容类型和使用落点。

## 五、主链路

```text
用户输入
  -> Composer 生成 typed input parts
  -> Host 创建 turn 与 pending message
  -> Context Recipe Compiler
       固定 Agent/Recipe revision
       + 当前活动分支
       + 条件激活、插槽排序和临时 overlay
       + 压缩摘要/记忆/知识召回
       + ContentEnvelope、token budget 与 overflow policy
       -> ContextManifest（可预览、可重放、可审计）
  -> Route Planner 选择 provider instance / key / model
  -> Provider Adapter 输出 normalized stream events
  -> Agent Loop
       text/reasoning delta -> live overlay
       tool proposal -> policy -> approval -> executor
       tool result -> normalize/delimit -> 下一轮上下文
  -> Renderer projection
       text: stable/pending AST
       native parts: renderer registry + declarative actions
       Agent 会话: optional conversation-flow
       artifact: isolated executable realm
  -> final snapshot + search index + audit events 原子结算
```

取消链需要反向贯穿整条链路：UI stop -> turn cancellation token -> Provider abort -> Agent loop 停止派发 -> executor cancel/kill -> 终态事务。完整中断要求这六个环节均收到取消信号并完成终态结算；仅清除前端 busy 状态、仅通知远端，或等到下一次 chunk 才检查停止均不满足该要求。

## 六、上下文编排自由度与记忆边界

三段式上下文链路主要处理缓存和预算，无法表达角色扮演、编码 Agent、资料研究和多 Agent 协作所需的上下文顺序。目标模块因此抽象为版本化 **Context Recipe**：用户可定义上下文来源、启用条件、语义位置、预算和超限后的降级策略。

这部分可组合 AIO Hub 的多阶段消息构建、SillyTavern 的 Context Preset/World Info、VCPToolBox 的变量与注入管线、Hermes Agent 的缓存分带，以及 DeepChat 的完整 turn 预算降级。旧项目中的字符串注入规则只作为导入格式，内部统一编译为结构化配方。

### 1. Context Recipe 模型

```text
ContextRecipe(id, revision, parentRevision)
  -> ContextBlock[]
       id / enabled / source / scope
       slot / roleHint / orderConstraints / priority
       condition / query / transform[]
       tokenBudget / overflowPolicy / onError
       trustPolicy / cachePolicy / visibility
```

每个 `ContextBlock` 是可追踪的独立上下文单元，包含尚未拼接的结构化信息：

| 字段 | 自由度 |
|---|---|
| `source` | Agent Persona、当前分支、历史窗口、摘要、世界书、知识库、长期记忆、工作区规则、附件、工具结果、变量、时间或插件数据源 |
| `scope` | 全局、Profile、Agent revision、项目、Session、分支或仅本轮 |
| `slot` | 安全前言、身份、环境、记忆、历史前、历史、历史后、当前输入前、当前输入后、工具尾部 |
| `condition` | 按 Agent、Profile、模型能力、会话标签、文件类型、用户显式开关、关键词/实体命中或上游 block 是否产出启用 |
| `transform` | 模板化、变量展开、检索、排序、去重、截断、摘要、格式转换、脱敏和不可信定界 |
| `tokenBudget` | 固定 token、总预算百分比、最小保留、最大上限或与其他 block 共享预算池 |
| `overflowPolicy` | 丢弃、按条裁剪、保留首尾、重新检索、摘要、降级为引用清单或阻止发送 |
| `visibility` | 始终展示、仅高级面板展示、对模型可见但不进入普通 transcript，或同时生成用户可审计引用 |

配方采用显式版本。Session 绑定 `recipeRevision`，单轮临时调整形成 overlay，不回写模板；用户可选择将 overlay 保存为新 revision。该设计保留 NextChat/Jan 的会话可复现性，并允许 AstrBot/Open WebUI 式运行时更新；更新只在用户明确选择后生效。

### 2. 语义插槽与消息数组编译

用户可以自由调整 block 顺序，但编辑界面操作的是具名语义插槽。Provider 的 `system/user/assistant/tool` 消息数组由编译器生成：

```text
immutable-security
  -> identity
  -> environment
  -> memory-and-knowledge
  -> history-prefix
  -> conversation-history
  -> history-suffix
  -> current-turn-prefix
  -> current-user-input
  -> current-turn-suffix
  -> tool-protocol-tail
```

用户可以创建子插槽，并用 `before/after` 约束排序，例如让世界书位于人格之后、历史之前，让编码规范位于工作区文件之后，让临时导演指令只包围当前输入。Provider Adapter 最后把语义插槽编译成 OpenAI、Anthropic、Gemini 等协议允许的消息结构；协议不支持某种 role 时必须给出可观察的降级结果，不能静默换位。

三项内容不参与普通拖拽覆盖：宿主安全前言固定在最前；真实工具调用/结果的 role 和调用 ID 由运行时生成；不可信来源不能通过调整位置取得可信 system 指令地位。用户主动提升某个来源的信任级别时，系统应创建显式 revision 并记录审计事件。

### 3. 条件激活与组合规则

Context Recipe 应支持比“始终注入”更细的触发语义：

- `always`：身份、固定输出格式和工作区基础规则；
- `manual`：由 Composer 或会话工具栏临时打开；
- `match`：关键词、标签、实体、文件路径或 MIME 命中后启用，适合世界书和领域规则；
- `retrieve`：根据当前输入检索并返回 Top-K，适合知识库与长期记忆；
- `event`：仅在工具失败、压缩发生、分支切换或子 Agent 回传后启用；
- `dependency`：上游 block 有结果或满足表达式时启用，适合多阶段研究与结构化工作流。

条件表达式应使用受限声明式 DSL，并提供类型检查和最大执行时间。需要任意代码的数据源放入 Plugin/Executor 域，经 schema 返回 `ContentEnvelope`；不能在 Host 的 prompt 拼装函数中执行用户 JavaScript。

### 4. 编译链与可观察降级

```text
resolve recipe inheritance
  -> evaluate activation conditions
  -> fetch source blocks in parallel
  -> normalize as ContentEnvelope
  -> apply typed transforms
  -> resolve slot/order constraints
  -> allocate token budgets
  -> apply overflow policies
  -> compile provider messages
  -> emit ContextManifest + request snapshot
```

每个数据源单独配置 `onError`：`skip`、`use-stale`、`fallback` 或 `block-send`。例如时间信息失败可以跳过，关键项目规则读取失败应阻止自动执行，知识库超时可以使用有时间戳的旧快照。该行为必须出现在运行事件与发送前预览中。

预算采用分块分配：先为各 block 设置保底和上限，再按优先级分配剩余空间。超预算时依次移除低优先级召回和运行提示、压缩较旧完整 turns，并保留最近完整交互。工具调用保持完整，摘要以新的 summary revision 保存，并记录覆盖范围和 lineage；原始 transcript 仍可审计、搜索和重新构建。

### 5. 三档编辑体验

| 模式 | 用户操作 | 适用场景 |
|---|---|---|
| 基础 | 选择预设，开关记忆、知识、附件和历史深度 | 普通聊天，不暴露编排术语 |
| 高级 | 拖拽 block、选择插槽、设置条件、优先级和预算 | 角色、研究和编码工作流 |
| 专家 | 编辑带 schema 的 YAML/JSON Recipe，查看编译错误和 Provider 降级 | 复杂 Agent、生态迁移和可复现评测 |

三个模式共享同一份结构化模型。可视化界面承担高频修改，文本格式用于 diff、版本控制、导入导出和批量生成。

### 6. 上下文检查器

发送前和历史回放时都应能打开 Context Inspector，至少显示：

- 最终 block 顺序、role、token 数、缓存带和预算占比；
- 每块的来源、revision、内容摘要、信任级别和激活原因；
- 哪些内容被去重、裁剪、摘要、降级或因错误跳过；
- Provider Adapter 实际生成的消息结构，以及相对上一次请求的 diff；
- 某条模型输出能够追溯到哪些知识、记忆、文件和工具结果。

Inspector 默认隐藏密钥、认证 Header 和敏感原文，但允许定位源记录。它既是高级用户的自由度保障，也是排查“为什么模型知道/忘了某件事”和缓存失效的主要入口。

### 7. 长期记忆边界

长期记忆必须具有独立读写权限。默认允许 Agent 读取经过筛选的记忆，写入则经过内容扫描、来源记录和可选审批；Persona evolution 只产生候选 revision，不直接改写当前人格。知识库原文、召回片段、模型生成摘要和用户画像不能混在同一张无来源文本表中。

在 Context Recipe 中，记忆作为可配置数据源，用户可选择命名空间、检索条件、插槽、预算和只读/读写模式；配方不改变记忆写入闸门。记忆命中项应携带时间、来源、置信度和失效策略；内容被删除或修订后，旧请求仍通过 ContextManifest 保留“当时使用哪个 revision”的可复现记录。

## 七、安全默认值

1. Provider 密钥在主进程或系统凭据库中静态加密，Renderer 只看到脱敏引用；备份默认不带解密材料。
2. 工具未声明策略时默认不暴露；已暴露工具未命中明确自动执行规则时默认请求审批。
3. 高影响类别始终需要用户在场，包括凭据读取、宿主设置修改、跨工作区写入和权限扩大；“全自动”也不能绕过。
4. shell、文件、网络、MCP 和原生插件使用不同 capability；命令字符串白名单不能代替最终路径、进程和网络目标校验。
5. 外部网页、RAG、MCP 和工具结果默认是数据，不获得 system 指令优先级；写入记忆前再次检查。
6. 普通 Markdown 不执行 raw HTML；链接、SVG、Mermaid 和媒体分别使用协议白名单与专用 sanitizer。
7. Artifact 默认 opaque origin、无 preload、禁宿主 DOM、禁密钥、禁任意文件系统；网络、持久存储和宿主动作按档位授权。
8. MCP HTTP 默认验证 TLS，并在服务端执行 DNS/IP/重定向检查；stdio 进程有工作目录、环境变量和生命周期边界。
9. 所有审批、拒绝、路由、重试、工具结果裁剪、记忆写入和 Artifact capability 请求进入审计流。
10. 安全策略解析失败、审批服务不可达或执行端无法验证 token 时 fail-closed；普通渲染与历史阅读仍可降级工作。

## 八、不应组合的部分

- 不把 VCPChat 的主文档脚本执行与宿主桥一起带入；保留能力目标，替换运行域。
- 不把 SillyTavern 的字符串/DOM 扩展契约作为内部协议；只做边缘兼容。
- 不照搬 AIO Hub “Agent 拥有一切”的单体配置；保留丰富能力，拆成版本化引用。
- 不照搬 Open WebUI 的 RAG/工具原文直接注入和安全头 opt-in 默认值。
- 不采用 LobeHub “未声明 humanIntervention 即自动执行”的失效方向。
- 不采用 Chatbox Windows shell 无 OS 隔离、Cherry Studio 只看命令首词的授权近似。
- 不采用整 JSON/JSONL 覆盖作为长会话主存储，也不采用历史 JSON 与行表双写真相源。
- 不让 Provider fallback、Key 轮换、模型 fallback 和跨渠道 failover 共用一个模糊开关。

## 九、高级与生态能力的抽象纳入

来源材料的调查深度和默认配置并不完全一致，因此“实现路径特殊”不能直接等同于“缺陷”或“高风险”。以下能力虽然不适合作为普通聊天的默认路径，但应作为高级能力纳入总体设计，而不是在抽象阶段删掉：

| 能力 | 主要来源 | 大抽象中的位置 | 默认边界 |
|---|---|---|---|
| 候选回复、swipe 与从候选创建分支 | SillyTavern | `CandidateGroup` + `Branch`，候选结果与当前选中结果分开持久化 | 普通会话可关闭；候选切换不得改写其他候选的事实记录 |
| 角色卡、世界书和旧协议导入 | SillyTavern、AIO Hub、VCPChat | `ImportAdapter -> Internal IR` 的边缘兼容层 | 导入后只保留内部结构，不让外部格式进入主存储和运行时契约 |
| 原生交互消息与流程卡 | VCPChat、AIO Hub | `InteractivePart` / `ConversationFlowPart` + renderer registry + 声明式 `ActionIntent` | 宿主原生渲染；模型 payload 不能直调 handler，动作仍走 Host 策略和状态机 |
| 可执行消息与交互式小应用 | VCPChat、AIO Hub | `ArtifactPart` + 独立 Artifact realm + 版本化 capability bridge | 任意 HTML/CSS/JS 只在隔离域运行；禁用宿主密钥和完整 preload，宿主动作逐项授权 |
| 非对话时段的记忆整理与定时任务 | VCPToolBox AgentDream、TaskAssistant | `BackgroundJob` / `MemoryWriteProposal`，与前台 Agent loop 分开 | 默认关闭；显式计划、预算、可取消、审计，记忆写入仍经过 gate |
| 语义虚拟模型与任务选模 | VCPToolBox | `VirtualModel` / `RoutePlan`，对外兼容标准模型接口 | 目录中显式标记 virtual/partial；请求记录候选链、实际模型和路由原因 |
| 异步子 Agent 与本机/服务端执行选择 | LobeHub、Hermes Agent | `AsyncOperation` + `ExecutionLocation` + 父子 lineage | 结果、取消、超时、计费和恢复均以异步操作建模；本机执行需单独 capability |
| Profile 级人格、技能、记忆和配置打包 | Hermes Agent | `ProfileRevision`，作为可迁移运行环境，而非单一 Persona 字段 | 角色修改和提示词缓存均产生可追踪 revision，避免历史回放依赖当前全局值 |

这些能力共享四条约束：

1. **默认状态可见且保守**：高级能力必须有明确的启用入口、当前状态和生效范围；调查中看到的“可调用”不代表默认启用。
2. **边缘兼容、内部原生**：ST/VCP 等格式只负责一次性转换为内部 IR；概念相似属于设计借鉴，只有运行时继续依赖外部协议才算真正耦合。
3. **交互按能力分层**：声明式消息部件由宿主原生渲染，任意代码才进入独立运行域；Artifact、插件、本机执行和后台任务均通过 capability、执行位置和生命周期边界接入 Host。
4. **过程与结果可重放**：候选生成、流程动作、后台任务、子 Agent、路由决策和 Artifact 状态都写入 typed events，使用户能解释“何时启用、由谁触发、实际做了什么”。

因此，组合架构不应只抽象“可靠聊天内核”，还应保留一个**高级能力层**：它承接社区资产、可执行内容、候选探索、后台认知和语义路由，同时通过显式模式、隔离运行域和可重放事件把这些非标准体验控制在可解释边界内。

## 十、最终判断

组合架构要求每个模块只拥有一种权威事实和一条清楚的失效边界：

- Cherry Studio / DeepChat 决定数据如何可靠落地；
- Chatbox / Cherry Studio / LobeHub 决定会话壳、Composer 和工作台如何组织日常操作；
- LobeHub 决定 Agent 过程如何被结构化观察；
- AIO Hub / VCPChat 决定消息内交互、流程呈现和流式正文如何成为一等体验；
- Cherry Studio / AIO Hub / LobeHub 决定渠道如何被实例化、保护和观察；
- Chatbox / Hermes Agent 决定工具执行如何在失败时拒绝；
- VCPChat 决定高级内容能力的上限，隔离域决定这个上限不会成为宿主权限；
- SillyTavern / AIO Hub 提供候选探索、世界书、角色资产和上下文玩法等生态语义，并通过转换层进入内部模型。

高级能力层补充了另一条产品路线：SillyTavern 的候选回复与生态资产、AIO/VCP 的原生交互消息和可执行小应用、VCPToolBox 的后台 Agent 与语义路由、Hermes 的 Profile 运行环境和 LobeHub 的异步子 Agent 都可以作为可选模式存在。它们不因来源材料存在缺口就应被排除；真正需要固化的是启用条件、内部表示、渲染方式、执行位置、权限和回放语义。

## 依据索引

- [Agent 工具横向对比](Agent工具/Agent工具横向对比.md)
- [Agent 角色横向对比](Agent角色/Agent角色横向对比.md)
- [Chat 横向对比](Chat/Chat横向对比.md)
- [LLM 渠道管理横向对比](LLM渠道管理/LLM渠道管理横向对比.md)
- [仓库分布横向对比](仓库分布/仓库分布横向对比.md)
- [消息渲染器横向对比](消息渲染器/消息渲染器横向对比.md)


人类评价：过于保守的构想，下次重做吧 