# Pi Agent 角色配置调查笔记

> 调查对象：`../../pi`（重点 `packages/coding-agent/src/core/` 的 system-prompt、resource-loader、settings-manager）
>
> 调查更新日期：2026-08-10
>
> 代码快照：`6b461b75b39b5a19b378dc42fbfbd1655bc446a6`（分支：`main`）
>
> 调查方式：只读源码梳理 system prompt 拼装、资源文件发现规则与设置合并；未运行交互会话
>
> 调查范围：角色实体与存储、创建与绑定、生效优先级、提示词拼装、模型与生成参数、外部能力授权、资产与变量、导入导出、运行时可见性
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 没有“角色/Persona/Assistant”作为独立持久化对象。角色能力由四条可配置链路组合而成，全部在**会话启动时**按 cwd 解析、在**每轮请求前**拼装进 system prompt：

1. **System prompt 文件**：`.pi/SYSTEM.md`（项目，需项目受信）或 `~/.pi/agent/SYSTEM.md`（全局）整篇替换默认 system prompt；`.pi/APPEND_SYSTEM.md`/全局 `APPEND_SYSTEM.md` 追加在末尾（`resource-loader.ts:1022-1048`）。
2. **项目上下文文件**：`AGENTS.override.md > AGENTS.md > AGENTS.MD > CLAUDE.md > CLAUDE.MD` 按“全局目录 → cwd 向上各祖先目录”收集，去重并以 `<project_instructions path="...">` 块包进 `<project_context>`（`resource-loader.ts:70-89, 118-156`）。
3. **Skills 与 Prompt 模板**：skills 由 `formatSkillsForPrompt`（skills.ts:335-361）生成 XML `<available_skills>` 区块进 system prompt 建索引，支持 `/skill:name` 全文注入（agent-session.ts:1309-1333）；`prompts/` 目录模板支持 `/template` 调用（展开在 agent-session.ts:1163/1351/1371）。
4. **扩展每轮改写**：`before_agent_start` 扩展事件可以替换整份 system prompt 或注入 custom 消息，且优先级高于基础拼装（`agent-session.ts:1232-1261`）。

模型/思考等级绑定在会话状态并以 `model_change`/`thinking_level_change` 条目落入会话文件；默认 Provider/模型/思考等级存在设置文件（全局 `~/.pi/agent/settings.json` + 项目 `.pi/settings.json` 深合并，`settings-manager.ts:139-165`）。历史消息里 assistant 消息自带 provider/model/usage，但 system prompt 本体不进会话文件（仅 HTML 导出时快照，`export-html/index.ts:134`）。

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

- **角色实体**：本次未找到任何“角色/Persona/Mask/Character”对象、表或文件格式。与之最近的概念是 system prompt 的**文件源**：`SYSTEM.md`（整篇替换）与 `APPEND_SYSTEM.md`（追加），都是普通 Markdown 文件，无版本字段、无 schema 校验、无用户数据模型。
- **存储位置**：全局在 `~/.pi/agent/`（`getAgentDir()`，`config.ts`），项目在 `<cwd>/.pi/`（`CONFIG_DIR_NAME`）。`SYSTEM.md` 项目路径仅在 `isProjectTrusted()` 时读取（`resource-loader.ts:1022-1026`），全局路径无条件读取。
- **内置/用户角色区分**：无内置角色；内置的是默认 system prompt 模板（`system-prompt.ts:121-138` 的“You are an expert coding assistant operating inside pi...”），用户 `SYSTEM.md` 出现即替换该模板。
- **删除策略**：删除文件即失效，无配置级删除操作。

## 2. 创建、选择与会话绑定

- **创建**：角色即文件，用户直接编辑/新建 `.pi/SYSTEM.md`、`APPEND_SYSTEM.md`、`AGENTS.md`、skills 等；`/reload` 命令重新加载全部资源（`slash-commands.ts:40`），无需重启会话。
- **复制/导入**：无角色复制、导入导出；`/export`（HTML/JSONL）导出的是会话本身。
- **绑定**：不是角色绑定会话，而是**资源按 cwd 解析**：`ResourceLoader` 每次 `load()` 以当前会话 cwd 发现上下文文件（`resource-loader.ts:514-524`），切换目录（`/new`、`/resume` 跨 cwd、fork）后重建 runtime 即换一套上下文（`agent-session-runtime.ts:214-221`）。同一会话内不存在运行时切换角色入口。

## 3. 提示词字段与最终拼装顺序

`buildSystemPrompt`（`system-prompt.ts:28-162`）的两种形态：

- **自定义 SYSTEM.md 存在时**：`customPrompt` 整篇替换默认模板，然后依次追加：`APPEND_SYSTEM.md` 内容 → `<project_context>`（每个 AGENTS/CLAUDE 文件一个 `<project_instructions path="...">` 块）→ skills 索引区（仅当 read 工具在激活集时，`system-prompt.ts:63-67`）→ `Current working directory: <cwd>`。
- **默认模板形态**：固定开场（“expert coding assistant operating inside pi…”）→ `Available tools:`（只有带一行 snippet 的激活工具才列出，`system-prompt.ts:80-84`）→ `Guidelines:`（按工具集推导 + `promptGuidelines` 扩展注入 + 固定两条“Be concise/Show file paths”）→ Pi 自身文档指引（README/docs/examples 路径及按主题的阅读指引）→ 追加段 → project_context → skills → cwd。
- **skills 索引格式**：`formatSkillsForPrompt`（skills.ts:335-361）生成 XML `<available_skills>` 区块（`<skill>` 含 name/description/location）供模型发现；全文经 `/skill:name` 注入（`agent-session.ts:1309-1333`，`<skill name=... location=...>` 块 + 相对路径提示）。
- **每轮改写**：`before_agent_start` 扩展事件返回的 `systemPrompt` 直接替换 `agent.state.systemPrompt`（`_systemPromptOverride`），本轮结束后复位为基础 prompt（`agent-session.ts:1071`）。

## 4. 模型、Provider 与生成参数

- **角色级绑定**：无角色→模型绑定；模型/思考等级是**会话级**状态（`agent.state.model/thinkingLevel`），切换时写 `model_change`/`thinking_level_change` 会话条目（`session-manager.ts:58-67`），`/model`、Ctrl+P 切换（`agent-session.ts:1594` 附近）。
- **默认值**：设置项 `defaultProvider/defaultModel/defaultThinkingLevel`（`settings-manager.ts:91-93`）；初始模型选择优先级为 CLI > scoped models > 设置默认 > 按 `defaultModelPerProvider` 匹配首个可用模型（`model-resolver.ts:620-700`）。`defaultThinkingLevel` 默认 `"medium"`（`defaults.ts:3`），模型不支持时 `clampThinkingLevel` 收敛（`models.ts:913-932`）。
- **其他生成参数**：无角色级温度/输出格式；Provider 请求层支持 `samplingParams`（透传给 OpenAI-compatible 服务，`packages/ai/src/types.ts:174-188`）与 `thinkingBudgets`，但绑定在模型元数据/设置而不是角色上。

## 5. 工具、知识库、记忆与子 Agent

- **工具授权**：无角色级工具授权。工具激活集是会话级列表（默认 `[read, bash, edit, write]`，`agent-session.ts:211-212`），`--tools`/设置可改；工具是否出现在 system prompt 由其“一行 snippet”是否存在决定（`system-prompt.ts:80-84`），全部工具经扩展注册。
- **知识库**：无向量知识库；等价物是 `<project_context>` 上下文文件（静态文本）与 skills 文件（按需注入）。
- **记忆**：无独立记忆服务；长期记忆即会话历史 + 压缩摘要（`compaction`），跨会话无自动记忆。
- **子 Agent**：`packages/agent` 的 `createAgent` 可被扩展用作子 Agent；无角色级子 Agent 配置。

## 6. 资产、变量、开场白与用户档案

- **头像/开场白/快捷回复**：本次未找到（无角色 UI）。
- **环境变量与占位符**：provider 配置的 header/apiKey 支持 `$env`/`$command` 模板（`resolve-config-value.ts`）；system prompt 文件本体无变量展开（`resolvePromptInput` 原样读入，`resource-loader.ts:53-68`）。
- **用户档案**：无用户档案对象；`AGENTS.md` 链即项目档案。

## 7. 导入、导出、迁移与兼容性

- **导入导出**：角色无导入导出格式。会话 `/export` HTML 含 system prompt 快照与工具渲染（`export-html/index.ts:134, 267`）。
- **未知字段/脚本/远程资源**：`SYSTEM.md`/`AGENTS.md` 是纯文本，无字段校验；`AGENTS.override.md` 专门用于覆盖仓库自带 `AGENTS.md`（候选顺序 `resource-loader.ts:71`）。
- **兼容性**：多项目工作流按“祖先目录链 + 全局目录”合并，重复路径去重；嵌套 git worktree 场景有去重处理（`findShadowedContextFile`，`resource-loader.ts:100-116`）。

## 8. 配置 UI 与运行时可见性

- **UI**：`/settings` 选择器可改默认 Provider/模型/思考等级等；无角色编辑 UI。`/model`、`/scoped-models` 命令（slash-commands.ts:21-22）；无 `/skills` 内置命令（skills 经 `/skill:name` 调用）。
- **运行时可见性**：footer 显示当前模型/状态（`components/footer.ts`）；`/session` 显示统计；`agent.state.systemPrompt` 可通过扩展读取（`extensions/types.ts:706`），HTML 导出可见全文。**当前生效提示词无内置查看命令**——本次未找到类似 `/system-prompt` 的展示入口。
- **历史快照**：assistant 消息持久化 provider/model/usage（`packages/ai/src/types.ts:412-427`），会话条目记模型切换；system prompt 本体不随会话条目保存。

## 9. 设计取舍与已确认边界

- **文件即配置**：角色能力全部通过文件约定表达，零数据库、零版本字段，与 CLI 工具工作流一致；代价是没有角色复用/版本管理/UI 层校验。
- **项目优先与信任门槛**：项目级 `SYSTEM.md`/`APPEND_SYSTEM.md` 只在项目受信后生效，全局目录始终生效；AGENTS 链则“全局 + 祖先 + 当前”合并，`AGENTS.override.md` 用于覆盖仓库版本。
- **扩展改写优先于文件**：`before_agent_start` 的 systemPrompt 是最高优先级且仅当轮有效，文件与扩展之间的关系是“扩展可完全覆盖”。
- **系统提示不落会话**：会话文件可回放消息但无法还原当时的完整 system prompt（除 HTML 导出），跨版本复盘时提示差异只能靠文件当时内容推断。

## 10. 未验证事项

- 未实际运行会话验证 SYSTEM.md/AGENTS.md 对请求的实际注入效果（拼装路径为静态确认）。
- 项目信任（`trust-manager.ts`）各入口对资源加载的完整影响未逐条验证。
- skills 在 `disable-model-invocation`（`skills.ts:67-81`）等 frontmatter 开关下的完整行为未运行验证。

## 11. 关键源码索引

- `packages/coding-agent/src/core/system-prompt.ts:28-162`：最终拼装
- `packages/coding-agent/src/core/resource-loader.ts:70-89`：上下文文件候选；`118-156`：祖先链收集；`1022-1048`：SYSTEM/APPEND 发现
- `packages/coding-agent/src/core/agent-session.ts:1023-1057`：基础 prompt 重建；`1232-1261`：扩展改写
- `packages/coding-agent/src/core/settings-manager.ts:89-137`：设置项；`139-165`：深合并
- `packages/coding-agent/src/core/model-resolver.ts:620-700`：默认模型选择
- `packages/coding-agent/src/core/skills.ts`：skills 发现与校验
