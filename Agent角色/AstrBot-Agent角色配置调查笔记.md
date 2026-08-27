# AstrBot Agent 角色配置调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`8ea8ce613a0bee4ddb48b21490afe23418277c75`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：Persona 数据模型与存储、解析优先级、system prompt 注入、工具/Skills 能力白名单、第三方 runner 差异、自定义错误回复、UI 层、与上下文压缩的交互
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的"Agent 角色"（Persona）是**纯指令 + 能力白名单**模型：一个 persona 由 `system_prompt` 文本、`begin_dialogs` 预设开场对话、工具与 Skills 白名单以及自定义错误文案组成。没有头像、语音、名字等富媒体字段（与"角色卡"类客户端差异明显）。运行时由 `_ensure_persona_and_skills`（astr_main_agent.py:499-664）负责，在每轮请求构造时把 persona 解析结果注入 ProviderRequest。

关键事实（快照 346b85d）：

- **存储**：v4 起存 SQLite `personas` 表（po.py:145-178，SQLModel），`persona_id` 即显示名（字符串，非 UUID）；v3 的 config.json `persona` 键已废弃，由迁移脚本改写（migra_3_to_4.py:236-276）。
- **运行时是 v3 兼容层**：`PersonaManager.get_v3_persona_data`（persona_mgr.py:353-432）把 DB 行转成 `Personality` TypedDict 缓存，每次 CRUD 后重建；主 Agent 消费的是 `personas_v3`，不是 DB 模型。
- **解析优先级**（`resolve_selected_persona`，persona_mgr.py:75-127）：会话规则强制 `session_service_config.persona_id` → 对话级 persona_id → `provider_settings.default_personality` → webchat 特例 `_chatui_default_`；`"[%None]"` 哨兵显式禁用。
- **注入位置**：persona prompt 追加到请求的 system_prompt（astr_main_agent.py:533-534）；预设对话以不保存标记插到上下文最前（:535-536），每轮重注入、不入库。
- **三态语义**：`tools`/`skills` 三态——None=全部、[]=禁用全部、列表=白名单；workspace Skills 不受 persona 过滤。
- **第三方 runner 不注入 persona**：Dify/Coze/Dashscope/DeerFlow 等只解析自定义错误文案，persona 对内置 Agent 执行器专属。
- **system 消息受压缩保护**：persona 永不被截断器丢弃（truncator.py:15-29 的 `_split_system_rest`），但计入 token 统计（token_counter.py:46-73），超长会推高总量、更早触发历史压缩。
- **内置角色两个**：内存 `DEFAULT_PERSONALITY`（persona_mgr.py:9-19）与 webchat 专用 `CHATUI_SPECIAL_DEFAULT_PERSONA_PROMPT`（astr_main_agent_resources.py:44-59）。

## 总体调用链

```text
每轮用户消息 → astr_main_agent.build_main_agent (astr_main_agent.py:1375-1713)
  → _decorate_llm_request (:991-1039)   [注：实际顺序见 _ensure_persona_and_skills 在各分支的调用点]
  → _ensure_persona_and_skills (:499-664)
      resolve_selected_persona (persona_mgr.py:75-127)   → persona_id / Personality / 强制ID / webchat特例
      persona prompt → req.system_prompt（# Persona Instructions 节）
      begin_dialogs → req.contexts[:0]
      skills 过滤（_filter_skills_for_current_config :467-496 + workspace skills :548-575）
      tools 白名单 → req.func_tool（get_full_tool_set 或按名筛选）
      subagent_orchestrator 集成（handoff 工具注入 / 去重 / router_prompt）
      trace.record("sel_persona", ...) (:657-664)
  → 后续 _apply_* 分支继续追加 system_prompt（TOOL_CALL_PROMPT、workspace EXTRA_PROMPT.md 等）
  → ToolLoopAgentRunner.reset (tool_loop_agent_runner.py:207-327)
      system 消息（含 persona）→ 上下文最前；begin_dialogs 紧随其后
  → step() 循环中 ContextManager 压缩（system 受保护）
```

## 1. 数据模型与存储

### 1.1 v4 Persona 表（po.py:145-178）

| 字段 | 类型 | 语义 |
|---|---|---|
| `id` | int 自增主键 | 内部行 ID |
| `persona_id` | str, max_length=255, unique（uix_persona_id :173-178） | **显示名即 ID**（非 UUID） |
| `system_prompt` | Text, nullable=False | 系统提示词（必填） |
| `begin_dialogs` | JSON list[str] \| None | 预设对话，偶数条 user/assistant 交替 |
| `tools` | JSON list[str] \| None | 注释明示三态（:163）：None=全部工具、[]=无工具、列表=名单 |
| `skills` | JSON list[str] \| None | 同上（:164-165） |
| `custom_error_message` | Text \| None | 请求失败时发给用户的替代文案（:166-167） |
| `folder_id` | str \| None | 所属文件夹（NULL=根目录，:168-169） |
| `sort_order` | int | 排序（:170-171） |

PersonaFolder 表（po.py:112-142）：递归层级，`parent_id` NULL=根（:132-133）。对话级绑定 ConversationV2 的 persona_id（po.py:86，conversations 表）。

### 1.2 v3 兼容层（persona_mgr.py）

- `Personality` TypedDict（po.py:581-601）：包含 prompt、name、begin_dialogs、已废弃的 mood_imitation_dialogs、tools、skills 和 custom_error_message；
- `DEFAULT_PERSONALITY`（persona_mgr.py:9-19）：`prompt="You are a helpful and friendly assistant."`，name=`"default"`，tools/skills=None；
- `get_v3_persona_data`（:353-432）：
  - 每行 DB persona 转为 dict（mood_imitation_dialogs 恒为 `[]`，:369）；
  - `begin_dialogs` 校验：**奇数条整组丢弃并记 error**（:383-388），合法则按 user/assistant 交替生成 `{role, content, _no_save: True}`（:389-398）；
  - 解析失败的 persona 记 error 跳过（:409-410）；
  - `selected_default_persona`：先匹配 `name == self.default_persona`，无匹配取第一个，全空则 `DEFAULT_PERSONALITY` 并**追加进 personas_v3**（:412-418）；
  - 同时写 `selected_default_persona`（Persona 模型，:423-430）；
- 每次 CRUD 后重建：delete（:135）、update（:169）、move（:201）、batch sort（:274）、create（:350）。

### 1.3 管理 API

- Dashboard REST：`astrbot/dashboard/api/personas.py`（CRUD/文件夹/排序）；
- Service：`astrbot/dashboard/services/persona_service.py`；
- 插件 API：`context.persona_manager`（star/context.py:161），文档 docs/zh/dev/star/plugin.md:1585-1657（get/create/update/delete_persona）。

### 1.4 v3 迁移（migra_3_to_4.py:236-276）

- `migration_persona_data`：config.json 的 `persona` 键导入 DB；
- 废弃的 `mood_imitation_dialogs` 被**拼进 system_prompt**（:253-266）——内容保留但不再作为独立字段。

## 2. 角色解析优先级

### 2.1 resolve_selected_persona（persona_mgr.py:75-127）

返回值是四元组：所选 persona_id、Personality 或 None、强制应用的 persona_id，以及是否使用 webchat 特殊默认值（:82-91）。

```text
1. 读 SharedPreferences scope=umo 的 session_service_config（:92-100）
   → persona_id = session_service_config.persona_id（会话规则强制，最高优先）
2. 若为空：persona_id = conversation.persona_id（对话级绑定）
   - "[%None]" 哨兵 → 保持 None 不动（显式禁用）
   - None → provider_settings.default_personality（全局默认）
3. 在 personas_v3 中按 name 查找（:112-115）
4. 找不到 + platform==webchat + 非 "[%None]" → persona_id="_chatui_default_"，use_webchat_special_default=True（:117-120）
5. 返回
```

注意：`"[%None]"` 只对**对话级**生效（:107-108）；会话规则若直接绑定这个哨兵，persona_id 会被置为该值，后续查找（:112）失败后（非 webchat）返回空 persona，因此规则级也能禁用。

### 2.2 引用了不存在 persona 的行为

- persona 为空时（:531-541）：**静默回落**——只追加 webchat 特例（若开关 `enable_default_system_prompt` 不为 False）；非 webchat 平台则完全不注入任何 persona 指令；
- 引用不存在的 persona_id 时，解析函数返回 None（persona_mgr.py:112-121）——不报错；
- 删除被引用的 persona：DB 删除（:129-135），对话/规则中的引用残留不清理，运行时回落默认行为。

## 3. 注入实现（_ensure_persona_and_skills，astr_main_agent.py:499-664）

### 3.1 前置

- 请求的 system_prompt 兜底为空串（:506-507）；
- webchat 内联 GenUI 开关 `enable_inline_genui` 追加 `CHATUI_INLINE_GENUI_SYSTEM_PROMPT`（:509-510）；
- `req.conversation` 为空直接 return（:512-513）——**无对话对象时不注入任何 persona/skills**。

### 3.2 persona 注入

```python
if prompt := persona["prompt"]:
    req.system_prompt += f"\n# Persona Instructions\n\n{prompt}\n"   # :533-534
if begin_dialogs := copy.deepcopy(persona.get("_begin_dialogs_processed")):
    req.contexts[:0] = begin_dialogs                                 # :535-536
```

- `_begin_dialogs_processed` 是 v3 缓存的已处理列表（带 role 与 `_no_save`）；deepcopy 防止污染缓存；
- 预设对话通过 `req.contexts[:0]` 插入历史**最前**（在会话历史之前、system 之后）；
- webchat 特例分支（:537-541）：`use_webchat_special_default and event.get_extra("enable_default_system_prompt") is not False`。

### 3.3 skills 过滤（:543-575）

```text
runtime = cfg.computer_use_runtime（默认 "local"）
SkillManager().list_skills(active_only=True, runtime=runtime)
_filter_skills_for_current_config（:467-496）：
    - 非插件源 skill 直接放行
    - 插件 skill：插件未激活→剔除；插件 reserved 或 plugin_set 无限制→放行；
      否则按 plugin_set 名单过滤
workspace skills：runtime=="local" 时 list_workspace_skills(workspace_root)（:549-554）
persona.skills 三态（:557-567）：
    - None → 全部（不过滤）
    - [] → skills=[]（含 workspace 清零：:563 的 and 条件决定 workspace 是否合并）
    - [名单] → 仅保留 name 在名单内的注册 skills；workspace skills 仍按名合并（:563-567）
注入：build_skills_prompt(skills) 追加 system_prompt（:569）
runtime=="none" 且注入 skills 时追加"未启用 Computer Use"提示（:570-575）
```

### 3.4 工具白名单（:578-594）

```python
if (persona and persona.get("tools") is None) or not persona:
    persona_toolset = tmgr.get_full_tool_set()      # 全量（含 _PermissionGuardedTool 包装）
    移除 inactive 工具（:581-583）
else:
    persona_toolset = ToolSet()
    for tool_name in persona["tools"]:
        tool = tmgr.get_func(tool_name)             # 查 func_list + 内置工具
        if tool and tool.active: add_tool
if not req.func_tool: req.func_tool = persona_toolset
else: req.func_tool.merge(persona_toolset)          # merge 走 add_tool 去重规则
```

语义：`tools=[]` 时 persona_toolset 为空，最终 `req.func_tool` 为空集（若之前无工具）→ 模型无工具可用；`tools=None` 走全量。

### 3.5 subagent_orchestrator 集成（:596-656）

- 配置 `subagent_orchestrator.main_enable` 开启（:599）；
- 遍历 `agents` 列表：`persona_id` 存在时用该 persona 的 tools 覆盖 agent 的 tools 声明（:610-618）；
- `tools=None` → 全部非 HandoffTool 工具归入 assigned_tools（:619-627）；
- 主 Agent 工具集追加所有 handoff 工具（:638-640）；
- `remove_main_duplicate_tools`（去重开关，:643-648）：把 assigned_tools 中非 handoff 的从主 Agent 工具集移除——**子 Agent 负责的工具从主 Agent 收回**；
- `router_system_prompt` 追加 system_prompt（:650-656）。

### 3.6 追踪

追踪记录（`event.trace.record`，:657-664）保存每次请求的解析结果与工具集快照，供 Trace 页查看。

## 4. system prompt 最终拼装顺序

完成 persona 与能力处理后，`build_main_agent` 及后续分支还会追加（astr_main_agent.py:1669-1675 附近）：

```text
[persona]  # Persona Instructions（+ GenUI/Safety/Live 等前置项）
skills prompt（build_skills_prompt）
TOOL_CALL_PROMPT（默认）或 TOOL_CALL_PROMPT_SKILLS_LIKE_MODE（skills_like 模式）
LIVE_MODE_SYSTEM_PROMPT（live_mode 时）
LLM_SAFETY_MODE_SYSTEM_PROMPT（安全模式时）
sandbox/local 环境提示（_build_local_mode_prompt :445-464、SANDBOX_MODE_PROMPT）
workspace EXTRA_PROMPT.md（_apply_workspace_extra_prompt :393-428）
subagent router_prompt
```

消息最终排列（ToolLoopAgentRunner.reset，tool_loop_agent_runner.py:309-324）如下：

```text
[0]  system = 完整 req.system_prompt
[1..n] begin_dialogs（_no_save 标志）
[n+1..] 会话历史（conversation.history + checkpoint 绑定，bind_checkpoint_messages :310）
[末尾] 本轮用户消息（prompt → extra_user_content_parts[系统提醒/知识库结果/引用] → 图片 → 音频）
```

注：`_apply_kb`（:278-309）知识库结果与 `_append_system_reminders`（:948-988，用户 ID/群名/时间）走 `extra_user_content_parts` **用户消息侧**注入，不进 system。

## 5. 绑定粒度

| 粒度 | 机制 | 位置 |
|---|---|---|
| 全局默认 | `provider_settings.default_personality`（默认 "default"，按 UMO 配置可覆盖） | config/default.py:124；persona_mgr.py:63-73 |
| 会话规则（UMO 级） | `session_service_config.persona_id` 强制覆盖 | persona_mgr.py:92-103 |
| 对话级 | `ConversationV2.persona_id`，可随时改 | po.py:86；conversation_service.py:124-145；`/new` 继承当前 persona（builtin_commands/commands/conversation.py:239-244） |

- `persona_pool` 配置项已定义但**从未使用**（astrbot-config.md:339-341）；
- `/persona` 指令（docs/zh/use/command.md:148-167）不在内置指令集中（内置仅 help/sid/name/reset/stop/new/stats/provider/dashboard_update/set/unset），依赖外部命令插件。

### 5.1 会话创建、消息快照与重新生成

- **会话创建不写入任何初始消息**：new_session（astrbot/dashboard/services/chat_service.py:1364-1373）只建 PlatformSession 行；ConversationV2 在首条消息时惰性创建且 content=None（astrbot/core/conversation_mgr.py:207-210）。begin_dialogs 每轮以前置插入方式注入（astr_main_agent.py:535-536），消息带不保存标记（persona_mgr.py:389-398），历史保存逻辑会显式跳过它（internal.py:470-471）——永不入库，因此旧历史不会残留旧版 begin_dialogs。
- **修改 begin_dialogs 后既有会话下一轮自动生效**：`personas_v3` 缓存每次 CRUD 重建（persona_mgr.py:135、169、201、274、350），每轮 `_ensure_persona_and_skills` 重新解析注入。
- **消息对象层不保存角色/模型快照**：PlatformMessageHistory（po.py:239-269）只有 platform_id、user_id、sender、content、llm_checkpoint_id，无 persona_id、无模型名；bot 消息内容由 build_bot_history_content 生成（chat_service.py:97-113），AgentStats 只含 token/耗时（astrbot/core/agent/response.py:31-38）。当次实际模型的记录分层存放在 trace 日志和 DB provider_stat 表中，具体定位见相关实现（internal.py:282-291、578-586）；selected_model 只经请求 extra 进入 req.model（astr_main_agent.py:1411-1412），不留存。
- **重新生成走完整主链路**：`chat.py:222-244` regenerate → `prepare_regenerate_message_payload`（chat_service.py:1721-1825，回滚历史 `history[:start]+history[end+1:]` :1799、删旧 bot 展示记录、换新 checkpoint）→ `_send_chat` → `build_chat_stream`（chat.py:94）→ 同一 Agent 构建链 → 重新解析 Persona 当前值。行为上每轮解析与 AIO Hub 的实时引用一致，但消息本身没有任何执行参数快照可查。

## 6. 自定义错误回复（persona_error_reply.py，86 行）

- 核心键：`PERSONA_CUSTOM_ERROR_MESSAGE_EXTRA_KEY = "persona_custom_error_message"`（:6）；
- `normalize_persona_custom_error_message`（:9-14）：非 str/空串 → None，去空白；
- 写入点：`set_persona_custom_error_message_on_event`（:37-47）在 `_ensure_persona_and_skills`（astr_main_agent.py:527-529）写入事件 extra；
- 消费点：
  - `astr_agent_run_util.py:326-336`：run_agent 异常时优先用自定义文案；
  - `pipeline/process_stage/method/agent_sub_stages/internal.py:432-438`：内部 runner 兜底；
  - `third_party.py:189-205`：第三方 runner 会话级错误文案——**第三方 runner 唯一解析 persona 相关内容的入口**；
- resolve_persona_custom_error_message（:50-69）独立复用角色解析逻辑，供无 Agent 路径（如 API 直连）解析。

## 7. 内置角色

| 角色 | 内容 | 位置 |
|---|---|---|
| `default` | "You are a helpful and friendly assistant."（内存，非 DB） | persona_mgr.py:9-19 |
| `_chatui_default_` | webchat 专用（"calm, patient friend..."，约 500 字符情感支持型设定，含"结束时加一个跟进问题"指令） | astr_main_agent_resources.py:44-59 |

- `get_persona_v3_by_id`（persona_mgr.py:47-61）：None/空 → None；`"default"` → DEFAULT_PERSONALITY；否则按 name 搜索；
- 无人格时自动补 DEFAULT_PERSONALITY（:412-418），保证 `personas_v3` 永不空。

## 8. 与上下文压缩的交互

- **system 保护**：ContextTruncator 的 `_split_system_rest`（truncator.py:15-29）把开头连续 system 消息剥离；后续三种截断策略（:100-202）均不触碰 system——persona 文本永不被丢弃；
- **计入 token**：token_counter.py:46-73 统计 system——超长 persona 推高总量、更早触发轮次截断或 LLM 摘要压缩（阈值 82%，keep_recent_ratio 默认 0.15）；
- `_ensure_user_message`（truncator.py:31-49）：截断后保证 system 后紧跟 user 消息（Zhipu 等 API 硬性要求）；
- `fix_messages`（:51-98）：tool_call/tool 配对修复（Gemini 严格校验）；
- **begin_dialogs 的脆弱性（静态推断）**：带 `_no_save` 的 begin_dialogs 在消息列表中是"非 system"，位于历史最前——按轮次截断/折半策略会先被丢弃，长会话中开场白可能静默消失（其语义为每轮重注入，但截断发生在注入之后）。

## 9. UI 层

| 界面 | 位置 | 内容 |
|---|---|---|
| 人格列表/卡片 | `views/persona/PersonaManager.vue` | 卡片式浏览（PersonaCard），system_prompt 截断显示 160 字符（PersonaCard.vue:15）；导入 JSON（:778-806，冲突自动加 `_imported_N` 后缀 :784-797）；删除确认 |
| 表单 | `components/shared/PersonaForm.vue` | persona_id（编辑时禁用，:37）、system_prompt（:43-50）、custom_error_message（:52-61）、能力编辑器 `PersonaCapabilitiesEditor`（tools/skills，:72-79）、预设对话展开面板（user/assistant 交替 label，:107-120）；校验规则见下 |
| 文件夹 | `views/persona/FolderTree.vue`、`MoveToFolderDialog.vue`、`FolderCard.vue` | 递归文件夹 + 拖拽/移动 |
| 能力编辑器 | `components/shared/PersonaCapabilitiesEditor.vue`、`PersonaCapabilityList.vue` | 三态选择（全部/禁用/名单）；未激活插件的 skill 被过滤出可选项与选中计数（PersonaCapabilitiesEditor.vue:75-77、185-207，消费 skills 列表的 `plugin_active` 字段，skills_service.py:263-274） |
| 预览 | `components/shared/PersonaQuickPreview.vue` | 快速预览效果 |
| 选择器 | `components/shared/PersonaSelector.vue` | 对话内切换 persona（写 conversation.persona_id） |
| 会话规则 | `SessionManagementPage.vue:505-524` | 规则绑定 persona_id（session_service_config） |
| 子 Agent | `views/SubAgentPage.vue` | agent → persona 关联 |

校验规则（PersonaForm.vue）：`persona_id` 非空 + 唯一（后端 DB unique 兜底）；`system_prompt` 最短 10 字符（:247-251 附近）；begin_dialogs 按行配对（`getDialogRules` :116）。

PersonaManager 的移动端工具栏现在始终保留新建文件夹入口，不再因已存在文件夹而隐藏；这是管理表面的可达性调整，不改变 persona 或文件夹的存储语义（`dashboard/src/views/persona/PersonaManager.vue:36-45`）。

## 10. 设计取舍与边界

### 10.1 已确认（代码/文档可证）

1. persona 是纯文本指令 + 白名单，无头像/语音/名称字段；
2. 只在内置 Agent 执行器生效；第三方 runner 完全不注入 persona（仅错误文案）；
3. `persona_pool` 配置项定义未用（astrbot-config.md:339-341）；
4. `mood_imitation_dialogs` v4 起废弃，迁移改写进 system_prompt（migra_3_to_4.py:253-266）；
5. v3 config.json persona 键已废弃（astrbot-config.md:561-565）；
6. SubAgent 无法隔离人格的 Skills；子 agent 对话历史不保存；
7. 每次 CRUD 重建 v3 缓存（persona_mgr.py:135,169,201,274,350）；
8. 自定义错误文案经事件 extra 每请求解析写入，非全局状态；
9. begin_dialogs 奇数条整组丢弃（persona_mgr.py:383-388）；
10. `"[%None]"` 哨兵两处语义：对话级与规则级都能禁用（:107-108、:102-103）；
11. persona 引用计数不存在：删除被引用 persona 后相关对话/规则静默回落默认。

### 10.2 取舍（平衡决策）

- **v3 兼容层，不是迁移清理**：运行时代价是一次冗余转换缓存，收益是 v3 插件 API（`get_persona_v3_data` 等）与 v4 并存；
- **persona_id 即显示名**：用户可读、易管理，代价是改名人脸经 DB 更新（无独立 slug）；
- **tools/skills 双三态**：None 语义在 WebUI 与 API 间靠 `NOT_GIVEN` 哨兵区分"未修改"与"显式置空"（persona_mgr.py:142-144）——API 设计细节；
- **workspace skills 不过滤**：persona 白名单只管注册 skills，工作区 skill 合并进主集（:563-567）——本地优先的设计意图；
- **subagent 工具回收**：`remove_main_duplicate_tools` 让子 Agent 抢走主 Agent 的重复工具，避免双 Agent 竞争（:643-648）。

### 10.3 静态推断的潜在问题（源码推断，未实测）

1. **超长 persona 无保护**：不截断、不告警，挤占上下文窗口、加速历史压缩；
2. **begin_dialogs 与轮次截断的交互**：非 system 消息先被丢，长会话开场白静默消失；
3. **切换 persona 后旧历史仍保留**：无变更标记/清空机制，模型可能受旧人格输出风格影响；
4. **引用不存在 persona 静默回落**：无告警日志（persona_mgr.py:112-121 无 logger），排查困难；
5. `resolve_selected_persona` 中 `provider_settings` 实参传入的是 `cfg`（astr_main_agent.py:524），而 `cfg` 是已带 UMO 覆盖的配置——文档与实现需对照 config 层验证。

## 11. 关键文件索引

| 文件 | 关键位置 |
|---|---|
| `astrbot/core/persona_mgr.py` | DEFAULT_PERSONALITY :9-19；get_persona_v3_by_id :47-61；resolve_selected_persona :75-127；get_v3_persona_data :353-432 |
| `astrbot/core/persona_error_reply.py` | 自定义错误文案整链（normalize :9-14 / set :37-47 / resolve :50-69） |
| `astrbot/core/db/po.py` | Persona :145-178；PersonaFolder :112-142；ConversationV2 :67-109；Personality :581-601 |
| `astrbot/core/astr_main_agent.py` | _ensure_persona_and_skills :499-664；_filter_skills_for_current_config :467-496；_apply_workspace_extra_prompt :393-428；_apply_local_env_tools :431-442；build_main_agent :1375-1713 |
| `astrbot/core/astr_main_agent_resources.py` | CHATUI_SPECIAL_DEFAULT_PERSONA_PROMPT :44-59；CHATUI_INLINE_GENUI :61-76；LIVE_MODE :78-88；TOOL_CALL_PROMPT :25-41 |
| `astrbot/core/agent/runners/tool_loop_agent_runner.py` | reset（system/begin_dialogs 落位）:207-327 |
| `astrbot/core/agent/context/truncator.py` | _split_system_rest :15-29；_ensure_user_message :31-49；fix_messages :51-98 |
| `astrbot/core/agent/context/token_counter.py` | system 计入 :46-73 |
| `astrbot/core/db/migration/migra_3_to_4.py` | migration_persona_data :236-276 |
| `astrbot/core/config/default.py` | default_personality :124；persona_pool :125 |
| `astrbot/dashboard/services/persona_service.py`、`api/personas.py` | CRUD REST |
| `astrbot/builtin_stars/builtin_commands/commands/conversation.py` | /new 继承 persona :239-244 |
| UI | `views/persona/PersonaManager.vue`；`components/shared/PersonaForm.vue`；`PersonaCapabilitiesEditor.vue`；`PersonaSelector.vue`；`SessionManagementPage.vue:505-524` |
| 文档 | docs/zh/use/custom-rules.md、subagent.md、skills.md、command.md；docs/zh/dev/star/plugin.md:1585-1657 |

## 12. 未验证事项

1. `/persona` 指令实现不在本仓库，按文档记载为准，未找到实现位置；
2. 切换 persona 后历史保留行为未实测；
3. dashboard 各 persona 表单组件的完整校验逻辑（除 system_prompt 10 字符外）未逐行核对；
4. `enable_default_system_prompt` flag 在 webchat 各路径的设置点未全部追踪；
5. 第三方 runner（Dify/Coze 等）对 persona 的完整处理（third_party.py:189-205 之外）未逐行核对。
