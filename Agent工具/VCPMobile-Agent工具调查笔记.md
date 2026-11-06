# VCPMobile Agent 工具调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5`（分支：`main`）
>
> 调查方式：只读静态源码核对，覆盖分布式节点注册、WebSocket 协议、工具注册表、开关持久化与设置界面；未连接 VCPToolBox 服务端
>
> 调查范围：VCPMobile 作为远端 VCP 分布式节点所暴露的设备工具；网关文本工具协议与服务端工具循环属于服务端实现，本节仅在移动端接入接口处引用
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

节点连接建立后才注册 manifest，并立刻推送一次已启用静态占位符；之后按流式调度周期推送快照。`src-tauri/src/distributed/client.rs:586-720,1298-1340`。

## 1. 工具来源、目录与协议

设备工具来自 Rust 内置注册表，当前注册四项 one-shot 工具和十项 streaming 工具；interactive trait 尚无实例注册。CLI 工具内部另有 Skill 目录、读取、物化和用户导入流程，须与设备工具发现区分。检查注册表及 CLI 适配器未发现 MCP 或 OpenAPI 目录接入。`src-tauri/src/distributed/tools/mod.rs:29-63`、`src-tauri/src/distributed/tool_registry.rs:191-260`。

向主服务发送的 manifest 将无 placeholder 的工具标记为 `synchronous`，有 placeholder 的工具标记为 `static`，并声明移动端原生入口与十秒协议 timeout。协议本身是节点注册和执行协议，不是 OpenAI `tool_calls` 或 JSON Schema function calling。`src-tauri/src/distributed/types.rs:198-260`。

`VCPMobileCLI` 将 Android 本地 shell/job 运行时投影为一个设备工具。它还提供 Skill 列举、有限读取和物化动作，导入则由应用 CLI 工作区承担。该适配器仅在 Android 且运行时准备成功时发布；普通无上下文调用会被拒绝，远端执行要求当前 ACK 的连接身份。见 [CLI 适配器](../../VCPMobile/src-tauri/src/distributed/tools/vcp_mobile_cli.rs#L56-L112)、[动作契约](../../VCPMobile/src-tauri/src/vcp_modules/cli/protocol.rs#L58-L96)。

聊天请求可切换到网关 `chatvcp` 路径，但移动端请求客户端没有用该注册表构建工具目录。因此模型能否看到这些描述、何时解析调用、如何把工具结果回注模型，属于远端 VCPToolBox/VCPChat 服务端的责任边界。`src-tauri/src/vcp_modules/infra/vcp_client.rs:1688-1720`。

## 2. 启用策略、授权与执行边界

注册时工具全不在启用白名单内；配置文件不存在、损坏、过大或含非法项时会 fail-closed 为空白名单（等价全部禁用）。保存采用“先持久化、后更新内存”的顺序，已连接节点会重新注册已启用清单。`src-tauri/src/distributed/tool_registry.rs:289-380,521-560`，`src-tauri/src/distributed/mod.rs:71-134`。

移动端界面可查看工具元数据并逐项开关；启用定位或通知前会请求并复核 Android 权限。这个用户操作是授权前置条件，但收到 `execute_tool` 后的 Rust 执行链只检查工具已启用和名称存在，不会再次显示逐次审批。主服务对持有节点 WebSocket Key 的请求是否已做身份、会话或风险审批，本仓库不可确认。`src/features/distributed/DistributedView.vue:78-147`，`src-tauri/src/distributed/tool_registry.rs:468-520`。

普通设备工具经 Tauri/Rust 与原生插件桥执行，CLI 则进一步启动 Android 本机 PRoot shell 子进程。本次未逐个审查各传感器工具的字段校验、Root 降级和平台权限。节点断开时，其子任务会被取消并等待收束。`src-tauri/src/distributed/client.rs:509-586`。

## 3. 请求校验、并发、结果与恢复

接收端先限制 WebSocket 帧为 512 KiB，再限制 `requestId`、工具名和序列化参数大小，拒绝重复 ID，并以信号量把在途执行限制为 8 个。合格请求异步执行，成功或失败都包装为 `tool_result` 回传。`src-tauri/src/distributed/client.rs:822-900,1298-1340`。

注册表没有统一参数 schema 校验，参数交给各工具实现；CLI 有独立 canonical validator，UI 与远端适配器都只向运行时提交通过校验的类型化动作。通用入站请求追踪位于当前 WebSocket 会话，但 CLI 将操作和 job 持久化到独立 JSON ledger。远端身份与请求 ID 生成稳定操作键，动作摘要一致时返回已有结果或 job，复用 ID 提交不同动作则拒绝。见 [CLI 身份映射](../../VCPMobile/src-tauri/src/distributed/tools/vcp_mobile_cli.rs#L84-L144)、[幂等执行](../../VCPMobile/src-tauri/src/vcp_modules/cli/runtime.rs#L277-L329)、[重放判定](../../VCPMobile/src-tauri/src/vcp_modules/cli/runtime.rs#L468-L498)。

CLI 的 shell 输出写为有界 stdout/stderr 文件，轮询按游标读取，单次读取上限 256 KiB、长轮询等待上限 8 秒。执行由 Android ProcessHost 启动带工作区绑定的 PRoot 环境；进程、超时、取消与作业账本各有实际实现，不能从“设备工具”概称推导为只有原生传感器调用，也不能将 PRoot 视为已验证的安全容器。见 [协议限制](../../VCPMobile/src-tauri/src/vcp_modules/cli/protocol.rs#L25-L27)、[原生进程启动](../../VCPMobile/src-tauri/plugins/vcp-mobile/android/src/main/java/com/vcp/mobile/cli/CliProcessHost.kt#L345-L390)。

CLI 重启先加载账本，原生 ProcessHost 句柄是进程内状态，持久化路径只作为证据，必须重新准备并核验运行时；账本不等价于可以无缝续跑原进程。通用节点仍采用 5 秒起步、上限 60 秒的指数退避。见 [CLI 初始化](../../VCPMobile/src-tauri/src/vcp_modules/cli/runtime.rs#L170-L190)、`src-tauri/src/distributed/client.rs:586-720`。

## 4. 已确认边界与未验证事项

- 检查设备注册表、CLI 适配器与聊天请求组装后，本次未找到 MCP 客户端或子 Agent 调度；本地工具执行包含 CLI/PRoot shell，模型到工具再回模型的循环仍由外部服务拥有。CLI 的实际隔离、资源限制与设备回收后的收口行为未运行验证。
- 当前协议的工具结果只回到主服务；主服务如何再写进模型上下文不在此仓库范围。
- 未连接真实节点，未验证认证、远端调用超时、工具结果长度、Android 权限拒绝和 Root/非 Root 路径的运行行为。

## 关键源码索引

- `src-tauri/src/distributed/tools/mod.rs`：14 项内置设备工具注册。
- `src-tauri/src/distributed/tool_registry.rs`：启用白名单、manifest、分派和 fail-closed 配置恢复。
- `src-tauri/src/distributed/types.rs`：注册、执行、取消与结果消息契约。
- `src-tauri/src/distributed/client.rs`：连接、重连、入站校验、并发门控和结果回传。
