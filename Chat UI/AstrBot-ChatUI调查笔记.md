# AstrBot Chat UI 调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`346b85db9d79207ea7b51694cce5276203612af4`（分支：`master`）
>
> 调查方式：从 [`../Chat/AstrBot-Chat调查笔记.md`](../Chat/AstrBot-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：项目自带的 WebChat 与管理界面；QQ、Telegram 等外部 IM 客户端的界面不归项目所有，不在本笔记范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 主要面向外部 IM 平台（QQ/Telegram/Discord/微信），这些平台客户端的聊天界面不归 AstrBot 所有。按 Chat UI 类目适用性规则，本笔记只覆盖项目自带界面：**WebChat**（webchat 平台适配器）与 **Dashboard 管理界面**。

原 Chat 调查对 UI 层的覆盖较薄：`dashboard/src/views/ChatPage.vue` 等界面组件只记录了入口位置，未逐行展开交互实现。因此本笔记以"界面清单 + 已知工作流 + 边界声明"为主，不扩写未调查的细节。

## 工作台边界与用户主链

```text
外部 IM 平台（QQ/Telegram/...）收到消息        WebChat（项目自带）收到消息
  -> AstrMessageEvent -> 流水线（请求类）        -> AstrMessageEvent -> 流水线（请求类）
  -> 结果经平台适配器发送（界面归平台）            -> 结果回传 WebChat 页面显示
```

AstrBot 的聊天主链是"事件总线 + 流水线"（执行语义在对话请求与上下文笔记），界面只是结果的一种投递表面；WebChat 与外部 IM 共享同一套事件模型（webchat 事件最后 `send(None)` 刷新 UI，scheduler.py:92-93）。

## 1. 界面清单

| 界面 | 位置 | 内容 |
|---|---|---|
| 聊天 | `views/ChatPage.vue`、`components/chat/Chat.vue`、ChatMessageList、ChatInput | 会话列表（ProjectList）、消息渲染、输入框（CommandSuggestion）、LiveMode 组件 |
| 对话管理 | `views/ConversationPage.vue` | 对话切换/删除/标题编辑 |
| 会话规则 | `views/SessionManagementPage.vue` | 按 UMO 配置 persona/provider/系统提示（session_service_config） |
| 追踪 | `views/TracePage.vue`、`components/shared/TraceDisplayer.vue` | `event.trace` 各阶段记录（含 sel_persona/astr_agent_prepare） |
| 统计 | `views/stats/StatsPage.vue` | 会话统计（token 等） |

## 2. 已知界面工作流

- 对话管理：切换/删除/标题编辑对话（`ConversationPage.vue`），对应 `switch_conversation`/删除/`new_conversation`（数据语义见会话与消息管理笔记 1.1）。
- 会话规则：按 UMO 配置 persona/provider/系统提示（`SessionManagementPage.vue`），对应 waking_check 的会话级过滤与配置。
- 追踪：`TracePage.vue` 展示 `event.trace` 各阶段记录（含 sel_persona/astr_agent_prepare），是流水线的可视化（执行语义见对话请求与上下文笔记）。

## 3. 设计取舍与已确认边界

- **外部 IM 界面不归项目所有**：QQ、Telegram、Discord、微信等客户端 UI 是第三方表面，不在 Chat UI 调查范围；项目拥有的是 WebChat（webchat 平台适配器）与 Dashboard。
- **WebChat 的交互实现未深入**：原调查只确认了组件存在与事件刷新机制，输入、发送、停止、消息操作等主链环节的界面行为未逐行核对。
- **LiveMode**：`Chat.vue` 中提及 LiveMode 组件，对应请求类的 `run_live_agent` 路径；界面细节未展开。

## 4. 未验证事项

- WebChat 页面的键盘、焦点、响应式与现场恢复行为未验证。
- 聊天页、追踪页、统计页的完整交互未逐行核对。
- Dashboard 之外是否存在其他项目自带聊天表面未确认。

## 5. 关键源码索引

- UI：`dashboard/src/views/ChatPage.vue`、`ConversationPage.vue`、`SessionManagementPage.vue`、`TracePage.vue`、`StatsPage.vue`
- WebChat 适配：`astrbot/core/platform/sources/webchat/webchat_adapter.py`
