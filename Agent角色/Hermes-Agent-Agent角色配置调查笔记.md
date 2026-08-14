# Hermes-Agent Agent 角色配置调查笔记

> 调查对象：`E:\works\git\hermes-agent`（Hermes Agent）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：静态代码阅读 + 全仓符号检索；按 `git log`/`git diff` 对提交范围做增量核对，受影响结论在 HEAD 处源码重新确认并修正行号；工作树干净，未运行程序
>
> 调查范围：角色/人格/persona/SOUL/身份/系统提示词的实体、存储、选择、拼装、参数绑定、外部能力、资产变量、导入导出与运行时可见性；TTS 专属 persona 与第三方 runner 不在范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent **没有独立持久化的“角色对象”**。它的“角色”是多个互补的提示词机制，按“身份 → 命名模板 → 全局/会话覆盖 → 运行时注入”分层叠加：

1. **身份层（SOUL.md）**：`$HERMES_HOME/SOUL.md` 是代理的“主身份文件”，首次运行自动用 `DEFAULT_SOUL_MD` 种子（`hermes_cli/config.py:840-914`），进入 system prompt 的 stable 层；无文件时回退到硬编码 `DEFAULT_AGENT_IDENTITY`（`agent/prompt_builder.py:144`）。
2. **人格模板（personalities）**：`config.yaml → agent.personalities` 是具名模板（string 或 `{system_prompt,tone,style}`），内置 14 个模板集中于**单一所有者模块** `hermes_cli/personality.py` 的 `BUILTIN_PERSONALITIES`（由 CLI 默认值迁入，`da6f0030`/`fe9e4d17` 系列）；用户条目按名覆盖内置。
3. **全局/会话 system prompt**：`display.personality` 保存**选中的名称**（空 = 无 overlay）并成为权威来源——启动/建 agent 时 `resolve_ephemeral_system_prompt_from_config` 优先把命名人格渲染成文本，否则回退到 user-owned 的 `agent.system_prompt`；env `HERMES_EPHEMERAL_SYSTEM_PROMPT` 仍最优先。三者最终收集为 agent 的 `ephemeral_system_prompt`，在主请求路径中附加在缓存 prompt 之后，**不写入轨迹**。**人格代码永不写 `agent.system_prompt`**（该字段保留给用户手动提示；v33→v34 迁移一次性清理旧 `/personality` 写入的文本并重置选择，`config_migrations.py:648-717`）。
4. **会话/渠道覆盖**：`ChannelOverride(model/provider/system_prompt)` 支持 per-channel 覆盖（`gateway/config.py:543-574`）；TUI 会话可存 `personality` 覆盖键。
5. **角色隔离由 Profile 承担**：`hermes profile create --clone` 复制 `config.yaml/.env/SOUL.md/skills/`，构成一套含模型、记忆、技能与提示词的完整隔离包。

关键运行时语义：system prompt **每个会话构建一次并缓存，仅在上下文压缩时重建**（`agent/system_prompt.py:1-8`），字节稳定以保住前缀缓存；`ephemeral_system_prompt` 在 API 调用时才拼接，不进缓存、不进轨迹（`agent/chat_completion_helpers.py:2394-2395`）。完整构建的 system prompt 会被记录（`system_prompts` hash 去重表 + session 行引用 model/model_config），但当前人格文本本身不随历史保存。

## 总体生效链路

以 CLI `/personality pirate` 为例：

```
/personality pirate
  cli.py  canonical=="personality" → _handle_personality_command(cmd_original)
  hermes_cli/cli_commands_mixin.py:1336-1410
     ├─ resolve_personality(name, config)   # personality.py:122 规范化名 + 渲染文本（dict → system_prompt + "Tone:" + "Style:" 行）
     ├─ persist_personality(name)           # 写 display.personality 名称（不写 agent.system_prompt）
     ├─ self.system_prompt = personality_prompt   # 当前会话实例取渲染文本（作为 ephemeral 传入 agent）
     └─ self.agent = None                   # 强制下一次消息重建 agent
下一条消息/新 agent：
  cli.py  self.system_prompt = env HERMES_EPHEMERAL_SYSTEM_PROMPT
          → resolve_ephemeral_system_prompt_from_config：display.personality 命名人格 > agent.system_prompt
  hermes_cli/cli_agent_setup_mixin.py  AIAgent(ephemeral_system_prompt=self.system_prompt or None)
  agent/agent_init.py:594  agent.ephemeral_system_prompt = ...
  run_conversation:
     conversation_loop.py:475-541  _restore_or_build_system_prompt → agent._build_system_prompt()
     system_prompt.py:152-558  build_system_prompt_parts(agent, system_message)
        stable:   load_soul_md() 或 DEFAULT_AGENT_IDENTITY + 工具指引 + 模型指引 + 平台暗示 + active-profile 提示
        context:  system_message + 项目上下文文件(AGENTS.md/.cursorrules/…) + workspace 快照
        volatile: 技能索引 + MEMORY.md + USER.md + 外部 memory provider + 日期/会话/模型行
     system_prompt.py:561-587  build_system_prompt  → 缓存到 _cached_system_prompt
  API 请求组包: chat_completion_helpers.py:2200-2201
     effective_system = _cached_system_prompt + "\n\n" + agent.ephemeral_system_prompt
  持久化: run_agent.py:649-656  create_session(system_prompt=_cached_system_prompt, model, model_config)
```

渠道（gateway）差异：渠道级提示来自 `channel_overrides[channel_id].system_prompt` 或全局 `agent.system_prompt`；模型优先级由 `hermes_cli/model_switch.py:760` 的 `resolve_effective_model` 按会话 > 渠道 > 全局解析。

## 1. 角色数据模型与存储

| 概念 | 实体类型 | 存储位置 | 持久化格式 |
| --- | --- | --- | --- |
| SOUL.md | 身份文件（非结构化 Markdown） | `$HERMES_HOME/SOUL.md` | 文本 |
| personalities | 命名人格模板 | `config.yaml → agent.personalities` | dict：name → string 或 `{system_prompt, tone, style}` |
| agent.system_prompt | 用户手动 overlay（人格代码不写） | `config.yaml → agent.system_prompt` | string |
| agent.ephemeral_system_prompt | 运行时注入、不入轨迹 | agent 实例内存 | string |
| display.personality | **人格选择（权威，全表面统一）**：命名人格名 / 空 | `config.yaml → display.personality` | string（名称） |
| ChannelOverride | per-channel 覆盖 | `platforms.<name>.channel_overrides[channel_id]` | dataclass（model/provider/system_prompt） |
| Profile | 完整角色包（隔离 HERMES_HOME） | `~/.hermes/profiles/<name>/` | 整个目录 |
| system_prompts 表 | 提示文本去重存储 | `hermes_state.db` | SQLite（hash → text） |
| sessions 表 | 会话消耗的 model/model_config 快照 | `hermes_state.db` | SQLite 行 |

- **SOUL.md 种子与升级**：首轮运行写 `DEFAULT_SOUL_MD`；若现有内容与 legacy 空模板逐字节匹配则自动升级，用户自定义内容永不改写（`hermes_cli/config.py:840-914`；模板在 `hermes_cli/default_soul.py`）。`hermes profile create` 也会 seed（profiles.py:1136-1138）。`hermes doctor` 检查其存在与空/非空（`hermes_cli/doctor.py:1453-1474`）。
- **内置 14 个人格字符串模板**：helpful/concise/technical/creative/teacher/kawaii/catgirl/pirate/shakespeare/surfer/noir/uwu/philosopher/hype（由 `cli.py:481-496` 迁入 `hermes_cli/personality.py` 的 `BUILTIN_PERSONALITIES`，`personality.py:60-79`）。dict 形式参考 `cli-config.yaml.example` 的 `agent.personalities` 示例（含 `system_prompt/tone/style`）。
- **dict 值渲染**：`render_personality_prompt`（`hermes_cli/personality.py:82`，`config.py:2947` 转发）——字符串原样；dict 拼接 `system_prompt` 加 `Tone:`/`Style:` 逐行；`normalize_personality_name`（`:104`）统一中立名（`none/default/neutral/""` → 空）。
- **配置读取与 env**：`HERMES_EPHEMERAL_SYSTEM_PROMPT` 优先于 `resolve_ephemeral_system_prompt_from_config`（其内部 `display.personality` 命名人格优先于 `agent.system_prompt`）；`HERMES_IGNORE_RULES`/`--ignore-rules` 使 SOUL、AGENTS.md、记忆一起失效。
- **记忆相关文件**：`memory.memory_enabled`（MEMORY.md，agent 长期记忆）、`memory.user_profile_enabled`（USER.md，用户画像），见 `cli-config.yaml.example` 的 `memory:` 示例；USER.md 位于 `~/.hermes/memories/USER.md`。
- **删除**：不存在“删除某个角色对象”；删除 `display.personality`/`agent.system_prompt` 配置、关闭 personality 为 `none`/`""`，或删除整个 profile 目录即为删除。

## 2. 创建、选择与会话绑定

- **创建**：
  - SOUL.md：首轮/`hermes profile create` 自动种子，或直接编辑 `$HERMES_HOME/SOUL.md`；web 提供 `/api/profiles/<name>/soul` GET/PUT/DELETE（`hermes_cli/web_routers/profiles.py:600-640`）。
  - personalities：直接编辑 config.yaml（本次未发现专门的创建命令）。
  - Profile：`hermes profile create <name> [--clone|--clone-all]`（`hermes_cli/profiles.py:998-1090`）。
- **选择**：
  - CLI：`/personality <name>`（cli_commands_mixin.py:1329-1357）；`none/default/neutral` 清除为 `""`。
  - Gateway：`/personality` 列出/设置（`gateway/slash_commands.py:2492-2560`，`_resolve_prompt` 解析）。
  - TUI/桌面：`/personality` 打开 picker（`hermes_cli/commands.py` 的 picker 命令集），走 RPC `config.set {key:"personality", session_id, value}`（`ui-tui/app/slash/commands/session.ts:191-216`）。
  - Profile：`hermes -p <name>`；gateway 按名 `platform_key/socket/server/channel/thread` 路由（`gateway/profile_routing.py:1-38`）。
- **会话绑定**：
  - CLI：`agent.system_prompt` 是会话启动时的一次性值（env 或 `resolve_ephemeral_system_prompt_from_config`），持久化后供下次启动读取；TUI 支持会话内 `session["personality"]` 覆盖（server.py:5192-5193）。
  - TUI 修改人格会对**既有会话**就地改 `agent.ephemeral_system_prompt`（`_apply_personality_to_session`，`server.py:6040-6090`：更新 ephemeral、必要时插入 `[System: ...]` 提示、写 `display_kind="personality_switch"` 时间线条目），不重置历史；选择经 `persist_personality` 落 `display.personality`（`config.set personality`，`server.py:11500-11534`）。CLI 则走 `self.agent = None` 强制重建。
  - Channel 覆盖作用域为渠道；Profile 作用域为整个 profile。
- **会话记录**：`run_agent.py` 建会话时写入 `system_prompt=self._cached_system_prompt` + model/model_config；CLI 建会话没有传 system_prompt 参数，仅 model_config=max_iterations/reasoning_config。

**覆盖优先级（综合）**：模型——会话 `/model` 或模型切换 > 渠道 override > 全局 `model:` 配置；提示——先看三大块拼装顺序，ephemeral 在缓存之后追加、永不覆盖；人格 = `display.personality` 名称 → 运行时渲染文本 → `ephemeral_system_prompt` overlay（`resolve_ephemeral_system_prompt_from_config`，`config.py:2957` 附近；`personality.py:142` `active_personality_name`），**不再写 `agent.system_prompt`**。

## 3. 提示词字段与最终拼装顺序

`agent/system_prompt.py` 的 `build_system_prompt_parts`（152-558）返回三块，`build_system_prompt`（561-587）用 `\n\n` 连接并缓存：

- **stable**（跨会话稳定）：SOUL.md 或 `DEFAULT_AGENT_IDENTITY`（189-201）→ `HERMES_AGENT_HELP_GUIDANCE` → `TASK_COMPLETION_GUIDANCE`（如有工具且未禁用）→ `PARALLEL_TOOL_CALL_GUIDANCE` → 工具专用指引（仅加载了对应工具时才注入：memory/session_search/skill_manage/steer note）→ computer-use 指引 → nous 订阅 → TOOL_USE_ENFORCEMENT（按模型名匹配 + 各模型操作指引）→ 技能索引相关提示 → alibaba model-name 兜底 → 环境提示（`build_environment_hints`）与环境探测（`environment_probe`）→ active-profile 提示 → 平台提示（`PLATFORM_HINTS` + config `platform_hints` override）。
- **context**（cwd 相关）：在编码时 workspace 快照（coding_context）之后接 `system_message`（如调用方提供）→ `build_context_files_prompt`（`prompt_builder.py:2273`，优先级注释 :2281-2287）。项目上下文**优先级：`.hermes.md`/`HERMES.md` → `AGENTS.md` → `CLAUDE.md` → `.cursorrules`，只取一种**；但 **AGENTS.md 是"git root → cwd 的目录链合并"**（`2e2fcc09` port from grok-cli：`_agents_md_directory_chain` `prompt_builder.py:2139`——沿 git root 到 cwd 每个目录各取 `AGENTS.md`/`agents.md` 首个命中，带 provenance 标签合并成段，链上重复内容跳过；`_load_agents_md` :2166）。SOUL.md 独立且总是包含（除非已作为身份载入，`skip_soul`）。cwd 回退到 Hermes 安装树时跳过项目上下文发现（:2316-2327）。
- **volatile**（最易变，放最后）：技能索引（正因为在缓存稳定前缀中不需要）→ MEMORY.md（agent 记忆）→ USER.md（用户画像）→ 外部 memory provider 的 `build_system_prompt()` → 日期行（到天，保证全天 byte-stable，`system_prompt.py:543-552`）。

细节：
- `ephemeral_system_prompt` **不进入这三块**（`system_prompt.py:475-478` 注释明确），只由 chat_completion_helpers/conversation_loop 在 API 调用时 `\n\n` 追加。
- `skip_soul` 防止 SOUL 被加载两次（identity 槽位与 project-context 槽位）。
- 每个由 `_cached_system_prompt_static` 重建 static 前缀的机制保留 `[stable, volatile]` 两段缓存布局（`reconstruct_static_prefix`，602-654）。

## 4. 模型、Provider 与生成参数

- 人格/身份文件**不绑定**模型、Provider 或采样参数；绑定发生在全局 `model:` 配置、session `/model` 切换、ChannelOverride（`gateway/config.py:543-574`）、Profile（独立 config.yaml）和 `auxiliary.*` 任务级覆盖。
- **采样参数进包**：`agent/transports/chat_transport.py:599-664` `_build_kwargs_from_profile` 用 ProviderProfile；temperature 取 profile `fixed_temperature`（可能返回 `OMIT_TEMPERATURE`）或调用方 params；`max_tokens` 优先级 ephemeral > 用户 > profile 默认（`profile.get_max_tokens`）。Anthropic 对思维模型强制 temperature=1，对 Opus 4.7 等剔除非默认 temperature/top_p/top_k（`anthropic_adapter.py:3012-3022`）；Kimi/Moonshot 等由 `auxiliary_client.py:640-656` 决定是否省略 temperature。
- 上下文窗口限额来自模型目录 `DEFAULT_CONTEXT_LENGTHS_LOWER`（context_compressor），`context_file_max_chars` 显式配置可覆盖。
- **切换模型不改 system prompt 内容**，只换请求 model/provider；会话快照记录 `model/model_config`（session 行）。

## 5. 工具、知识、记忆与子 Agent

- 人格/提示词**不授权工具**。工具授权在平台级 `tools.<platform>.enabled/disabled`、`hermes tools`（`hermes_cli/tools_config.py`）。工具是否加载影响提示词中是否注入对应指引（比如有 `memory` 工具才加入 MEMORY_GUIDANCE，`system_prompt.py:228-245`），这是“授权影响提示词”，角色本身不绑工具。
- **Skills**：技能索引只在存在 skills 工具时生成（`build_skills_system_prompt`），放入 volatile。技能位于 `~/.hermes/skills/`；技能命令以 user 消息注入（不破坏缓存）。
- **记忆**：MEMORY.md（agent 记忆）与 USER.md（用户画像）都在 volatile 段（`system_prompt.py:515-524`）。USER.md 有独立开关 `memory.user_profile_enabled`。
- **外部记忆 Provider**：可选插件，同一时刻至多启用一个，由 `memory.provider` 配置；插件目录 `plugins/memory/<name>`，经 `agent/memory_manager.py` 编排，其 `build_system_prompt()` 追加 volatile 段（`system_prompt.py:527-533`）。
- **子 Agent**：`delegate_task` 生成子 agent，默认继承 `ephemeral_system_prompt`（`agent/background_review.py:753-754`），角色提示随委派上下文传入。

## 6. 资产、变量、开场白与用户画像

- **用户画像**：USER.md（persona 描述）进入 volatile 段，`format_for_system_prompt("user")`（`system_prompt.py:521-524`）。
- **变量/占位符**：config.yaml 支持 `${VAR}`/`${env:VAR}` 递归展开（`hermes_cli/config.py:2546-2560` `_expand_env_vars`；`load_config()` 展开）；未解析保留原样。这是通用配置机制，不属于角色字段。
- **头像/开场白/快捷回复**：本次范围内未找到人格绑定头像/开场白/快捷回复的字段；快捷指令存在（quick_commands）但与 persona 无关。
- **prefill**：`agent.prefill_messages_file` 独立于 persona，预先填充 few-shot，不持久化（cli.py:4493-4495）。

## 7. 导入、导出、迁移与兼容性

- **从其他代理导入**：`hermes import-agent`（`agent_import.py` 文档）导入 Claude Code（`~/.claude`）与 Codex CLI（`~/.codex`）：
  - CLAUDE.md / AGENTS.md / memories/*.md → `memories/MEMORY.md`（去重、20,000 字符上限）
  - permissions.allowBash → config `command_allowlist`；denyBash → `approvals.deny`（`claude_rule_to_command_pattern`，332-351）
  - mcpServers → `config.yaml mcp_servers`（env secret 名剥离）
  - skills → `skills/claude-code-imports/`、`skills/codex-imports/`
  - **不导入凭据**（`auth.json`/`.credentials.json` 忽略、secret 名 env 剥离报告）。
  - 人类协议中提示语模板与**persona 系统不迁移**（本模块不写 `agent.personalities`/`system_prompt`）。
- **备份/恢复**：`hermes backup` → `~/.hermes/backups/*.zip` → `hermes import` 恢复（`hermes_cli/backup.py`，含 SOUL.md/config/MEMORY/skills/会话）。
- **Profile 迁移**：`hermes profile export <name> -o`（`profiles.py:1925`）本地/跨机恢复；`profile install/update`（`profile_distribution.py`）：manifest `distribution.yaml`，distribution-owned 默认 `SOUL.md`/`config.yaml`/`mcp.json`/`skills`/`cron`，用户数据（memories/sessions/logs/auth.json/.env/state.db...）绝不覆盖（`USER_OWNED_EXCLUDE`，101-120）。
- **OpenClaw 迁移**：`hermes claw migrate` 迁移整个 home（SOUL.md/MEMORY.md/USER.md/skills）。
- **兼容性分层结论**：对 CLAUDE.md/AGENTS.md/memories——能解析、能保留内容、运行时生效于记忆/上下文是贯彻到底；permissions→command 白名单与 skills 是一对一映射；但 **persona/system_prompt 字段没有导入承载**，“导入后没有 personality 模板”是已确认事实。

## 8. 配置 UI 与运行时可见性

- **CLI**：`/personality` 列出/设置；`/status` 显示 Model + Provider 与 `active_personality_name`（`config.py:4397-4402`），不显示人格文本。
- **TUI/桌面**：`config.set`/`config.get` 读写 `personality`（`methods_config.py:211-218`——**经 `active_personality_name` 回报生效值**、`server.py:11500-11534`）；`session.info` 返回 personality（`server.py:5192-5247`）；`/personality` picker（commands.py 的 picker 命令，补全经 `hermes_cli.personality`，`commands.py:2024-2050`）；`_probe_config_health` 警告“`display.personality` 与任何内置/`agent.personalities` 条目不匹配，人格 overlay 将被跳过”（server.py:5084-5111）。
- **Web/桌面**：`web/src/lib/api.ts:723-727` 提供 `/profiles/<name>/soul`；desktop 用 `personalityNamesFromConfig` 计算可用人格（`apps/desktop/src/lib/chat-runtime.ts:241`；桌面侧渲染在 `lib/personalities.ts`）；`apps/desktop/src/types/hermes.ts` 有 `personality?` 字段。
- **历史快照语义**：会话把**构建好的 system prompt** 存进 `system_prompts` 去重表（`hermes_state.py`），session 行保存当时 `model/model_config`。**人格当前值（ephemeral）不进轨迹**。所以“历史回放时的角色”只能反映当时的 system cached 部分，不含会话后新设置的人格字符串。

### 8.1 重试、缓存键与 stale 判定

- **session 记录 schema**：`hermes_state_common.py:207-263` 的 `CREATE TABLE sessions` 角色相关列——`system_prompt`（全文）+ `system_prompt_hash`（FK → `system_prompts(hash,prompt)`，:202-205）、`model`、`model_config`（TEXT 快照）、`parent_session_id`、`cwd/git_branch/git_repo_root/profile_name` 及 token/成本/标题等计费列。即完整 system prompt 文本入库存档，人格"当前值"（ephemeral）不入库。
- **缓存键**：内存键是 `agent._cached_system_prompt` 字符串本身；DB 去重键 = 全文 sha256（`hermes_state.py:90-91` `_system_prompt_hash`，:1976-1984 `_store_system_prompt` INSERT OR IGNORE），孤儿行由 `_delete_unreferenced_system_prompts` 回收。
- **CLI retry_last**（cli.py:8714 起）：截断内存 history 后重发同一 user 消息，**agent 实例不变** → 直接复用 `_cached_system_prompt`（agent_init.py），不重建。Gateway `_handle_retry_command`（gateway/slash_commands.py）重写 transcript 后走正常消息处理；每轮新建 AIAgent 时 `_restore_or_build_system_prompt`（conversation_loop.py:555 起）从 DB 读出当时存储的 prompt，`_stored_prompt_matches_runtime`（:693 起）通过则原样复用（含 `reconstruct_static_prefix` 恢复缓存断点布局），不重新构建。
- **修改人格文本不判 stale**：`_stored_prompt_matches_runtime` 只比对 prompt 尾部 `Model:`/`Provider:` 行——改人格文本不会使存储 prompt 判为 stale；CLI `/personality` 走 `self.agent = None` 强制重建（cli_commands_mixin.py:1385 附近），TUI 只改 `ephemeral_system_prompt`（tui_gateway/server.py:6040）不碰缓存；重建后由 conversation_loop 的 `update_system_prompt` 刷新库中全文与 hash。
- **提示词组与编辑器密度**：四层之外无"组"级抽象——`agent.personalities` 是扁平 dict，消费点均按名整体单选（cli.py:4490、cli_commands_mixin.py:1329-1357、gateway/slash_commands.py:2492-2560、tui_gateway/server.py:5811-5843），无多选组合、单选组互斥、组级总开关或逐条开关；`agent/system_prompt.py:152-587` 只按固定顺序拼 stable/context/volatile 三块。人格无专用编辑器（CLI/TUI 是列表选择器，桌面端只是设置页下拉 `display.personality`），无拖拽/批量；导入导出仅 profile 级（见第 7 节）。

## 9. 设计取舍与已确认边界

1. **提示缓存第一**：system prompt 一次构建、字节稳定，只有压缩时重建（AGENTS.md 的 “prompt caching is sacred” 约束）。这使“角色编写”能不破坏缓存，但代价是**角色修改只在下一次重建/新建会话生效**；CLI 用 `self.agent = None` 显式触发，TUI 用 `ephemeral_system_prompt` 就地替换实现会话内即时生效。
2. **人格即文本叠加，不是对象**：没有角色版本、头像、开场白等承载字段；横向比较时应把 Hermes 归为“配置聚合/全局语义”，不是“角色卡实体”。
3. **Profile 隔离是有意的**：profile 之间不继承（`--clone` 是唯一的“从默认开始”手段），与“profiles are independent islands”设计一致（AGENTS.md）。
4. **ephemeral 不入轨迹** 是双刃：人格不会污染历史，但也意味着轨迹/审计记录无法精确重放当时人格文本。
5. **配置 UI 字段不一定在请求链路生效**：`custom_prompt`（TUI `config.set prompt`）有 UI 与存储（`server.py:11135-11145`、`methods_config.py:194`），但本次检索仅发现读写，**没有读取它的请求路径**——典型的“界面存在、链路未消费”案例。
6. **SOUL 与项目规则分离**：身份（HERMES_HOME）与项目 AGENTS/CLAUDE/.cursorrules（cwd）独立、优先级明确，不会互相覆盖。
7. **多段固定指引文本均为稳定文本**：稳定 system prompt 是对缓存友好的设计选择；压缩重建时只会重新渲染一次，不影响前缀缓存。

## 10. 未验证事项

- `custom_prompt` 是否有真实消费者：仅发现 config 读写，未经运行验证；不能证明完全无效应，只能说本快照主请求链路未依赖。
- TUI/桌面 人格 picker 的视觉、键盘可及性与运行行为（静态只见入口事件绑定）。
- `HERMES_EPHEMERAL_SYSTEM_PROMPT` 在 gateway 的具体生效路径（`gateway/run.py` 有读取，本次未实测）。
- gateway `/personality` 与 `channel_overrides.system_prompt` 的优先互动只推断到代码层，未运行验证。
- 长会话在压缩重建时人格文本是否完整重放（静态推得 `invalidate_system_prompt` 会重载并重建，未实测）。
- `profile install` 完整安装/更新流程与故障路径（大量文件操作）基于代码导览，未运行。

## 11. 关键源码索引

- `agent/system_prompt.py`：三块组装 `build_system_prompt_parts`（152-558）、`build_system_prompt`（569）、ephemeral 不拼接与 static 前缀（483-488, 610-656）。
- `agent/prompt_builder.py`：`load_soul_md`（2082）、`DEFAULT_AGENT_IDENTITY`（144）、`build_context_files_prompt`（2273，优先级 .hermes.md>AGENTS.md[目录链]>CLAUDE.md>.cursorrules）、`_agents_md_directory_chain`（2139）。
- `hermes_cli/personality.py`：人格状态单一所有者（`BUILTIN_PERSONALITIES` 60-79、`render_personality_prompt` 82、`normalize_personality_name` 104、`resolve_personality` 122、`active_personality_name` 142、`persist_personality`）；`hermes_cli/config.py`（840-914 `_ensure_default_soul_md`、`resolve_ephemeral_system_prompt_from_config` 2957 附近）。
- `cli.py`：`/personality` 分发与 `retry_last`（8714）；`hermes_cli/cli_commands_mixin.py:1336-1410`：`/personality` 处理器（resolve_personality + persist_personality）。
- `gateway/slash_commands.py:2494`：gateway `/personality`。
- `gateway/config.py:543-574`：`ChannelOverride`（model/provider/system_prompt）。
- `hermes_cli/model_switch.py:760`：`resolve_effective_model`。
- `tui_gateway/server.py`：`session.info`（5192-5247）、人格逻辑（5992-6090）、健康检查（5084-5111）、`config.set`（11500-11534）；`tui_gateway/methods_config.py:211-218`。
- `ui-tui/app/slash/commands/session.ts:191-216`：TUI `/personality` RPC。
- `hermes_cli/cli_agent_setup_mixin.py`：`ephemeral_system_prompt` 传入。
- `agent/chat_completion_helpers.py:2394-2395`、`agent/conversation_loop.py:1172-1173`：ephemeral 生效于主请求。
- `agent/transports/chat_transport.py:599-664`：temperature/max_tokens 解析；`agent/anthropic_adapter.py`、`agent/auxiliary_client.py`。
- `run_agent.py`：`_build_system_prompt_parts` 转发。
- `hermes_state.py`：`_insert_session_row`（3685）、`system_prompts` 去重表与回收（2506-2517）、`_system_prompt_hash`（165）。
- `hermes_cli/profiles.py`：`create_profile`、`export_profile`；`hermes_cli/profile_distribution.py`：manifest owned/excluded 列表（40-120）。
- `hermes_cli/agent_import.py`：`AgentImporter`、`import_agent_command`、mapping 文档。
- `hermes_cli/backup.py`：`hermes backup`/`import` 恢复；`hermes_cli/doctor.py`：SOUL.md 体检；`hermes_cli/web_routers/profiles.py`：SOUL.md REST；`hermes_cli/config.py`：`_expand_env_vars` 变量展开。