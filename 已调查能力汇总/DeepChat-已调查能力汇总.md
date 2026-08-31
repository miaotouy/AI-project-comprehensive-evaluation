# DeepChat 已调查能力汇总

> 汇总对象：`DeepChat（https://github.com/ThinkInAIXYZ/deepchat）`
>
> 汇总更新日期：2026-08-31
>
> 依据：14 份单项目调查笔记（Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、对话导出与分享、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时、检索增强与认知编排；代码快照均为 `7f3379524da3ac629918d35682e38833ad5c203e`，dev 分支）；另引用 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)
>
> 汇总方法：阅读各来源笔记的"结论摘要"与关键章节，按功能主题合并重复能力，保留来源笔记的证据状态与边界表述，逐条链接来源；未进行新的源码调查
>
> 汇总范围：覆盖上述 14 个类目中与 DeepChat 相关的已调查能力；仓库分布、应用界面基础设施的结论单列于"工程与基础设施摘要"；对话请求与上下文、媒体创作等未列入来源清单的类目不在本次范围；不做跨项目横向比较
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

DeepChat 是 Electron 桌面聊天客户端（Vue 3 + Pinia + shadcn-vue 渲染层、Node + SQLite 主进程、AI SDK 出网）。聊天主链由 main process 驱动：`SessionTurn`/`transcript` 是事实源，renderer 以 typed route/IPC 订阅投影；一次回复以"pending 占位 → 流式替换 assistant blocks → sent/error 结算"完成，配套 queue/steer 独立输入通道、消息窗口化、双层搜索。Agent 层是独立的 loop 引擎（工具目录解析、权限审批、128 次工具调用上限、结果回注），并接入 Artifact 对象、MCP App 双层沙箱与本机 exec。外部面覆盖 ACP 外部执行体、五类 IM 远程控制与本地 CLI 控制平面；差异化能力包括 Tape & Trace、Skill 跨工具迁移、web 搜索/深度研究、Ollama 管理、DeepLink。

## 完成度速览

| 证据状态 | 条目数 |
| --- | ---: |
| 主链确认 | 35 |
| 静态源码确认 | 3 |
| 入口确认 | 1 |
| 归并已有类目 | 3 |
| 声明不符（能力子项） | 1 |
| 暂缓 | 0 |

合计 42 条能力条目（另含 1 条贡献统计建议，不计入能力）。主链确认与静态源码确认合计 38 项，约占能力条目的 90%；异常或部分确认项（声明不符 1、入口确认 1）约占 5%。此外有一批"未找到/未覆盖"边界记录与共性未运行验证清单，不占能力条目，集中列于文末"已知边界与待验证事项"。

证据口径：本汇总的“主链确认/静态源码确认”表示已在当前代码快照复查入口、状态、执行与结果处理构成的实现路径。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效。

## 功能能力摘要

- **Agent 上下文快照与压缩状态**：每轮从有效目录派生并冻结工具表面快照，程序化调用也绑定该轮执行授权；上下文压缩以占用快照、边界标记与状态化消息分隔行表达，摘要无效或过期时不会继续采用。ACP 认证属于 runtime 生命周期而非聊天渲染器职责。证据状态：静态源码确认；外部认证交互尚未运行验证。来源：[Agent工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md)。

### 角色与上下文

- **Agent 角色配置体系（DeepChat/ACP 双后端）**：`AgentType` 只有 `deepchat` 与 `acp` 两种取值；DeepChat 角色是持久化 Agent descriptor 加运行时 session policy，`DeepChatAgentConfig` 保存模型选择、systemPrompt、项目路径、权限、禁用工具、Skills、MCP、subagent 槽位、自动压缩、记忆与 persona 演化；内置 Agent id 固定为 `deepchat` 且受保护，手动 Agent 用 `deepchat-${nanoid(8)}`；descriptor 按 kind 分派到 DeepChat loop 或 ACP backend。角色模型为"模型选择 + system prompt + 工具/权限/记忆策略"，不含开场白、用户档案、自定义变量等资产类字段（未找到，见末尾小节）。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md)

- **系统提示词拼装与角色生效**：`systemPrompt` 作为 system prompt 首段，其后按固定顺序拼接运行时能力、环境（provider/模型/工作目录/时间）、Skills 元数据与内容、工具使用说明、编排策略、权限规则与验证策略；ACP-backed subagent 直接返回 base 不做拼接。压缩恢复的 checkpoint/memory/directives 经独立贡献注入，不进入 system prompt 文本。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md) 第 4 节、[Chat 调查笔记](../Chat/DeepChat-Chat调查笔记.md)

- **创建时快照 + 运行时实时重读的混合继承模型**：生成参数（systemPrompt、temperature、上下文长度等）随会话创建冻结进 `deepchat_sessions`/`new_sessions`，修改 Agent 配置不影响既有会话；工具目录与记忆开关每次请求按 Agent 当前配置实时重读；会话级覆盖经 `SessionGenerationSettingsPatch` 支持。与全量实时引用、完整副本两种模型都不同。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md) 第 7 节

- **Subagent 槽位与 authority**：最多 5 个槽位（默认 Explorer/Implementer/Reviewer），仅普通 DeepChat 会话且策略开启、存在有效槽位时 subagent 能力可用，否则返回 `unsupported_session`/`policy_disabled`/`no_valid_slots`；子会话持久化 parent/slot meta，工具解析器按父配置重算 authority，子会话在 ChatPage 只读呈现。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md) 第 8 节、[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>)

- **上下文压缩**：`autoCompaction*` 配置控制自动压缩阈值与保留轮数；`/compact` slash 命令触发手动压缩（ACP 会话不可用、生成中不触发）；压缩生成专门 assistant 消息（content 固定文案、metadata 带 `messageType:'compaction'`），可前插到指定位置并顺移排序号；MCP App 的 approved model context 在压缩时保留。证据状态：主链确认（静态源码）。[Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md) 第 1 节、[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 第 6 节、[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 9 节

- **Session Tape 的工具化轨迹召回**：DeepChat Agent 可通过 `tape_search` 在当前有效 Tape 的 FTS/BM25 投影中检索紧凑候选，再以 `tape_context` 展开选定条目周围、受字节预算限制的证据；已完成直属子 Agent Tape 可显式加入只读范围。结果不自动注入 prompt，后续搜索或作答由模型工具循环决定。证据状态：主链确认（静态源码）。来源：[检索增强与认知编排调查笔记](../检索增强与认知编排/DeepChat-检索增强与认知编排调查笔记.md)。

### 会话与消息

- **会话与消息数据模型（SQLite 多表）**：事实源分多张表——`new_sessions`（会话身份/项目/子会话/编排策略）、`deepchat_sessions`（provider/模型/权限/生成设置）、`deepchat_messages`（消息顺序/内容/状态仅 `pending`/`sent`/`error` 三档）、`deepchat_assistant_blocks`（结构化流式块，主键 `(message_id, block_index)`）、`deepchat_pending_inputs`（队列输入）；id 均由 main process 用 nanoid 生成。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/DeepChat-Chat调查笔记.md)

- **消息生命周期与流式持久化**：`SessionTranscript` 是主进程权威生命周期——建 user 消息 → 建 pending 占位 assistant → 流式反复替换 blocks（保持 pending）→ 完成置 `sent` 或异常写 error block 置 `error`；完成/错误路径同步更新 blocks、消息状态、搜索文档、usage 与 Tape facts，流式中间态只写 blocks。生成侧按 120ms（renderer 快照）/600ms（DB 落盘）节流全块快照。证据状态：主链确认（静态源码）。[Chat 调查笔记](../Chat/DeepChat-Chat调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md) 第 2 节

- **队列/steer 独立输入通道**：生成中的提交进入 pending lane，queue/steer 与已完成消息分表持久化；state 五档（pending/claimed/blocked/retry_required/consumed），`retry_required` 的持久化形态是 `blocked` + `retry_required_at`（schema v67）；重启恢复把 claimed 未物化项释放回队列、未读 steer 置 error、pending 消息兜底置 error。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md) 第 1.4 节、[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 第 5 节

- **编辑/重试/删除/分支语义**：retry 是破坏性截断（从源 user 消息起删除其后全部消息并重发）；delete 同样截断；edit 原地更新 user 消息内容并自动跟随 retry（编辑即重发）；fork 是复制到新会话而非父子指针，消息表无 parent/variant 字段；失败 assistant 消息保留 error 状态与错误块可 retry/fork。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md) 第 1.5、4 节、[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 第 6 节

- **消息窗口化、分页与现场恢复**：首屏默认 100 条、游标分页（页上限 500）；超过 160 条启用窗口化渲染（估算高度 + ResizeObserver 实测 + spacer + anchor + 二分查找），远离视口消息只保留估算高度；restore 请求带 epoch 防止异步写串会话，草稿按会话持久化到 localStorage 并在切换/重启后恢复。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md) 第 5 节、[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 第 2 节、[消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md) 第 6 节

- **双层搜索与 MCP 搜索工具**：会话内查找（Cmd/Ctrl+F）只匹配已加载的 display messages，不触发数据库查询；跨会话历史搜索走 FTS5 外部内容表 + 触发器同步（bm25 为主、LIKE 回退），服务 Spotlight 历史搜索，命中可定位到消息；内存 MCP 服务器把同一索引暴露为模型工具（搜索会话/消息/读历史/读统计）。证据状态：主链确认（静态源码）。[会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md) 第 5 节、[Chat 调查笔记](../Chat/DeepChat-Chat调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 第 2 节

- **对话图片导出（短按/长按）**：消息工具栏同一按钮短按捕获"当前问答组"、长按 800ms（键盘 Shift+Enter/Space）捕获"从顶部到当前消息"；流程对当前 `.message-list-container` 分段滚动截图（最多 30 段），主进程 Sharp 垂直拼接并加水印（DeepChat/版本/模型/Provider），写入系统剪贴板，无文件保存/分享链接/预览编辑器；"从顶部"起点受 100 条初始加载与消息窗口化约束，不等于会话真实起点。证据状态：主链确认（静态走通）。[对话导出与分享调查笔记](../对话导出与分享/DeepChat-对话导出与分享调查笔记.md)

### 消息渲染与展示

- **结构化 block 分发与类型系统**：`AssistantMessageBlock` 定义 content/search/reasoning_content/plan/error/tool_call/action/image 等类型，`MessageItemAssistant` 按 activity group、content、reasoning、tool call、action、媒体、错误分发；新增类型需同时改持久化类型、IPC zod 枚举与展示层，无插件式注册表；provider search 块与权限结果徽标（granted/denied）是两条已确认的分发规则。证据状态：静态源码确认。 [消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md) 第 1 节

- **Markdown 流式渲染与代码块**：`MarkdownRenderer` 基于 markstream-vue，代码块走 stream-monaco/Monaco；流式与静态内容采用不同 render batch、viewport priority 与节点虚拟化参数（静态长文可虚拟化、流式保持平滑输出，默认最多 260 个 live 节点）；截图捕获期间关闭节点级虚拟化。证据状态：静态源码确认。[消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md) 第 3 节、[对话导出与分享调查笔记](../对话导出与分享/DeepChat-对话导出与分享调查笔记.md)

- **Artifact 标签解析与隔离渲染**：`useArtifacts` 解析 `<antThinking>`/`<antArtifact>`/`<tool_call>` 等标签，兼容流式未闭合标签并带 last-parse memo；Artifact 类型映射 Code/Markdown/HTML/SVG/Mermaid/React，HTML/React 走 iframe sandbox、SVG 经 main process sanitizer、Mermaid 清洗危险标签并初始化 `securityLevel: strict`。证据状态：静态源码确认。[消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md) 第 2、4、5 节

### 生成与创作

- **Artifact 对象（能力等级 G3）**：模型在正文输出 `<antArtifact>` XML 标记（6 种 MIME 白名单），使用规范由内置内存 MCP 服务器指令工具注入（>15 行、可复用、独立成文才用，更新复用 identifier）；renderer 解析为独立对象，消息内卡片 + 工作区侧栏预览/代码双视图；对象事实源是消息块正文原文（SQLite），无独立对象表/ID/版本，身份为 `(messageId, blockId, identifier)` 三元组；模型可复用 identifier 以新消息续写"新版"，旧版不被覆盖。能力等级判定为 G3：HTML/React Artifact 可执行、Agent exec 可在本机子进程运行，但用户无编辑/保存通道且对象依附于消息文本，未达 G4/G5。证据状态：主链确认（静态走通）。[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 1、6 节

- **MCP App 沙箱（最完整的受控运行时）**：声明 `ui` 元数据与 `text/html;profile=mcp-app` 资源的 MCP 工具结果进入 `mcp-app://` 双层 iframe 沙箱（代理页 + 内层 sandbox iframe，动态 CSP 默认拒绝一切加载，Permissions-Policy 默认关闭摄像头/麦克风等）；JSON-RPC 2.0/postMessage 桥回宿主调工具、读资源、开外链、发消息、更新模型上下文，能力全部需用户逐次同意（2 分钟超时）；实例限额 64（窗口 32）、TTL 30 分钟，重载后实例不恢复但可从持久化 app 描述符重新 prepare。证据状态：主链确认（静态走通）。[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 7.1 节

- **Agent 本机执行**：exec/process 工具在主进程本机 spawn（默认超时 120s、kill 宽限 5s），目录限定 allowedDirectories（工作区根 + skill 根 + 会话目录 + temp + 用户批准路径）；命令 shell 可配置（posix/cmd/windows-powershell/git-bash，#2109），RTK 改写仅 posix 启用；命令权限按低/中/高/关键四级审批、白名单按 dialect 分开、通过后返回可撤销的一次性授权；输出按默认 12,000 字符截取内联预览、超限落会话目录 log；后台 exec 会话支持 7 种 process 操作；二进制读取放宽（#2110）只拒绝固定二进制 MIME，octet-stream 文本可读。证据状态：主链确认（源码确认）。[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 7.2 节、[Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)

- **图像生成与持久化**：图像生成工具走供应商图像模型，结果提升为独立 image 块（`image_data` + `image_mime_type` 列）；图片经 `imgcache://` 落盘引用，MCP 工具调用时把引用解析回 data URL（上限 8 个引用、展开 ≤32 MiB），renderer 侧已物化的图不再重复显示于 Markdown。证据状态：主链确认（静态源码）。[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 4 节

- **工作区文件预览与 Git diff**：工作区侧栏提供 markdown/html/pdf/svg/image 等格式预览（`workspace-preview://` 协议 iframe，响应带 nosniff），HTML/SVG/PDF 与 Artifact 共用查看器；工作区 Git diff（staged/unstaged）只读展示，无应用/拒绝操作；工具响应内联 diff 由工具卡渲染。证据状态：主链确认（静态源码）。[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 3、6 节

### Agent 运行时与外部协作

- **Agent 工具体系与统一路由**：`DeepChatToolResolver` 按 Agent 配置/项目/Skills/禁用工具/MCP 选择生成带 fingerprint 的会话工具目录；`ToolService` 把 MCP 与内置 Agent 工具统一为 MCP-format 定义（同名冲突保留 MCP 并标记 source）；`DeepChatLoopEngine` 每轮消费流、出现 tool batch 时结算持久化再继续，默认工具调用总上限 128；原生工具走 AI SDK tool stream，不支持原生工具的 Provider 走 `<function_call>` 文本协议（解析失败用 jsonrepair 修复）。证据状态：主链确认（静态源码）。[Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)

- **工具权限与安全边界**：`ToolPermissionBroker` 有 default/auto_approve/full_access 三档，参数先 canonicalize 再计算 SHA-256 hash，已批准记录需匹配会话/server/配置代数/binding/工具名/执行 id/参数 hash；`CommandPermissionService` 按 base command/签名/风险等级判断，控制语法检测按 dialect 区分，审批通过后命令类返回可撤销的一次性授权；工具分派前经过 Tape 执行契约门（contract lineage），违反冻结契约抛错。证据状态：主链确认（静态源码）。[Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md) 第 3 节

- **工具结果回注与 UI 状态**：工具调用与结果随 transcript 持久化后，下一轮 `contextBuilder` 把 tool_call 块映射为 assistant 消息 tool_calls 字段、把 response 转成 role:'tool' 消息回注（含 MCP App modelContext）；失败/错误响应同样以 tool 角色文本进入上下文。UI 侧工具卡显示 calling/response/end/error 状态机、参数/响应折叠、diff、图像预览与审批状态环。证据状态：主链确认（静态源码）。[Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md) 第 7 节

- **ACP 外部执行体**：`resources/acp-registry/registry.json` 列 38 个可发现 Agent（claude-acp、codex-acp、cursor、opencode、devin、goose、grok-build 等），经下载、sha256 校验、依赖安装后由 AgentManager 按 kind 分派；ACP 自己持有工具执行能力，DeepChat 内置工具目录对该 session 返回空；ACP 会话可反向作为 DeepChat 自身 harness 的 LLM provider。证据状态：主链确认（静态证据）。[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepChat-外部执行体与应用协作调查笔记.md)

- **定时任务（cron）与 remote delivery**：定时任务支持把计划结果投递到已绑定 IM 端点；完整执行链为入口确认，细节见末尾小节。证据状态：入口确认（交点记录）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 1

### 渠道与调度

- **LLM 渠道管理与生命周期**：渠道是持久化 `LLM_PROVIDER` 用户实例，默认 Provider 是应用内置配置模板和注册表条目，用户可新增 `custom: true` 实例并修改部分字段；配置存 Electron Store 与 SQLite `providers` 表两路协作，`ProviderInstanceManager` 按 ID 创建缓存实例、配置变更触发重建；一个 Provider 实例只有单一 baseUrl，多地址靠多实例实现。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md)

- **配置管理入口边界**：桌面设置页是完整管理入口（查看/新增/编辑/启停/删除 custom/刷新模型/连接测试）；CLI 是本地控制面而非独立配置编辑器（`provider list/test/add/update/set-credential/remove`，依赖运行中的 main 进程，公共 DTO 脱敏，内置 Provider 的 apiType 修改被拒）；Provider 导入是桌面设置页的数据迁移向导（从 CC Switch/Alma/Cherry Studio/Hermes/OpenClaw 扫描映射），不是通用导入文件格式；无 Provider 复制/导出，TUI 与远程 Web 管理未提供（未找到，见末尾小节）。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) 第 2、3 节

- **凭据存储与脱敏边界**：普通 API Key 明文作为 SQLite 字段保存，数据库层加密配置未确认；OpenAI Codex 与 xAI Grok OAuth 走独立 credential store 并经 safeStorage 加密（不可用时 file storage fallback）；AWS Bedrock 凭据走 settings store；Provider summary、CLI DTO、导入预览与请求 trace 均脱敏。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) 第 4 节

- **协议适配与运行时选择**：providerRegistry 按 Provider ID 优先、apiType 次之映射到 AI SDK runtime definition；同一 OpenAI-compatible apiType 复用统一适配器，Anthropic/Gemini/Vertex/Bedrock/Ollama 等特殊协议在 factory 组装 endpoint/headers/请求体；DeepSeek 官方 Responses endpoint 的原生 Web Search 是 Provider ID + 模型 ID + 官方 endpoint 三重条件下的特殊 adapter；ACP 的 `apiType: acp` 走 Agent backend 而非通用 AI SDK endpoint。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) 第 6 节

- **模型目录与能力元数据**：模型来源包括 Provider 内置/远端列表、Provider DB 聚合目录与用户 custom models；`ModelConfig` 保存上下文长度、输出上限、采样参数、vision/function call/reasoning、endpoint 与媒体能力，有效配置由 Provider facts、Provider DB 与用户覆盖合并；模型启停状态单独存 `model_status`，Provider 删除时级联清理。证据状态：主链确认（静态源码）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) 第 5 节

- **QPS 限流、重试与故障转移边界**：`RateLimitManager` 维护 Provider 级队列按 `1/qpsLimit` 间隔释放，是限流而非健康检查；未找到基于成本/延迟/权重的负载均衡，也未找到多 API Key 轮询与 Provider 层自动跨渠道 failover（模型 fallback 由 Agent/session attempt 管线驱动）；连接测试复用真实 Provider 执行链（可带 modelId 发真实请求），CLI 公共测试再包 5 秒超时并统一脱敏错误。证据状态：主链确认（静态源码；"无 failover"为已确认边界）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) 第 7、8 节

### 独特与差异化能力

- **IM 远程控制（多表面连续性，能力卡 1）**：Telegram/Feishu-Lark/QQBot/Discord/WeChat iLink 五个渠道把桌面会话投影到 IM，外部消息经命令路由（/start /stop /pending /open /agent 等）驱动同一 SessionTurn/runtime，可答复 question/权限、停止生成、打开桌面会话并接收 cron remote delivery；PairCode 授权 TTL 10 分钟、失败上限 5；执行仍在本机主进程，Feishu/Weixin 等依赖平台应用注册（外部服务依赖，暂缓运行验证见末尾小节）。证据状态：主链确认（静态证据）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 1、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepChat-外部执行体与应用协作调查笔记.md)

- **Tape & Trace（研究轨迹，能力卡 2）**：结构化记录系统（Tape entries + view manifest，DDD 分层，领域/应用/SQLite 基础设施分层）；严格执行日志以四类事件记录 run 边界与工具分派（崩溃可识别未收口 run）；执行契约按工具/工作区/深度冻结 ceilings（契约 64 KiB、工具 256、subagent 深度 1），工具服务分派前校验，绑定 id 写入 assistant block；TraceDialog 提供 request/view/entries/budget 四 tab，模型侧有 tape_search/tape_context 工具与跨会话 FTS 召回。证据状态：主链确认（静态证据）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 2、[Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)

- **Skill 跨工具迁移（能力卡 3）**：Settings → Skills 支持文件夹/ZIP/URL/拖放安装；导入/导出经格式转换器 + 11+ 工具适配器（claudeCode/codex/cursor/windsurf/copilot/openCode/goose/kiloCode/kiro/antigravity/agents），带文件名/路径安全校验；会话级 activeSkillNames 进入工具目录，skill_run 工具执行。证据状态：主链确认（静态走通）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 3、[Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)

- **搜索助手（web 搜索链，能力卡 4）**：内置内存 MCP 服务器提供 Bocha/Brave 搜索与 deepResearch 反思式深度研究，YoBrowser 浏览器工具模拟真人浏览；DeepSeek 原生 web 搜索（#2093）仅对 deepseek provider + deepseek-v4-flash + 官方 endpoint 启用，来源以 search 块渲染（http/https 白名单、去重、上限 100）。仅 README 声称的"自定义搜索助手模型"配置入口无消费方，声明不符，见末尾小节。证据状态：主链确认（web 搜索链）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 4、[消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md) 第 2 节

- **Ollama 管理（能力卡 5）**：apiType 为 ollama 时嵌入专用设置页，ollamaStore 经 OllamaManager 调 ollama SDK 提供下载（pull 进度事件回渲染层）、刷新与运行模型列表，不离开应用完成本地模型管理。证据状态：主链确认（静态走通）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 5

- **DeepLink（能力卡 6）**：`deepchat://` 协议三命令 start/mcp/provider——开新会话（msg/model/agent 参数）、一键安装 MCP 服务、导入 Provider；粘贴内容做危险模式扫描（script/iframe/javascript:/on*= 等），MCP 未就绪时挂起待启动后处理。证据状态：主链确认（静态走通）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 6

- **CLI 本地控制平面（终端驾驶面，能力卡 7）**：`deepchat` CLI 连接本地 HTTP control server（localhost + 带 scope 的 token 鉴权），/rpc /stream /upload 三条 RPC 路径、12 组路由面 80+ 个 route，可发起前台或 detached agent run、管理 MCP/Skill/Provider/设置、OCR/转写/媒体生成并暂存工件（ArtifactSpool）；变更命令经变更守卫与审批 broker（与桌面共用）、CliAuditLog 审计，agent 命令访问按 domain/verb scope 收口；launcher 安装可逆。证据状态：主链确认（静态证据）。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 7、[外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepChat-外部执行体与应用协作调查笔记.md)

- **ACP 作为模型**：已归并到 Agent 角色笔记 §3（kind 分派）与 LLM 渠道笔记 §2（`apiType: acp` 边界），主链确认。证据状态：归并已有类目。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 已归并节

- **自有会话搜索**：已归并到会话与消息管理笔记 §5 与 Chat UI 笔记 §2（FTS5 + 会话搜索服务）。证据状态：归并已有类目。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 已归并节

- **Artifact / MCP App 沙箱 / 本机 exec**：已归并到生成式输出与运行时笔记（主链确认 G3，见"生成与创作"集群）。证据状态：归并已有类目。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 已归并节

- **特色功能贡献统计建议**：独特功能笔记建议主贡献为 IM 远程控制、Tape & Trace、Skill 跨工具迁移、CLI 本地控制平面；辅助贡献为 Ollama 管理、DeepLink、web 搜索/深度研究链；归并不计数为 ACP 作为模型、自有会话搜索、Artifact。详见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 工程与基础设施摘要

- **仓库分布**：单包（单 package.json）+ 多运行时合仓的 Electron/Vue 应用（pnpm 10.34.5 + electron-vite + electron-builder）。Git 跟踪 4,379 文件；可识别源码 3,052 文件 / 904,777 行，其中 TypeScript 79.9%、Vue 11.0%、Swift 2.8%（主要来自 `plugins/cua/vendor/cua-driver` macOS 辅助程序）；测试树 953 文件 / 366,497 行，占全部可识别源码行 40.5%，`test/main`（605 文件）与 `src/main`（805 文件）规模接近、目录一一对应。`src/renderer` 下另有 settings/floating/browser-overlay 三个独立入口；`plugins/cua`、`plugins/feishu` 是自包含插件单元；文档 282 文件，i18n 覆盖 20 种语言；自 `dc4177c2` 以来新增三个子系统（本地 CLI 控制平面、结构化主进程日志、Tape 执行日志与契约层），均有同目录测试树；构建矩阵覆盖 Windows/macOS/Linux 与 x64/arm64，Electron 41.10.4、Node ≥24.18.0、应用版本 1.1.0。证据状态：Git 跟踪文件机械统计 + 构建配置复核（未运行构建）。[仓库分布调查笔记](../仓库分布/DeepChat-仓库分布调查笔记.md)

- **应用界面基础设施**：界面栈 Vue 3 + Pinia + shadcn-vue（底层 Reka UI）+ dc-ui 业务壳 + vue-router + vue-i18n + Tailwind v4，无 Element Plus/antd/framer-motion。弹窗三类消费方式（主进程 DialogService 全局确认、页面内 DcConfirmDialog、组件内 Dialog）共享底层原语但状态所有者不同；通知是最完整的公共机制（renderer NotificationManager 归一化/聚合/仲裁/展示预算 + vue-sonner Host + 主进程 WindowNotificationRouter 跨窗口语义路由，另有独立系统通知通道）；主题由主进程 settings 与 nativeTheme 权威、renderer 订阅快照，用户配置仅明暗三态 + 字号 5 档 + 正文/代码双字体，未提供主题市场/壁纸/主色引擎/自定义 CSS/密度圆角入口（未找到，见末尾小节）；renderer 未找到应用级错误边界，错误反馈分场景下放；主聊天窗未设最小尺寸、侧栏折叠不持久化；多窗口共享同一 renderer 源，运行时状态（busy/streaming）为窗口内内存。证据状态：静态源码核对。[应用界面基础设施调查笔记](../应用界面基础设施/DeepChat-应用界面基础设施调查笔记.md)

## 已知边界与待验证事项

### 声明不符

- **搜索助手"自定义搜索助手模型"**：README 声称的"配置一个搜索助手模型连接各种搜索源（内网、无 API 引擎、垂直搜索引擎）"对应 i18n 键 `searchEngineName/searchEngineUrl`，但 `src` 内的 .ts/.tsx/.vue 均无消费方，判定为遗留声明/未接线配置；当前可执行路径以 Bocha/Brave/DeepResearch、YoBrowser 和 DeepSeek 原生搜索为准。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 4

### 暂缓与外部依赖

- Feishu 渠道的安装与鉴权依赖飞书开放平台应用，Weixin iLink 依赖企业微信接口，Telegram/QQBot/Discord 依赖各自 bot 平台：均为外部服务依赖，主链执行需真实凭证，暂缓运行验证。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md)
- DeepLink 在 Windows/macOS/Linux 的协议注册差异与 MCP 未就绪时的排队恢复未实测，暂缓。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 6

### 入口确认未闭合

- **cron 定时任务与 remote delivery**：定时任务及其 remoteDelivery 配置面存在，且与 IM 远程控制的投递交点已确认，但 cron 本体的完整执行链只记录了交点，属入口确认，未展开调度器内部实现。[独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md) 能力卡 1

### 未找到与未覆盖

- **角色资产与变量**：DeepChat 角色模型未找到开场白/欢迎语/快捷回复、用户档案/Persona 模板、自定义环境变量插值等资产类字段；descriptor 层 avatar/icon 仅作 UI 展示，不进入提示词或请求（检索范围覆盖 `src/shared` 与 `src/main`）。[Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md) 第 5 节
- **渠道管理面**：未找到 Provider 复制、Provider 导出、CLI Provider 导入/导出，以及 TUI 与远程 Web 管理入口（"未找到"按本次搜索范围表述，不对未来分支或外部集成作绝对否定）。[LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) 第 2、3 节
- **生成与创作**：Artifact 导出/另存按钮（`useArtifactExport`）未被任何组件调用；无应用内图片导出历史、无 Artifact 编辑保存通道（工作区代码视图显式只读）为已确认边界。[生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) 第 5、6 节
- **界面与交互**：后台生成（窗口外继续运行 + 返回入口）、分支树/版本导航界面未在 ChatPage 找到；多窗口 busy/streaming 同步不存在（运行时状态为窗口内内存）。[Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) 第 7、8 节
- **主题能力边界**：未找到主题市场/壁纸/主色引擎/自定义 CSS/密度圆角用户入口（专项核对），主题形态为内置明暗三态 + 字号 5 档 + 双字体。[应用界面基础设施调查笔记](../应用界面基础设施/DeepChat-应用界面基础设施调查笔记.md) 第 4.3 节
- **未覆盖类目**：对话请求与上下文、媒体创作类目未列入本次来源清单，其主题（请求执行链、上下文构建细节、媒体创作）不在本次汇总范围。
- **轨迹召回边界**：Tape 召回不是独立文档库摄取管线；本次未确认向量召回或 reranker，也未发现命中自动生成固定后续查询或后台整理 Tape 的机制（检索增强与认知编排笔记）。

### 共性未验证（方法学口径）

- 全部来源笔记均基于当前代码快照，未运行 Electron 应用、构建、单元测试或真实 Provider/IM/CLI 请求；这保留了黑盒、UI 与端到端环境中的观察维度，不改变已复查的实现结论。
- 队列/重启恢复、消息窗口化高度、FTS 中文分词与搜索命中快照生命周期、schema 迁移兼容分支、fork/delete 并发竞态、剪贴板写入失败与图片捕获 30 段上限后的实际长图内容未验证（会话与消息管理笔记 §10、对话导出与分享笔记）。
- 命令 shell 各 dialect 的实际解析差异、RTK 非 posix 绕过路径、执行契约违反的运行时表现、Artifact 压缩后标签保留策略、HTML Artifact 沙箱与 CSP 组合的实际隔离强度未验证（Agent 工具笔记、生成式输出与运行时笔记）。
- 主题首帧闪烁、Reka 组件内部焦点管理、原生右键菜单、托盘/系统通知/全局快捷键、窗口最小尺寸拖拽表现、font-list 系统字体检测未验证（应用界面基础设施笔记 §9）。
- IM 五渠道真实回调/凭据、CLI token/审批/launcher/detached run 端到端、ACP 注册表真实下载校验启动、Ollama 下载进度、Tape 压缩交互与 manifest hash 算法、Skill 适配器双向兼容面均为静态走通，未运行验证（独特功能笔记、外部执行体笔记）。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)
- [Agent 角色配置调查笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md)
- [Chat 调查笔记](../Chat/DeepChat-Chat调查笔记.md)
- [Chat UI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>)
- [LLM 渠道管理调查笔记](../LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md)
- [仓库分布调查笔记](../仓库分布/DeepChat-仓库分布调查笔记.md)
- [会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md)
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/DeepChat-外部执行体与应用协作调查笔记.md)
- [对话导出与分享调查笔记](../对话导出与分享/DeepChat-对话导出与分享调查笔记.md)
- [应用界面基础设施调查笔记](../应用界面基础设施/DeepChat-应用界面基础设施调查笔记.md)
- [消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md)
- [独特功能调查笔记](../独特功能/DeepChat-独特功能调查笔记.md)
- [生成式输出与运行时调查笔记](../生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md)
- [检索增强与认知编排调查笔记](../检索增强与认知编排/DeepChat-检索增强与认知编排调查笔记.md)
