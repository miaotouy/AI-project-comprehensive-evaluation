# AstrBot 对话请求与上下文调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：直接阅读源码（事件总线、流水线调度、各阶段实现、并发工具、上下文管理、Agent 构建与 runner、WebChat 流式链路），行号按当前 HEAD 逐一核对
>
> 调查范围：事件总线与任务模型、流水线调度与各阶段、并发控制与 follow-up、上下文构建与压缩、群聊上下文注入、唤醒与装饰、停止/重试/续写语义；会话持久化语义与界面分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的一条入站消息经 `EventBus` 从异步队列取出，为每条消息创建独立 asyncio 任务，交给按配置 ID 映射的 `PipelineScheduler` 按固定 9 阶段顺序处理。并发控制落在 UMO 粒度：`session_lock` 串行化同会话的 LLM 请求，同发送者的新消息进入严格有序的 follow-up 队列；阶段本身不做并发限流。

调度器把一条入站事件依次交给固定的 9 个阶段，顺序定义在 `stage_order.py:3-13`：

| 阶段 | 职责 |
| --- | --- |
| `WakingCheck` | 唤醒判定与插件匹配 |
| `WhitelistCheck` | 白名单检查 |
| `SessionStatusCheck` | 会话状态检查 |
| `RateLimit` | 限流 |
| `ContentSafety` | 内容安全 |
| `PreProcess` | 预处理 |
| `Process` | 主处理（Agent 或插件/第三方 runner） |
| `ResultDecorate` | 结果装饰（@/回复前缀、T2I、TTS、分段、转发、安全复查） |
| `Respond` | 回复发送 |

- **洋葱模型调度**：调度器先调用阶段自己的 `process()`；返回普通协程就继续执行下一阶段，返回异步生成器则挂起当前阶段，递归跑完后续阶段后再回到 yield 点执行后置逻辑。LLM 请求阶段用的就是后一条路径——让 Respond 先把回复发出去，再回来做收尾。任何阶段都可以调用 `event.stop_event()` 截断后续传播（`scheduler.py:38-82`）。
- **EventBus 每事件一任务**：事件总线为每个入站事件调用 `asyncio.create_task` 启动独立任务，用 `_pending_tasks` 持有强引用避免被回收，任务完成回调负责暴露未捕获的异常。平台被移除时，`stop_platform` 停掉该平台的全部活跃事件（`event_bus.py:55-102`）。
- **并发控制**：`SessionLockManager` 以事件循环为外层隔离、以 UMO 为粒度维护 `asyncio.Lock`，引用计数归零后自动清理；这把锁包住整个 LLM 请求（`session_lock.py:8-55`；`internal.py:220`）。
- **follow-up 严格序**：Agent 运行期间，同一发送者的新消息被捕获成 `FollowUpTicket`，并在捕获那一刻分配单调递增的序号；放行由 `asyncio.Condition` 控制，只放队首。序号状态按 UMO 维护，没有残留时自动释放（`process_stage/follow_up.py:1-248`）。
- **上下文压缩两层**：`ContextManager` 先按轮次截断（`enforce_max_turns` 不为 -1 时生效），再按 token 压缩——用量越过 82% 阈值时交给摘要压缩器或按轮截断器，压缩后仍然超限就折半兜底（`context/manager.py:45-121`）。
- **Agent Runner 配置随 profile 生效**：Local runner 的 provider 与 fallback、Persona、安全模式、上下文压缩、重试、最大步骤、工具 schema 与超时统一取自 `agent_runner.config`。普通聊天、cron 与后台结果唤醒走同一套解析函数，三条链因此共用一份默认值（`astrbot/core/config/agent_runner.py:9-36,102-134`；`internal.py:71-145`）。
- **构建入口在包内**：Agent 构建由 `astr_main_agent` 包承担，`build_main_agent` 负责整体编排，请求收集与提示拼装落在 `request.py`，其余能力按主题拆成 persona、知识库、媒体、provider 选择、工具过滤、联网、子代理、工作区与 computer use 等模块（`astr_main_agent/builder.py:57`；`request.py:208-490`）。
- **会话名与发送者自动记录**：唤醒阶段由 `UmoAutoNameRecorder` 用有界缓存加后台写库的方式，记录发生变化的会话名与发送者名，落到 `umo_aliases` 与 `umo_senders` 两张表，写库过程不阻塞唤醒判定（`waking_check/umo_auto_name.py:19-40`）。WebChat 会话在首次对话时另由标题生成函数调用当前 chat provider 生成标题，回写到会话行（`agent_sub_stages/webchat.py:11-59`）。
- **当前图片在模型调用前统一准备**：入站与引用图片先本地化，再按最长边和 JPEG 质量转换；插件 hook 改写请求后会再次准备新增图片。CUA 为保持坐标一致跳过普通缩放，只对超大输入告警；不可恢复的图片会被移除，纯图片请求退化为 `[Image unavailable]`（`astrbot/core/utils/image_input.py:17 起`；`astr_main_agent/builder.py:156-178`）。

## 系统边界与生成任务主链

```text
平台适配器收到消息 → 构造 AstrMessageEvent（platform:message_type:session_id）
  → event_queue.put() → EventBus.dispatch 无限循环消费（event_bus.py:55-76）
  → 按 conf 映射取 PipelineScheduler → asyncio.create_task(scheduler.execute(event))
  → PipelineScheduler.execute（scheduler.py:84-102）
      active_event_registry.register(event)
      → _process_stages(event, from_stage=0)（洋葱模型，:38-82）
          WakingCheckStage（唤醒判定 + 插件 handler 匹配 + unique_session 改写 session_id + 会话/发送者名异步记录）
          WhitelistCheckStage / SessionStatusCheckStage / RateLimitStage / ContentSafetyCheckStage
          PreProcessStage
          ProcessStage → AgentRequestSubStage → InternalAgentSubStage
                          （session_lock 包裹 → build_main_agent → agent 循环）
                          或插件 handler（context_utils.call_handler）/ 第三方 runner
          ResultDecorateStage（@/回复前缀、T2I、TTS、分段回复、转发、安全复查）
          RespondStage（发送）
      finally: event.cleanup_temporary_local_files(); active_event_registry.unregister（:100-102）
```

边界：会话/对话的持久化语义在会话与消息管理；项目自带 WebChat 与管理界面在 Chat UI；工具执行循环内部（工具发现、执行、审批）属于 Agent 工具类目，本笔记只记录注入点与交接契约。

## 1. 提交入口、任务对象与状态机

- **入口**：`EventBus.dispatch()` 从 `event_queue` 取事件，按 UMO 解析配置；找不到对应的 `PipelineScheduler` 就记录错误并忽略，找到则为该事件创建独立任务交给它。调度器映射在构造时注入，按配置 ID 区分，因此多租户配置各自拥有独立 pipeline（`event_bus.py:55-76`）。
- **任务模型**：系统没有显式的任务 ID 或任务表，任务就是每个事件对应的 asyncio 任务加上事件对象本身。WebChat 侧另有 `message_id`（UUID）与 `ChatRunState.run_id`，IM 平台以平台消息 ID 作为身份（`chat_service.py:539 起`）。
- **活跃事件注册表**：`ActiveEventRegistry` 维护从 UMO 到活跃事件集合的映射，停止或重置时据此定位同一会话的事件；pipeline 进入时注册、退出时注销（`active_event_registry.py:11-94`；`scheduler.py:86,100`）。
- **运行状态**：系统没有集中状态机，运行中状态分散在 Agent runner、前端 `activeConnections` 与 WebChat 侧的 `ChatRunState.status` 中，后者取值为 running、completed、stopped、failed。
- **消息日志**：`_print_event` 按 `[配置名] [平台ID(平台名)] 发送者名/发送者ID: 消息概要` 的格式打印，日志的 extra 字段标记 `category=user_chat`（`event_bus.py:137 起`）。
- **外部唤醒事件**：cron、后台任务与插件分别构造 `AgentWakeupEvent` 并调用 `wake_main_agent`，把结构化会话历史送进同一套 9 阶段流水线。唤醒事件不经过平台适配器，`WakingCheck` 阶段直接将其视为已唤醒（`platform/agent_wakeup_event.py:93,110`；`astr_agent_wakeup.py:10-51`）。

## 2. 历史选择与上下文拼装顺序

上下文由 `build_main_agent`（`astr_main_agent/builder.py:57` 起）编排，收集与拼装主体在 `prepare_request`（`request.py:490` 起），最终载体是 `ProviderRequest`（req.contexts + req.extra_user_content_parts）：

1. **原始请求收集**：`collect_initial_request` 读取 Conversation 历史、当前文本、附件与引用，此时保留图片的原始语义；面向模型的图片转换推迟到 InternalAgentSubStage，插件 hook 改写请求后还能再处理一次（`request.py:208-489`）。
2. **prompt 前缀**：用户输入先由 `apply_prompt_prefix` 套上前缀（`request.py:50-65`）。
3. **persona**：Local runner 先从 profile 的 `agent_runner.config.persona` 取默认 Persona 与安全模式，再按会话规则与对话 persona 解析，注入 system prompt、begin dialogs 与能力白名单；安全指令在该模块后续代码段单独处理（`persona.py:32-151`）。
4. **媒体附件**：收集阶段把图片、录音、文件和视频定位成本地引用并附上文本说明；图片随后由 `prepare_request_images` 按模型策略转换，引用图片复用同一准备结果（`builder.py:156-178`；`utils/image_input.py:17 起`；`media.py:87-219`）。
5. **引用消息正文**：由 `append_quoted_content` 把被引用消息的正文追加进请求（`media.py:193 起`）。
6. **系统提醒块**：群名与当前时间等动态信息由 `group_name_display`、`datetime_system_prompt` 拼成 `<system_reminder>...</system_reminder>`，注入 `extra_user_content_parts`（`request.py:66-116`）。
7. **群聊上下文**：`on_req_llm` hook 从环形缓冲取出该条消息之前的原始消息，拼成 `...BEGIN CONTEXT...END CONTEXT...` 块追加到请求（`group_chat_context.py:160-195`，详见 §9）。
8. **知识库/联网**：知识库由 `apply_knowledge_base` 注入，`kb_agentic_mode` 开启时转为工具化检索；web search 由工具或 `web_search.py` 的应用逻辑在 agent 循环中触发（`knowledge_base.py:17 起`）。

顺序上 system prompt 在前、历史在 contexts、动态上下文全部追加到 `extra_user_content_parts` 末尾（对多模态 provider 由 runner 层合并进最终消息体，tool_loop_agent_runner.py 的 `_iter_llm_responses` 载荷）。

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

- **压缩器选择**：按优先级依次取自定义压缩器、摘要压缩器（只有配置了 LLM 压缩 provider 时才可用，`keep_recent_ratio` 默认 0.15）、按轮截断器（`manager.py:31-43`）。
- **阈值**：上下文用量超过 82% 即触发压缩，阈值常量 `compression_threshold` 默认 0.82（`compressor.py:66-174`）。
- **摘要压缩细节**（`compressor.py:115-310`）：
  - 按轮切分（round_utils），按 `keep_recent_ratio` 预算保留最近整轮，比例被钳制在 0 到 0.3；
  - 最新用户消息所在轮始终保留；
  - 总结失败返回原消息；
  - 结果由 system 消息 + 摘要对 + 最近轮组成。
- **截断器**：保护 system 消息、保证 system 之后紧跟 user、修复 tool_call/tool 配对（注释提到 Gemini 严格模式）、按轮截断时丢弃最旧的 N 轮，仍然超限就折半（`truncator.py:15-202`）。
- **token 估算**：优先采用 `trusted_token_usage`；图片按 765、音频按 500 计定额；中文字符系数 0.6，其他字符 0.3（`token_counter.py:34-78`）。
- **异常兜底**：压缩过程中出现任何错误都返回原消息（`manager.py:79-81`）。
- **默认配置**：压缩相关字段位于 Agent Runner 配置档案，策略默认取 LLM 摘要压缩，轮次不限，最近对话保留 15%。内部子阶段读取该档案，经 `resolve_context_compression_config` 映射回 `context_limit_reached_strategy`、`max_context_length` 等既有构建参数，策略缺失时兜底为按轮截断（`astrbot/core/config/agent_runner.py:21-29`；`internal.py:74-136`）。

## 4. SDK、Provider、模型与协议交接

- **交接点**：`build_main_agent` 先选 provider。没有可用 provider 时，它设置 LLM 错误消息后直接返回；否则构造 `ProviderRequest` 并填好上下文。模型可由事件的 `selected_model` 字段显式指定（WebChat 前端会传），没有指定时用 provider 实例的默认模型（`builder.py:57`；`providers.py:16`）。
- **Provider 解析**：请求按 UMO 路由到会话或配置绑定的 provider。Local runner 从 `agent_runner.config.model` 读取默认 provider、fallback 与请求重试次数；当前 provider 不支持图像模态时，再走图片 provider 的选择分支（`providers.py:31-173`；`provider/manager.py:342-365`；`config/agent_runner.py:9-15`）。
- **协议 Adapter 接管**：`InternalAgentSubStage` 只持有 `ProviderRequest` 与 provider 实例，OpenAI 兼容、Google、Anthropic 等具体协议由 `astrbot/core/provider` 下的实现负责，工具参数序列化交给功能工具模块。runner 把上下文、额外内容、工具与中断信号组装成 `text_chat` 载荷（`tool_loop_agent_runner.py:_iter_llm_responses`）。
- **第三方 runner**：`agent_runner_type` 不为 local 时改由 `ThirdPartyAgentSubStage` 接管，Dify、Coze、Dashscope、DeerFlow 等路径集中在 `agent_sub_stages/third_party.py`（`agent_request.py`；本次未逐行核对，见未验证事项）。
- **会话级开关**：`AgentRequestSubStage.process` 先确认 provider 已启用，再调用 `SessionServiceManager.should_process_llm_request`；会话规则可以关掉该会话的 LLM 能力。

## 5. 流式事件、缓冲、节流与顺序

- **生成器链**：`run_agent` 逐段产出文本、工具调用、推理与媒体；`InternalAgentSubStage.process` 把该生成器交给结果的异步流接口，RespondStage 发现 `STREAMING_RESULT` 后调用 `event.send_streaming` 把流推给平台（`respond/stage.py:194-297`）。
- **IM 平台**：流式发送由各适配器自己实现，节流与合并发生在平台侧，流水线内不做处理。
- **WebChat**：
  - 组件入队：`WebChatMessageEvent._send` 把文本、图片、录音、文件、JSON、按钮行等组件转成带 `message_id` 的事件，写入该请求专属的 back_queue（`webchat_event.py:38-200`）；
  - 单消费协程：`_consume_chat_run` 按组件类型归并，分批持久化，再按 revision 广播给 SSE 与 WS 订阅者（`chat_service.py:1081-1277`）；
  - 收尾：pipeline 结束时向队列发送结束信号，前端据此触发 `end`。
- **顺序保证**：back_queue 是 `asyncio.Queue`，只有单个消费协程，因此入队顺序就是处理顺序；订阅者超出限制时会被丢弃，慢速流断开后由前端重连。前端按组件类型把增量合并进 botRecord（`useMessages.ts`）。
- **全局缓冲**：流水线内没有跨事件缓冲或节流，顺序性由队列与锁保证（§8）。

## 6. 完成、异常、半截流与最终回写

- **收口位置**：生成器在 `InternalAgentSubStage.process` 的 yield 之后恢复执行，依次完成下列收尾（`internal.py:105-444`）：
  1. 保存 Live Mode 状态；
  2. 流式结束时在此补发 `STREAMING_FINISH` 结果，非流式请求走正常循环；
  3. 记录 `astr_agent_complete` 追踪事件；
  4. 异步写 `ProviderStat`；
  5. 保存历史；WebChat 会话缺少标题时另行触发 `generate_conversation_title`（`agent_sub_stages/webchat.py:11-59`）。
- **历史保存 `_save_to_history`**：跳过首条 system 消息与带 `_no_save` 标记的消息；用户中止时保留半截输出并补一条 assistant 记录；LLM 空回复且没有工具结果时不保存；`token_usage` 取最后一次 LLM 响应的 usage；带 checkpoint 时追加 `CheckpointMessageSegment`（`internal.py:445 起`）。
- **异常路径**：`process` 顶层捕获异常后发出错误回复，persona 配置了自定义错误消息时优先使用；`_record_internal_agent_stats` 异步写一条 `ProviderStat`，状态取 aborted、error 或 completed。
- **响应防重复**：`RespondStage` 发现同一文本已经通过 `send_message_to_user` 发过就跳过；收到 `_streaming_finished` 事件时也不再二次发送（`respond/stage.py:201-235`）。
- **洋葱收尾**：历史保存发生在 Respond 发送之后（yield 返回点），即"先发送、后落盘"；`finally` 中注销 runner、停止 typing 与 follow-up 状态收尾。

## 7. 停止、重试、续写与重新生成

- **两级停止**：
  - 硬断通过 `stop_event`：`ActiveEventRegistry.stop_all` 置位事件停止标志并截断流水线传播，`/reset` 走这条路径（`active_event_registry.py:52-71`；`conversation.py:110-142`）；
  - 软停通过 `agent_stop_requested`：`request_agent_stop_all` 保留事件传播，历史保存等后续流程照常执行，同时调用已注册的 agent_stop 回调立即取消 runner；follow-up 层挂载的回调就是 `runner.request_stop`（`active_event_registry.py:73-91`；`follow_up.py:39-58`）。
- **runner 侧中断**：`_await_or_stop` 让进行中的 LLM 请求或上下文压缩与 abort 信号赛跑，abort 先到就取消操作并返回 None；工具执行的中断通过 `_ToolExecutionInterrupted` 抛出（`tool_loop_agent_runner.py:103`、`:472` 起）。
- **停止入口**：`/stop` 命令按 runner 类型分流，第三方 runner 走 `stop_all`，本地 runner 走 `request_agent_stop_all`；WebChat 的停止按钮打到 `/chat/sessions/{id}/stop`，同样进软停入口（`conversation.py:143-168`）。
- **重试、续写与重新生成**：三者都是 WebChat 前端配合 ChatService 实现的机制。编辑用户消息后会触发续写，bot 消息可以重新生成，重生成时带上新的 checkpoint 重走一遍生成过程；IM 平台没有对应界面，只能 `/reset` 清掉历史再发一遍。Provider fallback 属于请求内的自动重试，由 `request_max_retries` 控制，与用户手动触发的重试是两回事（数据语义见会话与消息管理笔记 §4）。
- **follow-up 消费**：当前轮次结束后，runner 把积压的 follow-up 文本以 `[SYSTEM NOTICE]` 提示合并进下一轮内容，提示模型优先处理用户插话（`tool_loop_agent_runner.py:124`、`:703-731`）。

## 8. 队列、多会话并发与后台生成

RateLimit 的等待队列以完整 `unified_msg_origin` 分桶，因而不同平台会话不会共用限流计数（rate_limit_check/stage.py:57-82）。cron 与后台工具唤醒主 Agent 时保留结构化会话历史，并从 `agent_runner.config` 读取压缩、fallback、最大步骤和工具超时，交给同一 runner（`astr_agent_tool_exec.py:165-193、399-546`；`cron/manager.py:310-415`）。

- **SessionLockManager**：单例。外层以事件循环为键做隔离，用 `WeakKeyDictionary` 保存每个 loop 对应的管理器，防止跨 loop 误用 asyncio 锁；内层管理器以 UMO 为键懒创建 `asyncio.Lock`，并配引用计数，计数归零后自动清理。这把锁包住 `build_main_agent` 调用与整个 agent 运行，同一 UMO 的 LLM 请求被串行化，不同会话之间互不阻塞（`session_lock.py:8-55`；`internal.py:184-425`）。
- **follow-up 严格序**（`follow_up.py:16-218`）：
  - 捕获条件：同一 UMO、同一发送者，且 runner 尚未停止；
  - 捕获时立即通过 `_allocate_follow_up_order` 分配单调序号，排序依据是到达顺序，与唤醒顺序无关；
  - 状态按 pending、active、finished 或 consumed 流转：队首放行，随后消耗，完成时收尾；
  - 没有残留状态且没有活跃 runner 时，释放该 UMO 的状态；
  - monitor 任务在 ticket 解决时立刻推进序号，避免唤醒顺序漂移。
- **EventBus 背压**：`event_queue` 是未设置 maxsize 的 `asyncio.Queue`，突发流量下队列与内存持续增长；每个事件一个任务，全局没有并发上限。
- **限流**：`RateLimitStage` 按会话 ID 做固定窗口计数；超出限额时默认阻塞，用 `asyncio.sleep` 等到下一个窗口，只有 `discard` 策略才会丢弃请求（`rate_limit_check/stage.py:57-89`）。
- **后台生成**：cron 任务与后台工具任务以唤醒事件重新进入流水线，结果由处理阶段统一回写，不经过 RespondStage（`internal.py:445-504`）。WebChat 的后台生成由同一会话的多个 run 并行完成，run 记录存在 chat_runs 表里，前端靠 active_runs 恢复界面状态（`chat_service.py`）。

## 9. Agent、工具、知识库与附件注入点

- **Agent 构建**：`build_main_agent` 在不重置的入参下产出 `MainAgentBuildResult`，其中包含 agent runner、provider request、provider 与重置协程；Live Mode 改走 `run_live_agent`，`action_type` 为 live 时启用 TTS 处理（`internal.py:214,270-329`）。
- **工具目录**：工具与技能由 persona 的 tools、skills 配置决定，装配逻辑在 `apply_persona` 中。会话插件过滤在构建阶段完成，剔除会话未启用的插件工具，MCP 工具与没有归属的工具保留；请求 hook 可在这一步拦截；api_base 黑名单由 `select_chat_provider` 拦截（`persona.py:32-150`；`plugins.py:12,53`；`providers.py:31`）。
- **知识库**：非 agentic 模式下，`apply_knowledge_base` 在构建请求时检索知识库并把结果注入上下文；开启 `kb_agentic_mode` 后转为给模型提供检索工具。会话级知识库配置在删除会话时级联清理（`knowledge_base.py:17` 起；见会话与消息管理笔记 §8）。
- **群聊上下文注入**：记录与注入分别落在 `group_chat_context.py` 与 `builtin_stars/astrbot/main.py`（`group_chat_context.py:41-239`）。
  - 记录：`on_message` handler 在 `group_icl_enable` 打开时把群消息格式化成 `[昵称/时间]: 内容`，写入该 UMO 的内存环形缓冲，默认上限 1000 条，由 `group_message_max_cnt` 调整；解析出命令参数的消息不记录（`main.py:188-229`）。
  - 注入：`on_llm_request` hook 转到 `on_req_llm`，把该条消息之前的群聊历史拼成带 BEGIN/END CONTEXT 标记的系统提醒块，追加到 `req.extra_user_content_parts`（`main.py:321-331`；`group_chat_context.py:160-195`）。
  - 图像描述：`get_image_caption` 用一个独立的 provider（可由 `image_caption_provider_id` 指定）为图片生成文字描述并放进上下文（`group_chat_context.py:88-108`、`:204-219`）。
  - 主动回复：`need_active_reply` 只在群聊生效，被 @ 或收到唤醒命令时不触发，还要通过白名单过滤，最后按 `possibility_reply` 阈值做随机判定；一旦触发就直接调用 `request_llm` 复用当前对话（`group_chat_context.py:112-130`；`main.py:229-268`）。
  - 清理：`/reset` 或 `/new` 会置上 `_clean_group_context_session` 标记，消息发送完成后由发送后 hook 调用 `remove_session` 清空该会话的缓冲（`main.py:332-344`）。
- **外部能力注入点小结**：persona、知识库与引用解析发生在 `build_main_agent` 的构建期；群聊上下文、系统提醒与图片描述在 `on_llm_request` hook 期进入请求，此时 req 尚未拼装完成；web search、文件操作、cron、联网等其余能力都以工具形式交给 agent 循环，由模型在运行时调用（Agent 工具类目）。

## 10. 退出恢复、日志与已确认边界

- **退出与重启**：pipeline 任务的生命周期内没有持久化 checkpoint，服务重启后群环形缓冲、`ChatRunState` 与 follow-up 序号状态全部丢失。WebChat 中运行中的 run 可以在前端刷新后通过 `/chat/runs/{id}/stream` 的快照恢复，IM 平台没有对应的恢复入口（数据语义见会话与消息管理笔记 §3）。
- **可观测性**：`event.trace` 记录请求准备与完成两个阶段，事件名为 astr_agent_prepare 与 astr_agent_complete；Dashboard 侧由追踪存储汇总后经 SSE 展示。消息日志的 category 为 user_chat；用量统计表 ProviderStat 按 UMO 与 conversation 记录，供 `/stats` 命令与 StatsPage 消费（`internal.py:256,383,535`；`event_bus.py:137`；`utils/trace_store.py`）。
- **已确认边界**：阶段顺序硬编码在 `STAGES_ORDER` 中，出现未注册阶段会抛 ValueError；RateLimit 超限时默认阻塞等待；EventBus 的队列不设上限；`third_party.py` 覆盖的 Dify、Coze 等路径不构建 persona，错误文案也单独解析（`scheduler.py:23-25`；本次未逐行核对）。

## 11. 未验证事项

1. 各阶段在真实平台上的时序行为未启动实例实测，洋葱递归、流式与停止竞态都来自静态确认。
2. follow-up 与流式响应并存时的完整交互未逐行核对，消费点在 `tool_loop_agent_runner.py:1103`，边界场景未实测。
3. `result_decorate` 的 T2I、转发与语音合成完整逻辑未逐行核对，本次只覆盖初始化、内容安全复查与分段回复入口，代码在 `result_decorate/stage.py:104-220` 之后未深入。
4. `third_party.py` 涉及的 Dify、Coze 等第三方 runner 细节未逐行核对。
5. `whitelist_check`、`session_status_check`、`preprocess_stage` 三个前置阶段本次只确认了存在与职责，未逐行阅读（`stage_order.py:5-9`）。
6. 长会话低频访问时携带大上下文的影响属于静态推断：默认 `max_context_length=-1` 下依赖 82% 的 token 阈值触发压缩，未实测。
7. Provider fallback 与模态切换在真实多 provider 配置下的行为未运行验证。

## 12. 关键源码索引

- 事件：`astrbot/core/event_bus.py`（dispatch :55、stop_platform :77-102、日志 :137）
- 流水线：`astrbot/core/pipeline/stage_order.py`、`scheduler.py`（execute :84、_process_stages :38）、`stage.py`（register_stage :13）、`context_utils.py`（插件 handler 调用）
- 各阶段：`waking_check/stage.py`（含 `umo_auto_name.py`）、`whitelist_check/stage.py`、`session_status_check/stage.py`、`rate_limit_check/stage.py`、`content_safety_check/stage.py`、`preprocess_stage/stage.py`、`process_stage/stage.py`、`result_decorate/stage.py`、`respond/stage.py`
- Agent 子阶段：`process_stage/method/agent_request.py`、`agent_sub_stages/internal.py`、`agent_sub_stages/third_party.py`、`agent_sub_stages/webchat.py`、`process_stage/follow_up.py`
- 并发：`astrbot/core/utils/session_lock.py`、`utils/active_event_registry.py`
- 上下文：`astrbot/core/agent/context/manager.py`、`truncator.py`、`token_counter.py`、`compressor.py`、`config.py`
- Agent 构建：`astrbot/core/astr_main_agent/`（builder.build_main_agent :57、request :208/:490、persona.py、providers.py、plugins.py、knowledge_base.py、media.py、web_search.py、subagent.py、workspace.py、computer_use.py）、`agent/runners/tool_loop_agent_runner.py`
- 群上下文：`astrbot/builtin_stars/astrbot/group_chat_context.py`、`builtin_stars/astrbot/main.py`
- 配置：`astrbot/core/config/default.py`（agent_runner :207-210、provider_ltm_settings :237）、`astrbot/core/config/agent_runner.py`（模型/Persona/压缩字段 :9-36）
