# OpenClaw 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-09-03
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：静态阅读 OpenClaw 的 embedded、CLI 与 Codex harness 路径，追踪工作区 bootstrap 文件、skills、prompt hooks、memory、context engine、compaction、模板和请求前 transform；并直接核对兄弟 Codex 仓库的模型可见上下文与 skills 约束
>
> 调查范围：可编辑或可持久化的工作区指令文件、身份与记忆文件、skills、prompt 模板、插件 prompt 注入、context engine、运行时上下文分流、compaction 交接、请求层与调试投影；不覆盖普通会话 CRUD、渠道传输、Provider 协议细节和消息渲染实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 在本次检查范围内具备独立的运行时上下文编译能力，但它不是一个把所有规则合并成单一模板的编译器。规则对象分布在工作区 Markdown、skills、文件 prompt 模板、插件 hook、memory 插件和可选 context-engine 插件中；embedded 运行器先准备这些来源，再由 `buildAgentSystemPrompt` 生成系统提示词，并在模型调用前把会话消息转换成 Provider 可见的数组。

- 工作区文件是可编辑的上下文源，身份、用户偏好、长期记忆和首次运行仪式分别承担不同生命周期。文件是否注入取决于会话隐私、bootstrap 状态、memory provenance 和运行器类型（`src/agents/workspace.ts:57-68,1145-1288`；`src/agents/bootstrap-files.ts:237-371`）。
- skills 是规则对象最完整的实现。加载器合并多个有优先级的根目录，过滤后生成有硬上限的 `<available_skills>` 目录；目录只放元数据，完整正文按需读取。显式 `$skill` 引用走另一条有限的请求前展开路径（`src/skills/loading/workspace-skill-loader.ts:375-570,588-680`；`src/skills/loading/workspace-skill-prompt.ts:31-75,121-190`）。
- prompt 模板与 slash command 提供文件型输入预处理。模板可从 agent、项目、显式路径和扩展资源加载，参数替换是单次展开；embedded 运行器接收上层准备好的资源，SDK session 在输入阶段展开模板（`src/agents/sessions/prompt-templates.ts:108-225`；`src/agents/sessions/agent-session-prompting.ts:119-160,348-387`）。
- 插件 hooks、memory 与 context engine 能在不同阶段追加或替换模型上下文，也能影响工具面；各自有独立的 authority、超时和降级策略（`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts:91-188`；`src/agents/embedded-agent-runner/run/attempt-history.ts:555-631`）。
- 最终结果分为模型请求、权威会话和诊断投影三条去向。模型专用的 prepend context 不等于可见 transcript，`systemPromptReport` 和 `/context` 也不等于最终 Provider payload（`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts:165-337`；`src/auto-reply/reply/commands-context-report.ts:131-163,198-263`）。

## 系统边界与规则编译主链

本类别记录会改变模型输入、权威 transcript 或其可解释投影的可编辑/可持久化对象。普通固定 system prompt、一般工具注册、历史截断和 Provider 调用本身不单独视为规则对象，但它们与规则结果的交接会在相应阶段说明。OpenClaw 的 legacy context engine 只包装既有运行时流程；独立的消息编译和 compaction 仍由 embedded runner 持有（`src/context-engine/legacy.ts:7-39`）。

```text
agent/session 解析 agent、workspace、session、model 与运行器
  -> session preparation 读取/持久化 skills snapshot
  -> prepareEmbeddedAttemptSetup
       -> workspace/sandbox 边界
       -> skill entries、环境覆盖、skill catalog 与 code-mode skill
       -> bootstrap 文件加载、会话过滤、memory provenance 过滤、agent:bootstrap hook
       -> 文件预算、截断和 Project Context 路径映射
  -> prepareEmbeddedAttemptSystemPrompt
       -> 工具列表与工具能力提示
       -> provider prompt contribution
       -> memory prompt section、project memory、workspace notes
       -> SOUL/USER/IDENTITY/MEMORY 等稳定 Project Context
       -> cache boundary 后的时间、渠道、身份、runtime 与动态文件
  -> prepareEmbeddedAttemptHistory
       -> transcript sanitize/validate/history limit
       -> 可选 contextEngine.assemble
       -> engine systemPromptAddition 与消息数组交接
  -> before_prompt_build / agent_turn_prepare / heartbeat contribution
       -> transcript prompt 与 model-only prompt 分离
       -> runtime context custom message（display=false）
  -> transformContext 与 convertToLlm
       -> 当前消息和历史消息的 Provider 边界规范化
       -> systemPrompt + model messages + tools
  -> prompt:before / context.compiled / trajectory / systemPromptReport
  -> streamFn 或原生 CLI/Codex 请求
  -> 成功 turn 写入 transcript，context engine afterTurn/ingest/maintain
  -> compaction 时 memory flush -> summary -> transcript replacement -> retry
```

embedded 主入口是 `runEmbeddedAttempt`。它先准备 skills、bootstrap、工具和系统提示词，再在 `runEmbeddedAttemptExecutionPhase` 中恢复并编译历史，最后由 `runEmbeddedAttemptPromptPhase` 执行 prompt hook、运行时上下文分流、预检和提交（`src/agents/embedded-agent-runner/run/attempt.ts:57-84,150-347`；`src/agents/embedded-agent-runner/run/attempt-execution-phase.ts:25-120,159-250`；`src/agents/embedded-agent-runner/run/attempt-prompt-phase.ts:103-392`）。CLI backend 复用 bootstrap、skills 和 hook 语义，但把系统提示词写入参数或临时文件；Codex app-server 则把 OpenClaw 结果投影为 thread/turn 的 developer instructions 和 prompt 字段。

## 1. 规则对象、权威源与作用域

### 工作区文件与身份

工作区文件的权威源是 agent workspace 下的文件，而不是一个独立的 prompt 数据库。`ensureAgentWorkspace` 按模板创建必需的工作区文件，只有新工作区才创建 `BOOTSTRAP.md`；模板从打包的 `docs/reference/templates` 搜索目录读取，并去掉 frontmatter 后写入（`src/agents/workspace.ts:205-237,903-1142`；`src/agents/workspace-templates.ts:15-38`）。

运行时把这些文件表示为带文件名、路径、内容和 missing 状态的 `WorkspaceBootstrapFile`。该对象没有通用版本字段或规则 AST，Markdown 正文仍由模型直接消费（`src/agents/workspace.ts:245-260`）。

这些文件的身份和生命周期不同：工作区规约、人格语气、用户偏好、长期事实和首次运行仪式各有独立文件；`IDENTITY.md` 另外承担结构化身份记录。身份解析只识别有限的 Markdown 标签并忽略模板占位符，工具只回写稳定身份字段，不把所有自由文本都同步为配置（`src/agents/identity-file.ts:20-35,39-55,104-145,213-253`）。

工作区文件的作用域首先由 agent workspace 决定。当执行目录是另一个 worktree 或项目目录时，运行器只把该目录的 `AGENTS.md` 作为项目层文件追加到 agent workspace 文件之后，其他身份/记忆文件不会从执行目录加载（`src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts:39-45,117-140`）。

项目记忆会按已准备的 repository key 过滤带项目注释的 curated 条目；未激活项目的条目不进入 Project Context（`src/agents/project-memory-bootstrap.ts:18-50`）。

`BOOTSTRAP.md` 不是普通长期规则。只有主 agent 的交互式用户/手动运行、canonical workspace 和文件访问权同时满足时才使用 full 模式；heartbeat、cron、subagent 和非交互运行不执行该仪式，无文件访问权时只使用 limited 引导（`src/agents/bootstrap-mode.ts:10-32`；`src/agents/bootstrap-routing.ts:12-90`）。

完整流程成功后，运行器把完成标记写入 transcript，continuation-skip 才能跳过重复注入；compaction 或 reset 会使该标记失效（`src/agents/embedded-agent-runner/run/attempt-context-engine-helpers.ts:29-68`；`src/agents/embedded-agent-runner/run/attempt-finalize.ts:335-357`）。

### Skills

skill 的权威源是包含 `SKILL.md` 的目录。`metadata.openclaw` 前言块提供平台、依赖、环境、配置和安装门控；顶层 invocation 字段负责控制命令与模型目录可见性（`src/skills/loading/frontmatter.ts:203-239`）。

当前类型没有 skill 内容版本字段；session snapshot 另存 watcher 版本和 prompt 格式版本，用于判断可否复用已解析状态（`src/skills/types.ts:21-40,96-154`）。

skill 根目录按来源合并，同名项由高优先级来源覆盖；最终目录按 skill name 稳定排序，独立执行 root 与 agent workspace 同名时以前者为准。来源冲突会记录诊断，目录和 `SKILL.md` 还受 realpath、hardlink 和 symlink target 约束（`src/skills/loading/workspace-skill-loader.ts:375-570,646-680`）。

skill 的模型可见性和运行时可用性是两套面。配置禁用、secret degraded、bundled allowlist 以及平台/依赖门控先决定 eligible；随后 agent allowlist 和 session overlay 决定当前 agent 是否可见（`src/skills/loading/config.ts:109-158`；`src/skills/discovery/agent-filter.ts:14-53`）。

`disable-model-invocation:true` 只从正常模型目录和 picker 隐藏 skill，授权的显式引用仍可调用；因此“能被运行时加载”和“会出现在模型目录”不是同一状态（`src/skills/discovery/skill-index.ts:37-67`）。

session preparation 把有效 skill snapshot 写入 session entry。snapshot 保存目录、完整 eligible identities、过滤状态、node eligibility、解析后的 skill 对象和版本；prompt 正文仍由当前可读的 skill 文件提供（`src/agents/command/session-preparation.ts:56-117`；`src/skills/loading/workspace-skill-prompt.ts:51-75`）。

后续运行会在 prompt 格式、watcher version、roots、filter、overrides 或 node eligibility 变化时重建 snapshot，否则可从已有 snapshot 恢复（`src/skills/runtime/session-snapshot.ts:51-148`）。

skill 的写入和发布面由 Skill Workshop 管理。提案在 SQLite 中保存版本、来源、工作区、状态、hash 和扫描结果；apply 在目标锁下重新校验内容与目标树，再写入 `SKILL.md` 及受限 support files，成功后提升 skill snapshot version（`src/skills/workshop/store-sqlite-record.ts:23-86`；`src/skills/workshop/apply-transition.ts:200-397`）。

ClawHub、Git、本地目录和上传归档属于 skill 的安装/迁移入口，Workshop proposal 属于待审写入状态；本次未找到把所有工作区 Markdown 规则统一导入导出的 schema。memory 的外部导入也保持为独立的 Markdown 文件，不合并进 agent 的 `MEMORY.md`（`docs/tools/skills.md:199-253`；`docs/concepts/memory.md:64-93`）。

### Prompt 模板、命令与占位符

文件 prompt 模板是 agent SDK session 的独立资源对象。默认来源包括 agent directory 下的 `prompts/`、当前项目 `.openclaw/prompts/`，以及 extension/CLI 提供的显式路径；每个 `.md` 以文件名作为模板名，frontmatter 可提供 `description` 和 `argument-hint`，内容正文成为模板 body。加载失败被忽略并形成有限诊断，重名时保留先加载者并记录 collision（`src/agents/sessions/prompt-templates.ts:19-29,30-60,124-198`；`src/agents/sessions/resource-loader.ts:478-495,582-613,914-941`）。

模板只在消息以 `/` 开头且精确匹配 `/name [args]` 时展开；参数解析支持简单单/双引号，替换支持位置参数、全参数、参数切片，并采用单次正则替换，插入参数不会被第二轮重新解释。缺失或不安全的数字占位符替换为空文本（`packages/agent-core/src/harness/prompt-template-arguments.ts:9-41,44-87`；`src/agents/sessions/prompt-templates.ts:201-225`）。

skill 命令与 prompt 模板共享 slash 资源表，但模型引用另有 `$skill-name` 语法。普通消息中的 `$` 引用会被解析为当前 agent 的 eligible、user-invocable skill；最多八个，转义引用和全大写 shell 变量不视为 skill。命中后加入“请读取每个 `SKILL.md`”的有限前缀，未知 slash command 保持原文，allowlist-hidden skill 返回可见错误而不是静默忽略（`src/skills/discovery/chat-command-invocation.ts:66-115,206-293`；`src/agents/command/prepare.ts:363-397`）。

带 `command-dispatch: tool` 和 `command-tool` 的 skill slash command 可以绕过模型直接 dispatch 到工具，参数按 raw 模式转交；没有该配置的 skill command 仍走模型提示。Claude bundle command 还可以声明 prompt template，`$ARGUMENTS` 在命令前置模板中展开（`src/skills/discovery/command-specs.ts:73-185,188-219`；`src/skills/discovery/chat-command-invocation.ts:120-180`）。

### Memory 与上下文引擎

memory 的文件权威源仍是 workspace Markdown，SQLite 主要保存索引、provenance、检索状态和部分插件治理状态。memory-core 通过 `registerMemoryCapability` 声明 deterministic recall tool、private transcript recall、prompt builder、flush plan 和 runtime；其他 memory 插件可添加 prompt supplement、异步 prompt preparation 或 corpus supplement。注册表以当前 active plugin registry 为准，prompt supplement 按 plugin id 排序合成，异步 preparation 先并行完成，再以不可变 snapshot 进入同步渲染（`src/plugins/registry-contribution-types.ts:108-131,166-213,223-289`；`src/plugins/memory-state.ts:40-61,103-245`）。

context engine 是唯一明确以“assemble model context”为契约的插件面。配置槽 `plugins.slots.contextEngine` 只选择一个 engine；默认 `legacy` 的 `ingest` 不做事、`assemble` 透传消息、`compact` 委托内置 compaction。非 legacy engine 可以实现 `bootstrap`、`maintain`、`ingestBatch`、`afterTurn`、`commitTurn`、`assemble`、`compact` 和 subagent 生命周期，并通过 `acceptedHostParams` 限制 host 注入的 sessionKey、prompt、runtimeSettings、sessionTarget、runtimeContext 等字段（`src/context-engine/legacy.ts:7-39`；`src/context-engine/registry.ts:42-69,299-351`；`src/context-engine/types.ts:345-532`）。

## 2. 选择条件、优先级与编译顺序

### Bootstrap、skills 与系统提示词

embedded 运行器的顺序不是简单的文件名拼接，而是先准备输入，再编译 prompt：

1. 运行入口确定 agent、workspace、执行目录、model/harness、session target 和 active project keys。
2. session preparation 根据持久化 snapshot、watcher version、agent filter、node eligibility 和 session override 选择 skill 状态。
3. attempt setup 解析 sandbox，构造 skill prompt、skill usage paths、环境覆盖和 code-mode catalog。
4. bootstrap resolver 读取固定文件，按 session/privacy 过滤，排除不具备自动注入 provenance 的 `MEMORY.md`/`USER.md`，执行 `agent:bootstrap` hook，最后做路径安全化。
5. bounded bootstrap builder 以固定输入顺序分配 per-file 和 total 字符预算；`USER.md` 另有 4,000 字符上限，`AGENTS.md` 超限时保留头尾并生成 policy digest，其他文件保留头尾和截断标记（`src/agents/embedded-agent-helpers/bootstrap.ts:89-107,216-365,381-443`）。
6. `buildAgentSystemPrompt` 先生成 cache-stable prefix，再在 boundary 后追加日期、动态 project context、渠道/身份、消息投影、动态 provider suffix 和 runtime。context files 会按 `AGENTS`、`SOUL`、`IDENTITY`、`USER`、`TOOLS`、`BOOTSTRAP`、`MEMORY` 顺序排序，未识别文件按路径排序（`src/agents/system-prompt.ts:85-96,170-239,1184-1461`）。

系统提示词的主要优先级表现为“来源与阶段覆盖”，而非通用数值优先级：provider 可以替换 interaction style/tool call style/execution bias 三个命名 section，并分别提供 cache-stable prefix 与 dynamic suffix；`before_prompt_build` 的 `systemPrompt` 可以替换当前系统提示词，prepend/append system context 再包到其两侧；context engine 的 `systemPromptAddition` 在历史 assemble 后追加到运行时系统提示词。相同阶段的普通 prepend/append 内容按 queued injections、turn prepare、heartbeat contribution、prompt-build hook 的顺序合并（`src/agents/system-prompt-contribution.ts:6-34`；`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts:119-187`；`src/agents/embedded-agent-runner/run/attempt-history.ts:507-631`）。

工具 allowlist 也参与编译结果：prompt hook 返回 `toolsAllow` 后，embedded runner 将它与 host baseline 相交，再更新 session active tools；随后生成的 prompt tool catalog、uncompacted tool set 和 replay allowlist 分别用于当前请求、预检和后续恢复。一个 hook 因而可以同时改变模型可见工具和模型可见文本，但不自动获得工具执行授权；需要 `requiresToolAuthority` 的 hook 必须在 host 已确定工具面后运行（`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts:61-133`；`src/plugins/hook-types.ts:96-138,253-280`；`src/plugins/registry-registrars-tools-hooks.ts:429-460`）。

### Memory 选择与注入

memory prompt section 只在 `promptMode=full` 且当前 runtime 允许时构建；`minimal` subagent prompt 不包含完整 memory section。memory-core 根据实际可用的 `memory_search`/`memory_get` 工具动态生成 recall 指导，并将引用模式、agent、session key 和 sandbox 状态作为准备上下文；memory wiki 等补充插件在异步准备阶段生成其附加行，主 prompt builder 再按稳定 plugin id 排序拼接（`src/agents/system-prompt.ts:280-302,1047-1155`；`src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:230-240`；`src/plugins/memory-state.ts:184-245`）。

active-memory 的请求前选择有更细条件：必须有当前 turn 的 tool authority，memory tools 必须仍被 allowlist 允许，session/agent/渠道类型和 private destination 必须符合配置；lane 1 对 curated trigger 做 lexical-only 预筛，强命中最多注入三个短片段；需要回顾过去且 lane 1 不足时，lane 2 才启动受预算、超时和 authority 约束的 recall subagent。失败、超时、session disabled、无 private recall 能力或 authority 关闭时返回空结果，通常只记录 status/diagnostic，不阻断主回复（`extensions/active-memory/trigger-recall.ts:11-19,59-125,147-237`；`extensions/active-memory/index.ts:240-550`）。

memory-lancedb 的 auto-recall 是可选的独立 `before_prompt_build` 实现：只有 `autoRecall`、`memory_recall` 工具 authority、有效 agent 和长度足够的 prompt 同时满足时才查询；embedding/search 共用 15 秒 deadline，embedding timeout 会触发 agent 级 cooldown，成功结果最多三条，包装为“历史 context” prepend，而不是改写原始 user prompt（`extensions/memory-lancedb/auto-recall.ts:19-67,79-147`）。它与 memory-core 的能力注册和 active-memory 选择是不同插件路径，不能仅凭都有 recall 名称推断二者同时生效。

### 历史、context engine 与当前 prompt

在历史进入模型前，运行器先做 transcript sanitize、Provider replay validation、heartbeat artifact 过滤、history turn limit 和 tool-use/tool-result pairing repair。这个步骤属于相邻的会话上下文管理，但它决定 context engine 接收的消息集合（`src/agents/embedded-agent-runner/run/attempt-history.ts:423-551`）。

如果有 active context engine，`assembleHarnessContextEngine` 会把 runtime-only custom messages先移除，再以当前 message budget、available tools、citation mode、model、prompt 和 runtime settings 调用 engine。返回的 messages 成为后续 model history，`systemPromptAddition` 通过 cache-aware prepend 进入 system prompt；调用失败时当前 attempt 记录警告并继续使用未经 engine 改写的 pipeline messages，而 registry 对非 legacy engine 的生命周期错误会按 operation 进行 quarantine/fallback（`src/agents/harness/context-engine-lifecycle.ts:160-224`；`src/context-engine/registry.ts:124-197,245-292`）。

engine 的 `promptAuthority` 只改变 preflight 采用的 token estimate，不改变 `assemble().messages` 的模型可见权威性。`assembled` 使用 assemble 结果，`preassembly_may_overflow` 额外保留未窗口化历史供溢出预检；`ownsCompaction` 为 true 时，通用 pre-prompt compaction 默认跳过，但 engine 返回前述 authority 时仍可保留 safeguard（`src/context-engine/types.ts:7-38`；`src/agents/embedded-agent-runner/run/attempt-prompt-preflight.ts:187-229`）。

### Prompt hook 与运行时分流

`resolvePromptBuildHookResult` 每个 run 只 destructive-drain 一次 queued next-turn injections，并按 run id 缓存，使同一 run 的 provider fallback/retry 不会丢掉注入；随后依次执行 `agent_turn_prepare`、heartbeat-only contribution 和 `before_prompt_build`。普通 prepend/append context 先加入 effective prompt，system prompt replacement/context 只改变当前 model-bound system prompt；失败按 hook 粒度记录 warning 并返回空 contribution（`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts:61-117,119-188`）。

当前 turn 会同时保留 `promptForSession` 与 `promptForModel`。前者是可持久化的 bare transcript prompt，后者可以带 hook prepend/append；inbound context、heartbeat outcome、跨 session provenance 和其他运行时信息在需要时放入 `display:false` 的 custom message 或系统上下文。`resolveRuntimeContextPromptParts` 会从 model prompt 中剥离这类内部上下文，防止事件同时出现在可见 user 文本和隐藏 carrier 中（`src/agents/embedded-agent-runner/run/runtime-context-prompt.ts:114-245,247-285`；`src/agents/embedded-agent-runner/run/attempt-prompt-build.ts:555-652`）。

## 3. 请求层编译与模型可见结果

对 embedded/OpenClaw harness，`prepareEmbeddedAttemptPrompt` 在提交前安装两类临时边界：`installModelPromptTransform` 只替换 active user turn 的模型文本，使 `transcriptPrompt` 保持原样；`installRuntimeContextMessageForPrompt` 将隐藏 carrier 放入本次 prompt 和重试 prompt，并在提交结束后移除。真正模型调用由 Agent Core 的 `streamAssistantResponse` 执行：先运行 `transformContext`，再 `normalizeCoreContextMessages`，然后 `convertToLlm`，最后将 system prompt、转换后 messages 和 tools 交给 `streamFn`（`src/agents/embedded-agent-runner/run/attempt-llm-boundary.ts:267-343`；`packages/agent-core/src/agent-loop.ts:511-551`）。

因此，本类别中最接近最终请求的证据是 `context.compiled` trajectory event、`prompt:before` cache trace 和 `streamFn` 接收的 `Context`；系统提示词本身由 `buildAttemptSystemPrompt` 先渲染，再经过 provider transform，raw model run 则保留 base prompt 供诊断而向 provider 传空 system prompt（`src/agents/embedded-agent-runner/run/attempt-system-prompt.ts:28-59`；`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts:197-221`）。

CLI backend 的模型可见结果仍来自 OpenClaw 生成的 system prompt 和 prompt text，但消费面由 backend contract 决定：新 session 可通过 system prompt arg/file/config key 发送，复用 session 时按 `systemPromptWhen` 决定是否重发；prompt 通过 argv 或 stdin 发送，超出 `maxPromptArgChars` 时切换到 stdin。系统提示词临时文件会去掉内部 cache boundary，避免把内部传输标记暴露给 CLI（`src/agents/cli-runner/helpers.ts:100-179,199-257,360-382`；`src/agents/cli-runner/execute.ts:140-205,235-250`）。

CLI 的 prompt build 顺序是：先加载 OpenClaw transcript history 与 bootstrap/context files，再得到 skills prompt，构造 system prompt，运行 backend-owned system transform，应用 `before_prompt_build` 的 prepend/append 与 system replacement，加入 inbound context/provenance，必要时生成 OpenClaw history prompt，最后再做 backend text transform 和 model identity。因而 CLI 的 prompt catalog、native CLI `--plugin-dir` 和最终 argv/stdin 是三个不同证据层（`src/agents/cli-runner/prepare.ts:900-969,1580-1640,1641-1788`；`src/agents/cli-runner/execute.ts:162-205`）。

### Native Codex 投影

Codex app-server 不直接接收 OpenClaw embedded 的 `systemPrompt` 字符串作为唯一 system message。Codex plugin 将 OpenClaw 的 workspace files 分成 thread-level project `AGENTS.md`、turn-scoped `SOUL.md`/`IDENTITY.md`/`USER.md` 等 collaboration developer instructions、memory tool guidance 和 prompt context，再通过 thread start/resume 与 turn start 参数投影；项目文档的 native Codex 预算默认为 128 KiB（`extensions/codex/src/app-server/attempt-context.ts:250-294,711-809`；`extensions/codex/src/app-server/project-doc-thread-config.ts:4-8`）。

Native Codex 侧会避免重复注入执行目录的 `AGENTS.md`，在另一个执行目录时才向 thread-level developer instructions 补充 agent workspace 的 `AGENTS.md`；`MEMORY.md` 在 memory tools 可用时改为小型指导并按需读取，否则才使用 bounded fallback。OpenClaw 还只把允许的动态工具转换成 Codex dynamic tool specs，并按 Codex harness 的安全 deny list 限制若干 OpenClaw-only tools（`extensions/codex/src/app-server/attempt-context.ts:711-789`；`extensions/codex/harness.ts:21-50`）。

本次直接核对的 Codex 源码说明其自身模型可见上下文要求是增量构建、避免频繁改变以保持缓存、所有注入项有硬上限且单项不超过 10K tokens，注入片段使用 `ContextualUserFragment` 契约；其 prompt debug 集成测试以 `build_prompt_input` 的最终 `ResponseItem` 数组检查 workspace `AGENTS.md` 和当前 user message，而不是只检查配置（兄弟仓库 `codex-rs/core/tests/suite/prompt_debug_tests.rs:19-78`；`codex-rs/AGENTS.md:91-100`）。这支持将 Codex projection 归为模型请求层编译，但不把 Codex 内部 native project-doc discovery 误写成 OpenClaw 的权威文件加载。

Codex 的 context-engine projection 还有独立生命周期：如果 assemble 返回 `thread_bootstrap` 和稳定 epoch，OpenClaw 只在 epoch 改变时重新投影；否则按 turn 投影。projection decision、assembled message 数、prompt chars 和 developer addition chars 会写入运行日志，但这仍是投影诊断，不是 raw provider request dump（`src/context-engine/types.ts:31-48`；`extensions/codex/src/app-server/run-attempt-prompt.ts:147-183`）。

## 4. 消息生命周期变换与交接

规则编译结果对权威 transcript 的影响分为三类。第一类是 prompt-only：skills catalog、memory recall prepend、provider prompt contribution、hook context 和多数 system prompt additions 只改变本次或下一次模型输入，不写回 bare user transcript。第二类是 runtime carrier：inbound metadata、heartbeat outcome、inter-session provenance 和下一轮上下文可作为 hidden custom message 临时进入模型，再在提交/清理时从可见 transcript 过滤。第三类是 durable lifecycle：用户原文、assistant response、compaction summary、skill snapshot、bootstrap completion marker 和 memory flush 写入各自的 session/state/workspace owner。

embedded prompt 提交时会先用 `onFinalPromptText` 记录 transcript prompt，再通过 Agent Core 产生 assistant/tool messages；Agent event 的 `message_end` 进入 session manager，正常成功 turn 之后 context engine 获得去除 runtime carrier 的 conversation snapshot，优先调用 `afterTurn`，否则批量或逐条 `ingest`，随后执行 maintain。失败、abort、yield 和 prompt error 不推进成功 turn 的 context-engine durable state（`src/agents/embedded-agent-runner/run/attempt-prompt-submit.ts:134-188`；`src/agents/harness/context-engine-lifecycle.ts:262-383`；`src/agents/embedded-agent-runner/run/attempt-finalize.ts:228-333`）。

compaction 是输入历史的明确重写边界。内置路径先读取并验证 transcript、限制历史、运行 before-compaction hooks，然后让 server endpoint 或 embedded compaction model 生成 summary；成功后 `SessionManager.appendCompaction` 写入摘要并把 active agent messages 替换为 compaction 后的 replay-safe context。原始完整历史仍保留在 SQLite transcript，后续模型看到的是 summary 加近期 tail（`src/agents/embedded-agent-runner/compaction-session-execution.ts:314-365,374-489`；`src/agents/sessions/agent-session-compaction.ts:249-275`）。

context engine 选择改变 compaction 交接方式：`ownsCompaction:true` 时 engine 负责 `/compact`、overflow recovery 和自己的 proactive compaction；非 owning engine 仍必须实现 `compact()`，不会自动回落成 legacy compaction。engine 成功或失败会进入 registry 的 quarantine/fallback 逻辑，当前 turn 的 `assemble` 失败保留原 pipeline messages，`compact`/subagent preparation 等需要保留强失败语义的 operation 则不会静默替换（`docs/concepts/context-engine.md:342-384`；`src/context-engine/registry.ts:151-197`）。

compaction 前的 memory flush 是另一条交接链：只有非 heartbeat、非 CLI、workspace 可写且 memory flush plan 命中阈值时运行一个 silent maintenance turn；该 turn 使用专门的 prompt、system prompt、model、daily memory write path 和独立 run authority。它把未写入的持久事实追加到当天 `memory/*.md`，然后主会话才进行 compaction；flush 失败达到上限时会记录 degraded outcome，必要时轮换 bloated session，但主用户回复仍有明确的继续或错误结果（`src/auto-reply/reply/agent-runner-memory.ts:1085-1144,1164-1333,1345-1517`；`src/auto-reply/reply/agent-runner-execute.ts:190-270`）。

## 5. 显示层投影与消息渲染器交接

本次检查没有把 prompt report、trajectory、`/context` 输出或 Codex developer-instruction snapshot 当作模型权威消息。`systemPromptReport` 只保存 system prompt 的字符数/hash、Project Context 计数、bootstrap raw/injected/truncated 统计、skill block 统计和 tool schema 统计，不保存原始 prompt 正文；run report 写回 session entry，`/context` 优先读取它，没有 run report 时才生成 estimate（`src/agents/system-prompt-report.ts:1-6,101-164`；`src/config/sessions/session-system-prompt-report.ts:1-75`；`src/auto-reply/reply/commands-context-report.ts:57-163`）。

`/context list|detail|json` 展示文件、skills、tools、prompt size、token estimate 和 compactable transcript 数；`/context map` 只有在存在实际 run report 时才生成 treemap。map 会额外统计 runtime context 和 model-only prompt，因为它们进入模型却不在 transcript；它仍是按字符和估算 token 组织的诊断图片，不是完整网络 payload 或 hook trace（`src/auto-reply/reply/commands-context-report.ts:166-263,275-420`）。

显示与权威消息的分界由数据结构表达：runtime context custom message 使用 `role:"custom"`、`display:false` 和 `runtimeContextCarrier:true`，模型转换前会被重定位或过滤；hook 的 `historyMessages` 给插件的是 cloned snapshot；trajectory 记录 `context.compiled`，但不反向修改 session。由此，模型-only 的 memory/hook context 和用户可见 Markdown 需分别追踪，不能从 `/context` 或 UI 状态倒推权威 transcript（`src/agents/embedded-agent-runner/run/runtime-context-prompt.ts:25-32,266-285`；`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts:293-335`；`src/agents/embedded-agent-runner/run/attempt-session-prepare.ts:369-379`）。

对普通 SDK/CLI session，prompt template 展开和 extension command 处理也发生在输入处理层而非消息渲染器。extension command 找到后可以直接执行并不发送 LLM prompt；模板或 skill command 展开后才创建 user message。流式期间的新输入被分类为 steer/follow-up，展开后的内容进入队列并在后续 loop checkpoint 交接（`src/agents/sessions/agent-session-prompting.ts:124-175,205-257,334-387`；`packages/agent-core/src/agent.ts:398-445`）。

## 6. 调试、预览与可解释性

OpenClaw 有多层可解释表面，但覆盖范围不同：

- `systemPromptReport` 是每个 embedded/CLI run 的结构化摘要，能核对 prompt hash、字符预算、注入文件、skills block 和 tool schema；它不提供完整原文，也不逐条列出 hook 命中差异。
- `/context list`、`detail`、`json` 和 `map` 从 run report 或 estimate 构造操作者可读的上下文账本；`map` 明确拒绝只凭 estimate 生成实际运行 treemap。
- cache trace 的 `prompt:before`、`prompt:images` 和 trajectory 的 `context.compiled`/`prompt.submitted` 保存模型边界附近的消息、system prompt、tools、图片数和 transport；它们是运行观测记录，不是所有 Provider 的原始 HTTP body。
- `llm_input` hook 在提交前异步收到 system prompt、LLM boundary prompt、cloned history 和 tools；失败只写 warning，不改变已准备的 prompt。这个 hook 是观察面，不是同步改写面（`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts:197-221,293-337`）。
- Codex harness 的测试 API 可构造 thread/resume/turn prompt snapshot；Codex app-server 的 context report 能记录 developer instructions hash 和动态 tool schema，但 native Codex 自己加载的 project docs 仍可能超出 OpenClaw 的 per-file report（`extensions/codex/test-api.ts:44-104`；`extensions/codex/src/app-server/attempt-context.ts:301-349`）。

可编辑规则本身没有一个统一的“命中规则列表”或“编译前后 diff”界面。skills 有 `openclaw skills check`、来源/冲突/扫描诊断和 snapshot metadata；Skill Workshop 有 proposal list/inspect/evaluate/apply、SQLite 状态和事件；memory/active-memory 有 status、debug 与 recall outcome；这些表面分别属于资源、治理和检索 owner，不能合并成一个通用 prompt debugger。此次未找到一个能同时展示 skill、template、bootstrap、memory、hook、context-engine 命中顺序和最终 Provider payload 的统一预览器。

## 7. 失败、更新与已确认边界

### 失败收口

- 工作区 bootstrap 文件使用 boundary-safe open/read、realpath/source identity、2 MiB 单文件读取上限和 transient I/O retry；读取失败会进入 `[UNREADABLE: ...]` 内容或 missing 记录，继续由预算和 prompt builder处理，而不是无提示地把文件当作成功读取（`src/agents/workspace.ts:138-199,1145-1219`；`src/agents/workspace-bootstrap-read.ts:1-11`）。
- bootstrap context 超限会保留截断 marker；total budget 耗尽时停止继续注入，warning 进入 system prompt 并进入报告。`USER.md`、`AGENTS.md` 与普通文件有不同的截断策略，但没有通用的 Markdown 语义解析或循环 include 展开（`src/agents/embedded-agent-helpers/bootstrap.ts:216-365,381-443`）。
- skill frontmatter 解析异常、无效依赖 gate、越界路径、缺失技能文件和不安全 snapshot 只让该 skill 被跳过、过滤或从当前 catalog 重建；snapshot prompt 结构异常时不会继续进行不安全的 XML 局部过滤（`src/skills/loading/workspace-skill-loader.ts:190-215,535-570`；`src/skills/loading/workspace-skill-prompt.ts:106-190`）。
- prompt template 的文件读取异常、未知模板名和未匹配 slash command 保持原输入或记录资源诊断；占位符没有递归展开，因此没有由模板自身引起的循环替换路径。extension command handler 错误通过 extension error surface 报告，并将该命令视为已处理（`src/agents/sessions/prompt-templates.ts:30-60,176-198`；`src/agents/sessions/agent-session-prompting.ts:262-287`）。
- prompt hook、memory recall 和异步 memory preparation 都有独立错误/超时边界。普通 prompt hook 失败会返回无 contribution；active-memory 超时或 authority 关闭会跳过 recall；memory prompt preparation 若在 context engine assemble 前失败，则由外层 context-engine/runner 的 fallback 规则处理（`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts:119-188`；`extensions/active-memory/index.ts:291-345,532-550`；`src/plugins/memory-state.ts:184-245`）。
- context engine assemble 的 invalid result 会被 shape validator 拒绝并回到 pipeline messages；运行时异常会记录 engine quarantine，后续多数 guarded calls 使用 fallback engine。host capability 不满足时则在 run 前 fail closed，因为继续执行可能破坏 engine 的 transcript 语义（`src/agents/harness/context-engine-lifecycle.ts:227-249`；`docs/concepts/context-engine.md:315-354`）。

### 更新与缓存

工作区 bootstrap 文件以文件 identity/content cache 复用读取结果，但有 session cache 的 per-turn refresh，因此长会话可看到文件编辑；skills 以 watcher 250ms debounce bump snapshot version，新的 snapshot 通常在下一 agent turn 采用；配置/agent filter/remote node eligibility 变化也会触发 snapshot rebuild。Prompt-state mutation 默认不在当前已构建 run 中同步重编译，后续 turn 或新 session 才消费新的资源（`src/agents/bootstrap-cache.ts:1-67`；`src/skills/runtime/refresh.ts:53-80`；`src/skills/runtime/refresh-state.ts:29-84`）。

系统提示词稳定部分使用有上限的 process-local cache，key 包含 workspace、prompt mode、tool lines、provider contribution、skills prompt、memory section 和 stable context files；动态时间、渠道、身份、runtime、watched sessions 和 dynamic project context 位于 cache boundary 后。provider prompt contribution 也显式区分 stable prefix 与 dynamic suffix，避免每轮动态信息破坏可复用前缀（`src/agents/system-prompt.ts:98-145,1184-1225,1459-1566`；`src/agents/system-prompt-contribution.ts:12-34`）。

### 本次检查范围内未找到的能力

本次检查范围内未找到一个通用的、可编辑规则对象系统，能够像某些 preset/lorebook/宏引擎一样以统一 schema 保存任意规则、按关键词/概率/深度/冷却命中，再以统一编译顺序生成消息数组。OpenClaw 的独立能力是“多种文件与插件贡献者的上下文编译”，其中 skills、prompt templates、prompt hooks、memory 和 context engine 各自拥有 owner、schema、作用域和错误边界；它们不是一个共享的规则 AST。

依据包括：系统提示词 renderer 接收已经准备好的 `contextFiles`、`skillsPrompt`、`extraSystemPrompt` 和 provider contribution，而不加载规则源本身（`src/agents/system-prompt.ts:787-870`）；embedded resource loader 明确关闭 ambient skills、prompt templates、themes 和 context-file discovery，要求上层提供 prepared resources（`src/agents/embedded-agent-runner/resource-loader.ts:5-28`）；普通 SDK session 的 template loader 和 embedded runner 的 skill/bootstrap loader 也是两条不同资源路径（`src/agents/sessions/resource-loader.ts:178-267`；`src/agents/embedded-agent-runner/run/attempt.ts:156-347`）。因此，若按“独立规则编译器”理解为统一规则 schema/命中器，本次应标为**归并到相邻类目**：具体能力分别归 skills、对话请求与上下文、记忆、context engine 和会话管理，而不是为了对称虚构一个 OpenClaw preset/macro/lorebook 层。

## 8. 未验证事项

- 未运行真实 Provider、CLI 进程或 Codex app-server，未取得某个具体渠道和模型下的最终网络 payload；上述请求层结论以紧邻 `streamFn`、CLI argv/stdin、Codex thread/turn request builder 为依据。
- 未运行多根 skill 同名冲突、agent allowlist、session override、remote node skill、sandbox skill remap 与 `disable-model-invocation` 的组合场景；静态排序、过滤和 snapshot invalidation 已由代码确认。
- 未运行 `$skill`、slash skill command、`command-dispatch: tool`、prompt template 参数切片、参数内容包含占位符和未知命令的全部组合；模板替换的单次行为和上限由代码确认。
- 未核对每个 bundled memory/plugin 的实际 prompt supplement、异步 preparation、auto-recall 和 context-engine 组合结果；memory-core、active-memory、memory-lancedb 的各自入口和分流已定位。
- 未运行 active-memory lane 1/lane 2、private transcript recall、project-scoped memory、provenance 不 eligible、cooldown、timeout、compaction 前 flush 的实际命中和可见输出。
- 未运行 context engine plugin 的 `assemble` 重排、`systemPromptAddition`、`ownsCompaction`、`promptAuthority`、quarantine/fallback、thread bootstrap projection 和 subagent spawn 交互。
- 未确认所有渠道上 `/context` 的显示投影、trajectory 保存策略、日志保留/脱敏策略以及 `llm_input` 异步观测与实际 Provider 请求的时序一致性。
- `IDENTITY.md` 的文件解析和 agent identity 配置同步已静态确认，但它在每一种 harness 的提示词文本、渠道显示和 native Codex collaboration instruction 中的最终字节布局未运行核对。

## 9. 关键源码索引

- `src/agents/embedded-agent-runner/run/attempt.ts:57-84,156-347`：embedded attempt 的 skills、bootstrap、工具、system prompt 和 session runtime 准备顺序。
- `src/agents/system-prompt.ts:787-870,1130-1225,1304-1566`：OpenClaw 系统提示词 renderer、section 顺序、stable/dynamic cache boundary 和 prompt mode。
- `src/agents/workspace.ts:721-857,903-1142,1145-1288`：工作区模板创建、bootstrap 完成状态、固定文件读取和 session/privacy 过滤。
- `src/agents/bootstrap-files.ts:237-410` 与 `src/agents/embedded-agent-helpers/bootstrap.ts:89-107,216-443`：memory provenance、bootstrap hooks、文件预算、截断和 context file 构建。
- `src/skills/loading/workspace-skill-loader.ts:375-570,588-680`、`src/skills/loading/workspace-skill-prompt.ts:31-190`：skill 根目录优先级、过滤、snapshot 和 `<available_skills>` 编译。
- `src/skills/discovery/chat-command-invocation.ts:66-115,161-293`、`src/agents/sessions/prompt-templates.ts:108-225`：显式 skill 引用、命令模板和参数占位符展开。
- `src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts:91-188`、`src/agents/embedded-agent-runner/run/attempt-prompt-build.ts:110-303,478-684`：prompt hook 顺序、system/prompt prepend/append、运行时上下文分流。
- `src/agents/embedded-agent-runner/run/attempt-history.ts:396-640`、`src/agents/harness/context-engine-lifecycle.ts:160-249,262-383`：历史准备、context engine assemble、afterTurn/ingest/maintain 交接。
- `packages/agent-core/src/agent-loop.ts:511-551`、`src/agents/embedded-agent-runner/run/attempt-llm-boundary.ts:267-343`：`transformContext`、`convertToLlm` 到 Provider `streamFn` 的最终请求边界。
- `extensions/memory-core/index.ts:243-270,288-323`、`extensions/active-memory/index.ts:240-550`、`extensions/memory-lancedb/auto-recall.ts:38-147`：memory prompt guidance、主动 recall 和模型上下文 prepend。
- `src/auto-reply/reply/agent-runner-memory.ts:1085-1517`、`src/agents/embedded-agent-runner/compaction-session-execution.ts:314-489`：compaction 前 memory flush 与 compaction summary/transcript 交接。
- `src/agents/system-prompt-report.ts:101-164`、`src/auto-reply/reply/commands-context-report.ts:131-420`：prompt report、`/context` 诊断和显示投影边界。
- `extensions/codex/src/app-server/attempt-context.ts:250-349,711-809`、`extensions/codex/src/app-server/run-attempt-prompt.ts:147-183,187-328`：native Codex workspace/context-engine projection。
- 兄弟 Codex 直接核对：`codex-rs/AGENTS.md:91-100`、`codex-rs/core/tests/suite/prompt_debug_tests.rs:19-78`：Codex 增量上下文硬约束和 workspace prompt input 测试。
