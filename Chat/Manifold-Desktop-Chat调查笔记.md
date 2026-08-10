# Manifold Desktop Chat 调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-07
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读核对 Chat 前端、会话存储和 C++ 消息桥；未修改目标仓库
>
> 调查范围：会话状态、消息构建与发送、持久化、流式更新、搜索和导入导出
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论

Manifold Desktop 的 Chat 是一套较薄的“标签页内存状态 + WebView2 消息桥 + C++ 文件存储”实现：

```text
input-bar
  -> chat-tab 本地 messages[]
  -> CHAT_SEND
  -> MainWindow::HandleChatSend
  -> Provider::StreamChat
  -> CHAT_CHUNK / CHAT_DONE 广播
  -> chat-tab 更新 DOM
```

存储层提供会话文件的增删改查，但正常聊天流程没有接入保存。当前代码因此存在四个直接影响基本会话行为的问题：

1. 新对话不会持久化；关闭标签后内容丢失。
2. assistant 流式回复只进入 DOM，不写回 `messages[]`；第二次发送缺少上一轮 assistant 上下文。
3. `CHAT_CHUNK` 和 `CHAT_DONE` 没有会话标识，所有打开的聊天标签都监听同一广播。
4. 侧栏重命名只发送 `{title}`，C++ 后端按整份 JSON 覆盖原文件，会清除已有消息。

这些源码连接缺口说明正常会话主链尚未接通。

## 会话与发送

`openChatTab()` 为界面标签生成递增 id；如果传入已有 `sessionId`，`chat-tab.js` 发送 `LOAD_SESSION`，收到 `SESSION_DATA` 后把消息装入组件局部数组并渲染（`frontend/app.js:138-147`、`chat-tab.js:101-114`）。

## 消息构建流程

1. **输入与 UI 消息对象**：`frontend/components/input-bar.js:169-184` 读取输入文本并回调；`frontend/app.js:86-114` 调用 `addUserMessage`，将用户消息加入当前 tab 的 `messages[]`。`chat-tab.js:119-129` 构造 `{ role: 'user', content: text }`。
2. **历史筛选**：`frontend/components/chat-tab.js:119-129` 返回当前 tab 的整个 `messages[]`；没有发现按 token、分支或角色再筛选历史的逻辑。assistant 流式文本只更新 DOM 和 `streamingText`（`:27-59`），不回写 `messages[]`，因此第二轮消息不含上一轮 assistant。
3. **system prompt、附件与工具**：`frontend/services/provider-api.js:4-13` 的请求对象包含 `provider`、`model`、`messages`、`systemPrompt`、`temperature`、`tools`；本次未找到附件、记忆或知识库在 Chat 主链上的额外注入点。
4. **截断与压缩**：发送前未找到上下文截断、摘要压缩或 token 预算处理；请求直接携带当前数组。
5. **最终请求与 Provider**：前端通过 `CHAT_SEND` 发送上述 payload；`MainWindow.xaml.cpp:757-841` 处理桥消息并进入 Provider 流式调用，返回 `CHAT_CHUNK`/`CHAT_DONE`。具体 JSON 到 HTTP Provider 的字段映射未在本次笔记中进一步展开。
6. **边界**：上述消息缺失和全局广播行为来自静态调用点；未做多标签、取消和网络阻塞场景的动态验证。

发送时，用户消息通过 `addUserMessage()` 进入局部 `messages[]`，随后前端把整个数组、Provider、模型、system prompt 和 temperature 发给后端（`app.js:86-123`）。主进程只有一个 `m_chatThread`；新请求会先停止旧线程（`MainWindow.xaml.cpp:792-795`）。取消依赖 `stop_token`，只能在流回调再次运行时生效，不能主动中断已经阻塞的 `WinHttpReadData`。

每个聊天标签都注册全局 `CHAT_CHUNK`、`CHAT_DONE` 和 `CHAT_ERROR` listener（`chat-tab.js:27-98`）。事件没有 session/tab id，因此一个请求可能更新多个已打开标签；该可见行为尚未运行验证。

## 持久化缺口

`SessionManager` 把每个会话存为 `%LOCALAPPDATA%\Manifold\sessions\<id>.json`，支持整文件保存、加载、删除、列表和全文搜索（`SessionManager.cpp:23-131`）。前端 `session-store.js` 也实现了 `createSession()`、`addMessage()`、`updateModelMessage()` 和 `save()`。

但全仓库调用点显示：正常 Chat 流程没有调用这些写入函数，`chat-tab.js` 也不发送 `SAVE_SESSION`。assistant chunk 只更新 `streamingText` 和 DOM（`chat-tab.js:27-59`）。因此：

- 新会话不会生成会话文件；
- assistant 回复不会进入后续请求上下文；
- `updateModelMessage()` 期望的 `role === "model"` 与其他路径使用的 `assistant` 也不一致。

侧栏重命名发送 `SAVE_SESSION {id, data:{title}}`（`side-panel.js:83-105`），`HandleSaveSession()` 将 `data` 原样交给整文件覆盖的 `SaveSession()`（`MainWindow.xaml.cpp:528-534`）。对已存在的会话执行重命名会把文件替换为只有标题的 JSON。

## 搜索与导入导出

- 搜索：后端逐个读取会话文件，对整份 JSON dump 做不区分大小写的子串搜索；无索引和结果上限（`SessionManager.cpp:97-131`）。前端搜索浮层有 300ms 防抖和键盘导航（`search-overlay.js:24-58`）。
- JSON 导入：文件内容解析后直接按其中的 `id` 保存，没有 schema 或 id 路径校验（`MainWindow.xaml.cpp:648-677`）。
- JSON 导出：选择路径后写出格式化 JSON（`MainWindow.xaml.cpp:619-646`）。
- Markdown 导出：按消息角色拼接标题和正文，不修改内容（`MainWindow.xaml.cpp:679-722`）。

`SessionPath(id)` 直接计算 `sessionsDir / (id + ".json")`（`SessionManager.cpp:23-26`）；来自导入文件或桥消息的 id 未经过路径成分校验。

## 交互边界

- 流式每个 chunk 都无条件滚到底部，用户无法稳定停留在历史位置（`chat-tab.js:58`）。
- 流式指示器会在首个文本 chunk 重新赋值 `innerHTML` 时被移除。
- 错误行的 Retry 按钮只删除错误提示，不会重发请求（`chat-tab.js:87-98`）。
- 应用提供 chat、compare、terminal 多标签，但常规 Chat 只有一条全局生成线程。

Markdown 渲染和 HTML 边界见消息渲染调查笔记。

## 关键文件

| 职责 | 文件 |
| --- | --- |
| 标签和发送编排 | `frontend/app.js` |
| Chat 局部状态与流式 UI | `frontend/components/chat-tab.js` |
| 未接入的会话前端仓库 | `frontend/services/session-store.js` |
| 会话侧栏 | `frontend/components/side-panel.js` |
| 会话文件存储 | `Manifold.Core/SessionManager.cpp` |
| 会话与发送 handler | `MainWindow.xaml.cpp:508-850` |

## 验证边界

本笔记基于静态源码和调用点搜索。多标签串流、取消延迟、路径穿越及导入恶意会话的运行结果未做动态验证。
