# Cherry Studio 对话导出与分享调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：静态源码局部调查；本轮重点为分支消息（siblings）的最终显示、Agent 表面一致性（live 与 capture 两端组件与资料来源）与运行保真（流式/工具/富内容、32767px 边界、长图拼接）；未运行 Electron 应用或实际导出图片
>
> 调查范围：Topic 与单消息的 PNG 复制/保存、离屏完整列表、长内容捕获、资源内联和内容过滤、siblings 取舍、Home 与 Agent 两个消息表面的截图一致性；不覆盖 Markdown/备份导出、Notes 图片导出和远端分享
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的对话图片导出以**离屏复刻真实消息列表**为核心，并且存在**两条捕获路径**：Topics/会话列表菜单把请求投递到 action bus，由 160ms 后挂载的专用捕获宿主（`TopicImageCaptureHost`/`AgentSessionImageCaptureHost`）分页读取完整数据，在屏幕左侧 10000px 外建立固定宽 960px、非交互的完整 `MessageList`；另一类菜单（已确认历史记录面板 `AssistantHistoryRecords`，走事件默认处理器而非 action bus）则直接触发事件，由当前挂载的 live 列表响应，在其自身隐藏的捕获表面上执行。两条路径最终都调用相同的捕获工具，使用 html-to-image 把完整滚动内容转换为单张 Canvas，然后复制 PNG 或保存 PNG。

**siblings 最终显示已走通**：数据层在投影时就按 `modelId` 分桶，每个模型桶只保留一个气泡（活动成员或最新兄弟），用户分支只保留 on-path 那条（`useTopicMessages.ts:104-122`）。活动分支标记透传到列表项（`metadata.isActiveBranch`，`messageListItem.ts:58`）；组的 captureMode 下初始选中优先活动分支且跳过选中同步（`MessageGroup.tsx:106-142`），fold 布局只显示选中气泡（其余隐藏，同时被捕获过滤器排除），horizontal/grid 布局则显示组内全部气泡。

**Agent 表面一致性成立**：live 与 capture 复用同一组件树（`MessageList → MessageGroup → MessageFrame → MessageHeader`）。

名称/头像来源一致：消息头优先取发送时冻结的 `messageSnapshot`，其次取 provider 的 `assistantProfile`（`MessageHeader.tsx:43-64`）；两端的 profile 推导也一致（Home 端 `useAssistant(topic.assistantId)`，Agent 端 `activeAgent.name + getAgentAvatarFromConfiguration`）。

captureMode 只通过 adapter 层面禁用交互动作，并通过 `inert`/`pointer-events-none` 屏蔽交互，不改变渲染来源。

**运行保真**：图片内容来自持久化数据的完整快照（capture 宿主没有 streamingLayers），流式中间态不会进入图片；Markdown、代码块、工具调用由同一批真实组件渲染后被 html-to-image 克隆捕获；单 Canvas 无拼接，任一维度超过 32767px（CSS 像素）即显式拒绝；DPR 相乘后实际画布尺寸可能超出该上限（推断）。捕获前后无字体/图片加载等待，远端图片在未加载完成时可能以透明占位出现（推断）。

## 系统边界与完整主链

```text
Topics/会话列表菜单“导出图片/复制图片”
  -> requestTopicImageAction(topic, { emit: false }) 入 bus
  -> 160ms 后挂载 TopicImageCaptureHost / AgentSessionImageCaptureHost
  -> 分页读取完整消息（Topic: includeSiblings; Agent: /agent-sessions/{id}/messages）
  -> projectBranchMessagesToUI 投影消息与活动分支标记（按模型桶坍缩）
  -> 屏外 MessageImageCaptureHost + MessageList 完整渲染
  -> 隐藏捕获表面 data-topic-image-capture
  -> captureScrollable / captureScrollableAsDataUrl
  -> 复制 PNG Blob / saveImage 保存 PNG Data URL

使用事件默认处理器的菜单（如历史记录面板 `AssistantHistoryRecords`）
  -> EventEmitter.emit(COPY_TOPIC_IMAGE / EXPORT_TOPIC_IMAGE)
  -> 当前挂载的 live MessageList adapter 事件监听
  -> live 列表自身的隐藏捕获表面（同一 executeTopicImageAction）
```

两条路径共享 `executeTopicImageAction` 与 `captureScrollable*` 工具。单条消息另有直接捕获消息容器的命令：`message.copyImage` 和 `message.exportImage`，复用相同工具（`../../cherry-studio/src/renderer/components/chat/messages/frame/messageMenuBarActions.tsx:225-252`）。

## 1. Topic 数据抽取、分支取舍与离屏投影

话题捕获以每页 200 条循环读取 `/topics/{id}/messages`（参数为 `includeSiblings: true`），收集全部分页后反转页序、展平，再经 `projectBranchMessagesToUI()` 投影并过滤不可渲染的会话消息（`pages/home/messages/TopicImageCaptureHost.tsx:24-38`）。

**分支取舍发生在数据层**。`flattenBranchMessages()` 的规则（`hooks/useTopicMessages.ts:104-122`）：

- 用户消息：直接只保留 `item.message`（on-path 那条），离屏用户分支全部不进入列表；
- 助手消息：先按 `modelId` 分桶，每个桶只取一个显示成员——桶内优先活动成员，否则取 `createdAt` 最新的兄弟；再按桶首条消息时间排序。

因此同一模型的重生成队列（1 个桶 N 个兄弟）在图片中只有一条气泡（活动分支或该模型桶的最新兄弟）；纯多模型组（N 个桶各 1 条）保留 N 条气泡。`isActiveBranch` 标记 = `message.id === item.message.id`。

投影函数把共享消息转成 UI 消息并写入 `metadata.isActiveBranch`（`hooks/useTopicMessages.ts:305-319`），经列表项转换透传为活动分支标记（`utils/messageListItem.ts:58`）。live 聊天列表与 capture 宿主使用同一投影（`useChatRuntimeState.ts:117` 的消息即投影后的 UI 消息），因此两条捕获路径的分支口径一致。

**DOM 层取舍（captureMode）**：`MessageGroup` 在 captureMode 下跳过选中状态重同步（`MessageGroup.tsx:114-115`），初始选中优先活动分支，其次按 fold 选中/处理中状态，最后取末条（`MessageGroup.tsx:42-51,106-109`）。

fold 布局只显示选中气泡（`MessageWrapper` 的 `[&.fold]:hidden` + `[&.fold.selected]:inline-block`，`MessageGroup.tsx:459`），未选气泡为 `display:none`，同时被捕获工具的隐藏节点过滤器排除（`utils/image.ts:190-204`）。

horizontal/grid 布局渲染组内全部气泡，样式来自偏好设置 `chat.message.multi_model.style`（`messageGroupLayout.ts:11-19`），capture 不强制 fold。

`MessageImageCaptureHost` 定位在 `left:-10000px`，宽度固定 960px、容器本身高度 1px 且 overflow hidden，并用 `aria-hidden`、`inert`、`pointer-events-none` 屏蔽交互（`components/chat/messages/MessageImageCaptureHost.tsx:13-35`）。

宿主内部仍挂载完整 `MessageListProvider + MessageList`。捕获对象是消息列表内部仅在动作排队期间渲染的隐藏表面：`data-topic-image-capture` 的 fixed 定位 div，逐组非虚拟化渲染全部消息分组（`MessageList.tsx:810-832`）。虚拟列表不参与捕获。

## 2. 捕获与长图生成（运行保真）

`MessageList` 收到 capture action 后等待两帧布局，再执行：

- `copy`：`captureScrollable()` -> Canvas -> PNG Blob -> `copyImage`；
- `export`：`captureScrollableAsDataUrl()` -> PNG Data URL -> `saveImage(topic.name, data)`（`components/chat/messages/MessageList.tsx:472-499,570-603`）。

`captureScrollable()` 读取元素完整 `scrollWidth/scrollHeight`，不受当前视口尺寸限制。主要边界包括（`renderer/utils/image.ts:170-244`）：

- 总宽或总高超过 32767px 时直接返回 `dimension_too_large` 错误；判定发生在 CSS 像素层（`scrollWidth/scrollHeight`），而 `pixelRatio: window.devicePixelRatio` 会进一步放大最终画布——DPR>1 时实际画布尺寸可能先撞上浏览器 canvas 上限（推断，未运行验证）；
- `data-html-artifact` 节点被过滤，交互 HTML Artifact 不进入图片；
- `display:none` 和计算样式隐藏的节点被过滤（与 fold 布局的隐藏分支形成双重排除）；
- 本地 `file://` 图片源先由 `inlineLocalImageSources()` 临时内联（经 IPC `file.read` 读文件转 Data URL），完成后恢复；
- 背景取 CSS `--background`，像素倍率使用 `window.devicePixelRatio`；
- 高度、overflow、position 和滚动条样式只在**根元素**上被临时覆盖为完整展开状态，后代容器（如 horizontal/grid 布局的内部滚动容器）的样式未被改写；
- 先执行一次 `htmlToImage.toCanvas()` 预热资源缓存并销毁暖机 Canvas，再正式生成。

该实现生成单 Canvas 长图，**没有**分段捕获后拼接的策略；32767px 上限是显式失败边界。系统内唯一带缩放降级的捕获是 `captureScrollableIframe`（`utils/image.ts:275-470`，超过 32767px 时按比例缩小），但它只被 HTML Artifact 预览弹窗（`CodeBlockView/HtmlArtifactsPopup.tsx:155-162`）用于 Artifact 自身导出，不在对话导出链路内。

**动态内容口径**：capture 宿主不挂流式层（`TopicImageCaptureHost` 传入的 provider value 无 `streamingLayers`），消息列表直接用已持久化的 parts 渲染（`MessageList.tsx:785-788`），图片内容 = 分页读取时已持久化的快照；正在流式生成的消息（`status: pending`）在图片中只会呈现为当时已写入的内容（推断）。

Markdown、代码块、工具调用卡、reasoning 与附件由与聊天现场完全相同的 `MessageFrame`/parts 组件渲染为 DOM，再由 html-to-image 克隆捕获。

克隆前没有字体就绪或图片加载等待（对比 iframe 捕获路径有显式字体内联与懒加载图片强制 eager，`utils/image.ts:402-425`），远端图片在捕获时未加载完成会以透明占位（`imagePlaceholder`）呈现（推断）。

## 3. 单消息图片与完整 Topic 图片

消息操作栏的 `message.copyImage`/`message.exportImage` 直接捕获当前消息容器，保存文件名由消息标题生成；Topic 级操作则使用屏外完整列表，文件名来自 `topic.name`（`messageMenuBarActions.tsx:225-252`；`pages/home/messages/homeMessageListAdapter.tsx:918-925`）。

两条捕获路径的图片宽度来源不同：离屏宿主路径的捕获表面宽度 = 宿主内虚拟列表容器的 `clientWidth`（固定 960px 宿主），聊天侧 live 路径 = 当前聊天列的实际宽度（`MessageList.tsx:501-512` 取 `scrollContainerRef.current.clientWidth` 注入捕获表面）。因此同一 Topic 从两个入口导出的图片宽度可能不同（代码层面已确认，实际像素差需运行验证）。

两者都复用消息实际组件和主题，不提供选区、排序、布局、背景、水印或品牌条编辑。Topic 级范围是项目负责组装的完整消息投影，单消息级范围是当前消息卡；没有发现介于两者之间的任意多选图片分享稿。

## 4. 富内容、附件与安全边界

复用真实 `MessageList` 有利于保持 Markdown、工具卡、reasoning、附件和消息壳的一致表达。但导出 sink 做了明确差异化：交互 HTML Artifact 被排除（`data-html-artifact` 过滤），说明聊天可执行内容不会原样进入静态图片。其他 Artifact、远端图片、音视频和超宽表格的降级未运行验证。

captureMode 的表面对 live 现场还有其他 DOM 差异（均为样式类代码事实，实际图片效果未运行验证）：

- 多模型组的**组菜单栏**（布局切换图标、fold 模式模型标签列表、删除/重试按钮）不感知 captureMode（`MessageGroup.tsx:386-400` 无条件渲染组菜单栏，组件本身无 capture 分支），会一并进入图片；Home 端 capture adapter 仍提供删除确认与重试动作（`homeMessageListAdapter.tsx:868-869`），删除按钮不受删除可用性判断限制（capture 下该动作未提供，`homeMessageListAdapter.tsx:863`），呈可用外观；
- grid 布局的卡片固定 300px 高、内容容器 `overflow-hidden`（`MessageGroup.tsx:438,459`），horizontal 布局内容容器 `max-h-[calc(100vh-350px)]` 且 `overflow-y-auto`（`MessageGroup.tsx:438,459`），而 `captureScrollable` 只展开根元素，后代裁剪容器会把长内容截断在图片内；
- 这些布局样式由偏好设置 `chat.message.multi_model.style` 决定，capture 不强制 fold，因此用户当前的 grid/horizontal 设置会直接影响图片保真。

本地图片在捕获前临时内联，降低了 Electron 本地协议无法被 `html-to-image` 读取的风险。远端图片使用 `cacheBust` 和透明占位配置；CORS 失败或未加载完成时最终是占位、遗漏还是整体失败需要运行确认。

本次没有找到图片导出专用的敏感信息扫描或字段开关。图片表达继承当前消息列表的可见内容；是否隐藏 system、路径、工具参数和 reasoning 由上游消息投影与 UI 配置决定。Agent 会话数据在导出前经 `withTerminalErrorFallback` 补齐错误消息（`agentMessageListAdapter.tsx:48-76`），错误/空回复消息在图片中会显示统一的 `data-error` 占位（该 adapter 逻辑同时作用于 live 与 capture）。

## 5. Agent 表面一致性（live 与截图端）

**组件复用**：capture 端完整复用 live 的组件树（`MessageList → MessageGroup → MessageFrame → MessageHeader` 与 parts 渲染），没有独立渲染器。

差异只在两层：adapter 层以 `imageActionConsumer: 'capture'` 关闭交互（无删除、无翻译、无 runtime 绑定等，`homeMessageListAdapter.tsx:106,240,863-871`；`agentMessageListAdapter.tsx:257,320-342`）。

渲染层 `MessageGroup` 的 `captureMode` 跳过选中同步、flow 导航监听、runtime 绑定和元素注册等交互副作用（`MessageGroup.tsx:114-115,179,210,237`）；宿主的 `inert` + `pointer-events-none` 进一步屏蔽交互，但不改变表达内容。

**名称/头像来源一致**：消息头显示优先级为“发送时冻结的 `messageSnapshot`（name/emoji）→ provider meta 的 `assistantProfile`”（`MessageHeader.tsx:43-64,94-109`）。

Home 端 live 与 capture 都从 `useAssistant` 取助手实体（live：`Chat.tsx:82`；capture：`TopicImageCaptureHost.tsx:41`，且不加载默认模型），provider meta 记录助手名称与头像（`homeMessageListAdapter.tsx:918-925`）。

Agent 端 live（`AgentSessionMessages.tsx:66-75`）与 capture（`AgentSessionImageCaptureHost.tsx:60-75`）都用同一推导 `activeAgent.name + getAgentAvatarFromConfiguration`；模型徽标同样来自消息自身的模型字段（`messageListItem.ts:29-44`），与现场一致。

**不进入图片的部分**：Agent 的提示词（system prompt）与工具配置不渲染在消息列表 DOM 中，因此也不存在于图片里——"一致"的范围是名称、头像、模型与消息内容本身。Agent 会话捕获数据走独立分页接口（`getAgentSessionMessagesForExport`，`services/agentSessionExport.ts:75-99`，每页 200 条，无 siblings 概念），经 `exportViewToUIMessage` 映射后复用同一列表（`useMessageImageCaptureMessages.ts:22-25`）。

## 6. 生成历史、分享与持久化

每次动作即时捕获并交给剪贴板或保存 API，没有截图预览、应用内结果列表、版本比较或过时标记。生成结果不绑定 Topic 数据库，也未形成远端分享对象。复制和保存之外的系统 Share Sheet、访问控制、撤销与过期不适用。

## 7. 设计取舍与已确认边界

- 离屏完整列表避免虚拟列表、当前滚动位置和当前页面未加载完整数据导致长图缺段。
- 两条捕获路径（live 隐藏表面 vs 离屏宿主）共用同一执行器与工具函数；离屏宿主总是全量分页拉取，live 路径捕获的是当前内存中已加载的数据（live 与宿主使用同一扁平化投影，分支口径一致）。
- 分支取舍前置在数据投影层：用户分支只留 on-path，助手分支按模型桶坍缩为单气泡；fold 布局下未选中分支同时被 CSS 隐藏与捕获过滤器排除。图片语义 = 每模型一个气泡的活动路径表达。
- 复用真实消息组件提高现场与导出的表达一致性，但也使导出依赖消息列表的分支过滤、偏好布局（grid/horizontal 裁剪风险）和 UI 状态（组菜单栏进入图片）。
- 单 Canvas 捕获实现直接，尺寸超过 32767px（CSS 像素）时明确拒绝，不做分页、缩放或拼接降级；系统内仅有 HTML Artifact 的 iframe 路径做缩放降级，不在对话链路内。
- 交互 HTML Artifact 被主动排除，静态图片不会尝试执行或拍下该运行表面。
- 当前实现属于“复刻并交付”，不提供“编辑分享稿再生成”的流程。

## 8. 未验证事项

- horizontal/grid 布局下内部滚动容器的实际截断效果，以及组菜单栏（布局图标、删除/重试按钮）在成品图片中的视觉呈现（运行验证）。
- 32767px 边界附近的错误反馈、内存占用和取消行为；DPR>1 时画布实际尺寸先于 CSS 检查撞上限的推断。
- 流式生成进行中导出时，pending 消息在图片中的实际表达（数据层已确认无 streamingLayers）。
- 远端图片未加载完成/CORS 失败时的最终呈现（占位、遗漏或整体失败）；`fonts.ready` 缺失对字体渲染的影响。
- 历史记录面板（`AssistantHistoryRecords` 使用事件默认处理器）触发图片动作时，若对应 Topic 的 live 列表未挂载，事件无人消费是否导致请求悬空。
- 工具调用、reasoning、附件、表格和非 HTML Artifact 的实际保真。
- Windows/macOS/Linux 的剪贴板与保存文件结果；两条入口（聊天菜单 vs 列表菜单）产出图片的宽度差。
- 图片捕获相关测试虽存在，本次未执行测试或构建。

## 9. 关键源码索引

新增关键入口：

- `src/renderer/components/chat/messages/list/MessageGroup.tsx`（captureMode 行为、fold 显隐、组菜单栏）
- `src/renderer/components/chat/messages/utils/messageListItem.ts`（`isActiveBranch` 透传）
- `src/renderer/components/chat/messages/frame/MessageHeader.tsx`（名称/头像来源优先级）
- `src/renderer/pages/home/messages/homeMessageListAdapter.tsx`（live/capture 双模式、事件消费）
- `src/renderer/hooks/chat/useTopicMenuActions.ts`（事件默认处理器）
- `src/renderer/hooks/useImageCaptureTargets.ts`（宿主挂载延迟与取消）
- `src/renderer/pages/agents/messages/AgentSessionImageCaptureHost.tsx`
- `src/renderer/services/agentSessionExport.ts`（Agent 会话导出数据源）
- `src/renderer/pages/agents/messages/agentMessageListAdapter.tsx`（`withTerminalErrorFallback`、capture 模式）
- `src/renderer/utils/message/messageGroupLayout.ts`（多模型布局样式生效规则）

既有索引保留（本轮补充了定位说明）：

- `src/renderer/pages/home/messages/TopicImageCaptureHost.tsx`
- `src/renderer/pages/home/messages/topicImageActionBus.ts`
- `src/renderer/components/chat/messages/MessageImageCaptureHost.tsx`
- `src/renderer/components/chat/messages/MessageList.tsx`（隐藏捕获表面 `data-topic-image-capture` 与双路径执行器）
- `src/renderer/components/chat/messages/frame/messageMenuBarActions.tsx`
- `src/renderer/hooks/useTopicMessages.ts`（`flattenBranchMessages` 分支坍缩规则、`projectBranchMessagesToUI`）
- `src/renderer/utils/image.ts`（`captureScrollable`、`captureScrollableIframe`）
- `src/renderer/components/chat/messages/__tests__/MessageList.test.tsx`
