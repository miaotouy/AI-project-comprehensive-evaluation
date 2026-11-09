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

Hermes 的按需本地快照有两条入口，共用 `~/.hermes/sessions/saved/hermes_conversation_<时间戳>.json`：TUI/桌面端 `/save` 调用 `session.save` RPC（`tui_gateway/methods_session.py`），经典 CLI 走 `save_conversation`（`hermes_cli/cli_session_mixin.py`）。CLI 入口本次快照起支持 `/save [json|md|html] [filename] [redact]`，读取与渲染统一由 `hermes_cli/session_export.py`（`load_save_snapshot`/`render_session_for_save`/`normalize_save_format`）承担，网关持有会话时由网关侧渲染、本机只落盘；`session.save` 则优先从 DB 取规范快照，读失败才回退内存历史。canonical 会话事实源始终是 SQLite `state.db`，项目文档把这类文件称为 convenience exports（`website/docs/user-guide/sessions.md`）。

**边界判断：`/save` 是面向个人存档/离线查看的本地快照，位于项目“导出交付”主链之外**。它没有下游消费者（无导入、无渲染、无分享管道），docstring 自称 convenience export only（`hermes_cli/cli_session_mixin.py`），分享只停留在“用户自己拿走这个文件”层面。

Hermes 另有一套完整的对话导出子系统，入口独立于 `/save`：

- 命令行入口 `hermes sessions export`（`hermes_cli/sessions_cmd.py`）从 SessionDB 抽取数据，支持五种输出格式与两类可选加工（`--redact` 强制脱敏、`--lineage logical` 合并压缩血缘链）：
  - `jsonl`：每行一个完整会话对象；
  - `md`/`qmd`：Markdown 文档，带 SHA256 校验行与 `manifest.jsonl` 导出记录；
  - `html`：独立单文件（图片占位、reasoning 折叠块、CSP+转义）；
  - `trace`：Claude Code JSONL，可 `--upload` 到 Hugging Face 数据集（默认私有）。
- 导入往返存在：服务端 `import_sessions`（`hermes_state_portability.py`）暴露为 Web `POST /api/sessions/import`（`web_routers/sessions.py`），网页端另有对应入口；CLI 子命令层面本次未找到对应的导入命令。
- 研究数据交接有两条：`save_trajectories` 参数（`run_agent.py`，默认关闭）把每轮会话追加为 ShareGPT 格式 JSONL；`hermes sessions export --format trace --upload` 把会话发布为 Hugging Face Agent Trace 数据集（`agent/trace_upload.py`）。

能力分型如下（`E3` 图片分享与 `E4` 对话链接分享本次未找到）：
- `E1` 数据交换：多格式文件导出与 DB 导入往返；
- `E2` 阅读交付的简化形态：HTML 单文件，但正文是转义纯文本、无 Markdown 渲染、图片为占位；
- `E5` 发布与研究：HF 轨迹数据集与 ShareGPT 格式轨迹 JSONL，配套 `trajectory_compressor.py`、`datagen-config-examples/` 面向轨迹数据集生产。

## 系统边界与完整主链

会话事实源：SQLite `state.db` 中的 `SessionDB` 是 canonical 消息存储，消息逐轮增量写入；`SessionDB` 本身已是 facade，实现分散在 `hermes_state_*.py` 兄弟模块（schema、会话、消息、压缩、标题、检索），可移植性 mixin 独立在 `hermes_state_portability.py`。旁路产物只有 `~/.hermes/sessions/saved/` 一类显式导出，代码不写 `session_*.json`/`sessions.json`。

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

导出粒度固定为整会话。md/qmd 的 `--lineage logical` 会把压缩血缘链合并为一个逻辑会话（`export_session_lineage`，`hermes_state_portability.py`）。批量选取支持按时间、来源、模型等条件过滤（`--older-than`、`--source`、`--model`）。不传过滤器时 `export_all` 全量导出。单消息、连续范围或任意选区导出本次未找到；`--only user-prompts` 把用户消息压平成逐条记录，供 prompt 库或记忆摄入使用，不承担消息范围选择。

## 2. 范围选择、内容口径与字段过滤

- **`/save`（CLI）**：`save_conversation` 解析 `/save [json|md|html] [filename] [redact]`，无子参数时打印用法；`redact` 走 force 模式脱敏后写入。内容取自 `load_save_snapshot` 的 DB 规范快照，字段口径由 `render_session_for_save` 决定；是否含 `reasoning` 取决于 DB 列与快照构造，未运行验证。
- **`session.save`（TUI/桌面）**：同样走 `load_save_snapshot(db, key, "json")` 取规范快照，受 `sessions.max_export_messages` 限制（超限返回错误 4131）；读库失败时记录 warning 并回退内存历史，回退分支才附带 `system_prompt`（取 `agent._cached_system_prompt`）。落盘统一为 `render_session_for_save(data, "json")`。
- **自动 JSON 快照已移除**：`sessions.write_json_snapshots` 只剩遗留配置键，持久化路径不再写 `session_*.json`。`tests/agent/test_session_snapshot_removal.py` 断言：即使该键为 true 也不产生快照文件，而显式 `/save json <path>` 仍可用；模块 docstring 的表述是“自动持久化留在 SQLite，显式导出保持可用”。
- **`hermes sessions export jsonl`**：`export_session` 输出 DB 行与全部消息字段。DB schema 为 `reasoning`/`reasoning_content` 保留了列（可从导入字段白名单反推，`hermes_state_portability.py`），因此 jsonl 是含 reasoning 的完整会话对象；可选 `--redact` 以 force 模式深拷贝脱敏（`session_export_md.py`）。
- **md/qmd**：消息内容原样写入，`tool_calls` 以 JSON 代码块呈现（`session_export_md.py`）；reasoning 字段不渲染。
- **html**：正文一律 HTML 转义（`_escape_html`，`session_export_html.py`），三类富内容降级如下：
  - `image_url` 内容块 → `[Image Attachment]` 占位；
  - `tool_calls` → 折叠块；
  - reasoning/reasoning_content → 可折叠 Reasoning 块。
- **trace**：跳过 system 消息；assistant 的 content+tool_calls 转 Anthropic 风格 `text`/`tool_use` 块；tool 结果变 user 轮 `tool_result`；`reasoning` 字段不转换（`agent/trace_upload.py`）。
- **错误信息**：`end_reason` 等会话字段进 jsonl/md frontmatter；消息级错误主要落在 content 文本内，各格式均按 content 原样处理，无独立"错误"字段过滤逻辑。

## 3. 附件、资源与离线封装

- `/save` JSON：附件无特殊处理——多模态 content 数组（`image_url` 的 data: URL 或路径）原样进文件，本地文件路径不会被复制或打包。
- md/qmd：同前，data: URL 会整体写进 Markdown。
- html：图片一律不内联（`img-src data:` 的 CSP 下仅允许 data URL，但渲染逻辑把 image_url 换成文本占位，实际不输出图片），离线打开依赖 Google Fonts 外链（CSP 放行 `fonts.googleapis.com`/`fonts.gstatic.com`）——与文件头 docstring"No remote dependencies"（`session_export_html.py`）存在出入，离线保真需运行验证。
- trace：图片块 → `[image omitted]` 占位，避免 base64 膨胀（`trace_upload.py`）。
- 全仓未找到附件打包/复制/引用的封装层（zip、相对目录、附件清单）。

## 4. 格式、schema 与往返能力

- **jsonl**：导出输出每行一个会话对象，与 `import_sessions` 的输入同形状，往返存在（`hermes_state_portability.py`）。往返语义如下：
  - 同 id 会话跳过；
  - 父链仅在父存在时恢复，否则拆离为孤立会话；
  - `last_activity_*` 字段导入时重置为 NULL；
  - 尺寸与条数受硬上限约束（`_IMPORT_MAX_*`）。
- 每个结构化会话导出都附带文本无关的 `timings` 证据：按持久化消息时间戳给出首末时间、墙钟跨度、最大相邻间隔、角色计数、工具调用/结果数与逐消息间隔。Hermes 没有持久化独立的模型或工具秒表，因此该摘要明确标记 `complete: false`；没有时间戳时给出不可用原因。导入时该派生字段不计入内容尺寸预算，下次导出会重新计算（`hermes_state_portability.py`）。
- **md/qmd**：无 Markdown 导入路径（本次未找到）。导出侧包含：
  - frontmatter 带 exporter 版本标记（`EXPORTER_VERSION = "hermes sessions export (md/qmd) v1"`，`session_export_md.py`）与 `lineage_session_ids` 血缘 id 列表；
  - SHA256 校验行与 "Export verification" 段落（`session_export_md.py`），`verify_export_file` 可复核哈希与消息数（`session_export_md.py`）；
  - `manifest.jsonl` 追加每次导出记录（含 sha256，`session_export_md.py`）。
- trace：Claude Code JSONL，供 Hugging Face Agent Trace Viewer 消费，非 Hermes 自有格式（`trace_upload.py`）。
- html：无版本/schema 标记。

## 5. 分享稿编辑、编排与预览

不适用。导出前没有独立预览、内容开关、重排或编辑工作台；`--dry-run` 仅打印将匹配的会话列表（`sessions_cmd.py`）。`/save` 直接写文件并打印路径，无预览。HTML 模板是固定版式（主题深浅色自适应），无主题/尺寸/水印配置。

## 6. 图片、HTML、PDF 与富内容生成

- HTML 是唯一文档型交付物：内联 CSS/JS 的单文件模板，`secrets` 生成 script nonce，CSP 收紧（`default-src 'none'`），正文全部 HTML 转义，不支持 Markdown 渲染（代码块、表格、数学原样成文本）；多会话导出带侧边栏导航（`generate_multi_session_html_export`，`session_export_html.py`）。
- 图片导出（PNG/JPEG）、PDF、打印路径：本次未找到。
- 富内容降级：HTML 中 image → 占位文本；md 中所有内容按文本保留。

## 7. 生成历史、版本与持久化

- `/save`：每次生成新时间戳文件（秒级，同一秒内会覆盖），无列表、无去重、无版本管理；历史即目录里堆叠的文件。
- md 导出：默认拒绝覆盖已存在文件（`FileExistsError`，`session_export_md.py`），`--force` 覆盖；`manifest.jsonl` 追加记录构成可追踪的导出历史（含 sha256）。
- `--delete-after-verified`：md/qmd 校验通过后删除源会话（需 `--yes`，`sessions_cmd.py`）——导出文件的校验状态成为删除前提。
- 运行期自动快照及其实体文件守卫已随该功能一起移除，现在的持久化只有 SQLite 写入与显式导出两条。

## 8. 分享载体、访问控制与撤销

- 对话交付物全部为本地文件（saved 目录、session-exports 目录、stdout），无内置分享/复制动作。
- 唯一远端发布：HF 轨迹数据集（`agent/trace_upload.py`），默认 `private=True` 私有数据集，`--public` 可公开；上传 idempotent（`create_repo exist_ok`），提交信息含 session id；**无删除、撤销、过期或成员管理路径**（HF 侧的治理不在本地代码内）。
- `hermes debug share`（`hermes_cli/debug.py`）：把系统信息+日志上传到 paste.rs/dpaste 公开链接（`--nous` 传 Nous 内部 S3 私有桶），有删除 paste.rs 链接的命令（`debug.py`）。这是**诊断分享**，内容为日志与系统信息（"may contain conversation fragments"，`debug.py`）；它不从对话内容抽取交付物，因而不计入本类目主链。
- 对话内容的 URL/链接分享（会话快照页、公开页面、Gist）：本次未找到。

## 9. 隐私、安全与内容治理

- `/save` 默认不脱敏，原样落盘（含可能的密钥泄露内容）；`redact` 是显式选项，CLI 与网关侧都走 force 模式脱敏。
- `export jsonl/md`：`--redact` 可选，force 模式 `redact_sensitive_text` 深拷贝所有消息 content 与 tool_calls（`session_export_md.py`）；不传则原样。
- trace：**默认强制脱敏**（`redact=True` 经 `agent.redact.redact_sensitive_text force=True`），脱敏失败抛 `TraceRedactionError` 并拒绝上传（`trace_upload.py`），`--no-redact` 需显式勾选。
- HTML：全部用户内容 `_escape_html`（`session_export_html.py`）+ CSP nonce（`default-src 'none'; script-src 'nonce-…'`），`_generate_messages_html` 注释明确"prevents markup/JS injection"；图片、字体仅允许 data:/googleapis。
- 无导出前隐私提示、无 system prompt 开关（trace 无条件丢弃 system 消息；md/html 不写 system_prompt 字段——`/save` TUI 版除外，它**包含**完整 system prompt 原文）。

## 10. 性能、失败恢复与测试

- 大会话防护：`hermes sessions export`（console 引擎）有 per-session 消息数 guard（`sessions.max_export_messages` 默认 20000，`hermes_cli/console_engine.py`；`config_defaults.py`）；Web 导出用 keyset 分页流式输出（`web_routers/sessions.py`）。
- 导入上限：`_IMPORT_MAX_SESSIONS`、`_IMPORT_MAX_MESSAGES_PER_SESSION`、`_IMPORT_MAX_SESSION_BYTES`、`_IMPORT_MAX_TOTAL_BYTES` 四类硬限（分别约束会话数、单会话消息数、单会话字节数、总字节数），配合原子写入（`hermes_state_portability.py`）。
- timing evidence 只从已持久化时间戳派生，不包含提示词、工具参数或结果文本；它能定位长间隔，不能区分模型计算、网络等待和工具运行各自耗时。
- `/save` 失败只打印错误不中断会话（`cli.py`）；目录创建失败同样只报错返回（`methods_session.py`）。
- 已有测试（运行行为未在本机复验）：
  - `/save` 写 profile 目录而非 CWD：`tests/test_tui_gateway_server.py`；
  - 保存位置与导出各格式：`tests/cli/test_save_conversation_location.py`、`tests/hermes_cli/test_session_export.py`、`tests/hermes_cli/test_sessions_export_md_cli.py`、`tests/hermes_state/test_session_md_export.py`；
  - export→import 往返：`tests/test_hermes_state.py`；
  - trace 上传与导出预算 guard：`tests/agent/test_trace_upload.py`、`tests/hermes_cli/test_console_engine.py`。

## 11. 设计取舍与已确认边界

- **`/save` 快照 ≠ 导出交付**：快照是即时落盘的会话文件，无 schema 承诺、默认不脱敏、无下游消费者；导出子系统走 DB 抽取 + 脱敏 + 格式化渲染。两条管线并行，字段口径由各自的渲染函数决定：`/save` 走 `render_session_for_save`，批量导出走 `render_sessions_export`。
- 文档与实现的锚点：`sessions.md`"convenience exports, not the index"、`save_conversation` 的 docstring（convenience export only）、会话持久化测试的模块 docstring（automatic persistence stays in SQLite）。三者共同确认：canonical 事实源是 state.db，快照只是旁路。
- 导出子系统把"研究"当一等公民：trace 格式选第三方标准（Claude Code JSONL）而非自有 schema，上传默认私有；轨迹 JSONL 走 ShareGPT 格式（系统消息含工具定义、reasoning 包 `<think>`，`agent/agent_runtime_helpers.py`），配套 `trajectory_compressor.py` 与 `datagen-config-examples/` 说明轨迹是数据生成管线的原料（`batch_runner.py`）。
- 隐私默认值不对称：面向研究的 trace 默认强制脱敏、拒绝风险上传；面向个人的 `/save` 零加工。脱敏是可选项而非默认（jsonl/md 的 `--redact`）。
- HTML"无远程依赖"声明与 Google Fonts 外链并存（`session_export_html.py-34`），离线性需运行验证。
- 会话删除保护闭环：md 导出校验（哈希+消息数+session id）通过才允许删源会话，把"导出验证"接入"删除授权"。
- 状态快照的边界：当前代码继续把 `/snapshot restore` 归入 profile 状态恢复而非对话交付，恢复 SQLite 时使用备份 API，并针对仍被本进程连接持有的数据库拒绝继续（`hermes_cli/backup.py`、`hermes_state.py`）；状态备份/恢复与 `session.save`、`hermes sessions export` 生成的内容分属两类交付物。

## 12. 未验证事项

- `/save` 与 `session.save` 实际落盘文件的字段全集（尤其 `reasoning` 是否随 DB 快照写入）——静态推断：DB 有 reasoning 列且导出会带上，但 `/save` 的 json 渲染对哪些字段做裁剪未逐行核对。
- `hermes sessions export --format trace --upload` 的 HF 端实际行为（token 解析、私有数据集创建、`--public` 后内容治理）。
- HTML 导出的真实离线表现（Google Fonts 缺失时回退）、reasoning 折叠块与 JS 交互在无网络环境的行为。
- dashboard Sessions 页导出/导入的实际交互与导入校验反馈。
- 同一秒内重复 `/save` 的覆盖行为、快照目录的积累与清理策略（本次未找到清理机制）。
- `trajectory_compressor.py` 与 `datagen-config-examples/` 的端到端消费闭环（示例配置的消费入口本次未下钻）。

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
