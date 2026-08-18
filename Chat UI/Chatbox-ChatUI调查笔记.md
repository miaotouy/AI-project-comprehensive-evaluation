# Chatbox Chat UI 调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、renderer store、Electron 主进程），符号与行号对照当前 HEAD 逐一核实；静态代码只确认入口、状态与事件绑定，未运行验证
>
> 调查范围：工作台结构、会话导航、Composer 与草稿、发送前配置、生成反馈、消息操作、键盘与桌面集成；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目；通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱）不纳入本文
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 是桌面/移动双表面的聊天工作台（Electron + Web）：

- 页面顺序固定为 `Header → MessageList → InputBox`；侧栏桌面端是常驻挤压布局，移动端是左侧滑出的临时抽屉（没有底部 Tab Bar）。
- 首页是一个"假会话"（id 固定为 `'new'`），发送前的临时状态被分散存放在三种不同的容器里；首次发送时转入真实 Session。
- 消息区用 `react-virtuoso` 虚拟化，并缓存每个 Session 的滚动快照（最多 100 个），切换会话不丢阅读位置；流式跟随由自研 smooth-follow 控制器接管。
- Thread 边界是消息列表里的内联锚点标签；Fork 是分叉点下方的折叠分支组（`ForkGroup`，含 N/M 位置切换），替代回复不再以独立导航条平铺；两者与侧栏分组无关。
- 发送/停止按钮本身没有 `aria-label`（生成态外包了一层 Tooltip 显示 "Stop"），是最直接的无障碍缺口。
- 桌面端全局快捷键只有"显示/隐藏窗口"，托盘不显示聊天状态，系统通知 API 未接入（`new Notification(` 全仓库无匹配）。
- 草稿按会话粒度存 localStorage：首页假会话用固定 key `'new-chat'`，真实会话用 `draft-${sessionId}`（300ms 防抖）；发送成功后清除。
- 网页浏览开关经 uiStore 的 persist 中间件持久化（跨重启保留），知识库与 Agent 模式开关不持久化（重启丢失）。

## 工作台边界与用户主链

```text
进入首页（'new' 假会话）或已有会话
  -> 侧栏选择/新建/切换会话（置顶、归档、拖放排序、长按菜单）
  -> InputBox 组织输入：文本、附件、模型、Copilot、知识库、网页浏览、Agent 模式
  -> 发送 -> 发送按钮变停止，生成中由 smooth-follow 跟随输出
  -> 消息操作：编辑、复制、重试、删除、分支切换（ForkGroup）、Thread 定位
  -> 搜索定位（SearchDialog -> scrollToMessage）、切换会话或离开
  -> 再次进入：滚动快照恢复阅读位置
```

边界：搜索的数据扫描与索引属于会话与消息管理；流式节流落盘、工具注册与审批暂停的执行语义属于对话请求与上下文；消息内容、Markdown 与列表虚拟化的渲染实现属于消息渲染器（`../消息渲染器/Chatbox-消息渲染调查笔记.md`）。

## 1. 页面结构、导航与多窗口

### 1.1 会话页的布局与滚动策略

会话页（`routes/session/$sessionId.tsx`）的页面顺序固定为顶栏 → 消息列表 → 输入框，线程历史通过 `ThreadHistoryDrawer` 作为侧滑层挂载。进入会话后延迟调用一次"回到底部"滚动；发送新消息前先把消息列表标记为新消息并瞬间滚到底部（onSubmit 内，:189-201），生成期间由 smooth-follow 控制器跟随输出，用户手动向上滚动后会暂停跟随。

`MessageList` 使用 `react-virtuoso` 虚拟化，但关闭其内置的流式跟随，改由自研 smooth-follow 控制器接管（`MessageList.tsx:56, 478-533`）；并缓存每个 Session 的滚动快照（上限 100，:61-73），恢复时用虚拟列表的状态恢复 API 直接回到原位置（:484-492），切换会话不会把阅读位置丢掉。桌面端消息导航（上一条/下一条用户消息、"回到底部"）与移动端顶部浮条由两个组件提供（`MessageList.tsx:537-585`）。

### 1.2 侧栏：桌面常驻 / 移动端抽屉

移动端导航方式不是底部 Tab Bar，是从左侧滑出的抽屉（`SwipeableDrawer`，`Sidebar.tsx:140-166`）。`variant` 按小屏判定切换——小屏幕下侧栏是"临时"的覆盖层（打开时盖住内容，点遮罩或滑动关闭），桌面端是"常驻"的挤压布局（`__root.tsx:348-351` 内容区让出侧栏宽度；侧栏宽度可拖动调整并持久化到 `uiStore.sidebarWidth`）。抽屉用 keepMounted 保证移动端切换时 DOM 不销毁、disableEnforceFocus 避免侧栏打开时其他弹窗里的 input 无法点击；支持从屏幕边缘滑动手势打开/关闭，且滑动打开手势只在非 iOS 构建上启用；阿拉伯语（RTL）时锚点切到右侧。全项目没有找到底部 Tab Bar 组件——移动端的一级导航（新建对话/图片创作/搜索/归档/关于/设置）全部收在这一个可滑出的侧栏抽屉里。

小屏判定（`useIsSmallScreen()`，`hooks/useScreenChange.ts:14-18`）用 **< 640px** 判定为小屏（媒体查询）；但侧栏初始值判断用原始 `matchMedia('(max-width: 599.95px)')`（`uiStore.ts:10-16`）——600px 和 640px 两个数字并不完全一致，理论上存在 600px~640px 区间首屏渲染和后续渲染判断不一致的窄缝，未核实是否有实际可观察的视觉跳变。

**会话项活动指示**：侧栏会话项带"生成中"（转圈图标）与"回复完成未读"圆点两种指示（`SessionItem.tsx:276-294`，带状态角色与可访问名称）。状态来自两个纯内存 zustand store：一个按会话计数进行中的生成，一个维护"完成回复但未查看"的会话集合（排除当前正在查看的会话，`sessionActivityStore.ts:24-36`），由列表项经 hook 消费。**不写入会话元数据、不持久化**——重启后消失，会话列表的数据模型仍是"只认 meta 记录"。

## 2. 会话列表、搜索与现场恢复

### 2.1 会话列表分页与分组

`SessionList.tsx` 用 Virtuoso 分页加载（滚动到底触发下一页，翻页中挂加载页脚），置顶/普通两组通过 `SessionMetaRecord.starred` 置顶标记分开（Pinned/Chats 两个 section）；分页数据来自 IndexedDB 游标扫描（数据侧见会话与消息管理笔记 2.2）。本次未找到"会话列表完全为空"时的专门空状态组件——列表组件及其父组件没有对空数组的特殊分支，新用户首次打开时侧栏为空。

### 2.2 拖放排序：dnd-kit + 同组约束

用的库是 `@dnd-kit/core` + `@dnd-kit/sortable`（`SessionList.tsx:1-20`）。三种传感器：触屏（150ms 延迟、8px 容差）、鼠标（10px 移动阈值才激活，避免误触发拖拽）、键盘（配合 sortable 坐标辅助，:57-71）。

关键约束（`:87-89`）：拖拽只在**同一个置顶分组内**生效：

```ts
if (oldIndex < 0 || newIndex < 0 || !areSessionsInSamePinGroup(activeSession, overSession)) {
  return
}
```

`areSessionsInSamePinGroup`（`shared/utils/session-sort.ts:3-8`）就是判断两者 `starred` 值是否相同。也就是说**不能靠拖拽把一个未置顶会话拖进置顶区**，必须先手动点"置顶"。

移动端有一个独立的"调整顺序模式"：普通情况下小屏幕禁止拖拽（传感器条件与拖拽项禁用），必须先在长按菜单里点 "Adjust order"（`SessionItem.tsx:209-213`）进入重排状态，此时才出现拖拽把手图标（`SessionList.tsx:260-272`），顶部出现一条带 "Done" 按钮的提示条（`SessionList.tsx:150-170`）。这是典型的 iOS 风格"进入编辑模式再拖拽"。排序结果落地采用分数索引（数据侧见会话与消息管理笔记 2.3）。

### 2.3 会话项操作入口与归档提示

`SessionItem` 的右键/长按菜单承接置顶、调整顺序、归档（`SessionItem.tsx:200-222`）；归档当前会话会先跳回首页。归档总数超过 600 时弹确认框建议去设置页清理（:124-134）；否则最多每 24 小时弹一次"已归档，去设置管理"的 toast（带跳转设置页的 CTA，:100-111）。

### 2.4 消息搜索与定位

`pages/SearchDialog.tsx:50-65` 提供"当前会话"和"全部会话"两个入口（按初始模式设置决定）；搜索结果项点击后切换目标会话，并调用滚动定位 API 跳到具体消息——跨会话时先切换会话、再以 300ms 起步的重试机制（最多 10 次）等待列表就绪后滚动（`SearchDialog.tsx:179-203`）。跨会话搜索按页读取并逐条扫描的实现见会话与消息管理笔记 5。

## 3. Composer、草稿、附件与快捷输入

### 3.1 首页 "new" 临时会话：三种状态容器

`src/renderer/routes/index.tsx:83-86`：

```ts
const [session, setSession] = useState<Session>({
  id: 'new',
  ...initEmptyChatSession(),
})
```

`session` 是纯本地 React state，`id` 硬编码为字符串 `'new'`（不是 uuid）。provider/model 组合、copilot 引用、名称、copilot 的 system prompt 消息、头像与背景图全部存在这个 state 里，**不落地任何 store**。

`InputBox.tsx` 通过 `isNewSession = currentSessionId === 'new'`（`InputBox.tsx:253`）判断分支，但不同类型的"待发送状态"实际被分散存放在三种不同的容器里：

1. **本地组件 state**（仅 `routes/index.tsx` 内）：模型选择、copilotId、name、messages、头像。
2. **专用临时对象 `newSessionState`**（`uiStore.ts:40-47`）：

   ```ts
   newSessionState: {
     knowledgeBase?: Pick<KnowledgeBase, 'id' | 'name'>
     webBrowsing?: boolean          // 类型里声明了，但实际未被写入/读取
     workingDirectories?: string[]
     agentFullAccess?: boolean
   }
   ```

   `useKnowledgeBase({ isNewSession })`（`hooks/useKnowledgeBase.ts`）对新会话读写的是 `newSessionState.knowledgeBase`，而不是通用的 `sessionKnowledgeBaseMap['new']`。
3. **通用的"按 sessionId 映射"Map，直接复用字符串 `'new'` 当 key**：
   - `sessionWebBrowsingMap: Record<string, boolean|undefined>`（`uiStore.ts:36`），`InputBox.tsx:261`：`sessionWebBrowsingMap[currentSessionId || 'new']`；
   - `sessionAgentModeMap: Record<string, AgentModeEntry>`（`uiStore.ts:60`），读取见 `stores/session/agent-mode.ts:20-26`（`legacyMap[sessionId]`，sessionId 传入的就是 `'new'`）。

也就是说，`newSessionState.webBrowsing` 这个字段在类型定义里存在，但网页浏览的真实临时值走的是 `sessionWebBrowsingMap['new']`，两者是两套并行机制——全仓库 grep 该字段没有任何读写点，仅类型声明，是**未被使用的死字段**。

首次发送时转入真实会话的逻辑（`createPersistedChatSession`，`routes/index.tsx:272-353`）的数据语义见会话与消息管理笔记 3.1；"首页输入框"和真实会话输入框呈现相同，但生命周期不同。

### 3.2 草稿：按会话粒度的 localStorage

草稿由 `useMessageInput` 管理：key 规则是首页假会话固定 `'new-chat'`、真实会话按 `draft-${sessionId}`（`useMessageInput.ts:18-20`），输入 300ms 防抖写入 localStorage（:29-35），挂载时恢复、发送成功后清除对应 key（:22-27, 62-79）。首页假会话的草稿在创建真实会话后被显式删除（`routes/index.tsx:336`）。真实会话按会话各自独立，切换会话不串草稿。

### 3.3 输入快捷操作

发送键可配置 Enter、Ctrl/Cmd+Enter、Ctrl+Enter、Command+Enter、Shift+Enter 或 Ctrl+Shift+Enter，另有"发送但不生成回复"。空输入（或全文选中）时 ArrowUp/Down 浏览输入历史（`InputBox.tsx` 的上一/下一条历史函数，提交成功后写入历史，:928-930）；技能补全弹窗用 ArrowUp/Down 选择、Enter/Tab 确认、Escape 关闭；Escape 普通输入时阻止浏览器恢复 defaultValue 并让输入框失焦。引用消息通过 `quote` 状态注入（`uiStore.quote`，`InputBox.tsx:1334-1353`）。

### 3.4 附件拖入：没有拖拽过程的视觉反馈

`InputBox.tsx:1318` 用 `react-dropzone` 的 `useDropzone` 实现拖拽上传，根 props 直接铺在整个输入区容器上。**但只解构了根与输入 props，没有解构拖拽激活/接受/拒绝三个状态字段**——这三个状态字段在 `InputBox.tsx` 里完全没有被使用。也就是说，用户把文件拖到输入区上方悬停时，**没有任何高亮遮罩、虚线边框或文案提示**"松手可上传"，唯一的反馈是松手瞬间文件立刻被处理（成功则出现在附件预览区；被拒绝的文件类型通过 toast 弹一条"不支持的文件类型"提示；Agent 模式接受所有文件类型）。这是一个静态代码可确认的交互缺口：拖拽全程用户得不到"目标区域已识别"的即时反馈。

对比之下，会话列表拖拽排序（dnd-kit）有完整的视觉反馈体系（`DragOverlay`、把手图标、编辑模式提示条），输入区文件拖拽在这方面明显更简陋。

## 4. Agent、模型、工具与发送前配置

输入工具栏提供附件、网页搜索、推理级别、Agent Mode、知识库/技能、新建或回滚 Thread、会话设置、Token/上下文窗口和模型选择。`ModelSelectorV2` 可直接切换 provider/model（`InputBox.tsx:1887-1921`，触发按钮内显示模型名文本与下拉箭头图标）；Agent Mode 可在 Chat/Agent 间切换，并按模型能力显示执行设备、工作目录、审批模式和 Git/Worktree 控件。生成时发送按钮变为停止（`InputBox.tsx:1500-1510`）。

Agent 面板/按钮的界面变化：工作目录选择器有"最近使用的工作目录"（`stores/recentDirectoriesStore.ts` 支撑）；Agent 按钮按上下文显示能力提示气泡；小屏下 Agent 模式用状态图标呈现；网页搜索/知识库能力与 Work Mode 能力控件独立门控（网页搜索、知识库不受该门控影响）。技能补全弹窗的指令列表经 Portal + Floating UI 跟随锚点、不遮挡输入框（`InputBox.tsx:1413-1457`）。当 Agent 模式为自动且是首轮用户消息时，生成前会先做 Agent 模式建议（分类器模型判断），建议以消息内卡片呈现、可接受/拒绝（执行语义见对话请求与上下文笔记 9.6）。

网页浏览开关的默认值规则：如果该会话没有显式设置过，ChatboxAI provider 默认开、其他 provider 默认关（`InputBox.tsx:259-267`）；这些开关最终以工具注册的方式进入请求（执行语义见对话请求与上下文笔记 9）。开关本身经 uiStore persist 持久化，重启保留；知识库与 Agent 模式开关不持久化（会话与消息管理笔记 8）。

## 5. 发送、排队、流式反馈与停止

- **提交顺序**：提交处理器先更新 UI 滚动状态（标记新消息并瞬间滚到底部），再经 `submitNewUserMessage` 提交；输入区提交前有禁用态合并检查（生成中、预处理中、等待审批、存在预处理错误、RAG 附件索引未就绪时弹"文档仍在索引中"确认框，`InputBox.tsx:838-848, 881-884, 1936-1967`）。
- **发送/停止按钮**：`InputBox.tsx:1486-1510`——同一个按钮，按生成状态切换发送/停止动作，用图标区分状态；生成态外包了一层 Tooltip（"Stop"/"Stop all N replies"，仅在生成时显示），但**按钮本身没有 `aria-label` 属性**（Mantine Tooltip 不向触发元素注入可访问名称）——屏幕阅读器用户聚焦该按钮时得不到文字描述，这是最直接的无障碍缺口；生成中若有多个并发回复，停止按钮文案为"Stop all N replies"（`generatingCount`）。
- **生成中占位**：`Message.tsx:982-991` 在生成且内容为空时渲染自定义 `Loading` 组件（`components/icons/Loading.tsx`）——手写 SVG 动画：四个圆点用 `<animate>` 标签分别做纵坐标/透明度/半径三个属性的关键帧动画（周期 1.25s），四个点依次延迟 0s/0.2s/0.4s/0.6s 开始，形成"依次跳动"的等待指示器。
- **工具调用等待中**：`MessageLoading.tsx` 提供 `MessageStatuses`/`PreparingToolCallStatus`（`Message.tsx:89` 引入，`:955-957` 渲染），用于区分"纯文本生成中"和"准备/等待工具调用"两种状态展示。
- **网络请求失败**：走消息级的 `MessageErrTips.tsx`，根据 HTTP 状态码查一张文案映射表（`httpStatusCodeI18nKeys`，覆盖 401/403/408/429/500/502/503/504），给出可读文案；还会检测错误内容是不是网关返回的原始 HTML 页面（`isHtmlContent`），避免把一整页 HTML 源码糊给用户看。
- **审批卡片滚出视野时**：`PendingApprovalPill`（`components/chat/PendingApprovalPill.tsx`）——当审批卡在消息列表里滚出可视区时，输入框上方浮现浮动审批胶囊（内容来自审批关注 store 的待处理摘要），点击滚回审批卡所在消息，避免"审批在视野外用户不知情"。

## 6. 消息操作、分支与版本导航

### 6.1 消息操作栏

`Message.tsx` 的操作菜单按角色显示：助手"再次回复/重试"，用户"在下方继续回复"；两者可编辑（打开消息编辑弹窗，:395-405）、复制、引用、删除，另有"打开更多"菜单；助手生成中可停止，图片会话可"在下方生成更多图片"，移动端助手可举报。可恢复工具错误会让用户选择重试整条消息或从最后工具步骤重试（`retryChoiceOpened` 弹窗，:963-980）。回复仍在生成时也可以编辑/删除消息：操作可用性由专用状态计算模块决定——只有"可停止且并发回复数 > 1 且非图片"时才给消息内停止按钮，主列表生成中的最新回复不显示停止按钮、改由输入框停止，ForkGroup 内的替代回复例外（`components/chat/message-action-state.ts:15-29`）。`Message` 组件的编辑、复制、重试、删除、分支切换等动作通过 `sessionActions` 写回 store，而不是直接修改 DOM。

### 6.2 Thread、Fork 的界面呈现

`MessageList.tsx` 将最新一轮 user+assistant 合成一个渲染 item（组装函数见 `message-render-items.ts:49`、`message-timeline.ts:35`），其余消息逐条渲染；消息顶部可插入 `ThreadLabel`，Fork 在分叉点下显示 `ForkGroup`，摘要和跨会话来源分别由专用组件呈现（这些组件的内容渲染归消息渲染器，这里记录导航工作流）：

- **Thread 边界**：渲染每条消息前先检查该消息是否命中当前 thread 的历史哈希（数据侧见会话与消息管理笔记 1.2），命中就在该消息上方插入一个 `ThreadLabel`（`MessageList.tsx:396-456`）——thread 边界是消息列表里的一个内联锚点标签（"# threadName"，可打开菜单编辑名字/在抽屉里定位/继续这个 thread/移到独立会话/删除），和侧栏完全无关。`ThreadHistoryDrawer.tsx` 提供的是当前会话内所有 thread 的侧滑抽屉列表（作用域仅限"这一个 Session"），条目点击经滚动定位 API 跳到 thread 首条消息（:32-45）。
- **Fork 切换**：分支切换并入 `ForkGroup`：折叠组头部显示 `N / M` 位置指示（`ForkGroup.tsx:204`），切换走两个入口函数 → 会话 store 的纯函数（数据语义见会话与消息管理笔记 1.3），上一/下一按钮带可访问名称（`ForkGroup.tsx:160, 212`）。
- **替代回复折叠分支组**：分叉点下方渲染 `ForkGroup`（`MessageList.tsx:440-451`）：把多条替代回复收进"N 个回复"折叠组（新→旧排列，活动分支在最后），可展开逐条查看、复制、删除分支或从组内继续生成/停止（与主列表的 `generatingReplyCount` 计数联动）。
- **桌面端还有** `MessageMinimapRail`（仅桌面显示）、上一条/下一条用户消息导航和"回到底部"按钮（1.1）；minimap 锚点只用消息短预览文本并保持引用稳定（渲染细节见消息渲染器笔记）。

### 6.3 右键/上下文菜单：桌面端根本没有右键菜单

`SessionItem.tsx:185-190` 的 `handleContextMenu` 明确写着：

```ts
const handleContextMenu = (event: MouseEvent) => {
  if (!isSmallScreen) {
    return
  }
  event.preventDefault()
}
```

**桌面端（非小屏）完全不处理右键菜单事件**，只在小屏幕上阻止系统默认菜单弹出（防止手机长按弹出原生菜单干扰长按手势）。桌面端唯一能触发的"更多操作"入口是 hover 时显现的两个小图标按钮（置顶、归档，`SessionItem.tsx:306-350`，均带可访问名称），**没有右键菜单**，改名/删除等操作要通过打开会话后进入会话设置弹窗完成。

移动端（`isSmallScreen`）的"菜单"其实是**长按触发的操作菜单**（`SessionItem.tsx:358-370`，配合自制长按计时器：550ms 延迟、10px 移动容差），长按成功会触发一次原生震动反馈（桌面浏览器走 `navigator.vibrate?.(10)`，移动 App 走 Capacitor 的 `Haptics.impact`）。这个"菜单"底层是 Mantine Popover（`ActionMenu.tsx:120-206`），不是浏览器原生右键菜单事件驱动。

`Message.tsx` 全文 grep **没有找到 `onContextMenu`**——消息气泡没有右键菜单，所有消息操作都是操作栏上的常驻/hover 按钮，不支持右键唤出。

## 7. 多会话、多模型、群聊与后台生成

- 多模型并行在输入区以"快速模型/Agent 配置"的形式呈现（第 4 节）；同一会话内多个"在下方继续回复"可并行生成（替代回复，执行语义见对话请求与上下文笔记 8），侧栏按会话计数显示"生成中"指示（1.2），输入框停止按钮在多个回复并发时显示 "Stop all N replies"（第 5 节）。
- 群聊、子 Agent、后台任务的界面区分本次未调查——代码中未发现对应 UI 结构。

## 8. Chat UI 状态所有权与同步

- **状态分散风险**："new" 临时状态分散在三种不同容器里（本地 state / `newSessionState` 专用对象 / 通用 map 复用字符串 `'new'` 作 key），且 `newSessionState.webBrowsing` 字段完全未被使用（3.1）。给后续新增"发送前可配置项"的开发者增加了选错容器、忘记转移的风险。
- **草稿**：按会话粒度存 localStorage（`'new-chat'`/`draft-${sessionId}`），刷新与重启后恢复（3.2）；首页假会话的草稿在创建真实会话后被显式删除（会话与消息管理笔记 3.1 第 6 步）。
- **滚动位置**：每个 Session 的滚动快照缓存最多 100 个，切换会话不丢阅读位置（1.1）；`clearScrollPositionCache` 随会话删除清理（`MessageList.tsx:79-81`）。
- **会话级开关**：网页浏览开关（`sessionWebBrowsingMap`）经 uiStore persist 持久化；知识库（`sessionKnowledgeBaseMap`）与 Agent 模式（`sessionAgentModeMap`）仅内存态，重启丢失（会话与消息管理笔记 8）。
- **桌面端集成（Electron）**：
  - 全局快捷键：`src/main/main.ts:259-274` 的注册函数只注册了**一个**全局快捷键，绑定到显示/隐藏主窗口（:493, 567）。没有找到"新建会话""发送最近一条消息"之类更细粒度的全局快捷键。
  - 系统托盘（`main.ts:282-311`）：按平台选择不同图标（macOS 模板图、Windows ico），右键菜单只有 "Show/Hide" 和 "Exit" 两项，双击托盘图标也触发 `showOrHideWindow`。托盘图标本身**不显示未读消息数、生成状态等聊天相关的动态徽标**。
  - 系统级 Notification API 未接入：全代码库 grep `"new Notification("` 无匹配，Electron 主进程也没有引入 `Notification` 模块（`main.ts:172` 只有一条指向 Electron 通知文档的注释）。即"某条消息生成完成""工具调用需要审批"等场景**不会弹出系统通知**。
  - 窗口显示/隐藏事件双向打通：`main.ts:501, 515` 在窗口显示时发送 IPC `window-show` 给渲染进程；渲染侧（`useShortcut.tsx:49-56`）监听窗口显示/聚焦事件，窗口显示或聚焦时自动聚焦消息输入框（仅大屏幕）——这是唯一的"桌面事件 → 聊天 UI 反应"联动。

## 9. 键盘、焦点、响应式与关键路径可用性

### 9.1 无障碍

- **发送/停止按钮没有 `aria-label`**：`InputBox.tsx:1493-1510` 的发送/停止按钮只用图标区分状态，没有可访问名称、没有 title 属性；生成态有 Tooltip 包裹（"Stop"/"Stop all N replies"，:1486-1492），但 Mantine Tooltip 不向触发元素注入可访问名称属性——屏幕阅读器用户聚焦此按钮时仍得不到文字描述。这是最直接的无障碍缺口。输入框本身有可访问名称（`MessageInputField`，:1477）。
- **模型选择器有 Tooltip，但触发元素本身没有 `aria-label`**：`InputBox.tsx:1899-1920` 的模型选择器触发按钮没有可访问名称，视觉上靠内部文本文案传达当前模型名，对屏幕阅读器不算严重问题（有文本内容可读），但下拉箭头图标没有 `aria-hidden`。内部的行项组件（`ModelRow.tsx:113, 121, 127, 144`）反而做得更完整：视觉能力图标（Vision/Reasoning）、模型详情、收藏按钮都有 `aria-label`。
- **`trapFocus={false}` 的弹窗**（消息编辑、会话设置、Copilot 详情与设置四个弹窗）打开时键盘 Tab 键可以聚焦到弹窗背后的页面元素——这是 git log 可查证的、有意为之的修复（为解决 iOS Safari 里 Modal 内文本框无法长按选中文字的问题），但客观上牺牲了这四个弹窗的键盘可达性边界，是一个真实存在、有代码证据、且项目方明知取舍的无障碍缺口。
- **做得相对完整的反例**：项目里多处图标按钮补了可访问名称——
  - 消息跳转导航：真实 `<button type="button">` 元素 + 可访问名称（"Jump to message N"）+ focus-visible 焦点环，装饰性圆点用 `aria-hidden="true"` 正确隔离（`MessageMinimapRail.tsx:350-365`）；
  - 模型行、会话项的置顶/归档按钮、拖拽把手、分支标记与分支切换按钮等处的图标按钮（`ModelRow.tsx`、`SessionItem.tsx:310, 332`、`SessionList.tsx:264`、`ForkMarkerMessage.tsx:45`、`ForkGroup.tsx:160, 212`）；
  - 侧栏活动指示：状态角色 + 可访问名称（`SessionItem.tsx:280-282`）。

  也就是说项目里**存在无障碍意识**，但覆盖不均——发送/停止这个全应用最高频的交互点恰恰是缺失的。
- **Tab 顺序**：未系统性测试（需要实机/自动化工具验证，本次仅代码静态阅读），但从 DOM 结构看没有发现人为的 `tabIndex` 乱序设置；`trapFocus={false}` 造成的"跳出弹窗"是唯一从代码里能直接证实的 Tab 顺序问题。

### 9.2 快捷键面板

全文 grep 快捷键相关的帮助浮层触发方式（`?` 键监听、ShortcutsHelp、KeyboardShortcutsModal 等命名）**均无匹配**。快捷键处理函数（`hooks/useShortcut.tsx:65-133`）里硬编码了一批快捷键（Ctrl+I 聚焦输入框、Ctrl+E 切换网页浏览、Ctrl+N 新建会话、Ctrl+Shift+N 新建 Thread、Ctrl+Tab/Ctrl+Shift+Tab 切换会话、Ctrl+数字跳转会话、Ctrl+K 打开搜索、Ctrl+, 打开设置），**没有对应的"按 `?` 展示这份清单"的浮层**，唯一能看到快捷键说明的地方是设置页面里的静态列表（`routes/settings/hotkeys.tsx` → `components/Shortcut.tsx`）。用户需要主动打开设置才能看到/修改快捷键，不存在按需呼出的浮层式帮助。

## 10. 设计取舍与已确认边界

- **"new" 临时状态分散**在三种容器里，且 `newSessionState.webBrowsing` 是死字段（3.1）。
- **拖拽排序被限制在同一置顶分组内**（`areSessionsInSamePinGroup`），不能靠拖拽把未置顶会话直接拖进置顶区（2.2）。
- **附件拖拽无过程反馈**：拖拽悬停时没有任何"松手可上传"的视觉提示（3.4），与 dnd-kit 排序的完整反馈形成反差。
- **桌面端无右键菜单、无系统通知、无托盘状态徽标**：桌面集成与聊天状态联动最少（8）；侧栏会话项的"生成中/未读完成"指示仅存在于应用内，不走系统通知（1.2）。
- **生成中消息可编辑/删除**、ForkGroup 替代回复折叠组、审批浮动胶囊（PendingApprovalPill）属新增交互（6.1/6.2/5）。
- **"Stop all N replies"并发停止**：同一会话多个替代回复并行生成时，消息内停止按钮按 `shouldShowConcurrentReplyStop` 门控出现，主列表最新回复由输入框按钮停止（6.1）。
- **类目边界**：本笔记只记录用户工作流与界面状态；Thread/Fork 的数据模型在会话与消息管理笔记 1，流式节流与工具注入在对话请求与上下文笔记 5/9，消息壳与 Markdown 渲染在消息渲染器笔记。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为、系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 600px~640px 断点窄缝是否有实际可观察的视觉跳变未核实（1.2）。
- 发送/停止按钮在屏幕阅读器中的实际读出行为未验证（9.1 仅静态确认属性缺失）。
- 会话列表空状态的呈现未验证（2.1 仅确认代码中无空状态分支）。
- 拖拽排序、长按菜单的触控行为（传感器延迟/容差）未在实机上验证（2.2、6.3）。

## 12. 关键源码索引

- `src/renderer/routes/index.tsx`（首页/临时会话）
- `src/renderer/routes/session/$sessionId.tsx`（会话页布局与滚动）
- `src/renderer/routes/__root.tsx`（工作台骨架：Sidebar + Outlet）
- `src/renderer/components/session/SessionList.tsx`、`SessionItem.tsx`、`ThreadHistoryDrawer.tsx`
- `src/renderer/components/chat/MessageList.tsx`（ThreadLabel、ForkGroup、滚动缓存、smooth-follow）
- `src/renderer/components/InputBox/InputBox.tsx`（Composer、发送/停止、模型选择、拖拽上传）
- `src/renderer/hooks/useScreenChange.ts`、`useShortcut.tsx`、`useKnowledgeBase.ts`、`useMessageInput.ts`
- `src/renderer/stores/uiStore.ts`（`newSessionState`、各 sessionId-keyed map、persist partialize）
- `src/renderer/pages/SearchDialog.tsx`（搜索入口与定位）
- `src/renderer/Sidebar.tsx`（SwipeableDrawer 移动端导航）
- `src/renderer/components/ActionMenu.tsx`（长按菜单）
- `src/renderer/components/icons/Loading.tsx`、`components/chat/MessageLoading.tsx`、`MessageErrTips.tsx`、`PendingApprovalPill.tsx`
- `src/main/main.ts`（全局快捷键、托盘、window-show IPC）
