# NextChat 消息渲染器调查笔记

> 调查对象：`E:\works\git\NextChat`（重点 `app/components/markdown.tsx`、`app/components/chat.tsx`、`app/utils/chat.ts`、`app/components/artifacts.tsx`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：覆盖聊天消息、Markdown/代码/Mermaid/Artifact、流式推理、媒体和工具状态的渲染路径
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的消息渲染器是一个以 `react-markdown` 为核心、由 Chat 组件负责消息窗口和状态装配的轻量链：

1. `Chat` 先把 Mask context、会话消息、loading/input preview 组成可视窗口，再按 user/assistant/system 角色渲染头像、操作、工具状态、Markdown、图片和音频。
2. Markdown 使用 `react-markdown` 加一组插件：GFM、数学、软换行、KaTeX 与高亮（插件名见 §2.2 清单）。在解析前会把 `\[...\]`/`\(...\)` 转成 KaTeX 可识别形式，并尝试把裸 HTML 文档包进 `html` 代码块。
3. `<pre>` 被替换为 `PreCode`：Mermaid 代码单独交给 Mermaid 渲染成 SVG；HTML/DOCTYPE/SVG/XML 代码在 Artifact 开启时进入 sandbox iframe；普通代码支持复制和超过 400px 后折叠。
4. SSE 流式文本通过 `requestAnimationFrame` 缓慢吐给 UI；`reasoning_content` 或 `<think>` 块被转成 Markdown 引用行 `> `，没有独立的 reasoning 数据结构。
5. Artifact 通过 `srcDoc` 和 `sandbox="allow-forms allow-modals allow-scripts"`（无 `allow-same-origin`）预览，分享内容写入 Cloudflare KV。

Artifact 预览使用 opaque-origin 沙箱隔离；iframe 高度经 `postMessage` 回传给父窗口。

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

- `escapeBrackets` 避开行内代码和 fenced code，把 `\[...\]` 转为 `$$...$$`，把 `\(...\)` 转为 `$...$`；
- `tryWrapHtmlCode` 在文本中没有 fenced block 且检测到 `<!DOCTYPE html>` 时，自动补 `html` fenced block，避免完整 HTML 文档被当成普通段落。

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

- 音频扩展名 `.aac`/`.mp3`/`.opus`/`.wav` → `<audio controls>`；
- 视频扩展名 `.3gp`/`.3g2`/`.webm`/`.ogv`/`.mpeg`/`.mp4`/`.avi` → `<video controls>`。

内部 `/#...` 链接使用 `_self`，其他链接默认为传入 target 或 `_blank`；没有看到统一的 `rel="noopener noreferrer"` 注入。

## 3. 代码块、Mermaid 和 Artifact

### 3.1 普通代码和折叠

`PreCode` 的 effect 会把无语言、Markdown、text、LaTeX 等代码设为 `white-space: pre-wrap`，然后延迟探测 Artifact（`app/components/markdown.tsx:106-131`）。`CustomCode` 测量 `scrollHeight`，超过 400px 显示 More 按钮；`enableCodeFold` 同时受全局 config 与当前 Mask 开关控制，折叠状态将 `maxHeight` 设为 400px（`app/components/markdown.tsx:176-229`）。

### 3.2 Mermaid

检测到 `code.language-mermaid` 后，`PreCode` 把纯文本交给 `Mermaid`（`app/components/markdown.tsx:83-100`、`148-150`）。`Mermaid` 调用 `mermaid.run`（绑定容器节点、`suppressErrors: true`），错误时返回空内容；点击容器会序列化其中的 SVG，创建 `image/svg+xml` Blob 并打开图片 modal（`app/components/markdown.tsx:28-72`）。

这是一条“代码块先出现在 DOM，再由 Mermaid 替换/追加 SVG”的路径，不是服务端预渲染。

### 3.3 HTML Artifact

`PreCode.renderArtifacts` 检查三类内容：

- `code.language-html`；
- 代码文本以 `<!DOCTYPE`、`<svg` 或 `<?xml` 开头。

检测结果只在 `session.mask.enableArtifacts !== false && config.enableArtifacts` 时展示（`app/components/markdown.tsx:102-105`、`148-171`）。预览包括刷新按钮、全屏容器和分享按钮，真正的 iframe 组件在 `app/components/artifacts.tsx:36-107`。

## 4. 流式文本和 reasoning

### 4.1 文本动画

`stream`/`streamWithThink` 在 `app/utils/chat.ts:197-220`、`423-446` 中维护 `responseText` 与 `remainText`。每个 animation frame 按剩余长度的比例取出若干字符（约 1/60，下限 1），调用 `options.onUpdate(responseText, fetchText)`；连接关闭或 `[DONE]` 后一次性收尾。

Chat store 的 `onUpdate` 更新 assistant message.content，Chat 组件用 `message.streaming` 改变 Markdown key 和 loading 状态（`app/store/chat.ts:459-480`、`app/components/chat.tsx:1969-1987`）。

### 4.2 推理输出转换

OpenAI adapter 读取 `delta.reasoning_content`（`app/client/platforms/openai.ts:322-385`），`streamWithThink` 还识别文本中的 `<think>`/`</think>` 标签（`app/utils/chat.ts:586-615`）。在 thinking mode 时，它把每段内容写成：

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

没有 `allow-same-origin`，模型生成页面不能以父页面同源身份访问 cookie/localStorage。组件通过注入的 `ResizeObserver` 脚本以 `parent.postMessage(..., '*')` 向父窗口发送高度和 title（`app/components/artifacts.tsx:81-87`）；父窗口在 `message` listener 中只按 frame id 匹配，未校验 `e.origin`/`e.source`，随机 frame id 用于降低误收概率（`app/components/artifacts.tsx:50-62`）。该 iframe 路径没有独立 CSP 或请求 allowlist。

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
