# OpenClaw 对话导出与分享调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态源码阅读。搜索范围包括：CLI 与 in-chat 命令注册表（`src/auto-reply/commands-registry.shared.ts`、`src/cli/program/`、`src/commands/`）中的 export/backup/import/share 子命令；`src/trajectory/` 的轨迹导出实现；Control UI（`ui/src/pages/chat/`、`ui/src/pages/sessions/`）与 TUI（`src/tui/`）的导出/分享/截图入口；官方 iOS/macOS 共享应用（`apps/shared/OpenClawKit`）的 transcript 导出；以及会话与消息持久化模型（`src/config/sessions/`、`src/agents/sessions/`）。未运行 CLI、Gateway、TUI 或 UI。
>
> 调查范围：会话/消息如何被抽取出并固化为可交付内容（HTML、Markdown、JSONL 支持包），交付路径、内容口径与访问边界。排除：产品结构与设计基因；数据库 schema、整库备份（`openclaw backup`）、配置/Agent 迁移导入、审计活动导出（`openclaw audit`）与会议纪要（`openclaw transcripts`）等相邻能力只在交界处提及，不展开。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 是本地单操作者助手，本类目的能力落点分两类：把一次会话固化为**可读可传的本地交付物**，以及把会话+运行时轨迹打成**可交给维护者的脱敏支持包**。共存在四条相互独立、无共享管线的抽取→交付路径：

- 消息会话内的 owner-only 命令 `/export-session`（别名 `/export`）把持久化 transcript 渲染成**自包含 HTML 阅读稿**并写入工作区（阅读交付，含分支树与 system prompt，离线可用）。
- `/export-trajectory` 与 CLI `openclaw sessions export-trajectory` 把活动分支 transcript + 每轮运行的轨迹事件打成**脱敏 JSONL 支持包**，写入工作区 `.openclaw/trajectory-exports/`（数据交换/支持交付）。
- Control UI 会话页本地执行 `/export-session`，把**当前已加载消息**下载为纯文本 Markdown 文件。
- 官方 iOS/macOS 应用提供 “Export Transcript” 按钮（macOS 另配 ⌘⇧E），把当前视图消息导出为 Markdown 并经系统分享。

**未找到**：独立的分享稿编辑器/预览编排工作台、会话整图/长图导出、远端公开页或受控链接分享（Gist/站内快照等）、导出版本历史与撤销。会话 URL 只是带鉴权的 Control UI 内部深链，不面向第三方。

## 系统边界与总体调用链

会话持久化的事实源是本地 SQLite：per-agent DB（`agents/<agentId>/agent/openclaw-agent.sqlite`）存放 transcript 行，轨迹事件也在该库（`docs/tools/trajectory.md` 说明 live capture 不再写 session-adjacent JSONL sidecar）。导出端全部只读 transcript 行与轨迹行，在**操作者宿主的工作区**生成文件；聊天消息渠道里的导出命令由 Gateway 的 auto-reply 命令处理器执行，工具与文件写入同样发生在宿主。因此导出的数据边界 = 该 SQLite 中已持久化的活动分支 + 运行轨迹，而不是渠道聊天框里渲染出的内容。

两条 in-chat 命令都是 owner-only：处理器声明 ownerOnly 门禁，注册描述把 HTML 导出标为 “owner-only” 文件（`src/auto-reply/commands-registry.shared.ts:329-356`、`src/auto-reply/reply/commands-info.ts:279-302`），只有命令所有者（operator）能触发。这决定了导出的内容口径含 system prompt、工具 schema 与调用、轨迹等敏感材料。

## 1. 入口、用户目标与导出源

| 入口 | 目标 | 导出源 | 输出 |
|---|---|---|---|
| 消息会话 `/export-session [path]`（/export） | 个人阅读/本地留存，可再自行分发 | SQLite transcript 活动分支 | 单文件 HTML，工作区根或自定义相对路径 |
| 消息会话 `/export-trajectory [dir]`（/trajectory） | 调试复现、交给维护者的支持包 | transcript 分支 + runtime 轨迹事件 | `.openclaw/trajectory-exports/<name>/` 内 JSON/JSONL 集合 |
| CLI `openclaw sessions export-trajectory --session-key <key> ...` | 同上（可脚本化，指定任意存储会话） | 同上 | 同上 |
| Control UI 会话 `/export-session`（/export） | 会话文本留存 | 客户端内存中当前加载的实时消息 | 浏览器下载 `<chat-<assistant>-<时间戳>.md` |
| iOS/macOS “Export Transcript”（macOS ⌘⇧E） | 移动/桌面导出并系统分享 | 客户端 `viewModel.messages` | `.md`（macOS 存盘面板；iOS 临时文件→系统分享 sheet） |

in-chat 的 HTML 导出目标“当前活动会话”：`buildExportSessionReply` 先解析可选路径参数，再把会话入口解析为 store/agent，从 SQLite 读 transcript 行，组装会话数据并生成 HTML，最后经 fs-safe 的工作区写入口落盘（`src/auto-reply/reply/commands-export-session.ts:328-412`）。实现事实里默认文件名是 `openclaw-session-<sessionId前8位>-<时间戳>.html`；显式给出路径时覆盖同路径既有文件，省略路径时做冲突后缀（`-1`、`-2`…）避让（`commands-export-session-file.ts:13-30`）。

轨迹导出另有 CLI 版本。`openclaw sessions export-trajectory` 注册为 `sessions` 子命令并显式拒绝 `--all-agents` 等列表过滤（`src/cli/program/register.status-health-sessions.ts:429-462`），其 handler 解析单个 `--session-key`，读取对应 store 的 session 后调用共享导出核心（`src/commands/export-trajectory.ts:103-194`）。in-chat 版本并不直接写盘，而是组一条 `openclaw sessions export-trajectory --request-json-base64 ...` 的 exec 请求走审批通道执行（`commands-export-trajectory.ts:275-304`）。

## 2. 范围选择、内容口径与字段过滤

HTML 导出包含持久化 activity 分支上的全部条目：user/assistant/toolResult/bashExecution 消息、compaction、branch_summary、model_change、custom_message、label 等会话条目类型，并携带 `leafId`、`hasLeafControl`（`commands-export-session.ts:276-326`）。assistant 内容块按 text/thinking/toolCall 分解渲染；工具调用会匹配同 call id 的 toolResult 展示结果；system prompt 与工具名/描述/参数被一并嵌入会话数据（`commands-export-session.ts:352-377`）。若会话由 CLI/ACP 等后端运行时代理，持久化侧可能只有 user 行，回复会附加一条说明提示看后端 transcript（`BACKEND_DELEGATED_WARNING`，`commands-export-session.ts:43-89`）。

轨迹导出的事件口径记录在 `docs/tools/trajectory.md`：transcript 事件由活动分支重建（user/assistant 消息、工具调用与结果、compaction、model change、label、custom entries），runtime 事件覆盖 `session.started`、`trace.metadata`、`context.compiled`、`prompt.submitted`、`model.fallback_step`、`model.completed`、`trace.artifacts`、`session.ended`。会话语义上的“隐藏分支/非活动分支”在两者中都不包含——都只取当前 active leaf 的 branch。malformed transcript 行会被跳过并以警告汇总（JSON 行号）出现在回复或 manifest 中（`commands-export-session.ts:216-274`、`src/trajectory/export.ts` 的 warnings 汇总）。

Control UI 与原生应用的 Markdown 导出口径窄得多：只取消息的可见正文文本。Web 端抽取会先剥内部运行时上下文、inbound 元数据与思考标签（`ui/src/lib/chat/message-extract.ts:21-58`），原生端同样走 `visibleText`，且只导出 user/assistant 行（system 直接丢弃，见 `ChatTranscriptExporter.swift:93-102`）。

## 3. 附件、资源与离线封装

HTML 导出是强离线的自包含文件：会话数据以 base64 内嵌到 `<script id="session-data">`，marked.min.js、highlight.min.js 与模板 JS/CSS 全部由服务端拼接内嵌（`commands-export-session.ts:102-203`；vendor 资源在构建期生成），打开不需要网络。

模板对图片采用内联 data URL 渲染：user 图片块与工具结果的 image 块先过 MIME/纯 base64 校验再拼进 `<img src="data:...">`（`export-html/template.js` 的 `renderDataUrlImage`），非 data URL 的远端 markdown 图片会被展平。需要留意：图片只有以 base64 数据块存在于 transcript 内容时才会真正显示；持久化模型同时存在“managed media references”（`docs/web/control-ui.md` 记载图片以稳定 artifact id 引用），是否普遍携带可内联字节属未验证项。

Control UI 的 Markdown 导出不含任何附件（text-only）。原生应用导出的 Markdown 会把消息内联附件折叠成一行占位 `[attachment: 文件名]`，不复制文件本身，也未把附件放进取出的 Markdown（`ChatTranscriptExporter.swift:104-115`）。三处 Markdown 交付物都依赖阅读方自行解释 Markdown 语法与占位符。

## 4. 格式、schema 与往返能力

HTML 导出没有外置 schema，交付物即单文件静态页；内嵌数据是 base64 的会话 JSON。`docs/refactor/database-first.md` 明确指出该命令“只写独立 HTML 视图，不再从这些行重建或下载 session JSONL”，即没有面向重新导入的 JSON 导出通道。轨迹导出则有显式契约：`traceSchema: "openclaw-trajectory"` + `schemaVersion: 1` 打在 manifest 与每个事件行（`src/trajectory/types.ts`、`docs/tools/trajectory.md:92-99`）。轨迹包是“把轨迹物化出来交出去”的方向，官方未提供把它重新导入运行时恢复会话的路径，往返能力不适用。

## 5. 分享稿编辑、编排与预览

**本次未找到**面向导出的独立工作台。四条路径都没有先选消息/分支范围、再编辑/预览、最后生成的“分享稿”环节：HTML 与轨迹包是一次性生成，生成前后无 UI 预览（HTML 文件本身是最终交付物，双击即客户端渲染）；Control UI 与原生应用的 Markdown 导出是单键操作，直接产出文件。

## 6. 图片、HTML、PDF 与富内容生成

HTML 阅读稿是这类目中唯一的富内容再渲染器，`export-html/template.js` 承担全部离线渲染：Markdown 用定制 marked 渲染器（HTML 转义、链接/图片白名单处理，`safeMarkedParse` 与 renderers 段），代码块带高亮；工具调用按工具名做专用展示（bash 命令、read/write 文件路径与内容、结果输出折叠与行数显示等）；thinking 可折叠、工具输出可整体展开，另有排序树形侧栏、搜索与 Default/No-tools/User/Labeled/All 过滤，并通过 URL `leafId`/`targetId` 深链定位。导出模板有配套安全测试 `export-html/template.security.test.ts`（转义原始 HTML、MIME/纯 base64 校验、展平不安全图片与链接、属性转义等），渲染逻辑是静态确认过的可执行路径，视觉效果未运行验证。

**未找到**把整段对话渲染成 PNG/JPEG/PDF 的能力：Control UI、TUI、原生应用内搜索 export/screenshot 的产物均为测试截图或组件内临时文件，无面向对话的整图/长图管线。Android 的 `ChatWidgetExport.kt` 只把内联 widget（嵌在会话里的独立 web 内容）WebView 截图导出到剪贴板/Downloads，捕获对象不是对话列表，归入生成式输出边界，不记为本类目能力。

## 7. 生成历史、版本与持久化

四条路径都不产生可管理的导出版本历史：重新导出即覆盖（显式 HTML 路径）或生成新的时间戳目录/文件名，旧文件由操作者自行保管。`openclaw backup git`（整库级、operator 自建 Git 仓库、按表 JSONL + 提交历史）是唯一有版本概念的持久化对象，属于数据库整库备份边界，不属于会话分享交付物，此处仅作交集记录（`docs/cli/backup.md`）。

## 8. 分享载体、访问控制与撤销

**未找到**任何“创建对他人可访问对象”的能力：无 Gist/公开页/受控分享链接/站内快照，因此更新、撤销、过期、克隆等远端分享语义整体不适用。交付终点都是宿主本地文件；跨人传播依赖操作者用文件、邮箱或移动系统分享把文件带出去。

原生应用中存在两类系统级分享：iOS 的 transcript 先写临时目录再由 ShareLink sheet 交给其他 App（`apps/ios/Sources/Design/ChatProTab.swift:171-173,720-737`）；Android 每条消息长按提供 Copy/Share（`ACTION_SEND` 纯文本单条消息，`ChatMessageActions.kt:99-102,168-182`）。后者只分享单条消息文本，属于操作系统分享，不构成围绕对话建立的独立工作流。

Control UI 的会话深链（`/chat/<agent>/<slug>-<shortId>` 等，`docs/web/urls.md`）语法上有“share a session”的措辞，但所有路由都在 Gateway 鉴权之后，需要 operator 级登录/设备配对才能打开；它服务于书签与换端续聊，不是给访客的公开页面。`packages/session-url-contract` 只描述这套 URL 语法与 `/focus` 目标，没有 guest/token 语义。

## 9. 隐私、安全与内容治理

两条 in-chat 导出都是 owner-only，群聊场景对敏感结果另有处理：`/export-trajectory` 在群聊找不到私有 owner 路由时直接拒绝，找到则把审批与结果私有投递给 owner，群内只回简短 ACK（`commands-export-trajectory.ts:73-96`、`docs/tools/exec-approvals-advanced.md` 的敏感 owner-only 群命令规则）。审批提示明说轨迹包可含 prompt、模型消息、工具 schema 与结果、运行时事件与本地路径，并给出“按秘密对待、分享前审查”的指引（`commands-export-trajectory.ts:99-115`）。HTML 导出**不脱敏**——它刻意含 system prompt、工具 schema 与轨迹分支，敏感性与轨迹包同级但无提示文案；回复只回路径与统计，不回正文。

轨迹导出是唯一做内容清洗的路径：导出前对事件、manifest 与各 JSON/文本文件执行路径与工具载荷清洗——本地工作区路径替换为 `$WORKSPACE_DIR`，检测 home/state 路径与 secret-like 字段，连对象键名也做工具载荷清洗（`src/trajectory/export.ts:806-919`，配合 `sanitizeDiagnosticPayload`/诊断支持包清洗函数），文档另外列明会移除图片数据与已知 secret 字段并声明“redaction 是尽力而为”。HTML 模板端到端的安全性由渲染端转义而非内容清洗承担。

## 10. 性能、失败恢复与测试

轨迹导出设了明确的规模上限：会话文件 50 MiB、导出 runtime 事件 200,000、总事件 250,000（`src/trajectory/export.ts:88-91`），单事件行截断 256 KiB（`src/trajectory/paths.ts:12`），live capture 为滚动窗口 10 MiB。路径全部经 fs-safe 的 root 约束（防符号链接逃逸、目录必须落在工作区内），冲突文件名自动后缀避让、显式路径覆盖。HTML 导出未发现同样的体积上限，超大会话或内嵌大字节图片会整体进单文件，属未验证的极端场景。

覆盖情况：HTML 导出与模板各有测试（`commands-export-session.test.ts` 覆盖路径越界/覆盖语义/后端代理警告，`template.security.test.ts` 覆盖转义与清洗），轨迹导出有大规模单测（`src/trajectory/export.test.ts`、`command-export.ts` 的 CLI wrapper 测试），Control UI 与原生端各有导出单测（`ui/src/pages/chat/export.test.ts`、`ChatTranscriptExporterTests.swift`）。

## 11. 设计取舍与已确认边界

同一命令名 `/export-session`（含 `/export` 别名）在消息渠道与 Control UI 里是两个不同实现、两种内容口径：渠道端产出含 system prompt 与完整工具轨迹的离线 HTML，Web 端只下载已加载消息的正文 Markdown。用户从不同入口触发会得到性质不同的产物，需要按入口区分，不能按命令名混为一谈。

导出即快照是统一取向：轨迹包含时间戳目录、HTML 默认唯一文件名、Markdown 文件名带生成时间，都没有“与源会话联动/再同步”的语义；共享、版本与撤销不构成产品内工作流，交付后的传播完全外置到操作者。轨迹导出是调试导向（`docs/tools/trajectory.md` 明言 bundles are for support and debugging, not public posting），不是研究数据或规范化公开对话集的发布通道。

## 12. 未验证事项

- 未运行任何命令与 UI。HTML 阅读稿的分支导航、搜索过滤、折叠、图片显示与整体视觉未在浏览器观察验证；markdown/code 渲染保真只能按模板代码推断。
- HTML 导出中图片是否真实出现，取决于持久化 transcript 是否携带 base64 字节；若普遍是 artifact/media 引用，图片区会静默不渲染。此项未验证。
- Control UI 与原生应用的导出基于“当前已加载消息”，客户端 transcript 的实际加载窗口（是否整会话、是否有上限）未追踪到边界，不能断言导出等于完整会话。
- `/export-session` 在群聊渠道的回复投递是否走私有 owner 路由未逐一追踪（文档只把该规则点给了 exec 审批类命令），仅确认命令本体是 owner-only。
- 未运行规模化导出（大会话 HTML 的体积、内存与浏览器打开表现）验证。

## 关键源码索引

- `/export-session` 命令定义与 owner 门禁：`src/auto-reply/commands-registry.shared.ts:329-342`、`src/auto-reply/reply/commands-info.ts:279-288`
- 会话 HTML 导出主链：`src/auto-reply/reply/commands-export-session.ts:328-412`；写盘与路径规则：`src/auto-reply/reply/commands-export-session-file.ts:45-70`
- 离线阅读模板：`src/auto-reply/reply/export-html/template.html`、`src/auto-reply/reply/export-html/template.js:1357-1476`；安全测试：`src/auto-reply/reply/export-html/template.security.test.ts`
- 轨迹导出核心：`src/trajectory/export.ts:1228-1413`；CLI 命令：`src/commands/export-trajectory.ts:103-194`、`src/cli/program/register.status-health-sessions.ts:429-462`
- in-chat `/export-trajectory`（exec 审批 + 群聊私有路由）：`src/auto-reply/reply/commands-export-trajectory.ts:52-115`
- Control UI Markdown 导出：`ui/src/pages/chat/export.ts:10-39`；消息文本抽取：`ui/src/lib/chat/message-extract.ts:21-122`；绑定与派发：`ui/src/pages/chat/chat-pane-lifecycle.ts:444-445`、`ui/src/pages/chat/chat-commands.ts:393-396`
- 原生应用 Export Transcript：`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTranscriptExporter.swift:6-163`；macOS 调用：`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatWindowShell.swift:517-524`；iOS 调用与分享 sheet：`apps/ios/Sources/Design/ChatProTab.swift:720-737`
- 功能说明文档：`docs/tools/trajectory.md`、`docs/tools/slash-commands.md:174-178`
