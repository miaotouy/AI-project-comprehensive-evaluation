# Open WebUI 独特功能调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读通读根 README、后端 `backend/open_webui/routers/` 全部路由、`models/` 表模型、`utils/memory.py`、`utils/automations.py`、`tools/builtin.py`、`socket/main.py`、`socket/utils.py`、前端 `src/routes/` 路由与 `src/lib` API 客户端；未启动服务，未修改被调查仓库
>
> 调查范围：待查清单第二批候选（Notes、Channels、Persistent Memory、Calendar、Automations、语音/视频通话、Artifact KV、模型 Arena/ELO、企业身份、云文件、多节点运行）的入口、状态、执行与持久化主链；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 在"模型/Agent/RAG/工具/代码执行"通用底座之外，提供了一套**服务端为事实源的协作与平台产品面**：Notes、Channels、Persistent Memory、Calendar、Automations、Arena/ELO、企业身份、云文件和多节点运行。本轮确认六项达到 `主链确认`（静态证据），一项 `入口确认`，两项 `入口确认`（企业身份/云文件），一项 `声明不符`（Artifact KV 按当前快照未找到后端入口）。

1. **Channels**：实时协作频道（群组/DM/公告三类）+ 模型可被 @ 参与回复的完整主链（`主链确认`）。
2. **Notes**：独立文档工作区 + 笔记↔隐藏聊天双向绑定 + Yjs 实时协作 + 模型工具写入（`主链确认`）。
3. **Persistent Memory**：用户记忆写入（手动/工具/后台复盘三通道）+ 向量检索 + 每轮系统消息注入（`主链确认`）。
4. **Calendar**：个人/共享日历 + 事件/参与者/RSVP + 模型函数调用面（`主链确认`）。
5. **Automations**：rrule 定时 prompt 调度 + 后台无头执行 + 运行记录回填（`主链确认`）。
6. **模型 Arena/ELO**：反馈驱动的 Elo 排行 + 查询加权（`主链确认`）。
7. **语音/视频通话模式**：CallOverlay 的 STT 输入 + TTS 朗读 + 摄像头取图（`入口确认`，非 WebRTC 对端通话）。
8. **企业身份**：LDAP/OAuth/SCIM 2.0（`入口确认`）。
9. **云文件**：Google Drive / OneDrive picker（`入口确认`）。
10. **多节点运行**：Redis 会话/WebSocket 管理 + 分布式锁 + Yjs 文档跨节点（`入口确认`，机制级）。
11. **Artifact KV**：README 宣称的"built-in key-value storage API for artifacts"按当前快照未在 routers/models/utils/tools 中找到对应执行入口，标 `声明不符`（按当前快照），另见"未验证事项"。

归并已有类目：模型/Agent（Agent 角色笔记）、工具与 MCP（Agent 工具笔记）、代码执行与 Artifact 沙箱（生成式输出与运行时笔记）、RAG/知识库、多模型对话、会话与消息双写（会话管理笔记）、上下文管道（对话请求与上下文笔记）——这些能力不再重写。

## 介绍声明与候选盘点

README 功能清单（约 30 条）密度高，其中待查清单第二批明确的十一项属于"协作与平台产品面"。前端 `src/routes/` 与后端 `routers/` 一一对应，是候选归属的权威表面：`/notes`、`/channels/[id]`、`/calendar`、`/automations`、`/admin/evaluations`（Arena）、`/admin/analytics`（用量分析）、`/admin/users`（身份）、`scim.py`（SCIM 路由）、`utils/google-drive-picker.ts` 与 `onedrive-file-picker.ts`（云文件）、`socket/main.py`（Redis 多节点）。

| 候选（待查清单第二批） | 证据状态 | 结论 |
|---|---|---|
| Notes | `主链确认` | routers/notes.py 全 CRUD + 隐藏聊天绑定 + Yjs 协作（socket utils.py）+ builtin 工具 view_note/write_note/replace_note_content |
| Channels | `主链确认` | routers/channels.py 频道/成员/消息/线程/反应/置顶/Webhook + 模型 @ 参与（model_response_handler） |
| Persistent Memory | `主链确认` | utils/memory.py 注入链 + routers/memories.py 三写入通道 + 向量库 per-user collection |
| Calendar | `主链确认` | routers/calendar.py + 表 calendar/calendar_event/calendar_event_attendee + builtin 日历工具 |
| Automations | `主链确认` | routers/automations.py + utils/automations.py 调度循环 + automation_run 表 |
| 语音/视频通话 | `入口确认` | CallOverlay.svelte（STT/TTS/摄像头），非点对点通话 |
| Artifact KV | `声明不符` | 后端未找到 KV 存储 API 入口（搜索范围见下） |
| 模型 Arena/ELO | `主链确认` | routers/evaluations.py Elo + 排行榜 + 前端 /admin/evaluations |
| 企业身份 | `入口确认` | LDAP（auths.py:471）、OAuth、SCIM 2.0（scim.py，标注 experimental） |
| 云文件 | `入口确认` | Google Drive Picker（gapi）+ OneDrive picker 弹窗流 |
| 多节点运行 | `入口确认` | WEBSOCKET_MANAGER='redis' → socketio.AsyncRedisManager + RedisDict/RedisLock + YdocManager |

## 已确认的独特能力

### 能力一：Channels（实时协作空间 + 模型参与）— `主链确认`

**用户目标**：把"单用户聊天"升级为团队 + AI 共处的实时时间线——群组/私聊/公告三类频道，线程、反应、置顶、文件、Webhook 入站，模型可被 @ 拉入对话。会话与消息管理笔记明确排除了 channel 体系，本能力是新的覆盖。

**入口与触发者**：前端 `/channels/[id]`；用户发消息（`POST /api/v1/channels/{id}/messages/post` → `post_new_message` → `new_message_handler`，`routers/channels.py:1125`）。模型参与由**用户 @ 或回复触发**（`model_response_handler`，`channels.py:951`）——不是模型主动发言。

**事实对象**：`channel` / `channel_member` / `channel_file` / `channel_webhook` 四张表（`models/channels.py`）+ `messages.py` 的频道消息模型（`channel_id`、`parent_id` 线程、`reply_to_id`、`meta.model_id` 标记模型消息）。

**完整主链**：用户发消息 → 校验成员/权限（group/dm 需成员，公告频道走 access grants）→ `Messages.insert_new_message` 落库 → `sio.emit('events:channel', to='channel:{id}')` 实时广播（回复同时给父消息发 `message:reply`）→ 若消息 @ 了模型或回复了模型消息：`model_response_handler` 解析提及 → 为每个被 @ 模型创建占位消息（`meta.model_id`）→ 组装线程历史（含图片 Base64 与文件列表）→ 以 `chat_id='channel:{channel.id}'`、`session_id='channel:{channel.id}'` 调用完整 `CHAT_COMPLETION_HANDLER`（工具、Filters、RAG 全链路，流式经 socket 的 channel emitter 回推）→ 模型回复以模型身份落库。置顶/反应/线程/Webhook（`{token}` 匿名发布）各有独立端点。

**持续性**：全部状态在数据库（SQLite/PostgreSQL），多节点经 Redis socket 广播一致；`channel_member.last_read_at`/`is_active` 维护已读与在线。

**安全与资源边界**：成员制 + access grants + 频道级读写权限；Webhook 用 token 鉴权；模型回复经完整权限管线（`get_filtered_models`）。

**独特性判断**：Chat 类目只覆盖单用户聊天；Channels 是"Agent 社会 + 协同工作区"标签的完整服务端实现，且模型参与走真实聊天管线而非简单提示词拼装。

**证据强度**：路由源码为静态事实；真实 socket 推送、模型流式参与未运行验证。

### 能力二：Notes（独立文档工作区）— `主链确认`

**用户目标**：会话之外的内容工作区——富文本笔记、AI 改写选中文本、笔记↔聊天双向绑定（`GET /notes/{id}/chat` 建立隐藏聊天让模型直接编辑笔记）、实时多人协作。

**入口与触发者**：前端 `/notes`、`/notes/[id]`；用户创建/编辑为主，模型通过 `view_note` / `write_note` / `replace_note_content` 内建工具（`tools/builtin.py:1087/1149/1198`）写入。

**事实对象**：`note` 表（`models/notes.py`，含 `data.content.md` 富文本结构）+ `pinned_note` 表 + `access_grant`（resource_type='note'）。

**完整主链**：创建 → `Notes.insert_new_note` → 编辑经 REST 更新（`update_note_by_id`）或 Yjs 协作（socket `document:save` 事件，`socket/main.py:679-698` 校验写权限后落库）→ 每页列表/搜索（`/notes/search`，支持组过滤与查询）→ "与 AI 对话"入口 `get_note_chat_by_id`：按 `note_id` 查找/创建 `internal_meta={internal: True, type: 'note'}` 的隐藏聊天，system prompt 固定为"用 view_note 查看、replace_note_content 修改"的契约（`notes.py:340-401`）→ 模型经工具直接改笔记 → socket `events:note` 实时回推。聊天附加笔记注入：聊天 `meta.note_id` 在 `process_chat_payload`（`middleware.py:2621`）读取并注入上下文。

**持续性**：笔记、置顶、权限全部在 DB；多节点经 Redis 的 `YdocManager`（`socket/utils.py`）同步 Yjs 文档更新（`ydoc:{doc}:updates` 列表 + 压缩）。

**人机与多 Agent 关系**：用户可检查/撤销模型修改；模型编辑经工具权限（`_has_write_access_to_note`，`builtin.py:70`）与聊天权限双闸。

**独特性判断**：与"协同工作区"聚类（LobeHub Pages、VCP 群文件）对照，Notes 的服务端事实源 + 隐藏聊天 + Yjs 协作是完整闭环。

**证据强度**：路由、模型、socket 三处源码为静态事实；Yjs 实时协作与并发冲突未运行验证。

### 能力三：Persistent Memory（跨会话记忆）— `主链确认`

**用户目标**：AI 跨会话记住用户事实——用户在 A 聊天提到的偏好，B 聊天自动带入，且可手动增删、按路径组织、由模型后台复盘。

**入口与触发者**：三条写入通道 + 一条注入链。手动：`POST /memories/add`；工具：`add_memory/update_memory/replace_memory_content/delete_memory/list_memories/search_memories/list_memory_paths/read_memory_path`（`builtin.py:663-988`，受 `MUTATING_MEMORY_TOOLS` 治理）；后台：`review_memory_after_turn`（`utils/memory.py:408`）在每轮对话结束后按 `memories.review_interval_turns`（默认 10 轮）触发异步复盘——用独立 LLM 请求（`_generate_memory_operations`，输出 JSON 操作数组）对最近 16 条消息决定 add/replace/move/remove，经 `source='background_review'` 落库。注入：每次聊天请求前 `add_memory_context`（`memory.py:290`）把最近 7 条用户消息拼为查询 → 向量检索 `user-memory-{user.id}` 集合（k=8，按 `rag.relevance_threshold` 过滤）→ 与"user 类型全量 + 路径邻域"合并为 `[User Memory]/[Memory Neighborhood]/[Relevant Context]` 三段，写入 system 消息（`MEMORY_CONTEXT_OPEN/CLOSE` 标记包裹，旧段先移除），受 `memories.user_char_limit`/`context_char_limit` 截断。

**事实对象**：`memory` 表（content/type: user|context/path/meta）+ 每用户向量集合 `user-memory-{user.id}`。

**持续性**：DB + 向量库双写；`/memories/reset` 用 `asyncio.gather` 全量重嵌入；删除同步清向量。

**主动性与取消**：后台复盘是 `asyncio.create_task`（`memory.py:445`），失败仅记 debug 日志不阻断聊天；开关 `memories.background_review.enable`、`memories.enable` 与用户权限 `features.memories`。

**独特性判断**：与"记忆演化"聚类（Hermes 用户建模、VCPTagMemo）对照，Open WebUI 的记忆是"用户事实 + 路径组织 + 向量检索 + 后台复盘"的服务端闭环，且模型经工具可直接写入——人类工具面与记忆写入同构。

**证据强度**：全部写入/注入/复盘链源码为静态事实；真实嵌入模型调用与复盘效果未运行验证。

### 能力四：Calendar（个人/共享日历 + 模型调度面）— `主链确认`

**用户目标**：内置个人与共享日历（月/周/日视图、重复事件、颜色、参与者、提醒），且模型可通过函数调用直接查询/创建/更新日程（"帮我安排周五 3 点的会"）。

**入口与触发者**：用户经 `/calendar` UI；模型经内建工具 `search_calendar_events` / `create_calendar_event` / `update_calendar_event`（`builtin.py:3965/4058/4185`，函数调用由 Agent 工具笔记的调用循环触发）。

**事实对象**：`calendar` / `calendar_event` / `calendar_event_attendee` 三张表（`models/calendar.py`），事件含 `rrule`（重复规则）、`color`、`meta.alert_minutes` 提醒、RSVP 状态。

**完整主链**：用户/模型创建事件 → `CalendarEvents.insert_new_event`（校验 calendar access grants，默认日历兜底）→ UI 按范围查询 `get_events_by_range` / `search_events` → 提醒由 `scheduler_worker_loop` 的 `_check_calendar_alerts` 轮询（`utils/automations.py:249-254`）→ 通知经 `notifications` 系统推送。模型侧：`create_calendar_event` 用 `reminder_minutes` 参数映射 `alert_minutes`，无默认日历时返回错误 JSON 让模型转告用户。

**持续性**：全量 DB；时区由 `tz` 参数（用户 timezone）归一。

**独特性判断**：日历本身常见，但"模型函数调用直接管理日历 + 调度器发提醒"把日程做成 Agent 可写对象，属"人类工具面/主动 Agent"交集。

**证据强度**：路由、表模型、内置工具为静态事实；提醒推送与重复事件展开未运行验证。

### 能力五：Automations（定时 prompt 自动化）— `主链确认`

**用户目标**：把 prompt 挂到 rrule 重复日程上，后台无头运行并产出真实聊天——"每天早上 9 点生成一份当日计划"且结果可见、可回链。

**入口与触发者**：前端 `/automations`；用户创建（prompt + model + rrule + 文件夹）；执行由**后台调度器**触发（非用户交互）。

**事实对象**：`automation` + `automation_run` 两张表（`models/automations.py`），rrule 存 `automation.data['rrule']`。

**完整主链**：创建时校验限额（`automations.max_count`、`min_interval`，admin 豁免）→ `scheduler_worker_loop`（`utils/automations.py:203`，每实例运行、`SCHEDULER_POLL_INTERVAL` 默认 10s + 随机抖动防多实例抢跑）→ `Automations.claim_due(now_ns, limit=10)` 原子认领到期任务 → `execute_automation`（`automations.py:412`）：复验所有者权限（被降权/停用即失败记录）→ `prompt_template` 渲染 → 创建真实聊天（`meta.automation_id`，用户/助手消息占位）→ `sio.emit` 通知前端刷新列表 → 解析模型工具/特性/Filters（`_resolve_model_tool_ids` 等，与前端 Chat.svelte 同源逻辑）→ 带所有者 token 的 `_build_request` 无头调用完整 chat completion 管线 → 运行结果写 `automation_run`（含 chat 回链）→ 事件 `AUTOMATION_RUN_*` 发布。运行记录出现在日历（runs 与 Calendar 共用时间轴）与 `/automations/{id}/runs`。

**主动性与取消**：完全后台主动；`toggle` 停用、`delete` 删除、`/{id}/run` 手动立即执行；限额系统防滥用。

**独特性判断**："调度 + 无头执行 + 真实聊天产物 + 运行历史"四件套同时存在且结果归属自动化所有者，是"主动 Agent"聚类（对照 VCP FlowLock、Hermes cron）中用户可管理度最高的实现之一。

**证据强度**：调度循环与执行函数源码为静态事实；真实定时触发与多实例并发认领未运行验证。

### 能力六：模型 Arena / ELO 评估 — `主链确认`

**用户目标**：让用户对模型回复做成对/打分反馈，沉淀为可查询的模型排行榜（Arena + ELO），并按话题语义加权。

**入口与触发者**：用户在前端对回复评分（feedback，`rating: 1/-1` + `sibling_model_ids` + `tags`）；admin 在 `/admin/evaluations` 看榜。

**事实对象**：`feedback` 表（`models/feedbacks.py`，`LeaderboardFeedbackData` 只取 id+data 供排行计算）。

**完整主链**：用户评分落 `feedback` → `GET /evaluations/leaderboard`（`routers/evaluations.py:216`）：取全部反馈 → `_calculate_elo`（初始 1000、K=32、expected 公式；可选 `similarities` 权重）→ `_get_top_tags` 聚合话题标签 → 按 rating 降序返回。查询加权：带 query 时用 sentence-transformers 对标签做余弦相似度，相似度作 Elo 权重（`_compute_similarities`）。配置 `evaluation.arena.enable`/`evaluation.arena.models` 控制参与 Arena 的模型集合；`/leaderboard/{model_id}/history` 提供单模型历史。

**持续性**：全部来自 `feedback` 表，排行榜为实时计算（无缓存表）；仅 admin 可见。

**独特性判断**：多数项目只有用量统计；Open WebUI 把用户反馈变成 Elo 排行榜且支持话题加权检索，是"模型评估产品面"的完整实现（待查清单聚类"模型 Arena/ELO"唯一实例）。

**证据强度**：路由与 Elo 实现源码为静态事实；embedding 加权与排行榜 UI 未运行验证。

### 能力七：语音/视频通话模式（CallOverlay）— `入口确认`

**用户目标**：免提语音交互——按住说话转文字进聊天、模型回复语音朗读，摄像头可抓图作为消息附件。

**入口**：`src/lib/components/chat/MessageInput/CallOverlay.svelte`（输入栏通话浮层）。行为链（静态确认）：`getUserMedia` 采集麦克风 → `MediaRecorder` 录制 → `transcribeAudio` API（后端 `routers/audio.py`，多 STT 引擎：本地 Whisper/OpenAI/Deepgram/Azure）→ 转录文本进聊天；模型回复经 TTS（`synthesizeOpenAISpeech`/Transformers/Kokoro WebAPI 引擎，带音频缓存）朗读；`getUserMedia({video})` 摄像头画面 → canvas 截帧作为图片内容。**注意**：README 称"voice/video calls"，实现是单用户免提模式（STT→聊天→TTS 朗读 + 摄像头取图），**不是** WebRTC 点对点通话，也无通话信令服务。

**独特性判断**：把语音闭环做进聊天输入层，与终端/桌面伴生应用的语音能力有交集，但属于 WebUI 本体。

**证据强度**：组件源码为静态事实；浏览器媒体权限流程与 STT/TTS 引擎接入未运行验证。

### 能力八：企业身份（LDAP/OAuth/SCIM）— `入口确认`

- **LDAP**：`POST /auths/ldap`（`routers/auths.py:471`）完整登录链（DN 转义、组 CN 提取用于角色映射、服务器配置在 `/auths/admin/config/ldap`）。
- **OAuth**：`/auths/admin/config/oauth` 管理多 provider；`token/exchange` 端点支持企业 OAuth 会话；`oauth_sessions` 表记录 provider 会话。
- **SCIM 2.0**：`routers/scim.py` 实现 Users/Groups 的 SCIM 端点（`urn:ietf:params:scim:schemas:core:2.0:User/Group`、ListResponse/Error schema），文件头自述 **experimental**（可能不完全合规）；`SCIM_AUTH_PROVIDER` 控制认证来源。

**独特性判断**：作为自托管平台的自带身份层，LDAP+OAuth+SCIM 三件套齐备（SCIM 标实验性）。

**证据强度**：路由源码为静态事实；真实目录接入与 SCIM 合规性未验证。

### 能力九：云文件集成（Google Drive / OneDrive）— `入口确认`

前端 `utils/google-drive-picker.ts`（gapi picker，OAuth token 弹窗）与 `utils/onedrive-file-picker.ts`（OneDrive picker 弹窗流，`onedrive.live.com/picker`，access_token 表单注入）选择云端文件，把选中文件导入文件库供聊天/RAG 使用。后端侧未见独立"云文件代理"路由——文件导入后进入既有 `files` 体系（知识库/聊天文件面已由 RAG 与代码执行笔记覆盖）。

**独特性判断**：企业文档源接入的入口面属于平台独有，但主链后半段归并现有文件体系。

**证据强度**：前端 picker 源码为静态事实；真实 OAuth 流程与文件回流未运行验证。

### 能力十：多节点运行（Redis 支撑）— `入口确认`

`WEBSOCKET_MANAGER='redis'` 时：`socketio.AsyncRedisManager` 做跨节点事件广播（`socket/main.py:67-82`）；`socket/utils.py` 提供 `RedisDict`（会话状态哈希）、`RedisLock`（SET NX/EX 分布式锁 + 续期/释放 Lua 脚本）、`YdocManager`（Yjs 文档更新列表 + 压缩 + 用户集合，跨节点协作文档）。配合 DB 层（SQLite 加密/PostgreSQL）、会话/任务在 Redis 中取消（`stopTask` 经 Redis pubsub，对话请求与上下文笔记已确认）与自动化认领（`claim_due` 的原子更新），构成水平扩展基础。**注意**：这是平台运行机制，不是用户可见产品特性，按调查指南"工程机制单独标注"处理，不进入特色贡献计数。

**证据强度**：socket 模块源码为静态事实；多节点真实部署未验证。

## 已归并到现有类目的能力

| 能力 | 归并去向 |
|---|---|
| 模型/Agent（workspace models、persona、知识库绑定） | [`../Agent角色/Open-WebUI-Agent角色配置调查笔记.md`](../Agent角色/Open-WebUI-Agent角色配置调查笔记.md) |
| 工具/Filter/Pipeline/MCP/子 Agent | [`../Agent工具/Open-WebUI-Agent工具调查笔记.md`](../Agent工具/Open-WebUI-Agent工具调查笔记.md) |
| 代码执行（Pyodide/Jupyter）与 Artifact 沙箱 | [`../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md`](../生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md) |
| RAG/知识库/检索 | 现有 RAG 相关笔记（检索/知识库类目） |
| 多模型对话、MoA、消息 fan-out | [`../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md`](../对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md) |
| 会话/消息双写、channel 之外的消息模型 | [`../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md`](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md) |
| 富文本渲染、Markdown、Citations | [`../消息渲染器/Open-WebUI-消息渲染器调查笔记.md`](../消息渲染器/Open-WebUI-消息渲染器调查笔记.md) |
| LLM 渠道与 Provider 适配 | [`../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md`](../LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md) |

## 声明不符、外部依赖与暂缓项

- **Artifact KV（`声明不符`，按当前快照）**：README 宣称"Persistent Artifact Storage: Built-in key-value storage API for artifacts, enabling journals, trackers, leaderboards, and collaborative tools with personal and shared data scopes"。本次搜索范围：`backend/open_webui/routers/` 全部文件、`models/`、`utils/`、`tools/`、`socket/`、`internal/`，关键词 `artifact`/`kv`/`leaderboard`/`tracker`/`journal`/`/api/v1/data`，前端 `src/lib` 的 `artifact`/`kv` 命中仅为 Artifact 渲染 store（`stores/index.ts:133` 的 `artifactCode`）与代码块提取。**未找到独立 KV 存储 API 入口**；接近语义的是 channel 消息的 `data` 字段、calendar/note 的 `data` 字段与聊天任务清单（`create_tasks`/`update_task` 存 `Chat.tasks`，`builtin.py:3421`，即 README "Live Workflow & Message Flow" 的实现）。结论：该条 README 声明在当前可执行路径中找不到对应产品契约，可能指未来功能或文档愿景，不能据此计数。
- **语音/视频通话**：README 用语（"voice/video calls"）比实现（单用户免持 STT/TTS + 摄像头取图，无 WebRTC 对端）更宽，已按实现记录。
- **SCIM**：文件头自述 experimental 且"may not fully comply with SCIM 2.0"，按 `入口确认` 记录并保留差异说明。
- **伴生仓库**（不属于本仓库主链）：Open WebUI Computer、Open Terminal/Terminals、oikb、桌面 App（README 生态节），本轮不调查，标 `暂缓`。本仓库内的 `/terminals` 前端与 `routers/terminals.py` 仅代理外部 terminal server，未走主链。
- **Analytics/用量**：`routers/analytics.py` 存在（models/users/messages/tokens 统计），属于管理面板常规能力，不在待查清单，未走主链。

## 对特色贡献统计的影响

- 主贡献候选（`主链确认`，静态证据）：Channels、Notes、Persistent Memory、Calendar、Automations、模型 Arena/ELO——6 个能力族。
- 辅助贡献/`入口确认`：语音通话模式、企业身份（LDAP/OAuth/SCIM）、云文件入口。
- 多节点运行按"工程/可靠性机制"单独标注，不进用户可见特色计数。
- 同一工作流合并：Calendar 与 Automations 共享 `scheduler_worker_loop` 调度器与时间轴，但用户目标不同（日程管理 vs prompt 自动化），分开计数；Automations 的"运行记录上日历"不重复计数。
- Artifact KV 不计入；README 宣称而代码未接线的部分保留差异说明，不给特色加分。

## 未验证事项

- 全部能力均未运行验证（未启动 open-webui 服务）：socket 实时推送、模型在频道/笔记中的流式参与、记忆后台复盘的真实模型调用、自动化定时触发与多实例并发认领、ELO 加权查询、STT/TTS 引擎接入、LDAP/SCIM 真实接入、云文件 OAuth 流、Redis 多节点部署。
- Artifact KV 的"未找到"结论基于当前快照的静态搜索；若用户基于新版文档/发行版宣称存在，需在新快照复查。
- Calendar 重复事件（rrule）的展开与提醒推送细节未逐行核对（`get_events_by_range` 与 `_check_calendar_alerts` 行为以代码为准）。
- Notes 的 Yjs 协作在 SQLite/PostgreSQL 双后端下的并发正确性未验证。
- 频道模型消息在"会话与消息管理"双写体系中的归属（channel 消息不写 `chat.chat.history`）未与现有笔记交叉核对完整。

## 关键源码索引

- `backend/open_webui/routers/channels.py`（1125 new_message_handler、951 model_response_handler、916 send_notification）
- `backend/open_webui/routers/notes.py`（65 get_notes、308/467 note↔chat、536 update、616 access）
- `backend/open_webui/models/channels.py`（channel/channel_member/channel_file/channel_webhook）、`models/notes.py`、`models/calendar.py`（calendar/calendar_event/calendar_event_attendee）、`models/automations.py`（automation/automation_run、282 claim_due）、`models/memories.py`、`models/feedbacks.py`
- `backend/open_webui/utils/memory.py`（290 add_memory_context、408 review_memory_after_turn、520 _generate_memory_operations）
- `backend/open_webui/utils/automations.py`（203 scheduler_worker_loop、412 execute_automation、267 _build_request）
- `backend/open_webui/routers/memories.py`（127 add、274 query、391 reset）、`routers/evaluations.py`（81 _calculate_elo、216 leaderboard）、`routers/scim.py`、`routers/auths.py:471`（ldap_auth）、`routers/audio.py`（STT/TTS 引擎族）
- `backend/open_webui/tools/builtin.py`（663-988 记忆工具、990-1365 笔记工具、3965-4226 日历工具、3421/3471 任务清单、3537 automation 工具）
- `backend/open_webui/socket/main.py`（67-82 Redis manager、465-698 note Yjs 事件）、`socket/utils.py`（RedisDict/RedisLock/YdocManager）
- `src/routes/(app)/notes/`、`(app)/channels/[id]`、`(app)/calendar`、`(app)/automations/`、`(app)/admin/evaluations/`
- `src/lib/components/chat/MessageInput/CallOverlay.svelte`、`src/lib/utils/google-drive-picker.ts`、`onedrive-file-picker.ts`、`src/lib/apis/{notes,channels,calendar,automations,evaluations,memories,audio}/index.ts`
