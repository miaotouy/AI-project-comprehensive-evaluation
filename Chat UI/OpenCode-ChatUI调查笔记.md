# OpenCode Chat UI 调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`b8bd88901a4870ef3a5752840f4e23e11d54e24e`（分支：`dev`）
>
> 调查方式：从 [`../Chat/OpenCode-Chat调查笔记.md`](../Chat/OpenCode-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据，未重新调查代码；界面行为均为静态确认，视觉效果需运行验证
>
> 调查范围：TUI 与 Web App 双表面的工作台结构、会话导航与现场恢复、Composer 与草稿、生成反馈与停止、消息操作与审批工作流、多会话后台生成、跨窗口连续性；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 同时有 **TUI**（`packages/tui`）与 **Web App**（`packages/app`）两个聊天表面，共享同一服务端会话、SQLite 持久化与 SSE 事件流，按不同交互协议呈现同一用户主链：

- **TUI**：opentui 构建的单页会话视图，键盘为主——发送、shell 模式、自定义命令、双击 Esc 中断。
- **Web App**：浏览器页面 + 虚拟化 timeline + Composer 区域，Composer 上方按需挂载 permission/question/todo/followup/revert 各类 dock；中断按钮直接调 `api.session.interrupt`。
- **共享状态**：两表面都订阅同一事件流（TUI 经 `context/sdk.tsx`，Web 经 `server-sdk.tsx`），生成状态只有 `idle/retry/busy` 三态。
- **多会话并发**：每 session 一个 Runner，同会话串行、不同会话并行；界面没有全局"正在生成"汇总标记（按会话呈现）。
- 桌面端（Electron）复用 Web App 渲染，窗口级差异仅为草稿持久化与 last-active URL 恢复。

## 工作台边界与用户主链

```text
进入聊天表面（TUI 会话路由 / Web 会话页）
  -> 会话列表选择或新建（侧栏分页 / 命令面板搜索）
  -> Composer 组织输入与发送前配置（模型/Agent 由会话绑定，界面选择器）
  -> 提交或排队（Web shouldQueue / followup dock；TUI 发送）
  -> 观察与中断（Web 中断按钮 / TUI 双击 Esc）
  -> 消息操作（revert、copy、审批、提问、todo）
  -> 离开后再次进入：全量落库 + SSE 重连恢复现场（桌面端恢复 last-active URL）
```

边界：消息/part 如何经 SSE 投影到 store 并渲染属于消息渲染器（`../消息渲染器/OpenCode-消息渲染调查笔记.md`）；会话数据模型、列表查询与草稿持久化的数据语义属于会话与消息管理；发送链、中断、并发与后台任务的执行语义属于对话请求与上下文。

## 1. 页面结构、导航与多窗口

- **TUI**：消息路由 `routes/session/index.tsx`，承担发送、消息渲染入口、subagent footer、permission 对话框、fork 对话框；事件经 `context/sdk.tsx:82-117` 订阅。
- **Web App**：会话页（pages/session.tsx）组织 timeline 与 Composer；`SessionComposerRegion`（session-composer-region.tsx）挂载 permission/question/todo/followup/revert dock。
- **多窗口**：SSE 事件全量广播，多个窗口各自订阅同一事件流，无专门同步层（静态推断）。
- **桌面端（Electron）**：renderer 以源码方式复用 `@opencode-ai/app`（desktop/src/renderer/index.tsx:1-17），sidecar 进程内运行同一 opencode server（main/server.ts:57-184，Basic auth）；差异仅在窗口级：每窗口 MemoryRouter 与 last-active URL 恢复（index.tsx:85-111）、草稿 SQLite 持久化（main/ipc.ts:143-150 draft-*）、首启引导（onboarding）。

## 2. 会话列表、搜索与现场恢复

- **侧栏列表**：`directory-sync.ts:124-134` 用 `session.list({directory, limit, order:"desc"})`，`fetch(count=10)` 递增分页（数据语义见会话与消息管理笔记 5）。
- **命令面板**：跨目录 `session.list({parentID:null, search, limit:50})`（command-palette.ts:149）。
- **现场恢复**：会话与消息全量落库（SQLite），再次进入经 SSE 订阅恢复；断线 250ms 重连（server-sdk.tsx:307-308）。桌面端额外恢复 last-active URL。

## 3. Composer、草稿、附件与快捷输入

- **Web**：`createPromptSubmit.handleSubmit`（submit.ts:318-639）；排队发送（`shouldQueue`，submit.ts:482-487）与 followup dock（composer/session-followup-dock.tsx）；附件经 `blobDataUrl(blob, mime)` 转 data URL（submit.ts:101、:117）。
- **TUI**：发送 `component/prompt/index.tsx:1093-1110`；shell 模式 :1060-1068；自定义命令 :1070-1090。
- **草稿**：桌面端草稿按窗口持久化到 SQLite（main/ipc.ts:143-150 draft-*）；Web/TUI 端草稿粒度本次未在源笔记中覆盖。

## 4. Agent、模型、工具与发送前配置

会话级 `session.agent` 与 `session.model` 绑定（数据语义见会话与消息管理笔记 8），发送时不一致自动 `setAgentModel` 更新。界面层的模型/Agent 选择器形态与发送前参数配置入口，本次未在源笔记中覆盖（未调查）。

## 5. 发送、排队、流式反馈与停止

- **发送**：TUI `component/prompt/index.tsx:1093-1110`；Web `submit.ts`（`sendFollowupDraft` :58-208）。
- **排队**：Web 侧 `shouldQueue`（submit.ts:482-487）决定排队发送。
- **流式反馈**：事件 16ms 批量 flush 到 store 后由 timeline 渲染（渲染细节见消息渲染器笔记）；重试状态由 `SessionRetry` 组件展示（数据来自 `session_status {type:"retry",...}`，组件装配在消息渲染器笔记）。
- **停止**：Web 中断按钮直接 `api.session.interrupt`（pages/session.tsx:1823）；TUI **中断为双击 Esc**（两次 5 秒内按 Esc，component/prompt/index.tsx:407-418）。执行语义（abort 链与清理）见对话请求与上下文笔记 7。

## 6. 消息操作、分支与版本导航

- **Web**：用户消息底部 revert + copy；assistant text part 底部 copy + meta（agent · model · 时长 · interrupted）；会话头部菜单：重命名/分享/导出/归档/删除（组件装配见消息渲染器笔记 4，触发的工作流数据语义见会话与消息管理笔记 3、4）。
- **分支**：fork 对话框（TUI routes/session/index.tsx；数据语义见会话与消息管理笔记 4）。
- **审批**：`SessionPermissionDock`（app/src/pages/session/composer/session-permission-dock.tsx:8-74）reject/allowAlways/allowOnce 三按钮 → `sdk().api.permission.reply`；TUI 侧 `routes/session/permission.tsx`（含 diff 预览 :47-88）。按钮与组件装配见消息渲染器笔记 8。
- **提问**：`SessionQuestionDock`（Mark/Option 单选多选 + 自定义答案）；TUI `question.tsx`。
- **todo**：App 侧 `session-todo-dock.tsx` 与 todoState 状态机（session-composer-state.ts:13-22）；todo 数据写入经 `todowrite` 工具回注（执行语义见对话请求与上下文笔记 9，TodoTable 持久化见会话与消息管理笔记 2）。

## 7. 多会话、多模型、群聊与后台生成

- **多会话并发**：每 session 一个 Runner，同会话串行、不同会话并行；界面按会话呈现运行状态，无全局"正在生成"汇总标记（执行语义见对话请求与上下文笔记 8）。
- **后台生成**："detach 子 agent 到后台"端点 `POST /experimental/session/:id/background`（handlers/experimental.ts:159-188）；后台任务的界面反馈与返回入口本次未在源笔记中覆盖。
- **状态机**：只有 `idle/retry/busy` 三态（schema/src/session-status-event.ts:9-32），没有 queued/running/paused/complete 字面状态（执行语义见对话请求与上下文笔记 1）。

## 8. Chat UI 状态所有权与同步

- 两表面都订阅同一 SSE 事件流投影到各自 store（TUI `context/sdk.tsx:82-117`；Web `server-sdk.tsx`）——UI 状态事实源是服务端事件流。
- 跨窗口：SSE 全量广播，各窗口独立投影，无专门同步层（静态推断）。
- 草稿：桌面端按窗口持久化到 SQLite（3 节）。
- 生成状态：`session.execution.succeeded/failed/interrupted` → `{type:"idle"}`、`session.retry.scheduled` → `{type:"retry",...}`（投影细节见消息渲染器笔记 2）。

## 9. 键盘、焦点、响应式与关键路径可用性

- TUI：键盘为第一交互协议——发送、shell 模式、自定义命令、双击 Esc 中断（3 节、5 节）。
- Web/TUI 的无障碍与焦点细节本次未展开（需运行验证）。

## 10. 设计取舍与已确认边界

- **双表面共享服务端**：TUI 与 Web 是同一会话模型的两种交互协议，界面差异主要在输入与中断方式。
- **状态三态**：`idle/retry/busy` 语义较粗，排队/后台状态没有独立字面状态（数据语义见对话请求与上下文笔记 1）。
- **多窗口无专门同步层**：依赖 SSE 全量广播 + 各窗口独立投影。
- **类目边界**：本笔记只记录用户工作流与界面状态；审批/复制的组件装配在消息渲染器笔记 8；revert/fork 的数据变更在会话与消息管理笔记 4。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为需运行验证（本笔记结论主要来自静态代码）。
- TUI 与 Web 双表面并置运行时的同步表现未实测。
- 模型/Agent 选择器等发送前配置界面未调查。

## 12. 关键源码索引

- `packages/tui/src/routes/session/index.tsx`：TUI 会话路由（发送、中断、permission/fork 对话框）
- `packages/tui/src/components/prompt/index.tsx`：TUI 输入（发送 :1093-1110、双击 Esc :407-418、shell/自定义命令 :1060-1090）
- `packages/tui/src/context/sdk.tsx`：TUI 事件订阅（:82-117）
- `packages/app/src/pages/session.tsx`：Web 会话页（中断按钮 :1823）
- `packages/app/src/pages/session/composer/`：SessionComposerRegion、session-followup-dock、session-permission-dock、session-question-dock、session-todo-dock
- `packages/app/src/context/server-sdk.tsx`：Web 事件读取循环
- `packages/app/src/components/prompt-input/submit.ts`：Web 提交（sendFollowupDraft、shouldQueue、abort）
- `packages/desktop/src/`：Electron 窗口级差异（renderer/index.tsx、main/ipc.ts、main/windows.ts）
