# Jan 已调查能力汇总

> 汇总对象：`Jan（本地路径 E:\works\git\jan）`
>
> 汇总更新日期：2026-08-18
>
> 依据：13 个类目笔记——Agent工具、Agent角色、Chat、Chat UI、LLM渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题归并重复能力，保留证据状态并链接来源；未新增源码调查
>
> 汇总范围：覆盖上述 13 类目；`仓库分布`、`应用界面基础设施` 结论单列工程小节；不做跨项目横向比较
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Jan 是本地优先的 AI 桌面客户端：Tauri 桌面 + Web + Android/iOS 多表面，无后端聊天业务服务，React 前端（web-app）经 AI SDK 直连本地 llama-server / mlx-server 或远程 provider。工程形态为 Yarn workspaces monorepo，能力由 7 个可插拔扩展提供。已调查 13 个类目，功能主体为聊天、工具、角色、渠道与本地推理服务，区别于一般 Chat UI 的独特面在于"本地推理器设备级管理 + 服务端 MCP 编排 + CLI 与外部 Agent 预接"。

## 完成度速览

- 主链确认：4 项（能力一~四，源码贯通主链）
- 入口确认：1 项（Project 工作流，主链未完整走通）
- 归并已有类目：7 项（能力并入既有类目，不重复计数）
- 声明不符：1 项（本地↔云模型级 failover）
- 暂缓：1 项（Project 提案暂缓）
- 外部依赖：1 项（BrowserMCP 伴生扩展）

合计 15 项证据状态条目；非完全闭合项 4 项（声明不符、暂缓、外部依赖、入口确认未闭合）约占 27%，其余约 73% 为已确认正面结论。

**口径说明**：本汇总所有"主链确认 / 静态源码确认"均基于对当前代码快照的源码贯通，在编译型桌面应用或完整本地主链中视为完成交付态；"未运行验证"仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。异常项集中收录于文末"已知边界与待验证事项"小节。

## 功能能力摘要

### 角色与上下文

- **Assistant 角色实体与持久化**：每个助手一个目录一个 JSON 文件（`assistant.json`），assistant-extension 负责增删改查与 v1–v3 版本迁移；core 与 web 两侧类型字段定义不一致（已确认事实，运行时影响未验证，见末尾小节）。[Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- **默认助手**：id 固定 `jan`、`model:'*'`、内置 `type:'retrieval'` 且 `enabled:false` 的工具声明；web 侧另有第二份独立默认助手表示（useAssistant + localStorage），与 core 侧互不共享。[Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- **线程绑定助手快照与 system prompt**：线程保存 `ThreadAssistantInfo` 嵌入快照而非引用，无助手时写 `model-only` 占位；systemMessage 由 `renderInstructions` 生成；消息不保存模型/参数元数据，重新生成不重读助手当前配置；无开场白、提示词为单段无分组。【代码确认】[Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- **指令模板与占位符**：支持 `{{current_date}}` 模板变量（UTC 长月份替换），无用户变量或场景变量系统。[Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- **上下文管理**：`max_context_tokens>0` 时按 `auto_compact` 选择模型摘要压缩或纯截断（失败回退截断）；`finishReason==='length'` 且 token 达上下文 0.9 倍时冻结部分消息并提示手动扩容，阶梯 `<8192→8192→32768→×1.5`（封顶默认 131072），扩容由用户手动触发，无自动扩容。【代码确认】[对话请求与上下文调查笔记](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)

### 会话与消息

- **持久化双后端**：桌面端每线程一个目录（`thread.json` + `messages.jsonl`，per-thread 锁 + 整文件重写）；移动端（iOS/Android）走 SQLite（JSON 列 + 外键级联删除）；Rust 线程创建用服务端 UUID 覆盖前端 id。【代码确认】[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **三 store 协作与乐观写**：useThreads / useMessages / useChatSessions 分工，`addMessage` 先入内存再按 id 替换；`$threadId.tsx` 是分支/编辑/续写/上下文扩展的数据仲裁中枢。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **UI↔持久化消息双向转换**：content 为结构化 parts（text/reasoning/image/audio/video/tool_call），双向转换兼容旧 `metadata.tool_calls` 与 ` thinking` 等历史包裹格式。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)、[消息渲染器调查笔记](../消息渲染器/Jan-消息渲染器调查笔记.md)
- **分支、编辑、续写模型**：`parentId` 树 + 活跃根 `activeRootId`（存线程 metadata，跨重启可恢复）+ `activeChildId`；编辑 `makeSibling` 产生纯文本新版（媒体丢失，原版本保留可回退）；续写 `planContinuation` 原地替换不 fork；`repairDetachedAssistants` 自愈旧版幽灵根缺陷。【代码确认】[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **删除与批量删除**：`deleteThread` 级联清理向量库集合与搜索索引；`deleteAllThreads` 保留收藏与带 project 的线程。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **列表、搜索、排序与自动标题**：按 `updated` 降序、Fzf 模糊搜索（懒建索引，排除临时线程）、自动标题按"每 4 条 assistant 消息"节拍触发。【代码确认】[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **发送队列**：发送时正在流式则入队，`ready` 状态自动发下一条，`error` 或离开线程清队列；`QueuedMessageChip` 显示在输入区顶部，点击可放回编辑。【代码确认】[对话请求与上下文调查笔记](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Jan-ChatUI调查笔记.md>)
- **现场恢复**：待发送初始消息经 `sessionStorage`（键 `initial-message-<threadId>`）恢复；活跃分支经线程 metadata 的 `activeRootId` 重建；`resume:false` 不恢复未完成回合。【代码确认】[Chat UI 调查笔记](<../Chat UI/Jan-ChatUI调查笔记.md>)
- **缓存一致性**：per-thread 锁串行化同一线程消息写；桌面 create 去重 + modify upsert、SQLite `INSERT OR IGNORE`/`ON CONFLICT DO UPDATE` 双层防重复。【代码确认】[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)

### 生成与创作

- **流式生成管线**：前端直连模型服务——AI SDK `useChat` + 自研 `CustomChatTransport`，`experimental_throttle:50` 只节流 UI 状态、`resume:false`；推理参数不经 AI SDK 层，由 `createCustomFetch` 注入 HTTP body；流式事件链含工具执行循环、用量收集与 metadata 回写。【代码确认】[对话请求与上下文调查笔记](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)、[Chat 调查笔记](../Chat/Jan-Chat调查笔记.md)
- **消息渲染**：React 组件 + AI SDK parts 结构化模型，正文按 `part.type` 分派；Markdown 以 Jan fork 的 streamdown 为核心（remark GFM/数学 + rehype KaTeX/harden 消毒）；流式期间有 `useDeferredValue` 合并 token、推迟 Shiki 高亮、memo 比较器等优化；引用经 `citation-parser` + grounding 句子级余弦校验。消息列表全量渲染、无窗口化。【代码确认】[消息渲染器调查笔记](../消息渲染器/Jan-消息渲染器调查笔记.md)
- **HTML/SVG Artifact 沙箱预览**：`归并已有类目`（消息渲染器 / 生成式输出与运行时）。设置项 `renderHtmlArtifacts` 默认关闭，把 html/svg 围栏从消息文本拆出，在严格 CSP + sandbox 不透明源 iframe 中运行，默认禁网、无 postMessage 宿主通道；渲染期从消息文本推导，无独立对象身份。【归并已有类目】[生成式输出与运行时调查笔记](../生成式输出与运行时/Jan-生成式输出与运行时调查笔记.md)
- **输出生命周期与能力等级**：模型输出以消息正文为主承载（主体 G1 富静态结果），HTML artifact 提供沙箱运行环境（G3 窄实现）；工具结果（Web 搜索/RAG/MCP）以只读卡片展示。[生成式输出与运行时调查笔记](../生成式输出与运行时/Jan-生成式输出与运行时调查笔记.md)
- **消息操作与版本导航**：编辑（纯文本替换、流式态禁用、Ctrl+Enter 保存）、删除、复制、Continue（仅末条且 `metadata.stopped`，原地续写）、Regenerate（仅末条，生成兄弟版本）、版本 `< n/m >` 切换器渲染在消息项操作区。【代码确认】[Chat UI 调查笔记](<../Chat UI/Jan-ChatUI调查笔记.md>)、[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)

### Agent 运行时与外部协作

- **工具体系：三类来源与加载注入**：Web 搜索（`web_search`/`web_fetch`）、RAG（`retrieve`/`list_attachments`/`get_chunks`，仅线程有文档且 RAG 可用时启用）、MCP 任意工具；仅 `selectedModel.capabilities` 含 `tools` 时经 `refreshTools` 加载，schema 经 `normalizeToolInputSchemaValue` 规整以对齐 Rust/GBNF（GBNF 编译失败会静默禁用工具 JSON，属边界行为）。【代码确认】[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)
- **工具执行链**：AI SDK `streamText` 原生 tool calling + `toolChoice:'auto'`；MCP 执行实体在 Rust 侧（`TauriMCPService` → `collect_mcp_tools` / `execute_mcp_tool_calls`），结果以 `tool-<name>` part 流回 UI；工具循环在 onFinish 串行执行并回填，RAG 工具 auto-allow、MCP/第三方走审批。[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)
- **工具权限与审批（四级）**：thread 级 / server 级 / 全局 / allow-all，`isToolApproved` 按 全局工具 > 全局 server > thread 级 判定；禁用列表用复合 key `${serverName}::${toolName}` 全局持久化；文档嵌入后自动审批 RAG 工具。【代码确认】[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)
- **工具渲染与引用**：`ToolCallCard` / `WebToolWidget` / `RagToolWidget` / `ChainOfThoughtGroup` 承载推理链与工具调用分组；web 引用行 + `#cite-`/`#webcite-` 锚点 + 句子级 grounding 校验。[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)、[消息渲染器调查笔记](../消息渲染器/Jan-消息渲染器调查笔记.md)
- **MCP 服务生命周期**：Rust 侧 `helpers.rs` 管理 MCP 进程——并行拉起、幂等启动保护、stdio/sse/http streamable 传输分区、Windows `CREATE_NO_WINDOW`、bun/uvx runtime 覆盖与系统回退、500ms 稳定性检查与 `tools/list` 可达性验证（最多 3 次）。【代码确认】[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)

（服务端 MCP 编排、Jan CLI 与外部 Agent 预接、MCP 智能工具路由为独特功能卡，见"独特与差异化能力"小节。）

### 渠道与调度

- **渠道双层结构**：远程 provider（11 个预定义 + 用户自定义 OpenAI 兼容端点，api_type 可选 openai/anthropic）+ 本地引擎（llamacpp / mlx 经 router 暴露为 OpenAI 兼容端点）；请求默认打到本地 router 代理，Rust 按模型 ID 决定转发远程 provider 或路由到子进程；无独立 Endpoint 子实体，同名 provider 不能并存。[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)
- **provider 管理与配置**：自定义 provider 支持新增、编辑、启停、删除与模型列表维护，创建时校验名称、URL 与协议类型；内置 provider 隐藏通用设置卡；llamacpp/MLX 作为本地引擎处理（停用 llamacpp 先停止全部模型）。[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)
- **API key 管理**：主 key + fallback 链（`api-key-fallbacks`），401/403/429 轮换重试；连接测试对 `/models` 发 GET 并同时发 `x-api-key` 与 `Authorization: Bearer` 双头；远程 secrets 只进 OS keyring（`set_secret`/`get_secret`），绝不明文写 settings.json。【代码确认】[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)
- **参数体系**：`predefinedParams.ts` 的 `ParamDef`（capability + 默认值 + disabledBy）为单一定义源；`providerCaps.ts` 能力表决定参数"转发/可能忽略/拒绝"，自定义 provider 落入全放行；wire 层按 `CLIENT_SIDE_PARAM_KEYS` / `LLAMACPP_ONLY_PARAM_KEYS` / `WIRE_KEY_REMAP` 三层过滤；OpenAI o 系与 grok 系列模型级拒绝采样参数；上游拒绝采样参数时自动去参重试一次。[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)
- **模型系统与下载链**：模型对象（ModelInfo/Model/Setting/Runtime 参数 + 默认 ctx/max_tokens）；catalog 与 `/models` 刷新 + 软删除 tombstone；下载支持断点续传、镜像前缀 + HMAC 签名、CancellationToken 取消；模型源按 `library_name` 过滤 mlx（非 macOS 隐藏）；llamacpp 每模型独立 `model.yml`、MTP/embedding 探测、600ms 防抖重启 router。【代码确认】[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)
- **本地 API server 代理**：`proxy.rs` 三路路由（云端 provider / MLX 会话 / llama.cpp router）；`proxy_api_key` 双头认证（Bearer / X-Api-Key，/configs 一律 404）；`converters.rs` 在 OpenAI/Anthropic/Gemini/OpenAI-Responses 间双向转换并流式转发；服务端工具执行受 `enable_server_tool_execution` 门控（默认 false）；工具 schema 规整对齐 GBNF（date/time format 与复杂 pattern 会被删）。【代码确认】[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)

（设备级本地推理器管理闭环为独特功能卡，见"独特与差异化能力"小节。）

### 独特与差异化能力

保留独特功能笔记的能力卡标题与证据状态，完整机制见来源笔记：

- **能力一：设备级本地推理器管理闭环 — `主链确认`**：管理"跑模型的引擎本身"而非只管理模型文件——按 OS/CPU 指令集/GPU 选 CUDA/Vulkan/CPU 后端、下载/升级/回滚 llama-server 二进制、单进程 Router 承载多模型、GPU 卸载校验与 fit 预测，形成"探测→推荐→预测→验证"闭环；后端目录保留两版本供回滚，`update_history.json` 记录更新，崩溃时 `adoptRouter` 收养孤儿进程。调查样本中未见同类实现，为独特功能主贡献候选。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)
- **能力二：`/v1/orchestrations` 服务端 MCP 编排 — `主链确认`**：把 MCP 工具执行循环暴露为 HTTP 服务——外部客户端提交请求后，服务端加载 assistant 系统提示 → 模型出 tool_calls → 进程内执行 MCP 工具 → 循环至完成并返回聚合响应；`stream=true` 不支持，外部输入按请求处理，权限沿用 MCP 既有执行域。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Jan-外部执行体与应用协作调查笔记.md)
- **能力三：Jan CLI 与外部 Agent 预接 — `主链确认`**：`jan serve` / `jan launch claude|openclaw` / `jan threads` / `jan models` 打通桌面数据目录、终端与外部 Agent CLI 三面；`launch claude` 默认按显存自动配上下文的 `--fit` 并以环境变量指向本地端点，`launch openclaw` 写入/合并 `~/.openclaw/openclaw.json`；Claude Code 走 Anthropic 协议、OpenClaw 走 OpenAI 协议打到同一本地服务。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Jan-外部执行体与应用协作调查笔记.md)
- **能力四：MCP 智能工具路由 — `主链确认`**：用独立小模型对用户意图做工具级路由选择，LLM 不可用时降级关键词分类（七类 fallbackReason），路由决策与降级原因写入遥测；路由结果冻结（签名 + 缓存）以保持提示缓存稳定；为 Agent 工具类目的增强形态，不单独计主贡献。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)
- **归并已有类目项**：本地 OpenAI/Anthropic 兼容 API 服务与按 `model_id` 的静态路由 → 归并 LLM 渠道与生成式输出与运行时类目；双本地运行时（llamacpp + MLX）→ 归并能力一的运行时管理面与运行时类目；Hub 模型市场/量化分档/模型下载 → 归并运行时类目；HTML/SVG Artifact 围栏预览 → 归并消息渲染器类目；RAG 附件检索与 `web_search`/`web_fetch` → 归并 Agent 工具类目；Assistant/Agent、自动标题、首次运行向导、OS keyring → 归并角色/会话/设置类目。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md) `归并已有类目`
- **对特色贡献统计的影响**：主贡献候选为能力一（本地模型运行整体，与统计中 F41 同一能力族则理由增强不新增条目）；辅助贡献候选为能力二/三/四；Artifact、Hub 下载、RAG、web_search 不重复计数；统计表重排待待查清单全局待办处理。详见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)

## 工程与基础设施摘要

`仓库分布` 与 `应用界面基础设施` 两个类目的结论按主题概括如下，不逐条展开：

- **仓库形态与模块量级**：Yarn workspaces monorepo——`web-app/src` 119,779 行、`src-tauri`（含插件）约 3.7 万行、`extensions/*` 7 个独立包 15,440 行、`core` 共享 TS 类型单独发布 npm；全仓 2,258 个跟踪文件、可识别源码 191,672 行。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- **语言与运行时分工**：TypeScript 76.8%、Rust 19%（服务端代理 `proxy.rs` 3,577 行居首）、Swift 1.2%（`mlx-server` 仅 macOS）、Python 用于 autoqa；llamacpp 引擎二进制不入库，发布时经 `scripts/download-bin.mjs` 下载。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- **文档与测试分布**：文档 157 文件/16,735 行（docs 为 Nextra 文档站）；测试 319 文件/60,401 行（vitest 为主、共置 `__tests__`，Rust 用内嵌 `tests.rs` 不计入口径）。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- **跨平台与发布组织**：桌面覆盖 Windows/macOS/Linux，Tauri 提供 iOS/Android 构建入口（`--features mobile`，移动端 SQLite 持久化）；`.github/workflows` 34 个 workflow 覆盖 CI/发布/文档站/npm 发布/autoqa；扁平化打包在 flatpak 目录。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- **扩展机制与 ServiceHub 契约**：`ExtensionManager` 动态加载 7 个扩展包（llamacpp/mlx/assistant/conversational/rag/vector-db/download），扩展间以 `@janhq/core` 的 service hub 为契约；`core/` 单独打包发布。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- **界面栈与公共组件**：React 19 + Vite 6 + Tailwind 4 + TanStack Router（文件路由）+ zustand 5 + TanStack Virtual；`components/ui` 下 27 个 shadcn 风格 Radix 封装，Toast 用 sonner，移动抽屉用 vaul，无内部设计系统包。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **应用装配与 Provider 栈**：ServiceHubProvider（水合设置 store）与 ExtensionProvider（加载扩展，20s 看门狗）两层"就绪才渲染"；辅助窗口（日志/系统监控/API 日志）复用同一 bundle 与路由树，按 webview label 跳过扩展加载；桌面窗口由 Rust 侧运行时创建。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **状态所有权与持久化基座**：公共界面状态几乎全部为模块级 zustand 单例（组件树之外）；`backendStorage` 实现 StateStorage 接口，桌面落盘 `<jan_data>/settings.json`（Rust 500ms 防抖原子写，供 jan-cli 等进程外消费者可读），Web 构建退化为 localStorage，要求 skipHydration + 显式水合。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **弹窗、浮层与通知反馈**：无命令式弹窗服务，跨组件弹窗走"全局 zustand 门控 + Promise resolver"模式（与命令式 PopupHost 相反）；Radix 浮层统一 z-50，少数自绘浮层用 z-9999；sonner toast 支持四角与主题接入，常驻提示用"命名 id + 完成时关闭"配对。【代码确认】[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **主题系统**：权威源在渲染层 zustand（useTheme），Rust 负责系统主题感知（portal/ThemeChanged）与原生跟随（GTK prefer-dark）；支持明暗/auto、4 档字号、11 个强调色（仅写 primary/sidebar 两变量）；跨窗口同步与首屏防闪两层均已接通（静态缺陷见末尾小节）。【代码确认】[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **响应式与窗口适配**：唯一 JS 断点 768px；侧栏 floating/offcanvas，移动端自动换 Sheet 抽屉，rail 拖拽缩放 14–20rem（双持久化：cookie + backend storage）；Toast 顶部偏移避开 48px 拖拽区，右侧 Sheet 按标题栏布局加 pt-15；桌面与移动共用同一前端 bundle，移动端注入禁缩放 viewport 与 safe-area padding。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **密钥工程与安全边界**：API key 等 secrets 只进 OS keyring，settings.json 只存非敏感字段；真实认证为 `proxy_api_key` 双头校验；llama-server 鉴权 key 为公开 secret 派生的 HMAC key（防局域网误连、不防本地恶意进程，见末尾小节）。【代码确认】[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)

## 已知边界与待验证事项

异常项按主题集中于此，正文仅保留正面结论；证据状态标记沿用来源笔记。

### 声明不符

- **本地↔云模型级 failover**：README 语境下的"容灾/路由"易被读成智能调度，实际当前快照只有云端 API key 链 401 重试（`provider-api-keys.ts`）与 MCP 工具路由降级，无分片、无模型级本地↔云自动切换；统一路由为按 `model_id` 静态解析（`resolve_upstream_for_model`）。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md) `声明不符`

### 暂缓与外部依赖

- **Project 工作流**：`入口确认`——路由/服务层/rag-extension `scope:"project"` 检索证据以 UI 层为主，主链未完整走通；与"协同工作区"聚类重叠，本轮不单独提案，留待聚类比较。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md) `入口确认`/`暂缓`
- **BrowserMCP 外部依赖**：伴生 Chrome 扩展，本仓库只有配置入口，主链未接入；`Jan Browser MCP` 的工具被 `DropdownToolsAvailable` 显式过滤，不出现在开关列表中。【代码确认】[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md) `外部依赖`
- **首次运行向导**：普通引导流程，归并设置类目，不进入统计。[独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md) `归并已有类目`

### 未覆盖类目（本次未找到）

以下"未找到"结论均基于明确列出的源码搜索范围，属笔记未覆盖或项目内无入口，不构成项目级绝对否定：

- **角色导入导出**：检索设置路由、助手对话框与 assistant-extension 全部源码，未见文件导入、JSON 分享或导出入口；跨设备迁移只能复制数据目录（`file://assistants/<id>/assistant.json`）。[Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- **收藏 UI 入口**：`toggleFavorite` store 方法存在但 web-app 内无 UI 调用点（侧栏无收藏分区），`deleteAllThreads` 的收藏保留逻辑仍有效。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **回收站、归档与软删除**：threads 模块全部命令、`useThreads` 删除方法、线程列表与对话框目录均无入口；`deleteAllThreads` 的保留集（收藏 + 带 project）是唯一批量保护。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **多窗口跨窗口同步**：web-app chat stores 与 `services/window` 调用点均未找到同步机制（window 服务仅用于主题/扩展窗口），多窗口并发写入同一 thread 的行为未验证。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Jan-ChatUI调查笔记.md>)
- **语音输入**：搜索 `speech`/`webkitSpeechRecognition`/`MediaRecorder`/`getUserMedia` 在 `web-app/src` 无命中。[Chat UI 调查笔记](<../Chat UI/Jan-ChatUI调查笔记.md>)、[消息渲染器调查笔记](../消息渲染器/Jan-消息渲染器调查笔记.md)
- **系统通知通道**：web-app/src 搜索 Notification（浏览器 API 或 Tauri 插件）仅命中通知位置相关符号，无系统级通知。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **主题扩展能力**：web-app/src 搜索 importTheme/exportTheme/wallpaper/customCss/density 等符号无命中，无 themes/ 目录——无主题市场、壁纸、自定义 CSS、运行时字体、密度或圆角设置。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **窗口最小尺寸**：tauri.conf.json 无 windows 段，src-tauri 全文搜索 `min_inner_size`/`set_min_size` 无命中。[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **代码执行器/notebook/画布/diff-patch**：web-app/src、extensions/*、src-tauri/src 全仓搜索无命中（唯一进程 spawn 是 llamacpp 推理 router）；模型输出无独立文件落盘。[生成式输出与运行时调查笔记](../生成式输出与运行时/Jan-生成式输出与运行时调查笔记.md)
- **SQLite 移动端 schema 版本迁移**：`db.rs` 全文无 `PRAGMA user_version` 或迁移表，`CREATE TABLE IF NOT EXISTS` 无版本管理。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **线程/消息导入导出与备份恢复**：web-app services、Rust threads 模块、对话框目录均无入口。[会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- **e2e 测试目录**：未发现 playwright/cypress 端到端测试目录（Rust 测试用内嵌 `tests.rs`，不计入测试文件口径）。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- **移动端发行成熟度**：iOS/Android 仅确认源码与构建入口存在（`--features mobile`），未确认发行成熟度。[仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)

### 静态已确认的缺陷与不一致

- **SecurityConfigDialog 孤儿死代码**：9 个 `security_*` Tauri 命令在 src-tauri 中不存在（全库 grep 无命中），组件无任何挂载点；真实认证在 `proxy.rs` 的 `proxy_api_key` 双头校验。【代码确认】[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)
- **core/web 两侧 Assistant 类型不一致**：core 含 `model`/`tools`/`file_ids` 而无 `parameters`，web 含 `parameters` 而无前三者，v2 迁移却写 `parameters`；web 侧未见 tools 持久化路径，运行时影响未验证。[Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- **主题键名与持久化位置脱节**：内联防闪脚本读 localStorage('theme')、TauriWindowService 读 jan-theme 键（全仓库无写入方），实际持久化在 settings.json；迁移策略有意不清理 localStorage，首帧可能短暂显示错误主题。【代码确认】[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **强调色最小覆盖与静态默认残留**：运行时只写 `--primary`/`--sidebar` 两变量，:root 静态默认值又与 gray 色板不一致（gray 的 primary 为品牌橙），水合前短暂显示静态色。【代码确认】[应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- **llama-server 鉴权强度边界**：鉴权 key 为公开 secret（`'JustAskNow'`）派生的 HMAC key，`RouterInfo{port, api_key, pid}` 对 webview 可见——防局域网误连、不防本地恶意进程。【代码确认】[LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)

### 共性未验证

按"完成度速览"口径，以下均为方法学约束（静态源码确认已完成，未做黑盒运行），不否定代码完备性：

- 运行行为：视觉效果、时序、性能、真实 provider 上的流式、GPU 探测与 fit 预测、Router 多模型并发、外部 Agent 启动、`/v1/orchestrations` 端到端、MCP 智能路由真实 LLM 调用与遥测落库。
- 多窗口/多会话并发：llamacpp 固定 `id_slot=0` 的 KV 复用语义、整文件重写互相覆盖的实际行为。
- 数据与状态：分支树旧数据迁移完整性、compactMessages 摘要质量、banner 与 `metadata.error` 并存的 UI 呈现、消息编辑后引用/grounding 状态一致性。
- 未运行项目测试或构建；全部结论记录来自静态源码，代码快照与调查日期以各来源笔记为准。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Jan-Agent工具调查笔记.md)
- [Agent 角色调查笔记](../Agent角色/Jan-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/Jan-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/Jan-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/Jan-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/Jan-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/Jan-外部执行体与应用协作调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/Jan-应用界面基础设施调查笔记.md)
- [消息渲染器调查笔记](../消息渲染器/Jan-消息渲染器调查笔记.md)
- [独特功能调查笔记](../独特功能/Jan-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Jan-生成式输出与运行时调查笔记.md)