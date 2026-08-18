# Manifold Desktop 已调查能力汇总

> 汇总对象：`Manifold Desktop`（本地路径 `E:\works\git\Manifold-Desktop`）
>
> 汇总更新日期：2026-08-18
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染、独特功能、生成式输出与运行时共 13 篇来源笔记（代码快照均指向 `3d7448fb2e6053056da6d6c126e08f90b94cda4f`）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题归并重复能力，保留各笔记的证据状态标记并链接来源；汇总文件本身不做新源码调查
>
> 汇总范围：功能能力为主体；仓库分布、应用界面基础设施单列于工程与基础设施摘要；不做跨项目横向比较
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Manifold Desktop 是 Windows 10+ x64 单平台的 AI 聊天客户端，架构为"原生 C++/WinUI 3 薄壳 + 无框架 WebView2 单页面前端 + 独立 `server/` Proxy 样例"。README 自标 `Experimental`，仓库处于长期低活跃、未正式归档状态。CI 编译通过；按 13 篇来源笔记，项目处于"已调查但主链未闭合"状态：多轮 Chat 连续性、MCP 工具执行、插件初始化与会话持久化等关键主链存在已确认的断点，特色功能贡献统计为 0 分。各项能力的已确认事实与边界分布见下文与文末"已知边界与待验证事项"。

## 完成度速览

能力条目共 37 项，按主证据状态分布：

| 证据状态 | 条目数 |
| --- | ---: |
| 主链确认 | 29 |
| 入口确认 | 6 |
| 静态推断（待运行验证） | 1 |
| 独特功能候选盘点 | 1 |
| 暂缓 | 0 |
| 合计 | 37 |

独特功能候选盘点内含 8 个子项，另计：归并已有类目 2、入口确认 3、声明不符 3；特色功能贡献统计为 0 分，属于"已调查但主链未闭合"项目，占位方式见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。"主链确认"以源码贯通为据，既含"能力存在且链路接通"也含"源码确认的缺口"（如会话不持久化、assistant 不回写、MCP 不执行均为已确认事实，非推测）；异常判定（声明不符 3 子项、静态推断 1 项、以及入口确认未闭合项）集中列于文末"已知边界与待验证事项"，不在正文反复出现。

口径说明：本汇总所有"主链确认/静态源码确认"均基于对当前代码快照的源码贯通，在编译型桌面应用或完整本地主链中视为完成交付态；"未运行验证"仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。

## 功能能力摘要

### 角色与上下文

- **全局配置取代角色对象**：角色能力由全局 `systemPrompt`、`temperature` 与默认 Provider/模型承载；源码确认没有 Agent、Persona 或角色模板对象，无会话级角色保存。证据状态：主链确认。来源：[Agent 角色配置调查笔记](../Agent角色/Manifold-Desktop-Agent角色配置调查笔记.md)。
- **系统提示词发送链路**：发送时前端从全局 settings 读取 system prompt，后端按协议映射——OpenAI/OpenAI-compatible 放入消息首部 system 消息、Anthropic 写入顶层 `system`、Gemini 写入 `systemInstruction`；Compare 页共用同一条全局提示词。会话不保存发送时配置，重开历史会话无法恢复当时参数（见文末）。证据状态：主链确认。来源：[Agent 角色配置调查笔记](../Agent角色/Manifold-Desktop-Agent角色配置调查笔记.md)。
- **提示词库**：每条提示词一个 JSON 文件存于 `%LOCALAPPDATA%\Manifold\prompts\<id>.json`；标记为系统提示词的条目覆盖全局 system prompt，普通条目插入输入框。无分组、排序、目录与编辑流程，标题和内容无业务校验。证据状态：主链确认。来源：[Agent 角色配置调查笔记](../Agent角色/Manifold-Desktop-Agent角色配置调查笔记.md)。
- **上下文拼装**：把当前标签整个 `messages[]` 的 role/content 副本按数组顺序发送；assistant 流式文本只进 DOM 与 `streamingText`、不回写消息数组，第二轮请求缺少上一轮 assistant 上下文，且无上下文截断、摘要压缩或 token 预算处理（见文末）。证据状态：主链确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)、[Chat 调查笔记](../Chat/Manifold-Desktop-Chat调查笔记.md)。
- **请求参数装配**：后端消费宿主 settings 中的 temperature 作为请求参数；输入栏 token 估算按字符数/4 显示，不参与请求构造。前端 payload 的 temperature/tools 字段与设置面板 streamResponses 开关不参与请求构造（见文末）。证据状态：主链确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)。

### 会话与消息

- **会话数据层**：内存"聊天标签 + 组件局部 `messages[]`"与磁盘会话文件两套实现并存，存储层增删改查完整；正常聊天不落盘，新对话关闭标签即丢失，前端 `session-store.js` 为无引用死模块（见文末）。证据状态：主链确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/Manifold-Desktop-Chat调查笔记.md)。
- **会话文件存储与全文搜索**：`SessionManager` 提供整文件保存、加载、删除、列表（按 updatedAt 降序）与全文搜索（逐文件整份 JSON 子串匹配，无索引、无结果上限）；会话文件 schema 含 id/title/model/messages/createdAt/updatedAt，无版本号。证据状态：主链确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)。
- **会话列表、Home 与搜索定位**：侧栏会话列表、Home 页 Recent Sessions 网格（最多 12 条）与 Ctrl+F 搜索浮层（300ms 防抖、键盘导航）均可重新打开磁盘会话；搜索返回会话级结果，无会话内搜索与消息级定位。证据状态：主链确认。来源：[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)。
- **会话重命名与导入写路径**：重命名与导入的磁盘写路径存在；重命名只发送 `{title}` 对象、后端按整份 JSON 覆盖原文件，导入保存对 id 无路径成分校验，存在清空消息与路径穿越风险（见文末）。证据状态：主链确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)。
- **消息模型**：前端消息为 role/content 普通线性数组；C++ 侧 `ChatMessage` 另有 parts/toolCall/toolResult 扩展字段但仓库无产生路径；未接入的会话仓库按 `"model"` 角色读取，聊天主链与渲染器统一使用 `"assistant"`，角色命名存在不一致（见文末）。证据状态：主链确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)。
- **消息操作**：错误行 Retry 按钮与代码块复制等交互存在；无消息级编辑、删除、重生成、续写、回退或分支，Retry 只删除错误提示、不重发请求（见文末）。证据状态：主链确认。来源：[会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)。

### 生成与创作（生成式输出与运行时）

- **生成式输出为格式化回复（G0）**：模型输出以 SSE 流式文本逐 token 进入消息 DOM，经 marked.js 渲染为 Markdown 内联 HTML；无输出对象机制——无独立 ID、类型、状态或生命周期，无预览/编辑器/画布/沙箱/执行环境，无输出级持久化与模型回流（见文末）。证据状态：主链确认（专项评级 G0）。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)。
- **流式生成与广播**：单全局 `m_chatThread` 串行执行，新请求先停旧线程；chunk 经 `CHAT_CHUNK`/`CHAT_DONE` 广播并在前端累积重渲染，Compare 用独立线程向量并按 slotIndex 分发。广播无会话标识，多标签同时打开时一个请求可能更新多个标签（见文末）。证据状态：主链确认。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)。
- **Markdown 渲染**：历史 assistant 消息走自定义 code renderer 渲染，流式路径每次整段重渲染裸 `marked.parse()`；代码块复制按钮与工具调用折叠块存在。无 sanitizer、无 CSP，模型输出直接 `innerHTML` 注入，且已用仓库内 marked 复现历史代码块 renderer 对 fenced code block 抛 `TypeError`（见文末）。证据状态：主链确认（renderer 类型错误已运行复现）。来源：[消息渲染调查笔记](../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md)。
- **输出交互碎片**：代码块复制、工具调用折叠（点击展开 JSON 参数/结果）、错误行、取消按钮与完成时的 cost badge（token 与静态价格估算存 localStorage）入口存在；事件回传为单向推送，无日志与运行状态机。证据状态：入口确认。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)。
- **输出持久化与模型回流**：流式回复完成时不落盘、不入消息数组，模型不可查询输出列表或延续自己的上一轮输出，每次聊天从空数组起步，无"定位既有对象继续修改"机制（见文末）。证据状态：主链确认（缺口已确认）。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)。

### Agent 运行时与外部协作

- **MCP 工具链路**：无内置网页搜索/文件/代码执行工具，模型可见工具全部来自 MCP；工具经 `tools/list` 发现、扁平化为 schema 注入请求，模型返回的 tool call 渲染为折叠卡片。执行与结果回注未接通：`MCPClient::CallTool()` 已实现但无运行时调用点，`ToolResult` 与 `maxToolCallRounds` 只有定义（见文末）。证据状态：主链确认（执行缺口已确认）。来源：[Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)、[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)。
- **MCP 传输**：stdio transport 以 `CreateProcessW` 启动用户配置命令，SSE 固定 `{url}/sse` 与 `{url}/message`；请求同步等待、单次超时 30 秒。参数以空格直拼不转义、无沙箱或工具审批、应用启动与设置页添加服务器可能阻塞界面（见文末）。证据状态：入口确认。来源：[Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)。
- **插件接口**：`PluginContext` 声明 RegisterProvider/RegisterTool/RegisterTabType 接口，加载器可加载 DLL 并创建插件；初始化主链未接通——仓库无接口实现类、加载流程不调用 `IPlugin::Initialize(context)`，插件工具不会进入模型请求（见文末）。证据状态：主链确认（加载主链未接通）。来源：[Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)、[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)。
- **附件、记忆与知识库**：Chat 主链无注入点；后端有文件对话框与 `FILE_ATTACHED` 广播，前端无发送方与监听方，属已实现未接线的死路径（见文末）。证据状态：主链确认（本次未找到）。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)、[应用界面基础设施调查笔记](../应用界面基础设施/Manifold-Desktop-应用界面基础设施调查笔记.md)。
- **ConPTY 集成终端**：独立的人类工具页，有输入、输出、resize 与进程回收链，可启动 cmd/PowerShell；未与模型输出、工具审批或项目事实源形成闭环（见文末）。证据状态：入口确认。来源：[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)。

### 渠道与调度

- **渠道/Provider 模型**：渠道即启动时放入 `ProviderRegistry` 的 `IProvider` 实例；内置 Gemini、OpenAI、Anthropic 为代码固定，Proxy、Ollama 与用户配置的 OpenAI-compatible endpoint 按设置启动时构造。`ProviderConfig` 只保存 endpoint URL 与启用标志，无独立渠道名称、模型映射、Header 集合或多凭据结构。证据状态：主链确认。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。
- **渠道配置生命周期**：查看已注册 Provider、选择模型、保存 API Key、按 endpoint 拉取模型、校验 Key 的运行链路存在；无完整渠道 CRUD——新增/删除 OpenAI-compatible 渠道需手工编辑 `settings.json` 并重启，无复制、渠道级导入导出、运行时启停或独立连接测试 UI，后端 `VALIDATE_KEY` 已实现但设置页无调用按钮（见文末）。证据状态：主链确认。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。
- **凭据存储**：API Key 不写入 settings.json，存于 Windows Credential Manager 的 `Manifold_` + Provider ID generic credential；前端只收到 Key 存在性布尔值，向 `SET_API_KEY` 发送空串即删除凭据。证据状态：主链确认（系统级保护行为未运行验证）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。
- **协议适配与模型目录**：Gemini 用 URL 查询参数带 Key、OpenAI 系用 Bearer Header、Anthropic 用 `x-api-key` + `anthropic-version`；模型目录为 Provider 静态列表（无上下文长度/价格/模态字段）或远端 `/v1/models` 拉取（失败返回占位项）。Ollama 复用 OpenAI-compatible 并按静态路径组合可能产生重复 `/v1/v1/...`（见文末）。证据状态：主链确认（部分路径组合为静态推断）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。
- **调度、并发与取消**：常规聊天单线程串行，Compare 用独立线程组并按 slot 并发；取消依赖 `stop_token` 在流回调处检查，不能主动中断已阻塞的 `WinHttpReadData`，join 可能阻塞 UI 线程。无多 Key 轮询、负载均衡、重试、模型 fallback 或跨 Provider failover（见文末）。证据状态：主链确认（取消效果静态推断）。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)、[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。
- **独立 server/ Proxy 样例**：Express 服务提供 `/health`、`/v1/models`、`/v1/chat` 与按设备 ID 的内存 RPM/日配额路由；`/health` 只检查 Proxy 进程本身，该服务不是桌面端的渠道管理后端，前端 WebView2 页面也不是独立 Web 管理站点。证据状态：入口确认。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。

### 对话导出与分享

- **Markdown 导出**：侧栏会话项悬停显示 "MD" 按钮，整会话导出为 `.md`；输出为标题/Provider/Model/Date 头部 + `### User/Assistant/System` 角色映射 + 正文（取 content 或 text 字段），纯文本无转义、无脱敏。证据状态：主链确认。来源：[对话导出与分享调查笔记](../对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md)。
- **JSON 导入/导出**：JSON 导入已接 UI（首页 Import Session），按文件内 id 保存、缺省生成 `imported-<时间戳>`；导出 handler 实现完整但前端从无发送方（git 历史确认从未接 UI），同 schema 文件可往返但无版本标识（见文末）。证据状态：主链确认。来源：[对话导出与分享调查笔记](../对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md)。
- **导出边界**：无消息级选择、无批量、无预览与编排，唯一载体是本地文件（无链接、无访问控制、无版本历史）；Markdown 不可导入、无往返；失败路径全部静默。证据状态：主链确认。来源：[对话导出与分享调查笔记](../对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md)。
- **导出数据源**：因正常聊天消息不落盘且 `session-store.js` 是死模块，静态推断 MD/JSON 导出对普通聊天会话只输出头部与空消息区（见文末）。证据状态：静态推断。来源：[对话导出与分享调查笔记](../对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md)。

### Chat UI 与界面工作流

- **工作台与多标签**：home/chat/compare/terminal 多标签布局，单 WebView2 窗口；标签类型由 `app.js` 创建，Home 常驻不可关。未发现多窗口机制与侧栏折叠入口。证据状态：主链确认。来源：[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)。
- **Composer 与草稿**：输入栏为全局单例，Enter 发送、Shift+Enter 换行、按字符数/4 估算 token，提示词下拉可选提示词；草稿不持久化，标签切换重建 DOM 时未发送文本丢失（见文末）。证据状态：主链确认（草稿丢失为静态推断）。来源：[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)。
- **流式反馈、滚动与停止**：流式期间 chunk 追加并滚到底、完成时挂 cost badge；停止入口为输入栏 Cancel；关闭标签时若应用级 `appStreaming` 为真弹确认框。无"哪条在运行"的标记，Ctrl+W 直接关闭绕过确认（见文末）。证据状态：主链确认。来源：[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)。
- **快捷键与键盘可用性**：Ctrl+N/T/W/,/K/F/1–9 全局快捷键与搜索浮层方向键/Enter/Esc 导航为静态代码确认，textarea 与按钮带 aria-label。聊天标签实例无 `focus` 方法、切换回聊天标签不会自动聚焦输入框，Confirm 弹窗无 Esc、焦点陷阱与焦点归还（见文末）。证据状态：入口确认（焦点行为为静态推断）。来源：[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)。

### 独特与差异化能力

- **独特功能候选盘点**：README 声明的多 Provider 与统一聊天、安全凭据存储已归并已有类目；双模型并排比较、ConPTY 终端、成本与 token 跟踪为入口确认；MCP Client、DLL 插件系统、会话保存/搜索/导入导出为声明不符（详见文末"已知边界与待验证事项"）。本轮无确认可进入特色贡献统计的独特能力，特色点保持 0。证据状态：候选盘点（按子项标注）。来源：[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)、[特色功能贡献统计](../AI客户端特色功能贡献统计.md)。
- **项目状态与维护**：仓库创建于 2026-03-20，11 个提交集中于约三周后停止；仅 v0.2.0 一个无资产 Release；GitHub Actions 的 5 次 Build Verification 均成功但无自动化测试。状态标记为"长期低活跃，未正式归档，后续维护意图未确认"；CI 编译通过不改变"产品关键流程未闭合"的结论。证据状态：入口确认（远端 API 核对）。来源：[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)。

## 工程与基础设施摘要

- **仓库分布**：本组最小、平台边界最明确的仓库——127 个 Git 跟踪文件、可识别源码 98 文件/35,496 行、文档 5 文件/553 行、本次识别到 0 个测试文件。`Manifold.Core` 占 49 文件/28,939 行（大头为第三方 `json.hpp` 约 24,765 行），`frontend` 31/4,837，另有小型 `server` 区；语言以 C/C++ Header 为主（73.9%）。目标仅 Windows 10+ x64，前端经 WebView2 嵌入，非跨平台浏览器发行。来源：[仓库分布调查笔记](../仓库分布/Manifold-Desktop-仓库分布调查笔记.md)。
- **应用界面基础设施**：极薄 WinUI 3 原生壳 + 无框架 WebView2 前端，原生层只承担窗口、系统对话框、剪贴板与 JSON 消息桥，Toast/确认框/搜索浮层/设置抽屉全部由前端 DOM 与 CSS 实现且无统一 Portal 或层级管理；主题仅 dark/light 两档 37 个 token，无系统跟随、强调色、字体、密度、壁纸或自定义 CSS，浅色与深色边界存在首帧/边缘静态推断风险；系统通知、附件拖放、图片灯箱未实现；窗口状态持久化到 `window-state.json`，DPI 声明 PerMonitorV2。来源：[应用界面基础设施调查笔记](../应用界面基础设施/Manifold-Desktop-应用界面基础设施调查笔记.md)。

## 已知边界与待验证事项

### 声明不符（README/文档声明与当前实现不一致）

- **MCP Client 声明不符**：README 声明工具调用会被执行并回流重发，实际 tool call 只渲染展示，`MCPClient::CallTool()` 全仓库无运行时调用点，`ToolResult`、`maxToolCallRounds` 只有类型或字段定义；`docs/architecture.md` 的多轮工具执行描述与当前代码不一致。来源：[Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)。
- **DLL 插件系统声明不符**：README 声明插件能力，实际 `PluginContext` 无实现类，加载器加载 DLL 后不调用 `IPlugin::Initialize(context)` 便标记为 Initialized，插件工具不会进入模型请求。来源：[Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)。
- **会话保存/搜索/导入导出声明不符**：README 与 `docs/architecture.md:60` 声称 session export/import 与 Markdown export 已实现，实际正常聊天不调用保存模块、前端 `session-store.js` 为无引用死模块、JSON 导出 handler 无 UI 入口；侧栏重命名按整 JSON 覆盖会清空既有消息。来源：[对话导出与分享调查笔记](../对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md)、[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)。
- **请求参数与设置项不生效**：前端发送的 `temperature` 与 `tools` 字段后端不消费（后端取宿主 settings 中的 temperature、tools 只来自 MCP 注入）；设置面板 `streamResponses` 开关在发送路径无读取点，界面开关不改变行为。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)、[Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)。
- **半截实现：附件链路**：后端 `OPEN_FILE_DIALOG`/`FILE_ATTACHED` 已实现（含 base64 读取与广播），前端无发送方与监听方；`GET_SETTINGS`、`FRONTEND_READY` 等消息同为无消费方的空路径。来源：[应用界面基础设施调查笔记](../应用界面基础设施/Manifold-Desktop-应用界面基础设施调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)。

### 暂缓与外部依赖

- 暂缓项：0 项（无证据不足或依赖商业版/外部环境而挂起的能力候选）。
- 外部服务未运行验证：真实 Provider、Ollama、Proxy、OpenAI-compatible 网络请求与 SSE 兼容性、Ollama 路径 `/v1/v1/...` 组合、Windows Credential Manager 系统级保护与卸载清理、第三方插件加载均未运行验证，相关结论以静态源码为据。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)。

### 未覆盖类目

- **独立 CLI/TUI/Web 管理端未覆盖**：本仓库无独立 CLI 入口、参数解析依赖或 TUI 框架，ConPTY 终端只是 Shell 进程管理；无 Web 管理站点。此结论基于仓库内文件结构、依赖与关键词搜索，不排除仓库外发布工具或未纳入快照的脚本。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)。
- **测试树缺失**：仓库分布统计识别到 0 个测试文件；GitHub Actions 只做 NuGet restore、Debug x64 编译与产物上传，无单元/集成/端到端测试。来源：[仓库分布调查笔记](../仓库分布/Manifold-Desktop-仓库分布调查笔记.md)、[独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)。
- **界面机制未覆盖**：无系统通知、托盘、附件拖放、图片灯箱、主题扩展（强调色/字体/密度/壁纸/自定义 CSS/主题导入导出）、右键菜单；Toast 只挂载全局脚本错误路径，系统通知类 README 声明与当前挂接不一致。来源：[应用界面基础设施调查笔记](../应用界面基础设施/Manifold-Desktop-应用界面基础设施调查笔记.md)。

### 共性未验证

- 全部来源笔记为静态源码调查（代码快照 `3d7448fb`），未运行应用。多标签串流下"一个请求更新多个标签"的可见行为、取消延迟与 join 阻塞 UI、路径穿越与恶意会话导入、重命名覆盖清空消息、真实 Provider 网络请求、Compare 并发、ConPTY 终端行为、键盘/焦点/视觉表现与深浅色边界表现均需运行验证。来源：各来源笔记"未验证事项"章节。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/Manifold-Desktop-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/Manifold-Desktop-Chat调查笔记.md)
- [Chat UI 调查笔记](../Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md)
- [LLM 渠道管理调查笔记](../LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/Manifold-Desktop-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/Manifold-Desktop-应用界面基础设施调查笔记.md)
- [消息渲染调查笔记](../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)
- [独特功能与项目状态调查笔记](../独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md)
- [特色功能贡献统计](../AI客户端特色功能贡献统计.md)