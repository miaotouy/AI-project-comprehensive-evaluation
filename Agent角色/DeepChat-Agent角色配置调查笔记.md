# DeepChat Agent 角色配置调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/shared/types/agent-interface.d.ts`、`src/main/agent/`、`src/main/session/data/tables/newSessions.ts`）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7f3379524da3ac629918d35682e38833ad5c203e`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：Agent/角色配置结构、持久化、DeepChat/ACP 后端分派、subagent slot 与会话绑定、提示词拼装顺序、资产/变量能力核查、配置 UI 与运行时可见性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的角色是持久化 Agent descriptor 加上运行时 session policy：

1. `AgentType` 只有 `deepchat` 与 `acp` 两种取值。descriptor 通过 `kind` 选择运行后端：DeepChat 使用内置 loop/runtime，ACP 使用直接的 ACP session backend。
2. `DeepChatAgentConfig` 同时保存模型选择、系统提示词、项目路径、权限、禁用工具、技能（Skills）、MCP、subagent 槽位、自动压缩、记忆（memory）与 persona 演化等配置。
3. 内置 Agent id 固定为 `deepchat` 且 `protected`；手动创建的 DeepChat Agent id 为 `deepchat-${nanoid(8)}`。配置 JSON 存在 Agent 数据行中，写入时会规范化禁用工具列表和 subagent 不变量。
4. 会话记录 `agent_id`、项目路径、会话类型、父会话与编排策略。Subagent 能力只在普通 DeepChat 会话且策略开启、存在有效槽位时可用；子会话的工具范围由父会话的 authority 重新计算。
5. Agent 与会话更新契约还可携带 `toolModeOverride`；它决定本轮使用的工具模式，具体工具面的冻结和执行授权见 Agent 工具笔记。

## 1. 配置数据模型

`DeepChatAgentConfig`（`src/shared/types/agent-interface.d.ts:627-652`）的主要字段如下：

| 配置组 | 字段 | 运行时含义 |
|---|---|---|
| 模型 | `defaultModelPreset`、`assistantModel`、`visionModel`、`imageGenerationModel` | 默认会话、助手、视觉和图片生成模型及部分生成参数 |
| 上下文 | `defaultProjectPath`、`systemPrompt` | 默认工作目录与系统提示词 |
| 工具策略 | `permissionMode`、`disabledAgentTools`、`toolModeOverride` | 权限模式、用户可配置 Agent 工具禁用列表与本轮工具模式覆盖 |
| 扩展 | `enabledSkillNames`、`enabledMcpServerIds` | 允许进入工具目录的 Skills 与 MCP servers |
| 编排 | `subagentEnabled`、`subagents` | 是否允许 subagent 及其 slot 定义 |
| 记忆/压缩 | `autoCompaction*`、`memory*` | 自动压缩阈值、保留轮数、embedding/retrieval/extraction 与注入预算 |
| 输出限制 | `readFileAutoTruncateChars`、`toolOutputInlineChars`、`commandOutputInlineChars` | 文件读取截断与工具/命令输出内联字符上限（#2103，归一化 1,000–200,000，`src/shared/lib/agentOutputLimits.ts`，执行语义见 Agent 工具笔记 §3） |
| persona | `personaEvolutionEnabled` | 受保护的实验性 persona 演化开关 |

模型 preset 还可以覆盖温度、上下文长度、token 上限、思考预算、推理强度与 verbosity 等生成参数（`:567-580`）。`SessionAgentContextUpdate` 把生效的代理、模型、项目与权限信息写入会话运行状态（`:181-188`）。

## 2. Descriptor 与持久化生命周期

`AgentDescriptor`（`src/main/agent/shared/agentDescriptors.ts:4-48`）区分：

- `DeepChatAgentDescriptor`：`kind` 固定为 deepchat，`source` 为 builtin 或 manual，内嵌完整 `DeepChatAgentConfig`；
- ACP descriptor：可来自手动 launch 或 registry，包含安装状态和分发信息。

`DeepChatAgentRepository` 的证据链（`src/main/agent/deepchat/deepchatAgentRepository.ts:18-19`、`:153-253`）：

1. `ensureBuiltin` 创建或恢复内置 `deepchat`，并强制其启用且不可删除（`enabled`/`protected` 均为 true）。
2. `create` 使用 `nanoid(8)` 生成手动 Agent id，source 为 `manual`，配置经 `prepareConfigWrite` 后序列化为 JSON。
3. `update` 合并旧配置和更新字段，再执行 `normalizeDisabledAgentTools` 与 `assertDeepChatSubagentConfigInvariant`。
4. `delete` 仅允许非 protected、无关联 session 的 Agent，并在事务中清理 memory namespace/audit。
5. `resolveConfig` 返回默认值与已存字段合并后的有效配置；旧的继承配置可通过 `materializeLegacyInheritedConfigs` 展开为独立 JSON（`:263-297`）。

`AgentSettings` 以 repository 为数据源，提供 Agent 类型、有效配置与能力判断，并为 DeepChat 补齐默认的禁用工具列表（主入口 `src/main/agent/settings.ts:458-489`，默认列表 `:125-140`）。

## 3. Agent 到 backend 的分派

`AgentManager.resolveBackend`（`src/main/agent/manager/agentManager.ts:54-105`）先解析可执行 descriptor，再按 kind 分派到 `backends.deepchat` 或 `backends.acp`。

`resolveSessionHandle` 根据会话的 `agentId` 打开对应 handle（`:107-118`）；取消生成、清理 runtime、transfer 和 subagent facet 均复用相同分派。

因此，ACP 是独立的 Agent backend/协议路径。它可以出现在 Provider 目录中，但不能仅凭 `apiType` 把 ACP 视为普通 LLM provider；DeepChat 运行时会在工具解析时对 ACP-backed subagent 返回空工具目录。

## 4. 提示词字段与最终拼装顺序

角色配置中的 `systemPrompt` 作为 system prompt 的第一段进入最终请求。证据链：

1. `PromptAssemblyService.build`（`src/main/agent/deepchat/runtime/promptAssemblyService.ts:59-74`）把会话的 `configuredPrompt`（Agent 配置的 system prompt 或会话级覆盖值）作为 base prompt 传给 `buildSystemPromptWithSkills`。
2. `buildSystemPromptWithSkills`（`src/main/agent/deepchat/resources/systemPromptBuilder.ts:89-274`）按固定顺序拼接以下各段，段间以空行连接（`composePromptSections`，:312-317）：

| 顺序 | 内容 | 行号 |
| --- | --- | --- |
| 1 | `basePrompt`（角色 systemPrompt，位于最前） | :260 |
| 2 | 运行时能力提示 runtimePrompt | :261 |
| 3 | 环境提示 envPrompt（含 provider/model/workdir/当前时间） | :262 |
| 4 | Skills 元数据 | :263 |
| 5 | 已激活 Skill 内容 | :264 |
| 6 | 工具使用说明 toolingPrompt（来自 `ToolService.buildToolSystemPrompt`） | :265 |
| 7 | orchestration 策略 | :266 |
| 8 | 权限规则 | :267 |
| 9 | 验证策略 | :268 |
3. 对 ACP-backed subagent session，`buildSystemPromptWithSkills` 直接返回 `normalizedBase`，不做任何附加拼接（systemPromptBuilder.ts:100-102）。
4. 压缩恢复路径的 checkpoint/memory/directives 在 `PromptAssemblyService.createPostCompactionPromptAssembler`（promptAssemblyService.ts:89-106）中以独立贡献注入，不进入 system prompt 文本，与请求消息一起装配——该主题的完整上下文构建顺序见《Chat 调查笔记》§8（`contextBuilder.ts`、`promptAssemblyService.ts:59-73`），此处不再重复。

`DeepChatAgentConfig` 没有独立的"人格/用户档案"提示词字段；唯一接近的概念是 `personaEvolutionEnabled`（`agent-interface.d.ts:651`），它只控制 memory 层面的 persona 草稿产出与注入（`MemoryConfigInlinePanel.vue:283-285` 为 UI 开关），不属于 system prompt 的静态角色文本。

## 5. 资产、变量、开场白与用户档案

按《Agent 角色配置调查指南》的"资产与变量"主题核查后，DeepChat Agent 角色**本次未找到**以下能力，检索范围与依据如下：

- 开场白/欢迎语/快捷回复：`DeepChatAgentConfig` 全字段（`agent-interface.d.ts:627-652`）无此类字段；在 `src/shared` 与 `src/main` 中 grep `greeting|openingStarter|starterMessage|welcomeMessage` 无命中。
- 欢迎页（`src/renderer/src/pages/AgentWelcomePage.vue`）是静态引导页，不是角色配置资产。
- 用户档案/Persona 模板：配置层无 user profile 字段；`src/main/agent/shared/process/shellEnvHelper.ts` 中命中的 `userProfile` 是 shell 环境变量（Windows 用户目录），与角色人格无关。
- 角色头像/图标：descriptor 层有 `avatar`/`icon` 展示字段（`src/renderer/src/stores/ui/agent.ts:50-54` 的 `UIAgent` 映射），但属于 UI 展示资产，不进入提示词或请求。
- 环境变量/占位符：Agent 配置没有自己的变量插值机制；运行环境信息（provider/model/工作目录/时间）由 `systemPromptBuilder.ts` 的 `buildSystemEnvPrompt`（:234-244）在运行时动态生成，不属于用户可编辑的角色字段。

结论：DeepChat 的角色配置模型是"模型选择 + system prompt + 工具/权限/记忆策略"，不含开场白、快捷回复、用户档案或自定义变量等资产类字段；相关能力在项目级也未发现（检索范围覆盖 `src/shared` 与 `src/main` 的类型与实现文件）。

## 6. 配置 UI 与运行时可见性

- **配置入口**：`src/renderer/settings/` 是独立的 renderer 设置入口（`App.vue`）。
  - `DeepChatAgentsSettings.vue` 编辑 DeepChat Agent 的下列配置字段（表单字段清单 :421-446、:800-837）：
    - `systemPrompt`、`permissionMode`、`disabledAgentTools`
    - `subagentEnabled`/`subagents`
    - `memoryEnabled`、`defaultModelPreset`
  - 输出限制三个字段在 `outputLimits` 折叠面板（`:566-683`，与 `agentOutputLimits.ts` 默认值联动）。
  - Memory 相关（含 `personaEvolutionEnabled`）在 `MemoryConfigInlinePanel.vue:283-285`；ACP Agent 的 profile 管理在 `AcpSettings.vue`/`AcpProfileManagerDialog.vue`。
- **运行时可见性**：侧栏与聊天状态栏都让用户可确认当前角色与实际模型。
  - 侧栏 `WindowSideBar.vue` 列出 `agentStore.enabledAgents` 并支持切换（:34、:1679 的 `setSelectedAgent`；侧栏随工作区管理重构整体移位）。
  - 聊天状态栏 `ChatStatusBar.vue` 读取 `agentStore` 显示当前 agent/模型（:1241-1356），并在会话配置变更时读取 `agentConfig.systemPrompt` 用于展示（:2120）。
- 配置写入走 main process 的 agent routes（`src/main/agent/routes.ts:33` 起），经 `DeepChatAgentRepository` 持久化（见 §2）；会话运行时的 `SessionAgentContextUpdate`（`agent-interface.d.ts:181-188`）把有效 agent/model/project/permission 写入运行状态，用户无需重开会话即可在状态栏看到生效值。

## 7. Session 绑定与角色生效

`new_sessions` 表（`src/main/session/data/tables/newSessions.ts:13-30`、`:51-94`）保存：

```text
agent_id + project_dir
active_skills + disabled_agent_tools
session_kind (regular | subagent)
parent_session_id + subagent_meta_json
orchestration_policy (explicit | proactive)
```

创建会话时这些字段与 Agent 选择一并写入（`:137-196`）。角色配置通过会话保存的 agent id、项目路径和会话级覆盖共同生效；工具解析器（`DeepChatToolResolver`）会再次读取会话行，按当前父子关系计算工具策略。

### 7.1 创建时快照与工具/记忆实时重读的混合模型

会话创建时保存哪些角色配置、发送时还重读哪些，精确边界如下：

| 机制点 | 行为 | 源码定位 |
| --- | --- | --- |
| 创建时快照 | `SessionAssignmentPolicy.resolveCreateAssignment` 合并 `mergeDefaultGenerationSettings`（:240-248）后，把生成参数（systemPrompt、temperature、topP、contextLength、maxTokens、timeout、thinkingBudget、reasoningEffort 等）连同 provider/model/permissionMode/disabledAgentTools 写入 `deepchat_sessions` 与 `new_sessions` 两个表 | `src/main/session/assignmentPolicy.ts:47-90`、`:240-248`；`deepchatSessions.ts:329-388`；`newSessions.ts:137-196` |
| 运行期读取 | `SessionSettingsCoordinator.getEffectiveGenerationSettings` 优先 instance 缓存、其次会话持久行；`configuredPrompt` 全部来自 `generationSettings.systemPrompt` | `sessionSettingsCoordinator.ts:368-428`；`turnCoordinator.ts:255/820/1380`、`deepChatLoopRunner.ts:464`、`compactionRuntimeCoordinator.ts:215` |
| 发送时不重读 | 修改 Agent 配置不影响既有会话，除非显式 `setAgentContext`（即会话换 Agent）或 `updateGenerationSettings` | `sessionSettingsCoordinator.ts:202-269` |
| 工具与记忆实时重读 | `DeepChatToolResolver.resolveAgentToolPolicy` 每次经 `resolveDeepChatAgentConfig(agentId)` 取 `enabledMcpServerIds` 与 subagent slots（`disabledAgentTools` 来自会话行）；记忆开关（`MemoryRuntimeContext.isEnabled`/`isPersonaEvolutionEnabled`）每请求经 `policy.resolveAgentConfig(agentId)` 判断 | `src/main/agent/deepchat/runtime/toolResolver.ts:213-313`、`:237-238`；`src/main/memory/context.ts:179-186` |
| 会话级覆盖 | `SessionGenerationSettingsPatch` 覆盖 systemPrompt 与全部生成参数，另加 permissionMode、activeSkills、disabledAgentTools | `src/shared/contracts/common.ts:153-169`；路由 `sessions.routes.ts:103` |
| descriptor 无版本 | `DeepChatAgentDescriptor` 无 version/revision；`revision` 只在会话行自增，不冻结 descriptor 配置 | `src/main/agent/shared/agentDescriptors.ts:15-19`；`newSessions.ts:363` |

因此 DeepChat 属于"创建时快照 + 工具实时"的混合继承模型：提示词与采样参数随会话创建冻结，能力策略跟随 Agent 当前配置，与 AIO Hub 的全量实时引用、Jan/NextChat 的完整副本都不同。

### 7.2 消息执行元数据与重新生成语义

- 每条消息保存执行元数据：`MessageMetadata`（`agent-interface.d.ts:375-404`）含 model/provider/token 统计/runId 等，但不包含温度等完整请求参数快照。
- 持久化链路：
  - `process.ts:787-788`：运行时写 `state.metadata.provider/model`
  - `transcript.updateAssistantMetadata`（`session/data/transcript.ts:276-278`）：写入 `deepchat_messages.metadata`（`deepchatMessages.ts:42-53`）
  - usage 统计从该字段回读：`transcript.ts:1121-1135`
- 重新生成是**破坏性替换**，不是分支：`SessionTranscriptMutations.prepareRetryMessage/commitRetryMessage`（`src/main/session/transcriptMutations.ts:39-64`）在 retry 时删除源用户消息起的全部消息再重发（路由 `sessionsRetryMessageRoute`，客户端 `renderer/api/SessionClient.ts:214-219`）。
- 活动运行时消息表 `deepchat_messages` 无 parent_id/is_variant；`is_variant` 仅存在于旧 `messages.ts:26`，用于 legacy 导入。

## 8. Subagent slot 与 authority

`deepchatSubagents.ts`（:10-31、:47-66、:78-149）定义最多 5 个槽位、任务标题长度与编排提示，默认槽位为 Explorer、Implementer、Reviewer；规范化过程会去重并截断到槽位上限，且支持 `targetType: self|agent`。

`resolveDeepChatSubagentCapability`（`:165-183`）只有同时满足以下条件才返回 available：

1. Agent type 为 `deepchat`；
2. session kind 为 `regular`；
3. Agent policy 没有关闭 subagent；
4. 至少有一个有效 slot。

否则返回 `unsupported_session`、`policy_disabled` 或 `no_valid_slots` 之一。

子会话的 `session_kind`、`parent_session_id` 和 slot meta 由 `new_sessions` 持久化；工具解析器对子会话读取父配置，经 `composeSubagentAuthority` 生成禁用工具、MCP 与能力范围（`src/main/agent/deepchat/runtime/toolResolver.ts:213-311`）。

## 9. 边界与未验证事项

- 配置 JSON 的字段规范化在 repository/settings 层完成；本次未通过 UI 或迁移脚本验证旧版本配置的全部兼容分支。
- `enabledSkillNames`、`enabledMcpServerIds` 是允许列表语义，但实际工具定义仍受全局 Skill/MCP 服务状态、session project 和 provider capability 影响。
- subagent slot 是有界的，但本次未运行多级 delegation、live delegation consent 或 ACP child session。
- Agent descriptor 的 `protected` 防止删除内置 DeepChat；普通手动 Agent 的删除还要求没有关联 session，源码未测试并发删除与 session 创建竞争。
- system prompt 的最终顺序（§4）来自静态读码；未运行真实请求核对各 Provider 收到的完整 prompt 文本，也未验证 `buildSystemEnvPrompt` 的环境变量展开结果。
- 未运行项目测试或构建；记录来自静态源码。

## 10. 关键源码索引

- Agent/角色类型与配置：`src/shared/types/agent-interface.d.ts:549-683`
- descriptor kind/source：`src/main/agent/shared/agentDescriptors.ts:4-48`
- DeepChat Agent CRUD、规范化和内置保护：`src/main/agent/deepchat/deepchatAgentRepository.ts:18-19`、`:153-297`
- Agent 设置默认值与配置解析：`src/main/agent/settings.ts:125-140`、`:458-489`
- 提示词拼装顺序：`src/main/agent/deepchat/runtime/promptAssemblyService.ts:59-106`、`src/main/agent/deepchat/resources/systemPromptBuilder.ts:89-274`
- Agent 配置 UI：`src/renderer/settings/components/DeepChatAgentsSettings.vue`、`MemoryConfigInlinePanel.vue`
- 运行时 agent/模型可见性：`src/renderer/src/components/chat/ChatStatusBar.vue:1241-1356`、`src/renderer/src/components/WindowSideBar.vue:34`、`:1679`
- DeepChat/ACP backend 分派：`src/main/agent/manager/agentManager.ts:54-118`
- subagent slot 和 capability：`src/shared/lib/deepchatSubagents.ts:10-31`、`:47-203`
- session agent/project/subagent 字段：`src/main/session/data/tables/newSessions.ts:13-30`、`:51-196`
- child tool policy：`src/main/agent/deepchat/runtime/toolResolver.ts:213-311`

