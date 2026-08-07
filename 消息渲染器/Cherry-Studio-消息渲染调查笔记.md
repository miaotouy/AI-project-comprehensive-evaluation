# Cherry Studio 消息渲染调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-07-28
>
> 代码快照：`b7673c23860db5dd6da7f42dec5fc21f6b13de1a`（分支：`main`）
>
> 调查方式：只读源码梳理，未修改目标仓库
>
> 调查范围：消息模型、Markdown/富文本、流式更新、列表和扩展渲染机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 通过一套分层的消息 UI 运行时完成消息渲染，Markdown 只负责其中的正文呈现：

1. 主进程经 IPC 发送 AI SDK `UIMessageChunk`。
2. renderer 按 topic、execution 和 anchor 拆分流，并用 AI SDK `readUIMessageStream` 组装 `UIMessage.parts`。
3. 当前流式快照以 overlay 形式覆盖数据库历史，持久化数据保持不变。
4. 页面 adapter 将 Home、Agent 等业务能力注入统一的 `MessageListProvider`。
5. `MessageList` 虚拟化消息组，将历史层与高频更新的 live tail 隔离。
6. `MessagePartsRenderer` 把 parts 投影为正文、思考、工具、附件、图片、视频、错误、翻译和压缩记录。
7. 正文最终由基于 Streamdown 的静态/流式 Markdown 组件渲染。

代码中可以确认以下设计特点：

- 消息协议以结构化 parts 表达内容，避免从整段文本中用正则解析私有标记。
- 流式状态和数据库历史明确分层，完成时通过刷新数据完成 overlay 交接。
- 对高频渲染做了多层结构共享、按帧合并、历史冻结和虚拟列表优化。
- 普通 Markdown 有白名单净化、安全 URL 处理和专门的回归测试。
- Home 和 Agent 共用一套消息 UI，由 adapter 注入不同能力。

HTML artifact 经受限 sandbox iframe 独立预览，与正文 Markdown 的净化管线分离，处理方式见 Markdown 渲染一节。

## 总体架构

```text
Main AI runtime / Persistence
  -> ai.stream.chunk / done / error IPC
  -> TopicStreamSubscription（topic -> execution + anchor 分支）
  -> readUIMessageStream（AI SDK parts 组装）
  -> useExecutionOverlay（每帧提交最新消息快照）
  -> useStableMessagePartsLayers（history + live overlay 结构共享）
  -> Home / Agent MessageList adapter
  -> MessageListProvider
  -> MessageList（分组、虚拟列表、历史层 / live 层）
  -> MessageGroup
  -> MessageFrame
  -> MessageContent
  -> MessagePartsRenderer
       -> MainTextBlock -> ChatMarkdown -> Markdown / StreamingMarkdown
       -> ThinkingBlock
       -> ToolBlockGroup / tool renderer registry
       -> Image / file / video / error / translation / compaction
```

这条渲染链路包含三类边界：

- **数据边界**：持久化历史与 live overlay 分离。
- **业务边界**：Home、Agent 等页面通过 adapter 适配统一组件。
- **渲染边界**：结构化 parts 先投影布局，再由各 leaf component 呈现。

## 入口与页面适配

### 统一消息组件族

核心目录：

`src/renderer/components/chat/messages/`

该目录的 `README.md` 将其职责限定为消息显示，不负责 composer、页面导航、侧栏、设置或业务数据持久化。公开契约是：

```ts
type MessageListProviderValue = {
  state: MessageListState
  actions: MessageListActions
  meta: MessageListMeta
}
```

- `state`：消息、parts、topic、加载状态、渲染配置和 UI selector。
- `actions`：删除、重试、翻译、导出、定位、代码保存等能力。
- `meta`：assistant 展示信息、导出文件名等环境元数据。

共享组件根据 action 是否注入来判断相应能力是否可用，不依赖 `isHome`、`isAgent` 一类页面模式开关。

### Home 入口

- `src/renderer/pages/home/ChatMain.tsx`
- `src/renderer/pages/home/messages/homeMessageListAdapter.tsx:86`

`ChatMain` 调用 `useHomeMessageListProviderValue()`，然后统一渲染：

```tsx
<MessageListProvider value={value}>
  <MessageList />
</MessageListProvider>
```

Home adapter 承担的适配工作较多，将聊天页的删除、重试、翻译、代码保存、图片导出、分支操作和 UI 状态转换为共享 action。

### Agent 入口

- `src/renderer/pages/agents/components/AgentSessionMessages.tsx`
- `src/renderer/pages/agents/messages/agentMessageListAdapter.tsx:127`

Agent 同样渲染统一的 `MessageList`。差异由 adapter 提供，包括：

- Agent profile 和 session topic。
- Agent 工具终止、定位和图片导出。
- AskUserQuestion 乐观输入。
- 对完成但无可见内容的消息补一个 `data-error` fallback。
- 隐藏嵌套 sub-agent 产生、且带 parent tool call id 的顶层消息。

当前代码已经采用“一个消息 UI，多种业务 adapter”的模式。

## 消息数据模型

### 标准载体

`src/shared/data/types/message.ts`

消息采用 AI SDK 的结构：

- `CherryUIMessage = UIMessage<CherryUIMessageMetadata, CherryDataPartTypes>`
- `CherryMessagePart = UIMessagePart<CherryDataPartTypes, UITools>`

数据库也直接存储 `UIMessage.parts`。传输、持久化和渲染由此共享同一种结构，无需把最终正文重新解析成私有消息协议。

### AI SDK 内建 part

主要内建类型：

- `text`
- `reasoning`
- `tool-*`
- `dynamic-tool`
- `file`
- `source-url`
- `source-document`
- `step-start`

### Cherry 自定义 data part

定义于 `src/shared/data/types/uiParts.ts`：

- `data-error`
- `data-translation`
- `data-video`
- `data-compact`
- `data-compaction-anchor`
- `data-agent-task-event`
- `data-knowledge-scope`
- `data-code`

其中 `data-agent-task-event`、`data-knowledge-scope` 等是隐藏状态，不直接进入聊天正文。

### part metadata

Cherry 在 `providerMetadata.cherry` 下存储不同 part 的扩展信息：

- text：引用、composer token 快照。
- reasoning：思考耗时和开始时间。
- tool：transport、tool identity、server identity。
- file：内部文件 ID、composer file token 关联。
- error：持久化的 AI 错误诊断。

访问器 `readCherryMeta()` 会按 part type 用 Zod 验证 metadata，为读取过程提供明确的校验边界。不过，`MessagePartsRenderer` 中仍保留了局部未经验证的 `getCherryMeta()` 强制转换，相关约束尚未完全统一。

## 流式消息链路

### IPC 分流

关键文件：

- `src/renderer/services/aiTransport/IpcChatTransport.ts`
- `src/renderer/services/aiTransport/TopicStreamSubscription.ts`
- `src/renderer/hooks/useTopicStreamSubscription.ts`

`TopicStreamSubscription` 为一个 topic 建立一次 IPC 监听，再按以下组合创建独立分支：

```text
executionId + anchorMessageId
```

anchor 用于区分同一 execution 中的不同 turn。同一模型 execution 在 steer/continue 时可能切换到另一条 assistant row，仅按 execution id 分流会混合这些 turn。

订阅具备以下生命周期行为：

- 注册监听后才请求 `ai.stream.attach`，避免 attach 瞬间遗漏 chunk。
- 支持 Main 返回 buffered chunks，窗口重连时可回放。
- `done`、`paused`、`error` 分别关闭对应 execution 分支。
- 组件卸载时默认执行 detach，不会触发 abort；Main 可继续生成并持久化。
- error 会先转成 `data-error` part 推入 live branch，再结束流。

### 一次性 execution reader

核心：`src/renderer/hooks/useExecutionOverlay.ts:149`

每个 execution 都会新建 `readUIMessageStream` reader。有跨 turn 状态的 `Chat` 对象不会被复用，从而在结构上避免“上一轮完成答案 + 新流”串接。

继续工具审批时，reader 会用数据库当前 anchor message 作为 seed，以便新到的 tool output 合并到既有 tool input；seed 的 parts 会 `structuredClone`，避免 AI SDK 的原地修改污染 SWR/数据库历史引用。

### 按帧提交 overlay

`useExecutionOverlay` 通过以下机制合并 chunk 引发的 React state 更新：

- 最新 snapshot 先放入 `pendingSnapshotsRef`。
- 通过 `requestAnimationFrame` 合并同一帧内的更新。
- terminal frame 会同步 flush，保证最终画面先可见，再执行持久化交接。
- epoch 与 readerVersion 防止 topic 切换、旧 reader 和待处理帧写回过期状态。

AI SDK 每处理一个 chunk 都会克隆整条消息。`shareSettledPartReferences()`（第 127 行）会恢复已完成 part 的旧引用，使 React 更新集中在流式前沿，避免反复处理整个累计 transcript。

### history 与 overlay 的交接

`src/renderer/pages/home/hooks/useStablePartsByMessageId.ts:93`

`useStableMessagePartsLayers()` 生成两层 map：

- `historyPartsByMessageId`：数据库历史加翻译 overlay，不接收高频 execution 快照。
- `partsByMessageId`：live execution parts 覆盖 history，用于当前可变尾部。

两层都进行结构共享：内容未变化时复用 part array 和 map 容器。流结束后，页面先刷新数据库，再清理 overlay，避免最终内容短暂消失或重复显示。

## 列表与消息骨架

### Provider 拆分

`MessageListProvider.tsx` 将状态拆成多个 context：

- data
- messages
- actions
- meta
- render config
- selection
- static UI
- UI selectors
- editing message id

高频消费者可订阅更窄的 context，减少无关更新。

### 消息分组

`MessageList` 先把平铺消息稳定地分组成 user/assistant group，并支持：

- 单模型与多模型 sibling。
- horizontal、vertical、fold、grid 多模型布局。
- sibling navigation。
- 消息 outline。
- 多选、导出、复制、定位。

渲染链为：

```text
MessageList
  -> MessageVirtualList
  -> MessageGroup
  -> MessageFrame
  -> MessageContent
  -> MessagePartsRenderer
```

### 虚拟列表

`src/renderer/components/chat/messages/list/MessageVirtualList.tsx`

虚拟列表由 `virtua` 的 `<Virtualizer>` 实现，提供：

- O(log n) item offset。
- 动态尺寸测量。
- overscan/buffer。
- prepend 时的 `shift`，加载旧消息不跳动。
- `keepMounted` 保留正在选择或交互的 item。

聊天特有的滚动行为在 `chatVirtualizerRuntime.tsx`：

- 用户滚轮、拖动和键盘操作会取得 viewport ownership。
- 位于底部时，流式增长自动跟随。
- 用户离开底部后，异步高度变化不会抢回滚动位置。
- ResizeObserver 同时处理 streaming text、折叠块和异步富内容造成的高度变化。
- 平滑滚动用 rAF 驱动，并允许用户输入中断。

### 历史层与 live 层

`MessageList.tsx:112-127` 明确建立两个边界：

- `MessageHistoryLayer`：memo 封闭的历史，使用 `historyPartsByMessageId`。
- `MessageLiveLayer`：只给 mutable tail 接收逐帧 snapshot。

`firstLiveGroupIndex` 之前的消息组不会因最后一条消息继续输出而重渲染。历史区与活动区的这层隔离是性能设计的关键。

## parts 布局投影

核心文件：

- `blocks/messagePartLayouts.ts`
- `blocks/MessagePartsRenderer.tsx`

### active message

`projectLiveMessageParts()`（`messagePartLayouts.ts:164`）把 active parts 投影为：

- process：reasoning + 常规 tool history。
- part：当前结果、交互工具或 side-channel 内容。

最后一个仍处于 `streaming` 状态的 text 会成为 open text tail；隐藏的 transport part 不影响 tail 的判定。

### completed message

`projectCompletedMessageParts()`（第 256 行）把最终消息分成：

- `historyEntries`：推理和工具过程。
- `resultEntries`：最终正文及相邻图片、文件、视频或错误。
- `reportEntries`：artifact report side channel。

消息完成后，过程信息折叠显示，最终结果保持可见。该布局由纯投影逻辑决定，无需依赖 CSS 隐藏，并已有表驱动测试覆盖。

### 相邻 part 分组

`MessagePartsRenderer` 还会把：

- 连续图片合成 gallery。
- 连续工具合成 `ToolBlockGroup`。
- 相同 filePath 的连续 video 合并。
- AskUserQuestion 保持独立，不归入普通工具组。

每个 block 外有 `react-error-boundary`；单个富内容渲染失败时会显示局部 fallback，不影响整条消息的其他内容。

## part 到组件的分派

主分派函数：`MessagePartsRenderer.tsx:459`

| part | 组件/行为 |
|---|---|
| `text` | `MainTextBlock` -> `ChatMarkdown` |
| `reasoning` | `ThinkingBlock` / `ThinkingBlockContent` |
| `tool-*`, `dynamic-tool` | tool projection -> `ToolBlockGroup` / 专用工具组件 |
| image `file` | `ImageBlock`，相邻图片聚合 |
| other `file` | `MessageAttachments` |
| `data-code` | 包装成 fenced code 后复用 `MainTextBlock` |
| `data-error` | `ErrorBlock`，支持诊断结果 |
| `data-translation` | `TranslationBlock` |
| `data-video` | `MessageVideo` |
| `data-compact` | `CompactBlock` |
| `data-compaction-anchor` | 时间线锚点 |
| source/step/hidden data | 不直接渲染 |

未知 part 会记录 warning 并返回 `null`，因此不会导致整个渲染流程失败。不过，如果协议新增了 part 而 UI 尚未更新，对应内容会直接消失。建议为带有可显示 payload 的未知 part 提供开发态 fallback。

## Markdown 渲染

### 静态与流式双模式

`src/renderer/components/chat/messages/markdown/ChatMarkdown.tsx:24`

- 从未参与流式输出的历史内容使用 `Markdown`，即 Streamdown `mode="static"`。
- 当前输出使用 `StreamingMarkdown`，开启 incomplete Markdown repair 和 fade-in。
- 一个 block 只要曾经 streaming，结束后仍保持 `StreamingMarkdown` 组件类型，但关闭动画和 incomplete repair。

最后一点避免 terminal frame 从 StreamingMarkdown 切成 Markdown 时重建整棵 React 子树，从而保护选择区、focus 和 block 本地状态。

### 文本预处理

正文进入 Streamdown 前会：

- 修正 LaTeX bracket 表达。
- 清除 SVG 空行。
- 按需注入 citation tag。
- 对暂停且空内容显示本地化提示。
- 对 user message 可选择原样文本或 Markdown。
- 将 composer token 变成受控 `<span data-composer-token-*>` 占位，再映射回只读 token chip。

### 插件

`@cherrystudio/ui` 的 `withChatPlugins()` 当前等同于 full Markdown preset：

- Streamdown code plugin / Shiki。
- CJK 换行处理。
- KaTeX math。
- Mermaid。
- GitHub blockquote alerts。

### React component overrides

`useChatMarkdownComponents.tsx` 映射：

- `a` -> citation tooltip 或普通 link hover card。
- `code` -> inline code、file path、CodeBlockView 或 HTML artifact。
- `table` -> 支持复制和 Excel 导出。
- `img` -> ImageViewer。
- `svg` -> 自适应尺寸和预览菜单。
- `p` -> 含图片时改为 div，避免非法 DOM nesting。

代码块能识别不完整 fence，流式高亮状态会传给 `CodeBlockView`。在 fancy mode 下，HTML fenced code 先显示为 `HtmlArtifactsCard`，不会直接注入正文 DOM。

### HTML 净化

净化管线位于 `packages/ui/src/components/composites/markdown/internal.tsx`：

```text
raw HTML parse
  -> rehype sanitize（扩展白名单）
  -> SVG scaling / ID prefix
  -> Streamdown harden
  -> heading ID prefix
  -> React components
```

`sanitize.ts:194` 的 schema：

- 禁止 `iframe` 和 `script`；
- `style` 放入 strip 列表；
- 不允许 inline event handler；
- href/xlink 只扩展允许的 HTTP/HTTPS；
- data URL 只对图片 src 放行；
- SVG 只允许列举的元素和属性；
- 保留 citation 与 composer token 所需的少量 data attribute；
- 对 ID 加 `user-content-` 前缀。

`ChatMarkdown` 会检测 `<style>` 并注册 `MarkdownShadowDomRenderer`，但当前 schema 在 React component mapping 之前 strip 掉 `style`，因此这条 Shadow DOM 路径在现有管线下不可达（注释与实现不一致）。

MCP/meta 工具详情中有两处通过 `dangerouslySetInnerHTML` 注入 Shiki 生成的高亮 HTML；原始输入先经 Shiki tokenizer 生成待注入的 HTML。

### HTML artifact 预览

Markdown 中的 fenced `html` 被 `CodeBlock.tsx` 映射为 `HtmlArtifactsCard`，用户点击 preview 后打开 `HtmlArtifactsPopup`。`HtmlPreviewFrame.tsx:9` 默认 sandbox 为 `allow-scripts allow-same-origin allow-forms`，iframe 使用 `srcDoc`，未注入限制网络连接的 CSP。Main window 在 `windowRegistry.ts:88` 配置 `webSecurity: false`、`sandbox: false`、`webviewTag: true`；preload 在 `preload.ts:362-363` 暴露 `window.electron` 和完整 `window.api`（含文件读取、文件写入、打开路径等操作）。

### 平滑文本播放

`src/renderer/hooks/useSmoothStream.ts`

流式正文通过自适应 jitter buffer 播放，处理单位是 grapheme：

- 根据累计输入速率估计播放速度。
- 根据近期 stall 调整 80-800ms 的目标 cushion。
- 最大 backlog 为 400 grapheme，避免显示严重落后模型。
- 流结束后在最多约 2 秒内排空大尾部。
- 后台 tab 恢复时限制单帧时间跨度，避免积压内容在一帧内全部显示。

该算法改善了播放体验，同时也增加了实现复杂度。相关常量应依据 benchmark 和用户指标持续调优，避免凭感觉频繁修改。

## 工具渲染

### 统一投影

`tools/toolResponse.ts` 将 AI SDK ToolUIPart 映射为统一状态：

- `input-streaming` -> `streaming`
- `input-available` -> `invoking`
- approval states -> `pending`
- `output-available` -> `done`
- `output-error` -> `error`
- denied/cancelled -> `cancelled`

它还结合 tool name、metadata、MCP 命名规则和 provider metadata 判断工具类型：`mcp`、`builtin` 或 `provider`。

### 分派层

- `tools/chooseTool.tsx`：meta、knowledge、web search、image generation、Agent timeline。
- `tools/agent/toolRendererRegistry.tsx`：Read、Bash、Edit、Write、Grep、Glob、Task、WebFetch、Skill、NotebookEdit 等专用 renderer。
- `MessageMcpTool.tsx`：通用 MCP 详情、partial JSON 参数、输出截断和图片结果。

工具投影用 WeakMap 以 part object identity 缓存；流式过程中 settled tool part 可复用旧投影。

AskUserQuestion/approval 流程横跨消息区与输入区：awaiting approval 的 inline tool 可能不显示，approve/deny UI 由 composer override 提供。

## 性能设计总结

Cherry Studio 对流式渲染的优化覆盖了从输入到 DOM 的整条链路：

1. IPC/快照按 animation frame 合并。
2. 每个 execution 一次性 reader，避免跨 turn 污染。
3. settled parts 恢复旧引用。
4. history/live parts maps 结构共享。
5. Provider 按订阅频率拆 context。
6. MessageList 冻结历史层，只更新 live tail。
7. part leaf 使用 React.memo 和 identity-based comparator。
8. tool projection 使用 WeakMap。
9. Virtua 只挂载可见消息组。
10. 文本用自适应 jitter buffer 平滑播放。
11. 代码高亮支持 worker 和增量 tokenizer。
12. 重型 tool output 延迟/idle 后再解析和高亮。

这套体系高度依赖稳定的对象身份。扩展时如果随意 clone 所有 parts、重建 provider object，或跨层传入不稳定 callback，既有优化可能失效，功能却不会立即报错，因此容易产生隐性性能回归。

## 测试现状

静态盘点：

- `components/chat/messages`：216 个文件，其中 69 个测试文件。
- 消息组件 TSX 文件：154 个。
- `services/aiTransport`：7 个文件，其中 3 个测试文件。
- `packages/ui` Markdown：21 个文件，其中 6 个测试文件。

已看到的测试覆盖包括：

- `useExecutionOverlay` 的多 execution、seed、terminal、清理和 overlay 行为。
- `TopicStreamSubscription` 与 `IpcChatTransport`。
- live/completed part layout 投影。
- `MessagePartsRenderer` 的正文、reasoning、工具和边界情况。
- MessageVirtualList、滚动状态机、位置记忆和平滑滚动。
- Markdown、StreamingMarkdown、代码块、链接、表格、citation。
- sanitize schema 与 SVG plugin。
- Home/Agent adapter 和主要消息 action。

本次未实际执行测试。原因：

- 仓库未安装 `node_modules`。
- 当前环境是 Node `v22.13.1`，项目要求 `>=24.11.1 <24.16.0`。
- 当前 Corepack 在解析 pnpm 时发生签名 key id 校验失败。

基于以上情况，本笔记只确认了相关自动化测试的存在，未验证当前快照能否通过这些测试。

现有证据表明，以下链路仍未看到可在 CI 中无人值守判定结果的直接自动测试：HTML artifact 尝试访问 `parent.api` 的集成路径、artifact 网络请求/CSP、Shiki 输出转义、长会话 + 多 execution + 高频工具输出的 renderer benchmark，以及未知 part 的可观察 fallback。

## 可维护性观察

### 优点

- 消息 UI 有本地 `README.md`，职责和 adapter 规则清晰。
- 数据协议、布局投影和 leaf renderer 分层明确。
- Home 与 Agent 正在收敛到一个消息组件族。
- 关键性能约束通常配有说明设计原因的注释和测试。
- 安全净化已经下沉到共享 UI Markdown 包。

### 压力点

- `MessagePartsRenderer.tsx` 已超过 1,400 行、约 50KB，同时承担 part 分组、投影衔接、工具缓存、展示决策和渲染分派。
- `homeMessageListAdapter.tsx` 接近业务 facade，集中处理大量动作；后续可考虑按 capability 拆分内部 hook，同时保留统一的 Provider contract。
- agent/home/message runtime 正处于 v2 重构期，目录仍位于 shared components，而架构文档计划最终迁到 `features/chat`。
- `getCherryMeta()` 的未验证读取与共享层 `readCherryMeta()` 并存。
- HTML artifact 与普通 Markdown 的防护强度不一致。

## 扩展指南

### 新增普通显示 part

1. 在 `src/shared/data/types/uiParts.ts` 增加 data shape 和 `CherryDataPartTypes` 条目。
2. 判断它是 result、process、hidden 还是 side channel。
3. 更新 `messagePartLayouts.ts` 的集合或投影规则。
4. 在 `MessagePartsRenderer.renderPart()` 增加 leaf component。
5. 为 active、completed、empty、error 和相邻 part 顺序添加表驱动测试。

不要把结构化内容先序列化成私有文本标签，再从 Markdown 里正则解析回来。

### 新增工具 renderer

1. 保持 AI SDK ToolUIPart 为源数据。
2. 在 `toolResponse.ts` 确认 name/type/status 能正确归一化。
3. Agent tool 放进 `toolRendererRegistry.tsx`；独立 builtin/MCP 类别通过 `chooseTool.tsx` 分派。
4. 明确 streaming、approval、done、error、cancelled 的 UI。
5. 大输出使用截断、延迟解析或独立查看器。
6. 不要在 tool component 中直接接入页面私有 store；需要的能力经 Provider action 注入。

### 修改 Markdown 能力

1. 优先修改 `packages/ui` 的共享 Markdown pipeline。
2. 同步评估静态与 streaming 两种 mode。
3. 任意新 HTML/SVG 属性必须更新 sanitize 测试。
4. 任意新 URL 能力必须定义 protocol 和网络策略。
5. 保持 components/plugins 引用稳定，避免每次 chunk 重建配置。

### 修改流式行为

必须同时验证：

- fresh turn 不继承上次 snapshot。
- continue/tool approval 能合并旧 tool input。
- topic 切换不会提交旧 rAF snapshot。
- terminal frame 不丢最后几个 delta。
- DB refresh 与 overlay dispose 之间不闪烁。
- settled part identity 仍保持稳定。
- 用户主动滚离底部后不会被自动滚动抢回。

## 结论

Cherry Studio 使用结构化 parts、分层 overlay、虚拟列表和专门测试组织消息渲染，普通 Markdown 经白名单净化，HTML artifact 以受限 sandbox iframe 独立预览。
