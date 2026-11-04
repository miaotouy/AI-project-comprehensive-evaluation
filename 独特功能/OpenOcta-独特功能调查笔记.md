# OpenOcta 独特功能调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：以根 README、`docs/` 产品说明建立候选，再逐一核对 Go 包、Gateway 方法注册、Control UI 控制器/视图与持久化路径；重点走通定时任务、告警接入、审批、数字员工、知识库、蜂群、IM 渠道、Skill 提炼与 A2UI 的入口到结果链；未运行桌面端、Gateway 或任何外部渠道
>
> 调查范围：超出通用 Chat 与单 Agent 会话的产品工作流；不覆盖普通消息渲染、Provider 配置、主题、快捷键、模型下载与通用工具注册等已由其他类目承接的内容
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的辨识度不在聊天界面，而在「把 Agent 放进运维闭环」的一组工作流：

- 无人值守运行：Cron 任务与 `/hooks/alert`、`/hooks/agent` 等外部触发，让 Agent 在无人对话时启动一轮分析，并把结果写回会话、运行日志或 IM/Webhook。
- 命令策略与审批：按 allow/ask/deny 规则评估复合命令，敏感工具在执行前可中断等待人工批准。
- 数字员工：把「人设 + Skill 白名单 + 专属 MCP」打包成模板，会话与定时任务都能绑定。
- Knowledge Vault：本地 Obsidian 兼容的 Markdown 知识库，带全文/向量混合索引、文件树、双链图谱与 `memory_search` 工具。
- Agent Swarm：房间式多 Agent 协作，成员可再拆子 Agent，用户可单独指挥任意成员，拓扑与历史可恢复。
- IM 渠道双向：企业微信、微信、钉钉、飞书、QQ 的入站消息映射为会话，回复按原渠道回投。
- 会话经验提炼 Skill：把一段对话交给模型生成 SKILL.md，预览后下载，再走 Skill 安装/编辑流程。
- A2UI 回复通道：助手文本被编码成 A2UI 组件树下发，前端用组件运行时渲染，组件动作可回流为下一轮消息。

其中无人值守运行、数字员工、Knowledge Vault、Agent Swarm、IM 渠道与经验提炼六项具备入口、执行、结果与持久化的完整静态链路；审批与 A2UI 的主链只接通了一部分（见各卡边界）。Wails 桌面壳、应用内更新、日志导出与本地模型下载属于基础设施，不计入特色贡献。

## 介绍声明与候选盘点

| 声明来源 | 候选能力 | 代码落点 | 本次状态 |
|---|---|---|---|
| README「auto inspection / scheduled inspection」 | 定时任务与巡检 | `src/pkg/cron/`、`cron.*` 方法 | 主链确认 |
| README「alert intake」 | 告警 Webhook 接入 | `src/pkg/gateway/http/hooks.go` | 主链确认 |
| README「digital employees」 | 数字员工 | `src/pkg/employees/`、`employees.*` | 主链确认 |
| README「Knowledge Vault」「four-tier memory」 | 本地知识库 | `src/pkg/agent/knowledge/`、`vault.*` | 主链确认（记忆写入另见声明不符） |
| README「L4 Evolution」 | 记忆演化 | `src/pkg/agent/evolution/` | 仅读取注入，写入未接线 |
| README「WeCom / DingTalk / Feishu / WeChat」 | IM 远程派单 | `src/pkg/channels/`、`pkg/gateway/http/inbound_sink.go` | 主链确认 |
| README「Skills」「skills marketplace」 | Skill 创作与安装 | `src/pkg/agent/skills/`、`skills.compose/analyze/install` | 主链确认（市场在仓库外） |
| `docs/agent-swarm.md` | 多 Agent 协作 | `src/pkg/swarm/`、`swarm.*` | 主链确认 |
| README「approval」「security」 | 审批式变更 | `src/pkg/security/`、`approvals.*` | 后端主链确认，前端闭环未接通 |
| `package.json` 的 `@a2ui/lit` | 组件化回复 | `src/pkg/a2ui/`、`ui/src/ui/chat/a2ui-*` | 文本通道确认，交互组件未验证 |
| README「Wails desktop」「single binary」 | 桌面形态 | `src/main.go`、`src/pkg/desktop/` | 归并基础设施 |

## 已确认的独特能力

### 1. 无人值守运行：定时任务、告警接入与结果投递

| 维度 | 内容 |
|---|---|
| 用户目标 | 巡检、告警分析等常态工作不依赖用户坐在聊天窗口前；Cron 结果能按配置主动送达值班渠道 |
| 入口与触发者 | Control UI 的 Cron 页（`cron.add/run/runs`）；外部系统 POST `/hooks/alert`、`/hooks/agent`、`/hooks/wake`；调度器自身的到期循环 |
| 事实对象 | `CronJob`：schedule、payload、sessionTarget、wakeMode、delivery、runConfig、state |
| 执行与结果 | 到期任务走 `chat.send` 生成正常转录；完成后把最终回复摘要写运行日志并按 delivery 发送 |
| 持续性 | 任务定义存 `cron/jobs.json`，运行日志存 `cron/runs/*.jsonl`，重启后由 timer 重新计算下次运行 |
| 证据强度 | 主链确认（静态）；真实渠道送达未验证 |

**主链。** 创建任务时解析 `at`/`every`/`cron` 三种调度、两种 payload（`systemEvent` 与 `agentTurn`）以及 `main`/`isolated` 两种会话目标，连同数字员工 ID、资源过滤和投递配置写入 jobs 文件（`src/pkg/gateway/handlers/cron.go:102-179`、`src/pkg/cron/types.go:5-71`）。服务启动后按最近一次到期时间睡眠，最多 60 秒唤醒一次，取到期任务逐个执行（`src/pkg/cron/service.go:440-496`）。

执行时先校验 payload 与会话目标是否匹配，再构造会话键：手动强制运行使用 `agent:main:cron:<jobId>:run:<uuid>`，定时运行复用 `agent:main:cron:<jobId>`（任务显式配置 sessionKey 时改用该值），绑定数字员工时改用 `agent:main:employee:<id>`（`src/pkg/cron/service.go:298-350`）。随后调用 `RunCronChat`，再由 HTTP 层转成 `chat.send`，因此 Cron 运行和用户聊天共享同一套转录、工具与权限链路（`src/pkg/gateway/http/server.go:338-352`）。

**投递。** 会话结束后取「最后一个工具块之后」的文本作为摘要，思考与工具输出不会进入 IM（`src/pkg/gateway/handlers/chat.go:1072-1103`）。若任务配置了 `announce`，调用 Gateway 的 `send` 方法带 header 发往指定渠道；若配置了 `webhook`，POST 一个含任务 ID、会话键、摘要与状态的 JSON（`src/pkg/gateway/handlers/cron_delivery.go:142-199`）。10 秒内重复摘要会被去重，header 超过 50 字符会截断（`:42-61`、`:154-158`）。

**外部触发。** `/hooks/alert` 不要求固定的告警结构：解析失败时把整个请求体当作 message，然后拼出一段要求先查 MCP/Skill 再分析的 SRE 提示词，在新建的 `agent:main:alert:<uuid>` 会话里运行（`src/pkg/gateway/http/hooks.go:284-392`）。这条链路没有告警字段校验，也没有限流或来源签名，是否启用与 token 由 hooks 配置控制（`:88-105`）。该调用只传 `Deliver: true`，没有带 `Channel` 与 `To`，因此告警分析结果默认只留在会话里，不会像 Cron 那样主动外发（`:314-320`、`src/pkg/gateway/handlers/chat.go:806-811`）。

**已确认边界。** 运行状态字段 `RunningAtMs` 只在结束时被清空，从未在开始时写入，`Run` 也没有互斥判断；因此定时触发与界面上的强制运行可能同时启动同一任务（`src/pkg/cron/types.go:37-46`、`src/pkg/cron/service.go:356-390`）。桌面模式原本计划跳过 Cron，但对应开关被注释掉，当前桌面端仍会启动调度（`src/pkg/desktop/gateway.go:31-36`）。

### 2. 命令策略与审批门控

| 维度 | 内容 |
|---|---|
| 用户目标 | 让 Agent 能执行运维命令，同时把高风险动作限制为需人工确认或直接拒绝 |
| 入口与触发者 | 配置中的命令策略；Agent 调用 `execute` 工具时由运行时拦截；Security 页的审批列表 |
| 事实对象 | 策略规则（命令/片段、allow/ask/deny、禁用参数、密钥模式）与 `ApprovalRecord`（pending/approved/denied、白名单 TTL） |
| 执行与结果 | 命令先过策略与遗留校验器；开启审批时，`execute` 在真正执行前触发 Eino 中断，恢复时带批准结果 |
| 持续性 | 审批记录与白名单以 JSON 原子写入 `agents/approvals/approvals.json`，进程重启可恢复 |
| 证据强度 | 后端执行链与持久化确认；用户界面闭环未接通 |

**策略求值。** 复合命令按 `&&`、`||`、`;` 拆段，逐段匹配规则并取最严格结果；显式 allow 可以覆盖遗留 validator 的 deny（`src/pkg/agent/runtime/command_policy.go:103-179`）。求值结果被转换成遗留 validator，在文件系统后端的 `execute` 调用前执行（`src/pkg/agent/runtime/runtime.go:104-114`、`src/pkg/agent/eino/localbackend/backend.go:28-53`）。

**中断与恢复。** 审批开启时，引擎在工具链上追加一个只拦截 `execute` 的中间件；首次调用不执行工具，而是发出带工具名与原始参数的 `StatefulInterrupt`，恢复后若 `approved` 为真才用暂存参数执行，否则把拒绝原因作为工具结果返回（`src/pkg/agent/eino/approval_middleware.go:31-123`）。Gateway 侧把中断广播成 `state: "interrupted"` 的聊天事件，并提供 `chat.resume` 接收 `approved`、`reason` 与上下文（`src/pkg/gateway/handlers/chat.go:3231-3254`、`:3677-3719`）。

**队列管理。** `ApprovalQueue` 把记录与按会话的到期白名单落盘，支持批准、拒绝、等待（条件变量）与白名单续期（`src/pkg/security/approval.go:66-273`）。Gateway 暴露 `approvals.list/approve/deny/whitelistSession`，并按配置的 `timeoutSeconds` 计算过期状态（`src/pkg/gateway/handlers/approvals.go:36-60`、`:157-199`）。

**未接通部分。** 前端存在一个 Exec 审批浮层，监听 `exec.approval.requested` 并提供 Allow once / Always allow / Deny（`ui/src/ui/views/exec-approval.ts:25-80`、`ui/src/ui/app-gateway.ts:326-345`）。但这条链在仓库内没有生产端：

- 后端 `exec.approval.request`、`exec.approval.resolve` 与 `exec.approvals.set` 都是未实现桩，也没有代码广播该事件（`src/pkg/gateway/handlers/exec_approvals.go:17-48`）。
- 本次未找到 UI 调用 `chat.resume` 的位置，中断后的「点击批准继续」只完成到后端接口。
- 审批队列的写入方不在本仓库：`ApprovalQueue.Request` 除测试外没有调用者，审批列表读取的文件可能由外部 Agent SDK 写入或始终为空（`src/pkg/security/approval.go:66-109`、`src/pkg/gateway/handlers/approvals.go:62-70`）。

### 3. 数字员工：角色化的提示词、技能与 MCP 装配

| 维度 | 内容 |
|---|---|
| 用户目标 | 把「全能助手」拆成多个专业角色，降低无关技能与工具带来的干扰和 token 消耗 |
| 入口与触发者 | 数字员工页创建/编辑/启停/删除，员工市场安装；用户点「会话」或定时任务绑定 |
| 事实对象 | `Manifest`：ID、名称、描述、人设 prompt、技能 ID 列表、专属 MCP、启用状态、来源 |
| 执行与结果 | 会话键包含员工 ID，运行时据此选择员工技能目录、合并 MCP，并用员工 prompt 作为系统提示覆盖 |
| 持续性 | Manifest 存 `~/.openocta/employees/<id>/manifest.json`，随状态目录持久化；删除员工会级联删除其会话 |
| 证据强度 | 主链确认（静态）；官网市场下载未验证 |

**建模与存储。** 员工模板包含 prompt、`SkillIDs`、`McpServers`，并标注 `Builtin`、`Type`、`From` 以区分内置、自建与远程安装（`src/pkg/employees/model.go:7-30`）。列表汇总会同时解析 manifest 中的技能与员工目录下的 `employee_skills`（`src/pkg/employees/model.go:32-46`）。

**会话装配。** 当会话键形如 `agent:main:employee:<id>` 时，聊天处理链从员工 manifest 取 prompt 作为系统提示覆盖，把员工 MCP 合并进全局 MCP（同名时员工覆盖全局），并把技能目录切换到员工专属目录（`src/pkg/gateway/handlers/chat.go:1399-1410`、`:2212-2219`、`src/pkg/agent/runtime/skills.go:82-83`）。定时任务若绑定员工，会直接使用员工会话键，从而复用同一套装配（`src/pkg/cron/service.go:316-318`）。

**管理面。** 创建接口支持名称、描述、prompt、启停、技能 ID 与 MCP，编辑时合并已有 manifest 且不允许改内置员工；删除时先清理该员工的会话条目（`src/pkg/gateway/handlers/employees.go:66-199`）。员工 ID 默认直接取名称，仅做 `local:` 前缀与冒号替换（`:14-27`、`:201-227`）。

**外部依赖。** 「员工市场」从远端目录拉取条目并安装，来源标记为 `remote`，UI 只负责安装状态与按钮（`ui/src/ui/views/employee-market.ts:150-185`、`:234-272`）。市场服务不在本仓库，安装后的文件布局本次未逐项核对。

### 4. Knowledge Vault：可编辑的本地知识库与检索注入

| 维度 | 内容 |
|---|---|
| 用户目标 | 让 Runbook、架构笔记和历史经验成为 Agent 可检索的长期上下文，同时保持用户可读可改 |
| 入口与触发者 | 知识库页的文件树、编辑器、搜索与图谱；Agent 在对话中调用 `memory_search` |
| 事实对象 | Vault 目录下的 Markdown 文件与派生索引（Bleve + 可选向量） |
| 执行与结果 | 启动或手动同步时全量扫描、分块、重建索引；检索返回路径、行号与摘要 |
| 持续性 | Vault 是普通文件夹；索引在 `knowledge-index/`，可随时重建 |
| 证据强度 | 主链确认（静态）；检索质量与向量效果未验证 |

**入口与文件面。** `vault.*` 方法覆盖状态、列目录、读写文件、新建/重命名/删除文件与目录、搜索、同步和图谱（`src/pkg/gateway/handlers/health.go:148-160`）。文件操作被限制在 Vault 根目录内，路径会被清洗（`src/pkg/gateway/handlers/vault.go:558-581`、`:584-633`）。

**索引与检索。** `knowledge.Engine` 用 Bleve 建全文索引，并在配置了 embedder 时叠加向量相似度，默认权重为全文 0.55、向量 0.45（`src/pkg/agent/knowledge/engine.go:34-47`）。`memory_search` 工具只检索 `document` 类型，默认返回 8 条命中，结果是带路径与文本片段的 JSON（`src/pkg/agent/eino/knowledge_tools.go:20-55`）。知识库始终启用，启动时解析 Vault 与索引目录并注入系统提示（`src/pkg/agent/runtime/knowledge.go:13-46`）。

**图谱。** `vault.graph` 扫描 Markdown 中的 wiki 链接与普通链接，建立节点和边，供前端拓扑视图渲染（`src/pkg/gateway/handlers/vault.go:584-660`）。同步会清空会话运行时缓存并全量重建索引，返回文件数与分块数（`:558-581`）。

**已确认边界。** 系统提示明确要求模型使用 `session_search` 查询当前会话历史，但工具注册只包含 `memory_search`，仓库内也没有 `session_search` 的工具实现；`knowledge.SearchHistory` 存在但未被接入（`src/pkg/agent/runtime/knowledge.go:46`、`src/pkg/agent/eino/knowledge_tools.go:20-55`、`src/pkg/agent/knowledge/history.go:17`）。这意味着提示词会引导模型调用一个不存在的工具。

### 5. Agent Swarm：房间式多 Agent 协作

| 维度 | 内容 |
|---|---|
| 用户目标 | 把可分解、可并行的任务交给一棵可介入的 Agent 树，而不是单个长回合 |
| 入口与触发者 | 蜂群页创建房间；用户向任意成员发消息；成员通过 `swarm_member_create`/`sessions_spawn` 拆子 Agent |
| 事实对象 | Workspace、Member（父子关系、状态、会话键、绑定的数字员工）、房间历史 |
| 执行与结果 | 每次成员消息启动一个 A2A 任务，流式增量广播到前端，完成后写历史并回到 idle/failed |
| 持续性 | 房间与成员存 `swarm/workspaces.json`，历史最多 500 条，重启后可继续 |
| 证据强度 | 主链确认（静态）；多 Agent 并发质量未验证 |

**编排。** 创建房间时同时建立根成员；`SpawnSubagent` 在父成员下创建子成员，先在配额检查通过后落库，再把初始指令作为一条消息发给子成员（`src/pkg/swarm/orchestrator.go:52-121`）。成员消息先写用户历史、把状态置为 busy，再通过 `RuntimeExecutor.StartTask` 启动任务；流式增量、最终输出与错误分别广播，结束后写助手历史并恢复状态（`:123-215`）。

**配额与取消。** 树深最多 10 层、可继续派生的父层上限 8、每成员最多 5 个直接子成员、每房间最多 55 个成员（`src/pkg/swarm/limits.go:4-11`）。`StopAll` 取消工作区内所有运行并清理 busy 状态；`RemoveMember` 支持级联删除（`src/pkg/swarm/orchestrator.go:229-255`）。

**Agent 可见工具。** 成员侧注入 `swarm_member_create`、`swarm_message_send`，并在允许时注入 `sessions_spawn` 作为别名；工具说明明确要求「同一子 Agent 只创建一次」，避免模型重复派生（`src/pkg/gateway/handlers/swarm_tools.go:17-40`、`:107-133`）。

**UI 与持久化。** 前端按房间加载工作区、成员、图谱与历史，支持中止全部与删除房间（`ui/src/ui/controllers/swarm.ts:63-167`）。存储层把 Workspace 与 Member 一起写入单个 JSON 文件，成员状态与父 ID 都在其中（`src/pkg/swarm/store.go:24-45`、`:96-117`）。

### 6. IM 渠道双向：远程派单与原渠道回投

| 维度 | 内容 |
|---|---|
| 用户目标 | 在微信/企业微信/钉钉/飞书/QQ 里直接给 Agent 派任务，并在同一会话收到结果 |
| 入口与触发者 | 各渠道 Runtime 的长连接或回调；用户在 IM 中发消息 |
| 事实对象 | InboundMessage（渠道、会话 ID、发送者、内容、元数据）与 `agent:main:channel:<channel>:<peer>` 会话 |
| 执行与结果 | 入站消息转成 HooksAgent 调用，走 `chat.send`；回复按渠道与原会话 ID 回投 |
| 持续性 | 会话与普通聊天共用转录；渠道配置热重载会重建 Runtime |
| 证据强度 | 主链确认（静态）；真实账号收发未验证 |

**注册与热重载。** HTTP 层按配置注册 wework、weixin、dingtalk、feishu、qq 五个 Runtime，配置变更时停止旧连接并按新配置重建（`src/pkg/gateway/http/server.go:719-758`、`:364-378`）。渠道 Runtime 统一实现启动、停止、允许发送者判断与状态快照（`src/pkg/channels/runtime.go:44-105`）。

**入站映射。** `hooksAgentSink` 取消息内容与 `ChatID`（缺失时退回发送者 ID），拼出 `agent:main:channel:<channel>:<peer>`；若该渠道配置了 `digitalEmployeeId` 且 manifest 存在，则整个渠道切到员工会话键（`src/pkg/gateway/http/inbound_sink.go:32-94`）。随后调用 `HooksAgent`，携带 `Deliver: true`、渠道、目标会话与元数据。

**回投。** 回复经 `deliverAssistantToIM` 交给原渠道 Runtime 的 `Send`，并带回原消息 ID 作为引用（`src/pkg/gateway/handlers/chat.go:805-846`）。代码里保留了「`| 回复 <agentName>: <userQuery>` + 正文」的格式化意图，但 `formatChannelReply` 当前直接返回正文，前缀分支被注释掉，因此实际发送的是纯回复内容（`:1137-1149`）。仅当渠道与目标都存在时才投递，缺失时静默跳过（`:806-811`）。

**边界。** 渠道允许发送者由 `isAllowed` 与各 Runtime 的配置决定，`runtime.go` 只提供基础判断（`src/pkg/channels/runtime.go:175-189`）。群聊与单聊的会话隔离依赖 peer ID 与 `chatType` 元数据；同一群不同话题是否共享会话，本次未验证。

### 7. 会话经验提炼为 SKILL.md，并接入 Skill 创作/安装

| 维度 | 内容 |
|---|---|
| 用户目标 | 把一次成功的排障或操作对话沉淀为可复用的技能，而不是留在聊天记录里 |
| 入口与触发者 | 聊天输入区「提炼SKILL」；技能库的上传向导与对话式创作 |
| 事实对象 | 生成的 SKILL.md（frontmatter + 正文）、技能草稿、技能目录条目 |
| 执行与结果 | 读整段转录 → 模型生成 → 预览 → 下载；另可经 compose/analyze 生成草稿并保存/安装 |
| 持续性 | 提炼结果不落盘；安装后的技能以文件形式存在于托管/工作区技能目录 |
| 证据强度 | 主链确认（静态）；模型提炼质量未验证 |

**提炼链。** 后端读整段转录，跳过 system 与工具结果，把用户/助手文本与思考块拼成对话记录，套上「只提炼反复出现或关键工作流、必须带 frontmatter」的提示词，在一个禁用技能、子 Agent、沙箱与系统提示的独立运行时里执行（`src/pkg/gateway/handlers/chat_extract_skill.go:18-30`、`:99-142`、`:176-218`）。输出经围栏剥离后返回 Markdown 与文件名；前端在只读弹窗中预览并用 Blob 下载（`ui/src/ui/views/chat.ts:761-785`、`ui/src/ui/controllers/chat-extract-skill.ts:44-52`）。

**技能体系。** 技能以 `SKILL.md` 或单文件 Markdown 存在，按 `extraDirs < bundled < managed < workspace` 的优先级合并，同名时后者覆盖前者（`docs/skills.md:17-31`、`src/pkg/agent/skills/loader.go:89-177`）。Gateway 暴露的方法分两组：

- 安装与文件编辑：`skills.install` 接收上传包，保存、列举、读取单文件分别由 `skills.saveFile`、`skills.listFiles`、`skills.getFile` 承担。
- 创作辅助：`skills.compose` 用对话生成技能草稿，`skills.analyze` 解析已有技能并推断其所需工具（`src/pkg/gateway/handlers/health.go:139-147`、`:212-213`、`src/pkg/gateway/handlers/skill_compose.go:191-256`）。

**闭环程度。** 提炼结果只能下载，仓库内没有「把返回的 Markdown 直接安装为技能」的调用；用户需要再走上传/保存流程。因此这是「经验 → 文档」的沉淀，不是自动安装的自进化闭环。技能草稿在 compose 中只作为返回值，落盘由后续保存动作完成（`src/pkg/gateway/handlers/skill_compose.go:225-238`）。

### 8. A2UI 组件化回复与动作回流

| 维度 | 内容 |
|---|---|
| 用户目标 | 让助手回复不只是 Markdown，而是可组合、可交互、能回传动作的界面 |
| 入口与触发者 | 每个助手回合的文本增量；用户在 A2UI 组件上触发的动作 |
| 事实对象 | A2UI ServerMessage（surface、组件树、数据模型）与客户端动作 |
| 执行与结果 | 文本增量被编码为 createSurface/updateComponents/updateDataModel；前端用 `@a2ui/lit` 渲染；动作回到 `chat.a2ui.action` 并转成新一轮消息 |
| 持续性 | 组件块随助手消息写入转录，重开会话可重新渲染 |
| 证据强度 | 文本承载与动作回流确认；模型主动生成交互组件未验证 |

**服务端编码。** `AssistantTextStream.AppendDelta` 在首个增量时发 `createSurface`，随后发一个 `Column` 包含 `Text` 组件的布局，再把累计文本写入 `/content` 数据模型（`src/pkg/a2ui/stream.go:26-72`）。Gateway 收到 `EventA2UI` 后广播并把它追加成消息内容块，供历史回放（`src/pkg/gateway/handlers/chat.go:2679-2690`）。

**前端渲染与去重。** UI 用 `@a2ui/web_core`/`@a2ui/lit` 处理消息，按 surface 去重、过滤纯文本 surface，并在存在 A2UI 时抑制重复的 Markdown 正文（`ui/src/ui/chat/a2ui-bridge.ts:50-93`、`:162-272`、`ui/src/ui/chat/grouped-render.ts:331-359`）。

**动作回流。** 组件动作被包装成含 `name`、`surfaceId`、`sourceComponentId`、`timestamp`、`context` 的对象，调用 `chat.a2ui.action`；后端把它格式化为 `[A2UI Action: <name>]` 加 JSON，再作为一条新消息走 `chat.send`（`ui/src/ui/chat/a2ui-bridge.ts:74-93`、`src/pkg/gateway/handlers/chat.go:3622-3675`）。

**已确认边界。** 解析器支持从标记为 a2ui、jsonl 或 json 的代码围栏中提取消息，也保留了「移除命令确认按钮、改为文字确认」的清理函数，但本次未找到这些函数的调用方；没有证据表明模型可以主动输出可交互组件并被渲染（`src/pkg/a2ui/parser.go:100-134`、`src/pkg/a2ui/confirmation_strip.go:7-40`）。当前可确认的是「文本回复以 A2UI 文本组件承载」这一条通道。

## 已归并到现有类目的能力

- **Wails 桌面壳**：`src/main.go` 在窗口创建前启动内嵌 Gateway，等待 127.0.0.1:18900 健康后加载引导页；关闭窗口时关停服务（`src/main.go:48-130`、`src/pkg/desktop/gateway.go:20-110`）。这是应用交付形态，不是运维工作流。
- **单实例与安装引导**：启动时结束其他 OpenOcta 进程，macOS 首次从 DMG 启动会提示安装到应用程序目录（`src/main.go:58-62`）。
- **应用内更新**：`appupdate` 负责下载、校验与重启，桌面壳把退出回调注入 Gateway（`src/main.go:90-95`）。
- **日志导出**：属于运维排障而非对话分享，已在对话导出笔记记录。
- **本地模型下载/模型广场**：属于模型运行时资源，不构成媒体或 Agent 工作流。
- **四层记忆的读取注入**：`SOUL/PROMPT/MEMORY/USER` 四个 Markdown 文件在每次运行时被读成快照并拼进系统提示（`src/pkg/agent/evolution/store.go:14-58`、`src/pkg/agent/runtime/runtime.go:168-187`）。写入 API 未被调用，见下节。

## 声明不符、外部依赖与暂缓项

- **L4 Evolution 写入未接线。** `Store.Add/Replace/Remove` 提供带字符预算的增删改，但除测试外没有调用方；运行时只在创建时读取并注入快照，`SnapshotForSession` 也固定传空 session ID（`src/pkg/agent/evolution/store.go:41-44`、`:147-238`、`src/pkg/agent/runtime/runtime.go:180-186`）。README 的「L4 autonomous evolution」在当前快照中只能确认到「读取并注入」。
- **`session_search` 不存在。** 系统提示与知识库文档都要求使用它，但工具注册只有 `memory_search`（`src/pkg/agent/runtime/knowledge.go:41-46`、`docs/knowledge-vault.md:5`）。
- **Exec 审批前端空转。** 审批浮层与事件监听存在，后端 `exec.approval.*` 为未实现桩，也没有事件生产者（见能力卡 2）。
- **Skill 数量声明。** README 的「766+ Skills」依赖安装包与官网市场；本仓库没有附带任何 `SKILL.md`，`src/bundled` 为空目录，因此无法用仓库快照核对数量。
- **数字员工市场。** 条目来自远端服务，安装逻辑与文件格式不在本仓库；离线环境下只能使用自建员工。
- **IM 渠道。** 各渠道实现位于仓库内，但账号登录、二维码、Webhook 回调可达性依赖外部平台；本次未运行验证。

## 对特色贡献统计的影响

| 能力 | 计分 | 理由 |
|---|---|---|
| 无人值守运行（Cron + Alert Hook） | 主贡献 | 独立调度对象、持久化、执行链与结果投递完整 |
| 数字员工 | 主贡献 | 独立模板对象，改变会话装配与资源边界 |
| Knowledge Vault | 主贡献 | 独立文件工作台、索引、检索工具与图谱 |
| Agent Swarm | 主贡献 | 独立房间/成员树、配额、取消与历史 |
| IM 渠道双向 | 主贡献 | 独立渠道运行时与入站映射，形成跨表面闭环 |
| 会话经验提炼 Skill | 主贡献 | 从会话产生可复用文档并接入技能体系 |
| 命令审批 | 辅助 | 后端拦截与队列确认，前端闭环未接通 |
| A2UI | 辅助 | 文本承载与动作回流确认，交互组件链未验证 |
| Wails 桌面壳、更新、日志导出 | 不计 | 基础设施或已归并类目 |

## 未验证事项

- 未运行桌面端或 Gateway，未实际创建定时任务、触发告警、绑定员工、同步知识库或创建蜂群房间。
- 未验证企业微信/微信/钉钉/飞书/QQ 的真实收发、群聊隔离、附件与引用回复行为。
- 未验证数字员工市场下载、技能安装包的解析与技能优先级在运行时的实际合并结果。
- 未验证 Knowledge Vault 的向量检索质量、中文分词效果、大 Vault 的全量重建耗时与图谱规模上限。
- 未验证 Swarm 的并发上限、流式事件顺序、失败成员的级联状态与前端拓扑在大树下的表现。
- 未验证 A2UI 在不同模型输出下的兼容性，以及模型是否可能自发输出可交互组件。
- 未验证审批中断在真实运行中能否被前端恢复；本笔记只确认了后端接口与事件字段。

## 关键源码索引

- 定时任务：`src/pkg/cron/service.go:146-179`、`:272-391`、`:440-496`；`src/pkg/cron/types.go:5-71`；`src/pkg/gateway/handlers/cron.go:102-179`、`:503-546`
- 告警与 Hook：`src/pkg/gateway/http/hooks.go:29-105`、`:284-392`
- 投递：`src/pkg/gateway/handlers/cron_delivery.go:42-199`；`src/pkg/gateway/handlers/chat.go:1072-1103`、`:1165-1239`
- 审批：`src/pkg/agent/runtime/command_policy.go:103-179`；`src/pkg/agent/eino/approval_middleware.go:31-123`；`src/pkg/security/approval.go:66-273`；`src/pkg/gateway/handlers/approvals.go:157-340`
- 数字员工：`src/pkg/employees/model.go:7-46`；`src/pkg/gateway/handlers/employees.go:30-199`；`src/pkg/gateway/handlers/chat.go:1399-1419`、`:2212-2219`
- 知识库：`src/pkg/agent/eino/knowledge_tools.go:20-55`；`src/pkg/agent/knowledge/engine.go:34-97`；`src/pkg/gateway/handlers/vault.go:558-660`；`src/pkg/agent/runtime/knowledge.go:13-46`
- 蜂群：`src/pkg/swarm/orchestrator.go:52-255`；`src/pkg/swarm/store.go:24-117`；`src/pkg/swarm/limits.go:4-11`；`src/pkg/gateway/handlers/swarm_tools.go:17-133`
- IM 渠道：`src/pkg/channels/runtime.go:44-189`；`src/pkg/gateway/http/inbound_sink.go:32-94`；`src/pkg/gateway/handlers/chat.go:805-846`
- 技能：`src/pkg/agent/skills/loader.go:89-177`；`src/pkg/gateway/handlers/chat_extract_skill.go:18-258`；`src/pkg/gateway/handlers/skill_compose.go:191-256`；`docs/skills.md:17-31`
- A2UI：`src/pkg/a2ui/stream.go:26-72`；`src/pkg/gateway/handlers/chat.go:2679-2690`、`:3622-3675`；`ui/src/ui/chat/a2ui-bridge.ts:50-93`
- 桌面壳：`src/main.go:48-130`；`src/pkg/desktop/gateway.go:20-110`
