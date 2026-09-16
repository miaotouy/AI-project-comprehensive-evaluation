# VCPMobile Agent 工具调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9da3baac9fb9d610bc31be40a6dc8d6c66774890`（分支：`main`）
>
> 调查方式：只读静态源码核对，覆盖分布式节点注册、WebSocket 协议、工具注册表、开关持久化与设置界面；未连接 VCPToolBox 服务端
>
> 调查范围：VCPMobile 作为远端 VCP 分布式节点所暴露的设备工具；不将网关文本工具协议或服务端工具循环归为移动端实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 的工具能力以独立的“分布式节点”形式存在，不随本地聊天请求注入 function calling 目录。连接到主服务后，它注册用户已启用的设备能力；主服务以 WebSocket `execute_tool` 消息请求执行，移动端返回 `tool_result`。移动端不驱动“模型调用工具后再继续生成”的循环，也不解析本地 LLM 的 `tool_calls`。

注册表当前有 14 个设备工具：设备信息、通知、剪贴板和 `VCPMobileCLI` 为一次性执行工具；电池、内存、CPU、GPU、网络、存储、位置、运动、环境传感器和设备状态摘要为静态占位符/快照工具。所有新注册工具默认禁用。用户在界面逐项启用后，策略才写入应用配置目录并在已连接时重新注册。

## 总体调用链

```text
用户启用分布式节点与所需工具
  -> enabled_names 白名单持久化；仅 enabled manifest 可注册
  -> WebSocket 连接主服务，connection_ack 后 register_tools
  -> 主服务 execute_tool(requestId, toolName, toolArgs)
  -> 设备端边界检查、注册表查找和本机执行
  -> tool_result(success/error) 回传主服务
```

节点连接建立后才注册 manifest，并立刻推送一次已启用静态占位符；之后按流式调度周期推送快照。`src-tauri/src/distributed/client.rs:703-863,1119-1202`。

## 1. 工具来源、目录与协议

工具是 Rust 内置注册表，不包含 MCP、OpenAPI、外部插件安装或 Skill 发现。`build_registry` 明确注册四项 one-shot 工具和十项 streaming 工具；interactive trait 已定义但当前没有实例注册。`src-tauri/src/distributed/tools/mod.rs:29-58`，`src-tauri/src/distributed/tool_registry.rs:102-166`。

向主服务发送的 manifest 将无 placeholder 的工具标记为 `synchronous`，有 placeholder 的工具标记为 `static`，并声明移动端原生入口与十秒协议 timeout。协议本身是节点注册和执行协议，不是 OpenAI `tool_calls` 或 JSON Schema function calling。`src-tauri/src/distributed/types.rs:18-66,186-270`。

聊天请求可切换到网关 `chatvcp` 路径，但移动端请求客户端没有用该注册表构建工具目录。因此模型能否看到这些描述、何时解析调用、如何把工具结果回注模型，属于远端 VCPToolBox/VCPChat 服务端的责任边界。`src-tauri/src/vcp_modules/infra/vcp_client.rs:82-239`。

## 2. 启用策略、授权与执行边界

注册时工具全不在启用白名单内；配置文件不存在、损坏、过大或含非法项时会 fail-closed 为空白名单（等价全部禁用）。保存采用“先持久化、后更新内存”的顺序，已连接节点会重新注册已启用清单。`src-tauri/src/distributed/tool_registry.rs:261-330,592-760`，`src-tauri/src/distributed/mod.rs:71-116`。

移动端界面可查看工具元数据并逐项开关；启用定位或通知前会请求并复核 Android 权限。这个用户操作是授权前置条件，但收到 `execute_tool` 后的 Rust 执行链只检查工具已启用和名称存在，不会再次显示逐次审批。主服务对持有节点 WebSocket Key 的请求是否已做身份、会话或风险审批，本仓库不可确认。`src/features/distributed/DistributedView.vue:280-372`，`src-tauri/src/distributed/tool_registry.rs:335-500`。

工具运行在 Tauri/Rust 进程和 Android 插件桥，而非浏览器或容器；本次未逐个审查各传感器工具的字段校验、Root 降级和平台权限。节点断开时，其子任务会被取消并等待收束。`src-tauri/src/distributed/client.rs:60-116,477-522`。

## 3. 请求校验、并发、结果与恢复

接收端先限制 WebSocket 帧为 512 KiB，再限制 `requestId`、工具名和序列化参数大小，拒绝重复 ID，并以信号量把在途执行限制为 8 个。合格请求异步执行，成功或失败都包装为 `tool_result` 回传。`src-tauri/src/distributed/client.rs:29-38,118-176,864-1118,1218-1254`。

注册表没有统一参数 schema 校验；`tool_args` 原样交给工具实现。执行状态仅保留在当前 WebSocket 会话与前端连接状态中，未看到工具调用、结果或审批的 SQLite 持久化和重启恢复。节点重连采用 5 秒起步、上限 60 秒的指数退避。`src-tauri/src/distributed/client.rs:550-702`，`src-tauri/src/distributed/tool_registry.rs:335-500`。

## 4. 已确认边界与未验证事项

- 本地没有 MCP 客户端、子 Agent、代码执行沙箱，亦无本地“LLM -> 工具 -> LLM”迭代上限。
- 当前协议的工具结果只回到主服务；主服务如何再写进模型上下文不在此仓库范围。
- 未连接真实节点，未验证认证、远端调用超时、工具结果长度、Android 权限拒绝和 Root/非 Root 路径的运行行为。

## 关键源码索引

- `src-tauri/src/distributed/tools/mod.rs`：14 项内置设备工具注册。
- `src-tauri/src/distributed/tool_registry.rs`：启用白名单、manifest、分派和 fail-closed 配置恢复。
- `src-tauri/src/distributed/types.rs`：注册、执行、取消与结果消息契约。
- `src-tauri/src/distributed/client.rs`：连接、重连、入站校验、并发门控和结果回传。
