# VCPToolBox Agent / 角色配置调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e2762e4dab5c70952d88f96689fba1270624e5ef`（分支：`main`）
>
> 调查方式：对比旧快照 `eca06251f5687a52fbcd353cb8b04f42157882d0` 至当前 HEAD 的 diff，核对关键文件（`Agent/`、`agent_map.json*`、`modules/agentManager.js`、`Plugin/AgentAssistant/`、`Plugin/AgentDream/`、`Plugin/VCPTaskAssistant/`、`Plugin/VCPTimeLine/`、`Plugin/OpenHerPersona/`、`TVStxt/`）；未修改被调查仓库源码
>
> 调查范围：VCPToolBox 的 Agent 角色系统——文件格式、变量体系、AgentAssistant 配置与运行时能力，及 TaskAssistant/AgentDream 的当前状态核对
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

VCPToolBox 是**服务器端的 VCP 中间层**，不是用户直接对话的客户端。它的"Agent"概念有两层：

1. **提示词文件层（Agent/ 目录）**：每个 `.txt` 文件是一段包含 VCP 变量占位符的系统提示词，用于在请求管线中替换变量后注入给模型。文件通过 `agent_map.json` 映射别名（**当前仓库只携带 `agent_map.json.example`，真实映射文件需用户创建**，见 2.1），使用 `{{agent:AlterName}}` 在其他提示词中嵌套引用。
2. **AgentAssistant 插件层**：`Plugin/AgentAssistant/` 插件为每个命名 Agent 定义身份、模型、温度、提示词等，实现具名身份的多 Agent 通信与任务派发。

这两层可以独立使用：提示词文件层服务于变量注入管线；AgentAssistant 层服务于多 Agent 场景（AI 调用 AI、任务调度）。

Agent 文件层、TaskAssistant 任务模型和 AgentDream 架构基本未变。AgentAssistant 的委托循环增加 Flowlock 协议：回复中的开始、完成、失败、停止和心跳指令由独立解析器提取，严格模式只有显式开始后才继续自主心跳，完成/失败/停止按固定优先级收口；未使用该标记的旧委托仍保留兼容循环。委托状态同时保存协议模式、下次心跳与最终报告预览（`Plugin/AgentAssistant/flowlockProtocol.js:148-182`、`AgentAssistant.js:1064-1154`）。OpenHerPersona 的状态观察和 VCPTavern 的预设占位符解析也有增量调整；AgentDream 仍处于**默认禁用**（`.block`）状态，其审批执行链确认由管理面板路由 `routes/admin/dream.js` 承担（插件内部导出的审批函数仅为未实现占位）。

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

`.gitignore` 明确排除 `Agent/` 目录内的用户自定义文件，表明内置示例只是样板，实际使用时用户应覆盖或新增。当前仓库根目录只有示例文件 `agent_map.json.example`，没有真正的 `agent_map.json`。映射文件缺失时，`AgentManager.loadMap()` 只加载空映射（`modules/agentManager.js:55`），任何别名都判断为不存在，agent 嵌套占位符保持原样不展开（`agentManager.js:322-324`）。即：**默认快照下 Agent 文件层未激活，需要用户创建 `agent_map.json` 才会生效**。AgentManager 还会递归扫描该目录（含 `.md` 文件与符号链接），该结果只用于管理面板的 Agent 文件浏览，不参与占位符展开判定。

### 2.2 变量体系

提示词文件内的占位符在发送请求前由 `messageProcessor.js` 的多阶段管线替换：

| 前缀 | 来源 | 说明 |
| --- | --- | --- |
| `{{VarXxx}}` | `config.env` 中 `VarXxx=...` | 服务器配置变量，静态注入 |
| `{{TarXxx}}` | 当前对话目标/用户信息 | 动态注入，如 `{{TarSysPrompt}}`（用户自定义系统提示）、`{{TarUser}}`（用户名）|
| `{{Sar Xxx}}` | 会话/历史相关 | 来自对话上下文 |
| `{{VCP…}}` | 静态插件占位符 | 触发对应插件注入（如 `{{VCPMemoToolBox}}`、`{{VCPSearchToolBox}}`） |
| `[[日记本名::Group::Time::…]]` | TagMemo 知识库 | 带参数语法，召回相关记忆条目 |
| `{{agent:AlterName}}` | `agent_map.json` | 嵌套引用另一个 Agent 文件内容（映射文件默认不随仓库提供，需用户创建） |
| `《《文件名::…》》` / `<<文件名>>` | TVStxt/ 目录 | 引入 TVStxt 文本块 |

**TVStxt 目录**存放可被变量引用的文本块，例如工具权限说明（`dreamtool.txt`）、日记写作指南（`Dailynote.txt`）等，由 `config.env` 中 `VarXxx=filename.txt` 形式的变量声明，运行时按需加载。

### 2.3 agent_map.json 与热重载

```json
{
  "Nova": "Nova.txt",
  "DreamNova": "DreamNova.txt",
  "Aemeath": "Aemeath.txt"
}
```

AgentManager 监视 `agent_map.json` 与 `Agent/` 目录的变更，检测到修改时自动清空提示词缓存，实现免重启热重载。

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

通过 Admin Panel 向 `/admin_api/agent-assistant` 发送 POST 请求保存配置，插件立即调用 `reloadConfig()` 更新内存中的 Agent 映射，无需重启服务器。

### 3.5 发送时配置引用与历史快照语义

- **发送不重读 config.json**：发送入口直接取内存中的 `AGENTS[agent_name]` 映射（`AgentAssistant.js:706-711`），配置文件只在初始化与重载时读取（:69、:1237），热重载会清空映射（:187）；已启动的委托持旧对象引用继续运行，相当于按引用的“快照”。管理面板保存配置后触发重载（`routes/admin/agentAssistant.js:29-63`），因此“下次消息用最新配置”是内存缓存语义，不是每次请求重读。
- **会话历史无配置快照**：`updateAgentSessionHistory`（:233-249）只追加 `{role, content}` 裸消息对（调用点 :898），不携带模型或参数元数据。每次请求按当前内存中的 Agent 配置现场拼装请求载荷 `payloadForVCP`（:870-876），字段包括模型 ID、消息数组、最大输出 token、温度与流式关闭标记。
- **无 regenerate API、无开场白**：AgentAssistant 没有重新生成端点（全仓检索仅 SkillBridge 模板文件有无关命中）；OneRing 的 `updateMessageById`（`OneRingDB.js:108-110`）只做重试/编辑场景的内容原地替换（改旧行），不是新建兄弟分支。配置 schema 与 `Agent/*.txt` 提示词也都没有开场白/初始消息字段——服务端没有会话创建钩子，聊天历史由外部前端持有。同样没有提示词块分组或组级开关；最接近的是 VCPTavern 预设 `preset.rules` 中的单条规则级开关（`VCPTavern.js:423-425`），但无组级抽象，预设整体经 `{{VCPTavern::预设名::SessionID}}` 占位符整包切换（:252-273）。
- **推理标签清理**：`removeVCPThinkingChain(text, modelName)` 先剥离 VCP 思维链标记，再按实际响应模型决定是否启用 `ReasoningToContent`。启用时一并剥离主总线写入正文的 `<think>`/`<thinking>` 标签块（含未闭合块），避免推理链污染会话历史与委托报告（`AgentAssistant.js:312-349`，调用点 :893、:1049）。

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

任务类型：`forum_patrol`（论坛巡航，自动加载帖子列表）和 `custom_prompt`（通用提示词）。调度模式支持四种取值：

- `interval`：固定间隔重复
- `cron`：按 cron 表达式定时
- `once`：单次执行
- `manual`：手动触发

**实现细节（`Plugin/VCPTaskAssistant/vcp-task-assistant.js`）**：

- 持久化：任务与历史存于插件目录内的 `task-center-data.json`（:10），`globalEnabled` 默认关闭（:30），历史上限默认 200 条（:12）。状态上报：`broadcastStatusUpdate()` 目前只输出日志（:49-51），前端靠管理 API 轮询 `getStatus`。
- 调度实现：固定间隔模式最小间隔被强制为 10 分钟（`MIN_INTERVAL_MINUTES`，:11、:563）；单次模式执行后自动禁用任务（:550-556）；固定间隔与 cron 任务的执行异常不影响下一轮调度（:573-578）。
- 派发链：`executeTask` → `wakeUpAgent` → 进程内调用 `agentAssistant.processToolCall(...)`（:229-257）——任务中心直接引用 AgentAssistant 模块，不再走 HTTP 回环；`injectTools` 已禁用（:230，注释说明 Agent 自身已有完整工具集）。
- 状态与结果：每次执行更新 `task.runtime`（最近运行时间、下次运行时间、最近错误与结果统计），并把执行记录追加进 `history`（:275-279）；结果只归属任务对象与历史记录，不落回会话。
- 取消语义：清理与删除接口只能停止或删除**未来调度**，无法取消正在执行的派发（`executeTask` 没有取消机制）；被派发 Agent 的委托循环上限仍由 AgentAssistant 的 `delegationMaxRounds` 控制。

## 5. AgentDream（梦系统）

`Plugin/AgentDream/` 为 Agent 提供独立的"梦境"空间，在非对话时段进行记忆回顾和整理：

1. **触发**：定时检查或手动命令。定时由 `_startDreamScheduler` 每 15 分钟检查一次，时间窗默认 1-6 点、概率掷骰默认 0.6、冷却与频率默认 8 小时；手动由 `processToolCall` 的 `triggerDream` 命令触发。入梦过程独立于正常对话上下文：先由 `DreamWaveEngine.generateDreamWave()` 做记忆涟漪浪潮联想（种子 + 关联碎片），再组装 `dreampost.txt` 提示词调用 VCP API 生成叙事。叙事与记忆树持久化为 `dream_logs/*.json`；
2. **记忆操作**：合并、删除、创造感悟三类操作（`DiaryMerge`、`DiaryDelete`、`DreamInsight`）支持串语法批量；每次调用会先**读取源日记全文**放进操作记录供管理员审阅；
3. **审批门控**：操作先只写入 `pending_review` 状态的 JSON 日志并广播 `AGENT_DREAM_OPERATIONS`，**实际审批执行在管理 API `routes/admin/dream.js` 完成**——`_processDreamOperation()` 对 approve 执行合并/删除/感悟，reject 只改状态；提供列表、详情、单条审批与批量审批端点。写新日记走 `DailyNoteWrite` 插件，删除源日记并同步向量库索引（`vectorDBManager.removeDocument()`）。**注意**：AgentDream 插件内部导出的 `approveDreamOperation`/`rejectDreamOperation` 只是未实现占位（`AgentDream.js:995-1001`），真正的执行权在管理面板路由；
4. **默认启用状态**：当前 HEAD 中 AgentDream 仍为 `plugin-manifest.json.block`（**默认禁用**），相关配置字段见 `config.env.example`；
5. **预算与取消**：**未找到**任何"预算"（token/次数上限）或"取消进行中梦境"的机制——调度器只在单次梦境进行中跳过下一轮触发（`_checkAndTriggerDreams` 的 in-progress 检查），梦上下文按 `contextTTLHours`（默认 4 小时）与 6 轮上限（12 条消息）裁剪；
6. **专属提示词文件**：`Agent/DreamNova.txt`（梦中的 Nova 角色身份，13 行小文件）。

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

## 8.1 角色相关插件的其他变化

- **TVStxt 内容更新**：`Dailynote.txt` 新增“感悟串联”写作规范（原子事件并联、感悟串联、Tag 拾取重排）与 `DailyNoteSearcher` 文本检索/BM25 用法；`MemoToolBox.txt` 把 LightMemo 更新为“浪潮 V10 语义”，新增时间范围过滤（如 `[2025-04-11~2025-05-12]`）、音乐检索、多索引支持与 RFF 重排触发等语法说明。这些是注入给模型的操作指南，不是新插件。
- **VCPTimeLine**：新增 `POST /vcp-timeline/agents/:agentName/files/:month/compact` 端点，用模型把当月 Timeline 正文精简（保留首行日期作者行与末尾 Tag 行，剥离代码围栏，返回后由前端确认再保存）——"精简"是模型生成的建议文本，不直接覆盖文件（`Plugin/VCPTimeLine/VCPTimeLine.js:558-595,794-802`）。
- **OpenHerPersona**：新增 `delete`/`delete_agent` 命令删除某 Agent 的情绪轴状态、锚点与审计记录（拒绝删除默认桶），并用 generation 计数使删除期间的排队观察任务失效，防止旧任务把误识别数据写回（`OpenHerPersona.js:2165-2205`）。Agent 身份识别改为只信任 system 消息中的 OneRing 标记，不再从请求配置对象递归匹配 `name`/`agent` 字段（:1976-1994）。

## 9. 主要源码依据

- `VCPToolBox/modules/agentManager.js`：`AgentManager` 类，别名映射加载、提示词缓存与热重载；映射文件缺失时占位符不展开。
- `VCPToolBox/docs/AGENT_AND_TASK_SYSTEM_GUIDE.md`：AgentAssistant `config.json` 完整结构与 TaskAssistant 任务对象 schema。
- `VCPToolBox/AgentDream.md`：梦系统架构、文件说明与生命周期。
- `VCPToolBox/AGENTS.md`：项目结构快速定位，`AgentManager` 符号映射。
- `VCPToolBox/Agent/*.txt`：各内置 Agent 实际提示词（Nova、Aemeath、Metis、Weiming、MemoMaster、Hornet、DreamNova、ThemeMaidCoco）。
- `VCPToolBox/TVStxt/`：可被变量引用的工具说明/规则文本块。
- `VCPToolBox/routes/admin/dream.js`：AgentDream 梦操作的实际审批执行链。
- `VCPToolBox/Plugin/VCPTaskAssistant/vcp-task-assistant.js`：任务派发中心的调度、派发与持久化实现。

## 10. 调查边界

本篇关注 Agent 角色配置模型，未详细展开 VCP 协议执行链路、审批响应机制和分布式节点信任边界；参见 [VCPToolBox-Agent工具调查笔记.md](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。`messageProcessor.js` 的多阶段变量替换管线细节属于工具侧调查范围。
