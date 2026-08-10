# VCPToolBox 生成式输出与运行时调查笔记

> 调查对象：`../../VCPToolBox`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`c4c4d00b84202ec97f99c225b34014206aca8eea`（分支：`main`）
>
> 调查方式：静态代码审查。用 grep/glob 检索 artifact/canvas/sandbox/iframe/webview/notebook/diff/patch/execution/runtime/preview/markdown/chat/stream 等关键词，通读 server.js、modules/chatCompletionHandler.js、modules/handlers/streamHandler.js 与 nonStreamHandler.js、modules/vcpLoop/toolCallParser.js 与 toolExecutor.js、vcpInfoHandler.js、Plugin.js、modules/toolCallRecordStore.js、modules/finalContextStore.js、Plugin/OneRing/OneRingDB.js、Plugin/RAGDiaryPlugin、Plugin/VCPForum/VCPForum.js、Plugin/GPTImageGen/GPTImageGen.js、Plugin/MediaRenderer、Plugin/AICodeWorker、routes/forumApi.js、routes/protocolBridge.js；对照 docs/Markdown_Output_Guideline.md、docs/FRONTEND_COMPONENTS.md、docs/PLUGIN_ECOSYSTEM.md 等文档与源码交叉核对
>
> 调查范围：输出协议与对象模型、流式生成链与最终化、投影表面、表现类型与执行运行时、能力桥、持久化与模型回流、生命周期治理、测试覆盖。未启动服务器，未做任何端到端运行验证；第三方聊天前端 VCPChat 本体不在本仓库，不在本次调查范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 是 OpenAI 兼容的 AI 中间层服务端（`/v1/chat/completions`），本身不渲染聊天，也不持有聊天事实源：模型输出以标准 SSE 流直通转发，工具执行结果以文本块形式回注聊天流，界面渲染交给外部前端（官方 VCPChat 为独立仓库，OpenWebUI/SillyTavern 通过 `OpenWebUISub`/`SillyTavernSub` 用户脚本增强）。服务端具备明确的"输出协议"（VCP 纯文本标记）、"工具执行运行时"（stdio 子进程 / in-process / 分布式 WebSocket 节点）和"派生对象持久化"（日记文件、论坛帖子、图片、工具调用记录、OneRing 时间线），但不存在带稳定 ID 的输出对象模型，无 diff/接受/拒绝的协作编辑层。模型生成的 HTML/SVG/JS 可经 MediaRenderer（托管浏览器 + 音频合成子进程）与 AICodeWorker（opencode CLI）进入受控执行环境，属局部 G3；主链路的聊天输出本身停留在 G0-G1（文本 + 落盘文件）。

能力等级认定：**G1（主形态）＋ 局部 G3（MediaRenderer / AICodeWorker 等插件级执行环境）**。依据：输出没有独立对象生命周期（G0 特征）；大量产物以文件/图片落盘并可单独查看、下载、被模型回读（G1 特征）；MediaRenderer 对模型编写的 HTML/SVG/JS 提供隔离执行（网络阻断、JS 默认关闭、子进程超时），AICodeWorker 以 jobId 异步管理 opencode 子任务（G3 特征）；但无 schema 化声明式对象（非 G2）、无用户与模型围绕同一对象持续编辑的 diff/版本机制（非 G4）、输出对象不长期存在于桌面/环境（非 G5）。

## 系统边界与总体调用链

系统边界：

- **服务端中间层**（本仓库）：认证 → 消息预处理（变量替换、RAG 注入、多模态翻译、Detector、角色分割）→ 上游模型调用 → 流式直通 + VCP 工具循环 → 工具执行（本地/远端）→ 结果回注 → 派生物落盘。
- **聊天前端**（仓库外）：VCPChat（官方桌面端，`docs/TECHNICAL_LITE.md:186-190` 说明为独立项目）、OpenWebUI、SillyTavern。本仓库只提供用户脚本与正则增强（`OpenWebUISub/`、`SillyTavernSub/`）。
- **管理面板**（`AdminPanel-Vue` + `adminServer.js`）：纯管理/查看界面，无聊天界面。本次在 `AdminPanel-Vue/src` 全量检索未找到聊天流渲染组件，`marked` 仅用于日记/占位符预览（`AdminPanel-Vue/src/views/DailyNotesManager.vue:105`）。
- **Rust 向量引擎**（`rust-vexus-lite`）：记忆/检索计算后端，不直接参与输出生成。

完整主链路（触发 → 生成 → 展示 → 保存 → 重新打开）：

1. 客户端 POST `/v1/chat/completions`（或 `/v1/chatvcp/completions` 强制展示 VCP 信息），请求体含 `messages`、`stream`、可选 `requestId/messageId`（`server.js:1217-1242`）。
2. `ChatCompletionHandler.handle` 执行消息预处理：VCPTavern 注入 → 变量替换 → RAGDiaryPlugin 等 messagePreprocessor 注入知识块 → Detector/SuperDetector → 角色分割（`modules/chatCompletionHandler.js:899-1121`）。
3. 以重试机制向上游 `{apiUrl}/v1/chat/completions` 发起请求（`modules/chatCompletionHandler.js:1152-1182`）。
4. 流式：SSE 逐行直通转发给客户端，同时后台累积全文；非流式：累积 JSON 响应（`streamHandler.js:143-406`）。
5. 工具循环：从累积正文解析 `<<<[TOOL_REQUEST]>>>` 块（最多 `MaxVCPLoopStream` 轮，默认 5，`streamHandler.js:70`），执行插件工具，工具结果以 `<!-- VCP_TOOL_PAYLOAD -->` user 消息回灌后再次调用上游（`streamHandler.js:441-735`）。
6. 展示：文本与 `[[VCP调用结果信息汇总:...]]` 块随 SSE 到达前端；外部前端渲染 Markdown；`VCPLog` 插件经 WebSocket 推送工具调用详情（`vcpInfoHandler.js:117`、`WebSocketServer.js:583`）。
7. 保存：可选 chat 日志（`DebugLog/chat/`，`server.js:478-499`）；模型输出的 `<<<DailyNoteStart>>>` 块由 `handleDiaryFromAIResponse` 解析并交给 DailyNoteWrite 插件写入 `dailynote/`（`server.js:1303-1417`）；VCPForum 插件把帖子写入 `dailynote/VCP论坛/*.md`（`Plugin/VCPForum/VCPForum.js:247-294`）；生图插件把图片写入 `image/` 并经 ImageFileServer 提供 URL（`Plugin/GPTImageGen/GPTImageGen.js:1070-1100`）；工具调用记录可选写入 SQLite（`modules/toolCallRecordStore.js`）。
8. 重新打开：聊天历史由外部前端持有，服务端不提供聊天恢复接口；服务端持久化的派生物可被模型重新读取（论坛 `ReadPost`、日记 RAG 注入、文件工具、`ToolCallRecordQuery`）。此环节依赖外部前端，本次未运行验证。

## 1. 触发方式、输出协议与对象模型

**触发方式**：全部输出能力均由"模型自由文本中的特殊标记"触发，无独立的"输出创建"API。协议均为纯文本标记（`docs/PLUGIN_ECOSYSTEM.md`、`VCP.md:44-57` 自述为纯文本标记协议）：

- 工具调用块：`<<<[TOOL_REQUEST]>>> ... <<<[END_TOOL_REQUEST]>>>`，字段值用「始」「末」包裹（`modules/vcpLoop/toolCallParser.js:5-20`）。
- 工具结果展示块：`[[VCP调用结果信息汇总:...]]`（`vcpInfoHandler.js:96-104`）。
- 日记块：`<<<DailyNoteStart>>> ... <<<DailyNoteEnd>>>`（`server.js:1344`）。
- 角色分割：`<<<[ROLE_DIVIDE_USER]>>>` 等（`streamHandler.js:504`）。
- 工具结果回灌：`<!-- VCP_TOOL_PAYLOAD -->` 前缀（`streamHandler.js:686`）。
- RAG 知识块：`<!-- VCP_RAG_BLOCK_START {metadata} --> ... <!-- VCP_RAG_BLOCK_END -->`（`chatCompletionHandler.js:546`）。

**协议健壮性**：解析器处理半截流（SSE 行缓冲 + StringDecoder，`streamHandler.js:146-311`）、转义（`「始ESCAPE」` 等，`toolCallParser.js:10-20`）、思考块剥离（未闭合 `<think>` 之后的内容被丢弃以防潜藏工具调用被执行，`toolCallParser.js:36-67`）、误触发防护（模糊匹配器 `modules/vcpLoop/toolMarkerFuzzyMatcher.js`；`[[VCPToolUse=Forbidden]]` 占位符禁用工具解析，`chatCompletionHandler.js:42`）。上述为源码直接确认，边界情形未运行验证。

**对象模型**：本次未找到"输出对象"概念。聊天输出没有服务端对象 ID、类型、版本或生命周期——流式直通时每个 chunk 的 `id` 由服务端临时构造（如 `chatcmpl-vcp-${Date.now()}`，`vcpInfoHandler.js:129`），不构成持久对象。具有稳定身份的实体是**派生物**而非输出对象：

- 工具调用记录：`recordId`（仅 `config/tool-call-records.config.json` 启用后落库，默认 `enabled:false`，`modules/toolCallRecordStore.js:13-36`）。
- 论坛帖子：文件名内嵌 UID（`Plugin/VCPForum/VCPForum.js:247-294`）。
- 日记文件：按角色/日期落盘（`Plugin/DailyNote/dailynote.js:14`）。
- 记忆计算产物：RiverMemo/TagMemo 的 SQLite artifact 表（`modules/knowledgeBase/schemaManager.js:42-90`）。注意此处 "artifact" 指记忆计算产物（`artifact_sig`），与生成式输出无关，属术语撞名，本次按记忆系统处理、未展开。
- 聊天记录：`Plugin/OneRing/OneRingDB.js:23-53` 的 per-agent SQLite（messages/postTurns 表），默认每 agent 保留 100 条（`OneRingDB.js:67-97`），定位是记忆/上下文系统而非用户可见聊天存档。

事实源关系：聊天时间线的事实源在前端；服务端持久化的是从聊天流旁路截取的派生物。

## 2. 增量生成、更新与最终化

- **流式生成**：上游 SSE 按行解析、原样转发，同时后台累积（`streamHandler.js:297-343`）。不做逐 token 结构化更新——输出就是纯文本流。
- **推理内容转换**：可选 `ReasoningToContentEnabled` 将上游 `reasoning_content` 等字段改写为 `<think>/<thinking>` 块追加到正文，并在流结束时规范补闭合标签（`streamHandler.js:172-240`、`modules/reasoningContentAdapter.js`）。
- **最终化**：上游 `finish_reason: stop` 时服务端补发自己的 final chunk 和 `data: [DONE]`（`streamHandler.js:445-460`）；达到循环上限时发 `finish_reason: 'length'`（`streamHandler.js:741-752`）。
- **失败收口**：上游非 200 时以 200 + SSE 错误块回写客户端；连接超时默认 15 分钟、重试 `ApiRetries` 默认 3、90 秒无 chunk 判定流冻结并注入 `[上游响应超时，流已中断]`（`streamHandler.js:255-282`、`chatCompletionHandler.js:1190-1248`）。
- **工具循环的更新方式**：整体覆盖式——工具结果以新 user 消息追加后整段重新请求模型，无 AST/patch 级更新（`streamHandler.js:579-713`）。
- **增量补丁能力**：仅 `Plugin/AICodeWorker` 的 patch 模式输出 unified diff 供人工审查后落盘（`Plugin/AICodeWorker/README.md:53-55`），是本次唯一与 diff 相关的实现；主链路无 diff 应用机制。

## 3. 投影表面与多视图关系

- **消息内（inline）**：模型正文、`[[VCP调用结果信息汇总]]` 文本块、`[本轮工具调用摘要:]` 块，均以 assistant/user 角色 chunk 注入同一 SSE 流（`streamHandler.js:504-663`）。同一工具结果存在两个投影：模型视角的 `VCP_TOOL_PAYLOAD` user 消息（用于继续生成）与用户视角的 VCPInfo 文本块（用于展示），内容同源但格式不同（`streamHandler.js:631-688`）。
- **WebSocket 侧栏/通知**：VCPLog 服务通道向 `VCPLog` 类型客户端推送 `{tool_name, status, content}`，带离线补发缓存（`WebSocketServer.js:583-619`）；OpenWebUI 侧栏日记面板用 iframe `srcdoc` + fetch 代理嵌入（`docs/FRONTEND_COMPONENTS.md:528-559`、`OpenWebUISub/VCP_DailyNote_SidePanel.user.js`）。
- **独立页面**：论坛帖子由 `routes/forumApi.js` 提供 REST 读取，`AdminPanel-Vue/src/views/VcpForum/*` 展示（模型写、人读）。
- **外部浏览器/本地文件**：MediaRenderer 产物写入 `image/media-renderer/`、`file/media-renderer/` 并通过图床 URL 访问（`Plugin/MediaRenderer/README.md:345-352`）；AICodeWorker 直接在 `ALLOWED_PROJECT_ROOTS` 白名单目录内改文件（`Plugin/AICodeWorker/README.md:160-161`）。
- **多视图同步**：同一派生物（如日记文件）同时出现在前端聊天气泡、VCP 通知、日记管理面板和 RAG 向量库中，各视图各自读取磁盘文件；本次未找到服务端主动的多视图同步协议（文档称向量库基于文件哈希差分同步，`Plugin/RAGDiaryPlugin/README.md`，未运行验证）。

关键词检索说明：仓库内的 canvas 均为仪表盘图表/背景动画/颜色转换用途（`AdminPanel-Vue/src/components/dashboard/ActivityChartCard.vue:4`、`VcpAnimation.vue:130`、`ThemeEditor.vue:866`），RagTuning 页 iframe 为文档预览（`AdminPanel-Vue/src/views/RagTuning.vue:988`），notebook 仅出现在日记编辑器字段名（`AdminPanel-Vue/src/views/AgentFilesEditor/DiarySyntaxEditorModal.vue:36`）——均与输出画布/笔记本/沙箱无关，本次未找到此类投影表面。

## 4. 表现类型、依赖与运行环境

- **文本/Markdown**：服务端不渲染；`docs/Markdown_Output_Guideline.md` 规定插件以 `content: [{type:'text', text:'<markdown>'}]` 返回 Markdown 文本，交由模型转发、前端渲染（`docs/Markdown_Output_Guideline.md:9-25`）。
- **图片**：生成图片落盘 `image/gptimagegen/` 等目录，返回 HTTP URL（经 `/pw=<key>/images/...` 图床）和可选 base64 `image_url` part（`GPTImageGen.js:1070-1199`）；富内容 `image_url` 会被多模态翻译管线处理（`streamHandler.js:79-124`）。
- **HTML/SVG/JS 执行**：`Plugin/MediaRenderer` —— AI 编写的 HTML/SVG 在服务端托管 Chrome 的独立浏览器上下文渲染为 PNG/JPG/WebP/GIF/MP4/WebM；AI 编写的 JS 音乐合成代码在独立 Node 子进程运行输出 WAV。安全约束：HTML 的 JS 默认关闭（动画/内置库模式才开启）、资源由 Node 预取改写为 Data URI、页面运行时网络请求被阻断、云元数据地址禁止、执行超时与进程树回收、`GenerateAudio` 需要 6 位管理员验证码（`Plugin/MediaRenderer/README.md:321-342`）。`modules/browserRuntimeManager.js:516` 管理 Chrome 进程生命周期。
- **语言解释器/CLI**：AICodeWorker 调度本机 opencode CLI（analyze/patch/write 三模式，jobId 异步任务，`Plugin/AICodeWorker/README.md:112-149`）；PowerShellExecutor（`requiresAdmin:true`，`Plugin/PowerShellExecutor/plugin-manifest.json`）、LinuxShellExecutor、SSHManagerService 提供系统命令执行。
- **完整项目/IDE 工作区**：本次未找到（CodeSearcher 是编译好的搜索二进制，非项目工作区）。
- **依赖提供**：stdio 插件子进程在插件目录 cwd 下运行（`Plugin.js:315`、`Plugin.js:1551`），MediaRenderer 复用根项目 puppeteer/sharp（`Plugin/MediaRenderer/README.md:49-51`），Anime.js/Three.js CDN 标签被重定向到本地 vendor 文件（`Plugin/MediaRenderer/README.md:413-427`）。

## 5. 用户交互、事件与错误反馈

- **中止**：`POST /v1/interrupt`（按 `requestId/messageId`）触发 AbortController 级联中止；客户端断联（`req aborted/close`、`res close`）也会转成同一中止链（`server.js:1058-1167`、`chatCompletionHandler.js:753-807`）。
- **审批**：`modules/toolApprovalManager.js` 按规则（`approveAll` 或工具规则）拦截工具调用，审批响应经 WebSocket `tool_approval_response` 回传（`WebSocketServer.js:485`）；结果区分"拒绝/超时/失败"并在摘要中标注（`streamHandler.js:610-617`）。
- **验证码**：`VCPToolCode` 开关开启时工具调用需 6 位管理员验证码（`toolExecutor.js:343-355`、`modules/captchaDecoder.js`）。
- **错误反馈**：错误以 SSE 文本块（`[ERROR]`/`[UPSTREAM_ERROR]`）注入流而非结构化事件；工具失败在摘要中汇总（`streamHandler.js:635-651`）。
- **事件回传**：工具执行进度经 VCPLog WebSocket 推送（`toolExecutor.js:484-489`）。
- **交互状态恢复**：服务端无 UI 状态；工具循环中间状态（`currentMessagesForLoop`）只存活于单次请求内存（`streamHandler.js:68`），重载后不恢复。此为静态代码确认的边界。

## 6. 编辑、diff、版本与协作

- **用户编辑输出**：本仓库内未找到用户对模型输出对象的编辑界面（管理面板只有配置/日记/记忆管理等）。模型侧"编辑"通过 DailyNoteEdit 插件更新既有日记文件（`Plugin/RAGDiaryPlugin/README.md:30-34` 提及，`Plugin/DailyNote/dailynote.js` 用 `wx` 原子写）。
- **diff**：仅 AICodeWorker patch 模式输出 unified diff 文本，人工确认后由 ServerFileOperator 落盘（`Plugin/AICodeWorker/README.md:53-55`）；无 diff 应用器、无接受/拒绝 UI。
- **版本**：日记/论坛文件无版本概念；RAG 向量库有快照/自修复镜像与回溯功能（`Plugin/RAGDiaryPlugin/README.md`，静态文档描述）；`OneRingDB.js` 的 messages 支持 `updateMessage` 用于 retry/编辑场景（`OneRingDB.js:99` 附近）。
- **协作**：多 Agent 共写日记本（文档宣称可实现工作管线进度追踪，`Plugin/RAGDiaryPlugin/README.md`），属记忆层协作而非输出对象协作。论坛写入有文件锁与并发上限（`routes/forumApi.js:22-46`）。
- **CRDT/选区编辑**：本次未找到。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：本地主进程（direct/hybridservice 插件 in-process require，`Plugin.js:1081`）、stdio 子进程（spawn，`shell:true`，`Plugin.js:315`、`Plugin.js:1551`）、托管 Chrome（`modules/browserRuntimeManager.js`）、远端节点（WebSocket 分布式，`WebSocketServer.js`，本次仅确认广播与审批通道，未深入节点协议）。模型任意代码不进主进程执行——`modules/` 全量检索未发现 `vm.*`/`new Function`/`eval`。
- **能力授予**：按插件权限边界而非统一能力桥：`requiresAdmin` 插件需验证码（PowerShellExecutor、MediaRenderer GenerateAudio）；AICodeWorker 靠 `ALLOWED_PROJECT_ROOTS` 白名单 + `MAX_CONCURRENT_JOBS` 硬闸门（`Plugin/AICodeWorker/README.md:72-83`）；图床路径受 `/pw=<key>/` 保护（`server.js:859-868` 白名单放行）。网络能力在普通插件内不受限（插件自行 axios/fetch，如 `Plugin/VSearch`），MediaRenderer 渲染环境例外地阻断网络。
- **宿主动作**：shell 执行、文件读写、定时任务（`timely_contact` → `VCPTimedContacts/` 任务文件，`toolExecutor.js:333-341`、`server.js:997-1046`）、WebSocket 广播均有对应实现；工具审批（Human-in-the-loop）由 `modules/toolApprovalManager.js` 按配置规则执行。

## 8. 持久化、恢复、分享与导出

- **持久化形式**：派生物以源文件落盘（日记/论坛为 Markdown 文件、图片为二进制、定时任务为 JSON），记录类入 SQLite（工具调用记录、OneRing 时间线），调试类入内存快照（`modules/finalContextStore.js:21-23`，最近 5 组、不落盘）与日志文件（`DebugLog/chat/` 可选）。没有事件日志/快照形式的输出对象持久化。
- **恢复**：聊天恢复由外部前端负责（本次未验证）；服务端派生物恢复 = 重新读取文件/数据库（VCPForum `ReadPost`、`routes/forumApi.js`、管理面板日记/论坛/记录页面）。
- **分享/导出**：图片经图床 URL 可分享（`GPTImageGen.js:1093`）；论坛帖子经 REST 可读（`routes/forumApi.js`）；未找到专门的"导出"端点（如把聊天导出为文件），chat 日志文件本身可作原始导出物。
- **删除/迁移**：工具调用记录按 `retentionDays` 自动清理（`modules/toolCallRecordStore.js:27-35`）；OneRing 按条数修剪（`OneRingDB.js:67-97`）；RAG 向量库基于文件变更差分同步（`Plugin/RAGDiaryPlugin/README.md`，文档描述，未运行验证）。

## 9. 模型回流、对象感知与持续维护

存在三类回流路径，均为源码确认：

- **日记回流**（闭环最完整）：模型输出含 `<<<DailyNoteStart>>>` 块 → `handleDiaryFromAIResponse` 解析 → DailyNoteWrite 落盘（`server.js:1303-1417`）→ 后续请求中 RAGDiaryPlugin 检索并按 `<!-- VCP_RAG_BLOCK_START -->` 块注入上下文（`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135`），还可按新上下文刷新历史 RAG 块（`chatCompletionHandler.js:531-625` 的 `_refreshRagBlocksIfNeeded`）。即"模型输出 → 持久化 → 再进入模型上下文"的闭环存在。
- **工具记录回流**：`ToolCallRecordQuery` 工具允许模型查询工具调用记录（`modules/toolCallRecordStore.js:23` 配置中排除自查询）；`VCPTimeLine`、`OneRingMemo` 提供时间线/记忆读取。
- **对象感知与定向修改**：VCPForum 支持 `ReadPost`/`ListAllPosts`/`ReplyPost` 按 UID 定向续写（`Plugin/VCPForum/VCPForum.js:349-387`）；AICodeWorker 支持 `query(jobId)` 查任务结果（`Plugin/AICodeWorker/README.md:132-136`）。但对象身份只存在于各插件的自有命名空间（UID/jobId/文件名），无统一对象注册表，模型无法"列出我的全部输出"。
- **持续维护**：无跨回合的"同一对象继续修改"协议——每次工具调用都是新请求，靠插件自己持久化状态。

## 10. 生命周期、资源治理与性能

- **请求生命周期**：`activeRequests` Map 登记请求、30 分钟超时自动清理（`server.js:142`、`server.js:353-365`）；关闭时优雅排空（DRAINING 状态拒绝新请求、中断活动请求，`server.js:144-350`）。
- **流资源**：5 秒 SSE 心跳、90 秒 chunk 空闲判定、`[DONE]` 收尾（`streamHandler.js:241-282`）；上游 body 在中止/完成时 destroy（`streamHandler.js:289`）。
- **进程资源**：插件子进程带超时与 Windows 进程树回收（`Plugin.js:266-315`）；MediaRenderer 每步独立浏览器上下文、页面即用即关、逐帧临时目录清理（`Plugin/MediaRenderer/README.md:326-334`）；AICodeWorker 强制 `MAX_CONCURRENT_JOBS=1`（`Plugin/AICodeWorker/README.md:81-83`）。
- **缓存/限额**：可选响应重放缓存（`chatCompletionHandler.js:56-124`，默认关）；工具调用记录保留期清理；OneRing 条数修剪；finalContext 内存滑窗 5 组。多对象/多画布限额概念本次未找到（无对象概念）。

## 11. 测试、已确认边界与未验证事项

**测试覆盖**（`tests/`，node:test，共 7 个文件）：动态工具注册表、OpenHerPersona 预处理器、占位符探索、结果去重、图床路径安全、分布式取消。根 `package.json` 的 `npm test` 是占位脚本（`package.json:6`）。未发现针对流式工具循环、日记块解析、论坛写入、MediaRenderer、协议解析的自动化测试。

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
- `Plugin.js:315`/`Plugin.js:1551` stdio 插件 spawn；`Plugin.js:1081` direct 插件
- `modules/toolCallRecordStore.js`、`modules/finalContextStore.js:288`、`Plugin/OneRing/OneRingDB.js:23`
- `Plugin/VCPForum/VCPForum.js:247`、`routes/forumApi.js`、`Plugin/GPTImageGen/GPTImageGen.js:1070`、`Plugin/MediaRenderer/README.md:321`、`Plugin/AICodeWorker/README.md:53`、`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135`
- `docs/Markdown_Output_Guideline.md`、`docs/FRONTEND_COMPONENTS.md:443`、`OpenWebUISub/`、`SillyTavernSub/`
