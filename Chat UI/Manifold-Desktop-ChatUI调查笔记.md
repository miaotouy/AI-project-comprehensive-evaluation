# Manifold Desktop Chat UI 调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：从 [`../Chat/Manifold-Desktop-Chat调查笔记.md`](../Chat/Manifold-Desktop-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码；未运行验证，视觉效果与焦点行为无法确认
>
> 调查范围：标签工作台结构、会话侧栏、输入区、流式反馈、错误重试与搜索浮层工作流；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 的 Chat 界面是一套较薄的"标签页内存状态"实现：应用提供 chat、compare、terminal 多标签，聊天内容与流式状态全部放在 `chat-tab` 组件局部（`messages[]`、`streamingText`），没有全局 UI store。界面层存在几个直接影响使用的问题：

- 新对话不持久化，关闭标签后内容丢失，界面没有对应的保存或恢复路径（数据语义见会话与消息管理笔记）。
- 流式期间每个 chunk 无条件滚到底部，用户无法稳定停留在历史位置。
- 错误行的 Retry 按钮只删除错误提示，不重发请求。
- 一个请求可能更新多个已打开标签，界面没有运行标签标记（执行语义见对话请求与上下文笔记）。

## 工作台边界与用户主链

```text
打开应用（多标签工作台）
  -> openChatTab 新建标签 / 侧栏选择会话
  -> input-bar 输入 -> 发送（CHAT_SEND）
  -> 流式反馈（chunk 追加、滚动到底）
  -> 错误提示（Retry 无效）
  -> 关闭标签 / 重命名会话 -> 内容丢失或文件被覆盖
```

边界：消息内容与 Markdown 渲染、流式 DOM 生命周期、HTML 安全边界属于消息渲染器（`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`）；会话文件如何保存与加载属于会话与消息管理；`CHAT_SEND` 之后的执行链属于对话请求与上下文。

## 1. 页面结构、导航与多窗口

`frontend/app.js` 负责标签与发送编排，提供 chat、compare、terminal 多标签。`openChatTab()` 为界面标签生成递增 id，传入已有 `sessionId` 时发送 `LOAD_SESSION` 加载（数据侧见会话与消息管理笔记 1）。切换标签保留组件局部 `messages[]` 与 `streamingText`，无跨标签共享状态。本快照为单 WebView2 窗口，未发现多窗口或分离窗口机制。

## 2. 会话列表、搜索与现场恢复

- **侧栏**（`frontend/components/side-panel.js`）：会话列表与重命名入口；重命名发送 `SAVE_SESSION {id, data:{title}}`，后端整文件覆盖（数据语义见会话与消息管理笔记 2）。
- **搜索浮层**（`frontend/components/search-overlay.js:24-58`）：300ms 防抖和键盘导航；底层逐文件子串扫描的实现见会话与消息管理笔记 5。
- **现场恢复**：无——会话不落盘，关闭标签后内容丢失，重新打开没有恢复路径。

## 3. Composer、草稿、附件与快捷输入

`frontend/components/input-bar.js:169-184` 读取输入文本并回调。草稿保存、附件输入与快捷输入在本类目范围内未调查（原笔记未覆盖）。

## 4. Agent、模型、工具与发送前配置

请求对象携带 `provider`、`model`、`systemPrompt`、`temperature`、`tools`（`frontend/services/provider-api.js:4-13`），但界面层是否存在模型/温度等发送前配置入口，本次未在源笔记中发现证据（未核实）。

## 5. 发送、排队、流式反馈与停止

- **发送**：输入回调后经 `addUserMessage` 加入 `messages[]` 并发送 `CHAT_SEND`（执行链见对话请求与上下文笔记 1）。
- **流式反馈**：assistant chunk 追加到 `streamingText` 并重建 DOM；流式指示器会在首个文本 chunk 重新赋值 `innerHTML` 时被移除（`chat-tab.js:34-45`，DOM 生命周期细节见消息渲染笔记）。
- **滚动**：每个流式 chunk 都无条件滚到底部，用户无法稳定停留在历史位置（`chat-tab.js:58`）。
- **排队与停止**：未发现界面级排队或每标签停止入口；停止语义只有"新请求停止旧线程"（对话请求与上下文笔记 7）。

## 6. 消息操作、分支与版本导航

- 错误行的 Retry 按钮只删除错误提示，不会重发请求（`chat-tab.js:87-98`）。
- 未发现消息编辑、复制、删除或分支导航入口（原笔记未覆盖）。

## 7. 多会话、多模型、群聊与后台生成

多标签共享同一条全局生成线程；`CHAT_CHUNK`/`CHAT_DONE` 广播没有会话标识，一个请求可能更新多个已打开标签，界面没有"哪条在运行"的标记（执行语义见对话请求与上下文笔记 5、8）。compare 标签与本笔记的聊天主链并存。

## 8. Chat UI 状态所有权与同步

- `messages[]`、`streamingText` 均为 `chat-tab` 组件局部状态（`chat-tab.js:27-59,119-129`），没有全局 store；标签切换时状态随组件保留。
- 无草稿持久化；关闭标签即丢失。
- 无跨窗口同步问题（单窗口）。

## 9. 键盘、焦点、响应式与关键路径可用性

本次未调查（原笔记未覆盖，且需运行验证）。

## 10. 设计取舍与已确认边界

- **内存状态 + 无持久化**：界面状态与文件存储两套系统未接通（会话与消息管理笔记 2）。
- **全局广播无隔离**：多标签同听一个事件流，无运行标记（对话请求与上下文笔记 5）。
- **阅读位置不可停留**：流式滚动强制到底。
- **错误恢复路径无效**：Retry 不重发。
- 通用组件盘点（主题、动画、弹窗库等）不在本笔记范围。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性与响应式行为需运行验证。
- 多标签串流下"一个请求更新多个标签"的可见行为未运行验证。

## 12. 关键源码索引

| 职责 | 文件 |
| --- | --- |
| 标签和发送编排 | `frontend/app.js` |
| Chat 局部状态与流式 UI | `frontend/components/chat-tab.js` |
| 输入区 | `frontend/components/input-bar.js` |
| 会话侧栏 | `frontend/components/side-panel.js` |
| 搜索浮层 | `frontend/components/search-overlay.js` |
