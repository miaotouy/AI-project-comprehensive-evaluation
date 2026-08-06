# LobeHub Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-05
>
> 代码快照：`4edba1b75a97b91c28ad48cd1cc90528defa17ad`（分支：`canary`）
>
> 调查方式：只读核对 LobeAgentConfig、LobeAgentChatConfig、MetaData、AgentPlugin 类型定义及 AgentSetting store；未修改被调查仓库源码
>
> 调查范围：Agent/角色能配置什么、能力字段、运行时行为与内置预设方向
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

LobeHub 的 Agent 是七个项目里配置维度最多的。单个 Agent 对象（`LobeAgentConfig`）包含四个主要层：

1. **人格/元数据**：`systemRole`（系统提示词）、`title`、`avatar`、`backgroundColor`、`fewShots`（少样本对话）、`openingMessage`、`openingQuestions`；
2. **模型偏好**：`model`、`provider`、`params`（LLMParams：temperature、topP、maxTokens 等）；
3. **对话配置**（`chatConfig: LobeAgentChatConfig`）：超过 40 个可选字段，控制推理模式、历史压缩、工具模式、内存、搜索、Agent 模式等；
4. **外部能力**：`plugins`（市场插件）、`knowledgeBases`（知识库）、`files`（附件）、`tts`（语音合成）、`agencyConfig`（异构 Agent 绑定）。

与 Cherry Studio 类似，模型参数写在 Agent 内部，不在 Session 级；每个 Agent 还可以独立选择模型和 provider，比 Cherry Studio 更细粒度（支持 `provider` 字段单独覆盖）。

## 2. 配置入口与数据格式

### 2.1 类型包位置

`LobeAgentConfig` 定义在 monorepo 的 `packages/types/src/agent/item.ts`，通过 tsconfig 路径别名 `@/types/agent` 在应用代码中引用。`LobeAgentChatConfig` 在 `packages/types/src/agent/chatConfig.ts`。

### 2.2 Agent 存储

Agent 存在后端数据库，通过 `lambdaClient.agent` trpc 接口读写。前端 `AgentSetting` store（`src/features/AgentSetting/`）管理编辑态；`AgentStoreState` 的 `agentMap` 缓存已加载的 Agent 配置。

## 3. 人格与对话行为

### 3.1 核心身份字段

| 字段 | 类型 | 作用 |
| --- | --- | --- |
| `systemRole` | `string` | 系统提示词，必填，空字符串表示无系统提示 |
| `title` | `string?` | 显示名称 |
| `avatar` | `string?` | Emoji 或图片 URL |
| `backgroundColor` | `string?` | 头像背景色 |
| `virtual` | `boolean?` | 是否为自动生成（如从模板创建）的虚拟 Agent |

MetaData（`src/features/AgentSetting/store/initialState.ts` 中的 `meta`）包含 `avatar`、`backgroundColor`、`description`、`tags`、`title`，这些在 UI 的"元数据"标签页编辑；`loadingState` 为每个 meta 字段单独跟踪保存状态。

### 3.2 少样本与开场

| 字段 | 作用 |
| --- | --- |
| `fewShots` | 少样本示例对话（`FewShots` 类型，来自 `@/types/llm`） |
| `openingMessage` | 用户进入对话时 Agent 显示的开场白文本 |
| `openingQuestions` | 开场推荐问题列表，UI 作为快捷提问显示 |

### 3.3 输入模板

`chatConfig.inputTemplate` 字段允许设置用户输入的预处理模板，Agent 会在用户消息发送前应用此模板（例如包裹特定前后缀）。

## 4. 模型与输出偏好

### 4.1 基础模型参数

```typescript
interface LobeAgentConfig {
  model: string          // 模型 ID，默认 'gpt-4o-mini'
  provider?: string      // 覆盖全局 provider 选择
  params: LLMParams      // temperature、topP、maxTokens 等标准 LLM 参数（来自 model-bank 包）
}
```

`params` 是 `model-bank` 包定义的标准参数对象，包含常规推理参数。具体字段由 `LLMParams` 类型决定（未在本次调查中展开，以 model-bank 文档为准）。

### 4.2 LobeAgentChatConfig 关键字段

`chatConfig` 字段包含超过40个可选配置项，以下列出主要分组：

**Agent 模式**

| 字段 | 说明 |
| --- | --- |
| `enableAgentMode` | 是否开启 Agent 模式（完整工具集）；`undefined` = 默认 `true` |
| `toolMode` | `'agent'`（默认工具集+插件）/ `'chat'`（仅 runtime 管控工具）/ `'custom'`（精确声明插件集） |
| `skillActivateMode` | `'auto'`：AI 自主激活工具/技能；`'manual'`：用户手动选择 |

**推理与思考**

| 字段 | 说明 |
| --- | --- |
| `enableReasoning` / `enableReasoningEffort` | 开关推理/推理强度 |
| `reasoningEffort` | `'low'` / `'medium'` / `'high'` |
| `thinking` | `'disabled'` / `'auto'` / `'enabled'`（主要用于 Claude） |
| `thinkingBudget` | 思考 token 上限 |
| `enableAdaptiveThinking` | Claude Opus 4.6 自适应思考 |
| `effort` | `'low'` / `'medium'` / `'high'` / `'max'` |
| `preserveThinking` | 保留历史思考内容传给模型（Qwen preserve_thinking） |
| 模型专属推理字段 | `gpt5ReasoningEffort`、`grok4_3ReasoningEffort`、`deepseekV4ReasoningEffort`、`hy3ReasoningEffort`、`codexMaxReasoningEffort`、`opus47Effort`、`glm5_2ReasoningEffort` 等（各模型独立枚举值） |

**上下文与历史**

| 字段 | 说明 |
| --- | --- |
| `enableHistoryCount` / `historyCount` | 控制历史消息条数 |
| `enableMaxTokens` | 是否启用 maxTokens 限制 |
| `enableContextCompression` | 超 token 阈值后压缩旧消息为摘要 |
| `compressionModelId` | 指定用于生成压缩摘要的模型 |
| `disableContextCaching` | 关闭上下文缓存（Anthropic cache_control） |

**搜索与知识**

| 字段 | 说明 |
| --- | --- |
| `searchMode` | `'off'` / `'on'` / `'auto'` |
| `useModelBuiltinSearch` | 使用模型内置搜索（如 Gemini grounding） |
| `searchFCModel` | 指定用于搜索功能调用的工作模型（`{ model, provider }`） |
| `urlContext` | 是否传入 URL 上下文 |

**内存系统**

| 字段 | 说明 |
| --- | --- |
| `memory.enabled` | 是否启用长期记忆 |
| `memory.effort` | 记忆处理强度 `'low'` / `'medium'` / `'high'` |
| `memory.toolPermission` | `'read-only'`（仅读记忆）/ `'read-write'`（可写入记忆） |

**自迭代与图编排**

| 字段 | 说明 |
| --- | --- |
| `selfIteration.enabled` | 允许 Agent 自我迭代 |
| `enableGraphMode` | 开启图式编排运行时（Graph Runtime） |
| `graph` | `ReasoningGraph` 对象（图式编排定义） |

**图像生成**

| 字段 | 说明 |
| --- | --- |
| `imageAspectRatio` | 图像宽高比（如 `"16:9"`） |
| `imageResolution` | `'1K'` / `'2K'` / `'4K'` |

**其他**

| 字段 | 说明 |
| --- | --- |
| `textVerbosity` | `'low'` / `'medium'` / `'high'`，控制输出详略 |
| `toolResultMaxLength` | 工具结果内容最大长度（默认 25000 字符） |
| `topicGroupMode` | 话题列表分组方式（`byTime` / `byProject` / `flat` / `byStatus`） |
| `runtimeEnv.workingDirectory` | 桌面端工作目录（deprecated，推荐用 `agencyConfig.workingDirByDevice`） |

## 5. 外部工具与知识能力

### 5.1 插件（Plugins）

`plugins` 字段是 `AgentPluginEntry[]`，每个条目为三态：

- **bare string**（legacy）：等同 `{ identifier, mode: 'pinned' }`；
- `{ identifier, mode: 'pinned' }`：固定激活，每次请求都注入工具定义；
- `{ identifier, mode: 'auto' }`：自动激活，由 Agent 决定是否使用；
- `{ identifier, mode: 'disabled' }`：在此 Agent 中禁用该插件。

推荐用 `getActivePluginIds()`、`getPinnedPluginIds()`、`getDisabledPluginIds()`、`getPluginMode()` 等帮助函数操作，而非直接读取字段。

### 5.2 知识库

`knowledgeBases?: KnowledgeBaseItem[]` 挂接知识库。每个 Agent 独立的知识库绑定；知识库启用/禁用通过 `agent.toggleKnowledgeBase(agentId, knowledgeBaseId, enabled)` 接口控制。

### 5.3 文件附件

`files?: FileItem[]` 允许将文件绑定到 Agent；文件内容在对话时通过路由后端注入上下文。

### 5.4 TTS

`tts: LobeAgentTTSConfig` 为 Agent 专属 TTS 配置（语音合成服务、voice、speed 等），具体字段在 `packages/types/src/agent/tts.ts` 定义。

### 5.5 异构 Agent 绑定

`agencyConfig?: LobeAgentAgencyConfig` 支持：
- 设备级工作目录绑定（`workingDirByDevice`）；
- 指定异构 Agent Provider（用于 Heterogeneous Agents 功能，详见 `packages/heterogeneous-agents`）。

## 6. 内置 Agent 方向

LobeHub 不在代码中硬编码多个完整的角色预设；角色人格通过以下渠道引入：

1. **Chat Group Wizard 模板**（`src/components/ChatGroupWizard/templates.ts`）：提供 brainstorm、analysis、writing、planning、product、game 六类群组模板，每个模板包含 2–4 个成员 Agent，每个成员有 `title`、`avatar`、`systemRole`、可选 `plugins`；这些是 Agent 组的起点，不是单个 Agent 的完整配置。
2. **Agent 市场**（`lobe-chat-agents` + 远端 API）：市场 Agent 通过 `src/services/agent.ts` 的 `normalizeMarketAgentConfig()` 导入，自动处理 `model` 字段为对象/字符串两种格式的兼容。
3. **Agent Builder**（`src/features/AgentBuilder/`）：AI 驱动的 Agent 建议芯片（`SuggestionChips`），帮助用户一步步配置 systemRole 和其他字段。

`chatConfig.toolMode: 'custom'` 可以创建"精确范围"的子 Agent（如验证器），只拥有声明的插件，不注入任何默认工具。

## 7. 导入与兼容性

- **市场导入**：通过 `importFromMarket()` 将市场 Agent 写入本地数据库，`normalizeMarketAgentConfig()` 处理格式差异；
- **JSON 导出**（`src/features/ShareModal/ShareJSON/`）：`generateFullExport()` 生成含完整 AgentConfig 的 JSON 文件；
- **SillyTavern 迁移**：没有官方路径；`systemRole` 对应角色卡的 system_prompt，`fewShots` 对应示例对话，知识库可替代世界书；
- **AIO Hub 预设导入**：类型差异较大，主要在消息树/注入策略，需手工适配。

## 8. 主要源码依据

- `lobehub/packages/types/src/agent/item.ts`：`LobeAgentConfig` 主类型。
- `lobehub/packages/types/src/agent/chatConfig.ts`：`LobeAgentChatConfig`（超过 40 个可选字段）。
- `lobehub/packages/types/src/agent/agentConfig.ts`：`AgentMode`、`RuntimeEnvMode`、`RuntimeEnvConfig`。
- `lobehub/packages/types/src/agent/index.ts`：类型统一导出。
- `lobehub/src/features/AgentSetting/store/initialState.ts`：`State` 中的 `config: LobeAgentConfig` 和 `meta: MetaData`。
- `lobehub/src/features/AgentSetting/store/reducers/config.ts`：Config 更新操作（update/togglePlugin/reset）。
- `lobehub/src/services/agent.ts`：Agent CRUD 和市场导入 API 调用层（使用 `LobeAgentConfig`）。
- `lobehub/src/components/ChatGroupWizard/templates.ts`：群组模板（包含成员 Agent 结构示例）。

## 9. 调查边界

本篇关注"Agent 配置模型"，未详细展开 `humanIntervention` 工具审批策略、`headless` 子 Agent 绑路径、MCP 工具执行位置和 builtin 工具零审批问题；这些在 [LobeHub-Agent工具调查笔记.md](../Agent工具/LobeHub-Agent工具调查笔记.md) 中有详细记录。`params` 字段具体子字段以 `model-bank` 包文档为准。
