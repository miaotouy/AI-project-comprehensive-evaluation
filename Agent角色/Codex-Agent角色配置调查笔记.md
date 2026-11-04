# Codex Agent 角色配置调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c9750d7f50052b29f53def02b5cf2160ae49a3d9`（分支：`main`）
>
> 调查方式：只读源码静态梳理角色声明、目录发现、配置层投影、spawn 子 Agent 与提示词装配链路；未运行构建、未启动 TUI 或 app-server
>
> 调查范围：`agents` 角色声明与 `agents/` 目录发现、角色配置文件格式、内置角色、配置层优先级、角色对模型与提示词的覆盖、AGENTS.md 项目指令、spawn 时的 `agent_type`、角色在运行时的可见性与持久化；不含角色编辑界面、导入导出与多 Agent 调度算法本身
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的“Agent 角色”不是可独立创建、持久化和分享的角色卡，而是一组按名字声明的子 Agent 配置预设。角色只在派生（spawn）子线程时被投影到子配置；本次在核心链路中未找到把角色应用到已运行线程的入口。

关键事实：

- 角色实体只有三个字段：描述、可选的角色配置文件路径、昵称候选，见 `codex-rs/agent-roles/src/agent_role_config.rs:9-18`。
- 声明位置是 `agents.<role>`，可出现在任何配置层；同一层还会递归发现 `agents/**/*.toml`，见 `codex-rs/agent-roles/src/loader.rs:23-117`。
- 内置角色有三个：`default`、`explorer`、`worker`；`awaiter` 的声明被注释掉，见 `codex-rs/core/src/agent/role.rs:344-421`。
- 角色配置只被投影到一小组字段，并且只能收窄能力，不能扩大父会话的权限，见 `codex-rs/core/src/agent/role.rs:1-4` 与 `:69-128`。
- 角色层按 `SessionFlags` 优先级插入配置栈，高于项目层，低于遗留托管层，见 `codex-rs/core/src/agent/role.rs:242-268`。
- AGENTS.md 是独立于角色的项目指令通道，以 user 上下文注入，不参与角色覆盖，见 `codex-rs/core/src/agents_md.rs:58-116`。
- 子线程的来源标签和持久化记录都保留角色名，见 `codex-rs/protocol/src/protocol.rs:3398-3403`。

## 系统边界与总体调用链

Codex 源码里有两个容易被混为一谈的“角色”概念。第一个是本节讨论的 Agent 角色，即 `agents.<name>` 及其配置文件，决定子 Agent 的模型和开发者指令。第二个是线程来源上的角色标签，即 `SessionSource::SubAgent(SubAgentSource::ThreadSpawn { agent_role, .. })`，只用于标识这个子线程是用哪个角色派生出来的。两者通过 spawn 链路连接，但不是同一个对象。

还有第三条相邻通道：AGENTS.md。它是从磁盘发现的项目说明文本，任何线程都会加载，不因角色不同而改变发现规则；角色只能替换 `developer_instructions`，不能替换 AGENTS.md。

主链如下：

```text
模型调用 spawn_agent(agent_type?)
  → ThreadCreateRequest.agent_type（thread_spawn.rs:131-141）
  → prepare_agent_spawn_config（child_config.rs:51-101）
  → apply_spawn_agent_role（child_config.rs:291-330）
  → apply_role_to_config（role.rs:51-67）
  → resolve_role_config：用户角色优先，其次内置角色（role.rs:164-172）
  → load_role_layer_toml：读取并解析角色配置文件（role.rs:130-162）
  → AgentRoleOverrides：只挑出允许覆盖的字段（role.rs:36-48、80-128）
  → build_next_config：把角色层插入配置栈并同步 Config 字段（role.rs:174-240）
  → 子线程以其 SessionSource 记录 agent_role（thread_spawn.rs:162-168）
```

角色配置的加载发生在配置构建阶段，而不是 spawn 阶段。构建时会把每个配置层里的角色合并成一张表；spawn 只是按名字取用，加载入口见 `codex-rs/core/src/config/mod.rs:4031-4032`。

## 1. 角色实体与数据模型

运行时角色对象只有三个字段：

| 字段 | 作用 |
|---|---|
| `description` | 写进 spawn 工具说明，供模型判断何时使用该角色 |
| `config_file` | 指向一个角色配置层文件，可为空 |
| `nickname_candidates` | 派生子 Agent 时可选昵称的来源 |

结构定义在 `codex-rs/agent-roles/src/agent_role_config.rs:9-18`；配置声明侧的 `AgentRoleToml` 是同一组字段（`codex-rs/config/src/config_toml.rs:801-814`）。

角色不是独立持久化对象，没有单独的存储表，也没有版本字段。内置角色是一张静态表，用户角色来自配置层；解析时先查用户表，再查内置表，因此同名用户角色会覆盖内置角色（`role.rs:164-172`）。

角色配置文件是 TOML 表，顶层可写 `name`、`description`、`nickname_candidates`，其余字段被展开为普通 `ConfigToml`，见 `agent_role_config.rs:20-28`。这带来两条严格约束：

- 目录发现的角色文件必须自己写非空 `name`，否则报错（`agent_role_config.rs:73-88`）。
- 目录发现的角色文件必须写 `developer_instructions`；被 `agents.<role>.config_file` 引用的文件可以不写，因为此时角色名由声明提供（`agent_role_config.rs:67-71`、`:134-157`）。

角色文件侧使用 `deny_unknown_fields`，未知字段会直接解析失败。声明侧则不同：`AgentRoleToml` 只定义三个字段，但没有 serde 级未知字段拒绝；`agents` 表顶层不认识的键会被展开逻辑当成新角色名，角色表内部的未知键则被忽略。

## 2. 配置来源、发现与合并

### 2.1 三类来源

| 来源 | 位置 | 角色名 | 说明 |
|---|---|---|---|
| 内置 | 编译进二进制的静态表 | `default`、`explorer`、`worker` | 不读磁盘，`explorer` 的配置内容也被嵌入 |
| `agents` 声明 | 任意配置层的 TOML | 表键 | `config_file` 相对声明它的配置文件解析 |
| `agents/` 目录 | 每个配置层配置目录下的 `agents/**/*.toml` | 文件内 `name` | 递归子目录、只收 `.toml`、结果排序 |

目录根由配置层决定：User 层是 `$CODEX_HOME`，Project 层是项目的 `.codex` 目录，见 `codex-rs/config/src/state.rs:219-231`。因此用户级角色通常落在 `$CODEX_HOME/agents/`，项目级角色落在 `<repo>/.codex/agents/`。

目录发现用一个目录栈做深度优先遍历：弹出目录、把子目录压栈、把 `.toml` 文件收集起来，最后排序；`NotFound` 被当成“没有角色目录”而不是错误（`discovery.rs:7-39`）。

### 2.2 单层合并顺序

处理每个配置层时，先读 `agents` 声明，再扫描目录：

1. 声明逐个转成角色；同名重复只保留第一个并记录启动警告（`loader.rs:47-72`）。
2. 记录所有被声明引用的 `config_file` 路径（`loader.rs:56-58`）。
3. 目录发现时跳过这些已被引用的文件，避免同一个文件被注册两次（`loader.rs:298-301`）。
4. 目录内部按角色名去重，冲突同样只保留第一个并告警（`loader.rs:311-323`）。

因此同一层里“声明”优先于“目录发现”。

### 2.3 跨层合并

配置层按从低到高遍历，高优先级层覆盖低优先级层的同名角色，但缺失字段会从低层继承（`loader.rs:100-113`、`:166-173`）。继承只发生在三个角色字段上，不涉及角色配置文件里的模型或指令。

这里有两个实现细节。其一，高层只写描述而不写配置文件路径时，会继承低层路径，因为补缺规则是“当前值为空则取旧值”。其二，如果被引用的角色文件自己又写了名字，文件名会覆盖声明键，实际角色名以文件为准（`loader.rs:147-164`）。

所有层的角色最后都必须有非空描述，否则该角色被丢弃并记录警告（`loader.rs:237-249`）。

### 2.4 配置层优先级

角色层最终按 `SessionFlags` 插入，而配置层本身的优先级如下（`codex-rs/config/src/config_layer_source.rs:33-51`）：

| 层 | 优先级 |
|---|---|
| `PackagedDefaults` | -10 |
| `Mdm` | 0 |
| `System` | 10 |
| `EnterpriseManaged` | 15 |
| `User`（无 profile） | 20 |
| `User`（带 profile） | 21 |
| `Project` | 25 |
| `SessionFlags` | 30 |
| `LegacyManagedConfigTomlFromFile` | 40 |
| `LegacyManagedConfigTomlFromMdm` | 50 |

角色配置因此能压过项目和用户配置，但仍低于遗留托管配置。插入逻辑先复制现有层，再用 `partition_point` 找到第一个名字不小于角色层的位置插入，见 `role.rs:246-259`。

## 3. 内置角色

内置角色只有三个（`role.rs:350-387`）：

| 角色 | 配置 | 定位 |
|---|---|---|
| `default` | 无 | 省略 `agent_type` 时的默认角色，本身不注入额外指令 |
| `explorer` | `explorer.toml` | 面向代码库具体问题的快速调研；配置内容当前为空文件 |
| `worker` | 无 | 面向实现、修测试、拆分重构等生产性工作 |

`awaiter` 的整段声明被注释掉，但 `config_file_contents` 仍保留 `awaiter.toml` 的嵌入分支（`role.rs:388-418`）。也就是说，当前快照里 `awaiter` 不是可用内置角色。

spawn 工具的说明文本由 `spawn_tool_spec::build` 生成：先列用户定义角色，再补内置角色，同名跳过（`role.rs:281-299`）。如果某个角色的配置文件里固定了模型或推理强度，说明里会附加“该设置不可更改”的提示（`role.rs:301-341`）。

## 4. 角色配置层如何生效

角色是否产生效果，取决于它有没有配置文件。没有配置文件时，投影函数直接返回（`role.rs:75-77`）；这也是 `default` 和 `worker` 只作为“可选身份”存在的原因。

有配置文件时，执行顺序如下：

1. 内置角色读嵌入式内容，用户角色用敏感文件读取器读磁盘（`role.rs:136-155`）。
2. 先把文件解析成 `ConfigToml`，再解析一次以校验，并相对角色文件目录解析路径（`role.rs:157-161`）。
3. 只把下表字段放进 `AgentRoleOverrides`（`role.rs:80-89`）。
4. 只保留“关闭能力”的 feature 与 skill 条目（`role.rs:91-117`）。
5. 若投影结果为空，直接返回；否则重建配置（`role.rs:119-127`）。

投影字段与效果：

| 字段 | 效果 |
|---|---|
| `developer_instructions` | 替换子 Agent 的开发者指令 |
| `model` | 固定子 Agent 模型 |
| `model_reasoning_effort` | 固定推理强度 |
| `model_reasoning_summary` | 固定推理摘要方式 |
| `model_verbosity` | 固定输出详略 |
| `personality` | 固定人格预设 |
| `service_tier` | 固定服务档位，并按 feature 校验 `fast`/`ultrafast` |
| `features` | 只接受禁用项 |
| `skills` | 只保留禁用项，并清空 `max_context_tokens` |

可被角色关闭的 feature 只有五项（`role.rs:91-105`）：

- `ShellTool`
- `Apps`
- `Plugins`
- `MemoryTool`
- `RequestPermissionsTool`

其他 feature 即使在角色文件里写成 `false` 也不会进入投影。

技能侧同样只减不增。角色只能保留被禁用的配置项和内置项，只能传递关闭指令说明，并会把技能上下文预算清空（`role.rs:106-117`、`:221-227`）。因此角色无法重新打开父会话已关闭的技能，也无法抬高技能上下文预算。

最后一个细节是人格与模型自带提示的关系。如果角色把 `personality` 改成 `None`，而父配置的基础指令来自模型自带提示，重建配置会清空 `base_instructions` 和它的来源标记，避免人格指令与模型提示互相矛盾（`role.rs:228-238`）。

## 5. 生效优先级与冲突

spawn 时的配置装配顺序决定了冲突结果（`child_config.rs:51-101`）：

1. 以父回合配置为底，写入当前 step 的模型、推理强度与基础指令（`child_config.rs:110-122`）。
2. 应用调用方显式传入的模型与推理强度；两者缺省时回落到 `agents` 表里的子 Agent 默认模型与默认推理强度（`child_config.rs:204-261`）。
3. 应用角色层。
4. 应用服务档位。
5. 覆盖运行时审批策略、审批复核者、工作目录与权限快照（`child_config.rs:175-202`）。

因为角色层在显式模型参数之后应用，角色配置文件里固定的模型会覆盖调用方传入的 `model`。这与 spawn 工具说明里的“该角色的模型不可更改”一致，而不是相反。

全历史分叉有一条额外规则：V1 版本禁止同时指定 `agent_type`，直接报错；V2 版本允许带角色的全历史分叉，但角色没有给出 `developer_instructions` 时，会回填父回合的开发者指令（`child_config.rs:60-83`、`:167-173`）。

省略角色名时使用 `default`。如果 `default` 在用户配置里存在且带配置文件，这个默认角色会被记住，以便冷启动重载时再次应用它的限制（`child_config.rs:87-99`）。未知角色名会返回带名字的错误；内部应用失败则统一映射为不可用错误（`role.rs:51-67`）。

## 6. 提示词装配与 AGENTS.md

角色提供的 `developer_instructions` 会替换子配置里的同名字段，然后随子线程的 `TurnContext` 进入初始上下文。装配时它被放在开发者片段列表的最前面（`codex-rs/core/src/session/mod.rs:4740-4746`）。

世界状态片段的添加顺序是固定的：顶层工具、模型信息、token 预算、实时模式、AGENTS.md、权限、协作模式、持久模式、环境、应用与插件说明、工具清单，见 `codex-rs/core/src/session/world_state.rs:164-350`。最终消息顺序则是：聚合后的开发者消息、若干独立开发者消息、多 Agent 模式消息、上下文化 user 消息（`session/mod.rs:4929-4948`）。

AGENTS.md 的发现和角色完全独立，规则如下：

- 从当前工作目录向上找到项目根，默认标记是 `.git`；找不到标记时只考虑当前目录（`agents_md.rs:189-222`）。
- 从项目根向下到当前目录逐层收集，每层只取第一个命中的文件名（`agents_md.rs:242-268`）。
- 每层的候选顺序固定为 `AGENTS.override.md`、`AGENTS.md`，再拼接 `project_doc_fallback_filenames`（`agents_md.rs:272-295`）。
- 总预算由 `project_doc_max_bytes` 控制，默认 32768 字节；超出后截断后续文件（`agents_md.rs:68-113`、`config_toml.rs:77-85`）。
- 不可信项目直接跳过项目文档，只保留宿主提供的用户指令（`agents_md.rs:63-66`）。
- 多个执行环境各自读取，按环境顺序累加，直到预算耗尽（`agents_md.rs:68-113`）。

AGENTS.md 片段最终以 user 角色注入（`codex-rs/core/src/context/world_state/agents_md.rs:36-42`、`session/mod.rs:4916`）。因此角色改的是开发者指令，AGENTS.md 改的是用户上下文，两者不会互相覆盖。

## 7. 模型与生成参数

角色可以绑定模型、推理强度、推理摘要、输出详略、人格和服务档位，覆盖范围就是第 4 节的投影表。温度、`top_p`、最大输出 token 等采样参数不在角色配置的可用字段里：本次在 `config_toml.rs` 与 `profile_toml.rs` 的字段列表中未找到这些键。

显式模型覆盖需要先通过模型目录校验：按名字找到可用模型，再校验推理强度是否受支持（`child_config.rs:219-258`）。如果角色固定了另一模型，`apply_spawn_agent_role` 会在角色应用后重新校验推理强度（`child_config.rs:291-330`）。

服务档位也不是无条件接受（`role.rs:202-215`）：

- `fast` 需要 `FastMode` feature。
- `ultrafast` 需要 `UltrafastMode` feature。
- 其他值原样传递。

子 Agent 最终档位还要经过模型能力检查，不支持时置空（`child_config.rs:263-289`）。

## 8. 工具、Skill 与子 Agent 授权

角色不能新增工具、不能放宽沙箱、不能提高审批等级。它能做的只有两类收窄：关闭第 4 节列出的五个 feature，以及削减 skills。

工具目录本身由父会话的工具策略和模型能力决定，角色不参与注册过程。子配置继承父配置后，运行时覆盖会把审批策略、权限配置、工作目录重新对齐到父回合（`child_config.rs:175-202`），因此不存在“角色给自己更大权限”的路径。

子 Agent 的开关、并发上限、嵌套深度、默认模型、默认推理强度和中断消息，由 `agents` 表的其他字段控制，而不是单个角色（`config_toml.rs:766-799`）。

spawn 工具是否暴露 `agent_type` 由 `SpawnAgentToolOptions.expose_agent_type` 决定，说明文本则来自角色表（`core/src/tools/handlers/multi_agents_spec.rs:26-106`）。

## 9. 运行时可见性与快照

角色名会写进子线程的来源标签：`SubAgentSource::ThreadSpawn` 的 `agent_role` 字段由 `prepared.role_name` 填入（`thread_spawn.rs:162-168`）。

线程持久化记录也保留角色名，字段名是 `agent_role`，反序列化时兼容旧名 `agent_type`（`protocol.rs:3398-3403`）。这意味着恢复一个历史线程时可以直接知道它当初用的是什么角色。

昵称候选来自角色：有角色就用角色的 `nickname_candidates`，否则回落到默认昵称表（`codex-rs/core/src/agent/control/spawn.rs:66-78`）。spawn 工具返回值会带上昵称，便于在多个子 Agent 之间区分。

线程记录和 TUI 的选择器都会携带角色名：`/subagents` 选择器从线程记录读取 `agent_role`，并把它用于条目命名（`codex-rs/tui/src/app/agent_picker.rs:154-164`、`codex-rs/tui/src/app/agent_navigation.rs:423-427`）。本次未运行 TUI，未观察实际渲染与交互。

## 10. 设计取舍与已确认边界

- **角色是投影，不是权限主体**。角色层只补充配置字段，最终仍受父会话审批、沙箱和工具策略约束；文件头注释明确写了“可以定制或收窄子 Agent，但不能替代父会话权威”。
- **只在派生时生效**。本次未找到把角色配置应用到已运行线程的逻辑。
- **没有导入导出、复制或版本管理**。角色就是配置键加可选 TOML 文件，迁移靠复制配置。
- **描述是硬性要求**。没有描述的用户角色会被丢弃，避免 spawn 工具说明里出现无法解释的条目。
- **同层重复只保留第一个**。声明先于目录发现，冲突只告警不合并。
- **`awaiter` 当前不可用**。声明被注释，虽然嵌入资源仍在。

## 未验证事项

- 未构建 Codex，未实际 spawn 子 Agent，未验证角色配置文件在真实会话中的最终请求体。
- 未启动 TUI、IDE 扩展或 app-server，未观察角色在界面上的展示与选择方式。
- 未验证多执行环境（本地与远端）同时存在时，角色配置文件的路径解析是否符合预期。
- 未验证配置热重载、会话恢复和全历史分叉在真实运行时的行为差异。

## 关键源码索引

- `codex-rs/agent-roles/src/loader.rs`：分层加载、声明读取、目录发现、跨层合并。
- `codex-rs/agent-roles/src/discovery.rs`：`agents/` 目录递归与 `.toml` 过滤。
- `codex-rs/agent-roles/src/agent_role_config.rs`：角色文件格式、名称与描述校验。
- `codex-rs/config/src/config_toml.rs:764-814`：`AgentsToml` 与 `AgentRoleToml`。
- `codex-rs/config/src/config_layer_source.rs:33-51`：配置层优先级。
- `codex-rs/core/src/agent/role.rs`：角色投影、内置角色、spawn 说明生成。
- `codex-rs/core/src/agent/child_config.rs`：spawn 配置装配与角色应用。
- `codex-rs/core/src/thread_spawn.rs:124-168`：`agent_type` 解析与来源标签。
- `codex-rs/core/src/agents_md.rs`：AGENTS.md 发现、预算与截断。
- `codex-rs/core/src/session/world_state.rs:164-350`：提示片段顺序。
- `codex-rs/core/src/session/mod.rs:4719-4948`：开发者与 user 消息分块。
- `codex-rs/protocol/src/protocol.rs:3398-3403`：线程元数据中的角色快照。
