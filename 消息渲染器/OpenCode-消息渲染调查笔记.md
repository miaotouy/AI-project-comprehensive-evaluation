# OpenCode 消息渲染器调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：只读源码静态梳理 part 数据模型、SSE 到 store 的更新链、渲染组件、markdown 管线与性能策略；未运行构建与浏览器验证
>
> 调查范围：Web（`packages/app` + `packages/session-ui` + `packages/ui`）与 TUI（`packages/tui`）两条渲染链路；桌面端（Electron）复用 app 渲染，仅核实壳层边界；UI 行为均为静态确认，视觉效果需运行验证
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的消息渲染核心已从 app 迁入独立包 **`packages/session-ui`**（Web 端），由 `packages/app` 导入。渲染器接收的不是事件流而是最终 part 数组（`sync().data.part[msgId]`），流式增量通过 `part_text_accum_delta` 通道与 part 文本合并。markdown 管线为「marked 切块 → Web Worker 解析+shiki 高亮 → 主线程 DOMPurify → morphdom/增量 token span 写 DOM」：解析器与管线实现分别在 `packages/ui/src/context/` 与 `packages/session-ui/src/components/`。列表层用 `@tanstack/solid-virtual` 虚拟化 + 行复用，TUI 使用 opentui 内置 markdown 组件与 tree-sitter 代码高亮。各环节定位见文末 §12 关键源码索引。

关键事实（快照 1f94d8a）：

- **Part 12 种类型**与组件注册表 `PART_MAPPING`（`session-ui/src/components/message-part.tsx:250`）；工具组件经 `ToolRegistry.register` 注册 14 个（:1776-2621），未注册走 `GenericTool`。
- **流式期间是「先更新 state，Solid 再渲染」，但 markdown 正文是命令式 DOM 补丁**：非 code 块 morphdom 增量替换、code 块按 token 增量追加/裁剪（markdown.tsx:589-706）。
- **SSE 事件 16ms 批量 flush + delta 拼接**（`app/src/context/server-sdk.tsx:79-245`）。
- **markdown 解析在 Web Worker**，shiki 主题 `OpenCode`（全部 token 颜色映射 CSS 变量），**无行号**；katex 支持、Mermaid 不支持（仅出现在语言字典）。
- **DOMPurify 后置清洗**：`USE_PROFILES:{html,mathMl}`、FORBID_TAGS/FORBID_CONTENTS 含 style/script、ADD_TAGS svg/path（markdown-cache.tsx:13-32）。
- **文本节流**：增量 ≤512 字符立即显示，否则按 24ms 步进且在标点处截断（`PacedMarkdown`，message-part.tsx:252-334）。
- **工具分组**：连续上下文工具（read/glob/grep/list）合并为一个 context 组渲染（message-part.tsx:607、663-705、1043-1151）。

## 总体渲染链路

```text
服务端事件（session.ts:631-645 发布 message.updated / message.part.updated / message.part.delta）
  → SSE /event（handlers/event.ts:25-87，10s heartbeat）
  → App server-sdk.tsx 读取循环（for await）→ coalesceServerEvents 拼接 delta → 16ms flush
  → server-sync.tsx apply → server-session.ts 投影（part_text_accum_delta 累积 + produce 就地追加）
  → sync().data.part[msgId]（Solid store）
  → message-timeline.tsx：constructSessionMessageRows → createVirtualizer（虚拟行）
  → renderTimelineRow 分派 → MessagePart（PART_MAPPING 分派 part 组件）
  → TextPartDisplay → PacedMarkdown → markdown-stream 切块 → Worker parse（shiki）→ DOMPurify
  → morphdom / token span 增量写 DOM
```

## 1. 消息与内容块数据模型

- **Part 联合**（schema/src/v1/session.ts:357-370）共 12 种：

  ```text
  TextPart / SubtaskPart / ReasoningPart / FilePart / ToolPart / StepStartPart
  / StepFinishPart / SnapshotPart / PatchPart / AgentPart / RetryPart / CompactionPart
  ```
- 关键结构（schema/src/v1/session.ts）：TextPart 带 synthetic/ignored/time/metadata（:102-116）；ReasoningPart 记 time.start/end（:118-128）；FilePart 带 mime/filename/url/source（:171-179），source 支持 file/symbol/resource（:166-169）；ToolPart 带 callID/tool/state（:315-325），ToolState 四态按 status 判别（:259-313）。
- **消息**：`User`（role:"user"）与 `Assistant`（role:"assistant"，含 time.completed/error、parentID、finish/cost/tokens 等字段，:332-488）；`WithParts = {info, parts}`（:493-500）。
- 渲染输入：`MessageTimeline` 读 `sync().data.part[msgId]`（message-timeline.tsx:313），`MessagePartProps` 携带 part/message 与 open、defer、virtualizeDiff、onContentRendered 等渲染控制项（message-part.tsx:193-206）。

## 2. 流式数据到 UI 的更新链

- **事件产生**（packages/opencode/src/session/processor.ts）：推理 start/delta/end（:280-313）、文本 delta（:499-508）、工具输入 start/delta/end 与工具调用（:315-351）；`updatePartDelta` 发 `message.part.delta`（session.ts:879-887），`updatePart` 发 `message.part.updated`（session.ts:637-645）。
- **SSE 传输**：`handlers/event.ts:25-87`（Queue.unbounded + 目录过滤 + heartbeat）；`server-sdk.tsx:260-317` 读取循环，v1/v2 协议按 `server-compat.ts:86-92` 切换，v2 事件经 `adaptServerEvent` 映射（:28-57）。
- **合并与批量**：`enqueueServerEvent` 同 key 覆盖（:68-77）；`coalesceServerEvents` 拼接连续 `message.part.delta`（:79-139）；`flush()` 每 `FLUSH_FRAME_MS=16` 派发（:227-245）；断线 250ms 重连（:307-308）。
- **Store 投影**（`app/src/context/server-session.ts`）：按事件类型分别处理：

  - `message.updated` 与乐观合并按时间序键 `messageKey = time.created + id` 二分插入（`utils/session-message.ts:19-26` 的 `messageKey`/`compareMessages`，调用点 :1051、:1342）；`message.removed` 用 `findIndex` 按 id 定位删除（:1083-1089）；
  - `message.part.updated` 按 part id 二分插入/替换并删 accum（:1094-1189）；`message.part.delta` 写入 `part_text_accum_delta`（deltaBases 记录 base）并 `produce` 就地追加（:1190-1217）；
  - v2 事件经 `server-session-v2-reducer.ts` 的 `createV2SessionReducer` 投影回 v1 形态（reduce 在 :17 起，调用点 server-session.ts:940）；global-sync 投影器同用 `messageKey`（`event-reducer.ts:279` 二分、:299 `findIndex` 删消息）；TUI 端一致（`tui/src/context/sync.tsx:54-58` 的 `compareMessage`/`messageKey`、:328）。
- **DOM 更新**：Solid store 变化触发重渲染；markdown 正文例外——`Markdown` 组件对非 code 块用 morphdom 命令式替换（跳过 copy 按钮节点，markdown.tsx:589-633）、对 code 块用 worker 返回的 stable/unstable token 数组增量 span 追加/裁剪（:635-706，`renderedCodeTokens` WeakMap :55）。
- **节流**：`PacedMarkdown`/`createPacedValue`（message-part.tsx:252-334）：增量 ≤512 字符立即显示，否则按 `TEXT_RENDER_PACE_MS=24` 分步、`TEXT_RENDER_SNAP` 标点处截断。
- **完成收口**：`AssistantMessage.time.completed` 出现即 `streaming=false`（message-part.tsx:1704-1706）；会话执行结果事件（succeeded/failed/interrupted）→ 会话状态归为 idle（server-session.ts:964-970）；`session.retry.scheduled` → 重试状态（:971-977）。

## 3. 消息列表、窗口化与滚动

- **虚拟化**：`createVirtualizer`（@tanstack/solid-virtual，message-timeline.tsx:414-454），配置如下：

  ```text
  estimateSize=60 / overscan:50 / anchorTo:"end" / followOnAppend:true
  + 自定义 rangeExtractor（:445-453）
  ```
- **行模型**：`TimelineRow` 9 种标签（timeline-row.ts:8-41）：

  ```text
  TurnGap / CommentStrip / UserMessage / TurnDivider / AssistantPart / Thinking
  / DiffSummary / Error / Retry
  ```

  `constructMessageRows`（rows.ts:100-231）含 interrupted 拆分（:128-144）；投影的 user 消息按 `compareMessages` 插入有序位置（rows.ts:75-82）。revert 边界定位用 `findIndex`+`slice`（message-timeline.tsx:288-292）。
- **行复用**：`reuseTimelineRows`（row-reconciliation.ts:6-29）按 key 复用旧行，稳定 context 组 key（:31-56）。
- **高度测量**：`VirtualTimelineRow`（message-timeline.tsx:1279-1343）绝对定位 + `virtualizer.measureElement`；`resizeItem` 覆写在尺寸突变（>视口高）时钉住视口行（:466-493）；`timelineCache` 保存测量快照与 toolOpen，上限 16（:91、540-550）。
- **自动滚动**：`createAutoScroll`（packages/ui/src/hooks/create-auto-scroll.tsx:13-237）按如下规则贴底与回贴：

  - 距底 <10px 视为贴底（:134-137）；
  - 1.5s 窗口内不算用户滚动（:41-64）；
  - ResizeObserver 同帧回贴（:172-187）；
  - working 结束 300ms settling（:189-205）。

  页面层 `updateScrollState`（app/src/pages/session.tsx:1520-1529）。
- **hash 锚点**：`useSessionHashScroll`（use-session-hash-scroll.ts:6-202），seek rAF 重试最多 4 次，与自动滚动互斥。

## 4. 消息壳层与角色分派

- **行渲染**：`renderTimelineRow` switch（message-timeline.tsx:1118-1273）：UserMessage → `<Message>`（:1182-1188）；AssistantPart → `renderAssistantPartGroup`（:1021-1087），context 组进 `ContextToolGroup`、part 组进 `MessagePart`；Thinking → `TimelineThinkingRow`（TextShimmer + TextReveal）；Retry → `SessionRetry`；Error → `Card variant="error"`。
- **角色分派**：`Message` 组件按 `message.role` 分派（message-part.tsx:936-963）→ `UserMessageDisplay`（:1181-1392）/ `AssistantMessageDisplay`（:965-1041）。
- **Part 组件注册**：`PART_MAPPING`（:250）把 tool/compaction/text/reasoning 分别映射到 `ToolPartDisplay`、`CompactionPartDisplay`、`TextPartDisplay`（:1654-1757）、`ReasoningPartDisplay`（:1759-1774），并支持 `registerPartComponent`（:932-934）扩展；未注册类型不渲染。可见性过滤 `renderable`（:711-720）：todowrite 隐藏、question 在 pending/running 时隐藏、text 需非空、reasoning 需开启摘要设置。
- **操作栏**：用户消息底部 revert + copy（:1340-1389）；assistant text part 底部 copy + meta（agent · model · 时长 · interrupted，:1737-1753，仅最后一个非空 text part 显示 :1708-1719）；代码块右上角悬浮 copy（markdown.tsx:204-237）；会话头部菜单：重命名/分享/导出/归档/删除（message-timeline.tsx:1526-1860）。

## 5. Markdown、代码与富文本管线

- **文件分布**：本节的解析器与主题（marked-parser.tsx、marked-theme.tsx）及测试在 `packages/ui/src/context/`；管线实现（markdown.tsx、markdown.worker.ts、markdown-stream.ts、markdown-cache.tsx、markdown-inline-code-kind.ts、markdown-worker*.ts、markdown.css）均在 `packages/session-ui/src/components/`。

- **解析器**：`marked`（非 remark/rehype）+ `marked-shiki` + 自定义 katex 扩展（`packages/ui/src/context/marked-parser.tsx:5-18`）；link renderer 强制 `class="external-link" target="_blank" rel="noopener noreferrer"`（:9-12）。
- **管线顺序（Web Worker 内）**：
  1. **切块/投影**：`markdown-stream.ts` `stream(text, live)`（:53-86）用 `marked.lexer` 切 `Block[]`（full/live/code 三态），`project()` 增量投影只更新尾部（:88-121），`remend` 补全未闭合语法（:49-51）。
  2. **解析+高亮**：`markdown.worker.ts` `parse`（:63-69）；流式代码块用 `ShikiStreamTokenizer`（@shikijs/stream）`enqueue` 增量（:112-132）返回 `{reset,stable,unstable}` token；完成块 `codeToTokens`（:93-110）。
  3. **sanitize**：主线程 `sanitizeMarkdown`（markdown.tsx:461；markdown-cache.tsx:35-38）。
  4. **DOM 写入**：`updateBlock`（markdown.tsx:589-633）；`updateCodeBlock` 逐 token 生成 `<span style=...>`（:635-717）。
  5. **装饰**：`decorate`（:278-286）：每个 pre 包 `data-component="markdown-code"` 外壳 + copy 按钮（:208-237）、内联 code 分类（:268-276，识别 path/url）、内联代码 URL 转链接（仅 `^https?://`，:239-266、:103-114）。
- **代码高亮**：shiki 主题 `OpenCode`（`packages/ui/src/context/marked-theme.tsx:3-372`，token 颜色映射 CSS 变量）；`tabindex:false`；**无行号**；语言按 `bundledLanguages` 懒加载（markdown.worker.ts:89-91），未知语言回落 text。
- **数学**：katex `renderToString`（marked-parser.tsx:63-67，throwOnError:false），inline `\(...\)`、block `$$...$$`。
- **Mermaid**：**不支持渲染**（仅作为语言表条目出现，markdown-inline-code-kind.ts:706）。
- **缓存**：`markdown-cache.tsx:40-53` LRU max=200；首页预载 `preloadMarkdown`（app/src/pages/home/home-sessions-controller.tsx:120）。
- **Worker 基础设施**：`markdown-worker.ts` 主线程侧 latest/keys 上限 200、超期标记、错误降级；`markdown-worker-transport.ts` 每 key 单活跃+排队+supersede；`createLatestWorkerQueue`（markdown-worker-queue.ts:1-64）。
- **回归测试**：`packages/ui/src/context/marked-regression.test.ts`、`marked-parser.test.ts`、`markdown-stream.test.ts`。

## 6. 工具、reasoning、附件与自定义节点

- **工具组件注册**：`ToolRegistry.register/render`（message-part.tsx:1476-1496）已注册 14 个工具（apply_patch 经别名 `patch` 映射，:1490）：

  ```text
  read / list / glob / grep / webfetch / websearch / task / shell
  / edit / write / patch / todowrite / question / skill
  ```

  未注册的工具走 `GenericTool`（basic-tool.tsx:323-343）。
- **通用壳 `BasicTool`**（basic-tool.tsx:86-302）：Collapsible 包装、`TextShimmer`、状态驱动 subtitle/args、`defer` 双 rAF 延迟挂载（:48-84）、高度动画（:152-173）。
- **展开默认**：`partDefaultOpen`（part-default-open.ts:19-25）：shell 由设置 `shellToolPartsExpanded` 决定、edit/write/patch 由 `editToolPartsExpanded` 且纯删除 diff 折叠；受控 open 状态在 `toolOpen` store（message-timeline.tsx:409）。
- **输出渲染**：list/glob/grep 输出走 `Markdown`（:1826-1903）；shell 输出 `stripAnsi` 后用 `<pre><code>`（:2085-2153）；edit/write/patch 用 `@pierre/diffs` 虚拟化 diff 视图（file.tsx，`VIRTUALIZE_BYTES=500_000` :50）；exa websearch 输出提取 URL（:906-930）；错误统一 `ToolErrorCard`（tool-error-card.tsx:22-162）。
- **上下文分组**：连续 read/glob/grep/list 合并 `ContextToolGroup`（message-part.tsx:607、663-705、1043-1151）。
- **reasoning**：Web 端 reasoning part 直接 `PacedMarkdown` 渲染（:1759-1774），无折叠；折叠形态在 Thinking 行摘要（TextReveal）。TUI 端默认折叠成一行，点击展开（tui/src/routes/session/index.tsx:1572-1633）。
- **附件**：`attached`（url 以 `data:` 开头且非 inline）/`inline`（source.text.start/end）/`kind`（image/file）三类字段（message-file.ts:5-15）；`renderAttachments`（:1264-1313）→ `AttachmentCardV2`（v2/components/attachment-card-v2.tsx:5-33）；图片 `ImagePreview`（packages/ui/src/components/image-preview.tsx:10-32）。
- **todo 列表**：`todowrite` 渲染只读 Checkbox 列表（:2525-2574）；composer 区 `SessionTodoDock`。
- **表格**：marked 输出 `<table>`，CSS 横向滚动（markdown.css:271-287）；引用/blockquote 纯 CSS（:160-166）。

## 7. HTML、Artifact 与安全隔离

- **Sanitize**：所有非 code 块 markdown HTML 在插入 DOM 前经 DOMPurify（markdown-cache.tsx:35-38，调用点 markdown.tsx:461）。配置（markdown-cache.tsx:13-20）：

  ```text
  USE_PROFILES: {html:true, mathMl:true}   SANITIZE_NAMED_PROPS: true
  FORBID_TAGS: ["style"]                    FORBID_CONTENTS: ["style","script"]
  ADD_TAGS: ["svg","path"]
  ADD_ATTR: ["d","viewBox","preserveAspectRatio","xmlns","target"]
  ```
- **链接**：marked renderer 输出任意 href，协议过滤靠 DOMPurify 默认 URI 白名单（静态推断，未显式覆盖）；DOMPurify hook 给 `target="_blank"` 补 `rel="noopener noreferrer"`（markdown-cache.tsx:23-32）。
- **图片 src**：markdown `<img>` 依赖 DOMPurify 默认 `ALLOWED_URI_REGEXP`；附件本身是 data URL 直出（message-part.tsx:1294）。**本次未对 DOMPurify 默认白名单做运行验证**。
- 本快照未发现 iframe/Artifact 类渲染组件（全局搜索无匹配）。

## 8. 交互反馈与可访问性

- **复制**：`writeClipboard`（message-part.tsx:70-92）优先隐藏 textarea + `execCommand("copy")`，回退 `navigator.clipboard`；2 秒 `copied` 信号切 icon；代码块复制经事件委托、`data-copied` 2s 复位（markdown.tsx:288-331）。
- **折叠**：Collapsible + `toolOpen`/`partDefaultOpen`；ToolErrorCard 折叠。
- **重试**：`SessionRetry`（session-ui/src/components/session-retry.tsx:8-73）展示重试状态、倒计时、尝试次数（数据来自 `session_status {type:"retry",...}`）；手动重试入口是 composer 的 followup/编辑（SessionFollowupDock、use-composer-commands.tsx）。
- **审批**：`SessionPermissionDock`（app/src/pages/session/composer/session-permission-dock.tsx:8-74）reject/allowAlways/allowOnce 三按钮 → `sdk().api.permission.reply`；事件流 `permission.asked/replied` 入 store（event-reducer.ts:396-431）。TUI 侧 `routes/session/permission.tsx`（含 diff 预览 :47-88）。
- **提问**：`SessionQuestionDock`（session-question-dock.tsx，Mark/Option 单选多选 + 自定义答案）；TUI `question.tsx`。
- **预览/下载**：图片 `ImagePreview`；附件下载 `openAttachment`（session.tsx:1901-1920）：绝对路径优先 `platform.revealPath` 揭示，否则 `<a download>`；会话导出 `utils/session-export.ts`。
- **可访问性**：本次未展开（UI 行为需运行验证）。

## 9. 性能、缓存与测试

- **memoization**：全链路 `createMemo`（timeline 投影、part 查询、分组 `sameGroups`/`same` 结构化相等，message-part.tsx:615-661）；Effect `Data.TaggedClass` + 行复用。
- **虚拟列表**：overscan 50、`resizeItem` 钉住、`takeSnapshot` 缓存。
- **增量更新**：`message.part.delta` 就地追加；markdown 分块 + stable/unstable token 增量；`part_text_accum_delta` 独立累积通道；markdown LRU 200；首页预载。
- **节流/防抖**：`PacedMarkdown` 24ms 步进；SSE 16ms 批量 flush + delta 拼接；scroll rAF 合并（session.tsx:1531-1544）。
- **Worker 化**：解析与 shiki 高亮全部在 Web Worker，主线程仅 DOM 补丁；每 key 单活跃 + supersede 防堆积；code 块 key 上限 200。
- **延迟内容**：`BasicTool defer` 双 rAF；diff 虚拟化 `VIRTUALIZE_BYTES` 阈值；timeline 中 `virtualizeDiff={false}` 由行级虚拟化承担。
- **测试/基准**：有 marked 回归/解析/切块单元测试；UI 渲染基准设施本次未找到（`perf/` 只针对 opencode 包测试套件速度）；`packages/app/AGENTS.md` 有「改动 session/timeline 代码前记录生产基准」约定。

## 10. 扩展方式与已确认边界

新增 part 类型需要按顺序改动六个环节：

1. schema `Part` 联合（schema/src/v1/session.ts:357-370）；
2. SDK 再生成（sdk/js/script/build.ts）；
3. `PART_MAPPING` 注册（message-part.tsx:250）+ `renderable` 可见性（:711-720）；
4. Timeline 特殊行（timeline-row.ts + rows.ts + renderTimelineRow switch）；
5. store 过滤 `SKIP_PARTS`（event-reducer.ts:19、server-session.ts:30、sync.tsx:7，当前跳过 patch/step-start/step-finish）；
6. TUI `PART_MAPPING`（tui/src/routes/session/index.tsx:1564-1568）。

新增工具则 `ToolRegistry.register`（:1484-1491）+ TUI `toolDisplay` 分派。

**TUI 侧**（packages/tui）：消息壳 `routes/session/index.tsx`，各环节如下：

- part 映射 `{text, tool, reasoning}`（:1564-1568）；markdown 用 opentui 内置 `<markdown>`（streaming、tableOptions、conceal，:1685-1694），代码块用 tree-sitter wasm（parsers-config.ts:2）；
- 语法样式 `context/theme.tsx:271-272` + `theme/index.ts:66-79`（映射 ANSI :441-455）；
- 工具状态 `ToolPart`（:1702-1782）+ `InlineTool`（:1829-1905）+ `collapseToolOutput`（3 行截断）；
- 导出文本 `util/transcript.ts:26-112`。

**桌面端（Electron）不是第三套渲染栈**：renderer 以源码方式 import `@opencode-ai/app`（desktop/src/renderer/index.tsx:1-17 的 `AppInterface`/`PlatformProvider`，electron.vite.config.ts:93-105 用 app 的 `appPlugin`），markdown/消息渲染完全复用 app→session-ui 链路，desktop 包自身不依赖 session-ui（package.json 无该依赖）；生产环境经自定义 `oc://renderer` 协议加载打包的 renderer（main/windows.ts:291-332）。桌面独有的渲染代码仅 Splash 与首启引导（renderer/onboarding.tsx）；平台能力经 preload `window.api` 注入（src/preload/index.ts:13-138，含 draft 存储、窗口控制、剪贴板图片、原生文件选择）。

**服务端**：无 markdown 渲染——`UI.markdown` 是直通函数（cli/ui.ts:128-130 `return text`）；webfetch 工具的 `convertHTMLToMarkdown`（src/tool/webfetch.ts:182）是 HTML→markdown 供模型上下文，与 UI 渲染无关。

## 11. 未验证事项

1. 未运行构建与浏览器；虚拟列表滚动、morphdom 增量、token span 更新的实际视觉效果与性能未实测。
2. DOMPurify 默认 URI 白名单对图片/链接协议的实际拦截行为未运行验证（静态推断依赖默认配置）。
3. `part_text_accum_delta` 在断线重连、事件乱序下的文本合并正确性未实测。
4. `PacedMarkdown` 节流、Worker supersede 在长文本/高并发下的行为未实测。
5. 无障碍（键盘导航、ARIA）、主题切换的运行时行为未展开验证。

## 12. 关键源码索引

- `packages/session-ui/src/components/message-part.tsx`：PART_MAPPING（:250）、ToolRegistry（:1476-1496）、PacedMarkdown（:252-334）、renderable（:711-720）
- `packages/session-ui/src/components/basic-tool.tsx`、`tool-error-card.tsx`：工具壳层
- `packages/app/src/pages/session/timeline/message-timeline.tsx`：虚拟列表与行渲染
- `packages/app/src/pages/session/timeline/rows.ts`、`row-reconciliation.ts`、`projection.ts`：行模型
- `packages/ui/src/context/marked-parser.tsx`、`markdown.tsx`、`markdown.worker.ts`、`markdown-cache.tsx`、`marked-theme.tsx`：markdown 管线
- `packages/app/src/context/server-sdk.tsx`、`server-session.ts`、`server-session-v2-reducer.ts`：SSE 到 store；`packages/app/src/utils/session-message.ts`（:19-26）：`messageKey`/`compareMessages` 时间序排序键
- `packages/ui/src/hooks/create-auto-scroll.tsx`：自动滚动
- `packages/tui/src/routes/session/index.tsx`：TUI 消息渲染
- `packages/opencode/src/session/processor.ts`：part 事件产生（:278-537）
