# Open WebUI 会话与消息管理调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：直接阅读源码（FastAPI 路由与模型层、Socket.IO 事件处理、Alembic schema 版本、前端 store）
>
> 调查范围：会话与消息的数据模型、事实源与双写、CRUD 与生命周期事件、分叉/克隆/压缩、列表分页与搜索、一致性与恢复；生成任务执行与流式通道进入对话请求与上下文，前端工作台进入 Chat UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI v0.11.0 的 Chat 体系以**「会话 chat JSON 快照 + chat_message 消息表」双写**为特征：每条消息同时存在于 `chat.chat.history` 快照与 `chat_message` 行中，前端展示以历史快照为主，数据库行用于增量同步、统计和恢复。

- 聊天消息的增删改查全部集中在 [`routers/chats.py`](../../open-webui/backend/open_webui/routers/chats.py)（2236 行），`routers/` 目录下不存在独立的 `messages.py`；`models/messages.py` 是频道（channel）消息模型，与聊天消息 `models/chat_messages.py` 是两套物理隔离的体系；
- 消息以 `{chat_id}-{message_id}` 复合键存储于 `chat_message` 表（`chat_messages.py:224`），`parentId`/`childrenIds` 构成消息树，`modelIdx` 保留多模型并行（side-by-side）的列序；
- 编辑/删除消息粒度到单条消息；会话更新合并 history（`Chats.merge_history`，`chats.py:1360`），缺失 ID 不推断删除，删除走独立端点；
- `meta.internal=True` 的会话视为内部会话（如子代理），不在普通列表展示（`chats.py` 模型层 `is_internal_chat`）；
- 「history JSON 快照 + 消息表双写」与纯表存储的同类项目不同：前端读取快照 O(1)，写操作需要显式同步两处，`reconcile_messages_by_chat_id` 负责对齐；消息表缺失不破坏读取，可回退旧版 JSON blob 并自愈回填。

## 系统边界与数据主链

```text
POST /api/chats/new 或 POST /api/chat/completions（is_new_chat）
  -> Chat 表插入（chat JSON 含完整 history 快照，models/chats.py:416 insert_new_chat）
  -> 初始消息双写 chat_message 表（insert_new_chat 内 448-467 行）
  -> 流式期间：history 快照由前端维护，数据库行经 Socket.IO 事件增量更新
     （socket/main.py:997-1092 按类型落库）
  -> 完成：usage 落库、chat:list 刷新
  -> 会话列表 / 搜索 / 未读：按 chat_list_order 与标题+内容搜索查询
  -> 归档 / 分享 / 分叉 / 克隆 / 删除 / 压缩
```

边界：一次生成任务如何执行（`chat_completion` → `process_chat_payload` → fan-out → Socket.IO 流）在对话请求与上下文；前端发送链与 Overview 消息树图导航在 Chat UI；消息内容渲染在消息渲染器（`../消息渲染器/Open-WebUI-消息渲染器调查笔记.md`）。排除频道（channel）消息、Ydoc 协作、Direct Connection 客户端内部实现。

## 1. 会话、消息与分支数据模型

### 1.1 会话单位与 Chat 表

- **会话单位**：只有一种持久化对象 `Chat`（对应 `chat` 表）。
- 前缀语义：`temporary:`/`local:` 前缀的会话不落库，只是前端发送前的占位（见 `utils/chat_id.py:4-20`）；`channel:` 前缀的会话走另一套频道消息体系。
- ID 生成：会话 ID 由路由侧 `str(uuid4())` 生成（`chats.py:769`）；消息 ID 由前端 `uuidv4()` 生成（`Chat.svelte:2509`），服务端按 `{chat_id}-{message_id}` 拼复合主键。

[`models/chats.py`](../../open-webui/backend/open_webui/models/chats.py)（70-102 行）的 `Chat` 表字段：

| 字段 | 作用 |
|---|---|
| `id` / `user_id` | 会话 ID 与归属 |
| `title` | 标题（后台任务生成） |
| `chat` | JSON，内含完整 history 消息快照 |
| `share_id` | 分享 token（unique） |
| `archived` / `pinned` | 归档与固定 |
| `meta` / `variables` / `tasks` | 元数据（tags、internal 标记等）、会话变量、任务记录 |
| `folder_id` | 文件夹归属 |
| `summary` | 摘要 |
| `current_message_id` / `last_read_at` | 当前消息指针与已读时间 |

- 活跃会话判定窗口 `ACTIVE_CHAT_GAP_SECONDS = 30 * 60`（43 行）；
- `chat_list_order`（46-67 行）支持 `updated_at`、`title`、`unread_updated_at` 三种排序；
- 未读排序以 `ChatMessage.done=False` 的 assistant 子查询加 `updated_at > last_read_at` 差值计算（52-67 行）；
- `meta.internal=True` 的会话视为内部会话（`is_internal_chat`，105-106 行），所有列表查询用 `Chat.meta['internal'].as_boolean().is_not(True)` 排除（如 1310 行）；
- `ChatFile` 表（139-152 行）记录 `chat_id + message_id + file_id`，`(chat_id, file_id)` 唯一（152 行），级联删除。

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

- 消息树语义：history 快照里每条消息带 `parentId`/`childrenIds`，`currentId` 是活动路径指针；表行只存 `parent_id`，`childrenIds` 由 `get_messages_map_by_chat_id` 重建（375-390 行）；
- `upsert_message`（210-290 行）按复合键存在则逐字段覆盖，usage 用 `merge_usage` 合并（256-259 行）；
- `get_messages_map_by_chat_id`（331-392 行）把行还原为与 `chat.history.messages` 同构的字典，字段映射（321-327 行）：
  ```text
  parent_id→parentId / model_id→model / created_at→timestamp
  ```
- 还原后重建 `childrenIds`、回填 `info.usage`；无行时返回 None，调用方回退旧版 JSON blob；
- 统计类 API 丰富：按模型消息数、token 用量、每日活跃、Top 模型/工具（`_extract_tool_names` 递归扫描 `tool_calls`/`tools`/`output`/`meta`，89-120 行）等（490-1024 行）。

### 1.3 附属模型

- **Folder**：`models/folders.py`（22-33 行），支持树形父子；共享文件夹经 `AccessGrant` 查 user/group/public（`user:*`）授权并取最高权限（`get_shared_folder_ids_for_user`，160-192 行）；
- **SharedChat**：`models/shared_chats.py`（18-29 行），`id` 即分享 token，`chat` 字段是**分享时刻的 JSON 快照**（26 行），`create`/`update` 分别建快照与重新快照（61-112 行）；
- **Tag**：`models/tags.py`（18-31 行），复合主键 `(id, user_id)`（31 行），`id` 由 name 小写下划线生成（`replace(' ', '_').lower()`，61/75/98 行）；标签本体存 `Chat.meta.tags`；
- **频道消息**：`models/messages.py`（39-56 行），字段见下，仅服务 `channel:` 会话：
  ```text
  channel_id / reply_to_id / parent_id / is_pinned / content / data / meta
  ```

## 2. 事实源、索引与持久化

- **权威源划分**：前端渲染读 history 快照（O(1)）；增量同步、统计与恢复读消息表；两处由 `reconcile_messages_by_chat_id`（`models/chats.py:898`）单向对齐（快照 → 表，best-effort，错误只记日志不抛出）；
- **自愈恢复**：`Chats.get_messages_map_by_chat_id`（`models/chats.py:909-960`）三级策略——有行且父链完整 → 直接用表；父链有缺口 → 从旧版 JSON 补缺并回填（921-947 行）；完全无行 → 回退 JSON blob 并整批回填（949-960 行）；
- **索引**：两张表的复合索引如下（`chat` 表 95-101 行、`chat_message` 表 168-172 行）：
  ```text
  chat 表：folder_id / user_id+pinned / user_id+archived / updated_at+user_id
  chat_message 表：(chat_id, parent_id) / (model_id, created_at) / (user_id, created_at)
  ```
- **事件源**：所有变更经 `publish_event` 发审计/Webhook 事件（`events.py:161-221`），与 Socket.IO 前端事件是两套通道。事件名分会话与消息两组：
  ```text
  EVENTS.CHAT_CREATED / CHAT_FINISHED / CHAT_FAILED / CHAT_UPDATED / CHAT_DELETED / CHAT_ARCHIVED / CHAT_SHARED / ...
  EVENTS.MESSAGE_CREATED / MESSAGE_UPDATED / MESSAGE_DELETED
  ```

## 3. 创建、切换、归档、删除与恢复

`routers/chats.py` 的端点清单（节选，行号为 `@router` 装饰器行）：

| 行号 | 端点 | 说明 |
|---|---|---|
| 220 | GET `/list` | 当前用户会话列表（见第 5 节） |
| 262 | POST `/read` | 全部标记已读，返回 `folder_unread_counts` |
| 679 | DELETE `/` | 删除用户全部会话（`chat.delete` 权限） |
| 746 | POST `/new` | 建会话（校验 folder 归属与共享写权限 758-766 行，发 `EVENTS.CHAT_CREATED`） |
| 788 | POST `/import` | 批量导入（`require_chat_import_permission`，795 行） |
| 846 | GET `/search` | 搜索（见第 5 节） |
| 1251 | POST `/{id}/compact` | 上下文压缩（活动任务时 409 拒绝 1263-1267 行，成功后发 `EVENTS.CHAT_COMPACTED` 1290-1296 行） |
| 1305 | GET `/{id}` | 取会话（admin 直读、共享授权、文件夹授权三级 1309-1333 行） |
| 1348 | POST `/{id}` | 更新会话：**合并 history**（`Chats.merge_history`，1360 行），随后 `reconcile_messages_by_chat_id`（1382 行） |
| 1406 | POST `/{id}/messages/{message_id}` | 编辑消息（写库后经 event emitter 发 `chat:message`，1447-1456 行） |
| 1468 | DELETE `/{id}/messages/{message_id}` | 删除消息 |
| 1568 | DELETE `/{id}` | 删除会话（先停任务 1595 行、级联内部子会话 1599-1601 行、清理孤儿标签） |
| 1672 | POST `/{id}/fork` | 分叉（需 import 权限 1680 行；活动任务 409 拒绝 1686-1702 行） |
| 1763 | POST `/{id}/clone` | 克隆会话（走 `import_chats`，1782 行）；1822 行另有 `clone/shared` 分享克隆 |
| 1897 | POST `/{id}/archive` | 归档（归档时先停任务 1911 行并清理孤儿标签 1913 行） |
| 1933 | POST `/{id}/share` | 生成/刷新分享 token（已有 share_id 时重新快照 1948-1959 行） |
| 2092 | POST `/{id}/unread` | 标为未读（`last_read_at = 0`） |
| 2169 | POST `/{id}/tags` | 添加会话标签（GET 在 2154 行，DELETE 在 2210 行） |

- 惰性创建：空会话列表只是前端占位；真正的会话对象在 `POST /api/chat/completions` 判定 `is_new_chat` 时由后端创建（`main.py:1211-1392`），执行侧细节见对话请求与上下文笔记；
- 删除消息的树语义在模型层 `delete_message_from_history`（`models/chats.py:795-833`）：被删消息的孙节点重挂到父节点，`currentId` 回退到活动叶子；
- 恢复：`get_chat_by_id` 直接返回 `chat` JSON（快照天然自愈）；消息表缺失不破坏快照读取（第 2 节自愈策略）。异常退出时临时会话（`temporary:`）不落库、不恢复。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑**：`POST /{id}/messages/{message_id}` 只改目标消息的 `content`（1402-1456 行）；权限校验为"非本人且非管理员则拒绝"（1423-1427 行，删除端点同构 1484-1488 行）；
- **分支（fork）**：`POST /{id}/fork` 调 `build_fork_history`（`utils/chat_fork.py:4-41`）沿 `parentId` 从源消息一路回溯到根，deepcopy 后重建单向 `childrenIds` 链，生成**新会话**，不是原会话内切分支；
- 新会话通过 `originalChatId`/`branchPointMessageId`/`forked_from` 记录来源（1730-1734 行）；
- **克隆**：`POST /{id}/clone` 复制整个会话为新会话（`import_chats`），`branchPointMessageId` 指向当前 `currentId`；
- **版本切换**：不创建新消息对象。历史快照本身就是分支树，切换靠 `history.currentId` 指针与 `showMessage`（前端沿 `childrenIds` 走到叶子），数据语义见 Chat UI 笔记 Overview 一节；
- **重试/续写/回退的执行语义**（从哪个节点重建请求）在对话请求与上下文笔记第 7 节；本类目只记录它们修改的对象：重试/续写复用原消息 ID 写入（`assistant_message_id`），不新建分支节点。

## 5. 列表、分页、搜索与定位

- GET `/list`（`chats.py:220-259`）：分页 60 条/页（233-235 行），支持 `include_pinned`/`include_folders`/`sort_by`/`sort_dir` 参数；
- `add_active_state_to_chat_list` 依据 `ACTIVE_CHAT_GAP_SECONDS` 标记活跃；
- 未读：`POST /read`（262 行）批量置已读并返回 `folder_unread_counts`；`POST /{id}/unread`（2092 行）把 `last_read_at` 置 0；
- 前端读消息经 socket `events:chat`（`socket/main.py:534-579`）更新 `last_read_at` 并向房间广播 `chat:list`；
- 搜索：`GET /search`（846 行）→ `Chats.get_chats_by_user_id_and_search_text`（`models/chats.py:1735`）：
  - 前缀过滤：`tag:` / `folder:` / `pinned:` / `archived:` / `shared:`（1757-1796 行）；
  - 文本匹配：标题子串或消息内容 JSON 搜索（SQLite 用 `json_each`，1817-1840 行；PostgreSQL 走同构条件）；
  - 附加行为：`tag:` 前缀无结果时自动删标签（875-882 行）；命中片段 `chat_search_snippet` 随行返回（871 行）；
- 命中定位（跳转到具体消息）是前端行为，见 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

- **双写对齐是单向的**：`reconcile_messages_by_chat_id`（`models/chats.py:898-907`）只把快照消息 upsert 进表，不推断删除——`POST /{id}` 的合并策略（`merge_history`，773-793 行）同样只合并不删，前端并发快照与后端一致性的边界被明确划定；
- **流式增量落库**：生成中 `update_db=True` 的事件按类型写表（`socket/main.py:997-1092`），事件类型到写入行为的映射如下：
  ```text
  status → status_history 追加
  message → content 追加
  replace → content 覆盖
  embeds / files → 按 replace 标志追加或覆盖
  source / citation → sources 追加
  ```
- **并发写入无锁**：`upsert_message` 是读-改-写（226-261 行），usage 合并使用 `merge_usage` 幂等叠加；多实例并发写同一 chat 的最终一致性未做运行验证（见未验证事项）；
- **取消与清理**：删除/归档/分叉前都会 `stop_item_tasks` 或 409 拒绝，防止半截任务写回；`cleanup_task` 在任务 done 回调中注销（`tasks.py:86-100`）。

## 7. 迁移、导入导出与保留策略

- **Schema 版本管理**：Alembic，版本位于 `backend/open_webui/migrations/versions/`（55 个版本），其中直接涉及 chat/chat_message 表的有：
  ```text
  8452d01d26d7_add_chat_message_table
  4c5ce3d2f27f_add_context_summary_to_chat_message
  1af9b942657b_migrate_tags
  242a2047eae0_update_chat_table
  ```
- **兼容路径**：消息表无行即视为旧版数据，回退 JSON blob 并回填（第 2 节）；`DB_TO_JSON_KEY_MAP`/`EXCLUDED_COLUMNS`（`chat_messages.py:321-329`）保证行→字典转换对未知字段宽容；
- **导入导出**：`POST /import`（788 行）与 `import_chats`（`models/chats.py:534-589`）支持整包导入并双写消息表，导入时清理悬空 `folder_id`（541-554 行）。
- 统计导出：`GET /stats/usage`（279 行）、`GET /stats/export`（581/627 行）。
- **保留策略**：本次未找到自动过期回收或定时清理的代码（检查范围：`routers/chats.py` 全部端点与 `Chats` 表操作方法）。
- 批量清理只存在于手动入口：`DELETE /`、`POST /archive/all`（1093 行）、`POST /unarchive/all`（1108 行）。

## 8. Agent、模型、知识库与附件绑定

- **会话级**：`folder_id`、`variables`、`meta`（tags、internal、forked_from 等）、`tasks` 快照；
- **消息级**：消息行保存模型、附件、引用、嵌入、输出与用量等字段（完整字段见 §1.2 表）；`ChatFile` 表另存 `chat_id+message_id+file_id` 关系（139-152 行）；
- **任务级（不持久化在消息上）**：下列字段只随生成请求传递，`chat_message` 表列中不存在（表结构 128-172 行）：
  ```text
  tool_ids / skill_ids / filter_ids / features
  ```
- 工具调用过程以 `output`/`meta` 内容留存，`_extract_tool_names` 扫描这些字段即为此类统计设计（89-120 行）；
- **引用与历史快照**：分享（SharedChat）是时刻快照；分叉记录 `forked_from` 引用而非复制关系表；模型绑定是消息级快照（`model_id` 文本列），模型实体变更不回写历史。

## 9. 设计取舍与已确认边界

- **双写是历史兼容与可扩展性之间的折中**：前端读取快照 O(1)，写操作需要显式同步两处；对齐方向固定为快照→表，删除必须以专用端点执行；
- **消息树用 `modelIdx` 保留多模型并行的列序**：side-by-side 是内建数据语义而非插件（该字段随消息内容写入，`main.py:1287-1290` 保留）；
- **内部会话**（`meta.internal=True`，如子代理）不出现在普通列表，删除时级联（1568 端点 1599-1601 行）；
- **类目边界**：任务系统（asyncio + Redis 记账）、流式通道（Socket.IO）与上下文管线属于对话请求与上下文；Overview 消息树图的导航交互属于 Chat UI。

## 10. 未验证事项

- 多实例并发写入时 history 快照与消息表的最终一致性未做运行验证（静态代码只能确认写入入口与合并方向）。
- 频道消息、Ydoc 协作、Direct Connection 客户端内部实现不在本类目调查范围（已排除）。
- 大数据量下的 `json_each` 消息内容搜索性能未验证。

## 11. 关键源码索引

- Chat 表与表操作：[`models/chats.py`](../../open-webui/backend/open_webui/models/chats.py)（`Chat` 70-102、`merge_history` 773、`reconcile_messages_by_chat_id` 898、`get_messages_map_by_chat_id` 909）
- ChatMessage 表与消息树重建：[`models/chat_messages.py`](../../open-webui/backend/open_webui/models/chat_messages.py)（`upsert_message` 210、`get_messages_map_by_chat_id` 331）
- Chat/消息 CRUD 路由：[`routers/chats.py`](../../open-webui/backend/open_webui/routers/chats.py)
- 分叉构建：[`utils/chat_fork.py`](../../open-webui/backend/open_webui/utils/chat_fork.py)
- 事件定义：[`events.py`](../../open-webui/backend/open_webui/events.py)（161-221 行）
- 流式增量落库：[`socket/main.py`](../../open-webui/backend/open_webui/socket/main.py)（`get_event_emitter` 968、`events:chat` 534）
- Schema 版本目录：[`backend/open_webui/migrations/versions/`](../../open-webui/backend/open_webui/migrations/versions/)
