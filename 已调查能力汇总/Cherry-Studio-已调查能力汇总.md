# Cherry Studio 已调查能力汇总

> 汇总对象：`Cherry Studio（https://github.com/CherryHQ/cherry-studio）`
>
> 汇总更新日期：2026-08-18
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、媒体创作、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时共 15 份单项目调查笔记（代码快照均为 `cd82f996fb6c3a523b6d40de31314f2b86f56281`，main 分支）；另引用 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)
>
> 汇总方法：阅读各来源笔记的"结论摘要"与关键章节，按功能主题合并重复能力，保留来源笔记的证据状态与边界表述，逐条链接来源；未进行新的源码调查
>
> 汇总范围：覆盖上述 15 个类目中与 Cherry Studio 相关的全部已调查能力；仓库分布、应用界面基础设施的结论单列于"工程与基础设施摘要"；不做跨项目横向比较，不填写其他项目的能力空格
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Cherry Studio 是 Electron 桌面聊天客户端（React + Tailwind 渲染层、Node + SQLite 主进程、AI SDK 出网），TypeScript monorepo。产品表面分 Home（普通会话）与 Agent（Claude Code SDK 代理会话）两个入口，共用同一套"会话壳 + Composer + 消息列表"框架，以适配器注入差异。会话单位是 Topic，消息是 adjacency-list 树；一次生成由渲染层构建请求、主进程 `AiStreamManager` 集中编排；Agent 侧把 Claude Agent SDK runtime 作为独立会话执行者接入，另有六平台 IM 渠道作为外部控制表面。核心数据与运行状态都在主进程（SQLite + 状态机），渲染层以 SWR 缓存投影 + 流式 overlay 呈现。

## 完成度速览

| 证据状态 | 条目数 |
| --- | ---: |
| 主链确认（含"静态走通 / 静态证据 / 代码已确认"表述） | 21 |
| 静态源码确认（入口与状态级） | 8 |
| 归并已有类目 | 3 |
| 入口确认 | 0 |
| 声明不符 | 0 |
| 暂缓（能力条目） | 0 |
| 合计 | 32 |

全部 32 条功能能力条目均有正向证据状态：主链确认占比约六成半（21/32），加上静态源码确认后不存在"无证据"的能力条目；无声明不符、无暂缓能力条目，异常与边界集中在文末"已知边界与待验证事项"小节。

**口径说明**：本汇总所有"主链确认 / 静态源码确认"均基于对当前代码快照的源码贯通，在编译型桌面应用或完整本地主链中视为完成交付态；"未运行验证"仅指未进行黑盒运行、UI 或端到端操作，不否定代码完备性。以下正文中不再逐条重复该口径，只在与具体能力相关的边界处作一句带过。

## 功能能力摘要

### 角色与上下文

- **Assistant 助手配置体系**：角色核心对象是 Assistant，一套"模型 + 提示词 + 推理参数 + 工具源（`mcpServerIds`/`knowledgeBaseIds`/`modelId`/`groupId`）"的稳定配置；`AssistantSettings` 用 `enable*` 标志区分"存了但不用"与"发送给 API"，并支持 `customParameters` 透传 provider 专有参数。会话只存 `assistantId` 引用，每次请求按 id 重读助手（运行时引用语义），消息侧只冻结 `messageSnapshot` 快照；内置仅一个空提示词 Cherry 助手，另有资源目录市场模板与内置 cherry-assistant Agent 两套体系。证据状态：静态源码核对。[Agent 角色配置调查笔记](../Agent角色/Cherry-Studio-Agent角色配置调查笔记.md)

- **系统提示词装配与上下文来源注入**：`assembleSystemPrompt` 依次做变量替换、追加延迟工具命名空间目录与引用格式契约段；四类输入组织方式不统一——文件/知识库以消息 parts 表达（知识库范围是 `data-knowledge-scope` part、清理边界是 `data-clear` part）、联网搜索是 assistant 设置布尔开关、推理强度是独立请求字段、工具是否携带由主进程按模型能力判定。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/Cherry-Studio-Agent角色配置调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) 第 9 节

- **历史选择、模型消息整形与上下文压缩**：`resolveCompactedHistory` 沿锚点取活动路径、丢弃最近 `data-clear` 标记前的记录；`toModelMessages` 统一整形（重放持久化工具输出、规范化 MCP 工具名、剔除模型不支持媒体、合并相邻同角色消息、空 assistant 补 `'...'`）。压缩以所有模型 `contextWindow` 最小值为窗口触发，成功把摘要持久化到 `compactionSummary` 列，失败以 `skipped` 结算且不留时间线锚点；树结构本身不被修改。证据状态：主链确认（静态源码）；触发阈值属运行参数，见末尾小节。[对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) 第 2、3 节

### 会话与消息

- **会话与消息数据模型（Topic + 消息树 + 分支语义）**：会话单位 Topic 存 SQLite；消息是 adjacency-list 树（`parentId` 自引用外键 + `siblingsGroupId` 兄弟组），虚拟根由 CHECK 约束与唯一索引强制（每 topic 恰一根）；"切分支"是把 `activeNodeId` 指针重定向到目标分支叶子，不重排树，前端每次从指针反向 walk 到根；分支草稿是持久化的空 user 叶子（`reserveBranch`/`fill-reserved`），不再有渲染层假节点。删除语义收敛为"splice 保留可达历史"（首轮可删、多模型组删除只删兄弟回复），附件经 `chat_message_file_ref` 引用计数 + FileManager 策略化回收。证据状态：静态源码确认（`message-tree.md` 文档与实现一致）。[会话与消息管理调查笔记](../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/Cherry-Studio-Chat调查笔记.md)

- **多模型并行回复**：Composer 里 @模型 多选 → 主进程在同一事务建 1 条用户消息 + N 条 assistant 占位（共享 `siblingsGroupId`），随后 N 个 execution 真并行各自流式写各自占位行，读侧按兄弟组横向/网格展示，顶部有 `< i/N >` 兄弟导航。这是"同一问题并行比较显式选择的模型"，不是失败后候补链；steer 续答与临时聊天只取第一个模型。证据状态：主链确认（静态源码）；独特功能类目标记为"归并已有类目"。[对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) 第 8 节、[LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) 第 6 节、[Chat UI 调查笔记](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>) 第 7 节

- **消息列表渲染与流式 UI**：一套 `MessageListProvider` 契约由 Home/Agent 两适配器注入能力（可写操作有无决定按钮是否出现）；virtua 虚拟列表 + 历史层/live 层隔离；流式 overlay 是窗口级 `ExecutionStreamOverlayService`（按帧批量提交、结构共享、组件卸载不拆 reader）；parts 经 `MessagePartsRenderer` 投影为正文/思考/工具/附件/图片/视频/错误/翻译/压缩块。Markdown 走白名单净化（禁 iframe/script/inline handler、SVG 限元素），正文与 HTML artifact 预览的净化管线分离；流式正文有自适应 jitter buffer 平滑播放。证据状态：静态源码确认（大量组件测试）；视觉表现属运行验证项，见末尾小节。[消息渲染调查笔记](../消息渲染器/Cherry-Studio-消息渲染调查笔记.md)、[Chat 调查笔记](../Chat/Cherry-Studio-Chat调查笔记.md)

- **会话内搜索与全局搜索（双轨）**：会话内搜索是"已加载数据粗匹配 + 已挂载 DOM 精确 Range + CSS Custom Highlight 高亮"，流式行排除、虚拟化窗口外可定位但未加载页搜不到（分页固有限制，非 bug）；跨会话全局搜索走主进程持久化 FTS5（trigram）内容索引 + 联邦实体搜索（topic/assistant/agent/session/knowledge），`app.search` 命令打开，命中定位到消息并跳转 Topic。证据状态：主链确认（独特功能能力卡 2）。[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>) 第 2.3 节、[会话与消息管理调查笔记](../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md) 第 5 节

- **对话图片导出**：Topic/单消息两级 PNG 复制与保存，以"离屏复刻真实消息列表"为核心，两条捕获路径（action bus 驱动的离屏宿主 vs 事件默认处理器的 live 隐藏表面）共用同一捕获工具，html-to-image 转单张 Canvas；分支取舍在数据投影层（用户分支只留 on-path、助手按模型桶坍缩单气泡）；单 Canvas 无拼接，任一边超 32767px 显式拒绝；无分享稿编辑、无远端分享、无选区/水印/品牌条。证据状态：主链确认（静态走通）；捕获边界细节见末尾小节。[对话导出与分享调查笔记](../对话导出与分享/Cherry-Studio-对话导出与分享调查笔记.md)

- **消息级流式翻译**：消息操作栏"翻译"经独立 IPC 启动流式翻译，成功时剥离旧 `data-translation` part 并追加新 part（记录目标/源语言），译文作为消息的一部分持久化、可重译覆盖，取消即丢弃；另有 translateHistory 表与语言目录。证据状态：主链确认（独特性中等）。[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md) 能力卡 3

- **会话自动命名（两阶段）**：第一条用户消息落库后先用原文截断出临时标题，首轮回复完成后用 AI 生成摘要标题替换；`isNameManuallyEdited` 手动改名后永久停止自动命名；标题生成请求刻意不携带 `assistantId`，避免把助手工具配置挂到标题请求上。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md) 第 3.2 节

- **停止、重试、续写、重新生成与编辑**：停止经 IPC `ai.stream.abort` → `AbortController` → AI SDK 请求 signal（网络层已接线）；`trigger='continue-conversation'` 复用原 assistant 行续流，审批决定写回 parts 后恢复；regenerate 继承源回复模型与 turnOptions，live 期间被拒；编辑用户消息可"仅保存"（PATCH parts）或 `forkAndResend` 建兄弟行重发；半截流以 `paused` 持久化、工具审批等待中的打断终态化为 `output-error`。证据状态：主链确认（静态源码）；取消效果属运行验证项，见末尾小节。[对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) 第 6、7 节

- **数据备份、恢复与崩溃收口**：启动时 boot reconcile 把遗留 `pending` assistant 行翻为 `error`，避免 UI 永久"思考中"；备份恢复期间用 `pause`/`drainInFlight` 写安静期门禁新 turn 并等待在途持久化落盘；备份引擎 v7 full/slim 布局都包含 `cherrystudio.sqlite`（含凭据），恢复经 checkpoint + 崩溃安全 promotion 原子替换。证据状态：主链确认（静态源码）；恢复端到端行为见末尾小节。[会话与消息管理调查笔记](../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md) 第 3.5 节、[对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) 第 10 节、[LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) 第 3.4 节

### 生成与创作

- **媒体创作绘画工作台**：用户主导、模型能力目录驱动的图像生成工作站（能力分型 M1 主 + M3 资产生命周期 + M5 Agent 驱动创作边界）。每次生成写 `painting` 收据行（冻结 provider/model/prompt）+ `painting_file_ref` + v2 `file_entry`，可变参数只活在渲染内存草稿；执行全在 main（同步 AI SDK 与异步 submit/poll job 双路径，job 非重启持久、崩溃即弃）；`generate_image` 工具走同一核心但 `cleanupPolicy: 'manual'`、不写 painting 行。聊天→绘画有导航入口。证据状态：主链确认（静态走通）；真实模型与 job 运行项见末尾小节。[媒体创作调查笔记](../媒体创作/Cherry-Studio-媒体创作调查笔记.md)

- **聊天内 HTML Artifact**：模型以 Markdown 文本或裸 HTML 输出，前端内容探测分类 document/fragment——片段恒进无脚本 iframe（严格 CSP），完整文档经用户同意后进入独立沙箱 webview（主进程强制沙箱/上下文隔离、DNS 级 SSRF 防护、无 IPC 桥）；对象可整段重写保存回消息正文，可下载/外部打开/PNG 截图。无独立 part 类型与对象 ID（身份为按 Markdown 位置派生的临时 ID），回流靠"会话历史重入"。证据状态：主链确认（静态走通），能力等级 G3。[生成式输出与运行时调查笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)

- **Agent 工作区文件（G4 可编辑工作区）**：Claude Code SDK 以会话工作区为执行目录，产物即磁盘文件；`report_artifacts` 工具声明作为投影到消息卡片与右侧面板（实时文件树 watcher + 文件预览 + 防抖自动保存 + 乐观锁写时冲突检测），用户编辑后的磁盘文件在下一回合被模型经文件工具自然回流；无 CRDT、无对象级版本历史。证据状态：主链确认（静态走通），能力等级 G4。[生成式输出与运行时调查笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)

- **Python 代码执行**：代码块"运行"仅对 python 生效，偏好默认关闭；开启后经 Pyodide Web Worker（渲染进程内、Wasm 沙箱）执行，结果文本/图片显示在代码块状态栏、不持久化；主进程侧另有 Python 服务经 IPC 桥接同一 worker 供 MCP `python_execute` 工具调用，该调用链跨越六层，执行沙箱边界落在 Wasm + Web Worker。证据状态：静态源码确认（入口/状态/事件绑定）；Worker 桥接细节见末尾小节。[生成式输出与运行时调查笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)、[应用界面基础设施调查笔记](../应用界面基础设施/Cherry-Studio-应用界面基础设施调查笔记.md)

### Agent 运行时与外部协作

- **Agent Session（Claude Code SDK 运行时）**：`AgentSessionRuntimeService` 把 Claude Agent SDK 作为独立会话执行者接入，覆盖工作区、独立消息持久化后端（`AgentSessionMessageBackend`）、流事件、工具审批与取消；`ClaudeCodeRuntimeDriver` 以 cwd=workspace 调 SDK `query()`，原生工具（Bash/Read/Write/...）由 SDK 子进程执行，Cherry 通过禁用名单、使用权限判定与 PreToolUse hook 三层控制，不持有执行本身。证据状态：主链确认（静态证据）；SDK 级运行行为见末尾小节。[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Cherry-Studio-外部执行体与应用协作调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)

- **Agent 工具体系（双路径）**：普通聊天 MCP 路径（`McpRuntimeService` 管理用户配置的 stdio/SSE/Streamable HTTP/OAuth/in-memory server，工具经 `syncMcpToolsToRegistry` 注册进 AI SDK 工具表，按 `scope.mcpToolIds` 过滤）与 Claude Code Agent 路径（声明式 `toolRegistry.ts` 定义每个 SDK 原生工具与进程内 MCP 工具的 `exposure`：user/internal/disabled）各自独立、共享 MCP 运行时与审批 UI。进程内 MCP（cherry-tools/agent-memory/assistant/skills）在主进程直接函数调用；执行域全部落在 Electron 主进程，Bash 等原生工具无通用命令沙箱；工具 id 双轨制（legacy 名称型 + AI SDK catalog 哈希型）消除碰撞面。证据状态：代码已确认（静态源码）。[Agent 工具调查笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)

- **工具审批与安全边界**：普通聊天 MCP 走 AI SDK 原生 approval 状态机、决定持久化到消息 parts；Claude Code 走内存 `toolApprovalRegistry` 快路径（IPC 方法名共享、主进程分发不同）。权限模式优先级：MCP server 级强制提示 > bypassPermissions > acceptEdits > 默认安全工具 > prompt；always allow 仅 MCP 路径可持久化，Claude Code 原生工具每次调用都要逐次审批。路径校验 `workspacePathHook` 只覆盖六个结构化字段、Bash 命令文本不校验（源码注释确认刻意为之）；模型无法伪造真正可点击的审批卡片，但可在正文输出形似审批的文本造成社会工程学混淆。证据状态：代码已确认（静态源码）；待验证项见末尾小节。[Agent 工具调查笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md) 第 7、12、14 节

- **IM 渠道六平台（外部控制表面）**：discord/feishu/qq/slack/telegram/wechat 六平台经 `ChannelManager` 与渠道行接入，入站消息可启动 Agent Session 运行并流式回投，`/new` 等斜杠命令控制会话；协议兼容 OpenClaw 家族（Feishu 设备码注册、WeChat 双编码）；自带外部内容/工作区文件/输出消毒三层不可信输入防护；渠道会话在审批闸门里按 background agent 处理（常规工具父 turn 结束后自动放行），系统安全提示只是软性文本约束。证据状态：主链确认（静态证据）；逐平台往返属运行验证项，见末尾小节。[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Cherry-Studio-外部执行体与应用协作调查笔记.md)

- **宿主自身作为工具面（assistant MCP）**：Cherry 把宿主暴露给外部 runtime——`assistant` MCP 提供页面导航（路由白名单）、产品信息、创建 Agent、应用设置等工具；仅在本地 Cherry Assistant 会话注入（外部渠道会话不注入）；`diagnose` 可读本机日志/源码/配置，被刻意排除在自动批准之外。证据状态：主链确认（静态证据）。[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Cherry-Studio-外部执行体与应用协作调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)

### 渠道与调度

- **LLM 渠道管理（Provider + Endpoint Type + Adapter Family）**：一条渠道 = SQLite 中一条 `user_provider` 行；内置 Provider 由 provider-registry 预设 insert-only seed，用户配置只存差量、读取时合并。同一 Provider 可声明多个 Endpoint Type（OpenAI Chat/Responses、Anthropic Messages、Gemini GenerateContent 等），各自有独立 Base URL 与 adapterFamily，模型可覆盖默认文本端点；预设可复制为多个独立渠道实例。凭据管理较完整：多 API Key（跨请求 round-robin，无失败计数/熔断/自动恢复）、OAuth/IAM 统一进 `authConfig`，Renderer 拿不到真实秘密，但 SQLite 明文落盘、无静态加密。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md)

- **模型目录与选择**：模型稳定标识是 `providerId::modelId` 二元组合，运行时不会只凭裸模型名猜测渠道；模型目录由 Registry 生成流水线（手工声明 + models.dev/OpenRouter 实时合并）提供，运行时三层覆盖（用户差量 > provider-models 覆盖 > 基础模型定义）；元数据直接参与请求（Adapter 选择、reasoning 档位、参数限幅、contextWindow 传递），也影响 UI 展示与 wire protocol。证据状态：静态源码确认。[LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) 第 5 节

- **重试、容错与网络**：SDK 层普通聊天默认不重试（`maxRetries ?? 0`）；`chat.retry.*` 提供用户可配置的同模型重试 + 能力过滤的 fallback 模型，但默认关闭且请求级 `maxRetries: 0` 会显式关闭包装；无渠道权重/优先级/成本/延迟路由；健康检查（单 Provider 与批量模型+Key）只做即时诊断、结果不参与运行时调度；网络层复用 Electron 应用代理。证据状态：主链确认（静态源码）；"SDK 默认不重试、默认无跨 Provider failover"是已确认边界。[LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) 第 8 节

- **任务排队与并发调度**：主进程 steer 队列（流式期间后续发送落用户行入队、回合边界让出、done 后调度续答，aborted/error 后丢弃）与渲染层 follow-up 队列（topic 空闲自动 drain）两层；发送有 `draft/persisting/opening/streaming/ready` 阶段机；`dispatchLock` 只序列化"准备+启动"窗口；渲染层组件卸载 release 视图但不拆 reader、不 abort，主进程可后台继续生成，grace-period 驱逐（默认 30 秒）。证据状态：主链确认（静态源码）；运行行为验证项见末尾小节。[对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) 第 8 节、[Chat UI 调查笔记](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>) 第 5 节

- **配置导入与渠道管理入口边界**：Provider deep link 导入（确认后按 ID 新建或更新端点并追加 Key）；完整 CRUD 只在桌面端设置页（查看/新增/编辑/复制/启停/删除/连接检查）；Code CLI 功能可读写外部 CLI 配置文件，但那是"把当前 Provider 注入外部 CLI"，不是 `user_provider` 的替代存储。证据状态：静态源码确认（"未找到"项按本次搜索范围表述，见末尾小节）。[LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) 第 1.4、9 节

### 独特与差异化能力

- **Mini Program（应用门户）**：在客户端内以独立标签页运行 60+ 预设与自定义第三方 Web 应用（webview），带 keep-alive 池与 Launchpad/侧栏入口、区域过滤、共享缓存 transient descriptor；预设行差量覆盖、自定义行全量落 SQLite。无协议桥、无模型上下文回流，纯 Web 门户 + 标签管理，是样本中唯一形成完整主链的"应用门户"能力。证据状态：主链确认。贡献统计建议：主贡献。[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md) 能力卡 1、[特色功能贡献统计](../AI客户端特色功能贡献统计.md)

- **多模型同时对话**：已归并到已有类目（LLM 渠道管理 §6 与 Chat UI §7 已主链确认，见"会话与消息"集群的"多模型并行回复"条目）。证据状态：归并已有类目。[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)

- **文档处理**：已归并到已有类目（附件/OCR/知识库链由会话与消息管理、对话请求与上下文、Agent 工具笔记覆盖）。证据状态：归并已有类目。[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)

- **Agent workspace**：已归并到已有类目（Chat UI §6.2 与 Agent 工具笔记覆盖，见"生成与创作"集群的"Agent 工作区文件"条目）。证据状态：归并已有类目。[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)

- **桌面集成与通知**：托盘按系统明暗切换图标、点击行为可配置（唤起 QuickAssistant 或主窗口），系统通知经 Electron 原生 API、点击唤起主窗口，快捷键本地/全局分轨注册；已确认边界：托盘无未读/流式角标，Agent Session 列表无拖拽排序。证据状态：静态源码确认（空挂钩，见末尾小节）。[Chat UI 调查笔记](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>) 第 8.2 节、[应用界面基础设施调查笔记](../应用界面基础设施/Cherry-Studio-应用界面基础设施调查笔记.md)

- **无障碍与键盘路径**：Topic/Session 列表有完整 listbox 语义（roving tabindex + `aria-activedescendant`，有测试覆盖）；消息操作栏按钮带 `aria-label`；会话内搜索/输入历史/变量遍历等键盘主链已确认。已确认边界：Composer 输入区本体无可访问名称、分支树图键盘导航未核实（见末尾小节）。证据状态：静态源码确认；视觉与读屏表现属运行验证项，见末尾小节。[Chat UI 调查笔记](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>) 第 9 节

## 工程与基础设施摘要

- **仓库分布**：TypeScript monorepo（98.5% TypeScript），Electron 主应用与内部共享包合仓。主进程 `src/main` 432,627 行、renderer `src/renderer` 495,622 行、`packages/ui` 80,009 行，另有 provider-registry 与 AI core 两个约 1.8 万行的内部包；测试与实现大面积共置，测试源码约占总源码 45.4%。桌面端同一 Electron 主应用覆盖 Windows/macOS/Linux（x64/arm64 分别打包），无本仓独立移动端入口；`v2-refactor-temp` 源码已清空、仅剩文档与工具。证据状态：Git 跟踪文件机械统计 + pnpm workspace/构建配置复核。[仓库分布调查笔记](../仓库分布/Cherry-Studio-仓库分布调查笔记.md)

- **应用界面基础设施**：界面栈为 React + Tailwind（+ tw-animate-css），内部 UI 包 `@cherrystudio/ui` 基于 Radix 生态（无 antd/framer-motion/sonner）。弹窗主路径迁到 UI 包（Radix Dialog 封装 + 模块级 popup store + 每窗口 PopupHost，命令式调用，single-flight）；Toast 是自研单例 store（loading→success/error promise 桥接，按严重程度区分 aria 语义）；主题权威在主进程 ThemeService，视觉 token 分层契约（foundation → runtime input → 官方 Shadcn 语义 → 产品语义 → Tailwind 生成层），用户可设明暗/单主色/字体/自定义 CSS，无主题市场/壁纸/主题文件导入导出；右键菜单可在自绘与系统原生双模式间切换；错误边界分窗口/路由/消息块三层（react-error-boundary），另有崩溃遥测与 render-process-gone 自动 reload。证据状态：静态源码核对（键盘与多窗口表现需运行验证，见末尾小节）。[应用界面基础设施调查笔记](../应用界面基础设施/Cherry-Studio-应用界面基础设施调查笔记.md)

## 已知边界与待验证事项

### 声明不符

- 来源笔记中无"声明不符"项。独特功能笔记的"声明不符、外部依赖与暂缓项"一节实际只含暂缓与外部依赖；README 功能声明（Global Search、Mini Program、AI 翻译、多模型同时对话）均与代码相符，无"README 宣称但实现缺失"的记录。

### 暂缓与外部依赖

- README Roadmap 的 Notes/Canvas/OCR/TTS/插件系统/ASR 属愿景清单，未做存在性断言（独特功能笔记标记"暂缓"）。
- 全局搜索的知识库命中依赖知识库索引新鲜度（`features/knowledge/query/search.ts`），未验证。
- 小程序 webview 实际加载、区域过滤可用性、keep-alive 内存占用、多窗口间 transient descriptor 同步未运行验证。
- 翻译的语言目录完整读写链与模型选择未展开核对。
- 技能安装（`SkillService.install`）对下载内容的校验（签名/来源/恶意内容扫描）未展开；Skill 的信任模型等价于"信任其文本对模型的引导力"，非代码执行沙箱（Agent 工具笔记确认）。
- `mcpAutoInstall` 元工具允许模型触发 `npx` 拉取并执行任意 npm 包（供应链风险，来源笔记确认，非 bug）。
- 第三方 in-memory/HTTP server（didiMcp/nowledgeMem/flomo）的具体工具清单与数据流向未展开。
- WebDAV 属外部服务，未在本次范围展开（独特功能笔记"文档处理"归并项）。
- 远端图片在导出捕获时未加载完成/CORS 失败、`mcpAutoInstall` 之外的外部 CLI 是否按各自版本接受生成的配置文件，均未验证。

### 未覆盖类目

- 本工作区无其他 Cherry-Studio 类目来源笔记；横向对比文档未纳入本次汇总。全部 15 份来源笔记均存在、结论摘要均可识别。
- 各来源笔记明确"本次未找到"的项（按搜索范围表述，不构成项目级绝对结论）：绘画页无像素编辑、分支/版本、任务中心、"绘画→聊天插入"入口（媒体创作）；"助手回复完成"通知开关无 `source:'assistant'` 触发点（空挂钩）、无快捷键速查浮层、Agent Session 列表无拖拽排序（Chat UI）；Provider 专用 JSON/YAML 导入导出、Cherry 自身 CLI/TUI/Web 渠道 CRUD（LLM 渠道管理）；渲染进程无全局 window.onerror/unhandledrejection 兜底、HTML artifact 预览 webview 崩溃处理未找到（应用界面基础设施）；chat 主界面右 pane 无 artifact 面板、agent 会话消息中的代码块不可编辑、mindmap/思维导图组件未找到（生成式输出与运行时）；Composer 输入区本体无可访问名称、分支树图键盘导航未核实（Chat UI 无障碍）。
- 各笔记超出范围项：媒体创作笔记不覆盖 Mini Program webview 与全局搜索/翻译；生成式输出笔记不覆盖 v2-refactor-temp 阶段代码、MiniApp webview（persist:webview 分区）、知识库文件处理 artifact、MCP 工具调度；LLM 渠道管理笔记不覆盖外部 CLI 自身交互界面与 API Gateway 管理路由；应用界面基础设施笔记不覆盖聊天业务主链；消息渲染器笔记的未知 part 无开发态 fallback（扩展建议）。

### 共性未验证

- 全部来源笔记均未运行 Electron 应用或真实 Provider 请求；UI 视觉、键盘可用性、无障碍读屏、系统通知与跨平台行为均为静态代码结论（口径见"完成度速览"）。
- Agent 侧：SDK session resume、崩溃恢复、agent-teams 实验特性（默认全量开启）行为、子 Agent 是否继承父会话权限、Pyodide worker 桥接能力、工具输入超限处理分支、`error_max_turns` 呈现（Agent 工具笔记第 15 节）。
- 数据与执行侧：压缩触发阈值、网络级取消效果、同会话串行/并发行为、中间增量落盘频率、FTS 中文分词效果、附件回收宽限、崩溃恢复与多窗口并发写入。
- 媒体与导出：真实模型生成与计费、job 提交/轮询/取消时序、捕获 32767px 边界行为、grid/horizontal 布局截断、远端图片 CORS 表现、备份恢复端到端行为。
- 桌面集成：托盘图标切换、原生右键菜单、通知点击唤起等实际平台行为；渲染进程无全局错误兜底时的异常可见表现。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/Cherry-Studio-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/Cherry-Studio-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/Cherry-Studio-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md)
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/Cherry-Studio-外部执行体与应用协作调查笔记.md)
- [媒体创作调查笔记](../媒体创作/Cherry-Studio-媒体创作调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/Cherry-Studio-对话导出与分享调查笔记.md)
- [对话请求与上下文调查笔记](../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/Cherry-Studio-应用界面基础设施调查笔记.md)
- [消息渲染调查笔记](../消息渲染器/Cherry-Studio-消息渲染调查笔记.md)
- [独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)