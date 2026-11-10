# VCPToolBox Agent / 角色配置调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：对照近期 diff 核对关键文件（`Agent/`、`agent_map.json*`、`modules/agentManager.js`、`Plugin/AgentAssistant/`、`Plugin/AgentDream/`、`Plugin/VCPTaskAssistant/`、`Plugin/VCPTimeLine/`、`Plugin/OpenHerPersona/`、`TVStxt/`）；未修改被调查仓库源码
>
> 调查范围：VCPToolBox 的 Agent 角色系统——文件格式、变量体系、AgentAssistant 配置与运行时能力，及 TaskAssistant/AgentDream 的当前状态核对
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

VCPToolBox 是**服务器端的 VCP 中间层**，不是用户直接对话的客户端。它的"Agent"概念有两层：

1. **提示词文件层（Agent/ 目录）**：每个 `.txt` 文件是一段包含 VCP 变量占位符的系统提示词，用于在请求管线中替换变量后注入给模型。文件通过 `agent_map.json` 映射别名（**当前仓库只携带 `agent_map.json.example`，真实映射文件需用户创建**，见 2.1），使用 `{{agent:AlterName}}` 在其他提示词中嵌套引用。
2. **AgentAssistant 插件层**：`Plugin/AgentAssistant/` 插件为每个命名 Agent 定义身份、模型、温度、提示词等，实现具名身份的多 Agent 通信与任务派发。

这两层可以独立使用：提示词文件层服务于变量注入管线；AgentAssistant 层服务于多 Agent 场景（AI 调用 AI、任务调度）。

Agent 文件层与 TaskAssistant 任务模型都沿用原有机制，内置提示词模板从 8 个增加到 10 个：新增的 Kerr 把元思考与多日记本 RiverMemo 的声明直接写进提示词，DeepSeekOfficial 是面向 DeepSeek 模型的编码助手人格；Nova 由 88 行精简到 46 行，ThemeMaidCoco 扩到 233 行。

AgentAssistant 的委托循环引入 Flowlock 协议：回复中的开始、完成、失败、停止与心跳指令由独立解析器提取，严格模式下只有收到显式开始才继续自主心跳，完成、失败与停止按固定优先级收口；未使用这些标记的旧委托走兼容循环。委托状态同时保存协议模式、下次心跳与最终报告预览，协议解析与状态拼装见 `Plugin/AgentAssistant/flowlockProtocol.js:148-182` 与 `AgentAssistant.js:1064-1154`。OpenHerPersona 的状态观察逻辑与 VCPTavern 的预设占位符解析也有调整。AgentDream 仍为默认禁用状态（清单标记 `.block`），梦操作的审批执行由管理面板路由 `routes/admin/dream.js` 承担，插件内部导出的审批函数是未实现占位。

## 2. 提示词文件层（Agent/ 目录）

### 2.1 文件格式

`Agent/` 目录下每个 `.txt` 文件是一个 Agent 的系统提示词模板，纯文本，可包含 VCP 占位符。文件名（去掉 `.txt` 后缀）即为 Agent 的默认标识符。

```
Agent/
  Nova.txt             # 主 Agent 提示词
  DreamNova.txt        # 梦境中的 Nova（由 AgentDream 调用）
  Aemeath.txt          # 高规格专家型 Agent
  Metis.txt            # 后台服务型知识管理 Agent
  Hornet.txt           # 服务/工具集成型 Agent
  Weiming.txt          # 知识/记忆型 Agent
  MemoMaster.txt       # 记忆管理专家
  ThemeMaidCoco.txt    # 场景装饰/界面风格 Agent
  Kerr.txt             # 元思考 + 多日记本协作的任务型 Agent
  DeepSeekOfficial.txt # 面向 DeepSeek 模型的官方适配人格（编码助手外壳）
```

仓库的 `.gitignore` 把 `Agent/` 目录里的用户自定义文件排除在外，内置示例只是样板，实际部署时由用户覆盖或新增。仓库根目录只有示例 `agent_map.json.example`，真正的映射文件要用户自己创建。映射文件缺失时，`AgentManager.loadMap()` 得到一张空映射，所有别名都被判为不存在，嵌套占位符保持原文不展开，默认快照下 Agent 文件层因此未激活，等用户创建 `agent_map.json` 之后才生效，加载与展开的判断见 `modules/agentManager.js:55,322-324`。AgentManager 另外会递归扫描该目录（含 `.md` 文件与符号链接），扫描结果只供管理面板浏览 Agent 文件，不参与占位符展开判定。

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
| Nova | 小（46行） | 面向用户的 AI 女仆，多模态（图片/音频/视频），记忆日记，工具全集 |
| Aemeath | 大（235行） | 世界最强AI助手定位，超高规格，创造力与深度兼顾 |
| Weiming | 大（328行） | 知识/记忆型，专注 TagMemo/日记/知识整理 |
| MemoMaster | 大（371行） | 记忆管理专家，TagMemo 系统的高阶操作 |
| Metis | 中（93行） | 后台服务型，知识架构师，非面向用户 |
| Hornet | 中（63行） | 工具/服务集成型，任务执行导向 |
| DreamNova | 小（13行） | 梦境版 Nova，由 AgentDream 系统在独立上下文中调用 |
| ThemeMaidCoco | 大（233行） | 界面/主题类，输出 CSS 和视觉风格调整，含 MediaRenderer 主题工作流 |
| Kerr | 大（382行） | 元思考 + RiverMemo 多日记本协作，面向 VCP 开发与论坛/家目录任务 |
| DeepSeekOfficial | 大（216行） | 面向 DeepSeek 模型的官方适配人格，编码助手外壳 |

所有内置 Agent 都在提示词中大量使用变量占位符（`{{VarXxx}}`、`[[日记本::…]]` 等），依赖 VCPToolBox 的完整运行时才能正常工作。

当前模板的配置方向如下。Nova 的三个主要日记声明使用 RiverMemo；Hornet 使用最近六篇加 BM25 的日记声明，并通过轻量工具折叠文档取得文件与系统工具；ThemeMaidCoco 包含文件、代码检索与 MediaRenderer 的主题制作工作流。这些仍是提示词层的能力声明，是否实际生效取决于映射文件、插件启用状态与部署路径（`Agent/Nova.txt:4-7`、`Agent/Hornet.txt:1,56-64`、`Agent/ThemeMaidCoco.txt:1-65`）。

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

- **发送时读内存映射**：发送入口按 Agent 名从内存中的 `AGENTS` 映射取配置，配置文件只在初始化和重载时读取，重载会先清空这份映射；已启动的委托继续持有旧对象引用运行，效果相当于按引用保存的快照。管理面板保存配置后触发重载，配置改动在下一条消息就生效，请求路径读的是这份内存缓存（`AgentAssistant.js:69,187,706-711,1237`、`routes/admin/agentAssistant.js:29-63`）。
- **会话历史只留消息对**：历史写入函数 `updateAgentSessionHistory` 每轮向会话追加一条只含角色与内容的裸消息对，调用点很集中，历史中不带模型或参数元数据。每次请求由 `payloadForVCP` 按当前内存配置现场拼出载荷，字段为模型 ID、消息数组、最大输出 token、温度与流式关闭标记（`AgentAssistant.js:233-249,870-876,898`）。
- **重新生成与开场白**：全仓检索没有找到重新生成端点，命中只见于 SkillBridge 的模板文件，与聊天链路无关。OneRing 的 `updateMessageById` 把内容原地替换回旧消息行，用于重试与编辑，不会新建兄弟分支（`OneRingDB.js:108-110`）。配置 schema 与 `Agent/*.txt` 提示词里同样没有开场白或初始消息字段，服务端也没有会话创建钩子，聊天历史由外部前端持有。提示词块只到单条规则粒度：VCPTavern 预设的 `preset.rules` 提供规则级开关，预设整体靠 `{{VCPTavern::预设名::SessionID}}` 占位符整包切换，没有组级抽象（`VCPTavern.js:252-273,423-425`）。
- **推理标签清理**：`removeVCPThinkingChain(text, modelName)` 先剥离 VCP 思维链标记，再按实际响应模型决定是否开启 `ReasoningToContent`。开启后它连主总线写进正文的 `<think>`/`<thinking>` 标签块（含未闭合块）一起剥掉，推理链因此不会混进会话历史与委托报告（`AgentAssistant.js:312-349,893,1049`）。

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

- 持久化：任务与执行历史都写在插件目录下的 `task-center-data.json` 里，全局开关 `globalEnabled` 默认关闭，历史上限为 200 条。状态上报函数 `broadcastStatusUpdate()` 目前只打日志，前端只能轮询管理 API 的 `getStatus` 取状态（:10,12,30,49-51）。
- 调度实现：固定间隔模式的最小间隔被强制为常量 `MIN_INTERVAL_MINUTES` 的 10 分钟，单次模式跑完会自动禁用该任务，固定间隔与 cron 任务即使执行抛错，后续轮次照常调度（:11,550-556,563,573-578）。
- 派发链：任务中心在 `executeTask` 里经 `wakeUpAgent` 以进程内调用的方式把任务交给 AgentAssistant 的工具调用入口 `processToolCall`，中间没有 HTTP 回环；`injectTools` 已停用，源码注释给出的理由是 Agent 自身已有完整工具集（:229-257）。
- 状态与结果：每次执行都会刷新任务的运行态，写入最近运行时间、下次运行时间、最近错误与结果统计，同时向 `history` 追加一条执行记录；这些结果只留在任务对象与历史里，不回写会话（:275-279）。
- 取消语义：清理与删除接口作用于**未来调度**，一次派发进入执行后没有取消入口，`executeTask` 内部也没有中断点；被派发 Agent 的委托循环上限仍由 AgentAssistant 的 `delegationMaxRounds` 控制。

## 5. AgentDream（梦系统）

`Plugin/AgentDream/` 为 Agent 提供独立的"梦境"空间，在非对话时段进行记忆回顾和整理：

1. **触发**：梦境由定时器或手动命令启动。定时器 `_startDreamScheduler` 按常量 `SCHEDULER_CHECK_INTERVAL_MS` 每 15 分钟轮询一次，命中条件为默认 1 点到 6 点的时间窗、0.6 的掷骰概率与 8 小时的冷却和频率；手动入口是 `processToolCall` 里的 `triggerDream` 命令。入梦在独立于正常对话的上下文中进行：`DreamWaveEngine.generateDreamWave()` 先做记忆涟漪式的浪潮联想，从种子扩散出关联碎片，再按 `dreampost.txt` 组装提示词调用 VCP API 生成叙事，叙事与记忆树写入 `dream_logs/*.json`（`AgentDream.js:755`）；
2. **记忆操作**：三类操作分别是合并日记的 `DiaryMerge`、删除日记的 `DiaryDelete` 与生成感悟的 `DreamInsight`，都支持串语法一次处理多条；每次调用先把源日记全文读进操作记录，方便管理员在审阅时对照；
3. **审批门控**：梦操作先以 `pending_review` 状态写进 JSON 日志，并广播 `AGENT_DREAM_OPERATIONS` 通知管理面板。真正的合并、删除与感悟执行落在管理 API：审批路由提供列表、详情、单条审批与批量审批端点，其中 `_processDreamOperation()` 对 approve 执行操作，reject 只改状态。新日记由 `DailyNoteWrite` 插件写入，删除源日记时同步清掉向量库索引（`vectorDBManager.removeDocument()`）。插件内部导出的 `approveDreamOperation` 与 `rejectDreamOperation` 是未实现的占位函数，执行权在管理面板路由 `routes/admin/dream.js`（`AgentDream.js:1082-1090`）；
4. **启用状态**：当前快照里 AgentDream 的清单项仍是 `plugin-manifest.json.block`，即默认禁用，相关配置字段见 `config.env.example`；
5. **预算与取消**：已读的调度与执行路径中没有 token 或次数上限，进行中的梦境也没有取消入口；调度器在 `_checkAndTriggerDreams` 里看到梦境仍在进行时就跳过下一轮触发，梦上下文按 `contextTTLHours`（默认 4 小时）与 6 轮、12 条消息的上限裁剪；
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

- **Agent 文件导入**：把提示词存成 `.txt` 放进 `Agent/` 目录，再到 `agent_map.json` 登记别名，导入即完成；
- **SillyTavern 角色卡**：取角色卡里的 `data.system_prompt` 存为 `.txt`，去掉 `<START>` 一类 SillyTavern 专属标记，其中的变量占位符还要按 VCP 语法另行适配；
- **AIO Hub 预设**：YAML 中的 `presetMessages` 要手工拼成一段完整文本，原来的 depth/anchor 注入策略需要按 VCP 的注入方式重新安排；
- **VCPChat 集成**：客户端向 VCPToolBox 索取提示词时拿到的是服务端已处理过的版本，`Agent/*.txt` 里的宏由服务器替换完成后才下发。

*未包含 VCPTavern 内置插件的调研；VCPTavern 主要实现了部分酒馆风格的深入注入能力*

## 8.1 角色相关插件的其他变化

- **TVStxt 内容更新**：`Dailynote.txt` 补入“感悟串联”写作规范（原子事件并联、感悟串联、Tag 拾取重排）和 `DailyNoteSearcher` 的文本检索、BM25 用法；`MemoToolBox.txt` 把 LightMemo 升级为“浪潮 V10 语义”，并补充下列语法说明（两份文件都是注入给模型的操作指南，能力由既有插件提供）：
  - 时间范围过滤，如 `[2025-04-11~2025-05-12]`
  - 音乐检索
  - 多索引支持
  - 触发 RFF 重排
- **VCPTimeLine**：新增按月压缩端点 `POST /vcp-timeline/agents/:agentName/files/:month/compact`，它让模型把当月 Timeline 正文精简一遍：保留首行的日期作者行与末尾的 Tag 行，剥掉代码围栏。返回结果只是模型给出的建议文本，需要前端确认后才写回文件（`Plugin/VCPTimeLine/VCPTimeLine.js:558-595,794-802`）。
- **OpenHerPersona**：新增 `delete` 与 `delete_agent` 命令，用于删除某个 Agent 的情绪轴状态、锚点与审计记录，默认桶不允许删除；删除期间靠 generation 计数让排队的观察任务失效，旧任务无法把误识别的数据写回。身份识别改为只认 system 消息里的 OneRing 标记，请求配置对象中递归匹配的 `name` 与 `agent` 字段不再参与判断（`OpenHerPersona.js:1976-1994,2165-2205`）。

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
