# AstrBot Chat 调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`346b85db9d79207ea7b51694cce5276203612af4`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：会话模型与持久化、事件总线与任务模型、流水线调度与各阶段、唤醒、并发控制与 follow-up、上下文构建与压缩、群聊/私聊差异、UI 层
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 是面向 IM 平台（QQ/Telegram/Discord/微信等）的**消息驱动异步聊天框架**。一条入站消息经 `EventBus` 从异步队列取出，为每条消息创建独立 asyncio 任务，交给按配置 ID 映射的 `PipelineScheduler` 按固定 9 阶段顺序处理。并发控制不靠阶段限流，而靠 UMO 粒度的 `session_lock` 串行化 LLM 请求 + 严格有序的 follow-up 队列。

关键事实（快照 346b85d）：

- **两级会话概念**：会话（session）= 聊天窗口（如一个群），以 `unified_msg_origin`（`platform_id:message_type:session_id`，message_session.py:19）标识；对话（conversation）= 会话内的子对话，可新建/切换/删除（conversation_mgr.py:1-5 docstring）。
- **持久化双轨**：对话历史存 SQLite `conversations` 表（`ConversationV2.content` = OpenAI 格式 JSON 列表，po.py:83）；当前对话 ID 经 SharedPreferences `sel_conv_id`（scope=umo）持久化。
- **流水线 9 阶段**（stage_order.py:3-13）：WakingCheck → WhitelistCheck → SessionStatusCheck → RateLimit → ContentSafety → PreProcess → Process → ResultDecorate → Respond。
- **洋葱模型调度**（scheduler.py:35-78）：阶段 `process()` 返回普通协程 → 基线继续；返回 `AsyncGenerator` → 挂起，递归执行后续阶段，后续阶段完成后回到 yield 点执行后置逻辑（LLM 请求阶段用此模式：先让 Respond 发送，再回来做收尾）；`event.stop_event()` 在任意点截断传播。
- **EventBus 每事件一任务**（event_bus.py:39-63）：`asyncio.create_task` + `_pending_tasks` 强引用防 GC，完成回调暴露未捕获异常。
- **并发控制**：`SessionLockManager`（session_lock.py:8-55）按事件循环隔离、UMO 粒度的 `asyncio.Lock` + 引用计数自动清理，包裹整个 LLM 请求（internal.py:220）。
- **follow-up 严格序**（process_stage/follow_up.py，234 行）：Agent 运行期间同发送者的新消息捕获为 `FollowUpTicket`，在捕获时分配单调序号，`asyncio.Condition` 只放行队首；序号状态按 UMO 维护、无残留时自动释放。
- **唤醒**：`/` 前缀、@机器人、@全体、回复引用、私聊默认（webchat 无条件）；插件 handler filter AND 满足即唤醒；管理员在唤醒阶段就标记 role（waking_check/stage.py:96-104）。
- **群聊上下文**：`GroupChatContext` 每 UMO 内存环形记录最多 1000 条原始消息（含图像 caption），注入时格式化为 `<system_reminder>` 块；群历史可选持久化 700 条上限并暴露 `get_group_message_history` 工具。
- **上下文压缩两层**（context/manager.py:45-121）：先轮次截断（enforce_max_turns≠-1），再 token 压缩（82% 阈值触发，`TruncateByTurnsCompressor` 或 `LLMSummaryCompressor`，压缩后仍超限折半兜底）。

## 总体调用链

```text
平台适配器收到消息 → 构造 AstrMessageEvent（platform:message_type:session_id）
  → event_queue.put()（EventBus.dispatch 无限循环消费，event_bus.py:39-54）
  → 按 conf 映射取 PipelineScheduler → asyncio.create_task(scheduler.execute(event))
  → PipelineScheduler.execute（scheduler.py:80-97）
      active_event_registry.register(event)
      → _process_stages(event, from_stage=0)（洋葱模型，:35-78）
          WakingCheckStage（唤醒判定 + 插件 handler 匹配 + unique_session 改写 session_id）
          WhitelistCheckStage / SessionStatusCheckStage / RateLimitStage / ContentSafetyCheckStage
          PreProcessStage
          ProcessStage → InternalAgentSubStage（session_lock 包裹 → build_main_agent → agent 循环）
                         或插件 handler / 第三方 runner
          ResultDecorateStage（@/回复前缀、T2I、TTS、分段回复、forward、content safety 复查）
          RespondStage（发送）
      finally: event.cleanup_temporary_local_files(); active_event_registry.unregister
```

## 1. 会话模型与持久化

### 1.1 两级概念（conversation_mgr.py:1-5 docstring）

- **会话**：聊天窗口（群聊/私聊），`unified_msg_origin` 标识；
- **对话**：会话内的子对话，可切换（`switch_conversation` :126-137）、删除（:139-158）、新建（`new_conversation` :92-124，`/new` 继承当前 persona 与模型，builtin_commands/commands/conversation.py:239-244）。

### 1.2 会话标识（message_session.py:6-27）

```text
unified_msg_origin = f"{platform_id}:{message_type.value}:{session_id}"
```

- `MessageSession.from_str` 用 `split(":", 2)` 解析（:24-27）——session_id 本身可含冒号；
- `platform_id` 与 `platform_name` 在 v4 起统一（:13-16，`__post_init__` 自动取等值）。

### 1.3 对话表（po.py:67-109）

| 字段 | 说明 |
|---|---|
| `inner_conversation_id` | int 自增主键 |
| `conversation_id` | str UUID（:75-80） |
| `platform_id` / `user_id` | user_id = UMO（:82） |
| `content` | OpenAI 格式历史 JSON 列表（:83） |
| `persona_id` | 对话级角色绑定（:86） |
| `token_usage` | 累计 token，0 时用估计器（:87-91） |

### 1.4 ConversationManager（conversation_mgr.py:19-443）

- 内存缓存 `session_conversations: dict[str, str]`（UMO → 当前对话 ID，:23），`save_interval = 60` 秒（:25）——保存走 SharedPreferences `sel_conv_id`（`sp.session_put` :123、:137）；
- `get_curr_conversation_id` 三级回退：内存 → SP → None（:174-188）；
- **v2→v1 兼容转换** `_convert_conv_from_v2_to_v1`（:62-90）：`Conversation` 是 v3 时代的内存模型（history=JSON 字符串），`get_conversation` 统一返回 v1 形态（:190-214）；
- 删除会话触发级联回调 `register_on_session_deleted`（:30-43），用于知识库配置等清理（:171-172）；
- `add_message_pair`（:357-390）以 user+assistant 对追加历史；`get_human_readable_context`（:392-443）把历史转成 "User:/Assistant:" 可读文本（tool_calls 转 JSON，:423-428）。

## 2. 事件总线与任务模型（event_bus.py，83 行）

- 构造：`event_queue: asyncio.Queue` + `pipeline_scheduler_mapping: dict[conf_id, PipelineScheduler]`（:26-35）——**按配置实例分调度器**，多租户配置各自独立 pipeline；
- `dispatch()` 无限循环（:39-54）：取事件 → `get_conf_info` 解析配置名（:42-44）→ 无调度器则忽略（:46-51）→ `create_task`；
- **task 强引用**（:36-37、:53）：`_pending_tasks` 防止 pending task 被 GC；完成回调 `_on_task_done` 移除引用并暴露异常（:56-63）；
- 消息日志（:65-83）：`[配置名] [平台ID(平台名)] 发送者名/发送者ID: 消息概要`，extra `category=user_chat`。

## 3. 流水线调度（scheduler.py，98 行）

### 3.1 阶段顺序（stage_order.py:3-13）

| # | 阶段 | 职责 |
|---|---|---|
| 0 | `WakingCheckStage` | 唤醒判定（见 §5） |
| 1 | `WhitelistCheckStage` | 群/私聊白名单 |
| 2 | `SessionStatusCheckStage` | 会话是否被禁用 |
| 3 | `RateLimitStage` | 频控 |
| 4 | `ContentSafetyCheckStage` | 入站内容安全 |
| 5 | `PreProcessStage` | 事件预处理 |
| 6 | `ProcessStage` | 插件/LLM 请求（agent 子阶段） |
| 7 | `ResultDecorateStage` | 结果装饰（见 §4.7） |
| 8 | `RespondStage` | 发送 |

### 3.2 洋葱模型（scheduler.py:35-78）

```text
for stage in stages:
    coroutine = stage.process(event)
    if isinstance(coroutine, AsyncGenerator):
        async for _ in coroutine:          # yield 点 = 前置完成、后置待执行
            if event.is_stopped(): break
            await self._process_stages(event, i + 1)   # 递归执行后续阶段
            if event.is_stopped(): break
    else:
        await coroutine                     # 普通协程 = 基线，不递归
        if event.is_stopped(): break
```

- 递归深度 = 后续阶段数（最多 8 层）；
- `event.stop_event()` 在任何点截断：`execute()` 的 finally 保证临时文件清理与注册表注销（:96-98）；
- webchat/wecom_ai_bot 事件最后 `send(None)` 刷新 UI（:92-93）。

### 3.3 阶段注册

- `register_stage` 装饰器 + `registered_stages` 列表；`PipelineScheduler.__init__` 按 `STAGES_ORDER.index(cls.__name__)` 排序（:21-24），未在 STAGES_ORDER 中的阶段会抛 ValueError——顺序表是硬约束。

## 4. 各阶段细节

### 4.1 WakingCheckStage（waking_check/stage.py:35-248）

初始化配置（:46-75）：`no_permission_reply`、`friend_message_needs_wake_prefix`（默认 False）、`ignore_bot_self_message`（默认 False）、`ignore_at_all`（默认 False）、`disable_builtin_commands`、`unique_session`（默认 False）。

处理顺序（:77-248）：

1. **unique_session 改写**（:81-85）：群聊时按平台构建器换 session_id（`UNIQUE_SESSION_ID_BUILDERS` :17-26，覆盖 aiocqhttp/slack/dingtalk/qq_official/qq_official_webhook/lark/misskey/matrix 8 平台；webchat 不在内）；
2. **忽略机器人自身消息**（:87-93）：`get_self_id() == get_sender_id()` → stop；
3. **管理员身份标记**（:95-104）：遍历 `admins_id`，命中即 `event.role = "admin"`（API key 传 `_api_key_allow_admin_role` 可禁用）；
4. **前缀唤醒**（:106-124）：`wake_prefix`（默认 `/`）开头；群聊首段是 At 但非 @机器人/@全体则放弃；命中后剥离前缀（`message_str[len(wake_prefix):]`，:123）；
5. **At/AtAll/Reply 唤醒**（:125-143）：At 机器人、At 全体（受 ignore_at_all）、回复引用 bot 的消息（`Reply.sender_id == self_id`）；
6. **私聊默认唤醒**（:144-152）：非 `friend_message_needs_wake_prefix` 或 webchat；
7. **插件 handler filter 匹配**（:154-245）：遍历 `EventType.AdapterMessageEvent` handlers（受 `plugins_name` 过滤 :158-165），**filter 需 AND 全过**（:185-204）；`PermissionTypeFilter` 单独处理权限失败（:187-190、:205-221，`raise_error` 与 `no_permission_reply` 决定是否回复）；命中即 `is_wake=True`（:223-224）；`CommandGroupFilter` handler 不入 activated_handlers（:226-230）；
8. `SessionPluginManager.filter_handlers_by_session` 会话级二次过滤（:238-242）；
9. 仍非唤醒 → `event.stop_event()`（:247-248）。

### 4.2 RateLimitStage

- 对同一 UMO 计数，超过限制默认 **stall**（阻塞流水线直到限流窗口结束）而非丢弃（rate_limit_check/stage.py:74-82）。

### 4.3 ContentSafetyCheckStage

- 入站文本/图片审核；`content_safety.also_use_in_response` 开启时 `ResultDecorateStage` 会复用本阶段检查回复内容（result_decorate/stage.py:91-99）。

### 4.4 ProcessStage 与 agent 子阶段

- `InternalAgentSubStage.process`（internal.py:162+）：
  - 空消息且无 provider_request/media/reply → 跳过 LLM 请求（:174-191）；
  - `try_capture_follow_up`（:194-210）——同会话 Agent 运行中则进 follow-up 通道（见 §6.2）；
  - `send_typing`（:212-216）、`OnWaitingLLMRequestEvent` hook（:217-218）；
  - **`async with session_lock_manager.acquire_lock(event.unified_msg_origin)`**（:220）包裹整个 LLM 流程；
  - `build_main_agent(apply_reset=False)`（:231-236）+ provider api_base 黑名单检查（`decoded_blocked`，:253-262）；
  - `OnLLMRequestEvent` hook 可拦截止步（:269-272）；
  - `register_active_runner` 登记 runner 供 follow-up 捕获（:278）；
  - trace.record("astr_agent_prepare")（:282-291）；Live Mode 走 `run_live_agent`（:293-299）；
- `third_party.py`：Dify/Coze/Dashscope/DeerFlow 等第三方 runner 路径（不入 persona，只解析错误文案）。

### 4.5 ResultDecorateStage（result_decorate/stage.py:21-439）

初始化配置（:23-102）：`reply_prefix`、`reply_with_mention`、`reply_with_quote`、`t2i_word_threshold`（默认 150，下限 50，:32-37）、`t2i_strategy`（local/remote）、`forward_threshold`、TTS `trigger_probability`（:46-56）、**分段回复** `segmented_reply`（词数阈值/正则/分隔词，:58-88）、内容安全复查（:91-99）、`display_reasoning_text`（:101-102）。

装饰项：
- 思考内容展示（reasoning）、TTS 转语音、T2I 转图片、转发（超阈值）、@/Reply 前缀、分段发送（`_split_text_by_words` :104-110）。

### 4.6 RespondStage

- 最终发送；`OnDecoratingResultEvent` 可在发送前再拦截（result_decorate/stage.py:159-189 附近）。

## 5. 并发控制

### 5.1 SessionLockManager（session_lock.py:8-55）

- **两级结构**：外层 `SessionLockManager` 按事件循环（`WeakKeyDictionary[event_loop, manager]`）隔离（:33-52）——避免跨 loop 的 asyncio.Lock 误用；
- 内层 `_PerLoopSessionLockManager`：`defaultdict(asyncio.Lock)` + 引用计数（:11-30），计数归零自动 pop（:28-30），无泄漏；
- 单例 `session_lock_manager`（:55）。

### 5.2 follow-up 严格序（process_stage/follow_up.py:1-234）

- 全局表：`_ACTIVE_AGENT_RUNNERS`（UMO → runner，:11）、`_FOLLOW_UP_ORDER_STATE`（UMO → 状态机，:12-19）；
- **捕获条件**（`try_capture_follow_up` :162-204）：同 UMO、同发送者、runner 未 stop；
- **捕获时即分配序号**（`_allocate_follow_up_order` :81-90）——按到达顺序而非唤醒顺序；
- 状态：`pending → active → finished/consumed`（:16-17）；
- **队首放行**（`_activate_and_wait_follow_up_turn` :112-130）：`asyncio.Condition` 等待 `next_turn == seq`——后续消息阻塞等前序；
- 完成推进（:63-78 `_advance_follow_up_turn_locked`、:133-148 `_finish_follow_up_turn`）；状态空 + 无 active runner → 释放 UMO 状态（:108-109、:147-148）；
- runner 侧消费：`FollowUpTicket`（tool_loop_agent_runner.py:95-125）——当前轮次结束后按序注入（`_merge_follow_up_notice` 附带 SYSTEM NOTICE 提示优先处理用户插话）。

### 5.3 ActiveEventRegistry（active_event_registry.py:10-67）

- UMO → 活跃事件集合（:16-17）；
- `stop_all`（:28-47）：stop 事件传播（/reset 等场景终止同会话旧事件）；
- `request_agent_stop_all`（:49-64）：只置 `agent_stop_requested`，**不中断事件传播**——历史保存等后续流程仍可执行；
- pipeline `execute` 注册/注销（scheduler.py:87、:98）。

## 6. 上下文构建与压缩

### 6.1 历史加载与注入

- `Conversation.content` JSON → `req.contexts`（astr_main_agent.py:1404-1405、:1538）→ `bind_checkpoint_messages` 还原（agent/message.py:327-342）；
- 附加注入：persona（`_ensure_persona_and_skills`）、知识库结果/系统提醒（`extra_user_content_parts`，用户消息侧）。

### 6.2 ContextManager（context/manager.py:10-121）

```text
process(messages, trusted_token_usage):
  1. enforce_max_turns != -1 → truncate_by_turns（轮次截断，保留最新 N 轮）
  2. max_context_tokens > 0：
       total = count_tokens(messages, trusted_token_usage)
       should_compress(result, total, max) → _run_compression
_run_compression:
  compressor(messages)          # LLMSummaryCompressor 或 TruncateByTurnsCompressor
  double check：仍超限 → truncate_by_halving（折半兜底）
```

- 压缩器选择（:31-43）：`custom_compressor` → `llm_compress_provider` 存在则 `LLMSummaryCompressor`（keep_recent_ratio 默认 0.15）→ 否则 `TruncateByTurnsCompressor`；
- 异常兜底：任何压缩错误返回原消息（:79-81）；
- token 估算：`EstimateTokenCounter`（token_counter.py:38）优先 `trusted_token_usage`；图片 765 / 音频 500 定额；
- 默认配置：`max_context_length: -1`（不轮次限制）、`context_limit_reached_strategy: "llm_compress"`（config/default.py:127、:139）；
- 截断器细节（truncator.py）：system 消息保护（:15-29）、保证 system 后跟 user（:31-49）、tool_call/tool 配对修复（:51-98，Gemini 严格模式）。

## 7. 群聊/私聊差异

| 维度 | 行为 | 位置 |
|---|---|---|
| 会话 ID 构造 | QQ 群 = group_id、私聊 = 用户 ID；webchat = `webchat!用户名!会话ID` | aiocqhttp_platform_adapter.py:222-226、webchat_adapter.py |
| 群上下文 | `GroupChatContext`（builtin_stars/astrbot/group_chat_context.py:41-302）：每 UMO 环形 deque 最多 1000 条原始消息（`DEFAULT_GROUP_MESSAGE_MAX_CNT` :38、可配 `group_message_max_cnt` :71-77），注入格式 `[昵称/时间]: 内容` 包在 `<system_reminder>...BEGIN CONTEXT...END CONTEXT...`（:31-37），受 `provider_ltm_settings.group_icl_enable` 控制 | :140-239 |
| 图像 caption | `get_image_caption`（:88-108）用独立 provider（可指定 `image_caption_provider_id`）为群消息图片生成描述并入上下文 | :88-108 |
| 群历史持久化 | `PlatformMessageHistory` 表（po.py:239-269），`group_message_history_enable` 开启后存储平台无关表示，上限 `group_message_history_max_cnt: 700`，暴露 `get_group_message_history` 工具 | platform_message_history_mgr.py:32-106 |
| 主动回复 | `active_reply`（group_chat_context.py:64-69、110-128）：概率触发（`possibility_reply` 随机 < `possibility_reply` 概率）、群聊限定、`is_at_or_wake_command` 不触发、白名单过滤 | :110-128 |
| 群隔离 | 默认群内共享同一对话；`unique_session` 开启后按发送者构建独立会话 | waking_check/stage.py:81-85 |

## 8. UI 层

| 界面 | 位置 | 内容 |
|---|---|---|
| 聊天 | `views/ChatPage.vue`、`components/chat/Chat.vue`、ChatMessageList、ChatInput | 会话列表（ProjectList）、消息渲染、输入框（CommandSuggestion）、LiveMode 组件 |
| 对话管理 | `views/ConversationPage.vue` | 对话切换/删除/标题编辑 |
| 会话规则 | `views/SessionManagementPage.vue` | 按 UMO 配置 persona/provider/系统提示（session_service_config） |
| 追踪 | `views/TracePage.vue`、`components/shared/TraceDisplayer.vue` | `event.trace` 各阶段记录（含 sel_persona/astr_agent_prepare） |
| 统计 | `views/stats/StatsPage.vue` | 会话统计（token 等） |

## 9. 设计取舍与边界

### 9.1 已确认的设计（代码事实）

- **每消息一任务、无全局并发调度**：吞吐靠 asyncio 并发，顺序性靠 UMO 锁与 follow-up 队列，跨会话天然并行；
- **洋葱模型统一收尾**：LLM 流式输出在 Process 阶段挂起，Respond 先发，收尾（历史保存等）后执行——单条事件单流水线无跨阶段状态泄漏；
- **follow-up 严格序**：捕获时分配序号 + Condition 队首放行，避免并发唤醒顺序漂移（注释 "avoid wake-order drift" :156）；
- **stage 顺序硬编码**：STAGES_ORDER 即约束，新增阶段必须显式加入；
- **配置粒度多租户**：`pipeline_scheduler_mapping` 按 conf_id 隔离；
- **agent 停止两态**：`stop_event`（硬断）vs `agent_stop_requested`（软停，保历史）——语义分离。

### 9.2 取舍（平衡决策）

- **阶段无并发上限 + UMO 锁**：同会话串行化，但全局无背压（事件队列无限 Queue）；
- **RateLimit stall 阻塞**：限流窗口内整条流水线挂起（消息排队），不丢弃但堆积；
- **内存群上下文 + 可选持久化**：1000 条环形缓冲实时性优先，持久化走独立表并暴露工具；
- **unique_session 默认关**：群聊默认共享对话（成本低），按人隔离需显式开启；
- **Conversation v1 兼容层**：内部统一返回 v3 时代内存模型，历史 API 零改动。

### 9.3 静态推断的潜在问题（源码推断，未实测）

1. **崩溃丢最近对话**：`session_conversations` 内存缓存 60s 防抖 + SP 持久化，进程崩溃可能丢 60s 内的切换/新建；
2. **长会话低频访问**：`max_context_length=-1` 默认不按轮次限制，依赖 82% token 阈值触发压缩，低频会话可能长期携带大上下文（每次请求全量发送）；
3. **follow-up 与流式并行**：`enable_streaming` 时 runner 仍在流式输出，follow-up 注入时机的完整行为（tool_loop_agent_runner.py:119-125 区段）未实测；
4. **洋葱递归深度**：每个 AsyncGenerator 阶段都递归展开，含 agent 的 Process 阶段 + 8 层后续阶段嵌套，深链异常栈排查成本高；
5. **EventBus 队列无限**：无背压/丢弃策略，突发流量下内存增长。

## 10. 关键文件索引

- 会话管理：`astrbot/core/conversation_mgr.py`（:19-443）、`astrbot/core/platform/message_session.py`（:6-27）
- 持久化：`astrbot/core/db/po.py`（ConversationV2 :67-109、PlatformMessageHistory :239-269）、`astrbot/core/db/sqlite.py`、`utils/shared_preferences.py`
- 事件：`astrbot/core/event_bus.py`（:23-83）
- 流水线：`astrbot/core/pipeline/stage_order.py`（:3-13）、`scheduler.py`（:17-98）、`stage.py`（register_stage）
- 各阶段：`waking_check/stage.py`（:17-248）、`whitelist_check/stage.py`、`session_status_check/stage.py`、`rate_limit_check/stage.py`（stall :74-82）、`content_safety_check/stage.py`、`preprocess_stage/stage.py`、`process_stage/stage.py`、`result_decorate/stage.py`（:21-439）、`respond/stage.py`
- Agent 子阶段：`process_stage/method/agent_sub_stages/internal.py`（session_lock :220）、`third_party.py`、`follow_up.py`（:1-234）
- 并发：`astrbot/core/utils/session_lock.py`（:8-55）、`utils/active_event_registry.py`（:10-67）
- 上下文：`astrbot/core/agent/context/manager.py`（:10-121）、`truncator.py`、`token_counter.py`、`compressor.py`、`config.py`
- 群上下文：`astrbot/builtin_stars/astrbot/group_chat_context.py`（:31-302）、`astrbot/core/platform_message_history_mgr.py`（:32-106）
- 配置：`astrbot/core/config/default.py`（wake_prefix、max_context_length :127、context_limit_reached_strategy :139、group_message_history_max_cnt）
- UI：`dashboard/src/views/ChatPage.vue`、`ConversationPage.vue`、`SessionManagementPage.vue`、`TracePage.vue`、`StatsPage.vue`
- 平台适配：`astrbot/core/platform/sources/aiocqhttp/aiocqhttp_platform_adapter.py`（:222-226）、`webchat/webchat_adapter.py`

## 11. 未验证事项

1. 未启动实例实测各阶段在真实平台上的时序行为；
2. follow-up 与流式响应并存时的详细交互未逐行核对；
3. `result_decorate` 的 T2I/转发/语音合成完整逻辑未逐行核对（本次仅覆盖初始化与分段回复）；
4. `third_party.py`（Dify/Coze 等）细节未逐行核对；
5. `whitelist_check`、`session_status_check`、`preprocess_stage` 三个阶段本次未深入逐行阅读。
