# Hermes-Agent Chat UI 调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：从 [`../Chat/Hermes-Agent-Chat调查笔记.md`](../Chat/Hermes-Agent-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据
>
> 调查范围：桌面端（Electron + React）聊天工作台的用户工作流与界面状态：会话导航、Composer、发送与生成反馈、消息操作、UI 状态所有权与桌面集成；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目。TUI/Web 表面仅记录界面体系边界，未按组件盘点；源笔记未覆盖的通用界面盘点（主题、断点、动画等）本次不适用
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是 Agent 框架，聊天表面有三套：桌面端（Electron + React，本次观察界面）、TUI（Node/Ink）、web dashboard（PTY 嵌入 TUI）。三者的后端是同一个 `tui_gateway/server.py` + `AIAgent` 核心；桌面端不运行 agent，而是自 spawn 一个无头 `hermes serve` 后端进程，renderer 通过 WebSocket JSON-RPC 与后端通信。

桌面端的关键工作流特征：

- 桌面端所有会话原子只是后端真相的缓存，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的更新原则，该原则逐条对应 `apps/desktop/AGENTS.md`。
- 发送走 `submitText` → `useSubmitPrompt`：busy 门控、storedId/runtimeId 配对校验、session 切换 drift 守卫、无 runtime 时路由 resume 或先建后端会话，`prompt.submit` 带 1800s 超时。
- 流式反馈经自适应节流队列（33ms 起、上限 250ms）刷入界面，complete 后合并终态、interim 气泡原位结算防双泡，并触发会话列表 300ms 合并刷新。
- 停止是“本地定稿 + 后端中断”：`cancelRun` 先 `finalizeInterruptedMessages` 再调 `session.interrupt` RPC，迟到流事件被拒收，保留部分文本。
- pin、路由匹配、草稿作用域都键在跨压缩轮转稳定的 `_lineage_root_id` 上。
- 本次调查未覆盖桌面端的键盘与无障碍细节、通知与排队提示界面（源笔记未含相关内容，标注为未调查）。

## 工作台边界与用户主链

三界面一核心：

| 界面 | 进程模型 | 与后端传输 |
|---|---|---|
| 桌面端 Electron | renderer 进程 → WebSocket → 后端 | JSON-RPC over WS（`apps/desktop/src/hermes.ts` + `apps/shared`） |
| TUI（`hermes --tui`，Node/Ink） | Node 前端进程 → stdio → 后端 | 换行分隔 JSON-RPC over stdio |
| gateway / CLI | 同进程 | 直接调用 |

桌面端 spawn 参数为 `['serve','--host','127.0.0.1','--port','0']`（`electron/backend-command.ts:18-22`）；`backendSupportsServe()` 先读 `dashboard.py` 源码探测、失败再 `serve --help` 探针（`electron/main.ts:1893-1948`），旧 runtime 回退为 `dashboard --no-open`（`main.ts:1953-1955`）。`HERMES_SERVE_HEADLESS=1` 由 headless 分支设置（`hermes_cli/main.py:10402-10405`），`mount_spa()` 据此只挂 JSON-RPC/WS/API 面（`hermes_cli/web_server.py:16054`）。

桌面连接生命周期：

- `JsonRpcGatewayClient`（`apps/shared/src/json-rpc-gateway.ts:72-429`）：请求按 `frame.id` 匹配 pending Map，默认超时 120s；事件帧按 `params.type` 分发。`HermesGateway` 子类把超时改为 30s（`hermes.ts:229-239`）。
- `resolveGatewayWsUrl`（`websocket-url.ts:39-94`）：OAuth 模式每次拨号重新铸造一次性 ticket。
- 重连（`use-gateway-boot.ts`）：全抖动指数退避，300ms 基、15s 上限；连续失败 45s 后升级为可恢复错误覆盖层；power/online/visibilitychange 触发立即重连。重连成功后丢弃过期 runtime id（`resetTileRuntimeBindings`），再 `refreshSessions` 重新同步。请求层自带按需重连与失败重放（`use-gateway-request.ts:48-145`）。
- 多 profile 场景每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41`）。

用户主链：

```text
打开/恢复会话（基于 _lineage_root_id 的路由匹配）
  -> 侧栏会话列表（分 profile 分片翻页、pin 置顶）
  -> Composer 组织输入（文本、@file:/@line: 引用、拖放附件）
  -> submitText 发送（busy 门控、无 runtime 时先 resume/create 后端会话）
  -> 流式反馈（33-250ms 节流刷帧、interim 原位结算）
  -> 停止（cancelRun 本地定稿 + session.interrupt）或等待 complete 合并
  -> 消息操作（编辑=interrupt+rewind、reload/regenerate、fork）
  -> 压缩轮转时路由跟随新 storedSessionId、pin 经 lineage root 存活
  -> 重连后 refreshSessions 重新同步现场
```

边界：会话与消息数据语义属于会话与消息管理（`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`）；生成任务的真实执行、流式事件机制、中断层级属于对话请求与上下文（`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`）；消息内容、操作栏组件装配与列表渲染属于消息渲染器（`../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md`）。

## 1. 页面结构、导航与多窗口

- 桌面端是标准 GUI 工作台：侧栏（会话列表 + pin）+ 正文（transcript）。侧栏走 `/api/profiles/sessions/sidebar` 分 profile 分片（`hermes.ts:427-640` 的 `listAllProfileSessions`/批量 `sidebar` 请求，含 `recents/cron/messaging` 三切片与旧端点兼容回退），`SIDEBAR_SESSIONS_PAGE_SIZE` + `loadMoreSessions` 翻页（`use-session-list-actions.ts:264`）；侧栏行用 TanStack `@tanstack/react-virtual` 虚拟化（`package.json:90`；`virtual-session-list.tsx:66-78`，行估计 28px、overscan 12、动态测量），无 Virtuoso（全仓库零命中）。
- **侧栏过滤/排序菜单**（`store/layout.ts:316-350` + `store/sidebar-sort.ts`）：`$sidebarGrouping`（按日期/项目/状态分组）、`$sidebarOrdering`（updated/created/status/tokens/cost 排序）、`$sidebarRowMeta`（行尾元数据：tokens/cost/PR/profile/时间戳）、状态过滤（working/unread/stalled/draft/needs-input/background）与 PR/项目/归档过滤；全部持久化且可一键重置。排序实现为分组上层的统一排序键（`sidebar-sort.ts` 注释明示"旧实现把排序键作用在扁平列表上，分组视图下完全失效"）。`cost`/`tokens` 量级排序时丢弃日期分隔线。
- **会话状态点**（`store/session-dot-state.ts`）：单一状态来源（working/stalled/unread/draft/needs-input/background/idle），7 状态按优先级解析，状态在 lineage 别名下认领（跨压缩轮转仍正确），并驱动侧栏状态过滤与排序桶。
- 正文列表无 virtualizer：`RENDER_BUDGET=600` 成本单位（由 300 上调，且改为 store/paint 双轨定价、多窗格分摊预算） + “Show earlier” 翻页 + `content-visibility` 活跃尾部（`LIVE_TAIL_PARTS=40`）；渲染预算与 `content-visibility` 的实现细节见消息渲染器笔记 §3/§9。
- 路由匹配基于 `_lineage_root_id`（`session.ts:246` `sessionPinId`），压缩轮转后路由跟随消费新 storedSessionId（见 §8）。
- **HUD 模式**（`store/hud.ts` + `store/windows.ts` + `electron/main.ts`）：无边框、透明、置顶的浮动聊天窗，是**完整 renderer 而非傀儡窗**——渲染 `ChatView` 的 `hud` 变体，使用真实 composer（附件/斜杠命令/队列/语音/模型 pill 全部可用），支持会话切换与跨窗口草稿同步（`requestComposerDraftSync`）；标题栏开关与快捷键进入（`store/hud.ts:1-40`，注释明确"不是 pet overlay / quick entry 那种傀儡窗"）。
- 多窗口/多 profile：每个活跃 profile 一条独立二级 socket；多窗口并发事件时序未实测（未验证事项）。

## 2. 会话列表、搜索与现场恢复

- 会话列表数据分页接口在会话与消息管理笔记 §5.1；侧栏翻页与虚拟列表的界面呈现见 §1。
- 搜索：搜索的数据实现在会话与消息管理笔记 §5.3（FTS 三索引矩阵、命中前后端标 40 字符、`context` 字段）。桌面端搜索入口与命中跳转的界面工作流本次调查未覆盖（源笔记未含相关内容，标注为未调查）；FTS 命中高亮属于消息渲染类，见消息渲染器笔记边界说明。
- **现场恢复**：重连成功后 `refreshSessions` 重新同步（连接生命周期见上文）；complete 后按需 `hydrateFromStoredSession` 兜底回填，并增加 adopted turn 水合分支（接管"已在别处运行"的会话时先水合历史，否则用户消息不显示，`use-message-stream/index.ts:656-676`）；被压缩轮转的会话跳过回填。每会话真实状态缓存在 `sessionStateByRuntimeIdRef`（`use-session-state-cache.ts:84`），经 `syncSessionStateToView` 发布（:210-267），切换会话可回到对应现场。
- **pin**：`sessionPinId = session._lineage_root_id ?? session.id`（`session.ts:246`，压缩轮转后 pin 仍存活），持久化到 localStorage（`layout.ts:75` 附近），后端镜像 `PATCH /api/sessions/{id}`，`session-pin-sync.ts` 双向同步（push 先行带围栏防旧页回滚，pull 以后端为权威，boot 时重断言全量）。pin 的几个显示/排序缺陷已修复：pin 行不再被"Show earlier"分页切走、pin 行只显示一次且保持拖拽顺序、pin 排序在分组视图下生效（`layout-pinned-order.ts`、`sidebar-sort.ts`）。
- **草稿标题**（`lib/draft-title.ts`）：未发送草稿按输入内容实时派生标题（`deriveDraftTitle`，客户端实现 `derive_title` 的孪生逻辑：首行、折叠空白、48 字符词边界截断；斜杠命令取其参数），会话创建后由后端命名替换（见会话与消息管理笔记 §3 的标题机制）。

## 3. Composer、草稿、附件与快捷输入

- 发送路径入口：`submitText`（`use-prompt-actions/index.ts:587`）→ `useSubmitPrompt`（`submit.ts:97-753`）：`sanitizeComposerInput`、busy 门控（`:165-172`，`isTargetSessionBusy` 按**目标会话**的 busy 判断——显式目标（tile/队列排空）通常不是当前屏上会话）、storedId/runtimeId 配对校验（含排空时跨会话泄漏防护 `isBackgroundQueueDrain`，`:184-216`）、session 切换 drift 守卫、无 runtime 时路由 resume 或 `createBackendSessionForSend`；提交调用在 `withSessionNotFoundResume(withSessionBusyRetry(...))` 组合内（`submit.ts:645-650`，容错原语在 `utils.ts:146,244`）。
- **草稿跨窗口**（`store/composer.ts`）：composer 草稿 stash 支持窗口间迁移（HUD 与主窗、popout 之间的草稿同步，`requestComposerDraftSync('flush')`），HUD 打开前先把半成品文本推入共享 stash 再建窗。
- 附件拖放捕获：`useFileDropZone`（`chat/hooks/use-file-drop-zone.ts:33-146`）；`partitionDroppedFiles` 分流（`use-composer-actions.ts:240-256`）——应用内路径（工作区相对）直接转内联 `@file:`/`@line:` ref 插入文本，OS 拖入（本机绝对路径）走附件管线：目录 → `@folder:`、图片 → `attachImagePath`（base64 缩略图，:404-435）、文件 → `@file:` 相对 ref（:382-402）。提交注入点（`syncAttachmentsForSubmit` → `uploadComposerAttachment` → `file.attach`/`image.attach_bytes` RPC）在对话请求与上下文笔记 §9。
- 附件预览：`attachmentRefs` 挂在 `ChatMessage` 上（`chat-messages.ts:13-32`），`toChatMessages` 从 `@image:` 行提取回 attachmentRefs（:912-1099）。
- 编辑 composer：`user-message.tsx:326-356`——点击进入编辑 composer，发送即“interrupt + rewind”（执行语义在对话请求与上下文笔记 §7）。
- 草稿：源笔记未发现独立的草稿保存机制（本次未找到；`ChatMessage.pending` 只覆盖发送前的乐观气泡）；已有**草稿标题**与**跨窗口草稿迁移**（§2/§3），但草稿正文本身仍不持久化。

## 4. Agent、模型、工具与发送前配置

- 配置作用域是会话级：`model_override`/`create_reasoning_override` 为每会话字段（数据语义在会话与消息管理笔记 §8）；运行中 `/model` 切换以 `model_switch` 时间线条目入史（`server.py:3970-4031`，`_append_model_switch_marker` 先剥离旧 marker），不计入 user 轮计数。
- 桌面端模型/参数选择的界面入口（模型选择器、参数面板等）本次调查未覆盖（源笔记未含相关内容，标注为未调查）。

## 5. 发送、排队、流式反馈与停止

- **发送**：`submitText` → `useSubmitPrompt`（§3）；`prompt.submit` 带 1800s 超时（`submit.ts:650` `PROMPT_SUBMIT_REQUEST_TIMEOUT_MS=1_800_000`，turn 完成靠流事件而非 RPC ACK）；`session not found`/超时 → resume 后重试一次、busy 时按目标会话重试（`withSessionBusyRetry`/`withSessionNotFoundResume`，`utils.ts:146,244`）。
- **busy 状态**：`$busy`/`$awaitingResponse`（`store/session.ts:548` 附近）；`message.start` → busy 置位（`gateway-event.ts`）。排队：后端返回 `{status: "queued"}` 时桌面端排空机制走 `use-background-queue-drain`，排队提示界面本次调查未覆盖（源笔记未含相关内容，标注为未调查）。
- **流式反馈**：delta 经自适应节流队列刷入界面（33ms 起、上限 250ms，机制在对话请求与上下文笔记 §5）；`message.start` → `flushQueuedDeltas`；interim 气泡原位结算防双泡（`index.ts:603-654`）。
- **停止**：桌面端没有 `interruptResponse`（全仓库 grep 零命中）：`cancelRun` 先在本地定稿（`finalizeInterruptedMessages`，`rewind.ts:122`）再调 `session.interrupt` RPC；此后本地 `interrupted` 状态使迟到流事件拒收，complete 的 interrupted 分支只清 busy 保留部分文本。服务端中断层级在对话请求与上下文笔记 §7。
- **完成反馈**：`completeAssistantMessage` 合并终态（机制在对话请求与上下文笔记 §6）→ `scheduleSessionsRefresh` 300ms 合并刷新列表（`index.ts:151-173, 686`）。

## 6. 消息操作、分支与版本导航

- **编辑**：`user-message.tsx:326-356` 进入编辑 composer（§3）；rewind/edit 失败回滚完整历史（`use-prompt-actions/index.ts:878-909`，rewind 目标取 Ref 防闭包捕获过期目标）。
- **重试/重新生成**：桌面 reload/regenerate（`rewind.ts:140` `planReload`）；regen 入口的可用性条件（是否仅末条等）本次调查未覆盖。
- **分支（fork）**：live 会话用 `session.branch`，无 live 源时 `session.create` + `parent_session_id` + messages 种子（`use-session-actions/index.ts:1178` `forkBranch`，按 parent 已有分支数生成标题）；分支数据语义（新 session_key、`_branched_from`、标题 `#2`）在会话与消息管理笔记 §4。版本导航的界面控件本次调查未覆盖。
- 消息操作栏的组件装配（按钮、状态反馈）属于消息渲染器笔记（操作栏/状态反馈一节），本笔记只记录操作触发的工作流。

## 7. 多会话、多模型、群聊与后台生成

- 多 profile：每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41`），会话切换时各自维护现场（§2）。
- 子代理（subagent）会话在数据层是真实会话（会话与消息管理笔记 §8）；其界面呈现（spawn 树等）在消息渲染器笔记。
- 后台生成：auto-continue 与 async-delegation 路径（`server.py`）；后台任务的界面通知本次调查未覆盖（标注为未调查）；cron 投递支持**多投递目标**（`67927808`，桌面端给投递目标组以可访问名称），属设置/调度面，聊天工作流未展开。
- 多窗口并发、同窗口多会话并行生成的行为未实测（未验证事项）。

## 8. Chat UI 状态所有权与同步

- **状态原子**（`apps/desktop/src/store/session.ts`）：`$sessions`（:481）、`$messages`（:537，当前视图镜像）、`$activeSessionId`/`$selectedStoredSessionId`（:523-524）、`$activeSessionStoredIdRotation`（:536）、`$busy`/`$awaitingResponse`（:548-549），以及 `$unreadFinishedSessionIds`（:643，未读已完成会话，驱动状态点）。per-session 真实状态在 `sessionStateByRuntimeIdRef`（`use-session-state-cache.ts:84`），经 `syncSessionStateToView` 发布（:210-267）。
- **合并而非覆盖**：`mergeSessionPage` 保留 working/pinned/刚 settle 行，按 `_lineage_root_id` 去重防压缩轮转后双行（`session.ts:393`）；`sessionsToKeep` 定义保留集（`use-session-list-actions.ts:58`）；刷新结果签名门控保持引用同一（:209-213）。
- **先乐观后诚实**：`seedOptimistic` 先插用户气泡（`submit.ts` 乐观附件/气泡段）、失败路径回滚并追加错误气泡。
- **拒绝乱序回写**：`refreshSessionsRequestRef` 请求代际单调递增、过期响应丢弃（`use-session-list-actions.ts:151-152, 190`）；视图发布只接受当前 active 会话 + rAF 合并、flush 前再验 sessionId（`use-session-state-cache.ts:210` 附近）。
- **压缩轮转的 UI 反馈**：`ActiveSessionStoredIdRotation` 在发布时发现 storedSessionId 变化且 runtime 为 active 才发（`session-states.ts:142-150`；`use-session-state-cache.ts:113-122` 双通道），路由跟随消费后清空；`status.update kind=compacting/compacted` 驱动 `$compactingSessions`（`gateway-event.ts:1164-1166`，`store/compaction.ts`）。
- **桌面集成**：全局快捷键、托盘、系统通知等桌面集成细节源笔记未覆盖（标注为未调查）；窗口显示/隐藏与渲染进程的联动本次不适用（Electron 主进程代码在 `electron/main.ts`，仅 spawn/探针逻辑被本次调查读取）。

## 9. 键盘、焦点、响应式与关键路径可用性

- 本次调查未覆盖桌面端键盘快捷键体系、焦点顺序、无障碍与响应式行为（源笔记未含相关内容，标注为未调查）；TUI 的命令面板、选择器与键盘工作流体系见消息渲染器笔记（TUI 渲染链）与源笔记边界说明，不在本笔记展开。
- 流式期间的状态反馈（busy 置位、interim 结算）已在 §5 记录；视觉效果与焦点行为需运行验证（未验证事项）。

## 10. 设计取舍与已确认边界

- **桌面端是缓存投影而非真相源**：三原则（合并/乐观/拒绝乱序）是 `apps/desktop/AGENTS.md` 明文契约，桌面端不做本地合成（工作台边界）。
- **流式节流用 setTimeout 而非 rAF**：防后台窗口 rAF 挂起（对话请求与上下文笔记 §5）。
- **interim 气泡原位结算**：防“同一回复两页”的重复消息。
- **停止 = 本地定稿 + 后端中断**：迟到事件三处拒收，保留部分文本（§5）。
- **pin/路由/草稿作用域键在 lineage root**：压缩轮转后仍存活（§2）。
- **1800s 超时 + resume 后重试一次**：turn 完成靠流事件而非 RPC ACK（§5）。
- **边界**：会话数据语义、列表检索、一致性在会话与消息管理笔记；流式机制、中断层级、队列在对话请求与上下文笔记；操作栏装配、消息渲染在消息渲染器笔记。通用界面盘点（主题、断点、动画、弹窗/Toast 盘点）源笔记未成节，本次不适用。

## 11. 未验证事项

- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 键盘与无障碍、响应式行为、系统通知未调查（源笔记未覆盖）。
- 排队提示、模型选择器等发送前配置界面未调查（源笔记未覆盖）。
- 后台生成（auto-continue/async-delegation）的界面反馈未调查。

## 12. 关键源码索引

- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :229、`listSidebarSessions`/sidebar 批量 :455-640）；`store/session.ts`（mergeSessionPage :393、sessionPinId :246、lineageAliases :307、状态原子 :481-549、`$unreadFinishedSessionIds` :643）；`use-session-state-cache.ts`（:84、:210）；`use-session-list-actions.ts`（sessionsToKeep :58、refreshSessions :150、loadMoreSessions :264）；`use-prompt-actions/index.ts`（submitText :587、rewind/edit :878-909）、`submit.ts`（:97）、`rewind.ts`（finalizeInterruptedMessages :122、planReload :140）、`utils.ts`（withSessionNotFoundResume :146、withSessionBusyRetry :244）；`use-message-stream/index.ts`（hydrateFromStoredSession/adoptedRunningTurn :656-676）、`gateway-event.ts`（compacting :1164-1166）；`lib/chat-messages.ts`（ChatMessage :13）；`chat/user-message.tsx`（编辑入口 :326-356）；`chat/hooks/use-file-drop-zone.ts`（:33-146）；`use-composer-actions.ts`（:240-256）；`virtual-session-list.tsx`（:66-78）；`session-pin-sync.ts`；`layout.ts`（:75 附近、`$sidebarGrouping`/`$sidebarOrdering` :316-350）；以及 `store/hud.ts`、`store/windows.ts`、`store/sidebar-sort.ts`、`store/session-dot-state.ts`、`lib/draft-title.ts`、`store/composer.ts`（跨窗口草稿 stash）。
- 共享/连接：`apps/shared/src/json-rpc-gateway.ts`（:72-429）、`websocket-url.ts`（:39-94）；`use-gateway-boot.ts`（重连）；`use-gateway-request.ts`（:48-145）；`store/gateway.ts`（:30-41）。
- Electron：`electron/backend-command.ts`（:18-22）、`electron/main.ts`（探针 :1893-1955、HUD 窗口）。
- 后端边界：`hermes_cli/web_server.py`（`mount_spa` :16296，`HERMES_SERVE_HEADLESS` 分支 :16313）、`hermes_cli/main.py`（:10474）。
