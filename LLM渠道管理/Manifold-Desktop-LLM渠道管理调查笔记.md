# Manifold Desktop LLM 渠道管理调查笔记

> 调查对象：`https://github.com/gregorik/Manifold-Desktop`
>
> 调查更新日期：2026-08-18
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读检查配置模型、C++ Provider 注册与消息处理、WebView2 前端、独立 `server/` 和命令行/TUI 相关文件搜索；未修改目标仓库
>
> 调查范围：渠道实体、配置文件、CLI、TUI、Web、桌面端的渠道生命周期操作、凭据、模型目录、协议适配、请求路由和连接测试；未调查通用聊天上下文与会话导入导出
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 的“渠道”主要是启动时放入 `ProviderRegistry` 的 `IProvider` 实例。内置 Gemini、OpenAI 和 Anthropic 是代码固定的 Provider；Proxy、Ollama 和用户配置的 OpenAI-compatible endpoint 也是启动时构造的 Provider 实例。`ProviderConfig` 只保存 endpoint URL 和启用标志，没有独立的渠道名称、模型映射、Header 集合或多凭据结构（`Manifold.Core/SettingsManager.h:10-13`）。

因此，项目当前具备“查看已注册 Provider、选择模型、保存 API Key、按 endpoint 拉取模型、校验 Key”的运行链路，但没有完整的渠道管理 CRUD。桌面设置页可以编辑 Ollama endpoint 和各已注册 Provider 的 Key；新增或删除一个 OpenAI-compatible 渠道需要直接修改 `%LOCALAPPDATA%\\Manifold\\settings.json`，并通过重启让注册表重新构建。复制、渠道级导入导出、运行时启停和独立连接测试入口在本次源码中未找到。

## 总体调用链

1. `SettingsManager::Load()` 读取 `%LOCALAPPDATA%\\Manifold\\settings.json`，文件不存在时写入默认设置和设备 ID（`Manifold.Core/SettingsManager.cpp:106-133`）。
2. `MainWindow` 构造函数先注册三个内置 Provider，再根据 `proxyUrl`、`providerConfigs` 和 `ollamaEndpoint` 构造 Proxy、OpenAI-compatible 和 Ollama 实例（`MainWindow.xaml.cpp:126-155`）。
3. WebView2 加载前端后，宿主通过 `HOST_READY` 发送设置和 Provider Key 是否存在的布尔值；前端也可以发送 `LIST_PROVIDERS` 获取 Provider 与内置模型信息（`MainWindow.xaml.cpp:300-315, 852-874`）。
4. 聊天输入栏按 Provider 列表填充选择器，切换 Provider 时发送 `LIST_MODELS`；发送聊天时把 Provider ID 和模型 ID 交给 `CHAT_SEND`，C++ 端从 Credential Manager 取 Key，按 Provider 实例调用 `StreamChat()`（`frontend/components/input-bar.js:52-57, 159-167`；`MainWindow.xaml.cpp:757-840`）。
5. OpenAI、Anthropic、Gemini 和 OpenAI-compatible Provider 各自组装协议请求。模型目录请求则由对应实例的 `ListModels()` 执行，结果回传 WebView2；连接校验通过 `VALIDATE_KEY` 调用 Provider 的 `ValidateKey()`（`MainWindow.xaml.cpp:885-914`）。

## 1. Provider、渠道与 Endpoint 数据模型

### 渠道实体

源码没有单独名为 Channel、Profile 或 Endpoint 配置实体的抽象。实际粒度如下：

| 来源 | 注册 ID | Endpoint 及配置方式 | 是否能创建多个实例 |
| --- | --- | --- | --- |
| 内置 Gemini、OpenAI、Anthropic | 固定代码 ID | 各 Provider 类内固定上游 URL | 源码未提供用户实例化入口 |
| Proxy | `proxy` | `proxyUrl` 非空时启动注册；设备 ID作为额外 Header | 一个固定实例 |
| Ollama | `ollama` | `ollamaEndpoint` 非空时启动注册 | 一个固定实例 |
| OpenAI-compatible | 配置 map 的 key | `providerConfigs[id].endpointUrl` | 配置文件中可放多个 map 项，启动时各构造一个实例 |

`ProviderRegistry` 只提供 `AddProvider`、按 ID 查找、列出和列出模型，没有删除、替换、启用/禁用或持久化方法（`Manifold.Core/Providers/ProviderRegistry.h:10-18`）。同一 ID 再加入时会覆盖注册表中的指针，但本项目的前端没有触发动态添加流程。

### 默认配置与用户配置

`AppSettings` 的默认值包括 `activeProviderId = "gemini"`、默认 Gemini 模型、默认 Proxy URL 和 `http://localhost:11434` 的 Ollama endpoint。`providerConfigs` 默认为空 map；每一项包含 `endpointUrl` 和 `enabled`，序列化键为同名字段（`Manifold.Core/SettingsManager.cpp:11-16, 34-72`）。

启动时，内置 Provider 总是注册；Proxy 只要 `proxyUrl` 非空就注册；兼容 Provider 只有在 `enabled` 为真且 endpoint 非空时注册；Ollama 只要 endpoint 非空就注册。当前默认 Proxy URL 是示例域名，因此按默认设置会尝试注册 Proxy（`SettingsManager.h:45-50`；`MainWindow.xaml.cpp:133-155`）。

## 2. 配置生命周期、管理入口与持久化

### 操作覆盖矩阵

下表按本次检查到的实际入口记录。静态代码能确认入口和事件绑定，但不能确认真实保存成功、重启后的网络可用性。

| 操作 | 配置文件 | CLI | TUI/集成终端 | Web / `server/` | Windows 桌面端 |
| --- | --- | --- | --- | --- | --- |
| 查看已有渠道 | 可直接查看 `settings.json`；内置渠道不在配置文件中 | 未找到渠道管理命令 | 集成终端只是运行 Shell，未找到渠道管理界面 | `GET /v1/models` 是 Proxy 模型接口，不是渠道列表；未找到管理 API | Providers 设置页展示已注册 Provider，聊天输入栏展示选择器 |
| 新增渠道 | 可手工新增 `providerConfigs` map 项 | 未找到 | 未找到 | 未找到渠道注册接口 | 未找到新增 Provider/endpoint 表单 |
| 编辑渠道 | 可手工修改 endpoint 和 `enabled` | 未找到 | 未找到 | 未找到 | 可编辑 Ollama endpoint；不能编辑已有兼容 Provider 的 endpoint 或名称 |
| 复制渠道 | 未找到约定或命令 | 未找到 | 未找到 | 未找到 | 未找到 |
| 启停渠道 | 可修改 `providerConfigs[id].enabled`，作用于下次启动注册 | 未找到 | 未找到 | `server` 有限流和配额，但不是渠道启停 | 未找到渠道 toggle；插件 toggle 不属于 Provider |
| 删除渠道 | 删除 `providerConfigs` map 项后重启即可不再注册；没有专用迁移/删除流程 | 未找到 | 未找到 | 未找到 | 未找到 |
| 导入渠道 | 未找到渠道配置导入格式或入口 | 未找到 | 未找到 | 未找到 | 未找到；现有导入消息是会话导入 |
| 导出渠道 | `SettingsManager::ToJson()` 能序列化完整设置，但未发现渠道专用导出文件操作 | 未找到 | 未找到 | 未找到 | 未找到；现有导出消息是会话或 Markdown 导出 |
| 连接测试 | 无独立配置文件操作 | 未找到 | 未找到 | `/health` 只检查 Proxy 进程；不是上游渠道测试 | 有 `VALIDATE_KEY` 后端消息，但 Providers 设置页没有调用它的按钮 |

### 配置文件管理

`SettingsManager::Save()` 以缩进 JSON 覆盖写入 `%LOCALAPPDATA%\\Manifold\\settings.json`。桌面设置页的一般设置和 Ollama endpoint 通过 `SAVE_SETTINGS` 发送当前设置对象；C++ 端反序列化后做温度、字体大小和 system prompt 长度限制，再保存（`frontend/services/settings-store.js:31-35`；`MainWindow.xaml.cpp:480-494`）。

这不是渠道专用保存流程。前端状态会从 `HOST_READY` 合并宿主发送的完整 settings，但 UI 没有 `providerConfigs` 的编辑表单，也没有 `proxyUrl` 输入；直接保存其他设置时，是否保留手工配置取决于前端当前状态中是否仍含有这些字段，源码未提供单独的配置合并层。配置损坏时 `Load()` 捕获解析异常并使用默认设置；本次未找到备份、迁移版本号或冲突处理逻辑（`SettingsManager.cpp:117-131`）。

### 已有渠道与新建渠道的差异

- 内置渠道有固定显示名、协议实现、模型目录和能力标志，不能由用户在桌面设置页创建第二个同类实例。
- Ollama 是唯一有明确 endpoint 输入框的本地渠道；保存后写入设置，但 Provider 注册只发生在启动构造阶段，因此源码未确认修改是否会在当前进程立即生效。
- OpenAI-compatible 渠道理论上可以通过 `providerConfigs` 创建多个实例，每个 map key 成为 Provider ID；它们只能使用继承的 OpenAI-compatible 协议，名称直接使用 ID，源码未提供自定义显示名字段。
- 已注册的任何 Provider 都能在桌面端保存或清空一个按 Provider ID 隔离的 API Key；这项凭据操作不等于新增渠道。
- `enabled` 只参与启动时的注册筛选。注册后没有运行时启停接口，且内置 Provider、Proxy 和 Ollama 没有对应的通用 enabled 字段。

### CLI、TUI 和 Web 边界

本仓库没有独立 CLI 入口、参数解析依赖或 TUI 框架。C++ 的 ConPTY 终端可以启动 `cmd.exe` 或 PowerShell，并把用户输入转发给 Shell；搜索到的“CLI”注释属于终端进程管理，不是渠道管理。

`frontend/` 是嵌入 Windows 桌面程序的 WebView2 页面，不是独立 Web 管理站点。独立 `server/` 是 Express Proxy 样例，提供 `/health`、`/v1/models`、`/v1/chat` 和配额相关路由；没有 Provider CRUD、渠道开关、配置导入导出或管理认证。服务器中的 `/v1/models` 返回 Gemini 模型列表，不能查看桌面客户端的 `providerConfigs`（`server/src/index.js:19-26`；`server/src/routes/models.js:6-12`）。

## 3. 凭据、Header 与代理边界

API Key 不写入 `settings.json`。`CredentialManager` 使用 Windows Credential Manager 的 generic credential，目标名为 `Manifold_` 加 Provider ID；桌面端前端只收到 Key 是否存在的布尔值，保存时把明文从输入框通过 WebView2 消息传到 C++，请求前再由 C++ 取出并放入 `ChatRequest::apiKey`（`CredentialManager.cpp:47-87`；`MainWindow.xaml.cpp:300-315, 496-505, 770-777`）。仓库 README 和代码都表明使用 Windows 凭据存储；本次未运行验证 Windows Credential Manager 的实际系统保护行为。

设置页的密码输入框保存后会清空，并将 placeholder 改为 `Key saved`；没有显示、编辑或单独删除按钮。向 `SET_API_KEY` 发送空字符串会调用 `DeleteApiKey`，因此“清空 Key”是已确认的删除凭据入口（`frontend/components/settings-panel.js:243-255`；`MainWindow.xaml.cpp:496-505`）。源码未找到请求日志、导出流程或错误消息中对 Key 的显式脱敏处理；正常 Provider 列表和 `HOST_READY` 不返回 Key 正文。

OpenAI 使用 `Authorization: Bearer`，Anthropic 使用 `x-api-key` 和 `anthropic-version`，Gemini 把 Key 放在 URL 查询参数；OpenAI-compatible 继承 OpenAI 的请求组装。Proxy 通过 `X-Manifold-Device-ID` 添加设备 ID，但继承 OpenAI-compatible 的路径和 SSE 解析（`OpenAIProvider.cpp:16-18, 121-142`；`AnthropicProvider.cpp:15-19, 103-108`；`GeminiProvider.cpp:125-146`；`ProxyProvider.cpp:7-10, 40-42`）。

## 4. 模型目录与能力元数据

Gemini、OpenAI 和 Anthropic 的模型目录是 Provider 类中的静态列表，包含 ID、显示名、是否免费、免费 RPM 和简短备注；`ModelInfo` 没有上下文长度、输入输出价格、模态能力或别名字段（`ProviderTypes.h:98-106`）。

OpenAI-compatible 的 `ListModels()` 请求 `<endpoint>/v1/models`，成功时读取返回 JSON 的 `data[].id`；请求失败或结果为空时返回一个占位模型。当前实现没有把 API Key 传给该模型目录请求，因此需要认证的 endpoint 静态上可能无法列出真实模型（`OpenAICompatProvider.cpp:13-38`）。

Ollama 复用 OpenAI-compatible Provider，但注册时把 endpoint 先拼成 `<ollamaEndpoint>/v1`，继承的方法又追加 `/v1/models` 和 `/v1/chat/completions`；按静态路径组合可得到重复的 `/v1/v1/...`。这是源码确认的路径关系，未用真实 Ollama 服务验证。

Proxy 优先请求其 `/v1/models` 并把结果标为免费；请求失败时退回三个硬编码 Gemini 模型。独立 `server` 的模型路由则直接返回自己的三个 Gemini 模型，和桌面 Provider 的 Proxy fallback 列表并不完全相同（`ProxyProvider.cpp:13-37`；`server/src/providers/gemini.js:32-37`）。

## 5. Adapter、协议与请求组装

`IProvider` 统一暴露模型目录、是否需要 Key、流式能力、工具能力、同步发送、流式发送和 Key 校验；具体协议仍由各 Provider 类实现（`Manifold.Core/Providers/IProvider.h:9-23`）。

| Provider | 请求协议与地址 | Key 校验 | 模型目录 |
| --- | --- | --- | --- |
| Gemini | Google `generateContent` / `streamGenerateContent`，Key 在 URL | `GET /v1beta/models?key=...` | 静态 4 项 |
| OpenAI | `/v1/chat/completions`，Bearer Header，SSE | `GET /v1/models` | 静态 4 项 |
| Anthropic | `/v1/messages`，`x-api-key`，Anthropic SSE | 发起 1 token 的最小消息请求 | 静态 3 项 |
| OpenAI-compatible | 继承 OpenAI 的 `/v1/chat/completions`、Bearer 和 SSE | 继承 OpenAI 的 `/v1/models` 校验 | 远端 `/v1/models`，失败占位项 |
| Proxy | 继承 OpenAI-compatible 的聊天路径和解析器，模型列表加设备 Header | `RequiresApiKey()` 为假，继承校验逻辑但桌面端未见专用使用路径 | 远端列表，失败 3 项 fallback |

聊天请求的通用消息、system prompt、temperature 和 MCP 工具由 C++ 组装成 `ChatRequest`，之后交给具体 Adapter。当前桌面聊天入口无论设置中的 `streamResponses` 值如何，都调用 `StreamChat()`；该设置没有在 `HandleChatSend` 中参与分支（`MainWindow.xaml.cpp:757-800`）。

## 6. 运行时选择、绑定与路由

聊天消息携带 Provider ID 和模型 ID。C++ 端按 Provider ID 从启动时的 `ProviderRegistry` 查找实例；未找到时向前端发送 `CHAT_ERROR`。API Key 也按相同 Provider ID 查询，因此配置 map 的 key 同时承担渠道实例 ID 和凭据命名空间的作用（`MainWindow.xaml.cpp:759-777`）。

前端输入栏切换 Provider 后才请求该 Provider 的模型列表；当前 `populateProviders()` 和 `populateProviderOptions()` 默认请求列表第一项的模型，随后用全局 `settings.model` 尝试选中模型。`activeProviderId` 会被写入设置 schema，但本次查看到的输入栏发送逻辑直接使用选择器值，未找到依据 `activeProviderId` 自动恢复选择器的代码（`frontend/components/input-bar.js:193-235`）。

未找到 Provider 别名、按模型语义路由、负载均衡、同一渠道多 Key 轮询或跨 Provider 自动故障转移。Compare 功能是前端固定 Gemini 和 OpenAI 两个槽位的并行请求，不是通用渠道路由或 failover（`frontend/app.js:161-173`；`MainWindow.xaml.cpp` 中的 compare 处理入口）。

## 7. 多 Key、限流、重试与故障转移

- 每个 Provider ID 只有一个 Credential Manager Key；未找到多 Key 列表、轮询、冷却或 Key 健康状态。
- 桌面端 `HttpClient` 调用链中未找到重试、退避、模型 fallback 或跨 Provider failover；聊天线程可取消，但取消不是失败恢复机制。
- Proxy 独立服务器有按设备 ID 的内存 RPM 和日配额限制；这是 Proxy 服务的访问控制，不是桌面 Provider 的健康状态或渠道切换（`server/src/middleware/rate-limiter.js`、`server/src/store/quota-store.js`）。
- Provider 的 `enabled` 只决定启动时是否加入注册表，未持久化运行时健康状态，也没有自动恢复流程。

## 8. 连接检测、日志与可观测性

后端提供 `VALIDATE_KEY`，具体 Provider 会使用一个实际 API 请求判断 HTTP 状态是否为 200；Gemini 和 OpenAI-compatible 使用模型列表请求，Anthropic 使用最小消息请求。该消息通过 `provider-api.js` 暴露给前端，但当前设置页没有调用 `validateKey()` 或渲染校验结果的控件（`frontend/services/provider-api.js:33-36`；`frontend/components/settings-panel.js:200-259`）。因此“有连接测试后端能力”与“用户可从当前桌面设置页执行连接测试”需要区分。

Provider 列表会暴露 `requiresApiKey`、流式和工具支持标志，以及模型目录；Key 只暴露存在性。聊天完成消息包含 prompt/completion token 和 finish reason，前端 `pricing.js` 另以静态价格表和 localStorage 做估算；本次未找到渠道级请求日志、HTTP 延迟、状态历史或统一错误分类。

独立 Proxy 的 `/health` 只返回 Express 进程的 `status: ok`，不检查 Gemini Key、上游网络或模型请求。服务器代码把 Gemini SSE 原样转发到 `/v1/chat`，而桌面 Proxy Provider 继承的是 OpenAI-compatible 的 `/v1/chat/completions` 路径；两者路由和响应协议的差异按源码确认，未做网络运行验证（`server/src/index.js:19-26`；`server/src/routes/chat.js:8-47`；`ProxyProvider.cpp:7-10`）。

## 9. 设计取舍与已确认边界

- Provider 采用代码接口加启动注册，协议适配集中在 C++ Provider 类中，桌面端无需为每个协议维护独立前端请求实现。
- 用户自定义 endpoint 通过 `providerConfigs` 扩展 OpenAI-compatible 协议，配置粒度低而直接：只有 map key、URL 和启用标志，不能声明自定义 Header、协议类型、显示名或模型元数据。
- 凭据与普通设置分离，Key 由 Windows Credential Manager 持有；但 endpoint、Proxy URL、设备 ID 和启用状态仍是明文 JSON 配置。
- WebView2 前端承担展示、选择和消息转发，Windows C++ 主进程承担 Provider 注册、文件读写、凭据访问和真实 HTTP 请求；独立 `server/` 是可选 Proxy 样例，不是桌面端的统一渠道管理后端。
- 会话的 JSON/Markdown 导入导出存在，但与渠道配置无关；本次未找到可复用为渠道导入导出的接口。

## 10. 未验证事项

- 未使用真实 API Key、Ollama、Proxy 或 OpenAI-compatible 服务发起网络请求，未测量超时、阻塞、SSE 兼容性和修改配置后的生效时机。
- 未运行 Windows 桌面程序，因此 Providers 设置页的实际交互、Provider 列表刷新、Key 保存结果和连接校验按钮缺失的用户表现按静态源码记录。
- 未找到独立 CLI、TUI 或 Web 管理端；这一结论基于本仓库文件结构、依赖和关键词搜索，不能外推到仓库外的发布工具或未纳入快照的脚本。
- 未验证 Windows Credential Manager 的系统级加密、跨用户可见性、备份行为和卸载清理行为。
- 未找到 Provider 配置迁移、备份恢复和并发写入处理，是否由运行环境或发布包另行提供未确认。

## 11. 关键源码索引

| 职责 | 文件与入口 |
| --- | --- |
| 配置结构与 JSON 持久化 | `Manifold.Core/SettingsManager.h:10-50`；`Manifold.Core/SettingsManager.cpp:11-16, 34-72, 106-144` |
| Provider 启动注册 | `MainWindow.xaml.cpp:126-155` |
| Provider 注册表 | `Manifold.Core/Providers/ProviderRegistry.h:10-18`；`ProviderRegistry.cpp:6-31` |
| WebView2 初始化与 HOST_READY | `MainWindow.xaml.cpp:283-322` |
| Web 消息分发与设置保存 | `MainWindow.xaml.cpp:404-506` |
| Provider 列表、模型列表、Key 校验 | `MainWindow.xaml.cpp:852-914` |
| 聊天路由与 Credential Manager 取 Key | `MainWindow.xaml.cpp:757-840` |
| 桌面 Provider 设置页 | `frontend/components/settings-panel.js:200-259` |
| Provider/模型/Key 的前端桥接 | `frontend/services/provider-api.js:19-36`；`frontend/components/input-bar.js:48-64, 193-235` |
| 凭据存储 | `Manifold.Core/CredentialManager.h:14-21`；`CredentialManager.cpp:47-87` |
| 协议适配 | `GeminiProvider.cpp`；`OpenAIProvider.cpp`；`AnthropicProvider.cpp`；`OpenAICompatProvider.cpp`；`ProxyProvider.cpp` |
| 独立 Proxy 服务边界 | `server/src/index.js`；`server/src/routes/models.js`；`server/src/routes/chat.js` |
