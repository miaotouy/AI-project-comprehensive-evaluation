# AIO Hub 独特功能调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`（分支：`dev`）
>
> 调查方式：只读通读根 README、`docs/architecture/tools-architecture-overview.md`、全部 46 个 `src/tools/*.registry.ts`、目标模块 ARCHITECTURE 文档与关键实现（media-generator、asset-manager、llm-inspector、vcp-connector、skill-manager、macro-engine、quick-action、useDetachedManager、Rust `asset_manager.rs`、recall、regex-applier、git-committer、token-calculator、web-distillery、window-automator、realtime-subtitle-ocr、translator、content-deduplicator、smart-ocr、st-worldbook-manager 及 worldbook-processor）；未运行 Tauri 应用，未修改被调查仓库
>
> 调查范围：待查清单第二批候选（上下文分析器、宏与正则管道、快捷动作、Agent 私有资产、自由窗口、媒体工作站、资产管理器、多运行时插件、Skill 沙箱、请求检查器、VCP 监控）的入口、状态、执行与持久化主链；全量扫描剩余约 37 个未走主链的工具模块，新增八张能力卡；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的独特功能集中在"**本地工具枢纽 + 上下文工程**"两翼。去除 Chat/上下文/AST/Agent 已有覆盖后，本仓库仍独立成立的能力族有十八项，其中十六项主贡献达到主链确认（静态证据），另有 content-deduplicator 为辅助主链确认、VCP 监控为入口确认：

1. **媒体工作站（media-generator）**：会话-任务双轨、全局任务池、树形分支、参数清洁与资产回流，是完整的创作工作流（主链确认）。
2. **中央资产管理器（asset-manager）**：应用数据目录下的资产文件、SHA-256 去重、Rust 索引和来源追踪，构成跨工具的资产事实源（主链确认）。
3. **LLM 请求检查器（llm-inspector）**：Rust 外部代理与前端内部钩子组成双层监控，可透视应用内所有 LLM 调用（主链确认）。
4. **快捷动作系统（Quick Actions）**：宏模板、行级后处理、自动发送和 SillyTavern Quick Reply 导入（主链确认）。
5. **宏系统**：实际注册 74 个内建宏（README 宣称 60+），采用 PRE_PROCESS/SUBSTITUTE/POST_PROCESS 三阶段管道（主链确认，与上下文类目交界）。
6. **自由窗口管理**：组件级分离窗口 + logicHook 响应式同步 + 位置记忆/可见性自愈（`主链确认`）。
7. **Agent 私有资产**：`agent-asset://` 协议、`{{assets}}` 宏和渲染器解析链（主链确认）。
8. **Skill 沙箱**：Rust 路径锁定、超时和多运行时探测，支持渐进式披露（主链确认，执行细节已由 Agent 工具笔记承接）。
9. **VCP 监控与双向桥接（vcp-connector）**：observer 消息监控、分布式节点和工具桥（入口确认；节点与桥接已由 Agent 工具笔记承接）。
10. **Recall 思绪集**：从旧 knowledge 拆分出的"上下文即时召回"领域，采用检索管线、双 Agent 工具实例和严格占位符协议，定位为世界书的 RAG 进阶优化版（主链确认）。
11. **正则预设堆叠工作台（regex-applier）**：预设 CRUD + 多预设按顺序叠加应用 + 一键处理，补齐正则工具类"预设复用与堆叠预设"缺口（`主链确认`）。
12. **Git 工作台与 AI 提交信息（git-committer）**：LLM 流式生成 commit message + 多仓库并发全景操作（`主链确认`）。
13. **全局 Token 基础设施（token-calculator）**：Tokenizer 资产注册表 + 多模态计费，被 llm-chat 九处以上消费，聊天 token 预算的底层支撑（`主链确认`，按机制贡献标注）。
14. **网页蒸馏室（web-distillery）**：三层蒸馏 + Rust 反检测代理 + API 嗅探 + 站点配方 + Cookie 身份（`主链确认`）。
15. **窗口自动化流程语言（window-automator）**：子流程函数调用 + 变量作用域 + 条件跳转 + OCR 联动，接近小型 RPA 语言（`主链确认`）。
16. **实时字幕 OCR（realtime-subtitle-ocr）**：GDI 截屏 + aHash 去重 + 编辑距离字幕合并 + 一键注入全局 Chat（`主链确认`）。
17. **长文本分片翻译（translator）**：递归分片 + 并发限流 + 上一分片上下文继承，上限 100 万字符（`主链确认`）。
18. **弹幕播放器（danmaku-player）**：内置播放器（ASS/B 站 JSON/XML 弹幕 + 10 种字幕格式 + JASSUB 高保真渲染）与外部播放器透明覆盖层（Win32 窗口同步 + 虚拟时钟 + 鼠标穿透）双路径（`主链确认`）。

辅助与机制标注：content-deduplicator（五阶段漏斗 + 规范化匹配，非语义）与 danmaku-player、embedding-playground、media-info-reader、user-profile-manager、text-diff 等为辅助/第二梯队；`st-worldbook-manager` 已确认编辑、持久化、导入导出及聊天运行主链，归并 Agent 角色与上下文既有类目，不作为本篇新增能力重复计分；smart-ocr 作为共享 OCR 平台层（`platform/runner.ts` 被 realtime-subtitle-ocr、transcription、window-automator 三处复用；平台层含作业协议与稳定贡献点配置，`platform/plugin-engine.ts`/`config-migration.ts`，提交 `045c52bd0`）按机制标注；ffmpeg-tools 的跨工具回流链（输出→Chat 附件/转写工作台/资产）按机制标注，附注见第二梯队小节。

归并已有类目：上下文分析器（对话请求与上下文笔记 9.8 已确认复用真实管道预览）、上下文管道中的 regex-processor（同一笔记第 2 节管道处理器；Global/Agent/User 三层合并细节）。多运行时插件系统的 Agent 工具面已由 Agent 工具笔记覆盖，其 UI/生命周期扩展面本次标 `入口确认`。code-formatter、json-formatter、component-tester、symlink-mover、system-pulse、service-monitor、wallpaper-detector 经全量扫描确认无超出名字的跨工具/Agent/后台面，不入候选。

声明不符项：README/ARCHITECTURE 中 media-generator 的 `generateMedia(prompt, type)` Agent 方法声明存在但**未实现**（占位，见 `media-generator/ARCHITECTURE.md:410`）。

## 介绍声明与候选盘点

根 README（299 行）将产品定位为"一站式 AI 创作与开发工作站 + 专业级上下文工程引擎"，功能面非常宽。`docs/architecture/tools-architecture-overview.md`（2026-06-30 生成，39 个模块）与当前 `src/tools/` 实际 47 个 registry 文件（原 46 个基础上新增 `retrieval` 工具注册）基本一致，是本轮候选盘点的可靠索引。47 个工具中，与现有十类笔记重叠（Chat/上下文/会话/渲染/AST/Agent 工具与角色/渠道）的主要是 `llm-chat`、`rich-text-renderer`、`tool-calling`、`knowledge-base`、`web-canvas` 等；其余工具构成"工具枢纽"产品面。

| 候选（待查清单第二批） | 证据状态 | 结论 |
|---|---|---|
| 上下文分析器 | `归并已有类目` | 对话请求与上下文笔记 9.8 已确认：以所选节点为终点重跑真实上下文管道预览 |
| 60+ 宏与正则管道 | `主链确认` | 内建宏 74 个（macro-engine/macros/*.ts）；regex-processor 为管道处理器（priority 200），Global/Agent/User 三层合并 |
| 快捷动作 | `主链确认` | messageInputStore.handleQuickAction 完整执行链 + quick-actions 目录持久化 |
| Agent 私有资产 | `主链确认` | `agent-asset://` 协议 + AgentAssetsManager + `{{assets}}` 宏 + 渲染器 resolveAsset |
| 自由窗口 | `主链确认` | useDetachable/useDetachedManager + DetachedComponentContainer + logicHook 同步 |
| 媒体工作站 | `主链确认` | media-generator 双轨架构，本次走通完整主链 |
| 资产管理器 | `主链确认` | Rust `import_asset_from_bytes` SHA-256 去重 + `assets.jsonl` 索引 |
| 多运行时插件 | `入口确认` | JS/Native/Sidecar 三类（plugins/README + plugin-manager）；Agent 工具面已由 Agent 工具笔记承接 |
| Skill 沙箱 | `主链确认` | Rust skill_manager.rs 路径锁定/超时/多运行时探测；渐进式披露 |
| 请求检查器 | `主链确认` | llm-inspector 双层监控，内部钩子注入 fetchWithTimeout |
| VCP 监控 | `入口确认` | vcp-connector observer 六类事件监控面板；节点/桥接已由 Agent 工具笔记承接 |

| 候选（全量扫描新增） | 证据状态 | 结论 |
|---|---|---|
| Recall 思绪集（知识库拆分） | `主链确认` | 检索管线预设（algorithmic/comprehensive）+ 候选模块 + recall-basic/recall-admin 双 Agent 实例 + `【recall::...】` 严格占位符协议；knowledge 已重构为主动工具（见能力十） |
| 正则预设堆叠（regex-applier） | `主链确认` | 预设 CRUD/导入导出 + 多预设顺序叠加 + 一键处理；Agent 方法未暴露（getMetadata TODO） |
| Git 工作台（git-committer） | `主链确认` | AI 生成 commit message 流式链 + 多仓库并发全景 |
| Token 计算器（token-calculator） | `主链确认` | Tokenizer 资产注册表 + 多模态计费；llm-chat 9+ 处消费，机制贡献 |
| 网页蒸馏室（web-distillery） | `主链确认` | Rust 代理剥安全头 + 反检测注入 + API 嗅探 + 配方动作序列 + Cookie 身份 |
| 窗口自动化（window-automator） | `主链确认` | call 子流程/变量/条件跳转/OCR 联动，迷你自动化语言 |
| 实时字幕 OCR | `主链确认` | GDI 截屏 + aHash 去重 + 编辑距离合并 + 一键注入 Chat |
| 长文本翻译（translator） | `主链确认` | 递归分片 + 并发限流 + 上一分片上下文继承，上限 100 万字符 |
| 弹幕播放器（danmaku-player） | `主链确认` | 内置弹幕/字幕播放 + Win32 外部播放器透明覆盖层（虚拟时钟/鼠标穿透/Z-Order 跟随） |
| 内容查重器（content-deduplicator） | `主链确认`（辅助） | Rust 五阶段漏斗 + 规范化匹配；fuzzy 未实现，非语义去重 |
| smart-ocr 平台层 | `机制标注` | useOcrRunner 被字幕/转写/窗口自动化三处复用 |
| ffmpeg-tools 跨工具回流 | `主链确认`（附注） | 输出→Chat 附件/转写工作台/资产；executePipeline `$prev` 多步管道 |
| Embedding 游乐场/ST 世界书管理/媒体信息读取/用户档案中心/text-diff 等 | `入口确认`（第二梯队） | 见"第二梯队与确认无隐藏特性"小节 |

## 已确认的独特能力

### 能力一：媒体工作站（media-generator）— `主链确认`

**用户目标**：把"图片/视频/音频/3D 多模态生成"从聊天里的单次工具调用升级为可管理、可分支、可重试、可追踪的独立工作台；生成历史、任务队列、参数和资产同处一个事实源。

**入口与触发者**：用户入口为主——工具首页 `/media-generator`（`media-generator.registry.ts` 的 `toolConfig`），输入框"生成"提交到媒体任务会话；另一条是 Agent 侧：registry 通过 `buildAgentMethods.ts` 为每个可用模型动态生成模型方法，并标记为可供 Agent 调用，模型可触发生成。

**事实对象**：三个对象——`GenerationSession`（树形 `MediaMessage` 节点，独立于 llm-chat 会话体系）、`MediaTask`（跨会话全局任务池，状态为 `pending → processing → completed | error | cancelled`）和结果 `Asset`。桥接字段是节点 `metadata.taskSnapshot`，用于重试时恢复参数。

**完整主链**：输入提示词先打包为任务，按模型能力决定是否带上下文，再加入全局任务池并在会话树建立 User/Assistant 节点。生成执行支持 AbortController 中断，参考图转为 Base64，参数清洁逻辑按模型规则剔除不支持的参数并校验取值，随后决定多轮上下文。请求返回后解码 Base64 或拉取 URL，将生成参数写入文件元数据并导入资产库，同时保存衍生数据；最后把任务标为 completed 并关联结果资产。关键入口和落库逻辑见 media-generator 模块 ARCHITECTURE 文档。

**持续性**：`{appDataDir}/media-generator/` 下 `sessions-index.json` + `sessions/{id}.json` + `tasks.json` + `settings.json`；`syncIndex()` 启动自愈（补齐/移除索引项），崩溃遗留的 `generating` 节点自动标 `error`，`activeLeafId` 修复到最深叶子。

**主动性与取消**：无后台主动执行；取消入口可中止单个或全部生成，任务完成后保留在池中供 UI 查看，也可通过自动清理设置移除。

**外部依赖与执行域**：生成请求走用户配置的 LLM Profile（远程 API）；参考图与结果资产在本机资产库；无独立后端进程，执行逻辑在前端 + 远程 API。

**安全与资源边界**：参数清洁逻辑用于防止非法参数；无内容过滤，提示词完全由 LLM 控制；生成消耗真实 API 额度。generateMedia Agent 方法为占位未实现（`ARCHITECTURE.md:410`），Agent 触发生成实际依赖动态方法族。

**独特性判断**：llm-chat 的多模态输出只是"附件/转写"；media-generator 提供会话-任务双轨、参数清洁规则、内嵌元数据和资产回流，是 `创作工作站` 标签的完整实例。

**证据强度**：ARCHITECTURE.md 全文（730 行）+ registry 源码为静态事实；未运行应用验证 UI 与真实模型调用。

### 能力二：中央资产管理器（asset-manager）— `主链确认`

**用户目标**：所有工具产生的图片、文档、转写结果汇入一个按哈希去重、可分组筛选、带来源追踪的应用级资源中心，避免同一文件多次落盘。

**入口与触发者**：用户入口为工具页 `/asset-manager`（AssetManager.vue + useAssetManager）；实际主入口是**工具侧写入**——llm-chat 附件、media-generator 结果、sketch-pad 导出、OCR/转写结果都调用全局资产管理单例；入口见 `useAssetManager.ts:113` 等位置。

**事实对象**：Asset 包含 path、sha256、origins[]、thumbnail 和 derived 元数据等字段；索引存放在 `$APPDATA/assets/assets.jsonl`，文件按月分目录。

**完整主链**（以 media-generator 回流为例）：生成响应字节进入 Rust 导入命令（`src-tauri/src/commands/asset_manager.rs:870`），计算 SHA-256 并在当月范围查重。命中时给既有资产追加来源并直接返回；未命中时写文件、提取图片宽高、生成缩略图或音频封面、写入中央索引，最后由前端分页查询。

**持续性**：`assets.jsonl` 中央索引 + 物理文件；`rebuild_hash_index` 可重建哈希索引；重启后按索引恢复。

**安全与资源边界**：`enable_deduplication` 开关控制去重；`remove_asset_source` 在最后一个来源移除时删除文件；Tauri capability 对 fs 读取无路径限制（Agent 工具笔记第 7 节已记录）。

**独特性判断**：多数项目把文件挂在会话/知识库下；AIO Hub 用应用级资产层统一所有工具的产物并带来源生命周期，是 `创作工作站` 与"媒体/资产"聚类的关键支撑。

**证据强度**：Rust 命令源码 + 前端单例 + ARCHITECTURE 为静态事实；10 万+资产性能上限（ARCHITECTURE 自述）未实测。

### 能力三：LLM 请求检查器（llm-inspector）— `主链确认`

**用户目标**：对"发给模型的每个请求"做本地中间人级观察——既能拦截外部 LLM 客户端的流量，也能透视应用内自己发的请求，替代仅凭日志猜请求体。

**入口与触发者**：工具页 `/llm-inspector`（`LlmInspector.vue`）；用户开关 `monitorInternal`/`monitorExternal` 分别控制内部和外部监控。内部钩子默认关闭，是**被动观测**，不主动干预请求。

**完整主链**（内部钩子路径）：发送入口在调用 adapter 前记录请求上下文，随后由带超时的 fetch 在请求、响应和流式分支埋点；钩子注册表按 `X-Request-ID` 反查上下文，再通过本地回调和 Tauri 事件跨窗口广播，记录存入内存 store。详情面板展示总览、请求和响应三类信息，流式 SSE 另以 100ms 节流并支持 OpenAI、Anthropic、Gemini、Cohere、Ollama 五种格式。外部路径由 Rust axum 代理在默认 8999 端口拦截、转发上游并回流事件；跨窗口启用状态使用三事件协议同步，定位见 `types/hooks.ts:172`。

**持续性**：记录在内存 store；配置（端口、header 覆盖规则、布局比例、Token 估算开关）持久化 `appConfigDir/llm-inspector/settings.json`（createConfigManager 500ms 防抖）。记录本身不落盘。

**安全边界**：API Key 脱敏复制；header 覆盖规则可改上游请求；代理监听本机端口。

**独特性判断**：这是"自观察 LLM 流量的开发者表面"——应用内埋点 + 外部代理双通道，现有类目无对应项。

**证据强度**：ARCHITECTURE 全文 + 埋点源码为静态事实；代理真实转发与 SSE 解析未运行验证。

### 能力四：快捷动作系统（Quick Actions）— `主链确认`

**用户目标**：输入栏的指令增强——把"模板文本 + 宏 + 行级后处理"组合成可点击按钮，一键生成内容并可自动发送；支持导入 SillyTavern Quick Reply 生态资产。

**入口与触发者**：用户点击输入栏快捷操作按钮（QuickActionSelector.vue），由消息输入 store 的处理入口执行；源码定位见 `messageInputStore.ts:328`。

**事实对象**：`QuickActionSet` 表示快捷动作组，`QuickAction` 条目包含 label、content、autoSend、hotkey、lineProcessing 等字段；索引为 `quick-actions-index.json`，组文件存放在 `{appConfigDir}/llm-chat/quick-actions/`，定位见 `useQuickActionStorage.ts:40-57`。

**完整主链**：点击后取文本选区，无选区则取全文，作为 `{{input}}` 注入宏上下文并执行模板；随后按行添加前后缀或执行正则替换，失败时保留原文，再将结果写回选区或整体覆盖编辑器。开启自动发送时延迟 50ms 发送，否则重新聚焦输入框。导入链由 quickActionImportService.ts 解析 SillyTavern 的 `qrList` 格式。

**主动性与取消**：无后台行为；执行是同步改写输入框，可编辑后发送。

**独特性判断**：普通聊天输入框只有发送/重试；快捷动作把"宏模板 + 正则后处理 + 自动发送"做成了用户可管理的产品表面，并与 ST 生态互操作。

**证据强度**：store/composable/组件三处源码为静态事实；UI 行为未运行验证。

### 能力五：宏系统（74 个内建宏，三阶段管道）— `主链确认`

**用户目标**：让 Prompt 文本可编程——时间日期、系统环境、随机/掷骰、角色信息、变量读写、知识库、工具定义等都以 `{{name}}` 形式在发送前展开，属于"上下文 DSL"聚类（待查清单第 8 行）。

**事实对象**：`MacroDefinition`（name/type/phase/handler/example），注册在 `MacroRegistry`（reactive Map）。

**完整主链**：`MacroProcessor` 按 PRE_PROCESS、SUBSTITUTE、POST_PROCESS 三阶段执行，分别处理初始化、主体替换和格式化输出；每阶段批量处理对应宏，未注册宏记录 warning。内建宏实测 74 个，分类数量为 datetime 25、core 19、variables 8、functions 7、system 7、tools 3、recall 2、knowledge 1，另有 assets 和 cssVariables 各 1。system 组新增 `appVersion`，通过 Tauri `getVersion()` 读取应用版本，失败时返回 `Unknown`；旧 `{{kb}}` 宏已移除。全局和局部变量支持读写、增减及全局变量操作，会话变量快照语义见对话请求与上下文笔记 9.4；三阶段入口见 `macro-engine/MacroProcessor.ts:84`，版本宏见 `macro-engine/macros/system.ts:144-164`。

**持续性**：宏定义为代码内建；变量值随消息快照/会话 JSON 持久化（见会话管理笔记 1.3）。

**独特性判断**：README"60+"宣称实测为 74 个；三阶段管道 + 变量系统的组合在样本中接近 SillyTavern/VCP 的宏面，但以 Vue 应用内建实现。与对话请求与上下文笔记的重叠点是宏在上下文管道中的注入位置，本笔记只记宏引擎本身。

**证据强度**：逐文件统计注册定义（74 个）+ 管道代码为静态事实；未运行宏展开验证。

### 能力六：自由窗口管理（分离窗口系统）— `主链确认`

**用户目标**：把任意工具页甚至聊天输入框从主窗口拖出来成为独立无边框窗口，跨窗口共享同一状态源，位置大小自动记忆——多表面连续性的桌面实现。

**入口与触发者**：用户从工具卡片或标签页的分离菜单创建工具窗口；组件级分离由 useDetachable 处理 rdev 拖拽会话、全局快捷键和平台监听。

**完整主链**：分离请求创建带工具 ID 的 Tauri 窗口，由对应容器按 ID 加载工具组件；跨窗口状态通过 logicHook 与主窗口共享同一 store，窗口位置和大小由配置系统持久化。管理器每 30 秒检查窗口是否移出屏幕，定位见 `useDetachedManager.ts:194-208`；聊天和媒体输入框另经窗口同步总线传递增量或全量状态，并用版本号避免旧状态覆盖新状态。

**持续性**：窗口布局与已分离列表持久化（`get_all_detached_windows` 启动恢复）；`window-sync-architecture.md` 记录状态同步协议。

**独特性判断**：Chat UI 笔记已记录分离窗口同步行为（8.2），本笔记确认其作为应用级窗口基础设施的完整链路；在桌面 AI 客户端中属于少见的产品面。

**证据强度**：composable + 指南文档为静态事实；实际拖拽交互与多窗口视觉未运行验证。

### 能力七：Agent 私有资产（`agent-asset://`）— `主链确认`

**用户目标**：Agent 携带专属媒体资产（表情包、BGM、场景图），LLM 在回复里用 `agent-asset://` 协议主动引用，形成角色级"资产皮肤"。

**事实对象**：Agent 目录 `{appConfigDir}/llm-chat/agents/{agent_id}/assets/` 下的 `assets/` 子目录 + 组管理（`AgentAssetsManager.vue`、`agentAssetUtils.ts`）。

**完整主链**：资产管理 UI 导入 → 资产存 Agent 目录并注册组/ID → 引用格式 `agent-asset://{group}/{id}.{ext}` 写入预设消息或由 LLM 输出 → 发送前 `{{assets}}` 宏（`macro-engine/macros/assets.ts`）把资产清单注入 Prompt 引导使用 → 渲染时 `MessageContent.vue:728`/`ImageNode.vue`/`HtmlBlockNode.vue` 等组件通过 `resolveAsset` 钩子解析为真实 URL（AST 模式下由具体节点组件按需解析，避免二次编码）→ 消息内联显示。与 `skill_read_file` 的作用域严格分离（`docs/architecture/skill-integration.md:20`）。

**持续性**：资产随 Agent 配置目录持久化，PNG 角色卡 V2/V3 导入导出可携带资产。

**独特性判断**：把"模型可用资源"做成角色级命名空间并让 LLM 主动引用，是 SillyTavern 生态语义（角色资产）在桌面应用的完整落地。

**证据强度**：协议解析（agentAssetUtils）、宏、渲染器三处源码 + 文档为静态事实；未运行验证 LLM 实际引用。

### 能力八：Skill 沙箱（skill-manager）— `主链确认`（执行细节由 Agent 工具笔记承接）

**用户目标**：按 Agent Skills 规范安装、管理、执行 Skill 包，模型按需激活（渐进式披露），脚本在本机沙箱执行。

**完整主链**：`SkillBridgeFactory` 启动注册为 ToolRegistryFactory → `SkillLoader.scanAll`（Rust 并行扫描 `{appDataDir}/skills/` + 内置目录，YAML frontmatter 解析）→ `SkillManagerProxy`（id `skill:system`）动态生成 `activate_<name>` 方法 + `skill_run_script/skill_read_file/skill_list_dir` → LLM 调用激活 → Rust `skill_manager.rs` 执行：脚本路径必须位于 `scripts/` 子目录（防 `../` 穿越）、`current_dir` 锁定 Skill 根目录、运行时按 `bun → node → python` 探测（README 宣称"多种运行时"）、默认 60 秒超时。渐进式披露三级：元数据摘要 → 完整指令 → 资源文件按需读取（`ARCHITECTURE.md:110-120`）。安装来源支持本地/Git/URL。

**独特性判断**：Rust 侧强制路径沙箱 + 渐进式披露是 Agent 工具笔记已确认的边界；本笔记补全 Skill 包生命周期面（安装/卸载/热加载）。

**证据强度**：ARCHITECTURE + Rust 命令 + Agent 工具笔记交叉印证；未实际运行脚本。

### 能力九：VCP 监控与双向桥接（vcp-connector）— `入口确认`

**用户目标**：AIO Hub 作为 VCP（外部开源 AI 运行时）的桌面端观测与控制面——实时看 RAG 检索细节、元思考链、Agent 私聊预览、插件步骤状态，并把本机工具暴露给 VCP 云端 Agent。

**入口**：工具页 `/vcp-connector`（`VcpConnector.vue`，连接/监控/分布式三 Tab）。消息监控走两个 WebSocket 端点（`/vcpinfo/VCP_Key=<key>`、`/VCPlog/VCP_Key=<key>`），六类广播事件（RAG_RETRIEVAL_DETAILS / META_THINKING_CHAIN / AGENT_PRIVATE_CHAT_PREVIEW / AI_MEMO_RETRIEVAL / PLUGIN_STEP_STATUS / vcp_log）以虚拟滚动消息列表 + 分类卡片展示；历史消息持久化 `messages.json`。

**状态**：`config.json`（WS 地址/VCP Key）、`distributed-config.json`（节点名/暴露列表/自动注册开关）。分布式节点（AIO 作为节点被远端 `execute_tool` 调用，含 `internal_request_file` 强制内置）与工具桥（`VcpToolProxy` 把远端插件包装成本地 ToolRegistry）的执行细节已由 Agent 工具笔记第 7/9 节确认，本笔记不再重复。

**独特性判断**：这是"外部 Agent 协议"标签（待查清单聚类行）中唯一以监控面板 + 分布式节点双向形态出现的桌面实现；监控 UI 本身属于新覆盖面。

**证据强度**：ARCHITECTURE + Agent 工具笔记为静态事实；六类事件的真实渲染与断线重连未运行验证。

### 能力十：Recall 思绪集（世界书的 RAG 进阶版）— `主链确认`

**用户目标**：把旧 knowledge 拆分出的"语义条目召回"做成上下文即时召回层——比世界书（手动/关键词规则）更强的语义即时检索；传统文档库 RAG 的位置由重构后的 Knowledge 主动工具承担（不再是空壳）。

**入口与触发者**：工具页 `/recall` 提供工作区、统计、监控、实验室和设置；上下文管道以 priority 450 的 recall-processor 解析 `【recall::...】` 占位符，校验编码、数值范围以及未知或重复参数。旧 `【kb::...】` 只告警不执行。管道结合 Agent 绑定构造检索请求并调用即时召回入口；Agent 侧导出基础读写实例和管理实例，后者的方法均标记为可供 Agent 调用。

**事实对象**：RecallCollection 表示思绪集，RecallEntry 保存 key、Markdown 内容、带权标签、优先级、内容哈希和资产引用，RecallResult 保存分数、匹配类型和高亮，另有检索过滤条件对象；预设字段 `presetId: "algorithmic" | "comprehensive"` 的定义见 types/pipeline.ts。

**完整主链**：占位符或 Agent 绑定 → `resolvePlaceholderRetrieval`（`recall/logic/placeholderRetrieval.ts`）→ 按绑定/占位符参数（when/gate-tags/entries/limit/min-score）→ 检索管线执行 → 后置过滤 → `applyCharLimit`（maxRecallChars）→ `formatResults` 按结果模板格式化 → 注入上下文。Rust 侧旧 `recall/search/` 四引擎模块（keyword/vector/lens/blender）已并入**检索管线**（`src-tauri/src/recall/retrieval_pipeline.rs` + `retrieval_modules.rs`）：管线按预设（`Algorithmic`/`Comprehensive`）编排候选模块（内容向量/标签向量/Lens 关联等），产出带 `source_module_id`/ArtifactKey 的可追踪检索工件；`recall-monitor` 事件 + 心跳上报；检索缓存键含查询/集合/标签/数量/阈值/预设/模型等要素（提交 `d2d82c605`、`92d78971d`、`c46cc2fed`、`5403999b1`、`ad958b0fd` 等）。写入链：`recall_upsert_entry` 持久化 + 内存索引 → 前端索引编排器调 Embedding 模型 → `recall_update_entry_vector` 按模型隔离写向量 → 标签向量同步更新，HNSW 可按需重建。

**持续性**：存储已切换为 **SQLite 真源**，由 SqliteRecallRepository 落盘数据库和向量文件，旧 knowledge 数据经幂等迁移，备份过程通过 recall-backup-progress 事件报告。knowledge-base 已重构为主动工具，提供资料库列表和多策略搜索，支持 topK、过滤条件、相邻内容和字符上限，并收敛资料库访问授权、聊天显式资料引用、研究任务编排及 FTS/标签管理；关键存储定位见 `src-tauri/src/recall/storage/sqlite.rs`。

**独特性判断**：与 `worldbook-processor`（priority 300，基于 st-worldbook-manager 的手动/关键词匹配）同为"上下文即时注入"族，但 recall 提供语义向量召回 + 可插拔检索管线（预设/模块）+ 双 Agent 实例，是知识注入层的 RAG 进阶面；检索管线的模块化工件追踪（ArtifactKey/source_module_id）在样本中较完整。

**证据强度**：ARCHITECTURE.md 全文 + `recall-processor.ts` + `recall.registry.ts` + `retrieval_pipeline.rs` 静态事实；未运行验证向量召回质量、SQLite 迁移与 E2E 真实向量测试（`recall-e2e` preset 已建测试框架）。

### 能力十一：正则预设堆叠工作台（regex-applier）— `主链确认`

**用户目标**：补齐正则工具类"预设复用和堆叠预设"最后一截——把多条正则规则保存为可命名、可复制、可导入导出的预设，并在工作台按顺序叠加多个预设一次性应用（文本或批量文件），普通正则工具只有单条规则或固定规则集，无法组合复用。

**入口与触发者**：工具页 `/regex-applier`（`RegexApplier.vue`）；用户手动操作。Agent 方法未暴露——`getMetadata().methods` 为 TODO 空数组（`regex-applier.registry.ts:268-274`），探索代理确认与源码一致。

**事实对象**：`RegexPreset`（多条 `RegexRule` 规则链 + name/description）+ `PresetsConfig`（presets + activePresetId），持久化 `{appConfigDir}/regex_applier/presets.json`（ConfigManager 防抖 500ms 保存）；应用配置（processingMode/selectedPresetIds 组合）另存 appConfig。

**完整主链**：预设管理（`PresetManager.vue`：新建/复制/重命名/删除/切换激活/从 JSON 文件或剪贴板导入/导出，导入按 `regex::replacement` 键去重合并）→ 工作台"添加预设"多选 `selectedPresetIds: string[]` → 拖拽排序（VueDraggableNext，"按顺序应用"）→ `watch(selectedPresetIds, debouncedProcessText)` 防抖自动重处理 → JS 引擎 `applyRules` 逐条规则链替换实时预览；文件模式：Rust `validate_regex_pattern` 预校验（JS 与 Rust 正则差异如前瞻/后瞻）→ `process_files_with_regex` 批量处理（多预设规则展平为带 `preset_name` 的规则数组传后端）；一键处理 `oneClickProcess`（粘贴→处理→复制）走剪贴板链（`readText`/`writeText`）。

**持续性**：presets.json 重启恢复；规则链内每条规则可启停/重排；selectedPresetIds 组合记忆恢复上次堆叠。

**独特性判断**：与上下文管道内 regex-processor（请求层清洗）不同，这是面向用户的独立正则工作台，其"预设资产化 + 多预设有序堆叠"是该工具类中补齐复用与组合体验的产品面；预设可经 JSON 分享是 SillyTavern 生态同类（Regex 指令集）之外的通用格式。

**证据强度**：`core/presets.ts`、`stores/store.ts`、`core/engine.ts`（processText 多预设循环）、`RegexApplier.vue`（selectedPresetIds/拖拽/一键）静态事实；UI 行为未运行验证。

### 能力十二：Git 工作台与 AI 提交信息（git-committer）— `主链确认`

**用户目标**：把"仓库状态浏览 + 暂存/取消 + diff 审查 + 提交/推送"做成多仓库并发全景工作台，并让 LLM 根据实际 diff 流式生成 commit message——名字平淡，核心是 AI 提交助手。

**入口与触发者**：工具页 `/git-committer`；用户手动操作。无 Agent facade（registry methods 为空，Agent 工具笔记已 grep 确认）。

**事实对象**：`RepositoriesConfig`（多仓库列表）、`RepoStatus`（staged/unstaged/ahead 等）、DiffTab（original/modified）、提交草稿。

**完整主链**：`refreshStatus`（Rust `git_get_repo_status`）→ `stageFiles` 乐观更新（先移前端状态，失败回滚，成功再刷真实状态）→ `loadFileDiff`（`git_get_file_diff`，二进制降级 Tab）→ AI 生成：`buildDiffPrompt` 组装暂存文件 diff 文本（二进制占位"无文本差异"）→ `generateCommitMessage`（`useGitCommitterRunner.ts:385`）：`parseModelCombo` 取 LLM Profile → `useLlmRequest.sendRequest` 流式生成（systemPrompt 可自定义，`inspectorContext: { toolName: "git-committer", purpose: "generate-commit-message" }` 接入 llm-inspector）→ 用户确认后 `executeCommit`（可 pushAfter）→ 全景模式 `stageAllRepos`/`unstageAllRepos`/`pushAllRepos` 批量操作；切换仓库可选自动 pull。

**持续性**：仓库列表与应用配置持久化；无任务历史（提交本身在 git 内）。

**独特性判断**：git-analyzer（git2-rs 原生分析 + `getFormattedAnalysis` Agent 报告，formatters 统一 Agent 与 UI 输出）与其互补；"AI 生成提交信息 + 多仓库并发操作台"组合在样本桌面 AI 客户端中少见，AGENTS.md 也要求 AI 生成的提交遵循 Conventional Commits + 结构化中文描述，工具与仓库规范一致。

**证据强度**：`useGitCommitterRunner.ts` 全文 + registry 静态事实；未运行验证 LLM 输出质量与多仓库并发。仓库管理已重构，新增全景看板筛选（`PanoramaDashboard.vue` 按状态/标签等过滤仓库卡片，提交 `bef8660a8`），主链结论不受影响。

### 能力十三：全局 Token 基础设施（token-calculator）— `主链确认`（机制贡献）

**用户目标**：聊天上下文预算的底层支撑——按模型精确计 token（含多模态计费），被 llm-chat 的 token-limiter、上下文压缩、输入预览、响应处理九处以上消费；独立工具页只是它的调试面。

**入口与触发者**：工具页 `/token-calculator`；但实际主入口是**被消费**——`llm-chat/core/context-processors/token-limiter.ts`、`useContextCompressor`、`useChatInputTokenPreview`、`useChatResponseHandler`、`useChatExecutor`、`preview-builder`、`message-format-processors`、`llm-inspector/core/tokenEstimator.ts`、`translator`、`agent-manager` 均导入 `tokenCalculatorService`（`token-calculator.registry.ts:341`）。

**事实对象**：Tokenizer 资产注册表（bundled 内置 / local 本地文件 / remote 远程拉取三种来源 + 置信度 + modelId 匹配规则 + 校准参数）、TokenCount 结果（count/tokensPerSecond 等）。

**完整主链**：注册表按 modelId 规则解析 profile → 选择 tokenizer 资产 → Worker 线程执行（镜像按需推送 tokenizer.json，LRU 缓存）→ 多模态计费（OpenAI 图像瓦片、Gemini 2.0 固定/可变、Claude 固定成本、音频时长计费）→ 返回 count；调用方如 token-limiter 在管道阶段 600 按结果截断或压缩。

**持续性**：注册表持久化（bundled/local/remote 来源与校准参数）；Worker 资产按需下载缓存。

**独特性判断**：多数项目只有简单估算或单 tokenizer；这里做成"Tokenizer 资产注册表 + 校准 + 多模态计费 + Worker 隔离"的全局基础设施，直接影响聊天上下文预算决策。按调查指南，工程机制单独标注，不与用户可见能力混计。

**证据强度**：registry + `tokenizerRegistryStore.ts`（含"即使没有任何 UI 进入工具页，只要有其他模块消费也启动"注释，`:475`）+ 9+ 消费点静态事实；真实计费精度未运行验证。内置 Tokenizer 已资产化（`data/builtin-tokenizer-assets-manifest.ts` + `builtin-tokenizer-index.ts`），移除动态 JS loader，Worker 计算与注册表持久化链路重构（提交 `2b2252541`），内置分词资产随包分发、不再依赖运行时拉取脚本。

### 能力十四：网页蒸馏室（web-distillery）— `主链确认`

**用户目标**：把任意网页"蒸馏"成干净内容（Agent 与人工两个场景），突破 Tauri WebView 同源限制并绕过常见反爬检测——名字是蒸馏室，实际是带反检测代理的网页读取手。

**入口与触发者**：工具页 `/web-distillery`（5 Tab：蒸馏工作台/交互模式/身份卡片/配方管理/API 嗅探）；Agent 侧 `quickFetch`/`smartExtract` 两个 `agentCallable` 方法。

**事实对象**：`FetchResult`、`Recipe`（站点配方：提取规则 + 动作序列）、`CookieProfile`（身份卡片）；配方与身份持久化。

**完整主链**：三层蒸馏——`fast` 纯 HTTP `quickFetch`（毫秒级）；`smart` 隐藏 Iframe + JS 渲染（SPA 支持）；`interactive` 可视化浏览器视口人工拾取规则。smart/interactive 走 Rust Axum 本地代理（`127.0.0.1:0` 随机端口，`distillery_start_proxy`）：`handle_proxy_html` 获取目标 HTML 并剥除 `X-Frame-Options`/`Content-Security-Policy`/Content-Encoding 头（防 iframe 拦截）→ 同步注入 `anti-detection.js`（隐藏 `window.chrome.webview`/`webkit.messageHandlers`、覆盖 `navigator.webdriver=false`、伪装 chrome 插件环境、requestIdleCallback 延迟隐藏桥全局变量）→ defer 注入 `bridge.js`（含随机 nonce 防重放，postMessage 双向通信）+ `api-sniffer.js`（拦截 XHR/fetch 嗅探 JSON API）→ 前端 `transformer.ts` 六阶段蒸馏管道（HTML 解析/元数据/去噪/主内容 Readability/格式转换/后处理）→ 配方 `action-runner.ts` 执行动作序列（click/scroll/input/wait）→ Cookie 身份卡按域匹配注入 → 结果格式化供 Agent/UI。

**持续性**：配方（`recipe-store.ts`）与 Cookie 身份（`cookie-profile-store.ts`）持久化；内置配方库 + 用户自定义。

**安全与资源边界**：代理仅本机回环端口；`url` 参数无域名白名单（Tauri `http:allow-fetch` 放开全协议，Agent 工具笔记第 7 节已记录）；反检测注入是主动规避网站检测的行为面。

**独特性判断**：普通网页抓取工具只有 fetch 或浏览器渲染；此工具把"反检测代理 + API 嗅探 + 身份复用 + 配方动作序列"做成完整产品面，且是 Agent 的网页读取手。Agent 工具笔记只覆盖了调用面（quickFetch/smartExtract），产品面本笔记补全。

**证据强度**：ARCHITECTURE.md 全文 + `core/*` + Rust `proxy.rs` 静态事实；未运行验证真实反爬站点与 SPA 渲染。

### 能力十五：窗口自动化流程语言（window-automator）— `主链确认`

**用户目标**：可视化编排"点击/输入/取色/截图/OCR 判断"的桌面自动化流程，并支持子流程函数调用、变量作用域与条件跳转——实际是一个迷你自动化语言。

**入口与触发者**：工具页 `/window-automator`；用户手动编排执行。无 `agentCallable`（Agent 工具笔记已确认）。

**事实对象**：`Flow`（步骤列表，主流程 + 多个子流程）、`CallStepParams`/`GotoStepParams`/`CounterStepParams` 等步骤类型（click/input/colorCheck/goto/counter/ocr/call 等 10 类）、runtime（counters/variables/callStack）。

**完整主链**：流程执行器按步骤运行；call 步骤支持子流程函数式调用、形参实参、变量插值、返回值写回局部变量，并把调用栈深度限制为 10 层。goto、colorCheck、counter 和 ocr 组成条件跳转体系，只允许在子流程内跳转，跨流程跳转被禁止（`types.ts:230-231`）。OCR 步骤动态复用 smart-ocr 引擎，随后记录执行日志并高亮调用方；流程按步骤类型白名单持久化，删除子流程时自动清理相关调用引用。OCR 复用入口见 `stepExecutors.ts:416-422`。

**独特性判断**：普通窗口自动化工具只有录制回放；这里提供"函数调用 + 变量作用域 + 条件跳转 + OCR 联动"的流程语言，且与 smart-ocr 平台层形成跨工具闭环，接近小型 RPA 语言。无 LLM 参与（无理解窗口/生成流程）。

**证据强度**：`types.ts`/`useFlowExecutor.ts`/`stepExecutors.ts`/`flowTransforms.ts`/store + 测试静态事实；未运行验证真实窗口操作。

### 能力十六：实时字幕 OCR（realtime-subtitle-ocr）— `主链确认`

**用户目标**：把屏幕某区域（如视频字幕区）高频采样识别成带时间轴的字幕，可实时编辑、导出 SRT、一键发送到全局 Chat——"屏幕监控 → OCR → 聊天管道"完整链路。

**入口与触发者**：工具页 `/realtime-subtitle-ocr`；用户手动启停监控。

**事实对象**：字幕时间轴条目（文本 + 相对时间戳）、监控配置（采样频率 500-3000ms/去重灵敏度高-中-低/OCR 引擎）、`MonitorBox` 悬浮窗几何信息。

**完整主链**：屏幕监控定时调用 `capture_screen_rect`，由 Rust Windows GDI 抓取绝对坐标区域像素并计算 aHash；前端比较汉明距离，按高、中、低三档使用 2、4、8 的阈值，无变化则顺延当前字幕结束时间且不传 PNG，有变化才编码图像。随后复用 smart-ocr 平台识别，编辑距离相似度达到 90% 时更新原字幕，否则新建条目；文本可在编辑面板中提交，一键发送到全局 Chat 或导出 `.srt`。

**持续性**：监控配置 ConfigManager 防抖持久化；字幕时间轴在会话内（清空按钮），不落盘。

**独特性判断**：普通 OCR 工具是单张/批量识别；这里是"持续监控 + 帧去重 + 字幕语义合并 + 跨窗口注入聊天"的实时链路，MonitorBox 还复用自由窗口基础设施（透明/无边框/置顶悬浮窗）。与 danmaku-player 无联动（探索确认）。

**证据强度**：ARCHITECTURE.md 全文 + `useScreenMonitor.ts` 静态事实；未运行验证实际采样延迟与识别质量。

### 能力十七：长文本分片翻译（translator）— `主链确认`

**用户目标**：把超长文本（上限 100 万字符）拆片并发翻译，并让后续分片继承上一分片术语/人称/语气/风格，解决长文翻译的上下文一致性；渠道预设对比选优。

**入口与触发者**：工具页 `/translator`（多渠道并发对比 + 预设系统）；用户手动。

**事实对象**：`LongTextTask`（chunks 状态机 idle/waiting/completed/error + progress）、`TranslationChannel`（profile+model+prompt）、渠道预设。

**完整主链**：`useLongTextTranslator` → `recursiveSplitText` 递归分片 → `ConcurrencyLimiter` 限流并发翻译（`maxConcurrentChunks`）→ `buildLongTextPrompt`：有上一分片时注入 `<source_context>`/`<translation_context>`（仅上一分片，不重复翻译上文参考）→ `translateChunkWithRetry` 重试（429/timeout/503 等模式，最多 3 次）→ 流式 chunk 追加更新进度 → `joinTranslatedChunks` 合并；token 精确估算接入 token-calculator（`useTranslatorStore.ts:97-110`，防抖 500ms），超限风险事前预警。

**持续性**：渠道预设持久化；任务状态在内存。

**独特性判断**：普通翻译工具有多 API/历史记录；这里的"分片上下文继承 + 并发限流 + 精确 token 预算"是针对长文档的工程化处理。术语表/批量文件翻译仅在设计文档阶段未实现（探索确认）。

**证据强度**：`useLongTextTranslator.ts` 全文 + store 静态事实；未运行验证长文一致性。

### 能力十八：内容查重器（content-deduplicator）— `主链确认`（辅助）

**用户目标**：扫描目录找出重复/近似重复文件，按可配置规范化规则识别仅空白/标点/大小写差异的"规范化副本"，回收站删除。

**完整主链**：Rust `scan_duplicates` 五阶段漏斗（尺寸分桶 → 前/后 4KB 快速指纹 → BLAKE3 全文哈希 → 规范化哈希匹配 → 结果分组）→ 进度事件 + 取消机制（`DedupScanCancellation`）→ 回收站删除。Agent 侧 `scanDuplicates`（4 预设）已由 Agent 工具笔记表格记录。

**明确边界**：**非语义/模糊去重**——`fuzzy` 模糊匹配标注未实现、`minSimilarity` 为 dead code，自定义忽略模式未生效（探索代理源码确认）；可识别的是规范化副本而非近似文本。

**独特性判断**：普通查重只做哈希精确匹配；五阶段漏斗 + 规范化匹配是性能与能力上的增强，但属工程机制辅助，不按用户可见产品面独立计主贡献。

**证据强度**：`content_deduplicator.rs` 头部 + 探索代理交叉验证；未运行。

### 能力十九：弹幕播放器与外部播放器覆盖层（danmaku-player）— `主链确认`

**用户目标**：两条使用路径——内置播放器加载本地视频 + ASS/B 站 JSON/XML 弹幕 + 外挂字幕在同一窗口渲染；外部播放器覆盖层把透明弹幕窗口同步到 MPC-BE/MPC-HC/PotPlayer/mpv/VLC 客户区正上方，在第三方播放器上叠显弹幕。名字平淡，实为跨播放器弹幕基础设施。

**入口与触发者**：工具页 `/danmaku-player`（`DanmakuPlayer.vue` 模式切换/文件拖放）；用户手动操作。无 Agent 方法（registry 仅 `initialize`，`danmaku-player.registry.ts:22-31`）。

**事实对象**：`ParsedDanmaku`（统一弹幕行，时间秒，坐标基于 ASS `PlayResX/PlayResY`，滚动弹幕用 x1/y1→x2/y2 + t1/t2 表达移动）、`SubtitleTrack`（cues + ASS/SSA 原文 rawContent）、`DanmakuConfig`（类型/彩色/密度/显示区域/透明度/字号/速度/字体/描边/屏蔽词）、`ExternalPlayerConfig`/`OverlayState`（播放器类型、端口/IPC、裁切、全屏增强、目标 HWND、播放状态）。

**完整主链**（内置模式）：视频 `convertFileSrc` → 弹幕文件 `smartDecode()` 解码 → `parseDanmaku`（ASS + B 站 JSON `DanmakuElem[]` + B 站 XML `<d p=...>`）→ 字幕 `parseSubtitle`（SRT/VTT/ASS/SSA/LRC/SBV/SubViewer/MicroDVD/SAMI/TTML；IDX/SUP 图形字幕拒绝）→ `DanmakuEngine` 绑定 HTML5 video `currentTime`：`setDanmakus` 按 startTime 排序并预计算每条稳定哈希（`danmakuEngine.ts:67-75`）→ 每帧二分查找可见窗口（回溯最多 20s，`getVisibleWindow`）→ 内联执行类型/彩色/密度/屏蔽词过滤 + 显示区域限制 → Canvas 2D 绘制（描边/阴影/字体缩放缓存）→ 渲染节流约 30fps，无弹幕时停止 rAF。字幕双轨：普通文本走 DOM `SubtitleOverlay`（按当前时间筛选 active cues）；ASS/SSA 优先 `JassubRenderer` 动态 `import("jassub")` 高保真渲染（`object-fit: contain` 计算 letterbox 内实际视频区 + 极小 `backdrop-filter` 触发 WebView2 正常合成路径规避硬件 overlay 不可见），初始化失败降级 DOM（`JassubRenderer.vue:163`）。

**完整主链**（外部覆盖模式）：`useExternalPlayer` 按播放器类型自动扫描常见 Win32 类名（`find_player_windows`，也可全量扫描手动选 HWND）→ `TauriExternalPlayerStatusProvider` 统一 `get_external_player_status` 读状态（MPC-BE/MPC-HC：`variables.html` 按 `<p id>` 提取 file/state/position/duration；PotPlayer 实验：SMTC session 优先、无则发 `WM_USER` 消息；mpv：JSON IPC named pipe `--input-ipc-server`；VLC：`requests/status.json` + Basic Auth；均经 Rust 代理规避 CSP）→ `create_danmaku_overlay_window`（透明、无边框、跳过任务栏、鼠标穿透）→ 主窗口经 `danmaku-overlay:init/config-update/danmaku-update/stop` 事件同步数据与配置 → 覆盖窗口内最小渲染应用（`DanmakuOverlayApp.vue`：透明 Canvas + DanmakuEngine + 状态 provider + 虚拟时钟）→ 虚拟时钟（`useVirtualClock.ts`）：rAF 帧增量推进（播放速率可调）、每 200ms 轮询真实进度、偏差超 500ms 才校准（`CALIBRATION_THRESHOLD = 0.5`，防微小抖动跳帧）、暂停→播放强制校准、seek 后 `seekTo` 复位 → 位置同步（`useDanmakuOverlay.ts`）：`get_player_window_rect` 取物理像素 → 按 `scaleFactor` 转逻辑像素 → 普通/全屏分别应用 `offsetTop/offsetBottom` 裁切 → 默认 100ms 同步，检测到位置/尺寸/DPI/全屏变化进入 1s 活跃期改 16ms → 每轮刷新 Z-Order（全屏增强时 `HWND_TOPMOST`）→ 目标 HWND 失效自动关闭覆盖窗口。

**持续性**：弹幕显示配置（`useDanmakuConfig`）与外部播放器配置（`useExternalPlayer`）均 ConfigManager 防抖持久化；覆盖窗口位置不落盘，每次启动重新扫描对齐。

**主动性与取消**：无后台常驻（外部模式仅工具页挂载期间轮询 1s 预览 + 200ms 对时）；用户可随时关闭覆盖窗口、停止位置同步。

**安全与资源边界**：外部模式仅 Windows（Rust command 全部 `#[cfg(windows)]`）；Tauri 前端不直接请求播放器本地接口，统一走 Rust 代理规避 CSP/scope 限制；外部模式只显示弹幕不加载外挂字幕；图形字幕 IDX/SUP 不支持。

**独特性判断**：普通视频工具只有内置播放器；"透明覆盖层跟随外部播放器客户区 + 虚拟时钟对时 + 稳定哈希密度过滤（调密度不闪烁）+ JASSUB 高保真降级链"是跨播放器弹幕的完整桌面产品面，同类桌面弹幕工具（弹弹play 等）在 AI 客户端内属少见实现。与自由窗口基础设施不同：这是对任意第三方播放器窗口的 HWND 级跟随。

**证据强度**：ARCHITECTURE.md 全文 + `useVirtualClock.ts`/`useExternalPlayer.ts`/`useDanmakuOverlay.ts`/`danmakuEngine.ts`/`JassubRenderer.vue` 静态事实；未运行验证真实播放器窗口跟随与渲染效果，PotPlayer 状态同步为实验支持。

### 第二梯队与确认无隐藏特性的工具

- **入口确认（第二梯队，未走完整主链）**：`embedding-playground`（A/B 对比/1:N 排行/多模型竞技场 + 百分位阈值校准 + RAG 检索模拟，无 Agent 暴露）；`media-info-reader`（EXIF/WebUI/PNG 三层 + AioBundle 解析，`readImageMetadata` agentCallable）；`user-profile-manager`（richTextStyleOptions/regexConfig/worldbookIds/quickActionSetIds 跨工具配置中枢，被 llm-chat 消费）；`text-diff`（Monaco diff + 拖文件自动分左右 + `generatePatch` agentCallable 生成 unified diff）；`api-tester`（REST/GraphQL/LLM 预设 + `{{variable}}` 模板变量 + SSE 渲染 + 请求档案恢复）；`config-converter`（6 格式 N×N 互转 + 有损转换警告 + 批量模式）；`data-filter`（深层路径/多键 OR/自定义 JS 条件，Agent `applyFilter` 输出 Markdown 报表）；`dir-search`（Rust 并行流式搜索 + GBK 回退 + 单项替换 preserveCase + 文件整理，Agent 搜索替换）；`directory-janitor`（Agent 可远程触发的扫描+回收站清理，删除能力下放给 Agent）；`git-analyzer`（git2-rs 原生 + 流式加载 + Agent `getFormattedAnalysis` 20 参数报告）；`color-picker`（三算法并行 + Dexie 历史 + EyeDropper 回退，图片走资产库）。
- **确认无隐藏特性（全量扫描结论）**：`code-formatter`（纯 Prettier 静态/动态混合插件加载，不调 LLM）；`json-formatter`（无 AI 修复，sortKeys 为半成品设置）；`component-tester`（内部开发调试工具）；`symlink-mover`（双模式 + 历史日志，无跨工具面）；`system-pulse`（技术扎实的推送式仪表盘但仅页面挂载启停、无后台常驻/Agent/被引用）；`service-monitor`（只读 API 文档浏览器，无实时监听）；`wallpaper-detector`（跨平台探测但仅手动刷新）；`regex-applier` 的 Agent 面（methods 为 TODO）。

### 归并说明：上下文分析器与正则管道

- **上下文分析器**：对话请求与上下文笔记 9.8 已确认（复用真实管道预览、五视图界面在 Chat UI 6.3），标 `归并已有类目`，不重复计数。
- **正则处理管道**：管道内 `regex-processor`（`core/context-processors/regex-processor.ts:100`，priority 200）按角色与深度过滤规则，Global/Agent/User 三层配置合并（`resolveRawRules`），发送前清洗（如隐藏思维链）；渲染前转换（"自定义标签渲染"）在消息渲染器笔记的格式阶段。该能力是"上下文 DSL"聚类成员，与宏系统同族，但注入点与数据模型（`ChatRegexRule`）已由上下文类目完整解释，本次仅补三层合并细节，标 `归并已有类目` + 宏系统独立计数。
- **ST 世界书管理器与运行时**：`st-worldbook-manager` 已确认本地持久化、详情编辑、JSON/`.lorebook` 与角色卡 PNG/AIO Bundle 导入、ST/AIO 导出、Agent/User Profile 绑定和跨窗口同步；`worldbook-processor` 会在真实请求中执行关键词/正则、selective、概率、扫描深度、过滤、递归、包含组、加权选择与位置注入。标 `归并已有类目（主链确认）`，由 Agent 角色笔记和上下文笔记承接，特色统计的 F03 已给 AIO 辅助贡献，故本篇不新增分数。兼容度要按“格式、编辑、运行、生态协议”四层判断：部分 ST 字段只有保存/编辑而没有消费链，部分锚点降级映射，`sticky/cooldown/delay` 则是运行时已支持而编辑器缺控件。

## 已归并到现有类目的能力

| 能力 | 归并去向 |
|---|---|
| 上下文分析器 | [`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md) 9.8 |
| 上下文压缩 | 同上附录 A |
| 会话变量/快照 | 同上 9.4 + 会话与消息管理笔记 1.3 |
| 世界书管理/编辑/导入导出与运行时注入 | 同上 9.2/9.6 + [`../Agent角色/AIO-Hub-Agent角色配置调查笔记.md`](../Agent角色/AIO-Hub-Agent角色配置调查笔记.md) 5.1（`st-worldbook-manager` 与 `worldbook-processor` 主链确认；ST 兼容为可执行子集，与 recall 语义召回不同层） |
| 知识库占位符注入点 | 同上 9.6 + 上下文编译边界研究（`knowledge-processor` 已删除，由 `recall-processor` 解析 `【recall::...】` 占位符调用 `resolvePlaceholderRetrieval`；注入点归上下文类目，Recall 领域本体由本笔记能力十承接） |
| 工具调用基础设施（含插件注册为 ToolRegistry、VCP 协议、异步任务） | [`../Agent工具/AIO-Hub-Agent工具调查笔记.md`](../Agent工具/AIO-Hub-Agent工具调查笔记.md) |
| Skill 工具执行细节（路径锁定/超时） | 同上第 4/7/9 节 |
| VCP 分布式节点与工具桥 | 同上第 7/9 节 |
| web-distillery 的 Agent 调用面（quickFetch/smartExtract）与网络权限边界 | 同上第 4/7 节（产品面：反检测代理/API 嗅探/配方/身份由本笔记能力十四承接） |
| aio-file-operator 安全模型（白名单/死区/审批区）与 ffmpeg 子进程边界 | 同上第 4/9 节 + 生成式输出与运行时笔记 |
| recall/recall-admin 的 Agent 方法面 | 同上第 4 节（检索领域本体由本笔记能力十承接） |
| 富文本渲染引擎（AST/Patch、交互按钮、VCP 可视化） | [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)、生成式输出与运行时笔记 |
| 对话树图、撤销重做、分支语义 | 会话与消息管理笔记 |
| 自由窗口在聊天气泡/输入框的具体同步 | Chat UI 笔记 8.2 |
| 转写任务与上下文注入（transcription-processor） | 对话请求与上下文笔记 9.6 + Chat UI 3.4（转写工作台任务面未单独走主链，标注于能力十二附注的 ffmpeg 回流链） |

## 声明不符、外部依赖与暂缓项

- **media-generator `generateMedia` Agent 方法**：`media-generator/ARCHITECTURE.md:410` 明确声明该方法"在 `getMetadata()` 中有声明但尚未实现"，是前服务系统占位；Agent 触发生成实际走 `buildAgentMethods` 动态方法族。README 未单独宣称该方法，属文档内自述的占位，标 `声明不符`（文档对代码）。
- **regex-applier 的 Agent 面**：`getFormattedTextResult`/`getFormattedFileResult` 方法已完整实现（`regex-applier.registry.ts:223-261`），但 `getMetadata().methods` 为 TODO 空数组——接口可用、注册未通，Agent 无法实际调用，标 `声明不符`（代码对注册）。
- **content-deduplicator 的 fuzzy 模糊匹配**：ARCHITECTURE 相关描述与代码不一致——`minSimilarity` 为 dead code、模糊匹配标注未实现、自定义忽略模式未生效；实际能力为精确哈希 + 规范化匹配，非语义去重，标 `声明不符`（介绍对实现）。
- **插件目录是独立仓库**：`plugins/` 已被主仓库 `.gitignore`（`plugins/README.md`），示例插件托管在独立 GitHub 仓库；运行时从 `%APPDATA%/com.aio-hub.app/plugins/` 加载。多运行时插件的完整安装/分发链路本次未验证，标 `暂缓`。
- **移动端**（`mobile/`）为独立 Tauri 应用且私有许可证，本轮未调查，标 `暂缓`。
- **media-info-reader 的 A1111/ComfyUI/ST 角色卡元数据提取**：README 列出但不在待查清单，属工具清单成员，本轮未走主链，不计数。
- **translator 术语表/批量文件翻译**：仅在设计文档阶段，未实现（探索代理源码确认），标 `声明不符`（文档对代码）。

## 对特色贡献统计的影响

按调查指南"只有 `主链确认` 才能作为主贡献/辅助贡献进入特色统计"：

- 主贡献候选（能力族，不拆小工具）：媒体工作站、资产管理器、LLM 请求检查器、快捷动作、宏系统、自由窗口、Agent 私有资产、Skill 沙箱、Recall 思绪集、Git 工作台与 AI 提交信息、正则预设堆叠工作台、网页蒸馏室、窗口自动化流程语言、实时字幕 OCR、长文本分片翻译、弹幕播放器与外部播放器覆盖层——16 个能力族达到 `主链确认`（静态证据）。
- 辅助贡献：VCP 监控面板（`入口确认`）、多运行时插件（`入口确认`）、内容查重器（`主链确认`但属工程机制辅助，建议单列）。
- 机制贡献单独标注（不参与产品总分）：token-calculator（全局 Token 基础设施）、smart-ocr 平台层（OCR 引擎复用面）、ffmpeg-tools 跨工具回流链、资产管理器 Rust 索引、llm-inspector 流式节流。
- 同一工作流合并计数：宏系统与正则管道同属"上下文 DSL"聚类，但管道正则已归并上下文类目，仅宏系统独立计数；快捷动作依赖宏引擎但不并入宏系统；正则预设堆叠工作台（regex-applier）与上下文管道 regex-processor 用户目标不同（用户工具 vs 请求清洗），独立计数；recall 与 worldbook 注入同属"上下文即时注入"族但事实对象与引擎不同（语义条目+向量引擎 vs 世界书文档+规则匹配），按能力族独立计数。
- 第二梯队（`入口确认`，embedding-playground、media-info-reader、user-profile-manager、text-diff、api-tester、config-converter、data-filter、dir-search、directory-janitor、git-analyzer、color-picker）不进统计，待补主链。`st-worldbook-manager` 已移出本列表并归并 F03，现有辅助贡献不变。

## 未验证事项

- 全部能力均未运行验证：Tauri 分离窗口的视觉/拖拽行为、媒体生成真实 API 调用与内嵌元数据、llm-inspector 代理转发与 SSE 解析、快捷动作自动发送时序、宏展开的运行时输出、Skill 脚本多运行时探测（Windows 下 bash/sh 断层见 Agent 工具笔记）、Recall 向量召回质量与数据迁移、regex-applier 多预设堆叠的真实 UI 行为、git-committer AI 提交信息输出质量、token-calculator 计费精度、web-distillery 真实反爬站点与 SPA 渲染、window-automator 真实窗口操作、realtime-subtitle-ocr 采样延迟、translator 长文一致性、danmaku-player 真实播放器窗口跟随与 PotPlayer 实验状态读取、JASSUB 渲染效果。
- 资产管理器 10 万+ 资产索引性能上限未实测；`rebuild_hash_index` 未运行。
- VCP 监控六类事件的真实渲染、断线重连、双 WebSocket 状态机未运行验证。
- 宏数量统计基于静态正则（`name: "..."` 匹配），可能存在个别未注册或条件注册的宏未计入；74 个是当前快照的注册面统计（knowledge 1 + recall 2）。
- content-deduplicator 的 `fuzzy` 模糊匹配与 `minSimilarity` 已确认未实现（dead code），但自定义忽略模式是否残留 UI 入口未逐 UI 验证。
- regex-applier 的 Agent 方法（`getFormattedTextResult`/`getFormattedFileResult`）已实现但 `getMetadata` 未暴露，属接口可用、注册未通的半成品面。
- ST 世界书尚未用真实 V2/V3 样本完成导入、编辑、运行、导出和再导入的往返测试；`keys`/`secondary_keys` 与 `key`/`keysecondary`、`character_filter` 的归一化差异保留为兼容风险。

## 关键源码索引

- `src/tools/media-generator/media-generator.registry.ts`（toolConfig 与动态 Agent 方法注册）、`ARCHITECTURE.md`、`stores/mediaGenStore.ts`
- `src/composables/useAssetManager.ts`（全局单例）、`src-tauri/src/commands/asset_manager.rs:870`（import_asset_from_bytes 去重链）
- `src/tools/llm-inspector/ARCHITECTURE.md`、`core/hookRegistry.ts`、`src/llm-apis/common.ts:697`（fetchWithTimeout 埋点）
- `src/tools/llm-chat/stores/messageInputStore.ts:328`（handleQuickAction）、`services/quickActionImportService.ts`、`composables/storage/useQuickActionStorage.ts:40`
- `src/tools/llm-chat/macro-engine/MacroProcessor.ts:84`（三阶段）、`MacroRegistry.ts`、`macros/*.ts`（74 宏）
- `src/tools/llm-chat/core/context-processors/regex-processor.ts:100`（三层合并 + 角色/深度过滤）、`worldbook-processor.ts`（priority 300）、`recall-processor.ts`（priority 450，占位符 → RecallRetrievalRequest；替换原 knowledge-processor）
- `src/composables/useDetachable.ts`、`useDetachedManager.ts`、`src/views/DetachedWindowContainer.vue`、`docs/guide/detached-window-system.md`
- `src/tools/agent-manager/utils/agentAssetUtils.ts`、`components/assets/AgentAssetsManager.vue`、`src/tools/llm-chat/macro-engine/macros/assets.ts`
- `src/tools/skill-manager/ARCHITECTURE.md`、`services/SkillManagerProxy.ts`、`src-tauri/src/commands/skill_manager.rs`
- `src/tools/vcp-connector/ARCHITECTURE.md`、`stores/vcpConnectorStore.ts`
- `src/tools/recall/ARCHITECTURE.md`、`logic/placeholderRetrieval.ts:36`（占位符即时召回）、`services/api.ts`（searchWithCache/resolvePlaceholderRetrieval）、`recall.registry.ts`（recall-basic/recall-admin 双实例）、`src-tauri/src/recall/`（retrieval_pipeline.rs/retrieval_modules.rs 检索管线，替换旧四引擎 search/）、`src-tauri/src/recall/storage/sqlite.rs`（SqliteRecallRepository）
- `src/tools/regex-applier/core/presets.ts`、`stores/store.ts`（预设 CRUD/导入去重）、`core/engine.ts:209,279`（processText/processFiles 多预设循环）、`RegexApplier.vue`（selectedPresetIds/拖拽排序/一键处理）、`regex-applier.registry.ts:268`（Agent 面 TODO）
- `src/tools/git-committer/composables/useGitCommitterRunner.ts:385`（generateCommitMessage 流式链）、`src/tools/git-analyzer/`（git2-rs + getFormattedAnalysis）
- `src/tools/token-calculator/token-calculator.registry.ts:341`（tokenCalculatorService）、`stores/tokenizerRegistryStore.ts:475`（无 UI 也启动）、`core/tokenCalculatorEngine.ts`（多模态计费）
- `src/tools/web-distillery/ARCHITECTURE.md`、`core/recipe-store.ts`、`core/action-runner.ts`、`src-tauri/src/web_distillery/proxy.rs`（剥头/注入）
- `src/tools/window-automator/types.ts`（步骤类型/子流程跳转限制）、`composables/useFlowExecutor.ts`（MAX_CALL_DEPTH）、`composables/stepExecutors.ts:416`（OCR 复用 smart-ocr）
- `src/tools/realtime-subtitle-ocr/ARCHITECTURE.md`、`composables/useScreenMonitor.ts`（aHash/编辑距离/发送到 Chat）、`src-tauri/src/commands/window_automator.rs`（capture_screen_rect）
- `src/tools/translator/composables/useLongTextTranslator.ts`（分片/限流/上下文继承）、`core/textSplitter.ts`
- `src-tauri/src/commands/content_deduplicator.rs`（五阶段漏斗/规范化选项）、`src/tools/smart-ocr/platform/runner.ts`（useOcrRunner 共享层）
- `src/tools/danmaku-player/ARCHITECTURE.md`、`composables/useVirtualClock.ts`（虚拟时钟 + 500ms 校准阈值）、`composables/useDanmakuOverlay.ts`（位置同步/裁切/Z-Order/HWND 失效自愈）、`composables/useExternalPlayer.ts`（窗口扫描/1s 状态轮询）、`core/danmakuEngine.ts`（二分查找/稳定哈希密度过滤）、`components/JassubRenderer.vue:163`（降级链）、`src-tauri/src/commands/external_player.rs`（Win32 覆盖窗口/五播放器状态读取）
- `src/tools/ffmpeg-tools/composables/useFFmpegIntegration.ts:44`（sendToChat 回流）、`llmChatService.addAttachmentsFromPaths`
- `src/services/auto-register.ts:62`（registry 扫描）、`src/stores/tools.ts`（工具页面注册）
