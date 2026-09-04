# OpenClaw 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-04
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态源码阅读；沿消息内容 part、Gateway 显示投影、`show_widget` 工具、Canvas 文档、Board Store/HTTP、view ticket、widget bridge 与 host RPC 复查输出对象的创建、状态、运行与回流；未启动 Gateway、未运行真实 UI/渠道场景
>
> 调查范围：模型输出如何获得独立对象身份与专用运行环境——canvas document、session board widget 的对象模型/持久化/运行/授权/事件回流、消息内展示与 dashboard 投影；渠道投递状态只记录交接点；排除产品结构与设计基因；普通 Markdown/结构化 part 的 DOM 映射留给消息渲染器，媒体生成与 artifact 下载留给媒体创作
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 的默认聊天输出停留在 G0 层次：模型产出的可见回复是普通文本/结构化内容 part（含 thinking、工具调用/结果、媒体引用等），最终以 assistant 消息进入 transcript，本身没有独立 ID 之外的活对象生命周期；媒体文件通过 artifact 服务获得可寻址引用但归属媒体创作类目。这个基座之上的“输出对象”机制集中在两处：**Canvas 文档**（把一段自包含 HTML/媒体预览落到 `state/canvas/documents/<id>/`，带 manifest 与 `cv_*` doc id，作为消息内 widget 预览或托管内容面）和**Session Board Widget**（以 widget name 为稳定身份、revision/instanceId/viewGeneration 为版本线，持久化在 per-agent SQLite 的 `board_tabs`/`board_widgets`，可以承载 HTML、plugin registered content、MCP App view 三种内容，并带 grantState 能力授权）。

`show_widget` 工具是唯一向模型公开的“生成可操作输出”入口（`src/canvas/widget-tool.ts:251-516`）。它把模型给出的 HTML/SVG 包进统一 document shell（CSP + host bridge + theme/snapshot/size 桥），随后走两条目标路径：未 pin 时物化成 assistant-message 内嵌 Canvas 文档（沙箱 iframe、无网络、只读演示 + 用户激活驱动的 prompt 回流）；`pin: true` 时调用 `board.widget.put` 写入 session board，成为 dashboard 上可长期存在、可被再次同名字段更新、可声明网络 origin 与工具能力的 widget。pinned widget 运行于带 view ticket 的隔离 iframe/专用沙箱 host，脚本默认 `connect-src 'none'`，声明并获准的网络 origin 才进入 `connect-src`；host bridge 暴露 `prompt.send/state.emit/data.read/action.run/cron.trigger`，其中 data/action/cron 与 prompt 免确认都要求 grantState 为 `granted` 且工具名在 declared 集合内。

按指南能力谱系，本快照的核心聊天输出与普通富文本属于 G0/G1；widget/canvas 子系统整体处于 **G2–G3**：它以“声明式内容 kind + 能力声明 + 授权状态 + host 注册表路由”（G2 要素）承载 HTML/JS 沙箱执行（G3 要素），但更新粒度是整段覆盖（revision+1、授权随字节变化重审），没有 G4 需要的 diff/接受-拒绝编辑器或文件级管理，也没有脱离会话的 G5 环境化活对象；board widget 生命周期与会话绑定。媒体、图表等富静态结果经 artifact/媒体路径另归 G1，见 [OpenClaw 媒体创作调查笔记](../媒体创作/OpenClaw-媒体创作调查笔记.md)。

## 系统边界与完整主链

本类目边界以指南“输出获得独立对象身份或专用运行环境”为起点，接手点与相邻笔记的划分如下：

| 相邻类目 | 本笔记接管 | 留在相邻类目的内容 |
|---|---|---|
| 消息渲染器 | canvas block 的内容身份、widget 的托管 URL 与 iframe 隔离契约由谁产生 | 消息/气泡、Markdown、widget-card DOM、工具卡 DOM 映射 |
| 对话请求与上下文 | 生成对象如何被创建/引用、流式事件到终态如何回写 | 上下文拼装、流式 delta、队列、重试/压缩 |
| 媒体创作 | 生成结果如何成为可操作对象（本轮不涉及图片/视频/音频生成编排） | 媒体生成任务、managed media、artifacts RPC 下载 |
| 会话与消息管理 | board rows 作为输出对象的持久化语义 | session/transcript schema、删除归档 |
| Agent 工具 | 输出对象创建后的物化、运行与回流 | show_widget 的工具执行语义、approval 调度本身 |
| Chat UI | dashboard/board 投影面的入口与返回 | 工作台布局、面板开关、消息操作 |

完整主链（pinned widget 一条即覆盖“触发→生成→展示→交互→保存→回流”）：

```text
模型回合内调用 show_widget(widget_code, pin/name/tab/size/capabilities)
  -> 校验 widget_code 大小/kind/registration.validateSource
  -> buildWidgetDocument 包装为自包含 document shell（CSP+bridge+token）
  -> pin 分支: 经 in-process gateway RPC board.widget.put 写入 session board
       server-methods/board.ts: materialize(wrap)/declared 规范化
       -> board-store.putWidget -> sqlite board_widgets upsert (revision+1, sha256, viewGeneration, grantState)
       -> grantState=pending 时按 exec 模式 人工/auto-review/full 决策 -> store.grant
       -> 广播 board.changed
  -> 未 pin 分支: createCanvasDocument 落盘 state/canvas/documents/<id>/ (manifest.json + index.html)
       -> tool result {kind:canvas, view:{id,url}} 成为 assistant 消息的可见内容源
  -> 展示:
       inline: 客户端沙箱 iframe 请求 /__openclaw__/canvas/documents/<id>/index.html（CSP sandbox allow-scripts）
       pinned: Control UI 通过 board.get 获得 frameUrl(/__openclaw__/board/<sessionKey>/<name>/index.html?bt=ticket)
       board-http.ts 校验 ticket(grant/revision/viewGeneration) 后返回存储 HTML + CSP
  -> 运行/交互:
       框内脚本运行于 opaque/专用 origin；host bridge 以 MessageChannel 与宿主握手拿 ticket
       openclaw.state.emit -> board.event -> 以 "[dashboard]..." system event 入会话
       openclaw.prompt.send（用户激活+确认/授权）-> 会话内 user prompt
       openclaw.data.read/action.run/cron.trigger -> 校验 granted tool 后调用注册的 Gateway handler
  -> 持久化/回流:
       board_widgets rows 与会话同寿命；助手下回合从 system event 读到 widget 通知
       模型对同一 widget 的更新 = 再次 show_widget(pin, name 相同/generated identity 命中)
```

## 1. 消息输出对象模型与 G0 基座

### 模型可见文本与结构化 part

助手回合的模型输出在 Agent Core 中先归约为内存 assistant message（`packages/agent-core/src/agent-loop.ts:226-509`），part 语义与 Provider stream 增量无关紧要地在这里不是“对象身份”来源；最终 assistant 消息由 SessionManager 以 parent-linked entry 写入 transcript。Gateway 对外投递的是 `chat`/`agent` 事件和回复 payload，具体投影和缓冲节流在 [OpenClaw 对话请求与上下文调查笔记](../对话请求与上下文/OpenClaw-对话请求与上下文调查笔记.md) 已覆盖，本轮不重复。

聊天历史对 Canvas widget 的可恢复展示做了一次专门的显示投影：`augmentChatHistoryWithCanvasBlocks` 会扫描 assistant 消息与 tool call/result 的 details，把工具结果里可识别的 canvas 载荷转成一个 `{type:"canvas", preview:{viewId/url/boardWidgetName/...}, rawText}` 内容块，追加/合并到最近的可渲染 assistant 消息上，保证只读客户端重载历史后仍能恢复内嵌 widget（`src/gateway/chat-display-projection.canvas.ts:195-238`、`:264-340`；入口见 `src/gateway/server-methods/chat-history-pages.ts:329-427`）。也就是说，消息正文内的 widget 在数据层上是“对象引用 + 预览块”，本体在 Canvas 文档或 Board Store 中。

可识别载荷的来源有三种，统一由 `src/chat/canvas-render.ts` 定义：工具结果 details 中的 `{kind:"canvas", presentation:{target,sandbox,...}, view:{url,id,boardWidgetName}, mcpApp?}` JSON（`coerceCanvasPreview`，见 `src/chat/canvas-render.ts:115-203`）；assistant 文本中的 `[embed ...]`/`[embed]...[/embed]` 短码（会跳过代码围栏并按 `ref/url` 生成默认 `/__openclaw__/canvas/documents/<ref>/index.html` 地址，见 `src/chat/canvas-render.ts:211-332`）。MCP UI resource 工具结果也按 `target:"assistant_message"` 产生同类 canvas 预览（`src/agents/mcp-ui-resource.ts:403-406`）。

### 未发现独立身份的证据面

在普通文本/Markdown 回复路径上没有发现逐 token 内容或段落拥有独立 ID、可编辑状态或运行实例的机制：assistant 可见文本只是一个内容 part，全部生命周期管理发生在消息级（run、transcript entry），即指南定义的 G0。工具执行卡、附件、媒体块分属 Agent 工具、消息渲染器和媒体创作类目，均不构成新的 G2+ 输出对象。

## 2. 触发方式与输出协议

输出对象创建的两个触发入口：

1. **`show_widget` 核心工具**（唯一对模型开放的自助生成入口）。参数含 `title`、`widget_code`、可选 `kind`（html 或插件注册 kinds）、`pin`、`name/tab/size/presentation`、`capabilities{netOrigins,tools}`，schema 见 `src/canvas/widget-tool.ts:44-118`。其存在受客户端能力控制：只有在来源客户端声明 `inline-widgets`，或恰好一个 current-channel presenter 同步匹配可信运行上下文时才被注入工具集（`src/canvas/widget-tool.ts:282`，见 `docs/tools/show-widget.md:32-34`）。这说明协议本身是 typed tool-call，不是自由文本探测，也没有半截流/转义问题——工具按完整调用执行。
2. **插件注册内容 kind 与 MCP App view**。`show_widget` 的 `kind` 若指向插件 `registerBoardWidgetContentKind` 注册的 kind（如 diagram），会先 `validateSource` 再 `composeDocument` 把插件资源拼进文档（`src/plugins/board-widget-content-kind.types.ts`、`src/plugins/board-widget-content-kinds.ts:88-127`）；MCP 场景下，`mcp-ui-resource` 把 MCP server 的 `ui://` 资源转成 canvas 预览或可 pin 的 `mcp-app` view（`src/gateway/server-methods/board.ts:320-362`，view 由 transcript 工具调用重建，见 `src/gateway/mcp-app-reconstruction.ts`）。这类内容源由插件/服务器声明，同样不是模型自由文本。

产生规则上，HTML widget 的 `widget_code` 上限 262,144 字符（`WIDGET_CODE_MAX_CHARS`），pinned 文档在 wrapping 后还有 256 KiB UTF-8 的收紧上限；错误（超限、kind 不可用、validateSource 失败、capabilities 未带 pin、缺 inline 客户端且无 presenter 路由）一律以结构化工具错误或 partial 结果返回，不依赖消息文本里找标记。

## 3. 对象模型：身份、事实源与状态

### Canvas 文档

Canvas 文档是“一块托管内容”的最小对象：`cv_<hex>` id、kind（`html_bundle`/`url_embed`/`document`/`image`/`video_asset`）、title、preferredHeight、`surface`、`retentionScope`、`cspSandbox`、entryUrl、entry 文件清单与 manifest.json，落盘在 state dir 下 `canvas/documents/<id>/`（`src/canvas/documents.ts:38-54,336-378`）。文件是事实源；HTTP 层按 manifest 决定是否加 `Content-Security-Policy: sandbox allow-scripts`（`src/canvas/serve.runtime.ts:82-90`）。同一文档可被 assistant 消息引用，也可在 pin 时把 HTML 读出来作为 board widget 的内容（要求 `cspSandbox:"scripts"`，`src/gateway/server-methods/board.ts:310-319`）。canvas 文档不是通用可编辑工程，也没有版本/授权状态；其 manifest 只记录 kind、surface、retentionScope、创建时间与 entry 等元数据，配额内按 createdAt 逐最旧删除（`src/canvas/documents.ts:138-181`）。

### Board widget 与 snapshot

Board 是“一个 session 一张画布”的稳定对象集合。数据结构在 `packages/gateway-protocol/src/schema/board.ts`：

| 对象 | 关键字段 | 语义 |
|---|---|---|
| `BoardSnapshot` | sessionKey、revision、tabs、widgets | 一次读取/一次写入的布局事实源 |
| widget | name、tabId、contentKind（html/mcp-app/plugin）、contentOwner、registeredContentKind、pluginKind、props、presentation/heightMode、sizeW/H、position、grantState、revision、instanceId、declaredSummary、declared、frameUrl/viewTicket/viewGeneration/sandboxUrl | widget 的身份与可访问状态 |
| `BoardTab` | tabId、title、position、chatDock | 分组/侧边 dock 布局 |
| `BoardOp` | tab_create/update/delete/reorder；widget_move/resize/remove | 用户布局编辑的最小变更单位 |

widget name 是稳定地址，分“显式 name”和“生成 identity”两类：无显式 name 时由标题 slug 得到偏好名，并附带 `source:"show_widget"` + `sha256(title)` 的 generated identity，重放相同标题的 pin 会命中既有 widget 而不会新建；冲突时才落到 fallback name（`src/boards/board-store.ts:121-168`、`src/canvas/widget-tool.ts:220-228`）。Board 本身没有单独身份行：revision 由 tab 行的最大 revision 推导，最后一个空 tab 被删即视为 board 消失（`src/boards/sqlite-board-store.ts:168-177`）。

事实源分层：**Agent 数据库**（`board_tabs`/`board_widgets`，懒建 additive schema）保存布局与 HTML/descriptor/declared/grant 权威；**state 目录**保存 canvas 文档原始文件；**transcript**保存消息级的 canvas block/工具 details 引用；**运行实例**（iframe）只持短期 view ticket，不作为任何持久事实。

## 4. 生成、更新与最终化

### HTML widget 的包装与落盘

pinned 路径中真正的“生成”有两步：`buildWidgetDocument` 把模型 HTML 装进带完整 CSP、五段 bridge 注入、设计 token 基础样式和 title 的 document shell（`src/canvas/wrap.ts:89-269`）；然后 Gateway 的 `board.widget.put` handler 再做一次幂等包装并写入 store（`src/gateway/server-methods/board.ts:410-426`）。写入内容不是模型原文：CSP `default-src 'none'; connect-src <declared-or-'none'>`、`script-src 'unsafe-inline'...`、`img-src data:`，inline widget 无外部脚本来源、无网络。HTML 字节会被求 sha256；带声明能力的 widget 首次写为 `grantState:"pending"`，随后由会话 exec 策略（Guarded 人工/auto 模型评审/full 直接授权/Read only 拒绝）裁决，批准后 `granted_sha` 冻结为该字节 hash（`src/gateway/server-methods/board.ts:438-458`、`src/boards/board-store.ts:285-341,365-395`）。

### 更新语义与最终化

同名 widget 再次 put 是整段覆盖：`revision+1`、新 `instanceId`、新 `viewGeneration`；只有内容 kind 一致才允许覆盖，html/registered 的字节 hash 若与冻结授权 hash 相同且声明是已授权子集，才维持 `granted`，否则回到 `pending` 重新走授权（`src/boards/board-store.ts:246-263,287-295`）。失败路径由工具层收口：presentation 失败而 pin 已成功时返回 `status:"partial"` 并保留 board widget，不会回滚已落盘的 board 状态（`src/canvas/widget-tool.ts:469-484`）。

registered（插件 kind）widget 落盘只存 `source`；真正组装发生在授权后的 view 解析，按插件 `composeDocument` 注入插件资源 URL（`src/gateway/board-widget-view.ts:27-77`）。MCP App widget 落盘存 descriptor（server/tool/uiResourceUri/toolCallId），每次开 app view 时从 transcript 重新 mint，非 interactive/授权丢失时退化为只读（`src/gateway/server-methods/board.ts:499-555`）。

## 5. 投影表面与多视图关系

同一输出对象存在多个投影面，内容事实在 Store/DB，投影各自持有访问凭证：

- **assistant 消息内嵌（inline）**：canvas 文档 URL 由 widget-card 在沙箱 iframe 中加载，属于客户端 DOM 面，见 [OpenClaw 消息渲染器调查笔记](../消息渲染器/OpenClaw-消息渲染器调查笔记.md)。
- **session dashboard / workspace board**：pinned widget 显示在 Chat 工作区 dashboard/board 面板，Control UI 通过 `board.get` 拉 snapshot 并对每个可渲染 widget 生成 `frameUrl` 与 `sandboxUrl`（`src/gateway/server-methods/board.ts:166-260`）；网格布局/侧 dock/tab 由 `board.update` 管理。dashboard 是 widget 的“长期住所”，这是本类目真正的对象投影面。
- **当前渠道（current channel presenter）**：渠道插件可为同一 core 工具注册上下文 presenter，`show_widget` 结果可被投到当前 IM 会话（文档示例 Discord Activities“Open widget”按钮，见 `docs/tools/show-widget.md:12,18-20`），工具仍只有一次调用。
- **node panel / 独立设备面板**：`presentation.target:"node_panel"` 时把同一个 wrapped document 交给已配对 widget-panel 能力节点，文档明示该面板第一阶段 render-only（`docs/tools/show-widget.md:110-114`）。

同步契约：inline 与 board 是多份“投影”，其内容由一次 create/put 固化；pin 语义允许消息预览保留，而 dashboard 上另有同名 widget 实例（不同 revision 线）——所以同一视觉 widget 在消息与 dashboard 上可以是两份对象，用户把消息内 widget “Pin to dashboard”是创建动作而非引用共享（`ui/src/pages/chat/components/widget-card.ts:44-94`、`ui/src/pages/chat/components/widget-card.ts:548-560`）。

## 6. 表现类型、依赖与运行环境

| 能力 | 支持 | 边界 |
|---|---|---|
| 静态 HTML/SVG/主题化文档 | 支持（`<svg` 走 svg mode） | 每次进入沙箱 document shell |
| 内联脚本 | 支持 | `script-src 'unsafe-inline'`；被 capture-before-widget 的 bridge 前置 |
| 外部脚本/样式/图片资源 | 仅 registered widget 的插件资源 origin 可入 | inline 一律 `connect-src 'none'` |
| 网络 fetch/XHR | 仅声明并获准的精确 HTTPS origin | 进入 CSP `connect-src`；通配/凭据/路径/query 被拒 |
| iframe/弹出 | 关闭 | CSP `sandbox allow-scripts`（无 allow-popups/allow-same-origin），见 `src/gateway/board-sandbox.ts:27-46` |
| WebRTC/嵌套 frame | 尽力阻断 | `webrtc 'block'` + sandbox host `blockDescendantFrames`，文档承认 WebRTC data-channel egress 为建模残余 |
| host API | 见下节 | 经 MessageChannel bridge 的单请求通道 |

运行位置：widget 代码不在服务器进程或 worker/容器里跑，而是在**客户端宿主 DOM 的隔离 iframe**。inline widget 以 opaque origin（canvas 服务响应头再补 `CSP: sandbox allow-scripts`）；pinned widget 文档描述为“dedicated-origin、double-iframe 的 sandbox host”，代码侧至少可以确认 dashboard frame 由 `/__openclaw__/board/...` ticketed URL 提供 HTML 并以 sandbox host path 处理 CSP 域（`src/gateway/board-sandbox.ts:16-25`、`docs/tools/show-widget.md:20`），double-iframe 的具体代理实现未完整展开验证。token/主题由宿主经 `openclaw:widget-theme` 推送，白名单内 token 落入 CSS 变量（`src/canvas/wrap.ts:190-201`、`src/canvas/wrap.ts:3-27`）。

## 7. 用户交互、事件与错误反馈

用户可做的直接操作集中在两个面：

- **widget 卡/board 单元格**：允许/拒绝能力授权（pending widget）、移除 widget、复制/下载为 PNG（经框内 snapshot bridge 把当前 DOM+canvas 渲成 data URL，超时/不可用回退下载原始 HTML 单文件）、查看 raw details、消息内 widget “Pin to dashboard”、dashboard 上对 MCP App widget 刷新 view。实现面见 `ui/src/pages/chat/components/widget-card.ts:424-560`、`ui/src/components/board/board-widget-cell.ts:177-299`、`ui/src/pages/chat/components/widget-export.ts:83-161`。
- **布局编辑**：tab 增删改/排序、widget move/resize/remove 通过 `board.update` ops 生效；Board handler 每次广播 `board.changed`（`src/gateway/server-methods/board.ts:266-289`）。

widget 内事件（`openclaw.state.emit`）到达 Gateway 后追加为“board notice”，payload ≤8 KiB、5 秒内同内容去重，随后以 `[dashboard] <摘要> on widget <name>` 系统事件进入该 session（`src/boards/board-notices.ts:37-63`）——这是 board 事件唯一的持久落点。错误反馈：动作失败、frame 加载失败、授权卡状态（rejected）等由 board cell/widget card 展示并可重试/移除；无 widget 内日志通道。

## 8. 编辑、版本与协作

编辑能力矩阵（用户/模型）：

| 对象 | 用户可做 | 模型可做 |
|---|---|---|
| 布局（tab/widget 位置/尺寸/移除/tab dock） | 是（board.update ops） | 是（同 RPC / show_widget placement 参数） |
| widget 内容 | 否（本次未找到内容编辑 UI；只有 pin/export/raw 查看） | 是（同名 show_widget 整段覆盖） |
| 能力授权 | 是（pending 的 allow/reject；auto 模式可免人工） | 间接（通过重新声明 + 授权） |
| 历史/分支 | 无 diff/接受拒绝/撤销 | 无 |

版本表达是“单 revision 计数 + 冻结字节授权”：每个内容变化 revision+1、instanceId 与 viewGeneration 旋转，grant 与 revision/instanceId 强校验（过期 ticket 立即失效），但没有 patch/diff、没有多版本回溯、没有协作并发写；并发写由 per-agent DB 事务串行。这些证据表明该对象停留在“可整体替换、可安全重授权”层级，不构成 G4 的协作编辑语义。

## 9. 能力桥、执行位置与权限范围

widget bridge 是唯一的受控宿主通道。它由 wrapper 在 widget 代码运行前先创建 MessageChannel 并向 parent 发送 port offer，宿主只在首次 load 且内容窗口确实是 OpenClaw 托管文档时才采纳，`openclaw` API 在 5 秒 init 超时内由 `openclaw:widget-host-init`（携带 view ticket）激活；桥方法：`prompt.send`、`state.emit`、`data.read`、`action.run`、`cron.trigger`、只读 `host.controlUiBaseUrl`，另有把点击的 http(s) 链接转交宿主打开（禁 popup）的 `host.open`（`src/canvas/wrap.ts:120-182`；宿主侧路由见 `ui/src/lib/board/widget-bridge.ts:146-218`）。

服务端按能力声明执行的最小权限：

| 能力 | 判定条件 | 实现 |
|---|---|---|
| data binding 读取 | declared.tools 含该 bindingId 且 granted | 映射到白名单 handler：`sessions.list/usage.status/usage.cost/cron.list/cron.status/agents.list/health`，或插件 dashboardDataBindings；见 `src/gateway/board-host-tools.ts:99-108,156-185` |
| action 动词 | declared.tools 含 actionId 且 granted，参数按 plugin paramShape 校验 | 插件 dashboardActionVerbs 注册的 write-scoped handler（`src/gateway/board-host-tools.ts:187-220`） |
| cron 触发 | declared.tools 含精确 `cron.trigger:<jobId>` 且 granted | `cron.run mode:force`（`src/gateway/board-host-tools.ts:222-234`） |
| prompt 发送 | 需宿主内 transient user activation；另有 granted `prompt` 才跳过每次确认 | `board.prompt.authorize` 判定 + 宿主确认 UI（`ui/src/lib/board/widget-bridge.ts:163-184`） |
| 网络 | declared.netOrigins 精确 HTTPS origin，授权后进 `connect-src` | `src/boards/board-capabilities.ts:68-106` |

执行位置上，data/action/cron 全部由**宿主 UI 以 widget ticket 调用 Gateway RPC** 完成（“浏览器不在不可信 frame 内解析 data binding”，`docs/tools/show-widget.md:20`）；桥本身是帧内 JS，能力判定在 Gateway。每类授权都绑定到当前 Gateway context 的 plugin registry epoch 与 session work admission（`src/gateway/board-host-tools.ts:38-82`），不能跨进程/重启携带。

## 10. 持久化、恢复、分享与导出

- **board**：`board_widgets` 行保存内容 kind、HTML 字节（html 类）、descriptor、sha256、grant_state、granted_sha、view_generation、manifest（declared、nameIdentity、presentation、注册 instance 等）；写入路径 `src/boards/sqlite-board-store.ts:472-555`、授权 `:557-634`。读为行式重建 snapshot。删除会话时 board rows 一并删除并走归档流程（见 [会话与消息管理调查笔记](../会话与消息管理/OpenClaw-会话与消息管理调查笔记.md)）。恢复方式是重读 DB；本次未找到 board 级导入/导出 RPC。
- **canvas 文档**：状态目录文件 + manifest，随会话配额滚动清理；assistant 消息中的 canvas block 引用在历史重载时恢复 inline 预览。
- **导出**：widget 可复制/下载 PNG（或回退下载原始 HTML 单文件，`ui/src/pages/chat/components/widget-export.ts`）；本次未找到 board 级 JSON/AST 导出或可移植包。

## 11. 模型回流、对象感知与持续维护

- **事件回流**：widget `state.emit` → board event → session system event（`[dashboard] ... on widget <name>`），因此 widget 交互会在**下一个 agent turn** 自动进入模型上下文，无需模型去查询。这是“交互结果回流”的主通道。
- **prompt 回流**：widget `prompt.send` 生成会话内普通 user prompt 并触发正常 agent turn；要求瞬时用户激活、frame 可见聚焦、文本≤4000 字符、拒绝 `/`/`!` 命令前缀、每文档每滚动分钟 ≤10 条（`docs/tools/show-widget.md:124-133`；宿主约束 `ui/src/components/mcp-app-security.ts`）。
- **对象感知与定向修改**：模型“更新既有对象”靠同一 name/generated identity 的 `show_widget(pin:true)` 整段覆盖，而非先查询对象树再打补丁。本次未找到模型侧“列出本会话 board widget 状态/读取某 widget 当前内容”的专用工具入口——消息内可见信息来自工具自身记忆与 transcript；后续回合能可靠感知的只有系统事件与被 pin 成功/部分成功的工具结果。模型感知的精确边界标注为未验证。

## 12. IM 渠道投递（边界说明）

普通文本回复进入 IM 由 auto-reply/source-reply 管线执行：按来源路由与 SourceReplyDeliveryMode 决定用 source delivery、message tool 或 direct send，并对回复 payload 施加渠道插件 `transformReplyPayload` 与 typing 回调（`src/channels/message/reply-pipeline.ts:35-134`）。发送完成得到平台回执，规范化为 `MessageReceipt`（`primaryPlatformMessageId`/`platformMessageIds`/`parts`/thread 与 replyTo 归属，`src/channels/message/receipt.ts:36-122`），该回执是工具卡/交付状态回调和 run 终态判定的依据；写前队列、platform-send lease 与 unknown-after-send 恢复在 `src/infra/outbound/deliver-queue.ts`，属于 [主动Agent与后台任务调查笔记](../主动Agent与后台任务/OpenClaw-主动Agent与后台任务调查笔记.md) 的 durable delivery 主题。widget 对象在 IM 面不落普通文本，而是走渠道 presenter（文档化的 Discord Activities 按钮），其 transport 细节归渠道插件实现，本轮未展开。

## 13. 生命周期、资源治理与性能

| 面 | 上限/治理 | 出处 |
|---|---|---|
| board widget 数量 | 每 session ≤48 | `src/boards/board-store.ts:75` |
| widget HTML 字节 | 256 KiB（wrapped 后仍按上限）；raw widget_code 262,144 字符 | `src/boards/board-store.ts:76`、`src/canvas/widget-tool.ts:32` |
| plugin props | 8 KiB JSON | `src/boards/board-store.ts:77,201-208` |
| canvas 文档配额 | 每 session/agent scope ≤32，超出按 createdAt 删最旧 | `src/canvas/widget-tool.ts:34`、`src/canvas/documents.ts:138-181` |
| view ticket TTL | 20 分钟，内容 revision/viewGeneration 或 Gateway context 代次变化即失效 | `src/gateway/board-view-ticket.ts:12-14` |
| widget 事件 | payload ≤8 KiB、notice ≤500 字符、同内容 5s 去重 | `src/boards/board-notices.ts:4-6` |
| init/快照超时 | host init 5s；PNG snapshot 5s | `src/canvas/wrap.ts:142`、`ui/.../widget-export.ts:3` |
| 客户端运行期 | frame 高度 48–1200px、frame 高度缓存 ≤100 条 | `ui/src/pages/chat/components/widget-card.ts:136-170` |

不可见 widget 无专门的服务端暂停/冻结机制：board 只在被读取/渲染时才由客户端起 iframe；定时器、动画等资源随 iframe 卸载自然释放，Gateway 不托管其生命周期。配额以上限+整批滚动为主，未见跨对象预算调度器。

## 设计取舍与已确认边界

- **消息内 widget 与 dashboard widget 是两套生命周期**：inline 是可滚动清理的会话内托管预览（低持久承诺），pin 才进入带授权/版本/DB 的对象路径。这让“给模型一个轻量可视化”的成本很低，而“长期活对象”有完整治理。
- **授权绑定字节而非信任文本**：grant 冻结 hash，revision/instanceId/ticket 三重校验，内容更新后必须重审；模型声明能力而非拥有能力，网络/动作全部窄口。代价是每次内容更新都可能打断 dashboard 上已授权 widget 的运行状态。
- **对象更新粒度粗**：无 diff/patch/协作历史，替换即版本。这与 G4 画布类产品形成明确分界，也意味着模型无法对既有 widget 做选区级精修。
- **执行在客户端 iframe 而非服务器沙箱**：这是“浏览器双 iframe + CSP/无 same-origin”策略，不是容器/worker 执行；脚本能力由 CSP 与授权边界收敛，残余风险（WebRTC data channel 等）在仓库文档中被显式建模（`docs/tools/show-widget.md:158`）。该策略与本调查的“G3 可执行 artifact”判定不同轴：执行强度高但宿主隔离为主，没有出现服务端任意代码运行面。
- **回流闭环是“会话事件 + 用户态 prompt”**，不是对象可查询 API。模型不能“读某 widget 内存状态”，只能通过被转成系统事件的 notice 与用户确认后的 prompt 感知；持续维护靠对象稳定 name 的重新生成。这是与 Desktop/Agent 风格活对象的关键差异，OpenClaw 的 widget 更像“长在会话里的可交互成果”，而不是环境级常驻代理工件。

## 未验证事项

1. 未启动 Gateway/Control UI/任何渠道或真实 Provider，全部为静态路径；iframe 内的实际渲染、CSP 头生效、MessageChannel 握手与 5s 超时行为未运行验证。
2. pinned widget 的 “dedicated-origin、double-iframe sandbox host”（文档 `show-widget.md:20` 所述）只确认到 board sandbox path/CSP 与 ticketed frame 两层代码，sandbox host 的完整代理实现与 iframe 嵌套结构未全部走通。
3. 授权 auto 模式调用模型评审器（`resolveBoardWidgetApproval` 的动态 import 分支）、Guarded 人工授权与 widget grant/reject UI 的端到端顺序未运行验证。
4. 未确认模型侧是否存在“查询 board widget 列表/内容”的受控工具；只确认 widget 事件回流与 show_widget 覆盖更新两条路径。
5. widget 事件（state.emit）、prompt 确认框、导出 PNG、历史恢复 inline widget 等交互在真实 UI/键盘焦点场景下的行为未运行验证。
6. 渠道 presenter（current channel / node panel，含文档化的 Discord Activities）未在本仓库扩展代码中完整追踪，只核实 core 工具的路由与回执契约。
7. board widget 并发场景（同 session 双客户端 move/resize vs grant vs 内容 put）只确认 DB 事务与 revision 冲突校验，真实竞态行为未验证。

## 关键源码索引

- `src/canvas/widget-tool.ts:251-516`：show_widget 工具——校验、wrap、pin（board.widget.put）、inline canvas doc、presenter 结果与 partial 语义
- `src/canvas/wrap.ts:89-269`：widget document shell——CSP、host bridge、theme/snapshot/size/chat-host 桥
- `src/canvas/documents.ts:336-378`、`serve.runtime.ts:48-111`：canvas 文档落盘/manifest/pruning 与沙箱 HTTP 服务
- `packages/gateway-protocol/src/schema/board.ts`：board snapshot/widget/op/content/grant/ticket 协议 schema
- `src/boards/board-store.ts:222-395`、`sqlite-board-store.ts:472-634`：纯布局/授权快照计算与 SQLite 持久化
- `src/boards/board-capabilities.ts:68-126`：netOrigins/tools 声明规范化、子集判定与 granted 检查
- `src/gateway/server-methods/board.ts:166-700`：board.get/update/widget.put/grant/appView/event/prompt.authorize/data.read/action RPC
- `src/gateway/board-view-ticket.ts:175-239`、`board-http.ts:36-92`、`board-widget-view.ts:17-83`、`board-sandbox.ts:16-46`：view ticket、frame HTTP 授权与 CSP/沙箱
- `src/gateway/board-host-tools.ts:99-220`、`src/boards/board-notices.ts:37-63`：data binding/action/cron 的注册表路由与 widget 事件 notice
- `src/gateway/chat-display-projection.canvas.ts:195-340`、`src/chat/canvas-render.ts:115-332`：canvas 载荷归一与历史消息 canvas block 投影
- `ui/src/lib/board/widget-bridge.ts:140-219`、`ui/src/pages/chat/components/widget-card.ts:44-94,424-560`、`ui/src/pages/chat/components/widget-export.ts:83-161`、`ui/src/components/board/board-widget-cell.ts:177-299`：宿主桥路由与用户交互面
- `src/channels/message/receipt.ts:36-155`、`reply-pipeline.ts:35-134`：渠道投递回执与回复管线交接点
