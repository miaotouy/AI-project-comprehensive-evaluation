# Jan 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：静态源码调查；grep/glob 关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、exec、spawn、eval、wasm、writeFile 等）；阅读聊天生成、消息渲染、线程持久化与工具执行主链路；未运行应用与测试
>
> 调查范围：模型输出从生成到展示、运行、编辑、保存、重开、回流的主链路；HTML/SVG artifact 预览；工具结果的物化程度；扩展系统对输出生命周期的影响。模型加载、推理调度、RAG 向量库、下载与更新等不在本次范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

普通 Chat 输出仍以消息 part 为事实源：实验性 HTML/SVG 围栏预览在渲染时派生，缺稳定对象 ID 和宿主通道。Cowork 则以文件工具写入工作区，并从工具调用派生文件 Artifact 卡；对既有文件的编辑有差异面板，HTML 可在独立预览面展示。因此“无文件生成、无 diff/patch”只适用于普通 Chat 的围栏预览，不适用于 Cowork。两个表面不能合并成单一能力等级：前者是窄沙箱预览，后者有工作区编辑的部分性质，但接受/拒绝、跨运行对象版本与复原语义尚未验证（`web-app/src/lib/coworkArtifacts.ts:24-107,201`、`web-app/src/routes/cowork.tsx:424-427,1577-1584`）。

Cowork 的 Artifact 有三条派生来源：`write` 工具确认真正新建了文件、`edit` 只改既有文件因此不产生新卡、以及 shell 命令的输出——命令里点名的路径要被输出里的同名 basename 证实，或输出里出现 `Destination: <path>` 这类写出声明，才收为卡片（探测类命令与通配列表不算）。卡片按路径去重并按 Code/Image/Document/Video/Audio 分组（`web-app/src/lib/coworkArtifacts.ts:66-201`）。

## 系统边界与完整主链路

普通 Chat 的渲染入口仍在 web-app，以下主链只描述围栏预览。Cowork 另以 Tauri agent-tools 插件执行文件写入、编辑与 shell，前端依据工具结果构造预览与差异状态；文件内容存于会话沙箱或用户附加的可写目录，消息历史不是文件唯一事实源（`web-app/src/lib/coworkDispatch.ts:209-239`、`src-tauri/plugins/tauri-plugin-agent-tools/src/commands.rs:685-709`）。

已走通的主链路（触发 → 生成 → 展示/运行 → 交互 → 保存 → 重新打开）：

1. 触发：用户提交消息后，发送入口把它包装成 AI SDK 的 `UIMessage`，传输层补齐上下文并启动流式生成（`web-app/src/routes/threads/$threadId.tsx:913-1123`、`web-app/src/lib/custom-chat-transport.ts:1296-1375`）。
2. 生成：文本增量持续写入当前消息的文本 part；生成结束时，回调 `onFinish` 把这条消息整理成 `ThreadMessage` 写入后端，其 content 数组可包含文本、文件与推理等 part（`web-app/src/routes/threads/$threadId.tsx:293-460`）。
3. 保存：Rust 侧把消息写入 `threads/<threadId>/messages.jsonl`，同一线程的写入串行执行以保证一致性；这份 JSONL 文件就是消息的事实源，其中不存在 artifact 对象（`src-tauri/src/core/threads/commands.rs:159` 起）。
4. 展示与运行：消息渲染器按 part 渲染文本；设置开启且消息不在流式状态时，拆段逻辑把 html/svg 围栏从文本中切出，html 段交给 `HtmlArtifact` 组件（代码与预览双页签，预览是沙箱 iframe），svg 段以禁脚本的静态方式预览（`web-app/src/containers/RenderMarkdown.tsx:335-355`、`web-app/src/lib/utils.ts:72-121`）。
5. 交互：页签切换，iframe 内模型脚本可运行；公共壳会发送错误/框选消息，但普通 Chat 卡片没有对应消费，详见第 5 节。
6. 重新打开：读回 JSONL 后把消息对象转回 AI SDK 的 `UIMessage`，再走同一渲染链按持久文本重新渲染 artifact（`web-app/src/lib/messages.ts:255`）。预览打开时从源码创建新的 iframe 实例；旧实例的表单值、脚本变量和定时器等运行状态没有保存与回灌通道（[预览文档生成](<../../jan/web-app/src/components/HtmlArtifact.tsx#L26-L48>)、[iframe 挂载](<../../jan/web-app/src/components/HtmlArtifact.tsx#L102-L121>)）。

普通 Chat 的围栏 artifact 无文件读取与定向修改；Cowork 可通过 read/find/grep 查找已有文件，再经 edit/write 对同一工作区文件修改。文件路径充当对象定位键，工具执行结果进入后续模型回合（`web-app/src/lib/agentTools.ts:39-56`、`web-app/src/lib/coworkRunner.ts:571-590`）。

## 1. 触发方式、输出协议与对象模型

- 触发方式：HTML/SVG artifact 完全由模型自由文本中的围栏触发，用户命令、结构化 part 与工具调用都不参与。识别用的正则可匹配 html、svg 两种围栏以及裸 `<svg>…</svg>` 标签，其它语言的围栏（js、py 等）原样留在 Markdown 流中（`web-app/src/lib/utils.ts:72-121`）。防误触发有两道约束：围栏体必须是孤立的 SVG，流式期间不拆段，因此未闭合的围栏不会在生成中途被抽出（`web-app/src/containers/RenderMarkdown.tsx:258-264`）。该协议直接在正则文本上工作，没有转义与嵌套概念，嵌套围栏不会被识别，最终留在正文里。
- 普通 Chat 的围栏没有独立对象；Cowork 的 Artifact 从 write、edit 与 shell 的工具轨迹中派生，新建且扩展名允许的交付文件收为卡片，对已有文件的修改进入差异面板，卡片指向会话沙箱或附加目录里的文件本体（`web-app/src/lib/coworkArtifacts.ts:107-201`、`web-app/src/lib/coworkDiffs.ts`）。
- 消息对象本身有完整身份：稳定 ID、所属线程、角色、状态、创建时间与元数据，元数据承载 `parentId` 分支与 `stopped` 标记等字段。这套身份属于 Chat 消息层，输出对象自身没有身份（`web-app/src/routes/threads/$threadId.tsx:397-411`）。

## 2. 增量生成、更新与最终化

- 流式输出按 token 增量更新消息的文本 part；渲染器用延迟值与条件 memo 合并高频渲染，流式期间改走纯文本路径，避免每个 token 都触发语法高亮。这套增量机制位于消息渲染器这一层（`web-app/src/containers/RenderMarkdown.tsx:68-95, 216-231, 347-352`）。
- artifact 的"更新"是整体替换：非流式且设置开启时，输入内容一变化，分段结果与 iframe 的文档源就整体重建，重建由组件内的 memo 驱动（`web-app/src/components/HtmlArtifact.tsx:77-81`）。更新过程不涉及 AST 节点级改动；在输出链中搜索 diff 与 patch 未找到任何应用机制，命中项只有日期差值与 MCP schema 修补等无关代码。
- 最终化：生成完成回调负责持久化消息。生成因长度截断结束时（`finishReason === 'length'`），消息会标记为 stopped 并提供 Continue，用重放前缀的方式继续生成（`web-app/src/routes/threads/$threadId.tsx:301-341, 1352` 起）。流式进行中预览页签不可用，界面强制停在 Code 视图（`HtmlArtifact.tsx:83-84, 120-127`）。

## 3. 投影表面与多视图关系

- 普通 Chat 的 artifact 只有消息内联代码/预览页签；Cowork 提供独立预览、差异与文件侧栏。Cowork 预览可打开沙箱和附加目录中的文件，默认以不透明来源的 `srcdoc` 运行；可选的 `preview://` 独立来源按注册过的目录提供文件、受宿主 CSP 与网络开关约束，Windows 上不提供这一非沙箱模式，因为该平台只有不透明来源能把页面挡在 IPC 之外。Open 只放行文档与媒体，其他类型改为在文件夹中显示（`web-app/src/containers/CoworkPreviewPanel.tsx:44-83`、`src-tauri/plugins/tauri-plugin-agent-tools/src/preview.rs`）。
- 源（消息文本）与投影（artifact 组件）构成两级，运行实例（iframe）总是从源即时重建，无中间持久态。

## 4. 表现类型、依赖与运行环境

- 表现层级：静态 Markdown（GFM、KaTeX、Streamdown 代码块、Mermaid 图）覆盖 G0 至 G1 静态层；HTML artifact 是唯一的动态层，模型的 HTML/CSS/JS 在 iframe 中执行。该 iframe 只授予 allow-scripts、不授予 allow-same-origin，页面因此落在不透明源上，引用策略设为 no-referrer（`web-app/src/components/HtmlArtifact.tsx:118-122`）。
- 依赖提供：iframe 用 srcDoc 内联整份文档，文档壳由 `buildSrcDoc` 按顺序拼装：先是 CSP meta，再是内存存储 shim 与元素检查器脚本，最后是模型标记（`htmlSandbox.ts:46-65`）。CSP 分三档，决定页面能用哪些脚本、媒体与网络：

  | 档位 | 脚本 | 媒体与网络 |
  |---|---|---|
  | 禁脚本（SVG 静态） | 不声明 `script-src` | 静态渲染 |
  | 默认可脚本禁网 | 内联与 blob 脚本、blob worker | data/blob 媒体；`connect-src` 为 none |
  | `allowNetwork` | 同上 | 放宽到 `https:` |

  普通 Chat 的 `HtmlArtifact` 调用点未传 `allowNetwork`，Cowork 独立预览面板则有自己的网络开关。预览还会统计无法在沙箱内解析的相对资源并显示提示条（`lib/htmlSandbox.ts:4-60`、`HtmlArtifact.tsx:38-44`、`lib/htmlAssets.ts`）。

  SVG 段复用同一个组件，只是把 allowScripts 传成 false：此时 sandbox 为空，CSP 不声明 script-src，也不注入元素检查器（`RenderMarkdown.tsx:355-361`、`htmlSandbox.ts:58-60`）。
- 产品文案与实现一致：设置页说明"HTML runs the model-generated page in a sandboxed frame that executes its own scripts but cannot access Jan, your files, or the network"（web-app/src/locales/en/settings.json:99）。该功能标注为实验性，默认关闭（web-app/src/hooks/useInterfaceSettings.ts:186）。

## 5. 用户交互、事件与错误反馈

- 模型页面的按钮、表单与 JS 状态都在 iframe 内运行。公共壳注入的 shim 会向父窗口上报异常、加载失败与 CSP 拦截，元素检查器则发送框选与清除消息；这些消息能否生效，取决于宿主是否消费。普通 Chat 的 HtmlArtifact 只组装 iframe，没有 message 监听，也没有框选状态，因此卡片上不会出现错误反馈，报告也不会回流给模型（[HtmlArtifact.tsx:26–48、114–121](../../jan/web-app/src/components/HtmlArtifact.tsx#L26-L48)、[htmlSandbox.ts:56–65](../../jan/web-app/src/lib/htmlSandbox.ts#L56-L65)）。
- Cowork 的 srcdoc 预览会按 iframe 的 contentWindow 过滤报告、去重后限量显示错误提示；本次读取的组件没有消费框选与清除消息。live URL 分支不持有该 frame 引用，错误反馈的过滤、去重与限量提示只作用于 srcdoc 预览（[CoworkPreviewPanel.tsx:250–319](../../jan/web-app/src/containers/CoworkPreviewPanel.tsx#L250-L319)）。
- 交互状态不恢复：切到 Code 视图即卸载 iframe，切回重建全新文档；应用重载后从文本重建。预览高度用 CSS 的 resize-y 样式可拖拽，属浏览器原生行为，不持久化。
- 工具结果（Web 搜索与抓取、RAG、MCP）以只读卡片展示：工具条做成搜索框或地址栏样式，下方配结果链接行、引用卡片与文本片段，链接可点击打开外部页面。卡片只承担结果的只读展示，结果本身没有物化成可编辑对象（`web-app/src/containers/message/WebToolWidget.tsx:58` 起、`RagToolWidget.tsx:25` 起）。

## 6. 编辑、diff、版本与协作

- 普通 Chat 的编辑对象是消息全文；Cowork 的 write/edit 则对文件产生实际更改并记录差异。两者的版本、撤销与冲突处理不共享，文件 diff 展示不自动证明具备 Git 提交或 CRDT 协作（`web-app/src/lib/coworkDispatch.ts`、`web-app/src/routes/cowork.tsx:1577-1584`）。
- 版本：消息分支（parentId/activeRootId，n/m 版本切换，重生成保留旧版本为兄弟版本）（`web-app/src/routes/threads/$threadId.tsx`，版本/重生成逻辑）属于消息版本，非对象版本。无 artifact 级接受/拒绝、无 diff 视图、无 CRDT、无协作。
- 普通 Chat 模型不定向修改已生成消息；Cowork 模型可以调用文件 edit/write 修改沙箱或附加目录内的文件。

## 7. 能力桥、执行位置与权限范围

- 普通 Chat 的围栏 iframe 没有宿主能力桥；Cowork 的文件与 shell 工具属于 Agent 自身的能力，由工具网关控制，和 HTML 页面可用的宿主 API 是两条独立通道。Cowork 预览默认隔离，开启 live 的 `preview://` 模式后才使用专用 origin 与受限的文件 root，网络开关要按这一模式单独评估（`web-app/src/containers/CoworkPreviewPanel.tsx:44-83`）。
- 工具执行位置（与本类目交界，细节归 Agent 工具类目）：Web 搜索与抓取在 Rust 进程内用 reqwest 请求 Exa、Tavily、SearXNG 等服务，RAG 由独立扩展（extensions/rag-extension）提供，MCP 工具经服务中心的 callTool 通道转给 Rust 侧客户端。工具调用入口见 `web-app/src/routes/threads/$threadId.tsx:218` 起，搜索与抓取的请求实现在 `src-tauri/plugins/tauri-plugin-websearch/src/provider.rs:74-188`。执行调度与审批留给 Agent 工具调查，本笔记只记交接点：这些工具的结果以文本或 JSON 回填消息，没有产生可操作对象。
- 外部执行桥（能力桥的另一种应用）：Claude Code 集成把 Jan 本地 OpenAI 兼容服务器地址写入 shell 环境文件，并提示用户自行启动外部 CLI（`web-app/src/routes/settings/claude-code.tsx:38` 起、`src-tauri/src/core/system/commands.rs:897-1038`）。独立 Jan Agent CLI/TUI 运行自己的 Agent 并使用远程 Provider（`src-tauri/jan-cli/src/main.rs`），旧的 jan launch 命令已不在当前命令树中。这些路径的执行面都在外部终端或 CLI 自身进程，Jan 桌面只提供模型后端与配置，输出对象不在 Jan 内产生。

## 8. 持久化、恢复、分享与导出

- 持久化内容：只有消息源文本 part 及内联媒体 part。Rust 侧对消息 JSONL 文件整文件重写实现修改与删除（`src-tauri/src/core/threads/commands.rs:225-300`）；读回按行解析（`src-tauri/src/core/threads/helpers.rs:82`）。artifact 的 iframe 运行状态、视图选择、交互状态一律不持久化。
- 分享/导出：消息级复制按钮复制全文；`MarkdownTable` 组件提供 CSV 与 Markdown 格式的表格下载（`web-app/src/components/MarkdownTable.tsx:58` 起，属渲染器层的表格导出）。artifact 本身无下载/导出按钮；assistant 生成的图片在消息内可点击放大预览（`web-app/src/containers/MessageItem.tsx`，媒体 part 预览），无下载按钮。未发现分享链接机制。
- 恢复：重开线程时从 JSONL 恢复文本并重新推导 artifact——恢复的是"文本→派生渲染"，不是对象或运行状态。

## 9. 模型回流、对象感知与持续维护

- 普通 Chat 通过围栏源文本继续对话；Cowork 则可在后续工具回合读取、修改同一路径的文件，工具结果进入模型历史。公共预览壳中的上报脚本并未接入模型请求；错误提示只有 Cowork 的 srcdoc 面板消费，元素框选在本次检查的两个宿主组件中均未找到消费点（检查范围：[HtmlArtifact.tsx](../../jan/web-app/src/components/HtmlArtifact.tsx)、[CoworkPreviewPanel.tsx](../../jan/web-app/src/containers/CoworkPreviewPanel.tsx)）。
- 普通 Chat 围栏的对象感知：本次检查的消息渲染和 transport 中未找到 artifact 对象列表、独立源码读取或运行状态观察接口。对象身份不绑定到后续回合：每次"修改"都是整条消息重新生成或续写，无法定位单个 artifact。因此闭环（查询→读取→定向修改）**未实现**；持续维护只以"转录文本继续对话"的弱形式存在（Continue 重放部分文本、Regenerate 重新生成），这是 Chat 类目行为而非输出对象维护。

## 10. 生命周期、资源治理与性能

- iframe 生命周期随组件：切换 Code 视图或消息重渲染即卸载，无定时器/动画/媒体/进程登记与释放机制（浏览器默认回收）；iframe 内模型页面可自行开定时器等资源，宿主不管理。渲染期唯一的节流是延迟值调度与 memo 合并（见第 2 节）。
- 无对象级限额：消息无长度上限审计（上下文裁剪按 token 预算处理整段对话，见第 9 节）；多 artifact 场景仅受 DOM 与 iframe 数量约束，未见专门治理。持久化文件为单 JSONL 整写，长线程每次修改/删除都全量重写（见第 8 节），属性能与一致性的既有取舍。

## 11. 测试、已确认边界与未验证事项

- 测试覆盖（静态确认，未运行）：HtmlArtifact 组件测试覆盖默认预览视图、页签切换、sandbox 属性（allow-scripts、无 allow-same-origin）、CSP 注入与禁网断言、SVG 禁脚本模式、allowNetwork 放宽、流式中预览禁用与全文档包装（`web-app/src/components/__tests__/HtmlArtifact.test.tsx`）；渲染器测试覆盖设置开关、流式回退与非 html 围栏不拆（`web-app/src/containers/__tests__/RenderMarkdown.test.tsx`）；工具函数测试覆盖拆分正则（`web-app/src/lib/__tests__/utils.test.ts`，`splitHtmlArtifacts` 用例）。这些是 DOM 属性与 srcdoc 字符串级断言，不验证真实脚本执行。
- 未验证事项（未运行应用）：iframe 内脚本的实际执行行为、CSP 在 WebKitGTK/WebView2/WKWebView 三平台的实际生效、切页签后 iframe 状态丢失的具体表现、重开线程后 artifact 重建的视觉效果。上述均为静态代码推断之外的运行时行为。
- 已确认边界：普通 Chat 围栏预览仍没有独立对象 ID 或文件版本；Cowork 具有文件生成、差异展示与本地 shell，但尚未运行验证预览隔离、文件权限及资源回收，也未确认 notebook、CRDT 或对象级版本/撤销。原来仅搜索 `src-tauri/src` 排除了新插件目录，不能用于否定工作区工具。

## 12. 关键源码索引

- `web-app/src/components/HtmlArtifact.tsx:26-128`（组件：页签 + 沙箱 iframe）、`web-app/src/lib/htmlSandbox.ts:4-60`（CSP 三档与 `buildSrcDoc`）、`web-app/src/lib/htmlAssets.ts`（相对资源检测）、`web-app/src/lib/previewShim.ts`/`previewInspector.ts`（注入脚本）
- `web-app/src/lib/utils.ts:72-121`（ARTIFACT_RE 与 splitHtmlArtifacts 拆分协议）
- `web-app/src/containers/RenderMarkdown.tsx:335-361`（artifact 门控与分段渲染）
- `web-app/src/hooks/useInterfaceSettings.ts:138,186`（renderHtmlArtifacts 设置，默认 false）
- `web-app/src/containers/MessageItem.tsx`（文本/媒体 part 渲染与预览）
- `web-app/src/routes/threads/$threadId.tsx:538`（onFinish 持久化，截断处理在 `:565`）、`:105,218` 起（工具执行循环）、版本/重生成见同文件
- `web-app/src/lib/custom-chat-transport.ts:1382` 起（`sendMessages`，上下文组装与回流）
- `web-app/src/lib/messages.ts:17,255`（ThreadMessage ↔ UIMessage 转换）
- `src-tauri/src/core/threads/commands.rs:139-300`（messages.jsonl 读写）、`src-tauri/src/core/threads/mod.rs`（串行写设计）
- `src-tauri/plugins/tauri-plugin-websearch/src/provider.rs:53-64, 110-245`（Rust 侧搜索/抓取执行）
- `src-tauri/src/core/system/commands.rs:394-540`（Claude Code 环境配置）
- `web-app/src/lib/coworkArtifacts.ts`、`web-app/src/containers/CoworkPreviewPanel.tsx`（Cowork 文件交付与预览）
- `web-app/src/containers/message/WebToolWidget.tsx`、`RagToolWidget.tsx`（工具结果只读展示）
- `web-app/src/components/__tests__/HtmlArtifact.test.tsx`、`web-app/src/containers/__tests__/RenderMarkdown.test.tsx:435-490`（验证用例）
