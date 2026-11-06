# Codex Chat UI调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：只读源码静态梳理 Rust TUI 的启动循环、事件路由、Composer、会话恢复、审批与状态所有权；未运行 TUI，未在真实终端观察焦点、剪贴板和渲染效果
>
> 调查范围：`codex-rs/tui` 的终端聊天表面，以及它依赖的 `codex-rs/app-server` 协议边界；`codex-rs/exec` 的非交互输出和 TypeScript SDK 只作为相邻表面核实。按 `codex-rs`、`sdk`、`codex-cli` 和仓库根目录检查后，本次未找到浏览器、Electron 或移动端聊天前端，相关 Web/桌面工作台维度按 N/A 处理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 在本仓库中自有的聊天表面是 Rust 终端 TUI，而不是 Web 或桌面工作台：交互入口、消息显示、输入框、审批弹窗和会话选择器都在 `codex-rs/tui`。TUI 同时是 app-server 的客户端，用户看到的会话、回合、工具审批和流式输出都通过 app-server 协议往返；TUI 自己主要负责输入状态机、视图栈和终端渲染。

关键事实：

- **工作台是单终端窗口的垂直布局**：上方是 transcript（终端回滚区或自有全屏视图），下方是 `BottomPane` 的横幅、状态行、待审批、待发送预览和 Composer；没有可分离面板或多窗口。
- **TUI 不是聊天服务本体**：`AppServerTarget` 支持内嵌、本地守护进程和远程三种后端（`tui/src/lib.rs:330-339`），聊天动作最终落到 `turn/start`、`turn/steer` 或 `turn/interrupt`。
- **提交与排队分离**：任务运行时按 Enter 会尝试把新输入作为 steer 送入当前回合，按 Tab 则进入显式队列；无法 steer 的输入进入“被拒绝的 steer”队列等待后续重试。
- **停止入口是 Esc**：`AppCommand::Interrupt` 转成 app-server 的回合中断请求，并在回合 ID 竞态时重试一次。
- **审批是模态视图**：执行命令、权限提升、补丁应用和 MCP 询问四类请求都进入 `ApprovalOverlay`，可批准一次、按会话批准或拒绝。
- **会话现场按 thread 保存**：切换会话前会捕获 `ThreadInputState`，内含 Composer、输入队列、待发送 steer 和线程级状态覆盖。
- **没有浏览器/桌面聊天页**：`/app` 只把当前 thread 通过 `codex://threads/<id>` 交给外部 Desktop 应用，不在本仓库内渲染。

## 系统边界与总体调用链

本仓库的聊天链路由三层组成。最上层是 `codex-rs/tui`，负责终端输入、视图栈和渲染；中间是 `codex-rs/app-server`，维护 thread、turn、item 与审批请求；最下层是核心执行与会话持久化。TypeScript SDK 走的是 `codex exec --experimental-json` 的非交互通道，不是聊天工作台。

一条完整主链如下：

```text
启动 codex
  → App::run 建立 app-server 会话与 TUI（tui/src/app/startup.rs:241）
  → 选择新会话 / 恢复 / fork
  → ChatComposer 收集文本、附件、提及和斜杠命令
  → submit_user_message_with_prepared_images 生成 AppCommand::UserTurn
  → app/thread_routing.rs 交给 app-server
  → 活跃回合存在时 turn/steer，否则 turn/start
  → app-server 推送 turn/item/delta 通知
  → ThreadEventChannel 缓冲并按活跃 thread 投递
  → ChatWidget 更新流式状态与 HistoryCell
  → App 插入终端回滚区或自有 transcript
  → 完成时把流式片段合并为可重排的 Markdown cell
```

启动后的主循环在 `tui/src/app/startup.rs:1461-1711` 用 `select!` 同时等待应用事件、活跃 thread 事件、终端事件、app-server 事件、重连、尺寸变化和提交动画 tick。这个循环决定了 TUI 的“实时感”：终端输入和网络通知共享同一个消费循环，任何一侧阻塞都会影响另一侧的响应。

## 1. 工作台结构、全屏路由与窗口边界

TUI 的主画面默认没有侧栏或多列布局。`render_chat_widget_frame` 在自有全屏模式和内联模式下选择不同的 transcript 渲染路径，然后把底部区域交给 `ChatWidget`（`tui/src/app.rs:1318-1370`）。内联模式把已提交内容写入终端回滚区，自有模式在备用屏幕上维护可重绘的消息区。

工作区特性开启且终端宽度足够时，界面会并排显示两个会话：被显示的线程独占活动 Composer，另一侧只作为被动 transcript；左右方向键与专用快捷键在两侧之间切换焦点，也可以只隐藏侧栏（`tui/src/app/side_pane.rs:1-30`、`tui/src/app/side_focus.rs:1-30`）。该并行布局由 `tui_workspace` 特性控制，当前处于开发阶段且默认关闭（`codex-rs/features/src/lib.rs:1142-1146`）。

后端选择也在这一层：新建会话可以按项目与本地身份记住首选主机，选择器会复用已连接的多个后端并在它们之间切换，而不是为每次切换重连（`tui/src/app/backend_selection.rs:80`、`:265-290`；`codex-rs/config/src/types.rs:874-880`）。

`BottomPane` 负责底部区域的组合顺序（`tui/src/bottom_pane/mod.rs:2435-2585`）：

- 警告视图激活时整体替换底部内容；
- 有视图栈时显示栈顶视图，居中呈现的视图用 `ViewStack` 包裹；
- 否则依次组合内联横幅、状态行、Hook 状态、统一执行页脚、待审批列表、待输入预览、问题编辑器、Composer 和快捷键提示。

全屏或模态入口包括：

| 入口 | 触发 | 交互归属 |
|---|---|---|
| 会话选择器 | `codex resume`、`codex fork`、`/resume` | 独立运行的 TUI 选择器 |
| Transcript 视图 | `Ctrl+T` | 备用屏幕 overlay |
| 全文查找 | `F3` | Transcript 视图内搜索 |
| Activity 视图 | `F4` | 自有 transcript 的活动分组 |
| 警告列表 | `F2` | 覆盖底部区域 |
| 审批弹窗 | 工具请求到达 | `BottomPane` 内的模态视图 |
| Agent 总览 | `/agents`，或本地守护进程/远程后端下空 Composer 的左方向键 | 全屏命令中心 |

窗口边界方面，本仓库没有可拆分的聊天窗口、悬浮窗或桌面多窗口实现。`/app` 的处理是把 `codex://threads/<thread_id>` 交给操作系统打开 Desktop 应用（`tui/src/app/history_ui.rs:304-316`）；Desktop 应用本体不在本仓库。因此“跨窗口同步草稿和 busy 状态”这类维度为 N/A，只有同一终端进程内的 thread 切换与重连恢复。

## 2. 会话导航、恢复与搜索

会话导航以命令行入口和选择器为主，没有常驻侧栏。顶层的 resume 和 fork 子命令设置内部选择器标志（`tui/src/cli.rs:24-64`），选择器通过 app-server 的 `thread/list` 拉取会话，支持按当前工作目录过滤、排序、归档与取消归档，并区分恢复和 fork 两种动作（`tui/src/resume_picker.rs:1-82`）。会话内的 `/resume` 也打开同一选择器。

运行中的切换由活跃 thread 通道控制。`ThreadEventChannel` 为每个 thread 维护发送端、接收端和缓冲存储（`tui/src/app/thread_events.rs:615-632`）；主循环只消费当前活跃 thread 的接收端，其他 thread 的通知留在缓冲区。切回某个 thread 时，`ThreadInputState` 恢复它的 Composer 和输入队列（`tui/src/chatwidget/input_restore.rs:633-751`），已有测试覆盖“选择器往返后每个 thread 的输入仍保留”的行为。

历史加载采用分页而不是一次性读取全部会话：初次恢复取最近 5 个 turn，单页 item 上限为 100，另有扫描上限用于在渲染预算内补齐缺失项（`tui/src/app_server_session/history.rs:31-33`）。在 transcript 顶部继续向上滚动会触发更早一页的请求，加载期间保持当前位置；这属于终端视图的“反向分页”，没有 Web 端的虚拟列表和高度测量。

搜索入口分两层：`F3` 在完整 transcript 中查找，`Ctrl+T` 打开 transcript overlay 后可在其中跳转；Composer 内部的 `Ctrl+R`/`Ctrl+S` 搜索的是输入历史，不是会话消息。未读状态已有实现：选择器与任务中心会标记未读会话并在查看时确认已读（`tui/src/app/agent_center/rows.rs:204-210`）；跨会话搜索、置顶、拖放排序和消息 minimap 在本次源码范围内未找到对应实现。

## 3. Composer、草稿、附件与快捷输入

Composer 是一个完整的状态机而不是简单文本框（`tui/src/bottom_pane/chat_composer.rs:1-162`）。它维护 `TextArea`、附件、弹窗路由、原子化的斜杠命令、粘贴突发检测、Vim 模式、历史召回和右键粘贴。输入类型包括：

- 普通文本与多行编辑；
- `@` 提及：默认列出插件、文件系统条目和技能；
- `$` 提及：列出单个技能和应用；
- `/` 斜杠命令：补全后作为原子片段提交；
- `!` 前缀：允许时转成本地 shell 命令而不是模型请求；
- 本地图片和远程图片 URL；
- 语音输入（`F8` 切换，`F9` 静音）。

草稿作用域分三层。当前 thread 的 Composer 内容、附件、队列和问题编辑器状态由 `ThreadInputState` 捕获，切换会话或重连时恢复；跨会话的输入历史是持久化的纯文本记录，能恢复任务链接和提及绑定，但不能恢复附件；仅在当前进程内的历史则保留完整文本和本地/远程图片。启动阶段还有单独的草稿泵，在会话配置完成前保持输入可用，失败时把初始消息退回 Composer。

发送键位是 `Enter` 提交、`Tab` 排队（`tui/src/keymap.rs:1799-1808`）。Composer 的历史导航使用上下方向键，`Ctrl+R` 在页脚搜索并预览匹配项，`Esc` 先关闭可见的快捷键帮助，再退出编辑态或打断回合。外部编辑器由 `Ctrl+G` 打开。上述是代码绑定的入口；实际终端对组合键的保留情况需要在目标终端观察。

## 4. Agent、模型、工具与发送前配置

发送前配置没有独立的设置抽屉，而是分散在状态行、Composer 快捷键和斜杠命令中。常用入口包括：

| 能力 | 入口 | 作用域 |
|---|---|---|
| 模型与推理强度 | `/model`、`Alt+,` / `Alt+.` | 当前 thread 的模型与 effort |
| 权限模式 | `/permissions` | 当前 thread 的审批与权限配置 |
| Plan 模式 | `/plan` | 当前协作模式 |
| 沙箱提升 | `/setup-default-sandbox` | 运行环境配置 |
| 配置编辑 | `/config` | 本地设置 |
| 实验特性 | `/experimental` | 本地设置 |
| 键位与 Vim | `/keymap`、`/vim` | 本地设置 |
| 主题与状态行 | `/theme`、`/statusline`、`/title` | 本地设置 |
| 技能、应用、插件、MCP | `/skills`、`/apps`、`/plugins`、`/mcp` | 会话可用的能力目录 |
| IDE 上下文 | `/ide` | 当前编辑器选区与打开文件 |

`/model` 等命令可以带内联参数，也可以打开选择器；斜杠命令的完整枚举和可用性判断在 `tui/src/slash_command.rs:12-89`。命令是否能在任务运行中执行、是否要求可写 thread、是否在 side conversation 中可用，都有独立判定（同文件 `:202-313`）。这使发送前配置的“当前值”与“可修改时机”分离：状态行展示当前 thread 的模型和推理强度，修改则受任务状态约束。

模型、权限和 Plan 等命令修改的是 thread 级或运行时覆盖；配置、主题和键位修改本地设置。`ThreadInputState` 同时保存协作模式、状态面覆盖和任务运行标志，说明线程切换时配置不是简单地从全局重新读取，而是按 thread 恢复。

## 5. 发送、排队、流式反馈与停止

提交入口是 `submit_user_message_with_prepared_images`（`tui/src/chatwidget/input_submission.rs:151-599`）。它先处理错位策略、限流恢复、待提交图片和会话未配置等前置条件，再构造用户回合命令。App 侧的统一提交路径随后在当前有活跃回合时优先 steer，否则启动新回合（`tui/src/app/thread_routing.rs:729`）。

排队有两套语义：

- **隐式 steer**：任务运行时直接提交，输入被标记为 `PendingSteer`，尝试并入当前回合；如果 app-server 返回“当前回合不可 steer”，该输入进入 `rejected_steers_queue`，等待在可发送时重试。
- **显式队列**：`Tab` 把输入放入 `queued_user_messages`，当前回合结束后由 `maybe_send_next_queued_input` 依次发送。

底部预览会同时展示排队消息、待发送 steer 和被拒绝的 steer（`tui/src/bottom_pane/mod.rs:2490-2530`），因此用户能区分“已排队”和“正在尝试插入当前回合”两种状态。

停止入口是 `Esc`，绑定在 `chat.interrupt_turn`（`tui/src/keymap.rs:1784`）。处理时读取当前活跃回合 ID，向 app-server 发 `TurnInterrupt`；如果第一次因回合 ID 不匹配失败，会用错误中返回的实际回合 ID 重试一次（`tui/src/app/thread_routing.rs:739-808`）。中断失败会以警告通知回到聊天流，而不是静默丢弃。

生成反馈由状态行、终端标题和流式消息共同承担。回合开始设置“工作中/思考中”状态，增量到达时更新流式 cell，完成后隐藏状态指示器并把内容交给 transcript。错误通知区分“将重试”和“不再重试”：前者更新流式错误状态，后者生成错误消息并可能触发错位策略处理（`tui/src/chatwidget/protocol.rs:214-249`）。

审批会暂停当前工具调用并把控制权交给用户。执行审批和补丁审批在打开弹窗前会先刷新答案流（`tui/src/chatwidget/tool_requests.rs:284-340`），然后 `BottomPane` 推入 `ApprovalOverlay`。四类请求分别是执行命令、权限提升、应用补丁和 MCP elicitation（`tui/src/bottom_pane/approval_overlay.rs:75-78`）；选项由可用决策列表生成，包含批准一次、按会话批准、带策略修订的批准、拒绝和取消（同文件 `:860-937`）。权限请求另外区分“本回合授权”和“本会话授权”。

后台补丁审批有带线程标签的就地预览。请求本身只给出项标识，界面先从对应线程的事件缓存按 turn/item 找回文件变更，再把相同内容交给预览与审批页。只有带线程标签且变更非空时才追加预览；恢复不到变更时仍保留审批请求，但不画空预览（[内容恢复](../../codex/codex-rs/tui/src/app/file_change_approvals.rs#L10-L45)、[预览条件](../../codex/codex-rs/tui/src/app/thread_routing.rs#L334-L351)）。

该自动转呈只扫描具有 side-parent 待处理状态的非活跃线程，当前正显示侧对话时会暂缓；不能理解为任意后台线程的补丁都会立刻插入当前 transcript。转呈后先补预览再入审批队列，用户决定仍按原 thread/item 找到待回复 RPC，回给发起线程，无需把审批归属改成当前显示线程（[扫描与转呈](../../codex/codex-rs/tui/src/app/thread_routing.rs#L437-L521)、[按线程回传](../../codex/codex-rs/tui/src/app/app_server_requests.rs#L332-L346)）。

## 6. 消息操作、分支与版本导航

聊天内的消息操作以复制、导出和原始模式为主：

- `/copy` 复制最后一条回复或打开选择器挑选片段；
- `Ctrl+O` 复制当前选择或 transcript 内容；
- `Alt+R` 切换原始回滚模式，便于终端原生选择；
- `/export` 把会话导出为 Markdown；
- `/diff` 查看包含未跟踪文件的 git diff；
- `/raw` 切换适合复制的原始滚动输出。

分支发生在 thread 层而不是单条消息层：fork 创建新 thread，side 或 btw 创建临时 fork 作为侧对话，worktree 在新工作树中开始或继续会话；返回 side conversation 由 `Ctrl+/` 触发。消息级编辑、重新生成、删除、在消息处创建分支、兄弟版本切换和消息树/minimap 在本次源码范围内未找到对应 UI；已有的是 `Shift+Left`/`Alt+Up` 编辑排队消息和 `Shift+Right`/`Alt+Down` 返回提示栈。

`/copy` 的候选来自已完成回复和当前状态面，复制源尽量保留原始 Markdown 而不是终端换行后的文本；这使复制内容与显示宽度解耦。`/export` 的范围和文件名通过本地选择器确认，导出逻辑属于对话导出类目，本笔记只记录入口。

## 7. 多会话、多 Agent 与后台任务

同一时刻只有一个“活跃 thread”占用主循环的消息接收端，但其他 thread 仍可在 app-server 侧运行并缓冲事件。用户通过以下入口观察和返回：

- `/agents` 打开 Agent 命令中心，查看 thread 列表和运行状态；
- `/subagents` 在当前会话的子 Agent 之间切换；
- `/ps` 列出后台终端，`/stop` 停止全部后台终端；
- `/side` 和 `/btw` 在临时 fork 中开侧对话，`Ctrl+/` 返回；
- `F4` 在自有 transcript 中聚焦活动分组，展开工具与推理细节。

多会话的返回路径依赖 `ThreadInputState` 和 thread 事件缓冲：切换前保存输入与队列，切换后恢复 Composer 和状态；运行中的回合不会因为界面切换而停止，通知在缓冲区内等待。并排显示已有实现，但受 `tui_workspace` 特性与终端宽度约束：左侧（或右侧）为被动 transcript、只有被显示的线程拥有活动 Composer，方向键与专用快捷键切换焦点并可隐藏该侧（`tui/src/app/side_pane.rs:17-30`、`tui/src/app/side_focus.rs:16-24`）。群聊与“多模型同时回答同一问题”本次未找到。

后台终端的展示跟着当前显示的线程走：切回某线程时，界面会向 app-server 重新拉取该线程的后台终端列表并恢复，而不是沿用上一个线程的缓存（`tui/src/app/event_dispatch.rs:1977-1990`）；任务中心的未读标记来自任务行状态，查看后确认已读（`tui/src/app/agent_center/rows.rs:204-210`）。

## 8. Chat UI 状态所有权与同步

UI 状态分成四层：

| 状态 | 事实源 | 生命周期 |
|---|---|---|
| Composer 文本、附件、队列、待发送 steer | `ChatWidget` / `ThreadInputState` | 按 thread 保存，重连时恢复 |
| 视图栈、审批、问题编辑器、底部预览 | `BottomPane` | 当前进程内的 UI 状态 |
| 已提交消息列表 | `App.transcript_cells` | 当前会话的渲染列表 |
| thread、turn、item、审批请求 | app-server | 服务端会话状态，TUI 只持有投影 |

`App` 同时维护 transcript 的 cell 列表、终端原生历史、自有视图和可选的 overlay（`tui/src/app.rs:574-586`）。cell 列表是渲染的规范来源；内联模式下已提交 cell 还会写入终端回滚区，自有模式下由视图维护滚动、选择和布局缓存。两种模式由 `TranscriptMode::{Owned, Terminal}` 决定，要求自有模式与备用屏幕同时启用才走 Owned（`tui/src/transcript_mode.rs:7-23`）。

重连时，App 会捕获当前输入状态，重新建立 app-server 会话，再把状态恢复到新连接；如果初始 thread 启动失败，还会把初始消息退回 Composer。服务端通知在 `ThreadEventChannel` 中缓冲，活跃 thread 的通知才进入 `ChatWidget::handle_server_notification`（`tui/src/app/thread_routing.rs:2000-2052`）。因此“界面状态”和“任务状态”不是同一份数据：界面可以切换和重放，任务状态以 app-server 为准。

## 9. 键盘、焦点、响应式与关键路径

TUI 的默认键位覆盖了从进入会话到停止生成的完整路径（`tui/src/keymap.rs:1755-1808`）：

| 动作 | 默认键位 |
|---|---|
| 打断回合 | `Esc` |
| 提交 | `Enter` |
| 排队 | `Tab` |
| 打开 transcript | `Ctrl+T` |
| 全文查找 | `F3` |
| Activity 视图 | `F4` |
| 警告列表 | `F2` |
| 外部编辑器 | `Ctrl+G` |
| 复制 | `Ctrl+O` |
| 原始回滚模式 | `Alt+R` |
| 侧对话 | `Ctrl+/` |
| 输入历史搜索 | `Ctrl+R` / `Ctrl+S` |
| 调整推理强度 | `Alt+,` / `Alt+.` |
| 编辑排队消息 | `Shift+Left` / `Alt+Up` |
| 返回提示栈 | `Shift+Right` / `Alt+Down` |
| 切换后端主机 | `Leader` + `b` |
| 侧栏焦点（左、右、主 Composer、侧栏、隐藏） | `Leader` + `h`/`l`、`c`、`s`、`-` |

键位可以通过 `tui.keymap.*` 覆盖，加载时会解析并检测冲突；无效绑定会报告具体路径。焦点归属由 overlay 和 `BottomPane` 的视图栈决定：transcript overlay、警告视图、审批弹窗和问题编辑器分别通过 `owns_interaction_key` 或视图栈优先消费按键，未消费的事件才回到 Composer。`Esc` 的优先级是“关闭快捷键帮助 → 编辑/回溯 → 打断回合”，因此同一按键在不同视图下语义不同。

响应式行为主要是宽度驱动的重排：渲染宽度变化会触发 transcript 重排、流式队列重建和 Markdown 重渲染；终端高度变化由内联视口或自有视图的滚动逻辑处理。没有 CSS 断点、移动端抽屉或窗口尺寸档位。键盘可以完成选择会话、输入、发送、排队、停止和审批；终端本身不提供 ARIA 或屏幕阅读器语义，因此 Web 无障碍维度为 N/A，实际焦点顺序和组合键可用性仍需在目标终端观察。

## 10. 设计取舍与已确认边界

- **单一聊天表面**：交互集中在终端，仓库内没有并行的 Web/桌面聊天实现；代价是富内容、图片和复杂布局受终端能力约束。
- **app-server 作为任务事实源**：TUI 可以在重连后重建界面，但也意味着每个聊天动作都要经过协议层，启动和切换依赖 app-server 可用性。
- **内联回滚与自有 transcript 并存**：内联模式保留终端原生历史和复制习惯，自有模式允许原地重绘和更复杂的选择/搜索；两种模式的布局与重排路径不同。
- **steer 与 queue 双通道**：运行中提交默认尝试插入当前回合，显式排队则等回合结束；实现上存在两种控制粒度，也带来“被拒绝的 steer”这一额外状态。
- **会话级分支**：fork 产生新 thread，而不是在消息树内创建兄弟节点；因此没有消息级版本导航和树图。
- **没有浏览器或桌面工作台**：`/app` 只是深链到外部 Desktop 应用，不能据此认为本仓库包含桌面聊天实现。

## 11. 未验证事项

- 未运行 TUI，未观察真实终端中的焦点顺序、键盘可用性、鼠标选择、剪贴板和组合键行为。
- 未验证不同终端（Windows Terminal、iTerm2、tmux、Warp 等）对备用屏幕、超链接、图片和颜色的支持差异。
- 未验证语音输入、IDE 集成、桌面深链和系统通知在目标平台上的实际行为。
- 未对长会话、频繁切换和重连做运行时性能测量；代码中的分页和缓冲只能说明设计意图。
- 未确认外部 Desktop 应用是否复用本仓库的渲染逻辑；本笔记只覆盖本仓库代码。

## 12. 关键源码索引

- 启动与主循环：`codex-rs/tui/src/app/startup.rs:241`、`:1461-1711`
- TUI 事件入口与画面渲染：`codex-rs/tui/src/app.rs:872`、`:1318-1370`
- 后端目标：`codex-rs/tui/src/lib.rs:330-339`
- 提交与 steer：`codex-rs/tui/src/chatwidget/input_submission.rs:151-599`、`codex-rs/tui/src/app/thread_routing.rs:729`、`codex-rs/tui/src/app/user_turn_submission.rs:7`
- 中断：`codex-rs/tui/src/app/thread_routing.rs:739-808`
- 通知缓冲与分发：`codex-rs/tui/src/app/thread_events.rs:615-632`、`codex-rs/tui/src/app/thread_routing.rs:2000-2052`
- 审批：`codex-rs/tui/src/chatwidget/tool_requests.rs:284-340`、`codex-rs/tui/src/bottom_pane/approval_overlay.rs:75-78`、`:860-937`
- 底部布局：`codex-rs/tui/src/bottom_pane/mod.rs:2435-2585`
- Composer：`codex-rs/tui/src/bottom_pane/chat_composer.rs:1-162`
- 键位默认值：`codex-rs/tui/src/keymap.rs:1755-1808`
- 斜杠命令：`codex-rs/tui/src/slash_command.rs:12-89`
- 会话选择器：`codex-rs/tui/src/resume_picker.rs:1-82`
- 历史分页：`codex-rs/tui/src/app_server_session/history.rs:31-33`
- 输入状态保存与恢复：`codex-rs/tui/src/chatwidget/input_restore.rs:633-751`
- transcript 模式：`codex-rs/tui/src/transcript_mode.rs:7-23`
- 桌面深链：`codex-rs/tui/src/app/history_ui.rs:304-316`
- app-server 传输：`codex-rs/app-server/src/main.rs:42-58`
- 非交互 exec：`codex-rs/exec/src/cli.rs:63-85`、`sdk/typescript/src/exec.ts:95`
