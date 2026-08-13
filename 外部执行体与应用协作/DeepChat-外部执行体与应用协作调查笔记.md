# DeepChat 外部执行体与应用协作调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：静态复核 ACP agent 注册表与启动生命周期、`src/main/remote/` 与 `src/main/cli/` 主链；复用独特功能、Agent 工具和对话请求笔记；未运行外部平台或 CLI 二进制
>
> 调查范围：ACP 外部执行体、IM 远程控制和 CLI 本地控制平面；排除普通 MCP、DeepLink 和单向通知
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 同时覆盖外部执行体与外部控制表面，三条链均达到 `主链确认`（静态证据）：ACP agent 注册表（38 个条目）提供发现、安装、校验与启动外部 Agent runtime 的完整生命周期；五类 IM endpoint 远程驾驶桌面会话；本地 CLI 通过鉴权 RPC 发起和管理 Agent run。

## 接入角色与系统边界

- **外部执行体**：ACP agent 注册表。`resources/acp-registry/registry.json` 列有 38 个可发现 Agent（claude-acp、codex-acp、cursor、gemini、github-copilot-cli、devin、opencode、goose、grok-build、cline、deepagents 等），经下载、sha256 校验与依赖安装后启动；AgentManager 按 backend kind 分派，ACP 自己持有工具执行能力，DeepChat 内置工具目录对该 session 返回空。ACP 会话还可反向作为 DeepChat 自身 harness 的 LLM provider（`acpAsLlmProviderSessionControl/permission`）。
- **IM 控制表面**：Telegram、Feishu/Lark、QQBot、Discord、WeChat iLink endpoint 绑定一个 DeepChat session。
- **CLI 控制表面**：`deepchat` CLI 连接桌面主进程的 localhost HTTP control server。

## 完整主链

```text
IM 外部消息
  -> 渠道 adapter / poller / webhook
  -> RemoteEndpointBinding 查找本地 session
  -> commandRouter 解析 /agent、/stop、/pending、/open 等命令
  -> conversation runner 调用同一 SessionTurn/runtime
  -> delivery service 把文本、状态与交互投回原 endpoint

CLI 命令
  -> descriptor 发现 localhost server
  -> scoped token 鉴权
  -> /rpc、/stream、/upload
  -> routes/runService 调用主进程 Agent/MCP/Skill/Provider 等服务
  -> 流式事件或 detached run 终态回 CLI
```

ACP session 则从模型/Agent 选择入口进入独立 backend；其 payload 与工具事件映射到 DeepChat session/message 投影，取消由 session runtime 转交 backend。

```text
ACP agent 安装与启动
  -> AcpLaunchSpecService 按 binary/npx/uvx 选择分发
  -> 归档下载、sha256 校验、依赖安装（acpInitHelper）
  -> 启动 ACP runtime 并建立 session
  -> payload/工具事件映射到 DeepChat session/message
```

## 身份、协议与状态映射

`RemoteEndpointBinding` 把平台 endpoint 映射到本地 session，PairCode 默认 TTL 十分钟并限制失败次数。运行时 manager 在启动时重建渠道连接；断线后的重连、重放与轮询策略属于各渠道 adapter 与 poller，本次未逐通道走通。CLI 使用 control descriptor、协议版本、token scope、run id 和 approval request；detached run 有独立生命周期。

ACP session 与普通 DeepChat session 在能力边界上明确区分：manual compaction、pending queue resume 等只对 DeepChat runtime 可用，不能把宿主能力误推给 ACP backend。

## 执行、回流与控制语义

IM 端可发起 Agent 工作、停止生成、查看并回答 pending interaction、打开桌面会话，并接收 cron remote delivery。CLI 可发起前台或 detached run、管理工具和设置、等待终态及处理审批；CLI 面还能经 `CliComputeService` 驱动主进程的 LLM 调用、媒体生成、音频转写和 OCR，并暂存/取回工件（`ArtifactSpool`）。两者共享桌面应用的会话事实源与审批 broker。

产品面上，IM/CLI 入口在桌面会话中可看到绑定关系、运行状态与待审批交互，接管入口即"打开会话"命令；CLI 侧以 `--open` 类命令直达既有桌面会话。来自 IM/CLI 的文本、上传与指令进入同一主进程执行域，文件与命令副作用与桌面本地入口等价；上传、JSON 响应、流记录和审批文本按边界常量处理，但不可信输入的完整消毒策略未系统展开。

## 权限、凭据与治理边界

IM 渠道凭据保存在本地设置，endpoint 通过配对码授权；凭据刷新与失效流程未单独验证。CLI token 带 scope，变更类命令经过 `CliMutationGuard` 与 `approvalBroker`；`CliAuditLog` 把策略审计落盘，上传、JSON 响应、流记录和审批文本都有边界常量。外部 Agent 在沙箱内调用 `deepchat` CLI 时由 `AgentCliCommandAccess` 按 domain/verb scope 收口。执行仍发生在本机主进程，不因入口位于 IM 或终端改变文件与命令权限域。

## 相邻类目交接

- ACP 作为模型/Agent 的角色与工具边界见[Agent 角色笔记](../Agent角色/DeepChat-Agent角色配置调查笔记.md)和[Agent 工具笔记](../Agent工具/DeepChat-Agent工具调查笔记.md)。
- IM 与 CLI 能力卡的更多入口和源码依据见[独特功能笔记](../独特功能/DeepChat-独特功能调查笔记.md)。
- DeepLink 只负责启动/安装配置，不满足持续控制门槛。

## 已确认边界与未验证事项

- 未运行真实 IM 平台凭据、流式分段、交互回调 TTL 和断线重连。
- 未运行 CLI launcher、token/审批端到端和 detached run。
- ACP 注册表的真实下载、校验、安装与各 backend 启动未运行验证；外部 payload 兼容性和真实取消传播未展开。

## 关键源码索引

- `src/main/remote/index.ts`
- `src/main/remote/binding/store.ts`
- `src/main/remote/runtime/manager.ts`
- `src/main/remote/conversation/{commandRouter,runner,blockRenderer}.ts`
- `src/main/remote/delivery/service.ts`
- `src/main/cli/{server,routes,runService,launcherService,agentTokenAuthority,policy,computeService,artifactSpool,auditLog,agentCommandAccess}.ts`
- `src/shared/contracts/{localControl,cliCommands}.ts`
- `src/main/approval/approvalBroker.ts`
- `resources/acp-registry/registry.json`
- `src/main/agent/acp/launch/{acpLaunchSpecService,acpInitHelper}.ts`
- `src/main/app/composition.ts`（`acpAsLlmProvider*`）

