# AstrBot 生成式输出与运行时调查笔记

> 调查对象：`../../AstrBot`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`346b85db9d79207ea7b51694cce5276203612af4`（分支：`master`）
>
> 调查方式：静态代码阅读为主；grep/glob 检索 `astrbot/core` 与 `dashboard/src` 中 artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、runtime、preview 等关键词；走通 WebChat 聊天链路（发送 → 流式生成 → 消息持久化 → 重新加载）与工具结果物化链路（执行 → 文件附件 → 工作区浏览）的实现路径；对照单元测试确认部分行为
>
> 调查范围：模型生成内容的对象化与运行环境：`<html-genui>` 内联 HTML 预览、WebChat 消息协议与持久化、工具文件结果的物化与下载、会话/项目工作区、本地与沙箱代码执行。未运行服务与前端，全部结论为静态分析；UI 视觉效果、iframe 实际执行行为、沙箱远端行为未经运行验证。普通 Markdown 渲染、工具调用调度（Agent 类目）仅记录与本类目的交接点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的生成式输出目前分两类：一是 ChatUI 内联 HTML 预览（`<html-genui>` 私有标记），模型把完整 HTML/CSS/JS 以纯文本形式写入消息，前端用 sandboxed iframe（`allow-scripts` 但不含 `allow-same-origin`）按 500ms 节流重渲染，源码以消息文本持久化，重新打开会话后由同一 Markdown 管线重建；二是工具执行结果物化，代码在本机子进程或远端沙箱运行，产物文件经 `[FILE]/[IMAGE]` 前缀协议变成带 `attachment_id` 的附件 part 并可下载，同时落在会话/项目工作区目录，前端提供只读的文件树浏览与预览。两条链都没有"独立对象"身份：GenUI 块没有 ID、版本、diff 或能力桥，用户不能编辑输出，模型修订只能整块重发；工作区文件可被模型用读写/编辑/搜索工具定向维护，但用户侧只有只读投影。按能力谱系评定为 **G1 完全成立、G3 部分成立（弱对象版本）**：存在专用执行环境（iframe 脚本、本机/沙箱语言进程）且用户可实际操作，但输出未获得独立对象生命周期，也没有 G4/G5 的编辑、diff、版本与模型侧对象维护能力。

## 系统边界与完整主链路

本类目涉及的模块：

- 后端 WebChat 链路：`astrbot/dashboard/api/chat.py` → `astrbot/dashboard/services/chat_service.py`（SSE 流、消息持久化、附件登记）→ `astrbot/core/platform/sources/webchat/`（webchat 事件与 `[IMAGE]/[FILE]` 物化协议）
- Agent 输出侧：`astrbot/core/astr_main_agent.py`（提示词装配、GenUI 开关）、`astrbot/core/astr_main_agent_resources.py`（`<html-genui>` 输出协议提示词）
- 执行运行时：`astrbot/core/computer/`（booters：local / shipyard_neo / shipyard / cua / boxlite；olayer 协议），`astrbot/core/tools/computer_tools/`（shell、python、fs、cua 工具）
- 工作区：`astrbot/core/workspace.py`（会话/项目/自定义三类根目录），`astrbot/dashboard/services/chatui_project_service.py` + `astrbot/dashboard/api/chat_projects.py`（项目与只读文件浏览 API）
- 前端：`dashboard/src/components/chat/`（ChatMessageList、MessageList、HtmlGenUiNode、WorkspaceFilesPanel、ToolCallCard、IPythonToolBlock），`dashboard/src/composables/useMessages.ts`（SSE/WS 协议）

**主链路一（HTML GenUI 预览）**：Dashboard 聊天页发送请求带 `enable_inline_genui: true`（`dashboard/src/composables/useMessages.ts:7-13`）→ 后端注入 `CHATUI_INLINE_GENUI_SYSTEM_PROMPT`（`astrbot/core/astr_main_agent.py:509-510`），指示模型输出恰好一个 `<html-genui>...</html-genui>` 块 → 模型以普通文本流式产出该块（前端 `appendPlain`，`useMessages.ts:1113-1128`）→ markstream-vue 按自定义 HTML 标签解析出 `HtmlGenUiNode`（`dashboard/src/components/chat/chatMarkdownComponents.ts:8-16`）→ iframe `srcdoc` 预览，节流 500ms 整文档重建（`HtmlGenUiNode.vue:44,89-113`）→ 后端 `BotMessageAccumulator` 把纯文本合并进消息 parts 并写入 `PlatformMessageHistory`（`chat_service.py:908-943,1026-1041`）→ 重新打开会话 `get_session` 读历史，前端同一渲染管线重建 iframe（`useMessages.ts:257-283`；`chat_service.py:1395-1429`）。

**主链路二（代码执行与文件物化）**：用户请求 → 模型调用 `astrbot_execute_python` / `astrbot_execute_shell` / 文件系统工具（`astrbot/core/tools/computer_tools/python.py:80-153`、`fs.py:306-799`）→ 本机 `LocalBooter`（每次调用起独立子进程，`booters/local.py:129-211,828-866`）或远端沙箱（shipyard_neo 等，`computer_client.py:539-654`）→ 产物经 `MessageChain(File/Image)` → webchat `_send` 转成 `[FILE]文件名|显示名` / `[IMAGE]文件名`（`webchat_event.py:78-147`）→ `ChatService.create_attachment_from_file` 复制到 attachments 目录并登记 DB attachment（`chat_service.py:980-1005`；`message_parts_helper.py:358-392`）→ 前端渲染为带下载按钮的 file part（`ChatMessageList.vue:217-252`）→ 文件同时位于会话/项目工作区，用户可从 `WorkspaceFilesPanel` 只读浏览、预览、下载（`WorkspaceFilesPanel.vue:325-454`；`chat_projects.py:160-206`）。

**主链路三（模型侧文件维护闭环）**：模型通过 `astrbot_grep_tool` / `astrbot_file_read_tool` 查询（`fs.py:566-799,306-401`），通过 `astrbot_file_write_tool`（全文覆盖）与 `astrbot_file_edit_tool`（old/new 字符串替换、`replace_all`，`fs.py:403-563`）定向修改工作区文件；路径权限在 `util.py:57-71` 与 `fs.py:83-293`（admin/成员、local/sandbox 区分）。对 `<html-genui>` 对象没有等价查询/定向修改 API，修订只能由模型在对话新回合整块重出（提示词约定，`astr_main_agent_resources.py:68`）。

## 1. 触发方式、输出协议与对象模型

**触发**：GenUI 由前端请求标志触发，而非用户命令。`enable_inline_genui` 默认 True（`astrbot/core/platform/sources/webchat/request_flags.py:4`），前端构造请求固定开启（`useMessages.ts:9`），由 `event.get_extra("enable_inline_genui")` 决定是否注入输出协议提示词（`astr_main_agent.py:509-510`）。非 WebChat 平台（QQ 等）没有该标志，也不会注入协议。

**输出协议**：私有文本标记，无结构化 part。协议全部内容在 `CHATUI_INLINE_GENUI_SYSTEM_PROMPT`（`astr_main_agent_resources.py:61-76`）：输出恰好一个 `<html-genui>...</html-genui>` 块；开标签可带 `title` 属性；不允许 Markdown 代码围栏包裹；要求自包含 HTML/CSS/JS；修订时输出完整新块而非 diff。后端完全不解析该标记——它只是 `plain` part 的普通文本，协议解析完全发生在前端 markstream-vue 的 custom-tag 机制（`chatMarkdownComponents.ts`）。这带来两层含义：协议开放度很低（私有标记、靠提示词约定），且"误触发/半截流"处理依赖第三方渲染库的流式解析能力（本项目未实现自己的标记解析器）。

**对象模型**：不存在独立的输出对象。GenUI 块没有 ID、类型、状态、版本字段；它作为 `{"type":"bot","message":[{"type":"plain","text":"..."}]}` 的一部分随消息持久化（`chat_service.py:97-113,722-742`）。事实源是"消息历史记录 + 附件表"（`PlatformMessageHistory`、`Attachment`，见 `chat_service.py:510-512,634-638`）。文件产物有 `attachment_id` 和 `stored_filename` 两层身份（`message_parts_helper.py:385-392`），但附件生命周期跟随会话删除而回收（`chat_service.py:1225-1243`），不是独立的可寻址对象库。

## 2. 增量生成、更新与最终化

**文本流**：Agent 逐 token/块 yield，经 `webchat_event._send` 以 `streaming: true` 的 `plain` 事件写入队列（`webchat_event.py:51-62`），`ChatService._consume_chat_run` 用 `BotMessageAccumulator.pending_text` 累积，遇非 streaming 块或 `end` 时落库（`chat_service.py:125-183,1015-1041`）；前端 `appendPlain` 追加到最后一个 plain part（`useMessages.ts:1440-1449`）。

**GenUI 更新**：不是节点级更新。`HtmlGenUiNode` 每次内容变化（节流 500ms）用 `buildSrcdoc` 整文档重建 srcdoc（`HtmlGenUiNode.vue:89-113,129-140`），流式期间旧 iframe 保留、新文档替换，无 diff/patch、无 DOM 复用；`loading` 期间维持 `is-loading` 样式。被裁剪或失败的流：服务端 `_consume_chat_run` 异常时发布 `error` 事件并尽力 `flush_pending_bot_message`（`chat_service.py:1045-1073`）；前端在断开时追加错误文本（`useMessages.ts:665-670`）。

**文件 part 最终化**：`[IMAGE]/[FILE]` 事件到达时同步完成复制+登记，`attachment_saved` 事件把 `attachment_id` 推给前端（`chat_service.py:972-1013`）。

**修订**：无补丁协议。用户可对 bot 消息整体"重新生成"（`RegenerateMenu` → `chat_service.py:1702-1806`，回滚该回合 LLM 历史后重跑），GenUI 修订则依赖模型按提示词在新回合输出完整新块（`astr_main_agent_resources.py:68`）。每次修订产生新消息，对象身份没有延续机制。

## 3. 投影表面与多视图关系

- **GenUI**：仅消息内 inline 投影（`message-stack` 内 `<html-genui>` 节点），带 Preview/Source 双标签切换（`HtmlGenUiNode.vue:5-27`）——同对象的两个静态视图，均从同一份源文本派生，无独立标签页/侧栏/画布投影。
- **文件产物**：两种投影——消息内附件卡片（下载按钮，`ChatMessageList.vue:217-252`）与工作区文件树（`WorkspaceFilesPanel.vue`，侧边面板，读文件预览/下载）。两者共享磁盘文件，但附件副本在 `attachments/`，工作区原件在 `workspaces/`（见第 8 节），并非同一文件的两个视图。
- **插件页面 iframe**：`PluginPagePage.vue:645-653` 提供带 `postMessage` 宿主桥的插件页面 iframe（`PluginPagePage.vue:26-68,523-533`）。这是插件生态的宿主页面，不是生成式输出，本类目仅记录其存在以排除混淆。
- 未找到无限画布、桌面挂件、独立窗口投影；`canvas` 关键词仅在 `HtmlGenUiNode.vue:167` 的 CSS 中出现。

## 4. 表现类型、依赖与运行环境

**GenUI**：支持完整 HTML/CSS/JS（`<script>` 可用，提示词明确要求自包含），无外部依赖供给机制——提示词要求自包含，iframe 为 opaque origin，外部资源只能靠网络加载且受 CORS 约束。运行环境为浏览器 iframe（`srcdoc`），无服务端 HTML 执行。流式 Markdown 渲染依赖第三方库 markstream-vue 1.0.5-beta.0（`dashboard/package.json:35`），GenUI 解析能力（含流式半截标记的容错）来自该库，仓库内无对应测试。

**代码执行**：`LocalBooter` 的 Python 执行是每次调用 `python -c` 起新子进程（`booters/local.py:828-866`），无持久 kernel；`kernel_id` 参数在协议层存在（`olayer/python.py:8-19`）但本地实现忽略、Neo 实现显式标注 Bay SDK 不支持（`booters/shipyard_neo.py:62`）。Shell 每次调用起子进程（Windows 用 PowerShell 5.1，`booters/local.py:148-156`），另有 managed session（后台/交互式进程，输出写临时日志文件增量读取，`booters/local.py:213-825`）。沙箱运行时为 shipyard_neo（Bay，python-default profile，可含 browser 能力）/ shipyard / cua（桌面 GUI）/ boxlite，见 `computer_client.py:576-654` 与 `_apply_sandbox_tools` 的能力注册（`astr_main_agent.py:1125-1221`）。未发现 notebook 或 REPL 类型的持续运行对象。

## 5. 用户交互、事件与错误反馈

- **GenUI iframe**：用户可在 iframe 内与页面交互（`allow-forms allow-modals allow-pointer-lock allow-popups allow-scripts`，`HtmlGenUiNode.vue:45-46`）。**不存在** iframe → 宿主的事件回传：节点内没有 `postMessage` 监听、没有尺寸/状态/日志上报；`<base target="_blank">` 使链接在新标签打开（`HtmlGenUiNode.vue:157`）。交互状态在组件卸载/重载后不恢复（每次挂载新建 iframe）。
- **工具卡片**：`ToolCallCard` 支持展开/收起、显示 args/result、耗时计时（`ToolCallCard.vue:2-40,63-107`）；IPython 调用走 `IPythonToolBlock`（高亮代码与结果，`IPythonToolBlock.vue:5-21`）。这些是只读展示，无"继续编辑此代码并重跑"的交互。
- **文件 part**：下载按钮（`ChatMessageList.vue:237-251`），图片点击放大（overlay，`MessageList.vue:528-536`）。
- **错误反馈**：流错误/中止以纯文本附加到消息（`useMessages.ts:665-670,1084-1088`）；`error` 事件由服务端 `_consume_chat_run` 发布（`chat_service.py:1050-1053`）。

## 6. 编辑、diff、版本与协作

- **消息编辑**：仅"最新的用户消息"可编辑（`chat_service.py:1632-1660`；`ChatMessageList.vue:577-585`），编辑后截断后续消息并触发重新生成（`chat_service.py:1667-1693`；`Chat.vue:1476-1497`）。bot 消息（含 GenUI 块）不可就地编辑，只能整条重新生成。因此用户不能对模型输出做选区/结构化编辑。
- **diff/版本**：不存在。提示词明确要求修订输出完整块而非 diff（`astr_main_agent_resources.py:68`）；文件编辑工具采用 old/new 字符串替换语义（`fs.py:477-503`，`booters/local.py:996-1029`），无 diff 展示、无接受/拒绝、无撤销、无分支表达（"重新生成旧回合需要分支"被拒绝，`chat_service.py:1746-1747`）。
- **协作**：用户与模型不同时编辑同一对象——用户不能改 GenUI/工作区文件，模型通过工具独占修改文件；没有 CRDT 类并发机制。
- **线程（thread）**：可从 bot 消息创建基于 checkpoint 的对话线程（`chat_service.py:1440-1511`），属于 Chat 类目的分支表达，与本类目对象无关。

## 7. 能力桥、执行位置与权限范围

**GenUI 无能力桥**：iframe 沙箱策略不含 `allow-same-origin`（opaque origin），脚本可运行但没有任何宿主 API；与插件页面 iframe（有 `postMessage` 桥，`PluginPagePage.vue`）形成对比——生成式输出没有获得插件页面同等的桥接能力。

**代码执行**：本机执行无隔离（直接子进程，仅 `_BLOCKED_COMMAND_PATTERNS` 黑名单与管理员门槛，`booters/local.py:34-53`、`computer_tools/util.py:57-71`）；沙箱执行由远端运行时隔离（Bay 容器，TTL 管理，`computer_client.py:584-612,629-653`）。文件工具权限分层明确（`fs.py:10-35` 模块头部审计注释）：成员+本地限制读写范围（工作区、temp、skills），管理员不受该模块路径限制；沙箱成员不受模块限制、依赖沙箱边界。网络/存储/模型调用等宿主动作没有面向输出的逐项授权框架——这些属于 Agent 工具调度范畴。

## 8. 持久化、恢复、分享与导出

- **GenUI**：持久化的是源文本（消息 plain part 内，含 `<html-genui>` 标签原样），`get_session` 返回历史后前端重渲染（`chat_service.py:1406-1429`；`useMessages.ts:265-273`）。恢复的是"源码 + 重建的预览 DOM"，iframe 内运行状态（定时器、表单值、脚本变量）不持久。无分享链接、无导出按钮；用户可手动复制 Source 视图文本。
- **附件**：登记表 + 磁盘副本，`attachment_id` 可寻址下载（`/files/{attachment_id}`，`dashboard/api/files.py:91-102`）；会话删除时级联删除附件文件（`chat_service.py:1225-1243`）。消息内 file part 提供下载（`useMessages.ts` / `ChatMessageList.vue` 的 `downloadPart`）。
- **工作区文件**：落盘于 `data/workspaces/`（会话、`project_<id>`、自定义路径三类根，`workspace.py:65-91,121-165`），文件本身即持久化源；项目元数据存 DB。浏览/读/下载 API 为只读（`chatui_project_service.py:176-379`、`chat_projects.py:160-206`），无用户写入口。
- **导出**：项目工作区文件可单个下载（`chat_projects.py:184-206`）；未发现目录打包/项目级导出。

## 9. 模型回流、对象感知与持续维护

- **GenUI**：无对象级回流。模型"感知"历史输出仅通过对话历史（assistant 消息含此前完整 `<html-genui>` 文本），修订 = 新回合整块重出（提示词约定，`astr_main_agent_resources.py:68`）。没有查询对象列表、读取对象状态、定向修改的 API。
- **文件**：模型侧闭环完整——`astrbot_grep_tool`/`astrbot_file_read_tool` 查询读取（`fs.py:306-401,566-799`），`astrbot_file_write_tool`/`astrbot_file_edit_tool` 定向修改（`fs.py:403-563`），cwd 固定在会话/项目工作区（`computer_tools/util.py:27-45`，`workspace.py:191-217`）。这是"查询 → 读取 → 定向修改"闭环，但对象是普通磁盘文件而非生成式对象；模型用工具修改后，用户从工作区面板可看到更新。
- **沙箱**：shipyard_neo 提供执行历史/注释/技能候选等 Neo 工具（`astr_main_agent.py:1193-1203`），用于技能生命周期，不属于通用输出对象回流。

## 10. 生命周期、资源治理与性能

- **GenUI**：iframe 挂载于消息渲染期间；`loading="lazy"` 延迟加载（`HtmlGenUiNode.vue:35`）。组件卸载时仅清理节流定时器（`HtmlGenUiNode.vue:82-87`），无对 iframe 内定时器/动画/媒体/WebGL 的登记与释放机制——iframe 内资源随文档替换/组件销毁由浏览器回收，运行状态本身不持久（见第 8 节）。
- **代码执行**：本地 shell 每次调用有超时（默认 300s，`booters/local.py:16`）；managed session 有硬超时/终止/输出上限（`booters/local.py:213-265,339-359`），进程组终止后删除日志文件（`booters/local.py:800-824`）。Python 子进程每次调用超时默认 30s（`booters/local.py:841-864`）。沙箱按会话缓存 booter（`computer_client.py:21,555-654`），CUA 支持空闲超时自动关闭（`computer_client.py:35-87,652-653`），失效 booter 删除沙箱避免泄漏（`computer_client.py:555-575`）。未发现对长会话/多对象输出数量的整体限额机制。
- **性能**：GenUI 预览采用 500ms 节流整文档重建；流式 Markdown 有 `MARKDOWN_RENDER_MAX_LIVE_NODES` 上限（`markdownRenderConfig.ts`）。这些属于渲染层治理，未发现针对 GenUI 对象本身的资源配额。

## 11. 测试、已确认边界与未验证事项

**已有测试**（静态确认，未运行）：
- `tests/unit/test_astr_main_agent.py:813-860`：验证 `enable_inline_genui` 时注入提示词、无会话时也注入、关闭时不注入——覆盖触发与协议装配。
- `tests/test_chat_route.py:390-423`：请求 flags 归一化透传（含 `enable_inline_genui`）。
- `tests/test_computer_fs_tools.py`（约 60+ 用例）：读写/编辑/搜索工具的权限边界（成员受限目录、硬链接拒绝、超大文件、图片/PDF/docx/epub 读取等）。
- Dashboard 前端仅 5 个测试文件（`dashboard/tests/`：extensionPreferenceStorage、hashRouteTabs、imeInput、routerReadiness、subsetMdiFont），**没有**覆盖 HtmlGenUiNode、markstream 自定义标签、消息 part 渲染的测试。

**未验证事项**（未运行服务与前端）：
- `<html-genui>` 流式半截标签的解析容错实际行为（依赖 markstream-vue 1.0.5-beta.0，未运行验证）；
- iframe 内任意 HTML/JS 的实际运行与隔离表现（sandbox 属性行为、CORS 实际效果、`allow-popups` 弹窗）；
- 沙箱（shipyard_neo/cua/boxlite）远端行为与技能同步流程（`computer_client.py:444-537` 的 sync 脚本）；
- 重新打开会话后预览重建、附件下载、工作区浏览的端到端表现；
- 消息编辑/重新生成的 UI 流程、线程与 checkpoints 的行为（部分属于 Chat 类目）。

**已确认边界**：
- 后端不解析 `<html-genui>`；协议仅存在于提示词与前端渲染库。
- bot 消息不可编辑（`chat_service.py:1634-1635`），GenUI 无对象身份/版本/diff/导出。
- 工作区文件对用户只读（浏览/预览/下载 API 无写端点）。
- 本地 Python 无持久 kernel；`kernel_id` 为名义参数。
- 文档中未检索到 GenUI 说明（`docs/`、根目录 grep `html-genui` 均无结果），该能力仅存在于代码与提示词。

## 12. 关键源码索引

- `astrbot/core/astr_main_agent_resources.py:61-76`：`<html-genui>` 输出协议提示词（触发、格式、修订约定）
- `astrbot/core/astr_main_agent.py:509-510`：`enable_inline_genui` 注入点；`1125-1221`：沙箱工具装配
- `astrbot/core/platform/sources/webchat/request_flags.py:4`：GenUI 标志默认值
- `astrbot/dashboard/services/chat_service.py`：SSE 运行状态机与消息持久化（`_consume_chat_run:897-1088`、`build_chat_stream:1090-1183`、`update_message:1602-1693`）
- `astrbot/core/platform/sources/webchat/webchat_event.py:29-147`：`[IMAGE]/[FILE]` 物化协议
- `astrbot/core/platform/sources/webchat/message_parts_helper.py:358-392`：附件 part 生成
- `dashboard/src/composables/useMessages.ts:7-13,990-1160`：请求标志与流式协议处理
- `dashboard/src/components/chat/message_list_comps/HtmlGenUiNode.vue:29-46,89-169`：iframe 预览与沙箱策略
- `dashboard/src/components/chat/chatMarkdownComponents.ts:8-16`：custom-tag 注册
- `astrbot/core/tools/computer_tools/fs.py:306-799`：读/写/编辑/grep 工具
- `astrbot/core/tools/computer_tools/python.py:80-153`、`astrbot/core/tools/computer_tools/shell.py`：执行工具
- `astrbot/core/computer/booters/local.py:129-211,828-866`：本地执行运行时
- `astrbot/core/computer/computer_client.py:539-654`：运行时选择与沙箱生命周期
- `astrbot/core/workspace.py:65-165,191-217`：工作区解析
- `astrbot/dashboard/services/chatui_project_service.py:176-379`、`astrbot/dashboard/api/chat_projects.py:160-206`：工作区只读 API
- `dashboard/src/components/chat/WorkspaceFilesPanel.vue:325-454`：工作区文件面板
- `dashboard/src/components/chat/message_list_comps/ToolCallCard.vue`、`IPythonToolBlock.vue`：工具结果展示
