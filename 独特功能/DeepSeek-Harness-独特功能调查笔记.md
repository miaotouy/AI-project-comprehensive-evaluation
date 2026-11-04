# DeepSeek Harness 独特功能调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/extensions/`、`packages/boot/plugin-manager`、`packages/boot/plugin-market`、`packages/sandbox/`、`packages/goal/`、`packages/plan/plan-mode`、`packages/schedule/`、`packages/subagent/`、`packages/team/`，关联 `packages/bundle/`、`packages/skill/`、`packages/workflow/`、`packages/jobs/`、`packages/experimental/{forge,liveshare,worktree,auto-review,webhook,browser-use,computer-use}`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：静态源码阅读。通读六个机制各自的包 README、`docs/subsystems/` 对应页（goal、plan、schedule、sandbox、extensions、subagent、agent-team、forge、liveshare、persistence、spill 等）与关键 src 文件（`tool-cordis`、`cordis-host-runner` 的 inspection registry、`plugin-manager`、`goal` 与 `goal-round-driver`、`plan-mode`、`schedule` 的 domain/runtime/tools、`sandbox-local`、`subagent` 的 activation/out-of-process、`team/agent-team`）；辅以 `docs/upgrade-guide/`；未运行任何进程或测试
>
> 调查范围：覆盖 agent harness 特有的机制集合：只读自省 + 持久插件安装的自扩展、进程沙箱、同会话目标驱动、plan mode 日志化状态、Host 级定时任务、多 provider 子代理能力族与团队任务板，以及 plugin market/bundle/skill 注册表/workflow/jobs/forge/liveshare/worktree/auto-review/webhook/browser-use/computer-use 机制盘点；排除工具 schema、执行管线、审批与渲染细节（归 Agent 工具笔记）、agent-loop 回合执行（归 Chat 笔记）、会话持久化与压缩（归会话与消息管理、对话请求与上下文笔记）、LLM 渠道（归 LLM 渠道管理笔记）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

dsh 的独特功能集中在把 agent 自身运行时当作可编程对象的一组机制上。六个机制均达到主链确认（静态证据）：**自省式自扩展**让模型只读检查自己所在 Cordis 进程的服务与 Loader 条目，再通过持久插件管理安装 bundle 改变后续会话；**进程沙箱**把文件效应策略按每次调用携带，经平台后端 fail-closed 执行；**同会话目标驱动**把长期目标做成事件溯源状态，由轮次驱动插件在会话内自动续跑；**plan mode 日志化状态**与 **Host 级定时任务**分别把协作状态与时序任务做成"会话日志或领域存储折叠出状态、进程内只留可弃投影"；**多 provider 子代理能力族**在一个委派契约下覆盖六种执行位置，并叠加团队任务板。

这些机制共享三条架构模式：一是能力缝三角（Service Definition / Provider / Consumer），新行为一律放插件扩展点而不改 agent-loop；二是持久权威集中——会话事件日志承担会话内状态，schedule 与 team 把权威放在各自的领域存储或根会话，不设平行进程状态；三是"模型可见 ⟺ 已落盘"的日志完整不变量。除六个主机制外，plugin market/bundle、skill 注册表、workflow/jobs、forge、LiveShare、worktree、auto-review、webhook、browser/computer-use 等支撑与实验机制另行盘点。

两处已确认的移除：**运行期不变式（invariants）包族整体删除**，动态插件 define/run/stop/undefine 的模型工具入口不存在；**E2B 远程沙箱包族删除**，远端执行世界改由 POSIX SSH provider 家族承担。

## 介绍声明与候选盘点

根 README 仍自称 everything is a plugin 的 agent harness，根 `AGENTS.md` 的包清单点名 sandbox、goal、plan、schedule、subagent、bundle 等候选；`docs/subsystems/` 逐页描述机制语义。候选状态如下：

| 候选 | 状态 | 依据 |
|---|---|---|
| 自省式自扩展（inspect + 插件安装） | 主链确认（静态） | 本次能力一；只读 inspect 工具加 plugin_manager/plugin_market |
| 进程沙箱 | 主链确认（静态） | 本次能力二；含 `native/` 的 Landlock C 启动器与 Windows ACL 后端 |
| 同会话目标驱动 | 主链确认（静态） | 本次能力三 |
| plan mode 日志化状态 | 主链确认（静态） | 本次能力四 |
| Host 级定时任务 | 主链确认（静态） | 本次能力五；RRULE 加 target 的 Host 任务模型 |
| 多 provider 子代理与团队任务板 | 主链确认（静态） | 本次能力六 |
| 动态插件定义与运行（旧 self-modification） | 已移除 | 本次未找到模型可调用的 define/run/stop/undefine；改为持久 bundle 安装 |
| 运行期不变式 invariants | 已移除 | `packages/runtime-diagnostics/` 与 `@deepseek-ai/dsh-invariants` 不存在，仅留 v0.2.0-rc.2 迁移指南 |
| E2B 远程执行 POC | 已移除 | `packages/e2b/` 不存在，SSH provider 家族取代 |
| skill provider 注册表 | 归并已有类目（工具侧）+ 机制 | skill 工具链已由 Agent 工具笔记覆盖 |
| workflow / ralph | 入口确认（机制） | 模型写的工作流脚本 + worker-thread provider；ralph 是固定 fresh-agent 策略 |
| jobs 后台任务 | 入口确认（机制） | owner 隔离的观察/取消/完成通知协议 |
| bundle patch-layer 与 plugin market | 主链确认（静态） | 可安装的 profile 补丁层 npm 包 + 市场索引 |
| agent team 任务板 | 主链确认（静态） | 由实验包升为 `packages/team/` 一等包 |
| POSIX SSH 执行世界 | 主链确认（静态） | 共享连接把 fs/subprocess/sandbox 投影到同一远端主机 |
| forge 变更请求面 | 入口确认（机制） | 默认禁用的 seam，GitHub provider + 会话绑定 + 面板 |
| LiveShare 会话共享 | 入口确认（机制） | 观看者 Peer 与 remote-access 裁决 |
| webhook 入站会话 | 入口确认（机制） | 认证投递 → 规则 → 根会话 |
| worktree 隔离工作区 | 入口确认（机制） | 独立 worktree 服务与模型工具 |
| auto-review 逐调用审查 | 入口确认（实验） | 用当前模型判定待执行动作，放行即 Full access |
| browser-use / computer-use | 入口确认（实验性） | 多种 MCP/native provider 注册表 |
| feedback / attachment / deliverables | 骨架 / 普通能力 | 日志备注与评分；内容寻址附件；交付物声明 |

## 已确认的独特能力

### 能力一：自省式自扩展（inspect + 持久插件安装）

1. **用户目标与入口**：让模型在会话中检查自己所在运行时的 API、Loader 条目与工具表，并把新的插件/bundle 装进 profile 以改变后续会话。模型面入口是 `cordis_inspect_list` 与 `cordis_inspect_query` 两个只读工具（`packages/extensions/tool-cordis/src/index.ts`），加上 `plugin_manager`（列插件与 bundle、启停、安装、移除）与 `plugin_market`（读市场索引）（`packages/boot/plugin-manager/src/tools.ts`、`plugin-market/src/tools.ts`）。
2. **事实对象**：三个层次——运行时事实（服务/事件目录、Loader 条目及其 Config 状态、条目投影出的 JSON Schema）、插件包（package 目录、README、`lib/`）、bundle（可选补丁层包）。检查结果只读，不调用业务方法；查询从不触发副作用（`docs/tool-catalog.md` 的 tool-cordis 节）。
3. **完整主链**：`cordis_inspect_list` 列 provider（服务/事件目录、Host Config、工具表；浏览器端 provider 需要连接页面）→ `cordis_inspect_query` 取某项 API 或某个 Loader 条目的 Config 投影 → 模型据此写插件或 MCP 配置 → 打包为 bundle → `plugin_manager` 安装进 profile → 用户重启或后续会话加载新行。安装与启停影响整个 profile，需 danger-full-access 或逐次审批。
4. **与旧机制的差别**：本次未找到模型可调用的动态插件定义与运行入口——旧路径（`dyn-<n>` 插件 id、vm 沙箱求值、browser 半装载回执）不再出现在工具目录里。`cordis-host-runner` 仍保留 inspection registry 与生命周期工具，供宿主侧消费者使用；模型面只剩只读查询。
5. **配置方式**：Creator 模式（cordis preset）组合 tool-cordis 与 plugin_manager；`agent-preset` 包随附四套 skill（agent-experience、cordis-plugin-development、editing-cordis-compositions、cordis-composition-reference）指导模型先读检查结果、再读包 README 与源码。
6. **运行边界**：安装的插件是宿主进程内的真实代码，没有沙箱隔离；"只读检查"保证的是查询本身无副作用，而不是被装代码的安全性。

### 能力二：进程沙箱（sandbox）

1. **用户目标与入口**：给"同世界子进程"施加文件效应策略，档位为 read-only / workspace-write / danger-full-access；模型侧不直接调用沙箱工具，而由 permission-presets 或会话选项选择档位，bash/pwsh/fs/terminal 消费 `ctx.sandbox.confine`。
2. **事实对象**：一次调用携带的策略对象（档位、工作区根、可写路径集合）。身份不在会话日志里，属每次调用的参数化约束。
3. **完整主链**：permission preset 选定档位 → shell/fs 工具在 spawn 或写入前调用 `ctx.sandbox.confine` → `sandbox` seam 选后端（`sandbox-local` 内的 bwrap 优先、探针失败回退 Landlock；macOS Seatbelt；Windows 走 `sandbox-windows-acl` 的受限令牌 runner）→ 运行期拒绝 fail-closed → 结果与拒绝原因回到工具结果。
4. **策略来源**：`sandbox-policy` 包解析工作区根与策略，`sandbox-ssh` 把同一策略应用到远端主机；选不出后端抛 `SANDBOX_UNAVAILABLE`，无静默无沙箱回退。
5. **边界**：真实内核行为属平台运行验证项；沙箱只约束文件效应，不约束网络、进程可见性或内存。

### 能力三：同会话目标驱动循环（goal）

1. **用户目标与入口**：把长期目标写成事件溯源状态，agent 在会话内自动续跑直到完成或阻塞。模型工具为 `create_goal` / `get_goal` / `update_goal`（`packages/goal/tool-goal`），另有 `/goal` 命令面（`command-goal`）。
2. **事实对象**：`goal/change` 会话事件加严格递增 revision；激活（armed）是独立、不持久化的进程内标志。
3. **完整主链**：模型创建目标 → `goal-round-driver` 在回合结束时判断是否需要下一轮 → 以普通回合继续（受轮次预算约束，默认上限 256）→ 完成或阻塞由模型自报，连续默认 3 轮同一阻塞条件判为 blocked → 每次变更追加事件，重启后由日志折叠恢复。
4. **权限**：`tool-goal` 在执行时检查调用者是否为根 Agent 且处于开放回合、且本回合含人类来源输入（`packages/goal/tool-goal/src/authority.ts`），防止子 Agent 自建目标。
5. **边界**：目标不带调度与跨会话等待；轮次预算耗尽后停在原地等用户。

### 能力四：plan mode 作为日志化协作状态

1. **用户目标与入口**：在改动前先产出计划并等待批准。入口是 plan 模式切换（UI/命令）与 `exit_plan_mode` 工具；后者要求提交完整 Markdown 计划。
2. **事实对象**：`plan/mode` 是 log-only、整值替换的会话事件；`foldPlanMode` 纯折叠出状态，无 live mirror 对象。
3. **完整主链**：进入 plan 模式追加事件 → 每轮请求加入 `plan:policy` 提示段（order 50），约束模型只调研不修改 → `exit_plan_mode` 提交计划并经 user-questions 缝审批 → 批准后退出模式，后续回合恢复正常权限。
4. **边界**：沙箱与审批策略独立强制执行、互不读写该状态；plan 模式本身不是权限档位，只是提示与协作约定。

### 能力五：Host 级定时任务（schedule）

1. **用户目标与入口**：让 agent 按时间规则自动开工。模型工具为 `schedule_create`（`title`/`prompt`/`rrule`/`target`）、`schedule_list`（分页）、`schedule_view`、`schedule_edit`（update 含 pause/resume 与改 rrule/target，delete 同工具）。
2. **事实对象**：Host 任务 —— `schedule` 领域存储中的记录（`ScheduleRecord`），带 typed timing（After/At/Every/Daily/Weekly/Cron/RRule）、`target`（`this_session`/`new_once`/`new`）、`targetSessionId` 与 paused/ended 状态；领域存储写 version 2、读 version 1，物理布局不变。
3. **完整主链**：`schedule_create` 经 Remote 或原生服务写记录 → timer 作为可弃投影在到期时触发 → 目标会话空闲时以普通对话回合投递 → 每次投递记录 receipt 与目标会话 id → 记录变更追加领域事件，重启后由领域存储重建。
4. **作用范围**：任何 Host 任务都按 id 可读可改可删，不再局限于调用者自己的提醒；委派子 Agent 调用 `schedule_create` 会返回 `subagent_session` 拒绝。要限制某个 preset 不能管理他人任务，只能移除该 preset 的 tool-schedule 行。
5. **边界**：投递是尽力而为的 at-least-once；本轮不提供外部通知通道；历史会话日志里的旧提醒需要显式重建。

### 能力六：多 provider 子代理与团队任务板

1. **用户目标与入口**：把任务委派给同进程子 Agent 或外部执行体，并让多个 Agent 在同一棵树上协作。入口是 `subagent`/`subagent_fork` 工具、控制工具（`send_message`/`interrupt_agent`/`list_agents`/`wait_agent`），以及根会话开启 Team 模式后的 `team_task_create/get/list/update`。
2. **事实对象**：子 Agent 树（祖先、运行时归属、通信）、`subagent/descriptor` 持久描述符、激活句柄（`{ kind: 'activation', subagentId }`）、团队任务（`TeamTaskId` 形如 `task-<n>`，`TeamId` 就是根 `SessionId`）。
3. **完整主链**：模型调用委派工具 → `startActivation` 校验能力旗标 → 本地 `prepareContinuable` 或外部 `start` → 子 Agent 运行 → 本地子 Agent 保留 durable 会话、可继续收消息；外部一次性执行只回最终文本 → 结算后向父 Agent 投递完成通知 → 控制工具读写子 Agent 的身份与 inbox → Team 模式让共享任务在同一面板按 Owner 分派与等待。
4. **策略固定**：子 Agent 继承父的 permission roots 或钉死更严格档，委派策略以 `source: 'delegation'` 写入子会话日志可重放；spawn 用 `agentPreset` 选组合，fork 继承父的 preset。
5. **边界**：外部后端不接受后续消息；team 任务板只协作任务分派，不共享工具循环；历史 roster 记录保留用于解码但不授予权限。

## 支撑与实验机制盘点

### plugin market 与 bundle

`packages/boot/plugin-market` 提供市场索引读取与安装入口，`packages/util/plugin-market-index` 与 `apps/plugin-market-generator` 负责索引生成；bundle 是可安装的 profile 补丁层 npm 包（`packages/boot/app-boot` 定义 Profile 与 bundle 契约），`official-bundles` 列出一方集合。已在兼容层保留的 bundle 经验是"安装即加载组合行"，移除包只需删行。

### skill 注册表

`packages/skill/` 提供 skill seam（`skill`）、`skill-filesystem`（文件系统 provider）、`skill-office`（文档能力）与 `tool-skill`（模型面加载工具）；skill 以 catalog 形式进上下文，按名加载全文。会话内的 skill 目录由 preset 携带（`agent-preset/skills/`）。

### workflow / ralph

`workflow` seam 加 `workflow-ptc` provider（worker 线程执行模型写的工作流脚本），`tool-workflow` 是模型面入口；`ralph` 是固定策略的 fresh-agent 循环（`tool-ralph` 加 `ralph-bundle`）。

### jobs

`jobs` seam 加 `jobs-local`，`tool-jobs` 暴露 `job_list`/`job_output`/`job_kill`；后台 bash/PTY/子 Agent 使用同一协议，owner 隔离、完成通知与取消语义统一。子 Agent 不再经由 jobs 收集。

### forge / LiveShare / worktree / webhook / auto-review

- **forge**：默认禁用的 capability seam，GitHub provider 读变更请求，`forge-session` 把 PR/MR 绑定到会话，`client-ui-forge` 提供面板，`forge-bundle` 组合全部四件并带上 worktree 工具。
- **LiveShare**：把单个会话共享给外部观看者，观看者请求以自身 Peer 派发并受 remote-access 策略与工作区授权约束。
- **worktree**：独立 worktree 服务与 `create_worktree` 工具，为面板与并行任务提供隔离工作区；`generated-worktree-names` 迁移说明命名规则。
- **webhook**：认证投递 → 程序化规则 → 普通根会话，不保存投递或完成状态。
- **auto-review**：实验性逐调用审查——每次内层工具调用前用当前模型的 provider/model 判定待执行动作，放行以 Full access 执行，拒绝则询问用户；默认关闭，可在 Web 侧栏插件页开启。

### browser-use / computer-use

`packages/browser-use/` 与 `packages/computer-use/` 是正式 seam 包，实现分散在 `packages/experimental/browser-use-*`（Playwright、Chrome DevTools MCP、Stagehand native）与 `computer-use-*`（Cua、Cua macOS、driver MCP/native），模型工具形如 `stagehand_*`。

### feedback / attachment / deliverables

`feedback` 分 `message-feedback`（日志备注与 sidecar 评分两种契约）与 `command-feedback`；`attachment` 提供内容寻址附件存储与引用式读取；`deliverables` 提供 `present` 工具把已有文件登记为交付物。

## 已移除或改道的机制

| 机制 | 现状 | 证据 |
|---|---|---|
| 运行期不变式 `invariants` | 删除 | `packages/runtime-diagnostics/` 与 `@deepseek-ai/dsh-invariants` 及 `<pkg>/invariant` 子路径不存在；`docs/upgrade-guide/v0.2.0-rc.2/remove-runtime-invariants` 记录移除 |
| 动态插件 define/run/stop/undefine | 模型面移除 | tool-cordis 只剩两个只读工具；`docs/tool-catalog.md` |
| E2B 远端沙箱 | 删除 | `packages/e2b/` 不存在；SSH 家族取代 |
| session-local 定时提醒 | 改道为 Host 任务 | `schedule` 领域存储 version 2，工具为 create/list/view/edit |
| 实验性 agent-team 包 | 升为一等包 | `packages/team/{agent-team,tool-agent-team}` 与 `client-ui-agent-team` |
| 子 Agent 后台 job 收集 | 移除 | 委派统一返回激活句柄；`job_output` 不再收集子 Agent |
| hooks 包位置 | 迁至 experimental | `packages/experimental/{hook-protocol,hooks-claude-code,hooks-codex}` |

## 设计取舍与已确认边界

- **自扩展从"运行期改自己"改为"安装持久补丁"**：放弃进程内热定义插件，换取可重放、可审计、可卸载的 profile 变更；代价是模型不能即时试跑自己写的插件。
- **权威集中在日志或领域存储**：goal/plan 在会话日志，schedule 在领域存储，team 在根会话；进程内只留可弃投影，重启即重建。
- **沙箱策略按调用携带**：同一进程内的不同工具调用可用不同档位，代价是策略无法用进程级隔离表达。
- **定时任务升为 Host 级**：跨会话管理与入口统一，代价是权限从"仅自己"变成"全部任务"，需要靠移除工具行来收缩。
- **子代理统一激活契约**：外部一次性执行与本地可续会话共享一套准入、取消与归属，代价是两类的后续交互能力不同，调用方必须区分。
- **实验面默认关闭**：forge/liveshare/webhook/auto-review/market 都需显式组合或选择，避免默认暴露网络与权限面。
- **不变式机制退场**：以运行时不变式做防御的做法被移除，失败改由各插件自身的错误通道上报。

## 未验证事项

- 未运行任何进程或测试：沙箱真实内核行为、schedule 定时投递、goal 轮次驱动、plan 审批、plugin_manager 安装与启停、team 任务板协作均为静态确认。
- schedule 领域存储 v2 写入后的降级要求（需备份恢复）只读了迁移说明，未实测。
- auto-review 的实际判定质量、token 成本与误放行/误拒绝风险未评估。
- forge/liveshare/webhook 的安全裁决细节只读了子系统页。
- browser-use/computer-use 的多 provider 选择与真实浏览器/桌面行为属运行观察项。
- `cordis-host-runner` 保留的生命周期工具当前由哪些消费者使用（客户端插件装载、mods 桥？）未逐一确认。

## 关键源码索引

- 自省与自扩展：`packages/extensions/tool-cordis/src/{index,host,providers,present}.ts`、`packages/extensions/cordis-host-runner/src/{index,inspect-registry,lifecycle,sandbox,registry}.ts`、`packages/boot/plugin-manager/src/{index,tools}.ts`、`packages/boot/plugin-market/src/{index,tools}.ts`
- sandbox：`packages/sandbox/sandbox/src/index.ts`、`sandbox-local/src/*`、`sandbox-policy/src/*`、`sandbox-windows-acl/src/*`、`native/`（Landlock 启动器）
- goal：`packages/goal/goal/src/*`、`goal-round-driver/src/*`、`tool-goal/src/authority.ts`、`command-goal/src/*`、`docs/subsystems/goal.md`
- plan：`packages/plan/plan-mode/src/index.ts`（fold、pre-step append、提示段、set/onBoundary）、`docs/subsystems/plan.md`
- schedule：`packages/schedule/schedule/src/{domain,runtime,tools}.ts`、`docs/subsystems/schedule.md`
- subagent 与 team：`packages/subagent/subagent/src/{index,manager,out-of-process,activation,descriptor,depth}.ts`、`packages/team/agent-team/src/{types,index}.ts`、`packages/team/tool-agent-team/src/*`、`docs/subsystems/{subagent,agent-team}.md`
- 支撑：`packages/boot/app-boot/src/index.ts`、`packages/skill/skill-filesystem/src/*`、`packages/workflow/{workflow,workflow-ptc,tool-workflow}/src/*`、`packages/jobs/{jobs,jobs-local,tool-jobs}/src/*`
- 实验面：`packages/experimental/{forge,forge-github,forge-session,client-ui-forge}/src/*`、`liveshare/src/*`、`worktree/src/*`、`webhook/src/*`、`auto-review/src/index.ts`、`browser-use-*/src/*`、`computer-use-*/src/*`
- 文档：`docs/subsystems/{extensions,sandbox,goal,plan,schedule,subagent,agent-team,forge,liveshare,webhook,claude-code-mods}.md`、`docs/upgrade-guide/v0.2.0-rc.2/remove-runtime-invariants`、`docs/upgrade-guide/v0.2.2-alpha.2/schedule-agent-tools`
