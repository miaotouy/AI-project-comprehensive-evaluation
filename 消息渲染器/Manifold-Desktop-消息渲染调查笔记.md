# Manifold Desktop 消息渲染调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读核对前端渲染、C++ 流式桥和终端输出；未修改目标仓库
>
> 调查范围：Chat/Compare Markdown、工具块、错误和终端渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论

消息渲染完全位于 WebView2 前端。C++ Provider 在线程中产生 chunk，经 `PostMessageToWeb("CHAT_CHUNK")` 广播；`chat-tab.js` 累积文本并重新生成整条消息的 HTML。

```text
Provider::StreamChat
  -> StreamChunk
  -> CHAT_CHUNK
  -> streamingText += chunk.text
  -> marked.parse(streamingText)
  -> streamingEl.innerHTML = ...
```

实现只有两条正文路径：user/system 使用 `textContent`，assistant 使用 Markdown。没有结构化 reasoning、引用、附件或多 part 渲染层。

## Chat 与 Compare

历史 assistant 消息通过 `renderMessage()` 调用带自定义 code renderer 的 `renderMarkdown()`；流式 Chat 和 Compare 则直接调用裸 `marked.parse()`。三处入口分别在 `message-renderer.js:1-33, 80-105`、`chat-tab.js:27-59` 与 `compare-tab.js:40-56`，因此两条路径行为不同：

- 流式路径每个 chunk 都重新解析累计全文并替换整块 DOM，没有节流；
- 流式代码块没有自定义语言栏、复制按钮或显式 hljs 调用；
- 历史路径试图增加代码高亮和复制按钮；
- 每个 Chat chunk 都强制滚到底部。

当前 bundled marked 是 v15，其 `renderer.code` 回调接收 token 对象；项目仍按旧版 `(code, lang)` 签名处理，并把第一个参数交给只接受字符串的 `esc()`（`message-renderer.js:93-100`）。用仓库内 marked 实测，解析 fenced code block 会抛出 `TypeError: replace is not a function`。普通 Markdown 和流式裸 `marked.parse()` 不受这个自定义回调影响。

流式指示器也存在直接的 DOM 生命周期问题：它先被追加到 `streamingEl`，首个文本 chunk 随后的 `innerHTML = ...` 会立即将其移除（`chat-tab.js:34-45`）。

## 工具、错误与终端

- 工具调用/结果使用独立折叠块。名称经 `esc()` 后进入固定文本位置，参数和结果正文使用 `textContent`（`message-renderer.js:36-78`）。当前这些位置只需转义 `&<>`，引号不构成属性注入。
- `CHAT_ERROR` 文本先转义 `&<>` 再进入固定 `<span>`，附带的 Retry 按钮只删除提示，不会重新发送（`chat-tab.js:87-98`）。
- Compare 用户消息和错误使用 `textContent`；assistant 与 Chat 流式路径相同，使用裸 `marked.parse()`。
- 终端由 C++ `TerminalEmulator` 解析 ANSI，前端按结构化行和样式重建 `<span>`；文本经过 `escHtml()`（`TerminalEmulator.cpp`、`terminal-tab.js:31-49`）。

## HTML 边界

assistant Markdown 没有 sanitizer。marked 会保留原始 HTML，返回值直接写入 `innerHTML`（`message-renderer.js:15-17, 102`、`chat-tab.js:42`）。事件处理属性等活动 HTML 因而可能在 WebView 页面上下文执行；通过 `innerHTML` 插入的 `<script>` 元素通常不会自行执行，不能把所有原始 HTML 等同为相同行为。

页面没有 CSP，WebView2 显式启用脚本和 WebMessage（`frontend/index.html`、`MainWindow.xaml.cpp:248-255`）。Markdown 链接也没有统一点击拦截或导航白名单。

## 关键文件

| 职责 | 文件 |
| --- | --- |
| 历史消息与工具块 | `frontend/components/message-renderer.js` |
| Chat 流式渲染 | `frontend/components/chat-tab.js` |
| Compare 流式渲染 | `frontend/components/compare-tab.js` |
| WebView 消息桥 | `frontend/services/bridge.js`、`MainWindow.xaml.cpp:404-462` |
| 终端解析与呈现 | `Manifold.Core/TerminalEmulator.cpp`、`frontend/components/terminal-tab.js` |
| Markdown 库 | `frontend/vendor/marked.min.js` |

## 验证边界

已用仓库内 Node.js/marked 复现历史代码块 renderer 的类型错误。其余界面表现来自静态源码，未启动 WinUI/WebView2 应用，也未执行 HTML 注入样例。
