# VCPChat Agent / 角色配置调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对；只读核对 agentConfigManager、agentHandlers、chatManager、settingsManager，未修改被调查仓库源码
>
> 调查范围：Agent 配置结构、存储方式、能力字段与运行时行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 补充要点

- **模型参数可留空**：设置页折叠参数段的五个数值输入（温度、上下文长度上限、单次输出上限、top_p、top_k）留空保存时记为 `null`，折叠段随之显示“未设置”；空值解析、回填与保存由 `parseOptionalNumberInput` 完成，发送前再由 `omitUnsetOptionalModelParams` 把这些未设置的参数从请求体里删除。源码见 `modules/settingsManager.js:220-224,276-282,323-327` 和 `modules/ipc/chatHandlers.js:123-147,1064`。
- **重新回复时附件文本重新提取**：`handleRegenerateResponse`（`modules/renderer/messageContextMenu.js:857-887`）在历史缓存了旧版固定 UTF-8 解码结果时，通过 `electronAPI.getTextContent` 从原始附件重新提取文本；`modules/fileManager.js:357-405` 的 `decodeTextBuffer` 提供 UTF-8/UTF-16 BOM、UTF-16 零字节启发式和 GB18030 兜底检测。

## 1. 结论摘要

VCPChat 的"角色"是**以文件夹为单位的 Agent**：每个 Agent 对应用户数据目录下一个以 `agentId` 命名的子目录，目录内的 `config.json` 存储所有配置字段，`regex_rules.json` 存储独立的正则处理规则，头像图片（支持 PNG/JPG/GIF/WEBP）也保存在同一目录。

可配置字段有系统提示词、模型选择、温度、上下文长度限制、输出长度限制、流式输出开关，以及用于管理多线对话的话题列表。不能在 Agent 内部配置工具调用策略，工具能力仍由 VCP 分布式服务器负责；但提示词资产现在可由 PromptSponsor 工具读取和修改，并通过主进程服务复用 AgentConfigManager 的锁与原子写入。

## 2. 目录与文件结构

```
{userDataDir}/
  {agentId}/
    config.json         -- Agent 配置主文件
    config.json.backup  -- 原子写入前的备份（由 AgentConfigManager 维护）
    regex_rules.json    -- 正则处理规则（不写入 config.json）
    topics/
      {topicId}/
        history.json    -- 单条话题的对话历史
    avatar.png          -- 或 .jpg/.gif/.webp（可选）
```

`AgentConfigManager` 使用锁文件（`config.json.lock`）保证原子写入，并维护内存缓存以减少磁盘读取。读取失败时按优先级回退：内存缓存 → `.backup` 文件 → 默认配置（仅在 `allowDefault: true` 时）。

## 3. Agent 配置字段（config.json）

```json
{
  "name": "AgentDisplayName",
  "systemPrompt": "你是 {{AgentName}}。...",
  "model": "gemini-2.5-flash-preview-05-20",
  "temperature": 0.7,
  "contextTokenLimit": 1000000,
  "maxOutputTokens": 60000,
  "streamOutput": true,
  "topics": [
    { "id": "default", "name": "主要对话", "createdAt": 1234567890 }
  ]
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | `string` | Agent 显示名称（UI 展示和日志中使用） |
| `systemPrompt` | `string` | 系统提示词全文，支持 `{{AgentName}}` 宏替换 |
| `model` | `string` | 后端模型 ID（直接传给 VCP 分布式服务器） |
| `temperature` | `number` | 温度（默认 0.7）；当前 HEAD 支持存 `null` 表示"未设置"，发送时从请求体省略（见补充要点） |
| `contextTokenLimit` | `number` | 上下文截断上限，默认 1,000,000；新建默认 4,000；可留空存 `null` |
| `maxOutputTokens` | `number` | 单次最大输出 token 数，默认 60,000；新建默认 1,000；可留空存 `null` |
| `streamOutput` | `boolean` | 流式输出开关（默认 `true`） |
| `topics` | `Topic[]` | 话题列表，每条有 `id`、`name`、`createdAt`；另有 `locked/unread/creatorSource` 字段（兼容归一化见会话与消息管理笔记） |

**不写入 config.json 的字段：**
- `stripRegexes`：正则处理规则，从 `regex_rules.json` 独立加载，处理后传参给 chatManager，不持久化到主配置；

### 3.1 系统提示词宏

`systemPrompt` 在运行时通过以下宏替换：

| 宏 | 替换内容 |
| --- | --- |
| `{{AgentName}}` | 当前 Agent 的 `name` 字段值 |

这是唯一已确认的内置宏，不同于 AIO Hub 的完整宏系统；VCPToolBox 的 `{{VarXxx}}` 等宏不在 VCPChat 客户端侧处理，由上游 VCPToolBox 服务器处理。

### 3.2 话题（Topics）

一个 Agent 可以有多条话题（对话线程），每条话题有独立的历史文件（`topics/{topicId}/history.json`）。话题列表存在 `config.json` 的 `topics` 字段，至少有一个默认话题 `"default"`。创建 Agent 时会自动创建第一个话题目录。

### 3.3 三模式提示词管理器

独立于 `systemPrompt` 字段，还存在**三模式 PromptManager**（`Promptmodules/prompt-manager.js:6`）：由 `promptMode` 决定使用 original、modular 还是 preset 模式，对应存储字段为 `advancedSystemPrompt`/`presetSystemPrompt`：

- **original**：单段文本（对应笔记 §3 的 systemPrompt 路径）；
- **modular（积木模式）**：提示词按扁平数组存放，每个积木块带独立的 `disabled` 开关，组装时过滤掉停用块；块内的 `variants` 保存多条备选内容，同一时刻只有 `selectedVariant` 指定的那条生效。积木块支持拖拽排序，也能收进小仓（hiddenBlocks/warehouse）隐藏，这一层没有组级总开关，也没有单选组或多选组，块之间是平铺关系。实现见 `Promptmodules/modular-prompt-module.js:60,130-131,365-377,569,1209`，主进程侧同样的过滤逻辑见 `modules/ipc/promptHandlers.js:193-194`；
- **preset**：从预设目录里选一个 `.md` 或 `.txt` 文件，整段替换当前提示词。预设列表由 `load-preset-prompts` 扫描目录生成，默认目录是 `AppData/systemPromptPresets`；选择与加载逻辑见 `preset-prompt-module.js:269,344` 和 `modules/ipc/promptHandlers.js:65-124`。

### 3.4 发送时的配置引用与历史快照语义

- **发送用缓存引用**：发送时直接读当前选中项缓存的 config，不每次回磁盘加载（`chatManager.js:1317`）；刷新这份缓存的时机只有三处：
  - 设置页保存成功后重新拉取配置并写回（`modules/settingsManager.js:469-489`）；
  - 加载话题列表时由 `updateCurrentItemConfig` 写回（`modules/topicListManager.js:458`）；
  - 历史达到 4 条触发摘要时强制重读，`attemptTopicSummarizationIfNeeded` 重读后写回配置（`chatManager.js:911-912,1132-1183`）。
- **重新生成总是重读最新配置**：重新生成前通过 `electronAPI.getAgentConfig` 重新读取 Agent 配置，模型与参数再经 `buildModelConfig` 组装；`handleRegenerateResponse` 负责截断历史、重新提取附件文本并重建消息（`modules/renderer/messageContextMenu.js:857,949`）。
- **消息不保存模型/参数元数据**：user 与 assistant 消息只带角色、名称、正文、时间戳、id 和附件这几项，`history.json` 由 `save-chat-history` 通道按原样写入（`chatManager.js:1020-1027,1395-1403`、`modules/ipc/chatHandlers.js:527-543`）；`__vcpchatTimestampMeta` 只附加在发往 VCP 的请求 payload 上，不落盘。
- **重新生成 = 截断重建（覆盖语义）**：重新生成时先截取原消息之前的历史前缀，再删除原消息及其后的全部消息，随后按新结果重建（`modules/renderer/messageContextMenu.js:884-887`）；分支以话题为单位，`handleCreateBranch` 会把前缀历史复制到新话题（`chatManager.js:1783-1853`）。本快照未找到续写入口和开场白（greeting）配置，创建话题时 `history.json` 初始化为空数组（`modules/ipc/chatHandlers.js:613`）。

### 3.5 模型可操作的提示词资产

PromptSponsor 的 direct 服务只接受白名单命令。读取命令可查看当前模式、有效提示词、积木和仓库；写命令可切换模式、改原始或预设提示词、增删移动积木、管理轮换内容与小仓。写操作按 requestId 做进程内幂等，并通过 AgentConfigManager 更新同一份角色配置；切换模式或修改当前模式内容时同步刷新 `systemPrompt`，所以普通发送仍消费统一字段。预设文件只接受 `.md` 与 `.txt`。`modules/services/pluginAgentOperationService.js:26-49,197-214,377-640`

## 4. Tavern Rules（Tavern 规则）

Tavern Rules 是**全局规则**，不写在 Agent config.json 中；通过 `window.TavernManager.getActiveRulesForScope('agent')` 获取当前作用于 agent 范围的规则列表。

已知三种规则类型：

| 类型 | 作用 |
| --- | --- |
| `system_suffix` | 追加内容到系统提示词末尾（`applyTavernSystemSuffix`） |
| `user_suffix` | 追加内容到用户消息末尾（`applyTavernUserSuffix`） |
| `context_inject` | 按深度在历史消息数组中插入内容（`applyTavernContextInject`） |

Tavern Rules 适用于全局性的格式约束或额外提示词片段，不需要修改每个 Agent 的 systemPrompt。

## 5. 头像

- 支持 PNG、JPG、GIF、WEBP 四种格式；
- 头像存为 `{userDataDir}/{agentId}/avatar.{ext}`，另按 `{agentName}{ext}` 复制一份到集中的 `AppData/avatarimage/` 目录，与群组头像共用该目录（`modules/ipc/agentHandlers.js:556-569`）；
- 通过 `save-avatar` IPC 事件单独保存，不写入 config.json；
- 另提取主色（`needsColorExtraction: true`）用于 UI 配色。

## 6. 外部能力边界

VCPChat 客户端侧的 Agent 配置**不直接控制工具调用能力**，工具能力由以下链路决定：

1. 系统提示词中的 `{{VarToolList}}` 等 VCP 占位符（由上游 VCPToolBox 服务器处理后替换）；
2. VCPToolBox/VCPDistributedServer 侧配置的插件和分布式节点；
3. 全局设置中的 VCP 连接配置（endpointURL、apiKey）。

Agent config.json 里没有工具开关或 MCP 服务器字段；能调用什么取决于 VCPToolBox 服务器上为该 Agent 暴露了哪些 VCP 工具。

## 7. 内置 Agent 示例

VCPChat 没有内置角色预设；Agent 完全由用户在 UI 中创建，或从 VCPToolBox 的 `Agent/` 目录描述的系统提示词手动粘贴而来。VCPToolBox 中的 Nova、Aemeath、Weiming 等内置 Agent 提示词（`.txt` 文件）可作为 VCPChat 的 Agent systemPrompt 来源，但需要在 VCPToolBox 服务器端正确配置宏变量后才能正常运行。

## 8. 群组（Group）

VCPChat 还支持多 Agent 群组对话（`Groupmodules/groupchat.js`），群组配置独立于单 Agent 的 config.json，包含成员列表和群组级别的对话规则；调查不在本篇范围内。

## 9. 导入与兼容性

- 没有批量导入接口；角色通过在 UI 中手动创建并填写提示词来建立；
- VCPToolBox 的 AgentAssistant 插件（`/admin_api/agent-assistant`）管理服务器侧 Agent；VCPChat 客户端 Agent 与 VCPToolBox AgentAssistant 的对应关系需手动维护；
- SillyTavern 角色卡的 `system_prompt` 字段可直接粘贴为 VCPChat Agent 的 `systemPrompt`。

## 10. 当前快照的角色边界

角色仍以本地 Agent/群组配置和 Tavern 规则共同定义，没有新增角色版本字段或渠道绑定模型。变化在于提示词资产获得受管的模型工具入口，单聊请求也由独立编排器统一读取这些角色字段；历史消息仍不保存角色配置快照。`modules/chat/chatContextPipeline.js:319-417`、`modules/services/pluginAgentOperationService.js:377-640`

## 11. 主要源码依据

- `VCPChat/modules/utils/agentConfigManager.js`：原子读写、锁文件机制、缓存策略、默认配置值。
- `VCPChat/modules/ipc/agentHandlers.js`：Agent CRUD IPC 处理、头像保存、目录结构初始化、字段定义。
- `VCPChat/modules/chatManager.js`：systemPrompt 宏替换（`{{AgentName}}`）、Tavern Rules 应用、模型参数传递、streamOutput 解析。
- `modules/chat/chatContextPipeline.js:319-417`：普通单聊的角色字段到最终请求消息的编译入口。
- `modules/services/pluginAgentOperationService.js:377-640`：PromptSponsor 对角色提示词资产的受管读写。

## 12. 调查边界

本篇关注 Agent 配置模型，未详细展开 VCP 协议分发链路、工具审批机制和 VCPDistributedServer 权限；参见 [VCPChat-Agent工具调查笔记.md](../Agent工具/VCPChat-Agent工具调查笔记.md)。
