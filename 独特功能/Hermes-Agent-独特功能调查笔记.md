# Hermes Agent 独特功能调查笔记

> 调查对象：`E:\works\git\hermes-agent`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：只读盘点根 README 功能表、AGENTS.md 架构说明与源码（`agent/`、`tools/`、`plugins/memory/`、仓库根工具脚本）；未修改仓库源码
>
> 调查范围：闭环学习（记忆/技能后台复习）、Skill 自动创建与维护（skill_manage + curator）、持久记忆与用户建模（内置 MEMORY.md/USER.md + MemoryProvider 外部插件）、研究轨迹（轨迹保存/压缩/批量生成）、Tool Gateway；cron、委派、网关、TUI 与终端后端按待查清单标注已有覆盖并回链，不重写；/heartbeat、/goal 质量门、/refine、verify-on-stop、estop 按候选盘点处理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 的 README 自我定位是 "self-improving AI agent"，核心卖点是 "the only agent with a built-in learning loop"。本快照上这条主线确实形成了可走通的主链，且工程化程度高（后台线程、缓存复用、工具白名单、审批门、故障不阻塞主会话）：

| 候选 | 证据状态 | 一句话结论 |
|---|---|---|
| 闭环学习（记忆/技能后台复习） | `主链确认`（静态证据） | 每 N 轮/每 N 次工具迭代触发一次后台 fork 复习，fork 继承主会话运行时与提示缓存，白名单只放行 memory 与 skill_manage |
| 自动创建/改进 Skill | `主链确认`（静态证据） | `skill_manage` 六动作（create/patch/edit/delete/write_file/remove_file）+ 复杂任务（5+ 工具调用）创建指引 + curator 惰性后台维护（从不删除，只归档）+ `.usage.json` 统计 |
| 持久记忆与用户建模 | `主链确认`（内置）/ `入口确认`（外部 provider） | 内置 MEMORY.md/USER.md 文件记忆 + MemoryProvider ABC 外部后端（honcho/mem0/supermemory 等 8 个）+ 记忆写审批门 + 每轮 prefetch/sync |
| 研究轨迹 | `主链确认`（保存/压缩）/ `入口确认`（批量与数据集） | 轨迹 JSONL 保存 + trajectory_compressor 保护首尾压缩中间 + batch_runner/mini_swe_runner 批量生成；数据流水线为离线工具，不进入主会话 |
| Tool Gateway | `入口确认` | `tools/managed_tool_gateway.py` 统一路由 Nous 托管后端（firecrawl 搜索、fal-queue 图像、openai-audio TTS/转写、modal 沙箱）；外部订阅依赖 |
| 六/七类终端后端 | `归并已有类目` | `tools/environments/` 七个后端已在 Agent 工具笔记覆盖，本笔记只回链并记录 README 与待查清单的数字差异 |
| 跨会话检索（session_search） | `主链确认`（静态证据） | FTS5 + 会话谱系去重 + 锚定窗口，属于闭环学习"搜索自己过去对话"的组成件，一并归入学习闭环描述 |

与 VCP 系（AgentDream 叙事记忆）、LobeHub（五层白盒记忆）、Open WebUI（全局文本记忆）相比，Hermes 的记忆形态是**文件+外部后端双轨**，而最有辨识度的是**自我改进机制本身**：Agent 在后台复盘自己的对话并决定写记忆、建技能、改技能，且这一切以"prompt caching is sacred"为前提（fork 继承缓存、复习永不动主会话）。

## 系统边界

- 单仓库 Python 核心（run_agent.py/cli.py/gateway/）+ TS 前端（ui-tui/apps/desktop/web）；本笔记只涉核心与工具面。
- 闭环学习全部发生在本地进程内（fork 是进程内对象，不是子进程），后台线程执行，结果落文件或外部 provider。
- 与既有笔记分工：工具执行/审批链（[Agent工具笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)）、人格/提示词分层（[Agent角色笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)）、聊天表面（[Chat UI 笔记](../Chat%20UI/Hermes-Agent-ChatUI调查笔记.md)）。待查清单已确认 cron、委派、网关、TUI 覆盖较深，本笔记只回链不重写。

## 介绍声明与候选盘点

根 README（README.md:19-31）声明：built-in learning loop（"creates skills from experience, improves them during use, nudges itself to persist knowledge, searches its own past conversations, builds a deepening model of who you are"）、七类终端后端、Research-ready（"Batch trajectory generation, trajectory compression for training the next generation of tool-calling models"）、cron 自动化、委派并行、Honcho dialectic user modeling、agentskills.io 兼容。README 表格对学习闭环的描述（README.md:26）与代码实现一致。

## 已确认的独特能力

### 能力一：闭环学习——后台记忆/技能复习（`主链确认`，静态证据）

**用户目标**：让 Agent 不需要用户开口就自我沉淀——把对话中暴露的用户偏好写进记忆、把可复用流程固化为技能，且不打断主对话、不破坏提示缓存。README "nudges itself to persist knowledge" 的实现。

**入口与触发者**：三个独立计数触发器 + 一个按需入口（均为 Agent 侧自触发或用户显式命令）：

1. 记忆复习：`agent._user_turn_count` 每轮 +1，`_turns_since_memory >= _memory_nudge_interval`（默认 10，`agent/agent_init.py:1698-1713`，`memory.nudge_interval` 可配）→ `should_review_memory = True`（`agent/turn_context.py:421/685`）；
2. 技能复习：`_iters_since_skill >= _skill_nudge_interval`（默认 10，`agent_init.py:1798-1801`，`skills.creation_nudge_interval`）且 `skill_manage` 在工具集内（`agent/turn_finalizer.py:734-760`）；
3. 会话历史水化：恢复会话时按历史 user 消息数回填 `_turns_since_memory`，避免"重启后计数器归零永不触发"（`turn_context.py:592-644`，issue #22357）；
4. **`/refine` 按需触发**（`8f271272`，`hermes_cli/cli_commands_mixin.py:2545` `_handle_refine_command`）：用户显式运行同一记忆/技能复习 fork，可带 `[instructions]` 聚焦提示（`background_review.py:1106` 附近 docstring）。

**状态/对象**：计数器为 agent 实例字段；复习结果写入两个持久化面——记忆（`memory` 工具 → MEMORY.md 或外部 provider）与技能库（`skill_manage` → `~/.hermes/skills/<name>/SKILL.md`）。`AIAgent` 提供 `skip_background_review` 构造参数（`eaeba647`），cron 会话默认关闭后台复习（防污染用户画像/技能库，与 `skip_memory=True` 同一硬化思路）。

**完整主链**：回合响应交付后（`turn_finalizer.py:760` 附近，"runs AFTER the response is delivered so it never competes with the user's task"）→ `_spawn_background_review`（daemon 线程）→ `spawn_background_review_thread`（`agent/background_review.py:1093`）→ fork 一个 `AIAgent` 复习体：

- fork 继承父运行时（provider/model/base_url/凭据/已缓存 system prompt），命中同一提示缓存；`auxiliary.background_review.{provider,model}` 可路由到更便宜的模型，路由后改用压缩摘要重放（`_digest_history`，`background_review.py:123`，"same model -> full replay; different model -> digest"）；
- 工具白名单：`review_whitelist` 只含 memory 与技能管理工具，越权调用被 `set_thread_tool_whitelist` 拒绝（`background_review.py:935-953`，注释 "Background review denied non-whitelisted tool"）；
- 复习提示词：`_MEMORY_REVIEW_PROMPT`（"用户透露了什么关于自己的事值得记？"）与 `_SKILL_REVIEW_PROMPT`（"要 ACTIVE——大多数会话至少产生一次技能更新"；用户纠正风格/工作流是一级技能信号）（`background_review.py:171-182`）。live turn 开始前会取消 in-flight 后台复习（`71435fa0`），避免复习与主对话竞争。

**用户结果**：复习体通过 memory 工具写记忆（或说 "Nothing to save."）、通过 skill_manage 创建/修补技能；记忆写可能进入审批门（见能力三）；`summarize_background_review_actions` 生成动作摘要供 UI 回调（`background_review.py:410`）。

**持续性**：文件（MEMORY.md、skills/*）与外部 provider；复习体计数器被清零（`background_review.py:815-816`）防递归；复习失败仅捕获不抛出（`turn_finalizer.py:723-724` "best-effort"）。

**主动性与取消**：无用户干预入口（计数驱动）；配置可整体关闭（`nudge_interval: 0`）；curator 可暂停（见能力二）。

**外部依赖**：无（同模型或 `auxiliary.background_review` 路由的模型）；fork 使用父进程凭据。

**独特性判断**：这是"自我改进"的运行时闭环，不是记忆文件本身。与 VCPToolBox AgentDream（定时触发、审批预算）、LobeHub 定时提取（Upstash 工作流，离线全量）的关键差别：Hermes 的复习与主会话共享运行时与缓存，只花一次模型调用成本完成记忆+技能双写，且被设计为对主对话零干扰。标签：`记忆演化`、`自进化 Skill`。

### 能力二：Skill 自动创建、使用中改进与 curator 维护（`主链确认`，静态证据）

**用户目标**：把"重复任务的做法"固化为可复用技能，并在使用中发现不足时立刻修补，长期由后台 curator 负责归档与整合——形成技能的完整生命周期（创建 → 使用 → 修补 → 沉淀 → 归档）。

**主链**：

1. **创建**：`skill_manage` 工具（`tools/skill_manager_tool.py:1641-1676` 的 schema 描述即产品语义）——actions: create/patch/edit/delete/write_file/remove_file；"Create when: complex task succeeded (5+ calls), errors overcome, user-corrected approach worked"；"If you used a skill and hit issues not covered by it, patch it immediately"——使用中自改进是同一工具的两个动作面。前台创建需与用户确认（"Confirm with user before creating/deleting"），后台复习路径由 `is_background_review()` 标记来源（`skill_manager_tool.py:1600-1604`）。技能索引注入 system prompt volatile 段（Agent 角色笔记 §3 已覆盖），技能命令以 user 消息注入不破坏缓存。
2. **统计**：`tools/skill_usage.py` 维护 `~/.hermes/skills/.usage.json` 侧车（use_count/view_count/patch_count/last_activity_at/state/pinned），`record_created`/`bump_patch` 在每次 skill_manage 成功时落账（`skill_manager_tool.py:1599-1620`）。
3. **维护**：curator（`agent/curator.py:1-20` 模块文档）——惰性调度（无 cron 守护进程，Agent 空闲且距上次运行超过 `interval_hours` 时 `maybe_run_curator()` fork 复习体）；确定性状态机 `apply_automatic_transitions`（stale_after_days=30 标记 stale、archive_after_days=90 归档）+ 可选 LLM 整合 pass（`DEFAULT_CONSOLIDATE = False` 默认关闭）；硬性不变量：只碰 `created_by: "agent"` 的技能（`tools/skill_usage.is_agent_created`）、永不删除（归档可恢复）、pinned 技能跳过所有自动转移（`curator.py:15-20`）；状态持久化在 `~/.hermes/skills/.curator_state`（`curator.py:85-98`）。CLI：`hermes curator <status|run|pause|resume|pin|unpin|archive|restore|prune|backup|rollback>`（hermes_cli/curator.py）。`absorbed_into` 参数让整合/剪枝可被 curator 区分（`skill_manager_tool.py:1651-1657`）。
4. **生态**：`skills/`（默认启用）+ `optional-skills/`（`hermes skills install official/<cat>/<skill>`，tools/skills_hub.py）+ agentskills.io 兼容（README 声明）。

**持续性**：全部为磁盘文件（skills 目录、.usage.json、.curator_state），profile 隔离；`hermes backup` 含技能。

**外部依赖**：curator 整合 pass 需要 aux 模型调用；其余全本地。

**独特性判断**：技能不是"静态提示词包"，而是有来源标记（agent-created）、用量统计、自动生命周期与恢复性归档的对象。与 OpenCode/AIO Hub 的 Skills（人工编写为主）相比，Hermes 的技能库会自我演化。标签：`自进化 Skill`。

### 能力三：持久记忆与用户建模（`主链确认`：内置面；`入口确认`：外部 provider）

**用户目标**：跨会话记住用户事实并建立用户画像；READMME "builds a deepening model of who you are"。

**事实对象**（双轨）：

- 内置：`~/.hermes/memories/MEMORY.md`（Agent 长期记忆）与 `USER.md`（用户画像，`memory.user_profile_enabled` 开关），两者注入 system prompt volatile 段（Agent 角色笔记 §3.3 已确认注入链）；
- 外部：`MemoryProvider` ABC（`agent/memory_provider.py:81`：initialize/system_prompt_block/prefetch/queue_prefetch/sync_turn/get_tool_schemas/handle_tool_call/shutdown + 可选 on_turn_start/on_session_end/on_pre_compress/on_memory_write/on_delegation 钩子），`plugins/memory/` 内置 8 个 provider（honcho/mem0/supermemory/byterover/hindsight/holographic/openviking/retaindb），同一时刻至多一个外部 provider（`memory_manager.py:6-8`），由 `memory.provider` 配置激活。

**完整主链**：`MemoryManager`（`agent/memory_manager.py:364`）统一编排——每轮 `prefetch_all(user_message)` 注入召回上下文（`build_memory_context_block` 封装 + `StreamingContextScrubber` 流式清洗 `<memory-context>` 围栏，防止注入文本泄漏到 UI）、回合后 `sync_all` 后台写回、`queue_prefetch_all` 预取下一轮；外部 provider 工具 schema 经 `inject_memory_provider_tools` 追加到工具面（`memory_manager.py:110`，`memory_provider_tools_enabled` 受 memory toolset 门控）；琐碎输入跳过召回（`is_trivial_prompt`，`memory_provider.py:52-78`，"hi/thanks/ok" 等不触发网络召回）。

**人机关系**：记忆写审批门——`_apply_write_gate`（`tools/memory_tool.py:911`）命中时记忆写入转为 staged + pending_id，`/memory approve` 后由 `apply_memory_pending` 落盘（`memory_tool.py:1130`），即"模型想写记忆"可以被人审拦截；`tools/write_approval.py` 提供后台复习写的前景审批机制（测试 `test_background_review_toolset_restriction.py` 等验证）。

**用户建模**：Honcho provider（`plugins/memory/honcho/README.md`："AI-native cross-session user modeling with multi-pass dialectic reasoning, session summaries, bidirectional peer tools, and persistent conclusions"）——外部云服务（OAuth/device code/API key），`hermes memory setup honcho` 配置；其 `build_system_prompt()` 追加 volatile 段（Agent 角色笔记 §3.3 已确认拼接点）。Honcho 接入做了健壮性修复：认证过的 SDK 调用统一走 401 恢复助手（`864035b2`）、**会话中途 oauth 401 可恢复记忆并只提示一次**（`6ea01262`）、OAuth grant 失效时跳过记忆调用（`ecfc427b`）、session 初始化失败也暴露认证提示（`086dcb8b`）、裸 "401" 数字不再误判为认证错误（`b1414baa`）——会话中途刷新 token 不再中断记忆链路。

**持续性**：内置为文件；外部 provider 持久化在各自服务端；`on_session_end`/`on_pre_compress` 钩子提供会话末/压缩前提取；cron 会话 `skip_memory=True`（AGENTS.md cron 硬化不变量，防污染用户画像）。

**外部依赖**：外部 provider 为 SaaS（honcho/mem0/supermemory 等），属于"仓库外商业服务"但存在本仓库接入主链（ABC + MemoryManager + setup 向导），按指南计入。

**独特性判断**：记忆不是单一文件注入，而是"文件 + 插件 ABC + 后台同步 + 写审批 + 复习闭环"的组合。用户建模的"deepening"由 Honcho 的 dialectic 多轮推理承担（外部）。与 LobeHub 白盒记忆（结构化五层+工具读写）相比，Hermes 是自由文本记忆 + 外部语义建模。

### 能力四：研究轨迹——会话轨迹生产（`主链确认`：保存与压缩；`入口确认`：批量与数据集）

**用户目标**：把真实 Agent 会话变成可训练数据（README "Batch trajectory generation, trajectory compression for training the next generation of tool-calling models"）。

**主链**：

- **保存**：`save_trajectories`（AIAgent 参数）→ `convert_to_trajectory_format`（`agent/agent_runtime_helpers.py:115`，ShareGPT 格式）→ `save_trajectory`（`agent/trajectory.py:30`）追加 JSONL——成功进 `trajectory_samples.jsonl`、失败进 `failed_trajectories.jsonl`，条目带 model/completed/timestamp；
- **压缩**：`trajectory_compressor.py`（仓库根，1598 行）——保护首尾（system/human/首个 gpt/首个 tool + 最后 4 轮），只压缩中间段，替换为单条 human 摘要消息，目标 token 预算（默认 15250，`CompressionConfig`），支持目录批量与采样百分比（`--sample_percent=15`）；
- **批量生成**：`batch_runner.py`（并行批量处理，AGENTS.md 中注明调用 `agent._convert_to_trajectory_format`）、`mini_swe_runner.py`（SWE 类任务 runner）、`datagen-config-examples/`（web_research.yaml、trajectory_compression.yaml、example_browser_tasks.jsonl）、`mcp-research-data/`（ue_bench/ue_discovery/hard 数据集 json）。

**持续性**：JSONL 文件；离线工具链，不进入主会话。

**外部依赖**：压缩摘要调用 OpenRouter 模型（`trajectory_compressor.py` 导入 OpenRouter base url）；tokenizer 默认 `moonshotai/Kimi-K2-Thinking`。

**独特性判断**：绝大多数客户端把会话历史当聊天记录存，Hermes 把轨迹当训练数据生产（保存/压缩/批量生成/数据集管理成一套工具链）。标签：`研究轨迹`。

## 已归并到现有类目的能力

- **终端后端**：`tools/environments/` 共 7 个后端（base/local/ssh/docker/singularity/modal/managed_modal/daytona/vercel_sandbox 文件，实际可执行后端 7 类），已在 [Agent 工具笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md) §6 执行边界与第 8 节覆盖（容器资源上限、execute_code 沙箱、容器风险豁免）；README 说 "Seven terminal backends"，待查清单记"六类"，本快照按文件清单为 7 类。状态：`归并已有类目`。
- **Tool Gateway**：`tools/managed_tool_gateway.py` 确认存在——`resolve_managed_tool_gateway("fal-queue"|"modal"|"openai-audio")`、web_tools 的 firecrawl 网关路由（`tools/web_tools.py:236-246`），按 Nous Portal 订阅与 entitlements 门控（`tools/tool_backend_helpers.py`）。README "per-backend, not all-or-nothing"。回链 [Agent 工具笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)（工具审批/执行链覆盖网关会话级 yolo 等）；完整凭据/订阅流未验证。状态：`入口确认`（外部订阅依赖）。
- **cron 定时任务**：`cron/jobs.py` + `cron/scheduler.py`（AGENTS.md 硬化不变量：3 分钟硬中断、catchup 窗口、`.tick.lock` 文件锁、`skip_memory=True`），按待查清单标注已有覆盖（Agent 工具笔记 cron approvals.cron_mode、委派与网关笔记），本笔记不重写。状态：`归并已有类目`。
- **委派/子 Agent、MCP、插件体系、人格系统**：回链 Agent 工具/角色笔记。

## 声明不符、外部依赖与暂缓项

- **"the only agent with a built-in learning loop"**：声明强度超出可验证范围（无法证明"唯一"），但学习闭环本体在本快照有完整实现；按实现事实记录，不背书宣传强度。
- **Honcho 用户建模**：核心语义（dialectic 多轮推理、持久结论）在外部 Honcho 服务实现，本仓库只有接入链（plugin.yaml + client + oauth + session），具体建模质量未验证。状态：`入口确认`。
- **七终端后端中的 serverless 持久**（"environment hibernates when idle"）：Modal/Daytona 的休眠-唤醒语义依赖外部服务，本仓库只验证到环境适配器层。状态：`入口确认`/外部依赖。
- **agentskills.io 兼容**：README 声明，本次未核验协议细节（未验证事项）。

## 补充盘点的候选

- **会话心跳（`/heartbeat`，`主链确认`，静态证据）**：`hermes_cli/heartbeat.py`（`6518aa18`）——用户拥有的**会话级重复重入指令**（`/heartbeat every 10m <prompt>`），到期且会话空闲时作为普通 user turn 注入（与 /goal continuation 同一机制，不动 system prompt、不换 toolset，提示缓存与角色交替不受影响）；busy 时 tick 合并（空闲后只补一次，不堆积）；状态持久化在 SessionDB `state_meta` 的 `heartbeat:<session_id>`，`/resume` 可拾取；与 cron 明确分工（cron=隔离会话的调度任务，heartbeat=持续重入当前会话）。标签：`主动 Agent`。
- **目标质量门（`/goal` + quality gates，`主链确认`，静态证据）**：`hermes_cli/goals.py`（`6e041d52`）——/goal 循环在每次"可能完成"时用 judge 复查（`server.py:10234` 起注释描述 Ralph-style loop），并可配置**确定性命令质量门**（必须通过后才允许 /goal 完成）；续接提示只是普通 user 消息、真实用户消息抢占（`goals.py:6-20` 不变量）。标签：`主动 Agent`（与 heartbeat 同族，可合并计数）。
- **按需复习（`/refine`）**：并入能力一（见上），不单独计数。
- **verify-on-stop**：`agent/verify/`（recipes/environment/runner，`47a35d63` 系列）——回合终止前对候选回复跑 run-recipe 检测与验证（`_pending_verification_response`），已并入 [Agent 工具笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md) §5。状态：`归并已有类目`。
- **全局紧急停止（`hermes pause`/`resume`，`入口确认`）**：`agent/estop.py`（`5db1b72b`）——跨会话全局停止位（`hermes_cli/subcommands/pause.py`），属安全/可靠性机制，不进入用户可见产品特性统计。
- **技能生态扩充**：新增十余个 bundled/optional 技能（competitor-news-monitor、social-media-content-calendar、weekly-review-planning、product-price-monitor、meeting-action-items、google-workspace-daily-brief、github-issue-to-pr、email-inbox-triage、document-to-action-items、clean-room office 文档技能等）并整体收紧 HARDLINE 标准（`55982159`/`1c943389`），均为能力二生态的实例扩充，不改变机制结论。

## 对特色贡献统计的影响

- 建议新增主贡献候选：**闭环学习（后台记忆/技能复习 + /refine 按需）**、**Skill 生命周期（创建-改进-curator 维护）**（标签：`自进化 Skill`、`记忆演化`）；**研究轨迹工具链**（标签：`研究轨迹`）可作为独立贡献；**会话心跳 + 目标质量门**（标签：`主动 Agent`）可作为新主贡献候选（待与至少三个项目聚类后建立局部比较）。
- 辅助贡献：持久记忆与用户建模（与记忆演化聚类中 VCP/LobeHub/Open WebUI 形成自然聚类，比较维度：对象形态文件 vs 结构化、触发方式计数 vs 定时 vs 梦境、写入是否需人审）。
- 记忆写审批门与"模型写记忆被拦截"在横向对比中可作为人机关系维度证据。
- `/refine` 并入闭环学习计数、verify/estop 不进入特性统计（见新增候选小节）。

## 未验证事项

- 复习 fork 在真实长会话中的成本与频率（默认 10 轮/10 迭代触发一次，未运行验证）。
- `auxiliary.background_review` 路由到不同模型时的摘要重放质量。
- curator LLM 整合 pass（`consolidate` 默认关闭）的实际行为。
- Honcho 等外部 provider 的建模质量与数据驻留；会话中途 401 恢复在真实 OAuth 到期场景的端到端行为未实测。
- trajectory_compressor 的 tokenizer 依赖（Kimi-K2-Thinking）在无网环境的可用性。
- 终端后端"serverless 休眠唤醒"跨会话恢复语义（外部服务行为）。
- /heartbeat 与 /goal 的运行时行为（空闲判定、tick 合并、真实消息抢占）为静态推断，未运行验证。

## 关键源码索引

- 闭环学习：`agent/turn_context.py:421/592-644/685`（记忆 nudge 触发）、`agent/turn_finalizer.py:734-760`（技能 nudge + 后台复习调度）、`agent/background_review.py`（复习 fork `spawn_background_review_thread` :1093、白名单 :935-953、提示词 :171-182、digest :123、`/refine` :1106 附近）、`agent/agent_init.py:1698-1801`（间隔默认值与配置读取）、`hermes_cli/cli_commands_mixin.py:2545`（`/refine`）。
- Skill 生命周期：`tools/skill_manager_tool.py`（schema 语义 :1641-1676 附近；`is_background_review` 来源标记经 `tools/skill_provenance.py`）、`tools/skill_usage.py`（.usage.json）、`agent/curator.py`（惰性调度、不变量 15-20、状态文件 85-98）、`tools/skills_hub.py`。
- 记忆与用户建模：`agent/memory_manager.py`（MemoryManager 364、写门相关 1019-1128）、`agent/memory_provider.py:81`（ABC）、`tools/memory_tool.py:919,1138`（写审批门与 pending 应用）、`plugins/memory/honcho/`（401 恢复 `864035b2`/`6ea01262` 系列）。
- 主动 Agent（新增候选）：`hermes_cli/heartbeat.py`（会话心跳）、`hermes_cli/goals.py`（/goal 质量门）、`agent/estop.py`（紧急停止）。
- 研究轨迹：`agent/trajectory.py:30`（save_trajectory）、`agent/agent_runtime_helpers.py:115`（convert_to_trajectory_format）、`trajectory_compressor.py`、`batch_runner.py`、`mini_swe_runner.py`、`datagen-config-examples/`。
- Tool Gateway：`tools/managed_tool_gateway.py:174-211`（resolve/is_ready）、`tools/web_tools.py:236-246`、`tools/tool_backend_helpers.py`。
- 跨会话检索：`tools/session_search_tool.py:848`（session_search 主函数，FTS5+谱系去重）。
