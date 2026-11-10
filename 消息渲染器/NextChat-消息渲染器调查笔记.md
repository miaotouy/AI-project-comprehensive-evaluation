# NextChat 消息渲染器调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`（重点 `app/components/markdown.tsx`、`app/components/chat.tsx`、`app/utils/chat.ts`、`app/components/artifacts.tsx`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`1d3dc331512929a4b1d3e82354e72acce33b5c7a`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：覆盖聊天消息、Markdown/代码/Mermaid/Artifact、流式推理、媒体和工具状态的渲染路径
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的消息渲染器是一条以 `react-markdown` 为核心、由 Chat 组件负责消息窗口和状态装配的渲染链：

1. `Chat` 组件负责装配消息窗口：它把 Mask 上下文、会话消息以及 loading 与输入预览拼成当前可见的消息序列，再按 user、assistant、system 三种角色分别渲染头像、操作、工具状态、Markdown 正文、图片和音频。
2. Markdown 正文交给 `react-markdown` 渲染，并挂载 GFM、数学公式、软换行、KaTeX 与代码高亮五组插件（清单见 §2.2）。解析前先把 `\[...\]` 与 `\(...\)` 改写成 KaTeX 可识别的定界符，文本里没有代码围栏时还会把整段裸 HTML 文档包进代码块。
3. `<pre>` 元素统一换成 `PreCode`：Mermaid 图单独渲染成 SVG，HTML、DOCTYPE、SVG 与 XML 代码在 Artifact 开启时送进 sandbox iframe，普通代码提供复制按钮并在超过 400px 后折叠。
4. SSE 流式文本通过 `requestAnimationFrame` 逐帧写出；模型返回的 `reasoning_content` 或 `<think>` 块被改写成 Markdown 引用行，渲染层没有独立的 reasoning 数据结构。
5. Artifact 用 `srcDoc` 加载内容，sandbox 只授予 `allow-forms`、`allow-modals`、`allow-scripts` 三项权限，分享内容写入 Cloudflare KV。

## ASCII 调用链图

```text
ChatSession
  -> context + session.messages + loading/input preview
  -> renderMessages 分页窗口
  -> 每条消息 role/状态分派
     -> Avatar / actions / tool status
     -> Markdown(content)
        -> escapeBrackets + tryWrapHtmlCode
        -> react-markdown
           remark-math/gfm/breaks
           rehype-katex/highlight
           pre -> PreCode
           code -> CustomCode
           a -> audio/video/internal link
        -> Mermaid -> mermaid.run -> SVG image modal
        -> HTML/DOCTYPE/SVG/XML -> HTMLPreview iframe
```

流式支路：

```text
SSE delta
  -> streamWithThink.parseSSE
  -> remainText
  -> requestAnimationFrame(animateResponseText)
  -> ChatStore.onUpdate
  -> Markdown key(streaming ? loading : done)
```

## 1. Chat 消息层如何装配

### 1.1 可视消息来源

`app/components/chat.tsx:1333-1384` 先计算 `context`：`session.mask.hideContext` 为 true 时为空，否则复制 Mask context；如果 context 为空且历史第一条不是 bot hello，则插入欢迎消息。随后把 context、session.messages、loading preview 和可选的用户输入 preview 串成 `renderMessages`。

`hideContext` 只影响这个渲染数组，`getMessagesWithMemory` 仍会把 Mask context 发给模型，因而“隐藏”是显示选项而不是请求脱敏开关。

### 1.2 分页窗口

`CHAT_PAGE_SIZE` 为 15（`app/constant.ts:914`）。`Chat` 默认从末尾开始，按 `msgRenderIndex` 取最多 45 条消息；滚动到顶部或底部时以 15 条为步长改变索引（`app/components/chat.tsx:1386-1429`）。这是窗口化分页，不是 DOM 虚拟化；一条超长消息仍可能带来较大的布局成本。

### 1.3 角色和工具状态

消息行在 `app/components/chat.tsx:1771-2040` 内按 `message.role` 判断 user/assistant/system 展示头像。assistant message 的 `tools` 数组在正文上方渲染：

- `isError === false`：成功图标；
- `isError === true`：错误图标和 error tooltip；
- 未完成：加载图标；
- 显示 `tool.function.name`。

正文统一调用 `Markdown`，图片数组、`audio_url` 和日期在 Markdown 之后渲染。工具没有独立的消息树节点，而是 assistant bubble 的一个附加状态区。

## 2. Markdown 处理管线

### 2.1 预处理

`app/components/markdown.tsx:231-273`：

- `escapeBrackets` 先跳过行内代码和 fenced code，再把 `\[...\]` 转成 `$$...$$`、把 `\(...\)` 转成 `$...$`；
- `tryWrapHtmlCode` 在文本没有 fenced block、却出现 `<!DOCTYPE html>` 时，自动补上 `html` 语言标记，完整 HTML 文档因此按代码块处理。

### 2.2 Unified 插件和组件覆盖

`_MarkDownContent`（`app/components/markdown.tsx:270-319`）配置：

```text
remark-math
remark-gfm
remark-breaks
rehype-katex
rehype-highlight (detect=false, ignoreMissing=true)
```

组件覆盖为：

- `pre -> PreCode`：代码复制、Mermaid/Artifact 探测；
- `code -> CustomCode`：高度测量和折叠；
- `p -> <p dir="auto">`；
- `a -> audio/video 或普通链接`。

源码没有启用 `rehype-raw`，因此普通 HTML 不会直接作为 React DOM 执行；完整 HTML 需要落在代码探测/Artifact 路径。

### 2.3 媒体链接

`a` override（`app/components/markdown.tsx:292-310`）按扩展名把媒体链接渲染成内嵌播放器：

| 媒体类型 | 识别的扩展名 | 渲染结果 |
| --- | --- | --- |
| 音频 | `.aac`、`.mp3`、`.opus`、`.wav` | `<audio controls>` |
| 视频 | `.3gp`、`.3g2`、`.webm`、`.ogv`、`.mpeg`、`.mp4`、`.avi` | `<video controls>` |

内部 `/#...` 链接使用 `_self`，其他链接默认为传入 target 或 `_blank`；没有看到统一的 `rel="noopener noreferrer"` 注入。

## 3. 代码块、Mermaid 和 Artifact

### 3.1 普通代码和折叠

`PreCode` 在 effect 中把无语言标记以及 Markdown、text、LaTeX 这几类代码的样式设为 `white-space: pre-wrap`，随后延迟探测 Artifact 内容。`CustomCode` 负责测量 `scrollHeight`，内容超过 400px 时显示 More 按钮；折叠功能同时受全局配置与当前 Mask 开关控制，折叠后的最大高度同样取 400px。两处实现见 `app/components/markdown.tsx:106-229`。

### 3.2 Mermaid

检测到带 mermaid 语言标记的代码块后，`PreCode` 把其中的纯文本转交给 `Mermaid` 组件。该组件在容器节点上调用 `mermaid.run` 并开启 `suppressErrors`，渲染失败时返回空内容；点击容器会把内部 SVG 序列化，生成 `image/svg+xml` 格式的 Blob 后打开图片弹窗。组件定义与调用点都在 Markdown 主组件内，见 `app/components/markdown.tsx:28-150`。

这是一条“代码块先出现在 DOM，再由 Mermaid 替换/追加 SVG”的路径，不是服务端预渲染。

### 3.3 HTML Artifact

`PreCode.renderArtifacts` 检查三类内容：

- `code.language-html`；
- 代码文本以 `<!DOCTYPE`、`<svg` 或 `<?xml` 开头。

检测结果只在 `session.mask.enableArtifacts !== false && config.enableArtifacts` 时展示（`app/components/markdown.tsx:102-105`、`148-171`）。预览包括刷新按钮、全屏容器和分享按钮，iframe 组件在 `app/components/artifacts.tsx:36-107`。

## 4. 流式文本和 reasoning

### 4.1 文本动画

`stream` 与 `streamWithThink` 两个流式入口都维护已输出与待输出的文本缓冲区。每个 animation frame 按剩余长度的比例取字符（约 1/60，下限 1 个）并通过更新回调交给上层，连接关闭或收到 `[DONE]` 后一次性收尾。实现见 `app/utils/chat.ts:197-446`。

Chat store 的 `onUpdate` 更新 assistant message.content，Chat 组件用 `message.streaming` 改变 Markdown key 和 loading 状态（`app/store/chat.ts:459-480`、`app/components/chat.tsx:1969-1987`）。

### 4.2 推理输出转换

OpenAI 适配器从流式增量中取出 `reasoning_content` 字段（`app/client/platforms/openai.ts:322-385`），`streamWithThink` 另外识别正文里的 `<think>` 标签对（`app/utils/chat.ts:586-615`）。thinking mode 打开时，它把每段内容写成：

```text
> 第一段推理
> 第二段推理

最终回答
```

实现位置为 `app/utils/chat.ts:618-649`。因此渲染层只看到一段带 Markdown blockquote 的普通字符串，没有独立的 reasoning part、折叠状态或安全边界。

## 5. Artifact iframe、分享和存储

### 5.1 iframe 隔离

`HTMLPreview` 用 `srcDoc` 加载代码，并设置：

```text
sandbox="allow-forms allow-modals allow-scripts"
```

没有 `allow-same-origin`，模型生成页面不能以父页面同源身份访问 cookie/localStorage。注入的 ResizeObserver 向父窗口发送 frame id 与高度；标题没有由该脚本发送。父窗口对高度比较 frame id，对 title 却在比较前直接更新，两个字段都未核验事件来源。见 [监听器与注入脚本](../../NextChat/app/components/artifacts.tsx#L50-L87)。该 iframe 路径没有独立 CSP 或请求 allowlist。

### 5.2 分享和 Cloudflare KV

`ArtifactsShareButton` POST 原始 HTML 到 `ApiPath.Artifacts`，返回 id 后组成 `#/artifacts/<id>` 分享链接（`app/components/artifacts.tsx:109-203`）。`app/api/artifacts/route.ts:5-73` 在 Edge runtime：

1. POST 读取 body，计算 MD5 作为 KV key，相同内容复用同一 id；
2. 根据 `CLOUDFLARE_KV_TTL` 设置 expiration；
3. 写入 Cloudflare KV；
4. GET 按 id 读取并原样返回。

Artifact 页面再把 KV 内容交给相同的 `HTMLPreview`（`app/components/artifacts.tsx:205-265`）。

## 6. 边界与未验证事项

- `app/components/artifacts.tsx:83-85` 调用了 `props.code.replace(...)` 却没有接收返回值，随后仍返回 `script + props.code`；当前脚本因整体前置仍可工作，“在 DOCTYPE 后插入脚本”的分支未实现。
- Artifact 是全局配置与 Mask 双开关：全局关闭或 Mask 关闭时，HTML 代码只按代码块显示，没有在消息级别记录用户为何不能预览。
- Mermaid 失败直接返回空内容；Markdown/iframe 的错误隔离依赖 React/UI 外层。
- 流式推理被编码为 Markdown 引用文本，复制、导出和后续上下文都会把 `> ` 前缀当作普通 Markdown 内容。
- `react-markdown` 使用高亮和 KaTeX 但没有服务端预渲染，长代码、复杂 Mermaid 和大量图片会占用浏览器主线程。

未验证：本次未启动浏览器验证 Mermaid SVG、Artifact iframe 高度、移动端分页和恶意 HTML；结论来自源码静态检查。

## 7. 关键源码索引

- Markdown 主组件和 Mermaid：`app/components/markdown.tsx:1-72`
- 代码块/Artifact 探测：`app/components/markdown.tsx:74-174`
- code fold：`app/components/markdown.tsx:176-229`
- Markdown 预处理和插件：`app/components/markdown.tsx:231-319`
- Chat 消息窗口和分页：`app/components/chat.tsx:1333-1429`
- 消息、工具和附件渲染：`app/components/chat.tsx:1771-2040`
- SSE 文本动画：`app/utils/chat.ts:197-220`、`423-446`
- reasoning/thinking 转换：`app/utils/chat.ts:586-649`
- OpenAI reasoning chunk：`app/client/platforms/openai.ts:322-385`
- Artifact iframe 和分享：`app/components/artifacts.tsx:36-203`
- Artifact 页面：`app/components/artifacts.tsx:205-265`
- Artifact KV API：`app/api/artifacts/route.ts:5-73`
