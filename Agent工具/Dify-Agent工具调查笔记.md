# Dify Agent 工具调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读工具抽象、管理器、传统 Agent、Agent v2/dify-agent runtime、控制台工具 Provider API 与 MCP/Workflow 工具服务；未调用外部工具、Plugin Daemon 或内部 API
>
> 调查范围：模型可发现和调用的内置、API、插件、MCP 与 workflow 工具；不逐项审计所有工具实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 将“工具来源/配置”和“单次调用”分开处理。`ToolManager` 是发现与装配中心，`ToolEngine` 承担传统运行时执行；每种来源再由对应 Provider controller 转成统一 Tool。传统 Agent 与 Agent v2 都在模型请求前取得工具目录，却不共享同一个循环、执行域或审批语义：前者在 API 进程串行执行并回注 observation，后者在独立 dify-agent runtime 循环，核心工具再经内部 API 回到 Dify 执行。

## 总体调用链

```text
内置定义、插件、租户 API 工具、MCP Provider 或 workflow tool
  -> ToolProviderController / ToolManager 生成可用 Tool 与 schema
  -> 传统 Agent 或 Agent v2 按应用/tenant 配置构造本轮工具目录
  -> 传统 Agent 用 ToolEngine 串行执行并回注 ToolPromptMessage，或 Agent v2 runtime 调用核心/插件工具
  -> 结果、错误或 deferred human input 进入下一轮模型/Agent run，并投影到消息或 workflow run
```

工具“存在于工作区”不等于“被本次 Agent 授权”：管理、目录构建和节点选择是三层责任。

## 1. 工具类型与发现边界

内置工具以 Provider 目录、YAML 说明和实现代码组成；`ToolManager` 保有 builtin provider lock 和 hardcoded provider 映射。租户自定义 API 工具通过 `ApiToolProviderController.get_tools(tenant_id)` 从数据库读取（`custom_tool/provider.py:27-172`）。插件工具 Controller 能返回插件声明的工具（`plugin_tool/provider.py:11-72`），MCP Controller 在远端目录基础上产生 `MCPTool`（`mcp_tool/provider.py:21-145`）。

workflow-as-tool 也有独立 `WorkflowTool` 与 Provider controller（`workflow_as_tool/tool.py:40`、`provider.py:45-212`）。因此 workflow 的复用不是把聊天 prompt 文本塞进工具结果，而是先保存为 tenant 下的 workflow tool provider，再以统一工具 schema 暴露。

## 2. 管理生命周期与 workflow-as-tool

控制台统一入口为 `/workspaces/current/tool-providers`（`controllers/console/workspace/tool_providers.py:494`）。内置 Provider 至少有列工具、查看信息、添加/更新/删除凭据和列凭据接口；自定义 API Provider 有 add、远程 schema 获取、列工具、update、delete 等接口（582-819 行）。这些是控制台后端的操作覆盖，网页控件与真实网络结果仍未运行验证。

workflow 工具创建 payload 包含 name、label、description、icon、parameters、privacy policy、labels 和 workflow app ID（181-214 行）。创建服务在 tenant 内检查 name 或 app ID 冲突，并调用 `ensure_no_human_input_nodes`（`workflow_tools_manage_service.py:32-83`），即含人工输入节点的 workflow 不可直接按普通工具发布。更新、删除、按 tool/app 查询均有对应 API（904-1000 行）。

## 3. MCP、凭据与远端执行

MCP Provider 的创建/更新/删除 payload 以 server URL、名称、身份/认证和配置为核心（`tool_providers.py:259-310`）。`MCPTool` 的远端调用入口是 `invoke_remote_mcp_tool`（`mcp_tool/tool.py:278`）；服务端管理器可加密 headers、准备 OAuth token、从远端拉取工具并处理授权动作（`mcp_tools_manage_service.py:480-536`）。这说明 MCP 的连接与凭据属于服务端 Provider 配置，公开对话者并不会直接得到这些 header。

本次未连接 MCP 服务，未验证动态注册、OAuth 回调、身份转发、超时、SSE 读取、重连及远端工具返回如何映射为模型可见内容。

## 4. 调用、结果回注与 Agent 路径

`ToolEngine` 是传统执行入口，但实际执行类型仍由 Tool 子类决定：API 工具、插件、MCP 和 workflow 工具不共享同一个底层网络/进程边界。workflow Agent 与 Agent v2 分别有 `core/workflow/nodes/agent/` 和 `agent_v2/` 运行时；后者还有 `dify_tools_builder.py`、runtime request builder 与独立 `dify-agent` 服务。因此不能把旧 Agent 的工具循环、审批或错误语义迁移到 Agent v2。

传统 function-calling Agent 的主链已经可静态走通：模型返回原生 `tool_calls` 后，每轮先写入 `MessageAgentThought`，再按返回顺序逐个调用工具；每个结果转换成带同一 `tool_call_id` 的 `ToolPromptMessage`，回注下一轮模型上下文，同时补写 thought 的 observation、元数据和文件引用。模型一次给出多个 tool call 时，Dify 自身仍使用普通循环，不能称为并行工具执行。字符串参数只在工具只有一个 LLM 参数时自动包装，否则尝试解析 JSON 对象；找不到工具、凭据、参数或执行错误会变成模型可见 observation，而不是直接终止整个回合；二进制输出另建 MessageFile（`api/core/agent/fc_agent_runner.py:147-412`、`api/core/agent/base_agent_runner.py:226-354`、`api/core/tools/tool_engine.py:49-338`）。

传统 function-calling 的循环上限默认 10、最高 99；最后一轮移除工具迫使模型收尾，仍继续请求工具时抛超限错误。传统 ReAct 文本策略也有上限但解析/回注路径不同。这样可以确认一条“模型调用 -> 持久化 thought -> 串行工具 -> observation -> 下一轮模型”的完整链，却不能把它泛化成每种 Agent 策略的相同上限或失败语义。

Agent v2 有独立主链。工具 builder 只展开启用配置，Provider 级全选会排除显式列出的工具、规范化 MCP ID，并拒绝跨来源重名；内置/API/workflow/MCP 进入 `dify.core.tools`，插件通常进入 `dify.plugin.tools`。dify-agent 用 Pydantic AI 的 `Agent.run` 驱动模型工具循环，单次 run 的 request 上限为 500、默认超时一小时。核心工具调用带内部 API key 回到 Dify 的 `/inner/api/agent/tools/invoke`，后端重验 app/tenant 后以保存的工具运行时调用 `ToolEngine.generic_invoke`，因此凭据不直接交给 Agent backend；插件工具则由 Agent backend 带已准备凭据调用 Plugin Daemon，执行边界不同（`api/core/workflow/nodes/agent_v2/dify_tools_builder.py:170-373`、`dify-agent/src/dify_agent/runtime/runner.py:348-515`、`api/services/agent_tool_inner_service.py:44-136`）。

## 5. 实际目录、协议与参数边界

工具目录的共同抽象由 ToolManager、Provider controller 和 ToolEngine 提供，但“已登记在工作区”与“已注入本次模型请求”是两层事实。应用或 Agent 节点根据其配置取得候选工具，Agent/Agent v2 runtime 再将可用目录转为模型请求所需的 schema；本轮确认传统 Agent 节点和 Agent v2 都有独立工具构建入口，未把两者的过滤、命名冲突、token 预算或 tool-call 格式当作相同实现。

API 工具、插件、MCP 与 workflow 工具最终都要经过其专属 Tool/controller，因而不能假设存在一套统一的 HTTP、进程或远端协议。MCP Tool 的远端入口是 `invoke_remote_mcp_tool`；workflow-as-tool 只接受通过兼容性检查的 workflow。参数 schema、必填字段和类型的完整校验点、额外字段策略、模型返回错误怎样回送下一回合，本次尚未逐工具类别贯通。

不过，公共执行层已有比“入口”更具体的参数和事件契约。`ToolEngine.agent_invoke` 会从 LLM 形式的参数取本次模型给出的值，通知 Agent callback 开始、结束或错误，再调用 Tool；`generic_invoke` 对 workflow 回调执行同样的开始、执行和错误交接（`core/tools/tool_engine.py:49-205`）。API Tool 在构造 HTTP 请求前检查必填参数，并将缺参、无效 schema 和请求构造失败转为 `ToolParameterValidationError`（`custom_tool/tool.py:70-252`）。这确认了参数校验和 UI/事件投影的中间层，但不能据此说所有 Provider 都使用同一验证器。

Agent v2 的工具 builder 会先展开启用的 Provider 条目：配置指向 Provider 而未指定 tool name 时，才读取该 Provider 的可用工具并跳过显式列出的工具；随后规范化 MCP Provider ID、构造运行时 Tool，并把声明不存在或凭据校验失败转为结构化配置错误。这说明“工作区里可见的全部工具”不会无条件送入 Agent v2；本轮也已确认其 Agent runtime request 上限和内部工具回调，但没有运行模型协议或 token 预算。

## 6. 编排、授权与执行状态

传统 Agent 的 thought/observation 证明工具结果不是只能停留在执行器内部；最终消息或 workflow 节点持久化仍取决于应用 mode。Agent v2 唯一已确认的可恢复人工协作是专属 deferred 工具 `ask_human`：只有配置联系人时才注入，一次 run 仅允许一个 deferred call；外层 workflow 保存 session snapshot、form ID 与 `tool_call_id`，表单提交或超时后按该 ID 回注第二次 Agent run。这不是所有工具的逐调用审批（`api/core/workflow/nodes/agent_v2/runtime_request_builder.py:833-844`、`dify-agent/src/dify_agent/layers/ask_human/layer.py:102-159`、`api/core/workflow/nodes/agent_v2/ask_human_resume.py:62-121`）。

控制台能管理 Tool Provider 与 MCP Provider，但“管理权限”不等于每次调用的审批。CLI 工具在构建时会过滤未预授权、权限拒绝或危险未确认的配置，属于发布配置门槛；本轮没有找到 Dify Tool/MCP/API 通用的“每次调用前审批、执行端再验证批准令牌”机制。MCP headers 与 OAuth token 在服务端管理器中准备，公开聊天用户不能直接读取它们；这只是凭据边界，不是对远端工具权限效果的运行验证。

## 已确认边界与未验证事项

- 已确认内置、API、插件、MCP、workflow 五类来源和统一 Provider/Tool 抽象。
- workflow-as-tool 禁止含人工输入节点的 workflow，且以 tenant 下独立 Provider 保存。
- MCP headers/OAuth 由服务端管理器处理；其真实认证、安全和远端执行仍未验证。
- 传统 function-calling 已确认逐 call 的 thought、串行执行、observation 回注、默认/最大循环上限和二进制文件落点；未运行实际模型、工具、重试或输出预算。
- Agent v2 已确认独立工具构建、Pydantic AI 循环、核心工具的内部 API tenant 校验、插件工具的 daemon 边界与 ask_human 的 deferred resume；未验证内部 API、Plugin Daemon、MCP 或工具授权配置的端到端效果。
- 未找到 Dify Tool/MCP/API 通用的逐调用审批；CLI 预授权过滤和 ask_human 不能替代该机制。

## 关键源码索引

- `api/core/tools/tool_manager.py`、`tool_engine.py`：发现与传统执行中心
- `api/core/tools/{builtin_tool,custom_tool,plugin_tool,mcp_tool,workflow_as_tool}/`：来源专属 controller 与 Tool
- `api/services/tools/workflow_tools_manage_service.py:32-407`：workflow 工具生命周期
- `api/services/tools/mcp_tools_manage_service.py:117-692`：MCP 连接、加密 headers 与 OAuth
- `api/controllers/console/workspace/tool_providers.py:494-1000`：控制台管理 API
- `api/core/agent/fc_agent_runner.py:121-412`、`api/core/agent/base_agent_runner.py:226-354`：传统 function-calling 的循环、thought、执行和 observation 回注。
- `api/core/workflow/nodes/agent_v2/`、`dify-agent/src/dify_agent/runtime/runner.py:348-515`：Agent v2 的工具目录和独立循环。
- `api/controllers/inner_api/agent/tools.py:42-70`、`api/services/agent_tool_inner_service.py:44-136`、`dify-agent/src/dify_agent/layers/`：核心工具内部回调、插件工具与 deferred human input 边界。
