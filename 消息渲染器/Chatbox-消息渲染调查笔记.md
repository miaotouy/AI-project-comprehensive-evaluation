# Chatbox 消息渲染调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-07-29
>
> 代码快照：`7450ab2dde5eacab4a8721f8680006ba8b99438d`（分支：`main`）
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
3. 流式期间每个可见 chunk 更新 React Query session cache；每 2 秒或遇到 tool call 时落盘，结束时最终落盘。
4. session 路由把当前 session 交给 `MessageList`。
5. `MessageList` 合并历史 thread 和当前 thread，用 `react-virtuoso` 虚拟化，并把最后一轮 user/assistant 组合成一个列表项。
6. 普通消息进入 `Message`，再按 part 类型分派给 Markdown、思考时间线、工具 UI、图片、提示卡等专用组件。
7. 文本 part 才进入 `Markdown`；Markdown 内再分派普通文本、代码、LaTeX、Mermaid、SVG 和图片。

总体链路：

```text
model.chatStream()
  -> processStreamChunk()
  -> Message.contentParts
  -> React Query session cache / periodic storage persist
  -> /session/$sessionId
  -> MessageList (Virtuoso)
  -> ForkMarkerMessage | SummaryMessage | Message
  -> message timeline layout
  -> Markdown | ReasoningContentUI | StepTimelineUI | ToolCallPartUI
     | PictureGallery | MessageErrTips | MessageStatuses
```

从代码可以确认以下设计：

- 正文、思考、工具、图片、状态和错误是结构化 part，不依赖从 Markdown 私有标记中反向解析。
- 流式 UI cache 与持久化写入分开，避免每个 token 都写 storage。
- 列表虚拟化、滚动位置恢复和输出跟随都在 `MessageList` 统一处理。
- Markdown 默认支持 GFM、软换行、LaTeX、Shiki、Mermaid 和图片查看器。
- 原始 HTML 不进入 Markdown DOM；HTML 代码预览放进 sandboxed iframe。

已确认的当前问题：

1. **“自动预览 Artifact”设置已经失效。** `autoPreviewArtifacts`、`previewArtifact`、`needArtifact` 和 `MessageArtifact` import 仍留在 `Message.tsx`，但 JSX 不再渲染 `MessageArtifact`。该功能在 `102fa1bd` 中移除内联 Artifact 后没有同步清理设置和死代码。用户仍可从 HTML 代码块按钮手动预览。
2. **流式正文没有 UI 级节流。** 每个可见 text delta 都更新 React Query cache，并重新解析当前累计 Markdown；长回复或高频小 chunk 会使 CPU 成本随正文增长。
3. **Markdown 自动化测试偏窄。** 当前 `Markdown.test.tsx` 主要覆盖图片查看器，缺少 URL 安全、原始 HTML、GFM、LaTeX、代码块、Mermaid fallback 和流式不完整语法的组合测试。
4. **HTML 导出的会话名和 thread 名未转义。** `format-chat.tsx` 直接把 `sessionName`、`thread.name` 插入导出的 HTML；恶意或意外包含 HTML 的标题会在导出文件中成为可执行标记。

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

`MessageList` 调用 `getAllMessageList(currentSession)`。该函数按顺序拼接：

```text
session.threads[*].messages
  + session.messages
```

主视图会同时铺开当前 thread 和历史 thread；每个 thread 的首条消息前由 `ThreadLabel` 标出边界。

## 消息数据模型

核心定义位于：

`src/shared/types/session.ts`

`Message` 由 Zod schema 定义，主要字段包括：

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

迁移完成后，渲染层统一从 `contentParts` 读取历史数据。

### 文本扁平化

共享 `getMessageText()` 只拼接 text、可选 reasoning 和 image placeholder。工具、info、suggestion 不进入扁平正文。

仓库同时存在两套默认语义不同的 helper：

- `src/shared/utils/message.ts`：默认不包含 reasoning。
- `src/renderer/utils/message.ts`：默认包含 reasoning。

当前 `Message.tsx` 和 `MessageList.tsx` 使用 shared 版本。两套默认值并存容易让复制、字数、搜索或导出在后续改动中出现语义偏差。

## 流式数据如何到达 UI

核心文件：

- `src/renderer/stores/session/orchestration.ts`
- `src/renderer/stores/session/stream-chunk-processor.ts`
- `src/renderer/stores/session/messages.ts`
- `src/renderer/stores/chatStore.ts`

### chunk 到 part

`orchestrateGeneration()` 从 `model.chatStream()` 读取异步流，然后逐个调用 `processStreamChunk()`。

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

连续 text delta 和 reasoning delta 会原位追加到当前 part，而外层每次构造新的 `Message` 和新的 `contentParts` 数组。这使消息引用发生变化、触发 React 更新，同时保留已完成 part 的对象引用。

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

tool call 会立即落盘，因为它可能长时间等待工具执行或用户审批。正常结束、停止、错误和 paused 状态都会做最终持久化，并清除 `generating` 与 cancel handler。

流式消息直接替换 session query cache 中的对应消息，没有使用独立 overlay。路径较短，但整个 `MessageList` 会收到新的 session，并在每个可见 chunk 上重算当前消息列表和最后一轮分组。

## 列表层

核心文件：

`src/renderer/components/chat/MessageList.tsx`

### 虚拟列表

列表使用 `react-virtuoso`：

```tsx
<Virtuoso
  data={renderItems}
  increaseViewportBy={{ top: 2000, bottom: 2000 }}
  followOutput={false}
  itemContent={...}
/>
```

`increaseViewportBy` 在上下各多渲染 2000 px，降低滚动时的白屏和高度估算抖动，但也意味着实际挂载的消息明显多于视口内消息。

### 最后一轮分组

`MessageList` 找到最后一条 user message。如果它位于末尾，或紧跟一条普通 assistant message，则建立一个 `group`：

```text
[last user]
或
[last user, next assistant]
```

该 group 可以在新消息阶段设置 `minHeight = viewport height`，使最新问题从视口上方开始、回答在同一列表项内增长。其余消息一条对应一个 Virtuoso item。

### 特殊消息分流

每条 item 进入 `renderMessageBlock()` 后先分流：

```text
isForkMarker -> ForkMarkerMessage
isSummary    -> SummaryMessage
otherwise    -> Message
```

每条消息外还有独立 `ErrorBoundary`，单条消息渲染失败不会击穿整个会话页面。

### 滚动与导航

列表自己实现了：

- session 滚动快照恢复。
- 最多 100 个 session 的 LRU-like scroll cache。
- 顶部、底部、上一条 user、下一条 user 导航。
- 桌面消息 minimap。
- 流式输出跟随。

`createSmoothFollowOutputController()` 不使用 Virtuoso 自带 `followOutput`。它在用户位于底部时监听总高度变化，并按 animation frame 合并滚动请求；用户主动向上滚动后暂停跟随。移动端使用 `auto`，桌面通常使用 `smooth`，同时尊重 reduced motion。

## 单条消息骨架

核心文件：

`src/renderer/components/chat/Message.tsx`

`Message` 同时承担以下职责：

- 经典左对齐布局和 bubble 布局。
- user / assistant / system avatar。
- contentParts 分派。
- 思考与工具步骤折叠。
- 错误、状态和 loading。
- 文件、链接、图片和 OCR。
- token、word、model、耗时、时间戳元信息。
- 复制、编辑、重试、续写、引用、删除、举报。

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

`createMessageTimelineLayout()` 先找到最后一个 reasoning/tool-call part：

- 最后一个 step 之前的 text 被视为“过程说明”，并入 step timeline。
- 最后一个 step 之后的 text/image 被视为最终答案，保持普通消息正文样式。
- 连续 reasoning、tool-call 和中间 text 会合并为一个 `step_group`。

特殊兼容：非流式、恰好 `[text, reasoning]` 两个 part 时保持旧展示顺序，不把 text 归入过程时间线。

完成后的多步骤过程可以整体折叠。折叠时只显示最后一个 step 之后的答案区域；如果消息恰好终止在 step，则保留最后一步，避免折叠后整条消息为空。

Reasoning 内容本身用普通文本展示，不再递归走 Markdown；详情最大高度 400 px，可展开、复制并显示思考耗时。

### 工具 renderer

`ToolCallPartUI` 当前有四类专用分派：

- `web_search` -> 搜索查询、结果卡和错误状态。
- `parse_link` -> 链接解析 UI。
- `create_download` -> 文件/图片/HTML artifact 下载和预览。
- `user_exec` -> 命令、结果与拒绝状态。
- 其他工具 -> 通用 pill + args/result/error details。

paused tool call 进入 `StepTimelineUI`，可显示继续、停止、批准或拒绝操作。工具 payload 只作为文本放进 Mantine `Code`，不会当 HTML 执行；通用 preview 有 8000 字符上限，错误 preview 有 1200 字符上限。超过 30000 字符的完整 tool result 在流处理阶段转存 blob，只在消息里保留 1500 字符预览。

### 图片和附件

image part 使用 `PictureGallery`：

- storageKey 经 blob query 读取。
- 获取自然尺寸后进入共享图片查看器。
- user 图片使用紧凑高度。
- 图片可携带 OCR 文本，点击后进入 content viewer。

Markdown 图片由 `MarkdownImage` 包装进同一个图片查看器，但远程 URL 会直接作为 `<img src>` 加载。消息中的远程图片因此会向第三方服务器发起请求，构成一项隐私边界；当前没有图片代理或“点击后加载”策略。

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

`processLaTeX()` 会先保护 code span/fence 和已有公式，再转义疑似货币符号，最后把 bracket delimiter 标准化。

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

`remarkAddCodeIndex()` 给每个 fenced code block 分配稳定 index，`Message` 再用 message id + part index + code index 组成折叠 key。

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

Shiki 输出通过 `dangerouslySetInnerHTML` 注入，但来源是 Shiki tokenization，而不是模型原始 HTML。这里的安全性依赖 Shiki 正确转义源代码。

一个较小的显示风险是 `useShikiHtml()` 在 props 改变且新 language 尚未加载时不会主动清空旧 `asyncHtml`；极短窗口内可能继续显示上一组高亮 HTML，直到新异步结果返回。通常 fenced language 稳定，因此触发面有限。

### Mermaid 与 SVG

未闭合的流式 Mermaid fence 不会尝试增量渲染，只显示 loading；生成结束后动态 import Mermaid 并生成 SVG。

Mermaid SVG 被直接注入主页面 DOM。代码依赖 Mermaid 内部 DOMPurify/default strict security level，并没有再执行应用侧 sanitize。该边界需要谨慎维护：普通 `<img src="data:image/svg+xml">` 与 inline SVG 的脚本/事件属性执行模型不同，源码注释中“现代浏览器不会执行 SVG script”不足以单独作为安全证明。

普通 SVG fence 走 `SVGPreview`：先编码为 data URL，再通过 `<img>` 和 gallery 显示，没有把模型 SVG 直接拼进主 DOM。

### URL 与原始 HTML

Markdown 没有启用 `rehype-raw`，因此模型输出的原始 HTML 不会作为 React DOM 执行。

链接和图片 URL 经过 `@braintree/sanitize-url`。链接统一带：

```html
target="_blank" rel="noreferrer"
```

桌面端新窗口请求由 `setWindowOpenHandler` 拦截并交给系统浏览器。

这里仍应把 URL scheme 测试补齐，因为主窗口配置了 `webSecurity: false`，且 preload 暴露通用 `electronAPI.invoke`。当前 Markdown 路径没有发现直接 XSS，但一旦 inline SVG、依赖升级或自定义 renderer 引入 XSS，其影响会远高于普通网页。

## Artifact HTML 预览

核心文件：

- `src/renderer/components/Artifact.tsx`
- `src/renderer/modals/ArtifactPreview.tsx`

HTML fence 的手动预览不是在消息 DOM 内执行，而是打开 `artifact-preview` modal。原始 HTML 通过 `postMessage` 发送给：

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

当前设置页仍提供 `autoPreviewArtifacts`，默认 false；`Message.tsx` 仍有：

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

设置、state、扫描计算和 import 没有同步删除。这既是用户可见功能回归，也让每次 assistant message 渲染额外扫描完整正文寻找 HTML fence。

## Summary、Fork 与导出

### Summary

`SummaryMessage` 默认只显示分隔条和“Earlier messages summarized”徽标；展开后，摘要正文重新使用同一个 `Markdown` renderer。只有最新 summary 可以编辑和删除。

### Fork marker

`ForkMarkerMessage` 是纯结构标记，不进入 Markdown。存在 source session id 时可导航回源会话。

### HTML 导出

`src/renderer/lib/format-chat.tsx` 通过 `ReactDOMServer.renderToStaticMarkup()` 复用 Markdown renderer：

- text part 渲染为静态 Markdown HTML。
- tool-call 单独输出已转义的 args/result。
- image 从 blob 内联为 data URL。
- attachment name 使用 HTML escape。

但 `sessionName` 和 `thread.name` 直接拼进 HTML，没有 escape：

```ts
<title>${sessionName}</title>
<span>${sessionName}</span>
<h2>${i + 1}. ${thread.name}</h2>
```

会话名可能由模型自动生成，thread 名也可编辑，因此导出 HTML 应在这些位置统一 `escapeHtml()`。导出页面还从 CDN 加载 Tailwind 和 KaTeX CSS；离线打开时样式依赖网络。

## 性能观察

### 已有优化

- Virtuoso 虚拟列表。
- `Message`、`SummaryMessage`、`ForkMarkerMessage`、`Markdown`、代码块、图片 gallery 使用 `memo`。
- session scroll state 有 100 项上限。
- streaming fade stream key 有 200 项上限。
- Shiki HTML cache 有 50 项上限。
- 大 tool result 转存 blob。
- storage persist 以 2 秒间隔节流。
- 滚动跟随请求按 animation frame 合并。
- Mermaid 在 fence 未闭合时不渲染。

### 主要成本

1. 每个可见 text delta 都调用 `updateStreamingCache()`，没有 requestAnimationFrame、固定频率或字符批次合并。
2. session 引用变化会使 `MessageList` 重新执行 `getAllMessageList()`、last summary 搜索、last user 搜索、renderItems 构造和 minimap 文本提取。
3. 当前累计 text part 每次变化都会重新执行 LaTeX 预处理、ReactMarkdown parse 和 HAST transform。
4. 流式 fenced code 会持续产生不同的 Shiki cache key，最多保留最近 50 份累计代码。
5. `needArtifact` 对每条 assistant message 执行全文扫描但结果未使用。
6. Virtuoso 上下 2000 px overscan 对包含 Mermaid、图片和工具详情的消息可能挂载较重。

如果后续针对超长回复优化，优先级应是：先按 frame 合并 session cache UI 更新，再避免在流式前沿之外重算列表派生数据，最后考虑对当前 Markdown block 做更细的稳定层/流式尾部分离。

## 安全边界

当前实现的正向措施：

- ReactMarkdown 不启用 raw HTML。
- URL 经过 `sanitizeUrl`。
- link 使用 `noreferrer` 并交给系统浏览器。
- 通用工具 args/result 作为文本渲染。
- 普通 SVG 通过 image data URL 展示。
- 模型 HTML 在无 `allow-same-origin` 的 sandbox iframe 中执行。
- Shiki fallback 使用 React text node。

需要持续关注：

1. Mermaid SVG 直接 `dangerouslySetInnerHTML`，依赖第三方 sanitizer 默认行为。
2. 主 BrowserWindow 使用 `webSecurity: false`，没有启用 CSP，并暴露通用 IPC invoke；任何 renderer XSS 的后果都很重。
3. Markdown remote image 自动请求第三方 URL，存在隐私泄露面。
4. HTML export 标题未 escape。
5. Artifact 使用 `postMessage(..., '*')`。当前只向固定 iframe 发送模型 HTML，未接收敏感返回值，但仍建议把 target origin 固定为预览 origin。

## 测试现状

与消息渲染直接相关的现有自动化包括：

- `Markdown.test.tsx`：Markdown 图片、linked image、viewer grouping。
- `Markdown.ssr.test.tsx`：SSR/export 中的图片。
- `StreamingTextFade.test.tsx`：流式 suffix、Markdown HAST 包装、blocked subtree。
- `Mermaid.test.tsx`：Mermaid 状态。
- `message-timeline.test.ts`：part 分组和兼容顺序。
- `smooth-follow-output.test.ts`：滚动跟随控制器。
- `stream-chunk-processor.test.ts`：流式 chunk 到 part 的大量状态转换。
- ToolCall、Reasoning、MessageList、Summary、Error 等 Storybook real-component stories。

明显缺口：

- 没有 `Message.tsx` 的集成级 part 分派测试。
- 没有 `MessageList` 最后一轮 group 与流式更新组合测试。
- 没有 Markdown URL scheme / raw HTML / XSS 回归测试。
- 没有 GFM + LaTeX + streaming + incomplete fence 的组合测试。
- 没有 `autoPreviewArtifacts` 设置行为测试，因此死设置没有被发现。
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

继续演进这套 renderer 时，应保持以下约束：

1. 新消息能力优先新增结构化 part 或专用 tool renderer，不把控制协议塞进 Markdown。
2. 模型 HTML 永远不要进入主 renderer DOM，继续放在不同 origin 的 sandbox iframe。
3. 流式性能优化应发生在 cache 提交频率和稳定历史层，而不是牺牲 part 结构。
4. `Message` 已经职责过重；新增 part 类型时应建立 renderer registry 或独立 part component，避免继续扩大单个条件树。
5. 设置项必须有行为测试，避免再次出现 `autoPreviewArtifacts` 这种 UI、state 和实际渲染脱节。
