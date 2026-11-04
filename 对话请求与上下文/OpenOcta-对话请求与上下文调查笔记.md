# OpenOcta 对话请求与上下文调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态源码走读 + 检索，未运行构建与测试
>
> 调查范围：`chat.send` 的任务对象与状态机、转录历史加载与请求拼装顺序、模型与渠道交接、流式事件到 WebSocket 的映射、完成/异常/取消的回写、停止与审批续跑、同会话串行与跨会话并发、技能/MCP/知识库/附件注入点、退出与日志；会话 schema、界面交互与工具执行内部语义留给相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

一次生成是"WebSocket 方法调用 + 后台 goroutine + 会话级 TurnLoop"的组合。入口是 `chat.send`，任务身份是调用方传入的 `idempotencyKey`（缺省生成 UUID），并立刻成为 `runId`。请求返回 `{runId,status:"started"}` 之后，真正的执行在 goroutine 里跑，进度通过 `chat` 事件的 `state` 字段推给客户端。

关键事实：

- 上下文不是"内存中的会话对象"，而是每轮从 JSONL 转录重新水化；历史转换失败时整轮请求仍可继续，只是没有历史（`src/pkg/gateway/handlers/chat.go:2427-2452`）。
- 拼装顺序是固定的：运行时创建时构造系统提示与工具，随后每轮加载历史、合并当前输入，最后统一做工具轮修复（`src/pkg/agent/eino/event_bridge.go:20-47`、`tool_call_arguments.go:52-61`）。
- 同一会话键的请求是串行的，新消息默认"抢占"当前回合（在工具调用后生效）；不同会话并行，没找到全局并发上限（`src/pkg/agent/eino/session_turn_loop.go:221-249`、`src/pkg/agent/runtime/pool.go:57-139`）。
- 取消有两层：`ctx` 超时/取消让流循环退出，TurnLoop 的 `StopImmediate` 立即终止 agent；两者都由 `chat.abort` 或 `/stop` 触发（`chat.go:3258-3279`、`:3458-3515`）。
- 没有重试与重新生成。失败后用户重发就是新 `runId`；`chat.resume` 只用于工具审批中断后继续，不用于重放（`chat.go:3678-3840`）。

## 系统边界与生成任务主链

```text
WS chat.send（health.go:206-215 注册）
  -> 参数校验 / 命令分流 / 附件落盘（chat.go:1730-1899）
  -> runId = idempotencyKey，重复请求短路（:1893-1913）
  -> 同会话在飞检测 -> 等待运行时池 -> 用户消息追加（:1915-2002）
  -> 建中止控制器、Respond started（:2038-2051、:3168-3176）
  -> goroutine：模型工厂 -> 资源装配 -> 池内 Runtime（:2136-2379）
  -> 从转录水化历史 -> 组装 Request -> RunStreamTurn（:2420-2454）
  -> 流事件循环 -> 逐轮落盘 + 广播（:2644-2964）
  -> 收尾：IM/cron 投递、取消补写、更新会话快照（:2965-3164）
```

边界：消息如何被持久化与索引属于会话与消息管理；工具如何被发现、校验与执行属于 Agent 工具；流式文本如何渲染属于消息渲染器与 Chat UI。

## 1. 提交入口、任务对象与状态机

`chat.send` 的参数决定任务形状：`sessionKey` 缺省 `main`，`message` 为空且无附件时直接报错，附件最多一个（`chat.go:1732-1899`）。消息不是普通文本时先走命令分支：`/stop`、`!stop`、`/think`、`/new`、`/reset`（`:1744-1769`）。命令命中后不再走模型，或先重置会话再把剩余文本当新输入。

任务状态没有枚举字段，而是由三个东西共同表达：

| 载体 | 作用 |
| --- | --- |
| `ChatAbortController` | 保存 `Controller`（ctx 取消）、`TurnAbort`（TurnLoop 立即停）、会话键与起止时间 |
| `chatAbortControllers`（进程级 map） | 以 runId 索引在飞任务，用于去重、中止与"是否有在飞" |
| `chat` 事件 state | `delta` / `turn` / `final` / `complete` / `aborted` / `interrupted` / `a2ui` |

去重是精确匹配：同一 runId 且 sessionKey 相同，直接返回 `status:"in_flight"` 并附缓存标记（`chat.go:1901-1913`）。控制器在 `Respond` 之前注册，避免客户端收到 `started` 立刻 abort 却找不到任务（`:2039-2051`）。

超时来自三处优先级：请求参数 `timeoutMs`、配置/环境变量 `OPENOCTA_AGENT_RUN_TIMEOUT`、最后回退 600000 毫秒（`chat.go:2009-2035`）。引擎侧另有一个默认 10 分钟的回合预算，仅当 ctx 没有 deadline 时才生效（`src/pkg/agent/runtime/runtime.go:461-471`、`eino/runner.go:100-108`）。

## 2. 历史选择与请求拼装顺序

每轮请求的模型输入由四段合成，顺序稳定：

1. 系统提示：运行时创建时按"覆盖优先，否则内置模板"决定；内置模板包含身份、工具、命令执行约束、安全、工作区，再追加技能段、知识库段与进化提示（`src/pkg/agent/runtime/runtime.go:70-102`、`system_prompt.go:92-155`）。
2. 每轮覆盖：数字员工清单里的提示词，加上本地代理场景提示，作为 `SystemPromptOverrides` 直接替换系统提示而不是追加（`chat.go:2212-2226`）。
3. 历史消息：从当前会话转录读取，按角色白名单与最大条数裁剪后转成模型消息（`chat.go:2427-2452`、`transcript_history.go:103-121`）。
4. 当前输入：文本与附件块。

第 4 段有一个易误读的细节：用户消息在调用模型前已经写进转录，所以历史加载通常会包含它；`mergeCurrentRequestIntoHistory` 只在存在内容块时才动手，把附件块并入最后一条用户消息，避免重复一条文本（`event_bridge.go:49-74`）。纯文本消息因此不会重复，带附件时会"补齐"最后一条。

历史转模型消息做三件事：角色过滤（默认 user/assistant/toolResult）、按 `MaxMessages` 取尾部、重排工具轮。重排是为了修补"工具结果先于 assistant 工具调用行落盘"的乱序，同时给被中断的工具调用补占位结果（`transcript_history.go:131-172`、`tool_call_arguments.go:65-112`）。这是读侧修补，不改磁盘。

## 3. 预算、截断、摘要与压缩

预算只有一个来源：模型定义的上下文窗口。`TokenLimitForSessionHistory` 从 `models.providers[provider].models[].contextWindow` 取整数，取不到就是 0（`src/pkg/agent/model_factory.go:109-134`）。这个值进入运行时后变成上下文中间件的总预算。

中间件的默认阈值（`src/pkg/agent/eino/context_middleware.go:23-31`、`:46-121`）：

| 项 | 默认 | 用途 |
| --- | --- | --- |
| 总上下文 | 128000 token | 未配置窗口时的兜底 |
| 单个工具结果截断 | 8KB | `contextPruning.softTrim.maxChars` 可改 |
| 清理阈值 | 45% | 达到后清旧工具输出 |
| 摘要阈值 | 65% | 达到后触发摘要 |
| 保留后缀 | 4 条 | 清理时保留的 assistant 轮数 |
| 最少清理量 | 8000 token | 避免碎片化清理 |
| 预留下限 | 配置项 | `compaction.reserveTokensFloor` 压低两个阈值 |

实现分工：

- `reduction` 负责截断与清理旧工具输出，清理结果写到 `<stateDir>/agents/reduction`，可再读回。
- `summarization` 负责在阈值处总结，写入 `<stateDir>/agents/transcripts/conversation.jsonl`，这份文件与用户会话的 `<sessionId>.jsonl` 不是同一个。
- 两者都可用环境变量关闭；`compaction.mode == "off"` 只关摘要，不关清理（`context_middleware.go:96-107`、`:123-129`）。

会话级"压缩"是另一回事：`sessions.compact` 只按行数裁文件，不生成摘要（`src/pkg/gateway/handlers/sessions.go:880-1052`）。因此一次请求的上下文可能同时受"行级截断后的转录"和"运行中摘要"影响，两者不共享状态，也不可逆。

## 4. Provider、模型与协议交接

模型引用是 `provider/model` 字符串。来源优先级：请求参数 `modelRef`、agent 配置里的 model、全局默认；解析失败不回退到默认工厂，而是把错误写进转录并结束本次运行（`chat.go:2117-2175`）。

工厂按引用分派（`src/pkg/agent/eino/model_factory.go:183-292`）：

- 配置里显式声明了 provider，则按其 `api` 字段选择 Anthropic Messages 适配器或 OpenAI 兼容适配器，baseURL 与密钥来自配置。
- 未声明但在内置表里，则使用内置 baseURL 与 `<PROVIDER>_API_KEY` 环境变量，模型名可按 `<PROVIDER>_MODEL` 覆盖。
- 内置表覆盖 openrouter、moonshot、deepseek、groq、ollama、xunfei、volces_ark 等 25 个条目（`:26-52`）。
- 嵌入式模型走本地网关代理 `/api/embedded-models/v1`，用固定的本地密钥。

所有模型 HTTP 客户端显式禁用代理，超时 180 秒（`model_factory.go:106-123`）。上游是 SSE 流，这里不做二次缓冲，流由 Eino 迭代器逐块交给网关。

特殊路由：provider 为讯飞/星火且带图片附件时，换成讯飞图片理解工厂，绕开不支持 `image_url` 的 OpenAI 兼容端点（`chat.go:2176-2188`）。

## 5. 流式事件链与前端交接

Eino 事件先转成内部 `StreamEvent`，再由 `chat.send` 的循环翻译成两类输出：写文件的回合结果与推给前端的 `chat` 事件。

内部事件到前端状态的映射：

| 内部事件 | 前端 state | 附带内容 |
| --- | --- | --- |
| 文本增量 | `delta` | `text`，另有 `agent` 事件同名文本 |
| 思考增量 | `delta` | `reasoning` |
| A2UI | `a2ui` | 原始 A2UI 消息 |
| 一轮结束（tool_use / interrupt） | `turn` | 完整消息体，保留运行态 |
| 一轮结束（其他） | `final` | 完整消息体 |
| 运行收尾 | `complete` | 无消息体，触发历史刷新 |
| 中止 | `aborted` | 无消息体 |
| 审批中断 | `interrupted` | 工具名、参数、上下文 |
| 运行错误 | 无独立 state | 错误文本落盘后由 `complete` 收口 |

每条事件都带本 run 自增的 `seq`，由网关侧互斥计数器生成（`chat.go:287-298`、`:314-339`）。客户端按 sessionKey 相等性过滤，别的会话的事件进入后台状态（`ui/src/ui/controllers/chat.ts:495-522`）。

落盘与广播共用同一次翻译，但顺序有意区分：assistant 行先写文件再广播（`chat.go:2890-2931`）；工具结果行在 assistant 工具调用轮尚未落盘时先入队，等该轮写入后再补（`:2572-2595`）。推断：这是为了让文件里的顺序满足 provider 的 assistant→tool 契约，读侧的 `normalizeToolTurnMessageOrder` 是第二道保险。

部分文本被主动丢弃：泄漏的工具输出文本会被识别为工具结果而不是正文，A2UI 轮里的重复文本会被抑制（`chat.go:2661-2674`、`:960-973`）。

## 6. 完成、异常、半截流与最终回写

正常完成有三条路径：

- 消息流式结束：每轮 `message_stop` 都落盘一行 assistant，最终轮广播 `final`；循环结束后再做一次 IM/cron 投递（`chat.go:2818-2945`、`:2965-2991`）。
- 非流式回退：`RunStreamTurn` 不可用时调 `Run`，拿到整段文本后按带用量参数追加（`:2455-2553`）。
- 只拿到增量没有 `message_stop`：收尾时用快照函数 `publishAssistantSnapshot` 补一行（`:3048-3090`、`:998-1068`）。

异常与取消的收口方式不同：

| 场景 | 落盘内容 | 广播 |
| --- | --- | --- |
| ctx 取消 | 已累积内容作为 assistant 行，`stopReason:cancelled` | `aborted` |
| ctx 超时 | 同上去，`stopReason` 为超时原因 | 错误事件 |
| 运行错误事件 | 追加一条 assistant 文本 `[错误] ...` | `complete` |
| 模型无输出 | assistant 文本"模型未返回任何输出" | `complete` |
| 进程 panic | 先补写半截内容，再写 panic 文本 | `complete`（由 defer 发） |

每个 run 的 defer 都会删除控制器、停掉该 run 的浏览器实例、取消 ctx 并发 `complete`（`chat.go:2086-2095`）。因此前端最可靠的"结束"信号是 `complete`，而不是 `final`。

用量有两条记录线：消息体里的 `usage` 来自流式事件，用于展示；`token_usage` 旁路行来自 Eino 全局回调，用于成本统计，两者可能不完全一致（`chat.go:2862-2869`、`eino/usage_callback.go:207-240`）。

## 7. 停止、重试、续写与重新生成

停止有三个入口：消息里的 `/stop` 或 `!stop`、`chat.abort` 带 runId、`chat.abort` 不带 runId（中止该会话全部）。执行动作一致：调用 `TurnAbort`（TurnLoop 立即停），再调 ctx 取消，最后从 map 删除（`chat.go:3282-3294`、`:3458-3515`、`:3258-3279`）。

runId 与会话键不匹配时只记警告仍允许停止，理由写在注释里：runId 已唯一标识运行实例（`chat.go:3496-3501`）。

`chat.abort` 的响应可能在 `aborted` 事件之前返回，所以前端会先本地清空运行态，再等网关事件（`ui/src/ui/controllers/chat.ts:472-493`）。

续写就是再次发送：历史从文件重读，内存不保留对话，因此不存在"上次没写完继续"的专用接口。重新生成与重试本次未找到：在 `src/pkg/gateway/handlers`、`src/pkg/agent`、`ui/src/ui/controllers` 检索 retry/regenerate/resend/replay，除配置类错误提示外无命中。失败消息的"重试"是用户复制后再发，形成新 runId 与新消息行。

`chat.resume` 的唯一用途是审批中断后继续：它按 runId 与中断上下文恢复 TurnLoop，不重放历史（`chat.go:3678-3840`）。审批发生在 `execute` 工具首次调用前，用 Eino 的 `StatefulInterrupt` 挂起；批准则用暂存参数继续，拒绝则把拒绝理由当工具结果返回（`src/pkg/agent/eino/approval_middleware.go:50-85`）。

## 8. 队列、多会话并发与后台生成

并发模型是"每会话一把锁 + 每 run 一个 goroutine"：

- 池条目按会话键建，条目互斥锁在运行期间持有，同一键的第二个请求会阻塞在 `Acquire`，直到前一个释放（`src/pkg/agent/runtime/pool.go:73-105`）。
- 发送入口在 `Acquire` 之前先探测在飞状态并等待可用；等待分两段，各 5 秒，仍占用就清出池条目再试，失败返回"会话运行时仍忙"（`chat.go:3182-3209`）。
- 没找到全局并发上限或队列：不同会话各自建 Runtime，数量随活跃会话增长。

再次发送的语义是"抢占"而不是排队。检测到同键有在飞任务时，新一轮以 `preempt=true` 推入 TurnLoop，Eino 在工具调用之后的安全点中断上一轮；若走的是旧路径，则直接取消上一轮再等池（`chat.go:1915-1935`、`session_turn_loop.go:221-249`）。

后台生成没有独立调度器：cron 与渠道消息复用同一 `chat.send`，只是会话键不同；cron 的会话条目在模型调用前先建好，运行结束写结果文件（`chat.go:1787-1795`、`:2986-2991`）。

## 9. Agent、工具、知识库与附件注入点

本次运行的能力在 `runtime.Options` 里一次性装配，随后被池缓存：

| 能力 | 注入点 | 备注 |
| --- | --- | --- |
| 内置工具 | `tools.DefaultToolsWithInvoker` 加本地代理工具 | 每次新建 Runtime 时构建 |
| MCP 工具 | 配置合并 + 请求级 `resources.mcpServers` 过滤 | 同时建 Eino 侧 MCP 管理器 |
| 技能 | 技能目录 + 请求级 `skillKeys` 过滤 | 中间件把技能说明注入系统提示 |
| 知识库 | `memory_search` 工具与知识库提示段 | 只覆盖 Vault 文档，不含会话历史 |
| 浏览器 | 按配置注册，运行时按工具名标记 | 收尾时按 runId 关闭 |
| 子代理 / swarm | 开关打开时追加 swarm 工具 | 与会话键命名空间联动 |
| 联网搜索 | 代码中显式关闭 | `chatRunEnableWebTools` 恒为 false |

请求级资源的影响面被写进运行指纹，指纹变化会丢弃池中旧 Runtime（`chat_runtime_pool.go:15-46`）。这意味着"换技能再问一句"会触发一次冷启动。

附件有两条注入路径：写入 `Request.ContentBlocks` 供本轮使用；写入转录的图片块供下一轮水化。两者都由同一份 base64 解码而来（`chat.go:2384-2426`、`:1949-1985`）。

## 10. 退出恢复、日志与已确认边界

进程内状态不持久化：中止控制器、池、事件序号都随进程消失。持久化的只有转录、`sessions.json`、checkpoint 与运行时历史文件。

Checkpoint 存在 `<stateDir>/checkpoints/<id>.cp`，写入用临时文件加改名保证原子性（`src/pkg/agent/eino/file_checkpoint_store.go:18-60`）；检查点 ID 就是 sessionId。重置与删除会清掉对应检查点（`chat.go:387-394`、`runtime.go:280-287`）。

**重启后续跑本次未找到**：checkpoint 提供的是 Eino 中断/恢复所需的状态，但没有任何启动扫描逻辑把"上次未完成的 run"重新推入 TurnLoop。检索范围 `src/pkg/agent/eino`、`src/pkg/gateway`、`src/pkg/daemon`，关键词 resume/restore/recover/checkpoint。

可观测性主要靠日志与转录旁路行：网关日志携带 sessionKey 与 runId，池的获取/等待/释放都有耗时日志（`pool.go:73-139`、`chat_runtime_pool.go` 调用点）。没有独立的 trace 或指标导出。

已确认的边界：

- 系统提示覆盖是替换而非拼接，员工提示会把内置安全段一起换掉（`runtime.go:72-86`）。
- 纯文本回合的"当前输入"依赖先落盘再水化，若历史加载被配置关闭，这一轮就只剩历史没有新输入（`chat.go:2428-2452`）。
- 上下文摘要写在运行时的独立转录文件，不回流到会话 JSONL，因此换设备或重开会话看不到摘要痕迹。
- 工具结果先入队再补写的顺序修正只覆盖 `tool_use` 轮；其他半截情况依赖读侧修补。

## 11. 未验证事项

1. 抢占在"工具执行中"与"模型流式中"两种时机的实际中断点未实测；代码只声明在工具调用后生效。
2. 等待池的两段 5 秒加上清池重试在高并发下的表现未验证。
3. `stopReason` 在多次 `message_stop` 间的覆盖顺序未做运行验证；代码只保证每轮取当前事件的值。
4. 讯飞图片理解路由的实际协议差异未验证。
5. 摘要中间件与大上下文模型组合时的阈值行为未实测。
6. 附件较大时转录体积、`chat.history` 读取耗时与 32MB 单行上限的相互作用未实测。
7. 审批中断后客户端刷新页面再 `chat.resume` 是否仍能命中检查点未验证。

## 12. 关键源码索引

- `src/pkg/gateway/handlers/chat.go`：`ChatSendHandler`（`:1730-3177`）、流式状态映射（`:2644-2964`）、停止与恢复（`:3258-3530`、`:3678-3840`）
- `src/pkg/gateway/handlers/chat_runtime_pool.go`：运行指纹与 MCP 合并
- `src/pkg/agent/runtime/runtime.go`：运行时装配、RunStreamTurn、中止与清理
- `src/pkg/agent/runtime/pool.go`：会话级串行与等待
- `src/pkg/agent/eino/session_turn_loop.go`：TurnLoop、抢占、中断与恢复
- `src/pkg/agent/eino/event_bridge.go`：消息拼装与事件转换
- `src/pkg/agent/eino/transcript_history.go`、`tool_call_arguments.go`：历史转换与工具轮修复
- `src/pkg/agent/eino/context_middleware.go`：预算、截断、摘要
- `src/pkg/agent/eino/model_factory.go`：Provider/模型/协议适配
- `src/pkg/agent/eino/approval_middleware.go`、`usage_callback.go`
- `src/pkg/agent/stream/event.go`：内部流事件契约
- `ui/src/ui/controllers/chat.ts:308-545`：发送、停止与事件处理
