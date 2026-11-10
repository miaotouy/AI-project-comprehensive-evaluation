# OpenCode Agent 工具调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读源码静态梳理，追踪工具注册、注入、执行与回注全链路；未运行构建与工具调用
>
> 调查范围：工具定义与来源、注册与注入过滤、参数校验、编排循环、审批授权、执行边界、结果回注与截断、MCP、Skill、子 Agent；界面执行细节进入 Chat UI 与生成式输出类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 的工具全部由 Core 的 `Tool` 服务统一管理。插件在 `tool` 域里注册工具，内建工具也按插件形式装配：`packages/core/src/tool/plugin/` 下的每个文件导出一个插件的 `name` 与 `Plugin`，插件侧的新增、更新与移除入口在 `packages/plugin/src/effect/tool.ts`。MCP 工具按命名空间并入同一份目录，Code Mode 再把工具暴露给受限解释器。

模型侧只看到当轮工具快照：Tool 服务以整工具拒绝规则筛掉目录条目，保留当次定义及执行器；真实授权由各工具的叶子策略调用权限服务，注册表自身不统一审批。结果先归一化为文本/文件，再由 Session runner 做通用截断（2000 行 / 50 KiB，超限落盘）。每个步骤进行一次模型流式调用，runner 从持久历史重建下一步，AI SDK 不持有工具循环（[快照边界](../../opencode/packages/core/src/tool.ts#L250-L320)、[步骤执行](../../opencode/packages/core/src/session/runner/step.ts#L95-L130)）。

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
       -> 工具叶子调用 Permission.assert（按各自策略授权）
       -> definition/execute/normalizeContent（core/src/tool/runtime.ts）
       -> ToolOutput.truncate（core/src/tool-output.ts）
  -> durable 事件 session.tool.called/progress/success/failed（schema/src/session-event.ts）
  -> 结果回注为 assistant 内容项，进入下一轮
```

## 1. 工具定义与来源

- **工具形状**：工具定义是一份带输入 Schema 的可执行对象，`Tool.Info` 把工具名、输入 Schema、描述与执行器合在一起交给宿主，另允许附加可选配置。输入 Schema 可用 Effect Schema、StandardSchema 或 JSON Schema 编写。执行时宿主传入 `Context`，执行器返回 `Result`，三者包含的字段如下（`packages/schema/src/tool.ts`）：

  | 结构 | 字段 |
  |---|---|
  | `Tool.Info` | `name`、`input`、`description`、`execute` |
  | `Tool.Info` 可选项 | `output`、`options` |
  | `Context` | `sessionID`、`agent`、`messageID`、`id`、`progress` |
  | `Result` | `output`、`content`、`metadata` |

- **命名空间**：工具选项里有几项与命名和可见性相关的配置：

  - `namespace` 给同一来源的工具打上命名空间；
  - `permission` 指定审批使用的权限动作名；
  - `codemode` 与 `pinned` 控制是否暴露给 Code Mode。

  模型最终看到的名称由 runtime 的规整逻辑生成，`normalizedName` 与 `effectiveName` 分别负责名称规整与生效名称（`packages/core/src/tool/runtime.ts`）。

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
- **Code Mode**：受限解释器通过宿主工具与扩展全局对象访问外界。模型 execute 入口提供 fetch；它按 webfetch 动作审批、禁止 file URL、逐跳检查重定向拒绝规则，并设 30 秒超时与 20 次重定向上限。独立的 Tool.check 路径不提供 fetch（[fetch.ts](../../opencode/packages/core/src/codemode/fetch.ts#L17-L82)、[Tool.check](../../opencode/packages/core/src/tool.ts#L44-L50)）。

## 2. 注册、注入与过滤

- **注册即插件**：内建工具插件与用户插件都注册进 Tool 服务，形成 `Map<id, Tool.Info>` 与预转换的 `ToolDefinition`。
- **注入快照**：整工具过滤只控制目录可见性；进入执行后由捕获的工具叶子策略授权。重载与释放影响后续快照，已捕获执行器仍可能引用生产方的可变状态。
- **Agent 级控制**：steps 按逻辑模型调用计数，含文本收束步骤，与工具数量无一一对应。到达上限时请求选择禁用工具，执行回调也拒绝工具调用；新用户输入投递时重置额度（[runner 计数与请求](../../opencode/packages/core/src/session/runner/llm.ts#L200-L271)、[执行兜底](../../opencode/packages/core/src/session/runner/step.ts#L95-L97)）。
- **MCP 默认 Code Mode**：`plugin/mcp-codemode-defaults.ts` 按 MCP 工具声明决定是否默认进 Code Mode 目录。

## 3. 参数校验与执行

- **校验**：工具执行前，宿主按工具声明的 Schema 解码输入；解码失败时返回带字段说明的工具错误，这段说明会回注给模型，作为下一轮的纠正提示。旧版本遗留的工具别名由输入修复插件在解码前统一改写，例如把 `bash` 映射到 `shell`（`packages/core/src/tool/plugin/tool-input-repair.ts`）。
- **执行**：runtime 层的 `execute` 承担实际调用，它运行工具实现，把返回值归一化为文本或文件内容，处理图片压缩与超限提示，并把抛出的错误包装成统一结果（`packages/core/src/tool/runtime.ts`）。
- **进度**：工具在执行过程中可通过 `Context.progress` 上报元数据，这类更新以 `session.tool.progress` 事件广播，客户端据此显示实时状态。

## 4. 编排循环与工具回合

- **循环位置**：runner 的 llm 层驱动逻辑步骤循环，每一步显式调用一次 llm.stream，流中工具以独立 fiber 执行；下一步从已持久化历史重建请求，不维护内存工具循环（[step.ts](../../opencode/packages/core/src/session/runner/step.ts#L108-L155)、[llm.ts](../../opencode/packages/core/src/session/runner/llm.ts#L212-L220)）。
- **上限**：达到 Agent `steps` 上限后注入 `runner/max-steps.ts` 的固定提示，要求只输出文本并总结进度。
- **并行**：同一响应里的多个工具调用可并行执行，事件按调用 id 分别广播。
- **中断**：中断时进行中的工具与步骤标记 aborted（`Tool execution interrupted`/`Step interrupted`）。

## 5. 审批与授权

- **规则集**：权限以 `Permission.Ruleset` 表示，每条规则记录动作、资源与处理效果三件事。动作可以写成通配符，也可以写成具体工具名；效果分三档：

  - allow：放行；
  - ask：转入审批，等待客户端答复；
  - deny：拒绝执行。

  整套规则按列表顺序求值，多层规则由 merge 合并（`packages/core/src/permission.ts`）。

- **默认规则**：`Agent.Info.default` 整体放行，只有读取 env 文件这一项例外：`*.env` 与 `*.env.*` 需要询问，`*.env.example` 直接放行（`packages/schema/src/agent.ts`）。
- **审批阻塞**：命中需要询问的规则时，服务端挂起这次调用并等待客户端回复。无人值守模式只对原本判为 ask 的调用追加规则重新求值：所有目标资源都改判为 allow 才放行，否则按拒绝处理，原本就是 deny 的调用直接拒绝（[permission.ts](../../opencode/packages/core/src/permission.ts#L184-L209)）。
- **应用范围**：一次工具调用是否放行，由会话权限列、Agent 权限规则与工具自身策略共同决定。shell 另有一层命令级扫描，解析命令方言与结构来做风险判定（`packages/core/src/shell/scan.ts`）。

## 6. 执行边界

- **进程内执行**：除 shell 外，工具都运行在服务端进程内，直接访问工作区文件与网络（受权限规则约束）。
- **shell**：由子进程执行命令，权限在调用前判定；本次未找到额外的命令沙箱层。
- **Code Mode**：受控语法限制直接文件、进程与包访问；网络由宿主 fetch 扩展提供并独立授权，工具调用仍执行各叶子的策略。未实现语法返回诊断。
- **图片**：工具输出中的图片会按尺寸限制压缩，超出范围时降级为文本提示（`core/src/tool.ts` 的 `normalizeImages`）。

## 7. 结果回注与截断

- **归一化**：结果转成 `text` 或 `file` 内容项；文本超过 2000 行或 50 KiB 时截断并写入 `tool-output` 目录，返回提示让模型改用其他工具分段读取（`core/src/tool-output.ts:13-16`）。
- **落库**：结果与工具状态通过 durable 事件投影进消息内容，客户端时间线依此渲染工具卡片。
- **清理**：`tool-output-cleanup` 节点负责清理过期输出文件。

## 8. MCP、Skill 与子 Agent

- **MCP**：MCP 支持 stdio 与 HTTP/SSE 两类传输，远端服务器上的工具以服务器名作命名空间并入工具目录，资源读取交给 `mcp-resource` 工具完成。服务器连接状态变化时，工具目录随之热重载。
- **Skill**：系统提示会列出当前可用的技能，模型通过 `skill` 工具按名称加载对应文本，`read` 工具在读取文件时也会发现技能文件；技能的内容经提示与加载进入上下文，不向工具目录新增条目（`packages/core/src/skill.ts`、`packages/core/src/skill/discovery.ts`）。
- **子 Agent**：`subagent` 工具负责派生工作，它新建子会话，或向已存在的子 Agent 追加任务。子会话拿到收窄后的权限；任务完成或失败都通过子 Agent 任务与完成回传通道送回父会话，结果为空或子会话报错时按失败结果返回（`packages/core/src/tool/plugin/subagent.ts`、`packages/core/src/session/subagent-job.ts`、`packages/core/src/session/subagent-completion.ts`）。

## 9. 设计取舍与已确认边界

- **插件化注册**让内建工具与第三方工具走同一套 `add/update` 接口，代价是工具可见性依赖插件装配顺序与激活状态（`Plugin.awaitActivation`）。
- **快照式注入**把"模型看到的工具"和"实际能执行的工具"分离，权限变化需要重新快照。
- **结果截断 + 落盘**控制上下文成本，但让模型需要二次读取；截断阈值可通过配置插件调整。
- **Code Mode** 的外部能力由宿主提供，受限语法与执行额度构成实现边界；解释器实现本身仍属于信任面，静态调查不足以给出绝对逃逸安全保证。
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
