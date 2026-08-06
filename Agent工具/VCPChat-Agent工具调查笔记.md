# VCPChat Agent 工具调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-07-30
>
> 代码快照：`3f14e938e700a5487ca13c4a6d8a6caad8e70ac9`（分支：`main`）
>
> 调查方式：只读源码梳理（未修改被调查仓库任何文件）；未运行仓库测试/构建，结论均以静态阅读源码为准
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 不是一个"纯审批终端"。横向笔记称它"通常不直接托管工具执行"，这句话对**远端 VCPToolBox 插件**（FileOperator、PowerShellExecutor、ScreenPilot 等 70+ 插件）成立，但对**客户端自身**不成立——VCPChat 随包携带一个独立的 `VCPDistributedServer` 子进程（`VCPDistributedServer/VCPDistributedServer.js`），它以 WebSocket 分布式节点身份连接主 VCPToolBox 服务器，把本机能力（音乐控制、骰子、Canvas、Flowlock、DesktopRemote、本机文件读取、本机插件目录下的 PowerShell/PTY Shell/截图/UI 自动化等）注册为可被模型调用的工具，并在收到 `execute_tool` 消息后在本机 Node/Python 子进程中真正执行。除此之外，Electron **主进程**本身还直接托管了一条更短的模型触发链路：DESKTOP_PUSH 语法在 renderer 流式解析阶段被拦截，直接调用 `electronAPI.desktopPush` 在桌面画布创建/写入 HTML 挂件，完全不经过 VCPToolBox 的审批协议。

代码中已确认的最重要发现：

1. **VCPChat 自带的分布式节点默认开启**（`enableDistributedServer: true`，`modules/utils/appSettingsManager.js:132`），随主进程一起启动（`main.js:1018`），把本机 70+ 插件目录（`VCPDistributedServer/Plugin/*`）中的能力注册进主 VCPToolBox 的工具目录，包括 `PowerShellExecutor`、`PTYShellExecutor`、`FileOperator`（读写任意/受限目录）、`ScreenPilot`（截图/OCR/模拟点击/UI 自动化）、`MediaShot`（截取本机文件）等。这些插件由本机 Node/Python 子进程执行，不在渲染器安全边界内。
2. **审批终端的"自动允许规则"存的是纯字符串/正则匹配，且可被配置得任意宽**：`modules/filterManager.js:508-542` 的 `checkToolAutoApproval()` 只按 `toolPattern` 对 `toolName` 做 `contains`/`exact`/`regex` 匹配，规则存在 `settings.json` 的 `toolAutoApprovalRules` 里，明文、无权限分级；一条 `matchMode:'contain', toolPattern:''` 或 `.*` 之类的正则即可让所有工具（包括 PowerShellExecutor / FileOperator）绕过人工审批，自动发送 `tool_approval_response:approved`。
3. **VCPLog WebSocket 通道本身没有二次消息鉴权**：主进程连接时用 URL 里的 `VCP_Key` 做一次性握手鉴权（`main.js:1242`），握手成功后同一条 WebSocket 上收到的任意 `tool_approval_request` payload 都被无条件展示为审批 UI 并可被自动规则批准（`modules/notificationRenderer.js:67-91`）。审批与拒绝的响应也通过同一条无进一步签名的通道回传（`sendToolApprovalResponse`，`modules/notificationRenderer.js:38-58`）。一旦服务端或中间人能在这条连接上注入消息，就能伪造审批请求/响应。
4. **`/admin_api` 使用 Basic Auth，凭据明文落盘在 `forum.config.json`**（`modules/ipc/forumHandlers.js:60-65`），renderer 端通过 `btoa(username:password)` 直接拼 `Authorization` header（`Agenttaskmodules/task.js:240`、`Forummodules/forum.js:183`），且**该 admin 面板可直接改写服务端的 Agent Assistant / Task Assistant 配置**（`agent-assistant/config`、`task-assistant/config`），包括新增/删除委托 Agent、系统提示词、定时任务——这是一条从客户端配置面到服务端 Agent 编排的提权路径，值得作为独立风险项处理。
5. **DESKTOP_PUSH 是一条完全绕开 VCPToolBox 审批协议的本地能力**：模型只需在流式输出中吐出 `<<<[DESKTOP_PUSH]>>>...<<<[DESKTOP_PUSH_END]>>>` 包裹的 HTML/CSS/JS，`modules/renderer/streamManager.js:1830-2016` 就会在 renderer 侧直接拦截并调用 `electronAPI.desktopPush()`，主进程 `desktop-push` IPC（`modules/ipc/desktopHandlers.js:913-917`）原样转发给桌面窗口渲染——没有 `tool_approval_request`、没有工具白名单校验，唯一的门槛是一个宽松的前缀白名单（`<div`/`<svg`/`<style` 等）。

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
     │ main.js:1018 (settings.enableDistributedServer=true 默认开启)                  │
     │   -> VCPDistributedServer.js: new WebSocket(mainServerUrl + VCP_Key=vcpKey)   │
     │   -> registerTools(): 本机 Plugin/* 目录 manifest 注册进主服务器工具目录        │
     │   -> 主服务器审批通过后下发 execute_tool -> handleToolExecutionRequest()       │
     │        -> pluginManager.processToolCall() -> spawn(本机 node/python 子进程)   │
     │        -> 特殊分支: MusicController/SuperDice/Flowlock/DesktopRemote          │
     │             直接调用注入的 main.js handler，操纵本机窗口/播放器/桌面           │
     │        -> internal_request_file: 直接 fs.readFile(file://本机路径) 返回 b64  │
     └──────────────────────────────────────────────────────────────────────────────┘
```

依据：`main.js:1234-1299`（VCPLog 连接与握手）、`main.js:1014-1043`（分布式服务器初始化）、`VCPDistributedServer/VCPDistributedServer.js:240-282`（WS 连接）、`modules/renderer/streamManager.js:1830-2016`（DESKTOP_PUSH 拦截）、`modules/notificationRenderer.js:36-91`（审批渲染与自动批准）。

## VCPChat 本地能力清单（模型可触发、在本机 Electron 或本机子进程中执行）

| 能力 | 触发方式 | 执行位置 | 审批 | 源码依据 |
|---|---|---|---|---|
| 桌面画布挂件创建/写入（HTML+CSS+JS） | 流式文本中的 `<<<[DESKTOP_PUSH]>>>` 语法 | renderer 拦截 -> IPC -> 桌面窗口 webContents | **无**，仅前缀白名单校验 | `modules/renderer/streamManager.js:1830-2016`、`modules/ipc/desktopHandlers.js:913-917` |
| 桌面壁纸/挂件/Dock 查询与设置（`SetWallpaper`/`CreateWidget`/`QueryDesktop` 等） | VCPToolBox `DesktopRemote` 工具调用，经分布式节点转发 | 主进程 `desktopRemoteHandlers.js` 直接操作桌面窗口、写 `AppData/DesktopData`/`DesktopWidgets` 文件 | 走服务端 `toolApprovalConfig.json` 规则（不在客户端） | `modules/ipc/desktopRemoteHandlers.js:241-698`、`VCPDistributedServer/VCPDistributedServer.js:707-727` |
| 音乐播放控制（play/pause/next/prev，按标题模糊匹配曲库） | VCPToolBox `MusicController` 工具，分布式节点特殊分支直调 | 主进程 `musicHandlers.handleMusicControl` 操纵音乐窗口 | 服务端规则 | `VCPDistributedServer/VCPDistributedServer.js:646-677`、`modules/ipc/musicHandlers.js:201-269` |
| 骰子 `SuperDice` | VCPToolBox `SuperDice` 工具，分布式节点特殊分支 | 主进程 `diceHandlers.handleDiceControl` | 服务端规则 | `VCPDistributedServer/VCPDistributedServer.js:678-691` |
| Flowlock 控制（启动/停止/查询/设置输入框内容） | VCPToolBox `Flowlock` 工具 + 客户端侧 AI 输出中的 `[[Flowlock::Start/Stop/...]]` 控制行 | 主进程 `desktopRemoteHandlers.handleFlowlockControl`；客户端侧由 `Flowlockmodules/flowlock.js` 状态机在**本地自主循环**中重新发起对话请求 | 服务端规则（Flowlock 工具调用一侧）；客户端自主续写循环无逐次审批，仅有最大重试次数与空闲超时 | `modules/ipc/desktopRemoteHandlers.js:163-239`、`Flowlockmodules/flowlock.js:43-506` |
| 本机文件读取并回传 Base64（`internal_request_file`） | 主服务器请求分布式节点读取 `file://` 本机路径 | 分布式节点子进程 `fs.readFile` | 服务端决定是否发起此请求；客户端侧无路径白名单校验 | `VCPDistributedServer/VCPDistributedServer.js:599-640` |
| 本机 PowerShell / PTY Shell 执行 | VCPToolBox `PowerShellExecutor`/`PTYShellExecutor` 工具（随 VCPChat 安装包分发的本机插件） | 分布式节点 `spawn()` 本机 shell 子进程；高危命令可能弹出 Tkinter 确认框 | 服务端 `toolApprovalConfig.json` + 插件自身 `FORBIDDEN_COMMANDS`/`AUTH_REQUIRED_COMMANDS` 字符串黑名单 | `VCPDistributedServer/Plugin/PowerShellExecutor/*`、`VCPDistributedServer/Plugin/PTYShellExecutor/*` |
| 本机文件系统读写（`FileOperator`：ReadFile/WriteFile/DeleteFile/MoveFile/CreateCanvas 等） | VCPToolBox `FileOperator` 工具 | 分布式节点子进程，受 `ALLOWED_DIRECTORIES` 配置约束（留空则不限制） | 服务端规则 | `VCPDistributedServer/Plugin/FileOperator/plugin-manifest.json`、`.env:7` |
| 屏幕截图/OCR/模拟鼠标键盘/UI 自动化 | VCPToolBox `ScreenPilot` 工具 | 分布式节点 Python 子进程，可后台（不劫持鼠标/键盘）操作任意窗口 | 服务端规则 | `VCPDistributedServer/Plugin/ScreenPilot/plugin-manifest.json` |
| 视频/音频/图像截取与编辑（`MediaShot`） | VCPToolBox `MediaShot` 工具 | 分布式节点 Python 子进程，读写本机文件路径 | 服务端规则 | `VCPDistributedServer/Plugin/MediaShot/plugin-manifest.json` |
| 图床/文件下载服务暴露（`DistImageServer`） | 服务类插件常驻 HTTP 路由 `/pw=<key>/files/*` | 分布式节点 Express 路由，`imageKey` 明文存于 `config.env` | 单一静态密钥比较，无速率限制 | `VCPDistributedServer/Plugin/DistImageServer/image-server.js:1-58` |
| 手机端同步（`VCPMobileSync`）：历史/头像/Agent 配置双向同步 | 常驻 WebSocket + HTTP，`x-sync-token`/Bearer 鉴权 | 分布式节点内嵌 sqlite 索引 + 文件系统读写 `AppData` | 静态 token 比较 | `VCPDistributedServer/Plugin/VCPMobileSync/transport/routes.js:42-60` |
| Agent 间话题委派/心流交接（`TopicSponsor`：CreateTopic/CreateFlowlockTopic/ReplyToTopic 等） | VCPToolBox 工具调用，写本机 `Agents/*/config.json` 与 `UserData/*/topics/*/history.json` | 分布式节点子进程直接文件写入，客户端 `Flowlockmodules/flowlock.js` 认领后续自主循环 | 服务端规则（工具调用侧）；话题认领本身由主进程 IPC 做单候选校验，非"审批"而是"占用锁" | `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`、`modules/ipc/chatHandlers.js:131-235` |
| DesktopRemote 本地测试后门路由 `/pw=<file_key>/desktop-remote-test` | HTTP POST（仅限 loopback） | 分布式节点直接调用 `handleDesktopRemoteControl` | `isLoopbackAddress` + `file_key` 明文比较，无速率限制 | `VCPDistributedServer/VCPDistributedServer.js:162-238` |
| 剪贴板读取（图片/文本） | 渲染层 UI 触发（非模型直接触发） | 主进程 `clipboard` API | 不适用——**未确认**模型可主动触发此路径，暂列为需进一步核实 | `preloads/shared/roles.js:9-10` |

**未列入本表**：消息渲染层的工具请求/结果展示（`<<<[TOOL_REQUEST]>>>` 美化、`[[VCP调用结果信息汇总:...]]` 卡片）、Mermaid/KaTeX/HTML 预览等——这些只是显示，不构成本地执行能力，已在消息渲染器笔记中覆盖。

依据：见各行源码路径；分布式节点插件清单来自 `VCPDistributedServer/Plugin/` 目录枚举（`../../VCPChat/VCPDistributedServer/Plugin/`）。

## 1. VCPChat 是否存在客户端侧的 VCP 文本块解析与本地分发

**结论：不存在**（对聊天流内的 `<<<[TOOL_REQUEST]>>>`/`tool_calls` 而言），但**存在**（对 DESKTOP_PUSH 这一条专用协议而言）。

`contentPipeline.js` 的 `protect-tool-requests`/`restore-tool-requests` 步骤（消息渲染器笔记 4.3 节已确认）只是把工具请求文本保护起来避免被 Markdown 破坏，随后交给 `transformSpecialBlocks()` 生成展示用 `<pre>` 块，**不会**解析 `tool_name`/参数字段去触发任何本地调用。`Flowlockmodules/flowlock-protocol.js` 同样只解析 Flowlock 控制行用于渲染状态气泡和驱动 `flowlock.js` 状态机（续写下一轮对话），不解析 VCP 工具字段。

真正的例外是 DESKTOP_PUSH：`streamManager.js` 中的 `interceptDesktopPushInStream()`（第 1830 行起）在 chunk 级别扫描 `<<<[DESKTOP_PUSH]>>>` 开始标记、缓冲内容、用 `DESKTOP_PUSH_VALID_PREFIXES` 做二级校验后，直接调用 `electronAPI.desktopPush({action:'create'/'append'/'finalize', widgetId, content})`。这是客户端对模型输出中一种私有协议的**本地解析 + 本地分发**，且完全独立于 VCPToolBox 的工具审批体系。

依据：[`../../VCPChat/modules/renderer/contentPipeline.js`](../../VCPChat/modules/renderer/contentPipeline.js)（未见工具字段解析分支）、[`../../VCPChat/modules/renderer/streamManager.js:1830-2016`](../../VCPChat/modules/renderer/streamManager.js)。

## 2. 是否作为 VCP 分布式节点向服务端暴露本机能力

**结论：是**，且默认开启。

`main.js:1014-1043` 在应用启动后异步读取 `settings.enableDistributedServer`（默认 `true`，见 `appSettingsManager.js:132`），若为真则 `require('./VCPDistributedServer/VCPDistributedServer.js')` 并 `initialize()`。该模块：

- 用 `config.vcpLogUrl`/`config.vcpLogKey`（与聊天所用 VCPLog 同一对 URL/Key）拼出 `ws://.../vcp-distributed-server/VCP_Key=<key>` 连接主服务器（`VCPDistributedServer.js:250`）。
- 连接成功后 `registerTools()`：扫描本机 `VCPDistributedServer/Plugin/*/plugin-manifest.json`，把所有类型（`static`/`synchronous`/`asynchronous`/`service`/`hybridservice`）插件的 manifest 一次性发给主服务器（`type:'register_tools'`），**没有排除规则**——不像 AIO Hub 的 VCP Connector 会排除 `vcp:` 前缀避免循环代理，这里未见任何类别或名称过滤（对比横向笔记对 AIO Hub 的描述，VCPChat 没有对应的循环保护逻辑，值得关注但影响面有限，因为节点本身不会反向拉取其他节点）。
- 收到 `execute_tool` 消息后 `handleToolExecutionRequest()` 用 `pluginManager.processToolCall()` 在本机 `spawn()` 子进程执行（`Plugin.js:205-304`），`MusicController`/`SuperDice`/`Flowlock`/`DesktopRemote` 四类工具走特殊分支直接调用 `main.js` 注入的 handler 操纵本机窗口。
- 鉴权：客户端到服务端方向只有一次性 URL Key 握手；服务端到客户端方向的 `execute_tool` 消息**没有任何签名或二次校验**，只要该 WebSocket 连接存在，服务端（或任何能向该连接注入消息的中间人）发什么 `toolName`/`toolArgs`，分布式节点就执行什么。
- 暴露面：本机 Express HTTP 服务器还额外监听 `0.0.0.0:<随机或固定端口>`（`bindHttpServer()` 用 `'0.0.0.0'` 而非 `127.0.0.1`），提供 `/plugin/callback`（异步插件回调，无鉴权）和 `/pw=<file_key>/desktop-remote-test`（仅限 loopback + 固定密钥）。`/plugin/callback` 绑定在 `0.0.0.0` 且不做来源校验，理论上局域网内其他主机可以 POST 数据进来，被转发进 VCPLog 通知流。

依据：[`../../VCPChat/main.js:1014-1043`](../../VCPChat/main.js)、[`../../VCPChat/VCPDistributedServer/VCPDistributedServer.js:75-100`](../../VCPChat/VCPDistributedServer/VCPDistributedServer.js)（`bindHttpServer` 监听 `0.0.0.0`）、[`../../VCPChat/VCPDistributedServer/VCPDistributedServer.js:139-153`](../../VCPChat/VCPDistributedServer/VCPDistributedServer.js)（`/plugin/callback` 无鉴权）、[`../../VCPChat/VCPDistributedServer/Plugin.js:104-164`](../../VCPChat/VCPDistributedServer/Plugin.js)。

## 3. 上游工具调用的接收：`tool_calls` 与 VCP 文本块

VCPChat 主聊天链路对上游返回的 `tool_calls` 字段采取**原样透传**策略，不在客户端解析或执行：

- `modules/vcpClient.js:154-160` 的消息规范化逻辑显式保留 `msg.tool_calls`/`msg.tool_call_id`（"严格脱敏：只返回由 OpenAI/Gemini 等 API 规范要求的字段"），但只是为了下一轮请求把历史消息原样发回服务器，不做本地分支。
- 流式 chunk 归一化（`sendToVCP()` 内的 `processStream()`，`vcpClient.js:400-427`）只识别 `choices[0].delta.content`/`delta.content`/`content` 三种文本字段来累积 `accumulatedResponse`，**没有**读取或处理 `delta.tool_calls`/`function_call` 等结构化字段。也就是说，如果上游模型走的是原生 function-calling 而不是 VCP 文本协议，VCPChat 当前实现不会把这类结构化调用转成任何本地动作——它假定所有"需要执行"的工具调用都以 VCP 文本块（`<<<[TOOL_REQUEST]>>>`）形式出现在 `content` 文本流中，由服务端（VCPToolBox）解析执行，客户端只负责显示。
- 流式期间的组装完全在 `streamManager.js` 中完成（消息渲染器笔记 6.3-6.4 节已确认），产物是 DOM 展示，不产生任何本地调用副作用，唯一例外仍是 DESKTOP_PUSH 拦截器。

依据：[`../../VCPChat/modules/vcpClient.js:108-170`](../../VCPChat/modules/vcpClient.js)（消息规范化，保留但不解析 `tool_calls`）、[`../../VCPChat/modules/vcpClient.js:363-441`](../../VCPChat/modules/vcpClient.js)（流式 chunk 归一化，只认 `content` 字段）。

## 4. 审批终端实现

### 4.1 `tool_approval_request` 接收与展示

VCPLog WebSocket 消息由主进程 `main.js:1270-1279` 的 `onmessage` 回调 `JSON.parse` 后原样通过 IPC `vcp-log-message` 转发给 renderer，renderer 端 `notificationRenderer.js:renderVCPLogNotification()` 判断 `logData.type === 'tool_approval_request'` 时：

1. 先调用 `window.filterManager.checkToolAutoApproval(logData.data)`（见 4.2）；命中则自动发送允许响应并把这次自动批准记为一条 `tool_auto_approval` 类型通知，**不展示原始审批卡片**。
2. 未命中自动规则时，渲染一张带"允许/拒绝"按钮和可选理由输入框的通知卡片（悬浮 toast + 侧栏列表两处），且该卡片**永不自动消失**（`autoDismissDelay = Infinity`，`notificationRenderer.js:463-464`），点击卡片本体也不会关闭（"审核请求防误触"注释，`notificationRenderer.js:339-341`）。

### 4.2 允许/拒绝响应发送

`sendToolApprovalResponse(requestId, approved, reason)`（`notificationRenderer.js:38-58`）构造 `{type:'tool_approval_response', data:{requestId, approved, reason?}}`，通过 `window.chatAPI.sendVCPLogMessage()` -> IPC `send-vcplog-message` -> 主进程 `vcpLogWebSocket.send(JSON.stringify(data))`（`main.js:1326-1333`）原样发回同一条 WebSocket。响应体里除 `requestId`/`approved`/可选 `reason` 外**没有任何身份或时间戳字段**，也没有对 `requestId` 做签名或来源校验——`requestId` 完全由服务端在 `tool_approval_request` 中给出，客户端只是照抄。

### 4.3 本地自动允许规则的匹配语义与存储位置

自动允许规则存储在 `settings.json` 的 `toolAutoApprovalRules` 数组中（`modules/utils/appSettingsManager.js:96-97` 声明默认值 `[]`），每条规则形如：

```json
{ "id": "...", "name": "...", "toolPattern": "...", "matchMode": "contain|exact|regex", "description": "...", "enabled": true, "order": 0 }
```

`checkToolAutoApproval(approvalData)`（`filterManager.js:508-542`）的匹配语义：

- 全局开关 `settings.toolAutoApprovalEnabled` 为 `false` 时整个机制不生效。
- 取 `approvalData.toolName || approvalData.tool_name`（信任服务端上报的工具名，无本地白名单交叉校验）。
- 按 `order` 排序遍历规则，`enabled:false` 的规则跳过。
- `matchMode === 'exact'`：`toolName === pattern` 精确相等。
- `matchMode === 'regex'`：`new RegExp(pattern).test(toolName)`——**用户可以直接填一个 `.*` 或空模式的宽正则**，`saveToolAutoApprovalRule()` 只校验正则语法是否合法（`filterManager.js:438-445`），不校验其宽泛程度。
- 默认（`contain`）：`toolName.includes(pattern)`——**留空 `toolPattern` 会在 UI 层被 `!ruleData.toolPattern` 挡掉**（`filterManager.js:433-436`），但一个只有一个字符的 pattern（如 `e`）几乎会匹配所有工具名，等价于全局自动允许。
- 命中第一条规则即返回 `{rule, action:'approve'}`，后续规则不再检查——**没有"deny 优先"或"高危工具强制人工审批"的硬编码例外**：无论工具名是 `PowerShellExecutor` 还是 `SuperDice`，只要匹配到一条启用的规则，都会被同等自动允许。

这与横向笔记原文"支持逐次决定"的表述相比，**需要纠正**：客户端确实支持逐次决定，但一旦用户配置了过宽的自动允许规则，逐次决定权会被静默绕过，且**没有区分工具风险等级的机制**（不像 Cherry Studio 对只读工具和 Bash 类工具做默认策略区分，也不像 LobeHub 的 `always` 规则不可被 auto-run 绕过）。

### 4.4 超时行为

客户端侧**没有**审批超时机制——通知卡片 `autoDismissDelay = Infinity`，会一直挂在通知列表里直到用户手动点击允许/拒绝或应用重启。超时逻辑（若存在）应在 VCPToolBox 服务端的 `toolApprovalManager.js`（另一 agent 调查范围），客户端未确认服务端超时后是否会向本连接推送任何"已超时"的后续消息。

### 4.5 通知渠道鉴权与可伪造性

VCPLog WebSocket 的鉴权模型是**一次性握手**：连接 URL 中携带 `VCP_Key`（`main.js:1242`：`${wsUrl}/VCPlog/VCP_Key=${wsKey}?deviceName=...`），服务端在建立连接时校验一次。握手成功后，**该连接上收到的每一条消息都被无条件信任**——`main.js:1270-1279` 的 `onmessage` 只做 `JSON.parse`，不检查消息来源、不做消息级签名，直接转发给 renderer 渲染成审批卡片或其它通知。

由此产生的关键结论（已确认，非推测）：**任何能够在这条已建立的 WebSocket 连接上注入消息的一方（恶意/被入侵的 VCPToolBox 服务端、或网络中间人若 VCPLog 使用 `ws://` 而非 `wss://`）都可以伪造 `tool_approval_request`，诱导用户误点"允许"，或直接伪造一条能命中自动允许规则的请求实现无人值守执行**。客户端没有任何机制区分"这条审批请求确实对应一次真实的、待执行的工具调用"与"这是服务端/中间人构造的假请求"。`vcpLogUrl` 的协议（`ws://` 或 `wss://`）由用户在设置里填写，代码未见强制升级到 `wss://` 的逻辑。

依据：[`../../VCPChat/main.js:1234-1333`](../../VCPChat/main.js)（VCPLog 连接、消息转发、发送响应）、[`../../VCPChat/modules/notificationRenderer.js:36-91`](../../VCPChat/modules/notificationRenderer.js)、[`../../VCPChat/modules/notificationRenderer.js:233-331`](../../VCPChat/modules/notificationRenderer.js)（审批卡片渲染与按钮）、[`../../VCPChat/modules/filterManager.js:87-95`](../../VCPChat/modules/filterManager.js)（规则默认值归一化）、[`../../VCPChat/modules/filterManager.js:420-542`](../../VCPChat/modules/filterManager.js)（编辑器校验与匹配逻辑）。

## 5. 编排：客户端是否参与迭代循环

**分两条线看**：

1. **普通工具调用迭代循环**：客户端**不参与**。VCPChat 的 `vcpClient.js` 只做单次请求/响应（或单次流式会话），把完整历史发给服务端，工具调用的"发起模型请求 -> 执行工具 -> 把结果回注上下文 -> 再次请求模型"的整轮迭代逻辑在 VCPToolBox 服务端完成（属另一 agent 调查范围）。客户端能看到的只是最终这一轮的 `data`/`end`/`error` 流事件。
2. **Flowlock 心流锁循环**：客户端**确实**参与一个本地自主循环，但这个循环编排的是"要不要发起下一轮完整对话请求"，不是"工具调用内部的多轮迭代"。`Flowlockmodules/flowlock.js` 的 `FlowlockManager` 为每个 Agent 维护一个状态机：`start()`/`stop()`/`scheduleNextRound()`/`triggerRound()`。触发条件是模型输出末尾出现 `[[Flowlock::Start]]` 等控制行（由 `flowlock-protocol.js` 解析）；`triggerRound()` 调用 `continueWritingForContext()`（`Flowlockmodules/flowlock-integration.js:58-267`）重新读取历史、重新发起一次完整的 `chatAPI.sendToVCP()` 请求。
   - **上限**：每个 session 有 `maxRetries = 3`（错误重试上限），无对"正常轮数"的硬上限——只要模型持续输出 `[[Flowlock::NextHeartbeat::N]]` 而不输出 `Stop`/`Complete`/`Fail`，循环可以无限期持续，唯一的软约束是 `delaySeconds` 被 `normalizeDelaySeconds()` 限制在 1-86400 秒之间（`flowlock-protocol.js:199-205`）。
   - **超时**：DesktopPush 有独立的 150 秒空闲超时（见能力清单），Flowlock 本身没有总时长超时。
   - **取消**：`stop(agentId)`（右键菜单、快捷键 Ctrl/Cmd+G、或模型输出 `[[Flowlock::Stop]]`）可随时中断；`cleanup()` 在页面卸载时清空所有 session。

依据：[`../../VCPChat/Flowlockmodules/flowlock.js:43-160`](../../VCPChat/Flowlockmodules/flowlock.js)（start/stop）、[`../../VCPChat/Flowlockmodules/flowlock.js:285-411`](../../VCPChat/Flowlockmodules/flowlock.js)（`handleFinalizedMessage` 编排下一轮）、[`../../VCPChat/Flowlockmodules/flowlock-integration.js:58-267`](../../VCPChat/Flowlockmodules/flowlock-integration.js)（`continueWritingForContext` 重新发起请求）。

## 6. 结果处理与回注

工具结果（VCP 文本块形式）作为普通消息文本的一部分被写入聊天历史（`history.json`），下一轮对话时随完整历史一起发给服务端——客户端不单独截断或结构化存储工具结果本体，截断只发生在**展示层**：消息渲染器笔记 5.3 节已确认的 `renderToolResultBlock()` 对超过 50,000 字符的返回内容值只展示前 80 行，完整值保存在内存映射供展开查看，**不修改历史文件中的原始内容**。

错误形态：VCP 请求失败（HTTP 非 2xx、JSON 解析失败、AbortError 超时/取消）在 `vcpClient.js` 中都转换为 `{type:'error', error, accumulatedResponse}` 流事件，交由 `streamManager.finalizeStreamedMessage()` 合并已收文本和错误说明后落盘为一条 assistant 消息（消息渲染器笔记 6.7 节已确认），不是抛出异常中断整个会话。

依据：[`../../VCPChat/modules/vcpClient.js:307-361`](../../VCPChat/modules/vcpClient.js)（HTTP 错误处理）、[`../../VCPChat/modules/vcpClient.js:478-507`](../../VCPChat/modules/vcpClient.js)（AbortError/异常处理）；工具结果截断见消息渲染器笔记 5.3 节，[`../../VCPChat/modules/messageRenderer.js:1894`](../../VCPChat/modules/messageRenderer.js) 附近。

## 7. `/admin_api` 管理面：一条提权路径

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

**密码明文写入磁盘 JSON 文件**，`rememberCredentials` 开关只决定是否持久化，不做任何加密或 OS keychain 集成。renderer 侧 `Forummodules/forum.js:183` 和 `Agenttaskmodules/task.js:240` 都用 `btoa(username:password)` 直接构造 `Authorization: Basic ...` header——`btoa` 只是 Base64 编码，不是加密，且这一构造发生在 renderer 进程（`contextIsolation:true` 但页面 JS 本身可执行），意味着**任何能在这两个页面上下文执行 JS 的代码（包括通过消息渲染器的 XSS，见第 9 节）都能读取到已解码的用户名密码**，因为 `apiAuthHeader` 变量本身就活在页面全局作用域里（`Agenttaskmodules/task.js:6`）。

### 7.2 Agent Assistant / Task Assistant 配置面即提权路径

`Agenttaskmodules/task.js` 通过 `apiFetch()`（`task.js:253-270`，固定拼接 `${serverBaseUrl}admin_api${endpoint}`）暴露以下写操作：

- `POST /admin_api/agent-assistant/config`：整体覆盖 Agent Assistant 配置，包括新增/编辑/删除 Agent（`chineseName`/`baseName`/`modelId`/`systemPrompt`/`temperature`/`maxOutputTokens`）、全局委托参数（`delegationMaxRounds`/`delegationSystemPrompt`/`delegationHeartbeatPrompt`）。
- `POST /admin_api/agent-assistant/delegations/:id/cancel`：取消正在运行的异步委托任务。
- `POST /admin_api/task-assistant/config`：覆盖定时任务配置（cron/interval/once/manual 调度、`forum_patrol`/`custom_prompt` 类型、`dispatch.taskDelegation` 开关）、全局调度器开关。
- `POST /admin_api/task-assistant/trigger`：立即触发指定任务。

这构成一条**从 VCPChat 客户端配置面到 VCPToolBox 服务端 Agent 编排能力的提权路径**：拿到（或伪造/爆破）一次 Basic Auth 凭据，攻击者不仅能读取委托任务/Agent 列表，还能**修改任意 Agent 的系统提示词**（相当于劫持该 Agent 未来所有对话的行为）、**新增指向任意后端 `modelId` 的 Agent**、**修改定时任务的提示词模板使其在下次触发时执行任意指令**，且这些改动会持续生效直到再次被覆盖——不是一次性的越权读取，而是持久化的行为篡改。由于凭据来源仅是论坛登录（一个相对"轻"的功能入口），使用该论坛功能的用户可能没有意识到同一凭据保护着 Agent 编排的写权限。

依据：[`../../VCPChat/modules/ipc/forumHandlers.js:11-75`](../../VCPChat/modules/ipc/forumHandlers.js)（凭据明文存取）、[`../../VCPChat/Forummodules/forum.js:155-204`](../../VCPChat/Forummodules/forum.js)（Basic Auth 构造与登录表单）、[`../../VCPChat/Agenttaskmodules/task.js:224-270`](../../VCPChat/Agenttaskmodules/task.js)（继承论坛凭据、`apiFetch` 封装）、[`../../VCPChat/Agenttaskmodules/task.js:334-363`](../../VCPChat/Agenttaskmodules/task.js)（AA 配置读写）、[`../../VCPChat/Agenttaskmodules/task.js:619-665`](../../VCPChat/Agenttaskmodules/task.js)（FA 配置读写与立即触发）、[`../../VCPChat/Agenttaskmodules/task.js:853-870`](../../VCPChat/Agenttaskmodules/task.js)（取消委托）。

**文档声称但未在代码验证**：VCPHumanToolBox 的 README 中提到管理面板配置存储于 `localStorage`（`vcpht_adminConfig`）"与 contextIsolation 隔离保护"——`tool-manager.js:18-40` 确认了 `localStorage` 存取代码，但 README 所说的"隔离保护"只是指 `localStorage` 属于该 Electron 子应用自己的 origin，并不构成额外加密或访问控制，与 `forum.config.json` 明文落盘在风险性质上类似（同样是明文，只是介质不同）。

## 8. 子 Agent 与任务委派

VCPChat 客户端不直接执行"子 Agent"或"任务委派"的调度逻辑（那部分在 VCPToolBox 服务端的 Agent Assistant / Task Assistant 插件里，属另一 agent 调查范围），客户端 `Agenttaskmodules/task.js` 只是一个**配置与监控面板**：

- 轮询 `/admin_api/task-assistant/status` 每 15 秒一次（`task.js:136`）刷新任务运行状态。
- 轮询 `/admin_api/agent-assistant/delegations` 每 5 秒一次（`task.js:669`）显示异步委托任务的实时进度、最近回复预览、最终报告预览。
- 提供"立即执行任务"（`triggerTaskDirect`）、"取消委托"（`cancelDelegation`）两个写操作入口。

客户端侧真正自主运行的"类子 Agent"循环只有 Flowlock（见第 5 节）——它不是任务委派系统的一部分，而是聊天窗口内由模型自身控制协议触发的续写循环，编排边界完全在 renderer 进程内，没有独立进程或独立生命周期管理（页面刷新会清空所有 session，仅能通过 `recoverPendingRequests()` 恢复由 TopicSponsor 服务端插件创建的 pending Flowlock 话题请求）。

依据：[`../../VCPChat/Agenttaskmodules/task.js:121-145`](../../VCPChat/Agenttaskmodules/task.js)（初始化与轮询启动）、[`../../VCPChat/Agenttaskmodules/task.js:634-670`](../../VCPChat/Agenttaskmodules/task.js)（状态/委托轮询）、[`../../VCPChat/Flowlockmodules/flowlock.js:259-278`](../../VCPChat/Flowlockmodules/flowlock.js)（`recoverPendingRequests`）。

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

**总体结论**：VCPChat 及其分布式节点插件生态里，几乎所有密钥/凭据都以明文形式落盘（JSON 或 `.env` 文件），没有发现使用 OS keychain、`safeStorage`（Electron 提供的加密存储 API）或任何形式的凭据加密。这些文件都在 renderer 有权访问的 `AppData` 目录内，若 renderer 存在任意文件读取能力（例如经 preload API 暴露的 `chatAPI.loadSettings`/`loadForumConfig` 本身就是设计内的读取通道），凭据即可被读出。

依据：[`../../VCPChat/modules/utils/appSettingsManager.js:84-149`](../../VCPChat/modules/utils/appSettingsManager.js)（`defaultSettings` 字段列表，均以明文 JSON 存取，`writeSettings()` 直写不加密）、[`../../VCPChat/modules/ipc/forumHandlers.js:54-75`](../../VCPChat/modules/ipc/forumHandlers.js)、[`../../VCPChat/VCPHumanToolBox/renderer_modules/tool-manager.js:18-40`](../../VCPChat/VCPHumanToolBox/renderer_modules/tool-manager.js)。

## 10. 安全审计

逐条标注可利用性与前提条件，区分"已确认"与"需进一步验证"。

### 10.1 伪造 `tool_approval_request` / `tool_approval_response`（已确认，条件：能在已建立的 VCPLog 连接上注入消息）

VCPLog 消息处理（`main.js:1270-1279`）对收到的每条 WebSocket 消息只做 `JSON.parse`，不校验发送方身份、不做消息签名。任何能在这条连接上写入数据的角色（恶意/被入侵的服务端，或 `ws://` 明文连接下的网络中间人）都可以：
- 发送任意 `tool_approval_request`，诱导用户点击"允许"（即使对应的工具调用从未真正被服务端排队），或者更危险地，构造一个 `toolName` 恰好命中用户已配置的自动允许规则的请求，**无需用户交互即可让客户端回传 `approved:true`**。
- 伪造 `tool_approval_response` 本身不成立（响应是客户端->服务端方向），但可以伪造服务端会"接受"的响应格式来观察客户端行为——这一方向价值有限，真正的风险在于伪造请求方向。

利用前提：控制或劫持 VCPLog 服务端连接，或该连接使用未加密的 `ws://`。若用户始终使用 `wss://` 且服务端本身可信，此风险主要退化为"服务端被攻破后能诱导本机误操作"，而非独立的客户端漏洞。

### 10.2 自动允许规则过宽（已确认，条件：用户主动配置了宽松规则）

见第 4.3 节。`matchMode:'contain'` 配合极短 pattern，或 `matchMode:'regex'` 配合 `.*`，可使所有工具调用（包括本机分布式节点上的 `PowerShellExecutor`/`FileOperator`）无需人工审批直接执行。这不是代码缺陷本身（功能按设计工作），而是**缺少风险分级提示或强制护栏**——UI 没有对"这条规则会匹配到高危工具"给出任何警告，也没有像 LobeHub 的 `always` 规则那样存在不可被覆盖的强制审批类别。

### 10.3 `admin_api` 凭据泄漏与提权（已确认，条件：能读取 `forum.config.json` 或读取 renderer 内存/网络流量）

见第 7 节。密码明文落盘 + Basic Auth（无 TLS 时等价于明文传输）+ 可写的 Agent/Task 配置端点，构成完整的提权链：读到凭据 -> 篡改 Agent 系统提示词/新建任务 -> 在下次任务触发或该 Agent 参与对话时执行攻击者注入的指令。

### 10.4 渲染层 XSS 到 preload API（需进一步验证，结合渲染器笔记结论）

消息渲染器笔记已确认（4.5、7.3 节）assistant 消息中的原始 HTML/`<script>` 会在主聊天 `.md-content` 中执行，且 Marked 未安装 sanitizer（`sanitize:false` 但实际是"未设置 sanitizer"）。理论上，若模型输出的消息内容包含恶意脚本且未被现有保护映射拦截，该脚本运行在与 `Agenttaskmodules/task.js`/`Forummodules/forum.js` **不同的** BrowserWindow（主聊天窗口 vs 独立的任务/论坛子窗口），因此**默认不能直接读取 `apiAuthHeader` 变量**——两者是不同的渲染进程实例，各自的 `window` 全局作用域互不可见。但如果同一台机器上、同一用户会话下这些窗口共享同一个 preload API 实现（`preloads/chat.js`/`preloads/utility.js` 都暴露了 `loadForumConfig`），恶意脚本至少可以在**自己所在的窗口**内调用 `chatAPI.loadForumConfig()` 重新读取一次明文凭据——这条路径**已确认存在**（IPC 通道本身允许任意 renderer 调用），只是需要恶意脚本恰好运行在主聊天窗口而非独立子窗口时，还需要额外一步"调用 preload API 主动读取"而非"直接读取已存在的全局变量"。是否存在从主聊天窗口的 XSS 直接触达论坛/任务面板凭据的完整链路，仍需结合 preload 白名单的窗口级差异做更细致的验证（**未验证**：三个 preload 文件——`chat.js`/`utility.js`/`desktop.js`——的 `loadForumConfig` 白名单范围是否一致，若主聊天窗口 preload 本身就暴露该通道,则风险等级应上调为"已确认"）。

### 10.5 Prompt 注入经审批 UI 误导用户（需进一步验证）

审批卡片的展示内容（`titleText`/`mainContent`）直接来自服务端 `tool_approval_request.data` 中的 `toolName`/`args`/`maid`/`timestamp` 字段（`notificationRenderer.js:233-237`），这些字段的取值链条最终可能受模型输出影响（例如 `args.command` 若是模型生成的自由文本）。理论上模型可以让 `command` 参数看起来"无害"（掩盖真实意图）来误导用户点击允许——这是经典的审批 UI 层 prompt 注入风险，但**未在客户端代码层面确认**具体的字段净化/校验逻辑之外的问题；这条风险的根因更多在服务端如何构造 `tool_approval_request` 的展示字段，需要结合 VCPToolBox 端 `toolApprovalManager.js` 的实现共同评估（超出本笔记范围，标注为需进一步验证）。

### 10.6 DESKTOP_PUSH 无审批直达桌面渲染（已确认）

见能力清单第一行。这是一条**已确认**、**不需要任何前提条件**（只要模型输出包含合法前缀的 DESKTOP_PUSH 块）即可触发的本地能力，且完全绕开 VCPToolBox 的 `tool_approval_request`/规则体系。风险大小取决于桌面挂件 HTML/JS 的执行环境权限——挂件运行在独立的桌面窗口 `.md-content`-类似的 DOM 中，权限模型与消息渲染器笔记第 7 节描述的"assistant HTML 执行"一致（同源页面 JS 权限，非沙箱隔离）。

## 11. 与消息渲染器笔记的交叉点

- **工具块与审批 UI 呈现的分离**：聊天气泡内的 `<<<[TOOL_REQUEST]>>>`/`[[VCP调用结果信息汇总:...]]` 展示（消息渲染器笔记 5.2-5.3 节）与本笔记第 4 节的 `tool_approval_request` 通知卡片是**两条完全独立的 UI 通道**——前者渲染在聊天消息流的 `.md-content` 内，走 Marked + 保护映射；后者渲染在悬浮 toast / 侧栏通知列表内，是纯 DOM 拼接（`notificationRenderer.js` 大量使用 `element.appendChild`/`textContent`，未见 `innerHTML` 拼接用户可控内容，是相对更安全的写法）。
- **模型是否可以伪造出"看起来像审批请求"的聊天消息**：消息渲染器笔记未发现聊天正文中存在会被误认成 `tool_approval_request` 通知卡片的语法——两者视觉和 DOM 结构都不同（通知卡片有独立的 `.notification-tool-approval` class 和"允许/拒绝"按钮，聊天消息里的工具请求展示是 `<pre>` 代码块美化）。因此**模型无法仅通过聊天正文输出伪造出弹在通知区域的审批卡片**；真正的伪造风险（10.1 节）只能通过污染 VCPLog WebSocket 消息本身达成，不能通过"聊天内容里写一段看起来像审批请求的文字"达成——这是一个相对积极的边界确认，值得在笔记中明确指出。
- **工具结果的两层信任降级**：消息渲染器笔记 5.3 节确认工具结果 HTML 走"收紧后的 Markdown"，比 assistant 正文的"完整 HTML 运行时"权限更低。这与本笔记确认的"工具结果本身在客户端不经过任何执行逻辑，只是展示"一致——工具执行发生在服务端/分布式节点，客户端接收到的只是文本结果，双重确认了 VCPChat 聊天窗口对工具结果是纯展示消费者。

依据：[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 第 5.2-5.3、7.3 节；[`../../VCPChat/modules/notificationRenderer.js:248-396`](../../VCPChat/modules/notificationRenderer.js)（通知卡片 DOM 构造方式）。

## 12. 对旧横向笔记的纠正

1. **"VCPChat 主要是 VCPToolBox 的客户端与审批终端，并不直接托管工具执行"**——需要限定范围。客户端渲染进程确实不执行 VCPToolBox 主服务器插件；但 VCPChat **随包携带并默认启用**一个独立的分布式节点子系统（`VCPDistributedServer`），该子系统在**本机**用 Node/Python 子进程真实执行包括 `PowerShellExecutor`/`FileOperator`/`ScreenPilot` 等高危插件。"VCPChat 不托管工具执行"这句话对聊天窗口本身成立，但对"VCPChat 这个应用/安装包"整体不成立。旧横向笔记的矩阵表格里"实际执行域"一列写"ToolBox plugin 或分布式节点"——**已经提到了分布式节点**，但结论摘要里"VCPChat 主要是...客户端与审批终端"这句定性描述与自己矩阵表格内容存在张力，本笔记做了明确区分。
2. **"客户端自身不替服务端隔离插件能力"**——这句话本身没错，但遗漏了一个更直接的问题：客户端自己的分布式节点**也不给自己的插件做隔离**（没有沙箱、没有路径白名单强制、`FORBIDDEN_COMMANDS` 只是字符串黑名单可被绕过）。这不是"客户端没有替别人做隔离"，而是"客户端自己就是那个需要隔离但没有做隔离的执行者"。
3. **审批语义描述过于简单**："支持按工具/方法自动批准与手动批准"这一表述没有说明自动批准规则的匹配语义可以宽到什么程度（本笔记 4.3、10.2 节），也没有提及 VCPLog 通道本身缺乏消息级鉴权（本笔记 4.5、10.1 节）——这两点是本笔记新增的、旧横向笔记未覆盖的风险维度。
4. **未提及 DESKTOP_PUSH**：旧横向笔记完全没有提到这条绕开审批体系的本地能力，本笔记补充为能力清单第一行、审批清单例外。

## 13. 未验证事项与后续调查缺口

- **`preload/chat.js` vs `preload/utility.js` vs `preload/desktop.js` 的通道白名单差异**：三者都暴露 `loadForumConfig`，但未逐一核实每个 BrowserWindow 实际装载的是哪个 preload，以及是否存在某个窗口既能执行不受信任内容又同时拥有论坛凭据读取权限的组合（10.4 节标注为需进一步验证）。
- **VCPLog 默认协议是 `ws://` 还是 `wss://`**：代码本身不强制升级，具体默认值取决于用户在设置里填写的 `vcpLogUrl`；未找到硬编码默认 URL 来判断典型部署是否走加密连接。
- **服务端 `toolApprovalConfig.json` 的实际匹配规则与超时行为**：本笔记第 4.4 节已说明客户端无超时机制，但服务端是否有超时后的显式通知消息（例如 `tool_approval_timeout` 类型）需要结合 VCPToolBox 源码确认，本笔记未越界调查。
- **`/plugin/callback` 端点的滥用影响面**：确认了该端点监听 `0.0.0.0` 且无鉴权，但未验证局域网内伪造回调数据具体能在 VCPLog 通知流里造成何种具体后果（例如是否会被渲染为可信的 `vcp_log` 消息进而误导用户）。
- **10.5 节 prompt 注入经审批 UI 误导用户**：客户端展示逻辑本身简单直接，真正的风险主体（服务端如何构造 `args` 字段展示内容）超出本次调查范围，仍标注为需进一步验证。
- **本机分布式节点在 Windows 上的实际默认监听范围**：`bindHttpServer` 使用 `'0.0.0.0'`，意味着同一局域网内其他设备理论上可达 `/plugin/callback` 和诊断路由；未实测防火墙默认规则是否会拦截，也未确认这是否是有意为之的设计（例如配合 VCPMobileSync 局域网同步的需求）。

