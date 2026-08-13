# Cherry Studio 对话导出与分享调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：静态源码局部调查；读取 Topic 图片动作总线、离屏消息捕获宿主、完整消息分页加载、消息列表截图执行、图片工具函数及相关测试入口；未运行 Electron 应用或实际导出图片
>
> 调查范围：Topic 与单消息的 PNG 复制/保存、离屏完整列表、长内容捕获、资源内联和内容过滤；不覆盖 Markdown/备份导出、Notes 图片导出和远端分享
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的对话图片导出以**离屏复刻真实消息列表**为核心。Topic 导出请求通过 action bus 送到专用 `TopicImageCaptureHost`；宿主分页读取 Topic 消息，在屏幕左侧 10000px 外建立固定宽 960px、非交互的完整 `MessageList`，随后使用 `html-to-image` 把完整滚动内容转换为 Canvas。用户可以复制 PNG 或保存 PNG。

它没有独立分享稿编辑器或生成历史，视觉结果主要跟随消息列表组件和当前主题。实现对长图和本地资源做了专门治理：计算完整 scroll 尺寸、拒绝任一维度超过 32767px 的画布、临时内联本地图片、过滤隐藏节点与交互 HTML Artifact，并预热一次资源缓存后再正式捕获。

Topic 数据请求显式使用 `includeSiblings: true`，投影结果为兄弟消息标记 `metadata.isActiveBranch`。本次尚未走通 `MessageList` 在 capture mode 下对非活动兄弟的最终过滤，因此不能确认图片会同时展示所有分支还是只展示活动路径。

## 系统边界与完整主链

```text
Topic 菜单“导出图片/复制图片”
  -> topicImageActionBus 排队请求
  -> TopicImageCaptureHost 分页读取 Topic 消息
  -> projectBranchMessagesToUI 投影消息与活动分支标记
  -> 屏外 MessageImageCaptureHost + MessageList 完整渲染
  -> captureScrollable / captureScrollableAsDataUrl
  -> 复制 PNG Blob / saveImage 保存 PNG Data URL
```

单条消息另有直接捕获消息容器的命令：`message.copyImage` 和 `message.exportImage`，复用相同 `captureScrollable*` 工具（`../../cherry-studio/src/renderer/components/chat/messages/frame/messageMenuBarActions.tsx:225-252`）。

## 1. Topic 数据抽取与离屏投影

`getTopicImageCaptureMessages(topicId)` 以每页 200 条循环调用 `/topics/{id}/messages`，参数为 `includeSiblings: true`，收集全部分页后反转页序、展平，再调用 `projectBranchMessagesToUI()` 并过滤不可渲染会话消息（`pages/home/messages/TopicImageCaptureHost.tsx:20-35`）。

`projectBranchMessagesToUI()` 展平 `BranchMessage[]`，把共享消息转成 `CherryUIMessage`，并写入 `metadata.isActiveBranch`（`hooks/useTopicMessages.ts:305-319`）。这说明捕获数据层能辨识活动和非活动兄弟，但最终图片是否隐藏非活动项仍取决于 `MessageList`/`MessageGroup` 的 capture-mode 显示逻辑，本次没有完成该层验证。

`MessageImageCaptureHost` 使用 `aria-hidden`、`inert` 和 `pointer-events-none`，定位在 `left:-10000px`，宽度固定 960px、容器本身高度 1px 且 overflow hidden；内部仍挂载完整 `MessageListProvider + MessageList`（`components/chat/messages/MessageImageCaptureHost.tsx:13-35`）。因此捕获不依赖用户当前滚动到哪里，也不会把屏外捕获表面暴露为可交互 UI。

## 2. 捕获与长图生成

`MessageList` 收到 capture action 后等待两帧布局，再执行：

- `copy`：`captureScrollable()` -> Canvas -> PNG Blob -> `copyImage`；
- `export`：`captureScrollableAsDataUrl()` -> PNG Data URL -> `saveImage(topic.name, data)`（`components/chat/messages/MessageList.tsx:467-498,557-608`）。

`captureScrollable()` 读取元素完整 `scrollWidth/scrollHeight`，而不是当前视口尺寸。主要边界包括（`renderer/utils/image.ts:180-248`）：

- 总宽或总高超过 32767px 时直接返回 `dimension_too_large` 错误；
- `data-html-artifact` 节点被过滤，交互 HTML Artifact 不进入图片；
- `display:none` 和计算样式隐藏的节点被过滤；
- 本地图片源先由 `inlineLocalImageSources()` 临时转为可捕获内容，完成后恢复；
- 背景取 CSS `--background`，像素倍率使用 `window.devicePixelRatio`；
- 高度、overflow、position 和滚动条样式被临时覆盖为完整展开状态；
- 先执行一次 `htmlToImage.toCanvas()` 预热资源缓存并销毁暖机 Canvas，再正式生成。

这是一张单 Canvas 长图，没有像 DeepChat 那样分段捕获后在主进程拼接。32767px 上限是显式失败边界。

## 3. 单消息图片与完整 Topic 图片

消息操作栏的 `message.copyImage`/`message.exportImage` 直接捕获当前消息容器；保存文件名通过 `getMessageTitle(messageForExport)` 生成。Topic 级操作则使用屏外完整列表，文件名来自 `topic.name`（`messageMenuBarActions.tsx:225-252`；`pages/home/messages/homeMessageListAdapter.tsx:917-925`）。

两者都复用消息实际组件和主题，不提供选区、排序、布局、背景、水印或品牌条编辑。Topic 级范围是项目负责组装的完整消息投影，单消息级范围是当前消息卡；没有发现介于两者之间的任意多选图片分享稿。

## 4. 富内容、附件与安全边界

复用真实 `MessageList` 有利于保持 Markdown、工具卡、reasoning、附件和消息壳的一致表达。但导出 sink 做了明确差异化：交互 HTML Artifact 被排除，说明聊天可执行内容不会原样进入静态图片。其他 Artifact、远端图片、音视频和超宽表格的降级未运行验证。

本地图片在捕获前临时内联，降低了 Electron 本地协议无法被 `html-to-image` 读取的风险。远端图片使用 `cacheBust` 和透明占位配置；CORS 失败时最终是占位、遗漏还是整体失败需要运行确认。

本次没有找到图片导出专用的敏感信息扫描或字段开关。图片表达继承当前消息列表的可见内容；是否隐藏 system、路径、工具参数和 reasoning 由上游消息投影与 UI 配置决定。

## 5. 生成历史、分享与持久化

每次动作即时捕获并交给剪贴板或保存 API，没有截图预览、应用内结果列表、版本比较或过时标记。生成结果不绑定 Topic 数据库，也未形成远端分享对象。复制和保存之外的系统 Share Sheet、访问控制、撤销与过期不适用。

## 6. 设计取舍与已确认边界

- 离屏完整列表避免虚拟列表、当前滚动位置和当前页面未加载完整数据导致长图缺段。
- 复用真实消息组件提高现场与导出的表达一致性，但也使导出依赖消息列表的分支过滤和 UI 状态。
- 单 Canvas 捕获实现直接，尺寸超过 32767px 时明确拒绝，不做分页或缩放降级。
- 交互 HTML Artifact 被主动排除，静态图片不会尝试执行或拍下该运行表面。
- 当前实现是“复刻并交付”，不是“编辑分享稿再生成”。

## 7. 未验证事项

- `includeSiblings: true` 后非活动兄弟在最终捕获 DOM 中的可见性，以及多分支图片语义。
- Home 与 Agent 两套消息表面对 Topic/Session 图片动作的范围是否完全一致。
- 工具调用、reasoning、附件、图片、表格和非 HTML Artifact 的实际保真。
- 32767px 边界附近的错误反馈、内存占用和取消行为。
- Windows/macOS/Linux 的剪贴板与保存文件结果。
- 图片捕获相关测试虽存在，本次未执行测试或构建。

## 8. 关键源码索引

- `src/renderer/pages/home/messages/TopicImageCaptureHost.tsx`
- `src/renderer/pages/home/messages/topicImageActionBus.ts`
- `src/renderer/components/chat/messages/MessageImageCaptureHost.tsx`
- `src/renderer/components/chat/messages/MessageList.tsx`
- `src/renderer/components/chat/messages/frame/messageMenuBarActions.tsx`
- `src/renderer/hooks/useTopicMessages.ts`
- `src/renderer/utils/image.ts`
- `src/renderer/components/chat/messages/__tests__/MessageList.test.tsx`

