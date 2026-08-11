# Manifold Desktop 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：从 [`../Chat/Manifold-Desktop-Chat调查笔记.md`](../Chat/Manifold-Desktop-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：一次生成任务的提交入口、历史选择、请求构造、Provider 交接、流式广播、取消与回写；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 的请求主链是"前端标签页 → WebView2 消息桥 → C++ 主进程线程 → Provider 流式调用"：

```text
input-bar
  -> chat-tab 本地 messages[]
  -> CHAT_SEND
  -> MainWindow::HandleChatSend
  -> Provider::StreamChat
  -> CHAT_CHUNK / CHAT_DONE 广播
  -> chat-tab 更新 DOM
```

执行层两个直接影响基本会话行为的问题：assistant 流式回复只进 DOM 不进 `messages[]`（第二次发送缺少上一轮 assistant 上下文，数据语义见会话与消息管理笔记）；`CHAT_CHUNK` 和 `CHAT_DONE` 没有会话标识，所有打开的聊天标签都监听同一广播。主进程只有一个 `m_chatThread`，常规 Chat 的并发粒度是全局单线程。

## 系统边界与生成任务主链

```text
input-bar.js 读取输入 -> app.js addUserMessage（入 messages[]）
  -> CHAT_SEND 桥消息 -> MainWindow.xaml.cpp:757-841 HandleChatSend
  -> Provider::StreamChat -> CHAT_CHUNK / CHAT_DONE 广播
  -> chat-tab.js 更新 streamingText 与 DOM（渲染细节在消息渲染器）
```

边界：会话文件如何持久化、搜索与导入导出属于会话与消息管理；标签页、侧栏、搜索浮层与错误重试的界面工作流属于 Chat UI；chunk 到 DOM 的内容渲染属于消息渲染器（`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

- **入口**：`frontend/components/input-bar.js:169-184` 读取输入文本并回调；`frontend/app.js:86-114` 调用 `addUserMessage`，将用户消息加入当前 tab 的 `messages[]`。
- **任务对象**：前端经 `CHAT_SEND` 发送整个数组、Provider、模型、system prompt 和 temperature（`app.js:86-123`）；主进程 `MainWindow.xaml.cpp:757-841` 处理桥消息并进入 Provider 流式调用。没有显式任务 ID——任务身份隐含在全局 `m_chatThread` 线程和广播事件中。
- **状态机**：未发现任务级状态机；发送时用户消息直接进入 `messages[]`，没有占位消息。

## 2. 历史选择与上下文拼装顺序

`frontend/components/chat-tab.js:119-129` 返回当前 tab 的整个 `messages[]`；没有发现按 token、分支或角色再筛选历史的逻辑。assistant 流式文本只更新 DOM 和 `streamingText`（`:27-59`），不回写 `messages[]`，因此第二轮消息不含上一轮 assistant（该数据缺口在会话与消息管理笔记）。system prompt 随请求对象发送（见第 4 节）。

## 3. 预算、截断、摘要与压缩

发送前未找到上下文截断、摘要压缩或 token 预算处理；请求直接携带当前数组。

## 4. SDK、Provider、模型与协议交接

`frontend/services/provider-api.js:4-13` 的请求对象包含 `provider`、`model`、`messages`、`systemPrompt`、`temperature`、`tools`。具体 JSON 到 HTTP Provider 的字段映射未在本次笔记中进一步展开。

## 5. 流式事件、缓冲、节流与顺序

Provider 在线程中产生 chunk，经 `PostMessageToWeb("CHAT_CHUNK")` 广播。每个聊天标签都注册全局 `CHAT_CHUNK`、`CHAT_DONE` 和 `CHAT_ERROR` listener（`chat-tab.js:27-98`）。事件没有 session/tab id，因此一个请求可能更新多个已打开标签；该可见行为尚未运行验证。chunk 到 DOM 的累积、重新解析与滚动属于消息渲染器。

## 6. 完成、异常、半截流与最终回写

- **完成**：`CHAT_DONE` 广播，前端据此收尾；完整流式文本停留在 DOM 与 `streamingText`，不写回 `messages[]` 也不落盘（落盘缺口见会话与消息管理笔记）。
- **异常**：`CHAT_ERROR` 广播，错误行的 Retry 按钮只删除错误提示，不会重发请求（`chat-tab.js:87-98`），工作流见 Chat UI 笔记。

## 7. 停止、重试、续写与重新生成

- **停止**：主进程只有一个 `m_chatThread`；新请求会先停止旧线程（`MainWindow.xaml.cpp:792-795`）。取消依赖 `stop_token`，只能在流回调再次运行时生效，不能主动中断已经阻塞的 `WinHttpReadData`。
- **重试/续写/重新生成**：除上述无效 Retry 按钮外，未发现独立的重试或重新生成机制；发送语义就是再次调用同一主链。

## 8. 队列、多会话并发与后台生成

应用提供 chat、compare、terminal 多标签，但常规 Chat 只有一条全局生成线程；未发现发送队列、每会话隔离或后台生成机制。多标签共享同一广播的串扰风险见第 5 节。

## 9. Agent、工具、知识库与附件注入点

请求对象含 `tools` 字段（`provider-api.js:4-13`），但本次未找到附件、记忆或知识库在 Chat 主链上的额外注入点。

## 10. 退出恢复、日志与已确认边界

- 会话状态全部在内存（标签局部 `messages[]`），应用退出即丢失；磁盘侧恢复能力缺失见会话与消息管理笔记。
- 未发现任务级日志、trace 或用量关联。
- 已确认边界：上述消息缺失和全局广播行为来自静态调用点；未做多标签、取消和网络阻塞场景的动态验证。

## 11. 未验证事项

- 多标签串流、取消延迟、网络阻塞场景的动态验证未做。
- JSON 到 HTTP Provider 的实际字段映射未展开。
- 停止线程的真实中断效果需运行验证。

## 12. 关键源码索引

| 职责 | 文件 |
| --- | --- |
| 标签和发送编排 | `frontend/app.js` |
| 输入收集 | `frontend/components/input-bar.js` |
| Chat 局部状态与流式 UI | `frontend/components/chat-tab.js` |
| 请求对象构造 | `frontend/services/provider-api.js` |
| 会话与发送 handler | `MainWindow.xaml.cpp:757-841` |
