# LobeHub 独特功能调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
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
| 异构 Agent 统一托管 | `主链确认`（静态证据） | 六种本地 CLI（Amp/Claude Code/Codex/OpenCode/Pi/Qoder）经 driver + stream adapter 统一为 LobeHub operation/message；OpenClaw/Hermes 作为 platform task 启动、续接、取消并通过 notify 回流，详见[分类边界研究](外部执行体与应用协作边界研究.md) |
| IM 网关（Messenger / Agent Bot） | `入口确认` | Slack/Discord/Telegram/WeChat 平台注册、OAuth 安装、webhook 入口、cron 保活；webhook → execAgent 的消息往返未逐平台验证 |
| Workspace | `入口确认` | workspaces 表 + `/:workspaceSlug/*` 路由镜像 + 成员/预算/审计/配额设置页；共享设备池等治理面与已有 Agent 工具笔记的设备链衔接 |
| Pages | `入口确认` | `page/[id]` + PageEditor（文档锁、多 Agent copilot）；文档对象链已在生成式输出与运行时笔记覆盖，本笔记补产品表面 |
| Agent Groups | `入口确认`/`归并已有类目` | 群组对象与模板已被 Agent 角色笔记覆盖；群聊会话表面在会话类目边界内，本次只确认路由与成员编辑面 |
| Project | `主链确认`（静态证据） | 上快照无独立 project 表、仅按工作目录分组；本快照已落地 `projects` 实体（表 + tRPC CRUD + CLI 命令 + project-coordinator 内置 Agent），与按工作目录的话题分组并存 |

README 四个宣传点中，**Schedule、Personal Memory 是真正形成了可走通主链的独特能力**；Agent 运营（Brief/Work）是第三个高价值候选，但“hires”（Agent 市场/雇用）与统计页只到入口级。源码范围还确认了首页未展开的**异构 Agent 统一托管**：本地 coding CLI 和 OpenClaw/Hermes 都成为一等执行对象。Workspace 与 Pages 属于跨类目组合能力，达到入口确认，完整主链依赖既有类目笔记的文档/权限/设备链。**Goals（目标任务闭环）** 已具备可走通的静态主链（见能力五），Project 从“轻量组织概念”升级为独立实体。

## 系统边界

- 本笔记当前读 HEAD `3b57a07e`；SPA 路由集中在 `src/spa/router/desktopRouter.shared.tsx`，业务在 `src/features/`。
- 后端为 `apps/server`（Hono + TRPC + Drizzle/PostgreSQL），异步长流程走 Upstash Workflows/QStash（`apps/server/src/workflows-hono/`），本地/桌面环境回退到进程内调度。
- 与既有笔记的分工：Agent 配置对象（[Agent角色笔记](../Agent角色/LobeHub-Agent角色配置调查笔记.md)）、工具注入/审批/执行（[Agent工具笔记](../Agent工具/LobeHub-Agent工具调查笔记.md)）、文档/Portal（[生成式输出与运行时笔记](../生成式输出与运行时/LobeHub-生成式输出与运行时调查笔记.md)）。

## 介绍声明与候选盘点

根 README（README.md:117-183）按四组声明：

- **Operator**：“Hires, schedules, and reports on your entire AI team” + IM Gateway（README.md:117-124）；
- **Create**：Agent Builder（“describe what you need once, and the agent setup starts right away”）、10,000+ Skills（README.md:136-143）；
- **Collaborate**：Agent Groups、Pages（shared context 多 Agent 协作写作）、Schedule（定时运行）、Project（按项目组织）、Workspace（团队共享空间）（README.md:155-163）；
- **Evolve**：Personal Memory（Continual Learning + White-Box Memory，结构化可编辑）（README.md:176-183）。

路由注册表（`src/spa/router/desktopRouter.shared.tsx`）与声明一一对应，关键路径：
- `agent/`（含 `task`、`tasks`、`statistics`、`permission`）、`group/`、`memory/`（identities/contexts/preferences/experiences/activities）；
- `page/:id`、`tasks`/`task/:taskId`（跨 Agent 任务工作区）、`/:workspaceSlug/*`（工作区镜像）；
- `community/`（Agent 市场与社区）、`image`/`video`（创作面，本次不展开）。

设置面另有 `settings/messenger` 与 `agent/channel`（IM 渠道）。

## 已确认的独特能力

### 能力一：Schedule——任务调度与自动化（`主链确认`，静态证据）

**用户目标**：让 Agent 在用户离线时按 cron 或心跳间隔反复执行同一任务，并把每次运行的结果汇报回用户，普通 Chat 无法提供“任务对象 + 自动触发 + 汇报”的闭环。

**入口与触发者**（三类触发均确认）：

1. 用户手动：任务运行服务提供手动 "run now" 入口（`apps/server/src/services/taskRunner/index.ts:68` `TaskRunnerService.runTask`）；
2. 定时调度：QStash 中央调度器 `/api/workflows/task/schedule-dispatch`（`apps/server/src/workflows-hono/task/handlers/scheduleDispatch.ts:39`）按执行时间判断（cron 表达式 + 时区 + 去重）筛选到期任务，fan-out 到 `/schedule-execute` 后由 `runScheduleTick` 执行（`apps/server/src/services/taskRunner/scheduleTick.ts:38`）；
3. 心跳：`/heartbeat-tick`（QStash 自续期）与本地 `LocalTaskScheduler`（`apps/server/src/services/taskScheduler/impls/local.ts:17`，setTimeout 实现，供本地开发/Electron 使用）。

**事实对象**：`tasks` 表（`packages/database/src/schemas/task.ts:25`）是任务的事实模型，主要字段按用途分四组：
- 调度：`automationMode`（heartbeat 或 schedule）、`schedulePattern`/`scheduleTimezone`、心跳间隔/超时/最近心跳时间；
- 生命周期：`status`（backlog/running/paused/completed/failed/canceled + scheduled）、`parentTaskId` 自引用树、`taskDependencies`（blocks/relates 及条件依赖占位）；
- 附属对象：`taskDocuments`（任务文档）、`taskTopics`（每次运行一个 topic，含 `trigger: manual|schedule|heartbeat`、`handoff`、评审字段）、`taskComments`、`briefs`。
任务无父级继承，context/config 各自独立（schema 注释）。

**完整主链**：用户在创建弹窗（前端含 cron 配置与调度表单）中建任务后，`runTask` 先解析执行者（无指定则回退 inbox agent）、做冲突检查（已有 running topic 则拒绝）、清理心跳超时，再组装任务指令与工作区文档上下文，交给无头执行体 `AiAgentService.execAgent`（`index.ts:191`，headless 审批模式，挂载 task skill 与可选 Brief 工具）。Agent 在主题会话中执行，经 `lh task` CLI 工具自行查看/编辑任务、建子任务、写文档、汇报评论；任务技能约定"自动化任务永不 complete"，否则永久解除循环（`packages/builtin-skills/src/task/SKILL.md`）。完成回调经 webhook `/api/workflows/task/on-topic-complete` 新建 taskTopic 行并更新心跳。

**用户结果**：任务以看板与详情页呈现（`AgentTaskList/`、`AgentTaskDetail/`），详情含指令编辑、子任务树、评论、文档、话题抽屉与人工验收（验收标准与完成判定界面），`taskTopics.handoff` 提供 LLM 摘要的交接信息。自动触发结果经 Brief 系统回流（见能力三）。

**持续性**：全部状态在 PostgreSQL；调度 tick 以 DB 为权威（`scheduleTick.ts:35` 注释），用户暂停/取消/改模式后到期消息被跳过；执行次数配额只统计自动化 tick；watchdog（`workflows-hono/task/handlers/watchdog.ts`）扫描 running 超时任务；失败回退：自动化任务回 `scheduled`（保住下次 tick），非自动化回 `paused`（`taskRunner/index.ts:267-271`）。

**主动性与取消**：用户可 pause/cancel；人工等待语义由“未解决 urgent brief”实现——`briefModel.hasUnresolvedUrgentByTask` 命中则跳过本次 tick（`scheduleTick.ts:76`、`heartbeatTick.ts:76`），即“Agent 需要人时自动停摆”。

**人机关系**：headless 审批（工具审批笔记已覆盖该模式语义）；用户通过评论、验收标准、评论反馈介入；依赖链完成后 `cascadeOnCompletion` 自动启动下游任务（`taskRunner/index.ts:303`）。

**外部依赖**：QStash 为生产调度后端（Vercel cron 触发入口 `gatewayCron` 之外），本地回退 `LocalTaskScheduler`；`isExecutionTime` 的 cron 求值在 `@lobechat/utils/cronEval`。

**独特性判断**：任务对象（树、依赖、配额、验收）与 Agent 运行（topic、heartbeat、汇报）绑成一个生命周期，且由 Agent 通过 `lh task` 工具自我管理——不是单纯“定时发消息”，也不是外部 cron 薄壳。与 VCPToolBox TaskAssistant（interval/cron/manual）、Hermes cron（会话级定时消息）的差异：LobeHub 以任务为持久化事实对象，Agent 是执行者与自我维护者。

**任务调度主链的补充面**（`5952f4c3..HEAD`）：调度主链结论不变，以下为补充实现：

- Home 新增“scheduled-tasks 块”，任务模式以任务为形状呈现（`919195508`）；任务详情与列表状态同步修复（`8c62e226e`），cron 默认开启（`5af4f096d`）。
- “移除任务交付验收”操作（`78f132768`）；creator 任务回调为持久化投递（`975e21cf8`，`workflows/task/handlers/onCreatorComplete.ts`），回调投递串行化防重放（`51e24a0e9`）。
- 任务回调卡并入 goal 进度显示（`c0c56d6b0`）；scheduled-run 的乐观写回不被 watch 覆盖（`4afc5d4b0`）；任务校验 UI 重构（`TaskVerifyConfig`、RunVerifyTag 等）。

### 能力二：Personal Memory——白盒个人记忆（`主链确认`，静态证据）

**用户目标**：把分散会话中关于用户的事实（身份、偏好、经历、活动、情境）持续结构化沉淀，Agent 在对话中可检索、可写、可改、可删，且用户能逐条查看编辑（README “White-Box Memory”）。

**入口与触发者**：

- 自动：QStash 每小时 cron `/call-cron-hourly-analysis`（`apps/server/src/workflows-hono/memory-user-memory/index.ts:18`）→ `hourly` workflow 全量扫描用户 topic；
- 用户触发：记忆页面“分析”动作（`src/routes/(main)/memory/(home)/index.tsx:50` `ActionBar showAnalysis`）+ `asyncTasks` 进度实体；
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

**完整主链**（按职能拆三段）：
- **提取链**：话题完成或定时触发 `processTopic` workflow（`workflows/processTopic.ts:32`）→ `MemoryExtractionExecutor.extractTopic`（`services/memory/userMemory/extract.ts`，由 `@lobechat/memory-user-memory` 包执行 CEPA 层与 Identity 层两阶段提取，层可选）→ LLM 提取 + 向量嵌入 → 写入五层表；
- **消费链**：`lobe-user-memory` 工具（`packages/builtin-tool-memory/src/manifest.ts:91`）提供 9 个 API——语义检索（多查询 + 层/标签/关系/时间意图过滤）、分类查询，以及各层新增、身份更新的合并策略写入与必须给理由的删除；工具注入受 `globalMemoryEnabled` 门控；
- **用户面**：`/memory` 六条路由（identities/contexts/preferences/experiences/activities + home，home 含 Persona 与 RoleTagCloud），逐层列表/网格/时间线视图与编辑，记忆卡片在对话中以特殊渲染投影（`packages/builtin-tool-memory/src/client/`）。

**持续性**：PostgreSQL + 向量索引；hourly workflow 用游标续扫避免重复处理，取消请求协作式级联传播，失败回调不重试风暴（`WorkflowNonRetryableError`，`processTopic.ts:268`）；并行度受限（per-user key parallelism 5、全局 flowControl parallelism 25，`processTopic.ts:284-328` 注释）。

**主动性与取消**：hourly 扫描可全局关闭（runGuard）；用户主动任务可取消且进度落 `asyncTasks`；层选择（`payload.layers`）控制提取范围；`settings/memory` 与 `chatConfig.memory.*`（enabled/effort/toolPermission read-only|read-write，见 Agent 角色笔记）控制运行时行为。

**独特性判断**：五层记忆 + 结构化 taxonomy + 向量检索 + 可编辑白盒 + 来源追踪的组合在本样本中无对应实现；Open WebUI 的 Persistent Memory 是全局文本记忆，VCP 系记忆偏日志/语义动力学，均无“身份/偏好/经历/活动/情境五层 + 版本化合并策略 + 用户逐条编辑”的对象模型。记忆工具同时是 Agent 可写面（read-write 权限模型）。

### 能力三：Agent 运营——Brief 汇报与 Work 产物（`主链确认`：Brief/Work；`入口确认`：统计）

**用户目标**：用户离线时 Agent 团队自行干活，回来时获得“需要你决策/修复”与“完成报告”两级汇报，并看到统一的工作产物清单——README “reports on your entire AI team” 的实现面。

**Brief 主链**：任务运行完成 → `TaskLifecycleService.onTopicComplete`（`apps/server/src/services/taskLifecycle/index.ts:108`）→ 默认 auto 模式经 `synthesizeTopicBrief`（`index.ts:697`）程序化合成 `briefs` 行（`packages/database/src/schemas/task.ts:281`）；legacy agent 模式为逃生舱。briefs 行字段契约：
- 类型：decision/result/insight/error；优先级：urgent/normal/info；
- artifacts 程序化收集，带动作与已读/已处理状态。

用户界面 `HomeInbox` 分"Needs you"（阻塞 Agent 的 decision/fix，error 沉底）与"News"（insight/result 报告）两栏，brief 按用户且按工作区隔离；`DailyBrief` 卡片带任务引用与跳转；"未解决 urgent brief"反过来挂起后续自动化 tick（见能力一）；brief 可 resolve/标记已读。

**Work 主链**：`works` + `work_versions` 表（`packages/database/src/schemas/work.ts:26,144`）——每个版本绑定工具调用、消息、Agent、话题、线程与根操作（来源谱系），`currentVersionId` 指向最新版本；类型覆盖 document/task/external（github/linear 品牌图标与 URL 白名单，`src/features/Work/descriptors.tsx:34-73`）/filePreview；列表/摘要卡与 WorkGallery。WorkGallery 为独立 feature（提交 `098beec2b` 产品画廊重设计，`src/features/WorkGallery/`），入口经 `/resource/works` 路径段与过滤参数，点击在 Portal 中预览。Work 是"Agent 交付物"的统一事实对象，与工具注册的 `work?: PluginApiWorkConfig`（Agent 工具笔记 §1.3）衔接。

**统计入口**：`agent/statistics`（`AgentUsage`：7d/30d/90d 用量与成本、模型拆分、趋势图，`src/features/AgentUsage/hooks.ts:21`）+ `agent/permission`（工作区 Agent 的访问级 edit/use/view、模型策略 member/fixed、执行目标策略，`src/features/AgentPermission/PermissionForm.tsx`）。统计主链（数据聚合源）本次未深入。

**独特性判断**：Brief 是“Agent 需要人”与“Agent 干完活”的异步汇报信道，与任务调度构成完整离线运营闭环；Work 把文档/任务/外部服务产物统一为带版本与来源谱系的对象。二者合起来支撑 README “You stay in charge — without staying online”。

### 能力四：Agent Builder——对话式 Agent 配置（`主链确认`，静态证据）

**用户目标**：不打开几十个表单字段，用自然语言描述需求让一个专门 Agent 帮你把目标 Agent 配好（README “describe what you need once”）。

**主链**：右侧面板 `AgentBuilder`（`src/features/AgentBuilder/index.tsx:14`）初始化内置角色 `AGENT_BUILDER`（`packages/builtin-agents/src/agents/agent-builder/index.ts:43`，slug `agent-builder`，持久化落库）→ 对话中挂载 `lobe-agent-builder` 工具，并剥离同族 Agent/群组管理工具（避免"改到 builder 自己"；四组工具名见文末索引）→ 工具 API（`packages/builtin-tool-agent-builder/src/manifest.ts:6`）分读写两侧：读侧取可用模型与市场工具；写侧装插件（注释明确"ALWAYS REQUIRES user approval even in auto-run mode"）、改 Agent 配置与提示词 → 配置变更经 `AgentBuilderProvider` 实时作用于左侧目标 Agent。另有群组版本 `group-agent-builder`。

**独特性判断**：把“配置 Agent”本身做成一个 Agent 任务，且通过工具审批门把危险写操作（装插件）锁死在人审；与通用表单式配置（Cherry Studio 等）形成产品差异。运行时执行面（工具审批、配置对象）回链 Agent 工具/角色笔记。

### 能力五：Goals——带验收计划与有界自动修复的目标闭环（`主链确认`，静态证据）

**用户目标**：用户用 `/goal` 声明一个目标，Agent 把它拆成带验收标准、预算上限和轮次上限的任务循环，跑完后提交验收；普通 Chat 的"一次性回复"没有"目标 → 验收 → 有界修复"的闭环。该能力由以下提交逐级落地：
- `e8349e8ce`：/goal loop；
- `86f6b2684`：与任务创建拆分；
- `dc976694d`：统一创建流程；
- `10dbe1a16`：goal 视图与验收进度。

**入口与触发者**：Composer 的 `/goal` 命令——`goalTag.ts` 把目标标记存为结构化 chip（`f777343c8`）；发送时 `conversationLifecycle.ts:323-328` 检测 goal 提示并注入 `lobe-goal` 工具。

**事实对象**：goal 复用任务对象（无独立 goal 表）：`createGoal` 创建底层 task + 持久化验收标准（`TaskVerifyConfig`），`goalLoop.ts` 管理轮次（`DEFAULT_GOAL_MAX_ROUNDS`），`goalBudget.ts` 管理预算（可选 USD 上限），状态（done/paused/review/running）回写到创建工具卡（`goalLoop.ts:118-139`）。

**完整主链**：`/goal` chip → `lobe-goal.createGoal`（`packages/builtin-tool-goal/src/manifest.ts`，`humanIntervention: 'always'`，创建必须人工确认）→ 创建任务话题并启动 goal 循环 → 有界自动修复/验证（`apps/server/src/services/verify/` 的 goalLoop/settle/sweep 三模块）→ 消息内实时结果卡 → goal 视图（`agent/goals`、`agent/goal/[goalId]` 路由：创建/详情/验收/HowItWorks）→ 完成/拒绝由用户验收。

**持续性与资源边界**：全部状态在 PostgreSQL（task + verify 相关表）；轮次与花费双上限防止失控循环；`goalPhase` 驱动 UI 状态（done/paused/review/running）。

**独特性判断**：把“目标”建模为可验收、可自动修复、有预算上限的任务循环，且模型通过专门工具创建（非自由文本承诺）——与任务调度的关系是“目标是一次性任务的高级包装”，与 Brief 系统的关系是“验收结论进 brief 汇报”。在本样本中无对应实现。注意：README 未单独宣传 goals，本卡是 README 之外的实现面候选。

## 已归并到现有类目的能力

- **Agent Groups（群组对象）**：群组类型（`packages/types/src/agentGroup/index.ts`）、ChatGroupWizard 六类模板、成员 Agent 结构已在 [Agent 角色笔记](../Agent角色/LobeHub-Agent角色配置调查笔记.md) §6 覆盖；本快照新增群组路由 `group/:gid`（`desktopRouter.shared.tsx:206-243`）与成员编辑面（`group/profile/features/AgentBuilder` 可对成员跑 Builder，侧栏成员列表与添加/排序弹窗），群聊会话本体在会话与消息类目边界内。群组作为"多 Agent 并行协作"入口已确认，但群体编排运行链不在本次范围。状态：`入口确认`/`归并已有类目`。
- **Pages（文档协作写作）**：文档对象（documents 行、历史、编辑锁、发布到 workspace）已在 [生成式输出与运行时笔记](../生成式输出与运行时/LobeHub-生成式输出与运行时调查笔记.md) 覆盖；本笔记确认产品表面：`page/:id` 路由（`desktopRouter.shared.tsx:764-792`）、`PageEditor`（文档锁语义、`PageAgentProvider` 的 copilot 对话、页面元数据栏）。Pages 的"多 Agent 同页协作"运行链（协作者如何进入同一文档会话）未验证。状态：`入口确认`。
- **Agent 市场 / Community（hires 面）**：`community/` 路由族（agent/group_agent/model/provider/skill/mcp/user/org 详情与列表）、市场导入链在 Agent 角色笔记 §7 有记录；本次只做运营盘点的组成部分，不单独成卡。
- **插件、知识库、搜索、设备工具**：全部回链 [Agent 工具笔记](../Agent工具/LobeHub-Agent工具调查笔记.md)，不再重复。

异构 Agent 的完整分类边界、与 Connector/Messenger/浏览器控制表面的关系及横向样本，见[外部执行体与应用协作分类边界研究](外部执行体与应用协作边界研究.md)。本笔记只在摘要保留状态，不重复主链细节。

## 声明不符、外部依赖与暂缓项

- **Project（按项目组织）**：上快照的结论（数据库无 project 表、仅按工作目录分组）已过时。本快照（HEAD）新增完整 Project 实体，四层落地：
  - **表**：`projects` 实体含 `projects`/`projectAgents`/`projectChatGroups`/`projectKnowledgeBases`/`projectCompletionReviews` 五张表（`packages/database/src/schemas/project.ts:28`，migration 0134-0139）；
  - **API**：tRPC 路由覆盖创建/更新/删除/状态/验收/挂接 Agent 与知识库等操作，写操作带 `withScopedPermission('agent:update')` 保护（`apps/server/src/routers/lambda/project.ts`）；
  - **CLI**：`project list/view/create/edit/delete/status`，描述为"Manage goal-oriented projects"（`apps/cli/src/commands/project.ts`）；
  - **内置 Agent**：`project-coordinator` 按项目名生成协调者 systemRole（`packages/builtin-agents/src/agents/project-coordinator/index.ts`）。
  与此同时，话题侧的"按项目组织"仍以工作目录为键：`groupTopicsByProject`（`packages/utils/src/client/topic.ts:161-196`，`project:` 前缀 + `no-project` 沉底）与话题管理工具均按工作目录路径分组——两个"项目"语义并存（实体项目 vs 工作目录分组），其关联链（topic 如何归属到 projects 表）本次未走通。状态：`主链确认`（静态证据，实体项目侧）；分组侧维持原结论。
- **IM 网关**：平台注册（slack/telegram/discord/wechat/line/imessage 渠道路由与 webhook 处理器）、OAuth 安装（`agent-hono/handlers/` 的安装与回调 handler）、`/api/agent/webhooks/:platform`（`platformWebhook.ts`）、cron 保活与外部 `MESSAGE_GATEWAY`（`gatewayCron.ts:189-197`）、验证路由 `verify-im` 均确认存在；但"用户在 IM 发消息 → 绑定 Agent 会话 → 回复回 IM"的单平台完整往返与消息持久化语义未逐一走通（bot 场景的工具设备访问策略在 Agent 工具笔记 §7.2 已有记录）。状态：`入口确认`。
- **Workspace**：`workspaces` 表（slug/name/primaryOwnerId，`packages/database/src/schemas/workspace.ts:19`）、`/:workspaceSlug/*` 路由镜像（`desktopRouter.shared.tsx:880-1108`）、工作区设置页（成员、通知、统计、计划、账单、预算、额度、用量、服务模型、凭据、API key、OAuth 应用、审计日志、标签、存储、设备）、社区工作区详情页、共享设备池（Agent 工具笔记 §7.2）确认。另确认 API Key 能力范围列（提交 `ee7b69d17`；工作区 API Key 按成员权限收敛作用域，`a9bf96d95`）、工作区成员可对共享内建 Agent 选择个人模型（`68a318992`）、群组权限页（`src/routes/(main)/group/permission/index.tsx`）。Workspace 是"团队级 Agent 治理与共享"的容器，成员/权限/预算主链（邀请、角色、配额执行点）未逐个验证。状态：`入口确认`。
- **Agent 运营的 hires 面**：Agent 市场/社区、ConnectAgent 的“雇用”链路未单独走通；统计页数据聚合（usage 记录的写入与汇总）未验证。状态：`入口确认`。
- **image/video 创作工作台**（`(create)/image`、`(create)/video` 路由族）为 README 之外的独立创作面，本次不展开（未验证事项）。

## 对特色贡献统计的影响

- 建议新增主贡献候选：**任务调度与自动化（Schedule）**、**白盒个人记忆（Personal Memory）**（均可按静态主链确认计入，标签：`主动 Agent`、`记忆演化`）；**Agent 运营汇报（Brief + Work）** 作为组合贡献计入（标签：`主动 Agent`、`活对象`）；**Goals（目标闭环）** 作为独立主贡献候选（标签：`主动 Agent`、`活对象`）。
- 辅助贡献候选：Agent Builder（`人类工具面` 反向——人通过 Agent 配置 Agent）、IM 网关（`多表面连续性`）、Workspace（`协同工作区`）、Project（实体化后从暂缓项升级为辅助候选，`协同工作区`）。
- 与待查清单“Agent 社会/群体”聚类的交点：Agent Groups 会话面仍缺运行链，暂不进入统计。

## 未验证事项

- 任务自动化在生产环境（QStash）的运行表现、`/schedule-dispatch` 与 Vercel cron 的实际接线（本地代码只见入口与 fan-out 逻辑）。
- IM 平台消息往返（webhook → Agent 会话 → 回推）的单平台完整链路与 bot 会话持久化语义。
- Personal Memory hourly 扫描的调度 cadence 与资源消耗、提取质量（LLM 提取器未运行）。
- Workspace 成员/配额/账单执行点（邀请流程、budget 扣减、审计日志写入）。
- 统计页数据源（usage 记录写入与聚合 SQL）。
- `byProject` 分组中 workingDirectory 写入 topic metadata 的来源链（异构 Agent 运行时的目录上报）；以及实体 `projects` 表与工作目录分组两套“项目”语义的关联链（见 Project 条目）。
- Goal 循环在真实任务上的运行表现（轮次/预算触达后的 settle 行为、`sweep` 的巡检接线）——静态主链已确认但未运行验证。
- image/video 创作工作台与 Work 对象的衔接。
- 六种本地 CLI 与 OpenClaw/Hermes 的运行兼容性、Windows 进程树终止、SDK/CLI runtime 切换和真实 resume 行为。

## 关键源码索引

- 路由全貌：`src/spa/router/desktopRouter.shared.tsx`（agent/group/memory/page/tasks/workspaceSlug 各段）。
- 任务调度：`packages/database/src/schemas/task.ts`、`apps/server/src/services/taskRunner/index.ts`、`scheduleTick.ts`、`heartbeatTick.ts`、`apps/server/src/services/taskScheduler/impls/local.ts`、`apps/server/src/workflows-hono/task/handlers/scheduleDispatch.ts`、`packages/builtin-skills/src/task/SKILL.md`。
- 个人记忆：`packages/database/src/schemas/userMemories/index.ts`、`apps/server/src/services/memory/userMemory/extract.ts`、`apps/server/src/workflows-hono/memory-user-memory/workflows/processTopic.ts`、`packages/builtin-tool-memory/src/manifest.ts`、`src/routes/(main)/memory/(home)/index.tsx`。
- 运营汇报：`apps/server/src/services/taskLifecycle/index.ts`（onTopicComplete/synthesizeTopicBrief）、`packages/database/src/schemas/task.ts`（briefs）、`src/features/HomeInbox/index.tsx`、`packages/database/src/schemas/work.ts`、`src/features/Work/descriptors.tsx`、`src/features/AgentUsage/hooks.ts`。
- Agent Builder：`packages/builtin-agents/src/agents/agent-builder/index.ts`、`packages/builtin-tool-agent-builder/src/manifest.ts`、`src/features/AgentBuilder/index.tsx`（被剥离的四组工具：`lobe-agent-management`、`lobe-group-management`、`lobe-group-agent-builder`、`lobe-agent`）。
- IM 网关：`src/features/Messenger/index.tsx`、`apps/server/src/agent-hono/handlers/{platformWebhook,messengerInstall,messengerOAuthCallback,gatewayCron}.ts`。
- 项目分组：`packages/utils/src/client/topic.ts:161`、`src/store/chat/slices/topic/selectors.ts:203`、`src/features/AgentSidebar/Topic/utils/topicGroupMode.ts`。
- Project 实体：`packages/database/src/schemas/project.ts`、`apps/server/src/routers/lambda/project.ts`、`apps/cli/src/commands/project.ts`、`packages/builtin-agents/src/agents/project-coordinator/index.ts`。
- Goals：`packages/builtin-tool-goal/src/manifest.ts`、`apps/server/src/services/verify/goalLoop.ts`、`src/features/AgentGoals/`、`src/features/ChatInput/InputEditor/ActionTag/goalTag.ts`。
- 异构 Agent：`packages/types/src/agent/heterogeneousAgent.ts`、`packages/heterogeneous-agents/src/`、`apps/desktop/src/main/modules/heterogeneousAgent/`、`src/store/chat/slices/agentRun/actions/transports/hetero/heterogeneousAgentExecutor.ts`、`apps/desktop/src/main/controllers/GatewayConnectionCtr.ts`。
