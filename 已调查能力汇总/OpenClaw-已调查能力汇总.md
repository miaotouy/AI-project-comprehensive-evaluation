# OpenClaw 已调查能力汇总

> 汇总对象：`https://github.com/openclaw/openclaw`
>
> 汇总更新日期：2026-09-04
>
> 依据：OpenClaw 已完成的 17 份单项目调查笔记：仓库分布、会话与消息管理、对话请求与上下文、Chat UI、消息渲染器、对话导出与分享、LLM渠道管理、Agent角色配置、Agent工具、外部执行体与应用协作、主动Agent与后台任务、检索增强与认知编排、上下文编译与提示词工程、生成式输出与运行时、媒体创作、应用界面基础设施、独特功能（代码快照统一为各笔记记录的 `c64a640f5df5bc72537357417c54647c050cb863`）
>
> 汇总方法：逐一阅读全部来源笔记；按产品能力主题合并来自多个类目的同一能力，避免按来源目录重复抄写；能力说明保留各笔记的证据状态（主链确认/入口确认/本次未找到/暂缓/未运行等）与限定条件，不在汇总中补做源码调查或升级证据；来源链接为从本目录出发的相对路径
>
> 汇总范围：覆盖上述笔记对 OpenClaw 的已调查能力、关键边界、外部依赖与证据状态。明确遗漏：不做跨项目横向比较、评分或整改建议；汇总通常不新增源码定位；单项目笔记的逐条源码索引、完整状态清单与调用链细节需回读原文
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

OpenClaw 是一个以本机 Gateway 为控制平面的多渠道单操作者私人 AI 助手。Gateway 是中心状态、路由与控制平面；CLI、TUI、浏览器 Control UI、iOS/Android companion app 与消息渠道适配器主要是外部控制表面或设备节点，不各自持有主 Agent 运行时；真正执行模型请求的是与 Gateway 同机的 agent 运行器。产品形态与调用面依据见 [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)。

- **主要调用者与表面**：操作者通过 CLI、TUI、Control UI 和移动 companion 应用发起并管理会话；多渠道 IM（文档列出约 20 个支持渠道，为入口/文档级确认）上的消息、thread/topic 映射到 Gateway session 或 ACP binding；外部 ACP client 与第三方 Claude Code 子进程可以从相反方向桥接。
- **仓库结构与规模**：pnpm workspace，根入口 `openclaw.mjs`。`src` 承担 Gateway、Agent、会话、工具与 CLI 主链；`extensions` 承担消息渠道、Provider 插件与可选能力；`ui` 是 Control UI；`apps` 是桌面/移动 companion；`packages` 提供共享 SDK/协议。快照约 34,147 个跟踪文件，TypeScript 约占可识别源码 91%，Swift/Kotlin 服务 companion 与平台集成。依据见 [仓库分布调查笔记](../仓库分布/OpenClaw-仓库分布调查笔记.md)。
- **Agent 形态**：普通用户 Agent 是配置 roster（`agents.entries.<agentId>`）与 workspace 角色文件（AGENTS.md、SOUL.md、IDENTITY.md、USER.md、BOOTSTRAP.md、MEMORY.md）的组合，按 agentId 隔离 SQLite 状态与会话目录；另有 Gateway 投影的 system agent 行与外部 ACP harness 两类边界。依据见 [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md)。
- **重要外部依赖**：模型 Provider（OpenAI、Anthropic、Google、本地 Ollama/llama.cpp/LM Studio 等）；hosted 模型目录（`catalog.openclaw.ai`，源仓库在仓库外）；ClawHub 外部注册表及其扫描/审核服务；ComfyUI 本地/云端等媒体 Provider；消息渠道平台账号与推送服务；iOS/Android 设备本地能力；ACPX 外部 harness。
- **产品辨识点**：把"谁能接触 Agent、谁能往本机安装会改变 Agent 行为的代码"做成显式、可审计的准入与信任决策，见 [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md) 与本汇总"渠道、设备节点与外部执行体"一节。

本工作区未撰写产品结构与设计基因类笔记，产品演变叙事不展开。

## 会话与消息管理

主链确认（静态代码，未运行 Gateway/UI）。完整依据见 [会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)。

- **数据模型与标识**：会话分两层寻址——逻辑会话用 `sessionKey`，transcript generation 用 `sessionId`；同一逻辑会话可轮换保留多代 transcript。事实源是 per-agent SQLite（schema 版本 17），`session_nodes.entry_json` 是逻辑会话记录 canonical source，`session_windows` 与 `transcript_events` 拥有 transcript generations；活动路径、消息序号与全文搜索是从事件派生的可重建投影，不是第二份消息主库。消息是带 `parentId` 的父子链/DAG，entry 区分普通消息与 thinking 变化、model 切换、compaction、reset、branch 摘要等控制条目；写入必须经带 parent、幂等与媒体规范化的追加入口。
- **生命周期与版本操作**：创建、metadata patch、归档/置顶/未读、列表切换、reset、删除（archive-then-delete，先冷归档再回收）、restart recovery（仅接受带 restart tombstone 的 source）。rewind、fork、branch switch、checkpoint branch/restore 通过轮换 transcript generation 改变活动路径，旧代际通常保留而非物理删除；带 upstream link 的外部 harness session 不进本地 branch graph。
- **一致性**：SQLite 写入由 per-store writer queue 串行，事务内同步提交前重读权威行并做 expected identity/lifecycleRevision 比较；message 幂等键有唯一索引，重复请求返回原消息、payload 冲突显式报错。事件提交与活动路径/FTS 前向更新同事务；无法从新增行安全推断路径时用持久 dirty watermark 隐藏派生行，由 reconcile 完整重建（小型重建阈值约 4,000 行/4 MiB，超出转后台）。
- **检索与分页**：会话列表支持 offset 分页、固定排序（pinned 优先再按更新时间）与 agent/归档/owner 等过滤；聊天历史按活动路径的逻辑消息序号分页，可用 messageId anchor 定位并可回退 reset archive；正文搜索走 per-agent FTS5，只索引活动路径中的 user/assistant 可读文本，索引 dirty 时返回 indexing 而不是不可靠旧行。
- **迁移与导入**：transcript 文件协议版本 3、SQLite schema 版本 17，旧格式迁移与 `importSqliteSessionRows` 属 doctor/migration 路径；正常 runtime 写入器拒绝非 canonical key。迁移与 canonical repair 兼容旧 JSONL、旧 alias 与旧 schema。
- **会话级绑定**：模型/provider 覆盖、工具策略、worktree/exec 目录、channel/conversation 路由、CLI/ACP harness 元数据等作为会话引用或归属快照保存；附件随消息内容或 media store 引用关联，schema 中无独立会话附件表。
- **本次未找到**：面向用户的通用"就地编辑一条已落盘消息"或"按 message id 删除消息"RPC（精确 event rewrite 仅用于受保护 repair）；通用 sessions export/import RPC（导出/分享见本汇总对应小节）。

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

- **三层渠道结构**：逻辑 Provider（`provider/model` 中的品牌身份）→ 协议与 Adapter（按 `model.api` 协议族注册的流式实现）→ 模型目录与凭据（运行时可查询、可复制的目录快照）。没有持久化的"渠道实例"对象；"解析到具体渠道"的终点是 Model 行（baseUrl/api/compat）、可用 auth 方案、stream adapter 与会话绑定 LlmRuntime 四者。
- **模型目录**：来源合并为 author 的 agent `models.json`、provider 插件生成目录（agent SQLite `cache_entries`，scope `plugin-model-catalog-v1`）与运行时 `registerProvider(...)` 动态注入；hosted catalog 默认 `https://catalog.openclaw.ai/models/v1/catalog.json`（TTL 6 小时，源仓库不在本仓库内）可增量覆盖。`models.mode` 的 merge/replace 影响配置层，目录层始终是各来源之和。
- **凭据解析**：最终凭据统一为 `ResolvedRequestAuth(apiKey + headers)`。优先级链为显式 pin 的 auth profile → `auth.order` 配置顺序 → aws-sdk → env-first 环境变量 → provider 内联 key（env/exec/SecretRef 解析）→ auth store 按序逐 profile（api_key/token/oauth）。`models.json` 持久化的是来源 marker 而非明文；OAuth 是可刷新运行时状态，不接受 SecretRef。
- **故障转移四层**：同 key 瞬时重试、限流时 env 多 key 轮换、auth profile 轮换（各 profile 独立 cooldown/disabled，round-robin 且会话有 stickiness）、模型级 fallback 链。user pin 是严格选择不落入 fallback；configured/cron 主选可回退；仅当全链都是超载类错误时才整链最多重试 10 次。fallback 是 turn-local 的，不写回成下一轮选择。
- **连接检测与可观测**：CLI `models status/list --probe` 与 Control UI "Test connection"（RPC `models.probe`）复用同一 auth-probe 引擎，发起真实最小模型请求并返回状态桶与稳定 reasonCode；usage/cost 随每条 assistant 消息归一化落账。
- **管理入口（入口确认）**：config、CLI `models` 命令族、Control UI Settings→Model Providers；"复制 provider""导入/导出 provider 配置""桌面端独立 provider CRUD"本次未找到（限定于已读入口）。

## Agent 角色与工具

主链确认（静态）。分别依据 [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md) 与 [Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)。

### Agent 角色与配置

- **角色模型**：Agent 边界是 `agents.entries.<agentId>` 配置条目 + workspace 角色文件，不是单独 Persona 表，也不是只包一段 system prompt 的包装。配置条目承担身份元数据、workspace/目录、模型、能力策略与运行时选择；workspace 文件承担可编辑规则、人格、用户偏好、引导与记忆。唯一稳定标识是 roster 中的 Agent ID（schema 约束标识格式，无通用角色版本字段）。
- **身份与提示词来源**：身份由结构化 config identity 与人类可编辑 `IDENTITY.md` 两个来源合并，UI 展示优先 config、再 workspace、最后默认 Assistant。角色提示词主要来自源码内安全/工具指导、workspace 有界读取的上下文文件与本次运行的 channel/session/owner 等动态输入；`SOUL.md` 标 persona/tone、`USER.md` 标用户偏好。`AGENTS.md` 的 Tools 段只指导使用方式，不能授予工具。
- **workspace 与状态**：默认 workspace 由 `OPENCLAW_WORKSPACE_DIR`/`OPENCLAW_STATE_DIR`/profile 推导；Agent 状态、memory 与 session 按 agentId 隔离（per-agent `openclaw-agent.sqlite`）。bootstrap 文件注入模式有 always/continuation-skip/never 之分，pending `BOOTSTRAP.md` 约束首轮仪式；subagent 与 ACP worker 不重复接收顶层 bootstrap。
- **模型与覆盖**：Agent 支持 primary/fallback 两种形状；Agent primary 优先于 defaults；会话 pin（`modelOverrideSource:"user"`）严格、自动 fallback 记 auto 并周期 re-probe 原主选。配置默认模型、session 覆盖与"最近一次实际运行模型"是不同事实。
- **路由与 session key**：`bindings[]` 把 channel/account/peer/guild/team/role 条件映射到 Agent，结果同时是路由所有权与 session 命名空间；session key 以 agentId 为第一层命名空间，显式 Agent 与 session key 不一致会被拒绝。
- **原生 subagent 与 ACP**：subagent 目标须同时满足 allowlist 与已配置 Agent registry，child 保存 role、spawn depth、父 session 与继承工具策略；ACP binding 有独立的 `acpAgentId` 与持久 metadata，ACP-shaped key 本身不足以证明运行在 ACP。
- **Gateway/UI 可见面（入口确认）**：`agents.list/update`、identity、files、workspace 预览等 RPC 面向 operator 客户端做收窄投影；Agents 页面不是所有字段的通用表单。普通 Agent 无通用 clone/import/export；Claw 包安装/导出是独立的 provenance + consent 资产流（实验开关下），不等于通用角色分享格式。

### 工具面

- **工具目录按运行构建**：核心编码工具（读写编辑/shell）、OpenClaw 控制工具、渠道工具、插件工具与可选 MCP 工具先按运行上下文装配，再经 profile/全局/Agent/群组/发送者/sandbox/subagent/runtime 策略过滤，非 owner 调用者移除控制面工具，最终列表才交给 Agent Core。工具目录不是固定全局表。
- **调用与执行**：模型以标准 `toolCall` 发出；Agent Core 负责 schema 校验、`before_tool_call` 前置（循环准入、可信策略、插件 hook、审批）、串行/并行批次执行与结果回注。失败、拒绝、取消与未启动调用都生成可观察结果，不以静默丢弃结束。工具结果回注为 `toolResult` 消息进入下一轮上下文。
- **审批与执行边界**：审批是执行前策略链的一部分，Gateway/embedded broker 提供 allow-once/allow-always/deny，超时与不可用默认 fail-closed；执行域按工具分散在主机/sandbox、Gateway/渠道、MCP transport、设备节点等 owner。沙箱/workspace-only/safe-bin 边界由调用方策略注入，不等同操作系统级隔离。
- **MCP**：按 `tools/list` 分页物化目录（页数/条目/字节上限），调用闭包按 session 租约绑定，输出被标记为不可信网络内容；服务器声明的并行能力决定执行模式。MCP runtime 以 session 租约管理连接，重启后需重新建目录。
- **子 Agent 与继承**：`sessions_spawn` 可创建 subagent/ACP 运行，子运行继承父最终授权后的 allowlist，而非重新信任原始配置。

## 渠道、设备节点与外部执行体（含配对审批）

主链确认（静态）部分来自 [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)，独特能力卡依据 [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md)。

- **多表面控制链**：Gateway WebSocket 以 connect.challenge → connect → hello-ok 完成认证、设备证明、节点配对与 session 注册；请求/响应与事件分离，事件 `seq` 检测缺口，重连后经恢复/历史重建投影。CLI/TUI/Control UI/移动 app 都是外部控制表面，不拥有主 Agent runtime；TUI `--local` 嵌入式 backend 属宿主内建路径。
- **外部执行体 ACPX**：`sessions_spawn({runtime:"acp"})` 或 `/acp spawn` 进入 ACPX，由插件启动 Claude/Codex/Gemini/Pi 等外部 harness；harness 保有自己的工具循环与原生 session，text/tool/审批/错误经 Gateway session、父 session 或绑定渠道回流，进程租约与回收链完整。`openclaw attach` 是另一条带短期 grant + loopback MCP 配置的外部 Claude Code 协作链；原生 `openclaw acp` 反向让外部 ACP client 经 stdio 控制 OpenClaw 的 Gateway session。
- **设备节点调用**：Gateway node registry 向已配对节点发 `node.invoke.request`，节点回 progress/result，超时/取消/空闲超时/断线走结构化失败或 cancel；iOS 前台专属命令另有 TTL+容量的 pending action 与 APNS wake 流程。节点能力按声明 capability、allowlist、scope、插件策略与审批限制。
- **渠道 DM 与设备配对审批门（独特能力，主链确认静态）**：渠道账号的 `dmPolicy`（pairing/allowlist/open/disabled）与 allowFrom 决定陌生私聊是否放行。pairing 模式下未批准发送者收到 8 位 TTL 码（挂起请求 1 小时过期、单账号上限 3 条），消息不进 Agent；操作者经 CLI `openclaw pairing approve`、Control UI 队列或配对渠道批准后写入 allow entries，批准持久化并驱动下一次准入。设备端 setup-code/bootstrap token 配对及 scope 升级走同源的显式审批语义。该门 fail-closed、不透明码，各渠道插件共享核心决定器（以 Telegram 为例走通，其余渠道未逐一核对）。
- **身份分层**：连接身份、Gateway session key、ACP runtime session name、渠道 thread/topic、node id 是不同层级标识，不能凭聊天标题推断相等。
- **渠道 ACP binding**：把会话/Discord thread/Telegram topic 绑定到外部 ACP session；平台级消息编辑、线程与失败重试为入口确认、未运行验证。

## 后台与主动任务

各类运行形态主链确认（静态，未启动 Gateway/timer/渠道）。依据见 [主动Agent与后台任务调查笔记](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md)。

- **运行形态不是单一任务系统**：当前快照的主动运行分 cron/automations、heartbeat、hooks/webhooks、后台 CLI exec、detached subagent 五种，共享 Gateway 生命周期与结果交付设施，各自的状态 owner 不同。
- **cron/automations（最完整的后台主链）**：Agent 用 `automations` 工具、Gateway cron RPC 或 CLI 保存 job；到期由 CronService 认领，SQLite `cron_jobs` + `cron_run_receipts` 提供 durable reservation/running fence，`task_runs` 提供客户端可见投影。支持 at/every/cron 时间排程与 on-exit、stream 触发；main job 经 system event + heartbeat 重入主会话，isolated/current 用 detached run session；默认并发上限 8，支持退避重试、连续失败告警、10 次自动禁用、启动 catch-up 与 stale receipt 恢复。
- **heartbeat 与 wake bus**：周期 monitor 是 system-owned cron job（默认周期 30m）；hook/cron/后台 task 等进入同一 wake bus，按 agent/session 分组合并、每 target 最多一个活跃 heartbeat turn；安静/可见结果由 outcome classifier 区分，结构化结果写 `heartbeat_outcomes`，不打扰用户时不发消息。
- **hooks/webhooks**：Gateway HTTP 层只做认证/准入与幂等，不直接执行模型；`wake` hook 投递 system event，`agent` hook 把外部事件合成一次性 cron run。HTTP replay cache 仅进程内，不承担跨重启 ledger。
- **后台 CLI exec**：exec 在 yield/background 后把受监管进程登记为 task run，进程由 ProcessSupervisor 托管；完成后可写 system event 并请求 heartbeat。后台进程跨 Gateway 重启可恢复性未确认（未找到跨重启重连原始 child 的 worker owner）。
- **Detached subagent**：`sessions_spawn` 创建子 session 并登记 run，`subagent_runs` 持久化；结果可直投 requester、进 steering queue 注入下一次 turn，或经 settle wake 在所有子项结束后重入 requester。跨 restart 的 handoff 走 SQLite session delivery queue。
- **统一 durable channel delivery**：cron/heartbeat/subagent/task 的可见结果都进入写前队列（SQLite row + producer/platform lease），发送结果分 sent/suppressed/partial_failed/failed，保留 unknown-after-send 语义，避免平台调用已开始但结果不明时盲目重发。
- **本次未找到**：统一的跨进程通用 worker queue；持久性是 receipt、subagent registry、session/outbound delivery queue 分别承担的。

## 媒体生成与输出运行时

媒体创作部分主链确认（静态），输出对象部分为静态路径分析（G0 基座 + Canvas/Board widget 处于 G2–G3，无 G4/G5）。分别依据 [媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md) 与 [生成式输出与运行时调查笔记](../生成式输出与运行时/OpenClaw-生成式输出与运行时调查笔记.md)。

### 媒体生成（图片/视频/音乐）

- **工具与目录**：Agent 可调用三个专用媒体工具 `image_generate`/`video_generate`/`music_generate`，由媒体 Provider registry 与插件 manifest 提供能力目录（官方/第三方 Provider 及 ComfyUI 覆盖多模态）；工具是否出现由插件启用、Provider 能力、认证与策略决定。支持图片编辑/多图参考、文生/图生/视频变换、歌词/时长/参考音频等参数，并按 Provider 能力归一化。
- **异步任务与回流**：会话内请求建立 runtime=cli 的媒体 TaskRecord（`task_runs`），返回 taskId/runId；Provider 完成后再唤醒原 Agent 会话，要求生成短说明并把结构化媒体放进可见回复。任务在完成事件被接收前保持投递中状态，回流失败可记 blocked 或走回退，避免"Provider 已完成"与"用户已收到"混淆。
- **结果托管与 Artifact**：生成文件经 media store、managed outgoing media 记录与 transcript 绑定；`artifacts.list/get/download` 按 session/run/task 解析范围并提供短期 ticket。媒体清理依赖 transcript 引用或 transient 超时。
- **关键边界**：本次未找到独立媒体工作台页面、媒体历史树、版本对象、跨会话资产库或媒体工程对象；参考素材的"带图再生成"是 Provider 生成模式而非对 Artifact 的编辑；无统一 Provider 任务撤销句柄（`tasks.cancel` 可把任务标 cancelled，不保证撤销远端 Job）；任务行可恢复不等于生成作业可恢复。

### 生成式输出与 Widget/Canvas 运行时

- **基座（G0）**：默认聊天输出是普通文本/结构化 content part，以 assistant 消息进入 transcript，无内容级活对象生命周期。
- **Canvas 文档**：`show_widget` 工具（唯一向模型公开的生成输出入口）把模型 HTML/SVG 包进带 CSP + host bridge 的 document shell；未 pin 时落盘为 `state/canvas/documents/<id>/` 托管文档，作消息内沙箱 iframe 预览（无网络、只读演示、用户激活驱动的 prompt 回流）。历史重载时可从工具结果/短码恢复 inline 预览。
- **Session Board Widget**：`pin:true` 经 `board.widget.put` 写入 session board（per-agent SQLite `board_tabs`/`board_widgets`），以 widget name 为稳定身份、revision/instanceId/viewGeneration 为版本线，成为 dashboard 上可长期存在、可被再次同名生成整段覆盖的 widget；可承载 HTML、插件注册 content、MCP App view 三种内容。
- **能力授权**：带能力声明的 widget 首次为 pending，经会话 exec 策略（Guarded 人工/auto 模型评审/full/Read only）批准后冻结字节 hash；数据读取、action、cron 触发与免确认 prompt 都要求 grantState=granted 且工具名在 declared 集合。网络 fetch 只允许声明并获准的精确 HTTPS origin 进入 CSP `connect-src`；widget 代码运行在客户端隔离 iframe（非服务器沙箱）。
- **事件回流**：widget `state.emit` 经 board event 变 session system event（`[dashboard] ...`），使交互在下一个 Agent turn 自动进入模型上下文；`prompt.send` 生成会话内普通 user prompt 并需用户激活。
- **资源治理边界**：每 session board widget ≤48、HTML 上限 256 KiB、canvas 文档配额 ≤32、view ticket TTL 20 分钟、widget 事件 payload ≤8 KiB 等；无 board 级导入/导出 RPC、无 diff/patch 协作历史、无模型侧查询 board widget 列表的专用工具（未确认项）。

## 记忆检索与上下文编译

分别依据 [检索增强与认知编排调查笔记](../检索增强与认知编排/OpenClaw-检索增强与认知编排调查笔记.md) 与 [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/OpenClaw-上下文编译与提示词工程调查笔记.md)。

### 记忆检索与认知编排

- **谱系与边界（源码事实）**：内置记忆是"可编辑 Markdown 事实源 + 每 agent SQLite 派生索引 + 受权限控制的工具召回 + 发送前即时注入 + 后台记忆晋级"，不是外置知识库。QMD backend 已移除，配置迁移负责把旧路径迁移到内置后端；内置 SQLite 引擎是当前唯一内置 memory engine（memory-lancedb 是可替换插件）。
- **事实源与索引**：源为根 MEMORY.md、USER.md、`memory/` 下 Markdown 与显式 extraPaths（可选 session transcript corpus）；派生资产在 agent `openclaw-agent.sqlite`（source/chunks/FTS5/可选 sqlite-vec/embedding cache/provenance 等表）。切块默认约 400 token、80 overlap；Embedding provider 默认 openai，可配多种本地/远程；provider/model/source 等参与 index identity，变化后旧向量索引判 mismatched 而非静默复用。
- **检索主链**：`memory_search` 关键词（FTS5/BM25）+ 向量（KNN 或进程内 cosine）+ 混合合并，再按时效/importance/project affinity/MMR 重排；默认返回 ≤6 条、minScore 0.35。结果是带 path/line/score/provenance 的候选，不是 learned cross-encoder rerank。
- **工具化检索与即时注入**：模型可 `memory_search` 后 `memory_get` 精读；Bootstrap 阶段按 provenance/预算注入 MEMORY.md/USER.md；项目记忆块最多 48 条 curated 候选；Wiki（memory-wiki）把来源编译成 entity/concept/synthesis 页面并支持 `wiki_search/wiki_get` 与受预算的 digest 注入。
- **Active Memory（检索驱动编排的部分实现）**：Lane 1 是无模型的 lexical trigger 即时召回（≤3 条 hidden 前缀）；Lane 2 只在 recall intent 且 Lane 1 无 strong hit 时启动受限记忆子 Agent 返回摘要。当前未确认命中向量反馈、关系路径递进或多阶段自然语言 query planner，故不把一次额外 subagent turn 等同于固定多阶段认知链。
- **主动记忆演化（dreaming）**：memory-core 默认注册受 cron 管理的 light→REM→deep 后台 sweep；deep gate 通过后由有界 consolidation 子 Agent 按 operation 契约维护 MEMORY.md（preimage + hash fence + append-only fallback），DREAMS.md 是审阅面。untrusted/system 内容不能靠高 recall 晋级。
- **权限与不可信内容**：provenance 是 SQLite 关闭元数据；自动注入与晋级在分数前先过资格门；搜索对显式 provider 不可用保持 visible unavailable，不伪装成零命中。

### 上下文规则对象与编译

- **规则对象分布，不是单一编译器**：规则散落在 workspace Markdown、skills、文件 prompt 模板、插件 hook、memory 插件与可选 context engine。embedded 运行器先准备来源，`buildAgentSystemPrompt` 生成系统提示词，模型调用前把消息转成 Provider 可见数组。
- **workspace 文件**：身份/用户偏好/长期记忆/首轮仪式文件生命周期与注入条件不同；身份文件解析只识别有限标签、回写稳定字段；bootstrap 完成标记写入 transcript，compaction/reset 使其失效。
- **skills**：是规则对象最完整实现。多优先级根目录合并、同名按来源覆盖，产出有硬上限的 `<available_skills>` 目录（只放元数据，正文按需读取）；显式 `$skill` 引用走另一条请求前展开路径。模型可见性与运行时可用性两套面，`disable-model-invocation` 只从正常目录隐藏、授权引用仍可调。Skill Workshop 提供待审写入与 apply。
- **prompt 模板与 slash 资源**：模板从 agent `prompts/`、项目 `.openclaw/prompts/` 与显式路径加载，参数替换单次展开、无递归；`command-dispatch: tool` 的 skill 命令可绕过模型直投工具。
- **插件 hooks 与 context engine**：`before_prompt_build`、`agent_turn_prepare` 等 hook 可替换/追加系统提示词并影响工具面，但普通 hook 不自动获得工具执行授权；context engine 槽只选一个 engine，默认 legacy 透传消息并委托内置 compaction，非 legacy 可实现 assemble/compact/afterTurn 等并自带 quarantine/fallback。
- **模型可见结果与权威 transcript 分界**：prompt-only（skills 目录、hook context、多数 system prompt addition）、runtime carrier（hidden custom message，display:false）与 durable lifecycle（用户原文、compaction summary、skill snapshot、memory flush）三类变换分开；`systemPromptReport` 与 `/context` 是诊断投影，不等于最终 Provider payload。
- **compaction 与 memory flush**：compaction 是输入历史的明确重写边界（summary + 近期 tail 进模型，完整历史仍在 SQLite）；compaction 前可运行 silent memory maintenance turn 把未写事实追加到当天记忆文件。
- **本次未找到**：统一的"规则 schema + 命中器 + 统一编译"层（preset/lorebook/宏式引擎）；各规则来源各有 owner 与错误边界。

## 对话导出与分享

依据 [对话导出与分享调查笔记](../对话导出与分享/OpenClaw-对话导出与分享调查笔记.md)。导出路径四条相互独立、无共享管线，全部为静态确认（未运行 CLI/UI）。

- **消息内 `/export-session`（/export，owner-only）**：把持久化 transcript 活动分支渲染为自包含离线 HTML 阅读稿（base64 内嵌会话数据，带分支树、thinking、工具展示与 system prompt），写入工作区；`/export-trajectory` 与 CLI `openclaw sessions export-trajectory` 输出脱敏 JSONL 支持包（schema `openclaw-trajectory` v1），写入 `.openclaw/trajectory-exports/`，供调试/支持交付。
- **Control UI 会话页 `/export-session`**：本地执行、只把"当前已加载消息"下载为纯文本 Markdown（剥内部上下文与 thinking）。
- **原生应用 Export Transcript**：iOS/macOS 把当前视图消息导出为 Markdown 并经系统分享（macOS ⌘⇧E）。
- **口径差异**：同一命令名在渠道端与 Web 端是不同实现、不同内容口径（渠道端含 system prompt 与完整工具轨迹，Web 端仅正文 Markdown）；导出都是快照，无与源会话再同步语义。
- **内容边界**：只导出活动分支，不包含隐藏分支；轨迹导出做本地路径/secret 类清洗（尽力而为），HTML 导出刻意不脱敏；图片需以 base64 存在于 transcript 才真正内联显示（是否普遍携带未验证）。
- **未找到**：分享稿编辑器/预览工作台、会话整图/长图导出、远端公开页/受控链接分享、导出版本历史与撤销；会话 URL 是带鉴权的内部深链，不是公开分享面。控制面导出会话（如 CLI/ACP 代理时）只见 user 行并附说明。

## 界面与独特功能

### 聊天表面（Chat UI）

依据 [Chat UI 调查笔记](../Chat UI/OpenClaw-ChatUI调查笔记.md) 与 [消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)。四套表面都以 Gateway 会话与事件为远端事实来源，但各保留本地状态与恢复存储。

- **Control UI**：功能最完整的聊天工作台，支持多 pane/分屏/辅助面板与按会话保留的 pane 现场；Composer 支持 slash/skill 菜单、引用回复、附件、dictation/talk；草稿与附件分别按 Gateway owner 存浏览器 storage 与 IndexedDB；消息右键提供 reply/rewind/fork/copy；多会话经 sidebar 子树与 background task rail 呈现。
- **TUI**：单终端工作区，命令/选择器/快捷键为主入口，流式、scrollback（默认 180 component）与 run 协调由独立控制器处理；未找到与 Control UI 对应的事件消息级 rewind/fork 入口，也未找到跨进程 durable 草稿。
- **Apple 原生与 Android 原生**：iOS Chat Pro 用共享 SwiftUI 原生视图（Dashboard 经认证 WebView 打开 Control UI）；Android 是 Compose `ChatScreen`。两者的 Composer/草稿/outbox 在本地保存（Swift 内存 + ViewModel、Android Room/StateFlow）。
- **发送与恢复共同原则**：先保留用户输入，再用历史或带身份的运行事件确认交付；"已收到 ACK"与"已写入 canonical history"分开，不确定发送停在 unconfirmed/confirming/failed 而非静默重发；三套原生表面各自 outbox 由 canonical history 退休。
- **渲染管线**：Gateway 做显示投影（隐藏回复、预算、身份补全）；消息进入各客户端的 reducer 后由 thread builder/时间线装配为可见 turn。Control UI 用虚拟行 + 流式 Markdown 稳定前缀/尾部修复；TUI 用 pi-tui 有界 scrollback；iOS 用 ScrollView+LazyVStack、Android 用 reverse LazyColumn。渲染、滚动、富文本细节见 [消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)。
- **承载与安全边界**：普通 Markdown 是受限富文本（DOMPurify 白名单、无 iframe/script）；Canvas HTML 与 MCP App 走带 sandbox/CSP/TLS/bridge 约束的独立 widget 承载面。渲染器范围内未找到 Mermaid/KaTeX 实际 renderer，也未找到 ACP 专用独立消息 renderer（均为"本次检查范围未找到"）。
- **未运行验证**：多窗口间临时 draft/scroll/focus 是否完整同步、各平台真实键盘/IME/视觉与无障碍表现均未验证；未证明浏览器 IndexedDB、Apple 数据库与 Android Room 之间同步未发送草稿。

### 应用界面基础设施

依据 [应用界面基础设施调查笔记](../应用界面基础设施/OpenClaw-应用界面基础设施调查笔记.md)。

- **形态**：Control UI（`ui/`，Lit + Web Awesome + @openclaw/uirouter）是主要 Web 表面并随 Gateway 同版本派发；macOS/iOS/Android/Linux companion 是各自独立客户端，只与 Gateway 协议共享，不消费 Control UI token/store；TUI 基于 pi-tui。
- **公共机制**：一个 `<openclaw-app>` 根装配 Context、Tooltip/Hovercard Provider 与 Shell；弹窗统一到 `openclaw-modal-dialog`（wa-dialog 适配层）与 modal top-layer；Toast 是单槽宿主（Modal 打开时移入其顶层）；主题为 8 家族 × 暗/亮，index.html 内联脚本首帧前置调色板防白屏。
- **偏好同步**：外观类偏好（theme/mode/accent/locale 等白名单）以服务端 config `ui.prefs` 为权威、localStorage 为镜像与离线暂存，跨窗口/跨设备收敛；其余偏好设备本地；布局折叠等形态有意不跨 tab 同步。
- **响应式与多入口**：Shell 以 JS/CSS 双断点适配、移动窄屏用 nav-drawer；同一前端经 URL 解析出 approval/question/terminal/desktop/dashboard 等"聚焦文档"，复用入口、省略壳 chrome。图片 lightbox、文件预览等公共内容交互以 modal 为壳。
- **无障碍/动画扩展**（静态确认基础，未运行审计）：skip-link、focus-visible、aria/role 语义、reduced-motion 分支等；未做 WCAG 合规结论。

### 独特功能机制

依据 [独特功能调查笔记](../独特功能/OpenClaw-独特功能调查笔记.md)。

- **ClawHub 分发与安装信任门（主链确认，静态，依赖外部 ClawHub 响应）**：`openclaw skills install`/`plugins install clawhub:` 等入口先取目标 release 的信任元数据，裁决为 clean 放行、blocked（恶意/拉黑/审核阻止）拒绝下载、review-required 要求 `--acknowledge-clawhub-risk` 显式确认；裁决随安装记录持久化，`update --all`/doctor 后续重新过门。聊天命令面不能代替本机确认（防经 Agent 诱骗安装）。
- **`openclaw doctor` 诊断-修复-迁移链（入口确认，工程机制）**：检查/修复按模块族拆分，顶层 doctor 命令按只读/`--fix`/非交互/`--lint --json` 驱动；完整 check→fix→verify 回合未逐条走查，故不进入用户功能统计。
- **暂缓项与仓库内部资产**：companion 语音/talk、Canvas/A2UI、boards/workboard、meeting-bot、fleet、projects/flows/tasks 等"新表面"本轮只到声明/入口层，未走主链；taxonomy.yaml、custodian-skills 与仓库根 `skills/` 是 QA 与维护 agent 资产，不是用户产品能力。
- 渠道/设备配对审批门归并在本汇总"渠道、设备节点与外部执行体"一节。

## 证据边界与遗漏

- **统一证据状态**：以上"主链确认（静态）"均来自当前代码快照的可执行调用关系复核，未运行构建、测试、Gateway、真实 Provider、真实 UI/原生设备或端到端会话。按各类目指南，未做运行验证不降低源码结构类结论；运行验证补充的是平台差异、外部依赖、时序、性能与交互质量等可观察结果。
- **来源笔记彼此限定的差异**：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md) 撰写时把媒体创作判为"本类目不适用/未找到独立主链"，而同日完成的 [媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md) 已建立图片/视频/音乐生成的任务化主链确认。本汇总以媒体创作笔记为准，媒体生成能力见相应小节。
- **"本次未找到"（限定于已读入口/范围，不作项目级绝对断言）**：通用消息就地编辑与按 id 删除 RPC；通用 sessions export/import RPC；统一跨进程后台 worker queue；独立媒体工作台/媒体历史树/跨会话资产库/媒体工程对象；board 级导入导出与模型侧 board 查询工具；分享稿编辑器、会话整图导出、远端分享链接与导出版本历史；普通 Agent 的 clone/import/export；通用规则 schema 编译器（preset/lorebook 层）；Mermaid/KaTeX 与 ACP 专用消息 renderer。
- **本轮没有调查/暂缓**：companion 语音与 talk、Canvas/A2UI、board/workboard、meeting-bot、fleet、projects/flows/tasks 等新表面的用户主链；ClawHub 市场/扫描/审核服务（仓库外）；各渠道插件的逐平台传输实现（以核心决定器与 Telegram 为例，未逐一核对约 20 个渠道）；voice-phone 桥接等外部展示声明。
- **当前证据无法确认的事项**：不同 Provider 的真实事件时序、并发容量下的端到端顺序、错误恢复与重启竞态、多客户端并发的跨表面一致性与安全对抗强度（配对传播、下载校验、prompt-injection framing）、各 UI 的实际视觉/焦点/无障碍/键盘表现、附件与媒体在真实模型请求中的字节与成本。以上均需运行或对抗验证，现有来源未覆盖。
- **声明与实现差异记录**：命令名同名异实现（`/export-session` 渠道端 HTML vs Control UI 端 Markdown）；"share a session" URL 实为鉴权内部深链；models.json 中 apiKey 常为来源 marker 而非明文；`session_message` 与 `chat`/`agent` 事件是不同投影面；compaction 前后模型可见历史与 SQLite 完整历史是不同事实。
- **外部依赖边界**：模型 Provider、hosted catalog、ClawHub、媒体 Provider/ComfyUI、消息渠道平台、推送服务、ACPX 外部 harness、设备本地能力均在仓库外或需真实服务；无外部服务时相关门 fail-closed（如 ClawHub 来源不可达不静默降级）。
- 运行验证补充的是特定环境下的可观察结果；测试文件存在、测试运行、黑盒验证与线上使用属不同证据层级，本汇总仅引用各来源静态确认的边界。

## 来源笔记索引

正文已给出各能力链接，文末集中列出纳入汇总的 17 份来源笔记：

- [仓库分布调查笔记](../仓库分布/OpenClaw-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/OpenClaw-对话请求与上下文调查笔记.md)
- [Chat UI 调查笔记](../Chat UI/OpenClaw-ChatUI调查笔记.md)
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
