# AIO Hub 对话导出与分享调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：静态源码调查；读取分支/会话导出、消息截图对话框、独立截图渲染器、截图生成与历史管理实现，并与既有会话管理和 Chat UI 笔记交叉核对；未运行应用或实际生成图片
>
> 调查范围：结构化分支与会话导出、消息范围选择、截图分享稿编排、实时预览、PNG 生成、运行时生成历史、复制与保存；不覆盖会话导入、角色卡/预设资产交换和移动端资产分享
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 同时提供数据交换型导出和图片分享稿工作台。分支可按 Markdown、结构化 JSON 或 Raw JSON 导出，完整会话可保存树状表达并保留隐藏分支；截图链则从调用方提供的消息序列中选择连续范围或任意消息，进入独立 `ScreenshotRenderer`，允许调整布局、尺寸、背景、水印、品牌信息和内容元素，再生成 PNG。

图片工作台的辨识点是**生成结果历史**：每次手动生成都会向缩略图历史追加一项；选区或配置变化不会覆盖旧图，而是把已有结果标记为“已过时”。用户可以在多个结果之间切换、查看大图、复制、保存和删除。这是组件内存中的生成历史，没有发现写入会话、配置或文件索引的路径，不能视为跨重启持久版本。

本次未找到截图模块内直接改写消息正文副本的 `contenteditable`、textarea、CodeMirror 或消息内容更新入口。“可编辑”在当前实现中指分享稿的选区与视觉编排，不是独立正文编辑器。

## 系统边界与完整主链

```text
当前消息序列
  -> ShareScreenshotDialog 选择范围/逐条勾选
  -> ScreenshotConfigPanel 编辑分享稿配置
  -> ScreenshotRenderer 实时重建截图专用 DOM
  -> useScreenshotGenerator.generate()
  -> captureMessagesAndStitch() 并发截取每条消息并拼接 Canvas
  -> ScreenshotPreviewPanel 追加一条运行时历史
  -> 查看大图 / 复制 PNG / 保存 PNG
```

结构化导出是另一条链：

```text
活动分支或完整会话树
  -> ExportBranchDialog 选择格式、范围和包含项
  -> useExportManager 转换 Markdown / JSON / Raw JSON
  -> 预览并写入文件
```

两条链共享会话与消息数据，但不共享最终表达：结构化导出强调字段与树语义，截图工作台强调可见内容、视觉编排和图片交付。

## 1. 导出源、范围与内容口径

截图对话框接收调用方传入的 `messages: ChatMessageNode[]`。默认选择最后两条；若从某条消息打开，则选择该消息及其前一条。`MessageRangePanel` 同时提供连续范围滑块、起止输入、全选/清空和逐条复选，因此最终图片不必是连续区间（`../../aio-hub/src/tools/llm-chat/components/screenshot/ShareScreenshotDialog.vue:139-156`；`components/screenshot/MessageRangePanel.vue:19-83,131-164`）。

本次没有继续追踪所有调用方传给对话框的是活动路径、完整树还是某个投影，不能把截图范围写成“完整会话树”。完整树保留属于结构化会话导出能力。

分支导出由 `useExportManager` 提供：

- `exportBranchAsMarkdown`、`exportBranchAsJson`、`exportBranchAsRaw` 分别生成阅读型 Markdown、结构化 JSON 和保留原始节点字段的 Raw JSON（`composables/features/useExportManager.ts:229,607,1078`）；
- 范围与内容选项可控制预设、用户档案、Agent/模型信息、Token、附件和错误；
- 启用上下文管道后，导出宏、世界书、Recall/知识注入、变量替换与 Token 裁剪后的上下文结果，而不是简单复制可见消息；
- `exportSessionAsMarkdownTree` 处理完整节点树，可表达不在当前活动路径上的隐藏分支（`:849`）。

## 2. 分享稿编辑与实时预览

截图工作台不是对当前窗口做像素截屏。`ScreenshotRenderer` 复用消息组件并注入 `screenshotMode`、折叠策略和元素覆盖，使操作栏、分支按钮等交互元素不进入交付物（`components/screenshot/ScreenshotRenderer.vue`）。

可编辑维度包括：

- 卡片、气泡或跟随系统布局，以及圆角和字号覆盖；
- 自动或固定渲染宽度，范围 480–1280 CSS px；输出倍率 1x、2x、3x；
- 主题、纯色或应用壁纸背景，壁纸 cover/contain/tile/stretch；
- 消息间距、四周留白、卡片装饰；
- 平铺水印的文字、颜色、字号、间距和角度；
- 顶部/底部品牌条、Logo、描述、话题、参与 Agent/用户和二维码；
- 工具调用展开策略，以及头像、时间、Token、字数、模型和性能信息显隐。

这些配置通过 `v-model` 直接进入 `ScreenshotPreviewPanel` 和 `ScreenshotRenderer`，预览 DOM 会实时变化（`components/screenshot/ShareScreenshotDialog.vue:35-64`；`ScreenshotConfigPanel.vue:20-485`）。预览支持 40%–200% 缩放和拖拽平移；预览缩放不改变最终图片倍率（`ScreenshotPreviewPanel.vue:20-110,389-456`）。

## 3. PNG 生成与资源处理

用户必须手动点击“生成截图”；配置变化不会自动触发昂贵捕获。父组件等待截图 DOM 完成布局后，调用 `useScreenshotGenerator.generate()`，底层 `captureMessagesAndStitch()` 默认以并发度 6 逐条截取 `.message-slot`，再按间距和留白拼接到统一 Canvas（`ShareScreenshotDialog.vue:215-275`；`utils/screenshotCapture.ts:308-397`）。

生成器显式处理了几类离屏渲染问题：

- 使用自然布局尺寸，避免预览 `transform: scale` 改变捕获尺寸；
- 向克隆节点复制 CSS 变量，并强制 `content-visibility: visible`；
- 展开代码块、表格等溢出内容并隐藏滚动条；
- 在 Canvas 拼接阶段绘制纯色、主题或壁纸背景；
- 通过预模糊背景和区域裁剪补偿 `foreignObject` 中不可用的 `backdrop-filter`；
- 品牌条、水印和消息内容作为独立层进入最终画布。

最终只输出 PNG。复制使用 Clipboard API；保存通过 Tauri 文件对话框写入 PNG 字节。`canvasToPngBytes()` 用 `atob` 解码 Data URL，没有用受 CSP 限制的 `fetch(dataUrl)`（`composables/features/useScreenshotGenerator.ts:120-166`；`utils/screenshotCapture.ts:960-993`）。

## 4. 生成历史与版本语义

`ScreenshotPreviewPanel` 内部维护 `history: ScreenshotHistoryItem[]`。每项保存递增内存 ID、Data URL、Canvas、宽高、消息数、时间戳和 `stale` 标记（`ScreenshotPreviewPanel.vue:285-294,460-488`）。

版本行为如下：

1. 新 `lastImageUrl` 到达时追加历史并自动选中新项；
2. 父组件在选区、布局、折叠、元素开关或渲染配置变化后清空当前 `lastCanvas/lastImageUrl`；
3. 子组件观察到已生成 URL 变为空，把全部已有项标记为 `stale=true`，但不删除；
4. 用户可以切换缩略图、查看大图、复制或保存任一旧版本，也可单删或清空历史（`ShareScreenshotDialog.vue:309-322`；`ScreenshotPreviewPanel.vue:473-540`）。

历史没有进入 store、Tauri command 或持久化 service。本次只能确认它是组件局部运行时状态；BaseDialog 隐藏时组件是否保持挂载未继续下钻，但应用重启后不会恢复这一列表。

## 5. 富内容、隐私与已确认边界

截图专用渲染器复用聊天消息组件，因此普通 Markdown、工具卡、头像、消息元信息和项目主题能够沿用现场表达；工具卡还可独立决定展开或收起。复杂 Artifact、远端附件、跨域图片和超长代码的最终保真没有运行验证。

截图配置提供水印、品牌和二维码，但本次未找到面向 system prompt、reasoning、密钥、文件路径或个人信息的专用脱敏扫描。是否进入图片主要取决于调用方消息集合和元素开关。结构化导出允许选择多类字段，具体默认值与敏感内容提示仍需专项运行核对。

图片交付是本地复制或保存，没有创建远端图片对象，也没有访问控制、过期和撤销语义。AIO Hub 本项目中的其他资产分享不属于本次对话截图主链。

## 6. 设计取舍与已确认边界

- 独立渲染器使分享图不受当前滚动位置限制，并能隐藏交互控件；代价是截图 sink 需要跟随消息组件演进。
- 逐消息捕获再拼接避免直接捕获超长单一 DOM，但最终 Canvas 仍受平台尺寸和内存限制。
- 手动生成把高成本捕获与高频配置编辑解耦；`stale` 标记保留旧结果，同时明确它与当前分享稿不一致。
- 生成历史是结果比较工具，不是会话分支，也不是持久化版本库。
- 结构化导出与图片工作台分开实现，分别服务可移植数据和视觉交付。

## 7. 未验证事项

- 截图对话框所有调用方传入消息集合的分支范围，以及隐藏/禁用节点是否进入候选列表。
- reasoning、复杂工具结果、Artifact、附件、本地资产和跨域图片的实际截图保真。
- 极长会话、3x 输出、壁纸毛玻璃和二维码下的 Canvas 尺寸与内存行为。
- Windows/macOS/Linux 剪贴板和文件保存结果；本次未运行 Tauri 窗口。
- 关闭并重新打开同一对话框时，组件局部截图历史是否因挂载策略保留。
- 各结构化导出格式的默认内容开关、导入往返和敏感信息提示。

## 8. 关键源码索引

- `src/tools/llm-chat/components/screenshot/ShareScreenshotDialog.vue`
- `src/tools/llm-chat/components/screenshot/MessageRangePanel.vue`
- `src/tools/llm-chat/components/screenshot/ScreenshotConfigPanel.vue`
- `src/tools/llm-chat/components/screenshot/ScreenshotPreviewPanel.vue`
- `src/tools/llm-chat/components/screenshot/ScreenshotRenderer.vue`
- `src/tools/llm-chat/composables/features/useScreenshotGenerator.ts`
- `src/tools/llm-chat/utils/screenshotCapture.ts`
- `src/tools/llm-chat/composables/features/useExportManager.ts`
- `src/tools/llm-chat/components/export/ExportBranchDialog.vue`

