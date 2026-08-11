# Jan Chat UI 调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：从 [`../Chat/Jan-Chat调查笔记.md`](../Chat/Jan-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：线程工作台的用户工作流与界面状态：页面结构、线程列表与搜索、Composer 与附件摄取、发送/排队/流式/停止反馈、消息操作与版本导航、UI 状态所有权；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 是标准 GUI 项目：桌面/移动共用同一个 React web-app 前端（`web-app/`），本次未发现独立的移动端界面实现（消息渲染器笔记同样未发现独立移动端渲染器）。聊天表面是一个线程页工作台，`$threadId.tsx`（1863 行）是线程页中枢，承载分支/编辑/续写/上下文扩展全部仲裁。

关键工作流特征：

- **Composer**（`ChatInput.tsx`，2648 行，memo 但无自定义比较器）承担输入、附件摄取、发送与停止；发送时若正在流式则 `enqueue` 入队，队列消息显示在输入区顶部 `QueuedMessageChip`。
- **消息操作**：编辑（`EditMessageDialog`，Ctrl+Enter 保存）、删除（`DeleteMessageDialog`）、复制、Continue（仅末条且 `metadata.stopped`）、Regenerate（仅末条）；流式态下编辑/删除禁用。
- **版本导航**：线程列表内 `< n/m >` 切换分支版本；重新生成产生兄弟新 sibling 并成为 active；Continue 原地续写不 fork。
- **错误反馈**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；错误位置与 banner 互斥的关系未实测。
- **初始消息恢复**：`stickySessionStorage(INITIAL_MESSAGE_PREFIX + threadId)` 恢复发送。
- 消息列表全量渲染、无窗口化（滚动锚定与渲染细节在消息渲染器笔记 §1.4）。

## 工作台边界与用户主链

```text
进入 threads/$threadId（线程页中枢，$threadId.tsx 1863 行）
  -> 侧栏线程列表（排序/收藏/搜索/删除；版本导航 < n/m >）
  -> ChatInput 组织输入：文本、附件（图片/音频/视频/文档）、推理参数
  -> 发送：isStreaming 时入队（QueuedMessageChip），否则 processAndSendMessage
  -> 流式反馈（throttle 50ms 的 AI SDK 流）
  -> 停止（metadata.stopped 标记）/ 错误 banner / 上下文扩容横幅
  -> 消息操作：编辑（纯文本替换）、删除、Continue（原地续写）、Regenerate（新 sibling）
  -> 切换版本 / 离开线程（清队列）
  -> 再次进入：stickySessionStorage 恢复初始消息现场
```

边界：Thread/Message 持久化形状与分支数据语义属于会话与消息管理（`../会话与消息管理/Jan-会话与消息管理调查笔记.md`）；请求组装、流式消费、队列执行、扩容与错误回写的执行语义属于对话请求与上下文（`../对话请求与上下文/Jan-对话请求与上下文调查笔记.md`）；消息部件分派、Markdown 渲染与列表滚动属于消息渲染器（`../消息渲染器/Jan-消息渲染器调查笔记.md`）。

## 1. 页面结构、导航与多窗口

- 线程页工作台：侧栏（`ThreadList`/`NavChats`）+ 消息区（`conversation.tsx` 容器，StickToBottom 吸附底部，`role="log"` 无障碍角色，实现见消息渲染器笔记 §1.4）+ 输入区（`ChatInput`）。
- `$threadId.tsx`（1863 行）是线程页中枢：分支/编辑/续写/上下文扩展全部仲裁（`ensureBranched`/`setActiveBranch`/`syncActivePath`/`handleRegenerate`/`handleContinue`/`handleEditMessage`/`handleDeleteMessage`，L1227-1422）。
- 多窗口/多端：桌面与移动共用 web-app；多窗口并发的界面行为未验证（未验证事项）。桌面端专用窗口管理（托盘/快捷键等）不在本次调查范围（源笔记未覆盖，标注为未调查）。

## 2. 会话列表、搜索与现场恢复

- **线程列表**（`ThreadList.tsx`，317 行）：ThreadItem 懒加载消息（磁盘为空则不覆盖乐观写，L77-86）；项目模式显示省略的用户消息预览；下拉菜单=重命名/添加到项目/移出项目/删除（`What is Jan?` 且未完成 onboarding 时禁用删除，L255-259）；排序按 `update` 降序（L297-301，由 `updateThreadTimestamp` 更新，数据侧在会话与消息管理笔记 §5）。
- **收藏**：`toggleFavorite` 界面入口改顶层 `isFavorite`（数据侧在会话与消息管理笔记 §5）。
- **搜索**：`SearchDialog.tsx`（376 行）localStorage `recentSearches`（max 5），Fzf 结果按有无 project 分组，键盘导航；搜索数据实现在 `useThreads.getFilteredThreads`（会话与消息管理笔记 §5）。
- **删除确认**：删除对话框 `DeleteThreadDialog`/`DeleteAllThreadsDialog`（`NavChats` 仅显示 >=1 时挂 `<DeleteAllThreadsDialog>`）；删除的数据语义（级联清理、保留收藏与 project 线程）在会话与消息管理笔记 §3。
- **重命名**：`RenameThreadDialog`（数据侧 `metadata.titleSetManually=true`）。
- **现场恢复**：初始消息经 `stickySessionStorage(INITIAL_MESSAGE_PREFIX + threadId, {…})` 恢复发送（`$threadId.tsx` L1145-1172）；分支/版本切换时的滚动定位行为未运行验证（消息渲染器笔记 §1.4 未验证项）。

## 3. Composer、草稿、附件与快捷输入

- **输入区**：`ChatInput.tsx`（2648 行，memo 但无自定义比较器）承担 text/markdown 输入、文件上传、多模态图片、停止/继续流式。本快照**未发现语音输入**相关代码（搜索 `speech`/`voice`/`webkitSpeechRecognition` 无命中；见未验证事项）。
- **附件摄取**：
  - 图片（仅 JPEG/JPG/PNG ≤10MB，SHA-256 哈希去重）→ `processImageFiles` L950-1144；
  - 音频（WAV/MP3 ≤25MB，`decodeAudioDuration`）L1178-1265；
  - 视频（VIDEO_EXTS=mp4/mov/webm/mkv/avi/m4v，≤100MB，Tauri 经 `convertFileSrc`+fetch 读文件）L1315-1425；
  - 文档握取仅桌面端，扩展名白名单很长（pdf/docx/…/md/ts/js/sh/bash/ps1/…/cu/cuh），`processAttachmentsForSend` 决定 inline/embeddings（注入点执行语义在对话请求与上下文笔记 §2/§9）。
- **拖放**（L1519-1597）：`dropAcceptsAnything = hasMmproj || audio || video`；逐类型分流；**粘贴**（L1599-1724）：音频→`processAudioFiles`；图片走两路径（clipboard items / navigator.clipboard.read），文件命名 `pasted-image-<ts>.<ext>`。
- **输入历史**：ArrowUp/Down（光标在行首/尾才触发），历史在 `usePrompt.ts`（MAX_HISTORY_SIZE=100 去重去连续重复）。
- **队列提示**：队列消息显示在输入区顶部 `QueuedMessageChip`（队列执行语义在对话请求与上下文笔记 §1/§8）。
- **草稿**：本次调查未发现独立草稿保存机制（标注为未调查；初始消息恢复只覆盖 sticky 的待发消息）。

## 4. Agent、模型、工具与发送前配置

- 无模型时发送被拦截（`handleSendMessage` L364-366）。
- 线程内 SamplerPopover 编辑推理参数为“快照 + canonical 镜像”双写（数据语义在会话与消息管理笔记 §8）；参数如何进入请求（合并顺序、`createCustomFetch` 注入）在对话请求与上下文笔记 §2/§9。
- 线程助手是嵌入快照（`ThreadAssistantInfo`），本线程内选择/编辑助手只影响该线程（会话与消息管理笔记 §1.1/§8）；助手选择器的界面细节本次调查未覆盖（标注为未调查）。

## 5. 发送、排队、流式反馈与停止

- **发送**：`handleSendMessage`（L363-415）：`isStreaming` 时 `enqueue` 入队；否则 `onSubmit(prompt, files)`；发送链路 `processAndSendMessage` 的执行语义在对话请求与上下文笔记 §1。
- **排队反馈**：`QueuedMessageChip` 显示于输入区顶部；`status==='ready'` 自动发下一条、`error` 或离开线程清队列（执行语义在对话请求与上下文笔记 §8）。
- **流式反馈**：AI SDK `useChat` 流（throttle 50ms 只节流 UI 状态）；流式渲染（Streamdown、代码块延迟高亮、LaTeX 占位符）在消息渲染器笔记 §2。
- **停止**：ChatInput 提供停止/继续流式；`metadata.stopped` 在 `isAbort || finishReason==='length'` 时写（执行侧在对话请求与上下文笔记 §6）；Continue 按钮仅 `isLastMessage && isStopped` 显示（MessageItem L599-608）。
- **错误反馈**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；错误挂载 effect 找最后一条 assistant（无则最后用户消息）并写 `metadata.error`（执行侧在对话请求与上下文笔记 §6）；错误框 + Regenerate 按钮（MessageItem L528-555）。
- **上下文横幅**：`finishReason==='length'` 且 token ≥ 0.9×ctx_len 时提示 `"Increase Context Size"`（`$threadId.tsx` L1425+；扩容阶梯的执行语义在对话请求与上下文笔记 §3/§7）。

## 6. 消息操作、分支与版本导航

| 操作 | 界面入口 | 工作流要点 |
|---|---|---|
| 编辑 | `EditMessageDialog`（`extractFilesFromPrompt`/`injectFilesIntoPrompt`，Ctrl+Enter 保存，保存禁用当无变化/空文本） | 用户编辑同步 regenerate，assistant 编辑仅 fork 不重生成（数据语义在会话与消息管理笔记 §4） |
| 删除 | `DeleteMessageDialog` | 流式态禁用（数据语义在会话与消息管理笔记 §3） |
| 复制 | MessageItem 操作区 | — |
| Continue | 仅末条 && `metadata.stopped`（MessageItem L599-608） | 原地续写不 fork（执行语义在对话请求与上下文笔记 §7） |
| Regenerate | 仅末条 | 兄弟新 sibling，新回复成为 active（数据语义在会话与消息管理笔记 §4） |
| 版本切换 | `ThreadList` 版本导航 `< n/m >`（`handleSwitchVersion` L1272-1288） | `setActiveBranch`/`syncActivePath`（L1236/L1259） |
| 消息流式禁用 | 编辑/删除均流式态禁用 | — |

- 操作区（复制/编辑/删除/Continue/Regenerate 的按钮装配）与消息壳属于消息渲染器笔记 §1.2，本笔记记录操作何时可用与触发什么工作流。
- 分支树数据语义（`parentId` 树、`activeRootId`、`makeSibling`）在会话与消息管理笔记 §1.4。

## 7. 多会话、多模型、群聊与后台生成

- 多线程并行：每个线程独立 `useChat` 会话实例（`chat-session-store.ts` 按 sessionId 保存 Chat + transport）；同一页内“哪条仍在运行”的区分依赖 AI SDK 状态与流式标记。
- 队列跨线程隔离：离开线程清队列（`$threadId.tsx` L1654-1658）。
- 群聊、子 Agent、后台任务：本次调查未发现相关界面（标注为未调查）。
- 多窗口/多会话并发打到同一 llama-server 的行为未验证（推测项，对话请求与上下文笔记 §5）。

## 8. Chat UI 状态所有权与同步

- **三个 store 协作**：`useThreads`（线程列表/排序/搜索/增删改）、`useMessages`（乐观写 + 异步持久化）、`useChatSessions`（AI SDK 会话与流状态）；`$threadId.tsx` 是仲裁中枢（数据语义在会话与消息管理笔记 §2.4/§6）。
- **乐观写**：`addMessage` 乐观写后 `createMessage().then` 按 id 替换；ThreadItem 磁盘为空不覆盖乐观写（§2）。
- **错误状态**：`message-errors.ts` store（`message-errors.setError`）与 `metadata.error` 双写；banner 端配置控制呈现（§5）。
- **队列状态**：`message-queue-store.ts`（enqueue/dequeue）；离开线程、`error` 时清空（§5）。
- **删除时的状态清理**：`deleteThread` 级联清理 `useAgentMode`/`useChatSessions`/`useAppState.clearThreadState` + `cleanupVectorDB` + rebuild 索引（数据侧在会话与消息管理笔记 §3）。
- **现场恢复**：sticky sessionStorage 初始消息（§2）；每线程现场（活动版本、滚动位置）在切换时的保留行为未运行验证。
- 跨窗口同步：未调查（标注为未调查）。

## 9. 键盘、焦点、响应式与关键路径可用性

- **输入历史**：ArrowUp/Down（光标在行首/尾才触发，`usePrompt.ts` MAX_HISTORY_SIZE=100）——聊天关键路径的键盘可用点（§3）。
- **搜索**：SearchDialog 键盘导航（§2）。
- **编辑保存**：Ctrl+Enter 保存（§6）。
- 消息列表容器带 `role="log"` 无障碍角色（`conversation.tsx`，实现见消息渲染器笔记 §1.4）。
- 焦点顺序、无障碍名称、响应式行为需要运行验证（未验证事项）；本快照未发现语音输入（§3）。

## 10. 设计取舍与已确认边界

- **无窗口化全量渲染**：消息列表长列表性能依赖 MessageItem 的 memo 比较器与流式节流，无窗口化策略（渲染细节在消息渲染器笔记 §1.4）。
- **流式态锁定消息操作**：编辑/删除在流式期间禁用（§6）。
- **队列设计**：流式时入队、ready 自动发出、error 或离开清空（§5）。
- **编辑丢媒体**：编辑改写文本时丢弃图片/媒体 content，原版本仍保留可回退（数据语义在会话与消息管理笔记 §9-6）。
- **`resume:false`**：重启不恢复未完成回合（执行侧在对话请求与上下文笔记 §10）。
- **错误位置与 banner 互斥**：全局 banner 隐藏最后一条失败 assistant 消息，而 error 又写 metadata.error——两者可能同时存在，UI 呈现交由 banner 端配置【代码确认】，行为未实测。
- **边界**：线程数据语义在会话与消息管理笔记；请求执行在对话请求与上下文笔记；消息壳与操作栏装配在消息渲染器笔记。源笔记 §10 横向比较坐标属跨类目综合内容，保留于源文件。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为需要运行验证（本笔记结论主要来自静态代码）。
- 分支/版本切换时的滚动定位行为未验证。
- 错误位置与 banner 并存的 UI 呈现未实测。
- 多窗口并发行为未验证。
- “无语音输入”结论基于源码搜索（`speech`/`voice`/`webkitSpeechRecognition` 无命中），未运行验证。
- 模型/助手选择器、后台任务等界面未调查（源笔记未覆盖）。

## 12. 关键源码索引

- 线程页中枢：`web-app/src/routes/threads/$threadId.tsx`（发送/分支/编辑/续写/扩容/错误挂载/队列消费）。
- 输入区：`web-app/src/containers/ChatInput.tsx`（2648 行，附件摄取/拖放/粘贴/发送/停止）、`web-app/src/hooks/usePrompt.ts`（输入历史）。
- 消息操作：`web-app/src/containers/MessageItem.tsx`（操作区/Continue/Regenerate/错误框）、`web-app/src/containers/dialogs/EditMessageDialog.tsx`、`DeleteMessageDialog.tsx`。
- 线程列表：`web-app/src/containers/ThreadList.tsx`（排序/菜单/版本导航）、`SearchDialog.tsx`、`DeleteThreadDialog.tsx`/`DeleteAllThreadsDialog.tsx`、`RenameThreadDialog.tsx`。
- 状态：`web-app/src/stores/chat-session-store.ts`、`message-queue-store.ts`、`message-errors.ts`；`web-app/src/hooks/useMessages.ts`、`useThreads.ts`（界面侧读取）。
- 附件：`web-app/src/hooks/useChatAttachments.ts`、`web-app/src/lib/attachmentProcessing.ts`。
