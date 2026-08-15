# NextChat 对话导出与分享调查笔记

> 调查对象：`E:\works\git\NextChat`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：静态源码局部调查；读取消息导出弹窗、选择器交接、文本/JSON/图片预览、PNG 复制与下载、ShareGPT 调用入口、client adapter、next.config 重写、Service Worker 图片缓存与 Markdown 渲染管线；未运行浏览器、Tauri 客户端或远端分享服务
>
> 调查范围：本次补充 share adapter 下钻、分享权限与撤销、跨域图片处理、复杂富内容在导出端的保真；不覆盖整应用备份、Artifact 分享和远端 ShareGPT 服务实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 使用一个两步式 `MessageExporter` 统一文本、图片和 JSON 三种导出。用户先选择格式、决定是否包含 Mask context，并逐条勾选当前会话消息；第二步进入对应预览。图片模式用固定分享版式重新渲染标题、品牌、参与者、模型、消息数、话题、时间、头像、Markdown 正文和消息图片，再通过 `html-to-image` 生成 PNG；它不截取当前聊天视口。

图片可复制到剪贴板或下载；移动浏览器改为图片查看弹窗，Tauri 客户端走原生保存对话框。三种预览都显示“分享到 ShareGPT”操作，但该操作会重新投影消息、调用 `ClientApi.share()` 并返回 URL，上传内容不包含当前 PNG。`share()` 是 ClientApi 基类上的唯一实现，与 Provider 选择无关；Web 端经 next.config 的 `/sharegpt` 重写转发到 ShareGPT，Tauri 端直连，请求不带任何认证头。客户端只创建链接：无撤销、删除、过期或更新路径，创建结果也不在本机持久化。

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
  -> ClientApi.share(messages)（基类单实现，与 Provider 无关）
  -> POST /sharegpt（next.config beforeFiles rewrite）或 ShareGPT 直连（Tauri）
  -> 返回 shareg.pt URL、复制并打开
```

## 1. 导出源与内容选择

三种格式（文本、图片、JSON）共用同一选择状态，选择器默认全选；用户勾选的 `selectedMessages` 在上下文开关开启时先追加 Mask context，再按勾选追加当前会话消息（`../../NextChat/app/components/exporter.tsx:153-181,245-249`）。

因此 Mask context 不参与逐条选择，由一个总开关整体包含。消息选择允许保留任意子集，不受连续范围约束；最终顺序保持 Mask context 在前、会话消息按原数组顺序在后。分支、隐藏版本和工具调用的结构化保留不在本文件已读模型中体现。

## 2. 文本与 JSON 导出

文本模式实际生成 Markdown：以会话话题为一级标题，每条消息按“用户/ChatGPT”二级标题拼接 `getMessageTextContent()`，可复制或下载为 `<topic>.md`（`exporter.tsx:618-655`）。

JSON 模式生成 OpenAI 风格的 `messages` 数组：开头插入一条 role 为 system、内容为话题说明的合成消息，随后每条只保留所选消息的 role 与 content 字段。复制走压缩 JSON，下载以完整序列化输出，预览则把缩进 JSON 包进 Markdown 代码块（`exporter.tsx:657-691`）。该结构是有损投影，不对应原始 Session schema；消息 ID、日期、模型、附件和分支字段均不会进入。

## 3. 图片分享稿与 PNG 生成

`ImagePreviewer` 建立专用 `.preview-body`，顶部固定显示 NextChat 品牌、仓库地址、用户与 Mask 头像、模型、消息数、话题和最后一条消息时间。正文按角色重新排版：用户行反向排列，助手与用户使用不同背景；正文经共享 Markdown 组件渲染（`exporter.tsx:409-613`；`exporter.module.scss:75-190`）。

消息图片经 `getMessageImages` 提取，只收集 content 数组中 image_url 类型的 URL（`app/utils.ts:270-281`）；单张按宽度展示，多张进入按图片数计算尺寸的网格（`exporter.tsx:582-608`）。

图片来源在多数场景同源：Service Worker 可用时，图片先上传到本应用 `/api/cache/<nanoid>.<ext>` 缓存路径并由 SW 应答，否则用 Canvas 压缩成不超过 256KB 的 data: URL（`app/utils/chat.ts:15-71,144-165`、`public/serviceWorker.js:22-41`）。因此 PNG 导出遇到的绝大多数消息图片是 data: URL 或同源 URL，html-to-image 内联时不会触发跨域污染。

用户直接粘贴的第三方远端图片 URL 会保持引用进入 img 元素，导出链路中没有任何代理、转 base64 或跨域属性处理；这类图片若无 CORS 响应头，Canvas 会被污染或资源获取失败，复制与下载的 catch 只弹“复制失败/下载失败”Toast（`exporter.tsx:420-442,446-495`）——后一段是基于 html-to-image（package.json 锁定 `^1.11.11`）库行为的推断，node_modules 未安装、未运行验证。

输出有两条路径：

- 复制：把预览 DOM 转成 image/png 类型的 Blob 后写入系统剪贴板；桌面宽屏显示该按钮，移动端隐藏；
- 下载：把预览 DOM 转成 Data URL；Web 用 `<a download>` 下载，Tauri 打开保存对话框并写入文件，移动浏览器改为图片查看弹窗（`exporter.tsx:419-502`）。

没有发现图片主题、尺寸、水印或元素显隐配置，也没有多次生成结果列表。修改选择后重新进入预览即得到新的当前分享稿，旧 PNG 不在应用内保留。

## 4. ShareGPT 链接分享交接

分享按钮先标记导出意图，在视口外渲染一份只读副本，等每条 Markdown 渲染完成后把用户消息转为纯文本、助手消息取内部 HTML，构造成轻量消息数组并调用当前 Provider 对应的 client 分享方法（`exporter.tsx:259-406`）。返回字符串被当作分享 URL：弹窗显示并允许复制，800ms 后由 `window.open()` 打开（`exporter.tsx:346-348`）。图片预览中的 Share 按钮也走这条消息 HTML 分享链，不会上传刚生成的 PNG。

### 4.1 share adapter：基类单实现、Provider 无关

`share()` 只定义在 `ClientApi` 基类上，LLM 抽象类没有该方法（`app/client/api.ts:191-228`）。`getClientApi`（`api.ts:368-399`）只负责选择用哪个 Provider 的 LLM 客户端，因此无论当前模型是哪个 Provider，分享都走同一条 ShareGPT 管线。这是下钻后对初版笔记表述的修正：并非各 Provider 各自实现分享方法。

数据口径与发送细节（`api.ts:191-228`）：

- 投影：每条消息被扁平化为发送方与内容两个字段。发送方 `from` 仅区分角色是否为 user，其余一律记作 gpt；内容 `value` 直接取原始 content，多模态用户消息会把多媒体内容数组原样序列化进 JSON（服务端如何处理未验证）；
- 溯源消息：末尾强制追加一条发送方为 human、值为 `"Share from [NextChat]: https://github.com/Yidadaa/ChatGPT-Next-Web"` 的固定消息，源码注释说明该消息用于数据清洗、禁止二开者修改（`api.ts:197-205`）；
- 发送：Web 端 POST 到 `/sharegpt`，该地址是 `next.config.mjs:96-98` 的 beforeFiles 重写（目标 `https://sharegpt.com/api/conversations`），不经过 API 路由、服务端逻辑或密钥；Tauri 客户端经 isApp 判断直接 POST 同一远端地址。请求头只有 Content-Type，不带任何 token 或 API key；
- 响应：取响应中的 id 拼成 `https://shareg.pt/{id}` 返回；响应无 id 时返回 undefined，分享弹窗静默结束、无错误提示；请求异常则弹出错误详情并复位 loading（`exporter.tsx:313-354`）。

### 4.2 权限、撤销与快照语义

- 创建语义是快照分享：POST 时把选中消息投影后的 payload 一次性发给第三方，源会话后续变化不会反映到已创建链接；
- 客户端无任何管理闭环：全仓搜索 `sharegpt|shareg.pt|ShareGPT` 只命中 `app/client/api.ts`、`next.config.mjs`、README 与各 locale 文件；没有删除、撤销、过期、更新接口或管理 UI；store 目录下无任何 share 状态，创建出的 URL 不在本地持久化，重新打开应用后无法列出或找回；
- 认证与访问控制完全交给第三方 ShareGPT：本地代码无法确认 URL 是否可枚举、内容保留期、登录要求与公开范围；分享请求本身也未携带本地用户身份。

## 5. 富内容保真、隐私与边界

导出端复用聊天现场同一套 Markdown 渲染管线（`app/components/markdown.tsx`）：react-markdown 配合 remark 数学/GFM/硬换行插件与 rehype 的 KaTeX、代码高亮插件，KaTeX CSS 全局引入（`markdown.tsx:1-7,270-317`）。因此数学、代码高亮、GFM 表格、引用以及音频/视频链接内嵌播放器（`markdown.tsx:292-307`）在 PNG 预览中与现场渲染一致，不额外降级。以下为逐项确认：

- thinking/reasoning：流式阶段把思考内容组装为以引用行（blockquote）写入助手内容（`app/utils/chat.ts:602-649`）；四种导出端都用不经过滤的 `getMessageTextContent()`（`app/utils.ts:236-246`），因此 Markdown、JSON、PNG、ShareGPT 都包含思考全文，JSON 里是带引用标记的原始文本。剔除思考内容的另一版本只用于 provider 请求 payload，不参与导出。
- 工具调用：`ChatMessage.tools`（`app/store/chat.ts:44-66`）不被任何导出投影读取，结构化工具卡不导出；工具调用只有以文本形式写进消息内容时才会出现在交付物中。
- Mermaid：`PreCode` 检测语言为 mermaid 的代码块后异步转 SVG（`markdown.tsx:28-72,83-100`）。PNG 导出若渲染已完成，SVG 会进入截图；但 ShareGPT 分享稿在挂载时同步抓取内部 HTML（`exporter.tsx:264-287`），与 mermaid 的异步渲染和 Markdown 组件的动态加载存在竞态，抓到的助手 HTML 可能只含未渲染的原始代码块——静态推断，需运行验证。
- 代码折叠：代码块组件初始为折叠态，超过 400px 的代码块默认折叠并出现“显示更多”按钮（`markdown.tsx:176-229`），`enableCodeFold` 默认开启（mask 与全局配置双开关）。图片导出没有关闭折叠的路径，长代码块在 PNG 中可能呈现 400px 截断态——静态推断，需运行验证。
- RenderExport 内容口径（ShareGPT 侧）：用户消息只取纯文本（多模态数组只渲染第一个文本片段，用户图片不进入分享 payload）；助手消息取内部 HTML（含已渲染的数学、代码高亮、audio/video 元素与可能的图片）。远端清洗与脚本安全完全交给 ShareGPT 服务端。
- JSON 是训练/接口风格的简化结构，`content` 原样取值（多模态时为数组），不保留消息 ID、日期、模型、tools 等字段，不能据此恢复 NextChat Session。
- 隐私边界：`includeContext` 默认开启，Mask context 会一并进入四种交付物；无密钥或个人信息扫描；图片文件名直接使用 `${topic}.png`，Tauri 对话框和浏览器对非法文件名的实际处理未运行验证。

## 6. 设计取舍与已确认边界

- 三种格式共用消息选择和上下文开关，用户能够在同一入口切换面向阅读、视觉传播和接口交换的表达。
- 图片使用专用品牌版式，结果稳定且便于传播，但不能像 AIO Hub 那样编辑视觉配置或比较生成版本。
- 本地图片导出和远端 ShareGPT 是两条独立 sink；“图片预览中点击分享”发送消息内容，图片文件不会进入该链路。
- JSON 是有意简化的 messages payload，不具备备份格式的完整性；整应用 Backup 另属会话管理与备份恢复。
- 分享治理刻意保持单点：`share()` 单实现、无本地记录、无撤销/删除，链接生命周期完全依赖第三方 ShareGPT；CORS 问题用一次同源 rewrite 解决，服务端零鉴权。
- thinking 在导出端不做脱敏，与 API 发送方向的 `getMessageTextContentWithoutThinking` 形成口径差；对隐私敏感的思考内容，用户在导出前只能靠 `includeContext` 开关部分控制。

## 7. 未验证事项

- ShareGPT 服务端行为：URL 是否可枚举、登录与访问控制、内容保留期、是否有服务端删除接口（客户端未见对应调用）。
- `html-to-image` 对无 CORS 头的远端图片的实际失败表现、DPR/尺寸默认值与字体（KaTeX）嵌入——node_modules 未安装，以上为基于库行为的推断。
- `RenderExport` 挂载 effect 与 Mermaid 异步渲染、Markdown 动态 import 之间的竞态是否导致 ShareGPT 分享稿缺失 Mermaid SVG 或代码高亮。
- 长代码块在 PNG 中的折叠态、超长会话 Canvas 上限与内存表现（当前实现未见分段拼接）。
- ShareGPT 服务端对多模态 `value` 数组字段的解析行为。
- Web、移动浏览器和 Tauri 的剪贴板/下载运行结果；JSON 与 Markdown 的导入往返路径（本次未找到导出文件级 schema）。

## 8. 关键源码索引

- `app/components/exporter.tsx`
- `app/components/exporter.module.scss`
- `app/components/message-selector.tsx`
- `app/client/api.ts`
- `app/locales/cn.ts`
- `next.config.mjs`（`/sharegpt` beforeFiles rewrite）
- `app/utils.ts`（`getMessageTextContent`、`getMessageImages`）
- `app/utils/chat.ts`（`compressImage`、`uploadImage`、thinking 组装）
- `public/serviceWorker.js`（`/api/cache` 图片上传与缓存应答）
- `app/components/markdown.tsx`（共享渲染管线、Mermaid、代码折叠）
- `app/store/chat.ts`（`ChatMessage`/`ChatMessageTool` schema）
