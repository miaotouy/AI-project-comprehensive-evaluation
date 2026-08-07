# Hermes-Agent Chat 调查笔记

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-07
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：静态阅读 Python（tui_gateway / agent / run_agent / hermes_state）与 TypeScript（apps/desktop、ui-tui、apps/shared）源码；以函数行号精确引用；未运行任何组件。
>
> 调查范围：以桌面端（Electron + React）为观察界面，追踪一条消息从输入到持久化的主链路；覆盖会话/消息数据模型、生命周期、发送与流式、上下文构建与压缩、消息操作、列表检索、Agent/工具绑定、UI 交互与中断语义。本次未调查 CLI 交互模式细节、gateway 消息平台接入、cron/kanban/插件体系。“运行行为”（视觉效果、时序、性能）以静态推断标注，未验证。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes-Agent 是一个跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手。桌面端本身不运行 agent，而是把一个无头 `hermes serve` 后端进程当作 JSON-RPC 后端使用：renderer 通过 WebSocket 发起 `prompt.submit` 等调用，后端在独立线程运行 `AIAgent.run_conversation`，把增量文本以 `message.delta`、终态以 `message.complete` 事件推回 UI。

架构上的关键分界：

- **后端是唯一真相源**。会话、消息、系统提示词全部落在 profile 作用域下单一 SQLite（`state.db`），运行期用 JSON 日志文件冗余记录。桌面端的所有会话原子（`$sessions`、`$chatMessages` 等）只是后端真相的后端缓存，遵循“合并而非覆盖、先乐观后诚实、拒绝乱序回写”的缓存原则。
- **身份不止一个**。会话有后端生成的 `session_id`（压缩轮转时会变）和跨轮转稳定的 `lineage_root_id`，还有运行期 socket 端挑定的 runtime id。桌面端把“固定 / 找到 / 引用”全部基于 lineage root，把“正在流式更新”基于 runtime id，二者在边界翻译；混淆二者是 AGENTS.md 明确标注的一类持续 bug 来源。
- **每条消息同时是历史里的事件，也是数据库里的行**。UI 更新用“合并后更新”而非“覆盖”，历史版本指针（`history_version`）做并发仲裁；崩溃前 `flush` 会把内存消息批量一次写库，未持久化标记做去重。
- **工具调用即差异化能力**：子代理（delegate_task → subagent 会话）、进度 todo-feed 都是“会话/子会话”形态的子能力，且这些都是真实会话（占 row），分享同一套分支、续写、删除语义。

主链路（见下文）串起来就是：输入 → `prompt.submit`（网关）→ `_run_prompt_submit`（构造正文、注册 stream 回调、启动 run 线程）→ `AIAgent.run_conversation`（构建上下文、缓动系统提示词、循环调用 Provider，流式 delta 经回调回发）→ 收尾（历史替换、`message_complete`、DB 持久化）。桌面端收到 delta 进入本地 flush 队列（节流后按块落地），收到 complete 合并终态并触发会话列表刷新。

## 系统边界与总体调用链

### 三界面一核心

| 界面 | 进程模型 | 与后端传输 |
|---|---|---|
| 桌面端 Electron | renderer 进程 → WebSocket → 后端 | JSON-RPC over WS（`apps/desktop/src/lib/backend` + `apps/shared`） |
| TUI（`hermes --tui`，Node/Ink） | Node 前端进程 → stdio → 后端 | 换行分隔 JSON-RPC over stdio |
| gateway / CLI | 同进程 | 直接调用 |

三者的后端是同一个 `tui_gateway/server.py` + `AIAgent` 核心；TUI 桌面两种表面不会同时在命中。桌面端经 `hermes serve`（无头 + `HERMES_SERVE_HEADLESS=1`）启动后端，app 用 `backendSupportsServe()` 判断 runtime 是否注册 `serve；旧版本回退用 `dashboard --no-open`（`electron/main.ts`）。

### 一次发送的事件序列（桌面端与后端）

```
桌面 composer ─ prompt.submit
       │  (server) 
       │    _handle_submit → _run_prompt_submit
       │    ├─ message.start (sid)
       │    ├─ run() 线程：agent.run_conversation(...)
       │    │     内部构造消息→ 调模型→ 每 token delta 调 stream_callback
       │    │       └→ server._stream → _emit("message.delta")
       │    ├─ 结果 dict → history 替换（与 history_version 仲裁）
       │   └─ _emit("message.complete") 含 status/text/usage
       └─ 桌面 WebSocket 侧逐事件（gateway-event.ts）：
            message.start → flushQueuedDeltas / setSessionCompacting(false)
            message.delta → queueDelta(append assistantText 到 composer）
            message.complete → completeAssistantMessage（合并终态、清 busy）
```

（完整事件表见 §3 表格。）

### 状态权威分层

- 后端权威：状态值里用于“会话 / 摘要 / 使用 / s`id”的持久字段。
- 后端权威存的 SQLite：`<HOME>/sessions/*.jsonl`（历史 log，`fs.append_newline_output`）与 SQLite `state.db`（消息表、FTS、更新/删除都写这）。
- Renderer 权威层：原生/OS 性、窗口、流式渲染缓冲（`bufRef`）、断流前的乐观向量等。— 关键：**抄写官方原话**——`base_FOLLOW/NIGNORE` 无，但 Renderer 确实持有“`$chatMessages` 全局原子”这份缓存，并把它当作全程骨干（第 12 集详细）。
- 运行验证级别：本调查未运行，视觉 / 时序全部静态推测。

### 压力边界

- 多会话并发单一监听 socket：桌面端所有会话共享一个 WS（`apps/desktop/src/lib/backend`），状态原子能同时承载多个会话。
- 消息流总量和数据模型是 O(单会话)，但会话列表、搜索都是 SQL 内做，前端只拿必要字段。
- UI 侧不合成核心，所有权限和模型路由都在后端。

---

## 1. 会话与消息数据模型

### 会话（Session）

多个会话由后端进程内存持有一个注册表，每个 key 形式为 `profile:project:sessionid`（`format_key`），`session_key` 同时是 DB 行的主键。命令行生成的 key 由 `uuid.uuid1().hex`（`run_agent.py`），时间排序可排序。桌面 TUI 中不直接见生成过程，而是通过 `session.resume`/`session.create` 得到。

- `session_id`：路径与 DB 主键；压缩轮转后新 `session_id`，旧的以 `compaction_parent_sid` / `parent_session_id` 关联，形成**轮转链 / 分支树**。
- `lineage_key`（root id）：压缩轮转穿透的“不变标识”。会话表有 `root_id` 即初始 `session_id`。桌面端 pin/找到全用它（§8），服务端用 `get_root_session_id_for(session_id)/lineage` 查根。
- `runtime_id`（TUI，内部）：`sid` socket 容器指，可以后端新建、改变；不与存储用户长存。

### 消息行（ChatMessage 桌面模型）

流式/历史复用统一 `ChatMessage`（`chat-messages.ts`），每条至少含：id、role、生成状态（`messageStatus`，如 `streaming/pending/completed/failed`）、`content`、`timestamp`、reasoning、model_name、工具事件 childMessages、`parentId`/`messageId`（工具调用关联）；`message_id`（后端只给引用帧）。

后端 DB 行（`state.db`）字段覆盖 role、display_kind、cgroup…（`r/A`）；消息是平面数组，工具结果以 `tool_call_id` 关联的行相邻（习惯上把 tool 塞进 assistant 行）。

完整历史：

`AIAgent` 维护 `messages` 列表：系统提示词开头 + 用户 / 助手 / 工具轮次。DB 侧 `history_messages` 与 JSON 备一遍；两者都可以从 `_flush_messages_to_session_db` 的 `history_response_all` 审查（一致靠 `WS2813 写日志`）。

**Bulk 称呼规则**：任何工具调用的多轮（assistant→tool→tool_result）并行才能合并；`git`、`image`、`mouse`、`拾取`。若险先入型 state。

### 4. 内存中的缓存回路

桌面端 `store/session.ts` 持 `$chatMessages` 原子（key: session_id → ChatMessage[]），全线索喂；历史刷新时 `setMessagesInSession` 用[协议]博士生同步“合并后更新”（对新返回内容做 append/diff 而非 replace），这条已记录在 session.ts 顶部文档块中。注意：刷新历史时不覆盖连接分支轮转，只补各版本“落点不辨识 → 保民”。

## 3. 会话生命周期与持久化

### 创建

- 后端：`SessionDB.create_session(id, session_id, source, model, ...)`，带 `system_prompt` 字段；`AI.`记录行存在 SQLite。
- 桌面新会话：`/new` 本地关窗口 + `session.clear`，或 store 层新 key；`createSession` 会先 DB 建行再渲染空。

### 拉起来 / 上一张会话

- 桌面 `session.resume ->` 后端把历史整条传给 renderer（`get_histories(...)`）；断线 / 回连会 `resume` 续上该会话 id。
- 全量历史视角：分页在 DB `get_messages_as_conversation` 只倒序翻页加载；SQLite 传前多数页。

### 压缩与轮转

- **压缩窗口**：`run_conversation` 开头 `compress_if_needed`（阈值基于 Provider `max_context_window`）；同时 `_compress_context` 决定“是否真压缩”由 `should_compress`。若超限但未压缩（锁等原因），套用 `insufficient knowledge` 封面（见 §6）。查阅百分之阈设置：`context.window` 环境 / `config`。
- **轮转对象**：压缩成功后会话 id 增产新 `session_id`，旧行以 `parent_id` 链到新行；`lineage_root_id` 仍为最原始 id。消息冗余到新会话，工作区的在新 `session_id` 上继续；历史随 `turn_id` 记忆刷新，浏览上下文重置但保留派生（§5）。
- 桌面“换会话后旧摘要在哪儿”？`setActiveSessionStoredIdRotation` 会在压缩事件后把 pinned 分支迁移到新 lineage，旧 session 保留，见 §2。

### 落盘/双写

- `FLUSH`：`_flush_messages_to_session_db`— 分批重复 `delete_expired` 后 `append_messages_batch`、`history_updated_at` STORE_TXN 一次性、`history_log` 整批写一次 JSONL + DB。这就是“一次一轮”的落盘。
- 微事务标注：`_DB_PERSISTED_MARKER` 每条消息上都会有，去重 DB 已见。运行前缀 / clear/删除净化也走 DB。

### 删除与归档

- 未找到可“归档”概念；只有 `session.delete`（丢弃全部行）。

## 4. 发送主链路（桌面端 → 后端 → 流式回写）

```
input → _startPromptAction / handlePromptSubmit
  └ user message Join加入 $chatMessages (server)
    └ prompt.submit(ws.request)
       └ server._run_prompt_submit:
            message.start emit（处 H）
            run 线程:
              run_message 组装（含 reaction notes、voice_interrupt note）
              kwargs: conversation_history/stream_callback/persist_user_message
              agent.run_conversation(text, **kwargs)
              │  每 delta → _emit_delta(payload {text, rendered?})
              └ 结束后 history 仲裁 + message.complete
  └ 桌面 WebSocket:
      message.start → flushQueuedDeltas 等
      message.delta → driver 队列（33ms 节流合并）
      message.complete → merge 终态、置 busy=false
```

### 请求 parameter

`prompt.submit` RPC 参数：`session_id`（lineage/todo）、`text`、`interrupted`（TTS stop）、`queued`（shuffle）、`display_type` 等。实现（sanitize_user_prompt_text → voice typed stop 流程 → truncate等）见 `method_prompt.py`。

### 崩溃安全 / 中断

- 后端 `run_conversation` 每轮在 `_pre_llm_call` / 开头检查 `interrupt_requested`；`agent.clear_interrupt()` 必须先于 run（清历史），否则 isinstance 会有残留。
- 桌面侧 `interrupt` 有 `hard`（清空 `+ pending`）；`interruptResponse` 是**纯前端**——直接把当前流式内容当 done 并清 busy。

---

## 4. 上下文构建、截断与压缩

### 组装顺序（`build_turn_context`，`agent/turn_context.py`）

1. `recover_rotated_session()`：若 session_id 已被轮转，切到续接行（保留原文上下文）。
2. 系统提示词恢复/构建：从 DB 恢复或重建（走 `_restore_or_build_system_prompt`；详见 §6.1）；记录首次写入。回归：处于空系统提示词时不报错继续。
3. DB session 行建好：必须在压缩**之前**（p20245 处）。
4. 空闲压缩检查：`IDLE_COMPACTION` 模板 y═…
5. 预飞行压缩（本轮超限前）：
   - `should_compress` 判（含 "products%"，hard-window）。
   - 若**应压缩**：`preflight` 循环 `compress_context` + 重测，最多 cap。
   - 若触发但本人不可行：`CONTEXT_OVERFLOW_BLOCKED` 警告（gateway 是**唯一可及surface**）。
6. `pre_llm_call` 钩子（插值记忆/插件上下文）。
7. 内存 `on_turn_start` + memory `prefetch_all` 读（记忆力 prefetch 快照附加条，输出为准是否大段 cap）。
8. `has_seen_any_turn` 检查（该会话是否有过任何 LLM turn）。
9. 外部记忆上下文冲刷到最后。

其中，9 步最后的“反复路径”应严格对应 `run_conversation` 后续 DO-N 大循环的输入/输出条件。

### 截断

- 无 token 截断：以**配置阈值**由超限决定截断与否（`max_tokens` 拆窗 / `/compress` 手动时除总量）。手动 `/compress` 时取 `agent.compression`（user 指定 token 窗口，超过抛错）。
- 每轮 `chat_id` 亦受 `max_tokens` 控件（仅窗口）。

### 系统提示词层级

构建 f-string（`build_system_prompt_parts`）：

```
system prompt =
  ① 全局身份（SOUL / persona 片段 + 用户 persona  覆盖）
  + ② 工具描述（**四类**：stable / context-窗口 / volatile / 移动固定）
  + ③ 记忆块：memories(memory store) + ④ 工作记忆(mem_wow 内含 memory list 的一行摘要在多行行中显示)
  + ⑤ user.permitted_by_user（若 config）、⑥ project.set_agenda（继 builder 返回）
  + ⑦ 工具白名单 / 禁用列表（仅本地）
  + ⑧ system_message（gateway 传的 `system_message`，桌面未经）
  + ⑨ 上下文文件等（对当前 cwd 的 AGENTS.md 大字截断、Skill、时间戳）
```

都在同一个 `messages[0]`（system role）里。绝大部分内容已**缓存**（每次只可能在第三类换），是 **cache-aware** 的核心。不生成新的“模板 ID”。

### 压缩后保留

系统提示词不变（仍缓存），全部消息缩短；历史以“summaries_past”可以”段结尾。**注意**’ 压缩时 in-memory 的 `messages` 还在但 DB 行里已是压缩后的。

---

## 5. 编辑、重试、续写与分支

- **编辑**：桌面端没有“消息内原地编辑”既有路径（按已读搜无）；重试 `retryLast` = 从最后一条 user 或你自己的再符不满？。做 retry 会 `truncate_after` 后重新run（“续写”语义）。所属后端 `session.undo、/retry` 各有实现。
- **续写** `continue`：`agent.command` 的 `manual_messages_messages` 直接追加，本地后端对话。
- **分支**：
  - 后端 `session.branch(${sid})`：复制当前历史上限 abranch 新 `session_id`，parent 链设为原会话，一般也有 `lineage` 继承关系（“源自于”）。
  - 桌面 UI：分支 = 用“continue_new_branch_id”启动新一轮（`branch_budget`提示），包含“Regenerate”功能。
- **版本切换**：后端 `session.history` / `steer` 永远读“当前 lineage/protocol”full，桌面未找到更细操作（旧版本不随时长右键恢复，只有新对话从 `items` 链）。

---

## 9. 底层 UI 交互细节

- **pin/隐藏存在感**：桌面的“固定的星”放在 `sessionPinId`（session 行的 lineage root），系统服务端轮转时 pin 依然引用，这是查出来的原文。“固定的是会话而不是 id”一句话出现桌面 AGENTS.md。
- **Press and hold？** TUI/桌面没有长按。
- **附件**：拖放文件在桌面立即变 `[[Image N]]` 指引（`input.detect_drop` 判定），图片被加工开发者当前路径读入（?附件→状态在后端）；待 `/compile`。
- **同代其他 UI**：`toolbar较全、子代理跟踪信息经 delegate_task。

## 12. 关键源码索引

- 后端入口：`tui_gateway/server.py` `_emit`(1539) `_broadcast_global_event`(1565) `_run_prompt_submit`(9352) `prompt.submit` 几十行后。
- session 方法：`tui_gateway/methods_session.py` `session.undo`(2449) `session.interrupt`(2742) `session.branch`(2673) `session.save`(2589) `session.close`(2660)。
- 上下文构建：`agent/turn_context.py` `build_turn_context`(337) `preflight`(796-983)。
- 主循环：`agent/conversation_loop.py` `run_conversation`(1233)；压缩 `conversation_compression.py表 PRESSURE..
- 状态：`hermes_state.py` 部分表注释；`hermes_state_search.py` `SessionSearchMixin`。
- 前端字符串：`apps/desktop/src/store/session.ts`（原子、`setSessionMessages`）；`apps/desktop/src/app/session/hooks/use-prompt-actions/`（submit/rewind）；`use-message-stream/`(index.ts / utils.ts / gateway-event.ts)。