# AstrBot 对话请求与上下文调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`8ea8ce613a0bee4ddb48b21490afe23418277c75`（分支：`master`）
>
> 调查方式：直接阅读源码（事件总线、流水线调度、各阶段实现、并发工具、上下文管理、Agent 构建与 runner、WebChat 流式链路），行号按当前 HEAD 逐一核对
>
> 调查范围：事件总线与任务模型、流水线调度与各阶段、并发控制与 follow-up、上下文构建与压缩、群聊上下文注入、唤醒与装饰、停止/重试/续写语义；会话持久化语义与界面分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的一条入站消息经 `EventBus` 从异步队列取出，为每条消息创建独立 asyncio 任务，交给按配置 ID 映射的 `PipelineScheduler` 按固定 9 阶段顺序处理。并发控制不靠阶段限流，而靠 UMO 粒度的 `session_lock` 串行化 LLM 请求 + 严格有序的 follow-up 队列。

- **流水线 9 阶段**（stage_order.py:3-13）：
  1. `WakingCheck`：唤醒判定与插件匹配；
  2. `WhitelistCheck`：白名单检查；
  3. `SessionStatusCheck`：会话状态检查；
  4. `RateLimit`：限流；
  5. `ContentSafety`：内容安全；
  6. `PreProcess`：预处理；
  7. `Process`：主处理（Agent 或插件/第三方 runner）；
  8. `ResultDecorate`：结果装饰（@/回复前缀、T2I、TTS、分段、转发、安全复查）；
  9. `Respond`：回复发送。
- **洋葱模型调度**（scheduler.py:36-80）：阶段 `process()` 返回普通协程 → 基线继续；返回 `AsyncGenerator` → 挂起，递归执行后续阶段，后续阶段完成后回到 yield 点执行后置逻辑（LLM 请求阶段用此模式：先让 Respond 发送，再回来做收尾）；`event.stop_event()` 在任意点截断传播。
- **EventBus 每事件一任务**（event_bus.py:37-63）：`asyncio.create_task` 创建任务，`_pending_tasks` 强引用防 GC，完成回调暴露未捕获异常。
- **并发控制**：`SessionLockManager`（session_lock.py:8-55）按事件循环隔离、UMO 粒度的 `asyncio.Lock` + 引用计数自动清理，包裹整个 LLM 请求（internal.py:220）。
- **follow-up 严格序**（process_stage/follow_up.py:1-248）：Agent 运行期间同发送者的新消息捕获为 `FollowUpTicket`，在捕获时分配单调序号，`asyncio.Condition` 只放行队首；序号状态按 UMO 维护、无残留时自动释放。
- **上下文压缩两层**（context/manager.py:45-121）：先轮次截断（enforce_max_turns≠-1），再 token 压缩（82% 阈值触发，`TruncateByTurnsCompressor` 或 `LLMSummaryCompressor`，压缩后仍超限折半兜底）。

## 系统边界与生成任务主链

```text
平台适配器收到消息 → 构造 AstrMessageEvent（platform:message_type:session_id）
  → event_queue.put() → EventBus.dispatch 无限循环消费（event_bus.py:39-54）
  → 按 conf 映射取 PipelineScheduler → asyncio.create_task(scheduler.execute(event))
  → PipelineScheduler.execute（scheduler.py:82-100）
      active_event_registry.register(event)
      → _process_stages(event, from_stage=0)（洋葱模型，:36-80）
          WakingCheckStage（唤醒判定 + 插件 handler 匹配 + unique_session 改写 session_id）
          WhitelistCheckStage / SessionStatusCheckStage / RateLimitStage / ContentSafetyCheckStage
          PreProcessStage
          ProcessStage → AgentRequestSubStage → InternalAgentSubStage
                          （session_lock 包裹 → build_main_agent → agent 循环）
                          或插件 handler / 第三方 runner
          ResultDecorateStage（@/回复前缀、T2I、TTS、分段回复、转发、安全复查）
          RespondStage（发送）
      finally: event.cleanup_temporary_local_files(); active_event_registry.unregister（:98-100）
```

边界：会话/对话的持久化语义在会话与消息管理；项目自带 WebChat 与管理界面在 Chat UI；工具执行循环内部（工具发现、执行、审批）属于 Agent 工具类目，本笔记只记录注入点与交接契约。

## 1. 提交入口、任务对象与状态机

- **入口**：`EventBus.dispatch()`（event_bus.py:26-54）从 `event_queue` 取事件，按 UMO 解析配置；无对应 `PipelineScheduler` 时记录错误并忽略，否则为该事件创建独立任务交给该调度器。构造时注入的 `pipeline_scheduler_mapping` 按配置 ID 区分调度器——多租户配置各自独立 pipeline。
- **任务模型**：没有显式任务 ID/任务表；"任务"就是 per-event 的 asyncio.Task + 事件对象本身。WebChat 侧有 `message_id`（UUID）与 `ChatRunState.run_id`（chat_service.py:1137-1166），IM 平台以平台消息 ID 为身份。
- **活跃事件注册表**：`ActiveEventRegistry`（active_event_registry.py:11-94）维护 UMO 到活跃事件集合的映射，供停止/重置场景定位同会话事件；pipeline 进出时注册与注销（scheduler.py:89、:100）。
- **运行状态**：无集中状态机；运行中状态分散在 runner（`AgentRunner`）、`activeConnections`（前端）与 `ChatRunState.status`（webchat 侧 running/completed/stopped/failed，chat_service.py:1042-1049）。
- **消息日志**：`_print_event`（event_bus.py:65-83）以 `[配置名] [平台ID(平台名)] 发送者名/发送者ID: 消息概要` 记录，extra `category=user_chat`。

## 2. 历史选择与上下文拼装顺序

上下文在 `build_main_agent`（astr_main_agent.py:1375+）中拼装，最终载体是 `ProviderRequest`（req.contexts + req.extra_user_content_parts）：

1. **历史**：`Conversation.content` JSON → `req.contexts`（astr_main_agent.py:1404-1405、:1536-1538），对话不存在则惰性新建（`_get_session_conv` :261-275）。
2. **prompt 前缀**：`prompt_prefix` 先套用户输入（`_apply_prompt_prefix`，:1002 调用）。
3. **persona**：`_ensure_persona_and_skills`（:1010 调用，定义 :499+）按会话规则/对话 persona 解析（解析顺序见会话与消息管理笔记 §8），注入 system prompt 与 begin_dialogs，并把 persona 的工具/技能装配进 `req.func_tool`。
4. **媒体附件**：图片（压缩后路径入 `req.image_urls` + 文本占位 part）、录音、文件、视频逐组件转文件并附文本说明（:1420-1447）；回复引用消息内的媒体同样处理（:1448-1534，含 fallback 图片提取与 `max_quoted_fallback_images` 上限 :1500-1526）。
5. **引用消息正文**：`_process_quote_message`（:1023-1033）。
6. **系统提醒块**：群名（`group_name_display`）、当前时间（`datetime_system_prompt`）等拼成 `<system_reminder>...</system_reminder>` 注入 `extra_user_content_parts`（:960-988）。
7. **群聊上下文**：`on_req_llm` hook 把环形缓冲中该条消息之前的原始消息拼成 `<system_reminder>...BEGIN CONTEXT...END CONTEXT...` 块追加（group_chat_context.py:160-195，详见 §9）。
8. **知识库/联网**：`_apply_kb`（:278+，`kb_agentic_mode` 开启时走工具化检索）、web search 由工具在 agent 循环中触发。

顺序上 system prompt 在前、历史在 contexts、动态上下文全部追加到 `extra_user_content_parts` 末尾（对多模态 provider 由 runner 层合并进最终消息体，tool_loop_agent_runner.py:500-514 的 `_iter_llm_responses` 载荷）。

## 3. 预算、截断、摘要与压缩

`ContextManager`（context/manager.py:45-121）：

```text
process(messages, trusted_token_usage):
  1. enforce_max_turns != -1 → truncate_by_turns（轮次截断，保留最新 N 轮，:60-65）
  2. max_context_tokens > 0：
       total = count_tokens(messages, trusted_token_usage)
       should_compress 命中（usage_rate > 0.82）→ _run_compression（:67-77）
_run_compression（:83-121）:
  compressor(messages)          # LLMSummaryCompressor 或 TruncateByTurnsCompressor
  double check：仍超限 → truncate_by_halving（折半兜底，:112-119）
```

- **压缩器选择**（manager.py:31-43）：按优先级依次为自定义压缩器、存在 LLM 压缩 provider 时的摘要压缩器（`keep_recent_ratio` 默认 0.15）、否则按轮截断器。
- **阈值**：上下文用量超过 82% 时触发压缩（`compression_threshold: float = 0.82`；compressor.py:66、:77-93、:131、:158-174）。
- **摘要压缩细节**（compressor.py:115-310）：
  - 按轮切分（round_utils），按 `keep_recent_ratio` 预算保留最近整轮（:176-204，比例钳制 0-0.3 :144）；
  - 最新用户消息所在轮始终保留（:228-238）；
  - 总结失败返回原消息（:275-286）；
  - 结果由 system 消息 + 摘要对 + 最近轮组成（:288-309）。
- **截断器**（truncator.py:15-202）：保护 system 消息、保证 system 后跟 user、修复 tool_call/tool 配对（注释说明 Gemini 严格模式 :56-58）、按轮截断后丢弃最旧 N 轮，仍超限则折半。
- **token 估算**（token_counter.py:34-78）：优先 `trusted_token_usage`；图片 765 / 音频 500 定额；中文字符 0.6、其他 0.3 估算。
- **异常兜底**：任何压缩错误返回原消息（manager.py:79-81）。
- **默认配置**（config/default.py:127-139）：
  - `context_limit_reached_strategy: "llm_compress"`（压缩策略）；
  - `max_context_length: -1`（默认不限制）；
  - `llm_compress_keep_recent_ratio: 0.15`（摘要保留最近轮比例）。
  注意 `internal.py:94-96` 读取该策略时的兜底默认值是 `"truncate_by_turns"`（配置键始终存在，实际生效以配置为准）。

## 4. SDK、Provider、模型与协议交接

- **交接点**：`build_main_agent`（astr_main_agent.py:1375-1416）先选择 provider——无 provider 时置 LLM 错误消息并返回，否则构造 `ProviderRequest` 并填充 `req.contexts`；模型显式选择经 `event.get_extra("selected_model")` 写入 `req.model`（WebChat 前端可传），否则由 provider 实例的默认模型决定。
- **Provider 解析**：按 UMO 路由到会话/配置绑定的 provider（`Context.get_using_provider`，`umop_config_router` 负责 UMO 到配置 profile 的路由）；fallback 链（astr_main_agent.py:1306-1338）对 `fallback_chat_models` 列表去重；图像模态不支持时切换 `_select_image_chat_provider`（:1341-1372）。
- **协议 Adapter 接管**：`InternalAgentSubStage` 只持有 `ProviderRequest` 与 `Provider` 实例，具体协议（OpenAI 兼容/Google/Anthropic 等）由 `astrbot/core/provider` 下的 provider 实现与 `func_tool` 序列化接管；runner 把上下文、额外内容、工具与中断信号组成 `text_chat` 载荷（tool_loop_agent_runner.py:500-514 的 `_iter_llm_responses`）。
- **第三方 runner**：`agent_runner_type` 非 local 时改用 `ThirdPartyAgentSubStage`（agent_request.py:29-34），Dify/Coze/Dashscope/DeerFlow 等路径集中在 `agent_sub_stages/third_party.py`（本次未逐行核对，见未验证事项）。
- **会话级开关**：`AgentRequestSubStage.process` 先检查 provider enable（agent_request.py:37-41）与 `SessionServiceManager.should_process_llm_request`（:43-47，会话规则可关闭 LLM 能力）。

## 5. 流式事件、缓冲、节流与顺序

- **生成器链**：`run_agent` 生成器逐段产出文本、工具调用、推理与媒体；`InternalAgentSubStage.process` 把生成器放进 `MessageEventResult.set_async_stream`（internal.py:346-359），`RespondStage` 检测 `STREAMING_RESULT` 后调 `event.send_streaming`（respond/stage.py:211-225）。
- **IM 平台**：由各适配器实现 `send_streaming`（平台侧节流/合并，不在流水线内）。
- **WebChat**：
  - 组件入队：`WebChatMessageEvent._send` 把 Plain/Image/Record/File/Json 各组件转成带 `message_id` 的事件写入 per-request 的 back_queue（webchat_event.py:29-163）；
  - 单消费协程：`_consume_chat_run`（chat_service.py:897-1088）按组件类型归并、分批持久化、以 revision 广播给 SSE/WS 订阅者（:774-793）；
  - 收尾：pipeline 结束时 `send(None)` 发 `end` 事件（webchat_event.py:165-180，scheduler.py:94-95 触发）。
- **顺序保证**：back_queue 是 asyncio.Queue，单消费协程天然有序；订阅者超限被丢弃（慢流断开重连，chat_service.py:787-792）。前端按类型把增量合并到 botRecord（useMessages.ts:990-1160）。
- **无全局缓冲层**：流水线内不做跨事件缓冲/节流，顺序性靠队列与锁（§8）。

## 6. 完成、异常、半截流与最终回写

- **收口位置**：`InternalAgentSubStage.process` 的 yield 之后（internal.py:329-417）依次执行：
  1. Live Mode 保存（:331-342）；
  2. 流式结束时补发 `STREAMING_FINISH` 结果（:360-378），非流式走循环（:379-389）；
  3. `trace.record("astr_agent_complete")`（:393-397）；
  4. 异步写 `ProviderStat`（:399-406）；
  5. 历史保存（:409-417）。
- **历史保存 `_save_to_history`**（internal.py:452-539）：
  - 跳过首条 system（:466-469）与 `_no_save` 消息（:470-472）；
  - 用户中止时保留半截输出并补 assistant 记录（:477-504；:521-527 的 abort 标注已注释掉）；
  - LLM 空回复且无工具结果不保存（:506-512）；
  - `token_usage` 取最后一次 LLM 响应的 usage（:529-539）；
  - 带 checkpoint 时追加 `CheckpointMessageSegment`（:474-486、:514-519）。
- **异常路径**：process 顶层 except 发错误回复（persona 自定义错误消息优先，internal.py:430-438）；`_record_internal_agent_stats` 异步写 ProviderStat（:548-588，status=aborted/error/completed）。
- **响应防重复**：RespondStage 对 `send_message_to_user` 已发过的同文本跳过（respond/stage.py:182-204），并对 `_streaming_finished` 事件防二次发送（:176-181）。
- **洋葱收尾**：历史保存发生在 Respond 发送之后（yield 返回点），即"先发送、后落盘"；`finally` 中 `unregister_active_runner`（internal.py:426-428）、`stop_typing` 与 follow-up 状态收尾（:439-450）。

## 7. 停止、重试、续写与重新生成

- **两级停止**：
  - `stop_event`（硬断）：`ActiveEventRegistry.stop_all`（active_event_registry.py:52-71）置事件停止并截断流水线传播（/reset 场景用，conversation.py:182、:238）；
  - `agent_stop_requested`（软停）：`request_agent_stop_all`（:73-91）**不中断事件传播**——历史保存等后续流程仍可执行，同时调用注册的 agent_stop 回调立即取消 runner（follow_up.py:39-58 挂载 `runner.request_stop`）。
- **runner 侧中断**：`_await_or_stop`（tool_loop_agent_runner.py:461-498）把进行中的 LLM 请求/上下文压缩与 abort 信号竞速，abort 先到则取消操作并返回 None；工具执行中断走 `_ToolExecutionInterrupted`（:102-103）。
- **入口**：`/stop` 命令（conversation.py:196-220）按 runner 类型走 stop_all（第三方）或 request_agent_stop_all（本地）；WebChat 停止按钮 → `/chat/sessions/{id}/stop` → `request_agent_stop_all`（chat_service.py:1204-1213）。
- **重试/续写/重新生成**：这些是 WebChat 前端 + ChatService 的机制（数据语义见会话与消息管理笔记 §4）：编辑用户消息后自动续写（continueEditedMessage）、bot 消息重生成（regenerate → 新 checkpoint 重走生成）；IM 平台无对应 UI，仅 `/reset` 清历史后重发。Provider fallback 是请求内自动重试（`request_max_retries`，tool_loop_agent_runner.py 载荷 :510），与用户手动重试不同。
- **follow-up 消费**：runner 在当前轮次结束后把积压的 follow-up 文本以 `[SYSTEM NOTICE]` 提示合并进下一轮内容（tool_loop_agent_runner.py:702-721，使用点 :1103），提示模型优先处理用户插话。

## 8. 队列、多会话并发与后台生成

RateLimit 的等待队列已改为以完整 `unified_msg_origin` 分桶，因而不同平台会话不会共用限流计数（rate_limit_check/stage.py:57-82）。cron 与后台工具唤醒主 Agent 时会保留结构化会话历史，并从当前 Provider 配置读取、校验 `max_agent_step` 后传给 runner；它们不再绕过常规的上下文截断与步数上限（astr_agent_tool_exec.py:548-596；cron/manager.py:444-487）。

- **SessionLockManager**（session_lock.py:8-55）：外层按事件循环隔离（`WeakKeyDictionary[event_loop, manager]`，避免跨 loop 误用 asyncio.Lock）；内层 `_PerLoopSessionLockManager` 用 `defaultdict(asyncio.Lock)` 加引用计数，计数归零自动清理；单例。锁包住 `build_main_agent` 与整个 agent 运行（internal.py:220-425）——**同 UMO 串行化 LLM 请求，跨会话天然并行**。
- **follow-up 严格序**（follow_up.py:16-218）：
  - 捕获条件 = 同 UMO + 同发送者 + runner 未 stop（:176-218）；
  - 捕获时即分配单调序号（`_allocate_follow_up_order` :95-104，按到达顺序而非唤醒顺序）；
  - 状态流转 pending → active → finished/consumed（队首放行 :126-144、消耗 :107-123、完成 :147-162）；
  - 无残留状态且无活跃 runner 时释放 UMO 状态（:121-123、:161-162）；
  - monitor 任务在 ticket 解决时立即推进序号，避免唤醒顺序漂移（:165-173，注释 "avoid wake-order drift" :170）。
- **EventBus 无背压**：`event_queue` 是无限 asyncio.Queue（未限制 maxsize），突发流量下内存增长；每事件一任务，无全局并发上限。
- **限流**：`RateLimitStage`（rate_limit_check/stage.py:57-89）按会话 ID 做 Fixed Window 计数；超限默认阻塞等待下个窗口（`asyncio.sleep`，:74-82），`discard` 策略才丢弃（:83-89）。
- **后台生成**：cron 任务与 background 工具任务复用 `persist_agent_history` 回写（utils/history_saver.py:9-31；调用点 astr_agent_tool_exec.py:51、cron/manager.py:21），不经过 RespondStage；WebChat 的"后台生成"实际是同一会话多 run 并行（chat_service.py:518-519 的 chat_runs 表），前端以 active_runs 恢复。

## 9. Agent、工具、知识库与附件注入点

- **Agent 构建**：`build_main_agent`（internal.py:231-236 调用，apply_reset=False）产出 `MainAgentBuildResult`（含 agent runner、provider request、provider 与重置协程）；Live Mode 走 `run_live_agent`（internal.py:293-329，action_type="live" 时启用 TTS 处理）。
- **工具目录**：persona 的 tools/skills 决定装配（`_ensure_persona_and_skills`）；会话插件过滤在构建时生效（`_plugin_tool_fix`，astr_main_agent.py:1042-1068，MCP 工具与无归属工具保留）；`OnLLMRequestEvent` hook 可拦截止步（internal.py:269-272）；api_base 黑名单拦截（internal.py:253-262，名单 :544-545）。
- **知识库**：`_apply_kb`（astr_main_agent.py:278+）——非 agentic 模式在构建时检索注入，`kb_agentic_mode` 开启时转工具调用；会话级知识库配置在删除会话时级联清理（见会话与消息管理笔记 §8）。
- **群聊上下文注入**（group_chat_context.py:41-239 + builtin_stars/astrbot/main.py）：
  - 记录：`on_message` handler（main.py:196-227）按 `group_icl_enable` 开关把群消息格式化为 `[昵称/时间]: 内容`，写入每 UMO 的内存环形缓冲（默认上限 1000 条，可配 `group_message_max_cnt`）；命令消息不记录（handlers_parsed_params 非空，:223）；
  - 注入：`decorate_llm_req`（on_llm_request hook，main.py:325-334）→ `on_req_llm`（group_chat_context.py:160-195）把该条消息之前的历史拼成 `<system_reminder>...--- BEGIN CONTEXT---...--- END CONTEXT ---...</system_reminder>` 追加到 `req.extra_user_content_parts`（:192-195）；
  - 图像 caption：`get_image_caption`（:88-108）用独立 provider（可指定 `image_caption_provider_id`）生成描述入上下文（:204-219）；
  - 主动回复：`need_active_reply`（:110-128）——群聊限定、被 @ 或唤醒命令不触发、白名单过滤、概率触发（`possibility_reply` 随机值低于阈值时）；触发后直接 `request_llm` 复用当前对话（main.py:229-268）；
  - 清理：`/reset`、`/new` 置 `_clean_group_context_session`，`after_message_sent` 中 `remove_session`（main.py:336-344）。
- **外部能力注入点小结**：persona/知识库/引用解析在 `build_main_agent` 构建期；群上下文/系统提醒/图片描述在 `on_llm_request` hook 期（req 拼装完成前）；web search、文件操作、cron、联网等其余能力全部以工具形式在 agent 循环内由模型调用（Agent 工具类目）。

## 10. 退出恢复、日志与已确认边界

- **退出/重启**：pipeline task 生命周期内无持久化 checkpoint；服务重启丢弃全部内存运行态（群环形缓冲、ChatRunState、follow-up 序号状态）。WebChat 运行中 run 可在前端刷新后经 `/chat/runs/{id}/stream` 快照恢复（数据语义见会话与消息管理笔记 §3），IM 平台无恢复入口。
- **可观测性**：`event.trace` 记录 `sel_persona`（astr_main_agent.py:658-659）、`astr_agent_prepare`（internal.py:282-291）、`astr_agent_complete`（:393-397）等阶段，Dashboard TracePage 以 SSE 展示；消息日志 category=user_chat（event_bus.py:75-83）；`ProviderStat` 表按 UMO/conversation 关联用量（internal.py:548-588，/stats 命令与 StatsPage 消费）。
- **已确认边界**：阶段顺序硬编码于 `STAGES_ORDER`（未注册阶段抛 ValueError，scheduler.py:23-25）；RateLimit 超限默认阻塞而非丢弃；EventBus 无限队列无背压；`third_party.py`（Dify/Coze 等）路径不构建 persona 且错误文案单独解析（本次未逐行核对）。

## 11. 未验证事项

1. 未启动实例实测各阶段在真实平台上的时序行为（洋葱递归、流式、停止竞态均为静态确认）。
2. follow-up 与流式响应并存时的完整交互未逐行核对（消费点在 tool_loop_agent_runner.py:1103，边界场景未实测）。
3. `result_decorate` 的 T2I/转发/语音合成完整逻辑未逐行核对（本次仅覆盖初始化、内容安全复查与分段回复入口，result_decorate/stage.py:104-220 之后未深入）。
4. `third_party.py`（Dify/Coze 等第三方 runner）细节未逐行核对。
5. `whitelist_check`、`session_status_check`、`preprocess_stage` 三个前置阶段本次仅确认存在与职责（stage_order.py:5-9），未逐行阅读。
6. 长会话低频访问携带大上下文（`max_context_length=-1` 默认下依赖 82% token 阈值触发压缩）为静态推断，未实测。
7. Provider fallback 与模态切换在真实多 provider 配置下的行为未运行验证。

## 12. 关键源码索引

- 事件：`astrbot/core/event_bus.py`（:26-83）
- 流水线：`astrbot/core/pipeline/stage_order.py`、`scheduler.py`、`stage.py`（register_stage/registered_stages）
- 各阶段：`waking_check/stage.py`、`whitelist_check/stage.py`、`session_status_check/stage.py`、`rate_limit_check/stage.py`、`content_safety_check/stage.py`、`preprocess_stage/stage.py`、`process_stage/stage.py`、`result_decorate/stage.py`、`respond/stage.py`
- Agent 子阶段：`process_stage/method/agent_request.py`、`agent_sub_stages/internal.py`、`agent_sub_stages/third_party.py`、`process_stage/follow_up.py`
- 并发：`astrbot/core/utils/session_lock.py`、`utils/active_event_registry.py`
- 上下文：`astrbot/core/agent/context/manager.py`、`truncator.py`、`token_counter.py`、`compressor.py`、`config.py`
- Agent 构建：`astrbot/core/astr_main_agent.py`（_get_session_conv :261-275、build_main_agent :1375+）、`agent/runners/tool_loop_agent_runner.py`
- 群上下文：`astrbot/builtin_stars/astrbot/group_chat_context.py`、`builtin_stars/astrbot/main.py`
- 配置：`astrbot/core/config/default.py`（context_limit_reached_strategy :127、max_context_length :139、provider_ltm_settings :224-230）
