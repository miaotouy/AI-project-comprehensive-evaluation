# Pi Chat UI 调查笔记

> 调查对象：`../../pi`（重点 `packages/tui/`、`packages/coding-agent/src/modes/interactive/`、`packages/coding-agent/src/core/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`534bcbffb7e1e7551d9ee3572dfeb278e203e493`（分支：`main`）
>
> 调查方式：从 [`../Chat/Pi-Chat调查笔记.md`](../Chat/Pi-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据
>
> 调查范围：TUI 工作台结构、命令面板（slash 命令与快捷键）、会话选择器与搜索、状态行与流式反馈、运行中投递（steer/followUp）的界面、bash 执行交互与退出工作流；会话持久化与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 是 TUI 命令行编码 Agent，聊天表面由底部编辑器 + 聊天区 + footer 状态行组成，交互以命令与键盘为主：

- 输入区是底部多行 editor，支持 fuzzy autocomplete、`/` 命令补全与大量快捷键（Ctrl+P 模型循环、Ctrl+G 外部编辑器等）。
- 会话导航靠选择器：`/resume`（内嵌搜索框：fuzzy/正则）、`/tree`（树形导航 + label 书签）、`/session`（统计）。
- 状态行与专用状态指示器（Working/Retry/Compaction/BranchSummary/Idle）反馈生成状态，OSC 9;4 终端进度条可配置。
- 运行中可投递 steer（打断）/followUp（排队），`queue_update` 事件驱动待处理列表显示。
- `!` 前缀直跑 bash 并流式显示输出；双击 Esc 或 `/quit` 退出。
- fullscreen 视图：Ctrl+Shift+F transcript 搜索（Enter/Ctrl+G 下一个、Shift+Enter/Ctrl+Shift+G 上一个、Esc 关闭）、半页/单行滚动、鼠标多击选词/选行、Windows 下右键粘贴；退出 fullscreen 时可打印 transcript 或仅恢复屏幕+会话提示（`fullscreenExitOutput` 设置）。

## 工作台边界与用户主链

```text
启动 -> /resume（选择器 + 搜索）或新会话
  -> 底部 editor 输入（autocomplete / 命令补全）
     -> 普通文本 / !bash / /command / /skill:name / /template
  -> 生成中：footer 状态 + status indicator + 流式组件（渲染 -> 消息渲染器）
     -> steer/followUp 投递（执行 -> 对话请求与上下文）
  -> 会话操作：/fork /tree /compact /export /import /share /copy /clone /session
  -> 退出：/quit 或双击 Esc（doubleEscapeAction: fork|tree|none）
```

边界：会话/消息数据语义与列表扫描属于会话与消息管理（`../会话与消息管理/Pi-会话与消息管理调查笔记.md`）；prompt 输入处理、压缩与重试执行属于对话请求与上下文（`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`）；组件渲染与滚动属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 命令面板：slash 命令与快捷键

- **输入区**：底部多行 editor（`packages/tui/src/components/editor.ts`），支持 autocomplete（fuzzy）、`/` 命令补全、快捷键（Ctrl+P 模型循环、Ctrl+G 外部编辑器等，`core/keybindings.ts`）。
- **slash 命令**（`slash-commands.ts`）：`/fork`（从指定 user 消息创建分支）、`/tree`（切换分支）、`/compact`（手动压缩）、`/export`（HTML/JSONL）、`/import`、`/share`（GitHub secret gist）、`/copy`（复制最后一条助手消息）、`/clone`（复制当前会话）、`/session`（统计）、`/resume`（选择器）、`/hotkeys`（快捷键清单）、`/quit`。
- **fullscreen transcript 搜索**：`Ctrl+Shift+F` 打开右上角搜索框（`alt-screen-search.ts` 的 `AltScreenSearchComponent`），命中行以 `searchMatchBg/searchMatchText` 主题色+下划线高亮、当前命中反显，Enter/Shift+Enter 或 Ctrl+G/Ctrl+Shift+G 循环，Esc 关闭（`tui-alt-screen.ts` 的 `openSearch/navigateSearch/applySearchHighlights`）；搜索跳转用 `scrollTo(..., { disableFollow: true })` 抑制滚动跟随。
- **fullscreen 滚动与选择**：半页滚动（`tui.altScreen.halfPageUp/Down`）与单行滚动（`lineUp/Down`）按键默认未绑定、可在 keybindings 配置（`packages/tui/src/keybindings.ts:165-207`）；鼠标双击选词、三击选行，跨行拖拽扩展（`tui-alt-screen.ts` `getWordSelection/getLineSelection/getClickCount`）；Windows fullscreen 下未修饰右键从剪贴板粘贴到聚焦输入（`interactive-mode.ts:2834-2846`）。
- 命令执行语义（`/fork` 如何选分支起点、`/compact` 如何压缩）见对话请求与上下文/会话与消息管理笔记。

## 2. 选择器与会话导航

- `/resume` 会话选择器内嵌搜索框：token 模式（fuzzy/短语混合，`"node cve"` 引号）与 `re:` 正则模式，搜索文本是 `id + name + 全部消息文本 + cwd`（`session-selector-search.ts:26-57`；数据侧见会话与消息管理笔记 §5）。
- `/tree` 树形导航用 `SelectList`/`TreeSelectorComponent`，带 label 书签（`getTree`，`session-manager.ts:1310-1348`）；分支切换走 `chatContainer.clear() + renderInitialMessages()`（`interactive-mode.ts:5053-5054`）。
- 删除入口：`deleteSessionFile`（trash 优先、unlink 兜底）挂到会话选择器删除处理（`session-selector.ts:645`、:832）；快捷键 Ctrl+D（`app.session.delete`）与 Ctrl+Backspace（`deleteSessionNoninvasive`，keybindings.ts:147-154、267-268）。删除的数据语义见会话与消息管理笔记 §3。
- `/session` 显示统计（用户/助手/工具消息数、token、成本）。

## 3. 状态行与流式反馈

- 正在生成时 footer 显示模型/状态（`components/footer.ts`）；retry/compaction 有专用状态指示器（`status-indicator.ts`：Working/Retry/Compaction/BranchSummary/Idle）。footer 的成本标签只对已知订阅制标记显示 `(sub)`（`isUsingSubscription`：kimi-coding 或 OAuth 声明 `isSubscription` 的 Provider，如 GitHub Copilot/OpenAI Codex/xAI，`footer.ts:137-145`、`model-runtime.ts:462`）。
- 可配置 OSC 9;4 终端进度条（`settings-manager.ts:42`）。
- 流式渲染：`message_update` 时整体重建 assistant 组件内容（`interactive-mode.ts:3148-3181`），TUI 渲染由 `requestRender` 节流（`packages/tui/src/tui.ts:765-817`，`MIN_RENDER_INTERVAL_MS` 内合并帧）——组件层细节归消息渲染器笔记。
- 工具增量：`tool_execution_start/update/end` 驱动 `ToolExecutionComponent` 流式输出（`interactive-mode.ts:3227-3268`）。

## 4. 运行中投递与键盘工作流

- **steer/followUp**：运行中投递 steer（当前工具回合结束后、下一次 LLM 调用前注入）与 followUp（agent 结束后处理）两种队列，`queue_update` 事件驱动 UI 显示待处理列表（`agent-session.ts:319-323, 569-575`；执行语义见对话请求与上下文笔记 §8）。
- **中止**：自动重试期间 Esc 中止重试（`interactive-mode.ts:3342-3353`）；`AgentSession.abort()` 的中断语义见对话请求与上下文笔记 §6。
- **退出**：`/quit`、双击 Esc（`doubleEscapeAction: fork|tree|none`，`settings-manager.ts:122`）；退出 fullscreen 时按 `fullscreenExitOutput`（`transcript`/`resume-hint`，`settings-manager.ts:37, 134, 1140-1150`）打印 transcript 或恢复原屏幕只提示 resume。
- **全局按键**：`keybindings.ts`、`packages/tui/src/keybindings.ts`；`/hotkeys` 查看快捷键清单。alt-screen 提供搜索/半页/单行滚动按键组（§1）；`PI_TUI_ESC_TIMEOUT` 只作用于孤立 ESC（默认 10ms，SSH 下自动 100ms，`terminal.ts:112-124`、`stdin-buffer.ts:385-393`）。

## 5. bash 执行交互

- `!` 前缀直跑命令，`!!` 排除上下文；`BashExecutionComponent` 流式显示输出（`components/bash-execution.ts`），`bash_execution_update` 事件增量刷新。
- bash 执行消息的持久化形状与上下文排除语义见会话与消息管理/对话请求与上下文笔记。

## 6. 消息操作与现场恢复

- 复制：`/copy` 复制最后一条助手消息；工具/摘要组件支持展开收起（`setExpanded`，`interactive-mode.ts:3168`）。
- 无就地编辑：历史是追加型，修改以分支表达（`/fork` 从指定 user 消息创建分支，`agent-session-runtime.ts:262-352`，`position: before|at`；数据语义见会话与消息管理笔记 §4）。
- 现场恢复：切换会话前 `teardownCurrent` 保证进行中响应先持久化（执行侧见对话请求与上下文笔记 §10）；`/resume` 恢复 aborted 会话（数据侧见会话与消息管理笔记 §3）。

## 7. 多会话与并发边界

- 单会话单 agent 循环：无多会话并行 UI；`agent_settled` 事件通知 UI 进入空闲（执行侧见对话请求与上下文笔记 §8）。
- 子会话：扩展可用 `createAgentSession` 自行启动子会话（`core/sdk.ts:169`）；本次未找到 UI 层面的多 Agent 编排。

## 8. 设计取舍与已确认边界

- **事件驱动但全量重渲染**：`message_update` 每 delta 触发组件重建，TUI 以帧节流兜底；没有增量 AST 或虚拟列表（渲染侧见消息渲染器笔记）。
- **键盘为主的工作流**：删除、分支、压缩、复制等操作都有 slash 命令或快捷键入口；fullscreen 导航（搜索/半页/单行滚动）与文本选择以键盘+鼠标组合覆盖。
- **终端能力依赖**：OSC 9;4 进度条、图片显示等依赖终端能力探测（渲染侧见消息渲染器笔记）；多路复用器（tmux/zellij/STY）下鼠标跟踪降级为按钮运动模式以减少转发延迟（`tui-alt-screen.ts:262-278`）；全宽行绘制有直接引用快速路径（`layout.ts:316-330`）。
- 通用界面盘点：TUI 无弹窗库/Toast/主题等通用 UI 清单，本类目不虚构。

## 9. 未验证事项

- 未在真实终端运行：焦点顺序、键盘可用性、OSC 行为未实测。
- 流式期间的帧率、闪烁与长会话滚动性能未测量。
- 多会话并行、通知与跨端连续性不适用（TUI 单进程），不做虚构比较。

## 10. 关键源码索引

- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`：`3068-3374`（事件→UI）、`5053-5054`（分支切换重建）
- `packages/coding-agent/src/modes/interactive/slash-commands.ts`（slash 命令注册）
- `packages/coding-agent/src/modes/interactive/session-selector.ts:645`、`:832`（删除入口）
- `packages/coding-agent/src/modes/interactive/session-selector-search.ts:26-57`（搜索）
- `packages/coding-agent/src/core/keybindings.ts:147-154`、`:267-268`（快捷键）
- `packages/coding-agent/src/modes/interactive/components/footer.ts`、`status-indicator.ts`（状态行）
- `packages/coding-agent/src/modes/interactive/components/bash-execution.ts`（bash 流式）
- `packages/coding-agent/src/core/settings-manager.ts:42`（OSC 进度条）、`:122`（doubleEscapeAction）、`:1140-1150`（fullscreenExitOutput）
- `packages/tui/src/alt-screen-search.ts`（transcript 搜索）
- `packages/tui/src/components/editor.ts`（输入区）
- `packages/tui/src/tui.ts:765-817`（帧节流）
