# Open WebUI 独特功能调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：只读通读根 README、后端 `backend/open_webui/routers/` 全部路由、`models/` 表模型、`utils/memory.py`、`utils/automations.py`、`tools/builtin.py`、`socket/main.py`、`socket/utils.py`、前端 `src/routes/` 路由与 `src/lib` API 客户端；未启动服务，未修改被调查仓库
>
> 调查范围：待查清单第二批候选（Notes、Channels、Persistent Memory、Calendar、Automations、语音/视频通话、Artifact KV、模型 Arena/ELO、企业身份、云文件、多节点运行）的入口、状态、执行与持久化主链；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 在"模型/Agent/RAG/工具/代码执行"通用底座之外，提供了一套**服务端为事实源的协作与平台产品面**：Notes、Channels、Persistent Memory、Calendar、Automations、Arena/ELO、外部应用平台、多标签工作台、人工提问、企业身份、云文件和多节点运行。本轮确认九项达到 `主链确认`（静态证据），一项 `入口确认`（语音/视频通话），两项 `入口确认`（企业身份/云文件），一项 `声明不符`（Artifact KV 按当前快照未找到后端入口）。

14 项候选的形态与证据状态见下，未单独标注者均为 `主链确认`。

1. **Channels**：群组、DM 与公告三类实时协作频道，模型可被 @ 拉入并参与回复。
2. **Notes**：会话之外的独立文档工作区，笔记可与隐藏聊天双向绑定，支持 Yjs 实时协作，模型也能通过工具写入。
3. **Persistent Memory**：用户记忆有手动、工具与后台复盘三条写入通道，检索走向量库，并在每轮聊天请求前注入系统消息。
4. **Calendar**：个人与共享日历，覆盖事件、参与者与 RSVP，模型可通过函数调用直接查询、创建与更新日程。
5. **Automations**：按 rrule 定时触发 prompt，在后台无头执行，运行记录回填后可查。
6. **模型 Arena/ELO**：以用户反馈驱动 Elo 排行，并支持按查询话题加权。
7. **外部应用平台（Apps）**：外部应用以 manifest 注册、被邀请进频道，经签名上下文与 scope 校验参与会话，平台同时向其推送消息事件。
8. **多标签工作台（ChatTabs）**：在聊天区内统一承载会话、文件、终端、浏览器、桌面、Artifact、预览、语音、评论与侧聊等十一类标签。
9. **人工提问（ask_user）**：内置工具让模型在单轮内向用户提出 1-3 个结构化问题，前端卡片作答后继续同一轮推理。
10. **语音/视频通话模式**：CallOverlay 承担 STT 输入、TTS 朗读与摄像头取图，属单用户免提模式，无 WebRTC 点对点通话（`入口确认`）。
11. **企业身份**：LDAP、OAuth 与 SCIM 2.0 三条身份接入路径（`入口确认`）。
12. **云文件**：Google Drive 与 OneDrive 文件选择器（`入口确认`）。
13. **多节点运行**：Redis 承担会话与 WebSocket 管理，另配分布式锁与 Yjs 文档跨节点同步（`入口确认`，机制级）。
14. **Artifact KV**：README 宣称的"built-in key-value storage API for artifacts"按当前快照未在后端路由、表模型、工具与 socket 等目录中找到对应执行入口，标 `声明不符`（按当前快照），另见"未验证事项"。

归并已有类目：模型/Agent（Agent 角色笔记）、工具与 MCP/技能（Agent 工具笔记）、代码执行与 Artifact 沙箱（生成式输出与运行时笔记）、RAG/知识库、多模型对话、会话与消息双写（会话管理笔记）、上下文管道（对话请求与上下文笔记）——这些能力不再重写。

## 介绍声明与候选盘点

README 的功能清单约 30 条，密度很高；待查清单第二批明确点名的十一项集中在协作与平台产品面。前端路由与后端 routers 一一对应，是判断候选归属的权威表面，关键路径按能力分为四组：

| 入口 | 覆盖面 |
|---|---|
| `/notes`、`/channels/[id]`、`/calendar`、`/automations` | 协作功能页 |
| `/admin/evaluations`、`/admin/analytics`、`/admin/users`、`scim.py` | 模型评估、用量分析、身份管理与 SCIM 路由 |
| `utils/google-drive-picker.ts`、`onedrive-file-picker.ts` | 云文件选择 |
| `socket/main.py` | Redis 多节点 |

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
| 外部应用平台（Apps） | `主链确认` | routers/apps.py manifest 预览/创建/连接/interactions + models/apps.py app 表 + 频道成员与消息事件 |
| 多标签工作台（ChatTabs） | `主链确认` | src/lib/components/chat/ChatTabs/ 与 tabs.ts 的 11 类标签 + terminal 客户端 |
| 人工提问（ask_user） | `主链确认` | builtin ask_user 工具 + middleware 暂存 + AskUserCard 作答回流 |
| 企业身份 | `入口确认` | LDAP（auths.py）、OAuth、SCIM 2.0（scim.py，标注 experimental） |
| 云文件 | `入口确认` | Google Drive Picker（gapi）+ OneDrive picker 弹窗流 |
| 多节点运行 | `入口确认` | WEBSOCKET_MANAGER='redis' → socketio.AsyncRedisManager + RedisDict/RedisLock + YdocManager |

## 已确认的独特能力

### 能力一：Channels（实时协作空间 + 模型参与）— `主链确认`

**用户目标**：把"单用户聊天"升级为团队 + AI 共处的实时时间线——群组/私聊/公告三类频道，线程、反应、置顶、文件、Webhook 入站，模型可被 @ 拉入对话。会话与消息管理笔记明确排除了 channel 体系，本能力是新的覆盖。

**入口与触发者**：前端 `/channels/[id]`；用户发消息走后端消息入口（`POST /api/v1/channels/{id}/messages/post`，`routers/channels.py:1125`）。模型参与由**用户 @ 或回复触发**（`model_response_handler`，`channels.py:951`）——不是模型主动发言。

**事实对象**：频道体系由四张表承载（`models/channels.py`）：`channel` 存频道本身，`channel_member` 存成员关系，`channel_file` 存频道附件，`channel_webhook` 保存入站 Webhook。频道消息模型用 parent_id 表达线程、reply_to_id 表达回复，并用 meta 里的 model_id 标记模型消息。

**完整主链**（用户消息与模型参与分两段）：
- **用户消息**：消息入口先校验成员与权限——群组与私聊频道要求成员身份，公告频道走 access grants——再经 `Messages.insert_new_message` 落库，随后向频道实时广播；若这条消息是回复，还会给父消息补发一条回复通知。置顶、反应、线程与 Webhook 入站各有独立端点，其中 Webhook 用 `{token}` 做匿名发布鉴权。
- **模型参与**：用户 @ 了模型或回复了模型消息时，`model_response_handler` 先解析提及对象，为每个被 @ 的模型创建占位消息，用 meta 里的 model_id 标记该消息由模型发出；接着组装线程历史（含图片 Base64 与文件列表），以该频道的会话标识调用完整的 chat completion 管线，工具、Filters 与 RAG 都在链上，流式结果经 socket 的 channel emitter 回推，最终模型回复以模型身份落库。同一个 emitter 也处理 files 事件：文件被登记进 channel_file，回填所属消息 id 并合并进消息 data.files，模型在频道里生成的图片因此作为频道附件落库（`socket/main.py:1023-1049`；`tools/builtin.py:391-398`）。

**持续性**：全部状态在数据库（SQLite/PostgreSQL），多节点经 Redis socket 广播一致；`channel_member.last_read_at`/`is_active` 维护已读与在线。

**安全与资源边界**：成员制 + access grants + 频道级读写权限；Webhook 用 token 鉴权；模型回复经完整权限管线（`get_filtered_models`）。

**加密频道**：频道可切换为端到端加密模式，对应独立页面 `/channels/[id]/encrypted`，成员进入前先完成密钥协商——频道菜单调用前端加密客户端的 enter 与 canUseEncryption 两个函数（`src/lib/components/channel/ChannelMenu.svelte`、`src/lib/encryption/client.ts`）。加密算法由 Rust 编译为 wasm 随前端分发，源码在 `crypto/encryption/`，产物在 `src/lib/encryption/vendor/`；服务端只做密文包中继，`socket/encryption.py` 按频道维护协商状态与在线绑定，源码注释明确不保存消息载荷。服务端可见的信息因此限于成员关系、在线状态与密文包，明文只在成员浏览器内。

**独特性判断**：Chat 类目只覆盖单用户聊天；Channels 是"Agent 社会 + 协同工作区"标签的完整服务端实现，且模型参与走真实聊天管线而非简单提示词拼装。

**证据强度**：路由源码为静态事实；真实 socket 推送、模型流式参与未运行验证。

### 能力二：Notes（独立文档工作区）— `主链确认`

**用户目标**：会话之外的内容工作区——富文本笔记、AI 改写选中文本、笔记↔聊天双向绑定（`GET /notes/{id}/chat` 建立隐藏聊天让模型直接编辑笔记）、实时多人协作。

**入口与触发者**：前端 `/notes`、`/notes/[id]`；用户创建/编辑为主，模型通过查看、写入与替换内容三个内建工具（`tools/builtin.py:1087-1198`）写入。

**事实对象**：`note` 表（`models/notes.py`，含 `data.content.md` 富文本结构）+ `pinned_note` 表（置顶）+ `access_grant`（resource_type='note' 的访问授权）。

**完整主链**（编辑与 AI 对话分两段）：
- **创建与编辑**：新建笔记落 `Notes.insert_new_note`，之后的编辑有两条路：REST 更新走 `update_note_by_id`，多人协作走 Yjs 的 document:save socket 事件，服务端先校验写权限再落库，变更随即经 socket 回推。列表与搜索由 `/notes/search` 提供，支持按组过滤与查询（`socket/main.py:679-698`）。
- **与 AI 对话**：`get_note_chat_by_id` 为笔记查找或创建一条隐藏聊天，该聊天以 internal_meta 里的 internal 与 type 字段标识为内部 note 类型；system prompt 固定约定先查看、再整体替换内容的工具契约，模型据此经工具直接改笔记（`notes.py:340-401`）。聊天侧的笔记注入由 `process_chat_payload` 完成：读取聊天 meta 里的 note_id 后注入上下文（`middleware.py:2621`）。

**持续性**：笔记、置顶、权限全部在 DB；多节点经 Redis 的 `YdocManager`（`socket/utils.py`）同步 Yjs 文档更新（`ydoc:{doc}:updates` 列表 + 压缩）。

**人机与多 Agent 关系**：用户可检查/撤销模型修改；模型编辑经工具权限（`_has_write_access_to_note`，`builtin.py:70`）与聊天权限双闸。

**独特性判断**：与"协同工作区"聚类（LobeHub Pages、VCP 群文件）对照，Notes 的服务端事实源 + 隐藏聊天 + Yjs 协作是完整闭环。

**证据强度**：路由、模型、socket 三处源码为静态事实；Yjs 实时协作与并发冲突未运行验证。

### 能力三：Persistent Memory（跨会话记忆）— `主链确认`

**用户目标**：AI 跨会话记住用户事实——用户在 A 聊天提到的偏好，B 聊天自动带入，且可手动增删、按路径组织、由模型后台复盘。

**入口与触发者**：记忆有三条写入通道（用户手动、模型工具、后台复盘）和一条注入链，分别由用户请求、模型工具调用与后台任务触发。

- **手动**：用户直接提交 `POST /memories/add`。
- **模型工具**：模型可调用八个记忆工具，覆盖新增、更新、整体替换、删除、列表、检索与路径浏览，写操作统一受 `MUTATING_MEMORY_TOOLS` 名单约束（`tools/builtin.py:663-988`）。
- **后台复盘**：每轮对话结束后，`review_memory_after_turn` 先检查是否到达 `memories.review_interval_turns`（默认 10 轮）设定的间隔，到达就发起一次异步复盘；复盘用独立 LLM 请求生成 JSON 操作数组（见 `_generate_memory_operations`），读取最近 16 条消息后决定新增、替换、移动或删除，并以 source 为 background_review 落库（`utils/memory.py:408`）。
- **注入**：每次聊天请求前，`add_memory_context` 先取最近 7 条用户消息拼成查询，在 `user-memory-{user.id}` 向量集合中检索（k=8，按 `rag.relevance_threshold` 过滤），再与"user 类型全量 + 路径邻域"合并成 [User Memory]、[Memory Neighborhood]、[Relevant Context] 三段写入 system 消息；三段由 MEMORY_CONTEXT_OPEN/CLOSE 标记包裹，写入前先移除旧段，最终按长度配置截断（`utils/memory.py:290`）。

**事实对象**：`memory` 表（content/type: user|context/path/meta）+ 每用户向量集合 `user-memory-{user.id}`。

**持续性**：DB + 向量库双写；`/memories/reset` 用 `asyncio.gather` 全量重嵌入；删除同步清向量。

**主动性与取消**：后台复盘是 `asyncio.create_task`（`memory.py:445`），失败仅记 debug 日志不阻断聊天；开关 `memories.background_review.enable`、`memories.enable` 与用户权限 `features.memories`。

**独特性判断**：与"记忆演化"聚类（Hermes 用户建模、VCPTagMemo）对照，Open WebUI 的记忆是"用户事实 + 路径组织 + 向量检索 + 后台复盘"的服务端闭环，且模型经工具可直接写入——人类工具面与记忆写入同构。

**证据强度**：全部写入/注入/复盘链源码为静态事实；真实嵌入模型调用与复盘效果未运行验证。

### 能力四：Calendar（个人/共享日历 + 模型调度面）— `主链确认`

**用户目标**：内置个人与共享日历（月/周/日视图、重复事件、颜色、参与者、提醒），且模型可通过函数调用直接查询/创建/更新日程（"帮我安排周五 3 点的会"）。

**入口与触发者**：用户经 `/calendar` UI；模型经内建工具 `search_calendar_events` / `create_calendar_event` / `update_calendar_event`（`builtin.py:3965-4226`，函数调用由 Agent 工具笔记的调用循环触发）。

**事实对象**：日历数据落在三张表上：`calendar` 存日历，`calendar_event` 存事件，`calendar_event_attendee` 存参与者。事件记录带重复规则（rrule）、颜色、提醒分钟数（meta.alert_minutes）与 RSVP 状态；创建与更新表单会拒绝短于一天的重复频率（下限 24 小时，超频返回 `CALENDAR_RRULE_TOO_FREQUENT`，`models/calendar.py:30,198-245`）。

**完整主链**：用户/模型创建事件 → `CalendarEvents.insert_new_event`（校验日历访问授权，默认日历兜底）→ UI 按范围查询与搜索 → 提醒由调度器循环的 `_check_calendar_alerts` 轮询（`utils/automations.py:542`）→ 经通知系统推送。模型侧：`create_calendar_event` 用 `reminder_minutes` 参数映射 `alert_minutes`，无默认日历时返回错误 JSON 让模型转告用户。

**持续性**：全量 DB；时区由 `tz` 参数（用户 timezone）归一。

**独特性判断**：日历本身常见，但"模型函数调用直接管理日历 + 调度器发提醒"把日程做成 Agent 可写对象，属"人类工具面/主动 Agent"交集。

**证据强度**：路由、表模型、内置工具为静态事实；提醒推送与重复事件展开未运行验证。

### 能力五：Automations（定时 prompt 自动化）— `主链确认`

**用户目标**：把 prompt 挂到 rrule 重复日程上，后台无头运行并产出真实聊天——"每天早上 9 点生成一份当日计划"且结果可见、可回链。

**入口与触发者**：前端 `/automations`；用户创建（prompt + model + rrule + 文件夹）；执行由**后台调度器**触发（非用户交互）。

**事实对象**：`automation` + `automation_run` 两张表（`models/automations.py`），rrule 存 `automation.data['rrule']`。

**完整主链**（调度与执行分两段）：
- **调度**：创建自动化时先校验限额（automations.max_count 与 min_interval，admin 豁免），随后每个实例各跑一个 `scheduler_worker_loop`，默认每 10 秒轮询一次并加随机抖动，避免多实例同时抢跑；到期任务由 `Automations.claim_due` 以原子方式认领，每批最多 10 条（`utils/automations.py:68`）。
- **规则边界**：下次触发时间由 recurrence 工具计算，认领时采用 owner 所在时区；PostgreSQL 用行锁跳过其他实例已认领的行，其它方言的并发保证需单独验证。Calendar 的重复事件展开另属日程对象实现（[`models/automations.py:297-348`](../../open-webui/backend/open_webui/models/automations.py#L297-L348)）。
- **执行**：`execute_automation` 取到任务后先复验所有者权限，权限被收回或账号停用即记为失败；随后渲染 prompt 模板、创建一条真实聊天（meta 记录 automation_id，并预置用户与助手消息占位）、通知前端刷新列表，再按与前端 Chat.svelte 同源的逻辑解析模型工具、特性与 Filters，最后带所有者 token 发起无头请求，走完整 chat completion 管线（`utils/automations.py:349`）。运行结果写入 automation_run 并附聊天回链，同时发布运行事件，记录会进入日历时间轴（runs 与 Calendar 共用），也可在 `/automations/{id}/runs` 查看。

**主动性、终态与取消**：支持停用、删除和手动立即运行；停用影响未来调度。持久 chat 目标等待生成任务后复验消息完成状态，再写 success；频道目标未做同等完成复验。执行时还检查 owner 账号活跃与 session stamp。自动化路由未找到运行级独立取消 API，聊天任务取消可被持久 chat 执行器记为 error run。终端切目录辅助函数在本仓库后端仅找到定义，未找到调用点。详见[主动 Agent 与后台任务笔记](../主动Agent与后台任务/Open-WebUI-主动Agent与后台任务调查笔记.md)。

**独特性判断**："调度 + 无头执行 + 真实聊天产物 + 运行历史"四件套同时存在且结果归属自动化所有者，是"主动 Agent"聚类（对照 VCP FlowLock、Hermes cron）中用户可管理度突出的实现。

**证据强度**：调度循环与执行函数源码为静态事实；真实定时触发与多实例并发认领未运行验证。

### 能力六：模型 Arena / ELO 评估 — `主链确认`

**用户目标**：让用户对模型回复做成对/打分反馈，沉淀为可查询的模型排行榜（Arena + ELO），并按话题语义加权。

**入口与触发者**：用户在前端对回复评分（feedback，`rating: 1/-1` + `sibling_model_ids` + `tags`）；admin 在 `/admin/evaluations` 看榜。

**事实对象**：`feedback` 表（`models/feedbacks.py`，`LeaderboardFeedbackData` 只取 id+data 供排行计算）。

**完整主链**：用户评分落 `feedback` → `GET /evaluations/leaderboard`（`routers/evaluations.py:216`）：取全部反馈 → `_calculate_elo`（初始 1000、K=32、expected 公式；可选相似度权重）→ 聚合话题标签 → 按 rating 降序返回。查询加权：带 query 时用 sentence-transformers 对标签做余弦相似度，相似度作 Elo 权重。参与 Arena 的模型集合由 `evaluation.arena` 配置控制（enable/models）；`/leaderboard/{model_id}/history` 提供单模型历史。

**持续性**：全部来自 `feedback` 表，排行榜为实时计算（无缓存表）；仅 admin 可见。

**独特性判断**：Open WebUI 把用户反馈变成 Elo 排行榜且支持话题加权检索，是"模型评估产品面"的完整实现。

**证据强度**：路由与 Elo 实现源码为静态事实；embedding 加权与排行榜 UI 未运行验证。

### 能力七：语音/视频通话模式（CallOverlay）— `入口确认`

**用户目标**：免提语音交互——按住说话转文字进聊天、模型回复语音朗读，摄像头可抓图作为消息附件。

**入口**：`src/lib/components/chat/MessageInput/CallOverlay.svelte`（输入栏通话浮层）。行为链（静态确认）：浏览器媒体接口采集麦克风 → `MediaRecorder` 录制 → 转写 API（后端 `routers/audio/`，多 STT 引擎：本地 Whisper/OpenAI/Deepgram/Azure；另提供 `/realtime` WebSocket 实时语音端点 `routers/audio/realtime.py:359`）→ 转录文本进聊天；模型回复经 TTS（OpenAI 语音/Transformers/Kokoro WebAPI 引擎，带音频缓存）朗读；摄像头画面经 canvas 截帧作为图片内容。**注意**：README 称"voice/video calls"，实现是单用户免提模式（STT→聊天→TTS 朗读 + 摄像头取图），**不是** WebRTC 点对点通话，也无通话信令服务。

**独特性判断**：把语音闭环做进聊天输入层，与终端/桌面伴生应用的语音能力有交集，但属于 WebUI 本体。

**证据强度**：组件源码为静态事实；浏览器媒体权限流程与 STT/TTS 引擎接入未运行验证。

### 能力八：企业身份（LDAP/OAuth/SCIM）— `入口确认`

- **LDAP**：登录走 `POST /auths/ldap`，链路覆盖 DN 转义、从组 CN 提取角色映射，服务器配置放在 `/auths/admin/config/ldap`（`routers/auths.py:405`）。
- **OAuth**：多个 provider 在 `/auths/admin/config/oauth` 管理；`token/exchange` 端点支持企业 OAuth 会话，provider 会话记录在 oauth_sessions 表。
- **SCIM 2.0**：`routers/scim.py` 实现 Users 与 Groups 的 SCIM 端点，遵循 `urn:ietf:params:scim:schemas:core:2.0:User/Group` 与 ListResponse/Error 两类 schema；文件头自述 experimental（可能不完全合规），认证来源由 `SCIM_AUTH_PROVIDER` 控制。

**独特性判断**：作为自托管平台的自带身份层，LDAP+OAuth+SCIM 三件套齐备（SCIM 标实验性）。

**证据强度**：路由源码为静态事实；真实目录接入与 SCIM 合规性未验证。

### 能力九：云文件集成（Google Drive / OneDrive）— `入口确认`

前端 `utils/google-drive-picker.ts`（gapi picker，OAuth token 弹窗）与 `utils/onedrive-file-picker.ts`（OneDrive picker 弹窗流，`onedrive.live.com/picker`，access_token 表单注入）选择云端文件，把选中文件导入文件库供聊天/RAG 使用。后端侧未见独立"云文件代理"路由——文件导入后进入既有 `files` 体系（知识库/聊天文件面已由 RAG 与代码执行笔记覆盖）。

**独特性判断**：企业文档源接入的入口面属于平台独有，但主链后半段归并现有文件体系。

**证据强度**：前端 picker 源码为静态事实；真实 OAuth 流程与文件回流未运行验证。

### 能力十：多节点运行（Redis 支撑）— `入口确认`

`WEBSOCKET_MANAGER='redis'` 打开后，跨节点事件广播交给 `socketio.AsyncRedisManager`，另有三类 Redis 原语支撑共享状态（`socket/main.py:67-82`、`socket/utils.py:113-127`）。

- **RedisDict**：以哈希保存会话状态，并提供 HSCAN 分批读取与 HDEL 批量删除，供会话池清理使用。
- **RedisLock**：基于 SET NX/EX 的分布式锁，续期与释放走 Lua 脚本。
- **YdocManager**：维护 Yjs 文档的更新列表、压缩与用户集合，支撑跨节点协作。

配合 DB 层（SQLite 加密/PostgreSQL）、会话与任务在 Redis 中取消（对话请求与上下文笔记已确认）以及自动化认领的原子更新，构成水平扩展基础。该能力属于平台运行机制，按调查指南"工程机制单独标注"处理，不进入特色贡献计数。

**证据强度**：socket 模块源码为静态事实；多节点真实部署未验证。

### 能力十一：外部应用平台（Apps）— `主链确认`

**用户目标**：让外部服务以"应用"身份加入工作区和频道，与用户、模型处在同一时间线，而不是只能通过 API 调用或 webhook 单向触发。

**事实对象**：`app` 表记录应用的基本身份与凭据，包括 id、slug、名称、属主、启用状态、配置 data 与 api_key；同一文件里的 Manifest、Embed、Action、AppInvitation 等模型描述应用可声明的清单、嵌入卡片与动作（`models/apps.py:17,45-160`）。

**入口与主链**：管理员在 Apps 设置页提交 manifest（`src/lib/components/admin/Settings/Apps.svelte`），后端提供列表、manifest 预览、创建、读取、连接、删除与交互端点（`routers/apps.py:44-249`）。创建时校验回调 URL 只指向公网地址并发放 api_key；应用被邀请进频道后成为频道成员，平台把频道消息事件向其回调地址推送（`utils/apps.py:92-222`）。

**回传与授权**：应用经 `/{app_id}/interactions` 回调时，需携带按该 app 签名、默认 900 秒过期的上下文 token，平台再按 scope 与频道成员关系校验（`utils/apps.py:177-300`）；通过后可发布频道回复（`generate_app_channel_reply`）。因此它同时具备入站回调鉴权和出站事件推送两个方向。

**独特性判断**：Apps 把外部服务做成可邀请的一等参与者，与 Channels 打通；它是比 MCP 工具、webhook 入站更完整的双向集成面，但仍由 Open WebUI 持有消息与状态。

**证据强度**：模型、路由、出站请求与 token/scope 校验均为静态事实；真实注册、事件投递重试、回调鉴权与加密凭据的端到端行为未运行验证。

### 能力十二：多标签工作台（ChatTabs）— `主链确认`

**用户目标**：把会话、文件、终端、浏览器、桌面画面、Artifact 预览、语音、评论与侧聊放进同一聊天区的标签体系，减少在多个窗口间切换。

**事实对象**：标签状态由 `PanelTabs`（tabs、activeId、history）表达，标签种类包含 chat、files、file、terminal、browser、desktop、artifacts、preview、voice、comments、side（`src/lib/components/chat/ChatTabs/tabs.ts:5-32`）。

**入口与主链**：聊天页组件 Chat.svelte 持有 terminalTabs 实例，并在消息主区域挂载 ChatTabs（`src/lib/components/chat/Chat.svelte:3877,5720`）。每个标签种类由 ChatTabs 目录下的独立组件渲染，浏览器、桌面画面、嵌入内容、画布、Git 变更、侧聊与未命名文件各有对应组件，例如浏览器标签由 Browser.svelte 与 ChromeBrowser.svelte 承担；终端与文件系统经 `/api/v1/terminals` 代理（`src/lib/apis/terminal/`）。

**边界**：终端、桌面画面与浏览器能力依赖外部 Terminal/桌面服务，本仓库承担 UI 编排与代理；文件预览与 Artifact 仍由消息内容派生，标签只是展示位置。

**独特性判断**：把传统"右侧面板"扩展为可并行多标签的工作区，且标签种类覆盖远程终端、Git 变更与外部桌面，是聊天产品中少见的形态。

**证据强度**：标签类型、状态结构与挂载位置为静态事实；外部终端/桌面连接、标签会话隔离与并发行为未运行验证。

### 能力十三：人工提问（ask_user）— `主链确认`

**用户目标**：让模型在推理过程中停下来向用户提出澄清或选择，而不是把假设继续写进回答。

**事实对象**：内置工具 `ask_user` 接受 1 到 3 个结构化问题并返回选项（`backend/open_webui/tools/builtin.py:535`）；调用结果作为工具调用记录在消息 output 中。

**主链**：模型发出工具调用后，中间件在正常派发前先暂存该调用（`backend/open_webui/utils/middleware.py:5707`）；暂存规则要求该工具单独调用、单轮只能一个（`backend/open_webui/utils/ask_user.py:8-30`）。前端以 `AskUserCard.svelte` 渲染问题与选项，用户作答后作为工具结果回填，同一轮继续生成。

**边界与区别**：工具审批决定是否执行，人工提问收集信息；持久聊天中两者共用暂停落库与 resolve 端点，完整访问也不会自动代答。限制作用于当前工具调用批次：须单独调用且每批一个；代码未累计整个生成回合的提问次数。每次提问含 1–3 题，每题 2–3 个选项（[`utils/ask_user.py:9-81`](../../open-webui/backend/open_webui/utils/ask_user.py#L9-L81)、[`utils/tool_approval.py:119-170`](../../open-webui/backend/open_webui/utils/tool_approval.py#L119-L170)）。

**证据强度**：工具定义、中间件暂存与前端卡片为静态事实；作答回填后的续写时序、与流式渲染的配合未运行验证。

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
| 技能（Skills：`@` 提及注入、创建引导与版本历史） | [`../Agent工具/Open-WebUI-Agent工具调查笔记.md`](../Agent工具/Open-WebUI-Agent工具调查笔记.md) |
| 工作区全局搜索（`routers/search.py`，跨会话/消息/文件的权限内检索） | [`../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md`](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md) |
| 通知收件箱（`notification` 表、提醒与系统消息） | [`../主动Agent与后台任务/Open-WebUI-主动Agent与后台任务调查笔记.md`](../主动Agent与后台任务/Open-WebUI-主动Agent与后台任务调查笔记.md) |
| 资源评论（`comments` 表与频道/资源评论面） | [`../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md`](../会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md) |
| MFA（TOTP 与恢复码） | 并入下方企业身份能力（`入口确认`） |

## 声明不符、外部依赖与暂缓项

- **Artifact KV（`声明不符`，按当前快照）**：README 宣称"Persistent Artifact Storage: Built-in key-value storage API for artifacts, enabling journals, trackers, leaderboards, and collaborative tools with personal and shared data scopes"，即面向 Artifact 的键值存储 API，覆盖个人与共享作用域。按当前快照做静态搜索，未找到独立的 KV 存储 API 入口。
  - 搜索范围：后端 `backend/open_webui/` 下的 routers、models、utils、tools、socket、internal 六个目录，以及前端 `src/lib`。
  - 搜索关键词：artifact、kv、leaderboard、tracker、journal 与 `/api/v1/data`。
  - 前端命中：只有 Artifact 渲染 store 的 `artifactCode` 字段与代码块提取（`stores/index.ts:133`）。
  - 语义接近的实现：channel 消息、calendar 与 note 记录的 data 字段，以及聊天任务清单（创建与更新函数存 `Chat.tasks`，`builtin.py:3421`，对应 README 的"Live Workflow & Message Flow"）。
  - 结论：该条声明在当前可执行路径中找不到对应产品契约，可能指未来功能或文档愿景。
- **语音/视频通话**：README 用语（"voice/video calls"）比实现（单用户免持 STT/TTS + 摄像头取图，无 WebRTC 对端）更宽，已按实现记录。
- **SCIM**：文件头自述 experimental 且"may not fully comply with SCIM 2.0"，按 `入口确认` 记录并保留差异说明。
- **伴生仓库**（不属于本仓库主链）：Open WebUI Computer、Open Terminal/Terminals、oikb、桌面 App（README 生态节），本轮不调查，标 `暂缓`。本仓库内的 `/terminals` 前端与 `routers/terminals.py` 仅代理外部 terminal server，未走主链。
- **Analytics/用量**：`routers/analytics.py` 存在（models/users/messages/tokens 统计），属于管理面板常规能力，不在待查清单，未走主链。

## 对特色贡献统计的影响

- 主贡献候选（`主链确认`，静态证据）：Channels、Notes、Persistent Memory、Calendar、Automations、模型 Arena/ELO、外部应用平台、多标签工作台、人工提问——9 个能力族。
- 辅助贡献/`入口确认`：语音通话模式、企业身份（LDAP/OAuth/SCIM/MFA）、云文件入口。
- 多节点运行按"工程/可靠性机制"单独标注，不进用户可见特色计数。
- 同一工作流合并：Calendar 与 Automations 共享 `scheduler_worker_loop` 调度器与时间轴，但用户目标不同（日程管理 vs prompt 自动化），分开计数；Automations 的"运行记录上日历"不重复计数。
- Apps 与 Channels 共用频道成员与消息模型，但 Apps 的是"外部服务参与"而非模型参与，故单独计数；技能、通知收件箱、资源评论与全局搜索归入既有类目，不重复计数。
- Artifact KV 不计入；README 宣称而代码未接线的部分保留差异说明，不给特色加分。

## 未验证事项

- 全部能力均未运行验证（未启动 open-webui 服务）：socket 实时推送、模型在频道/笔记中的流式参与、记忆后台复盘的真实模型调用、自动化定时触发与多实例并发认领、ELO 加权查询、STT/TTS 引擎接入、LDAP/SCIM 真实接入、云文件 OAuth 流、Redis 多节点部署。
- Apps 的真实注册、出站事件投递重试、回调 token 校验与 SSRF 防护效果未运行验证。
- ChatTabs 的外部终端/桌面连接、标签会话隔离与并发切换行为未运行验证。
- ask_user 的作答回填后续写时序、与流式渲染和工具审批的交互未运行验证。
- Artifact KV 的"未找到"结论基于当前快照的静态搜索；若用户基于新版文档/发行版宣称存在，需在新快照复查。
- Calendar 重复事件（rrule）的展开与提醒推送细节未逐行核对（`get_events_by_range` 与 `_check_calendar_alerts` 行为以代码为准）。
- Notes 的 Yjs 协作在 SQLite/PostgreSQL 双后端下的并发正确性未验证。
- 频道模型消息在"会话与消息管理"双写体系中的归属（channel 消息不写 `chat.chat.history`）未与现有笔记交叉核对完整。

## 关键源码索引

- `backend/open_webui/routers/channels.py`（1125 new_message_handler、951 model_response_handler、916 send_notification）
- `backend/open_webui/routers/notes.py`（65 get_notes、308/467 note↔chat、536 update、616 access）
- `backend/open_webui/models/channels.py`（channel/channel_member/channel_file/channel_webhook）、`models/notes.py`、`models/calendar.py`（calendar/calendar_event/calendar_event_attendee）、`models/automations.py`（automation/automation_run、282 claim_due）、`models/memories.py`、`models/feedbacks.py`
- `backend/open_webui/utils/memory.py`（290 add_memory_context、408 review_memory_after_turn、520 _generate_memory_operations）
- `backend/open_webui/utils/automations.py`（68 scheduler_worker_loop、131 _build_request、349 execute_automation）
- `backend/open_webui/routers/memories.py`（127 add、274 query、391 reset）、`routers/evaluations.py`（81 _calculate_elo、216 leaderboard）、`routers/scim.py`、`routers/auths.py`（ldap_auth）、`routers/audio/`（STT/TTS 引擎族）
- `backend/open_webui/routers/apps.py`（44 列表、98 创建、203 connect、249 interactions）、`models/apps.py:17`、`utils/apps.py`（92 send_app_request、177 上下文 token、291 invocation 校验）
- `src/lib/components/chat/ChatTabs/`、`src/lib/components/chat/ChatTabs/tabs.ts:5-32`、`src/lib/components/chat/Chat.svelte:5720`、`src/lib/apis/terminal/`
- `backend/open_webui/tools/builtin.py:535`（ask_user）、`utils/ask_user.py`、`utils/middleware.py:5707`、`src/lib/components/chat/AskUserCard.svelte`
- `backend/open_webui/tools/builtin.py`（663-988 记忆工具、990-1365 笔记工具、3965-4226 日历工具、3421/3471 任务清单、3537 automation 工具）
- `backend/open_webui/socket/main.py`（67-82 Redis manager、465-698 note Yjs 事件）、`socket/utils.py`（RedisDict/RedisLock/YdocManager）
- `src/routes/(app)/notes/`、`(app)/channels/[id]`、`(app)/calendar`、`(app)/automations/`、`(app)/admin/evaluations/`
- `src/lib/components/chat/MessageInput/CallOverlay.svelte`、`src/lib/utils/google-drive-picker.ts`、`onedrive-file-picker.ts`、`src/lib/apis/{notes,channels,calendar,automations,evaluations,memories,audio}/index.ts`
