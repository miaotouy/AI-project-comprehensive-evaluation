# OpenOcta 会话与消息管理调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态源码走读 + 检索，未运行构建与测试
>
> 调查范围：会话键与 sessionId、消息 JSONL 形状、`sessions.json` 索引与落盘时机、创建/重置/修改/删除/压缩、列表与预览、并发写入与版本兼容、会话级外部对象绑定；请求执行、流式渲染与界面工作流分别留给对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 没有数据库。会话的事实源是两层文件：每个 agent 一份 `sessions.json` 索引（键 → 会话条目）加每个会话一份 `<sessionId>.jsonl` 追加日志。会话键是带语义的命名空间字符串（`agent:<id>:...`、`custom:<uuid>`、渠道组键、员工键、cron 键），条目里的 sessionId 才是 UUID，并决定转录文件名。

关键事实：

- 消息是线性追加日志，不是树。每条消息行确实写了 `parentId`，但读取路径从不使用它，只按文件顺序取最后 N 条（`src/pkg/session/transcript.go:258-309`）。
- 写入粒度是"回合/片段"：用户消息在请求前追加一次；assistant 内容在每次 `message_stop` 追加一行；工具结果单独作为 `toolResult` 行追加（`src/pkg/gateway/handlers/chat.go:2780-2806`、`:2890-2899`）。
- 消息追加没有会话级文件锁。池条目锁仅约束同一个 Runtime；超时驱逐先删映射、再等待旧锁释放后关闭，期间同键新旧 run 可能并行并追加同一转录（[pool.go:193–209、237–247](<../../openocta/src/pkg/agent/runtime/pool.go#L193>)、[chat.go:3182–3208](<../../openocta/src/pkg/gateway/handlers/chat.go#L3182>)）。
- 同一份 JSONL 还承载 `token_usage` 与 `tool_call` 旁路行，由 Eino 全局回调写入，只服务成本与工具统计，不参与上下文（`src/pkg/agent/eino/usage_callback.go:207-262`）。
- 无消息级编辑、删除、重试、重新生成与分支能力：本次在 `src/pkg/gateway/handlers`、`src/pkg/session`、`ui/src/ui` 检索 edit/delete/retry/regenerate/fork/branch，未找到对应入口（`apiKeys.regenerate` 是密钥接口，不相关）。
- `/new`、`/reset` 的语义是换一个新 sessionId 与新 JSONL 文件，旧文件留在磁盘上；"压缩"只是按行数保留尾部并归档原文件，不做摘要（`chat.go:1661-1727`、`sessions.go:880-1052`）。

## 系统边界与数据主链

```text
sessions.create / sessions.ensure（写索引 + 建空 JSONL）
  -> chat.send 前追加 user 行（chat.go:1945-2002）
  -> 每次 message_stop 追加 assistant 行（chat.go:2890-2899）
  -> 工具结果以 toolResult 行追加（chat.go:2780-2806）
  -> 旁路 token_usage / tool_call 行（usage_callback.go:226-260）
  -> chat.history 全量读文件后取最后 N 条（chat.go:1556-1657）
  -> sessions.list 合并各 agent 索引并补 token 统计（sessions.go:1923-2270）
  -> sessions.delete / sessions.compact 改索引或改文件（sessions.go:668-771、:880-1052）
```

边界：一次请求如何拼装上下文、调用模型与流式回写属于对话请求与上下文；侧栏、搜索面板与消息气泡交互属于 Chat UI。本笔记只回答"保存了什么、谁改写了它、重开后如何恢复"。

## 1. 会话单位、标识与键空间

会话由"键 + 条目"构成。键回答"这是谁跟谁的哪个上下文"，条目提供 sessionId 与文件名。条目结构见 `src/pkg/session/store.go:16-30`：

| 字段 | 含义 |
| --- | --- |
| `sessionId` | UUID，转录文件名主干，也是运行时 checkpoint 的 ID |
| `updatedAt` | 毫秒时间戳，列表排序与 activeMinutes 过滤依赖它 |
| `sessionFile` | 通常为 `<sessionId>.jsonl`，可带目录外的相对路径 |
| `label` / `pinnedAt` | 用户命名与置顶时间 |
| `channel` / `chatType` | 来源渠道与私聊/群聊类型 |
| `thinkingLevel` / `verboseLevel` | 会话级生成偏好 |
| `spawnedBy` | 子会话来源 |
| `systemPromptReport` / `skillsSnapshot` / `tools` | 一次运行后写入的快照，供 UI 与下一轮参考 |

键的规范化集中在 `src/pkg/gateway/handlers/sessions.go:1097-1174`。`agent:<agentId>:<rest>` 被保留为规范键；裸键补成 `agent:main:<key>`；`custom:` 前缀原样保留；查找时还会尝试去掉 `agent:<id>:` 后的裸值，以兼容渠道与工具写入的旧键。agentId 从键的第二段解析（`src/pkg/agent/model_factory.go:15-24`），没有该段则归 `main`。

sessionId 的来源有三档：参数显式传入、`sessions.json` 条目、以及从键推导。推导规则是取键的第三段做字符清洗（`src/pkg/agent/tools/sessions.go:16-32`），清洗器把非法字符换成 `-` 并要求匹配 `^[a-z0-9][a-z0-9._-]{0,127}$`（`src/pkg/session/paths.go:20-53`）。因此会话键与 sessionId 不是一一映射：多个键可以指向同一文件，而同一键在条目缺失时会退化出派生 ID。

会话键的语义前缀在 UI 侧也有对应判定，用于区分 swarm、子代理、acp、员工、cron 等会话（`ui/src/ui/sessions/session-key-utils.ts:40-153`）。

## 2. 消息模型与 JSONL 形状

文件首行是头，之后每行一条消息或一条旁路记录（`src/pkg/session/transcript.go:14-20`、`:258-264`）：

```text
{"type":"session","version":2,"id":"<sessionId>","timestamp":"<RFC3339>"}
{"type":"message","id":"<8位>","parentId":"<上一行id>","timestamp":"<RFC3339>","message":{...}}
```

`message` 内的角色是 `user`、`assistant`、`toolResult`，字段包括 `content`、`timestamp`、`usage`、`stopReason`、`provider`、`model` 以及四类耗时（`src/pkg/session/transcript.go:23-39`）。工具结果行额外带 `toolCallId`、`toolName`、`isError`。

内容块是一个宽松结构，覆盖文本、思考、图片、视频、文件、工具调用与 A2UI（`transcript.go:42-55`）。它的反序列化接受两种图片形状：扁平 `mimeType`/`data`，以及来自附件工具的嵌套 `source`（`:57-86`）。写入侧与读取侧的块类型对照如下（`src/pkg/gateway/handlers/chat.go:510-658`）：

| 持久化 type | 客户端 type | 关键字段 |
| --- | --- | --- |
| `text` | `text` | `text` |
| `thinking` | `thinking` | `thinking` |
| `image` / `video` | 同名 | `source{type:"base64",media_type,data}` |
| `file` / `document` / `attachment` | `file` | `mimeType`、`filename` |
| `toolcall` 等四种写法 | `toolCall` | `id`、`name`、`arguments` |
| `toolresult` | `toolResult` | `name`、`text`、`isError` |
| `a2ui` | `a2ui` | 原始 JSON |

关于"树"：写消息时确实把上一行的短 id 填入 `parentId`（`chat.go:1042-1052`、`:2780-2806`、`:2890-2899`），但 `ReadTranscriptMessages` 与预览读取都不解析该字段，重建历史时按行序切片。推断：这是为兼容外部格式保留的元数据；当前活动路径只有一条，版本切换不在可执行路径上。

`token_usage` 与 `tool_call` 行不在消息读取的转换里，`ReadTranscriptMessages` 会尝试把它们当 `TranscriptMessage` 解析，因缺少 `role` 而被丢弃；成本统计则单独扫描（`src/pkg/session/usage.go:322-441`）。

## 3. 事实源、索引与持久化时机

权威源全部是本地文件，目录由状态目录推出：`<stateDir>/agents/<agentId>/sessions/`，索引固定叫 `sessions.json`（`src/pkg/session/paths.go:56-63`、`store.go:36-39`）。配置项 `session.store` 可覆盖索引路径，但默认转录目录仍按 agent 推导，两者只在条目带 `sessionFile` 时对齐。

写入时机分三类：

- 索引写入是整文件重写。`updateSessionStore` 读全量、调用回调修改、再 `MarshalIndent` 覆盖（`sessions.go:1177-1198`）；`SaveSessionStore` 同样整体写（`store.go:97-109`）。
- 用户消息在模型调用前落盘，避免请求失败丢失输入（`chat.go:1945-2002`）。
- assistant 内容在每轮结束时落盘，工具调用轮与最终轮各一行；被取消时用快照函数补写半截内容（`chat.go:998-1068`、`:2993-3046`）。

`updatedAt` 的刷新有两套：普通 Web 会话在追加用户消息后按 sessionId 找到条目并 touch（`store.go:113-148`、`chat.go:1996-2001`）；cron 会话则在发送前用规范键建立条目，运行结束后再更新（`chat.go:1787-1795`、`:1458-1496`）。

## 4. 创建、切换、重命名、置顶、删除与清理

创建有两条路径。`sessions.create` 每次生成新 UUID，键为 `custom:<uuid>`，缺省标题按"自定义会话N"递增（`sessions.go:227-282`）。`sessions.ensure` 幂等：先按候选键查条目，存在就返回 `created:false`，否则写入 `channel:"webchat"` 的条目并建空文件，供数字员工在首条消息前就出现在侧栏（`sessions.go:300-389`、`ui/src/ui/controllers/sessions.ts:30-59`）。

修改与置顶都走 `sessions.patch`。解析层接受模型、发送策略、执行级别等字段，但真正写回条目的只有标题、思考级别、详细级别、来源和置顶时间（`sessions.go:2323-2362`）——其余参数目前只出现在请求结构中。条目缺 sessionId 时，patch 会懒创建 UUID。

重置（`sessions.reset`）与聊天里的 `/new`、`/reset` 做同一件事：保留标题、渠道、聊天类型与两个级别，换新 UUID 与新文件，清掉旧会话的运行时历史与 checkpoint，并中止在飞运行（`sessions.go:585-665`、`chat.go:1661-1727`、`:3297-3379`）。

删除有三层保护与三种清理范围：

- 主会话键拒绝删除（`sessions.go:700-706`）。
- 默认同时删转录文件；`deleteTranscript:false` 可只删索引。
- 删除后中止该键的运行并清出运行时池（`sessions.go:759-761`）。
- 员工删除会按 `employee:<id>` 与 `employee-<id>` 匹配清理全部相关键（`sessions.go:775-826`）；swarm 工作区删除按成员键与显式键清理（`:829-877`）。

返回结构里的 `archived` 字段名容易误解：它列出的是被 `os.Remove` 永久删除的路径（`sessions.go:1348-1354`），不是归档副本。真正的归档只发生在压缩：原文件重命名为 `<file>.bak.<时间戳>`（`:1356-1364`）。

## 5. 编辑、重试、续写、回退与分支语义

当前快照没有消息级改写能力。`chat.inject` 是唯一的"补写"入口：它追加一条 `role:"assistant"` 的消息，标记 `stopReason:"injected"`、用量全零，并向客户端广播 final（`chat.go:3518-3620`）。它不参与"重试上一条"，也不修改历史行。

续写就是继续发送。历史从转录重读，不在内存里累积对话；`/new` 之后是全新文件，因此没有"回退到某条消息再分支"的路径。

分支的替代物是会话复制，但本次未找到实现：`src` 与 `ui/src` 中检索 fork/branch/duplicate/clone，除 swarm 成员树与目录树组件外无命中。

压缩（`sessions.compact`）是文件级截断：默认保留最后 400 行，超过才归档原文件并重写（`sessions.go:900-1051`）。它按行而不是按回合，可能把一条消息的上下文切成两半；截断后 `updatedAt` 会刷新，但条目里的 token 快照不重算。推断：压缩后首轮请求的转录历史会从半截开始，模型侧看到的对话起点因此改变。

## 6. 列表、预览、分页与检索

列表是"全量读入内存后过滤"。`sessions.list` 合并各 agent 的索引（单文件配置时只读一份），再做键过滤、字段过滤、排序与截断（`sessions.go:1787-1831`、`:1923-2270`）：

- 过滤：cron 单次运行键默认排除；`global`/`unknown` 需显式包含；可按 agentId、spawnedBy、label 过滤。
- 排序：置顶优先（`pinnedAt` 大者在前），其次 `updatedAt` 降序；`limit` 在排序之后才截断。
- 补全：每行按条目 sessionId 找到转录并累计 token；可选补"首条用户消息派生标题"和"最后一条消息摘要"，这两项都要再读一次文件。

搜索只覆盖元数据：显示名、label、subject、sessionId 与会话键，全部是大小写不敏感子串匹配（`sessions.go:2184-2209`）。**消息内容全文检索本次未找到**：在 `src/pkg/session`、`src/pkg/gateway`、`src/pkg/agent/knowledge`、`ui/src` 检索 search/query/FTS/index，只看到上述元数据匹配、`sessions.preview` 的尾部预览，以及一个仅被测试引用的历史检索函数（`src/pkg/agent/knowledge/history.go:17`，调用方仅有 `history_test.go`）。系统提示与工具策略里出现的 `session_search` 没有对应的 Go 注册实现（`src/pkg/agent/runtime/knowledge.go:32-47`、`ui/src/ui/agents/tool-policy.ts:20`）。

预览与会话列表分开取数。`sessions.preview` 对每个键最多 64 个，读转录文件最后 64KB、最近 50 行，按时间正序返回角色与截断文本，默认 12 条、每条 240 字符（`src/pkg/session/preview.go:18-114`、`sessions.go:441-499`）。

消息读取没有游标分页。`chat.history` 读整个文件、丢掉解析失败行，再取最后 N 条；默认 100，超过 1000 按 100 处理（`chat.go:1556-1657`）。界面固定请求 500 条（`ui/src/ui/controllers/chat.ts:246`、`:266-287`）。文件读取上限是单行 32MB（`transcript.go:110-113`），超长工具输出会整行失败而不是截断。

## 7. 缓存、一致性、并发写入

索引层没有锁：`updateSessionStore` 是读—改—写。按实现结构推断，多个渠道与界面同时 touch 或修改索引时可能后写覆盖先写。转录使用追加写，和索引覆盖是两条独立路径；追加写本身未提供会话级事务或消息顺序保证。

池条目锁仅约束同一个 Runtime 的运行期。发送入口发现同键在飞任务时，先等池最多 30 秒，超时便驱逐映射，随后再检查最多 5 秒；此分支未先取消旧 run。驱逐只立即删除映射，旧条目持锁时要等运行结束释放锁后才关闭，因此新 Runtime 可在旧 run 仍运行时建立。跨会话可以并行，同键也存在新旧条目重叠的路径（[chat.go:1915–1935、3182–3208](<../../openocta/src/pkg/gateway/handlers/chat.go#L1915-L1935>)、[pool.go:193–209、237–261](<../../openocta/src/pkg/agent/runtime/pool.go#L193-L209>)）。

抢占标记作用于接收请求的 TurnLoop；驱逐后交给新 Runtime 的标记无法停止旧 Runtime。由此推断，同键新旧 run 可能向同一 JSONL 追加消息，交错顺序及同检查点 ID 的写入结果需运行验证。池还会按运行指纹失效重建：指纹包含工作区、agent、员工、模型、MCP 键、技能键与系统提示版本；指纹变化同样移除旧映射并延后关闭忙条目（[session_turn_loop.go:221–248](<../../openocta/src/pkg/agent/eino/session_turn_loop.go#L221-L248>)、[pool.go:85–100](<../../openocta/src/pkg/agent/runtime/pool.go#L85-L100>)、[chat_runtime_pool.go:15–46](<../../openocta/src/pkg/gateway/handlers/chat_runtime_pool.go#L15-L46>)）。

运行态明确不持久化：`runId`、中止控制器、池条目、事件序号都在进程内存里（`chat.go:239-251`）。进程退出后这些状态消失，文件里保留的只有已追加的消息。

## 8. 迁移、版本与导入导出

转录头写死版本 2（`transcript.go:107-109`），但读取只判断首行 `type=="session"` 就跳过，既不校验也不迁移（`:284-290`）。未知字段依靠 `json.Unmarshal` 的默认忽略行为兼容；解析失败的整行被丢弃（`:299-306`）。

`sessions.json` 没有 schema 版本字段，条目缺字段按零值处理。索引损坏会导致整个 store 读取失败：`LoadSessionStore` 在 JSON 错误时返回错误而不是空表（`store.go:41-58`），调用方多按"读失败即空"或"跳过该 agent"处理。

导入、备份恢复与跨版本迁移工具本次未找到：在 `src/pkg/session`、`src/pkg/gateway/handlers`、`src/cmd` 检索 export/import/migrate/backup，只看到 `sessions.compact` 的本地 `.bak` 归档与删除接口返回的路径列表。

## 9. Agent、模型、技能与附件绑定

模型不是会话字段。列表行展示的 provider/model 由"键 → agentId → agent 配置或默认模型"实时解析，缺省是 `anthropic` 与 `claude-sonnet-4-5-20250929`（`sessions.go:1247-1301`、`:2062-2070`）。这意味着换模型配置会立刻改变旧会话的展示与下一轮请求。

会话级真正持久化的生成偏好只有 thinking 与 verbose 两级，`/thinking` 命令会直接写条目（`chat.go:3382-3455`）。

运行后快照：`updateSessionAfterRun` 把技能快照写回条目，并在可用时写入系统提示报告与工具列表（`chat.go:1458-1496`）。这些是"上次运行用了什么"的记录，下一轮仍会重建，不当作配置输入。

附件采用双份：解码后写到 `<projectRoot>/attachments/<文件名>`，同时把 base64 塞进用户消息的内容块，因此转录会随图片体积增长（`chat.go:1807-1881`、`:1949-1985`）。消息体积与重放成本属于未验证项。

## 10. 设计取舍与已确认边界

- 文件即数据库：索引与转录分离，索引可重建（缺条目时按键派生 ID），但没有索引自愈过程；条目丢失会让同一段对话换一个文件名。
- 追加日志优先：写入简单、崩溃后最多丢最后一行；代价是没有原位编辑、分支与版本切换。
- 会话键承担路由：一个键同时决定存储位置、agent、运行时池分片与前端订阅；键格式变化会同时影响这四层。
- 池互斥属于条目级控制。驱逐会立即移除映射、延后关闭忙条目，同键新旧运行可能重叠；追加转录和同 ID 检查点没有因此获得全局串行保证。
- 删除与归档语义不一致：删除接口的 `archived` 字段实际是永久删除，真正的归档只在压缩时产生。
- 压缩是行级截断而非语义摘要：模型侧上下文压缩另有机制（见对话请求与上下文笔记），两者不共享状态。

## 11. 未验证事项

1. 并发 `sessions.patch` / touch 的实际丢失范围未做运行验证；结论基于读—改—写实现推断。同键旧 run 超过首次 30 秒等待、驱逐后新 run 启动的重叠时长，以及转录追加顺序、检查点覆盖和最终索引快照尚未运行验证。
2. 压缩把消息切成半截后，模型对首条残缺消息的处理未实测。
3. 转录单行超过 32MB 时的界面表现（整行丢弃）未实测。
4. 多窗口同时打开同一会话、以及 WebSocket 重连后 `chat.history` 与本地流的合并未验证。
5. `session.store` 指向自定义路径时，旁路 `token_usage` 行仍写入默认 agent 目录（`usage_callback.go:183-191`），对成本统计的影响未验证。
6. 旧版 `~/.openclaw/sessions` 兼容路径（`sessions.go:1337-1344`）在真实升级场景中的命中率未验证。

## 12. 关键源码索引

- `src/pkg/session/store.go`：条目结构、索引读写与 touch（`:16-30`、`:97-148`）
- `src/pkg/session/transcript.go`：JSONL 形状、追加与读取（`:107-135`、`:240-309`）
- `src/pkg/session/preview.go`、`src/pkg/session/usage.go`：尾部预览与成本汇总
- `src/pkg/gateway/handlers/sessions.go`：sessions.* 全量入口、键解析、列表与压缩
- `src/pkg/gateway/handlers/chat.go`：`chat.history`、`chat.send` 的落盘点、`chat.inject`、`/new`
- [pool.go:57–139、193–261](<../../openocta/src/pkg/agent/runtime/pool.go#L193-L261>)、[chat.go:3182–3208](<../../openocta/src/pkg/gateway/handlers/chat.go#L3182-L3208>)：条目互斥、超时驱逐与延后关闭
- `src/pkg/agent/eino/transcript_history.go`：转录转模型消息与工具轮次序修正
- `src/pkg/agent/tools/sessions.go`：`SessionIDFromSessionKey`
- `src/pkg/gateway/ws/hub.go:74-112`：会话与聊天方法/事件清单
- `ui/src/ui/controllers/sessions.ts`、`ui/src/ui/sessions/session-key-utils.ts`：前端取数与键判定
