# OpenClaw 媒体创作调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：静态源码与仓库文档走读；沿 Agent 媒体工具、媒体生成 runtime、插件能力注册、任务 registry、Gateway 媒体托管和 artifact RPC 复查入口、状态、持久化与回流关系；未运行测试、未调用外部模型或 ComfyUI、未启动 Gateway 与 Control UI
>
> 调查范围：图片、视频、音乐生成工具及其插件能力目录、参数与参考素材、异步任务、失败/取消/恢复、生成结果托管、Artifact 查询和 Agent 回流；媒体理解、TTS、相机/录屏节点、播放器与普通附件只作边界样本，不作为媒体创作主链；不调查具体 Provider 的真实生成质量、计费服务和客户端视觉效果
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**准入结论：主链确认，纳入媒体创作正式比较。** OpenClaw 提供三个媒体专用 Agent 工具 `image_generate`、`video_generate`、`music_generate`，由插件注册多个媒体生成 Provider 和模型能力目录；会话内请求会建立带 `taskId`、`runId`、会话归属和媒体任务类型的后台任务，结果落入媒体存储并通过内部完成事件回到原 Agent 会话，随后由 Gateway 转成受会话权限保护的媒体 Artifact。入口、任务、结果托管和 Agent 回流构成一条可走通的最小主链。

准入检查表如下：

| 检查项 | 结论 | 依据与边界 |
|---|---|---|
| 媒体专用入口、插件族、模型目录 | 已确认 | 三个专用生成工具；图片/视频/音乐 Provider registry；`action: "list"` 返回 Provider、模型、模式和能力；插件 manifest 声明能力合同 |
| 独立任务、历史、资产或工程身份 | 部分确认 | `task_runs` 为独立任务事实源，结果还有 `attachmentId`、Artifact ID 和托管媒体记录；本次未找到独立媒体历史树、资产库、版本对象或媒体工程对象 |
| 参数与参考素材 | 已确认 | 图片编辑、多图参考；视频文生视频、图生视频、视频变换和角色提示；音乐的歌词、时长、格式和参考图；Provider 能力决定归一化或拒绝 |
| 异步状态、回调、取消、失败、恢复 | 已确认但强度不一 | 任务状态、Provider 内部轮询、超时、失败和完成回流齐全；取消主要是任务层投影，未见统一 Provider 任务撤销；重启后的媒体任务没有在本次范围内确认可重新接管 |
| 预览、编辑、重试、复用 | 部分确认 | Control UI 和 Artifact RPC 可预览、下载、取缩略图；参考素材可再次作为输入，失败可重新调用；未找到媒体专用编辑器、分支树或 `retry`/`edit existing artifact` action |
| Agent 回流 | 已确认 | 完成事件携带结构化附件和回复指令，唤醒原会话的 Agent 生成可见回复；必要时有直接媒体回退路径的文档与实现支撑 |

能力归类为 **M1 模型生成工作站的任务化子集 + M4 插件化媒体编排 + M5 Agent 驱动创作**。M3 只在“生成文件和会话托管附件”的局部成立，不构成独立资产工作区；OpenClaw 没有本次指南所定义的完整媒体工作台、历史树或可继续编辑工程。

## 系统边界与完整主链

### 系统边界

| 层 | OpenClaw 中的承担者 | 观察到的职责 |
|---|---|---|
| 创作入口 | Agent 工具工厂与三个媒体生成工具 | 根据工具策略、插件能力、配置和认证状态决定是否把生成工具加入当前 Agent；普通聊天由 Agent 决定是否调用 |
| 能力目录 | `media-generation` registry、插件 manifest、媒体生成 core catalog | 以 `imageGenerationProviders`、`videoGenerationProviders`、`musicGenerationProviders` 分开注册；静态合成 Provider/model 能力项 |
| 任务事实源 | 通用 Task Registry 的 `task_runs` 与 `task_delivery_state` | 媒体任务使用 `runtime: "cli"`，另存任务类型、来源、请求会话、拥有者、运行 ID、状态、进度和结果投递状态 |
| Provider 执行 | 各 Provider 插件与图片/视频/音乐 runtime | Core 负责候选选择、认证可用性、能力检查、参数归一化和 fallback；外部模型、ComfyUI 或本地服务负责实际生成 |
| 结果存储 | media store、managed outgoing media、session transcript | 生成 buffer 先存到工具专用目录；可见回复阶段再复制或引用到 `outgoing/originals`，记录与 transcript message 绑定 |
| Agent 回流 | detached media lifecycle、internal event、requester session | 完成或失败后把结构化媒体附件和内部事件送回原请求会话，由正常可见回复契约收口 |
| 客户端访问 | `artifacts.list/get/download`、Gateway HTTP、Control UI | 按 session、run 或 task 解析作用域；托管媒体通过短期 ticket URL、范围请求和缩略图/播放路径访问 |

### 完整主链

以下链路是根据源码执行关系整理的推断，具体步骤均有相邻源码事实支撑：

```text
用户需求进入 Agent 回合
  -> createOpenClawTools 根据策略、Provider 能力和认证状态加入 image_generate/video_generate/music_generate
  -> Agent 调用 action="generate"，提供 prompt、模型、参数和参考素材
  -> 工具解析本地路径、data URL 或远程 URL，执行 sandbox、文件类型、大小和 SSRF 约束
  -> 选择 Provider/model 候选，按能力归一化参数并建立 requestKey
  -> session-backed 调用创建 runtime=cli 的媒体 TaskRecord
  -> 返回 taskId/runId 和“等待完成事件”的即时结果，后台 scheduler 执行 Provider runtime
  -> Provider 生成、轮询或下载结果；Core 检查非空输出并记录进度
  -> saveMediaBuffer 写入 tool-image-generation、tool-video-generation 或 tool-music-generation
  -> completion wake 携带结构化附件、媒体路径/URL 和内部回复指令回到 requester session
  -> Agent 生成短说明和媒体可见回复
  -> Gateway createManagedOutgoingMediaBlocks 保存 outgoing/originals、写 managed media record
  -> Session transcript 记录媒体 block；artifacts.list/get/download 与 Control UI 按会话/任务提供预览或下载
```

`agentSessionKey` 缺失时，工具走同一生成 runtime 的 inline 路径，不建立会话后台任务；精确 cron run 只有在可读取的 continuation/CLI binding 足够时才允许分离运行。这说明“异步任务”是会话与生命周期条件下的产品路径，不是所有 Provider 调用的统一外部 Job API。入口和分离条件见 `src/agents/openclaw-tools.ts`、`src/agents/tools/media-generate-background-shared.ts`、`src/agents/tools/media-generate-background.ts`。

## 1. 创作入口、触发者与事实对象

**入口和触发者。** 源码事实是 Agent 工具工厂显式构造三个生成工具，并把它们与 `tts`、`nodes`、`image` 等其他工具分开装配；工具是否出现由插件启用状态、Provider 能力、模型配置、认证和 allow/deny 策略共同决定。工具描述明确告诉 Agent：会话聊天中的媒体生成在后台运行，调用一次后等待完成事件，再提交可见回复。入口与装配见 `src/agents/core-tool-factory-descriptors.ts`、`src/agents/openclaw-tools.ts`、`src/agents/tools/media-tool-shared.ts`。

用户主要通过聊天提出需求，Agent 是直接触发者；cron 运行的 Agent 回合也可以使用同一工具。Provider 插件、ComfyUI、OpenAI、Google、fal 等属于执行后端，不是独立的 OpenClaw 媒体工作台入口。文档把这些能力描述为 tool-driven，并说明工具在有 backing Provider 时才出现，这是文档声明，见 `docs/tools/media-overview.md`；本次未找到独立的 `/image`、`/video` 媒体创作页面或媒体画廊路由。

**事实对象分层。** 当前快照中可以确认以下对象，但它们的产品含义不同：

| 对象 | 保存内容 | 在媒体创作中的作用 |
|---|---|---|
| Provider/model 能力项 | Provider ID、别名、默认模型、模型列表、模式和能力 | 决定入口可见性、模型解析、参数检查和 fallback，不是一次创作记录 |
| 媒体任务记录 | `taskId`、`runId`、`taskKind`、`sourceId`、请求会话、拥有者、prompt、状态、时间、进度、错误和投递状态 | 一次 session-backed 生成的生命周期身份；图片、视频、音乐分别使用 `image_generation`、`video_generation`、`music_generation` |
| 生成媒体文件 | UUID-backed media ID、文件路径、MIME、大小、可选原始文件名 | Provider 输出和后续回复准备阶段的文件事实源 |
| managed outgoing media record | `attachmentId`、sessionKey、messageId、retentionClass、媒体类型、尺寸/时长/文件信息 | 将可见回复中的媒体与消息和会话绑定，并为 Artifact 下载提供受控访问 |
| transcript artifact | session transcript 中的媒体 block、Artifact ID、task/run provenance、下载模式 | 客户端和 Gateway 的读取投影，不是独立媒体编辑工程 |

媒体任务没有独立的通用任务表：本次快照未找到任务注册表模块与任务 SQLite store，任务状态由会话 async-task 投影与媒体任务状态模块承担，状态词与终态语义需按这两个模块核对（`src/agents/media-generation-task-status.ts`、`src/agents/session-async-task-status.ts`）。媒体生命周期在创建任务时传入任务类型、Provider、prompt 和请求者身份；完整参数更多保留在即时工具结果、最终媒体详情和 transcript 投影中，因此单个任务状态不能等同于一棵完整的媒体创作历史树。

本次在图片、视频、音乐生成模块、媒体任务模块、Gateway managed media 和 Artifact RPC 范围内**未找到**独立的媒体历史树、版本对象、项目对象、跨会话资产库或媒体工程 DAG。Comfy 的 workflow JSON、`promptId` 和输出节点 ID 是 Provider 配置或一次 Provider 结果的元数据，不是 OpenClaw 媒体工程身份，见 `extensions/comfy/workflow-runtime.ts`。

## 2. 参数、素材与模型/渲染执行

### 参数与参考素材

三个工具有独立的输入契约，且参数会进入请求去重键、任务详情或最终结果详情：

| 工具 | 主要创作输入 | 参考素材与模式 | 结果控制 |
|---|---|---|---|
| `image_generate` | prompt、model、count、filename、size、aspectRatio、resolution、quality、outputFormat、background、Provider options | `image`/`images`，走图片编辑或 Provider 的 style reference | Provider/model 能力限制输出数量、尺寸、比例、分辨率、格式和背景 |
| `video_generate` | prompt、model、filename、size、aspectRatio、resolution、durationSeconds、audio、watermark、providerOptions | `image`/`images`、`video`/`videos`、`audioRef`/`audioRefs`；角色数组传递 first/last/reference 等语义 | 根据参考输入选择 generate、imageToVideo 或 videoToVideo；按模型归一化时长和几何参数 |
| `music_generate` | prompt、lyrics、instrumental、model、durationSeconds、format、filename | `image`/`images`，用于图片条件的 edit 模式 | Provider 能力决定歌词、器乐、时长和输出格式是否保留 |

工具边界会先清洁参考素材。图片工具最多接受 14 个参考图，视频工具的共享入口上限为 9 个图、4 个视频和 3 个音频，音乐工具最多 10 个参考图；工具层再与 Provider/model 的实际上限取交集。路径、`file://`、`data:` 和 HTTP(S) 输入按工具及 sandbox 条件分别处理，远程素材走 SSRF/大小/超时控制，加载结果会保存已解析输入和可能的重写来源。相关 schema 和执行见 `src/agents/tools/image-generate-tool.ts`、`src/agents/tools/video-generate-tool.ts`、`src/agents/tools/music-generate-tool.ts`、`src/agents/tools/media-tool-shared.ts`。

### 模型能力目录与 Provider 编排

**源码事实。** `src/media-generation/registry.ts` 为图片、音乐、视频建立三个能力 Provider registry；`src/plugins/capability-provider-runtime.ts` 通过 manifest contract 先解析可用插件，再按当前 registry 快照准备能力 Provider。`packages/media-generation-core/src/catalog.ts` 将默认模型、模型列表、模式和能力合成为静态目录项。三个工具的 `action: "list"` 读取该目录，并返回 Provider 配置状态、认证环境变量、模式、能力以及模型级目录信息，见 `src/agents/tools/media-generate-tool-actions-shared.ts`。

**插件族。** 仓库 manifest 声明了多 Provider 的图片、视频、音乐能力，包括 OpenAI、Google、fal、ComfyUI、MiniMax、OpenRouter、DeepInfra、xAI，以及多家视频 Provider；完整能力矩阵由 `docs/tools/media-overview.md` 作文档声明，具体注册来源分散在各 `extensions/*/openclaw.plugin.json`。Comfy 插件是一个清晰的多媒体插件族：同一插件同时注册图片、音乐和视频 Provider，见 `extensions/comfy/openclaw.plugin.json`、`extensions/comfy/index.ts`。

**候选和归一化。** runtime 按显式 `model`、各媒体配置的 primary、fallbacks、再到认证可用的 Provider 默认模型构造候选；显式模型覆盖只尝试指定 Provider/model。图片会按 Provider/model 能力清洁几何、质量、输出格式和背景；视频会先确认模式、参考数量、Provider options 类型、时长上限，再归一化尺寸、比例、分辨率、音频和水印；音乐会清洁歌词、器乐、时长和格式。失败候选保留 Provider/model、错误和原因，全部失败时汇总返回。对应实现见 `src/media-generation/runtime-shared.ts`、`src/image-generation/runtime.ts`、`src/video-generation/runtime.ts`、`src/music-generation/runtime.ts`。

### 执行位置

Core 不负责把任意 HTML、节点图或 FFmpeg 脚本当作 OpenClaw 媒体工程执行。实际生成由 Provider 所有：托管模型走 Provider API，Comfy local 走本地 ComfyUI HTTP 服务，Comfy Cloud 走 Cloud API，其他插件自行实现模型请求和结果下载。以 Comfy 为例，源码加载按能力选择的 workflow JSON，把 prompt 写入指定节点；有参考图时先上传，再 POST `/prompt`，随后轮询本地 `/history` 或云端 `/api/job/.../status`，最后从 `/view` 或 `/api/view` 下载输出，见 `extensions/comfy/workflow-runtime.ts`。这是一条 Provider 适配链，不是 OpenClaw 自有节点编辑器。

视频 Provider 可在插件内部实现外部异步任务。例如 DashScope 兼容适配器提交后取得 `task_id`，轮询 `SUCCEEDED`、`FAILED`、`CANCELED`、`UNKNOWN` 等状态，再下载结果 URL；Core 看到的是一个最终返回 `VideoGenerationResult` 的 Provider 合同，见 `src/video-generation/dashscope-compatible.ts`。文档对各 Provider 的队列、轮询和模式差异有声明，真实 Provider 服务行为本次未运行验证。

## 3. 任务状态、异步回调与取消

### OpenClaw 任务生命周期

Provider 资源现在由预检阶段取得并显式移交给已接纳任务。预检期间资源负责模型目录、认证或 Provider runtime 的一致快照；重复请求、取消或接纳失败会释放资源，只有成功进入前台执行或 detached scheduler 后才转移所有权。后台任务持续持有同一资源直到实际生成与结果持久化完成，避免任务已经排队却在执行前丢失 Provider 生命周期。实现见 `src/agents/tools/media-generate-background.ts`。

session-backed 媒体调用由 `runMediaGenerationTask` 创建运行中的 CLI 任务，任务来源分别记录为 `image_generate:<provider>`、`video_generate:<provider>` 或 `music_generate:<provider>`，并保存请求会话、请求者 Agent、prompt 和 Provider。初始工具结果包含 `async: true`、`status: "started"`、`taskId`、`runId`，之后后台执行器更新“Generating ...”“Saving ...”等进度。实现见 `src/agents/tools/media-generate-background-shared.ts`、`src/agents/tools/media-generate-background.ts`。

媒体完成不是简单的“Provider 返回即任务完成”。成功后台作业先把任务进度改为 `Generated media; delivering completion`，再尝试唤醒请求会话；只有完成事件处理结束后才把任务写成 `succeeded`。失败路径先尝试把错误送回原会话，再记录 `failed`；完成投递未确认时保留 `blocked` 终态语义，避免任务在用户尚未收到媒体时显示为普通成功。该顺序见 `src/agents/tools/media-generate-background-shared.ts` 与完成投递模块 `src/agents/tools/media-generate-background-completion.ts`。

### Provider 异步、轮询与内部回调

OpenClaw 有两类“回调”需要区分：

| 层次 | 已确认行为 |
|---|---|
| Provider 层 | Provider 可自行提交外部 Job 并轮询，或在一次 `generate*` Promise 内完成同步请求；Comfy 和 DashScope 适配路径明确使用轮询，轮询有间隔、deadline、终态错误和响应大小限制 |
| OpenClaw 任务层 | Core 通过后台 scheduler、进度 keepalive 和 `wakeTaskCompletion` 把完成结果转成内部 Agent event；它不是面向 Provider 的通用 webhook 合同 |
| 用户可见层 | requester session 的 Agent 依据内部事件生成可见回复；直接通道投递失败时，任务/媒体投递链仍有 session queue 或受控回退语义 |

本次在 `src/media-generation`、`src/image-generation`、`src/video-generation`、`src/music-generation` 和相关插件注册范围内未找到一个统一的 OpenClaw 媒体 webhook 接口。Provider 的 webhook 或远端回调若存在，属于该 Provider 插件内部实现，不能从公共生成合同推断其统一行为。

### 取消、失败与恢复

- **请求中止。** 参考素材加载和任务接纳前会检查 `AbortSignal`；源码注释明确，任务一旦接纳，生成的付费工作独立于请求者信号，见 `src/agents/tools/image-generate-tool.ts`、`src/agents/tools/video-generate-tool.ts`、`src/agents/tools/music-generate-tool.ts`。
- **任务取消。** 通用任务取消 RPC（`tasks.cancel`）与 `src/tasks/` 任务注册表在本次快照中均未找到，媒体任务没有统一的任务级取消入口；可用的中止路径是会话/tool abort 与运行中止，见 `src/agents/tools/media-generate-background.ts`、`src/agents/media-generation-task-status.ts`。图片、视频、音乐 Provider 请求合同没有统一取消句柄，因此即便插件自身支持取消，也需按 Provider 实现核对，不能从公共合同推断。
- **失败。** Provider 错误、空结果、空 buffer、不可投递视频、参考素材不符合能力、超时和响应超过大小上限都会进入候选失败或任务失败；fallback 会保留每次尝试的诊断。视频轮询还区分未知/过期任务、终态失败和超时，见 `src/video-generation/dashscope-compatible.ts`、`src/image-generation/runtime.ts`、`src/video-generation/runtime.ts`。
- **运行时恢复。** 媒体后台任务的状态由会话 async-task 投影与媒体任务状态模块表达（`src/agents/session-async-task-status.ts`、`src/agents/media-generation-task-status.ts`），本次未找到通用任务注册表（`src/tasks/` 已不存在）、固定保留期或 `lost` 标记逻辑，也未找到媒体任务在 Gateway 重启后继续轮询或重新接管 Provider 远端 Job 的实现。因此当前证据只支持“任务状态随会话/运行存在”，不支持“任务跨重启可恢复”。

## 4. 结果、历史、资产与工程持久化

### 生成结果

图片、视频、音乐工具分别把非空 Provider 输出保存到 `tool-image-generation`、`tool-video-generation`、`tool-music-generation` 媒体子目录。文件由 UUID-backed media ID 标识，可保留经净化的原始文件名；按媒体类型使用生成上限，批量保存失败时执行尽力回滚，见 `src/media/store.ts`、`src/agents/tools/generated-media-batch-persistence.ts`。视频结果可以是本地 buffer，也可以保留 Provider URL-only 资产；这解决的是交付形态，不是版本或工程持久化，见 `src/video-generation/types.ts`、`src/agents/tools/video-generate-tool.ts`。

### 托管附件与 Artifact

可见回复到达 Gateway 后，`createManagedOutgoingMediaBlocks` 会把图片、音频或视频存进 `media/outgoing/originals`，写入 managed outgoing media record，并生成带类型的 `artifact_managed_image_*` 或 `artifact_managed_media_*` ID。记录保存 session、可选 message、retention class、MIME、大小、图像尺寸和文件名；有 message 时从 transient 提升为 history。实现见 `src/gateway/managed-image-attachments.ts`、`src/gateway/managed-image-record-store.ts`。

`artifacts.list`、`artifacts.get`、`artifacts.download` 默认扫描 session transcript，并可以用 sessionKey、runId 或 taskId 解析范围；task 查询会先读取任务的 requester session 和 Agent 归属，再只返回带相同任务 provenance 的 transcript 媒体。managed media 下载会再次检查 session、Agent、transcript 关联和文件存在性，返回短期 ticket URL，见 `src/gateway/server-methods/artifacts.ts`、`src/gateway/server-methods/artifacts-session-resolution.ts`。

因此这里有“会话托管的媒体 Artifact”，但没有“跨会话可浏览的媒体资产库”。Artifact ID 的稳定性服务于 transcript 和客户端下载；它不是可编辑的媒体项目 ID。managed record 的清理也依赖 message/transcript 仍然引用该附件，或 transient 的时间与活跃任务条件，见 `src/gateway/managed-image-attachments.ts`。

### 历史、命名、去重与工程

- **任务历史：部分确认。** `task_runs` 保存一次任务的 prompt、状态、时间和投递信息，并可由 `tasks.list/get` 查询；媒体任务的完整生成参数主要在工具结果和 transcript 中，没有独立的 generation history 表。
- **文件命名：已确认。** media store 用 UUID 作为安全身份，filename 只是显示和扩展名提示；同一内容没有本次可见的内容 hash 资产去重。
- **请求去重：已确认但不是资产去重。** media request key 将 prompt、Provider/model、参考输入和主要参数稳定序列化；同一会话中活动任务或短时间内相同成功请求会触发 duplicate guard，区别请求可以并行启动，见 `src/agents/media-generation-task-status-shared.ts`。这防止重复调用，不建立可导航的版本关系。
- **历史树/分支：未找到。** 通用 session transcript 有自己的会话和消息历史语义，但在本次媒体生成范围内没有媒体结果之间的 parent、version、branch 或 generation graph 字段。
- **媒体工程：未找到。** 没有 OpenClaw-owned 的节点图、时间线、可编辑 project file 或媒体工程持久化对象。Comfy workflow JSON 仍由 Provider 配置指向或内嵌，输出元数据不会把它提升为 OpenClaw 项目。

## 5. 预览、编辑、重试、分支与复用

**预览和导出。** Agent 结果先以 `AgentGeneratedAttachment` 携带类型、路径/URL、MIME、文件名、尺寸和时长等信息；Gateway 再转成 transcript 中的 managed block。Control UI 和客户端可用 Artifact RPC 获取摘要或短期下载地址，图片有全图/缩略图路径，音频和视频有 `Range`、`ETag`、`HEAD` 和播放/下载处理。源码事实见 `src/agents/generated-attachments.ts`、`src/gateway/managed-image-attachments.ts`；播放器和 lazy FFmpeg rendition 是消费侧机制，文档说明见 `docs/nodes/media-playback.md`，不计为媒体创作工作台。

**编辑和继续创作。** 生成工具支持“带参考输入的下一次生成”：图片是 reference-image edit，视频是 image-to-video/video-to-video，音乐是 image-conditioned edit。它们是 Provider 生成模式，不是对已保存 Artifact 的像素编辑、时间线剪辑或节点图编辑。Comfy 的 workflow 可以由外部配置修改，但 OpenClaw 只注入 prompt/参考图并读取指定输出节点，源码没有针对已生成结果打开编辑工程的入口。

**重试。** Core 在一次调用内按候选 Provider/model 做自动 fallback；任务失败后，Agent 可以再次调用对应工具形成新的生成请求。工具 action 只有 `generate`、`status`、`list`，本次未找到媒体专用 `retry` action。相同 prompt/request 在活动期间会返回现有任务状态，最近成功的完全相同请求也会在短期 duplicate guard 窗口内被拦截；修改 prompt、参考素材或参数可形成不同请求。本次也未找到通用 `tasks.retry` RPC（`src/gateway/server-methods/tasks.ts` 已不存在）；面向阻塞 completion 投递的重试路径需在 delivery 相关模块单独核对。相关入口见 `src/agents/tools/media-tool-shared.ts`、`src/agents/tools/media-generate-tool-actions-shared.ts`。

**分支和复用。** 没有媒体专用分支树或版本浏览。下一次创作可以把上一次结果暴露的本地路径或 URL 重新作为参考输入，也可以重新使用模型配置和 Provider fallback；这种复用由 Agent 再次填充工具参数完成，未形成跨任务的资产引用边。Artifact 下载地址则是短期访问能力，不应被视为永久创作输入身份。

## 6. Agent 回流、插件与外部依赖

### Agent 回流

媒体工具的 Agent 回流是本快照中最完整的产品闭环部分。后台 completion event 保存 `eventSource`、任务会话、任务 ID、状态、结果文本、结构化附件、媒体路径和 `replyInstruction`；`wakeTaskCompletion` 把事件交给 requester session 的 announce/delivery 路径，要求原 Agent 产生短的用户可见说明并带上全部结构化媒体。实现见 `src/agents/tools/media-generate-background-shared.ts`。

工具说明和返回文本也参与 Agent 契约：初始结果明确给出 task ID，并要求不要为同一请求再次调用，等待完成事件；成功事件要求把附件送入当前可见回复，失败事件要求输出简短失败信息。因而媒体能力不是只有模型端“知道某个 API”，还能回到原会话形成 Agent 执行链，见 `src/agents/tools/media-generate-background-shared.ts`、`src/agents/tools/image-generate-tool.ts`、`src/agents/tools/video-generate-tool.ts`、`src/agents/tools/music-generate-tool.ts`。

当原 session 需要通过 Gateway/消息工具发送时，完成事件保留 requester origin 和会话归属；正常 Agent 回流失败时，任务 delivery 层可以进入 session queue 或按媒体缺失情况使用受控的直接回退。文档明确声明了“唤醒原会话、失败时只补发尚未送达的媒体”的行为，见 `docs/tools/media-overview.md`、`docs/automation/tasks.md`；本次没有运行真实频道和重启场景验证这一声明。

Agent 可以通过生成工具的 `action: "list"` 发现当前 Provider/model/能力，通过 `action: "status"` 查看本会话活动任务，也可以通过通用 `tasks.list/get` 查询任务账本，并从 completion event 得到结果路径、URL 和结构化附件。本次未找到让 Agent 直接浏览媒体历史树、跨会话资产索引、版本关系或已保存 Artifact 编辑状态的专用 API；再次创作依赖 Agent 将已有路径/URL 重新填入生成工具。

### 插件边界

插件以 manifest 先声明 `contracts`、Provider 认证和能力元数据，runtime 再按当前配置和 registry 快照加载具体实现。Provider 专属认证、API URL、模型目录、请求格式和响应解析留在插件中；Core 统一负责 Provider 发现、候选顺序、能力过滤、fallback、结果合同和 Agent 工具装配。这一边界由 `src/plugins/capability-provider-runtime.ts`、`src/media-generation/provider-registry.ts` 体现。

Comfy 插件同时覆盖 image/music/video 三个能力，但它仍然只是统一 Provider 适配，不是统一的媒体项目编排器。fal manifest 的 `referenceAudioInputs` 等字段只用于决定视频工具是否暴露参考音频参数，见 `extensions/fal/openclaw.plugin.json:32-40`、`src/agents/tools/video-generate-tool.ts`。OpenAI 等插件的 manifest 也只是声明能力、认证信号和模型相关目录，不创建独立媒体历史对象，见 `extensions/openai/openclaw.plugin.json`。

### 外部依赖与边界

| 依赖 | 进入主链的位置 | 本次确认的边界 |
|---|---|---|
| 外部图像/视频/音乐模型 | Provider `generateImage/generateVideo/generateMusic` | 认证、真实模型队列、计费、输出质量由外部服务或 Provider 插件负责 |
| ComfyUI local/cloud | workflow load、输入图上传、prompt、history/status、view/download | local/private network 受配置和 SSRF policy 约束；workflow JSON 是外部/配置输入 |
| 本地文件与 media store | 参考素材加载、生成结果保存、managed outgoing originals | 路径必须通过工具本地根、sandbox 或 Gateway local-media policy；文件有每类大小上限 |
| Gateway SQLite | task registry、managed outgoing image/media record | 记录任务和会话托管附件；不保存媒体工程 DAG 或跨会话资产索引 |
| Control UI/Artifact RPC | 结果摘要、短期 URL、缩略图、播放/下载 | 这是结果访问和消息投影，不是独立创作工作台 |
| TTS、媒体理解、节点相机/录屏 | 回复语音、入站附件理解、设备采集 | 支撑能力各有 Provider/节点/文件路径链，但本次不计入媒体生成主贡献 |

### 边界样本与不适用结论

- **媒体理解：不适用。** `runCapability` 的入口是入站图片、音频、视频附件，Provider/CLI 输出的是描述或转写文本，随后写入 `MsgContext.Body`、`Transcript` 和理解决策；它处理用户已经拥有的素材，不创建媒体生成任务、生成结果历史或可编辑资产。本次仅核对附件选择、Provider/CLI fallback、失败 disposition 和上下文回写，见 `src/media-understanding/runner.ts`、`src/media-understanding/apply.ts`。
- **TTS：不适用。** `textToSpeechCore` 同步调用语音 Provider，按频道选择 audio-file 或 voice-note 目标，再由 `tts-audio-store` 写入 `tool-speech-synthesis`；没有媒体创作任务、提示词/参考素材历史、版本或编辑入口。本次仅核对合成、转码、文件保存和频道投递边界，见 `src/tts/tts-synthesis.ts`、`src/tts/tts-audio-store.ts:1-23`。
- **节点相机/录屏：入口确认，但不适用。** `nodes` 工具暴露 `camera_snap`、`camera_clip`、`screen_record`、`screen_snapshot` 等设备动作；相机和屏幕代码负责验证节点返回的 base64/HTTPS URL、写入临时文件和施加大小/时长边界，没有模型生成、独立媒体任务、创作历史或继续编辑契约。本次仅核对节点动作清单、载荷校验、节点权限/命令边界和临时输出文件，见 `src/agents/tools/nodes-tool.ts`、`src/cli/nodes-camera.ts`、`src/cli/nodes-screen.ts`。
- **普通附件、播放器和 Artifact 服务：支撑能力，不单独准入。** Gateway managed outgoing media、`artifacts.*`、缩略图、Range/ETag、lazy playback rendition 负责把已经产生并写入 transcript 的媒体安全地保存、展示、下载或播放；它们没有生成提示词、模型执行或媒体编辑历史。本次将其作为生成结果的交付和复用支撑检查，未把普通附件、播放器或通用 FFmpeg 路径计作媒体创作能力，见 `src/gateway/managed-image-attachments.ts`、`src/gateway/server-methods/artifacts.ts`、`docs/nodes/media-playback.md`。

## 7. 权限、资源边界与失败恢复

**工具可见性和配置。** 生成工具受 `tools.allow`、`tools.deny`、插件启用状态、媒体 Provider manifest 和认证状态共同控制；显式媒体模型配置可以使工具保留，未配置模型则依赖认证可用的 Provider 默认值。全局禁用插件会关闭这些可选生成工具，见 `src/agents/openclaw-tools.media-factory-plan.ts`。媒体模型默认配置位于 `agents.defaults.mediaModels.image/video/music`，见 `src/config/types.agent-defaults.ts`；文档给出的配置与 Provider 顺序是文档声明，见 `docs/tools/image-generation.md`、`docs/tools/video-generation.md`。

**文件、网络与会话作用域。** 参考素材加载会区分 workspace/local roots、sandbox bridge、media store URI 和远程 URL；sandbox 默认拒绝远程参考 URL，远程读取使用 SSRF policy，Provider 也可以进一步限制只能使用 HTTPS URL。Comfy local 请求将 base URL hostname 纳入网络策略，cloud mode 的 private network 需要显式配置，见 `src/agents/tools/media-tool-shared.ts`、`extensions/comfy/workflow-runtime.ts`。生成结果进入 Gateway 时，managed record、session transcript、Artifact query 和短期 ticket 共同限制访问范围；`artifacts.*` 的方法由 `operator.read` 描述，见 `src/gateway/methods/core-descriptors.ts`。

**资源与时间上限。** 工具层限制图片数量、参考文件数量和正整数 timeout；Provider 能力继续限制输出数量、尺寸、模式、时长和参数。生成结果写入时遵循 `agents.defaults.mediaMaxMb` 或媒体类型默认上限，Gateway managed image 默认限制为 12 MiB，音频/视频使用各自媒体上限；视频 Provider 的提交、轮询、下载响应也有独立 body byte cap 和 operation deadline。相关源码见 `src/media/configured-max-bytes.ts`、`src/gateway/managed-image-attachments.ts`、`src/video-generation/dashscope-compatible.ts`；具体默认值的跨客户端说明见 `docs/nodes/media-playback.md`。

**失败收口与清理。** 生成批次保存失败会删除已经成功保存的同批文件；任务投递阶段会记录失败或 blocked 结果；managed outgoing cleanup 在 transcript 不再引用附件、transient 超时或会话删除条件满足时回收 record 和原文件。本次未找到通用任务 maintenance、`lost` 标记与保留期清理模块，媒体侧可确认的清理只有批次回滚与 managed outgoing cleanup。源码事实见 `src/agents/tools/generated-media-batch-persistence.ts`、`src/gateway/managed-image-attachments.ts`。

## 8. 设计取舍、已确认边界与未验证事项

### 设计取舍与已确认边界

- **工具优先而非工作台优先。** OpenClaw 把媒体创作嵌入 Agent 工具面，统一了 Provider 发现、能力过滤和结果回流，但没有引入一个独立的媒体编辑页面、媒体历史树或项目模型。
- **通用任务账本承载媒体异步。** 图片、视频、音乐共用 detached task lifecycle 和 Task Registry，差异通过 `taskKind`、`sourceId`、标签、进度和 completion event source 表达；任务账本同时服务 ACP、subagent、cron 和 CLI，因此它是通用活动记录，不是媒体专用历史模型。
- **执行与可见投递分离。** 任务在完成事件被原 Agent 接收前保持投递中的进度，生成成功但回流失败可以被记录为 blocked 或进入回退路径；这保证了“Provider 已完成”和“用户已收到”不被混为一谈。
- **Provider 适配保留专属能力。** 能力目录允许图片编辑、视频多模式、参考音频、模型级上限和 Provider options，但 Core 不把这些差异提升成一个统一的媒体工程语言；Comfy workflow 仍由 Provider 配置掌握。
- **资产语义是 transcript-backed。** 生成文件和 managed outgoing record 提供稳定 Artifact 身份、下载权限和清理语义，方便消息和客户端消费；本次未找到跨会话资产搜索、内容去重、版本比较或资产拖拽复用契约。
- **本次未找到的能力不能写成项目级绝对否定。** 结论只覆盖本节列出的源码、manifest、Gateway、任务和文档检查范围；其他未读的外部插件包或未来 Provider 不在结论中。

### 未验证事项

- 未运行图片、视频、音乐生成测试，也未调用真实 OpenAI、Google、fal、ComfyUI 或其他 Provider；Provider 真实队列时序、响应格式、计费和输出质量未验证。
- 未启动独立 Gateway、Control UI 或真实频道；任务事件到可见消息、managed outgoing record、Artifact ticket 和客户端预览的端到端行为未运行验证。
- 已接纳媒体任务在 `tasks.cancel` 后是否仍继续消耗 Provider 资源，以及任务取消与后续 completion wake 的竞态，源码显示没有统一 Provider abort 合同，但本次未运行验证具体 Provider 行为。
- Gateway 重启、Provider 远端任务仍存在、任务 registry 恢复后是否能重新接管轮询，未找到媒体专用 recovery 实现，也未做实际重启实验。
- 生成文件、managed outgoing record、transcript 引用和任务保留期的并发清理未做压力或故障注入验证。
- Control UI 的图片缩略图、音频/视频播放、下载、Artifact 过期重取，以及桌面/移动端布局、键盘可用性和真实视觉效果未验证。
- TTS、媒体理解、相机/录屏节点、播放器和普通附件只核对了入口与边界源码，没有把它们扩展为媒体创作主链；它们的 Provider 实际行为、设备权限和跨平台效果未调查。

## 9. 关键源码索引

- Agent 工具装配与策略：`src/agents/core-tool-factory-descriptors.ts`、`src/agents/openclaw-tools.ts`、`src/agents/openclaw-tools.media-factory-plan.ts`
- 图片生成工具：`src/agents/tools/image-generate-tool.ts`；runtime 与合同：`src/image-generation/runtime.ts`、`src/image-generation/types.ts`
- 视频生成工具：`src/agents/tools/video-generate-tool.ts`；runtime/能力/Provider async：`src/video-generation/runtime.ts`、`src/video-generation/capabilities.ts`、`src/video-generation/dashscope-compatible.ts`
- 音乐生成工具：`src/agents/tools/music-generate-tool.ts`；runtime 与合同：`src/music-generation/runtime.ts`、`src/music-generation/types.ts`
- 媒体 Provider registry/catalog：`src/media-generation/registry.ts`、`src/media-generation/provider-registry.ts`、`src/media-generation/runtime-shared.ts`、`packages/media-generation-core/src/catalog.ts`、`src/plugins/capability-provider-runtime.ts`
- 插件族与 Comfy workflow：`extensions/comfy/openclaw.plugin.json`、`extensions/comfy/index.ts`、`extensions/comfy/workflow-runtime.ts`；其他能力 manifest 示例：`extensions/fal/openclaw.plugin.json:32-40`、`extensions/openai/openclaw.plugin.json`
- 媒体任务生命周期与 Agent 回流：`src/agents/tools/media-generate-background.ts`、`src/agents/tools/media-generate-background-shared.ts`、`src/agents/media-generation-task-status.ts`、`src/agents/media-generation-task-status-shared.ts`
- 媒体任务状态与完成投递：`src/agents/media-generation-task-status.ts`、`src/agents/media-generation-task-status-shared.ts`、`src/agents/session-async-task-status.ts`、`src/agents/tools/media-generate-background-completion.ts`
- 媒体文件与托管附件：`src/media/store.ts`、`src/gateway/managed-image-record-store.ts`、`src/gateway/managed-image-attachments.ts`
- Artifact 与 Gateway 访问：`src/gateway/server-methods/artifacts.ts`、`src/gateway/server-methods/artifacts-session-resolution.ts`、`src/gateway/methods/core-descriptors.ts`
- 明确排除的支撑能力：`src/media-understanding/runner.ts`、`src/media-understanding/apply.ts`、`src/tts/tts-synthesis.ts`、`src/agents/tools/nodes-tool.ts`、`src/cli/nodes-camera.ts`、`src/cli/nodes-screen.ts`
- 文档声明对照：`docs/tools/media-overview.md`、`docs/tools/image-generation.md`、`docs/tools/video-generation.md`、`docs/automation/tasks.md`、`docs/gateway/clients.md`、`docs/nodes/media-playback.md`
