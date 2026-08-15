# Open WebUI 消息渲染器调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读源码核对（src/lib/components/chat/Messages 组件树、src/lib/utils/marked 扩展、src/lib/utils/index.ts、Artifacts/代码执行相关）；未修改目标仓库
>
> 调查范围：渲染入口分发、Markdown 管线与自定义扩展、代码高亮与 Math、HTML 消毒、可视化与 Artifacts 沙箱、结构化输出、代码执行、流式渲染优化、引用渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的消息渲染采用「marked lexer 出 token 树 + Svelte 组件逐个渲染 token」的管线，而不是 marked 官方 HTML renderer 的字符串输出。

- 渲染入口 `Messages/Message.svelte` 按 `role` 与父消息模型数分发到 `UserMessage` / `ResponseMessage` / `MultiResponseMessages`，并利用浏览器原生 `content-visibility: auto` 做离屏虚拟化；
- Markdown 库为 `marked ^9.1.0`，扩展全部自制：`<details>` 块、KaTeX、引用标记 `[1]`/`[1#foo]`、脚注、`:::` 冒号围栏、`@/#/$` 提及，并禁用单波浪线删除线；
- 代码高亮用 highlight.js（仅 github-dark 主题），只读渲染走 hljs，编辑模式改用 CodeMirror 6；Shiki 仅用于 Notebook 文件预览；
- Math 用 KaTeX（动态加载 + mhchem），`renderToString` 失败时把源文本 HTML 实体化后输出，避免原始字符进入 `{@html}`；
- HTML token 一律先 `DOMPurify.sanitize`（默认配置）再渲染；Mermaid/vega 生成的 SVG 再经 `sanitizeSvg` 白名单清洗；Vega loader 阻断一切外部资源；
- Artifacts（HTML/SVG 预览）是沙箱：srcdoc iframe + `sandbox="allow-scripts allow-downloads"`（可选 allow-forms/allow-same-origin）+ `injectCsp` 注入 CSP meta（默认空字符串即无 CSP），并拦截 iframe 内所有外部导航；
- 结构化输出：`message.output` 存在时走 `StructuredOutputRenderer`，把工具调用/reasoning/code_interpreter 归组为 detail 项与正文混排；
- 代码执行双通道：浏览器端 Pyodide（iframe `sandbox="allow-scripts"` 隔离、opaque origin），或后端 Jupyter 引擎（`executeCode` API）；
- 流式渲染用 rAF 节流 + token 级复用：`content` 变化时 requestAnimationFrame 合并一次解析，`done` 时立即处理并取消残留帧；`{#key id}` + `TextToken` 复用避免整棵树重建；
- 工具/检索内容不直接进正文：引用来源经 `sources` 数组推送渲染为 Citations 列表与正文 `[n]` 内联按钮；模型输出中的 `{{HTML_FILE_ID_*}}` 等占位符由 `replaceTokens` 展开成 `<file type="html">`/`<video>` 标签。

## 1. 渲染入口分发

| 文件 | 行为 |
|---|---|
| `Messages/Message.svelte`（57-147 行） | `role==='user'` → `UserMessage`；否则按父消息 `models.length===1` 分发 `ResponseMessage` / `MultiResponseMessages` |
| `Messages.svelte`（155-157 行） | `.chat-listitem { content-visibility: auto }` 离屏虚拟化（Safari 跳过） |
| `ResponseMessage.svelte` | 助手消息外壳：可见内容 = `getOutputText(message.output)` 剔除 output 条文或 `removeAllDetails(content)`（188-190 行）；模型附件 image/file（687-709 行）；`embeds` → `FullHeightIframe allowScripts=true`（711-728 行）；错误/Citations/CodeExecutions 分区（878-894 行） |
| `UserMessage.svelte`（384-400 行） | 用户消息内容：`renderMarkdownInUserMessages`（默认 true）→ `Markdown`，否则 `whitespace-pre-wrap`；内部消息（timer/subagent）特殊渲染（337-372 行） |
| `MultiResponseMessages.svelte`（40-80 行） | 多模型并行（MoA）并排渲染，内部仍是 `ResponseMessage` |
| `ContentRenderer.svelte`（282-333 行） | 分发：`output.length` → `StructuredOutputRenderer`；否则 `renderMarkdownInAssistantMessages` → `Markdown`；否则抽顶层 `<details>` 特排版 |

## 2. Markdown 渲染管线

```text
content (流式累加)
  -> processResponseContent（尖括号实体化、中文标点修正，utils/index.ts 86-145）
  -> replaceTokens（{{char}}/{{user}}/{{VIDEO_FILE_ID_*}}/{{HTML_FILE_ID_*}} 占位符，仅代码块外替换，utils/index.ts 56-84）
  -> marked.lexer（Markdown.svelte:70-74）
  -> MarkdownTokens.svelte 逐 token 渲染（150-583 行）
  -> 块级组件（CodeBlock / details / HTMLToken / KatexRenderer / SourceToken ...）
```

- `Markdown.svelte` 的 `<script context="module">`（1-28 行）用 `marked.use(...)` 注册全部扩展；
- token 覆盖共 14 类，逐一有对应渲染分支：

  ```text
  hr / heading / code / table / blockquote(alert) / list / details / html
  / iframe / paragraph / text / inlineKatex / blockKatex / colonFence
  ```
- 代码 token：含 ``` 围栏 → `CodeBlock`，否则纯文本（163-188 行）；
- 连续 `tool_calls/reasoning/code_interpreter` details 归并成 `detail_group`，展开 `Collapsible`/`ToolCallDisplay`（384-495 行）；
- `<details>` 块由 `utils/marked/extension.ts`（29-103 行）深度配对解析并捕获 `type` 属性；
- 引用 `[1]`、`[1,2]`、`[1#suffix]` 由 `citation-extension.ts` 生成 citation token → `SourceToken` 渲染为行内按钮；
- `:::` 冒号围栏由 `colon-fence-extension.ts` 分词，`fenceType` 拼入 class 名，内部内容重新走 blockTokens；
- 脚注 `[^]` 的 `<sup>` 也经 `DOMPurify.sanitize`（MarkdownInlineTokens.svelte 129-132 行）。

## 3. 代码高亮、Math 与 HTML 消毒

| 能力 | 实现 | 关键点 |
|---|---|---|
| 代码高亮 | highlight.js ^11.9，`github-dark.min.css` | `hljs.highlight` + `ignoreIllegals: true`（CodeBlock.svelte 566-569 行） |
| 代码编辑 | CodeMirror 6 | `basicSetup` + languages（CodeEditor.svelte） |
| Notebook 预览 | Shiki ^4.0.1 | 仅 `codeHighlight.ts` 175-187 行 + NotebookView |
| Math | KaTeX ^0.16.22 + mhchem | 单例懒加载；分隔符 `$ $$ \(\) \[\ \pu{} \ce{ \begin{equation}`；渲染失败→源文本 HTML 实体化输出（KatexRenderer.svelte 36-46 行） |
| HTML 块 | `DOMPurify.sanitize` 默认配置 | HTMLToken.svelte 11-14 行；YouTube iframe 白名单正则（49-65 行）；通用 iframe 取清洗前 `token.text` 的 src 且带空 `sandbox`（66-85 行）；`<file type="html">` 走 `/api/v1/files/{id}/content/html` 且 `sandbox="allow-scripts allow-downloads"` + 可配置 allow-forms/allow-same-origin（103-125 行） |
| SVG | `sanitizeSvg`（DOMPurify SVG profile） | `utils/index.ts` 1977-2011 行：`USE_PROFILES: {svg, svgFilters}`、允许 `style/foreignObject` 与 class/style/id/data-*/viewBox/href/xlink:href 属性、`SANITIZE_DOM: true` |
| Vega | `loader.sanitize` + `loader.load` | 阻断一切外部资源，仅允许 data:/同源；`renderer: 'none'` |

- 聊天内嵌 HTML token 一律走 HTMLToken（MarkdownTokens.svelte 497 行附近）；模型正文的 `<`/`>` 先经 `sanitizeResponseContent` 转义成实体（utils/index.ts 86-95 行），因此正文中的 HTML 标签多数以文本呈现，真正触发 HTML token 的形态有限（推测：与模型输出约定有关，未实测）。

## 4. 可视化与 Artifacts

- `CodeBlock.svelte`（358-390 行）：仅 mermaid/vega/vega-lite 三种语言且围栏闭合时触发 `renderMermaidDiagram` / `renderVegaVisualization`，结果可放大（SvgPanZoom 433-446 行）；
- mermaid 初始化 `htmlLabels: false`（utils/index.ts 1954-1963 行），`securityLevel: 'loose'` 但输出 SVG 被 `sanitizeSvg` 清洗；
- `Artifacts.svelte`（41-61 行）：iframe 内点击拦截，外部链接仅 `console.info` 阻止不导航；246-260 行 `srcdoc={injectCsp(contents[idx].content, $config?.ui?.iframe_csp)}` + `sandbox="allow-scripts allow-downloads"`；`ui.iframe_csp` 默认空字符串 → 不注入 CSP（csp.ts "first CSP meta wins"）；
- 引用文档预览：`CitationModal.svelte`（215-257 行）`sandbox="allow-scripts allow-forms"` + 可选 allow-same-origin + srcdoc CSP；普通文本预览用 Markdown 或 `<pre>`，HTML 内容走 sandbox iframe。

## 5. 结构化输出与代码执行

- `structuredOutput.ts`（126-195 行）：工具调用、reasoning（加 `>` 引用前缀）、code_interpreter（正文为 ```lang 代码块）构建 detail token；`buildOutputDisplayItems`（266-333 行）产出 message/详情序列；
- `StructuredOutputRenderer.svelte`（43-168 行）：message → Markdown（或纯文本），详情 → `ToolCallDisplay`/`Collapsible`；
- `CodeExecutions.svelte`（28-63 行）：`message.code_executions` → 齿轮徽章 + error/output/incomplete 状态点；`CodeExecutionModal.svelte` 显示 ERROR/OUTPUT + `result.files` 链接；
- 执行后端分两条通道（按 `$config.code.engine` 选择）：配置为 `'jupyter'` 时走 `executeCode` API（从 stdout 抽 `data:image/png`）；否则浏览器端 `executePythonAsWorker`（CodeBlock.svelte 149-356 行，自动探测 import→依赖，60s 超时），经 Pyodide worker 沙箱运行（iframe srcdoc + `sandbox="allow-scripts"`，matplotlib 内联 base64 PNG 补丁）。

## 6. 模型输出 vs 工具/检索内容

| 内容 | 进入方式 | 渲染 |
|---|---|---|
| 模型正文 | SSE `content` 经 `chat:message:delta` / `chat:completion` 累加 | Markdown 管线（正文 token/文本渲染，不经 innerHTML 整体注入） |
| 引用来源 | 后端 `sources` 数组随事件推送 | `Citations.svelte` 列表（按 `distance` 归并、显示占比）+ 正文 `[n]` 行内按钮（SourceToken） |
| 工具/检索细节 | 拆成 `details` / `output` 结构 | StructuredDetails → ToolCallDisplay / 详情标记，不走正文 |
| 代码执行 | `message.code_executions` | CodeExecutions 徽章 + 模态框 |
| 媒体文件 | `{{VIDEO_FILE_ID_*}}` / `{{HTML_FILE_ID_*}}` 占位符 | replaceTokens → `<video>` / `<file type="html">`（HTMLToken 沙箱分支） |

- `formatMessageContent`（ContentRenderer 126-131 行）：模型 `capabilities.citations==false` 时用正则删除正文里的 `[1]`、`[1,2]`、`[1#foo]` 引用标记。

## 7. 流式渲染优化

- `Markdown.svelte`（61-97 行）：`content` 变化时若已完成立即 `parseTokens`，否则 `requestAnimationFrame` 节流合并一次解析；完成时 `cancelAnimationFrame` 丢弃残留帧；`lastContent`/`lastParsedContent` 双缓存避免重复 lexer；
- `MarkdownTokens.svelte`（43-54 行）：text token 经 `MarkdownInlineTokens` → `TextToken`（流式期间避免每次全量替换 DOM）；heading/paragraph/table 递归 `svelte:self` 复用 token 引用；
- `ResponseMessage.svelte`（193-196 行）：流式期间对 message 做 `structuredClone` 快照 + content/done/output 快速比较，避免组件属性抖动导致 destroy/mount；
- `CodeBlock.svelte`（400-402 行）：`_token` 版本跟踪，只有文本真正变化才重新 `render()`。

## 8. 关键文件索引

| 职责 | 文件 |
|---|---|
| 入口分发 | `src/lib/components/chat/Messages/Message.svelte` |
| 内容分发 | `src/lib/components/chat/Messages/ContentRenderer.svelte` |
| Markdown 初始化与流式 lexer | `src/lib/components/chat/Messages/Markdown.svelte` |
| 块级 token 渲染 | `src/lib/components/chat/Messages/Markdown/MarkdownTokens.svelte` |
| 行内 token 渲染 | `src/lib/components/chat/Messages/Markdown/MarkdownInlineTokens.svelte` |
| HTML 消毒与 iframe 分支 | `src/lib/components/chat/Messages/Markdown/HTMLToken.svelte` |
| KaTeX | `src/lib/components/chat/Messages/Markdown/KatexRenderer.svelte` |
| 代码块（hljs/运行/mermaid/vega） | `src/lib/components/chat/Messages/CodeBlock.svelte` |
| 结构化输出 | `src/lib/components/chat/Messages/structuredOutput.ts`、`StructuredOutputRenderer.svelte` |
| Artifacts 沙箱 | `src/lib/components/chat/Artifacts.svelte`、`src/lib/utils/csp.ts` |
| 引用渲染 | `src/lib/components/chat/Messages/Citations.svelte`、`Citations/CitationModal.svelte` |
| marked 扩展 | `src/lib/utils/marked/*.ts`（7 个） |
| 内容预处理/占位符/SVG 清洗 | `src/lib/utils/index.ts`（56-145、1977-2011 行） |
| Pyodide 沙箱 | `src/lib/pyodide/pyodideSandboxHost.ts`、`src/lib/pyodide/createPyodideWorker.ts` |
| 流式事件拼装 | `src/lib/components/chat/Chat.svelte`（2377-2487 行） |
