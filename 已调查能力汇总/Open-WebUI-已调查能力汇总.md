# Open WebUI 已调查能力汇总

> 汇总对象：`Open WebUI`（远端仓库 `https://github.com/open-webui/open-webui`，单仓，代码快照 `d3e8bf3405e848cfba377814d0aa7ba7290e414d` / main）
>
> 汇总更新日期：2026-08-27
>
> 依据：13 份来源笔记，覆盖 Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时；横向对比文档不在本次汇总范围
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题聚类合并重复能力，保留证据状态并链接来源，不新增源码验证
>
> 汇总范围：全部 13 个类目笔记的结论；仓库分布与应用界面基础设施两个工程/基建向类目单列小节，不与功能能力混排
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Open WebUI 是 Python 后端（FastAPI + Socket.IO）与 Svelte 前端（SvelteKit SPA）合仓的 Web 聊天与协作平台，不内置模型推理，上游为 openai/ollama/pipe。核心特征：会话采用「history JSON 快照 + chat_message 消息表」双写、流式推送全程走 Socket.IO、多模型并行（MoA / side-by-side）内建、54 个内置工具按条件注入、代码解释器与 Artifact 沙箱；平台面另有 Channels、Notes、Persistent Memory、Calendar、Automations、Arena/ELO 等协作与产品能力。13 份类目笔记全部为静态源码调查，结论以当前代码快照为限。

## 完成度速览

- 主链确认：6 项（Channels、Notes、Persistent Memory、Calendar、Automations、模型 Arena/ELO）
- 入口确认：4 项（语音/视频通话模式、企业身份、云文件、多节点运行）
- 静态源码确认：36 项（角色与上下文、会话与消息、生成与创作、Agent 运行时、渠道与调度五类标准条目）
- 归并已有类目：8 项
- 声明不符：1 项（Artifact KV）
- 暂缓：1 组（伴生仓库）

异常项（声明不符 1 + 暂缓 1 组）共 2 处，占全部条目的约 4%；其余功能能力均以主链确认或静态源码确认为交付态。

> 口径说明：本汇总所有「主链确认 / 静态源码确认」均基于对当前代码快照的源码贯通，在编译型桌面应用或完整本地主链中视为完成交付态；「未运行验证」仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。各能力卡与条目的完整机制、状态与边界细节留在来源笔记，本文件只作检索入口。

## 功能能力摘要

- **服务端工具审批与代码解释器**：聊天参数可选择完整访问或逐次确认；逐次确认时服务端持久化首个待执行调用并使其余调用排队，用户决议后沿原会话参数恢复。代码解释器则按 legacy XML 标签或原生 function-calling 两条入口受功能开关、模型能力和用户权限共同门控。证据状态：静态源码确认。来源：[Agent工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md)。

### 角色与上下文

- **自定义模型（Agent 角色 / Persona）载体**：没有独立 persona 实体，载体是 Workspace Models——一个模型条目 = 上游基础模型 + system prompt + 推理参数 + 知识引用 + 工具/技能/过滤器绑定 + 访问授权；分 Override（覆盖型）与 Preset（预设型）两种形态，id 为用户名的 slug 化（无 `user/modelid` 前缀），参数一律存 DB 由服务端合并应用。证据状态：静态源码确认。来源：[Agent 角色配置调查笔记](../Agent角色/Open-WebUI-Agent角色配置调查笔记.md)

- **参数双层合并与路由层注入**：请求侧按「全局默认 < 模型 params < 请求 params」三层合并；真正的 persona 注入在路由层——openai/ollama 端点各自按 `model_id` 重新读 DB 后应用参数与 system prompt，权威来源是 DB 而非前端缓存。证据状态：静态源码确认。来源：[Agent 角色配置调查笔记](../Agent角色/Open-WebUI-Agent角色配置调查笔记.md)

- **System prompt 处理**：`params.system` 支持变量模板（聊天变量、用户变量、元数据变量、旧式 `{{ }}` 四段渲染），出站时前置拼接到已有 system message 之前，实现「模型人设 + 聊天级 system」并存；Ollama 侧 system 落在 options 里时提升为根级字段。证据状态：静态源码确认。来源：[Agent 角色配置调查笔记](../Agent角色/Open-WebUI-Agent角色配置调查笔记.md)

- **上下文来源与拼装管线**：`process_chat_payload` 按固定顺序执行外部能力注入（Pipeline Inlet → Filter Inlet → Chat Memory → Web Search → Image Gen → Code Interpreter → Tools Function Calling → Files）；持久会话历史由后端从 DB 加载（优先消息表行以保留结构化 output，续写时额外加载被续写消息），图片文件转 `image_url` content part。证据状态：静态源码确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **上下文压缩**：请求携带 `compact_token_threshold`，`process_chat_payload` 内按需压缩、超过阈值生成 `[CONVERSATION SUMMARY]` 系统消息追加，失败回退全量历史；手动压缩经 `POST /{id}/compact` 写 `context_summary` 检查点并发事件。证据状态：静态源码确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **知识注入双模式**：legacy 模式把模型 `meta.knowledge` 展开成 files 做 RAG；native FC 模式走内置工具 `query_knowledge_files`；`get_attached_knowledge` 汇总模型、聊天、笔记三处知识。证据状态：静态源码确认。来源：[Agent 角色配置调查笔记](../Agent角色/Open-WebUI-Agent角色配置调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

### 会话与消息

- **history JSON 快照 + 消息表双写**：每条消息同时存在于 `chat.chat.history` 快照与 `chat_message` 行，前端展示以快照为主（O(1)），增量同步/统计/恢复读消息表；`reconcile_messages_by_chat_id` 单向对齐（快照→表、best-effort），消息表缺失可回退旧版 JSON blob 并自愈回填。证据状态：静态源码确认。来源：[Chat 调查笔记](../Chat/Open-WebUI-Chat调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)

- **消息树数据模型**：消息以 `{chat_id}-{message_id}` 复合键存储，`parentId`/`childrenIds` 构成消息树、`modelIdx` 保留多模型列序；编辑/删除粒度到单条消息，删除消息的孙节点重挂到父节点；会话更新用 `merge_history` 只合并不推断删除。证据状态：静态源码确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)

- **会话 CRUD 与生命周期**：聊天消息的增删改查全部集中在 `routers/chats.py`（无独立 messages 路由）；提供建会话、分叉（fork 建新会话）、克隆、归档、压缩、标签、未读、导入导出等端点；`meta.internal=True` 的内部会话（如子代理）不出现在普通列表。证据状态：静态源码确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)

- **列表、分页、搜索与未读**：会话列表 60 条/页分页，支持 pinned/folders/三种排序；搜索支持 `tag:`/`folder:`/`pinned:`/`archived:`/`shared:` 前缀过滤与标题/消息内容全文匹配（SQLite 用 `json_each`）；未读排序由 `ChatMessage.done=False` 子查询加 `last_read_at` 差值计算。证据状态：静态源码确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)

- **生成主链与多模型 fan-out**：`POST /api/chat/completions` → `process_chat_payload` → 上游模型 → 流式/非流式响应处理器；多模型并行以 `asyncio.Task` 逐个 fan-out（仅 idx==0 携带标题/标签任务），任务注册进 Redis（哈希 + pubsub stop 命令）实现多实例协调。证据状态：静态源码确认。来源：[Chat 调查笔记](../Chat/Open-WebUI-Chat调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **Socket.IO 流式通道**：流式推送统一走 `events` 事件（发射到 `user:{user_id}` 房间），前端按 `data.type` 分发约 25 种消息类型；REST 只负责发起与终止任务；Direct Connection 是唯一保留 HTTP SSE 出口的路径。证据状态：静态源码确认。来源：[Chat 调查笔记](../Chat/Open-WebUI-Chat调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **停止、重试、续写与重新生成**：停止链路为前端 `stopResponse` → `stopTasksByChatId` → Redis pubsub 广播 stop → 各实例本地 `task.cancel()`；重新生成是纯前端实现（复用父消息 id 生成新 uuid 的兄弟分支）；续写传 `assistant_message_id` 由后端加载原回复续写；MoA 合并走独立的 HTTP fetch 流（非 Socket.IO），结果写入 `message.merged`。证据状态：静态源码确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **提交队列与并发**：前端 `chatRequestQueues` store + `processNextInQueue` 按会话串行化提交（合并 prompt 与文件后一次性发送），不同会话并行；任务系统是「asyncio + Redis 记账」而非任务队列，任务不跨 worker 迁移。证据状态：静态源码确认。来源：[Chat UI 调查笔记](<../Chat UI/Open-WebUI-ChatUI调查笔记.md>)、[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **后台任务**：`background_tasks_handler` 在生成结束后串行执行四类任务——追问建议、标题生成、标签生成、记忆抽取；outlet 过滤器已内联执行（`POST /api/chat/completed` 标记 Deprecated）。证据状态：静态源码确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)

- **Chat UI 工作台**：会话状态机整体内聚在 `Chat.svelte`（约 4205 行）；右侧面板 Overview 把整个消息树渲染为只读 SvelteFlow 节点图，点击节点切换 `history.currentId` 分支指针；Composer 输入区支持 `@` 提及、`/` 命令、语音听写、粘贴/拖放上传与 `largeTextAsFile`；支持 embedded 内嵌聊天模式。证据状态：静态源码确认。来源：[Chat UI 调查笔记](<../Chat UI/Open-WebUI-ChatUI调查笔记.md>)

- **对话导出与分享**：两条独立主链——本地下载（JSON / TXT / PDF 样式化与纯文本双模式，PDF 由 html2canvas-pro + jsPDF 客户端生成）与站内链接分享（`/s/{share_id}` 快照页，private/public/open 三态由 `access_grants` 决定，open 允许匿名）；社区分享是纯前端 `postMessage` 交接给 openwebui.com；全量 JSON 导出可经 DataControls 导入往返。证据状态：静态源码确认。来源：[对话导出与分享调查笔记](../对话导出与分享/Open-WebUI-对话导出与分享调查笔记.md)

- **事件源体系**：所有会话/消息变更经 `publish_event` 发审计/webhook 事件（`EVENTS.CHAT_*`/`EVENTS.MESSAGE_*`），与 Socket.IO 前端事件是两套独立通道。证据状态：静态源码确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)

### 生成与创作

- **消息渲染管线**：采用「marked lexer 出 token 树 + Svelte 组件逐个渲染 token」而非 marked 官方 HTML 字符串输出；扩展全部自制（`<details>` 块、KaTeX、引用 `[n]`、脚注、`:::` 冒号围栏、提及）；HTML token 一律先 DOMPurify 消毒，Mermaid/vega SVG 再经白名单清洗。证据状态：静态源码确认。来源：[消息渲染器调查笔记](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md)

- **流式渲染优化**：`content` 变化时 rAF 节流合并一次 lexer 解析，`done` 时立即处理并取消残留帧；`{#key id}` + `TextToken` 复用避免整棵树重建；消息列表用浏览器原生 `content-visibility: auto` 做离屏虚拟化（Safari 按 UA 剔除）。证据状态：静态源码确认。来源：[消息渲染器调查笔记](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md)

- **结构化输出**：`message.output` 存在时走 `StructuredOutputRenderer`，把工具调用 / reasoning / code_interpreter 归组为 detail 项与正文混排；渲染入口按 role 与父消息模型数分发到 User/Response/MultiResponse 组件。证据状态：静态源码确认。来源：[消息渲染器调查笔记](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md)

- **代码解释器（G3 主体）**：唯一具备完整「触发→执行→结果→展示→编辑→保存→重新打开→模型回流」生命周期的输出对象，载体是 Responses API 风格 `open_webui:code_interpreter` output item（持久化于 `ChatMessage.output`）；触发走私有 XML 标签协议，五重门控；执行循环最多 5 轮，结果就地写回同一 item 并回流模型续写。能力等级判定 G3 为主、兼具部分 G4（代码块编辑保存）与部分 G5（模型读写 `/mnt/uploads` 并就地更新）。证据状态：静态源码确认。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **Artifact（HTML/SVG 预览）**：由消息正文代码块探测派生（`getCodeBlockContents` 分组提取完整 HTML 文档），在聊天侧栏 iframe 预览（CSP 注入 + sandbox）；无独立对象身份、不可编辑、不可回流，关闭面板后内容仍是消息正文的一部分。证据状态：静态源码确认。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md)

- **Pyodide 文件系统与终端工作区**：Pyodide 是浏览器沙箱内会话级活文件系统（跨会话持久化默认关闭，`ENABLE_PYODIDE_FILE_PERSISTENCE` 控制）；终端工作区（文件浏览、notebook、端口预览、xterm）全部委托外部 Terminal 服务器，本仓只做代理。证据状态：静态源码确认。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md)

- **工具结果物化**：工具执行结果经 files / embeds / sources 三通道挂到消息 JSON 列——base64 图片拆成 `input_image` 供 LLM 消费、前端展示剥离并另附 user 消息；HTML 结果经 `tool_result_embeds` 直达前端 iframe 渲染。证据状态：静态源码确认。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

### Agent 运行时与外部协作

- **工具生态与注册**：工具统一注册成 `tools_dict`，三大来源——本地数据库工具（`get_tools`）、内置工具（`get_builtin_tools`）、外部 MCP/OpenAPI 工具服务器（`server:*` 前缀）；请求体显式携带 `tools` 键时完全跳过服务端解析；数据库工具按 `AccessGrants` 做访问授权。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **内置工具条件注入**：54 个内置工具按 16 个类别做四重开关检查——模型 meta 的 `builtinTools` 类别开关、全局配置、模型能力、用户权限，非全量暴露；另有 `kb_exec` 类 shell 命令工具把知识库当文件系统，受 `ENABLE_KB_EXEC` 控制。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **工具调用执行循环**：主循环在 `utils/middleware.py`（非路由层）——解析参数 → 执行（direct 工具推前端、普通工具绑定 `__messages__`/`__files__` 后 await）→ 处理结果 → 引用提取 → RAG 模板重写上下文 → 重新请求模型；参数校验是白名单过滤，多轮循环上限 `max_tool_call_iterations`；仅 6 类工具的结果提取引用来源。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **MCP 与外部工具服务器**：`connect_mcp_server` 做连接级访问授权、鉴权头组装（bearer/session/oauth）、streamablehttp + OAuth 建连后拉取工具清单；工具名统一 `{server_id}_{tool}`；MCP 客户端默认 `verify=False`；OpenAPI 服务器经 `execute_tool_server` HTTP 调用，函数名前缀防冲突。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **Filter / Pipeline 插件通道**：两条并行通道——本地函数插件按 inlet/stream/outlet handler 执行，远程 pipeline 服务器经 HTTP POST 到 `{url}/{filter_id}/filter/inlet|outlet`；执行顺序为 Pipeline Inlet → Filter Inlet → Chat Memory → Web Search → Image Gen → Code Interpreter → Tools Function Calling → Files；Valves 配置经 Fernet 加密存储（`WEBUI_SECRET_KEY` 派生密钥）。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **子代理（Sub-agents）**：内部 API 重入——`delegate_task` → 创建独立 chat（`internal_meta` type=subagent）→ 伪造带 `typ: 'subagent'` token 的内部请求 → 递归调用 `CHAT_COMPLETION_HANDLER`；后台模式用信号量限流；子代理内部禁用写类 memory 工具。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

- **前端工具 UI**：集成菜单在 `MessageInput/IntegrationsMenu.svelte` 的 Tools tab（非独立 Tools.svelte）；工作区管理页 `workspace/Tools.svelte` 负责上传/编辑/Valves；工具 ZIP 上传在本版本无 `/load/zip`，仅 `/load/url` 从 GitHub 拉取。证据状态：静态源码确认。来源：[Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)

### 渠道与调度

- **服务端 LLM 渠道配置**：OpenAI/Ollama 连接表示为配置行（URL + 按索引关联的配置对象，OpenAI 另有同索引 API Key），不是独立 Provider 实体；环境变量是启动种子默认值，运行时权威来源是数据库 `config` 表逐 key 存储；`config.json` 仅作旧版本迁移；管理员 Web Connections 支持查看、新增、编辑、启停、删除与连接测试，无复制/单条导入导出。证据状态：静态源码核对。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md)

- **用户 Direct Connections**：用户设置中的 OpenAI 兼容连接列表，由浏览器直连上游并直接测试（依赖上游 CORS），不进入服务端 Config 表；`ENABLE_DIRECT_CONNECTIONS` 总开关只决定能力开放，不提供 Ollama、服务端代理、管理员导入导出或跨用户共享。证据状态：静态源码核对。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md)

- **协议适配与模型目录**：统一入口按模型元数据选择 OpenAI 兼容 / Ollama / Azure / Anthropic / Responses 路径，Azure 改写部署路径与 API 版本；OpenAI 同名模型合并时固定首个连接的 `urlIdx`（无跨连接 failover），Ollama 同名模型随机选后端（是分摊不是故障转移）；未找到 LLM 调用级重试循环；`prefix_id` 防不同连接模型 ID 冲突。证据状态：静态源码核对。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md)

- **平台与入口矩阵**：管理员 Web Connections 与用户 Direct Connections 构成渠道管理的完整 Web 管理面——查看、新增、编辑、启停、删除、连接测试与通用配置 JSON 导入导出齐备；CLI 仅提供 `serve`/`dev`/`--version` 启动类命令、无渠道管理子命令，本仓库未找到 TUI；桌面端入口位于独立 `open-webui/desktop` 仓库。证据状态：静态源码核对；桌面端未验证，细节见末尾小节。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md)

### 独特与差异化能力

本小节保留独特功能笔记的能力卡标题与证据状态（沿用独特功能类目指南定义）。下列 6 项为 `主链确认`；语音/视频通话模式、企业身份、云文件、多节点运行 4 项 `入口确认` 与 Artifact KV `声明不符`、伴生仓库 `暂缓` 已移至末尾「已知边界与待验证事项」。

- **能力一：Channels（实时协作空间 + 模型参与）— `主链确认`**：群组/DM/公告三类频道 + 线程/反应/置顶/文件/Webhook 入站；模型被 `@` 或回复触发后以完整 `CHAT_COMPLETION_HANDLER` 管线参与回复，模型回复以模型身份落库。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

- **能力二：Notes（独立文档工作区）— `主链确认`**：笔记 ↔ 隐藏聊天双向绑定（`GET /notes/{id}/chat` 建立 internal 隐藏聊天，模型经 view_note/write_note/replace_note_content 工具直接改写）；Yjs 实时协作经 Redis `YdocManager` 同步；模型编辑受工具权限与聊天权限双闸。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

- **能力三：Persistent Memory（跨会话记忆）— `主链确认`**：手动、工具、后台复盘三条写入通道 + 每轮请求前向量检索注入（`user-memory-{user.id}` 集合）；后台复盘每 10 轮（默认）用独立 LLM 请求决定 add/replace/move/remove，失败不阻断聊天；记忆是「用户事实 + 路径组织 + 向量检索」的服务端闭环。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

- **能力四：Calendar（个人/共享日历 + 模型调度面）— `主链确认`**：calendar / calendar_event / calendar_event_attendee 三表，事件带 rrule、颜色、提醒与 RSVP；模型经内置日历工具直接查询/创建/更新日程；提醒由调度器循环轮询后经通知系统推送。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

- **能力五：Automations（定时 prompt 自动化）— `主链确认`**：rrule 定时 prompt 调度 + 后台无头执行 + 真实聊天产物 + 运行记录回填（`automation`/`automation_run` 两表）；`scheduler_worker_loop` 原子认领到期任务（限额 + 随机抖动防多实例抢跑）；结果可回链、可手动立即执行、可停用删除。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

- **能力六：模型 Arena / ELO 评估 — `主链确认`**：用户反馈（rating 1/-1 + 兄弟模型 + 标签）落 `feedback` 表，排行榜实时计算 Elo（初始 1000、K=32），带 query 时用 sentence-transformers 对标签做余弦相似度加权；仅 admin 可见，无缓存表。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

**归并已有类目项**：

- 模型/Agent（workspace models、persona、知识库绑定）——已归并到 Agent 角色笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- 工具/Filter/Pipeline/MCP/子 Agent——已归并到 Agent 工具笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- 代码执行（Pyodide/Jupyter）与 Artifact 沙箱——已归并到生成式输出与运行时笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- RAG/知识库/检索——已归并到现有 RAG 相关笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- 多模型对话、MoA、消息 fan-out——已归并到对话请求与上下文笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- 会话/消息双写、channel 之外的消息模型——已归并到会话与消息管理笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- 富文本渲染、Markdown、Citations——已归并到消息渲染器笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- LLM 渠道与 Provider 适配——已归并到 LLM 渠道管理笔记。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

独特功能笔记建议将 Channels、Notes、Persistent Memory、Calendar、Automations、模型 Arena/ELO 六项计入特色功能贡献统计（标签：协同工作区、记忆演化、主动 Agent、模型评估产品面），详见[特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 工程与基础设施摘要

- **仓库分布**：Python 后端 + Svelte 前端合仓的 Web 应用；5,031 个 Git 跟踪文件中 3,870 个位于 `static`（总文件数主要反映静态资源规模），可识别源码 1,011 文件 / 346,049 行，集中在 `backend/open_webui`（196,710 行）与 `src/lib`（141,095 行）；仓内显式测试资产很少（仅 2 个测试文件），完整用户文档不在当前 docs 目录展开；产品经 pip、Docker、Kubernetes 运行，原生桌面应用位于独立仓库（`open-webui/desktop`），本仓不含其平台代码。来源：[仓库分布调查笔记](../仓库分布/Open-WebUI-仓库分布调查笔记.md)

- **应用界面基础设施**：关闭 SSR 的 SvelteKit SPA（Svelte 5 框架 + Svelte 4 风格组件主体）、Tailwind CSS v4，无 UI 组件库——公共组件在 common 目录（53 个文件，Modal/ConfirmDialog/Drawer/Dropdown/Tooltip 等均自研）；Modal 负责 Portal、焦点陷阱、Esc、遮罩与滚动锁定，弹窗层级是「最后挂载者优先」而非 z-index 栈，全应用无自绘右键菜单；Toast 统一用 svelte-sonner，聊天完成等站内通知还旁路浏览器 Notification 与 webhook；主题以设备 localStorage 为权威（首屏内联脚本防 FOUC），聊天背景图却是账户级设置（文件夹 / 用户 / 许可三级优先级）；另有 24 项快捷键注册表、13+16 tab 设置框架、桌面壳（独立仓库）经 `window.electronAPI`/`window.applyTheme` 钩子接入。来源：[应用界面基础设施调查笔记](../应用界面基础设施/Open-WebUI-应用界面基础设施调查笔记.md)

## 已知边界与待验证事项

### 声明不符

- **Artifact KV（`声明不符`，按当前快照）**：README 宣称的「built-in key-value storage API for artifacts」在 routers/models/utils/tools 中未找到对应执行入口，语义最接近的是 channel 消息 / calendar / note 的 data 字段与聊天任务清单，不能据此计数；结论基于当前快照静态搜索，需在新快照复查。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

### 暂缓与外部依赖

- **伴生仓库（`暂缓`）**：Open WebUI Computer、Open Terminal/Terminals、oikb、桌面 App 属本仓库主链之外，本仓内的 `/terminals` 前端与 `routers/terminals.py` 仅代理外部 terminal server；Analytics/用量为管理面板常规能力，不在待查清单。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- **桌面端（`未验证`）**：独立 `open-webui/desktop` 仓库不在调查范围，桌面端连接管理、导入导出与多服务器切换不能从本仓库推断；本仓库 CHANGELOG 仅确认存在可运行本地实例或连接远程实例的原生桌面应用。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md)

### 入口确认（主链未闭合）

- **语音/视频通话模式（CallOverlay，`入口确认`）**：输入栏通话浮层实现单用户免提模式——麦克风录制转写进聊天、模型回复 TTS 朗读、摄像头截帧作附件；README 用语比实现更宽，不是 WebRTC 点对点通话；浏览器媒体权限流程与 STT/TTS 引擎接入未运行验证。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- **企业身份（`入口确认`）**：LDAP 登录链、OAuth 多 provider 管理与会话、SCIM 2.0 端点（文件头自述 experimental、可能不完全合规）均有路由入口；真实目录接入与 SCIM 合规性未验证。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- **云文件集成（`入口确认`）**：Google Drive / OneDrive 前端 picker 弹窗流可把云端文件导入文件库供聊天/RAG 使用；后端无独立云文件代理路由，主链后半段归并现有 files 体系；真实 OAuth 流程与文件回流未验证。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- **多节点运行（`入口确认`，工程机制）**：`WEBSOCKET_MANAGER='redis'` 启用 AsyncRedisManager 跨节点广播与 RedisDict/RedisLock/YdocManager 三类支撑；多节点真实部署未验证，不进特色贡献计数。来源：[独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)

### 未覆盖类目

- 频道消息（channel 体系，与聊天消息物理隔离）、Ydoc 协作、Direct Connection 客户端内部实现已在相关笔记明确排除。
- Chat UI 笔记对频道与 Direct Connection 的界面形态未调查；会话与消息管理笔记对多实例并发一致性、`json_each` 大表搜索性能未验证。

### 共性未验证

- 13 份笔记全部为静态源码调查、未运行服务：socket 实时推送、模型在频道/笔记中的流式参与、记忆后台复盘的真实模型调用、自动化定时触发与多实例并发认领、ELO 加权查询、STT/TTS 引擎接入、LDAP/SCIM 真实接入、云文件 OAuth 流、Redis 多节点部署、PDF 实际渲染效果、/s 分享页三态端到端行为均未验证。
- 多实例并发写入时 history 快照与消息表的最终一致性、Overview 消息树图超大树渲染性能、键盘焦点顺序与响应式断点行为等运行项未验证。
- 配置导入导出与连接管理结论来自静态请求路径，实际部署中的数据库加密、备份保护与日志凭据排除未验证。
- 长上下文压缩触发阈值下的实际行为、同一会话多标签页并发提交的队列行为未验证。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/Open-WebUI-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/Open-WebUI-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/Open-WebUI-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/Open-WebUI-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/Open-WebUI-对话导出与分享调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/Open-WebUI-应用界面基础设施调查笔记.md)
- [消息渲染器调查笔记](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md)
- [独特功能调查笔记](../独特功能/Open-WebUI-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md)
