# Open WebUI 会话与消息管理调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：直接阅读源码（FastAPI 路由与模型层、Socket.IO 事件处理、Alembic schema 版本、前端 store）
>
> 调查范围：会话与消息的数据模型、事实源与双写、CRUD 与生命周期事件、分叉/克隆/压缩、列表分页与搜索、一致性与恢复；生成任务执行与流式通道进入对话请求与上下文，前端工作台进入 Chat UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 当前快照的 Chat 体系以**「会话 chat JSON 快照 + chat_message 消息表」双写**为特征：每条消息同时存在于 `chat.chat.history` 快照与 `chat_message` 行中，前端展示以历史快照为主，数据库行用于增量同步、统计和恢复。

- 常规聊天与消息的增删改查集中在 [`routers/chats.py`](../../open-webui/backend/open_webui/routers/chats.py)，审批与人工提问的消息结算端点另见 [`main.py:1883-1906`](../../open-webui/backend/open_webui/main.py#L1883-L1906)；频道消息模型与聊天消息表分属两套体系；
- 消息以 `{chat_id}-{message_id}` 复合键写入 `chat_message` 表，主键格式见 `chat_messages.py:224`。快照里的 `parentId` 与 `childrenIds` 勾出消息树，`modelIdx` 记录多模型并行（side-by-side）时的列序；
- 编辑与删除都落到单条消息；会话更新只合并 history（`Chats.merge_history`，`chats.py:1360`），快照里缺少的消息 ID 不会被推断成删除，删除动作由独立端点承担；
- 标记 `meta.internal=True` 的会话算内部会话（例如子代理），普通列表不展示，判定在模型层的 `is_internal_chat`；
- 双写的直接后果是读写代价不同：前端读快照是 O(1) 操作，写操作则要同步快照与消息表两处，由 `reconcile_messages_by_chat_id` 兜底对齐；消息表缺行时读取回退到旧版 JSON blob，并由自愈回填补齐。

## 系统边界与数据主链

```text
POST /api/chats/new 或 POST /api/chat/completions（is_new_chat）
  -> Chat 表插入（chat JSON 含完整 history 快照，models/chats.py:416 insert_new_chat）
  -> 初始消息双写 chat_message 表（insert_new_chat 内 448-467 行）
  -> 流式期间：history 快照由前端维护，数据库行经 Socket.IO 事件增量更新
     （`socket/main.py:1057` 起按类型落库）
  -> 完成：usage 落库、chat:list 刷新
  -> 会话列表 / 搜索 / 未读：按 chat_list_order 与标题+内容搜索查询
  -> 归档 / 分享 / 分叉 / 克隆 / 删除 / 压缩
```

边界：一次生成任务如何执行（`chat_completion` → `process_chat_payload` → fan-out → Socket.IO 流）在对话请求与上下文；前端发送链与 Overview 消息树图导航在 Chat UI；消息内容渲染在消息渲染器（`../消息渲染器/Open-WebUI-消息渲染器调查笔记.md`）。排除频道（channel）消息、Ydoc 协作、Direct Connection 客户端内部实现。

## 1. 会话、消息与分支数据模型

### 1.1 会话单位与 Chat 表

- **会话单位**：持久化对象只有 `Chat` 一种，对应 `chat` 表。
- 前缀语义：带 `temporary:` 或 `local:` 前缀的会话不落库，只作为前端发送前的占位；`channel:` 前缀的会话归频道消息体系处理（`utils/chat_id.py:4-20`）。
- ID 生成：会话 ID 由路由侧调用 `str(uuid4())` 生成，消息 ID 由前端用 `uuidv4()` 生成，服务端再把两者拼成 `{chat_id}-{message_id}` 复合主键（`chats.py:769`、`Chat.svelte:2509`）。

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

- 活跃状态：列表要求会话同时存在活跃任务与未完成 assistant 消息，才标记为 active（`routers/chats.py:179-189`）。30 分钟间隔常量用于累计相邻消息之间的活跃时长统计（`models/chats.py:2120-2127`）。
- 列表排序支持按更新时间、标题与未读时间三种方式，未读排序结合未完成 assistant 消息的子查询与已读时间差值计算（`models/chats.py:43-67`）；
- 内部会话：`meta.internal=True` 的会话由 `is_internal_chat` 判定，所有列表查询统一用布尔表达式排除这类行（`models/chats.py:105-1310`）；
- 附件关联：`ChatFile` 表按 `chat_id + message_id + file_id` 记录消息附件，`(chat_id, file_id)` 唯一，随会话级联删除（`models/chats.py:139-152`）。

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

- 消息树语义：快照里每条消息带 `parentId` 与 `childrenIds`，`currentId` 指向活动路径；表行只保存 `parent_id`，子节点引用由 `get_messages_map_by_chat_id` 重建。写入消息时快照还会把它挂进父消息的子节点列表，修复活动路径时也按父指针回填缺失的子引用，父消息因此不会丢子指针（`models/chats.py:460-1025`）；
- 写入消息走 `upsert_message`：复合键已存在就逐字段覆盖，`usage` 由 `merge_usage` 累加合并（210-259 行）；
- 读取时 `get_messages_map_by_chat_id` 把表行还原成与 `chat.history.messages` 同构的字典，字段映射如下（321-392 行）：
  ```text
  parent_id→parentId / model_id→model / created_at→timestamp
  ```
- 还原出的消息会重建 `childrenIds` 并回填 `info.usage`；表里查不到行时返回 None，由调用方回退旧版 JSON blob；
- 统计类 API 按模型消息数、token 用量、每日活跃度与 Top 模型/工具等维度出数；其中工具名由 `_extract_tool_names` 递归扫描 `tool_calls`、`tools`、`output` 与 `meta` 得出（89-1024 行）。

### 1.3 附属模型

- **Folder**：文件夹支持父子树形结构；共享文件夹的可见性由 `AccessGrant` 按 user、group、public 三类主体查授权（公开授权的 subject 写作 `user:*`）并取最高权限，判定入口为 `get_shared_folder_ids_for_user`（`models/folders.py:20-162`）；
- **SharedChat**：分享以 `id` 作为 token，`chat` 字段保存的是**分享时刻的 JSON 快照**，`create` 与 `update` 分别负责建快照和重新快照（`models/shared_chats.py:23-64`）；
- **Tag**：标签用 `(id, user_id)` 复合主键，`id` 由名称转小写、空格换成下划线后生成（`replace(' ', '_').lower()`），标签本体存在 `Chat.meta.tags` 里（`models/tags.py:18-98`）；
- **频道消息**：`models/messages.py:37`，字段见下，仅服务 `channel:` 会话：
  ```text
  channel_id / reply_to_id / parent_id / is_pinned / content / data / meta
  ```
- **资源评论**：评论以资源为锚点保存线程化讨论，锚点可以是会话、笔记或频道消息，评论之间记录回复关系与提及；路由提供上下文计数、提及列表、按资源列表、创建、回复与编辑（`routers/comments.py:69-303`），模型定义在 `models/comments.py`。
- **通知收件箱**：`notification` 表承载提醒与系统消息；路由提供收件箱列表、未读数、打开事件与已读状态更新，另有推送目标配置（`routers/notifications.py:70-188`），模型定义在 `models/notifications.py`。
- **版本历史**：工具、函数、模型与技能各自维护历史表，保存编辑快照供对比与回滚：
  ```text
  models/tool_history.py / function_history.py / model_history.py / skill_history.py
  ```
  会话侧沿用 `shared_chat` 的单快照语义，两套机制互不共用。

## 2. 事实源、索引与持久化

- **权威源划分**：前端渲染读 history 快照（O(1)）；增量同步、统计与恢复读消息表；两处由 `reconcile_messages_by_chat_id`（`models/chats.py:1042`）单向对齐（快照 → 表，best-effort，错误只记日志不抛出）；
- **自愈恢复**：`Chats.get_messages_map_by_chat_id`（`models/chats.py:1053`）三级策略——有行且父链完整 → 直接用表；父链有缺口 → 从旧版 JSON 补缺并回填；完全无行 → 回退 JSON blob 并整批回填；
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

- **惰性创建**：空会话列表只是前端占位，真正的会话对象要等 `POST /api/chat/completions` 判定 `is_new_chat` 后才由后端创建（`main.py:1211-1392`），请求执行细节见对话请求与上下文笔记；
- **删除消息的树语义**：`delete_message_from_history` 把被删消息的孙节点重挂到父节点，并让 `currentId` 退回活动叶子（`models/chats.py:940`）；
- **恢复**：`get_chat_by_id` 直接返回 `chat` JSON 快照，消息表缺行也能读（第 2 节自愈策略）；异常退出时带 `temporary:` 前缀的会话不落库，也无从恢复。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑**：`POST /{id}/messages/{message_id}` 只改写目标消息的 `content` 字段，权限规则为非本人且非管理员即拒绝，删除端点沿用同一套判定（`routers/chats.py:1402-1488`）；
- **分支（fork）**：`POST /{id}/fork` 调用 `build_fork_history`，沿 `parentId` 从源消息回溯到根节点，deepcopy 后重建一条单向的 `childrenIds` 链，产出的是**新会话**，原会话内的分支结构维持原样（`utils/chat_fork.py:4-41`）；
- 来源信息写在新建会话的 `originalChatId`、`branchPointMessageId` 与 `forked_from` 三个字段里（`routers/chats.py:1730-1734`）；
- **克隆**：`POST /{id}/clone` 通过 `import_chats` 把整个会话复制成新会话，`branchPointMessageId` 指向复制时的 `currentId`；
- **版本切换**：切换版本不新建消息对象；历史快照本身就是一棵分支树，`history.currentId` 指针决定活动路径，前端 `showMessage` 沿 `childrenIds` 走到叶子节点，数据语义见 Chat UI 笔记 Overview 一节；
- **重新生成与续写改变的对象不同**：重新生成从目标回复的父 user 节点调用发送入口，为助手回复分配新的 UUID，形成同一父节点下的兄弟版本，带修改建议时还把原回复作为重生成上下文；继续生成则复用原助手消息 id，通过 `assistant_message_id` 读取已有输出再追加（[`Chat.svelte:4118-4827`](../../open-webui/src/lib/components/chat/Chat.svelte#L4118-L4827)）。

## 5. 列表、分页、搜索与定位

- **列表与分页**：`GET /list` 返回当前用户的会话列表，每页固定 60 条，查询参数控制固定会话与文件夹是否返回、以及排序方式：
  ```text
  include_pinned / include_folders / sort_by / sort_dir
  ```
  列表项上的活跃标记由 `add_active_state_to_chat_list` 依据 30 分钟空闲窗口算出（`routers/chats.py:262`）。
- **已读与未读**：`POST /read` 批量把会话置为已读并返回各文件夹未读数（`folder_unread_counts`），`POST /{id}/unread` 把 `last_read_at` 重置为 0（`routers/chats.py:303`）。
- **已读时间刷新**：前端打开某条消息时经 socket 的 `events:chat` 事件更新 `last_read_at`，并向房间广播 `chat:list`（`socket/main.py:875`）。
- **会话内搜索**：`GET /search`（`routers/chats.py:884` 起）把请求交给 `Chats.get_chats_by_user_id_and_search_text`（`models/chats.py:2216`），先做前缀过滤再匹配文本：
  - 前缀过滤可把范围缩小到标签、文件夹、固定、归档与共享五类：
    ```text
    tag: / folder: / pinned: / archived: / shared:
    ```
  - 文本匹配同时看标题子串与消息内容：SQLite 用 `json_each` 展开历史 JSON，PostgreSQL 走同构条件；SQLite 连接额外注册了自定义 `like` 函数，把模式转成正则、两侧折叠大小写后全匹配，以对齐 ILIKE 语义，标题检索因此在两种方言下结果一致（`internal/db.py:329`）。
  - 附加行为：`tag:` 前缀查不到结果时自动删掉该标签，命中片段以 `chat_search_snippet` 随行返回。
- **命中定位**：跳转到具体消息由前端完成，见 Chat UI 笔记。
- **工作区级搜索**：`GET /api/v1/search`（`routers/search.py:462`）是另一条实现，按关键词检索会话标题与消息内容，SQLite 走 `json_each`、PostgreSQL 用等价条件，命中项带标题、片段与消息 id；它跨资源聚合，会话内的 `/search` 只列会话行。

## 6. 缓存、一致性、多窗口与并发写入

- **双写对齐是单向的**：`backfill_messages_by_chat_id` 只把快照里的消息 upsert 进表，不据此推断删除；`POST /{id}` 的合并策略（`merge_history`）同样只合并不删，删除动作由独立端点承担（`models/chats.py:1070-1201`）；
- **批量回填**：一次对齐先筛出带 role 的消息，再交给 `ChatMessages.upsert_messages` 放进单个数据库事务写入；这仍是 best-effort 回填，失败时只记一条针对整次 chat 的告警，快照作为权威源的方向不变（`models/chats.py:1201`、`models/chat_messages.py:327`）。
- **流式增量落库**：生成过程中 `update_db=True` 的事件由 `socket/main.py:1057` 起的 event emitter 按类型写表，类型与写入行为的对应关系如下：
  ```text
  status → status_history 追加
  message → content 追加
  replace → content 覆盖
  embeds / files → 按 replace 标志追加或覆盖
  source / citation → sources 追加
  ```
- **并发保证按写入口区分**：普通消息 upsert 含读改写；审批、人工提问结算与工具执行认领都经 `edit_message_output`，在同一事务里读消息、改 output 再双写。SQLite 用 BEGIN IMMEDIATE，其它方言对 chat 行加锁；执行认领提交之后才调用真实工具，工具结束时再核对一次运行状态。各写路径的加锁范围并不一致，多实例最终一致性与外部工具的恰好一次执行都尚未做运行验证（[`models/chats.py:449-489`](../../open-webui/backend/open_webui/models/chats.py#L449-L489)、[`utils/middleware.py:3236-3268`](../../open-webui/backend/open_webui/utils/middleware.py#L3236-L3268)）；
- **Socket 会话身份与清理**：请求处理从本 worker 的 Socket.IO 会话取用户，经 `get_socket_session_user` 读取，不再回查共享的 SESSION_POOL（`socket/main.py:478`）；SESSION_POOL 仍由心跳维护 last_seen_at，孤儿会话清理改为分批扫描，Redis 后端用 HSCAN 取批次、HDEL 批量删除（`socket/main.py:231`、`socket/utils.py`）；
- **取消与清理**：删除、归档与分叉前都会调用 `stop_item_tasks`，或在活动任务未停时以 409 拒绝请求，避免半截任务写回；任务结束时 `cleanup_task` 在 done 回调里注销（`tasks.py:143`）。

## 7. 迁移、导入导出与保留策略

- **Schema 版本管理**：Alembic，版本位于 `backend/open_webui/migrations/versions/`（55 个版本），其中直接涉及 chat/chat_message 表的有：
  ```text
  8452d01d26d7_add_chat_message_table
  4c5ce3d2f27f_add_context_summary_to_chat_message
  1af9b942657b_migrate_tags
  242a2047eae0_update_chat_table
  ```
- **兼容路径**：消息表查不到行时按旧版数据处理，回退 JSON blob 并回填（第 2 节）；行转字典时 `DB_TO_JSON_KEY_MAP` 定义字段对应关系，`EXCLUDED_COLUMNS` 列出排除项，未知字段不会让转换失败（`chat_messages.py:321-329`）；
- **导入导出**：`POST /import` 与 `import_chats` 支持整包导入，导入过程中双写消息表并清理悬空的 `folder_id`（`routers/chats.py:788`、`models/chats.py:534-589`）。
- 统计导出提供两个只读接口：`GET /stats/usage` 与 `GET /stats/export`，分别输出用量汇总与导出报表（`routers/chats.py:279-627`）。
- **保留策略**：本次未找到自动过期回收或定时清理的代码，检查范围覆盖 `routers/chats.py` 的全部端点与 `Chats` 的表操作方法。
- 批量清理只有手动入口：`DELETE /` 与整批归档、整批取消归档两个端点（`routers/chats.py:1093-1108`）。

## 8. Agent、模型、知识库与附件绑定

- **会话级**：会话行自身承载文件夹归属、变量、元数据与任务快照：
  ```text
  folder_id / variables / meta（tags、internal、forked_from 等）/ tasks
  ```
- **消息级**：消息行保存模型、附件、引用、嵌入、输出与用量等字段（完整字段见 §1.2 表）；附件与消息的对应关系另由 `ChatFile` 表记录，键由会话、消息与文件三段组成（`models/chats.py:139-152`）；
- **请求配置与暂停恢复快照**：工具、技能、过滤器和能力选择没有各自独立的消息表列；持久聊天暂停审批或人工提问时，会把这些选择连同附件、终端、变量、参数和原 session id 保存到消息 `meta`。resolve 端点用该快照构造恢复请求，并优先采用会话当前的审批模式；因此它们在暂停场景下具有消息级持久化语义（[`utils/middleware.py:3348-3389`](../../open-webui/backend/open_webui/utils/middleware.py#L3348-L3389)、[`utils/tool_approval.py:188-254`](../../open-webui/backend/open_webui/utils/tool_approval.py#L188-L254)）。
- **压缩检查点**：用户轮次边界的摘要写入消息字段 `contextSummary`（映射数据库 `context_summary`）；工具批次内的摘要保存为 assistant output 中的压缩标记。两者裁剪后续请求的重放范围，原始消息树仍保留，详细算法见[请求与上下文笔记](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md#3-预算截断与压缩)。
- 工具调用过程以 `output` 与 `meta` 内容留存，`_extract_tool_names` 扫描这两个字段，正是为这类统计服务的（`chat_messages.py:89-120`）；
- **引用与历史快照**：分享保存的是分享时刻的快照；分叉把来源记录在 `forked_from` 引用里，关系数据随会话一起保存；模型绑定落在消息级快照（`model_id` 文本列）上，模型实体变更后不回写历史。

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

- Chat 表与表操作：[`models/chats.py`](../../open-webui/backend/open_webui/models/chats.py)（`Chat` 70-102、`merge_history` 917、`reconcile_messages_by_chat_id` 1042、`get_messages_map_by_chat_id` 1053、`_add_child_id_to_parent` 460）
- ChatMessage 表与消息树重建：[`models/chat_messages.py`](../../open-webui/backend/open_webui/models/chat_messages.py)（`upsert_message` 210、`get_messages_map_by_chat_id` 331）
- Chat/消息 CRUD 路由：[`routers/chats.py`](../../open-webui/backend/open_webui/routers/chats.py)
- 分叉构建：[`utils/chat_fork.py`](../../open-webui/backend/open_webui/utils/chat_fork.py)
- 事件定义：[`events.py`](../../open-webui/backend/open_webui/events.py)（161-221 行）
- 流式增量落库：[`socket/main.py`](../../open-webui/backend/open_webui/socket/main.py)（`get_event_emitter` 1057、`events:chat` 587）
- Schema 版本目录：[`backend/open_webui/migrations/versions/`](../../open-webui/backend/open_webui/migrations/versions/)
