# Cherry Studio 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`6534fc9ecefec9c8f58c133de5539ea66bc7567f`（分支：`main`）
>
> 调查方式：静态复核 Agent Session、Claude Code / Pi / DSH runtime 与驱动注册、工具注册、工作区链路与 IM 渠道层；复用 Agent 角色、Agent 工具和独特功能笔记；未运行各 runtime 或 IM 平台
>
> 调查范围：Claude Code、Pi、DSH 三种 Agent runtime 会话作为外部执行体，六平台 IM 渠道作为外部控制表面；排除普通 Assistant、普通 MCP server 和 Mini Program
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 有两条独立的完整主链，均达到 `主链确认`（静态证据）：

- **外部执行体**：`AgentSessionRuntimeService` 把 Agent runtime 作为独立会话执行者接入，覆盖工作区、消息持久化、流事件、工具审批和取消。runtime 目录并列三种驱动（Claude Code、Pi、DSH），由 Agent 行的 `type` 字段选择，不是单一 runtime。
- **外部控制表面**：IM 渠道层（`ChannelManager`，discord/feishu/qq/slack/telegram/wechat 六平台）把 Agent Session 作为可由外部线程发起、回答、接管和停止的交互对象，协议兼容 OpenClaw 家族实现。

普通聊天中的 MCP server 只属于 Agent 工具。只有 Agent runtime 路径（Claude Code / Pi / DSH）与 IM 渠道层因具有独立 runtime/生命周期而进入本类目。

## 接入角色与系统边界

- **外部执行体**：并列三种 Agent runtime——Claude Code（`@anthropic-ai/claude-agent-sdk`）、Pi、DSH，分别对应 `src/main/ai/runtime/` 下的 `claudeCode`、`pi`、`dsh` 三个目录。三者在 `registerDrivers.ts:39-43` 一次性注册进 runtime driver registry，各自声明的 runtime 类型取值为：
  - `claude-code`（`src/main/ai/runtime/claudeCode/ClaudeCodeRuntimeDriver.ts:1355`）
  - `pi`（`src/main/ai/runtime/pi/PiRuntimeDriver.ts:15`）
  - `dsh`（`src/main/ai/runtime/dsh/DshRuntimeDriver.ts:15`）

  会话由 Agent 行的 `type` 字段选择对应驱动（`AgentSessionRuntimeService.ts:617,1572-1573`）；枚举取值集合见 `AGENT_TYPES`（`src/shared/data/api/schemas/agents.ts:42-44`），Agent 实体上的字段定义见同文件 `:142-144`。runtime 持有自身工具循环与执行；Cherry 持有 Agent Session 产品对象、workspace、消息后端、工具曝光策略、审批 UI 和事件投影。
- **外部控制表面**：六平台 IM 渠道（`src/main/ai/channels/`）。`ChannelManager` 以数据库渠道行（`AgentChannelEntity`）保存连接，适配器覆盖 discord/feishu/qq/slack/telegram/wechat；入站消息经渠道消息处理器启动 Agent Session 运行并流式回投，`/new` 等斜杠命令控制会话。

Cherry 还把宿主自身作为工具面暴露给外部 runtime：`src/main/ai/mcp/servers/assistant.ts` 以 SDK MCP 形式注入会话，提供页面导航（路由白名单）、产品信息、创建 Agent、应用设置等工具，外部 Agent 可操作宿主应用。

## 完整主链

```text
创建或打开 Agent Session
  -> 解析 Agent 配置与 workspace
  -> 按 Agent 行的 type 选择 claude-code / pi / dsh 驱动
  -> Claude Code 路径：settingsBuilder 组装模型、环境变量、MCP、权限模式和 hooks
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

Agent Session 使用独立于普通 Topic/Assistant 消息路径的持久化后端，workspace 是 Agent 文件操作的事实边界。SDK session 与 Cherry session 的完整 resume 标识本次未单独展开；运行时、消息后端和工作区均有稳定产品对象。

IM 渠道的身份绑定到平台账号/线程与 `AgentChannelEntity` 渠道行；协议层面走 OpenClaw 家族兼容实现：Feishu 适配器实现 `openclaw-lark` 的设备码注册端点，WeChat 适配器兼容 openclaw-weixin 的双编码方案，`FlushController` 的注释自述启发自 openclaw-lark。Agent Session 归属用户、Workspace 与账号体系之间的绑定关系本次未展开。

## 执行、回流与控制语义

`ClaudeCodeStreamAdapter` 解析 SDK 的 `stream_event/system/result` 与 tool use block，投影为 Cherry 消息块。SDK 原生工具在主进程外部 runtime 执行；Cherry 通过禁用名单、使用权限判定与执行前钩子三类 SDK 机制（`disallowedTools`、`canUseTool`、`PreToolUse`）控制曝光与审批，并显示文件/命令过程。

取消由 Agent Session runtime 的 AbortController 进入 SDK 查询。工具并发、子 Agent/Team 等行为主要由 SDK 决定，Cherry 没有统一重写其调度器。

IM 渠道的执行与回流与桌面 Agent Session 共用同一套 runtime 驱动（按会话 Agent 的 `type` 选择 claude-code / pi / dsh）：外部线程消息触发与桌面会话相同的工作区与审批语义，流式结果按平台格式转换后回投。渠道层自带外部内容、工作区文件与输出消毒三类不可信输入防护（`ExternalContentGuard`、`WorkspaceFileGuard`、`OutputSanitizer`），外部内容可触发 SDK 工具执行与工作区写入，属于本类目必须关注的副作用面。产品表面（渠道管理页与 Agent 会话）显示已连接渠道、会话状态与命令入口，接管入口即 IM 线程内直接发言或 `/open` 类命令。

## 权限、凭据与治理边界

默认权限模式下，Bash 等原生工具逐次审批；`bypassPermissions` 会显著放宽执行。文件类工具由 workspace path hook 限制在工作区或 Agent 数据目录。MCP 工具可采用自身自动审批配置，但不能把普通 MCP 的权限模型等同于 SDK 原生工具。

SDK 持有真实执行，宿主无法完全替代 runtime 的权限边界；宿主侧工具曝光仍由前文的三类 SDK 钩子收口，宿主内建工具集（基础、自主操作、知识检索、CLI 安装等组）聚合进 `cherry-tools` 注入 SDK 会话，其中 CLI 安装类工具需用户审批。模型/API 凭据管理与 SDK 会话凭据作用域本次未展开。

## 相邻类目交接

- Assistant 与 Agent Session 两套角色对象见[Agent 角色笔记](../Agent角色/Cherry-Studio-Agent角色配置调查笔记.md)。
- 工具曝光、审批和路径边界见[Agent 工具笔记](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)。
- workspace 的文件树、编辑器和冲突检测见[生成式输出与运行时笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)。

## 当前外部执行体补充

三种 Agent runtime 中，Pi 在应用进程内通过运行时连接和 MCP adapter 接入，DSH 通过本地 bridge 与子进程交互；两者都与 Claude Code 并列注册，使用统一审批和模型注入边界，但协议事件、工具投影及子 Agent 调用各自适配。DSH 的桥还会把委派子 Agent 的工具调用路由回根会话，避免独立子会话脱离当前控制面。

运行时连接现在把本次 reasoning effort 纳入连接签名或 reconcile 条件，并为 OpenCode 保留会话头，使同一 Cherry Session 的上游会话身份稳定而不同 Session 相互隔离。后台或目标轮次还会以 `background-work`、`goal-round` 等 origin 写入运行状态，界面可区分用户回合与运行时主动回合。依据：`src/main/ai/runtime/{claudeCode/agentSessionWarmup,pi/modelInjection,dsh/modelInjection}.ts`、`src/main/ai/agentSession/agentSessionRuntimeState.ts:83-125`。

这确认了协作协议的本地接入与回流路径，未验证外部模型服务、CLI 子进程或远程 MCP 服务在网络故障下的运行行为。

API Gateway 还提供一个较窄的移动端配对面：桌面生成一次性短时配对码，移动设备换取只保存哈希的设备 token，随后只能经 LAN 访问 Provider 导出；生成、知识库与 MCP 路由仍被 LAN guard 拒绝。该路径满足设备身份、配对生命周期和受限双向协议，但当前只确认 Provider 配置交付，不把它写成与桌面 Agent Session 连续控制同一任务的完整主链。依据：`src/main/features/apiGateway/ApiGatewayPairing.ts:20-59`、`lanGuard.ts:5`、`routes/{pairing,providerExport}.ts`。

## 已确认边界与未验证事项

- 外部执行体一侧并列三个 runtime（Claude Code / Pi / DSH），均为静态主链确认，不称为统一 CLI Agent 管理平台；IM 渠道层为六平台静态主链确认，逐平台回调、签名与真实往返未运行验证。
- SDK session resume、崩溃恢复、版本兼容和真实进程取消未运行验证。
- `bypassPermissions`、实验性 Agent Teams 与工作区路径限制的组合行为未实测。
- IM 渠道的凭据刷新、渠道停用/重连与不可信输入防护的真实效果未运行验证。

## 关键源码索引

- `src/main/ai/agentSession/AgentSessionRuntimeService.ts`
- `src/main/ai/agentSession/persistence/AgentSessionMessageBackend.ts`
- `src/main/ai/runtime/{registerDrivers,registry}.ts`（三个 runtime 驱动注册与查找）
- `src/main/ai/runtime/claudeCode/{ClaudeCodeRuntimeDriver,settingsBuilder,streamAdapter}.ts`
- `src/main/ai/runtime/pi/{PiRuntimeDriver,PiRuntimeConnection}.ts`
- `src/main/ai/runtime/dsh/{DshRuntimeDriver,DshRuntimeConnection,DshBridgeServer}.ts`
- `src/shared/data/api/schemas/agents.ts`（`AGENT_TYPES` 与 Agent `type` 字段）
- `src/main/ai/tools/adapters/claudeCode/{agentTools,toolConditions}.ts`
- `src/shared/ai/claudecode/{toolRegistry,toolRules}.ts`
- `src/main/ai/channels/{ChannelManager,ChannelMessageHandler,FlushController}.ts`
- `src/main/ai/channels/adapters/{feishu/FeishuAppRegistration,wechat/WeChatProtocol}.ts`
- `src/main/ai/channels/security/{ExternalContentGuard,WorkspaceFileGuard,OutputSanitizer}.ts`
- `src/main/ai/mcp/servers/assistant.ts`
