# Jan 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：静态复核本地 API 服务的编排路由、Jan Agent CLI/TUI 与 RPC/ACP 入口、ADK 与 Extension API 包；未启动本地服务、未连接外部 Agent 或编辑器
>
> 调查范围：Jan 作为执行服务、执行体与工具提供方三条对外关系，以及外部 Agent 预接与扩展运行时；排除普通兼容推理端点的转发细节与运行实测
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 在外部关系上同时扮演三个角色，而不是单一的执行体：

1. **执行服务**：桌面本地 HTTP 服务的 `POST /orchestrations` 由 Jan 进程持有模型调用与 MCP 工具循环，只在设置里开启服务端工具执行后才放行。
2. **执行体**：独立的 `jan` 二进制默认打开 Agent TUI，`jan cli` 提供非交互子命令；桌面另有一套由前端循环拥有的 Cowork 运行面。两者共用同一份 Agent 内核，但会话与工具事件的归属方不同。
3. **工具提供方**：`jan mcp serve` 把 Jan 内置工具按项目根目录约束暴露给其他 Agent；实验性的 `acp` 子命令把同一 Agent 以 Agent Client Protocol 暴露给 Zed、JetBrains 一类编辑器。

外接驱动面是**会话级 JSON-RPC 协议**：客户端经 LF 分隔的 stdio 与 `jan` 建立会话，声明自己要提供的 host tool，运行时把工具调用派回客户端执行。协议 schema 与生成的 JavaScript 客户端（ADK）一起提交在仓库里，Python ADK 作为独立实现放在 `adk/python`。桌面 Claude Code 设置页仍保留外部 Agent 配置入口。

## 接入角色与系统边界

- **Jan 作为执行服务**：外部客户端提交 orchestration 请求，Jan 侧加载 assistant 系统提示、运行工具循环并返回聚合结果；该路由要求服务端工具执行开关打开，否则直接拒绝并提示到设置页开启。
- **Jan 作为执行体**：`jan` 默认 TUI；`jan cli agent run` 非交互执行；会话与配置来自 `~/.jan/config.toml` 与项目 `.jan/agent/agent.toml`。两者都不含本地推理或 GUI 依赖，模型来自远程 Provider。
- **Jan 作为工具提供方**：`jan mcp serve` 以 stdio 或 loopback Streamable HTTP 暴露只读工具，`--allow-write`、`--allow-exec`、`--tool` 逐层收窄或放行，HTTP 传输默认生成 bearer token。
- **Jan 作为编辑器内 Agent**：`acp` 子命令以 ACP 走 stdio，属于未毕业实验特性，需环境变量或项目配置显式开启。
- **外部 Agent 预接**：桌面设置页仍提供 Claude Code 配置入口，但不再由 CLI 自动启动。

## 完整主链

```text
本地编排（外部客户端 -> Jan）
POST /orchestrations（需开启服务端工具执行）
  -> 按 assistant_id 加载系统提示
  -> 模型生成 tool_calls
  -> Jan 进程执行 MCP 工具并回注结果
  -> 循环至完成，返回聚合响应（暂不支持流式）

外接运行时（客户端启动 jan cli agent rpc -> stdio JSON-RPC）
initialize -> initialized 通知 -> session/start -> session/tools/set（声明 host tool）
  -> turn/start -> 模型调用 -> tool 调用派回客户端 -> tool/respond
  -> turn/steer 可在回合中途追加输入
  -> 记录以事件流回传，终止通知为 turn/completed

工具提供（其他 Agent -> jan）
jan mcp serve --project <root> [--allow-write] [--allow-exec]
  -> 只读工具默认可用，写与执行需显式放行
  -> stdio 或 loopback HTTP 传输
```

## 身份、协议与状态映射

orchestration 仍是请求级任务：`proxy.rs` 的 `/orchestrations` 路由与 assistant 加载路径中未找到独立持久 orchestration 实体，响应由一次请求聚合成。

外部客户端通过 `jan cli agent rpc` 启动服务，完成 `initialize` 请求与 `initialized` 通知后才可创建会话。一个进程有多条可寻址会话，但全局仅一个 active turn；运行中更换该会话的工具或模型被拒绝，回合输入则可通过 steer 追加。入口、握手与并发门控见 [main.rs:1179](../../jan/src-tauri/jan-cli/src/main.rs#L1179)、[rpc.rs:488–616](../../jan/src-tauri/src/core/cli/rpc.rs#L488-L616)、[rpc.rs:749–790](../../jan/src-tauri/src/core/cli/rpc.rs#L749-L790)。

RPC 的 `session/resume` 只查询本进程内的会话表；成功完成且非 ephemeral 才把历史写成项目线程，并没有把这个方法实现为跨进程读取旧会话。ephemeral 同时禁止项目记忆写入（[rpc.rs:459–473](../../jan/src-tauri/src/core/cli/rpc.rs#L459-L473)、[rpc.rs:569–581](../../jan/src-tauri/src/core/cli/rpc.rs#L569-L581)、[rpc.rs:704–708](../../jan/src-tauri/src/core/cli/rpc.rs#L704-L708)）。

进程断开或用户 interrupt 会释放待回答的 host tool 请求，客户端迟到的重复结果得到 not_pending 错误（[rpc.rs:673–692](../../jan/src-tauri/src/core/cli/rpc.rs#L673-L692)、[rpc.rs:793–801](../../jan/src-tauri/src/core/cli/rpc.rs#L793-L801)）。

协议 schema 与事件类型由 Agent 内核维护，JavaScript ADK 与独立 Python ADK 提供客户端。schema、生成与安装器说明协议契约和分发方式；真实客户端兼容性仍需运行验证。

CLI 的用户配置在 `~/.jan/config.toml`，项目覆盖在 `.jan/agent/agent.toml`；项目会话可由 `jan -c` / `--resume` 恢复，也可存为兼容桌面的 thread。

## 执行、回流与控制语义

orchestration 的结果经 HTTP 返回，`stream=true` 当前不支持；它更接近"一次请求换一次聚合结果"，进行中取消与多客户端隔离未确认。

RPC 面的回流是双向的：模型产生的 host tool 调用不落在 Jan 进程，而是按客户端在 `session/tools/set` 里声明的能力派回客户端，等待 `tool/respond` 后再继续；未知或未声明的工具调用由运行时拒绝。会话内还可 steer、切换模型、替换工具集，这些操作都在同一 stdio 会话里完成。

桌面 Cowork 又不同：工具事件与会话由前端循环拥有，Jan 后端只提供工具能力，不应把它与 HTTP 编排或 RPC 会话的回流路径混同。

## 权限、凭据与治理边界

HTTP 编排与本地 API 服务共用一层网络与鉴权治理：服务监听非 loopback 地址时要求 API key，Trusted Hosts 的匹配不再接受任意 Host 头。编排路由额外要求"允许服务端执行工具"，把"能聊天"与"能在我机器上跑工具"拆成两个开关。

CLI 的 `--safe` 要求写入、命令与 MCP 调用前审批，`--sandbox` 开启 Shell 的 OS 沙箱，`--no-sandbox` 显式取消持久配置里的沙箱，另有"沙箱内命令申请越出沙箱"的升级开关；审批与沙箱是两套独立机制。

`jan mcp serve` 的工具面按项目根目录约束，写与执行默认关闭；`--tool` 只能收窄，不能突破 allow 标志授予的范围。

## 相邻类目交接

- 本地推理器、路由与模型服务生命周期见[独特功能笔记](../独特功能/Jan-独特功能调查笔记.md)。
- 普通 Provider 与兼容端点归 LLM 渠道管理；本页只记录对外执行关系。
- Agent 工具清单、审批界面与工具执行位置见[Agent 工具笔记](../Agent工具/Jan-Agent工具调查笔记.md)；Cowork 产物与预览见[生成式输出与运行时笔记](../生成式输出与运行时/Jan-生成式输出与运行时调查笔记.md)。

## 已确认边界与未验证事项

- `/orchestrations` 不支持流式，进行中取消、任务恢复和多客户端隔离未确认。
- RPC 协议只在 Rust 实现与 schema 两处静态核对，未用 ADK 客户端实跑；客户端声明工具失败、超大工具结果截断、steer 与工具返回竞态未验证。
- ACP 为隐藏实验特性，未与 Zed/JetBrains 实连；编辑器侧能力协商未验证。
- 未真实启动 CLI、桌面 Cowork 或 mcp serve，跨程序配置与会话兼容性未运行验证。
- BrowserMCP 是伴生扩展，本仓库只有配置入口，不纳入当前主链。

## 关键源码索引

- `src-tauri/src/core/server/proxy.rs`：编排路由与服务端开关、网络鉴权
- `src-tauri/src/core/server/converters.rs`：wire 协议互转
- `src-tauri/src/core/cli/rpc.rs`、`rpc_schema.rs`、`acp.rs`：外接运行时与编辑器协议
- `src-tauri/src/core/agent/host_tools.rs`：host tool 声明与结果契约
- `src-tauri/src/core/agent/{loop,project,global_config}.rs`
- `src-tauri/jan-cli/src/main.rs`：命令树
- `packages/adk/`、`adk/python/`、`protocol/rpc-schema.json`：SDK 与协议 schema
- `packages/extension-api/`、`packages/extension-runtime/`、`src-tauri/plugins/`：扩展 API 与宿主能力插件
