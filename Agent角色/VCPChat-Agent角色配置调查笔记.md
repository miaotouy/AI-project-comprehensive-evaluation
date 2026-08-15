# VCPChat Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fb66a52dd038a6fd147ee91cd1a39fe17555867e`（分支：`main`）
>
> 调查方式：基于当前 HEAD 的静态源码核对；只读核对 agentConfigManager、agentHandlers、chatManager、settingsManager，未修改被调查仓库源码
>
> 调查范围：Agent 配置结构、存储方式、能力字段与运行时行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 补充要点

- **模型参数可留空**：设置页折叠参数段的五个数值输入（`temperature/contextTokenLimit/maxOutputTokens/top_p/top_k`）留空时存为 `null`，回填空值、解析与保存见 `modules/settingsManager.js:181-185`、`:276-282`（`parseOptionalNumberInput`）、`:323-327`。发送前由 `omitUnsetOptionalModelParams` 从请求体删除（`modules/ipc/chatHandlers.js:94-118`、`:1064`）；折叠段未设置时显示“未设置”。
- **重新回复时附件文本重新提取**：`handleRegenerateResponse`（`modules/renderer/messageContextMenu.js:640`）在历史缓存了旧版固定 UTF-8 解码结果时，通过 `electronAPI.getTextContent` 从原始附件重新提取文本；`modules/fileManager.js:176-224` 的 `decodeTextBuffer` 提供 UTF-8/UTF-16 BOM、UTF-16 零字节启发式和 GB18030 兜底检测。

## 1. 结论摘要

VCPChat 的"角色"是**以文件夹为单位的 Agent**：每个 Agent 对应用户数据目录下一个以 `agentId` 命名的子目录，目录内的 `config.json` 存储所有配置字段，`regex_rules.json` 存储独立的正则处理规则，头像图片（支持 PNG/JPG/GIF/WEBP）也保存在同一目录。

配置字段不多但实用：系统提示词、模型选择、温度、上下文长度限制、输出长度限制、流式输出开关，以及用于管理多线对话的话题列表。不能在 Agent 内部配置工具调用策略——工具调用由 VCP 分布式服务器负责，配置在全局或后端。

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
- **modular（积木模式）**：`blocks` 是扁平数组，每块带独立 `disabled` 标志，组装时过滤禁用块（`Promptmodules/modular-prompt-module.js:60, 569, 1209`；主进程同逻辑见 `modules/ipc/promptHandlers.js:193-194`）。块内 `variants` 是多内容条目，配合 `selectedVariant` 单选（`modular-prompt-module.js:365-377, 130-131`）。支持块拖拽排序和小仓隐藏（hiddenBlocks/warehouse），但**没有组级总开关、没有单选/多选组**——块是平铺的，这也是全部调查项目中最接近 AIO Hub 消息组的机制；
- **preset**：从目录单选一个 `.md`/`.txt` 预设整段替换（`preset-prompt-module.js:269, 344`）。预设列表由 `load-preset-prompts` 扫描目录提供（`modules/ipc/promptHandlers.js:65-124`），默认目录为 `AppData/systemPromptPresets`。

### 3.4 发送时的配置引用与历史快照语义

- **发送用缓存引用**：`chatManager.js:1081` 发送时取 `currentSelectedItem.config`，不每次读磁盘；配置刷新点只有三处：
  - 设置页保存成功后重新拉取配置并写回（`modules/settingsManager.js:401-421`）；
  - 加载话题列表时（`updateCurrentItemConfig`，`modules/topicListManager.js:431`）；
  - 历史 ≥4 条触发摘要时强制重读（`attemptTopicSummarizationIfNeeded`，`chatManager.js:896-947`，`:911-912` 附近写回配置）。
- **重新生成总是重读最新配置**：`modules/renderer/messageContextMenu.js:687` 的 `getAgentConfig` 重新读取 Agent 配置，systemPrompt/模型/参数在 :888-969 组装（:961-968 为 model/temperature/max_tokens/top_p/top_k；`handleRegenerateResponse` 在 :640，含附件文本重新提取）。
- **消息不保存模型/参数元数据**：user/assistant 消息只含 `role/name/content/timestamp/id/attachments`（chatManager.js:1020-1027、:1395-1403，未变），history.json 原样写入（`save-chat-history`，`modules/ipc/chatHandlers.js:497-513`）；`__vcpchatTimestampMeta` 只附加在发往 VCP 的请求 payload，不落盘。
- **重新生成 = 截断重建（覆盖语义）**：`messageContextMenu.js:655-668` slice 保留到原消息的前缀、splice 删除原消息及其后全部消息再重建；分支是 topic 级（`chatManager.js:1511-1580` 的 `handleCreateBranch` 复制前缀历史到新话题）。本快照未找到续写入口和开场白/greeting 配置（创建 topic 时 history.json 初始化为空数组，`modules/ipc/chatHandlers.js:583`）。

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

- 支持格式：PNG、JPG、GIF、WEBP；
- 存储位置：`{userDataDir}/{agentId}/avatar.{ext}`；另会按 `{agentName}{ext}` 复制一份到集中的 `AppData/avatarimage/` 目录（`modules/ipc/agentHandlers.js:382-395`，与群组头像共用该目录）；
- 单独通过 `save-avatar` IPC 事件保存，不写入 config.json；
- 提取主色（`needsColorExtraction: true`）用于 UI 配色。

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

## 10. 主要源码依据

- `VCPChat/modules/utils/agentConfigManager.js`：原子读写、锁文件机制、缓存策略、默认配置值。
- `VCPChat/modules/ipc/agentHandlers.js`：Agent CRUD IPC 处理、头像保存、目录结构初始化、字段定义。
- `VCPChat/modules/chatManager.js`：systemPrompt 宏替换（`{{AgentName}}`）、Tavern Rules 应用、模型参数传递、streamOutput 解析。

## 11. 调查边界

本篇关注 Agent 配置模型，未详细展开 VCP 协议分发链路、工具审批机制和 VCPDistributedServer 权限；参见 [VCPChat-Agent工具调查笔记.md](../Agent工具/VCPChat-Agent工具调查笔记.md)。
