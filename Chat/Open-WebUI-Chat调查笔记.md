# Open WebUI Chat 调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读源码核对（FastAPI 后端 main.py / utils/middleware.py / models 层、Socket.IO 通道、SvelteKit 前端 Chat.svelte）；未修改目标仓库
>
> 调查范围：聊天数据模型、CRUD 路由、消息生成与任务调度、流式通道、前端发送与渲染、会话生命周期；排除频道（channel）消息、Ydoc 协作、Direct Connection 客户端内部实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md`](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md)（数据模型、CRUD、索引检索、双写一致性）
> - 对话请求与上下文：[`../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md`](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md)（生成主链、fan-out、Socket.IO 流、任务调度）
> - Chat UI：[`../Chat UI/Open-WebUI-ChatUI调查笔记.md`](<../Chat UI/Open-WebUI-ChatUI调查笔记.md>)（发送链界面、Overview 消息树图）
> - 消息渲染：[`../消息渲染器/Open-WebUI-消息渲染器调查笔记.md`](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md)（已有独立笔记）

## 结论摘要

Open WebUI v0.11.0 的 Chat 体系以「会话 JSON + 消息表」双写为特征：每条消息同时存在于 `chat.chat.history` 快照与 `chat_message` 行中，前端展示以历史快照为主，数据库行用于增量同步、统计和恢复。

- 聊天消息的增删改查全部集中在 `routers/chats.py`（约 2236 行），不存在独立的 `routers/messages.py`；`models/messages.py` 是频道（channel）消息模型，与聊天消息 `models/chat_messages.py` 是两套物理隔离的体系；
- 消息以 `{chat_id}-{message_id}` 复合键存储于 `chat_message` 表，`parentId`/`childrenIds` 构成消息树，`modelIdx` 保留多模型并行（side-by-side）的列序；
- 生成主链路：`POST /api/chat/completions` → `main.py: chat_completion`（1054 行）→ `utils/middleware.py: process_chat_payload`（2248 行）→ 上游（openai/ollama/pipe）→ `build_chat_response_context`（3008 行）→ 流式或非流式响应处理器；
- 多模型并行以 `asyncio.Task` 逐个 fan-out，仅第一个模型携带标题/标签生成任务；任务注册进 Redis（哈希 + pubsub stop 命令），实现多实例协调；
- 流式推送统一走 Socket.IO `events` 事件（发射到 `user:{user_id}` 房间），前端按 `data.type` 分发约 25 种消息类型；REST 只负责发起与终止任务；
- 标题、标签、追问、记忆抽取由 `background_tasks_handler` 在后端生成结束后串行执行；
- 系统事件通过 `events.py` 的 `EventDefinitions` 定义并触发 Webhook/通知；本版本没有 "SystemLog" 概念；
- 前端状态机整体内聚在 `src/lib/components/chat/Chat.svelte`（约 4205 行），包含发送、停止、重新生成、继续生成、MoA 合并与队列排队；
- 右侧面板另有 Overview 消息树图：把 `history.messages` 的 parentId 树渲染成只读 SvelteFlow 节点图（`@xyflow/svelte`），点击节点经 `showMessage` 切换到该消息所在分支（沿 childrenIds 走到叶子并更新 `history.currentId`），与主消息区共用同一棵 history 树（详见 5.3 节）。

## 1. 聊天数据模型

### 1.1 Chat 会话表

[`models/chats.py`](../../open-webui/backend/open_webui/models/chats.py)（70-102 行）的 `Chat` 表字段：

| 字段 | 作用 |
|---|---|
| `id` / `user_id` | 会话 ID 与归属 |
| `title` | 标题（后台任务生成） |
| `chat` | JSON，内含完整 history 消息快照 |
| `share_id` | 分享 token（unique） |
| `archived` / `pinned` | 归档与固定 |
| `meta` / `variables` / `tasks` | 元数据、会话变量、任务记录 |
| `folder_id` | 文件夹归属 |
| `summary` | 摘要 |
| `current_message_id` / `last_read_at` | 当前消息指针与已读时间 |

- 活跃会话判定窗口 `ACTIVE_CHAT_GAP_SECONDS = 30 * 60`（43 行）；
- `chat_list_order`（46-67 行）支持 `updated_at` / `title` / `unread_updated_at` 排序；未读排序以 `ChatMessage.done=False` 的 assistant 子查询加 `last_read_at` 差值计算；
- `meta.internal=True` 的会话视为内部会话（如子代理），不在普通列表展示；
- `ChatFile` 表（139-152 行）记录 `chat_id + message_id + file_id`，`(chat_id, file_id)` 唯一，级联删除。

### 1.2 ChatMessage 消息表

[`models/chat_messages.py`](../../open-webui/backend/open_webui/models/chat_messages.py)（128-172 行）的 `ChatMessage` 表：

| 字段 | 作用 |
|---|---|
| `id` | 文本主键，实际存储 `{chat_id}-{message_id}` 复合键（224 行） |
| `role` / `parent_id` | 角色与父消息 |
| `content` | JSON，str 或 blocks 列表 |
| `output` | JSON，OR 对齐输出项（reasoning/solution/code_interpreter 等） |
| `model_id` | 生成模型 |
| `files` / `sources` / `embeds` | 附件、引用来源、嵌入内容 |
| `meta` / `done` / `status_history` / `error` / `usage` | 状态机与用量 |
| `context_summary` | 上下文压缩检查点 |

- `upsert_message`（210-290 行）按复合键存在则逐字段覆盖，usage 用 `merge_usage` 合并；
- `get_messages_map_by_chat_id`（331-392 行）把行还原为与 `chat.history.messages` 同构的字典（`parent_id→parentId`、`model_id→model`、`created_at→timestamp` 等映射），并重建 `childrenIds`、回填 `info.usage`；无行时返回 None，调用方回退旧版 JSON blob；
- 统计类 API 丰富：按模型消息数、token 用量、每日活跃、Top 模型/工具（`_extract_tool_names` 递归扫描 `tool_calls`/`tools`/`output`/`meta`，89-120 行）等。

### 1.3 附属模型

- **Folder**：`models/folders.py`（22-33 行），支持树形父子、共享文件夹经 `AccessGrant` 查 user/group/public 授权并取最高权限（160 行）；
- **SharedChat**：`models/shared_chats.py`，`id` 即分享 token，`chat` 字段是**分享时刻的 JSON 快照**（非实时引用）；
- **Tag**：`models/tags.py`，复合主键 `(id, user_id)`，`id` 由 name 小写下划线生成；
- **频道消息**：`models/messages.py`，`channel_id`/`reply_to_id`/`parent_id`/`is_pinned`/`content`/`data`/`meta`，仅服务 `channel:` 会话。

## 2. Chat 与消息 CRUD 路由

`routers/chats.py` 的端点清单（节选）：

| 行号 | 端点 | 说明 |
|---|---|---|
| 220 | GET `/list` | 当前用户会话列表，默认 60 条/页，支持 pinned/folders/sort |
| 262 | POST `/read` | 全部标记已读，返回 `folder_unread_counts` |
| 746 | POST `/new` | 建会话（校验 folder 归属与共享写权限，发 `EVENTS.CHAT_CREATED`） |
| 788 | POST `/import` | 批量导入（`require_chat_import_permission`） |
| 846 | GET `/search` | 文本/tag 搜索；`tag:` 前缀无结果时自动删标签 |
| 1251 | POST `/{id}/compact` | 上下文压缩，写 `context_summary` 检查点 |
| 1305 | GET `/{id}` | 取会话（含 chat JSON） |
| 1348 | POST `/{id}` | 更新会话：**合并 history**（`Chats.merge_history`），缺失 ID 不推断删除，删除走独立端点 |
| 1406 | POST `/{id}/messages/{message_id}` | 编辑消息（写库后经 event emitter 发 `chat:message`） |
| 1468 | DELETE `/{id}/messages/{message_id}` | 删除消息 |
| 1568 | DELETE `/{id}` | 删除会话（级联消息与文件） |
| 1672 | POST `/{id}/fork` | 分叉：`build_fork_history` 沿 `parentId` 回溯重建消息子树 |
| 1763 | POST `/{id}/clone` | 克隆会话（含共享克隆） |
| 1897 / 1933 | POST `/{id}/archive` / `/{id}/share` | 归档与生成分享 token |
| 2092 | POST `/{id}/unread` | 标为未读 |
| 2154 | POST `/{id}/tags` | 会话标签 |

编辑/删除消息均有 `chat.user_id != user.id and user.role != 'admin'` 校验（1423-1427、1484-1488 行）。

## 3. 消息生成流程与任务调度

### 3.1 `chat_completion` 端点（main.py 1054-1794 行）

1. 请求解析（1149-1178 行）：`message_ids` 支持 list `[{model_id, message_id, modelIdx}]` 或 legacy dict；`user_message`/`chat_variables`/`tool_servers`（无 `features.direct_tool_servers` 权限时丢弃）从请求体中取出；
2. metadata 构造（1180-1209 行）：user_id/chat_id/session_id/folder_id/filter_ids/tool_ids/files/features/variables/model/direct/params（含 stream_delta_chunk_size、reasoning_tags、compact_token_threshold、function_calling）；
3. 新会话判定（1211-1212 行）：`is_new_chat` 时生成 uuid4 作为 chat_id；
4. `channel:` 分支权限门（1223-1258 行）：群聊/DM 需频道成员，其余需 `AccessGrants` 写权限；
5. 新会话持久化（1260-1392 行）：构造含全部 assistant 占位符的 history（保留 modelIdx）→ `insert_new_chat` → `EVENTS.CHAT_CREATED` → `emit_chat_list_event` → 用户消息与各 assistant 占位的 `EVENTS.MESSAGE_CREATED` → 插入 chat 文件 → 初始标题后台任务（`run_initial_title_generation`，1386-1392 行）；
6. 已有会话（1393-1533 行）：所有权校验 → 持久化 chat 级 fields → 保存用户消息（含取消 `chat.user_message` 定时器）→ grandparent 链接 childrenIds → 保存全部 assistant 占位符；
7. `process_chat`（1547-1570 行）：`process_chat_payload` → `chat_completion_handler`（真实模型调用）→ provider 返回 ≥400 转异常 → `build_chat_response_context` → `process_chat_response`；
8. 取消/异常（1571-1613 行）：`CancelledError` 发 `chat:tasks:cancel`；普通异常把 `error` 写入消息并发 `chat:message:error`；
9. finally 清理（1623-1700 行）：MCP 客户端断开、任务注销、无活动任务时发 `chat:active=false`、`process_pending_internal_messages`（子代理结果回填）；
10. **多模型 fan-out**（1702-1781 行）：每个模型一个 `asyncio.Task`，仅 `idx==0` 的模型携带 TITLE/TAGS 任务；任务注册 Redis，返回 `{status, task_ids, chat_id}`；
11. 别名：`generate_chat_completions = generate_chat_completion = chat_completion`（1789-1790 行），注册为 `app.state.CHAT_COMPLETION_HANDLER` 供子代理/定时器内部重入。

### 3.2 任务调度（tasks.py，199 行）

- 进程内 `tasks: dict[str, asyncio.Task]` + `item_tasks`；Redis 键 `{prefix}:tasks`（哈希）、`{prefix}:tasks:item`（集合）、`{prefix}:tasks:commands`（pubsub）；
- `redis_task_command_listener`（23-39 行）只处理 `stop` 命令，按 task_id 取消本地任务——这是多实例协作的唯一通道；
- `create_task`（102-122 行）返回 `(task_id, task)` 并写入 Redis；
- `stop_task`（143-177 行）：Redis 模式广播 stop 命令，本地模式 `task.cancel()`；
- 停止链路：前端 `stopResponse`（Chat.svelte 3303-3345 行）→ `stopTasksByChatId`（会话级）或逐个 `stopTask` → 所有 response 消息标记 `done`。

### 3.3 中间件核心函数（utils/middleware.py，5669 行）

- `process_chat_payload`（2248 行）：arena 模型解析、skill 注入、payload 预处理；管线顺序见文件内注释（Pipeline Inlet → Filter Inlet → Chat Memory → Web Search → Image Gen → Code Interpreter → Tools Function Calling → Files）；
- `streaming_chat_response_handler`（3750 行）：`extra_params` 注入 `__event_emitter__`/`__event_call__`/`__user__`/`__metadata__`/`__oauth_token__`/`__request__`/`__model__`（3766-3774 行）→ 过滤器 → task_id 生成 → 内嵌 `response_handler`：`tag_output_handler`（reasoning/solution/code_interpreter 标签切分）、delta 缓冲（`queue_pending_delta_data` 4203 行，按 delta_count/delta_chunk_size 聚合）、SSE `data:` 前缀解析、多轮工具调用（`execute_tool_call` 4969 行）、结束处 `background_tasks_handler`（5553 行）、`stream_wrapper` 重试/取消包装；
- `non_streaming_chat_response_handler`（3566-3747 行）：错误写库 → `chat:completion` 事件 → 无 output 时由 reasoning/content 构造 OR 输出项 → `done: True` 终包 → usage 落库 → `publish_chat_finished_event` → outlet 过滤 + 后台任务；异常发 `EVENTS.CHAT_FAILED`；
- `background_tasks_handler`（3194-3410 行）：**FOLLOW_UP_GENERATION**（3251 行，生成追问并落库）→ **TITLE_GENERATION**（3301 行）→ **TAGS_GENERATION**（3364 行）→ `review_memory_after_turn`（记忆）；前端通过 `background_tasks` 字段按需携带开关，标题/标签仅新会话首消息下发，追问恒发；
- `outlet_filter_handler`（3412 行）：outlet 过滤器内联执行，输出同步回写前端 `chat:outlet` 事件。

## 4. Socket.IO 流式通道

### 4.1 服务端（socket/main.py，1136 行）

- 事件注册：`usage`（339）、`heartbeat`（421）、`events:chat`（534，处理 last_read_at → 房间广播 `chat:list`）、`events:channel`、Ydoc 协作事件等；
- `get_event_emitter`（968 行）：向 `user:{user_id}` 房间发 `'events'`，payload 结构 `{chat_id, message_id, data: event_data}`；`update_db=True` 时按类型落库：`status`→status_history 追加、`message`→content 追加、`replace`→content 覆盖、`embeds`→追加；
- `_make_channel_emitter`（943-965 行）：`channel:` 会话专用，`chat:completion` 按 `THROTTLE_INTERVAL` 节流后更新频道消息并 emit `events:channel`；
- Direct Connection 模式（utils/chat.py `generate_direct_chat_completion` 49-148 行）：建 `{user_id}:{session_id}:{request_id}` 频道，`event_caller` 驱动客户端完成推理，通过 SSE 回传。

### 4.2 前端消费（Chat.svelte）

- 订阅 `$socket?.on('events', chatEventHandler)`（1278 行）；
- `chatEventHandler`（949-1141 行）按 `event.data.type` 分发约 25 种类型，见下表：

| 事件 type | 前端动作 |
|---|---|
| `chat:completion` | 含 output/done/usage 的完成包，直接覆盖内容 |
| `chat:message:delta` / `chat:message` | 追加 / 覆盖 content |
| `chat:message:files` / `chat:message:embeds` | 附件与嵌入内容 |
| `chat:message:error` | 错误展示 |
| `chat:message:tasks` / `chat:message:follow_ups` | 任务进度与追问 |
| `chat:tasks:cancel` | 取消任务状态 |
| `chat:active` | 有/无活动任务（false 时清 taskIds 并重载） |
| `chat:title` / `chat:tags` | 标题与标签刷新 |
| `chat:list` | 会话列表刷新 |
| `chat:outlet` | outlet 过滤器输出同步 |
| `source` / `citation` | 引用来源 |
| `notification` / `confirmation` / `execute` / `input` | 工具交互 |
| `terminal:*` | 终端 |

## 5. 前端发送与渲染

### 5.1 发送链路（Chat.svelte）

1. `submitPrompt`（2493-2540 行）：收集非图片文件 → 构造用户消息（uuid、parentId=currentId、childrenIds、timestamp=Unix 秒、models）→ 挂到 history 树 → `sendMessage`；
2. `sendMessage`（2773-2935 行）：为每个选中模型创建 assistant 占位消息（modelIdx 保留列序），构建 `messageIdsList`；无 chat_id 时（临时会话）创建 `temporary` 会话 ID；视觉能力检查；以单请求多模型方式只发主模型；
3. `sendMessageSocket`（2974-3259 行）：请求体含 `stream`（默认 true）、`messages`（**仅临时会话携带对话历史**，持久会话由后端从 DB 加载）、`params`（设置+会话参数+stop tokens）、`files`、`filter_ids`、`tool_ids`/`skill_ids`/`terminal_id`/`tool_servers`、`features`、`variables`、`session_id`/`chat_id`/`folder_id`、`id`、`message_ids`、`parent_id`/`user_message`、`regeneration_prompt`、`assistant_message_id`、`background_tasks`、`stream_options.include_usage`；
4. 响应处理（3221-3253 行）：收集 task_ids；新会话返回的 chat_id 更新 store + URL `/c/{id}` + 刷新列表 + 持久化会话 params；
5. 流式渲染 `chatCompletionEventHandler`（2377-2487 行）：output 存在时直接覆盖（OR 对齐）、delta content 追加、done 时标记完成并 fire-and-forget `chatCompletedHandler`；
6. 重新生成 `regenerateResponse`（3380-3411 行）：多模型会话按 `modelId + modelIdx` 单列重生成；
7. 继续生成 `continueResponse`（3413-3437 行）：done 消息重置为未完成，传 `assistant_message_id`；
8. MoA 合并 `mergeResponses`（3439-3489 行）：调 `generateMoACompletion` + `createOpenAITextStream`；
9. 提交排队：`chatRequestQueues` store + `processNextInQueue`（2157-2177 行）。

### 5.2 渲染组件

- `Chat.svelte`（会话控制器）、`Messages.svelte`、`MessageInput.svelte`；
- `Messages/Message.svelte`（入口分发）、`ResponseMessage.svelte`（主渲染：流式内容/Markdown/引用/代码执行/评分）、`UserMessage.svelte`、`MultiResponseMessages.svelte`（并排多列）、`StructuredOutputRenderer.svelte`（OR 输出）；
- `ShareChatModal.svelte` / `TagChatModal.svelte`：分享与标签。

### 5.3 会话消息树图（Overview）

聊天右侧面板 `ChatControls.svelte` 有 `controls / files / overview` 三个 tab，`showOverviewTab = hasMessages`（81 行）——只要会话有消息就提供 overview 入口（370 行挂载）。该视图把整个消息树渲染成一张**只读节点图**，实现分三层：

- **图数据构建**（`Overview/View.svelte`，190 行）：直接从 `history.messages` 遍历（76-119 行），每条消息一个节点，按 `parentId` 生成 `smoothstep` 边，`level = parent.level + 1` 分层，同层节点用 `layerWidths` 计数均匀排布；垂直/水平两种布局方向可切换（`Flow.svelte:59-63` 的 ControlButton）。
- **画布**（`Overview/Flow.svelte`）：`@xyflow/svelte`（SvelteFlow），`minZoom: 0.001`、`fitView`、`nodesConnectable/nodesDraggable: false`（28-46 行）——不允许拖拽节点或连线；`Background` + `Controls` 提供缩放平移，另有 pin（固定视口）按钮。节点卡（`Node.svelte`，94 行）显示用户/模型头像、名称、两行内容摘要（全文放 Tooltip），assistant 卡上还能直接收藏消息。
- **交互**：`history.currentId` 变化时 `fitView` 自动定位当前消息（`View.svelte:50-62`）；点击节点经 `nodeclick` dispatch 到 `ChatControls.svelte:372-375`，调用 `Chat.svelte` 的 `showMessage(message, true)`——它沿 `childrenIds` 一路走到叶子、更新 `history.currentId` 并把主消息区滚动到该消息，即**点击树图节点 = 切换到该消息所在分支**；活动路径上的边 `animated` 高亮（`View.svelte:119`）。

该视图是消息树的分支导航辅助，与发送链路（5.1 节）共享同一棵 `history` 树，不创建新消息或独立视图状态。

## 6. 会话生命周期事件流

| 阶段 | 触发点 | 事件/动作 |
|---|---|---|
| 创建 | `POST /api/chat/completions`（is_new_chat）/ `POST /api/chats/new` | `EVENTS.CHAT_CREATED`、`chat:list`、`chat:active=true` |
| 消息写入 | 用户消息/assistant 占位落库 | `EVENTS.MESSAGE_CREATED`（main.py 1326-1351 等） |
| 生成中 | 流式 delta | `chat:message:delta` / `chat:completion` / `chat:message:tasks` / `chat:message:files` / `chat:message:error` |
| 完成 | `publish_chat_finished_event`（middleware 145 行） | `EVENTS.CHAT_FINISHED` + `chat:list`；`POST /api/chat/completed` 已标 Deprecated（main.py 1976-1993 行），仅兼容外部集成 |
| 失败 | main.py 1584 / 非流式 3710 | `chat:message:error` + `chat:tasks:cancel` + `EVENTS.CHAT_FAILED` |
| 标题/标签/追问 | `background_tasks_handler` | `chat:title` / `chat:tags` / `chat:message:follow_ups` |
| 归档/固定/删除 | 对应路由 | `EVENTS.CHAT_ARCHIVED/UNARCHIVED/PINNED/UNPINNED/DELETED/...` |
| 分享 | `POST /{id}/share` | `EVENTS.CHAT_SHARED`，SharedChat 快照 |
| 分叉/克隆 | `POST /{id}/fork` / `clone` | `build_fork_history` 沿 parentId 回溯重建 |
| 已读/未读 | `POST /read`、socket `events:chat` | `chat:list` + folder_unread_counts，`unread_updated_at` 排序 |
| 压缩 | `POST /{id}/compact` | `context_summary` 检查点 + `context_compaction` 状态事件 |

## 7. 值得记录的架构事实

- 「history JSON 快照 + 消息表双写」与 Cherry Studio / Chatbox 的纯表存储不同：前端读取快照 O(1)，写操作需要显式同步两处，`reconcile_messages_by_chat_id` 负责对齐；这是历史兼容与可扩展性之间的折中；
- 多模型并行（MoA / side-by-side）是内建概念而非插件：一个请求 fan-out 多个任务，消息树用 `modelIdx` 保持列序，UI 支持逐列重新生成与合并；
- 流式通道完全走 Socket.IO，而其他同类项目（Chatbox、Cherry Studio）多为 HTTP SSE；Socket.IO 的事件命名空间在这里承载了「状态 + 内容 + 任务控制 + 工具交互」四种职责；
- 任务系统是「asyncio + Redis 记账」而非任务队列：任务不在 worker 间迁移，Redis 仅用于跨实例取消与状态查询；
- 消息编辑/删除粒度到单条消息，且 history 合并不推断删除，保证前端并发快照与后端一致性的边界被明确划定；
- `POST /api/chat/completed` 的 Deprecated 标记说明 outlet 过滤器已内联，第三方集成使用的旧协议正在收敛。

## 8. 关键文件索引

- Chat 表：[`models/chats.py`](../../open-webui/backend/open_webui/models/chats.py)
- ChatMessage 表与消息树重建：[`models/chat_messages.py`](../../open-webui/backend/open_webui/models/chat_messages.py)
- Chat/消息 CRUD 路由：[`routers/chats.py`](../../open-webui/backend/open_webui/routers/chats.py)
- 生成端点与 fan-out：[`main.py`](../../open-webui/backend/open_webui/main.py)（1054-1794 行）
- 生成管线与后台任务：[`utils/middleware.py`](../../open-webui/backend/open_webui/utils/middleware.py)（2248、3194、3566、3750 行）
- 任务调度：[`tasks.py`](../../open-webui/backend/open_webui/tasks.py)
- Socket.IO 事件：[`socket/main.py`](../../open-webui/backend/open_webui/socket/main.py)（968 行）
- 直连模式：[`utils/chat.py`](../../open-webui/backend/open_webui/utils/chat.py)（49-148 行）
- 事件定义：[`events.py`](../../open-webui/backend/open_webui/events.py)
- 分叉构建：[`utils/chat_fork.py`](../../open-webui/backend/open_webui/utils/chat_fork.py)
- 前端会话状态机：[`src/lib/components/chat/Chat.svelte`](../../open-webui/src/lib/components/chat/Chat.svelte)
- 前端 store：[`src/lib/stores/index.ts`](../../open-webui/src/lib/stores/index.ts)
- Overview 消息树图：[`src/lib/components/chat/Overview/`](../../open-webui/src/lib/components/chat/Overview/)、入口 `ChatControls.svelte`
