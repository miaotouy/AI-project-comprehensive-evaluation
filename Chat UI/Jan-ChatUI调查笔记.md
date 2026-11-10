# Jan Chat UI 调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、zustand store、对话框与键盘处理、快捷键注册）；视觉效果、焦点顺序、键盘可用性等静态代码无法确认的项标注"未运行验证"
>
> 调查范围：线程工作台的用户工作流与界面状态：页面结构、线程列表与搜索、Composer 与附件摄取、发送/排队/流式/停止反馈、消息操作与版本导航、多会话区分、UI 状态所有权、聊天关键路径的键盘可用性；会话数据语义进入会话与消息管理类目，请求执行进入对话请求与上下文类目。按本类目"通用 UI 过滤规则"，全项目 Modal/Toast/主题盘点、设置页与托盘等非聊天主链内容不纳入
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 是标准 GUI 项目：桌面/移动共用同一个 React web-app 前端（`web-app/`），仓库顶层目录未发现独立的移动端界面实现。聊天表面是一个线程页工作台：左侧栏（`LeftSidebar`）+ 线程页（`$threadId.tsx`，约 2500 行，线程页中枢）+ 首页新聊天（`routes/index.tsx`）。

关键工作流特征：

- **Composer**：输入区由 `ChatInput.tsx`（约 3000 行，memo 包裹且未自定义比较器）承担文本输入、附件摄取、发送与停止。当前回合仍在流式输出时，发送动作改为把消息加入队列，排队消息以 `QueuedMessageChip` 显示在输入区顶部。
- **消息操作**：编辑（`EditMessageDialog`，Ctrl+Enter 保存）、删除（`DeleteMessageDialog` 确认）、复制、Continue（仅末条且 `metadata.stopped`）、Regenerate（仅末条）；流式态下编辑/删除禁用。
- **版本导航**：`< n/m >` 切换器渲染在**消息项**（`containers/MessageItem.tsx` 的操作区，非线程列表）；重新生成产生兄弟 sibling 并成为 active；Continue 原地续写不 fork。
- **错误反馈**：banner 置顶（OOM/backend/context），最后一条失败 assistant 消息被隐藏；"Increase Context Size" 手动扩容按钮。
- **现场恢复**：待发送初始消息经 `sessionStorage`（键 `initial-message-<threadId>`）恢复；活跃分支经线程 metadata 的 `activeRootId` 重建（数据侧在会话笔记）。
- 消息列表全量渲染、无窗口化（滚动锚定与渲染细节在消息渲染器笔记）。

## 工作台边界与用户主链

```text
进入 threads/$threadId（线程页中枢 `$threadId.tsx`）
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

- **工作台拓扑**：线程页分为左侧栏与主区。左侧栏是 shadcn Sidebar 的 floating 变体，折叠时以 offcanvas 方式收起，包含导航区（新建聊天、搜索、项目入口，`NavMain.tsx:171-251`）、线程列表与项目列表。主区自上而下为顶栏、消息区与底部输入区：顶栏放模型下拉，消息区吸附底部滚动并使用 `role="log"` 无障碍角色（`components/ai-elements/conversation.tsx`），底部输入区是 `ChatInput`，位于线程页 `$threadId.tsx` 中。
- **首页新聊天**：`routes/index.tsx`——无会话状态下的大输入框（无提交处理器时创建线程并导航，`ChatInput.tsx`）；无可用 provider 时显示 `SetupScreen`。
- **临时对话**：`temporary-chat` 线程（查询参数进入），消息不落盘（数据侧在会话笔记 §1.1）。
- **Cowork 表面**：除线程页外另有工作台式聊天面，要求模型支持工具，由会话列表、回合时间线与右侧产物预览组成。用户可编辑、重试或删除较早提问，操作截断该提问之后的记录再继续，和线程页的兄弟版本导航不同；`/compact` 保留显示时间线，只压缩模型重放历史。队列在正常完成后续发，停止或预算触限时保留，出错才清空（[cowork.tsx:1054–1117](../../jan/web-app/src/routes/cowork.tsx#L1054-L1117)、[cowork.tsx:1360–1412](../../jan/web-app/src/routes/cowork.tsx#L1360-L1412)）。执行与存储详见相邻请求/会话笔记。
- **多窗口**：聊天状态跨窗口同步本次未找到，检查范围为 web-app chat stores 与 window 服务调用点；多窗口并发行为未运行验证。侧栏的窄屏抽屉由 shadcn Sidebar 提供，视觉与焦点行为未运行验证。

## 2. 会话列表、搜索与现场恢复

- **线程列表**：列表组件 `ThreadList.tsx`（325 行）按 `updated` 字段降序排列线程，运行中的线程显示加载图标。每个线程项在需要时才加载该线程的消息，磁盘数据为空时保留内存中的乐观写入；项目模式下条目显示省略后的用户消息预览。排序与加载的数据侧语义见会话笔记 §5。
- **线程菜单**：重命名 / 添加到项目 / 移出项目 / 删除；删除项在 `What is Jan?` 且未完成 onboarding（`setup-completed` localStorage）时禁用。
- **批量删除**：`NavChats.tsx:49-64` 在线程数 **>1** 时挂 `DeleteAllThreadsDialog`；删除后导航回首页（`DeleteAllThreadsDialog.tsx:49-51`）。
- **重命名**：`RenameThreadDialog`（Enter 或按钮保存，无变化/空标题禁用保存；自动聚焦并全选）；数据侧 `metadata.titleSetManually=true`（会话笔记 §2.4）。
- **搜索**：搜索面板由 `SearchDialog`（`containers/dialogs/SearchDialog.tsx`，453 行）提供，可用快捷键打开，快捷键注册见 `KeyboardShortcuts.tsx:71-76`。面板用 localStorage 保存最近搜索词（上限 5 条，可清空）；模糊匹配结果由 Fzf 产出，按有无 project 分组显示，用 ↑↓ 移动、Enter 确认，选中项自动滚入视口，确认后导航到 `/threads/$threadId`。搜索数据由 `useThreads.getFilteredThreads` 提供（会话笔记 §5）。
- **现场恢复**：进入线程页时——`activeRootId` 读线程 metadata 重建活跃分支（`$threadId.tsx`）；待发送初始消息经 `sessionStorage` 键 `initial-message-<threadId>` 恢复发送（发送前即移除防重复）；分支/版本切换后的滚动定位行为未运行验证。

## 3. Composer、草稿、附件与快捷输入

- **输入区**：输入框是 `TextareaAutosize`，最少 2 行、最多 10 行；Enter 发送，Shift+Enter 换行，输入法合成过程中不触发发送。输入框在挂载、切换线程与流式结束时自动获得焦点。承载它的 `ChatInput.tsx` 约 3000 行，用 memo 包裹且未自定义比较器。
- **输入历史**：无选区且光标位于全文起点时按 ArrowUp、位于全文终点时按 ArrowDown，可在最近 100 条输入记录中前后翻（上限由 `MAX_HISTORY_SIZE=100` 决定）。输入法合成期间跳过历史导航，边界判断见 `ChatInput.tsx:2249-2266`。历史记录跳过空输入与连续重复项，翻动前先保存当前草稿，实现见 `usePrompt.ts`（81 行）。
- **附件摄取**（+ 菜单，能力随模型 capabilities 显示）：
  - 图片（仅 JPEG/JPG/PNG ≤10MB，SHA-256 内容哈希去重）→ `processImageFiles`；
  - 音频（WAV/MP3 ≤25MB，`decodeAudioDuration` 取时长）；
  - 视频（mp4/mov/webm/mkv/avi/m4v，≤100MB，Tauri 下 `convertFileSrc`+fetch 读文件）；
  - 文档（桌面端对话框，扩展名白名单长清单 + 去重 + 大小限制），解析偏好 inline/embeddings 在发送时决策（`processAttachmentsForSend`，执行语义在对话请求笔记 §9）。
- **拖放**：模型带多模态投影（mmproj）、支持音频或支持视频三者任一成立时，输入区才接受拖放；放下后按类型分流，图片走 file-change 路径，音频与视频直接进入处理流程，拖拽悬停时输入框高亮。
- **粘贴**：支持音频时可粘贴音频；图片先走剪贴板 items 的传统路径，取不到时回退到 `navigator.clipboard.read`，保存名形如 `pasted-image-<ts>.<ext>`。
- **队列提示**：排队中的消息以 `QueuedMessageChip` 显示在输入区顶部（实现见 `containers/QueuedMessageBubble.tsx`）；点击其中文本可把它放回输入框编辑，点 X 将其移除。队列执行语义见对话请求笔记 §1/§8。
- **草稿**：本次未找到独立的草稿保存机制。输入文本只保存在 `usePrompt` 的内存状态中，切换线程即清空；sessionStorage 仅用于保存首页待发送的初始消息。检查范围为 `usePrompt` 与 `ChatInput` 的持久化调用。
- **语音输入**：本快照未发现相关实现，搜索 `web-app/src` 中 `speech`、`webkitSpeechRecognition`、`MediaRecorder`、`getUserMedia` 均无命中。

## 4. Agent、模型、工具与发送前配置

- **模型选择**：模型下拉 `DropdownModelProvider` 由线程页的 `HeaderPage` 与首页各挂载一份；未选中模型时，发送动作被拦截并给出提示，拦截点在 `ChatInput.tsx`。
- **助手切换**：`AssistantSwitcher`（助手 >1 时显示，可键盘循环切换，`AssistantSwitcher.tsx:59-68`）；线程助手是嵌入快照，本线程内选择/编辑只影响该线程（会话笔记 §1.1/§8）。
- **项目首条消息**：项目页把该项目的 assistantId 传给 Composer；创建线程时它优先于全局当前助手，因而选择器初始显示项目助手。已有线程仍按线程快照处理（`routes/project/$projectId.tsx:127-135`、`containers/ChatInput.tsx,477-496`）。
- **推理参数**：`SamplerPopover`（线程内编辑 = 快照 + canonical 镜像双写，数据侧在会话笔记 §8）；参数如何进入请求（合并顺序、`createCustomFetch` 注入）在对话请求笔记 §2/§9。
- **推理控制**：reasoning 开关（auto/on/off）与 Thinking Budget 等级（仅 llamacpp 显示 token 预算近似值）；OpenAI 的 reasoning effort 独立子菜单。
- **工具与外部能力开关**：输入区内并列以下几类开关。
  - MCP 工具下拉，可用工具经 `DropdownToolsAvailable` 与 `McpExtensionToolLoader` 提供；
  - web 搜索开关，激活时高亮；
  - Jan Browser 按钮，仅当模型同时支持 vision 与 tools 时出现；
  - embeddings 指示。
- **Token 计数**：`TokenCounter` 按设置显示紧凑/完整形态（`shouldShowTokenCounter` 条件）。
- **设置作用域可辨性**：模型级 `settings`（模型目录）与线程助手级 `parameters`（线程快照）在界面上分层呈现【代码确认】，未运行验证。

## 5. 发送、排队、流式反馈与停止

- **发送**：没有文本、也没有可发送媒体，或附件仍在摄取时，发送按钮保持禁用。点击后由 `handleSendMessage` 判断：正在流式输出则把消息加入队列，否则走 `onSubmit` 提交。发送链路的执行语义见对话请求笔记 §1。
- **排队反馈**：排队消息以 `QueuedMessageChip` 显示在输入区顶部（§3）。当前回合状态变为 `ready` 后自动发出下一条；出现 error 或离开线程时清空队列。执行语义见对话请求笔记 §8。
- **流式反馈**：流式过程中输入框显示 MovingBorder 光环；消息区在已提交且不是 continue 回合时显示 `PromptProgress`，continue 恢复时改显示 "Growing the Mind..." Shimmer，两处挂载都在 `$threadId.tsx`。后台处理嵌入文档时另显示 embeddings 进度条。UI 状态按 50ms 节流更新，AI SDK 的流本身不受节流影响。流式渲染细节（Streamdown、代码块、LaTeX）见消息渲染器笔记。
- **停止**：流式期间停止按钮的行为取决于队列。队列非空时按钮**变为"清队列"**，Tooltip 文案随队列长度切换；队列为空才真正停止，经 `onStop` 调用 AI SDK 的 `stop()`。停止后 `metadata.stopped` 置位，Continue 入口随之出现。执行侧见对话请求笔记 §6。
- **错误反馈**：llama.cpp 内存不足、GGML backend 失败与上下文溢出三类错误以 banner 置顶显示（挂载在线程页 `$threadId.tsx`），同时隐藏最后一条失败的 assistant 消息。错误挂载 effect 定位最后一条 assistant 消息并写入 `metadata.error`，banner 上的内存不足还附建议清单；消息项内的错误框与 Regenerate 按钮由 `MessageItem.tsx` 提供。执行侧见对话请求笔记 §6。
- **上下文扩容**：回合因长度上限结束（finishReason 为 length）且已用 token 达到上下文的 0.9 倍时，横幅显示 "Increase Context Size" 按钮；未达该条件时横幅改为 Reload/Regenerate。扩容阶梯的执行语义见对话请求笔记 §3。

## 6. 消息操作、分支与版本导航

| 操作 | 界面入口 | 可用性条件 | 工作流要点 |
|---|---|---|---|
| 编辑 | `EditMessageDialog`（`MessageItem.tsx` 分别接 user 与 assistant 消息） | 流式态禁用；无变化/空文本禁用保存 | 图片/文件保留 chips 仅对话框内展示（数据侧 makeSibling 只带文本，见会话笔记 §4）；Ctrl+Enter 保存；自动聚焦选中 |
| 删除 | `DeleteMessageDialog`（确认框，删除按钮自动聚焦，Enter 确认） | 流式态禁用 | 数据侧 retain 整写（会话笔记 §3） |
| 复制 | `CopyButton`（user 与 assistant 各一处） | 常驻 | 复制全部文本 parts |
| Continue | 播放图标按钮（`MessageItem.tsx`） | `selectedModel && !isStreaming && isLastMessage && isStopped` | 原地续写不 fork（执行侧对话请求笔记 §7） |
| Regenerate | 刷新图标按钮（`MessageItem.tsx`） | `selectedModel && !isStreaming && isLastMessage` | 兄弟新 sibling 成为 active（数据侧会话笔记 §4） |
| 版本切换 | `< n/m >` 切换器（`MessageItem.tsx`，仅 count>1 显示，边界禁用） | 常驻 | `onSwitchVersion` → `handleSwitchVersion`（`$threadId.tsx`）+ `setActiveBranch`/`syncActivePath` |

- 操作区装配（user 消息靠右、assistant 消息靠左）与消息壳属于消息渲染器笔记，本笔记只记录"何时可用、触发什么工作流"。
- 分支树数据语义（`parentId` 树、`activeRootId`、`makeSibling`）在会话笔记 §1.4。
- 编辑/删除流式禁用的依据是 `status` 为 streaming/submitted（含 pending 工具调用，`MessageItem.tsx`）。

## 7. 多会话、多模型、群聊与后台生成

- **多线程并行**：每个线程独立 AI SDK 会话（`chat-session-store.ts` 按 sessionId 保存 Chat + transport）；侧栏运行中线程显示 Loader2 图标（§2）+ 消息区流式标记区分"哪条在跑"；banner 错误按线程隔离回读（`$threadId.tsx`）。
- **临时对话**：`temporary-chat` 线程独立运行标记（agent 模式状态按线程键控，`ChatInput.tsx`）。
- **子 Agent 与后台任务**：普通线程页未找到群聊或子 Agent 管理工作流；Cowork 则有子 Agent 派发/结果时间线、待回答提问与后台运行态。切换会话不终止原 session 的运行，正常完成的队列消息仍回到原 session；运行状态按 session id 区分，不能把普通 Chat 的搜索边界推广到整个 web-app（[cowork.tsx:767–812](../../jan/web-app/src/routes/cowork.tsx#L767-L812)、[cowork.tsx:1029–1070](../../jan/web-app/src/routes/cowork.tsx#L1029-L1070)）。
- **多窗口/多会话并发**打到同一 llama-server 的行为未验证（推测项，对话请求笔记 §8）。

## 8. Chat UI 状态所有权与同步

- **store 分工**：

  | store | 负责范围 |
  |---|---|
  | useThreads | 线程列表、排序、搜索与增删改 |
  | useMessages | 消息的乐观写与异步持久化 |
  | useChatSessions | Chat 实例与流状态 |
  | useAppState | 当前线程、busy/embedding 标记、oom/backend 错误、abort controllers |
  | usePrompt | 输入草稿与历史 |
  | useMessageQueue | 每线程的消息队列 |
  | useMessageErrors | 错误文本 |
  | useChatAttachments | 每线程附件（`NEW_THREAD_ATTACHMENT_KEY` 首页中转） |

  `$threadId.tsx` 是上述状态的仲裁中枢（数据语义在会话笔记 §2.4/§6）。
- **乐观写**：`addMessage` 先把消息写入内存，再按 id 替换同一条记录；线程项在磁盘数据为空时保留这份乐观写入（§2）。
- **删除清理**：`deleteThread` 级联删除会话、队列、附件与向量库中的对应记录，并重建搜索索引（数据侧见会话笔记 §3）。离开线程时清空该线程队列并中止工具循环与审批（`$threadId.tsx`）。
- **错误状态**：错误同时写入 `message-errors.ts` 维护的状态与消息的 `metadata.error`，最终呈现由 banner 端配置控制（对话请求笔记 §6）。
- **busy 语义**：工具执行与嵌入处理期间都以 `setThreadBusy` 标记线程忙碌，两处调用见 `$threadId.tsx:1009,1045`；嵌入进度 UI 由 `embeddingThreads` 驱动。
- **现场恢复**：sessionStorage 初始消息（§2）；活跃分支经 `activeRootId` 恢复（§2）；每线程滚动位置在切换时的保留行为未运行验证。
- **跨窗口同步**：未找到（§1）。

## 9. 键盘、焦点、响应式与关键路径可用性

- **聊天关键路径的键盘点**【代码确认】：
  - 输入与发送：Enter 发送 / Shift+Enter 换行（§3）；
  - 输入历史：无选区且光标位于全文起点时按 ArrowUp、位于全文终点时按 ArrowDown 翻历史（§3）；
  - 编辑保存：Ctrl+Enter（`EditMessageDialog.tsx:75-80`）；
  - 删除与批量删除：消息删除、线程删除与批量删除三个确认框都在打开时把焦点放在删除按钮上，Enter 直接确认（`DeleteMessageDialog.tsx:30-34,57-60`、`DeleteThreadDialog.tsx:76-80,92-96`、`DeleteAllThreadsDialog.tsx:54-58,68-72`）；
  - 重命名：对话框打开即自动聚焦并全选标题，Enter 保存（`RenameThreadDialog.tsx:52-60`）；
  - 搜索：快捷键打开搜索面板（`KeyboardShortcuts.tsx:71-76`），用 ↑↓ 移动、Enter 确认选择（§2）；
  - 全局：`KeyboardShortcutsProvider` 注册切换侧栏、新建聊天、新建项目、打开设置、搜索与切换助手等快捷键，配置集中在 `lib/shortcuts/` 目录（`providers/KeyboardShortcuts.tsx`）；
  - 输入框自动聚焦：挂载、切线程、流式结束（`ChatInput.tsx`）。
- **消息区**：消息流容器使用 `role="log"` 无障碍角色（`conversation.tsx`）。
- **焦点顺序、可访问名称、响应式行为、无障碍验证**：未运行验证（静态代码只能确认事件绑定）。
- 本快照未发现语音输入（§3）。

## 10. 设计取舍与已确认边界

- **无窗口化全量渲染**：消息列表长列表性能依赖 `MessageItem` 的自定义 memo 比较器（流式末条强制渲染）与流式节流（渲染细节在消息渲染器笔记）。
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
- 消息操作：`web-app/src/containers/MessageItem.tsx`（915 行）（操作区/Continue/Regenerate/错误框/版本切换器）、`web-app/src/containers/dialogs/EditMessageDialog.tsx`、`DeleteMessageDialog.tsx`。
- 侧栏：`web-app/src/components/left-sidebar/index.tsx`、`NavMain.tsx`、`NavChats.tsx`；`web-app/src/containers/ThreadList.tsx`；`web-app/src/containers/dialogs/SearchDialog.tsx`、`RenameThreadDialog.tsx`、`DeleteThreadDialog.tsx`、`DeleteAllThreadsDialog.tsx`。
- 快捷键：`web-app/src/providers/KeyboardShortcuts.tsx`、`web-app/src/lib/shortcuts/`。
- 状态：`web-app/src/stores/chat-session-store.ts`、`message-queue-store.ts`、`message-errors.ts`；`web-app/src/hooks/useChatAttachments.ts`、`useAppState.ts`。
- 附件处理：`web-app/src/lib/attachmentProcessing.ts`、`web-app/src/types/attachment.ts`。
