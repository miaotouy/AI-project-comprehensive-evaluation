# DeepChat 对话导出与分享调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：静态源码局部调查；本轮补充阅读虚拟列表窗口化（useMessageVirtualization/useMessageWindow）、历史懒加载分页（messageStore.loadOlderMessages）、Markdown 节点虚拟化、preload 剪贴板实现与相关测试；未运行 Electron 应用、未执行测试
>
> 调查范围：当前问答组与“从顶部到当前消息”的图片复制主链，重点为迭代上限、分页/虚拟化影响、DOM 截图口径、跨平台剪贴板四个方向；不覆盖 Artifact 图片复制、浏览器页面截图、Tape/Trace 导出和会话 JSON 保存
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 提供消息级图片复制，并用同一按钮的短按/长按区分两种范围：短按捕获当前 assistant 消息及其父 user 消息组成的问答组；长按 800ms（键盘为 Shift+Enter/Space）捕获从会话顶部到当前消息。该流程直接对当前 `.message-list-container` 做分段滚动截图，不会重排为独立分享稿；随后在主进程用 Sharp 垂直拼接，增加 DeepChat、版本、模型与 Provider 水印，最终复制到系统剪贴板。

当前主链没有保存文件、分享链接、预览编辑器或生成历史。本轮补充确认四点：30 段迭代上限命中时是静默截断（拼接已有分段并返回成功，无专用错误）；“从顶部”的起点受历史懒加载分页与消息窗口化约束，捕获期间不会自动加载更早历史；截图口径是当前 DOM 视口截图（`capturePage`），捕获期间关闭 Markdown 节点级虚拟化；剪贴板写入无平台分支、无错误检查，且成功提示先于实际复制显示。

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

“从顶部”的起点是容器内第一个已挂载 `[data-message-id]`（`useMessageCapture.ts:129-134`），它并不等于会话第一条消息，受两层约束：

- 历史懒加载：会话打开只恢复约 100 条消息（`ChatPage.vue:437`）；更早历史以 100 条/页游标分页，仅在用户滚动到顶部时经 `loadOlderMessagesAtTop` 加载。捕获的程序化滚动不会触发分页：滚动监听要求用户手势意图（`hadUpwardPaginationIntent`）才可能加载，非用户滚动被视口通知直接判定为 native 而跳过，无手势意图时也会早退（`ChatPage.vue:684-692`；`useChatScrollController.ts:244-263`）。因此长会话的“从顶部”截图覆盖的是已加载页的最早消息，而非会话真实起点。
- 消息窗口化：已加载消息超过 `MESSAGE_WINDOWING_THRESHOLD = 160` 条时启用窗口化渲染（`ChatPage.vue:438`），只挂载视口 ±2400px overscan 范围内的行，其余区域用前后 spacer 占位（`ChatPage.vue:86-107`；`MessageList.vue:5-36`；`useMessageVirtualization.ts:81-125`）。捕获滚动时窗口随滚动监听的 rAF 指标同步移动，但没有代码在捕获前强制窗口已就位，未挂载区域的占位空白是否进入分段取决于滚动与挂载的时序（运行行为未验证）。≤160 条时全部挂载，无占位空白问题。

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

`captureAndCopy()` 在拼接成功后调用 `deviceClient.copyImage(imageData)`。preload 将该动作暴露给 renderer，最终写入系统剪贴板（`composables/usePageCapture.ts:337-355`；`src/preload/index.ts:23-25`）。当前消息工具栏没有保存文件或系统分享入口，用户需要从剪贴板粘贴到目标应用。

剪贴板交付细节：`window.api.copyImage` 直接 `nativeImage.createFromDataURL(image)` + `clipboard.writeImage(img)`（`src/preload/index.ts:23-26`），无平台分支、无 try/catch、无返回值；Electron 内部按平台转换格式（Windows/CF_DIB、macOS/NSPasteboard、Linux/X11），未传 `scaleFactor`（默认 1）。

`captureAndCopy` 调用后无条件返回 true，不检查写入结果（`usePageCapture.ts:344-346`）；若 `writeImage` 抛错，异常沿 IPC 抛回 renderer，`captureMessage` 无 catch 分支，表现为未处理的 Promise 拒绝（`useMessageCapture.ts:160-186`）。工具栏的“复制成功”浮层在 mouseup/键盘触发时即显示（`MessageToolbar.vue:227-249`），先于实际捕获与写入完成，与实际成败无关。

Web 平台路径不存在：renderer 的 `getDeepchatBridge` 在无 `window.deepchat` 时直接抛错（`renderer/api/core.ts:8-14`），`window.api` 仅由 Electron preload 暴露（`src/preload/index.ts:114-133`），本快照未找到浏览器端 mock 或独立 Web 构建目标。

## 4. 富内容与边界

截图对象是现场消息 DOM，内容口径不取自原始数据。每段由主进程 `webContents.capturePage(rect)` 抓取视口位图（`src/main/desktop/tab.ts:958-968`），因此进入图片的是“当前渲染后的可见内容”：已渲染的 Markdown/代码、流式输出进行到一半的文本、折叠/展开的当前 UI 状态，均按捕获瞬间的 DOM 呈现。捕获期间有两项针对性处理：

- Markdown 节点级虚拟化在捕获期间被关闭（`MessageList.vue:103-105` 的条件使 MarkdownRenderer 的 `resolvedNodeVirtual` 变 false、`maxLiveNodes` 归零，`MarkdownRenderer.vue:243-249`；平时静态长文最多保留 260 个 live 节点），保证已挂载消息的节点全部渲染进截图；
- 工具栏整体隐藏（`MessageToolbar.vue:2`，捕获中不再渲染），与 `.chat-capture-hide` 覆盖层（顶栏、输入区、只读工具交互浮层，`ChatPage.vue:9,127,141`）一起避免操作控件入图（`useMessageCapture.ts:33-53`）。

`.chat-capture-hide` 是明确的截图排除契约；除此之外，本次没有找到针对敏感内容、system prompt、路径或工具参数的专用过滤。

代码块由 Markstream 的 `monaco` codeRenderer 承担（`MarkdownRenderer.vue:225-227`），本轮未找到代码块级折叠契约；工具调用详情、think 块等的折叠状态（`useMessageWindow.ts:29-37` 以“折叠 pill/think 头”为默认估计高度）按现场状态入图。流式输出期间图片按钮仍可用（`MessageToolbar.vue:82-83` 仅以 isCapturingImage 禁用），此时截图会捕获未完成文本。

截图直接使用现场 DOM，没有独立渲染器、内容配置面板或视觉配置面板。水印由程序固定组装，用户不能在该工作流内选择背景、布局、宽度、倍率或水印字段。当前 DOM 中折叠的工具内容是否保持折叠，取决于现场 UI 状态。

Artifact 的 `copyAsImage()` 也复用页面捕获能力，但其导出源是独立 Artifact 对象，归生成式输出与运行时。本篇对话图片结论不重复计数。

## 5. 可靠性、历史与持久化

- `isCapturing` 防止同一 composable 并发截图（`usePageCapture.ts:159-161`）；
- 捕获过程在 finally 中恢复滚动行为，消息层另行恢复隐藏覆盖层；
- 单段失败会停止循环；已有分段仍可能继续进入拼接，是否形成部分图片没有显式完成度标记（`usePageCapture.ts:279-291,299-320`）；
- 最多 30 次迭代，命中上限时静默拼接已有分段，无截断错误（详见第 2 节）；
- 剪贴板写入失败无收口：无错误检查、无重试、无用户可见失败反馈，失败表现为未处理 Promise 拒绝（见第 3 节）；
- 测试覆盖：`test/renderer/composables/usePageCapture.test.ts` 只验证分段裁剪与拼接调用参数；`test/renderer/composables/useMessageCapture.test.ts` 以 mock 验证两种范围计算路径；`test/main/routes/dispatcher.test.ts:5923-5959` 验证路由接线。迭代上限、分页、剪贴板与平台行为均无测试；
- 没有应用内图片历史、预览、版本或持久化对象。

## 6. 设计取舍与已确认边界

- 短按/长按在一个紧凑入口中提供“当前问答组”和“截至当前的会话长图”两种常用范围。
- 分段捕获绕开单一超长 Canvas 的直接 DOM 转换限制，但依赖滚动期间现场稳定和每段延迟。
- 直接捕获当前 UI 保真度高，同时把折叠状态、已挂载范围和主题现场带入结果。
- 输出只进剪贴板，交付链简短，但没有文件管理、版本比较和远端分享治理。

## 7. 未验证事项

- 长会话超过 30 个分段后的实际长图内容（代码路径已确认静默截断，未运行验证拼接出的部分长图外观与提示表现）。
- 捕获期间新消息流入、消息高度变化或用户切换会话时的行为。
- 窗口化渲染下捕获滚动与窗口挂载/测量的时序：未挂载区域是否以占位空白进入分段、捕获中行高测量（ResizeObserver + rAF 批量）是否导致分段内容偏移；≤160 条消息时不涉及。
- “从顶部”起点与真实会话起点的差异程度（100 条初始加载 + 每页 100 条懒加载），以及到达已加载页顶后截图是否仍继续滚动进入占位空白。
- Markdown、代码、表格、工具卡、图片和本地附件的分段接缝与视觉保真，以及折叠块在截图中的实际呈现。
- 剪贴板写入失败的实际表现（异常是否被 Electron 吞掉、Toast/控制台输出），以及 Windows/macOS/Linux 各平台 PNG 复制的格式兼容性差异；`clipboard.writeImage` 未传 `scaleFactor` 时高 DPI 位图尺寸。
- 捕获失败后已有分段是否可能生成部分长图；本次未运行错误场景。

## 8. 关键源码索引

- `src/renderer/src/components/message/MessageToolbar.vue`
- `src/renderer/src/components/chat/MessageList.vue`
- `src/renderer/src/composables/message/useMessageCapture.ts`
- `src/renderer/src/composables/usePageCapture.ts`
- `src/main/lib/scrollCapture.ts`
- `src/main/desktop/tab.ts`
- `src/preload/index.ts`
- `src/renderer/src/features/chat-page/ChatPage.vue`（分页触发与窗口化接线、捕获隐藏覆盖层）
- `src/renderer/src/features/chat-page/composables/useMessageVirtualization.ts`（消息窗口化渲染窗口）
- `src/renderer/src/composables/message/useMessageWindow.ts`（行高估计与测量，折叠块默认高度）
- `src/renderer/src/stores/ui/message.ts`（`loadOlderMessages` 历史分页）
- `src/renderer/src/components/markdown/MarkdownRenderer.vue`（节点级虚拟化开关）
- `test/renderer/composables/usePageCapture.test.ts`、`useMessageCapture.test.ts`（现有测试覆盖）
