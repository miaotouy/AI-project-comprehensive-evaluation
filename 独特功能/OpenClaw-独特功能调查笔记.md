# OpenClaw 独特功能调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：静态源码阅读。先以根 README、VISION.md、docs 索引与 showcase、gateway/channels/plugins/clawhub 文档、taxonomy 的 release profile 建立产品声明候选；再为核心候选按“入口 -> 状态/对象 -> 执行 -> 用户结果 -> 持久化或下一次触发”走查可执行路径：渠道 DM 准入与配对审批链（src/pairing、src/channels/message-access、Gateway RPC 与渠道插件）、ClawHub 安装信任链（src/infra、skills/plugins CLI）、doctor 修复命令族；全程未运行构建、测试、CLI、Gateway 或外部服务
>
> 调查范围：本次覆盖渠道 DM/设备准入与配对审批、ClawHub 第三方能力分发信任、doctor 修复链等候选的入口与主链；companion apps/节点能力、ACP 执行体、主动与后台任务、会话/消息/渲染/媒体/记忆/Skills/角色/工具等已建类目内容只做归并与回链；明确排除产品结构与设计基因
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 是一个以本机 Gateway 为控制平面的多渠道个人 AI 助手。去掉普通 Chat 与通用 Agent 底座后，本类目本轮确认两张可以走通主链的能力卡，其余产品声明大多已被既有类目闭环或属于仓库内部/外部资产。

| 候选能力 | 状态 | 定性 |
| --- | --- | --- |
| 渠道 DM 与设备准入的配对审批门 | `主链确认`（静态证据） | 安全/接入机制 + 单操作者人机工作流，可作主贡献候选 |
| ClawHub 分发与安装信任门 | `主链确认`（静态证据） | 第三方 skill/plugin 分发安全机制，依赖外部 ClawHub 注册表 |
| `openclaw doctor` 诊断-修复-迁移链 | `入口确认`（修复闭环未逐条走查） | 运维/工程机制，单独标注不混入用户功能统计 |
| 多渠道 IM、设备节点、ACP/attach、主动与后台任务、媒体生成、记忆、会话消息、渲染与 Chat UI、角色/工具/Skills | `归并已有类目` | 见既有笔记回链 |
| companion 语音/Canvas/会议/看板等项目表面 | `暂缓` | Canvas/Board 已归并生成式输出专项；语音、会议等主链仍未完整走查 |
| taxonomy.yaml、custodian-skills、skills 根目录 | 非用户产品能力 | 仓库 QA 与维护 agent 资产 |

两条主链共同刻画 OpenClaw 的产品辨识点：它把“谁能接触我的 Agent、谁能往本机装会改变 Agent 行为的代码”变成显式、可审计的准入与信任决策，而不是默认放开。前者是渠道/设备配对审批，后者是 ClawHub 安装前的发布信任判定。

## 介绍声明与候选盘点

### 候选来源

产品重复强调的声明集中在根 README、VISION.md 与 docs 索引：单操作者的本地 Gateway 控制平面；把助手带到 WhatsApp、Telegram、Slack、Discord、Google Chat、Signal、iMessage 等多消息渠道（渠道声明占 README“How it fits together”与安全节主体，安全节点名 `openclaw pairing approve`）；companion apps 与节点承担 voice、Canvas、camera、screen 与设备本地动作；skills、plugins 与 ClawHub 生态；安全模型的“配对审批、沙箱、doctor 修复链”。`taxonomy.yaml` 的 release profile 还给出同一套能力矩阵的关键词（channel access gates、device-and-node-pairing、plugin-trust、doctor、health-repair 等），作为候选与实现侧名称的对照锚点。

### 候选清单

| 候选 | 来源声明 | 核实路径与结果 |
| --- | --- | --- |
| 渠道 DM 接入与配对审批 | README 安全节、docs/channels/pairing、docs/gateway/security | 主链确认：配置策略 -> 入口决定 -> 请求/码落库 -> 审批 -> allow entry -> 下次准入（能力卡一） |
| 设备/节点配对与 setup-code | docs/channels/pairing 第二节、docs/nodes | 归并：设备配对、role/scope、升级审批链已在[外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)确认，本笔记只在能力卡一中保留与 DM 门共用的“显式准入”语义 |
| 多渠道消息网关（channel 传输） | README、docs/channels、docs/index | 归并：渠道作为外部控制/交互表面在外部执行体与应用协作笔记，会话/消息/线程映射在会话与消息管理及 Agent 角色笔记，渲染在消息渲染器与 Chat UI 笔记；传输细节属设计基因 |
| ClawHub skills/plugins 分发与信任 | README 插件句、docs/clawhub、VISION 插件段 | 主链确认：安装命令 -> release trust 判定 -> 阻止/风险确认 -> 落盘记录（能力卡二） |
| 插件体系（plugin SDK、facade-runtime、extensions、memory 插件槽） | VISION“Plugins & Memory”、docs/plugins | 归并/排除：面向插件的分层与边界是工程架构（设计基因）；可安装能力半面并入能力卡二；memory 插件槽决策已由[检索增强与认知编排调查笔记](../检索增强与认知编排/OpenClaw-检索增强与认知编排调查笔记.md)承接 |
| companion apps、设备本地动作（camera/screen/voice） | README、docs/platforms、docs/nodes | 归并：节点 invoke、capability、APNS、pending action 主链已在外部执行体与应用协作笔记 |
| voice/talk、Canvas、boards、meeting-bot、fleet、projects/flows/tasks 新表面 | docs/start/showcase、docs/nodes（audio/talk/voicewake）、taxonomy、src 目录名 | 暂缓/介绍候选：本次只确认入口与文档声明，未走主链（见暂缓节） |
| skills、custodian-skills、taxonomy.yaml、仓库内 skills 目录 | 根目录存在、docs/tools/skills、docs/AGENTS | 非用户功能资产：taxonomy.yaml 是成熟度记分卡输入，skills/custodian-skills 是本仓库维护 agent 的规则资产（见声明不符节） |
| `openclaw doctor` 修复链 | README、docs/gateway/doctor、docs/install/updating、AGENTS | 入口确认：命令族与修复契约存在，完整 check->fix->verify 闭环本次未逐条走查（能力卡三，工程机制） |
| ACP/Swarm/子 Agent、attach、原生 ACP 桥 | README、docs/tools/acp-agents、外部执行体笔记 | 归并：见 Agent 角色与外部执行体与应用协作笔记 |
| 定时任务/后台运行/steering | README（隐晦）、docs/automation | 归并：见[主动 Agent 与后台任务调查笔记](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md) |

## 已确认的独特能力

### 能力卡一：渠道 DM 与设备准入的配对审批门

状态：`主链确认`（静态证据）。标签：接入安全机制、人机与多 Agent 关系、单操作者默认。

**用户目标**：普通聊天机器人与通用 Agent 面对“陌生人来信/陌生设备接入”时要么全拒要么全开。OpenClaw 的目标是让单操作者对自己助手做“显式准入审批”：IM 私聊者与设备节点默认不接触 Agent，必须经操作者批准后才被允许，并把批准做成排队、列表、通知与一键放行的可操作工作流。

**入口与触发者**：入口有两类。DM 侧由未知发送者在 `dmPolicy: "pairing"` 的渠道账户上发私聊消息触发（README 与 docs 均声明这是 DM 渠道的默认策略）；设备侧由新设备用 setup-code/bootstrap token 发起配对触发。两者都由远端主体（未知发送者/新设备）启动，审批动作由操作者通过 CLI、Control UI 或配对渠道完成。

**事实对象**：

- 渠道侧配置：每个渠道账户有 `dmPolicy` 与 `allowFrom` 两项访问配置，各自兼容顶层与 `dm.*` 嵌套两种历史写法，前者取下列四值，后者列出显式允许的来源（`src/channels/plugins/dm-access.ts`）。
  - `pairing`：配置命中或配对存储命中即放行，未命中的发送者可发起配对申请
  - `allowlist`：只认配置命中
  - `open`：要求通配或显式命中
  - `disabled`：直接拒绝
- 审批事实：共享 SQLite 状态库记录挂起的配对请求与码，以及已批准发送者的 allow entry（`src/state/openclaw-state-schema.sql`）。
- 设备事实：设备配对请求、已配对设备与 token、角色与 scopes，生命周期归 Gateway 连接层（归并在外部执行体与应用协作笔记）。

**完整主链**（静态证据）：

1. 渠道插件收到私聊消息后先交给核心入口决定器，由它判定来者能否进入。决定器把配置里的显式允许来源（含访问组展开成员）与配对存储里的已批准名单合成两条准入路径，按当前策略取值取舍；两条路径都未命中、且该事件允许发起配对时，返回原因码 `dm_policy_pairing_required`（`src/channels/message-access/sender-gates.ts`、`src/channels/message-access/decision.ts`）。
2. 插件侧把这个原因翻译成“发码并拒绝本次消息”。以 Telegram 为例，准入封装对非群聊执行 DM 准入检查，未获准的发送者被交给 challenge 发行器，由它把带码回复发回聊天，准入函数随即返回 false，这条消息不会进入 Agent（`extensions/telegram/src/bot-handlers.inbound-authorization.ts`、`extensions/telegram/src/dm-access.ts`）。群聊不走配对，另有一道独立的 allowlist 门。
3. challenge 发行器经 SDK 层落到共享存储，在事务内写入挂起请求并返回新码，同一发送者的重复请求复用已有请求行（`src/plugin-sdk/channel-pairing.ts`、`src/pairing/pairing-store.ts`）。码是 8 位大写无歧义字符，请求 1 小时后过期，每个渠道账户最多保留 3 条挂起请求。回复给发送者的文案含“OpenClaw: access not configured.”、身份行、码与 `openclaw pairing approve <channel> <code>` 的批准提示（`src/pairing/pairing-messages.ts`）。
4. 操作者对挂起请求做批准或驳回。CLI 的 `openclaw pairing list/approve` 按码批准；Control UI 经 `channels.pairing.*` RPC 列出、批准或驳回，批准时可附通知，并可选把该发送者提升为第一个命令 owner（`src/cli/pairing-cli.ts`、`src/gateway/server-methods/channel-pairing.ts`、`src/pairing/command-owner.ts`）。批准把请求行从挂起表移除并追加进已批准名单，驳回只删除挂起请求、不写入该名单。
5. 批准生效后，同一发送者的下一条私聊重新走第 1 步的决定器，这次命中配对存储里的已批准名单，直接放行进入会话与 Agent 执行，结果回发到这条 DM。这项批准只赋予该发送者的 DM 访问权，群聊授权与命令 owner 权限仍由各自配置决定。

**持续性**：请求与批准都持久化在共享 SQLite（`channel_pairing_requests` / `channel_pairing_allow_entries`），跨 Gateway 重启生效；旧版 `*-pairing.json` 与 `*-allowFrom.json` 文件由启动迁移或 `openclaw doctor --fix` 导入 SQLite 后删除。运行态只读 canonical SQLite 行，不再合并 legacy 文件（docs/channels/pairing.md 与本快照的 SQLite 写路径一致）。

**主动性与取消**：该门没有后台调度面，只在入站时求值。超时与容量是自动收口手段（TTL、单账户挂起上限）；驳回、删除 allow entry、失效升级请求、过期码与 token 吊销是“撤销”面。设备升级 scope/role 不会静默扩大既有批准，而是新建挂起升级请求等待人工审批。

**人机与多 Agent 关系**：审批动作提供三套表面（CLI、Control UI 的 DM access queue、设备 setup-code/`openclaw devices` 系列命令）；发送者可见结果是“收到码并被告知等待 owner 批准”或批准后的“access approved”。命令 owner 引导把首次批准的发送者绑定为 privileged command/exec 审批的主体，是“谁有资格批准”的另一个状态对象（`commands.ownerAllowFrom`）。

**外部依赖与执行域**：决策核心、状态存储与审批 RPC 在本机 Gateway；消息传输、发送者身份解析与“把码发回去”的收发动作在每个渠道插件的传输域内完成；设备侧在 iOS/Android 等节点应用内完成 setup-code 输入。审批本身不依赖外部服务。

**安全与资源边界**：该门默认 fail-closed（未批准 = 消息不处理）；码不透明（请求 ID 是 sha256 派生，CLI 按码批准走另一字段，RPC 用不暴露码的请求 ID）；`open` 策略被收窄为仍需通配或显式条目；单账户并发挂起有上限以抑制骚扰；已批准表所在的 SQLite 被视为敏感状态。边界外事项：真实渠道的逐平台收发、码送达可靠性、升级/吊销向所有节点的传播本次未运行验证。

**独特性判断**：它把“渠道 allowlist 配置”这一通用事实升级成带生命周期对象的审批工作流（请求-码-批准-白名单-通知），并横跨消息渠道与设备两类主体，无法由既有“会话与消息管理”（只管已准入后的会话）或“Agent 工具审批”（只管单次工具调用）完整解释。与最接近的对比项（一般 IM bot 的固定 allowlist、单点 token 配对）的关键差别是“未知发送者会获得一次有 TTL 的申请机会，由 owner 显式决定，且批准持久化并驱动下一次准入”。

**证据强度**：
- 实现事实：策略四值与读取合并、决定器打分规则、请求落库与码生成/过期/上限、RPC/CLI 批准与驳回、approval 写入 allow entries、Telegram 插件的 challenge 与拒绝路径、文案格式化。
- 推断：各渠道插件共享核心决定器并各自实现 transport 端，未逐一核对每个渠道插件；基于 `listPairingChannels()` 按 `plugin.pairing` 声明收集渠道（docs 列出 discord/telegram/whatsapp/signal/slack 等约 20 个支持渠道）。
- 未验证：真实 Gateway 运行下多条渠道并发审批、码送达与过期竞态、Control UI 队列交互、升级请求与吊销向所有设备的传播。

### 能力卡二：ClawHub 分发与安装信任门

状态：`主链确认`（静态证据，依赖外部 ClawHub 注册表响应）。标签：外部 Agent 协议/扩展分发、信任治理机制。

**用户目标**：让用户（及其 Agent）能从第三方来源安装会改变 Agent 能力的 skill 与 plugin，同时不让恶意/未扫描发布物直接进入本机。它把“安装一个 prompt/工具集/插件”从普通包管理动作变成一次带发布信任裁决的安全决策。

**入口与触发者**：安装由用户或操作者在 CLI 发起，skill 走 `openclaw skills install`，plugin 走 `openclaw plugins install`。来源解析在本机 CLI 模块完成：skill 认 `@owner/<slug>` 形式与本机 skills 目录，plugin 以 `clawhub:` 前缀标识（`src/cli/skills-cli.ts`、`src/cli/plugins-cli.ts`）。Agent 与聊天渠道也能经 skills/plugins 两类 RPC 或 `/plugins` 命令进入同一裁决，聊天面无法完成 ClawHub 风险确认，命令会提示转到本机 CLI 执行。更新命令复用同一道门。

**事实对象**：安装信任门在裁决前读取目标 release 的 ClawHub 信任描述，据此把这次安装归入四档裁决之一（`src/infra/clawhub-install-trust.ts`）。信任描述字段与裁决取值如下：

| 对象 | 取值 |
| --- | --- |
| 信任描述字段 | `scanStatus`、`moderationState`、`reasons`、`blockedFromDownload`、`pending`、`stale` |
| 安装裁决 | `clean`、`blocked`、`review-required`、`review-recommended` |

安装侧的对象是 workspace 的 `skills/` 目录、共享 skills 目录与插件安装记录，记录保存来源与 spec（如 `clawhub:demo@1.2.3`）。

**完整主链**（静态证据）：

1. 安装命令先解析来源；来源为 ClawHub 时先取该 release 的信任元数据，再判断是否阻塞。阻塞判定集中在 `isBlockingClawHubTrust`：下载被禁止、扫描状态为 malicious、审核状态属阻塞类、原因列表含恶意项，任一命中即拒绝下载（`src/infra/clawhub-install-trust.ts`）。
2. 裁决结果决定三种出口：
   - `clean`：直接放行。
   - `blocked`（恶意、被拉黑或审核阻止）：拒绝下载。
   - `review-required`（存在风险 reason 或未扫描提示）：要求非交互确认 `--acknowledge-clawhub-risk`；缺少确认时以 `clawhub_risk_acknowledgement_required` 类错误中止，并给出“Install cancelled; rerun with --acknowledge-clawhub-risk”的提示文案（`src/cli/clawhub-risk-acknowledgement.ts`、`src/infra/clawhub-install-trust.ts`）。
3. 放行后把发布物安装或更新到目标目录或插件 registry，并把这次裁决随安装记录持久化，记录里留下裁决结论、扫描状态、审核状态、风险原因、检查时间与确认时间六项字段（`src/infra/clawhub-install-trust.ts`）。skills-sh 这类外部分发引用的安装包由 ClawHub resolver 解析成 commit 固定的 GitHub 源，再按同一流程安装。
4. 信任状态会带入后续生命周期：`openclaw update --all` 与 `plugins update` 重新过同一道门；doctor 发现配置引用的插件尚未安装或带信任警告时，给出一条附带 `--acknowledge-clawhub-risk` 的修复建议（`src/commands/doctor/shared/missing-configured-plugin-install.ts:59-64`）。

**持续性**：裁决结果随安装/更新记录持久化；不同发布形态的信任锚点不同（版本化 release 用精确 release 信任元数据）。运行证据方面，`plugins-cli.install.test.ts` 等测试断言了 source=clawhub 的记录形状、两个错误码与 risk 确认后的继续路径，但这些是测试行为，不是本调查的运行验证。

**外部依赖与执行域**：注册表、扫描、审核状态与“官方发布者免信任提示”均位于仓库外 ClawHub 服务；仓库内只负责裁决与安装门。无 ClawHub 时该门退化为不可达来源错误，不向本地静默降级。

**安全与资源边界**：恶意/被拉黑 release 直接拒绝，不依赖用户事后判断；风险 release 必须显式确认；聊天命令面不能代替本机确认，防通过 Agent 诱骗安装。边界缺口：信任裁决完全信任 ClawHub 返回的元数据形状，本次未验证其网络层与下载校验的对抗强度。

**独特性判断**：它把“插件市场”从目录浏览变成内建在本机安装链上的发布信任裁决，并把它接到 doctor 修复与更新链上。普通 Chat 客户端的插件安装、AstrBot 类消息插件的“插件计数/生态外部事实”都不含这一“先裁决再落盘、落盘后留信任记录、修复合入推荐”的产品闭环。

**证据强度**：
- 实现事实：裁决输入/输出模型、阻塞与风险判定函数、确认标志解析、错误文案、记录字段结构、CLI 命令与 flag 接线、测试断言的记录形状与错误码。
- 推断：实际下载/解包/写入插件 registry 的细节基于命令接线与测试证据归纳，未逐行核对安装执行器；ClawHub 服务端扫描与审核逻辑在仓库外。
- 未验证：真实 ClawHub 响应、tarball 安装、更新收敛与降级路径的运行行为。

### 能力卡三：`openclaw doctor` 诊断-修复-迁移链（工程机制，单独标注）

状态：`入口确认`。不计入用户功能统计，记录为运维/自愈机制。

**机制概述**：`openclaw doctor` 由顶层入口按模式驱动一族检查模块，修复点覆盖配置与状态的旧格式迁移、损坏或陈旧安装的修复、插件与渠道的 schema 漂移、网关服务漂移、授权与 SecretRef 形状、端口冲突与启动诊断，一个检查族对应一个模块（`src/commands/doctor.ts`、`src/commands/doctor-*.ts`）。这些模块共用一套修复契约，契约定义在渠道插件侧（`src/channels/plugins/doctor-contract-api.ts`）。顶层入口支持下列运行模式：

- 只读检查
- `--fix` / `--repair` 修复
- 非交互运行
- force
- `--lint --json` 输出稳定的机器可读结果（`src/commands/doctor-lint.ts`）

修复与验证另拆成 repair-sequencing 与 finalize-config-flow 两段编排（`src/commands/doctor/`）。安装或更新完成后，升级链调用 doctor 做一次 post-upgrade 探针；启动与配置失败的错误文本通常把 `openclaw doctor` 或 `openclaw doctor --fix` 作为下一步动作。

本次只复核了入口与分族结构，未对任一“检查 -> 修什么 -> 怎么验证已修好”的完整回合逐条走查，因此维持 `入口确认`。doctor 与 AGENTS/VISION 的“配置兼容性由 doctor 迁移承担”绑定，是 OpenClaw 把迁移与修复前置为第一方运维面的体现。

## 已归并到现有类目的能力

以下能力已被既有 OpenClaw 笔记完整承接，本类目不重写，仅回链：

| 能力 | 归并去向 |
| --- | --- |
| 设备节点（camera/screen/voice/APNS pending action）、ACPX 外部 harness、原生 ACP 反向桥、`openclaw attach`、Gateway 多表面控制链 | [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md) |
| 会话/消息/分支的 SQLite 事实源与恢复、渠道地址与 conversation 映射 | [会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md) |
| cron/automations、heartbeat、hooks、后台 exec、detached subagent、结果交付与重启恢复 | [主动 Agent 与后台任务调查笔记](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md) |
| 记忆插件槽、Markdown/session corpus、`memory_search`、Active Memory、Memory Wiki、dreaming | [检索增强与认知编排调查笔记](../检索增强与认知编排/OpenClaw-检索增强与认知编排调查笔记.md) |
| 图片/视频/音乐生成工具主链、异步任务与 Artifact 回流 | [媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md) |
| workspace 文件、skills 加载/目录/`$skill`、prompt hooks、context engine 与 compaction | [上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/OpenClaw-上下文编译与提示词工程调查笔记.md) |
| Agent roster、路由绑定、workspace/身份/记忆边界、Skill snapshot | [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md) |
| 工具装配、MCP 投影、审批与执行域、沙箱 | [Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md) |
| 多渠道消息、群聊/线程路由与多 Agent 路由 | [消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)、[Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md) |
| Control UI/TUI/移动 app 聊天与流式渲染 | [Chat UI 调查笔记](<../Chat UI/OpenClaw-ChatUI调查笔记.md>)、[消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md) |
| 单操作者本地 Gateway 的“多表面控制平面”总述 | [外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)（多表面连续性属产品架构，不另计数） |
| 插件分层与插件 SDK/门面、`extensions/` 边界、memory 插件槽 | 工程架构（设计基因，排除）；用户可见半面并入能力卡二 |

## 声明不符、外部依赖与暂缓项

- **维护侧资产**：`taxonomy.yaml`、`custodian-skills/` 与根 `skills/` 目录服务于本仓库自身的维护与评分。`taxonomy.yaml` 是成熟度记分卡（Maturity scorecard）的输入，按子系统、功能、平台三级描述 QA 与发行成熟度，编辑规则见 `qa/maturity-scores.yaml` 与 docs 中的记分卡说明；`custodian-skills/` 与根 skills 目录则是维护本仓库时使用的 agent 规则资产。这些资产的作用域是仓库维护与成熟度评分，不驱动用户可见行为。
- **ClawHub 市场、skills.sh、独立 `clawhub` CLI 位于仓库外**：本仓库持有的是安装与信任裁决主链（能力卡二）；市场数据、扫描与审核在 clawhub.ai。`clawhub` standalone CLI（发布/迁移发布物）不在本仓库内实现。
- **部分“新表面”只到声明与入口层**：companion 语音/talk、A2UI、会议、fleet、projects/flows/tasks 等目录和文档说明存在入口或插件声明，但本次未走用户主链，标为暂缓或介绍候选，不作为统计依据。Canvas 文档与 session board widget 已由 [生成式输出与运行时调查笔记](../生成式输出与运行时/OpenClaw-生成式输出与运行时调查笔记.md) 走查，不再列入本专项暂缓项。
- **`claws`（Claw 包安装/导出）命令挂在实验开关下**（CLI 注册处按 `isExperimentalClawsEnabled()` 过滤，`src/cli/argv.ts`）。其 add/remove/update/export 与 provenance 机制按 [Agent 角色配置调查笔记](../Agent角色/OpenClaw-Agent角色配置调查笔记.md) 只作为独立兼容边界记录，本次不提升为主链候选。
- **voice-phone 桥接（Vapi 等）、实时语音、APNS 唤醒**依赖外部电话/推送服务，属展示与社区集成声明，无本仓库独立主链证据，本次不调查不计数。
- **未找到的例外说明**：本笔记没有声称上述目录中的模块“不存在”或“无效”；只说明它们没有被本次独特功能专项走查。设备节点能力（camera/screen/voice 的节点执行域）已在外部执行体笔记内确认，不在此重复。

## 对特色贡献统计的影响

- 两张能力卡达到 `主链确认`（静态证据）：渠道 DM/设备配对审批门、ClawHub 分发与安装信任门。二者都属于安全/接入/分发机制；按类目规则它们可以进入统计，但应与用户可见创作/协作特性区分标注，也可按“机制单列”处理，不并入一个笼统总分。
- doctor 修复链维持 `入口确认`，作为工程/运维机制单独记录，不进入贡献统计。
- 其余候选以“归并已有类目”收口，不新增贡献条目；companion 语音、A2UI 等暂缓项在完成专项前不进入统计，Canvas 文档与 session board widget 归入生成式输出专项。

## 未验证事项

- 真实 Gateway 运行下的多渠道 DM 配对并发、码过期竞态、Control UI 审批队列与逐平台挑战消息送达；设备升级请求/吊销向所有节点与渠道的传播。
- ClawHub 真实注册表响应、tarball 安装落盘、release trust 的下载校验强度、官方发布者免提示判定、`update --all` 收敛行为。
- doctor 任一“检查-修复-验证”完整回合的运行行为与 `--fix` 对各旧状态的实际迁移效果。
- companion 语音/talk、A2UI、meeting-bot、fleet、projects/flows/tasks 等新表面的用户主链；telegram `/pair`（device-pair 插件）、trusted-CIDR 自动放行等配置路径的真实行为。Canvas 文档与 session board widget 的静态主链已在生成式输出专项确认，其运行效果仍未验证。
- 各渠道插件的 DM 门与消息渲染差异无法在静态阅读中全量覆盖；本次以核心决定器与 Telegram 为例，未逐一核对约 20 个支持渠道插件的传输端实现。

## 关键源码索引

- 配对策略与状态：`src/channels/plugins/dm-access.ts`；`src/pairing/pairing-store.ts`；`src/state/openclaw-state-schema.sql`
- 准入决定核心：`src/channels/message-access/sender-gates.ts`、`src/channels/message-access/decision.ts`、`src/channels/message-access/runtime.ts`
- 审批 RPC 与 CLI：`src/gateway/server-methods/channel-pairing.ts`、`src/cli/pairing-cli.ts`、`src/pairing/pairing-messages.ts`
- 渠道插件侧配对（以 Telegram 为例）：`extensions/telegram/src/dm-access.ts`、`extensions/telegram/src/bot-handlers.inbound-authorization.ts`；SDK 发行器与适配契约 `src/plugin-sdk/channel-pairing.ts`、`src/channels/plugins/pairing.types.ts`
- ClawHub 信任门：`src/infra/clawhub-install-trust.ts`、`src/cli/skills-cli.ts`（risk 确认 flag 与安装接线）、`src/cli/plugins-cli.ts`、`src/cli/clawhub-risk-acknowledgement.ts`；测试侧断言记录形状与错误码见 `src/cli/plugins-cli.install.test.ts`、`src/cli/skills-cli.commands.test.ts`
- doctor 修复链：`src/commands/doctor.ts`、`src/commands/doctor-lint.ts`、`src/channels/plugins/doctor-contract-api.ts`、`src/commands/doctor/repair-sequencing.ts`、`src/commands/doctor/finalize-config-flow.ts`
- 候选声明锚点（文档）：`docs/channels/pairing.md`、`docs/gateway/security/index.md`、`docs/clawhub/cli.md`、`docs/gateway/doctor.md`、`docs/nodes/*`；仓库内部资产声明 `taxonomy.yaml`、`docs/AGENTS.md`（maturity scorecard）
