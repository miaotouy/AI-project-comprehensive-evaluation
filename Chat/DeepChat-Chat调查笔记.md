# DeepChat Chat 概览

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/main/session/turn.ts`、`src/main/session/data/`、`src/renderer/src/stores/ui/`、`src/renderer/src/features/chat-page/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：Chat session 生命周期、SQLite transcript、流式 assistant blocks、IPC/renderer 状态、消息窗口化和模型请求的上下文构建、会话内/跨会话搜索
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat Chat 是 main process 驱动、renderer 订阅的持久化会话系统：

1. Session、Agent backend、Provider runtime 和 transcript 全部在 main process 运行；renderer 通过 typed route/event 和 preload bridge 调用 `ChatClient`、`SessionClient`，不做本地合成。
2. 事实源是 SQLite 两张表：`deepchat_messages`（user/assistant 消息的顺序、内容、状态与 metadata）与 `deepchat_assistant_blocks`（结构化流式 block），流式更新时两张表分别更新。
3. 一次回复的生命周期：用户消息进入后创建 `pending` assistant 占位 → 流式过程反复替换 assistant blocks → 成功结算 `sent`，异常写 `error` block 并置 `error`。
4. `SessionTurn` 是会话回合的统一操作面，普通发送、steer、排队、重试、删除、编辑、fork、手动压缩和工具交互应答都从这里进入；pending input 有独立的 queue 与 steer 状态，不与已完成消息混同。
5. renderer 的 message store 维护持久化缓存、流式块、解析缓存和 IPC 增量事件；`useDisplayMessages` 用稳定的渲染 key，让流式消息落盘后仍复用同一个显示对象。消息窗口以实测高度配合上下 spacer 撑出占位、用逻辑 anchor 保住滚动位置，必要时再对附近的条目做二分查找。
6. 上下文压缩现在同时记录占用快照和边界标记；聊天列表把压缩显示为独立分隔行，不混入普通 assistant 消息，启动时会协调遗留的压缩标记（`src/main/agent/deepchat/harness/createDeepChatAgentHarness.ts`、`src/renderer/src/components/chat/MessageListRow.vue`）。
7. Tape 成为 transcript 的可重建事实来源：终态消息事实可经投影器重放到消息、结构化内容、blocks 与搜索文档表，并用独立 projection cursor 记录已应用的 Tape incarnation 和 entry 上界。
8. 消息导航由两件事承担：滚动缩略图（message map）用与窗口化同一张布局表计算刻度，跳转失败时可重试定位（`src/renderer/src/features/chat-page/model/minimapTicks.ts`、`messageJumpRetry.ts`）。
9. 输入侧新增 composer 路由与文档序列化：附件、内联引用和会话引用在提交前统一归类，输入内容的序列化与恢复也由这一层负责，避免草稿与提交两份结构各自演化（`composerInputRouting`、`composerDocumentSerialization`）。

## 产品表面与系统边界

- 产品表面：Electron 桌面 GUI。聊天能力（会话、队列、上下文、流式、持久化、搜索）由 main process 提供，renderer 是投影层。
- 边界：subagent session 在 ChatPage 中只读（`ChatPage.vue:428` `isReadOnlySession`，session kind 为 subagent），仍可显示消息、工具状态和最终 child result；ACP runtime 的具体外部协议 payload 未在本次专题展开。
- 通用主题、弹窗库、动画等非聊天主链基础设施不在本文件范围（本文件无独立通用界面盘点章节）。

## 端到端聊天主链

一条 text 调用链：

```text
ChatPage
  -> ChatClient/SessionClient（preload bridge）
  -> main SessionTurn
     -> session gate + runtime.pending
     -> SessionTranscript.createUserMessage
     -> createAssistantMessage(status=pending)
     -> Agent/Provider stream
        -> transcript.updateAssistantContent(blocks)
        -> IPC message events
     -> finalizeAssistantMessage(sent) 或 setMessageError(error)
  -> Pinia message/session store
  -> useDisplayMessages
  -> MessageList / MessageListRow
```

## 核心对象与状态权威

- `SessionTranscript`（`src/main/session/data/transcript.ts:166-381`）承担主进程侧的权威生命周期：用户消息先写库，随后创建 `pending` 占位的 assistant 消息；流式期间反复替换 blocks，且不改变这一状态；正常结束置 `sent`，异常则写入 error block 并把消息置 `error`。完成与错误路径同步更新 assistant blocks、消息内容与状态、搜索文档和 Tape facts，流式中间态只更新 blocks。
- `deepchat_messages`（`deepchatMessages.ts:8-54`）：消息表，保存消息标识、会话关联、序号、角色、内容、状态与 metadata 等；状态只取 `pending`、`sent`、`error` 三种，按会话与序号建索引。
- `deepchat_assistant_blocks`（`deepchatAssistantBlocks.ts:76-115`）：该表以消息标识加 block 序号为键保存结构化 block，`replaceForMessage` 每次替换整条消息，写入顺序保持不变。
- renderer 投影：message store 持有持久化缓存、流式块与修订号，游标分页见 `stores/ui/message.ts`；`useDisplayMessages`（`useDisplayMessages.ts:341-425`）按持久化 id 重建显示列表，用渲染 key 关联 pending 与最终落盘的同一消息。
- 队列记录（`src/shared/types/agent-interface.d.ts:298-320`）：保存 payload、关联 message ids、assistant id、阻塞原因与时间戳；state 状态机取值：
  - `pending`、`claimed`、`blocked`、`retry_required`、`consumed`（触发与恢复语义见下文 queue 状态）

## 专项导航

| 主题 | 调查笔记 |
| --- | --- |
| 会话与消息管理 | [DeepChat 会话与消息管理调查笔记](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md) |
| 对话请求与上下文 | [DeepChat 对话请求与上下文调查笔记](../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md) |
| Chat UI | [DeepChat ChatUI 调查笔记](<../Chat UI/DeepChat-ChatUI调查笔记.md>) |
| 消息渲染 | [DeepChat 消息渲染器调查笔记](../消息渲染器/DeepChat-消息渲染器调查笔记.md) |
| 横向对比 | [会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)、[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)、[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>) |
| 跨层综合结论 | [Chat 横向对比](../Chat/Chat横向对比.md) |

## 关键能力与已确认边界

- **pending input 独立通道**：steer、队列输入以及工具 question/permission 的应答，都作为 session turn 的独立输入通道进入（`src/main/session/turn.ts:36-405`），交互界面不会把它们拼进已完成消息；失败的 assistant 消息保留 `error` 状态与错误 block，可以重试或 fork。队列输入另有两项语义（源码确认）：
  - 释放后未发送（#2137）：队列记录被释放后若始终没有真正发出，会转入 `retry_required`；持久化形态是 `blocked` 加 `retry_required_at` 时间列（`deepchatPendingInputs.ts` 的 schema v67）。`SessionTurn` 为这一状态提供恢复与重试两个操作，并暴露对应路由。
  - 重启恢复：`recoverInputsAfterRestart` 返回受影响的会话与仍在队列的输入集合；被 claimed 但尚未生成用户消息的队列项释放回队列，未读的 steer 消息标记为失败（`src/main/session/data/pendingInputs.ts:392-468`）。
- **队列容量**：每个会话最多保留 10 个活动 queue 输入，数据层按活动项计数拒绝继续入队；常量与门控见 `src/shared/pendingInput.ts:2`、`src/main/session/data/pendingInputs.ts:474`。
- **Tape transcript 投影**：`TranscriptProjectionApplier` 把 Tape 的 message facts 以幂等 upsert/replace 写回消息表、user 内容分表、assistant blocks 和搜索文档；retraction event 则成批清理所有消息 sidecar。投影进度写入 `deepchat_transcript_projection_meta`，使启动恢复只重放 cursor 之后的 entry（`src/main/session/data/transcriptProjection.ts`、`tables/deepchatTranscriptProjectionMeta.ts:20-87`）。
- **消息窗口化**：消息列表只渲染当前窗口内的条目（`MessageList.vue:1-65`）。窗口计算拆成两个 hook：一个以估算高度配合 ResizeObserver 实测，用顶部与底部 spacer 和逻辑 anchor 保存滚动位置；另一个在超出阈值时二分查找视口附近的索引。窗口同时服务历史分页与流式追加，远离视口的已结算消息仅保留估算高度。滚动缩略图复用同一张逻辑布局表计算每条的 top/height 比例，跳转定位失败时走重试路径。hook 与缩略图的实现在 `useMessageWindow.ts`、`useMessageVirtualization.ts`、`minimapTicks.ts` 与 `messageJumpRetry.ts`。
- **跨会话引用**：Agent 的 `read_session` 工具按 cursor 分页读取另一会话的消息或搜索命中，预览与详情分别有字符上限 800 与 8192；Unicode 大小写折叠在 JS 侧完成，未使用 SQLite 的 `lower()`；读取结果需经调用方会话校验（`src/shared/sessionReferences.ts`、`src/main/session/data/sessionReferences.ts`、`src/main/tool/agentTools/agentToolManager.ts`）。
- **双层搜索**：会话内搜索只匹配已加载的 display messages，不触发数据库查询；跨会话走 FTS5（`deepchat_search_documents` 外部内容表 + 三个同步触发器，`deepchatSearchDocuments.ts:309-335`），以 bm25 查询为主、不可用时回退 LIKE；内存 MCP 服务同时提供模型工具与设置页入口（`conversationSearchServer.ts:465-494`）。
- **边界**：transcript 同时服务展示、搜索、Tape 和 usage/trace 等二级数据；附件、搜索结果快照与 legacy import 表的完整迁移链本次未追踪。

## 未验证事项

- SQLite 使用 `better-sqlite3-multiple-ciphers`，但实际数据库加密配置、事务隔离和崩溃恢复未验证。
- 流式 block 的 IPC 顺序依赖 renderer revision/cursor；未运行网络中断、快速切换 session 或重复事件场景。
- 消息窗口高度是估算与观测的组合，复杂图片/富内容导致的异步高度变化未通过浏览器实测；消息地图刻度依赖布局表可用，未运行超长会话下的刻度精度与跳转重试。
- 未运行测试、构建或桌面端交互；结论来自 main/renderer 静态源码。

## 关键源码索引

- turn 操作面：`src/main/session/turn.ts:36-405`；pending input DTO：`src/shared/types/agent-interface.d.ts:298-320`
- transcript 生命周期：`src/main/session/data/transcript.ts:166-381`
- 表定义：`src/main/session/data/tables/deepchatMessages.ts:8-54`、`deepchatAssistantBlocks.ts:76-115`、`newSessions.ts:13-30`
- Tape transcript 投影：`src/main/session/data/transcriptProjection.ts`、`src/main/session/data/tables/deepchatTranscriptProjectionMeta.ts`
- 会话内查找：`src/renderer/src/features/chat-page/composables/useChatSearch.ts`、`src/renderer/src/lib/chatSearch`
- 跨会话 FTS：`src/main/session/data/tables/deepchatSearchDocuments.ts:210-265`、`:309-335`、`src/main/mcp/inMemoryServers/conversationSearchServer.ts:465-494`
- ChatPage 组合与滚动恢复：`src/renderer/src/features/chat-page/ChatPage.vue:86-232`、`:512-584`、`:728-826`
- display 稳定缓存：`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:341-425`
- 消息列表：`src/renderer/src/components/chat/MessageList.vue:1-65`
- 消息地图与跳转重试：`src/renderer/src/features/chat-page/model/minimapTicks.ts`、`messageJumpRetry.ts`
- 输入路由与文档序列化：`src/renderer/src/features/chat-page/composables/useComposerInputRouting.ts`、`model/composerInputRouting.ts`、`model/composerDocumentSerialization.ts`
- 会话引用读取：`src/shared/sessionReferences.ts`、`src/main/session/data/sessionReferences.ts`、`src/main/tool/agentTools/agentToolManager.ts`
