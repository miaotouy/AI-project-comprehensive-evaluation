# Pi Chat UI 调查笔记

> 调查对象：`../../pi`（重点 `packages/tui/`、`packages/coding-agent/src/modes/interactive/`、`packages/coding-agent/src/core/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`534bcbffb7e1e7551d9ee3572dfeb278e203e493`（分支：`main`）
>
> 调查方式：直接阅读源码（interactive-mode 的事件消费与键盘绑定、TUI 组件与选择器、fullscreen 导航、设置入口），逐项核实并修正此前笔记中的符号引用与行号；未运行交互会话，静态代码无法确认的视觉/焦点/键盘行为标记为未验证
>
> 调查范围：TUI 工作台结构、输入区与命令面板、会话选择器与搜索、树导航、fullscreen 视图、状态行与流式反馈、运行中投递（steer/followUp）的界面、bash 执行交互、退出工作流、UI 状态所有权；会话持久化与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 是 TUI 命令行编码 Agent，聊天表面由底部多行编辑器 + 聊天区 + footer 状态行组成，交互以命令与键盘为主：

- 输入区是底部多行 editor，支持 autocomplete（fuzzy/文件/`/` 命令）、大量快捷键（Ctrl+P 模型循环、Ctrl+G 外部编辑器、Alt+Enter 排队等）。
- 会话导航靠选择器：`/resume`（内嵌搜索框：fuzzy/短语/正则）、`/tree`（树形导航 + label 书签）、`/session`（统计）。
- 状态行与专用状态指示器（Working/Retry/Compaction/BranchSummary/Idle）反馈生成状态，OSC 9;4 终端进度条可配置。
- 运行中可投递 steer（打断）/followUp（排队），`queue_update` 事件驱动待处理列表显示。
- `!` 前缀直跑 bash 并流式显示输出；`/quit`、Ctrl+D（空编辑器）退出。
- fullscreen 视图：Ctrl+Shift+F transcript 搜索（Enter/Ctrl+G 下一个、Shift+Enter/Ctrl+Shift+G 上一个、Esc 关闭）、半页/单行滚动（默认未绑定按键）、鼠标多击选词/选行、Windows 下右键粘贴；退出 fullscreen 时按设置打印 transcript 或恢复屏幕只提示 resume。

## 工作台边界与用户主链

```text
启动 -> /resume（选择器 + 搜索）或新会话
  -> 底部 editor 输入（autocomplete / 命令补全）
     -> 普通文本 / !bash / /command / /skill:name / /template
  -> 生成中：footer 状态 + status indicator + 流式组件（渲染 -> 消息渲染器）
     -> steer/followUp 投递（执行 -> 对话请求与上下文）
  -> 会话操作：/fork /tree /compact /export /import /share /copy /clone /session
  -> 退出：/quit、Ctrl+D，或空编辑器双击 Esc（doubleEscapeAction: fork|tree|none）
```

边界：会话/消息数据语义与列表扫描属于会话与消息管理（`../会话与消息管理/Pi-会话与消息管理调查笔记.md`）；prompt 输入处理、压缩与重试执行属于对话请求与上下文（`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`）；组件渲染与滚动属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 输入区、命令面板与发送前配置

- **输入区**：底部多行 editor（`packages/tui/src/components/editor.ts`，含撤销栈、kill-ring、word-wrap、paste marker 处理；autocomplete 在 :664-726 与 :2114-2193，Tab 强制补全 :2152-2170）；autocomplete provider 由 interactive-mode 装配（`setupAutocompleteProvider`，`interactive-mode.ts:726-742`），提供命令、文件、`/skill:`、`/template` 等条目。
- **slash 命令**：内置命令清单在 `BUILTIN_SLASH_COMMANDS`（`core/slash-commands.ts:19-42`）：`/settings` `/model` `/scoped-models` `/export` `/import` `/share` `/copy` `/name` `/session` `/changelog` `/hotkeys` `/fork` `/clone` `/tree` `/trust` `/login` `/logout` `/new` `/compact` `/resume` `/reload` `/quit`；扩展命令与模板/skill 并入补全（`_bindExtensionCore` 的 `getCommands`，`agent-session.ts:2340-2363`）。提交入口在 `setupEditorSubmitHandler`（`interactive-mode.ts:2873-3060`）。
- **快捷键**（`core/keybindings.ts:64-207`）：Ctrl+P/Shift+Ctrl+P 模型循环（:77-84）、Ctrl+L 模型选择器（:85）、Shift+Tab thinking 循环（:73-76）、Ctrl+T thinking 块开关（:87-90）、Ctrl+G 外部编辑器（:95-98）、Ctrl+X 复制消息（:99-102）、Alt+Enter followUp 队列（:103-106）、Alt+Up 取回排队消息（:107-110）、Ctrl+V/Alt+V 粘贴图片（:111-114）、Ctrl+D 退出（:68）、Esc 中止（:66）。`/hotkeys` 在聊天区打印完整清单（`interactive-mode.ts:6097-6209`）。
- **发送前配置**：`/settings` 打开设置选择器（`SettingsSelectorComponent`，`interactive-mode.ts:4380-4419` 传入当前值，:4420+ 回调写回），覆盖自动压缩、图片、模型 transport、thinking、主题、mermaid、doubleEscapeAction、fullscreen 输出等；`/model`（搜索参数）、`/scoped-models`、`/login`/`/logout` 管理模型与认证；设置分 global/project 两级（`settings-manager.ts:180-204`、`:316-347`，项目级仅在项目受信时读写）。
- **图片附件**：Ctrl+V 从剪贴板读图（图片写入临时文件、以路径插入编辑器）或读文本（`handleClipboardPaste`，`interactive-mode.ts:2848-2871`）；图片是否发送由 `settings.images` 控制（数据侧见会话与消息管理笔记 §8）。

## 2. 会话选择器与搜索

- `/resume` 打开 `SessionSelectorComponent`（`components/session-selector.ts:685+`；入口 `showSessionSelector`，`interactive-mode.ts:5096-5129`）：当前目录会话用 `SessionManager.list`、全部会话用 `listAll` 异步加载并显示进度（`session-selector.ts:922-982`）。Tab 切换当前目录/全部范围（:551-556、:1003-1026），Ctrl+S 循环排序（threaded/recent/relevance，:984-990），Ctrl+N 命名过滤（:992-997），Ctrl+P 切换路径显示（:569-573）。选中会话 Enter 恢复（`handleResumeSession`），Esc 取消。
- **搜索框**：内嵌在列表顶部（`session-selector.ts:417-419`），token 模式（fuzzy + 短语引号）与 `re:` 正则模式，搜索文本是 `id + name + 全部消息文本 + cwd`（`session-selector-search.ts:26-114`；数据侧见会话与消息管理笔记 §5）。
- **删除/重命名**：Ctrl+D 或 Ctrl+Backspace 进入删除确认（`session-selector.ts:576-601`、`:394-405`），确认后 `deleteSessionFile`（trash 优先、unlink 兜底，:645-680）；当前活动会话不可删（:399-402）。Ctrl+R 进入重命名模式（:866-920），写 `session_info` 条目（`interactive-mode.ts:5118-5123`）。数据语义见会话与消息管理笔记 §3。

## 3. 树导航与消息操作

- `/tree` 打开 `TreeSelectorComponent`（`components/tree-selector.ts:1328`；入口 `showTreeSelector`，`interactive-mode.ts:4955-5093`），数据来自 `sessionManager.getTree()`（`session-manager.ts:1310-1348`）；Shift+L 编辑 label、Shift+T 切换 label 时间戳，过滤器（`treeFilterMode` 设置，`settings-manager.ts:1207-1217`）与 filter 快捷键组（`core/keybindings.ts:179-206`）。选中条目后可选"不摘要/摘要/自定义提示摘要"（`interactive-mode.ts:4988-4992`），确认后 `navigateTree` 移动 leaf（执行侧见对话请求与上下文笔记；数据侧见会话与消息管理笔记 §4），UI 以 `chatContainer.clear() + renderInitialMessages()` 重建（`interactive-mode.ts:5053-5054`），选中 user 消息时其文本回填编辑器（:5055-5057）。
- `/fork` 打开 user 消息选择器（`showUserMessageSelector`，`interactive-mode.ts:2816`），从指定 user 消息创建分支（`agent-session-runtime.ts:262-352`，`position: before|at`）；`/clone` 复制当前会话（`interactive-mode.ts:4934`）。
- `/copy` 复制最后一条助手消息（`getLastAssistantText`，`agent-session.ts:3291-3313`）；工具/摘要组件支持展开收起（`setExpanded`，`interactive-mode.ts:3168`）；`/session` 显示统计（用户/助手/工具消息数、token、成本，数据侧见会话与消息管理笔记 §5）。
- 无就地编辑：历史是追加型，修改以分支表达（数据语义见会话与消息管理笔记 §4）。

## 4. fullscreen 视图

- fullscreen（alt-screen）模式由 `TuiAltScreen` 渲染（`packages/tui/src/tui-alt-screen.ts`），regular/fullscreen 切换保留组件与焦点（`interactive-mode.ts:791-805`）。
- **transcript 搜索**：Ctrl+Shift+F 打开右上角搜索框（`tui.altScreen.search`，`packages/tui/src/keybindings.ts:192-195`；`openSearch`，`tui-alt-screen.ts:416`），逐字搜索（`AltScreenSearchComponent`，`alt-screen-search.ts:105-157`，命中段映射 `findAltScreenSearchMatches` :71-97）；Enter/Ctrl+G 下一个、Shift+Enter/Ctrl+Shift+G 上一个（:196-203，`navigateSearch`，`tui-alt-screen.ts:458`），命中高亮与当前命中反显（`applySearchHighlights`，:1089），跳转用 `scrollTo(..., { disableFollow: true })` 抑制滚动跟随（:519），Esc 关闭（:204-207）。
- **滚动**：PageUp/Down 整页（:585-596）、Home/End 顶/底（:208-209、:621-624）、Ctrl+Shift+上下跳语义 prompt（:184-191、:613-620）；半页与单行滚动（`halfPageUp/Down`、`lineUp/Down`）默认未绑定按键、可在 keybindings 配置（`packages/tui/src/keybindings.ts:168-183`，处理逻辑 `tui-alt-screen.ts:597-612`）。
- **鼠标**：多击选词/选行（`getClickCount`/`getLineSelection`/word 级选择，`tui-alt-screen.ts:859-991`，`selectionGranularity` word/line）；Windows fullscreen 下未修饰右键从剪贴板粘贴到聚焦输入（`interactive-mode.ts:2834-2846`）；tmux/zellij/STY 下鼠标跟踪降级为按钮运动模式（`tui-alt-screen.ts:271-284`）。
- **退出行为**：退出 fullscreen 时按 `fullscreenExitOutput`（`transcript`/`resume-hint`，`settings-manager.ts:1140-1148`）打印 transcript 或恢复屏幕并只提示 resume（`stopInteractiveTui`，`interactive-mode.ts:782-789`）；滚动条样式可配置（`fullscreenScrollbar`，`settings-manager.ts:1150-1153`）。

## 5. 状态行与流式反馈

- footer 显示模型/状态/cwd（含 git 分支与会话名）/上下文百分比/token/成本（`components/footer.ts`；成本标签只对已知订阅制标记显示 `(sub)`：kimi-coding 或 OAuth 声明 `isSubscription` 的 Provider，`footer.ts:138-145`、`model-runtime.ts:462`）。
- 生成中显示专用状态指示器（`components/status-indicator.ts`：Working/Retry/Compaction/BranchSummary，空闲时 `IdleStatus` 占位 :105-113）；事件映射见 `handleEvent`（`interactive-mode.ts:3068-3396`：agent_start/compaction_start/auto_retry_start/summarization_retry_* 各自切换指示器与 Esc 处理）。
- 可配置 OSC 9;4 终端进度条（`showTerminalProgress`，`settings-manager.ts:1117-1119`；agent_start/agent_end 置位/复位，`interactive-mode.ts:3078-3080`、`:3271-3273`）。
- 流式渲染：`message_update` 时整体重建 assistant 组件内容（`interactive-mode.ts:3148-3181`），TUI 渲染由 `requestRender` 节流（`packages/tui/src/tui.ts:765-817`，16ms 合并帧）——组件层细节归消息渲染器笔记。
- 工具增量：`tool_execution_start/update/end` 驱动 `ToolExecutionComponent` 流式输出（`interactive-mode.ts:3227-3268`）；assistant 消息里的 `toolCall` 块在 `message_update` 时同步建组件并逐步更新参数（:3153-3177）。

## 6. 运行中投递与键盘工作流

- **steer/followUp**：运行中提交时走 `prompt(..., { streamingBehavior: "steer" })`（`interactive-mode.ts:3040-3047`），Alt+Enter 直接投递 followUp（`core/keybindings.ts:103-106`）；`queue_update` 事件驱动待处理列表显示（`updatePendingMessagesDisplay`，`interactive-mode.ts:4193-4210`，`Steering: …`/`Follow-up: …` 行 + Alt+Up 取回提示）；Alt+Up 把排队消息取回编辑器（`restoreQueuedMessagesToEditor`，:4212-4231）。执行语义见对话请求与上下文笔记 §8。
- **Esc 语义**（`interactive-mode.ts:2769-2795`）：流式中 → 取回排队消息并 abort；bash 运行中 → 取消 bash；bash 模式 → 清空；编辑器为空时双击 Esc（500ms 窗口）→ 按 `doubleEscapeAction`（fork/tree/none，`settings-manager.ts:1197-1199`）打开对应选择器。
- **中止**：自动重试期间 Esc 中止重试（`interactive-mode.ts:3342-3353`）；压缩期间 Esc 中止压缩（:3294-3299）；分支摘要期间 Esc 中止摘要（:5026-5028）。`AgentSession.abort()` 的中断语义见对话请求与上下文笔记 §6。
- **退出**：`/quit`、空编辑器 Ctrl+D（`interactive-mode.ts:3766-3769`）、Ctrl+C 清空编辑器（`app.clear`，`core/keybindings.ts:67`）；`shutdown` 停止 TUI 后打印 resume 命令（`interactive-mode.ts:3778-3817`）。孤立 ESC 的序列重组窗口可配置（`PI_TUI_ESC_TIMEOUT`，默认 10ms、SSH 下 100ms，`packages/tui/src/terminal.ts:104-121`、`stdin-buffer.ts:387-395`）。

## 7. bash 执行交互

- `!` 前缀直跑命令、`!!` 排除上下文（`interactive-mode.ts:3008-3024`）；同时只允许一个 bash 运行（:3013-3017），运行中提示 Esc 取消；`BashExecutionComponent` 流式显示输出（`components/bash-execution.ts:21`、`:80`、`:98`），增量经 `bash_execution_update` 事件（消费点 `interactive-mode.ts:3223-3225`）。
- bash 执行消息的持久化形状与上下文排除语义见会话与消息管理/对话请求与上下文笔记。

## 8. 多会话、后台与并发边界

- 单会话单 agent 循环：无多会话并行 UI；`agent_settled` 事件通知 UI 进入空闲（`interactive-mode.ts:3285-3287`；执行侧见对话请求与上下文笔记 §8）。
- 子会话：扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- 跨窗口/跨端同步、系统通知不适用（TUI 单进程），不做虚构比较。

## 9. UI 状态所有权与同步

- **draft**：编辑器文本在 editor 组件内部（`packages/tui/src/components/editor.ts`）；运行中投递的内容记录在 `AgentSession._steeringMessages/_followUpMessages`（`agent-session.ts:319-324`），abort/取回时回写编辑器（§6）。编辑器历史在 editor 内（`addToHistory`）。
- **selection**：选择器的选中项、搜索框文本、过滤器在各自组件内（如 `session-selector.ts:288-310` 的 `filteredSessions/selectedIndex/searchInput`），组件实例随 `showSelector` 生命周期创建销毁。
- **busy 状态**：`session.isStreaming/isCompacting` 是事实源（`agent-session.ts:878-885`、`:946-952`）；UI 投影为 status indicator 容器与 footer（§5）。
- **现场恢复**：切换会话前 `teardownCurrent` 保证进行中响应先持久化（执行侧见对话请求与上下文笔记 §10）；切换后 `chatContainer.clear() + renderInitialMessages()` 重建消息区（`interactive-mode.ts:1861-1862`）；`/resume` 恢复 aborted 会话（数据侧见会话与消息管理笔记 §3）；regular/fullscreen 切换保留组件与焦点（§4）。
- **pending input**：非交互测试路径有 `onInputCallback/pendingUserInputs` 缓冲（`interactive-mode.ts:3053-3057`）；压缩期间提交进 `compactionQueuedMessages` 并在结束时重放（:4233-4239、:4251-4322）。

## 10. 键盘、焦点与关键路径可用性

- **键盘主链**：选择会话（选择器 `tui.select.*` 键组，`packages/tui/src/keybindings.ts:147-158`）→ 输入（editor 编辑键组）→ 发送（Enter/Shift+Enter 换行，`tui.input.submit`/`tui.input.newLine` :143-144）→ 中止（Esc）→ 消息操作（Ctrl+X 复制、Ctrl+D 删除、`/fork`/`/copy`）；`/hotkeys` 提供运行时清单（§1）。
- **焦点传播**：选择器焦点沿 Container → SessionList → 搜索输入传递（`session-selector.ts:722-733` 的 focused setter 链），输入法光标位置随焦点走；fullscreen 搜索框独立聚焦（`alt-screen-search.ts:116-123`）。
- 静态代码可确认键绑定与焦点传播路径；焦点顺序、键盘实际可用性、IME 行为、OSC/终端能力差异需运行验证（§12）。

## 11. 设计取舍与已确认边界

- **事件驱动但全量重渲染**：`message_update` 每 delta 触发组件重建，TUI 以 16ms 帧节流兜底；没有增量 AST 或虚拟列表（渲染侧见消息渲染器笔记）。
- **键盘为主的工作流**：删除、分支、压缩、复制等操作都有 slash 命令或快捷键入口；fullscreen 导航（搜索/整页/半页/单行滚动）与文本选择以键盘+鼠标组合覆盖。
- **终端能力依赖**：OSC 9;4 进度条、图片显示等依赖终端能力探测（渲染侧见消息渲染器笔记）；多路复用器（tmux/zellij/STY）下鼠标跟踪降级为按钮运动模式以减少转发延迟（`tui-alt-screen.ts:271-284`）；全宽行绘制有直接引用快速路径（`packages/tui/src/layout.ts:319-325`）。

## 12. 未验证事项

- 未在真实终端运行：焦点顺序、键盘可用性、IME、OSC 9;4、图片显示等行为未实测。
- 流式期间的帧率、闪烁与长会话滚动性能未测量。
- 多会话并行、通知与跨端连续性不适用（TUI 单进程），不做虚构比较。

## 13. 关键源码索引

- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`：`2873-3060`（提交入口）、`3068-3396`（事件→UI）、`4955-5093`（树导航）、`5096-5129`（会话选择器）、`4193-4231`（队列显示/取回）、`2769-2795`（Esc 语义）
- `packages/coding-agent/src/modes/interactive/components/session-selector.ts`（会话选择器）、`session-selector-search.ts:26-114`（搜索）
- `packages/coding-agent/src/core/slash-commands.ts:19-42`（命令清单）、`core/keybindings.ts:64-207`（快捷键）
- `packages/coding-agent/src/modes/interactive/components/footer.ts`、`status-indicator.ts`（状态行）
- `packages/coding-agent/src/modes/interactive/components/bash-execution.ts`（bash 流式）
- `packages/coding-agent/src/core/settings-manager.ts:1117-1119`（OSC 进度条）、`:1197-1199`（doubleEscapeAction）、`:1140-1148`（fullscreenExitOutput）
- `packages/tui/src/alt-screen-search.ts`（transcript 搜索）、`tui-alt-screen.ts:416-519`、`:859-991`（搜索/滚动/鼠标选择）
- `packages/tui/src/components/editor.ts`（输入区）、`tui.ts:765-817`（帧节流）
