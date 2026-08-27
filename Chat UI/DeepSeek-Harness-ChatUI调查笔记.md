# DeepSeek Harness Chat UI 调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `apps/web`、`packages/client/*`、`packages/host/*`、`packages/api/*`、`packages/typert/`、`packages/extensions/ui-cordis`、`packages/core/tools/src/presentation.ts`）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`（分支：`master`）
>
> 调查方式：静态源码阅读，并对照仓库 `.agents/notes/implemented/architecture/` 下的 GUI 系列架构决策记录（加载链、slot 系统、对象层、RPC 协议、输入状态机、工具展示归属等）逐项核实；未运行 `dsh web`，视觉效果、键盘可用性与运行行为未实测
>
> 调查范围：前端技术栈与目录组织、双 cordis 插件树的加载链、slot 组合模型、客户端连接与四象限 RPC 协议、会话列表/工作区/搜索与现场恢复、Composer 输入状态机与 slash 管线、发送前配置与 schema-form 设置表单、消息流式渲染、工具卡片渲染意图与键控槽分发、多会话与后台生成、UI 状态所有权；排除项：UI 视觉效果、动画时长、焦点顺序、键盘可用性、滚动与流式性能需要运行验证，未运行即明确标注；会话数据语义、生成任务执行、消息渲染组件细节归相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 的 Web Chat UI（`dsh web`）是运行在浏览器里的第二条 Cordis 插件树：宿主进程跑一条 cordis 树（agent 循环、会话、RPC 网关、webserver），浏览器里跑第二条 client cordis 树，每个 UI 能力都是一个 `dsh.client` 插件包，由宿主构建的启动图（`__DSH_BOOT__`）按需取回。主要结论：

- **技术栈**：React 18 + Vite 6，但 React 只是纯投影层。业务数据住在 React-free 的"对象层"（`ConnectionController` → `SessionManager` → `Session` 三级），通过 `useSyncExternalStore` 快照喂给组件；组件不 import 框架，全部数据经 slot 系统派发的四个 props 份额到达。
- **连接架构**：四象限 RPC（请求/响应双向、方向永不从通道推断），上行是 HTTP POST、下行是每条逻辑流一条 WebSocket（mux 全会话聚合流 + host 宿主事件流）；无协议版本号，重连即重建（无 resume 游标）。`assistant/chunk` 事件就是令牌流本身，没有独立 delta 帧。
- **渲染机制**：`session/event` 帧进入连续事件窗口，由"会话节点装配器"（`ConversationNodeAssembler`）按注册制 Definition 折叠成业务节点；Chat 视图是"order 列表 + 按 key 订阅的座位"结构，流式增量只替换对应 key 的值，不重挂组件、不打乱兄弟节点引用。工具调用按工具名键控槽分发，`GenericToolCard` 兜底；工具在宿主侧用纯函数声明渲染意图（generic/terminal/diff + locations，结果另有 search/read/web 形态）。
- **设置表单**：宿主把 schemastery 序列化 schema 经 settings 命名空间下发，浏览器端 `rehydrateSchema` 复活校验器，按路径做不可变草稿编辑，以 `settings.mutate` path ops 增量写回。
- **主链路**：`dsh web` 起服务 → 浏览器拿 index.html + 启动图 → 两阶段启动（模块面 → 插件面）→ settled 一次性切到三栏工作台 → 选工作区创建 blank 会话 → Composer 提交（输入状态机事务）→ `session.prompt(mode:'queue')` → WebSocket 推帧 → 对象层累积 → 快照 → 行级重渲染。

## 工作台边界与用户主链

```text
dsh web（apps/cli 的 web 别名 = --profile web，装入 web-app bundle）
  -> webserver 绑定 127.0.0.1:3080，GET / 注入 window.__DSH_BOOT__
  -> AppWebEntry 两阶段 boot（loading 页 -> settled 一次性翻到真实 UI）
  -> AppFrame 三栏：sidebar | conversation | details（+ shell.overlay）
  -> 无会话 Hero：WorkspacePicker -> connectWorkspace -> 复用或创建 blank 会话 -> open()
  -> InputBar（同一实例从 inert 变 live）-> 输入状态机 -> Enter 提交事务
     -> 命令裁决（/ @ 触发）或 defaultSink -> session.prompt({mode:'queue'})
  -> WebSocket 下行：session/event（assistant/chunk 即令牌流）-> Session 事件窗口
     -> ConversationNodeAssembler -> ChatSnapshotBuilder -> ChatView 行级更新
  -> 运行中：TurnStatus + 停止按钮 + 队列 Dock；工具行按工具名键控槽分发
  -> 会话切换：侧栏行点击，Session 常驻消费帧，现场即时恢复
```

边界：会话/消息数据语义（blank 位、队列、事件窗口）与持久化属于会话与消息管理类目；prompt 受理、turn 执行、取消语义属于对话请求与上下文类目；消息组件（Markdown 增量渲染、代码块、图片）细节属于消息渲染器类目；工具审批的执行与校验语义属于 Agent 工具类目。本文只记录 Chat UI 侧的入口、状态、事件绑定与数据流向。

## 1. 技术栈与前端目录组织

apps/web 是一个薄 Vite 应用：入口 main.ts（`apps/web/src/main.ts:6-10`）只有 10 行，找到挂载点后把启动交给壳包；真正的启动、加载、装配全在 `@deepseek-ai/dsh-client-web` 里。构建配置把 workspace 包 alias 到源码（让 CSS 走 vite 管线而非 CSS 外置的 lib 包），vendor 手工拆包只放 React-free 的重渲染库（katex、shiki、micromark 系列）——插件包**永远不进入** vite 打包图，它们以运行时 bundle 到达（`apps/web/vite.config.ts:92-160`）。开发模式下直接 `vite serve` 会被拒绝，必须有宿主注入 `__DSH_BOOT__`。

`packages/client/*` 是前端本体，按到达方式分三类（`packages/client/AGENTS.md`）：

| 类别 | 包 | 说明 |
|---|---|---|
| 纯库（壳静态打包） | ui-slots、web-react、ui-primitives、schema-form、modules | 种子进模块表，不在宿主图内 |
| 静态到达 entry | connection、runtime、ui-theme、locale、hmr | 壳直接打包 `src/client/`，仍按图治理 |
| fetch 到达插件包 | ui-layout、ui-sidebar、ui-conversation、ui-tool、ui-workspace、ui-settings*、ui-commands、ui-input-trigger、ui-skill、ui-subagent、ui-cordis 等 | 双入口：node 半是空 apply，`./client` 子路径是 tsdown 闭包工厂 bundle |

职责分层（`packages/client/AGENTS.md`）：对象层（runtime，React-free：连接、会话、事件窗口、快照存储引擎）、渲染机制（web-react，壳专属：slot 渲染器、uSES 桥）、展示组件（各插件包 `src/client/`，纯 props）。插件包之间禁止 value import（构建期 purity 门），协作只走 cordis 服务与 slot；跨插件消费 `/client` 只允许 type-only。

测试分层完整：`apps/web/tests/` 下有大量 keyless 回放 e2e（fixture 服务端 + 快照 `ui.expected.md`），`stress-tests/reasoning-chunks.stress.ts` 用 100,000 个 reasoning chunk 压浏览器响应性（文件 1-50 行）。

## 2. 页面结构、加载链与装配

### 三栏工作台

工作台是 ui-layout 注册到内建 `'root'` slot 的 `AppFrame`：CSS grid 三栏（sidebar | 会话中列 | details），带两个拖拽手柄（pointer capture + rAF 节流），窄视口自动折叠侧栏，中列永远至少占 1fr（`packages/client/ui-layout/src/client/AppFrame.tsx:87-200`）。细节列（details）在会话切换时自动关闭，宽度为 0 时子树保持挂载（不卸载）。侧栏骨架在 ui-sidebar：宽模式内容与 56px 紧凑 rail 之间有 150ms 的滑动交叉淡出动画（`packages/client/ui-sidebar/src/client/SidebarRoot.tsx:28-60`）；滚动条只在指针位于列内时绘制（离开 2 秒后隐藏）。

### 加载链与装配

壳的启动是两阶段（`packages/client/web/src/boot.tsx:97-208`）：先解析宿主注入的启动图，建立客户端模块系统（懒 CJS 表：执行 bundle 只注册工厂，副作用在首次 require 时物化），渲染 loading 页并并行预取声明为立即加载的基础设施条目；随后挂载 vendored cordis Loader，把模块系统注入其内部槽（以模块 stub 与进程探针替换实现浏览器化），逐条创建图条目，`loader.await()` 后做全 ACTIVE 扫描（列出 import 失败、apply 抛错与等待缺失服务的纤维），成功即一次翻转 settled。壳只渲染 `'root'`（`packages/client/web/src/app.tsx:38-43`），app-shell 伪条目负责安装 slot 渲染器（`packages/client/web/src/app-shell.ts:35-50`）。每个 slot 条目带独立错误边界：一个插件崩了只黑一块卡片，boot 期失败则整页停在 loading 并展示失败报告。

### slot 组合模型

组件组合只有一条路：`ctx.slots.register({name, children?, store?, inject?}, Component)`——一次调用同时占用槽位、声明并授权子槽、声明 store、注入业务面（`packages/client/AGENTS.md` 规则 1-3）。组件 props 是四个自动派生的份额：运行时份额（会话作用域含 `useSession` 钩子与会话 id）、子槽渲染份额（`renderSlot`）、store 份额（只读钩子与声明动作）、inject 份额。

槽名镜像组合路径，例如 `'conversation.chat.node'` 与 `'tool.call.toolview'`。对话视图是 ui-conversation 声明的列表槽条目；conversation 条目本身是 session-maybe 驻留壳——无会话到 blank 会话的过渡期保持 React 实例存活（textarea DOM 全程存活），其内部严格会话条目（头部与正文）与同样 session-maybe 的 composer 栏条目在会话出现后才填充内容。完整槽树见 `packages/client/ui-conversation/src/client/contract/slots.ts`。

## 3. 客户端连接与 RPC 协议

协议契约在 `packages/host/apiproxy/src/api/`（浏览器可 import，零 Node 依赖）：所有 wire 消息是四象限判别联合——`client-request`（客户端铸 rpcId，POST /api/<method>）、`server-response`（该 POST 的应答体）、`server-request`（服务端铸 rpcId，WebSocket 文本消息）、`client-response`（POST /api/respond 回填）。rpcId 纪律：谁发起谁铸造，应答只回显；业务代码永远不铸。

业务结果以 `RpcResult<T>` 的 ok/error 判别联合表达，方法不抛业务错误；传输层失败（网络、宿主不在）由载体抛异常，两层不混（`packages/host/apiproxy/src/api/rpc.ts`）。zod 双层校验（信封一次、按方法或帧类型一次），错误码由 `RpcErrorDetailsMap` 一张表驱动。

载体层把平台差异收在两个可覆写点：`AbstractApiClient` 基类持全部协议不变量，传输走 `doFetch`、观察走 `onEnvelope`（实例级微任务批量缓冲，当前无消费方）。

浏览器子类 `WebApiClient` 上行用全局 fetch，下行每条逻辑流开一条 WebSocket——`/api/events.mux` 只发 MuxFrame、`/api/events.host` 只发 HostFrame，每条文本消息是一个完整的服务端请求 JSON 文档；Socket 只承载宿主到浏览器的下行，不接受任何客户端应用消息（`web-api-client.ts:13-90`）。两条流生命周期独立、无跨流顺序保证，任一流结束都判整个连接代数失败。

同源进程内还有不碰网络的 `InProcessApiClient`（跑真实 wire 序列化）与 `FixtureApiClient`（`?fixture` 无服务器开发、协议层假服务）。

`ConnectionController`（`packages/client/connection/src/client/connection.ts:61-169`）泵两条流并管理重连：指数退避 500ms 起、翻倍封顶 10s、带抖动、无次数上限；每代连接先做严格握手——两条流 open 且 `host.describe` 成功才发布 connected。

重连 = 重建：connected 触发列表刷新 + 每个已打开会话 resync（清窗口重开，用 subscribed 帧的 lastSeq 与历史尾 seq 对比、有缺口回填一次）。`assistant/chunk` 就是 session/event 帧里的令牌流，无独立 delta 帧。

帧类型全集见 `packages/host/apiproxy/src/api/events.ts`：

- MuxFrame（全会话聚合流）：`session/event`（会话事件，`assistant/chunk` 在其中）、`session/subscribed`、`session/queue`、`session/projection`、审批与问答的 requested/resolved 对
- HostFrame（宿主流）：`host/session-added`、`host/session-status`、`host/workspace-*` 系列、`host/remote-event`（Typert 远程事件转发）等

审批与问答的 requested 帧可应答：rpcId 在接受时铸造一次、mux 重开时原样重放；宿主侧 pending 表与 `/api/respond` 应答器已在 `api-proxy.ts:3696-3740` 实现（旧架构笔记中"respond 恒 not-pending 的 stub"状态已被此实现取代）。

宿主侧 BFF：api-proxy 实现全部 unary 域，路由表按 `RpcMethodMap` 编译期锁定（`fetch/handler.ts:90-100`）；除此之外，Typert 网关（`packages/api/gateway`）把业务服务上用 `@Remote` 标记的方法暴露为规范端点——服务端用生成的调用描述符解码参数、解析接收者、调用并编码结果，客户端侧对应的 remote 命名空间服务走 connection 的共享 /api 通道；`packages/api/remotes` 是 BFF 上层，负责 agent/session 身份解析并选择应用暴露的 Remote 贡献。

协议契约由 typert 从类型图生成（registry/loader/generator 三件套，`packages/typert/README.md`），业务包只声明标记。`packages/sdk/` 是另一条独立的进程外通道（stdio JSON-RPC server + TypeScript client），与 Web 的 /api 四象限协议无关。

## 4. 会话导航、工作区与现场恢复

会话列表与工作区浏览器在 ui-workspace 的 `WorkspaceBrowser`（`sidebar.workspaces` 槽位），支持分组树/平铺两种视图、每工作区折叠到 5 行、原生拖拽排序（行悬停显示插入标记）、本地过滤 + 宿主全文搜索（`session.search`，250ms 防抖、500 码位截断、结果上限 20 条并提示精化查询）（`packages/client/ui-workspace/src/client/WorkspaceBrowser.tsx:29-90`）。会话行从 sessions 列表快照派生。

新会话入口统一是 `connectWorkspace(workspaceId)`：先在列表镜像里找 blank 且工作区路径与会话成员资格同时匹配的会话复用（宿主成员资格规则，绝不只按 cwd），否则调 `session.create({workspaceId})`；返回的 id 保证已在列表且 `sessions.binding(id)` 同步可解析。

全局 New Session 按钮默认取最近工作区（按最新会话更新时间排序）。启动时若无已恢复会话，自动打开最近工作区的 blank 会话（策略只结算一次）。blank 会话是"已物化但日志为空"的普通会话：侧栏只显示当前的一个（标题强制 `New Session`），首次 `prompt()` 被接受才翻转 blank 位（宿主权威、跨标签页同步），会话创建不落盘、宿主重启后蒸发（`session.ts:190-260` 的翻转与 `handleBlank`）。blank 判定、创建/复用语义见会话与消息管理类目。

会话切换是"即时"的：Session 实例懒建且常驻，一旦创建就持续在后台吃帧，切走再切回直接渲染快照；切换时细节列自动关闭，滚动位置经 layout store 的 `chatScroll` 保存（会话内跨视图标签页切换恢复位置，见 ChatView 的打开逻辑）。侧栏行点击即切换当前会话（`sessions.current`），无多级目录、无归档 UI（宿主有 archived-sessions 帧与命令，本次未在 Web UI 找到归档入口）。

## 5. Composer、草稿与输入状态机

Composer 是 `conversation.composer.bar` 槽位的 InputBar：普通 textarea + 背景装饰层（chip、词法高亮、占位提示都画在 backdrop 上，textarea 字形不可见），带 IME 合成保护（合成期 Enter 只选候选不发送）、图片拖放/粘贴附件（`AttachmentRail`、`imageLimits` 投影预检）、Ctrl+Enter 换行（不走浏览器 execCommand，避免与自管理撤销分叉）。无会话时同一实例 inert 渲染（机器面缺失、`disabled` owner prop），`connectWorkspace` 返回后原地变 live——textarea DOM 全程存活。

输入是纯状态机 `InputMachine`（`packages/client/ui-conversation/src/client/input/machine.ts`）：四阶段（plain / adjudicating / claimed / submitting），命令模式**绝不从草稿文本派生**，由选择路径在离散时刻显式建立 claim（监听 `draft.startsWith(token)`，退格破坏自动释放）。事件面一个事务一条，按功能分组：

- 编辑：草稿变更、Ctrl+Enter 换行（不走浏览器 execCommand，避免与自管理撤销分叉）
- 跨插件重写：`begin-command` / `insert-ref` / `consume-token` 三个 scoped bail 事件，CAS 是草稿修订号相等
- 撤销：自管理 undo/redo（100 条环形日志，单字符输入按注入时钟窗口合并，成功提交清空）
- 粘贴：`paste-begin` / `paste-upgrade`（粘贴匹配 chip 两段式撤销）
- 提交：`enter` / `adjudicated` / `submit-settled`（SubmitAttempt 带序号与中止信号挡回潮，成功提交清草稿，失败在"live draft 仍等于 enter 时快照"的漂移守卫下回滚）

引用 chip：每个引用在草稿里占一个 U+FFFC，occurrence 表记录偏移/来源/剪贴板文本；视觉投影是标签、剪贴板投影是占位符展开后的纯文本、模型投影是提交时按来源的序列化器生成——草稿持久化永远存纯文本，刷新后 chip 降级为文本。skill/@subagent 引用走"纯文本引用"路线：选择直接插入字面 `/name ` `@name ` 文本，chip 视觉纯派生（`decorations.scanTextRefs` 词边界扫描），不参与命令裁决。

slash 管线（ui-input-trigger）：根服务只持来源注册表（`InputTriggerSource{trigger:'/'|'@',...}`，按注册顺序轮询，第一个非 undefined 答案胜出，无声明方则落默认 sink），每会话一个 `InputTriggerController` 持权威命中、菜单 store、键盘仲裁（组合框模式：焦点留在 textarea，↑↓/Enter/Esc 拦截且都过 IME guard，唯一例外 Shift+Enter 无条件先走）。命令知识在 ui-commands：三类命令（execute 直跑 / leadingInput 回填 `/name ` 继续输参 / popupSelect 官方选择框壳），目录按 sessionId 键控缓存，命令变更帧经 `host/remote-event` 转发为软失效、`connection/reset` 硬失效重预热；宿主是命令目录唯一权威。

## 6. 发送前配置与设置表单（schema-form）

发送前配置分几处：composer 工具行有两个命名控制座（模型选择与计划模式，未注册时保持空位、无占位符回退），权限选择器（审批策略预设选择）、上下文仪表、队列 Dock（只读队列列表）。模型选择经会话寻址的 `session.models` / `session.selectModel` RPC（可配 reasoning effort），agent preset 在设置页选择（`ui-agent-preset` 行）。

设置入口在侧栏底部（`sidebar.settings` 槽位），chrome 在 ui-settings-general（导航 + 对话框 + 保存/重载动作）。设置传输是命名空间制：`settings.describe` 返回某 section 的 schema（schemastery 序列化信封）、分层值（用户层与回退层）与 secrets，`settings.mutate` 以路径操作（set/unset）增量写回。

浏览器端 schema-form 包做四件事（`packages/client/schema-form/src/model.ts:19-151`）：`rehydrateSchema` 把序列化信封复活成活校验器；`nodeAtPath` 沿配置路径解析节点；按路径的读取/设置/删除做不可变草稿编辑（自动物化缺失的中间容器）；`validateDraft` 提交校验。模型页的 ProviderEditor 是典型用法：草稿按路径编辑、只有卡片可见的字段生成路径操作、整节 schema 校验（`ProviderEditor.tsx:145-260`）；权限预设与插件配置页同样复用这套工具。

API key 经 `credentials.set` 以引用形式存储（不落明文），适配器家族（deepseek / pi-ai）各有手写编辑卡片，推理 effort 因"按模型能力"刻意不进 provider 级表单。

## 7. 发送、流式渲染与生成控制

提交统一走 hub 的 defaultSink：乐观清草稿后只调 `session.prompt(content, 'queue')`（Web 无 steer 入口，宿主 wire 的 steer 模式不进入本机器），失败且 live draft 仍为空才回填——用户已继续输入则绝不覆盖。prompt 的 rpcId 经 MessageSource（`'user-rpc'`）进入 `user/message` 事件，客户端用它把乐观回显升级为事件流的正式消息。

流式渲染全链：宿主推 `session/event` 帧（`assistant/chunk` 就是令牌流，六种 StreamChunk 变体）→ Session 追加到连续事件窗口 → 装配器对每条事件跑所有 Definition 的 `match(event)`（只看当前事件、不做上下文扫描）→ assistant-step Definition 按块索引累积文本/推理/工具增量（块级不可变，见 `assistant.ts:80-120` 的 updateChunk）→ publication 返回动画帧节奏把高频增量合并到下一帧物化 → 快照构建器只替换该 key 的节点 → Notifier 微任务批量（`markDirty`）→ uSES 快照 → 只有订阅该 key 的行重渲染。

`PartialAccumulator`（`packages/client/runtime/src/client/sessions/partial.ts:22-80`）是历史兼容层：usage/finish 判定为不可见、跳过通知。

ChatView（`packages/client/ui-conversation/src/client/chat/ChatView.tsx:146-427`）是"order 列表 + 座位"结构：每个座位只订阅自己的节点 key，`order` 只在节点进出/移动时变；滚动跟随以 24px 阈值判定是否贴底，上翻页用"锚点行 + 相对偏移"保持读者位置，ResizeObserver 处理流式撑高；打开后跳底一次、视图标签页切回时恢复保存的阅读位置。

运行中显示 `TurnStatus`（"Deep diving..."，15 秒后叠加运行时钟，锚定 `turn/start` 时间），尾部渲染 pending steering 气泡。

错误与状态行：prompt 失败进 `promptError` 在 composer 出 Toast（草稿保留可重发）；`turn-error` 节点持久显示、`turn/end` 的 max-tokens 提示；重试节点（`model-retry`，details 行带 250ms 倒计时与失败信息）。

生成控制：停止按钮 → `session.cancel()`（保留 pending inbox 工作，结算后按 FIFO 恢复；子 agent 会话路由到 `subagent.interrupt`）。队列帧 `session/queue` 整体替换会话队列镜像（`queue-mirror.ts:24-60`，200 字符预览），QueueDock 只读展示，队列项可编辑/移除/steer（`session.updateQueue`）。空闲态由 running 中继与 turn 关闭驱动。

## 8. 工具卡片渲染

工具展示归属 ui-tool：装配层（ui-conversation 的 tool Definition）只负责把根 `tool/call` 与结果按 callId 配对、把 Code Dispatch 事件折叠成递归子调用块、发出一个稳定的 `tool-call` 聊天节点。

展示层 `ToolCallTree` 递归遍历根块，每一层都走同一个键控/会话级 `'tool.call.toolview'` 槽，键是 wire 工具名，无注册时落 `GenericToolCard`（`packages/client/ui-tool/src/client/tool/ToolCallTree.tsx:14-105`）。

业务工具包只注册自己的原子视图：例如 ui-cordis 为 cordis_define 等四个 cordis 工具注册卡片，另注册 `sidebar.footer.action` 面板与 `@pluginId` 引用源（`packages/extensions/ui-cordis/src/client/index.ts:84-168`），不碰装配与递归结构。

通用行的视觉分类在纯函数行模型 `toolRowModel`：按工具名映射变体（bash/read/write/edit/code/search/others），从 args 提取摘要/可打开路径/展开体，从结果节点展平输出文本，状态取 running/ok/error/stopped（`packages/client/ui-tool/src/client/tool/models/tool-call-model.ts:37-239`）。变体名到图标的映射表只覆盖第一方工具；未知工具名落到 others 行。

工具侧渲染意图是设计的一部分（`packages/core/tools/src/presentation.ts:46-140`）：`ToolDefinition.presentCall` 声明 pending 态（generic / terminal / diff 三类，附类别 icon、`locations` 供编辑器"跟随"），`presentResult` 声明完成态（generic / terminal / diff / search / read / web），全部是 args 的纯函数。

结构化结果（read 的行号窗口、web 的引用源、search 的命中分组）经 `output.presentationMeta` 随会话日志持久化，直播与回放路径由 `presentResult` 同样重建。详情面板是第二展示点：ui-conversation 把选中调用的内容体委托给 `'conversation.details.tool'`，ui-tool 复用卡片模型，插件缺席时回退原始结果文本。

## 9. 消息操作、队列与详情面板

消息操作栏 `MessageIconActions`：复制（剪贴板 + 1 秒对勾反馈、防抖）、分支（只在消息是已完成回合的 transcript 尾时可用，传消息 seq 给 `session.fork` 以该 turn 为边界分叉）、按需时钟（运行时长 / TTFT / tok/s 指标）；插槽式扩展位让独立插件（如 Like/Dislike 反馈）挂在内置复制与分支之间（`MessageIconActions.tsx:13-80`）。

turn tail 行（ui-deliverables）展示每个收尾 assistant 消息下的产出文件。队列项在 QueueDock 内可编辑/移除/steer。详情面板 `DetailsPanel` 随选中工具调用（`inspectCall`）打开，切换会话时自动关闭。

未找到就地编辑历史消息的入口——历史是追加型，修改以分支表达；消息删除 UI 本次未找到。

## 10. 多会话、子 Agent、后台与跨窗口

多会话并行是常态：所有会话共享一条 mux 流，Session 常驻后台消费帧，侧栏行带运行标记（running 来自 `host/session-status`），可同时多会话在跑；Web 端没有 Pi 那样的并发/队列选择器——新会话即新 blank 会话，发送在每会话各自 Composer 内。子 agent 会话在侧栏以 catalog 形式列出（`session.list` 快照按 parentId 过滤），子会话可进入阅读（one-shot 只读、不可恢复发送），父会话侧展示运行/中断标记；子会话自身是独立 sessionId 的普通会话，切换进子会话即切换当前会话。后台任务：`session/jobs` 帧 + ui-jobs 在会话头部列出（jobsBySession 镜像）。跨窗口：同一 host 进程可服务多个标签页（每标签页独立的双流连接），blank 位、会话增删、运行状态经帧广播跨标签页对齐；未找到草稿或当前会话的跨标签页同步机制（刷新即回落到宿主权威列表）。

## 11. UI 状态所有权与同步

三层事实源（`packages/client/AGENTS.md` 规则 5-7、架构笔记）：

- **对象层**（Session / SessionManager / ConnectionController）：业务状态全部在这里——事件窗口、流式累积、队列镜像、pending 交互、open 状态、分页、prompt 错误。React 只订阅快照。
- **声明式 store**（`defineStore`，zustand vanilla + immer）：只承载跨条目共享或需存活于重挂载的视图状态——布局（面板宽度/侧栏偏好，`AppFrame` 读）、会话内聊天状态（`chat` store：draft、选中调用、滚动位置、draft 镜像）、工作区视图偏好。store 工厂在 register 处声明，实例随条目/会话生命周期创建销毁。
- **组件本地状态**：scroll 锚点、搜索文本、展开状态等纯私有状态。

现场恢复：切走再切回即时（常驻实例 + 快照引用稳定）；`loadOlder` 上翻页用锚点行保位；重连 = `resync` 清窗口重开 + seq 对比回填，`chatScroll` 保存的阅读位置跨视图切换恢复，跨重载不恢复（草稿是纯文本投影，刷新后 chip 降级、滚动回底）。

## 12. 键盘、焦点与关键路径可用性

关键路径键盘：Hero（无会话时整个虚线卡片可用 Enter/Space 打开工作区选择器）→ 输入框输入（IME 合成保护、Ctrl+Enter 换行）→ Enter 提交 / 空格触发的 slash 裁决（Space 只认 leadingInput 命令，防止误触不可逆副作用）→ 组合框菜单 ↑↓/Enter/Esc 仲裁 → 停止按钮、队列项操作均可指针/键盘到达。焦点传播：菜单打开时焦点留在 textarea；弹层外点击关闭并返回文本区焦点；rail 搜索聚焦等待 300ms 侧栏展开动画完成（避免同步 focus 卡顿）。以上是静态代码可确认的绑定；焦点顺序、无障碍名称、实际键盘行为（尤其 IME 在中文输入法下的 Enter 边界）需运行验证（见 §14）。

## 13. 设计取舍与已确认边界

工作台继续以会话对象层而不是组件局部状态承接恢复。当前 Web 组合额外覆盖了冷启动空白会话、长历史分页、会话引用以及等待用户提问的路由场景；测试夹具把问题表面优先于底层运行状态的选择写成可回放断言。模型选择器可依据 adapter 提供的目录能力显示并批量修改选择项，但选择本身仍由宿主 settings 与会话请求构建链裁决（`apps/web/tests/{cold-blank-session,complex-history,built-boot}.ts`、`packages/client/runtime/src/client/workspaces/service.ts`）。

- **双 cordis 树 + 运行时插件加载**：浏览器复用宿主的 Loader 治理，模块系统自研（懒 CJS 表 + 同源外部脚本到达）；代价是 dev 每次改插件要重建 bundle + 纤维重挂，HMR 一次只重载一个插件、React 状态丢失（数据层不动）。web bundle 中 hmr 行当前默认 disabled（`cordis.patch.yml` 的 TODO）。
- **对象层 React-free + uSES 快照**：令牌流不打乱渲染树，行级重渲染靠引用稳定；代价是自研快照/批处理机制（`markDirty` 微任务、`notifyNow` 仅用户手势直回声、`animation-frame` 流式合并）。
- **重连即重建**：无 resume 游标，`mux` 的 `since` 是保留席位；换来的是实现简单与一致性，代价是重连会丢帧间隙（回填只补一次）。
- **仅下行 WebSocket**：上行保留 HTTP，避免重写超时/取消/信任围栏/请求关联语义；每条逻辑流一条 socket，绕开 HTTP/1.1 六连接配额但保留双流就绪语义。
- **一次翻转 boot**：无渐进渲染；settled 前只有 loading 页。
- **每会话一个输入机器**，无全局 Composer 并发模型；Web 无 steer 入口（host 能力存在但机器不暴露）。
- **工具渲染意图 = args 纯函数**，UI 展示层不进会话日志（日志只存 presentationMeta 与事件）；回放由同一函数重建。
- 审批/问答的宿主 pending 表与应答器已实现；客户端 `PendingWait` 会 mint 应答。approval-composer 与 question-composer e2e 存在，行为未实测。

## 14. 未验证事项

- 未运行 `dsh web`：视觉效果、动画、CSS 主题、焦点顺序、键盘可用性、IME 行为、滚动与流式性能均未实测（静态代码只确认入口、状态与事件绑定）。
- 流式期间的行级重渲染、100,000 chunk 压力场景只看到测试声明，未观测实际帧率。
- 多标签页并发、重连间隙丢帧、HMR 链（默认 disabled）未实测。
- 审批/问答的完整交互（ApprovalPanel 接管 Composer、QuestionComposer 回答流程）未实测。
- schema-form 只核对了模型层与使用点；ProviderEditor 的表单交互、设置保存冲突行为未实测。

## 15. 关键源码索引

- `apps/web/src/main.ts`（应用入口）、`apps/web/vite.config.ts`（shell 打包与 vendor 拆包）、`apps/web/tests/`（keyless 回放 e2e + snapshots）、`apps/web/stress-tests/reasoning-chunks.stress.ts`（流式压力）
- `packages/client/web/src/boot.tsx`（两阶段启动）、`app.tsx`（renderSlot('root')）、`app-shell.ts`（渲染器安装）
- `packages/client/ui-layout/src/client/AppFrame.tsx`（三栏）、`packages/client/ui-sidebar/src/client/SidebarRoot.tsx`（侧栏）、`packages/client/ui-workspace/src/client/WorkspaceBrowser.tsx`（会话/工作区列表与搜索）
- `packages/client/connection/src/client/connection.ts`（ConnectionController）、`web-api-client.ts`（WebSocket 下行）、`packages/host/apiproxy/src/api/rpc.ts`（四象限）、`api/events.ts`（帧清单）、`api/sessions.ts`（会话域契约）、`fetch/handler.ts`（unary 路由表）、`api-proxy.ts:3696-3740`（respond 应答器）
- `packages/client/runtime/src/client/sessions/session.ts`（帧分派/操作）、`partial.ts`（chunk 累积）、`queue-mirror.ts`、`packages/client/ui-conversation/src/client/conversation-nodes/assistant.ts`（流式 Definition）、`chat/ChatView.tsx`、`chat/ChatNodeSeat.tsx`、`skeleton/InputBar.tsx`、`input/machine.ts`（输入状态机）
- `packages/client/ui-tool/src/client/tool/ToolCallTree.tsx`、`tool/models/tool-call-model.ts`、`packages/core/tools/src/presentation.ts`（渲染意图）
- `packages/client/schema-form/src/model.ts`、`packages/client/ui-settings-models/src/client/ProviderEditor.tsx`、`packages/client/ui-settings/src/client/settings-scope.ts`
- `packages/api/gateway/src/index.ts`（Typert 网关）、`packages/api/remotes/`（BFF）、`packages/typert/README.md`、`packages/bundle/web-app/cordis.patch.yml`（浏览器 roster）
- 架构决策记录：`.agents/notes/implemented/architecture/` 下 `2026-07-19-gui-web-client-architecture.md`、`2026-07-19-gui-layering-and-rpc-protocol.md`、`2026-07-22-slot-type-chain-implementation.md`、`2026-07-23-client-plugin-loading-model.md`、`2026-07-25-web-input-machine-and-slash-pipeline.md`、`2026-08-04-websocket-downlink-carrier.md`、`2026-08-08-client-tool-presentation-ownership.md`、`2026-08-09-client-conversation-node-assembly.md`
