# OpenClaw Chat UI 调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：直接阅读源码，沿 Control UI、TUI、共享 Apple Chat UI、iOS 容器和 Android 原生 Chat UI 的入口、事件处理、会话操作及恢复路径进行静态调查；未运行目标界面和真实 Gateway 流程
>
> 调查范围：项目自有的 Control UI、TUI、iOS/Apple 原生聊天表面和 Android 原生聊天表面的工作台结构、会话导航与恢复、Composer、发送与生成反馈、消息操作、分支、多会话和状态同步；外部 Telegram、Discord 等客户端 UI，以及会话数据和请求执行的专项语义不在本笔记展开
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的聊天表面分成四个实现层：浏览器中的 Control UI、终端 TUI、共享的 SwiftUI Chat UI，以及 Android Compose Chat UI。它们都以 Gateway 会话和事件为远端事实来源，但保留各自的输入、局部状态和恢复存储，因此“同一会话可在多表面继续”与“草稿、滚动位置、临时附件不会自动成为跨平台共享状态”是两个不同层次的事实。

- **Control UI** 是功能最完整的聊天工作台。`ChatPage` 支持多 pane、分屏、可停靠辅助面板和按会话保留的 pane 现场；`ChatPane` 把消息线程、Composer、模型控制、审批/问题、后台任务、工作区和浏览器/桌面面板组合在一起（`ui/src/pages/chat/chat-page.ts:57-126`、`ui/src/pages/chat/chat-pane-layout-render.ts:49-167`）。
- **TUI** 是单个终端工作区，结构是 header、滚动聊天记录、状态区、footer 和多行编辑器。命令、选择器和键盘快捷键是主要入口，Gateway 连接、历史重载和运行生命周期由独立控制器协作完成（`src/tui/tui.ts:918-971`、`src/tui/tui.ts:1416-1652`）。
- **Apple 原生 Chat UI** 由 `OpenClawChatView`、`OpenClawChatComposer` 和 `OpenClawChatViewModel` 组成。iOS 的 Chat Pro 页面使用该原生视图，并把 Dashboard 作为经过认证的 Control UI WebView 打开；共享 ViewModel 负责消息、会话、模型、问题、工具、离线 outbox 和运行恢复（`apps/ios/Sources/Design/ChatProTab.swift:191-247`、`apps/ios/Sources/Design/ChatProTab.swift:494-526`）。
- **Android** 使用原生 `ChatScreen`，在同一页面放置 header、Agent/会话选择、消息时间线、进度与后台任务入口和 Composer；Gateway 交互与持久化 outbox 位于 `ChatController`、`ChatCommandOutbox`（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:657-945`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:651-730`）。
- **发送恢复的共同原则** 是先保留用户输入，再用消息历史或带身份的运行事件确认交付。Control UI、Apple 和 Android 都把“已收到 ACK”与“已写入 canonical history”区分开；不确定的交付会停在可见的待确认/失败状态，而不是静默重发（`ui/src/pages/chat/chat-outbox-drain.ts:159-245`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Outbox.swift:24-28`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:60-73`）。

## 工作台边界与总体调用链

各表面的主链可以概括为：

```text
进入聊天表面
  -> 解析或选择 Agent / session
  -> 加载历史、运行快照和局部 Composer 现场
  -> 输入文本、命令、附件或语音
  -> 发送、排队或进入本地命令处理
  -> 消费 Gateway ACK、delta、final、tool、question、approval 和 session 事件
  -> 操作消息、分支、会话或后台任务
  -> 切换、刷新、断线重连后按 session identity 恢复
```

- **Control UI**：`ui/src/main.ts` 只负责启动样式、服务 worker 和资源恢复；应用路由把动态 session URL 映射到 `chat` 或 `dashboard` 页面，页面 loader 再解析 session、Agent、face、短 ID、歧义候选和 draft 查询参数（`ui/src/main.ts:1-43`、`ui/src/app-routes.ts:78-164`、`ui/src/pages/chat/route.ts:61-95`、`ui/src/pages/chat/route-loader.ts:50-69`）。
- **TUI**：`runTui` 建立 `GatewayChatClient`、`ChatLog`、`CustomEditor`、overlay、session actions、command handlers 和 event handlers；编辑器提交先经过 admission，再按命令、local shell 或普通消息分派（`src/tui/tui.ts:1416-1652`、`src/tui/tui-submit.ts:33-105`）。
- **Apple**：iOS `ChatProTab` 创建带 Gateway transport、transcript cache 和 outbox 的 `OpenClawChatViewModel`，再交给共享 `OpenClawChatView`；iOS `SessionDashboardScreen` 是另一条 WebView 路径，不与原生时间线共享视图层（`apps/ios/Sources/Design/ChatProTab.swift:211-247`、`apps/ios/Sources/Design/ChatProTab.swift:494-526`、`apps/ios/Sources/Chat/SessionDashboardScreen.swift:4-28`）。
- **Android**：`UnifiedChatShellScreen` 把 talk 模式和 `ChatScreen` 放入统一 scaffold；`ChatScreen` 从 `MainViewModel` 收集会话、消息、运行、问题、模型、outbox 和 Composer 状态，`ChatController` 负责把这些状态连接到 Gateway（`apps/android/app/src/main/java/ai/openclaw/app/ui/UnifiedChatScreen.kt:16-48`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:273-420`）。

边界：消息内容如何完整渲染属于消息渲染器类目；会话树、消息身份和持久化数据模型属于会话与消息管理；Gateway 请求的并发、取消、队列执行和上下文构建属于对话请求与上下文。本笔记只记录用户能从聊天表面发现、触发、观察和恢复的工作流。

## 1. 页面结构、导航与多窗口

### Control UI

Control UI 有 `chat` 和 `dashboard` 两个聊天页面定义。应用路由先把动态 session 路径桥接到静态 route，再由 loader 产生实际 session route data；短 ID 无法唯一解析时，页面会列出 Agent、显示名和可用 ID 前缀供用户选择，而不是直接打开任意候选（`ui/src/pages/chat/route.ts:13-33`、`ui/src/pages/chat/route-loader.ts:174-260`）。

`ChatPage` 是聊天工作台的布局所有者。它读取持久化的 `chatSplitLayout`，按 viewport 维护 `narrow` 和移动导航状态，使用 pane ID 管理多个会话视图；桌面端可通过分割、关闭、聚焦、拖放会话和调整列宽改变布局，移动窄屏会关闭分割拖放路径（`ui/src/pages/chat/chat-page.ts:57-126`、`ui/src/pages/chat/chat-page.ts:216-260`、`ui/src/pages/chat/chat-page.ts:384-404`）。pane 还由 retained-session 控制器保留会话现场，使切换回一个已经打开过的 pane 时可以复用局部状态，而不是只依赖当前 URL。

单个 `ChatPane` 的布局由 primary column 和可选 sidebar region 组成。primary column 包含当前会话 header、消息线程和 Composer；辅助区域可呈现 session workspace、background tasks、detail、browser、desktop、companion/discussion 等面板，面板是否可用受当前 board、Gateway capability、会话和 pane 宽度共同决定（`ui/src/pages/chat/chat-pane-layout-render.ts:68-167`）。

### TUI

TUI 没有桌面式侧栏和多窗口布局，而是保持一个当前 Agent/session 的全屏终端工作区。`ChatLog` 负责滚动记录、pending user、streaming assistant、tool、系统通知和 BTW 结果；`CustomEditor` 位于底部，状态区和 footer 位于消息记录与编辑器之间（`src/tui/tui.ts:927-950`、`src/tui/components/chat-log.ts:32-52`）。overlay 用于模型、Agent、session、设置、审批等选择器；关闭最后一个 overlay 时把焦点恢复到编辑器（`src/tui/tui-overlays.ts:5-28`）。

### Apple 与 Android

共享 Apple 视图把消息列表、进度/turn recap、swarm 进度和 Composer 按纵向结构组合；macOS 与非 macOS 使用不同的间距、safe-area 和键盘处理参数。消息列表使用 `ScrollView` + `LazyVStack`，Composer 是否带完整 chrome、是否显示 session switcher、是否接受附件由调用者决定（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:184-232`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:318-376`）。

iOS Chat Pro 使用原生 clean-chat 表面，session 列表、background tasks、新建会话、Dashboard 和 transcript 分享通过 sheet 或导航入口打开；Dashboard 页面自身嵌入认证 Control UI，并提供返回和打开 Desktop 的导航动作（`apps/ios/Sources/Design/ChatProTab.swift:170-247`、`apps/ios/Sources/Chat/SessionDashboardScreen.swift:11-58`）。

Android 原生页面使用 `ClawScaffold`。header 提供侧栏、刷新、新建会话、分支、Dashboard 和后台任务入口，下一行是 Agent selector 与 session switcher，主体是 `ChatMessageList`，底部是 Composer；分支和模型选择器以 bottom sheet 展示（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:657-745`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:947-979`）。

本次没有确认 Control UI 是否支持独立浏览器窗口之间的完整 pane UI 状态同步。代码能确认 Gateway 事件和浏览器 storage 变化有同步入口，但实际多窗口的滚动、焦点和临时 Composer 状态需要运行观察。

## 2. 会话列表、搜索与现场恢复

### 列表、分组和定位

Control UI 的 session 侧栏把 Gateway session row 投影为可见的 sidebar row。投影包含 pinned、archived、category、Agent owner、子会话、运行/失败/未读、Composer draft、outbox attention、worktree 和后台状态；子会话可以嵌套显示，运行中或带 attention 的子项绕过普通子项数量限制（`ui/src/components/app-sidebar-session-navigation-logic.ts:148-290`、`ui/src/components/app-sidebar-session-row-render.ts:150-161`）。

侧栏支持 pinned、category/recent 分区、状态过滤、显示 cron/system、预览和按创建/更新时间/owner 排序。普通点击导航到 session，Shift/Alt 选择多行；session、section 和子会话都有拖放或展开入口，行菜单提供 pin、归档、删除等动作（`ui/src/components/app-sidebar-session-navigation.ts:127-175`、`ui/src/components/app-sidebar-session-navigation.ts:309-367`、`ui/src/components/app-sidebar-session-navigation.ts:418-467`、`ui/src/components/app-sidebar-session-row-render.ts:241-284`）。

Control UI 的 command palette 还提供跨 session 搜索。搜索状态包含失败、部分结果和不完整结果标记；Gateway 支持 `sessions.search` 时，结果可以结合 session metadata 和 transcript 命中，搜索请求使用请求 ID 避免旧查询覆盖新查询（`ui/src/components/command-palette.ts:300-313`、`ui/src/components/command-palette.ts:471-624`、`ui/src/components/command-palette-session-search.ts:1-40`）。这与当前线程内的 pane-local transcript search 是两条路径：后者只维护当前 pane 的查询和焦点返回目标（`ui/src/pages/chat/components/chat-thread-interactions.ts:43-61`、`ui/src/pages/chat/components/chat-thread-interactions.ts:212-301`）。

TUI 的 `/session` 和 `/sessions` 打开有限的 recent session 选择器。查询先尝试完整 key，再尝试唯一 substring，最后使用 fuzzy 匹配；多个命中返回 ambiguous candidates，避免把模糊输入静默解析到错误会话（`src/tui/tui-session-picker.ts:28-43`、`src/tui/tui-session-picker.ts:74-107`）。列表项组合显示名、key、更新时间和最后消息预览。session 选择后，旧 session 的运行 owner、projection、ChatLog、BTW 和 session info 先被清理，再加载新 session 历史（`src/tui/tui-session-actions.ts:86-123`）。

共享 Apple 侧栏以 `Pinned`、自定义 group 和 `Recent` 组织树形 session；macOS 侧栏直接提供搜索、New Thread、rename、pin、fork、unread、archive、copy key 和 delete 菜单（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSessionSidebar.swift:25-118`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSessionSidebar.swift:251-320`）。`ChatSessionsSheet` 提供 Active/Archived 切换、服务端搜索、批量选择、group 管理和删除确认；搜索或 archived 模式使用 scoped fetch，默认 active 列表使用 ViewModel 当前快照（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSheets.swift:42-55`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSheets.swift:65-147`）。

Android 的独立 Threads 页面提供 Recent、Current、Archived 过滤，文本搜索、Newest/Oldest 排序和 Compact/Detailed 布局；聊天页本身还提供轻量 session switcher，完整搜索进入 Threads 页面（`apps/android/app/src/main/java/ai/openclaw/app/ui/SessionsScreen.kt:165-223`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:692-715`）。

### 新建、切换和恢复

- Control UI 的侧栏选择先计算 session 的 preferred face 和 navigation target，再通过 navigation handoff 提交；route loader 负责把短 ID、slug、Agent scope 和 draft/focus 参数解析成 canonical route（`ui/src/components/app-sidebar-session-navigation.ts:309-333`、`ui/src/pages/chat/route-loader.ts:238-260`）。
- TUI 通过 `/new`、`/reset`、`/session` 和选择器完成新建、重置与切换。切换会递增历史加载 generation，只有仍属于当前 session、当前 generation 和当前 Agent 的异步结果才能重建 ChatLog（`src/tui/tui-session-actions.ts:424-451`、`src/tui/tui-session-actions.ts:453-519`）。
- Apple ViewModel 的 `startNewSession` 使用 transport route lease 创建新 session，创建完成后才采用新 key；支持 worktree 或 Agent 的请求不会在 `sessions.create` 不支持时静默降级成无等价语义的 reset（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:29-103`）。切换或删除当前 session 后，ViewModel 回到 resolved main session，或者在 main session 被删除时清理并原地重新 bootstrap（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:587-617`）。
- Android `ChatController.load` 会把 `main` 规范化为 Gateway 提供的主 session key，并用 generation 让旧的 history response 失效；Gateway 断开时保留 optimistic user echo 和恢复所需的 pending run 归属，重新连接后以 history/运行快照完成恢复（`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:690-730`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:916-931`）。

Control UI 的 session route 和 Composer 存储都带 Gateway owner、session scope、Agent scope。对于 `main`、`global` 和配置的 main alias，在默认 Agent 尚未加载时会先保留 unresolved scope，避免重连或默认 Agent 改变后把草稿、队列或历史映射到另一个 owner（`ui/src/lib/chat/outbox-store.ts:190-256`、`ui/src/lib/chat/outbox-store.ts:432-455`）。

## 3. Composer、草稿、附件与快捷输入

### Control UI

Control UI Composer 是多行 textarea，支持普通文本、slash command、skill 菜单、上下文/引用回复、附件、dictation、realtime talk 和发送/停止切换。Composer 在输入事件中同步 textarea 高度、draft、slash/skill 菜单和 typing presence；输入法 composition 期间暂存 composing draft，问题面板 takeover 前会先提交这份暂存文本（`ui/src/pages/chat/components/chat-composer.ts:79-205`、`ui/src/pages/chat/components/chat-composer.ts:261-328`）。

附件处理区分普通文件、图片/视频等 payload 和浏览器 annotation。普通 slash command 使用原始 Composer 文本，annotation context 只附加到下一条模型消息，不会把已经识别出的命令改成普通 prompt（`ui/src/pages/chat/chat-send-submit.ts:219-239`）。消息上下文还支持选中文本后发起 side question 或 more-details companion 请求（`ui/src/pages/chat/components/chat-thread-interactions.ts:402-425`）。

Control UI 的 Composer 状态分为两层：

- 文本、队列元数据和 draft revision 使用按 Gateway owner 隔离的浏览器 storage；存储 key 为 v2 owner key，session scope 再区分 conversation 和 Agent，storage event 会使其他浏览器上下文的 outbox projection 失效（`ui/src/lib/chat/outbox-store.ts:28-35`、`ui/src/lib/chat/outbox-store.ts:91-138`、`ui/src/lib/chat/outbox-store.ts:560-617`）。
- 带真实二进制 payload 的 durable draft 使用按 Gateway、recovery scope 和 Composer scope 组织的 IndexedDB。数据库、7 天过期、每个 owner 的活动 draft 数量和附件大小上限由运行时模块定义；读取异步完成后会再次校验当前 scope、revision 和 signature，避免旧恢复覆盖新输入（`ui/src/lib/chat/composer-draft-store.runtime.ts:4-10`、`ui/src/lib/chat/composer-draft-store.runtime.ts:281-320`、`ui/src/pages/chat/durable-composer-persistence.ts:198-311`）。

普通的 browser annotation 和附件 payload 还会在发送、队列删除、失败恢复和 Composer 替换时释放内存引用；因此队列行持久化的是可恢复的附件元数据/Blob，而不是只保留一个已经失效的 object URL。

### TUI

TUI `CustomEditor` 基于 pi-tui 的多行 editor，额外接入 Alt+Enter、Alt+Up、Ctrl+L、Ctrl+O、Ctrl+P、Ctrl+G、Ctrl+T、Shift+Tab、Escape、Ctrl+C 和空编辑器 Ctrl+D 等快捷键（`src/tui/components/custom-editor.ts:46-109`）。

提交时按顺序区分空文本、以 `!` 开头的单行 local shell、单行 slash command 和普通消息；普通消息可以在 Windows Git Bash 或指定终端环境下使用短 burst window 把快速到达的多行粘贴重新组合成一个提交（`src/tui/tui-submit.ts:11-105`、`src/tui/tui-submit.ts:108-138`、`src/tui/tui-submit.ts:140-236`）。编辑器还保护“trim 后会变成可执行 bang line”的文本，避免历史回填或提交清理意外改变用户意图（`src/tui/components/custom-editor.ts:118-148`）。

本次检查的 TUI 输入路径没有找到跨进程 durable Composer draft 存储；编辑器文本、输入历史和 pending submit 属于当前 TUI 进程状态。TUI 会记住最后 session key，但这不等同于保存未发送的编辑器草稿，具体运行行为仍需实测。

### Apple 与 Android

共享 Apple ViewModel 显式维护按 session 的 `draftsBySession` 和 `inputHistoriesBySession`，而 native attachments 在内存中保存；attachment staging 期间会阻止切换，防止文件/图片处理完成后把 payload 交给错误会话（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:18-39`）。Composer 在 macOS 支持文件拖入，在 iOS/iPadOS 支持 PhotosPicker、文件导入和 camera；共享视图还可接入 dictation、voice note 和 talk control（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatComposer.swift:116-185`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatComposer.swift:242-278`）。

Android 用 `ChatComposerStateStore` 以 `ChatComposerOwner` 为键保存文本 draft、附件、媒体 acquisition、附件遗漏提示和 send gate。owner alias 解析时会同时迁移文本、附件、send state 和提示，避免 Gateway 把 `main` 规范化后只迁移了其中一部分局部状态（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatComposerStateStore.kt:42-70`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatComposerStateStore.kt:267-313`）。

Android 的 durable command outbox 把附件分块写入数据库中的 BLOB 行，不把 base64 作为静态存储格式；Composer 发送前会校验单条命令、视频和每个 Gateway 的总附件预算（`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:47-58`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:147-187`）。

## 4. Agent、模型、工具与发送前配置

Control UI 的发送前配置位于 Composer 上方或其控制区，当前已确认包括 Agent、模型目录、thinking/effort、fast/context window 和 permission mode。模型选择器会根据当前 session、Agent 默认值、模型目录加载状态、model lock 和 Gateway method access 决定是否可用；权限选择器在 session 运行中修改时，会以“作用于下一次运行”的提示反馈（`ui/src/pages/chat/chat-pane-session-controls.ts:37-79`、`ui/src/pages/chat/chat-pane-session-controls.ts:81-215`）。

Control UI 会把 capability 和权限检查放在渲染入口附近。模型目录未加载、模型不可用、只读共享 session、placement startup 或 catalog 只读等情况会产生明确的 `disabledReason`，Composer 不会只显示一个没有解释的 disabled 按钮（`ui/src/pages/chat/chat-pane-render.ts:151-228`）。

TUI 使用命令和选择器完成同类配置。命令 descriptor 当前覆盖：

```text
/agent /agents
/session /sessions
/model /models
/think /fast /verbose /trace /reasoning
/usage /elevated /activation
/queue /stop /new /reset /abort
/settings /auth /gateway-status
```

命令清单、scope、shared 标记和参数补全由 `TUI_COMMAND_ROWS` 生成；thinking、verbose、reasoning、fast、elevated 和 activation 等值用于命令补全，而不是散落在输入处理器中（`src/tui/commands.ts:17-32`、`src/tui/commands.ts:73-174`）。模型和 Agent 选择器是 overlay，选择完成后通过 `patchSession` 或 session action 更新当前 session，并用 incarnation 检查防止旧请求回写到新 session（`src/tui/tui-command-handlers.ts:275-328`、`src/tui/tui-command-handlers.ts:332-349`）。

共享 Apple ViewModel 把模型选择、收藏/最近使用、thinking override、verbose 和 fast mode 组织为 session settings 操作；`thinkingOverrideIsInherited`、`verboseLevel` 和 `fastModeSelectionID` 用于区分“继承 Agent/session 默认值”和“当前 session 有显式覆盖”（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+ModelControls.swift:6-70`）。iOS transport 为模型列表、slash command、session settings、branch、fork 和 rewind 提供 Gateway 请求实现（`apps/ios/Sources/Chat/IOSGatewayChatTransport.swift:88-173`、`apps/ios/Sources/Chat/IOSGatewayChatTransport.swift:530-678`）。

Android ChatScreen 暴露 thinking 选择、模型 bottom sheet、模型收藏/最近使用和 session branch switcher；模型选择实际调用 `setChatSessionModel`，分支切换在没有运行、没有未解决 outbox 且 branch 数据已恢复时才启用（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:642-675`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:805-843`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:947-973`）。

工具审批和问题提示分别在各表面的 Composer/overlay/timeline 中出现：Control UI 将 inline approval、question prompt、tool stream 和 background task 作为 ChatPane props；TUI 的 plugin approval controller 按当前 Agent/session 过滤、排序和过期审批，使用 overlay selector 提供 allow-once、allow-always、deny 等选择（`ui/src/pages/chat/chat-pane-render.ts:136-183`、`ui/src/pages/chat/chat-view.ts:90-177`、`src/tui/tui-plugin-approvals.ts:209-300`）。

本次在已检查的 Control UI Composer 控制文件中没有找到 temperature 等通用参数的直接编辑控件。该结论只适用于这些入口的静态检查，不代表 Gateway 或 Agent 配置层没有相应参数。

## 5. 发送、排队、流式反馈与停止

### Control UI 发送和 durable outbox

Control UI 的 `handleSendChat` 先保存原始 draft、附件、session key、显示 leaf 和提交时间，再解析 stop alias、slash command、local command、reply target 和普通消息。普通消息会进入 pending send queue，持久化 admission 成功后由 delivery 层发送；如果同一 session 正在运行，队列项会根据 follow-up mode 记录 `queueMode`，并保留 expected leaf 以避免发送到已改变的分支（`ui/src/pages/chat/chat-send-submit.ts:197-239`、`ui/src/pages/chat/chat-send-submit.ts:469-591`）。

队列项的状态包括等待模型设置、等待重连、sending、waiting-idle、executing-command、failed 和 unconfirmed 等展示/恢复状态。普通消息与 local slash command 共用 Gateway-scoped outbox，但 local command 需要额外的连接、session 可见性和顺序约束（`ui/src/pages/chat/chat-queue.ts:37-59`、`ui/src/pages/chat/chat-send-delivery.ts:135-239`、`ui/src/pages/chat/chat-outbox-drain.ts:347-566`）。

恢复 drain 时，Control UI 先查询当前 session history。如果 history 已经包含同一 queued user turn，就把 server history materialize 到本地并移除 queue bubble；如果 ACK/请求曾经开始但 history 在确认窗口内仍没有证明，则将行停在 `unconfirmed`，提示用户检查会话后再重试（`ui/src/pages/chat/chat-outbox-drain.ts:159-245`、`ui/src/pages/chat/chat-outbox-drain.ts:280-344`）。不确定的 `/clear` 还会把后继队列项标成需要人工复核的 barrier，防止清空命令的未知结果被后续输入越过（`ui/src/pages/chat/chat-outbox-drain.ts:497-559`）。

### 事件、流式和停止

`chat-gateway.ts` 将 Gateway chat event 的 delta、final、aborted 和 error 规范化为当前 session projection。delta 既可以是追加文本，也可以是 replace/snapshot；final 会和历史消息按 run/message identity 去重，避免一个回答同时出现 event bubble 和 persisted history bubble（`ui/src/pages/chat/chat-gateway.ts:61-137`、`ui/src/pages/chat/chat-gateway.ts:200-300`）。`chat-state-events.ts` 进一步处理 session.message、sessions.changed、branch/reset/new 原因、运行终态和历史 reload；事件没有精确消息 cursor 时会回退到 scoped authoritative history（`ui/src/pages/chat/chat-state-events.ts:138-197`、`ui/src/pages/chat/chat-state-events.ts:224-303`）。

停止入口由当前运行身份决定。Control UI 优先发送带精确 `runId` 的 `chat.abort`；没有 browser-local run ID 时使用选定 session 的 `sessions.abort`，断线时只有拥有精确 run identity 的 abort intent 才会在同一 Gateway client 上重放，否则显示 disconnected 原因（`ui/src/pages/chat/run-lifecycle.ts:96-124`、`ui/src/pages/chat/run-lifecycle.ts:200-284`）。Composer 的 in-progress label 区分 sending、responding、waiting approval、preparing model 和 working，终态再显示 done/interrupted 的 live-region 文本（`ui/src/pages/chat/components/chat-composer.ts:79-175`）。

### TUI 发送和生成状态

TUI 提交 admission 明确区分 `sending` 与 `accepted` pending submit，以及 disconnected、pending、session-transition 三类阻塞。被阻塞的消息会恢复到编辑器并在 ChatLog 中说明原因，避免 pi-tui 清空编辑器后用户输入消失（`src/tui/tui-submit-state.ts:3-18`、`src/tui/tui-submit-state.ts:23-116`、`src/tui/tui-submit.ts:46-105`）。

事件处理器收到 delta 时更新 stream assembler、ChatLog assistant 和 streaming watchdog；final 会 materialize projection、刷新历史或保留已经显示的 final；aborted 会尽可能保留已产生的文本并追加 `run aborted` 诊断；error 会进入终态错误显示（`src/tui/tui-event-handlers.ts:170-379`）。运行生命周期还负责在重连时重新采用活动 run、在当前 run 结束后提升仍在运行的另一个 run，并在长时间没有 delta 时显示等待提示（`src/tui/tui-run-lifecycle.ts:78-152`、`src/tui/tui-run-lifecycle.ts:224-303`）。

TUI 的 Escape 绑定到 abort active，Ctrl+C 首次清空输入、再次操作才退出，Ctrl+D 在空编辑器中退出；overlay 关闭和工具展开等展示操作不会错误清除运行中的 activity status（`src/tui/tui.ts:1654-1721`）。Gateway 连接本身在 `GatewayChatClient` 中维护 ready promise、重连后的 ready 状态、事件 gap 和连接错误提示（`src/tui/gateway-chat.ts:178-257`、`src/tui/gateway-chat.ts:271-319`）。

### Apple 与 Android

Apple 的 `canSend` 要求没有提交中的 draft、发送中的请求、attachment staging、blocking run activity，并且有文本或附件；真正发送前先捕获 session snapshot 和 Composer revision，之后才进行 slash catalog、health、route lease 和 outbox 判断（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:13-47`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:361-437`）。

有健康 Gateway 时，Apple 会先写 optimistic user row，清空 Composer，再用 idempotency key 发送。Gateway 返回的 remote run ID 如果不同于本地 key，ViewModel 会把 optimistic row 和 run scope 重新绑定；请求失败时，若无法区分“未发送”和“可能已发送”，就保存到 durable outbox，而不是直接丢弃用户文本（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:540-590`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:629-767`）。

Apple outbox 的可见状态为 queued、sending、confirming、failed。ACK 只把状态移到 confirming，canonical `chat.history` 才负责退休 durable row；用户可以对 failed 行显式 retry 或 delete（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Outbox.swift:7-28`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Outbox.swift:274-360`）。

Android 的 `ChatCommandOutbox` 使用 Queued、Sending、Accepted、Failed；Accepted 的注释明确说明 started ACK 早于 transcript write，因此只有 history confirmation 才能退休。连接变化、delivery unconfirmed、owner changed、branch changed 和过期都会保留为用户可见的错误状态（`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:14-36`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:60-79`）。断线时 `ChatController.onDisconnected` 清理临时连接状态，但保留 optimistic message 和 pending run 归属，随后重新发布当前 Gateway 的 outbox（`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:690-730`）。

## 6. 消息操作、分支与版本导航

### Control UI

Control UI 的 transcript 对每个 pane 维护 search state、reply target、消息 context menu 和 pointer selection。右键或触摸消息可进入 copy selection、reply、rewind、copy markdown、fork 等动作；正在 streaming 或 reading 的消息会禁用需要稳定历史边界的 rewind/fork，菜单关闭时把焦点交回 Composer（`ui/src/pages/chat/components/chat-thread-interactions.ts:440-582`、`ui/src/pages/chat/components/chat-thread-interactions.ts:597-610`）。

`ChatPane` 把消息级 rewind/fork 连接到 session action callbacks，并通过当前 Gateway access 再检查 compact、abort、rewind、fork、reset 是否可用；执行失败时由当前 pane 或全局错误入口显示原因（`ui/src/pages/chat/chat-pane-session-controls.ts:217-266`）。分支改变会退休旧 branch request、清理 branch cache、刷新历史和 workspace checkout，避免旧分支的请求或工具结果继续显示（`ui/src/pages/chat/chat-state-events.ts:236-260`）。

当前线程内搜索是 pane-local 的文本框，不会改变 URL；打开时保存触发按钮和 owner，关闭后优先恢复原按钮，否则聚焦 Composer（`ui/src/pages/chat/components/chat-thread-interactions.ts:212-301`）。跨 session 搜索则由 command palette 的 Gateway search 处理，命中后再导航到对应 session。

### TUI、Apple 与 Android

本次在 TUI 的 `TUI_COMMAND_ROWS` 和已检查的 command handler 中确认了 session、model、agent、queue、stop、new、reset、abort 等命令，但没有找到与 Control UI 右键消息菜单对应的独立消息级 rewind/fork 入口。TUI 的 session action 重点是切换、历史重建、运行终态和 session metadata；不能据此断言项目其他 TUI 扩展不存在消息操作（`src/tui/commands.ts:92-174`、`src/tui/tui-command-handlers.ts:461-655`）。

共享 Apple Chat UI 的长按/菜单入口支持 Listen、Copy、Select text、Share、Reply；对带稳定 transcript entry ID 的 user message，还支持 Rewind to here 和 Fork from here（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMessageViews.swift`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:378-438`）。ViewModel 在 rewind 后接收 Gateway 返回的 editor text/attachments，刷新历史和 branch；fork 后切换到新 session 并恢复 editor 内容（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:401-438`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:641-679`）。

iOS 还提供 transcript Markdown 文件的系统分享 sheet；这属于导出/分享入口，文件内容口径由相邻导出类目负责（`apps/ios/Sources/Chat/ChatTranscriptShareSheet.swift:4-12`、`apps/ios/Sources/Design/ChatProTab.swift:170-205`）。

Android 通过消息长按菜单提供 Listen、Copy、Select text、Share、Reply，并在 session action 可用时提供 Rewind from here 和 Fork from here；`ChatScreen` 将这些动作绑定到 `rewindChatAtEntry`、`forkChatAtEntry`，同时把返回的 editor text/attachments 写回新的 Composer owner（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMessageActions.kt:48-121`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:724-788`）。Android branch switcher 是独立的 header bottom sheet；它与 rewind/fork 后的 history/branch refresh 共同决定当前可见版本（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:960-973`）。

## 7. 多会话、多模型、群聊与后台生成

Control UI 的多会话能力主要表现为 split panes、sidebar 子会话树和 background task rail。每个 pane 有自己的 session key、ChatState、Composer scope、tool stream 和 scroll state；sidebar row 同时投影当前 session、child session、active run IDs、unread、outbox attention 和 observer digest，因此切换 pane 后仍可从列表看到其他会话是否运行或失败（`ui/src/pages/chat/chat-view.ts:91-151`、`ui/src/components/app-sidebar-session-navigation-logic.ts:196-282`）。

ChatPane layout 还可把 workspace、background task、observer/detail、companion 和 browser/desktop 面板嵌入或停靠到辅助区域。后台任务并非伪装成当前消息流，而是由单独 rail/detail slot 展示，当前 session 的 observer digest 和 active run ID 作为其关联身份（`ui/src/pages/chat/chat-pane-layout-render.ts:87-136`）。

TUI 的运行协调器可以追踪多个 session run 或同一选择范围内的并发运行。当前 active run 结束后，如果仍有最近的可提升 run，就把它提升为状态栏和 watchdog 的 owner；事件处理还按 selected session、run ID 和本地 provisional run 过滤迟到事件（`src/tui/tui-run-lifecycle.ts:224-237`、`src/tui/tui-event-handlers.ts:170-269`）。本次未找到 TUI 中等价于 Control UI split pane 的同时可见多会话布局，主要入口仍是 session picker 切换。

共享 Apple ViewModel 同时保存 `pendingRuns`、`activeSessionRunIDs`、live run state、pending tool calls、subagent activities、swarm sessions/groups 和 question cards；transport event switch 对这些状态分别投影，session observer 只在 owner 和 active run 身份匹配时更新 sidebar（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:94-146`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+TransportEvents.swift:25-93`）。macOS session sidebar 把子树的 queued/running/failed/unread badge 向父节点聚合（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSessionSidebarModel.swift:87-175`）。

Android `ChatTimeline` 把普通消息、streaming assistant、pending tools、subagent activity、question、outbox/recovery、system row 和 thinking row 建模为不同的 timeline item；后台任务和 swarm 另有 sheet/card 入口（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatTimeline.kt:13-117`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:799-805`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:975-979`）。

Agent 与模型的区分依赖 session scope 和 model catalog，而不是只在消息气泡上显示一个简短名称。Control UI、Apple 和 Android 都在发送时捕获 Agent/session identity；对于 `global` 或 bare `main` alias，后续事件和 outbox replay 还要携带或重新确认 Agent owner。

## 8. Chat UI 状态所有权与同步

| 状态类别 | Control UI | TUI | Apple 原生 | Android 原生 |
|---|---|---|---|---|
| 当前 session / Agent | route data、pane layout 和 Gateway session scope | `TuiStateAccess.currentSessionKey/currentAgentId`、last-session 记录 | `OpenClawChatViewModel.sessionKey`、activeAgentId 和 session snapshot | `ChatController` 的 sessionKey、session owner 和 `ChatComposerOwner` |
| 历史与流式消息 | `ChatState`、session message cache、history projection、stream/tool state | `ChatLog`、session projection、stream assembler | ViewModel messages、streaming text、transcript cache 和 run scopes | `ChatController` StateFlow、`ChatTimeline` 派生列表 |
| draft / pending input | pane 内存 draft + Gateway-scoped browser storage；附件 Blob 另存 IndexedDB | editor 内存、输入历史、pending submit；本次未找到 durable draft | `draftsBySession`、input history 和内存 attachments | `ChatComposerStateStore` 按 owner 保存文本、附件和 send state |
| busy / run | browser-local run ID 加 session row active runs、observer digest 和 queue state | session projection、activeChatRunId、run coordinator 和 activity status | pendingRuns、liveRunState、active run IDs 和 run snapshot | pendingRunCount、selected active run、stream text、pending tools 和 session row |
| panel / selection / focus | pane-local transcript state、sidebar layout、overlay context、model picker key | overlay handle、selector state、editor focus | SwiftUI `@State`、`@FocusState`、sheet presentation | Compose `rememberSaveable`、bottom-sheet state 和 owner-keyed Composer state |
| scroll / reading position | `ChatTranscriptController`、scroll generation、near-bottom/follow lock | 终端 ChatLog scrollback | `scrollPosition`、followTarget、live-edge 和 jump-to-latest | timeline anchor、reverse layout、readAnchorIndex 和 reader controller |

### 事件同步

Control UI 的 `AppHost` 订阅 Gateway snapshot 和 event stream；Gateway store 将 connected、starting、connecting、reconnecting、offline、stopped 和 reload-required 等连接阶段投影给页面。被替换的 socket 事件会被丢弃，event gap 会设置错误并触发重新连接（`ui/src/app/app-host.ts:351-367`、`ui/src/app/gateway-store.ts:490-559`）。当前 Chat pane 再按 session key、Agent owner、run ID 和 connection epoch过滤事件，历史请求也只允许当前 request ownership 提交结果（`ui/src/pages/chat/chat-history.ts:104-231`）。

TUI 的 `GatewayChatClient` 把 Gateway event 转为 TUI event，`createEventHandlers` 再按 selected session 和运行身份投影到 ChatLog/session projection；gap 或重连后重新加载 history，避免只依赖可能缺失的 delta（`src/tui/gateway-chat.ts:224-255`、`src/tui/tui-event-handlers.ts:170-203`、`src/tui/tui-session-actions.ts:453-636`）。

Apple transport event 直接分为 health、sessionsChanged、sessionObserver、chat、sessionMessage、agent、progressCard、task、question、routeChanged 和 seqGap。seqGap 会失效 history/run snapshot、清理临时 pending/tool 状态并发起 scoped history 和 health refresh（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+TransportEvents.swift:25-93`）。Android 在 Gateway disconnect 时保留能用于恢复的本地消息和 outbox 行，重新 connected 后执行 `refreshHistoryForRecovery` 和 outbox publish（`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:690-730`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:806-814`）。

### 草稿和跨端连续性

同一个 Gateway session 的 canonical history、run status、questions、tool activity 和 session metadata 可以通过各自 transport 在 Control UI、TUI、Apple 和 Android 之间同步；但各表面的 Composer draft、滚动位置、焦点、临时 attachment 和 pane/sheet 展开状态属于本地实现。Control UI 的 browser storage listener 只负责浏览器上下文间的存储投影失效，不能证明所有临时输入在多窗口间实时合并（`ui/src/lib/chat/outbox-store.ts:91-138`）。

Apple 的 transcript cache/outbox 以 Gateway identity 绑定安装内数据库；Android 使用自身的 Room outbox 和 cache。两者都能在各自进程重启后恢复待发送行，但没有证据表明浏览器 IndexedDB/sessionStorage、Apple 数据库和 Android Room 会互相同步未发送 draft。

## 9. 键盘、焦点、响应式与关键路径可用性

- **Control UI 键盘和焦点**：Composer 的 keydown 路径覆盖发送、停止、slash/skill 菜单、输入历史和 talk/dictation；transcript 容器可聚焦并处理 Markdown 文件/session link 的键盘打开；transcript search 记录打开触发源，关闭后恢复按钮或 Composer 焦点（`ui/src/pages/chat/components/chat-composer.ts:309-328`、`ui/src/pages/chat/components/chat-thread.ts:148-183`、`ui/src/pages/chat/components/chat-thread-interactions.ts:258-301`）。
- **Control UI 响应式**：`ChatPage` 通过 `matchMedia` 维护窄屏状态，窄屏时不接受 split command 和拖放分割；移动导航还会根据独立 media query 合并页面 chrome（`ui/src/pages/chat/chat-page.ts:103-126`、`ui/src/pages/chat/chat-page.ts:201-230`）。代码可确认分支，但实际断点下的视觉布局、触摸滚动和焦点顺序没有运行验证。
- **TUI 键盘主链**：编辑、发送、shell、命令、模型/Agent/session selector、工具展开、thinking 显示、停止和退出都有显式 key binding；overlay 关闭时恢复编辑器焦点，TUI 的关键路径不依赖鼠标（`src/tui/components/custom-editor.ts:46-109`、`src/tui/tui.ts:1654-1721`、`src/tui/tui-overlays.ts:7-26`）。
- **Apple**：共享视图对消息列表使用 live-edge/followTarget 和 jump-to-latest 规则；session 变化时重置 scroll follow、停止 message speech 并等待新历史完成初始定位；非 macOS Composer 使用 FocusState 和交互式键盘收起（`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:351-461`）。
- **Android**：Composer 使用 Compose 的 IME padding、硬件键拦截和语义 content description；运行时会在 talk、voice note、dictation、发送和 active run 之间切换 trailing action，停止入口不会因为 draft 发生变化而消失（`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:221-239`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:805-944`）。

代码能确认入口、disabled 条件、焦点恢复调用和语义名称；真实键盘、IME、VoiceOver/TalkBack、终端鼠标、窄屏断点、横竖屏以及第三方 WebView 行为仍需目标环境验证。

## 10. 设计取舍与已确认边界

- **Gateway 事件作为共同事实源，表面各自投影**：Control UI、TUI、Apple 和 Android 不共享同一个前端状态容器，而是各自把 Gateway snapshot/event/history 归并成适合本表面的状态。这使 TUI、Web、native Composer 可以独立演进，也要求每个表面重复处理 run identity、历史迟到和断线恢复。
- **身份优先于便捷 alias**：`main`、`global`、Agent 前缀和 routing contract 会参与 history、draft、outbox 和 event matching。代码选择在 owner 不明确时等待、分桶或停泊，而不是按当前默认 Agent 猜测，这直接影响多 Agent 和重连后的恢复行为（`ui/src/lib/chat/outbox-store.ts:190-256`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:795-811`）。
- **ACK 不等于持久化**：Control UI、Apple 和 Android 都保留了“请求已被 Gateway 接受，但 canonical history 尚未证明”的中间阶段；不确定发送会显示为 unconfirmed/confirming 或进入人工 retry，而不是自动重放潜在重复消息。
- **桌面工作台与移动原生页面并存**：iOS 的主要 Chat Pro 体验使用共享原生 SwiftUI，但 session Dashboard 仍通过认证 WebView 使用 Control UI；Android 主要聊天体验是独立 Compose 实现。这些入口共享协议和部分数据语义，不共享完整 UI 组件树。
- **分支操作受恢复状态约束**：rewind、fork、branch switch 会清理 reply/run/branch 局部状态，并在确认当前分支后恢复 Composer；存在 unresolved outbox、active run 或未完成 branch refresh 时，相关控件会隐藏或禁用。
- **类目边界已确认**：本笔记不展开 Markdown/tool/message row 的完整装配，不把 Gateway 执行并发和 transcript 数据模型重复写成 UI 功能，也不把外部聊天渠道的客户端页面归入 OpenClaw 自有 Chat UI。

## 11. 未验证事项

- 未运行 Control UI、TUI、iOS、macOS 或 Android 的真实聊天界面；视觉效果、焦点顺序、键盘/IME、响应式断点、触摸手势、终端能力和 accessibility 实际表现未验证。
- 未连接隔离的真实 Gateway 走完新建 session、发送、真实 delta/final、tool、question、approval、stop、retry、rewind、fork、branch switch 和多 session 并发流程。
- 未实测 Gateway 断线、event gap、重连期间的 optimistic user echo、durable outbox drain、unconfirmed barrier、历史迟到和 Gateway restart recovery。
- 未验证同一 Gateway 同时由 Control UI、TUI、Apple 和 Android 打开时，运行状态、未读、session list、子 Agent 和后台任务在各表面之间的实时一致性。
- 未验证 Control UI 多浏览器窗口或多 pane 之间的临时 draft、附件、scroll、focus 和 side panel 状态；storage event 只能证明存储投影有失效通知。
- 未验证 iOS WebView 的认证、TLS、Dashboard session route、Desktop 跳转和 WebView 生命周期；也未验证 Android Room 数据库在进程终止、升级和 Gateway identity 切换后的实际恢复。
- 未验证真实设备上的相册、文件、camera、麦克风、dictation、voice note、talk、语音播放和系统分享权限及失败反馈。
- TUI fake-backend 或 PTY 测试即使存在，也只能说明相应测试替身和 TUI 循环的行为，不能替代真实 Gateway、provider、持久化、真实流式和平台行为证明；本次未运行这些测试。
- Control UI 未在已检查的 Composer 控制入口中找到通用参数级编辑器；参数是否由 Agent、模型或 Gateway 配置入口提供，仍属于相邻配置/请求类目的待确认事项。

## 12. 关键源码索引

- `ui/src/main.ts:1-43`、`ui/src/app-routes.ts:78-164`：Control UI 启动、动态 route bridge 和默认 chat fallback
- `ui/src/app/app-host.ts:351-367`、`ui/src/app/gateway-store.ts:490-559`：Gateway snapshot/event subscription、连接阶段、gap 和 stale socket 处理
- `ui/src/pages/chat/route.ts:13-95`、`ui/src/pages/chat/route-loader.ts:50-69`、`ui/src/pages/chat/route-loader.ts:174-260`：chat/dashboard route、短 session ref、歧义候选和 canonical route
- `ui/src/pages/chat/chat-page.ts:57-126`、`ui/src/pages/chat/chat-page.ts:216-260`、`ui/src/pages/chat/chat-page.ts:384-404`：pane、窄屏、分屏布局和 route handoff
- `ui/src/pages/chat/chat-pane-layout-render.ts:49-167`、`ui/src/pages/chat/chat-pane-render.ts:67-228`：primary transcript、Composer、sidebar rails、model/permission gate 和辅助面板
- `ui/src/components/app-sidebar-session-navigation.ts:127-175`、`ui/src/components/app-sidebar-session-navigation.ts:309-367`、`ui/src/components/app-sidebar-session-navigation.ts:418-467`：侧栏 session 选择、分组、过滤、多选和导航
- `ui/src/components/app-sidebar-session-navigation-logic.ts:148-290`、`ui/src/components/app-sidebar-session-row-render.ts:150-161`、`ui/src/components/app-sidebar-session-row-render.ts:241-284`：session row projection、子会话和 attention badge
- `ui/src/components/command-palette.ts:300-313`、`ui/src/components/command-palette.ts:471-624`、`ui/src/components/command-palette-session-search.ts:1-40`：跨 session 搜索状态和 Gateway search
- `ui/src/pages/chat/components/chat-composer.ts:79-205`、`ui/src/pages/chat/components/chat-composer.ts:261-328`、`ui/src/pages/chat/chat-send-submit.ts:197-239`、`ui/src/pages/chat/chat-send-submit.ts:469-591`：Composer、命令识别、发送 admission 和 queue
- `ui/src/lib/chat/outbox-store.ts:28-35`、`ui/src/lib/chat/outbox-store.ts:91-138`、`ui/src/lib/chat/outbox-store.ts:190-256`、`ui/src/lib/chat/outbox-store.ts:432-455`、`ui/src/lib/chat/outbox-store.ts:560-617`：Gateway-scoped browser outbox/draft projection 和 alias scope
- `ui/src/lib/chat/composer-draft-store.runtime.ts:4-10`、`ui/src/lib/chat/composer-draft-store.runtime.ts:281-320`、`ui/src/pages/chat/durable-composer-persistence.ts:198-311`：IndexedDB durable Composer attachments、过期和 revision restore
- `ui/src/pages/chat/chat-send-delivery.ts:135-239`、`ui/src/pages/chat/chat-outbox-drain.ts:159-245`、`ui/src/pages/chat/chat-outbox-drain.ts:280-344`、`ui/src/pages/chat/chat-outbox-drain.ts:347-566`：发送状态、FIFO drain、history confirmation 和 unconfirmed barrier
- `ui/src/pages/chat/chat-gateway.ts:61-137`、`ui/src/pages/chat/chat-gateway.ts:200-300`、`ui/src/pages/chat/chat-state-events.ts:138-197`、`ui/src/pages/chat/chat-state-events.ts:224-303`：delta/final/abort/error 和 session event projection
- `ui/src/pages/chat/run-lifecycle.ts:96-124`、`ui/src/pages/chat/run-lifecycle.ts:200-284`、`ui/src/pages/chat/components/chat-thread-interactions.ts:212-301`、`ui/src/pages/chat/components/chat-thread-interactions.ts:440-610`：停止、abort replay、transcript search、reply/rewind/fork menu
- `src/tui/tui.ts:918-971`、`src/tui/tui.ts:1416-1652`、`src/tui/tui.ts:1654-1721`：TUI 工作区装配、handler 连接和键盘入口
- `src/tui/tui-submit.ts:33-105`、`src/tui/tui-submit.ts:108-236`、`src/tui/tui-submit-state.ts:3-116`：TUI 提交分类、粘贴 burst、pending admission 和 blocked recovery
- `src/tui/commands.ts:73-174`、`src/tui/tui-command-handlers.ts:130-349`、`src/tui/tui-command-handlers.ts:461-655`：命令 descriptor、session transition、model/Agent/session selector 和命令处理
- `src/tui/tui-session-picker.ts:28-107`、`src/tui/tui-session-actions.ts:86-123`、`src/tui/tui-session-actions.ts:424-636`：TUI recent picker、模糊定位、session reset 和历史重建
- `src/tui/tui-event-handlers.ts:170-379`、`src/tui/tui-run-lifecycle.ts:78-152`、`src/tui/tui-run-lifecycle.ts:224-303`：TUI event projection、流式、终态、watchdog 和并发 run promotion
- `src/tui/tui-plugin-approvals.ts:209-300`、`src/tui/tui-overlays.ts:5-28`：TUI plugin approval overlay 和焦点恢复
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:93-232`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatView.swift:318-461`：共享 Apple Chat view、消息滚动、Composer chrome 和 live-edge
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:18-39`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:94-168`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift:571-811`：Apple ViewModel 的消息、draft、run、session 和 owner identity
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:13-47`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:361-437`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:476-590`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Sending.swift:629-767`：Apple send gate、offline/outbox route、optimistic echo 和失败恢复
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Outbox.swift:7-28`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+Outbox.swift:274-360`：Apple outbox 状态、retry/delete 和 canonical history confirmation
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+TransportEvents.swift:25-93`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+RunSnapshot.swift:5-69`：Apple transport event 分类、seq gap 和 in-flight run adoption
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:29-103`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:330-438`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel+SessionActions.swift:590-679`：新建、搜索、archive/delete、fork、rewind 和 branch switch
- `apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatComposer.swift:116-185`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatComposer.swift:242-278`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSessionSidebar.swift:25-118`、`apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatSessionSidebar.swift:251-320`：Apple 附件 Composer、会话侧栏和菜单
- `apps/ios/Sources/Design/ChatProTab.swift:170-247`、`apps/ios/Sources/Design/ChatProTab.swift:494-526`、`apps/ios/Sources/Chat/SessionDashboardScreen.swift:4-85`：iOS 原生 Chat Pro、Dashboard WebView 和 ViewModel/transport 组装
- `apps/ios/Sources/Chat/IOSGatewayChatTransport.swift:38-173`、`apps/ios/Sources/Chat/IOSGatewayChatTransport.swift:489-678`：iOS route lease、session mutation、branch、history、commands 和 send transport
- `apps/android/app/src/main/java/ai/openclaw/app/ui/UnifiedChatScreen.kt:16-48`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:273-420`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:657-979`：Android Chat 容器、状态收集、header、timeline、Composer 和 sheets
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatTimeline.kt:13-117`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatTimeline.kt:164-207`：Android 时间线 item、outbox/recovery、subagent、question 和 session owner 过滤
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatMessageActions.kt:48-121`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatScreen.kt:724-788`：Android 长按消息操作、reply、rewind 和 fork 回填
- `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:651-730`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatController.kt:916-1041`：Android StateFlow、断线恢复、Gateway scope 和 session load
- `apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:14-36`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:60-79`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:92-120`、`apps/android/app/src/main/java/ai/openclaw/app/chat/ChatCommandOutbox.kt:193-234`：Android durable outbox 限制、状态、owner、附件和 delivery contract
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatComposerStateStore.kt:42-127`、`apps/android/app/src/main/java/ai/openclaw/app/ui/chat/ChatComposerStateStore.kt:267-313`：Android Composer owner、send admission、附件和 alias migration
