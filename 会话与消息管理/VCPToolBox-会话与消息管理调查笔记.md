# VCPToolBox 会话与消息管理调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`c4c4d00b84202ec97f99c225b34014206aca8eea`（分支：`main`）
>
> 调查方式：从 [`../Chat/VCPToolBox-Chat调查笔记.md`](../Chat/VCPToolBox-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：会话与消息是否拥有事实源；结论是 VCPToolBox 不拥有跨请求会话状态，本文只记录边界与排除证据
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox **不拥有会话事实源**。它是一个无会话归属的请求级消息编排器：调用方提交一份 `messages`，服务端在内存中复制、重排、展开、注入和裁剪，形成发给模型的请求；会话 ID、历史数组和最终展示状态仍由外部前端负责。按本类目调查目标，不为形式完整虚构 Session 或消息数据库。

## 系统边界与排除证据

- **没有会话/消息持久化**：`finalContextStore` 是调试快照，不是历史数据库；`CHAT_LOG_ENABLED` 打开时写入的 `DebugLog/chat/YYYY-MM-DD/` 是可选审计文件，不是前端会话存储（默认关闭，不构成会话持久化）。外部 VCPChat、OpenWebUI 或其他客户端必须自行保存并在下一次请求中重新提交历史。
- **没有会话 CRUD**：`server.js` 暴露的对话相关端点全部是纯 API（`/v1/chat/completions`、`/v1/chatvcp/completions`、`/v1/human/tool`、protocolBridge），没有会话列表、消息编辑/删除/分支或跨请求恢复能力。
- **消息数组是请求体的一部分**：`ChatCompletionHandler.handle()` 对入站 body 原地处理，随后把最终消息写回 `originalBody.messages`（`modules/chatCompletionHandler.js:712-729`, `809-829`, `1123-1148`）——即消息的"存储"责任在客户端，服务端只负责本次请求的编排（编排细节见对话请求与上下文笔记）。

## 未验证事项

- 未运行真实上游模型，没有对每个插件组合下的最终消息数组做运行时快照（属于请求侧未验证项，此处不重复）。

## 关键源码索引

- `modules/finalContextStore.js`、`modules/chatCompletionHandler.js:1142`（调试快照写入点）
- `server.js`（478-499 行 ChatLog 开关、1206/1220/1235/1239 行聊天相关端点）
- `README.md`（17 行定位自述）
