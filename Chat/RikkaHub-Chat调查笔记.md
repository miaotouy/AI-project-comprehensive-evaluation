# RikkaHub Chat 调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9a35e3f2f1e2820e95c37deb82ef8f5e1592e06f`（分支：`master`）
>
> 调查方式：静态只读阅读当前快照的 Kotlin/Compose 源码，沿 Room 实体、ChatService、GenerationLoop、Provider 解码器与界面组件核对端到端主链，并综合本目录 2026-09-15 已落盘的 RikkaHub 各主题笔记；未运行应用、未连接任何 Provider 或远端服务
>
> 调查范围：聊天产品表面与系统边界、一次对话经过的责任边界与交接点、核心对象与状态权威、专项导航；不重复展开各专项的实现细节（数据 schema、请求协议、渲染器、导出格式等以对应笔记为准）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是原生 Android 的大模型聊天客户端：一部手机上的单 Activity Compose 应用，另有一套内嵌 Web 服务器把同一套会话服务与数据库暴露给局域网浏览器。会话以助手为归属单位，消息以「节点 + 候选」表达分支；Room 双表是持久化事实源，生成期间的权威状态在进程内存里。一次对话由 app 模块的 ChatService 统领，经内存队列、落库、GenerationLoop 装配、Provider 请求、流式合并与工具循环完成，回合成功结束时整段会话重写落库；内嵌 Web 端复用同一个 ChatService 与数据库。整体分为持久化、请求编排、显示、交付四层，本笔记只做导航。

## 产品表面与系统边界

- **原生端是唯一的主聊天表面**：进程只有一个可见 Activity（`RouteActivity`），起始页即聊天页；另有安全模式、拍照回传两个辅助 Activity 与 WebView 预览页，不进入主链，入口见 `RouteActivity.kt:212-318`。工作台结构见 [Chat UI](<../Chat UI/RikkaHub-ChatUI调查笔记.md>)。
- **内嵌 Web 服务器是第二套表面**：随包发布的 React 前端经 HTTP/SSE 复用宿主同一套会话服务与库，可发送消息、审批工具、导出 Markdown，是唯一的非本机生成入口。见 [外部执行体与应用协作](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)。
- **没有外部消息渠道，也没有群聊**：仓库不含 Telegram、Slack 等渠道适配；本次未找到多助手同会话或群聊入口（检查范围：`app`、`web`、`web-ui` 模块与已落盘笔记）。
- **执行边界在本机进程内**：模型请求只在宿主进程经 `ai` 模块 Provider 发起；会话、消息与媒体在 Room 与私有目录；工作区在其子进程执行；extension 与搜索 provider 只供外部能力；跨应用迁移仅单向导入。
- **仓库形态**是单 Gradle 多模块工程，外加 `web-ui`、`locale-tui`、`trace-cli` 三个旁路工程，规模与语言分布见 [仓库分布](../仓库分布/RikkaHub-仓库分布调查笔记.md)。

## 端到端聊天主链

原生端与内嵌 Web 汇入同一条链，一次回复只经过下列责任边界（完整机制见各 owner 笔记）：

1. **输入与入队**——两端都进入同一个 ChatService 发送接口；输入交给该会话的内存队列串行派发，已有活跃 Job 或未决审批时暂不派发（`ChatService.kt:405-445`）。owner：对话请求与上下文。
2. **用户消息落库**——追加 USER 节点并整会话重写（`ChatService.kt:464-508`）。owner：会话与消息管理。
3. **请求装配**——生成循环组装合成 system、按条数裁剪历史、跑输入变换器，再交 Provider（`GenerationLoop.kt:346-383`）。owner：上下文编译与提示词工程、LLM 渠道管理。
4. **流式合并**——分片在内存中合并为消息部件（`StreamChunkHandler.kt:57-303`）。owner：对话请求与上下文、消息渲染器。
5. **工具循环与审批**——需审批工具置为待定并中断本轮，用户动作后从编排层恢复；结果内联回触发它的助手消息，进入下一轮模型调用。owner：Agent 工具。
6. **回合收尾与显示**——成功时整会话重写落库并后台生成标题与建议，失败或停机只收尾内存推理；会话 StateFlow 驱动消息列表渲染与后台完成通知（`ChatService.kt:767-804`）。owner：会话与消息管理、Chat UI。

同一会话严格串行，不同会话各自持有 Job 并行运行；再次发送是排队而非打断；队列本身是内存对象，进程结束即失效。

## 核心对象与状态权威

| 对象 | 语义与权威所在层（owner 笔记） |
|---|---|
| 会话 Conversation | 归属一个助手，持会话级系统提示、注入/世界书 id 集合与工作区路径；Room 表 `conversationentity`（会话与消息管理） |
| 消息节点 MessageNode | 分支语义载体：候选消息数组加一个选中下标；Room 表 `message_node`，删除会话级联删除（会话与消息管理） |
| 消息与部件 | 角色、部件列表、注解、时间、模型 id 与用量，以 JSON 列打包进节点行（生成式输出与运行时、消息渲染器） |
| 活动路径 | 由每个节点的选中下标推得，没有父子外键，切换分支是单列修改（会话与消息管理） |
| 生成状态与队列 | 生成 Job、串行队列、待审批工具都在进程内存，进程结束即失效（对话请求与上下文） |
| 全文检索 | 独立 FTS5 虚表，只索引文本部件；标题搜索另走 LIKE（会话与消息管理） |
| 助手与 Provider 配置 | 均在 DataStore，会话只保存助手 id 与 Provider 引用，历史消息不保存助手快照（Agent 角色、LLM 渠道管理） |
| 界面状态 | 输入草稿与编辑目标、抽屉筛选与滚动位置属 ViewModel 与页面级 Compose 状态，均不落盘（Chat UI） |
| Web 投影 | 内嵌服务器从内存会话状态投影并做单节点 diff，不构成第二份消息主库（外部执行体与应用协作） |

生成期间的权威是内存会话状态，持久化事实源是 Room 双表，两者在回合结束点对齐；助手与 Provider 配置的权威都在 DataStore。

## 专项导航

- **会话与消息管理** — 数据模型、Room 双表与迁移、分支、整会话重写、FTS5：[笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)
- **对话请求与上下文** — 入队与串行调度、上下文裁剪、流式合并、停止/重试/后台保活：[笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)
- **上下文编译与提示词工程** — 两级提示注入与世界书、模板与占位符、变换器时机：[笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)
- **Chat UI** — 工作台、会话抽屉、Composer、消息操作与分支、Web 端差异：[笔记](<../Chat UI/RikkaHub-ChatUI调查笔记.md>)
- **消息渲染器** — 部件分派、原生 Markdown、代码高亮、思考时间线、工具卡：[笔记](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)
- **对话导出与分享** — Markdown/PNG 导出、配置交换、全量备份、外部导入：[笔记](../对话导出与分享/RikkaHub-对话导出与分享调查笔记.md)
- **Agent 角色** — Assistant 字段与绑定、模型/采样/工具参数、角色卡导入：[笔记](../Agent角色/RikkaHub-Agent角色配置调查笔记.md)
- **Agent 工具** — 注册顺序、审批状态机、结果回注、Step 循环、输出截断：[笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)
- **LLM 渠道管理** — 渠道配置、协议适配、模型目录与能力推断、多 Key 轮询：[笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)
- **外部执行体与应用协作** — extension 与 OAuth、PRoot 工作区、内嵌 Web 控制表面：[笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)
- **检索增强与认知编排** — 记忆注入、搜索 provider、会话 FTS 检索、附件转换：[笔记](../检索增强与认知编排/RikkaHub-检索增强与认知编排调查笔记.md)
- **生成式输出与运行时** — 部件对象模型、代码块与预览、JavaScript 工具与工作区边界：[笔记](../生成式输出与运行时/RikkaHub-生成式输出与运行时调查笔记.md)
- **媒体创作** — 图片生成工作台、未接线的视频生成、TTS/ASR 边界：[笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)
- **应用界面基础设施** — 应用装配、浮层与返回、通知、主题、窗口适配：[笔记](../应用界面基础设施/RikkaHub-应用界面基础设施调查笔记.md)
- **主动 Agent 与后台任务** — 前台服务保活的后台生成、Job 调度与恢复、无定时主动运行：[笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)
- **独特功能** — PRoot Linux 工作区与手机即服务端两项主贡献：[笔记](../独特功能/RikkaHub-独特功能调查笔记.md)
- **仓库分布** — 模块/语言/测试分布、构建与 CI、大资源：[笔记](../仓库分布/RikkaHub-仓库分布调查笔记.md)

## 关键能力与已确认边界

- **分支以候选表达，写入是回合制**：编辑或重新生成都给同一节点追加候选并选中，没有父子外键或独立分支实体；生成期间只改内存、成功结束时整会话重写，崩溃或取消会丢弃最近半截内容。
- **同一会话严格串行，且确认不存在定时主动运行**：没有 steer 或替换当前生成，再次发送即排队，停止会取消该会话全部活跃 Job；仓库内无 cron、无 WorkManager Worker 入队、无 AlarmManager/JobScheduler、无广播接收器，「时间提醒」是发送前的提示词注入。
- **检索是关键词路线**：记忆整表拼入系统提示，历史会话走 FTS5 加自定义分词，网页搜索对接多个平级 provider；全仓 Kotlin 源码本次未找到可用的向量检索或嵌入调用方。
- **交付三条链路互不复用**：对话阅读导出只取每节点当前选中的消息且只产出 Markdown/PNG；Provider 配置可编码为带密钥的二维码；全量备份是唯一可往返能力，恢复需重启。
- **媒体创作成熟度不均**：图片生成是独立于聊天的完整闭环（仅用户可触发）；视频生成模块已封装创建与轮询但应用侧无调用点；TTS/ASR 不产生可保存资产。
- **输出对象只有消息部件**：没有 artifact/canvas 协议与对象 id，代码块不可执行，唯一脚本运行时是模型可调用的 JavaScript 工具。

## 未验证事项

- 全部结论以静态源码为主：未构建或运行应用，主链交接点来自当前快照的可执行路径，未做端到端运行验证。
- 未实测流式渲染在高频分片下的帧率与重组行为、长会话滚动性能；界面只确认了入口、状态与事件绑定。
- 未连接真实 Provider，未验证各协议分支的逐字段映射、流式事件时序、多 Key 轮询的真实命中分布与重试效果。
- 未在真机验证 PRoot 安装与子进程回收、内嵌 Web 与令牌往返、FTS 分词装载、图片生成落盘及 extension/OAuth。
- 未做多端并发实验：App 与 Web 端同时写入同一会话的合并结果、内存权威源与数据库的一致性窗口未运行验证；视觉、键盘、TalkBack 与平台行为仅按静态边界记录。

## 关键源码索引

- 编排入口与状态：`app/src/main/java/me/rerere/rikkahub/service/ChatService.kt:405-508,658-805`；`service/ConversationSession.kt:21-148`、`service/MessageQueue.kt:40-118`
- 生成循环与上下文装配：`data/ai/GenerationLoop.kt:74-325,346-473`；工具工厂 `data/ai/tools/ChatToolFactory.kt:38-108`
- 会话与消息数据模型：`data/model/Conversation.kt:16-120`、`data/db/entity/ConversationEntity.kt`、`MessageNodeEntity.kt`；仓储与整会话重写 `data/repository/ConversationRepository.kt:299-309,433-472`
- 消息与部件及流式合并：`ai/src/main/java/me/rerere/ai/ui/Message.kt:17-89`、`UIMessagePart.kt:73-217`、`StreamChunkHandler.kt:57-303`
- Provider 路由与协议：`ai/src/main/java/me/rerere/ai/provider/ProviderManager.kt:16-56`、`ai/.../providers/openai/ChatCompletionsAPI.kt`、`ai/.../providers/claude/ClaudeProvider.kt`
- 界面装配与渲染：`app/src/main/java/me/rerere/rikkahub/RouteActivity.kt:212-318`、`ui/pages/chat/ChatPage.kt:94-538`、`ui/components/message/ChatMessage.kt:266-635`
- 内嵌 Web 服务端：`app/src/main/java/me/rerere/rikkahub/web/WebServerManager.kt:53-108`、`web/WebApiModule.kt:61-189`、`web/routes/ConversationRoutes.kt`
- 对照文档（存在与实现不一致处，以源码为准）：`rikkahub/docs/references/chat-generation-pipeline.md`
