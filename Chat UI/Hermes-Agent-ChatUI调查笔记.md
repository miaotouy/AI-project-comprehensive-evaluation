# Hermes Agent Chat UI 调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：直接阅读源码（Electron 主进程、React renderer 状态层与组件、apps/shared 连接层、TUI Ink 前端、后端事件协议），符号与行号在 HEAD 快照处逐一核对；界面视觉、焦点与键盘行为标注“未运行验证”
>
> 调查范围：桌面端（Electron + React）聊天工作台的用户工作流与界面状态：页面结构、会话导航、Composer 与草稿、发送前配置、生成反馈与停止、消息操作、多会话与后台生成、UI 状态所有权与桌面集成。会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目。TUI/Web 表面仅记录界面体系边界，未按组件盘点；通用界面盘点（主题、断点、动画、Modal/Toast 全量统计）按 Chat UI 指南的通用过滤规则不纳入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是 Agent 框架，聊天表面有三套：桌面端（Electron + React，本次观察界面）、TUI（Node/Ink）、web dashboard（PTY 嵌入 TUI）。三者的后端是同一个 `tui_gateway/server.py` + `AIAgent` 核心；桌面端不自带 agent 进程，界面状态全部来自后端 WebSocket JSON-RPC（执行语义见对话请求与上下文笔记 §1）。

桌面端的关键工作流特征：

- 桌面端界面状态是后端真相的缓存投影，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的更新原则（UI 侧合并语义见 §8，数据事实源见会话与消息管理笔记 §2/§6）。
- 发送走 `submitText` → `useSubmitPrompt`：busy 门控、storedId/runtimeId 配对校验、session 切换 drift 守卫、无 runtime 时路由 resume 或先建后端会话，`prompt.submit` 带 1800s 超时。
- 流式反馈经自适应节流队列（33ms 起、上限 250ms）刷入界面，complete 后合并终态、interim 气泡原位结算防双泡，并触发会话列表 300ms 合并刷新。
- 停止是“本地定稿 + 后端中断”：`cancelRun` 先 `finalizeInterruptedMessages` 再调 `session.interrupt` RPC，迟到流事件被拒收，保留部分文本。
- pin、路由匹配、草稿作用域都键在跨压缩轮转稳定的 `_lineage_root_id` 上。
- **草稿按会话持久化**：Composer 正文按会话键存入 localStorage（上限 50 条，仅文本），跨窗口经 storage 事件同步，压缩轮转时随 tip 迁移（§3）。
- 键盘与无障碍、响应式细节、系统通知未做运行验证，静态代码能确认的部分见 §9。

## 工作台边界与用户主链

三界面一核心：

| 界面 | 进程模型 | 与后端传输 |
|---|---|---|
| 桌面端 Electron | renderer 进程 → WebSocket → 后端 | JSON-RPC over WS（`apps/desktop/src/hermes.ts` + `apps/shared`） |
| TUI（`hermes --tui`，Node/Ink） | Node 前端进程 → stdio → 后端 | 换行分隔 JSON-RPC over stdio |
| gateway / CLI | 同进程 | 直接调用 |

桌面端后端进程的启动参数与 serve 探测链：
- spawn 参数为 `['serve','--host','127.0.0.1','--port','0']`（`electron/backend-command.ts:18-22`）。
- `backendSupportsServe()`（`electron/main.ts:1935-1990`）探测后端是否支持 `serve`：先读 `hermes_cli/subcommands/dashboard.py` 确认 `add_parser("serve")` 存在，失败再 `serve --help` 探针，结果按 runtime 缓存；旧 runtime 回退为 `dashboard --no-open`（`getBackendArgsForRuntime`），探测与回退逻辑见 `electron/main.ts:1948-1997`。
- headless 分支设置 `HERMES_SERVE_HEADLESS=1`（`hermes_cli/main.py:10471-10474`），`mount_spa()` 据此只挂 JSON-RPC/WS/API 面（`hermes_cli/web_server.py:16296`，headless 分支 :16313）。

桌面连接生命周期：

- `JsonRpcGatewayClient`（`apps/shared/src/json-rpc-gateway.ts:66-74`）统一处理请求与事件帧：请求按 `frame.id` 匹配挂起的等待项，默认超时 120s（`DEFAULT_REQUEST_TIMEOUT_MS=120_000`）；事件帧按 `params.type` 分发。`HermesGateway` 子类把超时收紧到 30s（`hermes.ts:230-239`）。
- `resolveGatewayWsUrl`（`websocket-url.ts:39` 起）：OAuth 模式每次拨号重新铸造一次性 ticket（`:12` 注释）。
- 重连（`use-gateway-boot.ts:56,226,432-446`）：全抖动指数退避，300ms 基、15s 上限；连续失败 45s 后升级为可恢复错误覆盖层（`RECONNECT_ESCALATE_AFTER_MS=45_000`）；power/online/visibilitychange 触发立即重连。重连成功后丢弃过期 runtime 绑定（`resetTileRuntimeBindings`，:190），再 `refreshSessions` 重新同步。请求层自带按需重连与失败重放（`use-gateway-request.ts`）。
- 多 profile 场景每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41`，`createSecondary` `:219`，每条 socket 都进同一个 `handleGatewayEvent`）。

用户主链：

```text
打开/恢复会话（基于 _lineage_root_id 的路由匹配）
  -> 侧栏会话列表（分 profile 分片翻页、pin 置顶）
  -> Composer 组织输入（文本、@file:/@line: 引用、拖放附件、草稿按会话持久化）
  -> submitText 发送（busy 门控、无 runtime 时先 resume/create 后端会话）
  -> 流式反馈（33-250ms 节流刷帧、interim 原位结算）
  -> 停止（cancelRun 本地定稿 + session.interrupt）或等待 complete 合并
  -> 消息操作（编辑=interrupt+rewind、reload/regenerate、fork）
  -> 压缩轮转时路由跟随新 storedSessionId、pin 经 lineage root 存活、草稿随 tip 迁移
  -> 重连后 refreshSessions 重新同步现场
```

边界：会话与消息数据语义属于会话与消息管理（`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`）；生成任务的真实执行、流式事件机制、中断层级属于对话请求与上下文（`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`）；消息内容、操作栏组件装配与列表渲染属于消息渲染器类目。

## 1. 页面结构、导航与多窗口

- 桌面端是标准 GUI 工作台：侧栏（会话列表 + pin）+ 正文（transcript）。
- 侧栏数据走 `/api/profiles/sessions/sidebar` 分 profile 分片批量拉取（`hermes.ts:427,455-640`，`listAllProfileSessions`，含 recents/cron/messaging 三切片与旧端点兼容回退），翻页由 `SIDEBAR_SESSIONS_PAGE_SIZE` + `loadMoreSessions` 完成（`use-session-list-actions.ts:264`）。
- 侧栏行用 TanStack `@tanstack/react-virtual` 虚拟化（`package.json:97`；`virtual-session-list.tsx:46-78`：行估计 28px、overscan 12、`measureElement` 动态测量），无 Virtuoso（全仓库零命中）。
- **侧栏过滤/排序菜单**（`store/layout.ts:316-323` + `store/sidebar-sort.ts`）：状态原子分工如下，全部持久化且可一键重置（`resetSidebarView`，`layout.ts:617`）：
  - `$sidebarGrouping`：按日期/项目/状态分组；
  - `$sidebarOrdering`：按 updated/created/status/tokens/cost 排序；
  - `$sidebarRowMeta`：行尾元数据；
  - 另有状态过滤与 PR/项目/归档过滤。
  排序实现为分组上层的统一排序键（`sidebar-sort.ts:40-51`，`$sidebarSessionRankIds`；注释说明旧实现把排序键作用在扁平列表上、分组视图下完全失效）。
- **会话状态点**（`store/session-dot-state.ts:28`）：单一状态来源（working/stalled/unread/draft/needs-input/background/idle），7 状态按优先级解析，状态在 lineage 别名下认领（跨压缩轮转仍正确，`:75-104`），并驱动侧栏状态过滤与排序桶（`sessionStatusBucket` `:44`）。
- 正文列表无 virtualizer，用渲染预算与分页控制成本：`RENDER_BUDGET=600` 成本单位、多窗格分摊预算、`LIVE_TAIL_PARTS=40` 的 `content-visibility` 活跃尾部与 “Show earlier” 翻页（以上见 `components/assistant-ui/thread/list.tsx:66,209,358`）；另有一层 store 侧转录窗口预算（`TRANSCRIPT_WINDOW_BUDGET=1200`/`TRANSCRIPT_WINDOW_MIN_MESSAGES=30`，`app/chat/transcript-window.ts:29-36`）。渲染细节见消息渲染器笔记。
- 路由匹配基于 `_lineage_root_id`（`session.ts:246-247` `sessionPinId`），压缩轮转后路由跟随消费新 storedSessionId（见 §8）。
- **HUD 模式**（`store/hud.ts` + `store/windows.ts` + `electron/main.ts:8973` 起）：无边框、透明、置顶的浮动聊天窗，是**完整 renderer 而非傀儡窗**——渲染 `ChatView` 的 `hud` 变体（注释明确 “NOT a puppet window”），使用真实 composer，支持会话切换与跨窗口草稿同步（`requestComposerDraftSync('flush')`，`hud.ts:8,56`）；进入 HUD 时主窗隐藏、退出时按 `hudSessionId` 回迁（`main.ts:8983-9001, 9217-9317`）。
- 多窗口/多 profile：每个活跃 profile 一条独立二级 socket；多窗口并发事件时序未实测（未验证事项）。

## 2. 会话列表、搜索与现场恢复

- 会话列表数据分页接口在会话与消息管理笔记 §5.1；侧栏翻页与虚拟列表的界面呈现见 §1。
- 搜索：搜索的数据实现在会话与消息管理笔记 §5.3（FTS 矩阵、命中前后端标、`context` 字段）。桌面端有 `lib/session-search.ts` 的本地会话过滤；搜索弹窗的界面工作流本次未覆盖（检查范围：未追踪聊天工作台之外的搜索面板组件）。FTS 命中高亮属于消息渲染类目。
- **现场恢复**：重连成功后 `refreshSessions` 重新同步（连接生命周期见上文）；complete 后按需 `hydrateFromStoredSession` 兜底回填，并有 adopted turn 水合分支——接管“已在别处运行”的会话时先水合历史，否则用户消息不显示（`use-message-stream/index.ts:695-712`）；被压缩轮转的会话跳过回填（`compactedTurnRef`）。
- 每会话真实状态缓存在 `sessionStateByRuntimeIdRef`（`use-session-state-cache.ts:84`），经 `syncSessionStateToView` 发布（:210-267），切换会话可回到对应现场。
- **pin**：以 `session._lineage_root_id ?? session.id` 为 pin 依据（`session.ts:246-247`，压缩轮转后仍存活），本地持久化在 localStorage（`layout.ts:30,91`，键 `SIDEBAR_PINNED_STORAGE_KEY`，`$pinnedSessionIds` 为 persistentAtom），后端镜像 `PATCH /api/sessions/{id}`；`session-pin-sync.ts`（:10-21,136-177）双向同步——push 先行带围栏防旧页回滚，pull 以后端为权威，boot 时重断言全量。
- **草稿标题**（`lib/draft-title.ts:5-18`）：未发送草稿按输入内容实时派生标题（`deriveDraftTitle`，客户端实现 `derive_title` 的孪生逻辑：首行、折叠空白、48 字符词边界截断；斜杠命令取其参数），会话创建后由后端命名替换（见会话与消息管理笔记 §2.4 的标题机制）；持久化草稿重启后也带标题（`store/composer.ts:155-172`）。

## 3. Composer、草稿、附件与快捷输入

- 发送路径入口：`submitText`（`use-prompt-actions/index.ts:587`）→ `useSubmitPrompt`（`submit.ts`）在提交前做一组门控——busy 检查（按**目标会话**判断，显式目标如 tile/队列排空通常不是当前屏上会话，:169 附近）、storedId/runtimeId 配对校验（含排空时跨会话泄漏防护，:198-202）、session 切换 drift 守卫，无 runtime 时先路由 resume 或新建后端会话；提交整体包在“会话未找到则 resume、busy 则重试”的容错组合里（:645-650，容错原语 `utils.ts:146,244`）。
- **草稿按会话持久化（本次核实修正）**：`store/composer.ts` 负责按会话键存取草稿，仅文本、附件不持久化：
  - 存储：正文按会话键（`draftKey`，未命名会话用 `__new__`，:129）写入 localStorage（键 `SESSION_DRAFTS_STORAGE_KEY='hermes:composer-drafts:v3'`，上限 `MAX_PERSISTED_DRAFTS=50`，写入逻辑 :279-294）；`stashSessionDraft`/`takeSessionDraft`（:296/:310）是唯一进出通道。
  - 跨窗口：localStorage `storage` 事件触发 `reloadPersistedDrafts` 合并（:211-237，注释 “Merge, don't clobber”——本地 map 可能持有未持久化的附件）；HUD/主窗交接用 `requestComposerDraftSync('flush'/'reload')` 事件（:240-266）。
  - 压缩轮转：`migrateSessionDraft` 把旧 tip 的草稿迁移到新 tip（:327-349），不覆盖非空目标。
- 附件拖放捕获：`useFileDropZone`（`chat/hooks/use-file-drop-zone.ts:33` 起）接住拖入，`partitionDroppedFiles`（`use-composer-actions.ts:240` 起）按来源分流：
  - 应用内路径（工作区相对）→ 直接转内联 `@file:`/`@line:` ref 插入文本；
  - OS 拖入（本机绝对路径）→ 附件管线：目录 `@folder:`、图片 `attachImagePath`（base64 缩略图）、文件 `@file:` 相对 ref（各分支见 `use-composer-actions.ts:395-533`）。
- 提交注入点（`syncAttachmentsForSubmit` → `uploadComposerAttachment` → 文件 attach 相关 RPC）在对话请求与上下文笔记 §9。
- 附件预览：`attachmentRefs` 挂在 `ChatMessage` 上（`chat-messages.ts:13-32`），`toChatMessages` 从 `@image:` 行提取回该字段（`chat-messages.ts:922,1005-1009`）。
- 编辑 composer：`user-message.tsx:326-355`——点击进入编辑 composer，发送即“interrupt + rewind”（注释：即使流式进行中也可点击编辑，发送即 revert；执行语义在对话请求与上下文笔记 §7）。
- 斜杠命令面板：桌面端有客户端侧命令编目与派发管线（`lib/desktop-slash-commands.ts`、`app/chat/composer/hooks/use-slash-completions.ts`、`use-prompt-actions/slash.ts` 的 `useSlashCommand` :155），内置命令本地处理或落后端执行；技能/quick command 经 `slash.exec` → `command.dispatch` 落为普通 prompt。面板组件细节未逐项展开。

## 4. Agent、模型、工具与发送前配置

- 配置作用域是会话级：`model_override`/`create_reasoning_override`/`create_service_tier_override` 是每会话字段（`methods_session.py:50-71,96-98`，数据语义在会话与消息管理笔记 §8）；运行中 `/model` 切换以 `model_switch` 时间线条目入史（`server.py:3970`，先剥离旧 marker 再追加），不计入 user 轮计数。
- 桌面端模型选择器与参数面板的组件细节本次未逐一展开（检查范围：`use-model-controls.ts` 等模型切换 hook 存在，UI 装配在消息渲染器/设置类目边界）；可确认的交互是：composer 的模型 pill 选择随 `session.create` 作为每会话 override 上送（`methods_session.py:45-49` 注释），新会话不会污染 profile 全局配置。

## 5. 发送、排队、流式反馈与停止

- **发送**：`submitText` → `useSubmitPrompt`（§3）；`prompt.submit` 带 1800s 超时（`submit.ts:650`，`PROMPT_SUBMIT_REQUEST_TIMEOUT_MS=1_800_000`），turn 完成靠流事件而非 RPC ACK；会话未找到或超时则 resume 后重试一次、busy 时按目标会话重试（容错原语 `utils.ts:146,244`）。
- **busy 状态**：`$busy`/`$awaitingResponse`（`store/session.ts:548-549`）；`message.start` → busy 置位（`gateway-event.ts`）。排队：后端返回 `{status: "queued"}` 时桌面端排空机制走 `use-background-queue-drain.ts`，其界面提示（队列横幅等）本次未逐项展开。
- **流式反馈**：delta 经自适应节流队列刷入界面（33ms 起、上限 250ms，机制在对话请求与上下文笔记 §5）；`message.start` → `flushQueuedDeltas`；interim 气泡原位结算防双泡（`use-message-stream/index.ts:506-530, 615-640`）。
- **停止**：桌面端（apps/desktop）没有名为 `interruptResponse` 的符号（该名字只在 TUI 侧作为 `SessionInterruptResponse` 类型存在，`ui-tui/src/gatewayTypes.ts:313`）：`cancelRun` 先在本地定稿（`finalizeInterruptedMessages`，`rewind.ts:122`）再调 `session.interrupt` RPC；此后本地 `interrupted` 状态使迟到流事件拒收（中断层级与执行语义见对话请求与上下文笔记 §7）。
- **完成反馈**：`completeAssistantMessage` 合并终态（机制在对话请求与上下文笔记 §6）→ `scheduleSessionsRefresh` 300ms 合并刷新列表（`index.ts:153-173`）+ `broadcastSessionsChanged` 跨窗口同步标题（`:163`）。

## 6. 消息操作、分支与版本导航

- **编辑**：`user-message.tsx:326-355` 进入编辑 composer（§3）；rewind/edit 失败回滚完整历史（`use-prompt-actions/index.ts:877-948`，rewind 目标取 Ref 防闭包捕获过期目标）。
- **重试/重新生成**：桌面 reload/regenerate（`rewind.ts:140` `planReload`；`index.ts:797-814` 以 `truncateSubmitParams(plan.truncateOrdinal)` 重发）。regen 入口的可用性条件（是否仅末条等）本次未逐项展开。
- **分支（fork）**：live 会话用 `session.branch`，无 live 源时 `session.create` + `parent_session_id` + messages 种子（`use-session-actions/index.ts:1178` `forkBranch`，按 parent 已有分支数生成标题 `:1229`）；分支数据语义（新 session_key、`_branched_from`、标题 `#2`）在会话与消息管理笔记 §4。版本导航的界面控件（分支树视图）本次未逐项展开。
- 消息操作栏的组件装配（按钮、状态反馈）属于消息渲染器笔记，本笔记只记录操作触发的工作流。

## 7. 多会话、多模型、群聊与后台生成

- 多 profile：每个活跃 profile 一条独立二级 socket（`store/gateway.ts:30-41`），会话切换时各自维护现场（§2）。
- 子代理（subagent）会话在数据层是真实会话（会话与消息管理笔记 §8）；其界面呈现（spawn 树等）在消息渲染器笔记。
- 后台生成：auto-continue 与 async-delegation 路径（`server.py`，机制在对话请求与上下文笔记 §8）；后台任务完成的界面通知本次未逐项展开；cron 投递支持多投递目标（属设置/调度面，聊天工作流未展开）。
- 多窗口并发、同窗口多会话并行生成的行为未实测（未验证事项）。

## 8. Chat UI 状态所有权与同步

- **状态原子**（`apps/desktop/src/store/session.ts`）：`$sessions`（:481）、`$messages`（:537，当前视图镜像）、`$activeSessionId`/`$selectedStoredSessionId`（:523-524）、`$activeSessionStoredIdRotation`（:536）、`$busy`/`$awaitingResponse`（:548-549），以及 `$unreadFinishedSessionIds`（:643，未读已完成会话，驱动状态点）。per-session 真实状态的缓存与发布见 §2 现场恢复。
- **合并而非覆盖**：`mergeSessionPage` 保留 working/pinned/刚 settle 行，按 `_lineage_root_id` 去重防压缩轮转后双行（`session.ts:393`）；`sessionsToKeep` 定义保留集（`use-session-list-actions.ts:58`）；刷新结果签名门控保持引用同一（完整合并语义与测试用例见会话与消息管理笔记 §6）。
- **先乐观后诚实**：`seedOptimistic` 先插用户气泡（`submit.ts:340` 起）、失败路径回滚并追加错误气泡。
- **拒绝乱序回写**：`refreshSessionsRequestRef` 请求代际单调递增、过期响应丢弃（`use-session-list-actions.ts:86, 151-152, 190`）；视图发布只接受当前 active 会话 + rAF 合并、flush 前再验 sessionId（`use-session-state-cache.ts:210-267`，实现见会话与消息管理笔记 §6）。
- **压缩轮转的 UI 反馈**：`ActiveSessionStoredIdRotation` 在发布时发现 storedSessionId 变化且 runtime 为 active 才发（`session-states.ts:142-150`；`use-session-state-cache.ts:121-127`），路由跟随消费后清空（`use-session-actions/index.ts:222-237`）；`status.update kind=compacting/compacted` 驱动 `$compactingSessions`（`gateway-event.ts:1165-1170`，`store/compaction.ts:8`）。
- **草稿状态所有权**：Composer 文本在 `$composerDraft`（`composer.ts:21`）+ per-session stash（§3）；附件在 `$composerAttachments` 作用域（`:22, 113`），附件仅内存不持久化。
- **桌面集成**：HUD 窗口由 Electron 主进程管理（`main.ts:8973` 起，透明/置顶/记住位置 `hud-state.json`）；全局快捷键、托盘、系统通知的完整清单本次未逐项盘点（静态代码可见 HUD 快照快捷键 `createHudSnapShortcut` 等，行为未运行验证）。

## 9. 键盘、焦点、响应式与关键路径可用性

- 静态代码可确认的输入路径：Composer 是受控文本输入，`prompt.submit` 由提交动作触发（§3）；侧栏为可滚动列表（虚拟化，§1）；HUD 模式有快照快捷键（`electron/main.ts:9058-9094`）。焦点顺序、Tab 遍历、无障碍名称与屏幕阅读器行为**未运行验证**。
- 聊天关键路径（选择会话 → 输入 → 发送 → 停止 → 消息操作）是否可纯键盘完成未验证；TUI 的命令面板、选择器与键盘工作流体系属于 TUI 表面，不在本笔记展开。
- 响应式行为（侧栏抽屉化、断点变化）未运行验证；`apps/desktop/src/sdk/index.ts:40` 注释提到 rail 折叠断点，实际行为未实测。

## 10. 设计取舍与已确认边界

- **桌面端是缓存投影而非真相源**：三原则（合并/乐观/拒绝乱序）是 `apps/desktop/AGENTS.md` 明文契约，桌面端不做本地合成（工作台边界）。
- **流式节流用 setTimeout 而非 rAF**：防后台窗口 rAF 挂起（对话请求与上下文笔记 §5）。
- **interim 气泡原位结算**：防“同一回复两页”的重复消息。
- **停止 = 本地定稿 + 后端中断**：迟到事件拒收，保留部分文本（§5）。
- **pin/路由/草稿作用域键在 lineage root**：压缩轮转后仍存活；草稿正文在轮转时随 tip 迁移（§2/§3/§8）。
- **草稿只持久化文本、附件仅内存**：localStorage 上限 50 条、best-effort（quota/隐私模式不打断输入），附件 blob 与上传状态不落盘（§3）。
- **1800s 超时 + resume 后重试一次**：turn 完成靠流事件而非 RPC ACK（§5）。
- **HUD 是完整 renderer**：真实 composer 与草稿同步，非傀儡窗（§1）。
- **边界**：会话数据语义、列表检索、一致性在会话与消息管理笔记；流式机制、中断层级、队列在对话请求与上下文笔记；操作栏装配、消息渲染在消息渲染器笔记。通用界面盘点（主题、断点、动画、Modal/Toast 全量统计）按 Chat UI 指南的通用过滤规则不纳入。

## 11. 未验证事项

- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 键盘与无障碍（焦点顺序、Tab 遍历、可访问名称）、响应式行为、系统通知未做运行验证。
- 排队提示、模型选择器/参数面板等发送前配置界面的组件细节未逐项展开。
- 后台生成（auto-continue/async-delegation）的界面反馈未逐项展开。
- 消息搜索弹窗与分支树视图的界面工作流未逐项展开。

## 12. 关键源码索引

- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :230、`listAllProfileSessions` :427、sidebar 批量 :455-640）；`store/session.ts`（mergeSessionPage :393、sessionPinId :246、lineageAliases :307、状态原子 :481-549、`$unreadFinishedSessionIds` :643）；`use-session-state-cache.ts`（:84、:210）；`use-session-list-actions.ts`（sessionsToKeep :58、refreshSessions :150、loadMoreSessions :264）；`use-prompt-actions/index.ts`（submitText :587、rewind/edit 回滚 :877-948）、`submit.ts`（submitParams :619、超时 :650）、`rewind.ts`（finalizeInterruptedMessages :122、planReload :140）、`utils.ts`（withSessionNotFoundResume :146、withSessionBusyRetry :244）；`use-message-stream/index.ts`（completeAssistantMessage :538、scheduleSessionsRefresh :153、hydrate/adoptedRunningTurn :695-712）、`gateway-event.ts`（compacting :1165-1170）；`lib/chat-messages.ts`（ChatMessage :13、toChatMessages :922）；`chat/user-message.tsx`（编辑入口 :326-355）；`chat/hooks/use-file-drop-zone.ts`（:33）；`use-composer-actions.ts`（partitionDroppedFiles :240、attachImagePath :404）；`virtual-session-list.tsx`（:46-47、:67-78）；`session-pin-sync.ts`；`layout.ts`（pin 存储键 :30/:91、`$sidebarGrouping`/`$sidebarOrdering` :316-323）；以及 `store/hud.ts`、`store/windows.ts`、`store/sidebar-sort.ts`、`store/session-dot-state.ts`、`store/composer.ts`（草稿持久化 :118-349）、`lib/draft-title.ts`。
- 共享/连接：`apps/shared/src/json-rpc-gateway.ts`（:66-72）、`websocket-url.ts`（:39）；`use-gateway-boot.ts`（重连 :56/:226）；`use-gateway-request.ts`；`store/gateway.ts`（:30-41）。
- Electron：`electron/backend-command.ts`（:18-22）、`electron/main.ts`（backendSupportsServe :1935-1990、HUD 窗口 :8973 起）。
- 后端边界：`hermes_cli/web_server.py`（`mount_spa` :16296、headless 分支 :16313）、`hermes_cli/main.py`（HERMES_SERVE_HEADLESS :10471-10474）。
