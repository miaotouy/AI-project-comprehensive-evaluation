# Chatbox Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：只读核对 Copilot 类型定义、Session 类型、Settings Schema、初始数据、Skills 类型及 Agent Mode 实现；未修改被调查仓库源码
>
> 调查范围：Copilot/角色能配置什么、与 Session 的关系、能力边界，以及内置示例方向
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

Chatbox 没有独立的"Agent 对象"，它的角色系统围绕两个对象展开：

- **`CopilotDetail`**（角色模板）：只存储人格信息（名称、系统提示词、头像、描述、标签）；不包含模型参数。
- **`Session`**（对话实例）：通过 `copilotId` 与 Copilot 关联，在 `settings` 字段保存模型与采样参数；每个 Session 独立管理自己的对话历史和设置。

这意味着同一个 Copilot 可以用不同模型/温度创建多个对话，两者之间没有强绑定。内置的预设 Session 展示了几种典型角色：旅游向导、社媒网红、软件开发者、翻译专家等。

技能层（Skills）和 Agent Mode 决定 Copilot 在运行时能做什么：技能层是指令加工具描述的文本组合，打开该模式后模型进入工具调用循环。两者都是会话级配置，不写死在 Copilot 中。

## 2. 配置入口

Chatbox 没有 JSON/YAML 预设目录，角色配置通过 UI 管理：

- 本地 Copilots 列表，用户在 UI 中创建/编辑，数据持久化在本地 storage；
- 远端 Copilot 市场，通过 `remote.ts` 拉取分页列表，支持按标签和关键词搜索；
- 导出/导入备份包含 Copilots 集合，格式与 `resources.ts` 定义的备份 schema 一致。

## 3. 人格与对话行为

### 3.1 CopilotDetail 字段

```typescript
interface CopilotDetail {
  id: string
  name: string
  prompt: string          // 系统提示词全文，直接以 system role 注入对话首条
  picUrl?: string         // 已废弃，迁移至 avatar
  avatar?: ImageSource    // { type:'url', url } | { type:'storage-key', storageKey }
  backgroundImage?: ImageSource
  description?: string
  tags?: string[]
  screenshots?: ImageSource[]
  createdAt?: number
  updatedAt?: number
  usedCount?: number
  sourceId?: string       // 若从远端市场复制，记录原始 ID
  starred?: boolean
}
```

角色只有这些字段：**名称 + 系统提示词 + 视觉素材 + 描述/标签元数据**。没有模型参数、工具配置或分支对话。

### 3.2 提示词注入方式

Copilot 的 `prompt` 字段会直接成为会话首条 system 消息，初始预设数据（`initial_data.ts`）可验证这一点。少样本示例不属于 Copilot：初始数据中的 user/assistant 示例消息存放在会话的 `messages` 数组里。

### 3.3 Session 与 Copilot 的绑定

会话通过可选的 `copilotId` 字段与 Copilot 关联：用户用某个 Copilot 创建新对话时，系统把该角色的 `prompt` 写为会话首条 system 消息并持久化关联 ID。此后每次切换到该会话，`usedCount` 等统计字段随之更新。

一个 Copilot 可以关联任意数量的会话，每个会话使用不同的模型参数。修改该角色的 `prompt` 不会自动同步到已创建的历史对话——其中的 system 消息是创建时写入的静态内容。

### 3.4 发送时的设置来源与消息快照

发送、续写与重新生成时，模型与温度一律从会话自身的 `settings` 读取，不读全局或 Copilot 配置。创建会话时，全局的 `lastUsedChatModel` 会经 `mergeDefaultSessionSettings` 固化进新会话的 `settings` 字段（注释明确"创建会话时从全局设置复制"）；聊天内换模型同样写回该字段。

Skills 启用列表、Agent Mode 与知识库选择属于另一组来源：Skills 启用列表读全局（`tools-builder.ts:338-339`）；Agent Mode 优先读会话自身的 `agentMode` 设置（`agent-mode.ts:20-26`）；知识库选择只保存在内存映射 `uiStore.sessionKnowledgeBaseMap`，不落库。

本节涉及的其余源码定位：

- `src/renderer/stores/chatStore.ts:311-316`：创建会话时固化设置
- `src/renderer/stores/chatStore.ts:561-573`：`mergeDefaultSessionSettings`
- `src/renderer/routes/session/$sessionId.tsx:127-141`：`onSelectModel` 聊天内换模型

每条消息只快照两个字段，temperature、技能启用列表与 Agent Mode 等设置不进入快照：

| 快照字段 | 写入值 |
| --- | --- |
| `aiProvider` | `settings.provider` |
| `model` | `getModelDisplayName(...)`（模型显示名） |

写入入口为 `initializeTargetMessage`（`src/renderer/stores/session/utils.ts:134-153`），字段定义见 `src/shared/types/session.ts:305-306`。

### 3.5 重新生成语义

重新生成**不替换原消息**，而是走 fork 分支：`regenerateInNewFork`（`src/renderer/stores/session/generation.ts:104-138`）先创建 fork，再在分支中插入一条新的 assistant 消息触发生成；只有消息是首条或找不到插入位置时，才回退到在原消息上直接生成。

例外是工具暂停后的继续与重试：这些路径以 `appendToMessage: true` 写回原消息，而不是创建分支。

本快照未找到开场白字段（"greeting" 仅出现在新手指引流程 `useGuideSession.ts:148-315`）和提示词块分组/组级开关。

本节涉及的其余源码定位：

- `forks.ts:27`：`createNewFork`；`shared/session/message-forks.ts`：fork 变换的纯函数 patch
- `orchestration.ts:1205、1355、1468、1499`：`continuePausedToolCall`/`stopPausedToolCall` 恢复路径

### 3.6 会话级 Agent 行为设置

`SessionSettingsSchema` 在 `shared/types/settings.ts:211` 提供可选的 `pauseOnToolCallLimit` 字段：按会话覆盖全局"工具调用 25 次确认点"（同名全局字段默认开启，`shared/types/settings.ts:558`）。该字段与 Copilot 无关，属于会话级 Agent 行为设置（生效语义见对话请求与上下文笔记 9.5、Agent 工具笔记 5.2）。

## 4. 模型与输出偏好

模型参数在 Session 层，不在 Copilot 层。

### 4.1 SessionSettings 字段

```typescript
// src/shared/types/settings.ts: SessionSettingsSchema
{
  provider?: string
  modelId?: string
  temperature?: number
  topP?: number
  maxTokens?: number
  stream?: boolean
  dalleStyle?: 'vivid' | 'natural'
  imageGenerateNum?: number
  providerOptions?: {
    claude?: { thinking: { type, budgetTokens }, effort }
    openai?: { reasoningEffort, reasoningSummary, include, forceReasoning }
    google?: { thinkingConfig: { thinkingBudget, thinkingLevel, includeThoughts } }
    deepseek?: { thinking: { type } }
    openaiCompatible?: { reasoningEffort, reasoning, enable_thinking, thinking_budget }
    openrouter?: { reasoning }
  }
  autoCompaction?: boolean      // 上下文达阈值时自动压缩摘要
  workingDirectories?: string[] // 桌面端：授权 Agent 无需逐次审批读写的本地目录
  agentFullAccess?: boolean     // Work Mode：跳过 user_exec 和写入变更的单次审批
  agentMode?: { value: 'auto'|'on'|'off', locked: boolean, lockReason: ... }
}
```

### 4.2 全局默认模型设置

Settings 还可以为不同用途分别指定默认模型（对话、会话命名、搜索词构造、OCR、embedding、rerank），均为全局设定，不属于某个 Copilot：

- `defaultChatModel`
- `threadNamingModel`
- `searchTermConstructionModel`
- `ocrModel`
- `defaultEmbeddingModel`
- `defaultRerankModel`

## 5. 技能与可执行能力

### 5.1 Skills 系统

Skills 是指令描述文档，不是沙箱隔离的权限域。`SkillSettings` 控制哪些 Skill 生效：

```typescript
{
  enabledSkillNames: string[]         // 已启用的 Skill 名列表
  translationEnabled: boolean
  builtinDefaultsInitialized: boolean
  appliedDefaultBuiltinSkillNames: string[]
}
```

Skill 的来源（`SkillSource.type`）可以是：
- `builtin`：内置，默认启用的有 `chatbox-product-info` 和 `vibedrop`
- `local`：本地文件系统
- `marketplace`：官方市场
- `github`：GitHub 仓库
- `chat`：从对话生成
- `claude-code`：从 `~/.claude/skills` 发现
- `agents`：从 `~/.agents/skills` 发现（Codex 等）

Skill 元数据（`SkillInfo`）描述技能的展示信息（名称、描述）、分发属性（许可证、兼容性）以及声明允许使用的工具（`allowedTools`）等。

### 5.2 Agent Mode

`agentMode.value` 的三个状态：

| 状态 | 含义 |
| --- | --- |
| `auto` | 默认，由系统根据上下文判断是否进入工具循环 |
| `on` | 强制开启工具调用循环 |
| `off` | 禁用工具，纯对话 |

Mode 可以被锁定（`locked: true`），防止用户在中途切换，锁定原因如下：

- `file_upload`：上传文件时
- `load_skill`：加载 Skill 时
- `message_sent`：消息发送中

`agentFullAccess` 打开后，`user_exec` 和文件系统写入操作不再需要逐次审批（Work Mode）。`workingDirectories` 列出授权目录，沙箱实现在 macOS/Linux 上依赖 `@anthropic-ai/sandbox-runtime`，Windows 无 OS 级隔离。

### 5.3 MCP 服务器

全局 `MCPSettings` 管理 stdio 和 HTTP 两种 MCP 服务器，每个服务器可独立启用并携带自己的标识字段。这是全局配置，不绑定到 Copilot；组装工具集时，系统按模型能力和当前 Agent Mode 动态决定哪些 MCP 工具生效。

### 5.4 知识库

知识库的 embedding 与 rerank 模型由全局 `extension.knowledgeBase.models` 指定；会话可附加文件，经 `session-attachment-rag` 模块索引，提供两种召回方式：`inline`（附加到消息）与 `session-retrieval`（按需检索）。

## 6. 内置 Copilot 方向画像

Chatbox 的内置示例均以会话预设的形式存在（`initial_data.ts`），每个预设的 system 消息决定了角色方向：

| 预设 Session | 角色描述 | 典型风格 |
| --- | --- | --- |
| Travel Guide | 旅游向导，根据位置推荐景点 | 实用建议型 |
| Social Media Influencer | 为 Instagram/Twitter/YouTube 创作内容 | 营销文案型 |
| Software Developer | 代码助手 | 技术支持型 |
| Translator | 翻译专家 | 精准转换型 |
| XHS (小红书) | 小红书内容创作 | 中文媒体型 |
| Just chat | 无特殊角色 | 通用助手 |

这些预设 Session 大多关联了远端 Copilot ID（`copilotId: 'chatbox-featured:XX'`），表明对应的完整提示词由远端市场托管，本地只存快照。

远端市场 Copilots 支持分页浏览和按标签过滤，`usedCount` 记录使用次数用于排行。

## 7. 导入与兼容性

- **备份**：`export-backup.ts` 导出包含全部本地 Copilots 的 ZIP/JSON 备份。
- **远端同步**：从市场复制 Copilot 到本地时，`sourceId` 记录来源 ID；可凭此判断是否需要更新。
- **格式**：Copilot 的核心载体是纯文本 `prompt`，没有 provider-specific 字段，因此跨版本兼容性较好。
- **SillyTavern/AIO Hub 迁移**：没有官方路径；手工将角色卡的 system prompt 字段粘贴为 Copilot 的 `prompt` 即可，few-shot 示例需另行处理。

## 8. 主要源码依据

- `chatbox/src/shared/types.ts`：`CopilotDetail` 接口定义。
- `chatbox/src/shared/types/session.ts`：`SessionSchema`、`SessionSettingsSchema` 类型。
- `chatbox/src/shared/types/settings.ts`：`SettingsSchema`、`GlobalSessionSettingsSchema`、`MCPSettingsSchema`。
- `chatbox/src/shared/types/skills.ts`：`SkillInfo`、`SkillSettings`、`SkillSource`。
- `chatbox/src/renderer/packages/initial_data.ts`：内置预设 Session 示例（含角色方向）。
- `chatbox/src/renderer/hooks/useCopilots.ts`：Copilot 列表管理、远端分页查询。
- `chatbox/src/renderer/packages/remote.ts`：远端市场 API 交互。
- `chatbox/src/renderer/packages/backup/`：备份导出/导入逻辑。

## 9. 调查边界

本篇关注"角色配置模型"，未详细展开工具审批链路、MCP 执行位置和沙箱安全边界；这些内容参见 [Chatbox-Agent工具调查笔记.md](../Agent工具/Chatbox-Agent工具调查笔记.md)。Skills 的具体注入方式（`buildToolsForSession()`）和 Agent Mode 的执行细节同样以工具笔记为准。
