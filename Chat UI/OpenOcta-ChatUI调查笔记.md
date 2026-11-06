# OpenOcta Chat UI 调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：只读源码静态梳理；阅读 `ui/src/ui` 下的壳层、聊天视图、控制器、会话运行态、事件路由与审批组件，界面行为按事件绑定与状态流转确认，未运行桌面应用
>
> 调查范围：桌面 Control UI 的「消息」聊天表面与 AgentSwarm 协作表面：工作台结构、会话导航与恢复、Composer 与草稿、发送前配置、发送/排队/流式/停止、消息操作入口、多会话与多 Agent、状态所有权、键盘与响应式；会话数据语义、任务执行与落盘分别留给相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的聊天表面是一个「任务会话工作台」，区别于 IM 式群聊：左侧会话侧栏、中间 Agent 线程、底部 Composer，全部由 Lit 3 Web Components 在单一壳层内拼装。前端实际技术栈是 Lit + `marked` + DOMPurify + A2UI 组件库，源码里仍保留上游 `openclaw` 命名（元素名 `openclaw-app`、包名 `openclaw-control-ui`），但产品面已按 IT Ops 任务改造：会话快捷指令来自场景模板、每次发送可提交本次 Skill/MCP 选择、会话可从历史里「提炼 Skill」、另有面向多 Agent 协作的 AgentSwarm 房间表面。

关键实现事实：

- **状态宿主单一**：`openclaw-app`（`ui/src/ui/app.ts` 的 `OpenClawApp`）持有全部聊天 `@state`；消息线程与输入框被拆成两个独立自定义元素，避免每次按键重绘整页。
- **运行态按会话分桶**：`ui/src/ui/chat/chat-session-runs.ts` 用模块级 `Map` 保存每个会话的 runId、阶段、流式文本与终止 run 集合，切换会话时保存/恢复，因此 A 会话生成中切到 B 再切回仍显示进行中。
- **服务端事件是事实源**：WebSocket 上的聊天事件与 Agent 事件驱动状态，run 结束后再用历史接口全量对齐；停止另发中止请求。
- **排队在客户端**：同会话正在生成时，新消息只进内存数组 `chatQueue`，等当前 run 结束事件到达后再补发。
- **审批不在消息流里**：执行审批以全局浮层（`exec.approval.requested`）出现，另有与聊天无关的顶栏提示条和 sandbox 页审批表，两套入口用不同 RPC。
- **A2UI 是独有的交互形态**：Agent 可返回结构化 UI surface，用户点击按钮会以 `chat.a2ui.action` 发起新一轮 run，面板在 `final` 后仍并入历史。
- **草稿不落盘**：输入文本只存在于输入组件的局部状态，向上只同步一个「是否有内容」布尔值；切换会话即清空。

## 工作台边界与用户主链

```text
进入「消息」页（tab=message）
  -> 左侧会话侧栏：搜索 / 新建 / 选择 / 置顶 / 重命名 / 分享链接 / 删除
  -> 主区线程：历史消息 + 实时流 + 工具调用 + 推理过程
  -> 底部 Composer：文本、@本机 Agent、附件、模型选择、全部资源（Skill/MCP）、提炼 Skill
  -> 发送（空闲则直发；生成中则入队）
  -> 观察：思考/调用工具/生成回复三阶段提示 + 可折叠工具卡 + 压缩上下文提示
  -> 控制：停止（同一按钮位替换「新会话」）、队列移除
  -> 审批：执行审批从全局浮层或顶栏提示进入 sandbox 页
  -> 离开/切回：URL 带 ?session=，运行态按会话恢复
```

边界：消息如何被解析成可见内容见 [`../消息渲染器/OpenOcta-消息渲染器调查笔记.md`](../消息渲染器/OpenOcta-消息渲染器调查笔记.md)；会话 CRUD、`sessions.list`/`chat.history` 的数据语义属于会话与消息管理；`chat.send` 之后的模型循环、工具执行与落盘属于对话请求与上下文。

## 1. 页面结构、导航与多窗口

壳层是三段式：顶栏、左侧导航栏、主内容区。顶栏固定九个产品入口——消息、定时任务、员工市场、技能库、知识库、工具库、模型、教程、配置（`ui/src/ui/app-render.ts:700-728`）。聊天只在标签为 `message`（消息页）或 `chat`（旧版聊天页）时渲染；后者是兼容旧链接的别名，带会话键时会被改写成消息页（`ui/src/ui/app-settings.ts:159-163`）。

「消息」页对壳层做了三处改写：

- 左侧导航整块替换为会话侧栏 `session-sidebar`，含搜索框、「新消息」按钮和会话列表（`app-render.ts:889-1135`）；侧栏可整体折叠，折叠状态存在设置里（`navCollapsed`）。
- 主区不渲染通用页头，因此页头里的聊天工具条（刷新、专注模式）在消息页不出现（`app-render.ts:1229-1260`、`app-render.helpers.ts:40-116`）。聊天表面只消费其中的专注模式回调，`onRefresh` 传入后没有对应控件；专注模式的退出按钮改由聊天表面自己提供（`views/chat.ts:988-1002`）。
- 主区成为 `chat` 分区，内部再分 `chat-split-container`（线程 + 可拉开的 Markdown 侧栏）与 `chat-compose`（`views/chat.ts:1004-1250`）。

聊天表面自身没有多标签或多窗口形态：桌面运行时只暴露最小化、最大化、退出等窗口能力（`app.ts:118-129`），会话切换靠侧栏与 URL 完成。AgentSwarm 是另一条独立入口（`tab=agentSwarm`），不嵌在消息页里。

AgentSwarm 表面是房间式协作工作台：左侧房间列表、上方成员树与关系图、中间成员对话与流式气泡、右侧面板（`ui/src/ui/views/agent-swarm.ts:561-`），与消息页共用同一 WebSocket 连接但使用另一组 RPC（`swarm.*`）。

## 2. 会话列表、搜索与现场恢复

侧栏数据来自会话列表接口 `sessions.list`。聊天上下文加载时一次拉取最多 5000 条带末条预览的会话，再补拉历史与头像（`ui/src/ui/app-chat.ts:318-332`）。列表行按置顶与更新时间排序，标题优先取员工名、自定义会话标签与来源渠道，其次才是派生标题和预览（`session-sidebar.ts:38-93`）。

搜索是纯客户端过滤：把会话行、标题、副标题拼成 haystack 后按子串匹配（`app-render.ts:963-986`），没有跨会话的消息内容检索入口，也没有服务端搜索 RPC；本次在 `ui/src/ui` 内未找到其它会话搜索入口。

会话操作集中在行尾溢出菜单：重命名、置顶/取消置顶、分享链接、删除（`app-render.ts:248-341`）。删除当前会话后会切到列表首项并重载历史。侧栏没有归档、分组或未读概念，唯一的分组线索是「数字员工会话」用员工名与首字头像区分（`app-render.ts:1041-1045`）。

现场恢复有三个层次：

- 当前会话键同时写进本地设置与 URL 的 `session` 查询参数；刷新时 URL 优先，其次回退到设置里记录的上次会话（`ui/src/ui/app-settings.ts:104-156`、`486-496`、`ui/src/ui/storage.ts:9-45`）。
- 历史消息一次取最近 500 条（`controllers/chat.ts:246`、`266-287`），超过上限时线程顶部插一条「仅显示最近 N 条」的系统提示（`ui/src/ui/chat/chat-items.ts:95-106`）。没有向上翻页或加载更早历史的入口。
- 若当前会话键已不在 `sessions.list`（被删除或归档），聊天刷新会把界面切到可用会话并提示（`app-chat.ts:48-104`）；员工会话、cron 单次会话与主会话被显式排除在误判之外。

## 3. Composer、草稿、附件与快捷输入

输入框是独立元素 `openocta-chat-input`，自带局部草稿状态，注释即说明目的是让按键不触发整页重渲染（`ui/src/ui/components/openocta-chat-input.ts:35-42`）。键盘约定：Enter 发送、Shift+Enter 换行、输入法组合态（`isComposing` 或 keyCode 229）不发送（`openocta-chat-input.ts:267-281`）。

`@` 提及只服务本机 CLI Agent：在光标前匹配 `@` 后的标识串，弹出可键盘上下选择的列表，选中后替换为别名形式。触发、候选与选中替换的完整逻辑在 `openocta-chat-input.ts:139-265`，候选项来源见 `app-render.ts:2745`。

草稿粒度为「单个输入组件实例」：

- 上层通过 `clearToken` 递增清空、`insertToken` 追加片段，而不是双向绑定文本（`openocta-chat-input.ts:62-97`）。
- 上层只镜像 `hasText` 布尔值用于启用发送按钮（`views/chat.ts:871-872`、`openocta-chat-input.ts:170-178`）。
- `ChatProps.draft` 与 `onDraftChange` 仍然存在，但聊天视图没有把 `draft` 传入输入框，也没有调用 `onDraftChange`；`state.chatMessage` 实际保持空串。
- 因此切换会话（`prepareChatSessionSwitch` 置空草稿、附件、模型与资源）后再回来，本次未找到任何文本草稿恢复路径（`app-chat.ts:115-126`）。

附件限制是单文件：图片与常见文档 5MB、视频 50MB，压缩包与可执行文件按扩展名和 MIME 双拦截，白名单以扩展名收口（`views/chat.ts:130-300`）。选择文件或粘贴图片都会读成 data URL 暂存（`views/chat.ts:378-476`），发送时图片转 base64 内容块，视频与文档降级成一行文字标记（`controllers/chat.ts:329-361`）。

空会话的引导由两层组成：场景模板的快捷指令（最多 5 条，未配置场景时用默认三条，`ui/src/ui/scenario-templates.ts:46-73`、`136-146`）与分类建议卡片组件 `openocta-chat-suggestions`（`views/chat.ts:897-926`）。点击建议默认填进输入框而不是直接发送。

Composer 底部还有三个 IT Ops 取向的入口：附件、全部资源（Skill/MCP）、提炼 SKILL。最后一项以 `chat.extractSkill` 请求网关把当前会话提炼成技能文件，结果在模态里预览，下载由前端用 Blob 完成（`views/chat.ts:1202-1221`、`controllers/chat-extract-skill.ts:15-52`）。

## 4. Agent、模型、工具与发送前配置

模型选择是 Composer 内的下拉框，选项由配置快照合并 `agents.defaults.models` 与 `models.providers` 得到，首项固定为「默认」并显示默认模型名；未选择时请求里的模型字段留空（`app-render.ts:2585-2641`、`controllers/chat.ts:422-435`）。选择结果只存在 `state.chatModelRef`，不写入会话配置，切换会话即重置。

「全部资源」弹层是发送前最关键的配置面，作用域是「本次发送」：

- 未显式配置时默认全部 Skill/MCP 可用，联网搜索默认开启（`ui/src/ui/chat/chat-resources.ts:3-16`、`views/chat.ts:610-612`）。
- 弹层可按技能键与 MCP 服务名选择、搜索和分组；前端把选择作为本次资源声明提交。后端会重新补入部分全局 MCP，技能也由目录再次扫描，因此该 UI 选择不能独立保证最终能力集合（`views/chat.ts:577-759`、`src/pkg/gateway/handlers/chat_runtime_pool.go:55-77`）。
- 该对象随 `chat.send` 的 `resources` 字段一起发出（`chat-resources.ts:18-25`、`controllers/chat.ts:432-434`），不构成会话级持久设置。

推理过程是否显示由两个条件同时决定：设置项 `chatShowThinking`（默认开启）与当前会话行的推理等级未关闭（`views/chat.ts:861-862`、`app-render.ts:557`）。本次在 UI 内未找到修改推理等级或该设置项的控件：聊天工具条里的思考开关变量只被声明、未参与渲染，样式表中对应的切换按钮类名也没有任何标记使用（`app-render.helpers.ts:40-116`、`ui/src/styles/chat/layout.css:24-67`）。

参数级配置（温度、最大步数等）不在聊天界面里，本次未找到对应控件；它们由配置页与 Agent 默认值决定。

## 5. 发送、排队、流式反馈与停止

发送入口 `handleSendChat` 先做三类文本命令识别，再决定直发还是排队（`ui/src/ui/app-chat.ts:261-316`）：

| 输入 | 行为 |
|---|---|
| `stop`/`esc`/`abort`/`wait`/`exit`/`/stop` | 转为中止当前 run（`app-chat.ts:128-144`、`282-285`） |
| `/new`、`/reset`（含带参） | 发送后刷新会话列表（`app-chat.ts:146-156`、`287`） |
| 其它 `/` 或 `!` 开头 | 视为系统命令，不携带附件（`app-chat.ts:270-274`） |

直发路径先乐观插入一条 user 消息，生成本地 runId 兼作幂等键，把阶段置为思考中，再发出 `chat.send`。若同会话仍在生成，新消息只进内存队列，界面显示队列条并可逐条移除，消息页上移除需二次确认；发送与入队判断见 `app-chat.ts:303-306`，请求组装见 `controllers/chat.ts:363-435`，队列条渲染见 `views/chat.ts:1030-1070`。

聊天事件用 state 字段区分七种情况（含 A2UI），处理逻辑集中在 `handleChatEvent`（`controllers/chat.ts:232-243`、`495-621`）：

- `delta`：文本与推理分片累加到 `chatStream` / `chatReasoningStream`，并对旧网关的「整段快照」做前缀兼容判断。
- `turn`：把该轮消息压入历史，清空流式文本与 A2UI，阶段切到 `tool`。
- `final`：把 final 消息（并合并仍挂起的 A2UI）替换成最后一条，然后清空运行态。
- `aborted` / `complete`：清空运行态；`error` 记下出错 runId 并等历史重载。
- `a2ui`：结构化 UI 分片先进入专用数组；run 已终止时改为并入末条助手消息，避免 `final` 与它竞争后丢失。
- 已终止的 run 会进 `chatTerminalRunIds`（保留 24 个），迟到的 delta 被丢弃（`controllers/chat.ts:63-81`、`539-547`）。

界面上的阶段文案与形态是：无流式文本时显示带光球动效和三点动画的活动行，按思考、调用工具、生成回复三个阶段显示对应文案，有推理文本时同屏展开「推理过程」折叠面板（`ui/src/ui/chat/grouped-render.ts:249-329`）。上下文压缩另有独立提示条，开始显示 Compacting，结束显示成功并 5 秒后自动消失（`views/chat.ts:328-355`、`ui/src/ui/app-tool-stream.ts:179-207`）。

停止入口与「新会话」共用同一个按钮位：可中止时显示「停止」，否则显示「新会话」（`views/chat.ts:1223-1247`）。点击后以会话键和 runId 发出 `chat.abort`，并先本地清空以避免事件迟到导致界面卡在进行中（`controllers/chat.ts:472-493`）。没有全局快捷键触发停止，只能点按钮或在输入框发送 `stop` 类文本。

发送失败会追加错误助手消息，run 级错误依赖历史重载。重连握手清空当前宿主字段里的 run、阶段和流式文本，但没有清空按会话保存的运行态映射。后台会话若错过终态，切回时仍可能恢复旧快照；因此重连只对当前字段做局部清理，跨会话孤儿状态的完整清理链本次未找到（`ui/src/ui/app-gateway.ts:165-180`、`ui/src/ui/chat/chat-session-runs.ts:35-59,149-157`）。

## 6. 消息操作、审批与返回路径

消息级操作很少，且集中在助手气泡与工具卡内部：

| 操作 | 入口 | 边界 |
|---|---|---|
| 复制 Markdown | 助手气泡右上角按钮，仅当有可见正文 | 失败与成功各有 1.5–2 秒文案回退（`ui/src/ui/chat/copy-as-markdown.ts:4-115`） |
| 展开工具输入/输出 | 工具卡与「已运行命令」折叠区 | 流式时默认展开，失败项自动展开（`grouped-render.ts:1029-1070`） |
| 查看完整工具输出 | 工具卡点击/回车 → 右侧 Markdown 侧栏 | 打开侧栏承载排版后的输出（`views/chat.ts:1009-1027`） |
| 预览/下载附件 | 文件块与图片的预览、下载按钮 | 图片新窗口打开，文件用模态预览（`grouped-render.ts:570-610`） |
| 提交 A2UI 交互 | 面板内按钮 → 新 run | 提交前移除同 surface 的旧块（`controllers/chat.ts:181-228`） |

本次在 `ui/src/ui/chat`、`ui/src/ui/views/chat.ts` 与 `controllers/chat.ts` 内未找到消息编辑、删除、重新生成、续写、分支或版本切换入口。

审批是独立通道，不在消息流里渲染：

- 执行审批：`exec.approval.requested` 事件带命令、宿主、Agent、会话、工作目录、安全策略等字段，进入全局队列并设置到期清理定时器（`app-gateway.ts:326-344`、`controllers/exec-approval.ts:30-63`）。界面是覆盖全屏的模态卡片，只显示队首一条与待处理条数，提供「允许一次 / 始终允许 / 拒绝」，动作走 `exec.approval.resolve`（`views/exec-approval.ts:25-88`）。
- 顶栏提示条：每 3 秒轮询 `approvals.list`，只在出现新增待审批 id 时弹出「有 N 条敏感命令待人工审批」，可跳到 sandbox 页或关闭（`ui/src/ui/app-approvals-banner.ts:8-66`、`app-render.ts:658-687`）。
- sandbox 页审批表：显示命令、状态、到期时间与 TTL，动作是「批准一次 / 会话免审 / 拒绝」，走 `approvals.approve|deny|whitelistSession` 三个 RPC，并提供跳回对应会话的链接（`views/approvals.ts:63-144`）。该页实际由 `views/security.ts` 装配（`app-render.ts:2454-2483`），仓库里另有未被引用的 `views/sandbox.ts`。

## 7. 多会话、多 Agent 与后台生成

多会话的关键是运行态分桶而非「全局 busy 标记」。`chat-session-runs.ts` 为每个会话保存 runId、阶段、流式文本、推理文本、A2UI 消息与终止集合；切换会话时先持久化当前会话，再恢复目标会话（`chat-session-runs.ts:109-158`）。非当前会话的事件不会丢弃，而是走 `applyBackgroundChatEvent` 更新该会话快照（`chat-session-runs.ts:219-301`，入口 `controllers/chat.ts:499-502`）。

这一设计带来的可观察行为是：在 A 会话生成中切到 B，A 的流式文本与阶段照常累积；切回 A 时界面直接显示仍在生成的现场。批量刷新与队列补发也按会话判断（`app-chat.ts:239-255`）。界面上没有「哪些会话正在运行」的总览列表，侧栏行也不显示运行标记；本次在 `app-render.ts` 的会话行模板与 `session-sidebar.ts` 内未找到运行态标记。

后台与子 Agent 的独立表面是 AgentSwarm：

- 房间由 `swarm.workspaces.create` 创建，成员按父子关系组成树与图，删除房间会连带删除成员、蜂群历史及关联聊天会话（`controllers/swarm.ts:94-141`、`views/agent-swarm.ts:450-472`）。
- 发送是 `swarm.message.send`，流式由 `swarm.task.delta` 事件按成员与 stream 类型分发（assistant / reasoning / tool_call / tool_result），只更新当前选中成员（`controllers/swarm.ts:206-228`、`241-317`、`app-gateway.ts:360-386`）。
- 停止是整房间级的 `swarm.workspaces.abortAll`，没有单成员停止入口（`controllers/swarm.ts:75-92`）。

本机 CLI Agent 是第三种协作对象，但只在 Composer 里以 `@别名` 文本形式出现，由后端解释，不构成独立会话或独立状态面板。

## 8. Chat UI 状态所有权

| 状态 | 事实源 | 生命周期 | 落盘 |
|---|---|---|---|
| 当前会话键 | `state.sessionKey` | 切换时重设 | `localStorage` + URL `?session=` |
| 消息历史 | `state.chatMessages` | `chat.history` 重载 / `turn`、`final` 追加 | 服务端 |
| 流式文本与阶段 | `state.chatStream` 等，镜像到 `chat-session-runs` | 每会话一份，跨切换保留 | 不落盘 |
| 输入文本 | `openocta-chat-input` 局部状态 | 发送或 `clearToken` 时清空 | 不落盘 |
| 是否有输入 | `state.chatComposeHasText` | 每次输入同步 | 不落盘 |
| 队列 | `state.chatQueue` | run 结束补发、可手动移除 | 不落盘 |
| 模型选择 | `state.chatModelRef` | 切换会话时重置 | 不落盘 |
| 资源限定 | `state.chatResources` | 切换会话时回默认 | 不落盘 |
| 审批队列 | `state.execApprovalQueue` | 事件驱动 + 到期清理 | 服务端 |
| 滚动位置 | `chatUserNearBottom` 等实例字段 | 会话切换重置 | 不落盘 |

因此「刷新页面」能恢复的是会话、历史与设置项；流式现场、队列、草稿与本次资源限定都会丢失。多窗口之间也没有同步层：每个窗口独立连网关、独立投影事件，本次未找到跨窗口的草稿或运行态广播。

## 9. 键盘、焦点与响应式

- Enter 发送、Shift+Enter 换行、输入法保护；`@` 列表内 Up/Down 移动、Enter/Tab 选中、Esc 关闭（`openocta-chat-input.ts:240-281`）。
- 会话行是 `role=button` 且可聚焦，Enter 触发切换；双击进入改名，Esc 退出（`app-render.ts:1005-1039`、`1059-1061`）。
- Esc 在全局只处理两件事：关闭原生对话框、关闭会话溢出菜单（`app.ts:754-769`），不会中止生成。
- 活动行、队列条与审批卡都带实时区域语义，分别用礼貌播报、状态角色和对话框角色表述（`grouped-render.ts:287-292`、`views/chat.ts:1033`、`views/exec-approval.ts:35`）。
- 消息线程本身声明为日志区并关闭实时播报，避免流式过程中逐字朗读（`components/openocta-chat-thread.ts:56-63`）。
- 响应式只在样式层：聊天布局在 900px、640px 处降级，工具卡结果区在 768px 处铺满（`ui/src/styles/chat/layout.css:1023-1230`、`sidebar.css:132-141`）；侧栏在窄屏下不自动变抽屉，仅整体折叠。
- 专注模式隐藏侧栏与页头，由设置项 `chatFocusMode` 或引导流程决定，退出按钮在聊天表面右上角（`app-render.ts:556`、`views/chat.ts:988-1002`）。

焦点顺序、屏幕阅读器实际播报与触屏可用性未运行验证。

## 10. 设计取舍与已确认边界

- **单一状态宿主 + 两个隔离元素**：消息线程与输入框都是独立自定义元素，用属性与自定义事件交互，目的是把高频输入与长列表渲染解耦（`views/chat.ts:928-952`、`1094-1109`）。
- **运行态本地分桶，不依赖服务端会话状态**：界面判断「是否在生成」只看本地 runId 与终止集合，服务端并不下发统一的会话状态字段（`chat-session-runs.ts:160-180`）。断线重连只清当前宿主运行字段，后台会话快照仍可能保留；没有 journal 重放恢复。
- **排队、草稿、资源限定都不持久化**：这三者都是操作现场而非会话属性，切会话或刷新即消失；相对地，模型选择的「默认」项让用户不必为每次会话显式绑定模型。
- **审批与聊天解耦**：审批有三处入口、两种 RPC（`exec.approval.resolve` 与 `approvals.*`），聊天线程里既没有审批消息也没有待审批徽标。
- **AgentSwarm 是并行产品面而非聊天扩展**：它有自己的房间、成员、RPC 与中止粒度，消息渲染复用 Markdown 管线但不复用 `openocta-chat-thread`。
- 本轮未覆盖：配置页、初始化向导、员工市场等非聊天页面的结构与交互。

## 11. 未验证事项

- 未运行桌面端，未验证流式文本的实际视觉节奏、滚动跟随手感与长会话卡顿。
- 「页头聊天工具条在消息页不出现」是布局分支的静态结论；`chatFocusMode` 若已被持久化为 true，界面进入专注布局的行为需运行确认。
- 发送失败后输入内容是否可恢复依赖 `previousDraft`，而该值来自始终为空的 `state.chatMessage`；未运行验证实际失败路径下的输入框表现。
- 审批轮询与事件两条通道在同一时刻到达时的展示顺序、以及多显示器/多窗口场景未验证。
- AgentSwarm 的成员树折叠、关系图缩放与右侧面板交互只做了静态阅读。

## 12. 关键源码索引

- `ui/src/ui/app.ts:148-240`：`OpenClawApp` 状态宿主与聊天相关 `@state`。
- `ui/src/ui/app-render.ts:550-1230`：壳层、顶栏入口、消息页侧栏与布局分支。
- `ui/src/ui/app-render.ts:2566-2810`：聊天表面的属性装配。
- `ui/src/ui/views/chat.ts:854-1255`：聊天布局、队列、Composer 与资源弹层。
- `ui/src/ui/app-chat.ts:158-332`：发送、排队、切换会话与刷新。
- `ui/src/ui/controllers/chat.ts:308-621`：`chat.send`、`chat.abort`、事件状态机与历史的入口。
- `ui/src/ui/chat/chat-session-runs.ts:109-301`：按会话的运行态保存、恢复与后台事件。
- `ui/src/ui/app-gateway.ts:151-387`：连接建立、事件路由与重连重置。
- `ui/src/ui/app-tool-stream.ts:137-286`：工具流节流、压缩提示。
- `ui/src/ui/app-approvals-banner.ts`、`ui/src/ui/views/exec-approval.ts`、`ui/src/ui/views/approvals.ts`：三处审批入口。
- `ui/src/ui/controllers/swarm.ts:56-322`、`ui/src/ui/views/agent-swarm.ts:323-472`：AgentSwarm 的发送、流式与房间管理。
