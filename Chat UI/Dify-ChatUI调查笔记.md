# Dify Chat UI 调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读公开 chat/chatbot 页面、带历史和嵌入式聊天组件、共享 hook 及组件测试；未运行浏览器
>
> 调查范围：面向已发布应用终端用户的聊天表面；控制台的应用编辑、Provider/工具配置不在本笔记范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 的聊天 UI 是“应用运行表面”，不是整个产品的唯一工作台。`/chat/[token]` 采用带会话历史的页面，`/chatbot/[token]` 和嵌入式 Chatbot 采用较轻入口；它们复用 `base/chat` 的发送、状态机、消息树、输入表单和事件处理。应用作者在控制台预先决定模型、工具、知识库等运行配置，公开页面只显示终端用户可填写的变量/文件，不提供通用的逐回合 Provider 管理。

## 工作台与用户主链

```text
加载站点配置与输入表单
  -> 历史模式选择/新建 conversation，或嵌入模式进入当前聊天
  -> 输入 query、应用变量、文件
  -> useChat 先在本地树插入 question/answer 占位
  -> SSE 返回数据、thought、文件、workflow 事件
  -> 回填 conversation/message/task/run ID，完成后重取服务端消息
  -> 可停止、重新生成、切换 sibling；workflow 暂停时填写人工输入再恢复
```

`chat-with-history/chat-wrapper.tsx:84-222` 与 `embedded-chatbot/chat-wrapper.tsx:86-220` 都从 `useChat` 取得 `handleSend`、`handleStop`、sibling 切换、建议问题和人工输入提交能力。二者将 query、files、inputs、conversation ID 和 `parent_message_id` 交给同一服务 URL；差异在于历史侧栏和嵌入式容器/主题，而非两套独立的生成协议。

## 1. 会话导航、新建与现场恢复

带历史的 context 提供新建、启动、切换、置顶/取消置顶、删除、重命名、侧栏折叠和移动状态（`chat-with-history/context.ts:21-42`）。嵌入式 hooks 在切换会话前先调用当前实例的 `handleStop`（`embedded-chatbot/hooks.tsx:374-381`）；新建会话也停止当前生成、清空当前 ID 和消息列表，再从 URL 参数重建新会话输入（383-398 行）。这说明切换/新建的 UI 策略优先中止本地任务并清空投影，持久化历史仍由 service API 负责。

新对话完成后，hook 接收服务端返回的 conversation ID，再将其加入列表或成为当前会话。只有这一步才能确认已从临时 UI 进入可恢复会话；“新建”按钮本身不证明已落库。

## 2. Composer、变量与附件

`useChat.handleSend` 以 `response_mode: 'streaming'` 组织 body，包含 conversation ID、处理后的 files、query 与 inputs（`chat/hooks.ts:1083-1162`）。wrapper 从应用的 inputs form 获取当前或新会话变量，附件先转换为请求实体。输入并非通用富文本编辑器，也不提供聊天内直接配置模型/工具：这些受已发布应用定义约束。

首次发送前，hook 在本地树创建 question 和 answer 占位，并将 parent ID 保留在树结构中（1111-1138 行）。这是流式期间 UI 能立即显示用户输入和加载态的原因；服务端后续传入 message ID 和 conversation ID 时才回填权威身份。

## 3. 发送、流式反馈与停止

发送回调会处理文本、Agent thought、消息结束和 workflow 事件。`onData` 可回填新 conversation ID、message ID、task ID（1205-1231 行）；`onThought` 将过程条目追加给当前 answer；`onMessageEnd` 为新 Agent 会话更新 ID。普通完成后，hook 可重取服务端会话消息，以服务端内容替换局部流状态（1262-1304 行）。

`handleStop` 先清本地 responding 状态，在 task ID 存在且非暂停时才调用 stop API（527-530 行）。这给用户即时反馈，但静态代码不能证明 API 已停止模型、工具或 worker。restart 复用该停止链并重置 chat tree/建议问题（539-548 行）。

## 4. 工作流、后台运行与人工输入

workflow start 会将 workflow run ID、task ID 和 running 状态写到当前 response item（`hooks.ts:793-815,1500-1526`）。完成、暂停和 resume 不是普通文本结束：暂停时 hook 将状态改为 Paused，并按 run ID 建立工作流事件订阅（1017-1025、1767-1780 行）；带人工输入表单的消息可通过 `handleResume` 恢复（1919-1926 行）。

这确认公开聊天能把 workflow 过程与人工输入作为对话的一部分展示，但并不等于所有节点过程都在 UI 可见。多会话同时运行、离开页面后继续运行和浏览器通知行为未实测。

## 5. 消息操作、状态所有权与可用性

答案组件提供引用、suggested questions、sibling count、反馈、文件和 Agent activity 的入口；回答正文可复制并给出成功 toast，重新生成仅在仍有聊天输入或调用方显式允许时出现，feedback、annotation、TTS 与 prompt log 又受应用 feature、回调与 readonly 状态共同约束（`base/chat/chat/answer/operation.tsx:86-443`）。因此“操作栏存在”不代表所有公开应用都有相同的编辑、标注或反馈权限；完整内容呈现见消息渲染器笔记。

React hook/context 负责 draft、当前 conversation ID、responding、task ID、workflow subscription 和局部 tree；会话和消息 API 是刷新后的事实源。滚动状态另由 `useChatLayout` 保存：用户离底部超过 100px 时暂停自动跟随，输入区或窗口尺寸变化经 `ResizeObserver` 与 requestAnimationFrame 合并更新（`base/chat/chat/use-chat-layout.ts:18-174`）。这是公开阅读现场的一部分，不等同于消息搜索、跨会话定位或虚拟列表。

静态组件可确认 citation 折叠控件使用 `aria-expanded`、`aria-label` 和 focus-visible ring（`chat/citation/index.tsx:73-115`），但未运行，因此不对键盘流程、焦点归还、移动端侧栏、屏幕阅读器体验或响应式布局做结论。

## 6. 表面差异与关键路径边界

带历史页面的侧栏负责列表和会话操作；嵌入式 Chatbot 更强调容器内的新建/切换，切换时先停止当前任务。两者共享请求 hook 并不表示拥有相同的持久化、导航或发布权限。控制台调试表面也不应与已发布 WebApp 混同：它们可能复用组件，却面向不同身份和配置来源。

公开用户可见的发送前配置主要是应用定义允许填写的 inputs/files，当前代码没有把 Provider、模型、工具、知识库作为通用逐回合选择器公开给该表面。消息操作会根据消息状态显示引用、建议问题、sibling、反馈、文件或过程内容；其真实数据写入、工具语义与导出范围分别留在会话、工具和导出类目。静态组件中的 aria 标签只能证明标记存在，不能证明键盘路径、焦点恢复、移动抽屉或错误场景的实际可用性。

## 未验证事项

- 置顶、重命名、删除、新建在网络失败或多标签页中的回滚和同步。
- 输入草稿是否跨刷新/会话持久化，以及附件失败和超大文件反馈。
- workflow 后台运行、暂停恢复、停止与浏览器离开后的真实行为。
- 快捷键、焦点顺序、移动抽屉、无障碍和普通 DOM 长会话列表的实际性能。

## 关键源码索引

- `web/app/(shareLayout)/{chat,chatbot}/[token]/page.tsx`：公开入口
- `web/app/components/base/chat/chat/hooks.ts:527-1926`：发送、流、停止、workflow 和恢复状态
- `web/app/components/base/chat/{chat-with-history,embedded-chatbot}/`：会话导航、输入和嵌入式容器
- `web/app/components/base/chat/chat/answer/`：答案、操作、reasoning 与引用装配
- `web/service/share.ts`：service API 的 SSE 与 stop 调用
