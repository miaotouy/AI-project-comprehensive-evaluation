# Hermes-Agent Agent 角色配置调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（Hermes Agent）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：静态代码阅读 + 全仓符号检索；按 `git log`/`git diff` 对提交范围做增量核对，受影响结论在 HEAD 处源码重新确认并修正行号；工作树干净，未运行程序
>
> 调查范围：角色/人格/persona/SOUL/身份/系统提示词的实体、存储、选择、拼装、参数绑定、外部能力、资产变量、导入导出与运行时可见性；TTS 专属 persona 与第三方 runner 不在范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent **没有独立持久化的“角色对象”**。它的“角色”是多个互补的提示词机制，按“身份 → 命名模板 → 全局/会话覆盖 → 运行时注入”分层叠加：

1. **身份层（SOUL.md）**：首次运行时，`$HERMES_HOME/SOUL.md` 由内置模板写入，成为代理的主身份文件并进入 system prompt 的稳定层；文件缺失时改用硬编码的默认身份文本（`hermes_cli/config.py:840-914`；`agent/prompt_builder.py:144`）。
2. **人格模板（personalities）**：`agent.personalities` 是一组具名模板，值可以是纯字符串，也可以是“提示词 + 语气 + 风格”的映射。内置 14 个模板与用户条目由同一个模块 `hermes_cli/personality.py` 统一持有，用户条目按名称覆盖同名内置项，模板定义最初由 `cli.py` 的默认值迁入。该模块还接受顶层 `personalities:` 块（最初 #643 的形状），同名冲突时以 `agent.personalities` 为准；空串、none、default、neutral 四个取值统一按“无人格 overlay”处理。
3. **全局/会话 system prompt**：
   - `display.personality` 只保存选中的名称，空值表示不叠加人格，全表面以它为准。启动或新建 agent 时按“env 覆盖 → 命名人格 → 用户手动提示”的顺序取文本：`HERMES_EPHEMERAL_SYSTEM_PROMPT` 优先级最高，命名人格渲染失败则回退到用户自有的 `agent.system_prompt`；取到的文本作为 agent 的 ephemeral 提示，在主请求路径上追加到缓存 prompt 之后，不写入轨迹。
   - 人格代码始终不写 `agent.system_prompt`，该字段留给用户手动提示；v33→v34 迁移一次性清理旧 `/personality` 写入的文本并重置选择（`config_migrations.py:648-717`）。
4. **会话/渠道覆盖**：渠道级覆盖由 `ChannelOverride` 承担，含模型、提供商与提示词三个字段，TUI 会话另可存一个 `personality` 覆盖键（`gateway/config.py:543-574`）。
5. **角色隔离由 Profile 承担**：`hermes profile create --clone` 会复制 config.yaml、.env、SOUL.md 与 skills 目录，得到一套自带模型、记忆、技能与提示词的独立环境。

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

渠道（gateway）差异：渠道级提示来自渠道覆盖的提示词字段，缺省回退全局 `agent.system_prompt`；模型优先级由 `resolve_effective_model` 按“会话 > 渠道 > 全局”解析（`hermes_cli/model_switch.py:760`）。

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

- **SOUL.md 种子与升级**：首轮运行写入默认模板；现有内容若与旧版空模板逐字节一致，会被自动升级成新模板，用户改过的内容保持原样。创建 profile 时同样会播种，`hermes doctor` 另外检查该文件是否存在、内容是否为空（模板定义在 `hermes_cli/default_soul.py`，播种与升级逻辑见 `hermes_cli/config.py:840-914`，创建与体检入口见文末源码索引）。
- **内置 14 个人格字符串模板**：完整名单见下（由 `cli.py:481-496` 迁入，集中定义于 `hermes_cli/personality.py` 的 `BUILTIN_PERSONALITIES`，`personality.py:60-79`）：

  ```text
  helpful / concise / technical / creative / teacher / kawaii / catgirl / pirate / shakespeare / surfer / noir / uwu / philosopher / hype
  ```

- **dict 形式模板**：纯字符串值原样使用。映射值可同时给出三个字段，分别是提示词 `system_prompt`、语气 `tone` 与风格 `style`；示例配置见 `cli-config.yaml.example` 的 `agent.personalities` 段。
- **dict 值渲染**：渲染由 `render_personality_prompt` 完成，纯字符串原样返回，映射则把提示词与 `Tone:`、`Style:` 两行依次拼成一段文本；`hermes_cli/config.py:2947` 处只是转发调用，主体实现在 `hermes_cli/personality.py:82`。
- **名称规范化**：`normalize_personality_name` 把 none、default、neutral 与空串一律视为未选择（`hermes_cli/personality.py:104`）。
- **配置读取与 env**：环境变量 `HERMES_EPHEMERAL_SYSTEM_PROMPT` 优先级最高；没有它时走常规解析入口 `resolve_ephemeral_system_prompt_from_config`，其中命名人格优先于用户手动提示 `agent.system_prompt`。
- **整体失效开关**：设置 `HERMES_IGNORE_RULES` 或加 `--ignore-rules` 会让 SOUL、项目规则与记忆一起失效。
- **记忆相关文件**：`memory.memory_enabled` 控制 `MEMORY.md`（agent 长期记忆）是否启用，`memory.user_profile_enabled` 控制 `USER.md`（用户画像）是否启用，示例见 `cli-config.yaml.example`。
- **删除**：这套机制里没有可删除的角色对象；删掉 `display.personality` 或 `agent.system_prompt` 配置、把 personality 设为 `none` 或空串、或者删除整个 profile 目录，效果都等同于删除角色。

## 2. 创建、选择与会话绑定

- **创建**：
  - SOUL.md 在首轮运行或执行 `hermes profile create` 时自动播种，也可以直接编辑 `$HERMES_HOME/SOUL.md`；Web 端另有 REST 接口可以读取、写入或删除该文件（`hermes_cli/web_routers/profiles.py:600-640`）。
  - personalities 没有专门的创建命令，直接编辑 config.yaml 即可（本次未发现其他入口）。
  - Profile 由 `hermes profile create <name>` 创建，加 `--clone` 或 `--clone-all` 可复制现有环境（`hermes_cli/profiles.py:998-1090`）。
- **选择**：
  - CLI 用 `/personality <name>` 设定；输入 none 等中立名或空串则清除选择（`hermes_cli/cli_commands_mixin.py:1329-1357`）。
  - Gateway 的 `/personality` 同时负责列出与设置（`gateway/slash_commands.py:2492-2560`）。
  - TUI 与桌面端的 `/personality` 打开选择器，选中结果通过 RPC 写入 personality 配置键（`ui-tui/app/slash/commands/session.ts:191-216`）。
  - 选 profile 用 `hermes -p <name>`；gateway 按名称路由到最具体的渠道或线程作用域（`gateway/profile_routing.py:1-38`）。
- **会话绑定**：
  - CLI 会话启动时只取一次提示文本（来自环境变量或统一解析函数），持久化后供下次启动读取；TUI 还能用会话级 personality 覆盖键改写这一层（`tui_gateway/server.py:5192-5193`）。
  - TUI 改人格对既有会话就地生效：更新临时提示文本，需要时插入 `[System: ...]` 提示并写入 `personality_switch` 时间线条目，历史消息保持不动；选择本身另行落盘到 `display.personality`（`tui_gateway/server.py:6040-6090`，落库入口见文末源码索引）。
  - CLI 的路径不同：把 agent 实例置空，强制下一条消息重建后生效。
  - 渠道覆盖只作用于该渠道，profile 覆盖作用于整个 profile。
- **会话记录**：`run_agent.py` 建会话时把完整 system prompt 连同模型与模型配置快照写进会话行；CLI 自己建会话时不传提示词，只传 `max_iterations` 与 `reasoning_config` 两项模型配置。

**覆盖优先级（综合）**：
- 模型：会话内的 `/model` 切换高于渠道 override，渠道 override 又高于全局 `model:` 配置。
- 提示：三块拼装完成后，ephemeral 段追加在缓存之后，始终不覆盖前面的内容。人格文本按“`display.personality` 记录的选择名 → 运行时渲染 → ephemeral 覆盖层”三级取得，解析入口在 `hermes_cli/config.py:2957` 附近，实际生效的名称以 `hermes_cli/personality.py:142` 为准。人格代码同样不写 `agent.system_prompt`。

## 3. 提示词字段与最终拼装顺序

`agent/system_prompt.py` 的 `build_system_prompt_parts`（152-558）返回三块，`build_system_prompt`（561-587）用双换行连接并缓存：

- **stable**（跨会话稳定，字节固定以保住前缀缓存）：按固定顺序拼装九部分，实现集中在 `build_system_prompt_parts`（`agent/system_prompt.py:152-558`）。
  1. 身份：SOUL.md，缺失时回退到硬编码的默认身份文本。
  2. 通用指引：帮助指引、任务完成指引（工具可用且未禁用时才加）与并行工具调用指引。
  3. 工具专用指引，只在该工具已加载时注入，覆盖 memory、session_search、skill_manage 与 steer note 四类。
  4. computer-use 指引与 nous 订阅。
  5. 工具使用强制条款，按模型名匹配并附各模型的操作指引。
  6. 技能索引相关提示，以及 alibaba 模型名的兜底分支。
  7. 环境提示与环境探测。
  8. active-profile 提示。
  9. 平台提示，由内置平台表与 config 的 `platform_hints` 覆盖合成。
- **context**（随 cwd 变化）：先放编码时生成的 workspace 快照，再接调用方传入的 system_message，最后由项目上下文汇总函数合成一段；项目上下文的发现、优先级判定与目录链合并都在 `agent/prompt_builder.py:2139-2327` 内。
  - 项目上下文按优先级只取一种，顺序如下：
    1. `.hermes.md` 或 `HERMES.md`
    2. `AGENTS.md`
    3. `CLAUDE.md`
    4. `.cursorrules`
  - `AGENTS.md` 的处理是例外，走目录链合并：从 git 根到 cwd 逐目录各取首个 `AGENTS.md` 或 `agents.md`，带 provenance 标签合并成段，链上重复内容跳过；这套机制来自 grok-cli。
  - SOUL.md 独立成段且总是包含，已作为身份载入时由 `skip_soul` 拦住，避免重复加载。
  - cwd 落在 Hermes 安装树内时跳过项目上下文发现。
- **volatile**（最易变，放在最后）：技能索引（稳定前缀里用不到）→ agent 记忆 MEMORY.md → 用户画像 USER.md → 外部记忆 Provider 追加的 `build_system_prompt()` → 日期行；日期只精确到天，保证全天字节稳定（`agent/system_prompt.py:543-552`）。

细节：
- `ephemeral_system_prompt` 不进这三块，只由请求组包与对话循环在 API 调用时用空行拼在末尾（`agent/system_prompt.py:475-478` 的注释已写明）。
- `skip_soul` 保证 SOUL 只加载一次，身份槽位与项目上下文槽位不会重复放入。
- 重建 static 前缀时沿用 `[stable, volatile]` 两段缓存布局（`reconstruct_static_prefix`，`agent/system_prompt.py:602-654`）。

## 4. 模型、Provider 与生成参数

- 人格与身份文件不绑定模型、Provider 或采样参数，绑定发生在全局 `model:` 配置、会话 `/model` 切换、渠道覆盖、独立 config.yaml 的 Profile 与 `auxiliary.*` 任务级覆盖（渠道覆盖的实现见 `gateway/config.py:543-574`）。
- **采样参数进包**：请求组包时从 profile 解析 temperature 与 max_tokens。temperature 先取 profile 的固定值，取到表示省略的标记时不下发，其次用调用方传入的参数；max_tokens 按“ephemeral > 用户 > profile 默认”的优先级取值（`agent/transports/chat_transport.py:599-664`）。
- **Provider 差异**：Anthropic 对思维模型强制 temperature=1，对 Opus 4.7 一类模型剔除与默认值不同的 temperature、top_p、top_k；Kimi/Moonshot 是否省略 temperature 由辅助客户端判断（`agent/anthropic_adapter.py:3012-3022`；`agent/auxiliary_client.py:640-656`）。
- 上下文窗口限额来自模型目录里的默认长度表，显式配置的 `context_file_max_chars` 可以覆盖它。
- 切换模型只替换请求中的 model 与 provider，system prompt 内容保持原样；会话行照旧保存当时的 model 与 model_config 快照。

## 5. 工具、知识、记忆与子 Agent

- 人格与提示词本身不授予工具权限，授权由平台级配置 `tools.<platform>.enabled/disabled` 决定，管理命令是 `hermes tools`，实现在 `hermes_cli/tools_config.py`。授权结果反过来影响提示词：只有加载了 memory 工具，系统提示里才出现对应的使用指引（`agent/system_prompt.py:228-245`）。
- **Skills**：技能索引只在 skills 工具存在时生成，放进易变段。技能文件存放在 `~/.hermes/skills/`，技能命令以用户消息注入，已经构建好的缓存前缀保持不变。
- **记忆**：agent 长期记忆 `MEMORY.md` 与用户画像 `USER.md` 都放在易变段。后者文件位于 `~/.hermes/memories/USER.md`，启停由独立开关 `memory.user_profile_enabled` 控制（`agent/system_prompt.py:515-524`）。
- **外部记忆 Provider**：这是可选插件，同一时刻最多启用一个，由 `memory.provider` 选定。插件放在 `plugins/memory/<name>`，经记忆管理器 `agent/memory_manager.py` 编排后往易变段追加内容，追加接口是插件自己的 `build_system_prompt()`（追加点见 `agent/system_prompt.py:527-533`）。
- **子 Agent**：`delegate_task` 派生的子 agent 默认继承 `ephemeral_system_prompt`，角色提示随委派上下文一起传入（`agent/background_review.py:753-754`）。

## 6. 资产、变量、开场白与用户画像

- **用户画像**：USER.md 里的 persona 描述在构建提示时由 `format_for_system_prompt("user")` 渲染，进入易变段（`agent/system_prompt.py:521-524`）。
- **变量/占位符**：config.yaml 支持 `${VAR}` 与 `${env:VAR}` 两种写法的递归展开，展开发生在配置加载阶段，解析不到的值原样保留。这是全配置通用的机制，不专属于角色字段（`hermes_cli/config.py:2546-2560` 的 `_expand_env_vars`）。
- **头像/开场白/快捷回复**：人格没有绑定头像、开场白或快捷回复的字段（本次范围内未找到）；快捷指令 quick_commands 属于另一套机制，与 persona 无关。
- **prefill**：`agent.prefill_messages_file` 与 persona 相互独立，用于预先填充 few-shot 消息，内容不持久化（`cli.py:4493-4495`）。

## 7. 导入、导出、迁移与兼容性

- **从其他代理导入**：`hermes import-agent` 读取 Claude Code 与 Codex CLI 的既有配置并转成 Hermes 结构，来源目录分别是 `~/.claude` 与 `~/.codex`。命令本体与来源清单由 `agent-importers` 插件提供，旧拼写 `claw` 仍可调用。各类资产的处理方式如下：

  | 源资产 | 落点 | 处理规则 |
  | --- | --- | --- |
  | CLAUDE.md、AGENTS.md、memories/*.md | `memories/MEMORY.md` | 去重，总量上限 20,000 字符 |
  | permissions 的 allowBash 与 denyBash | config 的 `command_allowlist` 与 `approvals.deny` | 把规则翻译成命令模式（`claude_rule_to_command_pattern`，332-351） |
  | mcpServers | config.yaml 的 `mcp_servers` | 剥离 env secret 名 |
  | skills | `skills/claude-code-imports/`、`skills/codex-imports/` | 按来源分目录存放 |

  凭据不参与导入：`auth.json` 与 `.credentials.json` 直接忽略，被剥离的 secret 名会出现在报告里。人类协议里的提示语模板与 persona 系统不在迁移范围，导入器不写 `agent.personalities` 与 `system_prompt`。
- **备份/恢复**：`hermes backup` 把 home 打包成 `~/.hermes/backups/*.zip`，再由 `hermes import` 恢复，范围覆盖 SOUL.md、config、MEMORY、skills 与会话（`hermes_cli/backup.py`）。
- **Profile 迁移**：导出用 `hermes profile export <name> -o`；本地或跨机恢复用 `profile install` 与 `profile update`。发行包清单是 distribution.yaml，分发逻辑在 `hermes_cli/profile_distribution.py`，导出入口是 `hermes_cli/profiles.py:1925`。恢复时按两类清单处理：
  - 发行方管理、可被更新覆盖：SOUL.md、config.yaml、mcp.json、skills、cron。
  - 用户数据从不覆盖：memories、sessions、logs、auth.json、.env、state.db 等，清单由 `USER_OWNED_EXCLUDE` 维护（101-120）。
- **OpenClaw 迁移**：`hermes claw migrate` 迁移整个 home 目录，包括 SOUL.md、MEMORY.md、USER.md 与 skills。
- **兼容性分层结论**：CLAUDE.md、AGENTS.md 与 memories 能被解析、内容被保留，运行时作用于记忆与上下文；权限规则到命令白名单、skills 到技能目录都是一对一映射。persona 与 system_prompt 字段没有对应的导入承载，导入完成后不会产生 personality 模板，这一点已确认。

## 8. 配置 UI 与运行时可见性

- **CLI**：`/personality` 负责列出与设置人格；`/status` 显示当前 Model、Provider 与生效的人格名称，不显示人格文本（`hermes_cli/config.py:4397-4402`）。
- **TUI/桌面**：配置读写接口直接操作 personality 键，回报时经 `active_personality_name` 换算出生效值（`tui_gateway/methods_config.py:211-218`）。会话信息接口返回当前人格，`/personality` 打开选择器；健康检查会比较所选人格与内置、用户条目，对不上时警告该人格覆盖层将被跳过。其余入口行号见文末源码索引。
- **Web/桌面**：Web 端为 SOUL.md 提供了一组 REST 接口，路径是 `/profiles/<name>/soul`；桌面端用 `personalityNamesFromConfig` 汇总可用人格名单，类型定义里 personality 是可选字段（`web/src/lib/api.ts:723-727`；`apps/desktop/src/lib/chat-runtime.ts:241`）。
- **历史快照语义**：建会话时把构建好的 system prompt 文本存进 `system_prompts` 去重表，会话行另存当时的模型与模型配置。人格当前值只存在于 ephemeral 段，不进轨迹。因此回放历史时看到的角色只覆盖当时缓存的提示文本，会话之后新设的人格字符串不在其中（`hermes_state.py`）。

### 8.1 重试、缓存键与 stale 判定

- **session 记录 schema**：sessions 表里与角色相关的列分三类，建表语句在 `hermes_state_common.py:207-263`：

  | 用途 | 列 | 说明 |
  | --- | --- | --- |
  | 提示文本 | `system_prompt`、`system_prompt_hash` | 前者存全文，后者是外键，指向 `system_prompts(hash, prompt)`（`hermes_state_common.py:202-205`） |
  | 模型快照 | `model`、`model_config` | 均为 TEXT 快照 |
  | 会话上下文 | `parent_session_id`、`cwd`、`git_branch`、`git_repo_root`、`profile_name` | 另有 token、成本、标题等计费列 |

  完整 system prompt 文本随会话入库存档，人格的运行时当前值只留在内存，不写库。
- **缓存键**：内存里的键就是 agent 上缓存的那段提示字符串本身；数据库按全文 sha256 去重，写入用 INSERT OR IGNORE，失去引用的孤儿行会被回收（`hermes_state.py`：哈希函数在 90-91 行，写入与回收在 1976-1984 行）。
- **CLI retry_last**：截断内存 history 后重发同一条用户消息，agent 实例保持不变，直接复用缓存提示，不重建（`cli.py:8714` 起，缓存取值见 `agent/agent_init.py`）。
- **Gateway 重试**：重试处理器（`gateway/slash_commands.py`）重写 transcript 后交回正常消息处理。每轮新建 agent 时，恢复函数先从库里读出当时存下的提示，校验函数比对通过就原样复用，连缓存断点布局一并恢复，跳过重建（`agent/conversation_loop.py:555` 起，校验在 693 行起）。
- **人格文本改动与 stale 判定**：过期判定只比对提示末尾的 `Model:` 与 `Provider:` 两行，改动人格文本不会让库里的提示被判过期。CLI 侧的 `/personality` 会强制重建，TUI 侧只替换 ephemeral 提示、缓存不动；重建完成后刷新库中的提示全文与哈希（`hermes_cli/cli_commands_mixin.py:1385` 附近；`tui_gateway/server.py:6040`）。
- **提示词组与编辑器密度**：四层之外没有"组"一级的抽象。`agent.personalities` 是扁平字典，CLI、Gateway、TUI 各消费点都按名称整体单选，不支持多选组合、互斥单选组、组级总开关或逐条开关；拼装侧只按固定顺序生成 stable、context、volatile 三块（`agent/system_prompt.py:152-587`）。人格也没有专用编辑器，CLI 与 TUI 只提供列表选择器，桌面端是设置页下拉 `display.personality`，没有拖拽与批量操作；导入导出只到 profile 一级（见第 7 节）。

## 9. 设计取舍与已确认边界

1. **提示缓存第一**：system prompt 一次构建、字节稳定，只在上下文压缩时重建，这是 AGENTS.md 中 “prompt caching is sacred” 约束的体现。角色编写因此不会打断缓存，代价是角色修改要等到下一次重建或新建会话才生效：CLI 把 agent 实例显式置空来触发，TUI 则就地替换 ephemeral 提示，实现会话内即时生效。
2. **人格以文本叠加实现**：角色没有版本、头像、开场白等承载字段；横向比较时把 Hermes 归入“配置聚合/全局语义”，与“角色卡实体”区分开。
3. **Profile 隔离是有意的**：profile 之间不继承，`--clone` 是唯一的“从默认开始”手段，与 AGENTS.md 里“profiles are independent islands”的设计一致。
4. **ephemeral 不进轨迹**：这一取舍让人格不污染历史，代价是轨迹与审计记录无法精确重放当时的人格文本。
5. **配置 UI 字段不一定在请求链路生效**：`custom_prompt` 在 TUI 的设置入口既能写也有存储，但本次检索只找到读写它的代码，没有找到读取它的请求路径，属于“界面存在、链路未消费”（`tui_gateway/server.py:11135-11145`，`tui_gateway/methods_config.py:194`）。
6. **SOUL 与项目规则分离**：身份文件放在 HERMES_HOME 下，项目规则来自 cwd 下的 AGENTS.md、CLAUDE.md 与 .cursorrules，两组来源独立、优先级明确，互不覆盖。
7. **多段固定指引文本均为稳定文本**：把固定指引放进稳定 system prompt 是对缓存友好的设计选择，压缩重建时只会重新渲染一次，前缀缓存不受影响。
8. **当前角色边界**：这个快照里角色仍由提示词与运行时覆盖组合而成，没有独立持久化的角色实体，插件、profile 与模型目录各自充当配置来源。Provider 的推理强度映射与模型目录改动会影响角色解析之后的实际请求参数，其影响落在请求参数层；是否存在新的角色配置层需要另行核对。

## 10. 未验证事项

- `custom_prompt` 是否有真实消费者：仅发现 config 读写，未经运行验证；不能证明完全无效应，只能说本快照主请求链路未依赖。
- TUI/桌面 人格 picker 的视觉、键盘可及性与运行行为（静态只见入口事件绑定）。
- `HERMES_EPHEMERAL_SYSTEM_PROMPT` 在 gateway 的具体生效路径（`gateway/run.py` 有读取，本次未实测）。
- gateway `/personality` 与 `channel_overrides.system_prompt` 的优先互动只推断到代码层，未运行验证。
- 长会话在压缩重建时人格文本是否完整重放（静态推得 `invalidate_system_prompt` 会重载并重建，未实测）。
- `profile install` 完整安装/更新流程与故障路径（大量文件操作）基于代码导览，未运行。
- 人格模块、SOUL/提示词组装与导入命令的关键位置以模块级定位给出；未逐行重读 26k 提交范围内的全部改动。

## 11. 关键源码索引

- `agent/system_prompt.py`：三块组装 `build_system_prompt_parts`（152-558）、`build_system_prompt`（569）、ephemeral 不拼接与 static 前缀（483-488, 610-656）。
- `agent/prompt_builder.py`：`load_soul_md`、`DEFAULT_AGENT_IDENTITY`、`build_context_files_prompt`（优先级 .hermes.md>AGENTS.md[目录链]>CLAUDE.md>.cursorrules）、`_agents_md_directory_chain`。
- `hermes_cli/personality.py`：人格状态单一所有者（`BUILTIN_PERSONALITIES`、`render_personality_prompt`、`normalize_personality_name`、`resolve_personality`、`active_personality_name`、`persist_personality`、`NEUTRAL_PERSONALITY_NAMES`）；`hermes_cli/config.py`（`_ensure_default_soul_md`、`resolve_ephemeral_system_prompt_from_config`）。
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
- `hermes_cli/setup_agent_import.py`、`hermes_cli/foreign_sessions.py`：会话发现与静态历史导入；`hermes import-agent` 命令本体与来源清单由 `agent-importers` 插件提供（`hermes_cli/left_core_migration.py` 的迁移表把旧 `claw` 指向它）。
- `hermes_cli/backup.py`：`hermes backup`/`import` 恢复；`hermes_cli/doctor.py`：SOUL.md 体检；`hermes_cli/web_routers/profiles.py`：SOUL.md REST；`hermes_cli/config.py`：`_expand_env_vars` 变量展开。
