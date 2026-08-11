# DeepChat Chat 概览

> 调查对象：`E:\works\git\deepchat`（重点 `src/main/session/turn.ts`、`src/main/session/data/`、`src/renderer/src/stores/ui/`、`src/renderer/src/features/chat-page/`）
>
> 调查更新日期：2026-08-07
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：Chat session 生命周期、SQLite transcript、流式 assistant blocks、IPC/renderer 状态、消息窗口化和模型请求的上下文构建、会话内/跨会话搜索
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> 2026-08-11 本文件已压缩为概览
>
> - 会话与消息管理：[`../会话与消息管理/DeepChat-会话与消息管理调查笔记.md`](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md)（数据模型、SQLite 事实源、缓存一致性、消息窗口分页接口与搜索）
> - 对话请求与上下文：[`../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md`](../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md)（提交入口、上下文构建、预算压缩、流式回写与队列）
> - Chat UI：[`../Chat UI/DeepChat-ChatUI调查笔记.md`](<../Chat UI/DeepChat-ChatUI调查笔记.md>)（ChatPage 工作台、pending lane、搜索入口与 UI 状态所有权）
> - 消息渲染：[`../消息渲染器/DeepChat-消息渲染器调查笔记.md`](../消息渲染器/DeepChat-消息渲染器调查笔记.md)（已有独立笔记；消息窗口化的 DOM 实现以该笔记 §6 为准）

## 结论摘要

DeepChat Chat 是 main process 驱动、renderer 订阅的持久化会话系统：

1. Session、Agent backend、Provider runtime 和 transcript 全部在 main process 运行；renderer 通过 typed route/event 和 preload bridge 调用 `ChatClient`、`SessionClient`，不做本地合成。
2. 事实源是 SQLite 两张表：`deepchat_messages`（user/assistant 消息的顺序、内容、状态与 metadata）与 `deepchat_assistant_blocks`（结构化流式 block），流式更新时两张表分别更新。
3. 一次回复的生命周期：用户消息进入后创建 `pending` assistant 占位 → 流式过程反复替换 assistant blocks → 成功结算 `sent`，异常写 `error` block 并置 `error`。
4. `SessionTurn` 同时提供普通发送、steer、queue、retry、delete、edit、fork、manual compaction 和 tool interaction response；pending input 有独立的 queue/steer 状态，不与已完成消息混同。
5. renderer message store 维护持久化缓存、streaming blocks、解析缓存和 IPC 增量事件；`useDisplayMessages` 用稳定 render key 让流式消息在落盘后复用显示对象；消息窗口以测量 + spacer + anchor + 二分查找实现附近消息渲染。

## 产品表面与系统边界

- 产品表面：Electron 桌面 GUI。聊天能力（会话、队列、上下文、流式、持久化、搜索）由 main process 提供，renderer 是投影层。
- 边界：subagent session 在 ChatPage 中只读（`ChatPage.vue:431-435`），仍可显示消息、plan、工具状态和最终 child result；ACP runtime 的具体外部协议 payload 未在本次专题展开。
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

- `SessionTranscript`（`src/main/session/data/transcript.ts:166-381`）：主进程侧权威生命周期——`createUserMessage` → `createAssistantMessage(pending)` → 流式 `updateAssistantContent`（替换 blocks、保持 pending）→ `finalizeAssistantMessage(sent)` 或 `setMessageError(error)`；完成与错误路径同步更新 assistant blocks、message 内容/状态、搜索文档和 Tape facts，流式中间态只更新 blocks。
- `deepchat_messages`（`deepchatMessages.ts:8-54`）：`id/session_id/order_seq/role/content/status/metadata` 等，状态仅 `pending|sent|error`，按 `(session_id, order_seq)` 建索引。
- `deepchat_assistant_blocks`（`deepchatAssistantBlocks.ts:76-115`）：`message_id + block_index` 保存结构化 block，`replaceForMessage` 一次替换保持顺序。
- renderer 投影：message store 的 `messageCache`/`streamingBlocks`/`streamRevision` 与游标分页（`stores/ui/message.ts`）；`useDisplayMessages`（`useDisplayMessages.ts:341-425`）按持久化 id 重建显示列表，用 `assistantRenderKeyByMessageId` 关联 pending 与最终落盘的同一消息。
- 队列记录（`src/shared/types/agent-interface.d.ts:258-275`）：state 为 `pending|claimed|blocked|consumed`，保存 payload、关联 message ids、assistant id、阻塞原因与时间戳。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/DeepChat-会话与消息管理调查笔记.md`](../会话与消息管理/DeepChat-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md`](../对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/DeepChat-ChatUI调查笔记.md>`](<../Chat UI/DeepChat-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/DeepChat-消息渲染器调查笔记.md`](../消息渲染器/DeepChat-消息渲染器调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- **pending input 独立通道**：steer、queue、工具 question/permission response 是 session turn 的独立输入通道（`turn.ts:36-405`），交互 UI 不把 pending input 拼进已完成消息；失败 assistant 消息保留 `error` 状态与错误 block，可 retry/fork。
- **消息窗口化**：`MessageList`/`MessageListRow` 只接收当前窗口的 `MessageListItem`（`MessageList.vue:1-65`）；`useMessageWindow` 以估算高度、ResizeObserver 实测、顶部/底部 spacer 与逻辑 anchor 保存滚动位置，`useMessageVirtualization` 在超阈值时二分查找 viewport 附近索引；同时服务历史分页与流式追加，远离 viewport 的 settled 消息仅保留估算高度（`ChatPage.vue:512-584`、`:728-826`）。
- **双层搜索**：会话内 `useChatSearch` 只匹配已加载的 display messages，不触发数据库查询；跨会话 FTS5（`deepchat_search_documents` 外部内容表 + 三个同步触发器，`deepchatSearchDocuments.ts:309-335`）经 `searchFts` bm25 查询、不可用时回退 `searchLike`；内存 MCP `conversationSearchServer`（:465-494）同时服务模型工具与设置页。
- **边界**：transcript 同时服务展示、搜索、Tape 和 usage/trace 等二级数据；附件、搜索结果快照与 legacy import 表的完整迁移链本次未追踪。

## 未验证事项

- SQLite 使用 `better-sqlite3-multiple-ciphers`，但实际数据库加密配置、事务隔离和崩溃恢复未验证。
- 流式 block 的 IPC 顺序依赖 renderer revision/cursor；未运行网络中断、快速切换 session 或重复事件场景。
- 消息窗口高度是估算与观测的组合，复杂 artifact/图片导致的异步高度变化未通过浏览器实测。
- 未运行测试、构建或桌面端交互；结论来自 main/renderer 静态源码。

## 关键源码索引

- turn 操作面：`src/main/session/turn.ts:36-405`；pending input DTO：`src/shared/types/agent-interface.d.ts:258-275`
- transcript 生命周期：`src/main/session/data/transcript.ts:166-381`
- 表定义：`src/main/session/data/tables/deepchatMessages.ts:8-54`、`deepchatAssistantBlocks.ts:76-115`、`newSessions.ts:13-30`
- 会话内查找：`src/renderer/src/features/chat-page/composables/useChatSearch.ts`、`src/renderer/src/lib/chatSearch`
- 跨会话 FTS：`src/main/session/data/tables/deepchatSearchDocuments.ts:210-265`、`:309-335`、`src/main/mcp/inMemoryServers/conversationSearchServer.ts:465-494`
- ChatPage 组合与滚动恢复：`src/renderer/src/features/chat-page/ChatPage.vue:86-232`、`:512-584`、`:728-826`
- display 稳定缓存：`src/renderer/src/features/chat-page/composables/useDisplayMessages.ts:341-425`
- 消息列表：`src/renderer/src/components/chat/MessageList.vue:1-65`
