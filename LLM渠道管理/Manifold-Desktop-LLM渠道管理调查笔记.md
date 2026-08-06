# Manifold Desktop LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读核对 Provider、凭据、设置面板和 `server/`；未修改目标仓库
>
> 调查范围：渠道注册、协议适配、模型目录、凭据和代理服务器
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论

渠道层采用 `ProviderRegistry + 每 Provider 单 API Key + 全局默认 Provider/模型`。内置 Gemini、OpenAI、Anthropic，并可注册 OpenAI-compatible、Ollama 和 Proxy Provider（`MainWindow.xaml.cpp:128-155`）。

| Provider | 请求协议 | 模型来源 |
| --- | --- | --- |
| Gemini | Google `generateContent` / SSE | 硬编码 4 个 |
| OpenAI | `/v1/chat/completions` / SSE | 硬编码 4 个 |
| Anthropic | `/v1/messages` / SSE | 硬编码 3 个 |
| OpenAI-compatible | 继承 OpenAI | 运行时请求 `/v1/models`，失败给占位项 |
| Proxy | 继承 OpenAI-compatible | 请求代理 `/v1/models`，失败给 3 个 Gemini 项 |

实现没有重试、退避、多 Key、负载均衡、故障转移和健康检查。`streamResponses` 设置没有被发送链读取，Chat 始终调用 `StreamChat()`。

## 注册与发送

`MainWindow` 构造时硬编码注册三个云 Provider；随后读取 `settings.json` 中的 `proxyUrl`、`providerConfigs` 和 `ollamaEndpoint` 注册其他实例（`MainWindow.xaml.cpp:116-155`）。自定义 Provider 没有设置页新增界面，只能手工编辑配置。

发送时按 providerId 从注册表取实例，并从 Windows Credential Manager 读取该 Provider 的 Key；model、temperature 和 system prompt 来自全局设置（`MainWindow.xaml.cpp:757-789`）。MCP 工具只注入常规 Chat，Compare 不注入。

内置协议分别映射 system prompt、图片和工具 schema：Gemini 使用 `systemInstruction`，OpenAI 把 system 消息插入 messages，Anthropic 使用顶层 `system`。三者都实现流式文本、token usage 和 tool call 解析。

## 已确认的连接问题

1. `OpenAICompatProvider::ListModels()` 在需要 Key 时仍发送空认证头（`OpenAICompatProvider.cpp:13-16`），受保护端点通常只能回退到占位模型。
2. Ollama 注册时把 endpoint 保存为 `<ollamaEndpoint>/v1`（`MainWindow.xaml.cpp:149-154`），继承的聊天和模型方法又分别追加 `/v1/chat/completions`、`/v1/models`，形成重复的 `/v1/v1/...` 路径。
3. Proxy 聊天继承 OpenAI 路径 `/v1/chat/completions`，仓库内 `server/` 只挂载 `/v1/chat`；两端路由不一致。
4. `server/` 直接转发 Gemini SSE，而 Proxy 使用 OpenAI SSE 解析器；响应结构也不一致。
5. 默认 `proxyUrl` 是 `https://manifold-proxy.example.com`，非空时会注册 Proxy Provider（`SettingsManager.h:46`）。

这些差异来自静态路径和解析器对照；实际网络行为未验证。

## 凭据与模型选择

API Key 使用 Windows Credential Manager 的 generic credential，目标名为 `Manifold_<providerId>`（`CredentialManager.cpp:47-88`）。`CRED_PERSIST_LOCAL_MACHINE` 表示凭据可跨当前用户在本机的后续登录会话持久化，不表示对所有 Windows 用户公开。前端只收到“是否已配置 Key”的布尔值，不读取 Key 正文。

输入栏提供 Provider 和模型下拉；切换 Provider 后通过桥请求模型列表（`input-bar.js:52-64, 222-236`）。`HandleListModels()` 在消息处理线程同步调用 Provider；对网络型 OpenAI-compatible 端点，模型请求可能阻塞界面（`MainWindow.xaml.cpp:885-901`，未运行验证）。

费用只是 `pricing.js` 的静态估算表；记录保存在 localStorage，不参与渠道选择。

## `server/` 状态

`server/` 是约十余个文件的独立 Express 转发样例，没有被桌面工程、README 的运行步骤或 CI 引用。它提供 `/health`、设备 id 中间件、内存 RPM 和 JSON 日配额，但只把 Gemini 路由挂到 `/v1/chat`。`X-Manifold-Device-ID` 没有签名或服务端身份校验，调用方可以自报任意 id。

因此，`server/` 不能视为已经接通的桌面应用后端。

## 关键文件

| 职责 | 文件 |
| --- | --- |
| Provider 接口和数据类型 | `Manifold.Core/Providers/IProvider.h`、`ProviderTypes.h` |
| 注册表 | `Manifold.Core/Providers/ProviderRegistry.cpp` |
| 协议适配 | `GeminiProvider.cpp`、`OpenAIProvider.cpp`、`AnthropicProvider.cpp` |
| Compatible / Proxy | `OpenAICompatProvider.cpp`、`ProxyProvider.cpp` |
| 凭据 | `Manifold.Core/CredentialManager.cpp` |
| 注册与发送 | `MainWindow.xaml.cpp:116-155, 757-914` |
| 前端选择与费用 | `frontend/components/input-bar.js`、`frontend/services/pricing.js` |
| 独立代理样例 | `server/src/*` |

## 验证边界

未使用真实 API Key、Ollama 或代理服务器发起请求，也未测量 WinHTTP 超时。协议字段和连接问题均按当前快照静态核对。
