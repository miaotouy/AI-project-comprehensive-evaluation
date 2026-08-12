# OpenCode 会话与消息管理调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`1f94d8a3c86b67f4f49a0e341de74e9188381b3a`（分支：`dev`）
>
> 调查方式：从 [`../Chat/OpenCode-Chat调查笔记.md`](../Chat/OpenCode-Chat调查笔记.md)（2026-08-10 调查）迁移现有段落与证据；按提交范围 b8bd889..HEAD 核对压缩序列化、时间序排序键与 revert/fork 定位改动
>
> 调查范围：会话/消息/part 数据模型、生命周期与 SQLite 持久化、消息操作与分支数据语义、列表分页与检索、V1/V2 双轨、外部对象绑定；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 以「SQLite 持久化 + 事件发布 + 客户端投影」为会话数据核心：消息模型是 Session → Message（role: user/assistant）→ Part（12 种类型）三层，part 独立存表、读取时组装。`updateMessage`/`updatePart` 只发布事件，DB 写入由事件投影器完成——写入与广播强耦合，事件顺序即持久化顺序。

关键事实（快照 1f94d8a）：

- **ID 体系**：Session `ses_` + 降序（新会话排序在前）、Message `msg_`、Part `prt_`，时间戳×0x1000+计数器编码 + 14 字节随机 base62（`packages/schema/src/identifier.ts:6-29`）。
- **流式落盘分三层**：reasoning/text 的 delta 走 `updatePartDelta` 发增量事件、完整 part 在 end 事件时落库、tool part 状态迁移即时落库（processor.ts:499-532）。
- **上下文压缩是"重写历史"**：compaction 重排消息并清空旧 tool 输出（compaction.ts）；快照 1f94d8a 起压缩请求把对话历史**文本序列化**为 `[User]/[Assistant]/[Assistant tool call]/[Tool result]` 前缀文本（结果按 `TOOL_OUTPUT_MAX_CHARS` 截断、compacted 输出标 `[Old tool result content cleared]`），拼进 summary 请求（compaction.ts:52-83、:387、:427-438），不再经 `toModelMessagesEffect` 的 stripMedia 媒体剥离。
- **无消息内容全文搜索**：仅会话标题 LIKE 搜索。
- **附件为 data URL 内联**：本快照未发现独立 attachments 目录。
- **V1/V2 双轨**：V1（Legacy）为生产主路径；V2 为事件溯源新架构（`session_input`/`event` 表），客户端按协议协商切换。

## 系统边界与数据主链

```text
POST /session（创建）-> createNext 生成 ses_ id + 默认标题
  -> prompt 时 user message 与 parts 立即落库（prompt.ts:1046-1047）
  -> 流式 part 经 processor 逐个 updatePart/updatePartDelta 发布事件
  -> 投影器消费事件 upsert message/part 表（projector.ts）
  -> GET /session/:id/message?limit&before 分页读取（MessageV2.page）
  -> session.list（LIKE title 搜索）供侧栏与命令面板
  -> 删除/重命名/revert/fork 修改原对象或新建会话
```

边界：消息/part 如何经 SSE 投影到客户端 store、如何渲染属于消息渲染器；一次生成的上下文拼装与执行属于对话请求与上下文；会话侧栏与搜索浮层工作流属于 Chat UI。

## 1. 会话、消息与分支数据模型

- **Session 字段**（core/src/session/sql.ts:22-66）：`id/project_id/workspace_id/parent_id/slug/directory/path/title/version/share_url/summary_*/metadata/cost/tokens_{input,output,reasoning,cache_read,cache_write}/revert/permission/agent/model{id,providerID,variant}/time_{created,updated,compacting,archived}`。
- **Message 表**：`data` 列存 `Omit<SessionV1.Info,"id"|"sessionID">`（sql.ts:77），**不含 parts**；parts 独立存 `part` 表（sql.ts:82-98，仅 `message_id` 带 `onDelete: cascade` 外键 :86-89），读取时 `MessageV2.hydrate` 批量组装（src/session/message-v2.ts:98-123）。
- **Message 判别**：`User`（role:"user"，含 summary/agent/model/system/tools，v1/session.ts:332-354）与 `Assistant`（role:"assistant"，含 parentID/modelID/providerID/mode/agent/path/cost/tokens/finish/error/structured，:453-485）；`Info = Union`（:490-491）。
- **Part 12 种类型**：text/subtask/reasoning/file/tool/step-start/step-finish/snapshot/patch/agent/retry/compaction（schema/src/v1/session.ts:357-370）。
- **finish 字段**：`"tool-calls"|"stop"|"error"` 等（:453-485）；`error` 归一化类型联合共 8 种：AuthError/APIError/ContextOverflowError/AbortedError/StructuredOutputError/ContentFilterError/UnknownError（NamedError.Unknown）/OutputLengthError（v1/session.ts:385-394）。
- **`snapshot` 语义是 git 快照**：step-start/step-finish part 与 session.revert 上的 `snapshot` 字段为 git 提交哈希（v1/session.ts:233-257、src/snapshot/index.ts:39-42、349-406）。
- **分支**：无消息树；分支通过 `fork` 新建会话复制消息实现（见第 4 节）。
- **V2 消息**：事件溯源模型 `SessionMessage`（schema/src/session-message.ts:200-212，type: user/assistant/synthetic/system/shell/agent-switched/model-switched/compaction），存 `session_message` 表（sql.ts:119-138），由 projector 从事件投影（core/src/session/projector.ts:350-395）。
- **`MessageV2` 是转换层而非新模型**：提供分页（page，:425-467）、历史转 AI SDK 消息（toModelMessagesEffect，:131-415）、过滤压缩（filterCompacted，:521-572；其中 `latest` 判定按 `time.created` 排序、id 仅作决胜，:582-604——导入消息的 id 不保证单调）、错误归一化（fromError，:603-731）。

## 2. 事实源、索引与持久化

- **SQLite 位置**：`join(Global.Path.data, "opencode.db")`（core/src/database/database.ts:43-55），启动设置 WAL 等 PRAGMA 并执行迁移（:27-33）；迁移文件在 core/src/database/migration/（38 个，含 V2 会话相关）。
- **事件即写入**：`Session.updateMessage/updatePart` 本身只发布事件，DB 写入由事件投影器完成（session.ts:631-645；projector.ts:262-330 的 `message.updated`→upsert message 表、`part.updated`→upsert part 表）。
- **写入时机（V1 主链路）**：
  - prompt：user message 与 parts 立即落库（prompt.ts:1046-1047），agent/model 同步到 session 行（:672-689）。
  - stream：assistant message 进入循环时先落库（prompt.ts:1186-1201）；流式 part 由 processor 逐个 `updatePart`/`updatePartDelta`（processor.ts:278-537）。
- **delta 通道独立于 part 存储**：流式期间前端用 `part_text_accum_delta` 累积，结束事件才完整替换（UI 更新频率高于落库频率，细节见消息渲染器笔记）。
- **附加持久化对象**：`TodoTable`（sql.ts:100-117），`Todo.update` 事务内 delete 全表 + 按 position 重插并发布 `todo.updated`（src/session/todo.ts:29-51）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：`POST /session`（server/routes/instance/httpapi/groups/session.ts:203-214）→ `Session.create`（session.ts:669-691）→ `createNext`（:501-540）：`id = SessionID.descending()`、`slug = Slug.create()`、默认标题 `New session - <ISO时间>`（:523），发布 `session.created`（:537）。V2：`POST /api/session`（packages/server/src/handlers/session.ts:67-79）→ `V2Session.create`（core/src/session.ts:208-262）。
- **重命名**：`PATCH /session/:id`（handlers/session.ts:183-204）→ `setTitle`（session.ts:755-757）。
- **删除**：`DELETE /session/:id`（handlers :178-181）→ `Session.remove`（session.ts:608-629）：取消后台任务、递归删子会话、发 `session.deleted`。
- **切换/归档**：Session 字段含 `time_{created,updated,compacting,archived}`（sql.ts:22-66），归档的生命周期流程本次未在源笔记中展开。
- **恢复语义**：消息/parts 均逐步落库，异常退出后从 SQLite 恢复；进程内运行态（Runner/status）不落库，随实例清理（run-state.ts:35-49）。V2 的 post-crash continuation recovery 明确标注为未来工作（runner/llm.ts:86）。

## 4. 编辑、重试、续写、回退与分支语义

- **编辑**：无整体 edit message 端点；`PATCH /session/:id/message/:messageID/part/:partID` 更新单个 part（groups/session.ts:433-444、handlers/session.ts:397-411）。
- **删除**：`DELETE .../message/:messageID`（:409-421，需 `assertNotBusy`）与 `DELETE .../part/:partID`（:422-432）→ 发 `message.removed`/`message.part.removed` 事件（session.ts:855-877），投影器删行并回滚 usage（projector.ts:276-311）。OpenAPI 描述明确 "without reverting file changes"（groups/session.ts:419）。
- **重试**：无独立重试端点；进程内自动重试（见对话请求与上下文笔记 7）。
- **回复/回退**：`POST /session/:id/revert`（groups/session.ts:369-382）→ `SessionRevert.revert`（revert.ts:38-88）：定位目标消息/part，记录 revert 状态（含 git snapshot），`snap.revert(patches)` 回滚文件；再次 prompt 前 `revert.cleanup`（:100-134）删除目标之后的消息——无 partID 时连目标消息本身一起删，有 partID 时保留目标消息、仅删其 partID 起的 parts。快照 1f94d8a 起目标与范围改用 `findIndex`+`slice` 定位（revert.ts:74-75、:106-114），不再用 id 大小比较（导入消息 id 可能非单调）。改的是原消息树（删除），不是新建分支节点。
- **分支**：`POST /session/:id/fork`（session.ts:693-734）：新建会话并复制截至某消息的全部消息/parts（复制边界由 `findIndex` 定位，:706，parentID 重映射 :712-718）。
- **续写**：同 session 继续 prompt 追加即可；V2 有 `delivery: "steer"`（打断当前轮）与 `"queue"`（排队，core/src/session/input.ts:245-287）。

## 5. 列表、分页、搜索与定位

- **Sidebar 列表**：`directory-sync.ts:124-134` 用 `session.list({directory, limit, order:"desc"})`，`fetch(count=10)` 递增分页；命令面板跨目录 `session.list({parentID:null, search, limit:50})`（command-palette.ts:149）。
- **V1 列表实现**：`listByProject`（session.ts:957-1010）：按 project_id + 可选 directory/path/workspaceID/roots/start/search 过滤，`LIKE title` 搜索（:993-995），orderBy desc(time_updated) limit 默认 100。
- **消息分页**：`GET /session/:id/message?limit&before=`（handlers/session.ts:106-145）→ `MessageV2.page` 用 base64url 游标 {id,time}（message-v2.ts:63-78、425-467），响应带 `Link: rel="next"` + `X-Next-Cursor`。V2 面 `session.history` 按 seq 分页读 `event` 表（server handlers/session.ts:332-356）。
- **搜索**：仅会话标题搜索；**消息内容全文搜索本次未找到实现**（全局 grep 无匹配）。
- **消息渲染**：App timeline 虚拟化与分页加载见消息渲染器笔记（`../消息渲染器/OpenCode-消息渲染调查笔记.md`），本笔记只记录数据分页接口。

## 6. 缓存、一致性、多窗口与并发写入

- **事件即写入**：写入与广播强耦合，事件顺序即持久化顺序——简化一致性问题，代价是投影器顺序消费（第 9 节）。
- **多窗口**：SSE 事件全量广播，多个窗口各自订阅同一事件流，无专门同步层（静态推断）；窗口级的会话/草稿恢复差异见 Chat UI 笔记。
- **流式临时状态**：`part_text_accum_delta` 在前端累积，结束事件完整替换（渲染器笔记）；断线重连与事件乱序下的文本合并正确性未实测。
- **乐观更新**：store 按**时间序键**（`messageKey = time.created + id`，app/src/utils/session-message.ts:19-26）二分插入/替换并删除 accum（server-session.ts:1051、:1094-1189；global-sync/event-reducer.ts:279-299；TUI 同步端同改，tui/src/context/sync.tsx:54-58、:328），`message.removed` 用 `findIndex` 按 id 定位；细节见消息渲染器笔记。

## 7. 迁移、导入导出与保留策略

- 数据库迁移：启动时执行，迁移文件在 core/src/database/migration/（38 个，含 V2 会话相关，database.ts:27-33）。
- 会话导出工具 `utils/session-export.ts` 在消息渲染器笔记中提及；导出内容与格式本次未在源笔记中覆盖。
- 导入与备份恢复流程本次未调查。

## 8. Agent、模型、知识库与附件绑定

- **会话级绑定**：`session.agent` 与 `session.model` 列（sql.ts:51-56）；发送时不一致自动 `setAgentModel` 更新（prompt.ts:672-689、session.ts:767-778）。工具集按 agent+permission 在请求时解析（见对话请求与上下文笔记 9）。
- **附件**：文件以 `data:` URL 内联在 part.url（v1/session.ts:171-179 的 FilePart），随消息历史持久化；**本快照未发现独立 attachments 上传目录**。data URL 在超长上下文与工具结果中的实际 token 成本未实测。

## 9. 设计取舍与已确认边界

- **事件即写入**：DB 写入与广播强耦合，事件顺序即持久化顺序（第 2 节）。
- **压缩改写历史而非删历史**：compaction 消息保留在链中，通过重排与 `time.compacted` 标记控制模型可见性。
- **revert 删除而非分支**：回退直接删消息，fork 才复制新会话。
- **消息内容不建全文索引**：仅标题搜索，长会话依赖分页与虚拟化。
- **V1/V2 双轨并存**：本快照 V1 为生产主路径；V2 的 prompt 先写 durable `session_input` 再 wake（AGENTS.md "V2 Session Core" 明确要求），post-crash continuation recovery 标注为未来工作（runner/llm.ts:86）。双轨在数据模型（1 节）、执行链（对话请求与上下文笔记）各答不同问题。

## 10. 未验证事项

1. V2 事件溯源链路（session_input/event 表、projector、coordinator）未运行验证。
2. `part_text_accum_delta` 在断线重连与事件乱序下的行为未实测。
3. 归档生命周期、导入导出、崩溃恢复与多窗口并发写入需运行验证。
4. 附件 data URL 在超长上下文与工具结果中的实际 token 成本未实测。

## 11. 关键源码索引

- `packages/opencode/src/session/session.ts`：Session 服务（createNext :501-540、updateMessage/updatePart :631-645、remove :608-629、fork :693-734、setTitle :755-757）
- `packages/core/src/session/sql.ts`：表结构（session/message/part/session_message/TodoTable）
- `packages/core/src/session/projector.ts`：事件投影落库（:262-330）
- `packages/core/src/database/database.ts`、`migration/`：SQLite 与迁移
- `packages/opencode/src/session/message-v2.ts`：hydrate/分页/过滤压缩（:98-123、:425-467、:521-572）
- `packages/opencode/src/session/revert.ts`、`session.ts:693-734`（fork）
- `packages/opencode/src/session/sql.ts` 的 list 入口（session.ts:957-1010）
- `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`：HTTP 端点
