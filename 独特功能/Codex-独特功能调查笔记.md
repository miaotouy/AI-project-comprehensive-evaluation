# Codex 独特功能调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：只读通读根 README、`codex-rs` 约 166 个成员 crate 的目录与关键模块；对沙箱与审批、补丁编辑、指令加载、app-server、`codex exec`、代码模式、云端任务逐条核对入口、状态、执行与结果；抽查对应测试；未构建或运行，未修改仓库
>
> 调查范围：去除普通聊天与通用 Agent 底座后仍形成完整工作流的候选；覆盖沙箱执行与审批、`apply_patch`、`AGENTS.md` 层级指令、app-server 集成面、`codex exec` 自动化、代码模式、云端任务；MCP 客户端、Skills/Plugins/Hooks、线程谱系、多智能体只做盘点，不单独设卡
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 的产品辨识度不在“会聊天的编码模型”，而在把模型输出约束进一个可审批、可回放、可被外部进程驱动的本地执行环境。本次确认七项达到 `主链确认`（静态证据）的能力：

1. **平台沙箱 + 分层审批 + Starlark 策略**：模型发起的命令先经策略与审批，再被 Seatbelt / Landlock+seccomp / Windows 受限令牌等原生机制约束；需要提权时由用户批准后重新执行，若策略含拒绝读规则则提权仍保留沙箱。
2. **`apply_patch` 专用补丁语言**：补丁采用 `*** Begin Patch` 专用语法，而非通用 unified diff；解析、校验、按上下文定位、整批提交与失败增量回报都在进程内完成，并受同一套沙箱与审批约束。
3. **`AGENTS.md` 层级指令合成**：从项目根到 cwd 逐目录收集，override 文件优先，按字节预算截断，与账号级/线程级指令合并后进入模型输入。
4. **app-server 作为 IDE 集成面**：JSON-RPC 线程生命周期、分页历史、审批回调、动态工具、daemon 与远程控制，外加 TypeScript/Python SDK，构成“Codex 作为服务”的完整面。
5. **`codex exec` 非交互自动化**：JSONL 事件、结构化最终答复、最后消息文件、恢复与分叉，全部复用 app-server 内核，适合 CI 与脚本。
6. **代码模式 `exec`/`wait`**：模型写一段 JavaScript，在 V8 宿主里通过全局 `tools` 对象编排多个工具，支持 yield 与续等；目前是实验特性、默认关闭。
7. **云端任务交接**：`codex cloud exec` 提交任务到服务端环境，`status/list/diff/apply` 把 best-of-N 结果取回并应用到本地工作树。

其中前五项为稳定的日常产品面，代码模式与云端任务是边界明确的辅助贡献。MCP、Skills/Plugins/Hooks、线程谱系与多智能体归并到已有类目，不重复计数。

## 介绍声明与候选盘点

根 README 把 Codex 定位为“在终端运行的编码 Agent”，并链接 CLI、IDE、云端等产品文档；仓库内 `docs/` 多数是外链占位（如 `docs/agents_md.md`、`docs/sandbox.md` 只有一句“见官网”），因此候选主要从 crate 结构、命令入口与可执行路径确认，而不是文档声明。

| 候选 | 证据状态 | 结论 |
|---|---|---|
| 平台沙箱 + 分层审批 + execpolicy | `主链确认` | 见能力一 |
| `apply_patch` 补丁式编辑 | `主链确认` | 见能力二 |
| `AGENTS.md` 层级指令 | `主链确认` | 见能力三 |
| app-server + SDK 集成面 | `主链确认` | 见能力四 |
| `codex exec` 自动化 | `主链确认` | 见能力五 |
| 代码模式 `exec`/`wait` | `主链确认`（实验、默认关闭） | 见能力六 |
| 云端任务提交与本地应用 | `主链确认`（静态；外部服务未验证） | 见能力七 |
| MCP 客户端（工具、资源、OAuth、elicitation） | `归并已有类目` | Agent 工具/扩展生态；仓库含一个面向内部留言板的 MCP 服务端实现（`message-board-mcp`），但本次未找到把 Codex 自身暴露成 MCP 服务端的命令 |
| Skills、Plugins、Hooks、Memories | `归并已有类目` | Agent 工具、Agent 角色、上下文类目 |
| 线程 rollout、resume/fork/revert、归档 | `归并已有类目` | 会话与消息管理、对话导出与分享 |
| 子智能体与协作工具（collab、agent roles、message board） | `入口确认` | 工具、协议条目与留言板服务端都在，agent 间投递还接入了 turn 输入通道；本次未走通“创建→协作→回收”全链，不单独设卡 |
| 远程执行服务（`exec-server` 与协议 crate） | `归并已有类目` | 外部执行体与应用协作：供客户端在远端环境执行命令与文件操作的服务面 |
| 实时语音会话 | `归并已有类目` | 语音交互面，不是媒体创作；见媒体创作笔记边界 |

## 已确认的独特能力

### 能力一：平台沙箱 + 分层审批 + Starlark 策略 — `主链确认`

**用户目标。** 让模型能执行真实命令、读写工作区，同时把“能做什么”限制在操作系统级沙箱和可审计的策略里，而不是只靠提示词约束。

**入口与触发者。** 模型通过命令执行工具发起请求；用户通过配置、`/permissions`、审批弹窗和 `codex sandbox` 子命令参与。审批模式定义在 `codex-rs/protocol/src/protocol.rs:1163-1186`（untrusted、on-request、granular、never），沙箱策略定义在同文件 `:1250-1299`（read-only、workspace-write、danger-full-access、external-sandbox）。`codex sandbox` 用于在宿主沙箱内直接跑命令（`codex-rs/cli/src/main.rs:190-191`）。

**完整主链。** 命令进入执行层后先选沙箱类型：按平台返回 Seatbelt、Linux Landlock+seccomp 或 Windows 受限令牌（`codex-rs/sandboxing/src/manager.rs:48-62`），再判断本次请求是否真的需要沙箱（`:311-351`）。需要时把原始 argv 包装成沙箱启动命令，注入文件系统与网络权限、环境变量和代理设置（`:353` 起的 `transform`）。执行入口在 `codex-rs/core/src/exec.rs:132` 选型、`:393-430` 变换并启动。平台后端分别为 Seatbelt 策略生成（`sandboxing/src/seatbelt.rs:844`）、Landlock 规则（`sandboxing/src/landlock.rs:26`）与 Windows 受限令牌/MXC（`sandboxing/src/windows.rs:38-100`）。

**策略层。** execpolicy 用 Starlark DSL 写规则，支持命令前缀规则与网络规则。命令规则解析接受 allow、prompt、forbidden，网络规则额外接受 deny；另有 `PromptUser` 内部变体表示必须由人重新确认（`codex-rs/execpolicy/src/decision.rs:9-19`；命令规则解析 `src/parser.rs:357-360`，网络规则 `:253-257`）。规则文件是配置层目录下的 `rules/*.rules`，含默认 `default.rules`，按配置层优先级叠加（`codex-rs/core/src/exec_policy.rs:56-58,669-702`）。`codex execpolicy check` 可离线检查某条命令会命中什么决策（`cli/src/main.rs:196-198`）。

**提权与失败。** 模型可以请求“带额外权限执行”，用户批准后才放宽；但若当前策略含拒绝读规则，提权仍保留沙箱，避免用一次批准抹掉拒绝读（`codex-rs/core/src/tools/sandboxing.rs:242-310`）。反过来，execpolicy 的 allow 规则可以表达“完全信任、跳过沙箱”，这是策略层而非模型层能决定的边界（同文件 `:269-285`）。沙箱拒绝会被识别并转成结构化错误，供上层决定重试或上报（`core/src/tools/runtimes/apply_patch.rs:241-257`）。

**持续性与边界。** 审批缓存按工具与路径/命令归类，避免同一命令反复询问（`core/src/tools/approvals.rs:109-179,302-310`）。审批请求本身属于瞬态事件，不写入 rollout（`rollout/src/policy.rs:197-198`），因此“谁批准过什么”不构成持久审计记录。整个能力只作用于本机进程与文件系统，不涉及远端执行。

**独特性判断。** “Agent 工具”只能描述工具注册与参数；“权限系统”通常只到应用层开关。Codex 把 OS 沙箱、分层配置、Starlark 策略、审批缓存和提权语义串成一条可执行链，并让同一条链同时约束命令与补丁，这是普通聊天客户端不具备的。

**证据强度。** 入口、平台后端、策略解析、提权分支与拒绝处理均为静态事实；真实平台上的沙箱强度、网络代理行为未运行验证。

### 能力二：`apply_patch` 补丁式编辑 — `主链确认`

**用户目标。** 让模型用接近人类 patch 的文本表达多文件修改，由宿主完成定位、校验与提交，避免模型直接覆盖整文件或依赖外部 `git apply`。

**入口与事实对象。** 工具名 `apply_patch`，输入是一段以 `*** Begin Patch` 开头、`*** End Patch` 结尾的文本，内部用 `*** Add File:`、`*** Delete File:`、`*** Update File:`、`*** Move to:` 和 `@@` 上下文分段表达变更（`codex-rs/apply-patch/src/parser.rs:7-45`）。解析结果是一个带文件变更列表的动作对象，由运行时执行（`core/src/tools/runtimes/apply_patch.rs:47-58`）。

**完整主链。** 模型产出补丁 → 解析器按严格模式校验标记与分段 → 安全评估与审批（补丁审批在上游完成，运行时只负责执行，见 `runtimes/apply_patch.rs:1-8,147`）→ 按上下文定位并在内存中计算替换 → 写入文件 → 返回逐文件 diff、成功/失败状态与实际已提交的变更集合（`apply-patch/src/lib.rs:307-330`；`file_update.rs:57-60` 计算替换）。

**结果与失败语义。** 补丁可能“部分提交后失败”：运行时保留已提交的增量（`AppliedPatchDelta`），把失败与已落盘内容一起回报，而不是假装原子回滚（`apply-patch/src/lib.rs:213-279`；`runtimes/apply_patch.rs:206-232`）。移动文件会同时记录源与目标路径。修改 `AGENTS.md` / `AGENTS.override.md` 时会额外打点（`runtimes/apply_patch.rs:219-230`），说明指令文件被视为特殊对象。

**审批与沙箱。** 补丁走与命令相同的权限模型：审批动作类型为 `ApplyPatch`，携带环境、cwd、文件列表、原始补丁与 diff（`core/src/tools/approvals.rs:109-179`）；执行时使用 turn 环境的文件系统与沙箱上下文（`runtimes/apply_patch.rs:1-8`）。用户拒绝时返回“patch rejected by user”，已提交的变更仍有单独的增量记录（`core/src/tools/events.rs:424-457`）。

**独特性判断。** 通用“文件编辑工具”通常是整文件写入或正则替换；Codex 自建了一套补丁语法、解析器、上下文定位和增量回报，并与审批、沙箱、diff 展示共用一套事件模型。它与 `codex apply` 不同：后者是把云端任务的 diff 交给 `git apply`（`codex-rs/chatgpt/src/apply_command.rs:14-76`）。

**证据强度。** 语法、解析、执行、审批与增量回报均为静态事实；复杂补丁的定位成功率、超大文件性能未运行验证。

### 能力三：`AGENTS.md` 层级指令 — `主链确认`

**用户目标。** 让仓库自己携带长期有效的工程约定，模型在任意子目录工作时都能拿到“从根到当前目录”的完整指令，而不是只读一个固定文件。

**入口与事实对象。** 文件名默认为 `AGENTS.md`，同目录的 `AGENTS.override.md` 优先（`codex-rs/core/src/agents_md.rs:43-45,272-296`）。账号级指令放在 codex home 的同名文件（`codex-rs/codex-home/src/instructions/mod.rs:41-62`）。`/init` 可生成初始文件（`tui/src/slash_command.rs:98`）。

**完整主链。** 会话启动时 `load_project_instructions` 先放入账号级与线程级指令，再按 turn 环境逐个收集项目文档（`core/src/agents_md.rs:58-116`）。项目根由 `.git` 等标记向上查找；找到根后，把“根 → cwd”的目录序列反转成正序，逐目录探测候选文件（`:192-269`）。读取时共享一个字节预算，默认 32 KiB（`config/src/config_toml.rs:77,337-342`），每个文件只取剩余额度，超长截断并告警（`agents_md.rs:150-180`）。最终把来源路径、环境与 cwd 作为 provenance 一并保留（`:170-177`），再合成模型可见文本（`:378-473`）。

**边界与条件。** 项目被标记为 untrusted 时，只保留账号/线程指令，不读项目文件（`agents_md.rs:64-66`）。文件系统访问走 turn 环境的执行器与沙箱上下文；沙箱下的读取失败会作为错误上报，而不是静默忽略（`:74-111`）。支持自定义候选文件名，但会拒绝路径分隔符、`.`、`..` 等可能越界的值（`:272-296`）。

**独特性判断。** 通用“系统提示/自定义指令”通常只有全局一层。Codex 把目录层级、override、预算、来源标注、沙箱读取和 untrusted 策略组合成一条确定的合成链，属于编码 Agent 的工作区约定机制，不是普通提示词模板。

**证据强度。** 发现顺序、预算、override 与 untrusted 分支均为静态事实；真实多环境（本地 + 远端执行器）合并效果未运行验证。

### 能力四：app-server 作为 IDE 集成面 — `主链确认`

**用户目标。** 让编辑器、桌面端、脚本和第三方客户端把 Codex 当作长期运行的 Agent 服务：创建/恢复/分叉线程、流式接收事件、处理审批、注入动态工具。

**入口与触发者。** `codex app-server` 启动服务，传输支持 stdio、Unix socket 与 WebSocket（`codex-rs/cli/src/main.rs:571-597`）；`codex app-server daemon` 管理本地常驻进程（`:633-638`），另有隐藏的 `--remote-control`。官方 SDK 位于 `sdk/typescript` 与 `sdk/python`，都是该协议客户端。

**事实对象与状态。** 协议按 v1/v2 分层，v2 的线程方法覆盖 start、resume、fork、revert、archive、delete、name、metadata、settings、queue、attachment、compact、search 等（`codex-rs/app-server-protocol/src/protocol/common.rs:555-901`）。线程状态由 `ThreadStatus` 表达，包含未加载、空闲、系统错误与“等待审批/等待用户输入”的活动标记（`protocol/v2/thread.rs:1720-1738`）。

**完整主链。** 客户端握手 → `thread/start` 或 `thread/resume`（可只带元数据，再用分页补齐历史）→ 发送 turn → 服务端把工具调用、审批请求、流式增量作为通知/服务端请求推给客户端 → 客户端回传审批决定或动态工具结果 → turn 结束后线程状态回到 idle。历史读取拆成 `thread/turns/list` 与 `thread/items/list`，都用不透明游标分页（`thread.rs:1789-1898`）；`thread/read` 的 `include_turns` 对分页线程已弃用（`:1723-1731`）。

**持续性与恢复。** 线程正文仍在 rollout，app-server 只是读写与投影层；`thread/resume` 可只加载元数据，历史按需分页（`thread.rs:421-481`）。分叉可在指定 turn 截断（`:544-573`），回退保留线程 ID、切换 rollout 文件（`:1314-1318`）。daemon 与远程控制使同一批线程可被多个客户端共享。

**人机关系。** 审批不是本地弹窗专用：协议把审批表达为服务端请求，客户端可显示、接受、拒绝或按 granular 配置自动处理（`protocol/common.rs` 的 server request 联合；`core/src/tools/approvals.rs:109-179`）。动态工具允许客户端把自己的工具注入某个线程（`thread.rs:151` 的 `dynamic_tools`，以及 `thread/inject_items`），使 IDE 能力与内置工具在同一循环里执行。

**独特性判断。** 普通聊天客户端只有 HTTP/SSE 接口；Codex 的 app-server 覆盖线程生命周期、分页历史、审批回调、动态工具、daemon 与两种语言 SDK，且 CLI 自身也复用这套内核（`exec/src/lib.rs:1039` 启动进程内 app-server 客户端）。它已超出“Agent 工具”或“LLM 渠道”，是产品级集成面。

**证据强度。** 方法表、传输、分页参数与 CLI 复用为静态事实；与真实 IDE 扩展、daemon 跨进程恢复未运行验证。

### 能力五：`codex exec` 非交互自动化 — `主链确认`

**用户目标。** 在 CI、脚本或其他程序里调用 Codex，拿到可机器解析的事件流与结构化最终结果，并能继续已有会话。

**入口与触发者。** `codex exec`（别名 `e`）由脚本或人工在终端触发（`cli/src/main.rs:152-154`）。核心参数为 `--json`、`--output-last-message/-o`、`--output-schema`、`--ephemeral`、`--skip-git-repo-check`（`exec/src/cli.rs:36-85`）；子命令支持 `resume` 与 `fork`（`:172-182`）。

**完整主链。** 参数解析后加载配置与输出 schema，启动进程内 app-server 客户端，再按新会话、恢复或分叉走对应线程生命周期（`exec/src/lib.rs:1039-1059`）。运行期间事件处理器把内部事件映射为 `ThreadEvent`，逐行写 stdout（`event_processor_with_jsonl_output.rs:89-105`）。事件类型固定为 thread/turn/item 的生命周期与错误（`exec_events.rs:11-37`），item 覆盖命令执行、文件变更、MCP、网页搜索、待办、协作工具等（`:107-133`）。

**结果形态。** `--json` 保证 stdout 每行一个合法 JSON（`exec/src/lib.rs:3`）；`-o` 只在成功 turn 后写入最后一条 Agent 消息，失败不覆盖旧文件（测试 `event_processor_with_jsonl_output_tests.rs:7`）；`--output-schema` 让最终消息成为符合给定 schema 的 JSON 文本（`exec_events.rs:108-110,135-140`）。`--ephemeral` 明确表示不落会话文件（`exec/src/cli.rs:40-42`）。

**边界。** 事件流没有“用户消息”item，不能当作完整会话档案；线程 ID 可用于后续 resume（`exec_events.rs:39-43`）。它也不提供并发队列或多任务编排，调度由外部脚本负责。

**独特性判断。** 通用“API 调用”只有请求/响应；这里把 Agent 回合拆成稳定的事件契约，并与恢复、分叉、结构化输出组合，形成可直接嵌入 CI 的自动化面。它与“Agent 工具”不同：触发者是外部进程，不是模型。

**证据强度。** 参数、事件枚举、写入时机与失败语义为静态事实；真实 CI 集成与长任务行为未运行验证。

### 能力六：代码模式 `exec`/`wait` — `主链确认`（实验、默认关闭）

**用户目标。** 让模型用一小段 JavaScript 编排多个工具调用（循环、分支、并发、结果变换），而不是逐条发起工具调用。

**入口与触发者。** 模型调用名为 `exec` 的自由格式工具，必要时用 `wait` 续等未完成的 cell（`codex-rs/code-mode-protocol/src/lib.rs:60-61`）。工具只在代码模式开启时装配（`core/src/tools/mod.rs:68-80`）；`code_mode` 特性处于开发阶段且默认关闭（`features/src/lib.rs:1303-1307`），代码模式宿主本身是稳定默认开启（`:1321-1325`）。

**完整主链。** 工具输入是原始 JavaScript，可带一行 `// @exec:` pragma 指定初始产出时间（`core/src/tools/code_mode/execute_spec.rs:5-20` 的 Lark 语法）。脚本在 V8 运行时执行，所有嵌套工具挂在全局 `tools` 对象上（如 `await tools.exec_command(...)`），另有 `text()`、`notify()`、`tool_search()` 等辅助；工具名规范化为 JS 标识符（`code-mode-protocol/src/description.rs:20-43`）。运行到 yield 时限就返回中间结果，模型用 `wait` 继续；cell 有堆、输出与 yield 上限（`code-mode-runtime/src/service.rs:34-35,44-67,257-269`）。

**隔离与并发。** 宿主可作为独立进程运行，通过 stdio/gRPC 与主进程通信（`code-mode-host/src/main.rs`；`code-mode-host/src/grpc_transport.rs`）。嵌套工具调用仍回到主进程的工具路由器，因此审批、沙箱与遥测对每一次子调用生效；代码模式工具不能调用自身（`core/src/tools/code_mode/mod.rs:376`）。

**独特性判断。** “Agent 工具”只解释单个工具的注册与执行；代码模式引入了独立的受限脚本运行时、yield/续等协议和嵌套工具目录，是第三种执行范式（直接调用、子智能体分派之外的“可编程编排”）。它与 OpenCode 的 CodeMode 目标相近，但实现栈（V8、独立宿主进程、`exec`/`wait` 两段式）不同。

**证据强度。** 工具语法、宿主、限额与装配条件为静态事实；真实模型生成脚本的正确性、超时与中断行为未运行验证。

### 能力七：云端任务提交与本地应用 — `主链确认`（静态；外部服务未验证）

**用户目标。** 把任务放到云端环境并行跑多个尝试，再把其中一个 diff 取回本地工作树。

**入口与触发者。** `codex cloud`（别名 `cloud-tasks`）在无子命令时打开任务浏览界面；子命令为 `exec`、`status`、`list`、`apply`、`diff`（`cli/src/main.rs:228-230`；`cloud-tasks/src/cli.rs:15-27`）。用户必须提供环境 ID，可选分支与 1–4 次尝试（`cli.rs:29-50`）。

**完整主链。** `exec` 把提示词、环境 ID、分支与 best-of-N 提交到云端，返回任务 ID（`cloud-tasks-client/src/http.rs:336-385`）；`status/list` 读取任务与尝试；`diff` 取统一 diff；`apply` 把指定尝试的 diff 交给 `git apply` 写入本地（`chatgpt/src/apply_command.rs:56-76`）。任务在云端执行，本仓库只承担提交、轮询、展示与应用。

**持续性与边界。** 任务状态与环境定义保存在服务端，仓库内只有环境 ID 参数与 HTTP 客户端；没有本地任务库、环境镜像定义或离线执行路径。`codex apply` 与 `apply_patch` 是两条不同的补丁路径：前者应用云端结果，后者是模型编辑工具。

**独特性判断。** 它把本地 Agent 与远端并行执行连成“提交—挑选—落地”的闭环，超出普通“模型 API”范围；但核心执行在仓库外，因此只计辅助贡献。

**证据强度。** CLI、客户端请求与应用路径为静态事实；真实云端服务、认证、环境解析与 best-of-N 结果质量未验证。

## 已归并到现有类目的能力

| 能力 | 归并去向 | 说明 |
|---|---|---|
| MCP 客户端（stdio/HTTP、OAuth、工具/资源、elicitation、审批） | Agent 工具 / 扩展生态 | `codex mcp list/get/add/remove/login/logout`；本次未找到 Codex 作为 MCP 服务端的命令，故不写“双向接入” |
| Skills、Plugins、Hooks、Memories | Agent 工具 / Agent 角色 / 上下文 | 有独立 crate 与配置面，但不改变“模型+工具”的基本关系 |
| rollout、resume/fork/revert、归档、线程搜索 | 会话与消息管理；对话导出与分享 | 详见同项目导出笔记 |
| `codex exec` 之外的多 Provider、模型目录、认证 | LLM 渠道管理 | 不是 Codex 独有的工作流 |
| 子智能体、协作工具、agent roles、message board | Agent 工具（子 Agent） | 入口与协议条目已确认，端到端回收未逐点核对，本次不设卡 |
| 实时语音会话 | 语音交互边界 | 通过 WebRTC 传输音频，不产生媒体资产 |

## 声明不符、外部依赖与暂缓项

- **`codex mcp-server` 不存在于本快照。** 仓库内没有独立 MCP 服务端 crate 或子命令；反向暴露由 app-server 协议承担。把 Codex 描述为“MCP 双向”会与当前可执行路径不符。
- **云端任务是外部依赖。** 服务端实现、环境定义、认证与结果托管都不在仓库内；本笔记只确认 CLI 与客户端侧链路。
- **代码模式默认关闭。** 虽然实现完整，但 `code_mode` 特性默认 false，且被标为开发阶段；不计入稳定主贡献。
- **子智能体未走通。** 工具与事件类型存在，但创建、并发、结果回收和权限继承的完整链路本次未逐点核对，保留为 `入口确认`。
- **文档不能作为证据。** `docs/` 下多数页面只有外链占位；行为判断以源码路径为准。

## 对特色贡献统计的影响

- **主贡献候选**：能力一（沙箱+审批+策略）、能力二（`apply_patch`）、能力三（`AGENTS.md`）、能力四（app-server）、能力五（`exec` 自动化）。这五项共同构成“可审批的本地执行 + 可被外部驱动的 Agent 服务”，是 Codex 与通用聊天客户端的主要差异。
- **辅助贡献候选**：能力七（云端任务交接）；能力六（代码模式）标注为实验性辅助，不计入稳定统计。
- **不重复计数**：MCP、Skills/Plugins/Hooks、线程管理、模型渠道、子智能体均归并到已有类目，不在本类目重复计分。

## 未验证事项

- 三平台沙箱的真实隔离强度、网络代理与 DNS 行为、提权重试在真实命令上的表现。
- `apply_patch` 在超大文件、歧义上下文、并发修改下的定位与失败回报。
- `AGENTS.md` 在本地 + 远端多执行器、多环境下的合并顺序与预算分配。
- app-server 与真实 IDE/桌面客户端的互通、daemon 重启恢复、远程控制鉴权。
- `codex exec` 在 CI 中的长任务、并发、结构化输出的实际稳定性。
- 代码模式真实模型脚本、异常中断、宿主崩溃恢复，以及默认关闭状态下的用户可达性。
- 云端任务的认证、环境解析、best-of-N 与 `apply` 的成功率。

## 关键源码索引

- 沙箱与审批：`codex-rs/protocol/src/protocol.rs:1163-1299`；`codex-rs/sandboxing/src/manager.rs:48-62,313-353`；`sandboxing/src/seatbelt.rs:844`、`landlock.rs:9-26`、`windows.rs:33-74`；`core/src/exec.rs:127-140,393-430`；`core/src/tools/sandboxing.rs:242-310`；`core/src/tools/approvals.rs:109-313`
- 策略 DSL：`codex-rs/execpolicy/src/decision.rs:9-20`、`src/parser.rs:3-14,88-109`、`src/amend.rs:65-121`；`core/src/exec_policy.rs:56-58,669-702`；`cli/src/main.rs:196-198`
- 补丁：`codex-rs/apply-patch/src/parser.rs:7-45`、`src/lib.rs:213-330`、`src/file_update.rs:57-60`；`core/src/tools/runtimes/apply_patch.rs:1-258`；`core/src/tools/events.rs:424-457`；`chatgpt/src/apply_command.rs:14-76`
- 指令：`codex-rs/core/src/agents_md.rs:43-116,192-296,378-473`；`codex-home/src/instructions/mod.rs:41-62`；`config/src/config_toml.rs:77,337-342`
- app-server：`codex-rs/cli/src/main.rs:571-638`；`app-server-protocol/src/protocol/common.rs:555-901`；`protocol/v2/thread.rs:544-573,1314-1318,1700-1731,1789-1898`；`sdk/typescript`、`sdk/python`
- 自动化：`codex-rs/exec/src/cli.rs:36-85,172-182`；`exec/src/lib.rs:3,1029-1049`；`exec/src/exec_events.rs:11-140`；`exec/src/event_processor_with_jsonl_output.rs:89-105`
- 代码模式：`codex-rs/code-mode-protocol/src/lib.rs:60-61`、`src/description.rs:20-43`；`core/src/tools/code_mode/execute_spec.rs:5-20`、`mod.rs:68-80,376`；`core/src/tools/code_mode/wait_handler.rs`；`code-mode-runtime/src/service.rs:34-67,257-269`；`code-mode-host/src/main.rs`
- 云端任务：`codex-rs/cli/src/main.rs:228-230`；`cloud-tasks/src/cli.rs:15-120`；`cloud-tasks-client/src/http.rs:336-385`
- 特性状态：`codex-rs/features/src/lib.rs:1303-1325,1900-1905`
