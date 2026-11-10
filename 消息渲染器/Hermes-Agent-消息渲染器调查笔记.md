# Hermes-Agent 消息渲染器调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：静态代码调查（未运行、未构建）。重点读取 `tui_gateway/`（Python 网关与事件发射）、`ui-tui/`（Ink/React TUI 渲染链）与 `apps/desktop/src/components/assistant-ui/`（Electron 桌面渲染链），辅以 `web/src`、`apps/shared`、相关测试文件的全局搜索与局部阅读。
>
> 调查范围：消息从“模型流式输出 / 事件流”进入可见 UI 的完整链路，覆盖 TUI（主链）、桌面、web dashboard 三条渲染面；明确排除模型上下文组织（Chat 调查）、经典 CLI Rich 渲染细节、消息网关（Telegram 等）平台适配层。题中“HTML 清洗/iframe 隔离”仅评估文档渲染器自身，不评估 Electron 其他系统界面。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes 的消息渲染由多套前端各自完成，它们共享一个 `tui_gateway` 后端。仓库内实际存在四条可见路由：

1. **TUI（同仓主渲染面）**：Node/Ink（React）进程通过 stdio JSON-RPC 与 Python 网关（`tui_gateway/server.py`）通信，网关把 agent 回调翻译成消息开始、增量、中间、完成四类主事件，以及推理、思考、工具、子代理等旁路事件。事件名以消息增量 `message.delta`、消息完成 `message.complete` 为常见形态，工具类事件统一以 `tool.*` 前缀区分。Ink 侧由 `createGatewayEventHandler.ts` 按事件类型分派，turnController 负责流式缓冲与分段，turnStore（nanostores）承载即时状态，StreamingAssistant 与 MessageLine 再把文本交给自研的 Md/StreamingMd 渲染器落屏。
2. **桌面（Electron + React）**：复用 `tui_gateway` 后端，经 `apps/shared` 的 JSON-RPC 客户端走 WS 通信（事件处理见 §2 与文末索引）；渲染器基于 `@assistant-ui/react-streamdown`（Streamdown），代码高亮交给 `@streamdown/code`（Shiki），数学公式由 KaTeX 记忆化渲染（`katex-memo.ts`）。
3. **桌面 dashboard（web）**：`web/src/pages/ChatPage.tsx` 用 xterm.js 嵌入真实 `hermes --tui`（`/api/pty`），主对话不是 React 重写；`web/src/components/Markdown.tsx` 只是一个极简列表式渲染器，用于会话列表/sidebar 等辅助面。
4. **经典 CLI / 网关**：`cli.ts`（prompt_toolkit + Rich）与 `gateway/`（聊天平台）不在本链路的焦点内，仅记录边界。

三个关键设计点已经过源码确认：

- **流式“先缓冲、后分段”模型**：Python 端每收到一个 token 就发射一次增量事件，并在 `history_lock` 保护下把它写入 inflight 缓冲；TUI 端的 turnController 用 bufRef 累积原文，按定时批次把截断后的直播文本写进 `$turnState.streaming`（16ms 空闲 / 80ms 输入 / 96ms 滚动三档节流），收到 message.complete 后再做 finalTail 去重与分段定稿，一次性 appendMessage 到 transcript。三类频率各有分工：chunk 走 message.delta，叠加网络与节流；批次走 streaming 状态对象，供视图消费；完成走 msg.complete 加 transcript，落到持久化。
- **TUI 的 Markdown 是自研的 `markdown.tsx`**，没有使用第三方 Markdown 依赖：Md 做内存块解析（行级状态机），StreamingMd 做增量渲染（仅重解析 in-flight 尾部）。Python 侧经 `tui_gateway/render.py` 这个渲染桥委托 `agent.rich_output` 做 Rich/ANSI 化，渲染桥按需导入该模块，对外提供单条消息、diff 与流式渲染器工厂。该模块本次仍未找到，桥因此返回 None，TUI 实际回落到 markdown.tsx，`message.complete` 的 `rendered` 字段在该前提下恒缺省（拿到非空结果才附带）。
- **HTML 与隔离面**：TUI 以终端字形渲染文本，不生成 HTML 节点；桌面正文经流式 Markdown→React 节点渲染，`dangerouslySetInnerHTML` 仅用于 3 处 SVG 片段与 artifact 预览 iframe，链接协议做白名单处理（详见第 7 节）。

主链路（键盘输入 → 可见消息）已在后文“系统边界与总体调用链”给出。

## 系统边界与总体调用链

```
用户输入 → composer(useSubmission) → prompt.submit (JSON-RPC 请求)
              └→ tui_gateway/server.py  dispatch → agent.run_conversation()
                     ├─ stream_callback(delta): _append_inflight_delta + message.delta
                     ├─ reasoning_callback:     reasoning.delta（+verbose）
                     ├─ thinking_callback:      thinking.delta
                     ├─ tool_start/complete/progress, subagent.*, moa.*, notice.*
                     └─ result {text,status,...} → message.complete({text,usage,status,[reasoning|warning|...]})
              ↓ stdio/WS JSON-RPC
        gatewayClient.ts（缓冲 ≤2000 事件，15s 启动/120s 请求超时）
              └─ createGatewayEventHandler.ts  switch(ev.type)
                     message.delta   → turnController.recordMessageDelta
                     message.interim → turnController.recordInterimMessage
                     message.complete→ turnController.recordMessageComplete → Msg[] → appendMessage
                     reasoning/thinking/moa/tool/subagent → turnController.record* / upsert*
              └─ turnController.ts（segmentMessages + bufRef + 定时节流）→ $turnState（nanostores）
        useMainApp.ts：historyItems: Msg[]（cap MAX_HISTORY=800）
              └─ StreamingAssistant（turn foot）/ MessageLine（定稿）→ Md / StreamingMd / ToolTrail / TodoPanel
```

状态所有权已在 AGENTS.md 明确：`ui-tui` 与 `apps/desktop` 都是与 `tui_gateway` 的“桌面后端”通信的独立渲染器；dashboard web 通过 PTY 嵌入 TUI、因此同一条渲染管线复用于浏览器。

## 必查主题

### 1. 输入模型与内容块数据模型

- **TUI 输入是纯字符串事件流**，网关只发 “text + 少量结构化字段”，TUI 生成 `Msg`（`ui-tui/src/types.ts`），字段结构如下：

  ```text
  role: 'assistant' | 'system' | 'tool' | 'user'
  text / thinking / tools[] / todos[] / panelData
  kind: 'diff' | 'event' | 'intro' | 'panel' | 'slash' | 'trail'
  isMoaReference / todoCollapsedByDefault 等
  ```

  角色与内容混在同一个 Msg 对象里，由组件按 `msg.kind` 与 `msg.role` 决定用哪种渲染体（见第 4 节）。
- **事件→Msg 的映射集中在 `ui-tui/src/app/turnController.ts`**：flushStreamingSegment 把 bufRef 里的原文落成 Msg，其中 reasoning 标签的切分交给 lib/reasoning.ts；pushInlineDiffSegment 处理只含 diff 的段；recordMessageComplete 产出最终消息列表、最终文本与是否中断三项。桌面侧由 `apps/desktop/src/app/session/hooks/use-message-stream/index.ts` 的入口承担同样的封段工作（含 interim 封段）。
- 事件协议类型位于 `ui-tui/src/gatewayTypes.ts`，其中 GatewayTranscriptMessage 描述一条转录消息，字段包括 context、display_kind、display_metadata、name、role 与 text。
- 状态模型：`ui-tui/src/app/turnStore.ts` 的 TurnState 承载直播文本、reasoning、分段、工具与活跃工具、子代理、待办等状态；即时渲染读 turnStore，定稿后的消息进 useMain 的 historyItems 数组。

### 2. 流式链路：缓冲、节流与收口

**Python → TUI：**
- `tui_gateway/server.py`：核心 `_stream(delta)`（9968 行）在 session 的 history_lock 保护下累积 inflight 增量后发射 `message.delta`，流式渲染器存在时附带 `rendered` 字段。收口事件 `message.complete` 在同一文件的 10232 行发射，携带原文文本、usage 与 status，并按场景另附载荷：

  - 计费墙：`billing` + `failure_reason`（结构化计费墙描述，10206-10209）；
  - `rendered`（10196-10212）、`reasoning`、`warning`、`response_previewed`；
  - `status="error"` 时额外携带 `error`+`recoverable` 字段（10226-10230）。

  收口行为还包括：`interrupted` 状态下以 "Operation interrupted: waiting for model response" 开头的取消元数据文本会被清空，避免被当作代理回复渲染（10180-10188）；无可见文本且带真实错误时用 `Error: <detail>` 兜底成可见文本（10176-10179）。
- 事件类型白名单 `tui_gateway/ws.py` 把 `message.delta / reasoning.delta / thinking.delta` 判为高频帧，做 **token 合批**（`_TOKEN_COALESCE_S=0.033`，约 30fps），任何非流式帧都会先冲刷缓冲确保顺序；WS transport 还 `TCP_NODELAY`（`_disable_nagle`）。
- `event_publisher.py`：桌面侧向 dashboard 回连的 PTY 广播使用队列 `_QUEUE_MAX=256`、daemon 线程、失败静默随丢，永不阻塞 agent 循环（注释明确）。

**TS → 状态：**
- `ui-tui/src/config/timing.ts`：流式节流时间常量如下（单位 ms）：

  ```text
  STREAM_BATCH_MS=16（打字） / STREAM_IDLE_BATCH_MS=16 / STREAM_SCROLL_BATCH_MS=96
  STREAM_TYPING_BATCH_MS=80 / REASONING_PULSE_MS=700
  ```

- turnController 分三处处理流式状态：
  - recordMessageDelta 只把增量文本累加进 bufRef；scheduleStreaming 按 streamDelay 定时把截断后的直播文本写进 `$turnState.streaming`，截断上限为 16000 字符或 240 行（`lib/text.ts`）。
  - recordInterimMessage 在 `display.interim_assistant_messages` 默认开启时，先把当前段标记为 interim 边界再冲刷，message.text 定稿时会整段被尾部去重跳过（见第 3 节）。
  - recordMessageComplete 负责 diff 去重、reasoning 沉淀、todos 归档与 spawn-tree 快照；interruptTurn 把当前 partial 连同已产生的工具行折叠成一条 assistant 消息（入口与注释同在 `turnController.ts`）。

### 3. 列表层：窗口化、高度与滚动锚定

- **TUI 用自定义虚拟化**（`ui-tui/hooks/useVirtualHistory.ts`）：虚拟化常量如下，其中 OVERSCAN 与 MAX_MOUNTED 曾因长会话性能调整（分别为 "YK node p99 106ms" 与避免 OOM GC 压力 #46699072 而收小）：

  ```text
  ESTIMATE=4 / OVERSCAN=20 / MAX_MOUNTED=120 / COLD_START=30
  PESSIMISTIC=1 / QUANTUM=10
  ```

  外层用 useDeferredValue 与 useSyncExternalStore 包裹 `@hermes/ink` 的 ScrollBox；transcript 行键为“消息 id + 列数”（`useMain.ts`），**拖拽 resize 时每行重挂载**，由 32ms coalescer 限流到 ≤30fps（`mainApp.ts`）。
- **桌面列表不虚拟化**，改用**渲染成本预算 + `content-visibility:auto`**（`apps/desktop/.../assistant-ui/thread/list.tsx`）：

  - 渲染预算 RENDER_BUDGET 设为 600，pane 分屏时按挂载的 pane 数量分摊，单窗格至少保留四分之一；
  - 首屏预算 FIRST_PAINT_BUDGET 取 20：首次同步 commit 之后由 rAF 分步补全，每帧补一步的回填步长由 BACKFILL_STEP 控制；
  - MIN_VISIBLE_GROUPS 约束真实分页时至少保留的组数，配合“show earlier”式的向上翻页；
  - 该路径不回写 scrollTop，避免与 `use-stick-to-bottom` 的吸底逻辑互相拉扯（`list.tsx`）。
- **桌面渲染成本按 store/paint 双轨计价**：messageStoreWeight 保护堆内存，按消息归一化成本计价（parts 数 + 每 512 字符 +1）；messagePaintWeight 保护绘制，按折叠后实际渲染形态计价（折叠工具行/思考行 = 1 单位，图片/澄清/委派卡片 = 6 单位，todo 提升出 transcript）。两套权重的实现见 `apps/desktop/src/lib/render-weight.ts`，工具归类的判断函数在同目录的 tool-render-class.ts：

  | 分类 | 判断函数 | 归属工具 |
  |---|---|---|
  | 交付物卡 | `isFileEditTool` | `edit_file`、`patch`、`write_file` |
  | 自绘卡 | `isCardTool` | `clarify`、`delegate_task`、`image_generate` |
  | 静默 | `isSilentTool` | `react_to_message`、`todo` |

  修复方向是“重而短”与“长而轻”的会话统一由同一规则约束。
- 行高度：TUI 由 `estimateRows`（`lib/text.ts`，带 fence/表格识别）预估算；desktop 用浏览器原生布局 + `contain-intrinsic-size:auto 37.5rem`（list.tsx），未用虚拟测量库。

### 4. 消息壳层与角色分派

- 消息组件：`ui-tui/src/components/messageLine.tsx` 中的 MessageLine 是 memo 组件，按 role 分派到 Md、StreamingMd 或 ToolTrail（含 TodoPanel）。系统消息在 `ui-tui/src/domain/messages.ts` 处按 display_kind 分流：hidden、model_switch、auto_continue、personality_switch 四类里，只有 personality_switch 会生成一条可见事件行（kind 为 event、role 为 system、文本为 personality changed）。桌面侧由 `apps/desktop/src/lib/chat-messages/index.ts` 做同样的归类，把它当作 system 角色显示同一句时间线文案。各角色的正文样式、字形、前缀与主题色由 `ui-tui/src/domain/roles.ts` 的 ROLE 表定义。
- 会话壳与状态壳：`ui-tui/src/components/appLayout.tsx` 组装 TranscriptScrollbar、Activity/Tool activity 区，并把上一条消息作为 prevMsg 传给 StreamingAssistant；streamingAssistant 组件用 turnStore 选择器读取分段、直播文本与工具列表，渲染回合内的附随面板。桌面端对应 `app/chat/session-view.tsx` 与 assistant-ui/thread 下的消息部件（assistant/user/system message 与 messenger parts）。
- **操作栏与状态反馈**：TUI 落在 statusBar、activity、notice 三处；桌面端有 tool-group、run-ticker 与 message reactions。

### 5. Markdown/代码/富文本管线

#### 5.1 TUI（`ui-tui/src/components/markdown.tsx`）
- 顶层 `Md` 把文本按行扫描成块（行状态机而非 AST），识别如下块类型：

  ```text
  代码块 / 数学块($$, \[) / heading(ATX+Setext) / hr / 脚注 / 定义列表
  / 任务列表 / 数字与无序列表 / 引用 / GFM 表格 / <details> 剥离 / <summary>→▶ / MEDIA 行→本地文件链接
  ```

  表格宽度按 ideal、proportional、hard 三档策略计算，必要时退化为纵向布局，宽度测量复用 `@hermes/ink` 的 stringWidth。
- 内联元素由一条优先级递减的交替正则统一处理，顺序固定：先图片与链接，再依次匹配 autolink、删除线、粗体、斜体、高亮、锚点脚注、上下标，最后才是裸 URL 与行内公式。
- 数学：lib/mathUnicode.ts 里的 tex2Unicode 负责把公式转成 Unicode（覆盖希腊字母名、ℕℤℚℝ、分数与上下标），再用 U+0001 与 U+0002 两个哨兵字符（BOX_OPEN、BOX_CLOSE）包住片段，交给 Text 的 bold + inverse 呈现高亮效果（`markdown.tsx`）。
- 高亮：语法高亮由 lib/syntax.ts 中手写的 highlightLine 完成，只覆盖 ts、py、sh、go、rust、sql、json、yaml 八种语言及别名，识别关键字、字符串、数字与注释；diff 语言另有 +、-、@@ 三种标记行的背景色。
- 链接：lib/externalLink.ts 先归一化 URL，再用 urlSlugTitleLabel 生成标题回退，并异步抓取页面标题（useLinkTitle 与 fetchLinkTitle，带 LRU 缓存）；终端只输出字符，页面里的 HTML 标签不会进入渲染结果。
- **性能**：MdCache 以主题为键做 WeakMap 缓存，再叠一层容量 512 的 Map LRU，缓存跨 remount 复用；Md 本身是 memo 组件，块内行级结果另有 useMemo 缓存。StreamingMd 的约束更严：已定稿的块只 tokenize 一次，流式尾部每来一个 delta 只重解析该尾部（O(tail)），并保持解析不回退。

#### 5.2 桌面（`apps/desktop/src/components/assistant-ui/markdown-text.tsx`）

使用 `@assistant-ui/react-markdown` 的 `StreamdownTextPrimitive`（模式=`streaming`）。管线分四段：

- **预处理与分块**：流式文本先经 tailBoundedReMark 做尾部截断重排（基于 `lib/markdown-preprocess.ts`，其中包含 `$` 货币符号保护），块边界由 parseMarkdownIntoBlocksCached 用 marked 做完整词法分析后缓存（`lib/markdown-blocks.ts`）；
- **数学**：`lib/katex-math.ts` 对 remark-math 与 rehype-katex 做记忆化，并开启单美元符行内公式；
- **代码**：`@streamdown/code` 配合 Shiki 渲染，语法高亮模块按需异步加载，以控制 chunk 体积；
- **Artifact**：detectArtifact 识别出构件后交给 ArtifactCard 渲染在右栏。

嵌入与媒体：`embeds/` 按平台注册视频、音频、社交帖与地图嵌入，`MEDIA:` 行直接渲染为 video/audio 元素，图片文件可从网关下载；`mediaPath`、`previewTarget`、`sessionRef` 等自定义协议由渲染器拦截解析。

推理摘要块修复：gpt-5.x 等“按完成 part 推送 delta”的模型在 chat 线上会把相邻摘要块粘成 `**One****Two**`，渲染器在 `ReasoningTextPart` 处用 `separateGluedReasoningBlocks`（`lib/reasoning-blocks.ts`，`message-parts.tsx`）幂等插入换行拆块（后端已随 delta 插断行，此修复覆盖历史持久文本与仍粘合的 provider）。

#### 5.3 桌面 dashboard（`web/src/components/Markdown.tsx`）

极简块/内联列表解析器，仅 http(s|mailto) 链接可点击，其余 scheme 降级为文本报告，用于 sidebar 等辅助文本。

### 6. 结构化内容：工具、reasoning、附件与自定义节点

- 工具 UI：TUI 的 `thinking.tsx` 里，ToolTrail 把工具调用、回合轨迹与活动记录按组渲染，活跃工具带 braille spinner 与耗时，verbose 参数用 boundedLiveRenderText 截到 800 字符、12 行以内；ToolCalls 与 TodoPanel 的渲染细节待确认。子代理由 SubagentAccordion 以树状展现 spawn tree，用深度与热度着色，并附 sparkline 与总览。
- reasoning：`lib/reasoning.ts` 的 splitReasoning 负责切分推理与正文，thinking 内容可折叠为 collapsed、truncated、full 三态，预览由 thinkingPreview 截取 COT 前 160 字。
- 附件：TUI 无富附件，MEDIA: 行降级成文件链接；桌面支持下载媒体文件、引用 llm 会话与打开 preview 目标（右键预览）。
- 桌面工具行的数据装配：会话恢复或重渲染时，storedToolMessagePart 优先从 toolMessage.args 解析完整参数重建命令，context 字段（80 字显示预览）只作标题侧占位，工具行因此不会停留在截断预览上（`apps/desktop/src/lib/chat-messages/index.ts:860-874`）。
- 连接操作拥有专用工具卡。`manage_connections` 的工具行绑定后端 operation id，只消费连接请求、连接更新和状态查询返回的权威快照；卡片可重试失效授权、跳过目标或 Continue 结算，结算后退化为静态逐目标摘要，不在前端自行推断连接状态（`apps/desktop/src/components/assistant-ui/connector-tool.tsx`，`apps/desktop/src/store/connection-request.ts`）。

### 7. HTML、Artifact 与安全隔离

- **TUI**：内容全以终端字形呈现，由 Ink 的 Text 与 Link 组件消费纯文本，整棵渲染树中 grep 不到 `dangerouslySetInnerHTML`，代码块只做文本着色。外链打开统一走 `lib/openExternalUrl.ts`：parseSafeUrl 先做协议白名单校验，再按平台拼接打开命令，force 参数用于二次确认。
- **桌面**：正文经流式 Markdown 转成 React 节点，`dangerouslySetInnerHTML` 仅出现在三处 SVG 片段输出（svg-embed、mermaid-embed、right-rail/preview-artifact）；iframe 用于右侧 preview-pane 与 UrlEmbed 的预览面。
- **链接协议**：桌面的 MarkdownLink 遇到非 http(s)/mailto 的 href 时输出普通文本或带 rel="noopener noreferrer" 的可点击链接，URL 先由 normalizeExternalUrl 归一化；web 版统一输出带 rel="noreferrer" target="_blank" 的 a 标签。MEDIA、sessionRef、preview 等自定义协议由渲染器定向解析并在应用内消费。
- iframe sandbox 与 CSP 配置未完整确认，归入“未验证事项”。

### 8. 交互状态反馈

- 交互入口按操作类型分布：
  - 复制由 `lib/clipboard.ts` 的 isUsableClipboardText 判定可用性；
  - 折叠用 `<details>`，桌面端对应 expandable-block；
  - 重试与停止走 session.interrupt 请求；
  - 审批由 `prompts.tsx` 发起 approval.request，再由 approval.respond 回填结果；
  - 预览由 open_preview RPC 打开，随后以 preview.attach 挂载目标；
  - 下载在桌面端调用 downloadGatewayMediaFile。
- 状态反馈：TUI 侧由 statusBar 展示常驻状态，pushActivity 与 notification.show 追加临时提示，其中 showNotice 在 agent busy 时先挂起，等 turn.end 再应用；桌面端对应 run-ticker。

### 9. 性能策略

| 面 | 策略 | 依据 |
|---|---|---|
| TUI Markdown | 每块一次 tokenize + 无回滚 + 缓存（`MdCache` LRU）；虚拟列表 + 高度估算 | `streamingMarkdown`/`markdown.tsx` |
| TUI transcript | 虚拟列表（`MAX`/`OVERSCAN`/`QUANTUM`） + `useDeferredValue`；拖拽 coalescing | `useVirtual.c.ts` |
| TUI 流式 | 流式状态对象 `boundedLiveRenderText`（16K/240行） | `lib/text.ts` |
| 桌面 Markdown | `katex` 记忆化 + 代码延迟、`marked` 块缓存、内容 `visible:auto` | `markdown-text.tsx` 等 |
| 桌面列表 | 渲染预算（store/paint 双轨定价，`RENDER_BUDGET=600` 按窗格分摊）+ 首屏小预算分步回填 + `content-visibility` | `thread/list.tsx`、`lib/render-weight.ts`、`lib/tool-render-class.ts` |

测试覆盖见下节索引 `tests/` 与 `ui-tui/src/__tests__`（`markdown/streamingMarkdown/text/virtualHeights/reasoning/messageLine/messages/turn` 等）与 `apps/desktop` 的 `markdown-text.*` 测试。

### 10. 扩展方式与已确认边界

- **TUI**：扩展点挂在 `domain/roles.ts` 与 `domain/messages.ts` 两处；新增一个显示词要同时改 Python 侧事件名录与 GatewayEvent 类型。新增节点类型还牵动三段：turnController 的分段、domain/messages.ts 的持久化、messageLine 与 StreamingMd 的渲染。TUI 没有插件式的渲染扩展模型。
- **桌面**：扩展点集中在组件替换层：`markdown-text.tsx` 暴露 components 覆盖入口，embeds 目录持有嵌入式渲染注册表（embeds/index.ts），preview-targets 决定预览去向；组件替换能力本身由 @assistant-ui/react-streamdown 提供。
- 外部编码 Agent 的导入转录被标记为 foreign history；Markdown 渲染器对这类历史不加载图片，也不挂载实时 transcript directives，避免导入文本获得当前会话的活能力（`apps/desktop/src/components/assistant-ui/markdown-text.tsx`，`hermes_cli/foreign_sessions.py`）。
- **Web**：`components/Markdown.tsx` 是独立的富文本渲染器，只服务 dashboard 辅助面，PTY 主链不经过它。

## 设计取舍与已确认边界

本节归纳反复出现的设计意图、以及从代码可确认的明确“不做”：

- **Rich/ANSI 渲染回退**只在 `agent.rich_output` 可用时才被选中。桥接模块 `tui_gateway/render.py` 位于仓库中，被桥接的模块在仓库范围内未找到，桥因此返回 None。Python 侧生成的 ANSI 渲染结果随之缺席，`message.delta` 的净文本始终按纯文本累积（说明见 turnController.ts 处引用的 #167991）。
- **message.complete 的段去重**：只在 finalTail 中剔除与最终文字重叠的段；response_previewed 为真时，已封口的 interim 段也一起参与去重，起始位置取 dedupeStart = interimBoundaryIndex ?? 0。diff 段按同一思路处理，判据是 finalHasOwnFence。这套逻辑针对“同一 patch 出现在两页”的已知 bug。
- **系统消息的事件行呈现**：display_kind 为 hidden、model_switch 或 auto_continue 的消息，在 toTranscriptMessages 处被改写成事件行或直接跳过；pending_reaction_notes 只作为模型输入参与，持久化文本里同样不写入它（`methods_prompt.py`）。
- **终端渲染器对 details 与 summary 的处理**：details 的开始与结束标签之间的内容整体跳过，summary 改写成一行以 ▶ 开头的摘要（`markdown.tsx`）。这一层是终端渲染器与 DOM 的分界。
- **桌面主对话与 dashboard 富渲染分离**：dashboard 没有自己的 transcript 渲染器，富文本只借 web 版 Markdown.tsx 兜底辅助面。
- **性能兜底**：verbose 工具轨迹上限 800 字符/12 行、历史保留 800 条、直播文本 16000 字上限（`lib/text.ts`）以及按记忆注解引用的 #34089 OOM 事件，都属于有意设置的约束。
- **本次未找到**：TUI 侧的 iframe 与 `dangerouslySetInnerHTML` 均未出现，桌面 embed 预览的完整来源尚待追溯；web 版 Markdown.tsx 只放行 http(s) 与 mailto 协议。

## 重连回放与渲染输入

共享 JSON-RPC 客户端会对每个 session 保存最近事件序号，重连后向后端补取缺口，并通过与实时帧相同的分发器投递（`apps/shared/src/json-rpc-gateway.ts`、`522-523`）。因此渲染层的输入已不再只能假定“连接期间连续到达”；UI 仍须依赖既有事件幂等与状态归属来避免把已显示的增量重复物化。静态阅读未验证断网中的最终视觉结果。

## 未验证事项

1. **运行行为**：虚拟列表的滚动手感、streaming 状态的闪烁、广播节流、桌面流式的无缝性、content-visibility 的实际性能以及 Damper 的独立性，都要在真机与真实长会话中观察，静态代码得不出结论。
2. **桌面安全清洗**：svg-embed 与 mermaid-embed 两处 dangerouslySetInnerHTML 的输入是否经过白名单化，目前只看到 clean 与 cleanSVG 两个函数、实现未读到；iframe 与 CSP 配置、openExternalUrl 在 Electron 侧的平台适配一致性、媒体文件下载对对称 token 的越权校核，均未覆盖。
3. **agent.rich_output**：本次仍未找到该模块，桥接层 tui_gateway/render.py 存在，导入失败时返回 None；若后续快照引入该模块，回退链路会随之变化。
4. **经典 CLI 与网关平台**：消息网关侧的文本渲染与 Markdown 清洗本次未覆盖，Telegram、Discord 等平台可能在发送前自行渲染 markdown，这部分落在渲染器主题之外。
5. **其余语言/UI**：iOS 移动端、native/ 目录与 acp_adapter 三处的渲染侧均未审查。

## 关键源码索引

- Python 网关：
  - 事件发射与回合执行已从 `tui_gateway/server.py`（现为 1,705 行 facade）拆到兄弟模块：`tui_gateway/prompt_turn.py`（`_run_prompt_submit`、流式回调与 message.complete 载荷组装、`render_message` 调用）、`tui_gateway/session_auto_continue.py`（`_emit_terminal_turn_error`、终态兜底）、`tui_gateway/session_history.py`（`_append_inflight_delta`）、`tui_gateway/server.py`（`_event_frame`）；子代理镜像与 `_pending_reaction_notes` 仍在原位置（`methods_prompt.py`）。
  - `tui_gateway/ws.py`: WS transport、token 合批（`_TOKEN_COALESCE_S=0.033`，约 30fps）、`_disable_nagle`。
  - `tui_gateway/event_publisher.py`(PTY broadcast, `_QUEUE_MAX` 备注见注释)。
  - `tui_gateway/render.py`(整个都是回退桥，options)。
- TUI：
  - `src/gatewayClient.ts`、`src/gatewayTypes.ts`、`src/app/createGatewayEventHandler.ts`（事件分派）、`src/app/turnController.ts`（分段/去重）、`src/app/turnStore.ts`、`src/app/useMainApp.ts`(history+虚拟)、`src/app/appLayout.tsx`、`src/app/streamingAssistant.tsx`。
  - `src/components/messageLine.tsx`、`markdown.tsx`、`streamingMarkdown.tsx`、`thinking.tsx`。
  - `src/lib/text.ts`、`syntax.ts`、`mathUnicode.ts`、`externalLink.ts`、`openExternalUrl.ts`、`liveProgress.ts`、`messages.ts`、`reasoning.ts`。
  - `src/hooks/useVirtualHistory.ts`、`src/config/limits.ts`、`src/config/timing.ts`、`src/domain/roles.ts`、`src/domain/messages.ts`。
- 桌面：`apps/desktop/src/app/session/hooks/use-message-stream/index.ts`（事件→状态）、`apps/desktop/src/components/assistant-ui/markdown-text.tsx`（Streamdown 管线）、`.../thread/list.tsx`（列表预算）、`.../embeds/*`、`apps/desktop/src/lib/{markdown-preprocess,katex-math,markdown-blocks,media}.ts`、`apps/desktop/src/lib/external-links.ts`（外链）。
- Web：`web/src/pages/ChatPage.tsx`（xterm/PTY）、`web/src/components/Markdown.tsx`、`web/src/lib/api.ts`（`getSessionMessages`）。
- 共享协议：`apps/shared/src/json-rpc-gateway.ts`、`apps/shared/src/websocket-url.ts`。
- 测试：`ui-tui/src/__tests__/{markdown,streamingMarkdown,messageLine,messages,turnController,turnStore,reasoning,thinkingMoaReferenceVisibility,useVirtualHistoryHeights,virtualHeights,text,syntax,externalLink,mathUnicode,emoji,blockLayout,details,gatewayClient,createGatewayEventHandler}.test.ts`；`tests/tui_gateway/test_render.py`；桌面 `assistant-ui/markdown-text.*.test`、web 无主渲染测试。
