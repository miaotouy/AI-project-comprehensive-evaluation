# VCPChat 独特功能调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`89e02b778d626078be91dfbad01e5c9554c47f76`（分支：`main`）
>
> 调查方式：汇总现有十类单项目笔记，对十六项候选逐一走读源码主链（入口 → 状态/对象 → 执行 → 用户结果 → 持久化），核对模块注册（`main.html`、`main.js`、IPC handlers、`VCPDistributedServer` 插件目录）与近期 Git 历史；补充音频引擎专项（`rust_audio_engine` 源码 + `audio_engine` 部署产物 + `Musicmodules` + `musicHandlers.js` + MusicController 工具链）与旁路模块补查（划词小助手、主题、论坛、骰子、笔记、翻译、语音、TTS 族、RAG Observer、任务台、VchatManager、日志）；再核对 b6ffa22 → fb66a52 的 Loom v2/WebCore 升级与新增 Scriptorium 文坊子系统；本次补查 fb66a52 → HEAD 的受管启动、恢复、更新和图形安装器链，并运行 Bootstrap 与安装器契约测试；未运行 Electron、Tauri 或真实更新，其他结论以静态分析为主
>
> 调查范围：待查清单中 VCPChat 的全部候选能力 + 音频引擎/音乐播放器专项 + 上轮排除与遗漏的旁路产品面补查；本次覆盖受管启动与安装器的完整主链、更新边界和测试证据；去重边界以现有类目笔记为准（群聊发言模式、Canvas、日记渲染、桌面挂件渲染等已有笔记覆盖的部分只补交点）
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
10. **前端插件机制与 LoomAPP 运行时**：`manifest.frontend` 声明插件样式/脚本，主进程扫描后注入主窗口；现有 VChatDynamicWallpaper、VChatAutoTTS 两个渲染器插件；Loom 是 Agent 可创建、管理、注入代码的隔离 WebApp 运行时。b6ffa22 后 Loom 升为 **v1.4.0 + VCP Agent WebCore**：新增页面快照（Grounded Markdown）/页面图片/Web Core 动作执行/串行指令与设备管理（WebHID/USB/Serial/Bluetooth），Loom 从"网页容器"进化为"Agent 可感知、可操作的网页运行时"。
11. **VCPMobileSync 跨端双向增量同步**：三阶段协议（Reconcile → Double-Hash Merkle Diff → NDJSON 流式），冲突按最新时间戳胜出，墓碑拦截防回流；中央索引模式由 `vcp_chat_data_service`（VCP-CDS）承接。
12. **Agent 自主管理 Topic（TopicSponsor）**：分布式插件直接读写 `AppData/Agents|UserData` 创建话题、回复话题、检查所有权/未读，与 FlowLock 的 `CreateFlowlockTopic` 交接构成闭环。

b6ffa22 → fb66a52 范围新增第 13 条 `主链确认` 能力：**Scriptorium 共笔文坊（VCP Scriptorium）**——本地富文档/演示创作空间（VDOCX/VPPTX 工程、DOCX/PPTX/MD/HTML/RTF/TXT 导入、HTML/PDF 导出），人类直接编辑渲染版式，Agent 经 `ScriptoriumCollaborator` direct 插件以"可审阅 PR"（文脉刻点 + 审批回执 + 修订冲突保护）协作编辑源码。详见能力卡 15。

fb66a52 → HEAD 范围新增第 14 条 `主链确认` 能力：**受管启动、恢复与图形安装器**。它把源码版 VCPChat 的首次诊断、受控修复、启动就绪交接、可取消恢复、版本目录更新与回滚连为独立工作流；安装器还在源码树有本地修改时提供暂存、仅快进更新和恢复策略。该能力面服务于桌面应用的交付与维护，不改变既有聊天功能或原始启动脚本。详见能力卡 16。

声明不符或依赖外部仓库的项：README 声称的"群文件/共享工作区/协同编辑"在本仓库未找到对应实现；"ST 预设、角色卡、世界书"在 VCPChat 前端无导入与管理入口（后端 VCPToolBox 才有）；"跨模态智能转译/全 URL 超栈追踪"的主服务器逻辑在 VCPToolBox，本仓库只确认节点侧 `internal_request_file` 拉取链；"跨端记忆"的中心记忆库同样位于后端。

新增两条 `主链确认` 能力：**VCP Hi-Fi 音频引擎与音乐播放器**（自研 Rust 解码/DSP/WASAPI 引擎 + Agent 点歌工具 + 桌面音乐挂件 + WebDAV 曲库）与**划词小助手（Rust 桌面感知引擎）**。另补查 11 个旁路模块：双语混合朗读、3D 物理骰子、Agent 论坛客户端、RAG Observer 信息流监听、语音聊天（Puppeteer 方案）、笔记系统达到 `主链确认`；任务台、VchatManager、日志中心为 `入口确认`；主题系统为 `骨架/声明不符`（README 声称的"Agent 主题生成器"未接线）。同时核出 8 项 README 声明与代码不符（DSD 硬解码、AI 歌词创作、音乐实时听音、TTS"600% 剪枝"、主题生成器、骰子多主题/物理施法、划词小助手右键呼出/文件夹工作区、Obsidian 云同步），详见"声明不符"节。

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
| 动态壁纸、自动 TTS、Loom 等前端插件 | `主链确认`（机制与 Loom）；`入口确认`（两个渲染器插件本体） | `frontend-plugin-loader.js` + manifest.frontend；Loom v1.4.0 + `modules/loom/webcore/*` | Loom 独立主贡献；插件机制辅助 |
| Scriptorium 共笔文坊 | `主链确认` | `ScriptoriumModules/` + `docxHandlers.js` + ScriptoriumCollaborator 插件 | 主贡献（创作工作站族，能力卡 15） |
| 受管启动、恢复与图形安装器 | `主链确认` | `scripts/vcpchat.mjs` + `modules/bootstrap/` + `apps/bootstrap-installer/` | 主贡献（多表面连续性/交付工作流，能力卡 16） |

## 已确认的独特能力

### 能力卡 1：高级回复（VCPChatTarven）三类注入系统

- **用户目标**：在不修改 Agent 配置与聊天历史的前提下，对每次 AI 请求做按需、可开关的提示词干预；这是普通 Chat 与通用 Agent 底座没有的"请求级临时设定"层。
- **入口与触发者**：用户右键发送按钮弹出「高级回复」浮窗（逐条开关），浮窗齿轮进入「规则管理」模态（新建/编辑/删除/拖拽排序）。渲染端 `Tavernmodules/tavern-manager.js:96-255`（浮窗）、`:258-596`（管理模态）。
- **事实对象**：规则实体为九字段 JSON（`{id, name, type, enabled, content, scope, wrap, role?, depth?}`），持久化在 `AppData/VCPChatTarven.json`，读写经 `tavern:get-rules`/`tavern:save-rules` 两个 IPC 通道（`modules/ipc/tavernHandlers.js:88-112`），主进程带 mtime 缓存。
- **完整主链**：右键发送按钮 → 开关/编辑规则 → 主进程写 JSON → 发送时 `getActiveRulesForScope`（`tavern-manager.js:602-608`）取生效规则 → 引擎按类型注入 → VCP 提交。三种注入由纯逻辑引擎 `modules/tavernRulesEngine.js` 实现：
  - `system_suffix`：系统提示词尾部追加（`applySystemSuffix`，`:78-89`）；
  - `user_suffix`：仅追加到本轮提交给 AI 的用户文本副本，**不写入历史**（`applyUserSuffix`，`:99-110`）；
  - `context_inject`：以独立 user/assistant 消息插入上下文（`applyContextInject`，`:123-149`）；depth 表示距末尾的位置，为 0 时插到末尾，为 N 时插到倒数第 N+1 条之前，按从大到小排序避免索引错位。
  - 包裹标记 `[本信息由VCPChat客户端注入]…[临时注入结束]`（`:27-28`），每条规则可关闭（裸注入）。
- **作用范围（scope）**：`global / agent / group` 三档（`isRuleActive`，`:56-61`）。单聊与群聊的全部发言路径（含重试/编辑与邀约发言）都接入三类注入；群聊的 user suffix 只改提交副本，历史落 `originalUserText`——"群聊不丢注入"的声明成立。各应用点定位如下：
  - 单聊：`modules/chatManager.js:1124`（user suffix）、`:1311/:1316`（system suffix）、`:1327`（context inject）
  - 重试/编辑路径：`modules/renderer/messageContextMenu.js:788/:934/:950`
  - 群聊：`Groupmodules/groupchat.js:518`（user suffix，历史落 `originalUserText` 于 `:531`）、`:607`（system suffix）、`:736`（context inject）
  - 邀约发言：`Groupmodules/groupchat.js:1189/:1308`
- **持续性**：规则 JSON 文件重启后恢复；开关即时生效（mtime 缓存失效）。
- **人机关系**：用户可在浮窗逐条开关，管理模态全量 CRUD；无 Agent 侧写入入口。
- **外部依赖**：纯前端 + 主进程文件，无后端依赖。
- **独特性判断**：与 SillyTavern 的注入位相比，它是客户端自管理、单聊/群聊统一适配的 VCP 原生实现；与 AIO Hub 的消息配方相比，它刻意保持"轻量、不污染历史"的临时设定定位。归入"上下文注入/DSL"聚类。
- **证据强度**：源码事实（引擎、应用点、持久化全部走通）；开关热加载与实际请求行为未运行验证。

### 能力卡 2：Memo 神经云图与日记工作台

- **用户目标**：把 AI 自动记录与整理的日记/记忆库从"文件目录"升级为"可视化记忆拓扑 + 批量整理 + 整合代笔"的工作台；这是普通聊天客户端没有的长期记忆管理面。
- **入口与触发者**：主窗口头部按钮右键打开 Memo 窗口（`main.html:690`，`modules/ipc/windowHandlers.js:342` 加载 `Memomodules/memo.html`）；VCPDesktop 桌面图标 `vchat-app-memo` 亦可进入（`Desktopmodules/桌面图标与启动API指南.md:33`）。
- **事实对象**：后端 `admin_api/dailynotes/*` 管理日记文件（文件夹/思维簇分类）；前端不落盘，全部经带 Basic Auth 的 REST 调用，主要操作定位如下：
  - 公共请求封装：`Memomodules/memo.js:501-520`
  - `loadFolders`（取文件夹）：`:524`；`loadMemos`（取日记）：`:700`
  - 保存：`:941`；批量删除/移动：`:1354-1412`
- **完整主链**：
  - 云图：日记卡 → "关联" → 选文件夹与 k/boost 参数 → `POST /associative-discovery`（`memo-graph.js:71-155`）→ 后端返回联想节点 → 前端 Canvas 力导向图渲染（斥力/引力、连线分数、节点卡、多选、缩放平移，`:157-567`）→ 节点详情可加载全文并批量加入工作台（`:611-692`）。
  - 工作台：选中多篇日记 → `DiaryWorkbench`（`memo-workbench.js:18-97`）→ 引用卡片/完整阅读 → 新建整合日记 → 以 `<<<[TOOL_REQUEST]>>>` 包装 DailyNote 的 create 命令（tool_name:DailyNote, command:create）经 `/v1/human/tool` 发布（`:158-234`）→ 发布后可对旧日记归档到「已整理」或批量删除，归档与删除定位见下。
    - 归档：`/move` 到「已整理」（`:266-282`）
    - 批量删除：`:335-348`
  - Agent 代笔与语义搜索：`memo.js:1060/:1160` 同样调用 `/v1/human/tool`（LightMemo/语义检索），结果经 `processSemanticSearchResults` 归一化为可打开路径（`:1197-1320`）。
- **持续性**：全部日记由后端持有；前端仅持久化 UI 偏好（隐藏文件夹/排序，`saveMemoConfig` `:1428`）。
- **人机关系**：用户主导整理（批量编辑、移动、归档）；Agent 通过工具代笔与语义检索参与；"模型回流"指模型经 DailyNote 工具写日记、经 Memo 窗口再被阅读与检索。
- **外部依赖**：后端 `admin_api/dailynotes` 与 `v1/human/tool` 属于 VCPToolBox（本仓库只确认请求格式与调用点）；云图算法（对称性破缺有序能索引）完全在后端，前端无法验证其语义。
- **独特性判断**：日记文件本身是后端生态的持久对象，但"联想云图 + 工作台 + 批量编辑"的组合只在 VCP 系出现；与 VCPToolBox 的 TagMemo/RiverMemo 是同一记忆体系的消费/管理两端。
- **证据强度**：源码事实（入口、API 链、图渲染、批量操作全部走通）；后端算法、云图实际渲染与 Agent 代笔结果未运行验证。

### 能力卡 2A：DeepMemo 2.0 中央会话回忆适配器（主动历史 RAG）

- **用户目标**：让 Agent 通过工具主动查找其他 Topic 中的历史对话，并把命中的上下文窗口带回当前会话；它检索的是聊天历史，不是 Memo 工作台管理的日记文件。
- **入口与触发者**：模型调用 `DeepMemo` 工具后，由 `DeepMemoService.processToolCall()` 接收参数（`VCPDistributedServer/Plugin/DeepMemo/DeepMemoService.js:42-126`）。VCP 主服务器把聊天请求中白名单内的 `requestContext` 复制为内部 `_vcpContext`；模型工具参数不能覆盖其中的 agentId、topicId 或 owner 信息（调用链与上下文上传说明见该插件 README）。
- **事实对象**：VCP-CDS 中央聊天数据服务维护的会话/Topic 历史索引。DeepMemo 2.0 不再扫描 Agent 目录、`history.json`，也不再创建独立 Tantivy/FlexSearch 索引；插件是常驻薄适配器，只消费 `ChatDataServiceClient.searchMemories()`。
- **完整主链**：规范化 `keyword`、窗口大小和结果上限 → 以可信 Agent/Topic 上下文构造中央搜索请求（`DeepMemoService.js:135-205`）→ 默认排除当前 Topic，按前后窗口扩展命中 → 选择性调用外部 Rerank（候选批次有文档数、字符数和超时界限）→ 按字符预算筛选 → 清理 HTML/CSS 后格式化回注当前工具结果；中央服务失败时按配置决定是否使用旧版回退程序。
- **持续性与边界**：索引和聊天历史由 VCP-CDS 持有；适配器自身不持久化记忆，不提供自动生成前注入、递归思考链或人工记忆维护。真实 CDS 搜索、精排效果和跨 Topic 结果未运行验证。
- **横向归类**：这是闭环的主动会话历史 RAG，但产品契约仍接近常规“搜索历史对话”工具；在特色统计中作为 VCP RAG 能力地图的边界样本记录，不另立主/辅助贡献。它与 VCPToolBox F66/F102 的区别在于：DeepMemo 由 Agent 主动调用并返回历史窗口，F66 在生成前自动注入私人语义召回，F102 则把检索组织成可持久、逐阶段演化的思考程序。

### 能力卡 3：VCPDesktop 流式推送与持久挂件

既有 `Agent工具` 与 `生成式输出与运行时` 笔记已确认 DESKTOP_PUSH 流式拦截（`modules/renderer/streamManager.js:1906`）、挂件收藏目录 `AppData/DesktopWidgets/<id>/`（`modules/ipc/desktopHandlers.js:999-1095`）与模型侧远程控制。本卡补充运行恢复、资源治理与近期提交范围三个面：

- **运行恢复**：收藏时把截图与 HTML 落盘（`Desktopmodules/favorites/favoritesManager.js:21-73`）；恢复时读文件、重建挂件并延迟执行内联脚本（`:108-139`），运行状态不持久，重启后脚本重新执行。收藏列表从目录扫描生成（`desktopHandlers.js:1228-1271`），并自动维护 `CATALOG.md` 索引（`:212-295`）。
- **资源治理**：挂件沙箱跟踪自身的定时器与窗口/文档监听器，以便销毁时清理（`Desktopmodules/core/widgetManager.js:460-538`）；`performanceManager` 按周期打点 JS 执行时长与帧数，估算每挂件 CPU% 与 FPS（`core/performanceManager.js:41-143`）；`visibilityFreezer` 冻结不可见区域的壁纸 iframe 与视频动画（`core/visibilityFreezer.js:237`）；另有 zIndex 管理与删除 fallback。
- **近期提交范围**：`Desktopmodules` 仅两次变更（`0f8aa6d` Loom 工程落地、`3f14e93` fix），挂件主链无结构性改动；变化集中在 `VCPDistributedServer` 侧的三处提交（见下列清单），对应能力卡 10 与 11：
  - 动态壁纸/自动 TTS 插件：`649e9af`
  - LoomController：`3e3c6b9`
  - VCP-CDS 数据库重构：`d00c10b`
- **证据强度**：恢复与资源治理为源码事实；真实桌面渲染、动画冻结效果与性能数据未运行验证。

### 能力卡 4：FlowLock 主动连续工作

既有 `Agent工具` 笔记已确认状态机、心跳、重试与完整请求重建。本卡补充（协议文档 `Flowlockmodules/README.md` 与代码一致）：

- **用户可见状态**：Agent 侧栏头像活动状态环、当前标题发光/悦动、心跳脉冲动画（`Flowlockmodules/flowlock.css`）；消息内按协议状态渲染对应气泡（`flowlock-protocol.js:326-330`，`data-vcp-block-type="flowlock"`）。状态字面量：
  ```text
  Start / Stop / Complete / Fail / NextHeartbeat / NextPrompt
  ```
- **用户操作**：右键聊天标题 = 启动（不立即续写）/停止；中键 = 启动并立即续写/停止；`Ctrl+G`（macOS `Command+G`）同中键（`flowlock-integration.js:272-367`）。
- **跨 Topic 接管**：`CreateFlowlockTopic` 由 TopicSponsor 插件创建带 `flowlockRequest`（UUID 请求 ID、pending 状态）的话题，前端在最终回复完整落盘后经 `claimPendingFlowlockTopic` 原子认领并交接 Session（`flowlock.js:163-260`；IPC `preloads/chat.js:265-267`），失败时补偿恢复为 pending；页面重载后枚举恢复，冲突保持 pending。
- **取消与资源上限**：Stop/Complete/Fail 取消定时器并增加 generation 防复活（README 5 节）；心跳延迟钳制在 1–86400 秒（`topicsponsor.js:151-158`）；续写失败默认最多重试三次后自动停止（README 7.4）；协议解析屏蔽工具请求/结果、Desktop Push、元思考链、think 块与代码围栏（README 6.1）；历史渲染只出状态气泡不重放命令（6.2）。
- **证据强度**：协议、状态机与交互绑定为源码事实；后台心跳续写与跨 Topic 交接的完整运行未验证（README 称单元测试通过，本仓库 `tests/` 中未见 Flowlock 测试文件）。

### 能力卡 5：VCP 人类工具箱（人类工具面）与插件 manifest → 表单转译

- **用户目标**：把 AI 才能用的 VCP 工具以表单化 GUI 开放给人类，无需手写 `<<<[TOOL_REQUEST]>>>`；普通客户端没有"把 Agent 工具面投影为人类可操作面板"的能力。
- **入口与触发者**：主窗口「工具箱」按钮经 launchStandaloneElectronApp 启动独立 Electron 应用 `VCPHumanToolBox`（`modules/ipc/desktopHandlers.js:1376`）；VCPDesktop 图标 `vchat-app-toolbox` 亦可进入。独立应用自身在 `VCPHumanToolBox/main.js:238-295` 注册 `vcp-ht-execute-tool-proxy` 执行代理。
- **事实对象**：工具定义库 `renderer_modules/config.js`（46 个出厂工具，7 种参数 widget 类型）+ 用户导入工具 `settings.vcpht_userTools`（Config Overlay 优先于出厂定义）。
- **完整主链（执行链）**：工具网格 → `buildToolForm()` 按参数 schema 生成表单 → 用户填参执行 → 经 `vcp-ht-execute-tool-proxy` 由主进程拼装 `<<<[TOOL_REQUEST]>>>` 并 `POST /v1/human/tool`（Bearer Token）→ `renderResult()` 多模态渲染。
- **完整主链（插件导入链）**：管理 Tab 连接后端 Admin API，`GET /admin_api/plugins`（`renderer_modules/tool-manager.js:79-103`）→ 解析 manifest 参数（支持四种格式与三层 fallback，`:220-310`；`invocationCommands` 适配为 config.js 格式，`:364-413`）→ 可视化表单/JSON 双编辑器 → `vcp-ht-save-settings` 持久化。
- **持续性**：用户工具随 `AppData/settings.json` 持久化；Admin 连接配置存 localStorage。
- **安全边界**：`contextIsolation + nodeIntegration:false`、preload 白名单 12 个 IPC 通道、路径校验（`getPluginManagerPluginDir`，`desktopHandlers.js:67-78`）。
- **外部依赖**：执行由 VCPDistributedServer/后端负责；应用自身 README 明确"不是权限管理系统"。
- **证据强度**：源码事实；表单实际交互与真实工具执行未运行验证。

### 能力卡 6：工作流编辑器（节点编排与执行引擎）

- **用户目标**：把多个 VCP 工具调用编排为可保存、可复用、可逐步执行的节点工作流。
- **入口与触发者**：HumanToolBox 顶部「工作流」按钮 → `openWorkflowEditor`（`renderer.js:1678-1722`）→ `WorkflowEditorLoader_Simplified` 动态加载模块（模块本身已由 `index.html:52-67` 预加载）。
- **事实对象**：jsPlumb 节点画布上的节点（VCPChat 插件 / VCPToolBox 插件 / 辅助节点）与连接，状态由 `WorkflowEditor_StateManager` 管理（位置、配置、连接、拓扑分层）。
- **完整主链**：拖拽建节点连线 → 执行按钮（`WorkflowEditor_UIManager.js:80/:173/:2468-2522`）→ `ExecutionEngine.executeWorkflow`（`WorkflowEditor_ExecutionEngine.js:65-159`）：先做环检测与预飞行检查，按分层拓扑同层并发执行并受 maxConcurrency 限流，错误策略可选 stop/continue → 插件节点构造 `<<<[TOOL_REQUEST]>>>` 并请求 `/v1/human/tool`（`:596-874`，含智能命令匹配）→ 结果归一化后存入节点结果对象并传播到下游输入。
- **辅助节点**：覆盖数据转换、条件、延时、循环（`loopStart`/`loopEnd`）、正则、代码编辑、URL 渲染、内容输入与 AI 拼接等类型（`:520-563` 分发）。
- **文档与实现不一致**：`VCPHumanToolBox/README.md` §8 声称"执行管线为空壳、不建议在生产中依赖"，但当前代码已实现完整执行链；按 AGENTS.md 约定以可执行路径为准，README 属陈旧说明。
- **持续性**：工作流保存/加载由 StateManager 承接（README §8 已实现列表）；本轮未核实落盘格式与位置。
- **证据强度**：入口、UI 绑定、执行引擎均为源码事实；未运行验证节点执行结果与保存/加载往返。

### 能力卡 7：ComfyGen 专用创作配置面板

- **用户目标**：为后端 ComfyUIGen 图像生成插件提供人类可用的参数与资产管理面板（工作流模板、LoRA、模型、提示词），与工具网格的"用户/Agent 共用参数面"形成闭环。
- **入口与触发者**：HumanToolBox 工具网格中 `ComfyUIGen` 卡片右上角 ⚙ 按钮 → `openComfyUISettings`（`renderer.js:1608-1650`）→ `ComfyUILoader` 动态加载 ComfyUI 模块族。
- **完整主链**：配置抽屉三 Tab（连接/生成参数/工作流管理）→ 测试连接（本地 ComfyUI，默认 `http://localhost:8188`）→ 保存配置写回后端插件目录 → 工作流导入（ComfyUI API 格式 JSON，校验后转换）→ 含 `WeiLinComfyUIPromptToLoras` 节点时自动注入 LoRA。抽屉与 Tab 实现见 `ComfyUI_UIManager.js:157-305`。
- **配置持久化与转换**：保存经 `comfyui:save-config` 写回 `VCPToolBox/Plugin/ComfyUIGen/comfyui-settings.json`（`ComfyUImodules/README.md:48`，PathResolver 定位插件目录）；工作流转换经 `import-and-convert-workflow`；LoRA 注入条件见 `ComfyUImodules/README.md:16-25`。
- **外部依赖**：ComfyUI 本地服务与后端插件（VCPToolBox）；本仓库只实现配置管理链，生成执行仍经工具网格或 Agent 调用。
- **证据强度**：入口与 IPC 链为源码事实；连接测试、模板转换与参数注入行为未运行验证。

### 能力卡 8：Agent 正则系统（四类作用点）

- **用户目标**：对 Agent 的渲染文本与发送给模型的上下文做可分层、按深度与角色生效的正则改写；比通用"消息过滤"更接近 SillyTavern 的提示词工程层。
- **入口与触发者**：Agent 设置中的正则规则编辑模态（`main.html:1822-1884`，含标题、查找/替换、作用域、角色与 min/max 深度）；`import-regex-rules` 支持导入 SillyTavern 正则脚本（`modules/ipc/regexHandlers.js:36-55`），导入时的字段映射如下：
  ```text
  placement: 1=user, 2=assistant
  markdownOnly → 前端（渲染）
  promptOnly → 上下文
  min/maxDepth → 直接对应
  ```
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
- **完整主链**：转发模态先展示目标列表（含 Agent 与群组，可搜索）→ 确认后用原始消息构造 `> 转发自 **sender** 的消息:` 前缀、原文与可选附言 → 聊天管理器切换到目标会话、填充输入框与附件后走标准发送链触发完整 AI 响应。入口与发送处理分别在 `renderer.js:2426-2470` 与 `modules/chatManager.js:1607-1651`；其余函数与字段定位见下：
  - `handleConfirmForward`：`renderer.js:2508-2564`；原文取 `getOriginalMessageContent`；附言字段 `forwardAdditionalComment`
  - 附件填充：`localPath: att.src` + `_fileManagerData`
  - 标准发送入口：`handleSendMessage`
- **持续性**：转发内容作为目标话题的普通消息落盘；评论只是消息文本一部分，无独立评论对象。
- **声明核对**：README 所述"右键消息气泡添加评论附加在原始消息下方"未找到独立实现——实际只有转发对话框内的"附加评论"字段；独立气泡评论本次未找到。
- **证据强度**：转发主链为源码事实；附件在目标端的历史重建与展示未运行验证。

### 能力卡 10：前端插件机制与 LoomAPP 运行时

- **插件注册**：插件 manifest 的 `frontend` 字段以 style/script 两字段声明渲染器插件；主进程 `listEnabledFrontendPlugins` 扫描 `VCPDistributedServer/Plugin/*`（`modules/ipc/desktopHandlers.js:96-120`），路径经 `resolveFrontendPluginResource` 白名单校验后返回相对 URL。
- **注入与事件**：`frontend-plugin-loader.js` 在 DOMContentLoaded 后注入样式与脚本，并派发 `vcp-frontend-plugins-loaded`；现有插件为 `VChatDynamicWallpaper` 与 `VChatAutoTTS`（manifest 均标 `pluginType: renderer`）。
- **两个现存插件（入口确认）**：VChatDynamicWallpaper（文件夹视频壁纸 + 紧凑播放控制）、VChatAutoTTS（自动朗读与代码块朗读开关），均为 `649e9af` 引入，插件本体行为未运行验证。
- **LoomAPP 运行时（主链确认）**：
  - **运行时托管**：`modules/loom/VCPLoomManager.js`（现 2,076 行）用 `WebContentsView` 托管 LoomAPP：manifest 声明 id、startUrl、窗口/视口、UA 与注入的 css/js（`inject.css`/`inject.js` 有 2MB 上限，`SAFE_APP_ID` 校验）。
  - **用户面**：`Loommodules/manager.html`（应用抽屉、导入/导出）与 `Loommodules/device-menu.html`（WebHID/WebUSB/WebSerial/WebBluetooth 设备授权选择，`loom:device-candidates` 事件）。
  - **Agent 侧 LoomController 1.4.0**：提供 13+ 命令（`plugin-manifest.json`），在原有八个命令 ListApps/CreateApp/OpenApp/CloseApp/GetAppSources/GetRuntimeSource/GetRenderedText/EditAppSources 之外新增四类能力：
    - **GetPageInfo**：Web Agent 页面快照 + Grounded Markdown（含 action handle/documentGeneration/snapshotId/pageGraph）；
    - **GetPageImage**：按图片 ID 返回 `data:image/...` 多模态回执；
    - **ExecuteAction**：Web Core 标准动作目录；
    - **串行指令协议**：`command1/command2/...` 编号步骤 + wait，任一步失败停止但保留成功步骤回执（`partial_failure`）。
  - **底层 WebCore 与测试**：新增 VCP Agent WebCore（`modules/loom/webcore/*`，8 个文件约 5,075 行：chrome/electron 双 adapter + web-agent-protocol + page/runtime core），由 LoomControllerService（306 → 656 行）路由到 VCPLoomManager 的 getWebAgentPageInfo/executeWebAgentAction；测试：`tests/loom-controller.test.js`、`tests/loom-electron-adapter.test.js`、`tests/loom-manager-runtime.test.js`（新增）。
- **证据强度**：注册、注入、Loom 命令分发与 WebCore 适配层均为源码事实；LoomAPP 实际运行、WebCore 页面感知与隔离边界未运行验证。

### 能力卡 11：VCPMobileSync 跨端双向增量同步

- **用户目标**：让 VCPChat 桌面端与 VCPMobile 手机端保持聊天数据（Agent/群组/话题/消息/头像）的物理双向同步；"跨端记忆"的 README 声明（中心记忆库实时同步）实际由后端承担，本插件同步范围不含记忆库。
- **入口与触发者**：桌面端全局设置开启「VCP 分布式服务器」后插件随 `VCPDistributedServer` 加载；手机端配置 HTTP（默认 5974）/WebSocket（默认 5975）与 Sync Token 握手。
- **事实对象**：`sync_state.db` 维护五张表（README §5，字面量见下）；中央索引模式下改用 VCP-CDS 的 SQLite/Tantivy。
  ```text
  entity_index / message_index / attachment_index / avatar_index / message_attachments
  ```
- **完整主链（三阶段协议 V2）**：Phase 1 Reconcile 扫描 `Agents/AgentGroups/UserData` 建索引（`VCPMobileSync/index.js:313`）；Phase 2 双哈希差分（configHash + Merkle contentHash）生成消息级 toPull/toPush/delete 清单（同步清单 `sync/manifest.js:88-195`，消息级 diff `sync/diff.js:114-197`，Fast-Path 直接跳过）；Phase 3 以 NDJSON 流式吞吐（`sync/message.js:29-191`）：逐行消费、文件锁、临时文件 + rename 原子写，并以 writeIntentLock 防止 watcher 死循环。冲突策略：双向增量合并，同一实体并发修改按最新时间戳胜出（README §1）；墓碑拦截 + 30 天清理防"幽灵数据回流"（README §6）。
- **中央索引模式**：开启 `MobileSyncUseCentralIndex=True` 后，同步清单、差分、拉取/推送、墓碑与变更流六类操作改由 Rust 服务 `vcp_chat_data_service`（VCP-CDS）承接（`rust_chat_data_service/README.md:8-16`），身份模型为三元组（`:110-120`，字面量见下）；测试 `tests/mobile-sync-central-adapter.test.js` 存在，旧 sync_state.db 链路可切换回退。
  ```text
  同步操作：Manifest / Diff / Pull / Push / Tombstone / Change Feed
  身份模型：(owner_type, owner_id, topic_id)
  ```
- **边界**：附件表存在但"实际上不能同步"（README §4 表格明确标注）；头像参与同步。
- **证据强度**：协议、表结构、原子写与中央适配为源码事实；真实手机端握手、大文件吞吐与冲突收敛未运行验证。

### 能力卡 12：Agent 自主管理 Topic（TopicSponsor）

- **用户目标**：让后台运行的 Agent 主动创建/发现/回复自己的聊天话题，实现"Agent 主动向用户发起聊天"的自主交互（README 自主话题管理）。
- **入口与触发者**：Agent 经 VCP 工具调用 `TopicSponsor` 插件（`VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`，命令分发 `:23-53`），命令族如下：
  ```text
  CreateTopic / CreateFlowlockTopic / ReadUnlockedTopics / CheckNewTopics /
  CheckUnreadMessages / ReplyToTopic / CheckTopicOwnership / ListUnlockedTopics / ReadTopicContent
  ```
- **事实对象**：直接读写 `AppData/Agents/<uuid>/config.json`（topics 数组）与 `AppData/UserData/<uuid>/topics/<topicId>/history.json`。
- **完整主链**：
  - **CreateTopic**（`:344-447`）：校验 Agent 存在 → 生成 `topic_<ts>_<uuid>` 话题目录与带 `_metadata.topicCreator` 的初始 assistant 消息 → topics 数组插入创建元数据（`locked:false, unread:true, creatorSource:"plugin:TopicSponsor"`）→ 临时文件 + rename 原子写 config；
  - **ReplyToTopic**（`:551-614`）：在 locked 且已读话题上拒绝写入，追加带 `isPluginReply`/`originalSender` 元数据的消息；
  - **CheckTopicOwnership**（`:616-655`）：读 `_creator` 判定 `is_owner`。
- **前端认领链**：`claimPendingFlowlockTopic`/`restoreFlowlockClaim`/`listPendingFlowlockTopics`（`preloads/chat.js:265-267`），主进程按 Agent 串行化、多候选拒绝、失败补偿恢复 pending（见能力卡 4）。普通话题的"前端实时刷新"（新话题出现在侧栏）机制本轮未单独核实——前端在会话切换/重载时重读 config，无 watcher 证据。
- **独特性判断**：与 FlowLock 同属"主动 Agent"聚类但事实对象不同（话题持久化 vs 运行时 Session）；跨 Agent 回复（一个 Agent 往另一 Agent 的话题追加消息）是仅 VCP 系出现的拓扑。
- **证据强度**：插件命令与认领 IPC 为源码事实；插件与前端 IPC 的真实对接运行未验证。

### 能力卡 13：VCP Hi-Fi 音频引擎与音乐播放器（Agent 可控的本机播放子系统）

- **用户目标**：在聊天客户端内获得一个专业级本机音乐播放器——Hi-Fi DSP 处理、WASAPI 独占输出、WebDAV 远程曲库、无缝隙切歌，且 Agent 能通过对话"点歌"、桌面挂件能随时控制。这是普通 Chat 客户端没有的"本机媒体播放子系统"。
- **入口与触发者（用户侧三入口）**：聊天页/托盘音乐按钮经 `open-music-window` IPC 创建单例无边框窗口（`modules/ipc/musicHandlers.js:290`，页面 Musicmodules/music.html）；VCPDesktop 内置音乐迷你条挂件（`Desktopmodules/builtinWidgets/musicWidget.js:150-173`）；音乐窗"分享到聊天"经 `music-share-track`（`musicHandlers.js:705`）。
- **入口与触发者（Agent 侧）**：`MusicController` 工具经 `<<<[TOOL_REQUEST]>>>` 到达 `VCPDistributedServer.js:656-687`，注入调用 `handleMusicControl`（`musicHandlers.js:201-269`：play 可带 target 点歌，另支持 pause/stop/next/previous）。
- **入口与触发者（提示词注入）**：全局设置 `agentMusicControl` 开启后，把 `点歌台{{VCPMusicController}}` 指令注入系统提示词（`modules/ipc/chatHandlers.js:948-962`、`modules/vcpClient.js:249-260`）。
- **事实对象**：音频源为本地文件与 WebDAV 服务器曲库（`Musicmodules/music-webdav.js`、`modules/webdavManager.js`）；播放器与引擎的持久化对象如下表（播放列表与歌单均位于 AppData 下）：
  | 对象 | 落盘位置 | 定位 |
  |---|---|---|
  | 播放列表 | `AppData/songlist.json` | `musicHandlers.js:279` |
  | 自定义歌单 | `AppData/custom_playlists.json` | `musicHandlers.js:670` |
  | 歌词 | `AppData/lyric/*.lrc` | — |
  | 封面缓存 | `AppData/MusicCoverCache` | — |
  | 引擎设置 | `AppData/audio_settings.json` | `rust_audio_engine/src/settings.rs:257` |
  | 响度元数据 | `loudness_cache.db`（SQLite） | `server.rs:638-649` |
  | 重采样缓存 | `resample_cache/`（SHA-256 文件名） | `main.js:664` |
- **完整主链（自研引擎）**：主进程启动时预热 Rust 二进制 `audio_engine/audio_server.exe`（`main.js:166-232`：spawn 时带 `--port 63789`，从 stdout 等待 `RUST_AUDIO_ENGINE_READY` 信号；退出时 POST `/shutdown` 优雅关停并兜底强杀）。引擎对外接口分两层，子模块分工如下：
  - 接口：actix-web HTTP API（`server.rs`）+ WebSocket 频谱/事件推送（`server/ws_handlers.rs`，50ms 帧间隔，事件位掩码含 load_complete/track_changed/needs_preload）；
  - 解码：Symphonia（`decoder.rs`，f64 全链路，支持本地路径与带 Basic Auth 的 HTTP(S) URL）；
  - 播放：cpal 共享模式 + **WASAPI 独占模式**（`wasapi_output.rs`，绕过系统混音器直通硬件，Windows 专用线程）；
  - 实时 DSP 链（音频线程用无锁原子参数，`player/audio_thread.rs`、`player/callback.rs`；debug 构建下以 `assert_no_alloc` 审计回调）：IIR 10 段 EQ（lock-free）、**FIR EQ 真实卷积**（1023+ taps 可调，`player/mod.rs:890-996`）、饱和、crossfeed、动态响度与峰值限制；
  - 噪声整形与位深：五种整形曲线（`Lipshitz5/FWeighted9/ModifiedE9/ImprovedE9/TpdfOnly`，`server/effects.rs`），输出位深可选 16/24/32；
  - 响度：EBU R128（`processor/loudness.rs`），`track/album/streaming/replaygain` 四种模式，全曲扫描 + SQLite 缓存 + 后台扫描任务（信号量限流、TTL 回收、可取消，`server.rs:65-88`、`server/playback.rs:509-653`）；
  - 重采样：SoX VHQ（`processor/resampler.rs`），目标采样率 8k–384k（`playback.rs:330-365`），缓存键含文件大小+mtime（`player/mod.rs:377-409`）；
  - 无缝隙切歌：预加载下一首解码 → pending buffer 原子交换（`player/gapless.rs`）；
  - 外置 IR 卷积（`load_ir`，64MB 上限，预置 `audio_engine/IRPreset/`，`musicHandlers.js:498-528` 列表管理）；
  - 安全：`validate_path`（`server.rs:99-189`）拒绝路径穿越、UNC、Windows 保留设备名，URL 拒绝私网/环回地址（SSRF 防护）。
- **前端播放器主链（控制与渲染）**：选曲后经 `music-load` IPC 调引擎 `/load`（`musicHandlers.js:166-196`）→ 引擎异步解码（进度经 WS 推送）→ play/pause/seek/volume/设备选择/独占开关等控制 → 状态轮询与 50ms 频谱帧驱动 Canvas 粒子可视化（`music-visualizer.js:102`）。
- **前端播放器主链（歌词与切歌）**：歌词支持本地 LRC 与网易云拉取，逐行滚动并附翻译（`music-lyrics.js`）；曲终预加载下一首实现 gapless（`music-player.js:223-258`，切歌事件竞争抑制见 `music-visualizer.js:130-153`）。
- **持续性**：播放列表/歌单/歌词/封面/引擎设置全部落盘 AppData，重启恢复；引擎随应用生命周期启停（启动预热、退出优雅关闭），播放运行状态不持久。
- **人机与多 Agent 关系**：用户全权控制（窗口/挂件/分享）；Agent 经 MusicController 只能按曲名/歌手匹配播放列表点歌与基础控制，无曲库写权限；`agentMusicControl` 可整体关闭。README"音乐实时被 agent 听到"的实际实现是**曲目元数据注入**——每请求 system 消息注入 `[当前播放音乐：title - artist (album)]` 与播放列表（`vcpClient.js:238-284`），非音频流/频谱转发（全仓无频谱上传给 Agent 的代码）。
- **外部依赖**：WebDAV 服务器（用户自备）；引擎纯本机，无后端依赖；`MusicController` 工具分发走 VCP 服务器但不依赖其能力。
- **声明核对**：README §专业级音频引擎/音乐播放器多项声明与代码不符：①"DSD 256bit 硬解码"——引擎内 grep `dsd|dsf` 零命中，Symphonia 亦无 DSD 解码，`声明不符`；②"AI 歌词创作（听歌识曲生成 .lrc）"——歌词仅单源网易云拉取（`modules/lyricFetcher.js:46-62/:187`），无 Agent 听歌生成路径，`声明不符`；③"多源云端歌词库"实为单源；④README 技术栈仍写"Python 音频引擎依赖"，引擎已是 v2.0.0 全 Rust（`Cargo.toml`、`main.rs:29-30`），README 陈旧。
- **独特性判断**：AIO Hub、SillyTavern 等同类没有"聊天内 Agent 可控点歌 + 桌面挂件 + WASAPI 独占 + 自研 DSP 链（FIR EQ/IR 卷积/EBU R128/SoX VHQ + 无锁音频线程）"的组合；它是 VCPChat"AI 原生桌面运行时"的又一旁路子系统。归入"创作工作站/媒体"聚类（与 ComfyGen、Loom 并列），或单列"本机媒体播放器"能力族。
- **证据强度**：引擎（约 50 个 Rust 文件）、前端、IPC 与 Agent 工具链全部静态走通；`audio_engine/` 为编译产物，未确认与源码一致；WASAPI 独占实际生效、DSP 听感、WebDAV 播放、频谱渲染与 gapless 切歌未运行验证。Git 历史中引擎整体在 `3f14e93`（2026-07-26）一次性落地，无演进轨迹可查。

### 能力卡 14：划词小助手（Rust 桌面感知引擎）

- **用户目标**：在任意应用的任意文本上划选即可唤出悬浮动作条（翻译/总结/解释/搜索/配图），用内部 Agent 处理并回话，无需离开当前工作窗口；这是"系统级文本感知 + AI 处理"的旁路产品面。
- **入口与触发者**：设置开启全局文本监听后，由系统级划选事件（左键拖选）触发。Rust sidecar `assistant_core_server`（actix-web，端口 63791，`rust_assistant_engine/src/main.rs:16-21`）经 Windows UIA（`uia_selection_provider.rs`）/macOS/Linux 捕获选区，经 stdout `ASSISTANT_EVENT` 桥接回主进程（`modules/assistant/assistant-rust-adapter.js:88-108`）。
- **完整主链**：主进程 `processSelectedText`（`modules/ipc/assistantHandlers.js:215-345`）→ 悬浮动作条 → 点击动作（`assistant-action`）→ 独立对话窗口（复用 messageRenderer 流式渲染），会话保存为真实 Agent 话题（`assistant.js:107-119`）；也支持"分享到笔记"。悬浮条/窗口/动作/分享的定位如下：
  - 悬浮条：`assistant-bar.html`（`:1049`）
  - 独立对话窗口：`assistant.html`（`:1115`）
  - 动作分发：`assistant-action`（`:1291-1320`）
  - 分享到笔记：`:1298-1308`
- **事实对象**：配置 `AppData/rust-assistant-config.json`（whitelist/blacklist/guard rules，`assistantHandlers.js:74/:449-452`）；会话走真实 Agent 话题持久化。
- **持续性**：守护进程随应用启停（启动/恢复/崩溃拉起，`assistantHandlers.js:489-638`）；配置与话题落盘。
- **声明核对**：README §划词小助手——"全域右键呼出"实际只跟踪左键划选（`windows_event_source.rs:33`），`声明不符`；"文件夹工作区模式"未找到实现（grep 零命中），`声明不符`；悬浮动作条、全局文本监听、独立对话窗口、分享笔记均 `主链确认`。
- **独特性判断**：聊天客户端内置 Rust 系统级文本感知 sidecar（三平台 capture + Windows UIA 选区监听），同类客户端未发现同等方案；归入"人类工具面/桌面感知"聚类。
- **证据强度**：Rust 捕获链、事件桥接、悬浮条与对话窗口为源码事实；真实划选触发、UIA 选区读取与三平台行为未运行验证。

### 能力卡 15：Scriptorium 共笔文坊（面向 AI 操作的多模态文档与演示工作台）

- **用户目标**：在同一工作台内完成"人类直接编辑渲染后的文档版式 + Agent 理解、查看并可审阅地修改同一份源码"的富文档/演示创作。它不是为传统 Office 文件外挂聊天窗口，而是以 VDOC 工程模型承载可阅读、可编辑和可运行的内容；VDOCX 为连续流文稿，VPPTX 为逐页演示，工程容器用 `document.json` 与 SHA-256 内容寻址资源组织（`ScriptoriumModules/README.md`、`vdoc-container.js`）。
- **入口与触发者（用户侧）**：托盘应用栏"文坊"经 `trayManager.js:26` 的 `vchat-app-scriptorium` 触发 `open-scriptorium-window` 打开独立窗口（`desktopHandlers.js:779-781`，映射到 `WINDOW_APP_IDS.DOCX='docx-editor'`）。
- **入口与触发者（IPC 注册与格式）**：主进程 `docxHandlers.initialize`（`main.js:1083-1092`）注册文档打开/保存/导入/导出 IPC（`modules/ipc/docxHandlers.js`，1,091 行）：管理 `.vdocx/.vpptx` 工程，导入支持 HTML/MD/TXT/RTF/DOCX/PPTX，导出 HTML/PDF；窗口 preload 见 `preloads/docx.js`（`PRELOAD_ROLES.DOCX`）。
- **入口与触发者（Agent 侧）**：`ScriptoriumCollaborator` direct 插件（`VCPDistributedServer/Plugin/ScriptoriumCollaborator/`，Service 818 行 + manifest，版本 2.1.0）经 `ScriptoriumAgentControlService`（`modules/services/scriptoriumAgentControlService.js`，428 行）操作当前窗口文档。
- **事实对象（两类真源）**：工程位于 `AppData/ScriptoriumDocument/VDOCX|VPPTX/`。VDOCX 的唯一真源是 Markdown-first 的 `markdown-hybrid` 文稿与独立 document CSS，可原生保留 HTML、LaTeX、Mermaid 和可编程岛；VPPTX 的每页则是一份完整 HTML Scene，另有共享 deck CSS（`ScriptoriumModules/README.md`、`plugin-manifest.json:45-62`）。两者都不把渲染 DOM 作为保存对象。
- **事实对象（文脉）**：**文脉（版本上下文）是工程数据**——人类刻点与 Agent PR 以五态（`pending/applied/rejected/conflict/failed`）进入同一条文脉，含操作元数据、changeSet、工程内嵌版本快照与审批回执；文脉可回溯，回溯前自动保存且不删后续文脉。
- **Agent 的观察面**：ScriptoriumCollaborator 先提供文档信息、渲染文本、分层目录、单章/源码检索和当前视口附近源码，因而长文档可按目录和章节读取，而不必把全文一次塞入上下文（`ScriptoriumCollaboratorService.js:565-631`、`plugin-manifest.json:25-57`）。`GetVisualContext` 另外返回 OpenAI content 数组，其中同时含 Markdown 语义摘要与实际 viewport 或指定演示页的 base64 截图；这才是它区别于只暴露 Markdown 的编辑器的 AI 多模态查看面（`ScriptoriumCollaboratorService.js:633-654`、`plugin-manifest.json:60-62`）。
- **完整主链（Agent 编辑）**：Agent 先读取 revision、结构、源码或截图，再按追加、插行或精确替换提交 `SubmitSourcePr`。请求带 Agent 署名与 expected revision，先在窗口侧生成 PR，由人类或预设 UI 自动允许策略决定 applied、rejected、conflict 或 failed；超时也只保留提案，不会静默改写文档（`ScriptoriumCollaboratorService.js:784-806`、`plugin-manifest.json:70-72`）。已应用修订和审批回执进入工程文脉，形成可回溯的协作记录。
- **创建与演示操作**：`CreateProject` 可以在不替换当前窗口的前提下直接落盘新的 VDOCX 或 VPPTX 工程；PPTX 另有 AddSlide、InsertSlide 和演示场景配置 PR。页面的完整源码可含样式、资源声明和交互脚本，运行时以注入的 scene 根限定页内查询（`ScriptoriumCollaboratorService.js:890-910`、`plugin-manifest.json:75-97`）。
- **多模态与运行时边界**：工程可管理图片、视频和音频资源，VDOCX 还支持公式、SVG、对象锚点与 Mermaid；需要 Canvas、WebGL、动画或长期交互身份的内容必须放入有稳定 ID 的可编程岛。派生的 KaTeX DOM、Mermaid SVG、Canvas、截图和编辑标记都不回写成源内容（`ScriptoriumModules/README.md`、`scriptorium-media.js`、`scriptorium-programmable-content.js`）。
- **导入、阅读与导出**：导入接受 HTML、Markdown、TXT、RTF、DOCX 和 PPTX，并将 Office 格式转换为新的 VDOC 工程，不承诺像素级原位编辑；导出可生成连续流或分页 HTML、PDF，资源会被本地化，演示导出物可脱离编辑器独立阅读或放映（`modules/ipc/docxHandlers.js:870-916/:1125-1192`、`scriptorium-export.js`）。
- **证据与边界**：源码确认了 UI、工程持久化、Agent 端口、PR/文脉、导入导出和截图返回的完整静态链。`tests/重构中禁用脚本/` 内有 hybrid compiler、importer、容器、协作者、资源本地化和 VPPTX 的测试/冒烟脚本，但尚未纳入测试命令；本次没有运行真实编辑、媒体播放、截图、PR 审批或 Office 导入导出。

### 能力卡 16：受管启动、恢复与图形安装器（fb66a52 → HEAD 范围）

- **用户目标**：让源码版桌面应用在依赖缺失、原生模块不匹配、启动失败或更新中断时给出可解释的诊断和恢复路径，并把更新从工作树原地修改中分离出来。现有 `npm start`、BAT 和 VBS 入口保持原样；新入口是附加的托管工作流（`scripts/vcpchat.mjs:4-9`、`scripts/vcpchat-bootstrap.mjs:9-25`）。
- **入口与对象**：开发者可用 `npm run vcpchat`，图形入口在 Windows/macOS/Linux 分别由 `launchers/VCPChat-Launcher.vbs`、`VCPChat-Setup.command` 和 `VCPChat-Launcher.sh` 定位 Tauri 安装器或恢复界面。核心状态并不写进聊天数据：启动 operation、ready 记录、修复日志、版本指针和锁都按项目根目录映射到独立 state root，避免同 lockfile 的不同 clone 共用状态（`modules/bootstrap/launch-protocol.js`、`scripts/vcpchat-dev-launcher.mjs:154-165`）。
- **完整主链（启动与修复）**：托管入口先运行只读 Doctor；通过时写 completion marker 并启动 Electron，失败时只输出有预算的 repair plan。只有 `--repair --yes` 或图形界面中的明确确认才执行修复；修复结束再次 Doctor，失败则停止并转向恢复界面（`scripts/vcpchat.mjs:103-164`）。启动器获取 operation lock 后启动 Electron，必须收到同 operation、同 PID、主窗可见且 preload/renderer 都 ready 的记录才将所有权交回应用；超时、崩溃和已运行实例各有独立结果（`scripts/vcpchat-dev-launcher.mjs:77-128`、`:168-308`；`main.js:315-398`）。
- **恢复、取消与资源边界**：恢复 UI 经独立 Electron 进程呈现修复计划和结构化进度，取消信号传给受管子进程树；平台层在 Windows 走 `taskkill /T`，在 POSIX 使用 detached process group 的终止策略（`bootstrap/recovery-main.cjs`、`modules/bootstrap/platform-process.js`）。修复清单以 lockfile 为身份基准，用 `npm ci` 与定向 native rebuild，Rust 或 vendor 修复保持 opt-in（`modules/bootstrap/repair-planner.js`、`tests/vcpchat-managed-bootstrap-m3-m8.test.mjs:23-94`）。
- **更新与本地修改语义**：CLI 更新下载必须是 HTTPS、同源重定向、签名 manifest 和完整文件闭包校验；下载可用 `.part`/Range 续传，候选版本经 staging、磁盘/路径/symlink/hash 校验、ready 健康检查后才原子切换 current 指针，失败自动回滚（`scripts/vcpchat-update.mjs`、`modules/bootstrap/update-downloader.js`、`modules/bootstrap/update-manager.js`）。Tauri 安装器的源码更新先检查 upstream；有本地修改时须由用户选择命名 stash，更新仅允许 fast-forward，随后按记录的 stash OID 恢复。恢复冲突或更新后 Doctor 失败时，修改仍保留在可恢复的 stash 中（`apps/bootstrap-installer/src-tauri/src/lib.rs:290-380`、`tests/vcpchat-installer-git-update.test.mjs:68-123`）。
- **证据与边界**：`npm run test:bootstrap` 的 46 项契约测试全部通过，覆盖锁、Doctor、显式修复、取消、跨平台进程边界、运行时闭包、签名下载、健康检查与回滚。`npm run test:installer-contract` 的 17 项中 16 项通过；失败的是 `main.js` ready 发布顺序的静态正则断言，源码仍存在 publish 调用（`main.js:364-368`），因此这只能证明测试断言与当前排版脱节，不能替代 Electron/Tauri 实机验证。Windows/Linux 安装、签名/公证、生产公钥分发、真实网络故障与长时更新均未运行确认；它是 Hermes-inspired 实现，不等同于已完成签名发布的独立产品安装器。
## 补查的旁路产品面与提案建议

本表记录上轮排除（音频引擎、主题系统、论坛、骰子）与未覆盖区域（笔记、翻译、语音、TTS、RAG、任务、VchatManager、日志、划词小助手）的补查结果。除能力卡 13/14 外，其余模块按证据强度分级：

| 模块 | 状态 | 关键证据 | 提案建议 |
|---|---|---|---|
| 双语混合朗读引擎（TTS 族） | `主链确认` | `modules/SovitsTTS.js:372-424` 正则切片主/副语言 → 双模型分流（`:454-455`）→ 队列预合成 + 缓存 `AppData/tts_cache`（`:13`）；`VChatAutoTTS` 插件 MutationObserver 自动朗读（`plugin.js:94-111`） | 建议提案：语音聚类辅助/主贡献 |
| VCPSuperDice 3D 物理骰子 | `主链确认` | `assets/dice-box` ammo.wasm 物理投掷（`Dicemodules/dice.js:81-97`）→ 结果回传 Agent（`diceHandlers.js:94-149`、`VCPDistributedServer.js:689-694`）；"十多种主题/物理施法"为 `声明不符`（仅 default 主题、无施法参数） | 辅助贡献候选 |
| VCP Forum 论坛客户端 | `主链确认` | 后端 `admin_api/forum`（Basic Auth）；前端 masonry 卡片 + CSS 作用域隔离 + KaTeX 数学保护（`Forummodules/forum.js:308-414/:887-1132`） | 与 VCPToolBox 论坛跨仓库合并计数（同一事实对象） |
| RAG Observer 信息流监听 | `主链确认` | `--rag-observer-only` 启动（`main.js:157/:558`）→ WS 连 :5890（`RAGmodules/rag-observer-config.js:22-23`）→ 透明浮层实时展示 RAG/通知 + 工具审批 approve/reject（`ragHandlers.js:157-201/:490-493`） | 辅助贡献候选 |
| 语音聊天（Voicechat） | `主链确认` | Puppeteer 启动 headless Chrome（`modules/speechRecognizer.js:104-113`）→ `webkitSpeechRecognition`（`recognizer.html:101-105`）→ `exposeFunction` 桥接回 Electron；会话落盘为真实 Agent 话题（`voicechat.js:131-149`） | 工程方案独特，产品贡献一般；可作辅助 |
| 笔记系统（Notes + 迷你便签） | `主链确认` | `AppData/Notemodules` 本地文件 + 网络目录挂载扫描缓存（`notesHandlers.js:26-45`）；`Win+Alt+Z` 全局便签（`main.js:1147-1149`） | 归"协同工作区"聚类（与 Canvas 并列），不单独提案 |
| 翻译窗口 | `主链确认`（功能常规） | 渲染层直连 VCP chat completions（`Translatormodules/translator.js:277`），快/均衡/质量三档 | 不提案（通用能力） |
| 主题系统 | `骨架/声明不符` | 选择器主链完整（`themeHandlers.js:50-105`）；"自然语言主题生成器（主题管理 Agent）"grep 零命中未接线 | 不提案 |
| Agent 任务台（Agenttaskmodules） | `入口确认` | 后端 `agent-assistant`/`task-assistant` 插件的管理 UI（`task.js:253-256`，admin_api） | 不提案（外部后端） |
| VchatManager | `入口确认` | 独立运维应用；亮点=配置/文件系统一致性检查修复（`consistency-checker.js`） | 不提案（运维工具） |
| VCPLog 日志中心 | `入口确认` | HTTP 轮询增量拉取（`Logmodules/log.js:219-231`），非 README 声称的 WebSocket | 不提案（WS 声明不符） |
| lyricFetcher / weatherService / modelUsageTracker | `骨架` | 歌词=网易云单源（`lyricFetcher.js`）；天气=后端 `admin_api/weather` 卡片；用量统计=`model_usage_stats.json` | 不提案（常规小工具） |

## 已归并到现有类目的能力

- **Agent 群聊三种发言模式（候选 10）**：`Groupmodules/modes/{sequentialMode,natureRandomMode,inviteOnlyMode}.js` 的策略注册表与完整判定逻辑已由[对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 8.1 节主链确认（sequential 全员轮发、naturerandom 的 @提及/tag 权重/保底发言者、invite_only 按钮驱动）。补充的群组长期状态交点：群聊消息由 `groupchat.js` 作为历史单一真源落盘（`:531/:539`），assistant 消息快照 `agentId/model/modelSource`（`:950`）；群聊上下文同样应用 VCPChatTarven 注入与正则。
- **Canvas 协作（候选 11 的已实现部分）**：Canvas 窗口与聊天主窗口的文件级同步（chokidar watcher → 行级 diff → 接受/拒绝）、内存版本快照等已由[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 深入覆盖（G3 为主、G4 部分）。补查结论：Canvas 是"单用户双窗口"同步（`canvasHandlers.js:93-105` 只向 canvas 窗口与主窗口广播），没有网络级多人协同协议；"与群文件区实时同步"未找到代码。
- **VCP 日记渲染与认知可见性（候选 7）**：`<<<DailyNoteStart>>>…<<<DailyNoteEnd>>>` 协议块的渲染（创建卡/更新替换预览）已由[消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 覆盖（`messageRenderer.js:311/:941-1005`，text-viewer 同步实现）；日记"模型回流"（DailyNote 工具结果通知渲染，`modules/notificationRenderer.js:150-216`）与对象管理（Memo 窗口）在本笔记能力卡 2 承接，不重复计数。
- **跨聊天消息转发入口（候选 14 的入口部分）**：右键转发入口已由 [Chat UI 调查笔记](../Chat%20UI/VCPChat-ChatUI调查笔记.md) 第 6 节记录，本卡补齐完整内容链（见能力卡 9）。
- **VCPDesktop 渲染与流式**：桌面推送的渲染器侧（消息内占位卡）、流式拦截、挂件源码编辑（Canvas 上下文打开）已由运行时笔记覆盖，能力卡 3 只补持久化/恢复/资源治理。

## 声明不符、外部依赖与暂缓项

- **群文件、共享工作区与协同编辑（候选 11）**：README 声称"为每个群组提供专属共享文件空间和工作区，支持实时协同编辑"。检查范围：全仓库 grep `群文件/GroupFiles/groupFiles/group-files` 零命中；群聊的"文件共享"实际是消息级附件（`attachments` 数组挂 user 消息，`groupchat.js:532`、`grouprenderer.js:1221-1285`），群成员通过历史可见；"协同编辑"仅存在于单用户 Canvas 双窗口场景。判定：群文件/共享工作区/群内协同编辑为 `声明不符`（未实现）。
- **ST 预设、角色卡、世界书与可视化注入（候选 9）**：README 声称"完全兼容并支持挂载 SillyTavern 的预设、角色卡和世界书，可直接创建和管理"。检查范围：`Promptmodules`（三种系统提示词模式：原始/积木块/预设文件）是 VCPChat 自己的提示词编辑器，无 ST 角色卡/世界书格式；全仓库 grep `世界书/WorldBook/角色卡/CharacterCard` 无前端实现命中；唯一确认的 ST 兼容入口是正则脚本导入（`regexHandlers.js:36-55`）。VCPToolBox 管理面板存在 `VcptavernEditor`（见 VCPToolBox Chat UI 笔记），判定：VCPChat 前端 `声明不符`，相关能力在外部仓库，暂缓归因。
- **分布式多模态文件追踪与跨模态转译（候选 15）**：节点侧主链已确认——主服务器经 `execute_tool` 工具发起（internal_request_file），节点 `VCPDistributedServer.js:605-644` 把 `file://` URL 转本地路径读取并返回 base64 与 mimeType；其中 `:606` 的 FileFetcherServer 新协议注释表明与后端联动。"全 URL 超栈追踪"与"高阶模型对低阶模型能力转译"的主服务器逻辑在 VCPToolBox，本仓库无实现；判定：节点侧 `入口确认`，完整闭环 `暂缓`（外部依赖）。
- **跨端记忆（候选 12 的记忆部分）**：README"跨端记忆"描述的是以 VCP 后端为中心的统一记忆库，VCPMobileSync 同步范围明确不含记忆（其 README 同步类型表只有 Agent/Group/Topic/Message/Attachment(不实际)/Avatar）；判定：记忆同步 `暂缓`（外部后端），消息/元数据同步 `主链确认`。
- **Agent 自主管理 Topic 的"前端刷新"（候选 8 补充项）**：TopicSponsor 创建话题后，普通话题在侧栏的即时出现机制未找到 watcher/事件证据（前端重读 config 而非订阅）；Flowlock 话题有明确的认领轮询。该项保留为未验证，不判不存在。
- **音频引擎"DSD 256bit 硬解码"（能力卡 13）**：引擎全量源码 grep `dsd|dsf` 零命中，Symphonia 无 DSD 解码支持；README §专业级音频引擎的 Hi-Res 声明不成立。
- **"AI 歌词创作（听歌识曲生成 .lrc）"与"音乐实时被 agent 听到"（能力卡 13）**：歌词仅单源网易云拉取，无 Agent 听歌生成路径；Agent 得到的是曲目元数据注入（`vcpClient.js:238-284`），非音频流/频谱转发。
- **TTS"流式剪枝算法 600% 加速"（README §语音朗读）**：`SovitsTest/GSVI.py`、`my_infer.py` 仅为 OpenAI 兼容 HTTP 封装，无剪枝算法代码；双语混合朗读为真，加速数字为 `声明不符`。
- **主题系统"自然语言主题生成器"（README §强大的主题系统）**：grep `主题管理/themeGenerator/ThemeAgent` 零命中，仅手动 CSS 主题选择器可用。
- **骰子"十多种主题"与"物理施法"（README §Vchat超级骰子插件）**：`assets/dice-box/themes/` 仅 default 一个主题；插件参数仅 notation/themecolor，无打滑/黏着/磁铁施法入口。
- **划词小助手"全域右键呼出"与"文件夹工作区模式"（能力卡 14）**：Rust 侧仅跟踪左键划选；文件夹工作区 grep 零命中。
- **笔记"Obsidian 类云端同步"与"分享笔记到 AI 知识库"（README §笔记模块）**：实际为网络目录挂载 + 扫描缓存（`notesHandlers.js:26-45`），无同步协议；知识库分享未找到对应代码。
- **VCPLog"通过 WebSocket 连接"（README §VCPLog 集成）**：日志中心为 HTTP 轮询（`log.js:219-231`）；WS 连接实际属于 RAG Observer。

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
- **新增主贡献候选**：
  10. VCP Hi-Fi 音频引擎与音乐播放器——本机媒体/创作工作站聚类（能力卡 13；与 ComfyGen、Loom 并列为一个媒体能力族合计，还是单列，取决于横向统计口径，建议与 VCPToolBox 媒体插件族不重复计"生成"）；计入前提：以 `主链确认` 静态证据计，注明引擎为编译产物未验证；
  11. 划词小助手（Rust 桌面感知引擎）——人类工具面/桌面感知聚类（能力卡 14）。
- **b6ffa22 → fb66a52 范围新增**：12. Scriptorium 共笔文坊——创作工作站/文档协作聚类（能力卡 15；Loom v1.4.0 升级计入既有 Loom 项，不重复计数）。
- **fb66a52 → HEAD 范围新增**：13. 受管启动、恢复与图形安装器——多表面连续性/交付工作流聚类（能力卡 16）。它的用户价值是可恢复的桌面交付流程；更新与修复的可靠性机制单独标注，不与聊天能力混合计数。
- **辅助贡献**：跨聊天消息转发与附言（Chat 工作流）；前端插件注册/注入机制（工程机制，单独标注）；双语混合朗读引擎（语音聚类）；3D 物理骰子与 RAG Observer 信息流监听（视统计口径可选）。
- **不计入**：群文件/共享工作区、ST 预设/角色卡/世界书（前端）、跨模态转译闭环、"跨端记忆"本体、主题生成器、DSD 硬解码、AI 歌词创作、音乐实时听音、TTS"600% 剪枝"（均为声明不符）。
- **机制贡献（单独标注，不与产品特性混分）**：正则与 Tavern 规则的安全屏蔽、Flowlock generation 防复活、VCPMobileSync 的原子写/墓碑/稳定哈希、挂件资源治理（定时器/监听器清理、性能打点、可见性冻结）、HumanToolBox 的 IPC 白名单与路径校验、音频引擎的路径穿越/SSRF 防护与无锁音频线程（assert_no_alloc 审计）、语音聊天的 Puppeteer 桥接方案。

## 未验证事项

1. 全部结论为静态分析，未运行应用：Tavern 注入在真实请求中的行为、Memo 云图渲染与后端联想算法、挂件桌面渲染与动画冻结效果、Flowlock 后台心跳续写与跨 Topic 交接、工作流编辑器执行与保存加载、ComfyUI 连接与模板转换、LoomAPP 运行与隔离、移动同步握手与吞吐、TopicSponsor 与前端认领对接。
2. 音频引擎：`audio_engine/` 编译产物与 `rust_audio_engine` 源码的一致性未确认；WASAPI 独占模式实际生效、DSP 链听感、FIR EQ/IR 卷积效果、WebDAV 远程播放、频谱可视化与 gapless 切歌行为均未运行验证；引擎在 Git 历史中仅 `3f14e93` 一次落地，无演进轨迹可核对。
3. 划词小助手：Rust sidecar 的真实划选触发、Windows UIA 选区读取与三平台行为未运行验证。
4. README 声称的"content 数组正则"作用点未定位到实现（`applyFrontendRegexRules` 与上下文路径均只处理字符串）。
5. 独立"气泡评论"（评论附加在原始消息下方并持久化）未找到实现，仅确认转发对话框内的附加评论字段。
6. 工作流编辑器的工作流落盘格式与位置未核实；README §8 与代码的矛盾以代码为准，但"哪一版是预期行为"未确认。
7. TopicSponsor 普通话题的前端即时刷新机制未核实。
8. VCP-CDS（Rust）的中央索引模式仅确认了适配层与测试存在，未核实其查询/Change Feed 的完整行为。
9. 两个渲染器前端插件（动态壁纸、自动 TTS）仅确认注册与加载机制，插件本体 UI 行为未验证；VChatAutoTTS 的双语自动朗读触发链为源码事实，合成效果未验证。
10. `tests/` 顶层现有 7 个文件（frontend-plugins、loom-controller、loom-electron-adapter、loom-manager-runtime、deepmemo-central-adapter、mobile-sync-central-adapter 六个测试 + test-export-inline.cjs），另有 `tests/重构中禁用脚本/` 子目录 12 个 scriptorium 测试/冒烟脚本（目录名自述"重构中禁用"，未纳入运行）；Flowlock 等核心模块无自动化测试覆盖；音频引擎未见测试目录。
11. 受管启动与安装器未运行 Electron、Tauri、签名安装包或真实网络更新；`test:installer-contract` 的 ready 发布顺序静态断言在当前 `main.js` 失败（16/17 通过），需以修正断言后的测试和实机 handoff 结果补证。

## 关键源码索引

- `Tavernmodules/tavern-manager.js`：高级回复浮窗与规则管理模态；`modules/tavernRulesEngine.js`：三类注入纯逻辑引擎；`modules/ipc/tavernHandlers.js`：`VCPChatTarven.json` 持久化与 IPC。
- `modules/chatManager.js:188-233/1085-1130`：单聊 Tavern 注入与上下文正则应用点；`Groupmodules/groupchat.js:510-539/605-608/736/1189/1308`：群聊注入路径与历史真源。
- `Memomodules/memo.js`（apiFetch/工作台/批量操作）、`memo-graph.js`（联想与力导向图）、`memo-workbench.js`（引用工作台与 DailyNote 发布）。
- DeepMemo 2.0：`VCPDistributedServer/Plugin/DeepMemo/DeepMemoService.js:42-126`（工具入口、可信上下文、中央搜索、可选精排与预算筛选）、`:135-205`（参数规范化与 VCP-CDS 请求构造）；`Plugin/DeepMemo/README.md`（central 适配边界与上下文上传协议）；`tests/deepmemo-central-adapter.test.js`（适配层测试）。
- `Desktopmodules/favorites/favoritesManager.js`、`core/widgetManager.js`、`core/performanceManager.js`、`core/visibilityFreezer.js`；`modules/ipc/desktopHandlers.js:40/212/948/999/1228`。
- `Flowlockmodules/flowlock.js`（Session 状态机与认领）、`flowlock-integration.js`（用户操作绑定）、`flowlock-protocol.js`（状态气泡）；`Flowlockmodules/README.md`（协议与生命周期权威文档）。
- `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`：Agent 自主话题命令族。
- `VCPHumanToolBox/`：`renderer_modules/config.js`（工具定义）、`renderer_modules/tool-manager.js`（插件导入与参数解析）、`WorkflowEditormodules/WorkflowEditor_ExecutionEngine.js`（工作流执行）、`ComfyUImodules/ComfyUI_UIManager.js`（ComfyGen 面板）；`VCPHumanToolBox/README.md` §8（与代码矛盾的陈旧说明）。
- `VCPDistributedServer/frontend-plugin-loader.js` + `modules/ipc/desktopHandlers.js:96-120`：前端插件注册与注入；`modules/loom/VCPLoomManager.js`（2,076 行）+ `modules/loom/webcore/*` + `VCPDistributedServer/Plugin/LoomController/`（1.4.0）：LoomAPP 运行时、WebCore 页面感知与动作命令。
- Scriptorium：`ScriptoriumModules/`（scriptorium.js/scriptorium.html/vdoc-hybrid-compiler.js/vdoc-core.js 等，README.md 为权威说明）、`modules/ipc/docxHandlers.js`、`modules/services/scriptorium{AgentControl,Import,PptxImport}Service.js`、`VCPDistributedServer/Plugin/ScriptoriumCollaborator/`、`preloads/docx.js`、`main.js:1083-1092`（初始化）；`tests/重构中禁用脚本/`（12 个测试/冒烟脚本）。
- 受管启动与安装：`scripts/vcpchat.mjs`（诊断/显式修复入口）、`scripts/vcpchat-bootstrap.mjs`（命令分发）、`scripts/vcpchat-dev-launcher.mjs`（operation lock、ready 与 handoff）、`scripts/vcpchat-update.mjs`（版本更新）、`modules/bootstrap/`（Doctor、修复、运行时闭包、进程边界、下载与回滚）、`bootstrap/`（恢复 UI）、`apps/bootstrap-installer/`（Tauri 图形安装器）、`launchers/`（三平台图形入口）、`tests/vcpchat-{bootstrap,managed-bootstrap-m3-m8,platform-boundary,installer-contract,installer-git-update}.test.mjs`。
- `VCPDistributedServer/Plugin/VCPMobileSync/`（manifest/diff/message/central）与 `rust_chat_data_service/README.md`：跨端同步与中央索引。
- `VCPDistributedServer/VCPDistributedServer.js:605-644`：节点侧 `internal_request_file` 文件拉取；`:656-687`：MusicController 工具注入调用；`:689-694`：SuperDice 注入调用。
- `modules/renderer/messageContextMenu.js:211-220` + `renderer.js:2426-2564` + `modules/chatManager.js:1607-1651`：转发与附言主链。
- `rust_audio_engine/`：`main.rs`（入口与端口 63789）、`server.rs`（HTTP 路由与路径/SSRF 防护）、`server/playback.rs`、`server/effects.rs`、`server/ws_handlers.rs`（频谱/事件 WS）、`server/webdav_handlers.rs`、`decoder.rs`（Symphonia f64 解码）、`wasapi_output.rs`（WASAPI 独占）、`player/`（audio_thread/callback/gapless/state）、`processor/`（eq/fir_eq/convolver/crossfeed/loudness/resampler/saturation/dsp_chain/lockfree_params）；`audio_engine/`：部署二进制与 `IRPreset/`；`settings.rs:257`：`AppData/audio_settings.json`。
- `Musicmodules/`：`music.js`（窗口装配与事件）、`music-player.js`（gapless 与播放逻辑）、`music-effects.js`（EQ/响度/饱和等效果面板）、`music-visualizer.js`（WS 频谱可视化）、`music-webdav.js`（远程曲库）、`music-lyrics.js`（LRC 解析滚动）；`modules/ipc/musicHandlers.js`（引擎代理与播放列表/歌词/IR 管理）；`modules/webdavManager.js`；`modules/lyricFetcher.js`（网易云单源）；`Desktopmodules/builtinWidgets/musicWidget.js`（桌面音乐条）。
- 划词小助手：`modules/assistant/assistant-rust-adapter.js`（sidecar 启动与 `ASSISTANT_EVENT` 桥接）、`modules/ipc/assistantHandlers.js`（悬浮条/对话窗口/动作分发）、`rust_assistant_engine/src/`（capture/windows_event_source/uia_selection_provider/metrics）。
- 旁路模块入口：`modules/SovitsTTS.js:372-424`（双语切片）、`WebIndexTTS2/server.js`（IndexTTS-2 云端代理）、`Dicemodules/dice.js` + `assets/dice-box`（3D 物理骰子）、`Forummodules/forum.js`（论坛渲染链）、`RAGmodules/rag-observer-config.js` + `ragHandlers.js`（信息流监听与审批浮层）、`Voicechatmodules/voicechat.js` + `modules/speechRecognizer.js`（Puppeteer 识别）、`Notemodules/notes.js`（笔记主链）、`Themesmodules/themes.js` + `themeHandlers.js`（主题选择器）、`Agenttaskmodules/task.js`（任务台）、`VchatManager/consistency-checker.js`、`Logmodules/log.js`。
