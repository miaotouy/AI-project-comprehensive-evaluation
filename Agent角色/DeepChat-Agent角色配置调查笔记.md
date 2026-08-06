# DeepChat Agent 角色配置调查笔记

> 调查对象：`E:\works\git\deepchat`（重点 `src/shared/types/agent-interface.d.ts`、`src/main/agent/`、`src/main/session/data/tables/newSessions.ts`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：Agent/角色配置结构、持久化、DeepChat/ACP 后端分派、subagent slot 与会话绑定
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的角色是持久化 Agent descriptor 加上运行时 session policy：

1. `AgentType` 只有 `deepchat` 和 `acp`。descriptor 通过 `kind` 选择 backend；DeepChat 使用内置 loop/runtime，ACP 使用直接 ACP session backend。
2. `DeepChatAgentConfig` 同时保存模型选择、system prompt、项目路径、权限、禁用工具、Skills、MCP、subagent slots、自动压缩、memory 和 persona evolution 等字段。
3. 内置 Agent id 固定为 `deepchat` 且 `protected`；手动创建的 DeepChat Agent id 为 `deepchat-${nanoid(8)}`。配置 JSON 存在 Agent rows 中，写入时规范化 disabled tools 和 subagent invariant。
4. Session 记录 `agent_id`、project、session kind、parent session 和 orchestration policy。Subagent 能力只对 regular DeepChat session 且策略开启、存在有效 slot 时可用；子 session 由父会话 authority 重新计算工具范围。

## 1. 配置数据模型

`DeepChatAgentConfig`（`src/shared/types/agent-interface.d.ts:627-652`）的主要字段如下：

| 配置组 | 字段 | 运行时含义 |
|---|---|---|
| 模型 | `defaultModelPreset`、`assistantModel`、`visionModel`、`imageGenerationModel` | 默认会话、助手、视觉和图片生成模型及部分生成参数 |
| 上下文 | `defaultProjectPath`、`systemPrompt` | 默认工作目录与系统提示词 |
| 工具策略 | `permissionMode`、`disabledAgentTools` | 权限模式与用户可配置 Agent 工具禁用列表 |
| 扩展 | `enabledSkillNames`、`enabledMcpServerIds` | 允许进入工具目录的 Skills 与 MCP servers |
| 编排 | `subagentEnabled`、`subagents` | 是否允许 subagent 及其 slot 定义 |
| 记忆/压缩 | `autoCompaction*`、`memory*` | 自动压缩阈值、保留轮数、embedding/retrieval/extraction 与注入预算 |
| persona | `personaEvolutionEnabled` | 受保护的实验性 persona 演化开关 |

模型 preset 还可以覆盖 temperature、context length、max tokens、thinking budget、reasoning effort 和 verbosity（`:567-580`）。`SessionAgentContextUpdate` 将有效 agent/model/project/permission 写入会话运行状态（`:181-188`）。

## 2. Descriptor 与持久化生命周期

`AgentDescriptor`（`src/main/agent/shared/agentDescriptors.ts:4-48`）区分：

- `DeepChatAgentDescriptor`：`kind: deepchat`、`source: builtin|manual`，包含 `DeepChatAgentConfig`；
- ACP descriptor：可来自手动 launch 或 registry，包含安装状态和分发信息。

`DeepChatAgentRepository` 的证据链（`src/main/agent/deepchat/deepchatAgentRepository.ts:18-19`、`:153-253`）：

1. `ensureBuiltin` 创建或恢复 `deepchat`，强制 `enabled: true`、`protected: true`。
2. `create` 使用 `nanoid(8)` 生成手动 Agent id，source 为 `manual`，配置经 `prepareConfigWrite` 后序列化为 JSON。
3. `update` 合并旧配置和更新字段，再执行 `normalizeDisabledAgentTools` 与 `assertDeepChatSubagentConfigInvariant`。
4. `delete` 仅允许非 protected、无关联 session 的 Agent，并在事务中清理 memory namespace/audit。
5. `resolveConfig` 返回默认值与已存字段合并后的有效配置；旧的继承配置可通过 `materializeLegacyInheritedConfigs` 展开为独立 JSON（`:263-297`）。

`AgentSettings` 在 `src/main/agent/settings.ts:458-489` 以 repository 为数据源提供 Agent 类型、有效配置和能力判断，并为 DeepChat 补齐默认 disabled tool 列表（`:125-140`）。

## 3. Agent 到 backend 的分派

`AgentManager.resolveBackend`（`src/main/agent/manager/agentManager.ts:54-105`）先解析可执行 descriptor，再按 `kind` 选择 `backends.deepchat` 或 `backends.acp`。`resolveSessionHandle` 根据 session 的 `agentId` 打开对应 handle（`:107-118`）；取消 generation、清理 runtime、transfer 和 subagent facet 均复用相同分派。

因此，ACP 是独立的 Agent backend/协议路径。它可以出现在 Provider 目录中，但不能仅凭 `apiType` 把 ACP 视为普通 LLM provider；DeepChat 运行时会在工具解析时对 ACP-backed subagent 返回空工具目录。

## 4. Session 绑定与角色生效

`new_sessions` 表（`src/main/session/data/tables/newSessions.ts:13-30`、`:51-94`）保存：

```text
agent_id + project_dir
active_skills + disabled_agent_tools
session_kind (regular | subagent)
parent_session_id + subagent_meta_json
orchestration_policy (explicit | proactive)
```

创建 session 时这些字段与 Agent 选择一并写入（`:137-196`）。这表示角色配置不是每次请求临时读取的名称，而是通过 session agent id、项目路径和会话级覆盖共同生效。`DeepChatToolResolver` 会再次读取 session row，按当前 parent/child 关系计算 tool policy。

## 5. Subagent slot 与 authority

`deepchatSubagents.ts:10-31` 定义最多 5 个 slot、任务标题长度和编排提示；默认 slot 为 Explorer、Implementer、Reviewer（`:47-66`）。规范化过程去重、截断到 slot limit，并支持 `targetType: self|agent`（`:78-149`）。

`resolveDeepChatSubagentCapability`（`:165-183`）只有同时满足以下条件才返回 available：

1. Agent type 为 `deepchat`；
2. session kind 为 `regular`；
3. Agent policy 没有关闭 subagent；
4. 至少有一个有效 slot。

否则返回 `unsupported_session`、`policy_disabled` 或 `no_valid_slots`。子 session 的 `session_kind`、`parent_session_id` 和 slot meta 由 `new_sessions` 持久化；工具解析器对 child session 读取 parent config 并通过 `composeSubagentAuthority` 生成禁用工具、MCP 与能力范围（`src/main/agent/deepchat/runtime/toolResolver.ts:213-311`）。

## 6. 边界与未验证事项

- 配置 JSON 的字段规范化在 repository/settings 层完成；本次未通过 UI 或迁移脚本验证旧版本配置的全部兼容分支。
- `enabledSkillNames`、`enabledMcpServerIds` 是允许列表语义，但实际工具定义仍受全局 Skill/MCP 服务状态、session project 和 provider capability 影响。
- subagent slot 是有界的，但本次未运行多级 delegation、live delegation consent 或 ACP child session。
- Agent descriptor 的 `protected` 防止删除内置 DeepChat；普通手动 Agent 的删除还要求没有关联 session，源码未测试并发删除与 session 创建竞争。
- 未运行项目测试或构建；记录来自静态源码。

## 7. 关键源码索引

- Agent/角色类型与配置：`src/shared/types/agent-interface.d.ts:549-683`
- descriptor kind/source：`src/main/agent/shared/agentDescriptors.ts:4-48`
- DeepChat Agent CRUD、规范化和内置保护：`src/main/agent/deepchat/deepchatAgentRepository.ts:18-19`、`:153-297`
- Agent 设置默认值与配置解析：`src/main/agent/settings.ts:125-140`、`:458-489`
- DeepChat/ACP backend 分派：`src/main/agent/manager/agentManager.ts:54-118`
- subagent slot 和 capability：`src/shared/lib/deepchatSubagents.ts:10-31`、`:47-203`
- session agent/project/subagent 字段：`src/main/session/data/tables/newSessions.ts:13-30`、`:51-196`
- child tool policy：`src/main/agent/deepchat/runtime/toolResolver.ts:213-311`

