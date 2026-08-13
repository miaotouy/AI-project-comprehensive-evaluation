# Cherry Studio 外部执行体与应用协作调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：静态复核 Agent Session、Claude Agent SDK、工具注册、工作区链路与 IM 渠道层；复用 Agent 角色、Agent 工具和独特功能笔记；未运行 SDK runtime 或 IM 平台
>
> 调查范围：Claude Agent SDK 会话作为外部执行体，六平台 IM 渠道作为外部控制表面；排除普通 Assistant、普通 MCP server 和 Mini Program
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 有两条独立的完整主链，均达到 `主链确认`（静态证据）：

- **外部执行体**：`AgentSessionRuntimeService` 把 Claude Agent SDK runtime 作为独立会话执行者接入，覆盖工作区、消息持久化、流事件、工具审批和取消。这一侧窄而深，只有单一 runtime，没有多 CLI 目录。
- **外部控制表面**：IM 渠道层（`ChannelManager`，discord/feishu/qq/slack/telegram/wechat 六平台）把 Agent Session 作为可由外部线程发起、回答、接管和停止的交互对象，协议兼容 OpenClaw 家族实现。

普通聊天中的 MCP server 只属于 Agent 工具。只有 Claude Agent SDK 路径与 IM 渠道层因具有独立 runtime/生命周期而进入本类目。

## 接入角色与系统边界

- **外部执行体**：`@anthropic-ai/claude-agent-sdk` 提供的 Agent runtime。SDK 持有自身工具循环与 Bash/Read/Write/Edit 等执行；Cherry 持有 Agent Session 产品对象、workspace、消息后端、工具曝光策略、审批 UI 和事件投影。
- **外部控制表面**：六平台 IM 渠道（`src/main/ai/channels/`）。`ChannelManager` 以数据库渠道行（`AgentChannelEntity`）保存连接，适配器覆盖 discord/feishu/qq/slack/telegram/wechat；入站消息经 `ChannelMessageHandler.handleIncoming` 启动 Agent Session 运行并流式回投，`/new`、`/compact`、`/help` 命令控制会话。

Cherry 还把宿主自身作为工具面暴露给外部 runtime：`src/main/ai/mcp/servers/assistant.ts` 以 SDK MCP 形式注入会话，提供 `navigate`（路由白名单）、`product_info`、`create_agent`、`apply_setting` 等工具，外部 Agent 可操作宿主应用。

## 完整主链

```text
创建或打开 Agent Session
  -> 解析 Agent 配置与 workspace
  -> settingsBuilder 组装模型、环境变量、MCP、权限模式和 hooks
  -> AgentSessionRuntimeService / runAgentTask 调用 SDK query()
  -> SDKMessage stream 进入 ClaudeCodeStreamAdapter
  -> 转为 CherryUIMessageChunk 并写 AgentSessionMessageBackend
  -> 工具审批、文件树和工作区变化投影到 UI
  -> abort 终止当前 SDK 查询

IM 渠道
  -> 平台回调经 ChannelManager 路由到对应 adapter
  -> handleIncoming 校验并按渠道会话定位 Agent Session
  -> startAgentSessionRun 流式执行，结果回投原线程
  -> /new、/compact、/help 命令与排队/暂停控制
```

## 身份、协议与状态映射

Agent Session 使用独立于普通 Topic/Assistant 消息路径的持久化后端，workspace 是 Agent 文件操作的事实边界。SDK session 与 Cherry session 的完整 resume 标识本次未单独展开，但运行时、消息后端和工作区均有稳定产品对象，不是一次性 `query()` 按钮。

IM 渠道的身份绑定到平台账号/线程与 `AgentChannelEntity` 渠道行；协议层面走 OpenClaw 家族兼容实现：Feishu adapter 实现 `openclaw-lark` 的 `/oauth/v1/app/registration` 设备码端点，WeChat adapter 兼容 openclaw-weixin 双编码，`FlushController` 注释自述启发自 openclaw-lark。Agent Session 归属用户、Workspace 与账号体系之间的绑定关系本次未展开。

## 执行、回流与控制语义

`ClaudeCodeStreamAdapter` 解析 SDK 的 `stream_event/system/result` 与 tool use block，投影为 Cherry 消息块。SDK 原生工具在主进程外部 runtime 执行；Cherry 通过 `disallowedTools`、`canUseTool` 和 `PreToolUse` hook 控制曝光与审批，并显示文件/命令过程。

取消由 Agent Session runtime 的 AbortController 进入 SDK 查询。工具并发、子 Agent/Team 等行为主要由 SDK 决定，Cherry 没有统一重写其调度器。

IM 渠道的执行与回流与桌面 Agent Session 共用同一 runtime：外部线程消息触发与桌面会话相同的工作区与审批语义，流式结果按平台格式转换后回投。渠道层自带不可信输入防护（`ExternalContentGuard`、`WorkspaceFileGuard`、`OutputSanitizer`），外部内容可触发 SDK 工具执行与工作区写入，属于本类目必须关注的副作用面。产品表面（渠道管理页与 Agent 会话）显示已连接渠道、会话状态与命令入口，接管入口即 IM 线程内直接发言或 `/open` 类命令。

## 权限、凭据与治理边界

默认权限模式下，Bash 等原生工具逐次审批；`bypassPermissions` 会显著放宽执行。文件类工具由 workspace path hook 限制在工作区或 Agent 数据目录。MCP 工具可采用自身自动审批配置，但不能把普通 MCP 的权限模型等同于 SDK 原生工具。

SDK 持有真实执行，宿主无法完全替代 runtime 的权限边界；宿主侧工具曝光通过 `disallowedTools`/`canUseTool`/`PreToolUse` 收口，宿主内建工具集（`cherryBuiltinTools`、`cherryAutonomyTools`、`cherryKnowledgeTools`、`cherryCliTools` 等）聚合进 `cherry-tools` 注入 SDK 会话，其中 CLI 安装类工具需用户审批。模型/API 凭据管理与 SDK 会话凭据作用域本次未展开。

## 相邻类目交接

- Assistant 与 Agent Session 两套角色对象见[Agent 角色笔记](../Agent角色/Cherry-Studio-Agent角色配置调查笔记.md)。
- 工具曝光、审批和路径边界见[Agent 工具笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)。
- workspace 的文件树、编辑器和冲突检测见[生成式输出与运行时笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)。

## 已确认边界与未验证事项

- 外部执行体一侧仅确认一个主要外部 runtime，不称为统一 CLI Agent 管理平台；IM 渠道层为六平台静态主链确认，逐平台回调、签名与真实往返未运行验证。
- SDK session resume、崩溃恢复、版本兼容和真实进程取消未运行验证。
- `bypassPermissions`、实验性 Agent Teams 与工作区路径限制的组合行为未实测。
- IM 渠道的凭据刷新、渠道停用/重连与不可信输入防护的真实效果未运行验证。

## 关键源码索引

- `src/main/ai/agentSession/AgentSessionRuntimeService.ts`
- `src/main/ai/agentSession/persistence/AgentSessionMessageBackend.ts`
- `src/main/ai/runtime/claudeCode/{settingsBuilder,streamAdapter}.ts`
- `src/main/ai/tools/adapters/claudeCode/{agentTools,toolConditions}.ts`
- `src/shared/ai/claudecode/{toolRegistry,toolRules}.ts`
- `src/main/ai/channels/{ChannelManager,ChannelMessageHandler,FlushController}.ts`
- `src/main/ai/channels/adapters/{feishu/FeishuAppRegistration,wechat/WeChatProtocol}.ts`
- `src/main/ai/channels/security/{ExternalContentGuard,WorkspaceFileGuard,OutputSanitizer}.ts`
- `src/main/ai/mcp/servers/assistant.ts`

