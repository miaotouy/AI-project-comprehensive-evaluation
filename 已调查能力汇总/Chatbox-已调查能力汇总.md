# Chatbox 已调查能力汇总

> 汇总对象：`Chatbox`（源码仓库 `https://github.com/chatboxai/chatbox`）
>
> 汇总更新日期：2026-08-27
>
> 依据：本工作区内 14 份 Chatbox 单项目调查笔记（Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、媒体创作、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时），均基于代码快照 `81571269addb6bafb589a920b2883f1e1e084fd1`（分支 `main`）；另参考 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态标记并链接来源；未新增源码调查
>
> 汇总范围：覆盖上述 14 个类目笔记中 Chatbox 的全部已调查能力；仓库分布与应用界面基础设施类目结论放入"工程与基础设施摘要"；不做跨项目横向比较，不重新下判断
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Chatbox 是一个 local-first、以单个 Session 为存储单元的多模型聊天客户端，提供 Electron 桌面端、Web 端与 Capacitor 移动端三套产品表面，TypeScript 高度统一的多端仓库。核心产品面包括：单会话聊天工作台（固定 `Header → MessageList → InputBox` 三段式）、角色模板 Copilots、Agent 模式与工具系统（MCP、Skills、沙箱代码执行、知识库/Web Search）、图像生成工作台、对话导出与整库备份、以及仓库内伴生的团队 API 资源共享方案。根 README 已明显落后于当前代码（声明不符详情见文末）。

## 完成度速览

| 证据状态 | 条目数 | 说明 |
| --- | --- | --- |
| 主链确认 | 30 | 功能能力正文 30 条；独特功能能力卡 2 张（Image Creator、Copilots）指向已并入正文的同名条目，不重复计数 |
| 入口确认 | 1 | 团队 API 资源共享（部署与端到端链路未走通，见文末） |
| 归并已有类目 | 3 | 覆盖关系引用，非独立能力 |
| 声明不符 | 1 | 根 README 模型清单过时（见文末） |
| 暂缓 | 1 | Copilots 远端精选/搜索依赖外部服务（见文末） |

主链确认占功能能力条目（31 项）的约 97%，其余 1 项为入口确认；另有归并引用 3 项、声明不符 1 项、暂缓 1 项为状态记录，全部集中见文末"已知边界与待验证事项"。多条主链确认条目带有"未运行验证"限定（沙箱运行时链路、图像真实计费、HTML 离线渲染、VibeDrop 发布、MCP 默认超时等），含义见下方口径，详情见文末。

**证据口径**：本汇总的“主链确认/静态源码确认”表示已在当前代码快照复查入口、状态、执行与结果处理构成的实现路径。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效。

## 功能能力摘要

### 角色与上下文

- **Copilots 角色模板（提示词库的当代形态）**：`CopilotDetail` 只存人格信息（名称、系统提示词、头像、描述、标签），不含模型参数；Session 通过 `copilotId` 关联，模型与采样参数保存在会话自身 settings，同一个 Copilot 可配不同模型创建多个会话；本地自建、收藏、星标、编辑与备份导入导出链路完整。证据状态：`主链确认`（本地部分）。远端精选/搜索依赖 Chatbox 后端 API，细节见文末。来源：[Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)、[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md) 能力卡 3。
- **会话级设置与消息快照**：发送、续写与重新生成时模型与温度一律从会话自身 settings 读取，全局默认仅在创建会话时固化；每条消息只快照 `aiProvider` 与模型显示名，temperature、技能启用列表与 Agent Mode 不进快照。证据状态：`主链确认`。来源：[Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)。
- **上下文拼装与自动压缩**：上下文先过滤不合格/错误消息、应用压缩点，再按 `maxContextMessageCount` 消息数上限裁剪历史（当前输入始终保留）；自动压缩按 token 预算（上下文窗口×阈值，默认 0.6）在发送前阻塞式触发，流式生成摘要、打 `isSummary` 标记并持久化压缩点，删除摘要即恢复原文参与上下文计算。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)。
- **Agent 模式建议（auto 首轮）**：`auto` 模式首轮由快速分类模型决定是否注入 `agent-mode-suggestion` 消息卡，用户接受后锁定为开启态，之后按 `on` 处理。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)、[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)。

### 会话与消息

- **local-first 单会话存储与双写**：完整 Session 对象与消息存通用 storage（IndexedDB），侧栏只认识 `SessionMetaRecord` 元信息（不含任何消息级字段），两者双写同步，每会话一个 `UpdateQueue` 串行合并，react-query 缓存是 UI 侧视图。证据状态：`主链确认`。来源：[Chat 调查笔记](../Chat/Chatbox-Chat调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)。
- **惰性创建会话（'new' 假会话）**：首页 id 固定为 `'new'` 的假会话，发送前临时状态分散在本地 state、`newSessionState` 专用对象与按字符串 `'new'` 作 key 的通用 map 三种容器；首条消息发出才经 `createPersistedChatSession` 迁移为真实 Session。证据状态：`主链确认`。来源：[Chat 调查笔记](../Chat/Chatbox-Chat调查笔记.md)、[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)。
- **Thread / Fork / Summary / ForkMarker 四套消息级结构**：thread（同会话内历史区间）、fork（同一消息位置的平行分支，替代回复折叠为 ForkGroup）、summary（消息级压缩标记）、forkMarker 是四套互不隶属的数据结构；唯一交叉点是"move thread to conversations"把 thread 转成新顶层会话，复制会话/挪 thread 时在新会话顶部插入指回源会话的 forkMarker。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)。
- **消息渲染：结构化 contentParts**：text、reasoning、tool-call、image、info 等 part 分派给专用组件，不依赖从 Markdown 私有标记反向解析；Markdown 默认支持 GFM、软换行、LaTeX、Shiki、Mermaid、SVG 与图片查看器，原始 HTML 不进入 Markdown DOM、HTML 代码预览放进 sandboxed iframe。证据状态：`主链确认`。来源：[消息渲染调查笔记](../消息渲染器/Chatbox-消息渲染调查笔记.md)。
- **流式更新与节流落盘**：每个可见增量只刷新 UI 缓存（几乎逐 token），落盘走每会话 `UpdateQueue`，按 2 秒节流且 tool-call 立即持久化，流结束/出错/暂停时无条件补一次最终落盘。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)、[Chat 调查笔记](../Chat/Chatbox-Chat调查笔记.md)。
- **消息搜索与定位**："当前会话/全部会话"两个入口，正则匹配覆盖文本、推理、信息与工具调用状态及文件名；无持久化倒排索引，跨会话按 IndexedDB 分页逐条扫描（每页 30、命中上限 50），点击结果切换会话并滚动定位。证据状态：`主链确认`。来源：[会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)。
- **侧栏分页、排序与活动指示**：IndexedDB 游标分页（页大小 50、置顶优先）、分数索引落地排序、拖拽仅在同一置顶分组内生效；"生成中/回复完成未读"指示为内存态 zustand store，不落盘、重启即消失。证据状态：`主链确认`。来源：[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)。
- **草稿与现场恢复**：草稿按会话粒度存 localStorage（首页 `'new-chat'`、真实会话 `draft-${sessionId}`，300ms 防抖），发送成功后清除；每会话滚动快照缓存最多 100 个，切换会话不丢阅读位置。证据状态：`主链确认`。来源：[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)。
- **停止、重试、续写与并行替代回复**：停止时把未完成的 tool-call 批收口为 error 态并落盘；重新生成走 fork 分支而非替换原消息，工具暂停后的继续/重试以 `appendToMessage` 写回原消息；"在下方继续回复"刻意绕过会话生成锁以支持并行替代回复，写入由 UpdateQueue 串行兜底。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)、[Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)、[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)。

### 生成与创作

- **图像生成工作台（Image Creator）**：独立 `/image-creator/` 工作台，能力分型为 M1 模型生成工作站 + M3 记录/资产生命周期；单一事实对象 `ImageGeneration` 记录（prompt、模型、参数、参考图键、结果图键、状态、错误与来源）配套 blob 图片存储；按 provider 分双执行路径（ChatboxAI 服务端异步任务 + 2 秒轮询 / 其余 provider 走 `model.paint` 直连），统一折叠为 pending/generating/done/error 本地四态；取消=停止监视、恢复需已持久化 `taskId`、重试=全新发起；参考图 DAG 用 `parentIds` 保留多父迭代关系并以引用计数式 blob 清理防误删。证据状态：`主链确认`（独特功能能力卡 2；媒体创作笔记另有 37 个图像相关单测通过）。真实计费生成需外部模型与计费环境，未运行验证，见文末。来源：[媒体创作调查笔记](../媒体创作/Chatbox-媒体创作调查笔记.md)、[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)。
- **沙箱代码执行与可寻址产物（G3）**：桌面端 Agent Mode 门控 `code_execution`，macOS/Linux 走 `@anthropic-ai/sandbox-runtime` OS 沙箱，Windows 无 OS 隔离直接执行；`create_download` 把文件持久化到 userData，下载卡可预览/保存，重启后仍可用；综合等级判定为 G3（可执行 Artifact），模型侧 read/list/search/write/edit 文件维护闭环具备 G4 部分特征。证据状态：`主链确认`（静态源码贯通）。运行时链路未运行验证，见文末。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Chatbox-生成式输出与运行时调查笔记.md)。
- **HTML artifact 预览与 VibeDrop 网页发布**：HTML 代码块经 sandboxed iframe 预览（本地 preview server 或远端 `artifact-preview.chatboxai.app` 宿主）；可发布为 VibeDrop 静态页（需登录 Chatbox 账号签发 per-user key，`unlisted`/`public` 两档可见性），发布对象限于聊天内可渲染的代码块 HTML，会话本身不进入该链路。证据状态：预览为 `主链确认`；VibeDrop 发布为入口级确认，真实发布链路未运行验证，见文末。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Chatbox-生成式输出与运行时调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/Chatbox-对话导出与分享调查笔记.md)。
- **对话导出（Markdown / TXT / HTML）**：顶部工具栏唯一入口的单弹窗能力，只有范围（当前线程/全部线程）与格式两个下拉，无预览、编辑、剪贴板或历史；三种格式共用同一套基于 contentParts 的抽取口径（含工具卡、图片占位或内联、附件文件名），reasoning、agent-mode-suggestion 与分叉分支不导出；HTML 复用聊天现场 Markdown 组件离屏静态渲染，受管图片内联 base64、样式依赖 Tailwind/KaTeX CDN。证据状态：`主链确认`。来源：[对话导出与分享调查笔记](../对话导出与分享/Chatbox-对话导出与分享调查笔记.md)。
- **备份 ZIP v2（可往返恢复）**：设置页整库备份：manifest 声明格式与版本、resources/ 资源级封装（覆盖分叉分支与消息资源）、SHA-256 校验、密钥脱敏；导入分"读取暂存→完整校验→事务提交"三阶段，兼容旧版单 JSON 备份；与阅读性对话导出在格式、抽取范围与资源策略上完全分离。证据状态：`主链确认`（含 890 行往返测试）。来源：[对话导出与分享调查笔记](../对话导出与分享/Chatbox-对话导出与分享调查笔记.md)。

### Agent 运行时与外部协作

- **工具集按会话动态组装**：`buildToolsForSession` 是整个应用唯一装配 AI SDK ToolSet 的函数，按 agentMode、模型能力声明、附件、知识库、MCP 配置与 codeExecution 选项决定哪些工具进入模型视野；web_search 与 parse_link 是唯一独立于 agentMode 的工具。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)。
- **工具审批与安全边界**：user_exec 走白名单→AI→人工三级审批、文件写入（write_file/edit_file）条件式审批、chatbox_cli 的计费/状态变更走 app_action 审批且不可被 agentFullAccess 绕过；暂停状态随会话持久化、重启后经继续/重试路径在原消息内恢复。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)。
- **Agent Mode 与文件维护闭环**：agentMode 三态（on/auto/off）可锁定，工作目录按会话 ID 确定性定位、重启复用；模型可经 read/list/search/write/edit 维护文件，write/edit 要求唯一匹配否则报错；`agentFullAccess` 打开后 user_exec 与文件写入免逐次审批。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Chatbox-生成式输出与运行时调查笔记.md)。
- **MCP 扩展**：用户可配置 stdio（main 进程子进程）与 HTTP/SSE（直连网络）两类 server，另有 5 个官方内建 HTTP server（域名 `mcp.chatboxai.app`，带许可证鉴权）；所有 MCP 工具无 Chatbox 层逐次审批、与 main 进程同权限，非 running 状态 server 的工具对模型不可见。证据状态：`主链确认`。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)。
- **Skills 系统**：四个来源（内置同步、`userData/skills`、`~/.claude/skills`、`~/.agents/skills`）先到先得去重；`install_skill` 仅校验路径范围/命名/大小、不校验 SKILL.md 正文语义，安装后自动启用。证据状态：`主链确认`。`skills:execute-script` IPC 已实现但当前未被任何工具或 UI 调用，见文末。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)、[Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)。
- **知识库、附件 RAG 与 Web Search**：知识库、网页浏览、Agent 模式在底层统一建模为同一工具注册管线里的三个开关，受模型 `isSupportToolUse` 门控，不拼进 prompt 文本；知识库提供 inline（附加到消息）与 session-retrieval（按需检索）两种召回方式。证据状态：`主链确认`（并入对话请求与上下文、Agent 工具笔记；独特功能笔记标记为归并已有类目）。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)、[Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)。
- **后台任务回填（非子 Agent）**：chatbox_cli 触发图片生成等后台任务，完成后把结果作为新 user 消息回填原会话并触发同一 agent 继续对话，回填消息带防注入声明；未发现 agent-as-tool 或嵌套 agent 调用，与"派生新 agent 实例"是不同机制。证据状态：`主链确认`（未发现子 Agent 的结论基于全仓库关键词搜索）。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)、[媒体创作调查笔记](../媒体创作/Chatbox-媒体创作调查笔记.md)。

### 渠道与调度

- **LLM 渠道管理（内置 Provider + 自定义 Provider）**：渠道分两层——代码注册的内置 Provider 与用户设置创建的自定义 Provider；同一内置 ID 只有一个用户端点，配置多个 OpenAI 兼容中转需创建多个自定义 Provider ID；桌面/Web 共用设置页，支持查看、新增、编辑、模型管理、导入（剪贴板 JSON/深链）、删除自定义渠道与连接测试，内置渠道不可删除。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md)。
- **模型目录与能力元数据**：模型目录由本地保存模型、Provider API、后端 manifest 与 models.dev 多源合并富化；模型条目区分 chat/embedding/rerank/image 并带 vision、reasoning、tool_use 能力与上下文窗口。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md)。
- **凭据、重试与连接测试**：支持单 API Key、OAuth、Azure、Bedrock 凭据，无 Key 池/轮询/熔断/健康路由；429 与 5xx 在同一模型实例内指数退避重试（最多 5 次），网络错误默认不自动重试，无跨 Provider/模型/Key failover；连接测试复用真实 `getModel()` 链路依次测文本、视觉与工具调用。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md)。
- **虚拟 CLI（chatbox_cli）**：应用内受控命令面而非独立终端程序，命令域仅 account/settings/chats/image；只读受限设置、无 Provider 管理命令；模型可经 `chatbox image generate` 触发图像生成后台任务并带计费类审批。证据状态：`主链确认`。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)、[媒体创作调查笔记](../媒体创作/Chatbox-媒体创作调查笔记.md)。
- **会话生成串行化与并发**：同会话主链生成任务被每会话生成锁（promise 尾链）串行化，前一个任务完成才执行下一个；"在下方继续回复"刻意绕过锁以支持并行替代回复，消息写入由 UpdateQueue 串行兜底；图像生成另有全应用单任务闸门。证据状态：`主链确认`。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)、[媒体创作调查笔记](../媒体创作/Chatbox-媒体创作调查笔记.md)。

### 独特与差异化能力

- **图像生成工作台（Image Creator）**（能力卡 2，`主链确认`）：内容已并入上文"生成与创作"小节，此处保留能力卡标题与证据状态，不重复展开。来源：[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)、[媒体创作调查笔记](../媒体创作/Chatbox-媒体创作调查笔记.md)。
- **Copilots（提示词库的当代形态）**（能力卡 3，`主链确认` 本地部分）：内容已并入上文"角色与上下文"小节；远端精选/搜索依赖外部服务，见文末。来源：[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)、[Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)。
- **归并已有类目**：Agent Mode / 沙箱代码执行 / create_download 产物 / HTML artifact 预览 → 已归并到[生成式输出与运行时调查笔记](../生成式输出与运行时/Chatbox-生成式输出与运行时调查笔记.md)；MCP / Skills → 已归并到[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)；知识库 / 附件 RAG / Web Search / Document Parser → 已归并到会话与消息管理、对话请求与上下文、消息渲染器笔记。

独特功能笔记建议将图像生成工作台、Agent Mode + 沙箱产物链计入主贡献，团队 API 资源共享与 Copilots（本地部分）为辅助贡献；相关口径见 [特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 工程与基础设施摘要

- **仓库分布**：TypeScript 高度统一的多端应用仓库，Electron 主进程、preload、renderer、Web 与 Capacitor 移动端共享 `src`；`src/renderer`（880 文件/150,097 行）为主实现区，`src/shared` 与 `src/main` 分别承担跨端逻辑与桌面能力；Git 跟踪 1,414 文件，测试 282 文件/49,839 源码行，语言以 TypeScript 为主（96.9%）。来源：[仓库分布调查笔记](../仓库分布/Chatbox-仓库分布调查笔记.md)。
- **应用界面基础设施**：界面栈为 React + TypeScript + Vite，Mantine 为主 UI 库，移动端抽屉用 vaul、另有预留的 Radix Dialog；AdaptiveModal 按屏幕形态在 Modal 与 Drawer 间切换，命令式弹窗统一经 nice-modal-react；通知为 MUI Snackbar（右上角）与 sonner（Settings 内部底部居中）两套并行系统；Sentry ErrorBoundary 四层包裹渲染树；主题同时驱动 MUI、Tailwind 与 Mantine 三套消费方；Overlay 栈自制"多层弹窗只有最上层响应 Esc"。来源：[应用界面基础设施调查笔记](../应用界面基础设施/Chatbox-应用界面基础设施调查笔记.md)。
- **桌面集成边界**：全局快捷键仅"显示/隐藏窗口"一项，托盘无聊天状态徽标，系统通知 API 未接入（全仓库无 `new Notification(` 匹配）；窗口显示事件联动聊天输入框聚焦是唯一的"桌面事件 → 聊天 UI 反应"联动。来源：[Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)。

## 已知边界与待验证事项

### 声明不符

- **根 README 模型清单过时**：根 README 的模型清单（ChatGLM-6B、llama2、Mixtral、vicuna 等）与当前 Provider 注册表不符，属文档过时，以代码为准；README 亦未列出 MCP、Skills、知识库、Agent Mode、Image Creator 等已实现能力。状态：`声明不符`。来源：[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)。

### 暂缓与外部依赖

- **Copilots 远端精选/搜索**：官方精选与搜索依赖 Chatbox 后端 API，离线不可用，可用性与分页未运行验证（`暂缓`）；本地自建/收藏/星标部分已`主链确认`。来源：[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)。
- **团队 API 资源共享**：`入口确认`——team-sharing 伴生部署（Docker + Caddy 反代注入团队 Key）与成员端免 Key 自定义 Provider 的端到端行为未验证（部署未实际拉起）；无用量/配额面板；README 宣称"不暴露 API Key"成立的前提是成员信任部署方。来源：[独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)。
- **VibeDrop 网页发布**：登录签发 per-user key、可见性两档、同名 slug 更新等发布逻辑为入口级确认，真实发布链路与第三方站点（app.vibedrop.cc）治理未运行验证。来源：[对话导出与分享调查笔记](../对话导出与分享/Chatbox-对话导出与分享调查笔记.md)。

### 入口确认（未走通完整链路）与已实现未接入

- **skills:execute-script IPC**：可直接执行 skill 自带脚本且不经 user_exec 审批，已实现但当前未被任何工具或 UI 调用，判断为"已实现未接入"；不排除动态调用未被搜索覆盖。来源：[Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)。
- **遗留死状态（非能力缺口）**：`newSessionState.webBrowsing` 死字段、`openAboutDialog` 空调用、`autoPreviewArtifacts` 设置已无消费方、旧的单 JSON 备份 UI 未被引用（详见对应来源笔记）。

### 未覆盖类目

- 独特功能笔记未调查的新用户引导（`/guide/`）剧本细节与 Chatbox AI 账号面。
- LLM 渠道笔记未找到独立 TUI（结论限于当前源码搜索范围，不宣称历史版本均不存在）。
- 会话级 JSON、PDF、PNG 导出与公开链接分享本次未找到；对话导出缺少 Markdown/TXT 内容断言测试。
- 移动端 SQLite/IndexedDB 实机迁移表现未验证。

### 共性未验证（方法学口径下的运行验证缺口）

- 各笔记普遍未运行真实 Provider 调用与计费生成、UI 视觉与键盘可用性、桌面/移动/浏览器平台行为；多数结论来自静态代码，图像生成与导出相关仅有部分单测运行通过。
- provider 侧 token 截断与最终 HTTP payload 字段（`packages/model-calls` 适配层职责）未逐一核实。
- MCP HTTP/SSE transport 默认超时数值未确认；`main/mcp/shell-env.ts` 实现未逐行读取。
- Windows 无 OS 沙箱的实际影响未验证（`TASK_SANDBOX_DENY_READ_PATHS` 仅 macOS/Linux 分支生效，`~/.ssh` 等拒绝规则在 Windows 上不生效）。
- 沙箱运行时链路（执行、预览、下载、暂停继续、重启恢复）整体未运行验证。
- 图像生成真实计费与异步任务轮询时序未运行；提交层 `retry: 2` 是否重复计费无运行时证据。
- `context-management` 压缩的运行时行为（摘要质量、触发频率、boundary 竞态）未运行验证。
- HTML 导出离线打开效果（Tailwind/KaTeX CDN 失效样式、Mermaid 空占位、未转义字段的 self-XSS 实际表现）未运行验证。
- 600~640px 断点窄缝是否有实际视觉跳变未核实；IndexedDB 捕获 VersionError 后重试兜底未见实现。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Chatbox-Agent工具调查笔记.md)：工具集装配、审批、执行位置、MCP/Skills 扩展、子 Agent 与后台任务回填
- [Agent 角色配置调查笔记](../Agent角色/Chatbox-Agent角色配置调查笔记.md)：Copilot 角色模型、会话设置来源、Skills/Agent Mode/MCP/知识库配置
- [Chat 调查笔记](../Chat/Chatbox-Chat调查笔记.md)：聊天概览、核心对象与状态权威、专项导航
- [Chat UI 调查笔记](../Chat UI/Chatbox-ChatUI调查笔记.md)：工作台结构、Composer、消息操作、键盘/无障碍、桌面集成
- [LLM 渠道管理调查笔记](../LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md)：Provider/渠道模型、配置生命周期、凭据、重试与连接测试
- [仓库分布调查笔记](../仓库分布/Chatbox-仓库分布调查笔记.md)：模块、语言、测试与跨平台代码组织
- [会话与消息管理调查笔记](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)：持久化模型、生命周期、分支、索引与检索
- [媒体创作调查笔记](../媒体创作/Chatbox-媒体创作调查笔记.md)：Image Creator 主链、参考图 DAG、取消/恢复/重试、Agent 回填
- [对话导出与分享调查笔记](../对话导出与分享/Chatbox-对话导出与分享调查笔记.md)：Markdown/TXT/HTML 导出、备份 ZIP v2、VibeDrop 发布边界
- [对话请求与上下文调查笔记](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)：提交入口、上下文拼装、流式节流落盘、停止与回写
- [应用界面基础设施调查笔记](../应用界面基础设施/Chatbox-应用界面基础设施调查笔记.md)：界面栈、弹窗/Toast/主题、错误处理、响应式
- [消息渲染调查笔记](../消息渲染器/Chatbox-消息渲染调查笔记.md)：消息模型、contentParts 渲染、Markdown/Artifact、列表虚拟化
- [独特功能调查笔记](../独特功能/Chatbox-独特功能调查笔记.md)：团队 API 资源共享、Image Creator、Copilots 能力卡与归并、声明不符项
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Chatbox-生成式输出与运行时调查笔记.md)：代码执行沙箱、产物持久化、HTML artifact 预览、能力等级评估 G3
