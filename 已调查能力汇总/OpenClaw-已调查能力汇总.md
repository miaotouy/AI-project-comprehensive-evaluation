# OpenClaw 已调查能力汇总

> 汇总对象：`https://github.com/openclaw/openclaw`
>
> 汇总更新日期：2026-11-05
>
> 依据：OpenClaw 已完成的 17 份单项目调查笔记：仓库分布、会话与消息管理、对话请求与上下文、Chat UI、消息渲染器、对话导出与分享、LLM渠道管理、Agent角色配置、Agent工具、外部执行体与应用协作、主动Agent与后台任务、检索增强与认知编排、上下文编译与提示词工程、生成式输出与运行时、媒体创作、应用界面基础设施、独特功能（代码快照统一为各笔记记录的 `55a554e78a83af031760ef247e26d5be9e24329d`）
>
> 汇总方法：逐一阅读全部来源笔记；按产品能力主题合并来自多个类目的同一能力，避免按来源目录重复抄写；能力说明保留各笔记的证据状态（主链确认/入口确认/本次未找到/暂缓/未运行等）与限定条件，不在汇总中补做源码调查或升级证据；来源链接为从本目录出发的相对路径
>
> 汇总范围：覆盖上述笔记对 OpenClaw 的已调查能力、关键边界、外部依赖与证据状态。明确遗漏：不做跨项目横向比较、评分或整改建议；汇总通常不新增源码定位；单项目笔记的逐条源码索引、完整状态清单与调用链细节需回读原文
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

OpenClaw 是一个以本机 Gateway 为控制平面的多渠道 AI 助手。Gateway 是中心状态、路由与控制平面；CLI、TUI、浏览器 Control UI、iOS/Android companion app 与消息渠道适配器主要是外部控制表面或设备节点，不各自持有主 Agent 运行时；模型请求可由同机 agent 运行器、受管理 worker environment、配对节点或外部 ACP harness 承担。产品形态与调用面依据见 [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)。

- **调用者与控制表面**：操作者通过 CLI、TUI、Control UI 和移动 companion 应用发起并管理会话。约 20 个支持渠道（入口与文档级确认）把渠道上的消息、thread 或 topic 映射成 Gateway 会话或 ACP 绑定；方向相反时，外部 ACP client 与第三方 Claude Code 子进程也能接入本机会话。
- **仓库结构与规模**：仓库是 pnpm workspace，根入口为 openclaw.mjs。规模上共 43,542 个跟踪文件、38,648 个源码文件和约 1,172 万行源码，TypeScript 约占 91%，Swift 与 Kotlin 服务于 companion 与平台集成。代码按职责分布在五个目录：

  - `src`：Gateway、Agent、会话、工具与 CLI 主链
  - `extensions`：消息渠道、Provider 插件与可选能力
  - `ui`：Control UI
  - `apps`：桌面与移动 companion
  - `packages`：共享 SDK 与协议

  依据见 [仓库分布调查笔记](../仓库分布/OpenClaw-仓库分布调查笔记.md)。
- **Agent 形态**：普通用户 Agent 由配置 roster（`agents.entries.<agentId>`）与一组 workspace 角色文件共同定义，文件包括 AGENTS.md、SOUL.md、IDENTITY.md、USER.md、BOOTSTRAP.md 与 MEMORY.md。每个 agentId 拥有隔离的 SQLite 状态与会话目录，另有 Gateway 投影出的 system agent 行与外部 ACP harness 两类边界形态。依据见 [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md)。
- **重要外部依赖**：模型 Provider 覆盖 OpenAI、Anthropic、Google 与本地 Ollama、llama.cpp、LM Studio；托管模型目录 catalog.openclaw.ai 的源仓库在仓库之外，ClawHub 外部注册表连同其扫描与审核服务，ComfyUI 本地或云端等媒体 Provider，以及消息渠道平台账号、推送服务、iOS/Android 设备本地能力和 ACPX 外部 harness 也都需要单独接入。
- **产品辨识点**：把"谁能接触 Agent、谁能往本机安装会改变 Agent 行为的代码"做成显式、可审计的准入与信任决策，见 [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md) 与本汇总"渠道、设备节点与外部执行体"一节。

本工作区未撰写产品结构与设计基因类笔记，产品演变叙事不展开。

## 会话与消息管理

主链确认（静态代码，未运行 Gateway/UI）。完整依据见 [会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)。

- **数据模型与标识**：会话分两层寻址，逻辑会话用 `sessionKey` 标识，transcript generation 用 `sessionId` 标识，同一逻辑会话可以轮换保留多代 transcript。持久会话默认落在 per-agent SQLite，agent store 也可以改用 PostgreSQL（agent schema 40，transcript 新会话协议 4、最低可读 3）。incognito 会话的状态与 transcript 由内存 actor 持有，关闭会话或进程退出后不再恢复。

  持久存储里，逻辑会话记录以 `session_nodes.entry_json` 为权威来源，`session_windows` 与 `transcript_events` 承载各代 transcript。活动路径、消息序号和全文搜索都是从事件派生、可重建的投影。

  消息本身是带 `parentId` 的父子链/DAG；entry 除普通消息外，还记录 thinking 变化、model 切换、compaction、reset 与分支摘要等控制条目；写入必须经过带 parent 校验、幂等判断与媒体规范化的追加入口。
- **生命周期与版本操作**：会话生命周期覆盖创建、metadata 修改、归档/置顶/未读、列表切换、reset 与删除；删除走 archive-then-delete，先冷归档再回收，重启恢复只接受带 restart tombstone 的 source。版本类操作包括 rewind、fork、分支切换与 checkpoint 分支/恢复，它们都通过轮换 transcript generation 改变活动路径，旧代际通常保留而不做物理删除；带 upstream link 的外部 harness 会话不进本地 branch graph。
- **一致性与幂等**：同一 SQLite store 的写入先进 per-store writer queue 串行执行；事务提交前会重读权威行，并比较 expected identity 与 lifecycleRevision。消息幂等键建有唯一索引，重复请求返回原消息，payload 冲突则显式报错。事件提交与活动路径、FTS 前向更新在同一事务内完成；当新增行不足以安全推断路径时，写入方用持久 dirty watermark 隐藏派生行，再由 reconcile 完整重建，小型重建的阈值约 4,000 行或 4 MiB，超出转后台执行。
- **检索与分页**：会话列表支持 offset 分页、pinned 优先再按更新时间的固定排序，以及按 agent、归档状态和 owner 过滤。聊天历史沿活动路径的逻辑消息序号分页，可用 messageId anchor 定位，也能回退到 reset archive。正文搜索使用 per-agent FTS5，只索引活动路径里 user 与 assistant 的可读文本；索引处于 dirty 状态时返回 indexing，不返回可能过期的旧行。
- **迁移与导入**：transcript 新会话协议为版本 4、最低可读版本 3，agent schema 为版本 40。旧格式迁移与 importSqliteSessionRows 只走 doctor/migration 路径，正常 runtime 写入器会拒绝非 canonical key；迁移与 canonical repair 兼容旧 JSONL、旧 alias 与旧 schema。
- **会话级绑定**：模型与 provider 覆盖、工具策略、worktree/exec 目录、channel/conversation 路由、CLI/ACP harness 元数据都以会话引用或归属关系的形式保存。附件跟随消息内容或 media store 引用建立关联，schema 里没有独立的会话附件表。
- **本次未找到**：面向用户的"就地编辑一条已落盘消息"或"按 message id 删除消息"RPC，精确 event rewrite 只用于受保护的 repair；也未找到通用的 sessions export/import RPC，导出与分享路径见本汇总对应小节。

## 对话请求与上下文

完整主链为静态确认，未运行真实 Provider 与对话场景。依据见 [对话请求与上下文调查笔记](../对话请求与上下文/OpenClaw-对话请求与上下文调查笔记.md)。

- **回合主链**：一次可见对话由 Gateway `chat.send` 收口：请求规范化 → 会话/model/agent 解析 → 准入（dedupe、session work admission、abort owner 注册）→ 附件预检 → ACK → 脱离 RPC 生命周期的 detached dispatch → reply/Agent run → 事件投影与终态回写。ACK 前完成需要同步确认的身份、幂等、路由与取消边界，ACK 后继续运行的 dispatch 仍持有 session admission 与持久化责任。
- **上下文来源**：SQLite transcript 经 SessionManager 恢复与清理；bootstrap、skills、渠道/发送者元数据、memory、项目记忆与工具进入 system prompt 或运行时消息。当前 turn 保留 transcript prompt 与 model prompt 两套文本（bare prompt 持久化，动态元数据经 hidden custom message 或 LLM boundary 投影传递）。历史进入模型前做 sanitize、replay validation、工具调用/结果配对修复与 turn 上限。
- **预算与压缩**：请求前预检（fits / truncate_tool_results_only / compact_only / compact_then_truncate）只写诊断、不直接压缩；实际压缩由 AgentSession 或外层 embedded recovery 在 provider overflow、阈值、超时恢复等条件下执行，经 Context Engine 接口或内置 runtime 重写 transcript；压缩后若无可见终答，终态层可追加"从压缩 transcript 继续"的内部 prompt，但不会把有工具副作用或 replay 不安全的 turn 当普通重放。
- **执行与事件面**：Agent Core 统一模型循环与工具循环；assistant 消息经 SessionManager 写 transcript，嵌入式 subscriber 转成回复 payload 与 `infra/agent-events`，Gateway 再向 Control UI、节点与渠道投影。可见文本走 75 ms pacing 与 suffix/replace 去重；`session.message` 持久行与 `chat` 运行事件、in-flight snapshot 分属不同投影。
- **停止、队列与并发**：`chat.abort` 分层处理 active/queued/deduped run 并保留 partial text 持久化；运行按 session lane 串行、跨 session 在 global lane 容量内并行；运行中新消息按 run-now/enqueue-followup/drop 策略处理，collect mode 可把多条消息合成聚合 prompt。队列 drain 是独立续作，parked turn 重新取得当前 prepared runtime generation。
- **重启恢复**：普通 active run 不因 Gateway 重启继续持有有效内存权限；Control UI 的 restart-safe main turn 用 HMAC fingerprint 提交 durable restart claim，重启后同请求经 fingerprint/run id/expected session adoption，不会重复写入不同的用户 turn。
- **媒体注入边界**：图片经持久化 media facts 与 image slot 进入 provider context，无法 hydate 的附件在 plugin harness 下直接抛错而不是悄悄缺失。

## 模型 Provider 渠道与故障转移

主链确认（静态，未运行构建、CLI 与 Gateway）。依据见 [LLM渠道管理调查笔记](../LLM渠道管理/OpenClaw-LLM渠道管理调查笔记.md)。

- **三层渠道结构**：渠道解析分三层完成。第一层是逻辑 Provider，即 `provider/model` 里的品牌身份；第二层是协议与 Adapter，按 `model.api` 声明的协议族注册具体的流式实现；第三层是模型目录与凭据，存放运行时可以查询和复制的目录项。系统里没有持久化的"渠道实例"对象，"解析到具体渠道"的终点是四样东西：Model 行的 baseUrl、api 与 compat 字段，可用的 auth 方案，stream adapter，以及会话绑定的 LlmRuntime。
- **模型目录**：模型目录由三处来源合并而成，包括 author 提供的 agent `models.json`、provider 插件生成的目录，以及运行时通过 `registerProvider` 动态注入的条目；插件目录落在 agent SQLite 的 `cache_entries` 表，scope 为 `plugin-model-catalog-v1`。托管目录默认请求 `https://catalog.openclaw.ai/models/v1/catalog.json`，TTL 为 6 小时，源仓库不在本仓库内，可对上述来源做增量覆盖。`models.mode` 的 merge 与 replace 只影响配置层，目录层始终是各来源之和。
- **凭据解析**：所有来源最终归一到同一个 `ResolvedRequestAuth(apiKey + headers)` 结构。解析按下列顺序逐级尝试：

  1. 显式 pin 的 auth profile
  2. `auth.order` 里配置的顺序
  3. aws-sdk
  4. env-first 环境变量
  5. provider 内联 key（env/exec/SecretRef 解析）
  6. auth store 按顺序逐个 profile（api_key/token/oauth）

  `models.json` 中持久化的只是来源 marker，明文不落盘；OAuth 属于可刷新的运行时状态，不接受 SecretRef。
- **故障转移四层**：故障转移按四层递进处理：

  - 同 key 瞬时重试
  - 限流时在 env 的多个 key 之间轮换
  - auth profile 轮换：各 profile 独立维护 cooldown 与 disabled 状态，轮换为 round-robin，会话保持 stickiness
  - 模型级 fallback 链

  user pin 属于严格选择，不落入 fallback；configured 与 cron 的主选可以回退；只有全链错误都属于超载类时，才整链最多重试 10 次。fallback 是 turn-local 的，不写回成下一轮的选择。
- **连接检测与可观测**：CLI 的 `models status`、`models list --probe` 与 Control UI 的 "Test connection" 按钮共用同一个 auth-probe 引擎，探测会发出一次真实的最小模型请求，返回状态桶和稳定的 reasonCode。usage 与 cost 随每条 assistant 消息归一化落账。
- **管理入口（入口确认）**：模型 Provider 的管理入口有三处，分别是配置文件、CLI 的 `models` 命令族和 Control UI 的 Settings→Model Providers。复制 provider、导入导出 provider 配置、桌面端独立 provider CRUD 这三项在已读入口中未找到。

## Agent 角色与工具

主链确认（静态）。分别依据 [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md) 与 [Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)。

### Agent 角色与配置

- **角色模型的构成**：一个 Agent 由 `agents.entries.<agentId>` 配置条目与 workspace 角色文件两部分组成，没有单独的 Persona 表，角色定义也不止一段 system prompt。配置条目负责身份元数据、workspace 与目录、模型、能力策略和运行时选择；workspace 文件负责可编辑规则、人格、用户偏好、引导与记忆。唯一稳定的标识是 roster 中的 Agent ID，schema 会约束其格式，且没有通用的角色版本字段。
- **身份与提示词来源**：身份由结构化 config identity 与人类可编辑的 `IDENTITY.md` 合并而得，UI 展示时按 config、workspace、默认 Assistant 的顺序取值。角色提示词来自三处：源码内的安全与工具指导、workspace 中有界读取的上下文文件，以及本次运行的 channel、session、owner 等动态输入。`SOUL.md` 标注 persona 与 tone，`USER.md` 承载用户偏好；`AGENTS.md` 的 Tools 段只说明工具用法，改变不了可用的工具集合。
- **workspace 与状态**：默认 workspace 由 `OPENCLAW_WORKSPACE_DIR`、`OPENCLAW_STATE_DIR` 与 profile 推导。每个 agentId 的状态、memory 和 session 相互隔离，各自落在自己的 `openclaw-agent.sqlite`。bootstrap 文件的注入模式分为 always、continuation-skip 与 never 三种，pending 的 `BOOTSTRAP.md` 对首轮仪式形成约束；subagent 与 ACP worker 不会重复接收顶层的 bootstrap。
- **模型与覆盖**：Agent 的模型配置有 primary 与 fallback 两种形状，Agent primary 优先于 defaults。会话里的 pin（`modelOverrideSource` 为 user）属于严格选择；自动 fallback 记为 auto，并周期性 re-probe 原来的主选。配置里的默认模型、session 覆盖与"最近一次实际运行模型"是三类不同的事实。
- **路由与 session key**：`bindings` 数组把 channel、account、peer、guild、team 和 role 条件映射到具体 Agent，映射结果同时表达路由所有权与 session 命名空间。session key 以 agentId 作为第一层命名空间；请求里显式指定的 Agent 与 session key 不一致时直接拒绝。
- **原生 subagent 与 ACP**：启动 subagent 时，目标必须同时出现在 allowlist 和已配置的 Agent registry 中；child 会保存 role、spawn depth、父 session 与继承来的工具策略。ACP binding 有自己的 `acpAgentId` 和持久 metadata，仅凭 ACP 形状的 session key 无法断定运行在 ACP 上。
- **Gateway/UI 可见面（入口确认）**：`agents.list`、`agents.update` 以及 identity、files、workspace 预览等 RPC 只向 operator 客户端暴露收窄后的投影，Agents 页面也只是覆盖部分字段的管理表单。普通 Agent 没有通用的 clone、import、export；Claw 包的安装与导出走独立的 provenance + consent 资产流，需要实验开关，载荷按包资产定义。

### 工具面

- **工具目录按运行构建**：核心编码工具（读写编辑/shell）、OpenClaw 控制工具、渠道工具、插件工具与可选 MCP 工具先按运行上下文装配，再经 profile/全局/Agent/群组/发送者/sandbox/subagent/runtime 策略过滤，非 owner 调用者移除控制面工具，最终列表才交给 Agent Core。工具目录不是固定全局表。
- **调用与执行**：模型以标准 `toolCall` 发出；Agent Core 负责 schema 校验、`before_tool_call` 前置（循环准入、可信策略、插件 hook、审批）、串行/并行批次执行与结果回注。失败、拒绝、取消与未启动调用都生成可观察结果，不以静默丢弃结束。工具结果回注为 `toolResult` 消息进入下一轮上下文。
- **审批与执行边界**：审批是执行前策略链的一部分，Gateway/embedded broker 提供 allow-once/allow-always/deny，超时与不可用默认 fail-closed；执行域按工具分散在主机/sandbox、Gateway/渠道、MCP transport、设备节点等 owner。沙箱/workspace-only/safe-bin 边界由调用方策略注入，不等同操作系统级隔离。
- **MCP**：按 `tools/list` 分页物化目录（页数/条目/字节上限），调用闭包按 session 租约绑定，输出被标记为不可信网络内容；服务器声明的并行能力决定执行模式。MCP runtime 以 session 租约管理连接，重启后需重新建目录。
- **子 Agent 与继承**：`sessions_spawn` 可创建 subagent/ACP 运行，子运行继承父最终授权后的 allowlist，而非重新信任原始配置。

## 渠道、设备节点与外部执行体（含配对审批）

主链确认（静态）部分来自 [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)，独特能力卡依据 [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md)。

- **多表面控制链**：Gateway 的 WebSocket 握手依次经过 connect.challenge、connect 和 hello-ok 三步，完成认证、设备证明、节点配对与 session 注册。连接上请求/响应与事件分开传递，事件携带 `seq` 用于检测缺口，重连后通过恢复流程和历史重建恢复投影。CLI、TUI、Control UI 与移动 app 都是外部控制表面，主 Agent runtime 不在这些客户端里；TUI 的 `--local` 嵌入式 backend 属于宿主机内建路径。
- **外部执行体 ACPX**：调用 `sessions_spawn` 时指定 runtime 为 acp，或执行 `/acp spawn`，都会进入 ACPX，由插件启动 Claude、Codex、Gemini、Pi 等外部 harness。harness 保有自己的工具循环与原生 session，文本、工具调用、审批和错误经 Gateway 会话、父会话或绑定渠道回流，进程租约与回收链完整。`openclaw attach` 是另一条外部 Claude Code 协作链，带短期 grant 与 loopback MCP 配置；原生 `openclaw acp` 反向工作，让外部 ACP client 通过 stdio 控制 OpenClaw 的 Gateway 会话。
- **设备节点调用**：Gateway 的 node registry 向已配对节点发送 `node.invoke.request`，节点回传 progress 或 result；超时、取消、空闲超时和断线都归为结构化失败或 cancel。iOS 前台专属命令另有一套受 TTL 与容量约束的 pending action 与 APNS wake 流程。节点能力受声明的 capability、allowlist、scope、插件策略和审批共同限制。
- **渠道 DM 与设备配对审批门（独特能力，主链确认静态）**：渠道账号的 `dmPolicy` 取值为 pairing、allowlist、open、disabled，配合 allowFrom 决定陌生私聊是否放行。pairing 模式下未批准的发送者会收到 8 位 TTL 码，挂起请求 1 小时过期、单账号最多 3 条，期间消息不进入 Agent。操作者通过 CLI 的 `openclaw pairing approve`、Control UI 队列或配对渠道批准后，系统写入 allow entries；批准结果持久化，并决定下一次准入是否放行。设备端的 setup-code 与 bootstrap token 配对、scope 升级沿用同一套显式审批语义。这道门默认拒绝，只认不透明码，各渠道插件共用同一核心决定器，其中 Telegram 已走通，其余渠道未逐一核对。
- **身份分层**：连接身份、Gateway session key、ACP runtime session name、渠道 thread/topic 与 node id 分属不同层级的标识，聊天标题相同也推不出标识相等。
- **渠道 ACP binding**：把一个会话、Discord thread 或 Telegram topic 绑定到外部 ACP 会话上。平台级消息编辑、线程操作与失败重试只到入口确认，未运行验证。
- **云与节点工作环境**：Gateway 可以把 session 放到受管理的 worker environment 或配对节点上，并持久化 placement state、generation、environment owner epoch 与 turn claim。仓库工作区要依次经过准备、同步、远端执行、结果暂存和本地 reconcile，出现冲突时形成显式的 workspace result。重启后的环境恢复与待结算结果由 recovery/reclaim 处理，旧的 claim 拿不回执行权。

## 后台与主动任务

各类运行形态主链确认（静态，未启动 Gateway/timer/渠道）。依据见 [主动Agent与后台任务调查笔记](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md)。

- **五种主动运行形态**：主动运行分成 cron/automations、heartbeat、hooks/webhooks、后台 CLI exec 与 detached subagent 五类，它们共享 Gateway 生命周期与结果交付设施，但每类各有自己的状态 owner。
- **cron/automations（最完整的后台主链）**：Agent 通过 `automations` 工具、Gateway cron RPC 或 CLI 保存 job，到期后由 CronService 认领。SQLite 的 `cron_jobs` 与 `cron_run_receipts` 两张表提供 durable reservation 与 running fence，cron history owner 把日程运行历史写进 task_runs。排程支持 at、every、cron 三种写法，以及 on-exit 与 stream 触发。main job 经 system event 与 heartbeat 重入主会话，isolated 与 current 使用 detached run session。默认并发上限为 8，另有退避重试、连续失败告警、连续 10 次失败后自动禁用、启动 catch-up 与 stale receipt 恢复。
- **heartbeat 与 wake bus**：周期 monitor 本身是一个 system-owned 的 cron job，默认周期 30 分钟。hook、cron 与后台 task 等来源统一进入同一条 wake bus，按 agent 与 session 分组后合并，每个 target 最多有一个活跃的 heartbeat turn。结果是安静还是可见由 outcome classifier 判定，结构化结果写入 `heartbeat_outcomes`；判定为安静时不发消息打扰用户。
- **hooks/webhooks**：Gateway 的 HTTP 层只负责认证、准入与幂等，模型不在这一层执行。wake hook 投递 system event，agent hook 把外部事件合成一次性的 cron run。HTTP replay cache 只存在于进程内，重启后不会保留。
- **后台 CLI exec**：命令转到后台时，yield 与 background 两条路径跟进程完成竞争，后台路径保留 process session 控制身份；进程、输出与完成通知由 supervisor、activity 和 registry 三方协作处理，不存在 runtime 为 cli 的通用任务行。取消分 durable 句柄与普通 supervisor 两条路径；完整重启接管尚未调查。
- **Detached subagent**：`sessions_spawn` 创建子 session 并登记一次 run，运行记录持久化在 `subagent_runs` 表。结果有三条去向：直接投递 requester、进入 steering queue 注入下一次 turn，或在所有子项结束后经 settle wake 重入 requester。跨 restart 的 handoff 走 SQLite 的 session delivery queue。
- **统一 durable channel delivery**：cron、heartbeat、subagent 与 task 的可见结果都先进入写前队列，队列由 SQLite 行加 producer/platform 租约构成。发送结果分为 sent、suppressed、partial_failed 与 failed 四种，unknown-after-send 语义被保留：平台调用已经开始而结果不明的消息不会盲目重发。
- **持久更新运行**：软件更新用 `update_runs` 账本记录触发源、目标、阶段步骤、验证、修复、终态与驱动身份。驱动需要显式 adopt 才接手，已经死亡的驱动和遗留运行按保存的 recovery 继续执行或结算。它作为一种独立的运维运行形态存在，没有与 cron、subagent 合并成通用 worker queue。
- **本次未找到**：统一的跨进程通用 worker queue。持久化分别由 receipt、subagent registry 与 session/outbound delivery queue 承担。

## 媒体生成与输出运行时

媒体创作部分主链确认（静态），输出对象部分为静态路径分析（G0 基座 + Canvas/Board widget 处于 G2–G3，无 G4/G5）。分别依据 [媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/OpenClaw-生成式输出与运行时调查笔记.md)。

### 媒体生成（图片/视频/音乐）

- **工具与目录**：Agent 可调用三个专用媒体工具 `image_generate`/`video_generate`/`music_generate`，由媒体 Provider registry 与插件 manifest 提供能力目录（官方/第三方 Provider 及 ComfyUI 覆盖多模态）；工具是否出现由插件启用、Provider 能力、认证与策略决定。支持图片编辑/多图参考、文生/图生/视频变换、歌词/时长/参考音频等参数，并按 Provider 能力归一化。
- **异步任务与回流**：媒体执行状态归进程内 operation owner，taskId 与 runId 对应同一次生成；满足 requester transcript 条件才脱离前台。Provider 结果先保存，再向原会话提交完成事件；持久 session queue 接管完成投递。生成成功与投递确认分开，未确认可带 blocked 终态；普通终态保留 2 分钟、blocked 7 天，均受当前进程 generation 约束。
- **结果托管与 Artifact**：生成文件经 media store、managed outgoing media 记录与 transcript 绑定；`artifacts.list/get/download` 按 session/run 解析范围并提供短期 ticket。媒体清理依赖 transcript 引用或 transient 超时。
- **关键边界**：本次未找到独立媒体工作台页面、媒体历史树、版本对象、跨会话资产库或媒体工程对象；参考素材的"带图再生成"是 Provider 生成模式而非对 Artifact 的编辑；没有通用 tasks.cancel 或统一 Provider 撤销句柄；接纳前可中止请求，接纳后工作独立运行。完成投递结果可以持久化保存；Provider 生成作业归属进程内 operation owner，重启后由新一轮运行重新发起。

### 生成式输出与 Widget/Canvas 运行时

- **基座（G0）**：默认聊天输出是普通文本或结构化的 content part，作为 assistant 消息进入 transcript，内容级的活对象没有独立生命周期。
- **Canvas 文档**：模型只能通过 `show_widget` 这一个入口生成输出，它把模型产出的 HTML 或 SVG 包进带 CSP 与 host bridge 的 document shell。未 pin 时文档落盘到 `state/canvas/documents/<id>/` 作为托管文档，并以消息内沙箱 iframe 预览，预览环境无网络、只读演示，prompt 回流由用户激活驱动。历史重载时可以从工具结果或短码恢复 inline 预览。
- **Session Board Widget**：调用时传 `pin` 为 true，内容经 `board.widget.put` 写入 session board，落在 per-agent SQLite 的 `board_tabs` 与 `board_widgets` 表。widget name 是稳定身份，revision、instanceId 与 viewGeneration 组成版本线，因此它能长期留在 dashboard 上，也能被再次同名生成整段覆盖。它可承载 HTML、插件注册的 content 与 MCP App view 三种内容。
- **能力授权**：带能力声明的 widget 首次处于 pending，由会话 exec 策略批准后冻结字节 hash；策略有 Guarded（人工确认）、auto（模型评审）、full 与 Read only 四种取值。数据读取、action、cron 触发与免确认 prompt 都要求 grantState 为 granted，且工具名落在 declared 集合内。网络 fetch 只放行声明并获准的精确 HTTPS origin，将其写入 CSP 的 connect-src。widget 代码运行在客户端隔离 iframe 中，沙箱边界由客户端提供。
- **事件回流**：widget 调用 `state.emit` 后，事件经 board event 转成 session system event（前缀 `[dashboard]`），交互内容因此在下一个 Agent turn 自动进入模型上下文。`prompt.send` 生成的是会话内普通 user prompt，需要用户激活。
- **资源治理边界**：每个 session 的 board widget 不超过 48 个，HTML 上限 256 KiB，canvas 文档配额 32 个，view ticket TTL 为 20 分钟，widget 事件 payload 不超过 8 KiB。board 级导入导出 RPC、diff/patch 协作历史、模型侧查询 board widget 列表的专用工具均为未确认项。

## 记忆检索与上下文编译

分别依据 [检索增强与认知编排调查笔记](../检索增强与认知编排/OpenClaw-检索增强与认知编排调查笔记.md) 与 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/OpenClaw-上下文编译与提示词工程调查笔记.md)。

### 记忆检索与认知编排

- **谱系与边界（源码事实）**：内置记忆由五部分构成，包括可编辑的 Markdown 事实源、每 agent 一份 SQLite 派生索引、受权限控制的工具召回、发送前即时注入，以及后台记忆晋级，整套机制在本地实现。QMD backend 已经移除，配置迁移负责把旧路径迁到内置后端；内置 SQLite 引擎是目前唯一的记忆引擎，memory-lancedb 作为可替换插件存在。
- **事实源与索引**：记忆源包括根目录的 MEMORY.md、USER.md，`memory/` 下的 Markdown，以及显式配置的 extraPaths，可选 session transcript corpus。派生资产存放在 agent 的 `openclaw-agent.sqlite` 里，包含 source、chunks、FTS5、可选 sqlite-vec、embedding cache 与 provenance 等表。切块默认约 400 token、80 重叠；Embedding provider 默认为 openai，也支持多种本地或远程实现。provider、model 与 source 等参数参与 index identity，其中任一变化后旧向量索引会被判为 mismatched，不会静默复用。
- **检索主链**：`memory_search` 先做关键词检索（FTS5/BM25）与向量检索（KNN 或进程内 cosine），再混合合并，按时效、importance、project affinity 与 MMR 重排；默认返回不超过 6 条，minScore 为 0.35。返回的候选带有 path、line、score 与 provenance，重排阶段不含 learned cross-encoder 模型。
- **工具化检索与即时注入**：模型先用 `memory_search` 检索，再用 `memory_get` 精读命中条目。Bootstrap 阶段按 provenance 与预算注入 MEMORY.md 和 USER.md；项目记忆块最多灌入 48 条 curated 候选。Wiki（memory-wiki）把来源编译成 entity、concept 与 synthesis 页面，提供 `wiki_search` 与 `wiki_get`，并按预算做 digest 注入。
- **Active Memory（检索驱动编排的部分实现）**：Lane 1 是无模型的 lexical trigger 即时召回，最多取 3 条作为 hidden 前缀注入。Lane 2 只在出现 recall intent 且 Lane 1 没有 strong hit 时启动，由一个受限的记忆子 Agent 返回摘要。命中向量反馈、关系路径递进与多阶段自然语言 query planner 目前都未确认；能确认的编排形态是一次额外 subagent turn 加有界摘要，固定的多阶段认知链仍未确认。
- **主动记忆演化（dreaming）**：memory-core 默认注册一条受 cron 管理的后台 sweep，按 light、REM、deep 三个阶段推进。deep gate 通过后，有界的 consolidation 子 Agent 按 operation 契约维护 MEMORY.md，写入时使用 preimage、hash fence 与 append-only fallback，DREAMS.md 则是供人审阅的界面。untrusted 与 system 内容即使 recall 很高也无法晋级。
- **权限与不可信内容**：provenance 以 SQLite 关闭元数据的形式保存；自动注入与晋级在打分之前先过一道资格门。显式 provider 不可用时搜索返回 visible unavailable，不会把不可用表示成零命中。

### 上下文规则对象与编译

- **规则对象的存放位置**：规则分散在 workspace Markdown、skills、文件 prompt 模板、插件 hook、memory 插件和可选的 context engine 中，没有单一的编译器统一处理。embedded 运行器先准备各来源，由 `buildAgentSystemPrompt` 生成系统提示词，模型调用前再把消息转换成 Provider 可见的数组。
- **workspace 文件**：身份、用户偏好、长期记忆与首轮仪式四类文件的注入条件和生命周期各不相同。身份文件解析只识别有限标签，回写时保持字段稳定；bootstrap 完成标记写入 transcript，compaction 或 reset 会让它失效。
- **skills**：skills 是规则对象实现得最完整的一类。它按优先级合并多个根目录，同名 skill 由来源覆盖，最终产出一个有硬上限的 `<available_skills>` 目录，目录里只放元数据，正文按需读取；显式 `$skill` 引用走另一条请求前展开的路径。模型可见性与运行时可用性是两套面：标记 `disable-model-invocation` 的 skill 只从正常目录中隐藏，授权引用仍可调用。Skill Workshop 提供待审写入与 apply。
- **prompt 模板与 slash 资源**：模板从 agent 的 `prompts/` 目录、项目的 `.openclaw/prompts/` 目录以及显式路径加载，参数替换只做一次展开，不递归。带 `command-dispatch` 为 tool 的 skill 命令可以不经过模型，直接投给工具。
- **插件 hooks 与 context engine**：`before_prompt_build`、`agent_turn_prepare` 等 hook 可以替换或追加系统提示词，也能影响工具面，但 hook 本身不会因此获得工具执行授权。context engine 槽位同一时间只选一个 engine：默认的 legacy 引擎透传消息并把压缩委托给内置 compaction，其他引擎可以实现 assemble、compact、afterTurn 等阶段，并自带 quarantine 与 fallback。
- **模型可见结果与权威 transcript 的分界**：上下文变换分成三类，各自独立：

  - prompt-only：skills 目录、hook context、多数 system prompt addition
  - runtime carrier：hidden custom message，display 为 false
  - durable lifecycle：用户原文、compaction summary、skill snapshot、memory flush

  诊断用的 `systemPromptReport` 与 `/context` 是独立投影，与最终发给 Provider 的 payload 分开维护。
- **compaction 与 memory flush**：compaction 是输入历史的一处明确重写边界，压缩后只有 summary 与近期 tail 进入模型，完整历史仍保留在 SQLite。compaction 之前可以跑一次 silent memory maintenance turn，把尚未写入的事实追加到当天的记忆文件。
- **本次未找到**：统一的"规则 schema + 命中器 + 统一编译"层，即 preset、lorebook 或宏式引擎那种形态；现有各规则来源各有自己的 owner 与错误边界。

## 对话导出与分享

依据 [对话导出与分享调查笔记](../对话导出与分享/OpenClaw-对话导出与分享调查笔记.md)。导出路径四条相互独立、无共享管线，全部为静态确认（未运行 CLI/UI）。

- **消息内 `/export-session`（/export，owner-only）**：在会话里执行这条命令，会把持久化 transcript 的活动分支渲染成一份自包含的离线 HTML 阅读稿，写入工作区。稿中 base64 内嵌了会话数据，带分支树、thinking、工具展示与 system prompt。`/export-trajectory` 与 CLI 的 `openclaw sessions export-trajectory` 输出另一份脱敏 JSONL 支持包，供调试和支持交付使用。这份支持包的 schema 为 `openclaw-trajectory` v1，默认落到 `.openclaw/trajectory-exports/`。
- **Control UI 会话页 `/export-session`**：导出在浏览器本地执行，只把当前已加载的消息下载成纯文本 Markdown，内部上下文与 thinking 会被剥掉。
- **原生应用 Export Transcript**：iOS 与 macOS 把当前视图中的消息导出为 Markdown，再交给系统分享面板，macOS 上的快捷键是 ⌘⇧E。
- **口径差异**：同一个命令名在渠道端和 Web 端对应两套实现，导出的内容范围也不同：渠道端包含 system prompt 与完整工具轨迹，Web 端只有正文 Markdown。两端导出的都是快照，之后不会与源会话再同步。
- **内容边界**：导出范围限于活动分支，隐藏分支不会出现。轨迹导出会清洗本地路径与 secret 类内容，属于尽力而为；HTML 导出则有意识地保留原始内容。只有当图片以 base64 形式存在于 transcript 中时才会真正内联显示，图片是否普遍携带这一点尚未验证。
- **公开会话分享**：Control UI 在用户显式确认后可以发布一条世界可读的 token 链接，也能单独撤销。公开发布绑定到精确的 session generation，与 shared、read-only、suggest、draft 这些团队可见性和成员关系彼此分离。普通会话 URL 仍然是要鉴权的深链。
- **仍未找到**：分享稿编辑器与预览工作台、会话整图或长图导出、本地导出版本历史。公开链接的过期、评论、访问统计与克隆也都未确认。走控制面导出会话时（例如经 CLI 或 ACP 代理），只能看到 user 行，并附有说明。

## 界面与独特功能

### 聊天表面（Chat UI）

依据 [Chat UI 调查笔记](<../Chat UI/OpenClaw-ChatUI调查笔记.md>) 与 [消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)。四套表面都以 Gateway 会话与事件为远端事实来源，但各保留本地状态与恢复存储。

- **Control UI**：功能最完整的聊天工作台，支持多 pane/分屏/辅助面板与按会话保留的 pane 现场；Composer 支持 slash/skill 菜单、引用回复、附件、dictation/talk；草稿与附件分别按 Gateway owner 存浏览器 storage 与 IndexedDB；消息右键提供 reply/rewind/fork/copy；多会话经 sidebar 子树与 background task rail 呈现。
- **TUI**：单终端工作区，命令/选择器/照捷键为主入口，流式、scrollback（默认 180 component）与 run 协调由独立控制器处理；未找到与 Control UI 对应的事件消息级 rewind/fork 入口，也未找到跨进程 durable 草稿。
- **Apple 原生与 Android 原生**：iOS Chat Pro 用共享 SwiftUI 原生视图（Dashboard 经认证 WebView 打开 Control UI）；Android 是 Compose `ChatScreen`。两者的 Composer/草稿/outbox 在本地保存（Swift 内存 + ViewModel、Android Room/StateFlow）。
- **发送与恢复共同原则**：先保留用户输入，再用历史或带身份的运行事件确认交付；"已收到 ACK"与"已写入 canonical history"分开，不确定发送停在 unconfirmed/confirming/failed 而非静默重发；三套原生表面各自 outbox 由 canonical history 退休。
- **渲染管线**：Gateway 做显示投影（隐藏回复、预算、身份补全）；消息进入各客户端的 reducer 后由 thread builder/时间线装配为可见 turn。Control UI 用虚拟行 + 流式 Markdown 稳定前缀/尾部修复；TUI 用 pi-tui 有界 scrollback；iOS 用 ScrollView+LazyVStack、Android 用 reverse LazyColumn。渲染、滚动、富文本细节见 [消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)。
- **承载与安全边界**：普通 Markdown 是受限富文本（DOMPurify 白名单、无 iframe/script）；Canvas HTML 与 MCP App 走带 sandbox/CSP/TLS/bridge 约束的独立 widget 承载面。Control UI 已接入 Mermaid；KaTeX 未确认 Web 渲染入口，Android 有原生资源，也未找到 ACP 专用独立消息 renderer（均为"本次检查范围未找到"）。
- **未运行验证**：多窗口间临时 draft/scroll/focus 是否完整同步、各平台真实键盘/IME/视觉与无障碍表现均未验证；未证明浏览器 IndexedDB、Apple 数据库与 Android Room 之间同步未发送草稿。

### 应用界面基础设施

依据 [应用界面基础设施调查笔记](../应用界面基础设施/OpenClaw-应用界面基础设施调查笔记.md)。

- **形态**：Control UI 使用 Solid 2 与原生 DOM 公共组件，随 Gateway 同版本派发；每个文档独立创建运行期。原生与 TUI 各有界面设施，Linux Tauri 可嵌入 Control UI。
- **公共机制**：Solid Context 与原生 bridge 提供能力对象；公共 Modal 管原生 dialog、滚动锁、焦点和取消；菜单由 Overlay owner 与导航状态机协作。Toast 宿主支持双 lane 堆叠，各收起显示三条，隐藏条目暂停，hover/focus 展开暂停；宿主随 Modal/抽屉移动。根与异步视图使用 Loading/Errored 边界；主题由 CSS token、首帧调色板和运行期主题 owner 协作。
- **偏好同步**：外观类偏好（theme/mode/accent/locale 等白名单）以服务端 config `ui.prefs` 为权威、localStorage 为镜像与离线暂存，跨窗口/跨设备收敛；其余偏好设备本地；布局折叠等形态有意不跨 tab 同步。
- **响应式与多入口**：Shell 以 JS/CSS 双断点适配、移动窄屏用 nav-drawer；同一前端经 URL 解析出 approval/question/terminal/desktop/dashboard 等"聚焦文档"，复用入口、省略壳 chrome。图片 lightbox、文件预览等公共内容交互以 modal 为壳。
- **无障碍/动画扩展**（静态确认基础，未运行审计）：skip-link、focus-visible、aria/role 语义、reduced-motion 分支等；未做 WCAG 合规结论。

### 独特功能机制

依据 [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md)。

- **ClawHub 分发与安装信任门（主链确认，静态，依赖外部 ClawHub 响应）**：执行 `openclaw skills install` 或 `plugins install clawhub:` 这类入口时，系统先取目标 release 的信任元数据再决定是否继续。裁决有三种：clean 直接放行；blocked（恶意、拉黑或审核阻止）拒绝下载；review-required 要求操作者用 `--acknowledge-clawhub-risk` 显式确认。裁决随安装记录持久化，`update --all` 与 doctor 之后还会重新过门。聊天命令面无法代替本机确认，以防用户经 Agent 被诱骗安装。
- **`openclaw doctor` 诊断、修复与迁移链（入口确认，工程机制）**：检查与修复逻辑按模块族拆分，顶层 doctor 命令由只读、`--fix`、非交互、`--lint --json` 几种参数组合驱动。完整的 check→fix→verify 回合没有逐条走查，因此不计入用户功能统计。
- **暂缓项与仓库内部资产**：companion 语音与 talk、A2UI、meeting-bot、fleet、projects/flows/tasks 这些"新表面"只查到声明与入口层，尚未走通主链；Canvas 文档与 session board widget 归入本汇总“媒体生成与输出运行时”一节。taxonomy.yaml、custodian-skills 与仓库根的 `skills/` 属于 QA 与维护 agent 资产，不在用户产品能力范围内。
- **归并位置**：渠道与设备的配对审批门见本汇总"渠道、设备节点与外部执行体"一节。

## 证据边界与遗漏

- **统一证据状态**：以上"主链确认（静态）"均来自当前代码快照的可执行调用关系复核，未运行构建、测试、Gateway、真实 Provider、真实 UI/原生设备或端到端会话。按各类目指南，未做运行验证不降低源码结构类结论；运行验证补充的是平台差异、外部依赖、时序、性能与交互质量等可观察结果。
- **媒体类目边界**：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md) 只保留外部 Provider、节点采集和远端执行边界；图片/视频/音乐生成的任务化主链以 [媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md) 为准。
- **"本次未找到"（限定于已读入口/范围，不作项目级绝对断言）**：通用消息就地编辑与按 id 删除 RPC；通用 sessions export/import RPC；统一跨进程后台 worker queue；独立媒体工作台/媒体历史树/跨会话资产库/媒体工程对象；board 级导入导出与模型侧 board 查询工具；分享稿编辑器、会话整图导出与本地导出版本历史；普通 Agent 的 clone/import/export；通用规则 schema 编译器（preset/lorebook 层）；Control UI KaTeX 与 ACP 专用消息 renderer。
- **本轮没有调查/暂缓**：companion 语音与 talk、A2UI、meeting-bot、fleet、projects/flows/tasks 等新表面的用户主链；ClawHub 市场/扫描/审核服务（仓库外）；各渠道插件的逐平台传输实现（以核心决定器与 Telegram 为例，未逐一核对约 20 个渠道）；voice-phone 桥接等外部展示声明。Canvas 文档与 session board widget 不在此列，其静态主链已归入“媒体生成与输出运行时”。
- **当前证据无法确认的事项**：不同 Provider 的真实事件时序、并发容量下的端到端顺序、错误恢复与重启竞态、多客户端并发的跨表面一致性与安全对抗强度（配对传播、下载校验、prompt-injection framing）、各 UI 的实际视觉/焦点/无障碍/键盘表现、附件与媒体在真实模型请求中的字节与成本。以上均需运行或对抗验证，现有来源未覆盖。
- **声明与实现差异记录**：命令名同名异实现（`/export-session` 渠道端 HTML vs Control UI 端 Markdown）；普通会话 URL 是鉴权内部深链，公开分享另用 public-share token 路由；models.json 中 apiKey 常为来源 marker 而非明文；`session_message` 与 `chat`/`agent` 事件是不同投影面；compaction 前后模型可见历史与 SQLite 完整历史是不同事实。
- **外部依赖边界**：模型 Provider、hosted catalog、ClawHub、媒体 Provider/ComfyUI、消息渠道平台、推送服务、ACPX 外部 harness、设备本地能力均在仓库外或需真实服务；无外部服务时相关门 fail-closed（如 ClawHub 来源不可达不静默降级）。
- 运行验证补充的是特定环境下的可观察结果；测试文件存在、测试运行、黑盒验证与线上使用属不同证据层级，本汇总仅引用各来源静态确认的边界。

## 来源笔记索引

正文已给出各能力链接，文末集中列出纳入汇总的 17 份来源笔记：

- [仓库分布调查笔记](../仓库分布/OpenClaw-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/OpenClaw-对话请求与上下文调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/OpenClaw-ChatUI调查笔记.md>)
- [消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/OpenClaw-对话导出与分享调查笔记.md)
- [LLM渠道管理调查笔记](../LLM渠道管理/OpenClaw-LLM渠道管理调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md)
- [Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)
- [主动Agent与后台任务调查笔记](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md)
- [检索增强与认知编排调查笔记](../检索增强与认知编排/OpenClaw-检索增强与认知编排调查笔记.md)
- [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/OpenClaw-上下文编译与提示词工程调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/OpenClaw-生成式输出与运行时调查笔记.md)
- [媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/OpenClaw-应用界面基础设施调查笔记.md)
- [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md)
