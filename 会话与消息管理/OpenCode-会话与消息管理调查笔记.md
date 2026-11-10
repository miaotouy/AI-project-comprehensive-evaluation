# OpenCode 会话与消息管理调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：直接阅读源码（Core 会话存储与事件、Protocol 端点、App 时间线投影），按新 HEAD 复核符号与文件位置；未运行构建与真实对话
>
> 调查范围：会话/消息数据模型、生命周期与 SQLite 持久化、消息操作与分支语义、列表分页与检索、导入导出；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 的会话数据以 durable 事件为源头，再由投影落库：服务端把会话创建、重命名与归档、inbox 入队与投递、步骤开始与结束、文本与工具进度都发布成 durable 事件，投影器按 seq 顺序写入 SQLite；客户端先读 HTTP 快照，再用事件流补增量。会话模型分五类表存储：

- `session_v2`：会话
- `session_message`：消息
- `session_part`：assistant 内容
- `session_inbox`：待执行输入
- `blob`、`blob_ref`：附件

消息是 11 种类型的联合，取值范围如下：

```text
user / assistant / synthetic / system / skill / shell
compaction / idle / agent-switched / model-switched / location-switched
```

assistant 的正文是内嵌内容数组，条目分 text、reasoning、tool 三类；工具状态有 streaming、running、completed、error 四态。消息表与会话表都只保留 v2 单轨，`session_v2` 是会话的唯一存储路径。

## 系统边界与数据主链

```text
POST /api/session（创建）-> Session.create（core/src/session.ts:288）
  -> 用户输入先入 inbox（SessionPrompt.prepare -> SessionInbox，delivery: steer/queue）
  -> 执行器认领会话（session.execution.started）-> AI 流式调用
  -> 每步 durable 事件（step.text.delta / tool.* / step.ended）
  -> 投影器写 session_message / session_part（projector.ts、message-updater.ts）
  -> 客户端 GET /api/session/:id/message 取快照，SSE 事件流补增量
  -> 重命名/归档/移动/回退/fork/删除均发布会话级事件
```

边界：事件如何经 SSE 投递到客户端、如何渲染属于消息渲染器与 Chat UI 类目；一次生成的历史拼装与模型调用属于对话请求与上下文。

## 1. 数据模型

- **Session**（会话表 `session_v2`）：一行记录把一次会话的归属与运行状态放在一起，包括所属项目与工作区、父会话与 fork 来源及其边界、slug、目录与子路径、标题、版本与分享地址、摘要与 diff 统计、成本与五类 token 计数、回退状态、权限规则集，以及绑定的 agent 与 model。忙碌、空闲、查看、压缩和归档各有时间戳，另有 `time_suspended` 与 `resume_attempts` 两个字段供重启后续跑使用（`packages/core/src/session/sql.ts:28-84`）。
- **Message**（`session_message`，`sql.ts:86-105`）：按 `session_id + seq` 唯一有序，`type` 与 `data` 分离存储；分页索引覆盖创建时间与 id。
- **assistant 内容**（`session_part`，`sql.ts:107-128`）：以 `message_id + ordinal` 为主键保存 text/reasoning/tool 条目，读取时批量拼回消息体（`history.ts:92-126`），因此内容既可整体重放也可按键读取。
- **Inbox**：只保存未投递条目，投递事务消费 inbox 并创建可见消息。同会话、同类型重用用户/合成输入 id 时首次受理胜出，重试中的内容、metadata 与投递方式被忽略；已投递后仍可从消息投影识别，跨会话或跨类型复用报冲突（[reconcile/admit](../../opencode/packages/core/src/session/inbox.ts#L125-L223)）。
- **附件**（`blob`/`blob_ref`，`sql.ts:185-215`）：附件按内容哈希去重存入 blob 表，运行时用 `media:` 引用按需取字节，不再把 data URL 内联进消息历史。
- **ID**：`ses_` 使用降序编码（新会话排序在前），`msg_` 使用升序编码；编码主体是时间戳×0x1000 加进程内计数器，再补随机 base62（`packages/schema/src/identifier.ts:1-29`、`session-id.ts`、`session-message.ts:21-31`）。消息 id 可由事件 id 派生（`evt_` 前缀替换为 `msg_`）。

## 2. 事实源、事件与持久化

- **SQLite 唯一事实源**：服务端启动时对位于应用数据目录的会话库执行迁移，迁移文件放在 `packages/core/src/database/migration/`，运行期的会话读写都以这个库为准。
- **事件清单**：会话级事件覆盖创建、重命名、归档与反归档、移动、查看、权限、metadata 更新、fork 与删除；消息与执行事件覆盖内容更新、步骤生命周期、文本、推理、工具与 shell 进度、压缩、执行状态、inbox、用量和指令更新。完整事件名在 `packages/schema/src/session-event.ts` 定义：

  | 分组 | 事件名 |
  | --- | --- |
  | 会话 | `session.created`、`session.renamed`、`session.archived`、`session.unarchived`、`session.moved`、`session.viewed`、`session.permissions`、`session.metadata.updated`、`session.forked`、`session.deleted` |
  | 消息内容 | `session.message.content.updated` |
  | 步骤 | `session.step.started`、`session.step.streamed`、`session.step.ended`、`session.step.failed` |
  | 流式增量 | `session.text.*`、`session.reasoning.*`、`session.tool.*`、`session.shell.*`、`session.compaction.*`、`session.execution.*`、`session.inbox.*`、`session.usage.*` |
  | 指令 | `session.instructions.updated` |

- **投影与顺序**：投影器是全局节点（`projector.ts` 的 `makeGlobalNode`），按事件 `created` 与 seq 生成消息体与 part 行；`message-updater.ts` 负责把单个事件应用为 assistant 消息增量（文本、推理、工具状态、快照、重试）。事件顺序即持久化顺序。
- **执行恢复标记**：会话行的 `time_suspended` 记录执行 claim，`resume_attempts` 保存该忙碌期的自动恢复次数。执行开始时写入，成功、失败或用户中断时释放，关闭中断与进程死亡则保留；它承担重启恢复记录，不承担集群租约或跨进程执行互斥（[execution.ts](../../opencode/packages/core/src/session/execution.ts#L73-L143)、[store.ts](../../opencode/packages/core/src/session/store.ts#L68-L91)）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：客户端调用 `POST /api/session` 创建会话，服务端由 `Session.create` 处理并生成默认标题与 slug；请求若带上父会话，则继承父会话的 metadata 与权限（`protocol/src/groups/session.ts:165`、`core/src/session.ts:288`）。
- **切换 agent/model**：独立端点 `session.switchAgent`、`session.switchModel`，成功后追加 `agent-switched`/`model-switched` 消息并同步会话列。
- **移动与归档**：`session.move`、`session.update`（归档字段）；归档事件 `session.archived/unarchived`，列表默认过滤已归档。
- **删除**：`DELETE /api/session/:id` → `Session.remove`（`core/src/session.ts:391`），级联删除消息、part、inbox、blob 引用，并取消该会话的执行。
- **恢复语义**：消息逐步落库，异常退出后从 SQLite 恢复；未完成的 assistant 消息由 `incompleteAssistants` 识别（`history.ts:342`），执行中断会记录 `session.execution.interrupted`。
- **fork**：`POST /api/session/:id/fork` → `Session.fork`（`core/src/session.ts:339`），新会话记录 `fork_session_id` 与 `fork_boundary`，按边界复制消息并重映射消息 id 与附件引用。

## 4. 编辑、重试、续写、回退与分支

- **编辑**：消息正文随工具与文本事件追加，服务端没有整体改写已存消息的端点；用户要改自己的输入，就在客户端改写后重新提交。
- **重试**：自动重试由 runner 的 retry 逻辑承担（`core/src/session/runner/retry.ts`、`model-retry.ts`），失败原因写入 assistant 消息的 `retry` 字段；用户侧"重试"是再次 prompt。
- **续写**：继续 prompt 即可；`delivery: "steer"` 会插入当前轮，`"queue"` 在轮结束后投递（`packages/schema/src/session-inbox.ts:11`）。
- **回退是分阶段操作**：暂存、提交、撤销各有端点，流程由 `revert.ts` 实现（`core/src/session/revert.ts`、`protocol/src/groups/session.ts:470-499`）：

  1. 暂存：调用 `POST /api/session/:id/revert/stage` 记录目标消息与文件快照，写入 `session.revert` 字段，事件为 `RevertEvent.Staged`。
  2. 提交：调用 `revert/commit` 执行清理。
  3. 撤销：调用 `DELETE revert` 撤销暂存并恢复文件。

  回退按消息边界删除后续消息，不新建分支；分支用 fork 表达。
- **压缩**：`POST /api/session/:id/compact` 生成 compaction 消息（running → completed/failed），completed 支持本地摘要与 provider 原生窗口（`compaction.ts`、`history.ts` 的 native window 判定）；历史读取按压缩边界裁剪。

## 5. 列表、分页、搜索与定位

- **会话列表**：`GET /api/session` 支持按目录、父会话、搜索词和条数上限筛选，其中搜索只对会话标题做 `LIKE` 子串匹配（`protocol/src/groups/session.ts:126`、`store.ts:155`）。
- **消息读取**：`GET /api/session/:sessionID/message`（`protocol/src/groups/message.ts:102`），服务端从 `session_message` 分页读取并批量拼 part。
- **全局会话列表**：`GET /api/session/active` 与 stats 端点供首页和统计使用。
- **搜索边界**：本次未在会话核心找到消息正文的全文索引；检索能力集中在会话标题与目录/项目筛选。
- **消息内容渲染**：App 时间线对消息投影与虚拟化，见消息渲染器笔记。

## 6. 一致性、多窗口与并发写入

- 事件即写入：消息与 part 的更新与广播绑定在同一事件流，投影器顺序消费，避免写路径与广播路径分叉。
- 多客户端：SSE 全量广播，每个窗口独立投影；客户端本地还有按 server 维度的同步队列与 eviction（`packages/app/src/runtime/server/global-sync/`）。
- 并发：当前进程的运行协调器按会话合并唤醒与恢复请求，不同会话可并行；inbox 把受理与执行解耦，steer 在安全步骤边界投递，queue 在空闲边界一次推进一个。待投递条目可取消或调整投递方式。
- 崩溃恢复：遗留执行 claim 让启动恢复找到未结束的顶层会话，续跑次数持久记录，默认超过 10 次会终结；已执行的外部副作用可能重复。用户主动停止释放 claim，不会仅因停止事件在下次启动自动重启（[restart.ts](../../opencode/packages/core/src/session/execution/restart.ts#L24-L63)）。

## 7. 迁移、导入导出与保留策略

- **数据库迁移**：启动时由 `packages/core/src/database/` 执行；迁移集包含 v1 → v2 会话表的结构转换。
- **导入导出**：新增实验性端点 `session.export` 与 `session.import`（`packages/server/src/handlers/session.ts:122-145`），导出单会话的消息与元数据；CLI 侧保留导出入口（`packages/cli/src/commands/handlers/`）。
- **保留策略**：删除会话级联清理消息与 blob 引用；未被引用的 blob 由 blob 引用表约束，垃圾回收策略本次未找到独立实现。

## 8. Agent、模型与附件绑定

- 会话行保存 agent 与 model（含 variant），切换通过独立端点并产生切换消息；请求执行时以会话当前绑定为准。
- 附件进入 inbox 时即物化为 blob 引用，模型请求时按需读取；消息历史中保存的是引用而非字节。
- 权限规则集存会话行（`permission` 列），每轮执行时与 Agent 配置合并使用（见 Agent 工具与对话请求笔记）。

## 9. 设计取舍与已确认边界

- **事件溯源 + 投影**让流式、工具状态和 usage 都走同一条事件流，客户端能重放增量；代价是投影器必须严格按事件顺序处理。
- **回退分阶段**（stage/commit/clear）比直接删除更安全：用户可以先看文件差异再提交。
- **消息内容无全文索引**：长会话靠分页与客户端虚拟化。
- **附件按内容寻址**：天然去重，但读取需要额外的 blob 引用解析。

## 10. 未验证事项

1. durable 事件在断线重连、乱序与多窗口并发下的行为未实测。
2. provider 原生 compaction 的窗口回放未用真实 provider 验证。
3. 崩溃续跑（`time_suspended`/`resume_attempts`）与 `session.execution.interrupted` 的实际恢复效果未运行验证。
4. blob 附件的 token 成本与清理策略未实测。
5. 导入端点对未知字段与旧版本数据的兼容程度未验证。

## 11. 关键源码索引

- `packages/schema/src/session-message.ts`：消息联合、assistant 内容与工具状态
- `packages/schema/src/session-event.ts`：durable 事件定义
- `packages/schema/src/session-inbox.ts`：delivery 语义
- `packages/core/src/session/sql.ts`：会话库表结构
- `packages/core/src/session/{session.ts,store.ts,history.ts,projector.ts,message-updater.ts,revert.ts,compaction.ts}`：服务实现
- `packages/protocol/src/groups/{session.ts,message.ts}`：端点契约
- `packages/server/src/handlers/session.ts`：导入导出等处理器
- `packages/app/src/runtime/server/global-sync/`、`src/session/timeline/`：客户端同步与投影
