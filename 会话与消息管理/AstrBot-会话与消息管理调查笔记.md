# AstrBot 会话与消息管理调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：只读源码与历史快照差异交叉定位；重点核实 WebChat 会话列表与消息分页、checkpoint 编辑重生成及侧线程删除级联；持久化与迁移结论以所列源码为依据，未启动服务
>
> 调查范围：两级会话概念、会话标识、对话持久化与 ConversationManager、WebChat 会话行/线程/消息编辑、群历史持久化、schema 升级与备份；事件调度、流水线与并发执行进入对话请求与上下文，界面进入 Chat UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 是面向 IM 平台（QQ/Telegram/Discord/微信等）的**消息驱动异步聊天框架**，会话与消息以"平台会话 → 子对话"两级结构持久化：

- **两级会话概念**：会话（session）是一个聊天窗口（如某个群），由 `unified_msg_origin` 标识，格式为 `platform_id:message_type:session_id`；对话（conversation）是会话内部的子对话，可以新建、切换与删除。标识定义见 `message_session.py:18-27`，两级关系的说明见 `conversation_mgr.py:1-5` 的模块 docstring。
- **持久化双轨**：LLM 对话历史落在 SQLite 的 `conversations` 表，content 字段保存 OpenAI 格式的消息 JSON 列表；当前对话指针由 SharedPreferences 以 `sel_conv_id` 为键持久化到 `preferences` 表；WebChat 的显示消息与会话行另存 `platform_message_history` 与 `platform_sessions` 两张表。
- **新增的会话元数据**：`umo_senders` 表记录每个 UMO 下出现过的发送者 ID 与名字，供发送者选择器和别名查询使用；`chatui_projects` 与 `session_project_relations` 把 WebChat 会话归入项目分组，属于项目的会话在普通会话列表中排除。两张项目表的定义见 `po.py:369-381` 与 `po.py:469-531`。
- **写入即时、无防抖**：新建或切换对话时，入口直接把新的当前对话指针写进 SharedPreferences，两处入口见 `conversation_mgr.py:123` 与 `:137`。类字段 save_interval 定为 60 秒，全仓检索只命中定义处一处，没有周期落盘或延迟合并的实现，保存行为是即时的，崩溃丢失最近对话的推断不成立。
- **WebChat 独有分支机制**：WebChat 的消息带 `llm_checkpoint_id`，用来关联对话历史里的某个 turn；编辑用户消息、重生成 bot 消息和创建侧线程（thread）都靠 checkpoint 先定位 turn 范围，再截断或复制历史。三条路径见 `chat_service.py:1689-1761`、`:1860-1946` 与 `:1960-2066`。
- **附件改名与分片上传**：WebChat 附件落盘时由 `unique_attachment_filename` 生成不冲突的文件名，上传支持分片续传，入口见 `chat_service.py:66`。平台消息历史只保存附件引用，对话历史的结构保持不变。
- **群历史可选持久化**：默认关闭的 `provider_ltm_settings.group_message_history_enable` 打开后，群消息与 bot 回复会写进平台消息历史表，并按 group_message_history_max_cnt 的上限 700 条裁剪，同时暴露读取工具。两项默认值见 `default.py:229-230`，读取工具见 `message_tools.py:357-361`。

## 系统边界与数据主链

```text
平台适配器收到消息 -> 构造 AstrMessageEvent（platform:message_type:session_id）
  -> ConversationManager.get_curr_conversation_id（内存 -> preferences 表 -> None）
  -> 流水线处理（执行语义在对话请求与上下文）
  -> agent 结束后 InternalAgentSubStage._save_to_history 整体覆写 conversations.content
  -> sel_conv_id 指向当前对话（切换/新建时立即写 preferences 表）

WebChat 侧（对话请求开始前与结束后各写一次）：
  ChatService.build_chat_stream 先把用户消息写入 PlatformMessageHistory
    -> webchat 队列 -> 适配器 -> 同一流水线
    -> WebChatMessageEvent.send 把结果写入 back_queue
    -> _consume_chat_run 汇流并写入 bot 记录（PlatformMessageHistory）
```

边界：事件总线、流水线调度、并发锁与上下文构建属于对话请求与上下文；消息发送后的结果装饰与界面属于 Chat UI；`get_group_message_history` 的工具语义与群上下文注入属于请求侧。

## 1. 会话、消息与分支数据模型

### 1.1 会话与对话两级概念

`ConversationManager` 模块 docstring（conversation_mgr.py:1-5）明确：会话用于标记对话窗口（如群聊 `123456789`），一个会话内可以建立多个对话，并支持对话的切换和删除。会话 = 聊天窗口，对话 = 会话内子对话。

### 1.2 会话标识（unified_msg_origin）

`MessageSession`（message_session.py:6-27）：

```text
unified_msg_origin = f"{platform_id}:{message_type.value}:{session_id}"
```

- 字符串到会话对象的转换由 from_str 完成，内部用 `split(":", 2)` 切出最多三段，因为 session_id 本身可能含有冒号；解析实现见 `message_session.py:24-27`。
- platform_name 自 v4.0.0 起实际保存的是 platform_id，取值由 __post_init__ 自动填成与 platform_id 相同；注释与初始化见 `message_session.py:13` 与 `:21-22`。
- WebChat 的 session_id 形如 webchat!{用户名}!{会话ID}，消息类型固定为 FriendMessage，拼出的完整 UMO 为 `webchat:FriendMessage:webchat!{用户名}!{会话ID}`；适配器生成见 `webchat_adapter.py:213`，UMO 拼接见 `chat_service.py:306-315`。
- 会话显示名单独保存在 `umo_aliases` 表里，含 auto_name 与 user_alias 两个字段，由 `/name` 命令维护；表定义见 `po.py:346-368`，命令实现见 `builtin_stars/builtin_commands/commands/name.py`。

### 1.3 平台会话行（PlatformSession）

`platform_sessions` 表（po.py:309-345）只承载 WebChat 会话列表；QQ/Telegram 等 IM 平台没有对应行，会话即 UMO 本身。字段说明如下表：

| 字段 | 说明 |
|---|---|
| `session_id` | UUID（:323-328） |
| `platform_id` | 默认 `webchat`（:329-330） |
| `creator` | 用户名（:331-332） |
| `display_name` | 可空（:333-334） |
| `is_group` | 注释"not implemented yet"（:335-336） |

### 1.4 对话表（ConversationV2）

`conversations` 表（po.py:72-116）：

| 字段 | 说明 |
|---|---|
| `inner_conversation_id` | int 自增主键（:75-79） |
| `conversation_id` | str UUID，唯一（:80-85、:110-115） |
| `platform_id` / `user_id` | user_id = UMO（:86-87） |
| `content` | OpenAI 格式历史 JSON 列表（:88） |
| `title` | 可空（:90） |
| `persona_id` | 对话级角色绑定（:91） |
| `token_usage` | 累计 token，0 时用估计器（:92-96 注释） |

索引（:98-116）：`(created_at DESC, inner_id DESC)` 与 `(platform_id, created_at DESC, inner_id DESC)` 两个复合索引，供列表排序与分页使用。

### 1.5 消息模型与 WebChat 显示消息

- **LLM 历史（conversations.content）**：OpenAI 格式线性消息数组（role: system/user/assistant/tool）。WebChat 场景额外含 `CheckpointMessageSegment`（`llm_checkpoint_id`，internal.py 历史写入、po.py 的 Conversation docstring）。
- **平台消息历史（platform_message_history.content）**：平台无关表示 `{"type": "user"|"bot", "message": [parts]}`。part 类型包括下列取值（不限于，媒体以 `attachment_id` 或文件名引用）：

  ```text
  plain | at | reply | media | tool_call | think
  ```

  消息链的转换在 `platform_message_history_mgr.py:32-106`，bot 内容的组装在 `chat_service.py:97-113`。
- **附件**：附件在消息级绑定，消息 part 通过 `attachment_id` 指向 `attachments` 表，表内记录 path、type 与 mime_type 等字段；文件实体存放在独立的数据目录，落盘时使用去重后的唯一文件名。表定义见 `po.py:382-412`，唯一文件名的生成见 `chat_service.py:66`。

### 1.6 分支：WebChat Thread

`webchat_threads` 表（po.py:279-308）记录父会话、父消息、基点 checkpoint 与选中文本。创建流程在 `chat_service.py:1689-1761`：选中 bot 消息文本 → 校验该消息是 bot 且带 `llm_checkpoint_id` → 用 checkpoint 在对话历史中定位 turn 范围 → 把**到 checkpoint 为止**的历史复制进新对话；thread 的 UMO 为 `webchat:FriendMessage:webchat!{用户名}!{thread_id}`。这是数据侧的"分支"：复制历史起点而非共享指针，thread 独立演进。IM 平台无对应机制。

### 1.7 会话分组：ChatUI 项目

`chatui_projects`（po.py:469-508）保存项目 ID、名称与创建者，`session_project_relations`（:509-531）记录会话到项目的归属。项目分组只影响 WebChat 会话列表的呈现与筛选：`get_sessions` 会排除项目会话，项目详情页另行查询（`chat_service.py:1571-1602`）。IM 平台没有项目概念，会话列表仍按 UMO 平铺。

## 2. 事实源、索引与持久化

- **LLM 历史权威源**：`conversations.content`。读取统一经 `ConversationManager.get_conversation`（conversation_mgr.py:190-214），内部把 `ConversationV2` 转成 v3 时代的内存模型 `Conversation`（history 为 JSON 字符串），历史 API 零改动。
- **当前对话指针权威源**：`preferences` 表（key=`sel_conv_id`，po.py:219-245）。内存缓存只是读穿缓存（`get_curr_conversation_id` :174-188：内存 → 表 → None，命中后回填 :187）。
- **WebChat 显示消息权威源**：`platform_message_history`（platform_id=webchat）。`ChatService.get_session` 现接受一基页码和 1-1000 的 page_size，返回总数与 has_more；前端默认每页 50 条并逐页向前加载（`chat_service.py:1603-1658`；`dashboard/src/composables/useMessages.ts:294-441`）。
- **群历史权威源**：同表（platform_id=各 IM 平台）。索引 `(platform_id, user_id, id)`（po.py:269-277）。
- **持久化时机**：对话切换/新建/删除即写 preferences（conversation_mgr.py:123、137、158、169 四处入口）；对话历史在 agent 完成后的收尾阶段整体覆写（internal.py 的 `_save_to_history`，见请求侧笔记 §6）；WebChat 用户消息先写、bot 消息流式过程中按批写（chat_service.py:1081-1277、build_chat_stream :1278 起）。
- **无防抖**：`save_interval = 60`（conversation_mgr.py:25）是死代码（全仓仅定义处出现），不存在周期落盘或防抖合并。

## 3. 创建、切换、归档、删除与恢复

- **新建对话**：new_conversation 先插入对话行，再更新内存缓存，并立即写入当前对话指针，实现见 `conversation_mgr.py:92-124`。IM 平台在首次 LLM 请求时惰性创建：请求构建阶段没有当前对话就新建一个。`/new` 命令会先停掉同一 UMO 上的活跃事件再新建，新对话只继承当前对话的 persona_id，模型不随对话继承，命令实现见 `commands/conversation.py:222-252`。
- **切换**：switch_conversation 同时更新内存与 SharedPreferences 中的当前对话指针，写入即时完成，入口见 `conversation_mgr.py:126-137`。
- **删除**：delete_conversation 删除单个对话并清空当前指针；delete_conversations_by_user_id 删除某个会话下的全部对话，并触发会话删除的级联回调，供知识库配置等清理使用。两个函数、回调实现与回调注册见 `conversation_mgr.py:30-43`、`:45-60` 与 `:139-172`。
- **重置**：`/reset` 把当前对话的历史清空（以空列表调用 update_conversation）并停止活跃事件，入口见 `conversation.py:110-180`。
- **WebChat 会话生命周期**：PlatformSession 行在首次发送消息时惰性补齐，也可以由接口显式创建。删除会话是级联清理：先停止正在运行的 run，再删除对话与平台历史（含附件文件），随后删除子线程、UMO 配置路由和会话行；批量删除会返回失败项明细。创建、级联删除与批删的入口见 `chat_service.py:1307-1315`、`:1415-1465`、`:1482-1520` 与 `:1554-1569`。
- **恢复**：重启后当前对话指针从 preferences 表读回，对话历史在写入时已经落库。WebChat 的生成中状态（ChatRunState，chat_service.py:539 起）只存在内存里，重启即丢失，运行期间可由前端通过 `/chat/runs/{id}/stream` 以快照恢复。

## 4. 编辑、重试、续写、回退与分支语义

- **IM 平台**：消息本身落在平台侧，AstrBot 数据层不提供编辑/删除消息操作；对会话数据的修改只有对话级操作（新建/切换/删除/重置）。
- **WebChat 编辑用户消息**（chat_service.py:1860-1952）：只允许编辑**最新**一条用户消息（必须是最后 turn 且带 checkpoint）；编辑后分配新 checkpoint、删除该消息之后的所有平台历史与派生线程、把对话历史截断到该 turn 前，返回 `needs_regenerate`。前端随后自动续写或重生成下一条 bot 消息（Chat.vue）。
- **重生成 bot 消息**（chat_service.py:1960-2066）：只允许最新 checkpoint；分配新 checkpoint、从对话历史剔除旧 turn、删除旧 bot 显示记录与派生线程，随后以同一用户消息重新走生成（跳过用户消息重放并打新 checkpoint）。旧版本不保留，不是版本切换式分支。
- **侧线程**：见 1.6，从选定 bot 消息复制历史到新对话，是最接近"分支"的机制。
- 以上均修改持久化对象而非仅内存；`update_message`/`prepare_regenerate_message_payload` 是唯一两条会改写历史与显示消息的入口。

## 5. 列表、分页、搜索与定位

- **对话列表**：get_filtered_conversations 支持分页、排序与搜索过滤，具体行为见下面的分条清单；对话管理页 ConversationPage.vue 直接调用这个接口，并在其上提供导出、批量删除与消息替换。入口在 `conversation_mgr.py:240-277`，SQL 组装在 `sqlite.py:374-500`。
  - 排序为 `created_at DESC, inner_id DESC`，分页默认 20/页；
  - 搜索为 `ilike` 模糊匹配标题、用户、会话 id 与内容（含 JSON 转义后的第二遍匹配）；
  - 可过滤消息类型、平台与排除 id/平台；
  - `include_history=False` 时延迟加载 content；
  - 多平台分页强制走全局排序索引。
- **WebChat 会话列表与消息历史使用两套分页口径**：会话列表入口按 creator 查询并排除项目会话，固定取第 1 页的 100 行，只返回列表本身，当前工作台没有从这个入口继续翻页的参数。单个会话的消息历史接受页码和页大小，第 1 页包含最新记录；前端每页取 50 条，插入旧页时按消息 ID 去重。列表与历史的分页实现见 `astrbot/dashboard/services/chat_service.py:1571-1594` 与 `:1603-1678`，前端逻辑见 `dashboard/src/composables/useMessages.ts:292-438`。
- **群历史**：PlatformMessageHistoryManager.get 先分页读取再反序，返回按时间升序排列的记录，实现见 `platform_message_history_mgr.py:108-123`。get_group_message_history 工具在其上限制单次数量不超过 50 条，并支持 before_id 翻页、不区分大小写的关键字搜索和发送者过滤，入口见 `message_tools.py:370-393` 与 `:418-434`。
- **搜索与定位**：搜索全部落在 SQL 层的 ilike 模糊匹配上，没有独立的搜索索引；命中后的滚动定位由 WebChat 前端在已加载的消息里完成（scrollToMessage，Chat.vue:1472-1480），会话数据层只提供会话级查询，消息级定位由前端承担。

## 6. 缓存、一致性、多窗口与并发写入

SharedPreferences 现在不再在启动时镜像整张 `preferences` 表：内存仅保留本进程写入的覆盖层，未命中异步读取会按键查询 SQLite，避免插件 KV 很大时的全表预加载与内存膨胀；写入仍由 FIFO 队列异步落库（shared_preferences.py:44-57、182-224、267-288）。这改变的是偏好读取的缓存策略，不改变 `sel_conv_id` 等会话指针的持久化归属。

- **读穿缓存**：session_conversations 只作读取缓存，没有写回路径，任何切换都会直接写库（见 §2）；缓存失效时数据随之丢弃，权威副本仍在数据库中。
- **并发写入**：update_conversation 按字段增量更新，title、persona_id、content 与 token_usage 各自只在传入值非 None 时改写，同一对话的并发更新最终由后写者覆盖，实现见 `sqlite.py:631-653`。add_message_pair 的读—改—写过程本身没有加锁，实际调用被请求侧的 UMO 级会话锁串行化（见请求侧笔记），入口见 `conversation_mgr.py:357-390`。
- **WebChat 生成流**：每个 run 由单个消费协程 _consume_chat_run 串行读取 back_queue 并落盘，同一 run 内不会出现并发写；不同 run 之间互不影响，实现见 `chat_service.py:1081-1277`。
- **多窗口**：内存中的 chat_runs 与 chat_runs_by_session 表允许同一会话并存多个 run，SSE 订阅者集合按 revision 广播。多窗口同时编辑同一条消息时没有乐观锁，静态代码里未见版本号校验，此项未运行验证。
- **同文本去重**：RespondStage 在发送前比对已有记录，命中 send_message_to_user 已发送的相同文本就跳过，避免重复回复落到平台侧；数据层没有重复检测，逻辑见 `respond/stage.py:213-235`。

## 7. 迁移、导入导出与保留策略

- **schema 迁移**：迁移逻辑集中在 astrbot/core/db/migration/ 目录，按目标版本与用途拆成多个脚本，当前脚本与旧版兼容脚本分列如下：
  - 当前：`migra_3_to_4.py`、`migra_45_to_46.py`、`migra_token_usage.py`、`migra_webchat_session.py`
  - 旧版：`sqlite_v3.py`、`shared_preferences_v3.py`
- **WebChat 会话迁移**：迁移脚本从 webchat 平台的历史 platform_message_history 记录里按用户去重，生成对应的 PlatformSession 行，显示名取旧 ConversationV2.title 的值；目标行已存在时跳过，脚本可重复执行，由 migra_helper 统一导入。实现见 `migra_webchat_session.py:19-103`。
- **导入导出**：备份模块按表全量导出与导入，表集合定义在 backup/constants.py 中，覆盖 platform_sessions、umo_senders、chatui_projects 以及会话与项目的关联表，附件等文件数据一并处理。导出与导入入口分别是 `core/backup/exporter.py` 与 `importer.py`。
- **保留策略**：群历史在插入时按 max_messages 裁剪，只保留最新 N 条，入口是 sqlite.py 的 insert_platform_message_history；PlatformMessageHistoryManager.delete 按时间偏移删除较早记录；WebChat 会话被删除时，相关历史全量清除。三处实现分别见 `sqlite.py:781-858`、`platform_message_history_mgr.py:125-133` 与 `chat_service.py:1415-1465`。群上下文的 1000 条内存环形缓冲不落盘（请求侧笔记 §5.3）。

## 8. Agent、模型、知识库与附件绑定

- **Persona（角色）**：对话级角色绑定记录在 ConversationV2.persona_id 字段，/new 新建对话时继承（见 §3）。此外还有会话级覆盖：session_service_config 规则以 UMO 为作用域存在 preferences 表，解析时先取会话规则的强制指定，再看对话上的 persona，最后回落到 provider 的默认 persona；webchat 在没有 persona 时使用 _chatui_default_。解析顺序与兜底见 `persona_mgr.py:123-200`。
- **模型**：模型在每次请求时解析，优先取 event.get_extra("selected_model") 的值（WebChat 前端可传入），取不到时用 provider 的默认模型；对话记录不保存模型的历史快照。取值位置见 `astr_main_agent/request.py:267`。
- **Provider/Agent 类型**：会话级规则可以覆盖 provider，例如 provider_perf_chat_completion 一类规则，见 `session_management_service.py:20-22`；agent_runner_type 则属于配置级设置。
- **配置档案中的 Agent Runner**：Local runner 的默认 provider、fallback、Persona、压缩与运行参数作为 agent_runner.config 嵌在每份配置 profile 里，对话消息不保存这些字段的历史快照。字段定义见 `astrbot/core/config/agent_runner.py:9-36,172-201`。
- **知识库**：知识库在会话级配置，按 UMO 建立路由与规则；会话被删除时，通过 register_on_session_deleted 注册的级联回调清理相关配置。回调实现与注册位置见 `conversation_mgr.py:30-43` 与 `:171-172`。实际的知识检索与上下文注入发生在请求侧。
- **附件**：附件在消息级绑定，消息 part 通过 attachment_id 指向附件记录（见 1.5）；上下文历史只保存引用或文件名，文件实体独立存放在 conversations 表之外，附件的文件内容不进入历史快照。

## 9. 设计取舍与已确认边界

- **两级模型解耦平台与对话**：会话（UMO）可跨重启稳定寻址，对话（conversation）可自由切换；`sel_conv_id` 指针而非外键引用，对话行与指针独立删除。
- **WebChat 与 IM 双轨持久化**：IM 平台消息留在平台侧（`Conversation` docstring po.py:582-604 明确"不存储非 LLM 的回复"），WebChat 无平台可依赖，故建 `platform_message_history` 全量存储显示消息。
- **checkpoint 定 turn**：编辑/重生成/线程共用同一套 checkpoint→turn 定位逻辑（chat_service.py 的 `_locate_checkpoint_turn_range` 等辅助，见 :353-378、:445-463），一致性代价是只允许操作"最新" turn。
- **写入即落库、无防抖**：`save_interval` 死代码说明防抖机制已移除，简单换取崩溃安全性（无未落盘窗口）。
- **类目边界**：会话与消息的持久化语义在本笔记；每条入站消息的任务化、流水线调度、并发锁与上下文压缩在对话请求与上下文笔记；WebChat 界面操作入口在 Chat UI 笔记。

## 10. 未验证事项

- 崩溃恢复（无防抖窗口是否完全无丢失）未实测，未做过进程级验证。
- `unique_session` 开启后按发送者隔离会话的实际行为未运行验证（waking_check/stage.py:82-85 只确认了改写逻辑）。
- 群历史持久化开关下的存储与裁剪行为未运行验证（有单元测试 tests/unit/test_group_message_history.py，未运行）。
- WebChat 多窗口并发编辑同一消息的竞态未运行验证（无版本号校验，静态推断存在覆盖风险）。
- Thread 与父会话在父消息被编辑/重生成后的级联删除仅从代码路径确认，未实测。

## 11. 关键源码索引

- 会话管理：`astrbot/core/conversation_mgr.py`、`astrbot/core/platform/message_session.py`
- 数据模型：`astrbot/core/db/po.py`（ConversationV2 :72-116、PlatformMessageHistory :246-278、WebChatThread :279-308、PlatformSession :309-345、UmoAlias :346-368、UmoSender :369-381、Attachment :382-412、ChatUIProject :469-508、SessionProjectRelation :509-531）
- 持久化：`astrbot/core/db/sqlite.py`（conversations :374-653、platform_message_history :781-859、platform_sessions :2032-2200）、`astrbot/core/utils/shared_preferences.py`
- WebChat 会话服务：`astrbot/dashboard/services/chat_service.py`（构建/消费流 :1081-1414、删除级联 :1415-1520、列表/分页 :1571-1658、线程 :1689-1860、编辑/重生成 :1860-2066、附件名 :66）
- 群历史：`astrbot/builtin_stars/astrbot/main.py`（:150-200、:273-323）、`astrbot/core/tools/message_tools.py`（:357-461）、`astrbot/core/platform_message_history_mgr.py`
- 迁移：`astrbot/core/db/migration/migra_webchat_session.py`、`migra_helper.py`
- 命令：`astrbot/builtin_stars/builtin_commands/commands/conversation.py`（/new :222-252、/reset :110-180）
