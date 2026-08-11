# LobeHub Chat UI 调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`5952f4c3f29ed3bb08dda6fd5fd64d6fffd4d3ae`（分支：`canary`）
>
> 调查方式：从 [`../Chat/LobeHub-Chat调查笔记.md`](../Chat/LobeHub-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码；通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、拖放、i18n）保留于原 Chat 笔记，待可选界面专题承接
>
> 调查范围：会话导航与现场恢复、Composer 与草稿、发送前配置、生成反馈与停止、消息操作、阅读辅助、UI 状态所有权、键盘与无障碍、桌面通知集成；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的聊天工作台由会话导航（Topic 侧栏）、消息区与 Lexical 工作台式输入区组成：

- Topic 列表：单击/双击 250ms 区分导航与开新 tab、拖拽引用到输入框、右键菜单、悬浮元数据卡、未读点、失败/运行图标与运行耗时；按 Flat/时间/状态/项目多种模式组织。
- 输入区是一个可扩展工作台：草稿自动恢复、输入历史（按 agent/user scope）、IME 组合态、文件粘贴/拖入、Markdown 输入预览、`@` mention（Fuse 模糊检索）与 `/` slash action（编辑器插件实现，不是发送前字符串替换）。
- 发送/停止按钮是同一个交互位，状态由 operation store 驱动；只读/无权限时提前置灰并给出 tooltip 原因。
- 工具审批卡片有全局键盘快捷键（1/2/↑/↓/Enter）；无障碍覆盖是“点状”而非体系化的，消息操作栏图标按钮等存在明确缺口。
- 桌面端（Electron）完成/审批通知与聊天状态直接联动并深链回具体 Topic；Web/PWA 没有系统级通知。
- 消息内容渲染（conversation-flow 算法、虚拟列表、Markdown）一律属于消息渲染器笔记，本文只记录工作流与界面状态。

## 工作台边界与用户主链

```text
进入 Topic（路由参数 -> ConversationContext）
  -> Topic 侧栏：切换 / 双击开 tab / 拖拽引用 / 未读点 / 运行态反馈（会话导航）
  -> Lexical 编辑器：草稿恢复 / 历史 / mention / slash / 文件粘贴（发送前配置：Agent、模型、执行设备、审批模式）
  -> 发送按钮（生成中变停止）-> 流式输出（keepMounted、ChatMiniMap、滚动快照）
  -> 消息操作：编辑/复制/重试/删除/分支/审批/翻译/TTS
  -> 离开 / 再次进入：滚动快照与草稿恢复现场
```

边界：消息数据如何分桶、CRUD 落库属于会话与消息管理（[`../会话与消息管理/LobeHub-会话与消息管理调查笔记.md`](../会话与消息管理/LobeHub-会话与消息管理调查笔记.md)）；发送后任务如何执行、审批如何恢复任务属于对话请求与上下文（[`../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md`](../对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md)）；消息列表虚拟化、角色分派、Markdown 与组件渲染属于消息渲染器（[`../消息渲染器/LobeHub-消息渲染调查笔记.md`](../消息渲染器/LobeHub-消息渲染调查笔记.md)）。通用界面盘点（弹窗库、Toast、主题、断点、动画、灯箱、拖放、i18n、PWA 安装、离线提示）保留在 [`../Chat/LobeHub-Chat调查笔记.md`](../Chat/LobeHub-Chat调查笔记.md) 第 13 节，待可选界面专题承接。

## 1. 会话导航与现场恢复

`AgentSidebar/Topic/List/Item/index.tsx` 在桌面端把单击延迟 250ms，以便把双击解释为“打开新 tab”；移动端单击直接导航。Topic 行支持拖拽引用到输入框、右键菜单、悬浮元数据卡、未读点、失败/运行图标、运行耗时和工作目录标签。列表本身按 Flat/按时间/按状态/按项目多种模式组织，`TopicSearchBar` 和 `AllTopicsDrawer` 提供全量查找；这些都是会话导航 UI，不改变 Topic 的消息树。（“全量查找”的后端实现——服务端 BM25 匹配 Topic 标题与消息内容——在会话与消息管理笔记第 4 节；结果不会直接标出或滚动到命中的具体消息。）

消息列表的滚动现场：`ChatList` 保存 topic 级滚动快照，`ChatMiniMap` 在消息足够多时显示用户消息锚点，悬停展开预览，点击后调用 `scrollToIndex`（虚拟列表的滚动机制与 `keepMounted` 见消息渲染器笔记第 5 节）。

## 2. Composer、草稿、附件与快捷输入

### 2.1 输入编辑器是一个可扩展工作台

`features/ChatInput/InputEditor/index.tsx` 基于 Lexical 编辑器，输入内容支持草稿自动恢复、输入历史（按 agent/user scope）、IME 组合态、文件粘贴/拖入、Markdown 输入预览、`@` mention 和 `/` slash action。mention 结果按 Agent、话题、文件等分类并用 Fuse 做模糊检索；slash 菜单和 action tag 都是编辑器插件，不是发送前再做字符串替换。离开页面前若编辑器非空会注册 `beforeunload` 提示，避免草稿静默丢失。

### 2.2 输入快捷操作

发送设置为 Enter 或 Mod+Enter，Shift+Enter 换行。输入为空时 ArrowUp 打开历史，ArrowUp/Down 移动，Enter/Tab 确认，Escape 关闭。Lexical 编辑器支持 @ mention、/ slash action/skill、文件粘贴/拖入、草稿恢复；工具快捷按钮可在 + 面板固定、取消固定、拖拽排序或恢复默认（拖拽排序的具体实现机制未核实，见第 11 节）。

## 3. Agent、模型、工具与发送前配置

ModeSelector 切换 Chat/Agent；Agent 模式下出现执行设备、工作目录/仓库、分支或 Worktree、审批模式和上下文窗口。模型按钮切换当前 topic 模型；多模型选择器可悬停移除单个模型或恢复 Agent 默认模型。无创建权限或 view-only 时发送按钮置灰并显示原因。

## 4. 发送、生成反馈与停止

`features/ChatInput/SendArea/SendButton.tsx` 从 ChatInput store 读取 `generating/disabled`：普通状态点击发送，生成状态显示停止动作；工作区只读权限和 Agent General access 会同时把按钮置灰并给出 tooltip，避免用户点击后才收到 403。`handleStop` 与生成状态由 operation store 驱动，按钮状态并非根据 DOM 中最后一条消息猜测。

**交互层的注意点**：
- 发送权限在 UI 侧提前反映，但最终权限仍由服务端校验；只读用户可以阅读同一 Topic，但不能通过按钮绕过权限发送。
- 发送按钮被禁用时外面套 `<Tooltip title={reason}>`（`ChatInput/SendArea/SendButton.tsx:45-46`），把“为什么不能发送”用无障碍可读的 Tooltip 文案暴露出来，不是单纯把按钮变灰不给理由。

## 5. 消息操作、分支与版本导航

助手消息默认编辑、复制；有工具时默认“删除并重新生成”。菜单还提供评论、创建分支、折叠流程、TTS、翻译、分享、选择/多选、重新生成、删除；用户消息默认重新生成、编辑、复制，并有同类菜单。错误消息显示重试与删除。工具/任务块另有审批、拒绝、取消和删除孤立工具消息，编辑文件卡可展开并查看/隐藏 diff。

消息操作栏承接编辑、重试、分支、转发、翻译和 TTS 等动作（`Messages/components/MessageActionBar` 等组件如何装配进消息壳属于消息渲染器笔记）；分支指示器画在子消息上、激活索引存在父消息 metadata 里，数据语义见会话与消息管理笔记 3.3。

## 6. 阅读辅助与多会话反馈

- 虚拟列表用 Virtua 渲染 `conversation-flow.parse()` 产出的 flat list（列表机制、`keepMounted`、索引空间转换等全部属于消息渲染器笔记第 5 节）；流式消息和有文本选区的消息强制 `keepMounted`，避免 Markdown 动画重播或选区被回收——界面呈现的阅读辅助（ChatMiniMap、滚动快照、scrollToIndex）见第 1 节。
- 多会话/后台生成的界面反馈：Topic 行的运行/失败图标、未读点与耗时（第 1 节），以及完成/审批的桌面通知（第 9 节）；“哪一条仍在运行并返回对应现场”由 operation 状态驱动这些 UI。

## 7. Chat UI 状态所有权与同步

- **按会话隔离**：`ConversationProvider`（`src/features/Conversation/ConversationProvider.tsx:86-130`）为每个 `messageMapKey` 创建一个独立 Zustand store；generation/editing/selection/scroll/virtua 相关与 `pendingArgsUpdates` 都是按 `contextKey` 隔离的 UI-only 状态，切换 topic/thread 时整个 store 连同内部状态重建，天然丢弃重置，不用手写清理逻辑（存储布局见会话与消息管理笔记 2.2/2.4）。
- **滚动 API 注册进 store**：滚动方法通过 `registerVirtuaScrollMethods` 注册进局部 store 的 `virtuaList/action.ts`（`registerVirtuaScrollMethods`/`scrollToBottom`/`scrollToIndex`/`setActiveIndex`，全文件 6-138 行），`activeIndex` 由 `calculateActiveIndex`（54-75 行）按可见区域内 “top 最小、ratio 最大” 的启发式算出，用于“当前阅读到哪条消息”的高亮/侧边导航。
- **草稿**：输入草稿按 agent/user scope 保存输入历史并自动恢复（第 2 节）；离开页面前 `beforeunload` 提示防止草稿静默丢失。

## 8. 键盘、焦点与关键路径可用性

### 8.1 无障碍：点状覆盖，存在明确缺口

**做得到位的具体证据**（有文件行号支撑,不是泛泛而谈）：
- `Conversation/ChatItem/components/Actions.tsx:34` 消息操作栏容器带 `role="menubar"`;
- `Conversation/WorkingSidebar/ProgressSection/index.tsx:160-165` 折叠面板用 `role="button"` + `aria-expanded` + `aria-controls={listId}` 三件套,是本次调查里最规范的一处无障碍实现;
- `Conversation/WorkingSidebar/Browser/index.tsx:435-438` 加载指示器用 `role="progressbar"` + `aria-label` + `aria-valuetext`;
- `Conversation/ChatList/components/RefreshError.tsx:37,40` 消息列表刷新失败提示用 `role="status"` + `aria-live="polite"`,能被屏幕阅读器主动播报;
- `ChatInput/ControlBar/GitStatus.tsx:383-403` Git 同步按钮用 `aria-busy`/`aria-disabled` 反映异步状态;
- `ChatInput/SendArea/SendButton.tsx:45-46` 发送按钮禁用时用 Tooltip 暴露原因（第 4 节）;
- `Messages/User/components/AudioPlayer/index.tsx:145` 播放/暂停按钮 `aria-label` 随状态切换文案（“播放”/“暂停”）。

**明确的缺口**（如实指出,不夸大也不回避）：
- Topic 列表行（`AgentSidebar/Topic/List/Item/index.tsx`）、消息操作栏里的单个 icon 按钮（复制/编辑/重试等,`Messages/components/MessageActionBar/index.tsx`）本次 grep 均**未找到** `aria-label`——这些是 `ActionIcon`,视觉上靠 `title`/tooltip 提示,但本次没有确认 `@lobehub/ui` 的 `ActionIcon` 组件内部是否自动把 `title` 映射成 `aria-label`（这是三方包内部实现,未下钻）,如果没有，纯图标按钮对屏幕阅读器就是无文字描述的;
- 双击/单击 250ms 定时器（第 1 节记录的 Topic 行交互）完全依赖鼠标事件（`onClick`）,本次未找到对应的键盘可达实现（如 `onKeyDown` 处理 Enter 打开、Tab 可聚焦的 `tabIndex`）——键盘用户能否等效完成“单击导航/双击开新 tab”这两个操作**未核实到证据,倾向于没有**;
- 虚拟列表（`VirtualizedList.tsx`）渲染的消息条目本次未找到 `role="log"`/`aria-live` 一类支持“新消息到达时屏幕阅读器播报”的实现,流式生成的文字增量对屏幕阅读器用户是不可感知的;
- 工具审批的全局键盘监听（`AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx:200-219`）虽然支持 1/2/↑/↓/Enter 快捷操作,且正确跳过了 INPUT/TEXTAREA/contentEditable 焦点,但监听器挂在 `window` 上而不是聚焦到审批卡片本身,屏幕阅读器用户如果不知道这组隐藏快捷键存在,只能靠视觉阅读选项文字再用 Tab 找按钮,没有 `role="radiogroup"`/`aria-activedescendant` 之类的语义关联。

**结论**：无障碍支持是工程师按需加的“点状覆盖”（哪个组件出问题/被特别关注就补一处 aria）,而不是设计系统层面统一约定的产物——同一类交互（图标按钮）在有的地方有 `aria-label`（`OpenCodeModelSelector.tsx:310`、`WorktreeSwitcher.tsx:613`、`Tools/useControls.tsx:1581,1594`）,在另一些地方没有（Topic 行、消息操作栏）,取决于具体开发者是否补充,不是组件库强制要求。真正的 WCAG 合规判定需要人工用屏幕阅读器/键盘走一遍实际操作流程,本次只是静态代码扫描,结论仅限于“代码里有没有写这些属性”。

### 8.2 快捷键面板/帮助

- **发现型提示**（用的时候顺手看一眼）：`src/features/CommandMenu/components/CommandFooter.tsx`（1-29 行）在 Cmd/Ctrl+K 命令面板底部常驻显示“↵ 打开 / ↑↓ 选择”两个键位提示,只覆盖命令面板内部的操作,不是全局快捷键列表。
- **完整列表**（专门去看的设置页）：`src/routes/(main)/settings/hotkey/index.tsx`（1-27 行）组织三个分组——`Desktop`（仅桌面端显示,`isDesktop` 判断,第 19 行）/`Essential`/`Conversation`（`features/Conversation.tsx:63-90`,当前只有 Conversation 分组一个 `HotkeyGroupEnum.Conversation`）。每一项用 `@lobehub/ui` 的 `<HotkeyInput>`（`Conversation.tsx:46-61`）渲染,支持用户**自定义改键**、清除绑定、冲突检测（`hotkeyConflicts`,第 39-44 行遍历其它已绑定项做重复检测并高亮）——这不只是一个只读的快捷键说明面板,而是一个可编辑的快捷键管理器,修改后走 `useSaveState` 自动保存（第 87 行 `onValuesChange` 触发 `save`）。
- 命令面板本身的完整键位表（Cmd+K 打开、Esc 返回/关闭、Backspace 返回、Tab 进 AI 模式、↑↓ 选择、Enter 确认）本次靠 `useCommandMenu.ts:82-92` 的 Esc/滚动锁定 `useEffect` 和 `README.md` 里记录的键位表交叉确认,`README.md` 是仓库内自带的开发文档而非用户可见 UI,用户能直接看到的仅有 `CommandFooter` 那两条提示 + 完整可编辑列表在设置页。

## 9. 桌面通知与跨平台连续性

桌面通知与聊天状态的联动是本次调查中确认度最高的一处集成：`src/store/chat/utils/desktopNotification.ts`（全文件 1-178 行）定义了两个统一注入点：

- `notifyDesktopAgentCompleted`（153-177 行）：Agent 回复完成时调用,`title` 按“话题标题 → Agent 名称 → 通用兜底”优先级解析（`resolveNotificationTitle`,68-88 行）,`body` 是把 markdown 回复剥成纯文本并截断到 256 字符（`buildNotificationBody`,90-100 行,超长加省略号）,`navigate` 深链回具体的 agent/topic/group 会话（`resolveNotificationNavigate`,58-62 行,按 groupId+topicId/agentId+topicId/仅 groupId/仅 agentId 四级优先级拼 URL,`resolveNotificationNavigatePath` 37-56 行）。调用点在 `store/chat/slices/aiAgent/actions/runAgent.ts:250-253`,紧跟在“停止 loading”之后触发,同批还会调用 `markTopicUnread`（255-263 行）把该 Topic 标记未读——**桌面通知和“Topic 未读点”是同一个完成事件驱动的两个并行副作用**（执行侧见对话请求与上下文笔记第 6 节）。
- `notifyDesktopHumanApprovalRequired`（102-131 行）：需要人工审批工具调用时触发,标题走同一套解析逻辑,额外调用 `desktopNotificationService.setBadgeCount(1)`（119 行）在 dock/任务栏打角标,并传 `force: true, requestAttention: true`（122-124 行,前台窗口也强制弹通知、抢占用户注意力,区别于普通完成通知默认只在窗口隐藏/失焦时才弹）。调用点 `runAgent.ts:303`,与对话请求与上下文笔记第 7 节的工具审批流程是同一条链路的下游副作用。
- 两者都通过 `isDesktop` 短路（`desktopNotification.ts:106,157`）,Web/PWA 环境下直接跳过,说明这套通知目前只在 Electron 桌面端生效,**没有找到** Web Push API/Service Worker 通知的对应实现,PWA 模式下完成/审批事件不会有系统级通知,只能靠“未读点”UI 或回到标签页查看。

## 10. 设计取舍与已确认边界

- **Topic 行的双击开 tab 与单击导航依赖 250ms 定时器**，快速跨行点击由模块级 timer 取消前一次动作；但完全依赖鼠标事件，键盘可达性未核实（第 8.1 节）。
- **虚拟列表的 `keepMounted` 只保护生成消息和选区**，普通历史消息仍会被回收，因此任何依赖 DOM 的扩展功能都必须通过 scroll API 而不能缓存节点（列表机制详见消息渲染器笔记）。
- **发送权限在 UI 侧提前反映**，但最终权限仍由服务端校验；只读用户可以阅读同一 Topic，但不能通过按钮绕过权限发送。
- **类目边界**：本笔记只记录用户工作流与界面状态；消息数据模型与 CRUD 在会话与消息管理笔记，发送与审批的执行语义在对话请求与上下文笔记，conversation-flow 算法与虚拟列表渲染在消息渲染器笔记。原 Chat 笔记中的通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、拖放、i18n、PWA 安装、离线提示）保留在 [`../Chat/LobeHub-Chat调查笔记.md`](../Chat/LobeHub-Chat调查笔记.md) 第 13 节，待可选界面专题承接。

## 11. 未验证事项

- `ActionIcon` 的 `title` prop 是否在渲染时自动映射为 DOM `aria-label`——三方包内部实现,未下钻,直接影响第 8.1 节里“大量图标按钮有没有 aria-label”的判断范围。
- 双击/单击 250ms 定时器的键盘可达实现未找到证据（第 8.1 节）。
- 工具快捷按钮在 + 面板“拖拽排序”的具体实现机制（排除了 dnd-kit 等专门拖拽库，但未读 `ChatInput/ActionBar/Tools/useControls.tsx` 确认真正机制，未核实）。
- `InputEditor` 目录下文件拖入时是否有拖拽悬停的视觉反馈样式——未找到专门代码,但也未完整读完整个目录,不排除遗漏。
- 视觉效果、键盘焦点顺序、响应式行为与系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 移动端/桌面端的布局差异与断点实现属于原 Chat 笔记的通用盘点范围，未在本笔记展开。

## 12. 关键源码索引

- `src/features/AgentSidebar/Topic/List/Item/index.tsx`（Topic 行交互）
- `src/features/Conversation/ConversationProvider.tsx`（86-130，UI 状态隔离）
- `src/features/Conversation/store/slices/virtuaList/action.ts`（1-138，滚动 API 注册）
- `src/features/ChatInput/InputEditor/index.tsx`（Lexical 编辑器）
- `src/features/ChatInput/SendArea/SendButton.tsx`（发送/停止）
- `src/features/Conversation/ChatMiniMap/index.tsx`（阅读辅助）
- `src/features/Conversation/ChatList/index.tsx`（76-243，滚动快照与列表接线）
- `src/features/Conversation/Messages/index.tsx`（61-260，消息操作入口）
- `src/features/Conversation/Messages/AssistantGroup/Tool/Detail/Intervention/ApprovalActions.tsx`（200-219，审批快捷键）
- `src/features/CommandMenu/components/CommandFooter.tsx`、`src/routes/(main)/settings/hotkey/index.tsx`（快捷键面板）
- `src/store/chat/utils/desktopNotification.ts`（1-178，桌面通知）
- `src/store/chat/slices/aiAgent/actions/runAgent.ts`（250-263, 303，完成/审批通知调用点）

