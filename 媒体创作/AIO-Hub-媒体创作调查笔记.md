# AIO Hub 媒体创作调查笔记

> 调查对象：`E:\works\GitStudyNotes\aio-hub`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：只读通读 media-generator 的 ARCHITECTURE.md、registry、store、生成/任务/持久化 composable 与 buildAgentMethods，asset-manager 的 ARCHITECTURE 与 Rust `asset_manager.rs` 关键命令，llm-apis 适配器族与测试；用 `node -e` 解析 package.json/tauri.conf.json/capabilities，`node --check` 抽查两个纯 JS 文件；未运行 Tauri 应用，未修改被调查仓库
>
> 调查范围：媒体创作类目视角的主链、任务/资产生命周期、会话/任务双轨、资产去重索引、Agent 触发与回流；复用独特功能与 Agent 工具笔记的既有证据，不重复抄写完整源码调查
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 是本次类目三种正式样本中唯一**应用级桌面媒体工作站**（分型 M1 + M3，Agent 面 M5）。media-generator 与 asset-manager 两模块形成一条完整闭环：媒体生成会话（`GenerationSession` 树）与全局任务池（`MediaTask`）解耦为双轨，结果资产经 SHA-256 去重汇入应用级中央资产库（`Asset`），之后可预览、重试、分支、导出、发送到聊天或作为下一轮参考图再次使用。

- **会话-任务双轨**：会话树只存交互历史与参数快照（`taskSnapshot`），任务池单独管理执行状态；桥接约定是 `assistantNode.id === task.id`（`src/tools/media-generator/stores/mediaGenStore.ts:203` 提交链、`src/tools/media-generator/composables/useTaskActionManager.ts:136`）。
- **结果资产化**：每次生成把解码/下载的字节先 `embedMetadata` 内嵌生成参数，再 `importAssetFromBytes` 入资产库，衍生数据另写 `derived/media-generator/{date}/{assetId}.json`（`useMediaGenerationManager.ts:712` handleResponseAssets）。
- **去重索引**：Rust 侧当月目录 SHA-256 去重（`check_duplicate_in_current_month`，`src-tauri/src/commands/asset_manager.rs:1265`），命中则给既有资产追加 `origin` 并回发 `asset-imported` 事件；未命中才落盘并写月度 `.index.json` 与内存 Catalog。
- **Agent 共用入口**：`getMetadata()` 按当前启用 Profile/模型与可见性配置动态生成 `generate_<model_id>` 方法族，`isFast` 模型同步返回、其余走 tool-calling 异步任务框架（`buildAgentMethods.ts:754`）；注册表另有 `addContentToInput/setInputContent/addAssets` 三个非 agentCallable 的编程接口。

与独特功能笔记[能力一、二](../独特功能/AIO-Hub-独特功能调查笔记.md)证据一致；本笔记是类目专页，只交接媒体创作维度，不再重复完整源码调查。全部结论基于静态源码；真实模型生成、UI 渲染与资产索引性能均未运行验证。

## 系统边界与完整主链

边界：media-generator（工作台）+ asset-manager（资产层）为主贡献；llm-chat 的多模态附件、transcription、danmaku-player、ffmpeg-tools 属于相邻边界，不入本主链。执行域是「Tauri 前端渲染进程 + 用户配置的远程 LLM Profile」，无本地生成器、无独立后端进程；生成链路内不依赖 FFmpeg/ComfyUI/浏览器渲染服务。

主链（用户会话模式）：

```text
MediaGenerationInput.handleSend（Ctrl+Enter，MediaGenerationInput.vue:411）
  -> store.submitTaskInSession（mediaGenStore.ts:203）
     -> useMediaGenerationManager.buildTask（纯函数打包参数，useMediaGenerationManager.ts:649）
     -> useMediaTaskManager.addTask 入全局任务池（useMediaTaskManager.ts:108）
     -> useTaskActionManager.addTaskNode 建 User/Assistant 节点（assistant.id=task.id + taskSnapshot，useTaskActionManager.ts:83）
     -> 可选自动命名（mediaGenStore.ts:226）
  -> executeGeneration（useMediaGenerationManager.ts:381）
     -> AbortController；参考资产 Asset -> Base64（按 maxImageDimension 缩放）
     -> sanitizeParams 按模型 mediaGenParams 规则清洁（useMediaGenParamRules.ts:147）
     -> applyContextRules 裁剪多轮上下文（useMediaGenerationManager.ts:350）
     -> useLlmRequest.sendRequest（inspectorContext + signal；openai-responses 走 onPartialImage 流式预览）
  -> handleResponseAssets（useMediaGenerationManager.ts:712）
     -> 解码 b64 / Data URL / tauriFetch 拉取 URL（代理回退）
     -> 可选 writeStandardMediaMetadata（音频）+ embedMetadata 内嵌参数
     -> importAssetFromBytes（Rust asset_manager.rs:870：SHA-256 当月去重 -> 落盘/追加 origin -> asset-imported 事件）
     -> persistDerivedData 写衍生数据 + update_asset_derived_data
  -> 任务标 completed，resultAssets/resultAssetIds 关联（useMediaGenerationManager.ts:892-899）
```

快速模式（`workbenchMode === "quick"`）跳过会话树：`handleSendQuick` 直接 buildTask -> addTask -> executeGeneration（`MediaWorkbench.vue:57`），任务仍进全局池、结果仍入资产库。Agent 路径从 `buildTask` 之后的同一执行链进入（`buildAgentMethods.ts:640` createHandler）。

## 1. 创作入口、触发者与事实对象

**入口**：工具页 `/media-generator`（`media-generator.registry.ts:44` toolConfig），四 Tab：工作台/画廊/任务列表/生成设置（`views/MediaGeneratorView.vue:41`）；工作台内「创作会话 / 快速生成」双模式（`MediaWorkbench.vue:52` workbenchMode 持久化于 localStorage）。右侧 `AssetGallery` 直接引用全局资产库。

**触发者**（必查问题 2）：用户手动为主；Agent 为次——`getMetadata()` 每次被调用时对可见模型生成 `generate_<sanitized_model_id>` 方法并绑定 handler（`media-generator.registry.ts:217`）；可见性受 `settings.agentConfig` 黑/白名单、`profilePriority`、`fastModelIds` 控制（`collectVisibleModels`，registry.ts:150）。**本次未找到**定时任务、外部服务或工作流触发媒体生成的入口；工作台无后台常驻执行。

**事实对象**（必查问题 3）三个，真源不同：

| 对象 | 定义 | 真源 |
|---|---|---|
| `GenerationSession` | 会话索引项 + 详情（`types.ts:338`），详情含 `nodes` 节点池、`rootNodeId`、`activeLeafId`、`generationConfig` | `sessions/{id}.json` |
| `MediaMessage` | 树节点（`types.ts:65`），metadata 携带 `taskId/isMediaTask/includeContext/taskSnapshot/translatedContent` | 随会话详情 |
| `MediaTask` | 全局任务（`types.ts:88`），五态 `pending/processing/completed/error/cancelled`，`input.params` 参数快照、`resultAssetIds/resultAssets` | `tasks.json` |
| `Asset` | 资产层对象（path/sha256/origins[]/metadata.derived） | `$APPDATA/assets/` + `assets.jsonl` |

桥接字段是 Assistant 节点上的 `metadata.taskSnapshot`（重试恢复用）与 `assistantNode.id === task.id`。资产本身不由 media-generator 拥有，而是中央资产库的共享对象（跨工具复用面，见第 4 节）。

## 2. 参数、素材与模型/渲染执行

**参数**（必查问题 5）：每媒体类型一套 `MediaTypeConfig.params`（`types.ts:156`：size/quality/style/negativePrompt/seed/steps/cfgScale/background/inputFidelity/partialImages/duration、Suno 的 suno_mode/mv/tags/title/make_instrumental、TTS 的 audioConfig/instructions 等），持久化在 `generation-config.json`（全局配置，`useMediaStorage.ts:99`）。请求前经 `sanitizeParams` 按模型 `mediaGenParams` 规则剔除不支持参数、clamp 数值、校验枚举、填充默认值；xAI/Gemini 类模型走 `aspectRatioMode`（`buildXaiSizeParams`）或专用 adapter。UI 参数别名映射（steps→numInferenceSteps、cfgScale→guidanceScale、duration→durationSeconds）在 `useMediaGenerationManager.ts:524-547`。

**素材**：按媒体类型过滤参考图/参考音频/参考视频（`MediaGenerationInput.vue:215` referenceAttachmentConfig），拖放、粘贴、文件选择都先 `importAssetFromPath` 入资产库再作为附件（`MediaGenerationInput.vue:324-404`）。执行时 Asset 转 Base64（`getAssetBinary` → `convertArrayBufferToBase64`），超过模型 `maxImageDimension` 先缩放（`useMediaGenerationManager.ts:453-488`）。多轮上下文：`includeContext` 开关 + `contextMessageIds` 手动指定；单轮模型自动带入上一条 Assistant 结果的图片作为参考（`collectSingleTurnReferenceAssets`，:156）；不支持多轮上下文的端点显式降级为单轮（:433 日志）。

**执行位置**（必查问题 4）：请求由 `useLlmRequest.sendRequest` 发往用户配置的 LLM Profile 的远程 API；适配器族按 profile 类型分发（openai image/video/audio、gemini image/chat、suno-newapi、minimax-music、siliconflow、cohere 等，`src/llm-apis/adapters/*`），统一产出 `LlmResponse.images/videos/audios`（`src/llm-apis/common.ts:572`）。视频/音乐存在轮询式异步 API（如 Ark/Agnes 视频、Suno、MiniMax Music），由各 adapter 封装。本地无渲染/编码器，纯前端 + 远程模型（源码事实）。

## 3. 任务状态、异步回调与取消

- **状态机**：`pending → processing → completed | error | cancelled`（`types.ts:59`）；`progress`/`statusText` 随阶段更新（准备附件→生成中 30→入库 90→完成 100，`useMediaGenerationManager.ts:596-621`）。
- **流式预览**：openai-responses 端点通过 `onPartialImage` 回调把中间预览图写入任务 `previewUrls`（:581-594）。
- **取消**：每个任务独立 `AbortController`（Map 管理，:74），`abortTask(taskId)`/`abortAll()`（:312-338）；`AbortError` 收敛为 `error` 状态、`error:"已中止"`（:623）。UI 取消入口：任务卡/任务列表 `handleCancelTask`（`MediaTaskList.vue:150`）、快速模式「停止全部」（`MediaWorkbench.vue:95`）。任务结束后保留在池中，由「清理已完成」按钮手动清理（`MediaWorkbench.vue:81`）；`autoCleanCompleted` 设置项**本次未找到执行消费者**（仅 settings/UI/文档出现，静态推断为未启用功能）。
- **超时与重试**：默认 `DEFAULT_MEDIA_TIMEOUT = 600000ms`（`src/llm-apis/common.ts:32`），settings 可配 `requestSettings.timeout/maxRetries`（默认 0，`config.ts:284`）；maxRetries 只传给请求层，默认不自动重试。`maxConcurrentTasks`（默认 3，`config.ts:231`）**本次未找到并发闸门实现**，仅设置项存在（静态推断：实际并发取决于 UI 的 isGenerating 全局锁与用户操作节奏，非任务池级限流）。
- **Agent 侧异步**：非 `isFast` 模型的方法 `executionMode: "async"` + `asyncConfig {hasProgress:true, cancellable:true, estimatedDuration:30}`（`buildAgentMethods.ts:781`），经 tool-calling 通用异步任务框架执行（提交即返回 taskId，重启后 running/pending 标 `interrupted` 且不自动恢复——Agent 工具笔记第 11 节）；handler 内用 `context.signal` 监听取消并转发 `abortTask`，用 `reportStatus` 回传任务进度（`buildAgentMethods.ts:699-712`）。`isFast` 模型走同步方法，超时走 executor 的 `withTimeout`（30s 默认）。

## 4. 结果、历史、资产与工程持久化

- **会话历史**（必查问题 6/8）：`{appConfigDir}/media-generator/` 下 `sessions-index.json`（轻量索引 + 当前会话 ID）、`sessions/{id}.json`（树详情）、`tasks.json`（全局任务池）、`settings.json`（用户设置）、`generation-config.json`（全局生成配置）。双层防抖：store 层 1s（`useMediaGenPersistence.ts:291`）+ storage 层 2s（`useMediaStorage.ts:458`）。索引自愈 `syncIndex`：扫描物理目录补齐/剔除索引项（`useMediaStorage.ts:296`）。
- **启动自愈**：`generating` 遗留节点按关联任务完成情况修 `complete`/`error`（元数据注明"应用重启，生成中断"，`useMediaGenPersistence.ts:178-192`）；`activeLeafId` 修复到最深叶子；无根节点自动创建。运行时另有"僵死节点" watch：任务结束而节点仍 generating 时自动修复（`mediaGenStore.ts:334-360`）。
- **资产持久化**（必查问题 8）：`$APPDATA/assets/` 按 类型/月份 分目录；Rust `AssetCatalog` 内存 Catalog（RwLock）+ `assets.jsonl` 中央索引（mark_dirty 落盘）；每目录 `.index.json` 月度哈希索引。`import_asset_from_bytes`（`asset_manager.rs:870`）：SHA-256 → `check_duplicate_in_current_month`（:1265，仅当月+同类型）→ 命中：若 sourceModule 不同则追加 `origin` 并 emit `asset-imported` 直接返回既有资产；未命中：写文件、提取图片宽高、生成缩略图/音频封面、写月度索引、入 Catalog。`rebuild_hash_index`（:1720）可全量重建哈希索引。图片宽高、`audio_waveform`（前端 Web Audio 采样后 `update_audio_waveform`，:2767）、`derived` 元数据都挂在 `AssetMetadata`。
- **来源生命周期**：`origins[]` 记录 (originType/source/sourceModule)；`remove_asset_source`（:2476）在最后一个来源被移除时删除物理文件；`add_asset_source` 追加来源。生成结果标记 `origin.type="generated"`、`source=revisedPrompt||taskId`、`sourceModule="media-generator"`。
- **衍生数据**：每次入库同时写 `derived/media-generator/{date}/{assetId}.json` 并 `update_asset_derived_data` 挂到 `metadata.derived["generation"]`（`useMediaGenerationManager.ts:912`）；asset-manager 侧边操作「查看生成参数」优先读 derived、缺失时 `get_asset_binary` + `extractMetadata` 从文件内嵌元数据提取（`media-generator.registry.ts:301-358`）。音频还支持标准媒体标签写入（ID3/WAV INFO，含用户档案作者、prompt 注释，`useMediaGenerationManager.ts:1011` buildStandardAudioMetadata，默认关闭 `metadataWrite.enabled=false`）。
- **删除**：`removeTask` 先清任务池再级联删除会话节点（`mediaGenStore.ts:294`）；删除会话走 `deleteSession`。资产删除在 asset-manager UI/Rust 侧（`remove_asset_completely`）。

## 5. 预览、编辑、重试、分支与复用

- **预览**（必查问题 6）：`openTaskResult` 按类型分发到 image/video/audio 全局查看器（`mediaGenStore.ts:170`）；`autoOpenAsset` 可选生成后自动打开；任务卡内联：视频海报 + 悬停播放（`MediaTaskCard.vue:325`）、音频波形懒采样并回写任务/节点（:200-222）、`getAssetUrl` 统一解析；画廊 Tab 与右侧 AssetGallery 展示历史资产。
- **重试**：`regenerateFromNode`（`mediaGenStore.ts:489`）→ `getRetryParams` 从 `taskSnapshot` 恢复参数（`useTaskActionManager.ts:152`，复用当前类型配置参数并强制 `seed=-1`）→ `createRegenerateBranch` 在源 User 节点下建兄弟 Assistant 节点 → 复用参数建新任务（`task.id = assistantNode.id`）→ `startGenerationWithTask` 直接执行。重试期间同一源节点加锁防重复（`retryingSourceMessageIds`）。
- **分支**：`createRegenerateBranch`（重试语义）、`createBranch`（纯复制语义，`useBranchManager`）、`switchToBranch`（`findDeepestLeaf` 后切换）、`saveToBranch`（复制后改内容）；节点删除为级联硬删除。会话模式用树路径 `getNodePath` 渲染活跃路径（`store.messages`）。
- **编辑**：`editMessage`、`updateNodeData`（禁止改 id/parentId/childrenIds，`mediaGenStore.ts:680`）、`MessageDataEditor` 直接编辑节点 JSON；批量模式可选中多条消息后删除（批量下载为 TODO 占位，`MediaWorkbench.vue:160-163`）。
- **导出**：`exportBranchAsMarkdown` 把分支路径导出为 Markdown（含参数快照 JSON 与资产信息，`useMediaExportManager.ts:38`）；任务卡支持复制提示词、打开文件所在目录（`MediaTaskCard.vue:340` openFileDirectory）。
- **复用/回流**：结果资产进入中央资产库后可供其他工具引用；AssetGallery 可把资产作为下一轮参考素材；asset-manager 操作菜单「发送到聊天」把资产注入 llm-chat（跨工具回流，见 Agent 工具/独特功能笔记）；Agent 调用结果以 `appdata://` 路径返回，由渲染层/宏机制解析成可显示图片（Agent 工具笔记第 8 节）。

## 6. Agent 回流、插件与外部依赖

- **发现**（必查问题 9）：动态方法族 `generate_<model_id>`，方法参数声明由模型 `mediaGenParams` 规则生成（`buildParameters`，`buildAgentMethods.ts:259`），描述含模型/渠道/快速模式/额外说明（`buildDescription`）。同一 modelId 多渠道时按 `profilePriority` 路由（`registry.ts:189` resolveProfileRoute）。配置变更（agentConfig/Profile 列表）通过 watch 失效工具发现缓存（`registry.ts:87` setupDiscoveryInvalidation）。
- **调用与返回**：handler 校验 prompt 必填、媒体类型支持、非 fast 模型必须异步执行（`buildAgentMethods.ts:651-665`）；成功返回 `{success, taskId, type, prompt, assets: [appdata://…], assetIds}`，失败返回 `{success:false, error}`（`buildResult`，:605-638）。
- **编程接口**：`addContentToInput/setInputContent/addAssets` 是注册表的公开方法但**不在 `getMetadata()` 中**（非 agentCallable），供其他模块写输入框/附件（`registry.ts:231-295`）。`getAssetSidecarActions` 让资产右键菜单挂"查看生成参数"。
- **审批与异步**：Agent 媒体生成走通用 tool-calling 审批/执行链（executor 二次校验 agentCallable、审批状态机、异步任务框架），细节见 Agent 工具笔记第 5/6/11 节，本笔记不重复。
- **外部依赖**（必查问题 10）：生成请求依赖用户 LLM Profile（远程 API/Key）；远程媒体下载走 Tauri HTTP 插件（`tauriFetch`，30s connectTimeout），失败回退 `fetchWithTimeout(forceProxy, relaxIdCerts)` 本地代理（`useMediaGenerationManager.ts:1123` fetchAsArrayBuffer）；本地文件走 `convertFileSrc`。**本次未找到**媒体插件族/manifest 协议（通用插件系统是 JS/Sidecar/Native，不承载媒体生成扩展点）；无 FFmpeg/ComfyUI/浏览器服务依赖（生成链内）。

## 7. 权限、资源边界与失败恢复

- **参数边界**：`sanitizeParams` 是模型参数的最后一道闸（剔除/钳制/枚举校验），但 `prompt` 不做任何内容过滤，完全由 LLM/用户控制（源码事实，与 Agent 工具笔记一致）。
- **素材边界**：参考素材按媒体类型过滤扩展名（`MediaGenerationInput.vue:215`）；图片按 `maxImageDimension` 缩放；MiniMax 翻唱限制单参考音频并校验两步工作流前置条件（`useMediaGenerationManager.ts:1091` validateMiniMaxTwoStepCover、`useMiniMaxCoverWorkflow.ts:128` ensureTwoStepReady，预处理结果 24h 过期）。
- **资源限额**（必查问题 11）：超时/重试可配；**本次未找到**任务数、文件大小、磁盘配额或并发数的执行级限额（`maxConcurrentTasks`/`autoCleanCompleted` 均无执行消费者）；资产库 10 万+ 性能上限仅为 ARCHITECTURE 自述（`asset-manager/ARCHITECTURE.md:76`），未实测。
- **失败恢复**：请求异常 → 任务 `error` + statusText（:630）；AbortError 单独处理为"已中止"；单条资产入库失败只记日志不中断其余资产（:887-889），全部失败则整体报错（:904）；`embedMetadata`/标准元数据写入失败降级继续入库（:844-851、:826-841）；远程下载 tauriFetch 失败自动走代理回退（:1155-1170）。崩溃/重启：generating 节点修复为 error，任务池保持最后状态但**不自动恢复执行**（静态推断：`taskManager.init` 只有加载，无重新入队路径）。

## 8. 设计取舍、已确认边界与未验证事项

**取舍**：

- 会话与任务解耦但以 ID 强耦合：`assistantNode.id === task.id`，重试时重建分支并复用节点 ID——简化了历史与执行的同步，代价是任务池删除必须级联节点删除（`removeTask` 语义即"删除消息"）。
- 去重是"当月 + 同类型"窗口而非全局唯一（`check_duplicate_in_current_month`），跨月/跨类型重复会再落盘；备份导入路径则做全 Catalog 哈希查找（`import_backup_asset`，:1067 注释明确差异）。
- 生成配置从会话中拆出为全局 `generation-config.json`（提交 `76a4ed79a` 起），会话文件只保留节点与输入草稿；类型参数保存在全局配置而非任务内（重试用 `currentConfig.types[type]` + taskSnapshot 的 prompt 混合恢复）。
- 工作台双模式（会话/快速）共用同一任务池与资产层，快速模式不建节点，历史只存在任务卡。
- `generateMedia` 文档声明为占位未实现，Agent 面以动态方法族为准（独特功能笔记「声明不符项」，`ARCHITECTURE.md:420`）。

**已确认边界**：

- 无本地生成/渲染引擎：所有生成都是远程 API 调用，离线不可用（源码事实）。
- 任务状态与进度主要面向 UI 展示，无统一回调注册面；Agent 进度经 `reportStatus` 桥接。
- `autoCleanCompleted`、`maxConcurrentTasks`、批量下载为"设置/占位存在、执行链未实现"（静态推断，基于全仓 grep 无消费者）。

**未验证事项**（均为"未运行验证：需要真实模型与图形环境"）：

- 真实模型生成（图片/视频/语音/音乐）、内嵌元数据与标准音频标签的实际写入效果、onPartialImage 流式预览。
- 远程媒体下载（tauriFetch/代理回退）、Ark/Agnes 视频轮询、MiniMax 翻唱两步工作流与 24h 有效期。
- 任务取消（abortTask/abortAll）在真实请求中的中断时效；超时与 maxRetries 行为。
- 会话索引/任务池的崩溃重启自愈、双层防抖在真实高频操作下的落盘完整性。
- 资产去重索引性能（10 万+ 自述上限）、`rebuild_hash_index`、重复导入事件与跨工具并发写入。
- 工作台 UI 渲染、跨窗口输入同步（`useMediaGenInputManager`）、拖放/粘贴素材交互。

## 9. 关键源码索引

- `src/tools/media-generator/media-generator.registry.ts`（toolConfig:44、getMetadata 动态方法族:217、可见性/路由:150-215、sidecar 查看生成参数:301）
- `src/tools/media-generator/services/buildAgentMethods.ts`（方法族构建:754、buildParameters:259、createHandler:640、buildResult:605、toAssetPath:600）
- `src/tools/media-generator/stores/mediaGenStore.ts`（submitTaskInSession:203、regenerateFromNode:489、removeTask:294、僵死节点 watch:334、openTaskResult:170）
- `src/tools/media-generator/composables/useMediaGenerationManager.ts`（executeGeneration:381、buildTask:649、handleResponseAssets:712、persistDerivedData:912、fetchAsArrayBuffer:1123、abortTask:312）
- `src/tools/media-generator/composables/useTaskActionManager.ts`（addTaskNode:83、getRetryParams:152）
- `src/tools/media-generator/composables/useMediaTaskManager.ts`（全局单例任务池、watch 防抖保存:80、normalizeTaskType:26）
- `src/tools/media-generator/composables/useMediaStorage.ts`（sessions-index.json/tasks.json/settings.json/generation-config.json 管理器、syncIndex:296、双层防抖:458）
- `src/tools/media-generator/composables/logic/useMediaGenPersistence.ts`（init 自愈:75-248、generating→error:178、防抖:291）
- `src/tools/media-generator/composables/useMediaGenParamRules.ts`（sanitizeParams:147、buildXaiSizeParams:394）
- `src/tools/media-generator/composables/useMediaExportManager.ts`（exportBranchAsMarkdown:38）
- `src/tools/media-generator/composables/useMiniMaxCoverWorkflow.ts`（startPreprocess:161、ensureTwoStepReady:128、24h 过期:219）
- `src/tools/media-generator/types.ts`（MediaTask:88、MediaMessage:65、GenerationSession:338、MediaGeneratorSettings:265）
- `src/tools/media-generator/config.ts`（默认设置:228、agentConfig 默认:293、超时 600s:284）
- `src/tools/media-generator/components/`（MediaWorkbench.vue 快速模式/停止/清理:57-99、MediaGenerationInput.vue 提交:411/素材过滤:215、MediaTaskList.vue 取消/重试:150-184、MediaTaskCard.vue 波形回写:200/打开目录:340、GenerationStream.vue 会话流）
- `src-tauri/src/commands/asset_manager.rs`（import_asset_from_bytes:870、check_duplicate_in_current_month:1265、月度索引:1208、list_assets_paginated:2200、remove_asset_source:2476、rebuild_hash_index:1720、import_backup_asset:1067、update_audio_waveform:2767）
- `src/composables/useAssetManager.ts`（assetManagerEngine 全局单例:73、importAssetFromBytes:113、getAssetUrl:174）
- `src/llm-apis/common.ts`（DEFAULT_MEDIA_TIMEOUT:32、LlmResponse:572）、`src/llm-apis/adapters/{openai,gemini,suno-newapi,minimax-music,siliconflow}/*`（媒体适配器族）
