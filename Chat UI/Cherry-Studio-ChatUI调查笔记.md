# Cherry Studio Chat UI 调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、适配器与 hook、IPC 命令绑定、主进程桌面服务），界面视觉与键盘行为以"未运行验证"标注
>
> 调查范围：工作台结构、会话导航、Composer 与草稿、发送前配置、生成反馈、消息操作、分支树图导航、搜索、键盘与无障碍、桌面集成；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- **Home 和 Agent 两个入口共用同一套"会话壳 + composer + 消息列表"框架**：共用类型契约而非组件树，两个适配器各自注入可选能力对象，下游组件按存在性判断渲染；旧的"`state.readonly` 标志"机制已不存在，差异由 `useMessageLeafCapabilities`/`normalInteractionsEnabled` 表达（组件装配见 1.1）。
- **会话单位 Topic 是导航单位**：侧栏列表 + 右侧分支面板（React Flow 树图）+ 消息列表 `< i/N >` 兄弟导航三套入口并存；分支面板看到的是"DB 树 + live overlay"合并结果。
- **搜索是双轨的**：会话内搜索（`MessageListSearch` + `FindBar`）是"已加载数据粗匹配 + 已挂载 DOM 精确 Range + CSS Custom Highlight 高亮"的混合实现，`a012837e5c` 起支持虚拟化窗口外的消息定位；跨会话全局搜索（`GlobalSearchPopup`，`app.search` 命令）走主进程 FTS（数据侧见会话与消息管理笔记 5）。
- **多模型并行**通过 Composer 的"提及模型"多选触发：选中 N 个模型 → 主进程并行 N 个 execution，读侧按兄弟组横向/网格展示（执行语义见对话请求与上下文笔记 8）。
- **桌面集成与聊天状态联动最少**："助手回复完成"系统通知开关仍接不到任何触发点（全仓库无 `source: 'assistant'` 调用）、托盘无未读/流式角标、无快捷键速查浮层。
- **无障碍**：Topic/Session 列表有完整的 listbox 语义（roving tabindex + `aria-activedescendant`，有测试覆盖）；消息操作栏按钮现在都有 `aria-label`（取自 action 的翻译 label，本次调查确认已修复）；Composer 输入区本体仍没有可访问名称（RichEditor 内核支持可选 `ariaLabel`，但 ComposerSurface 未传入）。

## 工作台边界与用户主链

```text
进入 Home 或 Agent 入口（同一套会话壳 + composer + 消息列表框架，适配器注入能力）
  -> Topic 列表选择/新建/重命名/删除（拖拽排序仅助手分组可用）
  -> Composer 组织输入：文本、附件、提及模型、知识库、联网、推理强度、工具面板
  -> 发送 -> 生成反馈（流式 live 层、兄弟组、Topic 行运行指示）
  -> 消息操作：复制/编辑/重新生成/删除/翻译/分支/导出
  -> 分支导航：< i/N > 兄弟切换 + 分支面板树图
  -> 搜索定位（会话内 FindBar / 全局 GlobalSearchPopup）
  -> 再次进入：恢复 Topic 现场（草稿按会话缓存）
```

边界：会话与消息的数据语义（树、指针、锚点）见 `../会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md`；提交、上下文拼装、流式执行与最终化见 `../对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md`；消息内容、Markdown、虚拟列表与消息壳的渲染实现见 `../消息渲染器/Cherry-Studio-消息渲染调查笔记.md`（内容渲染类内容一律链接过去，不复制）。弹窗库、Toast 系统、主题 token、断点清单等通用界面盘点不在本笔记范围。

## 1. 页面结构、导航与多窗口

### 1.1 工作台拓扑：一套框架，两套适配器

Home 和 Agent 两个入口共用同一套"会话壳 + composer + 消息列表"框架，但不是共用一个组件树，而是共用**类型契约**：框架通过 Context Provider（`MessageListProvider`，`MessageListProvider.tsx:77-87`）暴露统一的消息列表状态/动作契约（`MessageListState/Actions/Meta`，契约类型见 `types.ts:282,332` 起），Home 与 Agent 各自用独立的 hook 组装并注入实现（实现位置见下列清单）。消息列表、消息分组、消息壳等渲染组件只读这些 context，不知道自己在哪个入口下（能力注入细节见 6.2；组件装配见消息渲染器笔记"入口与页面适配"）。

两套适配器的实现位置：
- Home：`useHomeMessageListProviderValue`，`src/renderer/pages/home/messages/homeMessageListAdapter.tsx:85`
- Agent：`useAgentMessageListProviderValue`，`src/renderer/pages/agents/messages/agentMessageListAdapter.tsx:142`

工作台外围是窗口级 `AppShell`：标签页栏（`AppShellTabBar`）+ 路由标签（`TabRouter`）+ 侧栏 + 页面区（`AppShell.tsx:185-243`）。

### 1.2 侧栏折叠与窗口宽度：手动命令 + 页面级最小宽度

- 侧栏展开/折叠是**手动命令**（`app.sidebar.toggle`，`HomePage.tsx:408`）；未发现由 resize 观察器、媒体查询或 CSS 容器查询驱动的**聊天侧栏**自动折叠逻辑（测试中"Auto collapse pane"是手动临时折叠命令，`HomePage.test.tsx:1553-1571`，不改变偏好），不随窗口变窄自动收起。
- 主窗口最小可缩放宽度随当前路由动态调整：进入聊天/代理工作台时外壳组件立即调用 IPC 把最小尺寸从默认 `MIN_WINDOW_WIDTH=960px`（`src/shared/utils/window.ts:1`）临时放宽到 `SECOND_MIN_WINDOW_WIDTH=520px`（`AppShell.tsx:21-22,137-144`，`window.main.set_minimum_size`），离开时还原——聊天页允许拖得比其他页面更窄。
- 阅读宽度限制是独立机制：`NarrowLayout`（`src/renderer/components/chat/layout/NarrowLayout.tsx`）把消息内容限制在窄排版（`chat.narrow_mode` 偏好，默认 `true`，`preferenceSchemas.ts:615`），是用户可关闭的排版偏好。

## 2. 会话列表、搜索与现场恢复

### 2.1 Topic 列表与生成运行指示

- Topic 列表数据：`/topics` 无限分页（页大小 200）＋置顶段/普通段两段排序，数据侧见会话与消息管理笔记 5；空状态（`Topics.tsx:1662-1666`）与加载骨架在此只记录存在。
- **运行指示器与聊天主链的交点**：Topic 行右侧的运行指示为跨面板组件 `ConversationRowStatus`（`src/renderer/components/chat/resourceList/base/ConversationRowStatus.tsx:20-51`），按消息运行状态显示不同的徽标/图标，并带 `aria-label` + `role="img"`（`:41`）。状态与视觉对应如下：

  | 状态 | 视觉 |
  | --- | --- |
  | 等待审批 | warning 徽标（`:25-31`） |
  | `pending` | `Loader2` 旋转图标（`:43`） |
  | `error` | `CircleAlert`（`:45`） |
  | 已完成但未读 | 绿色小圆点（`:47`） |

  状态由 `Topics.tsx:1727-1735` 从 topic 流状态派生（`isFulfilled = done && lastCompletedAt !== lastSeenCompletion`，`useTopicStreamStatus.ts:48`；读收条语义：只有非当前行且未读才显示完成点）；指示器是绝对定位 overlay，悬停/聚焦时淡出让位给 pin/delete 操作（`ConversationRowStatus.tsx:17-18`）。
- **草稿存在指示**（本次调查新确认）：Topic 行还有草稿图标指示（`TopicDraftIndicator`，`Topics.tsx:1900-1912`），订阅草稿缓存的按会话存在性查询（`chatDraftCache.ts:50-52`），当前行与高优先级状态不显示（`:1890-1897`）。

### 2.2 Topic 拖拽排序：仅助手分组可拖

- 只有当 Topic 列表按"助手分组"显示时才可拖（`dragReady = isAssistantDisplayMode && ...`，`Topics.tsx:821`；`canDragTopicItem` `:1167-1170` 要求非置顶），按"时间分组"显示时完全不可拖——时间分组的顺序由时间戳决定，拖拽没有语义，这是有意为之的限制。
- 助手分组可整组拖拽重排（入口 `handleTopicReorder`，`Topics.tsx:1181-1346`）：先乐观更新顺序（`:1280`），失败时 toast 提示并回滚重新拉取（`:1287-1300`）；置顶组与"无助手"组不可作为拖拽目标（`:1173-1177,1305-1306`）。
- Agent 侧 Session 列表拖拽排序**未检索到独立实现**（`SessionItem` 相关代码未见拖拽路径），按"没有实现"记录（检查范围：agents 目录下会话列表组件）。

### 2.3 消息搜索工作流：命令触发 + 数据粗匹配 + DOM 高亮 + 滚动定位

- **入口**：搜索命令 `chat.message.search`（快捷键默认 Ctrl+F，`preferenceSchemas.ts:794`）由搜索组件注册（`MessageListSearch.tsx:307-314`），取当前选中文本作为初始搜索词（`:310-311`），Esc 关闭（`:316`）。
- **搜索栏 `FindBar`**：输入框、大小写/整词/包含用户三个开关、`i/N` 计数与上/下/关闭按钮依次对应 `FindBar.tsx:132,140-177,181-191,192-211`（输入框带 `aria-label`），Enter/Shift+Enter 前进后退（`:98-109`）。
- **匹配对象**：先在**已加载的消息数据**上做粗匹配（文本 part 投影为纯文本、`pending` assistant 排除、多模型回复组以整组粒度匹配，`messageSearch.ts:133-148`），再对**已挂载 DOM** 求精确 Range（`src/renderer/utils/contentSearch.ts:40-88`；节点过滤排除按钮/引用/代码块工具栏等，`messageSearchDom.ts:10-18`）。
- **虚拟化窗口外的定位**：`a012837e5c` 起窗口外的消息可以通过粗匹配被找到并滚入视口（`MessageListSearch.tsx:337-339`）；折叠的用户消息在导航时自动展开（`messageSearchDom.ts:29-34`）。
- **流式期间的匹配边界**：匹配数据被锁存、流结束才重算（`MessageListSearch.tsx:97-102`）；live 消息被整体排除（`excludedMessageIds={liveMessageIdSet}`，`MessageList.tsx:746`）。
- **高亮**：用浏览器原生 **CSS Custom Highlight API**（`CSS.highlights.set('message-search-matches'/'message-search-current', ...)`，`MessageListSearch.tsx:189-199,242-244`），样式在 `src/renderer/assets/styles/index.css:227-228` 用 `::highlight()` 伪元素定义。
- **跳转**：先处理卡片/网格等内部滚动容器，再让虚拟列表滚动到该行（`MessageListSearch.tsx:233-234`；`MessageList.tsx:315-319`）。
- **跨会话全局搜索**：`app.search` 命令打开全局搜索浮层（`AppShell.tsx:80-99`），结果分实体（`/search/entities`）与内容（`/search/contents`，FTS，`useGlobalSearchPanelData.ts:260,319`）两条接口；内容命中定位到消息并跳转对应 Topic（数据侧见会话与消息管理笔记 5）。

### 2.4 现场恢复

- 切 Topic/标签页时 Composer 保持挂载（`ChatContent.tsx:47-56` 注释：外层壳先挂框架、消息列表拥有初始加载视图），草稿按会话缓存跨导航保留（3.3）；切换时保留的滚动位置、面板开关等其余局部状态未逐一核实。

## 3. Composer、草稿、附件与快捷输入

### 3.1 输入快捷操作

`ComposerSurface.tsx`（2316 行）基于 TipTap 富文本内核（`RichEditor`，`useRichTextEditorKernel`，`:1739-1785`）实现一套输入快捷操作：

- 发送：根据设置使用 Enter 或 Ctrl/Command/Alt/Shift+Enter 发送，单独 Shift+Enter 在非发送配置下换行。
- 输入历史：输入为空时 ArrowUp/Down 浏览历史（`:1461-1482`），Enter 确认、Escape 关闭；Escape 还能退出展开编辑器（`:1484-1488`）。
- Tab 遍历 prompt variable token（`:1490-1499`）。
- 正文为空时 Backspace 可移除最后附件。
- 另支持文件拖放/粘贴、图片/文件 token、@ 实体引用、slash/工具面板和 follow-up 队列。

### 3.2 附件拖入反馈：绿色虚线高亮

拖拽处理挂在文件拖放 hook 上（`src/renderer/components/composer/paste/useFileDragDrop.ts:102-160`）：文件/文本/文件夹路径分别处理，不支持的拖入类型弹 toast 提示（`:124-131`）。视觉反馈是 2px 绿色虚线边框 + 半透明绿色蒙层（`ComposerSurface.tsx:2165-2167`），颜色走主题色变量，旧实现硬编码的 `#2ecc71` 已不存在。

### 3.3 草稿与编辑恢复状态机

`ChatComposerInner` 在一个组件内混杂了草稿缓存、输入历史导航、编辑会话恢复（含"编辑消息时保存旧草稿、取消编辑时还原"的完整状态机）、mentioned models、reasoning effort 的乐观更新+回滚、queued followups 等多套独立状态机，用一堆 ref 协调（`inputHistoryToolsRef`、`skipDraftCacheWriteForHistoryPreviewRef`、`editingOriginalFilePartsByTokenIdRef`、`savedDraftBeforeEditingRef` 等）——功能齐全但可读性门槛高（取舍见第 10 节）。

以下两个行为已确认：

- **未发送草稿跨导航保留**：草稿按会话/对话粒度缓存（`chatDraftCache`/`agentDraftCache`），缓存键格式 `chat.composer_draft.<topicId>`、TTL 24 小时、内容含 `text/tokens/files/knowledgeBaseIds/mentionedModelIds/multiSelectMode` 等字段（`chatDraftCache.ts:5-18`）；切换 Topic/标签页后再回来草稿仍在，且 Topic 行有草稿存在指示（2.1）。
- **编辑用户消息可直接保存、不重发**：编辑历史用户消息后提供"仅保存"路径（`editMessage` 写回 parts 到 `PATCH /messages/:id`，`useChatWriteActions.ts:274-294`），不必触发重新生成；"编辑后重发"则走 `forkAndResend` 建兄弟行 + regenerate（`:346-396`）。

## 4. Agent、模型、工具与发送前配置

### 4.1 Agent/模型快速切换

- **选择器**：`ChatConversationControls.tsx` 同时提供助手选择器（`AssistantSelector`，`:132-143`）与模型选择器（`ModelSelector`，`:157-208`）：模型可单选或多选，已选模型可移除并恢复助手默认模型。
- **"指定模型重新生成"不改默认配置**：消息栏的重新生成模型选择器（`renderRegenerateModelPicker`，`homeMessageListAdapter.tsx:760-787`）只影响该次操作，候选模型按能力过滤（`:760-763`）。
- **工具栏**：composer 工具栏支持固定、取消固定、拖拽重排和恢复默认。

### 4.2 多模型提及模式：如何触发"多模型同时回复"（UI 侧）

提及模型的选中态由专用 hook 管理（`src/renderer/components/composer/variants/chat/useChatMentionedModels.ts`）：非多选模式下选中一个模型会同步给单模型选择（`:109-122`，同步点 `:117-119`），多选模式下只更新提及模型数组、不触发单模型切换（`:112-115`）。选中模型以 `mentionedModels.map(m => m.id)` 进入请求 payload，主进程据此解析并并行执行（执行语义见对话请求与上下文笔记 9、8）。

### 4.3 发送前配置与请求的交界

四类发送前配置的最终去向见对话请求与上下文笔记 9，此处只记录各配置在渲染侧的落点：

- 知识库选择：`withKnowledgeScopePart`，`ChatComposer.tsx:1344`
- 附件：file parts，`ChatComposer.tsx:1365-1368`
- 联网开关：`assistant.settings.enableWebSearch` 进入请求能力体 `capabilityBody`，`useChatWriteActions.ts:296-301`
- 推理强度：`reasoningEffort` 独立字段，`useChatRuntimeState.ts:290-305`

工具面板"要不要显示某工具"由 `ComposerToolRuntimeHost` 与各 `defineTool` 在渲染期决定，实际携带由主进程模型能力判定（同上一节链接）。

## 5. 发送、排队、流式反馈与停止

- **发送入口**：发送按钮把 UI 提交转成运行时发送，再走 IPC 流式打开接口（`useChatRuntimeState.sendMessage` → `ai.stream.open`，执行链见对话请求与上下文笔记 1）；发送期间显示发送中状态（`ChatComposer.tsx:1361`）；打开接口返回 `blocked` 时弹 toast 提示（`useConversationTurnController.ts:61-68`）。
- **排队**：流式期间继续输入会进入 follow-up 队列（`ChatComposer.tsx:1401-1414`），条目显示在底部小面板 `QueuedFollowupsDock`（steer/编辑/删除/暂停按钮均有 `aria-label`，`QueuedFollowupsDock.tsx:97-165`），topic 空闲时自动 drain；reserved-branch 条目在流式期间被禁用（`ChatComposer.tsx:1418-1421`）。
- **生成反馈**：流式尾部以 live 层渲染（历史/live 两层切分由 `useMessageStreamingLayers` 提供 `streamingLayers`，渲染实现见消息渲染器笔记）；消息区初始加载骨架特意延迟 160ms 防闪烁（`MessageListLoading.tsx:4-6`，容器带 `aria-busy` `:21`）。
- **暂停/停止**：Composer 外围有暂停、编辑定位、取消编辑、展开高度等工具按钮（均有 `aria-label`，`ComposerSurface.tsx:2095-2201`）；停止入口的执行链（`ai.stream.abort` → `AbortController` → AI SDK signal）见对话请求与上下文笔记 7；停止/暂停按钮状态与真实任务状态（`ActiveStream.status`）的对应关系未运行验证。
- **Toast 交点**：Topic 侧导出图片用 `toast.loading({ key, promise, onError })` 再各自 success/error（`Topics.tsx:362` 附近）；复制代码等操作的 toast 反馈属于通用界面盘点，不统计。

## 6. 消息操作、分支与版本导航

### 6.1 消息操作清单与可用性

`messageMenuBarActions.tsx` 集中注册消息操作清单（各操作注册点见下表），每个操作带翻译 label 与可用性判定（如编辑 `:423`、新建分支 `:439`），流式期间部分按钮整体禁用（`messageMenuBarConfig.ts:24` 的 `STREAMING_DISABLED_BUTTON_IDS`）。

| 操作 | 注册点（`messageMenuBarActions.tsx`） |
| --- | --- |
| 编辑 / 复制 / 重新生成 / 指定模型重新生成 | `:291` / `:303` / `:311` / `:322` |
| 翻译 / 点赞 / 保存到笔记/知识库/文件 | `:334` / `:358` / `:370,461-486` |
| 删除 / 更多菜单 / 新建分支 / 多选 | `:382` / `:410` / `:434` / `:448` |
| 导出（图片/Markdown 含 reasoning/Word/Notion/语雀/Obsidian/Joplin/思源） | `:493-571` |
| 复制纯文本/图片 | `:576-587` |

**删除可用性**：语义由 `ChatWriteContext.ts:21` 的 `getMessageDeleteAvailability` 与 `useChatWriteActions.ts:210-220` 定义：消息未加载 → 禁用并提示"消息未加载"；生成中（`status='pending'`）→ 禁用并提示"正在生成"（tooltip 文案映射见 `messageDeleteAvailability.ts:6-13`）。数据侧（首轮可删、组删除只删兄弟回复）见会话与消息管理笔记 1.2。
**可用性判定机制**：几乎所有 action 的 `availability` 都在判断 `!!actions.xxx`——能力是否出现完全由适配器注入的字段决定（6.2），不是 if/else 页面模式分支。

### 6.2 适配器注入的操作面：Home 可写、Agent 只读 + agent 专属

- 能力以**可选字段对象**注入，由两个 hook 分别组装通用能力（导出/复制/通知等）与按消息的可变能力（`useMessageListAdapterCapabilities.ts:30`、`useMessageLeafCapabilities.ts:112`）；`messageListProviderBuilder.ts` 的三个 pick 函数（`pickMessageLeafState/pickMessageLeafActions/pickMessageHeaderActions`）只把存在的字段塞进 state/actions（`:24,44-57,66`）。
- **Home 适配器**（`homeMessageListAdapter.tsx`）：无只读标志；注入全套写操作（完整清单见本节末尾源码列表，`:839-876`），全部经由 `requireChatWrite('xxx')` 从 `ChatWriteContext` 获取真实实现（该 context 由 `ChatContent.tsx:265` 注入）。
- **Agent 适配器**（`agentMessageListAdapter.tsx`）是可写能力最少的一侧：`actions` 没有编辑、组删除、切换分支、重新生成、翻译等写操作（未注入清单见本节末尾源码列表）；`deleteMessage` 存在，但被 `normalInteractionsEnabled` 门控，仅图片捕获模式之外启用（`:257`）。
- **agent 专属操作**：另多出工作区文件、工具审批、artifact 面板等入口（`respondToolApproval/openArtifactFile/openAgentToolFlow/openInExternalApp/openPath`），相对路径经 `resolveWorkspaceFilePath` 解析到 agent workspace 目录（`:123-137`）——这些是 agent 运行时才有的概念，Home 侧没有对应实现。
- **终态兜底**：agent 侧另有 `withTerminalErrorFallback`（`:48-73`）——消息终态是 `error`/`success` 但没有可见 part 时，补一条 `data-error` part，防止 UI 卡在空白/转圈（执行侧语义见对话请求与上下文笔记 6）。
- 总结：不是靠 if/else 判断"我是 Home 还是 Agent"，而是靠两份完全独立的 hook 各自组装一份 `MessageListActions` 对象，字段有没有由各自的业务上下文决定；旧的 `state.readonly: true` 标志机制已不存在。

**本节末尾源码列表**（各适配器注入的写操作集合）：

- Home 注入：`deleteMessage`、`deleteMessageGroup(WithConfirm)`、`editMessage`、`startMessageBranch`、`setActiveBranch`、`regenerateMessage`、`translateMessage`、`abortMessageTranslation`、`removeMessageTranslation`、`renderRegenerateModelPicker`（`homeMessageListAdapter.tsx:839-876`）
- Agent 未注入：`editMessage`、`deleteMessageGroup`、`setActiveBranch`、`regenerateMessage`、`translateMessage`（`agentMessageListAdapter.tsx:399-423`）

### 6.3 分支面板（TopicBranchPanel）：消息树的图形导航

右侧分支面板（`src/renderer/pages/home/components/TopicBranchPanel.tsx`，301 行）把整个 Topic 的消息树渲染成一张 React Flow 图，是"在树上选分支/开分支"的图形入口，与消息列表的 `< i/N >` 兄弟导航并存：

- **数据流**：面板打开时按"拉全量树 → 叠加 live 态 → 生成图"三步组装，头部显示 `branchCount`/`nodeCount` 统计（`:262-268`）。各步实现：
  1. 拉取全量树：`/topics/:topicId/tree`，`depth: -1`（`:63-67`）
  2. 叠加 live 态：`mergeTopicMessageFlowLiveTree`（`:76-79`）
  3. 生成节点/边：`buildTopicMessageFlowGraph` 与 `layoutTopicMessageFlowGraph`（`:80`）

  "DB 树 + live overlay 合并"的数据侧见会话与消息管理笔记 2。
- **图构建**（`topicMessageFlowGraph.ts`）：构建器把树响应中的节点与兄弟组去重合并，并回溯活动路径、给边打状态标签、统计叶子数作为分支数（各函数与定位见本节末尾源码列表）。
- **布局**（`topicMessageFlowLayout.ts`）：用 dagre 做 `rankdir: 'TB'` 分层，节点固定 220×112、nodesep 56/ranksep 96；兄弟顺序按（深度, 创建时间, id）强制排序；边样式按状态着色——活动路径 `var(--success)` 加粗 + `animated`、非活动分支淡色虚线、兄弟边普通虚线（各常量与定位见本节末尾源码列表）。awaiting-input 空分支叶子是持久化树节点（`data.isAwaitingInput`），正常参与 dagre 布局。
- **画布**（`TopicMessageFlowCanvas.tsx`）用 React Flow 配置交互：关闭节点连接/拖拽与双击缩放（`:241-242,252`）、只挂载可视区域节点（`:248`）、缩放范围 0.08–1.4（`:237-238`）；空树渲染空状态（`:208-219`）。叠加层：
  - `MiniMap`（右下，节点按角色着色，`:254-262`）
  - `Controls`（左下，`:263`）
  - 图例（`:253`）
- **视口管理**：初始视口把根节点定位在画布顶部（`getRootFocusViewport`，`:90-97`）；面板 dock/popout 切换（`focusKey` 变化）时重新测量容器并复位视口（`:153-206`）。
- **节点卡**（`TopicMessageFlowNode.tsx`）：显示 role 徽标（user=success 系、assistant=info 系）、模型短名（取最后一段）、两行摘要、状态圆点（pending/success/error/paused）与时间（MM/DD HH:mm）；`isActive` 节点 ring 高亮、非活动分支 `opacity-55`；Handle 仅装饰（各定位见本节末尾源码列表）。
- **预览卡**：悬停 300ms 后 Popover 打开完整预览卡：按需拉取全量消息，复用主消息区的 `MessageContent` 真实渲染；awaiting-input/上下文边界节点不触发（各定位见本节末尾源码列表）。
- **点击**：`handleNodeSelect`（`TopicBranchPanel.tsx:82-114`）按节点类型分三种处理——"点到中间节点 = 切到该分支最新叶子"，与 `< i/N >` 的 `setActiveBranch` 同语义（数据侧见会话与消息管理笔记 4.2）：
  - 点 awaiting-input 活动节点：不动作（`:85`）
  - 点活动路径上的节点：仅定位不切分支（`:86-89`）
  - 其他节点：拉该分支最新叶子后切换 active 节点并刷新（`:91-103`，接口见本节末尾源码列表）
- **右键菜单**（`CommandContextMenu`，`TopicBranchPanel.tsx:280-294`；项定义 `getNodeContextMenuItems`，`:182-247`）有三项：
  - "从这条消息发起新分支"：仅 assistant 节点可见/可用（`:188,199-202`；已无旧的"有 assistant 后代/非当前 active"细化禁用原因）
  - "复制分支到新 Topic"：`POST /topics/:id/duplicate`，始终可用（`:206-215`）
  - awaiting-input 叶子的"删除该分支"：`DELETE /messages/:id?awaitingInputOnly=true`（`:217-228`，服务端守卫见会话与消息管理笔记 4.3）
- **分支草稿工作流**：点"从这条消息发起新分支"（入口 `:116-136`）经分支动作的 `reserveBranch`（`useTopicBranchActions.ts:18-31`）先持久化空 user 叶子（`POST /messages/:id/branches`），流式进行中不挪动 active 指针，分支面板立即显示"等待输入"节点；不再广播 `draft-branch:<anchorId>` 假节点（数据侧语义见会话与消息管理笔记 4.3）。
- **重命名入口**：`Chat.tsx:112-131`（`topic.rename` 命令处理器）弹出 `PromptPopup` 取新名字（数据侧见会话与消息管理笔记 3.2；弹窗库盘点不属于本笔记范围，只记录聊天主链交点）。

**本节末尾源码列表**（分支面板各入口与图构建的定位）：

- `TopicBranchPanel.tsx`：面板打开 `:63-67`、live 叠加 `:76-79`、图生成 `:80`、统计 `:262-268`、`handleNodeSelect` `:82-114`、右键菜单 `:280-294`（项定义 `getNodeContextMenuItems` `:182-247`）、`handleStartNodeBranch` `:116-136`
- `topicMessageFlowGraph.ts`：`buildTopicMessageFlowGraph` `:13-59`（去重合并 `:61-93`）、`collectActivePath` `:137-152`、边打标 `:33-44`、`countBranchPaths` `:95-102`
- `topicMessageFlowLayout.ts`：dagre 分层 `:55-70`、节点 220×112 `:14-17`、nodesep 56/ranksep 96 `:23-29`、OrderConstraint 排序 `:184-205`（比较 `:170-182`）、`toReactFlowEdge` 边样式 `:114-143`（`EDGE_COLORS` `:31-36`）
- `TopicMessageFlowCanvas.tsx`：交互开关 `:241-242,252`、可视区挂载 `:248`、缩放 `:237-238`、`MiniMap` `:254-262`、`Controls` `:263`、图例 `:253`、空状态 `:208-219`、`getRootFocusViewport` `:90-97`、`focusKey` 复位 `:153-206`
- `TopicMessageFlowNode.tsx`：role 徽标 `:25-32`、`getModelShortLabel` `:41-48`、状态圆点 `:34-39`、ring/透明度 `:228-233`、Handle `:241,283`、Popover `:186-200`、预览卡 `TopicMessageFlowNodePreviewCard` `:83-164`（`GET /messages/:id` `:96-99`、`MessageContent` `:151-158`、不触发节点 `:238-240,294`）
- 分支切换接口：`GET /topics/:topicId/path?nodeId=` + `PUT /topics/:id/active-node`（`:91-103`）；新建分支 `POST /messages/:id/branches`（`reserveBranch`，`useTopicBranchActions.ts:18-31`）；复制分支 `POST /topics/:id/duplicate`（`:206-215`）；删除分支 `DELETE /messages/:id?awaitingInputOnly=true`（`:217-228`）

## 7. 多会话、多模型、群聊与后台生成

- **多模型并行**：Composer 提及模型多选 → 主进程 N 个 execution 并行（执行语义见对话请求与上下文笔记 8）；读侧 `bucketAssistantSiblingsByModel` 按 `siblingsGroupId`/模型分桶后，同组兄弟以横向/网格布局展示，消息列表头部有 `< i/N >` 兄弟导航（`useMessageSiblings`，`SiblingsContext.ts:31-45`；数据分桶见会话与消息管理笔记 4.2；布局渲染见消息渲染器笔记"消息分组"）。
- **运行标记**：Topic 列表行的 `ConversationRowStatus` 让用户在侧栏看到哪个会话仍在运行、等待审批或已完成未读（2.1）；切换会话/标签页后 Main 进程仍可继续生成（渲染侧 detach 不 abort、release 不拆 reader，见对话请求与上下文笔记 8）。
- 群聊、子 Agent、后台任务面板的界面区分本次未调查（Agent 会话本身存在独立的会话列表与消息壳，但"多路对话返回对应现场"的完整工作流未展开）。

## 8. Chat UI 状态所有权与同步（含桌面集成）

### 8.1 UI 状态所有权

- **分支草稿已是持久化行**：`Chat.tsx` 旧的 `branchDraftAnchorIdRef`/`branchSendAnchorOverrideIdRef` 三态 ref 状态机已被删除，"从历史节点开新分支"改为 `useTopicBranchActions.reserveBranch` 持久化空 user 叶子 + `fill-reserved` 填充（6.3；数据侧语义见会话与消息管理笔记 4.3）——原先"隐式三态机容易漏清空"的脆弱点随机制移除而消失。
- **live branch 前端状态广播**：`TopicMessageFlowLiveState` 仍是纯前端结构，现在只广播流式中消息（草稿假节点已删除）；分支面板 dock/popout 时视口按 `focusKey` 复位（6.3 画布）。
- **草稿事实源**：按会话缓存于 cacheService（`chatDraftCache`，24h TTL，3.3）；Topic 行草稿指示订阅同一缓存（2.1）。
- **运行状态事实源**：主进程共享缓存键 `topic.stream.statuses.<topicId>`（`useTopicStreamStatus.ts:36`），"本窗口已读"读收条是另一个跨窗口共享键（`:37-39`）——运行指示是跨窗口一致的，不是窗口本地状态。
- **无全局状态库**：parts 分层、overlay、状态广播等全部用 hook/ref + 共享缓存实现，仓库明确不引入全局状态库（`useStableMessagePartsLayers.ts:5-22` 注释）。

### 8.2 桌面端集成：托盘、通知、快捷键

- **托盘**：`TrayService.ts` 在 mac 上根据系统明暗主题切换亮/暗两套托盘图标（`:29`）；点击托盘图标的行为受偏好 `feature.quick_assistant.click_tray_to_show` 控制——开则唤起 QuickAssistant 悬浮窗，关则唤起主窗口（`:61-71`）。
- **托盘无角标**：托盘本身**不显示未读消息数/流式状态角标**，未检索到 `setBadgeCount`/`flashFrame`/`setOverlayIcon` 等角标 API 调用。
- **系统通知**：主进程通知服务（`src/main/services/NotificationService.ts:7-20`）用 Electron 原生通知 API，点击通知会唤起主窗口并广播 `notification.clicked`（`:14-17`）；渲染层发送入口（`src/renderer/services/notification/NotificationService.ts:10-24`）先查 `assistant/backup/knowledge` 三个偏好开关，再决定是否调 IPC 发送。
- **一个值得记录的空路径**：偏好 `app.notification.assistant.enabled` 和对应设置项（"助手回复完成通知"）确实存在，但**全仓库检索不到任何一处 `source: 'assistant'` 的发送调用**——即"助手完成回复时弹系统通知"这个开关目前接不到任何触发点，是个用户能看到、能勾选、但不会生效的空挂钩。实际存在的发送调用点：

  - `BackupService.ts`：6 处 `source: 'backup'`（`:80,150,168,233,251,344`）
  - `useAutoBackupEvents.ts`：1 处（`:57-64`）
  - `useAppUpdateHandler.ts`：`source: 'update'`（`:40-46`）

  另有一条已知 TODO：`NotificationService.ts:17-20` 中 `update` 来源因没有对应偏好键而被静默丢弃。
- **全局快捷键**：`ShortcutService.ts` 按**本地/全局分轨**——带 `global` 标记的快捷键仍在系统级注册（`:44,104`），其余本地快捷键不再注册到系统，而是挂在窗口 `webContents.before-input-event` 事件上按命令解析拦截（含 guest webview 输入，`:173-187`），应用失焦时本地快捷键自然不生效。
- **冲突处理**：快捷键被其他应用占用时仍记录冲突集合并经 IPC 广播给渲染层展示提示（`:243,266` 附近）。
- **标签页导航**：另新增 `tab.next`/`tab.prev` 标签页导航快捷键（`AppShell.tsx:100-101`）。
- **速查表缺失**：仍未找到独立的"快捷键帮助面板/速查表"浮层——只有"设置 > 快捷键"这个静态配置页（`ShortcutSettings.tsx`，导出 `:672`）。

## 9. 键盘、焦点、响应式与关键路径可用性

### 9.1 无障碍：列表完整，输入区有缺口（本次核实两处旧结论）

**做得到位的地方**（有代码实证）：

- `ResourceList`（Topic 列表、Agent Session 列表共用的基础组件）实现标准的 **roving tabindex + `aria-activedescendant`** 模式，容器与行的 ARIA 角色如下；方向键/Home/End/Enter 等键盘操作都有对应测试覆盖并断言该属性正确移动（`__tests__/ResourceList.test.tsx:611-674`）——会话导航这条关键路径的键盘可用性有保障。
  - 容器：`role="listbox"`（`ResourceListVirtual.tsx:554,788`）
  - 行：`role="option"` + `aria-selected`（`ResourceList.tsx:416-417`）
- **消息操作栏按钮都有 `aria-label`**（本次核实为已修复）：按钮组件显式传入 `aria-label`，值为 action 的翻译文本，如"编辑/复制/重新生成"（`MessageMenuBarToolbarRenderers.tsx:83,107`，label 来源 `messageMenuBarActions.tsx:291-412`）；模型选择器、翻译、更多菜单也显式传入（`:292,316,367,424`）。旧结论"默认渲染路径缺 aria-label、只有视觉 Tooltip"已不成立。
- 折叠交互（用户消息折叠、Thinking 块展开/收起）用真实的 `aria-expanded`/`aria-controls`，且是可聚焦、可键盘触发的 `role="button"`（`MainTextBlock.tsx:291-292`、`ThinkingBlock.tsx:115-129`）——但这两个是消息内容组件，渲染细节见消息渲染器笔记。

**实证的缺失**：

- **Composer 输入区本体没有可访问名称**：富文本输入框基于 TipTap 的可编辑组件，可编辑根节点没有 `aria-label`——富文本内核支持可选 `ariaLabel`（`useRichEditor.ts:43,381-382`），但 `ComposerSurface` 调用内核 hook 时未传入、编辑器属性只有 class/style（`ComposerSurface.tsx:1432-1440,1739-1785`）；输入区本体依赖浏览器/TipTap 默认的可编辑语义。
- 输入区外围工具按钮（暂停、编辑定位、取消编辑、展开高度等）都有可访问名称（`ComposerSurface.tsx:2095-2201`）。

### 9.2 键盘主链与响应式

- 输入区键盘操作（发送键配置、历史浏览、Tab 遍历变量、Escape）见 3.1；会话列表键盘（listbox）见 9.1；搜索栏键盘（Enter/Shift+Enter/Esc、输入框自动聚焦）见 2.3；分支面板的键盘操作（树图能否用键盘导航）未核实。
- 响应式：无断点驱动的聊天侧栏自动折叠（1.2）；移动端/小屏布局未调查。

## 10. 设计取舍与已确认边界

- **`ChatComposer.tsx` 单文件复杂度偏高**（1908 行）：`ChatComposerInner` 一个组件本体加上闭包状态混杂了草稿缓存、输入历史导航、编辑会话恢复（含"编辑消息时保存旧草稿、取消编辑时还原"的完整状态机）、mentioned models、reasoning effort 的乐观更新+回滚、queued followups 等好几套独立状态机在同一个函数体内用一堆 ref 协调（3.3）。功能齐全，但可读性/可维护性门槛显著高于单一职责组件。
- **branch draft 的持久化改型**（8.1）：旧的"三态 ref 状态机"被 `reserveBranch` 持久化行取代，原来的脆弱点随机制移除而消失；新机制的代价是"空 user 叶子"需要在渲染与删除/填充路径上做派生判断与守卫（数据侧见会话与消息管理笔记 4.3）。
- **适配器模式的代价与收益**：能力注入（6.2）让"Home 可写、Agent 只读"不需要 if/else 分支，代价是追踪某个按钮为何出现需要跨两个 adapter 文件加能力 hook；`messageListProviderBuilder.ts` 的"只塞存在的字段"（`pickMessageLeafState` 等纯函数）保证 `actions.xxx &&` 判断语义清晰（该文件细节见消息渲染器笔记）。
- **搜索的"数据 + DOM"双轨**（2.3）：粗匹配在已加载数据上、精确高亮在已挂载 DOM 上，虚拟化窗口外的消息可定位但无 DOM 高亮；流式行被排除、未加载页搜不到，是分页 + 数据匹配的固有限制，数据侧影响见会话与消息管理笔记 5。
- **桌面集成缺口**（8.2）：通知空挂钩、托盘无角标、无快捷键速查浮层；Session 列表无拖拽排序（2.2）。
- **类目边界**：本笔记只记录用户工作流与界面状态；树模型与指针语义在会话与消息管理笔记 1/4，流式执行与最终化在对话请求与上下文笔记 5/6，消息壳与 Markdown 渲染在消息渲染器笔记。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性、响应式行为、系统通知需要运行验证（本笔记结论主要来自静态代码）。
- 停止/暂停按钮状态与真实任务状态的对应关系、切走 Topic 后任务收口（见对话请求与上下文笔记 7、8）。
- 草稿粒度已核实为"按会话缓存、跨导航保留"（3.3）；切换 Topic 保留的滚动位置、分支面板键盘操作仍未核实。
- 移动端布局、QuickAssistant 悬浮窗与主窗口的状态同步未调查。

## 12. 关键源码索引

- `src/renderer/pages/home/Chat.tsx`、`ChatContent.tsx`、`ChatMain.tsx`（命令注册、重命名、搜索挂载）
- `src/renderer/pages/home/Tabs/components/Topics.tsx`（拖拽排序、运行指示、草稿指示、空状态）
- `src/renderer/pages/home/components/TopicBranchPanel.tsx`、`src/renderer/components/chat/flow/{TopicMessageFlowCanvas,TopicMessageFlowNode,topicMessageFlowGraph,topicMessageFlowLayout}.ts(x)`
- `src/renderer/components/composer/variants/ChatComposer.tsx`、`ComposerSurface.tsx`、`chat/ChatConversationControls.tsx`、`chat/useChatMentionedModels.ts`、`chat/chatDraftCache.ts`
- `src/renderer/components/chat/messages/list/MessageListSearch.tsx`、`messageSearch.ts`、`messageSearchDom.ts`、`src/renderer/components/FindBar.tsx`、`src/renderer/utils/contentSearch.ts`（会话内搜索）
- `src/renderer/components/GlobalSearch/GlobalSearchPopup.tsx`、`GlobalSearchPanel.tsx`（全局搜索）
- `src/renderer/components/chat/messages/frame/messageMenuBarActions.tsx`、`MessageMenuBarToolbarRenderers.tsx`
- `src/renderer/pages/home/messages/homeMessageListAdapter.tsx`、`src/renderer/pages/agents/messages/agentMessageListAdapter.tsx`
- `src/renderer/components/chat/messages/MessageListProvider.tsx`、`messageListProviderBuilder.ts`、`hooks/useMessageListAdapterCapabilities.ts`
- `src/renderer/components/chat/resourceList/base/ResourceList.tsx`、`ResourceListVirtual.tsx`、`ConversationRowStatus.tsx`（listbox 键盘语义与运行指示）
- `src/renderer/hooks/SiblingsContext.ts`（`< i/N >` 兄弟导航）
- `src/renderer/components/layout/AppShell.tsx`、`src/renderer/pages/home/HomePage.tsx`（标签页、侧栏、最小宽度）
- `src/main/services/{TrayService,NotificationService,ShortcutService}.ts`（桌面集成）
