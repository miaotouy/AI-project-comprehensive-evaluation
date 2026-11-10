# Pi Chat UI 调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/tui/`、`packages/coding-agent/src/modes/interactive/`、`packages/coding-agent/src/core/`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码与版本差异，定向跟踪运行中投递与 Esc/退出键盘绑定；其余界面机制采用文中来源范围，未运行交互会话，视觉、焦点与平台键盘表现待观察
>
> 调查范围：TUI 工作台结构、输入区与命令面板、会话选择器与搜索、树导航、fullscreen 视图、状态行与流式反馈、运行中投递（steer/followUp）的界面、bash 执行交互、退出工作流、UI 状态所有权；会话持久化与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 是 TUI 命令行编码 Agent，聊天表面由底部多行编辑器 + 聊天区 + footer 状态行组成，交互以命令与键盘为主：

- 输入区是底部多行编辑器，支持 fuzzy、文件路径与斜杠命令三类补全，以及 Ctrl+P 模型循环、Ctrl+G 外部编辑器、Alt+Enter 排队等快捷键。
- 会话导航靠选择器：`/resume`（内嵌搜索框：fuzzy/短语/正则）、`/tree`（树形导航 + label 书签）、`/session`（统计）。
- 状态行与专用状态指示器（工作、重试、压缩、分支摘要、空闲五类）反馈生成状态，OSC 9;4 终端进度条可配置。
- 运行中可投递 steer（回合边界转向）/followUp（排队），`queue_update` 事件驱动待处理列表显示。
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
  -> 退出：/quit、空编辑器 Ctrl+D；空编辑器双击 Esc 按设置打开 fork/tree 选择器或无动作
```

边界：会话/消息数据语义与列表扫描属于会话与消息管理（`../会话与消息管理/Pi-会话与消息管理调查笔记.md`）；prompt 输入处理、压缩与重试执行属于对话请求与上下文（`../对话请求与上下文/Pi-对话请求与上下文调查笔记.md`）；组件渲染与滚动属于消息渲染器（`../消息渲染器/Pi-消息渲染器调查笔记.md`）。

## 1. 输入区、命令面板与发送前配置

- **输入区**：底部多行编辑器承担全部文本输入，内部实现撤销栈、kill-ring、自动换行与 paste marker 处理，autocomplete 和 Tab 强制补全也归它负责（`packages/tui/src/components/editor.ts:664-726,2114-2193,2152-2170`）。补全 provider 由 interactive-mode 的 `setupAutocompleteProvider` 装配（`interactive-mode.ts:726-742`），向编辑器提供命令、文件、skill 和模板四类条目。
- **slash 命令**：内置命令由 `BUILTIN_SLASH_COMMANDS` 统一登记，覆盖设置、模型、导出导入、分享复制、会话管理、分支、信任登录、压缩恢复等类别；扩展命令与模板、skill 另由会话侧并入补全（`core/slash-commands.ts:19-42`、`agent-session.ts:2340-2363`）。提交入口是 `setupEditorSubmitHandler`（`interactive-mode.ts:2873-3060`），内置清单如下：

  ```
  /settings /model /scoped-models /export /import /share /copy /name
  /session /changelog /hotkeys /fork /clone /tree /trust /login /logout
  /new /compact /resume /reload /quit
  ```
- **快捷键**（注册于 `core/keybindings.ts:64-207`），`/hotkeys` 在聊天区打印完整清单（`interactive-mode.ts:6097-6209`）：

  | 按键 | 作用 |
  |---|---|
  | Ctrl+P / Shift+Ctrl+P | 模型循环（:77-84） |
  | Ctrl+L | 模型选择器（:85） |
  | Shift+Tab | thinking 循环（:73-76） |
  | Ctrl+T | thinking 块开关（:87-90） |
  | Ctrl+G | 外部编辑器（:95-98） |
  | Ctrl+X | 复制消息（:99-102） |
  | Alt+Enter | followUp 队列（:103-106） |
  | Alt+Up | 取回排队消息（:107-110） |
  | Ctrl+V / Alt+V | 粘贴图片（:111-114） |
  | Ctrl+D | 退出（:68） |
  | Esc | 中止（:66） |
- **发送前配置**：`/settings` 打开设置选择器（`SettingsSelectorComponent`，`interactive-mode.ts:4380-4419` 传入当前值，:4420 起回调写回），覆盖自动压缩、图片、模型 transport、thinking、主题、mermaid、doubleEscapeAction、fullscreen 输出等；模型、作用域模型、登录与登出由对应命令管理；设置分 global/project 两级（`settings-manager.ts:180-204`、:316-347，项目级仅在项目受信时读写）。
- **图片附件**：Ctrl+V 从剪贴板读图（图片写入临时文件、以路径插入编辑器）或读文本（`handleClipboardPaste`，`interactive-mode.ts:2848-2871`）；图片是否发送由 `settings.images` 控制（数据侧见会话与消息管理笔记 §8）。

## 2. 会话选择器与搜索

- `/resume` 打开会话选择器，当前目录会话走列表接口、全部会话走全量接口，两者均异步加载并显示进度。条目范围与排序由 Tab（当前目录/全部）和 Ctrl+S（按线程/按最近/按相关度）控制，列表还支持 Ctrl+N 按名称过滤、Ctrl+P 切换路径显示；Enter 恢复选中会话，Esc 取消（`components/session-selector.ts:551-573,685,922-1026`；入口 `showSessionSelector`，`interactive-mode.ts:5096-5129`）。
- **搜索框**：内嵌在列表顶部，支持 token 模式（fuzzy 加短语引号）与 `re:` 正则模式；匹配对象是会话 id、名称、全部消息文本与 cwd 的组合（`session-selector.ts:417-419`、`session-selector-search.ts:26-114`；数据侧见会话与消息管理笔记 §5）。
- **删除/重命名**：Ctrl+D 或 Ctrl+Backspace 进入删除确认，确认后先尝试移入 trash、失败再直接 unlink 会话文件；当前活动会话不可删。Ctrl+R 进入重命名模式，结果写入会话的 `session_info` 条目（`components/session-selector.ts:394-405,576-601,645-680,866-920`；写入入口 `interactive-mode.ts:5118-5123`）。数据语义见会话与消息管理笔记 §3。

## 3. 树导航与消息操作

- `/tree` 打开树选择器，会话管理器把整棵树的数据交给它渲染（`components/tree-selector.ts:1328`；打开动作 `interactive-mode.ts:4955-5093`；树数据入口 `session-manager.ts:1310-1348`）。
- 树内编辑与过滤：Shift+L 编辑 label、Shift+T 切换 label 时间戳；过滤器由 treeFilterMode 与 filter 快捷键组定义（`settings-manager.ts:1207-1217`、`core/keybindings.ts:179-206`）。选中条目后可选择不摘要、摘要或自定义提示摘要，确认后移动 leaf；界面会清空消息区并重建初始消息，选中 user 消息时其文本回填编辑器（`interactive-mode.ts:4988-4992,5053-5057`；执行侧见对话请求与上下文笔记，数据侧见会话与消息管理笔记 §4）。
- `/fork` 让用户先挑一条 user 消息，再从该消息创建分支，插入位置可选；`/clone` 复制当前会话（`interactive-mode.ts:2816,4934`、`agent-session-runtime.ts:262-352`）。
- `/copy` 复制最后一条助手消息；工具与摘要组件支持展开收起；`/session` 显示用户/助手/工具消息数、token 与成本统计（`agent-session.ts:3291-3313`、`interactive-mode.ts:3168`；数据侧见会话与消息管理笔记 §5）。
- 无就地编辑：历史是追加型，修改以分支表达（数据语义见会话与消息管理笔记 §4）。

## 4. fullscreen 视图

- fullscreen（alt-screen）模式由 TuiAltScreen 渲染，regular 与 fullscreen 之间切换时组件与焦点保持不变（`packages/tui/src/tui-alt-screen.ts`、`interactive-mode.ts:791-805`）。
- **transcript 搜索**：Ctrl+Shift+F 打开右上角搜索框，对 transcript 逐字匹配，Enter 或 Ctrl+G 跳到下一个命中、Shift+Enter 或 Ctrl+Shift+G 跳到上一个，Esc 关闭。命中段高亮并反显当前项，跳转时会抑制滚动跟随（`alt-screen-search.ts:71-97,105-157`、`packages/tui/src/keybindings.ts:192-207`、`tui-alt-screen.ts:416-519,1089`）。
- **滚动**：PageUp/PageDown 整页翻动，Home/End 直达顶部与底部，Ctrl+Shift+上下跳到上一条或下一条语义 prompt；半页与单行滚动默认未绑定按键，可在 keybindings 配置（`packages/tui/src/keybindings.ts:168-209`、`tui-alt-screen.ts:585-624`）。
- **鼠标**：多击选中单词或整行，粒度由 selectionGranularity 的 word/line 取值控制；Windows fullscreen 下未修饰的右键把剪贴板内容粘贴到聚焦输入；在 tmux、zellij 或 STY 下鼠标跟踪降级为按钮运动模式（`tui-alt-screen.ts:271-284,859-991`、`interactive-mode.ts:2834-2846`）。
- **退出行为**：退出 fullscreen 时按 fullscreenExitOutput 的取值处理，transcript 打印完整转录文本，resume-hint 恢复屏幕并只提示 resume；滚动条样式另有配置项（`settings-manager.ts:1140-1148,1150-1153`、`interactive-mode.ts:782-789`）。

## 5. 状态行与流式反馈

- footer 汇总模型、状态、cwd（含 git 分支与会话名）、上下文百分比、token 与成本；成本标签只对已知订阅制显示 `(sub)`，判定依据是 kimi-coding 或 OAuth 中声明了 `isSubscription` 的 Provider（`components/footer.ts:138-145`、`model-runtime.ts:462`）。
- 生成中由状态指示器展示工作、重试、压缩、分支摘要四类状态，空闲时退回占位状态；启动、压缩、自动重试、摘要重试等事件在事件处理器里各自切换指示器与 Esc 处理（`components/status-indicator.ts:105-113`、`interactive-mode.ts:3068-3396`）。
- OSC 9;4 终端进度条可配置：agent 启动时置位、结束时复位（`settings-manager.ts:1117-1119`、`interactive-mode.ts:3078-3080,3271-3273`）。
- 流式渲染：每次消息更新整体重建 assistant 组件内容，TUI 侧由 requestRender 以 16ms 合并帧节流；组件层细节归消息渲染器笔记（`interactive-mode.ts:3148-3181`、`packages/tui/src/tui.ts:765-817`）。
- 工具增量：工具执行的开始、更新与结束事件驱动工具组件流式输出，assistant 消息里的 toolCall 块也在消息更新时同步建组件并逐步更新参数（`interactive-mode.ts:3153-3177,3227-3268`）。

## 6. 运行中投递与键盘工作流

- **steer/followUp**：运行中提交普通消息会进入 steer 队列，等当前助手与工具批次结束后才转向，入队本身不会中止在途调用；Alt+Enter 直接投递 followUp。待处理列表由 queue_update 事件驱动，以 Steering 行或 Follow-up 行展示并提示 Alt+Up 取回，Alt+Up 把排队消息取回编辑器（`interactive-mode.ts:4193-4210,4212-4231`、`core/keybindings.ts:103-106`）。队列结构与批次后消费见 [Agent 队列](../../pi/packages/agent/src/agent.ts#L307-L351)、[批次后消费](../../pi/packages/agent/src/agent-loop.ts#L267-L315)，执行语义见对话请求与上下文笔记 §8。
- **Esc 语义**：流式输出中按 Esc 取回排队消息并 abort 当前回合；bash 运行中取消 bash，处在 bash 模式则清空；编辑器为空时 500ms 内双击 Esc，按 doubleEscapeAction（fork/tree/none）打开对应选择器（`interactive-mode.ts:2769-2795`、`settings-manager.ts:1197-1199`）。
- **中止**：自动重试、压缩与分支摘要期间按 Esc 分别中止对应流程（`interactive-mode.ts:3294-3299,3342-3353,5026-5028`）。`AgentSession.abort()` 的中断语义见对话请求与上下文笔记 §6。
- **退出**：`/quit` 与空编辑器下的 Ctrl+D 都会关闭会话，关闭时停止 TUI 并打印恢复用的 resume 命令；Ctrl+C 只清空编辑器（`interactive-mode.ts:3766-3817`、`core/keybindings.ts:67`）。
- 孤立 ESC 的序列重组窗口可配置：`PI_TUI_ESC_TIMEOUT` 默认 10ms、SSH 下 100ms（`packages/tui/src/terminal.ts:104-121`、`stdin-buffer.ts:387-395`）。

## 7. bash 执行交互

- 以 `!` 开头的输入直接执行 bash 命令，`!!` 执行时把该命令排除出上下文；同一时间只允许一个 bash 运行，运行中提示 Esc 取消。输出由专用组件流式显示，增量经 bash_execution_update 事件送达（`interactive-mode.ts:3008-3024,3223-3225`、`components/bash-execution.ts:21-98`）。
- bash 执行消息的持久化形状与上下文排除语义见会话与消息管理/对话请求与上下文笔记。

## 8. 多会话、后台与并发边界

- 单会话单 agent 循环：无多会话并行 UI；`agent_settled` 事件通知 UI 进入空闲（`interactive-mode.ts:3285-3287`；执行侧见对话请求与上下文笔记 §8）。
- 子会话：扩展可用 `createAgentSession`（`core/sdk.ts:169`）自行启动子会话；本次未找到 UI 层面的多 Agent 编排。
- 跨窗口/跨端同步与系统通知不适用（TUI 单进程）。

## 9. UI 状态所有权与同步

- **draft**：编辑器文本与编辑历史都保存在编辑器组件内部；运行中投递的内容改由会话对象持有，分别记录在 steering 与 followUp 两个队列上，abort 或取回时再回写编辑器（`packages/tui/src/components/editor.ts`、`agent-session.ts:319-324`；取回流程见 §6）。
- **selection**：选择器的选中项、搜索框文本与过滤器状态归各自组件所有，组件实例随 showSelector 的创建与销毁一起生灭（`session-selector.ts:288-310`）。
- **busy 状态**：会话对象的 streaming 与 compacting 标志是事实源，UI 只把它们投影到状态指示器容器与 footer（`agent-session.ts:878-885,946-952`；投影见 §5）。
- **现场恢复**：切换会话前先由 teardownCurrent 持久化进行中的响应，切换后清空消息区并重建初始消息；`/resume` 可恢复 aborted 会话，regular 与 fullscreen 切换保留组件与焦点（`interactive-mode.ts:1861-1862`；执行侧见对话请求与上下文笔记 §10，数据侧见会话与消息管理笔记 §3，切换见 §4）。
- **pending input**：非交互测试路径用输入回调与待处理输入缓冲承接输入；压缩期间提交的消息进入单独队列，压缩结束后重放（`interactive-mode.ts:3053-3057,4233-4239,4251-4322`）。

## 10. 键盘、焦点与关键路径可用性

- **键盘主链**：先在选择器里选定会话，再在编辑器输入并发送（Enter 发送、Shift+Enter 换行），随后按 Esc 中止，或进行复制（Ctrl+X）、删除（Ctrl+D）与 fork 等消息操作；`/hotkeys` 提供运行时清单（`packages/tui/src/keybindings.ts:143-158`、§1）。
- **焦点传播**：选择器的焦点沿容器、会话列表到搜索输入逐层传递，输入法光标位置随焦点走；fullscreen 搜索框独立聚焦（`session-selector.ts:722-733`、`alt-screen-search.ts:116-123`）。
- 静态代码可确认键绑定与焦点传播路径；焦点顺序、键盘实际可用性、IME 行为、OSC/终端能力差异需运行验证（§12）。

## 11. 设计取舍与已确认边界

- **事件驱动但全量重渲染**：`message_update` 每 delta 触发组件重建，TUI 以 16ms 帧节流兜底；没有增量 AST 或虚拟列表（渲染侧见消息渲染器笔记）。
- **键盘为主的工作流**：删除、分支、压缩、复制等操作都有 slash 命令或快捷键入口；fullscreen 导航（搜索/整页/半页/单行滚动）与文本选择以键盘+鼠标组合覆盖。
- **终端能力依赖**：OSC 9;4 进度条、图片显示等依赖终端能力探测（渲染侧见消息渲染器笔记）；多路复用器（tmux/zellij/STY）下鼠标跟踪降级为按钮运动模式以减少转发延迟（`tui-alt-screen.ts:271-284`）；全宽行绘制有直接引用快速路径（`packages/tui/src/layout.ts:319-325`）。

## 12. 未验证事项

- 未在真实终端运行：焦点顺序、键盘可用性、IME、OSC 9;4、图片显示等行为未实测。
- 流式期间的帧率、闪烁与长会话滚动性能未测量。
- 多会话并行、通知与跨端连续性不适用（TUI 单进程）。

## 13. 模型与思考设置工作流

`/thinking` 打开可搜索的思考等级选择器，模型选择器也以同一模式显示默认项。用户按 Enter 的变更仅作用于当前会话，Ctrl+S 才持久化为默认设置；因此 TUI 可同时表达“本轮选择”和“后续启动默认值”两种作用域。运行中的 bash 输出在切换 thinking 可见性时会保留，而不会被局部界面重建清空（`packages/coding-agent/src/modes/interactive/components/thinking-selector.ts:37-104`、`model-selector.ts:73-162`、`packages/coding-agent/CHANGELOG.md` 的 0.84.3 修复项）。

## 14. 实验客户端与 fullscreen 交互补充

默认 `pi` TUI 之外，仓库有 `apps/p2` 应用：它的 TUI host 复用稳定版 alternate-screen renderer、编辑器、消息卡、主题与工具渲染器；会话由 p2 的 session worker 持有，页面与 TUI 通过 Chord 对象引用观察更新，worker 崩溃后重启并保留失败到重试，断线重连由 p2 的 hosts 处理（`apps/p2/src/hosts/tui.ts`、`apps/p2/src/hosts/session-workers.ts`、`packages/chord/README.md`）。

稳定 fullscreen 表面增加可点击 jump-to-end 指示器、搜索前后按钮、可拖动滚动条和 Alt 加速滚轮。选区自动复制可关闭；此时复制命令优先复制当前选区，并且后端失败会显示错误（`packages/coding-agent/src/modes/interactive/tui-renderer.ts:24-37`、`packages/tui/src/tui-alt-screen.ts:496-625,968-1116,1419-1468,1621-1641`）。这些交互均未在真实终端运行验证。

## 15. 关键源码索引

- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`：提交入口、事件到 UI、树导航、会话选择器、队列显示与取回、Esc 语义（按符号定位，行号随文件增长漂移）
- `packages/coding-agent/src/modes/interactive/components/session-selector.ts`（会话选择器）、`session-selector-search.ts`（搜索）
- `packages/coding-agent/src/core/slash-commands.ts:19-42`（命令清单）、`core/keybindings.ts:64-207`（快捷键）
- `packages/coding-agent/src/modes/interactive/components/footer.ts`、`status-indicator.ts`（状态行）
- `packages/coding-agent/src/modes/interactive/components/bash-execution.ts`（bash 流式）
- `packages/coding-agent/src/core/settings-manager.ts:1117-1119`（OSC 进度条）、`:1197-1199`（doubleEscapeAction）、`:1140-1148`（fullscreenExitOutput）
- `packages/tui/src/alt-screen-search.ts`（transcript 搜索）、`tui-alt-screen.ts:416-519`、`:859-991`（搜索/滚动/鼠标选择）
- `packages/tui/src/components/editor.ts`（输入区）、`tui.ts:765-817`（帧节流）
