# Hermes Agent 对话导出与分享调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：静态源码调查，未运行应用。读取 `session.save` RPC、CLI/TUI/桌面 `/save` 入口、`_save_session_log`、SessionDB 可移植性 mixin、`hermes sessions export` 全部分支、Markdown/HTML/JSONL/trace 渲染器、HF 轨迹上传、trajectory 保存与压缩工具；全文检索导入、链接分享、附件打包、剪贴板导出等关键词确认缺失面
>
> 调查范围：`session.save` 快照与"导出交付"的边界、内容口径（system prompt/工具/附件/reasoning/错误）、导入路径、链接分享与研究数据交接。不覆盖整库备份恢复（`hermes backup`/`/snapshot`）、profile 归档（`/export`、`/import`）、`hermes debug share` 的诊断详情和 gateway 消息转发
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes 的按需本地快照有两条入口，落盘目标都是 `~/.hermes/sessions/saved/hermes_conversation_<时间戳>.json`。TUI 与桌面端由 `/save` 调起 `session.save` RPC（`tui_gateway/methods_session.py`），经典 CLI 走 `save_conversation`（`hermes_cli/cli_session_mixin.py`）。CLI 的 `/save` 接受格式、文件名、脱敏三个可选参数（`/save [json|md|html] [filename] [redact]`），读取与渲染统一交给 `hermes_cli/session_export.py`；网关持有会话时由网关渲染，本机只负责落盘。`session.save` 优先从 DB 取规范快照，读库失败才回退内存历史。canonical 会话事实源始终是 SQLite `state.db`，项目文档把这类文件称为 convenience exports（`website/docs/user-guide/sessions.md`）。

**边界判断：`/save` 是面向个人存档/离线查看的本地快照，位于项目“导出交付”主链之外**。它没有下游消费者（无导入、无渲染、无分享管道），docstring 自称 convenience export only（`hermes_cli/cli_session_mixin.py`），分享只停留在“用户自己拿走这个文件”层面。

Hermes 另有一套完整的对话导出子系统，入口独立于 `/save`：

- 命令行入口 `hermes sessions export`（`hermes_cli/sessions_cmd.py`）从 SessionDB 抽取数据，支持五种输出格式，另有两类可选加工：`--redact` 强制脱敏，`--lineage logical` 合并压缩血缘链。
  - jsonl：每行一个完整会话对象；
  - md/qmd：Markdown 文档，带 SHA256 校验行与 manifest.jsonl 导出记录；
  - html：独立单文件，图片占位、reasoning 折叠块、CSP 与转义；
  - trace：Claude Code JSONL，可用 `--upload` 发到 Hugging Face 数据集，默认私有。
- 导入往返存在：服务端的 `import_sessions` 暴露为 Web 接口 `POST /api/sessions/import`，两条路径的实现分别在 `hermes_state_portability.py` 与 `web_routers/sessions.py`；网页端另有对应入口，CLI 子命令层面本次未找到对应的导入命令。
- 研究数据交接有两条：`save_trajectories` 参数（`run_agent.py`，默认关闭）把每轮会话追加成 ShareGPT 格式 JSONL；`hermes sessions export --format trace --upload` 把会话发布为 Hugging Face Agent Trace 数据集（`agent/trace_upload.py`）。

能力分型如下（图片分享 E3 与对话链接分享 E4 本次未找到）：
- E1 数据交换：多格式文件导出与 DB 导入往返；
- E2 阅读交付的简化形态：HTML 单文件，但正文是转义纯文本、无 Markdown 渲染、图片为占位；
- E5 发布与研究：HF 轨迹数据集与 ShareGPT 格式轨迹 JSONL，配套 `trajectory_compressor.py` 与 `datagen-config-examples/`，面向轨迹数据集生产。

## 系统边界与完整主链

会话事实源是 SQLite `state.db`，其中的 `SessionDB` 保存 canonical 消息，消息逐轮增量写入。这个类本身只作 facade，实现分散在同级的 `hermes_state_*.py` 模块里，覆盖 schema、会话、消息、压缩、标题与检索，可移植性 mixin 单独放在 `hermes_state_portability.py`。旁路产物只有落在 `~/.hermes/sessions/saved/` 的显式导出，代码中不再写 `session_*.json` 或 `sessions.json`。

主链 A（本地快照，三入口共用一个目标目录）：

```text
CLI /save（save_conversation，hermes_cli/cli_session_mixin.py）
TUI /save（ui-tui/src/app/slash/commands/core.ts → session.save RPC）
桌面 /save（apps/desktop/src/app/session/hooks/use-prompt-actions/slash-desktop-commands.ts → session.save RPC）
  → 优先从 SessionDB 读规范快照（load_save_snapshot，受 sessions.max_export_messages 限制）
  → DB 读失败时回退会话内存历史（CLI: conversation_history；gateway: session["history"]，history_lock 保护）
  → 渲染后写入 ~/.hermes/sessions/saved/hermes_conversation_<YYYYmmdd_HHMMSS>.json
```

主链 B（结构化导出交付）：

```text
hermes sessions export [output] --format jsonl|md|qmd|html|trace
  → SessionDB.export_session / export_session_lineage / export_all（--redact、--only user-prompts、过滤器）
  → jsonl：每行一个完整会话对象
  → md/qmd：YAML frontmatter + 消息 + 工具调用 JSON 块 + SHA256 校验，旁写 manifest.jsonl
  → html：独立单文件（内联 CSS/JS，nonce CSP）
  → trace：Claude Code JSONL（本地文件或 --upload 到 HF，默认私有）
```

主链 C（导入往返）：

```text
Dashboard Sessions 页或 POST /api/sessions/import（web_routers/sessions.py）
  → SessionDB.import_sessions（hermes_state_portability.py）
  → 跳过已存在 id；孤儿子会话拆离；activity 字段重置为 NULL；尺寸/条数上限校验
```

`hermes sessions export` 的 jsonl 输出与 `import_sessions` 的输入共用同一 `export_session` dict 形状，因此导入与导出可直接构成往返；`hermes sessions recover`（`sessions_cmd.py`）是 DB 文件级恢复，属整库恢复范畴，不计入本类目交付物。

## 1. 入口、用户目标与导出源

| 入口 | 位置 | 导出源 | 目标 |
|---|---|---|---|
| CLI `/save [json\|md\|html]` | `hermes_cli/cli_session_mixin.py`（渲染在 `hermes_cli/session_export.py`） | DB 规范快照，失败回退内存 `conversation_history` | 个人存档、离线查看 |
| TUI `/save` | `ui-tui/src/app/slash/commands/core.ts` | gateway 会话内存 `session["history"]` | 同上 |
| 桌面 `/save` | `apps/desktop/src/app/session/hooks/use-prompt-actions/slash-desktop-commands.ts` | 同上（compute-host 会话转发到宿主，`tui_gateway/methods_session.py`） | 同上 |
| `hermes sessions export` | `hermes_cli/sessions_cmd.py`、`main.py` | `SessionDB`（SQLite） | 个人存档、迁移、备份分析、研究发布 |
| Web 会话导出/导入 | `web_routers/sessions.py`（流式 JSON 导出、`/api/sessions/import` 导入） | `SessionDB` | 页面内下载/恢复 |

导出粒度固定为整会话。md/qmd 加 `--lineage logical` 时会把压缩血缘链合并成一个逻辑会话，这一合并由 `export_session_lineage` 完成（`hermes_state_portability.py`）。批量选取可以按时间、来源、模型等条件过滤，对应 `--older-than`、`--source`、`--model` 三个选项，不传过滤器时 `export_all` 全量导出。单消息、连续范围或任意选区的导出本次未找到。`--only user-prompts` 把用户消息压平成逐条记录，供 prompt 库或记忆摄入使用，它不承担消息范围选择。

## 2. 范围选择、内容口径与字段过滤

- **CLI 的 `/save`**：`save_conversation` 解析格式、文件名与脱敏三个可选参数，没有参数时打印用法；带 `redact` 时先做 force 模式脱敏再写入。内容取自 `load_save_snapshot` 读出的 DB 规范快照，字段口径由 `render_session_for_save` 决定。会话是否带 reasoning 取决于 DB 列与快照构造，未运行验证。
- **TUI 与桌面的 `session.save`**：同样用 `load_save_snapshot` 取规范快照，受 `sessions.max_export_messages` 限制，超限返回错误 4131；读库失败时记录 warning 并回退内存历史，只有回退分支才附带 system prompt，取自 `agent._cached_system_prompt`。落盘统一走 `render_session_for_save`。
- **自动 JSON 快照已移除**：`sessions.write_json_snapshots` 只剩一个遗留配置键，持久化路径不再写会话 JSON 文件。`tests/agent/test_session_snapshot_removal.py` 断言即使该键为 true 也不产生快照文件，显式 `/save json <path>` 仍然可用；模块 docstring 的表述是“自动持久化留在 SQLite，显式导出保持可用”。
- **`hermes sessions export` 的 jsonl**：`export_session` 输出完整的 DB 行与全部消息字段。DB schema 为 reasoning 与 reasoning_content 保留了列，这一点可从导入字段白名单反推（`hermes_state_portability.py`），因此 jsonl 里的会话对象带 reasoning；可选 `--redact` 会以 force 模式深拷贝脱敏（`session_export_md.py`）。
- **md/qmd**：消息内容原样写入，tool_calls 以 JSON 代码块呈现，reasoning 字段不渲染（`session_export_md.py`）。
- **html**：正文一律 HTML 转义（`_escape_html`，`session_export_html.py`），三类富内容降级如下：
  - image_url 内容块 → `[Image Attachment]` 占位；
  - tool_calls → 折叠块；
  - reasoning 与 reasoning_content → 可折叠的 Reasoning 块。
- **trace**：跳过 system 消息；把 assistant 的 content 与 tool_calls 转成 Anthropic 风格的 text、tool_use 块；tool 结果变成 user 轮的 tool_result；reasoning 字段不转换（`agent/trace_upload.py`）。
- **错误信息**：end_reason 等会话字段会写进 jsonl 与 md 的 frontmatter；消息级错误主要落在 content 文本里，各格式都按 content 原样处理，没有独立的错误字段过滤逻辑。

## 3. 附件、资源与离线封装

- **`/save` 的 JSON**：附件没有特殊处理，多模态 content 数组里 image_url 的 data: URL 或路径原样进文件，本地文件路径既不复制也不打包。
- **md/qmd**：与 JSON 相同，data: URL 会整体写进 Markdown。
- **html**：图片一律不内联——CSP 的 `img-src data:` 只放行 data URL，而渲染逻辑把 image_url 换成文本占位，所以实际不输出图片。页面离线打开依赖 Google Fonts 外链，CSP 放行 fonts.googleapis.com 与 fonts.gstatic.com；文件头 docstring 却写"No remote dependencies"（`session_export_html.py`），两者存在出入，离线保真需运行验证。
- **trace**：图片块换成 `[image omitted]` 占位，避免 base64 膨胀（`trace_upload.py`）。
- 全仓未找到附件打包、复制或引用的封装层（zip、相对目录、附件清单）。

## 4. 格式、schema 与往返能力

- **jsonl**：导出的每行是一个会话对象，与 `import_sessions` 的输入同形状，因此导入导出构成往返（`hermes_state_portability.py`）。往返语义如下：
  - 同 id 的会话跳过；
  - 父链只在父会话存在时恢复，否则拆离成孤立会话；
  - `last_activity_*` 字段导入时重置为 NULL；
  - 尺寸与条数受硬上限约束（`_IMPORT_MAX_*`）。
- 每个结构化会话导出都附带一份与文本无关的 timings 证据：按持久化消息时间戳给出首末时间、墙钟跨度、最大相邻间隔、角色计数、工具调用与结果数以及逐消息间隔。Hermes 没有持久化独立的模型或工具秒表，因此该摘要标为 `complete: false`；缺少时间戳时给出不可用原因。导入时这份派生字段不计入内容尺寸预算，下次导出会重新计算（`hermes_state_portability.py`）。
- **md/qmd**（实现见 `session_export_md.py`）：没有 Markdown 导入路径，这一点本次未找到。导出侧包含：
  - frontmatter 带 exporter 版本标记 `EXPORTER_VERSION = "hermes sessions export (md/qmd) v1"` 与血缘 id 列表 lineage_session_ids；
  - SHA256 校验行与 "Export verification" 段落，`verify_export_file` 可复核哈希与消息数；
  - manifest.jsonl 每导出一次追加一条记录，含 sha256。
- **trace**：采用 Claude Code JSONL 这一第三方格式，供 Hugging Face Agent Trace Viewer 消费（`trace_upload.py`）。
- **html**：不带版本或 schema 标记。

## 5. 分享稿编辑、编排与预览

不适用。导出前没有独立预览、内容开关、重排或编辑工作台；`--dry-run` 仅打印将匹配的会话列表（`sessions_cmd.py`）。`/save` 直接写文件并打印路径，无预览。HTML 模板是固定版式（主题深浅色自适应），无主题/尺寸/水印配置。

## 6. 图片、HTML、PDF 与富内容生成

- HTML 是唯一文档型交付物：内联 CSS/JS 的单文件模板，`secrets` 生成 script nonce，CSP 收紧（`default-src 'none'`），正文全部 HTML 转义，不支持 Markdown 渲染（代码块、表格、数学原样成文本）；多会话导出带侧边栏导航（`generate_multi_session_html_export`，`session_export_html.py`）。
- 图片导出（PNG/JPEG）、PDF、打印路径：本次未找到。
- 富内容降级：HTML 中 image → 占位文本；md 中所有内容按文本保留。

## 7. 生成历史、版本与持久化

- **`/save`**：每次生成带新时间戳的文件，时间戳精确到秒，同一秒内重复保存会覆盖；没有列表、去重或版本管理，历史就是目录里堆叠的文件。
- **md 导出**：默认拒绝覆盖已存在的文件并抛 `FileExistsError`（`session_export_md.py`），加 `--force` 才覆盖；manifest.jsonl 逐次追加记录，构成可追踪的导出历史，记录含 sha256。
- **`--delete-after-verified`**：md/qmd 校验通过后删除源会话，需同时给 `--yes`（`sessions_cmd.py`）；导出文件的校验状态在这里成为删除前提。
- 运行期的自动快照及其文件守卫已随该功能一起移除，当前持久化只剩 SQLite 写入与显式导出两条路径。

## 8. 分享载体、访问控制与撤销

- 对话交付物全部落在本地：saved 目录、session-exports 目录与 stdout，没有内置的分享或复制动作。
- 唯一的远端发布通道是 HF 轨迹数据集（`agent/trace_upload.py`）：数据集默认 `private=True`，加 `--public` 才公开；上传是幂等的（`create_repo exist_ok`），提交信息里带 session id。删除、撤销、过期与成员管理都没有对应路径，HF 侧的治理不在本地代码内。
- `hermes debug share`（`hermes_cli/debug.py`）把系统信息与日志上传到 paste.rs 或 dpaste 的公开链接，`--nous` 时改传 Nous 内部的 S3 私有桶，另有删除 paste.rs 链接的命令。这条通道属于**诊断分享**，上传的是日志与系统信息（docstring 说明可能含对话片段）；它不从对话内容抽取交付物，因此不计入本类目主链。
- 对话内容的 URL 或链接分享（会话快照页、公开页面、Gist）：本次未找到。

## 9. 隐私、安全与内容治理

- **`/save`**：默认不脱敏，内容原样落盘，可能写入密钥；脱敏由显式 `redact` 选项触发，CLI 与网关侧都走 force 模式。
- **jsonl 与 md 导出**：`--redact` 为可选参数，开启后以 force 模式调用 `redact_sensitive_text`，深拷贝所有消息 content 与 tool_calls 再脱敏（`session_export_md.py`）；不传就原样输出。
- **trace**：默认强制脱敏，内部以 `redact=True` 调用 `agent.redact.redact_sensitive_text` 的 force 模式；脱敏失败会抛 `TraceRedactionError` 并拒绝上传，只有显式勾选 `--no-redact` 才跳过（`trace_upload.py`）。
- **html**：全部用户内容经 `_escape_html` 转义（`session_export_html.py`），并配合 CSP nonce（`default-src 'none'; script-src 'nonce-…'`）；`_generate_messages_html` 的注释写明这能阻止标记与脚本注入，图片与字体只放行 data: 与 googleapis。
- 导出前没有隐私提示，也没有 system prompt 开关：trace 无条件丢弃 system 消息，md 与 html 不写 system_prompt 字段。TUI 的 `/save` 是例外，它**包含**完整 system prompt 原文。

## 10. 性能、失败恢复与测试

- **大会话防护**：`hermes sessions export` 走 console 引擎时，对每个会话按消息数设了上限，默认 20000 条，键名 `sessions.max_export_messages`（`hermes_cli/console_engine.py`，默认值在 `config_defaults.py`）；Web 导出则用 keyset 分页流式输出（`web_routers/sessions.py`）。
- **导入上限**：四类硬限，配套原子写入（`hermes_state_portability.py`）：
  - 会话数：`_IMPORT_MAX_SESSIONS`；
  - 单会话消息数：`_IMPORT_MAX_MESSAGES_PER_SESSION`；
  - 单会话字节数：`_IMPORT_MAX_SESSION_BYTES`；
  - 总字节数：`_IMPORT_MAX_TOTAL_BYTES`。
- timing evidence 只从已持久化的时间戳派生，不含提示词、工具参数或结果文本；它能定位长间隔，却区分不出模型计算、网络等待与工具运行各自的耗时。
- `/save` 失败时只打印错误、不中断会话（`cli.py`），创建目录失败同样只报错返回（`methods_session.py`）。
- 已有测试（运行行为未在本机复验）：
  - `/save` 的落盘位置是 profile 目录，与 CWD 无关：`tests/test_tui_gateway_server.py`；
  - 保存位置与导出各格式：`tests/cli/test_save_conversation_location.py`、`tests/hermes_cli/test_session_export.py`、`tests/hermes_cli/test_sessions_export_md_cli.py`、`tests/hermes_state/test_session_md_export.py`；
  - export→import 往返：`tests/test_hermes_state.py`；
  - trace 上传与导出预算 guard：`tests/agent/test_trace_upload.py`、`tests/hermes_cli/test_console_engine.py`。

## 11. 设计取舍与已确认边界

- **`/save` 快照与导出交付的边界**：快照是即时落盘的会话文件，没有 schema 承诺、默认不脱敏、也没有下游消费者；导出子系统则先做 DB 抽取，再脱敏，最后格式化渲染。两条管线并行，字段口径由各自的渲染函数决定：`/save` 走 `render_session_for_save`，批量导出走 `render_sessions_export`。
- 文档与实现的锚点有三处：`sessions.md` 写"convenience exports, not the index"，`save_conversation` 的 docstring 写 convenience export only，会话持久化测试的模块 docstring 写 automatic persistence stays in SQLite。三者共同确认 canonical 事实源是 state.db，快照只是旁路。
- 导出子系统把研究用途当一等公民：trace 直接采用 Claude Code JSONL 这一第三方标准，上传默认私有；轨迹 JSONL 走 ShareGPT 格式，系统消息里带工具定义、reasoning 包在 `<think>` 中（`agent/agent_runtime_helpers.py`）；配套的 `trajectory_compressor.py` 与 `datagen-config-examples/` 说明轨迹是数据生成管线的原料（`batch_runner.py`）。
- 隐私默认值不对称：面向研究的 trace 默认强制脱敏并在脱敏失败时拒绝上传，面向个人的 `/save` 则零加工。jsonl 与 md 导出把脱敏放在可选的 `--redact` 后面。
- HTML 模板声明"无远程依赖"，实际又挂 Google Fonts 外链（`session_export_html.py-34`），离线性需运行验证。
- 会话删除保护闭环：md 导出要校验通过（哈希、消息数、session id 三项）才允许删除源会话，导出验证因此接入了删除授权。
- 状态快照的边界：当前代码把 `/snapshot restore` 归入 profile 状态恢复，与对话交付分开；恢复 SQLite 时走备份 API，遇到仍被本进程连接持有的数据库就拒绝继续（`hermes_cli/backup.py`、`hermes_state.py`）。状态备份与恢复、`session.save` 和 `hermes sessions export` 生成的内容，分属两类交付物。

## 12. 未验证事项

- `/save` 与 `session.save` 实际落盘文件的字段全集，特别是 reasoning 是否随 DB 快照写入。静态推断认为 DB 有 reasoning 列、导出会带上它，但 `/save` 的 json 渲染究竟裁剪了哪些字段，尚未逐行核对。
- `hermes sessions export --format trace --upload` 在 Hugging Face 侧的实际行为：token 解析、私有数据集创建，以及加 `--public` 之后的内容治理。
- HTML 导出的实际离线表现，包括 Google Fonts 缺失时的回退，以及 reasoning 折叠块与 JS 交互在无网络环境下的行为。
- Dashboard 的 Sessions 页上导出与导入的实际交互，以及导入校验的反馈方式。
- 同一秒内重复执行 `/save` 时的覆盖行为，以及快照目录的积累与清理策略；清理机制本次未找到。
- `trajectory_compressor.py` 与 `datagen-config-examples/` 的端到端消费闭环；示例配置的消费入口本次未下钻。

## 13. 关键源码索引

- `tui_gateway/methods_session.py`（`session.save` RPC；compute-host 转发）
- `hermes_cli/cli_session_mixin.py`（`save_conversation`，`/save` 分发）、`hermes_cli/session_export.py`（`load_save_snapshot`/`render_session_for_save`/`normalize_save_format`/`SAVE_USAGE`）
- `run_agent.py`（`save_trajectories` 参数与轨迹保存）
- `hermes_state_portability.py`（`export_session`/`export_session_lineage`/`export_all`/`import_sessions`）
- `hermes_state_portability.py`（`_export_timings`：文本无关的导出时序证据）
- `hermes_cli/sessions_cmd.py`（`hermes sessions export` 全分支）
- `hermes_cli/session_export_md.py`、`hermes_cli/session_export_html.py`、`hermes_cli/session_export.py`
- `agent/trace_upload.py`（Claude Code JSONL 构建与 HF 上传）
- `agent/trajectory.py`、`agent/agent_runtime_helpers.py`（`convert_to_trajectory_format`）、根目录 `trajectory_compressor.py`
- `hermes_cli/web_routers/sessions.py`（`/api/sessions/import`、`/api/sessions/{id}/export`）、`web/src/lib/api.ts`（网页端导入/导出入口）
- `ui-tui/src/app/slash/commands/core.ts`、`apps/desktop/src/app/session/hooks/use-prompt-actions/slash-desktop-commands.ts`
- `website/docs/user-guide/sessions.md`（存储定位）
