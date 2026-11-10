# LobeHub 独特功能调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：只读盘点根 README 功能声明、SPA 路由注册表（`src/spa/router/desktopRouter.shared.tsx`）、数据库 schema（`packages/database/src/schemas/`）与后端服务/工作流（`apps/server/src/workflows-hono/`、`apps/server/src/services/taskRunner/`、`apps/server/src/services/memory/`）；补充复核异构 Agent runtime、设备网关和外部应用 Connector；未修改仓库源码
>
> 调查范围：README 宣布的 Operator/Create/Collaborate/Evolve 四组能力——Agent 运营、IM 网关、Agent Builder、Agent Groups、Pages、Schedule、Project、Workspace、Personal Memory，以及外部 CLI/平台 Agent 的统一托管；重点走通运营、日程、项目、个人记忆与异构 Agent 主链；插件、知识库、文档 Portal 和 Connector 执行细节只做回链不重写
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 当前 README 已把产品叙事升级为“Agents as the Unit of Work”，并把九个能力打包进四组（Operator / Create / Collaborate / Evolve）。这九项在本快照上均可定位到源码，但成熟度差异大：

| 候选 | 证据状态 | 一句话结论 |
|---|---|---|
| Schedule（任务调度与自动化） | `主链确认`（静态证据） | 完整主链：创建任务 → run/调度 tick → TaskRunnerService → headless execAgent → 主题会话 + Brief 汇报 → PostgreSQL 持久化；QStash cron 与本地 setTimeout 双实现 |
| Personal Memory | `主链确认`（静态证据） | 完整主链：对话 topic → Upstash Workflow（hourly / 用户触发）→ CEPA+Identity 五层提取 → 1024 维向量入库 → 记忆工具 9 API 读写 → 记忆管理页面编辑 |
| Agent 运营（Brief 汇报 + Work 产物 + 用量统计） | `主链确认`（Brief/Work 部分）/ `入口确认`（统计部分） | “hires, schedules, reports”中的 reports 落在 Briefs（decision/result/insight/error）+ HomeInbox 双栏 + Work 版本化产物对象；统计页为独立入口 |
| Agent Builder | `主链确认`（静态证据） | 内置 agent-builder 角色 + `lobe-agent-builder` 工具（读模型/搜工具/装插件/改配置），冲突工具被剥离；对话式配置 Agent 的完整闭环 |
| 异构 Agent 统一托管 | `主链确认`（静态证据） | 十三种本地执行体（增加 Factory Droid 与 Devin）经 driver + stream adapter 统一为 LobeHub operation/message；OpenClaw/Hermes 作为 platform task 启动、续接、取消并通过 notify 回流，横向比较见[外部执行体与应用协作类目](../外部执行体与应用协作/外部执行体与应用协作横向对比.md) |
| Agent Share 访客运行 | `主链确认`（静态证据） | Agent 可通过链接供已登录访客发起独立会话；分享配置限制访客主题数、每主题回合数、工具/API、模型与错误详情可见性，并在运行时隔离创建者文件、知识、设备与凭据 |
| IM 网关（Messenger / Agent Bot） | `入口确认` | Slack/Discord/Telegram/WeChat 平台注册、OAuth 安装、webhook 入口、cron 保活；webhook → execAgent 的消息往返未逐平台验证 |
| Workspace | `入口确认` | workspaces 表 + `/:workspaceSlug/*` 路由镜像 + 成员/预算/审计/配额设置页；共享设备池等治理面与已有 Agent 工具笔记的设备链衔接 |
| Pages | `入口确认` | `page/[id]` + PageEditor（文档锁、多 Agent copilot）；文档对象链已在生成式输出与运行时笔记覆盖，本笔记补产品表面 |
| Agent Groups | `入口确认`/`归并已有类目` | 群组对象与模板已被 Agent 角色笔记覆盖；群聊会话表面在会话类目边界内，本次只确认路由与成员编辑面 |
| Project | `主链确认`（静态证据） | 已落地 `projects` 实体（表 + tRPC CRUD + CLI 命令 + project-coordinator 内置 Agent），与按工作目录的话题分组并存 |

README 四个宣传点中，**Schedule 与 Personal Memory 已形成可走通的独特主链**；Agent 运营（Brief/Work）是第三个高价值候选，但“hires”（Agent 市场/雇用）与统计页只到入口级。源码范围还确认了首页未展开的**异构 Agent 统一托管**：本地 coding CLI 和 OpenClaw/Hermes 都成为一等执行对象。Workspace 与 Pages 属于跨类目组合能力，达到入口确认，完整主链依赖既有类目笔记的文档/权限/设备链。**Goals（目标任务闭环）** 已具备可走通的静态主链（见能力五），Project 从“轻量组织概念”升级为独立实体。

## 系统边界

- SPA 路由集中在 `src/spa/router/desktopRouter.shared.tsx`，业务在 `src/features/`。
- 后端为 `apps/server`（Hono + TRPC + Drizzle/PostgreSQL），异步长流程走 Upstash Workflows/QStash（`apps/server/src/workflows-hono/`），本地/桌面环境回退到进程内调度。
- 与既有笔记的分工：Agent 配置对象（[Agent角色笔记](../Agent角色/LobeHub-Agent角色配置调查笔记.md)）、工具注入/审批/执行（[Agent工具笔记](../Agent工具/LobeHub-Agent工具调查笔记.md)）、文档/Portal（[生成式输出与运行时笔记](../生成式输出与运行时/LobeHub-生成式输出与运行时调查笔记.md)）。

## 介绍声明与候选盘点

根 README（README.md:117-183）按四组声明：

- **Operator**：宣称“Hires, schedules, and reports on your entire AI team”，并单列 IM Gateway；
- **Create**：Agent Builder（“describe what you need once, and the agent setup starts right away”）与 10,000+ Skills；
- **Collaborate**：Agent Groups、Pages（shared context 多 Agent 协作写作）、Schedule（定时运行）、Project（按项目组织）与 Workspace（团队共享空间）；
- **Evolve**：Personal Memory（Continual Learning + White-Box Memory，结构化可编辑）。

路由注册表 `src/spa/router/desktopRouter.shared.tsx` 与四组声明一一对应，关键路径按职能分三类：
- Agent 侧：`agent/` 下挂 task、tasks、statistics 与 permission 四个子路由，另有 `group/` 与 `memory/`，后者按 identities、contexts、preferences、experiences、activities 五个记忆分区组织；
- 任务与工作区：`page/:id` 提供单页编辑入口，`tasks` 与 `task/:taskId` 组成跨 Agent 任务工作区，`/:workspaceSlug/*` 是工作区路由镜像；
- 社区与创作：`community/` 覆盖 Agent 市场与社区，`image` 与 `video` 属创作面，本次不展开。

设置面另有 `settings/messenger` 与 `agent/channel`（IM 渠道）。

## 已确认的独特能力

### 能力一：Schedule——任务调度与自动化（`主链确认`，静态证据）

**用户目标**：让 Agent 在用户离线时按 cron 或心跳间隔反复执行同一任务，并把每次运行的结果汇报回用户，普通 Chat 无法提供“任务对象 + 自动触发 + 汇报”的闭环。

**入口与触发者**（三类触发均确认）：

1. 用户手动：任务运行服务提供手动 "run now" 入口，由 TaskRunnerService.runTask 承接（`apps/server/src/services/taskRunner/index.ts:68`）；
2. 定时调度：QStash 中央调度器在 /api/workflows/task/schedule-dispatch 入口上按 cron 表达式、时区与去重规则算出执行时间，筛出到期任务后 fan-out 到 /schedule-execute，再由 runScheduleTick 逐个跑完（`apps/server/src/router-hono/workflows/task/handlers/scheduleDispatch.ts`、`apps/server/src/services/taskRunner/scheduleTick.ts:38`）；
3. 心跳：QStash 自续期的 /heartbeat-tick 与本地 LocalTaskScheduler 共同承担心跳，后者以 setTimeout 实现，供本地开发与 Electron 环境使用（`apps/server/src/services/taskScheduler/impls/local.ts:17`）。

**事实对象**：`tasks` 表是任务的事实模型（`packages/database/src/schemas/task.ts:25`），主要字段按用途分组：
- 调度：automationMode 决定走 heartbeat 还是 schedule，另有 cron 表达式与执行时区，以及心跳间隔、心跳超时和最近心跳时间；
- 生命周期：status 覆盖 backlog、running、paused、completed、failed、canceled 与 scheduled；parentTaskId 构成自引用树，taskDependencies 记录 blocks、relates 与条件依赖占位；
- 附属对象：任务文档 taskDocuments、每次运行一条的 topic 关系 taskTopics（触发来源区分 manual/schedule/heartbeat，另带 handoff 与评审字段）、评论 taskComments 与汇报 briefs。
任务不继承父级配置，context 与 config 各自独立（schema 注释）。

**完整主链**：用户在创建弹窗（含 cron 配置与调度表单）中建好任务后，runTask 先解析执行者，未指定时回退 inbox agent，再检查冲突（已有 running topic 则拒绝本次运行）并清理心跳超时，随后把任务指令与工作区文档上下文组装成输入，交给无头执行体 AiAgentService.execAgent（`apps/server/src/services/taskRunner/index.ts:191`，headless 审批模式，挂载 task skill 与可选 Brief 工具）。Agent 在主题会话中执行，并可经 lh task CLI 自行查看或编辑任务、建子任务、写文档、发汇报评论；任务技能约定自动化任务永不 complete，否则循环被永久解除（`packages/builtin-skills/src/task/SKILL.md`）。完成回调经 webhook /api/workflows/task/on-topic-complete 新建 taskTopic 行并更新心跳。

**用户结果**：任务以看板与详情页呈现（`AgentTaskList/`、`AgentTaskDetail/`），详情含指令编辑、子任务树、评论、文档、话题抽屉与人工验收（验收标准与完成判定界面），`taskTopics.handoff` 提供 LLM 摘要的交接信息。自动触发结果经 Brief 系统回流（见能力三）。

**持续性**：全部状态在 PostgreSQL；调度 tick 以 DB 为权威（`scheduleTick.ts:35` 注释），用户暂停/取消/改模式后到期消息被跳过；执行次数配额只统计自动化 tick；watchdog（`router-hono/workflows/task/handlers/watchdog.ts`）扫描 running 超时任务；失败回退：自动化任务回 `scheduled`（保住下次 tick），非自动化回 `paused`（`taskRunner/index.ts:267-271`）。

**主动性与取消**：用户可 pause/cancel；人工等待语义由“未解决 urgent brief”实现——`briefModel.hasUnresolvedUrgentByTask` 命中则跳过本次 tick（`scheduleTick.ts:76`、`heartbeatTick.ts:76`），即“Agent 需要人时自动停摆”。

**人机关系**：headless 审批（工具审批笔记已覆盖该模式语义）；用户通过评论、验收标准、评论反馈介入；依赖链完成后 `cascadeOnCompletion` 自动启动下游任务（`taskRunner/index.ts:303`）。

**外部依赖**：QStash 为生产调度后端（Vercel cron 触发入口 `gatewayCron` 之外），本地回退 `LocalTaskScheduler`；`isExecutionTime` 的 cron 求值在 `@lobechat/utils/cronEval`。

**独特性判断**：任务对象（树、依赖、配额、验收）与 Agent 运行（topic、heartbeat、汇报）绑成一个生命周期，且由 Agent 通过 `lh task` 工具自我管理——不是单纯“定时发消息”，也不是外部 cron 薄壳。与 VCPToolBox TaskAssistant（interval/cron/manual）、Hermes cron（会话级定时消息）的差异：LobeHub 以任务为持久化事实对象，Agent 是执行者与自我维护者。

### 能力二：Personal Memory——白盒个人记忆（`主链确认`，静态证据）

**用户目标**：把分散会话中关于用户的事实（身份、偏好、经历、活动、情境）持续结构化沉淀，Agent 在对话中可检索、可写、可改、可删，且用户能逐条查看编辑（README “White-Box Memory”）。

**入口与触发者**：

- 自动：QStash 每小时触发 cron /call-cron-hourly-analysis，由 hourly workflow 全量扫描用户 topic（`apps/server/src/router-hono/workflows/memory-user-memory/index.ts`）；
- 用户触发：记忆页面的“分析”动作调用 ActionBar 的 showAnalysis，进度落在 asyncTasks 实体上（`src/routes/(main)/memory/(home)/index.tsx:50`）；
- 对话中：Agent 经 `lobe-user-memory` 工具主动读写（见下）。

**事实对象**：`user_memories` 主表（`packages/database/src/schemas/userMemories/index.ts`）+ 五个层表，每层一个记忆类型、带独立字段与 1024 维向量列（HNSW 索引）：

| 层表 | 内容与关键字段 |
|---|---|
| `userMemoriesContexts` | 情境：影响/紧迫度评分、关联对象与主体 |
| `userMemoriesExperiences` | 经历：情况/行动/推理/关键学习、置信度 |
| `userMemoriesPreferences` | 偏好：行为指令、优先级、适用场景 |
| `userMemoriesActivities` | 活动：叙述/反馈/时间地点、状态 |
| `userMemoriesIdentities` | 身份：关系/角色/发生日期 |

记忆带 `sourceIds`（支撑消息 id）、tags、accessedCount。

**完整主链**按提取、旁支、消费与用户面四段展开：

- **提取链**：话题完成或定时触发即进入 processTopic workflow；工作流调用 MemoryExtractionExecutor.extractTopic，由 @lobechat/memory-user-memory 包分 CEPA 层与 Identity 层两阶段提取，层可按需选择，LLM 提取与向量嵌入的结果写入五层表（`apps/server/src/router-hono/workflows/memory-user-memory/workflows/processTopic.ts`、`apps/server/src/services/memory/userMemory/extract/extractTopic.ts`）；
- **旁支管线**：同目录另有两条独立管线，consolidation.ts 负责可回退的记忆合并，personaUpdate.ts 负责画像更新；
- **消费链**：lobe-user-memory 工具提供 9 个 API，覆盖带多查询、层/标签/关系/时间意图过滤的语义检索与分类查询，各层新增与身份更新走合并策略写入，删除必须给理由；工具注入受 globalMemoryEnabled 门控（`packages/builtin-tool-memory/src/manifest.ts:91`）；
- **用户面**：/memory 下六条路由对应五层记忆与 home，home 含 Persona 与 RoleTagCloud；各层提供列表、网格与时间线视图和编辑入口，记忆卡片在对话中以特殊渲染投影（`packages/builtin-tool-memory/src/client/`）。

**持续性**：PostgreSQL + 向量索引；hourly workflow 用游标续扫避免重复处理，取消请求协作式级联传播，失败回调不重试风暴（`WorkflowNonRetryableError`，`processTopic.ts:268`）；并行度受限（per-user key parallelism 5、全局 flowControl parallelism 25，`processTopic.ts:284-328` 注释）。

**主动性与取消**：hourly 扫描可全局关闭（runGuard）；用户主动任务可取消且进度落 `asyncTasks`；层选择（`payload.layers`）控制提取范围；`settings/memory` 与 `chatConfig.memory.*`（enabled/effort/toolPermission read-only|read-write，见 Agent 角色笔记）控制运行时行为。

**独特性判断**：五层记忆 + 结构化 taxonomy + 向量检索 + 可编辑白盒 + 来源追踪的组合在本样本中无对应实现；Open WebUI 的 Persistent Memory 是全局文本记忆，VCP 系记忆偏日志/语义动力学，均无“身份/偏好/经历/活动/情境五层 + 版本化合并策略 + 用户逐条编辑”的对象模型。记忆工具同时是 Agent 可写面（read-write 权限模型）。

### 能力三：Agent 运营——Brief 汇报与 Work 产物（`主链确认`：Brief/Work；`入口确认`：统计）

**用户目标**：用户离线时 Agent 团队自行干活，回来时获得“需要你决策/修复”与“完成报告”两级汇报，并看到统一的工作产物清单——README “reports on your entire AI team” 的实现面。

**Brief 主链**：任务运行完成后由 TaskLifecycleService.onTopicComplete 接管；默认 auto 模式调用 synthesizeTopicBrief 程序化合成 briefs 行，legacy agent 模式保留为逃生舱（`apps/server/src/services/taskLifecycle/index.ts:108,697`、`packages/database/src/schemas/task.ts:281`）。briefs 行按字段契约记录两类信息：
- 类型取 decision、result、insight、error，优先级取 urgent、normal、info；
- artifacts 由程序收集，带动作与已读/已处理状态。

用户界面 `HomeInbox` 分"Needs you"（阻塞 Agent 的 decision/fix，error 沉底）与"News"（insight/result 报告）两栏，brief 按用户且按工作区隔离；`DailyBrief` 卡片带任务引用与跳转；"未解决 urgent brief"反过来挂起后续自动化 tick（见能力一）；brief 可 resolve/标记已读。

**Work 主链**：`works` 与 `work_versions` 两张表承载"Agent 交付物"这一统一事实对象（`packages/database/src/schemas/work.ts:26,144`）。每个版本记录来源谱系——绑定的工具调用、消息、Agent、话题、线程与根操作——最新版本由 `currentVersionId` 指向。类型覆盖 document、task、external 与 filePreview，其中 external 带 github/linear 品牌图标与 URL 白名单（`src/features/Work/descriptors.tsx:34-73`）。

列表与摘要卡由独立 feature WorkGallery 提供（`src/features/WorkGallery/`），入口走 `/resource/works` 路径段与过滤参数，点击后在 Portal 中预览。Work 与工具注册里的 `work?: PluginApiWorkConfig` 衔接（Agent 工具笔记 §1.3）。

**统计入口**：`agent/statistics`（`AgentUsage`：7d/30d/90d 用量与成本、模型拆分、趋势图，`src/features/AgentUsage/hooks.ts:21`）+ `agent/permission`（工作区 Agent 的访问级 edit/use/view、模型策略 member/fixed、执行目标策略，`src/features/AgentPermission/PermissionForm.tsx`）。统计主链（数据聚合源）本次未深入。

**独特性判断**：Brief 是“Agent 需要人”与“Agent 干完活”的异步汇报信道，与任务调度构成完整离线运营闭环；Work 把文档/任务/外部服务产物统一为带版本与来源谱系的对象。二者合起来支撑 README “You stay in charge — without staying online”。

### 能力四：Agent Builder——对话式 Agent 配置（`主链确认`，静态证据）

**用户目标**：不打开几十个表单字段，用自然语言描述需求让一个专门 Agent 帮你把目标 Agent 配好（README “describe what you need once”）。

**主链**：右侧面板 `AgentBuilder`（`src/features/AgentBuilder/index.tsx:14`）先初始化一个内置角色 `AGENT_BUILDER`，slug 同名 `agent-builder`，落库持久化，定义见 `packages/builtin-agents/src/agents/agent-builder/index.ts:43`。

随后对话中挂载 `lobe-agent-builder` 工具，并剥离同族的一组 Agent 与群组管理工具，避免 builder 改到自己（四组工具名见文末索引）。配置变更经 `AgentBuilderProvider` 实时作用于左侧目标 Agent，另有群组版本 `group-agent-builder`。

工具的读写能力分开：读侧取可用模型与市场工具，写侧装插件、改 Agent 配置与提示词（`packages/builtin-tool-agent-builder/src/manifest.ts:6`）。装插件在注释里标注为"ALWAYS REQUIRES user approval even in auto-run mode"，自动运行模式下同样要人确认。

**独特性判断**：把“配置 Agent”本身做成一个 Agent 任务，且通过工具审批门把危险写操作（装插件）锁死在人审；与通用表单式配置（Cherry Studio 等）形成产品差异。运行时执行面（工具审批、配置对象）回链 Agent 工具/角色笔记。

### 能力五：Goals——带验收计划与有界自动修复的目标闭环（`主链确认`，静态证据）

**用户目标**：用户用 `/goal` 声明一个目标，Agent 把它拆成带验收标准、预算上限和轮次上限的任务循环，跑完后提交验收；普通 Chat 的"一次性回复"没有"目标 → 验收 → 有界修复"的闭环。该能力覆盖以下环节：
- `/goal` loop；
- 与任务创建拆分；
- 统一创建流程；
- goal 视图与验收进度。

**入口与触发者**：Composer 的 `/goal` 命令——`goalTag.ts` 把目标标记存为结构化 chip；发送时 `conversationLifecycle.ts:323-328` 检测 goal 提示并注入 `lobe-goal` 工具。

**事实对象**：Goal 已是独立实体。`goals` 表保存标题、完成要求、预算、生命周期以及可选的 `subjectType`/`subjectId` 执行载体；当前 `/goal` 仍可用 task 作为载体，schema 里 Goal 与 task 配置已经分离。随后加入的 goal graph 用 nodes、edges、决策、Work 版本证据和追加式事件表保留目标拆解与跨运行的人工决策，节点可关联负责执行的 task。轮次、成本与验收等执行性状态仍由载体及现有运行时表承担。

相关 schema 在 `packages/database/src/schemas/goal.ts` 与 `goalGraph.ts`；`goalShare.ts`、`goalSubscription.ts`、`goalTrace.ts` 分别承载分享、订阅与追加式轨迹。

**完整主链**：

1. `/goal` chip 经 lobe-goal 的 createGoal 建目标；该工具声明 humanIntervention 为 always，创建必须人工确认（`packages/builtin-tool-goal/src/manifest.ts`）。
2. 创建任务话题并启动 goal 循环。
3. 有界自动修复与验收：推进逻辑集中在 apps/server/src/services/goal/，advanceGoal 负责推进、decideNextMove 决定下一步、deliverySettle 处理交付收口，criteriaGenerator 生成验收标准，exploreGraph 探索目标图。
4. 验收证据链在 services/verify/：evidencePlanner 规划证据、evidenceIntake 收集材料、evidenceCoverage 评估覆盖度，goalReview 评审之后由 acceptanceDecision 给出结论、acceptanceMerge 合并结果。
5. 结果先进消息内的实时结果卡，再进入 goal 视图；路由 agent/goals 与 agent/goal/[goalId] 分别承载列表与详情，含创建、验收与 HowItWorks 页。
6. 完成或拒绝由用户验收。

**持续性与资源边界**：目标定义、图和事件在 PostgreSQL 持久化；task 与验收表继续承载执行细节。轮次与花费双上限防止失控循环；目标与载体的状态桥接、真实 UI 状态和恢复表现仍未运行验证。

**独特性判断**：把“目标”建模为可验收、可自动修复、有预算上限的任务循环，且模型通过专门工具创建（非自由文本承诺）——与任务调度的关系是“目标是一次性任务的高级包装”，与 Brief 系统的关系是“验收结论进 brief 汇报”。在本样本中无对应实现。README 未单独宣传 goals，本卡是 README 之外的实现面候选。

## 已归并到现有类目的能力

- **Agent Groups（群组对象）**：群组类型、ChatGroupWizard 六类模板与成员 Agent 结构已在 [Agent 角色笔记](../Agent角色/LobeHub-Agent角色配置调查笔记.md) §6 覆盖（类型定义见 `packages/types/src/agentGroup/index.ts`）。群组路由 group/:gid 与成员编辑面已确认存在：group/profile/features/AgentBuilder 可对成员跑 Builder，侧栏提供成员列表与添加/排序弹窗（`src/spa/router/desktopRouter.shared.tsx:206-243`）。群聊会话本体在会话与消息类目边界内；群组作为“多 Agent 并行协作”入口已确认，群体编排运行链本次未纳入调查范围。状态：`入口确认`/`归并已有类目`。
- **Pages（文档协作写作）**：文档对象（documents 行、历史、编辑锁、发布到 workspace）已在 [生成式输出与运行时笔记](../生成式输出与运行时/LobeHub-生成式输出与运行时调查笔记.md) 覆盖；产品表面由 page/:id 路由承载，PageEditor 负责文档锁语义，PageAgentProvider 提供 copilot 对话，页面元数据栏独立成栏（`src/spa/router/desktopRouter.shared.tsx:764-792`）。Pages 的“多 Agent 同页协作”运行链（协作者如何进入同一文档会话）尚未验证。状态：`入口确认`。
- **Agent 市场 / Community（hires 面）**：`community/` 路由族覆盖 agent、group_agent、model、provider、skill、mcp、user 与 org 八类对象的详情与列表，市场导入链在 Agent 角色笔记 §7 有记录；它作为运营盘点的组成部分记录在此，不单独成卡。
- **插件、知识库、搜索、设备工具**：全部回链 [Agent 工具笔记](../Agent工具/LobeHub-Agent工具调查笔记.md)，不再重复。

异构 Agent、Agent Share、Connector、Messenger 与浏览器控制表面的横向样本见[外部执行体与应用协作横向对比](../外部执行体与应用协作/外部执行体与应用协作横向对比.md)。Agent Share 的访客 topic 以 `senderId` 隔离，运行时强制 headless，数据与工具由装配期和执行期两道门禁限制；治理字段见 `packages/database/src/schemas/agentShare.ts:7-59`，执行门禁分布在 `apps/server/src/routers/lambda/shareChat/`（执行、守卫、运行控制）与 `apps/server/src/services/agentRuntime/AgentRuntimeService/shareRunGate.ts`。

## 声明不符、外部依赖与暂缓项

- **Project（按项目组织）**：Project 已是完整实体，在数据表、API、CLI 与内置 Agent 四层落地：
  - **表**：project 主体连同 projectAgents、projectChatGroups、projectKnowledgeBases 与 projectCompletionReviews 共五张表（`packages/database/src/schemas/project.ts:28`，migration 0134-0139）；
  - **API**：tRPC 路由覆盖创建、更新、删除、状态流转、验收、挂接 Agent 与知识库等写操作，统一由 withScopedPermission('agent:update') 保护（`apps/server/src/routers/lambda/project.ts`）；
  - **CLI**：project 命令提供 list、view、create、edit、delete、status 六个子命令，自述为“Manage goal-oriented projects”（`apps/cli/src/commands/project.ts`）；
  - **内置 Agent**：project-coordinator 按项目名生成协调者 systemRole（`packages/builtin-agents/src/agents/project-coordinator/index.ts`）。
  话题侧的“按项目组织”另有一套实现，仍以工作目录为键：groupTopicsByProject 用 project: 前缀分组、把没有项目的话题沉底为 no-project，话题管理工具同样按工作目录路径分组。实体项目与工作目录分组两套“项目”语义并存，话题如何归属到 projects 表的关联链本次未走通（`packages/utils/src/client/topic.ts:161-196`）。状态：`主链确认`（静态证据，实体项目侧）；分组侧维持原结论。
- **IM 网关**：六个平台（slack、telegram、discord、wechat、line、imessage）的渠道路由与 webhook 处理器、OAuth 安装、cron 保活、外部 MESSAGE_GATEWAY 通道以及 verify-im 验证路由均确认存在，安装流程由 messengerInstall、messengerOAuthCallback 等 handler 承担，消息从 /api/agent/webhooks/:platform 统一进入（`apps/server/src/router-hono/agent/handlers/`、`gatewayCron.ts:189-197`）。单平台“用户在 IM 发消息 → 绑定 Agent 会话 → 回复回 IM”的完整往返与消息持久化语义尚未逐一走通（bot 场景的工具设备访问策略在 Agent 工具笔记 §7.2 已有记录）。状态：`入口确认`。
- **Workspace**：workspaces 表以 slug、name 与 primaryOwnerId 标识团队空间，/:workspaceSlug/* 路由镜像出一整套工作区页面，社区工作区详情页与共享设备池同样在位（`packages/database/src/schemas/workspace.ts:19`、`src/spa/router/desktopRouter.shared.tsx:880-1108`，设备池见 Agent 工具笔记 §7.2）。设置面按组织、计费与资源三组展开：组织侧有成员、通知、标签与审计日志；计费与用量侧有统计、计划、账单、预算、额度与用量；资源侧有服务模型、凭据、API key、OAuth 应用、存储与设备。另有工作区 API Key 的能力范围列（按成员权限收敛作用域）、成员可为共享内建 Agent 选择个人模型，以及群组权限页（`src/routes/(main)/group/permission/index.tsx`）。Workspace 是“团队级 Agent 治理与共享”的容器，邀请、角色与配额执行点构成的成员/权限/预算主链尚未逐个验证。状态：`入口确认`。
- **Agent 运营的 hires 面**：Agent 市场/社区、ConnectAgent 的“雇用”链路未单独走通；统计页数据聚合（usage 记录的写入与汇总）未验证。状态：`入口确认`。
- **全文检索后端切换**：统一 FTS facade 支持 PostgreSQL 与可选 Elasticsearch。Elasticsearch 只负责候选召回，最终由 PostgreSQL 按用户、工作区与可见性水化；同步 worker、outbox、mapping generation 和 alias 构成独立部署边界。它属于跨实体检索基础设施，不单独计入特色贡献。状态：`主链确认`（静态源码）。见 `packages/database/src/repositories/ftsSearch/index.ts:39-77,98-199`、`elasticsearch.ts:67-168`。
- **image/video 创作工作台**（`(create)/image`、`(create)/video` 路由族）为 README 之外的独立创作面，本次不展开（未验证事项）。

## 对特色贡献统计的影响

- 主贡献候选建议：任务调度与自动化（Schedule）与白盒个人记忆（Personal Memory）均可按静态主链确认计入，标签为“主动 Agent”“记忆演化”；Agent 运营汇报（Brief + Work）以组合贡献计入，标签为“主动 Agent”“活对象”；Goals（目标闭环）单独列为主贡献候选，标签同为“主动 Agent”“活对象”。
- 辅助贡献候选：Agent Builder 属“人类工具面”的反向用法（人通过 Agent 配置 Agent），另有 IM 网关（“多表面连续性”）、Workspace（“协同工作区”）与 Project（实体化后从暂缓项升级为辅助候选，标签“协同工作区”）。
- 与待查清单“Agent 社会/群体”聚类的交点仍在 Agent Groups 会话面：运行链缺失，暂不进入统计。

## 未验证事项

- 任务自动化在生产环境（QStash）的运行表现、`/schedule-dispatch` 与 Vercel cron 的实际接线（本地代码只见入口与 fan-out 逻辑）。
- IM 平台消息往返（webhook → Agent 会话 → 回推）的单平台完整链路与 bot 会话持久化语义。
- Personal Memory hourly 扫描的调度 cadence 与资源消耗、提取质量（LLM 提取器未运行）。
- Workspace 成员/配额/账单执行点（邀请流程、budget 扣减、审计日志写入）。
- 统计页数据源（usage 记录写入与聚合 SQL）。
- `byProject` 分组中 workingDirectory 写入 topic metadata 的来源链（异构 Agent 运行时的目录上报）；以及实体 `projects` 表与工作目录分组两套“项目”语义的关联链（见 Project 条目）。
- Goal 循环在真实任务上的运行表现（轮次/预算触达后的 settle 行为、`sweep` 的巡检接线）——静态主链已确认但未运行验证。
- image/video 创作工作台与 Work 对象的衔接。
- 十三种本地执行体与 OpenClaw/Hermes 的运行兼容性、Windows 进程树终止、SDK/ACP/CLI runtime 切换和真实 resume 行为。

## 关键源码索引

- 路由全貌：`src/spa/router/desktopRouter.shared.tsx`（agent/group/memory/page/tasks/workspaceSlug 各段）。
- 任务调度：`packages/database/src/schemas/task.ts`、`apps/server/src/services/taskRunner/index.ts`、`scheduleTick.ts`、`heartbeatTick.ts`、`apps/server/src/services/taskScheduler/impls/local.ts`、`apps/server/src/workflows-hono/task/handlers/scheduleDispatch.ts`、`packages/builtin-skills/src/task/SKILL.md`。
- 个人记忆：`packages/database/src/schemas/userMemories/index.ts`、`apps/server/src/services/memory/userMemory/extract.ts`、`apps/server/src/workflows-hono/memory-user-memory/workflows/processTopic.ts`、`packages/builtin-tool-memory/src/manifest.ts`、`src/routes/(main)/memory/(home)/index.tsx`。
- 运营汇报：`apps/server/src/services/taskLifecycle/index.ts`（onTopicComplete/synthesizeTopicBrief）、`packages/database/src/schemas/task.ts`（briefs）、`src/features/HomeInbox/index.tsx`、`packages/database/src/schemas/work.ts`、`src/features/Work/descriptors.tsx`、`src/features/AgentUsage/hooks.ts`。
- Agent Builder：`packages/builtin-agents/src/agents/agent-builder/index.ts`、`packages/builtin-tool-agent-builder/src/manifest.ts`、`src/features/AgentBuilder/index.tsx`（被剥离的四组工具：`lobe-agent-management`、`lobe-group-management`、`lobe-group-agent-builder`、`lobe-agent`）。
- IM 网关：`src/features/Messenger/index.tsx`、`apps/server/src/router-hono/agent/handlers/{platformWebhook,messengerInstall,messengerOAuthCallback,gatewayCron}.ts`。
- Agent Share：`packages/database/src/schemas/agentShare.ts`、`apps/server/src/routers/lambda/agentShare.ts`、`apps/server/src/services/aiAgent/{shareGate,shareVisitorAbuseGuards}.ts`。
- 项目分组：`packages/utils/src/client/topic.ts:161`、`src/store/chat/slices/topic/selectors.ts:203`、`src/features/AgentSidebar/Topic/utils/topicGroupMode.ts`。
- Project 实体：`packages/database/src/schemas/project.ts`、`apps/server/src/routers/lambda/project.ts`、`apps/cli/src/commands/project.ts`、`packages/builtin-agents/src/agents/project-coordinator/index.ts`。
- Goals：`packages/builtin-tool-goal/src/manifest.ts`、`apps/server/src/services/goal/advanceGoal.ts`、`apps/server/src/services/verify/{evidencePlanner,goalReview,acceptanceDecision}.ts`、`src/features/AgentGoals/`、`src/features/ChatInput/InputEditor/ActionTag/goalTag.ts`。
- 异构 Agent：`packages/types/src/agent/heterogeneousAgent.ts`、`packages/heterogeneous-agents/src/`、`apps/desktop/src/main/modules/heterogeneousAgent/`、`src/store/chat/slices/agentRun/actions/transports/hetero/heterogeneousAgentExecutor.ts`、`apps/desktop/src/main/controllers/GatewayConnectionCtr.ts`。
