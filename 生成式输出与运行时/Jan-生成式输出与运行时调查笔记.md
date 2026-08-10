# Jan 生成式输出与运行时调查笔记

> 调查对象：`../../jan`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：静态源码调查；grep/glob 关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、exec、spawn、eval、wasm、writeFile 等）；阅读聊天生成、消息渲染、线程持久化与工具执行主链路；未运行应用与测试
>
> 调查范围：模型输出从生成到展示、运行、编辑、保存、重开、回流的主链路；HTML/SVG artifact 预览；工具结果的物化程度；扩展系统对输出生命周期的影响。模型加载、推理调度、RAG 向量库、下载与更新等不在本次范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的模型输出默认止于消息正文：文本/Markdown/代码块/数学/Mermaid 全部作为消息 part 持久化与重渲染，没有独立对象身份。唯一的例外是实验性 HTML/SVG artifact 预览（设置项 `renderHtmlArtifacts`，默认关闭）：把 ```html```、```svg``` 围栏和裸 `<svg>` 从消息文本中拆出，在 sandboxed iframe（`allow-scripts`、不透明源、严格 CSP、默认禁网）里运行。该 artifact 在渲染时从消息文本推导，无稳定 ID、无状态持久化、无宿主桥（无 postMessage）、无模型可寻址对象身份，模型回流只能按消息文本整体重写。全程未找到代码执行器、notebook、画布、文件生成或 diff/patch 机制；工具结果（Web 搜索、RAG、MCP）以只读卡片展示，不物化为可操作对象。能力等级：主体为 **G1**（富静态结果：SVG/HTML 预览、内联媒体、表格导出），存在 **G3 的窄实现**（HTML artifact 进入专用沙箱运行环境、用户可切换代码/预览并操作页面脚本），但缺对象模型、能力桥与可恢复运行状态，未达 G3 完整语义。

## 系统边界与完整主链路

本类目在 Jan 中的边界很窄：所有生成输出都落在 `web-app/src` 前端；后端 Rust 层（`src-tauri/src/core`）只做消息持久化、推理代理与工具执行调度，不解释任何生成内容。扩展层（`extensions/*`）提供推理、RAG、向量库、会话存储等能力，没有输出运行时。

已走通的主链路（触发 → 生成 → 展示/运行 → 交互 → 保存 → 重新打开）：

1. 触发：用户提交 → `processAndSendMessage` 构建 AI SDK `UIMessage`（web-app/src/routes/threads/$threadId.tsx:913-1123）→ `sendMessage` → `CustomChatTransport` 组装上下文并 `streamText`（web-app/src/lib/custom-chat-transport.ts:1296-1375）。
2. 生成：文本 delta 流式进入消息 parts；`onFinish` 将完成的消息转为 `ThreadMessage`（content 数组含 text/file/reasoning 等）写入后端（web-app/src/routes/threads/$threadId.tsx:293-460）。
3. 保存：Rust 把消息写入 `threads/<threadId>/messages.jsonl`（src-tauri/src/core/threads/commands.rs:142-300；mod.rs:5-10 说明单线程串行写保证一致性）。事实源是消息 JSONL，文件中不存在 artifact 对象。
4. 展示/运行：`MessageItem` 渲染文本 part → `RenderMarkdown`；若设置开启且非流式，`splitHtmlArtifacts` 把 html/svg 围栏拆出，html 段交给 `HtmlArtifact`（代码/预览双页签，预览为沙箱 iframe），svg 段以禁脚本静态预览渲染（web-app/src/containers/RenderMarkdown.tsx:254-307；web-app/src/components/HtmlArtifact.tsx:66-149）。
5. 交互：页签切换；iframe 内模型脚本可运行但与宿主零通道。
6. 重新打开：`fetchMessages` 读回 JSONL → `convertThreadMessageToUIMessage`（web-app/src/lib/messages.ts:203-339）→ 同一渲染链按消息文本重新推导 artifact。链路闭合，但闭合的是"文本渲染"，不是对象恢复。

模型继续维护闭环（查询 → 读取 → 定向修改）：**未找到**。artifact 无 ID、无查询接口；模型只能通过转录文本感知内容，继续回合时整段文本进入上下文（web-app/src/lib/custom-chat-transport.ts:1310-1349），不存在对同一对象的定向修改。

## 1. 触发方式、输出协议与对象模型

- 触发方式：HTML/SVG artifact 完全由模型自由文本中的围栏触发，无用户命令、无结构化 part、无工具调用参与。识别正则 `ARTIFACT_RE` 匹配 ```html```、```svg``` 围栏及裸 `<svg>…</svg>`，其余围栏（js、py 等）原样留在 Markdown 流中（web-app/src/lib/utils.ts:72-121）。误触发防护：`bodyIsLoneSvg` 要求围栏体是孤立的 SVG；流式中不拆段，未闭合围栏不会在 token 中途被抽出（web-app/src/containers/RenderMarkdown.tsx:258-264）。协议处理的是正则文本，无转义与嵌套概念——嵌套围栏不会被该正则识别，直接留在正文。
- 对象模型：**不存在独立对象**。artifact 是渲染期派生物：类型只有 html/svg 两种（由围栏语言决定），无稳定 ID、无来源消息字段、无版本、无状态、无能力声明。聊天消息（`ThreadMessage`）是唯一事实源；运行实例（iframe）是瞬态 DOM。输出协议开放度：自由文本探测级别，无 typed part 或 UI schema。
- 消息对象本身有完整身份：`id`、`thread_id`、`role`、`status`、`created_at`、`metadata`（含 `parentId` 分支、`stopped` 等）（web-app/src/routes/threads/$threadId.tsx:397-411），但那是 Chat/消息层身份，不属于输出对象。

## 2. 增量生成、更新与最终化

- 流式输出按 token 增量更新消息文本 part；`RenderMarkdown` 用 `useDeferredValue` + 条件 memo 合并高频渲染，流式中走 `StreamingCode` 纯文本路径避免每 token 高亮（web-app/src/containers/RenderMarkdown.tsx:68-95, 216-231, 347-352）。这属于消息渲染器的增量机制。
- artifact 的"更新"是整体替换：非流式且设置开启时，`normalizedContent` 变化会使 `segments` 重新拆分、`HtmlArtifact` 的 `srcDoc` useMemo 重建（web-app/src/components/HtmlArtifact.tsx:77-81）。没有 AST 节点更新、没有 diff/patch 应用——搜索 `diff|patch` 在输出链中未找到任何应用机制（仅日期差值与 MCP schema 修补等无关命中）。
- 最终化收口：`onFinish` 持久化消息；`finishReason === 'length'` 时标记 `stopped` 并提供 Continue（重放前缀继续生成）（web-app/src/routes/threads/$threadId.tsx:301-341, 1352 起）；流式结束前 artifact 预览页签禁用（`isStreaming` 时强制 Code 视图，HtmlArtifact.tsx:83-84, 120-127）。

## 3. 投影表面与多视图关系

- 表面只有一个：消息正文内联（`HtmlArtifact` 直接渲染在消息流中）。无侧栏、独立标签页、画布、桌面或外部浏览器投影；无多视图同步（代码视图与预览视图是同一组件的互斥页签，切换即卸载 iframe）。搜索 `canvas|notebook|webview` 未发现其他投影面（sidebar 的 "offcanvas" 是 CSS 折叠布局，与本类目无关）。
- 源（消息文本）→ 投影（artifact 组件）→ 运行实例（iframe）简化为两级：运行实例总是从源即时重建，无中间持久态。

## 4. 表现类型、依赖与运行环境

- 表现层级：静态 Markdown（GFM、KaTeX、Streamdown 代码块、Mermaid 图）覆盖 G0 至 G1 静态层；HTML artifact 是唯一动态层——模型 HTML/CSS/JS 在 iframe 中执行（`sandbox="allow-scripts"`，无 `allow-same-origin` → 不透明源，`referrerPolicy="no-referrer"`）（web-app/src/components/HtmlArtifact.tsx:136-143）。
- 依赖提供：iframe 用 `srcDoc` 内联，`buildSrcDoc` 在最前注入 `<meta http-equiv="Content-Security-Policy">` 保证 meta CSP 先于任何可触发资源加载的内容（HtmlArtifact.tsx:54-64）。默认 CSP `default-src 'none'`、`connect-src 'none'`、`img-src data: blob:`、`style-src 'unsafe-inline'`、`font-src data:`，禁网；`allowNetwork` 参数可放宽到 `https:`，但产品代码从未传入（仅测试使用）（HtmlArtifact.tsx:24-52；grep `allowNetwork` 在 web-app/src 仅见组件与测试）。SVG 段禁脚本（`allowScripts={false}`，sandbox 为空串，CSP 无 `script-src`）（RenderMarkdown.tsx:280-285）。
- 产品文案与实现一致：设置页说明"HTML runs the model-generated page in a sandboxed frame that executes its own scripts but cannot access Jan, your files, or the network"（web-app/src/locales/en/settings.json:104）。该功能标注 experimental，默认关闭（web-app/src/hooks/useInterfaceSettings.ts:186）。

## 5. 用户交互、事件与错误反馈

- artifact 内交互：页签切换（Code/Preview）；iframe 内模型页面自身的按钮、表单、JS 状态可操作（运行期由浏览器承担）。iframe 与宿主之间**零通道**：无 `postMessage`/`onMessage` 处理（全仓搜索仅命中推理消息类型等无关项），无尺寸、日志、错误或运行状态回传；Mermaid 渲染失败有独立错误组件（web-app/src/containers/RenderMarkdown.tsx:329-339，属于渲染器层）。
- 交互状态不恢复：切到 Code 视图即卸载 iframe，切回重建全新文档；应用重载后从文本重建。预览高度用 CSS `resize-y` 可拖拽，属浏览器原生行为，不持久化。
- 工具结果（Web 搜索/抓取、RAG、MCP）以只读卡片展示：搜索条/地址栏样式的 `ToolBar` + 结果链接行、引用卡片、文本片段（web-app/src/containers/message/WebToolWidget.tsx:59-152；RagToolWidget.tsx:25-103）。可点击打开外部链接，但不可操作、不可编辑、不可保存为对象——停在"工具结果的展示"边界，未物化。

## 6. 编辑、diff、版本与协作

- 用户编辑：消息级全文覆盖编辑——`EditMessageDialog` 编辑消息全文（含 assistant 消息），保存后触发重生成（web-app/src/containers/MessageItem.tsx:102-107, 566-604；web-app/src/containers/dialogs/EditMessageDialog.tsx）。编辑对象是消息文本，不是 artifact；artifact 随消息文本整体重建。
- 版本：消息分支（parentId/activeRootId，`< n/m >` 版本切换，重生成保留旧版本为 sibling）（web-app/src/routes/threads/$threadId.tsx:1223-1288, 1317-1346）属于消息版本，非对象版本。无 artifact 级接受/拒绝、无 diff 视图、无 CRDT、无协作。
- 模型侧无编辑能力：模型不通过任何机制修改已生成消息（重生成/续写会生成新的一条）。

## 7. 能力桥、执行位置与权限范围

- artifact 能力桥：**无**。iframe 不透明源 + CSP 禁网 + 无 postMessage，模型页面无法请求网络、存储、模型或宿主动作；唯一"能力"是自身脚本执行。
- 工具执行位置（与本类目交界，属 Agent 工具类目）：Web 搜索/抓取在 Rust 进程内用 reqwest 调 Exa/Tavily/SearXNG（src-tauri/plugins/tauri-plugin-websearch/src/provider.rs:53-64, 110-245）；RAG 走扩展（extensions/rag-extension）；MCP 工具经 `serviceHub.mcp().callTool` 调 Rust MCP 客户端（web-app/src/routes/threads/$threadId.tsx:482-587）。执行调度与审批属 Agent 工具调查，本笔记只记交接点：这些工具的结果以文本/JSON 回填消息，未产生可操作对象。
- 外部执行桥（能力桥的另一次应用）：Claude Code 集成把 Jan 本地 OpenAI 兼容服务器地址写入 shell 环境文件并提示用户自行启动外部 CLI（web-app/src/routes/settings/claude-code.tsx:70-205；src-tauri/src/core/system/commands.rs:394-540）；`jan-cli launch` 用环境变量派生外部 agent 程序（claude、openclaw）并 spawn（src-tauri/src/bin/jan-cli.rs:1143-1226）。执行面在外部终端，Jan 只提供模型后端与配置，不在 Jan 内产生输出对象。

## 8. 持久化、恢复、分享与导出

- 持久化内容：只有消息源文本（text content part）及内联媒体 part。Rust 侧对 `messages.jsonl` 整文件重写实现 modify/delete（src-tauri/src/core/threads/commands.rs:222-300）；读回按行解析（helpers.rs:46）。artifact 的 iframe 运行状态、视图选择、交互状态一律不持久化。
- 分享/导出：消息级 `CopyButton` 复制全文；`MarkdownTable` 提供 CSV/Markdown 下载（web-app/src/components/MarkdownTable.tsx:46-51, 91-138，属渲染器层的表格导出）。artifact 本身无下载/导出按钮；assistant 生成的图片在消息内可点击放大预览（MessageItem.tsx:395-407, 645-657），无下载按钮。未发现分享链接机制。
- 恢复：重开线程时从 JSONL 恢复文本并重新推导 artifact——恢复的是"文本→派生渲染"，不是对象或运行状态。

## 9. 模型回流、对象感知与持续维护

- 回流通道唯一且是文本级：每次生成时 `convertToModelMessages` 把历史消息（含 assistant 文本，即 artifact 围栏原文）整段放入请求体（web-app/src/lib/custom-chat-transport.ts:1310-1375）；上下文超限时 `context-manager.ts` 裁剪或摘要旧消息。模型"看到"的 artifact 与其输出形态一致，无独立视图。
- 对象感知：无对象列表查询、无源码读取接口、无运行状态观察。对象身份不绑定到后续回合：每次"修改"都是整条消息重新生成或续写，无法定位单个 artifact。因此闭环（查询→读取→定向修改）**未实现**；持续维护只以"转录文本继续对话"的弱形式存在（Continue 重放部分文本、Regenerate 重新生成），这是 Chat 类目行为而非输出对象维护。

## 10. 生命周期、资源治理与性能

- iframe 生命周期随组件：切换 Code 视图或消息重渲染即卸载，无定时器/动画/媒体/进程登记与释放机制（浏览器默认回收）；iframe 内模型页面可自行开定时器等资源，宿主不管理。渲染期唯一的节流是 `useDeferredValue` 与 memo（见第 2 节）。
- 无对象级限额：消息无长度上限审计（上下文裁剪按 token 预算处理整段对话，见 `context-manager.ts`）；多 artifact 场景仅受 DOM 与 iframe 数量约束，未见专门治理。持久化文件为单 JSONL 整写，长线程每次 modify/delete 全量重写（src-tauri/src/core/threads/commands.rs:222-300），属性能与一致性的既有取舍。

## 11. 测试、已确认边界与未验证事项

- 测试覆盖（静态确认，未运行）：`HtmlArtifact.test.tsx` 覆盖默认预览视图、页签切换、sandbox 属性（allow-scripts、无 allow-same-origin）、CSP 注入与禁网断言、SVG 禁脚本模式、`allowNetwork` 放宽、流式中预览禁用、全文档包装（web-app/src/components/__tests__/HtmlArtifact.test.tsx:37-112）；`RenderMarkdown.test.tsx` 覆盖设置开关、流式回退、非 html 围栏不拆（web-app/src/containers/__tests__/RenderMarkdown.test.tsx:435-490）；`utils.test.ts` 覆盖拆分正则（web-app/src/lib/__tests__/utils.test.ts:406-419）。这些是 DOM 属性/srcdoc 字符串级断言，不验证真实脚本执行。
- 未验证事项（未运行应用）：iframe 内脚本的实际执行行为、CSP 在 WebKitGTK/WebView2/WKWebView 三平台的实际生效、切页签后 iframe 状态丢失的具体表现、重开线程后 artifact 重建的视觉效果。上述均为静态代码推断之外的运行时行为。
- 已确认边界（本次未找到，搜索范围：web-app/src、extensions/*、src-tauri/src 全仓）：代码执行器（无 spawn/child_process/exec/eval/new Function/WebAssembly 用于生成内容，唯一进程 spawn 是 llamacpp 推理 router）；notebook/画布/工作区对象（无 canvas/notebook 输出面）；模型输出落盘为独立文件（web-app 无写文件调用，仅设置存储与 Claude Code 环境文件）；diff/patch 应用机制；artifact 的宿主桥与下载/分享入口。核心库 `core/` 与文档站 `docs/` 未纳入以上搜索范围。

## 12. 关键源码索引

- `web-app/src/components/HtmlArtifact.tsx:24-52`（CSP 构建）、`:54-64`（srcDoc 包装）、`:66-149`（组件：页签 + 沙箱 iframe）
- `web-app/src/lib/utils.ts:72-121`（ARTIFACT_RE 与 splitHtmlArtifacts 拆分协议）
- `web-app/src/containers/RenderMarkdown.tsx:254-307`（artifact 门控与分段渲染）
- `web-app/src/hooks/useInterfaceSettings.ts:138,186,270-272`（renderHtmlArtifacts 设置，默认 false）
- `web-app/src/containers/MessageItem.tsx:246-411, 504-657`（文本/媒体 part 渲染与预览）
- `web-app/src/routes/threads/$threadId.tsx:293-460`（onFinish 持久化）、`:482-587`（工具执行循环）、`:913-1123`（发送链路）、`:1223-1346`（版本/重生成）
- `web-app/src/lib/custom-chat-transport.ts:1296-1375`（上下文组装与回流）
- `web-app/src/lib/messages.ts:203-339`（ThreadMessage ↔ UIMessage 转换）
- `src-tauri/src/core/threads/commands.rs:142-300`（messages.jsonl 读写）、`src-tauri/src/core/threads/mod.rs:5-10`（串行写设计）
- `src-tauri/plugins/tauri-plugin-websearch/src/provider.rs:53-64, 110-245`（Rust 侧搜索/抓取执行）
- `src-tauri/src/core/system/commands.rs:394-540`（Claude Code 环境配置）
- `src-tauri/src/bin/jan-cli.rs:1143-1226`（jan-cli launch 外部 agent 派生）
- `web-app/src/containers/message/WebToolWidget.tsx`、`RagToolWidget.tsx`（工具结果只读展示）
- `web-app/src/components/__tests__/HtmlArtifact.test.tsx`、`web-app/src/containers/__tests__/RenderMarkdown.test.tsx:435-490`（验证用例）
