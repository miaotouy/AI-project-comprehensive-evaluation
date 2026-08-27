# Cherry Studio Agent / 角色配置调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`88cfe5dd2b77e63464be22968f66ebcb1d429483`（分支：`main`）
>
> 调查方式：只读核对 Assistant 类型定义、数据库 Schema、AssistantSettings、默认预设、系统提示词装配逻辑和 AgentSession 入口；未修改被调查仓库源码
>
> 调查范围：Assistant/角色能配置什么、模型偏好、工具能力边界及内置默认
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

Cherry Studio 的角色系统核心对象是 **`Assistant`**（助手），一个助手对应一套"模型 + 提示词 + 推理参数 + 工具源"的稳定配置。与 Chatbox 不同，模型参数写在助手内部（`settings` 字段），不在会话级别，因此同一个助手在不同对话中使用相同的参数基准。

助手通过四个关联维度决定能力边界：

- `mcpServerIds`、`knowledgeBaseIds`：关联 MCP 工具与知识库
- `modelId`（`"providerId::modelId"` 格式）：绑定默认模型
- `groupId`：加入分组

除普通助手会话外，Cherry Studio 还支持 **Agent Session**（`AgentSessionRuntimeService`）。它基于 Claude Code SDK 进入工具调用循环，消息使用独立的 `AgentSessionMessageBackend` 持久化。

## 2. 配置入口与数据格式

### 2.1 数据库 Schema

助手配置存储在 SQLite 数据库 `assistant` 表（`src/main/data/db/schemas/assistant.ts`）：

```sql
assistant(
  id          UUID PRIMARY KEY,
  name        TEXT NOT NULL,
  prompt      TEXT NOT NULL DEFAULT '',   -- 系统提示词
  emoji       TEXT NOT NULL,              -- UI 图标（Emoji）
  description TEXT NOT NULL DEFAULT '',
  modelId     TEXT REFERENCES user_model(id) ON DELETE SET NULL,
  groupId     TEXT REFERENCES group(id)   ON DELETE SET NULL,
  settings    TEXT (JSON),                -- AssistantSettings JSON blob
  orderKey    TEXT,                       -- 排序键
  createdAt, updatedAt, deletedAt         -- 软删除
)
```

关联表通过独立中间表维护：
- `assistant_mcp_server`（有序列表）→ MCP 服务器
- `assistant_knowledge_base`（有序列表）→ 知识库

### 2.2 默认助手预设

首次启动时，`DefaultAssistantSeeder` 自动写入一个空提示词的助手（Cherry 助手 / Cherry Assistant），绑定内置默认模型（`CHERRYAI_DEFAULT_UNIQUE_MODEL_ID`）。这是唯一的内置实例，不是多个预设角色的集合。

### 2.3 资源目录（Catalog）

`useAssistantCatalogPresets` 钩子和 `resourceCatalog/` 相关代码从远端或本地目录加载助手模板，供用户一键导入；这属于市场化模板体系，不是直接打包在源码中的固定预设。

## 3. 人格与对话行为

### 3.1 Assistant 字段

```typescript
interface Assistant {
  id: string                  // UUID v4
  name: string                // 显示名称（min 1 字符）
  prompt: string              // 系统提示词；空字符串 = 不注入 system 消息
  emoji: string               // Emoji 图标
  description: string         // 长描述
  settings: AssistantSettings // 见下节
  modelId: string | null      // "providerId::modelId" 格式；null = 尚未选择
  groupId: string | null      // 分组 ID
  orderKey: string            // 只读排序键，通过 order 接口修改
  mcpServerIds: string[]      // 有序 MCP 服务器 ID 列表
  knowledgeBaseIds: string[]  // 有序知识库 ID 列表
  createdAt: string           // ISO datetime
  updatedAt: string           // ISO datetime
  modelName: string | null    // 运行时只读：从 modelId 解析的显示名称
}
```

### 3.2 系统提示词装配

`assembleSystemPrompt` 函数（`src/main/ai/runtime/aiSdk/params/assembleSystemPrompt.ts`）：

1. 若 `assistant.prompt` 非空，先做变量替换（`replacePromptVariables`，代入模型名）再写入；
2. 若工具集中包含 `tool_search` 工具，追加推迟工具的命名空间目录提示词（`deferredToolsSystemPrompt`）；
3. 所选首方查询工具带 citation-id 契约时（`hasCitableTools`）追加 `CITATIONS_SYSTEM_PROMPT` 引用格式说明段（`assembleSystemPrompt.ts:19-25,41-49`）；
4. 多段用 `\n\n` 连接，全空返回 `undefined`。

目前 `prompt` 是纯文本，支持变量替换但没有类似 AIO Hub 的多节点消息树；没有 few-shot 示例对话的原生存储字段。

### 3.3 会话绑定与历史快照语义

会话（topic）只保存 `assistantId` 引用（`src/main/data/db/schemas/topic.ts:20`，另有 `activeNodeId`），不保存助手配置副本；每次发送请求都按 id 重读当前助手，因此修改助手后，既有会话的下一次请求立即使用新配置，属于"运行时引用"语义。

重读发生在请求构造阶段：先解析模型，再按 id 读取助手，最后用当前 prompt/settings/tools 构建请求参数（链路见本节末尾源码定位）。

例外是自动命名：`TopicNamingService.generateSummaryTitle` 生成标题的请求刻意**不携带 `assistantId`**，避免把助手的工具配置（MCP/联网/知识库）挂到标题生成请求上。

消息侧只有部分快照：每条 assistant 消息保存 `modelId` 与 `messageSnapshot`（作者 id/name/emoji 加内嵌模型快照），由 `buildAssistantMessageSnapshot` 在占位消息创建时写入；快照不含 temperature 等采样参数，未找到完整助手配置的 revision 快照。

本节源码定位：

- `modelResolution.ts:32-45`：`resolveAssistantModelId`，随后 `assistantDataService.getById` 读取助手
- `AiService.ts`：`getProviderAndModel` 在请求构造时再次 `getById(request.assistantId)`
- `assembleSystemPrompt.ts`：`buildAgentParams` 建参时直接读 `assistant.prompt`
- `src/main/data/db/schemas/message.ts:39-41`、`src/shared/data/types/message.ts:396-402`：消息快照字段定义
- `PersistentChatContextProvider.ts:39-55`（:246）：`buildAssistantMessageSnapshot` 写入点
- `modelResolution.ts:53-64`：`resolvePersistentSiblingsGroupId`（重新生成分支）

重新生成不是覆盖：前端入口 `regenerateWithCapabilities`（`src/renderer/pages/home/hooks/useChatWriteActions.ts:304`）发起流式请求，主进程在重生成分支中为回复继承或新分配 `siblingsGroupId`，在原用户消息下新建 assistant 兄弟占位，旧回复保留——与 AIO Hub 的"同历史分支重新生成对比"语义一致。

另外，"从历史节点开新分支"采用持久化空 user 叶子（`reserveBranch`/`fill-reserved`），该语义属会话与消息管理类目。

本快照未找到开场白字段（`ConversationGreeting.tsx` 只是空会话占位组件，不落库）和提示词块分组/组级开关（`assistant.prompt` 是单文本；`prompt` 表是独立"用户提示词片段"，非分组机制）。

## 4. 模型与输出偏好

### 4.1 AssistantSettings 字段

```typescript
interface AssistantSettings {
  // ——推理参数——
  temperature: number           // 默认 1.0
  enableTemperature: boolean    // false = 使用模型默认值，字段仍存储但不发送
  topP: number                  // 默认 1
  enableTopP: boolean           // false = 使用模型默认值
  maxTokens: number             // 默认 4096
  enableMaxTokens: boolean      // false = 使用模型默认值
  streamOutput: boolean         // 默认 true
  reasoning_effort: 'default' | 'low' | 'medium' | 'high' | ... // 推理强度

  // ——工具使用——
  mcpMode: 'disabled' | 'auto' | 'manual'
  maxToolCalls: number          // 默认 100（合法范围 1-1000，`assistant.ts:31-35,108`）
  enableMaxToolCalls: boolean   // 默认 true

  // ——上下文来源——
  enableWebSearch: boolean      // 默认 false
  enableGenerateImage: boolean  // 默认 false；需要 Settings 里配置画图模型

  // ——自定义参数——
  customParameters: Array<
    | { name: string; type: 'string';  value: string  }
    | { name: string; type: 'number';  value: number  }
    | { name: string; type: 'boolean'; value: boolean }
    | { name: string; type: 'json';    value: unknown }
  >
}
```

`enable*` 标志的语义：`false` 时字段值保留在数据库，但构建 API 请求时不传入，让模型使用自己的默认值；`true` 时才将存储值发送给 API。这个模式消除了"禁用时字段需要变为 null"的问题。

`customParameters` 支持任意键值对，适合传递 provider 专有参数，例如 `top_k`、`repetition_penalty`；字符串、数字、布尔与 JSON 四种类型各有对应的 UI 组件（文本框、数字微调、开关、JSON 编辑器）。

### 4.2 MCP 工具模式

`mcpMode` 控制 MCP 服务器如何参与请求：
- `disabled`：本次请求不使用任何 MCP 工具；
- `auto`：使用助手 `mcpServerIds` 列表中的服务器；
- `manual`：用户手动选择 MCP 服务器。

`mcpServerIds` 存储的是有序列表，决定工具集的优先级。

## 5. 工具与外部能力

### 5.1 知识库

`knowledgeBaseIds` 关联的知识库在对话时参与 RAG 召回。每个知识库有独立的向量索引；调用方式和召回策略由全局设置决定，不在 Assistant 层单独配置。

### 5.2 Web 搜索

`enableWebSearch` 开启后，`web_search` 工具注入工具集；实际执行由全局 `extension.webSearch` 设置决定使用哪个搜索 provider（内置、bing、tavily、bocha、querit 五选一）。

### 5.3 图像生成

`enableGenerateImage: true` 注入 `generate_image` 工具；依赖 Settings 中的 "画图模型" 配置（`defaultEmbeddingModel` 同层级的专用画图模型设置）。

### 5.4 Claude Code Agent Session

`src/main/ai/agentSession/AgentSessionRuntimeService.ts` 实现了独立的 Agent 会话路径，基于 Claude Code SDK 运行 Agent 循环，使用独立的持久化后端（`AgentSessionMessageBackend`）。这条路径不依赖 `AssistantSettings.mcpMode`，直接走 Claude Code 自己的工具注册表。启用入口在助手编辑器的"代码解释器"或 Agent 模式开关；工具权限和审批策略参见 [Cherry-Studio-Agent工具调查笔记.md](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)。

## 6. 内置角色方向

Cherry Studio 只有一个内置助手实例（空提示词的 "Cherry 助手"），不预置多个角色人格。角色的个性化完全靠用户的 `prompt` 字段，以及从资源目录市场导入的模板。

需要区分：**内置 cherry-assistant Agent**（`resources/builtin-agents/cherry-assistant/`）走的是 Claude Code Agent 路径的内置 Agent 体系，与 `DefaultAssistantSeeder` 生成的普通 Assistant 实例是两套对象：前者是 Agent（有 SOUL/工具白名单），后者是空提示词助手——"只有一个内置助手、不预置多角色人格"的结论只适用于 Assistant 体系。Agent 目录包含以下文件：

- `SOUL.md`
- `agent.json`
- `product-manifest.json`

Legacy v1 代码（`LegacyAssistant` 类型）显示旧版本曾有更多字段，v2 迁移时做了精简：主要能力保留在 `AssistantSettings` 中，或移到了独立关联表。旧版字段（部分列举）包括：

- `type`、`group`
- `messages`（少样本示例对话）
- `enableUrlContext`
- `knowledgeRecognition`
- `regularPhrases`

## 7. 导入与兼容性

- **资源目录**：通过 `resourceCatalog/` 和 `assistantTransfer.ts`，支持从市场导入助手模板；工具配置不跨随助手迁移，需在目标机器重新绑定。
- **v1 → v2 迁移**：`AssistantMigrator.ts` 把旧版字段映射到新 Schema；部分字段（如 `contextCount`、`toolUseMode`）被废弃或并入助手设置层。
- **SillyTavern/AIO Hub 迁移**：没有官方路径；将源角色的系统提示词导入 `prompt` 字段即可，少样本对话和世界书没有原生对应字段。

## 8. 当前角色能力边界

Agent 的运行时选项现覆盖 Claude Code、Pi 与 DSH。创建与编辑界面依据模型兼容性为每种运行时筛选可选模型，并在缺失模型上下文窗口时以 256K 作为运行时默认值；这属于 Agent 执行配置，不改变 Assistant 普通聊天的渠道实体。Prompt 也可按 Assistant 或 Agent 目标建立可见性绑定，配置对象仍由资源目录和数据服务持久化，而非在单次聊天中临时拼接。

Global Memory 的范围说明与概览文档明确了记忆的归属边界，但本次未运行验证跨会话召回的实际效果。依据：`src/shared/ai/agentRuntimeCapabilities.ts`、`src/shared/ai/piModelCompatibility.ts`、`src/shared/ai/dshModelCompatibility.ts`、`src/renderer/pages/settings/PromptSettings.tsx`、`src/main/data/services/PromptService.ts`、`docs/references/memory/overview.md`。

## 9. 主要源码依据

- `cherry-studio/src/shared/data/types/assistant.ts`：`AssistantSchema`、`AssistantSettingsSchema`、`DEFAULT_ASSISTANT_SETTINGS`。
- `cherry-studio/src/main/data/db/schemas/assistant.ts`：数据库表定义及 `AssistantSettings` 存储策略。
- `cherry-studio/src/main/data/db/seeding/seeders/defaultAssistantSeeder.ts`：默认助手种子逻辑。
- `cherry-studio/src/shared/data/presets/defaultAssistant.ts`：默认助手预设数据。
- `cherry-studio/src/main/ai/runtime/aiSdk/params/assembleSystemPrompt.ts`：提示词装配逻辑。
- `cherry-studio/src/main/ai/runtime/aiSdk/params/buildAgentParams.ts`：API 参数构建总控。
- `cherry-studio/src/main/ai/agentSession/AgentSessionRuntimeService.ts`：Agent Session 运行时。
- `cherry-studio/src/renderer/types/assistant.ts`：渲染层类型（含 `LegacyAssistant` 废弃类型）。

## 10. 调查边界

本篇关注"助手配置模型"，未展开 MCP 执行位置、审批链路、工具注册表和 Claude Code Agent 的权限细节；这些内容参见 [Cherry-Studio-Agent工具调查笔记.md](../Agent工具/Cherry-Studio-Agent工具调查笔记.md)。
