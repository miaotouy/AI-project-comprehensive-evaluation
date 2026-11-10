# Pi Agent 角色配置调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/coding-agent/src/core/` 的 system-prompt、resource-loader、settings-manager）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：只读源码梳理 system prompt 拼装、资源文件发现规则与设置合并；未运行交互会话
>
> 调查范围：角色实体与存储、创建与绑定、生效优先级、提示词拼装、模型与生成参数、外部能力授权、资产与变量、导入导出、运行时可见性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 没有“角色/Persona/Assistant”作为独立持久化对象。角色能力由四条可配置链路组合而成，全部在**会话启动时**按 cwd 解析、在**每轮请求前**拼装进 system prompt：

1. **System prompt 文件**：会话启动时，加载器若读到项目级 `.pi/SYSTEM.md`（需项目通过信任检查）或全局 `~/.pi/agent/SYSTEM.md`，就用它整篇替换默认 system prompt；项目或全局的 `APPEND_SYSTEM.md` 追加到末尾。发现与读取规则见 `resource-loader.ts:1022-1048`。
2. **项目上下文文件**：加载器从全局目录起，沿 cwd 向上的各级祖先目录收集 AGENTS/CLAUDE 系列文件并去重，每个文件包成一个 `<project_instructions path="...">` 块，汇总进 `<project_context>`。同一目录内的候选按优先级 `AGENTS.override.md > AGENTS.md > AGENTS.MD > CLAUDE.md > CLAUDE.MD` 取用，收集逻辑见 `resource-loader.ts:70-89, 118-156`。
3. **Skills 与 Prompt 模板**：skills 列表在拼装时生成 XML `<available_skills>` 索引区块，供模型发现有哪些 skill；需要全文时用 `/skill:name` 注入。`prompts/` 目录下的模板支持 `/template` 调用，注入与模板展开见 `agent-session.ts:1309-1333, 1163/1351/1371`。
4. **扩展每轮改写**：扩展在 `before_agent_start` 事件里可以替换整份 system prompt 或注入 custom 消息，这一层的改动覆盖上面的基础拼装，事件处理见 `agent-session.ts:1232-1261`。

模型/思考等级绑定在会话状态，切换时以 `model_change`/`thinking_level_change` 条目落入会话文件；默认 Provider/模型/思考等级来自全局 `~/.pi/agent/settings.json` 与项目 `.pi/settings.json` 的深合并结果（`settings-manager.ts:139-165`）。

历史消息里的 assistant 消息自带 provider/model/usage 等元数据，但 system prompt 本体不进会话文件，仅在 HTML 导出时快照（`export-html/index.ts:134`）。

## 总体生效链路

```text
会话创建 (AgentSession._buildRuntime)
  -> ResourceLoader.load: SYSTEM.md / APPEND_SYSTEM.md / AGENTS.md 链 / skills / prompts / extensions
  -> _rebuildSystemPrompt(toolNames) (agent-session.ts:1023-1057)
       buildSystemPrompt(options) (system-prompt.ts:28-162)
  -> 每轮 prompt():
       before_agent_start 扩展事件可改 systemPrompt (agent-session.ts:1232-1261)
       -> agent.state.systemPrompt (prepareNextTurnWithContext 注入每轮请求, agent-session.ts:541-556)
  -> Provider 请求: Context { systemPrompt, messages, tools }
```

## 1. 角色数据模型与存储

- **角色实体**：本次未找到任何“角色/Persona/Mask/Character”对象、表或文件格式。最接近的数据形态是 system prompt 的**文件源**：`SYSTEM.md` 负责整篇替换，`APPEND_SYSTEM.md` 负责追加，两者都是普通 Markdown 文件，没有版本字段，也不做 schema 校验，更没有配套的用户数据模型。
- **存储位置**：提示词分两类目录存放，全局的 `~/.pi/agent/` 与项目的 `<cwd>/.pi/`，目录常量定义在 `config.ts`。加载器无条件读取全局文件，项目级 `SYSTEM.md` 则要先通过信任检查 `isProjectTrusted()` 才读取（`resource-loader.ts:1022-1026`）。
- **内置角色与用户角色**：项目没有内置角色，自带的是默认 system prompt 模板，例如“You are an expert coding assistant operating inside pi...”（`system-prompt.ts:121-138`）；用户写出自己的 `SYSTEM.md` 后，这份模板即被替换。
- **删除策略**：删除文件即失效，无配置级删除操作。

## 2. 创建、选择与会话绑定

- **创建**：新建或编辑 `.pi/SYSTEM.md`、`AGENTS.md` 这类文件，就等于创建了一个角色。改完执行 `/reload` 重新加载全部资源（`slash-commands.ts:40`），会话无需重启。
- **复制与导入**：角色没有复制与导入导出机制；`/export`（HTML/JSONL）导出的是会话本身。
- **绑定**：角色不与会话绑定，资源按 cwd 解析——`ResourceLoader` 每次 `load()` 都以当前会话的 cwd 重新发现上下文文件（`resource-loader.ts:514-524`）。
- **目录切换**：用 `/new`、`/resume`（跨 cwd）或 fork 重建 runtime 之后，会话就换成另一套上下文（`agent-session-runtime.ts:214-221`）；同一会话内没有运行时切换角色的入口。

## 3. 提示词字段与最终拼装顺序

`buildSystemPrompt`（`system-prompt.ts:28-162`）的两种形态：

- **用户提供 SYSTEM.md 时**：加载器把文件内容当作 `customPrompt`，整篇替换默认模板，再按下面的顺序追加区块：
  - `APPEND_SYSTEM.md` 的内容；
  - `<project_context>`，其中每个 AGENTS/CLAUDE 文件包成一个 `<project_instructions path="...">` 块；
  - skills 索引区，前提是 read 工具在激活集里（`system-prompt.ts:63-67`）；
  - 当前工作目录提示，形如 `Current working directory: <cwd>`。
- **走默认模板时**：提示词先写固定开场（“expert coding assistant operating inside pi…”），随后依次拼入 `Available tools:` 段、`Guidelines:` 段、Pi 自身文档指引、追加段、project_context、skills 索引和当前工作目录。工具段只列带一行 snippet 的激活工具（`system-prompt.ts:80-84`）；`Guidelines:` 由工具集推导，叠加扩展通过 `promptGuidelines` 注入的内容与两条固定要求（“Be concise/Show file paths”）；文档指引给出 README、docs、examples 的路径以及按主题的阅读线索。
- **skills 索引格式**：`formatSkillsForPrompt` 为每个 skill 生成一个 `<skill>` 元素（含 name/description/location），汇总成 XML 的 `<available_skills>` 区块供模型发现（`skills.ts:335-361`）。模型需要全文时由 `/skill:name` 注入，注入块带上 location 与相对路径提示（`agent-session.ts:1309-1333`）。
- **每轮改写**：扩展通过 `before_agent_start` 事件返回的 systemPrompt 会直接替换会话的 `agent.state.systemPrompt`，本轮结束后复位成基础 prompt（`agent-session.ts:1071`）。

## 4. 模型、Provider 与生成参数

- **角色级绑定**：角色与模型之间没有绑定关系。模型和思考等级是会话级状态，保存在 `agent.state` 的 model 与 thinkingLevel 字段里，切换时向会话文件写入 `model_change` 或 `thinking_level_change` 条目（`session-manager.ts:58-67`）。
- **切换入口**：`/model` 命令或 Ctrl+P 快捷键（`agent-session.ts:1594` 附近）。
- **默认值**：
  - 设置项：`defaultProvider`、`defaultModel`、`defaultThinkingLevel`（`settings-manager.ts:91-93`）；
  - 初始模型选择优先级：CLI 参数 > scoped models > 设置默认 > 按 `defaultModelPerProvider` 匹配首个可用模型（`model-resolver.ts:620-700`）；
  - 思考等级默认 `"medium"`（`defaults.ts:3`），模型不支持时由 `clampThinkingLevel` 收敛（`models.ts:913-932`）。
- **其他生成参数**：温度与输出格式没有角色级入口。Provider 请求层支持 `samplingParams`（透传给 OpenAI-compatible 服务）和 `thinkingBudgets`，这两项挂在模型元数据与设置上（`packages/ai/src/types.ts:174-188`），与角色无关。

## 5. 工具、知识库、记忆与子 Agent

- **工具授权**：工具授权没有角色级入口。每个会话维护一份工具激活集，默认值 `[read, bash, edit, write]`（`agent-session.ts:211-212`），可用 `--tools` 参数或设置项改动。
- **提示词可见性与注册**：工具是否出现在 system prompt 由其“一行 snippet”是否存在决定（`system-prompt.ts:80-84`）；全部工具经扩展注册。
- **知识库**：无向量知识库；等价物是 `<project_context>` 上下文文件（静态文本）与 skills 文件（按需注入）。
- **记忆**：无独立记忆服务；长期记忆即会话历史 + 压缩摘要（`compaction`），跨会话无自动记忆。
- **子 Agent**：`packages/agent` 的 `createAgent` 可被扩展用作子 Agent，无角色级子 Agent 配置；示例见 `examples/extensions/subagent/`。
- 子 Agent 未指定 `model` 时，继承发起分发那个会话的当前模型与思考等级，两者通过 `--model` 与 `--thinking` 参数传入子进程（`examples/extensions/subagent/index.ts:265-270, 298-308`，#7897）。

## 6. 资产、变量、开场白与用户档案

- **头像/开场白/快捷回复**：本次未找到（无角色 UI）。
- **环境变量与占位符**：provider 配置里的 header 与 apiKey 支持 `$env`、`$command` 模板，解析逻辑在 `resolve-config-value.ts`；system prompt 文件不含变量展开，`resolvePromptInput` 按原样读入（`resource-loader.ts:53-68`）。
- **用户档案**：无用户档案对象；`AGENTS.md` 链即项目档案。

## 7. 导入、导出、迁移与兼容性

- **导入导出**：角色没有独立的导入导出格式。会话导出为 HTML 时会带上当时的 system prompt 快照与工具渲染结果（`export-html/index.ts:134, 267`）。
- **未知字段/脚本/远程资源**：`SYSTEM.md` 和 `AGENTS.md` 都是纯文本，加载时不做字段校验；`AGENTS.override.md` 专门用来覆盖仓库自带的上下文文件，它在候选顺序中的位置见 `resource-loader.ts:71`。
- **兼容性**：多项目工作流按“祖先目录链 + 全局目录”合并，重复路径去重；嵌套 git worktree 场景有去重处理（`findShadowedContextFile`，`resource-loader.ts:100-116`）。

## 8. 配置 UI 与运行时可见性

- **UI**：配置入口是 `/settings` 选择器，可以修改默认 Provider、模型、思考等级等；这里没有编辑角色的界面。
- **命令**：内置 `/model`、`/scoped-models` 命令（`slash-commands.ts:21-22`）；无 `/skills` 内置命令，skills 经 `/skill:name` 调用。
- **运行时可见性**：当前模型和状态显示在 footer（`components/footer.ts`），`/session` 显示会话统计，扩展可以读取 `agent.state.systemPrompt`（`extensions/types.ts:706`），HTML 导出里也能看到提示词全文。当前生效的提示词没有内置查看命令，本次未找到类似 `/system-prompt` 的展示入口。
- **历史快照**：assistant 消息持久化请求元数据（`AssistantMessage`，`packages/ai/src/types.ts:415-430`）：
  - 记录 api、provider、model、responseModel、usage、stopReason，不保存采样参数；
  - 会话条目只记模型切换：`model_change` 条目仅含 provider 与 modelId（`session-manager.ts:63-67`）；
  - system prompt 本体不随会话条目保存。
- **重试与重新生成**：本次未找到用户级 retry 或 regenerate 命令。内置命令表 `BUILTIN_SLASH_COMMANDS` 中没有对应条目（`core/slash-commands.ts:19-41`），对 `resend|replay|regenerate` 做 grep 也无命中。
- 仅有的 retry 是瞬时错误的自动重试（`agent-session.ts:2683-2747` 的 `_scheduleRetry`/`_prepareRetryableError`）：同上下文重发同轮请求，无兄弟分支、无参数快照。
- 人工“重新生成”的最近似路径是 `/fork`/`/clone`（`slash-commands.ts:31-32`）：从旧 user 消息重开分支，但那是新建会话分支，不是同节点重试。

## 9. 设计取舍与已确认边界

- **文件即配置**：角色能力全部通过文件约定表达，零数据库、零版本字段，与 CLI 工具工作流一致；代价是没有角色复用/版本管理/UI 层校验。
- **项目优先与信任门槛**：项目级 `SYSTEM.md`/`APPEND_SYSTEM.md` 只在项目受信后生效，全局目录始终生效；AGENTS 链则“全局 + 祖先 + 当前”合并，`AGENTS.override.md` 用于覆盖仓库版本。
- **扩展改写优先于文件**：`before_agent_start` 的 systemPrompt 是最高优先级且仅当轮有效，文件与扩展之间的关系是“扩展可完全覆盖”。
- **系统提示不落会话**：会话文件可回放消息但无法还原当时的完整 system prompt（除 HTML 导出），跨版本复盘时提示差异只能靠文件当时内容推断。

## 10. 未验证事项

- 未实际运行会话验证 SYSTEM.md/AGENTS.md 对请求的实际注入效果（拼装路径为静态确认）。
- 项目信任（`trust-manager.ts`）各入口对资源加载的完整影响未逐条验证。
- skills 在 `disable-model-invocation`（`skills.ts:67-81`）等 frontmatter 开关下的完整行为未运行验证。

## 11. 实验 facet 配置边界

默认 coding-agent 仍没有独立角色实体。p2 引入的是 Chord 插件与 facet：插件声明它服务的对象类型与对注册表的贡献，Chord 负责激活与热重载，会话 worker 与 Web/TUI host 各自加载相应插件。它是插件服务拓扑与能力装配，不包含 Persona、头像、开场白或角色版本对象（`apps/p2/docs/p2-notes.md`、`packages/chord/README.md`、`apps/p2/src/hosts/session-workers.ts`）。

## 12. 关键源码索引

- `packages/coding-agent/src/core/system-prompt.ts:28-162`：最终拼装
- `packages/coding-agent/src/core/resource-loader.ts:70-89`：上下文文件候选；`118-156`：祖先链收集；`1022-1048`：SYSTEM/APPEND 发现
- `packages/coding-agent/src/core/agent-session.ts:1023-1057`：基础 prompt 重建；`1232-1261`：扩展改写
- `packages/coding-agent/src/core/settings-manager.ts:89-137`：设置项；`139-165`：深合并
- `packages/coding-agent/src/core/model-resolver.ts:620-700`：默认模型选择
- `packages/coding-agent/src/core/skills.ts`：skills 发现与校验
