# Open WebUI 会话与消息管理调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：从 [`../Chat/Open-WebUI-Chat调查笔记.md`](../Chat/Open-WebUI-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：会话与消息的数据模型、CRUD、索引检索、生命周期事件与一致性；生成任务执行与流式通道进入对话请求与上下文，前端工作台进入 Chat UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.0 的 Chat 体系以**「会话 JSON + 消息表」双写**为特征：每条消息同时存在于 `chat.chat.history` 快照与 `chat_message` 行中，前端展示以历史快照为主，数据库行用于增量同步、统计和恢复。

- 聊天消息的增删改查全部集中在 `routers/chats.py`（约 2236 行），不存在独立的 `routers/messages.py`；`models/messages.py` 是频道（channel）消息模型，与聊天消息 `models/chat_messages.py` 是两套物理隔离的体系；
- 消息以 `{chat_id}-{message_id}` 复合键存储于 `chat_message` 表，`parentId`/`childrenIds` 构成消息树，`modelIdx` 保留多模型并行（side-by-side）的列序；
- 编辑/删除消息粒度到单条消息；会话更新合并 history（`Chats.merge_history`），缺失 ID 不推断删除，删除走独立端点；
- `meta.internal=True` 的会话视为内部会话（如子代理），不在普通列表展示；
- 「history JSON 快照 + 消息表双写」与 Cherry Studio / Chatbox 的纯表存储不同：前端读取快照 O(1)，写操作需要显式同步两处，`reconcile_messages_by_chat_id` 负责对齐；这是历史兼容与可扩展性之间的折中。

## 系统边界与数据主链

```text
POST /api/chats/new 或 POST /api/chat/completions（is_new_chat）
  -> Chat 表插入（chat JSON 含完整 history 快照）
  -> 用户消息与 assistant 占位写入 chat_message 表（复合键）
  -> 流式期间：history 快照由前端维护，数据库行经 Socket.IO 事件增量更新
  -> 完成：usage 落库、chat:list 刷新
  -> 会话列表 / 搜索 / 未读：按 chat_list_order 与索引查询
  -> 归档 / 分享 / 分叉 / 克隆 / 删除
```

边界：一次生成任务如何执行（`chat_completion` → `process_chat_payload` → fan-out → Socket.IO 流）在对话请求与上下文；前端发送链与 Overview 消息树图导航在 Chat UI；消息内容渲染在消息渲染器（`../消息渲染器/Open-WebUI-消息渲染器调查笔记.md`）。排除频道（channel）消息、Ydoc 协作、Direct Connection 客户端内部实现。

## 1. 会话、消息与分支数据模型

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

## 2. 创建、更新、归档、分享、删除与分支

`routers/chats.py` 的端点清单（节选）：

| 行号 | 端点 | 说明 |
|---|---|---|
| 746 | POST `/new` | 建会话（校验 folder 归属与共享写权限，发 `EVENTS.CHAT_CREATED`） |
| 788 | POST `/import` | 批量导入（`require_chat_import_permission`） |
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

## 3. 列表、分页、搜索与定位

- GET `/list`（220 行）：当前用户会话列表，默认 60 条/页，支持 pinned/folders/sort。
- GET `/search`（846 行）：文本/tag 搜索；`tag:` 前缀无结果时自动删标签。
- `POST /read`（262 行）：全部标记已读，返回 `folder_unread_counts`。
- 未读排序以 `ChatMessage.done=False` 的 assistant 子查询加 `last_read_at` 差值计算（1.1）。

## 4. 一致性与同步

- **双写对齐**：history JSON 快照是前端主展示源，`chat_message` 行用于增量同步、统计和恢复；`reconcile_messages_by_chat_id` 负责对齐两处。生成中的数据库行更新经 Socket.IO 事件（`update_db=True` 时按类型落库：`status`→status_history 追加、`message`→content 追加、`replace`→content 覆盖、`embeds`→追加），执行侧细节见对话请求与上下文笔记。
- **合并不推断删除**：`POST /{id}` 的 `Chats.merge_history` 对缺失 ID 不推断删除，保证前端并发快照与后端一致性的边界被明确划定。
- **恢复**：`get_messages_map_by_chat_id` 无行时返回 None，调用方回退旧版 JSON blob（1.2），即消息表缺失不破坏历史快照读取。

## 5. 生命周期事件流（数据语义）

| 阶段 | 触发点 | 事件/动作 |
|---|---|---|
| 创建 | `POST /api/chat/completions`（is_new_chat）/ `POST /api/chats/new` | `EVENTS.CHAT_CREATED`、`chat:list`、`chat:active=true` |
| 消息写入 | 用户消息/assistant 占位落库 | `EVENTS.MESSAGE_CREATED` |
| 完成 | `publish_chat_finished_event` | `EVENTS.CHAT_FINISHED` + `chat:list`；`POST /api/chat/completed` 已标 Deprecated，仅兼容外部集成 |
| 归档/固定/删除 | 对应路由 | `EVENTS.CHAT_ARCHIVED/UNARCHIVED/PINNED/UNPINNED/DELETED/...` |
| 分享 | `POST /{id}/share` | `EVENTS.CHAT_SHARED`，SharedChat 快照 |
| 分叉/克隆 | `POST /{id}/fork` / `clone` | `build_fork_history` 沿 parentId 回溯重建 |
| 已读/未读 | `POST /read`、socket `events:chat` | `chat:list` + folder_unread_counts，`unread_updated_at` 排序 |
| 压缩 | `POST /{id}/compact` | `context_summary` 检查点 + `context_compaction` 状态事件 |

生成中（流式 delta 事件）、失败（`chat:message:error` + `chat:tasks:cancel`）与标题/标签/追问（后台任务）的事件属于执行侧，记录在对话请求与上下文笔记。

## 6. 设计取舍与已确认边界

- **双写是历史兼容与可扩展性之间的折中**：前端读取快照 O(1)，写操作需要显式同步两处。
- **消息树用 `modelIdx` 保留多模型并行的列序**：side-by-side 是内建数据语义而非插件。
- **内部会话**（`meta.internal=True`，如子代理）不出现在普通列表。
- **类目边界**：任务系统（asyncio + Redis 记账）、流式通道（Socket.IO）与上下文管线属于对话请求与上下文；Overview 消息树图的导航交互属于 Chat UI。

## 7. 未验证事项

- 多实例并发写入时 history 快照与消息表的最终一致性未做运行验证。
- 频道消息、Ydoc 协作、Direct Connection 客户端内部实现不在本类目调查范围（原调查已排除）。

## 8. 关键源码索引

- Chat 表：[`models/chats.py`](../../open-webui/backend/open_webui/models/chats.py)
- ChatMessage 表与消息树重建：[`models/chat_messages.py`](../../open-webui/backend/open_webui/models/chat_messages.py)
- Chat/消息 CRUD 路由：[`routers/chats.py`](../../open-webui/backend/open_webui/routers/chats.py)
- 分叉构建：[`utils/chat_fork.py`](../../open-webui/backend/open_webui/utils/chat_fork.py)
- 事件定义：[`events.py`](../../open-webui/backend/open_webui/events.py)
- 前端会话状态机：[`src/lib/components/chat/Chat.svelte`](../../open-webui/src/lib/components/chat/Chat.svelte)（数据侧引用）
