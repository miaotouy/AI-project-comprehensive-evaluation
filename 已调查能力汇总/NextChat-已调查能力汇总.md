# NextChat 已调查能力汇总

> 汇总对象：`NextChat`（本地路径 `E:\works\git\NextChat`）
>
> 汇总更新日期：2026-08-18
>
> 依据：13 篇来源笔记（Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态标记并链接来源笔记；未做新的源码调查，未做跨项目横向比较
>
> 汇总范围：覆盖上述 13 个类目中 NextChat 已调查的能力；无未覆盖类目，暂缓项（ShareGPT 第三方依赖）如实列入"已知边界与待验证事项"
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

NextChat 是 Next.js 单页 Web 聊天客户端（Next.js 14 + React + Zustand + SCSS，含 Tauri 桌面壳），核心架构是"客户端 Zustand store + 客户端请求编排 + 单页消息窗口"：模型推理由外部 provider 完成，会话事实源在浏览器本地 IndexedDB（异常回退 localStorage），无服务端 conversation runtime。角色（Mask）、工具（OpenAPI 插件/MCP）、生成输出（Markdown/HTML Artifact）都围绕"消息"这一个中心对象组织，没有独立的 Agent 运行时或输出对象模型。

## 完成度速览

按能力条目统计的证据状态分布（34 条，含 1 条"归并已有类目"指认行）：

- 主链确认：30 项（约 88%）
- 入口确认：1 项（TTS 朗读）
- 归并已有类目：1 项指认（跨会话全文搜索，与主链确认条目为同一能力，不重复计数）
- 声明不符：0 项
- 暂缓：1 项（ShareGPT 会话分享，入口确认）
- 本次未找到（能力边界，非缺陷）：1 项（上下文组装范围）

合计 34 条能力条目，其中主链确认 30 项、入口确认 1 项、归并指认 1 项、暂缓 1 项、本次未找到 1 项。

绝大多数能力已从源码贯通确认，异常与暂缓合计仅 1 项，具体条目见文末"已知边界与待验证事项"。

**口径说明：** 本汇总所有"主链确认/静态源码确认"均基于对当前代码快照的源码贯通，在完整本地主链或源码级实现中视为完成交付态；"未运行验证"仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。NextChat 的会话、工具执行与渲染主链均可从源码贯通到最终输出。

## 功能能力摘要

### 角色与上下文

- **Mask 角色配置**：角色是"提示词、示例上下文、模型参数和插件选择"的组合对象，会话持有完整副本而非引用；用户 Mask 持久化 CRUD，内置 Mask 从 `/masks.json` 异步加载；`syncGlobalConfig` 决定是否跟随全局模型配置，用户改动后转局部配置，无版本继承、父子角色或权限隔离。证据状态：`主链确认`。来源：[Agent 角色配置调查笔记](../Agent角色/NextChat-Agent角色配置调查笔记.md)。

- **Context 示例上下文编辑与发送**：context 是有序 `ChatMessage[]`，编辑器支持增删、拖拽排序、文本/图片示例，请求时直接插入 system prompt 之后；`hideContext` 只隐藏聊天页显示、不提供请求脱敏。证据状态：`主链确认`。来源：[Agent 角色配置调查笔记](../Agent角色/NextChat-Agent角色配置调查笔记.md) §1/§4。

- **上下文拼装与 token 预算**：请求按 system prompt → 长期摘要 `memoryPrompt` → `mask.context` → 短期历史 → 新 user 消息顺序组装；`historyMessageCount` 与 `max_tokens` 双限、token 为启发式估算；`clearContextIndex` 抬高发送起点，错误消息跳过；`hideContext` 不影响发送。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §2、[Chat 调查笔记](../Chat/NextChat-Chat调查笔记.md)。

- **长对话两级压缩与自动标题**：短期窗口（历史条数与 token 预算）+ 长期摘要（`memoryPrompt`，阈值默认 1000 词，按模型系选择摘要模型）；首次达到 50 个估算词自动生成标题；摘要/标题失败只记日志，原始消息从不删除。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §3。

- **输入模板变量展开**：普通输入经 `fillTemplateWith` 展开 `{{input}}`、`{{model}}`、`{{time}}`、`{{lang}}`、`{{ServiceProvider}}`、`{{cutoff}}` 六个变量，缺 `{{input}}` 自动追加；MCP 回注消息跳过模板。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §1/§9。

- **上下文组装范围**：请求上下文固定由 system、记忆摘要、Mask context、短期历史与新消息组装，不包含用户档案或知识库内容。本次未找到档案/知识库字段或注入点（未覆盖边界见末尾小节）。证据状态：`本次未找到`（能力边界，非缺陷）。来源：[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §2/§9、[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §8。

### 会话与消息

- **会话数据模型与持久化**：`ChatSession[]` 内存数组为权威源，IndexedDB 为持久化副本（异常回退 localStorage）；消息是会话内线性数组，无消息树、无版本指针；Chat store persist 版本 3.3，带分版本 migrate；掩码、提示词、插件等各独立 store 各自持久化。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §1/§2/§7、[Chat 调查笔记](../Chat/NextChat-Chat调查笔记.md)。

- **会话 CRUD、fork 与排序**：新建/删除（删除提供 5 秒撤销 toast 并自动补回空会话）/移动排序均作用于数组与持久化 store；`forkSession` 深拷贝整个会话为新会话。本次未找到置顶/归档能力（未覆盖项见末尾小节）。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §3、[Chat UI 调查笔记](<../Chat UI/NextChat-ChatUI调查笔记.md>) §2。

- **消息编辑/删除/重试/置顶**：全部为对会话消息数组的就地变更——编辑改写内容、删除按 id 过滤、置顶 push 进 `mask.context` 参与后续请求；重试=删除原 user 与配对 assistant 后重发（新消息节点）。无独立"续写/继续生成"与回退版本机制（未覆盖项见末尾小节）。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §4、[Chat UI 调查笔记](<../Chat UI/NextChat-ChatUI调查笔记.md>) §6。

- **消息分页窗口**：`CHAT_PAGE_SIZE = 15` 的分页数据接口，初始定位末尾窗口、最多取 3 页，滚动以 15 条步进；消息完整保存在 `session.messages`，是窗口化分页而非 DOM 虚拟化。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §5、[消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md) §1.2。

- **跨会话全文搜索**：侧栏入口的独立搜索页对全部会话消息做内存 `indexOf` 子串扫描，无索引、无分词、大小写归一，命中片段取前后各 35 字符，点击定位到会话级。会话内搜索与消息行级跳转未找到（未覆盖项见末尾小节）。证据状态：`主链确认`（独特功能类目记为 `归并已有类目`，属普通会话检索）。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §5、[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)。

- **多设备同步**：WebDAV/Upstash 云端同步，Chat 按 session id 合并、同会话按 message id 去重，Prompt/Mask/Config/Access 各自合并；无跨标签自动同步。`mergeWithUpdate` 的 remote 时间变量为静态推断的疑似缺陷，细节见末尾小节。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §6、[Chat 调查笔记](../Chat/NextChat-Chat调查笔记.md)。

- **残留消息与未完成输入恢复**：启动/切会话时清理超过 60 秒仍带 streaming 标记的残留消息，空内容标 `isError`；未完成输入按会话 id 存 localStorage 并在重挂载时恢复。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §3/§5。

- **单活动会话与多会话并发**：同一时间仅一个活动会话、单会话单模型，切换经侧栏或快捷键，无分屏/多开；多会话请求并行无全局串行化，停止/重试按会话与消息键控互不干扰。本次未找到发送队列、后台生成、回复完成通知与消息级分支/版本导航（未覆盖项见末尾小节）。证据状态：`主链确认`（界面与并发边界）。来源：[Chat UI 调查笔记](<../Chat UI/NextChat-ChatUI调查笔记.md>) §5/§7、[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §8。

### 生成与创作

- **Markdown 渲染管线**：以 `react-markdown` 为核心，配 remark-math/GFM/breaks 与 rehype-katex/highlight；解析前把 `\[...\]`/`\(...\)` 转 KaTeX 形式并尝试给裸 HTML 补代码块；`PreCode` 提供代码复制与超过 400px 折叠；媒体链接按扩展名内嵌 audio/video。证据状态：`主链确认`。来源：[消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md) §2/§3。

- **Mermaid 渲染**：检测到 mermaid 语言代码块后由 `mermaid.run` 客户端转 SVG，点击可放大查看；失败时返回空内容。证据状态：`主链确认`。来源：[消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md) §3.2、[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) §3。

- **流式文本动画与 thinking 转换**：SSE 文本进 `remainText`，`requestAnimationFrame` 每帧按剩余比例（约 1/60，下限 1）刷入 UI，连接关闭后一次性收尾；`reasoning_content` 或 ` thinking` 标签被转成 Markdown 引用行，无独立 reasoning 数据结构，复制、导出与后续上下文都当作普通 Markdown。证据状态：`主链确认`。来源：[消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md) §4、[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §5。

- **HTML Artifact 预览**：模型自由文本探测（html 语言或 doctype/svg/xml 前缀，600ms 防抖），经 `srcDoc` 注入沙箱 iframe（sandbox 仅 `allow-forms allow-modals allow-scripts`、无 `allow-same-origin`）运行完整 HTML 页面，支持重载、全屏、下载单文件；受全局 `enableArtifacts` 与 `mask.enableArtifacts` 双开关控制；iframe 高度经 postMessage 回传，随机 frame id 匹配、未校验 e.origin。证据状态：`主链确认`。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) 主链、[消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md) §3.3/§5。

- **Artifact 分享与独立路由**：POST HTML 全文到 `/api/artifacts`，服务端以 md5 为 key 写入 Cloudflare KV（可选 TTL），分享链接 `#/artifacts/<md5>` 经独立路由 `/artifacts/:id` 取回并用同一 iframe 重开。依赖 `CLOUDFLARE_*` 环境变量，静态导出或未配置时不可用（推断，细节见末尾小节）。证据状态：`主链确认`。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) §8、[消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md) §5.2。

- **生成式输出对象模型**：模型输出统一落为消息文本并由 Markdown/HTML 渲染，无独立输出对象类型，消息文本是唯一事实源；能力等级判定为 G0 主体 + 部分 G3 预览。无编辑/diff/patch/版本/CRDT，无 notebook、code interpreter、canvas/WebGL 输出对象（未覆盖边界见末尾小节）。证据状态：`主链确认`。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) §1/§6/§11。

- **图片生成（DALL-E 3 与 SD）**：DALL-E 3 在 OpenAI 系 adapter 内改走 images API、结果以 `image_url` 存入消息；SD 是独立 `/sd` 页面画廊，draw 列表持久化 IndexedDB，走 Stability API（Provider 枚举中同名的 Stability 走图片链路而非对话渠道）；两者均为 G1 级可查看/复用内容，无对象生命周期。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §4/§9、[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) §4、[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)。

- **TTS 朗读**：消息头启用时显示朗读按钮，输出为 `audio_url` 消息字段，仅媒体播放，无生命周期治理。证据状态：`入口确认`。来源：[Chat UI 调查笔记](<../Chat UI/NextChat-ChatUI调查笔记.md>) §6、[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) §10。

- **对话导出（文本/图片/JSON）**：两步式 `MessageExporter` 统一三格式，共用逐条消息选择与 includeContext 开关；图片模式用固定品牌版式重新渲染标题、品牌、参与者、模型与消息图片，经 `html-to-image` 生成 PNG，可复制或下载，Tauri 走原生保存对话框；thinking 在导出端不做脱敏，工具调用不进入导出投影。证据状态：`主链确认`。来源：[对话导出与分享调查笔记](../对话导出与分享/NextChat-对话导出与分享调查笔记.md)。

- **ShareGPT 会话分享**：导出预览可一键生成 `shareg.pt/<id>` 链接并在新窗口打开，分享链路已从源码贯通。链路依赖第三方 ShareGPT 平台，属暂缓外部依赖，完整边界见末尾小节。证据状态：`入口确认`（暂缓）。来源：[对话导出与分享调查笔记](../对话导出与分享/NextChat-对话导出与分享调查笔记.md) §4、[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)。

### Agent 运行时与外部协作

- **OpenAPI 插件工具链**：把 YAML/JSON OpenAPI 文档的 operation 转成 OpenAI 风格 function schema 并生成本地执行映射；模型返回 `tool_calls` 后浏览器并发执行对应 HTTP operation，结果包装 `role: tool` 消息回注并 60ms 后递归重发同一 payload；插件由当前会话 `Mask.plugin` 决定，内置插件从 `plugins.json` 加载。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/NextChat-Agent工具调查笔记.md) §1/§2、[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §5/§9。

- **MCP 工具链**：已连接 stdio MCP server 的工具目录经 `getMcpSystemPrompt` 注入 system prompt，模型按 `json:mcp:<clientId>` fenced block 文本协议输出请求，客户端正则提取并经 MCP SDK 执行，结果以 `isMcpResponse` 用户消息回注下一轮；生命周期状态为 undefined/initializing/active/paused/error；工具不受 `Mask.plugin` 过滤，由全局开关与活跃 server 决定。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/NextChat-Agent工具调查笔记.md) §3/§4、[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §7/§9。

- **OpenAPI/MCP 工具执行模型**：OpenAPI 插件与 MCP 调用均在用户会话上下文内由客户端/服务端直接执行并回注结果，执行结果以工具状态区与消息文本展示。执行模型无统一审批、沙箱、权限策略与步数上限，文本协议脆弱性等边界细节见末尾小节。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/NextChat-Agent工具调查笔记.md) §2.3/§5。

### 渠道与调度

- **LLM 渠道模型**：渠道是代码内固定 `ServiceProvider` 枚举 + Access store 单一配置槽位；同一 Provider 只能有一份 endpoint/凭据，无命名 profile、多端点、渠道级新增/复制/删除/独立启停（未覆盖项见末尾小节）。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) §1/§6。

- **配置生命周期与 Web 设置页**：设置页可查看/编辑当前 Provider 的 URL、key、版本等字段并切换 Provider；`useCustomConfig` 是全局自定义配置开关；备份导出收集多个 store 非函数状态（含 Access store 凭据）；App 构建强制自定义配置。无统一连接测试（Check 按钮测试的是 WebDAV/Upstash 云同步），未找到 CLI/TUI 与独立渠道配置文件（未覆盖项见末尾小节）。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) §2/§8。

- **请求路由与代理边界**：Web 默认经 Next.js `/api/...` 代理（可注入服务端 key、限制模型、转发流），App/export 直连 Provider 官方 base URL 或用户自定义 URL；Tauri Rust 层只注册流式请求命令，不承担渠道管理或凭据服务；Header 按会话 provider 组装认证头。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) §3/§6、[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §4。

- **模型目录与路由**：`DEFAULT_MODELS` 静态表 + 首页 adapter `models()` 动态合并 + `CUSTOM_MODELS` 自定义增删启停；模型完整身份为 `model@provider` 用于消歧义；无别名、权重、负载均衡或跨 Provider 自动选择（未覆盖项见末尾小节）。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) §4/§6。

- **多 key 与故障转移**：服务端环境变量中的逗号分隔 key 读取时随机选取，请求侧具备 AbortController 与请求级超时。无轮询计数、失败冷却、熔断或健康状态持久化，无跨 Provider failover 或模型 fallback（未覆盖项见末尾小节）。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) §7。

### 独特与差异化能力

- **独特功能反向盘点结论**：按代码路由反向盘点确认 Mask、Artifact、OpenAPI 插件、MCP（含 MCP 市场页）、SD 图像面板与 Artifact 分享均已由现有类目闭环覆盖；无候选达到主链确认且未归类，不新增特色贡献。证据状态：`主链确认`（反向盘点）。来源：[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)。

- **会话全文搜索页（归并）**：侧栏入口的独立搜索页，对全部会话消息做内存全量子串扫描并回显片段。证据状态：`归并已有类目`，已归并到会话与消息管理类目（会话检索），不重复计数。来源：[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §5。

> 独特功能类目对特色贡献统计的影响：无新增特色贡献；ShareGPT 分享保留为入口确认/暂缓状态，供"外部 Agent 协议/社交分享"类聚类参考，划分详见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 工程与基础设施摘要

- **仓库分布**：NextChat 是紧凑的单应用仓库——Next.js Web/PWA 为主体，`src-tauri` 提供 Tauri 桌面封装，iOS 源码未在本仓公开。Git 跟踪 425 个文件，可识别源码 220 文件/48,347 行，`app` 占约 96% 源码行（`app/components` 与 `app/locales` 为最大区域，语言包显著影响量级）；TypeScript 占 88.3%、SCSS 10.4%；文档 29 文件，测试 34 文件集中在根 `test`，量级较小。统计为 Git 跟踪文件的机械统计，未运行构建与测试。来源：[仓库分布调查笔记](../仓库分布/NextChat-仓库分布调查笔记.md)。

- **应用界面基础设施**：零组件库，弹窗、确认框、输入框、Toast、图片弹窗均在 `ui-lib.tsx` 自研，命令式调用每次新建 DOM 节点与 React root，无公共 Host、队列、单例浮层或 Provider 树/portal；主题三态（auto/light/dark）由应用配置 store 持有并持久化，视觉定制仅限字号与字体，无主色、壁纸、自定义 CSS 或主题导入导出；响应式为 600px 单断点，桌面侧栏可拖拽调宽、移动端为 CSS 抽屉；PWA 非离线壳（Service Worker 只服务 `/api/cache` 图片通道），图片上传走 SW 缓存通道 + 本地 canvas 压缩兜底；Tauri 层保持薄封装（流式请求桥、拖窗区域、窗口状态插件、系统通知仅用于应用更新，无托盘/原生菜单/多窗口）；错误边界带错误栈、报错跳转与清空数据入口；无焦点陷阱、无 Tooltip/ContextMenu 公共机制。来源：[应用界面基础设施调查笔记](../应用界面基础设施/NextChat-应用界面基础设施调查笔记.md)。

## 已知边界与待验证事项

### 声明不符

- 未发现"介绍声明与实现不符"的候选：README 以部署与企业版为主，未声明其他独特产品工作流；反向盘点确认 Mask、Artifact、OpenAPI、MCP、SD 等产品面均已由现有类目闭环覆盖。证据状态：`无`。来源：[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)。

### 暂缓与外部依赖

- **ShareGPT 会话分享（暂缓）**：入口为导出预览面板的 Share 按钮，经 `ClientApi.share`（基类单实现、与 Provider 无关）上传——Web 经 `next.config.mjs` 的 `/sharegpt` rewrite 转发、Tauri 直连 ShareGPT，返回 `shareg.pt/<id>` 链接；请求无认证头、末尾强制追加"Share from NextChat"溯源消息；无撤销/删除/过期/更新路径，创建结果不本地持久化；文档/README 未提及该能力，链路依赖第三方平台可用性与数据策略；静态导出部署下 rewrite 不可用（推断），端到端流程未运行验证。证据状态：`入口确认`（暂缓）。来源：[对话导出与分享调查笔记](../对话导出与分享/NextChat-对话导出与分享调查笔记.md) §4、[独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)。

- **Artifact 分享的外部依赖**：Cloudflare KV 存取依赖服务端环境变量（`CLOUDFLARE_ACCOUNT_ID`、`KV_NAMESPACE_ID`、`KV_API_KEY`、`KV_TTL`），未配置或静态导出（`buildMode=export`）时分享不可用（推断，未运行验证）。证据状态：`主链确认`（依赖外部服务）。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) §8。

- **多设备同步疑似缺陷**：`mergeWithUpdate` 的 remote 时间变量取成了 `localState.lastUpdateTime`，远端时间戳不参与比较，本地时间戳非 0 时远端状态永不胜出（静态推断疑似实现缺陷，未在 WebDAV/多设备流程复现）。证据状态：`主链确认`（含静态推断缺陷）。来源：[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §6。

- **工具执行模型边界**：OpenAPI 插件 HTTP 与 MCP stdio 调用无统一审批、沙箱、权限策略或 Agent 步数上限；插件认证 token 进入客户端持久化、MCP 子进程继承整个 `process.env`；arguments 直接 `JSON.parse`、未知函数名无存在性检查；MCP 文本协议依赖正则与完整 fenced block，多调用/未闭合 block/非法 JSON 只记录错误，无结构化恢复，重发收敛依赖 60 秒请求级 abort。证据状态：`主链确认`（边界）。来源：[Agent 工具调查笔记](../Agent工具/NextChat-Agent工具调查笔记.md) §2.3/§5。

### 未覆盖类目与未找到的能力

- 未覆盖类目：无——13 个类目均有来源笔记，全部纳入本次汇总。
- 未找到的能力（`本次未找到`，非项目级否定）：发送队列与排队 UI、后台生成、续写入口、回复完成通知；消息级分支/版本导航、会话置顶/归档；用户档案与知识库注入；LLM 渠道的 CLI/TUI、独立渠道配置文件、统一连接测试、跨 Provider 故障转移；文件拖放、聊天图片灯箱。来源：[Chat UI 调查笔记](<../Chat UI/NextChat-ChatUI调查笔记.md>) §5/§7、[对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) §7/§8、[会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md) §3、[LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) §2.4/§7、[应用界面基础设施调查笔记](../应用界面基础设施/NextChat-应用界面基础设施调查笔记.md) §6。

### 共性未验证

- 全部结论基于静态源码；真实模型调用、SSE 断线重试、Mermaid/Artifact iframe 运行表现、Tauri 桌面行为、跨窗口/多标签同步、token 估算偏差、大数据量性能、无障碍与视觉运行态均未运行验证；各来源笔记"未验证事项"章节逐项列明。这些"未验证"仅为方法学约束，不否定已确认的源码完备性（口径见"完成度速览"）。
- 调查日期与代码快照：各来源笔记均基于提交 `defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支 `main`）；调查更新日期为 2026-08-12 至 2026-08-18，以来源笔记元数据为准。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/NextChat-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/NextChat-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/NextChat-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/NextChat-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/NextChat-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/NextChat-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/NextChat-会话与消息管理调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/NextChat-对话导出与分享调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/NextChat-应用界面基础设施调查笔记.md)
- [消息渲染器调查笔记](../消息渲染器/NextChat-消息渲染器调查笔记.md)
- [独特功能调查笔记](../独特功能/NextChat-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md)
- [特色功能贡献统计](../AI客户端特色功能贡献统计.md)