# Chat 横向对比

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、Hermes Agent、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-10
>
> 依据：本目录十六份单项目调查笔记（均带文件路径+行号证据）；本文档只做跨项目综合，不重复调查代码，具体证据请进入对应项目笔记核实
>
> 对比方法：基于本目录十六份单项目调查笔记，按会话单位、消息构建、消息存储、分支、搜索、流式持久化和中断等共同维度逐项对照；未被单项目笔记共同覆盖的 UI 专项单独标注范围
>
> 对比范围：会话单位、消息构建、消息存储、分支、搜索、流式持久化、中断和跨项目差异
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

说明：本文档以十六份笔记里已核实的具体机制为原料，做跨项目横向对照。2026-08-07 新纳入 AstrBot、DeepChat、Hermes Agent、Jan、Manifold Desktop、NextChat、Open WebUI；2026-08-10 新纳入 Pi（终端编码 Agent，CLI/TUI/print 三种模式共享同一 AgentSession）与 OpenCode（服务端会话运行时 + SQLite 持久化 + SSE 事件投影）。旧版 UI 深挖附录仍只覆盖原先六个有专项证据的聊天界面。

## 结论摘要

十六个项目里，“消息构建”“分支”“搜索”“流式持久化”“中断”虽然名称相近，底层实现却分属不同层次。新增项目补充了几种边界：IM 事件流水线（AstrBot）、主进程会话运行时（DeepChat）、独立 Agent 后端（Hermes Agent）、前端直连模型（Jan、NextChat）、服务端协同聊天系统（Open WebUI）、主链尚未接通持久化的薄客户端（Manifold Desktop）、终端本地 Agent 会话运行时（Pi，自研 agent-loop + JSONL 追加型树会话），以及服务端 Agent 会话运行时（OpenCode，SQLite 权威 + 事件广播 + 客户端投影，Web 与 TUI 共用）。VCPToolBox 不提供最终用户聊天 UI，仅参与消息构建与网关编排对比。

## SDK 使用与聊天主链

“使用 SDK”在这里指消息生成和流式组装的主链，而不是 UI 框架或某个可选插件。它决定了项目继承第三方消息/工具契约的程度；同为 OpenAI-compatible 请求也不代表采用同一 SDK。

| 项目 | 主链中的 SDK / 协议封装 | 对会话与消息模型的影响 |
| --- | --- | --- |
| AIO Hub | 自研 LLM Core、VCP 文本协议与可重放流源 | `ChatSessionDetail` 和树形消息节点由应用定义，流式状态由 AST/Patch 体系承接 |
| AstrBot | Python 自研事件总线、九阶段流水线与 Agent runner | OpenAI 格式历史只是持久化载体；会话顺序、唤醒、follow-up 和压缩语义由 AstrBot 流水线控制 |
| Chatbox | 调用层使用 Vercel AI SDK；会话层使用自定义 `contentParts` | SDK 归一化 Provider 流，历史、分支和持久化仍是应用自己的 Session 模型 |
| Cherry Studio | Vercel AI SDK `UIMessage` / `readUIMessageStream`；Agent 会话另走 Claude Code SDK | `UIMessage.parts` 是普通聊天的结构化消息契约，Agent Session 有独立持久化路径 |
| DeepChat | main process 内的自研 Session/Agent runtime 与 typed IPC | transcript、assistant blocks、pending input 和 Provider 流由主进程统一管理，renderer 只维护投影与缓存 |
| Hermes Agent | Python `AIAgent` + JSON-RPC/WebSocket 桌面协议 | 后端 SQLite 是真相源；桌面按 lineage/runtime 两类 ID 合并流式事件与持久化历史 |
| Jan | Vercel AI SDK `useChat` + 自研 `CustomChatTransport` | UI message、ThreadMessage 和文件/SQLite 持久化模型之间显式转换，transport 掌管上下文和 Provider 参数 |
| LobeHub | 自研 ModelRuntime、消息 Store 与 `conversation-flow` | Provider 调用与 DB 消息分层；展示路径由 flow 从消息记录重建 |
| Manifold Desktop | WebView2 `postMessage` + C++ Provider 流式桥 | 前端 `messages[]` 与 C++ 会话文件 API 未接通，assistant 流只更新 DOM，未形成完整会话模型 |
| NextChat | Zustand 会话状态 + 自研 Provider adapter/SSE 回调 | 单一 `ChatSession[]` 同时承载消息、Mask、摘要、工具状态和流式占位，没有服务端 conversation runtime |
| Open WebUI | FastAPI 中间件/Provider 适配 + Socket.IO 事件协议 | 服务端同时维护 history JSON 与消息行，约 25 类事件统一承载内容、状态、任务和工具交互 |
| OpenCode | 服务端 `SessionPrompt`/`SessionProcessor` + Vercel AI SDK `streamText`；SSE 事件协议 | SQLite 是权威源，`message.updated`/`message.part.updated`/`message.part.delta` 事件经 SSE 广播，App 以 16ms 批量 flush 投影到 Solid store，TUI 同协议订阅 |
| Pi | 自研 `AgentSession` + `agent-loop`，Provider 调用走 `packages/ai` 统一流接口 | JSONL 会话树由应用定义；流式事件（text/thinking/toolcall delta）统一转成 `message_update`，UI 全量重建 |
| SillyTavern | Provider 专属请求分支和浏览器/后端 `fetch` | `chat[]` 与 JSONL 格式不依赖统一消息 SDK，兼容语义由本地字段与扩展维持 |
| VCPChat | 自定义 VCP IPC/文本协议，单次 `fetch` 到网关 | Topic `history.json` 保存原始消息和上下文，VCP 标记在客户端解释 |
| VCPToolBox | 不适用：没有最终用户聊天主链 | 它处理入站协议和模型编排，不保存最终用户会话 |

### SDK/自研边界意味着什么

上表描述的是代码事实，下面只做基于这些事实的设计推断。这里的“意味着”不是项目作者的明示动机；它表示这种边界通常会把哪些责任放在应用内，以及会带来什么代价。

| 项目 | 更像是在做的设计决策 | 换来的能力 | 主动承担的成本 |
| --- | --- | --- | --- |
| AIO Hub | 把消息协议、会话树和可重放流作为产品主链，自研完整实现 | AST/Patch、VCP 文本协议、树形会话和流式恢复可以共享一套语义；第三方 Provider 位于适配层 | 需要自行维护协议、错误语义、流式边界和兼容层；外部 SDK 的新能力不会自动进入主链 |
| AstrBot | 把跨 IM 平台的消息处理建模为事件流水线，不承担桌面聊天页面职责 | 九阶段管线、UMO 锁、follow-up 严格序和插件阶段可以独立演进，适合多平台群聊与机器人场景 | 事件任务全局无背压；洋葱式异步生成器增加异常栈和收尾时序的理解成本 |
| Chatbox | 只在 Provider/流式调用层借力，产品数据模型仍由应用拥有 | 以较低成本统一多 Provider 的流事件，同时保留 `Session`、`Thread`、`Fork` 和 `contentParts` 这些产品语义；替换 Provider 不必改写会话存储 | SDK 的输出要映射到自定义消息模型，形成“SDK 契约 + 应用契约”两层边界；工具调用、压缩和分支越复杂，适配代码越多 |
| Cherry Studio | 普通聊天和 Agent 采用不同 SDK，按交互复杂度拆分协议 | 普通聊天可直接使用 `UIMessage.parts` 的结构化流；Claude Code SDK 可以单独承载 Agent 的工具、审批和执行生命周期，不必把 Agent 事件硬塞进普通消息 | 两条主链和两套持久化语义需要明确转换边界；跨模式复制、搜索、恢复和 UI 展示容易出现不一致 |
| DeepChat | 让主进程拥有 session、transcript、Agent 和 Provider runtime | pending input、工具交互、流式 block、搜索和持久化能共享一个有序 transcript；renderer 可专注窗口化展示 | main/renderer 间的 revision、cursor 和 IPC 事件顺序成为额外一致性边界，崩溃恢复与乱序行为仍需运行验证 |
| Hermes Agent | 让跨界面的 Python Agent 后端作为权威状态源 | CLI/TUI/桌面复用同一会话与工具能力，lineage id 可跨压缩轮转稳定引用会话 | session、lineage、runtime 三类身份需要持续翻译；前端“停止显示”与后端真实中断处在不同层 |
| Jan | 用 AI SDK 承接流式 UI，用自研 transport 保留本地模型和上下文控制 | 桌面/移动端共享前端逻辑，仍能注入本地 Provider 参数、附件清洗、压缩和树形版本 | UI 消息、持久化消息和 Provider 请求存在多次转换；桌面 JSONL 每次整文件重写，未完成回合不恢复 |
| LobeHub | 将 Provider SDK 留在适配层，自建 ModelRuntime、Store 和 flow | 可以把模型调用、权限、工具执行、消息持久化和展示投影按自己的运行时编排；适合把 Agent 过程记录为可观察流程 | 需要长期维护 Provider 适配和运行时抽象；全局 Store 与会话 Store 各自 `parse` 的重复计算，带来同步与引用稳定性成本 |
| Manifold Desktop | 保持前端与 C++ Provider 桥尽量薄 | 请求链短，前端标签页可直接驱动 Provider 流 | 会话存储 API 没有接入正常聊天主链，导致回复不回写上下文、多标签共享广播和重命名覆盖等基础一致性缺口 |
| NextChat | 把会话、摘要、工具和请求编排集中在一个客户端 store | 部署简单，IndexedDB/localStorage 即可保存完整本地状态，Provider adapter 可在同一状态机内处理工具回注 | 单 store 承担较多职责；token 估算、摘要质量、多端同步和工具结果复用都有各自的未验证边界 |
| Open WebUI | 把聊天建模为服务端协同系统，而非单机状态容器 | 权限、分享、归档、多模型、任务取消、工具交互和跨实例事件可以统一落在后端 | history JSON 与消息表双写需要持续对账；Socket.IO 事件协议和大型前端状态机扩大了状态组合面 |
| SillyTavern | 优先保证 Provider 和社区扩展的开放兼容，不设统一消息 SDK | 可以容纳 text-completion、OpenAI messages 及大量非标准字段，扩展可直接介入请求、正则、World Info 和存储格式 | 请求分支、字段语义和生命周期由本地约定拼接，类型保证弱；新增 Provider 往往意味着新增分支，长期容易产生行为差异和回归面 |
| VCPChat | 把客户端定位为 VCP 协议的呈现与交互端，把编排能力放到网关 | 客户端可以保持较薄，Topic 历史保存原始消息，网关和客户端可相对独立演进；VCP 标记可作为扩展协议承载工具/群聊能力 | 协议契约主要靠约定和客户端解释，标准 SDK 的互操作性、类型校验和错误归因较弱；网关行为不透明时，客户端难以单独诊断完整请求链 |
| VCPToolBox | 明确做“无会话的模型编排网关”，不拥有最终用户聊天模型 | 可以在一次请求内统一桥接多家 API、预算裁剪、Tavern/RAG/工具展开和递归工具循环；调用方继续拥有会话和 UI | 不负责跨请求历史、分支或恢复；调试重点从“聊天记录是否正确”转为“请求重写前后是否一致”，需要额外的快照、追踪和协议文档 |
| OpenCode | 把会话、消息、工具状态和事件流全部放在服务端运行时，Web/TUI/CLI 只是同协议的客户端 | SQLite 权威 + 事件广播，多前端共享同一会话语义；发送、中断、重试、压缩都在服务端闭环 | 前端必须消费 SSE 事件投影，协议版本（v1/V2 协商）影响客户端复杂度；本地纯离线场景仍依赖本地 server 进程 |
| Pi | 把消息协议、工具循环和会话持久化全部放在本地 Agent 运行时，交互模式只是 I/O 层 | CLI/TUI/print 共享同一 AgentSession；事件驱动 + 单 agent 循环语义统一 | 需要自维护流式事件、压缩、重试与终端渲染；多会话并行生成不在设计内 |

### 横向看，SDK 选型实际在决定什么

1. **谁是消息的规范拥有者。** Chatbox、Cherry Studio、Jan 把 SDK 当作调用层契约，Session/Topic/Thread 仍由应用定义；AIO Hub、LobeHub、DeepChat 把规范放在自研运行时；Hermes Agent、Open WebUI 放在独立后端；SillyTavern 和 VCPChat 则依靠原始消息与扩展字段/协议标记。这个边界影响历史数据能否脱离当前 Provider 解释，也影响接入新 Provider 时只需增加适配器，还是要增加一套请求分支。
2. **标准化发生在哪一层。** 调用层标准化（Chatbox、Cherry Studio、Jan）主要处理 Provider 流差异；主进程/运行时标准化（LobeHub、AIO Hub、DeepChat）还统一工具、上下文和展示投影；AstrBot、Hermes Agent、Open WebUI 分别把这类职责放在事件流水线、Agent 会话后端和协同服务中；VCPToolBox 只统一请求预处理，会话仍由调用方负责。仅看依赖中是否出现 SDK，无法判断系统的标准化范围，比较时要先区分所在层级。
3. **Agent 是否被视为普通消息的扩展。** Cherry Studio 选择单独的 Claude Code SDK；DeepChat 把 Agent turn、pending input 和工具交互变成主进程 transcript 的一部分；Hermes Agent 让子代理本身成为真实子会话；LobeHub/AIO Hub 在自研运行时中统一承接；SillyTavern/VCPChat 则通过字段或协议标记扩展。它们对审批、工具步骤、恢复状态和子会话可见性的表达能力并不相同。
4. **短期接入速度与长期语义控制的交换。** 成熟 SDK 可以减少 Provider 适配工作，但项目需要接受其事件模型和升级节奏；自研主链可以按产品语义设计消息树、流式落盘和工具循环，同时承担兼容性、测试和迁移责任。SillyTavern 的多分支兼容、AIO Hub 的协议一致性，分别体现了这两种取向。
5. **故障应归因到哪里。** SDK 边界清晰时，可以把 Provider 错误与应用状态错误分层定位；协议/网关自研较多时，错误可能发生在消息重写、标记解释或递归工具循环中。排查这类问题需要同时保留原始请求、转换后请求和执行快照，否则很难定位模型输出偏差的具体环节。

评估 Chat 应用的 SDK 使用情况时，应比较五件事：**规范消息由谁定义、流式事件在哪里归一化、工具和 Agent 生命周期由谁承接、会话数据能否脱离当前 Provider 恢复，以及失败时能否观察到每次转换。** 这些问题比依赖名称更能解释架构取向。

## 消息构建：历史如何转换为模型输入

| 项目 | 进入构建器的历史 | 注入、裁剪与最终模型输入 |
| --- | --- | --- |
| AIO Hub | 当前活动叶子到根的路径，已被压缩节点遮罩的原消息不进入上下文 | 管道依次处理会话加载、异步结果、正则、转写、世界书、预设、知识库、变量、Token 限制、格式化和附件解析；最终 Payload 与原始节点数组不同 |
| AstrBot | 当前 conversation 的 OpenAI 格式历史；群聊还可取 UMO 环形原始消息 | 先轮次截断，再在 82% token 阈值触发摘要或按轮截断，仍超限时折半；persona、知识库结果和群聊 `<system_reminder>` 另行注入 |
| Chatbox | 目标 assistant 之前的当前 Session/Thread 消息 | `buildContext` 处理压缩点、附件与最大上下文消息数；知识库、网页浏览和 Agent Mode 注册为工具，随后注入 system instructions 并转换为模型消息 |
| Cherry Studio | `getPathToNode(anchor)` 的路径；最近 `data-clear` 之前的消息被舍弃 | 先按上下文窗口生成或复用持久化压缩摘要，再由 AI SDK 将 UI parts 转为模型消息；多模型时同一用户消息可派生多份独立请求 |
| DeepChat | transcript 中从 summary cursor 开始的完整 turns；重试/恢复按 `orderSeq` 截到目标 assistant | system、skills、tools、checkpoint、memory 和 directives 组成 leading messages；超预算先移除 memory/directives，再保留完整尾部 turns，固定内容仍超限则报错 |
| Hermes Agent | SQLite/内存历史与压缩轮转后的当前 lineage 上下文 | `build_turn_context` 恢复系统提示、做预飞行压缩、注入记忆/插件上下文和运行期说明；轮转可更换 session id 但保留 lineage |
| Jan | 当前 Thread 的活动 `parentId` 路径与本轮输入 | transport 清洗附件和孤立消息，按上下文上限选择压缩或裁剪；system instructions、文件说明、网页工具和推理参数在不同层注入 |
| LobeHub | 当前 `ConversationContext` 的 display messages，发送前排除仅本地消息 | 输入区把文件、技能、工具和选择区编码为 metadata 或运行上下文；最终预算与 provider payload 由 client agent/Gateway runtime 决定，本次未逐 provider 展开 |
| Manifold Desktop | 当前标签页内的整个 `messages[]` | 只追加 system prompt 后经 WebView2 发给 C++；assistant 流未回写数组，因此第二轮缺少上一轮 assistant，上下文链实际不完整 |
| NextChat | 当前 session 中从 `clearContextIndex` 起的非错误消息 | 顺序为 system prompt → `memoryPrompt` → Mask context → 受消息数/token 估算限制的近期历史 → 当前 user；工具/MCP 结果再进入同一状态机 |
| Open WebUI | 持久会话由后端从 DB/history 加载；临时会话由前端携带历史 | 中间件依次处理 skill、memory、搜索、图像、代码解释器、工具和文件；多模型 fan-out 共用用户输入，后端按 message id/parent id 管理上下文 |
| SillyTavern | `chat[]` 过滤掉普通 system 消息后得到 `coreChat` | 先应用正则和附件内容，再经过 interceptor、World Info 和 API 分支格式化，产出 text-completion prompt 或 OpenAI messages；不同后端没有统一 payload |
| VCPChat | 群聊已核实为内存 `groupHistory` 的当前快照；单聊最终请求组装未在本次笔记逐步展开 | 群聊按成员串行构建各自上下文，下一位成员会看到上一位刚落盘的回复；单聊和群聊不应据此视为同一构建链 |
| VCPToolBox | 调用方提交的线性 `messages`；Responses、Anthropic、Gemini 请求先桥接成该格式 | 请求级管线依次做字符预算裁剪、Tavern 注入、模型路由、变量/Agent/Toolbox 展开、多模态与 RAG/Timeline/OneRing/折叠预处理、Detector 和角色拆分；工具循环再追加 assistant 正文与 user `VCP_TOOL_PAYLOAD`。它不拥有跨请求会话，但会实质重写最终模型输入 |
| Pi | 当前叶子到根的条目路径；compaction/branch_summary 条目被投影为摘要消息 | `buildSessionContext` 按路径组装，system prompt（SYSTEM.md/AGENTS 链/skills）由 `buildSystemPrompt` 拼装；工具结果以 toolResult 消息进入下一轮；token 超预算时压缩（摘要消息 + 保留条目）|
| OpenCode | 从 SQLite 重读的全量历史（`MessageV2.toModelMessagesEffect`，message-v2.ts:131-415） | system 拼装：agent.prompt ?? provider 风格 → env/AGENTS.md 指令/MCP 指令/skills → user.system（`llm/request.ts:56-66`）；media 从 tool result 抽离为独立 user 消息；溢出按 `model.limit.input - 20k` 检测，compaction 重排为 [compaction-user, summary-assistant, tail, continue-user] |

**结论**：只比较“是否有上下文”不足以区分实现。客户端应用、主进程 runtime、Agent 后端、Web 服务和无会话网关都可能负责最终输入的一部分。Manifold Desktop 的历史数组没有回写 assistant 流，因此第二轮请求仍缺少上一轮回复。比较具体行为时，应同时标注构建位置、历史真相源、压缩顺序、工具注入层和未覆盖边界。

## 会话单位与存储模型

| 项目 | 会话主体 | 存储粒度 | 持久化方式 |
| --- | --- | --- | --- |
| AIO Hub | Session（`ChatSessionDetail`；Agent 是显示及消息元数据关联，并非 Session 的父级） | 索引/详情分文件：`sessions-index.json` + `sessions/{id}.json` | 撤销/重做栈显式从不落盘（`saveSession` 写盘前 `delete history`） |
| AstrBot | UMO 标识的 session；其下可切换多个 conversation | SQLite `conversations.content` 保存 OpenAI 格式 JSON；当前 conversation id 存 SharedPreferences | 当前 conversation 选择 60 秒防抖写入；群消息历史另有可选表与条数上限 |
| Chatbox | Session（`SessionMetaRecord` + 完整对象） | IndexedDB：meta 表分页游标 + 完整 session 对象表 | 流式内容 UI 缓存与落盘分离（见下节），故意不做 DB version 升级 |
| Cherry Studio | Topic（真实 adjacency-list 树） | SQLite，`message.parentId` 自引用外键 + DB CHECK 约束 | `activeNodeId` 指针 + `getPathRowsToNodeTx` 反向 walk 渲染当前分支 |
| DeepChat | Session；subagent session 仍是可读 transcript | SQLite：message 行与 assistant block 分表，以 `(session_id, order_seq)` 建索引 | 流式中间态更新 block/pending，完成或错误时同步正文、状态、搜索文档和 Tape facts |
| Hermes Agent | Session + 跨压缩轮转稳定的 lineage root | profile 级 `state.db`；运行期另写 JSONL 日志 | 后端批量事务落库并用 persisted marker 去重；renderer 只是带版本仲裁的缓存 |
| Jan | Thread | 桌面每 thread 一个目录：`thread.json` + `messages.jsonl`；移动端 SQLite | 桌面每次整文件重写但有 per-thread 锁；`resume:false`，不恢复未完成回合 |
| LobeHub | Agent/topic/thread（多维 `messageMapKey`） | 服务端 + 本地双份缓存，双层 Store 各自独立解析 | 见下节"双层 parse"问题 |
| Manifold Desktop | Chat tab / 设计上的 session 文件 | `%LOCALAPPDATA%\Manifold\sessions\<id>.json` API | 正常聊天主链未调用保存，关闭标签即丢失；重命名按整 JSON 覆盖还可能清空消息 |
| NextChat | `ChatSession` | 整个 Zustand store 默认写 IndexedDB，失败回退 localStorage | session 数组内同时保存消息、Mask、摘要和截断索引；本地无通用加密层 |
| Open WebUI | Chat；内部子代理也可占独立会话行 | `chat.chat.history` JSON 快照 + `chat_message` 行双写 | 前端读快照，行表供增量同步/统计/恢复；`reconcile_messages_by_chat_id` 负责对齐 |
| SillyTavern | 聊天文件（`chat[]` 内存数组） | 单个 JSONL 文件，首行是 header，之后每行一条消息 | 一次性整份读入内存/DOM，无分页，保存时整份覆写 + UUID 完整性校验防并发覆盖 |
| VCPChat | Agent/群组 下的 Topic | 每个 Topic 一个 `history.json`（裸数组，无 schema 版本号） | 整份覆盖写，无原子写保护（无临时文件+rename） |
| VCPToolBox | 不适用 | 不提供最终用户会话存储 | — |
| OpenCode | Session → Message（user/assistant）→ Part（12 种）三层 | SQLite：`session`/`message`/`part` 三表，part 独立存表、读取时批量组装（`core/src/session/sql.ts:22-98`） | 增量落库：prompt 时写 user 消息，流式中每 part 状态迁移即时落库，`text-end` 才完整写文本 part；事件发布与投影分离（`Session.updateMessage/updatePart` 只发事件，projector 写库） |
| Pi | Session（JSONL 文件 = 会话树） | 每会话一个 `.jsonl`，条目带 `id/parentId` 形成树，`leafId` 指针标记当前位置 | 追加型：`message_end` 落盘；第一条 assistant 消息到达时创建文件并整写，之后逐条 append；版本迁移 v1→v3 时重写 |

**存储实现可分为三组**：Cherry Studio、DeepChat、Hermes Agent、Open WebUI、AstrBot 使用数据库行或事务；Chatbox、NextChat 使用 IndexedDB；AIO Hub、Jan 桌面端、SillyTavern、VCPChat 仍有整文件/整对象写入路径，Manifold Desktop 的存储 API 尚未接入正常聊天。介质本身不保证一致性：Open WebUI 需要对齐两份数据，Hermes Agent 需要仲裁三类会话 ID，Jan 虽有文件锁仍按 O(消息数) 重写。

## "分支"不是一回事：消息树、版本、复制和轮转链

这里需要先区分数据结构和操作语义。十五个项目里的“分支”至少包括消息树切换、消息版本、会话复制、文件截断另存、压缩轮转链和多模型并列，不能统一称作“消息树切换”：

1. **真树 + 指针跳转（Cherry Studio）**：持久层是 DB 树（`parentId` 外键 + CHECK 约束保证虚拟根不变式）；切分支时更新 `topic.active_node_id`，渲染再反向 walk 拼出路径。前端另有独立的 `TopicMessageFlowLiveState`（三态 ref 状态机：正常/草稿分支中/草稿取消但指定锚点），处理尚未落库的分支，显示生命周期与持久化树分开。
2. **树 + 兄弟记忆（AIO Hub）**：`parentId`/`childrenIds`/`lastSelectedChildId` 构成应用层树，`BranchNavigator` 用循环索引在兄弟间切换，并用 `lastSelectedChildId` 记住上次选择。重试、切换模型重试和续写分别创建 assistant 兄弟节点、带 prefix 的同内容兄弟节点、以及空子节点；它没有 Cherry Studio 那样的草稿态覆盖层。
3. **多套独立结构叠加（Chatbox）**：会话列表分组只认 `starred`（`SessionMetaSchema` 没有树/分支字段）；Thread 是 Session 内的历史区间，Fork 是同一消息位置的平行分支。两者可以叠加共存，`cleanupEmptyForkBranches` 需要分别处理 root 层和 thread 层，形成笔记所述的双写不一致风险。消息级分支与会话级条目的连接点，是把 thread 移成独立会话。
4. **多模型兄弟组（LobeHub / Cherry Studio 多模型场景）**：多模型 mention 场景下，N 个模型各自产出一条 assistant 消息，共享同一个 `siblingsGroupId`，属于并列结果，不是二选一分支；LobeHub 的 `BranchResolver` 处理的是重新生成后的候选选择，用 `metadata.activeBranchIndex` 存在父消息上，子消息本身不记录激活状态。
5. **独立文件/候选数组，无树（SillyTavern）**：Branch 把 `chat[]` 截断到某条消息后另存为新文件并跳转，Checkpoint 只另存不跳转。两者共享截断函数，但 `extra.bookmark_link` 是单值、`extra.branches` 是数组，记录关系的方式不同。单条消息的候选回复放在 `swipes` 数组中；Branch 可以先选定某个 swipe 再截断。VCPChat 的 Topic 之间没有消息级分支，多个 Topic 是并列历史。
6. **父子树 + 兄弟版本（Jan）**：`parentId` 形成活动路径，`makeSibling` 为编辑或重新生成创建同父新版本，`activeRootId`/版本导航选择可见路径；Continue 则原地续写，不产生新分支。媒体消息编辑回退为纯文本，是版本语义中的明确损失边界。
7. **有序 transcript 上的 fork（DeepChat）**：`SessionTurn` 支持 fork/retry/edit，但上下文恢复主要按 `orderSeq` 截取完整 turn，并非每次都沿 `parentId` 回溯。它更接近“从 transcript 某点复制出新 session/turn”，不能直接等同于 Cherry Studio 的 DB 邻接树。
8. **会话复制与 lineage（Hermes Agent、NextChat）**：Hermes `session.branch` 复制历史并建立 parent/lineage 关系，压缩轮转也会生成新 session id；NextChat 的 `forkSession()` 则深拷贝整个 Session、重发所有消息 id。二者都是会话级派生，但 Hermes 需要保持跨轮转 lineage，NextChat 只是本地独立副本。
9. **服务端回溯重建（Open WebUI）**：消息本身由 `parentId`/`childrenIds` 构成树；`POST /{id}/fork` 用 `build_fork_history` 从目标节点沿父链重建一个新 Chat。多模型的 `modelIdx` 并列列序与 fork 是另一套正交关系。
10. **指针分支（Pi）**：`branch()` 只移动会话的 `leafId` 指针，下次追加即成为新分支；`createBranchedSession` 把“根到指定叶子”的路径抽成新 JSONL 文件并重链 label；`branchWithSummary` 追加 `branch_summary` 摘要条目参与上下文。历史不修改、无草稿态覆盖层，语义接近 Cherry Studio 的指针跳转但实现是 JSONL 追加树。
11. **删除式回退 + 复制式 fork（OpenCode）**：`revert` 记录回退点（含 git snapshot）并回滚文件，再次 prompt 前**删除目标之后的所有消息**——改的是原消息树而非新建节点；真正的分支是 `POST /session/:id/fork`（session.ts:693-734），新建会话并复制截至某消息的全部消息/parts（parentID 重映射）。多模型/多候选不产生消息级兄弟节点，也没有草稿态覆盖层。

AstrBot 的多个 conversation 是同一 UMO 下可切换的独立对话，不是消息分支；Manifold Desktop 未形成可持久化的正常会话主链，本次也没有可比较的分支机制。

## 流式生成：渲染状态如何进入持久化层

各项目都要处理“UI 立刻刷新”和“完成态落盘”的时序，但并非都实现了两层缓冲；新增项目从数据库 block、WebSocket delta 到纯 DOM 更新覆盖了更多形态：

- **AIO Hub**：渲染走独立的 `ReplayableMessageStreamSource`（RAF 节流、可重放缓冲），持久化走另一套 `setTimeout` 节流（默认 2 秒或用户配置的增量保存间隔）。reasoning 内容直接 flush 到 `metadata.reasoningContent`，持久化频率高于正文。应用崩溃后，已落盘的“生成中”节点没有加载时自愈机制，只有同一会话再次触发生成、使 `generatingNodes.size` 先增后减时才会触发修复 watch。
- **Chatbox**：`updateStreamingCache`（只写 react-query 缓存）与 `persistStreamingMessage`（写 IndexedDB）分开；`shouldPersistStreamingChunk` 规定 tool-call 立即落盘，其余按 2000ms 定时。代码注释给出的原因是 tool-call 可能长时间等待审批，延迟落盘会在刷新时丢失待批准状态。落盘时用 `mergeCachedGeneratingMessages` 防止旧快照覆盖生成中的消息。
- **Cherry Studio**：数据流分为三层：DB 历史（SWR 缓存）、`useExecutionOverlay` 中尚未落库的流式增量，以及 `useStableMessagePartsLayers` 合并前两者后得到的 `historyPartsByMessageId`/`partsByMessageId`。渲染时再按 `firstLiveGroupIndex` 把同批消息分成已封存历史和 live 两段，分别使用不同的 memo 策略。
- **LobeHub**：全局 ChatStore 与会话级 ConversationStore 各自调用同一个 `parse()` 算法，分别维护 `displayMessages`。这套设计需要 `stabilizeReferences` 维护渲染引用稳定性；该补丁只用于局部 store，全局 store 没有对应处理，形成笔记所述的不一致。
- **SillyTavern**：没有独立的流式缓冲层，`StreamingProcessor` 直接修改 `chat[messageId].mes` 和 DOM `innerHTML`，渲染状态与持久化数组耦合较紧。DOM 引用经 `#checkDomElements()` 懒加载缓存后，如果流式期间执行 `redisplayChat` 整段重绘，旧引用会指向已脱离文档树的节点；后续写入不报错，也不会显示。笔记确认了这条代码路径，尚未做运行时复现。
- **VCPChat**：`streamManager.finalizeStreamedMessage` 统一收尾，1 秒防抖存盘；群聊消息因 `saveHistoryForContext` 对 `isGroupMessage` 直接 return，不走这条路径，由 `groupchat.js` 单独写盘。是否落盘由消息类型决定，而不是由节流参数决定。
- **AstrBot**：LLM 阶段以 `AsyncGenerator` 挂起流水线，让 Respond 阶段先发送结果，再回到生成器执行历史保存等收尾；顺序性来自 UMO 锁与 follow-up 队列，不是浏览器 UI 缓存。
- **DeepChat**：assistant 先以 `pending` 行和 block 占位；流式中间态替换 block 并经 IPC 增量投影到 renderer，完成/错误后再同步正文、状态、搜索文档和 Tape facts。稳定 render key 让同一消息从流态过渡到落盘态时复用显示对象。
- **Hermes Agent**：后端把 delta 经 WebSocket 推给桌面，renderer 以约 33ms 队列合并；终态 `message.complete` 再触发版本仲裁和会话刷新，后端按一轮批量事务写 SQLite/JSONL。
- **Jan**：AI SDK `experimental_throttle: 50` 只节流 UI，`useMessages` 另做乐观写与异步持久化；`resume:false` 明确不恢复未完成流。
- **NextChat**：assistant 占位从一开始就在 Zustand session 内，SSE `onUpdate` 原地改 content，`onFinish` 清掉 `streaming`。状态存储和 UI 共用同一对象，没有独立 transcript 层。
- **Open WebUI**：Provider 流先在后端按 chunk 数量聚合，再通过 Socket.IO 发约定事件；`update_db=True` 的 emitter 可按事件类型追加或覆盖消息行，前端按 `delta/output/done` 更新 history 投影。
- **Manifold Desktop**：chunk 只更新 DOM 与 `streamingText`，连前端 `messages[]` 都不回写。这不是“渲染与持久化解耦”，而是完成态尚未回到会话状态的断链。
- **Pi**：流式状态与持久化同源——`message_update` 携带完整 partial 消息驱动 TUI 重建，`message_end` 才落盘；无独立的流式缓冲层。TUI 以 `requestRender` 帧节流合并刷新；abort/error 以 stopReason 持久化，下次恢复可见。
- **OpenCode**：分三层频率——reasoning/text 的 delta 经 `updatePartDelta` 发 `message.part.delta` 增量事件（processor.ts:499-510），`text-end` 才完整落库（:512-532），tool part 状态迁移即时落库；App 端 `part_text_accum_delta` 累积增量、`message.part.updated` 完整替换（server-session.ts:1095-1231），SSE 16ms 批量 flush + delta 拼接。即 UI 更新频率 > 事件频率 > 落库频率，三层明确分离。

## 搜索：索引、命中粒度和跳转能力仍是三件事

新增项目出现了 SQLite FTS、消息搜索文档和 Fzf 懒索引。比较搜索能力时，还要区分索引对象、结果粒度和 UI 跳转：

- **AIO Hub**：跨会话搜索由 Rust 全量遍历文件系统并用正则预过滤，没有持久化索引，只能定位到会话。会话内搜索是独立的前端线性扫描，仅覆盖当前活动路径，无法命中隐藏分支。两套搜索没有衔接，跨会话结果不能直接跳到具体消息。
- **Cherry Studio**：搜索使用 `document.createTreeWalker` 遍历已渲染的 DOM 文本节点，没有查询消息数据模型。消息列表由 `virtua` 虚拟化，窗口外消息未挂载到 DOM，因此不会进入搜索范围。这是 DOM 搜索与虚拟列表组合后的范围限制。
- **VCPChat**：`searchTopicsByContent` 只对字符串类型的 `message.content` 做 `includes` 匹配，多模态数组（`[{type:'text',...}]`）会被跳过，形成明确的搜索盲区。
- **Chatbox**：有独立的 `SearchDialog`，支持“当前会话”和“全部会话”两种范围；`sessionHelpers.searchSessions` 分页读取 IndexedDB 中的完整 Session，扫描当前消息与历史 Thread，返回命中的具体消息，点击结果后调用 `scrollToMessage` 定位。实现采用数据层分页全量扫描，没有使用 DOM 搜索或持久化倒排索引（`SearchDialog.tsx:50-65,168-203`、`sessionHelpers.ts:877-929`）。
- **LobeHub**：侧栏的 `TopicSearchBar`/`AllTopicsDrawer` 已有全量 Topic 搜索；服务端 `TopicModel.queryByKeyword` 用 BM25 同时匹配 Topic 标题和消息内容，但返回的是 Topic 列表，不直接定位到具体消息。另有 `message.searchMessages` 后端查询端点，但本次未找到聊天 UI 对该端点的调用，因此不能把它等同于用户可见的消息定位搜索。
- **SillyTavern**：本次仍未找到聊天内容检索 UI；现有 `search` 相关代码集中在端点/扩展和 slash command 语义，不应据此断言完全不存在其它未覆盖入口。
- **DeepChat**：完成/错误结算会同步更新搜索文档，transcript 因而具备消息级检索材料；本次笔记没有继续核对 Chat UI 的搜索入口和命中后定位行为。
- **Hermes Agent**：SQLite `state.db` 带会话搜索 mixin/FTS，会话列表与搜索在 SQL 中完成，前端只取必要字段；笔记确认了后端索引路径，但未把桌面命中跳转逐项展开。
- **Jan**：`useThreads` 用 Fzf 懒建索引，SearchDialog 展示并导航 Thread；这是会话列表搜索，不是消息正文命中后定位。
- **Manifold Desktop**：逐个读取 session JSON，对整份 dump 做不区分大小写子串匹配，无索引和结果上限；而正常聊天未保存，搜索 API 也可能搜不到刚聊过的内容。
- **Open WebUI**：后端 `/search` 支持文本和 `tag:` 查询，结果粒度是 Chat；消息行虽独立存储，本次笔记未确认用户可见的“命中具体消息并跳转”链路。
- **NextChat / AstrBot**：本次单项目笔记没有把聊天内容搜索作为完整链路展开；不能据会话列表或管理页入口推断存在消息级检索。
- **Pi**：会话列表按 cwd 扫描 JSONL（并发上限 10），搜索是选择器内的 `id+名称+全部消息文本+cwd` token/正则匹配（`session-selector-search.ts`），结果是会话级命中；无消息级持久化索引。
- **OpenCode**：仅会话标题 `LIKE` 搜索（session.ts:993-995，`session.list({search})`），结果定位到会话；**消息内容全文搜索本次未找到实现**。消息分页用游标（`MessageV2.page`，base64url {id,time}），App timeline 向上加载。

结论：Chatbox 已确认能从 Session 数据命中并定位具体消息；LobeHub、Hermes Agent、DeepChat 具有数据库或搜索文档基础，但用户可见定位链路的证据不齐；Jan、Open WebUI、AIO Hub、Manifold Desktop 主要返回会话级结果；Cherry Studio 与 VCPChat 分别受虚拟 DOM 和多模态内容形态限制。现有笔记仍未确认任何项目完整满足“持久化消息索引 + 跨分支/跨会话命中 + 直接定位具体消息”三个条件。

## UI 交互与呈现：同样的数据结构，用户看到的是不同工作流

补充阅读各项目的页面、输入区、消息组件和侧栏代码后，UI 差异可以按“消息如何被看见、如何被操作、如何导航”来对照：

| 项目 | 主界面/导航 | 消息呈现 | 输入与生成中交互 | 关键 UI 取舍 |
| --- | --- | --- | --- | --- |
| AIO Hub | 三栏工作台：Agent/参数、ChatArea、Session；支持 ChatArea/输入框分离成悬浮窗 | 活动路径线性列表 + 可切换 Vue Flow 树图；rich-text-renderer 拆出 reasoning、附件、压缩节点 | CodeMirror/textarea、拖入/粘贴附件、工具审批条；发送按钮可 abort | 当前消息列表是完整 DOM + `content-visibility`，依赖活动路径；历史上曾用 TanStack Virtual，后因动态高度、倒序加载闪烁和滚动定位问题于 2026-04-29 撤回 |
| AstrBot | WebChat 与会话管理页服务于多 IM 平台后台 | ChatPage 展示选定 conversation，另有 Trace 页面展示流水线阶段 | 输入可触发命令建议与 Live Mode；真实入站还来自 QQ/Telegram 等平台 | Web UI 只是多平台事件系统的一个入口，不能代表群聊唤醒和平台回复的全部行为 |
| Chatbox | Header + Virtuoso 消息区 + 底部 InputBox；ThreadHistoryDrawer 侧滑 | 最新一轮 user/assistant 分组，ThreadLabel、ForkNav、Summary/ForkMarker 专用块，桌面 minimap | composer 承接模型/Copilot/知识库/网页浏览；停止直接 cancel 当前 generating 消息 | 虚拟列表和 smooth-follow 体验成熟；独立 SearchDialog 走 Session 数据扫描，不受 DOM 虚拟窗口限制 |
| Cherry Studio | Home/Agent 共用 `MessageListProvider` 契约，Topic 侧栏与消息流分离 | Virtua 分组列表；DB 历史与 live execution overlay 分层，工具/任务/reasoning 为显式组件 | 多模型选择可以并行生成 N 个 assistant；工具审批/异构干预走专用操作条 | 适配器复用能力强，但全局/局部 store 双 parse 让状态同步复杂 |
| DeepChat | renderer 通过 ChatPage 组合消息、pending input lane 与工具交互浮层 | 测量高度 + spacer + anchor + 二分窗口化，流式行保持可见 | steer、queue、question/permission 是独立输入通道；subagent session 只读 | 主进程是真相源，UI 通过 typed IPC 和 revision/cursor 维护投影 |
| Hermes Agent | Electron 桌面通过 WebSocket 连接无头 Python 后端 | 本地原子缓存合并历史与 delta，工具事件作为 child messages | prompt RPC、硬中断和纯前端停止显示具有不同语义 | lineage/runtime id 的翻译直接影响固定、恢复和流式状态 |
| Jan | Thread 页面集中承载列表、输入、队列、分支与错误 banner | 活动 parent 路径 + `< n/m >` 版本导航，失败 assistant 可隐藏 | 流式中再次发送进入 `QueuedMessageChip`；编辑/删除在流式态禁用 | UI 同时仲裁 AI SDK 状态与文件/SQLite 消息，页面中枢职责较重 |
| LobeHub | Agent Sidebar + Topic 多种分组/全量抽屉；输入编辑器是 Lexical 插件工作台 | Virtua flat list + keepMounted；AssistantGroup 折叠工具流程，ChatMiniMap 快速跳转 | slash/mention/文件/草稿/输入历史；发送按钮按权限和 generating 切换 | 权限、运行态、工具流程都在 UI 直接可见；Topic 双击开 tab 与单击导航有定时器语义 |
| Manifold Desktop | WebView2 标签页聊天界面 | assistant chunk 直接改 DOM，每 chunk 强制滚到底部 | 新请求先停止全局旧线程；取消只能在下一次流回调检查 stop token | 多标签共享无会话 id 的广播，正常聊天状态与文件存储未接通 |
| NextChat | 单页 Chat + 会话列表 | 轻量窗口分页：默认末尾 15 条，单次最多 45 条；工具状态挂在 assistant 下 | stop/retry/delete/pin/copy/TTS；图片和音频直接作为消息内容 | 不是虚拟列表；完整历史仍驻留 session 数组，窗口只限制渲染切片 |
| Open WebUI | Svelte Chat 控制器 + 消息、输入、分享/标签组件 | 单模型、side-by-side 多列、MoA 合并和结构化输出都有专用投影 | 支持队列、停止、重新生成、继续生成、工具确认和终端事件 | `Chat.svelte` 集中处理约 25 类 Socket.IO 事件，交互完整但状态组合复杂 |
| SillyTavern | Agent/群组/Topic 侧栏 + 中央消息 DOM + 通知/设置面板 | 整段 DOM 重绘与追加，swipe picker、checkpoint/branch、正则和大量扩展挂钩 | 发送按钮复用为中止；群聊邀请/多模式调度改变消息流 | 扩展性和可定制性最高，但长聊天没有虚拟化，重绘与旧 DOM 引用风险更明显 |
| VCPChat | 三 tab 左侧栏 + 中央聊天 + 通知侧栏，可调宽度 | 同一历史支持气泡/统一面板/刊物三种 CSS 投影；工具、思考链、日记是可折叠 bubble block | textarea + 附件预览；发送/中止同一按钮；Topic 列表渐进渲染、IntersectionObserver 计数 | 视觉模式切换成本低，但消息区仍是整段 DOM；单聊/群聊中断能力不对称 |
| VCPToolBox | 不提供聊天主界面；AdminPanel 是运维 SPA，OpenWebUISub 是第三方页面增强脚本 | 只在 OpenWebUI DOM 中把纯文本协议标记替换成工具卡片 | 不承接会话输入/停止/导航 | 不能与其它聊天应用按 UI 直接排名，属于后端协议与外部前端适配层 |
| OpenCode | 会话列表 + 虚拟化 timeline（Web）；TUI 全屏会话页 | 消息 part 驱动：text/tool/reasoning/compaction 组件 + 工具 15 个注册渲染器；context 组折叠连续 read/glob/grep/list；thinking 行与重试倒计时卡 | Web 发送/中断/排队/followup dock；TUI 发送、双击 Esc 中断、shell 模式、`@` agent 提及 | 渲染核心独立成 `packages/session-ui` 包被 Web 复用；Web 与 TUI 是两套独立渲染栈，共享服务端事件协议 |

### 跨项目结论

1. **“消息渲染”至少有四层含义**：AIO 当前把消息树编译成活动路径并完整挂载 DOM，再用 `content-visibility` 裁剪屏外渲染；它在 2025-11-02 至 2026-04-29 曾使用 TanStack Virtual，后因聊天场景的动态高度和滚动稳定性问题撤回。Chatbox/Cherry/Lobe/Jan 也把消息模型先编译成活动路径或 flat list；DeepChat 做测量驱动的窗口化，NextChat 只做固定页窗；SillyTavern/VCPChat/Manifold 主要增量或整段修改 DOM；VCPToolBox 只改第三方 DOM，不拥有消息列表。
2. **停止生成的视觉状态与执行状态可能不同**：VCPChat 单聊只通知远端，Hermes Agent 可以只在前端把流标为完成，Manifold 的 stop token 不能打断阻塞读取；Open WebUI 将停止建模为可跨实例路由的任务取消。评估停止能力时，需要继续追到请求或任务控制层。
3. **输入区承载了大量 Agent 交互**：DeepChat 的 steer/queue/permission、Jan 的排队与附件、Open WebUI 的工具确认和终端事件，与 AIO/Chatbox/Cherry/Lobe/VCPChat 的附件、知识库、mention、审批共同组成了输入协议。
4. **窗口化与搜索存在结构性冲突**：Chatbox/Cherry/LobeHub/DeepChat 通过虚拟或窗口列表控制长会话成本，但 Cherry 的 DOM 搜索以及任何依赖已挂载节点的扩展会漏掉窗口外消息；NextChat 的固定页窗也需要显式移动窗口。AIO 曾经也有这一类窗口化方案，但在消息高度动态、倒序加载和滚动定位稳定性上付出的复杂度过高，后来改为完整 DOM + `content-visibility`，以保留真实 DOM 定位能力并把成本转给浏览器的屏外渲染裁剪。SillyTavern/VCPChat 没有这个漏搜原因，却把成本转移到整段 DOM。
5. **UI 调查应记录“呈现投影”**：AIO 的 linear/force-graph、VCPChat 的 bubble/panel/immersive、Open WebUI 的 side-by-side/MoA、Chatbox 和 Jan 的分支版本导航，都说明同一份会话数据可以有多种用户可见投影；仅记录 `Session/Topic/Thread` schema 无法解释用户实际如何切换、编辑、停止和定位。

## 中断/取消生成：按钮停止、任务取消和请求中止不是同一层

| 项目 | 已核实的中断层 | 关键边界 |
| --- | --- | --- |
| AstrBot | `stop_event` 可截断事件传播；`agent_stop_requested` 只请求 Agent 停止 | 软停仍允许历史保存等后续阶段执行，语义刻意分离 |
| DeepChat | Session runtime 管理 working turn、steer/queue 与错误结算 | IPC 顺序、网络中断和快速切 session 尚未动态验证 |
| Hermes Agent | 后端轮询 `interrupt_requested`；桌面另有 hard interrupt | `interruptResponse` 只是前端把已有内容标为完成并清 busy，不等于后端请求已停 |
| Jan | AI SDK/transport 控制当前生成，流式态禁止编辑删除 | `resume:false`，中断后的未完成回合不恢复；具体底层网络 abort 未在笔记中等深展开 |
| Manifold Desktop | C++ `stop_token`，新请求先停止旧 `m_chatThread` | 只能在下一次 stream callback 生效，不能主动打断已阻塞的 `WinHttpReadData` |
| NextChat | `ChatControllerPool.stop` 调当前 controller | controller 的 Provider 级取消效果取决于 adapter；笔记未逐 Provider 验证 |
| Open WebUI | 前端按 chat/task 停止；本地 `task.cancel()`，Redis 模式广播 stop | Redis 只负责把取消命令路由到实际持有任务的实例，任务本身不迁移 |
| VCPChat | 群聊有本地 `AbortController`；单聊只通知远端 `/v1/interrupt` | 单聊本地读取循环不受控且无客户端超时；未被引用的 `vcpClient.js` 才包含本地 abort 与 300 秒超时 |
| Pi | `AgentSession.abort()` 中止 agent 运行、工具与重试退避 | 中断后 assistant 消息以 `stopReason: "aborted"` 持久化；切换/退出会话前先 abort 落盘再替换 runtime |
| OpenCode | `POST /session/:id/abort` → `SessionRunState.cancel` → 中断 Runner fiber（run-state.ts:77-86） | `Effect.onInterrupt` 走 `halt(AbortError)`，`cleanup` 把未完成 tool part 标 `"Tool execution aborted"` + `interrupted:true`；重试为进程内 `Effect.retry`（5xx/429，指数退避 2s 起），前端无独立手动重试端点 |

VCPChat 仍是“同一产品两条路径不对称”证据最完整的案例。新增笔记还显示：Hermes Agent 的前端完成化、Manifold Desktop 的回调式 stop token、Open WebUI 的跨实例任务取消分别处在不同层级。其余项目缺少同等深度证据，只能标为未验证，不能从按钮存在推断请求已被中止。

## 各项目自己承认或暴露出的技术债(有具体代码证据支撑的)

- **AIO Hub**：崩溃后残留的“生成中”节点没有加载时自愈，只能通过再次触发生成间接修复；跨会话搜索无索引，延迟会随数据量线性增长（静态推断，未实测）。
- **Chatbox**：`throttleWriteSessionAtom.ts` 的 `createSessionAtom`/`WriteQueue` 与实际生效实现使用相同的 2000ms 参数，却从未被调用，属于疑似死代码；`newSessionState.webBrowsing` 字段已有声明但未找到写入点；IndexedDB 有意不做 version 升级，代码注释所述的“重试兜底”也未找到实现。
- **Cherry Studio**：删除 Topic 不清理磁盘文件，代码中已有 TODO（`TopicService.ts:316`）；`docs/references/chat/message-tree.md` 仍把 Flow canvas 写成 forward reference，但分支流程图代码已经存在，文档未同步更新。
- **LobeHub**：`doctor/diagnose.ts` 用于检测和修复读取器无法完整渲染的消息树；`reconcileAssistantToolLinks` 用于修复乐观更新在 step 边界丢失工具引用的问题。这两项都来自现有修复代码，不是理论推测。
- **AstrBot**：事件队列没有全局并发上限；会话切换/新建的 SharedPreferences 有 60 秒防抖，进程崩溃可能丢失这段时间内的选择状态；follow-up 与流式并行的完整时序未实测。
- **DeepChat**：SQLite 加密配置、事务隔离、崩溃恢复和 IPC revision/cursor 在网络中断、快速切换会话时的行为未运行验证；搜索文档、Tape 和 transcript 的完整迁移链也未全部追踪。
- **Hermes Agent**：session id、lineage root 和 runtime id 的边界是持续 bug 来源；桌面侧“停止显示”和后端 `interrupt_requested` 不是同一动作，CLI/gateway 以外的运行行为未实测。
- **Jan**：桌面 `messages.jsonl` 每次整文件重写，长会话每轮 I/O 随消息数增长；`resume:false` 不恢复未完成回合；编辑消息会丢失媒体 content，分支树迁移完整性未验证。
- **Manifold Desktop**：正常聊天没有调用 `SAVE_SESSION`，assistant 不回写 `messages[]`；`CHAT_CHUNK`/`CHAT_DONE` 无会话标识导致多标签广播串扰，重命名整文件覆盖会清空既有消息。
- **NextChat**：默认把聊天全文、Mask、API key 和配置留在浏览器存储且无通用加密；摘要没有质量校验；WebDAV 合并时间戳实现可疑但未执行多设备复现。
- **Open WebUI**：history JSON 与 `chat_message` 双写依赖 reconcile；多模型、工具、Socket.IO 事件和后台标题/标签/追问任务共享同一大状态机；跨实例取消依赖 Redis pubsub，未迁移任务队列。
- **SillyTavern**：`chat_metadata.integrity` 用于检测多标签页并发写覆盖；`swipe()` 失败时会自动恢复，恢复失败后强制整页重载。两处机制都表明实现需要处理外部扩展或并发写造成的状态损坏。
- **VCPChat**：单聊中断能力不完整（见上节）；群聊历史写盘没有文件锁，存在并发覆盖丢消息的可能，尚未构造场景验证；未读自动判定要求整个历史仅有一条非系统 assistant 消息，因此多轮对话不会触发。
- **Pi**：流式 `message_update` 每 delta 全量重建组件，聊天列表无虚拟化，长会话渲染成本线性增长；JSONL 追加型文件随会话持续增长，恢复时全量读入；上下文 token 估算为启发式，与 Provider 计费可能不一致。
- **OpenCode**：无消息内容全文索引（仅标题搜索）；`message.part.delta` 的累计通道 `part_text_accum_delta` 与 `produce` 就地追加在断线重连/事件乱序下的正确性未实测；V1/V2 双轨会话体系并存（Legacy 主路径 + 事件溯源 V2 部分实现），客户端需按协议协商切换。

## VCPToolBox：不参与会话/UI 对比，但参与消息构建

VCPToolBox 不提供最终用户聊天主界面，但仍负责消息构建。它把调用方提交的历史归一化为 OpenAI `messages`，在首次请求前完成裁剪、注入和预处理；模型输出 VCP 工具标记后，再把 assistant 正文和工具结果 user payload 追加到内存上下文并递归请求。`FinalContextViewer` 只捕获首次上游 fetch 前的最近 5 份内存快照，不包含后续工具递归消息，也不是会话数据库。

AdminPanel-Vue 是独立进程（监听 `PORT+1`），与聊天主链物理解耦；OpenWebUISub 是运行在第三方聊天页面里的浏览器脚本，靠 `MutationObserver` 扫描 AI 回复文本里的协议标记字符串渲染成卡片。给模型的工具结果使用 `<!-- VCP_TOOL_PAYLOAD -->` user 消息，给前端的可见结果由 `vcpInfoHandler.js` 另行写入 SSE/最终 JSON，两者不能混为同一份消息。完整证据链见 `VCPToolBox-Chat调查笔记.md` 的“消息构建调查”。

## 选择提示（基于已核实机制）

| 侧重点 | 项目 | 已确认的边界 |
| --- | --- | --- |
| 数据库级消息树与事务约束 | Cherry Studio | SQLite 有外键和 CHECK 约束；三层数据管道增加调试复杂度 |
| 跨 IM 平台事件流水线、群聊唤醒与 follow-up | AstrBot | 核心单位是 UMO 和异步事件，WebChat 只是一种入口 |
| 主进程权威 transcript、Agent 输入队列与工具交互 | DeepChat | main/renderer 之间仍有 IPC revision、cursor 和事件顺序边界 |
| CLI/TUI/桌面共用 Agent 后端、跨压缩 lineage | Hermes Agent | session、lineage、runtime id 必须严格区分 |
| 本地模型、AI SDK 流式 UI 与消息版本树 | Jan | 桌面端每轮整写 JSONL，未完成回合不恢复 |
| 应用层树与分支记忆 | AIO Hub | 搜索无索引，崩溃后生成状态不自愈 |
| 简单会话记录、归档优先于删除 | Chatbox | 恢复归档不会重排，拖拽排序仅限同分组 |
| Agent 工具过程的可观察流程 | LobeHub | 双层 store 各自 parse；审批逻辑位于全局 store |
| 纯客户端部署，集中保存 Mask、摘要和工具状态 | NextChat | IndexedDB/localStorage 是主存储，本地数据与同步边界需单独评估 |
| 服务端权限、分享、多模型与跨实例任务控制 | Open WebUI | history/消息表双写，Socket.IO 事件状态组合较多 |
| 文件级分支、检查点与社区扩展 | SillyTavern | 长聊天不虚拟化；正则按展示、prompt、存储位置分层，渲染结果可能随聊天长度变化 |
| 多角色群聊与长期 Topic 关系 | VCPChat | 单聊没有本地 abort，可靠中止依赖远端 |
| 终端本地编码 Agent、追加型树会话与工具循环 | Pi | 单会话单循环；消息编辑以分支表达；无消息级搜索索引；系统提示不随会话保存 |
| 服务端 Agent 会话运行时、事件广播与多前端共用 | OpenCode | SQLite 权威 + SSE 投影；删除式 revert 与复制式 fork；无消息级全文搜索；Web/TUI 两套渲染栈 |

Manifold Desktop 当前更适合作为“聊天主链尚未接通持久化时会出现哪些断层”的对照样本，不宜仅凭已存在的 SessionManager API 判断会话能力已经完成。

以上内容只描述已核实的产品与源码机制，不构成性能、安全或 Agent 能力排名。分支、流式和搜索的详细证据见本目录下对应的单项目笔记；工具调用权限与 Agent 配置见 `项目调查笔记/Agent工具`；消息渲染层的公共问题见 `项目调查笔记/消息渲染器`。

## UI 细节深挖补录（2026-08-05 增补）

> 本节依据各项目笔记第 13 节的源码核实结果，做跨项目横向对照。覆盖范围：弹窗底层、通知/Toast、主题切换、无障碍、图片预览、动画方案，以及各项目的特殊实现差异。VCPToolBox 不提供聊天主界面，不参与本节对比。

### 弹窗/对话框：六种互不相同的底层技术栈

六个项目的弹窗没有两个是一样的：

| 项目 | 弹窗底层 | Esc/遮罩关闭 | 焦点管理 |
| --- | --- | --- | --- |
| AIO Hub | 自研 `BaseDialog.vue`（非 Element Plus），自增 z-index，300ms 入退场动画 | 支持（由 `showCloseButton`/`closeOnBackdropClick` prop 控制） | 基本缺失；唯一例外：`RenameDialog` 输入框有 `autofocus` |
| Chatbox | 三套并存：Mantine `Modal`（主力）+ `vaul`（移动端底部弹起）+ Radix `Dialog`（预留）；`@ebay/nice-modal-react` 统一管命令式调用 | 逐弹窗配置：登录/许可证类三项全禁；`trapFocus={false}` 在四个弹窗里有意关闭（iOS Safari 文本选中 workaround） | `trapFocus={false}` 的四个弹窗键盘 Tab 可穿透到背景——有代码提交记录的已知取舍 |
| Cherry Studio | 自建 `@cherrystudio/ui` 包裹 Radix `Dialog`；`services/popup` 用 `useSyncExternalStore` 做 store | 支持；两阶段关闭，延迟 200ms 播放退场动画 | Radix `DialogContent` 默认交给 `FocusScope` 管理焦点；业务侧可用 `focusOnClose` 指定关闭后的焦点落点 |
| LobeHub | `@lobehub/ui` 的命令式 `createModal`/`confirmModal`（主流）+ `ImperativeModal` 兼容层（迁移期遗留） | 高危操作（如清空工作区）把 `maskClosable` 设为 `false` 并要求勾选确认框；其余遮罩点击可关闭 | 业务调用方未发现统一的显式配置；`@lobehub/ui/base-ui` 内部是否有 focus trap 未下钻，结论应保留为未核实 |
| SillyTavern | 原生 `<dialog>` + 自研 `Popup` 类（非 jQuery UI Dialog）；阻塞性弹窗需**双击 Esc** 强制关闭（注释自曝为"踩坑后留下的防御代码"） | **点遮罩不会关闭**（与大多数现代弹窗库相反） | 无 |
| VCPChat | 全部自定义 DOM；通用 Modal 用 `<template>` 懒加载 + `modal-ready` 事件通知 | 确认对话框支持 Esc/Enter/遮罩点击；无 focus trap，Tab 可穿透背景 | 无 focus trap |

**跨项目结论**：SillyTavern 的遮罩点击不会关闭弹窗；Chatbox 有可追溯的提交记录说明关闭 focus trap 的原因。焦点管理覆盖不一：Cherry 的 Radix 基础层提供 `FocusScope`，其余项目在自动聚焦、关闭后的焦点落点和业务控件语义上各有缺口；LobeHub 的 `@lobehub/ui` 包内部实现尚未核实。

### 通知/Toast：每个项目各自为战

| 项目 | 实现 | 位置 | 特殊行为 |
| --- | --- | --- | --- |
| AIO Hub | 三层：`customMessage`（ElMessage 包装，offset 54px 避开无边框标题栏）→ `errorHandler` 四级分发（CRITICAL 走常驻 `ElNotification`，duration:0）→ 独立 `NotificationCenter`（持久化） | 顶部 | CRITICAL 级常驻不消失 |
| Chatbox | 两套分工：MUI `Snackbar`（聊天主流程，右上角，3s）+ `sonner`（Settings 弹窗内部，底部居中，`z-index: 2147483647`）；错误 toast 先出原文再追加异步翻译 | 右上角 / 底部居中 | 多条 MUI toast 会互相重叠（未处理堆叠位移） |
| Cherry Studio | 自研 store（非 antd/sonner），`role="alert"`/`role="status"` 区分严重程度，error 默认不消失 | 顶部居中 | 默认 3s，error 永不自动消失 |
| LobeHub | antd `App.useApp()` 单例（`AntdStaticMethods`），桌面端整体下移避开 Electron 标题栏；另有独立自绘悬浮通知卡片组件（`components/Notification`） | 顶部（偏移）+ 悬浮卡片 | 两套并存：antd 管临时提示，自绘卡片管持久通知 |
| SillyTavern | `toastr` 库（88 处调用分散在 86 个文件，无统一封装层）；`fixToastrForDialogs()` 专门处理弹窗打开时 toast 被遮罩挡住的问题；`escapeHtml:true` 防 XSS | 右上角 | 有独立的 `action-loader.js` 子系统管"阻塞遮罩单例 + 可堆叠 toast"，toast 可带停止按钮直调 `stopGeneration()` |
| VCPChat | 自定义，默认 7 秒消失，`tool_approval_request` 永不消失；通知侧栏打开时抑制浮动 Toast；窗口获焦时自动清理超时残留 toast；新 toast 插入顶部（prepend）而非追加尾部 | 左上角 prepend | **不发任何系统桌面 `Notification`** |

**跨项目结论**：多条 toast 并存时，Chatbox 的 MUI Snackbar 会重叠，SillyTavern 的 toastr 又分散在 86 个文件中，没有统一封装。Chatbox Settings 使用的 sonner 和 VCPChat 的 prepend 方案提供了明确的堆叠位置管理。

### 主题切换：热切换与整窗口重载

| 项目 | 切换机制 | 跟随系统 | 持久化位置 |
| --- | --- | --- | --- |
| AIO Hub | CSS 变量/class 切换 | `matchMedia('(prefers-color-scheme: dark)')` 注册 `change` 监听；仅 `auto` 模式响应 | `settings.json`（非 localStorage） |
| Chatbox | MUI 主题 + Tailwind `dark` class + Mantine `colorScheme` **三套各管一段**，`realTheme` 单一状态源统一驱动 | ✓（桌面端 `nativeTheme.on('updated')`，Web 端 `matchMedia` listener） | `localStorage['initial-theme']`（供首屏同步读取防闪烁） |
| Cherry Studio | Electron 主进程 `nativeTheme.themeSource` 为权威，IPC 广播同步渲染层；CSS 变量遵循 Shadcn 契约（无前缀），自定义主色直写行内 style | ✓（`nativeTheme` 原生支持） | Electron 主进程 store |
| LobeHub | `next-themes` 管 light/dark/system 解析和 `data-theme` 属性；`@lobehub/ui` 的 `ThemeProvider` 套色板 token——**两层分离，各自独立持久化** | ✓（`next-themes` 原生支持） | `next-themes` 的 localStorage（明暗）+ 用户 store + cookie 镜像（强调色/中性色） |
| SillyTavern | CSS 变量运行时改写 + 服务端存储；导入主题时若含 `@import` 专门弹出安全警告 | **✗（全仓库无 `prefers-color-scheme`）** | 服务端（非 localStorage） |
| VCPChat | **整份覆写 `themes.css` 文件，然后调用 `mainWindow.reload()` 整窗口重载** | Electron `nativeTheme.on('updated')` 监听并广播 `theme-updated` IPC；系统变化时不必用户手动切换 | `settings.json` 的 `currentThemeMode` + 本地 `themes.css` |

**跨项目结论**：VCPChat 切换主题时会 reload 整个窗口，可能出现白屏；SillyTavern 未跟随系统深色模式。Chatbox 同时维护三套主题机制，深色背景 `#242424` 在 MUI 和 Tailwind 两处分别硬编码，修改时需要同步两处。

### 无障碍（accessibility）：普遍薄弱，各有具体缺口

没有一个项目做到体系化的无障碍支持，但缺口的性质不同：

- **AIO Hub**：全目录 ARIA 属性命中极少；发送/停止按钮只有 `title` 没有 `aria-label`；会话列表项没有 `tabindex`，**纯键盘用户无法切换会话**；树图右键菜单没有键盘操作/Esc 关闭。唯一例外：`BatchManagerDialog` 有语义化角色标注。
- **Chatbox**：发送/停止按钮完全没有 `aria-label`（最高频交互点反而是缺失的）；`trapFocus={false}` 的四个弹窗键盘 Tab 可穿透背景（已知取舍）；做得较好的反例：消息跳转导航 `MessageMinimapRail` 用真实 `<button>` + `aria-label="Jump to message N"` + `aria-hidden` 正确隔离装饰元素。
- **Cherry Studio**：消息操作栏（复制/编辑/删除/点赞）无 `aria-label`，可访问名称只靠鼠标 Tooltip；composer 可编辑区无 `aria-label`/`role="textbox"`；Topic/Session 列表实现了规范的 roving tabindex + `aria-activedescendant`，优于一般水平。
- **LobeHub**：有多处规范实现（`role="progressbar"`、`aria-live="polite"` 等）；但 Topic 行、消息操作栏图标按钮普遍缺 `aria-label`；结论是"点状覆盖，非体系化"。
- **SillyTavern**：`index.html` 全文仅 1 处 `aria-hidden`；245 个"按钮"全是 `<div class="menu_button">`；为此专门写了 `keyboard.js`（MutationObserver + 动态 tabindex + Enter 触发）做键盘可达性补偿，但屏幕阅读器语义几乎空白——**无障碍最薄弱**。
- **VCPChat**：Presentation mode 切换、侧栏 tab、compact navigation 等有基础 ARIA；但 Agent/Topic/消息列表项均无 `aria-label`/`role`，无 focus trap。

**共同结论**：六个项目的无障碍语义都不完整。SillyTavern 大量使用 `<div>` 代替 `<button>`；Chatbox 的发送按钮缺少 `aria-label`，但 `ModelRow.tsx` 等其它图标按钮已有相应标注，覆盖标准并不一致。

### 图片预览：页面内灯箱与独立子窗口

| 项目 | 图片预览实现 | 特殊能力 |
| --- | --- | --- |
| AIO Hub | `viewerjs` 库 | — |
| Chatbox | `react-zoom-pan-pinch`（`TransformWrapper`），缩放 0.1×–8×，鼠标/触控手势 + 拖动平移 | 支持 `extraButtons` 注入（如"设为头像"） |
| Cherry Studio | `ImageViewer.tsx` + `@cherrystudio/ui` `ImagePreviewDialog` | 缩放、旋转、翻转、多图前后导航、复制/下载 |
| LobeHub | `ImageFileListViewer` + `@lobehub/ui` `PreviewGroup`/`Image` | 业务侧确认是灯箱预览并支持组内切换；缩放/旋转/下载等细节在 UI 包内部 |
| SillyTavern | 复用 `Popup` 弹窗，以 CSS class toggle 实现灯箱效果；另用 `jquery.izoomify` 提供鼠标悬停放大镜 | 触屏体验存疑（未实测） |
| VCPChat | **独立 Electron 子窗口**，8 种绘图工具、本地 Tesseract.js OCR（懒加载）、缩放范围 0.05×–32× | 唯一支持 OCR 识别图片文字 |

**跨项目结论**：VCPChat 的图片预览是独立进程子窗口（代价是开销大），其它项目走页面内灯箱/弹窗；只有 VCPChat 集成了 OCR 能力。Cherry Studio 的预览能力已在业务和 UI 包两侧核实，LobeHub 的灯箱接入已核实，只有其底层 UI 包提供的具体工具按钮能力仍未下钻。

### 动画方案：只有 LobeHub 引入了 framer-motion 体系

- **AIO Hub**：自研 CSS transitions + Element Plus 内置动效
- **Chatbox**：无 framer-motion；`tailwindcss-animate` + Mantine 内置过渡预设 + `vaul` 弹簧动画 + 手写 SVG `<animate>` + 手写 CSS keyframes；消息卡片首次出现**无入场动画**
- **Cherry Studio**：无 framer-motion；`tw-animate-css` + Radix `data-state` 驱动 + 手写 CSS keyframes；折叠展开是 `hidden` 硬切换，**无高度渐变过渡**
- **LobeHub**：`motion/react`（framer-motion 新包名）用在 `WorkflowCollapse` 折叠动效和文档编辑器侧栏滑动；消息本身进场**无动画**；且两处自定义动画对全局 `animationMode` 开关的遵守程度不一致（一处读、一处不读）
- **SillyTavern**：自研 `stream-fadein.js`（流式输出渐显）+ jQuery UI + CSS transitions；消息完成渲染后触发 `CHARACTER_MESSAGE_RENDERED` 事件供扩展挂钩
- **VCPChat**：CSS transitions；三种 presentation mode 切换是 body class 变换，由 CSS 控制

**跨项目结论**：六个项目都没有为消息卡片首次出现设置明显的入场动画。LobeHub 引入了 framer-motion，但只用于少数组件；Cherry Studio 的折叠展开采用 `hidden` 硬切换，属于代码中明确可见的实现方式。

### 各项目的特殊实现差异（汇总）

- **AIO Hub**：主题持久化在 `settings.json` 而非 localStorage（与"通常在浏览器层存"的预期相反，因为是 Tauri 原生应用）；侧栏拖拽宽度由自研 `useResizable` 实现，200–600px 硬编码约束。
- **Chatbox**：文件拖入输入区**没有任何高亮遮罩或视觉反馈**（`react-dropzone` 解构了 `getRootProps`/`getInputProps` 但完全没有使用 `isDragActive`/`isDragAccept`/`isDragReject`）；桌面端 `SessionItem` **没有右键菜单**（`handleContextMenu` 在非小屏时直接 return，操作只能通过 hover 按钮和设置弹窗完成）；初始断点判定用 599.95px，后续响应式用 640px，两个数字之间存在窄缝。
- **Cherry Studio**："助手回复完成通知"开关可勾选，但全仓库找不到任何发送调用——**是个不生效的死开关**（连 TODO 都没有，区别于代码自己承认的其他缺口）。
- **LobeHub**：移动端是独立路由树 + 独立构建产物（`vite.config.ts` 按 `isMobile` 切 entry），不是同构响应式；资源管理器的文件拖拽是团队主动放弃 `dnd-kit`、自建原生 HTML5 drag/drop（注释明确写了性能理由）。
- **SillyTavern**：swipe（候选回复切换）在移动端是**点按钮，不是划手势**，与功能名字暗示的手势操作不符；主题系统的 CSS 是服务端存储而非 localStorage，切换后需要页面刷新。
- **VCPChat**：compact navigation 由 `sidebarAvatarOnly` 字段显式控制，**不是宽度断点自动触发**；表情包选择器是平铺图片网格，无搜索无分类，点击插入原始 `<img>` HTML 标签。
