# DeepSeek Harness 独特功能调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：静态源码阅读。通读六个机制各自的包 README、`docs/subsystems/` 对应页（含 persistence、spill 等跨机制主题）与各机制关键实现文件；辅以 `docs/upgrade-guide/`；未运行任何进程或测试
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

1. **用户目标与入口**：让模型在会话中检查自己所在运行时的 API、Loader 条目与工具表，并把新的插件或 bundle 装进 profile，以此改变后续会话。模型面入口分三类：
   - 检查：`cordis_inspect_list` 列 provider，`cordis_inspect_query` 取单项或单个 Loader 条目的投影，实现在 `packages/extensions/tool-cordis/src/index.ts`
   - 装配：`plugin_manager` 负责列插件与 bundle、启停、安装和移除，代码在 `packages/boot/plugin-manager/src/tools.ts`
   - 选源：`plugin_market` 读取市场索引，代码在 `packages/boot/plugin-market/src/tools.ts`
2. **事实对象**：自省覆盖三个层次：运行时事实（服务与事件目录、Loader 条目及其 Config 状态、条目投影出的 JSON Schema）、插件包（package 目录、README 与编译产物目录 `lib/`）、bundle（可选的补丁层包）。检查结果只读，不调用业务方法，查询本身也不触发副作用；工具行为见 `docs/tool-catalog.md` 的 tool-cordis 节。
3. **完整主链**：模型先列出 provider，按需取回某项 API 或某个 Loader 条目的 Config 投影，据此写出插件或 MCP 配置，打包成 bundle 后装进 profile，重启或后续会话即加载新的组合行；安装与启停影响整个 profile，需要 danger-full-access 或逐次审批。各步分工如下：
   - `cordis_inspect_list` 列 provider，覆盖服务与事件目录、Host Config 与工具表；检查浏览器端 provider 需要连上页面
   - `cordis_inspect_query` 取单项 API 或某个 Loader 条目的 Config 投影
   - `plugin_manager` 把打包好的 bundle 安装进 profile
4. **模型面入口范围**：本次未找到模型可调用的动态插件定义与运行入口；工具目录里没有 `dyn-<n>` 插件 id，也没有 vm 沙箱求值或 browser 半装载回执这类条目。`cordis-host-runner` 仍保留 inspection registry 与生命周期工具，供宿主侧消费者使用，模型面只剩只读查询。
5. **配置方式**：Creator 模式（cordis preset）把 tool-cordis 与 plugin_manager 组合在一起；`agent-preset` 包随附四套 skill，指导模型先读检查结果、再读包 README 与源码：
   - agent-experience
   - cordis-plugin-development
   - editing-cordis-compositions
   - cordis-composition-reference
6. **运行边界**：安装的插件是宿主进程内的真实代码，没有沙箱隔离；只读检查的作用范围限于查询本身无副作用。

### 能力二：进程沙箱（sandbox）

1. **用户目标与入口**：给同世界子进程施加文件效应策略，模型侧不直接调用沙箱工具。档位由 permission-presets 或会话选项选定，bash、pwsh、fs 与 terminal 在执行前消费 `ctx.sandbox.confine`。可选档位有三档：
   - read-only
   - workspace-write
   - danger-full-access
2. **事实对象**：一次调用携带的策略对象（档位、工作区根、可写路径集合）。身份不在会话日志里，属每次调用的参数化约束。
3. **完整主链**：permission preset 选定档位后，shell 与 fs 工具在 spawn 或写入前调用 `ctx.sandbox.confine`，`sandbox` seam 据此从平台后端中挑一个执行，运行期的拒绝按 fail-closed 处理，结果与拒绝原因一起回到工具结果。后端选择顺序如下：
   - `sandbox-local`：优先 bwrap，探针失败时回退 Landlock
   - macOS：Seatbelt
   - Windows：`sandbox-windows-acl` 的受限令牌 runner
4. **策略来源**：`sandbox-policy` 包解析工作区根与策略，`sandbox-ssh` 把同一份策略应用到远端主机。选不出后端就直接报 `SANDBOX_UNAVAILABLE` 失败，不存在无沙箱的静默回退。
5. **边界**：真实内核行为属平台运行验证项；沙箱只约束文件效应，不约束网络、进程可见性或内存。

### 能力三：同会话目标驱动循环（goal）

1. **用户目标与入口**：把长期目标写成事件溯源状态，agent 在会话内自动续跑，直到完成或被判定阻塞。模型面有三个目标工具，实现在 `packages/goal/tool-goal`：
   - `create_goal`：创建目标
   - `get_goal`：读取目标
   - `update_goal`：更新目标

   另有 `/goal` 命令面（`command-goal`）。
2. **事实对象**：`goal/change` 会话事件加严格递增 revision；激活（armed）是独立、不持久化的进程内标志。
3. **完整主链**：模型创建目标后，`goal-round-driver` 在回合结束时判断是否还要继续，需要时以普通回合接着跑，受轮次预算约束（默认上限 256 轮）。完成或阻塞状态由模型自行上报，同一阻塞条件连续默认 3 轮即判为 blocked。每次变更都追加事件，重启后由日志折叠恢复。
4. **权限**：`tool-goal` 执行时检查调用者，要求它是根 Agent、处于开放回合，且本回合含人类来源输入（`packages/goal/tool-goal/src/authority.ts`），以此阻止子 Agent 自建目标。
5. **边界**：目标不带调度与跨会话等待；轮次预算耗尽后停在原地等用户。

### 能力四：plan mode 作为日志化协作状态

1. **用户目标与入口**：在改动前先产出计划并等待批准。入口是 plan 模式切换（UI/命令）与 `exit_plan_mode` 工具；后者要求提交完整 Markdown 计划。
2. **事实对象**：`plan/mode` 是 log-only、整值替换的会话事件；`foldPlanMode` 纯折叠出状态，无 live mirror 对象。
3. **完整主链**：进入 plan 模式追加事件 → 每轮请求加入 `plan:policy` 提示段（order 50），约束模型只调研不修改 → `exit_plan_mode` 提交计划并经 user-questions 缝审批 → 批准后退出模式，后续回合恢复正常权限。
4. **边界**：沙箱与审批策略独立强制执行、互不读写该状态；plan 模式本身不是权限档位，只是提示与协作约定。

### 能力五：Host 级定时任务（schedule）

1. **用户目标与入口**：让 agent 按时间规则自动开工。模型面有四个工具：
   - `schedule_create` 创建任务
   - `schedule_list` 分页列出任务
   - `schedule_view` 查看单个任务
   - `schedule_edit` 修改任务，update 含暂停、恢复与改 `rrule`/`target`，delete 也走同一工具
2. **创建参数**：`title` 与 `prompt` 描述任务内容，`rrule` 给出时间规则，`target` 决定投递目标，四个参数共同确定一条任务。
3. **事实对象**：Host 任务在 `schedule` 领域存储中表现为一条 `ScheduleRecord`，携带定时方式、投递目标、目标会话 id 与暂停/结束状态；领域存储写 version 2、读 version 1，物理布局保持不变。取值范围为：
   - 定时方式：After、At、Every、Daily、Weekly、Cron、RRule
   - 投递目标：`this_session`、`new_once`、`new`
4. **完整主链**：`schedule_create` 经 Remote 或原生服务写入记录，timer 作为可弃投影在到期时触发，目标会话空闲时以普通对话回合投递，每次投递记录 receipt 与目标会话 id。记录变更追加领域事件，进程重启后由领域存储重建。
5. **作用范围**：任何 Host 任务都按 id 可读、可改、可删，覆盖范围超出调用者自己的提醒；委派子 Agent 调用 `schedule_create` 会返回 `subagent_session` 拒绝。要限制某个 preset 不能管理他人任务，只能移除该 preset 的 tool-schedule 行。
6. **边界**：投递是尽力而为的 at-least-once；本轮不提供外部通知通道；历史会话日志里的旧提醒需要显式重建。

### 能力六：多 provider 子代理与团队任务板

1. **用户目标与入口**：把任务委派给同进程子 Agent 或外部执行体，并让多个 Agent 在同一棵树上协作。入口分四组：
   - 委派：`subagent` 与 `subagent_fork`
   - 消息与打断：`send_message`、`interrupt_agent`
   - 树与等待：`list_agents`、`wait_agent`
   - 团队任务：根会话开启 Team 模式后可用 `team_task_create/get/list/update`
2. **事实对象**：这套机制维护四类事实：
   - 子 Agent 树，记录祖先、运行时归属与通信关系
   - `subagent/descriptor` 持久描述符
   - 激活句柄，形如 `{ kind: 'activation', subagentId }`
   - 团队任务，`TeamTaskId` 形如 `task-<n>`，`TeamId` 取根 `SessionId`
3. **完整主链**：模型调用委派工具后，`startActivation` 先校验能力旗标，再按执行位置分流：本地走 `prepareContinuable`，外部走 `start`。本地子 Agent 保留 durable 会话，可以继续收消息；外部一次性执行只回最终文本。子 Agent 跑完结算后向父 Agent 投递完成通知，控制工具负责读写子 Agent 的身份与 inbox，Team 模式让共享任务在同一面板按 Owner 分派与等待。
4. **策略固定**：子 Agent 继承父的 permission roots，或被钉在更严格的档位；委派策略以 `source: 'delegation'` 写入子会话日志，可重放。spawn 时用 `agentPreset` 选定组合，fork 则继承父的 preset。
5. **边界**：外部后端不接受后续消息；team 任务板只协作任务分派，不共享工具循环；历史 roster 记录保留用于解码但不授予权限。

## 支撑与实验机制盘点

### plugin market 与 bundle

`packages/boot/plugin-market` 提供市场索引读取与安装入口，`packages/util/plugin-market-index` 与 `apps/plugin-market-generator` 负责索引生成；bundle 是可安装的 profile 补丁层 npm 包（`packages/boot/app-boot` 定义 Profile 与 bundle 契约），`official-bundles` 列出一方集合。已在兼容层保留的 bundle 经验是"安装即加载组合行"，移除包只需删行。

### skill 注册表

skill 能力由 `packages/skill/` 下的四个包组成：
- `skill`：seam 本体
- `skill-filesystem`：文件系统 provider
- `skill-office`：文档能力
- `tool-skill`：模型面加载工具

skill 以 catalog 形式进入上下文，按名加载全文；会话内的 skill 目录由 preset 携带，位于 `agent-preset/skills/`。

### workflow / ralph

workflow 由 `workflow` seam 与 `workflow-ptc` provider 组成，后者在 worker 线程里执行模型写的工作流脚本，模型通过 `tool-workflow` 调用。ralph 是固定策略的 fresh-agent 循环，由 `tool-ralph` 与 `ralph-bundle` 拼成。

### jobs

后台任务由 `jobs` seam 与 `jobs-local` 组成，模型面的 `tool-jobs` 暴露三个工具：
- `job_list`：列出任务
- `job_output`：读取输出
- `job_kill`：取消任务

后台 bash、PTY 与子 Agent 共用同一协议，owner 隔离、完成通知与取消语义一致；子 Agent 改由委派的激活句柄收集。

### forge / LiveShare / worktree / webhook / auto-review

- **forge**：默认禁用的 capability seam，GitHub provider 读变更请求，`forge-session` 把 PR/MR 绑定到会话，`client-ui-forge` 提供面板，`forge-bundle` 组合全部四件并带上 worktree 工具。
- **LiveShare**：把单个会话共享给外部观看者，观看者请求以自身 Peer 派发并受 remote-access 策略与工作区授权约束。
- **worktree**：独立 worktree 服务与 `create_worktree` 工具，为面板与并行任务提供隔离工作区；`generated-worktree-names` 迁移说明命名规则。
- **webhook**：认证投递 → 程序化规则 → 普通根会话，不保存投递或完成状态。
- **auto-review**：实验性逐调用审查——每次内层工具调用前用当前模型的 provider/model 判定待执行动作，放行以 Full access 执行，拒绝则询问用户；默认关闭，可在 Web 侧栏插件页开启。

### browser-use / computer-use

`packages/browser-use/` 与 `packages/computer-use/` 是正式 seam 包，实现分散在 `packages/experimental/browser-use-*`（Playwright、Chrome DevTools MCP、Stagehand native）与 `computer-use-*`（Cua、Cua macOS、driver MCP/native），模型工具形如 `stagehand_*`。

### feedback / attachment / deliverables

feedback 分成 `message-feedback` 与 `command-feedback` 两条实现，前者覆盖日志备注与 sidecar 评分两种契约。attachment 提供内容寻址的附件存储与引用式读取；deliverables 提供 `present` 工具，把已有文件登记为交付物。

## 机制缺位与归属

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

- **自扩展走安装持久补丁**：插件以 profile 变更的形式安装，可重放、可审计、可卸载；没有进程内热定义的入口，代价是模型不能即时试跑自己写的插件。
- **权威集中在日志或领域存储**：goal/plan 在会话日志，schedule 在领域存储，team 在根会话；进程内只留可弃投影，重启即重建。
- **沙箱策略按调用携带**：同一进程内的不同工具调用可用不同档位，代价是策略无法用进程级隔离表达。
- **定时任务升为 Host 级**：跨会话管理与入口统一，代价是权限从"仅自己"变成"全部任务"，需要靠移除工具行来收缩。
- **子代理统一激活契约**：外部一次性执行与本地可续会话共享一套准入、取消与归属，代价是两类的后续交互能力不同，调用方必须区分。
- **实验面默认关闭**：forge/liveshare/webhook/auto-review/market 都需显式组合或选择，避免默认暴露网络与权限面。
- **失败上报走插件自身错误通道**：当前没有运行时不变式防御层，失败由各插件自身的错误通道上报。

## 未验证事项

- 未运行任何进程或测试：沙箱真实内核行为、schedule 定时投递、goal 轮次驱动、plan 审批、plugin_manager 安装与启停、team 任务板协作均为静态确认。
- schedule 领域存储 v2 写入后的降级要求（需备份恢复）只读了迁移说明，未实测。
- auto-review 的实际判定质量、token 成本与误放行/误拒绝风险未评估。
- forge/liveshare/webhook 的安全裁决细节只读了子系统页。
- browser-use/computer-use 的多 provider 选择与真实浏览器/桌面行为属运行观察项。
- `cordis-host-runner` 保留的生命周期工具当前由哪些消费者使用（客户端插件装载、mods 桥？）未逐一确认。

## 关键源码索引

- 本次重点包（机制主体）：`packages/extensions/`、`packages/boot/plugin-manager`、`packages/boot/plugin-market`、`packages/sandbox/`
- 本次重点包（目标、计划、定时与团队）：`packages/goal/`、`packages/plan/plan-mode`、`packages/schedule/`、`packages/subagent/`、`packages/team/`
- 关联包：`packages/bundle/`、`packages/skill/`、`packages/workflow/`、`packages/jobs/`、`packages/experimental/{forge,liveshare,worktree,auto-review,webhook,browser-use,computer-use}`
- 调查方式涉及的实现入口（宿主与插件面）：`tool-cordis`、`cordis-host-runner` 的 inspection registry、`plugin-manager`
- 调查方式涉及的实现入口（机制实现）：`goal` 与 `goal-round-driver`、`plan-mode`、`schedule` 的 domain/runtime/tools、`sandbox-local`、`subagent` 的 activation/out-of-process、`team/agent-team`
- 自省与自扩展：`packages/extensions/tool-cordis/src/{index,host,providers,present}.ts`、`packages/extensions/cordis-host-runner/src/{index,inspect-registry,lifecycle,sandbox,registry}.ts`、`packages/boot/plugin-manager/src/{index,tools}.ts`、`packages/boot/plugin-market/src/{index,tools}.ts`
- sandbox：`packages/sandbox/sandbox/src/index.ts`、`sandbox-local/src/*`、`sandbox-policy/src/*`、`sandbox-windows-acl/src/*`、`native/`（Landlock 启动器）
- goal：`packages/goal/goal/src/*`、`goal-round-driver/src/*`、`tool-goal/src/authority.ts`、`command-goal/src/*`、`docs/subsystems/goal.md`
- plan：`packages/plan/plan-mode/src/index.ts`（fold、pre-step append、提示段、set/onBoundary）、`docs/subsystems/plan.md`
- schedule：`packages/schedule/schedule/src/{domain,runtime,tools}.ts`、`docs/subsystems/schedule.md`
- subagent 与 team：`packages/subagent/subagent/src/{index,manager,out-of-process,activation,descriptor,depth}.ts`、`packages/team/agent-team/src/{types,index}.ts`、`packages/team/tool-agent-team/src/*`、`docs/subsystems/{subagent,agent-team}.md`
- 支撑：`packages/boot/app-boot/src/index.ts`、`packages/skill/skill-filesystem/src/*`、`packages/workflow/{workflow,workflow-ptc,tool-workflow}/src/*`、`packages/jobs/{jobs,jobs-local,tool-jobs}/src/*`
- 实验面：`packages/experimental/{forge,forge-github,forge-session,client-ui-forge}/src/*`、`liveshare/src/*`、`worktree/src/*`、`webhook/src/*`、`auto-review/src/index.ts`、`browser-use-*/src/*`、`computer-use-*/src/*`
- 文档：`docs/subsystems/{extensions,sandbox,goal,plan,schedule,subagent,agent-team,forge,liveshare,webhook,claude-code-mods}.md`、`docs/upgrade-guide/v0.2.0-rc.2/remove-runtime-invariants`、`docs/upgrade-guide/v0.2.2-alpha.2/schedule-agent-tools`
