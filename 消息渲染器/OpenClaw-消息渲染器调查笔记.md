# OpenClaw 消息渲染器调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：只读梳理 Gateway 协议、transcript 投影、Control UI、TUI、iOS 原生聊天和 Android 原生聊天的事件、状态、列表与内容渲染链；未运行构建、测试或目标设备验证
>
> 调查范围：消息从 Gateway 历史或实时事件进入可见聊天表面的过程，覆盖文本、reasoning、工具、附件、Markdown、Canvas/MCP 小部件、滚动与性能边界；排除模型请求与上下文组装、完整会话 CRUD、Composer 工作流、独立 Artifact 生命周期和导出 sink，仅记录它们与聊天现场渲染的交接点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的消息渲染由一个共享的 Gateway 显示协议和多套客户端投影组成。Gateway 把持久 transcript 转成可供聊天表面消费的显示消息，同时把实时生成拆成 `chat` 运行事件、`agent` 工作事件和 `session.message` 持久消息事件。Control UI 和 TUI 共用 `@openclaw/gateway-client` 的会话身份与运行投影规则；iOS、Android 则各自把协议 payload 解码为原生模型，再交给 SwiftUI 或 Compose 组件。

主链路可以概括为：

```text
Agent / SQLite transcript commit
  ├─ chat runtime buffer -> chat: status/delta/final/aborted/error
  └─ transcript update -> display projection -> session.message
                                      └-> sessions.changed（列表/生命周期通知）

Control UI: GatewayBrowserClient
  -> selected-session subscription + chat.history/chat.startup
  -> pane-owned session projection
  -> ChatItem/MessageGroup/stream-run/agent-run-frame
  -> virtual transcript rows
  -> markdown/tool/media/widget components

TUI: GatewayChatClient or embedded backend
  -> tui-event-handlers + shared session projection
  -> TuiStreamAssembler / ChatLog
  -> pi-tui Markdown and terminal components

iOS / Android:
  -> native transport event enum or Gateway event dispatcher
  -> history + in-flight run reconciliation
  -> native timeline
  -> SwiftUI LazyVStack or Compose LazyColumn
```

最有特色的实现选择有四点：

- Gateway 先做显示投影、隐藏回复过滤、内容预算和 transcript 身份补全，客户端通常不直接渲染原始运行时 envelope。
- Control UI 把“持久消息、实时文本、工具流、提问和运行状态”保留为不同的投影对象，再在 thread builder 中合并为用户可读的 turn。
- Control UI 使用 TanStack virtualizer、行测量、稳定滚动锚点和流式 Markdown 尾部修复；TUI 则选择有界 scrollback 和组件原地更新。
- Canvas HTML、MCP App 和原生媒体不混入普通 Markdown 的 HTML 执行路径，而是进入带 URL、sandbox、TLS 或 bridge 约束的独立承载面。

## 总体渲染链路

### Gateway 与协议边界

协议层把聊天历史、发送请求和实时运行事件分开。`chat.history` 接受 session key、agent、cursor、offset、message anchor 和显示字符预算，并返回历史消息、session 信息、分页或 cursor 状态；cursor 增量只能返回 `delta` 或要求客户端 `reset`。`chat.send` 使用幂等键、队列模式和可选附件，实时 `chat` 事件带有 session、agent、run 和单调序列字段。具体契约见 `packages/gateway-protocol/src/schema/logs-chat.ts:25-61,142-174,192-272`。

持久消息在 SQLite 变更提交后才发出 transcript update。写入通知携带 agent、session、session key 和 store path，随后 Gateway 根据消息序号和当前 session 状态构造 `session.message` payload；被显示投影过滤的消息仍可通过 `sessions.changed` 通知列表观察者。提交后的通知与广播顺序见 `src/config/sessions/session-accessor.sqlite-events.ts:9-35`、`src/gateway/server-session-events.ts:72-127,231-373`。

Gateway 的显示投影位于传输和客户端之间。它会处理内部 envelope、隐藏的 heartbeat 或控制回复、工具可见文本、错误 fallback、用户资料头像、媒体引用和字符上限。超过显示上限的消息在 `__openclaw` 中留下 `truncated` 与原因，客户端可据此通过 `chat.message.get` 请求完整单条消息；该边界见 `src/gateway/chat-display-projection.core.ts:305-353`、`src/gateway/chat-display-projection.sanitize.ts:588-617` 和 `src/gateway/session-transcript-message.ts:51-100`。

### 客户端共享状态规则

浏览器和 TUI 共用的 session projection 以 session scope、消息 identity 和 run state 为核心。scope 包含 session key、session id、agent、生命周期 revision 和 active leaf；消息 identity 可来自 durable id、sequence、idempotency key 或导入来源。运行状态包括 streaming、completed、error、aborted、timeout 和 yielded，并保留有限数量的 terminal run 以识别重复 final。实现见 `packages/gateway-client/src/session-projection.ts:23-121,205-303,479-590`。

投影 reducer 将 snapshot、持久消息、乐观发送、运行 delta、终态、session reset 和 transport gap 视为不同事件。持久消息只有通过 identity 匹配、scope 校验和顺序插入后才进入显示数组；已知的 live 或 pending 条目可以在旧 snapshot 中保留。`transportGap` 会被记录，重连本身不会清除它，必须等权威历史到达，见 `packages/gateway-client/src/session-projection.ts:593-704`。

## 1. 消息与内容块数据模型

### Gateway 显示消息

Gateway 没有为所有模型供应商强制一个固定的内容 part 联合。协议中的历史和事件 message 字段主要是 `unknown`，显示投影负责把不同 transcript 形态收敛为客户端可以识别的 role、content、metadata 和 session 信息。`__openclaw.id`、`seq`、`idempotencyKey`、`recordTimestampMs`、`kind`、`truncated`、`runTerminal` 等字段承担渲染去重、排序、分支标记和完整消息读取的职责。

运行事件的共同身份由以下信息组成：

| 信息 | 渲染用途 |
|---|---|
| `sessionKey`、`agentId` | 把事件限制到当前 pane、TUI 或原生会话 |
| `runId`、`spawnedBy` | 识别实时回合、子运行和终态归属 |
| `seq` | 检测乱序、事件间隙并恢复工具/运行投影 |
| `messageId`、`messageSeq` | 让 `session.message` 可以与历史行对齐 |
| `activeLeafEntryId` | 让历史 snapshot 与 branch/rewind 之后的显示路径对齐 |

### Control UI 模型

Control UI 的 pane state 同时持有历史消息和实时投影。`history-merge.ts` 以 pane 为 owner 保存 session projection，避免分屏之间共享 live state；`session-message-apply.ts` 接受 Gateway 的 `session.message`，补入 `__openclaw` identity 后再交给 reducer。它还区分 producer-owned assistant、上一回合迟到的 assistant、用户消息和导入消息，避免把相关 run 的最终回复误放到新 turn，见 `ui/src/pages/chat/history-merge.ts:14-23,58-102,220-269`、`ui/src/pages/chat/session-message-apply.ts:63-176`。

历史消息进入 thread builder 后被抽象为两类主要对象：普通 `ChatItem` 和按 role、sender、run、边界分组的 `MessageGroup`。另外还有 stream、reading indicator、question、notice、divider、work-group、activity-run 和 agent-run-frame。`buildChatItems` 负责过滤 heartbeat、压缩/重置 marker、工具结果、Canvas 预览和 queued send；`groupMessages` 再按 role、run、sender 和 commentary/runtime activity 边界合并，见 `ui/src/pages/chat/chat-thread-build.ts:75-215`、`ui/src/pages/chat/chat-thread-grouping.ts:57-130`。

### TUI 模型

TUI 不把终端输出解析为浏览器 DOM。每个 run 在 `TuiStreamAssembler` 中保存 thinking 文本、content 文本、文本块、非文本块信号和当前 display text；该状态最多跟踪 200 个 run，并在最终消息到达时与 streamed 文本合并，见 `src/tui/tui-stream-assembler.ts:10-18,111-247`。

`ChatLog` 是 TUI 的可见 scrollback 容器，内部按 run 保存 streaming、frozen 和 finalized assistant component，同时保存工具、用户消息、pending system notice 和 BTW 消息的索引。工具开始时会冻结此前的 assistant 文本，保证工具卡位于正确的因果位置；终态会更新或删除原 streaming component，见 `src/tui/components/chat-log.ts:24-109,433-526,570-611`。

### iOS 与 Android 原生模型

iOS 的 `OpenClawChatMessage` 包含 role、content 数组、时间、transcript message id、幂等键、tool call/name、usage、stopReason、错误、provenance 和 history marker。`OpenClawChatMessageContent` 同时容纳文本、thinking、媒体、工具调用参数、工具详情和 Canvas preview；解码器还兼容字符串型 content、旧的 `MediaPath`/`MediaType` 字段和 managed artifact URL。定义与解码见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatModels.swift:117-213,402-583`。

Android 先把 Gateway payload 解码为 `ChatMessage` 和 `ChatMessageContent`。可见 role 集合是 user、assistant、system、custom；content 类型包括 text、image、audio、video、attachment/file 和受限的 canvas widget。解析器兼容 `input_text`、`output_text`、字符串 content、旧 transcript 音频字段，并把 managed media URL 转换为 artifact id，见 `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatModels.kt:11-35,82-110`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:7140-7261`。

## 2. 流式数据到 UI 的更新链

### Gateway 实时文本

Gateway 的 live projector 接受 assistant 事件中的完整 text、delta 或两者，按前缀关系决定替换、追加或保留旧快照，并把 live buffer 限制在 500,000 个字符。随后移除内部 runtime context、directive tag 和需要隐藏的控制回复。实现见 `src/gateway/live-chat-projector.ts:18-110`。

`server-chat.ts` 对可见文本使用 75 ms pacing。每次 assistant 事件先合并到 run buffer；若距离上次广播不足 75 ms，就安排一次延迟 flush，否则立即把相对于上次广播的 delta 发给 `chat` 订阅者。payload 仍携带当前完整 assistant message，因此客户端既能用 delta，也能在 replace 或恢复场景使用完整快照，见 `src/gateway/server-chat.ts:216-221,877-988`。

run 终态到达时，Gateway 先 flush 尚未广播的 buffer，再发 final、aborted 或 error。正常 final 若没有可见文本就省略 message；错误终态另带错误信息和分类。生命周期持久化在终态处理后进行，持久化完成或失败都会通知 session 列表订阅者，见 `src/gateway/server-chat.ts:1058-1109`、`src/gateway/server-chat.ts:716-855`。

### Control UI 更新

GatewayBrowserClient 把 WebSocket event frame 交给 pane lifecycle。连接切换后，Control UI 先为选中的 session 获取消息订阅租约，再用 `chat.startup` 或 `chat.history` 加载历史；切换 session 或 agent 时，旧租约释放与新租约 acquire 并行进行，过时的 generation 不得写回当前 pane。相关入口见 `ui/src/pages/chat/chat-pane-context.ts:424-473`、`ui/src/pages/chat/chat-history.ts:847-1001`、`ui/src/lib/sessions/session-scoped-operations.ts:134-179`。

历史请求使用共享的 bounded in-flight registry。相同 client、session、agent、connection epoch 和 cursor 的请求可以被多个 pane 复用，但每个 pane 仍按自己的 request ownership 验证结果。cursor 返回 `delta` 时，消息会按 `session.message` 的同一 reducer 逐项应用；返回 `reset` 时清除 cursor 并重新请求 tail page。实现见 `ui/src/pages/chat/chat-history.ts:1052-1146,1592-1687,1769-1891`。

实时 `chat` 事件进入 `handleChatGatewayEvent`，负责 delta 拼接、run 状态、终态替换和迟到 final 去重；实时 `session.message` 进入 `applySessionMessagePayload`，负责把持久行纳入当前 projection。历史 snapshot 只在 session、agent、connection epoch 和 request version 都仍匹配时提交。`chat-state-events.ts` 还会在 delta 时使用 animation frame 请求重绘，在终态和历史交接时立即请求重绘，见 `ui/src/pages/chat/chat-state-events.ts:431-594`、`ui/src/pages/chat/chat-state-render.ts:5-38`。

工具流走独立的 `tool-stream.ts`。它按 runId + toolCallId 保存工具条目，使用 Gateway sequence 防止历史恢复覆盖更新的 live 状态；工具事件最多保留 50 条，文本输出上限为 120,000 字符，普通工具 UI 更新节流为 80 ms。结果可以生成 tool call、tool result、diff、approval review 或 Canvas preview，见 `ui/src/pages/chat/tool-stream.ts:32-75,1034-1201`。

### TUI 更新

`src/tui/tui.ts` 在连接建立后订阅 session events，并把 `chat`、`agent`、`sessions.changed` 和 `session.message` 分别交给事件处理器；订阅失败会重试，超过次数后在 TUI 中显示错误。入口见 `src/tui/tui.ts:1739-1800`。

`tui-event-handlers.ts` 对选中 session、run ownership、事件序号和历史 reload 状态做过滤。chat delta 进入 `TuiStreamAssembler.ingestDelta`，有可见文本时原地更新 ChatLog；final 先从 assembler 生成完整文本，再把 streaming component 定稿或删除。tool/生命周期事件由 `handleAgentEvent` 更新工具和活动状态，见 `src/tui/tui-event-handlers.ts:170-380,502-619`。

embedded backend 把 agent assistant 事件的完整 text/delta 合并到本地 run buffer，再发出 `chat` 和 `agent` 两类本地事件。工具或非 assistant 事件会先确保 run 已登记，便于 TUI 在尚未有文本时显示活动状态，见 `src/tui/embedded-backend.ts:1284-1357`。

### iOS 与 Android 更新

iOS 在 ViewModel 初始化时启动 transport event task，把异步事件切到 MainActor。health、chat、session.message、agent、question、progress 和 seq gap 都进入统一分派；seq gap 会清空不完整 live state 并重新请求历史。见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:527-547`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+TransportEvents.swift:25-92`。

iOS 启动或恢复时先设置 active session subscription，再请求 history。历史返回的 `inFlightRun` 可以重新接管 pending run 和 buffered text；同一 run 的 live delta 则更新 `streamingAssistantText`，终态会清理工具和流式文本并触发历史刷新。见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:880-999`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+RunSnapshot.swift:5-69`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+TransportEvents.swift:397-601`。

Android 使用 StateFlow 保存 messages、historyLoading、streamingAssistantText、pending tools、subagent activity、questions 和 session 状态。Gateway event dispatcher 将 chat、session.message、agent、sessions.changed、question 和 progressCard.changed 交给对应处理函数；seq gap 清除不完整活动并触发恢复历史，见 `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:3232-3307`。

Android 的 `chat` handler 只让当前 controller 所有的 run 更新 live 文本；非当前 session 的终态用于有限的后台历史恢复。`fetchAndApplyHistory` 通过 history generation、Gateway scope、agent owner 和 request sequence 丢弃过时结果，再用 history 的消息和 in-flight snapshot 替换冷启动缓存，见 `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:5508-5627,3822-3970`。

## 3. 消息列表、窗口化与滚动

### Gateway 历史窗口

历史读取支持三种定位方式：数字 offset、messageId anchor 和 opaque cursor。数字分页会读取 transcript tail，再做显示投影和字节预算；messageId 读取会围绕同一序号组扩展窗口，保证同一 transcript entry 的相关内容一起返回；cursor 增量最多处理 200 个事件和 1,000,000 字节，遇到 compaction、reset、超过预算或仍有更多内容时返回 reset。入口见 `src/gateway/server-methods/chat-history-handler.ts:285-329,449-532`、`src/gateway/server-methods/chat-history-pages.ts:167-207,210-329`、`src/gateway/server-methods/chat-history-delta.ts:12-100`。

历史消息还有独立的全局 payload 预算和单消息预算。过大的消息被替换为带截断标记的可见预览；Control UI 和原生客户端不会把这类内部 marker 直接当作普通正文显示。Control UI 的完整消息入口在 `ui/src/pages/chat/components/chat-message-markdown.ts:98-180`。

### Control UI virtualizer

Control UI 的 transcript controller 使用 `@tanstack/lit-virtual`。默认估算行高为 120 px，overscan 为 6，采用 end anchor 和显式的 `scrollToEnd`；`followOnAppend` 关闭，由聊天自己的滚动状态决定是否跟随新内容。每一行通过 `measureElement` 测量，窗口尺寸变化时优先使用 `resizeItem` 和现有测量，避免清空所有 offscreen 高度造成跳动，见 `ui/src/pages/chat/components/chat-transcript-controller.ts:59-62,228-285`。

虚拟范围外的 focused row 会由 `extractTranscriptRange` 额外保留，因而搜索定位、回复跳转或详情操作不会因为 row 离开窗口而消失。行 key 变化时，controller 会用 snapshot 和当前 scroll offset 预览下一组虚拟行，MCP App row 还会在卸载前经过专门的 teardown gate，见 `ui/src/pages/chat/components/chat-transcript-range.ts:3-39`、`ui/src/pages/chat/components/chat-transcript-controller.ts:374-455`。

Control UI 的 follow policy 由 thread controller 和页面状态共同维护。新 user turn、stream segment、工具边界和 history reset 会影响活动路径；用户主动滚动后不再强行贴底，回到 end threshold 内才恢复跟随。具体的几何测量和 scroll position 由 controller 维护，流式状态更新则通过 `requestAnimationFrame` 合并，见 `ui/src/pages/chat/chat-state-render.ts:16-38`。

### TUI、iOS 与 Android 列表

TUI 没有在 `src/tui/components/chat-log.ts` 及其直接渲染组件中发现浏览器式虚拟列表。`ChatLog` 通过 `maxComponents` 控制 scrollback，默认值为 180；溢出时优先删除最旧 component，并同步清理工具、assistant run、pending user 和 notice 的索引。活动 run 的 prompt、reply 和工具会在必要时受到保护，见 `src/tui/components/chat-log.ts:32-109,111-161`。这说明 TUI 采用有界保留，而非按滚动窗口重新挂载历史。

iOS 的原生聊天使用 `ScrollView` + `LazyVStack`。消息行和系统行全部从当前 ViewModel 的 transcriptRows 生成，实时 assistant、pending tools、subagent 和 question 作为列表尾部的瞬时行追加。没有在本次检查的 `OpenClawChatView` 历史路径中看到独立的 numeric page 或 transcript virtualizer；冷启动和离线缓存由 ViewModel 负责，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:351-462,464-537,693-705`。

iOS 通过 `scrollPosition`、live edge threshold 48 px、turn anchor 和 one-shot positioning 管理滚动。新 turn 通常定位到用户消息附近；键盘出现时改为跟随 live edge；用户滚动后显示 Jump to latest，流式 tick 不会反复绑定同一个 row，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:376-431,723-751,928-1021`。

Android 使用 `LazyColumn(reverseLayout = true)` 和稳定的 `chatTimelineItemKey`。timeline index 0 是最新视觉边缘，latest user message 是恢复历史时的 reader anchor，latest content 是实时跟随目标。`ChatReaderScrollController` 用 `LazyListState`、`snapshotFlow` 和 `rememberSaveable` 保存 session-scoped 状态；新 user turn 会转为 LatestContent，用户离开目标后显示 Jump to latest，见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:1388-1487`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatReaderScrollController.kt:76-152,177-277`。

## 4. 消息壳层与角色分派

### Control UI

Control UI 的消息壳分三层完成分派：

- `buildChatItems` 将系统 marker、普通消息、queued send、工具流和 Canvas preview 变成可排序的 ChatItem。
- `groupMessages` 按 role、sender、run 和 turn boundary 生成 MessageGroup；同一回合的 assistant commentary、工具和最终回复可以继续被拆分。
- `coalesceStreamRuns`、`collapseCompletedTurnWork` 和 `coalesceAgentRunFrames` 把实时流、已完成工作和活动状态包装成稳定的可见 frame。

最终组件由 `chat-message-group.ts`、`chat-message-bubble.ts` 和 `chat-message-stream.ts` 承载。user group、assistant group、tool group、系统 notice、compaction/reset divider、streaming assistant、reading indicator、question 和 run frame 都有独立布局入口。完成回合的中间工作可折叠为 Worked for X；实时回合保持活动指示、工具和文本的连续布局，见 `ui/src/pages/chat/chat-thread-grouping.ts:180-300`、`ui/src/pages/chat/chat-agent-run-grouping.ts:22-31,196-260`、`ui/src/pages/chat/components/chat-agent-run-frame.ts:31-90`。

assistant 正文、reasoning、工具卡、附件和 Canvas preview 仍在同一 group 壳内组合。`renderGroupedMessage` 先做 role/message normalization，再计算工具卡、图片、附件、thinking、正文和 reply target，随后按 Markdown、tool card、media 和 widget 的条件决定内容顺序，见 `ui/src/pages/chat/components/chat-message-bubble.ts:212-360`。

### TUI

TUI 的用户消息使用 `UserMessageComponent`，assistant 使用 `AssistantMessageComponent`，两者都包裹 `HyperlinkMarkdown`。system notice 使用终端 Text；工具使用 `ToolExecutionComponent`；BTW 问题使用 `BtwInlineMessage`。`ChatLog` 负责把这些组件插入正确的 run 位置和 scrollback，assistant 的工具边界会冻结此前文本，见 `src/tui/components/user-message.ts:5-21`、`src/tui/components/assistant-message.ts:6-23`、`src/tui/components/chat-log.ts:445-526`。

### iOS

iOS 的 `ChatTranscriptRow` 先把历史 marker 转成 compaction/reset divider，把 `internal_system` provenance 的 user 行转成 restart recovery 或系统通知，其余消息转为 message row，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTranscriptRows.swift:3-155`。

`ChatMessageBubble` 按 user 与非 user 选择左右布局和 bubble 样式。`ChatMessageBody` 再决定正文是否显示、是否显示 tool activity、媒体、链接预览和 Canvas widget；tool result 通常被 `OpenClawChatView.mergeToolResults` 合并到前一条 assistant message，孤立 result 才保留为 fallback activity，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMessageViews.swift:288-360,394-500,567-660`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:1034-1095`。

### Android

Android 先用 `ChatTimelineItem` 把持久消息、streaming assistant、pending tools、subagent、question、turn recap、system notice、system divider 和 outbox 分成稳定 key 的时间线。`ChatScreen` 再按 item 类型调用 `ChatBubble`、`ToolBubble`、`SubagentActivityRows`、`ChatQuestionCard`、系统行和加载状态，见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatTimeline.kt:13-162`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:1399-1485`。

`ChatBubble` 将 user、system 和 assistant 映射为 speaker/caption，过滤空文本、图片上限、Canvas widget 和媒体，然后在统一的 Material surface 中装配 Markdown、音视频、图片、文件、widget、链接预览、speech 状态和时间。用户消息超过阈值时使用独立的 disclosure，见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:1707-1887`。

## 5. Markdown、代码与富文本管线

### Control UI Markdown

Control UI 的解析器是 `markdown-it`，开启 HTML 识别、换行、linkify、strikethrough、task list、details、tables、assistant transcript role marker、session link 和 file link。HTML 识别的目的主要是让自定义 rule 把原始 HTML 转为可显示的安全文本或受控 details，不代表普通 Markdown 获得任意 HTML 执行面。解析器配置和 scheme rule 见 `ui/src/components/markdown-parser.ts:141-174,267-291`。

普通消息的主要顺序是：

1. 规范化换行并移除不支持的 citation control marker。
2. 按 140,000 字符截断；超过 40,000 字符的非 document 正文走 escaped plain-text fallback。
3. 由 markdown-it 生成 HTML，代码块由 highlight.js core 的有限语言注册表处理。
4. 由 DOMPurify 按显式 tag/attribute 白名单清洗。
5. Lit 通过 `unsafeHTML` 插入已经清洗的结果。

这些步骤分别位于 `ui/src/components/markdown.ts:88-107,500-537`、`ui/src/components/markdown-code-blocks.ts:236-318` 和 `ui/src/pages/chat/components/chat-message-markdown.ts:335-349`。允许的普通 Markdown tag 不包含 iframe、script 或 style；DOMPurify hook 还会把链接协议限制为 http、https、mailto，移除 host-local markdown file 的 href，并为外部链接补 target 与 rel，见 `ui/src/components/markdown.ts:438-483`。

流式正文使用稳定前缀和尾部修复。`splitStableStreamingMarkdown` 在 fence、details、列表和 link reference 边界外寻找稳定段；稳定段复用普通缓存，尾段用 `remend` 修补未闭合语法。开放代码 fence 保持 plain text，避免每个 delta 都触发完整代码高亮，见 `ui/src/components/markdown-streaming.ts:104-287`、`ui/src/components/markdown-streaming.ts:289-328`、`ui/src/components/markdown.ts:575-614`。

代码块具有独立 header、语言标签、复制按钮、展开和换行控制。纯 JSON 的 assistant 消息在 20,000 字符以内会被识别并显示为可折叠的 pretty-printed code；更长或解析失败的 JSON 保持普通正文，见 `ui/src/pages/chat/components/chat-message-markdown.ts:32-77`。

本次在 `ui/src/components/markdown-parser.ts`、`markdown.ts`、`markdown-streaming.ts` 和 `markdown-code-blocks.ts` 的 Markdown 渲染范围内未找到 Mermaid 或 KaTeX 的实际渲染入口。代码块语言识别不等于 Mermaid 执行；该结论仅表示本次检查范围未找到，未扩展到项目所有插件或独立预览表面。

### TUI Markdown

TUI 使用 `@earendil-works/pi-tui` 的 Markdown 组件，不生成 HTML。`HyperlinkMarkdown` 先通过 `sanitizeMarkdownSource` 处理文本，再让 pi-tui 生成终端行，最后把识别到的 URL 包装为 OSC 8 hyperlink；渲染结果按终端宽度缓存，文本变化或 invalidate 时清除缓存，见 `src/tui/components/hyperlink-markdown.ts:12-64`。

工具输出也经过同一终端 Markdown 路径，但默认按 12 行和“行宽 × 12”计算 preview budget，单个过长行同样受到字符预算约束；展开后才使用完整 sanitized source。见 `src/tui/components/tool-execution.ts:23-72,111-193`。

### iOS Markdown

iOS 使用 Swift Markdown/AttributedString 和 SwiftUI 专用 block view。`ChatMarkdownBlockSegmenter` 将文本拆成 prose、heading、code、math、table、list、disclosure 和 thematic break；它会识别 raw HTML 上下文，以免 details、script、style、textarea 等文本中的伪标签改变结构，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMarkdownBlockSegmenter.swift:4-20,102-148,150-273`。

`ChatMarkdownRenderer` 对 prose 使用 AttributedString，对 heading、code、math、table、list 和 disclosure 分别调用专用 SwiftUI view。开放 code fence 或未完成 math delimiter 在流式期间显示为普通 monospace 文本；完成后代码进入 content-keyed highlight cache，数学进入 SwiftMath 解析和图片缓存。见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMarkdownRenderer.swift:149-226,234-300`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMarkdownBlockViews.swift:9-77`。

表格使用横向 ScrollView，列表使用 Grid 并保留 checkbox 的可访问性标签；代码和数学也使用横向 ScrollView。见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMarkdownBlockViews.swift:134-190,192-295`。本次检查的原生 Markdown 链路没有发现把任意 HTML 交给 WebView 执行的入口；HTML 识别主要服务于结构分段和文本降级，运行时视觉效果未验证。

### Android Markdown

Android 使用 CommonMark parser，开启 autolink、strikethrough、GFM tables 和 task list，并保留 source spans。`ChatMarkdown` 先分离 math source，再对 CommonMark block 递归渲染 paragraph、heading、code、quote、list、table、thematic break 和 literal HTML；details 是独立的 disclosure tokenizer 与 Compose surface。见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMarkdown.kt:93-173,175-349,737-772`。

Android 的 raw HTML 以 monospace literal text 显示。Markdown link 只有 http 和 https 被包装为 `LinkAnnotation.Url`，其他 scheme 只保留可见文本；这使 file、content、intent 等 URL 不会从普通聊天 Markdown 触发 Android 外部动作，见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMarkdown.kt:640-715`。

流式代码 fence 在结束前不做高亮，完成后再用 Compose AnnotatedString 和代码 token 颜色生成高亮；代码 block 本身支持文本选择和横向内容。见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMarkdown.kt:195-205`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMessageViews.kt:492-535`。

## 6. 工具、reasoning、附件与自定义节点

### 工具与 reasoning

Gateway 把 agent tool/lifecycle 事件和 chat 文本事件分开。Control UI 的工具流按 tool call id 维护参数、partial result、result、exit code、diff stat、错误和 approval review；历史消息中的工具调用与工具结果再由 `tool-cards.ts` 提取为可读的 ToolCard。工具输出会做文本截断和 `redactToolPayloadText` 脱敏，具体提取规则见 `ui/src/lib/chat/tool-cards.ts:35-72,96-187`。

Control UI 的 tool card 根据工具视图分类显示 command、read、edit、write、search 和 fetch 等摘要，并可显示输入、输出、错误、raw details、diff、diff stat、approval review 和 Canvas preview。对于工具结果只包含一个可见 outcome 的情况，普通消息壳会把工具文本和正文布局去重，见 `ui/src/pages/chat/components/chat-tool-cards.ts:100-132,210-300,765-807`。

assistant 的 thinking 内容由 Gateway 投影和客户端设置共同控制。Control UI thread builder 会过滤隐藏的 heartbeat，并可将 thinking/commentary 作为 stream 或 reasoning activity；iOS 的 `ChatMessageVisibleText` 默认从可见文本中排除 thinking，只有 reasoning display option 开启时才将 thinking 包装为 `<think>` 显示；Android 当前 ChatMessage content parser 不把 thinking 单独暴露为普通可见 role，工具和运行指示器由时间线另行承载，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMessageVisibleText.swift:20-69`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatTimeline.kt:94-116`。

Control UI 还会将连续的 read、glob、grep、list 工具组合为 context/activity group，并将完成回合的中间工作收拢到折叠的 work group。这样工具调用的可见性由 run frame 和工作组决定，Markdown 正文只负责叶子内容，见 `ui/src/pages/chat/chat-thread-grouping.ts:196-300`、`ui/src/pages/chat/components/chat-agent-run-frame.ts:57-89`。

### 附件与媒体

Control UI 的附件先经过 availability、managed media ticket 和 artifact download resolver，再按 image、audio、video、document、SVG 等类型选择组件。托管附件会缓存带过期时间的可用 URL，在过期前刷新；刷新失败显示 unavailable 状态并提供有限重试。见 `ui/src/pages/chat/components/chat-message-attachments.ts:105-220,334-352`。

图片可进入 lightbox，音频和视频使用对应媒体承载，文档以附件卡显示。附件 href 只接受相对路径、http、https、blob；audio 才额外接受格式严格的 `data:audio/...;base64`。见 `ui/src/pages/chat/components/chat-attachment-href.ts:1-29`。

SVG 预览不把服务端 SVG 字符串直接插入页面。`openclaw-chat-svg-attachment` 对同源 HTTP 资源执行 256 KiB 与 10 秒预算的 fetch，随后生成 blob URL 交给 `<img>`；跨源 HTTP、超限、失败或不可用资源降级为普通附件卡，见 `ui/src/pages/chat/components/chat-svg-attachment.ts:9-18,123-181,205-245`。

iOS 以 `OpenClawChatMessageContent.mediaKind` 和 artifact id 区分图片、音频、视频及普通文件，最多展示四张图片，其他图片显示隐藏数量。工具调用和结果按 id 配对；工具详情展开时默认显示最多 40 行，单行 diff 文本最多 2,000 个 Unicode scalar，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMessageViews.swift:612-660`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatToolActivityViews.swift:57-191`。

Android 对 inline image base64 设置 300 KiB 字符上限，managed image 通过 artifact loader 异步解码；每条 bubble 最多显示四张图片。音视频由 Media3/ExoPlayer 卡片承载，播放权由进程级 playback arbiter 管理，见 `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:7152-7199`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:1744-1865`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMediaPlayer.kt:169-284`。

### 提问、计划、子 agent 与特殊 marker

问题、progress card、subagent activity 和 outbox 不是普通 assistant 文本。Control UI、iOS 和 Android 都把它们作为独立的 transient row 或 activity group 装配；compaction/reset 则从 `__openclaw.kind` 转换成 divider。Android 的 `ChatTimelineItem` 明确列出这些 item，iOS 的 `ChatTranscriptRow` 明确列出 system notice 和 history divider，Control UI 则在 `chat-thread-build.ts` 中提前生成 notice/divider。

### Canvas、MCP、ACP 与节点内容

Canvas assistant message preview 会通过 tool-card 或 message 组件进入 widget card。Control UI 对内部 Canvas document 使用 sandboxed iframe，对 MCP App 使用 `mcp-app-view` 自定义元素和 AppBridge；普通 Markdown parser 不负责这些 widget 的 HTML。入口见 `ui/src/pages/chat/components/widget-card.ts:385-419,527-602`、`ui/src/components/mcp-app-view.ts:122-175`。

本次在 Gateway、TUI、Control UI、iOS 和 Android 的聊天渲染入口中未找到 ACP 专用的独立消息 renderer。Gateway 会识别 ACP session key 并沿 session/run 路径路由，客户端主要消费通用 chat、agent、session.message 和工具 payload；ACP 运行时产生的具体特殊 content 在本次范围内未单独建立样本验证。节点产生的 tool、Canvas 或 session message 若满足这些通用 payload 形态，会落入相应的通用工具、widget 或消息壳。

独立 Artifact 的创建、执行、持久化和复用不在本笔记范围内。这里仅记录 Canvas/MCP preview 作为聊天消息中的可见交接点，以及它们如何通过独立 widget surface 承载。

## 7. HTML、Artifact 与内容承载边界

### 普通 Markdown

Control UI 的普通 Markdown 允许 markdown-it 识别 raw HTML，但 raw HTML renderer 会转义内容；最终 DOMPurify 只保留显式的普通文本/结构化标签白名单，不保留 iframe、script、style。代码块里的 HTML 仍是代码文本或受控 block-art 文本。`unsafeHTML` 只接收经过 parser 和 DOMPurify 的字符串，见 `ui/src/components/markdown-parser.ts:61-75`、`ui/src/components/markdown.ts:25-92,502-537`。

iOS 和 Android 原生 Markdown 都把 HTML 作为文字或结构扫描输入，不把它当作可执行网页。两端的 Canvas widget 另走 WebKit/WebView；因此“普通 Markdown 中的 HTML”与“模型请求生成的 widget preview”是两个不同承载面。

### Canvas HTML iframe

Control UI 的 Canvas preview 使用 `<iframe sandbox="...">`。内部 Canvas document 只有在能识别为 OpenClaw 管理的 document URL 时才获得 prompt-capable bridge；外部允许的 embed URL 可以显示，但不会获得向聊天发送 prompt 的 authority。iframe 的高度由 postMessage 上报并被 48 至 1,200 px 夹紧，见 `ui/src/pages/chat/components/widget-card.ts:132-169,303-356`。

widget prompt 不能直接执行 slash command 或 privileged action。宿主要求 frame 已连接、可见并且当前获得焦点，文本最多 4,000 字符，不能以 `/` 或 `!` 开头；同一 rate key 每 60 秒最多 10 次。通过检查后才向拥有 chat pane 的 DOM 派发普通 `openclaw-widget-prompt` 事件，见 `ui/src/components/mcp-app-security.ts:15-99`。

### MCP App

MCP App 由 `McpAppView` 创建 AppBridge、PostMessageTransport 和 sandbox iframe。它向 app 提供 host context、theme、尺寸、CSP、server tools、openLinks 以及可选的 message/updateModelContext 能力；资源变更或组件断开时执行 bridge 与 transport teardown。实现入口见 `ui/src/components/mcp-app-view.ts:27-58,108-175,237-260`。MCP App 的具体工具执行生命周期属于 MCP/工具表面，本笔记只记录其在聊天消息中的挂载和卸载边界。

### iOS 与 Android 原生 widget

iOS 只接受 `/__openclaw__/canvas/documents/...` 形式的相对目标，并要求 capability surface 是 http/https、无 userinfo/query/fragment，且路径经过重复 percent decoding 后不能包含 `.`、`..`、slash 或 backslash。Widget resource 还携带 surface role 和 TLS fingerprint；失败后按 node、operator surface 等角色重新选择资源，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatInlineWidgetView.swift:54-70,159-206`。

Android 的 URL resolver 使用相同的 capability surface 和 canonical path 思路。Widget WebView 使用独立 profile，关闭 file/content access、DOM storage、mixed content 和多窗口；只有 sandbox 为 `scripts` 时启用 JavaScript，主文档导航要求与初始 document 相同。资源可使用 pinned TLS client，HTML 文档上限为 2 MiB，加载超时为 8 秒，见 `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatWidgetUrlResolver.kt:6-169`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatInlineWidgetView.kt:68-70,242-405,432-517`。

## 8. 内容交互反馈与可访问性

### Control UI

消息正文的操作栏提供复制、回复和对截断 assistant 消息的完整内容读取。Gateway 设置 `__openclaw.truncated` 后，assistant 行可以调用 `chat.message.get`；加载中、加载失败和重试状态由消息 disclosure 显示，不依赖正文中的 sentinel 文本，见 `ui/src/pages/chat/components/chat-message-markdown.ts:118-180,300-349`。

代码块复制由事件委托处理，按钮在成功、失败和两秒复位之间切换 aria label；代码块还可展开隐藏行或开启横向换行。用户长消息、tool card、raw details、activity group 和 work group 都使用 `aria-expanded` 与显式 toggle。见 `ui/src/components/markdown-code-blocks.ts:82-117,121-205`、`ui/src/pages/chat/components/chat-tool-cards.ts:135-188`。

工具卡的 review metadata 会显示 reviewing、approved、denied、timed out 等状态，并保留 rationale、risk level 和 authorization 信息；diff、raw output、Canvas preview 和 MCP view 各有独立展开或侧栏入口。实际 Gateway permission reply 和 Composer 工作流属于相邻 Chat UI 范围，本次只记录 card 与审批状态的显示交接。

### TUI、iOS 与 Android

TUI 的 Ctrl+O 切换所有工具输出展开状态，Ctrl+T 切换 thinking 显示；工具 output 默认显示预算内 Markdown preview，终态用颜色区分 pending、success 和 error。终端链接使用 OSC 8，文本通过 `sanitizeRenderableText`/`sanitizeMarkdownSource` 处理。

iOS 的消息 context menu 提供 copy、reply、full message、rewind、fork 和 assistant listen；文本使用 `.textSelection(.enabled)`，tool result 和 diff 的折叠按钮带有 accessibility label/value，见 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:581-670`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatToolActivityViews.swift:125-191`。

Android 的 ChatMessageActionHost 负责 reply、rewind、fork、listen 等操作；图片可以进入全屏 preview，托管图片加载失败显示 Tap to retry；widget 可以复制或保存为图片。ChatBubble、系统行、Markdown link、代码和 checkbox 都提供 Compose semantics 或内容描述，见 `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:1773-1887`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMessageViews.kt:366-489`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatInlineWidgetView.kt:92-239`。

这些可访问性标签、键盘/触摸绑定和加载分支可以由源码确认；实际屏幕阅读器朗读顺序、键盘焦点移动、动画表现和平台控件行为未运行验证。

## 9. 性能、缓存与测试

### 已确认的性能策略

Control UI 同时限制数据量和重绘范围：Gateway 历史有单消息/总字节预算，live buffer 上限 500,000 字符，工具流最多 50 条且输出最多 120,000 字符；Markdown 输入最多 140,000 字符，普通 parser 超过 40,000 字符走 plain-text fallback，缓存最多 500 项，单项最多 50,000 字符。Markdown cache key 包含 locale、代码块 chrome、file/session link、table interaction 和完整输入，避免不同 presentation 复用错误 HTML。

Control UI transcript 使用虚拟行、overscan、测量缓存、focused row 保留和 session scroll snapshot；thread builder 使用 message/group identity 做结构相等复用，`guardChatRenderItems` 避免只因旁边的 live row 变化而重建所有静态行，见 `ui/src/pages/chat/components/chat-transcript-render-guard.ts:7-51`、`ui/src/pages/chat/chat-thread.ts:77-238`。

TUI 用 180 个 component 的 bounded scrollback、200 个 stream assembler run 和每宽度的 Markdown render cache。它不保留完整 DOM 或 AST，工具输出在 render 时按宽度截断，适合终端内的有界交互。iOS 对完成的代码/数学内容使用缓存，对开放 fence 跳过高亮；Android 以 StateFlow、Compose `remember`、LazyColumn 和 base64/artifact 预算限制重组范围。

### 测试证据

本次定位到的相关测试包括：

- Gateway 显示投影：`src/gateway/chat-display-projection.test.ts`、`src/gateway/control-reply-text.test.ts`。
- Control UI 事件和历史：`ui/src/pages/chat/chat-gateway.test.ts`、`ui/src/pages/chat/chat-state.test.ts`、`ui/src/pages/chat/chat-history.test.ts`、`ui/src/pages/chat/chat-history-cursor.test.ts`、`ui/src/pages/chat/chat-history-subscription-errors.test.ts`。
- Control UI 渲染与预算：`ui/src/pages/chat/components/chat-transcript-render.test.ts`、`ui/src/pages/chat/components/markdown-streaming-highlight.test.ts`、`ui/src/e2e/chat-stream-runtime-budgets.e2e.test.ts`。
- TUI 流和 scrollback：`src/tui/tui-stream-assembler.test.ts`、`src/tui/components/chat-log.test.ts`、`src/tui/components/chat-log-run-state.test.ts`、`src/tui/tui-event-handlers.test.ts`。
- iOS 身份与 transport：`apps/ios/Tests/IOSGatewayChatTransportTests.swift`，以及共享 chat UI 的 Markdown、媒体和 typography 相关测试。
- Android 解码与 Markdown：`apps/android/app/src/test/java/ai/openclaw/app/chat/ChatMessageContentParsingTest.kt`、`ChatControllerMessageIdentityTest.kt`、`apps/android/app/src/test/java/ai/openclaw/app/ui/chat/ChatMarkdownTest.kt`。

上述文件证明项目为这些边界提供了回归测试入口，但本次没有运行测试、性能基准、构建或浏览器/原生视觉检查，不能据此推出长会话运行时性能。

## 10. 扩展方式与已确认边界

### 新增消息内容或工具

新增可见内容通常需要经过以下边界：

1. Gateway protocol 或 transcript display projection 能够携带该内容，并为它提供身份、预算和可见性规则。
2. `session-transcript-message.ts` 或对应历史路径能把它投影到 `session.message`/`chat.history`。
3. Control UI 的 message normalization、`chat-thread-build.ts` 和 grouping 能够决定它属于普通消息、activity、工具、divider 还是 stream。
4. `chat-message-bubble.ts`、tool card、media 或 widget registry 增加具体内容组件；如果内容是 HTML/iframe，则同时经过 Markdown allowlist 或 widget security boundary。
5. TUI 的 `tui-event-handlers.ts`、`TuiStreamAssembler`、`ChatLog` 和终端组件决定其 terminal projection。
6. iOS 的 `OpenClawChatMessageContent`/segmenter/view 与 Android 的 `ChatMessageContent`/parser/Compose view 分别增加原生投影。

新增工具的 Control UI 入口集中在 tool-card extraction、tool-call view、tool display registry 和 `chat-tool-cards.ts`；新增工具不应仅依赖 Markdown 正文猜测调用语义。TUI 和原生端没有复用 Control UI 的组件 registry，需要分别增加对应的 display mapping。

### 已确认的架构边界

- Gateway 负责显示安全、消息身份、序号、预算和 session/run 路由；客户端负责角色壳、布局、Markdown、滚动和平台交互。
- Control UI 与 TUI 共享 session identity/replay reducer，但不共享 HTML 或终端渲染器。
- iOS 与 Android 共享协议语义，不共享 Control UI 的 DOM renderer；二者各自维护 native content parser、media loader、widget host 和 scroll policy。
- `chat` 的实时文本不等于持久 transcript；终态之后仍需等待 `session.message` 或 history reconciliation 才能获得 durable identity。
- 普通 Markdown 是受限富文本；Canvas HTML 和 MCP App 是带 sandbox/bridge/CSP/TLS 约束的独立 widget surface。
- 独立 Artifact 的执行与持久化不属于普通消息 renderer；聊天表面只负责显示其 preview 或受控交接点。

## 11. 未验证事项

1. 未运行 OpenClaw 构建、TypeScript 测试、Swift 测试、Android 测试、浏览器页面或 iOS/Android 目标设备；视觉布局、实际字体、屏幕阅读器顺序和平台 WebView 行为均未观察。
2. 未对 Gateway live delta 在断线、seq gap、乱序、同 session 多 run、agent alias 切换和历史 cursor reset 下的实际运行结果做端到端验证；当前结论来自 reducer、generation 和事件处理分支。
3. 未对 Control UI virtualizer 的长 transcript 高度测量、分屏切换、focused row、MCP App 卸载和用户主动滚动进行浏览器性能或视觉测试。
4. 未对 Markdown-it、DOMPurify、highlight.js 和 URL parser 在浏览器实际版本中的默认行为做运行时组合验证；源码显式配置可确认的 allowlist 与 hook 已记录在正文。
5. 本次在 Control UI Markdown 文件范围内未找到 Mermaid/KaTeX 实际 renderer，但未扫描所有插件、独立 Canvas 文档或其他非聊天页面，因此不能作项目级“不支持”结论。
6. 未验证普通 Markdown 的 raw HTML、SVG attachment、Canvas iframe、MCP App bridge 在真实消息 payload 下的降级、资源过期、跨源导航、TLS pin 更新和 renderer crash recovery。
7. ACP session、node 事件和特殊工具 payload 在本次只确认了通用 Gateway 路由与客户端 generic tool/session 入口，未以实际运行样本确认每种特殊内容在所有客户端的最终视觉映射。
8. 未比较 TUI 180 component scrollback、iOS LazyVStack 和 Android LazyColumn 在极长 transcript、连续工具输出或大量图片下的真实内存和交互延迟。

## 12. 关键源码索引

### 协议、Gateway 与共享投影

- `packages/gateway-protocol/src/schema/logs-chat.ts:25-61,142-174,192-272`：`chat.history`、`chat.send`、实时 chat event schema。
- `packages/gateway-client/src/session-projection.ts:23-121,339-418,593-704`：session scope、消息 identity、snapshot/live reconciliation 和 run reducer。
- `src/config/sessions/session-accessor.sqlite-events.ts:9-35`：SQLite commit 后发出 transcript update。
- `src/gateway/server-session-events.ts:72-127,231-373`：session message 显示投影、序号读取和广播。
- `src/gateway/chat-display-projection.core.ts:305-353`：历史/实时消息的显示投影主入口。
- `src/gateway/chat-display-projection.sanitize.ts:588-617`：字符截断与 `__openclaw.truncated` marker。
- `src/gateway/session-transcript-message.ts:51-139`：`session.message` 与历史 transcript entry 的 payload 投影。
- `src/gateway/server-methods/chat-history-handler.ts:115-329,449-532`：历史读取、预算、in-flight run 和 cursor response。
- `src/gateway/server-methods/chat-history-pages.ts:167-207,210-329`：offset/anchor 历史窗口。
- `src/gateway/server-methods/chat-history-delta.ts:12-100`：有界 cursor 增量和 reset 条件。
- `src/gateway/live-chat-projector.ts:18-110`：assistant full text/delta 合并、隐藏控制内容和 live cap。
- `src/gateway/server-chat.ts:216-221,877-1109`：75 ms chat pacing、delta 广播和 terminal flush。

### Control UI

- `ui/src/pages/chat/chat-pane-context.ts:424-473`：连接恢复、选中 session subscription 和 startup history。
- `ui/src/lib/sessions/session-scoped-operations.ts:134-179`：session message subscription lease。
- `ui/src/lib/sessions/index.ts:414-504`：session.message/sessions.changed 的列表投影。
- `ui/src/pages/chat/chat-history.ts:847-1001,1592-1687,1769-1891`：订阅同步、历史请求共享和 cursor 应用。
- `ui/src/pages/chat/history-merge.ts:14-23,58-102,220-269`：pane-owned projection。
- `ui/src/pages/chat/session-message-apply.ts:63-176`：持久 session message 到 pane reducer。
- `ui/src/pages/chat/chat-state-events.ts:431-594`：Gateway event 到聊天状态和重绘请求。
- `ui/src/pages/chat/chat-thread-build.ts:75-215`：消息、工具、marker、queued send 到 ChatItem。
- `ui/src/pages/chat/chat-thread-grouping.ts:57-130,180-300`：MessageGroup、stream/work/activity group。
- `ui/src/pages/chat/chat-agent-run-grouping.ts:22-31,196-260`：agent-run-frame。
- `ui/src/pages/chat/components/chat-transcript-controller.ts:228-285,374-455`：虚拟列表、测量和渲染范围。
- `ui/src/pages/chat/components/chat-transcript-range.ts:3-39`：focused row 保留和虚拟范围预览。
- `ui/src/pages/chat/components/chat-message-group.ts:127-198`：消息组参数和内容装配。
- `ui/src/pages/chat/components/chat-message-bubble.ts:212-360`：role/message normalization、工具、附件和 Markdown 壳。
- `ui/src/pages/chat/components/chat-message-markdown.ts:98-180,300-349`：正文、截断消息读取、复制/回复和 streaming Markdown。
- `ui/src/components/markdown.ts:25-107,438-614`：DOMPurify allowlist、链接 hook、缓存与静态/流式入口。
- `ui/src/components/markdown-parser.ts:141-174,267-291,353-430`：markdown-it 插件、scheme 过滤和 file link。
- `ui/src/components/markdown-streaming.ts:104-287,289-328`：稳定前缀、fence/details 扫描和尾部修复。
- `ui/src/pages/chat/tool-stream.ts:32-75,1034-1201`：工具流身份、80 ms 节流和 120,000 字符预算。
- `ui/src/lib/chat/tool-cards.ts:35-187`：工具 call/result 提取、错误和脱敏。
- `ui/src/pages/chat/components/widget-card.ts:303-419,527-602`：Canvas/MCP widget iframe 和 chat surface。
- `ui/src/components/mcp-app-view.ts:122-175,237-260`：MCP App bridge、sandbox resource 和 teardown。
- `ui/src/components/mcp-app-security.ts:15-99`：widget prompt 文本、焦点和频率边界。
- `ui/src/pages/chat/components/chat-message-attachments.ts:355-612`、`chat-svg-attachment.ts:9-181`：附件、媒体票据和 SVG preview。

### TUI

- `src/tui/tui.ts:930-950,1739-1800`：ChatLog 装配、Gateway event handler 和 session subscription。
- `src/tui/tui-event-handlers.ts:170-380,502-619`：chat、session.message、agent 事件处理。
- `src/tui/embedded-backend.ts:1284-1357`：embedded agent event 到 chat/agent projection。
- `src/tui/tui-stream-assembler.ts:10-18,111-259`：per-run thinking/content/final 合并。
- `src/tui/components/chat-log.ts:32-161,445-611`：有界 scrollback、assistant/tool/user component 生命周期。
- `src/tui/components/hyperlink-markdown.ts:12-64`：pi-tui Markdown、sanitized source 和 OSC 8。
- `src/tui/components/tool-execution.ts:23-72,111-193`：工具输出预算、展开和错误样式。

### iOS 与 Android 原生聊天

- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTransport.swift:4-18`：iOS transport event union。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+TransportEvents.swift:25-92,397-601`：iOS event 分派、session message 和 chat final。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:527-547,880-999`：iOS event task、bootstrap、history 和 subscription。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+RunSnapshot.swift:5-69`：iOS in-flight run adoption。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatModels.swift:117-213,402-583`：iOS message/content model 和 decoder。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:351-537,540-705,928-1021`：iOS LazyVStack transcript、实时行与滚动。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTranscriptRows.swift:3-155`：iOS system/divider/message row projection。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMessageViews.swift:288-360,394-660`：iOS message bubble、正文、工具和附件。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMarkdownBlockSegmenter.swift:4-20,150-273`：iOS structural Markdown segmentation。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMarkdownRenderer.swift:149-300`：iOS Markdown block renderer。
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatInlineWidgetView.swift:54-70,159-206,295-405`：iOS Canvas widget URL/TLS/WebKit surface。
- `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatModels.kt:11-35,82-110`：Android visible message/content model。
- `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:3232-3307,5508-5627,5820-5951`：Android Gateway event handlers。
- `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:3822-3970,6540-6573,7143-7261`：Android history apply、message decode 和 content parser。
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatTimeline.kt:13-162,345-443`：Android timeline item model 和 stable key。
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:1304-1487,1707-1887`：Android LazyColumn 和 ChatBubble 分派。
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatReaderScrollController.kt:76-152,177-277`：Android scroll anchor/follow state。
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMarkdown.kt:93-349,640-772`：Android CommonMark、details、HTML literal 和 safe links。
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMessageViews.kt:351-537`：Android image、preview 和 code block。
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatInlineWidgetView.kt:68-70,242-405,432-517`：Android isolated WebView widget。
