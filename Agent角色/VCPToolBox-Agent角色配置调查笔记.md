# VCPToolBox Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-05
>
> 代码快照：`eca06251f5687a52fbcd353cb8b04f42157882d0`（分支：`main`）
>
> 调查方式：只读核对 Agent/ 目录、agentManager.js、AGENT_AND_TASK_SYSTEM_GUIDE.md、AgentDream.md、docs/ 文档；未修改被调查仓库源码
>
> 调查范围：VCPToolBox 的 Agent 角色系统——文件格式、变量体系、AgentAssistant 配置与运行时能力
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

VCPToolBox 是**服务器端的 VCP 中间层**，不是用户直接对话的客户端。它的"Agent"概念有两层：

1. **提示词文件层（Agent/ 目录）**：每个 `.txt` 文件是一段包含 VCP 变量占位符的系统提示词，用于在请求管线中替换变量后注入给模型。文件通过 `agent_map.json` 映射别名，使用 `{{agent:AlterName}}` 在其他提示词中嵌套引用。
2. **AgentAssistant 插件层**：`Plugin/AgentAssistant/` 插件为每个命名 Agent 定义身份、模型、温度、提示词等，实现具名身份的多 Agent 通信与任务派发。

这两层可以独立使用：提示词文件层服务于变量注入管线；AgentAssistant 层服务于多 Agent 场景（AI 调用 AI、任务调度）。

## 2. 提示词文件层（Agent/ 目录）

### 2.1 文件格式

`Agent/` 目录下每个 `.txt` 文件是一个 Agent 的系统提示词模板，纯文本，可包含 VCP 占位符。文件名（去掉 `.txt` 后缀）即为 Agent 的默认标识符。

```
Agent/
  Nova.txt          # 主 Agent 提示词
  DreamNova.txt     # 梦境中的 Nova（由 AgentDream 调用）
  Aemeath.txt       # 高规格专家型 Agent
  Metis.txt         # 后台服务型知识管理 Agent
  Hornet.txt        # 服务/工具集成型 Agent
  Weiming.txt       # 知识/记忆型 Agent
  MemoMaster.txt    # 记忆管理专家
  ThemeMaidCoco.txt # 场景装饰/界面风格 Agent
```

`.gitignore` 明确排除 `Agent/` 目录内的用户自定义文件，表明内置示例是样板，实际使用时用户应覆盖或新增。

### 2.2 变量体系

提示词文件内的占位符在发送请求前由 `messageProcessor.js` 的多阶段管线替换：

| 前缀 | 来源 | 说明 |
| --- | --- | --- |
| `{{VarXxx}}` | `config.env` 中 `VarXxx=...` | 服务器配置变量，静态注入 |
| `{{TarXxx}}` | 当前对话目标/用户信息 | 动态注入，如 `{{TarSysPrompt}}`（用户自定义系统提示）、`{{TarUser}}`（用户名）|
| `{{Sar Xxx}}` | 会话/历史相关 | 来自对话上下文 |
| `{{VCP…}}` | 静态插件占位符 | 触发对应插件注入（如 `{{VCPMemoToolBox}}`、`{{VCPSearchToolBox}}`） |
| `[[日记本名::Group::Time::…]]` | TagMemo 知识库 | 带参数语法，召回相关记忆条目 |
| `{{agent:AlterName}}` | `agent_map.json` | 嵌套引用另一个 Agent 文件内容 |
| `《《文件名::…》》` / `<<文件名>>` | TVStxt/ 目录 | 引入 TVStxt 文本块 |

**TVStxt/ 目录**（`TVStxt/`）存放可被变量引用的文本块，例如工具权限说明（`dreamtool.txt`）、渲染规则（`DIVRendering.txt`）、日记写作指南（`Dailynote.txt`）等，由 `config.env` 中 `VarXxx=filename.txt` 声明，运行时按需加载。

### 2.3 agent_map.json 与热重载

```json
{
  "Nova": "Nova.txt",
  "DreamNova": "DreamNova.txt",
  "Aemeath": "Aemeath.txt"
}
```

`AgentManager` 监视 `agent_map.json` 和 `Agent/` 目录的变更（`chokidar`），检测到修改时自动清空提示词缓存，实现热重载，无需重启服务器。

### 2.4 典型 Agent 方向画像

根据 `Agent/` 目录中的实际文件：

| Agent | 规模 | 偏好方向 |
| --- | --- | --- |
| Nova | 中（88行） | 面向用户的 AI 女仆，多模态（图片/音频/视频），记忆日记，工具全集 |
| Aemeath | 大（234行） | 世界最强AI助手定位，超高规格，创造力与深度兼顾 |
| Weiming | 大（238行） | 知识/记忆型，专注 TagMemo/日记/知识整理 |
| MemoMaster | 大（370行） | 记忆管理专家，TagMemo 系统的高阶操作 |
| Metis | 中（92行） | 后台服务型，知识架构师，非面向用户 |
| Hornet | 中（68行） | 工具/服务集成型，任务执行导向 |
| DreamNova | 小（13行） | 梦境版 Nova，由 AgentDream 系统在独立上下文中调用 |
| ThemeMaidCoco | 中（38行） | 界面/主题类，输出 CSS 和视觉风格调整 |

所有内置 Agent 都在提示词中大量使用变量占位符（`{{VarXxx}}`、`[[日记本::…]]` 等），依赖 VCPToolBox 的完整运行时才能正常工作。

## 3. AgentAssistant 插件层

`Plugin/AgentAssistant/` 实现多 Agent 身份管理，每个 Agent 由配置文件中的一个对象定义：

### 3.1 AgentAssistant config.json 结构

```json
{
  "maxHistoryRounds": 7,
  "contextTtlHours": 24,
  "globalSystemPrompt": "",
  "delegationMaxRounds": 15,
  "delegationTimeout": 300000,
  "delegationSystemPrompt": "...",
  "delegationHeartbeatPrompt": "...",
  "agents": [
    {
      "baseName": "NOVA",
      "chineseName": "诺娃",
      "modelId": "gemini-2.0-flash",
      "description": "性格/能力综述",
      "systemPrompt": "完整系统提示词...",
      "maxOutputTokens": 40000,
      "temperature": 0.7
    }
  ]
}
```

### 3.2 Agent 对象字段

| 字段 | 说明 |
| --- | --- |
| `baseName` | 内部标识符（对应旧版 `AGENT_XXX` 前缀），全大写惯例 |
| `chineseName` | 工具调用中的触发名称及 UI 显示名，中文 |
| `modelId` | 绑定的后端模型 ID（独立于全局模型） |
| `description` | 供其他 Agent 了解其能力的简介（用于 AI 委托决策） |
| `systemPrompt` | 核心系统提示词（决定性格与行为） |
| `maxOutputTokens` | 单次最大输出 token 数 |
| `temperature` | 温度（0.0–2.0） |

### 3.3 全局参数

| 字段 | 说明 |
| --- | --- |
| `maxHistoryRounds` | 全局对话历史记忆轮数 |
| `contextTtlHours` | 上下文存活时间（超时后清除历史） |
| `globalSystemPrompt` | 追加到所有 Agent 提示词末尾的全局补充 |
| `delegationMaxRounds` | 异步委托模式最大循环轮数 |
| `delegationTimeout` | 异步委托任务超时时间（毫秒） |
| `delegationSystemPrompt` | 委托任务的初始系统提示词 |
| `delegationHeartbeatPrompt` | 委托超时时的心跳催促提示词 |

### 3.4 热重载

通过 Admin Panel 向 `/admin_api/agent-assistant` 发送 POST 请求保存配置，插件立即调用 `reloadConfig()` 更新内存中的 `AGENTS` 映射，无需重启服务器。

## 4. TaskAssistant 任务派发系统

`Plugin/AgentDream` 相关的还有 **TaskAssistant（FA）**，用于将定时/手动任务派发给 AgentAssistant 中定义的 Agent：

### 4.1 任务对象（Task）

```json
{
  "id": "fa_12345",
  "name": "每日早处理",
  "type": "forum_patrol",
  "enabled": true,
  "schedule": {
    "mode": "interval",
    "intervalMinutes": 60,
    "cronValue": "0 8 * * *",
    "runAt": "ISO Timestamp"
  },
  "targets": {
    "agents": ["可可", "诺娃"]
  },
  "dispatch": {
    "injectTools": ["VCPForum"],
    "maid": "VCP系统",
    "temporaryContact": true,
    "channel": "AgentAssistant"
  },
  "payload": {
    "promptTemplate": "任务提示词...",
    "includeForumPostList": true
  }
}
```

任务类型：`forum_patrol`（论坛巡航，自动加载帖子列表）和 `custom_prompt`（通用提示词）。调度模式：`interval`、`cron`、`once`、`manual`。

## 5. AgentDream（梦系统）

`Plugin/AgentDream/` 为 Agent 提供独立的"梦境"空间，在非对话时段进行记忆回顾和整理：

1. **触发**：定时或手动，独立于正常对话上下文；
2. **记忆采集**：从个人/公共知识库随机抽取种子，通过 TagMemo 语义检索关联碎片；
3. **叙事生成**：AI 以意识流方式生成梦境内容；
4. **记忆操作**：`DiaryMerge`（合并）、`DiaryDelete`（删除）、`DreamInsight`（创造感悟）；
5. **审批门控**：所有操作仅生成 JSON 索引，需管理员在 Admin Panel 审批后才执行；
6. **专属提示词文件**：`Agent/DreamNova.txt`（梦中的 Nova 角色身份）。

## 6. 配置方式对比

| 配置方式 | 适用场景 | 存储位置 |
| --- | --- | --- |
| `Agent/*.txt` + `agent_map.json` | 变量注入管线，`{{agent:Name}}` 嵌套引用 | 文件系统 |
| AgentAssistant `config.json` | 多 Agent 通信，AI 委托 AI | Admin Panel 管理，内存热重载 |
| TaskAssistant 任务配置 | 定时/手动任务派发给 Agent | Admin Panel 管理 |
| `config.env` 中的 `VarXxx` | 静态环境变量，注入所有提示词 | 环境配置文件 |

## 7. 提示词与能力边界

VCPToolBox Agent 提示词不像 AIO Hub 那样有显式的工具开关字段——能调用哪些工具由以下决定：

1. 提示词中包含的 `{{VCP…}}` 静态占位符（由对应插件注入工具定义）；
2. 占位符引用的 TVStxt 工具权限文件（如 `{{VarDreamTool}}` 引用的 `dreamtool.txt`）；
3. AgentAssistant 的 `dispatch.injectTools` 字段（任务派发时动态注入）；
4. 全局插件注册表中已激活的插件。

可以通过不在提示词中包含某个工具的占位符，有效限制 Agent 的工具可见性，但这是约定俗成的限制，不是硬件层面的沙箱隔离。

## 8. 导入与兼容性

- **Agent 文件导入**：把提示词粘贴为 `.txt` 文件放入 `Agent/` 目录，在 `agent_map.json` 注册别名即完成；
- **SillyTavern 角色卡**：将 `data.system_prompt` 内容放入 `.txt` 文件，移除 SillyTavern 专属格式标记（`<START>` 等）；VCP 变量占位符需要另外适配；
- **AIO Hub 预设**：YAML 的 `presetMessages` 需手工拼接为单一文本，注入策略（depth/anchor）无法直接复用；
- **VCPChat 集成**：VCPChat 客户端从 VCPToolBox 服务器获取已处理的提示词，`Agent/*.txt` 中的宏由 VCPToolBox 在服务器端替换后再下发给客户端。

*此处未包含VCPTavern内置插件的调研，简单来说VCPTavern主要实现了部分酒馆风格的深入注入能力*

## 9. 主要源码依据

- `VCPToolBox/modules/agentManager.js`：`AgentManager` 类，别名映射加载、提示词缓存与热重载。
- `VCPToolBox/docs/AGENT_AND_TASK_SYSTEM_GUIDE.md`：AgentAssistant `config.json` 完整结构与 TaskAssistant 任务对象 schema。
- `VCPToolBox/AgentDream.md`：梦系统架构、文件说明与生命周期。
- `VCPToolBox/AGENTS.md`：项目结构快速定位，`AgentManager` 符号映射。
- `VCPToolBox/Agent/*.txt`：各内置 Agent 实际提示词（Nova、Aemeath、Metis、Weiming、MemoMaster、Hornet、DreamNova、ThemeMaidCoco）。
- `VCPToolBox/TVStxt/`：可被变量引用的工具说明/规则文本块。

## 10. 调查边界

本篇关注 Agent 角色配置模型，未详细展开 VCP 协议执行链路、审批响应机制和分布式节点信任边界；参见 [VCPToolBox-Agent工具调查笔记.md](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。`messageProcessor.js` 的多阶段变量替换管线细节属于工具侧调查范围。
