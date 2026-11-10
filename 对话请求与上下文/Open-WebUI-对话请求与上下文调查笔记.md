# Open WebUI 对话请求与上下文调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：直接阅读源码（FastAPI 主入口与生成管线 `utils/middleware.py`、任务调度 `tasks.py`、Socket.IO 通道 `socket/main.py`、前端 `Chat.svelte` 发送链与事件分发）
>
> 调查范围：一次生成任务的提交入口、上下文拼装、Provider 交接与多模型 fan-out、Socket.IO 流式通道、停止/重试/续写、队列与并发、后台任务、外部能力注入点；会话数据语义与前端工作台分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的生成主链路：`POST /api/chat/completions` → `main.py: chat_completion`（1084 行）→ `utils/middleware.py: process_chat_payload`（2055 行）→ 上游（openai/ollama/pipe）→ `build_chat_response_context` → 流式或非流式响应处理器。

- 多模型并行时，端点给每个选中的模型各起一个 `asyncio.Task`，只有第一个模型额外携带标题与标签生成任务；任务同时登记进 Redis（哈希记账、pubsub 广播停止命令），供多实例协调（`main.py:1702-1781`）；
- 流式推送统一由 Socket.IO 的 `events` 事件承担，按 `user:{user_id}` 房间发射，前端再按消息类型分发约 25 种更新；REST 接口只负责发起与终止任务（`socket/main.py:968-995`）；
- 标题、标签、追问与记忆抽取在模型生成结束后，由后台任务处理器串行执行（`middleware.py:3543`）；
- 停止链路：前端停止按钮按会话或按任务发起取消，服务端经 Redis pubsub 把停止命令广播到各实例，各实例再取消本地任务，前端随即将该会话所有回复消息标记为已完成；
- 提交排队发生在前端：同一会话生成期间的新提交进入队列，当前回合结束后由队列处理函数发出（`Chat.svelte:2157-2177`）；
- 任务系统由 asyncio 任务对象加 Redis 记账组成，任务不在 worker 之间迁移，Redis 只用于跨实例取消与状态查询（`tasks.py`）。

## 系统边界与生成任务主链

```text
前端 submitPrompt（构造用户消息挂到 history 树）
  -> sendMessage（为每个选中模型创建 assistant 占位，无 chat_id 时创建 temporary 会话）
  -> sendMessageSocket -> POST /api/chat/completions
  -> main.py chat_completion（请求解析、新会话判定、占位落库）
  -> process_chat_payload（管线注释：Pipeline Inlet -> Filter Inlet -> Chat Memory
     -> Web Search -> Image Gen -> Code Interpreter -> Tools Function Calling -> Files
     -> Filter Request（消息定稿前；工具循环每轮之后重跑））
  -> chat_completion_handler（真实模型调用）
  -> streaming_chat_response_handler（delta 缓冲、tag 切分、工具调用、后台任务）
  -> Socket.IO 'events'（user:{user_id} 房间）-> 前端 chatEventHandler 按 type 分发
```

边界：`chat.chat.history` 快照与 `chat_message` 表的双写语义在会话与消息管理；前端按钮状态、Overview 树图导航在 Chat UI；消息内容渲染在消息渲染器。排除频道（channel）消息、Ydoc 协作、Direct Connection 客户端内部实现（客户端侧协议未逐行核对）。

## 1. 提交入口、任务对象与状态机

### 1.1 前端发送链路（Chat.svelte）

1. 提交阶段 `submitPrompt` 把用户输入变成一条挂在 history 树上的用户消息：先收集非图片文件，再生成带 uuid、父节点、子节点列表、Unix 秒时间戳与目标模型的节点，挂到当前节点之下并把 `currentId` 移过去，最后交给发送函数（`Chat.svelte:2493-2540`）；
2. `sendMessage`（2773-2935 行）为每个选中模型创建 assistant 占位消息，并用 `modelIdx` 记住列序；会话尚不存在时以 `temporary:{socket.id}` 作为临时会话 id（`src/lib/utils/chatId.ts:4`），期间还检查模型是否支持视觉输入；出站时只发主模型一条请求，选中的全部消息经 `message_ids` 列表随行；
3. `sendMessageSocket`（2974-3259 行）组装请求体，字段按用途分四组：
   - 消息与流：是否流式（默认开启）与消息数组；对话历史只在临时会话中随请求携带，持久会话由后端从数据库加载；
   - 参数：合并后的设置与会话参数、stop tokens，以及流式用量开关；
   - 能力与注入：文件、过滤器、工具与技能、终端、工具服务器、功能开关与变量；
   - 身份与续写：会话与文件夹标识、当前消息 id 与选中消息 id 列表、父消息、用户消息、再生提示词、续写目标消息 id；标题与标签只在新会话首条消息下发，追问每次携带；
4. 响应阶段收集返回的任务 id；新会话拿到的 chat_id 会写回 store 并把地址栏替换为 `/c/{id}`，随后刷新会话列表、持久化本次会话参数（3221-3253 行）。

### 1.2 服务端 `chat_completion` 端点（main.py 1052-1794 行）

1. 请求解析阶段先从请求体取出消息 id 列表、用户消息、会话变量与工具服务器配置；消息 id 兼容新格式的列表（每项含模型、消息与列序号）与旧格式的 dict，工具服务器在调用方缺少直连权限时直接丢弃；模型参数按全局默认、模型级、请求级由低到高逐层覆盖（1062-1178 行）；
2. metadata 随后一并构造，装入用户与会话标识、注入字段以及流式分片大小、推理标签、压缩阈值、函数调用方式等请求参数，随请求向下传递（1180-1209 行）；
3. 新会话判定读取请求中的父消息：显式给出 `parent_id` 为 None 且没有 chat_id 时判为新会话，并生成 uuid4 作为会话 id（1139、1211-1212 行）；
4. `channel:` 开头的会话单独走权限门：群聊与私信要求调用者是频道成员，其余会话要求写权限，同时校验 message_id 属于该频道（1223-1258 行）；
5. 新会话先落库：依全部 assistant 占位消息构造 history 快照（保留列序）并插入会话记录，随后依次发出会话创建、会话列表刷新与各条消息创建的事件，插入会话文件，最后在请求带标题生成开关时启动初始标题后台任务（1260-1392 行）；
6. 已有会话走另一条路径：校验所有权后持久化会话级字段与变量，保存用户消息并取消对应定时器，把新节点挂到祖父节点的 childrenIds 上，再保存全部 assistant 占位消息（1393-1533 行）；
7. `process_chat` 串起一次完整生成：拼装上下文、调用真实模型、把 provider 返回的 400 及以上状态转成异常、构造响应上下文并进入响应处理（1547-1570 行）；
8. 取消与异常的出口不同：任务被取消时用 `asyncio.shield` 保证 `chat:tasks:cancel` 事件仍能发出；普通异常把错误写入消息，再发错误事件与取消事件；缺少 chat_id 的旧路径与直连路径退化为 HTTP 400（1571-1622 行）；
9. finally 阶段负责清理：断开 MCP 客户端、注销任务并在无活动任务时发出 `chat:active=false`，最后回填子代理产生的内部消息（1623-1700 行）；
10. **多模型 fan-out** 需要 session_id 与 chat_id 同时存在，每个模型一个 `asyncio.Task`；首个模型携带标题与标签任务，其余模型剔除这两项但保留追问；子代理发出的内部请求直接 await、不注册任务；fan-out 前先发 `chat:active=true`，最终返回状态、任务 id 列表与会话 id；条件不满足时走同步的单模型路径（1702-1785 行）；
11. 三个生成函数名指向同一实现，并注册为 `app.state.CHAT_COMPLETION_HANDLER`，供子代理、定时器与自动化内部重入；Anthropic 兼容端点转换 payload 后复用同一入口（1789-1794、1897-1954 行）。

## 2. 上下文来源与拼装顺序

- 上下文拼装由 `process_chat_payload` 统一负责（`utils/middleware.py:2055-3120`）：它按文件内注释的固定顺序依次经过管道入口、过滤器入口、会话记忆、联网搜索、图像生成、代码解释器、工具函数调用与文件处理，并在消息定稿前再补跑一次 Filter `request`；arena 模型在这一入口解析成具体子模型；
- 持久会话的历史由后端从数据库加载（`load_messages_from_db`，`utils/middleware.py:1897`）：优先取消息表行以保留结构化输出，续写时额外加载被续写的那条 assistant 消息；系统提示词从请求首条消息提取后置前，图片文件转成 image_url 内容块。上下文的「历史部分」以数据库行或会话快照为准（数据侧见会话与消息管理笔记）；
- 外部能力以请求体字段注入：工具、技能、终端、工具服务器、过滤器、文件、变量与功能开关，构造过程见 1.1 第 3 步。

## 3. 预算、截断与压缩

压缩受服务端开关控制；有效阈值取请求正整数覆盖值与服务端上限的较小值。预算优先使用最近一条消息的 provider 用量加后续消息估算；无用量时按字符约四比一估算，图片按固定开销计入。保留比例限制在 10%–50%，默认 40%，先按消息数取目标再对齐用户轮次；工具循环中改为对齐完整调用/结果批次，避免切断协议配对（[`utils/context_compaction.py:224-260,372-400`](../../open-webui/backend/open_webui/utils/context_compaction.py#L224-L400)）。

请求处理有两个时点：存在 Filter、Pipeline、审批恢复或 legacy 工具模式时，在能力注入前压缩，使这些处理器读取压缩历史；普通 native 请求先应用已有检查点，再在最终请求已组装后生成摘要，便于同模型摘要请求复用原提示缓存。相同模型且保留边界可唯一定位时，摘要请求复放完整出站消息并追加摘要指令；无法取得摘要时改走独立摘要请求。摘要以 `[CONVERSATION SUMMARY]` 系统消息进入后续请求；压缩异常保留当前历史（[`utils/middleware.py:2184-2225`](../../open-webui/backend/open_webui/utils/middleware.py#L2184-L2225)、[`utils/middleware.py:3001-3044`](../../open-webui/backend/open_webui/utils/middleware.py#L3001-L3044)、[`utils/context_compaction.py:403-532`](../../open-webui/backend/open_webui/utils/context_compaction.py#L403-L532)）。

| 压缩入口 | 持久化检查点与恢复 |
|---|---|
| 请求前自动压缩 | 保留段从 user 消息开始且属于持久聊天时，把摘要写到首条保留消息的 `contextSummary`；读取最新检查点时只送该节点以后的路径 |
| 工具循环内压缩 | 每轮工具结果回注后再次检查预算，在 assistant output 中写 `open_webui:context_compaction` 标记，保存摘要与首个保留调用的 call id；恢复时裁剪到该调用批次，并移除仅供内部使用的标记 |
| 手动压缩 | `POST /{id}/compact` 检查活动任务后调用 `compact_chat_branch`，摘要当前分支中最后一条以外的消息，把检查点写到当前节点；原历史仍保留 |

证据：[`utils/context_compaction.py:122-172,175-221,326-369`](../../open-webui/backend/open_webui/utils/context_compaction.py#L122-L369)、[`utils/middleware.py:6006-6084`](../../open-webui/backend/open_webui/utils/middleware.py#L6006-L6084)。摘要质量、缓存命中和长上下文实际开销未运行验证。

## 4. Provider、模型与协议交接

- 上游分 openai、ollama 与 pipe 三系；拼装阶段先解析 arena 模型并归一参数，再由 `chat_completion_handler` 调用真实模型（`utils/chat.py:208`）；
- 子代理、定时器与自动化经应用状态上注册的完成处理器重入同一入口（1.2 第 11 步）；
- Direct Connection 模式另有一条客户端推理通道：服务端按用户、会话与请求 id 建立频道，事件调用（`get_event_call`）通过 `sio.call` 把请求推给客户端，客户端推理结果经频道回传，服务端用 `StreamingResponse` 以 SSE 转发。这是唯一保留 HTTP SSE 出口的路径，普通聊天全程走 Socket.IO（`utils/chat.py:49-148`）；
- Anthropic 兼容端点把 payload 双向转换后复用同一入口。

## 5. 流式事件、缓冲与顺序

### 5.1 服务端（socket/main.py）

- 事件按用途分别注册：用量与心跳属于轻量通知，会话事件在服务端读取 `last_read_at` 后向房间广播 `chat:list`，此外还有频道事件与 Ydoc 协作事件（`socket/main.py:540-587`）；
- `get_event_emitter`（`socket/main.py:1057`）把 payload 以 `{chat_id, message_id, data}` 的形状发到 `user:{user_id}` 房间的 `events` 事件；开启落库时按事件类型写入消息（数据语义见会话与消息管理笔记第 6 节）：

  | 事件类型 | 落库方式 |
  |---|---|
  | `status` | status_history 追加 |
  | `message` | content 追加 |
  | `replace` | content 覆盖 |
  | `embeds` / `files` | 追加或覆盖 |
  | `source` / `citation` | sources 追加 |
- `_make_channel_emitter`（`socket/main.py:946`）：`channel:` 会话专用，`chat:completion` 按 `THROTTLE_INTERVAL = 0.15` 秒节流后更新频道消息并 emit `events:channel`；另处理 `files` 事件——登记频道文件、回填消息 id 并更新消息 data.files。

### 5.2 流式响应处理器（utils/middleware.py `streaming_chat_response_handler`，3750 行）

按处理顺序分五步：

1. 注入：把事件发射器、事件调用、用户、元数据、OAuth 令牌、请求与模型等参数连同会话与消息 id 一并写入 `extra_params`，交给管道与过滤器使用；随后执行 Filter `request` 并生成 task_id；
2. 标签切分：内嵌的标签处理器按 reasoning、solution 与 code_interpreter 三类标签切分输出（`middleware.py:4202`）；
3. 缓冲：增量按累计数量与分片大小聚合后排队（`middleware.py:4740`）；
4. 工具与收尾：解析 SSE 的 `data:` 前缀并执行多轮工具调用，结束处依次发布生成完成事件、运行 outlet 过滤器与后台任务（`middleware.py:5671-6279`）；
5. 取消包装：重试与取消由 `stream_wrapper` 统一包装，取消时关闭上游响应体并保存半截状态。

推理增量与 reasoning_details 同时到达时不再互相吞掉：只有当本段确实没有推理文本可发时才把该事件置空，带 details 的 provider（如 OpenRouter）因此不会丢掉 reasoning 增量（`utils/middleware.py:5264-5272`）。

Responses 事件在流式期间已累积 output item 时，即使最终 completed 事件给出空 output 也保留累积结果；独立的 output-item 完成事件同样会合并进当前输出。这避免把已显示的 Responses 文本在收尾阶段覆盖为空（`utils/middleware.py:805-913`）。

### 5.3 前端消费（Chat.svelte）

订阅 `$socket?.on('events', chatEventHandler)`（1278 行）；`chatEventHandler`（949-1141 行）按 `event.data.type` 分发约 25 种类型（仅处理 `event.chat_id === $chatId` 的当前会话，952 行）：

| 事件 type | 前端动作 |
|---|---|
| `chat:completion` | `chatCompletionEventHandler`（2377-2487 行）：output 存在时直接覆盖（OR 对齐）、delta content 追加、done 时标记完成并 fire-and-forget `chatCompletedHandler` + `processNextInQueue` |
| `chat:message:delta` / `message` | content 追加 |
| `chat:message` / `replace` | content 覆盖 |
| `chat:message:files` / `files`、`chat:message:embeds` / `embeds` | 附件与嵌入内容 |
| `chat:message:error` | 错误展示 |
| `chat:message:tasks` / `chat:message:follow_ups` | 任务进度与追问 |
| `chat:tasks:cancel` | 取消任务状态（当前消息则置所有 response done 并走队列） |
| `chat:active` | 有/无活动任务（false 时清 taskIds、按需重载并更新已读） |
| `chat:title` / `chat:tags` | 标题与标签刷新 |
| `chat:outlet` | outlet 过滤器输出同步 |
| `source` / `citation` | 引用来源（code_execution 单独处理） |
| `notification` / `confirmation` / `execute` / `input` | 工具交互（toast、确认弹窗、代码执行、输入） |
| `terminal:*` | 终端 |

## 6. 完成、异常、最终化与回写

- 非流式请求由 `non_streaming_chat_response_handler` 收尾：先构造 Responses 风格输出项，再发一条 `chat:completion` 完成终包，把 done 标记与用量落库，随后发布生成完成事件并依次运行 outlet 过滤器与后台任务；出现异常时发出会话失败事件（`middleware.py:145、3566-3747`）；
- 流式请求在结束时做同样的收尾：发布完成事件、发完成终包、跑 outlet 过滤与后台任务；收到 `CancelledError` 时关闭上游流并保存半截状态（`middleware.py:5538-5574`）；
- 前端收到完成事件后直接以 output 覆盖消息内容，done 后只刷新侧栏列表，outlet 过滤与持久化已由后端内联完成（`Chat.svelte:2179-2487`）。

## 7. 停止、重试、续写与重新生成

- **停止**：前端 `stopResponse`（`Chat.svelte:3303-3345`）按会话或按任务发起取消，随即将该会话全部回复消息标记为已完成；只有 MoA 合并的 fetch 流会再调用 abort，最后推进队列；
- **任务调度**（`tasks.py`）：
  - 记账：进程内的 tasks 字典按 task_id 保存 asyncio.Task，item_tasks 按对象 ID 归组同一批任务 ID；模型请求以 chat_id 作为归组 ID。Redis 侧用哈希记录任务与对象的关联、用集合保存每个对象的任务 ID，并通过 pubsub 传递停止命令（`tasks.py:90-95,160-181`；`main.py:1832-1836`）；
  - 监听：`redis_task_command_listener`（23-39 行）**只处理 `stop` 命令**，按 task_id 取消本地任务，这是多实例协作的唯一通道；
  - 创建与停止：创建任务返回 task_id 与任务对象并写入 Redis；停止任务在 Redis 模式下广播 stop 并清理记账，本地模式直接取消并等待结束；会话级停止按 chat_id 列出归组任务，再逐个调用停止入口（`tasks.py:348-359`）；
- **重新生成** `regenerateResponse`（3380-3411 行）：多模型会话按模型与列序号只重生成一列，可附带再生提示词，后端把该提示词追加为最后一条用户消息（`middleware.py:2344-2345`）；
- **继续生成** `continueResponse`（3413-3437 行）：把已完成的消息重置为进行中并带上 assistant 消息 id，后端加载原回复内容接着续写（1.2/2 节）；
- **MoA 合并** `mergeResponses`（3439-3489 行）：调用 MoA 合并接口（`generateMoACompletion`）并复用 OpenAI 文本流（`createOpenAITextStream`），走独立的 HTTP fetch 流（非 Socket.IO），结果写入 `message.merged`；
- 重试与失败恢复区分：provider 错误（≥400）转异常发 `chat:message:error`；同 provider 重试与故障转移属于 LLM 渠道管理类目，本笔记未调查。

## 8. 队列、多会话并发与后台任务

- 提交排队：前端为每个会话维护请求队列（`src/lib/stores/index.ts:107`），同一会话生成期间的新提交先进队，当前回合结束后由队列处理函数把多次提交的 prompt 与文件合并成一次发送；不同会话之间并行，前端状态由会话活跃事件驱动（`Chat.svelte:2157-2177`）；
- 多模型并行（MoA 与 side-by-side）是内建概念，不依赖插件：一个请求 fan-out 多个任务（1.2 第 10 步），消息树用列序号保持各列顺序，界面支持逐列重新生成与合并（7）；
- 生成结束后，`background_tasks_handler` 按固定顺序执行四类后台任务：
  1. `FOLLOW_UP_GENERATION`（3251 行）：生成追问并落库、发事件；
  2. `TITLE_GENERATION`（3302 行）：生成标题并发 `chat:title`；
  3. `TAGS_GENERATION`（3364 行）：生成标签并发 `chat:tags`；
  4. `review_memory_after_turn`（3401 行）：记忆抽取。
  前端通过 `background_tasks` 字段按需开关，标题与标签只在新会话首条消息携带，追问每次携带（1.1 第 3 步）；会话在生成期间被删除则跳过这些任务（`middleware.py:3207-3543`）；
- outlet 过滤在生成收尾时内联执行，输出经 `chat:outlet` 事件回写前端（`middleware.py:1030-1040、3412`）；
- 服务端没有任务队列：任务对象只存在于发起请求的实例进程内，Redis 承担跨实例取消广播与状态查询。

## 9. Agent、工具、知识库与附件注入点

- 工具、技能与终端由请求体带入，工具服务器还要经过服务端权限过滤。native 模式先构建候选工具目录，再套用延迟工具机制：工具 schema 可以从 provider tools 中移除，检索返回定义后经分派器调用，目录细节见[Agent 工具笔记](../Agent工具/Open-WebUI-Agent工具调查笔记.md#延迟目录与两阶段调用)。
- 多轮工具调用由流式响应处理器内的 `execute_tool_call` 执行，迭代上限与循环条件在同一文件判断；工具交互事件（通知、确认、执行、输入）经 Socket.IO 送达前端（5.3）；工具结果以 Responses 输出项回写（数据侧见会话与消息管理笔记第 8 节）；审批恢复只对带 `assistant_message_id` 的续写或恢复请求生效，其他路径新建消息 id 时不回收待执行的工具调用（`middleware.py:3238-3245、5552-5577、5671`）；
- 子代理结果在 finally 阶段回填（1.2 第 9 步）；
- 记忆抽取在每轮结束后运行（8）；
- 知识库与联网搜索在拼装管线内完成，检索入口见 `middleware.py:388` 起；
- 工具执行循环的内部语义（过滤算法、参数校验、执行、审批、循环上限）属于 Agent 工具类目，本笔记只记录注入点与交接。

## 10. 退出恢复、日志与已确认边界

- 无活动任务时服务端发出 `chat:active=false`（1.2 第 9 步），前端据此清空任务 id、按需重新加载消息并更新已读状态（5.3）；
- 临时聊天使用非落库 id，但任务恢复另有服务端登记与流快照：Socket 重连后前端调用 resume 端点重新绑定会话并补齐内存消息输出；持久会话则查询任务后按需重载数据库消息。该路径支持断线重连，浏览器完整刷新与服务器重启后的恢复保证未确认（[`main.py:2164-2179`](../../open-webui/backend/open_webui/main.py#L2164-L2179)、[`Chat.svelte:1895-1933`](../../open-webui/src/lib/components/chat/Chat.svelte#L1895-L1933)）。
- 已确认边界：`POST /api/chat/completed` 的 docstring 标注为 Deprecated，outlet 过滤已内联，该端点只用于兼容外部集成（`main.py:1976-1979`）；
- 日志与可观测性：任务以 task_id 关联，Redis 中的哈希与集合可直接查询；`GET /api/tasks` 与按会话查询的 `GET /api/tasks/chat/{chat_id}` 提供查询入口，错误信息写入消息的 error 字段（`tasks.py:68-73`、`main.py:2023-2029`，对应 1.2 第 8 步）。

## 11. 未验证事项

- 多实例并发取消与 Redis 记账的最终一致性未运行验证（静态代码确认了 pubsub 广播与幂等清理路径）。
- Direct Connection 客户端内部实现未逐行核对（服务端交接点已核实）。
- 长上下文、压缩触发阈值下的实际行为需要运行验证。
- 队列的跨窗口行为：同一会话在多个标签页并发提交时 `chatRequestQueues` 的前端去重与合并未验证。

## 12. 关键源码索引

- 生成端点与 fan-out：[`main.py`](../../open-webui/backend/open_webui/main.py)（1052-1794 行）
- 生成管线与后台任务：[`utils/middleware.py`](../../open-webui/backend/open_webui/utils/middleware.py)（`process_chat_payload` 2365、`background_tasks_handler` 3654、`outlet_filter_handler` 3872、`non_streaming_chat_response_handler` 4033、`streaming_chat_response_handler` 4217、`execute_tool_call` 5671）
- 压缩：[`utils/context_compaction.py`](../../open-webui/backend/open_webui/utils/context_compaction.py)（`compact_messages_for_request` 42、`compact_chat_branch` 150）
- 任务调度：[`tasks.py`](../../open-webui/backend/open_webui/tasks.py)
- Socket.IO 事件：[`socket/main.py`](../../open-webui/backend/open_webui/socket/main.py)（`get_event_emitter` 1057、`get_event_call` 1181、`events:chat` 587、`_make_channel_emitter` 946）
- 直连模式：[`utils/chat.py`](../../open-webui/backend/open_webui/utils/chat.py)（49-148 行）
- 前端会话状态机与发送链：[`src/lib/components/chat/Chat.svelte`](../../open-webui/src/lib/components/chat/Chat.svelte)（949-1141、2157-2177、2377-3489 行）
- 前端 store：[`src/lib/stores/index.ts`](../../open-webui/src/lib/stores/index.ts)（`chatRequestQueues` 107）
