# Jan 消息渲染器调查笔记

> 调查对象：`E:\works\git\jan`（重点 `web-app/src/containers/RenderMarkdown.tsx`、`web-app/src/containers/MessageItem.tsx`、`web-app/src/lib/messages.ts`、`web-app/src/containers/HtmlArtifact.tsx`、`web-app/src/containers/ChatInput.tsx`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 Jan 仓库
>
> 调查范围：消息部件分派、Markdown/LaTeX/Mermaid 渲染、流式渲染策略、HTML 工件与安全模型、引用与 grounding 渲染、输入区（无语音）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的消息渲染是 **React 组件 + AI SDK UIMessage parts** 的结构化模型：消息正文不是单一字符串，而是 `text / reasoning / file / tool-*` 部件数组（`web-app/src/containers/message/types.ts`，36 行：`CONTENT_TYPE = {TEXT, FILE, REASONING}`，`isToolPart = type.startsWith('tool-')`）。整体是一个 React web-app（`web-app/`），本次未发现独立的移动端渲染器。

Markdown 渲染以 **Jan fork 的 streamdown** 为核心（依赖 `npm:@janhq/streamdown@^2.1.1`，`web-app/package.json:97`）：remark 管线（GFM、数学、禁用缩进代码块）+ rehype 管线（KaTeX + `defaultRehypePlugins.harden` 消毒）+ 流式专用插件（code/mermaid/cjk）。**Jan 替换了 fork 的 rehype 插件集：丢弃默认的 rehype-raw + rehype-sanitize，改用 `[rehypeKatex, harden]`**。流式期间有专门优化：`useDeferredValue` 合并 token、流式中代码块不跑 Shiki 高亮、LaTeX 占位符保护管线。

Jan 值得关注的三个设计点：

- **结构化 parts 消除了从 Markdown 反向解析私有标记的需要**：reasoning、工具调用和文件附件都是独立 part，渲染层按类型分派，不依赖正文 hack。
- **HTML 工件默认严格沙箱**：`HtmlArtifact` iframe 默认使用不透明源 + 严格 CSP + sandbox；放宽路径由设置控制（非流式 + 设置开启时可用）。
- **流式渲染有明确的性能优化链路**：`useDeferredValue` 合并 token、流式代码块推迟 Shiki 高亮、memo 比较器显式忽略无关字段，避免每 token 全量重渲。

## 1. 部件模型与分派

### 1.1 部件来源

`web-app/src/lib/messages.ts` 负责 UI 消息 ↔ ThreadMessage 双向转换：

- `convertUIMessageToThreadMessage`（L17-133）：text / reasoning（包裹 `<think>`，L40）/ file（image/audio/video，L50-82）/ tool part（L97-116）→ ThreadMessage；
- `convertThreadMessageToUIMessage`（L203-373）：`tool_call` content 转 `tool-<name>` part（L282-301）；兼容旧 `metadata.tool_calls`（L306-354）；`parseReasoning`（L161-196）解析 `<think>`/`<thought>`/`<|channel|>analysis`；
- `uiMessageHasMeaningfulContent`（L375-399）、`threadMessageIsEmpty`（L401-419）。

### 1.2 MessageItem 分派（683 行）

- `hasPendingToolCall`（L129-140）：终态仅 `output-available`/`output-error`/`output-denied`；`awaitingApproval` 查 `pendingApprovals[toolCallId]`（L142-149）；
- `renderedParts`（L413-475）：顺序遍历 parts，`reasoning`/`tool-*` 归入 `ChainOfThoughtGroup`（`isCotPart`，L416-417），text/file 打断 flush；
- 用户消息渲染为气泡（`coloredUserBubble`，附件 chips 显示 `injectionMode`，L272-310）；assistant 文本走 `RenderMarkdown` 并注入 `injectCitationMarkers`（grounding 后，L313-326）；
- 引用聚合（L160-180）：tool part 输出经 `parseCitationsFromToolOutput` 分 rag/web；流结束触发 `ensureGrounding`（`rag.embed` 句子级余弦校验，L194-212）；web 引用行 `WebSourcesRow`（63 行，L515-517）；
- 附件：音频/视频内嵌播放器、用户图片缩略图+预览对话框（L333-411、L644-657）；
- 错误框 + Regenerate（L528-555）；
- 操作区：复制/编辑（`EditMessageDialog` 带 imageUrls）/删除/Continue（仅 `metadata.stopped`）/Regenerate（仅末条）（L558-642）；
- memo 比较器对末条流式消息恒重渲染（L661-680）。

派生工具部件组件（独立文件）：

- `ChainOfThoughtGroup`（296 行）：推理链 / 工具调用分组折叠渲染；
- `ToolCallCard.tsx`（120 行）：单个工具调用卡片；
- `RagToolWidget.tsx`（104 行）：RAG 检索结果卡片；
- `WebToolWidget.tsx`（154 行）：Web 搜索展开项；
- `Citations`（224 行）/ `CitationLink`（90 行）：引用聚合与锚点链接；
- `WebSourcesRow`（63 行）、`MarkdownTable`（156 行）、`MermaidError`（30 行）。

`conversation.tsx` 提供列表容器：`use-stick-to-bottom` 吸附底部、`role="log"` 无障碍角色。

### 1.3 输入区（ChatInput.tsx，2648 行）

聊天输入由 `ChatInput.tsx` 承担：text/markdown 输入、文件上传、多模态图片、停止/继续流式等。本快照**未发现语音输入**相关代码（搜索 `speech`/`voice`/`webkitSpeechRecognition` 无命中；见 §3 未验证）。

## 2. RenderMarkdown

`web-app/src/containers/RenderMarkdown.tsx`（380 行）。正文不维护自定义 AST，直接经 remark/rehype 管线转为 React 节点（streamdown fork），没有 AST diff 环节；更新粒度是组件级 memo 与 Streamdown 流式模式解析。

### 2.1 插件配置

```text
REMARK_PLUGINS    = [remarkGfm, remarkMath, disableIndentedCodeBlockPlugin]   (L61)
REHYPE_PLUGINS    = [rehypeKatex, defaultRehypePlugins.harden]               (L62)
STREAMDOWN_PLUGINS = { code, mermaid, cjk }                                  (L63)
LINK_SAFETY       = { enabled: false }                                       (L65)
```

- **Fork 插件替换确认**：`REHYPE_PLUGINS` 没有沿用 streamdown 默认的 `rehype-raw + rehype-sanitize`，而是替换为 `[rehypeKatex, harden]`；`rehype-raw` 仅存在于 `package.json` 依赖清单（L90），src 中无 `rehypeRaw` 使用点。
- `Streamdown` props（L354-370，逐行核验）：`mode`（L356）、`parseIncompleteMarkdown`（L357）、`animate`（L358）、`animationDuration={500}`（L359）、`linkSafety`（L360）、mermaid 错误组件（L370）；含 `className`/`messageId`。
- 插件引用被 hoist 到模块级常量（L58-60 注释：Streamdown 是 memoized 的，若每次渲染传入新字面量会破坏 memo，导致每个流式 token 全量重解析 + 重高亮）。
- 代码块样式钩子：`[data-streamdown="code-block-header"]` 相关样式在 `index.css:261`。

### 2.2 流式优化

- 流式输入走 AI SDK `useChat`（throttle 50ms），`useDeferredValue` 合并 token（L220-231）；
- 流式中代码块不跑 Shiki（`StreamingCode`，L72-95）：活动代码块在流式期间渲染纯文本，避免每 token 全量高亮（webkitgtk 慢）；流结束由 Shiki `CodeBlock` 接管；
- LaTeX 规范化占位符管道（L97-201）：PUA 占位符保护代码/数学 → 逐行 `maskInlineMath` → 货币 `\$` 转义 → ZWSP 修复强调 flanking（`fixEmphasisFlanking`，L103-108）→ `\[..\]`/`\(..\)` → `$$..$$`。ZWSP 只加在代码/数学被遮蔽之后，避免 KaTeX 报 “Unrecognized Unicode character 8203”。

### 2.3 组件覆盖

- `a` → `#cite-`/`#webcite-` 锚点（`CitationLink`/`WebCitationChip`，L234-250）；
- `table` → `MarkdownTable`；
- HTML 工件分段：仅非流式 + 设置开启；svg 分支强制 `allowScripts={false}`（L258-296）；
- 代码块 `code-block.tsx`：shiki `codeToHtml`，light/dark 双高亮。

### 2.4 HTML 消毒、工件与链接渲染

- 正文 HTML 消毒由 streamdown fork 的 `defaultRehypePlugins.harden` 承担（L62）；仓库源码中未发现 DOMPurify 使用；
- `LINK_SAFETY = { enabled: false }`（L65、L360）——链接安全检查被显式关闭；
- `web-app/src/containers/HtmlArtifact.tsx`（151 行）：iframe 承载，默认严格 CSP + sandbox 不透明源；`allowNetwork`/`allowScripts` props 可放宽（非流式 + 设置开启时）；
- 链接不再直接跳转，而是锚点到引用区（`#cite-`/`#webcite-`），配合 `web-citation-store.ts` 与 `WebSourcesRow` 展示来源。`lib/citation-parser.ts` 与 `lib/grounding.ts`（句子切分 + 余弦相似度）负责从工具输出提取引用并做真值校验。

## 3. 边界与未验证事项

- streamdown 内部 harden 的标签/属性白名单无法从本仓库源码确认（推测项）；
- `LINK_SAFETY={enabled:false}` 的影响范围（streamdown 按协议白名单过滤链接的逻辑）未确认；
- RAG `retrieve` 返回的 citations 载荷结构以 `citation-parser.ts` 与 `rag-extension` 索引为准，未核对运行时实际 JSON；
- `editMessage` 后重新渲染、分支切换时的引用/grounding 状态一致性未验证；
- “无语音输入”结论基于源码搜索（`speech`/`voice`/`webkitSpeechRecognition` 无命中），未运行验证；
- `MermaidError`（30 行）在流式错误时直接展示，错误内容/样式未运行确认；
- 未运行项目测试或构建；记录来自静态源码，UI 行为（动画、无障碍、平台差异）需运行验证。

## 4. 关键源码索引

- 渲染主组件：`web-app/src/containers/RenderMarkdown.tsx`（380 行）
- 消息部件分派：`web-app/src/containers/MessageItem.tsx`（683 行）
- 输入区：`web-app/src/containers/ChatInput.tsx`（2648 行，无语音）
- 部件类型：`web-app/src/containers/message/types.ts`（36 行）
- 消息转换：`web-app/src/lib/messages.ts`
- 引用解析 / grounding：`web-app/src/lib/citation-parser.ts`、`web-app/src/lib/grounding.ts`
- HTML 工件：`web-app/src/containers/HtmlArtifact.tsx`（151 行）
- 代码块：`web-app/src/components/ai-elements/code-block.tsx`
- 工具卡片：`web-app/src/components/ai-elements/tool.tsx`、`tool-runtime.tsx`；`RagToolWidget.tsx`、`WebToolWidget.tsx`
- 渲染子组件：`ChainOfThoughtGroup`（296 行）、`ToolCallCard.tsx`（120 行）、`Citations`（224 行）、`CitationLink`（90 行）、`WebSourcesRow`（63 行）、`MarkdownTable`（156 行）、`MermaidError`（30 行）
- 样式钩子：`index.css:261`（`[data-streamdown="code-block-header"]`）
- 列表容器：`web-app/src/containers/conversation.tsx`