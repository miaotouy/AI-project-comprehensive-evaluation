# Open WebUI 消息渲染器调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：只读源码核对（src/lib/components/chat/Messages 组件树、src/lib/utils/marked 扩展、src/lib/utils/index.ts、Artifacts/代码执行相关）；未修改目标仓库
>
> 调查范围：渲染入口分发、Markdown 管线与自定义扩展、代码高亮与 Math、HTML 消毒、可视化与 Artifacts 沙箱、结构化输出、代码执行、流式渲染优化、引用渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的消息渲染采用「marked lexer 出 token 树 + Svelte 组件逐个渲染 token」的管线，而不是 marked 官方 HTML renderer 的字符串输出。

- 消息渲染入口收到一条消息后先按角色分流，助手消息再按父消息的模型数量决定单条渲染还是多模型并排；消息列表借助浏览器原生的 `content-visibility: auto` 跳过离屏内容的绘制（`Messages/Message.svelte`）；
- Markdown 解析由 `marked ^9.1.0` 承担，扩展语法全部由项目自制，同时关闭单波浪线删除线，逐项为：
  - details 折叠块；
  - KaTeX 公式；
  - 引用标记 `[1]` 与 `[1#foo]`；
  - 脚注；
  - 冒号围栏 `:::`；
  - 提及标记 `@`/`#`/`$` 与下划线 `++text++`；
- 代码块高亮用 highlight.js，主题固定为 github-dark；编辑模式换用 CodeMirror 6，Shiki 只服务于 Notebook 文件预览；
- 公式由 KaTeX 渲染，单例懒加载并附带 mhchem 化学语法；`renderToString` 失败时把源文本转成 HTML 实体再输出，原始字符不会进入 `{@html}` 注入点；
- HTML token 先经 DOMPurify 的默认配置清洗再渲染；Mermaid 与 Vega 生成的 SVG 另走一遍 `sanitizeSvg` 白名单清洗，Vega 的 loader 还会阻断一切外部资源；
- Artifacts 的 HTML/SVG 预览运行在 srcdoc iframe 中，沙箱只放行脚本与下载，可选叠加表单与同源权限；容器用 `injectCsp` 把 CSP meta 注入预览内容，配置默认空字符串即不施加 CSP，iframe 内的外部导航一律被拦截；
- 消息带 `message.output` 时改由 `StructuredOutputRenderer` 接管，工具调用、思考过程与代码解释器结果被归组为可折叠详情项，与正文混排；
- 代码执行有两条通道：浏览器端把代码交给 Pyodide，运行在 opaque origin 的 `sandbox="allow-scripts"` iframe 里；后端通道调用 Jupyter 引擎的 `executeCode` API；
- 流式渲染用 requestAnimationFrame 节流并按 token 复用节点：内容变化时合并成一次解析，完成信号到达立即处理并取消残留帧，`{#key id}` 与 `TextToken` 配合让整棵消息树免于重建；
- 工具与检索内容按各自结构渲染，原始检索文本不拼进正文：引用来源经 `sources` 数组推送后渲染成引用列表与正文里的 `[n]` 内联按钮；模型输出中的 `{{HTML_FILE_ID_*}}` 这类占位符由 `replaceTokens` 展开成 `<file type="html">` 或 `<video>` 标签。

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
  -> marked.lexer（Markdown.svelte:87）
  -> MarkdownTokens.svelte 逐 token 渲染（150-583 行）
  -> 块级组件（CodeBlock / details / HTMLToken / KatexRenderer / SourceToken ...）
```

Colon fence 扩展还接受花括号中的双引号属性。写作块可用 subject 作为标题、用 recipient 补充标题行；未带这些属性时仍显示 fence 类型。属性只在扩展定义的区块首行解析，未闭合或非花括号形式不会作为元数据采纳（`src/lib/utils/marked/colon-fence-extension.ts:12-38`、`Markdown/ColonFenceBlock.svelte:21-26`）。

- `Markdown.svelte` 的 `<script context="module">`（1-28 行）用 `marked.use(...)` 注册全部扩展；
- token 覆盖共 14 类，逐一有对应渲染分支：

  ```text
  hr / heading / code / table / blockquote(alert) / list / details / html
  / iframe / paragraph / text / inlineKatex / blockKatex / colonFence
  ```
- 代码 token 分两种走向：带围栏标记的代码块交给 `CodeBlock` 渲染，没有围栏的按纯文本输出（163-188 行）；
- 相邻的工具调用、思考过程与代码解释器详情会合并成一个 `detail_group`，再展开成折叠面板和工具调用卡片（384-495 行）；
- details 折叠块由 marked 扩展逐层配对解析，并保留块上的 `type` 属性（`utils/marked/extension.ts` 29-103 行）；
- 正文中的 `[1]`、`[1,2]`、`[1#suffix]` 引用标记由 `citation-extension.ts` 转成 citation token，再渲染成行内按钮；
- `:::` 冒号围栏交给 `colon-fence-extension.ts` 分词，围栏类型拼进 class 名，内部内容重新走一遍块级 token；
- 下划线标记完成行内分词后交给 renderer，输出 `<u>` 包裹解析好的行内 token（`src/lib/utils/marked/extension.ts:90`）；
- 脚注的 `<sup>` 同样先过 `DOMPurify.sanitize`（`MarkdownInlineTokens.svelte` 129-132 行）。

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

- 聊天内嵌 HTML token 一律走 HTMLToken（MarkdownTokens.svelte 497 行附近）；模型正文的 `<`/`>` 先经 `sanitizeResponseContent` 转义成实体（utils/index.ts 86-95 行），因此正文中的 HTML 标签多数以文本呈现，触发 HTML token 的形态有限（推测：与模型输出约定有关，未实测）。

## 4. 可视化与 Artifacts

- 代码块只有在语言为 mermaid、vega 或 vega-lite 且围栏闭合时才调用图表渲染，生成结果可交给 SvgPanZoom 放大查看（`CodeBlock.svelte` 358-390 行，缩放交互在 433-446 行）；
- mermaid 初始化时关闭 HTML 标签渲染，安全级别取 `'loose'`，产出的 SVG 仍要经 `sanitizeSvg` 白名单清洗（`utils/index.ts` 1954-1963 行）；
- Artifacts 在 iframe 内拦截点击，指向外部的链接只打一条 `console.info` 就终止，不触发导航；预览内容先经 `injectCsp` 注入 CSP 再写入 srcdoc，沙箱放行脚本与下载，CSP 字符串取自配置 `ui.iframe_csp`，默认空值即不注入；多个 CSP meta 并存时以第一个为准（`Artifacts.svelte` 41-61 行、246-260 行，`csp.ts`）；
- 引用文档预览在 `CitationModal.svelte`（215-257 行）中打开：iframe 沙箱为 `sandbox="allow-scripts allow-forms"`，可再叠加同源权限，srcdoc 同样带 CSP；普通文本用 Markdown 或 `<pre>` 展示，HTML 内容进入沙箱 iframe。

## 5. 结构化输出与代码执行

- 结构化输出的 token 构建集中在 `structuredOutput.ts`：工具调用、思考过程和代码解释器结果各自转成详情 token，其中思考过程加 `>` 引用前缀，代码解释器正文放进带语言标记的代码块；
- `buildOutputDisplayItems` 把这些 token 排成 message 与详情交替的展示序列：空槽位先补占位再写入，避免后续展开时出现 undefined 片段，事件流写到越界处则追加新槽位（`src/lib/components/chat/Messages/structuredOutput.ts` 166-186 行、344 行、465-500 行）；
- 终端文件结果是否内联，取决于结果标记与终端文件显示设置，`displayed` 字段不参与这项判定（`StructuredOutputRenderer.svelte` 164-169 行）；
- `StructuredOutputRenderer.svelte`（43-168 行）按条目类型分派：message 条目交给 Markdown 渲染，纯文本场景直接输出文本；详情条目交给 `ToolCallDisplay` 或 `Collapsible`；
- `CodeExecutions.svelte`（28-63 行）在消息带 `message.code_executions` 时显示齿轮徽章和 error/output/incomplete 状态点；`CodeExecutionModal.svelte` 展示 ERROR、OUTPUT 以及 `result.files` 里的文件链接；
- 执行后端按 `$config.code.engine` 选择通道：配置为 `'jupyter'` 时调用 `executeCode` API，从 stdout 中抽出 `data:image/png` 图片；
- 浏览器通道由 `executePythonAsWorker` 驱动 Pyodide worker，运行前自动探测 import 并解析依赖，超时设为 60 秒；worker 宿主是 `sandbox="allow-scripts"` 的 srcdoc iframe，matplotlib 图形以内联 base64 PNG 补丁返回（`CodeBlock.svelte` 149-356 行）。

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

- `Markdown.svelte`（61-97 行）在内容变化时分两种走向：消息已完成就直接分词，仍在流式输出则用 requestAnimationFrame 把多次更新合并成一次解析；完成信号到达时取消残留帧，上次内容与上次已解析内容两份缓存让重复分词直接跳过；
- `MarkdownTokens.svelte`（43-54 行）把 text token 交给行内 token 组件再落到文本节点，流式期间省去整棵 DOM 的替换；标题、段落与表格用 `svelte:self` 递归，沿用同一份 token 引用；
- `ResponseMessage.svelte`（193-196 行）在流式期间先对 message 做 `structuredClone` 快照，再快速比对内容、完成标志与 output，避免属性抖动触发组件销毁重建；
- `CodeBlock.svelte`（400-402 行）用 `_token` 记录版本，文本没变就不再重新 `render()`。

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
