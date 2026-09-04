# OpenClaw Chat 调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：综合已完成的 OpenClaw 单项目笔记，并补读源码确认端到端主链骨架
>
> 调查范围：端到端聊天概览与专项导航；不放产品结构与设计基因
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 是单操作者私人 AI 助手：本地 Gateway 是会话、工具、事件与渠道连接的控制平面，Telegram、WhatsApp、Slack、Discord 等消息渠道承担日常终端聊天面，另有 Control UI、TUI、iOS/Android companion apps 作为自有界面。一次可见对话由两条前端入口之一发起——自有界面经 Gateway 协议 RPC，渠道消息经渠道适配与 auto-reply 管线——随后在同一个 reply run 主链上汇合：Gateway 完成准入与 ACK 后把 turn 交给脱离 RPC 生命周期的 dispatch，嵌入式 Agent 运行器从 per-agent SQLite 恢复 transcript、拼装历史与上下文并驱动 Agent Core 工具/Provider 流式循环，assistant 结果经同一 transcript 追加路径落库，再分别投影为实时 chat/agent 事件和持久 session.message 供表面显示。

聊天体系有四个贯穿性分层（详见专项笔记，此处只给骨架）：**会话与消息层**把逻辑会话（sessionKey）与 transcript generation（sessionId）分离，per-agent SQLite 是消息唯一事实源，活动路径与 FTS 是可重建投影，分支、reset、rewind、fork 通过轮换 generation 保留历史；**请求与运行层**把「ACK 不等于持久化」贯彻到底，用户 turn、Agent 内存消息、live chat payload 与已提交 transcript 是四套不同频率的投影面；**显示层**由 Gateway 显示投影与各客户端 timeline 组装构成，控制消息、工具卡、thinking 与真实聊天气泡分开建模；**交付层**的导出全部固化为操作者本机文件，没有对外的分享链接或服务。

## 产品表面与系统边界

- **自有聊天表面**共有四个实现层：浏览器 Control UI（功能最完整的工作台，支持多 pane 分屏与后台任务 rail，与 Gateway 同版本捆绑派发）、终端 TUI（单工作区、命令与选择器为主入口）、共享 SwiftUI Chat UI（iOS Chat Pro 原生页面，Dashboard 另走认证 WebView）、Android Compose Chat UI（独立原生实现）。四者都以 Gateway 会话与事件为远端事实源，但草稿、滚动与临时附件是本地状态，不构成跨平台共享状态。工作台结构与工作流见 [OpenClaw Chat UI 调查笔记](<../Chat UI/OpenClaw-ChatUI调查笔记.md>)。
- **消息渠道是外部系统拥有的聊天面**。`extensions/` 下的 telegram、whatsapp、slack、discord 等渠道扩展把外部消息框中的对话映射到 Gateway 会话，只做传输、动作编码与回复投递；渠道 App 的 UI、账号与线程语义归各平台所有，OpenClaw 不拥有这些客户端的渲染面。
- **执行边界**：浏览器、CLI、TUI 与 companion apps 都不与模型 Provider 直连，模型请求只在 Gateway 所在主机的嵌入式 Agent 运行器内发起；会话、工具、媒体、附件与渠道连接由 Gateway 与本地 SQLite 持有。真正持有 Agent runtime 的还有 ACP harness 等外部执行体，其会话语义由外部系统拥有，见 [OpenClaw 外部执行体与应用协作调查笔记](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md)。
- 仓库规模与模块分工（`src` 承担 Gateway/会话/工具/CLI 主链，`extensions` 为渠道与能力扩展，`ui`/`apps` 为自有表面，`packages` 为共享协议与 SDK）见 [OpenClaw 仓库分布调查笔记](../仓库分布/OpenClaw-仓库分布调查笔记.md)。

## 端到端聊天主链

把两条前端入口合一后，主链如下（只保留交接点，行号为快照依据；各环节完整机制在对应专项笔记）：

```text
输入
  ├ 自有界面（Control UI/TUI/CLI/companion）：WebSocket RPC chat.send
  └ 渠道消息（extensions/telegram 等）-> src/channels turn 生命周期
        -> auto-reply dispatch（src/auto-reply/dispatch.ts:385,472）
Gateway chat.send 准入与 ACK（src/gateway/server-methods/chat-send-handler.ts:38-303）
  -> 规范化/幂等/会话解析/附件预处理/abort 注册 -> 返回 {runId, started}
  -> detached dispatch（chat-send-agent-dispatch / reply-dispatch）
  -> dispatchReplyFromConfig -> 构造 FollowupRun（src/auto-reply/reply/dispatch-from-config.ts:24）
  -> runEmbeddedAgent：session lane -> global lane -> prepared runtime
  -> attempt：从 per-agent SQLite 恢复 transcript
       -> 历史清理/上下文拼装/system prompt/工具目录/预算预检
       -> AgentSession.prompt -> Agent Core loop -> Provider stream
            （packages/agent-core/src/agent-loop.ts:226-613）
       -> 工具调用/继续回合/压缩/fallback/终态恢复
  -> 输出三层回写：
       Agent Core 内存消息 -> embedded subscriber -> server-chat 投影（src/gateway/server-chat.ts）
       SessionManager.appendMessage 追加带 parentId 的 assistant entry 落 SQLite
       SQLite commit 后广播 session.message / sessions.changed
  -> 表面收尾：chat.history/chat.startup + 实时事件 + 显示投影 -> 气泡/tool/流式渲染
       渠道侧另有 reply payload 回投渠道
```

**提交与 ACK。** 终端表面的每次发送由 Gateway 的 `chat.send` 主链负责：请求先规范化与解析会话，准入阶段写 pending dedupe、占用同会话运行槽并注册 abort owner；ACK 前同步确认身份、幂等、附件与取消边界，ACK 后把 turn 交给脱离 RPC 生命周期的 dispatch。渠道消息不走这条 RPC 面，而是经渠道 turn 生命周期汇入同一 auto-reply dispatch，因此两类输入的后续执行共享同一 admission、运行注册与终态屏障。准入、队列与并发语义见 [OpenClaw 对话请求与上下文调查笔记](../对话请求与上下文/OpenClaw-对话请求与上下文调查笔记.md)。

**上下文与执行。** run 解析有效 session target 后先在 session lane 串行、再入 global lane；单次 attempt 从 SQLite transcript 恢复 active branch，按顺序完成历史 sanitize、预算预检、Context Engine assemble（如启用）、system prompt 组装与工具目录构建，再调用 AgentSession.prompt 进入 Agent Core 的工具/回合循环。模型引用经模型目录解析为 provider/model 与请求凭据，Provider 协议差异由协议 adapter 承担。上下文来源、预算压缩、模型交接、停止重试与队列细则见对话请求与上下文专项，模型目录与渠道管理见 [OpenClaw LLM 渠道管理调查笔记](../LLM渠道管理/OpenClaw-LLM渠道管理调查笔记.md)，工具循环语义见 [OpenClaw Agent 工具调查笔记](../Agent工具/OpenClaw-Agent工具调查笔记.md)。

**持久化与可见回写分离。** 正常的 assistant 回合由运行器经 SessionManager 写入带 parentId 的 transcript entry，Gateway 不重复 append；Gateway 只负责把 live 回复、工具状态与 agent 事件投影给订阅者（文本按 75ms 节流、乱序文本发 replace）。非 Agent 回复、abort partial、媒体补写与 source reply mirror 各走专门的 finalization 分支以维持幂等。读取侧，`chat.history`/`chat.startup` 从活动 transcript 取逻辑消息序号，Gateway 先做显示投影（隐藏控制回复、截断、`__openclaw` 身份补全），再交给各表面组装成 timeline。消息生命周期与读取分页见 [OpenClaw 会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)，显示投影与客户端渲染见 [OpenClaw 消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)。

## 核心对象与状态权威

| 对象 | 语义与权威位置 |
|---|---|
| 逻辑会话（session key 寻址）与 transcript window（session id/generation） | `session_nodes.entry_json` 是逻辑记录事实源，`session_windows` 拥有 transcript generation；两者在 per-agent SQLite 中，`agents/<agentId>/agent/openclaw-agent.sqlite` |
| 消息与控制 entry | transcript 内带 id、parentId、时间戳的追加型事件；标准 message 外还有 compaction、reset、model_change、label、custom 等控制 entry，不等于聊天气泡 |
| 活动路径与 FTS | 从 transcript 事件派生的可重建投影，非另一份消息主库；dirty 时由 reconcile 自愈 |
| 运行身份 | 一次发送在 Gateway（idempotencyKey/clientRunId）、reply operation、Agent Core（runId/activeRun）、session lifecycle row、chat event state 各有一层身份与状态，彼此通过 owner claim/lifecycle generation 关联 |
| 模型与凭据 | 运行时 ModelRegistry 目录快照是「有哪些模型、谁发凭据」的单一来源；会话保存 provider/model 引用，进程生命周期绑定不进入序列化形状 |
| 可见消息与运行快照 | 显示 message、in-flight run snapshot、optimistic echo 都是客户端或 Gateway 的投影字段，不替代已提交的 parent-linked transcript |

消息事实源、运行状态权威与各投影层的归属，按层分见会话与消息管理、对话请求与上下文、消息渲染器三个专项。

## 专项导航

| 专项 | 在本类目中的职责 | 笔记 |
|---|---|---|
| 会话与消息管理 | 逻辑会话/transcript generation 数据模型、SQLite 事实源与派生索引、创建/列表/历史分页/搜索、rewind/fork/switch/reset/删除归档/恢复、会话级 agent/模型/渠道/工具绑定 | [会话与消息管理](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md) |
| 对话请求与上下文 | chat.send 准入与 ACK、历史恢复与上下文拼装、预算/压缩、Provider 交接与流式事件、终态回写、停止/重试/队列/并发、restart recovery | [对话请求与上下文](../对话请求与上下文/OpenClaw-对话请求与上下文调查笔记.md) |
| Chat UI | Control UI/TUI/共享 SwiftUI/Android Compose 的工作台、会话导航、Composer 与草稿、发送反馈、消息操作、多会话与恢复 | [Chat UI](<../Chat UI/OpenClaw-ChatUI调查笔记.md>) |
| 消息渲染器 | Gateway 显示投影、各客户端把历史与实时事件收敛为 timeline 项、文本/thinking/工具/媒体/Canvas 渲染与滚动边界 | [消息渲染器](../消息渲染器/OpenClaw-消息渲染器调查笔记.md) |
| 对话导出与分享 | HTML 阅读稿、脱敏 JSONL 轨迹包、Control UI/iOS Markdown 导出；四路均产本机文件，无分享稿工作台与公开链接 | [对话导出与分享](../对话导出与分享/OpenClaw-对话导出与分享调查笔记.md) |
| LLM 渠道管理 | 逻辑 Provider/协议 adapter/模型目录+凭据三层、会话模型引用到渠道实例的解析主链、auth profile 轮换与模型 fallback、models.probe | [LLM 渠道管理](../LLM渠道管理/OpenClaw-LLM渠道管理调查笔记.md) |
| Agent 角色 | agents.entries 与 workspace 文件组合、路由/session key 命名空间、角色到 prompt/模型/工具/skill/subagent 授权的生效链 | [Agent 角色](../Agent角色/OpenClaw-Agent角色配置调查笔记.md) |
| Agent 工具 | 运行时工具面构建、策略过滤、MCP 适配、审批、Agent Core 工具循环与 toolResult 回注 | [Agent 工具](../Agent工具/OpenClaw-Agent工具调查笔记.md) |
| 外部执行体与应用协作 | Gateway 多表面接入、ACPX 外部 harness、openclaw attach、node.invoke、原生 ACP 反向控制 | [外部执行体与应用协作](../外部执行体与应用协作/OpenClaw-外部执行体与应用协作调查笔记.md) |
| 主动 Agent 与后台任务 | cron/heartbeat/webhook/后台 exec/detached subagent 的触发、执行、结果交付与重启恢复 | [主动 Agent 与后台任务](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md) |
| 检索增强与认知编排 | memory-core/memory-wiki/lancedb 插件槽、Markdown+session 语料、召回注入、Active Memory 子 Agent、dreaming 记忆晋级 | [检索增强与认知编排](../检索增强与认知编排/OpenClaw-检索增强与认知编排调查笔记.md) |
| 上下文编译与提示词工程 | workspace 指令文件、skills、prompt 模板、插件 prompt hook、context engine 与 compaction 交接、运行时上下文分流 | [上下文编译与提示词工程](../上下文编译与提示词工程/OpenClaw-上下文编译与提示词工程调查笔记.md) |
| 生成式输出与运行时 | 聊天输出 G0/G1 基座、show_widget/Canvas 文档、session board widget（G2–G3）的对象身份与沙箱 | [生成式输出与运行时](../生成式输出与运行时/OpenClaw-生成式输出与运行时调查笔记.md) |
| 媒体创作 | image/video/music 三个生成工具、后台任务、媒体托管与 Artifact、完成事件唤醒原会话回流 | [媒体创作](../媒体创作/OpenClaw-媒体创作调查笔记.md) |
| 应用界面基础设施 | Control UI 应用级浮层/toast/主题/状态所有权等公共设施；不与聊天主链展开，只记录交界面 | [应用界面基础设施](../应用界面基础设施/OpenClaw-应用界面基础设施调查笔记.md) |
| 仓库分布 | 规模统计与模块组织依据 | [仓库分布](../仓库分布/OpenClaw-仓库分布调查笔记.md) |

## 关键能力与已确认边界

- **分支与历史操作是主特征**：rewind、fork、branch switch、checkpoint restore 通过轮换 transcript generation 保留历史，leaf control 决定活动路径；普通追加、幂等键与 active-branch rebasing 保证并发写入安全。未找到面向用户的通用「就地编辑或按 id 删除单条已落盘消息」RPC，精确 rewrite 只用于受保护修复（会话与消息管理专项）。
- **发送与运行边界**：每会话串行、跨会话在容量内并行；queue/followup/steer/collect 覆盖运行中新消息；停止分 abort active/queued/worker 多层。发送方都把「收到 ACK」与「canonical history 已证明」区分，不确定交付停在 unconfirmed/confirming 供人工重试（对话请求与上下文、Chat UI 专项）。
- **上下文预算与压缩**：预检诊断与真正压缩分离；context overflow、自动压缩、compaction 后 continuation 都有专门恢复路径，legacy Context Engine 只做透传包装（对话请求与上下文、上下文编译与提示词工程专项）。
- **检索面分窄宽两条**：会话列表 search 只看 metadata；正文检索走 per-agent FTS5 `sessions.search`，只索引活动路径中 user/assistant 文本，dirty 时返回 indexing 而非旧行（会话与消息管理专项）。
- **导出即本机快照**：HTML/轨迹包/Markdown 导出均无与源会话联动、无导出版本管理；in-chat 导出是 owner-only 且含 system prompt 等敏感材料，轨迹包是唯一做内容清洗的路径（对话导出与分享专项）。
- **生成式输出有独立承载面但无完整资产线**：Canvas 文档与 session board widget 有独立身份、沙箱与能力授权；无媒体/图表的编辑工程与版本对象（生成式输出与运行时、媒体创作专项）。
- **未确认项以专项口径记录**：例如通用导出/导入 RPC、TUI 的 durable draft、可跨 window 同步的临时输入等，均在对应专项中标记为「本次未找到」而非项目级否定。

## 未验证事项

- 未运行真实 Gateway、真实对话、流式/中断/重试/队列；主链各交接点来自当前代码快照的静态路径与专项静态推断，未做运行验证。
- 未实测多表面同时打开时的运行状态、未读、session list 实时一致性；Control UI 多窗口、断线重连、event gap 与 Gateway restart recovery 的端到端行为未运行验证。
- 未验证不同 Provider 对文本/thinking/工具增量、媒体输入、abort 与超时的实际事件时序；也未连接真实渠道、MCP 服务、memory 插件或 ACP harness。
- 未运行大规模会话列表、长 transcript、FTS reconcile、媒体 round trip 与压缩恢复的基准或故障注入；崩溃、SQLite worker 失败与归档发布中断的恢复只能按代码路径判断。
- 视觉效果、键盘/IME/无障碍、响应式断点、终端与平台行为均按静态边界记录，未在目标环境中观察。

## 关键源码索引

- `src/gateway/server-methods/chat-send-handler.ts:38-303`：chat.send 准入、ACK 与 detached dispatch 主入口
- `src/gateway/server-methods/chat-send-admission.ts:48-563`：dedupe、会话工作准入与 abort owner
- `src/auto-reply/dispatch.ts:385,472`、`src/auto-reply/reply/dispatch-from-config.ts:24-113`：渠道与自有表面共用的回复管线入口
- `src/agents/embedded-agent-runner/run-orchestrator.ts`、`run-loop.ts`：prepared runtime、session/global lane 与 attempt 重试循环
- `packages/agent-core/src/agent-loop.ts:226-613`：Agent 回合/工具循环与 Provider stream 交接
- `src/gateway/server-chat.ts:652-1121`、`src/gateway/live-chat-projector.ts`：chat/agent 实时投影、节流与终态
- `src/agents/sessions/agent-session-base.ts:346-459`、`session-manager-entries.ts:128-170`：assistant/user 消息落 transcript
- `src/config/sessions/session-accessor.sqlite-transcript-write.ts`、`sqlite-entry-store.ts`：SQLite 事实源写入与 session row
- `src/gateway/chat-display-projection.core.ts:305-353`、`session-transcript-message.ts`：显示投影与单条消息边界
- `packages/gateway-protocol/src/schema/logs-chat.ts`、`sessions.ts`：聊天协议与会话公开契约
