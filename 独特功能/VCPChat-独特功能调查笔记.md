# VCPChat 独特功能调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：汇总现有十类单项目笔记，对十六项候选逐一走读源码主链（入口 → 状态/对象 → 执行 → 用户结果 → 持久化），核对模块注册（`main.html`、`main.js`、IPC handlers、`VCPDistributedServer` 插件目录）与近期 Git 历史；补充音频引擎专项（`rust_audio_engine` 源码 + `audio_engine` 部署产物 + `Musicmodules` + `musicHandlers.js` + MusicController 工具链）与旁路模块补查（划词小助手、主题、论坛、骰子、笔记、翻译、语音、TTS 族、RAG Observer、任务台、VchatManager、日志）；再核对 Loom v2/WebCore 升级与新增 Scriptorium 文坊子系统；本次补查受管启动、恢复、更新和图形安装器链，并运行 Bootstrap 与安装器契约测试；未运行 Electron、Tauri 或真实更新，其他结论以静态分析为主
>
> 调查范围：待查清单中 VCPChat 的全部候选能力 + 音频引擎/音乐播放器专项 + 上轮排除与遗漏的旁路产品面补查；本次覆盖受管启动与安装器的完整主链、更新边界和测试证据；去重边界以现有类目笔记为准（群聊发言模式、Canvas、日记渲染、桌面挂件渲染等已有笔记覆盖的部分只补交点）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 的独特功能候选密集：十六项候选中有十二项达到 `主链确认`，两项为 `入口确认`，两项存在与 README 声明不符或依赖外部仓库的部分。项目的产品辨识度集中在一个事实上：**VCPChat 围绕 VCP 后端协议（VCPToolBox 提供服务）构成一个"AI 原生桌面运行时"**——聊天、桌面挂件、记忆工作台、人类工具面、移动同步和插件系统共享同一套 `AppData/` 文件事实源，由前端私有标记协议与后端工具链驱动。

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
10. **前端插件机制与 LoomAPP 运行时**：`manifest.frontend` 声明插件样式/脚本，主进程扫描后注入主窗口；现有 VChatDynamicWallpaper、VChatAutoTTS 两个渲染器插件；Loom 是 Agent 可创建、管理、注入代码的隔离 WebApp 运行时，现为 **v1.4.0 + VCP Agent WebCore**：页面快照（Grounded Markdown）/页面图片/Web Core 动作执行/串行指令与设备管理（WebHID/USB/Serial/Bluetooth），构成"Agent 可感知、可操作的网页运行时"。
11. **VCPMobileSync 跨端双向增量同步**：三阶段协议（Reconcile → Double-Hash Merkle Diff → NDJSON 流式），冲突按最新时间戳胜出，墓碑拦截防回流；中央索引模式由 `vcp_chat_data_service`（VCP-CDS）承接。
12. **Agent 自主管理 Topic（TopicSponsor）**：分布式插件直接读写 `AppData/Agents|UserData` 创建话题、回复话题、检查所有权/未读，与 FlowLock 的 `CreateFlowlockTopic` 交接构成闭环。

第 13 条 `主链确认` 能力：**Scriptorium 共笔文坊（VCP Scriptorium）**——本地富文档/演示创作空间（VDOCX/VPPTX 工程、DOCX/PPTX/MD/HTML/RTF/TXT 导入、HTML/PDF 导出），人类直接编辑渲染版式，Agent 经 `ScriptoriumCollaborator` direct 插件以"可审阅 PR"（文脉刻点 + 审批回执 + 修订冲突保护）协作编辑源码。详见能力卡 15。

第 14 条 `主链确认` 能力：**受管启动、恢复与图形安装器**。它把源码版 VCPChat 的首次诊断、受控修复、启动就绪交接、可取消恢复、版本目录更新与回滚连为独立工作流；安装器还在源码树有本地修改时提供暂存、仅快进更新和恢复策略。该能力面服务于桌面应用的交付与维护，不改变既有聊天功能或原始启动脚本。详见能力卡 16。

声明不符或依赖外部仓库的项：README 声称的"群文件/共享工作区/协同编辑"在本仓库未找到对应实现；"ST 预设、角色卡、世界书"在 VCPChat 前端无导入与管理入口（后端 VCPToolBox 才有）；"跨模态智能转译/全 URL 超栈追踪"的主服务器逻辑在 VCPToolBox，本仓库只确认节点侧 `internal_request_file` 拉取链；"跨端记忆"的中心记忆库同样位于后端。

新增两条 `主链确认` 能力：**VCP Hi-Fi 音频引擎与音乐播放器**（自研 Rust 解码/DSP/WASAPI 引擎 + Agent 点歌工具 + 桌面音乐挂件 + WebDAV 曲库）与**划词小助手（Rust 桌面感知引擎）**。另补查 11 个旁路模块：双语混合朗读、3D 物理骰子、Agent 论坛客户端、RAG Observer 信息流监听、语音聊天（Puppeteer 方案）、笔记系统达到 `主链确认`；任务台、VchatManager、日志中心为 `入口确认`；主题系统为 `骨架/声明不符`（README 声称的"Agent 主题生成器"未接线）。同时核出 8 项 README 声明与代码不符（DSD 硬解码、AI 歌词创作、音乐实时听音、TTS"600% 剪枝"、主题生成器、骰子多主题/物理施法、划词小助手右键呼出/文件夹工作区、Obsidian 云同步），详见"声明不符"节。

## 介绍声明与候选盘点

根 `README.md` 功能声明密度极高，且多数在近期更新段有明确入口。逐项核对后的状态如下（详细证据见对应能力卡）：

| 候选能力 | 状态 | 关键入口 | 特色统计建议 |
|---|---|---|---|
| 高级回复 / VCPChatTarven 三类注入 | `主链确认` | 发送按钮右键浮窗 + 规则管理模态 | 主贡献（上下文注入族） |
| Memo 神经云图与日记工作台 | `主链确认` | 头部按钮右键打开 Memo 窗口 | 主贡献（记忆工作台族） |
| VCPDesktop 流式推送与持久挂件 | `主链确认` | `--desktop-only` 启动 + DESKTOP_PUSH 协议 | 主贡献（活对象族） |
| FlowLock 主动连续工作 | `主链确认` | 标题右键/中键/Ctrl+G + 内嵌协议 | 主贡献（主动 Agent 族） |
| VCP 人类工具箱与自动 GUI 工作流 | `主链确认`（工具面）/ `主链确认`（工作流编辑器，静态） | 主窗口工具箱按钮启动独立应用 | 主贡献（人类工具面族） |
| ComfyGen 专用创作面板 | `主链确认`（配置管理链） | 工具卡 ⚙ 按钮 → 配置抽屉 | 随人类工具箱族合并计数 |
| VCP 日记渲染和认知可见性 | `归并已有类目`（渲染）+ Memo 卡承接对象侧 | DailyNote 协议块 + Memo 窗口 | 渲染部分不重复计数 |
| Agent 自主管理 Topic（TopicSponsor） | `主链确认` | TopicSponsor 插件 + flowlock 认领 IPC | 主贡献（主动 Agent 族） |
| ST 预设、角色卡、世界书与可视化注入 | `声明不符`（前端） | 仅 ST 正则导入可用 | 不计入 |
| Agent 群聊四种发言模式 | `归并已有类目` | `Groupmodules/modes/` 策略注册表 | 不重复计数 |
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

- **用户目标**：让用户在不改动 Agent 配置和聊天历史的前提下，为每次发往模型的请求临时追加提示词并逐条开关；这套请求级临时设定层是普通聊天客户端缺少的能力。
- **入口与触发者**：用户右键发送按钮打开「高级回复」浮窗，在浮窗内逐条开关规则，齿轮按钮进入「规则管理」模态做新建、编辑、删除与拖拽排序。两个界面与发送时的取规则由同一模块承载（`Tavernmodules/tavern-manager.js:96-819`）。
- **事实对象**：每条规则是一条九字段记录（id、name、type、enabled、content、scope、wrap、role 与 depth），持久化在 AppData 下的 VCPChatTarven.json，读写经两个 IPC 通道，主进程按文件修改时间缓存（`modules/ipc/tavernHandlers.js:94-118`）。
- **完整主链**：右键发送按钮 → 开关或编辑规则 → 主进程写 JSON → 发送时取出当前作用域内的生效规则 → 引擎按类型注入 → 交给 VCP 提交。三种注入、包裹标记与作用域判定都在同一纯逻辑引擎里实现（`modules/tavernRulesEngine.js:27-149`）：

  | 注入类型 | 行为 |
  |---|---|
  | system_suffix | 规则内容追加到系统提示词末尾 |
  | user_suffix | 只追加到本轮提交给 AI 的用户文本副本，历史中不保存 |
  | context_inject | 以独立的 user/assistant 消息插入上下文；depth 为距末尾的位置，0 插到末尾，N 插到倒数第 N+1 条之前，按从大到小排序以避免索引错位 |

- **包裹与作用范围**：包裹标记「[本信息由VCPChat客户端注入]…[临时注入结束]」可由每条规则关闭，关闭后即为裸注入；规则分 global、agent、group 三档，作用域判定决定某个作用域下哪条规则生效。
- **应用点**：单聊、重试与编辑、群聊以及邀约发言的全部发言路径都接入三类注入（`modules/chatManager.js:1311-1360`、`Groupmodules/groupchat.js:518-1308`）；群聊的 user suffix 只改提交副本，历史落原始用户文本，群聊因此不会丢注入。消息右键菜单一侧的接入点见文末源码索引。
- **持续性**：规则文件在重启后恢复；开关改动即时生效，靠修改时间缓存失效实现。
- **人机关系**：用户可在浮窗逐条开关，也可在管理模态里完成全量增删改查；Agent 侧没有写入入口。
- **外部依赖**：渲染进程加主进程文件读写，不涉及后端。
- **独特性判断**：与 SillyTavern 的注入位相比，它是客户端自管理、单聊与群聊统一适配的 VCP 原生实现；与 AIO Hub 的消息配方相比，它保持轻量、不写入历史的临时设定定位。归入上下文注入与 DSL 聚类。
- **证据强度**：引擎、应用点与持久化都在源码中走通；开关热加载与实际请求行为未经运行验证。

### 能力卡 2：Memo 神经云图与日记工作台

- **用户目标**：把 AI 自动记录和整理的日记库做成可视化记忆拓扑，叠加批量整理与整合代笔，成为普通聊天客户端没有的长期记忆管理面。
- **入口与触发者**：主窗口头部按钮右键打开 Memo 窗口，窗口页面 Memomodules/memo.html 由主进程加载，窗口与桌面图标两条入口并存（`main.html:750`、`modules/ipc/windowHandlers.js:372`）；VCPDesktop 的 vchat-app-memo 桌面图标同样可以进入，入口清单见 Desktopmodules/桌面图标与启动API指南.md:33。
- **事实对象**：日记文件由后端 admin_api/dailynotes 管理，按文件夹与思维簇分类；前端不落盘，全部操作经带 Basic Auth 的 REST 调用来回，公共请求封装、文件夹与日记读取、保存、批量删除、移动与语义检索集中在一个前端模块中实现（`Memomodules/memo.js:501-1428`）。
- **完整主链**：
  - 云图：日记卡选「关联」后带上文件夹与 k/boost 参数请求联想发现接口，后端返回联想节点，前端以 Canvas 力导向图呈现（斥力与引力、连线分数、节点卡、多选、缩放平移），节点详情能加载全文并批量加入工作台（`Memomodules/memo-graph.js:71-692`）。
  - 工作台：选中多篇日记后进入 DiaryWorkbench，引用卡片与全文阅读并存，可新建整合日记，发布时把 DailyNote 的 create 命令包装成工具请求经 /v1/human/tool 提交，发布后能把旧日记归档到「已整理」或批量删除（`Memomodules/memo-workbench.js:18-348`）。
  - Agent 代笔与语义搜索：同一条 memo.js 路径也调用 /v1/human/tool，走 LightMemo 与语义检索，结果归一化为可打开的路径，定位并入事实对象一条。
- **持续性**：日记全部由后端持有，前端只持久化隐藏文件夹与排序这类 UI 偏好，配置保存也在上述 memo.js 模块内。
- **人机关系**：用户主导批量编辑、移动与归档；Agent 通过 DailyNote 工具代笔、通过语义检索参与；"模型回流"指模型经 DailyNote 工具写日记，再由 Memo 窗口读回与检索。
- **外部依赖**：admin_api/dailynotes 与 /v1/human/tool 属 VCPToolBox，本仓库只确认请求格式与调用点；云图算法（对称性破缺有序能索引）在后端，前端无法验证其语义。
- **独特性判断**：日记文件本身是后端生态的持久对象，联想云图、工作台与批量编辑的组合只出现在 VCP 系；它与 VCPToolBox 的 TagMemo/RiverMemo 是同一记忆体系的消费端与管理端。
- **证据强度**：入口、API 链、图渲染与批量操作都在源码中走通；后端算法、云图实际渲染与 Agent 代笔结果未经运行验证。

### 能力卡 2A：DeepMemo 2.0 中央会话回忆适配器（主动历史 RAG）

- **用户目标**：让 Agent 通过工具主动查找其他 Topic 中的历史对话，并把命中的上下文窗口带回当前会话；它检索的是聊天历史，不是 Memo 工作台管理的日记文件。
- **入口与触发者**：模型调用 `DeepMemo` 工具后，由 `DeepMemoService.processToolCall()` 接收参数（`VCPDistributedServer/Plugin/DeepMemo/DeepMemoService.js:39-115`）。VCP 主服务器把聊天请求中白名单内的 `requestContext` 复制为内部 `_vcpContext`；模型工具参数不能覆盖其中的 `agentId`、`topicId` 或 `owner` 信息（调用链与上下文上传说明见该插件 README）。
- **事实对象**：VCP-CDS 中央聊天数据服务维护的会话/Topic 历史索引。插件是常驻薄适配器，只消费 `ChatDataServiceClient.searchMemories()`。
- **完整主链**：规范化 `keyword`、窗口大小和结果上限 → 以可信 Agent/Topic 上下文构造中央搜索请求（`DeepMemoService.js:120-190`）→ 默认排除当前 Topic，按前后窗口扩展命中 → 选择性调用外部 Rerank（候选批次有文档数、字符数和超时界限）→ 按字符预算筛选 → 清理 HTML/CSS 后格式化回注当前工具结果；中央服务失败时按配置决定是否使用旧版回退程序。
- **持续性与边界**：索引和聊天历史由 VCP-CDS 持有；适配器自身不持久化记忆，不提供自动生成前注入、递归思考链或人工记忆维护。真实 CDS 搜索、精排效果和跨 Topic 结果未运行验证。
- **横向归类**：这是闭环的主动会话历史 RAG，但产品契约仍接近常规“搜索历史对话”工具；在特色统计中作为 VCP RAG 能力地图的边界样本记录，不另立主/辅助贡献。它与 VCPToolBox F66/F102 的区别在于：DeepMemo 由 Agent 主动调用并返回历史窗口，F66 在生成前自动注入私人语义召回，F102 则把检索组织成可持久、逐阶段演化的思考程序。

### 能力卡 3：VCPDesktop 流式推送与持久挂件

既有 `Agent工具` 与 `生成式输出与运行时` 笔记已确认 DESKTOP_PUSH 流式拦截（`modules/renderer/desktopPushConsumer.js`）、挂件收藏目录 `AppData/DesktopWidgets/<id>/`（`modules/ipc/desktopHandlers.js:999-1095`）与模型侧远程控制。本卡补充运行恢复与资源治理两个面：

- **运行恢复**：收藏挂件时把截图与 HTML 落到挂件目录（`Desktopmodules/favorites/favoritesManager.js:21-73`）；恢复时读回文件、重建挂件并延迟执行内联脚本（`:108-139`），运行状态不入盘，重启后脚本重新执行。收藏列表由目录扫描生成，并自动维护 `CATALOG.md` 索引（`modules/ipc/desktopHandlers.js:212-295`、`:1478-1528`）。
- **资源治理**：挂件沙箱记录自身的定时器与窗口、文档监听器，销毁时统一清理（`Desktopmodules/core/widgetManager.js:552-630`）；性能管理器按周期采样 JS 执行时长与帧数，估算每个挂件的 CPU 占比与 FPS（`core/performanceManager.js:41-143`）；可见性冻结器把不可见区域的壁纸 iframe 与视频动画暂停（`core/visibilityFreezer.js:237`）；另有 zIndex 管理与删除时的兜底处理。
- **证据强度**：恢复与资源治理为源码事实；真实桌面渲染、动画冻结效果与性能数据未经运行验证。

### 能力卡 4：FlowLock 主动连续工作

既有 `Agent工具` 笔记已确认状态机、心跳、重试与完整请求重建。本卡补充（协议文档 `Flowlockmodules/README.md` 与代码一致）：

- **用户可见状态**：Agent 侧栏头像活动状态环、当前标题发光/悦动、心跳脉冲动画（`Flowlockmodules/flowlock.css`）；消息内按协议状态渲染对应气泡（`flowlock-protocol.js:362-366`，`data-vcp-block-type="flowlock"`）。状态字面量：
  ```text
  Start / Stop / Complete / Fail / NextHeartbeat / NextPrompt
  ```
- **用户操作**：右键聊天标题 = 启动（不立即续写）/停止；中键 = 启动并立即续写/停止；`Ctrl+G`（macOS `Command+G`）同中键（`flowlock-integration.js:181-276`）。
- **跨 Topic 接管**：`CreateFlowlockTopic` 由 TopicSponsor 插件创建带 `flowlockRequest`（UUID 请求 ID、pending 状态）的话题，前端在最终回复完整落盘后经 `claimPendingFlowlockTopic` 原子认领并交接 Session（`Flowlockmodules/flowlock.js:169-260`；preload 能力声明见 `preloads/api/flowlock.js`），失败时补偿恢复为 pending；页面重载后枚举恢复，冲突保持 pending。
- **取消与资源上限**：Stop/Complete/Fail 取消定时器并增加 generation 防复活（README 5 节）；心跳延迟钳制在 1–86400 秒（`topicsponsor.js:151-158`）；续写失败默认最多重试三次后自动停止（README 7.4）；协议解析屏蔽工具请求/结果、Desktop Push、元思考链、think 块与代码围栏（README 6.1）；历史渲染只出状态气泡不重放命令（6.2）。
- **证据强度**：协议、状态机与交互绑定为源码事实；后台心跳续写与跨 Topic 交接的完整运行未验证（README 称单元测试通过，本仓库 `tests/` 中未见 Flowlock 测试文件）。

### 能力卡 5：VCP 人类工具箱（人类工具面）与插件 manifest → 表单转译

- **用户目标**：把原本只有 AI 能调用的 VCP 工具以表单化 GUI 开放给人类，使用者不必手写 `<<<[TOOL_REQUEST]>>>`；普通客户端没有把 Agent 工具面投影成人类操作面板的能力。
- **入口与触发者**：主窗口「工具箱」按钮经独立应用启动器打开 VCPHumanToolBox，VCPDesktop 的 vchat-app-toolbox 图标同样可以进入；应用自身注册执行代理通道，主进程侧的启动与路径校验同在一处（`modules/ipc/desktopHandlers.js:114-125/1649`、`VCPHumanToolBox/main.js:276-333`）。
- **事实对象**：工具定义库在 `VCPHumanToolBox/renderer_modules/config.js`，含 46 个出厂工具与 7 种参数 widget 类型；用户导入的工具存于设置项 vcpht_userTools，Config Overlay 的优先级高于出厂定义。
- **完整主链（执行链）**：工具网格 → 按参数 schema 生成表单 → 用户填参执行 → 主进程经执行代理通道拼装工具请求，以 Bearer Token 提交 /v1/human/tool → 渲染文本与多模态结果。
- **完整主链（插件导入链）**：管理 Tab 连接后端 Admin API 取插件清单，解析 manifest 参数（四种格式、三层 fallback），把调用命令适配成 config.js 的格式，再交给可视化表单或 JSON 编辑器修改并持久化（`VCPHumanToolBox/renderer_modules/tool-manager.js:79-413`）。
- **持续性**：用户工具随 AppData/settings.json 持久化；Admin 连接配置存 localStorage。
- **安全边界**：窗口开启 contextIsolation、关闭 nodeIntegration，preload 只放行 12 个 IPC 通道，路径经插件目录解析校验（同一份 IPC 文件）。
- **外部依赖**：工具执行由 VCPDistributedServer 与后端负责；应用 README 说明它不承担权限管理。
- **证据强度**：源码事实；表单实际交互与真实工具执行未经运行验证。

### 能力卡 6：工作流编辑器（节点编排与执行引擎）

- **用户目标**：把多个 VCP 工具调用编排成可保存、可复用、可逐步执行的节点工作流。
- **入口与触发者**：HumanToolBox 顶部「工作流」按钮调用编辑器打开函数（`VCPHumanToolBox/renderer.js:1637`），由简化加载器动态加载编辑器模块，模块资源已在页面中预加载（`VCPHumanToolBox/index.html:52-67`）。
- **事实对象**：画布用 jsPlumb 承载节点与连接，节点分 VCPChat 插件、VCPToolBox 插件与辅助节点三类，位置、配置、连接与拓扑分层都由 StateManager 管理。
- **完整主链**：拖拽建立节点与连线后点执行（`WorkflowEditormodules/WorkflowEditor_UIManager.js:2468-2522`），进入执行引擎：先做环检测与预飞行检查，再按分层拓扑让同层节点并发执行并受并发上限限流，错误策略可选停止或继续；插件节点构造工具请求调 /v1/human/tool（含智能命令匹配），结果归一化后存入节点结果对象并传播到下游输入（`WorkflowEditormodules/WorkflowEditor_ExecutionEngine.js:65-874`）。
- **辅助节点**：覆盖数据转换、条件、延时、循环、正则、代码编辑、URL 渲染、内容输入与 AI 拼接等类型，其中循环类节点以成对的起点与终点标识，分发逻辑在同一执行引擎内。
- **文档与实现不一致**：`VCPHumanToolBox/README.md` §8 声称执行管线为空壳、不建议在生产中依赖，而当前代码已有完整执行链；按仓库约定以可执行路径为准，README 属陈旧说明。
- **持续性**：工作流的保存与加载由 StateManager 承接（对应 README §8 的已实现列表）；落盘格式与位置本次未核实。
- **证据强度**：入口、UI 绑定与执行引擎为源码事实；节点执行结果与保存加载往返未经运行验证。

### 能力卡 7：ComfyGen 专用创作配置面板

- **用户目标**：为后端 ComfyUIGen 图像生成插件提供人类可用的参数与资产管理面板（工作流模板、LoRA、模型、提示词），与工具网格的"用户/Agent 共用参数面"形成闭环。
- **入口与触发者**：HumanToolBox 工具网格中 `ComfyUIGen` 卡片右上角 ⚙ 按钮 → `openComfyUISettings`（`VCPHumanToolBox/renderer.js:1567`）→ `ComfyUILoader` 动态加载 ComfyUI 模块族。
- **完整主链**：配置抽屉三 Tab（连接/生成参数/工作流管理）→ 测试连接（本地 ComfyUI，默认 `http://localhost:8188`）→ 保存配置写回后端插件目录 → 工作流导入（ComfyUI API 格式 JSON，校验后转换）→ 含 `WeiLinComfyUIPromptToLoras` 节点时自动注入 LoRA。抽屉与 Tab 实现见 `ComfyUI_UIManager.js:157-305`。
- **配置持久化与转换**：保存经 `comfyui:save-config` 写回 `VCPToolBox/Plugin/ComfyUIGen/comfyui-settings.json`（`ComfyUImodules/README.md:48`，PathResolver 定位插件目录）；工作流转换经 `import-and-convert-workflow`；LoRA 注入条件见 `ComfyUImodules/README.md:16-25`。
- **外部依赖**：ComfyUI 本地服务与后端插件（VCPToolBox）；本仓库只实现配置管理链，生成执行仍经工具网格或 Agent 调用。
- **证据强度**：入口与 IPC 链为源码事实；连接测试、模板转换与参数注入行为未运行验证。

### 能力卡 8：Agent 正则系统（四类作用点）

- **用户目标**：对 Agent 的渲染文本与发送给模型的上下文做可分层、按深度与角色生效的正则改写；比通用"消息过滤"更接近 SillyTavern 的提示词工程层。
- **入口与触发者**：Agent 设置中的正则规则编辑模态（模板声明于 `main.html:982`，含标题、查找/替换、作用域、角色与 min/max 深度）；import-regex-rules 支持导入 SillyTavern 正则脚本（`modules/ipc/regexHandlers.js:36-55`），导入时的字段映射如下：
  ```text
  placement: 1=user, 2=assistant
  markdownOnly → 前端（渲染）
  promptOnly → 上下文
  min/maxDepth → 直接对应
  ```
- **事实对象**：Agent 配置里的 stripRegexes 数组就是正则规则集合，规则单独写入 regex_rules.json，不并入 config.json 主体（`modules/ipc/agentHandlers.js:58/279-281`）。
- **完整主链（四类作用点）**：规则在四处生效，机制与定位如下表：

  | 作用点 | 行为 | 定位 |
  |---|---|---|
  | 上下文正则 | 发送前按轮次深度逐条改写历史消息，深度图以轮次为单位生成 | `modules/chatManager.js:54-81/328-348/1327-1350` |
  | 渲染器正则 | 在渲染、更新与阅读等路径上按角色与深度过滤显示文本 | `modules/renderer/messageRenderer.js:972-989` |
  | 深度正则 | 规则自带的最小与最大深度结合轮次深度图决定生效范围 | 同上一条 |
  | content 数组 | README 声称存在针对多模态 content 数组的正则；本次未定位到专门实现，两条路径都只处理字符串 | — |

- **持续性**：规则随 Agent 配置持久化在 regex_rules.json。
- **独特性判断**：与 AIO Hub、SillyTavern 的正则分层属同一聚类（上下文 DSL），作用点命名（渲染、上下文、深度）与 SillyTavern 脚本兼容导入是 VCP 系的特点。
- **证据强度**：引擎与三类作用点为源码事实；content 数组维度未证实；运行效果未经运行验证。

### 能力卡 9：跨聊天消息转发与转发附言（气泡评论）

- **用户目标**：把一条消息（含文本与附件）带来源标识与附言转发到另一个 Agent/群组话题，解决"信息跨上下文流动"。
- **入口与触发者**：消息右键「转发消息」（`modules/renderer/messageContextMenu.js:211-220`；中键快捷动作 `middleClickHandler.js:634-640`）。
- **完整主链**：转发模态先展示目标列表（含 Agent 与群组，可搜索）→ 确认后用原始消息构造转发前缀、原文与可选附言 → 聊天管理器切换到目标会话、填充输入框与附件后走标准发送链触发完整 AI 响应。模态与文本构造在 `modules/renderer/forwardMessageOwner.js:21-40`，会话切换与发送在 `modules/chatManager.js:2338-2390`。
- **持续性**：转发内容作为目标话题的普通消息落盘；评论只是消息文本一部分，无独立评论对象。
- **声明核对**：README 所述"右键消息气泡添加评论附加在原始消息下方"未找到独立实现——实际只有转发对话框内的"附加评论"字段；独立气泡评论本次未找到。
- **证据强度**：转发主链为源码事实；附件在目标端的历史重建与展示未运行验证。

### 能力卡 10：前端插件机制与 LoomAPP 运行时

- **插件注册**：插件 manifest 的 `frontend` 字段以 style/script 两字段声明渲染器插件；主进程 `listEnabledFrontendPlugins` 扫描 `VCPDistributedServer/Plugin/*`（`modules/ipc/desktopHandlers.js:143-167`），路径经 `resolveFrontendPluginResource` 白名单校验后返回相对 URL。
- **注入与事件**：`frontend-plugin-loader.js` 在 DOMContentLoaded 后注入样式与脚本，并派发 `vcp-frontend-plugins-loaded`；现有插件为 `VChatDynamicWallpaper` 与 `VChatAutoTTS`（manifest 均标 `pluginType: renderer`）。
- **两个现存插件（入口确认）**：VChatDynamicWallpaper（文件夹视频壁纸 + 紧凑播放控制）、VChatAutoTTS（自动朗读与代码块朗读开关），插件本体行为未运行验证。
- **LoomAPP 运行时（主链确认）**：
  - **运行时托管**：`modules/loom/VCPLoomManager.js`（现 2,076 行）用 `WebContentsView` 托管 LoomAPP。manifest 声明的字段如下：

    ```text
    id, startUrl, 窗口/视口, UA, css, js
    ```

    注入的样式与脚本各有 2MB 上限，应用 ID 另经 `SAFE_APP_ID` 校验。
  - **用户面**：应用管理器页面负责应用抽屉与导入导出，设备菜单页面负责 WebHID、WebUSB、WebSerial 与 WebBluetooth 的设备授权选择，选择结果经设备候选事件回传（`Loommodules/manager.html`、`Loommodules/device-menu.html`）。
  - **Agent 侧 LoomController 1.4.0**：插件清单声明了 13 个以上命令，其中八个负责列出、创建、打开、关闭应用以及读取运行时源码、渲染文本与编辑应用源码，另外四类能力是：
    - **GetPageInfo**：返回 Web Agent 页面快照与 Grounded Markdown，回执含动作句柄、文档代次、快照 ID 与页面图；
    - **GetPageImage**：按图片 ID 返回 data:image 形式的多模态回执；
    - **ExecuteAction**：执行 Web Core 标准动作目录中的动作；
    - **串行指令协议**：按编号步骤加等待依次执行带编号的指令，任一步失败即停止，已成功步骤的回执保留并以 `partial_failure` 标记。
  - **底层 WebCore**：这一版引入 VCP Agent WebCore（`modules/loom/webcore/*`，8 个文件约 5,075 行，含 chrome 与 electron 双 adapter、web-agent-protocol 以及页面与运行时 core 三层），LoomControllerService 把 Agent 请求路由到 LoomManager 的页面信息读取与动作执行两个方法。
  - **WebCore 测试**：测试落在 tests/ 下的 loom-controller.test.js、loom-electron-adapter.test.js 与 loom-manager-runtime.test.js 三个文件，分别覆盖控制器、Electron 适配器与管理器运行时。
- **证据强度**：注册、注入、Loom 命令分发与 WebCore 适配层均为源码事实；LoomAPP 实际运行、WebCore 页面感知与隔离边界未运行验证。

### 能力卡 11：VCPMobileSync 跨端双向增量同步

- **用户目标**：让 VCPChat 桌面端与 VCPMobile 手机端保持聊天数据（Agent/群组/话题/消息/头像）的物理双向同步；"跨端记忆"的 README 声明（中心记忆库实时同步）实际由后端承担，本插件同步范围不含记忆库。
- **入口与触发者**：桌面端全局设置开启「VCP 分布式服务器」后插件随 `VCPDistributedServer` 加载；手机端配置 HTTP（默认 5974）/WebSocket（默认 5975）与 Sync Token 握手。
- **事实对象**：`sync_state.db` 维护五张表（README §5，字面量见下）；中央索引模式下改用 VCP-CDS 的 SQLite/Tantivy。
  ```text
  entity_index / message_index / attachment_index / avatar_index / message_attachments
  ```
- **完整主链（三阶段协议 V2）**：一次同步按索引、差分、传输三步完成：
  - 第一阶段 Reconcile：扫描 Agent、群组与用户数据三个根目录建立索引（`VCPMobileSync/index.js:313`）；
  - 第二阶段差分：用配置哈希与 Merkle 内容哈希双层比对，产出消息级的拉取、推送与删除清单，命中 Fast-Path 时直接跳过（`sync/manifest.js:88-195`、`sync/diff.js:114-197`）；
  - 第三阶段传输：NDJSON 流式吞吐，逐行消费，写入用文件锁加临时文件 rename 的原子方式，并以写意图锁避免 watcher 自触发（`sync/message.js:29-191`）。
  冲突策略是双向增量合并，同一实体的并发修改按最新时间戳胜出（README §1）；墓碑拦截配合 30 天清理，防止幽灵数据回流（README §6）。
- **中央索引模式**：开启 `MobileSyncUseCentralIndex=True` 后，同步清单、差分、拉取/推送、墓碑与变更流六类操作改由 Rust 服务 `vcp_chat_data_service`（VCP-CDS）承接（`rust_chat_data_service/README.md:8-16`），身份模型为三元组（`:110-120`，字面量见下）；测试 `tests/mobile-sync-central-adapter.test.js` 存在，旧 `sync_state.db` 链路可切换回退。
  ```text
  同步操作：Manifest / Diff / Pull / Push / Tombstone / Change Feed
  身份模型：(owner_type, owner_id, topic_id)
  ```
- **边界**：附件表存在但"实际上不能同步"（README §4 表格明确标注）；头像参与同步。
- **证据强度**：协议、表结构、原子写与中央适配为源码事实；真实手机端握手、大文件吞吐与冲突收敛未运行验证。

### 能力卡 12：Agent 自主管理 Topic（TopicSponsor）

- **用户目标**：让后台运行的 Agent 主动创建/发现/回复自己的聊天话题，实现"Agent 主动向用户发起聊天"的自主交互（README 自主话题管理）。
- **入口与触发者**：Agent 经 VCP 工具调用 TopicSponsor 插件，命令分发在 `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js:23-655`，命令族如下：
  ```text
  CreateTopic / CreateFlowlockTopic / ReadUnlockedTopics / CheckNewTopics /
  CheckUnreadMessages / ReplyToTopic / CheckTopicOwnership / ListUnlockedTopics / ReadTopicContent
  ```
- **事实对象**：插件直接读写 Agent 配置里的 topics 数组，以及每个话题目录下的聊天历史文件（`AppData/Agents/<uuid>/config.json、AppData/UserData/<uuid>/topics/<topicId>/history.json`）。
- **完整主链**：三个主要动作与命令分发同处一份插件文件，机制与边界如下表：

  | 命令 | 行为 |
  |---|---|
  | CreateTopic | 先校验 Agent 存在，再生成带时间戳与 UUID 的话题目录并写入带创建者元数据的首条 assistant 消息，随后把创建元数据（未锁定、未读、来源为插件）插入 topics 数组，最后以临时文件加 rename 的原子写回配置 |
  | ReplyToTopic | 话题处于锁定且已读状态时拒绝写入，其余情况追加带插件回复标识与原始发送者元数据的消息 |
  | CheckTopicOwnership | 读取话题创建者，判定调用方是否为所有者 |

- **前端认领链**：前端用认领、恢复、枚举三个 API 处理 Flowlock 的待认领话题（`preloads/api/flowlock.js`），主进程按 Agent 串行化、拒绝多候选，失败时补偿恢复为 pending（见能力卡 4）。普通话题的前端实时刷新（新话题出现在侧栏）本次未单独核实：前端在会话切换或重载时重读 config，未见 watcher 证据。
- **独特性判断**：与 FlowLock 同属主动 Agent 聚类，但事实对象不同（话题持久化与运行时 Session）；一个 Agent 往另一个 Agent 的话题追加消息这种跨 Agent 回复，只在 VCP 系出现。
- **证据强度**：插件命令与认领 IPC 为源码事实；插件与前端 IPC 的真实对接未经运行验证。

### 能力卡 13：VCP Hi-Fi 音频引擎与音乐播放器（Agent 可控的本机播放子系统）

- **用户目标**：让聊天客户端自带一套专业级本机音乐播放能力——Hi-Fi DSP 处理、WASAPI 独占输出、WebDAV 远程曲库与无缝隙切歌，并让 Agent 能通过对话点歌、桌面挂件能随时控制。普通聊天客户端没有这样的本机媒体播放子系统。
- **用户侧入口**：聊天页与托盘的播放按钮经 IPC 创建单例无边框音乐窗，页面是 Musicmodules/music.html；音乐窗的分享到聊天走独立通道，窗口创建、播放控制与分享通道都在同一份音乐 IPC 模块内（`modules/ipc/musicHandlers.js:200-832`）；桌面另有内置音乐迷你条挂件（Desktopmodules/builtinWidgets/musicWidget.js:150-173）。
- **Agent 侧入口**：音乐控制工具请求到达 VCP 服务器后注入调用音乐控制处理（VCPDistributedServer.js:676-714）。命令集是播放、暂停、停止、下一首、上一首，其中播放可带目标曲目，其余四个只做基础播放控制。
- **提示词注入**：全局设置开启 Agent 音乐控制后，「点歌台」指令会被注入系统提示词（`modules/ipc/chatHandlers.js:1180-1201`）。
- **事实对象**：音频来自本地文件与 WebDAV 服务器曲库（Musicmodules/music-webdav.js、modules/webdavManager.js）；播放列表与歌单等持久化对象分布在 AppData 下：

  | 对象 | 落盘位置 | 定位 |
  |---|---|---|
  | 播放列表 | AppData/songlist.json | 音乐 IPC 模块内 |
  | 自定义歌单 | AppData/custom_playlists.json | 音乐 IPC 模块内 |
  | 歌词 | AppData/lyric/*.lrc | — |
  | 封面缓存 | AppData/MusicCoverCache | — |
  | 引擎设置 | AppData/audio_settings.json | rust_audio_engine/src/settings.rs:276 |
  | 响度元数据 | loudness_cache.db（SQLite） | rust_audio_engine/src/server.rs:728-739 |
  | 重采样缓存 | resample_cache/（SHA-256 文件名） | main.js:746 |

- **完整主链（自研引擎）**：主进程启动时预热 Rust 二进制 audio_engine/audio_server.exe：spawn 时带固定端口，从 stdout 等就绪信号，退出时先发优雅关停请求，超时再兜底强杀（`main.js:224-290`）。引擎按职责分层：

  | 层 | 职责 | 定位 |
  |---|---|---|
  | 接口 | HTTP 用 actix-web，频谱与事件走 WebSocket，50ms 帧间隔，事件位掩码覆盖加载完成、切歌与预加载需求 | server.rs、server/ws_handlers.rs |
  | 解码 | Symphonia 全链路用 f64，本地路径与带 Basic Auth 的 HTTP(S) URL 都能读 | decoder.rs |
  | 输出 | cpal 共享模式与 WASAPI 独占模式并存，独占模式绕过系统混音器直通硬件，跑在 Windows 专用线程上 | wasapi_output.rs |
  | 实时 DSP 链 | 音频线程用无锁原子参数，debug 构建下审计回调是否分配内存；源域依次处理音量、十段 IIR EQ、饱和与 crossfeed，再做卷积和动态响度；FIR EQ 使用可调的 1023+ taps 卷积核，可与外置 IR 合并；跨重采样边界后处理输出域峰值限制与噪声整形 | player/callback.rs:236-269,595-624 |
  | 噪声整形与位深 | 五种曲线可选，输出位深可选 16/24/32 位 | server/effects.rs |
  | 响度 | 按 EBU R128 计算，提供 track、album、streaming 与 replaygain 四种模式，配合全曲扫描、SQLite 缓存和可取消的后台扫描任务（信号量限流、TTL 回收） | server.rs、server/playback.rs |
  | 重采样 | SoX VHQ 算法，目标采样率覆盖 8k–384k，缓存键含文件大小与 mtime | processor/resampler.rs、player/mod.rs:377-409 |
  | 切歌与卷积 | 预加载下一首的解码结果再原子交换缓冲；外置 IR 卷积上限 64MB，预置 IR 放在 audio_engine/IRPreset/，列表管理在音乐 IPC 模块内 | player/gapless.rs、musicHandlers.js:625-655 |
  | 安全校验 | 拒绝路径穿越、UNC 路径与 Windows 保留设备名，URL 侧拒绝私网与环回地址，构成 SSRF 防护 | server.rs:99-189 |

- **前端播放器主链（控制与渲染）**：选曲后经 IPC 调引擎的加载接口（同一份音乐 IPC 模块，musicHandlers.js:200-230），引擎异步解码并通过 WebSocket 推送进度；随后播放、暂停、跳转、音量、设备选择与独占开关等控制生效，状态轮询与 50ms 频谱帧驱动 Canvas 粒子可视化（music-visualizer.js:102）。
- **前端播放器主链（歌词与切歌）**：歌词取本地文件或云端候选。统一抓取器并行搜索网易云、QQ 与酷狗，并为网易云和 QQ 候选补查 AMLL TTML；手动候选按标题、歌手、专辑与时长评分，选中后同时保存 JSON 与 LRC。自动入口复用同一套候选搜索与应用 API，但底层审计函数读取了未传入的曲目时长，属可执行的未声明变量缺陷，自动跨源审计能否跑完尚未确认（`modules/lyrics/lyricFetcherUnified.js:444-585`、Musicmodules/music-lyrics.js:66-103）。
- **持续性**：播放列表、歌单、歌词、封面与引擎设置全部落在 AppData，重启即可恢复；引擎随应用启停（启动预热、退出优雅关闭），播放运行状态不落盘。
- **人机与多 Agent 关系**：用户通过音乐窗、桌面挂件与分享完全掌控播放；Agent 经音乐控制工具只能按曲名或歌手匹配播放列表点歌并做基础控制，没有曲库写权限，该能力可整体关闭。README 所说音乐实时被 agent 听到，实际实现是曲目元数据注入：每次请求往 system 消息注入当前播放曲目与播放列表（chatHandlers.js:1180-1201），全仓没有把音频流或频谱上传给 Agent 的代码。
- **外部依赖**：WebDAV 服务器由用户自备；引擎纯本机运行，不依赖后端；MusicController 的工具分发经由 VCP 服务器，但不使用其其他能力。
- **声明核对**：README 宣称的 DSD 256bit 硬解码与当前引擎不符；听歌识曲生成 .lrc 的 AI 歌词创作也没有找到 Agent 听音生成链。早期关于多源云端歌词库不成立的判断与当前实现不符：现有多源搜索、下载与质量选优链，覆盖网易云、QQ、酷狗与 AMLL 四类来源，但它们不生成歌词。README 还把音频引擎写成 Python 依赖，而主引擎当前是 Rust。
- **独特性判断**：AIO Hub、SillyTavern 等同类产品没有聊天内 Agent 可控点歌、桌面挂件、WASAPI 独占与自研 DSP 链（FIR EQ、IR 卷积、EBU R128、SoX VHQ 与无锁音频线程）这样的组合，它构成 VCPChat AI 原生桌面运行时的又一个旁路子系统。归入创作工作站与媒体聚类（与 ComfyGen、Loom 并列），也可单列本机媒体播放器能力族。
- **证据强度**：引擎（约 50 个 Rust 文件）、前端、IPC 与 Agent 工具链均完成静态走读；audio_engine/ 为编译产物，与源码是否一致未确认；WASAPI 独占实际生效、DSP 听感、WebDAV 播放、频谱渲染与 gapless 切歌未经运行验证。

### 能力卡 14：划词小助手（Rust 桌面感知引擎）

- **用户目标**：在任意应用的文本上划选即可唤出悬浮动作条，选择翻译、总结、解释、搜索或配图，由内部 Agent 处理并把结果回话，用户无需离开当前工作窗口；这是系统级文本感知加 AI 处理的旁路产品面。
- **入口与触发者**：设置开启全局文本监听后，左键拖选产生的系统级划选事件会触发整条链路。Rust sidecar 用 actix-web 起在 63791 端口（`rust_assistant_engine/src/main.rs:16-21`），经 Windows UIA（uia_selection_provider.rs）或 macOS、Linux 的对应实现捕获选区，再经 stdout 的事件行桥接回主进程（`modules/assistant/assistant-rust-adapter.js:88-108`）。
- **完整主链**：主进程收到选区后由处理函数弹出悬浮动作条，点击动作分发到独立对话窗口，窗口复用消息渲染器的流式渲染，会话保存为真实 Agent 话题（assistant.js:107-119）；悬浮条与对话窗口的页面、动作分发与分享到笔记都在同一份 IPC 文件内（`modules/ipc/assistantHandlers.js:74-638/1049-1320`）。
- **事实对象**：配置落在 AppData/rust-assistant-config.json，含白名单、黑名单与守护规则三类设置；会话走真实 Agent 话题持久化。
- **持续性**：守护进程随应用启停，启动、恢复与崩溃后拉起都有对应逻辑；配置与话题均落盘。
- **声明核对**：README 划词小助手一节宣称的全域右键呼出实际只跟踪左键划选（windows_event_source.rs:33），判为 `声明不符`；文件夹工作区模式在全仓库搜索无命中，判定相同；悬浮动作条、全局文本监听、独立对话窗口与分享笔记四项均为 `主链确认`。
- **独特性判断**：聊天客户端内置 Rust 系统级文本感知 sidecar，三平台各自捕获、Windows 走 UIA 选区监听，同类客户端未发现同等方案；归入人类工具面与桌面感知聚类。
- **证据强度**：Rust 捕获链、事件桥接、悬浮条与对话窗口为源码事实；真实划选触发、UIA 选区读取与三平台行为未经运行验证。

### 能力卡 15：Scriptorium 共笔文坊（面向 AI 操作的多模态文档与演示工作台）

- **用户目标**：在同一工作台里让人类直接编辑渲染后的文档版式，同时让 Agent 能理解、查看并以可审阅的方式修改同一份源码，产出富文档与演示。编辑对象是 VDOC 工程模型，VDOCX 为连续流文稿、VPPTX 为逐页演示，工程容器用 document.json 与 SHA-256 内容寻址资源组织，Office 文件只作为导入来源（ScriptoriumModules/README.md、vdoc-container.js）。
- **入口与触发者（用户侧）**：托盘应用栏的文坊图标（trayManager.js:28 声明为 vchat-app-scriptorium）触发打开独立窗口，窗口映射到桌面应用 ID 表里的 docx-editor 项（desktopHandlers.js:873-875）。
- **入口与触发者（IPC 注册与格式）**：主进程初始化文档 IPC 模块后，由它注册文档打开、保存、导入、导出四组通道，管理 vdocx 与 vpptx 工程，导入接受 HTML、MD、TXT、RTF、DOCX 与 PPTX，导出 HTML 与 PDF（`modules/ipc/docxHandlers.js:870-1192`）。窗口 preload 见 preloads/docx.js。
- **入口与触发者（Agent 侧）**：ScriptoriumCollaborator direct 插件（版本 2.1.0）经 428 行的中间服务层操作当前窗口里的文档（`modules/services/scriptoriumAgentControlService.js`）。
- **事实对象（两类真源）**：工程存放在 AppData 下的 ScriptoriumDocument 目录。VDOCX 的真源是 Markdown-first 的混合文稿加独立 document CSS，能原生保留 HTML、LaTeX、Mermaid 与可编程岛；VPPTX 的每一页是一份完整 HTML Scene，另有共享 deck CSS。两者保存的都是源内容，渲染 DOM 随渲染过程生成。
- **事实对象（文脉）**：文脉即版本上下文，属工程数据：人类刻点与 Agent PR 以 pending、applied、rejected、conflict、failed 五种状态进入同一条文脉，携带操作元数据、变更集、工程内嵌版本快照与审批回执；文脉可以回溯，回溯前自动保存，已有的后续文脉不会被删除。
- **Agent 的观察面**：插件先提供文档信息、渲染文本、分层目录、单章与源码检索和当前视口附近的源码，长文档因此可以按目录和章节读取，不必把全文一次塞入上下文；另一类调用返回 OpenAI content 数组，同时含 Markdown 语义摘要与实际 viewport 或指定演示页的 base64 截图，这使它具备只暴露 Markdown 的编辑器所没有的 AI 多模态查看面（`ScriptoriumCollaboratorService.js:565-933`、`plugin-manifest.json:25-97`）。
- **完整主链（Agent 编辑）**：Agent 先读取 revision、结构、源码或截图，再以追加、插行或精确替换三种动作提交源码 PR。请求带 Agent 署名与预期的 revision，先在窗口侧生成 PR，再由人类或预设的自动允许策略决定结果为 applied、rejected、conflict 或 failed；超时也只保留提案，不改写文档。已应用的修订与审批回执进入工程文脉，形成可回溯的协作记录（定位见上一条）。
- **创建与演示操作**：创建工程动作能在不替换当前窗口的前提下直接落盘新的 VDOCX 或 VPPTX 工程；PPTX 另有加页、插页与演示场景配置 PR。页面完整源码可含样式、资源声明与交互脚本，运行时把页内查询限定在注入的 scene 根之下。
- **多模态与运行时边界**：工程可管理图片、视频与音频资源，VDOCX 还支持公式、SVG、对象锚点与 Mermaid；需要 Canvas、WebGL、动画或长期交互身份的内容要放进带稳定 ID 的可编程岛。派生的 KaTeX DOM、Mermaid SVG、Canvas、截图与编辑标记都只存在于渲染层，不回写成源内容（ScriptoriumModules/README.md、scriptorium-media.js、scriptorium-programmable-content.js）。
- **导入、阅读与导出**：导入接受 HTML、Markdown、TXT、RTF、DOCX 与 PPTX，Office 格式会被转换成新的 VDOC 工程，转换结果不做像素级原位还原；导出可生成连续流或分页的 HTML 与 PDF，资源会被本地化，演示导出物能脱离编辑器独立阅读或放映（同一份文档 IPC 模块、scriptorium-export.js）。
- **证据与边界**：源码确认了 UI、工程持久化、Agent 端口、PR 与文脉、导入导出以及截图返回的整条静态链。`tests/重构中禁用脚本/` 内有 hybrid compiler、importer、容器、协作者、资源本地化与 VPPTX 的测试与冒烟脚本，但尚未纳入测试命令；真实的编辑、媒体播放、截图、PR 审批与 Office 导入导出本次均未运行。

### 能力卡 17：桌宠（DeskPet，可选应用功能模块）

桌宠是随包可选启用的独立功能模块，按 `modules/<目录>/feature.json` 清单加载（当前唯一一个 feature 模块）。角色形象支持 Live2D、精灵图或静态立绘，作为桌面独立窗口常驻，不占聊天窗口：

- **对话投影**：桌宠窗口显示当前会话的回复文本与工具执行进度，气泡文本、工具活动与朗读各自有独立状态；回复可朗读，闲时能主动搭话。
- **桌面审批**：工具审批请求可以直接在桌宠上允许或拒绝，不必回到主窗口的通知栏。
- **动作与外观**：表情映射、动作/手势、视线与头部姿态、拖拽抛出、边缘吸附、全屏检测后隐藏、闲置动画与漫游，换装与 ZIP 导入。
- **生命周期**：作为 feature 模块注册主进程 `register(host)` 与渲染侧 `install(context)`，停用后下次启动完全不加载，preload API 同步不暴露。

依据：`modules/deskpet/feature.json`、`modules/deskpet/index.js`、`modules/deskpet/petStream.js`、`modules/deskpet/petProactive.js`、`modules/deskpet/petIpc.js`、`DeskPetmodules/mainWindow/index.js`、`docs/deskpet-live2d-v1.md`。
### 能力卡 16：受管启动、恢复与图形安装器

- **用户目标**：让源码版桌面应用在依赖缺失、原生模块不匹配、启动失败或更新中断时给出可解释的诊断与恢复路径，并把更新从工作树的原地修改中分离出来。现有 npm start、BAT 与 VBS 入口保持原样，新入口是可选的托管工作流（`scripts/vcpchat.mjs:4-164`），命令分发在 scripts/vcpchat-bootstrap.mjs:9-25。
- **入口与对象**：开发者用 npm run vcpchat，图形入口在 Windows、macOS 与 Linux 上分别由 launchers 目录下的 VCPChat-Launcher.vbs、VCPChat-Setup.command 与 VCPChat-Launcher.sh 定位 Tauri 安装器或恢复界面。启动操作记录、就绪记录、修复日志、版本指针与锁这几类状态按项目根目录映射到独立状态目录，避免共用同一 lockfile 的不同 clone 互相串状态（modules/bootstrap/launch-protocol.js、scripts/vcpchat-dev-launcher.mjs:154-165）。
- **完整主链（启动与修复）**：托管入口先跑只读 Doctor；通过时写完成标记并启动 Electron，失败时只输出有预算的修复计划。只有显式修复参数或图形界面里的明确确认才执行修复，修复结束再跑一次 Doctor，仍失败就停止并转向恢复界面。启动器取得 operation lock 后启动 Electron，必须收到 operation 与 PID 相同、主窗可见且 preload 与 renderer 都 ready 的记录，才把所有权交回应用；超时、崩溃与已有实例运行各有独立结果（`scripts/vcpchat-dev-launcher.mjs:77-308`、`main.js:381-464`）。
- **恢复、取消与资源边界**：恢复 UI 在独立 Electron 进程里展示修复计划与结构化进度，取消信号会传给受管子进程树；Windows 走 taskkill 树终止，POSIX 用独立进程组终止（bootstrap/recovery-main.cjs、modules/bootstrap/platform-process.js）。修复清单以 lockfile 为身份基准，用 npm ci 安装并对原生模块做定向 rebuild；Rust 与 vendor 修复默认关闭，需显式选择（modules/bootstrap/repair-planner.js、tests/vcpchat-managed-bootstrap-m3-m8.test.mjs:23-94）。
- **更新与本地修改语义**：

  | 环节 | 行为 | 定位 |
  |---|---|---|
  | 下载 | 走 HTTPS、同源重定向、签名 manifest 与完整文件闭包校验；支持 .part 与 Range 续传 | scripts/vcpchat-update.mjs、modules/bootstrap/update-downloader.js |
  | 切换 | 候选版本先进 staging，通过磁盘、路径、symlink 与 hash 校验以及 ready 健康检查后才原子切换 current 指针，失败自动回滚 | modules/bootstrap/update-manager.js |
  | 安装器源码更新 | 先检查 upstream；有本地修改时须由用户选择命名 stash，更新只允许 fast-forward，随后按记录的 stash OID 恢复；恢复冲突或更新后 Doctor 失败时修改仍留在 stash 中 | `apps/bootstrap-installer/src-tauri/src/lib.rs:290-380`、tests/vcpchat-installer-git-update.test.mjs:68-123 |

- **证据与边界**：npm run test:bootstrap 的 46 项契约测试全部通过，覆盖锁、Doctor、显式修复、取消、跨平台进程边界、运行时闭包、签名下载、健康检查与回滚。npm run test:installer-contract 的 17 项中 16 项通过；失败的一项是主进程 ready 发布顺序的静态正则断言，源码里的 publish 调用仍在（交接定位见上一条），说明该断言与当前排版脱节，Electron 与 Tauri 的实机验证仍需单独进行。Windows/Linux 安装、签名与公证、生产公钥分发、真实网络故障与长时更新都未运行确认；该实现受 Hermes 启发，签名与发布层面的独立产品安装器属于另一层交付。
## 补查的旁路产品面与提案建议

本表记录上轮排除（音频引擎、主题系统、论坛、骰子）与未覆盖区域（笔记、翻译、语音、TTS、RAG、任务、VchatManager、日志、划词小助手）的补查结果。除能力卡 13/14 外，其余模块按证据强度分级：

| 模块 | 状态 | 关键证据 | 提案建议 |
|---|---|---|---|
| 双语混合朗读引擎（TTS 族） | `主链确认` | `modules/SovitsTTS.js:372-424` 正则切片主/副语言 → 双模型分流（`:454-455`）→ 队列预合成 + 缓存 `AppData/tts_cache`（`:13`）；`VChatAutoTTS` 插件 MutationObserver 自动朗读（`plugin.js:94-111`） | 建议提案：语音聚类辅助/主贡献 |
| VCPSuperDice 3D 物理骰子 | `主链确认` | ammo.wasm 物理投掷后回传 Agent；当前 UI 白名单提供 9 个主题，资源树含 13 份 theme.config，并增加按主题选择碰撞/落定音色的 soundscape。物理参数仍是固定的 `BASE_PHYSICS`，未找到打滑、黏着、磁铁等“施法”入口 | 辅助贡献候选 |
| VCP Forum 论坛客户端 | `主链确认` | 后端 `admin_api/forum`（Basic Auth）；前端 masonry 卡片 + CSS 作用域隔离 + KaTeX 数学保护（`Forummodules/forum.js:308-414/:887-1132`） | 与 VCPToolBox 论坛跨仓库合并计数（同一事实对象） |
| RAG Observer 信息流监听 | `主链确认` | 独立启动后经 WS 展示 RAG/通知并处理工具审批；召回卡可选 A/B 两轮，客户端按规范化结果文本显示交集、独有项和重合率（`RAGmodules/RAG_Observer.js:19-260`） | 辅助贡献候选 |
| 语音聊天（Voicechat） | `主链确认` | Puppeteer 启动 headless Chrome（`modules/speechRecognizer.js:104-113`）→ `webkitSpeechRecognition`（`recognizer.html:101-105`）→ `exposeFunction` 桥接回 Electron；会话落盘为真实 Agent 话题（`voicechat.js:137-155`） | 工程方案独特，产品贡献一般；可作辅助 |
| 笔记系统（Notes + 迷你便签） | `主链确认` | `AppData/Notemodules` 本地文件 + 网络目录挂载扫描缓存（`notesHandlers.js:26-45`）；`Win+Alt+Z` 全局便签（`main.js:1360-1362`） | 归"协同工作区"聚类（与 Canvas 并列），不单独提案 |
| 翻译窗口 | `主链确认`（功能常规） | 渲染层直连 VCP chat completions（`Translatormodules/translator.js:277`），快/均衡/质量三档 | 不提案（通用能力） |
| 主题系统 | `骨架/声明不符` | 选择器主链完整（`themeHandlers.js:51-89`）；"自然语言主题生成器（主题管理 Agent）"grep 零命中未接线 | 不提案 |
| Agent 任务台（Agenttaskmodules） | `入口确认` | 后端 `agent-assistant`/`task-assistant` 插件的管理 UI（`task.js:253-256`，走 `admin_api`） | 不提案（外部后端） |
| VchatManager | `入口确认` | 独立运维应用；亮点=配置/文件系统一致性检查修复（`consistency-checker.js`） | 不提案（运维工具） |
| VCPLog 日志中心 | `入口确认` | 实际走 HTTP 轮询增量拉取（`Logmodules/log.js:219-231`）；README 声称的 WebSocket 连接未在此模块出现 | 不提案（WS 声明不符） |
| `lyricFetcher` / `weatherService` / `modelUsageTracker` | `主链确认/缺陷/骨架` | 歌词多源搜索与手动候选主链已接线，自动审计有未声明 target 缺陷；天气为后端 `admin_api/weather` 卡片；用量统计写 `model_usage_stats.json` | 不提案（常规小工具） |

## 已归并到现有类目的能力

- **Agent 群聊四种发言模式（候选 10）**：`Groupmodules/modes/` 下的策略模块（sequentialMode、natureRandomMode、inviteOnlyMode 与 gamePrompts）与完整判定逻辑（game 模式由游戏事件驱动发言，JEV 决策模式负责发起方判定）已由[对话请求与上下文调查笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 8.1 节主链确认（sequential 全员轮发、naturerandom 的 @提及/tag 权重/保底发言者、invite_only 按钮驱动）。补充的群组长期状态交点：群聊消息由群聊模块作为历史单一真源落盘，assistant 消息快照带 Agent、模型与模型来源三个字段（`Groupmodules/groupchat.js:531-950`）；群聊上下文同样应用 VCPChatTarven 注入与正则。
- **Canvas 协作（候选 11 的已实现部分）**：Canvas 窗口与聊天主窗口的文件级同步（chokidar watcher → 行级 diff → 接受/拒绝）、内存版本快照等已由[生成式输出与运行时调查笔记](../生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) 深入覆盖（G3 为主、G4 部分）。补查结论：Canvas 是"单用户双窗口"同步（`canvasHandlers.js:93-105` 只向 canvas 窗口与主窗口广播），没有网络级多人协同协议；"与群文件区实时同步"未找到代码。
- **VCP 日记渲染与认知可见性（候选 7）**：DailyNote 起止协议块的渲染（创建卡与更新替换预览）已由[消息渲染器调查笔记](../消息渲染器/VCPChat-消息渲染器调查笔记.md) 覆盖（`messageRenderer.js:311/:941-1005`，text-viewer 同步实现）；日记"模型回流"（DailyNote 工具结果通知渲染，`modules/notificationRenderer.js:216-284`）与对象管理（Memo 窗口）在本笔记能力卡 2 承接，不重复计数。
- **跨聊天消息转发入口（候选 14 的入口部分）**：右键转发入口已由 [Chat UI 调查笔记](../Chat%20UI/VCPChat-ChatUI调查笔记.md) 第 6 节记录，本卡补齐完整内容链（见能力卡 9）。
- **VCPDesktop 渲染与流式**：桌面推送的渲染器侧（消息内占位卡）、流式拦截、挂件源码编辑（Canvas 上下文打开）已由运行时笔记覆盖，能力卡 3 只补持久化/恢复/资源治理。

## 声明不符、外部依赖与暂缓项

- **群文件、共享工作区与协同编辑（候选 11）**：README 声称"为每个群组提供专属共享文件空间和工作区，支持实时协同编辑"。全仓库搜索群文件、GroupFiles、groupFiles 与 group-files 均无命中；群聊的文件共享实际是消息级附件，附件挂在 user 消息的附件数组上，群成员通过历史可见；协同编辑只出现在单用户 Canvas 双窗口场景（`Groupmodules/groupchat.js:532、Groupmodules/grouprenderer.js:1446-1520`）。判定：群文件、共享工作区与群内协同编辑均为声明不符（未实现）。
- **ST 预设、角色卡、世界书与可视化注入（候选 9）**：README 声称"完全兼容并支持挂载 SillyTavern 的预设、角色卡和世界书，可直接创建和管理"。Promptmodules 是 VCPChat 自己的提示词编辑器，提供原始、积木块与预设文件三种系统提示词模式，没有 ST 角色卡与世界书格式；全仓库搜索世界书、WorldBook、角色卡与 CharacterCard 均无前端实现命中；唯一确认的 ST 兼容入口是正则脚本导入（`modules/ipc/regexHandlers.js:36-55`）。VCPToolBox 管理面板另有 VcptavernEditor（见 VCPToolBox Chat UI 笔记）。判定：VCPChat 前端为声明不符，相关能力在外部仓库，暂缓归因。
- **分布式多模态文件追踪与跨模态转译（候选 15）**：节点侧主链成立——主服务器经 execute_tool 工具发起 internal_request_file，节点把本地文件协议 URL 转成本地路径读取，返回 base64 与 MIME 类型（`VCPDistributedServer.js:606-664`），其中 FileFetcherServer 的新协议注释表明与后端联动。"全 URL 超栈追踪"与"高阶模型对低阶模型能力转译"的主服务器逻辑在 VCPToolBox，本仓库没有实现。判定：节点侧为入口确认，完整闭环暂缓（外部依赖）。
- **跨端记忆（候选 12 的记忆部分）**：README 的"跨端记忆"指以 VCP 后端为中心的统一记忆库，VCPMobileSync 的同步范围不含记忆，其 README 的同步类型表只列 Agent、Group、Topic、Message、Attachment（未实际同步）与 Avatar。判定：记忆同步暂缓（外部后端），消息与元数据同步为主链确认。
- **Agent 自主管理 Topic 的前端刷新（候选 8 补充项）**：TopicSponsor 创建话题后，普通话题出现在侧栏的即时机制未见 watcher 或事件证据，前端是在会话切换时重读 config；Flowlock 话题则有明确的认领轮询。该项保留为未验证。
- **音频引擎的 DSD 256bit 硬解码声明（能力卡 13）**：引擎全量源码搜索 dsd 与 dsf 均无命中，Symphonia 也不支持 DSD 解码；README 在专业级音频引擎一节里的 Hi-Res 声明与实现不符。
- **“AI 歌词创作（听歌识曲生成 .lrc）”与“音乐实时被 agent 听到”（能力卡 13）**：当前多源歌词链做的是元数据搜索与候选下载，没有 Agent 听音生成；自动质量审计还存在未声明 target 的缺陷。Agent 得到的是曲目元数据注入，音频流与频谱都不会转发给它。
- **TTS 的流式剪枝 600% 加速声明（README §语音朗读）**：SovitsTest/GSVI.py 与 my_infer.py 只是 OpenAI 兼容的 HTTP 封装，没有剪枝算法代码；双语混合朗读确实存在，600% 这个加速数字列为声明不符。
- **主题系统的自然语言主题生成器（README §强大的主题系统）**：搜索主题管理、themeGenerator 与 ThemeAgent 均无命中，可用的只有手动 CSS 主题选择器。
- **骰子“物理施法”（README §Vchat超级骰子插件）**：多主题已经实现，UI 白名单提供 9 个主题，资源树有 13 份配置并带主题声景；物理参数保持固定，未找到打滑、黏着或磁铁等施法入口。
- **划词小助手的全域右键呼出与文件夹工作区模式（能力卡 14）**：Rust 侧只跟踪左键划选；文件夹工作区在全仓库搜索无命中。
- **笔记的 Obsidian 类云端同步与分享笔记到 AI 知识库（README §笔记模块）**：实际做法是网络目录挂载加扫描缓存，没有同步协议；把笔记分享到知识库未找到对应代码（`modules/ipc/notesHandlers.js:26-45`）。
- **VCPLog 的 WebSocket 连接声明（README §VCPLog 集成）**：日志中心走 HTTP 轮询；WebSocket 连接实际属于 RAG Observer（`Logmodules/log.js:219-231`）。

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
- 12. Scriptorium 共笔文坊——创作工作站/文档协作聚类（能力卡 15；Loom v1.4.0 升级计入既有 Loom 项，不重复计数）。
- 13. 受管启动、恢复与图形安装器——多表面连续性/交付工作流聚类（能力卡 16）。它的用户价值是可恢复的桌面交付流程；更新与修复的可靠性机制单独标注，不与聊天能力混合计数。
- **辅助贡献**：跨聊天消息转发与附言（Chat 工作流）；前端插件注册/注入机制（工程机制，单独标注）；双语混合朗读引擎（语音聚类）；3D 物理骰子与 RAG Observer 信息流监听（视统计口径可选）。
- **不计入**：群文件/共享工作区、ST 预设/角色卡/世界书（前端）、跨模态转译闭环、"跨端记忆"本体、主题生成器、DSD 硬解码、AI 歌词创作、音乐实时听音、TTS"600% 剪枝"（均为声明不符）。
- **机制贡献（单独标注，不与产品特性混分）**：正则与 Tavern 规则的安全屏蔽、Flowlock generation 防复活、VCPMobileSync 的原子写/墓碑/稳定哈希、挂件资源治理（定时器/监听器清理、性能打点、可见性冻结）、HumanToolBox 的 IPC 白名单与路径校验、音频引擎的路径穿越/SSRF 防护与无锁音频线程（assert_no_alloc 审计）、语音聊天的 Puppeteer 桥接方案。

## 未验证事项

1. 全部结论为静态分析，未运行应用：Tavern 注入在真实请求中的行为、Memo 云图渲染与后端联想算法、挂件桌面渲染与动画冻结效果、Flowlock 后台心跳续写与跨 Topic 交接、工作流编辑器执行与保存加载、ComfyUI 连接与模板转换、LoomAPP 运行与隔离、移动同步握手与吞吐、TopicSponsor 与前端认领对接。
2. 音频引擎：`audio_engine/` 编译产物与 `rust_audio_engine` 源码的一致性未确认；WASAPI 独占模式实际生效、DSP 链听感、FIR EQ/IR 卷积效果、WebDAV 远程播放、频谱可视化与 gapless 切歌行为均未运行验证。
3. 划词小助手：Rust sidecar 的真实划选触发、Windows UIA 选区读取与三平台行为未运行验证。
4. README 声称的"content 数组正则"作用点未定位到实现（`applyFrontendRegexRules` 与上下文路径均只处理字符串）。
5. 独立"气泡评论"（评论附加在原始消息下方并持久化）未找到实现，仅确认转发对话框内的附加评论字段。
6. 工作流编辑器的工作流落盘格式与位置未核实；README §8 与代码的矛盾以代码为准，但"哪一版是预期行为"未确认。
7. TopicSponsor 普通话题的前端即时刷新机制未核实。
8. VCP-CDS（Rust）的中央索引模式仅确认了适配层与测试存在，未核实其查询/Change Feed 的完整行为。
9. 两个渲染器前端插件（动态壁纸、自动 TTS）仅确认注册与加载机制，插件本体 UI 行为未验证；VChatAutoTTS 的双语自动朗读触发链为源码事实，合成效果未验证。
10. `tests/` 当前跟踪 174 个文件，覆盖聊天 surface/流式终态、历史写入、Canvas 审批、LoomSkill、设置保存、歌词候选、移动同步、Scriptorium 与启动安装链等；真实 Electron 视觉、Flowlock 端到端循环和音频引擎听感仍未由这些 Node 契约替代。
11. 受管启动与安装器未运行 Electron、Tauri、签名安装包或真实网络更新；`test:installer-contract` 的 ready 发布顺序静态断言在当前 `main.js` 失败（16/17 通过），需以修正断言后的测试和实机 handoff 结果补证。

## 关键源码索引

- `Tavernmodules/tavern-manager.js`：高级回复浮窗与规则管理模态；`modules/tavernRulesEngine.js`：三类注入纯逻辑引擎；`modules/ipc/tavernHandlers.js`：`VCPChatTarven.json` 持久化与 IPC。
- `modules/chatManager.js:188-233/1085-1130`：单聊 Tavern 注入与上下文正则应用点；`Groupmodules/groupchat.js:510-539/605-608/736/1189/1308`：群聊注入路径与历史真源；`modules/renderer/messageContextMenu.js:788`：消息右键菜单一侧的注入应用点。
- `Memomodules/memo.js`（`apiFetch`/工作台/批量操作）、`memo-graph.js`（联想与力导向图）、`memo-workbench.js`（引用工作台与 DailyNote 发布）。
- DeepMemo 2.0：`VCPDistributedServer/Plugin/DeepMemo/DeepMemoService.js:39-115`（工具入口、可信上下文、中央搜索、可选精排与预算筛选）、`:135-205`（参数规范化与 VCP-CDS 请求构造）；`Plugin/DeepMemo/README.md`（central 适配边界与上下文上传协议）；`tests/deepmemo-central-adapter.test.js`（适配层测试）。
- `Desktopmodules/favorites/favoritesManager.js`、`core/widgetManager.js`、`core/performanceManager.js`、`core/visibilityFreezer.js`；`modules/ipc/desktopHandlers.js:40/212/948/999/1228`。
- `Flowlockmodules/flowlock.js`（Session 状态机与认领）、`flowlock-integration.js`（用户操作绑定）、`flowlock-protocol.js`（状态气泡）；`Flowlockmodules/README.md`（协议与生命周期权威文档）。
- `VCPDistributedServer/Plugin/TopicSponsor/topicsponsor.js`：Agent 自主话题命令族。
- `VCPHumanToolBox/`：`renderer_modules/config.js`（工具定义）、`renderer_modules/tool-manager.js`（插件导入与参数解析）、`WorkflowEditormodules/WorkflowEditor_ExecutionEngine.js`（工作流执行）、`ComfyUImodules/ComfyUI_UIManager.js`（ComfyGen 面板）；`VCPHumanToolBox/README.md` §8（与代码矛盾的陈旧说明）。
- `VCPDistributedServer/frontend-plugin-loader.js` + `modules/ipc/desktopHandlers.js:143-167`：前端插件注册与注入；`modules/loom/VCPLoomManager.js`（2,076 行）+ `modules/loom/webcore/*` + `VCPDistributedServer/Plugin/LoomController/`（1.4.0）：LoomAPP 运行时、WebCore 页面感知与动作命令。
- Scriptorium 前端模块：`ScriptoriumModules/`（`scriptorium.js`/`scriptorium.html`/`vdoc-hybrid-compiler.js`/`vdoc-core.js` 等，`README.md` 为权威说明）。
- Scriptorium 主进程与插件：`modules/ipc/docxHandlers.js`、`modules/services/scriptorium{AgentControl,Import,PptxImport}Service.js`、`VCPDistributedServer/Plugin/ScriptoriumCollaborator/`、`preloads/docx.js`、`main.js:1262-1271`（初始化）；`tests/重构中禁用脚本/`（12 个测试/冒烟脚本）。
- 受管启动与安装，入口脚本：`scripts/vcpchat.mjs`（诊断/显式修复入口）、`scripts/vcpchat-bootstrap.mjs`（命令分发）、`scripts/vcpchat-dev-launcher.mjs`（operation lock、ready 与 handoff）、`scripts/vcpchat-update.mjs`（版本更新）。
- 受管启动与安装，支撑模块：`modules/bootstrap/`（Doctor、修复、运行时闭包、进程边界、下载与回滚）、`bootstrap/`（恢复 UI）、`apps/bootstrap-installer/`（Tauri 图形安装器）、`launchers/`（三平台图形入口）、`tests/vcpchat-{bootstrap,managed-bootstrap-m3-m8,platform-boundary,installer-contract,installer-git-update}.test.mjs`。
- `VCPDistributedServer/Plugin/VCPMobileSync/`（manifest/diff/message/central）与 `rust_chat_data_service/README.md`：跨端同步与中央索引。
- `VCPDistributedServer/VCPDistributedServer.js:625-664`：节点侧 `internal_request_file` 文件拉取；`:656-687`：MusicController 工具注入调用；`:689-694`：SuperDice 注入调用。
- `modules/renderer/messageContextMenu.js:211-220` + `modules/renderer/forwardMessageOwner.js:21-40` + `modules/chatManager.js:2338-2390`：转发与附言主链。
- `rust_audio_engine/` 引擎源码，按职责分：
  - 入口与 HTTP：`main.rs`（入口与端口 63789）、`server.rs`（HTTP 路由与路径/SSRF 防护）、`server/ws_handlers.rs`（频谱/事件 WS）、`server/webdav_handlers.rs`；
  - 解码与输出：`decoder.rs`（Symphonia f64 解码）、`wasapi_output.rs`（WASAPI 独占）、`server/playback.rs`、`server/effects.rs`；
  - 播放与 DSP：`player/`（audio_thread/callback/gapless/state）、`processor/`（eq/fir_eq/convolver/crossfeed/loudness/resampler/saturation/dsp_chain/lockfree_params）；
  - 持久化与部署：`audio_engine/`（部署二进制与 `IRPreset/`）、`settings.rs:276`（`AppData/audio_settings.json`）。
- `Musicmodules/`：播放器、效果、频谱、WebDAV 与歌词 UI；`modules/ipc/musicHandlers.js` 负责引擎和歌词 IPC；`modules/lyrics/lyricFetcherUnified.js`、`matchScore.js` 负责多源候选、评分与自动审计（`createAuditedLyrics` 有未声明 target 缺陷）；`Desktopmodules/builtinWidgets/musicWidget.js` 为桌面音乐条。
- 划词小助手：`modules/assistant/assistant-rust-adapter.js`（sidecar 启动与 `ASSISTANT_EVENT` 桥接）、`modules/ipc/assistantHandlers.js`（悬浮条/对话窗口/动作分发）、`rust_assistant_engine/src/`（capture/windows_event_source/uia_selection_provider/metrics）。
- 旁路模块入口：
  - 语音与朗读：`modules/SovitsTTS.js:372-424`（双语切片）、`WebIndexTTS2/server.js`（IndexTTS-2 云端代理）、`Voicechatmodules/voicechat.js` + `modules/speechRecognizer.js`（Puppeteer 识别）；
  - 桌面与内容：`Dicemodules/dice.js` + `assets/dice-box`（3D 物理骰子）、`Notemodules/notes.js`（笔记主链）、`Themesmodules/themes.js` + `themeHandlers.js`（主题选择器）；
  - 社区与观测：`Forummodules/forum.js`（论坛渲染链）、`RAGmodules/rag-observer-config.js` + `ragHandlers.js`（信息流监听与审批浮层）、`Agenttaskmodules/task.js`（任务台）；
  - 运维：`VchatManager/consistency-checker.js`、`Logmodules/log.js`。
