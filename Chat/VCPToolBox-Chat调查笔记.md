# VCPToolBox Chat 调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-07
>
> 代码快照：`c4c4d00b84202ec97f99c225b34014206aca8eea`（分支：`main`）
>
> 调查方式：只读源码调查
>
> 调查范围：聊天会话、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md`](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)（不拥有会话事实源，边界记录）
> - 对话请求与上下文：[`../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)（请求级消息编排、协议归一化、VCP 工具循环）
> - Chat UI：[`../Chat UI/VCPToolBox-ChatUI调查笔记.md`](<../Chat UI/VCPToolBox-ChatUI调查笔记.md>)（不适用，排除证据与疑点核实）

说明：调查时 `VCPToolBox` 工作区干净；本补充以该快照的实际代码为准。

---

## 定位

VCPToolBox 是 VCP（Variable & Command Protocol）协议的**服务端 + 运维 + 配置中枢**，不是聊天产品本身：

- `server.js`（约 8.8 万行）暴露的对话相关端点全部是纯 API，没有配套 HTML 聊天页面：
  - `app.post('/v1/chat/completions', ...)`（`server.js:1206`）
  - `app.post('/v1/chatvcp/completions', ...)`（强制显示 VCP 信息的变体，`server.js:1220`）
  - `app.post('/v1/human/tool', ...)`（人类直接调用工具，`server.js:1239`）
  - `app.use(protocolBridge)`（`server.js:1235-1236`，桥接 OpenAI Responses / Anthropic Messages / Gemini GenerateContent 三种协议到内部 `/v1/chat/completions`）
- 官方桌面聊天前端是外部项目 VCPChat（`README.md:219`："推荐前端：VCPChat（官方）"），VCPToolBox 仓库内不包含它的源码。
- README 自述定位："VCP 不是一个让 AI 调用工具的框架，它是给 AI 的一个能够持续存在的世界"（`README.md:17`），系统职责是记忆/感知/自主生活/工具生态的基础设施，聊天只是众多前端可以接入的表现层之一。

## 范围结论

VCPToolBox 不提供最终用户聊天主界面，调查中发现以下两点值得注意：

1. **文档已过时**：`docs/FRONTEND_COMPONENTS.md`（生成于 2026-02-13）描述的 AdminPanel 是"原生 JS/CSS + EasyMDE 的内嵌静态前端"（该文档 §2.1-2.2），但当前代码库的实际管理面板是**AdminPanel-Vue**（Vue 3 + Pinia + vue-router 的独立 SPA 工程，`AdminPanel-Vue/package.json`），旧版原生 JS AdminPanel 已被替换/迁移。证据：
   - `adminServer.js:21-24`：`VUE_ADMIN_PANEL_ROOT = path.join(__dirname, 'AdminPanel-Vue', 'dist')`，并显式提示 `[AdminServer] Run "npm run build" inside AdminPanel-Vue before starting the admin server.`
   - `adminServer.js:22`：`LEGACY_ADMIN_PANEL_BACKUP_ROOT = path.join(__dirname, 'AdminPanel-backup-20260408-201832')`，说明旧版原生 JS 面板已被重命名为备份目录，仓库根目录已确认不存在 `AdminPanel/` 目录（只有 `AdminPanel-Vue/`）。
   - 因此本次调查以 `AdminPanel-Vue/` 源码为准，`docs/FRONTEND_COMPONENTS.md` 第 2 节内容视为历史文档，不能作为当前行为依据。

2. **管理面板是独立进程，物理上与聊天主链解耦**：`adminServer.js` 头部注释明确写道"独立后台管理面板进程，监听 PORT+1"、"目的：将 AdminPanel 与聊天主链解耦，避免主进程 SSE stall 时后台面板一起卡顿"（`adminServer.js:2-3`）。主进程 `server.js:829-834` 对 `/AdminPanel` 路径直接 302 重定向到 `PORT+1`：
   ```js
   // server.js:829-834
   const ADMIN_PORT = parseInt(port) + 1;
   app.use('/AdminPanel', (req, res) => {
       res.redirect(302, `${protocol}://${host}:${ADMIN_PORT}${originalPath}`);
   });
   ```
   这进一步说明管理面板在架构上就是和聊天请求处理链路分离的旁路系统，而不是聊天体验的一部分。

结论：AdminPanel-Vue 是运维/配置后台，OpenWebUISub 是第三方聊天前端的增强层，VCPToolBox 本身不产出面向最终用户的聊天主界面。

这不等于 VCPToolBox 不构建消息。它是一个**无会话归属的请求级消息编排器**：调用方提交一份 `messages`，服务端在内存中复制、重排、展开、注入和裁剪，形成发给模型的请求；会话 ID、历史数组和最终展示状态仍由外部前端负责。

## 消息构建调查

### 1. 入口归一化：三种协议收敛到同一条主链

标准入口是 `POST /v1/chat/completions`；`/v1/chatvcp/completions` 只额外强制显示 VCP 调用信息（`server.js:1216-1242`）。协议桥接层先把其他格式转换为 OpenAI 风格的 `{ role, content }` 数组，再在本机 HTTP 转发到标准入口（`routes/protocolBridge.js:789-857`）：

- Responses API：从 `input` 提取 `message` 项；`developer` 归一化为 `system`，文本部分拼接为字符串（`routes/protocolBridge.js:299-332`）。
- Anthropic Messages：把顶层 `system` 放在数组首位，再提取 `body.messages`（`routes/protocolBridge.js:359-379`）。
- Gemini GenerateContent：`systemInstruction` 变成 `system`，`contents[].role=model` 变成 `assistant`（`routes/protocolBridge.js:386-412`）。

桥接会把原生 `tools`、`tool_choice` 和 `parallel_tool_calls` 作为受保护的顶层字段加回转发 body，不放进 `messages` 或 RAG 文本（`routes/protocolBridge.js:54-56`, `158-173`, `820-821`）。但 VCP 自己的工具循环仍依赖模型正文中的 `<<<[TOOL_REQUEST]>>>` 纯文本标记，不能把这两套工具协议视为同一条执行链。

### 2. 初始请求：从客户端历史到首次上游 body

`ChatCompletionHandler.handle()` 对入站 body 原地处理，随后把最终消息写回 `originalBody.messages`（`modules/chatCompletionHandler.js:712-729`, `809-829`, `1123-1148`）。可复现的顺序如下：

1. 读取 `requestId/messageId`，移除仅供 VCPChat 使用的 `vcpchatExtensions`。
2. 若带 `contextTokenLimit`，先从 body 删除该字段并调用 `contextManager.pruneMessages()`。它按**文本字符数**估算长度，不计算图片等非文本 part；保留全部 `system`、以 `[系统提示:]` 开头的 user，以及最后两条消息，然后从前向后删除其他消息直到达到限制（`modules/contextManager.js:10-25`, `34-95`）。这不是摘要压缩，也不保证严格 token 上限。
3. 消费连续顶层 system 中的 `[[VCPToolUse=Forbidden]]`，移除占位符并在本次请求禁用 VCP 工具解析（`modules/chatCompletionHandler.js:182-209`, `854-857`）。同时扫描 `{{TransBase64}}` / `{{TransBase64+}}`，决定后续多模态处理；模型命中纯文本 tag 时可自动强制翻译（`modules/chatCompletionHandler.js:859-970`）。
4. 优先执行 `VCPTavern`。触发器 `{{VCPTavern::Preset...}}` 只从 system 查找，触发器本身及其他消息中的同名残留会被删除；预设按 embed → relative → depth 注入，relative/depth 可插入新的消息对象，并可解析会话时间变量（`Plugin/VCPTavern/VCPTavern.js:235-310`, `419-579`）。
5. 若请求模型是语义路由模型，使用 Tavern 注入后的消息选出真实后端模型，再应用模型重定向和思维开关（`modules/chatCompletionHandler.js:911-947`）。
6. 逐条深拷贝消息并执行变量解析。只有 `system`，或以 `[系统提示:]` / `[系统邀请指令:]` 开头的 user，才有权限展开 Agent/Toolbox；整个请求只展开一个 Agent，同名 Toolbox 只展开一次。随后处理时间、环境、SAR、日记/知识库、动态工具、插件描述等其他占位符（`modules/messageProcessor.js:146-255`, `601-823`）。
7. 按配置调用多模态预处理器（`MultiModalProcessor` 优先，否则 `ImageProcessor`），再遍历 `PluginManager.messagePreprocessors` 执行其他插件。预处理器注册顺序由 `preprocessor_order.json` 中的已知顺序优先，未列出的插件按名称排序追加；当前保存顺序以 `VCPTavern → ImageProcessor → RAGDiaryPlugin → VCPTimeLine → OpenHerPersona → OneRing → ContextFoldingV2` 为主（`Plugin.js:802-880`, `preprocessor_order.json`）。因此插件可能修改原消息内容、插入消息，或仅挂载数组元数据。
8. 后置执行 Detector/SuperDetector；最后按开关运行 Role Divider。Role Divider 默认跳过第一个消息，识别 `ROLE_DIVIDE_*` 标签为新的 system/user/assistant 消息，并保护 `TOOL_REQUEST`、DailyNote 标记块不被拆开（`modules/chatCompletionHandler.js:1098-1121`, `modules/roleDivider.js:69-121`, `383-399`）。
9. 以处理后的 body 建立首次上游请求，并写入内存 `finalContextStore`。这个快照是**首次 fetch 前**的请求，不包含后续 VCP 工具递归回合；最多保留 5 组（`modules/chatCompletionHandler.js:1139-1150`, `modules/finalContextStore.js:21-23`, `288-300`）。

### 3. RAG、时间线与折叠在消息中的实际形态

这些能力不是独立的“会话消息表”，而是预处理器对本次数组的改写：

- `RAGDiaryPlugin` 只处理 system 或虚拟 system user 中的日记本/知识库占位符；查询向量来自最近真实 user 与最近 assistant 的加权内容，命中的召回结果替换占位符，必要时还会收集附件（`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1134-1219`, `1222-1240`, `1367-1403`）。
- `VCPTimeLine` 找到首个可信 system/系统前缀 user 中的时间线占位符，只接受一次声明，把时间线文本替换到该占位符，其余同名占位符清空（`Plugin/VCPTimeLine/VCPTimeLine.js:372-415`）。
- `ContextFoldingV2` 需要 system 中的激活占位符；它基于 assistant 历史块的深度、向量相似度和 FoldingStore，把低相关且已有摘要的 assistant 内容原地替换为摘要，未完成摘要则异步触发，开关本身从最终 system 文本删除（`Plugin/ContextFoldingV2/ContextFoldingV2.js:158-215`, `228-300`）。
- OneRing 会把触发器改成系统通知、按配置追加上下文/时间标记，并在数组上挂载 `__oneRingMeta`；后续产生新数组的阶段显式复制这份元数据（`Plugin/OneRing/OneRing.js:929-950`, `modules/chatCompletionHandler.js:259-279`）。

### 4. VCP 工具循环：模型上下文与前端显示分叉

首次上游返回后，流式和非流式 handler 都维护一份 `currentMessagesForLoop`，而不是修改客户端的原始会话。每一轮的核心结构是：

```text
处理后的历史
  -> assistant: 模型本轮正文（含 TOOL_REQUEST 标记）
  -> 执行 Archery/普通工具
  -> user: <!-- VCP_TOOL_PAYLOAD --> + 工具结果
  -> 再次 POST /v1/chat/completions
```

- `ToolCallParser` 先剥离 reasoning block，再解析纯文本工具标记；普通调用与 `archery` 调用分离（`modules/vcpLoop/toolCallParser.js:22-93`, `303-310`）。
- assistant 工具调用正文会追加到循环上下文；普通工具的 `result.content` 汇总后序列化为字符串 user payload，含图片时改用多模态数组并可再次经过图片翻译（`modules/handlers/streamHandler.js:429-441`, `579-688`; `modules/handlers/nonStreamHandler.js:421-434`, `444-518`）。
- Archery 成功结果默认不回送模型；只有 Archery 出错且没有普通调用时，错误内容才形成 `VCP_TOOL_PAYLOAD` 触发递归（`modules/handlers/streamHandler.js:492-560`; `modules/handlers/nonStreamHandler.js:351-416`）。
- `RAGMemoRefresh` 开启时，追加工具 payload 前会刷新历史中的 `VCP_RAG_BLOCK`，查询使用最近真实 user，而不是工具 payload（`modules/chatCompletionHandler.js:531-624`; 两个 handler 的 `RAG 刷新`段）。
- 循环最多由 `MaxVCPLoopStream/NonStream` 控制，默认回退 5；达到上限时流式返回 `finish_reason=length`，非流式也把最终 choice 标为 `length`（`modules/handlers/streamHandler.js:68-70`, `741-752`; `modules/handlers/nonStreamHandler.js:302-304`, `565-589`）。

### 5. 推理字段、VCP 信息与日志不是同一份消息

- 循环和 OneRing 只读取模型 `message.content`；stream handler 将 reasoning 字段另存于日志 message，不混入 `collectedContentThisTurn`，避免推理链进入工具解析与记忆（`modules/handlers/streamHandler.js:154-169`, `408-417`；非流式同样取 `message.content`，`modules/handlers/nonStreamHandler.js:269-300`）。
- 当模型匹配 reasoning 转正文配置时，发给客户端的 SSE/JSON 才会把 reasoning 包成 `<think>` 或 `<thinking>`；内部循环仍使用原始正文（`modules/reasoningContentAdapter.js:41-49`, `128-137`; `modules/handlers/streamHandler.js:172-217`; `modules/handlers/nonStreamHandler.js:272-285`, `565-577`）。
- `vcpInfoHandler.streamVcpInfo()` 产生的工具结果汇总、成功/失败摘要只写入客户端输出（流式 SSE 或非流式 `conversationHistoryForClient`）；模型下一轮读取的是独立的 `VCP_TOOL_PAYLOAD`。`SHOW_VCP_OUTPUT` 关闭时，`mark_history` 仍可强制显示单个调用（`modules/handlers/streamHandler.js:594-663`; `modules/handlers/nonStreamHandler.js:447-494`）。
- `CHAT_LOG_ENABLED` 打开时，`DebugLog/chat/YYYY-MM-DD/` 才异步写入初始请求、每轮 request/toolCalls/response；默认关闭，不构成会话持久化（`server.js:478-499`）。

### 6. 消息构建边界

已确认：VCPToolBox 在单次 HTTP 请求内拥有完整的“请求历史 → 最终上游 messages → 工具递归 messages”编排能力；它不拥有会话列表、消息编辑/删除/分支或跨请求恢复。`finalContextStore` 是调试快照，不是历史数据库；ChatLog 是可选审计文件，不是前端会话存储。外部 VCPChat、OpenWebUI 或其他客户端必须自行保存并在下一次请求中重新提交历史。

尚未验证：未运行真实上游模型，故没有对每个插件组合下的最终消息数组做运行时快照；`messagePreprocessors` 的未列入 `preprocessor_order.json` 插件顺序只能根据源码确认“按名称排序追加”，不能据此推断每个安装环境的完整实际列表。

## 与聊天相关的界面能力

### 1. AdminPanel-Vue：40 条路由里没有一条是会话/消息浏览器

`AdminPanel-Vue/src/app/routes/manifest.ts` 定义了完整路由清单（`APP_ROUTE_MANIFEST`，第 78-471 行），共 4 个导航分组：核心（core）、Agent & 内容（agentContent）、知识 & RAG（knowledge）、工具 & 插件（toolsPlugins）。逐一核对后，没有任何路由用于"发消息 / 浏览历史会话 / 编辑单条消息 / 会话搜索或归档"。唯二在名字上容易联想到"聊天"的两个视图，实测都是**只读审计工具**而非聊天界面：

- **`FinalContextViewer.vue`**（`/final-context-viewer`，`manifest.ts:139-148`）：展示"最后一次发给上游模型前的最终请求体"，页面文案自述"**不包含 AI 最终输出**"（`FinalContextViewer.vue:26`）。数据来自内存中最多 5 组滑窗快照（`modules/finalContextStore.js` 定义 `const MAX_SNAPSHOTS = 5;`），由 `modules/chatCompletionHandler.js:1142` 在每次真实 `/v1/chat/completions` 请求完成最终请求体合成后调用 `finalContextStore.setLastFinalContext(...)` 写入。页面本身**没有任何发送消息的输入框**，空态文案是"尚未捕获任何最终上下文。请先发起一次聊天请求。"（`FinalContextViewer.vue:504`）——即它是"事后调试镜像"，不是聊天窗口。它还带一个"池月1号"分析弹窗（`FinalContextViewer.vue:675-830`），用于对某条 AI 回复块做词项证据分布统计（BM25/TF-IDF 类分析），同样是离线可观测性工具而非交互功能。
- **`ToolCallRecordsManager.vue`**（`/tool-call-records-manager`，`manifest.ts:422-431`）：查询/清理插件调用记录数据库（后端 `modules/toolCallRecordStore.js` + `routes/admin/toolCallRecords.js`），提供按记录 ID、工具名、调用者、时间范围过滤的表格和详情弹窗（`ToolCallRecordsManager.vue:153-360`），"危险操作"区提供清理过期/清空全部记录（同文件 293-310 行）。这是插件调用审计台账，不涉及聊天消息本身的浏览或编辑。

### 2. 容易被误判为聊天 UI 的地方（专门核实的疑点）

- **`VcpAnimation.vue` 的"Nova"看板娘对话气泡**——这是最容易被误判为聊天窗口的组件。点击 Dashboard 侧边的 Nova 头像会弹出一个带头像+文字的气泡（`VcpAnimation.vue:14-42`：`aria-label="唤醒 Nova"`、`class="nova-maid-bubble"`），乍看像是"和 AI 聊天"。但实际机制是纯前端装饰：文案来自硬编码的静态语料数组 `NOVA_LINES`（约 30 条固定台词，`VcpAnimation.vue` 脚本区，例如"拓扑女仆 Nova 已上线：今日链路稳定，主人可以放心下达开发计划。"），点击后 `rerollNovaBubble()` 只是 `Math.floor(Math.random() * NOVA_LINES.length)` 随机选一条本地文案，**不发起任何网络请求**，5 秒后自动关闭（`NOVA_BUBBLE_AUTO_CLOSE_MS = 5000`）。表情图来自 `emojisApi.getGallery(...)` 拉取"Nova表情包"分类的静态图片。这是纯彩蛋/氛围装饰，与 AI 对话无关。
- **`ImmersiveCelestialPanel.vue`**：连续点击 Logo 5 次触发的"沉浸观星模式"彩蛋面板（`VcpAnimation.vue` 中 `EASTER_EGG_CLICKS = 5` 触发 `appStore.enterImmersiveMode()`），展示实时星轨数据和塔罗占卜卡片，属于审美装饰功能，不是对话界面。
- **`VcpForum.vue`**（VCP 论坛，`/vcp-forum`）：提供帖子列表/详情浏览、回复提交、删帖等管理操作（`VcpForum.vue:1-60`），页面自带提示："当前页面提供浏览、回复和管理操作；如需发帖，请使用论坛创建入口或 VCPForum 工具链"（`VcpForum.vue:11-13`）。这是 Agent 社区论坛的管理端，面向的是 Agent 之间的论坛帖子，不是人类与单个 Agent 的一对一聊天会话。
- **WebSocket `/vcp-admin-panel/VCP_Key=xxx` 通道**（`WebSocketServer.js:187` 路由正则，`WebSocketServer.js:977` `broadcastToAdminPanel` 函数）：这是一条真实的实时推送通道，但推送内容仅限管理事件，例如插件热重载通知 `{type: 'plugins-reloaded', message: ...}`（`Plugin.js:2041-2044`、`2150-2153`），不推送任何聊天消息内容，不能被误认为聊天流。

结论：AdminPanel-Vue 里所有看起来"像"聊天的元素，拆开机制后都不是真正的用户-AI 对话通道，而是审计视图、彩蛋装饰或论坛管理。

### 3. OpenWebUISub：第三方聊天前端的纯前端增强层

`OpenWebUISub/` 下三个脚本都是 Tampermonkey/Greasemonkey 用户脚本（`@match https://your.openwebui.url/*`），运行在浏览器里、注入到 OpenWebUI 这类第三方聊天页面，VCPToolBox 后端不感知它们的存在。三者机制如下：

**(a) `OpenWebUI VCP Tool Call Display Enhancer.user.js`（v3.9.8）——把协议文本渲染成卡片**

这是回答"工具调用结果如何进入第三方聊天 UI"的核心证据。机制分两层：

- 主引擎（针对被语法高亮包裹的 ` ```VCPToolCall ` 代码块）：用 `MutationObserver` 监视 CodeMirror 渲染出的 `.language-VCPToolCall` / `.language-DailyNote` 节点（`mount()` 函数，脚本 333-384 行），读取其文本内容，按 `<<<[TOOL_REQUEST]>>> ... <<<[END_TOOL_REQUEST]>>>` 或 `<<<DailyNoteStart>>> ... <<<DailyNoteEnd>>>` 标记切分，解析出 `tool_name:「始」PluginName「末」` 等 key/value（`renderToolCall()` 217-243 行、`renderDailyNote()` 245-305 行），再动态构建一个 `<div class="vcp-tool-card">` 表格卡片替换原始文本的显示，并把原始 CodeMirror 编辑器节点加上 `vcp-soft-hidden` 类隐藏掉（`mount()` 349-350 行）。
- 兜底引擎（针对没有被代码块包裹的裸文本）：用另一个全局 `MutationObserver` 扫描 `document.body` 文本节点，找到含 `<<<[TOOL_REQUEST]>>>` 的父节点，同样构建卡片并把原文本节点隐藏（`processTarget()` 550-595 行，`initFallback()` 597-661 行）。

关键点：**这一切都发生在浏览器 DOM 层，没有额外的网络请求**。卡片渲染完全基于 AI 回复文本里字面出现的协议标记字符串。这些标记为什么会出现在聊天消息文本里？因为 VCP 工具调用走的是"纯文本标记协议"而非原生 Function Calling（README.md:170："工具调用走纯文本标记协议，任何能输出文本的模型都能用，不依赖原生 Function Calling"）。具体到后端：
- AI 输出中直接包含 `<<<[TOOL_REQUEST]>>>...<<<[END_TOOL_REQUEST]>>>` 文本（这是模型自己生成的，用于声明要调用哪个工具）；
- 工具执行完成后，`vcpInfoHandler.js` 把插件返回结果格式化成一段可读文本块并**以 SSE chunk 的形式直接写回同一条聊天流**：
  ```js
  // vcpInfoHandler.js:96-104
  function formatVcpInfoToText(toolName, status, pluginResult) {
      const readableContent = extractReadableText(pluginResult);
      const statusIcon = status === 'success' ? '✅' : '❌';
      const textBlock = `[[VCP调用结果信息汇总:\n- 工具名称: ${toolName}\n- 执行状态: ${statusIcon} ${status.toUpperCase()}\n- 返回内容: ${readableContent}\nVCP调用结果结束]]`;
      return `\n${textBlock}\n`;
  }
  ```
  `streamVcpInfo()`（`vcpInfoHandler.js:117-154`）把这段文本包装成标准 OpenAI 风格的 `chat.completion.chunk` SSE 负载写入 `responseStream`，被 `modules/chatCompletionHandler.js` 在处理 `/v1/chat/completions` 时调用（`chatCompletionHandler.js:3` 引入 `vcpInfoHandler`）。也就是说，工具调用结果本质上是**assistant 消息正文里的一段格式化纯文本**，随聊天 SSE 流原样送到任何消费这个 API 的前端（OpenWebUI、VCPChat 等）。OpenWebUISub 脚本要做的事，只是在浏览器里把这段已经渲染出来的原始文本"美化"成卡片，不涉及第二次网络访问、不修改后端行为。

**(b) `OpenWebUI Force HTML Image Renderer with Lightbox.user.js`（v6.0.0）**：修正 AI 输出内容里 `/images/...` 图片 URL（自动补全 `BASE_URL` 与鉴权 Key，`fixVcpUrl()` 函数），并附加缩放/平移灯箱效果。同样是纯前端 DOM 处理，不涉及新的后端交互，只是让已经存在于消息文本里的图片链接能正常显示、能点击放大。

**(c) `VCP_DailyNote_SidePanel.user.js`（v0.2.1）——"特洛伊木马"式 iframe 注入，是三者中唯一真正发起跨域网络请求的**：

这个脚本不是渲染聊天消息本身，而是在宿主聊天页面右侧挂一个独立的侧边栏面板（宽度 260px，脚本 197-282 行 `initUI()`），展示的是 VCPToolBox 后端的"日记本"（DailyNote）管理界面（对应后端 `Plugin/DailyNotePanel/` 插件）。机制：

1. 用 `GM_xmlhttpRequest` 下载 `PANEL_URL`（即后端 `/AdminPanel/DailyNotePanel/` 页面）的 HTML/CSS/JS 三份静态资源（脚本 100-119 行 `download()`）；
2. 把下载到的 `index.html` 的 `<body>` 内容、内联 CSS、内联 JS 拼装成一份完整 HTML 字符串，通过 `<iframe srcdoc="...">` 注入（脚本 131-193 行"组装特洛伊木马 HTML"）；
3. 在 iframe 内部注入劫持代码，把 `window.fetch` 重写为调用 `window.parent.__VCP_FETCH_PROXY__`（脚本 153-164 行），而这个代理函数挂在宿主页面的 `unsafeWindow` 上，内部再用 `GM_xmlhttpRequest` 附带 `Authorization: Basic ...`（脚本硬编码的 `AUTH_USER`/`AUTH_PASS`）发起真正的跨域请求，从而绕过浏览器同源策略去访问 VCPToolBox 后端的 `/AdminPanel/dailynote_api/*` 接口（对应后端路由：`Plugin/DailyNotePanel/index.js:191` 挂载静态资源、`:219` 挂载 `dailyNotesRoutes`，前端脚本 `Plugin/DailyNotePanel/frontend/script.js:2` `const API_BASE = '/AdminPanel/dailynote_api'`）。

这是 OpenWebUISub 中唯一"服务器有对应后端路由被脚本反复调用"的情况，但被调用的后端（DailyNotePanel）本身就是 AdminPanel 生态下的一个笔记管理插件，与聊天消息流无关——它只是被"嫁接"到了聊天页面的侧边栏里，方便用户在聊天时随手翻阅 AI 的日记，不读取、不修改聊天消息本身。

**综合结论**：OpenWebUISub 三个脚本没有一个是"独立会话管理器"，全部运行在浏览器脚本引擎里，或者是纯 DOM 渲染层（(a)(b)），或者是通过 iframe+代理把 VCPToolBox 已有的后台页面"借用"进聊天页面侧边栏（(c)）。VCPToolBox 后端代码里搜不到任何专门为 OpenWebUISub 服务的路由（它们调用的 `/AdminPanel/dailynote_api`、`/AdminPanel/*` 静态资源、`/images/*` 都是本来就存在、服务于 AdminPanel/图片子系统的通用接口）。

## 与 Agent 的联系

AdminPanel-Vue 的"Agent & 内容"分组（`manifest.ts` 中 `navGroup: "agentContent"`）集中了对 VCPChat 等聊天前端体验起决定作用的后台配置面：

- `AgentFilesEditor.vue`（Agent 管理器）、`AgentAssistantConfig.vue`（Agent 通讯配置，对应 `docs/AGENT_AND_TASK_SYSTEM_GUIDE.md` §2 描述的 AgentAssistant 模块，API 基础路径 `/admin_api/agent-assistant`，支持热重载 `agents` 映射表和 `maxHistoryRounds` 而不需要重启服务）；
- `ForumAssistantConfig.vue`（任务派发中心，对应同文档 §3 的 TaskAssistant 模块，API `/admin_api/task-assistant`，支持论坛巡航 `forum_patrol` 和通用提示词任务 `custom_prompt` 两类定时任务）；
- `AgentEmotionManager.vue`（OpenHerPersona 情绪轴体观测器，页面自述"当前版本为纯异步观察器，不注入提示词"）；
- `AgentScores.vue`、`DreamManager.vue`（梦境操作审批，"在梦境操作触及日记文件前进行审核"）、`ScheduleManager.vue`、`ClawMailManager.vue`（Agent 信箱）、`AgentTimeLineManager.vue`（长期时间线摘要，写入 `dailynote/<Agent>timeline/YYYY-MM.md`）、`OneRingManager.vue`、`VcptavernEditor.vue`（VCPTavern 上下文注入预设编辑器，后端 `Plugin/VCPTavern/VCPTavern.js`）、`BridgeHijackConfig.vue`（VCPBridgeServer 的 System Prompt 劫持代理配置，让任意下游 CLI/客户端复用同一套人格提示词）。

这些配置项直接决定了通过 `/v1/chat/completions` 等端点接入的任意聊天前端（VCPChat、OpenWebUI 等）看到的 Agent 人格、记忆窗口、工具权限与主动任务行为，但 AdminPanel-Vue 本身不参与具体某一条聊天消息的收发。更详细的权限/工具边界结论请参见 `项目调查笔记/Agent工具`。

## 主要依据

- `README.md`（定位与前端生态描述，17/170/175/219/239 行）
- `docs/FRONTEND_COMPONENTS.md`（历史文档，描述已过时的原生 JS AdminPanel，仅作对照）
- `docs/AGENT_AND_TASK_SYSTEM_GUIDE.md`（AgentAssistant / TaskAssistant 技术文档）
- `server.js`（829-847 行 `/AdminPanel` 重定向逻辑；1206/1220/1235/1239 行聊天相关端点）
- `adminServer.js`（1-30 行独立进程说明；190-193 行 Vue 构建产物静态托管）
- `AdminPanel-Vue/src/app/routes/manifest.ts`（40 条路由全清单）
- `AdminPanel-Vue/src/views/FinalContextViewer.vue`、`ToolCallRecordsManager.vue`、`VcpForum.vue`
- `AdminPanel-Vue/src/components/dashboard/VcpAnimation.vue`（Nova 彩蛋气泡）
- `modules/finalContextStore.js`、`modules/chatCompletionHandler.js:1142`
- `vcpInfoHandler.js`（VCP 工具调用结果如何写回聊天 SSE 流）
- `OpenWebUISub/VCP_DailyNote_SidePanel.user.js`
- `OpenWebUISub/OpenWebUI VCP Tool Call Display Enhancer.user.js`
- `OpenWebUISub/OpenWebUI Force HTML Image Renderer with Lightbox.user.js`
- `Plugin/DailyNotePanel/index.js`、`Plugin/DailyNotePanel/frontend/script.js`

## 调查中澄清的几个关键点

1. `docs/FRONTEND_COMPONENTS.md` 描述的原生 JS AdminPanel 已过时，当前实现是 AdminPanel-Vue（独立 Vue SPA，构建产物由 `adminServer.js` 独立进程托管在 `PORT+1`）。
2. AdminPanel-Vue 与聊天主链**物理解耦**，有明确的架构证据支撑（独立进程、302 重定向），不只是笼统的"管理界面"。
3. 专门核实了"容易被误判为聊天 UI"的三个具体组件（Nova 彩蛋气泡、FinalContextViewer、VcpForum），逐一用代码证据说明它们为什么不是聊天界面。
4. OpenWebUISub 的机制拆解为三份脚本各自的具体实现（DOM MutationObserver 卡片渲染 / URL 修复 / iframe+fetch 代理注入），并补上了"VCP 工具调用结果为何会以文本形式出现在聊天消息里"的后端证据链（`vcpInfoHandler.js` 把结果格式化后作为 SSE chunk 写入聊天流），把前后端串成一条完整因果链。
