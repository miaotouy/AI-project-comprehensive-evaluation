# VCPMobile Chat 调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：静态阅读 Vue/Pinia 前端、Tauri/Rust 命令、SQLite 服务与仓库内测试
>
> 调查范围：移动端 Agent/群组话题聊天、本地消息与流式链路；不覆盖 VCP 服务端、Agent/工具与同步协议细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 是一个 Android 优先的 Tauri 聊天客户端。它拥有聊天工作台、话题和消息的本地 SQLite 副本，以及把远端 VCP 服务 SSE 结果投射到 Vue 的执行层；模型推理、远端服务的最终可用性和 Agent 工具循环不属于该仓库。

聊天以 Agent 或 Group 为所有者，以其下的 Topic 作为可恢复会话。前端把选择状态、可见历史、活动流和暂存附件拆入不同 Pinia store；Rust 负责话题与消息持久化、上下文组装、请求注册及流收口。详细机制见[会话与消息管理](../会话与消息管理/VCPMobile-会话与消息管理调查笔记.md)、[对话请求与上下文](../对话请求与上下文/VCPMobile-对话请求与上下文调查笔记.md)、[Chat UI](../Chat%20UI/VCPMobile-ChatUI调查笔记.md)和[消息渲染器](../消息渲染器/VCPMobile-消息渲染器调查笔记.md)。

## 产品表面与系统边界

聊天表面是 Vue WebView 中的移动端工作台：`ChatView` 呈现当前话题历史，`InputEnhancer` 收集文本、语音和附件，左侧 Agent/Group 与话题列表决定会话。桌面端可经同步提供数据，但当前仓库的会话事实源是本地 SQLite，而非某个云端聊天 API；相应的跨端合并策略留在同步专项。入口与布局见 `src/features/chat/ChatView.vue:88-198`。

核心对象有三层：话题记录 owner、名称、未读和消息计数；消息记录角色、正文、附件、完成原因和预渲染块；活动生成记录尚未终结的助手消息。前端的 `ConversationKey` 还加入 epoch，用于阻止异步加载结果写回已切换的会话，见 `src/core/stores/chatSessionStore.ts:16-68`。

## 端到端聊天主链

1. 用户选定 Agent/Group 及其 Topic 后，ChatView 分页读入本地历史；初始页为 5 条，向上滚动再取旧消息。 
2. Composer 调用 history store。它先把用户消息乐观加入可见列表，再通过 `append_single_message` 落库，并把同一消息与设置、Channel 传给单聊或群聊命令，见 `src/core/stores/chatHistoryStore.ts:329-475`。
3. Rust 读取纯文本历史与附件提取文本，连同 Agent 配置拼装请求；注册以 UUID 表示的 pending 助手消息后发出 `thinking` 事件，并向 VCP 服务发起 SSE 请求，见 `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:87-164`。
4. `chatStreamStore` 按消息 ID 维护活动对象。`aurora` 增量先合并到待提交状态，再按 animation frame 写入视图；结束事件取得最终 blocks、移除活动流并触发标题总结，见 `src/core/stores/chatStreamStore.ts:364-582`。
5. Rust 最终化事务原子更新消息、渲染缓存、全文索引和活动生成记录，然后向前端发送终态。中断或异常退出后的 pending 行可在下次历史加载后尝试恢复，见 `src-tauri/src/vcp_modules/chat/message_service.rs:1450-1530` 与 `src/core/stores/chatStreamStore.ts:664-904`。

## 专项导航

| 主题 | 承担模块 | 对应笔记 |
|---|---|---|
| Topic、消息、附件与本地恢复 | `topic_service`、`message_service` | [会话与消息管理](../会话与消息管理/VCPMobile-会话与消息管理调查笔记.md) |
| 上下文、远端请求、SSE、取消与恢复 | `agent_chat_application_service`、`vcp_client` | [对话请求与上下文](../对话请求与上下文/VCPMobile-对话请求与上下文调查笔记.md) |
| 移动工作台与 Composer | `ChatView`、`InputEnhancer` | [Chat UI](../Chat%20UI/VCPMobile-ChatUI调查笔记.md) |
| AST、富块、附件与流式尾部 | `MessageRenderer`、预渲染器 | [消息渲染器](../消息渲染器/VCPMobile-消息渲染器调查笔记.md) |

## 关键能力与已确认边界

系统支持单 Agent 与群聊、消息编辑后截断重发、单消息删除、重新生成、附件发送、逐消息停止和群聊回合停止。它没有在当前聊天数据模型中呈现消息树或兄弟版本指针；重新生成会截断目标助手消息后的历史，再基于最后一条用户消息启动新的生成，见 `src/core/stores/chatHistoryStore.ts:588-643`。

当前聊天表面不是无状态网关：用户消息、助手终态和渲染缓存都在本地存储。反过来，浮动助手存在一条不存数据库的暂存对话路径，代码标注为未注册的 dormant asset，因此不作为主聊天能力计入，见 `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:220-348`。

## 未验证事项

本次未运行 Android 应用或连接 VCP 服务，因此未验证真实 SSE 兼容性、前后台切换后的恢复效果、键盘/读屏体验、群组实际发言策略与跨端同步冲突结果。

## 关键源码索引

- `src/features/chat/ChatView.vue:88-198`
- `src/core/stores/chatHistoryStore.ts:292-475`
- `src/core/stores/chatStreamStore.ts:364-582`
- `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:44-207`
- `src-tauri/src/vcp_modules/chat/message_service.rs:1323-1530`
