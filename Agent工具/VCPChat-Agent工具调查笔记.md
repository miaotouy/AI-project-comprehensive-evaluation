# VCPChat Agent 工具调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：只读源码梳理（未修改被调查仓库任何文件）；未运行仓库测试/构建，结论均以静态阅读源码为准
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 随包携带一个独立的 `VCPDistributedServer` 子进程（`VCPDistributedServer/VCPDistributedServer.js`），它以 WebSocket 分布式节点身份连接主 VCPToolBox 服务器，把本机能力（音乐控制、骰子、Canvas、Flowlock、DesktopRemote、本机文件读取、本机插件目录下的 PowerShell/PTY Shell/截图/UI 自动化等）注册为可被模型调用的工具，并在收到 `execute_tool` 消息后在本机 Node/Python 子进程中真正执行。除此之外，Electron **主进程**本身还直接托管了一条更短的模型触发链路：DESKTOP_PUSH 语法在 renderer 流式解析阶段被拦截，直接调用 `electronAPI.desktopPush` 在桌面画布创建/写入 HTML 挂件，完全不经过 VCPToolBox 的审批协议。

代码中已确认的关键发现：

1. **分布式节点随主进程默认开启**：应用启动时读取 `enableDistributedServer` 设置，其默认值为真（`modules/utils/appSettingsManager.js:170`、`main.js:1276`）；启用时加载分布式节点模块并完成初始化，把本机插件目录（当前 HEAD 30 个目录）中的能力注册进主 VCPToolBox 的工具目录，包括：
   - `PowerShellExecutor`、`PTYShellExecutor`：本机 shell 执行；
   - `FileOperator`：读写任意/受限目录；
   - `ScreenPilot`：截图/OCR/模拟点击/UI 自动化；
   - `MediaShot`：截取本机文件。
   上述插件都在本机 Node/Python 子进程中执行，渲染进程内不运行它们；renderer 型插件改由前端插件加载器加载，不进入工具注册。
2. **审批终端的"自动允许规则"是纯字符串/正则匹配**：`modules/filterManager.js:567` 起的匹配函数只拿规则里的工具名模式与服务端上报的工具名比对，支持包含、完全相等和正则三种模式，规则以明文存在 `settings.json` 的 `toolAutoApprovalRules` 中，无权限分级。
3. **VCPLog WebSocket 通道在一次握手后不再做消息级鉴权**：主进程连接时用 URL 里的 `VCP_Key` 做一次性握手鉴权（`main.js:2208-2226`），握手成功后同一条连接上收到的任意 `tool_approval_request` 载荷都被无条件展示为审批 UI，也可被自动规则直接批准；允许与拒绝的响应同样经这条无进一步签名的通道回传（`modules/notificationRenderer.js:294-340`）。
4. **`/admin_api` 使用 Basic Auth，凭据明文落盘在 `forum.config.json`**（`modules/ipc/forumHandlers.js:60-65`），renderer 端由页面脚本用 base64 编码直接拼出 Authorization 头（`Agenttaskmodules/task.js:240`、`Forummodules/forum.js:206`）；该 admin 面板可改写服务端的 Agent Assistant / Task Assistant 配置，包括新增/删除委托 Agent、系统提示词、定时任务。
5. **DESKTOP_PUSH 是模型输出中一条不经 VCPToolBox 审批协议直达桌面的本地协议**：模型只需在流式输出中吐出 `<<<[DESKTOP_PUSH]>>>` 起始标记与结束标记包裹的 HTML/CSS/JS，流式投影把 token 交给 `modules/renderer/desktopPushConsumer.js:36-45,195` 直接拦截。主进程再经 IPC 把内容原样转发给桌面窗口渲染（`modules/ipc/desktopHandlers.js:1105-1132`）——不经过 `tool_approval_request`，唯一的前置校验是前缀白名单（完整清单见下）：

```text
<!doctype  <div  <section  <article  <main  <header  <nav  <aside  <canvas  <svg  <style  target:  <!--
```

## ASCII 调用链图

```text
                     ┌───────────────────────────────────────────────┐
                     │              VCPToolBox 主服务端                │
                     │  (工具执行、审批规则源、Agent Assistant 配置面) │
                     └───────────────┬─────────────────┬─────────────┘
                                      │                 │
                    tool_calls / VCP  │                 │ WebSocket VCPLog
                    文本块（聊天流）   │                 │ (审批请求/响应、通知)
                                      ▼                 ▼
                     renderer.js (vcp-stream-event)   main.js:connectVcpLog()
                       │                                 │ IPC: vcp-log-message / vcp-log-status
                       ▼                                 ▼
              messageRenderer.js / streamManager.js   notificationRenderer.js
              （工具请求/结果原样展示为 UI 块，        （渲染 tool_approval_request 卡片；
               不在客户端解析分发）                     filterManager.checkToolAutoApproval()
                       │                                 命中规则则自动发送 approved）
                       │ DESKTOP_PUSH 语法拦截                 │ ipcRenderer.send('send-vcplog-message')
                       ▼                                 ▼
              electronAPI.desktopPush()            main.js: vcpLogWebSocket.send()
                       │ IPC 'desktop-push'                    (tool_approval_response 明文回传)
                       ▼
              desktopHandlers.js -> 桌面窗口 webContents.send('desktop-push-to-canvas')
              （HTML/CSS/JS 挂件直接渲染，无审批）

     ┌──────────────────────────── VCPChat 自带分布式节点 ────────────────────────────┐
     │ main.js:1097 (settings.enableDistributedServer=true 默认开启)                  │
     │   -> VCPDistributedServer.js: new WebSocket(mainServerUrl + VCP_Key=vcpKey)   │
     │   -> registerTools(): 本机 Plugin/* 目录 manifest 注册进主服务器工具目录        │
     │        （renderer 型插件由 Plugin.js 跳过，改走前端插件加载器）                │
     │   -> 主服务器审批通过后下发 execute_tool -> handleToolExecutionRequest()       │
     │        -> pluginManager.processToolCall() -> spawn(本机 node/python 子进程)   │
     │        -> direct 插件 (LoomController/DeepMemo 等) 由注入的服务依赖            │
     │           (chatDataService/loomManager) 执行，_vcpContext 与模型生成的         │
     │           toolArgs 分离传入                                                    │
     │        -> 特殊分支: MusicController/SuperDice/Flowlock/DesktopRemote          │
     │             直接调用注入的 main.js handler，操纵本机窗口/播放器/桌面           │
     │        -> internal_request_file: 直接 fs.readFile(file://本机路径) 返回 b64  │
     └──────────────────────────────────────────────────────────────────────────────┘
```

依据：`main.js:1276-1291,2208-2250` 与 `VCPDistributedServer/VCPDistributedServer.js:275-284` 覆盖分布式服务器初始化、WS 连接注册与 VCPLog 握手转发；`modules/notificationRenderer.js:294-340` 覆盖审批卡片渲染与自动批准。

## VCPChat 本地能力清单（模型可触发、在本机 Electron 或本机子进程中执行）

| 能力 | 触发方式 | 执行位置 | 审批 | 源码依据 |
|---|---|---|---|---|
| 桌面画布挂件创建/写入（HTML+CSS+JS） | 流式文本中的 `<<<[DESKTOP_PUSH]>>>` 语法 | renderer 拦截 -> IPC -> 桌面窗口 webContents | **无**，仅前缀白名单校验；不经过 VCPToolBox `tool_approval_request`/规则体系（旁路能力） | `modules/renderer/desktopPushConsumer.js:36-45,195`、`modules/ipc/desktopHandlers.js:1105-1132` |
| 桌面壁纸/挂件/Dock 查询与设置（`SetWallpaper`/`CreateWidget`/`QueryDesktop` 等） | VCPToolBox `DesktopRemote` 工具调用，经分布式节点转发 | 主进程 `desktopRemoteHandlers.js` 直接操作桌面窗口、写 `AppData/DesktopData`/`DesktopWidgets` 文件 | 走服务端 `toolApprovalConfig.json` 规则（不在客户端） | `modules/ipc/desktopRemoteHandlers.js:241-698`、`VCPDistributedServer/VCPDistributedServer.js:739-759` |
| 音乐播放控制（play/pause/next/prev，按标题模糊匹配曲库） | VCPToolBox `MusicController` 工具，分布式节点特殊分支直调 | 主进程 `musicHandlers.handleMusicControl` 操纵音乐窗口 | 服务端规则 | `VCPDistributedServer/VCPDistributedServer.js:666-704`、`modules/ipc/musicHandlers.js:274-350` |
| 骰子 `SuperDice` | VCPToolBox `SuperDice` 工具，分布式节点特殊分支 | 主进程 `diceHandlers.handleDiceControl` | 服务端规则 | `VCPDistributedServer/VCPDistributedServer.js:678-691` |
| Flowlock 控制（启动/停止/查询/设置输入框内容） | VCPToolBox `Flowlock` 工具 + 客户端侧 AI 输出中的 `[[Flowlock::Start/Stop/...]]` 控制行 | 主进程 `desktopRemoteHandlers.handleFlowlockControl`；客户端侧由 `Flowlockmodules/flowlock.js` 状态机在**本地自主循环**中重新发起对话请求 | 服务端规则（Flowlock 工具调用一侧）；客户端自主续写循环无逐次审批，仅有最大重试次数与空闲超时 | `modules/ipc/desktopRemoteHandlers.js:163-239`、`Flowlockmodules/flowlock.js:43-506` |
| 本机文件读取并回传 Base64（`internal_request_file`） | 主服务器请求分布式节点读取 `file://` 本机路径 | 分布式节点子进程 `fs.readFile` | 服务端决定是否发起此请求；客户端侧无路径白名单校验 | `VCPDistributedServer/VCPDistributedServer.js:619-660` |
| 本机 PowerShell / PTY Shell 执行 | VCPToolBox `PowerShellExecutor`/`PTYShellExecutor` 工具（随 VCPChat 安装包分发的本机插件） | 分布式节点 `spawn()` 本机 shell 子进程；高危命令可能弹出 Tkinter 确认框 | 服务端 `toolApprovalConfig.json` + 插件自身 `FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS` 字符串黑名单 | `VCPDistributedServer/Plugin/PowerShellExecutor/*`、`VCPDistributedServer/Plugin/PTYShellExecutor/*` |
| 本机文件系统读写（`FileOperator`：ReadFile/WriteFile/DeleteFile/MoveFile/CreateCanvas 等） | VCPToolBox `FileOperator` 工具 | 分布式节点子进程，受 `ALLOWED_DIRECTORIES` 配置约束（留空则不限制） | 服务端规则 | `VCPDistributedServer/Plugin/FileOperator/plugin-manifest.json`、`.env:7` |
| 屏幕截图/OCR/模拟鼠标键盘/UI 自动化 | VCPToolBox `ScreenPilot` 工具 | 分布式节点 Python 子进程，可后台（不劫持鼠标/键盘）操作任意窗口 | 服务端规则 | `VCPDistributedServer/Plugin/ScreenPilot/plugin-manifest.json` |
| 视频/音频/图像截取与编辑（`MediaShot`） | VCPToolBox `MediaShot` 工具 | 分布式节点 Python 子进程，读写本机文件路径 | 服务端规则 | `VCPDistributedServer/Plugin/MediaShot/plugin-manifest.json` |
| 图床/文件下载服务暴露（`DistImageServer`） | 服务类插件常驻 HTTP 路由 `/pw=<key>/files/*` | 分布式节点 Express 路由，`imageKey` 明文存于 `config.env` | 单一静态密钥比较，无速率限制 | `VCPDistributedServer/Plugin/DistImageServer/image-server.js:1-58` |
| 手机端同步（`VCPMobileSync`）：历史/头像/Agent 配置双向同步 | 常驻 WebSocket + HTTP，`x-sync-token`/Bearer 鉴权 | 旧模式：分布式节点内嵌 sqlite 索引 + 文件系统读写 `AppData`；中央模式（`MobileSyncUseCentralIndex=true`）：消息数据面改由 VCP-CDS 提供，本地 DB 变 `:memory:`（仅附件/头像 DTO 定位） | 静态 token 比较 | `VCPDistributedServer/Plugin/VCPMobileSync/transport/routes.js:42-60`、`sync/central.js`（新增） |
| Agent 创建/编辑/感知/操作网页应用（`LoomController`：LoomAPP + WebCore 页面快照/动作） | VCPToolBox 工具调用，`hybridservice` direct 协议 | 分布式节点 direct 模块调用注入的 `VCPLoomManager`；读写 `AppData/LoomApps`，WebContentsView 运行页面；LoomSkill 将多步操作以 schema-v2 文件保存并按 taskId 执行/查询 | 服务端规则（工具调用侧）；Skill 内部另有限制输入、目标、步骤数、结果大小和并发应用 | `VCPDistributedServer/Plugin/LoomController/LoomControllerService.js`、`LoomSkillService.js`、`modules/loom/VCPLoomManager.js` |
| Agent 感知/PR 式协作编辑 Scriptorium 文档（`ScriptoriumCollaborator`：GetDocumentInfo/GetRenderedText/GetSource/SearchSource/GetVisualContext/SubmitSourcePr/CreateDocument 等） | VCPToolBox 工具调用，`hybridservice` direct 协议 | 分布式节点 direct 模块调用注入的 `ScriptoriumAgentControlService`（Electron 主进程，经 `docxHandlers` 读写 `AppData/VDOCX|VPPTX` 工程与文脉快照） | 服务端规则（工具调用侧）；文档 PR 另有前端审批回执 | `VCPDistributedServer/Plugin/ScriptoriumCollaborator/ScriptoriumCollaboratorService.js`、`modules/services/scriptoriumAgentControlService.js`、`modules/ipc/docxHandlers.js` |
| 历史对话深度回忆（`DeepMemo` v2：按 maid/关键词检索历史上下文窗口） | VCPToolBox 工具调用，`hybridservice` direct 协议 | 中央模式：`chatDataService.client.searchMemories`（VCP-CDS/Tantivy）；可选外部 rerank API；`backend:'legacy'` 回退旧链路 | 服务端规则 | `VCPDistributedServer/Plugin/DeepMemo/DeepMemoService.js` |
| 主聊天窗口文件夹视频壁纸（`VChatDynamicWallpaper`） | **renderer 型前端插件**，不经工具目录；`listEnabledFrontendPlugins` IPC 扫描启用 | 渲染进程插件脚本（`frontend-plugin-loader.js` 注入），`vchat-wallpaper-select-directory` IPC 扫描本机视频文件夹（mp4/webm/mov/mkv/avi） | 不适用（无工具调用）；插件文件按 manifest 白名单解析 | `VCPDistributedServer/Plugin/VChatDynamicWallpaper/plugin.js`、`modules/ipc/desktopHandlers.js:2440-2475` |
| Agent Sovits 自动 TTS/代码块朗读（`VChatAutoTTS`） | **renderer 型前端插件**，同上 | 渲染进程插件脚本，按 Agent 粒度的 localStorage 设置自动朗读 assistant 消息 | 不适用 | `VCPDistributedServer/Plugin/VChatAutoTTS/plugin.js` |
| Agent 间话题委派/心流交接（`TopicSponsor`：CreateTopic/CreateFlowlockTopic/ReplyToTopic 等） | VCPToolBox 工具调用，写本机 `Agents/*/config.json` 与 `UserData/*/topics/*/history.json` | 分布式节点子进程直接文件写入，客户端 `Flowlockmodules/flowlock.js` 认领后续自主循环 | 服务端规则（工具调用侧）；话题认领本身由主进程 IPC 做单候选校验，非"审批"而是"占用锁" | `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`、`modules/ipc/chatHandlers.js:160-265` |
| DesktopRemote 本地测试后门路由 `/pw=<file_key>/desktop-remote-test` | HTTP POST（仅限 loopback） | 分布式节点直接调用 `handleDesktopRemoteControl` | `isLoopbackAddress` + `file_key` 明文比较，无速率限制 | `VCPDistributedServer/VCPDistributedServer.js:182-258` |
| 剪贴板读取（图片/文本） | 渲染层 UI 触发（非模型直接触发） | 主进程 `clipboard` API | 不适用——**未确认**模型可主动触发此路径，暂列为需进一步核实 | `preloads/api/files.js:12-15` |

DeepMemo 的运行时后端由插件 `config.env` 里的 `DeepMemoBackend` 决定（`DeepMemoService.js:215-223`），取值为 legacy 时回退旧链路。设置默认值里另有一项 `DeepMemoUseCentralSearch`，默认关闭（`appSettingsManager.js:176`），服务代码从不读取这个键——全仓库检索该键只出现在设置管理器与 rust README 中。中央检索是否启用，实际只取决于插件侧的这个开关。

VCPMobileSync 的中央索引模式（`MobileSyncUseCentralIndex=true`）下，`delete_notify` 需携带上下文或走删除推送（`sync/central.js`）。

**未列入本表**：消息渲染层的工具请求/结果展示（`<<<[TOOL_REQUEST]>>>` 美化、`[[VCP调用结果信息汇总:...]]` 卡片）、Mermaid/KaTeX/HTML 预览等——这些只是显示，不构成本地执行能力，已在消息渲染器笔记中覆盖。

依据：见各行源码路径；分布式节点插件清单来自 `VCPDistributedServer/Plugin/` 目录枚举（当前 HEAD 30 个目录）。

## 1. VCPChat 是否存在客户端侧的 VCP 文本块解析与本地分发

**结论：不存在**（对聊天流内的 `<<<[TOOL_REQUEST]>>>`/`tool_calls` 而言），但**存在**（对 DESKTOP_PUSH 这一条专用协议而言）。

`contentPipeline.js` 里的工具请求保护与还原两个步骤（消息渲染器笔记 4.3 节已确认）只是把工具请求文本保护起来避免被 Markdown 破坏，随后交给特殊块转换生成展示用的预格式块，**不会**解析 `tool_name` 与参数字段去触发任何本地调用。

`Flowlockmodules/flowlock-protocol.js` 同样只解析 Flowlock 控制行用于渲染状态气泡和驱动 `flowlock.js` 状态机（续写下一轮对话），不解析 VCP 工具字段。

真正的例外是 DESKTOP_PUSH：`desktopPushConsumer` 在 chunk 级别扫描 `<<<[DESKTOP_PUSH]>>>` 开始标记、缓冲内容、用 `VALID_PREFIXES` 做二级校验后，直接调用 `electronAPI.desktopPush({action:'create'/'append'/'finalize', widgetId, content})`。这是客户端对模型输出中一种私有协议的**本地解析 + 本地分发**，且完全独立于 VCPToolBox 的工具审批体系。

依据：[`../../VCPChat/modules/renderer/contentPipeline.js`](../../VCPChat/modules/renderer/contentPipeline.js)（未见工具字段解析分支）、[`../../VCPChat/modules/renderer/desktopPushConsumer.js`](../../VCPChat/modules/renderer/desktopPushConsumer.js)。

## 2. 是否作为 VCP 分布式节点向服务端暴露本机能力

**结论：是**，且默认开启。

`main.js:1276-1291` 在应用启动后异步读取分布式节点开关（默认开启，见 `appSettingsManager.js:170`），若为真则加载分布式节点模块并完成初始化。该模块：

- 用 `config.vcpLogUrl`/`config.vcpLogKey`（与聊天所用 VCPLog 同一对 URL/Key）拼出 `ws://.../vcp-distributed-server/VCP_Key=<key>` 连接主服务器（`VCPDistributedServer.js:275-279`）。
- 连接成功后 `registerTools()`：扫描本机 `VCPDistributedServer/Plugin/*/plugin-manifest.json`，把所有后端类型插件的 manifest 一次性发给主服务器（`type:'register_tools'`）。后端类型包括：

```text
static / synchronous / asynchronous / service / hybridservice
```

- 注册前的过滤规则：`pluginType: 'renderer'` 的插件会被过滤掉，它们改由前端插件加载器注入渲染进程，不进入工具目录（`Plugin.js:122-125`）。该节点只把自身能力上报给主服务器，不反向拉取其他节点，循环代理的路径因此有限。
- 收到 `execute_tool` 消息后，节点用 `handleToolExecutionRequest()` 经 `pluginManager.processToolCall()` 在本机 spawn 子进程执行（`Plugin.js:202-301`）。音乐控制、骰子、Flowlock 与 DesktopRemote 四类工具走特殊分支，直接调用主进程注入的 handler 操纵本机窗口。
- direct 插件拿到的执行上下文与模型参数分开传递：`_vcpContext` 由节点侧注入并按可信上下文处理，`toolArgs` 是模型生成的内容（`VCPDistributedServer.js:664-789`、`Plugin.js:187-193`）。这类插件返回的字符串原样回传，不经过 stdio 的 JSON 提取流程。
- 服务注入：`initializeServices` 把主进程持有的聊天数据服务、Loom 管理器与 Scriptorium 控制服务注入 direct 插件，路由注册以 await 等待完成（`Plugin.js:303-351`）。
- 子进程清理：Windows 上 `_killProcessTree` 调用 `taskkill` 时补挂了 error 监听；POSIX 侧插件进程以独立进程组启动，超时终止时向整个进程组发信号，避免留下孤儿进程（`Plugin.js:16-30,235-405`）。
- 鉴权只在连接建立时做一次：客户端用 URL 里的 Key 完成握手；此后服务端下发的 `execute_tool` 消息没有任何签名或二次校验，连接上收到的工具名与参数会被分布式节点按原样执行。
- 暴露面：本机 Express HTTP 服务器监听 `0.0.0.0` 上的随机或固定端口，绑定的是通配地址，回环地址只是可访问地址之一。对外提供异步插件回调 `/plugin/callback` 与诊断路由；后者限定 loopback 并用固定密钥比较。回调路由既不鉴权也不校验来源，局域网内其他主机可以 POST 数据进来，被转发进 VCPLog 通知流（`VCPDistributedServer.js:79-173`）。

依据：[`../../VCPChat/main.js:1276-1291`](../../VCPChat/main.js)（启动与初始化）、[`../../VCPChat/VCPDistributedServer/VCPDistributedServer.js:79-173`](../../VCPChat/VCPDistributedServer/VCPDistributedServer.js)（HTTP 服务器绑定通配地址、回调路由无鉴权）、[`../../VCPChat/VCPDistributedServer/Plugin.js:104-164`](../../VCPChat/VCPDistributedServer/Plugin.js)。

## 3. 上游工具调用的接收：`tool_calls` 与 VCP 文本块

VCPChat 主聊天链路对上游返回的 `tool_calls` 字段采取**原样透传**策略，不在客户端解析或执行：

- 请求组装阶段会保留历史消息里的 `tool_calls` 与 `tool_call_id` 字段，上下文压缩的白名单也把它们列入保留项（`modules/chat/chatContextPipeline.js:388`、`contextCompactionPrompts.js:85`）。这段代码只做字段搬运，目的是把历史消息原样发回服务器，不产生本地分支；主进程转发前同样只做白名单式复制（`modules/ipc/chatHandlers.js:1132`）。
- 流式响应的归一化只累积文本：客户端只从 `content` 字段累积文本，对 `delta.tool_calls` 等结构化字段没有读取或处理逻辑（`modules/ipc/chatHandlers.js:1056-1360`）。因此上游模型若走原生 function-calling，VCPChat 不会把这类调用转成本地动作——它假定所有需要执行的工具调用都以 VCP 文本块（`<<<[TOOL_REQUEST]>>>`）出现在 content 文本流里，由服务端 VCPToolBox 解析执行，客户端只负责显示。
- 流式期间的组装完全在渲染进程的流式投影中完成（消息渲染器笔记 6.3-6.4 节已确认），产物是 DOM 展示，不产生任何本地调用副作用，唯一例外仍是 DESKTOP_PUSH 拦截器。

依据：[`../../VCPChat/modules/chat/chatContextPipeline.js:319-417`](../../VCPChat/modules/chat/chatContextPipeline.js)（请求消息组装，保留但不解析 `tool_calls`）、[`../../VCPChat/modules/ipc/chatHandlers.js:1056-1360`](../../VCPChat/modules/ipc/chatHandlers.js)（流式 chunk 归一化，只认 `content` 字段）。

## 4. 审批终端实现

### 4.1 `tool_approval_request` 接收与展示

VCPLog WebSocket 消息由主进程 `main.js:1576-1585` 的 `onmessage` 回调解析后原样通过 IPC `vcp-log-message` 转发给 renderer，renderer 端通知渲染函数判断 `logData.type === 'tool_approval_request'` 时：

1. 先调用 `window.filterManager.checkToolAutoApproval(logData.data)`（见 4.2）；命中则自动发送允许响应并把这次自动批准记为一条 `tool_auto_approval` 类型通知，**不展示原始审批卡片**。
2. 未命中自动规则时，渲染一张带"允许/拒绝"按钮和可选理由输入框的通知卡片（悬浮 toast + 侧栏列表两处），且该卡片**永不自动消失**（`autoDismissDelay = Infinity`，`notificationRenderer.js:936-937`），点击卡片本体也不会关闭（"审核请求防误触"注释，`notificationRenderer.js:430-432`）。

审批卡片上的标题与正文直接取自服务端 `tool_approval_request.data` 中的工具名、参数、maid 与时间戳字段（`notificationRenderer.js:307-311`），客户端只负责展示，不自行构造这些字段。

### 4.2 允许/拒绝响应发送

审批响应由 renderer 侧的发送函数（`notificationRenderer.js:81-114`）构造成一条类型为 `tool_approval_response` 的消息，经 IPC 通道 `send-vcplog-message` 交给主进程，由主进程在同一条 WebSocket 上原样发回（`main.js:1684-1686`）。

响应体里除 `requestId`、批准标志与可选理由外**没有任何身份或时间戳字段**，也没有对该 ID 做签名或来源校验——它完全由服务端在审批请求里给出，客户端只是照抄。

### 4.3 本地自动允许规则的匹配语义与存储位置

自动允许规则存储在 `settings.json` 的 `toolAutoApprovalRules` 数组中（`modules/utils/appSettingsManager.js:131-132` 声明默认值 `[]`），每条规则形如：

```json
{ "id": "...", "name": "...", "toolPattern": "...", "matchMode": "contain|exact|regex", "description": "...", "enabled": true, "order": 0 }
```

`checkToolAutoApproval(approvalData)`（`filterManager.js:509-543`）的匹配语义：

- 匹配前先看全局开关：`settings.toolAutoApprovalEnabled` 为 `false` 时，整条规则链都不参与判断。
- 待匹配的工具名取自审批数据里的 `toolName`，也兼容 `tool_name` 写法；这个值直接采用服务端上报的结果，客户端没有本地白名单做交叉校验。
- 规则按 `order` 字段排序后依次尝试，`enabled` 为 false 的规则跳过。
- `exact` 模式要求工具名与 `toolPattern` 完全相等。
- `regex` 模式用 `new RegExp(pattern)` 对工具名做正则测试。保存规则时只校验正则语法是否合法，不限制表达式的宽泛程度，用户填一个 `.*` 就能匹配全部工具名。
- `contain` 是默认模式，按子串包含判断。空 pattern 会在界面层被非空校验挡掉，但只填一个字符（例如 `e`）几乎能命中所有工具名，效果等同于全局自动允许（两处校验见 `filterManager.js:434-446`）。
- 第一条命中的规则即返回批准结果，后面的规则不再检查。代码里没有 deny 优先或高危工具强制人工确认的硬编码例外：`PowerShellExecutor` 与 `SuperDice` 这类工具只要命中一条启用规则，就按同一路径自动批准。

### 4.4 超时行为

客户端侧**没有**审批超时机制——通知卡片 `autoDismissDelay = Infinity`，会一直挂在通知列表里直到用户手动点击允许/拒绝或应用重启。超时逻辑（若存在）应在 VCPToolBox 服务端的 `toolApprovalManager.js`（另一 agent 调查范围），客户端未确认服务端超时后是否会向本连接推送任何"已超时"的后续消息。

### 4.5 通知渠道鉴权与消息级校验

VCPLog WebSocket 的鉴权模型是**一次性握手**：连接 URL 中携带 `VCP_Key`，服务端在建立连接时校验一次。握手成功后，该连接上收到的每一条消息都**不校验发送方身份、不做消息级签名**——主进程的 `onmessage` 回调只做解析，直接转发给 renderer 渲染成审批卡片或其它通知（`main.js:1548-1585`）。

审批与拒绝的响应也通过同一条无进一步签名的通道原样回传（`sendToolApprovalResponse`，见 4.2）。`vcpLogUrl` 的协议（`ws://` 或 `wss://`）由用户在设置里填写，代码未见强制升级到 `wss://` 的逻辑。

依据：[`../../VCPChat/main.js:1540-1686`](../../VCPChat/main.js)（VCPLog 连接、消息转发、发送响应）、[`../../VCPChat/modules/notificationRenderer.js:79-422`](../../VCPChat/modules/notificationRenderer.js)（审批卡片渲染与按钮）、[`../../VCPChat/modules/filterManager.js:88-543`](../../VCPChat/modules/filterManager.js)（规则默认值归一化、编辑器校验与匹配逻辑）。

## 5. 编排：客户端是否参与迭代循环

**分两条线看**：

1. **普通工具调用迭代循环**：客户端**不参与**。VCPChat 的发送链路只做单次请求/响应（或单次流式会话），把完整历史发给服务端，工具调用的"发起模型请求 -> 执行工具 -> 把结果回注上下文 -> 再次请求模型"的整轮迭代逻辑在 VCPToolBox 服务端完成（属另一 agent 调查范围）。客户端能看到的只是最终这一轮的 `data`/`end`/`error` 流事件。
2. **Flowlock 心流锁循环**：客户端**确实**参与一个本地自主循环，但这个循环编排的是“要不要发起下一轮完整对话请求”，不是“工具调用内部的多轮迭代”。

   每个 Agent 对应一个 `FlowlockManager` 状态机，负责启动、停止、安排下一轮与触发本轮（`Flowlockmodules/flowlock.js`）。触发条件是模型输出末尾出现 `[[Flowlock::Start]]` 一类控制行，由协议解析器识别后交给状态机；触发时它会重新读取历史，再向服务器发起一次完整的对话请求（`Flowlockmodules/flowlock-integration.js:58-267`）。
   - **上限**：每个 session 的错误重试上限是 3 次，正常轮数没有硬上限——模型只要持续输出 `[[Flowlock::NextHeartbeat::N]]` 而始终不输出 Stop、Complete 或 Fail，循环就会一直续下去；唯一的软约束是轮次间隔被限制在 1 到 86400 秒之间（`flowlock-protocol.js:233-239`）。
   - **超时**：Flowlock 没有总时长超时；DesktopPush 另有独立的 150 秒空闲超时（见能力清单）。
   - **取消**：`stop(agentId)` 可随时中断循环，入口有右键菜单、快捷键 Ctrl/Cmd+G 和模型输出的 `[[Flowlock::Stop]]` 控制行；页面卸载时 `cleanup()` 会清空所有 session。

依据：[`../../VCPChat/Flowlockmodules/flowlock.js:43-160`](../../VCPChat/Flowlockmodules/flowlock.js)（start/stop）、[`../../VCPChat/Flowlockmodules/flowlock.js:293-450`](../../VCPChat/Flowlockmodules/flowlock.js)（`handleFinalizedMessage` 编排下一轮）、[`../../VCPChat/Flowlockmodules/flowlock-integration.js:58-267`](../../VCPChat/Flowlockmodules/flowlock-integration.js)（`continueWritingForContext` 重新发起请求）。

## 6. 结果处理与回注

工具结果（VCP 文本块形式）作为普通消息文本的一部分被写入聊天历史（`history.json`），下一轮对话时随完整历史一起发给服务端——客户端不单独截断或结构化存储工具结果本体，截断只发生在**展示层**：消息渲染器笔记 5.3 节已确认的 `renderToolResultBlock()` 对超过 50,000 字符的返回内容值只展示前 80 行，完整值保存在内存映射供展开查看，**不修改历史文件中的原始内容**。

错误形态：VCP 请求失败（HTTP 非 2xx、JSON 解析失败、AbortError 超时/取消）都被归一为 `chat.stream.failed` 终态并携带已收文本，交由终态投影合并错误说明后落盘为一条 assistant 消息（消息渲染器笔记 6.7 节已确认），不是抛出异常中断整个会话。

依据：[`../../VCPChat/modules/ipc/chatHandlers.js:1056-1360`](../../VCPChat/modules/ipc/chatHandlers.js)（HTTP 错误与中断处理）、[`../../VCPChat/modules/chat/chatEventContract.js:7-34`](../../VCPChat/modules/chat/chatEventContract.js)（终态归一）；工具结果截断见消息渲染器笔记 5.3 节。

## 7. 管理面 admin_api

### 7.1 凭据存储与传输

`/admin_api` 使用 HTTP Basic Auth。凭据来源是**论坛登录表单**，保存在 `AppData/UserData/forum.config.json`：

```js
// modules/ipc/forumHandlers.js:60-65
const configToSave = {
    username: config.username || '',
    password: config.rememberCredentials ? (config.password || '') : '',
    ...
};
```

**密码明文写入磁盘 JSON 文件**，`rememberCredentials` 开关只决定是否持久化，不做任何加密或 OS keychain 集成。renderer 侧的论坛模块与任务模块都用页面 JS 的 base64 编码直接构造 Authorization 头（`Forummodules/forum.js:206`、`Agenttaskmodules/task.js:6,240`）——这只是 Base64 编码，不具备加密强度，且凭据字符串长期留在页面全局作用域。

### 7.2 Agent Assistant / Task Assistant 配置写入范围

`Agenttaskmodules/task.js` 通过 `apiFetch()`（`task.js:253-270`，固定拼接 `${serverBaseUrl}admin_api${endpoint}`）暴露以下写操作：

- `POST /admin_api/agent-assistant/config`：整体覆盖 Agent Assistant 配置，可新增、编辑或删除 Agent，请求体同时携带 Agent 字段与全局委托参数。
  - Agent 字段：

      ```text
      chineseName  baseName  modelId  systemPrompt  temperature  maxOutputTokens
      ```

  - 全局委托参数：`delegationMaxRounds`、`delegationSystemPrompt`、`delegationHeartbeatPrompt`。
- `POST /admin_api/agent-assistant/delegations/:id/cancel`：取消正在运行的异步委托任务。
- `POST /admin_api/task-assistant/config`：覆盖定时任务配置，涉及调度方式（cron、interval、once、manual）、任务类型（`forum_patrol`、`custom_prompt`）、`dispatch.taskDelegation` 开关，以及全局调度器开关。
- `POST /admin_api/task-assistant/trigger`：立即触发指定任务。

这些写操作覆盖的配置范围包括：任意 Agent 的系统提示词与模型参数、指向任意后端 `modelId` 的 Agent、定时任务提示词模板与调度开关，改动会持续生效直到被再次覆盖。管理面板与论坛登录共用同一份 Basic Auth 凭据（`forum.config.json`）。

依据：[`../../VCPChat/modules/ipc/forumHandlers.js:11-75`](../../VCPChat/modules/ipc/forumHandlers.js)（凭据明文存取）、[`../../VCPChat/Forummodules/forum.js:178-227`](../../VCPChat/Forummodules/forum.js)（Basic Auth 构造与登录表单）、[`../../VCPChat/Agenttaskmodules/task.js:224-870`](../../VCPChat/Agenttaskmodules/task.js)（继承论坛凭据与 `apiFetch` 封装、AA/FA 配置读写、立即触发与取消委托）。

**文档声称但未在代码验证**：VCPHumanToolBox 的 README 提到管理面板配置存储于 `localStorage`（`vcpht_adminConfig`）"与 contextIsolation 隔离保护"——`tool-manager.js:18-40` 确认了这份配置的读写代码；README 所说的"隔离保护"指该存储属于这个 Electron 子应用自己的 origin，没有额外加密或访问控制；与 `forum.config.json` 一样是明文存储，只是介质不同。

## 8. 子 Agent 与任务委派

VCPChat 客户端不直接执行"子 Agent"或"任务委派"的调度逻辑（那部分在 VCPToolBox 服务端的 Agent Assistant / Task Assistant 插件里，属另一 agent 调查范围），客户端 `Agenttaskmodules/task.js` 只是一个**配置与监控面板**：

- 轮询 `/admin_api/task-assistant/status` 每 15 秒一次（`task.js:136`）刷新任务运行状态。
- 轮询 `/admin_api/agent-assistant/delegations` 每 5 秒一次（`task.js:669`）显示异步委托任务的实时进度、最近回复预览、最终报告预览。
- 提供"立即执行任务"（`triggerTaskDirect`）、"取消委托"（`cancelDelegation`）两个写操作入口。

客户端侧真正自主运行的"类子 Agent"循环只有 Flowlock（见第 5 节）——它运行在聊天窗口内，由模型自身控制协议触发续写，编排边界完全在 renderer 进程内，与任务委派系统分属两条链路，没有独立进程或独立生命周期管理（页面刷新会清空所有 session，仅能通过 `recoverPendingRequests()` 恢复由 TopicSponsor 服务端插件创建的 pending Flowlock 话题请求）。

依据：[`../../VCPChat/Agenttaskmodules/task.js:121-145`](../../VCPChat/Agenttaskmodules/task.js)（初始化与轮询启动）、[`../../VCPChat/Agenttaskmodules/task.js:634-670`](../../VCPChat/Agenttaskmodules/task.js)（状态/委托轮询）、[`../../VCPChat/Flowlockmodules/flowlock.js:266-286`](../../VCPChat/Flowlockmodules/flowlock.js)（`recoverPendingRequests`）。

## 9. 配置与密钥：存储位置与保护

| 密钥/配置 | 存储位置 | 是否明文 | renderer 可访问性 |
|---|---|---|---|
| `vcpApiKey`（聊天 API Bearer token） | `AppData/settings.json` | 明文 | 通过 `chatAPI.loadSettings()` 可读，用于每次请求 `Authorization: Bearer` |
| `vcpServerUrl` | `AppData/settings.json` | 明文（URL） | 同上 |
| `vcpLogUrl` / `vcpLogKey`（VCPLog WebSocket 鉴权） | `AppData/settings.json` | 明文 | 主进程持有并用于连接；renderer 通过 `globalSettings` 间接可见（用于展示连接状态、Flowlock 续写请求） |
| `fileKey` | `AppData/settings.json` | 明文 | 用于分布式服务器诊断路由的密钥比较 |
| 论坛/`/admin_api` 用户名密码 | `AppData/UserData/forum.config.json` | 明文（`rememberCredentials` 决定是否持久化密码，但持久化即明文） | renderer 通过 IPC `load-forum-config` 读取，随后长期留存在页面全局变量 `apiAuthHeader` 中 |
| VCPHumanToolBox admin 配置（host/port/user/pass） | `localStorage`（`vcpht_adminConfig`，VCPHumanToolBox 子应用自己的 origin） | 明文 | 该子应用页面 JS 可直接读取 |
| DistImageServer/VCPMobileSync token | 各插件自己的 `config.env` | 明文 | 不在 VCPChat 主渲染进程内，而是分布式节点子进程读取 |

**总体结论**：VCPChat 及其分布式节点插件生态里，几乎所有密钥/凭据都以明文形式落盘（JSON 或 `.env` 文件），没有发现使用 OS keychain、`safeStorage`（Electron 提供的加密存储 API）或任何形式的凭据加密。各密钥/凭据的存储位置与 renderer 可访问性见上表。

依据：[`../../VCPChat/modules/utils/appSettingsManager.js:119-187`](../../VCPChat/modules/utils/appSettingsManager.js)（`defaultSettings` 字段列表，均以明文 JSON 存取，`writeSettings()` 直写不加密）、[`../../VCPChat/modules/ipc/forumHandlers.js:54-75`](../../VCPChat/modules/ipc/forumHandlers.js)、[`../../VCPChat/VCPHumanToolBox/renderer_modules/tool-manager.js:18-40`](../../VCPChat/VCPHumanToolBox/renderer_modules/tool-manager.js)。

## 10. 与消息渲染器笔记的交叉点

- **工具块与审批 UI 是两条独立通道**：聊天气泡内的工具请求与结果汇总展示走 Marked 渲染加保护映射，落在消息流的 `.md-content` 内（消息渲染器笔记 5.2-5.3 节）；审批卡片走悬浮 toast 与侧栏通知列表，DOM 由 `appendChild` 和 `textContent` 拼接，未见用 `innerHTML` 写入用户可控内容。
- **聊天正文能否伪造审批卡片**：消息渲染器笔记在聊天正文里没有找到会被误认成审批通知的语法，两类 UI 的视觉和 DOM 结构都不同——通知卡片带独立的 `.notification-tool-approval` class 与允许/拒绝按钮，聊天正文里的工具请求展示是 `<pre>` 代码块美化。因此仅靠聊天正文输出无法在通知区域生成审批卡片；该区域的唯一来源是 VCPLog 通道上的 `tool_approval_request` 消息（该通道不做消息级来源校验，见 4.5 节）。
- **工具结果的信任降级发生在两层**：消息渲染器笔记 5.3 节确认工具结果里的 HTML 走收紧后的 Markdown，权限低于 assistant 正文的完整 HTML 运行时；本笔记确认工具结果在客户端不经过任何执行逻辑，只按文本展示。工具执行发生在服务端或分布式节点，聊天窗口拿到的只有结果文本。

依据：[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 第 5.2-5.3、7.3 节；[`../../VCPChat/modules/notificationRenderer.js:322-487`](../../VCPChat/modules/notificationRenderer.js)（通知卡片 DOM 构造方式）。

## 11. 当前工具边界

当前快照把 Scriptorium 协作器扩展为分布式节点的 direct 工具：它可读取文档信息、渲染文本、源码与视觉上下文，并以 `SubmitSourcePr` 提交待人工处理的完整源码修订；文档侧分别为请求和审阅设置 30 秒与 5 分钟的超时。该链路仍由服务端工具审批和文档内 PR 回执共同约束，不能与聊天文本中的普通工具展示混为一条执行路径。移动同步则继续以 VCP-CDS 的中央索引为默认数据面，保留旧本地索引回退；Wire 1.2 的 canonicalizer、错误契约和幂等入口使同步协议的约束比普通聊天历史写入更明确。

LoomSkill 是 LoomController 内的组合执行面。CreateSkill/EditSkill 接收串行步骤，先校验声明的输入占位符，再对固定 target 做 WebCore 持久目标验证；trial 模式会试跑整条链，current 模式允许目标验证失败时保留低可靠性原始句柄并记录 warning，none 模式跳过 DOM 验证。执行时会在页面动作前完成输入替换，限制同步模式两分钟、异步任务数量与结果字节数，并以 busyApps 防止同一应用并发；任务状态只保留在进程内并按 TTL 回收，服务重启后查询不到旧 task。`VCPDistributedServer/Plugin/LoomController/LoomControllerService.js:325-412`、`LoomSkillService.js:129-269`

依据：

- `VCPDistributedServer/Plugin/ScriptoriumCollaborator/ScriptoriumCollaboratorService.js:979-1001`（文档侧超时与 PR 提交流程）
- `modules/ipc/docxHandlers.js:32-33`（文档读写入口）
- `VCPDistributedServer/Plugin/VCPMobileSync/index.js:114-191`（手机同步插件主入口）
- `VCPDistributedServer/Plugin/VCPMobileSync/transport/routes.js:76-184`（同步路由与错误契约）
- `VCPDistributedServer/Plugin/VCPMobileSync/sync/canonical.js:178-400`（同步协议 canonicalizer）

## 12. 未验证事项与后续调查缺口

- **各窗口 preload 的通道白名单差异**：聊天、工具与桌面三个 preload 脚本都暴露 `loadForumConfig`，本次未逐一核实每个 BrowserWindow 实际装载哪一个，也尚未确认是否存在某个窗口既执行不受信任内容、又具备论坛凭据读取权限的组合。
- **VCPLog 的默认连接协议**：代码不做协议强制升级，实际取用户在设置里填写的 `vcpLogUrl`；本次未找到硬编码默认地址，典型部署是否走加密连接尚未确认。
- **服务端审批配置的匹配规则与超时行为**：客户端侧没有审批超时机制（见 4.4 节）；服务端 `toolApprovalConfig.json` 是否在超时后下发显式通知消息（例如 `tool_approval_timeout` 类型），需要结合 VCPToolBox 源码确认，本次未覆盖。
- **插件回调端点的入站数据影响面**：该端点监听 `0.0.0.0` 且不做鉴权已确认；局域网内其他主机向它 POST 的数据在 VCPLog 通知流里呈现成什么形态（例如是否成为一条 `vcp_log` 消息），本次未运行验证。
- **审批卡片字段的构造来源**：客户端只渲染服务端审批请求 payload 里的字段（见 4.1 节）；服务端如何生成这些内容属于服务端范围，本次未下探。
- **本机分布式节点的实际可达范围**：HTTP 服务器绑定 `0.0.0.0`，同一局域网内其他设备理论上可以访问回调端点与诊断路由；Windows 防火墙默认规则是否拦截，以及这一绑定是否为配合手机同步的局域网需求而有意开放，本次均未实测确认。
- **VCP-CDS 的降级与一致性**：Rust 聊天数据服务以 shadow 形式运行（`modules/services/chatDataService/*`），二进制缺失、启动超时或崩溃时降级，聊天功能本身不受影响，但 DeepMemo 的中央检索与手机同步的中央索引随之不可用，或需要回退开关；CDS 摄取与 `history.json` 之间的最终一致性本次未运行验证。
- **DeepMemo v2 两套后端的行为差异**：`DeepMemoService.js` 默认使用 `backend: 'central'`，由 `DeepMemoLegacyFallback` 控制回退旧链路；两套检索对同一关键词的召回与排序差异，本次未运行对比。
- **LoomController 的能力边界**：manifest 注释声明 LoomAPP 的 `request.headers` 不可覆盖 Cookie 与 Host；"允许外部 origin 打开"开关与 WebContentsView 的隔离导航策略只有 `VCPLoomManager.js` 注释说明，具体防护效果本次仅做静态阅读，未实测。
- **渲染进程前端插件的信任面**：启用插件时只校验脚本与样式声明的文件名（`path.basename` 相等比较，`desktopHandlers.js:135-141`），插件脚本本身在主窗口上下文执行；配合界面里的启用机制，插件可以拿到 `window.chatAPI` 的完整通道，这一组合的实际影响本次未进一步核实。
- **LoomSkill 在真实页面上的效果**：schema、验证、执行与 TTL 状态机已从源码确认；LoomAPP 运行、WebCore 动作、目标跨文档代次失效与异步结果回流均未运行验证。
