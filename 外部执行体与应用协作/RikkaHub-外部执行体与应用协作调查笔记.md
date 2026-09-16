# RikkaHub 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9a35e3f2f1e2820e95c37deb82ef8f5e1592e06f`（分支：`master`）
>
> 调查方式：静态阅读 Android/Kotlin 源码，覆盖 MCP 客户端与连接注册表、MCP OAuth 协调器与 loopback 回调服务器、workspace（PRoot rootfs）执行链、内嵌 Ktor Web 服务器与 JWT 鉴权、Workspace/Web 相关 Room 实体与设置持久化；未在设备或模拟器上运行，未执行真实 MCP 往返、OAuth 授权或 PRoot 命令。
>
> 调查范围：MCP 服务器的配置/连接/工具发现与命名、传输方式、OAuth 授权；workspace 的创建、启动、shell 工具暴露、文件系统边界与生命周期；内嵌 Web 服务器的启动与鉴权、Web 端与端上的数据共享；外部应用/业务应用的连接边界。排除普通模型 Provider、搜索服务、技能内容本身、备份同步与视频生成等模块。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

本仓库的外部协作能力由三条执行位置不同的主链构成，均可在当前快照静态走通：

- **外部工具服务（MCP 客户端）**：应用作为 MCP Host 连接远端 SSE 或 Streamable HTTP 服务器，把发现的工具注册进当前助手的工具表；工具循环留在宿主进程，服务器只提供工具能力，连接与令牌刷新由运行时注册表管理（`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpManager.kt:106-133`）。
- **外部执行体（workspace / PRoot）**：每个 workspace 是一份用户自行下载的 Ubuntu rootfs 加一个应用私有文件区，模型通过 workspace 工具在其内读写文件、执行 shell，命令落在 PRoot 用户态沙箱中（`workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt`、`ProotShellRunner.kt`）。
- **外部控制表面（内嵌 Web 服务器）**：端上启动 Ktor CIO 服务器，随包发布的 React 前端经 HTTP 与 SSE 复用同一套会话服务与设置存储（`app/src/main/java/me/rerere/rikkahub/web/WebServerManager.kt:53-108`、`WebApiModule.kt:61-189`）。

三者的共同点：是否自动执行由工具自带的审批需求与该表面的用户开关决定，外部内容只被当作工具输入或沙箱命令，而不是可回写宿主状态的外部会话；MCP 独有账号级凭据与远端连接生命周期，workspace 独有独立执行环境，Web 是唯一能从宿主之外驱动同一会话的控制表面。

## 接入角色与系统边界

| 接入角色 | 本仓库对象 | 协议方向与执行位置 |
|---|---|---|
| 外部工具服务 | 远端 MCP Server（SSE / Streamable HTTP） | 宿主发起连接、发现并调用工具；server 提供工具执行，无本地会话映射 |
| 外部执行体 | workspace 的 PRoot rootfs 子进程 | 宿主进程内拉起 PRoot 子进程，命令在 rootfs 用户态沙箱执行 |
| 外部控制表面 | 浏览器中的 web-ui 前端 | 外部客户端经 HTTP/SSE 驱动宿主同一 ChatService 与会话 |

MCP 侧有完整生命周期与凭据，满足本类目"可识别身份 + 持续生命周期 + 双向协议 + 状态映射 + 治理边界"的准入；但它不把外部服务器的会话或资源映射回本地对象，工具结果直接并入助手消息。workspace 有独立 runtime 与文件系统，但进程由宿主拉起并同步等待结果，不存在两端的会话协议。Web 端满足"可发起、回答、停止同一任务"的控制表面定义。

本次未找到：外部 CLI Agent、Agent SDK、ACP 或远程任务队列入口；MCP stdio 传输；账号/installation/Connector 模型；webhook 或 WebSocket 反向推送。检查范围为当前快照的 `data/ai/mcp`、`data/ai/extension`、`workspace`、`web`、`web-ui`、`oauth` 模块与 `settings.gradle.kts` 所列模块。

## 完整主链

### 主链 A：MCP 连接与工具调用

```text
设置页新增服务器（类型、URL、可选 headers、可选 OAuth）
  -> McpManager 订阅 settings.mcpServers -> SessionRegistry.reconcile
  -> 每个启用的 serverId 建 McpSession，connectSession 在 lifecycleMutex 内串行
  -> createTransport 选 SSE 或 Streamable HTTP 并注入 headers -> sdkClient.connect
  -> 401 且 OAuth 可发现则置 NeedsAuthorization
  -> syncTools 全量拉取工具、按名字合并、写回 SettingsStore
  -> 两段都成功后暴露为 McpStatus.Connected；调用工具时 callTool 带 120 秒超时
```

判定是两段式：`connectSession` 先 connect 传输再 `syncTools`，只有连接参数在同步前后一致才把客户端与配置标记为已连接，否则关闭重连（`McpSessionRegistry.kt:241-255`）。断线由传输层 `onClose`/`onError` 触发有界重连，最多 5 次，退避自 1 秒指数增长、封顶 30 秒（同文件 `45-47`、`347-409`）。

### 主链 B：workspace 创建、rootfs 安装与 shell 执行

```text
创建 workspace -> WorkspaceRepository.create 生成 Uuid 作为 id 与 root，建 files/linux/tmp
  -> 用户填入 rootfs 归档 URL（默认 Ubuntu Base 24.04 arm64）并安装
  -> RootfsInstaller 下载并解包到 staging，替换 linux 目录后由 RootfsPatcher 打补丁
  -> shell 状态 READY 后，绑定该 workspace 的助手才获得 workspace_* 工具
  -> 模型调用 workspace_shell/read/write/edit -> ProotShellRunner 组装 proot 命令行启动子进程
  -> readResult 采集 stdout/stderr、按超时强杀、超限截断后作为工具结果回传
```

安装先把归档解压到临时 staging，成功后再整体替换目标 rootfs，避免半成品覆盖可用环境；下载与解包都检测线程中断以响应协程取消（`workspace/src/main/java/me/rerere/workspace/RootfsInstaller.kt:19-47, 266-272`）。解包路径经规范化与 canonical 校验，拒绝 `..` 与逃逸符号链接（同文件 `319-345, 180-194`）。

### 主链 C：内嵌 Web 服务器的启动与外部驱动

```text
开启 Web 服务器 -> 启动 WebServerService 前台服务
  -> WebServerManager.start 选择绑定地址（0.0.0.0 或 127.0.0.1）并做端口可用性检查
  -> startWebServer(port, host) { configureWebApi(...) } 启动 Ktor CIO
  -> 非 localhost-only 时注册 mDNS 并回填 hostname/address
  -> 浏览器取 web-ui 静态资源 -> 凭访问口令换取 JWT（若启用）
  -> 前端经 /api/conversations* 读写同一会话，/api/events 收 SSE
  -> 工具审批、停止生成经 REST 回到同一 ChatService
```

Web 服务器是应用进程内的同一服务实例，`configureWebApi` 直接注入 `ChatService`、会话与文件夹仓库、设置存储和文件管理器，因此端上与 Web 端共享同一份内存状态与同一个数据库（`WebApiModule.kt:61-68, 140-188`）。

## 身份、协议与状态映射

### MCP 侧

服务器的本地身份是配置项里的 Uuid，用户可见身份是配置名，同时用作 MCP 客户端实现名与工具命名空间前缀；服务器名只允许字母数字（白名单），工具注册名由它拼成 `mcp__…__…`，构造与启用过滤见文末交接（`data/ai/tools/ChatToolFactory.kt:76-94`）。传输方式只有 `sse` 与 `streamable_http`，配置模型是密封类，从 MCP JSON 导入时也只解析 URL、type 与 headers（`data/ai/mcp/McpConfig.kt:62-95`；`ui/pages/setting/SettingMcpPage.kt:1017-1033`），未发现 stdio 或本地进程传输。

工具的持久身份是工具名，重新同步时描述与输入 Schema 被服务器返回值覆盖，用户设置的启用开关与审批标志保留（`McpSessionRegistry.kt:499-512`）。是否触发重连只取决于传输类型、服务器 URL、客户端名与 headers 组成的连接键，工具开关变化不会重连（同文件 `465-497`）。OAuth 状态（动态注册结果、端点与令牌、过期时间）随服务器配置持久化，而连接客户端只在内存注册表里，重启后由配置流重新协调建立（`McpConfig.kt:23-51`）。

### workspace 侧

持久身份是 Room 表 `workspaces` 的 id 与唯一 root 字段，另有名称、shell 状态、工具审批覆盖表和 shell 兼容模式等列（`data/db/entity/WorkspaceEntity.kt:11-41`）。助手通过自身的 `workspaceId` 绑定 workspace（`data/model/Assistant.kt:43`），会话级另有 `workspaceCwd` 作为默认工作目录。shell 状态是四态枚举（禁用、安装中、已就绪、损坏，`workspace/src/main/java/me/rerere/workspace/Workspace.kt:13-18`）。启动时做完整性检查：目录缺失只标记损坏而不删记录，声明就绪或安装中但找不到 rootfs 则回退为禁用（`data/repository/WorkspaceRepository.kt:34-55`）；删除 workspace 会清理目录并清空指向它的助手绑定（同文件 `308-330`）。

### Web 侧

外部客户端身份只到"一次 JWT"一层：令牌主题固定为 `web-access`，由访问口令经 HMAC-SHA256 派生密钥签名，有效期 30 天，前端存放在 localStorage 并在请求头或查询串中携带（`WebApiModule.kt:43-48, 191-222`；`web-ui/app/services/api.ts:28-144`）。没有账号模型，所有通过鉴权的客户端共享同一份助手与会话数据。

## 执行、回流与控制语义

### MCP 的执行与回流

工具执行严格是请求-响应：`callTool` 带 120 秒超时，会话在连接期内复用，重连成功后工具目录按新代际合并；连续失败达上限时注销客户端并把状态置为错误（`McpSessionRegistry.kt:362-370`）。结果内容到消息片段的转换属于工具执行面的回注逻辑，本笔记不展开。

### workspace 的执行与回流

shell 工具把命令交给 `WorkspaceRepository.executeCommand`，后者用 `runInterruptible` 包装，使协程取消转成线程中断并杀死阻塞中的子进程（`WorkspaceRepository.kt:290-306`）。`ProotShellRunner` 把根目录指向该 workspace 的 linux 目录，工作目录固定在 `/workspace` 或 `/workspace/<cwd>`，再按挂载表把文件区、技能、工具输出与上传目录绑进沙箱（`ProotShellRunner.kt:64-117`）。命令经位置参数传入，最后在 rootfs 内以固定环境变量的非交互 bash 求值一次，环境里关闭颜色、分页与交互提示（同文件 `95-115`）。

输出回流是结构化的：退出码、标准输出、标准错误、是否超时与是否截断一并写入工具结果，单流超过 128KB 后继续读到 EOF 但丢弃多余内容，避免管道写满阻塞子进程（`workspace/src/main/java/me/rerere/workspace/WorkspaceShellRunner.kt:40-79, 102-143`）。默认超时 30 秒，工具允许模型指定最长 600 秒（`WorkspaceManager.kt:249`；`data/ai/tools/WorkspaceTools.kt:23, 253-256`）。workspace 另有面向人的交互终端：详情页用 Termux 组件在同一 PRoot 参数下建持久 PTY 会话，与模型工具共享 rootfs 与文件区，但不经 Web 暴露（`ui/pages/extensions/workspace/WorkspaceTerminalSession.kt:23-91`）。

### Web 的执行与控制

Web 端能发送与编辑消息、重生成、切换分支、设标题、移动/分叉/删除会话、停止生成，以及提交工具审批结果（`web/routes/ConversationRoutes.kt:270-363`）。会话流以 SSE 推送新消息节点的增量或全量快照并附生成中标志，连接期间为会话增引用、断开时释放（同文件 `365-449`）。全局事件流 `/api/events` 复用单条 SSE 连接，按事件名区分设置快照、会话列表失效与文件夹列表（`web/routes/EventsRoutes.kt:21-109`）。

## 权限、凭据与治理边界

**MCP 凭据**。OAuth 的发现顺序是：先按 401 响应的 `WWW-Authenticate` 头定位受保护资源元数据，失败则退回 RFC 9728 的 well-known 路径；授权服务器元数据再按 RFC 8414 与 OIDC Discovery 查找（`data/ai/mcp/McpOAuthDiscoveryClient.kt:49-122`）。授权用 PKCE 与随机 state，回调走绑在 IPv4 回环地址的临时服务器，端口与路径固定为 52134，随首个会话打开启动、末个会话关闭停止，并按 state 路由回调（`data/ai/mcp/McpOAuthCoordinator.kt:24-28, 135-245`；`oauth/src/main/java/me/rerere/oauth/OAuthLoopbackCallbackServer.kt:33-114, 139-188`）。

本地无可复用 client_id 且服务器支持动态注册时先注册客户端，授权页经 Custom Tabs 打开（`oauth/src/main/java/me/rerere/oauth/OAuthAuthorizationLauncher.kt:13-20`）。令牌在临近过期 60 秒内按 serverId 串行刷新，失败则沿用旧配置而不中断（`McpOAuthCoordinator.kt:83-121`）。令牌与客户端密钥随设置持久化；`McpOAuthState` 的 `toString` 已脱敏，但存储未加密（`McpConfig.kt:39-51`）。

**MCP 请求头**。用户 headers 原样附加；OAuth 已启用且已有访问令牌、用户又未自备 Authorization 头时注入 `Authorization: Bearer <token>`（`McpSessionRegistry.kt:446-497`），所以凭据作用域是"每台服务器一份"，不代表个人、Agent 或团队身份。

**MCP 动作审批**。MCP 工具的审批需求随工具配置持久化，并成为宿主工具的审批标志（`McpConfig.kt:53-60`）；待审状态的生成、批准或拒绝后的结果回注属宿主通用工具机制，见文末交接。Web 端审批入口同样经 REST 回到同一个 `ChatService.handleToolApproval`。

**workspace 边界**。这是用户态 PRoot 沙箱，不提供内核级隔离：PRoot 在宿主用户权限下重映射路径与 root 身份，`--root-id` 让 rootfs 内进程看到 root，`--link2symlink` 兼容不支持符号链接的场景，`--kill-on-exit` 保证退出时回收子进程（`ProotShellRunner.kt:68-79`）。

文件区是应用私有的 `filesDir/workspaces/<root>/files`，Linux 区与临时区是同 workspace 下的 `linux`、`tmp`。跨目录访问由路径解析统一处理：`/workspace` 映射文件区，挂载表路径映射各自源目录，`/dev`、`/proc`、`/sys` 被明确拒绝为可读文件并要求改用 shell（`WorkspaceManager.kt:121-146, 255`）。

越界写另有产品边界：写文件与编辑文件默认免强制审批，目标路径落在 `/workspace`、`/tmp`、`/skills` 之外时强制转审批，并可按 workspace 覆盖落库（`WorkspaceTools.kt:26-34, 126, 169, 407-420`；`WorkspaceRepository.kt:104-114`）。

断网或 rootfs 缺失时 shell 工具直接失败，shell 非就绪时 workspace 工具集根本不注入（`ChatToolFactory.kt:97-108`）。

**Web 边界**。JWT 鉴权开启时，除令牌换取接口外的 `/api` 路由全部要求 Bearer 令牌，校验动态读取当前访问口令，改口令后旧令牌立即失效；未开启则所有 API 与静态资源都不要求鉴权（`WebApiModule.kt:90-138, 170-186`）。

服务器默认绑定全部接口并注册 mDNS 广播，只有显式选择仅本机模式才绑回环地址（`WebServerManager.kt:24-25, 63-101`）。`/api/events` 推送的设置快照是完整的 Settings 序列化结果，含 Web 访问口令字段，该字段的可见范围就是 SSE 的鉴权范围（`web/routes/EventsRoutes.kt:45-47`；`data/datastore/PreferencesStore.kt:561-565`）。Web 端也能触发文件类接口与会话操作，权限等价于本机已登录用户。

## 相邻类目交接

- **Agent 工具执行面**：MCP 与 workspace 工具的数据契约、命名与注册顺序、按启用状态过滤、Schema 注入、审批状态机与结果回注、输出超 32KB 的截断与落盘，均见 [RikkaHub Agent工具调查笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)；本笔记只在执行位置与外部边界意义上引用。
- **上下文编译与提示词工程**：workspace 相关的系统提示注入（工作区说明、`AGENTS.md`、`/upload` 只读声明）见 [RikkaHub 上下文编译与提示词工程调查笔记](../上下文编译与提示词工程/RikkaHub-上下文编译与提示词工程调查笔记.md)。
- **生成式输出与运行时**：预览 WebView 运行环境与 web-ui 控制台的托管方式见 [RikkaHub 生成式输出与运行时调查笔记](../生成式输出与运行时/RikkaHub-生成式输出与运行时调查笔记.md)。
- **主动 Agent 与后台任务**：Web API 作为从会话之外发起生成的触发来源、Web 服务器前台服务的保活与通知见 [RikkaHub 主动Agent与后台任务调查笔记](../主动Agent与后台任务/RikkaHub-主动Agent与后台任务调查笔记.md)。
- **会话与消息管理**：Web 端与端上复用的会话、消息、设置仓库及其持久化契约见 [RikkaHub 会话与消息管理调查笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

## 已确认边界与未验证事项

已确认边界：

- MCP 工具是否进入本轮工具表，由服务器启用、助手的服务器集合与工具自身开关共同决定，过滤规则见 Agent 工具笔记（`McpManager.kt:106-116`）。
- workspace 工具只在助手绑定 workspace 且 shell 就绪时注入，系统提示中的工作区引导与 `AGENTS.md` 注入共用同一条件（`ChatToolFactory.kt:97-108`；`WorkspaceReminderTransformer.kt:28-34`）。
- Web 服务器由前台服务保活，启动前检查通知权限，非仅本机模式在目标 SDK 上还需本地网络权限，任一缺失即跳过启动（`RikkaHubApp.kt:174-210`；`service/WebServerService.kt:45-114`）。rootfs 安装的下载 URL 与工具审批开关由用户在 workspace 详情页设置，rootfs 内容不随应用分发。

未验证事项：

- 未在设备上运行 MCP 连接、工具同步、断线重连与真实 OAuth 授权：`onError`/`onClose` 的触发顺序、SSE 流放弃判定、退避重连、动态注册复用条件、令牌刷新并发与厂商 ROM 依赖均属运行期观察项。
- 未运行 PRoot：`--link2symlink`、`PROOT_NO_SECCOMP` 兼容模式、x86_64 与 arm64 差异、子进程树在超时或取消时是否完全回收均需目标环境验证。
- 未验证 Web 端口可用性检查、mDNS 注册与 `hostname.local` 解析、SSE 在移动网络切换下的重连表现，以及 MCP 工具审批在 Web 端与本机端并发提交时的状态收敛。

## 关键源码索引

- `app/src/main/java/me/rerere/rikkahub/data/ai/mcp/`：`McpManager.kt`、`McpSessionRegistry.kt`、`McpConfig.kt`、`McpOAuthCoordinator.kt`、`McpOAuthDiscoveryClient.kt`
- `oauth/src/main/java/me/rerere/oauth/`：`OAuthLoopbackCallbackServer.kt`、`OAuthHttpClient.kt`、`OAuthAuthorizationLauncher.kt`
- `workspace/src/main/java/me/rerere/workspace/`：`WorkspaceManager.kt`、`ProotShellRunner.kt`、`WorkspaceShellRunner.kt`、`RootfsInstaller.kt`、`RootfsPatcher.kt`、`Workspace.kt`
- `app/src/main/java/me/rerere/rikkahub/`：`data/repository/WorkspaceRepository.kt`、`data/db/entity/WorkspaceEntity.kt`、`data/model/Assistant.kt`、`di/RepositoryModule.kt`、`data/ai/tools/{ChatToolFactory,WorkspaceTools,SkillsTools}.kt`
- `app/src/main/java/me/rerere/rikkahub/`：`web/{WebServerManager,WebApiModule}.kt`、`web/routes/{ConversationRoutes,EventsRoutes,SettingsRoutes}.kt`、`ui/pages/extensions/workspace/WorkspaceTerminalSession.kt`、`service/WebServerService.kt`、`RikkaHubApp.kt`
- `web/src/main/java/me/rerere/rikkahub/web/Entry.kt`、`web-ui/app/services/api.ts`、`docs/references/chat-generation-pipeline.md`
