# Chatbox Chat UI 调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`f90fc31afd634494bdf8f074eca3e38fcf8da740`（分支：`main`）
>
> 调查方式：从 [`../Chat/Chatbox-Chat调查笔记.md`](../Chat/Chatbox-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码；通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱）保留于原 Chat 笔记，待可选界面专题承接
>
> 调查范围：工作台结构、会话导航、Composer 与草稿、发送前配置、生成反馈、消息操作、键盘与无障碍、桌面集成；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 是桌面/移动双表面的聊天工作台（Electron + Web）：

- 页面顺序固定为 `Header → MessageList → InputBox`；侧栏桌面端是常驻挤压布局，移动端是左侧滑出的临时抽屉（没有底部 Tab Bar）。
- 首页是一个"假会话"（id 固定为 `'new'`），发送前的临时状态被分散存放在三种不同的容器里；首次发送时迁移到真实 Session。
- 消息区用 `react-virtuoso` 虚拟化，并缓存每个 Session 的滚动快照（最多 100 个），切换会话不丢阅读位置。
- Thread 边界是消息列表里的内联锚点标签；Fork 是分叉点下方的"◀ 1/2 ▶"内容替换导航；两者与侧栏分组无关。
- 发送/停止按钮没有 `aria-label`，是本次调查发现的最直接的无障碍缺口。
- 桌面端全局快捷键只有"显示/隐藏窗口"，托盘不显示聊天状态，系统通知 API 未接入。

## 工作台边界与用户主链

```text
进入首页（'new' 假会话）或已有会话
  -> 侧栏选择/新建/切换会话（置顶、归档、拖放排序）
  -> InputBox 组织输入：文本、附件、模型、Copilot、知识库、网页浏览、Agent 模式
  -> 发送 -> 发送按钮变停止，生成中由 smooth-follow 跟随输出
  -> 消息操作：编辑、复制、重试、删除、分支切换（ForkNav）、Thread 定位
  -> 搜索定位（SearchDialog -> scrollToMessage）、切换会话或离开
  -> 再次进入：滚动快照恢复阅读位置
```

边界：搜索的数据扫描与索引属于会话与消息管理；流式节流落盘、工具注册与审批暂停的执行语义属于对话请求与上下文；消息内容、Markdown 与列表虚拟化的渲染实现属于消息渲染器（`../消息渲染器/Chatbox-消息渲染调查笔记.md`）。

## 1. 页面结构、导航与多窗口

### 1.1 会话页的布局与滚动策略

`routes/session/$sessionId.tsx` 的页面顺序固定为 `Header → MessageList → InputBox`，线程历史通过 `ThreadHistoryDrawer` 作为侧滑层挂载。进入会话后延迟调用 `scrollToBottom('auto')`；发送新消息前先把 `MessageList` 标记为新消息并瞬间滚到底部，生成期间由 smooth-follow 控制器跟随输出，用户手动向上滚动后会暂停跟随。`MessageList` 使用 `react-virtuoso`，并缓存每个 Session 的滚动快照（最多 100 个），切换会话不会把阅读位置丢掉。

### 1.2 侧栏：桌面常驻 / 移动端抽屉

移动端导航方式不是底部 Tab Bar，是从左侧滑出的 `SwipeableDrawer`（`Sidebar.tsx:138-158`）。`variant={isSmallScreen ? 'temporary' : 'persistent'}`——小屏幕下侧栏是"临时"的覆盖层（打开时盖住内容，点遮罩或滑动关闭），桌面端是"常驻"的挤压布局（内容区 `padding-left` 让出侧栏宽度）。`ModalProps.keepMounted: true` 保证移动端切换时 DOM 不销毁；`disableEnforceFocus: true`（避免侧栏打开时其他弹窗里的 input 无法点击）。`SwipeableDrawer` 支持从屏幕边缘滑动手势打开/关闭，阿拉伯语（RTL）时锚点切到右侧（`anchor={language === 'ar' ? 'right' : 'left'}`，`:139`）。全项目没有找到底部 Tab Bar 组件——移动端的一级导航（新建对话/图片创作/搜索/归档/关于/设置）全部收在这一个可滑出的侧栏抽屉里。

小屏判定 `useIsSmallScreen()`（`hooks/useScreenChange.ts:14-18`）是 `useMediaQuery(theme.breakpoints.down('sm'))`，即 **< 640px 判定为小屏**；`uiStore.ts:10-16` 的 `isSmallScreenViewport()` 用原始 `matchMedia('(max-width: 599.95px)')` 做初始化时的同步判断（用于 `showSidebar` 的初始值）——600px 和 640px 两个数字并不完全一致，理论上存在 600px~640px 区间首屏渲染和后续渲染判断不一致的窄缝，未核实是否有实际可观察的视觉跳变。

## 2. 会话列表、搜索与现场恢复

### 2.1 会话列表分页与分组

`SessionList.tsx` 用 Virtuoso 分页加载（`endReached` 触发 `fetchNextPage()`），置顶/普通两组通过 `SessionMetaRecord.starred` 分开。分页数据来自 IndexedDB 游标扫描（数据侧见会话与消息管理笔记 2.2）。

### 2.2 拖放排序：dnd-kit + 同组约束

用的库是 `@dnd-kit/core` + `@dnd-kit/sortable`（`SessionList.tsx:1-20`），不是 react-beautiful-dnd 或 sortablejs。三种传感器：`TouchSensor`（150ms 延迟、8px 容差）、`MouseSensor`（10px 移动阈值才激活，避免误触发拖拽）、`KeyboardSensor`（`SessionList.tsx:57-70`）。

关键约束（`SessionList.tsx:82-89`）：拖拽只在**同一个置顶分组内**生效：

```ts
if (oldIndex < 0 || newIndex < 0 || !areSessionsInSamePinGroup(activeSession, overSession)) {
  return
}
```

`areSessionsInSamePinGroup`（`shared/utils/session-sort.ts:3-8`）就是判断两者 `starred` 值是否相同。也就是说**不能靠拖拽把一个未置顶会话拖进置顶区**，必须先手动点"置顶"。

移动端有一个独立的"调整顺序模式"：普通情况下小屏幕禁止拖拽（`SessionList.tsx:71`），必须先在 `SessionItem` 的长按菜单里点"Adjust order"（`SessionItem.tsx:204-209`）进入 `isReordering` 状态，此时才出现拖拽把手图标，顶部出现一条带"Done"按钮的提示条（`SessionList.tsx:150-170`）。这是典型的 iOS 风格"进入编辑模式再拖拽"。

排序结果落地采用分数索引（数据侧见会话与消息管理笔记 2.3）。

### 2.3 会话项操作入口与归档提示

`SessionItem` 的右键/长按菜单承接置顶、改名、归档、恢复和删除；归档当前会话会先跳回首页（`router.navigate({ to: '/', replace: true })`）。归档总数超过 `ARCHIVED_SESSION_CLEANUP_THRESHOLD = 600`（`SessionItem.tsx:24`）时弹确认框建议去 Settings 清理；否则最多每 24 小时（`ARCHIVE_TIP_INTERVAL`）弹一次"已归档，去设置管理"的 toast（带 CTA，跳转设置页）。

### 2.4 消息搜索与定位

`pages/SearchDialog.tsx:50-65` 提供"当前会话"和"全部会话"两个入口；搜索结果项点击后会切换目标会话，并调用 `scrollActions.scrollToMessage`（`SearchDialog.tsx:168-203`）定位到具体消息。跨会话搜索按页读取并逐条扫描的实现见会话与消息管理笔记 5。

## 3. Composer、草稿、附件与快捷输入

### 3.1 首页 "new" 临时会话：三种状态容器

`src/renderer/routes/index.tsx:83-86`：

```ts
const [session, setSession] = useState<Session>({
  id: 'new',
  ...initEmptyChatSession(),
})
```

`session` 是纯本地 React state，`id` 硬编码为字符串 `'new'`（不是 uuid）。`model`（provider/modelId）、`copilotId`、`name`、`messages`（copilot 的 system prompt）、`assistantAvatarKey`/`picUrl`/`backgroundImage` 全部存在这个 state 里，**不落地任何 store**。

`InputBox.tsx` 通过 `isNewSession = currentSessionId === 'new'`（`InputBox.tsx:233-234`）判断分支，但不同类型的"待发送状态"实际上被分散存放在三种不同的容器里：

1. **本地组件 state**（仅 `routes/index.tsx` 内）：模型选择、copilotId、name、messages、头像。
2. **专用临时对象 `newSessionState`**（`uiStore.ts:40-47`）：

   ```ts
   newSessionState: {
     knowledgeBase?: Pick<KnowledgeBase, 'id' | 'name'>
     webBrowsing?: boolean          // 类型里声明了，但实际未被写入/读取（见下）
     workingDirectories?: string[]
     agentFullAccess?: boolean
   }
   ```

   `useKnowledgeBase({ isNewSession })`（`hooks/useKnowledgeBase.ts:16-20`）对新会话读写的是 `newSessionState.knowledgeBase`，而不是通用的 `sessionKnowledgeBaseMap['new']`。

3. **通用的"按 sessionId 映射"Map，直接复用字符串 `'new'` 当 key**：
   - `sessionWebBrowsingMap: Record<string, boolean|undefined>`（`uiStore.ts:36`），`InputBox.tsx:242`：`sessionWebBrowsingMap[currentSessionId || 'new']`。
   - `sessionAgentModeMap: Record<string, AgentModeEntry>`（`uiStore.ts:60`），读取见 `stores/session/agent-mode.ts:23-26`（`legacyMap[sessionId]`，`sessionId` 传入的就是 `'new'`）。

也就是说，`newSessionState.webBrowsing` 这个字段在类型定义里存在，但网页浏览的真实临时值走的是 `sessionWebBrowsingMap['new']`，两者是两套并行机制——`newSessionState.webBrowsing` 看起来是**未被使用的死字段**（grep 未发现任何 `newSessionState.webBrowsing` 的写入点，仅类型声明）。这是一处具体的实现细节/技术债。

首次发送时的迁移逻辑（`createPersistedChatSession`）的数据语义见会话与消息管理笔记 3.1；"首页输入框"和真实会话输入框呈现相同，但生命周期不同。

### 3.2 输入快捷操作

发送键可配置 Enter、Ctrl/Cmd+Enter、Ctrl+Enter、Command+Enter、Shift+Enter 或 Ctrl+Shift+Enter，另有"发送但不生成回复"。空输入（或全文选中）时 ArrowUp/Down 浏览输入历史；技能补全弹窗用 ArrowUp/Down 选择、Enter/Tab 确认、Escape 关闭。Escape 普通输入时阻止浏览器恢复 defaultValue 并让输入框失焦。

### 3.3 附件拖入：没有视觉反馈

`InputBox.tsx:1268-1281` 用 `react-dropzone` 的 `useDropzone` 实现拖拽上传，`getRootProps()` 直接铺在整个输入区容器上（`InputBox.tsx:1340`）。**但只解构了 `getRootProps`/`getInputProps`，没有解构 `isDragActive`/`isDragAccept`/`isDragReject`**——grep 全文确认这三个状态字段在 `InputBox.tsx` 里完全没有被使用。也就是说，用户把文件拖到输入区上方悬停时，**没有任何高亮遮罩、虚线边框或文案提示**"松手可上传"，唯一的反馈是松手瞬间文件立刻被处理（成功则出现在附件预览区，被拒绝的文件类型才通过 `toastActions.add` 弹一条"不支持的文件类型"提示，`InputBox.tsx:1274`）。这是一个具体的、可复现的交互缺口：拖拽全程用户得不到"目标区域已识别"的即时反馈。

对比之下，会话列表拖拽排序（dnd-kit）有完整的视觉反馈体系（`DragOverlay`、把手图标、编辑模式提示条），输入区文件拖拽在这方面明显更简陋。

## 4. Agent、模型、工具与发送前配置

输入工具栏提供附件、网页搜索、推理级别、Agent Mode、知识库/技能、新建或回滚 Thread、会话设置、Token/上下文窗口和模型选择。`ModelSelectorV2` 可直接切换 provider/model；Agent Mode 可在 Chat/Agent 间切换，并按模型能力显示执行设备、工作目录、审批模式和 Git/Worktree 控件。生成时发送按钮变为停止。

网页浏览开关的默认值规则：如果该会话没有显式设置过，ChatboxAI provider 默认开、其他 provider 默认关（`InputBox.tsx:241-248`）；这些开关最终以工具注册的方式进入请求（执行语义见对话请求与上下文笔记 9）。

## 5. 发送、排队、流式反馈与停止

- **提交顺序**：`onSubmit` 先更新 UI 滚动状态，再调用 `submitNewUserMessage`；若当前存在 `generating` 消息，停止按钮调用其 `cancel()` 并把该消息以 `generating:false` 乐观写回。
- **生成中占位**：`Message.tsx:946-955` 在 `msg.generating && contentParts.length === 0` 时渲染一个自定义 `Loading` 组件（`components/icons/Loading.tsx`），是手写的纯 SVG 动画——四个圆点用 SVG `<animate>` 标签分别做 `cy`/`opacity`/`r` 三个属性的关键帧动画，`dur="1.25s"`，四个点依次 `begin` 延迟 `0s/0.2s/0.4s/0.6s`，形成"依次跳动"的等待指示器。
- **工具调用等待中**：`MessageLoading.tsx` 提供 `MessageStatuses`/`PreparingToolCallStatus`（`Message.tsx:97` 引入），用于区分"纯文本生成中"和"准备/等待工具调用"两种状态展示。
- **会话列表加载**：只有"翻页加载中"的转圈图标（`SessionListLoadingFooter`），没有找到"会话列表完全为空"时的专门空状态组件——grep 未发现 `SessionList.tsx` 或其父组件里有对 `sessions.length === 0` 的特殊分支处理；新用户首次打开时列表为空，视觉上就是一片空白侧栏，没有引导文案或插图。
- **网络请求失败**：走消息级的 `MessageErrTips.tsx`，会根据 HTTP 状态码查一张 `httpStatusCodeI18nKeys` 映射表（`MessageErrTips.tsx:49-58`，覆盖 401/403/408/429/500/502/503/504）给出可读文案，还专门检测了错误内容是不是网关返回的原始 HTML 页面（`isHtmlContent`，`:40-43`）以避免把一整页 HTML 源码糊给用户看。

## 6. 消息操作、分支与版本导航

### 6.1 消息操作栏

`Message.tsx` 的操作栏按角色显示：助手"再次回复/重试"，用户"在下方继续回复"；两者可编辑、复制、引用、删除、打开更多菜单。助手生成中可停止，图片会话可"在下方生成更多图片"，移动端助手可举报；可恢复工具错误会让用户选择重试整条消息或从最后工具步骤重试。开发环境的更多菜单可查看原始 JSON。`Message` 组件的编辑、复制、重试、删除、分支切换等动作通过 `sessionActions` 写回 store，而不是直接修改 DOM。

### 6.2 Thread、Fork 的界面呈现

`MessageList.tsx` 将最新一轮 user+assistant 合成一个渲染 item，其余消息逐条渲染；消息顶部可插入 ThreadLabel，Fork 在分叉点下显示 `ForkNav`，摘要和跨会话来源分别由 `SummaryMessage`、`ForkMarkerMessage` 专用组件呈现（这些组件的内容渲染归消息渲染器，这里记录导航工作流）：

- **Thread 边界**：`renderMessageBlock`（`MessageList.tsx:428-472`）在渲染每条消息前检查 `currentThreadHash[msg.id]`，命中就在该消息上方插入一个 `ThreadLabel`（`MessageList.tsx:679-755`）——thread 边界是消息列表里的一个内联锚点标签（"# threadName"，可点开菜单编辑名字/在抽屉里定位/继续这个 thread/移到独立会话/删除），和侧栏完全无关。`ThreadHistoryDrawer.tsx` 提供的是当前会话内所有 thread 的一个侧滑抽屉列表，作用域也仅限"这一个 Session"。
- **Fork 导航**：`ForkNav`（`MessageList.tsx:613-673`）：分叉点消息下方一个"◀ 1/2 ▶"控件，点左右箭头切换分支内容，是**同一条消息位置上的内容替换**，不产生新的侧栏条目，也不是 thread。
- **桌面端还有** `MessageMinimapRail`、上一条/下一条用户消息导航和"回到底部"按钮，移动端会隐藏 minimap 以节省空间。

### 6.3 右键/上下文菜单：桌面端根本没有右键菜单

这是一个和直觉相反的发现：`SessionItem.tsx:181-186` 的 `handleContextMenu` 明确写着：

```ts
const handleContextMenu = (event: MouseEvent) => {
  if (!isSmallScreen) {
    return
  }
  event.preventDefault()
}
```

**桌面端（非小屏）完全不处理 `contextmenu` 事件**，只在小屏幕上 `preventDefault()` 阻止系统默认菜单弹出（防止手机长按弹出"分享图片"之类的原生菜单干扰长按手势）。桌面端唯一能触发的"更多操作"入口是 hover 时显现的两个小图标按钮（置顶、归档，`SessionItem.tsx:273-315`），**没有右键菜单**，改名/删除等操作要通过打开会话后进入 `SessionSettings` 弹窗完成。

移动端（`isSmallScreen`）的"菜单"其实是**长按触发的 `ActionMenu`**（`SessionItem.tsx:319-335`，配合自制长按计时器，`MOBILE_LONG_PRESS_DELAY = 550ms`、移动容差 `10px`），长按成功会触发一次原生震动反馈（`triggerLongPressHaptic`，桌面浏览器走 `navigator.vibrate?.(10)`，移动 App 走 Capacitor 的 `Haptics.impact`）。这个"菜单"底层是 Mantine `Popover`（`ActionMenu.tsx:112-197` 的 `ContextualActionMenu`），不是浏览器原生 `contextmenu` 事件驱动。

`Message.tsx` 全文 grep **没有找到 `onContextMenu`**——消息气泡没有右键菜单，所有消息操作都是操作栏上的常驻/hover 按钮，不支持右键唤出。

## 7. 多会话、多模型、群聊与后台生成

- 多模型并行在输入区以"快速模型/Agent 配置"的形式呈现（第 4 节），同一会话内多模型如何并行生成未在本类目调查范围内确认。
- 群聊、子 Agent、后台任务的界面区分本次未调查。

## 8. Chat UI 状态所有权与同步

- **状态分散风险**："new" 临时状态分散在三种不同容器里（本地 state / `newSessionState` 专用对象 / 通用 map 复用字符串 `'new'` 作 key），且 `newSessionState.webBrowsing` 字段疑似完全未被使用（3.1）。给后续新增"发送前可配置项"的开发者增加了选错容器、忘记迁移的风险。
- **滚动位置**：每个 Session 的滚动快照缓存最多 100 个，切换会话不丢阅读位置（1.1）。
- **桌面端集成（Electron）**：
  - 全局快捷键：`main.ts:259-274` 的 `registerShortcuts` 只注册了**一个**全局快捷键——`shortcutSetting.quickToggle`，绑定到 `showOrHideWindow()`（显示/隐藏主窗口）。没有找到"新建会话""发送最近一条消息"之类更细粒度的全局快捷键。
  - 系统托盘（`main.ts:280-324`）：按平台选择不同图标，右键菜单只有"Show/Hide"和"Exit"两项，双击托盘图标也触发 `showOrHideWindow`。托盘图标本身**不显示未读消息数、生成状态等聊天相关的动态徽标**。
  - 系统级 Notification API 未接入：全代码库 grep `"new Notification("` 无匹配，Electron 主进程也没有引入 `Notification` 模块。即"某条消息生成完成""工具调用需要审批"等场景**不会弹出系统通知**。
  - 窗口显示/隐藏事件双向打通：`main.ts:501,515` 在窗口显示时发送 IPC `window-show` 给渲染进程；`useShortcut.tsx:49-56` 监听 `platform.onWindowShow`/`onWindowFocused`，窗口显示或聚焦时自动 `dom.focusMessageInput()`（仅大屏幕）——这是唯一的"桌面事件 → 聊天 UI 反应"联动。

## 9. 键盘、焦点、响应式与关键路径可用性

### 9.1 无障碍

- **发送/停止按钮完全没有 `aria-label`**：`InputBox.tsx:1404-1451` 的发送/停止 `ActionIcon`（`onClick={generating ? onStopGenerating : handleSubmit}`）只用图标区分状态（`IconPlayerStopFilled`/`IconArrowUp`），**没有 `aria-label`、没有 `Tooltip` 包裹、没有 `title` 属性**——屏幕阅读器用户点到这个按钮时得不到任何文字描述，这是本次调查里发现的最直接的无障碍缺口证据。
- **模型选择器有 `Tooltip`，但触发元素本身没有 `aria-label`**：`InputBox.tsx:1834-1867` 的 `ModelSelectorV2` 触发按钮（`UnstyledButton`）没有 `aria-label`，视觉上靠内部 `<Text>` 文案传达当前模型名，对屏幕阅读器不算严重问题（有文本内容可读），但下拉箭头图标 `IconChevronRight` 同样没有 `aria-hidden`。`ModelSelectorV2` 内部的行项组件（`ModelRow.tsx:69,101,109,115,132`）反而做得更完整：视觉能力图标（Vision/Reasoning）、收藏按钮都有 `aria-label`。
- **`trapFocus={false}` 的四个弹窗**（`MessageEdit`、`SessionSettings`、`CopilotDetailModal`、`CopilotSettingsModal`）打开时键盘 Tab 键可以聚焦到弹窗背后的页面元素——这是 git log 可查证的、有意为之的修复（`2930c21d`，为解决 iOS Safari 里 Modal 内文本框无法长按选中文字的问题），但客观上牺牲了这四个弹窗的键盘可达性边界，是一个真实存在、有代码证据、且项目方明知取舍的无障碍缺口。
- **做得相对完整的反例**：`MessageMinimapRail.tsx:250-263` 的消息跳转导航用真实的 `<button type="button">` 元素、`aria-label={jumpLabel}`（"Jump to message N"）、`focus-visible:ring-1` 可见焦点环，装饰性的圆点用 `aria-hidden="true"`（`:265`）正确隔离；`ModelRow.tsx`、`SessionItem.tsx:276,297`、`SessionList.tsx:264`（拖拽把手）、`ForkMarkerMessage.tsx:45` 等处的图标按钮也都补了 `aria-label`。也就是说项目里**存在无障碍意识**，但覆盖不均——发送/停止这个全应用最高频的交互点恰恰是缺失的。
- **Tab 顺序**：未系统性测试（需要实机/自动化工具验证，本次仅代码静态阅读），但从 DOM 结构看没有发现人为的 `tabIndex` 乱序设置；`trapFocus={false}` 造成的"跳出弹窗"是唯一从代码里能直接证实的 Tab 顺序问题。

### 9.2 快捷键面板

全文 grep 快捷键相关的帮助浮层触发方式（`?` 键监听、`ShortcutsHelp`、`KeyboardShortcutsModal` 等命名）**均无匹配**。`useShortcut.tsx`（`hooks/useShortcut.tsx:65-133`）里的 `keyboardShortcut` 函数处理了一批硬编码的快捷键（聚焦输入框、切换网页浏览、新建会话、新建 Thread、新建图片会话、Ctrl+Tab 切换会话、Ctrl+数字跳转会话、Ctrl+K 打开搜索、Ctrl+, 打开设置），**没有对应的"按 `?` 展示这份清单"的浮层**，唯一能看到快捷键说明的地方是设置页面里的静态列表 `routes/settings/hotkeys.tsx` → `components/Shortcut.tsx`。用户需要主动打开设置才能看到/修改快捷键，不存在按需呼出的浮层式帮助。

## 10. 设计取舍与已确认边界

- **"new" 临时状态分散**在三种容器里，且 `newSessionState.webBrowsing` 是死字段（3.1）。
- **拖拽排序被限制在同一置顶分组内**（`areSessionsInSamePinGroup`），不能靠拖拽把未置顶会话直接拖进置顶区（2.2）。
- **`localStorage.removeItem('new-chat')`**（`routes/index.tsx:336`）在本次阅读范围内找不到对应的写入点——未核实其用途，可能是遗留代码。
- **桌面端无右键菜单、无系统通知、无托盘状态徽标**：桌面集成与聊天状态联动最少（8）。
- **类目边界**：本笔记只记录用户工作流与界面状态；Thread/Fork 的数据模型在会话与消息管理笔记 1，流式节流与工具注入在对话请求与上下文笔记 5/9，消息壳与 Markdown 渲染在消息渲染器笔记。原 Chat 笔记中的通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、openAboutDialog 死状态）保留在 `../Chat/Chatbox-Chat调查笔记.md`，待可选界面专题承接。

### 10.1 弹窗与通知交点（通用组件只记录与聊天主链的交点）

- **聊天相关弹窗**：`MessageEdit`（消息编辑）、`ThreadNameEdit`（thread 命名）、`SessionSettings`、`ClearSessionList`（清空会话列表）、`ExportChat`（导出）、`ConfirmModal`（删除/归档确认）等聊天工作流弹窗走项目统一的 `AdaptiveModal`（桌面 Mantine Modal / 移动端 vaul 抽屉二选一）与 `NiceModal` Promise 式调用；其中 `MessageEdit`、`SessionSettings` 设置了 `trapFocus={false}`，键盘 Tab 可跳出弹窗（无障碍影响见 9.1）。Esc 关闭采用自制"只有栈顶弹窗响应 Esc"方案（`useOverlayManager` 维护全局 overlayStack）。完整弹窗库盘点保留于原 Chat 笔记 13.1。
- **通知/Toast 交点**：聊天主流程的提示（消息复制、附件重试排队、发送出错、不支持的文件类型、归档提示）走 `toastActions` + MUI Snackbar（右上角，多条同时存在时无堆叠错位逻辑）；归档提示带 CTA 可跳转设置页（duration 8000）。Settings 内部的 sonner 提示系统与聊天主链无关。两套系统的完整盘点保留于原 Chat 笔记 13.2。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为、系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 600px~640px 断点窄缝是否有实际可观察的视觉跳变未核实（1.2）。
- `'new-chat'` localStorage key 的写入点未找到（10）。

## 12. 关键源码索引

- `src/renderer/routes/index.tsx`（首页/临时会话）
- `src/renderer/routes/session/$sessionId.tsx`（会话页布局与滚动）
- `src/renderer/components/session/SessionList.tsx`、`SessionItem.tsx`、`ThreadHistoryDrawer.tsx`
- `src/renderer/components/chat/MessageList.tsx`（ThreadLabel、ForkNav、MinimapRail）
- `src/renderer/components/InputBox/InputBox.tsx`（Composer、发送/停止、模型选择、拖拽上传）
- `src/renderer/hooks/useScreenChange.ts`、`useShortcut.tsx`、`useKnowledgeBase.ts`
- `src/renderer/stores/uiStore.ts`（`newSessionState`、各 sessionId-keyed map）
- `src/renderer/pages/SearchDialog.tsx`（搜索入口与定位）
- `src/renderer/Sidebar.tsx`（SwipeableDrawer 移动端导航）
- `src/renderer/components/ActionMenu.tsx`（长按菜单）
- `src/renderer/components/icons/Loading.tsx`、`components/chat/MessageLoading.tsx`、`MessageErrTips.tsx`
- `src/main/main.ts`、`src/renderer/platform/desktop_platform.ts`（桌面集成）

