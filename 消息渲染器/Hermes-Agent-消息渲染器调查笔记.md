# Hermes-Agent 消息渲染器调查笔记

> 调查对象：`E:\works\git\hermes-agent`
>
> 调查更新日期：2026-08-07
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：静态代码调查（未运行、未构建）。重点读取 `tui_gateway/`（Python 网关与事件发射）、`ui-tui/`（Ink/React TUI 渲染链）与 `apps/desktop/src/components/assistant-ui/`（Electron 桌面渲染链），辅以 `web/src`、`apps/shared`、相关测试文件的全局搜索与局部阅读。
>
> 调查范围：消息从“模型流式输出 / 事件流”进入可见 UI 的完整链路，覆盖 TUI（主链）、桌面、web dashboard 三条渲染面；明确排除模型上下文组织（Chat 调查）、经典 CLI Rich 渲染细节、消息网关（Telegram 等）平台适配层。题中“HTML 清洗/iframe 隔离”仅评估文档渲染器自身，不评估 Electron 其他系统界面。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes 的“消息渲染器”不是单一实现，而是共享一个 `tui_gateway` 后端、由多套前端各自渲染的体系。仓库内实际存在四条可见路由：

1. **TUI（同仓主渲染面）**：Node/Ink（React）进程通过 stdio JSON-RPC 与 Python `tui_gateway` 通信（`tui_gateway/server.py`）。Python 侧把 agent 回调翻译成 `message.start / message.delta / message.interim / message.complete / reasoning.delta / thinking.delta / tool.* / subagent.*` 等事件；Ink 侧 `createGatewayEventHandler.ts → turnController（流式缓冲/分段）→ turnStore（nanostores）→ StreamingAssistant/MessageLine → Md/StreamingMd` 自研 Markdown 渲染器落屏。
2. **桌面（Electron + React）**：复用 `tui_gateway` 后端（`apps/shared` 的 `JsonRpcGatewayClient` + WS，`apps/desktop/src/app/session/hooks/use-message-stream`），渲染器基于 `@assistant-ui/react-streamdown`（Streamdown）+ `@streamdown/code`（Shiki） + KaTeX（`katex-memo.ts` 记忆化）。
3. **桌面 dashboard（web）**：`web/src/pages/ChatPage.tsx` 用 xterm.js 嵌入真实 `hermes --tui`（`/api/pty`），主对话不是 React 重写；`web/src/components/Markdown.tsx` 只是一个极简列表式渲染器，用于会话列表/sidebar 等辅助面。
4. **经典 CLI / 网关**：`cli.ts`（prompt_toolkit + Rich）与 `gateway/`（聊天平台）不在本链路的焦点内，仅记录边界。

三个关键设计点已经过源码确认：

- **流式“先缓冲、后分段”模型**：Python 端每个 token 发射 `message.delta`（可在 `history_lock` 下写入 inflight）；TUI 端 `turnController.bufRef` 累积原文，按定时批次把 `boundedLiveRenderText(streaming)` 写入 `$turnState.streaming`（16ms 空闲 / 80ms 输入 / 96ms 滚动节流），`message.complete` 时再做 `finalTail` 去重 + 分段定稿，一次性 `appendMessage` 到 transcript。这是三种不同频率的明确区分：chunk→`message.delta`（网络+节流）、chunk/批次→`streaming` 状态对象（视图）、完成→`msg.complete`+transcript（持久化）。
- **TUI 的 Markdown 是自研的 `markdown.tsx`**，没有使用第三方 Markdown 依赖：`Md`（重内存块解析，行级状态机）+ `StreamingMd`（增量渲染，仅重解析 in-flight tail）。Python 侧曾计划经 `tui_gateway/render.py` 委托 `agent.rich_output`（Rich/ANSI 化），**本次快照中 `agent.rich_output` 模块不存在**（grep 确认仅 `render.py` 与 `tests/tui_gateway/test_render.py` 引用），因此一切时间为 `None`，TUI 实际总是回落到 `markdown.tsx`。
- **没有真实 HTML 清洗边界**：终端字形下、桌面 SVG/Mermaid 用 `dangerouslySetInnerHTML`（返回 `clean`/`svg`），这些是渲染 SVG 片段而不是 HTML+CSS 文档；实际上桌面侧的内容并非由 HTML 进入，而是流式 Markdown→React 节点，故“HTML 清洗”问题退化为“链接协议白名单 + 嵌入 iframe 的 preview 面”。真正的 iframe 与 `dangling` 高级概念只出现在 desktop right-rail `preview-artifact.tsx`（`dangerouslySetInnerHTML`）并公开为 `preview` URL 源预处理，具体注释可见“安全边界”一节（含未验证事项）。

主链路（键盘输入 → 可见消息）已在后文“总体渲染链路”给出。

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
              └─ turnController.ts（segmentMessages + bufRef + 定时节流）→ $turnState（nanoug）
        useMainApp.ts：historyItems: Msg[]（cap MAX_HISTORY=800）
              └─ StreamingAssistant（turn foot）/ MessageLine（定稿）→ Md / StreamingMd / ToolTrail / TodoPanel
```

状态所有权已在 AGENTS.md 明确：`ui-tui` 与 `apps/desktop` 都是与 `tui_gateway` 的“桌面后端”通信的独立渲染器；dashboard web 通过 PTY 嵌入 TUI、因此同一条渲染管线复用于浏览器。

## 必查主题

### 1. 输入模型与内容块数据模型

- **TUI 输入是纯字符串事件流**，网关只发 “text + 少量结构化字段”，TUI 生成 `Msg`（`ui-tui/src/types.ts:116`）：`role('assistant'|'system'|'tool'|'user')`、`text`、`thinking`、`tools[]`、`todos[]`、`panelData`，另有 `kind: 'diff'|'event'|'intro'|'panel'|'slash'|'trail'`、`isMoaReference`、`todoCollapsedByDefault` 等。角色 + 内容混合在一个对象里，由组件根据 `msg.kind`/`msg.role` 分派（见 4）。
- **事件→Msg 的映射集中在 `ui-tui/src/app/turnController.ts`**：`flushStreamingSegment`（bufRef→`Msg`，含 `reasoning tag` 分割，见 `lib/reasoning.ts`）、`pushInlineDiffSegment`（diff-only 段），`recordMessageComplete` 生成 `{finalMessages, finalText, wasInterrupted}`。desktop 侧由 `apps/desktop/src/app/session/hooks/use-message-stream/index.ts`（含 interim 封段）。
- 事件协议类型位于 `ui-tui/src/gatewayTypes.ts`（`GatewayTranscriptMessage` 含 `context/display_kind/display_metadata/name/role/text`）。
- 状态模型：`ui-tui/src/app/turnStore.ts` 的 `TurnState` 承载 `streaming`（可见文本）、`streaming`、`reasoning`、`streamSegments`、`tools`、`activeTools`、`subagents`、`todos` 等——即时渲染走 turnStore，定稿走 useMain 的 `historyItems[]`。

### 2. 流式链路：缓冲、节流与收口

**Python → TUI：**
- `tui_gateway/server.py`：核心 `_stream(delta)`（行 9614）在 `session["history_lock"]` 下 `_append_inflight_delta` 后发射 `message.delta {text}`（可选 `rendered` 若流式渲染器存在）；`message.complete`（行 9870）发射 `{"text": raw, "usage": _get_usage(agent), "status": status}`，另可携带 `reasoning`、`warning`、`response_previewed`、`billing`+`failure_reason`、`rendered`（见 9820–9850）。
- 事件类型白名单 `tui_gateway/ws.py:53` 把 `message.delta / reasoning.delta / thinking.delta` 判为高频帧，做 **token 合批**（`_TOKEN_COALESCE_S=0.033`，约 30fps），任何非流式帧都会先冲刷缓冲确保顺序；WS transport 还 `TCP_NODELAY`（`_disable_nagle`）。
- `event_publisher.py`：桌面侧向 dashboard 回连的 PTY 广播使用队列 `_QUEUE_MAX=256`、daemon 线程、失败静默随丢，永不阻塞 agent 循环（注释明确）。

**TS → 状态：**
- `ui-tui/src/config/timing.ts`：`STREAM_BATCH_MS=16`（打字）、`STREAM_IDLE_BATCH_MS=16`、`STREAM_SCROLL_BATCH_MS=96`、`STREAM_TYPING_BATCH_MS=80`、`REASONING_PULSE_MS=700`。
- `turnController`：
  - `recordMessageDelta` 只 `bufRef += text`；`scheduleStreaming` 用 `streamDelay` 定时把 `boundedLive`（≤16000 字符/240 行，`lib/text.ts:137`）写入 `$turnState.streaming`（`turnController.ts:959` 附近）。
  - `recordInterimMessage`（`display.interim_assistant_messages` 默认开）把 seg 标记为 `interimBoundaryIndex` 后再 flush，`message.text` 后被完整 `finalTail` 去重跳过（见 3 说明）。
  - `recordMessageComplete`（参阅 turnController.ts 前注释）内有 diff 去重、reasoning 沉淀、todos 归档、spawn-tree 快照；`interruptTurn` 把当前 partial+tools 折叠成单条 assistant 消息（`turnController.ts:297`）。

### 3. 列表层：窗口化、高度与滚动锚定

- **TUI 用自定义虚拟化**：`ui-tui/hooks/useVirtualHistory.ts` 常量 `ESTIMATE=4`、`OVERSCAN=20`（曾为 40，“YK node p99 106ms”）、`MAX_MOUNTED=120`（曾为 260，为避免 OOM GC 压力 #46699072 调整）、`COLD_START=30`、`PESSIMISTIC=1`、`QUANTUM=10`；用 `useDeferredValue` + `useSyncExternalStore`，外接 `@hermes/ink` 的 `ScrollBox`。transcript 行由 `messageId(msg):c{cols}` 键驱动（`useMain.ts:342`），**拖拽 resize 时每行重挂载**，用 `RESIZE_COALESCE_MS=32` coalescer 限流到 ≤30fps（`<-mainApp.ts:159`）。
- **桌面列表不虚拟化**，改用**渲染成本预算 + `content-visibility:auto`**：`apps/desktop/.../assistant-ui/thread/list.tsx` `RENDER_BUDGET=300`（单位：parts=1、每512字符+1）、`FIRST_PAINT_BUDGET=20`（首次同步 commit 后 rAF 补全）、“show earlier”分页、不触 scrollTop 以免与 `use-stick-to-bottom` 打架（`list.tsx:40-78`）。
- 行高度：TUI 由 `estimateRows`（`lib/text.ts:308`，带 fence/表格识别）预估算；desktop 用浏览器原生布局 + `contain-intrinsic-size:auto 37.5rem`（list.tsx:542），未用虚拟测量库。

### 4. 消息壳层与角色分派

- 消息组件：`ui-tui/src/components/messageLine.tsx`（`MessageLine = memo`）按 role 分派 `Md`/`StreamingMd`/`ToolTrail`（含 `TodoPanel`）；系统消息（`display_kind=hidden/model_switch/auto_continue`）在 `ui-tui/src/domain/messages.ts` 处理。`ui-tui/src/domain/roles.ts` 的 `ROLE` 表定义助手/系统/工具/用户的 body、glyph、prefix 与主题色。
- 会话/状态壳：`ui-tui/src/components/appLayout.tsx`（含 TranscriptScrollbar、StreamingAssistant 拿 `prevMsg=historyItems[last]`、Activity/Tool activity 区），`streamingAssistant.tsx` 用 `turnStore` 选择器（`streamSegments`/`streaming`/`tools`）渲染回合内的“附随面板”。桌面为 `app/chat/session-view.tsx` + `assistant-ui/thread/*`（`assistant-message`、`user-message`、`system-message`、`messenger-parts`）。
- **操作栏 / 状态反馈**：TUI 在`statusBar` / `activity` / `notice`；desktop 有 `tool-group`、`run-ticker`、message reactions。

### 5. Markdown/代码/富文本管线

**TUI（`ui-tui/src/components/markdown.tsx`）**：
- 顶层 `Md` 把文本按行扫描成块（行状态机而非 AST）：```` 代码 / 数学块(`$$`,`\[`) / heading(ATX+Setext) / hr / 脚注 / 定义列表 / 任务列表 / 数字/无序列表 / 引用 / GFM 表格 / `<details>` 剥离 / `<summary>`→`▶` / MEDIA 行→本地文件链接。表格有三档宽度策略（ideal/proportional/hard + vertical fallback），使用 `@hermes/ink` 的 `stringWidth`。
- 内联用 `INLINE_RE` 一个优先级大的交替表达式（图片→链接→autolink→删除→粗体→斜体→高亮→锚脚→上下标→裸 URL→行内公式）。
- 数学：`lib/mathUnicode.ts:685 tex2Unicode`（希腊名/ℕℤℚℝ/分数/上下标）＋ `U+0001/0002 BOX_OPEN/CLOSE` 哨兵→ `<Text bold inverse>` 高亮笔效果（`markdown.tsx:17`）。
- 高亮：`lib/syntax.ts` 手写 `highlightLine`，仅 8 语言（ts/py/sh/go/rust/sql/json/yaml + 别名）关键字/字符串/数字/注释；diff 语言专用 `+`/`-`/`@@` 背景色。
- 链接：`lib/externalLink.ts` 归一化 URL + `urlSlugTitleLabel` + 异步抓页面标题（`useLinkTitle`/`fetchLinkTitle`，LRU 缓存），无 HTML 标签渲染（纯终端字符）。
- **性能**：`MdCache` 主题键 WeakMap + `Map` LRU 512（跨 remount），`Md = memo`，行级 `useMemo`；`StreamingMd` 用自己的“已定稿块只 tokenize 一次、仅 in-tail 每 delta 重解析 O(tail) + 不回退不变式”。

**桌面（`apps/desktop/src/components/assistant-ui/markdown-text.tsx`）**：使用 `@assistant-ui/react-markdown` 的 `StreamdownTextPrimitive`（模式=`streaming`），preprocess 用 `tailBoundedReMark` 基于 `lib/markdown-preprocess.ts`（含 `$` 货币保护），块边界由 `parseMarkdownIntoBlocksCached`（`lib/markdown-blocks.ts`，`marked` 完整 lex）驱动；数学用 `lib/katex-math.ts`（记忆化 `remark-math`+`rehype-katex`，`singleDollarTextMath:true`）；代码用 `@streamdown/code` + Shiki（异步按需加载，防 chunk 膨胀）；`detectArtifact` → `ArtifactCard`（右栏）；嵌入系统 `embeds/`（youtube/vimeo/twitter/tiktok/spotify/pinterest/maps/instagram）与 `MEDIA:` 直接 `<video>/<audio>`、图片文件可从网关下载；链接拦截 `mediaPath/previewTarget/sessionRef` 类自定义协议。
```
**桌面 dashboard `web/src/components/Markdown.tsx`**：极简块/内联列表解析器，仅 http(s|mailto) 链接可点击，其余 scheme 降级为文本报告（` 安全注释`），用于 sidebar 等辅助文本。

### 6. 结构化内容：工具、reasoning、附件与自定义节点

- 工具 UI：TUI `thinking.tsx` 的 `ToolTrail` 把 `tools[]`/`turnTrail`/`activity` 按组渲染（`parseToolTrailResultLine`…），活跃工具显示 braille spinner + 耗时，verbose args 用 `boundedLiveRenderText`（≤800 字符/12 行）；`ToolCalls`/`TodoPanel`（待确认渲染细节）。`SubagentAccordion` 以树状展示 spawn tree（深度/热度色/sparkline/总览）。
- reasoning：`lib/reasoning.ts splitReasoning`；`thinking` 折叠（`collapsed|truncated|full`），`thinkingPreview` 截取 COT max 160。
- 附件：TUI 无富附件（`MEDIA:` 行→文件链接）；桌面支持媒体文件(重点 下载)、`llm` 会话引用、`preview` 目标（右键预览）。

### 7. 安全边界：HTML、URL、iframe、Artifact

- **TUI**：不渲染 HTML 节点；内容直接被 `Ink` 的 `Text/Link` 消费。链接打开走 `lib/openExternalUrl.ts`（`parseSafeUrl` + 平台命令 + `force`），`<a>` 不落地为 HTML。< 代码块仅高亮。`dangerouslySetInnerHTML` 在 TUI 树中不存在（grep 未命中）。
- **桌面**：标记出 3 处 `dangerouslySetInnerHTML`：`embeds/svg-embed.tsx:29`、`embeds/mermaid-embed.tsx:103,109`、`right-rail/preview-artifact.tsx:91`。这些均渲染“SVG 片段”，且 `preview-artifact.tsx` `clean` 变量此前由 `…clean` 处理（未展开）；iframe 出现在右侧预览（`preview-pane`）与 `UrlEmbed`。`iframe sandbox`、CSP 策略、SVG 内嵌事件清理未获完整确认（见“未验证事项”）。
- 链接协议：desktop `MarkdownLink` 对非 http(s)\\`https: ` /`mailto:` 的 href 直接输出 `rel="noopener noreferrer"` 的 xx 或普通文本；`normalizeExternalUrl` 归一化。`web` 版仅 `<a rel=noreferrer target=_blank>`。
- 引用 `MEDIA`、`sessionRef` 等均为自定义指向的处理,不形成外部 entity。

### 8. 交互状态反馈

- 复制（`lib/clipboard.ts isUsableClipboardText`）、折叠（`<details>`; 桌面 `expandable-block`）、重试 / 停止（`session.interrupt`）、审批（`prompts.tsx` → `approval.request` → `approval.respond`）、预览（`open_preview` RPC, `preview.attach`）、下载（desktop `downloadGatewayMediaFile`）等。
- 状态反馈：TUI `statusBar`/`pushActivity`/`notification.show`（`turnController.showNotice`，busy 时挂起到 turn.end 应用）、桌面 `run-ticker` 等。

### 9. 性能策略

| 面 | 策略 | 依据 |
|---|---|---|
| TUI Markdown | 每块一次 tokenize + 无回滚 + 缓存（`MdCache` LRU）；虚拟列表 + 高度估算 | `streamingMarkdown`/`markdown.tsx` |
| TUI transcript | 虚拟列表（`MAX`/`OVERSCAN`/`QUANTUM`） + `useDeferredValue`；拖拽 coalescing | `useVirtual.c.ts` |
| TUI npm | 流式状态对象 `boundedLiveRenderText`（16K/240行） | `lib/text.ts` |
| 桌面 Markdown | `katex` 记忆化 + 代码延迟、`marked` 块缓存、内容 `visible:auto` | `markdown-text.tsx:471` 等 |
| 桌面列表 | 渲染预算（parts+512字）+ 首屏小预算 + `content-visibility` | `thread/list.tsx` |

测试覆盖见下节索引 `tests/` 与 `ui-tui/src/__tests__`（`markdown/streamingMarkdown/text/virtualHeights/reasoning/messageLine/messages/turn` 等）与 `apps/desktop` 的 `markdown-text.*` 测试。

### 10. 扩展方式与已确认边界

- **TUI**：`domain/roles.ts` + `domain/messages.ts` 是注入点；新增显示词由 Python 事件名录与 `GatewayEvent` 联合确定。新增节点类型需要同时改 `turnController`（分段）、`domain/messages.ts`（持久化）、`messageLine`/`StreamingMd`（渲染）。无插件式渲染扩展模型。
- **桌面**：组件覆盖 + `markdown-text.tsx` 的 `components`、`embeds/` 注册表（`embeds/index.ts`）、`preview-targets` 是较集中的扩展点；`@assistant-ui/react-streamdown` 提供组件替换层。
- **Web**：`components/Markdown.tsx` 是独立的富文本渲染（仅 dashboard 辅助面），不参与 PTY 主链。

## 设计取舍与已确认边界

本节归纳反复出现的设计意图、以及从代码可确认的明确“不做”：

- **Rich 不回退到 `markdown.tsx` 之间的回退**只在 `agent.rich_output` 存在时选择；本快照模块缺失 → 恒为 `None`。这意味 Python 的 ANSI `rendered` 不会注入，`message.delta` 净文本累积（注释提到 `display.final_response_markdown: render` 曾篡改 `rendered` 增量导致丢失，v2 改为始终累积 `text`，见 `turnController.ts:677-682` 处的 #167991）。
- **`message.complete` 常去重内部逻辑**：只在 `finalTail` 中剔除与最终文字重叠的 segment；`response_previewed` 时连已封 interims 也去重（`dedupeStart=interimBoundaryIndex ?? 0`）。Diff 段同理（`finalHasOwnFence`）。这是为了避免“同一 patch 两页”的已知 bug。
- **系统消息不当地"user 气泡"**：`display_kind` 的 `hidden/model_switch/auto_continue` 在 `toTranscriptMessages` 被转成 `kind:event` 或跳过；`pending_reaction_notes` 只进 model input 不进持久化文本（`methods_prompt.py`）。
- **TUI 不渲染 Web 组件语义**：`<details>` 直接丢弃内容（`markdown.tsx:1102` 起 `</details>` 跳过），`<summary>` 变成 `▶ ` 行——这是终端渲染器与 DOM 的边界。
- **桌面主对话 ≠ dashboard 富渲染**：dashboard 无自己的 transcript 渲染器，`web Markdown.tsx` 仅辅助，这削减了可比较的“应对比”面积。
- **性能兜底**：`VERBOSE_TRAIL_MAX=800/12`、`MAX_HISTORY=800`、16600字直播上限、记忆注解引用（`#34089` OOM 事件）等表明"防爆防炸"是刻意约束，不是省略。
- **未发现**：TUI 无 iframe、无 `dangerouslySetInnerHTML`、桌面 `embed` 预览未完全溯源；`web/Markdown.tsx` 仅允许 http(s|mailto)。

## 横向比较字段（本记录对照）

> 下表为各文档渲染面的对照，供同类别笔记横向对比。其中“网关(Telegram等)”因不在范围内标记为“未调查”。

| 维度 | TUI（`ui-tui`，主渲染面） | 桌面（`apps/desktop`） | dashboard（`web`+xterm） |
|---|---|---|---|
| 输入表示 | 事件流→`Msg`（role+kind+text+todos+tools） | 事件→assistant-ui `Message` parts（TextMessagePart 等） | 原始 PTY 字节（xterm 渲染，非结构数据） |
| 流式更新单位 | chunk 累积→电池 16/80/96ms `streaming`；完成时整段 | streaming chunk —— Streamdown 增量块 | 终端字符帧 |
| 列表策略 | 虚拟化（ESTIMATE 4/MAX 120/OVESCAN 20/COLDBEGIN 30） | 渲染预算 + `content-visuality` + 分页“show earlier” | 终端视图 |
| Markdown 引擎 | 自研 `markdown.tsx` + `StreamingMd` | `@assistant-ui/react-streamdown` + `marked`块分析 + `Shiki` + KaTeX | 超简 `Markdown.tsx`（dashboard 尔用） |
| HTML 清洗 | 不需要（无 HTML 输入），文字即渲染 | 仅 SVG 三处 `dangerouslySetInnerHTML`；无 HTML 全量清洗（未确认） | 仅格式输出，无 HTML 输出 |
| Artifact 隔离 | 无（纯文本） | `ArtifactCard`（detectArtifact；reasoning 禁 artifact） | 无 |
| 工具 UI | `ToolTrail`/`Thinking` 树状面板 + `TodoPanel` | `tool-group` + run-ticker | xterm 内 TUI 的 |
| 扩展注册方式 | 组件/domain 硬连；无渲染插件注册表 | `embeds/` 注册表 + Streamdown `components` 覆盖 | 无 |
| 性能策略 | 虚拟列表 + 深 `bounded` + LRU 缓存 + 防重解析 | 渲染预算 + 记忆化 Katex + 异步 Shiki + `content-visible` | xterm WebGL |

- 输入表示：`消息`三者各一（TUI event→Msg；桌面 event→parts；dashboard:PTY 字节）。
- 未调查/不确定：桌面 iframe/CSP/清理、移动端（iOS TUI）、经典 CLI Rich 细节。

## 未验证事项

1. **运行行为**：虚拟列表滚动、`streaming` 闪烁、广播节流、桌面 streaming 无缝性、`content-visibility` 性能、Damper 独立；静态代码无法证明，需真机/真实长会话验证。
2. **桌面安全清洗**：`svg-embed`/`mermaid-embed` 的 `dangerouslySetInnerHTML` 输入是否经过白名单化（目前已存在 `clean`/`cleanSVG` 但未读到实现）；iframe/CSP 配置；`openExternalUrl` 在 Electron 侧是否统一弹性；媒体文件下载的越权（对称 token）校核未覆盖。
3. **`agent.rich_output`**：本次未找到模块（grep 仅命中 `render.py` 与测试），若后续快照引入，则“回退链路”会变化。
4. **经典 CLI 与网关平台**：未覆盖消息网关的文本渲染与 Markdown 清洗（Telegram/Discord 等可能在发送前自行渲染 markdown），不在本次“渲染器”主题内。
5. **其余语言/UI**：iOS 移动端、`native/`、`acp_adapter` 未作渲染侧审查。

## 关键源码索引

- Python 网关：
  - `tui_gateway/server.py`: `_stream` 流式回调(9614)`、`message.complete` 载荷组装(9834-9850)`、`_emit`(1539)`、`_append_inflight_delta`(7100)、`_emit_terminal_turn_error`(7593→7626)、`_agent_cbs`(5612，reason.C/`thinking_callback`/interim)、子代理镜像(5550-5609)、`_pending_reaction_notes`(见 `methods_prompt.py`)。
  - `tui_gateway/ws.py`: WS transport、token 合批(53-60)、`_disable_nagle`(268)。
  - `tui_gateway/event_publisher.py`(PTY broadcast, `_QUEUE_MAX` 备注见注释)。
  - `tui_gateway/render.py`(整个都是回退桥，options)。
- TUI：
  - `src/gatewayClient.ts`、`src/gatewayTypes.ts`、`src/app/createGatewayEventHandler.ts`（事件分派）、`src/app/turnController.ts`（分段/去重）、`src/app/turnStore.ts`、`src/app/useMainApp.ts`(history+虚拟)、`src/app/appLayout.tsx`、`src/app/streamingAssistant.tsx`。
  - `src/components/messageLine.tsx`、`markdown.tsx`、`streamingMarkdown.tsx`、`thinking.tsx`。
  - `src/lib/text.ts`、`syntax.ts`、`mathUnicode.ts`、`externalLink.ts`、`openExternalUrl.ts`、`liveProgress.ts`、`messages.ts`、`reasoning.ts`。
  - `src/hooks/useVirtualHistory.ts`、`src/config/limits.ts`、`src/config/timing.ts`、`src/domain/roles.ts`、`src/domain/messages.ts`。
- 桌面：`apps/desktop/src/app/session/hooks/use-message-stream/index.ts`（事件→状态）、`apps/desktop/src/components/assistant-ui/markdown-text.tsx`（Streamdown 管线）、`.../thread/list.tsx`（列表预算）、`.../embeds/*`、`apps/desktop/src/lib/{markdown-preprocess,katex-math,markdown-blocks,media}.ts`、`apps/desktop/src/lib/external-ter外链.ts`。
- Web：`web/src/pages/ChatPage.tsx`（xterm/PTY）、`web/src/components/Markdown.tsx`、`web/src/lib/api.ts`（`getSessionMessages`）。
- 共享协议：`apps/shared/src/json-rpc-gateway.ts`、`apps/shared/src/websocket-url.ts`。
- 测试：`ui-tui/src/__tests__/{markdown,streamingMarkdown,messageLine,messages,turnController,turnStore,reasoning,thinkingMoaReferenceVisibility,useVirtualHistoryHeights,virtualHeights,text,syntax,externalLink,mathUnicode,emoji,blockLayout,details,gatewayClient,createGatewayEventHandler}.test.ts`；`tests/tui_gateway/test_render.py`；桌面 `assistant-ui/markdown-text.*.test`、web 无主渲染测试。

## 附录：本地调查规范原文（供随后编辑续写时对照）

写入要求、调查深度、证据与结论规则见 `E:\works\git\项目调查笔记\AGENTS.md` 原文；必查 10 项、推荐结构、注意事项与横向比较字段见 `E:\works\git\项目调查笔记\主调查指南：消息渲染器调查指南.md`。本笔记按该指南逐一应答；凡在正文未能覆盖的条目，均已在“未验证事项”或“边界”标注。