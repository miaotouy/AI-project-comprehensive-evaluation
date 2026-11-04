# OpenCode Agent 角色配置调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读源码静态梳理 Agent 配置加载、内存编辑、选择与绑定、提示词拼装、模型与权限生效链路；未运行构建与交互
>
> 调查范围：Agent 数据模型与存储、配置来源与合并、选择与绑定、提示词拼装、模型与生成参数、工具/权限/Skill/子 Agent 授权、内置 Agent、界面可见性；会话数据与工具执行细节分别进入会话与消息管理、Agent 工具类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Agent 在 OpenCode 2.x 中是"由配置构建、可被插件编辑的内存对象"，没有 Agent 数据表；会话行只保存 Agent 的 id 引用。Agent 服务维护一张内存表，内建插件与配置插件通过编辑器接口写入或改写条目，读取方拿到的始终是当前快照。

配置来源分两类：配置文档里的 agents 字段，以及带 frontmatter 的 markdown 文件（`agent/`、`agents/` 与旧式 `mode/`、`modes/` 目录）。V2 原生字段（`permissions`、`request`、`system`、`disabled`）与 V1 字段共用同一加载器，V1 写法先经迁移函数转换。默认 Agent 由会话绑定、`default_agent` 配置、内建 build、可选项首个依次决定。

## 总体生效链路

```text
配置文档 + markdown 文件（core/src/config/plugin/agent.ts）
  -> Config 服务合并 -> Agent 编辑器写入（core/src/agent.ts）
  -> 内建插件改写条目（core/src/plugin/agent.ts、plan.ts 等）
  -> 选择：会话 agent -> default_agent -> build -> 首个可选（Agent.select）
  -> 执行时解析（session/runner/model.ts、runner/llm.ts）
       -> 模型绑定 + 请求参数
       -> 权限规则集 + 工具可见性
       -> 系统提示 = agent.system + context baseline
  -> durable 事件记录切换与使用
```

## 1. 数据模型与存储

- **Agent.Info**（`packages/schema/src/agent.ts:23-35`）字段：

  | 字段 | 含义 |
  |---|---|
  | `id`/`name` | 标识与展示名 |
  | `model` | 可选模型引用（provider/model/variant） |
  | `request` | provider 请求的 settings/headers/body 透传 |
  | `system` | 自定义系统提示 |
  | `description` | 展示描述 |
  | `mode` | `subagent`/`primary`/`all` |
  | `hidden` | 是否在选择器中隐藏 |
  | `color` | 界面着色 |
  | `steps` | 单轮最大工具步骤数 |
  | `permissions` | 权限规则集 |

- **默认值**：`Agent.Info.default(id)` 生成"全允许 + 读取 `.env` 需询问 + `.env.example` 允许"的基线（`agent.ts:36-55`）。
- **存储**：Agent 不落库；会话的 `agent` 列保存 id（`packages/core/src/session/sql.ts:28-84`）。进程内由 Agent 服务以 `Map<ID, Info>` 维护，变更时发 Agent 更新事件（`core/src/agent.ts`）。
- **可编辑性**：`Editor` 支持 `list/get/default/update/remove`，内建插件通过 `transform` 修改条目，第三方插件同样可以注册 Agent。

## 2. 配置来源、加载与合并

- **配置文档**：配置服务按全局、项目、环境变量指定文件、托管配置等来源合并为文档序列；`agent` 字段解码为 `Config.Agent`（`packages/schema/src/config/agent.ts`），未知字段忽略。
- **markdown 文件**：`{agent,agents}/**/*.md` 与 `{mode,modes}/*.md` 被发现并解析 frontmatter；`mode` 目录强制 primary。带 V2 原生字段的文件按 V2 形状解码，其余按 V1 形状解码后经迁移转换（`packages/core/src/config/plugin/agent.ts`、`v1/config/agent.ts`、`v1/config/migrate.ts`）。
- **目录监听**：配置代理文件变化会触发重新加载（`ConfigEntryObserver.observeSources`）。
- **默认 Agent**：配置键 `default_agent` 指定；加载器在条目合并后应用，并校验其可选性（`config/plugin/agent.ts:68`）。

## 3. 选择、绑定与切换

- **选择优先级**：`Agent.select` 先取显式 id（会话绑定或调用方传入），否则取 `default_agent`，再退到内建 build，最后取第一个可选条目（`core/src/agent.ts`）。
- **可选性**：`subagent` 与 `hidden` 的条目不会成为默认或主选择；子 Agent 只能由 `subagent` 工具引用。
- **会话绑定**：会话创建可带 agent；`session.switchAgent` 端点切换会话 Agent 并写入 `agent-switched` 消息；历史消息保留当时的 Agent id，因此时间线能显示每条助手消息由哪个角色产生。
- **模型绑定**：会话优先使用自己的 model，未设置时回退到 Agent 的 model，再回退到默认模型（`session/runner/model.ts`）；切换 Agent 不自动改写会话模型。

## 4. 提示词与上下文

- **系统提示**：最终提示由 Agent 的 `system` 与上下文基线拼装，基线包含工具指引、项目/全局指令、技能与引用引导等，由 SystemContext 组合（`core/src/session/runner/llm.ts`、`core/src/system-context/`）。
- **动态注入**：插件可通过 session 的 context 钩子在请求尾部追加提醒。Plan 插件就是这样维持"计划模式"提醒的：Agent 切换、压缩或回退都可能冲掉提醒，因此在每次请求时核对并补回（`core/src/plugin/plan.ts`）。
- **工具指引**：内建系统提示模板位于 `core/src/session/runner/prompt/system.txt`，工具自身的说明由工具定义携带。
- **变量替换**：本次未找到 Agent 提示中的 `$ARGUMENTS` 之类变量展开；该语义存在于命令模板而非 Agent。

## 5. 权限、工具与 Skill 授权

- **权限求值**：规则集是 action/resource/effect 三元组列表，按顺序求值，后写规则可覆盖前项（`core/src/permission.ts` 的 `evaluate`/`merge`）。
- **合并层级**：Agent 权限 + 会话权限 + 工具自身策略共同生效；无人值守场景以 `Unattended` 规则替代人工确认。
- **工具可见性**：Tool 服务按合并后的规则集生成当轮工具快照，被拒绝的工具不会出现在模型可调用列表里。
- **Skill**：技能是否可用同样经权限规则判定，系统提示与 `skill` 工具只暴露允许的技能。
- **子 Agent 权限**：`subagent` 工具只知道当前调用方有权发起的子 Agent；子会话按自身 Agent 的权限运行，不能借父会话权限越界（`core/src/tool/plugin/subagent.ts`）。

## 6. 模型与生成参数

- Agent 的 `request` 字段把 provider 请求的 settings、headers、body 透传给模型请求，因此温度、top_p 等生成参数写在 body 里而非独立字段。
- `model` 支持引用 `provider/model` 与变体；解析结果与请求参数合并后交给 AI 层。
- `steps` 控制单轮工具回合上限，超出后注入收束提示（`runner/max-steps.ts`）。

## 7. 内置 Agent

- **build**：默认主 Agent，基线权限来自 `Agent.Info.default`，即允许全部工具但对 `.env` 读取询问。
- **plan**：由 Plan 插件注册为只读规划角色，允许提问，拒绝编辑，仅允许写入全局计划目录；工具执行后再拦一次越权修改（`core/src/plugin/plan.ts`）。
- **general**：通用子 Agent（`core/src/plugin/agent.ts:63`）。
- **explore**：探索型子 Agent，允许搜索与读取类工具（`core/src/plugin/agent.ts:74`）。
- **compaction/title/summary**：隐藏的主 Agent，分别用于压缩、标题与摘要生成（`core/src/plugin/agent.ts:96-110`）。
- 其余内建插件（goal、identity、optimize、verbosity 等）也会按需注入条目或改写提示。

## 8. 界面可见性与导出

- **选择器**：App 的 Agent 选择器与 TUI 的 Agent 对话框都调用同一列表接口，仅展示可选条目；`@` 提及子 Agent 的入口在输入框补全中。
- **可见状态**：时间线与侧栏按消息上的 Agent id 着色或标注；切换 Agent 产生 `agent-switched` 消息。
- **调试**：CLI 保留 `debug agents` 处理器打印 Agent 列表（`packages/cli/src/commands/handlers/debug/agents.ts`）。
- **创建与导入导出**：旧版的 `agent create` 生成命令在本次快照中未找到；Agent 通过配置文件与 markdown 手工编写，导出会话不包含 Agent 定义。

## 9. 设计取舍与已确认边界

- **内存对象 + 配置事实源**：改动配置后重新加载即可生效，无需迁移数据库；代价是 Agent 没有版本历史。
- **权限是唯一授权杠杆**：工具、Skill、子 Agent 的可见性都由权限规则派生，配置层不再有 per-agent 的工具开关字段。
- **V1/V2 字段同源加载**：旧 markdown 文件无需改造即可继续使用，但 V1 `tools` 布尔表的语义要经迁移映射为权限规则。
- **提示词动态核对**：状态型提醒（如 Plan 模式）由插件在每次请求时核对，避免压缩/回退丢失。
- **边界**：本次未找到 Agent 的图形化编辑界面与 Agent 导入导出。

## 10. 未验证事项

1. 未运行真实会话：Agent 切换、模型回退与权限审批的实际表现未实测。
2. 配置合并顺序在多层来源（全局/项目/环境变量/托管）同时存在时未运行验证。
3. 子 Agent 权限在多层嵌套调用中的行为未验证。
4. markdown frontmatter 的 V1/V2 混合写法在真实文件上的兼容性未逐项实测。

## 11. 关键源码索引

- `packages/schema/src/agent.ts`：Agent.Info 与默认权限
- `packages/schema/src/config/agent.ts`：Agent 配置字段
- `packages/core/src/agent.ts`：Agent 服务与选择逻辑
- `packages/core/src/config/plugin/agent.ts`：配置与 markdown 加载
- `packages/core/src/v1/config/{agent.ts,migrate.ts}`：V1 配置兼容
- `packages/core/src/plugin/agent.ts`、`plan.ts`：内置 Agent
- `packages/core/src/permission.ts`：权限求值
- `packages/core/src/session/runner/{model.ts,llm.ts}`：模型与提示拼装
- `packages/core/src/tool/plugin/subagent.ts`：子 Agent 派发
- `packages/protocol/src/groups/session.ts`：切换 Agent 端点
