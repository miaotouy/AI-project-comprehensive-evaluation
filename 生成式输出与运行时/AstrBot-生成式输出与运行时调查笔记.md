# AstrBot 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：静态代码阅读为主；grep/glob 检索 `astrbot/core` 与 `dashboard/src` 中 artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、runtime、preview 等关键词；走通 WebChat 聊天链路（发送 → 流式生成 → 消息持久化 → 重新加载）与工具结果物化链路（执行 → 文件附件 → 工作区浏览）的实现路径；对照单元测试确认部分行为
>
> 调查范围：模型生成内容的对象化与运行环境：`<html-genui>` 内联 HTML 预览、WebChat 消息协议与持久化、工具文件结果的物化与下载、会话/项目工作区、本地与沙箱代码执行。未运行服务与前端，全部结论为静态分析；UI 视觉效果、iframe 实际执行行为、沙箱远端行为未经运行验证。普通 Markdown 渲染、工具调用调度（Agent 类目）仅记录与本类目的交接点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的生成式输出目前分两类：一是 ChatUI 内联 HTML 预览（`<html-genui>` 私有标记），模型把完整 HTML/CSS/JS 以纯文本形式写入消息，前端用不含 same-origin 的沙箱 iframe 按 500ms 节流重渲染，源码以消息文本持久化，重新打开会话后由同一 Markdown 管线重建；二是工具执行结果物化，代码在本机子进程或远端沙箱运行，产物文件经 `[FILE]/[IMAGE]` 前缀协议变成带 `attachment_id` 的附件 part 并可下载，同时落在会话/项目工作区目录，前端提供只读的文件树浏览与预览。两条链都没有"独立对象"身份：GenUI 块没有 ID、版本、diff 或能力桥，用户不能编辑输出，模型修订只能整块重发；工作区文件可被模型用读写/编辑/搜索工具定向维护，但用户侧只有只读投影。按能力谱系评定为 **G1 完全成立、G3 部分成立（弱对象版本）**：存在专用执行环境（iframe 脚本、本机/沙箱语言进程）且用户可实际操作，但输出未获得独立对象生命周期，也没有 G4/G5 的编辑、diff、版本与模型侧对象维护能力。

## 系统边界与完整主链路

本类目涉及的模块：

| 层次 | 主要入口 | 职责 |
| --- | --- | --- |
| 后端 WebChat 链路 | `astrbot/dashboard/api/chat.py` → `astrbot/dashboard/services/chat_service.py` → `astrbot/core/platform/sources/webchat/` | SSE 流、消息持久化、附件登记；webchat 事件与 `[IMAGE]/[FILE]` 物化协议 |
| Agent 输出侧 | `astrbot/core/astr_main_agent/`、`astrbot/core/astr_main_agent_resources.py` | 提示词装配、GenUI 开关、`<html-genui>` 输出协议提示词 |
| 执行运行时 | `astrbot/core/computer/`、`astrbot/core/tools/computer_tools/` | 本地 booter 与多种远端沙箱运行时（olayer 协议）；shell、python、fs、cua 工具 |
| 工作区 | `astrbot/core/workspace.py`、`astrbot/dashboard/services/chatui_project_service.py`、`astrbot/dashboard/api/chat_projects.py` | 会话/项目/自定义三类根目录；项目与只读文件浏览 API |
| 前端 | `dashboard/src/components/chat/`、`dashboard/src/composables/useMessages.ts` | 消息列表、GenUI 预览、工作区面板与工具结果卡片（ChatMessageList、MessageList、HtmlGenUiNode、WorkspaceFilesPanel、ToolCallCard、IPythonToolBlock）；SSE/WS 协议 |

**主链路一（HTML GenUI 预览）**：聊天页每次发送请求都固定带上启用内联 GenUI 的标志（`dashboard/src/composables/useMessages.ts:9-19`），后端读到该标志后注入输出协议提示词（`astr_main_agent/persona.py:50-51`），要求模型恰好产出一个 `<html-genui>...</html-genui>` 块。模型按普通文本流式吐出这个块，前端在流式渲染时用自定义标签把它解析成 GenUI 节点，交给 iframe 以 srcdoc 预览，并按 500ms 节流整文档重建；后端把纯文本合并进消息 parts 写入历史，重新打开会话时前端沿同一条渲染管线把预览重建出来。解析、预览与持久化的具体入口见文末源码索引。链路各环节都有源码依据，未做运行验证。

**主链路二（代码执行与文件物化）**：用户请求触发模型调用执行工具与文件系统工具（入口如 `astrbot_execute_python`，实现见文末源码索引）；本机每次调用起一个独立子进程，也可以改走远端沙箱（`computer_client.py:552-667`）。产物沿消息链交给发送层，转成带 `[FILE]/[IMAGE]` 前缀的文本标记，后端把文件复制进附件目录并登记，前端渲染为带下载按钮的附件卡（`webchat_event.py:114-183`、`chat_service.py:1164-1189`，渲染见第 5 节）。同一个文件同时落在会话/项目工作区，用户可从文件面板只读浏览、预览、下载（面板与只读 API 的定位见文末源码索引）。

**主链路三（模型侧文件维护闭环）**：模型用 grep/read 类工具查询、用 write/edit 类工具定向修改工作区文件，工具类别与实现见第 9 节及文末源码索引；路径权限按 admin/成员、local/sandbox 分层（`util.py:62-76`、`fs.py:83-293`）。对 `<html-genui>` 对象没有等价查询/定向修改 API，修订只能由模型在对话新回合整块重出（提示词约定，`astr_main_agent_resources.py:76`）。

## 1. 触发方式、输出协议与对象模型

**触发**：GenUI 由前端请求标志触发，而非用户命令。`enable_inline_genui` 默认 True（`astrbot/core/platform/sources/webchat/request_flags.py:4`），前端构造请求固定开启（`useMessages.ts:14`），由 `event.get_extra("enable_inline_genui")` 决定是否注入输出协议提示词（`astr_main_agent/persona.py:50-51`）。非 WebChat 平台（QQ 等）没有该标志，也不会注入协议。

**输出协议**：协议是一套私有文本标记，没有结构化的消息 part。全部约定写在 `CHATUI_INLINE_GENUI_SYSTEM_PROMPT` 中（`astr_main_agent_resources.py:69-85`）：

- 输出恰好一个 `<html-genui>...</html-genui>` 块，开标签可带 `title` 属性；
- 该块不用 Markdown 代码围栏包裹，内容自包含 HTML/CSS/JS；
- 修订时重新输出完整新块，不用 diff 表达改动。

后端完全不解析这个标记，它只是 `plain` part 里的普通文本；解析全部发生在前端，由 markstream-vue 的自定义标签机制完成（`chatMarkdownComponents.ts`）。由此带来两点后果：协议开放度很低，靠私有标记加提示词约定；"误触发/半截流"的处理依赖第三方渲染库的流式解析能力，本项目没有自己的标记解析器。

**对象模型**：不存在独立的输出对象。GenUI 块没有 ID、类型、状态、版本字段，它作为消息文本的一部分随消息持久化，消息结构形如：

```text
{"type":"bot","message":[{"type":"plain","text":"..."}]}
```

这段结构由消息持久化入口写入，事实源是消息历史记录与附件表，两者分别由 `PlatformMessageHistory` 与 `Attachment` 承载。文件产物另有附件 ID 与落盘文件名两层身份，前者即 `attachment_id`。附件生命周期跟随会话删除而回收，不存在独立的可寻址对象库；写入、登记与回收逻辑集中在 `chat_service.py:141-742,1415-1451`，附件 part 的生成见 `message_parts_helper.py:450-457`。

## 2. 增量生成、更新与最终化

**文本流**：Agent 逐 token 或逐块产出，发送层把每段增量包装成 `streaming: true` 的 plain 事件写入队列（`webchat_event.py:60-71`）；后端消费循环用消息累积器合并尚未落库的文本，遇到非流式块或结束标记时一次性落库（`chat_service.py:169-232,1015-1041`）。前端把收到的增量追加到最后一个 plain part 上（`useMessages.ts:1509-1518`）。

**GenUI 更新**：不是节点级更新——每次内容变化（节流 500ms）就整文档重建预览（`buildSrcdoc`，`HtmlGenUiNode.vue:89-113`），流式期间旧 iframe 保留、新文档替换，无 diff/patch、无 DOM 复用，loading 期间维持加载样式。失败流处理：服务端消费循环异常时发布 `error` 事件并尽力冲刷未完成的 bot 消息（`chat_service.py:1233-1261`）；前端在断开时追加错误文本（`useMessages.ts:714-719`）。

**文件 part 最终化**：`[IMAGE]/[FILE]` 事件到达时同步完成复制+登记，`attachment_saved` 事件把 `attachment_id` 推给前端（`chat_service.py:1156-1201`）。

**修订**：无补丁协议。用户可对 bot 消息整体"重新生成"（`RegenerateMenu` → `chat_service.py:1928-2032`，回滚该回合 LLM 历史后重跑），GenUI 修订则依赖模型按提示词在新回合输出完整新块（`astr_main_agent_resources.py:76`）。每次修订产生新消息，对象身份没有延续机制。

## 3. 投影表面与多视图关系

- **GenUI**：只有消息内的一种 inline 投影，即聊天消息栈里的 `<html-genui>` 节点。节点上提供 Preview 与 Source 两个静态标签，二者都从同一份源文本派生（`HtmlGenUiNode.vue:5-27`），没有独立标签页、侧栏或画布视图。
- **文件产物**：有两种投影——消息内的附件卡片（带下载按钮，`ChatMessageList.vue:217-252`）与侧边工作区文件树（可读文件、预览、下载，`WorkspaceFilesPanel.vue`）。两处对应磁盘上的不同副本：消息侧指向 `attachments/` 下的附件副本，工作区侧指向 `workspaces/` 下的原件（见第 8 节）。
- **插件页面 iframe**：`PluginPagePage.vue:645-653` 提供带 `postMessage` 宿主桥的插件页面 iframe（`PluginPagePage.vue:26-68,523-533`）。这是插件生态的宿主页面，不是生成式输出，本类目仅记录其存在以排除混淆。
- 未找到无限画布、桌面挂件、独立窗口投影；`canvas` 关键词仅在 `HtmlGenUiNode.vue:167` 的 CSS 中出现。

## 4. 表现类型、依赖与运行环境

**GenUI**：支持完整 HTML/CSS/JS（`<script>` 可用，提示词明确要求自包含），无外部依赖供给机制——提示词要求自包含，iframe 为 opaque origin，外部资源只能靠网络加载且受 CORS 约束。运行环境为浏览器 iframe（`srcdoc`），无服务端 HTML 执行。流式 Markdown 渲染依赖第三方库 markstream-vue 1.0.5-beta.0（`dashboard/package.json:36`），GenUI 解析能力（含流式半截标记的容错）来自该库，仓库内无对应测试。

**代码执行**：本地与沙箱共四类运行时，本次未找到 notebook 或 REPL 类型的持续运行对象：

- 本地 Python：每次调用都用 `python -c` 起一个新的子进程（`booters/local.py:858-896`），没有持久 kernel。协议层保留了 `kernel_id` 参数（`olayer/python.py:8-18`），本地实现忽略它，Neo 实现标注 Bay SDK 不支持（`booters/shipyard_neo.py:62`）。
- 本地 Shell：每次调用起子进程执行；Windows 上优先探测 PowerShell 7（`pwsh`），探测失败再回退到 Windows PowerShell（`booters/local.py:59-61,163-180`）。另有 managed session 承载后台与交互式进程，输出写入临时日志文件再增量读取（`booters/local.py:212-855`）。
- 远端沙箱：提供 shipyard_neo、shipyard、cua、boxlite 等运行时。其中 shipyard_neo 基于 Bay，默认使用 python-default profile，可附带 browser 能力；cua 提供桌面 GUI。运行时的选择与生命周期见 `computer_client.py:589-667`，能力装配见文末源码索引（`astr_main_agent/computer_use.py:140-238`）。

## 5. 用户交互、事件与错误反馈

- **GenUI iframe**：用户可以在 iframe 内与页面交互——sandbox 放开了脚本（`allow-scripts`）、表单、弹窗、指针锁定等能力，完整清单见 `HtmlGenUiNode.vue:45-46`，其中不含 `allow-same-origin`。iframe 向宿主回传事件的通道不存在：节点内没有 postMessage 监听，也不上报尺寸、状态或日志。文档头部的 `<base target="_blank">` 让链接在新标签页打开（`HtmlGenUiNode.vue:157`）。交互状态不跨组件卸载保留，每次挂载都会新建一个 iframe。
- **工具卡片**：`ToolCallCard` 支持展开/收起、显示参数与结果、耗时计时（`ToolCallCard.vue:2-40,63-107`）；IPython 调用走 `IPythonToolBlock`（高亮代码与结果，`IPythonToolBlock.vue:5-21`）。这些是只读展示，无"继续编辑此代码并重跑"的交互。
- **文件 part**：下载按钮（`ChatMessageList.vue:273-287`），图片点击放大（overlay，`MessageList.vue:528-536`）。
- **错误反馈**：流错误/中止以纯文本附加到消息（`useMessages.ts:870-877,988-1041`）；`error` 事件由服务端 `_consume_chat_run` 发布（`chat_service.py:1238-1241`）。

## 6. 编辑、diff、版本与协作

- **消息编辑**：只有最新一条用户消息可以编辑；编辑后系统截断该消息之后的历史并重新生成回复（后端 `chat_service.py:1860-1873,1686-1712`，前端 `ChatMessageList.vue:615-623` 与 `Chat.vue:1734-1755`）。bot 消息连同其中的 GenUI 块都不能就地编辑，只能整条重新生成，用户对模型输出没有选区级或结构化编辑入口。
- **diff/版本**：不存在。提示词明确要求修订输出完整块而非 diff（`astr_main_agent_resources.py:76`）；文件编辑工具采用 old/new 字符串替换语义（`fs.py:477-503`，本地 booter 的同类实现见文末源码索引），无 diff 展示、无接受/拒绝、无撤销、无分支表达（"重新生成旧回合需要分支"被拒绝，`chat_service.py:1973`）。
- **协作**：用户与模型不同时编辑同一对象——用户不能改 GenUI/工作区文件，模型通过工具独占修改文件；没有 CRDT 类并发机制。
- **线程（thread）**：可从 bot 消息创建基于 checkpoint 的对话线程（`chat_service.py:1648-1729`），属于 Chat 类目的分支表达，与本类目对象无关。

## 7. 能力桥、执行位置与权限范围

**GenUI 无能力桥**：iframe 沙箱策略不含 `allow-same-origin`（opaque origin），脚本可运行但没有任何宿主 API；与插件页面 iframe（有 `postMessage` 桥，`PluginPagePage.vue`）形成对比——生成式输出没有获得插件页面同等的桥接能力。

**代码执行**：Local runtime 不再等同于无隔离宿主子进程。member/admin 各有文件范围、执行和联网策略；受限执行在 Linux 由 bubblewrap、macOS 由 Seatbelt 启动，清理环境变量并按策略暴露工作区、技能与临时目录，同时施加进程资源上限。Windows 没有本机进程沙箱后端，配置校验会拒绝需要隔离的策略；允许 host 文件范围或其他宽权限仍是显式高权限配置。远端 sandbox runtime 继续由 Bay/CUA 等外部环境隔离（`astrbot/core/computer/process_sandbox/base.py:8-57,154-250`；`process_sandbox/__init__.py:15-42`；`tools/computer_tools/util.py:93-309`；`dashboard/services/config_service.py:333-391`）。

## 8. 持久化、恢复、分享与导出

- **GenUI**：落库的是源文本，`<html-genui>` 标签原样留在消息的 plain part 里；会话历史接口返回后由前端重新渲染（`chat_service.py:1603-1679`、`useMessages.ts:292-323`）。恢复出来的是源文本加重建的预览 DOM，iframe 里的定时器、表单值、脚本变量等运行状态不随之恢复。没有分享链接与导出按钮，用户只能从 Source 视图手动复制文本。
- **附件**：登记表 + 磁盘副本，`attachment_id` 可寻址下载（`/files/{attachment_id}`，`dashboard/api/files.py:175-186`）；会话删除时级联删除附件文件（`chat_service.py:1415-1451`）。消息内 file part 提供下载（`ChatMessageList.vue` 的下载按钮逻辑）。
- **工作区文件**：落盘于 `data/workspaces/`（会话、`project_<id>`、自定义路径三类根，`workspace.py:65-91,121-165`），文件本身即持久化源；项目元数据存 DB。浏览/读/下载 API 为只读（`chatui_project_service.py:176-419`、`chat_projects.py:160-212`），无用户写入口。
- **导出**：项目工作区文件可单个下载（`chat_projects.py:188-212`）；未发现目录打包/项目级导出。

## 9. 模型回流、对象感知与持续维护

- **GenUI**：没有对象级的模型回流。模型只能通过对话历史感知此前的输出——assistant 消息里带着完整的 `<html-genui>` 文本，修订时在新回合整块重出（`astr_main_agent_resources.py:76`）。查询对象列表、读取对象状态、定向修改对象的 API 均不存在。
- **文件**：模型侧闭环完整——grep/read 类工具查询读取，`astrbot_file_edit_tool` 等 write/edit 类工具定向修改（实现见文末索引 `fs.py:306-808`）。cwd 固定在会话/项目工作区（`workspace.py:191-217`，路径权限见 `computer_tools/util.py:28-50`）。这是"查询 → 读取 → 定向修改"闭环，对象是普通磁盘文件；模型用工具修改后，用户从工作区面板可看到更新。
- **沙箱**：shipyard_neo 提供执行历史/注释/技能候选等 Neo 工具（`astr_main_agent/computer_use.py:207-218`），用于技能生命周期，不属于通用输出对象回流。

## 10. 生命周期、资源治理与性能

- **GenUI**：iframe 只存在于消息渲染期间，`loading="lazy"` 让它延迟加载（`HtmlGenUiNode.vue:35`）。组件卸载时只清理节流定时器（`HtmlGenUiNode.vue:82-87`），iframe 内的定时器、动画、媒体与 WebGL 没有登记与释放机制，随文档替换或组件销毁由浏览器回收，运行状态本身不持久（见第 8 节）。
- **代码执行**：本地 shell 每次调用有超时（默认 300s）；managed session 有硬超时/终止/输出上限，进程组终止后删除日志文件；Python 子进程每次调用超时默认 30s。这些时限、输出上限与日志清理逻辑集中在 `booters/local.py:17,212-264,339-359,800-824,871-894`。沙箱按会话缓存 booter，CUA 支持空闲超时自动关闭，失效 booter 删除沙箱避免泄漏（`computer_client.py:21,35-87,567-666`）。未发现对长会话/多对象输出数量的整体限额机制。
- **性能**：GenUI 预览采用 500ms 节流整文档重建；流式 Markdown 有 `MARKDOWN_RENDER_MAX_LIVE_NODES` 上限（`markdownRenderConfig.ts`）。这些属于渲染层治理，未发现针对 GenUI 对象本身的资源配额。

## 11. 测试、已确认边界与未验证事项

**已有测试**（静态确认，未运行）：

| 测试文件 | 覆盖行为 |
| --- | --- |
| `tests/unit/test_astr_main_agent.py:1062-1160` | `enable_inline_genui` 开启时注入提示词、无会话时也注入、关闭时不注入，覆盖触发与协议装配 |
| `tests/test_chat_route.py:451-487` | 请求 flags 归一化透传，含 `enable_inline_genui` |
| `tests/test_computer_fs_tools.py`（约 60+ 用例） | 读写/编辑/搜索工具的权限边界：成员受限目录、硬链接拒绝、超大文件、图片/PDF/docx/epub 读取等 |
| `dashboard/tests/`（共 5 个测试文件） | 偏好存储、路由、输入法等基础工具；`HtmlGenUiNode`、markstream 自定义标签与消息 part 渲染没有测试覆盖 |

**未验证事项**（未运行服务与前端）：
- `<html-genui>` 流式半截标签的解析容错实际行为（依赖 markstream-vue 1.0.5-beta.0，未运行验证）；
- iframe 内任意 HTML/JS 的实际运行与隔离表现（sandbox 属性行为、CORS 实际效果、`allow-popups` 弹窗）；
- 沙箱（shipyard_neo/cua/boxlite）远端行为与技能同步流程（`computer_client.py:457-548` 的 sync 脚本）；
- 重新打开会话后预览重建、附件下载、工作区浏览的端到端表现；
- 消息编辑/重新生成的 UI 流程、线程与 checkpoints 的行为（部分属于 Chat 类目）。

**已确认边界**：
- 后端不解析 `<html-genui>`；协议仅存在于提示词与前端渲染库。
- bot 消息不可编辑（`chat_service.py:1860-1861`），GenUI 无对象身份/版本/diff/导出。
- 工作区文件对用户只读（浏览/预览/下载 API 无写端点）。
- 本地 Python 无持久 kernel；`kernel_id` 为名义参数。
- 文档中未检索到 GenUI 说明（`docs/`、根目录 grep `html-genui` 均无结果），该能力仅存在于代码与提示词。

## 12. 关键源码索引

- `astrbot/core/astr_main_agent_resources.py:69-85`：`<html-genui>` 输出协议提示词（触发、格式、修订约定）
- `astrbot/core/astr_main_agent/persona.py:50-51`：`enable_inline_genui` 注入点；`astrbot/core/astr_main_agent/computer_use.py:140-238`：沙箱工具装配
- `astrbot/core/platform/sources/webchat/request_flags.py:4`：GenUI 标志默认值
- `astrbot/dashboard/services/chat_service.py`：SSE 运行状态机与消息持久化（`_consume_chat_run:897-1088`、`build_chat_stream:1090-1183`、`update_message:1621-1712`）
- `astrbot/core/platform/sources/webchat/webchat_event.py:38-183`：`[IMAGE]/[FILE]` 物化协议
- `astrbot/core/platform/sources/webchat/message_parts_helper.py:423-457`：附件 part 生成
- `dashboard/src/composables/useMessages.ts:9-19,1149-1470`：请求标志与流式协议处理
- `dashboard/src/components/chat/message_list_comps/HtmlGenUiNode.vue:29-46,89-169`：iframe 预览与沙箱策略
- `dashboard/src/components/chat/chatMarkdownComponents.ts:8-16`：custom-tag 注册
- `astrbot/core/tools/computer_tools/fs.py:306-808`：读/写/编辑/grep 工具
- `astrbot/core/tools/computer_tools/python.py:79-152`、`astrbot/core/tools/computer_tools/shell.py`：执行工具
- `astrbot/core/computer/booters/local.py:127-210,828-866,1048-1081`：本地执行运行时与文件编辑实现
- `astrbot/core/computer/computer_client.py:552-667`：运行时选择与沙箱生命周期
- `astrbot/core/workspace.py:65-165,191-217`：工作区解析
- `astrbot/dashboard/services/chatui_project_service.py:176-419`、`astrbot/dashboard/api/chat_projects.py:160-212`：工作区只读 API
- `dashboard/src/components/chat/WorkspaceFilesPanel.vue:326-462`：工作区文件面板
- `dashboard/src/components/chat/message_list_comps/ToolCallCard.vue`、`IPythonToolBlock.vue`：工具结果展示
