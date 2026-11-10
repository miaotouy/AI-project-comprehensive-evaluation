# OpenClaw 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：静态阅读 OpenClaw 的 embedded、CLI 与 Codex harness 路径，追踪工作区 bootstrap 文件、skills、prompt hooks、memory、context engine、compaction、模板和请求前 transform；并直接核对兄弟 Codex 仓库的模型可见上下文与 skills 约束
>
> 调查范围：可编辑或可持久化的工作区指令文件、身份与记忆文件、skills、prompt 模板、插件 prompt 注入、context engine、运行时上下文分流、compaction 交接、请求层与调试投影；不覆盖普通会话 CRUD、渠道传输、Provider 协议细节和消息渲染实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 在本次检查范围内具备独立的运行时上下文编译能力。规则对象分布在工作区 Markdown、skills、文件 prompt 模板、插件 hook、memory 插件和可选 context-engine 插件中；embedded 运行器先准备这些来源，再由 `buildAgentSystemPrompt` 生成系统提示词，并在模型调用前把会话消息转换成 Provider 可见的数组。

- 运行器把工作区文件当作可编辑的上下文源：身份、用户偏好、长期记忆和首次运行仪式各有独立的生命周期，文件会不会进入 prompt 取决于会话隐私设置、bootstrap 状态、memory provenance 和运行器类型（`src/agents/workspace.ts`；`src/agents/bootstrap-files.ts`）。
- skills 是 OpenClaw 中实现最完整的一类规则对象。加载器先按优先级合并多个根目录，过滤后生成有字符上限的 `<available_skills>` 目录，目录里只放元数据，正文留到模型按需读取；显式 `$skill` 引用另走一条有限的请求前展开路径（`src/skills/loading/workspace-skill-loader.ts`；`src/skills/loading/workspace-skill-prompt.ts`）。
- prompt 模板与 slash command 构成文件型输入预处理层。模板可以从 agent 目录、项目目录、显式路径和扩展资源加载，参数只做单次替换；embedded 运行器接收上层准备好的资源，SDK session 则在输入阶段展开模板（`src/agents/sessions/prompt-templates.ts`；`src/agents/sessions/agent-session-prompting.ts`）。
- 插件 hook、memory 和 context engine 能在不同阶段追加或替换模型上下文，也能收窄工具面。三者各自持有 authority 判定、超时和降级策略（`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts`；`src/agents/embedded-agent-runner/run/attempt-history.ts`）。
- 编译结果最终流向三处：模型请求、权威会话和诊断投影。模型专用的 prepend context 只进入模型请求，可见 transcript 由 session 层维护；`systemPromptReport` 与 `/context` 输出属于诊断投影，Provider payload 由运行器在请求边界组装（`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts`；`src/auto-reply/reply/commands-context-report.ts`）。

## 系统边界与规则编译主链

本类别记录会改变模型输入、权威 transcript 或其可解释投影的可编辑/可持久化对象。普通固定 system prompt、一般工具注册、历史截断和 Provider 调用本身不单独视为规则对象，但它们与规则结果的交接会在相应阶段说明。OpenClaw 的 legacy context engine 只包装既有运行时流程；独立的消息编译和 compaction 仍由 embedded runner 持有（`src/context-engine/legacy.ts`）。

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

embedded 主入口是 `runEmbeddedAttempt`。它先准备 skills、bootstrap、工具和系统提示词，再进入执行阶段恢复并编译历史，最后在 prompt 阶段执行 prompt hook、运行时上下文分流、预检和提交（`src/agents/embedded-agent-runner/run/attempt.ts`；`src/agents/embedded-agent-runner/run/attempt-execution-phase.ts`；`src/agents/embedded-agent-runner/run/attempt-prompt-phase.ts`）。CLI backend 复用 bootstrap、skills 和 hook 语义，但把系统提示词写入参数或临时文件；Codex app-server 则把 OpenClaw 结果投影为 thread/turn 的 developer instructions 和 prompt 字段。

## 1. 规则对象、权威源与作用域

### 工作区文件与身份

工作区文件的权威源是 agent workspace 下的文件，而不是一个独立的 prompt 数据库。`ensureAgentWorkspace` 按模板创建必需的工作区文件，只有新工作区才创建 `BOOTSTRAP.md`；模板从打包的 `docs/reference/templates` 搜索目录读取，并去掉 frontmatter 后写入（`src/agents/workspace.ts`；`src/agents/workspace-templates.ts`）。

运行时把这些文件表示为带文件名、路径、内容和 missing 状态的 `WorkspaceBootstrapFile`。该对象没有通用版本字段或规则 AST，Markdown 正文仍由模型直接消费（`src/agents/workspace.ts`）。

这些文件的身份和生命周期不同：工作区规约、人格语气、用户偏好、长期事实和首次运行仪式各有独立文件；`IDENTITY.md` 另外承担结构化身份记录。身份解析只识别有限的 Markdown 标签并忽略模板占位符，工具只回写稳定身份字段，不把所有自由文本都同步为配置（`src/agents/identity-file.ts`）。

工作区文件的作用域首先由 agent workspace 决定。当执行目录是另一个 worktree 或项目目录时，运行器只把该目录的 `AGENTS.md` 作为项目层文件追加到 agent workspace 文件之后，其他身份/记忆文件不会从执行目录加载（`src/agents/embedded-agent-runner/run/attempt-bootstrap-prepare.ts`）。

项目记忆会按已准备的 repository key 过滤带项目注释的 curated 条目；未激活项目的条目不进入 Project Context（`src/agents/project-memory-bootstrap.ts`）。

`BOOTSTRAP.md` 不是普通长期规则。只有主 agent 的交互式用户/手动运行、canonical workspace 和文件访问权同时满足时才使用 full 模式；heartbeat、cron、subagent 和非交互运行不执行该仪式，无文件访问权时只使用 limited 引导（`src/agents/bootstrap-mode.ts`；`src/agents/bootstrap-routing.ts`）。

完整流程成功后，运行器把完成标记写入 transcript，continuation-skip 才能跳过重复注入；compaction 或 reset 会使该标记失效（`src/agents/embedded-agent-runner/run/attempt-context-engine-helpers.ts`；`src/agents/embedded-agent-runner/run/attempt-finalize.ts`）。

### Skills

skill 的权威源是包含 `SKILL.md` 的目录。`metadata.openclaw` 前言块提供平台、依赖、环境、配置和安装门控；顶层 invocation 字段负责控制命令与模型目录可见性（`src/skills/loading/frontmatter.ts`）。

当前类型没有 skill 内容版本字段；session snapshot 另存 watcher 版本和 prompt 格式版本，用于判断可否复用已解析状态（`src/skills/types.ts`）。

skill 根目录按来源合并，同名项由高优先级来源覆盖；最终目录按 skill name 稳定排序，独立执行 root 与 agent workspace 同名时以前者为准。来源冲突会记录诊断，目录和 `SKILL.md` 还受 realpath、hardlink 和 symlink target 约束（`src/skills/loading/workspace-skill-loader.ts`）。

skill 的模型可见性和运行时可用性是两套面。配置禁用、secret degraded、bundled allowlist 以及平台/依赖门控先决定 eligible；随后 agent allowlist 和 session overlay 决定当前 agent 是否可见（`src/skills/loading/config.ts`；`src/skills/discovery/agent-filter.ts`）。

`disable-model-invocation:true` 只从正常模型目录和 picker 隐藏 skill，授权的显式引用仍可调用；因此“能被运行时加载”和“会出现在模型目录”不是同一状态（`src/skills/discovery/skill-index.ts`）。

session preparation 把有效 skill snapshot 写入 session entry。snapshot 保存目录、完整 eligible identities、过滤状态、node eligibility、解析后的 skill 对象和版本；prompt 正文仍由当前可读的 skill 文件提供（`src/agents/command/session-preparation.ts`；`src/skills/loading/workspace-skill-prompt.ts`）。

后续运行会在 prompt 格式、watcher version、roots、filter、overrides 或 node eligibility 变化时重建 snapshot，否则可从已有 snapshot 恢复（`src/skills/runtime/session-snapshot.ts`）。

skill 的写入和发布面由 Skill Workshop 管理。提案在 SQLite 中保存版本、来源、工作区、状态、hash 和扫描结果；apply 在目标锁下重新校验内容与目标树，再写入 `SKILL.md` 及受限 support files，成功后提升 skill snapshot version（`src/skills/workshop/store-sqlite-record.ts`；`src/skills/workshop/apply-transition.ts`）。

ClawHub、Git、本地目录和上传归档属于 skill 的安装/迁移入口，Workshop proposal 属于待审写入状态；本次未找到把所有工作区 Markdown 规则统一导入导出的 schema。memory 的外部导入也保持为独立的 Markdown 文件，不合并进 agent 的 `MEMORY.md`（`docs/tools/skills.md`；`docs/concepts/memory.md`）。

### Prompt 模板、命令与占位符

文件 prompt 模板是 agent SDK session 的独立资源对象。默认来源包括 agent directory 下的 `prompts/`、项目 `.openclaw/prompts/`，以及 extension/CLI 提供的显式路径；每个 Markdown 文件以文件名作为模板名，frontmatter 可提供描述与参数提示，正文成为模板 body。加载失败被忽略并形成有限诊断，重名时保留先加载者并记录 collision（`src/agents/sessions/prompt-templates.ts`；`src/agents/sessions/resource-loader.ts`）。

模板只在消息以 `/` 开头且精确匹配 `/name [args]` 时展开；参数解析支持简单单/双引号，替换支持位置参数、全参数、参数切片，并采用单次正则替换，插入参数不会被第二轮重新解释。缺失或不安全的数字占位符替换为空文本（`packages/agent-core/src/harness/prompt-template-arguments.ts`；`src/agents/sessions/prompt-templates.ts`）。

skill 命令与 prompt 模板共享 slash 资源表，但模型引用另有 `$skill-name` 语法。普通消息中的 `$` 引用会被解析为当前 agent 的 eligible、user-invocable skill；最多八个，转义引用和全大写 shell 变量不视为 skill。命中后加入“请读取每个 `SKILL.md`”的有限前缀，未知 slash command 保持原文，allowlist-hidden skill 返回可见错误而不是静默忽略（`src/skills/discovery/chat-command-invocation.ts`；`src/agents/command/prepare.ts`）。

带 `command-dispatch: tool` 和 `command-tool` 的 skill slash command 可以绕过模型直接 dispatch 到工具，参数按 raw 模式转交；没有该配置的 skill command 仍走模型提示。Claude bundle command 还可以声明 prompt template，`$ARGUMENTS` 在命令前置模板中展开（`src/skills/discovery/command-specs.ts`；`src/skills/discovery/chat-command-invocation.ts`）。

### Memory 与上下文引擎

memory 的文件权威源仍是 workspace Markdown，SQLite 主要保存索引、provenance、检索状态和部分插件治理状态。memory-core 通过 `registerMemoryCapability` 声明 deterministic recall tool、private transcript recall、prompt builder、flush plan 和 runtime；其他 memory 插件可添加 prompt supplement、异步 prompt preparation 或 corpus supplement。注册表以当前 active plugin registry 为准，prompt supplement 按 plugin id 排序合成，异步 preparation 先并行完成，再以不可变 snapshot 进入同步渲染（`src/plugins/registry-contribution-types.ts`；`src/plugins/memory-state.ts`）。

context engine 是唯一明确以“assemble model context”为契约的插件面，配置槽 `plugins.slots.contextEngine` 同时只能选一个 engine。默认的 `legacy` 实现只做透传：`ingest` 不做事、`assemble` 原样传出消息、`compact` 委托内置 compaction。

- 非 legacy engine 可实现的钩子如下，另有 subagent 生命周期钩子：

  ```text
  bootstrap  maintain  ingestBatch  afterTurn  commitTurn  assemble  compact
  ```

- engine 通过 `acceptedHostParams` 声明愿意接收哪些宿主字段，例如 sessionKey、prompt、runtimeSettings、sessionTarget 和 runtimeContext；宿主按这份声明收窄注入范围。

钩子与字段的声明位置见 `src/context-engine/legacy.ts`、`src/context-engine/registry.ts`、`src/context-engine/types.ts`。

## 2. 选择条件、优先级与编译顺序

### Bootstrap、skills 与系统提示词

embedded 运行器先准备输入，再编译 prompt：

1. 运行入口确定本次运行使用的 agent、workspace 和执行目录，并选定模型与 harness、session target 以及参与编译的项目键。
2. session preparation 根据持久化 snapshot、watcher version、agent filter、node eligibility 和 session override 选择 skill 状态。
3. attempt setup 解析 sandbox，构造 skill prompt、skill usage paths、环境覆盖和 code-mode catalog。
4. bootstrap resolver 先读取固定文件，再按会话隐私过滤，剔除缺少自动注入 provenance 的 `MEMORY.md` 与 `USER.md`，随后执行 `agent:bootstrap` hook，最后对产物做路径安全化。
5. bounded bootstrap builder 以固定输入顺序分配 per-file 和 total 字符预算；`USER.md` 另有 4,000 字符上限，`AGENTS.md` 超限时保留头尾并生成 policy digest，其他文件保留头尾和截断标记（`src/agents/embedded-agent-helpers/bootstrap.ts`）。
6. `buildAgentSystemPrompt` 先生成 cache-stable prefix，再在 boundary 后追加日期、动态 project context、渠道/身份、消息投影、动态 provider suffix 和 runtime。context files 按固定顺序排序，未识别文件按路径排序（渲染器见 `src/agents/system-prompt.ts`）：

    ```text
    AGENTS → SOUL → IDENTITY → USER → TOOLS → BOOTSTRAP → MEMORY
    ```

系统提示词的优先级以“来源与阶段覆盖”表达，没有通用数值优先级：provider 可以替换 interaction style/tool call style/execution bias 三个命名 section，并分别提供 cache-stable prefix 与 dynamic suffix；`before_prompt_build` 的系统提示词替换可以覆盖当前值，prepend/append system context 再包到其两侧；context engine 的 `systemPromptAddition` 在历史 assemble 后追加到运行时系统提示词。相同阶段的普通 prepend/append 内容按 queued injections、turn prepare、heartbeat contribution、prompt-build hook 的顺序合并（`src/agents/system-prompt-contribution.ts:6-34`；`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts`；`src/agents/embedded-agent-runner/run/attempt-history.ts`）。

工具 allowlist 也参与编译结果：prompt hook 返回 `toolsAllow` 后，embedded runner 将它与 host baseline 相交，再更新 session active tools；随后生成的 prompt tool catalog、uncompacted tool set 和 replay allowlist 分别用于当前请求、预检和后续恢复。一个 hook 因而可以同时改变模型可见工具和模型可见文本，但不自动获得工具执行授权；需要 `requiresToolAuthority` 的 hook 必须在 host 已确定工具面后运行（`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts`；`src/plugins/hook-types.ts`；`src/plugins/registry-registrars-tools-hooks.ts`）。

### Memory 选择与注入

memory prompt section 只在 promptMode 为 full 且当前 runtime 允许构建时生成，minimal 的 subagent prompt 里没有完整 memory section。memory-core 依据本次实际可用的 memory_search 与 memory_get 工具动态写 recall 指导，准备上下文包含引用模式、agent、session key 和 sandbox 状态。memory wiki 等补充插件在异步准备阶段产出附加行，主 prompt builder 按稳定的 plugin id 顺序拼接（`src/agents/system-prompt.ts`；`src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts`；`src/plugins/memory-state.ts`）。

active-memory 的请求前选择有更细条件：必须有当前 turn 的 tool authority，memory tools 必须仍被 allowlist 允许，session/agent/渠道类型和 private destination 必须符合配置；lane 1 对 curated trigger 做 lexical-only 预筛，强命中最多注入三个短片段；需要回顾过去且 lane 1 不足时，lane 2 才启动受预算、超时和 authority 约束的 recall subagent。失败、超时、session disabled、无 private recall 能力或 authority 关闭时返回空结果，通常只记录 status/diagnostic，不阻断主回复（`extensions/active-memory/trigger-recall.ts`；`extensions/active-memory/index.ts`）。

memory-lancedb 的 auto-recall 是可选的独立 `before_prompt_build` 实现：只有 `autoRecall`、`memory_recall` 工具 authority、有效 agent 和长度足够的 prompt 同时满足时才查询；embedding/search 共用 15 秒 deadline，embedding timeout 会触发 agent 级 cooldown，成功结果最多三条，包装为“历史 context” prepend，而不是改写原始 user prompt（`extensions/memory-lancedb/auto-recall.ts`）。它与 memory-core 的能力注册和 active-memory 选择是不同插件路径，二者是否同时生效取决于各自的启用条件。

### 历史、context engine 与当前 prompt

在历史进入模型前，运行器先做 transcript sanitize、Provider replay validation、heartbeat artifact 过滤、history turn limit 和 tool-use/tool-result pairing repair。这个步骤属于相邻的会话上下文管理，但它决定 context engine 接收的消息集合（`src/agents/embedded-agent-runner/run/attempt-history.ts`）。

如果有 active context engine，`assembleHarnessContextEngine` 会把 runtime-only custom messages先移除，再以当前 message budget、available tools、citation mode、model、prompt 和 runtime settings 调用 engine。返回的 messages 成为后续 model history，`systemPromptAddition` 通过 cache-aware prepend 进入 system prompt；调用失败时当前 attempt 记录警告并继续使用未经 engine 改写的 pipeline messages，而 registry 对非 legacy engine 的生命周期错误会按 operation 进行 quarantine/fallback（`src/agents/harness/context-engine-lifecycle.ts`；`src/context-engine/registry.ts`）。

engine 的 promptAuthority 只影响 preflight 阶段采用的 token estimate，assemble 返回消息的模型可见权威性由 assemble 结果本身决定。取值 assembled 时直接采用 assemble 结果；preassembly_may_overflow 额外保留未窗口化的历史供溢出预检。ownsCompaction 为 true 时，通用的 pre-prompt compaction 默认跳过，engine 返回前述 authority 时仍可保留 safeguard（`src/context-engine/types.ts`；`src/agents/embedded-agent-runner/run/attempt-prompt-preflight.ts`）。

### Prompt hook 与运行时分流

`resolvePromptBuildHookResult` 每个 run 只 destructive-drain 一次 queued next-turn injections，并按 run id 缓存，使同一 run 的 provider fallback/retry 不会丢掉注入；随后依次执行 `agent_turn_prepare`、heartbeat-only contribution 和 `before_prompt_build`。普通 prepend/append context 先加入 effective prompt，system prompt replacement/context 只改变当前 model-bound system prompt；失败按 hook 粒度记录 warning 并返回空 contribution（`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts`）。

当前 turn 会同时保留 `promptForSession` 与 `promptForModel`。前者是可持久化的 bare transcript prompt，后者可以带 hook prepend/append；inbound context、heartbeat outcome、跨 session provenance 和其他运行时信息在需要时放入 `display:false` 的 custom message 或系统上下文。运行时上下文剥离会把这类内部上下文从 model prompt 中移除，防止事件同时出现在可见 user 文本和隐藏 carrier 中（`src/agents/embedded-agent-runner/run/runtime-context-prompt.ts`；`src/agents/embedded-agent-runner/run/attempt-prompt-build.ts`）。

## 3. 请求层编译与模型可见结果

对 embedded/OpenClaw harness，提交前会安装两类临时边界，模型调用的真正入口由 Agent Core 持有。

- 模型文本边界：只替换当前 user turn 送往模型的文本，`transcriptPrompt` 保持原样（`installModelPromptTransform`）。
- 运行时上下文边界：把隐藏 carrier 同时放入本次 prompt 和重试 prompt，提交结束后移除（`installRuntimeContextMessageForPrompt`）。

`prepareEmbeddedAttemptPrompt` 负责安装这两处边界。模型调用由 `streamAssistantResponse` 依次完成四步：先转换上下文，再规范化 core 消息，然后转换为 LLM 输入，最后把 system prompt、转换后的 messages 和 tools 交给 `streamFn`。

前三步对应 `transformContext`、`normalizeCoreContextMessages` 和 `convertToLlm`；边界实现见 `src/agents/embedded-agent-runner/run/attempt-llm-boundary.ts`，循环实现见 `packages/agent-core/src/agent-loop.ts`。

因此，本类别中最接近最终请求的证据是 `context.compiled` trajectory event、`prompt:before` cache trace 和 `streamFn` 接收的上下文对象；系统提示词本身由运行器先渲染，再经过 provider transform，raw model run 则保留 base prompt 供诊断而向 provider 传空 system prompt（`src/agents/embedded-agent-runner/run/attempt-system-prompt.ts`；`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts`）。

CLI backend 的模型可见结果仍来自 OpenClaw 生成的 system prompt 和 prompt text，但消费面由 backend contract 决定：新 session 可通过 system prompt arg/file/config key 发送，复用 session 时按 `systemPromptWhen` 决定是否重发；prompt 通过 argv 或 stdin 发送，超出 `maxPromptArgChars` 时切换到 stdin。系统提示词临时文件会去掉内部 cache boundary，避免把内部传输标记暴露给 CLI（`src/agents/cli-runner/helpers.ts`；`src/agents/cli-runner/execute.ts`）。

CLI 的 prompt build 顺序是：先加载 OpenClaw transcript history 与 bootstrap/context files，再得到 skills prompt，构造 system prompt，运行 backend-owned system transform，应用 `before_prompt_build` 的 prepend/append 与 system replacement，加入 inbound context/provenance，必要时生成 OpenClaw history prompt，最后再做 backend text transform 和 model identity。因而 CLI 的 prompt catalog、native CLI `--plugin-dir` 和最终 argv/stdin 是三个不同证据层（`src/agents/cli-runner/prepare.ts`；`src/agents/cli-runner/execute.ts`）。

### Native Codex 投影

Codex app-server 按 thread 与 turn 两层参数接收上下文；Codex plugin 直接从工作区资源、skills 和运行参数构建各字段，使用独立于 embedded systemPrompt 字符串的编译入口（`extensions/codex/src/app-server/run-attempt-context.ts:169-208`）。Codex plugin 把工作区文件分成四类：thread 级的项目 AGENTS.md、turn 级的 SOUL.md、IDENTITY.md、USER.md 等协作 developer instructions、memory 工具指导，以及 prompt context，然后分别通过 thread start/resume 与 turn start 参数发送；项目文档在 native Codex 内的默认预算为 128 KiB（`extensions/codex/src/app-server/attempt-context.ts`；`extensions/codex/src/app-server/project-doc-thread-config.ts:4-8`）。

Native Codex 侧会避免重复注入执行目录的 `AGENTS.md`，在另一个执行目录时才向 thread-level developer instructions 补充 agent workspace 的 `AGENTS.md`；`MEMORY.md` 在 memory tools 可用时改为小型指导并按需读取，否则才使用 bounded fallback。OpenClaw 还只把允许的动态工具转换成 Codex dynamic tool specs，并按 Codex harness 的安全 deny list 限制若干 OpenClaw-only tools（`extensions/codex/src/app-server/attempt-context.ts`；`extensions/codex/harness.ts`）。

本次直接核对的 Codex 源码显示，它要求模型可见上下文增量构建、尽量保持稳定以复用缓存，所有注入项都有硬上限且单项不超过 10K tokens，注入片段统一使用 `ContextualUserFragment` 契约。其 prompt debug 集成测试检查的是最终产出的 `ResponseItem` 数组，从中确认 workspace 的 `AGENTS.md` 和当前 user message 都已进入，配置字段只提供间接依据（兄弟仓库 `codex-rs/core/tests/suite/prompt_debug_tests.rs:19-78`；`codex-rs/AGENTS.md:91-100`）。据此可以把 Codex projection 归入模型请求层编译；Codex 内部 native project-doc discovery 走它自己的加载路径，与 OpenClaw 的权威文件加载分开记录。

Codex 的 context-engine projection 还有独立生命周期：如果 assemble 返回 `thread_bootstrap` 和稳定 epoch，OpenClaw 只在 epoch 改变时重新投影；否则按 turn 投影。projection decision、assembled message 数、prompt chars 和 developer addition chars 会写入运行日志，但这仍是投影诊断，不是 raw provider request dump（`src/context-engine/types.ts`；`extensions/codex/src/app-server/run-attempt-prompt.ts`）。

## 4. 消息生命周期变换与交接

规则编译结果对权威 transcript 的影响分为三类。第一类是 prompt-only：skills catalog、memory recall prepend、provider prompt contribution、hook context 和多数 system prompt additions 只改变本次或下一次模型输入，不写回 bare user transcript。第二类是 runtime carrier：inbound metadata、heartbeat outcome、inter-session provenance 和下一轮上下文可作为 hidden custom message 临时进入模型，再在提交/清理时从可见 transcript 过滤。第三类是 durable lifecycle：用户原文、assistant response、compaction summary、skill snapshot、bootstrap completion marker 和 memory flush 写入各自的 session/state/workspace owner。

prompt 提交时，运行器先用 onFinalPromptText 记录 transcript prompt，再由 Agent Core 产生 assistant 与 tool 消息；message_end 事件进入 session manager。成功 turn 结束后，context engine 收到的是剥离了 runtime carrier 的 conversation snapshot，运行器优先调用 afterTurn，没有该钩子时按批量或逐条 ingest，随后执行 maintain。失败、abort、yield 和 prompt error 不会推进成功 turn 的 context-engine 持久状态（`src/agents/embedded-agent-runner/run/attempt-prompt-submit.ts`；`src/agents/harness/context-engine-lifecycle.ts`；`src/agents/embedded-agent-runner/run/attempt-finalize.ts`）。

compaction 是输入历史的明确重写边界。内置路径先读取并验证 transcript、限制历史、运行 before-compaction hooks，然后让 server endpoint 或 embedded compaction model 生成 summary；成功后 `SessionManager.appendCompaction` 写入摘要并把 active agent messages 替换为 compaction 后的 replay-safe context。原始完整历史仍保留在 SQLite transcript，后续模型看到的是 summary 加近期 tail（`src/agents/embedded-agent-runner/compaction-session-execution.ts`；`src/agents/sessions/agent-session-compaction.ts`）。

context engine 的选择决定了 compaction 由谁执行。ownsCompaction 为 true 时，engine 自己负责 /compact、overflow recovery 和主动压缩；非 owning engine 仍要实现 compact()，运行时不会回落到 legacy compaction。engine 的成功与失败进入 registry 的 quarantine 和 fallback 逻辑：当前 turn 的 assemble 失败时保留原 pipeline messages，compact 与 subagent preparation 这类需要强失败语义的操作不会被静默替换（`docs/concepts/context-engine.md`；`src/context-engine/registry.ts`）。

compaction 前的 memory flush 是另一条交接链：只有非 heartbeat、非 CLI、workspace 可写且 memory flush plan 命中阈值时运行一个 silent maintenance turn；该 turn 使用专门的 prompt、system prompt、model、daily memory write path 和独立 run authority。它把未写入的持久事实追加到当天 `memory/*.md`，然后主会话才进行 compaction；flush 失败达到上限时会记录 degraded outcome，必要时轮换 bloated session，但主用户回复仍有明确的继续或错误结果（`src/auto-reply/reply/agent-runner-memory.ts`；`src/auto-reply/reply/agent-runner-execute.ts`）。

## 5. 显示层投影与消息渲染器交接

本次检查没有把 prompt report、trajectory、`/context` 输出或 Codex developer-instruction snapshot 当作模型权威消息。`systemPromptReport` 只保存 system prompt 的字符数/hash、Project Context 计数、bootstrap raw/injected/truncated 统计、skill block 统计和 tool schema 统计，不保存原始 prompt 正文；run report 写回 session entry，该命令优先读取它，没有 run report 时才生成 estimate（`src/agents/system-prompt-report.ts`；`src/config/sessions/session-system-prompt-report.ts`；`src/auto-reply/reply/commands-context-report.ts`）。

`/context list|detail|json` 展示文件、skills、tools、prompt size、token estimate 和 compactable transcript 数；`/context map` 只有在存在实际 run report 时才生成 treemap。map 会额外统计 runtime context 和 model-only prompt，因为它们进入模型却不在 transcript；它仍是按字符和估算 token 组织的诊断图片，不是完整网络 payload 或 hook trace（`src/auto-reply/reply/commands-context-report.ts`）。

显示与权威消息的分界由数据结构表达：runtime context custom message 使用 `role:"custom"`、`display:false` 和 `runtimeContextCarrier:true` 三个标记，模型转换前会被重定位或过滤；hook 收到的历史是 cloned snapshot；trajectory 记录 `context.compiled`，但不反向修改 session。模型-only 的 memory/hook context 与用户可见 Markdown 分属两条去向，`/context` 和 UI 状态承载诊断投影，权威 transcript 由 session 层维护：

- 标记定义与剥离路径：`src/agents/embedded-agent-runner/run/runtime-context-prompt.ts`
- prompt 支撑：`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts`
- session 准备：`src/agents/embedded-agent-runner/run/attempt-session-prepare.ts`

对普通 SDK/CLI session，prompt template 展开和 extension command 处理也发生在输入处理层而非消息渲染器。extension command 找到后可以直接执行并不发送 LLM prompt；模板或 skill command 展开后才创建 user message。流式期间的新输入被分类为 steer/follow-up，展开后的内容进入队列并在后续 loop checkpoint 交接（`src/agents/sessions/agent-session-prompting.ts`；`packages/agent-core/src/agent.ts`）。

## 6. 调试、预览与可解释性

OpenClaw 有多层可解释表面，但覆盖范围不同：

- systemPromptReport 是每次 embedded 或 CLI 运行的结构化摘要，可用来核对 prompt hash、字符预算、注入的文件、skills block 和 tool schema。摘要保存统计值，没有 prompt 原文，也不逐条记录 hook 命中差异。
- `/context` 的 list、detail、json 和 map 四种视图从 run report 或估算值构造操作者可读的上下文账本，其中 map 只在存在真实 run report 时才画 treemap。
- cache trace 的 prompt:before、prompt:images 与 trajectory 的 context.compiled、prompt.submitted 记录模型边界附近的消息、system prompt、工具、图片数和 transport，属于运行观测；Provider 的原始 HTTP body 需另行抓取。
- llm_input hook 在提交前异步收到 system prompt、LLM 边界 prompt、克隆的历史和工具列表；回调失败只写 warning，已准备的 prompt 保持不变。该 hook 用于观察，改写 prompt 由前面的构建阶段完成（`src/agents/embedded-agent-runner/run/attempt-prompt-support.ts`）。
- Codex harness 的测试 API 可以构造 thread、resume 和 turn 三个层级的 prompt snapshot；Codex app-server 的 context report 记录 developer instructions 的 hash 与动态 tool schema。native Codex 自己加载的 project docs 可能超出 OpenClaw 的 per-file report 范围（`extensions/codex/test-api.ts`；`extensions/codex/src/app-server/attempt-context.ts`）。

可编辑规则本身没有一个统一的“命中规则列表”或“编译前后 diff”界面。skills 有 `openclaw skills check`、来源/冲突/扫描诊断和 snapshot metadata；Skill Workshop 有 proposal list/inspect/evaluate/apply、SQLite 状态和事件；memory/active-memory 有 status、debug 与 recall outcome；这些表面分别属于资源、治理和检索 owner，不能合并成一个通用 prompt debugger。此次未找到一个能同时展示 skill、template、bootstrap、memory、hook、context-engine 命中顺序和最终 Provider payload 的统一预览器。

## 7. 失败、更新与已确认边界

### 失败收口

- 运行器读取工作区 bootstrap 文件时按边界安全方式打开，先校验 realpath 与来源身份，单文件上限 2 MiB，遇到临时 I/O 错误会重试。读取失败的文件以 `[UNREADABLE: ...]` 内容或 missing 状态交给后续预算与 prompt 构建，不会静默当作读取成功（`src/agents/workspace.ts`；`src/agents/workspace-bootstrap-read.ts`）。
- bootstrap 上下文超出预算时保留截断标记；总预算耗尽后停止继续注入文件，warning 写入 system prompt 并进入报告。`USER.md`、`AGENTS.md` 与普通文件的截断策略各不相同，构建过程不做 Markdown 语义解析，也没有循环 include 展开（`src/agents/embedded-agent-helpers/bootstrap.ts`）。
- skill 的 frontmatter 解析异常、依赖 gate 无效、路径越界、技能文件缺失或 snapshot 不可信，只会让该 skill 被跳过、过滤或从当前 catalog 重建。snapshot 的 prompt 结构异常时，加载器跳过不安全的 XML 局部过滤（`src/skills/loading/workspace-skill-loader.ts`；`src/skills/loading/workspace-skill-prompt.ts`）。
- prompt 模板读取失败、模板名未知或 slash command 未匹配时，输入保持原样或只留下资源诊断；占位符没有递归展开，也就没有由模板自身引起的循环替换路径。extension command handler 抛错时经 extension error surface 上报，该命令仍视为已处理（`src/agents/sessions/prompt-templates.ts`；`src/agents/sessions/agent-session-prompting.ts`）。
- prompt hook、memory recall 与异步 memory preparation 各有独立的错误和超时边界。普通 prompt hook 失败只返回空 contribution；active-memory 超时或 tool authority 关闭时跳过 recall；memory prompt preparation 在 context engine assemble 之前失败，交给外层 context-engine 与 runner 的 fallback 规则（`src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts`；`extensions/active-memory/index.ts`；`src/plugins/memory-state.ts`）。
- context engine assemble 返回无效结果时被 shape validator 拒绝，消息回到 pipeline messages；运行时异常会记录 engine quarantine，后续多数受保护的调用改走 fallback engine。宿主机 capability 不满足时在 run 之前 fail closed，继续执行可能破坏 engine 对 transcript 的语义假设（`src/agents/harness/context-engine-lifecycle.ts`；`docs/concepts/context-engine.md`）。

### 更新与缓存

工作区 bootstrap 文件以文件 identity/content cache 复用读取结果，但有 session cache 的 per-turn refresh，因此长会话可看到文件编辑；skills 以 watcher 250ms debounce bump snapshot version，新的 snapshot 通常在下一 agent turn 采用；配置/agent filter/remote node eligibility 变化也会触发 snapshot rebuild。Prompt-state mutation 默认不在当前已构建 run 中同步重编译，后续 turn 或新 session 才消费新的资源（`src/agents/bootstrap-cache.ts`；`src/skills/runtime/refresh.ts`；`src/skills/runtime/refresh-state.ts`）。

系统提示词稳定部分使用有上限的 process-local cache，key 包含 workspace、prompt mode、tool lines、provider contribution、skills prompt、memory section 和 stable context files；动态时间、渠道、身份、runtime、watched sessions 和 dynamic project context 位于 cache boundary 后。provider prompt contribution 也显式区分 stable prefix 与 dynamic suffix，避免每轮动态信息破坏可复用前缀（`src/agents/system-prompt.ts`；`src/agents/system-prompt-contribution.ts:12-34`）。

### 本次检查范围内未找到的能力

本次检查范围内未找到一个通用的、可编辑规则对象系统，能够像某些 preset/lorebook/宏引擎一样以统一 schema 保存任意规则、按关键词/概率/深度/冷却命中，再以统一编译顺序生成消息数组。OpenClaw 的独立能力是“多种文件与插件贡献者的上下文编译”，其中 skills、prompt templates、prompt hooks、memory 和 context engine 各自拥有 owner、schema、作用域和错误边界；它们不是一个共享的规则 AST。

依据有三处。系统提示词 renderer 只接收上层准备好的 contextFiles、skillsPrompt、extraSystemPrompt 和 provider contribution，自身不加载规则源；embedded resource loader 关闭 ambient skills、prompt templates、themes 和 context-file discovery，要求上层提供已准备好的资源；普通 SDK session 的模板加载器与 embedded runner 的 skill、bootstrap 加载器分别实现，资源路径互不共享（`src/agents/system-prompt.ts`；`src/agents/sessions/resource-loader.ts`；`src/agents/embedded-agent-runner/run/attempt.ts`）。按“独立规则编译器”理解为统一规则 schema 与命中器时，本次标为**归并到相邻类目**：相关能力分别归入 skills、对话请求与上下文、记忆、context engine 和会话管理，统一的 preset/macro/lorebook 层在本次检查范围内未找到。

## 8. 未验证事项

- 未运行真实 Provider、CLI 进程或 Codex app-server，没有取得具体渠道和模型下的最终网络 payload。请求层结论的依据是紧邻 streamFn、CLI argv/stdin 以及 Codex thread 与 turn 请求构造器的代码。
- 未运行多根目录下 skill 同名冲突、agent allowlist、session override、remote node、sandbox remap 与 disable-model-invocation 的组合场景；静态排序、过滤和 snapshot 失效已由代码确认。
- 未运行 `$skill` 引用、slash skill command、command-dispatch 到工具的命令、模板参数切片、参数内含占位符与未知命令的全部组合；模板替换只做一轮以及相关上限由代码确认。
- 未核对每个内置 memory 插件在实际组合下的 prompt supplement、异步 preparation、auto-recall 与 context engine 结果；memory-core、active-memory 和 memory-lancedb 的入口与分流已定位。
- 未运行 active-memory lane 1/lane 2、private transcript recall、project-scoped memory、provenance 不 eligible、cooldown、timeout、compaction 前 flush 的实际命中和可见输出。
- 未运行 context engine 插件的组合行为，包括 assemble 重排历史、追加 systemPromptAddition、ownsCompaction 生效后的压缩交接、promptAuthority 变化、quarantine 与 fallback 切换、thread bootstrap 投影以及 subagent spawn 交互。
- 未确认所有渠道上 `/context` 的显示投影、trajectory 保存策略、日志保留/脱敏策略以及 `llm_input` 异步观测与实际 Provider 请求的时序一致性。
- `IDENTITY.md` 的文件解析和 agent identity 配置同步已静态确认，但它在每一种 harness 的提示词文本、渠道显示和 native Codex collaboration instruction 中的最终字节布局未运行核对。

## 9. 关键源码索引

- `src/agents/embedded-agent-runner/run/attempt.ts`：embedded attempt 的 skills、bootstrap、工具、system prompt 和 session runtime 准备顺序。
- `src/agents/system-prompt.ts`：OpenClaw 系统提示词 renderer、section 顺序、stable/dynamic cache boundary 和 prompt mode。
- `src/agents/workspace.ts`：工作区模板创建、bootstrap 完成状态、固定文件读取和 session/privacy 过滤。
- `src/agents/bootstrap-files.ts` 与 `src/agents/embedded-agent-helpers/bootstrap.ts`：memory provenance、bootstrap hooks、文件预算、截断和 context file 构建。
- `src/skills/loading/workspace-skill-loader.ts`、`src/skills/loading/workspace-skill-prompt.ts`：skill 根目录优先级、过滤、snapshot 和 `<available_skills>` 编译。
- `src/skills/discovery/chat-command-invocation.ts`、`src/agents/sessions/prompt-templates.ts`：显式 skill 引用、命令模板和参数占位符展开。
- `src/agents/embedded-agent-runner/run/attempt-prompt-helpers.ts`、`src/agents/embedded-agent-runner/run/attempt-prompt-build.ts`：prompt hook 顺序、system/prompt prepend/append、运行时上下文分流。
- `src/agents/embedded-agent-runner/run/attempt-history.ts`、`src/agents/harness/context-engine-lifecycle.ts`：历史准备、context engine assemble、afterTurn/ingest/maintain 交接。
- `packages/agent-core/src/agent-loop.ts`、`src/agents/embedded-agent-runner/run/attempt-llm-boundary.ts`：`transformContext`、`convertToLlm` 到 Provider `streamFn` 的最终请求边界。
- `extensions/memory-core/index.ts`、`extensions/active-memory/index.ts`、`extensions/memory-lancedb/auto-recall.ts`：memory prompt guidance、主动 recall 和模型上下文 prepend。
- `src/auto-reply/reply/agent-runner-memory.ts`、`src/agents/embedded-agent-runner/compaction-session-execution.ts`：compaction 前 memory flush 与 compaction summary/transcript 交接。
- `src/agents/system-prompt-report.ts`、`src/auto-reply/reply/commands-context-report.ts`：prompt report、`/context` 诊断和显示投影边界。
- `extensions/codex/src/app-server/attempt-context.ts`、`extensions/codex/src/app-server/run-attempt-prompt.ts`：native Codex workspace/context-engine projection。
- 兄弟 Codex 直接核对：`codex-rs/AGENTS.md:91-100`、`codex-rs/core/tests/suite/prompt_debug_tests.rs:19-78`：Codex 增量上下文硬约束和 workspace prompt input 测试。
