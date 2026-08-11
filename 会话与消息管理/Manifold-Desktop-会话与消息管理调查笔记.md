# Manifold Desktop 会话与消息管理调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：从 [`../Chat/Manifold-Desktop-Chat调查笔记.md`](../Chat/Manifold-Desktop-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：会话与消息的数据模型、文件存储、生命周期、搜索、导入导出与绑定；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 的会话数据层由两部分组成：内存中的"聊天标签 + 组件局部 `messages[]`"，以及磁盘上的 `<id>.json` 会话文件（`SessionManager`）。存储层提供会话文件的增删改查与全文搜索，但正常聊天流程没有接入保存——四个直接影响基本会话行为的问题中，三个落在本类目：

1. 新对话不会持久化；关闭标签后内容丢失。
2. assistant 流式回复只进入 DOM，不写回 `messages[]`；第二次发送缺少上一轮 assistant 上下文。
3. 侧栏重命名只发送 `{title}`，C++ 后端按整份 JSON 覆盖原文件，会清除已有消息。

这些源码连接缺口说明正常会话主链尚未接通。

## 系统边界与数据主链

```text
openChatTab（生成标签 id）
  -> chat-tab 组件局部 messages[]（内存事实源）
  -> （预期）SAVE_SESSION / SessionManager.SaveSession 写 <id>.json
  -> （预期）LOAD_SESSION / SESSION_DATA 读回并渲染
  -> 搜索：SessionManager 逐个读文件子串匹配
```

边界：`CHAT_SEND` 之后的 Provider 调用、流式广播与取消属于对话请求与上下文；标签页切换、侧栏与搜索浮层的界面工作流属于 Chat UI；消息 Markdown 渲染属于消息渲染器（`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`）。

## 1. 会话、消息与分支数据模型

- **会话单位**：界面"聊天标签"。`openChatTab()` 为标签生成递增 id；如果传入已有 `sessionId`，`chat-tab.js` 发送 `LOAD_SESSION`，收到 `SESSION_DATA` 后把消息装入组件局部数组并渲染（`frontend/app.js:138-147`、`chat-tab.js:101-114`）。持久化单位是 `sessions/<id>.json`（`SessionManager.cpp:23-26`）。
- **消息模型**：`chat-tab.js:119-129` 构造 `{ role: 'user', content: text }` 加入当前 tab 的 `messages[]`，是普通线性数组。assistant 流式文本只更新 DOM 和 `streamingText`（`:27-59`），不回写 `messages[]`。
- **分支/thread**：本次未找到消息树、分支或 thread 结构。

## 2. 事实源、索引与持久化

`SessionManager` 把每个会话存为 `%LOCALAPPDATA%\Manifold\sessions\<id>.json`，支持整文件保存、加载、删除、列表和全文搜索（`SessionManager.cpp:23-131`）。前端 `session-store.js` 也实现了 `createSession()`、`addMessage()`、`updateModelMessage()` 和 `save()`。

但全仓库调用点显示：正常 Chat 流程没有调用这些写入函数，`chat-tab.js` 也不发送 `SAVE_SESSION`。因此：

- 新会话不会生成会话文件；
- assistant 回复不会进入后续请求上下文；
- `updateModelMessage()` 期望的 `role === "model"` 与其他路径使用的 `assistant` 也不一致。

即内存 `messages[]` 是实际事实源，磁盘文件是未被主链接通的另一套实现。侧栏重命名发送 `SAVE_SESSION {id, data:{title}}`（`side-panel.js:83-105`），`HandleSaveSession()` 将 `data` 原样交给整文件覆盖的 `SaveSession()`（`MainWindow.xaml.cpp:528-534`）——对已存在的会话执行重命名会把文件替换为只有标题的 JSON。

## 3. 创建、切换、归档、删除与恢复

- **创建**：标签打开即"会话"，无持久化层面的创建动作；由于正常流程不落盘，新对话关闭标签后内容丢失。
- **切换**：标签切换保留组件局部 `messages[]`（UI 工作流见 Chat UI 笔记）。
- **归档、置顶、恢复**：本次未找到对应实现或调用点。

## 4. 编辑、重试、续写、回退与分支语义

本次未找到消息级编辑、删除、回退或分支的数据操作；assistant 内容不进入 `messages[]`，使"续写/回退"在数据层天然缺失。错误行的 Retry 按钮只删除错误提示、不重发请求（`chat-tab.js:87-98`），界面工作流见 Chat UI 笔记。

## 5. 列表、分页、搜索与定位

- 后端逐个读取会话文件，对整份 JSON dump 做不区分大小写的子串搜索；无索引和结果上限（`SessionManager.cpp:97-131`）。
- 未发现分页、排序或命中定位接口；前端搜索浮层有 300ms 防抖和键盘导航（`search-overlay.js:24-58`），入口与定位工作流见 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

本快照没有持久化写路径，因此没有落盘节流或多端合并问题。内存侧的一致性风险是：`CHAT_CHUNK`/`CHAT_DONE` 广播没有会话标识，一个请求可能污染多个已打开标签的局部状态（事件链细节见对话请求与上下文笔记）。

## 7. 迁移、导入导出与保留策略

- JSON 导入：文件内容解析后直接按其中的 `id` 保存，没有 schema 或 id 路径校验（`MainWindow.xaml.cpp:648-677`）。
- JSON 导出：选择路径后写出格式化 JSON（`MainWindow.xaml.cpp:619-646`）。
- Markdown 导出：按消息角色拼接标题和正文，不修改内容（`MainWindow.xaml.cpp:679-722`）。
- `SessionPath(id)` 直接计算 `sessionsDir / (id + ".json")`（`SessionManager.cpp:23-26`）；来自导入文件或桥消息的 id 未经过路径成分校验。
- 未发现 schema 版本号或迁移机制。

## 8. Agent、模型、知识库与附件绑定

请求对象包含 `provider`、`model`、`systemPrompt`、`temperature`、`tools` 字段（`frontend/services/provider-api.js:4-13`），但本次未发现这些绑定在会话级如何保存——没有会话文件写入主链，绑定随内存请求对象存在。附件、记忆或知识库在 Chat 主链上的注入点本次未找到。

## 9. 设计取舍与已确认边界

- **双前端仓库未接通**：`session-store.js` 与 `SessionManager.cpp` 各自实现了会话写路径，但正常 Chat 主链都不调用。
- **角色命名不一致**：`updateModelMessage()` 期望 `role === "model"`，其他路径使用 `assistant`。
- **重命名破坏数据**：侧栏重命名以整文件覆盖方式保存只有标题的 JSON。
- 本类目只回答数据语义；执行层问题（全局广播、单线程）见对话请求与上下文笔记。

## 10. 未验证事项

- 多标签串流、取消延迟、路径穿越及导入恶意会话的运行结果未做动态验证（本笔记基于静态源码和调用点搜索）。
- 重命名覆盖行为未运行复现。

## 11. 关键源码索引

| 职责 | 文件 |
| --- | --- |
| Chat 局部状态与流式 UI | `frontend/components/chat-tab.js` |
| 未接入的会话前端仓库 | `frontend/services/session-store.js` |
| 会话侧栏（重命名） | `frontend/components/side-panel.js` |
| 会话文件存储 | `Manifold.Core/SessionManager.cpp` |
| 会话与发送 handler | `MainWindow.xaml.cpp:508-850` |
