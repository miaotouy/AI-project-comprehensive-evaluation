# Chatbox 消息渲染调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：只读源码梳理，未修改目标仓库
>
> 调查范围：消息模型、Markdown/富文本、流式更新、列表和扩展渲染机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 以 `Message.contentParts` 组织消息渲染，Markdown renderer 只处理其中的文本 part。完整链路如下：

1. 模型流由 `orchestrateGeneration()` 消费。
2. `processStreamChunk()` 把增量转换成 `text`、`reasoning`、`tool-call`、`image` 等 part。
3. 流式期间每个可见增量都更新 React Query session cache；每 2 秒或遇到工具调用时落盘，结束时最终落盘。
4. 会话路由把当前会话交给 `MessageList`。
5. `MessageList` 合并历史线程与当前线程，用 `react-virtuoso` 虚拟化，并把最后一轮用户/助手消息组合成一个列表项。
6. 普通消息进入 `Message`，再按 part 类型分派给 Markdown、思考时间线、工具 UI、图片、提示卡等专用组件；有替代回复的消息在下方挂 `ForkGroup` 折叠分支组（`MessageList.tsx:439-451`）。
7. 文本 part 才进入 `Markdown`；Markdown 内再分派普通文本、代码、LaTeX、Mermaid、SVG 和图片。

总体链路：

```text
model.chatStream()
  -> processStreamChunk()
  -> Message.contentParts
  -> React Query session cache / periodic storage persist
  -> /session/$sessionId
  -> MessageList (Virtuoso)
  -> ForkMarkerMessage | SummaryMessage | Message (+ ForkGroup 替代回复折叠组)
  -> message timeline layout
  -> Markdown | ReasoningContentUI | StepTimelineUI | ToolCallPartUI
     | PictureGallery | MessageErrTips | MessageStatuses
```

从代码可以确认以下设计：

- 正文、思考、工具、图片、状态和错误是结构化 part，不依赖从 Markdown 私有标记中反向解析。
- 流式 UI cache 与持久化写入分开，避免每个 token 都写 storage。
- 列表虚拟化、滚动位置恢复和输出跟随都在消息列表组件统一处理。
- Markdown 默认支持 GFM、软换行、LaTeX、Shiki、Mermaid 和图片查看器。
- 原始 HTML 不进入 Markdown DOM；HTML 代码预览放进 sandboxed iframe。

已确认的当前问题：

1. **流式正文没有 UI 级节流。** 每个可见文本增量都更新 React Query cache，并重新解析当前累计 Markdown；长回复或高频小增量会使 CPU 成本随正文增长。
2. **“自动预览 Artifact”设置已完全无消费方。** `Message.tsx` 中已无 `autoPreviewArtifacts`/`previewArtifact`/`needArtifact` 状态与 `MessageArtifact` import，但设置项仍保留在 schema（`shared/types/settings.ts:547`）与设置页开关（`routes/settings/chat.tsx:455`，默认 false）里，全仓库没有任何读取该设置的消费方。用户仍可从 HTML 代码块按钮手动预览。
3. **Markdown 自动化测试偏窄。** 已有 sandbox 文件链接与 Mermaid 真实渲染（`Mermaid.real.test.tsx`）用例，但 GFM、LaTeX、代码块、Mermaid fallback 与流式不完整语法的组合测试仍缺。

另有一项边界事实：**HTML 导出的会话名和线程名未转义。** `format-chat.tsx:39,112,125` 直接把 `sessionName`、`thread.name` 插入导出的 HTML，标题包含 HTML 时会原样进入导出文件。

## 页面入口与状态来源

会话页面入口是：

`src/renderer/routes/session/$sessionId.tsx`

页面通过 `useSession(currentSessionId)` 从 React Query 读取 session。query 使用：

```ts
queryKey: QueryKeys.ChatSession(sessionId)
staleTime: Infinity
```

session 存在时页面直接渲染：

```tsx
<MessageList
  ref={messageListRef}
  key={`message-list${currentSessionId}`}
  currentSession={currentSession}
/>
```

`key` 绑定 session id，因此切换会话会重新创建完整的消息列表实例；这也隔离了列表内部的滚动和局部交互状态。

消息列表调用 `getAllMessageList()`，该函数按顺序拼接：

```text
session.threads[*].messages
  + session.messages
```

主视图会同时铺开当前线程和历史线程；每个线程的首条消息前由 `ThreadLabel` 标出边界。

## 消息数据模型

核心定义位于：

`src/shared/types/session.ts`

消息结构由 Zod schema 定义，主要字段包括：

- `id`
- `role`: `system | user | assistant | tool`
- `contentParts`
- `generating`
- `isStreamingMode`
- `files` / `links`
- `status`
- `error` / `errorCode` / `errorExtra`
- `usage` / `generationDuration` / `firstTokenLatency`
- `backgroundTask`

`contentParts` 是 discriminated union：

| part type | 主要字段 | UI 语义 |
| --- | --- | --- |
| `text` | `text` | 正文或工具步骤之间的中间说明 |
| `reasoning` | `text`, `startTime`, `duration` | 思考过程、计时与折叠详情 |
| `tool-call` | `state`, `toolCallId`, `toolName`, `args`, `result` | 工具运行、结果、错误或审批暂停 |
| `image` | `storageKey`, `ocrResult?` | 消息图片与 OCR 入口 |
| `info` | `text`, `values?` | 轻量提示条 |
| `agent-mode-suggestion` | `reason?` | Chat Mode / Work Mode 选择卡 |

工具状态为：

```text
call -> result | error | paused
```

工具 part 还可以保存 provider metadata、step index、开始时间、耗时、暂停原因和大结果的 blob storage key。

### 兼容旧消息

`src/shared/utils/message.ts` 中的 `migrateMessage()` 是旧字段迁移边界：

- 旧 `content` 转成 `[{ type: 'text', text }]`。
- 旧 `pictures` 转成 image part。
- 旧 `webBrowsing` 转成一个已完成的 `web_search` tool-call part。

迁移完成后，渲染层统一从结构化 part 列表读取历史数据。

### 文本扁平化

共享的 `getMessageText()` 只拼接正文文本、可选的思考内容和图片占位符；工具、提示条、建议卡不进入扁平正文。

仓库同时存在两套默认语义不同的文本提取 helper：

- `src/shared/utils/message.ts`：默认不包含思考内容。
- `src/renderer/utils/message.ts`：默认包含思考内容。

当前消息组件与列表组件使用 shared 版本。两套默认值并存容易让复制、字数、搜索或导出在后续改动中出现语义偏差。

## 流式数据如何到达 UI

核心文件：

- `src/renderer/stores/session/orchestration.ts`
- `src/renderer/stores/session/stream-chunk-processor.ts`
- `src/renderer/stores/session/messages.ts`
- `src/renderer/stores/chatStore.ts`

### chunk 到 part

`orchestrateGeneration()` 从模型的异步流读取增量，逐条交给 `processStreamChunk()` 转换。

主要转换规则：

| stream chunk | 处理结果 |
| --- | --- |
| `text-delta` | 追加到当前 text part；不存在则新建 |
| `reasoning-delta` | 追加到当前 reasoning part，并记录开始时间 |
| `reasoning-end` | 固化 reasoning duration，显示 preparing tool call status |
| `tool-input-*` | 暂存增量参数并更新 KB/line progress，不立即创建 part |
| `tool-call` | 创建 `state: call` 的 tool-call part |
| `tool-result` | 原位更新对应 part 为 `result` 并记录 duration |
| `tool-error` | 更新或补建 part 为 `error` |
| `file` | 图片保存到 blob storage，再追加 image part |
| `status` | 更新 `Message.status`，不改 contentParts |
| `finish-step` | 增加 provider step index |
| `finish` | 保存 usage 和 finish reason |

连续正文增量和思考增量会原位追加到当前 part，而外层每次构造新的消息对象和新的 part 数组，使消息引用变化并触发 React 更新，同时保留已完成 part 的对象引用。

### cache 与持久化

流开始前先插入/持久化带 `generating: true` 的目标 assistant message。

流式期间分两条路径：

```text
普通 chunk
  -> updateStreamingCache()
  -> chatStore.updateMessageCache()
  -> React Query setQueryData()
  -> UI 立即重渲染

tool-call 或距上次落盘 >= 2 秒
  -> persistStreamingMessage()
  -> storage + query cache
```

工具调用会立即落盘，因为它可能长时间等待工具执行或用户审批。正常结束、停止、错误和暂停状态都会做最终持久化，并清除生成标记与取消处理器。

流式收口：停止生成时仍在运行的 tool-call part 会被收口为错误态并记录耗时（收口逻辑在 `stream-chunk-processor.ts`）；`orchestration.ts:774-801` 用 abort 与 chunk 读取做竞速，停止后可立即收口消息而无需等待流排空。大结果转存 blob 时保留 part 的 provider metadata 等原字段。

流式消息直接替换会话缓存中的对应消息，没有使用独立 overlay。路径较短，但整个消息列表组件会收到新的 session，并在每个可见增量上重算当前消息列表和最后一轮分组。

## 列表层

核心文件：

`src/renderer/components/chat/MessageList.tsx`

### 虚拟列表

列表使用 Virtuoso：

```tsx
<Virtuoso
  data={renderItems}
  increaseViewportBy={{ top: 2000, bottom: 2000 }}
  followOutput={false}
  itemContent={...}
/>
```

该参数让列表在上下各多渲染 2000 像素，降低滚动时的白屏和高度估算抖动，但也意味着实际挂载的消息明显多于视口内消息。

### 最后一轮分组

列表组件找到最后一条用户消息。如果它位于末尾，或紧跟一条普通助手消息，则建立一个分组：

```text
[last user]
或
[last user, next assistant]
```

该分组可以在新消息阶段把列表项最小高度设为视口高度的 85%（`MessageList.tsx:505-506`），使最新问题从视口上方开始、回答在同一列表项内增长；其余消息一条对应一个 Virtuoso item。分组与滚动定位的 item 索引计算已从列表组件提取为独立的 `buildMessageRenderItems()`（`components/chat/message-render-items.ts:49-77`），`scrollToMessage` 等消费方必须经它定位，避免流式期间滚到错误位置。

### 特殊消息分流

每条消息项进入 `renderMessageBlock()`（`MessageList.tsx:396-456`）后先分流：

```text
isForkMarker -> ForkMarkerMessage
isSummary    -> SummaryMessage
otherwise    -> Message
```

每条消息外还有独立 `ErrorBoundary`，单条消息渲染失败不会击穿整个会话页面。

### 替代回复折叠分支组（ForkGroup）

当消息的分支索引挂有多于一条分支时，分叉点消息下方渲染 `ForkGroup`（`components/chat/ForkGroup.tsx`）——把"重新生成/继续回复"产生的替代回复收进一个可折叠的分支组，组内按最新优先排列、活动分支（当前主列表正在渲染的那条）显示在最后，组内也可独立停止/切换回复。该组只出现在消息位置内，不产生新侧栏条目（数据语义见会话与消息管理笔记 1.3）。

### 滚动与导航

列表自己实现了：

- 会话滚动快照恢复（最多 100 个会话的类 LRU 滚动缓存，`MessageList.tsx:61-70`）。
- 顶部、底部、上一条 user、下一条 user 导航。
- 桌面消息 minimap。
- 流式输出跟随。

`createSmoothFollowOutputController()` 不使用 Virtuoso 自带的输出跟随属性。它在用户位于底部时监听总高度变化，并按动画帧合并滚动请求；用户主动向上滚动后暂停跟随，滚回底部容差内时自动恢复（`smooth-follow-output.ts:28-73`）；布局收缩把暂停中的视口推到"底部"不会误恢复。移动端使用 `auto`，桌面通常使用 `smooth`，同时尊重 reduced motion。

### Minimap 锚点

列表组件只为 minimap 生成**短预览锚点**：`getMessagePreviewText()`（`message-navigation-utils.ts:22`）把每条用户消息折叠成最多 `MINIMAP_PREVIEW_MAX_LENGTH` 字符的文本前缀（图片占位符 `[image]`），并对预览相同的连续流式更新复用上一份锚点数组（稳定 identity，避免长回复流式期间 minimap 全量重算）；小屏完全跳过锚点计算。minimap 侧栏组件对大量锚点只渲染视口窗口加 overscan（`MessageMinimapRail.tsx:30-37`）。

## 单条消息骨架

核心文件：

`src/renderer/components/chat/Message.tsx`

消息组件同时承担以下职责：

- 经典左对齐布局和 bubble 布局。
- user / assistant / system avatar。
- contentParts 分派。
- 思考与工具步骤折叠。
- 错误、状态和 loading。
- 文件、链接、图片和 OCR。
- token、word、model、耗时、时间戳元信息。
- 复制、编辑、重试、续写、引用、删除、举报。

回复仍在生成时也可以编辑/删除消息：操作可用性由 `message-action-state.ts` 计算，并发生成多条回复时仅 ForkGroup 内的替代回复显示停止按钮，主列表生成中的最新回复从输入框停止（`MessageList.tsx:431-433` 传入生成计数字段）。删除生成中的消息经 `removeMessage` 做 fork 分支与压缩点清理（见会话与消息管理笔记）。

`backgroundTask` 是最高优先级短路：这类消息只渲染为居中的后台任务通知，不进入普通消息骨架。

### part 分派

普通 part 的最终映射为：

| 条件 | renderer |
| --- | --- |
| `reasoning` | `ReasoningContentUI` |
| `text` | `Markdown` 或 `StreamingTextFade` |
| `info` | 品牌色提示条 |
| `agent-mode-suggestion` | Work Mode 选择卡 |
| `image` | `PictureGallery` + 可选 OCR 摘要 |
| `step_group` | `StepTimelineUI` |
| 独立 `tool-call` | `ToolCallPartUI` |
| `msg.error` | `MessageErrTips` |
| `msg.status` | `MessageStatuses` / `PreparingToolCallStatus` |

文本在关闭 Markdown 时并非 `dangerouslySetInnerHTML`，而是普通 React text node，并通过 `whitespace-pre-line` 保留换行。

### 思考、工具与正文时间线

`createMessageTimelineLayout()` 先找到最后一个思考或工具 part：

- 最后一个步骤之前的正文被视为“过程说明”，并入步骤时间线。
- 最后一个步骤之后的正文/图片被视为最终答案，保持普通消息正文样式。
- 连续思考、工具调用和中间正文会合并为一个步骤组。

特殊兼容：非流式、恰好 `[text, reasoning]` 两个 part 时保持旧展示顺序，不把正文归入过程时间线。

完成后的多步骤过程可以整体折叠。折叠时只显示最后一个步骤之后的答案区域；如果消息恰好终止在步骤上，则保留最后一步，避免折叠后整条消息为空。

思考内容本身用普通文本展示，不再递归走 Markdown；详情最大高度 400 px，可展开、复制并显示思考耗时。

### 工具 renderer

`ToolCallPartUI` 当前有四类专用分派：

- `web_search` -> 搜索查询、结果卡和错误状态。
- `parse_link` -> 链接解析 UI。
- `create_download` -> 文件/图片/HTML artifact 下载和预览（`ToolCallPartUI.tsx:925`；下载卡内的沙箱文件链接经 `SandboxFileLink` 渲染，可对模型幻觉出来的 sandbox 路径做重映射救援，见生成式输出笔记）。
- `user_exec` -> 命令、结果与拒绝状态（命令卡可展开读取结构化输出，取消的命令显示 "Stopped" 而非失败）。
- 其他工具 -> 通用 pill + args/result/error details。

暂停的工具调用进入 `StepTimelineUI`，可显示继续、停止、批准或拒绝操作；`tool_call_limit` 暂停的继续按钮为拆分按钮（继续 / 继续并本会话不再暂停确认），`pauseOnToolCallLimit` 可会话级或全局关闭。工具 payload 只作为文本放进 Mantine Code 组件，不会当 HTML 执行；通用 preview 有 8000 字符上限，错误 preview 有 1200 字符上限。超过 30000 字符的完整 tool result 在流处理阶段转存 blob，只在消息里保留 1500 字符预览。

### 图片和附件

image part 使用 `PictureGallery`：

- storageKey 经 blob query 读取。
- 获取自然尺寸后进入共享图片查看器。
- user 图片使用紧凑高度。
- 图片可携带 OCR 文本，点击后进入 content viewer。

Markdown 图片由 `MarkdownImage` 包装进同一个图片查看器，但远程 URL 会直接作为 `<img src>` 加载。消息中的远程图片因此会向第三方服务器发起请求；当前没有图片代理或“点击后加载”策略。

文件和链接位于正文外的 `MessageAttachmentGrid`。超过 4 个时折叠；session RAG 附件在 pending/indexing 状态下每 3 秒轮询一次。

## Markdown renderer

核心文件：

- `src/renderer/components/Markdown.tsx`
- `src/renderer/components/streaming-text-fade.ts`
- `src/renderer/packages/latex.ts`
- `src/renderer/packages/shiki.ts`
- `src/renderer/components/Mermaid.tsx`

### 处理管线

正文处理顺序：

```text
raw text
  -> processLaTeX()（可关闭）
  -> useStreamingTextSegments()
  -> ReactMarkdown
       remarkGfm
       remarkMath（LaTeX 开启时）
       remarkBreaks
       remarkAddCodeIndex
       rehypeKatex
       rehypeWrapStreamingSegments（流式新增文本存在时）
  -> custom code / a / img components
```

具体能力：

- GFM 表格、删除线、任务列表等。
- 普通换行转 `<br>`。
- `$...$`、`$$...$$`、`\(...\)`、`\[...\]` 数学公式。
- fenced code block。
- Mermaid diagram。
- SVG preview。
- Markdown image viewer。

`processLaTeX()` 会先保护行内代码、代码块和已有公式，再转义疑似货币符号，最后把括号分隔符标准化。

### 流式文字淡入

Markdown 开启时，新增文本不是在 Markdown 外简单包 span，而是在 Markdown 解析后的 HAST 中按 source offset 包装：

- 只处理单调追加的 suffix。
- 最近 350 ms 的新增 segment 保持独立动画。
- code、pre 和 KaTeX 子树不做淡入。
- source 长度和渲染文本长度不一致时放弃动画，避免 escape/entity 偏移错误。
- reduced motion 下完全关闭。
- 全局只记住最近 200 个 stream key，避免状态无限增长。

关闭 Markdown 时使用更简单的 `StreamingTextFade`，直接按字符串 offset 包装新增 suffix。

### 代码块

`remarkAddCodeIndex()` 给每个代码块分配稳定序号，消息组件再用消息 id、part 序号和代码块序号组成折叠 key。

`CodeRenderer` 的分派：

```text
无换行 -> InlineCode
language=mermaid 且开启 Mermaid -> MessageMermaid
其他 -> BlockCode + 可选 SVGPreview
```

BlockCode 使用 Shiki：

- highlighter 单例预加载两个主题。
- language 按需异步加载。
- language 不支持时退回 plaintext。
- HTML 高亮结果做 50 项 LRU-like cache。
- 高亮尚未完成时先显示转义后的纯文本 `<pre><code>`。
- 超过 7 行的代码块可以折叠；默认折叠状态来自全局设置。
- HTML 代码块提供预览和发布按钮。

Shiki 输出通过 `dangerouslySetInnerHTML` 注入，但来源是 Shiki 分词结果，而不是模型原始 HTML。这里的安全性依赖 Shiki 正确转义源代码。

一个较小的显示风险是 `useShikiHtml()` 在 props 改变且新语言尚未加载时不会主动清空旧 `asyncHtml`；极短窗口内可能继续显示上一组高亮 HTML，直到新异步结果返回。通常代码块语言稳定，因此触发面有限。

### Mermaid 与 SVG

未闭合的流式 Mermaid 代码块不会尝试增量渲染，只显示 loading；生成结束后动态 import Mermaid 并生成 SVG。Mermaid 初始化带 `suppressErrorRendering: true`，渲染失败只在本组件内转成错误文案（`Mermaid.tsx:40-57`），并打一条 `MERMAID_RENDER_FAILED` 诊断埋点（`jk-events.ts`），不会让整条消息或页面崩溃。

Mermaid 生成的 SVG 直接注入主页面 DOM，应用依赖 Mermaid 内部的 DOMPurify 净化与默认 strict 安全级别，没有再做应用侧清洗。

普通 SVG 代码块走 `SVGPreview`：先编码为 data URL，再通过 `<img>` 和 gallery 显示，没有把模型 SVG 直接拼进主 DOM。

### URL 与原始 HTML

Markdown 没有启用 `rehype-raw`，因此模型输出的原始 HTML 不会作为 React DOM 执行。

链接和图片 URL 经过 `@braintree/sanitize-url`。链接统一带：

```html
target="_blank" rel="noreferrer"
```

桌面端新窗口请求由 `setWindowOpenHandler` 拦截并交给系统浏览器。主窗口配置了 `webSecurity: false`，没有启用 CSP。

## Artifact HTML 预览

核心文件：

- `src/renderer/components/Artifact.tsx`
- `src/renderer/modals/ArtifactPreview.tsx`

HTML 代码块的手动预览不是在消息 DOM 内执行，而是打开 `artifact-preview` modal。原始 HTML 通过 `postMessage(..., '*')` 发送给：

```text
https://artifact-preview.chatboxai.app/preview
```

iframe sandbox 为：

```text
模型 HTML：allow-scripts allow-forms
previewUrl：allow-scripts allow-forms allow-same-origin
```

模型 HTML 路径没有 `allow-same-origin`，因此即使允许脚本，也保持 opaque origin，无法直接读取主窗口 DOM 或 preload API。这是当前渲染链里重要的隔离边界。

`create_download` 生成的 HTML artifact 优先通过 sandbox provider 创建 preview URL；否则读取文件、内联相对资源后走相同 modal。

### 失效的自动预览设置

当前设置页仍提供 `autoPreviewArtifacts`，默认 false；消息组件中仍有：

```ts
const autoPreviewArtifacts = useSettingsStore(...)
const [previewArtifact, setPreviewArtifact] = useState(autoPreviewArtifacts)
const needArtifact = useMemo(...)
```

但三个值都没有进入 JSX，`MessageArtifact` 也只被 import、没有被调用。当前实际交互只有“点击 HTML 代码块上的预览按钮”。

Git 历史显示 `102fa1bd` 在重做代码块时删除了：

```tsx
{needArtifact && (
  <MessageArtifact ... preview={previewArtifact} ... />
)}
```

设置、状态、扫描计算和 import 没有同步删除。这既是用户可见功能回归，也让每条 assistant 消息渲染时额外扫描完整正文寻找 HTML 代码块。

## Summary、Fork 与导出

### Summary

`SummaryMessage` 默认只显示分隔条和“Earlier messages summarized”徽标；展开后，摘要正文重新使用同一个 `Markdown` renderer。只有最新摘要可以编辑和删除。

### Fork marker

`ForkMarkerMessage` 是纯结构标记，不进入 Markdown。存在源会话 id 时可导航回源会话。

### HTML 导出

`src/renderer/lib/format-chat.tsx` 通过 `ReactDOMServer.renderToStaticMarkup()` 复用 Markdown renderer：

- text part 渲染为静态 Markdown HTML。
- tool-call 单独输出已转义的 args/result。
- image 从 blob 内联为 data URL。
- attachment name 使用 HTML escape。

但 `sessionName` 和 `thread.name` 直接拼进 HTML，没有转义：

```ts
<title>${sessionName}</title>
<span>${sessionName}</span>
<h2>${i + 1}. ${thread.name}</h2>
```

导出页面还从 CDN 加载 Tailwind 和 KaTeX CSS；离线打开时样式依赖网络。

## 性能观察

### 已有优化

- Virtuoso 虚拟列表。
- 消息、摘要、分叉标记、Markdown、代码块、图片 gallery 等组件使用 `memo`。
- session scroll state 有 100 项上限。
- streaming fade stream key 有 200 项上限。
- Shiki HTML cache 有 50 项上限。
- 大 tool result 转存 blob。
- storage persist 以 2 秒间隔节流。
- 滚动跟随请求按动画帧合并。
- Mermaid 在代码块未闭合时不渲染。

### 主要成本

1. 每个可见文本增量都调用 `updateStreamingCache()`，没有动画帧节流、固定频率或字符批次合并。
2. session 引用变化会使消息列表重新执行消息拼接、最新摘要搜索、最后一条用户消息搜索、列表项构造和 minimap 锚点计算（锚点侧已优化为短预览 + 稳定 identity，见"Minimap 锚点"）。
3. 当前累计 text part 每次变化都会重新执行 LaTeX 预处理、ReactMarkdown parse 和 HAST transform。
4. 流式代码块会持续产生不同的 Shiki 缓存键，最多保留最近 50 份累计代码。
5. `needArtifact` 对每条 assistant 消息执行全文扫描但结果未使用；该状态已移除（见"已确认的当前问题"第 2 条）。
6. Virtuoso 上下 2000 px overscan 对包含 Mermaid、图片和工具详情的消息可能挂载较重。

## 测试现状

与消息渲染直接相关的现有自动化包括：

- `Markdown.test.tsx`：Markdown 图片、linked image、viewer grouping、sandbox 文件链接卡片。
- `Markdown.ssr.test.tsx`：SSR/export 中的图片。
- `StreamingTextFade.test.tsx`：流式 suffix、Markdown HAST 包装、blocked subtree。
- `Mermaid.test.tsx` / `Mermaid.real.test.tsx`：Mermaid 状态机与真实渲染（含失败路径）。
- `message-timeline.test.ts`：part 分组和兼容顺序。
- `smooth-follow-output.test.ts`：滚动跟随控制器（用户中断/容差恢复用例）。
- `Message.test.tsx`：part 分派、操作栏可见性与 token 显示。
- `MessageList.test.tsx`：最后一轮 group、ForkGroup 装配、minimap 锚点 identity 与流式组合。
- `ForkGroup.test.tsx`：替代回复折叠分支组。
- `message-render-items.test.ts`：Virtuoso item 分组与索引定位。
- `message-navigation-utils.test.ts`：minimap 短预览提取与锚点比较。
- `ToolCallPartUI.command.test.tsx` / `ToolCallPartUI.image-recovery.test.tsx`：命令时间线与图片任务恢复。
- `stream-chunk-processor.test.ts`：流式 chunk 到 part 的大量状态转换。
- ToolCall、Reasoning、MessageList、Summary、Error 等 Storybook real-component stories。

明显缺口：

- 没有 Markdown URL scheme / raw HTML / XSS 回归测试。
- 没有 GFM + LaTeX + streaming + incomplete fence 的组合测试。
- 没有 `autoPreviewArtifacts` 设置行为测试（该设置已无消费方，见上文）。
- 没有 HTML export 标题转义测试。

本次未运行测试。仓库没有 `node_modules`，本机 Corepack 在解析 pnpm 签名时失败；调查结论来自当前代码和 Git 历史的只读核对。

## 关键文件索引

| 职责 | 文件 |
| --- | --- |
| session 页面入口 | `src/renderer/routes/session/$sessionId.tsx` |
| session React Query cache | `src/renderer/stores/chatStore.ts` |
| generation orchestration | `src/renderer/stores/session/orchestration.ts` |
| chunk -> part | `src/renderer/stores/session/stream-chunk-processor.ts` |
| 流式 cache / persist | `src/renderer/stores/session/messages.ts` |
| 消息 schema | `src/shared/types/session.ts` |
| 旧消息迁移 / 文本提取 | `src/shared/utils/message.ts` |
| 消息列表 | `src/renderer/components/chat/MessageList.tsx` |
| 消息列表 item 分组 | `src/renderer/components/chat/message-render-items.ts` |
| 替代回复折叠分支组 | `src/renderer/components/chat/ForkGroup.tsx` |
| minimap 锚点与导航 | `src/renderer/components/chat/MessageMinimapRail.tsx`、`message-navigation-utils.ts` |
| 单条消息 | `src/renderer/components/chat/Message.tsx` |
| timeline 分组 | `src/renderer/components/chat/message-timeline.ts` |
| Markdown | `src/renderer/components/Markdown.tsx` |
| 流式文字淡入 | `src/renderer/components/streaming-text-fade.ts` |
| Shiki | `src/renderer/packages/shiki.ts` |
| Mermaid / SVG | `src/renderer/components/Mermaid.tsx` |
| 工具与 reasoning UI | `src/renderer/components/message-parts/ToolCallPartUI.tsx` |
| 图片 | `src/renderer/components/chat/PictureGallery.tsx` |
| 附件 | `src/renderer/components/chat/MessageAttachmentGrid.tsx` |
| 错误 | `src/renderer/components/chat/MessageErrTips.tsx` |
| 状态 | `src/renderer/components/chat/MessageLoading.tsx` |
| Summary | `src/renderer/components/chat/SummaryMessage.tsx` |
| Artifact iframe | `src/renderer/components/Artifact.tsx` |
| Artifact modal | `src/renderer/modals/ArtifactPreview.tsx` |
| HTML export | `src/renderer/lib/format-chat.tsx` |

## 可复用的设计判断

Chatbox 将结构化 part 放在 Markdown 之前：Markdown 只处理 text，工具、思考、图片、错误和审批保持可交互的类型化 UI。与在最终字符串里嵌入特殊标签相比，这种边界更便于维护、持久化和迁移。
