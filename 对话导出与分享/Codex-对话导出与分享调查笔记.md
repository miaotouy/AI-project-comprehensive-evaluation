# Codex 对话导出与分享调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c9750d7f50052b29f53def02b5cf2160ae49a3d9`（分支：`main`）
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

按本类目分型，Markdown 导出属于 `E2 阅读交付` 的窄实现，rollout 与 `exec --json` 属于 `E1 数据交换` 的事件/日志侧；本次未找到 `E3 图片分享`、`E4 链接分享`、`E5 发布与研究` 的对应实现。`/import` 只做从 Claude Code 到 Codex 的单向迁移，不构成通用往返。

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

`/export` 的入口在斜杠命令表中定义，说明文字是“export the conversation as markdown”（`codex-rs/tui/src/slash_command.rs:51,112`）；弹窗只提供“Copy to clipboard”和“Save to file”两个目标（`codex-rs/tui/src/chatwidget/transcript_export.rs:8-45`），文件名默认 `codex-session-<thread-id>.md`（同文件 `:47-63`）；Android 上剪贴板项被禁用，只剩文件目标（`:22`）。任务进行中仍可执行导出（`slash_command.rs:248-269`）。

没有 `codex export` 子命令：子命令枚举（`codex-rs/cli/src/main.rs:146-246`）只有 exec、resume、fork、archive、delete、migrate-rollouts、cloud 等，没有导出项。全仓库出现的 `export` 多数是 TypeScript/JSON Schema 代码生成（`app-server-protocol/src/export.rs`），不是会话导出。此结论限定于本快照的 CLI 与 TUI 入口。

## 2. Markdown 导出主链

`/export` 不复用屏幕上的历史 cell，而是重新向 app-server 取数后再渲染。取数先只读线程元数据，再以 `HistoryHydrationScope::Complete` 分页补齐全部 turn 与 item；若服务端不支持分页历史，则回退到带 turns 的旧式读取；若线程是 ephemeral，则直接使用界面内存中的 transcript（`codex-rs/tui/src/app/transcript_export.rs:81-137`）。这带来两个直接后果：导出内容不依赖滚动缓冲区，也不受界面已渲染多少影响；但长会话必须把全部历史拉完才能开始渲染。

可见项过滤会剔除审查模式内部产生的用户消息与嵌套审查 turn 的重复内容（`transcript_export.rs:202-227`）。随后按条目类型转成 cell：用户消息、Agent Markdown、计划、reasoning 摘要分别成段，其余命令执行、补丁、MCP 调用、网页搜索等归入“Activity”（`:229-297`）。渲染时统一做控制字符清洗，测试确认输出不含 ANSI 转义（`codex-rs/tui/src/app/transcript_export_tests.rs:160-177`）。

各部分的内容口径如下：

- **用户消息**：取正文并清洗；本地或远端图片只追加编号标签（如 `[Image #1]`），不内联图片数据（`transcript_export.rs:232-246`）。
- **reasoning**：只输出摘要；是否包含原始 reasoning 取决于 `show_raw_agent_reasoning` 配置（`:42-46,247-249`）。
- **文件变更**：输出状态、变更数量，以及每个文件的 diff 全文（`:139-151`）。
- **MCP 调用**：输出服务器/工具、参数、文本结果；图片降级为“Returned image”，音频为“<audio content>”，嵌入资源只留 URI，资源链接只留链接地址（`:152-196`）。
- **元数据**：会话信息 cell 被显式跳过；产物只有一级标题 `# Codex conversation` 和按角色分节的正文，不含模型、时间、token、会话 ID 等头信息（`:229-297`）。

文件写入先解析 `~`、绝对路径和相对 cwd 的路径，再以临时文件加 `persist_noclobber` 落盘；同名文件已存在时直接报错，不覆盖（`:299-316`；测试 `transcript_export_tests.rs:181-204`）。因此重复导出必须换文件名，仓库内没有“生成历史/版本列表”。

## 3. 运行时落盘：rollout 的内容口径

rollout 的落盘位置与形态分三条规则：

- **路径与文件名**：新会话路径由 codex home、`sessions`、年/月/日三级目录和文件名拼成（`codex-rs/rollout/src/recorder.rs:1779-1786`），文件名是 `rollout-<UTC 时间戳>-<thread-id>.jsonl`；被 revert 过的线程会在 thread id 后再拼一个 rollout id（`rollout/src/rollout_file_name.rs:67-72`）。
- **归档与压缩**：归档把文件重命名到 codex home 下的 `archived_sessions`，文件名不变、不再保留年/月/日层级、不重写内容（`thread-store/src/local/archive_thread.rs:80-118`）；超过 7 天的文件压缩成 `.jsonl.zst`，读取端对两种表示透明（`rollout/src/compression.rs:26,63,370-371`）。
- **注释滞后**：`recorder.rs:82` 的示例仍是旧的扁平路径，与按日期分目录的实现不一致，应以 `:1779-1786` 为准。

每行是一个带时间戳的信封，内部条目使用扁平序列化（`codex-rs/history/src/lib.rs:375-381`）。条目类型包括会话元数据、模型可见的响应项、压缩记录、turn 上下文、token 用量、世界状态、保留上下文、事件消息与实时消息（`history/src/lib.rs:216-237`）。其中 `EventMsg` 是 UI/生命周期事件，不等同于模型历史。

落盘不是“全量录制”。写入策略按条目类型取舍（`rollout/src/policy.rs:22-51`）：

- 响应项中消息、reasoning、工具调用与输出、网页搜索、图片生成、压缩记录保留；`CompactionTrigger` 和 `Other` 丢弃（`:81-101`）。
- 分页历史模式下只保留 `ItemCompleted` 等少量事件；旧式历史模式才保留用户/Agent 消息、补丁结束、MCP 结束等旧事件（`:128-227`）。
- 审批请求、exec 开始/结束、错误、流式增量、会话配置、计划增量等属于瞬态事件，不落盘（`:161-227`）。这解释了为什么 rollout 不能当作完整的交互审计日志：谁批准了什么、命令何时开始，都不在其中。

大输出在写入时被裁剪：命令聚合输出超过 64 KiB 会从中间截断并留下标记，MCP 结果也按 64 KiB 截断（`policy.rs:16-19,252-286`）。因此 rollout 保留的是“可恢复上下文所需的内容”，不是逐字全量。

线程元数据另有 SQLite 索引，保存标题、预览、首条用户消息、模型、cwd、git 信息、归档时间、token 用量等，rollout 路径也是其中一列（`codex-rs/state/src/model/thread_metadata.rs:127-200`）。线程列表既有读这份索引的路径，也保留直接扫描 rollout 的路径；正文始终以 rollout 为准。

## 4. 回放、分叉与撤销

恢复时读取整份 rollout，逐行解析；单行解析失败只记 warning 并跳过，完全不解析出内容才报错（`rollout/src/recorder.rs:1135-1200`）。解析出的首个会话元数据决定线程 ID，随后封装成 `InitialHistory::Resumed` 交给会话重建（`:1203-1219`）。

分叉与回退在 app-server 协议层定义：

- `thread/fork` 支持 `lastTurnId`（含该 turn）或 `beforeTurnId`（不含该 turn 及其后全部 turn），两者互斥（`app-server-protocol/src/protocol/v2/thread.rs:544-573`）。
- `thread/revert` 以 `beforeTurnId` 为界丢弃该 turn 及之后的内容，线程 ID 保持不变，但切换到一个新的不可变 rollout 文件（`thread.rs:1300-1304`；语义说明见 `rollout/src/metadata.rs:113-120`，文件名规则见 `rollout_file_name.rs:69-72`）。

分叉后的新线程在会话元数据中保留来源线程 ID（`history/src/lib.rs:410-421` 的 `forked_from_id`），但父会话内容不会自动出现在导出物里。Markdown 导出不读取这条谱系信息。

## 5. `codex exec` 的结构化输出

`codex exec` 的导出相关参数集中在 `codex-rs/exec/src/cli.rs:52-85`：`--json` 打印 JSONL，`--output-last-message/-o` 写最后消息，`--output-schema` 指定最终消息的 JSON Schema，`--ephemeral` 表示不落会话文件。`exec` 还提供 `resume` 与 `fork` 子命令（`cli.rs:172-182`）。

`--json` 的契约是“stdout 每行一个合法 JSON 事件”（`exec/src/lib.rs:3`）。事件类型为线程开始、turn 开始/完成/失败、item 开始/更新/完成和错误（`exec/src/exec_events.rs:11-37`），item 负载覆盖 Agent 消息、reasoning 摘要、命令执行、文件变更、MCP 调用、协作工具、网页搜索、待办列表与错误（`:107-133`）。事件由 `EventProcessorWithJsonOutput` 直接打印，序列化失败时退化为一个 error 事件（`exec/src/event_processor_with_jsonl_output.rs:88-104`）。

关键边界：`ThreadItemDetails` 没有“用户消息”变体，因此 JSONL 流只描述 Agent 侧行为，不能单独重建一份完整对话。`thread.started` 给出的线程 ID 可用于后续 resume（`exec_events.rs:39-43`），完整历史仍需读 rollout。`-o` 只在成功 turn 后写入，失败不会覆盖旧文件（测试 `exec/src/event_processor_with_jsonl_output_tests.rs:7`）。

`--output-schema` 只约束最终答复的形状，不改变事件流；最终消息在 `--json` 模式下以 JSON 字符串出现在 Agent 消息 item 中（`exec_events.rs:108-110,135-140`）。

## 6. app-server 的线程读取面

app-server 把线程历史拆成三个读取方法：`thread/read` 取线程与元数据，`thread/turns/list` 按游标分页取 turn，`thread/items/list` 按 turn 或全线程分页取条目（方法注册见 `app-server-protocol/src/protocol/common.rs:880-901`）。`thread/read` 的 `include_turns` 被标注为对分页线程已弃用，推荐只读元数据后再分页（`v2/thread.rs:1723-1731`）；turn 与 item 列表都支持升降序和前后游标（`:1789-1818,1823-1898`）。

这套接口是 IDE/客户端消费对话历史的正式通道，返回的是规范化 `ThreadItem`，与 TUI Markdown 导出使用同一份条目模型（`transcript_export.rs:8-9,123-135`）。它解决“如何取到结构化历史”，但自身不生成可交付文件，也不涉及访问控制；传输层提供 stdio、Unix socket 与 WebSocket（`cli/src/main.rs:591-598`）。

## 7. 附件与外部资源

导出不解包、不内联、不复制附件。用户图片只保留编号标签；MCP 返回的图片、音频、嵌入资源分别降级为占位文本或 URI（第 2 节）。工具生成的图片由图片生成扩展保存在 codex home 的 `generated_images/<session>/<call_id>.png`（`codex-rs/ext/image-generation/src/artifact.rs:5-35`）；Markdown 导出把它当作一条活动记录，写入调用 ID、状态、改写后的提示词与保存路径，而不是嵌入图片（`tui/src/thread_transcript/other_items.rs:63-83`）。

因此 Markdown 文件与 rollout 都不是自包含档案：换机器后图片、MCP 资源、diff 之外的仓库状态都无法从导出物恢复。

## 8. 导入与往返

本次唯一的对话导入入口是 `/import`，说明为“从 Claude Code 导入 setup、项目与近期会话”（`tui/src/slash_command.rs:118`）。迁移模块把外部会话转成 Codex 的 rollout 条目，并在历史中插入一个 `<EXTERNAL SESSION IMPORTED>` 标记消息（`codex-rs/external-agent-migration/src/sessions/export.rs:27,150-160`）；再次导入时可用 ledger 检查点追加缺失后缀（`sessions/append.rs:27-40`）。默认只发现 30 天内、最多 50 条外部会话（`external-agent-migration/src/model.rs:5-24`）。

这是单向迁移：没有把 Codex rollout 转成通用交换格式再导回的路径，也没有任意 JSON/JSONL 的通用导入命令。`resume` 与 `fork` 属于同一实现内部的往返，前提是 rollout 文件仍在原 codex home。

## 9. 分享载体、访问控制与撤销

不适用。本次未找到会话分享链接、公开页面、Gist、远端快照或撤销接口；搜索范围为 CLI 子命令、TUI 斜杠命令、app-server 方法与全仓库 `share` 字样，命中的都是网络连接共享、UNC 路径和注释语义，没有对话分享对象。

因此交付物的访问控制完全由外部环境决定：剪贴板内容进入系统剪贴板历史，Markdown 文件继承目标目录权限。导出侧没有脱敏开关，正文会包含命令输出、文件 diff、MCP 结果、绝对路径与仓库信息；reasoning 是否出现取决于本地配置而非导出时的提示。对隐私敏感的会话，仓库内没有“导出前过滤/确认”的实现。

## 10. 版本、失败恢复与测试

- 没有导出格式版本号；rollout 的 schema 由 `RolloutLine` 生成（`app-server-protocol/src/export.rs:209-213`），兼容性靠读取端容错和 `SessionMeta` 中的 CLI 版本字段，而不是显式格式版本。
- 导出失败时错误直接回到 TUI 提示；文件写入失败不会留下半成品（临时文件加 `persist_noclobber`）。剪贴板写入有独立结果提示（`transcript_export.rs:56-76`）。
- 测试覆盖 Markdown 渲染与过滤、MCP/补丁详情、ANSI 清洗、路径解析与拒绝覆盖（`transcript_export_tests.rs:21-232`）。rollout 侧有策略与压缩测试，`exec` 侧有 JSONL 事件测试。**本次未找到**针对 `/export` 与 app-server 端到端联调、超大会话、跨平台剪贴板的测试。

## 11. 设计取舍与已确认边界

- **三种口径按用途分开。** rollout 服务于恢复与分页读取，允许过滤和截断；Markdown 服务于人读，保留可见内容但丢弃元数据；`exec` JSONL 服务于机器消费，只描述 Agent 侧事件。三者没有共同的“导出 schema”。
- **持久化优先于可移植。** rollout 是内部契约，依赖 codex home、SQLite 索引、压缩表示和同版本读取逻辑；把它直接交给别人并不构成可导入的档案。
- **Markdown 是窄导出。** 只有整线程、只有两种终点、无选区、无图片内联、无模板与主题、无预览、无版本历史；换来的是实现简单且不依赖渲染 DOM。
- **不做社会化传播。** 仓库内没有分享服务客户端或服务端对象，符合本地 Agent 的产品边界。
- **文档滞后于实现。** `docs/exec.md`、`docs/slash_commands.md` 等在本快照中只是指向 developers.openai.com 的占位链接，不能作为行为依据；`recorder.rs:82` 的路径注释也与按日期分目录的实现不符。

## 12. 未验证事项

- `/export` 的真实交互：弹窗按键、剪贴板在 Windows/macOS/Linux 的可用性、超大线程的取数与渲染耗时、ephemeral 线程导出结果。
- Markdown 在真实会话中的保真度：复杂表格、嵌套列表、Mermaid、超长命令输出、二进制/图片附件在查看器中的最终呈现。
- app-server 分页在旧服务端上的回退路径，以及 `items_view` 不同取值对导出的实际影响。
- rollout 压缩与并发写入、写入中断后的恢复、`migrate-rollouts` 对旧文件的迁移结果。
- 从 Claude Code 导入后的线程在 resume、fork、`/export` 中的表现，以及导入会话的字段损失程度。

## 13. 关键源码索引

- TUI 导出：`codex-rs/tui/src/slash_command.rs:51,112`；`tui/src/chatwidget/transcript_export.rs:8-63`；`tui/src/app/transcript_export.rs:32-316`；`tui/src/app/event_dispatch.rs:461-470`
- 导出过滤与渲染测试：`tui/src/app/transcript_export_tests.rs:126-232`
- rollout 写入与读取：`codex-rs/rollout/src/recorder.rs:1779-1786,1135-1219`；`rollout/src/policy.rs:16-286`；`rollout/src/compression.rs:26-63,370-371`；`rollout/src/rollout_file_name.rs:41-72`；`thread-store/src/local/archive_thread.rs:80-118`
- 历史条目与信封：`codex-rs/history/src/lib.rs:216-237,375-399,410-421`
- 线程元数据索引：`codex-rs/state/src/model/thread_metadata.rs:127-200`
- `codex exec`：`codex-rs/exec/src/cli.rs:52-85,172-182`；`exec/src/lib.rs:3,933-1015`；`exec/src/exec_events.rs:11-133`；`exec/src/event_processor_with_jsonl_output.rs:88-104`
- app-server 读取：`codex-rs/app-server-protocol/src/protocol/common.rs:880-901`；`protocol/v2/thread.rs:544-573,1300-1304,1723-1898`
- 外部会话导入：`codex-rs/external-agent-migration/src/model.rs:5-24`；`src/sessions/export.rs:27,150-160`；`src/sessions/append.rs:27-40`
- CLI 子命令全集：`codex-rs/cli/src/main.rs:146-246`
