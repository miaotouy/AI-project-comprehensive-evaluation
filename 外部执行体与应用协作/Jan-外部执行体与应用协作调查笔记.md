# Jan 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`95e96d02c58ca361a3e54cb36360ed16bc534c8a`（分支：`main`）
>
> 调查方式：静态复核 `/v1/orchestrations`、Jan CLI 与 Claude Code/OpenClaw 预接源码；复用独特功能和运行时笔记；未启动本地服务或外部 Agent
>
> 调查范围：Jan 作为本地 Agent 服务，以及 Jan 为外部 Agent CLI 配置本地模型连接的双向关系；排除普通 OpenAI/Anthropic 兼容推理端点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 有两条方向相反但均已接通的主链，达到 `主链确认`（静态证据）：`POST /v1/orchestrations` 让外部 HTTP 客户端调用 Jan 的 MCP 工具循环；`jan launch claude|openclaw` 则配置并启动外部 Agent，使其使用 Jan 的本地模型服务。

## 接入角色与系统边界

- **Jan 作为执行服务**：外部客户端提交 orchestration 请求，Jan server 持有模型调用和 MCP 工具循环。
- **外部 Agent 作为调用者/执行体**：Claude Code/OpenClaw 持有自己的 Agent 工具循环，Jan 提供本地模型 endpoint、凭据/Provider 配置和启动桥。
- **CLI 控制表面**：`jan serve/models/threads/launch` 与桌面共享数据目录和本地服务。

## 完整主链

```text
POST /v1/orchestrations
  -> 按 assistant_id 加载持久化 assistant 系统提示
  -> 调用模型生成 tool_calls
  -> Jan 进程执行 MCP 工具并回注结果
  -> 循环至完成
  -> 返回聚合响应

jan launch <任意 CLI>
  -> 确保本地 router/service 可用
  -> 通用注入 OPENAI/ANTHROPIC base url、key 与默认模型环境变量
  -> claude 特判按 --fit 配置；openclaw 特判合并 ~/.openclaw/openclaw.json 并设默认模型
  -> 启动外部 Agent

协议转换
  -> converters.rs 在 OpenAI / Anthropic / Gemini / OpenAI-responses wire 协议间双向转换
  -> Claude Code 走 Anthropic 协议、OpenClaw 走 OpenAI 协议打到同一本地服务
```

## 身份、协议与状态映射

orchestration 当前更接近请求级任务：本次在 `proxy.rs` orchestration 路由与 assistant 加载路径中未找到独立持久 orchestration 实体，但请求可携带 `assistant_id` 映射到本地持久化的 assistant 配置。外部客户端身份主要由本地 API 边界承担（`proxy_api_key` 校验与公网绑定告警）。CLI 与桌面共享 Jan 数据目录，`jan threads` 可直接读取线程。OpenClaw provider 配置持久化在外部 Agent 的配置目录，形成跨应用状态映射。

## 执行、回流与控制语义

orchestration 结果通过 HTTP 返回，`stream=true` 当前不支持；回流载荷为聚合响应，不含工具事件、文件变化、审批或结构化提问流。外部 Agent 路径中，Claude/OpenClaw 自己执行工具和维护会话，Jan 只提供模型服务、协议转换与启动配置；因此它不同于 LobeHub 对 CLI 事件、工具和取消的统一托管。

产品表面（桌面与 `jan serve` 日志）显示本地服务地址、模型与启动的外部 Agent；本地连接状态随 CLI/服务生命周期变化，无独立"外部连接管理器"。orchestration 的外部输入按请求处理，可触发 MCP 工具执行，副作用面与 Jan server 既有执行域一致。

## 权限、凭据与治理边界

MCP 工具权限沿用 Jan server 的既有执行域，未发现按动作自动放行/逐次审批的配置面，审计落点未展开。Claude 路径通过环境变量指向本地 Anthropic 兼容服务；OpenClaw 路径会写外部配置文件。配置覆盖、已有凭据合并、端点暴露与 orchestration 鉴权的部署细节本次未展开。

## 相邻类目交接

- 本地推理器、Router 与模型服务生命周期见[独特功能笔记](../独特功能/Jan-独特功能调查笔记.md)。
- 普通模型 Provider 和兼容端点归 LLM 渠道管理；本页只记录工具编排服务与外部 Agent 预接。
- MCP 智能工具路由属于 Agent 工具，不因使用小模型选工具自动进入本类目。

## 已确认边界与未验证事项

- `/v1/orchestrations` 不支持流式，进行中取消、任务恢复和多客户端隔离未确认。
- 未真实启动 Claude Code/OpenClaw，配置兼容性和已有用户配置合并行为未运行验证。
- BrowserMCP 是伴生扩展，本仓库只有配置入口，不纳入当前主链。

## 关键源码索引

- `src-tauri/src/core/server/proxy.rs`
- `src-tauri/src/core/server/converters.rs`
- `src-tauri/src/bin/jan-cli.rs`
- `src-tauri/src/core/cli/mod.rs`
- `extensions/llamacpp-extension/src/index.ts`

