# AIO Hub 独特功能调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 调查方式：只读通读根 README、`docs/architecture/tools-architecture-overview.md`、全部 46 个 `src/tools/*.registry.ts`、目标模块 ARCHITECTURE 文档与关键实现（media-generator、asset-manager、llm-inspector、vcp-connector、skill-manager、macro-engine、quick-action、useDetachedManager、Rust `asset_manager.rs`）；未运行 Tauri 应用，未修改被调查仓库
>
> 调查范围：待查清单第二批候选（上下文分析器、宏与正则管道、快捷动作、Agent 私有资产、自由窗口、媒体工作站、资产管理器、多运行时插件、Skill 沙箱、请求检查器、VCP 监控）的入口、状态、执行与持久化主链；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的独特功能集中在"**本地工具枢纽 + 上下文工程**"两翼。去除 Chat/上下文/AST/Agent 已有覆盖后，本仓库仍独立成立的能力族有九项，其中七项本次达到 `主链确认`（静态证据）：

1. **媒体工作站（media-generator）**：会话-任务双轨、全局任务池、树形分支、参数清洁与资产回流，是完整的创作工作流（`主链确认`）。
2. **中央资产管理器（asset-manager）**：`$APPDATA/assets/` + SHA-256 去重 + Rust `assets.jsonl` 索引 + 来源追踪，是跨工具的资产事实源（`主链确认`）。
3. **LLM 请求检查器（llm-inspector）**：Rust 外部代理 + 前端内部钩子双层监控，可透视应用内所有 LLM 调用（`主链确认`）。
4. **快捷动作系统（Quick Actions）**：宏模板 + 行级后处理 + 自动发送 + SillyTavern Quick Reply 导入（`主链确认`）。
5. **宏系统**：实际注册 72 个内建宏（README 宣称 60+），三阶段管道 PRE_PROCESS/SUBSTITUTE/POST_PROCESS（`主链确认`，与上下文类目交界）。
6. **自由窗口管理**：组件级分离窗口 + logicHook 响应式同步 + 位置记忆/可见性自愈（`主链确认`）。
7. **Agent 私有资产**：`agent-asset://` 协议 + `{{assets}}` 宏 + 渲染器解析链（`主链确认`）。
8. **Skill 沙箱**：Rust 路径锁定 + 超时 + 多运行时探测，渐进式披露（`主链确认`，执行细节已由 Agent 工具笔记承接）。
9. **VCP 监控与双向桥接（vcp-connector）**：observer 消息监控 + 分布式节点 + 工具桥（`入口确认`；节点与桥接已由 Agent 工具笔记承接）。

归并已有类目：上下文分析器（对话请求与上下文笔记 9.8 已确认复用真实管道预览）、正则处理管道（同一笔记第 2 节管道处理器；本次补充 Global/Agent/User 三层合并细节）。多运行时插件系统的 Agent 工具面已由 Agent 工具笔记覆盖，其 UI/生命周期扩展面本次标 `入口确认`。

声明不符项：README/ARCHITECTURE 中 media-generator 的 `generateMedia(prompt, type)` Agent 方法声明存在但**未实现**（占位，见 `media-generator/ARCHITECTURE.md:410`）。

## 介绍声明与候选盘点

根 README（299 行）将产品定位为"一站式 AI 创作与开发工作站 + 专业级上下文工程引擎"，功能面非常宽。`docs/architecture/tools-architecture-overview.md`（2026-06-30 生成，39 个模块）与当前 `src/tools/` 实际 46 个 registry 文件基本一致，是本轮候选盘点的可靠索引。46 个工具中，与现有十类笔记重叠（Chat/上下文/会话/渲染/AST/Agent 工具与角色/渠道）的主要是 `llm-chat`、`rich-text-renderer`、`tool-calling`、`knowledge-base`、`web-canvas` 等；其余工具构成"工具枢纽"产品面。

| 候选（待查清单第二批） | 证据状态 | 结论 |
|---|---|---|
| 上下文分析器 | `归并已有类目` | 对话请求与上下文笔记 9.8 已确认：以所选节点为终点重跑真实上下文管道预览 |
| 60+ 宏与正则管道 | `主链确认` | 内建宏 72 个（macro-engine/macros/*.ts）；regex-processor 为管道处理器（priority 200），Global/Agent/User 三层合并 |
| 快捷动作 | `主链确认` | messageInputStore.handleQuickAction 完整执行链 + quick-actions 目录持久化 |
| Agent 私有资产 | `主链确认` | `agent-asset://` 协议 + AgentAssetsManager + `{{assets}}` 宏 + 渲染器 resolveAsset |
| 自由窗口 | `主链确认` | useDetachable/useDetachedManager + DetachedComponentContainer + logicHook 同步 |
| 媒体工作站 | `主链确认` | media-generator 双轨架构，本次走通完整主链 |
| 资产管理器 | `主链确认` | Rust `import_asset_from_bytes` SHA-256 去重 + `assets.jsonl` 索引 |
| 多运行时插件 | `入口确认` | JS/Native/Sidecar 三类（plugins/README + plugin-manager）；Agent 工具面已由 Agent 工具笔记承接 |
| Skill 沙箱 | `主链确认` | Rust skill_manager.rs 路径锁定/超时/多运行时探测；渐进式披露 |
| 请求检查器 | `主链确认` | llm-inspector 双层监控，内部钩子注入 fetchWithTimeout |
| VCP 监控 | `入口确认` | vcp-connector observer 六类事件监控面板；节点/桥接已由 Agent 工具笔记承接 |

## 已确认的独特能力

### 能力一：媒体工作站（media-generator）— `主链确认`

**用户目标**：把"图片/视频/音频/3D 多模态生成"从聊天里的单次工具调用升级为可管理、可分支、可重试、可追踪的独立工作台；生成历史、任务队列、参数和资产同处一个事实源。

**入口与触发者**：用户入口为主——工具首页 `/media-generator`（`media-generator.registry.ts` 的 `toolConfig`），输入框"生成"提交走 `mediaGenStore.submitTaskInSession`；另一条是 Agent 侧：registry 通过 `buildAgentMethods.ts` 为每个可用模型动态生成 `generate_<model_id>` 方法（`agentCallable: true`），模型可触发生成。

**事实对象**：三个对象——`GenerationSession`（树形 `MediaMessage` 节点，独立于 llm-chat 会话体系）、`MediaTask`（跨会话全局任务池，`pending → processing → completed | error | cancelled`）、结果 `Asset`（回流资产管理器）。桥接字段是节点 `metadata.taskSnapshot`（重试时恢复参数）。

**完整主链**：输入提示词 → `buildTask`（打包参数、按模型能力决定是否带上下文）→ `addTask` 进全局任务池 → `addTaskNode` 在会话树建 User/Assistant 节点 → `executeGeneration`（AbortController 可中断；参考图 Asset→Base64；`sanitizeParams` 按模型 `mediaGenParams` 规则剔除不支持参数、校验取值；`applyContextRules` 决定多轮上下文）→ `useLlmRequest.sendRequest` → 响应 `handleResponseAssets`（解码 b64/拉取 URL → `embedMetadata` 把生成参数内嵌进文件元数据 → `importAssetFromBytes` 入资产库 → 衍生数据写 `derived/media-generator/{date}/{assetId}.json`）→ 任务标 completed 并关联 `resultAssets`。

**持续性**：`{appDataDir}/media-generator/` 下 `sessions-index.json` + `sessions/{id}.json` + `tasks.json` + `settings.json`；`syncIndex()` 启动自愈（补齐/移除索引项），崩溃遗留的 `generating` 节点自动标 `error`，`activeLeafId` 修复到最深叶子。

**主动性与取消**：无后台主动执行；`abortTask(taskId)`/`abortAll()` 中止生成，任务完成后保留在池中供 UI 查看（可配 `autoCleanCompleted` 自动清理）。

**外部依赖与执行域**：生成请求走用户配置的 LLM Profile（远程 API）；参考图与结果资产在本机资产库；无独立后端进程，执行逻辑在前端 + 远程 API。

**安全与资源边界**：`sanitizeParams` 防非法参数；无内容过滤（`prompt` 完全由 LLM 控制）；生成消耗真实 API 额度。`generateMedia` Agent 方法为占位未实现（`ARCHITECTURE.md:410`），Agent 触发生成实际依赖 `buildAgentMethods` 的动态方法族。

**独特性判断**：llm-chat 的多模态输出只是"附件/转写"；media-generator 提供会话-任务双轨、参数清洁规则、内嵌元数据和资产回流，是 `创作工作站` 标签的完整实例。

**证据强度**：ARCHITECTURE.md 全文（730 行）+ registry 源码为静态事实；未运行应用验证 UI 与真实模型调用。

### 能力二：中央资产管理器（asset-manager）— `主链确认`

**用户目标**：所有工具产生的图片、文档、转写结果汇入一个按哈希去重、可分组筛选、带来源追踪的应用级资源中心，避免同一文件多次落盘。

**入口与触发者**：用户入口为工具页 `/asset-manager`（`AssetManager.vue` + `useAssetManager`）；实际主入口是**工具侧写入**——llm-chat 附件、media-generator 结果、sketch-pad 导出、OCR/转写结果都调用全局单例 `assetManagerEngine.importAssetFromBytes/Path`（`useAssetManager.ts:113` 等）。

**事实对象**：`Asset`（path、sha256、origins[]、thumbnail、derived 元数据等），索引存 `$APPDATA/assets/assets.jsonl`，文件按月分目录。

**完整主链**（以 media-generator 回流为例）：生成响应字节 → `import_asset_from_bytes`（`src-tauri/src/commands/asset_manager.rs:870`）→ 计算 SHA-256 → `check_duplicate_in_current_month` 查重：命中则给既有资产追加 `origin`（`asset-imported` 事件）直接返回；未命中则写文件、提取图片宽高、生成缩略图/音频封面、写 `assets.jsonl` → 前端无限滚动分页查询（`list_assets_paginated` Rust 命令）。

**持续性**：`assets.jsonl` 中央索引 + 物理文件；`rebuild_hash_index` 可重建哈希索引；重启后按索引恢复。

**安全与资源边界**：`enable_deduplication` 开关控制去重；`remove_asset_source` 在最后一个来源移除时删除文件；Tauri capability 对 fs 读取无路径限制（Agent 工具笔记第 7 节已记录）。

**独特性判断**：多数项目把文件挂在会话/知识库下；AIO Hub 用应用级资产层统一所有工具的产物并带来源生命周期，是 `创作工作站` 与"媒体/资产"聚类的关键支撑。

**证据强度**：Rust 命令源码 + 前端单例 + ARCHITECTURE 为静态事实；10 万+资产性能上限（ARCHITECTURE 自述）未实测。

### 能力三：LLM 请求检查器（llm-inspector）— `主链确认`

**用户目标**：对"发给模型的每个请求"做本地中间人级观察——既能拦截外部 LLM 客户端的流量，也能透视应用内自己发的请求，替代仅凭日志猜请求体。

**入口与触发者**：工具页 `/llm-inspector`（`LlmInspector.vue`）；用户开关 `monitorInternal`/`monitorExternal`。内部钩子默认 OFF（`shouldCaptureInternal()` 总开关），是**被动观测**，不主动干预请求。

**完整主链**（内部钩子路径）：`useLlmRequest.sendRequest` 在调用 adapter 前 `setContext(requestId, inspectorContext)`（工具名/会话 ID/用途）→ `fetchWithTimeout`（`src/llm-apis/common.ts:697`）三个分支埋点 `triggerRequest/triggerResponse/triggerStream` → `hookRegistry` 按 `X-Request-ID` 反查上下文 → 本地回调 + Tauri `emit` 跨窗口广播（LRU 去重）→ `inspectorRecordsStore` 记录 `CombinedRecord`（source: internal/external）→ 详情面板 3 Tab（总览/请求/响应），流式 SSE 走 `inspectorStreamStore` 100ms 节流 + 多格式智能提取（OpenAI/Anthropic/Gemini/Cohere/Ollama 五类）。外部代理路径：Rust axum 代理（默认端口 8999）拦截外部客户端 → 转发上游 → `inspector-*` 事件回流。跨窗口启用状态经 `INSPECTOR_SYNC_EVENT` 三事件协议同步（`types/hooks.ts:172`）。

**持续性**：记录在内存 store；配置（端口、header 覆盖规则、布局比例、Token 估算开关）持久化 `appConfigDir/llm-inspector/settings.json`（createConfigManager 500ms 防抖）。记录本身不落盘。

**安全边界**：API Key 脱敏复制；header 覆盖规则可改上游请求；代理监听本机端口。

**独特性判断**：这是"自观察 LLM 流量的开发者表面"——应用内埋点 + 外部代理双通道，现有类目无对应项。

**证据强度**：ARCHITECTURE 全文 + 埋点源码为静态事实；代理真实转发与 SSE 解析未运行验证。

### 能力四：快捷动作系统（Quick Actions）— `主链确认`

**用户目标**：输入栏的指令增强——把"模板文本 + 宏 + 行级后处理"组合成可点击按钮，一键生成内容并可自动发送；支持导入 SillyTavern Quick Reply 生态资产。

**入口与触发者**：输入栏快捷操作按钮（`QuickActionSelector.vue`）→ `messageInputStore.handleQuickAction(action)`（`messageInputStore.ts:328`）。用户手动点击触发。

**事实对象**：`QuickActionSet`（组）+ `QuickAction`（label/content/autoSend/hotkey/lineProcessing），索引 `quick-actions-index.json`，组文件存 `{appConfigDir}/llm-chat/quick-actions/`（`useQuickActionStorage.ts:40-57`）。

**完整主链**：点击 → 取 textarea 选区（无选区取全文）作为 `{{input}}` → `createMacroContext`（用户名/角色名/会话树/Agent/用户档案）→ `MacroProcessor.process` 执行模板（silent 模式）→ `lineProcessing` 逐行加前缀/后缀或正则替换（`new RegExp(pattern, flags)`，失败降级保留原文）→ 写回编辑器（选区替换或整体覆盖）→ `autoSend` 为真则 50ms 后 `handleSend()`，否则聚焦输入框。导入链：`quickActionImportService.ts` 解析 SillyTavern `qrList` 格式转成 QuickActionSet。

**主动性与取消**：无后台行为；执行是同步改写输入框，可编辑后发送。

**独特性判断**：普通聊天输入框只有发送/重试；快捷动作把"宏模板 + 正则后处理 + 自动发送"做成了用户可管理的产品表面，并与 ST 生态互操作。

**证据强度**：store/composable/组件三处源码为静态事实；UI 行为未运行验证。

### 能力五：宏系统（72 个内建宏，三阶段管道）— `主链确认`

**用户目标**：让 Prompt 文本可编程——时间日期、系统环境、随机/掷骰、角色信息、变量读写、知识库、工具定义等都以 `{{name}}` 形式在发送前展开，属于"上下文 DSL"聚类（待查清单第 8 行）。

**事实对象**：`MacroDefinition`（name/type/phase/handler/example），注册在 `MacroRegistry`（reactive Map）。

**完整主链**：`MacroProcessor.process`（`macro-engine/MacroProcessor.ts:84`）按三阶段执行——`PRE_PROCESS`（如变量初始化）→ `SUBSTITUTE`（主体替换）→ `POST_PROCESS`（如时间格式化输出），每阶段 `getMacrosByPhase` 批量处理，未注册宏记 warning。内建宏实测 72 个：datetime 25、core 19、variables 8、functions 7、system 6、tools 3、knowledge 2、assets/cssVariables 各 1（`macro-engine/macros/*.ts` 逐文件统计）。全局/局部变量支持 `setvar/getvar/incvar/decvar` 与 `setglobalvar/getglobalvar` 族（会话变量快照语义在对话请求与上下文笔记 9.4）。

**持续性**：宏定义为代码内建；变量值随消息快照/会话 JSON 持久化（见会话管理笔记 1.3）。

**独特性判断**：README"60+"宣称实测为 72 个；三阶段管道 + 变量系统的组合在样本中接近 SillyTavern/VCP 的宏面，但以 Vue 应用内建实现。与对话请求与上下文笔记的重叠点是宏在上下文管道中的注入位置，本笔记只记宏引擎本身。

**证据强度**：逐文件正则统计宏名（72 个）+ 管道代码为静态事实；未运行宏展开验证。

### 能力六：自由窗口管理（分离窗口系统）— `主链确认`

**用户目标**：把任意工具页甚至聊天输入框从主窗口拖出来成为独立无边框窗口，跨窗口共享同一状态源，位置大小自动记忆——多表面连续性的桌面实现。

**入口与触发者**：工具卡片/标签页的分离菜单 → `useDetachedManager.createToolWindow`（Tauri `create_tool_window`）；组件级分离走 `useDetachable`（rdev 拖拽会话，全局快捷键/平台监听）。

**完整主链**：分离请求 → 新建 Tauri 窗口（URL 带工具 ID，`/detached-window/...` 或 `/detached-component/...`）→ `DetachedWindowContainer.vue`/`DetachedComponentContainer.vue` 按 ID 加载工具组件 → 跨窗口状态经 `logicHook`（返回 `props: Ref` + `listeners`）与主窗口共享同一 store/状态（`docs/guide/detached-window-system.md`）→ 窗口位置/大小经窗口配置系统持久化；`useDetachedManager` 每 30 秒 `ensureWindowVisible` 检查防止窗口移出屏幕（`useDetachedManager.ts:194-208`，受 `autoAdjustWindowPosition` 设置控制）。聊天/媒体生成输入框的状态同步走 `useWindowSyncBus` + `useStateSyncEngine`（增量 patch 与全量两种模式，`VersionGenerator` 防旧覆盖新）。

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

### 归并说明：上下文分析器与正则管道

- **上下文分析器**：对话请求与上下文笔记 9.8 已确认（复用真实管道预览、五视图界面在 Chat UI 6.3），标 `归并已有类目`，不重复计数。
- **正则处理管道**：管道内 `regex-processor`（`core/context-processors/regex-processor.ts:100`，priority 200）按角色与深度过滤规则，Global/Agent/User 三层配置合并（`resolveRawRules`），发送前清洗（如隐藏思维链）；渲染前转换（"自定义标签渲染"）在消息渲染器笔记的格式阶段。该能力是"上下文 DSL"聚类成员，与宏系统同族，但注入点与数据模型（`ChatRegexRule`）已由上下文类目完整解释，本次仅补三层合并细节，标 `归并已有类目` + 宏系统独立计数。

## 已归并到现有类目的能力

| 能力 | 归并去向 |
|---|---|
| 上下文分析器 | [`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md) 9.8 |
| 上下文压缩 | 同上附录 A |
| 会话变量/快照 | 同上 9.4 + 会话与消息管理笔记 1.3 |
| 世界书、知识库、转写注入 | 同上 9.2/9.6 |
| 工具调用基础设施（含插件注册为 ToolRegistry、VCP 协议、异步任务） | [`../Agent工具/AIO-Hub-Agent工具调查笔记.md`](../Agent工具/AIO-Hub-Agent工具调查笔记.md) |
| Skill 工具执行细节（路径锁定/超时） | 同上第 4/7/9 节 |
| VCP 分布式节点与工具桥 | 同上第 7/9 节 |
| 富文本渲染引擎（AST/Patch、交互按钮、VCP 可视化） | [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)、生成式输出与运行时笔记 |
| 对话树图、撤销重做、分支语义 | 会话与消息管理笔记 |
| 自由窗口在聊天气泡/输入框的具体同步 | Chat UI 笔记 8.2 |

## 声明不符、外部依赖与暂缓项

- **media-generator `generateMedia` Agent 方法**：`media-generator/ARCHITECTURE.md:410` 明确声明该方法"在 `getMetadata()` 中有声明但尚未实现"，是前服务系统占位；Agent 触发生成实际走 `buildAgentMethods` 动态方法族。README 未单独宣称该方法，属文档内自述的占位，标 `声明不符`（文档对代码）。
- **插件目录是独立仓库**：`plugins/` 已被主仓库 `.gitignore`（`plugins/README.md`），示例插件托管在独立 GitHub 仓库；运行时从 `%APPDATA%/com.aio-hub.app/plugins/` 加载。多运行时插件的完整安装/分发链路本次未验证，标 `暂缓`。
- **移动端**（`mobile/`）为独立 Tauri 应用且私有许可证，本轮未调查，标 `暂缓`。
- **media-info-reader 的 A1111/ComfyUI/ST 角色卡元数据提取**：README 列出但不在待查清单，属工具清单成员，本轮未走主链，不计数。

## 对特色贡献统计的影响

按调查指南"只有 `主链确认` 才能作为主贡献/辅助贡献进入特色统计"：

- 主贡献候选（能力族，不拆小工具）：媒体工作站、资产管理器、LLM 请求检查器、快捷动作、宏系统、自由窗口、Agent 私有资产、Skill 沙箱——8 个能力族达到 `主链确认`（静态证据）。
- 辅助贡献：VCP 监控面板（`入口确认`）、多运行时插件（`入口确认`）。
- 同一工作流合并计数：宏系统与正则管道同属"上下文 DSL"聚类，但正则管道已归并上下文类目，仅宏系统独立计数；快捷动作依赖宏引擎但不并入宏系统（用户目标不同：模板按钮 vs 语言能力）。
- 工程机制单独标注：资产管理器的 Rust 索引、llm-inspector 的流式节流属于机制贡献，不与用户可见能力混计。

## 未验证事项

- 全部能力均未运行验证：Tauri 分离窗口的视觉/拖拽行为、媒体生成真实 API 调用与内嵌元数据、llm-inspector 代理转发与 SSE 解析、快捷动作自动发送时序、宏展开的运行时输出、Skill 脚本多运行时探测（Windows 下 bash/sh 断层见 Agent 工具笔记）。
- 资产管理器 10 万+ 资产索引性能上限未实测；`rebuild_hash_index` 未运行。
- VCP 监控六类事件的真实渲染、断线重连、双 WebSocket 状态机未运行验证。
- 宏数量统计基于静态正则（`name: "..."` 匹配），可能存在个别未注册或条件注册的宏未计入；72 个是当前快照的注册面统计。

## 关键源码索引

- `src/tools/media-generator/media-generator.registry.ts`（toolConfig 与动态 Agent 方法注册）、`ARCHITECTURE.md`、`stores/mediaGenStore.ts`
- `src/composables/useAssetManager.ts`（全局单例）、`src-tauri/src/commands/asset_manager.rs:870`（import_asset_from_bytes 去重链）
- `src/tools/llm-inspector/ARCHITECTURE.md`、`core/hookRegistry.ts`、`src/llm-apis/common.ts:697`（fetchWithTimeout 埋点）
- `src/tools/llm-chat/stores/messageInputStore.ts:328`（handleQuickAction）、`services/quickActionImportService.ts`、`composables/storage/useQuickActionStorage.ts:40`
- `src/tools/llm-chat/macro-engine/MacroProcessor.ts:84`（三阶段）、`MacroRegistry.ts`、`macros/*.ts`（72 宏）
- `src/tools/llm-chat/core/context-processors/regex-processor.ts:100`（三层合并 + 角色/深度过滤）
- `src/composables/useDetachable.ts`、`useDetachedManager.ts`、`src/views/DetachedWindowContainer.vue`、`docs/guide/detached-window-system.md`
- `src/tools/agent-manager/utils/agentAssetUtils.ts`、`components/assets/AgentAssetsManager.vue`、`src/tools/llm-chat/macro-engine/macros/assets.ts`
- `src/tools/skill-manager/ARCHITECTURE.md`、`services/SkillManagerProxy.ts`、`src-tauri/src/commands/skill_manager.rs`
- `src/tools/vcp-connector/ARCHITECTURE.md`、`stores/vcpConnectorStore.ts`
- `src/services/auto-register.ts:62`（registry 扫描）、`src/stores/tools.ts`（工具页面注册）
