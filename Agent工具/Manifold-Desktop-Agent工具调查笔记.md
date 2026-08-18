# Manifold Desktop Agent 工具调查笔记

> 调查对象：`https://github.com/gregorik/Manifold-Desktop`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读核对 MCP、Provider、插件和发送链路；未修改目标仓库
>
> 调查范围：模型可见工具的发现、注入、调用与结果回传
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论

Manifold Desktop 没有内置网页搜索、文件操作或代码执行工具。模型可见的工具来自 MCP；插件接口也声明了工具注册能力，但运行链路没有接通。

当前 MCP 实现只能完成“发现工具、把 schema 发给模型、在界面展示 tool call”，不能执行工具并继续生成：

```text
MCP tools/list
  -> MCPClient::GetAllTools()
  -> ChatRequest.tools
  -> Provider 协议适配
  -> 模型返回 tool call
  -> CHAT_CHUNK
  -> renderToolCall()
  -> 结束
```

`MCPClient::CallTool()` 已实现，但全仓库没有运行时调用点；`ToolResult`、`maxToolCallRounds` 也只有类型或字段定义。

`docs/architecture.md` 描述的“调用工具、追加结果、重新请求模型”与当前代码不一致（`MCPClient.cpp:131-155`、`MainWindow.xaml.cpp:757-841`）。

## MCP 发现与注入

- `MCPClient::ConnectServer()`（`MCPClient.cpp:12-80`）根据配置创建 stdio 或 SSE transport；连接后先发送 `initialize` 握手，再请求 `tools/list` 与 `resources/list`。
- 代码构造了 `notifications/initialized` JSON，但没有把 `notifLine` 交给 transport，因此该通知实际未发送（`MCPClient.cpp:40-49`）。

发现的工具被扁平转换为 `ToolDefinition`：名称、描述和一层 `properties/required` 会进入 Provider 请求（`MCPClient.cpp:104-128`）。同名工具以后连接的服务器覆盖路由表中的先前条目（`MCPClient.cpp:63`）。

常规聊天无条件注入全部已连接工具（`MainWindow.xaml.cpp:785-789`）；Compare 路径没有设置 `req.tools`（`MainWindow.xaml.cpp:1078-1090`）。

Gemini、OpenAI 和 Anthropic 均实现了各自的工具 schema 与 tool call 解析，OpenAICompat 继承 OpenAI 格式。

## 传输与运行边界

- stdio transport 通过 `CreateProcessW` 启动用户配置的命令；参数使用空格直接拼接，没有独立转义（`StdioTransport.cpp:32-36`）。
- stdio 和 SSE 请求均同步等待，单次超时 30 秒。应用启动和设置页添加服务器时都在当前线程调用 `ConnectServer`，服务器不可达可能阻塞界面（`MainWindow.xaml.cpp:163-174, 1019-1035`；未运行验证）。
- SSE transport 固定使用 `{url}/sse` 和 `{url}/message`，`Connect()` 启动线程后等待 500ms，但不确认连接是否建立（`SSETransport.cpp:8-29`）。
- MCP stdio 进程以宿主用户权限启动，没有沙箱或工具审批。当前没有执行回环，因此模型产生的 tool call 不会触发 `CallTool()`。

## 插件工具

- 接口声明：`PluginContext` 提供 `RegisterProvider`、`RegisterTool`、`RegisterTabType` 等注册接口，但仓库没有实现该接口的类。
- 加载链路未接通：`PluginManager::LoadEnabled()` 会加载 DLL、调用 `CreatePlugin` 并注册前端虚拟主机，却**没有调用 `IPlugin::Initialize(context)`**，随后直接把状态标为 `Initialized`（`PluginManager.cpp:67-129`）。
- 设置页切换：只修改状态和配置，不会即时加载或卸载 DLL（`PluginManager.cpp:151-157`、`MainWindow.xaml.cpp:1177-1187`）。

因此，插件工具目前是接口骨架，不会进入模型请求。

## 关键文件

| 职责 | 文件 |
| --- | --- |
| 工具与消息类型 | `Manifold.Core/Providers/ProviderTypes.h` |
| MCP 发现、聚合和调用 | `Manifold.Core/MCP/MCPClient.cpp` |
| MCP 传输 | `Manifold.Core/MCP/StdioTransport.cpp`、`SSETransport.cpp` |
| 工具注入与流式发送 | `MainWindow.xaml.cpp:757-841` |
| 工具块渲染 | `frontend/components/message-renderer.js:36-78` |
| 插件接口与加载 | `Manifold.Core/Plugins/PluginContext.h`、`PluginManager.cpp` |

## 验证边界

以上结论来自静态源码和全仓库调用点搜索，未实际连接 MCP server，也未加载第三方插件。阻塞时长和 UI 表现属于按同步调用路径作出的推断。
