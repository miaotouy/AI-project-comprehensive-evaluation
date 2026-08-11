# AstrBot 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`346b85db9d79207ea7b51694cce5276203612af4`（分支：`master`）
>
> 调查方式：从 [`../Chat/AstrBot-Chat调查笔记.md`](../Chat/AstrBot-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：事件总线与任务模型、流水线调度与各阶段、并发控制与 follow-up、上下文构建与压缩、群聊上下文注入、唤醒与装饰；会话持久化与界面分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的一条入站消息经 `EventBus` 从异步队列取出，为每条消息创建独立 asyncio 任务，交给按配置 ID 映射的 `PipelineScheduler` 按固定 9 阶段顺序处理。并发控制不靠阶段限流，而靠 UMO 粒度的 `session_lock` 串行化 LLM 请求 + 严格有序的 follow-up 队列。

- **流水线 9 阶段**（stage_order.py:3-13）：WakingCheck → WhitelistCheck → SessionStatusCheck → RateLimit → ContentSafety → PreProcess → Process → ResultDecorate → Respond。
- **洋葱模型调度**（scheduler.py:35-78）：阶段 `process()` 返回普通协程 → 基线继续；返回 `AsyncGenerator` → 挂起，递归执行后续阶段，后续阶段完成后回到 yield 点执行后置逻辑（LLM 请求阶段用此模式：先让 Respond 发送，再回来做收尾）；`event.stop_event()` 在任意点截断传播。
- **EventBus 每事件一任务**（event_bus.py:39-63）：`asyncio.create_task` + `_pending_tasks` 强引用防 GC，完成回调暴露未捕获异常。
- **并发控制**：`SessionLockManager`（session_lock.py:8-55）按事件循环隔离、UMO 粒度的 `asyncio.Lock` + 引用计数自动清理，包裹整个 LLM 请求（internal.py:220）。
- **follow-up 严格序**（process_stage/follow_up.py，234 行）：Agent 运行期间同发送者的新消息捕获为 `FollowUpTicket`，在捕获时分配单调序号，`asyncio.Condition` 只放行队首；序号状态按 UMO 维护、无残留时自动释放。
- **上下文压缩两层**（context/manager.py:45-121）：先轮次截断（enforce_max_turns≠-1），再 token 压缩（82% 阈值触发，`TruncateByTurnsCompressor` 或 `LLMSummaryCompressor`，压缩后仍超限折半兜底）。

## 系统边界与生成任务主链

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

边界：会话/对话的持久化语义在会话与消息管理；项目自带 WebChat 与管理界面在 Chat UI；工具执行循环内部属于 Agent 工具类目。

## 1. 事件总线与任务模型（event_bus.py，83 行）

- 构造：`event_queue: asyncio.Queue` + `pipeline_scheduler_mapping: dict[conf_id, PipelineScheduler]`（:26-35）——**按配置实例分调度器**，多租户配置各自独立 pipeline；
- `dispatch()` 无限循环（:39-54）：取事件 → `get_conf_info` 解析配置名（:42-44）→ 无调度器则忽略（:46-51）→ `create_task`；
- **task 强引用**（:36-37、:53）：`_pending_tasks` 防止 pending task 被 GC；完成回调 `_on_task_done` 移除引用并暴露异常（:56-63）；
- 消息日志（:65-83）：`[配置名] [平台ID(平台名)] 发送者名/发送者ID: 消息概要`，extra `category=user_chat`。

## 2. 流水线调度（scheduler.py，98 行）

### 2.1 阶段顺序（stage_order.py:3-13）

| # | 阶段 | 职责 |
|---|---|---|
| 0 | `WakingCheckStage` | 唤醒判定（见 §3.1） |
| 1 | `WhitelistCheckStage` | 群/私聊白名单 |
| 2 | `SessionStatusCheckStage` | 会话是否被禁用 |
| 3 | `RateLimitStage` | 频控 |
| 4 | `ContentSafetyCheckStage` | 入站内容安全 |
| 5 | `PreProcessStage` | 事件预处理 |
| 6 | `ProcessStage` | 插件/LLM 请求（agent 子阶段） |
| 7 | `ResultDecorateStage` | 结果装饰（见 §3.5） |
| 8 | `RespondStage` | 发送 |

### 2.2 洋葱模型（scheduler.py:35-78）

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

### 2.3 阶段注册

`register_stage` 装饰器 + `registered_stages` 列表；`PipelineScheduler.__init__` 按 `STAGES_ORDER.index(cls.__name__)` 排序（:21-24），未在 STAGES_ORDER 中的阶段会抛 ValueError——顺序表是硬约束。

## 3. 各阶段细节

### 3.1 WakingCheckStage（waking_check/stage.py:35-248）

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

### 3.2 RateLimitStage

- 对同一 UMO 计数，超过限制默认 **stall**（阻塞流水线直到限流窗口结束）而非丢弃（rate_limit_check/stage.py:74-82）。

### 3.3 ContentSafetyCheckStage

- 入站文本/图片审核；`content_safety.also_use_in_response` 开启时 `ResultDecorateStage` 会复用本阶段检查回复内容（result_decorate/stage.py:91-99）。

### 3.4 ProcessStage 与 agent 子阶段

- `InternalAgentSubStage.process`（internal.py:162+）：
  - 空消息且无 provider_request/media/reply → 跳过 LLM 请求（:174-191）；
  - `try_capture_follow_up`（:194-210）——同会话 Agent 运行中则进 follow-up 通道（见 §4.2）；
  - `send_typing`（:212-216）、`OnWaitingLLMRequestEvent` hook（:217-218）；
  - **`async with session_lock_manager.acquire_lock(event.unified_msg_origin)`**（:220）包裹整个 LLM 流程；
  - `build_main_agent(apply_reset=False)`（:231-236）+ provider api_base 黑名单检查（`decoded_blocked`，:253-262）；
  - `OnLLMRequestEvent` hook 可拦截止步（:269-272）；
  - `register_active_runner` 登记 runner 供 follow-up 捕获（:278）；
  - trace.record("astr_agent_prepare")（:282-291）；Live Mode 走 `run_live_agent`（:293-299）；
- `third_party.py`：Dify/Coze/Dashscope/DeerFlow 等第三方 runner 路径（不入 persona，只解析错误文案）。

### 3.5 ResultDecorateStage（result_decorate/stage.py:21-439）

初始化配置（:23-102）：`reply_prefix`、`reply_with_mention`、`reply_with_quote`、`t2i_word_threshold`（默认 150，下限 50，:32-37）、`t2i_strategy`（local/remote）、`forward_threshold`、TTS `trigger_probability`（:46-56）、**分段回复** `segmented_reply`（词数阈值/正则/分隔词，:58-88）、内容安全复查（:91-99）、`display_reasoning_text`（:101-102）。

装饰项：思考内容展示（reasoning）、TTS 转语音、T2I 转图片、转发（超阈值）、@/Reply 前缀、分段发送（`_split_text_by_words` :104-110）。

### 3.6 RespondStage

- 最终发送；`OnDecoratingResultEvent` 可在发送前再拦截（result_decorate/stage.py:159-189 附近）。

## 4. 并发控制

### 4.1 SessionLockManager（session_lock.py:8-55）

- **两级结构**：外层 `SessionLockManager` 按事件循环（`WeakKeyDictionary[event_loop, manager]`）隔离（:33-52）——避免跨 loop 的 asyncio.Lock 误用；
- 内层 `_PerLoopSessionLockManager`：`defaultdict(asyncio.Lock)` + 引用计数（:11-30），计数归零自动 pop（:28-30），无泄漏；
- 单例 `session_lock_manager`（:55）。

### 4.2 follow-up 严格序（process_stage/follow_up.py:1-234）

- 全局表：`_ACTIVE_AGENT_RUNNERS`（UMO → runner，:11）、`_FOLLOW_UP_ORDER_STATE`（UMO → 状态机，:12-19）；
- **捕获条件**（`try_capture_follow_up` :162-204）：同 UMO、同发送者、runner 未 stop；
- **捕获时即分配序号**（`_allocate_follow_up_order` :81-90）——按到达顺序而非唤醒顺序；
- 状态：`pending → active → finished/consumed`（:16-17）；
- **队首放行**（`_activate_and_wait_follow_up_turn` :112-130）：`asyncio.Condition` 等待 `next_turn == seq`——后续消息阻塞等前序；
- 完成推进（:63-78 `_advance_follow_up_turn_locked`、:133-148 `_finish_follow_up_turn`）；状态空 + 无 active runner → 释放 UMO 状态（:108-109、:147-148）；
- runner 侧消费：`FollowUpTicket`（tool_loop_agent_runner.py:95-125）——当前轮次结束后按序注入（`_merge_follow_up_notice` 附带 SYSTEM NOTICE 提示优先处理用户插话）。

### 4.3 ActiveEventRegistry（active_event_registry.py:10-67）

- UMO → 活跃事件集合（:16-17）；
- `stop_all`（:28-47）：stop 事件传播（/reset 等场景终止同会话旧事件）；
- `request_agent_stop_all`（:49-64）：只置 `agent_stop_requested`，**不中断事件传播**——历史保存等后续流程仍可执行；
- pipeline `execute` 注册/注销（scheduler.py:87、:98）。

## 5. 上下文构建与压缩

### 5.1 历史加载与注入

- `Conversation.content` JSON → `req.contexts`（astr_main_agent.py:1404-1405、:1538）→ `bind_checkpoint_messages` 还原（agent/message.py:327-342）；
- 附加注入：persona（`_ensure_persona_and_skills`）、知识库结果/系统提醒（`extra_user_content_parts`，用户消息侧）。

### 5.2 ContextManager（context/manager.py:10-121）

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

### 5.3 群聊上下文注入

`GroupChatContext`（builtin_stars/astrbot/group_chat_context.py:41-302）：每 UMO 内存环形 deque 最多 1000 条原始消息（`DEFAULT_GROUP_MESSAGE_MAX_CNT` :38、可配 `group_message_max_cnt` :71-77），注入格式 `[昵称/时间]: 内容` 包在 `<system_reminder>...BEGIN CONTEXT...END CONTEXT...`（:31-37），受 `provider_ltm_settings.group_icl_enable` 控制（:140-239）；图像 caption：`get_image_caption`（:88-108）用独立 provider（可指定 `image_caption_provider_id`）为群消息图片生成描述并入上下文；主动回复 `active_reply`（:64-69、110-128）：概率触发（`possibility_reply` 随机 < `possibility_reply` 概率）、群聊限定、`is_at_or_wake_command` 不触发、白名单过滤。

## 6. 设计取舍与已确认边界

### 6.1 已确认的设计（代码事实）

- **每消息一任务、无全局并发调度**：吞吐靠 asyncio 并发，顺序性靠 UMO 锁与 follow-up 队列，跨会话天然并行；
- **洋葱模型统一收尾**：LLM 流式输出在 Process 阶段挂起，Respond 先发，收尾（历史保存等）后执行——单条事件单流水线无跨阶段状态泄漏；
- **follow-up 严格序**：捕获时分配序号 + Condition 队首放行，避免并发唤醒顺序漂移（注释 "avoid wake-order drift" :156）；
- **stage 顺序硬编码**：STAGES_ORDER 即约束，新增阶段必须显式加入；
- **配置粒度多租户**：`pipeline_scheduler_mapping` 按 conf_id 隔离；
- **agent 停止两态**：`stop_event`（硬断）vs `agent_stop_requested`（软停，保历史）——语义分离。

### 6.2 取舍（平衡决策）

- **阶段无并发上限 + UMO 锁**：同会话串行化，但全局无背压（事件队列无限 Queue）；
- **RateLimit stall 阻塞**：限流窗口内整条流水线挂起（消息排队），不丢弃但堆积；
- **内存群上下文 + 可选持久化**：1000 条环形缓冲实时性优先，持久化走独立表并暴露工具；
- **unique_session 默认关**：群聊默认共享对话（成本低），按人隔离需显式开启。

### 6.3 静态推断的潜在问题（源码推断，未实测）

1. **长会话低频访问**：`max_context_length=-1` 默认不按轮次限制，依赖 82% token 阈值触发压缩，低频会话可能长期携带大上下文（每次请求全量发送）；
2. **follow-up 与流式并行**：`enable_streaming` 时 runner 仍在流式输出，follow-up 注入时机的完整行为（tool_loop_agent_runner.py:119-125 区段）未实测；
3. **洋葱递归深度**：每个 AsyncGenerator 阶段都递归展开，含 agent 的 Process 阶段 + 8 层后续阶段嵌套，深链异常栈排查成本高；
4. **EventBus 队列无限**：无背压/丢弃策略，突发流量下内存增长。

（崩溃丢最近对话属于会话持久化侧，记录在会话与消息管理笔记。）

## 7. 未验证事项

1. 未启动实例实测各阶段在真实平台上的时序行为；
2. follow-up 与流式响应并存时的详细交互未逐行核对；
3. `result_decorate` 的 T2I/转发/语音合成完整逻辑未逐行核对（本次仅覆盖初始化与分段回复）；
4. `third_party.py`（Dify/Coze 等）细节未逐行核对；
5. `whitelist_check`、`session_status_check`、`preprocess_stage` 三个阶段本次未深入逐行阅读。

## 8. 关键源码索引

- 事件：`astrbot/core/event_bus.py`（:23-83）
- 流水线：`astrbot/core/pipeline/stage_order.py`（:3-13）、`scheduler.py`（:17-98）、`stage.py`（register_stage）
- 各阶段：`waking_check/stage.py`（:17-248）、`whitelist_check/stage.py`、`session_status_check/stage.py`、`rate_limit_check/stage.py`（stall :74-82）、`content_safety_check/stage.py`、`preprocess_stage/stage.py`、`process_stage/stage.py`、`result_decorate/stage.py`（:21-439）、`respond/stage.py`
- Agent 子阶段：`process_stage/method/agent_sub_stages/internal.py`（session_lock :220）、`third_party.py`、`follow_up.py`（:1-234）
- 并发：`astrbot/core/utils/session_lock.py`（:8-55）、`utils/active_event_registry.py`（:10-67）
- 上下文：`astrbot/core/agent/context/manager.py`（:10-121）、`truncator.py`、`token_counter.py`、`compressor.py`、`config.py`
- 群上下文：`astrbot/builtin_stars/astrbot/group_chat_context.py`（:31-302）
- 配置：`astrbot/core/config/default.py`（wake_prefix、max_context_length :127、context_limit_reached_strategy :139、group_message_history_max_cnt）
