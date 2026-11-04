# OpenCode Chat UI 调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：直接阅读源码（Web App、共享会话渲染包、TUI 与 Electron 壳层的组件与事件绑定），界面行为为静态确认，视觉效果与键盘可用性需运行验证
>
> 调查范围：各聊天表面的工作台结构、会话导航与现场恢复、Composer 与草稿、排队与中断、消息操作与审批问答工作流、多会话与后台生成、跨窗口与多服务端连接；消息渲染与数据语义分别进入消息渲染器、会话与消息管理类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 有三个聊天表面：Web App（`packages/app`，Solid，浏览器与 Electron 共用）、TUI（`packages/tui`，Solid 终端界面）、以及共享渲染包 `packages/session-ui`。三者共享同一套服务端会话数据与 SSE 事件流，界面差异集中在输入方式、导航结构与多服务端能力。

App 已从"单会话页面"演化为工作台：顶部按服务端 / 工作区 / 会话组织，支持同时连接多个 OpenCode 服务端，会话在标签间切换；Composer 内部集成排队面板、审批与提问 dock、活动芯片等；TUI 的会话路由带 Composer 子标签（shell、子 Agent、终端），并把草稿、排队与中断都纳入键盘操作。

## 工作台边界与用户主链

```text
进入聊天表面
  -> 选择服务端/工作区（App 顶部；桌面端进程内服务端或已连接守护进程）
  -> 会话列表或新建会话（App 会话列表/首页；TUI 命令面板）
  -> Composer 组织输入（文本、附件、引用、slash 命令、shell 模式）
  -> 提交：steer 或 queue（服务端 inbox 语义）
  -> 观察执行（execution 事件 -> busy/idle、重试、工具进度）
  -> 中断（App 中断按钮 / TUI 快捷键），可带 resume 让后续输入继续
  -> 消息操作（回退、复制、审批、提问、待办、fork）
  -> 离开后重进：HTTP 快照 + SSE 增量恢复现场
```

边界：消息如何投影与渲染属于消息渲染器；会话/消息/回退/fork 的数据语义属于会话与消息管理；发送受理、队列、压缩与重试的执行语义属于对话请求与上下文。

## 1. 页面结构、导航与多服务端

- **App 工作台**：路由与布局在 `packages/app/src/session/`（`screen.tsx`、`route.tsx`、`session-frame.tsx`、`session-layout.ts`）与 `packages/app/src/home`、`workspaces`、`servers`、`settings`、`usage`、`voice`、`new-session` 等目录；会话页由时间线、Composer 与侧栏组成。
- **多服务端**：App 可同时连接多个 OpenCode 服务端并在其间切换，每个服务端有独立的同步状态与数据目录（`packages/app/src/runtime/server/`）；桌面端默认连接本机服务端。
- **TUI**：`packages/tui/src/app.tsx` 组织路由；会话页在 `routes/session/index.tsx`，Composer 拆成 `routes/session/composer/`（主输入、shell、子 Agent、终端四个标签），对话框在 `component/dialog-*.tsx`（模型、Agent、会话列表、集成、工作区、MCP 等），插件化界面在 `feature-plugins/`。
- **共享渲染**：会话时间线、消息、工具卡片、diff（pierre）、文件与来源面板集中在 `packages/session-ui/src/`，App 与 TUI 复用同一渲染层。
- **桌面壳**：`packages/desktop/src/main`、`preload`、`renderer` 三层，主进程负责窗口、文件选择、外部链接、进程与服务端管理，渲染层加载 App 源码。

## 2. 会话列表、搜索与现场恢复

- **App**：会话列表按工作区/时间排序，支持搜索与归档过滤；首页提供最近会话与项目入口；归档后会同步清理列表与缓存并导航到相邻会话。
- **TUI**：命令面板（`component/command-palette.tsx`）与会话列表对话框（`component/dialog-session-list.tsx`）承担切换与搜索。
- **现场恢复**：会话与消息全部落库，重进时先拉 HTTP 快照再订阅 SSE；客户端维护按服务端维度的同步状态与请求队列（`runtime/server/global-sync/`），断线自动重连。
- **桌面端**：窗口恢复上次会话；每窗口草稿独立持久化。

## 3. Composer、草稿、附件与快捷输入

- **提交**：App 的 Composer 由 `packages/app/src/composer/`（编辑器、附件、命令、历史、请求构造）与 `packages/app/src/session/composer/`（会话级适配、排队、审批与 dock）组成；提交走 `composer/submit.ts`，把文本、附件、引用、模型与 delivery 组装成 prompt 请求。
- **附件**：图片与文件在客户端先转成可上传形态，服务端受理时物化为 blob；粘贴、拖入失败会提示并保留草稿。
- **草稿**：Web 端草稿与偏好经持久化层保存（`runtime/persistence/drafts.ts` 使用 IndexedDB 的 `opencode-drafts` 库，其余偏好走 localStorage 命名空间）；桌面端窗口级草稿由主进程 IPC 承担；TUI 侧本次未找到独立草稿持久化。
- **快捷输入**：slash 命令在客户端解析（`composer/client-slash-command.ts`），支持客户端命令与服务端命令；shell 模式在 Composer 内切换；`@` 触发文件/Agent 提及，编辑器支持行内注释式引用（`comments.tsx`、`comment-note.ts`）。
- **TUI 输入**：`routes/session/composer/index.tsx` 处理发送与模式切换，shell 标签展示命令输出，子 Agent 标签展示子会话进度，终端标签对接内嵌终端。

## 4. 发送前配置可见性

- App 的 Composer 控件显示当前会话模型与 Agent，并可切换模型、Agent 与变体；切换会更新会话绑定并在时间线留下切换消息。
- 本次未找到参数级（温度等）发送前编辑界面，生成参数由 Agent 的 `request` 与模型配置决定。
- TUI 通过模型/Agent/变体对话框切换，Composer 内不内嵌选择器。

## 5. 发送、排队、流式反馈与中断

- **排队**：服务端 inbox 语义（steer 插入当前轮、queue 排队）在 App 的排队面板中可见，可查看未投递条目并取消（`session/composer/queue-panel.tsx`、`queue.ts`；协议端点 `session.inbox.list`/`session.inbox.cancel`）。
- **流式反馈**：执行事件驱动 busy/idle，assistant 内容随事件增量更新；工具调用显示流式输入与进度；重试状态以独立卡片呈现。
- **中断**：`POST /api/session/:sessionID/interrupt` 中断当前执行，返回是否真正中断；带 `resume` 时会在中断后继续处理已排队的 steer 与下一项控制输入，而队列中的用户提示保持挂起（`packages/protocol/src/groups/session.ts:672-686`）。App 的中断按钮与 TUI 快捷键都调该端点。
- **活动提示**：Composer 上方的活动芯片显示当前执行的活动（编辑、搜索、执行命令等），插件也可注入自己的芯片（`activity-chips.tsx`、`plugin-pills.tsx`）。

## 6. 消息操作、审批、问答与待办

- **消息级操作**：复制、回退、跳转与元信息（Agent、模型、耗时、是否中断）；回退分阶段执行（暂存 → 提交/撤销），界面据此展示文件差异。
- **审批**：服务端发出权限请求后，App 在 Composer 区域挂载审批 dock，提供拒绝、允许一次、始终允许等回复；TUI 用对话框展示命令与 diff 后再回复。
- **提问**：`question` 工具的提问会以表单形式展示，支持单选/多选与自由文本；TUI 有对应问答界面。
- **待办**：会话 todo 以列表或面板展示，数据来自 `todowrite` 工具回注。
- **表单**：OAuth 等流程需要输入时以服务端表单形式下发，App 与 TUI 均可渲染与取消（`session.form.*` 端点）。

## 7. 多会话、子 Agent 与后台任务

- 不同会话可并行执行，界面按会话显示状态，没有全局"正在生成"汇总标记。
- 子 Agent 以子会话运行，TUI 的 Composer 子 Agent 标签与 App 的时间线内嵌卡片展示其进度；子 Agent 完成后结果回注父会话。
- 后台任务（如后台命令、计划任务）通过 job 与 schedule 子系统运行，完成结果以消息形式回到会话；本次未找到独立的后台任务管理页面。

## 8. 状态所有权与跨窗口同步

- UI 状态事实源是服务端：客户端拉取快照后用 SSE 增量投影，所有窗口与表面独立投影同一事件流。
- App 的同步层按服务端/会话分片，带请求队列与引用计数，避免多组件重复请求（`runtime/server/request-queue.ts`、`refcount.ts`）。
- 草稿与偏好是客户端本地状态：Web 端 IndexedDB + localStorage，桌面端按窗口持久化。
- 多窗口之间没有额外同步层，依赖服务端事件流与本地持久化的交叉更新。

## 9. 键盘、焦点与响应式

- TUI 以键盘为第一交互协议：发送、模式切换、命令面板、中断、会话切换都有默认键位且可配置（`config/keybind.ts`）。
- App 提供 Composer 提交/中断、模型与 Agent 切换等快捷键，桌面端另有窗口级菜单与快捷键。
- 移动端形态、焦点顺序与无障碍细节本次未展开，需在目标环境观察。

## 10. 设计取舍与已确认边界

- **共享渲染包**让 App 与 TUI 的表现层一致，代价是会话渲染必须只依赖通用能力；`session-ui` 有导入边界测试约束。
- **多服务端**让工作台可同时管理本机与远程会话，客户端同步层因此按服务端分片。
- **队列上移到服务端**：steer/queue 持久化在 inbox，客户端展示与取消队列条目，而不是仅在内存排队。
- **中断可续跑**：interrupt 的 resume 语义把"停止"与"继续处理已排队输入"分开，界面只需一个按钮。
- **边界**：本次未找到独立的后台任务管理中心、参数级生成配置界面；界面视觉效果与键盘可用性未运行验证。

## 11. 未验证事项

- 视觉效果、焦点顺序、无障碍与响应式行为需运行验证。
- 多服务端并存、断线重连与多窗口并发下的界面一致性未实测。
- TUI 的 shell/子 Agent/终端标签在真实终端环境下的交互未实测。
- 桌面端的窗口恢复、附件选择与外部链接行为未运行验证。

## 12. 关键源码索引

- `packages/app/src/session/`：会话页、路由、布局、时间线控制器
- `packages/app/src/composer/`：编辑器、附件、命令、历史、持久化
- `packages/app/src/session/composer/`：会话级 Composer、排队面板、活动芯片
- `packages/app/src/runtime/`：服务端同步、持久化
- `packages/session-ui/src/`：共享时间线、消息与工具渲染
- `packages/tui/src/app.tsx`、`routes/session/`、`component/`、`feature-plugins/`：TUI 结构
- `packages/desktop/src/main/`、`preload/`、`renderer/`：桌面壳
- `packages/protocol/src/groups/session.ts`：排队、中断、表单等端点
