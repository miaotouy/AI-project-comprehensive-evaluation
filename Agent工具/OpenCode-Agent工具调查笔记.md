# OpenCode Agent 工具调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读源码静态梳理，追踪工具注册、注入、执行与回注全链路；未运行构建与工具调用
>
> 调查范围：工具定义与来源、注册与注入过滤、参数校验、编排循环、审批授权、执行边界、结果回注与截断、MCP、Skill、子 Agent；界面执行细节进入 Chat UI 与生成式输出类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 的工具系统由 Core 的 `Tool` 服务统一管理：工具不再集中注册在某个 registry，而是由插件在 `tool` 域里通过 `add/update/remove` 注册（`packages/plugin/src/effect/tool.ts`），内建工具本身就是一组内建插件（`packages/core/src/tool/plugin/*.ts`，每个文件导出 `name` 与 `Plugin`）；MCP 工具按命名空间并入，Code Mode 把工具暴露给受限解释器。

模型侧只看到当轮工具定义快照：Tool 服务按 Agent/会话权限规则集过滤后生成 `ToolDefinition` 列表与执行器（`core/src/tool.ts` 的 `snapshot`），执行前再做一次权限求值并可能阻塞等待人工审批。结果统一归一化为文本/文件内容并做截断（2000 行 / 50 KiB），超限落盘到 `tool-output` 目录。编排循环由执行器驱动，而非 AI SDK 自动执行工具。

## 总体调用链

```text
执行器准备步骤
  -> Tool.snapshot(permissions)（core/src/tool.ts）：列出工具、转成 ToolDefinition、附带 execute
       ├─ 内建插件注册（core/src/plugin/internal.ts 汇总 tool/plugin/*）
       ├─ 外部插件通过 ToolEditor.add 注册
       └─ MCP 工具并入（core/src/tool/mcp.ts，命名空间 = server 名）
  -> 请求发往 AI 层（session/model-request.ts）
  -> 模型返回工具调用
  -> SessionStep 调 Tool 服务执行（runner/step.ts）
       -> Permission.evaluate/ask（core/src/permission.ts）
       -> definition/execute/normalizeContent（core/src/tool/runtime.ts）
       -> ToolOutput.truncate（core/src/tool-output.ts）
  -> durable 事件 session.tool.called/progress/success/failed（schema/src/session-event.ts）
  -> 结果回注为 assistant 内容项，进入下一轮
```

## 1. 工具定义与来源

- **工具形状**（`packages/schema/src/tool.ts`）：`Tool.Info` 含 `name`、`input`（Effect Schema / StandardSchema / JSON Schema）、`description`、`execute`、可选 `output` 与 `options`；`Context` 含 `sessionID/agent/messageID/id/progress`；返回 `Result`（`output`、`content`、`metadata`）。
- **命名空间**：`options.namespace` 让工具带上命名空间，`options.permission` 指定权限动作名，`options.codemode`/`pinned` 控制是否暴露给 Code Mode；`runtime.ts` 的 `normalizedName`/`effectiveName` 负责把名字规整为模型可见的名称。
- **内建工具**（`packages/core/src/tool/plugin/`，由 `core/src/plugin/internal.ts` 装配）：

  | 名称 | 文件 | 说明 |
  |---|---|---|
  | `read` | read.ts | 读文件/目录，附 AGENTS 指令与技能发现 |
  | `write` | write.ts | 整文件写入 |
  | `edit` | edit.ts | 文本替换编辑 |
  | `patch` | patch.ts | 补丁式修改 |
  | `glob` | glob.ts | 路径匹配 |
  | `grep` | grep.ts | 正则搜索 |
  | `shell` | shell.ts | 执行命令 |
  | `webfetch` | webfetch.ts | 抓取网页 |
  | `websearch` | websearch.ts | 网络搜索 |
  | `todowrite` | todo.ts | 更新会话 todo |
  | `question` | question.ts | 向用户提问 |
  | `skill` | skill.ts | 按名加载技能 |
  | `subagent` | subagent.ts | 派发子 Agent |
  | `experimental_image_generate` | image-generate.ts | 生成图片 |
  | `opencode`/`models` 等 | opencode.ts | 自省与模型查询 |
  | 资源工具 | mcp-resource.ts | 读取 MCP 资源 |
  | 定时任务 | schedule.ts | 创建计划任务 |
  | 产物工具 | artifact.ts | 产出与引用附件 |

- **插件工具**：外部插件通过 `ToolEditor.add` 注册，或在 `execute.before/after` 钩子里改写输入与结果（`packages/plugin/src/effect/tool.ts`）。
- **MCP 工具**：`core/src/tool/mcp.ts` 把每个 MCP 工具注册为带命名空间的工具（`name(server, tool)`），调用前以完整名称做权限判定；MCP 服务器断开/重连时工具目录随之变更。
- **Code Mode**：`packages/codemode` 是一个只支持受控语法的解释器，程序无法直接访问网络、文件系统、进程或应用 API，只能通过宿主提供的工具与扩展全局对象与外界交互，宿主可限制执行时间、调用次数、输出大小与数据；Core 的 `codemode/` 负责目录与工具暴露。

## 2. 注册、注入与过滤

- **注册即插件**：内建工具插件与用户插件都注册进 Tool 服务，形成 `Map<id, Tool.Info>` 与预转换的 `ToolDefinition`。
- **注入快照**：`Tool.snapshot(permissions)` 一次性产出当轮可见定义与执行器，权限过滤在快照与执行两处都生效，避免模型看到不可用的工具。
- **Agent 级控制**：Agent 的 `steps` 限制单轮工具回合数；Agent 的 `permissions` 规则集决定允许/询问/拒绝；`hidden`/`mode` 决定 Agent 是否出现在选择列表。
- **MCP 默认 Code Mode**：`plugin/mcp-codemode-defaults.ts` 按 MCP 工具声明决定是否默认进 Code Mode 目录。

## 3. 参数校验与执行

- **校验**：输入按工具声明的 Schema 解码，失败返回带字段说明的 `Tool.Error`，该信息会作为模型可见的纠正提示；`plugin/tool-input-repair.ts` 对历史别名（如 `bash` → `shell`）做兼容修复。
- **执行**：`runtime.ts` 的 `execute` 负责调用工具、归一化内容（文本/文件、图片压缩与超限提示）并包装错误。
- **进度**：工具可通过 `Context.progress` 上报 metadata，事件流以 `session.tool.progress` 广播，客户端据此显示实时状态。

## 4. 编排循环与工具回合

- **循环位置**：执行器在 `core/src/session/runner/step.ts` 内驱动，单步内处理模型响应、工具调用与结果回注，`Outcome` 区分 Completed/Retry/Continue/RecoverFull/Compacted/OutputLimit。
- **上限**：达到 Agent `steps` 上限后注入 `runner/max-steps.ts` 的固定提示，要求只输出文本并总结进度。
- **并行**：同一响应里的多个工具调用可并行执行，事件按调用 id 分别广播。
- **中断**：中断时进行中的工具与步骤标记 aborted（`Tool execution interrupted`/`Step interrupted`）。

## 5. 审批与授权

- **规则集**：`Permission.Ruleset` 是 `{action, resource, effect}` 列表，action 可以是通配或具体工具名，effect 为 allow/ask/deny；`evaluate` 按顺序求值，`merge` 合并多层规则（`core/src/permission.ts`）。
- **默认规则**：`Agent.Info.default` 给全允许，但对 `*.env`/`*.env.*` 的读取要求询问，`*.env.example` 允许（`packages/schema/src/agent.ts`）。
- **审批阻塞**：需要询问时服务端创建 `Deferred` 等待客户端回复，`reply` 支持接受/拒绝/纠正等结果；无人值守场景使用 `Unattended` 规则跳过等待。
- **应用范围**：会话权限列 + Agent 权限规则 + 工具自身策略共同决定；shell 命令还有命令级扫描（`core/src/shell/scan.ts` 解析命令方言与结构）用于风险判定。

## 6. 执行边界

- **进程内执行**：除 shell 外，工具都运行在服务端进程内，直接访问工作区文件与网络（受权限规则约束）。
- **shell**：由子进程执行命令，权限在调用前判定；本次未找到额外的命令沙箱层。
- **Code Mode**：与任意 JS 沙箱不同，解释器只实现受控语法，禁止网络、文件系统、进程与包引用；未实现语法返回 `UnsupportedSyntax` 诊断。
- **图片**：工具输出中的图片会按尺寸限制压缩，超出范围时降级为文本提示（`core/src/tool.ts` 的 `normalizeImages`）。

## 7. 结果回注与截断

- **归一化**：结果转成 `text` 或 `file` 内容项；文本超过 2000 行或 50 KiB 时截断并写入 `tool-output` 目录，返回提示让模型改用其他工具分段读取（`core/src/tool-output.ts:13-16`）。
- **落库**：结果与工具状态通过 durable 事件投影进消息内容，客户端时间线依此渲染工具卡片。
- **清理**：`tool-output-cleanup` 节点负责清理过期输出文件。

## 8. MCP、Skill 与子 Agent

- **MCP**：stdio 与 HTTP/SSE 两类传输；工具按 `server_命名空间` 暴露，资源读取由 `mcp-resource` 工具承担；服务器状态变化会触发热重载。
- **Skill**：不是工具注册来源；系统提示列出可用技能，`skill` 工具按名加载技能文本（`core/src/skill.ts`、`skill/discovery.ts`），`read` 工具也会发现技能文件。
- **子 Agent**：`subagent` 工具创建子会话或向已有子 Agent 追加任务（`tool/plugin/subagent.ts`），子会话继承收窄的权限，完成/失败通过 `session/subagent-job.ts`、`subagent-completion.ts` 回传父会话；结果为空或子会话报错时作为失败结果返回而不是当成功。

## 9. 设计取舍与已确认边界

- **插件化注册**让内建工具与第三方工具走同一套 `add/update` 接口，代价是工具可见性依赖插件装配顺序与激活状态（`Plugin.awaitActivation`）。
- **快照式注入**把"模型看到的工具"和"实际能执行的工具"分离，权限变化需要重新快照。
- **结果截断 + 落盘**控制上下文成本，但让模型需要二次读取；截断阈值可通过配置插件调整。
- **Code Mode** 是受限解释器而非沙箱化 JS，能力面由宿主显式提供，因此不会出现任意代码逃逸面。
- **边界**：工具审批的 UI 表现、工具卡片的渲染属于 Chat UI/消息渲染；工具能力清单的横向比较在 Agent 工具横向对比文档。

## 10. 未验证事项

1. 未运行真实工具调用：shell 命令扫描、图片压缩、Code Mode 执行的边界行为未实测。
2. MCP 服务器热重连、命名空间冲突与工具目录变更未在真实服务器上验证。
3. 审批 Deferred 在客户端断线、多窗口并发下的行为未实测。
4. 截断阈值（2000 行 / 50 KiB）与超限落盘的实际触发效果未实测。
5. 子 Agent 的权限收窄与结果回传在深嵌套场景未验证。

## 11. 关键源码索引

- `packages/schema/src/tool.ts`：Tool.Info/Context/Result/Content
- `packages/core/src/tool.ts`：Tool 服务、快照与权限过滤
- `packages/core/src/tool/runtime.ts`：定义转换、执行、内容归一
- `packages/core/src/tool/plugin/`：内建工具插件
- `packages/core/src/plugin/internal.ts`：内建插件装配
- `packages/plugin/src/effect/tool.ts`：插件侧工具编辑与钩子
- `packages/core/src/permission.ts`：规则求值与审批
- `packages/core/src/tool-output.ts`：截断与落盘
- `packages/core/src/tool/mcp.ts`、`packages/core/src/mcp/`：MCP 接入
- `packages/codemode/README.md`、`packages/core/src/codemode/`：Code Mode
- `packages/core/src/session/runner/step.ts`、`max-steps.ts`：工具回合与步数上限
