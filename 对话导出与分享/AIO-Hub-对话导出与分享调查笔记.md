# AIO Hub 对话导出与分享调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-14
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

本次未找到截图模块内直接改写消息正文副本的 `contenteditable`、textarea、CodeMirror 或消息内容更新入口。当前实现中的“可编辑”仅指分享稿的选区与视觉编排，不包含独立的正文编辑器。

本轮补充确认了三件事。其一，截图候选列表的来源是唯一的：`ShareScreenshotDialog` 只在 `ChatArea.vue:638-650` 实例化，消息一律来自活动路径与智能体开场白展示消息，范围不含完整树；消息菜单、树图节点菜单和导出弹窗“生成分享长图”都汇入同一个对话框。其二，截图内容是数据驱动的独立重渲染：复用消息组件但隐藏编辑、menubar、流式指示器等现场交互元素；生成流程对消息内容没有快照冻结，运行中生成时理论上可能截到流式更新的中间态（推断）。其三，结构化分支导出（Markdown/JSON/Raw JSON）只产生文件，没有导入入口；项目内仅批量备份 ZIP 管线支持会话往返。

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

截图对话框接收调用方传入的 `messages: ChatMessageNode[]`。默认选择最后两条；若从某条消息打开，则选择该消息及其前一条。`MessageRangePanel` 同时提供连续范围滑块、起止输入、全选/清空和逐条复选，因此最终图片不必是连续区间（`../../aio-hub/src/tools/llm-chat/components/screenshot/ShareScreenshotDialog.vue:139-156`）。

调用方分支范围本轮已追踪完整（在 `src/tools/llm-chat` 全目录搜索该对话框引用）：截图对话框只有一处实例化，位于 `components/ChatArea.vue:638-650`；`ChatArea` 的消息唯一来自 `LlmChat.vue:575` 的 `currentActivePathWithPresets`，即活动路径加智能体开场白展示消息。活动路径从当前叶子节点沿父指针回溯、排除根节点，且不做启用状态过滤；预设展示消息按角色、启用状态、注入策略和模型匹配过滤后追加，并标记为预设展示；两段组装逻辑与回溯过滤的实现位置见文末索引。因此截图候选列表是“当前可见线性对话 + 最多 `displayPresetCount` 条开场白”：隐藏分支不进入，压缩隐藏节点不进入，但禁用节点和压缩摘要节点仍在候选内。

所有入口都汇入同一个对话框：消息菜单、树图节点菜单和导出弹窗的“生成分享长图”按钮，最终都调用 `ChatArea.handleScreenshot`（`ChatArea.vue:111-114`）打开截图对话框；三处入口的位置见下列清单。

- 消息菜单：`components/message/MessageList.vue:742,818,887`
- 树图节点菜单：`components/conversation-tree-graph/flow/components/GraphNodeMenubar.vue:407-416` → `FlowTreeGraph.vue:74`
- 导出弹窗“生成分享长图”按钮：`components/export/ExportBranchDialog.vue:105-108,167-170`

导出弹窗中设置的消息范围不会传递到截图对话框：截图对话框只接收焦点消息 id，并根据它初始化选区；焦点消息不在候选列表时回退为“最后两条”（`ShareScreenshotDialog.vue:139-152`）。从非活动分支的树节点发起时，候选列表仍然是当前活动路径。

分支导出由 `useExportManager` 提供：

- 三个独立入口分别生成阅读型 Markdown、结构化 JSON 和保留原始节点字段的 Raw JSON（`composables/features/useExportManager.ts`）：
  - `exportBranchAsMarkdown`（`:229`）
  - `exportBranchAsJson`（`:607`）
  - `exportBranchAsRaw`（`:1078`）
- 范围与内容选项可控制预设、用户档案、Agent/模型信息、Token、附件和错误；
- 启用上下文管道后，导出宏、世界书、Recall/知识注入、变量替换与 Token 裁剪后的上下文结果，内容已经超出可见消息的简单复制；
- `exportSessionAsMarkdownTree` 处理完整节点树，可表达不在当前活动路径上的隐藏分支（`useExportManager.ts:849`）。

## 2. 分享稿编辑与实时预览

截图工作台通过 `ScreenshotRenderer` 重建内容，不捕获当前窗口像素。该渲染器复用消息组件并注入 `screenshotMode`、折叠策略和元素覆盖，使操作栏、分支按钮等交互元素不进入交付物（`components/screenshot/ScreenshotRenderer.vue`）。

可编辑维度包括：

- 卡片、气泡或跟随系统布局，以及圆角和字号覆盖；
- 自动或固定渲染宽度，范围 480–1280 CSS px；输出倍率 1x、2x、3x；
- 主题、纯色或应用壁纸背景，壁纸 cover/contain/tile/stretch；
- 消息间距、四周留白、卡片装饰；
- 平铺水印的文字、颜色、字号、间距和角度；
- 顶部/底部品牌条、Logo、描述、话题、参与 Agent/用户和二维码；
- 工具调用展开策略，以及头像、时间、Token、字数、模型和性能信息显隐。

这些配置通过 `v-model` 直接进入预览面板和渲染器，预览 DOM 会实时变化（`components/screenshot/ShareScreenshotDialog.vue:35-64`）。预览支持 40%–200% 缩放和拖拽平移；预览缩放不改变最终图片倍率（`ScreenshotPreviewPanel.vue:20-110,389-456`）。

运行保真关系（本轮确认）：渲染器用同一批消息组件按传入数据重新渲染，数据响应式来自 store（LlmChat computed → ChatArea props → 对话框 → 预览面板 → 渲染器）。因此图片与聊天现场的一致性取决于“store 数据 vs 现场 DOM 状态”的同步程度。

截图模式下，编辑/重新生成/翻译按钮、菜单栏、流式指示器、gpt-image-2 部分预览和翻译控件被显式隐藏（`components/message/MessageContent.vue:1000,1163,1173-1177`；`message/ChatMessage.vue:319`；`message/ToolCallMessage.vue:1130-1133`）；工具卡展开由折叠策略接管、不接受交互（`ToolCallMessage.vue:284-289`）。

流式消息内容由 `RichTextRenderer` 的 stream-source 渲染，生成中的部分内容本身会进入截图；生成流程只等待 100ms 与图片解码（`ShareScreenshotDialog.vue:227-234`；`utils/screenshotCapture.ts:109-134`），对消息内容没有快照冻结，运行中生成可能截到流式更新的中间态——这是基于静态代码的推断，未运行验证。

## 3. PNG 生成与资源处理

用户必须手动点击“生成截图”；配置变化不会自动触发昂贵捕获。父组件等待截图 DOM 完成布局后调用 `useScreenshotGenerator.generate()`，底层默认以并发度 6 逐条截取消息槽，再按间距和留白拼接到统一 Canvas（`ShareScreenshotDialog.vue:215-275`；`utils/screenshotCapture.ts:308-397`）。

生成器显式处理了几类离屏渲染问题：

- 使用自然布局尺寸，避免预览 `transform: scale` 改变捕获尺寸；
- 向克隆节点复制 CSS 变量，并强制 `content-visibility: visible`；
- 展开代码块、表格等溢出内容并隐藏滚动条；
- 在 Canvas 拼接阶段绘制纯色、主题或壁纸背景；
- 通过预模糊背景和区域裁剪补偿 `foreignObject` 中不可用的 `backdrop-filter`；
- 品牌条、水印和消息内容作为独立层进入最终画布。

最终只输出 PNG：复制使用系统剪贴板，保存通过 Tauri 文件对话框写入 PNG 字节。字节转换用 `atob` 解码 Data URL，刻意避开受 CSP 限制的 `fetch(dataUrl)`（`utils/screenshotCapture.ts:960-993`）。

极长图没有尺寸防护（本轮确认）：捕获拼接把全部消息拼到单张 Canvas，尺寸直接取总宽总高与输出倍率之积，没有任何维度上限检查、分块或分段保存（`utils/screenshotCapture.ts:391-393`）。高度只受运行平台 Canvas 上限与内存约束；宽度上限 1280 CSS px 与 3x 输出意味着最宽约 3840px，长会话下高度先触及平台上限（约 32767/65535px 级），失败表现与触发点取决于 WebView 实现。

失败处理只有两层：单条消息 `drawImage` 失败被捕获后跳过继续（`screenshotCapture.ts:479-484`），大画布创建或 `toDataURL` 编码失败统一走“生成截图失败”提示，无尺寸专项提示或降级路径。另外，截图历史每一项同时在内存中持有 Canvas 与 Data URL（`ScreenshotPreviewPanel.vue:477-487`），多次生成大图会叠加占用内存。

## 4. 格式、schema 与往返能力

结构化导出（Markdown/JSON/Raw JSON）经 `ExportBranchDialog` 预览后通过 `writeTextFile` 落盘（`components/export/ExportBranchDialog.vue:434-479`），是纯输出管线。

JSON 导出没有版本或 schema 标识，除真实 Payload 模式（`exportType: "real_payload"`）外只有字段列表；常规 JSON 是线性消息列表，不保留 `parentId`/`childrenIds` 分支关系，只有 Raw JSON 保留分支链的节点 map（`composables/features/useExportManager.ts:607-841,1078-1130`）。

往返结论（本轮确认）：本次未找到 Markdown/JSON/Raw JSON 三种导出格式的导入入口。在 `src/tools/llm-chat` 全目录搜索导入路径，只发现会话备份 ZIP 导入（`components/sidebar/BatchManagerDialog.vue:676-708` → `services/sessionImportExportService.ts:163-201` → `stores/session/sessionLifecycleManager.ts:381`）、SillyTavern 正则/世界书导入、快捷操作导入和智能体导入，没有任何代码读取分支 Markdown/JSON 回写会话。上述搜索覆盖 TypeScript 文件中的文件读取调用与各 Dialog 入口，足以确认结构化导出格式不支持往返。

项目内真正可往返的是另一条批量备份管线：`exportSessionsAsZip` 产出 `aiohub-chat-session-backup` v1.0.0 格式的 ZIP，内容为 `metadata.json` 加每会话扁平 JSON，导出时剥离 `history/historyIndex`（`sessionImportExportService.ts:119-125,127-161`）。导入时按冲突策略 keep（改名“(导入副本)”）/overwrite/skip 处理，未知字段被忽略（`:70-117,203-257`）。

该格式与分支导出的 Raw JSON 结构相近（都含 index/detail/nodes），但批量导入入口只接受 ZIP 文件（`BatchManagerDialog.vue:679-682` 的过滤器），单文件 Raw JSON 没有 UI 导入路径，两者在管线层面不互通。

## 5. 生成历史与版本语义

`ScreenshotPreviewPanel` 内部维护 `history: ScreenshotHistoryItem[]`。每项保存递增内存 ID、Data URL、Canvas、宽高、消息数、时间戳和 `stale` 标记（`ScreenshotPreviewPanel.vue:285-294,460-488`）。

版本行为如下：

1. 新 `lastImageUrl` 到达时追加历史并自动选中新项；
2. 父组件在选区、布局、折叠、元素开关或渲染配置变化后清空当前 `lastCanvas/lastImageUrl`；
3. 子组件观察到已生成 URL 变为空，把全部已有项标记为 `stale=true`，但不删除；
4. 用户可以切换缩略图、查看大图、复制或保存任一旧版本，也可单删或清空历史（`ShareScreenshotDialog.vue:309-322`；`ScreenshotPreviewPanel.vue:473-540`）。

历史没有进入 store、Tauri command 或持久化 service，是组件局部运行时状态（本轮进一步确认：`BaseDialog` 默认 `destroyOnClose: true`，`src/components/common/BaseDialog.vue:20,147`，对话框内容在关闭时卸载，`ScreenshotPreviewPanel` 随重建，历史列表在关闭并重新打开后不保留）。

## 6. 富内容、隐私与已确认边界

截图专用渲染器复用聊天消息组件，因此普通 Markdown、工具卡、头像、消息元信息和项目主题能够沿用现场表达；工具卡还可独立决定展开或收起。复杂 Artifact、远端附件、跨域图片和超长代码的最终保真没有运行验证。

截图配置提供水印、品牌和二维码，但本次未找到面向 system prompt、reasoning、密钥、文件路径或个人信息的专用脱敏扫描。是否进入图片主要取决于调用方消息集合和元素开关。结构化导出允许选择多类字段，具体默认值与敏感内容提示仍需专项运行核对。

图片交付是本地复制或保存，没有创建远端图片对象，也没有访问控制、过期和撤销语义。AIO Hub 本项目中的其他资产分享不属于本次对话截图主链。

## 7. 设计取舍与已确认边界

- 独立渲染器使分享图不受当前滚动位置限制，并能隐藏交互控件；代价是截图 sink 需要跟随消息组件演进。
- 逐消息捕获再拼接避免直接捕获超长单一 DOM，但最终 Canvas 仍受平台尺寸和内存限制。
- 手动生成把高成本捕获与高频配置编辑解耦；`stale` 标记保留旧结果，同时明确它与当前分享稿不一致。
- 生成历史仅用于结果比较，不具备会话分支或持久化版本库的语义。
- 结构化导出与图片工作台分开实现，分别服务可移植数据和视觉交付。
- 图片内容的一致性依赖共享数据；渲染器不复用现场 DOM。交互态、流式指示器不会进入图片，但消息内容变化会实时反映到预览；生成瞬间的内容以 store 数据为准，无快照冻结。
- 长图采用单 Canvas 全量拼接，无尺寸上限与分块降级；逐消息捕获只降低单次捕获复杂度，没有解决总尺寸与编码内存问题。
- 批量备份 ZIP 是唯一闭环的交换格式，与面向阅读的分支导出刻意分离。

## 8. 未验证事项

- 运行中生成截图时，流式消息内容仍在更新与实际捕获之间的竞态表现（静态推断存在中间态可能，未运行验证）。
- 极长会话、3x 输出、壁纸毛玻璃和二维码下的 Canvas 上限触达值与失败表现，以及生成历史叠加的内存占用（代码确认无防护，实际阈值未运行验证）。
- reasoning、复杂工具结果、Artifact、附件、本地资产和跨域图片的实际截图保真。
- Windows/macOS/Linux 剪贴板和文件保存结果；本次未运行 Tauri 窗口。
- 各结构化导出格式的敏感信息提示：默认内容开关已从代码确认（`ExportBranchDialog.vue:183-191` 全部 true，仅 `includePreset` 默认 false），但导出前是否提示 system prompt、密钥、文件路径等敏感内容仍未见专用扫描，属未覆盖。
- 从非活动分支的树节点发起“生成分享长图”时，焦点回退到活动路径最后两条的实际体验（代码路径已确认，交互表现未运行验证）。

## 9. 关键源码索引

- `src/tools/llm-chat/components/screenshot/ShareScreenshotDialog.vue`
- `src/tools/llm-chat/components/screenshot/MessageRangePanel.vue`（`19-83,131-164`）
- `src/tools/llm-chat/components/screenshot/ScreenshotConfigPanel.vue`
- `src/tools/llm-chat/components/screenshot/ScreenshotPreviewPanel.vue`
- `src/tools/llm-chat/components/screenshot/ScreenshotRenderer.vue`
- `src/tools/llm-chat/composables/features/useScreenshotGenerator.ts`
- `src/tools/llm-chat/utils/screenshotCapture.ts`
- `src/tools/llm-chat/composables/features/useExportManager.ts`
- `src/tools/llm-chat/components/export/ExportBranchDialog.vue`
- `src/tools/llm-chat/components/ChatArea.vue`（截图对话框唯一实例化点与入口汇聚）
- `src/tools/llm-chat/LlmChat.vue`（`currentActivePathWithPresets` 传入点）
- `src/tools/llm-chat/stores/llmChatStore.ts`（活动路径计算 `256-289`）
- `src/tools/llm-chat/stores/session/sessionAccessManager.ts`（活动路径回溯 `74-102`）
- `src/tools/llm-chat/utils/chatPathUtils.ts`（预设展示消息 `61-125,88-124`）
- `src/tools/llm-chat/services/sessionImportExportService.ts`（备份 ZIP 往返）
- `src/tools/llm-chat/components/sidebar/BatchManagerDialog.vue`（批量备份导入导出入口）
- `src/components/common/BaseDialog.vue`（默认 `destroyOnClose: true`）
