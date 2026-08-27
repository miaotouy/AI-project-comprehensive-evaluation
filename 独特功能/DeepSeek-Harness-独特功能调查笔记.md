# DeepSeek Harness 独特功能调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/extensions/`、`packages/sandbox/`、`packages/goal/`、`packages/plan/plan-mode`、`packages/schedule/`、`packages/subagent/`，关联 `packages/bundle/`、`packages/runtime-diagnostics/invariants`、`packages/skill/`、`packages/workflow/`、`packages/jobs/`、`packages/e2b/`）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`（分支：`master`）
>
> 调查方式：静态源码阅读。通读六个机制各自的包 README、`docs/subsystems/` 对应页（goal、plan、schedule、sandbox、extensions、subagent、persistence、spill）与关键 src 文件（`tool-cordis`、`cordis-host-runner` 的 sandbox/lifecycle、`goal` 与 `goal-round-driver`、`plan-mode`、`schedule` 的 domain/runtime/index、`sandbox-local`、`subagent` 的 index/continuation、`native/landlock-run` 入口 C 源）；未运行任何进程或测试
>
> 调查范围：覆盖——agent harness 特有的机制集合：自引用插件运行时、进程沙箱、同会话目标驱动、plan mode 日志化状态、session-local 定时调度、多 provider 子代理能力族，以及 invariants/bundle/skill 注册表/workflow/jobs/e2b/feedback/attachment 机制盘点；排除——工具 schema、执行管线、审批与渲染细节（归 Agent 工具笔记）、agent-loop 回合执行（归 Chat 笔记）、会话持久化与压缩（归会话与消息管理、对话请求与上下文笔记）、LLM 渠道（归 LLM 渠道管理笔记）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

dsh 的独特功能不在聊天或工具表面，而在把 agent 自身运行时当作可编程对象的一组机制。六个机制均达到主链确认（静态证据）：**自引用插件运行时**让 agent 检查自己所在 Cordis 进程的插件与服务目录，并把模型写的插件包挂载、运行、回滚进同一进程；**进程沙箱**把文件效应策略按每次调用携带，经四个平台后端 fail-closed 执行；**同会话目标驱动**把长期目标做成事件溯源状态，由轮次驱动插件在会话内自动续跑；**plan mode 日志化状态**与 **session-local 定时调度**共用"会话日志折叠出状态、进程内只留可弃投影"的模式；**多 provider 子代理**是一个委派契约下六种执行位置的子 agent 能力族。

这些机制共享三条架构模式：一是能力缝三角（Service Definition / Provider / Consumer），新行为一律放插件扩展点而不改 agent-loop；二是会话事件日志是唯一持久权威，任何状态都从日志折叠恢复，不设平行持久对象；三是"模型可见 ⟺ 已落盘"的日志完整不变量。除六个主机制外，invariants（运行时不变式注册表）、bundle（profile patch-layer 插件包）、skill 注册表、workflow/jobs 等支撑机制另行盘点，见下文。

## 介绍声明与候选盘点

根 README 只自称 everything is a plugin 的 agent harness（`README.md:5-7`），但根 `AGENTS.md` 的包清单直接点名"agent inspects/mounts its own plugins"、"plan mode as logged state"、sandbox、goal、schedule、subagent、bundle 等候选；`docs/subsystems/` 逐页描述机制语义。候选状态如下：

| 候选 | 状态 | 依据 |
|---|---|---|
| 自引用插件运行时 | 主链确认（静态） | 本次能力一；`demo:cordis` 演示脚本与 `examples/web-cordis` 组合 |
| 进程沙箱 | 主链确认（静态） | 本次能力二；含 `native/` 的 Landlock C 启动器 |
| 同会话目标驱动 | 主链确认（静态） | 本次能力三 |
| plan mode 日志化状态 | 主链确认（静态） | 本次能力四 |
| session-local 定时调度 | 主链确认（静态） | 本次能力五 |
| 多 provider 子代理 | 主链确认（静态） | 本次能力六 |
| skill provider 注册表 | 归并已有类目（工具侧）+ 机制 | skill 工具链已由 Agent 工具笔记覆盖；注册表本身是 scope 分层的中立发现机制 |
| workflow / ralph | 入口确认（机制） | 模型写的工作流脚本 + worker-thread provider；ralph 是固定 fresh-agent 策略 |
| jobs 后台任务 | 入口确认（机制） | owner 隔离的观察/取消/完成通知协议 |
| bundle patch-layer | 入口确认（机制） | 可安装的 profile 补丁层 npm 包 |
| invariants 运行时不变式 | 入口确认（机制） | 每个包发布 `./invariant` 伴侣 |
| e2b 远程执行 POC | 入口确认（暂缓） | 实验性 provider 组合；依赖外部 E2B 服务 |
| feedback / attachment | 骨架 / 普通能力 | feedback 分日志备注与 sidecar 评分两种契约；attachment 是内容寻址附件存储 |

## 已确认的独特能力

### 能力一：自引用插件运行时（self-modification）

1. **用户目标与入口**：让模型在会话中直接检查自己所在运行时的插件与服务，并把模型自己写的 Cordis 插件包定义、运行、停止、删除——即"agent 修改自身运行时"。入口是七个模型工具：三组只读 inspect（list/query/self）与 define/run/stop/undefine 四个动作，全部注册在 `packages/extensions/tool-cordis/src/index.ts:41-379`；用户也可在消息中显式引用 `@<pluginId>`，pre-step 监听器会把该插件最新包上下文注入下一请求（同文件 `:381-398`）。
2. **事实对象**：动态 Plugin/Package/Run 三层次对象。define 铸造 `dyn-<n>` 插件 id 与不可变包 id；包是"两个 JavaScript 函数体"（host 半 + browser 半），纯 JS、无 import 与 TS 变换。定义与运行只存在于进程内存：不写插件文件、不改 `cordis.yml`、重启即失、仅定义它的会话可见；另一会话的定义读作 absent 而非 forbidden（`cordis-host-runner/README.md`）。
3. **完整主链**：inspect（只读报告）→ define（先编译预检语法、只记录不运行）→ run（host 半在 node:vm 沙箱中求值并作为子 fiber 挂到动态插件组；含 browser 半时先发 request-run 轮询，由某个页面装载后回执）→ stop/undefine（退避或删除）。沙箱构造见 `cordis-host-runner/src/sandbox.ts:129-145`，子 fiber 启动与注册冲突处理见 `lifecycle.ts:22-45`。
4. **持续性**：定义与运行状态全是进程内存；会话日志只记 define 调用的元数据，绝不记代码。重启后卡片 id 无法解析时如实报告"定义不在"，而不是假装可运行；页面重载后要重新 run 才能取回 browser 半。
5. **安全与信任边界**：vm 只隔离全局、明确不是安全边界（README 明言按授予 bash 的谨慎度装载）。Node 的 require/timers/fetch 被陷阱化并重定向到 `ctx.fs`、`ctx.web`、`ctx.bash` 与 Cordis 计时器（`sandbox.ts:96-108`）；`vmTimeoutMs`（默认 5000ms）只限制同步求值部分，异步体可逃逸。browser 半激活需页面同意，无页面连接时 run 挂起直到调用回合取消。
6. **独特性判断**：Pi 的扩展系统由用户在会话外安装、OpenCode 的插件目录是构建期事实；这里是模型在运行中定义、审批、运行并回滚自身所在进程的插件，且能通过生成式 API catalog 读到仓库级服务契约（`tool-cordis/src/api-catalog.ts` 与 live service store 求交）。证据强度：静态主链确认；vm 逃逸面与浏览器端渲染行为未运行验证。

### 能力二：进程沙箱（sandbox）

1. **用户目标**：给"同世界子进程"施加文件效应策略——bash、pwsh 与 fs 工具的进程执行受同一策略约束，而不用容器或微VM。沙箱不是用户直接操作的功能，而是能力缝：`ctx.sandbox.confine(argv, policy)` 返回替换 argv，由消费者自己 spawn（`packages/sandbox/sandbox/src/index.ts:158`）。
2. **完整主链**：`ctx.sandboxPolicy.resolve()` 按调用解析完整策略（显式批准的 mode 覆盖 > 会话最后一条 `sandbox/mode` 日志事件 > 部署默认；workspace 根取会话不可变 cwd，按文件系统语义规范化）→ `sandbox-local` 选择并缓存后端探针结论 → confine 返回 wrapped argv 加三份分类事实（enforcement、denial 方言、runner-failure 规则）→ 消费者 spawn 返回的 argv。策略解析与后端分离见 `sandbox-policy/src/index.ts:91`、`sandbox-local/src/index.ts:316-333`。
3. **模式与后端链**：模式三档——read-only、workspace-write、danger-full-access，只有前两档可发给 provider，danger 档直接原样 spawn、不调沙箱。后端按平台链选择：Linux 上 bwrap 优先、功能探针失败再试 Landlock；macOS 唯一候选 Seatbelt；Windows 唯一候选 ACL 受限令牌 runner（`sandbox-local/src/index.ts:159-166`）。多候选才逐个探针，单候选直接选用，但运行期拒绝仍 fail-closed。
4. **Landlock 与 Windows 细节**：`native/landlock-run` 是静态链接 musl 的 C11 启动器，自装规则集后 exec 被包裹命令（规则集跨 execve 继承，调用进程不受限）；规则集创建失败或内核不执行时直接非零退出，绝不无沙箱放行（`native/landlock-run/packages/entry/src/main.c:1-80`）。Windows runner 为每个 workspace 建常驻写 SID 与 ACE，为每个 live session/workspace 对建随机私有 temp 目录与可撤销 ACE——崩溃残留不能授权续开会话；因进程初始化必须保留 Everyone，enforcement 如实上报 partial（`sandbox-local/src/index.ts:392-443`）。
5. **边界与词汇**：enforcement 是上报事实（full/partial），要求绝对保证的消费者必须拒绝 partial；denial 方言按后端分别携带（bwrap 的只读文件系统文本、Landlock 的 permission denied、Seatbelt 的 operation not permitted 等），runner-failure 规则让消费者区分"沙箱坏了"与"命令被正确拒绝"。无静默无沙箱回退：选不出后端时抛 `SANDBOX_UNAVAILABLE`（`docs/subsystems/sandbox.md`）。
6. **独特性判断**：与 AstrBot 的容器式 Agent Sandbox、OpenCode 的进程组方案不同，这是"按调用携带策略 + 多平台原生后端 + fail-closed 契约"的执行域机制，策略可以并发会话不同边界而不改动 provider 状态。证据强度：静态主链确认；bwrap/Seatbelt/Windows ACL 的真实内核行为未运行验证。

### 能力三：同会话目标驱动循环（goal）

1. **用户目标**：把一个长期完成目标从"一条消息"提升为可持久化、可续跑、有预算的会话级对象：模型在会话内自动继续工作直到目标完成、暂停或被阻塞。入口包括人类侧 `/goal` 命令（`command-goal/README.md`）与模型侧 `get_goal/create_goal/update_goal` 工具（`tool-goal/README.md`）。
2. **事实对象与状态模型**：目标快照（objective、phase、maxGoalRounds、blockedReason）加严格递增的 revision；一切变更以 `goal/change` 会话事件落盘（整快照或 clear tombstone），严格折叠校验非法转换。激活（armed/disarmed）是分离的、从不持久化的进程内标志——决定"续跑消费者能否再开一轮"，由 `GoalService` 在 create/resume 时武装，在 disarm、session-start、插件卸载时解除（`packages/goal/goal/src/index.ts:236-242`；`docs/subsystems/goal.md`）。
3. **完整主链**：人类回合 create（create/edit/pause/resume 要求回合内直接人类消息这一宿主证明）→ 事件落盘 → `goal-round-driver` 在 agent 完全空闲、目标 active+armed、未达轮次上限时先过持久化屏障，再保留下一轮号并构造带 goal 来源（goalId/revision/round）的 `<goal_round>` 用户消息，经 followup 入 inbox（`goal-round-driver/src/index.ts:138-205`；提示内容见 `prompt.ts:12-26`）→ `agent/pre-step` 监听器在下游监听前后双向校验预订记录（同文件 `:349-414`）→ 只有真正进入回合的 `user/message` 才递增 `roundsStarted` → 模型执行本轮，随后驱动再进下一轮。
4. **主动性与取消**：驱动只在 idle 时保留下一轮，人类消息进入时自动让路。turn/end aborted 会取消已保留的轮并暂停目标；max-tokens 结束解除武装；flush 失败解除武装；插件卸载关闭准入并等待静止。轮次预算默认上限 256，耗尽时驱动主动 block（code `round-limit`）。
5. **完成与阻塞的判定边界**：完成/阻塞由模型自行判定证据是否充分，运行时只提供结构：模型自报 blocked 需连续 N 轮同一条件（默认 3，`blockedAfterConsecutiveRounds`）且 reason code 固定为 `model-reported`；无独立评估器（`tool-goal/README.md` 明列为 deferred work）。
6. **独特性判断**：与"子代理重试/后台循环"不同，它明确在同一会话内继续、不 fork 会话、不产生新 Agent，轮次是带编号消息进入同一历史；与 Ralph（fresh agent 策略）是刻意分开的两个方案。证据强度：静态主链确认；多轮续跑的竞态与真实模型行为未运行验证。

### 能力四：plan mode 作为日志化协作状态（plan）

1. **用户目标**：让用户与模型在同一会话内切换"先规划、后执行"的协作模式，并保证模式状态在任何表面（resume、fork、compaction、多客户端）都一致。plan mode 是软指导：激活时把部署提供的 `plan:policy` 提示段（order 50）加入每轮请求；沙箱模式与审批策略独立强制执行、互不读写该状态（`packages/plan/plan-mode/src/index.ts:225-233`）。
2. **状态模型**：`plan/mode` 是 log-only、整值替换的会话事件；`foldPlanMode(events, end?)` 纯折叠出前缀中最后一条值（无则 false），没有 live mirror，UI 通过 `session/event` 观察已提交翻转（同文件 `:129-138`、`:46-55`）。
3. **完整主链**：`/plan [off|message]` 或 `set()` → 无打开回合时立即 append；回合打开时保持 pending，直到下一个被接受的 in-turn pre-step 在请求组装前 append（`set` 见 `:425-445`，pre-step append 见 `:205-222`）。选中状态只在最近请求 header 曾描述相反状态时补一条插件来源通知，避免冗余告知模型；append 失败不阻塞回合，pending 留待下次被接受的 pre-step。
4. **退出**：`exit_plan_mode` 工具常驻注册（进/出模式只改提示段、不改请求工具目录）；要求完整 markdown 计划（# 开头），经 user-questions 缝呈现给用户审批；approve 后挂 silent pending 退出，在下一被接受 pre-step 落盘，当前工具批次内规划指导保持生效；keep-planning 作为带反馈的失败返回给模型。模式由用户或模型随时可切，无后台自动行为。
5. **独特性判断**：模式状态是"可重放日志事实"而非 UI 状态，计划文本本身不进会话（只进审批通道）——这是把协作状态做成日志事件的示范，schedule、sandbox 模式、goal 阶段同用该模式。证据强度：静态主链确认。

### 能力五：session-local 定时调度（schedule）

1. **用户目标**：模型创建"稍后提醒/定时检查"类规则，到期以普通对话回合回到原会话。交付边界固定为 session-local：原会话必须在线，无外部通知通道、无冷会话调度器；冷会话重开时过期目标变为 overdue。
2. **事实对象**：`schedule/change` 事件是唯一持久权威，记录三变体——after（延迟一次性）、at（绝对时刻，规范化 RFC3339 UTC）、every（固定间隔，最小 5 分钟，创建时锚定）；折叠出活动记录，timer 只是可弃投影（`docs/subsystems/schedule.md`）。管理调用先等会话持久化屏障，屏障失败返回 `persistence_uncertain` 而非猜测落库结果。
3. **完整主链**：`schedule_create` 落事件 → `ScheduleRuntime` 折叠日志、算最早目标、arm 分段 timer（上限约 24.8 天，每次醒来重读墙钟；`packages/schedule/schedule/src/runtime.ts:178-184`）→ 到期且 agent 完全 idle 时 claim maintenance 阶段 → 构造 framing 后的用户消息经 followup 入队 → 同步入队成功后才 append dispatch 事件（`:254-306`）。投递是"普通对话回合"：无独立回执、无渲染器；入队后崩溃可能重复提醒，边界明言是尽力而为的 at-least-once。
4. **批量与补漏**：一次性提醒逐个优先进入；多条 every 过期合并为一个批次（同 decision time）限制模型回合数；漏过的区间不枚举不重放，只投最新到期并把记录直接推进到下一个锚定目标。fork 不继承活动提醒（只折 seedLength 之后的事件），`dispatch` 一次性记录是终态 id-only 转换。
5. **独特性判断**：提醒不是外部 cron 也不是通知推送，而是"会话日志上的规则 + 进程内定时投影 + 原会话回合投递"，重启后从日志恢复调度语义。证据强度：静态主链确认；真实 timer 唤醒与崩溃窗口行为未运行验证。

### 能力六：多 provider 子代理能力族（subagent）

1. **用户目标**：让 agent 把工作委派给子 agent，且执行位置可选：同进程 spawn、同进程 fork（继承父会话已完成历史）、进程外 ACP、真实 Codex 与 Claude Code 子进程、进程外 dsh SDK 实例——六个 provider 加一个共享的进程内驱动包。`ctx.subagents` 是唯一委派契约，多 provider 并发共存（`packages/subagent/subagent/src/index.ts:369-425`）。
2. **事实对象与持续性**：每次本地启动追加 `subagent/descriptor` 会话事件（provider 名、mode、冷恢复所需字段）；委派深度以 `SessionHeader.delegationDepth` 单调持久化，重启后子 agent 不会被重新计为顶层。可续子代理（continuable child）拥有一个持久子会话 + 至多一个进程内 Activation；冷恢复直接从持久会话重建 Agent，不重新走 provider（`continuation.ts`；`subagent/src/index.ts:212-275`）。
3. **完整主链**：模型经 `tool-subagent` 调 start（one-shot：等结果并 dispose）或 startContinuable（立即返回持久 childId；后续经 send_message followup 唤醒，interrupt 停当前回合）→ 子代理在继承的沙箱与固定审批策略内执行 → 完成或夭折时 settled notice 回到父会话，或经 report 通道主动回传。可续路径的建立、唤醒、冷恢复与中断见 `continuation.ts:403-583`。
4. **委派策略固定**：在委派边界快照父会话的沙箱 override，并把子代理审批钉死为 never（自动拒绝一切 ask，避免无人盯的审批挂起）；子会话注入固定 delegation-scope 声明（权限启动时固定、无法从内部扩大、超范围以报告限制结束而非重试）；这些策略以 `source: 'delegation'` 事件写入子会话日志并在任何 fork 种子之后生效，子代理从日志即可重建其有效策略（`subagent/README.md` Delegated policy 节）。
5. **独特性判断**：与 OpenCode 子代理、LobeHub 外部 CLI 托管相比，这里是"一个契约、六种执行位置、可续会话对象"，且把策略继承做成可重放事件而不是运行时传递。证据强度：静态主链确认；ACP/Codex/Claude Code 真实子进程与跨进程冷恢复未运行验证。

## 工程与支撑机制盘点

实验性 Agent Teams 已把多 Agent 协作提升为可组合的能力组：team runtime、成员与协作工具各自为插件，相关的会话事件和文档同样进入持久化目录。它仍属于实验性组合，不能据此推断存在成熟的团队管理 UI 或跨账户协作服务（`packages/experimental/agent-team/`、`docs/subsystems/agent-team.md`、`examples/headless-agent/team.cordis.snapshot.yml`）。

以下机制已确认入口与契约，属于工程或支撑性质，不单独展开能力卡：

- **invariants 运行时不变式**：每个 npm 包必须发布 `./invariant` 伴侣，向 `ctx.invariants` 注册基于事件/数据关系的运行时检查（会话围栏、轮次计数、模型请求可重建性等）；可 allowlist/blocklist 与启停，安装器在专用子 fiber 运行。是"把不变量接进运行时"的可靠性机制，见 `packages/runtime-diagnostics/invariants/README.md`。
- **bundle profile patch-layer**：npm 包 manifest 声明 `dsh.bundle.patch` 即成为 `dsh --profile` 组合的可安装补丁层；profile 是 `$DSH_HOME/profiles/<name>` 下的包目录，按 bundles 顺序叠加补丁、再叠用户 `cordis.patch.yml`（HMR 热重组）。`dsh-base` 是每个 profile 的第一层。见 `packages/boot/app-boot/README.md` Profiles 节（`README.md:36-45`）。
- **skill provider 注册表**：`ctx.skills` 是按 scope 分层的 provider 中立注册表（本地文件、嵌入、远端均可），发现与加载分离，模型/人类双面调用策略独立。工具侧（目录消息 + skill 加载器）已由 Agent 工具笔记覆盖，注册表机制本身不单独计独特功能。
- **workflow / ralph**：模型可提交编排脚本给 `ctx.workflowEngine`，worker-thread provider 在隔离线程执行（明确非安全边界）；`ralph` 工具是固定策略——把不可变目标交给一串全新子 agent——以普通插件演示"不改 agent-loop 也能实现编排策略"。见 `packages/workflow/README.md`、`tool-ralph/README.md`。
- **jobs 后台任务**：owner 隔离的后台任务协议（观察、取消、等待、完成通知），`job_list/job_output/job_kill` 是模型面；见 `packages/jobs/README.md`。
- **e2b 远程执行 POC**：实验性 provider 组合，把一个文件系统/进程执行世界放进 E2B Linux 沙箱，只实现 fs 与 subprocess 两个 OS 适配器；边界明确不移 harness 进程与模型状态，需外部 E2B 服务，标暂缓。
- **feedback / attachment**：feedback 分两种契约（命令反馈是日志备注、消息反馈是独立 sidecar，均不进模型上下文）；attachment 是内容寻址的不可变附件存储，落 `DSH_HOME` 下。两者属普通能力，归入会话/工具既有类目。

## 已归并到现有类目的能力

- **工具执行管线**：tools 注册、schema、approval、渲染、run_code 传输等细节已由 Agent 工具笔记覆盖（含 `cordis_*` 工具族与 schedule、goal、workflow、jobs、skill 的全部模型工具名与执行链），本次只补机制层。
- **agent-loop 与回合执行**：Chat 笔记已覆盖 `ReactLoopAgent`、steer/followup、错误与取消；本文直接复用其术语（pre-step、followup、idle、maintenance、turn/end）。
- **会话持久化与压缩**：事件日志、flush 屏障、compaction、spill 的存储细节归会话与消息管理、对话请求与上下文笔记；本文只记录"日志折叠出状态"这一模式的使用方。
- **LLM 渠道与重试**：归 LLM 渠道管理笔记。

## 声明不符、外部依赖与暂缓项

- **e2b 远程执行**：依赖外部 E2B 服务与 SDK，本仓库只有适配器 POC；未运行验证，标暂缓。
- **vm 沙箱的安全声明**：文档明言"不是安全边界"，host-realm 辅助函数可逃逸——这是项目自述的边界而非缺陷结论；逃逸的实际利用面未验证。
- **cold-session 调度**：README 明言无冷会话调度器、无外部通知通道；若部署者期望重启后定时器仍会发通知，属于文档已声明的边界。
- **反馈闭环**：message-feedback 的客户端 Remote aggregate 与 UI 消费方"单独所有且延后"（`packages/feedback/README.md`），Host 侧契约已存在，端到端 UI 链未闭合。

## 对特色贡献统计的影响

- 六个机制按"产品特性 vs 机制贡献"分账：goal、plan mode、schedule、self-modification 属于用户/模型可感知的产品能力，可计入产品特性；sandbox 与子代理的委派策略固定属于安全与执行域机制，与 invariants 一起按机制贡献单列。
- 横向比较对象建议为同类 harness：Pi（扩展系统/分支会话）、OpenCode（多表面/子代理/ACP）、Hermes Agent（skill 闭环）、Jan（编排端点）；"agent 修改自身运行时"当前没有第二样本，保留为稀有能力卡。

## 未验证事项

- 六个机制均为静态主链确认，未运行：vm 逃逸面、browser 半渲染与 request-run 审批轮询的真实交互、Landlock/bwrap/Seatbelt/Windows ACL 的真实内核与权限行为、goal 多轮续跑的竞态、schedule 定时器唤醒与崩溃窗口、ACP/Codex/Claude Code 子进程与跨进程冷恢复。
- `demo:cordis` 演示脚本（"the agent modifies its own runtime"）未执行。
- e2b POC 未连接外部服务。
- 未逐包核对 `verify-package-invariants` 门禁在全部工作区包上的实际通过状态（机制存在性已确认，门禁运行未验证）。

## 关键源码索引

### 自引用插件运行时

- `packages/extensions/tool-cordis/src/index.ts:41-379`（七工具注册）、`:381-398`（@pluginId pre-step 注入）
- `packages/extensions/cordis-host-runner/src/sandbox.ts:96-145`（Node API 陷阱与 vm 沙箱）、`:206-238`（define 预检与求值）
- `packages/extensions/cordis-host-runner/src/lifecycle.ts:22-45`（host 半 fiber 启动）
- `examples/web-cordis/README.md`；根 `package.json` 的 `demo:cordis` 脚本

### 进程沙箱

- `packages/sandbox/sandbox/src/index.ts:158`（confine 抽象）
- `packages/sandbox/sandbox-policy/src/index.ts:91`（resolve）
- `packages/sandbox/sandbox-local/src/index.ts:159-166`（平台链）、`:316-333`（confine）、`:392-443`（Windows ACL 授权物化）
- `native/landlock-run/packages/entry/src/main.c:1-80`（Landlock 启动器）
- `docs/subsystems/sandbox.md`

### goal

- `packages/goal/goal/src/index.ts:236-267`（disarm/create）、`fold.ts`（严格折叠）
- `packages/goal/goal-round-driver/src/index.ts:138-205`（保留与入队）、`:349-414`（pre-step 校验）
- `packages/goal/goal-round-driver/src/prompt.ts:12-26`（goal_round 提示）
- `docs/subsystems/goal.md`；`packages/goal/tool-goal/README.md`（权限与阈值）

### plan mode

- `packages/plan/plan-mode/src/index.ts:129-138`（fold）、`:205-222`（pre-step append）、`:225-233`（提示段）、`:425-460`（set/onBoundary）
- `docs/subsystems/plan.md`

### schedule

- `packages/schedule/schedule/src/domain.ts:465-647`（解码/折叠/分配 id）、`runtime.ts:77-323`（ScheduleRuntime）
- `packages/schedule/schedule/src/tools.ts:299`（工具注册）
- `docs/subsystems/schedule.md`

### subagent

- `packages/subagent/subagent/src/index.ts:369-425`（注册/start）、`continuation.ts:403-583`（可续建立/唤醒/中断）
- `packages/subagent/subagent/src/descriptor.ts`（持久描述符）、`depth.ts`（深度）
- `packages/subagent/subagent/README.md`（委派策略固定）

### 支撑机制

- `packages/runtime-diagnostics/invariants/README.md`
- `packages/boot/app-boot/README.md:36-45`（Profiles 与 bundle 契约）
- `packages/skill/skill/README.md`、`packages/workflow/README.md`、`packages/jobs/README.md`、`packages/e2b/README.md`、`packages/feedback/README.md`、`packages/attachment/README.md`
