# OpenClaw Agent 角色配置调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：静态阅读 Agent 配置 schema、配置解析、路由与 session key、workspace/bootstrap、system prompt、工具/Skill/memory/subagent、ACP、Gateway RPC 和 Control UI 源码，并沿入口追踪状态、持久化和可见字段
>
> 调查范围：普通 Agent 的角色数据模型、workspace 角色文件、创建与路由绑定、提示词和模型生效链、工具/Skill/memory/子 Agent 授权、资产与用户档案、迁移兼容、ACP/Claw 边界、Gateway 与 Control UI 可见性；排除最终上下文历史拼装、单个工具执行、聊天界面内的快速切换交互和各 Provider Adapter 的完整协议细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- OpenClaw 的 Agent 角色由 `agents.entries.<agentId>` 配置条目和该 Agent 的 workspace 文件共同定义：配置条目承担身份元数据、目录、模型、能力策略和运行时选择，workspace 文件承担可编辑的规则、人格、用户偏好、引导和记忆上下文。canonical workspace 文件共六个，分别是 AGENTS.md、SOUL.md、USER.md、IDENTITY.md、BOOTSTRAP.md 和 MEMORY.md。字段定义见 `src/config/types.agents.ts`，文件集合见 `src/agents/workspace.ts`。
- 普通用户 Agent 由人工编写的 roster（authored roster）管理；Gateway 另外按 client capability 投影出一组独立的 system-agent 行，这些 system agent 只存在于投影结果里，不在 `agents.entries` 中。分层投影的实现见 `src/gateway/agent-list.ts`。
- Agent 的唯一稳定标识是配置 roster 里的 agent ID。`AgentConfig` 没有通用的角色版本字段，schema 只规定 ID 以字母数字开头并限制长度。createdVia、createdAt 这类来源信息由 Gateway 列表和 provenance 投影产生，记录的是创建来源，不带版本号语义。相关 schema 见 `src/config/zod-schema.agents.ts` 和 `packages/gateway-protocol/src/schema/agents-models-skills.ts`。
- 一次实际运行的角色由多层事实共同决定：配置文件加载和迁移、显式 `agentId` 或渠道 binding、带 Agent 命名空间的 session key、Agent workspace/state 目录、bootstrap 文件、Skill 和工具策略、session 覆盖、实际 provider/model/runtime，以及请求级 prompt 参数。主链路可概括为“配置加载 -> Agent 所有者解析 -> 路由/session key -> 目录与能力解析 -> bootstrap/prompt -> provider/runtime -> session 报告和 UI 投影”。
- 配置里的 identity 字段和 workspace 的 `IDENTITY.md` 是两个独立来源。配置一侧适合保存结构化的 name、theme、emoji 和 avatar；workspace 文件另外可以包含 creature、vibe 这类供人编辑的字段。Control UI 展示时先取 Agent 配置 identity，缺失部分由 workspace identity 补齐，最后落到默认 Assistant；本次没有在规范 system prompt renderer 中找到把配置 identity 自动展开成完整人格提示的独立步骤。两侧的合并与解析见 `src/agents/identity-file.ts` 和 `src/gateway/assistant-identity.ts`。
- 角色提示词由三类输入拼成：源码里固定的安全、工具和运行时指导，Agent workspace 中按上限读取的上下文文件，以及本次运行的 channel、session、owner、时间、模型和额外提示。上下文文件在 prompt 里各有分工：`SOUL.md` 标记为 persona/tone，`USER.md` 标记为用户偏好和 profile directives，`AGENTS.md` 的 Tools 段只讲使用方式，不授予工具。渲染顺序和缓存边界由 `src/agents/system-prompt.ts` 控制。
- 模型选择支持 Agent 级 primary/fallback，取值可以是单个字符串，也可以是 `{ primary, fallbacks }` 对象。Agent 的 primary 优先于 defaults 的 primary，之后别名、已配置 Provider、裸模型名的唯一 Provider 推断和默认 Provider/model 依次参与解析。会话还会持久化显式或自动 fallback 覆盖，配置里的默认模型和当前 session 上一次实际运行的模型因此是两条不同的事实。解析入口见 `src/agents/model-selection-shared.ts`，session 运行时字段见 `src/config/sessions/types.ts`。
- 工具的可用集合由固定目录经过多层策略过滤得出，参与过滤的层次包括 profile、全局、Provider、Agent、群组、发送者和 sandbox、subagent、runtime 与 inherited policy，角色提示文字只负责说明用法；进入运行时和 prompt 的是过滤后的有效列表。Skill 走类似的 Agent/default/session 三层过滤，区别在于 Agent 显式写出的 `skills` 会替换默认列表，session overlay 再对单个 Skill 做启用或禁用。相关实现见 `src/agents/conversation-tool-policy-pipeline.ts` 与 `src/skills/discovery/agent-filter.ts`。
- 普通 Agent 的 session 通过 `agent:<agentId>:...` 形式的 key 和 Agent 所属 store 建立绑定，每条消息不复制完整角色配置。SessionEntry 保存的是运行时事实：实际 provider/model、runtime/harness、session 覆盖、Skill snapshot、system prompt report 和 ACP metadata；其中 system prompt report 只记大小、hash、注入统计和工具/Skill 统计，完整原始角色快照留在配置侧。投影实现见 `src/config/sessions/session-accessor.sqlite-session-row.ts`、`src/config/sessions/session-prompt-types.ts` 与 `src/config/sessions/session-system-prompt-report.ts`。
- ACP 是外部 harness 的独立运行时边界。配置同时区分两个 ID：负责 OpenClaw session 与存储的 `agentId`，和指向外部 harness 的 `acpAgentId`。session key 呈 ACP 形状还不足以证明该 session 跑在 ACP 里，需要持久化的 ACP metadata 与 runtime 标识。普通 Agent 的 `subagents.allowAgents` 和本地 subagent tool policy 属于本机委派授权，与 ACP harness ID 分属两套机制。
- 本次在普通 Agent 的 CLI 和 Gateway 配置入口中没有找到通用的 Agent clone/import/export 命令，也没有找到 `src/claws/` 目录。与 Claw 相关的只剩渠道安装入口（`src/commands/channels/add.ts` 及其 add-wizard）和 Claw 包生命周期租约（`src/state/claw-package-lifecycle-lease.ts` 及配套 key 模块）；portable Agent/profile/workspace 导出的实现模块同样未找到，渠道安装入口不能当作普通 Agent 的角色分享格式。

## 系统边界与总体调用链

### 配置到运行时

1. 配置加载器读取 JSON5 配置，处理 include、环境变量和 dotenv 影响，然后执行 legacy 迁移、schema 校验和 runtime materialization。配置不存在时也会经过同一套 runtime defaults，避免首次运行和空配置的默认行为分叉；主入口见 `src/config/io.load.ts`。
2. Agent roster 的 canonical 来源是 `agents.entries`，每个 key 就是 Agent ID，runtime 另外生成一份供旧调用方使用的 list projection。多 Agent 配置缺少明确 ownership 或 legacy default marker 时，加载方必须显式指定所有者；选择和兼容逻辑见 `src/agents/agent-scope-config.ts`。
3. 请求可以直接带 `agentId`，也可以由渠道 binding、session key 或事先准备的 fallback owner 推出 Agent。显式 Agent 与 `agent:<id>:...` 形式的 session key 不一致时，session resolution 直接拒绝，不会静默回落到默认 Agent；见 `src/agents/agent-scope.ts`。
4. 路由 binding 按 channel、account、peer、guild、team 和 role 条件匹配 Agent，同时算出普通会话 key、main session key 与 last-route policy。它产出的只是路由所有权和 session 命名空间，Agent 配置在运行时另行解析；见 `src/routing/resolve-route.ts`。
5. Agent scope 负责把 Agent 解析到具体的 workspace 和 agent 目录。workspace 先看显式设置；兼容默认 Agent 可以继承 `agents.defaults.workspace` 或默认 workspace，其余 Agent 在默认 workspace 下派生 `<workspace>/<agentId>`，没有默认 workspace 时落到 state 下的 `workspace-<agentId>`。agentDir 同样先看显式值，缺省时用 state 下的 `agents/<agentId>/agent`；见 `src/agents/agent-scope-config.ts`。
6. 运行准备阶段按 Agent 和 session 解析 bootstrap context、Skill、memory、工具策略、sandbox、channel 能力和模型事实。bootstrap 文件会被每文件和总量上限截断，之后才交给 system prompt renderer；见 `src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts` 与 `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`。
7. embedded runner 先建立 OpenClaw base system prompt，再按非 raw run 条件交给 Provider-specific transform；raw model run 保留 base prompt 供诊断，但提交给 Provider 的 prompt 为空。这个边界由 `src/agents/embedded-agent-runner/run/attempt-system-prompt.ts` 明确。
8. 运行结束或中途更新时，session entry 记录实际 runtime model、provider、harness、覆盖、Skill snapshot、prompt report 和 ACP metadata；Gateway/Control UI 读取这些投影展示配置值与部分“当前生效”值。

### 角色与相邻对象

| 对象 | 所有者 | 在本调查中的作用 | 职责边界 |
|---|---|---|---|
| `agents.entries.<id>` | `openclaw.json` 及配置迁移 | Agent ID、结构化 identity、workspace、model、tools、skills、sandbox、subagents 等配置 | 配置来源，运行时值另由 session entry 记录 |
| workspace bootstrap 文件 | Agent workspace | 规则、人格、用户偏好、引导、记忆和项目上下文 | 人类编辑的 prompt 上下文，与配置 schema 分开 |
| session key | 路由和 session store | 将一次对话/子 Agent/ACP session 放入 Agent 命名空间 | 只表达归属与命名空间，角色内容另存 |
| SessionEntry | Agent-scoped session store | 保存当前 session 的运行时事实、覆盖和部分 snapshot/report | 运行时事实与局部覆盖，角色定义留在配置侧 |
| ACP metadata | shared state DB 的 ACP 表及 session 关联 | 证明外部 harness、backend、mode、runtime options 和生命周期 | 外部 harness 运行时边界，与普通 subagent policy 分开 |
| Claw manifest | Claw 包安装/导出流程 | 经过审查的可安装资产、workspace 文件和部分 Agent settings | 包资产与 provenance 的安装导出边界，与普通 Agent 导入导出分开 |

## 1. 角色数据模型与存储

### 配置实体

`AgentConfig` 是一个由 Agent ID 加配置主体组成的 roster entry。canonical `agents.entries` 的 key 承担 ID，runtime projection 才会把它重新表示为带 `id` 的对象。当前字段可以按以下职责理解：

| 组别 | 主要字段 | 作用 |
|---|---|---|
| 标识和目录 | `name`、`description`、`workspace`、`agentDir` | 运营展示、工作区和 Agent-scoped 状态位置 |
| 结构化身份 | `identity.name`、`theme`、`emoji`、`avatar` | UI、消息前缀、头像和渠道身份解析 |
| 模型和运行时 | `model`、`models`、`modelPolicy`、`utilityModel`、`runtime`、`agentRuntime`、`params` | primary/fallback、模型元数据、覆盖许可、Provider 参数和 embedded/ACP runtime 选择 |
| 回复和上下文默认 | `thinkingDefault`、`verboseDefault`、`reasoningDefault`、`fastModeDefault`、`contextInjection`、bootstrap limits、`contextLimits` | Agent 默认的思考、可见性、推理和 workspace context 行为 |
| 能力和隔离 | `skills`、`skillsLimits`、`memory.search`、`tools`、`sandbox` | Skill、memory、工具 policy、workspace access 和 sandbox 约束 |
| 交互和生命周期 | `heartbeat`、`groupChat`、`humanDelay`、`typingMode`、`tts` | heartbeat、群聊、延迟、输入反馈和语音相关行为 |
| 委派 | `subagents.delegationMode`、`allowAgents`、`model`、`thinking`、`requireAgentId` | 子 Agent 的目标、模型、提示词倾向和选择约束 |

字段定义和 deprecated/compat 标记见 `src/config/types.agents.ts`。`agents.defaults` 提供共享默认值，合流按字段分组进行：`resolveAgentConfig` 只合并 verbose、fast mode、输入模式与 context 限制等少数默认字段，模型、Skill、工具和 workspace 另由各自的 resolver 处理，没有统一深合并全部字段的 merge 函数；见 `src/agents/agent-scope-config.ts`。

Agent ID 使用 schema 约束的 `[a-z0-9_][a-z0-9_-]{0,63}` 形式。schema 仍保留一个 `default=true` 兼容 marker，并限制最多一个；`agents.ownership=explicit` 不能与 legacy marker 共存，多 Agent roster 没有 marker 时需要 explicit ownership。类型层已将这个 marker 标记为 deprecated，schema 和 runtime 的兼容路径见 `src/config/zod-schema.agents.ts`、`src/agents/agent-scope-config.ts`。

### Workspace 与 Agent state

- 默认 workspace 从环境变量逐级推导：先取 `OPENCLAW_WORKSPACE_DIR`，其次 `OPENCLAW_STATE_DIR`，再结合 `OPENCLAW_PROFILE` 和 home 目录算出位置，默认安装点是 `<home>/.openclaw/workspace`。解析逻辑见 `src/agents/workspace-default.ts:13-31`。
- 非默认 Agent 缺少显式 workspace 时，存在 defaults workspace 就派生 `<defaults.workspace>/<agentId>`，否则用 state 目录下的 `workspace-<agentId>`。显式路径先经过用户路径解析，并做 null byte 清理；见 `src/agents/agent-scope-config.ts`。
- Agent state 的默认数据库落在 state 目录的 `agents/<agentId>/agent/openclaw-agent.sqlite`。Agent-scoped runtime state、memory store 和部分 auth/session 边界按 Agent ID 隔离，路径 helper 见 `src/state/openclaw-agent-db.paths.ts`。
- Agent session/transcript 目录是 `<state-dir>/agents/<agentId>/sessions`，由 `src/config/sessions/paths.ts` 解析。session accessor 和 SQLite logical-node projection 负责把 session entry 与 transcript/store 生命周期连接起来。
- shared state DB 仍承载全局注册和 ACP metadata 等共享事实；当前 ACP metadata 以 `acp_sessions` 表保存，key 由 Agent ID 和 store session key 共同组成，见 `src/acp/runtime/session-meta-keys.ts`。
- Agent auth profile 属于凭证层，与角色字段分开存放。Agent directory 可以拥有 Agent-local credential store，默认 Agent 或迁移状态下还存在继承/共享 auth store 的兼容边界；创建第二个 Agent 时 CLI 只在用户确认后复制可移植 profile，OAuth 通常要求单独登录。相关创建路径见 `src/commands/agents.commands.add.ts`，敏感值不应进入角色导出或调查记录。

### Workspace 角色文件

当前 canonical workspace 文件名集合及缺失语义如下：

| 文件 | 角色含义 | 缺失时 |
|---|---|---|
| `AGENTS.md` | 项目/工作区操作规则和协作约束 | 通常是 required bootstrap 文件 |
| `SOUL.md` | persona/tone | 可选 |
| `IDENTITY.md` | Agent 的人类可编辑身份记录 | 可选；结构化字段也可来自 config |
| `USER.md` | 用户偏好和 profile directives | 可选 |
| `BOOTSTRAP.md` | 初次初始化仪式和首轮行为 | 完成初始化后 canonical 根文件会被隐藏或移除 |
| `MEMORY.md` | durable non-profile facts and decisions | 可选，写入 memory 后出现 |

集合由 `src/agents/workspace.ts` 定义，Control UI 的 core file 列表由同一集合派生，避免 UI 继续展示已退休文件，见 `src/gateway/server-methods/agents.ts`。workspace 文件由边界安全的 pinned open/read 读取，并按文件 identity 缓存；这使同一文件的替换不会被旧内容静默覆盖，读取实现见 `src/agents/workspace.ts`。

### 创建、更新和删除对存储的影响

- `createAgent` 先校验 ID、算出 workspace 和 agentDir，在配置 mutation lock 内写入 roster，再确保 workspace 与 session 目录存在。workspace 仍处于 bootstrap pending 时，创建流程不会立刻把结构化 identity 写进 `IDENTITY.md`，要等 bootstrap 完成后才写入，以免初始化模板覆盖首轮仪式。见 `src/agents/agent-create.ts`。
- Agent 更新可以同时改动 name、workspace、model 和结构化 identity。Gateway handler 在配置提交前初始化新 workspace，再把 identity 合并进目标 workspace 的 `IDENTITY.md`；workspace 迁移时它还会尝试从旧 workspace 保留原有 identity 内容。见 `src/gateway/server-methods/agents.ts`。
- 删除普通 Agent 时，配置 mutation 先移除指向它的 route binding、Agent-to-Agent allow、subagent allowAgents、相关 owner refs 和兼容引用，再按 deletion journal、database ownership、session purge 和安全 trash 流程清理 workspace、agentDir、sessions 与数据库文件。删除 sole Agent、共享 auth store owner 或 inherited auth owner 会被拒绝。配置裁剪见 `src/commands/agents.config.ts`，Gateway 删除入口见 `src/gateway/server-methods/agents.ts`。

## 2. 创建、选择与会话绑定

### 创建入口

普通 Agent 当前有三类主要入口：

- CLI 的 `openclaw agents add` 支持交互向导和 non-interactive 模式。自动化模式必须提供 workspace 和 name，之后可选 model、agentDir 和 binding，再进入 workspace 初始化与 auth profile 处理。入口见 `src/commands/agents.commands.add.ts`。
- Gateway 的 `agents.create` 对外只暴露 name、workspace、model、emoji、avatar 五个参数，内部委托同一个 `createAgent`，协议创建入口因此拿不到完整 AgentConfig。schema 见 `packages/gateway-protocol/src/schema/agents-models-skills.ts`，handler 见 `src/gateway/server-methods/agents.ts`。
- Control UI 的 Agents 页面在本地 config form 里编辑模型、fallback、tools、skills 等允许的配置片段，结构化 identity 走 `agents.update` 写入。页面能看到的可编辑字段取决于 panel、Gateway capability 和当前 config shape，它覆盖的只是 AgentConfig 的一部分字段。

Agent identity 还可以通过 `openclaw agents set-identity` 设置。它可以从 flags 读取 name、emoji、theme、avatar，也可以从指定 workspace 或 `IDENTITY.md` 读取，再把稳定字段写回 config；见 `src/commands/agents.commands.identity.ts`。

### 默认 Agent 与显式选择

默认选择存在兼容层，而不是单一的固定 `main` 常量：

- 没有 authored roster 时，部分旧调用方仍按 implicit `main` 兼容。
- 只有一个 Agent 时可作为 sole Agent，不需要用户选择。
- legacy `default=true` marker 仍可作为兼容 owner。
- 多 Agent 且没有兼容 owner 时，Gateway list 会返回 `selectionRequired=true`，需要请求、binding 或 ambient service 明确指定 Agent。
- `agents.defaults.systemAgent.agentId` 是 ambient system work 的显式 owner，优先于被剥离的 legacy marker。

解析函数区分 sole、legacy、explicit 三类 ownership。Gateway list 的公开投影给出 `defaultId`、`ownership`、`selectionRequired` 以及 main key 和 session scope 五个字段，实现见 `src/gateway/agent-list.ts`，协议 schema 见 `packages/gateway-protocol/src/schema/agents-models-skills.ts`。

### Route binding 与 session key

`bindings[]` 中缺少 `type` 的记录按普通 route binding 处理；`type: "acp"` 才是 ACP binding。普通 route 可以按以下上下文匹配：

- channel 和 account；
- direct/group/channel peer；
- Discord guild、team 和 member roles；
- 可选 DM/group session scope；
- thread 的 parent peer 继承。

类型和 schema 见 `src/config/types.agents.ts` 与 `src/config/zod-schema.agents.ts`。路由解析结果同时包含 `agentId`、`sessionKey`、main session key 以及 last-route policy 和 matched-by 说明，见 `src/routing/resolve-route.ts`。

session key 以 Agent ID 作为第一层命名空间。常见形状包括：

| 场景 | key 形状或规则 | 作用 |
|---|---|---|
| main/shared session | `agent:<id>:<mainKey>` | 直接会话在 main scope 下折叠 |
| per-peer DM | `agent:<id>:direct:<peer>` | 按跨渠道 identity link 或 peer 隔离 |
| per-channel DM | `agent:<id>:<channel>:direct:<peer>` | 按 channel 和 peer 隔离 |
| per-account DM | `agent:<id>:<channel>:<account>:direct:<peer>` | 多账号分别保存 |
| group/channel | `agent:<id>:<channel>:<kind>:<peer>` | 群组或频道对话隔离 |
| thread | 在 base key 后追加 `:thread:<threadId>` | thread session 与 parent 关联 |

构造逻辑见 `src/routing/session-key.ts` 和 `src/routing/session-key.ts`。session key 包含 Agent ID 时，显式请求 Agent 必须与其一致；没有 Agent-scoped key 的 legacy/unscoped key 则需要由 configured default、persisted store owner 或明确 fallback owner 解出，见 `src/agents/agent-scope.ts`。

### 原生 subagent 与 ACP binding

原生 `sessions_spawn` 创建新的 Agent-scoped child session，并保存 `spawnedBy`、`completionOwnerSessionKey`、workspace/cwd、spawn depth、subagent role 和 inherited tool policy。Child session 在目标 Agent ID 下重新解析运行时，同时继承明确允许的上下文和策略；它的配置来源是目标 Agent 定义与继承规则。创建与 patch 入口见 `src/agents/subagents/spawn/subagent-spawn.ts` 和 `src/agents/subagents/spawn/subagent-spawn-session-patch.ts`。

ACP configured binding 的持久标识由 channel、account、conversation 和 owning Agent 计算，形成稳定的 `agent:<agentId>:acp:binding:...` key；`agentId` 表示 OpenClaw 所属 Agent，`acpAgentId` 表示外部 harness 里的 Agent。见 `src/acp/persistent-bindings.types.ts` 与 `src/acp/persistent-bindings.types.ts`。

ACP lifecycle 会检查已有 metadata 的 external agent、mode、backend 和 cwd 是否仍与 binding 相符；model drift 可以原地 patch，结构不匹配则关闭并重新初始化 session。见 `src/acp/persistent-bindings.lifecycle.ts` 与 `src/acp/persistent-bindings.lifecycle.ts`。

## 3. 提示词字段、优先级与输出契约

### 角色字段与提示词来源的区分

OpenClaw 没有把所有“角色内容”放在一个 `systemPrompt` 字段里。当前能追到的来源分工如下：

| 来源 | 进入方式 | 主要语义 |
|---|---|---|
| Agent `identity` | 结构化 resolver、UI identity、消息前缀和 avatar | name/theme/emoji/avatar 等身份元数据 |
| `AGENTS.md` | workspace bootstrap context | 操作规则、项目规则；Tools 段不能授予工具 |
| `SOUL.md` | Project Context | persona/tone |
| `USER.md` | Project Context 或受 memory provenance 过滤 | 用户偏好和 profile directives |
| `IDENTITY.md` | workspace context 和 UI identity fallback | 人类编辑的身份记录 |
| `BOOTSTRAP.md` | pending bootstrap 的特殊 context | 初次 setup 仪式和首轮回复约束 |
| `MEMORY.md` | Project Context 或 memory provenance 过滤 | durable facts/decisions，非用户 profile |
| `agents.defaults.*` | config-aware prompt builder 和各能力 resolver | 默认模型、owner、TTS、delegation、memory citations、FS policy 等 |
| session/request fields | run preparation | model、prompt mode、channel、时间、额外提示和局部覆盖 |
| Provider contribution | provider runtime hook | stable prefix、dynamic suffix 和可替换 section |

`buildProjectContextSection` 会把 `SOUL.md`、`MEMORY.md`、`USER.md` 的语义写入提示词，并在每个文件前加独立标题；具体实现见 `src/agents/system-prompt.ts`。这意味着 workspace 文件的自然语言内容会进入 prompt，但它们仍然不是 config schema 中的结构化字段。

### Bootstrap 注入策略

Agent 可以用 `contextInjection` 控制 bootstrap 文件的注入：

| 模式 | 行为 |
|---|---|
| `always` | 每个适用 turn 重新准备 workspace bootstrap context，默认值 |
| `continuation-skip` | 检查当前活动 transcript 是否已有完整 bootstrap 完成 marker；安全 continuation 可以跳过重复注入 |
| `never` | 不注入 workspace bootstrap context |

默认值和 per-agent override 见 `src/agents/bootstrap-files.ts`。`continuation-skip` 会扫描活动 SQLite transcript branch；遇到 compaction/reset 会认为旧 marker 不可复用，见 `src/agents/bootstrap-files.ts`。

Bootstrap 还有运行场景路由：

- primary interactive run 可以接收 full bootstrap；
- subagent 和 ACP worker 不重复接收 top-level bootstrap，而是走自己的 context 路径；
- lightweight heartbeat/cron context 可以保持 bootstrap 文件为空；
- pending `BOOTSTRAP.md` 的 full mode 要求首个可见回复遵循文件内容，不能先发普通 greeting；
- 当执行 workspace 与 Agent bootstrap workspace 不同，runner 会把 Agent bootstrap 与 execution project 的 `AGENTS.md` 分层处理。

这些条件由 `src/agents/bootstrap-routing.ts` 与 `src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts` 连接起来。每文件和总量限制由 Agent defaults 提供，类型注释给出的默认值为每文件 20000 chars、总计 150000 chars，见 `src/config/types.agent-defaults.ts`。

### Canonical prompt 的大致顺序

规范 renderer 把稳定前缀和每轮变化的 suffix 分开。当前源码中可观察到的主要顺序是：

1. 基础 “personal assistant running inside OpenClaw” 身份行。
2. 工具目录、Deferred Tool Schemas、工具工作流指导和已注册 native command guidance。
3. delegation/subagent/ACP guidance，以及 Provider 可覆盖的 interaction style、tool call style、execution bias。
4. promised work、安全规则、OpenClaw control、Skill 读取指导、Skill workshop 和 memory prompt。
5. model aliases、workspace 路径、FS workspace-only 指导、docs、sandbox 状态。
6. bootstrap pending guidance、`Workspace Files (injected)` 说明、assistant output directives、可选 reasoning format。
7. stable Project Context，随后是 silent reply 规则和 cache boundary。
8. volatile temporal context、dynamic Project Context、审批 UI、authorized senders、Webchat canvas、messaging/channel guidance。
9. 本次运行的 `extraSystemPrompt`、reaction guidance、Provider dynamic suffix、watched sessions。
10. Runtime 行，包含 Agent/session/model/provider 相关事实和 reasoning 状态。

稳定部分与 volatile 部分的实际拼接在 `src/agents/system-prompt.ts` 中完成。context provider 提供这些文件时，Prompt renderer 按 basename 排序，顺序为 AGENTS.md、SOUL.md、IDENTITY.md、USER.md、TOOLS.md、BOOTSTRAP.md、MEMORY.md；某个文件是否真的出现，仍取决于 workspace loader、过滤和 bootstrap routing，排序表同样在该文件里。

### 生效优先级

这里不存在覆盖所有字段的一条数字优先级链，而是多个 owner-specific resolver 组合：

- Agent 显式 workspace 优先于 defaults workspace，没有显式设置时再按默认 Agent 或派生 workspace 的规则计算。
- Agent 显式 Skill filter 优先于 defaults Skill filter，显式空列表也算显式设置；session sparse overlay 最后对单个 Skill 决定启用还是禁用，见 `src/skills/discovery/agent-filter.ts`。
- 模型 primary 先取 Agent entry，其次 `agents.defaults.model`；模型选择、session override、request override 和自动 fallback 在运行时还会继续改变当前选择，单看 Agent list 的 model 字段读不到最终结果。
- 配置里的工具 policy 与全局、profile、Provider、群组、发送者、sandbox、subagent、runtime 和 inherited policy 逐层收敛，靠后执行的是 deny/allow 判定，prompt 里写一句话绕不过去，见 `src/agents/conversation-tool-policy-pipeline.ts`。
- `buildConfiguredAgentSystemPrompt` 先解析 config-derived prompt fields，再展开成 renderer 参数；owner display、delegation、TTS、model aliases、memory citations 和 FS policy 这些同名项最终以 config resolver 的值为准，见 `src/agents/system-prompt-config.ts`。
- workspace 文件内容作为 Project Context 注入，prompt 文本要求模型遵循 `SOUL.md`、`USER.md` 等内容，更高优先级指令可以覆盖它。这类内容没有 schema-level allow/deny 语义，改变不了工具的实际可用性。
- Provider 的 prompt contribution 可以替换若干完整 section，并追加 stable prefix 和 dynamic suffix；它属于 Provider runtime hook，作用范围不涉及 Agent identity 字段。
- `extraSystemPrompt` 是本次运行的局部输入，位置在 channel/session guidance 之后、Runtime 行之前。embedded runner 会把调用方的 extra prompt、project memory 写入提示和 model-tools-unavailable 提示合并到一起，见 `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`。

### 输出契约

角色提示词还承担渠道和运行时输出契约，而不只是人格文本：

- 存在 message tool 时，prompt 按 source reply delivery mode 指示模型用 `message(action=send)` 发送，并说明附件、语音和 replyTo 的处理方式；旧 automatic mode 下仍可能使用 `MEDIA:`、`[[reply_to_current]]` 这类过渡 marker。
- `message_tool_only` 会关掉通用的 silent-reply section，要求可见回复一律走 message tool，实现在 `src/agents/system-prompt.ts`。
- 支持 reasoning tag 的 Provider 会收到 `<think>...</think><final>...</final>` 形式的提示；reasoning level 以及是否隐藏由当前运行和 Provider 能力决定。
- 没有可说内容时，full prompt 的 silent reply section 要求整段回复精确使用 silent token，把 token 夹在正常回复里不符合该约定，见 `src/agents/system-prompt.ts`。
- Agent prompt 先拼出 base prompt，再执行 Provider transform，所以 `systemPromptReport` 记录的是 attempt 组装出的那份 prompt，Provider 最终协议可能还有额外转换，见 `src/agents/embedded-agent-runner/run/attempt-system-prompt.ts`。

## 4. 模型、Provider 与生成参数

### Agent 级模型配置

`AgentModelConfig` 支持两种形状：

```text
"provider/model"
{ primary: "provider/model", fallbacks: ["provider/other-model"] }
```

类型定义见 `src/config/types.agents-shared.ts`。Agent entry 和 defaults 都可以保存模型；Agent entry 还可以通过 `models` 保存具体 provider/model 的 alias、Provider 参数、streaming 和 per-model runtime metadata，见 `src/config/types.agent-defaults.ts`。

`resolveConfiguredModelRef` 的静态选择顺序是：

1. 有 agentId 时读取该 Agent entry 的 primary。
2. Agent 没有 primary 时读取 `agents.defaults.model` 的 primary。
3. 对配置 alias、profile-qualified ref、精确 Provider ref 和 manifest normalization 做解析。
4. 裸模型名若能从 Agent/default/provider catalog 唯一推导 Provider，则补上该 Provider。
5. 无法解析时记录 warning，并回退到 configured Provider fallback 或内置 default provider/model。

实现见 `src/agents/model-selection-shared.ts` 与 `src/agents/model-selection-shared.ts`。这说明 Agent 配置里的字符串不一定就是最终提交给 Provider 的完整 ref；alias 和 provider catalog 会改变它的规范表示。

### session 和请求覆盖

SessionEntry 保存以下角色相关的运行时模型事实：

- `providerOverride`、`modelOverride`：当前 session 的选择覆盖；
- `agentRuntimeOverride`：session 级 runtime/harness 覆盖；
- `modelOverrideSource`：区分 user 与 auto fallback；
- `modelOverrideFallbackOriginProvider/model`：自动 fallback 的 primary 来源；
- `modelProvider`、`model`：最近一次实际运行模型；
- `agentHarnessId`、`modelSelectionLocked`：运行时 harness 和锁定语义。

这些字段及其 reset/fallback 语义见 `src/config/sessions/types.ts`。因此：

- UI 或 `/model` 的显式 session 选择可以暂时盖过 Agent 默认；
- Provider rate limit/timeout 等自动 fallback 会留下来源标记，避免被误识别为用户选择；
- Agent 配置更新不会把历史 session 直接重写成一份新的角色快照；新的 turn 会按 session override、配置和运行时策略重新解析；
- `modelSelectionScope` 支持 session、agent、global 三种产品语义，但具体 mutation surface 由调用方选择，不是单纯 Agent entry resolver 的行为。

Gateway 的 `agent` 请求可以直接携带 provider/model 选择、`thinking`、`promptMode` 和投递模式等运行级参数，协议定义见 `packages/gateway-protocol/src/schema/agent.ts`。请求入口把这些参数与 session 和配置事实组合后，才交给 runner。

### thinking、reasoning、streaming 与其他参数

- Agent 和 defaults 可以设置 `thinkingDefault`、`verboseDefault`、`reasoningDefault` 和 `fastModeDefault` 四项默认值；session entry 另外记录思考、推理和 fast mode 的当前生效状态。
- `params` 是任意 key/value 的 Provider 参数容器，Agent entry、defaults 和 per-model metadata 各有对应类型入口。每个 Provider Adapter 的参数 merge 与覆盖顺序本次没有完整追完，因此无法概括成一条全局的温度或输出格式优先级。
- `modelPolicy.allow` 限制 session 和 run override 能用的 model refs，空值或省略按类型注释表示允许任意模型。显式 override 授权与自动 fallback 授权分开处理，见 `src/agents/model-selection-shared.ts`。
- UI 的 Agents overview 明确展示 primary、fallbacks、runtime 和 thinking default，并支持保留 `{ fallbacks }` 而清空 primary；清空 Agent primary 的语义是恢复 defaults inheritance，已写好的 fallback list 不动，见 `ui/src/pages/agents/model-config.ts`。
- 配置化 ACP binding 只发生 model drift 时，会保留现有 channel conversation binding，由 ACP manager 原地更新 runtime model；mode、backend、cwd 或 external agent 改变时才重建 session，见 `src/acp/persistent-bindings.lifecycle.ts`。

### 可见的实际模型事实

运行时 prompt 的 `Runtime` 行包含当前 Agent、session、实际 model、default model、channel、能力和 thinking 等信息；模型身份还单独有 `Current model identity` 行，见 `src/agents/system-prompt.ts` 与 `src/agents/system-prompt.ts`。Session prompt report 也保存 provider/model，Gateway model catalog 和 Agents list 则把可选择/配置模型投影给 UI；这些“当前事实”和“可选择候选”需要分别理解。

## 5. 工具、知识库、记忆与子 Agent

### 工具授权与实际过滤

Agent 工具策略至少涉及以下层次：

| 层 | 典型来源 | 作用 |
|---|---|---|
| profile | global `tools.profile` 或 Agent `tools.profile` | 选择 minimal/coding/messaging/full 等基础集合 |
| global | `tools.allow/alsoAllow/deny` | 进程级工具约束 |
| Provider | `tools.byProvider` | 按 provider/model 进一步限制 |
| Agent | `agents.entries.<id>.tools` | Agent 级 profile、allow/alsoAllow/deny |
| group/sender | 群组和发送者策略 | 按会话来源缩小能力 |
| sandbox | sandbox tools policy | sandbox 场景的最终约束 |
| subagent | `tools.subagents` 与 role deny list | 子 Agent 固有能力边界 |
| runtime | 外部 harness/runtime policy | 当前运行时的可见工具集合 |
| inherited | child session 保存的 allow/deny | 从父 subagent 继承的收敛策略 |

`resolveEffectiveToolPolicy` 负责准备 global/provider/agent policy，`resolveConversationToolPolicies` 和 pipeline 负责统一应用。默认 pipeline 先处理 profile/global/provider/agent/group/sender，再经过 sandbox、subagent、runtime 和 inherited 层；见 `src/agents/agent-tools.policy.ts`、`src/agents/conversation-tool-policy-pipeline.ts`。

最终工具对象先被 policy filter，再用可见 tool names 和 summary 生成 prompt 的 Tooling section。prompt 中的 “The AGENTS.md Tools section guides usage; it never grants availability” 明确了 workspace 规则与授权的边界，见 `src/agents/system-prompt.ts`。

### Skill 授权和 snapshot

- Agent entry 明确拥有 `skills` 属性时，使用该列表，即使它是空列表；省略时才使用 `agents.defaults.skills`。
- session 可以通过稀疏 overlay 对单个 Skill 做显式 enable/disable；enable overlay 可以打开基础 filter 未列出的 Skill，disable overlay 可以关闭基础允许的 Skill。
- Skill prompt 只有在运行时存在可用的技能读取路径时才进入 system prompt：通常是 read、Code Mode 的 exec，或 CLI backend 自带的文件能力；prompt 要求读取完整 `SKILL.md`，而不是把文档窗口当成完整内容。
- Agent entry 可以设置 `skillsLimits.maxSkillsPromptChars`，用于限制 Skill prompt footprint。

解析和 session overlay 见 `src/skills/discovery/agent-filter.ts`；Skill prompt 和运行时 catalog 在 `src/skills/loading/workspace-skill-prompt.ts` 及其调用链中生成。Session snapshot 保存 prompt、content-addressed prompt ref、Skill 名称、filter 和 node eligibility；`resolvedSkills` 仅供当前进程加速，持久化前会被剥离，见 `src/config/sessions/session-prompt-types.ts` 与 `src/config/sessions/store-entry-shape.ts`。

### Memory、USER.md 与知识边界

Memory 配置是顶层 memory 配置与 Agent `memory.search` override 的合流，不是 `USER.md` 的别名。当前可解析的 memory search 事实包括：

- enabled、rememberAcrossConversations、memory/sessions sources；
- embedding provider/model、local/remote fallback；
- extra paths、multimodal、chunking、hybrid ranking 和 cache；
- Agent-scoped SQLite database path。

Agent memory store 默认使用同一 Agent-scoped `openclaw-agent.sqlite` 路径，配置合流和 store path 见 `src/agents/memory-search.ts`。memory prompt 只在 full prompt、对应 context engine 和可用 memory tools 条件满足时准备，见 `src/agents/memory-prompt-prepare.ts`。

自动加载 `USER.md` 和 `MEMORY.md` 前还会做 memory provenance classification；不符合自动注入条件的文件会被排除，避免把不明来源的文件当成自动 memory context，见 `src/agents/bootstrap-files.ts`。

当前调查检查的 Agent schema、bootstrap loader、memory resolver、MCP/runtime 入口中没有找到独立的 `knowledge`、`worldBook` 或“世界书”字段。本次只能记录为“已检查范围内未找到独立 Agent 字段”；workspace 文件、memory extra paths、Skill 和 MCP 可以提供外部知识能力，但它们的生命周期和授权方式不同，不能合称为一个内置知识库字段。

### 原生 subagent

Subagent target policy 的默认语义是 requester 可以 self-spawn。若设置 `allowAgents`，目标必须同时满足 allowlist 和已配置 Agent registry；`*` 只放宽 allowlist，不会允许不存在的 Agent ID，见 `src/agents/subagents/spawn/subagent-target-policy.ts`。

默认 subagent 限制包括：

- depth 0 是 main；低于最大 depth 的 child 是 orchestrator；达到最大 depth 的 child 是 leaf；
- 默认最大 spawn depth 是 1，即 depth-1 child 默认不能继续 spawn；
- leaf 没有 child control scope；
- `agents.defaults.subagents` 和 Agent `subagents` 可以分别设置 delegation mode、allowAgents、model、thinking、requireAgentId、并发数和超时；
- subagent session 会保存 role、control scope、spawn depth、父 session key 和 inherited tool allow/deny。

深度和 role resolver 见 `src/agents/subagents/spawn/subagent-capabilities.ts`、`src/agents/subagents/spawn/subagent-capabilities.ts`。subagent prompt 会明确“assigned task only”、自动回报父 Agent、禁止自行 heartbeat/side quest，并区分可继续 spawn 的 orchestrator 和 leaf，见 `src/agents/subagents/spawn/subagent-system-prompt.ts`。

子 Agent 的工具 policy 还会无条件拒绝 gateway、agents_list、openclaw、session_status、automations、message、sessions_send 等协调或外发工具；leaf 还会拒绝 subagent status/history/spawn 工具，见 `src/agents/agent-tools.policy.ts`。

### ACP harness

ACP prompt guidance 与 native subagent guidance 是分开的。embedded prompt 只有在 ACP runtime 可用且没有 sandbox 阻断时才提示 `sessions_spawn(runtime:"acp")`；sandbox 内会明确 ACP spawn 被阻断，要求使用本地 subagent。相关条件见 `src/agents/system-prompt.ts` 和 `src/agents/system-prompt.ts`。

ACP runtime metadata 的判断不能只看 key 是否包含 `acp`。`applyAcpRuntimeOverlay` 要求 `acpRuntime === true` 且 key 是 ACP session key；注释明确说 bridge session 可能使用 ACP-shaped key 但仍运行配置模型，见 `src/agents/acp-runtime-overlay.ts`。持久化 metadata 包括 backend、external agent、mode、runtime options、cwd、state 和 last error，落库/读取见 `src/acp/runtime/session-meta.ts`。

## 6. 资产、变量、开场白与用户档案

### Identity、avatar 与消息前缀

`IDENTITY.md` parser 识别 name、emoji、theme、creature、vibe、avatar；writer 只稳定更新 name、theme、emoji、avatar 四类字段，并保留不相关 Markdown。模板 placeholder 会被忽略，避免初始化文本被误认成真实 identity，见 `src/agents/identity-file.ts` 与 `src/agents/identity-file.ts`。

Agent identity 的 UI/display precedence 是：

- name：配置 Agent identity -> workspace `IDENTITY.md` -> 默认 `Assistant`；
- avatar：配置 avatar/emoji -> workspace avatar/emoji -> 默认文本 `A`，同时做 URL、data URL、本地路径和文本 avatar 校验；
- emoji：配置 emoji -> workspace emoji，再尝试 avatar 字段作为兼容来源。

实现见 `src/gateway/assistant-identity.ts`。结构化 identity 还影响消息 prefix 和 ack reaction，但 reaction/prefix 另有 channel account、channel、global messages 层级，不能把它们等同于角色人格 prompt；见 `src/agents/identity.ts`。

头像支持受限的 HTTP URL、data URL、workspace 相对路径和短文本四种形式。`IDENTITY.md` 读取有 4 MiB 文件上限，avatar data URL 另受媒体上限约束；解析见 `src/agents/identity-file.ts` 和 `src/gateway/assistant-identity.ts`。Control UI 通过 agents.update 保存 name、emoji 和 avatar，Gateway 同步改写 workspace 的 identity 文件，入口见 `ui/src/lib/agents/index.ts` 和 `src/gateway/server-methods/agents.ts`。

### 开场白、快捷回复和变量

本次检查的 Agent schema、create/update Gateway schema、system prompt config 和 Agents UI 中没有找到独立的“角色开场白”“快捷回复”“示例对话”或“世界书”字段。存在的相近机制需要分开理解：

- pending `BOOTSTRAP.md` 时，prompt 要求首个可见回复遵循 bootstrap 文件，不能发 generic greeting；这是一次性初始化契约，不是普通角色 greeting 字段。
- heartbeat 有自己的 prompt 和首次运行策略；它属于后台调度，不是 Agent 的开场白。
- channel response prefix、message actions 和 native command guidance 属于输出/渠道契约。
- `$ARGUMENTS` 等占位符出现在 bundled command/Skill prompt template 展开路径，不是 Agent 角色变量系统；入口见 `src/skills/discovery/chat-command-invocation.ts`。
- config loader 支持 include 和环境变量/dotenv 解析，Skill 还会声明 requiredEnv/primaryEnv，但本次没有找到“把任意环境变量自动展开到角色 prompt”的通用 Agent 字段。

### Workspace 文件访问与 UI 文件面

Agent 配置页的 `agents.files.*` 是 canonical workspace 文件的受限编辑面：

- `agents.files.list` 返回 Agent workspace 和 core file metadata；workspace setup 完成后可以隐藏 pending `BOOTSTRAP.md`。
- `agents.files.get/set` 只接受 canonical allowlist 中的文件名，不接受任意相对路径。
- `IDENTITY.md` 不作为普通 freeform editor tab 展示，以免第二个编辑器覆盖 identity form 保留的字段；它仍可通过 raw file API 写入。
- 另有 `agents.workspace.list/get` 只读浏览器，可读取 workspace-relative 的目录和文本/图片预览，并对路径、大小、UTF-8 和图片 MIME 做限制。

这些边界见 `src/gateway/server-methods/agents.ts`、`src/gateway/server-methods/agents.ts` 和 `src/gateway/server-methods/agents-workspace.ts`、`src/gateway/server-methods/agents-workspace.ts`。

### `USER.md` 与 durable user profile

workspace `USER.md` 是进入 Agent Project Context 的人类编辑文件，语义是 durable user preferences/profile directives。Gateway 的 durable user profile 是另一套记录：由 shared state DB 的 `user_profiles`、email aliases、GitHub identity 和 avatar 等表/记录组成，有独立的 profile ID、merge head、display name 和 avatar revision，见 `src/state/user-profiles.ts`、`src/state/user-profiles.ts` 和 `src/state/user-profiles.ts`。

因此当前系统同时存在两个“用户档案”来源：Agent workspace 内的 prompt instructions，以及 Gateway authenticated/durable profile。它们的所有者、持久化位置和用途不同；本调查不把二者合并成角色字段。

## 7. 导入、导出、迁移与兼容性

### Config 读取与写入

配置读取流程会保留原始文本、parsed object、include/env resolution facts、migration diagnostics、hash 和 runtime config snapshot；非法配置不会降级成空配置。读取、校验和 materialization 见 `src/config/io.load.ts`。

schema 对 Agent entries、bindings、identity 和大部分 runtime config 使用 strict object。未知字段能否保留取决于具体 schema 和 include/migration owner，不能假定所有未来字段都会被静默透传。涉及已持久化旧结构的修复主要由 `openclaw doctor --fix` 和 legacy migration 负责；runtime 仍有少量 raw SDK compatibility 分支，其作用限于既有 SDK 调用的兼容。

### Roster 与 main 迁移

- legacy implicit `main` 只在没有 authored roster 等兼容场景使用。
- 读取时可以识别 legacy `default=true`，写入 canonical entries 时逐步移除旧 list/default 形状。
- 从 sole Agent 过渡到 explicit multi-agent roster 时，会 pin workspace、auth owner 或 system owner，避免第二个 Agent 出现后旧默认行为漂移。
- 创建或重新创建 `main` 时，如果检测到 legacy main session 可能存在冲突，创建会被 migration gate 阻止并要求先执行 doctor；见 `src/agents/agent-create.ts`。
- 删除 Agent 时同步清除 route、subagent allow、heartbeat/system owner 等引用；如果共享 auth 或 session store 仍由该 Agent 拥有，操作会先拒绝。

这些兼容逻辑分布在 `src/config/legacy.roster.ts`、`src/config/legacy.default-agent-owner.ts`、`src/config/sessions/legacy-main-session-migration.ts`、`src/commands/agents.config.ts` 和 `src/gateway/server-methods/agents.ts`。

### 普通 Agent 的分享边界

本次检查的 `openclaw agents` CLI、Gateway `agents.create/update/delete`、identity/file RPC 和 Agent config mutation 中，没有找到普通 Agent 的通用 clone/import/export 命令，也没有找到一个对外承诺的角色 JSON bundle 格式。结论应限定为“已检查入口未找到”，而不是项目级绝对断言。

### Claw 包的独立导出/安装流程

Claw 是另一条经过 provenance 和 consent 的资产流：

- export 只接受已安装且 complete、workspace 未漂移、托管文件/包/MCP/cron 状态完整的 Claw Agent；
- manifest 中可携带 Agent ID、name、description 和部分 identity；
- Claw OpenClaw profile 可冻结部分 tools、groupChat mention patterns、sandbox、memory.search、heartbeat 和 humanDelay；
- workspace 托管文件作为包内容导出，本地 avatar 可以作为 workspace sidecar；远程 avatar 不会按本地文件方式打包；
- export 会检查 workspace、包、bootstrap、MCP 和 cron drift，避免把未确认状态分享出去；
- add/apply plan 需要 consent plan integrity，并按 workspace、package、MCP、cron、config 和 install provenance 分阶段写入；失败时返回 partial result，不报告为完成。

本次未找到 portable Agent/identity/profile 子集导出与漂移检查模块（原 `src/claws/` 已不存在）；可确认的相邻实现是渠道安装 mutation 契约（`src/commands/channels/add.ts`、`add-wizard.ts`）与 Claw 包生命周期租约（`src/state/claw-package-lifecycle-lease.ts`）。这条流程没有把普通 Agent 的全部 `model`、auth secret 或任意 config unknown fields 自动变成通用角色包。

## 8. 配置界面、输出契约与可见字段

### Gateway 公共 Agent 面

`agents.list` 返回的是面向 operator client 的压缩投影，包含：

- Agent ID、kind、createdVia/creator/createdAt；
- name 和结构化 identity 的 name/theme/emoji/avatar/avatarUrl；
- workspace、workspaceGit；
- primary/fallback model；
- agentRuntime、thinking levels/options/default。

协议 schema 见 `packages/gateway-protocol/src/schema/agents-models-skills.ts`。handler 会为每个 Agent 读取 prepared model catalog，再按 client capability 决定是否包含 system rows，见 `src/gateway/server-methods/agents.ts`。

可变入口的公开字段是刻意收窄的：

| RPC | 可观察/可变内容 |
|---|---|
| `agents.create` | name、workspace、model、emoji、avatar |
| `agents.update` | name、workspace、model（null 清除 Agent override）、emoji、avatar |
| `agent.identity.get` | 当前 Agent/session 的 name、nameSource、avatar source/status/reason、emoji |
| `agents.files.list/get/set` | canonical workspace 文件 metadata/content |
| `agents.workspace.list/get` | workspace-relative 的只读目录和文件预览 |
| `models.list` | 当前 Agent 可见的模型 catalog 和能力 |
| `tools.catalog` | 工具 profile、分组、插件来源和基础描述 |
| `tools.effective` | 当前 session 实际可用工具分组和来源 |

`agent.identity.get` 会先从 session key 或显式 Agent 解析 owner，再用 config/workspace identity 合并，见 `src/gateway/server-methods/agent-identity.ts`。它不会返回完整 AgentConfig，也不会声称返回完整 prompt。

### Control UI Agents 页面

Agents overview 当前能让用户看到或编辑的主要角色维度是：

- identity name、emoji 和 avatar；
- workspace 路径；
- primary model、fallbacks、runtime、thinking default；
- effective skill filter 的摘要；
- tools profile、profile 来源、allow/deny overrides、基础工具计数；
- 当前选定 session 的 live effective tools；
- Agent workspace 文件状态、内容和预览。

Overview 的字段绑定见 `ui/src/pages/agents/panels-overview.tsx`、`ui/src/pages/agents/panels-overview.tsx` 和 `ui/src/pages/agents/panels-overview.tsx`。Tools panel 明确把“配置上允许”与“当前 session live”分开显示；如果当前运行 session 不属于选定 Agent，则不会把另一 Agent 的有效工具误显示为当前值，见 `ui/src/pages/agents/panels-tools-skills.tsx`。

UI 的工具目录来自 Gateway `tools.catalog`，实际运行值来自 `tools.effective`；Skill panel 同时显示配置 filter 和运行时 status。文件能力由 `ui/src/lib/agents/index.ts`、`ui/src/lib/agents/index.ts` 管理，连接更换或 Agent selection 改变时会使旧请求失效，避免旧 Agent 的异步结果覆盖当前页面。

### Session 可见性与历史 snapshot

当前 session/status 面能够确认的角色相关信息包括：

- session key 所属 Agent namespace；
- 最近实际 provider/model 和显式/自动 model override；
- session runtime/harness；
- Skill prompt 的 hash、长度、entries 和 filter snapshot；
- workspace 文件注入状态、原始/注入字符数、截断和 warning；
- system prompt 总长度、project/non-project context 长度和 hash；
- 工具 summary/schema 长度、hash 和 properties count；
- ACP backend、external agent、mode、cwd、runtime options 和状态。

`SessionSystemPromptReport` 是可观察性/预算报告，不是完整角色快照。它明确只保存 system prompt 的 chars/hash、上下文统计、注入文件统计、Skill 统计和工具 schema 统计，见 `src/config/sessions/session-system-prompt-report.ts` 与 `src/agents/system-prompt-report.ts`。Session node projection 会把 runtime-only `resolvedSkills` 去掉，再把 canonical entry JSON 写入 logical node，见 `src/config/sessions/session-accessor.sqlite-session-row.ts`。

本次检查的 SessionEntry、transcript accessor 和 prompt report 中没有找到“每条历史消息保存完整 Agent config 或完整原始 system prompt”的证据。可以确认的是 session 级运行时事实和有限 Skill/prompt report 会保存；完整角色快照和逐消息角色版本语义属于未确认事项。

## 9. 设计取舍与已确认边界

- **配置与文件分层**：结构化 identity、model 和 policy 适合做 schema 校验与 UI 编辑；人格规则、用户偏好和项目规则保留在 workspace 文件，允许人类直接编辑并进入 Project Context。
- **Agent 与 session 分离**：Agent ID 通过 route/session key 参与所有权和隔离；session 只保存实际运行事实和局部覆盖，避免每次配置变化都复制完整角色定义到历史记录。
- **默认 Agent 的安全选择**：sole/legacy/explicit 三种 ownership 让旧单 Agent 配置仍能运行，同时在多 Agent 无明确 owner 时失败并提示选择，减少 ambient work 误落到错误 Agent 的风险。
- **能力以 policy 为准**：prompt 会列出当前可用工具，但 AGENTS/TOOLS 文本不能授予工具；多层 policy 在 runtime 过滤，subagent 和 sandbox 还有独立的收敛层。
- **Bootstrap 的一次性和可复用性**：pending bootstrap 用特殊首轮契约完成初始化；完成 marker、continuation-skip、heartbeat/cron lightweight path 和 per-turn cache 又避免重复注入大文件。
- **稳定 prompt 与动态 prompt 分离**：稳定 workspace/tool/安全部分在 cache boundary 前，时间、owner、channel、session 和 extra prompt 放在后面，使每轮变化不必使整段 stable prefix 失效。
- **可观测性记录统计口径**：prompt report 记录 hash、大小和来源统计，能帮助 UI/status 解释预算和注入；完整 system prompt 与角色字段保留在 workspace 与配置中，session 只保存这份报告。
- **ACP 身份双层建模**：OpenClaw Agent ID、外部 harness Agent ID、ACP backend 和 session metadata 分开保存，防止仅凭 key 形状或本地 subagent policy 错判运行时。
- **安全删除和迁移**：Agent 删除先检查共享 auth、数据库 ownership、session leases 和 deletion journal，再清除 config/workspace/state；legacy roster/session 由 doctor/migration 边界处理，避免 runtime 长期叠加旧格式。
- **普通 Agent 与 Claw 分流**：Claw export/add 面向可审查的包资产和 provenance，具有 drift/consent/install 生命周期；它不是普通 Agent 的隐藏通用导入导出接口。

已确认的实现边界：

- `identity` 配置字段是结构化身份元数据，`SOUL.md` 才是当前可直接追到 system prompt 的 persona/tone 文件来源。
- `USER.md` 是 workspace prompt context，shared state DB 的 user profile 是另一套 durable identity。
- Agent `skills` 显式值替换 defaults，工具 policy 则按多层 pipeline 合流，二者不能用同一条“继承”规则概括。
- SessionEntry 通过 Agent-scoped store 和 session key 与 Agent 关联，当前类型中没有一个用于复制整份 Agent config 的通用 snapshot 字段。
- `agentRuntime`、ACP binding runtime、session `agentHarnessId` 和 model/provider policy 是不同层次；UI 的 runtime label 不应直接当作 provider/model 名称。

## 10. 未验证事项

- 未运行构建、Vitest、Gateway、实际渠道交互或 Control UI；文中运行行为以当前代码快照的静态调用链和类型/注释为依据。
- 普通 Agent 是否存在未读到的独立 clone/import/export surface 未能做项目全量行为验证；已检查的 `agents` CLI/Gateway/Control UI入口未找到通用格式。Claw 的 export/add 已单独记录。
- `agents.defaults.params`、Agent `params`、per-model `models.*.params` 与各 Provider Adapter 的最终请求参数 merge/覆盖顺序没有完整覆盖；温度、输出格式或其他任意 Provider 参数的统一优先级需要在补齐这层顺序后判断。
- 没有在已读 SessionEntry/transcript/report 入口中找到每条历史消息保存完整角色快照的路径，但未对所有 transcript writer、消息 schema 和恢复实现做全量调查，因此只能标为未确认。
- 没有在已检查 Agent schema、bootstrap、memory、Skill、MCP 和 UI 入口中找到独立 knowledge/world book 字段；外部插件或未读的产品 surface 仍可能有自己的知识资产契约。
- Provider-specific system prompt transform 的最终字节、不同 Provider 对 `extraSystemPrompt` 的协议映射和 raw model run 的实际线上表现未做运行验证。
- auth profile 的共享/继承/Agent-local 状态已追到创建和路径边界，但没有把每个 Provider 的 credential selection、模型 alias 和 session override 组合做成完整矩阵。
- UI 的视觉布局、响应式表现、键盘行为、实时连接切换和跨平台文件行为不属于本次静态调查覆盖范围。

## 11. 关键源码索引

### Agent 配置、目录和迁移

- `src/config/types.agents.ts`：AgentConfig、AgentEntryConfig、AgentsConfig 字段。
- `src/config/types.agent-defaults.ts`、`src/config/types.agent-defaults.ts`：context injection、model、workspace、Skill 和 prompt defaults。
- `src/config/zod-schema.agents.ts`：Agent roster、ownership 和 legacy default marker 校验。
- `src/agents/agent-scope-config.ts`：roster、default owner、Agent config resolution。
- `src/agents/agent-scope-config.ts`：workspace 与 agentDir resolution。
- `src/agents/workspace-default.ts:13-31`：默认 workspace 环境变量/profile/home 解析。
- `src/agents/agent-create.ts`：Agent 创建、workspace 初始化、identity 写入和 provenance。
- `src/commands/agents.config.ts`：Agent summary 和 config mutation。
- `src/commands/agents.config.ts`：删除时的 config/reference pruning。

### 路由、session 与持久化

- `src/routing/resolve-route.ts`：route binding 输入、Agent route 结果和 session key 构造。
- `src/routing/session-key.ts`：Agent store key、Agent ID resolution、DM/group session key。
- `src/agents/agent-scope.ts`：session Agent resolution 和 execution contract。
- `src/state/openclaw-agent-db.paths.ts`：Agent-scoped SQLite path。
- `src/config/sessions/paths.ts`：Agent session/transcript directory。
- `src/config/sessions/types.ts`：SessionEntry、model/runtime override、Skill/prompt/ACP metadata。
- `src/config/sessions/store-entry-shape.ts`：canonical session shape 和 runtime-only Skill stripping。
- `src/config/sessions/session-accessor.sqlite-session-row.ts`：session entry 到 logical-node projection。

### Workspace、bootstrap 与 prompt

- `src/agents/workspace.ts`：canonical workspace bootstrap file names 和 expected absence。
- `src/agents/bootstrap-files.ts`、`src/agents/bootstrap-files.ts`：context injection、session filtering、bounded context。
- `src/agents/bootstrap-routing.ts`：primary/subagent/ACP/bootstrap mode routing。
- `src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts`：embedded run 的 bootstrap 准备和 workspace layering。
- `src/agents/system-prompt-config.ts`：config-derived owner/TTS/delegation/alias/memory/FS prompt fields。
- `src/agents/system-prompt.ts`：workspace Project Context rendering。
- `src/agents/system-prompt.ts`：tool/runtime/config input normalization。
- `src/agents/system-prompt.ts`：stable prefix、cache boundary、dynamic suffix 和 runtime prompt。
- `src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`：model/runtime/channel/memory/Provider prompt input preparation。
- `src/agents/embedded-agent-runner/run/attempt-system-prompt.ts`：base prompt 与 Provider transform 边界。

### 模型、工具、Skill、memory 与 subagent

- `src/agents/model-selection-shared.ts`：Agent/default model、alias、Provider inference 和 fallback。
- `src/agents/model-selection-config.ts`：default model 与 subagent configured model selection。
- `src/agents/conversation-tool-policy-pipeline.ts`：canonical tool policy pipeline。
- `src/agents/agent-tools.policy.ts`：global/provider/Agent tool policy preparation。
- `src/skills/discovery/agent-filter.ts`：Agent/default/session Skill filter。
- `src/agents/memory-search.ts`：per-agent memory search config 与 SQLite path。
- `src/agents/memory-prompt-prepare.ts`：memory prompt preparation。
- `src/agents/subagents/spawn/subagent-target-policy.ts`：subagent target allowlist 与 registry intersection。
- `src/agents/subagents/spawn/subagent-capabilities.ts`、`src/agents/subagents/spawn/subagent-capabilities.ts`：depth、role、control scope。
- `src/agents/subagents/spawn/subagent-system-prompt.ts`：child role、completion 和 delegation prompt。
- `src/agents/subagents/spawn/subagent-spawn.ts`：child session、workspace、model、thread 和 prompt spawn flow。

### Identity、ACP、Claw 和界面

- `src/agents/identity-file.ts`、`src/agents/identity-file.ts`：IDENTITY.md parser/writer。
- `src/agents/identity.ts`：Agent identity、message prefix、reaction 和 human delay resolution。
- `src/gateway/assistant-identity.ts`：config/workspace/default identity merge。
- `src/gateway/server-methods/agents.ts`：Agent list/create/update Gateway handlers。
- `src/gateway/server-methods/agents.ts`：canonical Agent file list/get/set handlers。
- `src/gateway/server-methods/agent-identity.ts`：identity RPC。
- `packages/gateway-protocol/src/schema/agents-models-skills.ts`：Agent list/create/update/delete/file protocol schema。
- `packages/gateway-protocol/src/schema/agent.ts`：agent run 和 identity request/result schema。
- `src/acp/persistent-bindings.types.ts`：ACP owning Agent/external harness identity 和 generated key。
- `src/acp/persistent-bindings.lifecycle.ts`：configured ACP session match/reconfigure。
- `src/acp/runtime/session-meta.ts`：ACP metadata persistence/read。
- `src/agents/acp-runtime-overlay.ts`：ACP runtime classification boundary。
- `src/state/claw-package-lifecycle-lease.ts`、`src/state/claw-package-lifecycle-lease-key.ts`：Claw 包生命周期租约；`src/commands/channels/add.ts`、`add-wizard.ts`：渠道安装入口（portable 导出模块本次未找到）。
- `src/commands/channels/add.ts`、`src/commands/channels/add.ts`：Claw consented install mutation。
- `ui/src/pages/agents/panels-overview.tsx`、`ui/src/pages/agents/panels-overview.tsx`：Agent identity/context/model UI。
- `ui/src/pages/agents/panels-tools-skills.tsx`：configured policy 与 live effective tools UI。
- `ui/src/lib/agents/index.ts`：Agent list/files/tools Gateway client capability。
- `src/state/user-profiles.ts`、`src/state/user-profiles.ts`：shared durable user profile。
