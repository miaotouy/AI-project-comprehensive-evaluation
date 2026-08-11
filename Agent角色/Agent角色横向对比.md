# Agent 角色配置横向调查与对比

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、SillyTavern、VCPChat、VCPToolBox、Hermes Agent
>
> 对比更新日期：2026-08-11
>
> 依据：同目录十六份单项目调查笔记及其中记录的代码快照
>
> 对比方法：统一比较角色实体、存储粒度、会话绑定、提示词装配、模型参数、工具授权、知识与记忆、导入格式和历史快照；只采用单项目笔记中已有的源码结论
>
> 对比范围：Agent、Assistant、Persona、Mask、Character Card、自定义模型及与角色最接近的全局提示词配置；不重复展开工具执行安全、Provider 渠道管理和消息渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 单项目笔记

| 项目 | 笔记 | 行数 | 分支 | 代码快照 |
| --- | --- | ---: | --- | --- |
| AIO Hub | [AIO-Hub-Agent角色配置调查笔记.md](AIO-Hub-Agent角色配置调查笔记.md) | 427 | `main` | `eba9d84b234672321312e92ab48bb474cfb0aca4` |
| AstrBot | [AstrBot-Agent角色配置调查笔记.md](AstrBot-Agent角色配置调查笔记.md) | 329 | `master` | `346b85db9d79207ea7b51694cce5276203612af4` |
| Chatbox | [Chatbox-Agent角色配置调查笔记.md](Chatbox-Agent角色配置调查笔记.md) | 200 | `main` | `7450ab2dde5eacab4a8721f8680006ba8b99438d` |
| Cherry Studio | [Cherry-Studio-Agent角色配置调查笔记.md](Cherry-Studio-Agent角色配置调查笔记.md) | 190 | `main` | `b7673c23860db5dd6da7f42dec5fc21f6b13de1a` |
| DeepChat | [DeepChat-Agent角色配置调查笔记.md](DeepChat-Agent角色配置调查笔记.md) | 157 | `dev` | `dc4177c2ac80905ebac985554a9f957aaca31ab8` |
| Jan | [Jan-Agent角色配置调查笔记.md](Jan-Agent角色配置调查笔记.md) | 148 | `main` | `fad3f12a147d138388a66f0d92a02b2675f65294` |
| LobeHub | [LobeHub-Agent角色配置调查笔记.md](LobeHub-Agent角色配置调查笔记.md) | 225 | `canary` | `4edba1b75a97b91c28ad48cd1cc90528defa17ad` |
| Manifold Desktop | [Manifold-Desktop-Agent角色配置调查笔记.md](Manifold-Desktop-Agent角色配置调查笔记.md) | 68 | `main` | `3d7448fb2e6053056da6d6c126e08f90b94cda4f` |
| NextChat | [NextChat-Agent角色配置调查笔记.md](NextChat-Agent角色配置调查笔记.md) | 168 | `main` | `706a18b95b714ab29b2a4842d3b9ff4f887935d5` |
| Open WebUI | [Open-WebUI-Agent角色配置调查笔记.md](Open-WebUI-Agent角色配置调查笔记.md) | 185 | `main` | `01f4282f1ffe0d6212f58d3afbeae21fffd0c4be` |
| OpenCode | [OpenCode-Agent角色配置调查笔记.md](OpenCode-Agent角色配置调查笔记.md) | 191 | `dev` | `b8bd88901a4870ef3a5752840f4e23e11d54e24e` |
| Pi | [Pi-Agent角色配置调查笔记.md](Pi-Agent角色配置调查笔记.md) | 113 | `main` | `6b461b75b39b5a19b378dc42fbfbd1655bc446a6` |
| SillyTavern | [SillyTavern-Agent角色配置调查笔记.md](SillyTavern-Agent角色配置调查笔记.md) | 206 | `release` | `8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8` |
| VCPChat | [VCPChat-Agent角色配置调查笔记.md](VCPChat-Agent角色配置调查笔记.md) | 150 | `main` | `3f14e938e700a5487ca13c4a6d8a6caad8e70ac9` |
| VCPToolBox | [VCPToolBox-Agent角色配置调查笔记.md](VCPToolBox-Agent角色配置调查笔记.md) | 239 | `main` | `eca06251f5687a52fbcd353cb8b04f42157882d0` |
| Hermes Agent | [Hermes-Agent-Agent角色配置调查笔记.md](Hermes-Agent-Agent角色配置调查笔记.md) | 203 | `main` | `01a1037d1e6d7b6eb96a786ef282c3aea4818194` |

## 比较口径

本文比较的是“哪一层拥有配置，以及运行时怎样消费配置”，不按字段数量给项目排名。十六个项目中，“角色”至少有九种不同含义：可执行 Agent、助手配置、人格模板、角色卡、自定义模型、全局 system prompt、文件约定的提示词资源、编码 Agent 的配置对象，以及 Hermes 的分层提示词机制。只有先确定载体，模型绑定、工具权限和历史快照才有可比性。

矩阵使用以下表述：

| 表述 | 含义 |
| --- | --- |
| 有 / 无 | 单项目笔记已用类型或执行路径确认存在或不存在 |
| 未提供 | 已读角色数据模型中没有该字段，但能力可能位于全局、会话或其他模块 |
| 未调查 | 单项目笔记没有覆盖该主题，不能据此判断项目是否支持 |
| 未确认 | 已找到相关字段或入口，但静态证据不足以确认最终运行时语义 |

“角色支持工具”只表示角色配置能够收窄、绑定或触发工具来源，不表示工具一定可执行，也不表示有审批或沙箱。工具发现、审批和执行边界以 [Agent工具横向对比.md](../Agent工具/Agent工具横向对比.md) 为准。

## 结论摘要

十六个项目没有一个共同的“Agent 角色”抽象，主要差异在配置所有权和会话继承方式。

1. **配置聚合型 Agent：AIO Hub、Cherry Studio、LobeHub、DeepChat。** 角色同时拥有提示词、模型或模型引用、生成参数和外部能力。AIO Hub 还把可分组切换的消息树、资产、世界书、会话变量和工具审批放进同一实例；消息组支持多选、单选和组级开关，并在聊天侧边栏直接呈现。LobeHub 把长期记忆、图编排和插件模式纳入 Agent；DeepChat 把项目目录、权限、MCP、Skills、subagent slot 和 memory policy 放进 descriptor；Cherry Studio 的范围相对收敛，以模型、单段 prompt、MCP 和知识库关联为主。
2. **模板与会话分层：Chatbox、AstrBot。** Chatbox 的 Copilot 只拥有人格元数据，模型、Skills、Agent Mode 和 RAG 位于 Session；创建会话时 prompt 被写入历史，形成静态快照。AstrBot Persona 拥有提示词与工具/Skills 白名单，但模型不属于 Persona；运行时按会话规则、对话绑定和全局默认逐轮解析。
3. **会话副本型：Jan、NextChat。** Jan 把 Assistant 的 name/model/instructions/tools 复制进 thread；NextChat 把完整 Mask 复制进 session，fork 时再深拷贝。两者都使历史会话脱离模板的后续修改，但 NextChat 还保留全局模型配置同步开关。
4. **模型即角色：Open WebUI。** Workspace Model 同时是上游模型别名、system prompt、参数包、知识和工具绑定、访问控制对象。请求按 model id 重新读数据库，角色生命周期直接复用模型目录和权限体系。
5. **可移植内容型：SillyTavern。** Character Card 的边界是人格、场景、示例对话、开场白、世界书和扩展字段；模型与生成 Preset 分离。它在当前十六个项目中拥有最明确的社区角色卡格式和很细的提示词语义分区，但角色卡本身不承担模型和工具权限，实际配置还分散在角色卡、推理 Preset、Prompt Manager、Advanced Formatting、World Info 与扩展层。
6. **文件/服务编排型：VCPChat、VCPToolBox。** VCPChat 每个 Agent 一个目录，模型和基础参数随 Agent 保存，工具策略留给 VCP 服务端。VCPToolBox 同时存在提示词文件和 AgentAssistant 配置两层，前者参与变量替换，后者承担具名多 Agent 通信和任务派发。
7. **无角色实体：Manifold Desktop。** 只有全局 system prompt、温度、Provider/模型和文本提示词库；会话不保存发送时配置。因此它应作为“全局配置基线”比较，不能记成一个功能较少的 Agent 实现。
8. **分层提示词 + 独立 Profile（Hermes Agent）。** 身份文件（SOUL.md）、命名人格模板（personalities）、全局/会话 system 提示词（agent.system_prompt）与运行时注入（ephemeral）四级叠加成 system prompt；任何一层都不绑定模型或工具。角色隔离放在 Profile（独立的 HERMES_HOME 目录）这一完整容器上。修改角色只影响下一次构建或由 TUI 就地改 ephemeral，不重写既有缓存前缀。
9. **无角色实体、文件约定型：Pi。** 角色能力由 `SYSTEM.md`（整篇替换默认提示词）、`APPEND_SYSTEM.md`（追加）、`AGENTS.md/CLAUDE.md` 祖先链（`<project_context>` 块）与 skills 文件组合，全部按会话 cwd 在启动时解析；模型/思考等级是会话级状态，默认值来自全局+项目设置。没有任何角色对象、角色 UI 或角色导入导出，system prompt 本体不随会话条目保存。
10. **配置对象 + 内置 agent 模板：OpenCode。** Agent 是由配置构建的只读内存对象（`src/agent/agent.ts:35-56`），来源为 `opencode.json` 的 `agent` 字段与 `{agent,agents}/**/*.md`（带 frontmatter，mode 文件强制 primary）；持久化的只是 session 表上的 agent 名字引用，会话消息另存 agent/model 快照。角色同时拥有 prompt（缺省回退 provider 风格提示）、model/variant/temperature/top_p、permission 规则与 steps 上限；内置 build/plan（primary）、general/explore（subagent）、compaction/title/summary（hidden）。修改角色配置后，新会话用新配置，既有会话的消息仍显示当时的 agent/model 快照，但继续生成使用当前配置解析的 agent 与权限。

最关键的横向差异不是“能否填写 system prompt”，而是**修改角色后，既有会话下一轮使用新配置、旧快照，还是由全局设置覆盖**。这三种语义分别出现在 Open WebUI/AstrBot 一类的运行时解析、Chatbox/Jan/NextChat 的快照或副本，以及 Manifold Desktop 的全局当前值中。Hermes Agent 介于后两者之间：人格配置是全局当前值，但会话会记录构建好的 system prompt（hash 去重）与模型快照，而运行时注入的人格文本不随轨迹保存。

若单独比较**预设可配置范围与日常编辑体验**，结论会与“社区生态成熟度”不同：AIO Hub 是当前样本中最强的一体化候选。它把消息角色、顺序、锚点/深度、模型匹配、消息组、宏、变量、知识库占位符、资产附件、模型参数和工具策略放在同一个 Agent 编辑流程里；其中消息组可设多选或单选，并有组级总开关和侧边栏快速切换。SillyTavern 的优势仍是角色卡标准、社区资产和 World Info 生态，但 Prompt Manager 中的 marker、system prompt、override、relative/in-chat injection、order、trigger 等字段与角色卡和采样 Preset 分层存在，能力多不等于配置关系更容易理解。

## 架构分型

| 分型 | 项目 | 角色载体 | 主要所有权边界 |
| --- | --- | --- | --- |
| 配置聚合 | AIO Hub | `ChatAgent` / `AgentPreset` | Agent 拥有消息树、模型引用、参数、工具、知识和资产 |
| 配置聚合 | Cherry Studio | `Assistant` | Assistant 拥有模型、prompt、参数、MCP/知识库引用 |
| 配置聚合 | LobeHub | `LobeAgentConfig` | Agent 拥有人格、模型、chatConfig、插件、知识、文件和记忆策略 |
| 配置聚合 | DeepChat | Agent descriptor + session policy | descriptor 拥有运行时配置，session 保存 agent id 和覆盖项 |
| 人格模板 | AstrBot | `Persona` | Persona 拥有指令、开场对话和能力白名单，Provider/模型在外层 |
| 人格模板 | Chatbox | `CopilotDetail` | Copilot 只拥有人格；模型和工具能力归 Session |
| 线程快照 | Jan | `Assistant` + `ThreadAssistantInfo` | Assistant 是模板，thread 内嵌使用时快照 |
| 会话副本 | NextChat | `Mask` + `ChatSession.mask` | Mask 是模板，新会话复制完整配置 |
| 模型预设 | Open WebUI | Workspace `Model` | 自定义模型同时承担 persona、参数、能力和权限 |
| 角色卡 | SillyTavern | Character Card | 卡片拥有可移植角色内容，运行参数归应用 Preset |
| Agent 目录 | VCPChat | `{agentId}/config.json` | Agent 拥有 prompt、模型、参数和 topic 列表，工具归服务端 |
| 服务端双层 | VCPToolBox | `Agent/*.txt` + AgentAssistant | 文本层负责变量注入，插件层负责多 Agent 身份和委托 |
| 全局设置 | Manifold Desktop | `AppSettings.systemPrompt` | 没有角色或会话级配置对象 |
| 全局提示词 + Profile 容器 | Hermes Agent | `SOUL.md` + `agent.personalities` + `agent.system_prompt`（ephemeral） | 角色本身只是提示词层；模型、工具、记忆和参数归全局/渠道/Profile 配置 |
| 文件约定 | Pi | `SYSTEM.md` + `APPEND_SYSTEM.md` + `AGENTS.md` 链 + skills | 提示词是 cwd 解析的文本资源；模型/参数归会话与设置 |
| 配置对象 + 内置模板 | OpenCode | `Agent.Info`（配置构建的内存对象）+ `{agent,agents}/**/*.md` | Agent 拥有 prompt、model/variant/参数、permission 与 steps；会话只存名字引用 |

## 实体、存储与会话绑定

| 项目 | 稳定实体与标识 | 持久化粒度 | 会话如何选择角色 | 历史快照语义 |
| --- | --- | --- | --- | --- |
| AIO Hub | `ChatAgent.id`；预设与实例分离 | 每 Agent 一个 `agent.json` + 索引 + 资产目录；会话另存消息树 | 会话索引保存 `displayAgentId`；每次发送、续写、重新生成按 Agent ID 读取当前配置 | **实时引用 + 局部快照**：开场白在首次发送后固化为消息；旧回复保留，生成节点保存 Agent/模型/请求参数元数据；完整 Agent 配置不随会话冻结 |
| AstrBot | `Persona.persona_id`，显示名即 ID | SQLite `personas` 行 + v3 运行时缓存 | 会话规则强制值 > 对话 `persona_id` > Provider 默认 > webchat 特例 | 每轮重新解析 Persona；`begin_dialogs` 每轮重注入且 `_no_save`；消息对象不保存 persona_id/模型名，当次实际模型记录在 trace 日志与 `provider_stat` 表；切换后旧历史行为未实测 |
| Chatbox | `CopilotDetail.id` | 本地 Copilot 集合；Session 单独保存消息与设置 | Session 保存 `copilotId`，创建时把 prompt 写成首条 system 消息 | **静态快照**：修改 Copilot 不更新既有 Session 的 system 消息；每条消息另存 provider 与模型显示名（无温度等参数快照）；regenerate 在 fork 分支新建消息，保留旧回复 |
| Cherry Studio | `Assistant.id` UUID | SQLite `assistant` 行 + MCP/知识库中间表；topic 存 `assistantId` 引用 | topic 保存 `assistantId`；每次请求按 id 重读 Assistant（`assistantDataService.getById`） | **实时引用 + 消息快照**：消息存 `modelId` 与 `messageSnapshot`（作者身份+模型快照）；重新生成在原用户消息下新建 assistant 兄弟分支（`siblingsGroupId`），旧回复保留 |
| DeepChat | descriptor id；内置 `deepchat` 受保护 | Agent row 内 JSON config；session row 单独存 `generationSettings` 等策略 | session 保存 `agent_id`、project、kind、parent 和 orchestration policy | **创建时快照 + 工具实时**：systemPrompt/生成参数在会话创建时快照进 session 行，发送不重读 descriptor（除非显式换 Agent）；工具/记忆策略按 agent_id 实时重读；descriptor 无版本字段；重新生成是破坏性替换（删源消息起全部再重发） |
| Jan | `Assistant.id`；默认 `jan` | 每 Assistant 一个目录和 `assistant.json` | 创建 thread 时写入 `ThreadAssistantInfo` | **嵌入快照**：name/model/instructions/tools 被复制进 thread；thread 发送读内嵌快照的 instructions/parameters，不读 Assistant 当前配置；消息本身不保存模型/参数元数据；重新生成保留旧回复为 sibling（parentId/activeRootId 版本切换） |
| LobeHub | Agent id + `LobeAgentConfig` | 后端数据库（messages/topics 表含 model/provider 列），前端 store 缓存编辑态 | 发送时按 agentId 从 DB 读当前配置（`agentService.getAgentConfigById`），会话不存配置副本 | **实时引用 + 消息模型快照**：assistant 消息与 topic 记录 model/provider；开场白不落库、空会话实时渲染；regenerate 先删旧消息再重生成（覆盖语义） |
| Manifold Desktop | 无角色实体 | `%LOCALAPPDATA%\Manifold\settings.json` 全局单值 | 所有会话读取同一全局 system prompt | **无快照且消息不落盘**：前端 `session-store.js` 无任何引用（死模块），聊天消息仅存内存数组；`SAVE_SESSION` 只写 title；无 regenerate（Retry 仅移除错误元素） |
| NextChat | `Mask.id` | Zustand 持久化用户 Mask；内置 Mask 来自 `/masks.json` | `newSession(mask)` 把完整 Mask 复制到 session | **完整副本**：模板修改不回写；fork 再深拷贝；全局同步开启时模型配置可继续被覆盖；开场白是固定 `BOT_HELLO` 欢迎语（渲染期注入、不入历史，与 Mask 无关）；bot 消息只快照模型名；regenerate 删除旧配对后重建 |
| Open WebUI | Workspace Model `id` | DB `Model` 行：`params/meta` JSON + access grants | 前端按 model id 请求，服务端路由按 id 重新读 DB；chat 表 JSON 列另存 `models` 列表与 `chat.params` 覆盖 | **运行时引用 + 局部快照**：assistant 消息有 `model_id` 列但无 params 快照；chat 级 params 随 chat 保存并随请求发送，与模型 params 并存；regenerate 纯前端在 parent 下新建 assistant 兄弟消息（不替换原消息） |
| SillyTavern | Character Card 名称/文件 | `characters/` 下 PNG、JSON、CharX 或 BYAF | 应用选择角色卡；User Persona 另属全局/单会话层 | **创建时快照 + tainted 固化**：开场白（first_mes/alternate_greetings 转 swipes）随 JSONL 落盘；未 tainted 聊天在改卡后可整体重建开场白，首次生成后 `tainted` 置位固化；每次生成重读角色卡当前值；消息/每个 swipe 快照 `extra.api/model`，无温度/预设快照；swipe 追加保留旧回复，regenerate 删除末条助手消息重建 |
| VCPChat | Agent 目录名 `agentId` | 每 Agent 目录：配置、规则、头像；每 topic 一个 `history.json` | 先选 Agent，再选其 topic；发送用 `currentSelectedItem.config` 内存缓存引用（设置保存/话题加载时刷新） | topic 历史与 Agent 配置分存；消息只含 role/name/content/timestamp/id/attachments，无模型/参数元数据；重新生成时重读最新配置并截断原消息及其后全部消息重建（覆盖语义）；分支是 topic 级 |
| VCPToolBox | 文件别名或 AgentAssistant `baseName/chineseName` | `.txt` + `agent_map.json`；插件 `config.json` | 变量引用、AgentAssistant 通信或 TaskAssistant 派发 | **无快照**：会话历史只存 `{role, content}` 裸消息对；每次请求从内存 `AGENTS` 映射现拼 payload（model/max_tokens/temperature）；config.json 仅 initialize/reloadConfig 时读取，Admin Panel 保存后热重载；无 regenerate API，OneRing 提供内容原地替换 |
| Hermes Agent | 无角色实体；`personalities` 名称、SOUL.md 文件名 | `config.yaml`（agent.personalities / agent.system_prompt / display.personality）+ `$HERMES_HOME/SOUL.md` + Profile 目录 | `/personality` 写全局 `agent.system_prompt`；TUI 会话保存 `personality` 键；Profile 独立选择 | 会话保存构建后的 system prompt（sha256 全文去重）与 model/model_config；人格当前文本不入轨迹，属"全局当前值 + 提示词快照"；retry_last 复用内存缓存不重建；存储 prompt 与运行时比对只检查尾部 Model/Provider 行，修改人格文本不判 stale |
| Pi | 无角色实体；文件即配置 | `SYSTEM.md`/`APPEND_SYSTEM.md`（全局 `~/.pi/agent/` 或项目 `.pi/`）+ `AGENTS.md` 链 + skills 文件 | 资源按会话 cwd 解析；无角色选择入口，`/reload` 重载文件 | 无快照：system prompt 不随会话条目保存（仅 HTML 导出含快照）；AssistantMessage 随消息记录 provider/model/usage/stopReason（无采样参数）；无用户级 retry/regenerate 命令，瞬时错误自动重试 |
| OpenCode | `Agent.Info.name`（配置构建）；无独立版本字段 | 配置对象（`opencode.json` 的 `agent`/`mode` 字段 + `{agent,agents}/**/*.md` + `{mode,modes}/*.md`）；无 agent 表 | 输入框/对话框/`--agent`/`@` 提及选择；session 表保存 agent 名（`core/src/session/sql.ts:51`），发送时 `setAgentModel` 同步 | **引用 + 消息快照**：session 与消息各存 agent/model 字段（含 variant/tools，无温度等参数）；undo/revert 是物理删除 revert 点之后的消息再重发（非分支对比），重发时重建 agent 重新解析当前配置；分支手段只有 `session.fork`；part 不携带请求参数元数据 |

这里可以明确区分四种继承模型：

```text
运行时引用：AIO Hub / AstrBot / Open WebUI
  会话保存 ID，下一轮重新解析当前配置

创建时快照：Chatbox / Jan
  创建会话或线程时复制关键角色内容

完整会话副本：NextChat
  复制整个 Mask，之后可独立修改和 fork

全局当前值：Manifold Desktop
  所有会话共享当前设置，历史不保存当时配置
```

Pi 介于“全局当前值”与“运行时引用”之间：提示词文件在会话创建或 `/reload` 时读取，同一会话内每轮使用已加载内容，不逐轮重读文件；切换 cwd 即换一套文件资源。其会话文件不保存任何提示词快照，与 Manifold Desktop 一样无法从历史复原当时提示词。

OpenCode 属于“运行时引用”的变体：会话只保存 agent 名字与当时的 model 快照，下一轮生成时按当前配置重新构建 agent 与权限；但每条消息额外带 agent/model 字段，使历史渲染仍能显示当时的角色与模型，而 Manifold Desktop 与 Pi 都做不到这一点。

AIO Hub 是运行时引用的混合形态：开始对话前，开场白候选仍会随 Agent 同步；第一次发送后，全部开场白分支固化为会话消息。其余 Agent 配置在每次发送、续写和重新生成时重新读取，重新生成则基于同一用户节点创建新的助手兄弟分支。这种设计优先支持在相同历史下修改 Agent 后即时对比，而不是把会话做成完整角色版本快照。

其余项目可归入或接近上述类别：Cherry Studio 和 LobeHub 是运行时引用（每次请求重读 Assistant/Agent 当前配置，消息另存作者/模型快照）；DeepChat 是“创建时快照 + 工具实时”的混合（systemPrompt/生成参数在会话创建时快照进 session 行，工具与记忆策略按 agent_id 实时重读）；SillyTavern 是“创建时快照 + 每轮重读”的混合（开场白随 JSONL 固化且 tainted 阻止回写，每次生成重读角色卡）；VCPChat 发送使用内存缓存引用、重新生成时重读最新配置并截断重建；VCPToolBox 以内存映射 + 热重载接近运行时引用但没有任何消息级快照；Manifold Desktop 确认连消息本身都不落盘。

## 提示词、模型与参数

| 项目 | 人格内容形态 | 已确认的装配或优先级 | 模型与生成参数所有者 |
| --- | --- | --- | --- |
| AIO Hub | 有序消息树，支持 system/user/assistant、锚点、深度、模型匹配，以及带多选/单选/组级开关的消息组 | 按默认顺序或 `depth/advanced_depth/anchor` 注入，`chat_history` 与 `user_profile` 是显式锚点；组状态由编辑器投影为成员 `isEnabled` | Agent 实例保存 `profileId/modelId` 和参数；Profile 只保存模型定义与凭据 |
| AstrBot | `system_prompt` + 偶数条 `begin_dialogs` | Persona 追加为 `# Persona Instructions`；Skills、工具提示、环境提示和 router prompt 后续继续追加；begin dialogs 位于历史前 | Persona 不绑定模型；Provider/模型在外层配置 |
| Chatbox | 单段 Copilot `prompt` | 创建 Session 时成为首条 system 消息 | Provider、modelId、temperature 等属于 Session，不属于 Copilot |
| Cherry Studio | 单段 `prompt`，支持变量 | Assistant prompt 先写入；存在 `tool_search` 时再追加 deferred-tools 提示 | Assistant 保存 `modelId` 与 `AssistantSettings` |
| DeepChat | descriptor `systemPrompt` | `PromptAssemblyService.build` → `buildSystemPromptWithSkills` 九段拼接（basePrompt 最前，`systemPromptBuilder.ts:260-268`）；ACP 子会话直返原文 | Agent config 保存多种模型 preset 与生成参数 |
| Jan | 单段 `instructions`，支持 `{{current_date}}` | 从 thread 快照渲染 system prompt；只有非 `model-only` Assistant 才采用其参数 | Assistant/thread 快照保存模型；web/core 参数形状仍有未确认差异 |
| LobeHub | `systemRole` + `fewShots`（字段存在）+ opening + input template | 输入模板位置已确认；**fewShots 在 `src/` 与 `packages/agent-runtime/` 无消费点**（仅类型、DB schema、市场导入映射引用），运行时请求只传 `systemRole`，其实际注入效果未确认 | Agent 保存 `provider/model/params` 与大量 chatConfig |
| Manifold Desktop | 全局单段 `systemPrompt` | OpenAI 放消息首部，Anthropic 放顶层 `system`，Gemini 放 `systemInstruction` | 全局 `activeProviderId/model/temperature` |
| NextChat | 有序 `context: ChatMessage[]` | system prompt -> 长期记忆摘要 -> Mask context -> 最近历史 -> 本轮用户消息 | Mask/session 副本保存 `modelConfig`；可继续同步全局配置 |
| Open WebUI | `params.system`，支持 chat/user/metadata/旧式变量 | 参数为全局默认 < 模型 params < 请求 params；模型 system 在出站时前置到已有 system 内容 | Workspace Model 保存基础模型引用和任意参数；请求仍可覆盖 |
| SillyTavern | description/personality/scenario/system/示例/post-history 分字段 | 非空 `system_prompt` 覆盖全局；`post_history_instructions` 放历史末尾；其他字段位置可由 Advanced Formatting 调整 | 角色卡不存模型参数；模型与生成参数归 Preset/连接设置 |
| VCPChat | 单段 `systemPrompt` + `{{AgentName}}` | Agent system prompt 后应用全局 Tavern `system_suffix`；另有 user suffix 和 context depth 注入 | Agent 保存裸 model id、temperature、上下文和输出上限 |
| VCPToolBox | `.txt` 变量模板或 AgentAssistant `systemPrompt` | 多阶段替换 Var/Tar/Sar/VCP/TagMemo/agent/TVStxt；AgentAssistant `globalSystemPrompt` 追加到所有 Agent | AgentAssistant 每个 Agent 保存 modelId、temperature、maxOutputTokens；文本文件层不拥有模型 |
| Hermes Agent | SOUL.md 文本 + `personalities` 单段提示（string 或 dict） | SOUL/默认身份 → 稳定指引 → 项目上下文（.hermes.md>AGENTS.md>CLAUDE.md>.cursorrules）→ 技能/记忆/USER.md/时间行 → 调用时附加 ephemeral；一次构建缓存、压缩时重建 | 人格不绑定模型；模型归全局 `model:`/session `/model`/ChannelOverride/Profile；温度与 max_tokens 由 Provider 适配层解析 |
| Pi | SYSTEM.md（整篇替换）+ APPEND_SYSTEM.md（追加）| 自定义时：SYSTEM → APPEND → `<project_context>`（AGENTS/CLAUDE 链）→ skills 索引 → cwd；默认模板时：开场+工具列表+guidelines+文档指引 → APPEND → context → skills → cwd；`before_agent_start` 扩展可当轮整篇覆盖 | 模型/思考等级是会话级状态（`model_change` 条目），默认值在全局+项目设置；无角色级生成参数 |
| OpenCode | agent `prompt`（markdown 正文原样）或空 | 两段拼装：`agent.prompt ?? provider 风格提示` → env/AGENTS.md 指令/MCP 指令/skills → user.system（`llm/request.ts:56-66`、`session/prompt.ts:1257-1271`）；AGENTS.md 按全局→项目祖先链加载（`session/instruction.ts:110-153`） | Agent 可绑 `model`/`variant`/`temperature`/`top_p`/`options`；生效 `input.model ?? agent.model ?? session.model ?? provider.defaultModel()`（prompt.ts:646、614-633）；切换 agent 默认继承上一模型 |

提示词“优先级”在不同项目中有三种动作，不能统一写成覆盖关系：

| 动作 | 项目示例 | 语义 |
| --- | --- | --- |
| 替换 | SillyTavern 非空 `system_prompt` | 角色卡 system 取代应用 Preset system |
| 前置/追加 | Open WebUI、AstrBot、Cherry Studio、VCPChat、Hermes Agent | 多段 prompt 共存，位置决定约束先后 |
| 消息级插入 | AIO Hub、NextChat、SillyTavern depth/world info | 内容以 system/user/assistant 消息或历史深度进入上下文 |

因此，只比较一个 `systemPrompt` 字段是否存在会遗漏 AIO Hub 的锚点消息、SillyTavern 的历史末尾指令和 NextChat 的多角色 context，也会误把 Open WebUI 的参数覆盖顺序当成 system prompt 替换顺序。

## 工具、知识与记忆

| 项目 | 角色级工具/能力控制 | 角色级知识 | 记忆与状态 |
| --- | --- | --- | --- |
| AIO Hub | 工具/方法开关、审批、迭代、超时、并发、协议和设置都归 Agent | 世界书 + 细粒度 RAG 绑定与注入策略 | 会话变量、非破坏性摘要压缩、虚拟时间；会话变量不等于长期记忆 |
| AstrBot | `tools`/`skills` 三态：全部、禁用全部、白名单；workspace Skills 有单独合并语义 | KB 结果走用户消息侧注入，不属于 Persona 字段 | Persona 无长期记忆字段；begin dialogs 不入库，system 受截断保护 |
| Chatbox | Skills、Agent Mode、MCP、工作目录和 full access 都在 Session/全局层，不在 Copilot | Session 附件 RAG；知识库模型为全局设置 | Session 可自动压缩；Copilot 无记忆字段 |
| Cherry Studio | Assistant 绑定有序 MCP server 列表和模式；Agent Session 另走 Claude Code 工具路径 | Assistant 绑定有序知识库列表 | 角色笔记未找到 Assistant 长期记忆字段 |
| DeepChat | Agent 保存权限模式、禁用工具、Skills、MCP 和 subagent slots | 未作为独立角色字段总结 | Agent 保存 memory 检索/抽取/预算、自动压缩和 persona evolution 开关 |
| Jan | `AssistantTool` 当前只定义 retrieval，默认关闭 | `file_ids` + retrieval 工具定义；web 持久化链路未确认 | 未提供独立长期记忆字段 |
| LobeHub | 插件有 pinned/auto/disabled，另有 agent/chat/custom 工具模式和异构 Agent | 每 Agent 绑定知识库与文件 | `memory.enabled/effort/toolPermission` 明确区分只读与读写，另有压缩和自迭代 |
| Manifold Desktop | 无角色级工具配置 | 无角色级知识配置 | 无角色级记忆；历史不保存 prompt/temperature |
| NextChat | `Mask.plugin` 绑定 OpenAPI 插件 id，但无角色级权限、审批或参数范围 | 未提供 Mask 知识库字段 | 请求可注入长期记忆摘要，但单项目笔记未把记忆所有权归入 Mask |
| Open WebUI | Model meta 绑定 tools、skills、filters、builtin tools、terminal 和能力开关，并叠加 access grants | `meta.knowledge` 引用集合/文件 | memory 是可选内置 feature；角色笔记未确认 per-model 长期记忆命名空间 |
| SillyTavern | 角色卡核心不承载工具授权；extensions 可扩展，工具安全另见工具笔记 | 内嵌 Character Book + 外部 World Info | User Persona 独立；角色卡本身无通用长期记忆字段 |
| VCPChat | Agent config 无工具开关，工具由 VCP 服务端和全局连接决定 | 未提供角色级知识库字段 | 每 topic 独立历史；无已确认的长期记忆配置 |
| VCPToolBox | 工具可见性来自 VCP 占位符、TVStxt、任务 `injectTools` 和全局插件状态，不是硬权限边界 | TagMemo/日记本变量可召回知识 | AgentAssistant 有历史轮数/TTL；AgentDream 有独立记忆整理和审批流程 |
| Hermes Agent | 人格/提示词不授权工具；工具开关在平台级 `tools.<platform>` 与 `hermes tools`，工具加载与否才影响指引注入 | SOUL.md 是身份文本；项目 AGENTS.md/.cursorrules 随 cwd 提供；无角色级知识库字段 | MEMORY.md（agent 记忆）与 USER.md（用户画像）可注入 volatile 段；外部记忆 Provider（plugins/memory）追加提示；子 Agent 继承 ephemeral |
| Pi | 无角色级工具授权；工具激活集是会话级列表（默认 read/bash/edit/write），system prompt 只列带 snippet 的工具 | 无知识库；等价物是 `<project_context>` 上下文文件与 skills 文本 | 无独立记忆；长期记忆即会话历史+压缩摘要，跨会话无自动记忆 |
| OpenCode | agent `permission` 规则（`{pattern: action}`）+ 会话 permission 合并，运行时过滤工具/MCP/Skill 可见性（`llm/request.ts:208-214`、`session/tools.ts:81-89`）；`tools` 布尔字段已废弃 | 无角色级知识库字段；等价物是 AGENTS.md 指令与引用（reference） | 无角色级长期记忆；会话 todo 列表与压缩摘要（compaction）属会话状态 |

能力绑定可分成三种强度：

1. **显式策略对象**：AIO Hub、AstrBot、DeepChat、LobeHub、Cherry Studio。角色配置直接保存白名单、模式或服务器引用，运行时仍需结合全局注册状态和执行策略。
2. **会话或外层挂载**：Chatbox、Jan、NextChat、Open WebUI。人格模板本身未必拥有工具，但会话、模型预设或 thread 快照会携带能力信息。
3. **内容约定或服务端决定**：SillyTavern、VCPChat、VCPToolBox。提示词/扩展/服务端暴露面决定模型看到什么，角色文件不等于独立权限域。

## 导入、导出与兼容性

| 项目 | 已确认格式或入口 | 可移植范围与边界 |
| --- | --- | --- |
| AIO Hub | JSON/YAML；ZIP、文件夹、单文件、带数据 PNG；可导入 SillyTavern JSON/PNG | 可携带资产、世界书和多数 Agent 配置；本地 id/profileId 等实例字段剥离，目标端仍需重绑模型 |
| AstrBot | Dashboard JSON 导入；v3 config persona 自动迁移到 v4 DB | 冲突名称自动加后缀；旧 mood dialogs 拼入 system prompt；未见通用角色卡格式 |
| Chatbox | 应用备份 ZIP/JSON、远端 Copilot 市场 | 主要携带单段 prompt 和元数据；模型、few-shot、工具不在 Copilot 中 |
| Cherry Studio | Resource Catalog / assistant transfer；v1 -> v2 migrator | 工具配置不随模板跨机器迁移；少样本和世界书没有 v2 原生对应 |
| DeepChat | 未调查独立 Agent 导入/导出 | descriptor 迁移和 UI 兼容分支未覆盖 |
| Jan | 每 Assistant 一个 JSON，内建 v1/v2/v3 schema 迁移；无独立导入导出接口（跨设备迁移只能复制数据目录） | core/web 类型不一致，parameters/tools 的完整往返仍未确认 |
| LobeHub | 市场导入；完整 AgentConfig JSON 导出 | 可携带 Agent 配置；外部插件、知识库和模型资源仍依赖目标环境 |
| Manifold Desktop | 提示词库每条 JSON；角色导入不存在 | 只能复用文本，不能表达会话角色、模型包或能力绑定 |
| NextChat | 单个或数组 Mask JSON；URL `?mask=<id>` | 导入只检查 name，无 schema 版本、字段白名单或冲突策略；URL 只分享已有 id |
| Open WebUI | Workspace Models import/export/sync API | 逐条校验 knowledge 文件权限和写权限；模型、参数、meta 与 grants 是平台内对象 |
| SillyTavern | PNG、JSON、CharX、BYAF；V1 自动映射 V2，支持 V3 | 角色内容和内嵌资产/世界书可移植；模型参数和应用 Preset 不在角色卡中 |
| VCPChat | 无批量导入；UI 手工创建 | 可手工粘贴 system prompt；客户端 Agent 与服务端 AgentAssistant 需人工对应 |
| VCPToolBox | 放置 `.txt` 并登记 `agent_map.json`；Admin Panel 管 AgentAssistant | 文本容易导入，但 AIO 消息树、SillyTavern depth 等结构需展平，VCP 变量依赖服务端运行时 |
| Hermes Agent | `hermes import-agent`（Claude Code/Codex）；`hermes backup`/`import`；`hermes profile export/import`；`profile install/update`（distribution.yaml）；`hermes claw migrate`（OpenClaw） | 导入 CLAUDE.md/AGENTS.md/memories→MEMORY、权限→command 白名单、skills、MCP；凭据一律排除；persona 字段无导入承载；profile 分发默认含 SOUL.md/config/skills，用户数据目录绝不覆盖 |
| Pi | 无角色导入导出；`/export`（HTML/JSONL）只导出会话 | 角色即文件，复制文件即“导入”；无 schema 校验、无字段映射、无冲突处理 |
| OpenCode | 无导入导出命令；`opencode agent create`（CLI）由 LLM 生成带 frontmatter 的 markdown | 复制 markdown 文件即可携带角色；`opencode export` 只导出会话且 agent part 脱敏；V1→V2 配置迁移器自动映射字段（`core/src/v1/config/migrate.ts:35-125`） |

SillyTavern 的角色卡和 AIO Hub 的 Agent 包覆盖面最接近“可分享角色资产”，但两者的能力边界不同：SillyTavern 刻意把模型 Preset 留在卡外，AIO Hub 导出则可以携带 Agent 参数、资产和世界书，同时剥离本机渠道引用。Open WebUI、Cherry Studio、LobeHub 的导入更接近平台内模板或数据库对象迁移，外部资源引用不能只靠一份 JSON 保证生效。

从跨项目映射看，最稳定的最小公分母只有**名称、单段 system prompt、头像/图标（若目标支持）和描述**。以下内容通常会丢失或需要人工适配：

- AIO Hub 的消息树锚点、分组、模型匹配与会话变量；
- SillyTavern 的 `post_history_instructions`、depth prompt、World Info 触发语义和扩展字段；
- LobeHub/DeepChat 的 memory、subagent、工作目录和编排策略；
- Open WebUI 的 access grants、基础模型链和平台内知识引用；
- VCPToolBox 的变量、TagMemo 与插件占位符；
- Chatbox、Jan、NextChat 已经写入历史会话的角色快照。

## 运行时可见性与变更影响

| 项目 | 用户能确认什么 | 修改角色后的已确认影响 |
| --- | --- | --- |
| AIO Hub | 当前 Agent、模型、参数、消息树、消息组、工具和知识配置均有编辑入口；侧边栏可直接切组和成员状态 | 侧边栏修改直接持久化当前 Agent，并影响既有会话的下一次发送/续写/重新生成；开场白仅在首次发送前同步，之后固化；重新生成保留旧回复并创建同历史分支 |
| AstrBot | Persona 选择器、会话规则、能力三态和 trace 记录 | 下一轮按优先级重解析；被删除引用可静默回落，第三方 runner 不注入 Persona；消息对象不保存 persona_id/模型名，当次模型记录在 trace 与 `provider_stat` 表 |
| Chatbox | Session 显示自身模型设置并保留 copilotId；消息显示 provider/模型 | 修改 Copilot 不更新既有 Session system 消息；重新生成创建 fork 分支保留旧回复 |
| Cherry Studio | Assistant 编辑器展示 prompt、模型、参数和关联资源；消息显示作者/模型快照 | 每次请求按 `assistantId` 重读当前 Assistant；修改后既有会话下一次请求生效；重新生成保留旧回复并新建兄弟分支 |
| DeepChat | Agent descriptor 与 session policy 都有明确状态字段 | systemPrompt/生成参数在会话创建时快照，修改 descriptor 不影响既有会话（除非显式换 Agent）；工具/记忆策略实时重读；重新生成破坏性替换 |
| Jan | 设置页和 Assistant switcher；thread 内有 AssistantInfo | 既有 thread 使用嵌入快照，不自动跟随模板；消息本身不保存模型/参数元数据；重新生成保留旧回复为 sibling |
| LobeHub | Agent 设置页覆盖人格、模型、插件、知识和 chatConfig | 发送时按 agentId 实时读 Agent 当前配置；开场白为空会话实时渲染；regenerate 删除旧消息后重生成 |
| Manifold Desktop | 只能看到当前全局设置 | 修改后所有后续请求读取新全局值；聊天消息仅存内存、不落盘，历史完全无法恢复 |
| NextChat | 当前 session 持有可编辑 Mask 和同步开关 | 模板改动不回写；当前会话改模型后关闭全局同步；开场白为固定欢迎语不入历史；regenerate 删除旧配对重建 |
| Open WebUI | 模型选择器和 Workspace Model 编辑页；只读调用者看不到 params | 下一次请求按 model id 重新读 DB；请求参数仍可覆盖模型参数；regenerate 在 parent 下新建兄弟消息 |
| SillyTavern | 角色卡与 Prompt Manager 可见 | 未 tainted 的聊天在改卡后可整体重建开场白；首次生成后 tainted 固化；每次生成重读角色卡当前值 |
| VCPChat | 当前 Agent/topic、模型参数和历史文件边界明确 | 发送用内存缓存引用（设置保存/话题加载时刷新）；重新生成时重读最新配置并以截断重建落盘 |
| VCPToolBox | Admin Panel 可热重载 AgentAssistant，文件层也热重载 | 新请求使用内存 `AGENTS` 映射的当前配置；历史只存 `{role, content}` 无快照可查 |
| Hermes Agent | `/personality` 列出可用与当前值、`/status` 显示模型/Provider；TUI 会话 personality；web 编辑 SOUL.md | 修改人格写全局 `agent.system_prompt`：CLI 强制重建 agent（下一轮生效），TUI 就地改 `ephemeral_system_prompt` 不重置历史；轨迹不含人格文本，历史重放反映缓存 system prompt；retry_last 复用内存缓存不重建，存储 prompt 与运行时比对只检查尾部 Model/Provider 行 |
| Pi | footer 显示当前模型/状态；`/session` 显示统计；无查看当前 system prompt 的内置命令 | 修改文件后 `/reload` 重建基础 prompt；`before_agent_start` 的当轮覆盖在轮末复位；历史只含消息与模型条目，无法从会话文件还原当时的提示词；无用户级重试命令（瞬时错误自动重试） |
| OpenCode | App/TUI 输入框 agent 下拉与 `@` 补全、按 agent 着色；消息元信息显示 agent·model·时长；CLI `opencode agent list`/`debug agent` 展示权限与工具状态 | 修改配置后新会话用新配置；既有会话消息显示当时快照，继续生成使用当前配置解析的 agent 与权限；undo 物理删除 revert 点之后的消息再重发并重建 agent；无“当前权限面板”UI |

## 适用边界

按实现边界观察，不做总排名，可以得到几组清晰取向：

- **需要一个角色同时拥有模型、参数、工具和知识**：AIO Hub、Cherry Studio、LobeHub、DeepChat、Open WebUI 都能表达，但聚合根不同。Open WebUI 的根是“模型”，其余项目的根是 Agent/Assistant descriptor。
- **需要在一个界面里组合并频繁切换提示词变体**：AIO Hub 是当前样本中最完整的实现。消息组可表达“风格任选多项”“场景只能选一项”“整套规则暂时关闭”，同时仍可对单条消息配置模型匹配和注入位置。SillyTavern 能表达许多相近的提示词位置和开关语义，但缺少同等的组级选择抽象，且配置分布更广；VCPChat 的 modular 积木模式支持块级启停与块内 variants 单选，是样本中最接近的机制，但块是平铺的、没有组级总开关。
- **需要人格与运行环境解耦**：Chatbox 和 AstrBot 更明确。Chatbox 把模型/工具放到 Session，AstrBot 把 Provider 放在 Persona 外，同时用 Persona 白名单收窄能力。
- **需要会话可复现性**：Jan、Chatbox、NextChat 已确认存在不同程度的角色快照。AIO Hub 选择了另一种取向：开场白和旧回复固化、未来执行实时读取当前 Agent，并记录部分请求元数据，适合在同一历史上迭代测试，但不能仅靠会话完整还原旧 Agent 配置。Manifold Desktop 已确认连消息本身都不落盘；其他项目的运行时表现需要补充运行验证后才能完全比较。
- **需要角色内容交换**：SillyTavern 的社区规范最明确，AIO Hub 的包覆盖资产和运行配置更广。两者之间仍需处理模型参数、消息位置和权限语义的差异。
- **需要服务端多 Agent 编排**：DeepChat、LobeHub、VCPToolBox 和 AstrBot 都有相关入口，但 subagent slot、异构 Agent、AgentAssistant 委托和 Persona router 是不同机制，不能只用“支持多 Agent”合并评价。
- **只需要所有聊天共用一条指令**：Manifold Desktop 的全局模型足够直接，但缺乏角色选择、会话级复现和能力隔离；Hermes Agent 也以全局提示词为基础，但 `agent.system_prompt`/`SOUL.md` 有 personalities 选择与 Profile 级隔离作为补充。
- **提示词即文件、随项目分发**：Pi 是十六个项目中唯一把整条角色链路做成普通 Markdown 文件的项目——SYSTEM.md/AGENTS.md 可进 git、按目录作用域天然隔离，代价是没有角色选择、导入格式、字段校验或运行时可见性。OpenCode 同样支持 `{agent,agents}/**/*.md`（frontmatter 角色文件，可进 git），但它是配置对象而非纯文件约定：还接受 opencode.json 字段、提供角色选择 UI 与权限/参数绑定，markdown 只是载体之一。

## 已确认边界与证据缺口

1. 单项目笔记的调查深度不完全一致。AIO Hub、AstrBot 对提示词装配和存储覆盖较深；Cherry Studio、LobeHub 重点在配置模型；DeepChat、Jan、NextChat、Open WebUI 更聚焦近期新增的持久化或运行链路。矩阵未用字段缺失填补这些深度差异。
2. “历史快照语义”十六个项目均有源码级证据。AIO Hub 是开场白/历史消息固化与 Agent 当前配置实时引用并存；Cherry Studio 与 LobeHub 是实时引用 + 消息作者/模型快照；DeepChat 是 systemPrompt/生成参数创建时快照 + 工具/记忆实时重读；SillyTavern 是开场白 JSONL 固化（tainted）+ 每轮重读角色卡；Chatbox/Jan/NextChat 是创建时快照或副本；VCPChat/VCPToolBox 无消息级快照；Manifold Desktop 消息不落盘；Open WebUI 是运行时引用 + chat 级 params 快照；Pi 已确认无提示词快照；AstrBot 每轮重解析但消息不存 persona_id。导出聊天、审计记录和历史重放的完整验证仍非全覆盖。
3. 角色修改后既有会话的行为已有静态代码结论；仍未运行验证的包括 AstrBot 切换后的旧历史渲染、SillyTavern 改卡后的 UI 表现、VCPToolBox 委托持旧对象引用期间的并发行为、DeepChat 跨版本迁移分支等，需要运行验证才能完全定论。
4. 工具字段只比较角色配置的挂载点。审批、沙箱、执行位置、模型可见定义和失效方向不在本文重复下结论。
5. 知识库“已绑定”不等于内容一定进入请求。实际效果还受召回阈值、权限、索引状态、模型能力、注入模式和全局服务状态影响。
6. 导入兼容性区分“能解析”“能保留字段”和“运行时生效”。手工粘贴 system prompt 只能算文本迁移，不能算角色格式兼容。
7. Jan 的 core/web Assistant 类型不一致是已确认事实；tools、parameters 与文件存储的完整往返仍未运行验证，因此横向表没有把任一侧字段当成完整稳定契约。
8. AstrBot Persona 只对内置 Agent runner 注入；Dify、Coze、Dashscope、DeerFlow 等第三方 runner 只读取自定义错误文案。对 AstrBot 的能力结论不能外推到所有 runner。

## 后续维护口径

新增项目或更新单项目笔记时，横向表至少复核以下九项：

1. 角色是独立实体、模板、模型别名、会话副本还是全局设置；
2. 稳定 ID、版本字段、存储位置和删除/迁移语义；
3. 会话保存引用、部分快照、完整副本还是不保存角色状态；
4. 全局 prompt、角色 prompt、会话 prompt、历史末尾指令和临时输入的实际装配顺序；
5. Provider、模型和生成参数属于角色、会话还是全局配置；
6. 工具、Skills、MCP、知识库、文件、记忆和 subagent 是绑定、白名单、提示词约定还是全局能力；
7. 导入时未知字段、资源引用、敏感配置和目标端缺失能力如何处理；
8. 用户能否看到当前角色、实际模型、能力范围和局部覆盖；
9. 修改或删除角色后，既有会话、历史重放和导出记录使用什么版本。

只有单项目笔记提供了直接证据，横向表才把“未调查/未确认”改为肯定结论。
