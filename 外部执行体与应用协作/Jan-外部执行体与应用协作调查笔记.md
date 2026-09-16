# Jan 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`38491c73d12398edda45ebec366f940e83509490`（分支：`main`）
>
> 调查方式：静态复核 `/v1/orchestrations`、Jan CLI 与 Claude Code/OpenClaw 预接源码；复用独特功能和运行时笔记；未启动本地服务或外部 Agent
>
> 调查范围：本地 HTTP 编排端点与独立 Jan Agent CLI/TUI 的外部执行关系；排除普通兼容推理端点与外部 CLI 的运行实测
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前代码有两条不同的执行路径：桌面本地 HTTP 服务的 `POST /v1/orchestrations` 执行 MCP 编排；独立的 Jan Agent CLI/TUI 则在用户项目中以远程 Provider 运行自己的 Agent。旧快照的 `jan serve` / `jan launch claude|openclaw` 一键预接链不在现行 CLI 命令树中，不能据此声称当前 CLI 会启动外部 Agent 或本地模型服务。CLI 入口见 `src-tauri/jan-cli/src/main.rs:1-5,24-50,149-157`。

## 接入角色与系统边界

- **Jan 作为执行服务**：外部客户端提交 orchestration 请求，Jan server 持有模型调用和 MCP 工具循环。
- **Jan Agent CLI 作为执行体**：独立 crate 的 `jan` 打开 Agent TUI；`jan cli agent run` 非交互执行，Provider 来自用户/项目配置或桌面配置，不包含本地推理或 GUI 依赖（`src-tauri/jan-cli/src/main.rs:1-5,28-50`）。
- **外部 Agent 预接**：桌面 Claude Code 设置页仍提供配置入口；旧 `jan launch` CLI 自动启动外部 Agent 的结论不适用于当前命令树。

## 完整主链

```text
POST /v1/orchestrations
  -> 按 assistant_id 加载持久化 assistant 系统提示
  -> 调用模型生成 tool_calls
  -> Jan 进程执行 MCP 工具并回注结果
  -> 循环至完成
  -> 返回聚合响应

jan / jan cli agent run
  -> 解析项目 .jan/agent/agent.toml、~/.jan/config.toml 与 Provider 配置
  -> 选择远程模型并运行 Agent 工具循环
  -> 保存可恢复的对话 thread；jan -c / --resume 恢复项目会话

协议转换
  -> converters.rs 在 OpenAI / Anthropic / Gemini / OpenAI-responses wire 协议间双向转换
  -> Claude Code 走 Anthropic 协议、OpenClaw 走 OpenAI 协议打到同一本地服务
```

## 身份、协议与状态映射

orchestration 当前更接近请求级任务：在 `proxy.rs` orchestration 路由与 assistant 加载路径中未找到独立持久 orchestration 实体。独立 CLI 的用户配置位于 `~/.jan/config.toml`，项目覆盖位于 `.jan/agent/agent.toml`；项目内的会话可由 `jan -c` 或 `--resume` 恢复，并可保存为 Desktop 兼容 thread（`src-tauri/src/core/agent/global_config.rs:1-29`、`src-tauri/src/core/agent/project.rs:1-47`、`src-tauri/src/core/cli/mod.rs:214-225`）。不应将其等同于旧 `jan threads` 直读桌面数据目录的启动链。

## 执行、回流与控制语义

orchestration 结果通过 HTTP 返回，`stream=true` 当前不支持。CLI 自己维护工具、对话与恢复状态；桌面 Cowork 又由前端运行循环拥有工具事件和会话，不应把这两者当作 HTTP 编排端点的回流事件（`web-app/src/lib/coworkRunner.ts:15-25`）。

orchestration 的外部输入按请求处理，可触发 MCP 工具执行，副作用面与 Jan server 既有执行域一致。CLI 的默认交互入口是 Agent TUI，不承担本地服务启动日志的展示。

## 权限、凭据与治理边界

HTTP 编排的 MCP 工具权限沿用 Jan server 的既有执行域，审计落点未展开。CLI 的 `--safe` 要求写入、命令和 MCP 调用前审批；Shell OS 沙箱可用 `--sandbox` 开启，默认配置为关闭，这与审批开关不同（`src-tauri/jan-cli/src/main.rs:69-98`、`src-tauri/src/core/agent/global_config.rs:25-29`）。

## 相邻类目交接

- 本地推理器、Router 与模型服务生命周期见[独特功能笔记](../独特功能/Jan-独特功能调查笔记.md)。
- 普通模型 Provider 和兼容端点归 LLM 渠道管理；本页只记录工具编排服务与外部 Agent 预接。
- MCP 智能工具路由属于 Agent 工具，不因使用小模型选工具自动进入本类目。

## 已确认边界与未验证事项

- `/v1/orchestrations` 不支持流式，进行中取消、任务恢复和多客户端隔离未确认。
- 未真实启动 CLI、Claude Code/OpenClaw，跨程序配置及会话兼容性未运行验证。
- BrowserMCP 是伴生扩展，本仓库只有配置入口，不纳入当前主链。

## 关键源码索引

- `src-tauri/src/core/server/proxy.rs`
- `src-tauri/src/core/server/converters.rs`
- `src-tauri/jan-cli/src/main.rs`
- `src-tauri/src/core/agent/project.rs`、`global_config.rs`
- `src-tauri/src/core/cli/mod.rs`
- `extensions/llamacpp-extension/src/index.ts`
