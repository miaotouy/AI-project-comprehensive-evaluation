# DeepChat 对话导出与分享调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：静态源码局部调查；读取消息工具栏手势、截图范围计算、滚动分段捕获、主进程拼接/水印和剪贴板交付；未运行 Electron 应用、未执行测试
>
> 调查范围：当前问答组与“从顶部到当前消息”的图片复制主链；不覆盖 Artifact 图片复制、浏览器页面截图、Tape/Trace 导出和会话 JSON 保存
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 提供消息级图片复制，并用同一按钮的短按/长按区分两种范围：短按捕获当前 assistant 消息及其父 user 消息组成的问答组；长按 800ms（键盘为 Shift+Enter/Space）捕获从会话顶部到当前消息。它不是重排分享稿，而是对当前 `.message-list-container` 做分段滚动截图，随后在主进程用 Sharp 垂直拼接，并增加 DeepChat、版本、模型与 Provider 水印，最终复制到系统剪贴板。

当前主链没有保存文件、分享链接、预览编辑器或生成历史。截图范围和品牌信息较明确，但最多 30 个分段、每段默认等待 350ms，极长会话可能只覆盖上限内内容；代码没有在达到 `maxIterations` 时单独报告截断状态，本次未运行验证。

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

这两种范围都依赖当前 DOM。未挂载、虚拟化移除、折叠或非活动分支消息不会因数据层存在而自动进入图片；本次未确认消息列表是否会为截图临时加载全部历史。

## 2. 分段捕获与垂直拼接

捕获前，模块隐藏所有 `.chat-capture-hide` 元素，等待 Vue `nextTick` 和 60ms，使操作控件不进入图片；无论成功失败，finally 都恢复覆盖层（`useMessageCapture.ts:19-47,156-184`）。

`usePageCapture.captureArea()` 以 `.message-list-container` 为滚动容器，保存原滚动位置和 `scrollBehavior`。默认参数为每段等待 350ms、最多 30 次、扣除 20px 滚动条宽度；它计算目标在滚动内容中的绝对范围，逐段滚动到目标位置，经 `tabClient.captureCurrentArea(rect)` 取得图片数据，完成后恢复原位置（`composables/usePageCapture.ts:154-324`）。

收集到的分段交给 `tabClient.stitchImagesWithWatermark()`。主进程 `ScrollCaptureManager`/拼接实现使用 Sharp 读取每段宽高，取最大宽度和高度总和，居中垂直合成 PNG；带水印版本由 desktop tab 路由承接（`src/main/lib/scrollCapture.ts:275-340`；`src/main/desktop/tab.ts:981-1010`）。

## 3. 水印与交付

截图水印包含：

- 当前主题明暗；
- 应用版本；
- 品牌 `DeepChat`；
- 本地化提示文案；
- 当前消息提供的模型名和 Provider（`useMessageCapture.ts:162-175`）。

`captureAndCopy()` 在拼接成功后调用 `deviceClient.copyImage(imageData)`。preload 将该动作暴露给 renderer，最终写入系统剪贴板（`composables/usePageCapture.ts:337-355`；`src/preload/index.ts:23-25`）。当前消息工具栏没有保存文件或系统分享入口，用户需要从剪贴板粘贴到目标应用。

## 4. 富内容与边界

截图对象是现场消息 DOM，因此 Markdown、代码、工具卡、reasoning、附件预览等以当前可见状态进入图片。`.chat-capture-hide` 是明确的截图排除契约；除此之外，本次没有找到针对敏感内容、system prompt、路径或工具参数的专用过滤。

截图不是独立渲染器，也没有内容或视觉配置面板。水印由程序固定组装，用户不能在该工作流内选择背景、布局、宽度、倍率或水印字段。当前 DOM 中折叠的工具内容是否保持折叠，取决于现场 UI 状态。

Artifact 的 `copyAsImage()` 也复用页面捕获能力，但其导出源是独立 Artifact 对象，归生成式输出与运行时，不在本篇对话图片结论中重复计数。

## 5. 可靠性、历史与持久化

- `isCapturing` 防止同一 composable 并发截图；
- 捕获过程在 finally 中恢复滚动行为，消息层另行恢复隐藏覆盖层；
- 单段失败会停止循环；已有分段仍可能继续进入拼接，是否形成部分图片没有显式完成度标记；
- 最多 30 次迭代，代码未在命中上限且目标未完成时返回专用错误；
- 没有应用内图片历史、预览、版本或持久化对象。

## 6. 设计取舍与已确认边界

- 短按/长按在一个紧凑入口中提供“当前问答组”和“截至当前的会话长图”两种常用范围。
- 分段捕获绕开单一超长 Canvas 的直接 DOM 转换限制，但依赖滚动期间现场稳定和每段延迟。
- 直接捕获当前 UI 保真度高，同时把折叠状态、已挂载范围和主题现场带入结果。
- 输出只进剪贴板，交付链简短，但没有文件管理、版本比较和远端分享治理。

## 7. 未验证事项

- 长会话超过 30 个分段后的实际结果是否静默截断。
- 捕获期间新消息流入、消息高度变化或用户切换会话时的行为。
- 虚拟列表、历史分页和非活动分支对“从顶部”范围的限制。
- Markdown、代码、表格、工具卡、图片和本地附件的分段接缝与视觉保真。
- 各桌面平台的剪贴板写入和高 DPI 尺寸。
- 捕获失败后已有分段是否可能生成部分长图；本次未运行错误场景。

## 8. 关键源码索引

- `src/renderer/src/components/message/MessageToolbar.vue`
- `src/renderer/src/components/chat/MessageList.vue`
- `src/renderer/src/composables/message/useMessageCapture.ts`
- `src/renderer/src/composables/usePageCapture.ts`
- `src/main/lib/scrollCapture.ts`
- `src/main/desktop/tab.ts`
- `src/preload/index.ts`

