# OpenCode 会话与消息管理调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：直接阅读源码（TypeScript 服务端会话存储与事件、TUI/Web 客户端投影），核对快照 HEAD 全部符号与行号
>
> 调查范围：会话/消息/part 数据模型、生命周期与 SQLite 持久化、消息操作与分支数据语义、列表分页与检索、V1/V2 双轨、外部对象绑定；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 以「SQLite 持久化 + 事件发布 + 客户端投影」为会话数据核心：消息模型是 Session → Message（role: user/assistant）→ Part（12 种类型）三层，part 独立存表、读取时组装。`updateMessage`/`updatePart` 只发布事件，DB 写入由事件投影器完成（packages/opencode/src/session/session.ts:631-645、packages/core/src/session/projector.ts:262-330）——写入与广播强耦合，事件顺序即持久化顺序。

关键事实（快照 1f94d8a）：

- **ID 体系**：三类 id 前缀与编码方向见下；ID 主体是时间戳×0x1000 加计数器，再拼 14 字节随机 base62（`packages/schema/src/identifier.ts:14-29`、`packages/schema/src/session-id.ts:5-14`、`packages/opencode/src/id/id.ts:51-70`）：
  ```text
  ses_：Session 前缀，随创建时间降序（新会话排序在前）
  msg_：Message 前缀，升序
  prt_：Part 前缀，升序
  ```
- **流式落盘分三层**：reasoning/text 的 delta 走 `updatePartDelta` 发增量事件、完整 part 在 end 事件时落库、tool part 状态迁移即时落库（processor.ts:280-313、:499-532）。
- **上下文压缩是"重写历史"**：compaction 重排消息并清空旧 tool 输出（`compaction.ts:279-323`、`message-v2.ts:521-572`）。
- 压缩请求把对话历史序列化为 6 种角色前缀文本（见下列代码块）拼进 summary 请求；结果按 `TOOL_OUTPUT_MAX_CHARS`（2000）截断，压缩过的输出标 `[Old tool result content cleared]`（`compaction.ts:52-86`、`:385-441`）。
  ```text
  [User] / [Assistant] / [Assistant reasoning] / [Assistant tool call] / [Tool result] / [Tool error]
  ```
- 压缩不再经 `toModelMessagesEffect` 的 stripMedia 媒体剥离——该选项保留但本快照无调用方（grep 未见 `stripMedia: true`）。
- **无消息内容全文搜索**：仅会话标题 LIKE 搜索（session.ts:993-995、core/src/session.ts:277）。
- **附件为 data URL 内联**：本快照未发现独立 attachments 存储目录。
- **V1/V2 双轨**：V1（Legacy `message`/`part` 表）为生产主路径；V2 为事件溯源新架构（`session_message`/`session_input`/`event` 表，seq 排序），客户端按协议协商切换。

## 系统边界与数据主链

```text
POST /session（创建，groups/session.ts:203-214）-> createNext 生成 ses_ id + 默认标题（session.ts:501-540）
  -> prompt 时 user message 与 parts 立即落库（prompt.ts:1046-1047）
  -> 流式 part 经 processor 逐个 updatePart/updatePartDelta 发布事件（processor.ts:278-537）
  -> 投影器消费事件 upsert message/part 表（projector.ts:262-330）
  -> GET /session/:id/message?limit&before 分页读取（handlers/session.ts:106-145，MessageV2.page）
  -> session.list（LIKE title 搜索）供侧栏与命令面板（session.ts:957-1010）
  -> 删除/重命名/revert/fork 修改原对象或新建会话（session.ts:608-629、:755-757；revert.ts；session.ts:693-734）
```

边界：消息/part 如何经 SSE 投影到客户端 store、如何渲染属于消息渲染器类目；一次生成的上下文拼装与执行属于对话请求与上下文；会话侧栏与搜索浮层工作流属于 Chat UI。

## 1. 会话、消息与分支数据模型

- **Session 字段**（`packages/core/src/session/sql.ts:22-66`）：列覆盖身份与路径、标题与分享、摘要、成本与 token 统计、回退与权限、agent/model 绑定、各类时间戳等；`agent`/`model` 为列而非外键引用（:51-56）。字段全集：
  ```text
  id / project_id / workspace_id / parent_id / slug / directory / path / title / version / share_url / summary_* / metadata / cost / tokens_{input,output,reasoning,cache_read,cache_write} / revert / permission / agent / model{id,providerID,variant} / time_{created,updated,compacting,archived}
  ```
- **Message 表**：data 列存 `Omit<SessionV1.Info,"id"|"sessionID">` 类型（`sql.ts:19`、`:68-80`），**不含 parts**；分页排序依赖复合索引 `(session_id, time_created, id)`（:79）。
- **Part 独立存表**：parts 独立存 `part` 表，仅 `message_id` 带级联删除外键（`sql.ts:82-98`）；读取时 `MessageV2.hydrate` 批量组装（`packages/opencode/src/session/message-v2.ts:98-123`）。
- **Message 判别**：`User` 与 `Assistant` 两种消息各有独立字段集合，`Info` 是它们的联合类型（`packages/schema/src/v1/session.ts:490`）：
  ```text
  User（role:"user"）：summary / agent / model / system / tools / format（:332-355）
  Assistant（role:"assistant"）：parentID / modelID / providerID / mode / agent / path / cost / tokens / finish / error / structured / variant（:453-488）
  ```
- **Part 12 种类型**（`packages/schema/src/v1/session.ts:357-370`）：
  ```text
  text / subtask / reasoning / file / tool / step-start / step-finish / snapshot / patch / agent / retry / compaction
  ```
- **ToolPart 状态机**（:259-313）：
  ```text
  pending / running / completed / error（completed 状态带 time.compacted，:286）
  ```
- **CompactionPart**：带 `tail_start_id`（:195-202）。
- **finish 字段**：任意字符串，本快照可见取值见下（:484；`prompt.ts:1295-1316`、`processor.ts:443`）：
  ```text
  "tool-calls" / "stop" / "error" / "content-filter"
  ```
- **error 归一化**：8 种错误类型联合（`v1/session.ts:385-394`）：
  ```text
  AuthError / APIError / ContextOverflowError / AbortedError / StructuredOutputError / ContentFilterError / UnknownError / OutputLengthError
  ```
- **`snapshot` 语义是 git 快照**：`step-start`/`step-finish` part 与回退记录上的该字段都是 git tree 哈希（`v1/session.ts:87-92, 233-257`）。快照操作集在 `packages/opencode/src/snapshot/index.ts`：
  ```text
  track :318-347 / patch :349-380 / restore :382-406 / revert :408-
  ```
- **分支**：无消息树；分支通过 `fork` 新建会话复制消息实现（见第 4 节）。
- **V2 消息类型**：事件溯源模型 `SessionMessage`，8 种类型定义于 `packages/schema/src/session-message.ts:200-213`：
  ```text
  user / assistant / synthetic / system / shell / agent-switched / model-switched / compaction
  ```
- **V2 消息存储**：存 `session_message` 表（`sql.ts:119-138`，`seq` 每会话唯一），由投影器从事件投影（`projector.ts:112-191`、:331-395）。
- **V2 会话输入**：另存 `session_input` 表（admitted/promoted seq，`sql.ts:140-166`）。
- **`MessageV2` 是转换层而非新模型**：提供四类转换（`packages/opencode/src/session/message-v2.ts`）：
  ```text
  page（分页）:425-467 / toModelMessagesEffect（历史转 AI SDK 消息）:131-415 / filterCompacted（过滤压缩）:521-572 / fromError（错误归一化）:606-734
  ```
  其中 `latest` 判定按 `time.created` 排序、id 仅作决胜（:582-604）——导入消息的 id 不保证单调。

## 2. 事实源、索引与持久化

- **SQLite 位置**：数据库文件为 `Global.Path.data` 下的 `opencode.db`（路径拼接见 `packages/core/src/database/database.ts:43-55`，非 latest/beta/prod 渠道时按渠道加后缀）；启动时设置 WAL 等 PRAGMA 并执行迁移（:27-33）。迁移文件在 `core/src/database/migration/`（38 个，含 V2 会话相关）。
- **事件即写入**：`Session.updateMessage/updatePart` 本身只发布事件，DB 写入由事件投影器完成——`message.updated` 事件 upsert 消息表、`part.updated` 事件 upsert part 表并加减 usage（`session.ts:631-645`；投影器在 `projector.ts:262-330`）。写入与广播强耦合，事件顺序即持久化顺序。
- **写入时机（V1 主链路）**：
  - prompt：user message 与 parts 立即落库（prompt.ts:1046-1047），agent/model 不一致时 `setAgentModel` 同步到 session 行（:672-689、session.ts:767-778）。
  - stream：assistant message 进入循环时先落库（prompt.ts:1186-1201）；流式 part 由 processor 逐个 `updatePart`/`updatePartDelta`（processor.ts:280-313、:499-532）。
- **delta 通道独立于 part 存储**：流式期间客户端用 `part_text_accum_delta` 累积，结束事件才完整替换（app/src/context/global-sync/event-reducer.ts:364-382；细节见消息渲染器笔记）。
- **附加持久化对象**：`TodoTable`（`sql.ts:100-117`，主键 `(session_id, position)`）的事务更新会整表重写后按 position 重插，并发布更新事件（`packages/opencode/src/session/todo.ts:29-51`）。

## 3. 创建、切换、归档、删除与恢复

- **创建（V1）**：链路 `POST /session`（`groups/session.ts:203-214`）→ `Session.create`（`session.ts:669-691`）→ `createNext`（:501-540）：
  - id 与 slug：生成降序编码的 id（:515）与 slug（:516）；
  - 标题：默认 `New session - <ISO时间>`（:523），子会话前缀 `Child session -`（:48-49）；
  - 事件：发布 `session.created`（:537）。
- **创建（V2）**：`POST /api/session`（`packages/server/src/handlers/session.ts:67-79`）→ `V2Session.create`（`packages/core/src/session.ts:208-262`），`session.created` 事件由投影器落库（:241-258）。
- **惰性创建**：App 在首次发送且无 `params.id` 时才调用 `api.session.create`（`app/src/components/prompt-input/submit.ts:401-435`）。
- **重命名**：`PATCH /session/:id`（`handlers/session.ts:183-204`）→ `setTitle`（`session.ts:755-757`）。
- **自动标题**：首轮 prompt 后 `ensureTitle` 调小模型生成标题（`prompt.ts:193-253`）。
- **删除**：`DELETE /session/:id`（`handlers/session.ts:178-181`）→ `Session.remove`（`session.ts:608-629`），依次完成：
  - 取消后台任务（`cancelBackgroundJobs`，:618、:940-955）；
  - 递归删除子会话（:619-622）；
  - 发布 `session.deleted` 并移除事件（:624-625）。
- **切换/归档**：归档标记是会话字段 `time.archived`（`sql.ts:59`），`PATCH /session/:id` 的对应分支调 `setArchived`（`handlers/session.ts:200-202`、`session.ts:759-761`）。
- App 侧归档只从列表移除并调用更新（`directory-sync.ts:136-146`）；列表查询默认排除已归档（`session.ts:564`、`layout/helpers.ts:19`）。无独立"清空空会话"机制。
- **恢复语义**：消息/parts 均逐步落库，异常退出后从 SQLite 恢复；进程内运行态（Runner/status）存于 InstanceState，随实例清理（run-state.ts:35-50）。V2 的 post-crash continuation recovery 明确标注为未来工作（core/src/session/runner/llm.ts:86）。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑**：无整体 edit message 端点；`PATCH /session/:id/message/:messageID/part/:partID` 更新单个 part（groups/session.ts:433-444、handlers/session.ts:397-411）。
- **删除**：消息与 part 各有删除端点（`handlers/session.ts:384-432`，需 `assertNotBusy`），删除发布 `message.removed`/`message.part.removed` 事件（`session.ts:855-877`）。
- 投影器删行并回滚 usage（`projector.ts:276-311`）；OpenAPI 描述明确删除不还原文件变更（`groups/session.ts:419`）。
- **重试**：无独立重试端点；进程内自动重试（见对话请求与上下文笔记 7），前端对失败消息的重试本质是再次发送。
- **回退（revert）**：`POST /session/:id/revert`（`groups/session.ts:369-382`）→ `SessionRevert.revert`（`revert.ts:38-89`），依次执行：
  1. 校验空闲（`assertNotBusy`，:39）；
  2. 定位目标消息/part 并记录回退状态（:55-66，含 git 快照）；
  3. 用 `snap.revert(patches)` 回滚文件（:72）；
  4. 计算 diff 写入存储并发布 `session.diff`（:76-78），`setRevert` 持久化（:79-87）。
- 回退范围：再次 prompt 前 `revert.cleanup`（:101-124）删除目标之后的消息——无 partID 时从目标轮次的最后一个 user 消息之后全部删除；有 partID 时保留该 user 消息、仅删 partID 起的 parts。
- 目标与范围用 `findIndex`+`slice` 定位（:74-75、:106-114），不用 id 大小比较（导入消息 id 可能非单调）。
- `unrevert` 恢复文件并清空回退状态（:91-99）。回退改的是原消息链（删除），不是新建分支节点。
- **分支（fork）**：`POST /session/:id/fork`（`session.ts:693-734`）新建会话并复制截至某消息（缺省全部）的消息/parts：
  - 标题 `(fork #N)` 递增（:161-169）；
  - 复制边界由 `findIndex` 定位（:706）；
  - 新 id 用 `MessageID.ascending()`，assistant 的 `parentID` 重映射（:712-718）；
  - compaction part 的 `tail_start_id` 一并重映射（:727-729）。
- **续写**：同 session 继续 prompt 追加即可（loop 从数据库重读历史）；V2 有 `delivery: "steer"`（打断当前轮）与 `"queue"`（排队，packages/schema/src/session-delivery.ts:5、core/src/session/input.ts:245-288）。

## 5. 列表、分页、搜索与定位

- **侧栏列表**：app/src/context/directory-sync.ts:124-134 用 `session.list({directory, limit, order:"desc"})`，`fetch(count=10)` 递增分页；命令面板跨目录 `session.list({parentID:null, search, limit:50})`（app/src/components/command-palette.ts:149）。
- **V1 列表实现**：`listByProject`（`session.ts:957-1010`）按 project_id 加可选目录、路径、工作区、roots、start、search 过滤，标题用 `LIKE` 子串匹配（:993-995），按更新时间降序且 limit 默认 100（:997-1003）。
- `listGlobal` 跨项目时按更新时间与 id 双键排序（:574）。
- **消息分页**：`GET /session/:id/message?limit&before=`（`handlers/session.ts:106-145`）→ `MessageV2.page`（`message-v2.ts:425-467`）：
  - 游标为 base64url 编码的 `{id,time}`（message-v2.ts:63-78），`older` 谓词在 :95-96；
  - 排序与探测：按创建时间与 id 降序（:439），limit+1 探测是否有更多（:440）；
  - 响应带 `Link: rel="next"` 与 `X-Next-Cursor` 头（handlers :130-144）。
- **V2 消息分页**：`session.history` 按 seq 分页读 `event` 表（`packages/server/src/handlers/session.ts:332-356`、`core/src/session.ts:352-359`）。
- **搜索**：仅会话标题搜索；**消息内容全文搜索本次未找到实现**（在 packages/opencode、packages/core、packages/app 三个包中 grep 未发现对消息/part 内容的子串或全文查询，唯一的 `LIKE` 用在标题）。
- **消息渲染**：App timeline 虚拟化与分页加载见消息渲染器笔记，本笔记只记录数据分页接口。

## 6. 缓存、一致性、多窗口与并发写入

- **事件即写入**：写入与广播强耦合，事件顺序即持久化顺序——简化一致性问题，代价是投影器顺序消费（projector.ts 的 events.project 各事件分支）。
- **多窗口**：SSE 事件全量广播，多个窗口各自订阅同一事件流、独立投影到各自 store，无专门同步层（静态推断，见 Chat UI 笔记）。
- **流式临时状态**：`part_text_accum_delta` 在客户端累积，结束事件完整替换（渲染器笔记）；断线重连与事件乱序下的文本合并正确性未实测。
- **乐观更新**：store 按时间序键（`messageKey = time.created + id`，`app/src/utils/session-message.ts:21`）二分插入/替换并删除累积状态（`server-session.ts:1053`、`event-reducer.ts:272-339`；TUI 端同改，`tui/src/context/sync.tsx:55-58, 328`）。
- `message.removed` 用 `findIndex` 按 id 定位（`server-session.ts:1086`、`event-reducer.ts:299`）；细节见消息渲染器笔记。

## 7. 迁移、导入导出与保留策略

- 数据库迁移：启动时执行（database.ts:33），迁移文件在 core/src/database/migration/（38 个，含 session_message 投影索引、session_input inbox、context epoch 等 V2 相关）。
- 会话导出：CLI `opencode export [sessionID]` 导出 info + messages 为 JSON（packages/opencode/src/cli/cmd/export.ts:223-287）；App 侧分享走 `SessionShare`（share/session.ts，`share_url` 列）。
- 导入、备份恢复与未知字段兼容策略本次未调查（未找到导入端点）。

## 8. Agent、模型、知识库与附件绑定

- **会话级绑定**：会话行保存 agent 与 model 两列（`sql.ts:51-56`，模型存 `{id,providerID,variant}` JSON），发送时不一致自动 `setAgentModel` 更新（`prompt.ts:672-689`、`session.ts:767-778`）。
- 工具集按 agent 与权限在请求时解析（见对话请求与上下文笔记 9）；V2 有 agent-switched/model-switched 事件消息（`projector.ts:331-349`）。
- **附件**：文件以 `data:` URL 内联在 FilePart.url（v1/session.ts:171-179），随消息历史持久化；**本快照未发现独立 attachments 上传目录**（grep 未见附件落盘路径）。data URL 在超长上下文与工具结果中的实际 token 成本未实测。

## 9. 设计取舍与已确认边界

- **事件即写入**：DB 写入与广播强耦合，事件顺序即持久化顺序（第 2 节）。
- **压缩改写历史而非删历史**：compaction 消息保留在链中，通过重排与 `time.compacted` 标记控制模型可见性（message-v2.ts:521-572；旧 tool 输出在 replay 时标 `[Old tool result content cleared]` :294）。
- **revert 删除而非分支**：回退直接删消息，fork 才复制新会话（第 4 节）。
- **消息内容不建全文索引**：仅标题搜索，长会话依赖分页与虚拟化（第 5 节）。
- **V1/V2 双轨并存**：本快照 V1 为生产主路径；V2 的 prompt 先写 durable `session_input` 再 wake（core/src/session.ts:360-386，AGENTS.md "V2 Session Core" 明确要求），post-crash continuation recovery 标注为未来工作（core/src/session/runner/llm.ts:86）。双轨在数据模型（第 1 节）、执行链（对话请求与上下文笔记）各答不同问题。

## 10. 未验证事项

1. V2 事件溯源链路（session_message/session_input/event 表、projector、run-coordinator）未运行验证。
2. `part_text_accum_delta` 在断线重连与事件乱序下的行为未实测。
3. 归档生命周期、导入、崩溃恢复与多窗口并发写入需运行验证。
4. 附件 data URL 在超长上下文与工具结果中的实际 token 成本未实测。
5. `snapshot.revert` 对非 git 工作树（`enabled()` 为假时）的行为未实测。

## 11. 关键源码索引

- `packages/opencode/src/session/session.ts`：Session 服务（createNext :501-540、updateMessage/updatePart :631-645、remove :608-629、fork :693-734、setTitle :755-757、listByProject :957-1010）
- `packages/core/src/session/sql.ts`：表结构（session/message/part/todo/session_message/session_input）
- `packages/core/src/session/projector.ts`：事件投影落库（:262-330 等）
- `packages/core/src/database/database.ts`、`migration/`：SQLite 与迁移
- `packages/opencode/src/session/message-v2.ts`：hydrate/分页/过滤压缩/错误归一化（:98-123、:425-467、:521-572、:606-734）
- `packages/opencode/src/session/revert.ts`、`session.ts:693-734`（fork）
- `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`：HTTP 端点
- `packages/schema/src/v1/session.ts`：User/Assistant/Part/事件契约
