# LobeHub Chat 概览

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：只读源码（Read + Grep + Glob，逐文件通读，未凭猜测下结论）
>
> 调查范围：聊天会话、消息构建、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 是全栈聊天工作台：Web、Electron 桌面端与独立打包的移动端 SPA 共用同一套会话模型，前端双层 Zustand store 与自建服务端数据库共同构成状态体系，模型调用分本地 client agent 与服务端 Gateway 两条执行路径。

- 会话按多维坐标压平成消息桶：`ConversationContext` 描述坐标，`messageMapKey.ts` 按优先级归一化 scope 后拼出分桶键，共 6 种以上 scope；本地副本使用更细的 key，服务端列表缓存的身份另由 `services/message/cache` 计算。
- 每个会话桶的消息只有全局 ChatStore 的 transcript 层写入，写完落到 IndexedDB 本地副本（`@/libs/replica`）；会话级的 ConversationStore 从上往下单向镜像，收到写入时先转发回副本再回读。
- 一次生成从发送 action 开始：先构造临时消息与 operation，再分流到 client agent 或 Gateway，流式结果回写后落库；operation 是前后端交接任务的载体。审批与干预先由 `resolveGatewayResume` 判断应该走 Gateway 新 operation 还是本地 runtime 重建，异构 Agent 另走 IPC 与 tRPC。
- 浏览器与服务端的 Agent 配置、上下文事实、工具规则和模型参数解析已抽到共享 `packages/mecha`；两端保留各自的数据采集与 transport，但不再维护两套上下文决策规则。
- Gateway 在实验开关下按用户或分享身份复用 WebSocket，并按 operation 订阅事件；同一会话还有排队输入时，服务端 Agent 会在决策点以软中断交还当前 turn，让队列接着派发下一条，排队输入因此不必等长循环自然跑完。
- 渲染侧由 `conversation-flow` 三阶段 parse 把消息树压成 flatList，Virtua 按 role 分派渲染；桌面端完成/审批通知联动聊天状态并深链回 Topic，Web/PWA 无系统级通知。

## 产品表面与系统边界

- **产品表面**：Web 端基于 Next.js；Electron 桌面端自绘标题栏并支持桌面通知，通过 IPC 驱动本地异构 Agent；移动端是独立打包的 SPA，走 `(mobile)` 路由树加底部 TabBar，布局单独设计。
- **后端**：自建服务端由 tRPC lambda 与 `packages/database` 构成，承担 CRUD、BM25 检索和 Gateway 执行；模型接入统一走 `ModelRuntime` 与各 provider adapter（见 LLM 渠道管理专项），服务端自身不做推理。
- **事实源**：权威数据存放在服务端数据库；前端通过 `messageService` 与 SWR 读写，并缓存到 IndexedDB；两层前端 store 里的 `displayMessages` 是解析后的展示态。
- **不拥有的层级**：通用界面基础设施（弹窗库、Toast、主题、动画、断点、拖放、i18n、PWA 安装等）已移出，见 [`../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md`](../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md)。

## 端到端聊天主链

```text
用户输入（Composer：Lexical 编辑器，草稿/mention/slash/附件/语音消息）
  -> 会话级 ConversationStore.sendMessage（读 composer 参数与 displayMessages，过滤 isLocalOnlyMessage；现为 106 行薄包装）
  -> 全局 ChatStore.sendMessage（agentRun/actions/entries/conversationLifecycle/index.ts：提取 skills/tools/mentions/文件引用、Command Bus 处理 /compact 等命令、构造 operationContext）
  -> 生成 user/assistant 临时消息 + operation（临时消息与 operation 在同一发送链内创建）
  -> 分流：client agent（executeClientAgent）| Gateway（transports/gateway -> webapi/chat/[provider]/route.ts -> ModelRuntime.chat）
  -> 流式事件经 operation 状态机（生成/审批/暂停/停止）驱动 UI 与回写
  -> 落库：messageService + 本地副本（IndexedDB replica）；会话级 store 以单向镜像读取副本
  -> 渲染：parse 重算 displayMessages -> Virtua 虚拟列表增量更新（keepMounted 保护流式消息）
  -> 完成：agentRun/actions/lifecycle/buildRunLifecycle 停止 loading + 桌面通知 + markTopicUnread
```

发送主逻辑落在全局 ChatStore：`agentRun/actions/entries/conversationLifecycle/index.ts`（约 2,180 行）在这里创建临时消息与 operation，并完成发送参数提取；会话级的 `sendMessage.ts` 只做前置 hook 与中断检查，然后转发给它。命令类输入交给 Command Bus：`/compact` 转成压缩 operation，`/goal` 向选定工具注入 `lobe-goal`，单 Agent 场景下直接 @mention 即成为执行路由；运行时类型统一由 `selectRuntimeType` 选出。Web 端另有语音消息入口 `sendVoiceMessage`。

发送链路上的各入口：

| 环节 | 源码入口 |
| --- | --- |
| 发送与上下文构造 | `conversationLifecycle/index.ts` 里的 sendMessage 入口与 operationContext 构造 |
| 会话级前置 | `src/features/Conversation/store/slices/message/action/sendMessage.ts` |
| 命令处理 | `processCommands`，/goal 注入、@mention 执行路由与 selectRuntimeType 都在发送链内 |
| 事件与生命周期 | `agentRun/actions/transports/{gateway,client,hetero}/` 与 `agentRun/actions/lifecycle/buildRunLifecycle.ts` |
| 语音消息 | `ChatInput/VoiceMessage/` 与 sendVoiceMessage |

## 核心对象与状态权威

| 对象 | 职责与状态 |
| --- | --- |
| 分桶键 | `ConversationContext` 描述会话的多维坐标，`messageMapKey.ts` 按优先级归一化 scope 后拼成字符串，作为消息桶的 key |
| `UIChatMessage` | 扁平的展示消息行，携带标识、父子归属、角色、工具与 agent 关联等字段；权威源在服务端，前端缓存与两处展示副本都为派生结果 |
| 全局 ChatStore | `dbMessagesMap` 存原始消息，`messagesMap` 存 parse 后的结果，两者由 transcript 层独占写入；另有 `messagePagingMap` 记录分页游标、`messageReplica` 记录本地副本状态。生成任务保存在 operation 相关 map 中，刻意做成全局状态以支持多 Agent/Topic 并行 |
| 会话级 ConversationStore | 持有 `dbMessages` 与 `displayMessages`，外加 generation、editing、selection、scroll、virtua 与 `pendingArgsUpdates` 等 UI 态；UI 态按 contextKey 隔离，实例跨 topic 存活，切换时原地重置 |
| 服务端 | message/topic 表、`message:list` 的列表缓存身份（`services/message/cache` 的 `getMessageListCacheIdentity`）、BM25 检索、Gateway agent 状态 |

## 专项导航

| 主题 | 笔记 |
| --- | --- |
| 会话与消息管理 | [LobeHub-会话与消息管理调查笔记.md](../会话与消息管理/LobeHub-会话与消息管理调查笔记.md) |
| 对话请求与上下文 | [LobeHub-对话请求与上下文调查笔记.md](../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md) |
| Chat UI | [LobeHub-ChatUI调查笔记.md](<../Chat UI/LobeHub-ChatUI调查笔记.md>) |
| 消息渲染器 | [LobeHub-消息渲染调查笔记.md](../消息渲染器/LobeHub-消息渲染调查笔记.md) |
| 横向对比 | [会话与消息管理横向对比.md](../会话与消息管理/会话与消息管理横向对比.md)、[对话请求与上下文横向对比.md](../对话请求与上下文/对话请求与上下文横向对比.md)、[ChatUI横向对比.md](<../Chat UI/ChatUI横向对比.md>) |
| 相关专项 | 生成式输出与运行时、Agent 工具、Agent 角色、LLM 渠道管理；应用界面基础设施盘点见 [LobeHub-应用界面基础设施调查笔记.md](../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md) |

## 关键能力与已确认边界

- **分支**：每条消息的激活分支指针存在父消息的 `metadata.activeBranchIndex` 上，由 `BranchResolver` 解析；索引越界说明乐观更新还在进行中。历史数据有新、旧两种形态（dual-form），读取时都兼容；数据语义见会话与消息管理笔记。
- **压缩**：`/compact` 转成独立的 compression operation，待摘要消息由 `ClientCompressionTransport` 处理；token 预算落在 runtime 与 Gateway 一侧，本次未展开。
- **搜索**：Topic 搜索走服务端 BM25，匹配标题与消息内容；`message.searchMessages` 端点存在，本次未找到前端调用，消息级定位因此未确认。
- **停止/取消**：由 operation 状态机驱动；Gateway 审批的过渡态窗口期内，Stop 不会真正中断生成，`INPUT_LOADING_OPERATION_TYPES` 的注释承认这一已知限制。
- **多会话并发**：operations 保存在全局，支持并行生成；群聊按 group 与 group_agent 两种 scope 加 subAgentId 分桶。
- **排队续作**：客户端把「还有排队消息」的状态同步到顶层 Gateway operation，运行时用 `queued_message_interrupt` 收口当前 turn，再由队列派发下一条；同步失败时退回原本的完成后 drain 语义。
- **异构 Agent**：AskUser 类中断在本地经 IPC、远程经 tRPC 把答案回送给阻塞中的执行流程。
- **边界**：本地分桶 key 与服务端缓存 key 不同构，是长期维护的耦合点；通用界面基础设施位于聊天主链之外，已单独成篇。

## 未验证事项

- 全局 `messagesMap` 的 UI 消费点尚未排查完整；主渲染读取的是会话级镜像。
- 诊断模块 doctor/diagnose.ts 产出的修复补丁由 `TopicDoctorModal` 人工触发，交服务端的 `topicDoctorRepo.repair` 处理，本次未见自动应用的路径；该补丁的 SQL 未下钻。
- Gateway resume 与本地 client runtime 两条审批路径是否行为等价——仅确认两套独立实现，未运行验证。
- `ModelRuntime` 与各 provider adapter 的最终 HTTP 字段未逐一核对。
- 本轮按引用路径核对了发送链、镜像同步与生命周期的归位，未重跑聊天链路；行号引用以模块级定位为准。
- 通用 UI 的未核实项随盘点搬到应用界面基础设施笔记，涉及弹窗 focus trap、ActionIcon 的 aria-label、断点像素值、拖拽机制与 SW 推送，见 [LobeHub-应用界面基础设施调查笔记.md](../应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md)。

## 关键源码索引

- `src/store/chat/utils/messageMapKey.ts`（会话分桶 key）
- `src/features/Conversation/ConversationProvider.tsx`、`StoreUpdater.tsx`（会话级镜像）
- `src/store/chat/slices/message/transcript/`、`actions/query.ts`（副本唯一写入者与读取合并）
- `src/services/message/{cache,replica}.ts`（缓存身份与副本契约）
- `src/features/Conversation/store/slices/message/action/sendMessage.ts`、`agentRun/actions/entries/conversationLifecycle/index.ts`（发送与上下文）
- `src/store/chat/slices/agentRun/actions/entries/conversationControl.ts`（审批/干预二分）
- `src/store/chat/slices/agentRun/actions/{dispatch,lifecycle,transports}/`（分流、生命周期、事件处理）
- `src/store/chat/slices/operation/types.ts`（operation 状态机）
- `packages/conversation-flow/src/parse.ts`（三阶段解析入口）
- `src/app/(backend)/webapi/chat/[provider]/route.ts`（Gateway 请求入口）
- `src/store/chat/slices/agentRun/actions/lifecycle/buildRunLifecycle.ts`（完成副作用）
