# OpenCode Chat UI 调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：直接阅读源码（Solid TUI 与 Web App 双表面组件与事件绑定、Electron 窗口层），界面行为均为静态确认，视觉效果与键盘可用性需运行验证
>
> 调查范围：TUI 与 Web App 双表面的工作台结构、会话导航与现场恢复、Composer 与草稿、生成反馈与停止、消息操作与审批工作流、多会话后台生成、跨窗口连续性、发送前配置可见性；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 同时有 **TUI**（`packages/tui`，opentui + Solid）与 **Web App**（`packages/app`，Solid）两个聊天表面，共享同一服务端会话、SQLite 持久化与 SSE 事件流，按不同交互协议呈现同一用户主链：

- **TUI**：单页会话视图，键盘为第一交互协议——发送、shell 模式、自定义命令、双击 Esc 中断、命令面板切换会话。
- **Web App**：会话页（`pages/session.tsx`）+ 虚拟化 timeline + Composer 区域，Composer 上方按需挂载提问、审批、待办、回退、追问等各类操作 dock；中断按钮直接调 `api.session.interrupt`。
- **共享状态**：两表面都订阅同一事件流（TUI 经 `context/sdk.tsx`，Web 经 `server-sdk.tsx`），生成状态只有 `idle/retry/busy` 三态；UI 状态事实源是服务端事件流。
- **多会话并发**：每 session 一个 Runner，同会话串行、不同会话并行；界面按会话呈现运行状态，无全局"正在生成"汇总标记。
- **桌面端（Electron）**：renderer 复用 `@opencode-ai/app`，sidecar 进程内运行同一 opencode server；窗口级差异为草稿 SQLite 持久化与 last-active URL 恢复。

## 工作台边界与用户主链

```text
进入聊天表面（TUI 会话路由 / Web 会话页）
  -> 会话列表选择或新建（Web 侧栏分页 / 命令面板搜索；TUI 命令面板）
  -> Composer 组织输入与发送前配置（模型/Agent 选择器 + variant）
  -> 提交或排队（Web shouldQueue / followup dock；TUI 发送）
  -> 观察与中断（Web 中断按钮 / TUI 双击 Esc）
  -> 消息操作（revert、copy、审批、提问、todo）
  -> 离开后再次进入：全量落库 + SSE 重连恢复现场（桌面端恢复 last-active URL）
```

边界：消息/part 如何经 SSE 投影到 store 并渲染、操作栏组件装配属于消息渲染器（`../消息渲染器/OpenCode-消息渲染调查笔记.md`）；会话数据模型、列表查询与草稿持久化的数据语义属于会话与消息管理；发送链、中断、并发与后台任务的执行语义属于对话请求与上下文。

## 1. 页面结构、导航与多窗口

- **TUI**：消息路由是单文件大会话控制器（`routes/session/index.tsx`，2725 行），承担发送（`Prompt`，:1323-1329）、消息渲染入口、子 agent footer（:1311）、权限与提问对话框（:1299、:1305）、时间线/分支对话框（:527-561）以及 share/rename/compact 等会话命令（:500-579）；事件经 `context/sdk.tsx:82-117` 订阅，16ms 批量投递，断线按 1s→30s 指数退避。
- **Web App**：会话页（`pages/session.tsx`）组织 timeline 与 Composer；`SessionComposerRegion`（`pages/session/composer/session-composer-region.tsx:11-168`）按需挂载提问、审批、待办、回退、追问等 dock 与 Composer 本体；新式 PromptInputV2Composer 与旧式 PromptInput 由 `newSessionDesign()` 开关选择（`pages/session.tsx:2183-2239`）。
- **多窗口**：SSE 事件全量广播，多个窗口各自订阅同一事件流、独立投影，无专门同步层（静态推断，见第 8 节）。
- **桌面端（Electron）**：renderer 以源码方式复用 `@opencode-ai/app`（`desktop/src/renderer/index.tsx:3-17`），sidecar 进程内运行同一 opencode server（`main/server.ts` 的 `spawnLocalServer` :57，Basic auth 头 :197）。
- 窗口级差异仅三处：每窗口独立 MemoryRouter 与 last-active URL 恢复（`index.tsx:85-111`）、草稿按窗口持久化到 SQLite（`main/ipc.ts:143-150` 的 draft 系列通道）、首启引导；macOS 关窗不退出进程，`activate` 时重建窗口（`main/index.ts:411-418`）。

## 2. 会话列表、搜索与现场恢复

- **侧栏列表（Web）**：目录同步模块按目录查询会话列表（倒序、限量参数见 `context/directory-sync.ts:124-134`），按 10 条递增分页（数据语义见会话与消息管理笔记 5）；归档会话从列表移除（:136-146）。
- **首页入口**：打开目录时若为空目录，自动初始化 Git 后注册为项目（`pages/home/home-controller.ts:89-109`），项目行支持右键菜单（`pages/home/home-projects-view.tsx:478`）。
- 首页最近会话按"更新时间，缺省取创建时间"降序、id 决胜排序（`pages/layout/helpers.ts:12-16` 的 `compareSessionTime`，`home-sessions-controller.tsx:257`）。
- **命令面板**：跨目录搜索会话，只查顶层会话并限量 50 条（`app/src/components/command-palette.ts:149`，入口在 `dialog-command-palette-v2.tsx:82`）；TUI 侧会话切换同样走命令面板（`component/command-palette.tsx`、`dialog-session-list.tsx`）。
- **现场恢复**：会话与消息全量落库（SQLite），再次进入经 SSE 订阅恢复；Web 断线 250ms 重连（server-sdk.tsx:307-308）。桌面端额外恢复 last-active URL（renderer/index.tsx:105-111）。

## 3. Composer、草稿、附件与快捷输入

- **Web**：提交逻辑集中在 `createPromptSubmit.handleSubmit`（`components/prompt-input/submit.ts:318-639`），含排队发送（`shouldQueue`，`pages/session.tsx:1754-1757` → `submit.ts:482-487`）与追问 dock（`composer/session-followup-dock.tsx`，暂存队列、编辑、补发 :8-105）。
- Web 附件：图片经 `blobDataUrl` 转 data URL 随消息发送（`submit.ts:101, 117`）；粘贴或拖入失败以 toast 恢复（`prompt-input-v2.tsx:365-384`）。
- **TUI**：发送在 `component/prompt/index.tsx:1092-1121`；shell 模式以 `!` 进入、Esc/backspace 退出（:1059-1070、:831-857）；自定义命令 :1071-1091。
- TUI 光标样式可配置（`tui.json` 的 `cursor` 节点，`config/index.tsx:33-40, 90-92, 129-132`），style 取以下四值之一，并可控制闪烁：

  ```
  block / underline / line / default
  ```
- **草稿**（三表面各自独立）：
  - Web：文本与图片 blob 经 IndexedDB `opencode-drafts` 持久化（`utils/draft-store.ts:97-154`），会话页以草稿页签形式恢复（`layout.tsx` :94-、:173-176）；
  - 桌面端：按窗口持久化到 SQLite（`main/ipc.ts:143-150`，库文件 `userData/drafts.sqlite` :58）；
  - TUI：未找到草稿持久化入口，prompt 历史只在进程内记录（`component/prompt/history.tsx`）。

## 4. Agent、模型、工具与发送前配置

- 会话级 `session.agent` 与 `session.model` 绑定（数据语义见会话与消息管理笔记 8），发送时不一致会自动调用 `setAgentModel` 更新（`packages/opencode/src/session/prompt.ts:672-689`）；发送前模型与 Agent 选择改的是提交链读取的局部当前值（`submit.ts:338-341`）。
- **界面选择器（Web）**：`SessionComposerControls`（`composer/session-composer-controls.ts:23-50`）提供 agents 查询与模型选择；V2 Composer 还暴露 agent 与 model variant 的循环切换快捷键（`agent.cycle`、`model.variant.cycle`）以及提交/停止按钮（`components/prompt-input-v2.tsx:385-409`）。**本快照中 Composer 暴露的是当前会话已绑定的 agent/model + variant 选择，未发现参数级（temperature 等）发送前配置界面**（参数由 agent/model 配置与 provider 默认决定，见对话请求与上下文笔记 4）。
- **TUI**：模型/Agent 切换走命令面板与对话框（component/dialog-model.tsx、dialog-agent.tsx、dialog-variant.tsx），未发现 Composer 内嵌选择器。

## 5. 发送、排队、流式反馈与停止

- **发送**：TUI 在 `component/prompt/index.tsx:1092-1121` 经 SDK 客户端发起会话请求；Web 侧 `submit.ts` 的 `sendFollowupDraft`（:58-208）内含命令、shell 与普通发送三条路径，最终走 `api.session.prompt`（:168-199、:88-105、:491-510）。
- **排队**：Web 侧 `shouldQueue`（pages/session.tsx:1754-1757：settings followup=queue 且 busy 且未被 question/permission 阻塞且非子会话）决定排队发送，入 followup dock 后空闲补发（:1777-1795）。
- **流式反馈**：事件 16ms 批量 flush 到 store 后由 timeline 渲染（渲染细节见消息渲染器笔记）；重试状态由 `SessionRetry` 组件展示（timeline/message-timeline.tsx:1247，数据来自 `session_status {type:"retry",...}`，server-session.ts:970-976）。
- **停止（Web）**：中断按钮直接调 `api.session.interrupt`（`pages/session.tsx:1820-1825`）；V2 Composer 的停止回调同样走该接口（`prompt-input-v2.tsx:403-408`、`submit.ts:275-277`）。
- **停止（TUI）**：中断为双击 Esc（两次 5 秒内按 Esc，`component/prompt/index.tsx:392-422`；Esc 绑定于 `config/keybind.ts:97` 的 `session_interrupt`）。执行语义（abort 链与清理）见对话请求与上下文笔记 7。

## 6. 消息操作、分支与版本导航

- **Web**：用户消息底部 revert + copy；assistant text part 底部 copy + meta（agent · model · 时长 · interrupted）——组件装配见消息渲染器笔记，数据语义见会话与消息管理笔记 4。会话头部菜单：重命名/分享/导出/归档/删除。
- **分支**：TUI fork 对话框（routes/session/index.tsx:541-561 `DialogForkFromTimeline`）；Web 侧 fork 入口经命令（use-session-commands.tsx，`session.fork`）；数据语义（复制边界、parentID 重映射）见会话与消息管理笔记 4。
- **审批**：`SessionPermissionDock`（`composer/session-permission-dock.tsx:8-74`）提供"拒绝/始终允许/允许一次"三种回复，统一调 `api.permission.reply`（`session-composer-state.ts:78-93`）；TUI 侧在 `routes/session/permission.tsx`（含 diff 预览 :22-88）。按钮与组件装配见消息渲染器笔记。
- **提问**：`SessionQuestionDock`（Mark/Option 单选多选 + 自定义答案，composer/session-question-dock.tsx）；TUI `routes/session/question.tsx`。
- **TUI 复制**：在 tmux 会话中同时写入 OSC52 直写序列与 tmux passthrough，兼容 `set-clipboard on` 配置下的 ssh 复制（tui/src/clipboard.ts:23-28）。
- **todo**：App 侧 `session-todo-dock.tsx` 与 todoState 状态机（`composer/session-composer-state.ts:13-22`），支持隐藏、清空、打开、关闭等视图动作（:120-176）；todo 数据写入经 `todowrite` 工具回注（执行语义见对话请求与上下文笔记 9，TodoTable 持久化见会话与消息管理笔记 2）。

## 7. 多会话、多模型、群聊与后台生成

- **多会话并发**：每 session 一个 Runner，同会话串行、不同会话并行；界面按会话呈现运行状态（session_status per session），无全局"正在生成"汇总标记（执行语义见对话请求与上下文笔记 8）。
- **子会话/后台生成**：子 agent 以子会话（parentID）运行，TUI 底部显示 `SubagentFooter`（`routes/session/index.tsx:1310-1312`）；"detach 同步子 agent 到后台"的端点在 `handlers/experimental.ts:159-172`（`POST /experimental/session/:id/background`），TUI 快捷键 ctrl+b（`keybind.ts:98`）；后台任务完成的界面反馈本次未找到独立返回入口（结果经合成 user 消息回注，见对话请求与上下文笔记 8）。
- **状态机**：只有 `idle`/`retry`/`busy` 三态（`schema/src/session-status-event.ts:9-32`），没有排队、运行、暂停、完成等独立字面状态（执行语义见对话请求与上下文笔记 1）；Web 端 V2 事件合成 busy/idle（`server-session.ts:963-976`）。

## 8. Chat UI 状态所有权与同步

- 两表面都订阅同一 SSE 事件流投影到各自 store（TUI 侧 `context/sdk.tsx:82-117` 与 `sync.tsx`；Web 侧 `server-sdk.tsx` 与 `server-session.ts`/`global-sync/event-reducer.ts`）——UI 状态事实源是服务端事件流。
- 跨窗口：SSE 全量广播，各窗口独立投影，无专门同步层（静态推断）。
- 草稿：Web 端 IndexedDB、桌面端按窗口 SQLite（第 3 节）；TUI 端进程内。
- 生成状态由会话执行事件投影而来，映射见下表（`server-session.ts:963-976`；V1 事件路径为 `session.status`）：

  | 服务端事件 | 投影状态 |
  |---|---|
  | `session.execution.started` | `{type: "busy"}` |
  | `session.execution.succeeded` / `failed` / `interrupted` | `{type: "idle"}` |
  | `session.retry.scheduled` | `{type: "retry", ...}` |

## 9. 键盘、焦点、响应式与关键路径可用性

- TUI：键盘为第一交互协议——发送、shell 模式、自定义命令、双击 Esc 中断（第 3、5 节）；keybind 系统可覆盖（config/keybind.ts）。
- Web：Composer 提交/停止、agent/model variant 切换有快捷键（prompt-input-v2.tsx:413-428）；移动端会话侧栏以底部 tabs 呈现（pages/session.tsx:2245 mobileTabsBottom）。
- Web/TUI 的无障碍与焦点顺序细节本次未展开（需运行验证）。

## 10. 设计取舍与已确认边界

- **双表面共享服务端**：TUI 与 Web 是同一会话模型的两种交互协议，界面差异主要在输入与中断方式。
- **状态三态**：`idle`/`retry`/`busy` 语义较粗，排队与后台状态没有独立字面状态（数据语义见对话请求与上下文笔记 1）；Web 端排队是客户端级暂存（followup dock），V2 另有服务端 `delivery:"queue"`（对话请求与上下文笔记 8）。
- **多窗口无专门同步层**：依赖 SSE 全量广播 + 各窗口独立投影。
- **类目边界**：本笔记只记录用户工作流与界面状态；审批/复制的组件装配在消息渲染器笔记；revert/fork 的数据变更在会话与消息管理笔记 4。
- **本快照未调查**：模型/Agent 参数级（temperature 等）发送前配置界面（静态推断不存在，检查范围：session-composer-controls.ts、prompt-input-v2.tsx、submit.ts 均无参数编辑控件）。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为需运行验证（本笔记结论主要来自静态代码）。
- TUI 与 Web 双表面并置运行时的同步表现未实测。
- 后台任务完成的界面反馈入口未调查。
- 移动端会话侧栏抽屉形态未运行验证。

## 12. 关键源码索引

- `packages/tui/src/routes/session/index.tsx`：TUI 会话路由（发送、权限/提问/fork/timeline 对话框、subagent footer）
- `packages/tui/src/component/prompt/index.tsx`：TUI 输入（发送 :1092-1121、双击 Esc :392-422、shell/自定义命令 :1059-1091）
- `packages/tui/src/context/sdk.tsx`、`sync.tsx`：TUI 事件订阅与 store
- `packages/app/src/pages/session.tsx`：Web 会话页（中断 :1820-1825、Composer 挂载 :2180-2241）
- `packages/app/src/pages/session/composer/`：SessionComposerRegion 与 question/permission/todo/revert/followup dock、session-composer-state.ts
- `packages/app/src/components/prompt-input/submit.ts`：Web 提交（sendFollowupDraft、shouldQueue、abort）
- `packages/app/src/context/server-sdk.tsx`、`server-session.ts`：Web 事件读取循环与投影
- `packages/desktop/src/`：Electron 窗口级差异（renderer/index.tsx、main/ipc.ts、main/server.ts、main/index.ts）
