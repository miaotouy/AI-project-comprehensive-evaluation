# VCPChat 独特功能调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`b6ffa22f15bd0fd2499f4513a992f6bdff1de731`（分支：`main`）
>
> 调查方式：汇总现有十类单项目笔记，对十六项候选逐一走读源码主链（入口 → 状态/对象 → 执行 → 用户结果 → 持久化），核对模块注册（`main.html`、`main.js`、IPC handlers、`VCPDistributedServer` 插件目录）与近期 Git 历史；未运行应用、未发起真实模型请求，全部结论为静态分析
>
> 调查范围：待查清单中 VCPChat 的全部候选能力；去重边界以现有类目笔记为准（群聊发言模式、Canvas、日记渲染、桌面挂件渲染等已有笔记覆盖的部分只补交点）。排除：音频引擎、主题系统、论坛、骰子等未列入候选的模块
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 是待查清单中独特功能密度最高的项目之一：十六项候选中有十二项达到 `主链确认`（其中三项来自既有笔记，本轮补齐运行恢复、资源治理与 HEAD 变化），两项为 `入口确认`，两项存在与 README 声明不符或依赖外部仓库的部分。项目的产品辨识度集中在一个事实上：**VCPChat 不只是聊天客户端，而是围绕 VCP 后端协议（VCPToolBox 提供服务）建立的"AI 原生桌面运行时"**——聊天、桌面挂件、记忆工作台、人类工具面、移动同步和插件系统共享同一套 `AppData/` 文件事实源，由前端私有标记协议与后端工具链驱动。

已确认的独特能力族（均为主链确认，静态证据）：

1. **高级回复（VCPChatTarven）三类注入系统**：类 SillyTavern 的规则注入，规则存 `AppData/VCPChatTarven.json`，注入覆盖单聊与群聊全部发言路径，用户消息尾部注入不写入历史。
2. **Memo 神经云图与日记工作台**：日记文件由后端 `admin_api/dailynotes` 管理，前端提供文件夹分类、语义联想云图、批量编辑、多日记引用工作台与 Agent 代笔（经 `/v1/human/tool` 调 DailyNote 工具）。
3. **VCPDesktop 流式推送与持久挂件**：`<<<[DESKTOP_PUSH]>>>` 流式拦截创建挂件，收藏后按目录持久化于 `AppData/DesktopWidgets/`，带性能打点、可见性冻结与定时器/监听器清理等资源治理。
4. **FlowLock 主动连续工作**：模型在最终回复中输出 `[[Flowlock::...]]` 控制协议，由前端状态机驱动后台心跳续写，支持多 Agent 并发 Session、跨 Topic 原子交接与 TopicSponsor 请求认领。
5. **VCP 人类工具箱（人类工具面）**：独立 Electron 应用把 VCP 插件 manifest 自动转译为表单化 GUI，执行经主进程代理到 `/v1/human/tool`；插件管理面板支持从后端导入并自动解析参数 schema。
6. **工作流编辑器**：jsPlumb 节点画布 + 分层拓扑执行引擎，插件节点按 `<<<[TOOL_REQUEST]>>>` 实际调用后端；仓库自带 README 声称"执行管线为空壳"，与当前代码不一致，以代码为准（未运行验证）。
7. **ComfyGen 专用配置面板**：HumanToolBox 内嵌 ComfyUI 配置抽屉，管理连接、工作流模板（导入/转换/校验）、模型与 LoRA 参数，写回后端插件配置。
8. **Agent 正则系统**：`stripRegexes` 规则模型带作用域（渲染/上下文）、角色、min/max 深度，GUI 编辑并兼容导入 SillyTavern 正则脚本。
9. **跨聊天消息转发与转发附言**：右键转发 → 目标选择（Agent/群组）→ 带来源标识与可选评论构造新消息 → 走标准发送链，附件一并携带。
10. **前端插件机制与 LoomAPP 运行时**：`manifest.frontend` 声明插件样式/脚本，主进程扫描后注入主窗口；现有 VChatDynamicWallpaper、VChatAutoTTS 两个渲染器插件；Loom 是 Agent 可创建、管理、注入代码的隔离 WebApp 运行时。
11. **VCPMobileSync 跨端双向增量同步**：三阶段协议（Reconcile → Double-Hash Merkle Diff → NDJSON 流式），冲突按最新时间戳胜出，墓碑拦截防回流；中央索引模式由 `vcp_chat_data_service`（VCP-CDS）承接。
12. **Agent 自主管理 Topic（TopicSponsor）**：分布式插件直接读写 `AppData/Agents|UserData` 创建话题、回复话题、检查所有权/未读，与 FlowLock 的 `CreateFlowlockTopic` 交接构成闭环。

声明不符或依赖外部仓库的项：README 声称的"群文件/共享工作区/协同编辑"在本仓库未找到对应实现；"ST 预设、角色卡、世界书"在 VCPChat 前端无导入与管理入口（后端 VCPToolBox 才有）；"跨模态智能转译/全 URL 超栈追踪"的主服务器逻辑在 VCPToolBox，本仓库只确认节点侧 `internal_request_file` 拉取链；"跨端记忆"的中心记忆库同样位于后端。

## 介绍声明与候选盘点

根 `README.md` 功能声明密度极高，且多数在近期更新段有明确入口。逐项核对后的状态如下（详细证据见对应能力卡）：

| 候选能力 | 状态 | 关键入口 | 特色统计建议 |
|---|---|---|---|
| 高级回复 / VCPChatTarven 三类注入 | `主链确认` | 发送按钮右键浮窗 + 规则管理模态 | 主贡献（上下文注入族） |
| Memo 神经云图与日记工作台 | `主链确认` | 头部按钮右键打开 Memo 窗口 | 主贡献（记忆工作台族） |
| VCPDesktop 流式推送与持久挂件 | `主链确认`（既有，已补） | `--desktop-only` 启动 + DESKTOP_PUSH 协议 | 主贡献（活对象族，已有） |
| FlowLock 主动连续工作 | `主链确认`（既有，已补） | 标题右键/中键/Ctrl+G + 内嵌协议 | 主贡献（主动 Agent 族，已有） |
| VCP 人类工具箱与自动 GUI 工作流 | `主链确认`（工具面）/ `主链确认`（工作流编辑器，静态） | 主窗口工具箱按钮启动独立应用 | 主贡献（人类工具面族） |
| ComfyGen 专用创作面板 | `主链确认`（配置管理链） | 工具卡 ⚙ 按钮 → 配置抽屉 | 随人类工具箱族合并计数 |
| VCP 日记渲染和认知可见性 | `归并已有类目`（渲染）+ Memo 卡承接对象侧 | DailyNote 协议块 + Memo 窗口 | 渲染部分不重复计数 |
| Agent 自主管理 Topic（TopicSponsor） | `主链确认` | TopicSponsor 插件 + flowlock 认领 IPC | 主贡献（主动 Agent 族） |
| ST 预设、角色卡、世界书与可视化注入 | `声明不符`（前端） | 仅 ST 正则导入可用 | 不计入 |
| Agent 群聊三种发言模式 | `归并已有类目` | `Groupmodules/modes/` 策略注册表 | 不重复计数 |
| 群文件、共享工作区与 Canvas 协作 | `声明不符`（群文件/工作区）/ `归并已有类目`（Canvas） | 无群文件代码；Canvas 见运行时笔记 | 不计入（群文件），Canvas 不重复计数 |
| 跨端记忆与 VCPMobileSync | `主链确认`（同步）；记忆本体在外部 | VCPMobileSync 插件 + VCP-CDS | 主贡献（跨端族）；"记忆"部分暂缓 |
| Agent 正则系统 | `主链确认` | Agent 设置正则编辑器 + `stripRegexes` | 主贡献（上下文 DSL 族） |
| 跨聊天消息转发与气泡评论 | `主链确认` | 消息右键 → 转发模态 | 辅助贡献（Chat 工作流） |
| 分布式多模态文件追踪与能力转译 | `入口确认`（节点侧）；追踪与转译在外部 | `internal_request_file` | 暂缓计入 |
| 动态壁纸、自动 TTS、Loom 等前端插件 | `主链确认`（机制与 Loom）；`入口确认`（两个渲染器插件本体） | `frontend-plugin-loader.js` + manifest.frontend | Loom 独立主贡献；插件机制辅助 |

## 已确认的独特能力

### 能力卡 1：高级回复（VCPChatTarven）三类注入系统

- **用户目标**：在不修改 Agent 配置与聊天历史的前提下，对每次 AI 请求做按需、可开关的提示词干预；这是普通 Chat 与通用 Agent 底座没有的"请求级临时设定"层。
- **入口与触发者**：用户右键发送按钮弹出「高级回复」浮窗（逐条开关），浮窗齿轮进入「规则管理」模态（新建/编辑/删除/拖拽排序）。渲染端 `Tavernmodules/tavern-manager.js:96-255`（浮窗）、`:258-596`（管理模态）。
- **事实对象**：规则实体 `{id, name, type, enabled, content, scope, wrap, role?, depth?}`，持久化在 `AppData/VCPChatTarven.json`（`modules/ipc/tavernHandlers.js:88`，读写经 `tavern:get-rules`/`tavern:save-rules`，`:95-112`），主进程带 mtime 缓存。
- **完整主链**：右键发送按钮 → 开关/编辑规则 → 主进程写 JSON → 发送时 `getActiveRulesForScope`（`tavern-manager.js:602-608`）取生效规则 → 引擎按类型注入 → VCP 提交。三种注入由纯逻辑引擎 `modules/tavernRulesEngine.js` 实现：
  - `system_suffix`：系统提示词尾部追加（`applySystemSuffix`，`:78-89`）；
  - `user_suffix`：仅追加到本轮提交给 AI 的用户文本副本，**不写入历史**（`applyUserSuffix`，`:99-110`）；
  - `context_inject`：以独立 user/assistant 消息按 `depth` 插入上下文（`applyContextInject`，`:123-149`，`depth=0` 为末尾、`depth=N` 为倒数第 N+1 条之前，从大到小排序避免索引错位）。
  - 包裹标记 `[本信息由VCPChat客户端注入]…[临时注入结束]`（`:27-28`），每条规则可关闭（裸注入）。
- **作用范围（scope）**：`global / agent / group` 三档（`isRuleActive`，`:56-61`）。单聊应用点：`modules/chatManager.js:1124`（user suffix）、`:1311/:1316`（system suffix）、`:1327`（context inject）；重试/编辑路径 `modules/renderer/messageContextMenu.js:788/:934/:950`。群聊应用点：`Groupmodules/groupchat.js:518`（user suffix 只改提交副本，历史落 `originalUserText`，`:531`）、`:607`（system suffix）、`:736`（context inject），邀约发言路径同样应用（`:1189/:1308`）——"群聊不丢注入"的声明成立。
- **持续性**：规则 JSON 文件重启后恢复；开关即时生效（mtime 缓存失效）。
- **人机关系**：用户可在浮窗逐条开关，管理模态全量 CRUD；无 Agent 侧写入入口。
- **外部依赖**：纯前端 + 主进程文件，无后端依赖。
- **独特性判断**：与 SillyTavern 的注入位相比，它是客户端自管理、单聊/群聊统一适配的 VCP 原生实现；与 AIO Hub 的消息配方相比，它刻意保持"轻量、不污染历史"的临时设定定位。归入"上下文注入/DSL"聚类。
- **证据强度**：源码事实（引擎、应用点、持久化全部走通）；开关热加载与实际请求行为未运行验证。

### 能力卡 2：Memo 神经云图与日记工作台

- **用户目标**：把 AI 自动记录与整理的日记/记忆库从"文件目录"升级为"可视化记忆拓扑 + 批量整理 + 整合代笔"的工作台；这是普通聊天客户端没有的长期记忆管理面。
- **入口与触发者**：主窗口头部按钮右键打开 Memo 窗口（`main.html:690`，`modules/ipc/windowHandlers.js:342` 加载 `Memomodules/memo.html`）；VCPDesktop 桌面图标 `vchat-app-memo` 亦可进入（`Desktopmodules/桌面图标与启动API指南.md:33`）。
- **事实对象**：后端 `admin_api/dailynotes/*` 管理的日记文件（文件夹/思维簇分类）；前端不落盘，全部经带 Basic Auth 的 REST 调用（`Memomodules/memo.js:501-520`；`loadFolders` `:524`、`loadMemos` `:700`、保存 `:941`、批量删除/移动 `:1354-1412`）。
- **完整主链**：
  - 云图：日记卡 → "关联" → 选文件夹与 k/boost 参数 → `POST /associative-discovery`（`memo-graph.js:71-155`）→ 后端返回联想节点 → 前端 Canvas 力导向图渲染（斥力/引力、连线分数、节点卡、多选、缩放平移，`:157-567`）→ 节点详情可加载全文并批量加入工作台（`:611-692`）。
  - 工作台：选中多篇日记 → `DiaryWorkbench`（`memo-workbench.js:18-97`）→ 引用卡片/完整阅读（`:285-332`）→ 新建整合日记 → 构造 `<<<[TOOL_REQUEST]>>> tool_name:DailyNote, command:create` 经 `/v1/human/tool` 发布（`:158-234`）→ 发布后可对旧日记归档（`/move` 到「已整理」，`:266-282`）或批量删除（`:335-348`）。
  - Agent 代笔与语义搜索：`memo.js:1060/:1160` 同样调用 `/v1/human/tool`（LightMemo/语义检索），结果经 `processSemanticSearchResults` 归一化为可打开路径（`:1197-1320`）。
- **持续性**：全部日记由后端持有；前端仅持久化 UI 偏好（隐藏文件夹/排序，`saveMemoConfig` `:1428`）。
- **人机关系**：用户主导整理（批量编辑、移动、归档）；Agent 通过工具代笔与语义检索参与；"模型回流"指模型经 DailyNote 工具写日记、经 Memo 窗口再被阅读与检索。
- **外部依赖**：后端 `admin_api/dailynotes` 与 `v1/human/tool` 属于 VCPToolBox（本仓库只确认请求格式与调用点）；云图算法（对称性破缺有序能索引）完全在后端，前端无法验证其语义。
- **独特性判断**：日记文件本身是后端生态的持久对象，但"联想云图 + 工作台 + 批量编辑"的组合只在 VCP 系出现；与 VCPToolBox 的 TagMemo/RiverMemo 是同一记忆体系的消费/管理两端。
- **证据强度**：源码事实（入口、API 链、图渲染、批量操作全部走通）；后端算法、云图实际渲染与 Agent 代笔结果未运行验证。

### 能力卡 3：VCPDesktop 流式推送与持久挂件

既有 `Agent工具` 与 `生成式输出与运行时` 笔记已确认 `<<<[DESKTOP_PUSH]>>>` 流式拦截（`modules/renderer/streamManager.js:1906` `processDesktopPushToken`）、挂件收藏目录 `AppData/DesktopWidgets/<id>/`（`modules/ipc/desktopHandlers.js:999-1095`）与模型侧远程控制（`desktopRemoteHandlers.js`）。本轮补充：

- **运行恢复**：收藏 = 截图 + HTML 落盘（`Desktopmodules/favorites/favoritesManager.js:21-73`）；恢复 = `desktopLoadWidget` 读文件 → `widget.create` 重建 → 延迟执行内联脚本（`:108-139`），运行状态不持久，重启后脚本重新执行。收藏列表经 `desktop-list-widgets` 从目录扫描（`desktopHandlers.js:1228-1271`），并自动维护 `CATALOG.md` 索引（`:212-295`）。
- **资源治理**：挂件沙箱跟踪自身 `_intervals/_timeouts/_windowListeners/_docListeners` 以便销毁清理（`Desktopmodules/core/widgetManager.js:460-538`）；`performanceManager` 按周期打点 JS 执行时长与帧数，估算每挂件 CPU%/FPS（`core/performanceManager.js:41-143`）；`visibilityFreezer` 冻结不可见区域的壁纸 iframe/视频动画（`core/visibilityFreezer.js:237`）；另有 zIndex 管理与删除 fallback。
- **当前 HEAD 变化**：近期提交中 `Desktopmodules` 仅两次变更（`0f8aa6d` Loom 工程落地、`3f14e93` fix），未发现挂件主链的结构性改动；新增变化集中在 `VCPDistributedServer`（动态壁纸/自动 TTS 插件 `649e9af`、LoomController `3e3c6b9`、VCP-CDS 数据库重构 `d00c10b`），见能力卡 10 与 11。
- **证据强度**：恢复与资源治理为源码事实；真实桌面渲染、动画冻结效果与性能数据未运行验证。

### 能力卡 4：FlowLock 主动连续工作

既有 `Agent工具` 笔记已确认状态机、心跳、重试与完整请求重建。本轮补充（协议文档 `Flowlockmodules/README.md` 与代码一致）：

- **用户可见状态**：Agent 侧栏头像活动状态环、当前标题发光/悦动、心跳脉冲动画（`Flowlockmodules/flowlock.css`）；消息内渲染 Start/Stop/Complete/Fail/NextHeartbeat/NextPrompt 状态气泡（`flowlock-protocol.js:326-330`，`data-vcp-block-type="flowlock"`）。
- **用户操作**：右键聊天标题 = 启动（不立即续写）/停止；中键 = 启动并立即续写/停止；`Ctrl+G`（macOS `Command+G`）同中键（`flowlock-integration.js:272-367`）。
- **跨 Topic 接管**：`CreateFlowlockTopic` 由 TopicSponsor 插件创建带 `flowlockRequest`（UUID 请求 ID、pending 状态）的话题，前端在最终回复完整落盘后经 `claimPendingFlowlockTopic` 原子认领并交接 Session（`flowlock.js:163-260`；IPC `preloads/chat.js:265-267`），失败时补偿恢复为 pending；页面重载后枚举恢复，冲突保持 pending。
- **取消与资源上限**：Stop/Complete/Fail 取消定时器并增加 generation 防复活（README 5 节）；心跳延迟钳制在 1–86400 秒（`topicsponsor.js:151-158`）；续写失败默认最多重试三次后自动停止（README 7.4）；协议解析屏蔽工具请求/结果、Desktop Push、元思考链、think 块与代码围栏（README 6.1）；历史渲染只出状态气泡不重放命令（6.2）。
- **证据强度**：协议、状态机与交互绑定为源码事实；后台心跳续写与跨 Topic 交接的完整运行未验证（README 称单元测试通过，本仓库 `tests/` 中未见 Flowlock 测试文件）。

### 能力卡 5：VCP 人类工具箱（人类工具面）与插件 manifest → 表单转译

- **用户目标**：把 AI 才能用的 VCP 工具以表单化 GUI 开放给人类，无需手写 `<<<[TOOL_REQUEST]>>>`；普通客户端没有"把 Agent 工具面投影为人类可操作面板"的能力。
- **入口与触发者**：主窗口「工具箱」按钮经 `launchStandaloneElectronApp('VCPHumanToolBox', 'Human Toolbox')` 启动独立 Electron 应用（`modules/ipc/desktopHandlers.js:1376`）；VCPDesktop 图标 `vchat-app-toolbox` 亦可进入。独立应用自身 `VCPHumanToolBox/main.js:238-295` 注册 `vcp-ht-execute-tool-proxy` 代理。
- **事实对象**：工具定义库 `renderer_modules/config.js`（46 个出厂工具，7 种参数 widget 类型）+ 用户导入工具 `settings.vcpht_userTools`（Config Overlay 优先于出厂定义）。
- **完整主链**：工具网格 → `buildToolForm()` 按 params schema 生成表单 → 用户填参执行 → `vcp-ht-execute-tool-proxy` → 主进程拼装 `<<<[TOOL_REQUEST]>>>` → `POST /v1/human/tool`（Bearer Token）→ `renderResult()` 多模态渲染。插件导入链：管理 Tab → 连接后端 Admin API → `GET /admin_api/plugins`（`renderer_modules/tool-manager.js:79-103`）→ manifest 参数解析（`parseDescription` 支持四种格式、三层 fallback，`:220-310`；`invocationCommands` → config.js 格式适配，`:364-413`）→ 可视化表单/JSON 双编辑器 → `vcp-ht-save-settings` 持久化。
- **持续性**：用户工具随 `AppData/settings.json` 持久化；Admin 连接配置存 localStorage。
- **安全边界**：`contextIsolation + nodeIntegration:false`、preload 白名单 12 个 IPC 通道、路径校验（`getPluginManagerPluginDir`，`desktopHandlers.js:67-78`）。
- **外部依赖**：执行由 VCPDistributedServer/后端负责；应用自身 README 明确"不是权限管理系统"。
- **证据强度**：源码事实；表单实际交互与真实工具执行未运行验证。

### 能力卡 6：工作流编辑器（节点编排与执行引擎）

- **用户目标**：把多个 VCP 工具调用编排为可保存、可复用、可逐步执行的节点工作流。
- **入口与触发者**：HumanToolBox 顶部「工作流」按钮 → `openWorkflowEditor`（`renderer.js:1678-1722`）→ `WorkflowEditorLoader_Simplified` 动态加载模块（模块本身已由 `index.html:52-67` 预加载）。
- **事实对象**：jsPlumb 节点画布上的节点（VCPChat 插件 / VCPToolBox 插件 / 辅助节点）与连接，状态由 `WorkflowEditor_StateManager` 管理（位置、配置、连接、拓扑分层）。
- **完整主链**：拖拽建节点连线 → 执行按钮（`WorkflowEditor_UIManager.js:80/:173/:2468-2522`）→ `ExecutionEngine.executeWorkflow`（`WorkflowEditor_ExecutionEngine.js:65-159`：环检测、预飞行检查、分层拓扑、同层并发 + maxConcurrency 限流、错误策略 stop/continue）→ 插件节点构造 `<<<[TOOL_REQUEST]>>>` 并 `fetch /v1/human/tool`（`:596-874`，含智能命令匹配）→ 结果归一化存 `nodeResults` 并传播到下游输入。辅助节点含数据转换、条件、延时、循环（loopStart/loopEnd）、正则、代码编辑、URL 渲染、内容输入、AI 拼接等（`:520-563` 分发）。
- **文档与实现不一致**：`VCPHumanToolBox/README.md` §8 声称"执行管线为空壳、不建议在生产中依赖"，但当前代码已实现完整执行链；按 AGENTS.md 约定以可执行路径为准，README 属陈旧说明。
- **持续性**：工作流保存/加载由 StateManager 承接（README §8 已实现列表）；本轮未核实落盘格式与位置。
- **证据强度**：入口、UI 绑定、执行引擎均为源码事实；未运行验证节点执行结果与保存/加载往返。

### 能力卡 7：ComfyGen 专用创作配置面板

- **用户目标**：为后端 ComfyUIGen 图像生成插件提供人类可用的参数与资产管理面板（工作流模板、LoRA、模型、提示词），与工具网格的"用户/Agent 共用参数面"形成闭环。
- **入口与触发者**：HumanToolBox 工具网格中 `ComfyUIGen` 卡片右上角 ⚙ 按钮 → `openComfyUISettings`（`renderer.js:1608-1650`）→ `ComfyUILoader` 动态加载 ComfyUI 模块族。
- **完整主链**：配置抽屉三 Tab（连接/生成参数/工作流管理，`ComfyUI_UIManager.js:157-305`）→ 测试连接（本地 ComfyUI，默认 `http://localhost:8188`）→ 保存配置经 `comfyui:save-config` 写回 `VCPToolBox/Plugin/ComfyUIGen/comfyui-settings.json`（`ComfyUImodules/README.md:48`，PathResolver 定位插件目录）；工作流支持导入 ComfyUI API 格式 JSON → 校验 → 转换保存（`import-and-convert-workflow`）；LoRA 需工作流含 `WeiLinComfyUIPromptToLoras` 节点才会自动注入（`ComfyUImodules/README.md:16-25`）。
- **外部依赖**：ComfyUI 本地服务与后端插件（VCPToolBox）；本仓库只实现配置管理链，生成执行仍经工具网格或 Agent 调用。
- **证据强度**：入口与 IPC 链为源码事实；连接测试、模板转换与参数注入行为未运行验证。

### 能力卡 8：Agent 正则系统（四类作用点）

- **用户目标**：对 Agent 的渲染文本与发送给模型的上下文做可分层、按深度与角色生效的正则改写；比通用"消息过滤"更接近 SillyTavern 的提示词工程层。
- **入口与触发者**：Agent 设置中的正则规则编辑模态（`main.html:1822-1884`：标题、查找/替换、作用域、角色、min/max 深度）；`import-regex-rules` 支持导入 SillyTavern 正则脚本（`modules/ipc/regexHandlers.js:36-55`，映射 `placement` 1=user/2=assistant、`markdownOnly`→前端、`promptOnly`→上下文、min/maxDepth）。
- **事实对象**：Agent 配置 `stripRegexes` 数组（`agentHandlers.js:58/:279-281` 单独读写 `regex_rules.json`，不入 config.json 主体）。
- **完整主链（四类作用点）**：
  - 上下文（历史内容）正则：发送时对每条历史消息按"轮次深度"映射逐条应用（`modules/chatManager.js:1091-1114`，`buildTurnDepthMap` `:54-81` 以轮次为单位算深度）；
  - 渲染器正则：`messageRenderer.js:849-866` `applyFrontendRegexRules`，应用点 `:2030/:3311/:3680/:3756`（渲染、更新、阅读等路径），按角色与深度过滤；
  - 深度正则：规则级 `minDepth/maxDepth` + 轮次深度图（`getActiveRegexRules` `chatManager.js:133-153`）；
  - content 数组：README 声称的"content 数组正则"本轮未定位到针对多模态 content 数组的专门实现，`applyFrontendRegexRules` 与上下文路径都只处理字符串——该项存疑，列入未验证。
- **持续性**：规则随 Agent 配置持久化（`regex_rules.json`）。
- **独特性判断**：与 AIO Hub、SillyTavern 的"正则分层"属同一聚类（上下文 DSL），但作用点命名（渲染/上下文/深度）与 ST 兼容导入是 VCP 系特色。
- **证据强度**：引擎与三类作用点为源码事实；content 数组维度未证实；运行效果未验证。

### 能力卡 9：跨聊天消息转发与转发附言（气泡评论）

- **用户目标**：把一条消息（含文本与附件）带来源标识与附言转发到另一个 Agent/群组话题，解决"信息跨上下文流动"。
- **入口与触发者**：消息右键「转发消息」（`modules/renderer/messageContextMenu.js:211-220`；中键快捷动作 `middleClickHandler.js:634-640`）。
- **完整主链**：`showForwardModal`（`renderer.js:2426-2470`：目标列表来自 `getAllItems`，含 Agent 与群组，可搜索）→ `handleConfirmForward`（`:2508-2564`）用 `getOriginalMessageContent` 取原始消息 → 构造 `> 转发自 **sender** 的消息:` + 原文 + 可选附加评论（`forwardAdditionalComment`）→ `chatManager.handleForwardMessage`（`modules/chatManager.js:1607-1651`）：切换到目标 → 填充输入框与附件（`localPath: att.src` + `_fileManagerData`）→ 走标准 `handleSendMessage` 触发完整 AI 响应。
- **持续性**：转发内容作为目标话题的普通消息落盘；评论只是消息文本一部分，无独立评论对象。
- **声明核对**：README 所述"右键消息气泡添加评论附加在原始消息下方"未找到独立实现——实际只有转发对话框内的"附加评论"字段；独立气泡评论本次未找到。
- **证据强度**：转发主链为源码事实；附件在目标端的历史重建与展示未运行验证。

### 能力卡 10：前端插件机制与 LoomAPP 运行时

- **插件注册与注入**：插件 manifest 的 `frontend: {style, script}` 字段声明渲染器插件（`VChatDynamicWallpaper`、`VChatAutoTTS` 的 `plugin-manifest.json` 均为 `pluginType: renderer`）；主进程 `listEnabledFrontendPlugins`（`modules/ipc/desktopHandlers.js:96-120`）扫描 `VCPDistributedServer/Plugin/*`，路径经 `resolveFrontendPluginResource` 白名单校验后返回相对 URL；`frontend-plugin-loader.js` 在 `DOMContentLoaded` 后把样式/脚本注入主窗口并派发 `vcp-frontend-plugins-loaded`。
- **两个现存插件（入口确认）**：VChatDynamicWallpaper（文件夹视频壁纸 + 紧凑播放控制）、VChatAutoTTS（自动朗读与代码块朗读开关），均为近期提交 `649e9af` 新增，插件本体行为未运行验证。
- **LoomAPP 运行时（主链确认）**：`modules/loom/VCPLoomManager.js`（1194 行）用 `WebContentsView` 托管"LoomAPP"（manifest 含 id/startUrl/窗口/视口/UA/注入 css+js，`inject.css`/`inject.js` 有 2MB 上限，`SAFE_APP_ID` 校验，`:15-25/:118-`）；用户面 `Loommodules/manager.html`（应用抽屉、导入/导出 `:166-168`）；Agent 侧 `LoomController` 插件提供 ListApps/CreateApp/OpenApp/CloseApp/GetAppSources/GetRuntimeSource/GetRenderedText/EditAppSources 共 9 个命令（`VCPDistributedServer/Plugin/LoomController/README.md:106-120`，EditAppSources 支持运行时热更新）。测试：`tests/loom-controller.test.js`。
- **证据强度**：注册、注入、Loom 命令分发均为源码事实；LoomAPP 实际运行与隔离边界未运行验证。

### 能力卡 11：VCPMobileSync 跨端双向增量同步

- **用户目标**：让 VCPChat 桌面端与 VCPMobile 手机端保持聊天数据（Agent/群组/话题/消息/头像）的物理双向同步；"跨端记忆"的 README 声明（中心记忆库实时同步）实际由后端承担，本插件同步范围不含记忆库。
- **入口与触发者**：桌面端全局设置开启「VCP 分布式服务器」后插件随 `VCPDistributedServer` 加载；手机端配置 HTTP（默认 5974）/WebSocket（默认 5975）与 Sync Token 握手。
- **事实对象**：`sync_state.db`（entity_index / message_index / attachment_index / avatar_index / message_attachments 五表，README §5）+ 中央索引模式下的 VCP-CDS SQLite/Tantivy。
- **完整主链（三阶段协议 V2）**：Phase 1 Reconcile 扫描 `Agents/AgentGroups/UserData` 建索引（`VCPMobileSync/index.js:313`）→ Phase 2 双哈希差分（configHash + Merkle contentHash，`sync/manifest.js:88-195` 同步清单；`sync/diff.js:114-197` 消息级 toPull/toPush/delete，Fast-Path 直接跳过）→ Phase 3 NDJSON 流式吞吐（`sync/message.js:29-191`：逐行消费、文件锁 `acquireLock`、临时文件 + rename 原子写、writeIntentLock 防 watcher 死循环）。冲突策略：双向增量合并，同一实体并发修改按最新时间戳胜出（README §1）；墓碑拦截 + 30 天清理防"幽灵数据回流"（README §6）。
- **中央索引模式**：`MobileSyncUseCentralIndex=True` 时 Manifest/Diff/Pull/Push/Tombstone/Change Feed 由 Rust 服务 `vcp_chat_data_service`（VCP-CDS）承接（`rust_chat_data_service/README.md:8-16`），身份模型 `(owner_type, owner_id, topic_id)`（`:110-120`）；测试 `tests/mobile-sync-central-adapter.test.js` 存在。旧 `sync_state.db` 链路可切换回退。
- **边界**：附件表存在但"实际上不能同步"（README §4 表格明确标注）；头像参与同步。
- **证据强度**：协议、表结构、原子写与中央适配为源码事实；真实手机端握手、大文件吞吐与冲突收敛未运行验证。

### 能力卡 12：Agent 自主管理 Topic（TopicSponsor）

- **用户目标**：让后台运行的 Agent 主动创建/发现/回复自己的聊天话题，实现"Agent 主动向用户发起聊天"的自主交互（README 自主话题管理）。
- **入口与触发者**：Agent 经 VCP 工具调用 `TopicSponsor` 插件（`VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`），命令分发 `:23-53`：CreateTopic / CreateFlowlockTopic / ReadUnlockedTopics / CheckNewTopics / CheckUnreadMessages / ReplyToTopic / CheckTopicOwnership / ListUnlockedTopics / ReadTopicContent。
- **事实对象**：直接读写 `AppData/Agents/<uuid>/config.json`（topics 数组）与 `AppData/UserData/<uuid>/topics/<topicId>/history.json`。
- **完整主链**：CreateTopic（`:344-447`）校验 Agent 存在 → 生成 `topic_<ts>_<uuid>` 话题目录与带 `_metadata.topicCreator` 的初始 assistant 消息 → topics 数组插入（`locked:false, unread:true, creatorSource:"plugin:TopicSponsor"`）→ 临时文件 + rename 原子写 config；ReplyToTopic（`:551-614`）在 locked 且已读话题上拒绝写入，追加带 `isPluginReply/originalSender` 元数据的消息；CheckTopicOwnership（`:616-655`）读 `_creator` 判定 `is_owner`。前端侧：Flowlock 认领链 `claimPendingFlowlockTopic/restoreFlowlockClaim/listPendingFlowlockTopics`（`preloads/chat.js:265-267`，主进程按 Agent 串行化、多候选拒绝、失败补偿恢复 pending，见能力卡 4）。普通话题的"前端实时刷新"（新话题出现在侧栏）机制本轮未单独核实——前端在会话切换/重载时重读 config，无 watcher 证据。
- **独特性判断**：与 FlowLock 同属"主动 Agent"聚类但事实对象不同（话题持久化 vs 运行时 Session）；跨 Agent 回复（一个 Agent 往另一 Agent 的话题追加消息）是仅 VCP 系出现的拓扑。
- **证据强度**：插件命令与认领 IPC 为源码事实；插件与前端 IPC 的真实对接运行未验证。

## 已归并到现有类目的能力

- **Agent 群聊三种发言模式（候选 10）**：`Groupmodules/modes/{sequentialMode,natureRandomMode,inviteOnlyMode}.js` 的策略注册表与完整判定逻辑已由[对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 8.1 节主链确认（sequential 全员轮发、naturerandom 的 @提及/tag 权重/保底发言者、invite_only 按钮驱动）。本轮补充的群组长期状态交点：群聊消息由 `groupchat.js` 作为历史单一真源落盘（`:531/:539`），assistant 消息快照 `agentId/model/modelSource`（`:950`）；群聊上下文同样应用 VCPChatTarven 注入与正则。
- **Canvas 协作（候选 11 的已实现部分）**：Canvas 窗口与聊天主窗口的文件级同步（chokidar watcher → 行级 diff → 接受/拒绝）、内存版本快照等已由[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 深入覆盖（G3 为主、G4 部分）。本轮补充：Canvas 是"单用户双窗口"同步（`canvasHandlers.js:93-105` 只向 canvas 窗口与主窗口广播），没有网络级多人协同协议；"与群文件区实时同步"未找到代码。
- **VCP 日记渲染与认知可见性（候选 7）**：`<<<DailyNoteStart>>>…<<<DailyNoteEnd>>>` 协议块的渲染（创建卡/更新替换预览）已由[消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 覆盖（`messageRenderer.js:311/:941-1005`，text-viewer 同步实现）；日记"模型回流"（DailyNote 工具结果通知渲染，`modules/notificationRenderer.js:150-216`）与对象管理（Memo 窗口）在本笔记能力卡 2 承接，不重复计数。
- **跨聊天消息转发入口（候选 14 的入口部分）**：右键转发入口已由 [Chat UI 调查笔记](../Chat%20UI/VCPChat-ChatUI调查笔记.md) 第 6 节记录，本轮补齐完整内容链（见能力卡 9）。
- **VCPDesktop 渲染与流式**：桌面推送的渲染器侧（消息内占位卡）、流式拦截、挂件源码编辑（Canvas 上下文打开）已由运行时笔记覆盖，能力卡 3 只补持久化/恢复/资源治理。

## 声明不符、外部依赖与暂缓项

- **群文件、共享工作区与协同编辑（候选 11）**：README 声称"为每个群组提供专属共享文件空间和工作区，支持实时协同编辑"。检查范围：全仓库 grep `群文件/GroupFiles/groupFiles/group-files` 零命中；群聊的"文件共享"实际是消息级附件（`attachments` 数组挂 user 消息，`groupchat.js:532`、`grouprenderer.js:1221-1285`），群成员通过历史可见；"协同编辑"仅存在于单用户 Canvas 双窗口场景。判定：群文件/共享工作区/群内协同编辑为 `声明不符`（未实现）。
- **ST 预设、角色卡、世界书与可视化注入（候选 9）**：README 声称"完全兼容并支持挂载 SillyTavern 的预设、角色卡和世界书，可直接创建和管理"。检查范围：`Promptmodules`（三种系统提示词模式：原始/积木块/预设文件）是 VCPChat 自己的提示词编辑器，无 ST 角色卡/世界书格式；全仓库 grep `世界书/WorldBook/角色卡/CharacterCard` 无前端实现命中；唯一确认的 ST 兼容入口是正则脚本导入（`regexHandlers.js:36-55`）。VCPToolBox 管理面板存在 `VcptavernEditor`（见 VCPToolBox Chat UI 笔记），判定：VCPChat 前端 `声明不符`，相关能力在外部仓库，暂缓归因。
- **分布式多模态文件追踪与跨模态转译（候选 15）**：节点侧主链已确认——主服务器发 `execute_tool`（internal_request_file），节点 `VCPDistributedServer.js:605-644` 将 `file://` URL 转本地路径读取并返回 base64+mimeType；`FileFetcherServer 新协议` 注释（`:606`）表明与后端联动。"全 URL 超栈追踪"与"高阶模型对低阶模型能力转译"的主服务器逻辑在 VCPToolBox，本仓库无实现；判定：节点侧 `入口确认`，完整闭环 `暂缓`（外部依赖）。
- **跨端记忆（候选 12 的记忆部分）**：README"跨端记忆"描述的是以 VCP 后端为中心的统一记忆库，VCPMobileSync 同步范围明确不含记忆（其 README 同步类型表只有 Agent/Group/Topic/Message/Attachment(不实际)/Avatar）；判定：记忆同步 `暂缓`（外部后端），消息/元数据同步 `主链确认`。
- **Agent 自主管理 Topic 的"前端刷新"（候选 8 补充项）**：TopicSponsor 创建话题后，普通话题在侧栏的即时出现机制未找到 watcher/事件证据（前端重读 config 而非订阅）；Flowlock 话题有明确的认领轮询。该项保留为未验证，不判不存在。

## 对特色贡献统计的影响

按"同一工作流的支撑机制合并计数、工程机制单独标注"口径，建议计入（均为静态证据的 `主链确认`）：

- **主贡献候选**：
  1. 高级回复（VCPChatTarven）——上下文注入/DSL 聚类；
  2. Memo 神经云图与日记工作台——记忆工作台聚类（与 VCPToolBox 记忆体系是消费/生产两端，跨仓库合计时注意不重复计"日记"本身）；
  3. VCPDesktop 持久挂件——活对象聚类（既有结论保持）；
  4. FlowLock 主动连续工作（含 TopicSponsor 交接）——主动 Agent 聚类（既有结论保持；TopicSponsor 的自主话题管理建议与 FlowLock 合并计数或单列为 Agent 自主性子项，不拆两个主贡献）；
  5. VCP 人类工具箱人类工具面（含插件导入与 ComfyGen 面板）——人类工具面聚类；
  6. 工作流编辑器——人类工具面聚类，建议与工具箱合并计数，但注明"代码主链完整、README 自述空壳、未运行验证"；
  7. Agent 正则系统——上下文 DSL 聚类；
  8. VCPMobileSync——多表面连续性聚类；
  9. LoomAPP 运行时——活对象/创作运行时聚类，与普通前端插件机制分开计数。
- **辅助贡献**：跨聊天消息转发与附言（Chat 工作流）；前端插件注册/注入机制（工程机制，单独标注）。
- **不计入**：群文件/共享工作区、ST 预设/角色卡/世界书（前端）、跨模态转译闭环、"跨端记忆"本体。
- **机制贡献（单独标注，不与产品特性混分）**：正则与 Tavern 规则的安全屏蔽、Flowlock generation 防复活、VCPMobileSync 的原子写/墓碑/稳定哈希、挂件资源治理（定时器/监听器清理、性能打点、可见性冻结）、HumanToolBox 的 IPC 白名单与路径校验。

## 未验证事项

1. 全部结论为静态分析，未运行应用：Tavern 注入在真实请求中的行为、Memo 云图渲染与后端联想算法、挂件桌面渲染与动画冻结效果、Flowlock 后台心跳续写与跨 Topic 交接、工作流编辑器执行与保存加载、ComfyUI 连接与模板转换、LoomAPP 运行与隔离、移动同步握手与吞吐、TopicSponsor 与前端认领对接。
2. README 声称的"content 数组正则"作用点未定位到实现（`applyFrontendRegexRules` 与上下文路径均只处理字符串）。
3. 独立"气泡评论"（评论附加在原始消息下方并持久化）未找到实现，仅确认转发对话框内的附加评论字段。
4. 工作流编辑器的工作流落盘格式与位置未核实；README §8 与代码的矛盾以代码为准，但"哪一版是预期行为"未确认。
5. TopicSponsor 普通话题的前端即时刷新机制未核实。
6. VCP-CDS（Rust）的中央索引模式仅确认了适配层与测试存在，未核实其查询/Change Feed 的完整行为。
7. 两个渲染器前端插件（动态壁纸、自动 TTS）仅确认注册与加载机制，插件本体 UI 行为未验证。
8. 现有 `tests/` 目录只含 4 个测试文件（frontend-plugins、loom-controller、deepmemo-central-adapter、mobile-sync-central-adapter），Flowlock 等核心模块无自动化测试覆盖。

## 关键源码索引

- `Tavernmodules/tavern-manager.js`：高级回复浮窗与规则管理模态；`modules/tavernRulesEngine.js`：三类注入纯逻辑引擎；`modules/ipc/tavernHandlers.js`：`VCPChatTarven.json` 持久化与 IPC。
- `modules/chatManager.js:188-233/1085-1130`：单聊 Tavern 注入与上下文正则应用点；`Groupmodules/groupchat.js:510-539/605-608/736/1189/1308`：群聊注入路径与历史真源。
- `Memomodules/memo.js`（apiFetch/工作台/批量操作）、`memo-graph.js`（联想与力导向图）、`memo-workbench.js`（引用工作台与 DailyNote 发布）。
- `Desktopmodules/favorites/favoritesManager.js`、`core/widgetManager.js`、`core/performanceManager.js`、`core/visibilityFreezer.js`；`modules/ipc/desktopHandlers.js:40/212/948/999/1228`。
- `Flowlockmodules/flowlock.js`（Session 状态机与认领）、`flowlock-integration.js`（用户操作绑定）、`flowlock-protocol.js`（状态气泡）；`Flowlockmodules/README.md`（协议与生命周期权威文档）。
- `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`：Agent 自主话题命令族。
- `VCPHumanToolBox/`：`renderer_modules/config.js`（工具定义）、`renderer_modules/tool-manager.js`（插件导入与参数解析）、`WorkflowEditormodules/WorkflowEditor_ExecutionEngine.js`（工作流执行）、`ComfyUImodules/ComfyUI_UIManager.js`（ComfyGen 面板）；`VCPHumanToolBox/README.md` §8（与代码矛盾的陈旧说明）。
- `VCPDistributedServer/frontend-plugin-loader.js` + `modules/ipc/desktopHandlers.js:96-120`：前端插件注册与注入；`modules/loom/VCPLoomManager.js` + `VCPDistributedServer/Plugin/LoomController/`：LoomAPP 运行时与命令。
- `VCPDistributedServer/Plugin/VCPMobileSync/`（manifest/diff/message/central）与 `rust_chat_data_service/README.md`：跨端同步与中央索引。
- `VCPDistributedServer/VCPDistributedServer.js:605-644`：节点侧 `internal_request_file` 文件拉取。
- `modules/renderer/messageContextMenu.js:211-220` + `renderer.js:2426-2564` + `modules/chatManager.js:1607-1651`：转发与附言主链。
