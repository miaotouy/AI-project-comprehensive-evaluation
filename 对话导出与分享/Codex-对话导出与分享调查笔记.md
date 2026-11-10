# Codex 对话导出与分享调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：静态源码调查；读取 TUI `/export` 的弹窗、取数与渲染实现，rollout 录制与持久化策略，`codex exec` 参数与 JSONL 事件定义，app-server 线程读取/分页协议，以及会话列表、恢复、分叉、回退和 Claude Code 迁移入口；未构建或运行 CLI/TUI
>
> 调查范围：会话落盘与回放、Markdown 导出、`codex exec` 结构化输出、app-server 历史读取、fork/revert/import 的往返与分支语义；不覆盖消息渲染细节、请求上下文拼装、整库备份、模型请求口径与云端任务页面
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Codex 没有统一的 CLI 导出子命令，也不提供远端分享。交互界面里只有一条由用户触发的 Markdown 导出命令。与对话交付相关的能力分成三条互不相同的链路：

1. **运行时持久化**——每次会话按线程写成 rollout JSONL，供恢复、分叉、线程列表和调试使用。它是内部事实源，不是面向用户的导出格式，写入前会过滤事件并对大输出截断。
2. **面向阅读的交付**——交互界面提供 `/export`，把整条线程渲染成 Markdown，复制到剪贴板或写入文件。这是唯一由用户主动触发、可交付给他人的产物。
3. **面向自动化的输出**——`codex exec --json` 把 Agent 侧事件写成 stdout JSONL，`-o` 保存最后一条消息，`--output-schema` 约束最终消息为结构化 JSON；app-server 则向 IDE/客户端提供分页读取线程历史的 RPC。

按本类目的分型，Markdown 导出落在 E2 阅读交付，是该类型里的一处窄实现；rollout 与 exec --json 落在 E1 数据交换，处于事件与日志一侧。E3 图片分享、E4 链接分享、E5 发布与研究这三类，本次均未找到对应实现。导入侧只有从 Claude Code 到 Codex 的单向迁移，尚无通用的往返路径。

三种口径的差异是本次调查的核心：同一段对话在 rollout、Markdown 和 `exec` 事件流中保留的字段并不相同，不能互相替代。

## 系统边界与完整主链

```text
持久化：core Session::persist_rollout_items
  -> RolloutRecorder 追加 JSONL（策略过滤、大输出截断、按日期分目录）

回放：codex resume / exec resume
  -> RolloutRecorder::get_rollout_history
  -> InitialHistory::Resumed -> 重放 items 重建上下文

阅读交付：TUI /export
  -> app-server thread/read（仅元数据）
  -> 分页补齐完整 turns/items（旧服务端回退 include_turns）
  -> visible_export_items 过滤
  -> thread_items_to_transcript_cells + render_markdown_transcript
  -> 剪贴板 或 write_transcript（拒绝覆盖）

自动化：codex exec --json
  -> EventProcessorWithJsonOutput 逐行打印 ThreadEvent
  -> 可选 -o 最后消息、--output-schema 结构化最终消息

外部读取：app-server thread/turns/list + thread/items/list（游标分页）
```

分享服务、公开页面、访问令牌与撤销都不在本仓库出现。本仓库能确认的交付终点只有本机文件、系统剪贴板和本地 app-server 连接。

## 1. 入口、目标与导出源

| 入口 | 触发者与目标 | 导出源与粒度 | 交付终点 |
|---|---|---|---|
| `/export` | 用户主动；个人存档或转给别人阅读 | 当前线程的全部可见条目，无选区、无单条、无范围 | 剪贴板或 Markdown 文件 |
| `codex exec --json` | 脚本/CI；机器消费 | Agent 侧事件流（不含用户消息条目） | stdout 逐行 JSON |
| `codex exec -o FILE` | 脚本；取最终答复 | 最后一轮 Agent 消息 | 文件 |
| `codex exec --output-schema` | 脚本；结构化结果 | 最终消息的 JSON 形状 | stdout/最后消息 |
| app-server `thread/read`、`thread/turns/list`、`thread/items/list` | IDE 或外部客户端 | 线程元数据、按 turn/item 分页 | 协议响应 |
| `/rollout` | 用户；定位原始文件 | 仅打印 rollout 路径 | 屏幕文本 |
| `/import` | 用户；从 Claude Code 迁移 | 外部会话、配置、项目与近期会话 | 新建本地线程 |
| `codex resume` / `codex fork` | 用户；继续或分叉 | 既有 rollout 的全部条目或某个 turn 之前的前缀 | 新会话状态 |

用户在会话中触发 `/export` 后，弹窗给出两个去处：复制到剪贴板，或保存为文件，文件名默认为 `codex-session-<thread-id>.md`。该命令登记在斜杠命令表中，说明文字为“export the conversation as markdown”；Android 上剪贴板一项被禁用，只剩文件目标，任务进行中同样可以执行导出（`codex-rs/tui/src/slash_command.rs:51,112,248-269`、`codex-rs/tui/src/chatwidget/transcript_export.rs:8-63`）。

没有 `codex export` 子命令：子命令枚举（`codex-rs/cli/src/main.rs:145-245`）只有 exec、resume、fork、archive、delete、migrate-rollouts、cloud 等，没有导出项。全仓库出现的 `export` 多数是 TypeScript/JSON Schema 代码生成（`app-server-protocol/src/export.rs`），不是会话导出。此结论限定于本快照的 CLI 与 TUI 入口。

## 2. Markdown 导出主链

`/export` 不复用屏幕上的历史 cell，而是重新向 app-server 取数后再渲染。取数先只读线程元数据，再以 `HistoryHydrationScope::Complete` 分页补齐全部 turn 与 item；若服务端不支持分页历史，则回退到带 turns 的旧式读取；若线程是 ephemeral，则直接使用界面内存中的 transcript（`codex-rs/tui/src/app/transcript_export.rs:81-137`）。这带来两个直接后果：导出内容不依赖滚动缓冲区，也不受界面已渲染多少影响；但长会话必须把全部历史拉完才能开始渲染。

可见项过滤会剔除审查模式内部产生的用户消息与嵌套审查 turn 的重复内容（`tui/src/app/transcript_export.rs:202-227`）。随后按条目类型转成 cell：用户消息、Agent Markdown、计划、reasoning 摘要分别成段，其余命令执行、补丁、MCP 调用、网页搜索、图片生成等归入“Activity”（`:229-297`）。渲染时统一做控制字符清洗，测试确认输出不含 ANSI 转义（`codex-rs/tui/src/app/transcript_export_tests.rs:160-177`）。

各部分的内容口径如下：

- **用户消息**：导出正文并做控制字符清洗；本地或远端图片只留一个编号标签（如 `[Image #1]`），图片数据本身不写入正文（`tui/src/app/transcript_export.rs:232-246`）。
- **reasoning**：只导出摘要；原始 reasoning 是否出现，由 `show_raw_agent_reasoning` 配置决定（`:42-46,247-249`）。
- **文件变更**：导出状态与变更数量，并附上每个文件的 diff 全文（`:139-151`）。
- **MCP 调用**：导出服务器与工具名、参数和文本结果；图片降级为“Returned image”，音频降级为“<audio content>”，嵌入资源只保留 URI，资源链接只保留链接地址（`:152-196`）。
- **元数据**：会话信息条目被显式跳过；产物只有一级标题 `# Codex conversation` 与按角色分节的正文，模型、时间、token、会话 ID 等头信息都不写入（`:229-297`）。

文件写入先解析 `~`、绝对路径和相对 cwd 的路径，再以临时文件加 `persist_noclobber` 落盘；同名文件已存在时直接报错，不覆盖（`:299-316`；测试 `transcript_export_tests.rs:181-204`）。因此重复导出必须换文件名，仓库内没有“生成历史/版本列表”。

## 3. 运行时落盘：rollout 的内容口径

rollout 的落盘位置与形态分三条规则：

- **路径与文件名**：新会话落在 codex home 之下，路径由 `sessions` 与年、月、日三级目录逐层拼出，文件名形如 `rollout-<UTC 时间戳>-<thread-id>.jsonl`；线程被 revert 过时，文件名会在 thread id 之后再接一个 rollout id（`codex-rs/rollout/src/recorder.rs:1727-1734`、`rollout/src/rollout_file_name.rs:67-72`）。
- **归档与压缩**：归档把文件移动到 codex home 下的 `archived_sessions` 目录，文件名保持不变，年/月/日层级不再保留，内容原样搬走；超过 7 天的文件会被压缩成 `.jsonl.zst`，读取端对压缩与否两种形态一视同仁（`thread-store/src/local/archive_thread.rs:80-118`、`rollout/src/compression.rs:26,63,370-371`）。
- **注释滞后**：recorder 模块里的示例注释仍按旧的扁平路径书写，与按日期分目录的实现不符，实际行为以同一文件中的路径拼接实现为准（`codex-rs/rollout/src/recorder.rs:79,1727-1734`）。

每行是一个带时间戳的信封，内部条目使用扁平序列化（`codex-rs/history/src/lib.rs:388-394`）。条目类型包括会话元数据、模型可见的响应项、压缩记录、turn 上下文、token 用量、世界状态、保留上下文、事件消息与实时消息（`history/src/lib.rs:228-249`）。其中 `EventMsg` 只服务 UI 与生命周期，模型历史由响应项等条目承载。

落盘不是“全量录制”。写入策略按条目类型取舍（`rollout/src/policy.rs:22-51`）：

- 响应项中，消息、reasoning、工具调用与输出、网页搜索、图片生成和压缩记录都会写入；`CompactionTrigger` 与 `Other` 两类被丢弃（`:81-101`）。
- 分页历史模式下只写入 `ItemCompleted` 等少量事件；旧式历史模式才带上用户与 Agent 消息、补丁结束、MCP 结束这类旧事件（`:128-227`）。
- 审批请求、exec 开始与结束、错误、流式增量、会话配置、计划增量都属于瞬态事件，写入时即被跳过（`:161-227`）。rollout 因此无法充当完整的交互审计日志：谁批准了什么、命令何时开始，都不在其中。

大输出在写入时被裁剪：命令聚合输出超过 64 KiB 会从中间截断并留下标记，MCP 结果也按 64 KiB 截断（`policy.rs:16-19,252-286`）。因此 rollout 保留的是“可恢复上下文所需的内容”，不是逐字全量。

线程元数据另有 SQLite 索引，保存标题、预览、首条用户消息、模型、cwd、git 信息、归档时间、token 用量等，rollout 路径也是其中一列（`codex-rs/state/src/model/thread_metadata.rs:127-200`）。线程列表既有读这份索引的路径，也保留直接扫描 rollout 的路径；正文始终以 rollout 为准。

## 4. 回放、分叉与撤销

恢复时读取整份 rollout，逐行解析；单行解析失败只记 warning 并跳过，完全不解析出内容才报错（`rollout/src/recorder.rs:1129-1194`）。解析出的首个会话元数据决定线程 ID，随后封装成 `InitialHistory::Resumed` 交给会话重建（`:1197-1213`）。

分叉与回退在 app-server 协议层定义：

- 分叉由 `thread/fork` 的两个参数之一指定切点，二者互斥：给出 `lastTurnId` 表示保留到该 turn 并包含它，给出 `beforeTurnId` 表示该 turn 及其后的全部 turn 都丢弃（`app-server-protocol/src/protocol/v2/thread.rs:544-573`）。
- 回退由 `thread/revert` 以 `beforeTurnId` 为界，丢掉该 turn 及之后的内容；线程 ID 保持不变，承载它的文件则切换到一个新的不可变 rollout（`thread.rs:1314-1318` 定义方法，`rollout/src/metadata.rs:113-120` 说明语义，文件名规则见 `rollout_file_name.rs:69-72`）。

分叉后的新线程在会话元数据中保留来源线程 ID（`history/src/lib.rs:423-434` 的 `forked_from_id`），但父会话内容不会自动出现在导出物里。Markdown 导出不读取这条谱系信息。

## 5. `codex exec` 的结构化输出

`codex exec` 的导出相关参数集中定义在 `codex-rs/exec/src/cli.rs:52-85`，各参数负责的产物不同：

- `--json`：把事件以 JSONL 形式打印到 stdout。
- `--output-last-message` / `-o`：把最后一轮消息写入文件。
- `--output-schema`：指定最终消息需要满足的 JSON Schema。
- `--ephemeral`：表示本次运行不落会话文件。

`exec` 另有 `resume` 与 `fork` 两个子命令（`codex-rs/exec/src/cli.rs:172-182`）。

`--json` 的契约是 stdout 每行输出一个合法 JSON 事件（`exec/src/lib.rs:3`）。事件类型包括线程开始，turn 的开始、完成与失败，item 的开始、更新与完成，以及错误；item 一侧的负载涵盖 Agent 消息、reasoning 摘要、命令执行、文件变更、MCP 调用、协作工具、网页搜索、待办列表与错误（`exec/src/exec_events.rs:11-37`，负载字段见同文件 `:107-133`）。这些事件由 EventProcessorWithJsonOutput 直接打印，序列化失败时退化为一条 error 事件（`exec/src/event_processor_with_jsonl_output.rs:89-105`）。

关键边界：`ThreadItemDetails` 没有“用户消息”变体，因此 JSONL 流只描述 Agent 侧行为，不能单独重建一份完整对话。`thread.started` 给出的线程 ID 可用于后续 resume（`exec_events.rs:39-43`），完整历史仍需读 rollout。`-o` 只在成功 turn 后写入，失败不会覆盖旧文件（测试 `exec/src/event_processor_with_jsonl_output_tests.rs:7`）。

`--output-schema` 只约束最终答复的形状，不改变事件流；最终消息在 `--json` 模式下以 JSON 字符串出现在 Agent 消息 item 中（`exec_events.rs:108-110,135-140`）。

## 6. app-server 的线程读取面

app-server 把线程历史拆成三个读取方法，各自负责一层：`thread/read` 返回线程本身与元数据，`thread/turns/list` 以游标分页取 turn，`thread/items/list` 再按单个 turn 或整条线程分页取条目（方法注册见 `app-server-protocol/src/protocol/common.rs:880-901`）。`thread/read` 的 `include_turns` 参数对分页线程已标记为弃用，推荐先只读元数据，再逐页取内容；turn 与 item 两个列表都支持升降序和前后游标（`app-server-protocol/src/protocol/v2/thread.rs:1743-1751,1809-1898`）。

这套接口是 IDE/客户端消费对话历史的正式通道，返回的是规范化 `ThreadItem`，与 TUI Markdown 导出使用同一份条目模型（`tui/src/app/transcript_export.rs:8-9,123-135`）。它解决“如何取到结构化历史”，但自身不生成可交付文件，也不涉及访问控制；传输层提供 stdio、Unix socket 与 WebSocket（`cli/src/main.rs:590-597`）。

## 7. 附件与外部资源

导出物只记录附件引用：用户图片保留编号标签，MCP 返回的图片、音频、嵌入资源分别降级为占位文本或 URI（第 2 节），附件字节留在原处。工具生成的图片由图片生成扩展保存在 codex home 的 `generated_images/<session>/<call_id>.png`（`codex-rs/ext/image-generation/src/artifact.rs:5-65`）；Markdown 导出把它当作一条活动记录，写入调用 ID、状态、改写后的提示词与保存路径，图片文件留在生成目录（`tui/src/thread_transcript/other_items.rs:63-83`）。

因此 Markdown 文件与 rollout 都不是自包含档案：换机器后图片、MCP 资源、diff 之外的仓库状态都无法从导出物恢复。

## 8. 导入与往返

对话导入只有 `/import` 一个入口，说明文字为“从 Claude Code 导入 setup、项目与近期会话”。该入口由迁移模块实现：它把外部会话转成 Codex 的 rollout 条目，并在历史中插入一条 `<EXTERNAL SESSION IMPORTED>` 标记消息（`tui/src/slash_command.rs:118`、`codex-rs/external-agent-migration/src/sessions/export.rs:27,150-160`）；再次导入时，ledger 检查点可以补上缺失的后缀（`sessions/append.rs:27-40`）。默认只发现 30 天以内、最多 50 条外部会话（`external-agent-migration/src/model.rs:5-24`）。

这是单向迁移：没有把 Codex rollout 转成通用交换格式再导回的路径，也没有任意 JSON/JSONL 的通用导入命令。`resume` 与 `fork` 属于同一实现内部的往返，前提是 rollout 文件仍在原 codex home。

## 9. 分享载体、访问控制与撤销

不适用。本次未找到会话分享链接、公开页面、Gist、远端快照或撤销接口；搜索范围为 CLI 子命令、TUI 斜杠命令、app-server 方法与全仓库 `share` 字样，命中的都是网络连接共享、UNC 路径和注释语义，没有对话分享对象。

因此交付物的访问控制完全由外部环境决定：剪贴板内容进入系统剪贴板历史，Markdown 文件继承目标目录权限。导出侧没有脱敏开关，正文会包含命令输出、文件 diff、MCP 结果、绝对路径与仓库信息；reasoning 是否出现取决于本地配置而非导出时的提示。对隐私敏感的会话，仓库内没有“导出前过滤/确认”的实现。

## 10. 版本、失败恢复与测试

- 导出格式没有版本号；rollout 的 schema 由 `RolloutLine` 生成，兼容性依靠读取端的容错和 `SessionMeta` 里的 CLI 版本字段来维持（`app-server-protocol/src/export.rs:209-213`）。
- 导出出错时，错误直接回到 TUI 提示；文件写入采用临时文件加 `persist_noclobber`，失败不会留下半成品；剪贴板写入另有独立的结果提示（`tui/src/app/transcript_export.rs:56-76`）。
- 测试覆盖 Markdown 渲染与过滤、MCP 与补丁详情、ANSI 清洗、路径解析和拒绝覆盖（`transcript_export_tests.rs:21-232`）。rollout 侧有策略与压缩测试，`exec` 侧有 JSONL 事件测试；针对 `/export` 与 app-server 的端到端联调、超大会话、跨平台剪贴板的测试，**本次未找到**。

## 11. 设计取舍与已确认边界

- **三种口径按用途分开。** rollout 服务于恢复与分页读取，允许过滤和截断；Markdown 服务于人读，保留可见内容但丢弃元数据；`exec` JSONL 服务于机器消费，只描述 Agent 侧事件。三者没有共同的“导出 schema”。
- **持久化优先于可移植。** rollout 是内部契约，依赖 codex home、SQLite 索引、压缩表示和同版本读取逻辑；把它直接交给别人并不构成可导入的档案。
- **Markdown 是窄导出。** 只有整线程、只有两种终点、无选区、无图片内联、无模板与主题、无预览、无版本历史；换来的是实现简单且不依赖渲染 DOM。
- **不做社会化传播。** 仓库内没有分享服务客户端或服务端对象，符合本地 Agent 的产品边界。
- **文档滞后于实现。** `docs/exec.md`、`docs/slash_commands.md` 等在本快照中只是指向 developers.openai.com 的占位链接，不能作为行为依据；`recorder.rs:79` 的路径注释也与按日期分目录的实现不符。

## 12. 未验证事项

- `/export` 的真实交互：弹窗按键、剪贴板在 Windows/macOS/Linux 的可用性、超大线程的取数与渲染耗时、ephemeral 线程导出结果。
- Markdown 在真实会话中的保真度：复杂表格、嵌套列表、Mermaid、超长命令输出、二进制/图片附件在查看器中的最终呈现。
- app-server 分页在旧服务端上的回退路径，以及 `items_view` 不同取值对导出的实际影响。
- rollout 压缩与并发写入、写入中断后的恢复、`migrate-rollouts` 对旧文件的迁移结果。
- 从 Claude Code 导入后的线程在 resume、fork、`/export` 中的表现，以及导入会话的字段损失程度。

## 13. 关键源码索引

- TUI 导出：`codex-rs/tui/src/slash_command.rs:51,112`；`tui/src/chatwidget/transcript_export.rs:8-63`；`tui/src/app/transcript_export.rs:32-316`；`tui/src/app/event_dispatch.rs:475-484`
- 导出过滤与渲染测试：`tui/src/app/transcript_export_tests.rs:126-232`
- rollout 写入与读取：`codex-rs/rollout/src/recorder.rs:1727-1734,1135-1219`；`rollout/src/policy.rs:16-287`；`rollout/src/compression.rs:26-63,370-371`；`rollout/src/rollout_file_name.rs:41-72`；`thread-store/src/local/archive_thread.rs:80-118`
- 历史条目与信封：`codex-rs/history/src/lib.rs:228-249,375-399,410-421`
- 线程元数据索引：`codex-rs/state/src/model/thread_metadata.rs:127-200`
- `codex exec`：`codex-rs/exec/src/cli.rs:52-85,172-182`；`exec/src/lib.rs:3,933-1015`；`exec/src/exec_events.rs:11-133`；`exec/src/event_processor_with_jsonl_output.rs:89-105`
- app-server 读取：`codex-rs/app-server-protocol/src/protocol/common.rs:880-901`；`protocol/v2/thread.rs:544-573,1314-1318,1723-1898`
- 外部会话导入：`codex-rs/external-agent-migration/src/model.rs:5-24`；`src/sessions/export.rs:27,150-160`；`src/sessions/append.rs:27-40`
- CLI 子命令全集：`codex-rs/cli/src/main.rs:145-245`
