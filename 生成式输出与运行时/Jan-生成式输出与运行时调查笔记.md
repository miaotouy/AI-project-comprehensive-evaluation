# Jan 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`38491c73d12398edda45ebec366f940e83509490`（分支：`main`）
>
> 调查方式：静态源码调查；grep/glob 关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、exec、spawn、eval、wasm、writeFile 等）；阅读聊天生成、消息渲染、线程持久化与工具执行主链路；未运行应用与测试
>
> 调查范围：模型输出从生成到展示、运行、编辑、保存、重开、回流的主链路；HTML/SVG artifact 预览；工具结果的物化程度；扩展系统对输出生命周期的影响。模型加载、推理调度、RAG 向量库、下载与更新等不在本次范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

普通 Chat 输出仍以消息 part 为事实源：实验性 HTML/SVG 围栏预览在渲染时派生，缺稳定对象 ID 和宿主通道。Cowork 则以文件工具写入工作区，并从工具调用派生文件 Artifact 卡；对既有文件的编辑有差异面板，HTML 可在独立预览面展示。因此“无文件生成、无 diff/patch”只适用于普通 Chat 的围栏预览，不适用于 Cowork。两个表面不能合并成单一能力等级：前者是 G3 的窄沙箱预览，后者有 G4 工作区编辑的部分性质，但接受/拒绝、跨运行对象版本与复原语义尚未验证（`web-app/src/lib/coworkArtifacts.ts:5-21`、`web-app/src/routes/cowork.tsx:1550-1572,1764-1773`）。

## 系统边界与完整主链路

普通 Chat 的渲染入口仍在 web-app，以下主链只描述围栏预览。Cowork 另以 Tauri agent-tools 插件执行文件写入、编辑与 shell，前端依据工具结果构造预览与差异状态；文件内容存于会话沙箱或用户附加的可写目录，消息历史不是文件唯一事实源（`web-app/src/lib/coworkDispatch.ts:209-239`、`src-tauri/plugins/tauri-plugin-agent-tools/src/commands.rs:685-709`）。

已走通的主链路（触发 → 生成 → 展示/运行 → 交互 → 保存 → 重新打开）：

1. 触发：用户提交后，发送入口构建 AI SDK 的 `UIMessage`，再由传输层组装上下文并启动流式生成（发送链路见 web-app/src/routes/threads/$threadId.tsx:913-1123；组装与生成见 web-app/src/lib/custom-chat-transport.ts:1296-1375）。
2. 生成：文本 delta 流式进入消息 parts；生成结束回调 `onFinish` 把完成的消息转为 `ThreadMessage`（content 数组含 text/file/reasoning 等）写入后端（web-app/src/routes/threads/$threadId.tsx:293-460）。
3. 保存：Rust 把消息写入 `threads/<threadId>/messages.jsonl`（src-tauri/src/core/threads/commands.rs:142-300；mod.rs:5-10 说明单线程串行写保证一致性）。事实源就是这份 JSONL 消息文件，文件中不存在 artifact 对象。
4. 展示/运行：消息渲染器渲染文本 part；若设置开启且非流式，拆段逻辑把 html/svg 围栏拆出，html 段交给 `HtmlArtifact`（代码/预览双页签，预览为沙箱 iframe），svg 段以禁脚本静态预览渲染（web-app/src/containers/RenderMarkdown.tsx:254-307；web-app/src/components/HtmlArtifact.tsx:66-149）。
5. 交互：页签切换；iframe 内模型脚本可运行但与宿主零通道。
6. 重新打开：读回 JSONL，把消息对象转回 AI SDK 的 `UIMessage`（web-app/src/lib/messages.ts:203-339），再走同一渲染链按消息文本重新推导 artifact。链路闭合，但闭合的是"文本渲染"，不是对象恢复。

普通 Chat 的围栏 artifact 无文件读取与定向修改；Cowork 可通过 read/find/grep 查找已有文件，再经 edit/write 对同一工作区文件修改。文件路径充当对象定位键，工具执行结果进入后续模型回合（`web-app/src/lib/agentTools.ts:39-56`、`web-app/src/lib/coworkRunner.ts:571-590`）。

## 1. 触发方式、输出协议与对象模型

- 触发方式：HTML/SVG artifact 完全由模型自由文本中的围栏触发，无用户命令、无结构化 part、无工具调用参与。识别正则 `ARTIFACT_RE` 匹配 html/svg 两种围栏及裸 `<svg>…</svg>` 标签，其余语言围栏（js、py 等）原样留在 Markdown 流中（web-app/src/lib/utils.ts:72-121）。防误触发靠两点：一是要求围栏体是孤立的 SVG，二是流式中不拆段，未闭合围栏不会在 token 中途被抽出（web-app/src/containers/RenderMarkdown.tsx:258-264）。协议处理的是正则文本，无转义与嵌套概念——嵌套围栏不会被该正则识别，直接留在正文。
- 普通 Chat 围栏没有独立对象；Cowork Artifact 由 write/edit 的工具轨迹派生，只把新建且扩展名允许的交付文件收为卡片；修改已有文件进入差异面板。文件位于会话沙箱或附加目录，卡片的出现不等于额外复制一份独立文件对象（`web-app/src/lib/coworkArtifacts.ts:5-21`、`web-app/src/lib/coworkDiffs.ts`）。
- 消息对象本身有完整身份：稳定 ID、所属线程、角色、状态、创建时间与元数据（元数据承载 `parentId` 分支、`stopped` 标记等）（web-app/src/routes/threads/$threadId.tsx:397-411），但那是 Chat/消息层身份，不属于输出对象。

## 2. 增量生成、更新与最终化

- 流式输出按 token 增量更新消息文本 part；渲染器用延迟值与条件 memo 合并高频渲染，流式中走纯文本路径避免每 token 高亮（web-app/src/containers/RenderMarkdown.tsx:68-95, 216-231, 347-352）。这属于消息渲染器的增量机制。
- artifact 的"更新"是整体替换：非流式且设置开启时，输入内容变化会使分段与 iframe 的文档源整体重建（`HtmlArtifact` 组件内由 memo 驱动）（web-app/src/components/HtmlArtifact.tsx:77-81）。没有 AST 节点更新、没有 diff/patch 应用——搜索 diff、patch 在输出链中未找到任何应用机制（仅日期差值与 MCP schema 修补等无关命中）。
- 最终化收口：生成完成回调持久化消息；当生成因长度截断结束（`finishReason === 'length'`）时标记 `stopped` 并提供 Continue（重放前缀继续生成）（web-app/src/routes/threads/$threadId.tsx:301-341, 1352 起）；流式进行中预览页签禁用，强制显示 Code 视图（HtmlArtifact.tsx:83-84, 120-127）。

## 3. 投影表面与多视图关系

- 普通 Chat 的 artifact 只有消息内联代码/预览页签；Cowork 提供独立预览、差异与文件侧栏。Cowork 预览可打开沙箱和附加目录中的文件，默认以 `srcdoc` 运行；可选 `preview://` 独立来源按注册 root 提供文件并受宿主 CSP/网络开关约束（`web-app/src/containers/CoworkPreviewPanel.tsx:57-89,141-150,300-310`、`src-tauri/plugins/tauri-plugin-agent-tools/src/preview.rs:1-35`）。
- 源（消息文本）与投影（artifact 组件）构成两级，运行实例（iframe）总是从源即时重建，无中间持久态。

## 4. 表现类型、依赖与运行环境

- 表现层级：静态 Markdown（GFM、KaTeX、Streamdown 代码块、Mermaid 图）覆盖 G0 至 G1 静态层；HTML artifact 是唯一动态层——模型 HTML/CSS/JS 在 iframe 中执行（`sandbox="allow-scripts"`，无 `allow-same-origin` → 不透明源，`referrerPolicy="no-referrer"`）（web-app/src/components/HtmlArtifact.tsx:114-121）。
- 依赖提供：iframe 用 `srcDoc` 内联，文档壳由 `lib/htmlSandbox.ts` 的 `buildSrcDoc` 组装：CSP meta 置于最前，再注入内存存储 shim 与元素检查器脚本，然后才是模型标记（`htmlSandbox.ts:46-65`）。CSP 分三档——禁脚本（SVG 静态，无 `script-src`）、默认可脚本禁网（`script-src 'unsafe-inline' blob:`、`media-src data: blob:`、`worker-src blob:`、`connect-src 'none'`）、`allowNetwork` 时放宽到 `https:`；`allowNetwork` 在产品代码中不传入，仅测试使用。预览还会统计无法在沙箱内解析的相对 `src`/`href` 并显示提示条（`lib/htmlAssets.ts:36-44`、`HtmlArtifact.tsx:104-113`）。SVG 段禁脚本：sandbox 为空、CSP 不声明 `script-src`（RenderMarkdown.tsx:280-285）。
- 产品文案与实现一致：设置页说明"HTML runs the model-generated page in a sandboxed frame that executes its own scripts but cannot access Jan, your files, or the network"（web-app/src/locales/en/settings.json:104）。该功能标注为实验性，默认关闭（web-app/src/hooks/useInterfaceSettings.ts:186）。

## 5. 用户交互、事件与错误反馈

- artifact 内交互：页签切换（Code/Preview）；iframe 内模型页面自身的按钮、表单、JS 状态可操作（运行期由浏览器承担）。iframe 与宿主之间由两个注入脚本建立单向通道：preview shim 把未捕获异常、未处理的 Promise 拒绝、加载失败的资源与 CSP 拦截的请求以 `{source:'jan-preview-shim', type:'error', ...}` 上报父窗口；preview inspector 在悬停/点击时把元素框选与标签以 `pin`/`clear` 上报（`lib/previewShim.ts:1-17`、`lib/previewInspector.ts:1-15`）。没有尺寸或运行状态回传；Mermaid 渲染失败有独立错误组件（web-app/src/containers/RenderMarkdown.tsx:329-339，属于渲染器层）。
- 交互状态不恢复：切到 Code 视图即卸载 iframe，切回重建全新文档；应用重载后从文本重建。预览高度用 CSS 的 resize-y 样式可拖拽，属浏览器原生行为，不持久化。
- 工具结果（Web 搜索/抓取、RAG、MCP）以只读卡片展示：搜索条/地址栏样式的工具条，配结果链接行、引用卡片与文本片段（web-app/src/containers/message/WebToolWidget.tsx:59-152；RagToolWidget.tsx:25-103）。可点击打开外部链接，但不可操作、不可编辑、不可保存为对象——停在"工具结果的展示"边界，未物化。

## 6. 编辑、diff、版本与协作

- 普通 Chat 的编辑对象是消息全文；Cowork 的 write/edit 则对文件产生实际更改并记录差异。两者的版本、撤销与冲突处理不共享，文件 diff 展示不自动证明具备 Git 提交或 CRDT 协作（`web-app/src/lib/coworkDispatch.ts:209-239`、`web-app/src/routes/cowork.tsx:1764-1773`）。
- 版本：消息分支（parentId/activeRootId，n/m 版本切换，重生成保留旧版本为兄弟版本）（web-app/src/routes/threads/$threadId.tsx:1223-1288, 1317-1346）属于消息版本，非对象版本。无 artifact 级接受/拒绝、无 diff 视图、无 CRDT、无协作。
- 普通 Chat 模型不定向修改已生成消息；Cowork 模型可以调用文件 edit/write 修改沙箱或附加目录内的文件。

## 7. 能力桥、执行位置与权限范围

- 普通 Chat 围栏 iframe 无宿主能力桥；Cowork 的文件和 shell 工具是 Agent 自身受工具网关控制的能力，不应混同于 HTML 页面的任意宿主 API。Cowork 预览默认隔离，开启 live `preview://` 后有专用 origin 和文件 root 限制，需单独评价网络开关（`web-app/src/containers/CoworkPreviewPanel.tsx:65-89,141-150`）。
- 工具执行位置（与本类目交界，属 Agent 工具类目）：Web 搜索/抓取在 Rust 进程内用 reqwest 请求 Exa、Tavily、SearXNG 等搜索服务（src-tauri/plugins/tauri-plugin-websearch/src/provider.rs:53-64, 110-245）；RAG 走扩展（extensions/rag-extension）；MCP 工具经服务中心的 callTool 通道调 Rust 侧 MCP 客户端（web-app/src/routes/threads/$threadId.tsx:482-587）。执行调度与审批属 Agent 工具调查，本笔记只记交接点：这些工具的结果以文本/JSON 回填消息，未产生可操作对象。
- 外部执行桥（能力桥的另一次应用）：Claude Code 集成把 Jan 本地 OpenAI 兼容服务器地址写入 shell 环境文件并提示用户自行启动外部 CLI（web-app/src/routes/settings/claude-code.tsx:70-205；src-tauri/src/core/system/commands.rs:394-540）；独立 Jan Agent CLI/TUI 运行自己的 Agent 并用远程 Provider（`src-tauri/jan-cli/src/main.rs`），旧 `jan launch` 派生外部 agent 程序的分支已不在当前命令树中。执行面在外部终端或 CLI 自身进程，Jan 桌面只提供模型后端与配置，不在 Jan 内产生输出对象。

## 8. 持久化、恢复、分享与导出

- 持久化内容：只有消息源文本 part 及内联媒体 part。Rust 侧对消息 JSONL 文件整文件重写实现修改与删除（src-tauri/src/core/threads/commands.rs:222-300）；读回按行解析（helpers.rs:46）。artifact 的 iframe 运行状态、视图选择、交互状态一律不持久化。
- 分享/导出：消息级复制按钮复制全文；`MarkdownTable` 组件提供 CSV 与 Markdown 格式的表格下载（web-app/src/components/MarkdownTable.tsx:46-51, 91-138，属渲染器层的表格导出）。artifact 本身无下载/导出按钮；assistant 生成的图片在消息内可点击放大预览（MessageItem.tsx:395-407, 645-657），无下载按钮。未发现分享链接机制。
- 恢复：重开线程时从 JSONL 恢复文本并重新推导 artifact——恢复的是"文本→派生渲染"，不是对象或运行状态。

## 9. 模型回流、对象感知与持续维护

- 普通 Chat 只通过围栏文本回流；Cowork 可在后续工具回合读取、修改同一路径的文件，工具结果进入模型历史。预览 shim 与元素检查器对普通 Chat artifact 与 Cowork 预览面板共用（同一 `buildSrcDoc`），因此两者都有脚本错误与元素框选的 `postMessage` 上报；但这类上报不构成“对象可查询、可定向修改”的闭环（`web-app/src/lib/htmlSandbox.ts:46-65`）。
- 对象感知：无对象列表查询、无源码读取接口、无运行状态观察。对象身份不绑定到后续回合：每次"修改"都是整条消息重新生成或续写，无法定位单个 artifact。因此闭环（查询→读取→定向修改）**未实现**；持续维护只以"转录文本继续对话"的弱形式存在（Continue 重放部分文本、Regenerate 重新生成），这是 Chat 类目行为而非输出对象维护。

## 10. 生命周期、资源治理与性能

- iframe 生命周期随组件：切换 Code 视图或消息重渲染即卸载，无定时器/动画/媒体/进程登记与释放机制（浏览器默认回收）；iframe 内模型页面可自行开定时器等资源，宿主不管理。渲染期唯一的节流是延迟值调度与 memo 合并（见第 2 节）。
- 无对象级限额：消息无长度上限审计（上下文裁剪按 token 预算处理整段对话，见第 9 节）；多 artifact 场景仅受 DOM 与 iframe 数量约束，未见专门治理。持久化文件为单 JSONL 整写，长线程每次修改/删除都全量重写（见第 8 节），属性能与一致性的既有取舍。

## 11. 测试、已确认边界与未验证事项

- 测试覆盖（静态确认，未运行）：HtmlArtifact 组件测试覆盖默认预览视图、页签切换、sandbox 属性（allow-scripts、无 allow-same-origin）、CSP 注入与禁网断言、SVG 禁脚本模式、allowNetwork 放宽、流式中预览禁用与全文档包装（web-app/src/components/__tests__/HtmlArtifact.test.tsx:37-112）；渲染器测试覆盖设置开关、流式回退与非 html 围栏不拆（web-app/src/containers/__tests__/RenderMarkdown.test.tsx:435-490）；工具函数测试覆盖拆分正则（web-app/src/lib/__tests__/utils.test.ts:406-419）。这些是 DOM 属性与 srcdoc 字符串级断言，不验证真实脚本执行。
- 未验证事项（未运行应用）：iframe 内脚本的实际执行行为、CSP 在 WebKitGTK/WebView2/WKWebView 三平台的实际生效、切页签后 iframe 状态丢失的具体表现、重开线程后 artifact 重建的视觉效果。上述均为静态代码推断之外的运行时行为。
- 已确认边界：普通 Chat 围栏预览仍没有独立对象 ID 或文件版本；Cowork 具有文件生成、差异展示与本地 shell，但尚未运行验证预览隔离、文件权限及资源回收，也未确认 notebook、CRDT 或对象级版本/撤销。原来仅搜索 `src-tauri/src` 排除了新插件目录，不能用于否定工作区工具。

## 12. 关键源码索引

- `web-app/src/components/HtmlArtifact.tsx:26-128`（组件：页签 + 沙箱 iframe）、`web-app/src/lib/htmlSandbox.ts:4-66`（CSP 三档与 `buildSrcDoc`）、`web-app/src/lib/htmlAssets.ts`（相对资源检测）、`web-app/src/lib/previewShim.ts`/`previewInspector.ts`（注入脚本）
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
- `web-app/src/lib/coworkArtifacts.ts`、`web-app/src/containers/CoworkPreviewPanel.tsx`（Cowork 文件交付与预览）
- `web-app/src/containers/message/WebToolWidget.tsx`、`RagToolWidget.tsx`（工具结果只读展示）
- `web-app/src/components/__tests__/HtmlArtifact.test.tsx`、`web-app/src/containers/__tests__/RenderMarkdown.test.tsx:435-490`（验证用例）
