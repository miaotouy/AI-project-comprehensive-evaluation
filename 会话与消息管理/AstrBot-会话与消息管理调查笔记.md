# AstrBot 会话与消息管理调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`8ea8ce613a0bee4ddb48b21490afe23418277c75`（分支：`master`）
>
> 调查方式：直接阅读源码（conversation_mgr、SQLite 数据层、SharedPreferences、WebChat 会话服务、schema 升级脚本与备份模块），所有行号按当前 HEAD 逐一核对
>
> 调查范围：两级会话概念、会话标识、对话持久化与 ConversationManager、WebChat 会话行/线程/消息编辑、群历史持久化、schema 升级与备份；事件调度、流水线与并发执行进入对话请求与上下文，界面进入 Chat UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 是面向 IM 平台（QQ/Telegram/Discord/微信等）的**消息驱动异步聊天框架**，会话与消息以"平台会话 → 子对话"两级结构持久化：

- **两级会话概念**：会话（session）= 聊天窗口（如一个群），以 `unified_msg_origin`（`platform_id:message_type:session_id`，message_session.py:18-27）标识；对话（conversation）= 会话内的子对话，可新建/切换/删除（conversation_mgr.py:1-5 docstring）。
- **持久化双轨**：LLM 对话历史存 SQLite `conversations` 表（content 为 OpenAI 格式 JSON 列表）；当前对话指针经 SharedPreferences `sel_conv_id` 持久化（落 `preferences` 表）；WebChat 的显示消息与会话行另存 `platform_message_history`、`platform_sessions` 两张表。
- **写入即时、无防抖**：新建/切换对话的入口内直接写 SharedPreferences（conversation_mgr.py:123、:137）。类字段 `save_interval = 60`（:25）在全仓无任何引用（ripgrep 检索 `save_interval` 仅命中定义处一处），不存在"60 秒防抖保存"；崩溃丢最近对话的推断不成立。
- **WebChat 独有分支机制**：消息带 `llm_checkpoint_id` 关联对话历史 turn；编辑/重生成/侧线程（thread）都基于 checkpoint 定位 turn 范围后截断或复制历史（chat_service.py:1621-1712、:1721-1825、:1459-1530）。
- **群历史可选持久化**：`provider_ltm_settings.group_message_history_enable`（默认关，default.py:229）开启后，群消息与 bot 回复写入平台消息历史表，按配置上限 700 条裁剪（`group_message_history_max_cnt`，default.py:230），并暴露读取工具（message_tools.py:357-361）。

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

- `from_str` 用 `split(":", 2)` 解析（:24-27）——session_id 本身可含冒号；
- `platform_name` 自 v4.0.0 起实际为 platform_id（:13 注释），`__post_init__` 自动取等值（:21-22）；
- WebChat 的 session_id 形如 `webchat!{用户名}!{会话ID}`（webchat_adapter.py:213），完整 UMO 为 `webchat:FriendMessage:webchat!{用户名}!{会话ID}`（chat_service.py:306-315）；
- 会话显示名另有 `umo_aliases` 表（po.py:339-359，`auto_name`/`user_alias`），由 `/name` 命令维护（builtin_stars/builtin_commands/commands/name.py）。

### 1.3 平台会话行（PlatformSession）

`platform_sessions` 表（po.py:302-336）只承载 WebChat 会话列表；QQ/Telegram 等 IM 平台没有对应行，会话即 UMO 本身。字段说明如下表：

| 字段 | 说明 |
|---|---|
| `session_id` | UUID（:316-321） |
| `platform_id` | 默认 `webchat`（:322-323） |
| `creator` | 用户名（:324-325） |
| `display_name` | 可空（:326-327） |
| `is_group` | 注释"not implemented yet"（:328-329） |

### 1.4 对话表（ConversationV2）

`conversations` 表（po.py:67-109）：

| 字段 | 说明 |
|---|---|
| `inner_conversation_id` | int 自增主键（:70-74） |
| `conversation_id` | str UUID，唯一（:75-80、:105-108） |
| `platform_id` / `user_id` | user_id = UMO（:81-82） |
| `content` | OpenAI 格式历史 JSON 列表（:83） |
| `title` | 可空（:85） |
| `persona_id` | 对话级角色绑定（:86） |
| `token_usage` | 累计 token，0 时用估计器（:87-91 注释） |

索引（:93-109）：`(created_at DESC, inner_id DESC)` 与 `(platform_id, created_at DESC, inner_id DESC)` 两个复合索引，供列表排序与分页使用。

### 1.5 消息模型与 WebChat 显示消息

- **LLM 历史（conversations.content）**：OpenAI 格式线性消息数组（role: system/user/assistant/tool）。WebChat 场景额外含 `CheckpointMessageSegment`（`llm_checkpoint_id`，internal.py:474-486 写入、po.py 注释见 Conversation docstring :558-565）。
- **平台消息历史（platform_message_history.content）**：平台无关表示 `{"type": "user"|"bot", "message": [parts]}`。part 类型包括下列取值（不限于，媒体以 `attachment_id` 或文件名引用）：

  ```text
  plain | at | reply | media | tool_call | think
  ```

  链转换在 `platform_message_history_mgr.py:32-106`，bot 内容组装在 `chat_service.py:97-113`。
- **附件**：`attachments` 表（po.py:362-390，字段 path/type/mime_type）做消息级绑定（part 内 `attachment_id`），文件实体存独立数据目录（chat_service.py:510-512、webchat_event.py:20）。

### 1.6 分支：WebChat Thread

`webchat_threads` 表（po.py:272-299）记录父会话、父消息、基点 checkpoint 与选中文本。创建流程在 `chat_service.py:1459-1530`：选中 bot 消息文本 → 校验该消息是 bot 且带 `llm_checkpoint_id` → 用 checkpoint 在对话历史中定位 turn 范围 → 把**到 checkpoint 为止**的历史复制进新对话；thread 的 UMO 为 `webchat:FriendMessage:webchat!{用户名}!{thread_id}`。这是数据侧的"分支"：复制历史起点而非共享指针，thread 独立演进。IM 平台无对应机制。

## 2. 事实源、索引与持久化

- **LLM 历史权威源**：`conversations.content`。读取统一经 `ConversationManager.get_conversation`（conversation_mgr.py:190-214），内部把 `ConversationV2` 转成 v3 时代的内存模型 `Conversation`（history 为 JSON 字符串），历史 API 零改动。
- **当前对话指针权威源**：`preferences` 表（key=`sel_conv_id`，po.py:212-236）。内存缓存只是读穿缓存（`get_curr_conversation_id` :174-188：内存 → 表 → None，命中后回填 :187）。
- **WebChat 显示消息权威源**：`platform_message_history`（platform_id=webchat）。列表加载经 `ChatService.get_session` 取最近 1000 条（chat_service.py:1414-1448）。
- **群历史权威源**：同表（platform_id=各 IM 平台）。索引 `(platform_id, user_id, id)`（po.py:262-269）。
- **持久化时机**：对话切换/新建/删除即写 preferences（conversation_mgr.py:123、137、158、169 四处入口）；对话历史在 agent 完成后的收尾阶段整体覆写（internal.py:452-539，见请求侧笔记 §6）；WebChat 用户消息先写、bot 消息流式过程中按批写（chat_service.py:1143-1151、:897-1088）。
- **无防抖**：`save_interval = 60`（conversation_mgr.py:25）是死代码（全仓仅定义处出现），不存在周期落盘或防抖合并。

## 3. 创建、切换、归档、删除与恢复

- **新建对话**：`new_conversation`（conversation_mgr.py:92-124）——建行、更新内存缓存、立即写当前对话指针。IM 平台首次 LLM 请求时惰性创建（无当前对话即新建，astr_main_agent.py:261-275）；`/new` 命令（commands/conversation.py:222-252）停掉同 UMO 活跃事件后新建，**仅继承当前对话的 `persona_id`**（:239-244），不继承模型。
- **切换**：`switch_conversation`（conversation_mgr.py:126-137），内存 + preferences 立即写。
- **删除**：`delete_conversation`（:139-158）删除单对话并清当前指针；`delete_conversations_by_user_id`（:160-172）删会话下全部对话，并触发会话删除的级联回调（:45-60，供知识库配置等清理；注册 :30-43）。
- **重置**：`/reset`（conversation.py:124-194）清空当前对话历史（`update_conversation(..., [])` :184-188）并停止活跃事件。
- **WebChat 会话生命周期**：`PlatformSession` 在首次发送消息时惰性补齐（chat_service.py:1118-1135），也可显式创建（:1364-1373）；删除会话是级联清理（:1226-1274）：停止运行 → 删对话与平台历史（含附件文件）→ 删子线程 → 删 UMO 配置路由 → 删会话行；批删带失败项明细（:1293-1330）。
- **恢复**：重启后 `sel_conv_id` 从 preferences 表恢复当前对话指针；对话历史即时落库。WebChat 生成中状态（`ChatRunState`）是内存态，重启丢失，但运行中可由前端经 `/chat/runs/{id}/stream` 以快照恢复（chat_service.py:744-772、:873-895）。

## 4. 编辑、重试、续写、回退与分支语义

- **IM 平台**：消息本身落在平台侧，AstrBot 数据层不提供编辑/删除消息操作；对会话数据的修改只有对话级操作（新建/切换/删除/重置）。
- **WebChat 编辑用户消息**（chat_service.py:1621-1712）：只允许编辑**最新**一条用户消息（:1656-1672，必须是最后 turn 且带 checkpoint）；编辑后分配新 checkpoint、删除该消息之后的所有平台历史与派生线程、把对话历史截断到该 turn 前（:1686-1705），返回 `needs_regenerate`。前端随后自动续写或重生成下一条 bot 消息（Chat.vue:1493-1531）。
- **重生成 bot 消息**（chat_service.py:1721-1825）：只允许最新 checkpoint（:1765-1766）；分配新 checkpoint、从对话历史剔除旧 turn（:1798-1804）、删除旧 bot 显示记录与派生线程（:1805-1815），随后以同一用户消息重新走生成（跳过用户消息重放并打新 checkpoint）。旧版本不保留，不是版本切换式分支。
- **侧线程**：见 1.6，从选定 bot 消息复制历史到新对话，是最接近"分支"的机制。
- 以上均修改持久化对象而非仅内存；`update_message`/`prepare_regenerate_message_payload` 是唯一两条会改写历史与显示消息的入口。

## 5. 列表、分页、搜索与定位

- **对话列表**：`get_filtered_conversations`（conversation_mgr.py:240-277；SQL 层 `sqlite.py:342-448`）支持分页（默认 20/页）、排序与搜索过滤（行为见下列清单）；对话管理页 ConversationPage.vue 使用该接口（含导出、批量删除、消息替换）。
  - 排序为 `created_at DESC, inner_id DESC`，分页默认 20/页；
  - 搜索为 `ilike` 模糊匹配标题、用户、会话 id 与内容（:359-372，含 JSON 转义后的第二遍匹配）；
  - 可过滤消息类型、平台与排除 id/平台（:373-395）；
  - `include_history=False` 时延迟加载 content（:415-416）；
  - 多平台分页强制走全局排序索引（:417-443）。
- **WebChat 会话列表**：`get_sessions`（chat_service.py:1382-1405）按 creator 分页 100 条/页，排除项目会话。
- **群历史**：`PlatformMessageHistoryManager.get`（platform_message_history_mgr.py:108-123）分页读取后反序（时间升序）；`get_group_message_history` 工具支持数量上限（≤50）、`before_id` 分页、不区分大小写的关键字搜索与发送者过滤（message_tools.py:370-393、:418-434）。
- **无跨表全文索引**：搜索均为 SQL 层 ilike 扫描，无独立搜索索引；命中定位由 WebChat 前端在已加载消息中滚动定位（scrollToMessage，Chat.vue:1472-1480），会话数据层无消息级定位 API。

## 6. 缓存、一致性、多窗口与并发写入

SharedPreferences 现在不再在启动时镜像整张 `preferences` 表：内存仅保留本进程写入的覆盖层，未命中异步读取会按键查询 SQLite，避免插件 KV 很大时的全表预加载与内存膨胀；写入仍由 FIFO 队列异步落库（shared_preferences.py:44-57、182-224、267-288）。这改变的是偏好读取的缓存策略，不改变 `sel_conv_id` 等会话指针的持久化归属。

- **读穿缓存**：`session_conversations` 无写回路径，一切切换即写库（见 §2），缓存失效即丢失但库中权威仍在。
- **并发写入**：`update_conversation`（sqlite.py:482-504）按字段增量更新（title/persona_id/content/token_usage 各自非 None 才更新），同对话并发改写是 last-write-wins；`add_message_pair`（conversation_mgr.py:357-390）读-改-写没有锁，但实际调用受请求侧 UMO 级会话锁串行化（见请求侧笔记）。
- **WebChat 生成流**：单消费协程 `_consume_chat_run`（chat_service.py:897-1088）串行消费 back_queue 并落盘，避免同 run 内的并发写；不同 run 独立。
- **多窗口**：`chat_runs`/`chat_runs_by_session` 内存表支持同一会话多 run 并存；SSE 订阅者集合按 revision 广播（:774-871）。多窗口同时编辑同一消息无乐观锁（静态代码未见版本号校验），未运行验证。
- **同文本去重**：RespondStage 对 `send_message_to_user` 已发送的同文本跳过（respond/stage.py:182-204），防止重复回复落盘在平台侧，数据层无重复检测。

## 7. 迁移、导入导出与保留策略

- **schema 迁移**：`astrbot/core/db/migration/` 下按版本/用途拆分脚本：
  - 当前：`migra_3_to_4.py`、`migra_45_to_46.py`、`migra_token_usage.py`、`migra_webchat_session.py`
  - 旧版：`sqlite_v3.py`、`shared_preferences_v3.py`
- **WebChat 会话迁移**（`migra_webchat_session.py:20-118`）：从历史 `platform_message_history`（webchat 平台）中按用户去重生成 `PlatformSession` 行，显示名取自旧 `ConversationV2.title`（:63-71），已存在则跳过、可重复执行；由 `migra_helper` 导入。
- **导入导出**：`core/backup/exporter.py`/`importer.py` 按表全量导出/导入（`platform_sessions` 在主表集合内，backup/constants.py:50），含附件等文件数据。
- **保留策略**：群历史按 `max_messages` 在插入时裁剪（sqlite.py:659-675，仅保留最新 N 条）；`PlatformMessageHistoryManager.delete` 按时间偏移删除（platform_message_history_mgr.py:125-133）；WebChat 会话删除时全量清除（chat_service.py:1226-1274）。群上下文 1000 条内存环形缓冲不持久化（请求侧笔记 §5.3）。

## 8. Agent、模型、知识库与附件绑定

- **Persona（角色）**：对话级绑定——`ConversationV2.persona_id`，`/new` 继承（见 §3）；同时存在**会话级覆盖**：`session_service_config` 规则（存 `preferences` 表，scope=umo）按"会话规则强制 → 对话 persona → provider 默认 persona"的优先级解析（persona_mgr.py:92-127），webchat 无 persona 时回落 `_chatui_default_`（:117-120）。
- **模型**：**不绑定会话/对话**。请求时从 `event.get_extra("selected_model")`（WebChat 前端可选）或 provider 默认模型解析（astr_main_agent.py:1411-1412），无历史快照。
- **Provider/Agent 类型**：会话级规则可覆盖 provider（`provider_perf_chat_completion` 等，session_management_service.py:20-22）；`agent_runner_type` 是配置级。
- **知识库**：会话级配置（UMO 路由/规则），删除会话时经 `register_on_session_deleted` 级联清理（conversation_mgr.py:30-43 注释、:171-172）；实际检索注入发生在请求侧。
- **附件**：消息级绑定（part 内 `attachment_id`，见 1.5），不参与上下文历史快照（历史只存引用/文件名，文件实体独立于 conversations 表）。

## 9. 设计取舍与已确认边界

- **两级模型解耦平台与对话**：会话（UMO）可跨重启稳定寻址，对话（conversation）可自由切换；`sel_conv_id` 指针而非外键引用，对话行与指针独立删除。
- **WebChat 与 IM 双轨持久化**：IM 平台消息留在平台侧（Conversation docstring po.py:561-562 明确"不存储非 LLM 的回复"），WebChat 无平台可依赖，故建 `platform_message_history` 全量存储显示消息。
- **checkpoint 定 turn**：编辑/重生成/线程共用同一套 checkpoint→turn 定位逻辑（chat_service.py:353-378、:445-463），一致性代价是只允许操作"最新" turn。
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
- 数据模型：`astrbot/core/db/po.py`（ConversationV2 :67-109、PlatformMessageHistory :239-269、PlatformSession :302-336、WebChatThread :272-299）
- 持久化：`astrbot/core/db/sqlite.py`（conversations :308-524、platform_message_history :635-756）、`astrbot/core/utils/shared_preferences.py`
- WebChat 会话服务：`astrbot/dashboard/services/chat_service.py`（构建/消费流 :897-1202、编辑/重生成 :1621-1825、线程 :1459-1608、删除级联 :1226-1274）
- 群历史：`astrbot/builtin_stars/astrbot/main.py`（:154-194、:273-323）、`astrbot/core/tools/message_tools.py`（:357-461）、`astrbot/core/platform_message_history_mgr.py`
- 迁移：`astrbot/core/db/migration/migra_webchat_session.py`、`migra_helper.py`
- 命令：`astrbot/builtin_stars/builtin_commands/commands/conversation.py`（/new :222-252、/reset :124-194）
