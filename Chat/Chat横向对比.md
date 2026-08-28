# Chat 横向对比（概览与跨类目导航）

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、DeepSeek Harness、Dify、Hermes Agent、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、Risuai、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-28
>
> 依据：会话与消息管理、对话请求与上下文、Chat UI、消息渲染器四个类目的单项目调查笔记及横向对比；本文档只保留跨层综合结论
>
> 对比方法：本文档为导航性总览，详细表格已迁入三个新类目的横向对比；只保留能够同时解释数据层、执行层和交互层的综合结论
>
> 对比范围：跨层综合结论、选择提示；会话数据在[会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)，执行语义在[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)，用户工作流在[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)，通用界面基础设施在[应用界面基础设施横向对比](../应用界面基础设施/应用界面基础设施横向对比.md)
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

十九个项目里，"消息构建""分支""搜索""流式持久化""中断"虽然名称相近，底层实现却分属不同层次。新增项目补充了几种边界：IM 事件流水线（AstrBot）、主进程会话运行时（DeepChat）、已发布应用的服务端聊天/工作流调用面（Dify）、独立 Agent 后端（Hermes Agent）、前端直连模型（Jan、NextChat）、服务端协同聊天系统（Open WebUI）、主链尚未接通持久化的薄客户端（Manifold Desktop）、前端内存权威 + 整库增量编码落盘的无路由单页应用（Risuai）、终端本地 Agent 会话运行时（Pi，自研 agent-loop + JSONL 追加型树会话），以及服务端 Agent 会话运行时（OpenCode，SQLite 权威 + 事件广播 + 客户端投影，Web 与 TUI 共用）与事件溯源驱动循环的 Agent 会话运行时（DeepSeek Harness，ReactLoopAgent 驱动 turn/step 生命周期，边界全部是 durable session 事件）。VCPToolBox 不提供最终用户聊天 UI，仅参与消息构建与网关编排对比。

AIO Hub 的排队语义已明确到“目标父节点至根路径”：同一路径顺序等待，空闲分支可并行生成；Cherry Studio 的 Agent 聊天则把 Claude Code、Pi 与 DeepSeek Harness 收束进同一调度与持久化边界。VCPChat 的聊天视图、流投影和历史写入已拆为各自的所有者，因此也进一步说明聊天主链的生命周期与消息磁盘事实源是两层问题。

## 跨层综合结论

### 横向看，SDK 选型实际在决定什么

1. **谁是消息的规范拥有者。** Chatbox、Cherry Studio、Jan 把 SDK 当作调用层契约，Session/Topic/Thread 仍由应用定义；AIO Hub、LobeHub、DeepChat 把规范放在自研运行时；Hermes Agent、Open WebUI 放在独立后端；SillyTavern 和 VCPChat 则依靠原始消息与扩展字段/协议标记。这个边界影响历史数据能否脱离当前 Provider 解释，也影响接入新 Provider 时只需增加适配器，还是要增加一套请求分支。
2. **标准化发生在哪一层。** 调用层标准化（Chatbox、Cherry Studio、Jan）主要处理 Provider 流差异；主进程/运行时标准化（LobeHub、AIO Hub、DeepChat）还统一工具、上下文和展示投影；AstrBot、Hermes Agent、Open WebUI 分别把这类职责放在事件流水线、Agent 会话后端和协同服务中；VCPToolBox 只统一请求预处理，会话仍由调用方负责。仅看依赖中是否出现 SDK，无法判断系统的标准化范围，比较时要先区分所在层级。
3. **Agent 是否被视为普通消息的扩展。** Cherry Studio 选择单独的 Claude Code SDK；DeepChat 把 Agent turn、pending input 和工具交互变成主进程 transcript 的一部分；Hermes Agent 让子代理本身成为真实子会话；LobeHub/AIO Hub 在自研运行时中统一承接；SillyTavern/VCPChat 则通过字段或协议标记扩展。它们对审批、工具步骤、恢复状态和子会话可见性的表达能力并不相同。
4. **短期接入速度与长期语义控制的交换。** 成熟 SDK 可以减少 Provider 适配工作，但项目需要接受其事件模型和升级节奏；自研主链可以按产品语义设计消息树、流式落盘和工具循环，同时承担兼容性、测试和迁移责任。SillyTavern 的多分支兼容、AIO Hub 的协议一致性，分别体现了这两种取向。
5. **故障应归因到哪里。** SDK 边界清晰时，可以把 Provider 错误与应用状态错误分层定位；协议/网关自研较多时，错误可能发生在消息重写、标记解释或递归工具循环中。排查这类问题需要同时保留原始请求、转换后请求和执行快照，否则很难定位模型输出偏差的具体环节。

评估 Chat 应用的 SDK 使用情况时，应比较五件事：**规范消息由谁定义、流式事件在哪里归一化、工具和 Agent 生命周期由谁承接、会话数据能否脱离当前 Provider 恢复，以及失败时能否观察到每次转换。** 这些问题比依赖名称更能解释架构取向。

### 搜索：索引、命中粒度和跳转能力仍是三件事

结论：Chatbox 与 DeepChat 已确认能从数据层命中并定位具体消息（Chatbox 走 IndexedDB Session 扫描，DeepChat 走 FTS5 全文索引 + 命中 message_id 定位）；LobeHub、Hermes Agent 具有数据库或搜索文档基础，但用户可见定位链路的证据不齐；Jan、Open WebUI、AIO Hub、Manifold Desktop 主要返回会话级结果；Cherry Studio 与 VCPChat 分别受虚拟 DOM 和多模态内容形态限制。现有笔记仍未确认任何项目完整满足"持久化消息索引 + 跨分支/跨会话命中 + 直接定位具体消息"三个条件（DeepChat 的 FTS5 覆盖消息级命中与定位，但索引的写入触发点和清理策略本次未完整追踪）。逐项目细节见[会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)与[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)。

### 中断/取消生成：按钮停止、任务取消和请求中止不是同一层

VCPChat 仍是"同一产品两条路径不对称"证据最完整的案例。Hermes Agent 的前端本地定稿、Manifold Desktop 的回调式 stop token、Open WebUI 的跨实例任务取消分别处在不同层级。其余项目缺少同等深度证据，只能标为未验证，不能从按钮存在推断请求已被中止。逐项目中断层级见[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)，用户可见的停止入口与反馈见[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)。

### UI 交互与呈现的跨项目结论

1. **"消息渲染"至少有四层含义**：AIO 当前把消息树编译成活动路径并完整挂载 DOM，再用 `content-visibility` 裁剪屏外渲染；它早期曾使用 TanStack Virtual，后因聊天场景的动态高度和滚动稳定性问题撤回。Chatbox/Cherry/Lobe/Jan 也把消息模型先编译成活动路径或 flat list；DeepChat 做测量驱动的窗口化，NextChat 只做固定页窗；SillyTavern/VCPChat/Manifold 主要增量或整段修改 DOM；VCPToolBox 只改第三方 DOM，不拥有消息列表。渲染实现细节在[消息渲染器横向对比](../消息渲染器/消息渲染器横向对比.md)。
2. **停止生成的视觉状态与执行状态可能不同**：VCPChat 单聊只通知远端，Hermes Agent 前端先本地定稿再请求后端中断、两者存在中间窗口，Manifold 的 stop token 不能打断阻塞读取；Open WebUI 将停止建模为可跨实例路由的任务取消。评估停止能力时，需要继续追到请求或任务控制层。
3. **输入区承载了大量 Agent 交互**：DeepChat 的 steer/queue/permission、Jan 的排队与附件、Open WebUI 的工具确认和终端事件，与 AIO/Chatbox/Cherry/Lobe/VCPChat 的附件、知识库、mention、审批共同组成了输入协议。
4. **窗口化与搜索存在结构性冲突**：Chatbox/Cherry/LobeHub/DeepChat 通过虚拟或窗口列表控制长会话成本，但 Cherry 的 DOM 搜索以及任何依赖已挂载节点的扩展会漏掉窗口外消息；NextChat 的固定页窗也需要显式移动窗口。AIO 曾经也有这一类窗口化方案，但在消息高度动态、倒序加载和滚动定位稳定性上付出的复杂度过高，后来改为完整 DOM + `content-visibility`，以保留真实 DOM 定位能力并把成本转给浏览器的屏外渲染裁剪。SillyTavern/VCPChat 没有这个漏搜原因，却把成本转移到整段 DOM。
5. **UI 调查应记录"呈现投影"**：AIO 的 linear/force-graph、Cherry 的 `TopicBranchPanel` 消息树图（React Flow，选分支辅助面板）、Open WebUI 的 side-by-side/MoA 与 Overview 消息树图（SvelteFlow，点击节点切分支）、VCPChat 的 bubble/panel/immersive、Chatbox 和 Jan 的分支版本导航，都说明同一份会话数据可以有多种用户可见投影；仅记录 `Session/Topic/Thread` schema 无法解释用户实际如何切换、编辑、停止和定位。

## VCPToolBox：不参与会话/UI 对比，但参与消息构建

VCPToolBox 不提供最终用户聊天主界面，但仍负责消息构建。它把调用方提交的历史归一化为 OpenAI `messages`，在首次请求前完成裁剪、注入和预处理；模型输出 VCP 工具标记后，再把 assistant 正文和工具结果 user payload 追加到内存上下文并递归请求。`FinalContextViewer` 只捕获首次上游 fetch 前的最近 5 份内存快照，不包含后续工具递归消息，也不是会话数据库。AdminPanel-Vue 是独立进程（监听 `PORT+1`），与聊天主链物理解耦；OpenWebUISub 是运行在第三方聊天页面里的浏览器脚本。给模型的工具结果使用 `<!-- VCP_TOOL_PAYLOAD -->` user 消息，给前端的可见结果由 `vcpInfoHandler.js` 另行写入 SSE/最终 JSON，两者不能混为同一份消息。完整证据链见[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)的 VCPToolBox 一节。

### DeepSeek Harness：事件溯源驱动的 Agent 会话运行时

DeepSeek Harness 是构建在 vendored Cordis 插件框架上的 agent harness，"一切皆插件"。对话运行核心是 agent-loop 的 ReactLoopAgent：step 是一次模型请求加其工具调用，turn 是零或多个 step，边界全部是 durable session 事件（turn/start → step/start → user/message → assistant/chunk* → assistant/message → tool/call* → tool/result* → step/end → turn/end）。与其他项目最大的差异是事件溯源：Session 是追加式事件日志、唯一事实源，模型历史由日志派生，UI 只是事件消费者；事件分 session 持久、agent live、capability 策略三域。输入经 inbox 两条 pending 列表投递，followup/steer 唤醒驱动、inject 只排队；取消是协作式 abort；headless 一键任务。与 pi 的关联仅在 llm-pi-ai 适配层，循环无继承证据。

## Risuai：前端内存权威 + 整库增量编码的多载体单页应用

Risuai 的产品表面是桌面 GUI（Tauri）、Web、移动 Web 与 Node 服务器内嵌四种载体切换的无路由单页应用，Node 侧只提供托管与存储适配，不拥有会话状态。消息规范由单一内存权威 `DBState.db` 持有，角色、会话、消息与全部设置都挂在同一个对象上，保存循环按角色分块增量编码整库写入单一二进制存档 `database/database.bin`，与 SillyTavern 每轮整份重写 JSONL 的取向形成对照。端到端主链交接点是 `sendChat` 单文件编排：UI 层直接 push 消息后，上下文、记忆、组装、渠道请求与流式回写全部在该入口串起，全程直接读写权威对象。Agent 与消息扩展取内存优先：重roll 候选只驻留内存、不随消息落盘，与 SillyTavern 的持久 swipe 字段相反；"分支"表达为整份会话副本加注释回链，而不是消息树。

## 选择提示（基于已核实机制）

| 侧重点 | 项目 | 已确认的边界 |
| --- | --- | --- |
| 数据库级消息树与事务约束 | Cherry Studio | SQLite 有外键和 CHECK 约束；三层数据管道增加调试复杂度 |
| 跨 IM 平台事件流水线、群聊唤醒与 follow-up | AstrBot | 核心单位是 UMO 和异步事件，WebChat 只是一种入口 |
| 主进程权威 transcript、Agent 输入队列与工具交互 | DeepChat | main/renderer 之间仍有 IPC revision、cursor 和事件顺序边界 |
| CLI/TUI/桌面共用 Agent 后端、跨压缩 lineage | Hermes Agent | 会话句柄（sid）与持久 session id 必须区分，压缩轮转后按 lineage root 重锚 |
| 本地模型、AI SDK 流式 UI 与消息版本树 | Jan | 桌面端每轮整写 JSONL，未完成回合不恢复 |
| 应用层树与分支记忆 | AIO Hub | 搜索无索引；崩溃后残留"生成中"节点已由加载路径自动修复（`repairInterruptedGeneratingNodes`），修复行为未做运行复现 |
| 简单会话记录、归档优先于删除 | Chatbox | 恢复归档不会重排，拖拽排序仅限同分组 |
| Agent 工具过程的可观察流程 | LobeHub | 双层 store 各自 parse；审批逻辑位于全局 store |
| 纯客户端部署，集中保存 Mask、摘要和工具状态 | NextChat | IndexedDB/localStorage 是主存储，本地数据与同步边界需单独评估 |
| 服务端权限、分享、多模型与跨实例任务控制 | Open WebUI | history/消息表双写，Socket.IO 事件状态组合较多 |
| 文件级分支、检查点与社区扩展 | SillyTavern | 长聊天不虚拟化；正则按展示、prompt、存储位置分层，渲染结果可能随聊天长度变化 |
| 多角色群聊与长期 Topic 关系 | VCPChat | 单聊没有本地 abort，可靠中止依赖远端 |
| 终端本地编码 Agent、追加型树会话与工具循环 | Pi | 单会话单循环；消息编辑以分支表达；无消息级搜索索引；系统提示不随会话保存 |
| 服务端 Agent 会话运行时、事件广播与多前端共用 | OpenCode | SQLite 权威 + SSE 投影；删除式 revert 与复制式 fork；无消息级全文搜索；Web/TUI 两套渲染栈 |
| 事件溯源驱动循环、插件层循环控制与 headless 一键任务 | DeepSeek Harness | turn/step 边界全部是 durable 事件、可重放重建；模型可见 ⟺ 已记录；内置无 turn 预算；与 pi 无循环继承证据（仅 llm-pi-ai 适配层） |
| 前端内存权威、无路由多载体单页应用与整库增量编码存档 | Risuai | 重roll 候选不落盘；分支为整份会话副本加注释回链，非消息树；未找到消息级搜索索引 |

Manifold Desktop 当前更适合作为"聊天主链尚未接通持久化时会出现哪些断层"的对照样本，不宜仅凭已存在的 SessionManager API 判断会话能力已经完成。

以上内容只描述已核实的产品与源码机制，不构成性能、安全或 Agent 能力排名。分支、流式和搜索的详细证据见对应类目的单项目笔记与横向对比；工具调用权限与 Agent 配置见 `项目调查笔记/Agent工具`；消息渲染层的公共问题见 `项目调查笔记/消息渲染器`。

## 迁移与导航

- 会话单位、存储模型、分支、索引与搜索（数据侧）：[会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)
- SDK 主链、消息构建、流式持久化、中断：[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)
- 工作台、搜索入口、消息操作、停止反馈、键盘无障碍：[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)
- 消息渲染实现：[消息渲染器横向对比](../消息渲染器/消息渲染器横向对比.md)
- 通用界面盘点（弹窗/Toast/主题/图片预览/动画）：[应用界面基础设施横向对比](../应用界面基础设施/应用界面基础设施横向对比.md)
- Dify 专项：[Chat](Dify-Chat调查笔记.md)、[会话与消息管理](../会话与消息管理/Dify-会话与消息管理调查笔记.md)、[对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)、[Chat UI](<../Chat UI/Dify-ChatUI调查笔记.md>)、[消息渲染器](../消息渲染器/Dify-消息渲染器调查笔记.md)、[Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)、[LLM 渠道管理](../LLM渠道管理/Dify-LLM渠道管理调查笔记.md)、[生成式输出与运行时](../生成式输出与运行时/Dify-生成式输出与运行时调查笔记.md)
- Risuai 专项：[会话与消息管理](../会话与消息管理/Risuai-会话与消息管理调查笔记.md)、[对话请求与上下文](../对话请求与上下文/Risuai-对话请求与上下文调查笔记.md)、[Chat UI](<../Chat UI/Risuai-ChatUI调查笔记.md>)、[消息渲染](../消息渲染器/Risuai-消息渲染调查笔记.md)、[Agent 角色](../Agent角色/Risuai-Agent角色配置调查笔记.md)、[LLM 渠道管理](../LLM渠道管理/Risuai-LLM渠道管理调查笔记.md)、[Agent 工具](../Agent工具/Risuai-Agent工具调查笔记.md)、[生成式输出与运行时](../生成式输出与运行时/Risuai-生成式输出与运行时调查笔记.md)、[应用界面基础设施](../应用界面基础设施/Risuai-应用界面基础设施调查笔记.md)、[独特功能](../独特功能/Risuai-独特功能调查笔记.md)、[对话导出与分享](../对话导出与分享/Risuai-对话导出与分享调查笔记.md)、[仓库分布](../仓库分布/Risuai-仓库分布调查笔记.md)
