# NextChat 对话导出与分享调查笔记

> 调查对象：`E:\works\git\NextChat`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：静态源码局部调查；读取消息导出弹窗、选择器交接、文本/JSON/图片预览、PNG 复制与下载、ShareGPT 调用入口；未运行浏览器、Tauri 客户端或远端分享服务
>
> 调查范围：当前会话的消息选择、Mask context 包含策略、Markdown/JSON/PNG 生成和分享按钮交接；不覆盖整应用备份、Artifact 分享和远端 ShareGPT 服务实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 使用一个两步式 `MessageExporter` 统一文本、图片和 JSON 三种导出。用户先选择格式、决定是否包含 Mask context，并逐条勾选当前会话消息；第二步进入对应预览。图片模式不是截取当前聊天视口，而是用固定分享版式重新渲染标题、品牌、参与者、模型、消息数、话题、时间、头像、Markdown 正文和消息图片，再通过 `html-to-image` 生成 PNG。

图片可复制到剪贴板或下载；移动浏览器改为图片查看弹窗，Tauri 客户端走原生保存对话框。三种预览都显示“分享到 ShareGPT”操作，但该操作重新投影消息后调用当前 Provider client 的 `share()`，返回 URL；它不是把当前 PNG 上传为图片。本次未下钻各 client adapter 和远端服务，链接权限、保留期与撤销均未确认。

## 系统边界与完整主链

```text
当前 Session.messages + 可选 Session.mask.context
  -> MessageSelector 逐条选择
  -> 选择 text / image / json
  -> MarkdownPreviewer / ImagePreviewer / JsonPreviewer
  -> 复制或下载本地交付物
```

分享链接走独立交接：

```text
同一 selectedMessages
  -> RenderExport 重新渲染并提取用户纯文本、助手 innerHTML
  -> getClientApi(provider).share(messages)
  -> 返回 URL、复制并打开
```

## 1. 导出源与内容选择

`formats = ["text", "image", "json"]`。选择状态来自 `useMessageSelector()`，`MessageSelector` 默认全选；`selectedMessages` 先在 `includeContext=true` 时追加 `session.mask.context`，再追加当前会话中 ID 被选中的消息（`../../NextChat/app/components/exporter.tsx:153-181,245-249`）。

因此 Mask context 不参与逐条选择，而是由一个总开关整体包含。消息选择不是连续范围约束，可以保留任意子集；最终顺序保持 Mask context 在前、会话消息按原数组顺序在后。分支、隐藏版本和工具调用的结构化保留不在本文件已读模型中体现。

## 2. 文本与 JSON 导出

文本模式实际生成 Markdown：以会话话题为一级标题，每条消息按“用户/ChatGPT”二级标题拼接 `getMessageTextContent()`，可复制或下载为 `<topic>.md`（`exporter.tsx:618-655`）。

JSON 模式生成一个 OpenAI 风格的 `messages` 数组，开头增加 `role: "system"`、内容为话题说明的合成消息，随后只保留所选消息的 `role` 与 `content`。复制使用压缩 JSON，下载同样使用 `JSON.stringify(msgs)`；预览则把缩进 JSON 包进 Markdown 代码块（`:657-691`）。这不是原始 Session schema 的无损导出，消息 ID、日期、模型、附件和分支字段不会进入该结构。

## 3. 图片分享稿与 PNG 生成

`ImagePreviewer` 建立专用 `.preview-body`，顶部固定显示 NextChat 品牌、仓库地址、用户与 Mask 头像、模型、消息数、话题和最后一条消息时间。正文按角色重新排版：用户行反向排列，助手与用户使用不同背景；正文经共享 Markdown 组件渲染（`exporter.tsx:409-613`；`exporter.module.scss:75-190`）。

消息图片由 `getMessageImages(m)` 提取：一张图按宽度展示，多张图进入网格并按图片数计算尺寸。图片 URL 直接用于 `<img src>`，本次未见导出前主动复制或内联资源的代码；`html-to-image` 对远端跨域资源的实际处理和失败降级需运行验证。

输出有两条路径：

- 复制：`toBlob(previewDOM)` -> `ClipboardItem({"image/png": blob})` -> `navigator.clipboard.write()`；桌面宽屏显示该按钮，移动端隐藏；
- 下载：`toPng(previewDOM)` 返回 Data URL；Web 创建 `<a download>`，Tauri 打开保存对话框并把 Data URL `fetch` 成字节写入，移动浏览器改为 `showImageModal()`（`exporter.tsx:419-502`）。

没有发现图片主题、尺寸、水印或元素显隐配置，也没有多次生成结果列表。修改选择后重新进入预览即得到新的当前分享稿，旧 PNG 不在应用内保留。

## 4. ShareGPT 链接分享交接

`PreviewActions` 的分享按钮设置 `shouldExport=true`，在视口外渲染 `RenderExport`。它等待每条 Markdown DOM 出现，然后把用户消息变成 `textContent`，助手消息变成 `innerHTML`，构造成轻量 `ChatMessage[]`，调用 `getClientApi(config.modelConfig.providerName).share(msgs)`（`exporter.tsx:259-406`）。

返回字符串被当作分享 URL：弹窗显示并允许复制，800ms 后 `window.open()`。本次只确认客户端调用入口；不同 Provider 的 `share()` 是否都指向 ShareGPT、是否建立快照、是否公开、能否撤销或过期，未继续追踪。图片预览中的 Share 按钮也走这条消息 HTML 分享链，不会上传刚生成的 PNG。

## 5. 富内容、隐私与边界

- 图片稿使用 `getMessageTextContent()` 和共享 Markdown 渲染，消息中一层或多层图片另行插入；工具调用、reasoning、引用和 Artifact 的保留取决于这些字段是否被该文本/图片提取函数投影，本次未下钻。
- JSON 是训练/接口风格的简化结构，不保留完整会话身份，不能据此恢复 NextChat Session。
- `includeContext` 默认开启，Mask context 可能包含发送前提示内容；界面有开关，但本次未找到密钥或个人信息扫描。
- 图片文件名直接使用 `${topic}.png`；Tauri 对话框和浏览器对非法文件名的实际处理未运行验证。
- 分享链把助手渲染后的 `innerHTML` 交给 client adapter；远端清洗和脚本安全不在本地已读范围内。

## 6. 设计取舍与已确认边界

- 三种格式共用消息选择和上下文开关，用户能够在同一入口切换面向阅读、视觉传播和接口交换的表达。
- 图片使用专用品牌版式，结果稳定且便于传播，但不能像 AIO Hub 那样编辑视觉配置或比较生成版本。
- 本地图片导出和远端 ShareGPT 是两条独立 sink；“图片预览中点击分享”仍分享消息内容，而非图片文件。
- JSON 是有意简化的 messages payload，不是备份格式；整应用 Backup 另属会话管理与备份恢复。

## 7. 未验证事项

- `getClientApi(...).share()` 各 Provider 实现、服务端访问权限、内容快照、删除和保留期。
- Markdown 中代码、数学、Mermaid、HTML、工具结果与 reasoning 在 PNG 中的实际保真。
- 远端图片、Data URL、本地附件和跨域资源在 `html-to-image` 中是否完整输出。
- 超长会话的 Canvas 上限、内存和分页行为；当前实现未见分段拼接。
- Web、移动浏览器和 Tauri 的剪贴板/下载运行结果。
- JSON 与 Markdown 是否有对应导入往返路径；本次未找到导出文件级 schema。

## 8. 关键源码索引

- `app/components/exporter.tsx`
- `app/components/exporter.module.scss`
- `app/components/message-selector.tsx`
- `app/client/api.ts`
- `app/locales/cn.ts`

