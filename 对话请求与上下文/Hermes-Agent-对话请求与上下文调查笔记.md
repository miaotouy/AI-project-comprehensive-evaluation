# Hermes Agent 对话请求与上下文调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 调查方式：直接阅读源码（Python Agent 会话运行时 run_agent.py / agent/ 包、tui_gateway JSON-RPC 网关、桌面端与 TUI 事件消费），所有符号与行号在 HEAD 快照处逐一核对；行为类结论区分源码事实与静态推断
>
> 调查范围：一次生成任务的提交入口、任务对象与状态机、历史选择与上下文拼装顺序、预算截断与压缩、Provider 交接、流式事件链、最终化与回写、停止重试续写、队列并发、外部能力注入点与退出恢复。会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目；工具执行循环内部语义属于 Agent 工具类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手。桌面端不运行 agent，而是自 spawn 一个无头 hermes serve 后端进程，renderer 通过 WebSocket 发起 prompt.submit 等 JSON-RPC 调用，后端在独立线程运行对话主循环，把增量文本以 message.delta、终态以 message.complete 事件推回 UI。

主链路：composer → prompt.submit（WS）→ methods_prompt.py 校验、截断与 busy 门控 → 发送任务函数（记录 turn marker、注册流式回调、启动 run 线程，见 `server.py:9707`）→ 对话主循环（见 `conversation_loop.py:1422`，组装上下文、循环调用 Provider，每个 token 增量经流式回调回发）→ 收尾函数持久化 → message.complete（含 status/text/usage）。桌面端增量文本进入自适应节流队列（33ms 起、上限 250ms），完成事件合并终态并触发会话列表刷新（300ms 合并）。

## 系统边界与生成任务主链

一次发送的事件序列：

```text
桌面 composer ─ prompt.submit(WS)
   │  methods_prompt.py: handler（校验/busy 门控/truncate，:67-346）
   │  server.py: _run_prompt_submit(:9707)
   │    ├─ record_turn_start（崩溃标记）          (:9773)
   │    ├─ _emit("message.start", sid)            (:9741)
   │    ├─ run() 线程：agent.run_conversation(...) (:10024)
   │    │     build_turn_context → 调模型 → 每 token delta 调 _stream
   │    │       └→ _emit("message.delta", {text, rendered?})  (:9968-9976)
   │    ├─ history 替换（history_version 防抖）    (:10088-10150)
   │    ├─ _sync_session_key_after_compress        (:10158)
   │    └─ _emit("message.complete", {status, text, usage})  (:10196-10232)
   └─ 桌面 gateway-event.ts：
         message.start → flushQueuedDeltas / busy 置位
         message.delta → queueDelta（33-250ms 节流合批）
         message.complete → completeAssistantMessage（合并终态、触发列表刷新）
```

事件帧格式为 `{"jsonrpc":"2.0","method":"event","params":{"type", "session_id", "payload"}}`，帧构造与发射见 `server.py:1566-1573`。WS 端对流式事件做 33ms 合批刷帧（`ws.py:44-60`），非流式帧先冲刷缓冲保证顺序。

边界：会话与消息如何持久化、分支数据语义属于会话与消息管理（`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`）；发送按钮、停止反馈、排队提示等用户可见状态属于 Chat UI（`../Chat UI/Hermes-Agent-ChatUI调查笔记.md`）；流式事件进入可见状态后的渲染属于消息渲染器类目。

## 1. 提交入口、任务对象与状态机

入口位于 `methods_prompt.py:67-346`，方法名为 `prompt.submit`：

| 参数 | 位置 | 用途 |
|---|---|---|
| `session_id` | :71 | 会话定位 |
| `text` | :72-73 | 经输入清理函数处理（`hermes_cli/input_sanitize.py:65-70`：剥粘贴包裹符、折叠重复输入伪影） |
| `interrupted` | :105-110 | 语音 barge-in 标记，转为语音中断状态 |
| `queued` | :147-150 | 队列排空专用，强制 queue 模式（忙时提交即只排队不打断） |
| `truncate_before_user_ordinal` | :104, :175-303 | 编辑/回退时截断历史。截断提交必须显式携带 `confirm_truncate=true`，否则拒绝（:193-209）；空截断还需 `confirm_empty_truncate` 显式确认，否则拒绝（:227-244，错误 4028） |
| `surface` | :120 | 桌面 HUD 窗口标记，写入会话的 client_surface 字段 |

display_type 参数本次未找到（全树 grep 零命中）；display_kind/display_metadata 是发送任务函数的内部关键字参数（`server.py:9713-9714`），仅 auto-continue、async-delegation 路径传入。桌面端实际发送 `{session_id, text, interrupted?, surface?, queued?}`（`submit.ts:619-633`）。

handler 顺序：先循环检查 busy 状态（`server.py:7598`；入口判断见 `methods_prompt.py:136-155`），再执行截断（先写库，失败拒轮，再改内存历史并递增版本，`methods_prompt.py:256-303`），随后标记运行中并登记任务（:304-307），确保会话行和分支种子存在（:322-326），惰性构建 agent（`server.py:2129`），等待构建完成（默认等待上限 600 秒，`server.py:2035-2058`），最后启动后台线程并返回 `{status: "streaming"}`（:391-396）。失败时发送终态错误帧（`methods_prompt.py:354-368`）。

busy 处理位于 `server.py:7598-7679`：按 display.busy_input_mode（默认 interrupt）分派。steer 模式调整当前任务，支持活动轮重定向时直接重定向，否则入队并异步中断；结果分别是 queued、steered 或 redirected。具体分支见 :7637-7679。

## 2. 历史选择与上下文拼装顺序

### 2.1 build_turn_context

上下文构建位于 `agent/turn_context.py:430-1378`，约 30 个动作按功能分组：

1. 恢复轮转会话（:463）：若会话已被压缩轮转则取回 child 历史；
2. 轮间 MCP 工具刷新（:501-527，仅在已注册 MCP 且工具集变化时执行），并注册流式回调（:536）；
3. 拷贝会话历史（:607），追加本轮用户消息并记录用户位置（:662-664）；合成轮的显示类型和显示元数据在此盖章（:657-660）；
4. 系统提示词：缓存为空时从 DB 恢复并校验，命中则复用，否则重建并持久化（`conversation_loop.py:555`、:607-683）；恢复后使用缓存提示词（:716-719）；
5. DB session 行 `_ensure_db_session`（`:732-744`，**在压缩之前**，防 NULL system_prompt；压缩轮转/原地压缩都要引用父行）；
6. idle 压缩（`:763` 起，见 §3）；
7. preflight 压缩（`:841` 起，见 §3）；
8. 压缩后重锚 user idx（`:828-831`）；
9. `pre_llm_call` 插件钩子（`:1152-1204`）；gateway 必达注记消费；
10. 中断状态重闩；`_memory_manager.on_turn_start`（`:1248-1252`）；
11. 外部记忆 `prefetch_all`（`:1261-1266`）；
12. 为 API 副本追加 sidecar 内容（包含记忆块和插件上下文，`turn_context.py:53`、:1269-1318）；
13. crash 持久化：`_ensure_db_session` + 用户行一次写入（`:1327-1333`）；回合末 `_maybe_title_session_at_turn_start`（`:1363`，标题机制在会话与消息管理笔记 §2.4）。

### 2.2 系统提示词组装

系统提示词构建函数（`agent/system_prompt.py:152-558`）产出三档字典：

- `stable`（跨会话稳定）：SOUL/身份、task-completion、parallel-tool-call 指导、工具族指导、tool_use_enforcement、env hints 等；
- `context`（cwd 相关）：coding workspace、profile 提示、平台 hint、调用方 `system_message`、上下文文件（`build_context_files_prompt` 在 `agent/prompt_builder.py:2273`，调用点 `system_prompt.py:488-504`）；
- `volatile`（最易变）：skills index、内置记忆块（MemoryStore 格式化，`system_prompt.py:525-530`）、USER.md、外部记忆 provider 块、时间戳行（日期级粒度保字节稳定）。

主构建函数（:569）拼接并缓存结果（:588）；续会话从 DB 恢复，压缩后清空缓存并重载记忆磁盘（:598）。

记忆进入上下文有两个通道：内置 MemoryStore 进入 volatile 系统提示词；外部 provider 先预取，再以 sidecar 注入当前用户消息，轮后同步写回（`run_agent.py:4173`、:4222）。

## 3. 预算、截断、摘要与压缩

- 无 token 级截断原语；压缩判断见 `agent/context_compressor.py:2906`：达到阈值且未被阻塞才压缩。阻塞原因是压缩失败冷却或连续两次无效，阈值按上下文长度比例计算，也可由绝对上限覆盖。
- 压缩入口从 `run_agent.py:7448` 进入 `agent/conversation_compression.py:2150`；状态模板集中在 `conversation_compression.py:125-164`，覆盖 PRE_API、PREFLIGHT、IDLE_COMPACTION 和 CONTEXT_OVERFLOW_BLOCKED。
- preflight（`turn_context.py:841-1096`）先做廉价粗估，再按需多轮重测，默认最多 3 轮；只有行数减少或 token 降幅超过 5% 才继续。被阻塞时提示 CONTEXT_OVERFLOW_BLOCKED，判定细节见 :322、:339。
- idle 压缩：墙上时间门（`compression_idle_compact_after_seconds`，`turn_context.py:763`），与 token 阈值正交，要求 token 数 > floor。
- **压缩内容保留面**：压缩时保留进行中的工具链和 clarify 等非响应哨兵，修剪陈旧的 reasoning 行，并处理最大迭代提示和无 continuation 的孤儿恢复。原地压缩与轮转都保留旧行的 `active=0/compacted=1` 语义（会话与消息管理笔记 §3.4）。
- **native 服务端压缩（`agent/native_compaction.py`）**：gpt-5.6 家族通过 `/v1/responses` 的 context_management 请求项触发服务端压缩（:1-14、:109-144）；服务端持久化并重放 opaque compaction item，本地压缩仍作为回退。
- **缓存边界注册表（`agent/prompt_cache_boundary.py`）**：技能、Webhook 和 cron builder 声明 stable/volatile 字节边界，缓存规划器在边界放置断点；注册表仅存于进程内，miss 时回退整条消息策略。
- 轮转会生成新 session_id，在单事务中插入子行、写入压缩后消息并将父行标记为 compression，再切换会话 ID和重置 flush 基线；标题由后续步骤补写（`conversation_compression.py:3343, 3393-3436`）。旧行保留语义见会话与消息管理笔记 §1.2 / §3.4。
- 原地压缩不轮转 ID，而是软归档旧行并让同一会话 ID贯穿整个生命周期（数据语义见会话与消息管理笔记 §3）。
- 压缩后系统提示词不变时继续使用缓存；消息列表则与轮转前副本区分，防止重复追加。

## 4. SDK、Provider、模型与协议交接

对话主循环位于 `agent/conversation_loop.py:1422` 起：

- 先构建本轮上下文（见 §2）。每轮顶部检查中断并消耗预算，再处理 steer、清理 sidecar 和长度续接标记，前置系统提示词，规划 prompt cache，执行 API 前压缩检查，最后按需流式调用 Provider；长度标记清理位置见 :1912-1914，API 参数构建见 `agent/chat_completion_helpers.py:1330`。
- 结束时由 `agent/turn_finalizer.py:70` 收尾：关闭中断的工具序列、补齐必要的 assistant 行、持久化会话、执行 hooks 并生成结果；终局清除中断状态（:727）。
- **auto 路由身份**：auto 路由运行时按请求中的 provider/model 解析并在会话内保留，不回落配置默认值；辅助任务有独立路由函数（`agent/auxiliary_client.py:5633`）。reasoning 参数随 agent 配置进入请求构建（`chat_completion_helpers.py:1348`），具体解析点本快照未逐行核对。

## 5. 流式事件、缓冲、节流与顺序

发送任务函数（`server.py:9707` 起）的发射链：

1. 清除每轮开头的中断状态（:9736-9740）；
2. 写入回合开始标记（:9773）；
3. 发出空 payload 的 message.start 事件（:9741）；
4. 流式回调处理增量文本（:9968-9976）：维护 resume 快照，生成 `{text, rendered?}` payload，依次进入 TTS 队列并发出 message.delta；快照入口见 `server.py:7303`。

WS 端对 message.delta 等高频帧做 token 合批（`ws.py:44-60`，间隔 0.033 秒，约 30fps），任何非流式帧先冲刷缓冲保证顺序（:145-159）。

桌面端事件→状态层（`use-message-stream/gateway-event.ts`、`use-message-stream/index.ts`）：

- **流式节流**：桌面端按会话累加增量文本，再用 setTimeout 调度刷新，避免后台窗口 rAF 挂起；刷新间隔取固定下限与上次实测成本三倍中的较大值，并受上限约束。实现见 `use-message-stream/index.ts:235-342` 和 `use-message-stream/utils.ts:67, 73`。多类事件处理结束时都会触发刷新，事件清单见 `gateway-event.ts:594/637-643/706/733/745/768/857/865/1190/1280`。
- 事件状态转换为：start 刷新并置 busy，delta 累加，complete 合并最终文本。

## 6. 完成、异常、半截流与最终回写

发送任务函数（`server.py:9707` 起）的收尾链：

1. history 替换带版本防抖（:10088-10150）：版本未变直接替换，仅有 model-switch marker 时合并，真正不同步则不写并记录 warning；
2. 压缩轮转后重新锚定 session_key（调用点 :10158，迁移会话配额租约和 yolo 状态的实现见 :4919）；
3. status 有 interrupted、error、complete 三态（:10162-10167）；中断文本若以取消元数据前缀开头则清空，避免桌面将其画成回复；无可见回复但存在真实错误时，显示 `Error: <detail>`（:10176-10188）；
4. 发出 message.complete，payload 包含文本、用量、状态以及可选的 reasoning、warning、billing、rendered 和错误恢复信息（:10196-10232）；错误时保留可重放快照，异常路径统一发送终态错误帧（`:7796`），可带 partial 文本。
5. finally 阶段清理记忆、发送 TTS sentinel、清除运行状态并结算事件。

桌面端收到 complete 后合并最终文本：删除所有流式文本片段，以权威终态重写并保留 reasoning；临时气泡原位结算以避免双泡。结束后延迟 300ms 合并会话列表刷新，并按需从存储会话回填；压缩轮转的 turn 跳过回填，adopted turn 先水合。实现入口为 `use-message-stream/index.ts:538`，文本合并细节见 `lib/chat-messages.ts:242-266`。

## 7. 停止、重试、续写与重新生成

- **中断（服务端）**：
  - 服务端在主循环顶部、重试等待和空响应重试等位置检查中断；流式 API 入口会抛出 `InterruptedError`（`agent/chat_completion_helpers.py:806/822/1319`）。
  - `interrupt()`（`run_agent.py:3091`）设置中断请求，硬取消经过压缩提交栅栏，并向执行线程、工具 worker 和子代理传播。
  - `clear_interrupt(preserve_redirect=False)`（`run_agent.py:3237`）负责清理状态；保留重定向时仅在存在待处理重定向的情况下清除。
  - `redirect()`（`run_agent.py:3328`）只打断模型请求，不扩散到工具或子代理。
  - 服务端的 session.interrupt（`methods_session.py:2942`）请求硬中断并清理审批。
  - **回合租约（turn lease）**：租约超时采用 fail-closed 策略且可配置（`gateway/turn_lease.py`）；shutdown 时中断每个进行中的 API 回合。
  - **停止（桌面端）**：桌面端没有名为 `interruptResponse` 的符号；TUI 的同名对照为 `SessionInterruptResponse`（`ui-tui/src/gatewayTypes.ts:313`）。桌面停止操作先在本地定稿，再调用 session.interrupt RPC；随后本地 interrupted 状态拒收迟到流事件，complete 的中断分支只清 busy 并保留部分文本。停止按钮的界面反馈见 Chat UI 笔记 §5。
  - **重试**：三套实现都截断到最后一个真实用户回合后重发；真实回合的判定及数据变化见会话与消息管理笔记 §4。TUI 的 `/retry` 实现见 `ui-tui/src/app/slash/commands/core.ts:745-768`，桌面 reload/regenerate 见 `rewind.ts:140`，CLI 对照见 `cli.py:8714`。
  - **续写**：没有 `/continue` 命令或独立 RPC，只是普通 prompt.submit 文本“continue”（busy 时也只入队）；空响应恢复会重放占位 assistant 行，持久化前删除该占位结构（`run_agent.py:1940`、`turn_finalizer.py:268`）。
  - **编辑后发送**：桌面入口 `user-message.tsx:326-355`。点击进入编辑 composer，发送即执行“interrupt + rewind”；数据侧截断语义见会话与消息管理笔记 §4，服务端要求 `confirm_truncate` 见 §1。
  - **运行中干预**：session.steer（`methods_session.py:3219`）会把文本追加到本批次最后一条工具消息末尾，不新增消息也不破坏角色交替；没有可挂载工具时回存，未消费内容作为下一轮用户消息投递（`turn_finalizer.py:717-719`）。session.redirect（`methods_session.py:3252`）要求 agent 支持活动轮重定向，未就绪但正在运行时先入队（:3267-3273）。

## 8. 队列、多会话并发与后台生成

- 同会话 busy 时，优先按 steer 或活动轮重定向处理，否则入队并异步中断，返回 queued；具体分支见 `server.py:7598-7679`。queued 参数只用于排空队列并强制 queue 模式（`methods_prompt.py:147-150`），队列在回合结束后排空并用代际编号防串扰（`server.py:7682`）。
- agent 构建等待有 600 秒上限（`server.py:2035`）。
- 后台生成包括 auto-continue 和 async-delegation；它们会传递显示类型和元数据。AIAgent 可关闭后台复习，子代理异步任务则创建独立会话执行（数据语义见会话与消息管理笔记 §8）。
- 多会话并发与同会话串行化的实际运行行为未验证（见未验证事项）。

## 9. Agent、工具、知识库与附件注入点

- 工具执行会传入流式回调、用户消息持久化开关和会话任务标识（`server.py:9994-10015`），每轮顶部处理 steer，轮间刷新 MCP 工具，并运行 pre_llm_call 插件钩子（`turn_context.py:501-527`、:1152-1204）。
- 记忆有两个注入通道：内置 MemoryStore 进入 volatile 系统提示词；外部 provider 先预取，再以 sidecar 注入当前用户消息，轮后写回（`run_agent.py:4222`）。内部语义不在本类目展开。
- 附件注入：@file: 和 @context 引用在发送任务中预处理（`server.py:9821-9850`）；图片按路由选择 native 像素直传或 text vision 预分析（`server.py:9858-9907`）。桌面端按跨文件系统情况选择附件 RPC 或共享本地路径；本次未找到 `[[Image N]]` 指引，图片指引是 @image:<path> 指令行。`input.detect_drop` 仅存在于 Ink TUI 的 `tui_gateway/methods_prompt.py:736`，桌面 renderer 使用 file/image attach RPC。拖放与附件分流见 Chat UI 笔记 §3。

## 10. 退出恢复、日志与已确认边界

- 崩溃恢复：回合标记写入 `<home>/desktop/interrupted_turns.json`，限制为 32 条/24 小时/64KB，并在客户端已见到结果后清除（`turn_marker.py`）。session.resume 会按标记自动重跑并用 attempts 计数防止循环；断连窗口的失败回合还可从 inflight 快照恢复（`server.py:7796-7803`）。标记文件语义见会话与消息管理笔记 §2.3 / §3.4。
- 桌面端请求层：prompt.submit 超时为 1800 秒，回合完成依靠流事件而不是 RPC ACK；找不到会话或超时后，resume 会触发一次重试，busy 则按目标会话重试（`submit.ts:650`、`use-prompt-actions/utils.ts:146, 244`）。
- 可观测性：message.complete 携带 usage 和 billing，错误终帧携带 error、recoverable、partial 和 failure_reason（`server.py:10196-10230`）。任务级日志和 trace 不在本次调查范围。
- 已确认边界：无 token 级截断原语（§3）；`display_type` 参数不存在（§1）；桌面端没有 `interruptResponse` 符号（§7）。

## 当前压缩与 Provider 交接

上下文压缩的默认保留策略已收紧为 lean tail：保护尾部的下限与上限分别是 10,000 和 25,000 token，另保留受预算约束的近期用户消息与工具回合（`agent/context_compressor.py:869-883`）。因此“压缩后尽量保留大段原始上下文”的旧理解不再成立；当前实现优先保留较短的可验证尾部，其余依赖压缩摘要。ACP 侧也把多个客户端收敛到共享 OpenAI bridge，并在支持工具调用的 agent-as-provider 场景中将该 provider 自身的工具工作合并回当前 turn；运行时效果仍未执行验证。

## 11. 未验证事项

- `display.busy_input_mode` 各模式（steer/redirect/queue）在真实 provider 上的行为未验证。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证（持久化入口在会话与消息管理笔记 §2.3）。
- 崩溃重放的端到端行为、多会话并发打到同一后端的表现未实测。

## 12. 关键源码索引

- prompt 方法：`tui_gateway/methods_prompt.py`（:67-346）；`hermes_cli/input_sanitize.py`（:65-70）。
- 网关：`tui_gateway/server.py`——`_run_prompt_submit`（:9707）、`_handle_busy_submit`（:7598）、`_drain_queued_prompt`（:7682）、`_sync_session_key_after_compress`（:4919）、`_emit_terminal_turn_error`（:7796）、`_wait_agent_for_prompt`（:2035）、`_maybe_schedule_auto_continue`（:7444）、`_event_frame`/`_emit`（:1566/:1573）、`_append_inflight_delta`（:7303）。
- session 方法：`tui_gateway/methods_session.py`——interrupt（:2942）、steer（:3219）、redirect（:3252）。
- 上下文构建：`agent/turn_context.py` `build_turn_context`（:430）、`compose_user_api_content`（:53）；系统提示词：`agent/system_prompt.py` `build_system_prompt_parts`（:152）。
- 主循环：`agent/conversation_loop.py` `run_conversation`（:1422）、`_restore_or_build_system_prompt`（:555）；收尾 `agent/turn_finalizer.py`（:70）。
- 压缩：`agent/context_compressor.py` `should_compress`（:2906）、`agent/conversation_compression.py` `compress_context`（:2150）、`agent/native_compaction.py`（gpt-5.6 native 服务端压缩）、`agent/prompt_cache_boundary.py`（stable/volatile 缓存边界注册表）。
- 运行与中断：`run_agent.py`——`interrupt`/`clear_interrupt`/`redirect`（:3091/:3237/:3328）、`_compress_context`（:7448）、`_sync_external_memory_for_turn`（:4173）。
- Provider 交接：`agent/chat_completion_helpers.py`（`build_api_kwargs` :1330、`InterruptedError` 抛出点 :806/:822/:1319）。
- 崩溃标记：`tui_gateway/turn_marker.py`。
- 桌面端：`apps/desktop/src/hermes.ts`（HermesGateway :230）；`use-prompt-actions/submit.ts`（submitParams :619）、`rewind.ts`（finalizeInterruptedMessages :122、planReload :140）、`utils.ts`（:146/:244）；`use-message-stream/index.ts`（completeAssistantMessage :538、scheduleSessionsRefresh :153、hydrate/adoptedRunningTurn :695-712）、`gateway-event.ts`；`lib/chat-messages.ts`（mergeFinalAssistantText :242）；`apps/shared/src/json-rpc-gateway.ts`、`use-gateway-request.ts`（按需重连与失败重放）。
