# Manifold Desktop 信息污染源调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读核对渲染、WebView2 桥、导入存储、MCP 和代理配置；未修改目标仓库
>
> 调查范围：外部内容进入模型、DOM、宿主桥和本地存储的路径
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论

主要风险链集中在两处：未消毒的 assistant Markdown，以及没有来源约束的 WebView2 消息桥。二者组合后，模型输出或导入会话中的活动 HTML可能取得与正常前端相同的桥调用能力。

```text
模型输出 / 导入的 assistant 内容
  -> marked.parse（保留原始 HTML）
  -> innerHTML
  -> 页面脚本上下文
  -> window.chrome.webview.postMessage
  -> MainWindow::OnWebMessage
  -> 本地 handler
```

该链路依据代码成立，但本次没有在 WebView2 中执行利用样例。

## 渲染输入

| 来源 | DOM 写入 | 当前边界 |
| --- | --- | --- |
| assistant 历史/流式文本 | `marked.parse` 后写 `innerHTML` | 无 sanitizer |
| user/system 文本 | `textContent` | 文本节点 |
| tool call 参数/结果 | `textContent` | 文本节点 |
| Chat 错误 | 转义 `&<>` 后写入固定文本位置 | 当前上下文足够 |
| 搜索标题/片段 | 转义后插入固定模板，命中部分加 `<mark>` | 当前上下文足够 |
| 终端文本 | `escHtml()` 后拼结构化 span | 文本已转义 |

`frontend/index.html` 没有 CSP；WebView2 显式开启脚本和 WebMessage（`MainWindow.xaml.cpp:248-255`）。marked 保留原始 HTML，事件处理属性、可加载资源等活动内容可能产生脚本或导航行为。`innerHTML` 插入的 `<script>` 通常不会自行执行，因此原笔记中“任何 HTML/`<script>` 都会执行”的表述不准确。

## 导航与宿主桥

`MainWindow` 只注册 `NavigationCompleted`，没有 `NavigationStarting` 或 `NewWindowRequested` 策略（`MainWindow.xaml.cpp:283-321`）。Markdown 生成的普通链接也没有统一点击拦截。导航完成后，宿主会再次发送包含 settings 和 Provider Key 配置状态的 `HOST_READY`。

前端桥允许页面调用 `window.chrome.webview.postMessage()`；C++ 的 `WebMessageReceived` handler 没有读取或校验消息来源 URI，`OnWebMessage()` 只按 `type` 分派（`MainWindow.xaml.cpp:283-298, 404-454`）。可调用面包括设置、API Key 写入/删除、会话文件、终端、网络请求和 `OPEN_EXTERNAL_URL`。API Key 正文本身不会下发给前端。

仓库中的 `OPEN_EXTERNAL_URL` 只由首页更新按钮使用，消息 renderer 和搜索结果没有调用它；原笔记把 `message-renderer.js:44-48` 说成 `openExternal` 实现，属于错误引用，现已删除。

## 存储与配置输入

- 会话导入不校验 schema，assistant 字段会进入未消毒的 Markdown 路径（`MainWindow.xaml.cpp:648-677`）。
- 会话 id 直接参与 `sessionsDir / (id + ".json")`，桥消息和导入数据中的 id 没有路径成分校验（`SessionManager.cpp:23-26`）。
- 提示词 id 同样直接参与文件路径；正常 UI 使用 `crypto.randomUUID()`，但桥 handler 本身不校验（`PromptManager.cpp:23-25`、`MainWindow.xaml.cpp:1143-1155`）。
- `proxyUrl`、Ollama endpoint 和自定义 Provider endpoint 进入网络请求前没有 scheme/host 白名单。
- API Key 存于 Windows Credential Manager；`settings.json` 保存端点、system prompt、MCP 命令和 device id，不保存 Key 正文。

## MCP 与代理

MCP 工具描述来自外部服务器，会作为工具 schema 发给模型，没有内容过滤。当前运行时没有 `CallTool()` 回环，因此模型产生的 tool call 不会自动执行；工具结果提示注入也尚未进入正常链路。

stdio MCP 命令由用户配置并以宿主权限启动，没有沙箱。独立 `server/` 用无签名的 `X-Manifold-Device-ID` 计配额，调用方可更换 id 获取新配额；该 server 当前没有接入桌面端正常聊天路径。

## 关键文件

| 职责 | 文件 |
| --- | --- |
| Markdown 与文本边界 | `frontend/components/message-renderer.js`、`chat-tab.js` |
| WebView 设置、导航和桥 | `MainWindow.xaml.cpp:248-321, 404-454` |
| 会话导入与文件路径 | `MainWindow.xaml.cpp:648-677`、`Manifold.Core/SessionManager.cpp` |
| 提示词文件路径 | `Manifold.Core/PromptManager.cpp` |
| MCP 外部输入 | `Manifold.Core/MCP/MCPClient.cpp` |
| 凭据 | `Manifold.Core/CredentialManager.cpp` |
| 代理身份与配额 | `server/src/middleware/device-id.js`、`rate-limiter.js` |

## 验证边界

风险级别依据静态数据流判断，未在 WebView2 中验证事件属性执行、跨站导航后的 WebMessage 可用性或路径穿越结果。本文只记录边界，不替代运行时安全测试。
