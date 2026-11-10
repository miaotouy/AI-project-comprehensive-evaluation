# DeepChat 对话导出与分享调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：静态源码局部调查；阅读范围包括虚拟列表窗口化（useMessageVirtualization、useMessageWindow）、历史懒加载分页（messageStore.loadOlderMessages）、Markdown 节点虚拟化、preload 剪贴板实现与相关测试；未运行 Electron 应用、未执行测试
>
> 调查范围：当前问答组与“从顶部到当前消息”的图片复制主链，重点为迭代上限、分页/虚拟化影响、DOM 截图口径、跨平台剪贴板四个方向；不覆盖 Artifact 图片复制、浏览器页面截图、Tape/Trace 导出和会话 JSON 保存
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 提供消息级图片复制，并用同一按钮的短按/长按区分两种范围：短按捕获当前 assistant 消息及其父 user 消息组成的问答组；长按 800ms（键盘为 Shift+Enter/Space）捕获从会话顶部到当前消息。该流程直接对当前 `.message-list-container` 做分段滚动截图，不会重排为独立分享稿；随后在主进程用 Sharp 垂直拼接，增加 DeepChat、版本、模型与 Provider 水印，最终复制到系统剪贴板。

当前主链没有保存文件、分享链接、预览编辑器或生成历史。补充确认四点：30 段迭代上限命中时是静默截断（拼接已有分段并返回成功，无专用错误）；“从顶部”的起点受历史懒加载分页与消息窗口化约束，捕获期间不会自动加载更早历史；截图口径是当前 DOM 视口截图（`capturePage`），捕获期间关闭 Markdown 节点级虚拟化；剪贴板写入无平台分支、无错误检查，且成功提示先于实际复制显示。

## 系统边界与完整主链

```text
消息工具栏图片按钮
  -> 短按 copyImage / 长按 copyImageFromTop
  -> useMessageCapture 计算问答组或顶部到当前消息矩形
  -> 隐藏 .chat-capture-hide 覆盖层
  -> usePageCapture.captureArea 分段滚动并 captureCurrentArea
  -> 主进程 stitchImagesWithWatermark
  -> deviceClient.copyImage 写入剪贴板
  -> 恢复滚动位置、覆盖层和捕获状态
```

## 1. 入口与范围语义

`MessageToolbar` 在鼠标按下后启动 800ms 计时器：到时触发 `copyImageFromTop`；提前松开触发 `copyImage`。键盘 Enter/Space 触发当前问答组，按住 Shift 触发从顶部截图；捕获进行中禁用重复触发（`../../deepchat/src/renderer/src/components/message/MessageToolbar.vue:199-254,284-291`）。

`useMessageCapture` 的范围计算分两类：

- `calculateMessageGroupRect(messageId, parentId)` 查找父 user 节点和当前 assistant 节点，以两者外接矩形作为范围；找不到父节点时退化为当前 assistant 消息矩形；
- `calculateFromTopToCurrentRect(messageId)` 取消息容器中第一个 `[data-message-id]` 与当前消息的外接矩形（`composables/message/useMessageCapture.ts:70-145`）。

这两种范围都依赖当前 DOM。`getTargetRect` 在 `captureArea` 开始时只求值一次（`composables/usePageCapture.ts:179`），后续分段位置完全基于这一次的矩形快照，捕获过程中目标消息被虚拟列表卸载不影响位置计算。

“从顶部”的起点是容器内第一个已挂载 `[data-message-id]`（`useMessageCapture.ts:129-134`），即当前 DOM 中最早的一条已挂载消息；它与会话第一条消息的差距由两层机制决定：

- 历史懒加载：会话打开时只恢复约 100 条消息，更早的历史按每页 100 条游标分页，用户在滚动到顶部时才触发加载。捕获过程中的程序化滚动不会触发分页：滚动监听要求先有用户向上滚动的手势意图，非用户滚动会被视口通知判定为原生滚动而跳过，没有手势意图时也会提前退出。因此长会话的“从顶部”截图覆盖的是已加载页的最早消息，会话起点之前仍有未加载的历史（`ChatPage.vue:437,684-692`；`useChatScrollController.ts:244-263`）。
- 消息窗口化：已加载消息超过 160 条（阈值常量 `MESSAGE_WINDOWING_THRESHOLD`）时启用窗口化渲染，只挂载视口上下各 2400 像素范围内的行，其余区域由前后占位元素填充。捕获滚动时窗口跟随滚动的 rAF 指标同步移动，代码中没有在捕获开始前强制窗口就位的步骤，未挂载区域的占位空白是否进入分段取决于滚动与挂载的时序（运行行为未验证）。消息不超过 160 条时全部挂载，不存在占位空白（`ChatPage.vue:86-107,438`；`MessageList.vue:5-36`；`useMessageVirtualization.ts:81-125`）。

## 2. 分段捕获与垂直拼接

捕获前，模块隐藏所有 `.chat-capture-hide` 元素，等待 Vue `nextTick` 和 60ms，使操作控件不进入图片；无论成功失败，finally 都恢复覆盖层（`useMessageCapture.ts:19-47,156-184`）。

`usePageCapture.captureArea()` 以 `.message-list-container` 为滚动容器，保存原滚动位置和 `scrollBehavior`。默认参数为每段等待 350ms、最多 30 次、扣除 20px 滚动条宽度；它计算目标在滚动内容中的绝对范围，逐段滚动到目标位置，经 `tabClient.captureCurrentArea(rect)` 取得图片数据，完成后恢复原位置（`composables/usePageCapture.ts:154-324`）。

迭代上限收口（代码路径确认，未运行验证）：上限常量 `maxIterations` 默认 30（`usePageCapture.ts:172`，注释“防止无限循环”），调用方未覆盖该值。循环条件为“累计捕获高度小于目标高度且迭代次数未达上限”（`usePageCapture.ts:245-248`）。

命中上限且目标未完成时循环直接退出，之后仅检查已捕获分段是否为空；只要已捕获到分段就继续拼接并返回成功（`usePageCapture.ts:299-320`）。因此超限结果是静默截断：长图只覆盖约 30 个视口高度（约 30 段 × 容器可视高度），没有“部分完成”标记或专用错误码，与触发方式（短按/长按）无关。若某段 `captureCurrentArea` 返回空或抛错，循环同样 break，已收集分段仍会进入拼接（`usePageCapture.ts:279-291`）。

`isCapturing` 防并发，捕获期间再次进入直接返回“正在进行截图”错误（`usePageCapture.ts:159-161`）。

收集到的分段交给 `tabClient.stitchImagesWithWatermark()`。主进程 `ScrollCaptureManager`/拼接实现使用 Sharp 读取每段宽高，取最大宽度和高度总和，居中垂直合成 PNG；带水印版本由 desktop tab 路由承接（`src/main/lib/scrollCapture.ts:275-340`；`src/main/desktop/tab.ts:981-1010`）。

## 3. 水印与交付

截图水印包含：

- 当前主题明暗；
- 应用版本；
- 品牌 `DeepChat`；
- 本地化提示文案；
- 当前消息提供的模型名和 Provider（`useMessageCapture.ts:162-175`）。

`captureAndCopy()` 在拼接成功后调用 `deviceClient.copyImage(imageData)`。preload 将该动作桥接到主进程剪贴板 IPC，最终写入系统剪贴板（`composables/usePageCapture.ts:337-355`；`src/preload/index.ts:8-33`）。当前消息工具栏没有保存文件或系统分享入口，用户需要从剪贴板粘贴到目标应用。

剪贴板交付已移到主进程：`registerClipboardIpc` 创建 `nativeImage`，空图会抛错，合法图再写入 clipboard；preload 以 `ipcRenderer.invoke` 调用并记录异步错误（`src/main/app/clipboardIpc.ts:1-21`、`src/preload/index.ts:8-33`）。该调用仍无平台分支和返回值，截图工作流也不等待成功结果；Electron 负责平台格式转换。

复制入口先等待截图完成，只有捕获成功且返回图片数据时才发起剪贴板写入并返回 true，否则返回 false；它不等待或核对剪贴板写入结果（`src/renderer/src/composables/usePageCapture.ts:341-349`）。写入失败由 preload 捕获并记录日志，捕获工作流没有获得这项失败结果（`src/preload/index.ts:24-27`）。

工具栏的“复制成功”浮层在鼠标松开或键盘触发时就已显示，早于实际捕获与写入完成，提示时机由用户操作决定；捕获调用与提示入口分别见 `src/renderer/src/composables/message/useMessageCapture.ts:160-186`、`src/renderer/src/components/message/MessageToolbar.vue:242-264`。

Web 平台路径不存在：renderer 的 `getDeepchatBridge` 在无 `window.deepchat` 时直接抛错（`renderer/api/core.ts:8-14`），`window.api` 仅由 Electron preload 暴露（`src/preload/index.ts:114-133`），本快照未找到浏览器端 mock 或独立 Web 构建目标。

## 4. 富内容与边界

截图对象是现场消息 DOM，内容口径不取自原始数据。每段由主进程 `webContents.capturePage(rect)` 抓取视口位图（`src/main/desktop/tab.ts:958-968`），因此进入图片的是“当前渲染后的可见内容”：已渲染的 Markdown/代码、流式输出进行到一半的文本、折叠/展开的当前 UI 状态，均按捕获瞬间的 DOM 呈现。捕获期间有两项针对性处理：

- 捕获期间关闭 Markdown 节点级虚拟化：列表组件据此把节点虚拟化开关置为关闭，并把活跃节点上限归零，保证已挂载消息的节点全部渲染进截图；平时静态长文最多保留 260 个活跃节点（`MessageList.vue:103-105`；`MarkdownRenderer.vue:243-249`）；
- 工具栏在捕获期间整体不渲染，加上 `.chat-capture-hide` 覆盖层隐藏的顶栏、输入区与只读工具交互浮层，操作控件不会进入截图（`MessageToolbar.vue:2`；`ChatPage.vue:9,127,141`；`useMessageCapture.ts:33-53`）。

`.chat-capture-hide` 是明确的截图排除契约；除此之外，本次没有找到针对敏感内容、system prompt、路径或工具参数的专用过滤。

代码块由 Markstream 的 `monaco` codeRenderer 承担（`MarkdownRenderer.vue:225-227`），本轮未找到代码块级折叠契约；工具调用详情、think 块等的折叠状态（`useMessageWindow.ts:29-37` 以“折叠 pill/think 头”为默认估计高度）按现场状态入图。流式输出期间图片按钮仍可用（`MessageToolbar.vue:82-83` 仅以 isCapturingImage 禁用），此时截图会捕获未完成文本。

截图直接使用现场 DOM，没有独立渲染器、内容配置面板或视觉配置面板。水印由程序固定组装，用户不能在该工作流内选择背景、布局、宽度、倍率或水印字段。当前 DOM 中折叠的工具内容是否保持折叠，取决于现场 UI 状态。

Artifact 的 `copyAsImage()` 也复用页面捕获能力，但其导出源是独立 Artifact 对象，归生成式输出与运行时。本篇对话图片结论不重复计数。

## 5. 可靠性、历史与持久化

除截图外还有一条纯文本导出链：Nowledge Mem 导出走插件连接，导出前先取目标连接再加载会话，取不到就返回“选择连接”错误；提交时把该连接随 thread 一起传入，连接检测在插件侧 verify（`src/main/exporter/index.ts`、`src/main/exporter/nowledgeMemClient.ts`）。用户消息文本在导出时会把会话引用的内联项拼进正文，避免导出稿丢失“引用了哪个会话”的信息（`src/main/exporter/formats/userMessageText.ts`、`@shared/sessionReferences`）。

- 并发保护：捕获进行中再次进入会直接被拒绝，返回“正在进行截图”错误（`usePageCapture.ts:159-161`）；
- 状态恢复：捕获在 finally 中恢复滚动位置与滚动行为，消息层另行恢复被隐藏的覆盖层；
- 失败处理：单段捕获失败会结束循环，已收集的分段仍可能进入拼接，是否产出部分图片没有显式完成度标记（`usePageCapture.ts:279-291,299-320`）；
- 迭代上限：最多 30 次，命中上限时静默拼接已有分段，没有截断错误（详见第 2 节）；
- 剪贴板写入：空图会被拒绝并记录错误，截图工作流不等待这个 Promise，没有重试或专用的用户失败反馈（见第 3 节）；
- 测试覆盖：
  - `test/renderer/composables/usePageCapture.test.ts` 验证分段裁剪与拼接调用参数；
  - `test/renderer/composables/useMessageCapture.test.ts` 以 mock 验证两种范围计算路径；
  - `test/main/routes/dispatcher.test.ts:5923-5959` 验证路由接线；
  - 迭代上限、分页、剪贴板与平台行为没有测试。
- 没有应用内图片历史、预览、版本或持久化对象。

## 6. 设计取舍与已确认边界

- 短按/长按在一个紧凑入口中提供“当前问答组”和“截至当前的会话长图”两种常用范围。
- 分段捕获绕开单一超长 Canvas 的直接 DOM 转换限制，但依赖滚动期间现场稳定和每段延迟。
- 直接捕获当前 UI 意味着图片就是现场渲染结果，同时也把折叠状态、已挂载范围和主题现场带入结果。
- 输出只进剪贴板，交付链简短，但没有文件管理、版本比较和远端分享治理；Nowledge Mem 文本导出依赖外部插件连接，属于可选的第三方交付面，其连接状态与凭据由插件维护。

## 7. 未验证事项

- 长会话超过 30 个分段后的实际长图内容（代码路径已确认静默截断，未运行验证拼接出的部分长图外观与提示表现）。
- 捕获期间新消息流入、消息高度变化或用户切换会话时的行为。
- 窗口化渲染下捕获滚动与窗口挂载/测量的时序：未挂载区域是否以占位空白进入分段、捕获中行高测量（ResizeObserver + rAF 批量）是否导致分段内容偏移；≤160 条消息时不涉及。
- “从顶部”起点与真实会话起点的差异程度（100 条初始加载 + 每页 100 条懒加载），以及到达已加载页顶后截图是否仍继续滚动进入占位空白。
- Markdown、代码、表格、工具卡、图片和本地附件的分段接缝与视觉保真，以及折叠块在截图中的实际呈现。
- Nowledge Mem 插件的连接选择、verify 与提交在真实环境中的表现未运行验证。
- 剪贴板 IPC 失败后的实际用户反馈，以及 Windows/macOS/Linux 各平台 PNG 复制的格式兼容性差异与高 DPI 位图尺寸。
- 捕获失败后已有分段是否可能生成部分长图；本次未运行错误场景。

## 8. 关键源码索引

- `src/renderer/src/components/message/MessageToolbar.vue`
- `src/renderer/src/components/chat/MessageList.vue`
- `src/renderer/src/composables/message/useMessageCapture.ts`
- `src/renderer/src/composables/usePageCapture.ts`
- `src/main/lib/scrollCapture.ts`
- `src/main/desktop/tab.ts`
- `src/preload/index.ts`
- `src/main/app/clipboardIpc.ts`、`src/shared/clipboardChannels.ts`
- `src/renderer/src/features/chat-page/ChatPage.vue`（分页触发与窗口化接线、捕获隐藏覆盖层）
- `src/renderer/src/features/chat-page/composables/useMessageVirtualization.ts`（消息窗口化渲染窗口）
- `src/renderer/src/composables/message/useMessageWindow.ts`（行高估计与测量，折叠块默认高度）
- `src/renderer/src/stores/ui/message.ts`（`loadOlderMessages` 历史分页）
- `src/renderer/src/components/markdown/MarkdownRenderer.vue`（节点级虚拟化开关）
- `test/renderer/composables/usePageCapture.test.ts`、`useMessageCapture.test.ts`（现有测试覆盖）
