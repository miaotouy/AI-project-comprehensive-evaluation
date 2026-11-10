# Jan 消息渲染器调查笔记

> 调查对象：`https://github.com/janhq/jan`（重点 `web-app/src/containers/RenderMarkdown.tsx`、`web-app/src/containers/MessageItem.tsx`、`web-app/src/lib/messages.ts`、`web-app/src/components/HtmlArtifact.tsx`、`web-app/src/containers/ChatInput.tsx`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 Jan 仓库
>
> 调查范围：消息部件分派、Markdown/LaTeX/Mermaid 渲染、流式渲染策略、HTML 工件与安全模型、引用与 grounding 渲染、输入区（无语音）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的消息渲染是 **React 组件 + AI SDK UIMessage parts** 的结构化模型：消息正文以 `text / reasoning / file / tool-*` 部件数组承载，渲染层的输入是这类部件而非整条消息的单一字符串（`web-app/src/containers/message/types.ts`，36 行：`CONTENT_TYPE` 仅 TEXT/FILE/REASONING 三种，`isToolPart = type.startsWith('tool-')`）。整体是一个 React web-app（`web-app/`），本次未发现独立的移动端渲染器。

Markdown 渲染以 **Jan fork 的 streamdown** 为核心，依赖声明为 `npm:@janhq/streamdown@^2.1.1`（`web-app/package.json`）。fork 的管线分三层：remark 侧启用 GFM 与数学公式，并禁用缩进代码块；rehype 侧用 KaTeX 排版公式，再由 `defaultRehypePlugins.harden` 做 HTML 消毒；另有 code、mermaid、cjk 三个流式专用插件。Jan 在这个 fork 上换了一套 rehype 插件，默认的 rehype-raw 与 rehype-sanitize 已被移除，改用 KaTeX、`restrictChatLinks` 与 harden 的组合（常量定义见 §2.1 代码块）；该插件由本仓库实现，专门约束聊天正文里的链接。流式期间另有三处优化：`useDeferredValue` 合并 token、代码块在流式中跳过 Shiki 高亮、LaTeX 走占位符保护管线。

Jan 的三个设计点：

- **reasoning、工具调用和文件附件都是独立 part**，渲染层按类型分派，不需要从 Markdown 反向解析私有标记，也不需要在正文里做 hack。
- **HTML 工件默认严格沙箱**：`HtmlArtifact` iframe 默认使用不透明源 + 严格 CSP + sandbox；放宽路径由设置控制（非流式 + 设置开启时可用）。
- **流式渲染针对每个 token 全量重渲做了三处处理**：`useDeferredValue` 合并 token、流式代码块推迟 Shiki 高亮、memo 比较器显式忽略无关字段。

## 1. 部件模型与分派

### 1.1 部件来源

`web-app/src/lib/messages.ts` 负责 UI 消息 ↔ ThreadMessage 双向转换：

- 正向转换入口是 `convertUIMessageToThreadMessage`：文本、推理、文件与工具部件逐类映射成 ThreadMessage，推理内容包裹为 `<think>`，文件按 image、audio、video 区分（`messages.ts:17` 起）。
- 反向转换入口是 `convertThreadMessageToUIMessage`：把工具调用内容转成 `tool-<name>` 部件，兼容旧数据里的 metadata.tool_calls；think、thought 与 channel|analysis 三种推理分隔标记统一由 `parseReasoning` 解析（`messages.ts:170-255`）。
- 空内容判断由两个函数承担：`uiMessageHasMeaningfulContent` 与 `threadMessageIsEmpty`（`messages.ts:402`、`:428`）。

### 1.2 MessageItem 分派（915 行）

- 工具调用是否还在进行由 `hasPendingToolCall` 判断：状态为 output-available、output-error 或 output-denied 时算终态，其余状态都按未完成处理；待审批状态另查 pendingApprovals 里对应的工具调用 id（`MessageItem.tsx:192`）。
- 部件按顺序渲染，入口是 `renderedParts`：遍历时推理与工具部件收进 `ChainOfThoughtGroup`，文本和文件部件打断当前分组并触发 flush，分组条件由 `isCotPart` 判断（`MessageItem.tsx:507` 起、`:416-417`）。
- 用户消息渲染成气泡，附件 chips 上显示注入方式；assistant 的正文交给 `RenderMarkdown`，引用标记在 grounding 完成后注入（`MessageItem.tsx:272-310`、`:313-326`）。
- 引用聚合分两步：工具输出先由 `parseCitationsFromToolOutput` 拆成 rag 与 web 两类，流结束后再触发 `ensureGrounding`，由 grounding store 调用 rag 扩展的 embed 接口做句子级余弦校验；web 引用行由 `WebSourcesRow` 渲染（`MessageItem.tsx:252-278`）。
- 附件按类型渲染：音频与视频用内嵌播放器，用户图片显示缩略图并可打开预览对话框（`MessageItem.tsx:333-411`、`:644-657`）。
- 出错时显示错误框并附带 Regenerate 操作（`MessageItem.tsx:528-555`）。
- 操作区提供复制、编辑、删除、Continue 与 Regenerate：编辑使用带 imageUrls 的 `EditMessageDialog`，Continue 仅在 `metadata.stopped` 为真时出现，Regenerate 只对最后一条开放（`MessageItem.tsx:558-642`）。
- memo 比较器对末尾仍在流式的消息始终判定需要重渲染（`MessageItem.tsx:661-680`）。

派生工具部件组件（独立文件）：

| 组件 | 行数 | 负责的渲染内容 |
| --- | --- | --- |
| `ChainOfThoughtGroup` | 291 | 推理链与工具调用分组折叠渲染，并按 messageId 记录推理耗时（`hooks/useCoTDuration.ts`） |
| `ToolCallCard.tsx` | 156 | 单个工具调用卡片 |
| `AgentToolWidget.tsx` | 327 | Agent 的工具调用 |
| `SubagentToolWidget.tsx` | 47 | 子 Agent 的工具调用 |
| `RagToolWidget.tsx` | 95 | RAG 检索结果卡片 |
| `WebToolWidget.tsx` | 142 | Web 搜索展开项 |
| `Citations` | 213 | 引用聚合 |
| `CitationLink` | 82 | 锚点链接 |
| `WebSourcesRow` | 58 | web 引用来源行 |
| `MarkdownTable` | 146 | 表格渲染 |
| `MermaidError` | 27 | Mermaid 渲染错误的展示 |

`conversation.tsx` 提供列表容器：`use-stick-to-bottom` 吸附底部、`role="log"` 无障碍角色。

### 1.3 输入区（ChatInput.tsx，约 3000 行）

聊天输入由 `ChatInput.tsx` 承担：text/markdown 输入、文件上传、多模态图片、停止/继续流式等。本快照**未发现语音输入**相关代码（搜索 `speech`/`voice`/`webkitSpeechRecognition` 无命中；见 §4 未验证）。

### 1.4 消息列表、窗口化与滚动

消息列表的容器实现在 `web-app/src/components/ai-elements/conversation.tsx`（235 行）。顶层 Conversation 在 `StickToBottom` 之外做了一层封装，初次挂载和容器尺寸变化时都平滑吸附到底部，并带上 log 无障碍角色；ConversationContent 承担消息列的容器职责，ConversationScrollButton 在用户离开底部时显示回底按钮。同文件还提供 `useReleaseScrollLock` 上下文，子组件可借此临时让出滚动锁，例如展开工具卡片时。

- **消息列表全量渲染**：列表没有做窗口化或虚拟化，所有消息一次性挂载；依赖清单里的 `@tanstack/react-virtual` 只服务于 Hub 模型列表，调用点在 `web-app/src/routes/hub/index.tsx` 的 `useVirtualizer`，消息列表没有用到它。
- **长列表性能来源**：本次在 web-app 中未找到 `content-visibility` 样式声明（grep 无命中），长列表的流畅度依赖 MessageItem 的 memo 比较器与流式节流（§1.2、§2.2）。
- **滚动锚定**：吸附逻辑由 StickToBottom 的 `isAtBottom` 与 `scrollToBottom` 提供；分支与版本切换时的滚动定位行为尚未运行验证。

## 2. RenderMarkdown

`web-app/src/containers/RenderMarkdown.tsx`（456 行）。正文不维护自定义 AST，直接经 remark/rehype 管线转为 React 节点（streamdown fork），没有 AST diff 环节；更新粒度是组件级 memo 与 Streamdown 流式模式解析。

### 2.1 插件配置

```text
REMARK_PLUGINS    = [remarkGfm, remarkMath, disableIndentedCodeBlockPlugin]   (:109)
REHYPE_PLUGINS    = [rehypeKatex, restrictChatLinks, defaultRehypePlugins.harden] (:110)
STREAMDOWN_PLUGINS = { code, mermaid, cjk }                                  (:111)
LINK_SAFETY       = { enabled: false }                                       (:113)
```

- **rehype 插件集**：`REHYPE_PLUGINS` 由 KaTeX、`restrictChatLinks` 与 harden 三个插件组成，streamdown 默认的 rehype-raw 与 rehype-sanitize 已不在其中；rehype-raw 只保留在 web-app 的依赖清单，src 里没有它的使用点。该插件由本仓库实现（`:59`），链接渲染因此受两层控制：插件负责改写 href，`LINK_SAFETY` 负责关闭 streamdown 自带的协议过滤。
- **Streamdown 的 props**：一组控制流式行为，包括 `mode` 与不完整 Markdown 解析开关、是否播放动画及动画时长；另一组是常规渲染参数，包括链接安全检查、mermaid 错误组件、class 名与消息 id。
- **模块级常量**：插件引用被提升到模块作用域，源码注释解释了原因——Streamdown 是 memoized 的，每次渲染传入新的字面量会破坏 memo，导致每个流式 token 都触发全量重新解析与重新高亮。
- **样式钩子**：代码块头部样式通过 `[data-streamdown="code-block-header"]` 选择器挂接，规则写在 `index.css`。

### 2.2 流式优化

- 流式数据来自 AI SDK 的 `useChat`，回调按 50ms 节流；上层再用 `useDeferredValue` 合并连续到达的 token，减少每帧重渲染的次数（`RenderMarkdown.tsx:268`）。
- 流式中的代码块暂不交给 Shiki：活动代码块先以纯文本渲染（`StreamingCode`，`:121`），避免每个 token 都触发一次全量高亮——这段开销在 webkitgtk 上尤其明显；流结束后由 Shiki 的 `CodeBlock` 接管。
- LaTeX 规范化占位符管道（L97-201）：先用 PUA 占位符遮蔽代码/数学，再做行内数学掩码与货币符号转义，随后插入 ZWSP 修复强调 flanking（`fixEmphasisFlanking`，L103-108），最后把 `\[..\]`/`\(..\)` 归一为 `$$..$$`。ZWSP 只加在代码/数学被遮蔽之后，避免 KaTeX 报 "Unrecognized Unicode character 8203"。

### 2.3 组件覆盖

- 链接：`a` 标签被覆写为 `#cite-/#webcite-` 锚点，分别由 CitationLink 与 WebCitationChip 渲染，覆写点在 `mergedComponents`（`RenderMarkdown.tsx:281`）。
- 表格：`table` 交给 `MarkdownTable` 渲染。
- HTML 工件：分段处理只在非流式输出且相关设置开启时启用；svg 分支强制传入 `allowScripts={false}`（`RenderMarkdown.tsx:258-296`）。
- 代码块：`code-block.tsx` 调用 shiki 的 `codeToHtml` 同时产出亮色与暗色两套高亮结果。

### 2.4 HTML 消毒、工件与链接渲染

- 正文里的 HTML 交给 streamdown fork 提供的 `defaultRehypePlugins.harden` 消毒（`:110`），仓库源码中没有 DOMPurify 的使用点。
- `LINK_SAFETY` 被设为 `{ enabled: false }`（`:113`），streamdown 自带的链接安全检查因此关闭，协议过滤改由 `restrictChatLinks` 接管。
- HTML 工件由 `web-app/src/components/HtmlArtifact.tsx`（130 行）用 iframe 承载，默认启用严格 CSP 与不透明源 sandbox：`allowNetwork` 默认关闭，`allowScripts` 默认开启，但 SVG 分支强制关闭。文档壳与 CSP 由 `lib/htmlSandbox.ts` 的 srcDoc 拼装逻辑生成，其中包含内存存储 shim 与元素检查器脚本；相对资源无法解析时，`lib/htmlAssets.ts` 负责给出提示条。只有非流式输出且设置开启时，才通过对应的 props 放宽网络与脚本限制。
- 正文链接点击后跳到引用区锚点（`#cite-/#webcite-`），来源展示由 `web-citation-store.ts` 与引用来源行组件完成；引用的提取与校验落在 `lib/citation-parser.ts`、`lib/grounding.ts`，做法是句子切分加余弦相似度比对。

## 3. 扩展方式与新增节点机制

- **部件层由硬编码分支分派**：消息部件按 `part.type` 在渲染循环里顺序分派，分派代码直接写在组件内部（`MessageItem.tsx:507` 起）：文本走 renderTextPart 交给 `RenderMarkdown`，文件走 renderFilePart，推理与工具部件走 `ChainOfThoughtGroup`。新增一种部件类型要同时改动两侧：`messages.ts` 的 ThreadMessage ↔ UIMessage 转换（§1.1）和这里的分派分支；本快照没有可供注册新类型的插件注册表。
- **Markdown 层的扩展点**：`mergedComponents` 把 `a` 覆写成引用锚点（`#cite-/#webcite-` 两种前缀，由 CitationLink 与 WebCitationChip 渲染），把 table 换成 MarkdownTable，再与调用方传入的 components prop 合并。代码、数学与 Mermaid 由 Streamdown 插件常量控制（§2.1），源码注释说明 code 组件保持原样，以便 html 与 svg 仍按段拆出（`RenderMarkdown.tsx:254-257`、`:281`）。
- **扩展边界（静态确认）**：本快照未发现 schema 驱动或注册表式的动态渲染组件机制，新增节点类型依赖硬编码分派。

## 4. 边界与未验证事项

- streamdown 内部 harden 的标签与属性白名单无法从本仓库源码确认，该项属推测。
- `LINK_SAFETY` 设为 `{ enabled: false }` 后，streamdown 按协议白名单过滤链接的逻辑受影响的范围尚未确认。
- RAG `retrieve` 返回的 citations 载荷结构以 `citation-parser.ts` 与 `rag-extension` 的索引为准，运行时实际的 JSON 未核对。
- `editMessage` 重新渲染、分支切换时，引用与 grounding 状态能否保持一致尚未验证。
- “无语音输入”的结论来自源码搜索，`speech`、`voice`、`webkitSpeechRecognition` 均无命中，未做运行验证。
- `MermaidError`（27 行）在流式出错时直接展示，错误内容与样式未运行确认。
- 长会话下列表全量渲染的实际性能（无窗口化）未运行验证。
- 项目测试与构建没有运行，本文的记录来自静态源码；动画、无障碍与平台差异等 UI 行为需要在目标环境中运行验证。

## 5. 关键源码索引

- 渲染主组件：`web-app/src/containers/RenderMarkdown.tsx`（456 行）
- 消息部件分派：`web-app/src/containers/MessageItem.tsx`（915 行）
- 输入区：`web-app/src/containers/ChatInput.tsx`（约 3000 行，无语音）
- 部件类型：`web-app/src/containers/message/types.ts`（36 行）
- 消息转换：`web-app/src/lib/messages.ts`
- 引用解析 / grounding：`web-app/src/lib/citation-parser.ts`、`web-app/src/lib/grounding.ts`
- HTML 工件：`web-app/src/components/HtmlArtifact.tsx`（130 行）、`web-app/src/lib/htmlSandbox.ts`（66 行）、`web-app/src/lib/htmlAssets.ts`
- 代码块：`web-app/src/components/ai-elements/code-block.tsx`
- 工具卡片：`web-app/src/components/ai-elements/tool.tsx`、`tool-runtime.tsx`；`RagToolWidget.tsx`、`WebToolWidget.tsx`
- 渲染子组件：`ChainOfThoughtGroup`（291 行）、`ToolCallCard.tsx`（156 行）、`AgentToolWidget.tsx`（327 行）、`SubagentToolWidget.tsx`（47 行）、`Citations`（213 行）、`CitationLink`（82 行）、`WebSourcesRow`（58 行）、`MarkdownTable`（146 行）、`MermaidError`（27 行）
- 样式钩子：`index.css:261`（`[data-streamdown="code-block-header"]`）
- 列表容器：`web-app/src/components/ai-elements/conversation.tsx`（235 行，use-stick-to-bottom + 滚动锁释放）
