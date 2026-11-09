# Hermes Agent Chat UI 调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（git 仓库）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：直接阅读源码（Electron 主进程、React renderer 状态层与组件、apps/shared 连接层、TUI Ink 前端、后端事件协议），符号按当前快照复核，行号只在核实处给出；界面视觉、焦点与键盘行为标注“未运行验证”
>
> 调查范围：桌面端（Electron + React）聊天工作台的用户工作流与界面状态：页面结构、会话导航、Composer 与草稿、发送前配置、生成反馈与停止、消息操作、多会话与后台生成、UI 状态所有权与桌面集成。会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目。TUI/Web 表面仅记录界面体系边界，未按组件盘点；通用界面盘点（主题、断点、动画、Modal/Toast 全量统计）按 Chat UI 指南的通用过滤规则不纳入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是 Agent 框架，聊天表面有三套：桌面端（Electron + React，本次观察界面）、TUI（Node/Ink）、web dashboard（PTY 嵌入 TUI）。三者复用 Python Agent 核心，规范网关与 legacy tui_gateway 桥分别承担控制协议；桌面端不自带 agent 进程，界面状态全部来自后端 WebSocket JSON-RPC（执行语义见对话请求与上下文笔记 §1）。常规本地连接先调用 `hermes gateway ensure --json`，由网关生命周期层附着或启动规范 owner；桌面只持有端点与 viewer 连接，关闭或切换桌面不拥有终止网关的权力。一个 owner 可服务多个 profile，各 home 的归属仍由运行时发现与锁协调（[实际启动消费](../../hermes-agent/apps/desktop/electron/main.ts#L11887-L11913)、[端点判定](../../hermes-agent/apps/desktop/electron/local-gateway.ts#L219-L254)）。

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

桌面端本地连接链：
- 主连接与 profile 池均经 gateway ensure 返回规范端点；ready 判定、旧 owner 重启和拒绝原因由协议处理。端点描述不含公共 dashboard token，原生连接使用一次性私有 ticket。
- 常规启动没有接入旧的 spawn-ledger attach 回调，也不会独立启动 serve 子 owner；保留的发现模块注释不足以说明当前主路径（[main.ts](../../hermes-agent/apps/desktop/electron/main.ts#L11887-L11913)）。
- SSH、URL 与 Cloud 保留远端连接意图，远端失败不会转为启动本地 owner。legacy serve 的 headless SPA 分支仍是独立路径，需与规范本地网关区分。

桌面连接生命周期：

- 连接层由 `JsonRpcGatewayClient`（`apps/shared/src/json-rpc-gateway.ts`）统一处理两类帧：请求按 `frame.id` 匹配挂起的等待项，事件帧按 `params.type` 分发；请求默认超时 120s（`DEFAULT_REQUEST_TIMEOUT_MS=120_000`）。
- 桌面端子类 `HermesGateway` 对常规请求使用更短超时，唯独 `prompt.submit` 放宽到 30 分钟（`PROMPT_SUBMIT_REQUEST_TIMEOUT_MS=1_800_000`，`apps/desktop/src/api/client.ts:37`）。
- `resolveGatewayWsUrl`（`apps/shared/src/websocket-url.ts`）：OAuth 模式每次拨号重新铸造一次性 ticket。
- 重连（`app/gateway/hooks/use-gateway-boot.ts`）：全抖动指数退避，300ms 基、15s 上限；连续失败 45s 后升级为可恢复错误覆盖层（`RECONNECT_ESCALATE_AFTER_MS=45_000`）；power/online/visibilitychange 触发立即重连。重连成功后丢弃过期 runtime 绑定（`resetTileRuntimeBindings`），再 `refreshSessions` 重新同步。请求层自带按需重连与失败重放（`app/gateway/hooks/use-gateway-request.ts`）。
- 多 profile 场景每个活跃 profile 一条独立二级 socket（`store/gateway.ts` 的 `createSecondary`，每条 socket 都进同一个 `handleGatewayEvent`）。

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
- 侧栏数据按 profile 分片批量拉取：一次请求覆盖 recents、cron、messaging 三个切片，并带旧端点兼容回退；翻页由固定页大小驱动。接口是 `/api/profiles/sessions/sidebar`，实现在 `hermes.ts` 的 `listAllProfileSessions`，翻页常量与动作是 `SIDEBAR_SESSIONS_PAGE_SIZE` 与 `loadMoreSessions`（`app/session/hooks/use-session-list-actions.ts`）。
- 侧栏行用 TanStack `@tanstack/react-virtual` 虚拟化（`apps/desktop/package.json`；`app/chat/sidebar/virtual-session-list.tsx`：行估计 28px、overscan 12、`measureElement` 动态测量），无 Virtuoso（全仓库零命中）。
- **侧栏过滤/排序菜单**（`store/layout.ts` + `store/sidebar-sort.ts`）：状态原子分工如下，全部持久化且可一键重置（`resetSidebarView`，`store/layout.ts`）：
  - `$sidebarGrouping`：按日期/项目/状态分组；
  - `$sidebarOrdering`：按 updated/created/status/tokens/cost 排序；
  - `$sidebarRowMeta`：行尾元数据；
  - 另有状态过滤与 PR/项目/归档过滤。
  排序实现为分组上层的统一排序键（`store/sidebar-sort.ts`，`$sidebarSessionRankIds`；注释说明旧实现把排序键作用在扁平列表上、分组视图下完全失效）。
- **会话状态点**（`store/session-dot-state.ts`）：单一状态来源（working/stalled/unread/draft/needs-input/background/idle），7 状态按优先级解析，状态在 lineage 别名下认领（跨压缩轮转仍正确），并驱动侧栏状态过滤与排序桶（`sessionStatusBucket`）。
- 正文列表不做虚拟化，改用渲染预算与分页控制成本：每屏按成本单位 `RENDER_BUDGET=600` 限流，多窗格分摊同一预算，末尾的活跃部分按 `LIVE_TAIL_PARTS=40` 配合 `content-visibility` 渲染，更早内容由 “Show earlier” 翻页加载（以上见 `components/assistant-ui/thread/list.tsx`）。
- store 侧另有一层转录窗口预算（`TRANSCRIPT_WINDOW_BUDGET=1200` / `TRANSCRIPT_WINDOW_MIN_MESSAGES=30`，`app/chat/transcript-window.ts`）。渲染细节见消息渲染器笔记。
- 路由匹配基于 `_lineage_root_id`（`session.ts` `sessionPinId`），压缩轮转后路由跟随消费新 storedSessionId（见 §8）。
- **HUD 模式**：无边框、透明、置顶的浮动聊天窗，本身是完整的 renderer，渲染 `ChatView` 的 `hud` 变体（源码注释写作 “NOT a puppet window”），带真实 composer，支持会话切换与跨窗口草稿同步（`requestComposerDraftSync('flush')`）。进入 HUD 时主窗隐藏，退出时按 `hudSessionId` 回迁。
  状态与窗口编排在 `store/hud.ts` 与 `store/windows.ts`，窗口行为由 `electron/` 下的主进程模块族承担。
- 多窗口/多 profile：每个活跃 profile 一条独立二级 socket；多窗口并发事件时序未实测（未验证事项）。

## 2. 会话列表、搜索与现场恢复

- 会话列表数据分页接口在会话与消息管理笔记 §5.1；侧栏翻页与虚拟列表的界面呈现见 §1。
- 搜索：搜索的数据实现在会话与消息管理笔记 §5.3（FTS 矩阵、命中前后端标、`context` 字段）。桌面端有 `lib/session-search.ts` 的本地会话过滤；搜索弹窗的界面工作流本次未覆盖（检查范围：未追踪聊天工作台之外的搜索面板组件）。FTS 命中高亮属于消息渲染类目。
- **现场恢复**：重连成功后 `refreshSessions` 重新同步（连接生命周期见上文）；complete 后按需 `hydrateFromStoredSession` 兜底回填，并有 adopted turn 水合分支——接管“已在别处运行”的会话时先水合历史，否则用户消息不显示（`app/session/hooks/use-message-stream/index.ts`）；被压缩轮转的会话跳过回填（`compactedTurnRef`）。
- 每会话真实状态缓存在 `sessionStateByRuntimeIdRef`（`app/session/hooks/use-session-state-cache.ts`），经 `syncSessionStateToView` 发布，切换会话可回到对应现场。
- **pin**：pin 的键取 `session._lineage_root_id ?? session.id`（`session.ts`），压缩轮转后仍然有效。本地用 persistentAtom `$pinnedSessionIds` 存在 localStorage（键 `SIDEBAR_PINNED_STORAGE_KEY`，`store/layout.ts`），同时镜像到后端 `PATCH /api/sessions/{id}`。

  `store/session-pin-sync.ts` 负责双向同步：push 先行为并带围栏，避免旧页回滚覆盖新值；pull 以后端为权威；boot 时重断言全量。
- **草稿标题**（`lib/draft-title.ts`）：未发送草稿按输入内容实时派生标题（`deriveDraftTitle`，客户端实现 `derive_title` 的孪生逻辑：首行、折叠空白、48 字符词边界截断；斜杠命令取其参数），会话创建后由后端命名替换（见会话与消息管理笔记 §2.4 的标题机制）；持久化草稿重启后也带标题（`store/composer.ts`）。

## 3. Composer、草稿、附件与快捷输入

- 发送路径入口是 `submitText`（`app/session/hooks/use-prompt-actions/index.ts`），它转给 `useSubmitPrompt`（同目录 `submit.ts`）做提交前门控：busy 检查按**目标会话**判断，显式目标（tile、队列排空）的会话常在当前屏之外；再校验 storedId / runtimeId 配对（含排空时跨会话泄漏防护-202）与 session 切换 drift；无 runtime 时先路由 resume 或新建后端会话。

  整条提交包在「会话未找到则 resume、busy 则重试」的容错组合里（容错原语 `app/session/hooks/use-prompt-actions/utils.ts`）。
- **草稿按会话持久化**：`store/composer.ts` 负责按会话键存取草稿，仅文本、附件不持久化：
  - 存储：正文按会话键写入 localStorage，键为 `draftKey`（未命名会话用 `__new__`），存储键是 `SESSION_DRAFTS_STORAGE_KEY='hermes:composer-drafts:v3'`，最多保留 `MAX_PERSISTED_DRAFTS=50` 条，写入逻辑见 `persistDrafts`。草稿的进出只有两个通道：`stashSessionDraft` 与 `takeSessionDraft`。
  - 跨窗口：localStorage `storage` 事件触发 `reloadPersistedDrafts` 合并（注释 “Merge, don't clobber”——本地 map 可能持有未持久化的附件）；HUD/主窗交接用 `requestComposerDraftSync('flush'/'reload')` 事件。
  - 压缩轮转：`migrateSessionDraft` 把旧 tip 的草稿迁移到新 tip，不覆盖非空目标。
- 附件拖放捕获：`useFileDropZone`（`app/chat/hooks/use-file-drop-zone.ts`）接住拖入，`partitionDroppedFiles`（`app/chat/hooks/use-composer-actions.ts`）按来源分流：
  - 应用内路径（工作区相对）→ 直接转内联 `@file:`/`@line:` ref 插入文本；
  - OS 拖入（本机绝对路径）→ 附件管线：目录 `@folder:`、图片 `attachImagePath`（base64 缩略图）、文件 `@file:` 相对 ref（各分支见 `app/chat/hooks/use-composer-actions.ts`）。
- 提交注入点（`syncAttachmentsForSubmit` → `uploadComposerAttachment` → 文件 attach 相关 RPC）在对话请求与上下文笔记 §9。
- 附件预览：`attachmentRefs` 字段挂在 `ChatMessage` 上，由 `toChatMessages` 从 `@image:` 行解析回填（`lib/chat-messages/index.ts`）。
- 编辑 composer：`components/assistant-ui/thread/user-message.tsx`——点击进入编辑 composer，发送即“interrupt + rewind”（注释：即使流式进行中也可点击编辑，发送即 revert；执行语义在对话请求与上下文笔记 §7）。
- 斜杠命令面板：桌面端有客户端侧命令编目与派发管线（`lib/desktop-slash-commands.ts`、`app/chat/composer/hooks/use-slash-completions.ts`、`use-prompt-actions/slash.ts` 的 `useSlashCommand`），内置命令本地处理或落后端执行；技能/quick command 经 `slash.exec` → `command.dispatch` 落为普通 prompt。面板组件细节未逐项展开。

## 4. Agent、模型、工具与发送前配置

- 配置作用域是会话级：模型、推理强度与服务档位各有每会话 override 字段（`model_override`、`create_reasoning_override`、`create_service_tier_override`，`methods_session.py`；数据语义在会话与消息管理笔记 §8）。运行中 `/model` 切换以 `model_switch` 时间线条目入史，写入前先剥离旧 marker（`server.py`），且不计入 user 轮计数。
- 桌面端模型选择器与参数面板的组件细节本次未逐一展开（检查范围：`use-model-controls.ts` 等模型切换 hook 存在，UI 装配在消息渲染器/设置类目边界）；可确认的交互是：composer 的模型 pill 选择随 `session.create` 作为每会话 override 上送（`methods_session.py` 注释），新会话不会污染 profile 全局配置。

## 5. 发送、排队、流式反馈与停止

- **发送**：提交走 `submitText` → `useSubmitPrompt`（§3）。`prompt.submit` 的 RPC 等待上限为 1800s（`PROMPT_SUBMIT_REQUEST_TIMEOUT_MS=1_800_000`，`app/session/hooks/use-prompt-actions/submit.ts`）；turn 的完成以流事件为准，RPC ACK 仅表示受理。会话未找到或超时则 resume 后重试一次，busy 时按目标会话重试（容错原语 `app/session/hooks/use-prompt-actions/utils.ts`）。
- **busy 状态**：`$busy` 与 `$awaitingResponse` 两个原子，在 `message.start` 到达时置位（`store/session.ts`、`gateway-event`）。后端返回 `{status: "queued"}` 时由 `use-background-queue-drain.ts` 的排空机制接管，队列横幅等界面提示本次未逐项展开。
- **流式反馈**：delta 经自适应节流队列刷入界面（33ms 起、上限 250ms，机制在对话请求与上下文笔记 §5）；`message.start` → `flushQueuedDeltas`；interim 气泡原位结算防双泡（`app/session/hooks/use-message-stream/index.ts`）。
- **停止**：停止分两步，先在本地定稿再中断后端。`cancelRun` 先把已收到的内容定稿（`finalizeInterruptedMessages`，`app/session/hooks/use-prompt-actions/rewind.ts`），再发 `session.interrupt` RPC；此后本地进入 `interrupted` 状态，迟到的流事件被拒收（中断层级与执行语义见对话请求与上下文笔记 §7）。

  桌面端（`apps/desktop`）没有叫 `interruptResponse` 的符号，该名字只出现在 TUI 的类型 `SessionInterruptResponse`（`ui-tui/src/gatewayTypes.ts`）。
- **完成反馈**：`completeAssistantMessage` 合并终态（机制在对话请求与上下文笔记 §6）→ `scheduleSessionsRefresh` 300ms 合并刷新列表（`use-message-stream/index.ts`）+ `broadcastSessionsChanged` 跨窗口同步标题。

## 6. 消息操作、分支与版本导航

- **编辑**：`components/assistant-ui/thread/user-message.tsx` 进入编辑 composer（§3）；rewind/edit 失败回滚完整历史（`app/session/hooks/use-prompt-actions/index.ts`，rewind 目标取 Ref 防闭包捕获过期目标）。
- **重试/重新生成**：桌面 reload/regenerate（`app/session/hooks/use-prompt-actions/rewind.ts` `planReload`；`use-message-stream/index.ts` 以 `truncateSubmitParams(plan.truncateOrdinal)` 重发）。regen 入口的可用性条件（是否仅末条等）本次未逐项展开。
- **分支（fork）**：live 会话直接调 `session.branch`；源会话已不在 live 时改用 `session.create` 加 `parent_session_id` 与消息种子（`app/session/hooks/use-session-actions/index.ts` 的 `forkBranch`，标题按父会话已有分支数生成）。分支的数据语义（新 session_key、`_branched_from`、`#2` 标题）见会话与消息管理笔记 §4；分支树视图等版本导航控件本次未逐项展开。
- 消息操作栏的组件装配（按钮、状态反馈）属于消息渲染器笔记，本笔记只记录操作触发的工作流。

## 7. 多会话、多模型、群聊与后台生成

- 多 profile：每个活跃 profile 一条独立二级 socket（`store/gateway.ts`），会话切换时各自维护现场（§2）。
- 子代理（subagent）会话在数据层是真实会话（会话与消息管理笔记 §8）；其界面呈现（spawn 树等）在消息渲染器笔记。
- 后台生成：auto-continue 与 async-delegation 路径（`server.py`，机制在对话请求与上下文笔记 §8）；后台任务完成的界面通知本次未逐项展开；cron 投递支持多投递目标（属设置/调度面，聊天工作流未展开）。
- 子代理已有会话级实时控制面。后端只返回属于当前 live session、transport 与 generation 的 roster；选中子代理后可读取最多 16 KiB 的实时转录尾部、发送 steer 或硬中断。结束、外来或代际失效的子代理不再暴露内容。桌面把 roster 放在 Composer 上方的状态栈，TUI 提供 dock 与全高 roster（`tui_gateway/methods_subagents.py`，`apps/desktop/src/app/chat/composer/status-stack/subagent-section.tsx`，`ui-tui/src/components/agentControls.tsx`）。
- 桌面 Composer 支持传统 STT → Hermes → TTS 与 GPT-Live 两种语音引擎。GPT-Live 前端持有麦克风和扬声器，但真实请求仍连同近期文本上下文交给当前 Hermes 会话，由 Hermes 当前模型与工具集执行；不可用时回退 STT（`apps/desktop/src/app/chat/composer/hooks/use-voice-live-conversation.ts`，`apps/desktop/src/lib/voice-live.ts`，`tools/voice_live.py`）。
- 多窗口并发、同窗口多会话并行生成的行为未实测（未验证事项）。

## 8. Chat UI 状态所有权与同步

- **状态原子**都放在 `apps/desktop/src/store/session.ts`：
  - `$sessions`：会话列表；
  - `$messages`：当前视图镜像；
  - `$activeSessionId` 与 `$selectedStoredSessionId`：活动会话的两个 ID；
  - `$activeSessionStoredIdRotation`：压缩轮转后随发布产生的迁移信号；
  - `$busy` 与 `$awaitingResponse`：生成中与等待响应；
  - `$unreadFinishedSessionIds`：未读已完成会话，驱动状态点。

  per-session 真实状态的缓存与发布见 §2 现场恢复。
- **合并而非覆盖**：`mergeSessionPage` 保留 working/pinned/刚 settle 行，按 `_lineage_root_id` 去重防压缩轮转后双行（`session.ts`）；`sessionsToKeep` 定义保留集（`app/session/hooks/use-session-list-actions.ts`）；刷新结果签名门控保持引用同一（完整合并语义与测试用例见会话与消息管理笔记 §6）。
- **先乐观后诚实**：`seedOptimistic` 先把用户气泡插进视图，失败路径回滚并追加错误气泡（`app/session/hooks/use-prompt-actions/submit.ts`）。
- **拒绝乱序回写**：`refreshSessionsRequestRef` 请求代际单调递增、过期响应丢弃（`app/session/hooks/use-session-list-actions.ts`）；视图发布只接受当前 active 会话 + rAF 合并、flush 前再验 sessionId（`app/session/hooks/use-session-state-cache.ts`，实现见会话与消息管理笔记 §6）。
- **压缩轮转的 UI 反馈**：发布时若发现 `storedSessionId` 变化且 runtime 为 active，就发出 `ActiveSessionStoredIdRotation`，路由层消费后清空该信号（`session-states.ts`、`app/session/hooks/use-session-state-cache.ts`、`app/session/hooks/use-session-actions/index.ts`）。

  `status.update` 的 `kind=compacting/compacted` 阶段驱动 `$compactingSessions`，界面据此显示压缩进度（`gateway-event`、`store/compaction.ts`）。
- **草稿状态所有权**：Composer 文本在 `$composerDraft`（`composer.ts`）+ per-session stash（§3）；附件在 `$composerAttachments` 作用域，仅内存不持久化。
- **桌面集成**：HUD 窗口由 Electron 主进程管理（`electron/` 下的主进程模块族；窗口透明、置顶与位置状态见 `hud-state.json`）；全局快捷键、托盘、系统通知的完整清单本次未逐项盘点（静态代码可见 HUD 快照快捷键 `createHudSnapShortcut` 等，行为未运行验证）。

## 9. 键盘、焦点、响应式与关键路径可用性

- 静态代码可确认的输入路径：Composer 是受控文本输入，`prompt.submit` 由提交动作触发（§3）；侧栏为可滚动列表（虚拟化，§1）；HUD 模式有快照快捷键（`electron/` 主进程模块族）。焦点顺序、Tab 遍历、无障碍名称与屏幕阅读器行为**未运行验证**。
- 聊天关键路径（选择会话 → 输入 → 发送 → 停止 → 消息操作）是否可纯键盘完成未验证；TUI 的命令面板、选择器与键盘工作流体系属于 TUI 表面，不在本笔记展开。
- 响应式行为（侧栏抽屉化、断点变化）未运行验证；`apps/desktop/src/sdk/index.ts` 注释提到 rail 折叠断点，实际行为未实测。

## 10. 设计取舍与已确认边界

- **桌面端只做缓存投影**：三原则（合并/乐观/拒绝乱序）是 `apps/desktop/AGENTS.md` 明文契约，桌面端不在本地合成状态（工作台边界）。
- **流式节流用 setTimeout 而非 rAF**：防后台窗口 rAF 挂起（对话请求与上下文笔记 §5）。
- **interim 气泡原位结算**：防“同一回复两页”的重复消息。
- **停止 = 本地定稿 + 后端中断**：迟到事件拒收，保留部分文本（§5）。
- **pin/路由/草稿作用域键在 lineage root**：压缩轮转后仍存活；草稿正文在轮转时随 tip 迁移（§2/§3/§8）。
- **草稿只持久化文本、附件仅内存**：localStorage 上限 50 条、best-effort（quota/隐私模式不打断输入），附件 blob 与上传状态不落盘（§3）。
- **1800s 超时 + resume 后重试一次**：turn 的完成以流事件为准，RPC ACK 仅表示受理（§5）。
- **HUD 是完整 renderer**：真实 composer 与草稿同步，非傀儡窗（§1）。
- **边界**：会话数据语义、列表检索、一致性在会话与消息管理笔记；流式机制、中断层级、队列在对话请求与上下文笔记；操作栏装配、消息渲染在消息渲染器笔记。通用界面盘点（主题、断点、动画、Modal/Toast 全量统计）按 Chat UI 指南的通用过滤规则不纳入。

## 11. 当前多 profile 恢复链

聊天工作台把活动会话的 owner route 保存为 connection + profile，恢复消息页时把同一作用域传入 session API（`apps/desktop/src/app/chat/index.tsx`、`apps/desktop/src/api/sessions.ts`）。后端事件重连依据每会话水位补取缺失帧（`apps/shared/src/json-rpc-gateway.ts`），所以 profile 切换、短断线和同 ID 会话不会共享一份未标注归属的前端缓存。该结论的证据是代码中的数据流与控件绑定；键盘、焦点与断线体验属于运行验证范围。

## 12. 未验证事项

- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 键盘与无障碍（焦点顺序、Tab 遍历、可访问名称）、响应式行为、系统通知未做运行验证。
- 排队提示、模型选择器/参数面板、后台生成（auto-continue/async-delegation）界面反馈、消息搜索弹窗与分支树视图等组件细节与界面工作流未逐项展开。
- GPT-Live 的 WebRTC 服务、打断时序、计费与 STT 回退未运行验证；子代理 roster 的轮询、实时尾部和代际授权也只做了静态核对。

## 13. 关键源码索引

索引按层列出入口。桌面端条目沿用原文路径写法：首条为完整路径，其余相对 `apps/desktop/src/`；右侧是正文提到的符号或用例，语义见对应小节。

```text
apps/desktop/src/hermes.ts            HermesGateway、listAllProfileSessions、sidebar 批量拉取
store/session.ts                      mergeSessionPage、sessionPinId、lineageAliases、
                                      $busy / $awaitingResponse 等状态原子、$unreadFinishedSessionIds
app/session/hooks/use-session-state-cache.ts
app/session/hooks/use-session-list-actions.ts
                                      sessionsToKeep、refreshSessions、loadMoreSessions
app/session/hooks/use-prompt-actions/
  index.ts                            submitText
  submit.ts                           提交参数与超时
  rewind.ts                           finalizeInterruptedMessages、planReload
  utils.ts                            会话未找到 resume、busy 重试原语
app/session/hooks/use-message-stream/index.ts    completeAssistantMessage、
                                                 scheduleSessionsRefresh、hydrate/adopted turn
gateway-event                         compacting 状态
lib/chat-messages/index.ts            ChatMessage、toChatMessages
components/assistant-ui/thread/user-message.tsx  编辑入口
app/chat/hooks/use-file-drop-zone.ts
app/chat/hooks/use-composer-actions.ts           partitionDroppedFiles、attachImagePath
app/chat/sidebar/virtual-session-list.tsx
store/session-pin-sync.ts
store/layout.ts                       pin 存储键、$sidebarGrouping / $sidebarOrdering
store/hud.ts
store/windows.ts
store/sidebar-sort.ts
store/session-dot-state.ts
store/composer.ts                     草稿持久化
lib/draft-title.ts
```

- 共享/连接：`apps/shared/src/json-rpc-gateway.ts`、`apps/shared/src/websocket-url.ts`；`app/gateway/hooks/use-gateway-boot.ts`（重连退避）、`app/gateway/hooks/use-gateway-request.ts`；`store/gateway.ts`。
- Electron：[main.ts](../../hermes-agent/apps/desktop/electron/main.ts#L11887-L11913) 与 [local-gateway.ts](../../hermes-agent/apps/desktop/electron/local-gateway.ts#L219-L254)：规范本地 owner 的附着与端点判定；HUD 窗口模块独立于该连接链。
- 后端边界：`hermes_cli/web_server.py`（`mount_spa` 与 headless 分支）、`hermes_cli/main.py`（`HERMES_SERVE_HEADLESS`）。
- 子代理控制与语音：`tui_gateway/methods_subagents.py`、`apps/desktop/src/app/chat/composer/status-stack/subagent-*.tsx`、`ui-tui/src/components/agentControls.tsx`、`apps/desktop/src/lib/voice-live.ts`、`tools/voice_live.py`。

