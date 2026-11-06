# Agent 角色配置横向调查与对比

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、DeepSeek Harness、Dify、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、SillyTavern、VCPChat、VCPMobile、VCPToolBox、Hermes Agent、Risuai、OpenClaw、RikkaHub、Codex、OpenOcta
>
> 对比更新日期：2026-11-05
>
> 依据：下列单项目角色笔记及其链接的会话、请求与工具专项；调查日期与源码快照分别以各来源元数据为准
>
> 对比方法：统一比较角色实体、存储粒度、会话绑定、提示词装配、模型参数、工具授权、知识与记忆、导入格式和历史快照；只采用单项目笔记中已有的源码结论
>
> 对比范围：Agent、Assistant、Persona、Mask、Character Card、自定义模型及与角色最接近的全局提示词配置；不重复展开工具执行安全、Provider 渠道管理和消息渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 单项目笔记

| 项目 | 笔记 | 行数 | 分支 | 代码快照 |
| --- | --- | ---: | --- | --- |
| AIO Hub | [AIO-Hub-Agent角色配置调查笔记.md](AIO-Hub-Agent角色配置调查笔记.md) | 488 | `dev` | `03cf4b6e028d0e23d5447a7c0cd7678aab07af3f` |
| AstrBot | [AstrBot-Agent角色配置调查笔记.md](AstrBot-Agent角色配置调查笔记.md) | 340 | `master` | `f926af99ec5f8bd85b64413f8bfad55da76ef73b` |
| Chatbox | [Chatbox-Agent角色配置调查笔记.md](Chatbox-Agent角色配置调查笔记.md) | 248 | `main` | `d17455c5ca8fd3ff44385c6d4d2118599e4c970f` |
| Cherry Studio | [Cherry-Studio-Agent角色配置调查笔记.md](Cherry-Studio-Agent角色配置调查笔记.md) | 230 | `main` | `e2fd716e569c73c1baa4ac226b6b0607792cdb9d` |
| DeepChat | [DeepChat-Agent角色配置调查笔记.md](DeepChat-Agent角色配置调查笔记.md) | 198 | `dev` | `3db91f876ad903b17215da94cd1a4a6398823dad` |
| DeepSeek Harness | [DeepSeek-Harness-Agent角色调查笔记.md](DeepSeek-Harness-Agent角色调查笔记.md) | 173 | `master` | `8bd073392eef6f54e921a093b95076248eb08cbb` |
| Dify | [Dify-Agent角色配置调查笔记.md](Dify-Agent角色配置调查笔记.md) | 94 | `main` | `e568478f8f2b95efc189b698c2f4386a7dbe1c3e` |
| Jan | [Jan-Agent角色配置调查笔记.md](Jan-Agent角色配置调查笔记.md) | 162 | `main` | `12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9` |
| LobeHub | [LobeHub-Agent角色配置调查笔记.md](LobeHub-Agent角色配置调查笔记.md) | 254 | `canary` | `67aaf17da1f43f0b5c851794b796a92d3258b86b` |
| Manifold Desktop | [Manifold-Desktop-Agent角色配置调查笔记.md](Manifold-Desktop-Agent角色配置调查笔记.md) | 74 | `main` | `3d7448fb2e6053056da6d6c126e08f90b94cda4f` |
| NextChat | [角色](NextChat-Agent角色配置调查笔记.md)、[输入模板分流](../对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) | 173 | `main` | `1d3dc331512929a4b1d3e82354e72acce33b5c7a` |
| Open WebUI | [Open-WebUI-Agent角色配置调查笔记.md](Open-WebUI-Agent角色配置调查笔记.md) | 215 | `main` | `c38885a1a737da4968f157092f304f3b5481d0bf` |
| OpenCode | [OpenCode-Agent角色配置调查笔记.md](OpenCode-Agent角色配置调查笔记.md) | 133 | `dev` | `7864a941527ad54e415d5875c98e038c5fc25697` |
| Pi | [Pi-Agent角色配置调查笔记.md](Pi-Agent角色配置调查笔记.md) | 136 | `main` | `ff33ef42c4bd762cecd6958e3aabbc8e684ceb05` |
| RikkaHub | [RikkaHub-Agent角色配置调查笔记.md](RikkaHub-Agent角色配置调查笔记.md) | 245 | `master` | `903e058b9361bff71d0b79f4ef2d8ac23d6597e6` |
| SillyTavern | [SillyTavern-Agent角色配置调查笔记.md](SillyTavern-Agent角色配置调查笔记.md) | 213 | `release` | `06bde939fb1e9c4c8d8641d810f0a916b5bce127` |
| VCPChat | [VCPChat-Agent角色配置调查笔记.md](VCPChat-Agent角色配置调查笔记.md) | 168 | `main` | `ce9882266782ffdd7b958bbf79d8db70480047c0` |
| VCPMobile | [VCPMobile-Agent角色配置调查笔记.md](VCPMobile-Agent角色配置调查笔记.md) | 75 | `main` | `5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5` |
| VCPToolBox | [VCPToolBox-Agent角色配置调查笔记.md](VCPToolBox-Agent角色配置调查笔记.md) | 269 | `main` | `018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf` |
| Hermes Agent | [Hermes-Agent-Agent角色配置调查笔记.md](Hermes-Agent-Agent角色配置调查笔记.md) | 235 | `main` | `71736c9f32597bbca9d89cede5aa136e55946b2f` |
| Risuai | [Risuai-Agent角色配置调查笔记.md](Risuai-Agent角色配置调查笔记.md) | 225 | `main` | `39f1ac1472d0ef6907ee933c4cf25182ee2aec9f` |
| OpenClaw | [OpenClaw-Agent角色配置调查笔记.md](OpenClaw-Agent角色配置调查笔记.md) | 609 | `main` | `55a554e78a83af031760ef247e26d5be9e24329d` |
| Codex | [Codex-Agent角色配置调查笔记.md](Codex-Agent角色配置调查笔记.md) | 277 | `main` | `021fccb046508938c4754982efccfb51d6e8356e` |
| OpenOcta | [OpenOcta-Agent角色配置调查笔记.md](OpenOcta-Agent角色配置调查笔记.md) | 271 | `main` | `0c7dac2284211facdfc813166fe648d093153bb6` |

## 比较口径

本文比较的是“哪一层拥有配置，以及运行时怎样消费配置”，不按字段数量给项目排名。二十四个项目中，“角色”至少有十五种不同含义：可执行 Agent、助手配置、人格模板、角色卡、自定义模型、应用发布配置、全局 system prompt、文件约定的提示词资源、编码 Agent 的配置对象、插件行组合的 preset、移动端 SQLite Agent，以及 Hermes 的分层提示词机制、OpenClaw 的配置条目加 workspace 文件组合、Codex 的 spawn 子 Agent 预设加 AGENTS.md 指令层、OpenOcta 的数字员工模板加 `agents.list` 运行主体。只有先确定载体，模型绑定、工具权限和历史快照才有可比性。

矩阵使用以下表述：

| 表述 | 含义 |
| --- | --- |
| 有 / 无 | 单项目笔记已用类型或执行路径确认存在或不存在 |
| 未提供 | 已读角色数据模型中没有该字段，但能力可能位于全局、会话或其他模块 |
| 未调查 | 单项目笔记没有覆盖该主题 |
| 未确认 | 已找到相关字段或入口，但静态证据不足以确认最终运行时语义 |

“角色支持工具”指角色配置能够收窄、绑定或触发工具来源；工具能否实际执行、是否需要审批、是否受沙箱约束，由执行层决定。工具发现、审批和执行边界以 [Agent工具横向对比.md](../Agent工具/Agent工具横向对比.md) 为准。

## 结论摘要

二十四个项目没有一个共同的“Agent 角色”抽象，主要差异在配置所有权和会话继承方式。

1. **配置聚合型 Agent：AIO Hub、Cherry Studio、LobeHub、DeepChat、RikkaHub。** 角色同时拥有提示词、模型或模型引用、生成参数和外部能力。AIO Hub 还把可分组切换的消息树、资产、世界书、会话变量和工具审批放进同一实例；消息组支持多选、单选和组级开关，并在聊天侧边栏直接呈现。LobeHub 把长期记忆、图编排和插件模式纳入 Agent；DeepChat 把项目目录、权限、MCP、Skills、subagent slot 和 memory policy 放进 descriptor；Cherry Studio 的范围相对收敛，以模型、单段 prompt、MCP 和知识库关联为主。RikkaHub 聚合人格与能力，会话复制模型、搜索和工具接入等执行配置，其余人格、采样与记忆继续读取助手当前值。
2. **模板与会话分层：Chatbox、AstrBot。** Chatbox 的 Copilot、Soul 与记忆共同提供身份，模型和运行能力留在会话/全局；首次需要时冻结提示上下文，工作目录与记忆作用域变化另行刷新对应切片。AstrBot Persona 拥有提示词与工具/Skills 白名单，但模型不属于 Persona；运行时按会话规则、对话绑定和全局默认逐轮解析。
3. **会话副本型：Jan、NextChat。** Jan 把 Assistant 的 name/model/instructions/tools 复制进 thread；NextChat 为 session 和 fork 复制顶层 Mask 与模型配置，嵌套数组仍可能共享；fork 重置摘要并重分配消息 id。两者都使历史会话脱离模板的后续修改，但 NextChat 还保留全局模型配置同步开关。Jan 另有 CLI 项目 Agent 与 Cowork 子 Agent 两条配置边界：Cowork 的 task 可在一轮中并行派发子 Agent，派发 schema 与 Rust 侧 `subagent.rs` 同源（`{subagents:[{name, task, phase?, allowed_tools?}]}`），`name` 命中已保存的子 Agent 定义即复用其角色与工具，带 `phase` 时按阶段成组串行，每个子 Agent 的写域另有 git worktree 隔离。
4. **模型即角色：Open WebUI。** Workspace Model 同时是上游模型别名、system prompt、参数包、知识和工具绑定、访问控制对象。请求按 model id 重新读数据库，角色生命周期直接复用模型目录和权限体系。
5. **可移植内容型：SillyTavern。** Character Card 的边界是人格、场景、示例对话、开场白、世界书和扩展字段；模型与生成 Preset 分离。它在当前二十四个项目中拥有最明确的社区角色卡格式和很细的提示词语义分区，但角色卡本身不承担模型和工具权限，实际配置还分散在角色卡、推理 Preset、Prompt Manager、Advanced Formatting、World Info 与扩展层。AIO Hub 对这套生态的支持不止角色卡导入：它有独立世界书编辑器、持久化与导入导出服务，受支持字段会进入真实上下文管道；两者的差距主要落在社区资产、扩展协议与完整语义覆盖。
6. **文件/服务编排型：VCPChat、VCPToolBox。** VCPChat 每个 Agent 一个目录，模型和基础参数随 Agent 保存，工具策略留给 VCP 服务端。VCPToolBox 同时存在提示词文件和 AgentAssistant 配置两层，前者参与变量替换，后者承担具名多 Agent 通信和任务派发。
7. **无角色实体：Manifold Desktop。** 只有全局 system prompt、温度、Provider/模型和文本提示词库；会话不保存发送时配置。因此它应作为“全局配置基线”比较，不能记成一个功能较少的 Agent 实现。
8. **移动端持久化 Agent：VCPMobile。** SQLite `agents` 表的 Agent 同时拥有名称、双层系统提示词、裸模型 ID 和生成参数，并拥有多个话题；发送前实时读取当前 Agent 配置。网关 URL/Key 是全局单值，工具、知识、记忆与 Provider 绑定不在 Agent 内；角色包导入导出和版本字段仍未确认，但 Agent 级本机设置可导出与导入（带哈希与更新时间校验），语音配置（发音人、语音库、朗读规则与预览）也是本机扩展。
8. **分层提示词 + 独立 Profile（Hermes Agent）。** 身份文件、命名人格模板、用户手动 system 提示词与运行时注入共同叠加成 system prompt；`display.personality` 保存选中的**人格名称**并成为权威来源（空 = 无 overlay）。启动或创建 agent 时优先把命名人格渲染成文本，否则回退到用户手动提示；环境变量仍最优先，**人格代码不会写回用户手动提示字段**（v33→v34 迁移会一次性清理旧写入）。任何一层都不绑定模型或工具。角色隔离放在 Profile（独立的 HERMES_HOME 目录）这一完整容器上。修改角色只影响下一次构建或由 TUI 就地改 ephemeral，不重写既有缓存前缀。
9. **无角色实体、文件约定型：Pi。** 角色能力由 `SYSTEM.md`（整篇替换默认提示词）、`APPEND_SYSTEM.md`（追加）、`AGENTS.md/CLAUDE.md` 祖先链（`<project_context>` 块）与 skills 文件组合，全部按会话 cwd 在启动时解析；模型/思考等级是会话级状态，默认值来自全局+项目设置。没有任何角色对象、角色 UI 或角色导入导出，system prompt 本体不随会话条目保存。
10. **配置对象 + 内置 agent 模板：OpenCode。** Agent 是由配置构建的只读内存对象（`src/agent/agent.ts:35-56`），来源为配置文件的 agent 字段与带 frontmatter 的角色文件（mode 文件强制 primary）；持久化的只是 session 表上的 agent 名字引用，会话消息另存 agent/model 快照。角色同时拥有 prompt（缺省回退 provider 风格提示）、模型与生成参数、permission 规则和 steps 上限；内置 build/plan（primary）、general/explore（subagent）、compaction/title/summary（hidden）。修改角色配置后，新会话用新配置，既有会话的消息仍显示当时的 agent/model 快照，但继续生成使用当前配置解析的 agent 与权限。
11. **preset 组合型：DeepSeek Harness。** 角色由普通插件声明行定义，注册表急切创建组合修订，Agent 通过作用域父链绑定；更新会退役旧修订，运行中及历史读取引用释放后才回收。人格与工具共享组合，模型选择独立并在每步准备时固定。日志可重建所选身份，插件内部负责会话隔离（[来源](<./DeepSeek-Harness-Agent角色调查笔记.md>)）。

12. **角色卡 + 全局预设（Risuai）。** 角色拥有内容、资产、世界书与入场引导，会话内嵌于角色；模型、采样与装配预设独立于角色选择。提示词和开场白实时读取角色，消息另存生成元数据。候选仅在内存中，选中的正文可随消息保存，分支通过复制聊天保留。

13. **配置条目 + workspace 角色文件（OpenClaw）。** 角色边界是 `agents.entries.<agentId>` 配置条目与 workspace 文件组合：条目持有结构化 identity、workspace/agentDir、模型 primary/fallback 与工具/Skill/memory 策略；人格与规则文本落在 workspace 文件（AGENTS/SOUL/IDENTITY/USER/BOOTSTRAP/MEMORY），经 Project Context 注入提示词，且文本不能借此授予工具。会话经 route binding 与 `agent:<id>:...` key 绑定 Agent 命名空间，发送按当前配置与 session 覆盖重新解析；session 只持久化实际 provider/model 与 prompt/工具统计报告，不复制完整角色，逐消息角色版本未找到证据（未确认）。原 `src/claws/` 目录在当前快照中已不存在，与之相关的 portable Agent/identity 子集导出与漂移检查没有对应实现，只剩渠道安装入口与 Claw 包生命周期租约。

14. **派生/冷读投影（Codex）。** 命名预设为子线程提供开发者指令、模型与有限的能力收窄，审批和沙箱仍以父回合为准。派生及 V2 冷加载重读角色文件，驻留线程复用运行态；来源角色名未冻结实现版本。工作区指令另走独立通道。

15. **双配置 + 会话键编码身份（OpenOcta）。** 数字员工是 `employees/<id>/manifest.json` 模板，持有单段 Prompt、技能引用与专属 MCP；`agents.list` 条目持有 workspace、模型与身份展示名，但没有 Prompt 字段，两套结构没有共同基类。身份不靠外键，而是编码进 sessionKey（`agent:main:employee:<id>` 及兼容前缀），聊天入口从键中反解员工 ID，因此网页、IM 与 OpenAPI 入口共享同一员工会话。员工 Prompt 通过 SystemPromptOverrides 替换内置基础提示，随后仍追加技能、知识库与演进段落；模型、workspace 与工具归 Agent 或请求，员工不参与。`agents.*` RPC 为占位实现，普通 Agent 只能由配置文件提供。

最关键的横向差异在于：**修改角色后，既有会话下一轮使用新配置、旧快照，还是由全局设置覆盖**。这三种语义分别出现在 Open WebUI/AstrBot 一类的运行时解析、Chatbox/Jan/NextChat 的快照或副本，以及 Manifold Desktop 的全局当前值中。Hermes Agent 介于后两者之间：人格配置是全局当前值，但会话会记录构建好的 system prompt（hash 去重）与模型快照，而运行时注入的人格文本不随轨迹保存。Risuai 实时读取角色字段，同时保存消息正文与生成元数据；未选中的 reroll 候选不随主库存档。OpenClaw 属运行时引用的变体：session key 绑定 Agent 命名空间、不复制配置，下一轮按当前配置与 session 覆盖重解析；session 只保存实际模型与 prompt/工具统计报告，完整角色快照与逐消息角色版本未确认。

若单独比较**预设可配置范围与日常编辑体验**，结论会与“社区生态成熟度”不同：AIO Hub 是当前样本中最强的一体化候选。它把消息角色、顺序、锚点/深度、模型匹配、消息组、宏、变量、知识库占位符、资产附件、模型参数和工具策略放在同一个 Agent 编辑流程里；其中消息组可设多选或单选，并有组级总开关和侧边栏快速切换。它还自带世界书编辑器与运行时，支持关键词/正则、selective、概率、扫描深度、递归、过滤、包含组与 depth 注入等可执行子集。SillyTavern 的优势仍是角色卡标准、社区资产、传统角色扮演工作流、扩展事件和 World Info 全语义覆盖；这不能简化为“AIO 的角色能力远弱于酒馆”，也不能反过来用 AIO 的配置聚合优势否定酒馆生态。

跨项目比较酒馆兼容时，应拆成四层：格式能否导入、字段能否保留/编辑、字段是否在目标运行时生效、原生态协议是否完整复现。AIO 前三层已有相当覆盖，第四层并不完整：部分锚点降级映射，sticky、cooldown、delay 这些状态虽有运行时处理却缺少编辑控件，另一些扩展字段只能保存或编辑但未找到消费链。Risuai 同属酒馆生态入口：V2/V3、PNG、JSON、CharX 都能导入且主要字段进入运行时，但对 ST 扩展字段采用内联装饰符转译，字段能生效却不再保留原结构。用一个“支持/不支持”标签会同时掩盖它已有的能力和真实边界。

Cherry Studio 的 Agent 驱动覆盖 Claude Code、Pi 与 Pi-Durable；DeepSeek Harness 是独立受管 Web 子进程。这些执行配置各有模型与权限交接，普通 Assistant 的角色实体仍保持独立。VCPChat 的当前 Tavern 与群聊调整同样没有新增角色版本、渠道绑定或持久化角色实体，仍应按本地 Agent/群组配置与 Tavern 规则的组合比较。

### DeepSeek Harness

DeepSeek Harness 的比较单位是可修订插件组合，注册表管理声明、激活审计与引用生命期，Agent 保留已绑定修订。它适合表达“人格与运行能力共同装配”，模型路由仍由独立会话选择控制；与固定角色卡或仅提示词模板的边界不同。详细绑定与恢复见[角色笔记](<./DeepSeek-Harness-Agent角色调查笔记.md>)。

### Risuai

Risuai 将角色内容与全局模型预设分开，既有聊天实时读取角色提示与开场白，历史正文和生成元数据独立保存。候选文本不持久化，选中正文可落盘；角色交换覆盖酒馆格式，但世界书扩展采用装饰符转译。工具目录归全局模块，脚本低级权限及插件宿主 API 授权另有边界（[角色](./Risuai-Agent角色配置调查笔记.md)、[会话](../会话与消息管理/Risuai-会话与消息管理调查笔记.md)、[权限](../Agent工具/Risuai-Agent工具调查笔记.md)）。

### RikkaHub

RikkaHub 的 Assistant 在设置中聚合人格、模型参数、工具、注入与外观。会话创建时复制部分执行配置，后续可在聊天页独立调整；其余人格、采样、本地工具和记忆开关继续读取绑定助手当前值，形成部分快照与实时引用的混合语义。

历史消息保存模型标识与响应；旧助手的完整配置需另行核对。记忆另属按助手隔离的 Markdown 文件库，工具与注入的执行边界见相邻类目；角色转移主要依靠整体设置备份（[来源](<./RikkaHub-Agent角色配置调查笔记.md>)）。

## 架构分型

| 分型 | 项目 | 角色载体 | 主要所有权边界 |
| --- | --- | --- | --- |
| 配置聚合 | AIO Hub | `ChatAgent` / `AgentPreset` | Agent 拥有消息树、模型引用、参数、工具、知识和资产 |
| 配置聚合 | Cherry Studio | `Assistant` | Assistant 拥有模型、prompt、参数、MCP/知识库引用 |
| 配置聚合 | LobeHub | `LobeAgentConfig` | Agent 拥有人格、模型、chatConfig、插件、知识、文件和记忆策略 |
| 配置聚合 | DeepChat | Agent descriptor + session policy | descriptor 拥有运行时配置，session 保存 agent id 和覆盖项 |
| 配置聚合 | RikkaHub | Assistant 设置对象 + ConversationConfig | 角色聚合人格与能力；会话复制部分执行配置并可独立调整，其余字段实时引用 |
| 人格模板 | AstrBot | `Persona` | Persona 拥有指令、开场对话和能力白名单，Provider/模型在外层 |
| 人格模板 | Chatbox | `CopilotDetail` | Copilot 只拥有人格；模型和工具能力归 Session |
| 线程快照 | Jan | `Assistant` + `ThreadAssistantInfo` | Assistant 是模板，thread 内嵌使用时快照 |
| 会话副本 | NextChat | `Mask` + `ChatSession.mask` | Mask 是模板，新会话复制完整配置 |
| 模型预设 | Open WebUI | Workspace `Model` | 自定义模型同时承担 persona、参数、能力和权限 |
| 角色卡 | SillyTavern | Character Card | 卡片拥有可移植角色内容，运行参数归应用 Preset |
| Agent 目录 | VCPChat | `{agentId}/config.json` | Agent 拥有 prompt、模型、参数和 topic 列表，工具归服务端 |
| 移动端持久化 Agent | VCPMobile | SQLite `agents` 表 | Agent 拥有双层提示词、裸模型 ID、参数和话题；网关凭据归全局设置，工具归远端 VCP 调度；语音配置与 Agent 本地设置备份属本机扩展，不进入同步提示词 |
| 服务端双层 | VCPToolBox | `Agent/*.txt` + AgentAssistant | 文本层负责变量注入，插件层负责多 Agent 身份和委托 |
| 全局设置 | Manifold Desktop | `AppSettings.systemPrompt` | 没有角色或会话级配置对象 |
| 全局提示词 + Profile 容器 | Hermes Agent | `SOUL.md` + `agent.personalities`（`display.personality` 选中名称即权威）+ `agent.system_prompt`（用户手动提示词） | 角色本身只是提示词层；模型、工具、记忆和参数归全局/渠道/Profile 配置 |
| 文件约定 | Pi | `SYSTEM.md` + `APPEND_SYSTEM.md` + `AGENTS.md` 链 + skills | 提示词是 cwd 解析的文本资源；模型/参数归会话与设置 |
| 声明式组合 | DeepSeek Harness | 普通插件行声明及注册表修订 | 组合提供提示词、工具与服务；Agent 绑定修订，模型与生成参数独立 |
| 配置对象 + 内置模板 | OpenCode | `Agent.Info`（配置构建的内存对象）+ `{agent,agents}/**/*.md` | Agent 拥有 prompt、model/variant/参数、permission 与 steps；会话只存名字引用 |
| 角色卡 + 全局预设 | Risuai | `character` / `groupChat`（独立持久化对象，`chaId` 标识；角色含 `onboarding` 入场引导字段） | 角色持有提示词与内容字段；模型、采样参数、装配顺序和工具归全局 Database 与预设 |
| 配置条目 + workspace 文件 | OpenClaw | `agents.entries.<agentId>` 配置条目 + workspace 角色文件（AGENTS/SOUL/IDENTITY/USER/BOOTSTRAP/MEMORY.md） | 配置条目拥有身份、workspace、模型、工具/Skill/memory 策略与 sandbox；workspace 文件提供人格与规则文本，属 prompt 内容而非授权源 |
| 派生时投影 | Codex | `agents.<role>` 声明 + `agents/**/*.toml` 角色文件 + 内置 `default`/`explorer`/`worker` | 角色只投影子线程的开发者指令、模型与少量开关，且只允许收窄；工具、审批与沙箱归父会话 |
| 双配置 + 会话键绑定 | OpenOcta | 数字员工 `manifest.json` + `agents.list` 条目 | 员工持有 Prompt、技能与专属 MCP；Agent 持有 workspace、模型与身份名；身份由 sessionKey 编码，无统一角色实体 |

## 实体、存储与会话绑定

| 项目 | 稳定实体与标识 | 持久化粒度 | 会话如何选择角色 | 历史快照语义 |
| --- | --- | --- | --- | --- |
| AIO Hub | `ChatAgent.id`；预设与实例分离 | 每 Agent 一个 `agent.json` + 索引 + 资产目录；会话另存消息树 | 会话索引保存 `displayAgentId`；每次发送、续写、重新生成按 Agent ID 读取当前配置 | **实时引用 + 局部快照**：开场白在首次发送后固化为消息；旧回复保留，生成节点保存 Agent/模型/请求参数元数据；完整 Agent 配置不随会话冻结 |
| AstrBot | `Persona.persona_id`，显示名即 ID | SQLite `personas` 行 + v3 运行时缓存 | 会话规则强制值 > 对话 `persona_id` > Provider 默认 > webchat 特例 | 每轮重新解析 Persona；`begin_dialogs` 每轮重注入且 `_no_save`；消息对象不保存 persona_id/模型名，当次实际模型记录在 trace 日志与 `provider_stat` 表；切换后旧历史行为未实测 |
| Chatbox | Copilot id 与会话关联 | 模板、Soul/记忆和会话分别存储；会话另存提示上下文快照 | Chat Mode 使用会话提示与记忆，Work Mode 将 Copilot 叠加进 Soul | **冻结上下文**：首次需要时捕获，工作目录变化全量重捕获，记忆 scope 变化只刷新记忆切片；重新生成通常 fork 保留旧回复 |
| Cherry Studio | `Assistant.id` UUID | SQLite `assistant` 行 + MCP/知识库中间表；topic 存 `assistantId` 引用 | topic 保存 `assistantId`；每次请求按 id 重读 Assistant（`assistantDataService.getById`） | **实时引用 + 消息快照**：消息存 `modelId` 与 `messageSnapshot`（作者身份+模型快照）；重新生成在原用户消息下新建 assistant 兄弟分支（`siblingsGroupId`），旧回复保留 |
| DeepChat | descriptor id；内置 `deepchat` 受保护 | Agent row 内 JSON config；session row 单独存 `generationSettings` 等策略 | session 保存 `agent_id`、project、kind、parent 和 orchestration policy | **创建时快照 + 工具实时**：systemPrompt/生成参数在会话创建时快照进 session 行，发送不重读 descriptor（除非显式换 Agent）；工具/记忆策略按 agent_id 实时重读；descriptor 无版本字段；重新生成是破坏性替换（删源消息起全部再重发） |
| DeepSeek Harness | 声明中的稳定 id；运行期另有组合修订 | 组合配置中的插件行，由 bundle patch 安装；注册表不扫描目录 | 创建或恢复时绑定 scope 父链；只允许 blank 期改选 | **修订绑定 + 身份日志**：更新后运行 Agent 保留旧修订，引用归零回收；日志保存身份与选择事件，旧实现不跨进程保留 |
| Dify | AppModelConfig；Agent v2 另有 roster/draft/revision | 应用 active config 与 Agent v2 版本化配置分开持久化 | 终端用户运行已发布 App；Agent v2 会话建立 generation binding | 传统应用后续调用读取 active config；Agent v2 已绑定会话固定 generation；完整 prompt 快照未确认 |
| Jan | `Assistant.id`；默认 `jan` | 每 Assistant 一个目录和 `assistant.json`；独立 CLI Agent 另用项目 `.jan/agent/agent.toml` 与用户 `~/.jan/config.toml`，旧 `jan serve`/`jan launch` 一键预接链已不在命令树；Cowork 子 Agent 的派发与写域隔离在 Rust `subagent.rs`，每个子 Agent 一个 git worktree | 创建 thread 时写入 `ThreadAssistantInfo` | **嵌入快照**：name/model/instructions/tools 被复制进 thread；thread 发送读内嵌快照的 instructions/parameters，不读 Assistant 当前配置；消息本身不保存模型/参数元数据；重新生成保留旧回复为 sibling（parentId/activeRootId 版本切换） |
| LobeHub | Agent id + `LobeAgentConfig` | 后端数据库（messages/topics 表含 model/provider 列），前端 store 缓存编辑态 | 发送时按 agentId 从 DB 读当前配置（`agentService.getAgentConfigById`），会话不存配置副本 | **实时引用 + 消息模型快照**：assistant 消息与 topic 记录 model/provider；开场白不落库、空会话实时渲染；regenerate 先删旧消息再重生成（覆盖语义） |
| Manifold Desktop | 无角色实体 | `%LOCALAPPDATA%\Manifold\settings.json` 全局单值 | 所有会话读取同一全局 system prompt | **无快照且消息不落盘**：前端 `session-store.js` 无任何引用（死模块），聊天消息仅存内存数组；`SAVE_SESSION` 只写 title；无 regenerate（Retry 仅移除错误元素） |
| NextChat | `Mask.id` | 用户 Mask 与会话分别持久化 | 新会话复制 Mask 顶层和模型配置，嵌套数组未递归克隆 | **可变副本**：fork 重分配消息 id、重置摘要与上下文清除位置，嵌套内容仍可共享；模板保存无主动回写，全局模型同步另行生效 |
| Open WebUI | Workspace Model `id` | DB `Model` 行：`params/meta` JSON + access grants | 前端按 model id 请求，服务端路由按 id 重新读 DB；chat 表 JSON 列另存 `models` 列表与 `chat.params` 覆盖 | **运行时引用 + 局部快照**：assistant 消息有 `model_id` 列但无 params 快照；chat 级 params 随 chat 保存并随请求发送，与模型 params 并存；regenerate 纯前端在 parent 下新建 assistant 兄弟消息（不替换原消息） |
| SillyTavern | Character Card 名称/文件 | `characters/` 下 PNG、JSON、CharX 或 BYAF | 应用选择角色卡；User Persona 另属全局/单会话层 | **创建时快照 + tainted 固化**：开场白（first_mes/alternate_greetings 转 swipes）随 JSONL 落盘；未 tainted 聊天在改卡后可整体重建开场白，首次生成后 `tainted` 置位固化；每次生成重读角色卡当前值；消息/每个 swipe 快照 `extra.api/model`，无温度/预设快照；swipe 追加保留旧回复，regenerate 删除末条助手消息重建 |
| VCPChat | Agent 目录名 `agentId` | 每 Agent 目录：配置、规则、头像；每 topic 一个 `history.json` | 先选 Agent，再选其 topic；发送用 `currentSelectedItem.config` 内存缓存引用（设置保存/话题加载时刷新） | topic 历史与 Agent 配置分存；消息只含 role/name/content/timestamp/id/attachments，无模型/参数元数据；重新生成时重读最新配置并截断原消息及其后全部消息重建（覆盖语义）；分支是 topic 级 |
| VCPMobile | `agent_id`（名称可用字符 + 创建时间）；无版本字段 | SQLite `agents` 表；头像独立表；每 Agent 拥有多个话题 | 当前会话保存 `agent_id/topicId`；发送前实时读取 Agent 配置 | **实时引用、无完整消息快照**：历史消息不携带角色/参数快照；未验证历史重放或重新生成的快照语义 |
| VCPToolBox | 文件别名或 AgentAssistant `baseName/chineseName` | `.txt` + `agent_map.json`；插件 `config.json` | 变量引用、AgentAssistant 通信或 TaskAssistant 派发 | **无快照**：会话历史只存 `{role, content}` 裸消息对；每次请求从内存 `AGENTS` 映射现拼 payload（model/max_tokens/temperature）；config.json 仅 initialize/reloadConfig 时读取，Admin Panel 保存后热重载；无 regenerate API，OneRing 提供内容原地替换 |
| Hermes Agent | 无角色实体；`personalities` 名称、SOUL.md 文件名 | `config.yaml`（agent.personalities / agent.system_prompt / display.personality）+ `$HERMES_HOME/SOUL.md` + Profile 目录 | `/personality` 写 `display.personality` 名称（不写 `agent.system_prompt`）；TUI 会话可存 `personality` 覆盖键；Profile 独立选择 | 会话保存构建后的 system prompt（sha256 全文去重）与 model/model_config；人格当前文本不入轨迹，属"全局当前值 + 提示词快照"；retry_last 复用内存缓存不重建；存储 prompt 与运行时比对只检查尾部 Model/Provider 行，修改人格文本不判 stale |
| Pi | 无角色实体；文件即配置 | `SYSTEM.md`/`APPEND_SYSTEM.md`（全局 `~/.pi/agent/` 或项目 `.pi/`）+ `AGENTS.md` 链 + skills 文件 | 资源按会话 cwd 解析；无角色选择入口，`/reload` 重载文件 | 无快照：system prompt 不随会话条目保存（仅 HTML 导出含快照）；AssistantMessage 随消息记录 provider/model/usage/stopReason（无采样参数）；无用户级 retry/regenerate 命令，瞬时错误自动重试 |
| OpenCode | `Agent.Info.name`（配置构建）；无独立版本字段 | 配置对象（`opencode.json` 的 `agent`/`mode` 字段 + `{agent,agents}/**/*.md` + `{mode,modes}/*.md`）；无 agent 表 | 输入框/对话框/`--agent`/`@` 提及选择；session 表保存 agent 名（`core/src/session/sql.ts:51`），发送时 `setAgentModel` 同步 | **引用 + 消息快照**：session 与消息各存 agent/model 字段（含 variant/tools，无温度等参数）；undo/revert 是物理删除 revert 点之后的消息再重发（非分支对比），重发时重建 agent 重新解析当前配置；分支手段只有 `session.fork`；part 不携带请求参数元数据 |
| Risuai | 角色 UUID；无版本字段 | 角色内嵌聊天，主库存档按块编码，remote 与冷归档可外置 | 当前角色与角色内聊天指针共同选择，生成中拒绝换角色 | **实时引用 + 生成元数据**：开场白实时取角色字段，正文与已选候选随消息保存；未选候选内存保留，分支复制成独立聊天 |
| OpenClaw | `agents.entries` 的 key 即 Agent ID（schema 约束标识，无通用版本字段）；Gateway 可另投影 system-agent rows | `openclaw.json` roster + 每 Agent workspace/`agentDir` + Agent-scoped state（`agents/<id>/agent/openclaw-agent.sqlite`、sessions 目录）；canonical workspace 文件集合为常量 | route binding（channel/account/peer/guild/role）映射 Agent，session key 以 `agent:<id>:...` 命名空间绑定；显式 Agent 与 key 不一致被拒；多 Agent 无 owner 时要求显式选择 | **运行时引用 + 运行时事实快照**：session 保存实际 provider/model、session override、Skill snapshot 与 prompt 统计报告，不复制完整角色；逐消息完整角色快照未找到证据（未确认） |
| RikkaHub | Assistant UUID；无完整角色版本 | 设置 JSON 保存助手，会话数据库保存部分执行配置；记忆为独立文件库 | 会话绑定助手 id，模型/搜索/能力子集由会话配置覆盖 | **混合**：部分创建时快照可在会话内修改，其余每轮读取助手；消息保存模型与响应，无法还原完整旧配置 |
| Codex | 角色名；无不可变版本 | 配置声明与角色 TOML；线程记录角色来源 | 常规 spawn 缺省应用 default，全历史 fork 缺省跳过；隐式 default 来源仅 V2 非全历史且有用户配置时记录 | **派生/冷读投影**：spawn 重读文件，V2 冷加载按保存来源再应用；已驻留线程复用运行态，历史无完整角色快照 |
| OpenOcta | 员工 `id`（目录名，创建时直接取名称）与 `agents.list` 条目的 `id`；均无版本字段 | 每员工一个 `employees/<id>/manifest.json` 加独占技能目录；Agent 配置在主配置文件；会话条目存技能快照与指针 | 员工身份编码进 sessionKey（`agent:main:employee:<id>` 及兼容前缀），Agent ID 取键的第二段 | **运行时引用 + 技能快照**：每轮按 sessionKey 重读 Manifest 与 Agent 配置，运行时按指纹复用；会话只稳定写技能快照，系统提示报告与工具列表未找到填充点；删除员工连带删除其会话 |

这里可以明确区分四种继承模型：

```text
运行时引用：AIO Hub / AstrBot / Open WebUI
  会话保存 ID，下一轮重新解析当前配置

冻结或嵌入快照：Chatbox / Jan
  首次需要时冻结身份上下文，或创建线程时嵌入配置；后续刷新条件各异

可变会话副本：NextChat
  复制顶层 Mask 与模型配置，嵌套引用和 fork 重置范围另有边界

全局当前值：Manifold Desktop
  所有会话共享当前设置，历史不保存当时配置
```

Pi 介于“全局当前值”与“运行时引用”之间：提示词文件在会话创建或 `/reload` 时读取，同一会话内每轮使用已加载内容，不逐轮重读文件；切换 cwd 即换一套文件资源。其会话文件不保存任何提示词快照，与 Manifold Desktop 一样无法从历史复原当时提示词。

OpenCode 属于“运行时引用”的变体：会话只保存 agent 名字与当时的 model 快照，下一轮生成时按当前配置重新构建 agent 与权限；但每条消息额外带 agent/model 字段，使历史渲染仍能显示当时的角色与模型，而 Manifold Desktop 与 Pi 都做不到这一点。

AIO Hub 是运行时引用的混合形态：开始对话前，开场白候选仍会随 Agent 同步；第一次发送后，全部开场白分支固化为会话消息。其余 Agent 配置在每次发送、续写和重新生成时重新读取，重新生成则基于同一用户节点创建新的助手兄弟分支。这种设计优先支持在相同历史下修改 Agent 后即时对比，不把会话做成完整角色版本快照。

混合模型须继续区分配置切片与刷新时点。RikkaHub 和 DeepChat 将部分配置固定到会话，其余实时读取；SillyTavern 与 Risuai 将角色内容、开场白和历史正文分别处理。DeepSeek Harness 绑定运行期组合修订，Codex 在派生与 V2 冷加载时投影当前角色；身份日志都不足以永久保留旧实现。OpenClaw、OpenOcta 保存的运行事实或技能快照，也只覆盖完整角色的一部分。具体字段边界见上表。

## 提示词、模型与参数

| 项目 | 人格内容形态 | 已确认的装配或优先级 | 模型与生成参数所有者 |
| --- | --- | --- | --- |
| AIO Hub | 有序消息树与消息组；单条正文可由片段及可选版本组合 | 先验证组与编译有效版本，再展开宏与附件并按深度/锚点注入；动态锚点保留工具链边界 | 模型绑定与参数归 Agent；审批模型配置是全局设置，角色保存审批策略 |
| AstrBot | 人格提示与成对示例消息 | 人格追加进 system，后续能力与环境仍可追加；示例置于历史前且不入库，每轮重读 | Persona 不绑定模型，渠道与模型归外层配置 |
| Chatbox | Copilot、Soul 与 Memories 分层 | Work Mode 按身份、Soul 内角色叠加、记忆、工具和运行信息拼接；Chat Mode 不注入 Soul，仍可读冻结记忆 | 模型与采样归 Session，角色不绑定渠道 |
| Cherry Studio | 单段 `prompt`，支持变量 | Assistant prompt 先写入；存在 `tool_search` 时再追加 deferred-tools 提示 | Assistant 保存 `modelId` 与 `AssistantSettings` |
| DeepChat | descriptor `systemPrompt` | `PromptAssemblyService.build` → `buildSystemPromptWithSkills` 九段拼接（basePrompt 最前，`systemPromptBuilder.ts:260-268`）；ACP 子会话直返原文 | Agent config 保存多种模型 preset 与生成参数 |
| DeepSeek Harness | 分层提示 section；persona 前后缀占固定槽位 | Agent、组合、全局就近覆盖，其余按顺序拼接；完整替换可保留单段，工作区指令另作 user 上下文 | 模型选择独立并在每步准备时冻结，该步重试沿用；角色不拥有采样参数 |
| Dify | AppModelConfig 的 simple/advanced prompt；Agent v2 是版本化 Soul/配置 | simple transform 按模型把预提示、变量、上下文、历史与 query 变为消息或 completion；最终顺序受应用模式影响 | 模型与凭据由租户 Provider 解析；应用配置可选择模型和参数 |
| Jan | 单段 `instructions`，支持 `{{current_date}}` | 从 thread 快照渲染 system prompt；只有非 `model-only` Assistant 才采用其参数 | Assistant/thread 快照保存模型；web/core 参数形状仍有未确认差异 |
| LobeHub | `systemRole` + `fewShots`（字段存在）+ opening + input template | 输入模板位置已确认；**fewShots 在 `src/` 与 `packages/agent-runtime/` 无消费点**（仅类型、DB schema、市场导入映射引用），运行时请求只传 `systemRole`，其实际注入效果未确认 | Agent 保存 `provider/model/params` 与大量 chatConfig |
| Manifold Desktop | 全局单段 `systemPrompt` | OpenAI 放消息首部，Anthropic 放顶层 `system`，Gemini 放 `systemInstruction` | 全局 `activeProviderId/model/temperature` |
| NextChat | 有序示例上下文与输入模板 | 系统提示、记忆、角色示例、历史再接本轮输入；纯文本展开模板，图片输入以原文覆盖展开结果，MCP 回注跳过模板 | 会话 Mask 副本保存模型配置，可继续同步全局默认 |
| Open WebUI | `params.system`，支持 chat/user/metadata/旧式变量 | 参数为全局默认 < 模型 params < 请求 params；模型 system 在出站时前置到已有 system 内容 | Workspace Model 保存基础模型引用和任意参数；请求仍可覆盖 |
| SillyTavern | description/personality/scenario/system/示例/post-history 分字段 | 非空 `system_prompt` 覆盖全局；`post_history_instructions` 放历史末尾；其他字段位置可由 Advanced Formatting 调整 | 角色卡不存模型参数；模型与生成参数归 Preset/连接设置 |
| VCPChat | 单段 `systemPrompt` + `{{AgentName}}` | Agent system prompt 后应用全局 Tavern `system_suffix`；另有 user suffix 和 context depth 注入 | Agent 保存裸 model id、temperature、上下文和输出上限 |
| VCPMobile | `mobile_system_prompt` + 同步 `system_prompt` | mobile 提示词非空时覆盖同步提示词；有效提示词再与历史和 Tavern 上下文装配 | Agent 保存裸模型 ID、token 限制、stream 与可选 temperature；网关 URL/Key 归全局设置 |
| VCPToolBox | `.txt` 变量模板或 AgentAssistant `systemPrompt` | 多阶段替换 Var/Tar/Sar/VCP/TagMemo/agent/TVStxt；AgentAssistant `globalSystemPrompt` 追加到所有 Agent | AgentAssistant 每个 Agent 保存 modelId、temperature、maxOutputTokens；文本文件层不拥有模型 |
| Hermes Agent | SOUL.md 文本 + `personalities` 单段提示（string 或 dict） | SOUL/默认身份 → 稳定指引 → 项目上下文（.hermes.md>AGENTS.md>CLAUDE.md>.cursorrules）→ 技能/记忆/USER.md/时间行 → 调用时附加 ephemeral（ephemeral 文本由 `resolve_ephemeral_system_prompt_from_config` 解析，`display.personality` 命名人格优先于 `agent.system_prompt`，env 最优先）；一次构建缓存、压缩时重建 | 人格不绑定模型；模型归全局 `model:`/session `/model`/ChannelOverride/Profile；温度与 max_tokens 由 Provider 适配层解析 |
| Pi | SYSTEM.md（整篇替换）+ APPEND_SYSTEM.md（追加）| 自定义时：SYSTEM → APPEND → `<project_context>`（AGENTS/CLAUDE 链）→ skills 索引 → cwd；默认模板时：开场+工具列表+guidelines+文档指引 → APPEND → context → skills → cwd；`before_agent_start` 扩展可当轮整篇覆盖 | 模型/思考等级是会话级状态（`model_change` 条目），默认值在全局+项目设置；无角色级生成参数 |
| OpenCode | agent `prompt`（markdown 正文原样）或空 | 两段拼装：`agent.prompt ?? provider 风格提示` → env/AGENTS.md 指令/MCP 指令/skills → user.system（`llm/request.ts:56-66`、`session/prompt.ts:1257-1271`）；AGENTS.md 按全局→项目祖先链加载（`session/instruction.ts:110-153`） | Agent 可绑 `model`/`variant`/`temperature`/`top_p`/`options`；生效 `input.model ?? agent.model ?? session.model ?? provider.defaultModel()`（prompt.ts:646、614-633）；切换 agent 默认继承上一模型 |
| Risuai | 描述、人格、场景、示例、开场白与深度提示 | 全局顺序或模板卡片拼装；角色主提示与备注可覆盖全局占位，开场白实时取字段而不固化进历史 | 模型和采样归全局预设，角色与聊天未绑定预设 |
| OpenClaw | workspace 文件：SOUL.md（persona/tone）、USER.md（用户偏好）、IDENTITY.md、AGENTS.md（操作规则）；config `identity` 是结构化元数据，不是整段人格文本 | 稳定前缀与 volatile 后缀分别渲染，workspace 文件经 Project Context 注入并按 basename 排序；无单一优先级链，model/Skill/工具/workspace 各走 resolver（Agent primary 优先于 defaults primary）；bootstrap 受注入模式与每文件/总量上限控制 | Agent entry `model`（primary/fallback）归 Agent；session 可持久化 user/auto 覆盖；`params` 是 per-Provider 任意容器，完整 merge 顺序未跟踪 |
| RikkaHub | 单段 `systemPrompt`（支持占位变量）+ `messageTemplate` + `presetMessages` + 模式/正则注入 | systemPrompt 作为首条合成 system 消息；会话覆盖开关允许时用 `customSystemPrompt` 整体替换助手版本；注入按 `priority` 降序、按位置枚举（系统提示词前后、对话首尾、深度）分组插入；占位变量与 Pebble 模板发送前替换 | 模型和推理等优先取会话固定值，失效时回退助手/全局；采样参数读助手当前值，null 表示不发送 |
| Codex | 角色文件里的 `developer_instructions` 单段文本；无结构化人格、示例对话、开场白或变量字段 | 角色层替换子线程的开发者指令，并排在开发者片段最前；随后是世界状态片段（含 AGENTS.md、权限、环境与工具清单）和多 Agent 模式消息；AGENTS.md 以 user 角色注入，默认总预算 32768 字节 | 角色可固定模型、推理强度、推理摘要、输出详略、人格与服务档位；温度、`top_p` 和最大输出 token 不在角色可用字段中（本次未找到） |
| OpenOcta | 员工 Prompt 单段纯文本；无模板变量、示例对话、独立 Persona、开场白或角色级参数 | 非空时替换内置基础系统提示，之后依次追加技能说明（无 Eino 技能中间件时）、知识库说明与演进段落；另按消息内容追加本地 CLI 提示 | 模型归 `agents.list[].model`，请求 `modelRef` 优先、defaults 兜底；员工不参与；无角色级采样参数 |

提示词“优先级”在不同项目中有三种动作，不能统一写成覆盖关系：

| 动作 | 项目示例 | 语义 |
| --- | --- | --- |
| 替换 | SillyTavern 非空 `system_prompt` | 角色卡 system 取代应用 Preset system |
| 前置/追加 | Open WebUI、AstrBot、Cherry Studio、VCPChat、Hermes Agent | 多段 prompt 共存，位置决定约束先后 |
| 消息级插入 | AIO Hub、NextChat、SillyTavern depth/world info | 内容以 system/user/assistant 消息或历史深度进入上下文 |

因此，只比较一个 system prompt 字段是否存在，会遗漏 AIO Hub 的锚点消息、SillyTavern 的历史末尾指令和 NextChat 的多角色上下文，也会误把 Open WebUI 的参数覆盖顺序当成 system prompt 替换顺序。

## 工具、知识与记忆

| 项目 | 角色级工具/能力控制 | 角色级知识 | 记忆与状态 |
| --- | --- | --- | --- |
| AIO Hub | Agent 保存工具/方法控制与审批策略；是否允许被派发、模型继承与嵌套深度另有子智能体声明；仲裁模型归全局 | 世界书有编辑与运行时；Knowledge 访问授权与 Recall 自动召回分开 | 会话变量、非破坏性摘要压缩与虚拟时间，各有运行消费点 |
| AstrBot | tools 三态作用于 Persona 装配阶段，后续内置能力可追加；skills 空集合同时禁止工作区技能 | KB 走用户消息侧注入 | Persona 无长期记忆字段；权限代理覆盖另依目录装配入口，角色名单与执行授权分开比较 |
| Chatbox | Skills、运行模式、MCP 和工作目录由会话/全局装配 | 附件 RAG 属会话，知识库模型归全局 | Soul 与长期事实分存，Copilot 可独立记忆 scope；会话冻结上下文，作用域改变时刷新记忆切片 |
| Cherry Studio | Assistant 绑定有序 MCP server 列表和模式；Agent Session 另走 Claude Code 工具路径 | Assistant 绑定有序知识库列表 | 角色笔记未找到 Assistant 长期记忆字段 |
| DeepChat | Agent 保存权限模式、禁用工具、Skills、MCP 和 subagent slots | 未作为独立角色字段总结 | Agent 保存 memory 检索/抽取/预算、自动压缩和 persona evolution 开关 |
| DeepSeek Harness | 插件组合声明工具与服务，实际可见性叠加每步准入；组合本身不构成沙箱 | 工作区指令由独立插件注入，Skill 资源随安装组合提供 | 会话日志与压缩；角色层未找到跨会话自动记忆 |
| Dify | 传统 Agent/Agent v2 可配置内置、API、插件、MCP 与 workflow 工具 | 数据集和检索是应用配置/工作流资源，不是通用角色卡字段 | 记忆、检索和运行时效果依赖应用模式；未归纳为统一角色字段 |
| Jan | `AssistantTool` 当前只定义 retrieval，默认关闭 | `file_ids` + retrieval 工具定义；web 持久化链路未确认 | 未提供独立长期记忆字段 |
| LobeHub | 插件有 pinned/auto/disabled，另有 agent/chat/custom 工具模式和异构 Agent；共享 Agent 的访客运行不继承创建者全部外部能力，Agent Share 会剥离文件、知识库、异构 Agent 与设备能力并按 tool grants 收窄工具 | 每 Agent 绑定知识库与文件 | `memory.enabled/effort/toolPermission` 明确区分只读与读写，另有压缩和自迭代 |
| Manifold Desktop | 无角色级工具配置 | 无角色级知识配置 | 无角色级记忆；历史不保存 prompt/temperature |
| NextChat | `Mask.plugin` 绑定 OpenAPI 插件 id，但无角色级权限、审批或参数范围 | 未提供 Mask 知识库字段 | 请求可注入长期记忆摘要，但单项目笔记未把记忆所有权归入 Mask |
| Open WebUI | Model meta 绑定 tools、skills、filters、builtin tools、terminal 和能力开关，并叠加 access grants | `meta.knowledge` 引用集合/文件 | memory 是可选内置 feature；角色笔记未确认 per-model 长期记忆命名空间 |
| SillyTavern | 角色卡核心不承载工具授权；extensions 可扩展，工具安全另见工具笔记 | 内嵌 Character Book + 外部 World Info | User Persona 独立；角色卡本身无通用长期记忆字段 |
| VCPChat | Agent config 无工具开关，工具由 VCP 服务端和全局连接决定 | 未提供角色级知识库字段 | 每 topic 独立历史；无已确认的长期记忆配置 |
| VCPMobile | Agent 配置未找到工具、MCP、Skill、知识库或记忆字段；设备工具另由用户显式启用后供远端 VCP 调度 | 未提供角色级知识库字段 | 每 Agent 多话题；无已确认的长期记忆配置 |
| VCPToolBox | 提示注入决定可见工具说明，执行仍受全局审批；JEV 声明可展开真实调用，不只是说明素材 | 日记/知识变量在可信载体中召回 | 委托历史有轮数与 TTL；OneRing 可另存跨请求消息，AgentDream 独立整理记忆 |
| Hermes Agent | 人格/提示词不授权工具；工具开关在平台级 `tools.<platform>` 与 `hermes tools`，工具加载与否才影响指引注入 | SOUL.md 是身份文本；项目 AGENTS.md/.cursorrules 随 cwd 提供；无角色级知识库字段 | MEMORY.md（agent 记忆）与 USER.md（用户画像）可注入 volatile 段；外部记忆 Provider（plugins/memory）追加提示；子 Agent 继承 ephemeral |
| Pi | 无角色级工具授权；工具激活集是会话级列表（默认 read/bash/edit/write），system prompt 只列带 snippet 的工具 | 无知识库；等价物是 `<project_context>` 上下文文件与 skills 文本 | 无独立记忆；长期记忆即会话历史+压缩摘要，跨会话无自动记忆 |
| OpenCode | agent `permission` 规则（`{pattern: action}`）+ 会话 permission 合并，运行时过滤工具/MCP/Skill 可见性（`llm/request.ts:208-214`、`session/tools.ts:81-89`）；`tools` 布尔字段已废弃 | 无角色级知识库字段；等价物是 AGENTS.md 指令与引用（reference） | 无角色级长期记忆；会话 todo 列表与压缩摘要（compaction）属会话状态 |
| Risuai | 全局 MCP 目录，角色低级脚本开关与插件宿主授权分开；插件写数据库需另授 dbWrite，不能推成角色工具白名单 | 角色、聊天与模块三源世界书，受角色预算约束 | 角色开关配合全局记忆算法，记忆与变量状态写入聊天 |
| OpenClaw | 工具目录按运行上下文重建，经 profile/global/provider/Agent/group/sender/sandbox/subagent/runtime/inherited 多层 policy 过滤后才可见；AGENTS.md/TOOLS 文本不能授予工具 | 已检查范围内未找到独立 knowledge/worldBook 字段（本次未找到）；workspace 文件、memory extra paths、Skill、MCP 可提供外部知识但生命周期与授权不同 | memory search 由顶层配置与 Agent `memory.search` override 合流，默认 Agent-scoped SQLite；MEMORY.md 自动加载前做 provenance 分类；USER.md 属用户偏好而非记忆 |
| RikkaHub | 会话配置与助手实时字段共同决定本轮能力，工具执行边界见 Agent 工具 | 未确认角色级向量知识库；注入与 Lorebook 按配置参与 | 按助手隔离的 Markdown 记忆库；目录/核心文件注入，其他按需读取，可后台整理 |
| Codex | 只能在五项白名单 feature 内关闭能力，并削减 skills；不能新增工具、放宽沙箱或提高审批等级，工具目录由父会话策略与模型能力决定 | 无角色级知识库；项目指令文件、skills 与 MCP 资源分别属指令或工具通道 | 无角色级记忆字段；子 Agent 数量与深度由 `agents` 表其他字段控制，不随角色变化 |
| OpenOcta | 员工只有 `skillIds` 与专属 `mcpServers`（与全局合并、同 key 员工覆盖）；无工具白名单或审批配置，工具取运行时默认集合与请求资源过滤 | `agents.list[].knowledge` 字段存在，但 `chat.send` 主链未找到读取点；员工无知识字段 | 无角色级记忆字段；会话按员工 ID 聚合，网页、IM 与 OpenAPI 共享同一员工会话 |

能力绑定可分成三种强度：

1. **显式策略对象**：AIO Hub、AstrBot、DeepChat、LobeHub、Cherry Studio。角色配置直接保存白名单、模式或服务器引用，运行时仍需结合全局注册状态和执行策略。
2. **会话或外层挂载**：Chatbox、Jan、NextChat、Open WebUI。人格模板本身未必拥有工具，但会话、模型预设或 thread 快照会携带能力信息。
3. **内容约定或服务端决定**：SillyTavern、VCPChat、VCPToolBox、Risuai。提示词/扩展/服务端暴露面决定模型看到什么，权限域落在提示词与扩展层面，角色文件本身不带权限声明；Risuai 的角色没有工具字段或白名单，工具是全局 MCP 模块。

## 导入、导出与兼容性

| 项目 | 已确认格式或入口 | 可移植范围与边界 |
| --- | --- | --- |
| AIO Hub | JSON/YAML；ZIP、文件夹、单文件、带数据 PNG；可导入 SillyTavern JSON/PNG | 可携带资产、世界书和多数 Agent 配置；本地 id/profileId 等实例字段剥离，目标端仍需重绑模型 |
| AstrBot | Dashboard JSON 导入；v3 config persona 自动迁移到 v4 DB | 冲突名称自动加后缀；旧 mood dialogs 拼入 system prompt；未见通用角色卡格式 |
| Chatbox | 应用备份 ZIP/JSON、远端 Copilot 市场；备份导出/导入逻辑位于 `chatbox-core` 包的 `backup-v3` | 主要携带单段 prompt 和元数据；模型、few-shot、工具不在 Copilot 中 |
| Cherry Studio | Resource Catalog / assistant transfer；v1 -> v2 migrator | 工具配置不随模板跨机器迁移；少样本和世界书没有 v2 原生对应 |
| DeepChat | 未调查独立 Agent 导入/导出 | descriptor 迁移和 UI 兼容分支未覆盖 |
| DeepSeek Harness | 通过 bundle patch 新增或覆盖声明行；读取面可呈现组合文本 | 注册表不接受目录复制或 YAML 写回；整份插件列表替换，失败声明仍可见并阻止新绑定 |
| Dify | 应用 DSL、Agent DSL | 迁移的是应用或 Agent 定义；跨租户会清理凭据、secret、token 和部分源工作区字段，不是角色卡交换格式 |
| Jan | 每 Assistant 一个 JSON，内建 v1/v2/v3 schema 迁移；无独立导入导出接口（跨设备迁移只能复制数据目录） | core/web 类型不一致，parameters/tools 的完整往返仍未确认 |
| LobeHub | 市场导入；完整 AgentConfig JSON 导出 | 可携带 Agent 配置；外部插件、知识库和模型资源仍依赖目标环境 |
| Manifold Desktop | 提示词库每条 JSON；角色导入不存在 | 只能复用文本，不能表达会话角色、模型包或能力绑定 |
| NextChat | 单个或数组 Mask JSON；URL `?mask=<id>` | 导入只检查 name，无 schema 版本、字段白名单或冲突策略；URL 只分享已有 id |
| Open WebUI | Workspace Models import/export/sync API | 逐条校验 knowledge 文件权限和写权限；模型、参数、meta 与 grants 是平台内对象 |
| SillyTavern | PNG、JSON、CharX、BYAF；V1 自动映射 V2，支持 V3 | 角色内容和内嵌资产/世界书可移植；模型参数和应用 Preset 不在角色卡中 |
| VCPChat | 无批量导入；UI 手工创建 | 可手工粘贴 system prompt；客户端 Agent 与服务端 AgentAssistant 需人工对应 |
| VCPMobile | 未找到角色包导入、导出或复制入口；Agent 级本机设置可导出与导入（`export_agent_local_settings`/`import_agent_local_settings`，带哈希与更新时间校验） | 可手工编辑本机移动提示词、Agent 参数和语音配置；同步提示词由服务端补回，设置备份不能当作角色包交换 |
| VCPToolBox | 放置 `.txt` 并登记 `agent_map.json`；Admin Panel 管 AgentAssistant | 文本容易导入，但 AIO 消息树、SillyTavern depth 等结构需展平，VCP 变量依赖服务端运行时 |
| Hermes Agent | `hermes import-agent`（Claude Code/Codex）；`hermes backup`/`import`；`hermes profile export/import`；`profile install/update`（distribution.yaml）；`hermes claw migrate`（OpenClaw） | 导入 CLAUDE.md/AGENTS.md/memories→MEMORY、权限→command 白名单、skills、MCP；凭据一律排除；persona 字段无导入承载；profile 分发默认含 SOUL.md/config/skills，用户数据目录绝不覆盖 |
| Pi | 无角色导入导出；`/export`（HTML/JSONL）只导出会话 | 角色即文件，复制文件即“导入”；无 schema 校验、无字段映射、无冲突处理 |
| OpenCode | 无导入导出命令；`opencode agent create`（CLI）由 LLM 生成带 frontmatter 的 markdown | 复制 markdown 文件即可携带角色；`opencode export` 只导出会话且 agent part 脱敏；V1→V2 配置迁移器自动映射字段（`core/src/v1/config/migrate.ts:35-125`） |
| Risuai | Tavern V2/V3、PNG（`chara`/`ccv3` 文本块）、JSON、CharX（ZIP）、Chub API、Risu Hub（realm）深链；导出默认 V3、可选 V2 | ST 世界书扩展字段内联成 `@@` 装饰符（即运行时语法）而非保留原结构；`extensions` 未知键保留但不保证消费；`virtualscript` 导入置空、`lowLevelAccess` 需确认；未找到 BYAF 支持；聊天单独支持 JSON/JSONL/HTML/TXT |
| OpenClaw | 普通 Agent 已检查的 CLI/Gateway/Control UI 入口未找到通用 clone/import/export；原 `src/claws/` 已不存在，portable 子集导出与漂移检查无对应实现；Claw 包 export/install 是独立 provenance/consent 流程；另有 legacy roster/`default` marker 与 doctor 迁移 | Claw manifest 可携带 Agent id/name/description、部分 identity 与 workspace 托管文件，并可冻结部分 tools/sandbox/memory/groupChat 设置；凭据与完整 AgentConfig 不随包通用导出；workspace 文件可复制但不构成角色包交换格式 |
| RikkaHub | 无助手级导出或分享入口；整体设置备份（`settings.json` 含全部助手）；导入 SillyTavern JSON/PNG（`chara_card_v2`/`v3`）与 Chatbox 会话 | 助手转移只能靠整体设置备份；ST 导入只映射名称、`first_mes`（转为 assistant 预设消息）、system_prompt+description+personality+scenario 拼接与 PNG 背景，示例对话与世界书不保留；Chatbox 导入的是会话并挂到当前选中助手 |
| Codex | 迁移依靠配置层与角色 TOML 文件，未找到角色包交换入口 | 目录发现要求名称与开发者指令；文件拒绝未知字段，角色声明内部未知键则忽略；同层同名取首项并告警 |
| OpenOcta | 员工 zip 站点安装（必须含 `config.json` 与 `README.md`，可选 `skill.zip`）与 `employees.create`；无导出或标准角色包 | 员工 zip 是安装格式而非双向交换格式，安装后来源标记为 remote；普通 Agent 没有创建 RPC；员工 ID 直接取名称，大小写敏感平台上可能与解析路径不一致 |

SillyTavern 的角色卡和 AIO Hub 的 Agent 包覆盖面最接近“可分享角色资产”，但两者的能力边界不同：SillyTavern 刻意把模型预设留在卡外，AIO Hub 导出则可以携带 Agent 参数、资产和世界书，同时剥离本机渠道引用。Risuai 与 SillyTavern 同侧：角色是纯内容容器，模型预设留在卡外，导出仅携带角色内容，ST 扩展字段以装饰符内联转译。Open WebUI、Cherry Studio、LobeHub 的导入更接近平台内模板或数据库对象迁移，外部资源引用不能只靠一份 JSON 保证生效。

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
| AIO Hub | 完整编辑器分离模型/上下文页面，支持组合片段版本与组选择；侧栏可直接改当前角色 | 完整编辑弹窗先存草稿，侧栏改动即更新角色；预设单条保存有修订比对。后续执行读当前配置，历史回复与已固化开场白保留 |
| AstrBot | Persona 选择器、会话规则、能力三态和 trace 记录 | 下一轮按优先级重解析；被删除引用可静默回落，第三方 runner 不注入 Persona；消息对象不保存 persona_id/模型名，当次模型记录在 trace 与 `provider_stat` 表 |
| Chatbox | 会话显示模型、Copilot、Work Mode 与记忆入口 | Soul/记忆写入默认影响未来快照；工作目录或 scope 改变触发相应重捕获；重新生成通常保留旧回复为 fork |
| Cherry Studio | Assistant 编辑器展示 prompt、模型、参数和关联资源；消息显示作者/模型快照 | 每次请求按 `assistantId` 重读当前 Assistant；修改后既有会话下一次请求生效；重新生成保留旧回复并新建兄弟分支 |
| DeepChat | Agent descriptor 与 session policy 都有明确状态字段 | systemPrompt/生成参数在会话创建时快照，修改 descriptor 不影响既有会话（除非显式换 Agent）；工具/记忆策略实时重读；重新生成破坏性替换 |
| DeepSeek Harness | Remote roster、会话身份标签与组合修订盘点；改选由服务端检查回合边界 | 声明更新产生新修订，运行 Agent 保留原绑定；blank 期可改选，历史文本不随修改重写 |
| Dify | 作者在 Console 编辑应用或 Agent v2；公开聊天未确认通用 persona picker 或完整运行配置展示 | 传统应用运行时读 active config；Agent v2 generation binding 防止既有会话随新发布版本漂移 |
| Jan | 设置页和 Assistant switcher；thread 内有 AssistantInfo | 既有 thread 使用嵌入快照，不自动跟随模板；消息本身不保存模型/参数元数据；重新生成保留旧回复为 sibling |
| LobeHub | Agent 设置页覆盖人格、模型、插件、知识和 chatConfig；推理强度另接 Composer 的 `useReasoningEffortControl`，把用户级模型实例默认层与 topic 覆盖解析后并入模型选择器 | 发送时按 agentId 实时读 Agent 当前配置；开场白为空会话实时渲染；regenerate 删除旧消息后重生成 |
| Manifold Desktop | 只能看到当前全局设置 | 修改后所有后续请求读取新全局值；聊天消息仅存内存、不落盘，历史完全无法恢复 |
| NextChat | 当前 session 持有可编辑 Mask 和同步开关 | 模板改动不回写；当前会话改模型后关闭全局同步；开场白为固定欢迎语不入历史；regenerate 删除旧配对重建 |
| Open WebUI | 模型选择器和 Workspace Model 编辑页；只读调用者看不到 params | 下一次请求按 model id 重新读 DB；请求参数仍可覆盖模型参数；regenerate 在 parent 下新建兄弟消息 |
| SillyTavern | 角色卡与 Prompt Manager 可见 | 未 tainted 的聊天在改卡后可整体重建开场白；首次生成后 tainted 固化；每次生成重读角色卡当前值 |
| VCPChat | 当前 Agent/topic、模型参数和历史文件边界明确 | 发送用内存缓存引用（设置保存/话题加载时刷新）；重新生成时重读最新配置并以截断重建落盘 |
| VCPMobile | Agent 设置页可编辑本机提示词、模型和参数，另有语音设置页维护发音人、语音库与朗读规则；同步提示词对前端读取被隐藏 | 后续发送实时读取当前 Agent；历史消息不带完整角色快照，重新生成语义未验证 |
| VCPToolBox | Admin Panel 可热重载 AgentAssistant，文件层也热重载 | 新请求使用内存 `AGENTS` 映射的当前配置；历史只存 `{role, content}` 无快照可查 |
| Hermes Agent | `/personality` 列出可用与当前值、`/status` 显示模型/Provider（含 `active_personality_name`）；TUI 会话 personality；web 编辑 SOUL.md | 修改人格写 `display.personality` 名称（不写 `agent.system_prompt`）：CLI 强制重建 agent（下一轮生效），TUI 就地改 `ephemeral_system_prompt` 不重置历史；轨迹不含人格文本，历史重放反映缓存 system prompt；retry_last 复用内存缓存不重建，存储 prompt 与运行时比对只检查尾部 Model/Provider 行 |
| Pi | footer 显示当前模型/状态；`/session` 显示统计；无查看当前 system prompt 的内置命令 | 修改文件后 `/reload` 重建基础 prompt；`before_agent_start` 的当轮覆盖在轮末复位；历史只含消息与模型条目，无法从会话文件还原当时的提示词；无用户级重试命令（瞬时错误自动重试） |
| OpenCode | App/TUI 输入框 agent 下拉与 `@` 补全、按 agent 着色；消息元信息显示 agent·model·时长；CLI `opencode agent list`/`debug agent` 展示权限与工具状态 | 修改配置后新会话用新配置；既有会话消息显示当时快照，继续生成使用当前配置解析的 agent 与权限；undo 物理删除 revert 点之后的消息再重发并重建 agent；无“当前权限面板”UI |
| Risuai | 角色编辑器、开场白分页和入场引导；消息展示模型与耗时 | 修改角色影响后续显示与请求，既有正文仍保存；选中候选写回消息，未选候选刷新丢失，完整角色版本未冻结 |
| OpenClaw | Control UI 展示 identity、workspace、primary/fallbacks/runtime/thinking 默认、工具 profile 与 allow/deny 摘要、有效 Skill filter、当前 session live tools、workspace 文件状态；session/status 显示实际 provider/model 与 override | 新 turn 按当前配置与 session override 重新解析，历史 session 不被重写成新角色快照；运行时事实与 prompt/工具统计报告更新；完整逐消息角色版本语义未确认 |
| RikkaHub | 助手详情聚合人格与能力；聊天页修改模型、推理、搜索等会话配置 | 会话已复制字段随后独立更新，其余读取绑定助手当前值；进行中生成保留已捕获对象，历史不保存完整角色版本 |
| Codex | 派生工具说明与线程记录携带角色名；TUI 子 Agent 选择器也消费角色来源，实际交互未运行观察 | 后续 spawn 和 V2 冷加载会重新应用角色文件，已驻留线程保留运行态；全历史 fork 的默认角色与指令回填另有分支，实际恢复交互未运行验证 |
| OpenOcta | `employees.list` 摘要给出名称、描述、Prompt、启停、技能名与 MCP key；实际模型、workspace 与合并后的 MCP 不随列表返回，会话条目只见技能快照 | 每轮按 sessionKey 重读 Manifest 与 Agent 配置，运行时指纹变化即重建；`enabled` 不构成门禁，禁用员工仍可用已知 key 起会话；删除员工连带清理会话 |

## 适用边界

按实现边界观察，不做总排名，可以得到几组清晰取向：

- **需要一个角色同时拥有模型、参数、工具和知识**：AIO Hub、Cherry Studio、LobeHub、DeepChat、Open WebUI、RikkaHub 都能表达，但聚合根不同。Open WebUI 的根是“模型”，其余项目的根是 Agent/Assistant descriptor。
- **需要在一个界面里组合并频繁切换提示词变体**：AIO Hub 是当前样本中最完整的实现。消息组可表达“风格任选多项”“场景只能选一项”“整套规则暂时关闭”，同时仍可对单条消息配置模型匹配和注入位置。SillyTavern 能表达许多相近的提示词位置和开关语义，但缺少同等的组级选择抽象，且配置分布更广；VCPChat 的 modular 积木模式支持块级启停与块内 variants 单选，是样本中最接近的机制，但块是平铺的、没有组级总开关。
- **需要人格与运行环境解耦**：Chatbox 和 AstrBot 更明确。Chatbox 把模型/工具放到 Session，AstrBot 把 Provider 放在 Persona 外，同时用 Persona 白名单收窄能力。Risuai 走同一取向且更彻底：角色只持有提示词与内容，模型、采样参数、装配顺序和工具全部归全局 Database 与预设，切换角色不触碰预设选择。
- **需要会话可复现性**：Jan、Chatbox、NextChat 已确认存在不同程度的角色快照。AIO Hub 选择了另一种取向：开场白和旧回复固化、未来执行实时读取当前 Agent，并记录部分请求元数据，适合在同一历史上迭代测试，但不能仅靠会话完整还原旧 Agent 配置。Manifold Desktop 的消息只存内存；Risuai 保存正文与生成元数据，但没有持久化候选库或完整角色快照；RikkaHub 保留部分会话快照，其余字段随助手当前值变化，消息中的模型与响应也不足以还原完整旧配置；其他项目的运行时表现需要补充运行验证后才能完全比较。
- **需要角色内容交换**：SillyTavern 的社区规范最明确，AIO Hub 的包覆盖资产和运行配置更广。Risuai 是第三个角色卡生态入口，覆盖 Tavern V2/V3、PNG、JSON、CharX、Chub 与自有 Hub，但对 ST 扩展字段做内联装饰符转译而非原结构保留。三者之间仍需处理模型参数、消息位置和权限语义的差异。
- **需要服务端多 Agent 编排**：DeepChat、LobeHub、VCPToolBox 和 AstrBot 都有相关入口，但 subagent slot、异构 Agent、AgentAssistant 委托和 Persona router 是不同机制，不能只用“支持多 Agent”合并评价。
- **只需要所有聊天共用一条指令**：Manifold Desktop 的全局模型足够直接，但缺乏角色选择、会话级复现和能力隔离；Hermes Agent 也以全局提示词为基础，但 `agent.system_prompt`/`SOUL.md` 有 personalities 选择与 Profile 级隔离作为补充。
- **提示词即文件、随项目分发**：Pi 是二十四个项目中唯一把整条角色链路做成普通 Markdown 文件的项目——SYSTEM.md/AGENTS.md 可进 git、按目录作用域天然隔离，代价是没有角色选择、导入格式、字段校验或运行时可见性（Codex 的 AGENTS.md 同样可进 git，但它的角色本体是 TOML 配置，在 spawn 与 V2 冷加载时投影）。OpenCode 同样支持 `{agent,agents}/**/*.md`（frontmatter 角色文件，可进 git），但它是配置对象，不是纯文件约定：还接受 opencode.json 字段、提供角色选择 UI 与权限/参数绑定，markdown 只是载体之一。OpenClaw 是同一方向的混合形态：结构化 identity、模型与工具/memory 策略留在配置条目，workspace 的人格与规则文件只承担提示词内容，可编辑文本不能授予工具。

## 已确认边界与证据缺口

1. 单项目笔记的调查深度不完全一致。AIO Hub、AstrBot 对提示词装配和存储覆盖较深；Cherry Studio、LobeHub 重点在配置模型；DeepChat、Jan、NextChat、Open WebUI 更聚焦近期新增的持久化或运行链路。矩阵未用字段缺失填补这些深度差异。
2. 历史证据分为正文、角色身份、模型元数据、局部配置和完整提示上下文。上表逐项目记录已确认层次；只有角色名或模型名时，无法还原完整旧配置。运行期修订保留、磁盘快照和重启后重读也须分开比较，导出与完整重放尚未全覆盖。
3. 角色修改后既有会话的行为已有静态代码结论；仍未运行验证的包括 AstrBot 切换后的旧历史渲染、SillyTavern 改卡后的 UI 表现、VCPToolBox 委托持旧对象引用期间的并发行为、DeepChat 跨版本迁移分支等，需要运行验证才能完全定论。OpenClaw 的角色提示词装配、修改配置后既有会话的实际行为、审批与 UI 表现亦属未运行验证。
4. 工具字段只比较角色配置的挂载点。审批、沙箱、执行位置、模型可见定义和失效方向不在本文重复下结论。
5. 知识库“已绑定”只表示绑定关系存在；内容是否进入请求还受召回阈值、权限、索引状态、模型能力、注入模式和全局服务状态影响。
6. 导入兼容性区分“能解析”“能保留字段”和“运行时生效”。手工粘贴 system prompt 只能算文本迁移，不能算角色格式兼容。
7. Jan 的 core/web Assistant 类型不一致是已确认事实；tools、parameters 与文件存储的完整往返仍未运行验证，因此横向表没有把任一侧字段当成完整稳定契约。
8. AstrBot Persona 只对内置 Agent runner 注入；Dify、Coze、Dashscope、DeerFlow 等第三方 runner 只读取自定义错误文案。AstrBot 的能力结论适用范围限于内置 Agent runner。

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
