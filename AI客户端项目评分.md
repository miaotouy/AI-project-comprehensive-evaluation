# AI 客户端项目评分

> 对比对象：`AIO Hub`、`AstrBot`、`Chatbox`、`Cherry Studio`、`DeepChat`、`Hermes Agent`、`Jan`、`LobeHub`、`Manifold Desktop`、`NextChat`、`OpenCode`、`Open WebUI`、`Pi`、`SillyTavern`、`VCPChat`、`VCPToolBox`
>
> 对比更新日期：2026-08-10
>
> 依据：本目录下 Agent 工具、Agent 角色、会话与消息管理、对话请求与上下文、Chat UI、LLM 渠道管理、仓库分布和消息渲染器单项目调查笔记及横向对比
>
> 对比方法：把既有调查项转换为统一的 0-5 分量表，分别计算分项分、场景加权分、证据覆盖率和风险标签；所有分数必须能够回链到调查笔记中的源码依据或明确的未验证记录
>
> 对比范围：本地或自托管 AI 客户端、Agent 工作台和相关中间层；比较当前代码快照中的产品与工程机制，不比较品牌、社区热度、提交数量、商业资源和未来路线图
>
> 文档定位：提供可复算的项目评分口径和结果载体，用于选型与架构参考；不把单一总分解释为项目的绝对质量排名，也不作为整改方案

## 结论摘要

现有调查适合形成评分文档，但不适合只给出一列总分。项目定位差异很大：通用桌面客户端、IM 机器人框架、编码 Agent、角色扮演前端、可执行消息运行时和 LLM 中间层追求的目标并不相同。同一套固定权重会系统性偏向某一种产品。

本评分采用四层结果：

1. **八个分项分**：保留项目真实强项和短板。
2. **四套场景分**：分别回答通用桌面、Agent 工作台、高自由度生态和二次开发参考的选型问题。
3. **证据覆盖率与置信等级**：避免把“未调查”或“无法确认”计为能力缺失。
4. **风险标签**：高权限执行、凭据暴露、失效时放行和事实源不一致等问题单独显示，不藏进平均分。

只有共同口径已经覆盖、证据覆盖率达到门槛的项目才进入同场景排序。其余项目仍展示分项结果，但总分标记为“证据不足”或“不适用”。

## 一、评分标记

| 标记 | 含义 | 是否进入分数 |
|---|---|---|
| `0` | 已确认不支持，或主路径完全缺失 | 是 |
| `1` | 只有最小能力，依赖人工约定或明显脆弱的单一路径 | 是 |
| `2` | 能完成基础任务，但缺少关键闭环、边界或恢复机制 | 是 |
| `3` | 常见主路径完整，设计和行为基本可解释 | 是 |
| `4` | 机制成熟，覆盖高级场景，并有较清楚的边界或验证 | 是 |
| `5` | 在本次样本中具有参考级实现，形成完整闭环且没有同维度的重大已确认缺口 | 是 |
| `U` | 本次未调查到足够证据 | 否，计入覆盖率缺口 |
| `?` | 已调查，但静态代码无法确认实际行为 | 否，计入覆盖率缺口 |
| `N/A` | 项目定位决定该项不适用，例如纯中间层没有消息列表 | 否，从适用权重中移除 |

评分以 `0.5` 为最小步长。`0` 只能用于已确认缺失，不能因为搜索中没有看到实现就直接记零。`5` 也不等于没有缺陷，只表示在该维度和当前样本范围内达到参考级。

## 二、基础评分维度

基础权重用于观察一个完整 AI 客户端的综合能力。分项分先按子项等权平均，再乘以基础权重。

| 维度 | 基础权重 | 子项 |
|---|---:|---|
| Chat 与会话 | 18 | 事实模型；持久化与恢复；发送、流式与中断；上下文截断与压缩；编辑、重试、分支、搜索和长会话 |
| 消息渲染 | 15 | 内容块模型；增量更新链；列表窗口化与滚动；Markdown、工具、附件和富内容；Artifact 隔离、性能与测试 |
| LLM 渠道 | 12 | Provider/Endpoint 实体；模型目录与协议适配；凭据边界；多 Key、限流、重试与故障转移；连接检测与可观测性 |
| Agent 角色与上下文 | 10 | 角色模型与版本；会话绑定和快照；提示词拼装；工具、知识和记忆；导入导出与运行时可见性 |
| Agent 工具与运行时 | 20 | 工具注册和收窄；调用表示与参数校验；循环、并发、预算和取消；审批与执行鉴权；隔离、结果回注和子 Agent 边界 |
| 工程基础 | 10 | 模块边界；类型与数据契约；自动测试；文档与迁移；跨平台和发布组织 |
| 安全与可恢复性 | 10 | 失效方向；凭据保护；不可信内容边界；审批与审计；崩溃一致性、取消结算和恢复 |
| 扩展性与生态 | 5 | 插件/MCP/Skill 边界；资产兼容；自定义渲染与 Artifact；工作流和子 Agent 扩展；兼容层与内部事实模型的分离 |

### 2.1 Chat 与会话

- `1`：单数组或整文件存储，流式状态主要留在界面内，缺少可靠恢复。
- `3`：会话和消息可持久化，流式终态明确，具备编辑、重试、上下文裁剪等常见能力。
- `5`：事实模型、分支、流式结算、取消、压缩、搜索、长会话和崩溃恢复形成可重放闭环。

### 2.2 消息渲染

- `1`：累计字符串反复整段渲染，富内容和安全边界主要依赖外围约定。
- `3`：正文、推理、工具和附件有稳定分派，流式与历史态可正常交接。
- `5`：typed parts、增量渲染、长列表、重型节点生命周期、隔离运行域和回归验证同时完整。

### 2.3 LLM 渠道

- `1`：单端点、单 Key、静态模型名，凭据和请求链路边界较弱。
- `3`：多 Provider、模型能力、协议 Adapter、连接测试和错误归一化完整。
- `5`：Provider 可实例化，多 Key 有健康闭环，凭据受保护，并具备可观察的限流、重试和跨渠道故障转移。

### 2.4 Agent 角色与上下文

- `1`：角色主要是一段 system prompt 或全局设置快照。
- `3`：角色包含模型、参数、工具或知识绑定，并能稳定作用于会话。
- `5`：角色、运行环境、能力、记忆和上下文配方可版本化、可迁移、可审计，历史会话可复现。

### 2.5 Agent 工具与运行时

- `1`：工具可被模型调用，但缺少统一校验、审批、终止或结果规范化。
- `3`：注册、过滤、参数校验、执行、结果回注和基本审批链完整。
- `5`：策略与执行端双重鉴权，失效时拒绝，具备隔离、预算、取消、子 Agent 继承和完整审计闭环。

### 2.6 工程基础

- `1`：关键逻辑集中在少数大文件，测试和迁移约束较少。
- `3`：模块分工清楚，有类型约束、关键测试、文档和发布流程。
- `5`：跨进程与跨平台契约明确，测试覆盖主链和故障链，迁移、兼容和性能基准可持续维护。

### 2.7 安全与可恢复性

- `1`：模型内容或工具接近宿主权限，凭据明文暴露，关键策略异常时放行。
- `3`：常见危险操作有审批或隔离，凭据不进入普通 Renderer，失败能进入可理解终态。
- `5`：不可信内容、审批 token、执行 capability、审计事件和崩溃恢复贯穿主链，关键策略 fail-closed。

### 2.8 扩展性与生态

- `1`：扩展依赖修改核心或共享宿主权限，内部协议与外部格式混合。
- `3`：存在稳定插件、MCP、Skill、资产或 Renderer 扩展入口。
- `5`：扩展可声明能力和生命周期，外部生态经适配层进入内部 IR，兼顾兼容性、隔离和可迁移性。

## 三、场景权重

| 场景 | Chat | 渲染 | 渠道 | 角色 | 工具 | 工程 | 安全 | 生态 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 通用桌面客户端 | 22 | 18 | 18 | 10 | 10 | 10 | 8 | 4 |
| Agent 工作台 | 12 | 10 | 10 | 15 | 28 | 8 | 12 | 5 |
| 高自由度与生态 | 12 | 22 | 8 | 15 | 15 | 5 | 8 | 15 |
| 二次开发与架构参考 | 10 | 12 | 10 | 10 | 15 | 25 | 10 | 8 |

场景分只改变权重，不改变原始分项分。纯中间层、IM 框架或终端 Agent 可以参与与自身定位相符的场景，不强行进入通用桌面榜。

## 四、计算规则

单个场景的适用分按下式计算：

```text
场景分 = Σ(分项分 / 5 × 场景权重) / 已评分适用权重 × 100
证据覆盖率 = 已评分适用权重 / 全部适用权重 × 100%
```

发布规则：

- 证据覆盖率低于 `70%`：不发布场景分，只显示分项证据。
- 覆盖率为 `70%-84%`：可显示暂定分，不进入正式排序。
- 覆盖率达到 `85%`：可进入同场景排序。
- 两个项目相差小于 `2` 分时视为同档，不用小数位制造虚假精度。
- 排名必须同时显示场景、代码快照日期、覆盖率和风险标签。

## 五、风险标签

风险标签不直接做隐式扣分。相关机制会影响对应分项，但标签仍单独展示，防止高功能分掩盖高影响边界。

| 标签 | 触发条件 |
|---|---|
| `HOST_EXEC` | 模型生成内容或工具可在宿主高权限域执行 |
| `FAIL_OPEN` | 审批、权限或策略解析异常时默认放行 |
| `NO_ISOLATION` | shell、代码或插件执行缺少与宿主权限相称的隔离 |
| `SECRET_EXPOSURE` | 凭据明文进入前端、日志、备份或宽读取范围 |
| `UNTRUSTED_MERGE` | 网页、RAG、MCP、插件或导入资产可获得高信任指令地位 |
| `DUAL_TRUTH` | 同一会话、消息或配置存在两个可能分叉的权威事实源 |
| `NO_CANCEL` | UI 停止无法贯穿 Provider、Agent loop、工具与终态结算 |
| `STATIC_ONLY` | 关键视觉、安全、性能或平台行为只有静态代码证据，尚未运行验证 |

同一标签需要在结果表后附一句事实依据和笔记链接。风险是否可接受由目标场景决定，例如 `HOST_EXEC` 对可执行消息项目可能是能力上限，同时也是必须显式处理的信任边界。

## 六、置信等级

| 等级 | 要求 |
|---|---|
| `A` | 主链和关键边界有源码定位，并有运行、测试或可复现数据验证 |
| `B` | 主链和关键边界有充分静态源码依据，未完成运行验证 |
| `C` | 只覆盖主要入口，仍有影响评分的明确证据缺口 |
| `D` | 主要依赖 README、界面文案或间接推断，不用于正式排序 |

项目总置信等级取关键高权重维度中的最低等级，不能用大量低影响证据稀释一个关键未验证项。

## 七、结果表

以下是第一轮静态源码评分。分项单元格采用 `分数/置信等级`；场景分取整数。所有适用维度均已录入，因此分项覆盖率为 `100%`；这只表示量表没有空项，运行验证缺口由统一的 `B` 级置信度表达。

| 项目 | Chat | 渲染 | 渠道 | 角色 | 工具 | 工程 | 安全 | 生态 | 基础综合 | 通用桌面 | Agent 工作台 | 高自由度 | 二次开发 | 覆盖/置信 | 风险标签 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| AIO Hub | 3.5/B | 4.5/B | 4/B | 4.5/B | 3/B | 3.5/B | 2.5/B | 4.5/B | 73 | 76 | 72 | 78 | 74 | 100%/B | `HOST_EXEC` `NO_ISOLATION` `SECRET_EXPOSURE` |
| AstrBot | 4/B | 3.5/B | 4/B | 3.5/B | 3.5/B | 4/B | 3/B | 4/B | 74 | N/A | 72 | 73 | 74 | 100%/B | `HOST_EXEC` `SECRET_EXPOSURE` |
| Chatbox | 4/B | 4/B | 4/B | 3/B | 3.5/B | 4/B | 3.5/B | 3.5/B | 75 | 76 | 73 | 73 | 75 | 100%/B | `HOST_EXEC` `NO_ISOLATION` `SECRET_EXPOSURE` |
| Cherry Studio | 4.5/B | 4.5/B | 4.5/B | 4/B | 3.5/B | 4.5/B | 3/B | 3.5/B | 81 | 84 | 78 | 80 | 81 | 100%/B | `HOST_EXEC` `NO_ISOLATION` |
| DeepChat | 4.5/B | 4.5/B | 4/B | 4.5/B | 4/B | 4.5/B | 4/B | 4/B | 85 | 86 | 85 | 85 | 86 | 100%/B | `HOST_EXEC` |
| Hermes Agent | 4.5/B | 4/B | 4.5/B | 3.5/B | 4.5/B | 4.5/B | 4.5/B | 4.5/B | 87 | 86 | 86 | 85 | 87 | 100%/B | `HOST_EXEC` |
| Jan | 3.5/B | 4/B | 3.5/B | 3.5/B | 3/B | 3.5/B | 3.5/B | 3/B | 69 | 70 | 68 | 69 | 69 | 100%/B | `HOST_EXEC` `NO_ISOLATION` |
| LobeHub | 4/B | 4.5/B | 4/B | 4.5/B | 3.5/B | 4.5/B | 2.5/B | 4.5/B | 79 | 81 | 77 | 82 | 81 | 100%/B | `HOST_EXEC` `FAIL_OPEN` `NO_ISOLATION` `NO_CANCEL` |
| Manifold Desktop | 0.5/B | 1/B | 2/B | 0.5/B | 0.5/B | 1/B | 0.5/B | 1/B | 17 | 19 | 15 | 17 | 18 | 100%/B | `HOST_EXEC` `NO_CANCEL` |
| NextChat | 3.5/B | 3.5/B | 3.5/B | 3.5/B | 1.5/B | 3/B | 1.5/B | 2.5/B | 56 | 61 | 52 | 57 | 56 | 100%/B | `HOST_EXEC` `NO_ISOLATION` `SECRET_EXPOSURE` |
| OpenCode | 4.5/B | 4.5/B | 3.5/B | 4/B | 4/B | 4.5/B | 3/B | 4/B | 81 | N/A | 80 | 82 | 82 | 100%/B | `HOST_EXEC` `NO_ISOLATION` `SECRET_EXPOSURE` |
| Open WebUI | 4/B | 4/B | 3.5/B | 4/B | 3.5/B | 3/B | 3/B | 4/B | 73 | 74 | 72 | 75 | 71 | 100%/B | `DUAL_TRUTH` `UNTRUSTED_MERGE` |
| Pi | 4/B | 3.5/B | 3.5/B | 3/B | 3/B | 4.5/B | 2/B | 4/B | 68 | N/A | 65 | 68 | 71 | 100%/B | `HOST_EXEC` `NO_ISOLATION` |
| SillyTavern | 4/B | 3.5/B | 3/B | 4.5/B | 1.5/B | 2.5/B | 1/B | 4.5/B | 59 | 63 | 55 | 65 | 58 | 100%/B | `HOST_EXEC` `UNTRUSTED_MERGE` |
| VCPChat | 3.5/B | 4/B | 1.5/B | 3/B | 1.5/B | 2.5/B | 0.5/B | 4/B | 50 | 53 | 46 | 57 | 50 | 100%/B | `HOST_EXEC` `NO_ISOLATION` `SECRET_EXPOSURE` `NO_CANCEL` |
| VCPToolBox | N/A | N/A | 2.5/B | 3/B | 3/B | 2.5/B | 2.5/B | 4/B | 57 | N/A | 57 | 61 | 56 | 100%/B | `HOST_EXEC` `NO_ISOLATION` `SECRET_EXPOSURE` |

`AstrBot`、`OpenCode` 和 `Pi` 不以通用桌面聊天为产品边界，因此不进入“通用桌面客户端”场景。`VCPToolBox` 没有独立消息列表和渲染主路径，对应维度为 `N/A`；其余场景按适用权重重新归一化。所有项目当前都带有全局性的 `STATIC_ONLY` 限制，本表不在每行重复。

## 八、场景结果

- **通用桌面客户端**：DeepChat 与 Hermes Agent 同为 `86`，Cherry Studio 为 `84`，属于第一档；LobeHub `81` 单列下一档。AIO Hub 与 Chatbox 同为 `76`，实现取向不同但加权结果相同。
- **Agent 工作台**：Hermes Agent `86`、DeepChat `85` 属同档；OpenCode `80`；Cherry Studio `78` 与 LobeHub `77` 属同档。Hermes 的失分主要来自角色不是版本化聚合实体，DeepChat 的限制主要是仍缺运行验证。
- **高自由度与生态**：DeepChat 与 Hermes Agent 同为 `85`；LobeHub 与 OpenCode 同为 `82`；Cherry Studio `80`、AIO Hub `78`。SillyTavern 和 VCPChat 的生态原始分很高，但工具闭环、安全边界和工程验证拉低了场景总分；这套场景分评价的是“自由能力能否长期、可控地运行”，不只是玩法数量。
- **二次开发与架构参考**：Hermes Agent `87`、DeepChat `86` 属第一档；OpenCode `82`、Cherry Studio 与 LobeHub `81` 属第二档。测试分布、权威事实源、协议边界和迁移能力在这一场景中的权重最高。

分数差距小于 `2` 时不解释为稳定名次。首轮结果最值得保留的不是“谁第一”，而是三个明显分组：完整运行时与强工程闭环、能力完整但存在关键边界缺口、定位特殊或主链尚未闭合。

## 九、评分依据

以下摘要说明各项目主要拉分项和限分项。链接缩写为会话管理（C）、请求与上下文（X）、消息渲染（R）、渠道（P）、Agent 角色（A）、Agent 工具（T）和仓库分布（E）。

- **AIO Hub**：stable/pending AST、Key 健康状态、富 Agent 配置和资产兼容拉高渲染、渠道、角色与生态分；文件边界只靠前端字符串判断、分布式入向调用和凭据明文限制工具与安全分。[C](会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md) [X](对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md) [R](消息渲染器/AIO-Hub-消息渲染器调查笔记.md) [P](LLM渠道管理/AIO-Hub-LLM渠道管理调查笔记.md) [A](Agent角色/AIO-Hub-Agent角色配置调查笔记.md) [T](Agent工具/AIO-Hub-Agent工具调查笔记.md) [E](仓库分布/AIO-Hub-仓库分布调查笔记.md)
- **AstrBot**：九阶段 IM 流水线、统一消息组件、多能力 Provider 实例和四路工具注册形成完整机器人框架；桌面场景不适用，平台转换分叉、默认成员权限和 Dashboard 返回完整 Key 构成主要限制。[C](会话与消息管理/AstrBot-会话与消息管理调查笔记.md) [X](对话请求与上下文/AstrBot-对话请求与上下文调查笔记.md) [R](消息渲染器/AstrBot-消息渲染器调查笔记.md) [P](LLM渠道管理/AstrBot-LLM渠道管理调查笔记.md) [A](Agent角色/AstrBot-Agent角色配置调查笔记.md) [T](Agent工具/AstrBot-Agent工具调查笔记.md) [E](仓库分布/AstrBot-仓库分布调查笔记.md)
- **Chatbox**：typed parts、虚拟列表、Provider 注册表、会话快照和不可绕过的高风险审批类别使主路径均衡；Windows 无 OS 隔离、工具名静默冲突、Copilot 能力边界较窄和完整配置备份含凭据限制上限。[C](会话与消息管理/Chatbox-会话与消息管理调查笔记.md) [X](对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md) [R](消息渲染器/Chatbox-消息渲染调查笔记.md) [P](LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md) [A](Agent角色/Chatbox-Agent角色配置调查笔记.md) [T](Agent工具/Chatbox-Agent工具调查笔记.md) [E](仓库分布/Chatbox-仓库分布调查笔记.md)
- **Cherry Studio**：SQLite 消息树、流式 overlay、结构化 parts、Provider/Endpoint/Adapter 分层和大规模测试资产形成完整客户端底座；普通聊天与 Agent 双链、主进程工具执行、`acceptEdits` 首词匹配和缺少跨 Provider 高可用是主要限分项。[C](会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md) [X](对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) [R](消息渲染器/Cherry-Studio-消息渲染调查笔记.md) [P](LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) [A](Agent角色/Cherry-Studio-Agent角色配置调查笔记.md) [T](Agent工具/Cherry-Studio-Agent工具调查笔记.md) [E](仓库分布/Cherry-Studio-仓库分布调查笔记.md)
- **DeepChat**：主进程权威 transcript、结构化 blocks、窗口化渲染、Provider 与能力元数据分层、Agent descriptor 和参数哈希绑定审批形成较完整闭环；Agent revision、凭据静态保护及部分崩溃和乱序行为仍缺确认。[C](会话与消息管理/DeepChat-会话与消息管理调查笔记.md) [X](对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md) [R](消息渲染器/DeepChat-消息渲染器调查笔记.md) [P](LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) [A](Agent角色/DeepChat-Agent角色配置调查笔记.md) [T](Agent工具/DeepChat-Agent工具调查笔记.md) [E](仓库分布/DeepChat-仓库分布调查笔记.md)
- **Hermes Agent**：后端 SQLite 唯一事实源、跨界面事件协议、多层渠道 fallback、fail-closed 审批、工具预算和大规模测试使综合分最高；人格不是独立版本实体，host 工具仍在主进程执行，`execute_code` RPC 子工具旁路不重复走编排层审批。[C](会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md) [X](对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md) [R](消息渲染器/Hermes-Agent-消息渲染器调查笔记.md) [P](LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md) [A](Agent角色/Hermes-Agent-Agent角色配置调查笔记.md) [T](Agent工具/Hermes-Agent-Agent工具调查笔记.md) [E](仓库分布/Hermes-Agent-仓库分布调查笔记.md)
- **Jan**：AI SDK parts、严格 Artifact 沙箱、线程 Assistant 快照、OS keyring 与失败换 Key 使客户端主链较稳；桌面消息整文件重写、不恢复未完成回合、工具执行缺少强隔离和角色类型往返未完全确认限制得分。[C](会话与消息管理/Jan-会话与消息管理调查笔记.md) [X](对话请求与上下文/Jan-对话请求与上下文调查笔记.md) [R](消息渲染器/Jan-消息渲染器调查笔记.md) [P](LLM渠道管理/Jan-LLM渠道管理调查笔记.md) [A](Agent角色/Jan-Agent角色配置调查笔记.md) [T](Agent工具/Jan-Agent工具调查笔记.md) [E](仓库分布/Jan-仓库分布调查笔记.md)
- **LobeHub**：conversation-flow、工具渲染注册表、Provider 加密、丰富 Agent 配置和大型 monorepo 测试构成明显强项；多数内建工具未声明审批即自动执行、connector 权限异常方向、MCP 执行隔离和服务端中断只在步骤边界检查拉低安全与工具分。[C](会话与消息管理/LobeHub-会话与消息管理调查笔记.md) [X](对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md) [R](消息渲染器/LobeHub-消息渲染调查笔记.md) [P](LLM渠道管理/LobeHub-LLM渠道管理调查笔记.md) [A](Agent角色/LobeHub-Agent角色配置调查笔记.md) [T](Agent工具/LobeHub-Agent工具调查笔记.md) [E](仓库分布/LobeHub-仓库分布调查笔记.md)
- **Manifold Desktop**：实现边界简单，Provider 注册和 WebView2 流式桥已存在；正常聊天不持久化、assistant 不回写上下文、Markdown 无 sanitizer、MCP 只展示不执行、取消不能主动中止阻塞读取且没有测试树，主链尚未闭合。[C](会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md) [X](对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md) [R](消息渲染器/Manifold-Desktop-消息渲染调查笔记.md) [P](LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md) [A](Agent角色/Manifold-Desktop-Agent角色配置调查笔记.md) [T](Agent工具/Manifold-Desktop-Agent工具调查笔记.md) [E](仓库分布/Manifold-Desktop-仓库分布调查笔记.md)
- **NextChat**：客户端会话 store、Mask 完整副本、Provider adapters 和 opaque-origin Artifact 足以支撑轻量聊天；工具没有统一审批、沙箱或步数上限，MCP 子进程继承完整环境，用户 Key 明文持久化且服务端日志可打印 Key，工程与安全上限较低。[C](会话与消息管理/NextChat-会话与消息管理调查笔记.md) [X](对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) [R](消息渲染器/NextChat-消息渲染器调查笔记.md) [P](LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) [A](Agent角色/NextChat-Agent角色配置调查笔记.md) [T](Agent工具/NextChat-Agent工具调查笔记.md) [E](仓库分布/NextChat-仓库分布调查笔记.md)
- **OpenCode**：SQLite 权威会话、SSE 事件投影、Worker Markdown、虚拟列表、配置化 Agent、AI SDK 工具循环和包级测试使 Agent 与二次开发得分突出；shell 无沙箱、审批无超时、凭据明文和消息全文搜索缺失限制安全与渠道分。[C](会话与消息管理/OpenCode-会话与消息管理调查笔记.md) [X](对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) [R](消息渲染器/OpenCode-消息渲染调查笔记.md) [P](LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) [A](Agent角色/OpenCode-Agent角色配置调查笔记.md) [T](Agent工具/OpenCode-Agent工具调查笔记.md) [E](仓库分布/OpenCode-仓库分布调查笔记.md)
- **Open WebUI**：服务端协同聊天、多模型分支、token 级 Svelte 渲染、连接行渠道、Workspace Model 和多来源工具形成完整 Web 平台；history JSON 与消息行双写、普通 LLM 请求无重试、仓内测试极少及外部内容注入边界限制工程与安全分。[C](会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md) [X](对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md) [R](消息渲染器/Open-WebUI-消息渲染器调查笔记.md) [P](LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md) [A](Agent角色/Open-WebUI-Agent角色配置调查笔记.md) [T](Agent工具/Open-WebUI-Agent工具调查笔记.md) [E](仓库分布/Open-WebUI-仓库分布调查笔记.md)
- **Pi**：JSONL 追加型会话树、终端安全渲染、多 Provider 包、项目文件提示词、统一 agent-loop 和高测试密度适合本地编码工作流；没有 MCP、逐次审批、迭代上限、角色实体和提示词快照，bash 在宿主进程权限下执行。[C](会话与消息管理/Pi-会话与消息管理调查笔记.md) [X](对话请求与上下文/Pi-对话请求与上下文调查笔记.md) [R](消息渲染器/Pi-消息渲染器调查笔记.md) [P](LLM渠道管理/Pi-LLM渠道管理调查笔记.md) [A](Agent角色/Pi-Agent角色配置调查笔记.md) [T](Agent工具/Pi-Agent工具调查笔记.md) [E](仓库分布/Pi-仓库分布调查笔记.md)
- **SillyTavern**：角色卡、World Info、swipe、Connection Profile、HTML/CSS 兼容和扩展事件构成样本中最强的角色内容生态；累计全文重渲染、整文件会话、核心测试较少、工具无逐次审批以及导入内容可注册 STscript 工具明显压低工具、安全和工程分。[C](会话与消息管理/SillyTavern-会话与消息管理调查笔记.md) [X](对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md) [R](消息渲染器/SillyTavern-消息渲染调查笔记.md) [P](LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md) [A](Agent角色/SillyTavern-Agent角色配置调查笔记.md) [T](Agent工具/SillyTavern-Agent工具调查笔记.md) [E](仓库分布/SillyTavern-仓库分布调查笔记.md)
- **VCPChat**：稳定区/尾区渲染、可执行富消息、Topic/群聊和 VCP 生态把渲染与扩展能力推到很高；单网关、宿主脚本执行、宽本机工具、明文凭据备份、单聊无本地 abort 和极少自动测试使安全、渠道与工程分较低。[C](会话与消息管理/VCPChat-会话与消息管理调查笔记.md) [X](对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) [R](消息渲染器/VCPChat-消息渲染器调查笔记.md) [P](LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md) [A](Agent角色/VCPChat-Agent角色配置调查笔记.md) [T](Agent工具/VCPChat-Agent工具调查笔记.md) [E](仓库分布/VCPChat-仓库分布调查笔记.md)
- **VCPToolBox**：VCP 协议、语义虚拟模型、AgentAssistant、插件和分布式执行形成有特色的编排生态；它没有最终用户 Chat/渲染主链，核心仍是单上游单 Key，审批身份共用全局 Key，插件安全强度不一致且测试资产较少。[C](会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md) [X](对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md) [P](LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md) [A](Agent角色/VCPToolBox-Agent角色配置调查笔记.md) [T](Agent工具/VCPToolBox-Agent工具调查笔记.md) [E](仓库分布/VCPToolBox-仓库分布调查笔记.md)

## 十、依据索引

- [Agent 工具横向对比](Agent工具/Agent工具横向对比.md)
- [Agent 角色横向对比](Agent角色/Agent角色横向对比.md)
- [会话与消息管理横向对比](会话与消息管理/会话与消息管理横向对比.md)
- [对话请求与上下文横向对比](对话请求与上下文/对话请求与上下文横向对比.md)
- [Chat UI 横向对比](<Chat UI/ChatUI横向对比.md>)
- [Chat 横向对比（概览与跨类目导航）](Chat/Chat横向对比.md)
- [LLM 渠道管理横向对比](LLM渠道管理/LLM渠道管理横向对比.md)
- [仓库分布横向对比](仓库分布/仓库分布横向对比.md)
- [消息渲染器横向对比](消息渲染器/消息渲染器横向对比.md)
- [AI 客户端完整体验栈与模块组合构想](AI客户端最佳模块组合构想.md)

人类评价：还要再继续挖掘，目前的评价有些偏平庸向，大概是说有的项目在特色上不突出但是做的看起来比较标准化，容易获得AI评委的好感
