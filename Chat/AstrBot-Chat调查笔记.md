# AstrBot Chat 概览

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：会话模型与持久化、事件总线与任务模型、流水线调度与各阶段、唤醒、并发控制与 follow-up、上下文构建与压缩、群聊/私聊差异、UI 层
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 是面向 IM 平台（QQ/Telegram/Discord/微信等）的**消息驱动异步聊天框架**。一条入站消息经 `EventBus` 从异步队列取出，为每条消息创建独立 asyncio 任务，交给按配置 ID 映射的 `PipelineScheduler` 按固定 9 阶段顺序处理。并发控制不靠阶段限流，而靠 UMO 粒度的 `session_lock` 串行化 LLM 请求 + 严格有序的 follow-up 队列。核心特征：UMO 事件流水线、九阶段洋葱调度、两级会话概念、上下文双层压缩。

## 产品表面与系统边界

- **产品表面**：无最终用户 GUI。项目自带 WebChat（浏览器聊天入口）与 Dashboard（管理后台，Vue），其余全部通过 IM 平台适配器接入。
- **服务形态**：机器人框架/消息管道。按配置实例分调度器（`pipeline_scheduler_mapping` 按 conf_id 隔离），多租户各自独立 pipeline。
- **不拥有的层级**：外部 IM 客户端界面不归项目所有；平台适配器只负责收发消息，界面呈现由各平台拥有。

## 端到端聊天主链

```text
平台适配器收到消息 → 构造 AstrMessageEvent（unified_msg_origin = platform:message_type:session_id）
→ event_queue.put() → EventBus.dispatch 无限循环消费（每事件一 asyncio.create_task，_pending_tasks 强引用防 GC）
→ 按 conf 映射取 PipelineScheduler → scheduler.execute(event)
→ 九阶段洋葱模型：WakingCheck（唤醒+handler 匹配+unique_session）→ WhitelistCheck → SessionStatusCheck
   → RateLimit（超限 stall 阻塞）→ ContentSafetyCheck → PreProcess → Process（InternalAgentSubStage：
   session_lock 包裹 → build_main_agent → agent 循环；或插件 handler / 第三方 runner）
   → ResultDecorate（@/回复前缀、T2I、TTS、分段回复、转发、安全复查）→ Respond（发送）
→ 收尾：event.cleanup_temporary_local_files()、active_event_registry 注销、历史保存
```

## 核心对象与状态权威

- **两级会话**：会话（session）= 聊天窗口，以 `unified_msg_origin` 标识；对话（conversation）= 会话内子对话，可新建/切换/删除。
- **持久化**：对话历史存 SQLite `conversations` 表（`ConversationV2.content` = OpenAI 格式 JSON 列表）；当前对话 ID 经 SharedPreferences `sel_conv_id`（scope=umo）持久化；内存缓存 60s 防抖。
- **AstrMessageEvent**：事件载体，`stop_event()` 可任意点截断传播；`role` 在唤醒阶段被标记（admin 等）。
- **并发状态**：`SessionLockManager`（按事件循环隔离、UMO 粒度 `asyncio.Lock` + 引用计数自动清理）；follow-up 序号状态机（捕获时分配单调序号）；`ActiveEventRegistry`（stop_all 硬断 vs `agent_stop_requested` 软停；软停同时经 agent_stop 回调立即取消 runner 进行中的 LLM 请求，事件传播与历史保存仍继续，见 #9602）。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/AstrBot-会话与消息管理调查笔记.md`](../会话与消息管理/AstrBot-会话与消息管理调查笔记.md)（两级会话、对话持久化、群历史）。
- 对话请求与上下文：[`../对话请求与上下文/AstrBot-对话请求与上下文调查笔记.md`](../对话请求与上下文/AstrBot-对话请求与上下文调查笔记.md)（事件总线、9 阶段流水线、并发控制、上下文压缩）。
- Chat UI：[`../Chat UI/AstrBot-ChatUI调查笔记.md`](<../Chat UI/AstrBot-ChatUI调查笔记.md>)（项目自带 WebChat 与 Dashboard；外部 IM 界面不归项目所有）。
- 消息渲染：[`../消息渲染器/AstrBot-消息渲染器调查笔记.md`](../消息渲染器/AstrBot-消息渲染器调查笔记.md)（已有独立笔记）。
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`../Chat UI/ChatUI横向对比.md`](<../Chat UI/ChatUI横向对比.md>)。

## 关键能力与已确认边界

1. **九阶段洋葱调度**：阶段 `process()` 返回 `AsyncGenerator` 时挂起，递归执行后续阶段，完成后回到 yield 点执行后置逻辑——LLM 请求阶段先让 Respond 发送，再回来做历史保存等收尾；单事件单流水线，无跨阶段状态泄漏。
2. **并发控制**：同 UMO 串行化（session_lock 包裹整个 LLM 流程），跨会话天然并行；follow-up 捕获时分配序号 + `asyncio.Condition` 队首放行，避免唤醒顺序漂移。
3. **上下文压缩两层**：先轮次截断（`enforce_max_turns≠-1`），再 token 压缩（82% 阈值触发，`LLMSummaryCompressor` 或 `TruncateByTurnsCompressor`，压缩后仍超限折半兜底）；system 消息保护、tool 配对修复。
4. **群聊**：`GroupChatContext` 每 UMO 内存环形记录最多 1000 条原始消息（含图像 caption），注入为 `<system_reminder>` 块；群历史可选持久化 700 条上限并暴露 `get_group_message_history` 工具；`unique_session` 开启后按发送者隔离会话。
5. **边界**：RateLimit 超限 stall 阻塞而非丢弃（消息堆积）；EventBus 无限队列无背压；阶段顺序硬编码于 `STAGES_ORDER`；agent 停止两态（stop_event 硬断 / agent_stop_requested 软停保历史）。

## 未验证事项

- 未启动实例实测各阶段在真实平台上的时序行为；follow-up 与流式响应并存时的详细交互未逐行核对。
- `result_decorate` 的 T2I/转发/语音合成完整逻辑未逐行核对；`third_party.py`（Dify/Coze 等）细节未逐行核对。
- `whitelist_check`、`session_status_check`、`preprocess_stage` 三个阶段未深入逐行阅读。
- 崩溃丢最近对话（60s 防抖窗口）、长会话低频访问携带大上下文等为静态推断。

## 关键源码索引

- `astrbot/core/conversation_mgr.py`（对话管理，:19-443）、`astrbot/core/db/po.py`（ConversationV2 / PlatformMessageHistory）
- `astrbot/core/event_bus.py`（事件总线）、`astrbot/core/pipeline/scheduler.py` + `stage_order.py`（洋葱调度）
- `astrbot/core/pipeline/process_stage/method/agent_sub_stages/internal.py`（session_lock :220）、`follow_up.py`（:1-248）
- `astrbot/core/utils/session_lock.py`（UMO 锁）、`astrbot/core/agent/context/manager.py`（上下文压缩）
- `astrbot/builtin_stars/astrbot/group_chat_context.py`（群上下文）、`dashboard/src/views/ChatPage.vue`（WebChat）
