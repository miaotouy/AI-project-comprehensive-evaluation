# Jan Chat UI 调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`95e96d02c58ca361a3e54cb36360ed16bc534c8a`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、zustand store、对话框与键盘处理、快捷键注册）；视觉效果、焦点顺序、键盘可用性等静态代码无法确认的项标注"未运行验证"
>
> 调查范围：线程工作台的用户工作流与界面状态：页面结构、线程列表与搜索、Composer 与附件摄取、发送/排队/流式/停止反馈、消息操作与版本导航、多会话区分、UI 状态所有权、聊天关键路径的键盘可用性；会话数据语义进入会话与消息管理类目，请求执行进入对话请求与上下文类目。按本类目"通用 UI 过滤规则"，全项目 Modal/Toast/主题盘点、设置页与托盘等非聊天主链内容不纳入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 是标准 GUI 项目：桌面/移动共用同一个 React web-app 前端（`web-app/`），仓库顶层目录未发现独立的移动端界面实现。聊天表面是一个线程页工作台：左侧栏（`LeftSidebar`）+ 线程页（`$threadId.tsx`，1863 行，线程页中枢）+ 首页新聊天（`routes/index.tsx`）。

关键工作流特征（均有源码依据，正文标注位置）：

- **Composer**（`ChatInput.tsx`，2648 行，memo 无自定义比较器）承担文本输入、附件摄取、发送与停止；发送时若正在流式则 `enqueue` 入队，队列消息以 `QueuedMessageChip` 显示在输入区顶部。
- **消息操作**：编辑（`EditMessageDialog`，Ctrl+Enter 保存）、删除（`DeleteMessageDialog` 确认）、复制、Continue（仅末条且 `metadata.stopped`）、Regenerate（仅末条）；流式态下编辑/删除禁用。
- **版本导航**：`< n/m >` 切换器渲染在**消息项**（`MessageItem.tsx:477-502`，非线程列表）；重新生成产生兄弟 sibling 并成为 active；Continue 原地续写不 fork。
- **错误反馈**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；"Increase Context Size" 手动扩容按钮。
- **现场恢复**：待发送初始消息经 `sessionStorage`（键 `initial-message-<threadId>`）恢复；活跃分支经线程 metadata 的 `activeRootId` 重建（数据侧在会话笔记）。
- 消息列表全量渲染、无窗口化（滚动锚定与渲染细节在消息渲染器笔记）。

## 工作台边界与用户主链

```text
进入 threads/$threadId（线程页中枢，$threadId.tsx 1863 行）
  -> 侧栏：NavMain（新建聊天/搜索/项目入口）+ NavChats（线程列表）+ NavProjects
  -> ChatInput 组织输入：文本、附件（图片/音频/视频/文档）、推理参数、助手/模型/工具配置
  -> 发送：isStreaming 时入队（QueuedMessageChip），否则 onSubmit -> processAndSendMessage
  -> 流式反馈（throttle 50ms 的 AI SDK 流）+ 停止按钮（队列非空时变清队列）
  -> 停止（metadata.stopped 标记）/ 错误 banner / 上下文扩容横幅
  -> 消息操作：编辑（纯文本替换）、删除、Continue（原地续写）、Regenerate（新 sibling）、版本 < n/m >
  -> 离开线程（清队列、abort 工具循环）-> 再次进入：activeRootId 恢复分支、sessionStorage 恢复待发消息
```

边界：Thread/Message 持久化形状与分支数据语义属于会话与消息管理（`../会话与消息管理/Jan-会话与消息管理调查笔记.md`）；请求组装、流式消费、队列执行、扩容与错误回写的执行语义属于对话请求与上下文（`../对话请求与上下文/Jan-对话请求与上下文调查笔记.md`）；消息部件分派、Markdown 渲染与列表滚动属于消息渲染器（`../消息渲染器/Jan-消息渲染器调查笔记.md`）。

## 1. 页面结构、导航与多窗口

- **工作台拓扑**：左侧栏 `LeftSidebar`（shadcn Sidebar，floating 变体、offcanvas 折叠）——导航区（新建聊天/搜索/项目入口，`NavMain.tsx:171-251`）+ 线程列表 + 项目列表；主区 = 顶栏（模型下拉）+ 消息区（吸附底部滚动，`role="log"` 无障碍角色，`components/ai-elements/conversation.tsx:10-18`）+ 底部 `ChatInput`（`$threadId.tsx:1676-1860`）。
- **首页新聊天**：`routes/index.tsx`——无会话状态下的大输入框（无提交处理器时创建线程并导航，`ChatInput.tsx:418-518`）；无可用 provider 时显示 `SetupScreen`。
- **临时对话**：`temporary-chat` 线程（查询参数进入），消息不落盘（数据侧在会话笔记 §1.1）。
- **多窗口**：聊天状态无跨窗口同步机制（本次未找到；检查范围：web-app chat stores 与 `services/window` 调用点——window 服务仅用于主题/扩展窗口）；多窗口并发的界面行为未运行验证。侧栏在窄屏下的抽屉化行为由 shadcn Sidebar 提供，未运行验证。

## 2. 会话列表、搜索与现场恢复

- **线程列表**（`ThreadList.tsx`，317 行）：`ThreadItem` 懒加载消息（磁盘为空不覆盖乐观写，L68-98）；项目模式下显示省略的用户消息预览（L164-168）；排序按 `updated` 降序（L297-301，数据侧在会话笔记 §5）；运行中线程显示加载图标（L159-161, L173-175）。
- **线程菜单**（L180-265）：重命名 / 添加到项目 / 移出项目 / 删除；删除项在 `What is Jan?` 且未完成 onboarding（`setup-completed` localStorage）时禁用（L253-260）。
- **批量删除**：`NavChats.tsx:49-64` 在线程数 **>1** 时挂 `DeleteAllThreadsDialog`；删除后导航回首页（`DeleteAllThreadsDialog.tsx:49-51`）。
- **重命名**：`RenameThreadDialog`（Enter 或按钮保存，无变化/空标题禁用保存；自动聚焦并全选）；数据侧 `metadata.titleSetManually=true`（会话笔记 §2.4）。
- **搜索**：`SearchDialog`（`containers/dialogs/SearchDialog.tsx`，376 行）——localStorage 最近搜索（max 5，可清空）、Fzf 结果按有无 project 分组显示、↑↓/Enter 键盘导航、选中项滚动入视口、选择后导航到线程页（`/threads/$threadId`）；快捷键打开（`KeyboardShortcuts.tsx:71-76`，`PlatformShortcuts.SEARCH`）；搜索数据实现在 `useThreads.getFilteredThreads`（会话笔记 §5）。
- **现场恢复**：进入线程页时——`activeRootId` 读线程 metadata 重建活跃分支（`$threadId.tsx:849-857`）；待发送初始消息经 `sessionStorage` 键 `initial-message-<threadId>` 恢复发送（L1145-1172，发送前即移除防重复）；分支/版本切换后的滚动定位行为未运行验证。

## 3. Composer、草稿、附件与快捷输入

- **输入区**：`ChatInput.tsx`（2648 行，`memo` 无自定义比较器）——`TextareaAutosize`（minRows 2 / maxRows 10），Enter 发送、Shift+Enter 换行（IME 合成中不触发，L1905-1917）；`autoFocus` + 挂载/切线程/流式结束自动聚焦（L543-570）。
- **输入历史**：ArrowUp/Down（光标位于行首/行尾才触发，L1919-1938）在 `usePrompt.ts`（81 行，MAX_HISTORY_SIZE=100，去空与连续重复，导航时保存草稿）。
- **附件摄取**（+ 菜单 L1967-2038，能力随模型 capabilities 显示）：
  - 图片（仅 JPEG/JPG/PNG ≤10MB，SHA-256 内容哈希去重）→ `processImageFiles` L950-1144；
  - 音频（WAV/MP3 ≤25MB，`decodeAudioDuration` 取时长）→ L1178-1265；
  - 视频（mp4/mov/webm/mkv/avi/m4v，≤100MB，Tauri 下 `convertFileSrc`+fetch 读文件）→ L1315-1399；
  - 文档（桌面端对话框，扩展名白名单长清单 + 去重 + 大小限制，L655-894），解析偏好 inline/embeddings 在发送时决策（`processAttachmentsForSend`，执行语义在对话请求笔记 §9）。
- **拖放**（L1517-1597）：`dropAcceptsAnything = hasMmproj || audioSupported || videoSupported` 才启用；逐类型分流（图片走 file-change 路径、音频/视频直接处理），拖入反馈为输入框高亮（L1748-1758）。
- **粘贴**（L1599-1724）：音频（audioSupported 时）与图片（clipboard items 传统路径 + `navigator.clipboard.read` 回退，命名 `pasted-image-<ts>.<ext>`）两路。
- **队列提示**：`QueuedMessageChip`（`containers/QueuedMessageBubble.tsx`）显示在输入区顶部（L1874-1890）——点击文本放回输入框编辑、X 移除（执行语义在对话请求笔记 §1/§8）。
- **草稿**：本次未找到独立草稿保存机制——`prompt` 只在 `usePrompt` 内存中，切线程即清；sessionStorage 只用于"首页待发送的初始消息"（标注为未找到，检查范围：usePrompt 与 ChatInput 持久化调用）。
- **语音输入**：本快照未发现（搜索 `speech`/`webkitSpeechRecognition`/`MediaRecorder`/`getUserMedia` 在 `web-app/src` 无命中）。

## 4. Agent、模型、工具与发送前配置

- **模型选择**：`DropdownModelProvider` 在 HeaderPage（线程页）与首页；无模型时发送被拦截并提示（`ChatInput.tsx:364-367`）。
- **助手切换**：`AssistantSwitcher`（助手 >1 时显示，可键盘循环切换，`AssistantSwitcher.tsx:59-68`）；线程助手是嵌入快照，本线程内选择/编辑只影响该线程（会话笔记 §1.1/§8）。
- **项目首条消息**：项目页把该项目的 assistantId 传给 Composer；创建线程时它优先于全局当前助手，因而选择器初始显示项目助手。已有线程仍按线程快照处理（`routes/project/$projectId.tsx:127-135`、`containers/ChatInput.tsx:235-242,477-496`）。
- **推理参数**：`SamplerPopover`（线程内编辑 = 快照 + canonical 镜像双写，数据侧在会话笔记 §8）；参数如何进入请求（合并顺序、`createCustomFetch` 注入）在对话请求笔记 §2/§9。
- **推理控制**：reasoning 开关（auto/on/off）与 Thinking Budget 等级（仅 llamacpp 显示 token 预算近似值，L2255-2562）；OpenAI 的 reasoning effort 独立子菜单（L2329-2413）。
- **工具与外部能力开关**：MCP 工具下拉（`DropdownToolsAvailable`/`McpExtensionToolLoader`）、web 搜索开关（高亮激活态，L2221-2247）、Jan Browser 按钮（需 vision+tools 模型，L2066-2106）、embeddings 指示（L2108-2125）。
- **Token 计数**：`TokenCounter` 按设置显示紧凑/完整形态（`shouldShowTokenCounter` 条件，L226-232）。
- **设置作用域可辨性**：模型级 `settings`（模型目录）、线程助手级 `parameters`（线程快照）——界面分层清晰【代码确认】，未运行验证。

## 5. 发送、排队、流式反馈与停止

- **发送**：发送按钮在无文本且无可发送媒体/正在摄取附件时禁用（L2597-2607）；`handleSendMessage`（L363-415）流式态入队、否则 `onSubmit`；发送链路执行语义在对话请求笔记 §1。
- **排队反馈**：`QueuedMessageChip` 于输入区顶部（§3）；`status==='ready'` 自动发下一条、`error` 或离开线程清队列（执行语义在对话请求笔记 §8）。
- **流式反馈**：AI SDK 流（throttle 50ms 只节流 UI 状态）；输入框流式态显示 MovingBorder 光环（L1736-1746）；`PromptProgress`（submitted 且非 continue 时）与"Growing the Mind..." Shimmer（continue 恢复时，`$threadId.tsx:1762-1774`）；嵌入文档处理中显示 embeddings 进度条（L1749-1761）；流式渲染（Streamdown、代码块、LaTeX）在消息渲染器笔记。
- **停止**：流式态停止按钮（L2573-2596）——**队列非空时按钮变为"清队列"**（Tooltip 文案随队列长度切换，L2594），队列空才 `stopStreaming`（`onStop` → AI SDK `stop()`，L572-583）；`metadata.stopped` 使 Continue 入口出现（执行侧在对话请求笔记 §6）。
- **错误反馈**：banner 置顶（llama.cpp OOM / GGML backend / context overflow，`$threadId.tsx:1775-1845`），隐藏最后一条失败 assistant 消息（L1703-1708）；错误挂载 effect 找最后一条 assistant 并写 `metadata.error`（执行侧在对话请求笔记 §6）；消息级错误框 + Regenerate 按钮（`MessageItem.tsx:528-555`）；banner 上 OOM 附建议清单（L1800-1807）。
- **上下文扩容**：`finishReason==='length'` 且 token ≥ 0.9×ctx_len 时横幅显示 "Increase Context Size" 按钮（L1808-1830；扩容阶梯执行语义在对话请求笔记 §3），否则横幅显示 Reload/Regenerate（L1832-1840）。

## 6. 消息操作、分支与版本导航

| 操作 | 界面入口 | 可用性条件 | 工作流要点 |
|---|---|---|---|
| 编辑 | `EditMessageDialog`（`MessageItem.tsx:566-573` user / L599-604 assistant） | 流式态禁用；无变化/空文本禁用保存 | 图片/文件保留 chips 仅对话框内展示（数据侧 makeSibling 只带文本，见会话笔记 §4）；Ctrl+Enter 保存；自动聚焦选中（L54-61） |
| 删除 | `DeleteMessageDialog`（确认框，删除按钮自动聚焦，Enter 确认） | 流式态禁用 | 数据侧 retain 整写（会话笔记 §3） |
| 复制 | `CopyButton`（user L564 / assistant L597） | 常驻 | 复制全部文本 parts |
| Continue | 播放图标按钮（`MessageItem.tsx:610-623`） | `selectedModel && !isStreaming && isLastMessage && isStopped` | 原地续写不 fork（执行侧对话请求笔记 §7） |
| Regenerate | 刷新图标按钮（`MessageItem.tsx:625-634`） | `selectedModel && !isStreaming && isLastMessage` | 兄弟新 sibling 成为 active（数据侧会话笔记 §4） |
| 版本切换 | `< n/m >` 切换器（`MessageItem.tsx:477-502`，仅 count>1 显示，边界禁用） | 常驻 | `onSwitchVersion` → `handleSwitchVersion`（`$threadId.tsx:1272-1288`）+ `setActiveBranch`/`syncActivePath`（L1236/L1259） |

- 操作区装配（user 消息靠右 L558-580、assistant 消息靠左 L583-642）与消息壳属于消息渲染器笔记，本笔记只记录"何时可用、触发什么工作流"。
- 分支树数据语义（`parentId` 树、`activeRootId`、`makeSibling`）在会话笔记 §1.4。
- 编辑/删除流式禁用的依据是 `status` 为 streaming/submitted（含 pending 工具调用，`MessageItem.tsx:151-155`）。

## 7. 多会话、多模型、群聊与后台生成

- **多线程并行**：每个线程独立 AI SDK 会话（`chat-session-store.ts` 按 sessionId 保存 Chat + transport）；侧栏运行中线程显示 Loader2 图标（§2）+ 消息区流式标记区分"哪条在跑"；banner 错误按线程隔离回读（`$threadId.tsx:893-910`）。
- **临时对话**：`temporary-chat` 线程独立运行标记（agent 模式状态按线程键控，`ChatInput.tsx:180-186`）。
- **群聊、子 Agent、后台任务**：本次未发现相关界面（搜索范围：web-app 容器与路由）——标注为未找到。
- **多窗口/多会话并发**打到同一 llama-server 的行为未验证（推测项，对话请求笔记 §8）。

## 8. Chat UI 状态所有权与同步

- **store 分工**：
  - `useThreads`：列表/排序/搜索/增删改；
  - `useMessages`：乐观写 + 异步持久化；
  - `useChatSessions`：Chat 实例与流状态；
  - `useAppState`：当前线程、busy/embedding 标记、oom/backend 错误、abort controllers；
  - `usePrompt`：草稿与历史；
  - `useMessageQueue`：per-thread 队列；
  - `useMessageErrors`：错误文本；
  - `useChatAttachments`：per-thread 附件（`NEW_THREAD_ATTACHMENT_KEY` 首页中转）；
  - `$threadId.tsx` 是仲裁中枢（数据语义在会话笔记 §2.4/§6）。
- **乐观写**：`addMessage` 先入内存再按 id 替换；ThreadItem 磁盘为空不覆盖乐观写（§2）。
- **删除清理**：`deleteThread` 级联清 session/queue/attachments/向量库 + 重建搜索索引（数据侧会话笔记 §3）；离开线程清队列（`$threadId.tsx:1654-1658`）、abort 工具循环与审批（L879-888）。
- **错误状态**：`message-errors.ts` 与 `metadata.error` 双写（对话请求笔记 §6）；banner 端配置控制呈现。
- **busy 语义**：`setThreadBusy` 覆盖工具执行与嵌入处理期间（`$threadId.tsx:475, 1009, 1045`）；`embeddingThreads` 驱动嵌入进度 UI（L1749-1761）。
- **现场恢复**：sessionStorage 初始消息（§2）；活跃分支经 `activeRootId` 恢复（§2）；每线程滚动位置在切换时的保留行为未运行验证。
- **跨窗口同步**：未找到（§1）。

## 9. 键盘、焦点、响应式与关键路径可用性

- **聊天关键路径的键盘点**【代码确认】：
  - 输入与发送：Enter 发送 / Shift+Enter 换行（§3）；
  - 输入历史：ArrowUp/Down 光标首尾触发（§3）；
  - 编辑保存：Ctrl+Enter（`EditMessageDialog.tsx:75-80`）；
  - 删除/批量删除：Enter 确认、删除按钮自动聚焦（`DeleteMessageDialog.tsx:30-34,57-60`、`DeleteThreadDialog.tsx:76-80,92-96`、`DeleteAllThreadsDialog.tsx:54-58,68-72`）；重命名：自动聚焦并全选（`RenameThreadDialog.tsx:52-60`）、Enter 保存（L81-86）；
  - 搜索：快捷键打开（`KeyboardShortcuts.tsx:71-76`），↑↓/Enter 导航选择（§2）；
  - 全局：`KeyboardShortcutsProvider`（`providers/KeyboardShortcuts.tsx`）注册切侧栏/新聊天/新项目/设置/搜索/切助手等 `PlatformShortcuts`（集中在 `lib/shortcuts.ts` 配置）；
  - 输入框自动聚焦：挂载、切线程、流式结束（`ChatInput.tsx:543-570`）。
- **消息区**：`role="log"`（`conversation.tsx:15`）。
- **焦点顺序、可访问名称、响应式行为、无障碍验证**：未运行验证（静态代码只能确认事件绑定）。
- 本快照未发现语音输入（§3）。

## 10. 设计取舍与已确认边界

- **无窗口化全量渲染**：消息列表长列表性能依赖 `MessageItem` 的自定义 memo 比较器（流式末条强制渲染，L661-680）与流式节流（渲染细节在消息渲染器笔记）。
- **流式态锁定消息操作**：编辑/删除在 streaming/submitted 禁用（§6）。
- **队列设计**：流式时入队、ready 自动发出、error 或离开清空；停止按钮在队列非空时变清队列（§5）。
- **编辑丢媒体**：编辑改写文本时数据侧丢弃图片/媒体 content，原版本保留可回退（会话笔记 §9）。
- **`resume:false`**：重启不恢复未完成回合（执行侧对话请求笔记 §10）。
- **banner 与 metadata.error 并存**：全局 banner 隐藏最后一条失败 assistant 消息，同时 error 又写 `metadata.error`——两者可能同时存在，UI 呈现交由 banner 端配置【代码确认】，行为未运行验证。
- **版本切换器位置**：`< n/m >` 在消息项操作区而非线程列表（§6）。
- **边界**：线程数据语义在会话笔记；请求执行在对话请求笔记；消息壳与操作栏装配在消息渲染器笔记。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为（含侧栏移动端抽屉化）——本笔记结论主要来自静态代码，需运行验证。
- 分支/版本切换后的滚动定位行为。
- 错误位置与 banner 并存的 UI 呈现。
- 多窗口/多会话并发行为。
- "无语音输入"结论基于源码搜索（`speech`/`webkitSpeechRecognition`/`MediaRecorder` 无命中），未运行验证。
- 模型/助手选择器、工具下拉等面板的完整交互细节未逐一展开（只记录与聊天主链的交点）。

## 12. 关键源码索引

- 线程页：`web-app/src/routes/threads/$threadId.tsx`（发送/分支/编辑/续写/扩容/错误挂载/队列消费/现场恢复）。
- 输入区：`web-app/src/containers/ChatInput.tsx`（附件摄取/拖放/粘贴/发送/停止/队列 chip）、`web-app/src/hooks/usePrompt.ts`。
- 消息操作：`web-app/src/containers/MessageItem.tsx`（操作区/Continue/Regenerate/错误框/版本切换器）、`web-app/src/containers/dialogs/EditMessageDialog.tsx`、`DeleteMessageDialog.tsx`。
- 侧栏：`web-app/src/components/left-sidebar/index.tsx`、`NavMain.tsx`、`NavChats.tsx`；`web-app/src/containers/ThreadList.tsx`；`web-app/src/containers/dialogs/SearchDialog.tsx`、`RenameThreadDialog.tsx`、`DeleteThreadDialog.tsx`、`DeleteAllThreadsDialog.tsx`。
- 快捷键：`web-app/src/providers/KeyboardShortcuts.tsx`、`web-app/src/lib/shortcuts.ts`。
- 状态：`web-app/src/stores/chat-session-store.ts`、`message-queue-store.ts`、`message-errors.ts`；`web-app/src/hooks/useChatAttachments.ts`、`useAppState.ts`。
- 附件处理：`web-app/src/lib/attachmentProcessing.ts`、`web-app/src/types/attachment.ts`。
