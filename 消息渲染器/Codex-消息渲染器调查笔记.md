# Codex 消息渲染器调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c9750d7f50052b29f53def02b5cf2160ae49a3d9`（分支：`main`）
>
> 调查方式：只读源码静态梳理 app-server 通知到 TUI HistoryCell 的数据流、流式控制器、Markdown 写入器、缓存与终端布局；未运行 TUI，未在真实终端观察渲染结果
>
> 调查范围：`codex-rs/tui` 的终端消息渲染，包括用户/助手/推理/工具/计划 cell、流式提交、Markdown 与代码高亮；导出 sink、Web 前端和桌面端渲染不在本仓库范围内
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的消息渲染器不是 DOM 或组件树，而是“app-server 事件 → `HistoryCell` → ratatui 行”的终端管线。渲染输入是协议层的 thread、turn、item 与增量通知；输出是带超链接元数据的逻辑行，最终写入终端回滚区或自有备用屏幕缓冲。

关键事实：

- **流式显示分为稳定区和活动尾部**：只有以换行结束的源码才进入稳定队列，未闭合的行留在可变的尾部或预览中，避免表格和代码围栏在增量过程中反复变形。
- **提交按自适应节流**：`Smooth` 模式每个 tick 提交一行，队列积压超过阈值后进入 `CatchUp` 批量排空；阈值带迟滞，避免在边界附近来回切换。
- **完成态从源码重建**：流式期间的多个 `AgentMessageCell` 会被替换为一个保存原始 Markdown 的 `AgentMarkdownCell`，窗口缩放时按当前宽度重新渲染。
- **Markdown 使用 pulldown-cmark 的自定义事件写入器**：表格、任务列表、数学公式、Mermaid 和本地文件链接都在写入阶段转换为终端行，而不是先生成 HTML。
- **代码高亮使用 syntect + two_face**，带 512 KB、10000 行和单行 4 KiB 的保护阈值；主题切换通过修订号使渲染缓存失效。
- **内容承载是纯文本终端**：HTML 作为字面文本显示，没有 iframe、脚本或 Artifact 执行面；链接通过终端超链接和本地文件重定向处理。

## 总体渲染链路

```text
app-server 通知（turn/item/agentMessage delta 等）
  → ThreadEventChannel 缓冲
  → ChatWidget::handle_server_notification 分派
  → on_agent_message_delta / on_plan_delta / reasoning delta
  → StreamController::push
  → StreamCore：源码收集 + 仅提交换行完整段 + 渲染末块
  → 提交动画 tick：Smooth 单行 / CatchUp 批量
  → AgentMessageCell / StreamingAgentTailCell 进入历史
  → 完成：ConsolidateAgentMessage
  → AgentMarkdownCell（保存源码，按宽度重渲染）
  → App::insert_history_cell
  → 终端回滚区（inline）或 TranscriptView（owned）
```

这条链路的关键分界在 `push` 与 `commit tick`：`push` 只更新源码、渲染快照和待提交队列，不直接写屏幕；真正把行送入历史的是提交动画 tick。这样网络增量频率、渲染频率和终端写入频率可以彼此解耦。

## 1. 消息与内容块数据模型

app-server 的 `ThreadItemPayload` 定义了七类 item：用户消息、助手消息、计划、推理、命令执行、文件变更和 MCP 工具调用（`app-server-protocol/src/protocol/v2/item.rs:299-400`）。TUI 不直接绘制这些结构，而是把它们映射成实现 `HistoryCell` 的单元：

| 协议内容 | TUI 承载 |
|---|---|
| 用户消息 | `UserHistoryCell`，含文本元素、本地图片和远程图片 URL |
| 助手消息 | 流式阶段 `AgentMessageCell`，完成态 `AgentMarkdownCell` |
| 推理摘要 / 原始推理 | `ReasoningSummaryCell`，可并入活动分组 |
| 计划 | `StreamingPlanTailCell`、`ProposedPlanCell`、`PlanUpdateCell` |
| 命令执行 | `ExecCell` 及变体，含命令、输出和退出状态 |
| 文件变更 | `PatchHistoryCell`、`PatchFailureCell` |
| MCP 工具 | `McpToolCallCell` |
| 其他事件 | 搜索、图片生成、Hook、通知、警告等专用 cell |

`HistoryCell` trait 是渲染层的统一接口（`tui/src/history_cell/mod.rs:201-356`）。它要求提供主视图行、原始行、复制源、期望高度和 transcript 行，并允许 cell 声明自己是否有稳定的高度、是否是流式续行、是否有活动分组身份。这个设计使“消息壳”和“内容渲染”可以分开：cell 决定内容和高度，App 决定插入位置和终端 sink。

`UserHistoryCell` 只把本地图片和远程图片输出为标签，未在该 cell 中看到终端图形协议调用（`tui/src/history_cell/messages.rs:207-215`）。这与 Web 端直接渲染 `<img>` 的模型不同。

## 2. 流式数据到 UI 的更新链

增量通知进入 `ChatWidget::handle_server_notification` 后按类型分派（`tui/src/chatwidget/protocol.rs:4-240`）：

- `AgentMessageDelta` 更新当前助手消息的流式标识并调用 `on_agent_message_delta`；
- `PlanDelta` 进入计划流；
- 推理摘要和原始推理分别处理，原始推理只有在配置允许时才显示；
- 命令执行和文件变更的输出增量进入各自的工具 cell；
- `TurnDiffUpdated` 和 `TurnPlanUpdated` 更新差异与计划视图；
- `TurnCompleted` 触发收口、用量输出和状态清理。

流式控制器的核心是 `StreamCore`（`tui/src/streaming/controller.rs:86-106`）。它同时维护四份状态：累积源码、已提交源码的增量渲染、可丢弃的散文预览，以及待提交的稳定行队列。`push_delta` 只提交已经出现换行的完整行段；最后一个未换行的残段留在预览或活动尾部（同文件 `:150-179`）。这条规则对表格尤其重要：未换行的半行如果提前提交，会在下一帧变成另一组列宽。

稳定行进入队列后，真正写入历史由提交 tick 完成。控制器提供单行和多行两种取行方式（`tui/src/streaming/controller.rs:647-658`），tick 则来自 App 主循环中的提交动画分支（`tui/src/app/startup.rs:1640-1650`）。

节流策略在 `chunking.rs` 中给出两档：

| 模式 | 行为 | 进入条件 |
|---|---|---|
| `Smooth` | 每个 tick 提交一行 | 默认状态，队列为空时回到此模式 |
| `CatchUp` | 批量排空当前队列 | 队列深度达到 8 行，或最老行等待达到 120ms |

退出 CatchUp 需要队列深度降到 2 行以下、最老行等待降到 40ms 以下，并持续 250ms；退出后还有 250ms 的再进入抑制。队列深度达到 64 行或最老行等待达到 300ms 时视为严重积压，可绕过抑制（`tui/src/streaming/chunking.rs:85-116`）。两个控制器的队列深度和最大等待时间会合并成一个决策，再执行统一的排空计划（`tui/src/streaming/commit_tick.rs:69-91`）。

完成收口分两步。首先取出控制器，渲染剩余源码，并把原始 Markdown 作为合并事件发给 App（`tui/src/chatwidget/streaming.rs:90-167`）。然后 App 找到尾部连续的流式助手 cell，用一个保存源码的助手 cell 替换整段（`tui/src/app/agent_message_consolidation.rs:24-90`）。如果流式文本与完成消息不一致，或者存在尚未稳定提交的尾部，会要求对终端回滚区做重排。

## 3. 消息列表、窗口化与滚动

TUI 有两条互斥的列表路径，由 `TranscriptMode::{Owned, Terminal}` 决定（`tui/src/transcript_mode.rs:7-23`）：

- **Terminal 模式**：已提交 cell 通过转义序列写入终端原生回滚区，列表的“存储”就是终端历史；TUI 只保留 cell 引用和少量尾部状态。
- **Owned 模式**：备用屏幕内由 `TranscriptView` 维护消息列表、滚动位置、选择和搜索状态，所有可见行由 TUI 重绘。

`App` 同时持有 transcript 的 cell 列表、终端原生历史、自有视图和 overlay（`tui/src/app.rs:568-579`）。cell 列表是规范列表；插入函数先把它加入列表，再根据当前模式决定是否写入终端或延迟到自有视图（`tui/src/app/history_ui.rs:25-68`）。因此“消息列表”和“终端回滚区”不是同一份数据：前者可以被重排和重新分组，后者一旦写入就受终端历史语义约束。

自有视图的绘制是逐可见行循环，而不是 Web 式虚拟列表（`tui/src/transcript_view.rs:185-308`）。每帧从当前起点开始，按 cell 的布局逐行填充视口，同时记录可见行、活动分组和选择状态；布局结果按条目键和宽度缓存。滚动状态区分“跟随最新”和“阅读历史”，并处理提示头让位、搜索高亮和选择拖拽。

历史分页由 app-server 提供：初次恢复最多 5 个 turn，单页 item 上限 100（`tui/src/app_server_session/history.rs:31-33`）。在顶部继续滚动会请求更早一页，加载期间保持阅读位置。这里没有前端 DOM 的高度测量或 `IntersectionObserver`，但同样需要处理“插入旧内容后不要跳走”的锚定问题。

## 4. 消息壳层与角色分派

角色分派发生在 cell 选择阶段，而不是在渲染函数里按角色分支：

- 用户消息由 `UserHistoryCell` 渲染，保留文本元素和图片标签，支持原始行与复制源；
- 助手流式片段由 `AgentMessageCell` 渲染，首行加圆点前缀，续行加缩进；
- 助手完成消息由 `AgentMarkdownCell` 渲染，保存 Markdown 源并在宽度变化时重渲染；
- 活动尾部由 `StreamingAgentTailCell` 渲染，直接使用控制器当前宽度的行，避免再次换行破坏表格边界；
- 推理摘要由 `ReasoningSummaryCell` 承载，多个推理片段可以并入同一个活动分组；
- 工具、补丁、计划、MCP、搜索、图片和通知各有专用 cell。

消息壳没有统一的“头像 + 气泡 + 操作栏”结构。用户消息和助手消息的区分主要靠前缀、缩进、颜色和内容形态；操作入口在 Composer 或全局快捷键，而不是每条消息悬浮工具条。复制源由 cell 的 `copy_source` 提供，终端选择由 App 的渲染选择层处理。

活动分组是这套壳层的一个特色：工具调用和推理可以折叠成一个活动条目，展开后显示细节。`HistoryCell` 通过活动身份、展开行和详情接口暴露分组语义（`tui/src/history_cell/mod.rs:259-274`）。这让长回合的工具序列不会把每个调用都铺满屏幕。

## 5. Markdown、代码与富文本管线

Markdown 渲染入口在 `render_markdown_agent_with_list_spacing`（`tui/src/markdown.rs:118-151`）。处理顺序如下：

1. 重写内联可视化指令，收集受信任的本地文件链接；
2. 在启用表格时展开被围栏包裹的表格源码；
3. 归一化 Markdown，处理表格、数学和特殊换行；
4. 用 pulldown-cmark 解析，并启用删除线、表格和可选的任务列表；
5. 通过自定义 `Writer` 把事件写成 `HyperlinkLine`；
6. 对本地文件链接做重定向，对 Web 链接决定是否隐藏目标地址。

解析器配置在 `tui/src/markdown_render.rs:418-438`。表格始终启用 `ENABLE_TABLES`，任务列表由 `preferences.lists` 控制；数学预处理在解析前完成，避免 TeX 转义被 Markdown 先消费。渲染偏好默认全部开启：Mermaid、数学、表格和列表（`config/src/tui_rendering.rs:11-30`）。

写入阶段的行为：

- **代码块**：取 info string 的第一个 token 作为语言，调用 syntect 高亮；语言无法识别或超过保护阈值时回落为纯文本（`tui/src/render/highlight.rs:596-634`、`:740-754`）。
- **表格**：按列内容计算宽度并绘制终端表格；超宽时按列分类和换行策略降级，表头与数据行分别处理。
- **HTML**：作为字面文本逐行写入，不解析标签、不执行脚本（`tui/src/markdown_render.rs:941-982`）。
- **数学**：在 `preferences.math` 开启时用有界 Unicode 排版近似小型 TeX 子集；公式过长或无法满足宽度时保留源码。
- **Mermaid**：完成的围栏块交给 `codex_mermaid` 渲染为终端 span；不支持、超宽或超限时显示说明并回退为高亮源码（`tui/src/markdown_render/mermaid.rs:39-61`）。
- **链接**：逻辑行保留目标地址和源范围，终端层可以标记 OSC 8 超链接；本地文件链接会按会话 `cwd` 缩短显示并做受信任重定向。

代码高亮使用 `two_face` 的语法集和 32 个内置主题，主题可以在运行时切换；切换时递增全局修订号，使已渲染内容的缓存失效（`tui/src/render/highlight.rs:64-100`、`:267-292`）。高亮有明确护栏：超过 512 KB、10000 行或单行 4 KiB 时跳过着色（同文件 `:636-655`）。

## 6. 工具、reasoning、附件与自定义节点

工具内容不是一种通用 JSON 卡片，而是按工具类型选择 cell：

- 命令执行显示命令行、输出流和退出状态，流式输出通过 `CommandExecutionOutputDelta` 追加；
- 文件变更显示补丁 diff，失败时使用 `PatchFailureCell`；
- MCP 工具调用显示调用参数、进度和结果；
- Web 搜索、图片查看、图片生成、Hook 和警告等各有专用 cell；
- 计划既可以在流式阶段显示为尾部 cell，也可以在完成后变成 `ProposedPlanCell` 或 `PlanUpdateCell`。

推理的显示受配置控制：摘要默认可以显示，原始推理需要显式开启。推理片段可以进入活动分组，而不是每条都单独占一段。计划增量走独立的 `PlanStreamController`，与助手消息共享同一套节流和提交策略，但发出时使用计划样式。

附件方面，用户消息保存本地图片路径和远程图片 URL，渲染为图片标签；Composer 的附件状态属于 Chat UI 类目。工具产生的文件、图片和 diff 作为结构化 cell 内容显示，不经过 Markdown 解析。在 `tui/src` 的已读入口中本次未找到面向消息内容的通用插件注册表；新增内容类型需要新增 cell 和对应的通知分派。

## 7. HTML、Artifact 与内容承载边界

终端渲染器没有浏览器上下文，因此不存在 iframe、脚本执行、CSS 注入或 DOM 清洗问题。Markdown 中的 HTML 被当作普通文本写入行，标签本身可见但不会生效（`tui/src/markdown_render.rs:941-982`）。这使内容承载边界比 Web 渲染器简单，但也意味着富 HTML 内容不会被还原为布局。

本地文件链接和 Web 链接仍需要边界处理。渲染器会区分受信任的本地文件目标和普通链接，前者按会话工作目录缩短显示并可重定向到真实路径，后者可以隐藏冗长的目标地址。Mermaid 和数学公式只生成终端 span，不引入外部资源。内联可视化指令会被重写为终端可显示的内容；由于它依赖文件系统状态，相关的 `AgentMarkdownCell` 不走普通 Markdown 缓存。

TUI 中没有 Artifact 预览窗、HTML 沙箱或脚本运行器。图片生成和图片查看有专用 cell，但是否使用终端图形协议取决于运行环境，本次未运行验证。

## 8. 内容交互反馈与可访问性

终端渲染器提供的交互是“选择、复制、跳转、展开”，而不是按钮点击：

- App 维护渲染选择和复制目标，`Ctrl+O` 复制当前选择或 transcript；
- `/copy` 从已完成回复或状态面选择复制片段，复制源优先使用原始 Markdown；
- `Alt+R` 切换原始行模式，便于终端原生选择；
- `F3` 在完整 transcript 中查找并高亮匹配；
- `F4` 聚焦活动分组，展开或折叠工具与推理详情；
- 链接通过终端超链接悬停和点击处理，本地文件链接有专用重定向。

反馈主要通过行内状态和错误 cell 表达：复制成功或失败会生成通知，工具失败会生成错误 cell，链接打开失败会写错误消息。代码块没有独立的“复制”按钮，复制统一走选择或 `/copy`；这与 Web 端每块悬浮复制按钮的交互不同。

无障碍方面，终端没有 ARIA 角色、可访问名称或屏幕阅读器树。键盘可以完成查找、选择、复制、展开和审批，但实际焦点顺序、终端读屏支持和组合键可用性需要在目标环境观察；Web 无障碍维度为 N/A。

## 9. 性能、缓存与测试

渲染性能主要由四层机制控制：

| 机制 | 作用 | 位置 |
|---|---|---|
| 增量 Markdown 渲染 | 只保留最后一个顶层块为可变，之前的块渲染一次 | `tui/src/streaming/render.rs:130-245` |
| 有界散文预览 | 未换行的文本只生成可丢弃预览，不推进稳定边界 | `tui/src/streaming/controller.rs:181-203` |
| 表格 holdback | 未确定的表格结构不进入稳定队列 | `tui/src/streaming/table_holdback.rs` |
| 单条渲染缓存 | 按宽度、列表间距、主题修订和终端颜色缓存最终行 | `tui/src/history_cell/markdown_render_cache.rs:9-52` |

增量渲染不是无条件的。遇到引用式链接定义或内联可视化指令时，会退回整段重渲染，因为这些内容可能影响前文的语义（`tui/src/streaming/render.rs:153-174`）。完成收口也会重新渲染完整源码，以保证最终结果与增量结果一致。

代码高亮在进程内只初始化一次语法集，主题用读写锁保护；主题修订号参与缓存键，避免切换主题后复用旧颜色。高亮前有大小、行数和单行长度阈值，超限直接走纯文本。

测试方面，`tui/src/streaming/render_tests.rs` 覆盖增量渲染与完整渲染的一致性、HTML 接缝、引用链接和 Mermaid 可变围栏；`controller.rs` 和 `chunking` 相关测试覆盖提交队列与模式切换；渲染输出使用快照测试。在 `codex-rs/tui` 范围内本次未找到专门的基准测试目录或 criterion 基准，长会话性能仍需运行时测量。

## 10. 扩展方式与已确认边界

新增一种消息内容通常需要三处改动：

1. 在 app-server 协议中增加 item 或通知类型；
2. 在 `ChatWidget` 的通知分派中把事件映射成渲染状态；
3. 实现新的 `HistoryCell` 并通过 `add_to_history` 或 `insert_history_cell` 插入。

新增 Markdown 语法则要扩展 `markdown_render` 的解析前预处理或 `Writer` 事件处理。这里没有 Web 端的组件注册表或插件协议；扩展点是 Rust 枚举、trait 实现和通知分派。

已确认的边界：

- 渲染单位是终端逻辑行，不是 DOM 节点；
- HTML 不执行，富内容降级为文本；
- 列表在自有模式下按可见行绘制，在终端模式下交给原生回滚区；
- 流式完成会从源码重建最终 cell，流式期间的局部样式不保证与最终渲染逐字一致；
- 消息操作没有统一的悬浮工具条，复制和跳转走全局入口；
- 没有通用 Artifact/iframe 承载面。

## 11. 未验证事项

- 未运行 TUI，未观察实际颜色、表格边框、宽字符、表情符号和超链接在终端中的表现。
- 未验证不同终端对 OSC 8、备用屏幕、宽字符宽度和图形协议的支持差异。
- 未对超长会话、超大代码块、复杂表格和 Mermaid 图的渲染性能做运行时测量。
- 未验证数学公式的 Unicode 近似在各类公式上的可读性，以及 Mermaid 失败回退的实际布局。
- 未确认外部 Desktop 应用和 Web 前端是否复用本仓库的渲染逻辑；本笔记只覆盖本仓库的 TUI 代码。

## 12. 关键源码索引

- 通知分派：`codex-rs/tui/src/chatwidget/protocol.rs:4-240`
- 流式答案与收口：`codex-rs/tui/src/chatwidget/streaming.rs:90-167`
- 流式核心：`codex-rs/tui/src/streaming/controller.rs:86-179`、`:212-330`、`:590-658`
- 自适应节流：`codex-rs/tui/src/streaming/chunking.rs:85-116`
- 提交 tick：`codex-rs/tui/src/streaming/commit_tick.rs:69-91`
- 增量 Markdown 渲染：`codex-rs/tui/src/streaming/render.rs:130-245`
- cell 接口：`codex-rs/tui/src/history_cell/mod.rs:201-356`
- 消息 cell：`codex-rs/tui/src/history_cell/messages.rs:17`、`:392`、`:494`、`:571`、`:753`
- 完成态合并：`codex-rs/tui/src/app/agent_message_consolidation.rs:24-90`
- 历史插入：`codex-rs/tui/src/app/history_ui.rs:25-118`
- 自有 transcript：`codex-rs/tui/src/transcript_view.rs:185-308`
- transcript 模式：`codex-rs/tui/src/transcript_mode.rs:7-23`
- Markdown 配置：`codex-rs/tui/src/markdown_render.rs:418-438`
- HTML 字面输出：`codex-rs/tui/src/markdown_render.rs:941-982`
- Mermaid 回退：`codex-rs/tui/src/markdown_render/mermaid.rs:39-61`
- 数学预处理：`codex-rs/tui/src/markdown_render/math.rs:226-250`
- 代码高亮：`codex-rs/tui/src/render/highlight.rs:596-655`、`:740-754`
- 渲染偏好：`codex-rs/config/src/tui_rendering.rs:11-30`
- 渲染缓存：`codex-rs/tui/src/history_cell/markdown_render_cache.rs:9-52`
- 历史分页：`codex-rs/tui/src/app_server_session/history.rs:31-33`
- 协议 item：`codex-rs/app-server-protocol/src/protocol/v2/item.rs:299-400`
