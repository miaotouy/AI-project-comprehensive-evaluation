# Hermes Agent 对话请求与上下文调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（git 仓库）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：直接阅读源码（Python Agent 会话运行时 run_agent.py 与 agent/ 包、tui_gateway JSON-RPC 网关与其契约目录、桌面端与 TUI 事件消费），符号按当前快照复核；行号仅给复核过的位置，其余用文件加符号定位；行为类结论区分源码事实与静态推断
>
> 调查范围：一次生成任务的提交入口与契约、任务对象与状态机、历史选择与上下文拼装顺序、预算截断与压缩、Provider 交接、流式事件链、最终化与回写、停止重试续写、队列并发、外部能力注入点与退出恢复。会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目；工具执行循环内部语义属于 Agent 工具类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手。常规桌面本地连接通过 gateway ensure 取得规范 owner，renderer 经 WebSocket JSON-RPC 提交并观察输入回执与生成事件；网关的生命期独立于桌面窗口。legacy tui_gateway 桥仍承接另一组调用，正文分别说明两种执行与恢复契约。

主链路：composer → prompt.submit（WS）→ 参数契约校验与 busy 门控（`tui_gateway/methods_prompt.py`）→ 回合执行（`tui_gateway/prompt_turn.py` 的 `_run_prompt_submit`，记录 turn marker、注册流式回调、启动运行线程）→ 对话主循环（`agent/conversation_loop.py:1802` 的 `run_conversation`，组装上下文、循环调用 Provider，每个增量经流式回调回发）→ 收尾持久化 → message.complete（含 status/text/usage）。桌面端增量文本进入自适应节流队列，完成事件合并终态并触发会话列表刷新。

本次快照的结构变化集中在四处：方法契约集中到 `tui_gateway/contracts/*.py` 并以 Pydantic 校验；`tui_gateway/server.py` 从约万行收缩到 1,705 行的 facade，prompt 执行、busy 处理、自动续跑、历史与压缩衔接分别落入 `prompt_turn.py`、`session_auto_continue.py`、`session_history.py`、`session_compression.py`；中断/重定向原语抽到 `agent/interrupt_control.py`；截断参数从"用户轮序号"改为优先使用持久化行 id 或消息 id。

## 系统边界与生成任务主链

### 规范网关与 legacy 桥的执行边界

常规桌面本地连接经 gateway ensure 取得规范 owner。其 prompt.submit 要求稳定 submission_id/input_id，授权后把输入及不可变附件写入受理账本，再安排执行；回执确认已受理，不等价于已完成。相同主体、会话、请求 id 的原样重试返回既有回执，payload 变化报 admission_conflict；排队上限为每会话 32 条（[入口](../../hermes-agent/gateway/session_controls.py#L753-L833)、[受理事务](../../hermes-agent/hermes_state_runtime.py#L130-L177)）。

规范 owner 重启将旧代际 started 输入转为 unknown，后续输入暂停等待明确恢复决策；不自动重跑可能已经产生副作用的输入（[recover_session_inputs](../../hermes-agent/hermes_state_runtime.py#L453-L464)）。下面的 methods_prompt、prompt_turn、busy 模式与中断标记细节对应 legacy tui_gateway 桥，其恢复契约只在 legacy 桥内成立；规范网关的恢复按上文的 unknown 状态与明确恢复决策处理。

一次发送的事件序列：

```text
桌面 composer ─ prompt.submit(WS)
   │  契约：tui_gateway/contracts/prompt_voice.py（PromptSubmitParams / PromptSubmitResult）
   │  handler：tui_gateway/methods_prompt.py（校验 / busy 门控 / 截断）
   │  tui_gateway/prompt_turn.py: _run_prompt_submit(:1114)
   │    ├─ record_turn_start（崩溃标记，tui_gateway/turn_marker.py:124）
   │    ├─ _emit("message.start", sid)
   │    ├─ 运行线程：agent.run_conversation(...)
   │    │     build_turn_context → 调模型 → 每 token delta 调流式回调
   │    │       └→ _emit("message.delta", {text, rendered?})
   │    ├─ history 替换（history_version 防抖）
   │    ├─ _sync_session_key_after_compress（tui_gateway/session_compression.py:313）
   │    └─ _emit("message.complete", {status, text, usage})
   └─ 桌面 gateway-event.ts：
         message.start → flushQueuedDeltas / busy 置位
         message.delta → queueDelta（自适应节流合批）
         message.complete → completeAssistantMessage（合并终态、触发列表刷新）
```

事件帧为 `{"jsonrpc":"2.0","method":"event","params":{"type", "session_id", "payload"}}`，帧构造 `_event_frame`（`tui_gateway/server.py:587`）。WS 端对流式事件合批刷帧，非流式帧先冲刷缓冲保证顺序。

边界：会话与消息如何持久化、分支数据语义属于会话与消息管理（`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`）；发送按钮、停止反馈、排队提示等用户可见状态属于 Chat UI（`../Chat UI/Hermes-Agent-ChatUI调查笔记.md`）；流式事件进入可见状态后的渲染属于消息渲染器类目。

## 1. 提交入口、任务对象与状态机

`prompt.submit` 的参数与结果由 `tui_gateway/contracts/prompt_voice.py` 声明（`PromptSubmitParams`、`PromptSubmitStatus`、`PromptSubmitResult`，方法注册在 `:83`），handler 在 `tui_gateway/methods_prompt.py`：

| 参数 | 用途 |
|---|---|
| `text` | 用户输入；正常为字符串，relay/hosted 路径可传结构化 parts |
| `display_kind` | 只认 `hidden`，其他值按普通用户行渲染 |
| `interrupted` / `queued` | 语音 barge-in 标记 / 队列排空专用（忙时必须排队，不允许 steer/redirect） |
| `surface` | 桌面 HUD 等客户端表面标记，未知值清空 surface |
| `voice_context` / `voice_turn` | 语音实时会话：近期口述转写只作模型输入；口述轮走 `auxiliary.voice_chat` |
| `title_preview` | 桌面大段粘贴预览，只用于取标题，不进模型轮 |
| `truncate_before_row_id` / `truncate_before_message_id` / `truncate_before_user_ordinal` | 编辑/回退的截断目标，**优先持久化行 id，其次消息 id，序号为遗留形式** |
| `confirm_truncate` / `confirm_empty_truncate` / `confirm_deep_truncate` | 截断必须显式确认；空截断另需 `confirm_empty_truncate`（否则错误 4028）；一次归档多个用户轮需 `confirm_deep_truncate` |
| `rebind_survivor_row_ids` | 截断后幸存行的重绑标识 |

`display_type` 参数仍不存在（检查范围：契约目录与 `methods_prompt.py`）。handler 顺序：检查 busy 状态 → 执行截断（先写库，失败拒轮，再改内存历史并递增 `history_version`）→ 标记运行中并登记任务 → 确保会话行与分支种子存在 → 惰性构建 agent → 等待构建完成（`_wait_agent_for_prompt` 在 `tui_gateway/session_registry.py:33`：按 5 秒分片轮询，30 秒后发慢提示，上限由 `agent.build_wait_timeout` 配置）→ 启动后台线程并返回 `{status: "streaming"}`。失败时发送终态错误帧。

busy 处理在 `tui_gateway/session_auto_continue.py:400` 的 `_handle_busy_submit`：按 `display.busy_input_mode`（默认 interrupt）分派，`queue` 模式由 `queued` 参数强制；结果分别是 queued、steered 或 redirected，队列排空在 `_drain_queued_prompt`（`:457`），终态错误帧在 `_emit_terminal_turn_error`（`:559`）。

## 2. 历史选择与上下文拼装顺序

### 2.1 build_turn_context

上下文构建入口 `build_turn_context`（`agent/turn_context.py:1093`），动作按功能分组：

1. 恢复轮转会话：会话已被压缩轮转则取回 child 历史；
2. 轮间 MCP 工具刷新（仅在已注册 MCP 且工具集变化时执行）并注册流式回调；
3. 拷贝会话历史，追加本轮用户消息并记录用户位置；合成轮的显示类型与显示元数据在此盖章；
4. 系统提示词：缓存为空时从 DB 恢复并校验，命中则复用，否则重建并持久化（`agent/conversation_loop.py:802` 的 `_restore_or_build_system_prompt`）；恢复后使用缓存提示词；
5. DB 会话行 `_ensure_db_session`（**在压缩之前**，防 NULL system_prompt；压缩轮转/原地压缩都要引用父行）；
6. idle 压缩（见 §3）；
7. preflight 压缩（见 §3）；
8. 压缩后重锚用户位置；
9. `pre_llm_call` 插件钩子；gateway 必达注记消费；
10. 中断状态重闩；`_memory_manager.on_turn_start`；
11. 外部记忆 `prefetch_all`；
12. 为 API 副本追加 sidecar 内容（记忆块与插件上下文，`compose_user_api_content` 在 `agent/turn_context.py:124`）；
13. crash 持久化：`_ensure_db_session` 加用户行一次写入；回合末执行标题派生（标题机制在会话与消息管理笔记 §2.3）。

每次重建历史时，过期的 `api_content` sidecar 由 `drop_stale_api_content`（`agent/turn_context.py`）丢弃，避免把上一轮的字节保真内容重放给新请求。

### 2.2 系统提示词组装

`build_system_prompt_parts`（`agent/system_prompt.py:738`）产出三档字典：

- `stable`（跨会话稳定）：SOUL/身份、task-completion、parallel-tool-call 指导、工具族指导、tool_use_enforcement、env hints 等；
- `context`（cwd 相关）：coding workspace、profile 提示、平台 hint、调用方 `system_message`、上下文文件（`build_context_files_prompt` 在 `agent/prompt_builder.py`）；
- `volatile`（最易变）：skills index、内置记忆块、USER.md、外部记忆 provider 块、时间戳行（日期级粒度保字节稳定）。

主构建函数拼接并缓存结果；续会话从 DB 恢复，压缩后清空缓存并重载记忆磁盘。

记忆进入上下文有两个通道：内置 MemoryStore 进入 volatile 系统提示词；外部 provider 先预取，再以 sidecar 注入当前用户消息，轮后同步写回（`run_agent.py:888` 的 `_sync_external_memory_for_turn`）。

## 3. 预算、截断、摘要与压缩

- 无 token 级截断原语；压缩判断 `should_compress` / `should_compress_info`（`agent/context_compressor.py:3003/3007`）：达到阈值且未被阻塞才压缩。阻塞原因是压缩失败冷却或连续两次无效，阈值按上下文长度比例计算，也可由绝对上限覆盖。
- 压缩入口 `compress_context`（`agent/conversation_compression.py:3989`）；`agent/compression_facade.py:227` 提供 Agent 侧 `_compress_context` 门面；状态模板覆盖 PRE_API、PREFLIGHT、IDLE_COMPACTION 与 CONTEXT_OVERFLOW_BLOCKED。
- preflight 先做廉价粗估，再按需多轮重测（默认最多 3 轮），只有行数减少或 token 降幅超过 5% 才继续；被阻塞时提示 CONTEXT_OVERFLOW_BLOCKED。
- idle 压缩：墙上时间门（`compression_idle_compact_after_seconds`）与 token 阈值正交，要求 token 数高于下限。
- **压缩内容保留面**：保留进行中的工具链和 clarify 等非响应哨兵，修剪陈旧 reasoning 行，并处理最大迭代提示与无 continuation 的孤儿恢复。原地压缩与轮转都保留旧行的 `active=0/compacted=1` 语义（会话与消息管理笔记 §3.5）。
- **native 服务端压缩**（`agent/native_compaction.py`）：部分模型家族通过 `/v1/responses` 的 context_management 请求项触发服务端压缩，服务端持久化并重放 opaque compaction item，本地压缩仍作为回退。
- **缓存边界注册表**（`agent/prompt_cache_boundary.py`）：技能、Webhook 和 cron builder 声明 stable/volatile 字节边界，缓存规划器在边界放置断点；注册表仅存于进程内，miss 时回退整条消息策略。
- 轮转会生成新 session_id，在单事务中插入子行、写入压缩后消息并将父行标记为 compression，再切换会话 ID 与 flush 基线；标题由后续步骤补写。原地压缩不轮转 ID，软归档旧行（数据语义见会话与消息管理笔记 §1.2 / §3.5）。
- 压缩后系统提示词不变时继续使用缓存；消息列表则与轮转前副本区分，防止重复追加。

## 4. SDK、Provider、模型与协议交接

网关的方法、请求与事件契约集中声明在 `tui_gateway/contracts/` 目录（sessions、prompt_voice、events、registry 等文件），注册时拒绝未声明方法；运行时以 Pydantic 校验参数与结果并拒绝未知键；生成器把同一目录输出为 TypeScript 声明与 OpenRPC（`scripts/gen_gateway_contracts.py`）。桌面/TUI 因而消费由后端模型生成的协议类型，而不是各自手写宽松 payload 约定。

对话主循环 `run_conversation`（`agent/conversation_loop.py:1802`），Agent 侧门面在 `agent/turn_facade.py`：

- 先构建本轮上下文（见 §2）。每轮顶部检查中断并消耗预算，再处理 steer、清理 sidecar 和长度续接标记，前置系统提示词，规划 prompt cache，执行 API 前压缩检查，最后按需流式调用 Provider；API 参数构建在 `build_api_kwargs`（`agent/chat_completion_helpers.py:1503`）。
- 结束时由 `agent/turn_finalizer.py` 收尾：关闭中断的工具序列、补齐必要的 assistant 行、持久化会话、执行 hooks 并生成结果；终局清除中断状态。
- **auto 路由身份**：auto 路由运行时按请求中的 provider/model 解析并在会话内保留，不回落配置默认值；辅助任务有独立路由函数（`agent/auxiliary_client.py`）。reasoning 参数随 agent 配置进入请求构建，具体解析点本快照未逐行核对。

## 5. 流式事件、缓冲、节流与顺序

回合执行入口 `_run_prompt_submit`（`tui_gateway/prompt_turn.py:1114`）的发射链：

1. 清除每轮开头的中断状态；
2. 写入回合开始标记（`record_turn_start`，`tui_gateway/turn_marker.py:124`）；
3. 发出空 payload 的 message.start 事件；
4. 流式回调处理增量文本：维护 resume 快照（`_append_inflight_delta`，`tui_gateway/session_history.py:413`），生成 `{text, rendered?}` payload，依次进入 TTS 队列并发出 message.delta。

WS 端对 message.delta 等高频帧做 token 合批（约 30fps），任何非流式帧先冲刷缓冲保证顺序。

桌面端事件到状态层（`use-message-stream/gateway-event`、`use-message-stream/index.ts`）：

- **流式节流**：按会话累加增量文本，用 setTimeout 调度刷新（避免后台窗口 rAF 挂起）；刷新间隔取固定下限与上次实测成本三倍中的较大值，并受上限约束。多类事件处理结束时都会触发刷新。
- 事件状态转换为：start 刷新并置 busy，delta 累加，complete 合并最终文本。

## 6. 完成、异常、半截流与最终回写

收尾链：

1. history 替换带版本防抖：版本未变直接替换，仅有 model-switch marker 时合并，真正不同步则不写并记录 warning；
2. 压缩轮转后重新锚定 session_key（`_sync_session_key_after_compress`，`tui_gateway/session_compression.py:313`），迁移会话配额租约与 yolo 状态；
3. status 有 interrupted、error、complete 三态；中断文本若以取消元数据前缀开头则清空，避免桌面将其画成回复；无可见回复但存在真实错误时显示 `Error: <detail>`；
4. 发出 message.complete，payload 含文本、用量、状态，以及可选的 reasoning、warning、billing、rendered 与错误恢复信息；错误时保留可重放快照，异常路径统一经 `_emit_terminal_turn_error`（`tui_gateway/session_auto_continue.py:559`）发送终态错误帧，可带 partial 文本；
5. finally 阶段清理记忆、发送 TTS sentinel、清除运行状态并结算事件。

桌面端收到 complete 后合并最终文本：删除所有流式文本片段，以权威终态重写并保留 reasoning；临时气泡原位结算以避免双泡。结束后延迟合并会话列表刷新，并按需从存储会话回填；压缩轮转的 turn 跳过回填，adopted turn 先水合。实现见 `use-message-stream/index.ts` 与 `lib/chat-messages`。

## 7. 停止、重试、续写与重新生成

- **中断（服务端）**：
  - 主循环顶部、重试等待和空响应重试等位置检查中断；流式 API 入口抛 `InterruptedError`（`agent/chat_completion_helpers.py` 的 `interruptible_api_call` / `interruptible_streaming_api_call`）。
  - 中断原语集中在 `agent/interrupt_control.py`：`clear_interrupt`（`:278`，可保留 redirect 或硬取消）、`redirect`（`:323`，只打断模型请求，不扩散到工具或子代理）、`interrupt_issuer`（`:29`）；硬取消经过压缩提交栅栏，并向执行线程、工具 worker 和子代理传播。
  - 服务端 `session.interrupt` 请求硬中断并清理审批。
  - **回合租约**：`gateway/turn_lease.py` 按解析后的 session_id 串行化"载入历史→运行→flush"，等待超时 fail-closed；shutdown 时中断每个进行中的 API 回合。
  - **停止（桌面端）**：桌面端没有名为 `interruptResponse` 的符号；TUI 的对照符号为 `SessionInterruptResponse`（`ui-tui/src/gatewayTypes.ts`）。桌面停止先在本地定稿再调用 session.interrupt，随后本地 interrupted 状态拒收迟到流事件，complete 的中断分支只清 busy 并保留部分文本。
  - **重试**：三套实现都截断到最后一个真实用户回合后重发；真实回合判定与数据变化见会话与消息管理笔记 §4。TUI 的 `/retry` 在 `ui-tui/src/app/slash/commands/core.ts`，桌面 reload/regenerate 在 `rewind.ts`，CLI 对照为 `retry_last()`。
  - **续写**：没有 `/continue` 命令或独立 RPC，只是普通 prompt.submit 文本"continue"；空响应恢复会重放占位 assistant 行，持久化前由 `_drop_trailing_empty_response_scaffolding`（`agent/session_persistence.py:530`）删除。
  - **编辑后发送**：桌面入口在 `user-message.tsx`，点击进入编辑 composer，发送即执行"interrupt + rewind"，截断目标优先用持久化行 id（§1）；数据侧截断语义见会话与消息管理笔记 §4。
  - **运行中干预**：`session.steer` 把文本追加到本批次最后一条工具消息末尾，不新增消息也不破坏角色交替；没有可挂载工具时回存，未消费内容作为下一轮用户消息投递。`session.redirect` 要求 agent 支持活动轮重定向，未就绪但正在运行时先入队。

## 8. 队列、多会话并发与后台生成

- 同会话 busy 时按 steer 或活动轮重定向处理，否则入队并异步中断，返回 queued（`_handle_busy_submit`，`tui_gateway/session_auto_continue.py:400`）；`queued` 参数强制 queue 模式，队列在回合结束后由 `_drain_queued_prompt`（`:457`）排空并用代际编号防串扰。
- agent 构建等待有 600 秒上限（`_wait_agent_for_prompt`，`tui_gateway/session_registry.py:33`）。
- 后台生成包括 auto-continue（`_maybe_schedule_auto_continue`，`tui_gateway/session_auto_continue.py:58`）和 async-delegation；它们会传递显示类型与元数据。AIAgent 可关闭后台复习，子代理异步任务则创建独立会话执行（数据语义见会话与消息管理笔记 §8）。
- 多会话并发与同会话串行化的实际运行行为未验证（见未验证事项）。

## 9. Agent、工具、知识库与附件注入点

- 工具执行会传入流式回调、用户消息持久化开关和会话任务标识；每轮顶部处理 steer，轮间刷新 MCP 工具，并运行 pre_llm_call 插件钩子（`agent/turn_context.py`）。
- 记忆有两个注入通道：内置 MemoryStore 进入 volatile 系统提示词；外部 provider 先预取，再以 sidecar 注入当前用户消息，轮后写回。内部语义不在本类目展开。
- 附件注入：@file: 和 @context 引用在回合执行前预处理；图片按路由选择 native 像素直传或 text vision 预分析。桌面端按跨文件系统情况选择附件 RPC 或共享本地路径；图片指引是 @image:<path> 指令行。`input.detect_drop` 仅存在于 Ink TUI 侧，桌面 renderer 使用 file/image attach RPC。拖放与附件分流见 Chat UI 笔记 §3。
- 语音轮：契约新增 `voice_context`/`voice_turn`，口述轮走 `auxiliary.voice_chat` 路由（`tools/voice_live.py`），与文本轮共用主循环。

## 10. 退出恢复、日志与已确认边界

- 崩溃恢复：回合标记写入 `<home>/desktop/interrupted_turns.json`（上限 32 条/24 小时/64KB 提示词），在客户端已见到结果后清除（`tui_gateway/turn_marker.py`）；标记带写入者 pid 与启动时间，并用跨进程文件锁避免同机多后端互踩。`session.resume` 按标记自动重跑并用 attempts 计数防循环；断连窗口的失败回合还可从 inflight 快照恢复。
- 桌面端请求层：请求带超时参数（`utils.ts` 的 `timeoutMs`），后端事件循环饥饿时以超时拒绝，且与"畸形响应"分开判定；回合完成依靠流事件而不是 RPC ACK；找不到会话或超时后 resume 会触发一次重试，busy 则按目标会话重试（`submit.ts`、`use-prompt-actions/utils.ts`）。
- 可观测性：message.complete 携带 usage 与 billing，错误终帧携带 error、recoverable、partial 与 failure_reason。任务级日志与 trace 不在本次调查范围。
- 已确认边界：无 token 级截断原语（§3）；`display_type` 参数不存在（§1）；桌面端没有 `interruptResponse` 符号（§7）。

## 11. 压缩保留策略与批处理输出

上下文压缩的默认保留策略为 lean tail（`tail_mode` 默认 `lean`，`agent/context_compressor.py:2824`）：尾部预算下限与上限分别是 10,000 与 25,000 token（`LEAN_TAIL_FLOOR_TOKENS`/`LEAN_TAIL_CAP_TOKENS`，`:923-924`），另保留受预算约束的近期用户消息与工具回合。当前实现因此不保留大段原始上下文，而是优先保留较短的可验证尾部，其余依赖压缩摘要。ACP 侧把多个客户端收敛到共享 OpenAI bridge，并在支持工具调用的 agent-as-provider 场景中把该 provider 自身的工具工作合并回当前 turn；运行时效果未执行验证。

批处理入口 `hermes chat -q ... --format stream-json` 把一次性对话暴露为 JSONL 协议：首帧是 system/init，随后按发生顺序输出 text、tool_use、tool_result，末帧 result 携带成功状态、用量与最终文本。它复用正常 Agent 主链，只替换输出汇聚面（`hermes_cli/stream_json.py`）。

## 12. 未验证事项

- `display.busy_input_mode` 各模式（steer/redirect/queue）在真实 provider 上的行为未验证。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证（持久化入口在会话与消息管理笔记 §2.2）。
- 崩溃重放的端到端行为、多会话并发打到同一后端的表现未实测。
- `confirm_deep_truncate` 的强制时机（契约注释写"下一版启用"）与 `rebind_survivor_row_ids` 的重绑语义未逐行核对。
- 契约目录生成链（`scripts/gen_gateway_contracts.py`）与生成产物的一致校验未运行。

## 13. 关键源码索引

- 提交契约与入口：`tui_gateway/contracts/prompt_voice.py`（`PromptSubmitParams`、方法声明 :83）、`tui_gateway/methods_prompt.py`（`_coerce_truncate_int` :195、确认参数 :336-349、空截断 4028 :507-515）。
- 回合执行：`tui_gateway/prompt_turn.py`（`_run_prompt_submit` :1114）、`tui_gateway/session_auto_continue.py`（`_maybe_schedule_auto_continue` :58、`_handle_busy_submit` :400、`_drain_queued_prompt` :457、`_emit_terminal_turn_error` :559）。
- 网关：`tui_gateway/server.py`（`_event_frame` :587）、`tui_gateway/session_registry.py`（`_wait_agent_for_prompt` :33）、`tui_gateway/session_history.py`（`_append_inflight_delta` :413）、`tui_gateway/session_compression.py`（`_sync_session_key_after_compress` :313）、`tui_gateway/contracts/registry.py`、`scripts/gen_gateway_contracts.py`。
- 上下文构建：`agent/turn_context.py`（`compose_user_api_content` :124、`build_turn_context` :1093、`drop_stale_api_content`）；系统提示词：`agent/system_prompt.py`（`build_system_prompt_parts` :738）、`agent/prompt_builder.py`（`build_context_files_prompt`）。
- 主循环与收尾：`agent/conversation_loop.py`（`_restore_or_build_system_prompt` :802、`run_conversation` :1802）、`agent/turn_facade.py`、`agent/turn_finalizer.py`、`agent/session_persistence.py`（`_drop_trailing_empty_response_scaffolding` :530）。
- 压缩：`agent/context_compressor.py`（`should_compress` :3003、`should_compress_info` :3007）、`agent/conversation_compression.py`（`compress_context` :3989）、`agent/compression_facade.py`（`_compress_context` :227）、`agent/native_compaction.py`、`agent/prompt_cache_boundary.py`。
- 中断与租约：`agent/interrupt_control.py`（`interrupt_issuer` :29、`clear_interrupt` :278、`redirect` :323）、`gateway/turn_lease.py`。
- 流式 Provider 交接：`agent/chat_completion_helpers.py`（`build_api_kwargs` :1503、`interruptible_api_call` :1260、`interruptible_streaming_api_call` :3977）。
- 崩溃标记：`tui_gateway/turn_marker.py`（`record_turn_start` :124、`clear_turn_marker` :140）。
- 批处理输出：`hermes_cli/stream_json.py`；输入清理：`hermes_cli/input_sanitize.py`。
- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway）、`use-prompt-actions/submit.ts`、`use-prompt-actions/rewind.ts`、`use-prompt-actions/utils.ts`、`use-message-stream/index.ts`、`use-message-stream/gateway-event`、`lib/chat-messages`、`apps/shared/src/json-rpc-gateway.ts`、`use-gateway-request.ts`。
