# OpenCode Agent 角色配置调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：只读源码静态梳理 agent 配置加载、选择、提示词拼装与权限叠加链路；未运行构建与交互
>
> 调查范围：Agent 数据模型与存储、配置加载与合并、选择与绑定、生效优先级、提示词拼装、模型与生成参数、工具/权限/Skill/子 Agent 授权、导入导出、UI 可见性、内置 agent；V2 架构并行对照；桌面端（Electron）复用 app UI 仅核实边界
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 的 Agent 是「从配置构建的只读内存对象」，本身不落库；持久化的只是 session 表上的 agent 名字引用（`packages/core/src/session/sql.ts:51`）。Agent 配置来源：
- `opencode.json`/`opencode.jsonc` 的 `agent` 字段；
- `{agent,agents}/**/*.md` 与 `{mode,modes}/*.md` 文件（mode 强制 primary）。

最终 system prompt 由「agent.prompt（缺省用 provider 风格提示）→ env → AGENTS.md 指令 → MCP 指令 → skills」按序拼装（`src/session/llm/request.ts:56-66`、`src/session/prompt.ts:1257-1271`）。权限求值采用 agent 权限与会话权限合并的 allow/ask/deny 三档规则（`src/permission/index.ts`），工具的最终可见性在请求组装时按合并后的规则过滤。

关键事实（快照 1f94d8a）：

- **Agent 实体字段**（`packages/opencode/src/agent/agent.ts:35-56`）：

  ```text
  name / description / mode("primary"|"subagent"|"all") / native / hidden
  temperature / topP / color / permission / model / variant / prompt / options / steps
  ```

- **加载与合并十一步**（`src/config/config.ts:314-596`）：
  1. 远程 well-known；
  2. 全局；
  3. `OPENCODE_CONFIG`；
  4. 项目；
  5. `.opencode/` 目录；
  6. `OPENCODE_CONFIG_CONTENT`；
  7. Console/Org；
  8. 企业托管；
  9. mode 并入 agent；
  10. `OPENCODE_PERMISSION`；
  11. 全局 tools 并入 permission。
- **选择优先级**：会话保存值 → `default_agent` → `build` → 列表第一个（`app/src/context/local-agent.ts:5-6`、agent.ts:328-340）。
- **模型解析与 agent 部分耦合**：`input.model ?? agent.model ?? currentModel(session)`（prompt.ts:646）；agent 无 model 时沿用会话模型，切换 agent 默认继承模型。
- **内置 7 个 agent**：build/plan（primary）、general/explore（subagent）、compaction/title/summary（primary+hidden）（agent.ts:141-265）。
- **配置字段 `tools` 已废弃**：仅布尔表，normalize 时并入 permission（v1/config/agent.ts:62-81）；无 `"*"`、对象 map 或 "read-only" 组语法。
- **无导入导出功能**；唯一生成路径是 `opencode agent create`（CLI，LLM 生成 markdown，cli/cmd/agent.ts）。
- **`$ARGUMENTS` 变量只存在于命令模板**，agent 的 markdown 正文原样作为 system prompt（prompt.ts:1372-1395）。

## 总体生效链路

```text
配置加载（src/config/config.ts:314-596，十一步合并）
  → Agent.Service 构建（src/agent/agent.ts:98-353，InstanceState 闭包内只读快照）
  → 用户选择/会话保存 agent 名（app prompt-input / TUI dialog-agent / CLI --agent）
  → prompt 时 agents.get(name) 或 defaultInfo（prompt.ts:636-637）
  → system prompt 拼装（request.ts:56-66 + prompt.ts:1257-1271）
  → 模型解析（input.model ?? agent.model ?? currentModel，prompt.ts:646）
  → 权限合并（agent.permission + session.permission）→ 工具过滤（request.ts:208-214）
  → LLM 请求
```

## 1. 角色数据模型与存储

### 1.1 V1 实体（当前运行时）

- `Agent.Info`（Effect Schema，`agent.ts:35-56`）字段：

  ```text
  name / description / mode("subagent"|"primary"|"all") / native / hidden
  temperature / topP / color / permission(PermissionV1.Ruleset)
  model({modelID, providerID}) / variant / prompt
  options(任意 key-value，如温度等模型参数) / steps
  ```

- Agent 一次性在 `InstanceState` 闭包中构建（agent.ts:98-353），`get/list/defaultInfo` 每次返回只读快照（:312-344），**没有 agent 表**。
- 会话持久化的只有名字：session 表 `agent` 列（`packages/core/src/session/sql.ts:51`），另有 `model`（:52-56）与 `permission`（:50）两个 JSON 列。

### 1.2 V2 实体（迁移中）

- V2 实体（`packages/schema/src/agent.ts:20-37`）字段：

  ```text
  id / model / request(headers+body) / system / description / mode / hidden / color / steps / permissions
  ```

  无独立 temperature/topP 字段（静态推断：走 `request.body`）。
- 内存 Map（core/src/agent.ts:48-66），同样不落库。

### 1.3 mode 语义（两套一致）

- `primary`：主 agent，可直接选择；`subagent`：只能被 task 工具调用；`all`：两者皆可。
- 可选择性：V1 的 `defaultInfo` 拒绝 subagent/hidden（agent.ts:328-340）；App 主选择器同样过滤这两类（app/src/context/local.tsx:70）；`@` 提及菜单只列非 primary 的 agent（app/src/components/prompt-input.tsx:582-605）。

## 2. 创建、选择与会话绑定

- **创建**：配置文件手写；`opencode agent create`（cli/cmd/agent.ts:33-232）由 `Agent.generate`（agent.ts:368-436）生成后写成带 frontmatter 的 markdown（cli/cmd/agent.ts:195-222）。
- **选择器**（四个客户端入口）：
  - App 输入框 agent 下拉：`prompt-input.tsx:1649-1675`；
  - TUI：`dialog-agent.tsx` 对话框与 `agent.list`/`agent.cycle` 命令（tui/src/app.tsx:678-736）；
  - CLI：`opencode run --agent`（cli/cmd/run.ts:170、596-639），拒绝 subagent 作主 agent；
  - HTTP：`GET /app/agents`（server/routes/instance/httpapi/handlers/instance.ts:80-81）。
- **会话绑定**：
  - 会话创建：`Session.createNext` 接受 agent 写入（session.ts:501-540）；
  - 更新：每次用户消息若 agent/model 变化，`setAgentModel` 更新 session 行（prompt.ts:672-689、session.ts:767-778）；
  - 消息快照：user 消息记 `info.agent`（prompt.ts:656-670），assistant 消息记 agent/mode（prompt.ts:1186-1200）。
- **切换（V1）**：无专用端点，切换 = 下次 prompt 带不同 `input.agent` 覆盖 session 行；plan/build 互切由 `plan_enter`/`plan_exit` 权限 + plan 工具触发（src/tool/plan.ts:34-73）。
- **切换（V2）**：专用 `session.switchAgent` 端点（server/src/handlers/session.ts:108-122、core/src/session.ts:393-401）。

## 3. 提示词字段与最终拼装顺序

两段式拼装（V1 运行时，源码确认）：

**第一段**（prompt.ts:1257-1271，每轮）：
```
system = [
  ...env,               // sys.environment(model)：模型名 + <env> 工作目录/平台/日期/引用
  ...instructions,      // instruction.system()：AGENTS.md 等
  ...(mcpInstructions), // sys.mcp(agent, session.permission)
  ...(skills),          // sys.skills(agent)
]
```
- `env` 内容见 src/session/system.ts:60-96（含 `<available_references>`）；skills 段 :98-110；mcp 段 :112-128。
- 结构化输出时追加 `STRUCTURED_OUTPUT_SYSTEM_PROMPT`（prompt.ts:1271、82）。

**第二段**（`LLMRequestPrep.prepare`，llm/request.ts:56-66）：
```
system = [
  agent.prompt ?? SystemPrompt.provider(model),  // agent 自写 prompt 优先，否则按 api 选 provider 风格
  ...input.system,                                // 第一段拼出的 env/instructions/mcp/skills
  ...(user.system ? [user.system] : []),          // prompt payload 的 system 字段
].join("\n")
```
- provider 风格 prompt 按模型 api id 选择对应模板文件（system.ts:27-42，含 anthropic、gpt、gemini、default 等）。Meta 系模板覆盖 muse 家族：api id 含 `"muse"` 即返回 `PROMPT_META`，按 `muse-glimmer` 区分两种型号，并替换模板中的 `{{MODEL_NAME}}` 占位（system.ts:27-31、prompt/meta.txt，提交 b9f3b38）。
- 拼装后触发 `experimental.chat.system.transform` 插件钩子（request.ts:69-73）；OpenAI OAuth 场景改走 `options.instructions`（request.ts:99）——真正写入 `providerOptions.instructions` 的是 agent 生成逻辑的 isOpenaiOauth 分支（agent.ts:418-433，注入经 llm.ts:316）。

**指令（AGENTS.md）加载**（src/session/instruction.ts，`systemPaths` :110-153）按来源顺序：

1. 全局 `~/.config/opencode/AGENTS.md`（以及可选的 `~/.claude/CLAUDE.md`，:60-63）；
2. 项目目录向上查找 `AGENTS.md`/`CLAUDE.md`/`CONTEXT.md`（CONTEXT.md 已标注 deprecated，:64-68；每层只取第一个匹配，:122-133）；
3. `config.instructions` 指定的路径或 URL。

- 渲染时每条指令带来源头 `Instructions from: {path}`（:155-169）；就近指令文件只附加一次（claims 集合，:70-77、201-211）。

V2 运行时（core/src/session/runner/llm.ts:168-214）把 agent 的 system 与 `system.baseline` 拼接为 system；baseline 来自 SystemContext 组合（指令、skill 引导、引用引导），按 registry key 排序输出（core/src/system-context/registry.ts:39-44）。

## 4. 模型、Provider 与生成参数

- **agent 可绑定**（agent.ts:281-286）：`model`（字符串，由 `Provider.parseModel` 解析）、`variant`、`temperature`、`top_p` 与 `options`。
- **生效点**：`prompt.ts:646` 按 `input.model ?? ag.model ?? currentModel(sessionID)` 解析；`currentModel` 依次查 session 表的 model 字段、最近带 model 的 user 消息，最后回退 `provider.defaultModel()`（prompt.ts:614-633）。
- **参数合并顺序**（request.ts:84-128）：temperature 与 topP 优先取 agent 值，缺省由 `ProviderTransform` 按模型生成；`options` 按 base(provider) → model → agent → variant 的顺序合并（:84-91）。
- **切换 agent 的模型行为**：App 端 `agent.set()` 保存 agent、模型与 variant（app/src/context/local.tsx:196-216），默认继承上一个模型，除非新 agent 自带 model；V2 `switchAgent` 不改 session.model（core/src/session.ts:393-401）。
- **默认模型**：`Provider.defaultModel()`（provider.ts:1947-1980）依次取配置的 `cfg.model`、最近使用记录（state/model.json）、第一个已配置 provider 的排序首个模型。
- App 端「当前默认模型」优先取 server `/config/providers` 响应的 `defaultModel`，`cfg.model` 仅作回退（provider-catalog.ts:28-38、提交 941e71d）。
- **内置 title agent** 自带 `temperature: 0.5`（agent.ts:240）。

## 5. 工具、知识库、记忆与子 Agent

- **tools 字段（已废弃）**：布尔表类型（`v1/config/agent.ts:21-23`），normalize 时把 `write`/`edit`/`patch` 映射为 `edit` 权限、其余键按工具名直接成为权限键（:69-77）。
- **无高级 tools 语法**：本快照未找到 `"*"`、对象 map 或 "read-only" 组语法（全局搜索无匹配）；全局 `config.tools` 同为布尔表并入全局 permission（config/config.ts:553-564）。
- **permissions 语法**：值可为字符串动作或 `{pattern: action}` 对象（v1/config/permission.ts:5-12）。已知权限键（:17-36）：
  - 读写与搜索：`read`、`edit`、`glob`、`grep`、`list`、`lsp`、`webfetch`、`websearch`；
  - 执行与任务：`bash`、`task`、`todowrite`、`question`、`doom_loop`；
  - 边界类：`external_directory`、`skill`。
- **运行时合流**：
  - 合并：工具上下文把 agent 权限与会话权限合并（`merge`，src/session/tools.ts:81-89）；
  - 过滤：`resolveTools` 按 `Permission.disabled` 过滤（llm/request.ts:208-214）；MCP 工具可见性经 `Permission.visibleTools` 过滤（src/tool/registry.ts:281；tools.ts:390-489 是 MCP 工具注册与 ask 求值）。
- **会话级 permission 来源**：`session.create` payload（session.ts:260-271）与 prompt payload 的 `tools`（废弃，prompt.ts:1060-1067）。
- **Skill 授权**：通过权限键 `skill` 控制——`Skill.available(agent)` 过滤 `Permission.evaluate("skill", name, agent.permission)` 不为 deny 的 skill（src/skill/index.ts:310-315）；系统提示 skills 段与 skill 工具都走该过滤。
- **MCP 按 agent 过滤**：配置层无 per-agent 字段（core/src/v1/config/mcp.ts），全部在运行时按工具权限过滤（system.ts:112-117、tools.ts:390-489）。
- **TaskTool 子 agent 权限继承**（agent/subagent-permissions.ts:14-27）：子会话权限 = 父会话 deny 规则 + `external_directory` 规则；子 agent 自身无 `todowrite`/`task` 权限则补 deny（:24-25）。
- task 工具侧（task.ts:139-155）再追加 `task`/`todowrite` deny 与 `experimental.primary_tools` deny；`subagent_depth` 限制嵌套（task.ts:104-117）。

## 6. 资产、变量、开场白与用户档案

- **`$ARGUMENTS` 变量不存在于 agent prompt**：只存在于命令（slash command）模板（prompt.ts:1372-1395、src/command/index.ts:42）。agent 的 markdown 正文原样作为 system prompt。
- **`@file`/`@agent` 引用**：消息与命令模板中的 `@name` 解析为文件 part 或 agent part（prompt.ts:157-191、src/config/markdown.ts:5-10）；agent part 注入「请调用 task 工具」提示（prompt.ts:974-990）。
- **AGENTS.md `@import` 指令：本次未找到**（全仓搜索无匹配），AGENTS.md 仅作纯文本指令附加。
- **无开场白/快捷回复机制**：本次未找到相关实现（agent 只有 description/prompt 字段）。

## 7. 导入、导出、迁移与兼容性

- **无导出**：`opencode export`（cli/cmd/export.ts）只导出会话，agent part 被脱敏（:146-155）。
- **无 agent 导入能力**：`opencode import <file>`（cli/cmd/import.ts:94-108）只导入 session/message/part 表，不涉及 agent 配置；唯一生成路径是 `opencode agent create`。
- **V1→V2 迁移**：`ConfigMigrateV1`（core/src/v1/config/migrate.ts:35-125）字段映射：
  - `agent`/`mode` → `agents`（mode 强制 primary，:100）；
  - `permission`/`tools` → `permissions`（write/patch → edit，:93-94）；
  - `prompt` → `system`；`disable` → `disabled`；
  - temperature/top_p 进 `request.body`（:106-125）。
- **frontmatter 解析**：markdown agent 文件的 YAML frontmatter 用 gray-matter 解析（core/src/config/markdown.ts:4-10）。

## 8. 配置 UI 与运行时可见性

- **App**：
  - agent/模型下拉：`prompt-input.tsx:1649-1675`、:1677-1709；
  - `@` 补全 subagent：`prompt-input.tsx:582-605`；
  - 侧栏按最后 user 消息的 agent 着色：`app/src/pages/layout/sidebar-items.tsx:172`、`app/src/utils/agent.ts:34-44`。
- **TUI**：
  - agent 选择对话框：`tui/src/component/dialog-agent.tsx:11-26`；
  - 会话页按消息 agent 着色：`tui/src/routes/session/index.tsx:1374、1543`；
  - 子 agent footer：`tui/src/routes/session/subagent-footer.tsx:17-21`。
- **权限展示**：无「当前 agent 权限面板」；权限请求弹窗显示 subagent 类型（`tui/src/routes/session/permission.tsx:287`）。
  - CLI：`opencode agent list` 打印权限 JSON（cli/cmd/agent.ts:247-250）；
  - CLI：`opencode debug agent <name>` 展示工具启用状态（cli/cmd/debug/agent.handler.ts:33-88）。
- **历史快照**：消息带 agent/model 快照字段（见第 2 节），历史消息渲染仍显示当时的 agent 与模型。
- **桌面端（Electron）**：agent 选择与管理完全复用 app 层——agent 下拉在 `app/src/pages/session/composer/session-composer-controls.ts:40`、`@agent` 提及在 prompt-input-v2.tsx:277-280；desktop 包内无角色/agent 代码（仅组合 app 源码，desktop/src/renderer/index.tsx:1-17）。

### 8.1 请求参数快照范围与重发/撤销语义

- **快照范围**：只有 agent/model/variant 级的部分快照，无完整请求参数，分三层看：
  - session 表（`packages/core/src/session/sql.ts:22-66`）保存 `agent`(text)、`model`(JSON `{id, providerID, variant?}` :52-56)、`permission`(JSON :50)、`revert`(JSON :49)、`metadata`(JSON :42) 及 cost/tokens/summary/share_url/time_compacting/time_archived 等，**无 temperature 等生成参数快照**；
  - 消息侧：V1 User 消息带 `agent/model{variant}/tools/system/format`（`packages/schema/src/v1/session.ts:332-354`），Assistant 消息带 `agent/mode/modelID/providerID/variant/cost/tokens/finish`（:453-485）；
  - part 层：`partBase` 仅 `id/sessionID/messageID`（:81-85），TextPart/ToolPart 的可选 `metadata`（:114、:321）不承载请求参数。
- **重试/重新生成 = 撤销 + 重发（替换式）**：
  1. undo 命令（`app/src/pages/session/use-session-commands.tsx:331-357`；TUI `tui/src/routes/session/dialog-message.tsx:26-55`）走 `session.revert.stage` → `SessionRevert.revert`（`src/session/revert.ts:38-88`），只设 revert 标记并恢复快照；
  2. 下一轮发送时 `revert.cleanup`（`src/session/prompt.ts:459、1056`；revert.ts:100-134）**物理删除** revert 点之后的 message/part；
  3. 重发时按 session 行 agent 名 `agents.get(name)` 重建 agent（prompt.ts:461、636-641），即重新解析当前配置。
- 因此 OpenCode 没有 AIO Hub 式"同历史兄弟分支生成对比"，分支手段只有 `session.fork`（另建会话）；provider 级自动重试（`RetryPart{attempt,error}`，v1/session.ts:220-231；`SessionRetry.policy` `src/session/processor.ts:660-666`）是同一请求重发，不重解析配置。
- V2 `resume`（`packages/core/src/session.ts:152-169、426-428`）是 drain/队列恢复执行，不是 regenerate。
- **无 agent 编辑 UI 与提示词分组**：app 仅有 agent 选择器（`context/local-agent.ts`），无编辑器页面；agent prompt 是单段 markdown，`disable: true` 是唯一启停字段（v1/config/agent.ts:24，构建时跳过 agent.ts:268-271）；无导入导出（见第 7 节），无开场白（见第 6 节）。

## 9. 内置 Agent 定义（V1，agent.ts:141-265）

| agent | mode | 要点 |
|---|---|---|
| build :141-155 | primary | 默认 agent；permission = defaults + `question:allow` + `plan_enter:allow`；无 prompt |
| plan :156-181 | primary | `plan_exit:allow`、`task:deny`、`edit:* deny` 但 `.opencode/plans/*.md` 与数据目录 plans 允许 |
| general :182-195 | subagent | 仅 `todowrite:deny` |
| explore :196-218 | subagent | 全 deny + `grep/glob/list/bash/webfetch/websearch/read:allow`；带 `PROMPT_EXPLORE` |
| compaction :219-233 | primary, hidden | `PROMPT_COMPACTION`；全 deny |
| title :234-249 | primary, hidden | `PROMPT_TITLE`；`temperature:0.5`；全 deny |
| summary :250-264 | primary, hidden | `PROMPT_SUMMARY`；全 deny |

- 公共默认权限 `defaults`（agent.ts:119-136）：
  - `*:allow`，`doom_loop:ask`，`external_directory:ask`；
  - `external_directory` 白名单目录 allow：Truncate.GLOB、tmp、skills、references；
  - `question`/`plan_enter`/`plan_exit:deny`；read 对 `.env` 有特殊规则。
- 四个 prompt 文件：agent/prompt/{compaction,explore,summary,title}.txt。
- V2 对应定义在 core/src/plugin/agent.ts:100-205（explore 的允许列表不含 bash/list，与 V1 存在差异）。

## 10. 设计取舍与已确认边界

- **配置即事实、内存快照**：agent 无独立持久化，重启后仅靠配置重建；会话记住的是名字引用。
- **prompt 优先于 provider 风格**：agent 自定义 prompt 完全覆盖 provider 提示模板，无自动拼合。
- **tools 字段废弃但保留兼容**：布尔表映射权限，与 permissions 双轨并存。
- **未知配置字段静默忽略**：schema 解码用 `onExcessProperty:"ignore"`（config/parse.ts:40-47），对未知顶层键不抛 InvalidError（38e10eb）。
- **默认全开**：build/plan 权限 `*:allow`，靠 ask 审批兜底；explore 等专用 agent 用全 deny + 白名单。
- **MCP/Skill 按 agent 的过滤全部在运行时**：配置层无 per-agent 挂接字段，权限规则是唯一杠杆。
- **V1/V2 迁移中**：V2 的 agent.model 不被 runner 读取（静态推断：模型解析只看 session.model），V2 explore 工具集与 V1 有差异，迁移未完成。

## 11. 未验证事项

1. 未运行构建与真实会话；V2 runner（core/src/session/runner/）的实际执行路径未运行验证。
2. `opencode agent create` 的 LLM 生成质量与 frontmatter 写入结果未实测。
3. UI 中 agent 颜色分配、下拉交互、`@` 补全的运行时行为未运行验证（静态代码只确认绑定）。
4. 企业托管配置（managed dir + macOS MDM）与 Console/Org 远程配置的合并行为未实测。

## 12. 关键源码索引

- `packages/opencode/src/agent/agent.ts`：Agent.Info（:35-56）、内置 agent（:119-265）、生成（:368-436）
- `packages/opencode/src/agent/subagent-permissions.ts`：子 agent 权限继承
- `packages/opencode/src/agent/prompt/`：内置 prompt 模板
- `packages/opencode/src/config/config.ts`：配置加载与合并（:314-596）
- `packages/opencode/src/config/agent.ts`：markdown agent 文件加载（:11-59）
- `packages/opencode/src/session/prompt.ts`：模型解析（:614-689）、system 拼装（:1257-1271）
- `packages/opencode/src/session/llm/request.ts`：最终 prompt 与参数合并（:56-128）
- `packages/opencode/src/session/instruction.ts`：AGENTS.md 指令加载
- `packages/opencode/src/permission/index.ts`：权限求值（:28-214）
- `packages/core/src/v1/config/agent.ts`、`v1/config/permission.ts`、`v1/config/migrate.ts`：配置 schema 与迁移
- `packages/app/src/context/local.tsx`、`local-agent.ts`、`components/prompt-input.tsx`：App 侧选择与绑定
