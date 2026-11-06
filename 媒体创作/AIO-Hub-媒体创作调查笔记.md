# AIO Hub 媒体创作调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：对照源码快照差异，只读走查工作台入口、任务调度、结果卡与画廊、输入与持久化、Agent 方法和媒体协议适配器；资产存储以 Rust 命令为证据；未运行应用、构建、测试或真实模型请求
>
> 调查范围：桌面媒体工作台的输入、参数与参考资产、会话/任务双轨、进度与取消、资产入库、历史重试与复用、OpenRouter 媒体协议和 Agent 回流；渠道实体与通用工具审批分别交接相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 是**应用级桌面媒体工作站**（分型 M1 + M3，Agent 面 M5）。media-generator 与 asset-manager 两模块形成一条完整闭环：媒体生成会话（`GenerationSession` 树）与全局任务池（`MediaTask`）解耦为双轨，结果资产经 SHA-256 去重汇入应用级中央资产库（`Asset`），之后可预览、重试、分支、导出、发送到聊天或作为下一轮参考图再次使用。

- **会话-任务双轨**：会话树保存交互历史与提交快照，任务池单独管理执行状态；助手节点 ID 与任务 ID 一致。显示优先读取实时任务，缺失时回退节点快照，清理后的历史结果展示存在第 4 节所述边界（[提交与关联](<../../aio-hub/src/tools/media-generator/stores/mediaGenStore.ts#L217-L275>)）。
- **结果资产化**：解码或下载结果后，尝试嵌入生成参数再导入资产库；嵌入失败仍可继续，衍生数据另写入生成参数文件。至少一项成功入库才完成任务，全部失败则报错（[响应资产处理](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L1014-L1118>)）。
- **去重索引**：Rust 侧按当月目录做 SHA-256 去重（`check_duplicate_in_current_month`，`src-tauri/src/commands/asset_manager.rs:1265`）：命中时只给既有资产追加 `origin` 并回发 `asset-imported` 事件，不重复落盘；未命中才写文件，并更新月度 `.index.json` 与内存 Catalog。
- **Agent 共用入口**：`getMetadata()` 按当前启用的 Profile/模型与可见性配置动态生成 `generate_<model_id>` 方法族，`isFast` 模型同步返回结果，其余走 tool-calling 异步任务框架（`buildAgentMethods.ts:754`）；注册表另有三个非 agentCallable 的编程接口供外部注入输入框与附件（见第 6 节）。
- **本地音频渠道适配**：audio.cpp 通过普通 LLM Profile 接入 TTS。工作台按服务端语义默认不发送 OpenAI 的 `alloy` 音色，并把默认输出设为 WAV；响应仍以实际 `Content-Type` 判定格式，避免把 WAV 字节按 MP3 扩展名入库。Agent 动态方法同样把 audio.cpp 的 `audio_format` 限定为 `wav`（`packages/llm-core/src/providers/sync-media.ts:208-244`、`buildAgentMethods.ts:155-203`）。
- **输入工作区**：输入区与会话共用 `InputPanelHost`/`InputPanelLayout` 与 `useInputPanel` 契约，快捷词库和提示词优化作为单面板槽位打开；优化面板可选用视觉模型、读取当前草稿或参考图，按优化/翻译/优化并翻译三种模式调用 LLM，结果以编辑器原生替换写回（`components/PromptOptimizePanel.vue`、`components/QuickPromptLibrary.vue`）。输入提示词与已入库附件元数据随会话详情持久化（`inputPrompt`/`inputAttachments`，`types.ts:335-337`）。
- **任务工作区**：任务列表可在网格与列表间切换；列表按自身容器宽度调整为横向、折行或堆叠布局，并同步虚拟行高。结果卡与会话结果可把图片加入参考输入，画廊则按资产导入事件刷新历史预览（[任务列表布局](<../../aio-hub/src/tools/media-generator/components/MediaTaskList.vue#L52-L167>)、[参考输入去重](<../../aio-hub/src/tools/media-generator/composables/useMediaGenReferenceInput.ts#L6-L15>)）。
- **执行与恢复**：模块级队列实际限制并发，工作台设置默认 6 个槽位；取消收敛为 cancelled，重启把遗留的排队/生成任务转为 error。自动清理默认关闭，开启后只在 5 分钟延迟后移除已完成任务记录，结果资产及会话快照独立保留（第 3、4 节）。
- **OpenRouter 多媒体协议**：图像、视频、语音请求使用独立适配器，按协议选择参考素材、输出格式与轮询地址；上游进度映射到工作台的 30～89 区间。视频返回的轮询 URL 必须与配置 API 同源（[OpenRouter 媒体适配器](<../../aio-hub/packages/llm-core/src/providers/openrouter-media.ts#L19-L275>)）。

与独特功能笔记[能力一、二](../独特功能/AIO-Hub-独特功能调查笔记.md)证据一致；本页只覆盖媒体创作维度，不重复其中的完整源码调查。全部结论基于静态源码；真实模型生成、UI 渲染与资产索引性能均未运行验证。

## 系统边界与完整主链

边界：media-generator（工作台）+ asset-manager（资产层）为主贡献；聊天模块的多模态附件、转写、弹幕播放器与 FFmpeg 工具属于相邻边界，不入本主链。执行域是「Tauri 前端渲染进程 + 用户配置的 LLM Profile」，服务可以是远程 API，也可以是本机 audio.cpp HTTP 服务。应用不内嵌生成器、渲染器或独立生成后端，生成链路也不依赖 FFmpeg、ComfyUI 或浏览器渲染服务。

主链（用户会话模式）：

```text
MediaGenerationInput.handleSend（Ctrl+Enter，MediaGenerationInput.vue:490）
  -> store.submitTaskInSession（mediaGenStore.ts:217）
     -> useMediaGenerationManager.buildTask（纯函数打包参数，useMediaGenerationManager.ts:809）
     -> useMediaTaskManager.addTask 入全局任务池（useMediaTaskManager.ts:227）
     -> useTaskActionManager.addTaskNode 建 User/Assistant 节点（assistant.id=task.id + taskSnapshot，useTaskActionManager.ts:83）
     -> 可选自动命名（mediaGenStore.ts:234）
  -> executeGeneration：置 pending 并加入全局队列（useMediaGenerationManager.ts:767-803）
     -> pumpGenerationQueue：取得并发槽位后 runGeneration（同文件:95-120）
     -> AbortController；参考资产 Asset -> Base64（按 maxImageDimension 缩放）
     -> sanitizeParams 按模型 mediaGenParams 规则清洁（useMediaGenParamRules.ts:147）
     -> applyContextRules 裁剪多轮上下文（useMediaGenerationManager.ts:441）
     -> useLlmRequest.sendRequest（inspectorContext + signal；openai-responses 走 onPartialImage 流式预览）
  -> handleResponseAssets（useMediaGenerationManager.ts:867）
     -> 解码 b64 / Data URL / tauriFetch 拉取 URL（代理回退）
     -> 可选 writeStandardMediaMetadata（音频）+ embedMetadata 内嵌参数
     -> importAssetFromBytes（Rust asset_manager.rs:873：SHA-256 当月去重 -> 落盘/追加 origin -> asset-imported 事件）
     -> persistDerivedData 写衍生数据 + update_asset_derived_data
  -> 任务标 completed，resultAssets/resultAssetIds 关联（useMediaGenerationManager.ts:879 起）
```

快速模式（`workbenchMode === "quick"`）跳过会话树，由 `MediaWorkbench.vue:52` 的入口直接构建任务、加入全局任务池并执行，任务仍进全局池、结果仍入资产库。Agent 路径则在 `buildTask` 之后接入同一执行链（`buildAgentMethods.ts:662` createHandler）。

## 1. 创作入口、触发者与事实对象

**入口**：工具页 `/media-generator`（`media-generator.registry.ts:44` toolConfig），四 Tab：工作台/画廊/任务列表/生成设置（`views/MediaGeneratorView.vue:41`）；工作台内「创作会话 / 快速生成」双模式（`MediaWorkbench.vue:52` workbenchMode 持久化于 localStorage）。右侧 `AssetGallery` 直接引用全局资产库。

**触发者**：用户手动为主；Agent 为次——`getMetadata()` 每次被调用时对当前可见模型生成 `generate_<sanitized_model_id>` 方法并绑定 handler（`media-generator.registry.ts:218`）；可见性由 Agent 配置的黑/白名单、Profile 优先级与快速模型清单共同决定（`collectVisibleModels`，同文件 `:151`）。本次在媒体注册表与工作台入口中未找到媒体专用的定时调度接口；已提交请求由前端进程持有，切换展示面板与进程退出的语义应分别看待，重启处理见第 4 节。

**事实对象**三个，真源不同：

| 对象 | 定义 | 真源 |
|---|---|---|
| `GenerationSession` | 会话索引项 + 详情（`types.ts:320,347`），详情含 `nodes` 节点池、`rootNodeId`、`activeLeafId`、`generationConfig` 与输入草稿 `inputPrompt`/`inputAttachments` | `sessions/{id}.json` |
| `MediaMessage` | 树节点（`types.ts:66`），metadata 携带 `taskId/isMediaTask/includeContext/taskSnapshot/translatedContent` | 随会话详情 |
| `MediaTask` | 全局任务（`types.ts:89`），五态 `pending/processing/completed/error/cancelled`，`input.params` 参数快照、`resultAssetIds/resultAssets` | `tasks.json` |
| `Asset` | 资产层对象（path/sha256/origins[]/metadata.derived） | `$APPDATA/assets/` + `assets.jsonl` |

桥接字段是 Assistant 节点上的 `metadata.taskSnapshot`（重试恢复用）与 `assistantNode.id === task.id`。资产本身不由 media-generator 拥有，而是中央资产库的共享对象（跨工具复用面，见第 4 节）。

## 2. 参数、素材与模型/渲染执行

**参数**：每种媒体类型有一套独立的参数定义（`MediaTypeConfig.params`，`types.ts:156`），由全局配置文件 `generation-config.json` 持久化（`useMediaStorage.ts:99`）。请求前 `sanitizeParams` 按模型的 `mediaGenParams` 规则清理参数：剔除不支持的键、钳制数值、校验枚举并填充默认值；xAI/Gemini 类模型通过 `aspectRatioMode`（`buildXaiSizeParams`）或专用适配器构造尺寸。UI 层还有一组参数别名映射（如 steps→numInferenceSteps、cfgScale→guidanceScale、duration→durationSeconds），在 `useMediaGenerationManager.ts:600-640`。各媒体类型的参数面如下（节选用于说明边界）：

```text
通用绘图：size, quality, style, negativePrompt, seed, steps, cfgScale, background,
          inputFidelity, partialImages, duration
Suno：suno_mode, mv, tags, title, make_instrumental
TTS：audioConfig, instructions 等
```

audio.cpp 的语音参数与 OpenAI 默认值不同。该渠道下音色留空表示使用服务端 `default_voice_preset`，界面允许自由输入服务端 preset、`voice_dir` 音色名或 cached voice ID；输出格式默认且只允许 WAV。通用音频适配器不会注入 `alloy`，并优先按响应 `Content-Type` 推断真实容器格式（`useMediaGenParameterState.ts:402-441`、`ModelParameterFields.vue:499-518`、`packages/llm-core/src/providers/sync-media.ts:208-244`）。

**素材与上下文**：拖放、粘贴与文件选择按媒体类型过滤素材，先导入资产库再作为附件提交。输入附件最多 16 项，以资产 ID 去重；这个上限由附件管理器执行，具体模型端点仍可能有更窄限制（[输入素材入口](<../../aio-hub/src/tools/media-generator/components/MediaGenerationInput.vue#L293-L470>)、[附件管理器](<../../aio-hub/src/tools/media-generator/composables/useAttachmentManager.ts#L23-L70>)）。执行时从本地资产读取字节并转 Base64，模型声明最大图片尺寸时先缩放；附件读取失败时保留原条目交给后续链路，缩放失败时继续使用原字节；音频附件只做 Base64 编码（[素材转换](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L532-L598>)）。

上下文开关保存在各媒体类型配置中，界面调整时还写回所选模型的迭代细化能力。支持对话的生成端点按开关或手选消息裁剪历史；其余端点走单轮请求，但在模型支持参考输入时，可使用手选消息中的图片，或在开关开启时取紧邻上一条助手结果图片。关闭开关且未手选消息时，不自动携带上一轮图片（[上下文开关](<../../aio-hub/src/tools/media-generator/components/MediaGenerationInput.vue#L132-L201>)、[单轮参考选择](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L241-L275>)、[执行交接](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L498-L530>)）。

**输入工作区**：输入从功能面板、附件、提示词编辑器到工具栏依次排布；面板与附件高度会从编辑区预算中扣除。快捷词库与提示词优化共用单面板容器，重复点击已打开入口默认关闭，也可按设置切换为折叠；切媒体类型、会话或工作区模式时关闭面板（[输入面板接线](<../../aio-hub/src/tools/media-generator/components/MediaGenerationInput.vue#L48-L117>)、[默认设置](<../../aio-hub/src/tools/media-generator/config.ts#L194-L199>)）。快捷词按当前选区插入，优化结果则替换提示词并通过编辑器原生操作保留撤销历史（[写回入口](<../../aio-hub/src/tools/media-generator/components/MediaGenerationInput.vue#L210-L291>)）。

提示词优化分为优化、翻译、优化并翻译三种模式，可独立选择模型和目标语言。只有非纯翻译、所选模型具备视觉能力且用户允许时，才读取已入库图片并随草稿发送；文本模型同样可处理优化任务，只省去参考图。结果先显示在预览区，点击应用才写回输入框；空结果给出错误，面板卸载时中止请求（[参考图条件](<../../aio-hub/src/tools/media-generator/components/PromptOptimizePanel.vue#L110-L161>)、[请求与应用结果](<../../aio-hub/src/tools/media-generator/components/PromptOptimizePanel.vue#L341-L423>)）。提示词与附件资产元数据作为会话草稿防抖保存，切会话时重新装入，详见第 4 节。

**执行位置**：请求发往所选 LLM Profile 对应的服务，适配器统一返回图片、视频或音频结果。图片/语音可同步返回，视频和部分音乐使用创建任务后轮询；audio.cpp 是用户另行运行的本机 HTTP 服务。工作台自己负责任务与资产管理，生成发生在所配置的外部服务中。

OpenRouter 按渠道身份、类型或官方域名识别，即使模型路由重映射提供方身份，媒体协议仍能保持。桌面 OpenAI 图片/视频/音频入口显式切换到其独立适配器；图片入口也会按渠道类型分流到 SiliconFlow（[渠道识别](<../../aio-hub/packages/llm-core/src/providers/openrouter-media.ts#L18-L36>)、[桌面图片分流](<../../aio-hub/src/llm-apis/adapters/openai/image.ts#L20-L40>)）。协议边界如下：

| 媒体 | OpenRouter 请求与结果规则 | 证据 |
|---|---|---|
| 图像 | JSON 图片端点；参考图片转为输入引用；显式像素尺寸优先于比例/分辨率；拒绝 mask 输入；输出格式仅保留端点支持值 | [图像适配器](<../../aio-hub/packages/llm-core/src/providers/openrouter-media.ts#L38-L127>) |
| 语音 | 输出限 mp3/pcm，音色可自由填写；参考图/音频按协议转换引用，格式错误直接报错 | [语音适配器](<../../aio-hub/packages/llm-core/src/providers/openrouter-media.ts#L129-L170>) |
| 视频 | 首尾帧与普通素材分别映射；创建后轮询任务状态，成功取返回 URL 或下载内容端点；服务返回的轮询地址受配置 API 同源检查，自定义状态端点优先 | [视频适配器](<../../aio-hub/packages/llm-core/src/providers/openrouter-media.ts#L172-L314>) |

这组规则影响工作台实际可用参数和结果收口；渠道配置、普通聊天路由和鉴权属于 LLM 渠道类目，真实远端兼容性尚未运行验证。

## 3. 任务状态、异步回调与取消

### 全局队列与状态收口

任务先进入 pending，取得槽位后转 processing，结果为 completed、error 或 cancelled。队列与运行任务集合放在模块级，工作台、任务列表及 Store 的多次 composable 实例化共用它们。队列泵按当前并发数启动任务，执行结束的 finally 释放槽位并继续泵送；重复提交同一运行中或排队中的任务 ID 会直接返回，不重复发送请求（[队列泵](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L93-L141>)、[入队与去重](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L764-L803>)）。

工作台设置的并发默认值为 **6**；Store 立即把设置同步给运行时。底层管理器初始化兜底为 3，实际值会规范到 1～10；运行时调整并发会再次泵送队列（[设置默认值](<../../aio-hub/src/tools/media-generator/config.ts#L194-L199>)、[设置消费](<../../aio-hub/src/tools/media-generator/stores/mediaGenStore.ts#L85-L95>)）。会话输入界面还会在已有生成任务时阻止再次发送，快速生成与 Agent 入口则可持续进入共享队列（[输入门控](<../../aio-hub/src/tools/media-generator/components/MediaGenerationInput.vue#L490-L500>)）。

取消也区分排队与运行：排队任务从队列移除、置 cancelled 并结算等待者；运行任务才有独立的 AbortController，中止后由执行 catch 捕获 AbortError 并置 cancelled，finally 回收控制器。全部停止同时覆盖两类任务；本地取消是否能停止外部服务的实际生成，仍需服务端协议与运行验证（[取消入口](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L394-L429>)、[终态收口](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L739-L761>)）。

### 进度、超时与清理

- **阶段进度**：准备附件后开始生成，进度到 30；轮询回调以单调方式推进到 89 以内，上游未给百分比时缓慢自增；入库到 90，完成到 100。Responses 图像的中间帧另写入任务预览数组（[预览与进度](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L666-L715>)）。
- **请求与下载分开计时**：媒体请求默认 10 分钟，默认不自动重试；下载预算默认每资产 120 秒，可配置到 10～1200 秒（[请求默认值](<../../aio-hub/src/llm-apis/common.ts#L33>)、[下载预算](<../../aio-hub/src/tools/media-generator/config.ts#L109-L124>)）。
- **入库兜底**：watchdog 取“每资产下载预算 × 返回资产数 + 120 秒”作为整体预算，超时后任务进入 error，迟到的入库流程不会覆盖任务终态，但可能仍完成资产落盘（[watchdog](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L717-L737>)、[迟到结果保护](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L1089-L1104>)）。
- **自动清理**：默认关闭；开启后为 completed 任务安排固定 5 分钟计时器，到期仅移出全局任务池。开启设置或初始化时也会为已有完成任务安排计时，关闭设置则撤销计时器。会话快照与资产库继续保留；手动“清理已结束”则逐项调用 Store 删除，连同当前会话中的对应节点清理（[清理执行消费者](<../../aio-hub/src/tools/media-generator/composables/useMediaTaskManager.ts#L167-L205>)、[完成触发](<../../aio-hub/src/tools/media-generator/composables/useMediaTaskManager.ts#L239-L265>)、[手动清理](<../../aio-hub/src/tools/media-generator/components/MediaTaskList.vue#L218-L224>)）。

Agent 调用复用同一媒体执行队列。非 fast 模型声明为可报告进度、可取消的异步工具，handler 转发取消信号并报告媒体任务状态；fast 模型走同步工具。工具框架任务与媒体任务是两层状态，工具层恢复/审批交接见[Agent 工具笔记](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)，媒体池重启收口见第 4 节。

## 4. 结果、历史、资产与工程持久化

- **会话历史**：历史数据全部落在 `{appConfigDir}/media-generator/` 下，由以下文件承担：
  - `sessions-index.json`：轻量索引 + 当前会话 ID
  - `sessions/{id}.json`：会话树详情
  - `tasks.json`：全局任务池
  - `settings.json`：用户设置
  - `generation-config.json`：全局生成配置

  写入带双层防抖：store 层 1s（`useMediaGenPersistence.ts:307`）+ storage 层 2s（`useMediaStorage.ts:458`）；索引自愈由 `syncIndex` 扫描物理目录补齐/剔除索引项（`useMediaStorage.ts:296`）。输入提示词与附件元数据随会话详情防抖保存，重启或切换会话时还原（`types.ts:335-337`、`useMediaGenPersistence.ts`）。
- **启动自愈**：全局任务池初始化把遗留 pending/processing 转为 error，分别写明“排队任务未恢复”或“生成中断”，并保存修正结果；它们不会重新入队。会话加载再按关联任务完成情况，把 generating 节点修正为 complete 或 error，并修复活动叶子与缺失根节点（[任务池恢复](<../../aio-hub/src/tools/media-generator/composables/useMediaTaskManager.ts#L92-L130>)、[节点恢复](<../../aio-hub/src/tools/media-generator/composables/logic/useMediaGenPersistence.ts#L180-L239>)）。

  显示时优先读实时任务，找不到时回退到节点快照；但普通提交时快照是 pending 任务的深拷贝，当前执行完成只更新任务池。检索媒体目录的快照写入点，未找到完成结果自动回写到节点快照的消费者。因此“节点和资产仍存在”与“任务清理后历史仍能显示完整结果”需分开看：按此数据链推断，任务移除后可能回退到缺少结果的提交快照，实际交互效果尚未运行验证（[初建快照](<../../aio-hub/src/tools/media-generator/composables/useTaskActionManager.ts#L122-L136>)、[显示优先级](<../../aio-hub/src/tools/media-generator/components/message/MessageContent.vue#L158-L181>)、[结果写回](<../../aio-hub/src/tools/media-generator/composables/useMediaGenerationManager.ts#L1089-L1118>)）。
- **资产持久化**：物理文件按类型/月份分目录存放于 `$APPDATA/assets/`；Rust 侧维护 `AssetCatalog` 内存目录（并发读写）并以 `assets.jsonl` 作中央索引，变更后落盘；每目录另有 `.index.json` 月度哈希索引。导入流程 `import_asset_from_bytes`（`asset_manager.rs:873`）：

  1. 计算 SHA-256，调用 `check_duplicate_in_current_month` 查当月同类型去重（:1293）
  2. 命中：若来源模块（`sourceModule`）不同则追加 `origin` 并发出 `asset-imported` 事件，直接返回既有资产
  3. 未命中：写文件、提取图片宽高、生成缩略图/音频封面、写月度索引、入内存 Catalog

  `rebuild_hash_index`（:1748）可全量重建哈希索引。图片宽高、`audio_waveform`（前端 Web Audio 采样后经 `update_audio_waveform` 回写，:2795）与 `derived` 元数据都挂在 `AssetMetadata` 上。
- **来源生命周期**：`origins[]` 数组记录资产的每个来源（类型、来源标识、来源模块）。`add_asset_source` 追加来源，`remove_asset_source` 在最后一个来源被移除时删除物理文件（`asset_manager.rs:2504`）。生成结果写入的来源标记为：

  ```text
  origin.type = "generated"
  source = revisedPrompt || taskId
  sourceModule = "media-generator"
  ```
- **衍生数据**：每次入库同时把生成参数快照写入 `derived/media-generator/{date}/{assetId}.json`，并经 `update_asset_derived_data` 挂到 `metadata.derived["generation"]`（`useMediaGenerationManager.ts:1124`）。asset-manager 侧「查看生成参数」优先读衍生文件，缺失时回退到 `get_asset_binary` + `extractMetadata` 从文件内嵌元数据提取（`media-generator.registry.ts:302-358`）。音频另支持写入 ID3/WAV INFO 标准媒体标签（含用户档案作者与 prompt 注释，`useMediaGenerationManager.ts:1016`），默认关闭（`metadataWrite.enabled=false`）。
- **删除**：`removeTask` 先清任务池再级联删除会话节点（`mediaGenStore.ts:312`）；删除会话走 `deleteSession`。资产删除在 asset-manager UI/Rust 侧（`remove_asset_completely`）。

## 5. 预览、编辑、重试、分支与复用

### 任务列表与结果预览

任务列表按提示词/模型搜索，结合媒体类型与状态过滤，再按创建时间倒序展示。网格按容器宽度分列并虚拟化行；列表模式使用同一批过滤任务，按实际滚动容器宽度在三种布局间切换，行高随布局调整，并按比例修正当前滚动位置。布局因此受工作区、侧栏或分离窗口的可用宽度影响，视觉效果尚未现场验证（[过滤与两种虚拟列表](<../../aio-hub/src/tools/media-generator/components/MediaTaskList.vue#L52-L167>)）。

| 列表容器宽度 | 列表布局 | 虚拟行高 |
|---|---|---|
| 至少 1040px | 横向完整行 | 96px |
| 560～1039px | 折行 | 152px |
| 小于 560px | 堆叠 | 248px |

结果卡保存“资产与可用 URL”的对应关系，多结果可切换当前项，当前图片可一键加入参考输入；完整提示词和错误信息分别有可滚动的详情框。视频 URL 经过统一媒体源适配，音频波形按当前结果懒加载并缓存（[结果切换与加参考](<../../aio-hub/src/tools/media-generator/components/MediaTaskCard.vue#L155-L238>)、[详情框与媒体源](<../../aio-hub/src/tools/media-generator/components/MediaTaskCard.vue#L77-L153>)）。

全局打开结果仍按图片、视频、音频分发查看器，可配置生成后自动打开；任务列表的下载和复制结果入口取首个资产，卡内“打开所在目录”则跟随当前结果项，二者范围不同（[任务操作](<../../aio-hub/src/tools/media-generator/components/MediaTaskList.vue#L255-L345>)、[卡内目录操作](<../../aio-hub/src/tools/media-generator/components/MediaTaskCard.vue#L425-L443>)）。

### 重试、分支与编辑

重试有两条不同入口：

- **任务列表重试**只把旧提示词、模型、参数和输入附件恢复到当前表单，等待用户再次发送；它本身不新建任务（[恢复表单](<../../aio-hub/src/tools/media-generator/components/MediaTaskList.vue#L227-L253>)）。
- **会话重生成**使用历史提示词和用户节点附件，但模型及类型参数取当前配置，随机种子设为 -1；临时换模型时再覆盖本次选择。入口先解析参数，再在原 User 下创建兄弟 Assistant，按新节点 ID 建新任务并进入共享队列。同一源节点重试期间加锁防重复（[参数来源](<../../aio-hub/src/tools/media-generator/composables/useTaskActionManager.ts#L173-L228>)、[重建分支与执行](<../../aio-hub/src/tools/media-generator/stores/mediaGenStore.ts#L511-L601>)）。

分支、编辑与导出另有以下入口：

- **分支**：分支操作有四种语义：
  - `createRegenerateBranch`：重试语义
  - `createBranch`：纯复制语义（`useBranchManager`）
  - `switchToBranch`：`findDeepestLeaf` 后切换
  - `saveToBranch`：复制后修改内容

  节点删除为级联硬删除；会话模式用树路径 `getNodePath` 渲染活跃路径（`store.messages`）。
- **编辑**：节点编辑入口包括 `editMessage`、`updateNodeData` 与直接编辑节点 JSON 的 `MessageDataEditor`；`updateNodeData` 禁止改动节点结构字段 `id`/`parentId`/`childrenIds`（`mediaGenStore.ts:706`）。批量模式可选中多条消息后删除（批量下载仍为 TODO 占位，`MediaWorkbench.vue:165-166`）。
- **导出**：`exportBranchAsMarkdown` 把分支路径导出为 Markdown（含参数快照 JSON 与资产信息，`useMediaExportManager.ts:38`）；任务卡支持复制提示词、打开文件所在目录（`MediaTaskCard.vue:425` openFileDirectory）。

### 资产复用与画廊

结果卡与会话消息中的图片按钮都接到同一参考输入入口，按资产 ID 拒绝重复，并检查 16 项附件上限；加入后还需用户再次提交，才会成为新任务素材。它复用已有资产，不重新导入文件（[卡片接线](<../../aio-hub/src/tools/media-generator/components/MediaTaskList.vue#L205-L215>)、[会话接线](<../../aio-hub/src/tools/media-generator/components/message/MessageContent.vue#L222-L232>)、[共享参考输入](<../../aio-hub/src/tools/media-generator/composables/useMediaGenReferenceInput.ts#L6-L15>)）。

画廊 Tab 从资产库分页读取生成结果，优先用内联元数据、再用衍生文件加载提示词；右侧历史面板只读媒体生成器来源的生成资产首批 50 项。二者都订阅资产导入事件并以 200ms 延迟合并刷新，提供图片/视频/音频预览；当前模板中未接参考输入按钮（[右侧历史](<../../aio-hub/src/tools/media-generator/components/AssetGallery.vue#L63-L159>)、[画廊元数据](<../../aio-hub/src/tools/media-generator/components/MediaGallery.vue#L69-L125>)）。跨工具复用通过资产管理器“发送到聊天”与 Agent 结果路径完成；Agent 返回的资产路径使用应用数据协议，显示交接见[Agent 工具笔记](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)。

## 6. Agent 回流、插件与外部依赖

- **发现**：动态方法族 `generate_<model_id>` 的参数声明由模型 `mediaGenParams` 规则生成（`buildAgentMethods.ts:280`），方法描述含模型、渠道与快速模式等说明。语音参数还读取渠道类型：audio.cpp 不套用 OpenAI 音色枚举，输出格式只暴露 WAV。同一 modelId 多渠道时按 Profile 优先级路由；agentConfig/Profile 配置变更经 watch 使工具发现缓存失效。
- **调用与返回**：handler 先校验 prompt 必填、媒体类型支持，并要求非 fast 模型必须异步执行（`buildAgentMethods.ts:682-714`）；成功或失败时由 `buildResult` 组装结构化结果（同文件 `:627-660`）：

  ```text
  成功: {success, taskId, type, prompt, assets: [appdata://…], assetIds}
  失败: {success:false, error}
  ```
- **编程接口**：`addContentToInput`、`setInputContent`、`addAssets` 是注册表的公开方法，但**不在 `getMetadata()` 中**（非 agentCallable），供其他模块写入输入框与附件（`registry.ts:232-300`）。`getAssetSidecarActions` 让资产右键菜单挂“查看生成参数”。
- **审批与异步**：Agent 媒体生成走通用 tool-calling 审批/执行链（executor 二次校验 agentCallable、审批状态机、异步任务框架），细节见 Agent 工具笔记第 5/6/11 节，本笔记不重复。
- **外部依赖**：生成请求依赖用户 LLM Profile 对应的远程或本地 HTTP 服务；audio.cpp 需要用户自行运行服务进程。远程媒体下载走 Tauri HTTP 插件，失败回退本地代理；本地文件走 `convertFileSrc`。**本次未找到**媒体插件族/manifest 协议；生成链本身不依赖 FFmpeg、ComfyUI 或浏览器渲染服务。

## 7. 权限、资源边界与失败恢复

- **参数边界**：`sanitizeParams` 是模型参数的最后一道闸（剔除/钳制/枚举校验），但 `prompt` 不做任何内容过滤，完全由 LLM/用户控制（源码事实，与 Agent 工具笔记一致）。
- **素材边界**：参考素材按媒体类型过滤扩展名（`MediaGenerationInput.vue:293`）；图片按 `maxImageDimension` 缩放；MiniMax 翻唱限制单参考音频并校验两步工作流前置条件（`useMediaGenerationManager.ts:1304` validateMiniMaxTwoStepCover、`useMiniMaxCoverWorkflow.ts:128` ensureTwoStepReady，预处理结果 24h 过期）。提示词优化的参考图输入另受视觉能力与处理模式约束：文本模型可继续进行优化、翻译及二者组合，只使用文本；纯翻译即使选择视觉模型也不读取图片（[条件与提示](<../../aio-hub/src/tools/media-generator/components/PromptOptimizePanel.vue#L119-L161>)）。
- **资源限额**：超时/重试可配；`maxConcurrentTasks` 是全局执行级并发上限，但本次未找到任务总数、文件大小或磁盘配额的执行级限额。`autoCleanCompleted` 开启时，已完成任务在固定 5 分钟延迟后从全局任务池移除（`useMediaTaskManager.ts:188-211`），会话树中的结果节点保留；资产库 10 万+ 性能上限仅为 ARCHITECTURE 自述（`asset-manager/ARCHITECTURE.md:76`），未实测。
- **失败恢复**：各类失败按场景收敛（`useMediaGenerationManager.ts`）：
  - 请求异常：任务置 `error` 并写 statusText（`:753`）；取消类中断单独处理为“已中止”（见第 3 节）
  - 资产入库：单条失败只记日志不中断其余（:1081），全部失败则整体报错（:1117）；入库阶段另有阶段级预算，超时视为任务失败并写入“资产入库超时”（`:735`）
  - 元数据写入：`embedMetadata`/标准标签失败降级继续入库（:1016、:1033）
  - 远程下载：tauriFetch 失败自动走代理回退（:1395）

  崩溃/重启：任务池中的排队及运行任务会转为 error，节点按第 4 节规则自愈；不会重新发出生成请求。任务清理后会话显示依赖快照的完整性，资产文件则由独立资产库管理。

## 8. 设计取舍、已确认边界与未验证事项

**取舍**：

- 会话与任务用相同 ID 关联，界面可以直接定位实时任务；手动删除经 Store 清理当前会话节点，自动清理则只移除池记录。快照是否包含完整结果决定任务池清理后的历史可读性，详见第 4 节。
- 去重是"当月 + 同类型"窗口而非全局唯一（`check_duplicate_in_current_month`），跨月/跨类型重复会再落盘；备份导入路径则做全 Catalog 哈希查找（`import_backup_asset`，:1067 注释明确差异）。
- 当前生成配置的权威入口是全局配置文件；会话详情仍保存配置副本，初始化时会用全局配置装入当前参数，切会话时保留当前全局选择。任务输入另有提交参数快照，会话重生成采用当前参数与历史提示词/附件，任务列表重试则恢复旧任务表单（[当前配置加载](<../../aio-hub/src/tools/media-generator/composables/logic/useMediaGenPersistence.ts#L241-L251>)、[会话保存形状](<../../aio-hub/src/tools/media-generator/composables/logic/useMediaGenPersistence.ts#L280-L303>)）。
- 工作台双模式（会话/快速）共用同一任务池与资产层，快速模式不建节点，历史只存在任务卡。
- 输入面板与 Chat 共用公共组件契约而非各自实现：好处是折叠/替换/焦点行为一致，代价是媒体输入区需随公共契约与自身高度预算同时调整（`Components/common/README.md#inputpanel`）。
- `generateMedia` 文档声明为占位未实现，Agent 面以动态方法族为准（独特功能笔记「声明不符项」，`ARCHITECTURE.md:435`）。

**已确认边界**：

- 应用不内嵌生成/渲染引擎；生成通过 Profile 对应的 HTTP 服务执行。audio.cpp 可以部署在本机，但它是独立外部服务，不随应用内置。
- 任务状态与进度主要面向 UI 展示，无统一回调注册面；Agent 进度经 `reportStatus` 桥接，异步轮询任务经 `onMediaProgress` 回调上报。
- 批量下载仍为占位；`autoCleanCompleted` 与 `maxConcurrentTasks` 已接入任务池，前者在延迟后把已完成任务移出任务池，后者约束全部媒体工作区共享的并发请求数。
- OpenRouter 多媒体协议只覆盖图像、视频、语音三类端点；桌面端与官方域名都走该协议，其他 OpenAI 兼容渠道仍走通用适配器。

**未验证事项**（均为"未运行验证：需要真实模型与图形环境"）：

- 真实模型生成（图片/视频/语音/音乐）、内嵌元数据与标准音频标签的实际写入效果、onPartialImage 流式预览。
- 远程媒体下载（tauriFetch/代理回退）、Ark/Agnes/OpenRouter 视频轮询（含跨源 polling_url 拒绝）、MiniMax 翻唱两步工作流与 24h 有效期。
- 任务取消（abortTask/abortAll）在真实请求中的中断时效；超时与 maxRetries 行为；入库阶段超时预算的实际阈值表现。
- 会话索引/任务池的崩溃重启自愈、双层防抖在真实高频操作下的落盘完整性、输入草稿随会话恢复。
- 资产去重索引性能（10 万+ 自述上限）、`rebuild_hash_index`、重复导入事件与跨工具并发写入。
- 工作台 UI 渲染、跨窗口输入同步（`useMediaGenInputManager`）、拖放/粘贴素材交互。
- 提示词优化面板的多模态提示词效果、参考图读取开关与纯文本模型降级；快捷词库按选区插入的实际交互。
- 任务记录被自动清理后，会话回退提交快照的实际展示与重试体验；默认/修改并发下的真实队列时序、网格/列表切换及不同宽度下的视觉表现。

## 9. 关键源码索引

- `src/tools/media-generator/media-generator.registry.ts`（toolConfig:44、getMetadata 动态方法族:218、可见性/路由:151-215、sidecar 查看生成参数:302）
- `src/tools/media-generator/services/buildAgentMethods.ts`（方法族构建:754、buildParameters:280、createHandler:662、buildResult:627、toAssetPath:622）
- `src/tools/media-generator/stores/mediaGenStore.ts`（submitTaskInSession:217、regenerateFromNode:511、removeTask:312、僵死节点 watch:350、openTaskResult:184）
- `src/tools/media-generator/composables/useMediaGenerationManager.ts`（executeGeneration:767、buildTask:809、handleResponseAssets:867、persistDerivedData:1124、fetchAsArrayBuffer:1336、abortTask:397、进度回调:684-696）
- `src/tools/media-generator/composables/useTaskActionManager.ts`（addTaskNode:83、getRetryParams:152）
- [任务池管理](<../../aio-hub/src/tools/media-generator/composables/useMediaTaskManager.ts>)：重启收口、任务防抖保存、运行时配置与 5 分钟自动清理。
- `src/tools/media-generator/composables/useMediaStorage.ts`（sessions-index.json/tasks.json/settings.json/generation-config.json 管理器、syncIndex:296、双层防抖:458）
- `src/tools/media-generator/composables/logic/useMediaGenPersistence.ts`（init 自愈:75-248、generating→error:197、防抖:307）
- `src/tools/media-generator/composables/useMediaGenParamRules.ts`（sanitizeParams:147、buildXaiSizeParams:394）
- `src/tools/media-generator/composables/useMediaGenParameterState.ts`、`components/ModelParameterFields.vue`（audio.cpp 音色与 WAV 参数语义）
- `src/tools/media-generator/composables/useMediaExportManager.ts`（exportBranchAsMarkdown:38）
- `src/tools/media-generator/composables/useMiniMaxCoverWorkflow.ts`（startPreprocess:161、ensureTwoStepReady:128、24h 过期:219）
- `src/tools/media-generator/components/PromptOptimizePanel.vue`、`QuickPromptLibrary.vue`（提示词优化与快捷词库面板）
- [媒体输入区](<../../aio-hub/src/tools/media-generator/components/MediaGenerationInput.vue>)与公共输入面板组件：面板生命周期、参考素材、草稿编辑与提交。
- `src/tools/media-generator/types.ts`（MediaTask:89、MediaMessage:66、GenerationSession:347、GenerationSessionDetail:320、MediaGeneratorSettings:268）
- [媒体默认配置](<../../aio-hub/src/tools/media-generator/config.ts#L109-L199>)：下载预算、提示词优化配置与默认并发数。
- `src/tools/media-generator/components/`（MediaWorkbench.vue 快速模式/停止/清理:52-99、MediaGenerationInput.vue 提交:490/素材过滤:293、MediaTaskList.vue 取消/重试:200,227、MediaTaskCard.vue 波形:597/打开目录:425、GenerationStream.vue 会话流）
- `src-tauri/src/commands/asset_manager.rs`（import_asset_from_bytes:873、check_duplicate_in_current_month:1293、月度索引:1208、list_assets_paginated:2228、remove_asset_source:2504、rebuild_hash_index:1748、import_backup_asset:1070、update_audio_waveform:2795）
- `src/composables/useAssetManager.ts`（assetManagerEngine 全局单例:73、importAssetFromBytes:113、getAssetUrl:174）
- `src/llm-apis/common.ts`（DEFAULT_MEDIA_TIMEOUT:33、LlmResponse:558）、`src/llm-apis/adapters/{openai,gemini,suno-newapi,minimax-music,siliconflow}/*`（媒体适配器族）
- `packages/llm-core/src/providers/openrouter-media.ts`（isOpenRouterProfile:19、image:38、audio:129、video:172）
- `packages/llm-core/src/providers/sync-media.ts`（audio.cpp TTS 默认值与响应格式推断）
