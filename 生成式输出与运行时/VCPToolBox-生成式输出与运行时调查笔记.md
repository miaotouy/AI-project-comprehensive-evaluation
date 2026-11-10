# VCPToolBox 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：静态代码审查。用 grep/glob 检索 artifact/canvas/sandbox/iframe/webview/notebook/diff/patch/execution/runtime/preview/markdown/chat/stream 等关键词，通读 server.js、modules/chatCompletionHandler.js、modules/handlers/streamHandler.js 与 nonStreamHandler.js、modules/vcpLoop/toolCallParser.js 与 toolExecutor.js、vcpInfoHandler.js、Plugin.js、modules/toolCallRecordStore.js、modules/finalContextStore.js、Plugin/OneRing/OneRingDB.js、Plugin/RAGDiaryPlugin、Plugin/VCPForum/VCPForum.js、Plugin/GPTImageGen/GPTImageGen.js、Plugin/MediaRenderer、Plugin/AICodeWorker、routes/forumApi.js、routes/protocolBridge.js；对照 docs/Markdown_Output_Guideline.md、docs/FRONTEND_COMPONENTS.md、docs/PLUGIN_ECOSYSTEM.md 等文档与源码交叉核对
>
> 调查范围：输出协议与对象模型、流式生成链与最终化、投影表面、表现类型与执行运行时、能力桥、持久化与模型回流、生命周期治理、测试覆盖。未启动服务器，未做任何端到端运行验证；第三方聊天前端 VCPChat 本体不在本仓库，不在本次调查范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 是 OpenAI 兼容的 AI 中间层服务端（`/v1/chat/completions`），本身不渲染聊天，也不持有聊天事实源：模型输出以标准 SSE 流直通转发，工具执行结果以文本块形式回注聊天流，界面渲染交给外部前端（官方 VCPChat 为独立仓库，OpenWebUI/SillyTavern 通过 `OpenWebUISub`/`SillyTavernSub` 用户脚本增强）。服务端具备明确的"输出协议"（VCP 纯文本标记）、"工具执行运行时"（stdio 子进程 / in-process / 分布式 WebSocket 节点）和"派生对象持久化"（日记文件、论坛帖子、图片、工具调用记录、OneRing 时间线），但不存在带稳定 ID 的输出对象模型，无 diff/接受/拒绝的协作编辑层。模型生成的 HTML/SVG/JS 可经 MediaRenderer（托管浏览器 + 音频合成子进程）与 AICodeWorker（opencode CLI）进入受控执行环境，属局部 G3；主链路的聊天输出本身停留在 G0-G1（文本 + 落盘文件）。

MediaRenderer 的鼠标主题输出进一步说明这一边界：一份模型生成 HTML 经受控浏览器渲染后可变成多尺寸 CUR/ANI、预览 PNG 和带安装脚本的 ZIP，且把原 HTML 与 `theme.json` 一并保存；这些内容仍由文件服务以 URL 托管，调用之间没有主题 ID、版本编辑或协作合并语义，因此不改变 G1 主形态和局部 G3 的分级（`Plugin/MediaRenderer/MediaRenderer.js:1667-2058`、`CursorThemePackager.js:11-685`）。

能力等级认定：**G1（主形态）＋ 局部 G3（MediaRenderer / AICodeWorker 等插件级执行环境）**。依据：输出没有独立对象生命周期（G0 特征）；大量产物以文件/图片落盘并可单独查看、下载、被模型回读（G1 特征）；MediaRenderer 对模型编写的 HTML/SVG/JS 提供隔离执行（网络阻断、JS 默认关闭、子进程超时），AICodeWorker 以 jobId 异步管理 opencode 子任务（G3 特征）；但无 schema 化声明式对象（非 G2）、无用户与模型围绕同一对象持续编辑的 diff/版本机制（非 G4）、输出对象不长期存在于桌面/环境（非 G5）。

## 系统边界与总体调用链

系统边界：

- **服务端中间层**（本仓库）：一次请求依次经过认证、消息预处理、上游模型调用、流式直通与 VCP 工具循环、工具执行、结果回注，最后把派生物落盘。其中消息预处理包含变量替换、RAG 注入、多模态翻译、Detector 判定与角色分割，工具执行则分本地与远端两种。
- **聊天前端**（仓库外）：VCPChat（官方桌面端，`docs/TECHNICAL_LITE.md:186-190` 说明为独立项目）、OpenWebUI、SillyTavern。本仓库只提供用户脚本与正则增强（`OpenWebUISub/`、`SillyTavernSub/`）。
- **管理面板**（`AdminPanel-Vue` + `adminServer.js`）：纯管理/查看界面，无聊天界面。本次在 `AdminPanel-Vue/src` 全量检索未找到聊天流渲染组件，`marked` 仅用于日记/占位符预览（views/DailyNotesManager.vue:105）。
- **Rust 向量引擎**（`rust-vexus-lite`）：记忆/检索计算后端，不直接参与输出生成。

完整主链路（触发 → 生成 → 展示 → 保存 → 重新打开）：

1. 客户端向 `/v1/chat/completions` 发起 POST 请求，请求体携带消息列表、流式开关与可选请求标识；换用 `/v1/chatvcp/completions` 时会强制展示 VCP 信息（`server.js:1217-1242`）。
2. 处理器入口先做消息预处理，顺序为 VCPTavern 注入、变量替换、RAGDiaryPlugin 等预处理器注入知识块、Detector/SuperDetector 判定，最后做角色分割（`chatCompletionHandler.js:899-1121`）。
3. 预处理完成后带重试向上游 `{apiUrl}/v1/chat/completions` 发起请求（`modules/chatCompletionHandler.js:1152-1182`）。
4. 上游响应按模式分两种收法：流式时 SSE 逐行直通转发给客户端、后台同时累积全文，非流式时累积完整 JSON 响应（`streamHandler.js:143-406`）。
5. 工具循环从累积正文里解析 `<<<[TOOL_REQUEST]>>>` 块，执行插件工具后把结果以 `<!-- VCP_TOOL_PAYLOAD -->` 前缀的 user 消息回灌，再请求一次上游；循环轮数上限由 `MaxVCPLoopStream` 控制，默认 5 轮（`streamHandler.js:70-735`）。
6. 文本正文与 `[[VCP调用结果信息汇总:...]]` 块随 SSE 到达前端，由外部前端渲染 Markdown；VCPLog 插件另经 WebSocket 把工具调用详情推给前端（`vcpInfoHandler.js:117`、`WebSocketServer.js:583`）。
7. 派生物按各自通道落盘：
   - chat 日志（可选）：`DebugLog/chat/`；
   - 日记：模型输出的 `<<<DailyNoteStart>>>` 块经解析交给 DailyNoteWrite 插件写入 `dailynote/`；
   - 论坛帖子：`dailynote/VCP论坛/*.md`；
   - 图片：`image/` 并经图床提供 URL；
   - 工具调用记录（可选）：SQLite。
   上述通道的落盘入口依次见 `server.js:478-1417`、`VCPForum.js:247-294`、`GPTImageGen.js:1070-1100` 与 `modules/toolCallRecordStore.js`。
8. 重新打开：聊天历史仍由外部前端持有，服务端不提供聊天恢复接口；服务端持久化的派生物可被模型重新读取，途径包括论坛的 `ReadPost`、日记的 RAG 注入、文件工具和 `ToolCallRecordQuery`。此环节依赖外部前端，本次未运行验证。

## 1. 触发方式、输出协议与对象模型

**触发方式**：全部输出能力均由"模型自由文本中的特殊标记"触发，无独立的"输出创建"API。协议均为纯文本标记（`docs/PLUGIN_ECOSYSTEM.md`、`VCP.md:44-57` 自述为纯文本标记协议）：

| 用途 | 标记形式 | 源码定位 |
| --- | --- | --- |
| 工具调用块 | `<<<[TOOL_REQUEST]>>> ... <<<[END_TOOL_REQUEST]>>>`，字段值用「始」「末」包裹 | `modules/vcpLoop/toolCallParser.js:5-20` |
| 工具结果展示块 | `[[VCP调用结果信息汇总:...]]` | `vcpInfoHandler.js:96-104` |
| 日记块 | `<<<DailyNoteStart>>> ... <<<DailyNoteEnd>>>` | `server.js:1344` |
| 角色分割 | `<<<[ROLE_DIVIDE_USER]>>>` 等 | `streamHandler.js:504` |
| 工具结果回灌 | `<!-- VCP_TOOL_PAYLOAD -->` 前缀 | `streamHandler.js:686` |
| RAG 知识块 | `<!-- VCP_RAG_BLOCK_START {metadata} --> ... <!-- VCP_RAG_BLOCK_END -->` | `chatCompletionHandler.js:546` |

**协议健壮性**：解析器以 SSE 行缓冲 + StringDecoder 处理半截流（streamHandler.js:146-311）；参数用「始ESCAPE」等转义承载字面量，未闭合的 `<think>` 之后的内容被丢弃以防潜藏工具调用被执行（toolCallParser.js:10-67）；模糊匹配器与 `[[VCPToolUse=Forbidden]]` 占位符构成误触发防护（toolMarkerFuzzyMatcher.js、chatCompletionHandler.js:42）。上述为源码直接确认，边界情形未运行验证。

**对象模型**：本次未找到"输出对象"概念。聊天输出没有服务端对象 ID、类型、版本或生命周期——流式直通时每个 chunk 的 `id` 由服务端临时构造（如 `chatcmpl-vcp-${Date.now()}`，`vcpInfoHandler.js:129`），不构成持久对象。具有稳定身份的实体是**派生物**而非输出对象：

- 工具调用记录：每条记录有 `recordId`，需在 `config/tool-call-records.config.json` 中显式启用后才会落库，默认关闭（`modules/toolCallRecordStore.js:13-36`）。
- 论坛帖子：文件名内嵌 UID（`Plugin/VCPForum/VCPForum.js:247-294`）。
- 日记文件：按角色和日期落盘（`Plugin/DailyNote/dailynote.js:14`）。
- 记忆计算产物：RiverMemo/TagMemo 的 SQLite artifact 表，建表迁移在 `rust-vexus-lite/src/schema.rs`，JS 侧不再保留独立的 schema 管理器。这里的 "artifact" 指记忆计算产物（`artifact_sig`），与生成式输出无关，属术语撞名，本次按记忆系统处理、未展开。
- 聊天记录：per-agent SQLite 的 messages/postTurns 表，默认每 agent 保留 100 条，定位是记忆与上下文系统，用户可见的聊天存档由前端持有（`Plugin/OneRing/OneRingDB.js:23-97`）。

事实源关系：聊天时间线的事实源在前端；服务端持久化的是从聊天流旁路截取的派生物。

## 2. 增量生成、更新与最终化

- **流式生成**：上游 SSE 到达后按行解析并原样转发给客户端，同时后台累积全文，供后续工具循环解析使用；输出本身是纯文本流，服务端不做逐 token 的结构化更新（`streamHandler.js:297-343`）。
- **推理内容转换**：开启可选开关 `ReasoningToContentEnabled` 后，服务端把上游 `reasoning_content` 等字段改写成 `<think>/<thinking>` 块追加到正文，并在流结束时补齐闭合标签（`streamHandler.js:172-240`、`modules/reasoningContentAdapter.js`）。
- **最终化**：上游返回 `finish_reason: stop` 时，服务端补发自己的 final chunk 与 `data: [DONE]` 结束该流；工具循环达到轮数上限时，改为发送 `finish_reason: 'length'`（`streamHandler.js:445-752`）。
- **失败收口**：上游返回非 200 时，服务端仍以 200 状态回写一个 SSE 错误块；连接超时默认 15 分钟，重试次数由 `ApiRetries` 控制（默认 3），90 秒收不到 chunk 即判定流冻结，并向流中注入 `[上游响应超时，流已中断]`（`streamHandler.js:255-282`、`modules/chatCompletionHandler.js:1190-1248`）。
- **工具循环的更新方式**：采用整体覆盖，工具结果作为新的 user 消息追加后整段重新请求模型，没有 AST 或 patch 级的局部更新（`streamHandler.js:579-713`）。
- **增量补丁能力**：只有 `Plugin/AICodeWorker` 的 patch 模式会输出 unified diff 供人工审查后落盘，是本次唯一与 diff 相关的实现；主链路没有 diff 应用机制（`Plugin/AICodeWorker/README.md:53-55`）。

## 3. 投影表面与多视图关系

- **消息内（inline）**：模型正文、工具结果汇总块和本轮工具调用摘要块都作为 assistant 或 user 角色的 chunk 注入同一条 SSE 流。同一份工具结果在这里有两个投影：模型视角的 `VCP_TOOL_PAYLOAD` user 消息供继续生成，用户视角的 VCPInfo 文本块供展示，两者内容同源、格式不同（`streamHandler.js:504-688`）。
- **WebSocket 侧栏与通知**：VCPLog 服务通道向声明为 `VCPLog` 类型的客户端推送工具名、状态和内容，并带离线补发缓存；OpenWebUI 的侧栏日记面板则用 iframe `srcdoc` 配合 fetch 代理嵌入（`WebSocketServer.js:583-619`、`docs/FRONTEND_COMPONENTS.md:528-559`、`OpenWebUISub/VCP_DailyNote_SidePanel.user.js`）。
- **独立页面**：论坛帖子由 `routes/forumApi.js` 提供 REST 读取，`AdminPanel-Vue/src/views/VcpForum/*` 负责展示，形成模型写、人读的分工。
- **外部浏览器与本地文件**：MediaRenderer 的产物写入 `image/media-renderer/`、`file/media-renderer/`，通过图床 URL 访问；AICodeWorker 直接在 `ALLOWED_PROJECT_ROOTS` 白名单目录内改文件（`Plugin/MediaRenderer/README.md:345-352`、`Plugin/AICodeWorker/README.md:160-161`）。
- **多视图同步**：同一派生物（例如一份日记文件）会同时出现在前端聊天气泡、VCP 通知、日记管理面板和 RAG 向量库中，各视图分别读取磁盘文件，本次未找到服务端主动的多视图同步协议（文档称向量库基于文件哈希差分同步，`Plugin/RAGDiaryPlugin/README.md`，未运行验证）。

关键词检索说明：canvas 的命中都落在展示层绘制——仪表盘图表、背景动画与主题编辑器的色板（`AdminPanel-Vue/src/components/dashboard/ActivityChartCard.vue:4`、`VcpAnimation.vue:130`、`views/ThemeEditor.vue`），RagTuning 页的 iframe 用于文档预览，notebook 只作为日记编辑器的字段名出现（`AdminPanel-Vue/src/views/RagTuning.vue:988`、`AdminPanel-Vue/src/views/AgentFilesEditor/DiarySyntaxEditorModal.vue:36`）。这些位置与输出画布、笔记本或沙箱无关，本次未找到此类投影表面。

## 4. 表现类型、依赖与运行环境

- **文本/Markdown**：服务端不渲染 Markdown；`docs/Markdown_Output_Guideline.md` 要求插件以带 `text` 类型 content part 的形式返回 Markdown 原文，交由模型转发、前端渲染（`docs/Markdown_Output_Guideline.md:9-25`）。
- **图片**：生成的图片落盘到 `image/gptimagegen/` 等目录，插件返回图床 HTTP URL（路径形如 `/pw=<key>/images/...`）和可选的 base64 `image_url` part；富内容中的图片还会再经多模态翻译管线处理（`GPTImageGen.js:1070-1199`、`streamHandler.js:79-124`）。
- **HTML/SVG/JS 执行**：`Plugin/MediaRenderer` 在服务端托管的 Chrome 独立浏览器上下文中渲染 AI 编写的 HTML/SVG，输出 PNG/JPG/WebP/GIF/MP4/WebM；AI 编写的 JS 音乐合成代码则在独立 Node 子进程运行，输出 WAV。托管 Chrome 的进程生命周期由 browserRuntimeManager.js:516 管理，安全约束如下（`Plugin/MediaRenderer/README.md:321-342`）：
  - HTML 的 JS 默认关闭，动画/内置库模式才开启；
  - 资源由 Node 预取改写为 Data URI；
  - 页面运行时网络请求被阻断，云元数据地址禁止；
  - 执行超时与进程树回收；
  - `GenerateAudio` 需要 6 位管理员验证码。
- **语言解释器/CLI**：AICodeWorker 调度本机 opencode CLI 做代码任务，分为 analyze、patch、write 三种模式，任务以 jobId 异步管理；PowerShellExecutor、LinuxShellExecutor 和 SSHManagerService 则直接提供系统命令执行，其中 PowerShellExecutor 标注了 `requiresAdmin:true`（`Plugin/AICodeWorker/README.md:112-149`、`Plugin/PowerShellExecutor/plugin-manifest.json`）。
- **完整项目/IDE 工作区**：本次未找到（CodeSearcher 是编译好的搜索二进制，非项目工作区）。
- **依赖提供**：stdio 插件子进程以插件目录为 cwd 运行，MediaRenderer 复用根项目的 puppeteer 与 sharp 依赖，Anime.js、Three.js、Pixi.js 的 CDN 标签被重定向到本地 vendor 文件（`Plugin.js:390,1728`、`Plugin/MediaRenderer/README.md:49-427`）。

## 5. 用户交互、事件与错误反馈

- **中止**：客户端向 `/v1/interrupt` 发 POST 并带上 `requestId/messageId`，对应请求便沿 AbortController 级联中止；客户端断连（req aborted/close、res close）也走同一条中止链（`server.js:1058-1167`、`chatCompletionHandler.js:753-807`）。
- **审批**：工具调用可能被 `modules/toolApprovalManager.js` 按 `approveAll` 或工具级规则拦下，审批响应经 WebSocket 的 `tool_approval_response` 回传；拒绝、超时和失败会在结果摘要中分别标注（`WebSocketServer.js:485`、`streamHandler.js:610-617`）。
- **验证码**：`VCPToolCode` 开关打开后，每次工具调用都需要 6 位管理员验证码，解码逻辑在 `modules/captchaDecoder.js`（`toolExecutor.js:343-355`）。
- **错误反馈**：错误以 `[ERROR]`、`[UPSTREAM_ERROR]` 文本块注入 SSE 流，工具失败则在结果摘要里汇总，两条路径都以文本块呈现，不走结构化事件通道（`streamHandler.js:635-651`）。
- **事件回传**：工具执行进度由 VCPLog 经 WebSocket 推送（`toolExecutor.js:484-489`）。
- **交互状态恢复**：服务端不保存 UI 状态，工具循环的中间消息（`currentMessagesForLoop`）只存在于单次请求的内存里，重载后无法恢复；该判断来自静态代码确认（`streamHandler.js:68`）。

## 6. 编辑、diff、版本与协作

- **用户编辑输出**：本仓库内未找到针对模型输出对象的编辑界面，管理面板只覆盖配置、日记和记忆管理；模型一侧的"编辑"由 DailyNoteEdit 插件完成，它更新既有日记文件，落盘用 `wx` 原语做原子写（`Plugin/DailyNote/dailynote.js`、`Plugin/RAGDiaryPlugin/README.md:30-34`）。
- **diff**：只有 AICodeWorker 的 patch 模式会输出 unified diff 文本，经人工确认后由 ServerFileOperator 落盘；仓库内没有 diff 应用器，也没有接受或拒绝界面（`Plugin/AICodeWorker/README.md:53-55`）。
- **版本**：日记和论坛文件都没有版本概念；RAG 向量库提供快照、自修复镜像与回溯功能，属文档描述；OneRing 的 messages 表支持 `updateMessage`，用于 retry 和编辑场景（`Plugin/RAGDiaryPlugin/README.md`、`Plugin/OneRing/OneRingDB.js:99` 附近）。
- **协作**：多个 Agent 可以共写一本日记，文档称借此追踪工作管线进度，协作发生在记忆层；论坛写入另有文件锁和并发上限（`routes/forumApi.js:22-46`）。
- **CRDT/选区编辑**：本次未找到。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：工具按插件类型走四种执行位置——direct 与 hybridservice 插件在主进程内调用，stdio 插件以 shell 模式 spawn 成子进程，MediaRenderer 走托管 Chrome，分布式插件连远端 WebSocket 节点（节点协议本次只确认了广播与审批通道）。模型生成的任意代码不进入主进程执行，`modules/` 全量检索未发现 `vm.*`、`new Function` 或 `eval` 调用（`Plugin.js:390-1728`）。
- **能力授予**：权限按各插件自己的边界管理，没有统一的能力桥。标注 `requiresAdmin` 的插件（PowerShellExecutor、MediaRenderer 的 GenerateAudio）需要验证码；AICodeWorker 用 `ALLOWED_PROJECT_ROOTS` 白名单加 `MAX_CONCURRENT_JOBS` 限制并发，图床路径由带 key 的 URL 前缀保护（`Plugin/AICodeWorker/README.md:72-83`、`server.js:859-868`）。普通插件内的网络访问不受限制，插件自行调用 axios 或 fetch（如 VSearch 插件），MediaRenderer 的渲染环境则阻断网络。
- **宿主动作**：shell 执行、文件读写、定时任务和 WebSocket 广播都有对应实现；定时任务由 `timely_contact` 写成 `VCPTimedContacts/` 下的任务文件，工具审批（Human-in-the-loop）由 `modules/toolApprovalManager.js` 按配置规则执行（`toolExecutor.js:333-341`、`server.js:997-1046`）。

## 8. 持久化、恢复、分享与导出

- **持久化形式**：派生物按类型各有落盘方式——日记与论坛写成 Markdown 文件，图片存为二进制，定时任务存成 JSON，工具调用记录和 OneRing 时间线进 SQLite。调试信息只留在内存和日志里：finalContext 快照保留最近 5 组、不落盘，chat 日志按需写入 `DebugLog/chat/`。输出对象本身没有事件日志或快照形式的持久化（`modules/finalContextStore.js:21-23`）。
- **恢复**：聊天的恢复由外部前端负责，本次未验证；服务端一侧的派生物恢复就是重新读取文件和数据库，入口包括论坛的 `ReadPost`、`routes/forumApi.js` 以及管理面板的日记、论坛与记录页面。
- **分享/导出**：图片通过图床 URL 分享，论坛帖子通过 REST 读取；未找到专门的导出端点（例如把聊天导出成文件），chat 日志文件本身可以充当原始导出物（`GPTImageGen.js:1093`、`routes/forumApi.js`）。
- **删除/迁移**：工具调用记录按 `retentionDays` 自动清理，OneRing 按条数修剪，RAG 向量库则按文件变更做差分同步（`modules/toolCallRecordStore.js:27-35`、`OneRingDB.js:67-97`、`Plugin/RAGDiaryPlugin/README.md`）。

## 9. 模型回流、对象感知与持续维护

存在三类回流路径，均为源码确认：

- **日记回流**（闭环最完整）：模型通过 DailyNote 插件的 create/update 命令写日记，文件提交后由知识库管理器的后台队列索引；后续请求中 RAGDiaryPlugin 检索到这些内容，按 `<!-- VCP_RAG_BLOCK_START -->` 块注入上下文，并随新上下文刷新历史 RAG 块（`modules/chatCompletionHandler.js:565-625` 的 `_refreshRagBlocksIfNeeded`）。早期版本让模型直接输出日记块、服务端解析落盘，这条输出块协议在当前快照已不在服务端链路中，写入统一走工具调用。
- **工具记录回流**：模型可以用 `ToolCallRecordQuery` 工具查询工具调用记录，该工具在配置中排除自查询；`VCPTimeLine` 和 `OneRingMemo` 则提供时间线与记忆读取（`modules/toolCallRecordStore.js:23`）。
- **对象感知与定向修改**：VCPForum 支持按 UID 定向续写（`ReadPost`/`ListAllPosts`/`ReplyPost`），AICodeWorker 支持按 jobId 查询任务结果。对象身份只存在于各插件自己的命名空间里（UID、jobId、文件名），没有统一的对象注册表，模型无法"列出我的全部输出"（`Plugin/VCPForum/VCPForum.js:349-387`、`Plugin/AICodeWorker/README.md:132-136`）。
- **持续维护**：跨回合"继续修改同一对象"没有协议支撑——每次工具调用都是新请求，状态由插件自己持久化。

## 10. 生命周期、资源治理与性能

- **请求生命周期**：服务端把每个请求登记在 `activeRequests` Map 中，30 分钟超时后自动清理；关闭服务时进入 DRAINING 状态，先拒绝新请求、再中断活动请求并等其排空（`server.js:142-365`）。
- **流资源**：SSE 流靠 5 秒心跳维持，90 秒收不到 chunk 即判定空闲，最后以 `[DONE]` 收尾（`modules/handlers/streamHandler.js:176-312`）。
- **进程资源**：插件子进程带超时并做跨平台进程树回收，Windows 用 `taskkill /T /F`、Unix 对进程组发 SIGKILL，非 Windows 平台 spawn 时还带 `detached`；MediaRenderer 为每一步开独立浏览器上下文、页面用完即关、逐帧清理临时目录；AICodeWorker 把并发上限锁死为 1（`Plugin.js:325`、`Plugin/MediaRenderer/README.md:326-334`、`Plugin/AICodeWorker/README.md:81-83`）。
- **缓存/限额**：响应重放缓存可选，默认关闭；工具调用记录按保留期清理，OneRing 按条数修剪，finalContext 用 5 组的内存滑窗。多对象或多画布的限额概念本次未找到，项目中缺少对象概念本身（`chatCompletionHandler.js:56-124`）。

## 11. 测试、已确认边界与未验证事项

**测试覆盖**（`tests/`，node:test）：根 `tests` 下有 26 个 `*.test.js`，`tests/chromeBridge/` 另有 ChromeBridge 运行时核心、页面句柄、页面图片、内容可编辑回复等测试。已覆盖的方面包括：

- 工具与预处理：动态工具注册表、OpenHerPersona 预处理器与观察者、占位符探索、结果去重；
- 安全与并发：图床路径安全、分布式取消、AgentAssistant Flowlock；
- 光标主题打包；
- 原生检索：NativeKnowledgeRuntime registry、RiverMemo 联合查询计划/回退/默认模式、语义去重、日记索引原子增量、标签派生失效、RAG 日记 copy-on-write、SAR 管理器、TDB 0.8.5、时间线 RiverMemo、associativeDiscovery RiverMemo。

流式工具循环、日记块解析、论坛写入、MediaRenderer 和协议解析均无自动化测试；根 `package.json` 的 `npm test` 是占位脚本（package.json:6）。

**本次明确未验证/未覆盖**：

- 未运行服务器，所有链路行为均为静态代码推断；SSE 半截流、中止竞态、审批交互、MediaRenderer 渲染、AICodeWorker 子进程等均未运行验证。
- 聊天"展示"与"重新打开"环节依赖外部前端（VCPChat 等），不在本仓库，未验证。
- 分布式 WebSocket 节点协议、RAG 向量差分同步、OneRing 时间线回读仅确认入口，未深入。
- 声明"未找到"的结论范围：输出对象模型、diff 应用器、用户编辑界面、CRDT、导出端点、IDE/项目工作区——检索范围为本仓库全部 JS/Vue 源码与 docs/ 文档（vendor/dist 除外），且以 `modules/`、`Plugin.js`、`server.js`、`AdminPanel-Vue/src` 通读为主。

## 12. 关键源码索引

- `server.js:1217` `/v1/chat/completions` 入口；`server.js:1231` `/v1/chatvcp/completions`；`server.js:1058` `/v1/interrupt`；`server.js:1303` `handleDiaryFromAIResponse`；`server.js:478` chat 日志
- `modules/chatCompletionHandler.js:644` `handle()` 23 步编排；`modules/chatCompletionHandler.js:1152` 上游 fetch；`modules/chatCompletionHandler.js:531` RAG 块刷新
- `modules/handlers/streamHandler.js:143` 流式直通与累积；`modules/handlers/streamHandler.js:441` 工具循环；`modules/handlers/nonStreamHandler.js:380` 非流式循环
- `modules/vcpLoop/toolCallParser.js:74` `parse()`；`modules/vcpLoop/toolExecutor.js:192` `execute()`
- `vcpInfoHandler.js:117` `streamVcpInfo`；`WebSocketServer.js:583` `broadcast`
- `Plugin.js:390`/`Plugin.js:1728` stdio 插件 spawn；`Plugin.js:1189` direct 插件
- `modules/toolCallRecordStore.js`、`modules/finalContextStore.js:288`、`Plugin/OneRing/OneRingDB.js:23`
- `Plugin/VCPForum/VCPForum.js:247`、`routes/forumApi.js`、`Plugin/GPTImageGen/GPTImageGen.js:1070`、`Plugin/MediaRenderer/README.md:321`、`Plugin/AICodeWorker/README.md:53`、`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135`
- `docs/Markdown_Output_Guideline.md`、`docs/FRONTEND_COMPONENTS.md:443`、`OpenWebUISub/`、`SillyTavernSub/`
