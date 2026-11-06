# OpenOcta Agent 角色配置调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态阅读角色配置结构、数字员工存储、`chat.send` 主链、运行时构造、提示词拼装、模型与技能解析、导入安装和会话快照代码；未启动 Gateway 做交互验证，也未连接真实模型
>
> 调查范围：数字员工模板与 `agents.list` 两套角色配置、存储位置、创建与导入、会话绑定、提示词与模型优先级、技能和 MCP 挂接、运行时可见性；排除最终上下文的完整历史拼装、工具执行细节、Chat UI 视觉效果和各 Provider Adapter 协议
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- OpenOcta 没有单一的“角色”实体，当前代码里同时存在两套配置。数字员工（employees）是可持久化的模板，保存 Prompt、SkillIDs 和专属 MCP；`agents.list` 则是运行主体配置，负责 workspace、模型、身份名称和路由命名空间，但它的配置结构没有 Prompt 字段。两者通过 sessionKey 在同一次运行中汇合。
- 数字员工模板存放在状态目录下的 `employees/<id>/manifest.json`。Windows 默认位置是 `%APPDATA%\openocta\employees`，其他平台通常是 `~/.openocta/employees`，路径解析见 `src/pkg/employees/paths.go:14-17`。模板的字段定义见 `src/pkg/employees/model.go:7-30`。
- 角色绑定不使用用户级或路由级外键，而是把身份编码进 sessionKey。数字员工会话使用 `agent:main:employee:<id>` 或其变体，聊天入口再从 key 中反解员工 ID；反解逻辑见 `src/pkg/gateway/handlers/chat.go:1419-1448`。
- 数字员工的 Prompt 通过 `SystemPromptOverrides` 进入运行时，语义是替换内置基础系统提示，而不是在默认提示后追加。替换发生在 `src/pkg/agent/runtime/runtime.go:71-86`，赋值来源见 `src/pkg/gateway/handlers/chat.go:2212-2218`。
- 替换之后，运行时仍可能追加技能说明、知识库说明和演进快照段落；因此“员工 Prompt”是基础指令的唯一来源，但不是最终系统提示的全部内容。追加顺序见 `src/pkg/agent/runtime/runtime.go:87-101`。
- 模型绑定在 `agents.list[].model` 上，数字员工 Manifest 没有模型字段。请求参数里的 `modelRef` 优先于 Agent 配置，Agent 配置再优先于 defaults；解析入口见 `src/pkg/agent/model_factory.go:80-88`。
- 技能与 MCP 是数字员工与 Agent 配置差异最大的两处能力。数字员工可以声明 `skillIds` 和专属 `mcpServers`，运行时按员工 ID 加载技能目录并与全局 MCP 合并；合并逻辑见 `src/pkg/gateway/handlers/chat.go:1389-1411`。
- `agents.*` 的列表、创建、更新和删除处理器当前是占位实现：列表固定返回空数组，其余多数返回 `method_not_implemented`。因此没有通过专用 RPC 创建普通 Agent 的可执行路径；现有 Agent 由配置文件提供，配置表单是否覆盖该段本次未验证。实现见 `src/pkg/gateway/handlers/agents_extended.go:7-65`。

## 系统边界与总体调用链

### 两套角色对象

| 对象 | 持久化位置 | 主要职责 | 不具备的能力 |
|---|---|---|---|
| 数字员工模板 | 状态目录 `employees/<id>/manifest.json` | 人设 Prompt、描述、启停、技能引用、专属 MCP、分类和来源 | 模型绑定、workspace、路由规则、版本号 |
| `agents.list` 条目 | 主配置文件 | 运行主体 ID、workspace、模型、身份显示名、知识库、子 Agent 与沙箱配置 | Prompt 文本、模板版本、独立技能文件 |
| sessionKey | 会话存储与请求参数 | 把一次对话归入某个 Agent 命名空间，并可携带员工 ID | 角色定义本身 |
| SessionEntry | 会话存储 | 保存会话指针、技能快照和少量运行时报告 | 完整角色配置副本 |

`AgentConfig` 的字段结构见 `src/pkg/config/schema.go:724-741`。数字员工 Manifest 与 `Summary` 的字段见 `src/pkg/employees/model.go:7-46`。两者没有共享的基类，也没有统一的角色版本字段。

### 一次数字员工对话的主链

1. 前端或调用方以 `agent:main:employee:<id>` 作为 sessionKey 发起 `chat.send`。员工页优先复用已有的稳定 key，见 `ui/src/ui/app-render.ts:112-149`。
2. `ChatSendHandler` 解析 sessionKey 中的 Agent ID 和员工 ID。Agent ID 来自 key 的第二段，员工 ID 由专门的前缀解析函数提取；入口见 `src/pkg/gateway/handlers/chat.go:1730`。
3. 处理器根据 Agent ID 解析 workspace，再读取主配置与员工 Manifest。workspace 解析见 `src/pkg/agent/workspace.go:17-47`，员工 Prompt 读取见 `src/pkg/gateway/handlers/chat.go:2194-2218`。
4. 处理器合并全局 MCP 与员工专属 MCP，并把员工 Prompt、技能过滤、MCP 过滤和模型选择一起纳入运行时指纹。MCP 合并见 `chat.go:2207-2211`，指纹见 `chat.go:2239-2249`。
5. 运行时池按指纹创建或复用运行时。创建时装配工具、模型工厂、技能目录、审批开关和系统提示覆盖值；运行时构造见 `src/pkg/agent/runtime/runtime.go:40-149`。
6. 运行时构建 Eino DeepAgent，把系统提示作为 Instruction，把工具和中间件交给 Agent；构建见 `src/pkg/agent/eino/engine.go:63-155`。
7. 运行结束后，`chat.send` 把技能快照写入会话条目，并可选择写入系统提示报告和工具列表。写入入口见 `src/pkg/gateway/handlers/chat.go:1451-1495`。

### 角色与相邻对象的边界

角色配置只决定“以什么身份、用什么基础指令、能看见哪些能力”。消息历史、上下文压缩、工具审批和结果展示分别由其他链路负责，本笔记只在它们影响角色生效时引用。

## 1. 角色实体与数据模型

### 数字员工 Manifest

数字员工是目录型模板，`manifest.json` 是唯一必需文件。字段职责如下：

| 字段 | 含义 | 运行影响 |
|---|---|---|
| `id` | 稳定标识，同时进入 sessionKey | 决定模板目录、技能目录和员工会话解析 |
| `name` | 展示名称 | 主要用于列表和选择，不参与提示词 |
| `description` | 功能描述 | 列表展示与安装信息 |
| `prompt` | 人设或系统提示 | 非空时替换基础系统提示 |
| `enabled` | 是否可用 | 仅由列表返回；聊天入口读取 Prompt 和技能时未检查该字段 |
| `createdAt` | 创建时间，Unix 毫秒 | 仅元数据 |
| `builtin` | 历史内置标记 | 注释明确后端不再嵌入默认员工 |
| `skillIds` | 引用的全局技能名 | 与员工独占技能目录合并后进入技能中间件 |
| `mcpServers` | 员工专属 MCP 配置 | 与全局 MCP 合并，同 key 时员工覆盖 |
| `type` | 分类 | 列表分组，空值显示为“其它” |
| `from` | 来源，如 local、remote | 安装与展示元数据 |

字段定义与注释见 `src/pkg/employees/model.go:7-30`。`Summary` 额外提供 `skillNames` 和 `mcpServerKeys` 供列表展示，见同文件 `33-46`。

Manifest 没有模型、工作区、工具、温度、版本或更新时间字段。因此数字员工不能独立绑定模型或工作目录，这些能力仍由 sessionKey 中的 Agent ID 对应的 `agents.list` 条目决定。

### 运行 Agent 配置

`AgentConfig` 按职责可以分成几组：

| 组别 | 字段 | 作用 |
|---|---|---|
| 标识 | `id`、`name`、`default` | Agent ID、展示名、默认 Agent 标记 |
| 目录 | `workspace`、`agentDir` | 工作区与 Agent 状态目录 |
| 模型 | `model`、`models`、`imageModel` | primary/fallback 模型引用 |
| 能力 | `skills`、`knowledge`、`tools`、`subagents`、`sandbox` | 技能、知识库、工具、子 Agent 和沙箱配置 |
| 交互 | `identity`、`humanDelay`、`heartbeat`、`groupChat` | 身份展示、延迟、心跳和群聊 |

结构见 `src/pkg/config/schema.go:724-741`。本次在 `chat.send` 主链中没有找到 Agent 级技能、工具、子 Agent 和沙箱字段的读取点；实际生效的技能过滤来自请求资源，工具装配来自运行时默认集合，员工技能来自 Manifest。身份名称字段只在回复前缀和显示名解析中被读取，见 `src/pkg/gateway/handlers/chat.go:1121-1135`。

### 标识与版本

Agent ID 和员工 ID 都是字符串，没有独立版本字段。员工 Manifest 只有创建时间，没有修改时间或内容哈希。运行时为了避免陈旧配置，使用“运行时指纹”而不是版本号：workspace、Agent ID、员工 ID、模型引用、MCP key 集合、技能 key 集合、联网开关和系统提示覆盖值共同决定是否复用池化运行时，见 `src/pkg/gateway/handlers/chat.go:2239-2249`。

## 2. 存储、默认值与内置角色

### 存储位置

| 内容 | 路径 | 说明 |
|---|---|---|
| 员工模板 | 状态目录 `employees/<id>/manifest.json` | 由 `ResolveEmployeesDir` 解析 |
| 员工独占技能 | 状态目录 `employee_skills/<id>/` | 上传或站点安装的技能 |
| 员工旧版技能 | 状态目录 `employees/<id>/skills/` | 兼容旧目录，仍会加载 |
| 全局技能池 | workspace 与管理目录 | `skillIds` 从这里按名称匹配 |
| 会话条目 | 会话存储 | 保存技能快照和会话指针 |

员工根目录解析见 `src/pkg/employees/paths.go:9-17`。技能来源与合并顺序见 `src/pkg/agent/skills/employee.go:13-63`：旧目录先加载，独占目录覆盖同名项；`skillIds` 非空时再从 workspace 技能池按名称补充，独占技能始终保留。

### 读写与删除语义

`LoadManifest` 读取 `<id>/manifest.json`，文件缺失或 JSON 无效都统一返回不存在；`SaveManifest` 在 ID 为空时回退到名称，并在覆盖时保留已有 `createdAt` 等字段。实现见 `src/pkg/employees/store.go:75-137`。

`ListSummaries` 扫描员工根目录，跳过无 Manifest 或损坏的目录，并把 `skillIds` 与独占技能目录名合并成展示用 `skillNames`，见 `src/pkg/employees/store.go:16-73` 与 `163-189`。

删除员工会同时删除该员工的会话。处理器先调用会话清理，再删除模板目录，见 `src/pkg/gateway/handlers/employees.go:170-198`。这意味着删除角色不是单纯移除模板，历史会话也会被一并清理。

### 内置员工

`Manifest.Builtin` 的注释写明“历史兼容，后端不再 embed 默认员工”，见 `src/pkg/employees/model.go:20-21`。仓库的嵌入入口只包含前端与 `.env`，见 `src/embed/embed.go:19-20`，并且 `src/embed/employees` 目录不存在。

文档 `docs/builtin-employees.md` 仍描述通过 `src/embed/employees/*.yaml` 提供内置员工，并在构建时嵌入。这是文档与当前实现的明确不一致：检查 `src/embed` 与 `src/pkg/employees` 后，本次未找到从 YAML 加载内置员工的入口，代码可执行路径以 `embed.go` 的嵌入列表为准。

## 3. 创建、导入与会话绑定

### 创建与更新

员工创建入口是 Gateway 方法 `employees.create`，实现见 `src/pkg/gateway/handlers/employees.go:63-168`。请求支持名称、描述、Prompt、启停、技能和 MCP 配置；带显式 ID 时进入编辑模式并合并字段，没有显式 ID 时创建新模板。

新建时 ID 的处理值得单独说明。代码先规范化显式 ID，为空则调用 `deriveEmployeeIDFromName`。该函数当前直接返回名称本身，原有的小写化和字符过滤逻辑已被注释掉，见 `src/pkg/gateway/handlers/employees.go:201-227`。因此名称中的大小写、空格和中文都会进入目录名。

聊天入口解析员工 ID 时会把整个 sessionKey 转成小写，见 `src/pkg/gateway/handlers/chat.go:1420`。在大小写敏感的文件系统上，模板目录可能保留大写，而运行时按小写 ID 查找，形成目录不匹配；在 Windows 默认的大小写不敏感文件系统上，这种差异通常不会暴露。该推断基于两条代码路径的对比，尚未在 Linux 环境运行验证。

### 站点导入

站点安装接口按员工、技能和 MCP 三类下载 zip，入口与分类参数见 `src/pkg/gateway/http/site_install.go:60-126`。

- 员工 zip 必须包含 `config.json` 与 `README.md`，可选包含 `skill.zip`。
- `config.json` 至少提供 id、name、description，并可带 Prompt、启停、技能和 MCP。
- 解析、模板写入和技能解压见同文件 `328-417`。

安装后的模板来源标记为 remote，分类取请求中的 type 或 category，并写入安装元数据。这里没有通用的“角色导出”接口或标准角色包格式；员工 zip 是安装格式，不是双向交换格式。

### 会话绑定形式

员工身份由 sessionKey 承载。解析函数支持以下形态：

| 形式 | 解析结果 | 典型来源 |
|---|---|---|
| `agent:main:employee:<id>` | `<id>` | 员工页稳定会话 |
| `agent:main:employee:<id>:run:<sessionId>` | `<id>` | 旧版或 OpenAPI 会话 |
| `agent:<agentId>:employee-<id>-<rest>` | `<id>` | 兼容前缀 |
| `employee-<id>` 或 `employee-<id>-<rest>` | `<id>` | 兼容前缀 |

实现见 `src/pkg/gateway/handlers/chat.go:1413-1448`。解析前统一转小写，且 `run` 被排除为员工 ID，避免把子会话段误认为员工。

IM 渠道入站也使用同一约定。渠道配置了 `digitalEmployeeId` 且员工仍存在时，入站消息的 sessionKey 从“渠道 + peer”切换为员工稳定 key，见 `src/pkg/gateway/http/inbound_sink.go:53-70`。这样同一个员工的网页、IM 和 OpenAPI 入口可以共享 Prompt、技能和 MCP；代价是同一员工的所有 peer 被合并进一个会话。

### 普通 Agent 的创建入口

`agents.*` 处理器目前是占位实现：列表返回空数组，创建、更新、删除和文件方法多数返回 `method_not_implemented` 或空结果，见 `src/pkg/gateway/handlers/agents_extended.go:7-65`。因此 UI 的 Agents 页从列表方法拿不到条目，也没有专用的创建 RPC。普通 Agent 目前由配置文件提供；通用配置表单能否直接编辑 `agents.list` 属于另一条路径，本次未验证。

## 4. 生效优先级

### 总表

| 维度 | 优先级顺序 | 实际行为 |
|---|---|---|
| 系统提示 | 员工 Prompt > 内置基础提示 | 员工 Prompt 非空时替换；随后追加技能、知识库、演进段落 |
| 模型 | 请求 `modelRef` > `agents.list[].model` > defaults | 员工 Manifest 不参与 |
| 工作区 | `agents.list[].workspace` > 默认 Agent 的 defaults workspace > 状态目录 | 员工不参与 |
| 技能 | 员工条目优先，空集合回退工作区，再筛选候选 | 最终只传目录，中间件可见集合未必等于筛选条目 |
| MCP | 员工先覆盖全局，之后请求筛选 | 非空结果又补入全局启用项，筛选不构成严格白名单 |
| 工具 | 运行时默认集合 > 请求资源过滤 | Agent 级 `tools` 字段本次未找到读取点 |

### 系统提示

`runtime.New` 先判断是否启用系统提示，再用 `SystemPromptOverrides` 替换默认 Instruction。默认分支读取 workspace 的提示 markdown，员工分支直接使用 Manifest 中的 Prompt，见 `src/pkg/agent/runtime/runtime.go:70-86`。

替换完成后，运行时依次尝试追加技能说明、知识库说明和演进快照。技能说明只在没有 Eino 技能中间件时追加；知识库说明来自配置；演进段落读取 workspace 下的 `.agents/evolution`，见 `src/pkg/agent/runtime/runtime.go:87-101` 与 `168-188`。

因此，“员工 Prompt 完全覆盖系统提示”只对基础段落成立。工具使用规范、安全声明、Windows Shell 策略等内置段落会随基础提示一起被替换掉；如果员工 Prompt 没有重新声明这些约束，运行时就只保留后续追加的技能、知识库和演进内容。

### 模型

无显式 `modelRef` 时，处理器按 sessionKey 中的 Agent ID 解析模型引用并创建模型工厂，见 `src/pkg/gateway/handlers/chat.go:2160-2175` 与 `src/pkg/agent/model_factory.go:80-88`。显式 `modelRef` 会绕过 Agent 配置，直接按模型引用创建工厂。

数字员工会话的 Agent ID 通常是 `main`，所以员工没有自己的模型，实际使用默认 Agent 的模型。若调用方在 `chat.send` 中传入 `modelRef`，包括 OpenAPI 的 `model` 字段，则请求级模型优先。

### 工作区

workspace 解析只接受 Agent ID，不接受员工 ID。优先级为：该 Agent 的显式 workspace、默认 Agent 的 defaults workspace、状态目录下的默认 workspace、其他 Agent 的 `agents/<id>/workspace`，见 `src/pkg/agent/workspace.go:13-47`。

数字员工因此共享其 Agent 的 workspace。员工独占的是 Prompt、技能和 MCP，不是文件系统边界。

### 技能

运行时在启用技能时调用 `ResolveSkillsDir`。员工会话先加载员工技能条目；没有员工条目时退回 workspace 条目；随后应用请求级技能过滤。解析见 `src/pkg/agent/eino/skills.go:12-65`。

技能过滤停留在候选条目层。该函数最终只返回目录，中间件拿到目录后自行扫描，过滤后的条目名单没有传入中间件。普通会话只要过滤结果非空，就优先返回整个工作区技能根目录；员工会话则先返回首个有效条目的技能自身目录。条目的 BaseDir 由加载器设为 SKILL.md 所在目录，因此员工分支返回值和代码注释所说的“扫描直接子目录的根”有层级差异（`src/pkg/agent/eino/skills.go:18-65`、`src/pkg/agent/skills/loader.go:305-337`）。

这使条目合并、请求名单与实际中间件可见集合成为不同层次，不能把请求过滤写成可靠白名单。员工条目为空时还会回退全局工作区池，即使 Manifest 的技能列表为空也不保证最终无技能。中间件安装只接收目录，实际扫描结果未运行验证（`src/pkg/agent/eino/context_middleware.go:157-168`）。

### MCP

员工 MCP 先覆盖同名全局项，再按请求 key 过滤；但后续合并函数在过滤结果非空时重新补入全部启用的全局项。因此选择一部分服务时，未选的全局服务仍可能进入运行时；选择空集合才使这条 Manager 路径直接为空（`src/pkg/gateway/handlers/chat.go:2207-2211`、`chat_runtime_pool.go:55-77`）。

新建运行时还会读取上下文提供的 MCP 工具回调；该路径只检查请求名单是否非空，没有逐服务过滤回调结果。运行时选项虽保存 MCP 过滤字段，引擎构建路径没有再消费它。工具按名称去重后交给引擎，连接随运行时驱逐关闭（`chat.go:2278-2302,2358-2362`）。资源选择因此停留在请求声明层，执行端可见的工具集合由回调结果与目录扫描决定。

## 5. 提示词字段与输出契约

### 内置系统提示的结构

默认系统提示由固定前缀和 workspace 提示文件组成。固定前缀包含身份、工具、Shell、安全和工作区五类段落；Windows 上追加 Shell 策略；最后把 `prompt/` 下的 markdown 作为“项目上下文”注入。构建函数见 `src/pkg/agent/runtime/system_prompt.go:92-155`。

固定前缀明确要求 `execute` 的 command 为单行、长脚本先写文件、文件工具使用 `file_path`，并声明工作区是文件操作的唯一全局目录。这些是提示层约束，不是执行层的强制校验。

### 员工 Prompt 的位置

员工 Prompt 是纯文本字段，没有结构化的人格、用户档案、示例对话、变量或开场白子字段。它在 `chat.send` 中被读取并作为 `SystemPromptOverrides` 传给运行时，见 `src/pkg/gateway/handlers/chat.go:2212-2218` 与 `2331-2350`。

此外，`BuildLocalAgentSystemHint` 会根据消息内容生成本地 CLI Agent 的使用提示，并追加到员工 Prompt 之后，见 `src/pkg/gateway/handlers/chat.go:2220-2226`。这意味着同一员工的最终基础指令可能随消息内容变化。

### 未找到的提示词能力

本次未找到以下能力的实现入口：提示词模板变量替换、示例对话字段、用户 Persona 独立存储、开场白、快捷回复、角色级生成参数。检查范围为 `src/pkg/employees`、`src/pkg/agent/runtime`、`src/pkg/config/schema.go` 和 `chat.send` 主链。

## 6. 运行时可见性与快照

会话条目预留了三类运行时事实：技能快照、系统提示报告和工具列表，结构见 `src/pkg/gateway/handlers/chat.go:1450-1455`。写回逻辑见同文件 `1457-1495`。

当前主链只稳定写入技能快照。`chat.send` 在两处构造快照时仅设置技能快照字段，见 `src/pkg/gateway/handlers/chat.go:2550` 与 `3163`；`SystemPromptReport` 和 `Tools` 字段虽然存在，但本次未找到填充点；因此界面无法从会话条目确认最终系统提示或实际工具目录。

技能快照对员工会话有单独分支：先加载员工技能，再输出技能名、描述、文件路径、来源和是否禁止模型调用，见 `src/pkg/gateway/handlers/chat.go:1341-1385`。这提供了“当前员工能用哪些技能”的可观察信息，但不包含 MCP 工具清单。

角色本身的可见信息主要来自 `employees.list` 返回的 `Summary`：名称、描述、Prompt、启停、技能名和 MCP key。运行时实际使用的模型、workspace 和合并后的 MCP 配置没有随角色列表返回。

## 7. 设计取舍与已确认边界

- **sessionKey 作为角色连接键**：优点是网页、IM 和 OpenAPI 可以共享同一员工会话，不需要额外的绑定表；代价是 key 解析规则成为事实上的角色协议，大小写和分隔符变化会直接影响角色识别。
- **员工 ID 直接使用名称**：创建路径保留原始名称，解析路径统一小写。Windows 上通常无感，大小写敏感平台上可能出现模板存在但运行时找不到的情况。
- **Prompt 替换而非追加**：员工 Prompt 获得完全的人设控制权，但也会丢掉内置的工具、安全和 Shell 约束。该行为由 `SystemPromptOverrides` 的赋值方式直接决定，不是文档约定。
- **启停字段不构成访问控制**：`enabled` 会出现在列表摘要中，但聊天入口在读取 Prompt、技能和员工 MCP 时没有检查它。已禁用的员工仍可通过已知 sessionKey 建立会话；禁用状态更接近展示和管理标记，而不是运行时门禁。
- **角色与模型解耦**：数字员工不保存模型，模型始终跟随 Agent 或请求。这样员工模板可以跨模型复用，但无法为单个员工固定生成参数。
- **普通 Agent 配置存在但专用入口缺失**：`AgentConfig` 有 workspace、model、skills 等字段，但 Gateway 的 `agents.*` 方法是占位实现，列表和创建 RPC 不可用。当前可用的角色创建入口集中在数字员工，普通 Agent 依赖配置文件。
- **内置员工只存在于文档**：代码不嵌入默认员工，`Builtin` 仅作历史标记。文档中的 YAML 内置机制与当前快照不一致。
- **技能多来源但单目录注入**：条目层合并了旧目录、独占目录和 workspace 池，Eino 中间件只接收一个根目录，跨根目录的完整技能集合是否全部可见取决于目录选择结果。
- **删除角色会清理会话**：员工删除包含会话清理，角色生命周期与会话生命周期绑定。

## 8. 未验证事项

- 未启动 Gateway，未验证员工页创建、编辑、启停和删除的实际交互与错误提示。
- 未在 Linux 或大小写敏感文件系统上验证“名称含大写”的员工能否被稳定识别。
- 未验证站点安装的真实网络下载、zip 内容校验和安装后技能解压结果。
- 未验证 `agents.list` 配置中的技能、工具、子 Agent 和沙箱字段是否会被其他非聊天入口读取；本次只确认 `chat.send` 主链没有读取。
- 未验证多 Agent 配置下，非 `main` 的 sessionKey 与数字员工组合时的实际 workspace、模型和技能行为。
- 未验证演进目录存在时，追加段落对员工 Prompt 的实际影响程度。

## 关键源码索引

- 角色字段与摘要：`src/pkg/employees/model.go:7-46`
- 员工路径与存储：`src/pkg/employees/paths.go:9-17`、`src/pkg/employees/store.go:16-137`
- 员工创建与删除：`src/pkg/gateway/handlers/employees.go:63-198`、`201-227`
- 会话绑定与员工解析：`src/pkg/gateway/handlers/chat.go:1389-1448`
- 提示词覆盖与运行时构造：`src/pkg/agent/runtime/runtime.go:40-149`
- 默认系统提示：`src/pkg/agent/runtime/system_prompt.go:92-155`
- 模型解析：`src/pkg/agent/model_factory.go:14-24`、`80-88`
- workspace 解析：`src/pkg/agent/workspace.go:13-47`
- 技能来源与目录解析：`src/pkg/agent/skills/employee.go:13-63`、`src/pkg/agent/eino/skills.go:12-65`
- 站点安装：`src/pkg/gateway/http/site_install.go:60-126`、`328-417`
- 普通 Agent 占位接口：`src/pkg/gateway/handlers/agents_extended.go:7-65`
- 员工页稳定会话 key：`ui/src/ui/app-render.ts:112-149`
