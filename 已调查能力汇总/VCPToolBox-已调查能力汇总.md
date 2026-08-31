# VCPToolBox 已调查能力汇总

> 汇总对象：`VCPToolBox`（远端仓库 `https://github.com/lioensky/VCPToolBox`）
>
> 汇总更新日期：2026-08-28
>
> 依据：15 篇来源笔记（产品结构与设计基因、检索增强与认知编排、Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、媒体创作、对话请求与上下文、应用界面基础设施、独特功能、生成式输出与运行时）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态标记并链接来源笔记；未做新的源码调查，未做跨项目横向比较
>
> 汇总范围：覆盖上述 15 个类目中 VCPToolBox 已调查的能力；默认关闭/默认禁用、声明不符、暂缓与归并项如实列入对应小节
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

VCPToolBox 是 VCP（Variable & Command Protocol）协议的**服务端 + 运维/配置中枢**，不是聊天产品本身：`/v1/chat/completions` 等端点是纯 API，官方桌面聊天前端是外部项目 VCPChat，仓库内不产出最终用户聊天界面。它同时是 VCP 生态里唯一真正执行工具、转发分布式调用并托管审批状态机的服务端。

产品历史上，它从 2025-05-12 的“AI API 与工具交互”工具箱逐步扩展为插件运行时、分布式执行、管理面板和长期记忆中枢；当前 README 将整体定位提升为让 AI 持续存在的环境。RAG 是这一定位变化最集中的演进线：早期多路相似度与结构召回经浪潮 V1-V8、TagMemo V9.1/V9.2 发展到当前 RiverMemo Topology V3。历史作者自述、提交节点和当前执行边界见[产品结构与设计基因](../产品结构与设计基因/VCPToolBox-产品结构与设计基因调查笔记.md)与[检索增强与认知编排](../检索增强与认知编排/VCPToolBox-检索增强与认知编排调查笔记.md)；历史版本不替代当前源码。

核心边界：不拥有会话事实源（客户端提交完整 `messages`，服务端在单次 HTTP 请求内复制、重排、展开、注入和裁剪）；模型推理由外部上游完成，上游出口是单一 OpenAI-compatible 配置（`API_URL` + `API_Key`）；工具调用走纯文本标记协议（`<<<[TOOL_REQUEST]>>>`），不依赖原生 Function Calling；当前快照为 `Plugin/` 下 89 个插件目录（69 启用、20 个 `.block` 禁用）。大量能力高度依赖用户配置且默认关闭或禁用（AgentDream 插件 `.block`、`VCP_BROWSER_RUNTIME_ENABLED=false`、`ReasoningToContentEnabled=false`、`privacyProtection.enabled=false`、TaskAssistant `globalEnabled=false`、`ModelRedirect.json` 本快照不存在），“主链确认”指在默认或文档说明配置下代码链路完整存在，不代表开箱即用。

## 完成度速览

| 证据状态 | 条目数 |
|---|---|
| 主链确认（静态源码贯通） | 44 |
| 入口确认 | 1 |
| 归并已有类目 | 6 |
| 声明不符 | 4 |
| 暂缓 | 2 |
| 合计 | 57 |

主链确认占全部 57 条记录的约 77%；声明不符与暂缓合计 6 项（约 11%）为少数局部异常，其中元思考主题配置、VCPClawMail 轮询间隔、插件数量口径 3 项同时是主链确认卡的局部细节（能力二、能力十六、插件热重载），不否定对应主链完整性。另有若干主链确认能力带默认关闭、默认禁用或外部依赖边界（AgentDream、托管浏览器、VCPEverything 等），性质是“默认未启用”而非“主链缺失”，均集中见文末“已知边界与待验证事项”。

**证据口径**：本汇总的“主链确认/静态源码确认”表示已在当前代码快照复查入口、状态、执行与结果处理构成的实现路径。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效。代码快照与调查日期以各来源笔记为准。

## 功能能力摘要

- **协作循环与可编程媒体交付**：AgentAssistant 可识别 Flowlock 的开始、心跳和终止指令，并持久化协议模式、下次心跳与最终报告预览；MediaRenderer 可把受控浏览器渲染的 HTML 打包成多尺寸 CUR/ANI、预览和安装 ZIP。浏览器可复用已有的 DevTools 端点，鼠标主题仍是文件服务交付物，不形成主题 ID、版本链或协作合并。证据状态：`主链确认`（静态源码）；实际安装效果未运行验证。来源：[Agent工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)、[媒体创作调查笔记](../媒体创作/VCPToolBox-媒体创作调查笔记.md)、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/VCPToolBox-外部执行体与应用协作调查笔记.md)。

### 角色与上下文

- **Agent 提示词文件层与别名映射**：`Agent/` 目录下每个 `.txt` 是一段含 VCP 变量占位符的系统提示词模板，经 `agent_map.json` 映射别名并以 `{{agent:AlterName}}` 嵌套引用；真实映射文件需用户创建（仓库只带 `agent_map.json.example`），映射缺失时占位符不展开、Agent 文件层默认未激活；AgentManager 监视文件变更实现免重启热重载。证据状态：`主链确认`（默认未激活）。来源：[Agent 角色配置调查笔记](../Agent角色/VCPToolBox-Agent角色配置调查笔记.md)。

- **变量体系（多前缀占位符注入管线）**：发送前由 `messageProcessor.js` 多阶段管线替换 `{{VarXxx}}`（环境变量）、`{{TarXxx}}`（对话目标）、`{{Sar Xxx}}`（会话）、`{{VCP…}}`（静态插件）、`[[日记本名::Group::Time::…]]`（TagMemo 知识库）、`{{agent:AlterName}}`（嵌套 Agent）、`《《文件名::…》》`/`<<文件名>>`（TVStxt 文本块）。证据状态：`主链确认`。来源：[Agent 角色配置调查笔记](../Agent角色/VCPToolBox-Agent角色配置调查笔记.md)。

- **AgentAssistant 多 Agent 身份配置与委派（主体）**：每个命名 Agent 定义身份、模型、温度、提示词等；支持即时通讯、`timely_contact` 定时联络与异步委托（`delegationMaxRounds` 默认 15 轮上限），`inject_tools` 可临时拼接工具说明到被委托 Agent 提示词尾部（未做权限限制）。主体已归并到 Agent 工具/Agent 角色类目，跨 Agent 长期通信局部见独特能力十一。证据状态：`归并已有类目`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)、[Agent 角色配置调查笔记](../Agent角色/VCPToolBox-Agent角色配置调查笔记.md)。

- **VCPTavern 预设注入与会话时间变量**：从 system 消息查找 `{{VCPTavern::Preset...}}` 触发器，按 embed/relative/depth 策略注入预设，可解析 `{{LastChatTime}}`/`{{TimeSinceLastChat}}` 会话时间变量（唯一“会话键”持久化是 `access_logs.json` 时间戳）。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)。

- **上下文编排（OneRing / VCPTimeLine / ContextFoldingV2）**：已确认数组元数据（`__oneRingMeta`）、时间线占位符替换与基于摘要的折叠替换，均以预处理器改写本次消息数组实现，属上下文编排而非独立会话存储。已归并到对话请求与上下文类目。证据状态：`归并已有类目`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)、[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 归并说明。

- **上下文裁剪、多模态预处理与预处理器顺序**：`contextTokenLimit` 按文本字符数估算裁剪（非 token 真值、忽略图片）；多模态预处理器（`MultiModalProcessor`/`ImageProcessor`）与其余 messagePreprocessors 按 `preprocessor_order.json` 顺序执行（未列出插件按名称排序追加）；RAGDiaryPlugin 只处理 system/系统前缀 user 中的日记占位符。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)。

- **Role Divider 角色拆分**：按开关运行，识别 `<<<[ROLE_DIVIDE_SYSTEM/ASSISTANT/USER]>>>` 标签拆出新消息，并保护工具请求与日记标记块不被拆开。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。

- **推理内容双通道与客户端展示转换**：流式/非流式处理器在回注客户端的副本上把 `reasoning_content` 等字段按模型白名单（`ReasoningToContentModel`）改写为 ` thinking` 标签正文；内部 VCP 循环、OneRing 入库与日记持久化只使用原始 `content`，两通道互不污染；该转换默认关闭，细节见末尾小节。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

### 会话与消息

- **请求级消息编排（无会话事实源边界）**：不拥有会话事实源，无会话对象、会话列表、消息 CRUD、编辑/删除/分支、搜索或导入导出；输入单位是请求体 `messages[]`，会话 ID、历史数组与最终展示状态由外部前端负责，服务端重启不保留会话状态。证据状态：`主链确认`（边界记录，非能力缺失）。来源：[会话与消息管理调查笔记](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/VCPToolBox-Chat调查笔记.md)。

- **审计与调试存储盘点**：`finalContextStore`（内存最多 5 组滑窗快照）、ChatLog（可选审计文件，默认关闭）、`tool-call-records.sqlite3`（工具调用审计台账，默认关闭）、VCPTavern `access_logs.json`（会话键时间戳）均为审计/调试性质，不是会话持久化。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)。

- **请求级停止与响应去重**：`/v1/interrupt` 按 `requestId`/`messageId` 在 `activeRequests` 注册表中置中止标志并级联 `AbortController`，客户端断联触发同一中止链；`ResponseReplayCache` 按 `clientIp::messageId` 做响应回放去重（默认关）。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)。

- **Chat UI 不适用边界**：不产出最终用户聊天主界面。AdminPanel-Vue 40 条路由逐条核对无聊天路由；`adminServer.js` 独立进程监听 PORT+1、主进程 302 重定向，与聊天主链物理解耦；Nova 看板娘气泡、沉浸观星面板等均为彩蛋装饰；`aiChat` 后台 API 代理无消费页面；OpenWebUISub 是第三方页面纯前端增强层。证据状态：`主链确认`（不适用记录）。来源：[Chat UI 调查笔记](<../Chat UI/VCPToolBox-ChatUI调查笔记.md>)、[Chat 调查笔记](../Chat/VCPToolBox-Chat调查笔记.md)。

### 生成与创作

- **输出协议与对象模型**：全部输出由模型自由文本中的纯文本标记触发（工具块、`[[VCP调用结果信息汇总]]`、`<<<DailyNoteStart>>>` 日记块、角色分割标签、`<!-- VCP_TOOL_PAYLOAD -->` 回灌、RAG 知识块）；无带稳定 ID 的输出对象模型，聊天输出无服务端对象 ID/类型/版本，具有稳定身份的实体是派生物（日记文件、论坛帖子、图片、工具记录、OneRing 时间线）。能力等级 G1 主形态 + 局部 G3（MediaRenderer/AICodeWorker）。证据状态：`主链确认`。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。

- **流式生成、最终化与失败收口**：上游 SSE 按行解析、原样转发并后台累积；`finish_reason: stop` 时补发 final chunk 与 `[DONE]`，达到工具循环上限时发 `length`；上游非 200 以 200 + SSE 错误块回写，连接超时默认 15 分钟、重试 `ApiRetries` 默认 3、90 秒无 chunk 判冻结并注入中断提示。证据状态：`主链确认`。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)。

- **日记回流闭环**：模型输出 `<<<DailyNoteStart>>>` 块 → 解析落盘 `dailynote/` → 后续请求中 RAGDiaryPlugin 检索并以 `<!-- VCP_RAG_BLOCK_START -->` 块注入上下文，还可按新上下文刷新历史 RAG 块，构成“模型输出 → 持久化 → 再进入模型上下文”闭环。证据状态：`主链确认`。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。

- 多媒体生成（MediaRenderer 可编程渲染 + 图像/视频插件族）与异步任务回注两条主链分别见独特能力十、能力五。

### Agent 运行时与外部协作

- **VCP 文本协议解析器**：状态机扫描器（`toolCallParser.js`）解析 `<<<[TOOL_REQUEST]>>>` 块与「始」「末」字段，默认严格模式精确匹配，`fuzzyToolMatching` 开启后容忍 `{始}`、`<<[TOOL_REQUEST]>>` 等变体（可配置的协议宽松开关）；支持 ESCAPE 转义、同轮多块、` thinking` 思考块剥离（未闭合标签保守丢弃其后内容）；解析器不识别 code fence，流式解析发生在完整拼接后。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。

- **工具定义与上下文注入**：模型看到的工具描述是插件 manifest 中的原始中文自然语言文本（无 JSON Schema/function-calling 转换层），经 `{{VCP<PluginName>}}` 占位符注入 system prompt；static 插件另有 `{{VCPxxx}}` 数据占位符，支持 `refreshIntervalCron` 周期性刷新与 stale-while-revalidate 语义。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。

- **工具执行链**：ToolExecutor 以 `Promise.all` 并发执行同轮调用，单个失败转为错误结果不中断其他调用；流式/非流式处理器把工具调用触发的重新推理限制为最多 5 轮（可配置）；stdio 默认超时 60 秒/异步 1800 秒、分布式默认 60 秒；无自动重试（错误回注由模型自愈）；超时后跨平台强杀整个进程树。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。

- **审批系统与隐私脱敏**：执行前的人工控制环节，审批请求经 WebSocket 广播给所有已认证的 VCPLog 客户端，任何持有全局 `VCP_Key` 的客户端均可批准/拒绝任意请求（身份未绑定发起者）；超时默认 5 分钟且默认拒绝执行，`WebSocketServer` 未初始化时直接抛错；`requiresAdmin` 非框架强制（两条注入路径都要求插件自己比对）；`privacyProtection.enabled` 开启后工具结果回注前按敏感模式掩码（默认关闭，细节见末尾小节）；审批判定发生在分布式分支之前，对转发调用同样生效。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。

- **分布式节点协议**：WebSocket 节点经 `register_tools` 注册工具与能力，主服务器 `executeDistributedTool` 分派并等待 `tool_result`；结果绑定目标 `serverId`（非目标节点结果被忽略），节点声明 `cancelTool` 时超时 best-effort 发送 `cancel_tool`，断线立即 reject 全部 pending；鉴权只有一层全局 `VCP_Key`（无节点级密钥），同名工具注册会被跳过但可注册诱导性命名新工具。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。

- **外部执行体接入**：AICodeWorker 以 jobId 调度 opencode/Antigravity CLI（analyze/patch/write 三模式，共用并发闸门）；SSHManagerService 按 hosts.json 连接池预热执行远端设备；DeepWikiVCP 是全仓库唯一 MCP-over-HTTP 客户端。托管浏览器与跨节点文件两条链分别见独特能力六、能力七。证据状态：`主链确认`（静态证据）。来源：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/VCPToolBox-外部执行体与应用协作调查笔记.md)。

- **插件热重载与插件清单**：manifest 变更分“元数据刷新”与“完整重载”两级，static 插件按签名增量刷新并清理失效占位符与 cron，加载流程串行化并带预校验；当前快照 89 个插件目录、69 启用、20 个 `.block` 禁用；数量口径与文档不符的细节见末尾小节。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。

- **执行隔离与安全边界**：stdio 插件与主进程同机同用户权限、无 OS 级沙箱，direct/hybridservice 插件即主进程一部分；唯一例外是 LinuxShellExecutor 自带可选沙箱后端（bubblewrap/firejail/docker，默认 none）与 RLIMIT 资源限制；Dockerfile 中 `USER appuser` 被注释（容器内默认 root）；Shell 类插件安全差异巨大（PowerShellExecutor 仅关键字黑名单，LinuxShellExecutor 有八层校验）；未发现 `vm.*`/`eval` 执行模型任意代码。证据状态：`主链确认`（含已确认边界）。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。

- **HTTP/WebSocket 鉴权与安全边界**：`/v1/*` 全局 Bearer 鉴权（白名单图像/Embedding 路由在通用鉴权之前挂载，可绕过 VCP 对外 Key 校验）；管理面板 Basic Auth/Cookie；图床 `/pw=<key>/` 路径内嵌 key；`/plugin-callback` 无鉴权（taskId 无签名，可伪造覆盖异步结果）；WebSocket 各通道共享同一 `VCP_Key`；CORS 全开、默认监听所有网络接口。证据状态：`主链确认`（含已确认风险点）。来源：[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

### 渠道与调度

- **单上游出口与模型层**：核心 LLM 出口只有一个 `API_URL` + `API_Key`（OpenAI-compatible），无本地 Provider 实体表、多 Base URL 或多 Key 池；Provider 渠道/Key 轮询/熔断若存在则在聚合上游（NewAPI/One API）内部，对 VCP 是黑盒；`ModelRedirect.json` 提供公开名→内部名静态映射，本快照不存在即默认未启用。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

- **语义路由与模型重定向**：`SemanticModelRouter.json` 暴露 `VCPModelAuto` 等虚拟模型，用最后 user/assistant 内容 embedding 与 route description 做余弦相似度排序，低于阈值选默认模型；普通指定模型重试时模型不变，仅语义虚拟模型请求沿候选模型链改写 `body.model`；Web 管理端的新增/复制/删除/启停对象是 preset/route 而非 Provider。已归并到 LLM 渠道管理类目。证据状态：`归并已有类目`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

- **入站协议桥**：OpenAI Chat/Responses、Anthropic Messages、Gemini GenerateContent 五种入站协议经 `protocolBridge.js` 归一化为 OpenAI 风格消息并本机回送主 Chat 链；出站仍统一 OpenAI-compatible Chat Completions；原生 tools 字段原样透传、不参与 VCP 工具执行。已归并到 LLM 渠道管理类目。证据状态：`归并已有类目`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)。

- **重试、超时与 Embedding 备用模型**：普通 Chat 最多 `ApiRetries` 次总尝试（默认 3），重试 500/503/429/特定 token 型 401/连接/首包超时/网络错误，退避为按尝试次序递增的线性延迟（不读 Retry-After、无抖动）；Embedding 有独立主模型 + 最多 9 个备用模型顺序切换，URL/Key 不变；无多 Key 轮询、Key 级熔断、多渠道权重或 Provider 健康表。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

- **凭据存储、备份与鉴权缺口**：`config.env` 与插件 `config.env` 均为磁盘明文，管理 API 把完整主配置原文返回给已认证管理员（无 Secret 掩码）；`backup_vcp.py` 默认归档所有 `.env`/`.json`，会把核心/插件 Key 一起放入未加密 ZIP；白名单图像/Embedding 路由在通用 Bearer 鉴权之前挂载，命中请求直接使用上游 `API_Key` 转发。证据状态：`主链确认`（含已确认风险点）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

- **可观测性与连接测试**：`/v1/models` 单次拉取上游目录并附加语义路由虚拟模型；管理端模型列表接口、Chat 代理与语义匹配预览是三个层次的检查（目录/可达性、真实生成链、只算路由计划）；可选 NewAPI Monitor 显示请求/token/quota/RPM/TPM，数据来自外部 NewAPI 管理 API、不参与 VCP 路由；CLI、TUI 与独立桌面端渠道管理入口未找到。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)。

### 独特与差异化能力

以下保留独特功能类目能力卡标题与证据状态；19 张卡中 18 项为 `主链确认`（静态证据）、1 项为 `归并已有类目`（能力十一，保留跨 Agent 长期通信局部）；另有人类工具 API（`/v1/human/tool`）为 `入口确认`，未闭合细节见文末小节。完整机制、源码定位与边界见 [独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md)。

**记忆演化**

- **能力一：TagMemo 浪潮语义动力学 + RiverMemo 拓扑 V3**：让长期记忆按语义相关性而非关键词召回并维持可解释排序，写入/索引/查询/排序/解释/更新全链在一条可解释数学链内，排序内核在 Rust/Rayon 单次 N-API 边界交付；依赖上游 Embedding API。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md)能力一、[检索增强与认知编排调查笔记](../检索增强与认知编排/VCPToolBox-检索增强与认知编排调查笔记.md)。

- **能力二：元思考递归推理链（VCP元思考）**：以提示词 DSL 触发多阶段递归 RAG，按链定义逐簇召回元逻辑模块并用上一阶段结果改变下一阶段查询方向；当前快照只有 default 链，主题配置存在文档与实现出入，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力二。

- **能力三：AgentDream 非对话记忆整理（梦系统）**：定时（默认 1-6 点、0.6 概率、8 小时冷却）或手动入梦，生成意识流叙事与需审批的记忆整理操作（合并/删除/感悟），审批执行链在管理路由 `routes/admin/dream.js`；插件默认禁用，无预算、无进行中取消，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力三、[Agent 角色配置调查笔记](../Agent角色/VCPToolBox-Agent角色配置调查笔记.md)。

- **能力十二：LightMemo 轻量记忆检索与生产构型 A/B 对照**：复用 RAGDiaryPlugin 索引与 Rust 引擎，提供 KNN/TagMemo V9/RiverMemo V3 三轨同域 A/B 重合率对照，作为调优与验证机制。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十二。

**上下文语言**

- **能力四：TVS 占位符上下文语言 + PlaceholderExplorer 调试面**：占位符解析带 Agent/Toolbox 守卫与递归解析，PlaceholderExplorer 提供占位符索引/编辑/预览与死链检查、编辑回滚。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力四。

**创作工作站**

- **能力十：多媒体生成与媒体插件族**：MediaRenderer 可编程渲染（HTML/SVG → 托管 Chrome 截图或确定性逐帧 + FFmpeg 编码 GIF/MP4/WebM、AI 合成代码 → Node 子进程生成 PCM16 WAV）+ 图像/视频生成插件族（15 目录，FluxGen/GPTImageGen/GeminiImageGen/QwenImageGen/DoubaoGen 等，2 个 `.block` 禁用），统一走 VCP 块协议；资源白名单（50MB/100MB/24 资源/2MB 源码/帧数/采样上限）、脚本白名单（仅 Anime.js/Three.js）、页面运行时网络全阻断、云元数据地址常禁、GenerateAudio 需 6 位验证码。证据状态：`主链确认`（含运行验证部分）。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十、[媒体创作调查笔记](../媒体创作/VCPToolBox-媒体创作调查笔记.md)。

- **能力五：六类插件协议与异步任务回注**：static/synchronous/asynchronous/service/messagePreprocessor/hybridservice 六类协议统一编排；异步长任务先返回、回调 `/plugin-callback/:pluginName/:taskId` 后经 `{{VCP_ASYNC_RESULT}}` 占位符回注，结果落盘 `VCPAsyncResults/`；回调端点存在无鉴权边界，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力五、[媒体创作调查笔记](../媒体创作/VCPToolBox-媒体创作调查笔记.md)。

**人类工具面 / 活对象**

- **能力六：浏览器托管运行时（managed Chrome + ChromeBridge 协议 v3）**：生命周期、页面观察/控制/验证/截图、Grounded Markdown Agent 视图、稳定内容 Hash、快照去重、默认敏感 DOM 脱敏与指标；2.4 新增正文图片语义与 Popup 人工 Managed 选择，agent 不再隐式控制托管运行时；运行时默认关闭，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力六、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/VCPToolBox-外部执行体与应用协作调查笔记.md)。

**分布式多模态**

- **能力七：跨节点文件透明获取与取消传播**：WebSocket 节点返回文件带来源信息，FileFetcher 按来源透明拉取与缓存，带循环保护、断线清理与 `cancel_tool` 传播。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力七、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/VCPToolBox-外部执行体与应用协作调查笔记.md)。

**主动 Agent**

- **能力八：TaskAssistant 定时/手动任务派发**：interval/cron/once/manual 四种调度模式，任务与历史持久化于 `task-center-data.json`，派发给 AgentAssistant 定义的 Agent（进程内直连模块，不走 HTTP 回环）；结果归属任务对象与历史，无进行中取消；`globalEnabled` 默认关闭，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力八、[Agent 角色配置调查笔记](../Agent角色/VCPToolBox-Agent角色配置调查笔记.md)。

- **能力十六：VCPClawMail 邮箱轮询与投递**：常驻轮询邮箱、WebSocket 即达推送、`{{VCPClawMailInbox}}` 占位符注入，子邮箱可自动投递到对应 Agent；依赖 ClawMailKey 等外部配置，轮询间隔存在文档与实现出入，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十六。

**Agent 社会**

- **能力九：VCPForum 文件事实源社区**：帖子以 Markdown 文件为事实源（`dailynote/VCP论坛/*.md`），Agent 可发帖/回复，模型写、人读；无用户治理机制。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力九、[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。

- **能力十五：MagiAgent 多观点会议**：三贤人独立 LLM 辩论、异步查询与 `{{VCP_ASYNC_RESULT}}` 回注，形成多观点会议机制。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十五。

- **能力十一：分布式 Agent / AgentAssistant 多 Agent 通信（跨 Agent 长期通信局部）**：委托与即时通讯主体已归并到 Agent 工具/Agent 角色类目；跨 Agent 上下文 TTL 与心跳保留为本卡片局部。证据状态：`归并已有类目`（保留跨 Agent 长期通信局部）。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十一、[Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。

**自进化 Skill**

- **能力十四：SkillBridge 技能目录索引**：启动扫描 `SKILL/` 生成 vcp_fold 折叠技能索引 `{{VCPSkillBridge}}`，Ink 模式读取工作流约定。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十四。

**支撑机制（安全）**

- **能力十七：UserAuth 管理员认证码**：每小时 6 位码经 code.bin 解密注入 `DECRYPTED_AUTH_CODE` 环境变量，供 requiresAdmin 工具（PowerShellExecutor/MediaRenderer 等）消费；属安全支撑机制，不计主贡献。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十七。

**其他**

- **能力十三：VCPEverything 本地全盘文件检索**：Everything HTTP 服务桥，提供毫秒级全盘搜索；依赖本机 Everything HTTP 服务，细节见末尾小节。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十三。

- **能力十八：DigitalOracle 金融数据聚合**：15 个 Provider 聚合宏观/利率/加密/预测市场/期权数据，全局宏面板并发聚合。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十八。

- **能力十九：DeepWikiVCP 仓库文档 MCP 客户端**：全仓库唯一 MCP-over-HTTP 客户端，支持 DeepWiki 结构/内容/问答/Deep Research/多仓库，80K 截断防爆上下文。证据状态：`主链确认`。来源：[独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力十九。

**归并已有类目清单**

- OneRing / 时间线 / ContextFolding：已归并到对话请求与上下文类目。
- 语义虚拟模型路由：已归并到 LLM 渠道管理类目。
- OpenAI/Anthropic/Gemini 协议桥：已归并到 LLM 渠道管理类目。
- AgentAssistant 多 Agent 通信（主体）：已归并到 Agent 工具/Agent 角色类目。
- 管理面板、系统监控、日志查看：已归并到 Chat UI/运维常规类目，不形成独立能力卡。

> 独特能力族的产品/机制贡献划分（18 个可计能力族、支撑机制单列、入口确认暂不计入）见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 工程与基础设施摘要

- **仓库分布**：VCPToolBox 是 Node 编排服务、Vue 管理台、插件集合、知识/技能资料与多个 Rust/Python 辅助程序合仓的多运行时插件仓库。Git 跟踪 3,010 文件，可识别源码 1,283 文件/459,871 行，文档 692 文件、测试 32 文件；两大主体为 `AdminPanel-Vue`（src 270 文件 + vendor 46 文件 + dist 320 跟踪文件）与 `Plugin`（SkillBridge 616 文件、PaperReader 81 文件），根服务源码约 20,813 行。语言占比 JavaScript 51.1%、Vue 14.9%、Rust 8.6%、CSS 6.3%；测试集中在 AdminPanel 与根 tests，未随插件数量成比例扩展；Docker CI 构建 Linux amd64/arm64；`c4c4d00`→`1ae9b63c` 集中做多系统兼容加固（进程树终止跨平台化、macOS SQLite checkpoint、Rust 搜索器按平台三元组选原生二进制）。统计为 Git 跟踪文件机械统计，未运行构建、部署与测试。来源：[仓库分布调查笔记](../仓库分布/VCPToolBox-仓库分布调查笔记.md)。

- **应用界面基础设施**：AdminPanel-Vue 是 Vue 3 + Pinia + vue-router 单页应用，无第三方 UI 组件库、无动画库、无 i18n 库，40 条路由分 4 个导航分组。BaseModal 自研弹窗基座（Teleport、焦点陷阱、滚动锁定、Esc/遮罩关闭）；confirm/input/loading/message 经模块级 feedbackState 单例 + FeedbackHost 提供命令式接口（总线可替换）；通知中心经 WebSocket 自动重连、抽屉内嵌工具审批响应。主题完全保存在 localStorage，OKLCH token + 17 预设 + 颜色覆盖 + 自定义 CSS + 背景图，运行时变量发现、结构 token 锁定、导入导出；无系统跟随、主题市场或自动色阶生成。响应式依赖媒体查询，Dashboard 另用容器查询与列数感知；拖放分 HTML5（插件上传）与自研指针会话（排序/面板）两套；无公共图片灯箱、上传组件、应用级错误边界；无障碍静态盘点有焦点陷阱、aria-live、skip-link，命令式对话框焦点圈与 BaseModal 不一致（运行态未验证）。来源：[应用界面基础设施调查笔记](../应用界面基础设施/VCPToolBox-应用界面基础设施调查笔记.md)。

## 已知边界与待验证事项

本小节集中记录声明不符、暂缓、入口确认未闭合、默认关闭/外部依赖与共性未验证事项；功能能力正文只保留正面结论，局部异常在此集中。

### 声明不符

- **元思考主题配置（`thinktheme/*.json`）**：`docs/FEATURE_MATRIX.md` 声明主题配置位于 `thinktheme/*.json`，仓库未找到该目录；实际主题入口是 `meta_thinking_chains.json` 的非 default 链条目，当前快照只有 default 链（能力二局部异常）。
- **README“300+ 官方插件”**：实际快照为 89 个插件目录（69 启用 + 20 个 `.block` 禁用），数量口径与文档不符（不影响插件热重载主链判断）。
- **README“跨模型上下文无缝持久化”**：无服务端跨模型上下文持久化，历史由客户端携带，表述夸大。
- **VCPClawMail 轮询间隔**：manifest 声称默认 60000ms，代码以 5 分钟为下限（能力十六局部异常）。
- **AgentDream 插件内审批函数**（非异常记录，不计入计数）：`approveDreamOperation`/`rejectDreamOperation` 为 not_implemented 占位，但管理路由 `routes/admin/dream.js` 实现真实审批执行，以可执行路径为准，链完整。

### 暂缓与外部依赖

- **按 Agent 隔离浏览器 Profile（maid/valet）**：仅存在于二期设计文档，当前未实现（`暂缓`），当前仍是 global 单 Profile。
- **VCPForumOnline 在线论坛**：`.block` 禁用，功能比文件版更全（私信/点赞/编辑/搜索/未读追踪），当前主链以文件版 VCPForum 为准（`暂缓`）。
- **默认关闭/禁用机制**：AgentDream（`.block` 默认禁用）、托管浏览器（`VCP_BROWSER_RUNTIME_ENABLED=false`）、ReasoningToContent、privacyProtection、TaskAssistant（`globalEnabled=false`）、ModelRedirect.json（本快照不存在）等默认关闭项在真实部署中的推荐配置组合未验证；主链在默认或文档配置下代码完整，不代表开箱即用。
- **外部依赖**：VCPEverything 需本机 Everything HTTP 服务；VCPClawMail 需 ClawMailKey（manifest required）；DeepWikiVCP/DigitalOracle 需网络与上游服务；TagMemo/元思考/LightMemo 的 Embedding 依赖上游 API。均属配置可用而非默认可用。

### 入口确认未闭合

- **人类直接调用工具 API（`/v1/human/tool`）**：端点存在且需 Bearer 鉴权、复用完整审批链（`server.js:1250-1298`，Bearer 之后注册），已被 CapturePreprocessor（ScreenPilot 截图）与 VCPForumOnlinePatrol（禁用）作为内部调用面；VCPToolBox 内无独立人类工具面板 UI，与 VCPChat 自动 GUI 的交接属 VCPChat 仓库范围，未调查。

### 未覆盖类目

- **插件细节**：`ScheduleManager`/`TimedTaskQuery` 等定时插件后台调度、各插件内部参数校验/路径处理/命令拼接、ImageServer 路径 key 比对逻辑未逐一深入。
- **能力卡局部子项**：VCPClawMail 的 listEmails/readMail/sendMail 主体与 `getDataDir()` 实际路径未逐行验证；LightMemo 的 `_rerankDocuments` HTTP 调用细节未逐行验证；MagiAgent `/MagiAgent/:id` 回调端点鉴权未核对；UserAuth 在 `chatCompletionHandler.js:363-374` 的另一 code.bin 读取点用途未核实；SkillBridge 的 vcp_fold 在 system prompt 端实际展开与 FileOperator “Ink 模式”具体命令名未核对。

### 共性未验证

- **静态证据为主**：全部主链为静态代码结论；记忆召回质量、梦境叙事、媒体渲染、托管浏览器进程行为、任务调度长跑、主题/无障碍/键盘运行态均未运行验证。
- **分布式与外部执行**：分布式节点断线/重连/在途文件与取消竞争、SSH 会话中断、AICodeWorker 真实取消与工作区写入、SnowBridge 断线语义未运行验证；managed browser 的登录态、Profile 隔离、私网/云元数据防护未验证。
- **安全边界**：`/plugin-callback` 无鉴权与 `plugin_callback_forward` 来源未绑定的实际利用面、白名单路由绕过 Bearer 的利用面、PowerShellExecutor 关键字黑名单绕过空间未做端到端验证；Docker 下 `SANDBOX_BACKEND=docker` 可用性未验证。
- **范围说明**：较早来源主要基于提交 `1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`，仓库分布、产品结构及检索增强等近期来源已更新到 `e2762e4dab5c70952d88f96689fba1270624e5ef`；均为 `main` 分支，具体以各来源笔记元数据为准。

## 来源笔记索引

- [产品结构与设计基因调查笔记](../产品结构与设计基因/VCPToolBox-产品结构与设计基因调查笔记.md)
- [检索增强与认知编排调查笔记](../检索增强与认知编排/VCPToolBox-检索增强与认知编排调查笔记.md)
- [Agent 工具调查笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/VCPToolBox-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/VCPToolBox-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/VCPToolBox-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/VCPToolBox-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md)
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/VCPToolBox-外部执行体与应用协作调查笔记.md)
- [媒体创作调查笔记](../媒体创作/VCPToolBox-媒体创作调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/VCPToolBox-应用界面基础设施调查笔记.md)
- [独特功能调查笔记](../独特功能/VCPToolBox-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)
- [特色功能贡献统计](../AI客户端特色功能贡献统计.md)
