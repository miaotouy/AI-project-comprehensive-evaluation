# Manifold Desktop Chat 概览

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

> 迁移状态（2026-08-11）：本文件已压缩为概览。内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md`](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)（数据模型、持久化缺口、搜索导入导出与路径校验）
> - 对话请求与上下文：[`../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md`](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)（消息构建、Provider 交接、流式广播、取消与并发）
> - Chat UI：[`../Chat UI/Manifold-Desktop-ChatUI调查笔记.md`](<../Chat UI/Manifold-Desktop-ChatUI调查笔记.md>)（标签工作台、会话侧栏、搜索浮层、流式反馈与错误重试工作流）
> - 消息渲染：[`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`](../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md)（已有独立笔记）
>
> 2026-08-11 本文件已压缩为概览

## 结论摘要

Manifold Desktop 的 Chat 是一套较薄的“标签页内存状态 + WebView2 消息桥 + C++ 文件存储”实现，聊天主链尚未完全接通，存在四个直接影响基本会话行为的问题：新对话不持久化（关闭标签即丢失）；assistant 流式回复只进 DOM 不回写 `messages[]`（第二轮请求缺少上一轮 assistant 上下文）；`CHAT_CHUNK`/`CHAT_DONE` 无会话标识（所有打开的标签监听同一广播）；侧栏重命名按整份 JSON 覆盖会话文件，会清空已有消息。

## 产品表面与系统边界

- 桌面 GUI（chat/compare/terminal 多标签），前端为 WebView2；模型推理经 C++ `Provider::StreamChat`（WinHTTP）调外部 Provider。
- 会话文件 `%LOCALAPPDATA%\Manifold\sessions\<id>.json` 由 `SessionManager` 管理，但正常聊天流程没有接入保存/加载（`session-store.js` 是未接入的前端仓库）。

## 端到端聊天主链

```text
input-bar -> chat-tab 本地 messages[]（含上轮 user）
  -> CHAT_SEND（整个数组 + provider/model/systemPrompt/temperature）
  -> MainWindow::HandleChatSend（MainWindow.xaml.cpp:757-841）
  -> Provider::StreamChat（WinHTTP 流式）
  -> CHAT_CHUNK / CHAT_DONE 广播
  -> chat-tab 更新 DOM（streamingText 只进 DOM，不回写 messages[]）
```

## 核心对象与状态权威

- `chat-tab.js` 组件局部 `messages[]` 与 `streamingText` 是可见视图权威；后端 `SessionManager`/`SessionPath(id)` 是文件层权威。
- 主进程只有一个 `m_chatThread`：新请求先停止旧线程（全局 stop，`MainWindow.xaml.cpp:792-795`）；取消依赖 `stop_token`，不能主动中断已阻塞的 `WinHttpReadData`。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md`](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md`](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/Manifold-Desktop-ChatUI调查笔记.md>`](<../Chat UI/Manifold-Desktop-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`](../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- 支持：会话文件增删改查与全文搜索（逐文件整份 JSON 子串、无索引无上限）、JSON 导入导出与 Markdown 导出、多标签（chat/compare/terminal）。
- 已确认缺口：无上下文截断/压缩/token 预算；无附件/记忆注入点；错误行 Retry 按钮不重发请求；流式每 chunk 无条件滚底；`SessionPath` 对导入/桥消息 id 无路径成分校验；`updateModelMessage` 期望 `role==="model"` 与其他路径的 `assistant` 不一致。

## 未验证事项

- 多标签串流、取消延迟、路径穿越与导入恶意会话均未做动态验证；上述缺口来自静态调用点搜索。

## 关键源码索引

- 标签与发送编排：`frontend/app.js`；`frontend/components/chat-tab.js`（流式与局部状态）
- 未接入的会话前端仓库：`frontend/services/session-store.js`；侧栏：`frontend/components/side-panel.js`
- 文件存储：`Manifold.Core/SessionManager.cpp`；桥 handler：`MainWindow.xaml.cpp:508-850`
