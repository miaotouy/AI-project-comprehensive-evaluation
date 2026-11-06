# OpenOcta 对话导出与分享调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态阅读会话持久化、Gateway 方法与 Control UI 源码；按 export、download、share、clipboard、copy、markdown、report、attachment、logs、cron 等关键词检索 `src`、`ui/src`、`docs`；未运行桌面端、Gateway 或 UI
>
> 调查范围：会话与任务结果是否能形成面向用户的导出物、报告、日志归档、剪贴板或文件交付；区分运行时持久化与用户导出。不覆盖数据库/索引迁移、整库备份、普通附件上传、媒体对象自身导出与 Chat UI 的按钮布局细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 把会话按 JSONL 追加写入本地目录，但面向用户的抽取与交付只有三个窄口，外加一条任务结果外发：

- 单条助手回复的「Copy as markdown」：把气泡中的可见正文写入剪贴板，不带思考、工具卡、附件或用户消息。
- 「提炼 SKILL」：读取整个会话历史，调用模型生成一份 SKILL.md，在只读弹窗中预览后可下载为 `.md` 文件。这是从对话派生的文档，不是会话转录。
- 日志页「Export visible / Export filtered」：把当前日志缓冲的原始行下载为 `.log` 文本，导出对象是运行日志而非对话。
- 定时任务完成后，把最终回复摘要投递到 IM 渠道或 Webhook；这是任务结果的传播，不是会话导出。

本次未找到会话级或批量导出、HTML/PDF/图片分享稿、公开链接或站内快照、导入往返、导出历史与版本，也没有分享权限、撤销或保留期语义。Control UI 的会话页只提供刷新、筛选、改标签、压缩与删除。

## 系统边界与总体调用链

会话事实源是本地文件，不是数据库：Linux/macOS 为 `~/.openocta/agents/<agentId>/sessions/<sessionId>.jsonl`（Windows 为 `%APPDATA%\openocta` 下的同一相对路径），首行为会话头，后续每行一条消息；同目录的 `sessions.json` 保存 session key 到会话文件的索引（`src/pkg/session/paths.go:70-82`、`src/pkg/session/store.go:16-39`）。转录格式版本为 2，单行读取上限 32 MiB，以兼容包含长工具输出的行（`src/pkg/session/transcript.go:107-113`）。

用户可见的抽取路径有两条，都不经过统一的「导出服务」：

1. 复制：`chat.history` 把消息交给 UI，气泡渲染时从消息内容计算 Markdown，点击按钮直接写剪贴板（`ui/src/ui/chat/grouped-render.ts:1470-1482`、`ui/src/ui/chat/copy-as-markdown.ts:15-44`）。
2. 提炼：输入区按钮调用 `chat.extractSkill`，后端读转录、拼提示词、跑一个禁用工具的子运行时，把模型输出规范化后返回 Markdown 与文件名（`src/pkg/gateway/handlers/chat_extract_skill.go:33-174`）。

另外两条是「结果外发」而非「会话导出」：定时任务摘要经 `DeliverCronResultIfNeeded` 发往渠道或 Webhook（`src/pkg/gateway/handlers/cron_delivery.go:111-199`）；Agent 写出的报告类文件被转成聊天附件块，由前端提供预览与下载（`src/pkg/agent/tools/deliverable_files.go:48-85`、`ui/src/ui/chat/file-blocks.ts:652-684`）。

## 1. 入口、用户目标与导出源

| 入口 | 触发者 | 导出源 | 粒度 | 交付物 | 目标 |
|---|---|---|---|---|---|
| 消息气泡「Copy as markdown」 | 用户 | 单条助手消息的可见正文 | 单消息 | 剪贴板文本 | 个人复用片段 |
| 输入区「提炼SKILL」 | 用户 | 整个会话转录 | 整会话 | 只读预览 + `.md` 下载 | 把经验固化为可复用技能 |
| 日志页导出按钮 | 用户 | 已加载的日志行 | 当前缓冲/筛选结果 | `.log` 文件 | 运维排障归档 |
| 定时任务 delivery | 调度器 | 该次运行的最终回复 | 单次运行摘要 | IM 消息或 Webhook JSON | 值班通知 |
| 聊天附件下载 | Agent 产物 | 工作区内文件 | 单文件 | 内联 base64 附件 | 报告/脚本交付 |

「复制」按钮只出现在助手气泡；用户消息没有对应按钮，因为渲染条件要求 `role === "assistant"` 且存在可见文本（`ui/src/ui/chat/grouped-render.ts:1482`、`:1518`）。「提炼」按钮在会话加载中或消息为空时隐藏，条件基于 UI 当前已加载的消息数组，而非后端转录长度（`ui/src/ui/app-render.ts:2678-2682`）。

## 2. 内容口径与字段过滤

**复制。** 计算 Markdown 时优先取消息的可见文本，其次取 A2UI 展示文本；随后剥离本地图片引用，文本为空则取消按钮（`ui/src/ui/chat/grouped-render.ts:1470-1482`）。同一气泡中的思考面板、工具调用卡、图片与文件附件是独立渲染分支，不进入这段 Markdown。因此复制结果是「本气泡的正文」，不含上下文、思考、工具参数或工具输出。A2UI 组件树本身也不会被序列化，只取其中的展示文本。

**提炼。** 后端读取转录时不设消息上限，按文件顺序遍历；格式化阶段跳过空角色、`system`、`toolResult` 与 `tool`，只保留用户与助手的文本块，并把思考块以 `[思考] 内容` 的形式拼进去（`src/pkg/gateway/handlers/chat_extract_skill.go:54`、`:176-218`）。图片、文件、工具调用参数与工具结果不参与。转录行的包装结构带有 `parentId`，但读取函数只反序列化 `type` 与 `message`，提取侧也不使用父子关系，因此没有活动分支或隐藏分支的概念，输出是全部追加行的顺序拼接（`src/pkg/session/transcript.go:257-307`）。

**提示词与输出。** 提示词要求输出带 YAML frontmatter 的完整 SKILL.md，禁止编造对话外内容；模型若返回代码围栏，会被剥离；文件名取自 frontmatter 的 `name` 字段，缺失时用 `extracted-skill.md`（`src/pkg/gateway/handlers/chat_extract_skill.go:18-30`、`:220-258`）。默认超时 120 秒，可由调用参数覆盖（`:92-97`）。

**日志。** 导出使用日志页当前内存缓冲（上限 2000 行），按级别与文本过滤；导出内容是命中的原始日志行，而不是解析后的字段（`ui/src/ui/controllers/logs.ts:18-19`、`ui/src/ui/views/logs.ts:46-78`）。

## 3. 附件、资源与离线封装

两条对话侧路径都不处理附件。复制只写文本；提炼跳过图片与文件块。因此交付物离开应用后无法还原会话中的图片、附件或工具产物。

相对独立的「任务产物交付」会把 Agent 写出的文件读成 base64 内联到消息内容块，前端提供下载链接。允许的类型包括 HTML、Markdown、文本、JSON、YAML、CSV、PDF 与常见图片；大小上限分别为 HTML/PDF 2 MiB、图片 5 MiB、文本 2 MiB（`src/pkg/agent/tools/deliverable_files.go:14-34`、`:118-245`）。助手正文里提到的路径也会被正则扫描并补成附件块（`:490-553`），合并发生在 Gateway 写回消息内容时（`src/pkg/gateway/handlers/chat.go:2617`）。

预览 HTML/PDF 时使用 `sandbox=""` 的空沙箱 iframe，脚本不会执行（`ui/src/ui/chat/file-blocks.ts:623-633`）。文件内容以 base64 内联，但 HTML 内部引用的远端脚本、样式和图片是否可用取决于文件本身，本次未验证。

## 4. 格式、schema 与往返能力

用户可见的格式只有两种：纯文本 Markdown（复制或下载）与 `.log` 文本。两者都没有版本号、schema、元数据或来源会话标识。下载文件名来自模型生成内容的 frontmatter，未做字符清洗（`src/pkg/gateway/handlers/chat_extract_skill.go:164-167`、`ui/src/ui/controllers/chat-extract-skill.ts:44-52`）。

内部转录虽然是结构化 JSONL（会话头 + 消息行，含 usage、模型、耗时、工具结果字段），但没有把该 JSONL 暴露给用户的导出入口，也没有从导出物重新导入会话的路径（`src/pkg/session/transcript.go:13-55`）。因此不存在往返能力，也不存在未知字段与分支关系的保留问题。

## 5. 分享稿编辑、编排与预览

提炼结果有一个独立的预览表面：模态卡片用 `<pre>` 原样显示 Markdown，底部只有「下载」和「关闭」，没有编辑、选区、排序、主题、分页或水印（`ui/src/ui/views/chat.ts:761-785`）。预览字符串与下载 Blob 使用同一个状态变量，因此预览与产物同源；关闭只是隐藏弹窗，不产生版本或历史（`ui/src/ui/app-render.ts:2685-2700`）。

复制路径没有任何预览或编排，点击即写剪贴板。日志导出同样没有预览，直接以当前过滤结果生成文件。

## 6. 图片、HTML、PDF 与富内容生成

对话内容没有图片、HTML 或 PDF 生成管线：没有离屏渲染、滚动拼接、打印分页或分享图能力。唯一的富内容再渲染是聊天现场的 Markdown 渲染，与导出无关。

任务产物侧存在 HTML/PDF 文件的预览与下载，但输入是 Agent 已写好的文件，不是从对话重建的分享稿。这属于「生成式输出」的交付边界，不作为本类目的对话导出能力。

## 7. 生成历史、版本与持久化

没有版本概念。每次提炼都覆盖组件内的加载状态、Markdown 与文件名，关闭弹窗只把 `open` 置回 false，已生成的内容仍留在页面状态里，直到下一次提炼覆盖或页面重载；后端也不落盘任何提炼结果（`ui/src/ui/app-render.ts:2689-2691`、`src/pkg/gateway/handlers/chat_extract_skill.go:169-173`）。重新提炼即重新调用模型，旧结果不可比较、不可恢复。

复制与日志导出不产生历史记录。定时任务侧有运行日志，但那是调度记录而非导出历史（见下节）。

## 8. 交付载体、访问控制与撤销

| 载体 | 实现 | 访问语义 |
|---|---|---|
| 剪贴板 | `navigator.clipboard.writeText`，非安全上下文回退到隐藏 textarea + `execCommand` | 本机当前用户，无鉴权 |
| 文件下载 | `Blob` + `URL.createObjectURL` + 合成 `<a download>`，点击后立即回收 URL | 落到浏览器下载目录，无访问控制 |
| 日志文件 | 同上，文件名 `openclaw-logs-<label>-<时间戳>.log` | 无访问控制，命名仍沿用旧产品名 |
| IM 投递 | 调用 Gateway 的 `send` 方法，带 `channel`、`to`、`header` | 取决于渠道账号权限 |
| Webhook | POST JSON，字段为 `jobId`、`sessionKey`、`summary`、`status` | 仅校验 http/https 前缀，无签名、重试或鉴权 |

不存在远端快照、可访问 URL、登录要求、撤销或过期机制。所谓「分享」只能由用户自行搬运剪贴板内容或下载文件后通过外部工具传播。

定时任务投递前会做 10 秒内的同摘要去重，header 截断到 50 字符；投递失败时返回值被丢弃，没有重试或失败记录（`src/pkg/gateway/handlers/cron_delivery.go:42-61`、`:142-199`）。运行结果另写两份 JSONL：调度器按 `runs/<jobId>.jsonl` 记录状态，聊天完成回调按 `runs/<sessionId>.jsonl` 记录摘要；`cron.runs` 只读前者（`src/pkg/cron/service.go:50-84`、`src/pkg/gateway/handlers/chat.go:1165-1239`、`src/pkg/gateway/handlers/cron.go:522-531`）。

## 9. 隐私、安全与内容治理

提炼会把整段会话（含思考块）发送给当前配置的模型提供商，且没有脱敏、字段排除或二次确认步骤。用户只看到「提炼SKILL」按钮，看不到将要发送的内容范围。被跳过的只有 system、工具结果与工具调用，这减少了一部分敏感内容，但环境路径、命令、密钥若写在正文或思考中仍会进入请求（`src/pkg/gateway/handlers/chat_extract_skill.go:176-218`）。

复制不做任何过滤；日志导出包含原始日志行，可能含主机名、路径、请求参数等运维信息，具体是否含密钥取决于日志内容，本次未逐项核对。任务产物附件由路径正则扫描产生，读取被限制在 Agent 工作区内，越界路径会被拒绝（`src/pkg/agent/tools/deliverable_files.go:292-329`）。

`chat.attachment.read` 只校验会话 ID 与工作区路径，没有额外的按会话 ACL（`src/pkg/gateway/handlers/chat.go:1517-1553`）。这属于本地单用户信任模型的边界，而不是分享治理。

## 10. 性能、失败恢复与测试

- 复制按钮在写剪贴板期间禁用并标记 `aria-busy`，成功后 1.5 秒恢复，失败显示 2 秒错误标签；按钮断开连接时直接返回（`ui/src/ui/chat/copy-as-markdown.ts:51-111`）。
- 提炼失败会在输入区显示错误文本；空结果、无历史、模型工厂失败、运行时失败和空文档分别返回不同错误（`src/pkg/gateway/handlers/chat_extract_skill.go:66-81`、`:99-162`；`ui/src/ui/controllers/chat-extract-skill.ts:15-42`）。
- 提炼需要读取全部转录并一次拼进提示词，长会话没有截断、分段或摘要策略，只受 120 秒超时约束。大会话是否会超出模型上下文，本次未验证。
- 日志导出受 UI 缓冲 2000 行与服务端单次 5000 行/1 MB 的限制，导出的是已加载片段，不是完整日志文件（`src/pkg/gateway/handlers/logs.go:15-20`、`ui/src/ui/controllers/logs.ts:18`）。
- 本次未找到复制、提炼或日志导出的自动化测试；`ui/src/ui/chat` 下的测试覆盖消息抽取、附件块与 A2UI，不覆盖这三个入口。

## 11. 设计取舍与已确认边界

- 项目把会话文件当作内部事实源，没有把它包装成用户导出格式；因此没有 JSON/JSONL 导出，也没有导入。
- 分享能力被压缩为「单消息复制」与「经验提炼下载」，面向的是复用与沉淀，不是会话传播。
- 提炼输出的是 SKILL.md，不是对话记录。它改变的是内容形态，且只保留文字与思考，丢弃工具链证据。
- 定时任务是唯一自动外发通道，但外发内容是最终回复摘要，且只截取最后一个工具块之后的文字，思考与工具输出不会进入 IM（`src/pkg/gateway/handlers/chat.go:1072-1103`）。
- 用量页的 i18n 文案与样式表存在「Sessions (CSV)」「Daily (CSV)」等条目，本次在视图层与控制器层未找到对应实现，这条导出入口目前只出现在文案层（`ui/src/ui/strings.ts:603-604`、`:1609-1610`）。

## 12. 未验证事项

- 未在桌面端实际点击复制、提炼与日志导出，未验证剪贴板行为、下载文件名、长会话表现与弹窗布局。
- 未验证不同模型对提炼提示词的遵循程度，以及 frontmatter 名称含路径字符时的浏览器实际处理。
- 未验证 IM announce 投递在真实企业微信/飞书/DingTalk 账号下的送达、去重与失败表现。
- 未验证日志内容是否实际包含密钥或个人数据；本笔记只确认导出机制，不对日志内容作断言。
- 未验证项目外（官网、AMC、伴生服务）是否存在会话分享能力；本结论仅覆盖本仓库快照。

## 关键源码索引

- 剪贴板：`ui/src/ui/chat/copy-as-markdown.ts:15-115`、`ui/src/ui/chat/grouped-render.ts:1470-1518`
- 提炼入口与预览：`ui/src/ui/views/chat.ts:761-785`、`:1203-1218`、`ui/src/ui/app-render.ts:2678-2700`
- 提炼后端：`src/pkg/gateway/handlers/chat_extract_skill.go:33-258`
- 转录持久化：`src/pkg/session/transcript.go:107-307`、`src/pkg/session/paths.go:70-82`、`src/pkg/session/store.go:16-39`
- 日志导出：`src/pkg/gateway/handlers/logs.go:263-299`、`ui/src/ui/controllers/logs.ts:99-147`、`ui/src/ui/views/logs.ts:46-78`、`ui/src/ui/app-scroll.ts:140-152`
- 定时任务投递：`src/pkg/gateway/handlers/cron_delivery.go:111-199`、`src/pkg/gateway/handlers/chat.go:1072-1103`、`:1165-1239`
- 任务产物附件：`src/pkg/agent/tools/deliverable_files.go:48-85`、`:490-553`、`ui/src/ui/chat/file-blocks.ts:623-684`
