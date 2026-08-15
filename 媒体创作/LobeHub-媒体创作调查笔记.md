# LobeHub 媒体创作调查笔记

> 调查对象：`E:\works\GitStudyNotes\lobehub`（Next.js 16 SPA + Hono/tRPC 服务端 + Drizzle/PostgreSQL，另含 Electron 桌面目标）
>
> 调查更新日期：2026-08-14
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：静态源码走读（只读，未修改仓库）；与独特功能笔记快照比对（HEAD 一致）；零依赖验证仅限 `node -e` 解析 5 个 package.json（全部通过）与 `git status` 工作树核对（0 改动）；未安装依赖、未运行测试、未启动应用（Next.js 应用在无模型/无 DB/S3 环境下 dev 跑不通）
>
> 调查范围：`(create)/image` 与 `/video` 路由族媒体创作主链（能力分型 M1 模型生成工作站 + M3 资产/记录生命周期，含 M5 边界）：入口与触发者、topic/batch/generation 三层事实对象、参数/参考图/模型执行、lambda/async 双路由与轮询、webhook 与后台轮询、结果/历史/资产持久化、预览/复用/重试、Agent 工具回流、workspace 权限与限额。聊天 Agent 工具执行机制、消息渲染与模型 provider 内部实现只做交接引用；独特功能笔记已覆盖的 Schedule/Memory/Brief/Work 等能力不在本页范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 有一条完整的图像 + 视频生成工作链，能力分型为 **M1 模型生成工作站 + M3 记录/资产生命周期**：单一工作台按 `generationTopics → generationBatches → generations` 三层持久化每次创作，`generations` 再挂 `asyncTasks`（任务状态/错误/预扣句柄）与 `files`（S3 资产行）；资产行以 `FileSource.ImageGeneration|VideoGeneration` 标记来源，`asset` jsonb 保存 URL/尺寸/时长。执行分 lambda（提交、事务建行）与 async（实际模型调用）双路由，视频另有 webhook 与后台轮询两条完成路径；客户端以 SWR 指数退避轮询任务终态。

媒体创作视角下三个关键机制（独特功能笔记均未展开）：

1. **三层对象 + 封面回写**：topic（LLM 生成标题、封面、workspace 可见性）→ batch（provider/model/prompt/width/height/config jsonb，即"复用设置"的来源）→ generation（seed、asset、fileId、asyncTaskId）。生成成功后若 topic 尚无封面，客户端自动把首张缩略图经 `updateTopicCover` 回写为 topic 封面（`src/store/image/slices/generationBatch/action.ts:280-292`）。
2. **lambda/async 双路由 + 双完成路径**：`image.createImage` 在事务里建 batch+N 个 generation+N 个 asyncTask 后 fire-and-forget 触发 `asyncCaller.image.createImage`（`apps/server/src/routers/lambda/image/index.ts:215-332`），真正调模型在 async 路由（`apps/server/src/routers/async/image.ts`）；视频由 lambda 直接调 `modelRuntime.createVideo`，按 provider 返回分 webhook 等待（`src/app/(backend)/api/webhooks/video/[provider]/route.ts`，一次性 token 校验）与 `after()` 后台轮询（`apps/server/src/services/generation/videoBackgroundPolling.ts`，5s 固定间隔 × 120 次）两条路径收口。
3. **Agent 创作通道**：`builtin-tool-image-generation` 是唯一的“结果进聊天”回流：Agent 可发现图像模型与参数 schema、发起生成并查询任务状态（4 个 API，见第 6 节），`humanIntervention: 'never'`，默认在工具内等待完成，结果以 markdown 图片标签 + 专用渲染组件进消息（`packages/builtin-tool-image-generation/src/manifest.ts`、`ExecutionRuntime/index.ts:441-587`）。

已确认边界：OSS 快照中计费/通知为闭源占位（`ENABLE_BUSINESS_FEATURES=false`，charge*/notify* 均为 no-op stub），工作台生成结果与聊天会话之间**未找到** sendToChat 类回流入口；`recreateImage/recreateVideo` store 动作存在但**本次未找到 UI 调用点**；`apps/server/src/routers/async/video.ts`（异步轮询变体）注册在 asyncRouter 但**本次未找到生产调用者**。全部结论为静态源码事实；真实模型调用、S3/PostgreSQL/Redis、webhook 网络行为与 UI 视觉效果未运行验证。

## 系统边界与完整主链

### 边界

| 层 | 承担者 | 证据 |
|---|---|---|
| 创作入口 | `/image`、`/video` 路由族（个人与 `/:workspaceSlug/*` 双形态） | `src/spa/router/desktopRouter.shared.tsx:672-711`、`src/routes/(main)/(create)/features/CreateGenerationPage.tsx:43-44` |
| 事实对象 | `generation_topics` / `generation_batches` / `generations` 三表 + `asyncTasks` + `files` | `packages/database/src/schemas/generation.ts`、relations `:325-362` |
| 提交/任务执行 | lambda 路由（事务建行、触发 async）；async 路由（调模型）；视频 webhook 路由（Next.js route） | `routers/lambda/{image,video,generationTopic,generationBatch,generation}/index.ts`、`routers/async/{image,video}.ts`、`src/app/(backend)/api/webhooks/video/[provider]/route.ts` |
| 结果加工 | GenerationService（sharp 缩略图/封面）、VideoGenerationService（ffmpeg-static 元数据/截图）、FileService（S3） | `apps/server/src/services/generation/{index,video,videoBackgroundPolling,latency}.ts` |
| 持久化 | PostgreSQL（Drizzle）；资产 blob 在 S3/OSS，`files.fileHash → globalFiles.hashId` 全局去重 | `packages/database/src/models/{generationTopic,generationBatch,generation,asyncTask,file}.ts` |
| 客户端状态/轮询 | zustand 双 store（image/video 各四 slice）+ SWR 指数退避轮询 | `src/store/image/slices/*`、`src/store/video/slices/*` |
| Agent 通道 | `builtin-tool-image-generation`（client/server 双 executor 共用同一 ExecutionRuntime） | `packages/builtin-tool-image-generation/src/`、`apps/server/src/services/toolExecution/serverRuntimes/imageGeneration.ts` |

### 完整主链（静态走通）

```text
侧栏/命令菜单/`/image`、`/video` 路由（个人或 /:workspaceSlug 镜像）
  -> PromptInput：GenerationMediaModeSegment 切换 image/video
       -> ModelSwitchPanel 模型目录（aiInfra enabledImageModelList / enabledVideoModelList，model-bank parameters schema 驱动）
       -> ConfigAction 参数面板（quality/resolution/size/dimension/steps/cfg/seed/watermark/promptExtend/webSearch；视频另加 aspectRatio/duration/cameraFixed/generateAudio/endImageUrl）
       -> 参考图上传：useFileStore.uploadWithProgress（S3）-> imageUrl/imageUrls/endImageUrl 写入参数
       -> GenerationVisibilitySelector（新 topic 的 private/public）+ Generate
  -> createImage / createVideo（store action）
       -> 无 topic 时先 createGenerationTopic：optimistic 建行 + LLM 生成标题（chainSummaryGenerationTitle，失败回退首词截断）
  -> lambda image.createVideo / image.createImage
       -> resolveBusinessModelMapping + isLobeHubModelAvailable（品牌 provider 弃用模型拦截）
       -> 参考图 URL -> S3 key 归一化存 config jsonb（validateNoUrlsInConfig 防全 URL 入库）
       -> 事务：batch + N generations（'seed' in params 时 generateUniqueSeeds 逐张唯一）+ N asyncTasks（metadata.precharge）
       -> fire-and-forget asyncCaller.image.createImage（每 generation 一个 asyncTask）
  -> async image.createImage：initModelRuntimeFromDB -> modelRuntime.createImage
       -> transformImageForGeneration（sharp 512 上限缩略图 _thumb.webp）-> uploadImageForGeneration（S3 key: generations/images/<uuid>_<WxH>_<ts>_raw|thumb）
       -> createAssetAndFile（asset jsonb + files 行 + fileId）-> asyncTask Success -> notify/charge（OSS stub）
  -> 视频：lambda video.createVideo 调 modelRuntime.createVideo(callbackUrl=.../api/webhooks/video/:provider?token=)
       -> useWebhook：等待 webhook（token timingSafeEqual 校验、终态幂等、错误退款）
       -> 否则 after() 调 processBackgroundVideoPolling（5s×120 次 handlePollVideoStatus）
       -> 成功：VideoGenerationService.processVideoForGeneration（下载<=500MB/5min -> ffmpeg 元数据 + 0.1s 截图 -> cover/thumb webp -> S3）
       -> createAssetAndFile（url/coverUrl/thumbnailUrl/duration/width/height）-> Success
  -> 客户端：GenerationFeed 逐 generation SWR 轮询 getGenerationStatus（1s 起、每 5 次翻倍、30s 封顶、错误×2）
       -> 终态 Success 时回写 generation.asset、必要时回写 topic 封面；Error 显示分类错误
  -> 复用：BatchItem 的 reuseSettings（回填配置，image 剔除 seed）/ copyPrompt / deleteBatch；
       GenerationItem 的 download / copySeed（模型支持则 reuseSeed 直接应用）/ delete / copyError；
       topic 列表（grid/list）切换历史、删除、publishToWorkspace / makePrivate（creator-only）
  -> Agent：builtin-tool-image-generation 4 API，生成结果以 markdown 图片标签回流聊天（+ 专用渲染组件 3s 轮询）
```

## 1. 创作入口、触发者与事实对象

**入口与触发者**：用户主导的工作台是主入口——`/image`、`/video` 两条路由（`desktopRouter.shared.tsx:672-711`）共享同一 `(create)` 布局族的页面骨架（目录 `src/routes/(main)/(create)/features/`）。PromptInput 顶部的 `GenerationMediaModeSegment` 负责 image/video 切换（`GenerationMediaModeSegment.tsx:104-110`）。URL 深链：`?topic=` 定位历史 topic，`?model=&prompt=` 自动生成（`image/features/PromptInput/index.tsx:187-267`，含模型未就绪防误触发的守卫注释）；全局命令菜单可搜索 image/video 历史 topic（`src/features/CommandMenu/SearchResults.tsx:68-71`）。第二个触发者是聊天内 Agent：`builtin-tool-image-generation` 工具（见第 6 节）。未找到插件、定时任务或外部服务触发入口；`notifyImageCompleted`/`notifyVideoCompleted` 钩子存在但为空实现（`packages/business-server/src/image-generation/notifyImageCompleted.ts:12`、`video-generation/notifyVideoCompleted.ts:11`）。

**核心事实对象**——三层 + 两个关联对象（`packages/database/src/schemas/generation.ts`、relations `:325-362`）：

- `generationTopics`（`:16-54`）：userId/workspaceId、`title`（LLM 生成）、`coverUrl`（S3 key）、`type: 'image'|'video'`、`visibility: private|public`（工作区内，personal 模式忽略）。关系：`batches: many`。
- `generationBatches`（`:64-109`）：一次请求的配置——provider/model/prompt/width/height/ratio/`config jsonb`（不索引的通用设置，参考图 key 也存这里）；关系：topic 一对多、generations 一对多。
- `generations`（`:122-161`）：`seed`、`asset jsonb<GenerationAsset>`（url/thumbnailUrl/originalUrl/coverUrl/width/height/duration）、`asyncTaskId`（set null）、`fileId`（文件删除时级联删 generation）。
- `asyncTasks`：任务状态机（Pending/Processing/Success/Error）、error、duration、`metadata`（precharge 句柄、视频 webhookToken、inferenceId）；`checkTimeoutTasks` 兜底超时（`packages/database/src/models/asyncTask.ts:253-289`，超时阈值 `ASYNC_TASK_TIMEOUT = 298s`，`packages/business/config/src/server/route.ts:2`）。
- `files`（+ `globalFiles`）：资产行与按 hash 去重的 blob 元数据（`packages/database/src/models/file.ts:86-141`）。

前端类型 `GenerationBatch`（含 creator/avgLatencyMs）与 `Generation`（含 task{id,status,error}）在 `packages/types/src/generation/index.ts:79-104`。

## 2. 参数、素材与模型/渲染执行

**模型能力目录**：

- **来源**：`aiProviderSelectors.enabledImageModelList`/`enabledVideoModelList`（`src/store/aiInfra`）按 provider 分组提供已启用模型
- **schema**：每个模型的 `parameters` 来自 model-bank 标准参数——图像 `RuntimeImageGenParams`（`standard-parameters/index.ts:280-289`）、视频 `RuntimeVideoGenParams`（`video.ts:191-194`）；UI 按 schema 渲染参数控件，读取默认值/上下界/枚举（`useGenerationConfigParam`，`generationConfig/hooks.ts`）
- **参数迁移**：模型切换时 `generationConfig` slice 经 `setModelAndProviderOnSelect` 用 `extractDefaultValues` 与 `preserveSupportedParams` 保留 prompt/参考图、丢弃不支持的参数（`generationConfig/action.ts:287-321`、`preserveSupportedParams.ts`）

**参数进入请求**：image 与 video 的提交 schema（`apps/server/src/routers/lambda/image/index.ts:50-66`、`routers/lambda/video/index.ts:60-77`）都是“topicId + model/provider + 宽松 params 透传”结构——image 含 `params{prompt,cfg?,height?,width?,steps?,seed?,imageUrls?,...passthrough}` 等字段，video 含 `params{aspectRatio?,cameraFixed?,duration?,endImageUrl?,generateAudio?,imageUrl?,prompt,resolution?,seed?,...passthrough}`。参考图（本地上传经 `useFileStore.uploadWithProgress` 上 S3，`(create)/features/GenerationInput/useReferenceImageUpload.ts:92-195`）以 URL 形式进入请求。lambda 侧把 imageUrl/imageUrls/endImageUrl 用 `fileService.getKeyFromFullUrl` 归一化为 S3 key 再入库（避免存过期 presigned URL），并有 `validateNoUrlsInConfig` 防御性校验（`image/index.ts:112-186`、`image/utils.ts`）。开发环境把代理 URL 转回 S3 URL 供 async 任务访问（image `:157-183`、video `:137-165`）。

**执行位置**：

- **图像**：lambda `image.createImage`（`image/index.ts:85-403`）依次完成：
  1. 映射/校验/归一化/预扣（OSS 为空）
  2. 事务建 batch + N generation——`'seed' in params` 时经 `generateUniqueSeeds` 每张唯一 seed，否则 null（`:236-247`）
  3. 建 N asyncTask（`:259-290`）后 fire-and-forget 触发 `asyncCaller.image.createImage`（`:319-332`）

  实际模型调用在 async 路由（`apps/server/src/routers/async/image.ts:81-401`）：
  1. `initModelRuntimeFromDB` 读库中 provider 配置，`modelRuntime.createImage` 实际调用（agent-runtime 统一接口，各 provider 实现为外部依赖）
  2. sharp 加工（`transformImageForGeneration`，512 上限缩略图，`services/generation/index.ts:97-210`）
  3. S3 上传（key 形如 `generations/images/<uuid>_<WxH>_<日期>_raw.<ext>` 与 `_thumb.webp`，`:212-259`）
  4. `createAssetAndFile` 收尾

  ComfyUI provider 额外透传认证头下载图片（`:212-228`）。
- **视频**：lambda `video.createVideo`（`routers/lambda/video/index.ts:81-372`）事务建 batch+generation+asyncTask（webhookToken 放 metadata，`:184-247`），随后 `modelRuntime.createVideo`（`:259-266`）。完成后按响应 `useWebhook` 分流：webhook 型等回调（`src/app/(backend)/api/webhooks/video/[provider]/route.ts`），否则 `after()` 注册 `processBackgroundVideoPolling`（`videoBackgroundPolling.ts:32-142`，5s 间隔 × 120 次 `handlePollVideoStatus`）。

  视频加工在 `VideoGenerationService.processVideoForGeneration`（`services/generation/video.ts:58-163`）：
  1. 下载（500MB/5min 上限，`:166-221`）
  2. ffmpeg-static 提取元数据（duration/尺寸，`:223-256`）
  3. 0.1s 截图（`:261-285`）
  4. cover/thumb webp → S3（key：`generations/videos/...`、`_cover.webp`、`_thumb.webp`）
- **异步变体**：`apps/server/src/routers/async/video.ts` 是同构轮询实现（含 abort 支持），注册于 asyncRouter（`routers/async/index.ts:9-15`），但**本次未找到生产调用者**（grep `asyncCaller.video` 无命中；lambda video 走 webhook/后台轮询）。

**主题标题的 LLM 生成**：`summaryGenerationTopicTitle` 用 `chatService.fetchPresetTaskResult` + `chainSummaryGenerationTitle(prompts, 'image'|'video', lang)` 流式生成标题（`src/store/image/slices/generationTopic/action.ts:74-136`），失败回退"首条 prompt 前 3 词截 20 字符"。

## 3. 任务状态、异步回调与取消

**客户端状态机**：`GenerationItem`（`image/features/GenerationFeed/GenerationItem/index.tsx:22-148`）按 `generation.task.status` 三态渲染 Success/Error/Loading；视频 batch 单 generation，同样三态（`video/features/GenerationFeed/BatchItem.tsx:79-88,201-230`）。每 generation 以 `useCheckGenerationStatus` 发起 SWR 轮询，参数为任务与主题定位信息及轮询开关（`src/store/image/slices/generationBatch/action.ts:193-301`；视频同构 `src/store/video/slices/generationBatch/action.ts:146-240`）。

**轮询策略**：SWR `refreshInterval` 动态计算——基 1s、每 5 次请求翻倍、30s 封顶，轮询出错再 ×2；终态 Success/Error 返回 0 停止（`image/.../generationBatch/action.ts:213-238`）。轮询端点 `lambda generation.getGenerationStatus` 先经 `checkTimeoutTasks` 处理超龄任务（`routers/lambda/generation.ts:65-95`、`models/asyncTask.ts:253-289`）：Pending/Processing 超时被置为 `Error(Timeout)`，即“DB 为权威”的收口。终态回写：Success 更新 generation（含 asset）并触发 topic 封面回写（`:280-292`）。

**服务端超时/中止**：async image 路由内 `AbortController` + `ASYNC_TASK_TIMEOUT`（298s）定时 abort（`async/image.ts:131-133,322-334`），abort 后任务标记 Error 并走退款（OSS stub）；视频 webhook 路由对中间状态（pending）直接跳过（`webhooks/video/[provider]/route.ts:71-75`），终态幂等（`:115-122`）。

**取消与失败**：**本次未找到用户侧取消动作**——工作台没有 cancel 按钮/action（grep image/video store 未见 cancel 类方法；取消语义只存在于 async 路由的服务端 abort 与 SWR 停止轮询）。失败分类：`categorizeImageGenerationError`（`apps/server/src/routers/async/imageError.ts`，区分编辑图/内容审核/超时等）与 provider content policy 消息（`getProviderContentPolicyErrorMessage`）；客户端 ErrorState 按 `AsyncTaskErrorType` 翻译并支持复制错误（`GenerationItem/ErrorState.tsx:30-125`）；InvalidProviderAPIKey 在 batch 层整卡引导设置（`BatchItem.tsx:122-136` → `GenerationInvalidAPIKey`）。任务层重试入口见第 5 节。

**重启语义**：状态全部在 PostgreSQL；页面刷新/重启后 topic 列表与 batch feed 由 SWR 重新拉取，未终态 generation 的轮询自动恢复（`useFetchGenerationBatches` + `useCheckGenerationStatus` 以 DB 行为为准），无内存态恢复问题（zustand `currentGeneratingId` 类缓存不存在于此设计）。

## 4. 结果、历史、资产与工程持久化

**三层落库**：lambda 事务内一次写入 batch + generations + asyncTasks（image `index.ts:215-298`；video `index.ts:192-247`）；成功时 `generationModel.createAssetAndFile` 在同一事务写 `asset jsonb` + `files` 行 + 回填 `fileId`（`packages/database/src/models/generation.ts:137-178`），file 的 visibility 跟随 topic visibility（`:156`）。

**命名与去重**：S3 key 按以下模式生成（`services/generation/index.ts:212-259,266-310`、`video.ts:87-135`）：

```text
images: generations/images/<uuid>_<WxH>_<yyyyMMddHHmmss>_raw.<ext>   + _thumb.webp
videos: generations/videos/<uuid>_<WxH>_<ts>_raw<.mp4|.webm>         + _cover.webp + _thumb.webp
covers: generations/covers/<uuid>_<WxH>_<ts>_cover.webp
```

去重：原图与缩略图各算 sha256（`image.ts:116,148`），`FileModel.create(..., insertToGlobalFiles=true)` 以 `fileHash → globalFiles.hashId` + `onConflictDoNothing` 做全局 blob 去重（`models/file.ts:86-141`），`files` 行仍各自建。**无内容级去重之外的历史合并逻辑**（同 prompt 重复生成会新建 batch）。

**索引与来源关联**：generations 建有 `user_id/workspace_id/batch_id/file_id` 索引（`schemas/generation.ts:155-161`）。来源语义：`FileSource.ImageGeneration|VideoGeneration`（`packages/types/src/files/index.ts:17-27`）区分生成文件与普通上传；生成文件不在 `LIBRARY_HIDDEN_FILE_SOURCES` 内，因此会出现在资源库的 Images/Videos tab（`desktopRouter.shared.tsx:73-74`）。`files.metadata` 记录 generationId/宽高/路径（`async/image.ts:255-264`）；asset jsonb 同时保留 provider 原始 URL（`originalUrl`，通常短期过期）。

**删除链**：删除按"数据库优先、文件后清理"原则——topic 删除收集 coverUrl+所有 generation 的 url/thumbnailUrl/coverUrl 后级联删表，再 `fileService.deleteFiles`（S3，失败只记日志不阻塞，`models/generationTopic.ts:159-215`）；batch 删除同构（`models/generationBatch.ts:247-298`）；generation 删除保留主文件、只删缩略图（`routers/lambda/generation.ts:37-63`，注释说明新需求如此）。

**读取变换**：`queryGenerationBatchesByTopicIdWithGenerations` 把 config 中的 S3 key 变回完整 URL、附 creator 信息（`models/generationBatch.ts:168-234`）；`transformGeneration` 把 asset 的 key 变访问 URL（`models/generation.ts:225-268`）；topic 列表附封面完整 URL 与 creator（`models/generationTopic.ts:37-72`）。

## 5. 预览、编辑、重试、分支与复用

- **预览**：batch 内 `Image.PreviewGroup` 网格 + 每张 `GenerationItem`（`BatchItem.tsx:148-159`）；视频 `VideoSuccessItem` 播放（静态代码确认组件存在，实际播放未运行验证）。
- **导出**：图片 `useDownloadImage`（文件名 `<prompt前30字符>_<时间戳>.<ext>`，`GenerationItem/index.tsx:50-63`）；视频 `downloadFile`（`:132-146`）。
- **重试/再生成**：UI 实装的是 batch 级 `reuseSettings`（image `BatchItem.tsx:100-106` 剔除 seed 后回填配置，video `BatchItem.tsx:110-120` 逐参数回填）与 `copyPrompt`。generation 级提供 `copySeed`（模型支持 seed 时 `reuseSeed` 直接应用，否则复制剪贴板，`GenerationItem/index.tsx:65-87`）。`recreateImage`/`recreateVideo` store 动作（删除原 batch 后用 `batch.config` 原参数重建，`src/store/image/slices/createImage/action.ts:115-152`、`src/store/video/slices/createVideo/action.ts:134-164`）**本次未找到 UI 调用点**（全 src grep 仅命中定义与测试）。
- **编辑**：无像素级编辑/局部重绘（本次未找到）；"继续创作"的等价物是修改 prompt/参考图/参数后重新生成，或用主题封面/历史批次继续。
- **分支**：无显式分支 UI；每次生成新建 batch（同一 topic 内线性追加），删除 batch 后 reuseSettings 可重建近似批次，但不保留 parent 关系（与 Chatbox 的 parentIds DAG 不同，本次未找到 generation 级父子字段）。
- **再次引用**：参考图可以从本地上传，也可复用历史（`ReferenceImages` 展示 batch.config 里的参考图，`image/features/GenerationFeed/ReferenceImages.tsx`；复用即 reuseSettings 回填）；结果文件进资源库 tab（第 4 节）；topic 封面被 Sidebar 引用展示。

## 6. Agent 回流、插件与外部依赖

**Agent 创作通道**：`builtin-tool-image-generation`（`packages/builtin-tool-image-generation/src/manifest.ts`）提供 4 个 API：

- `listImageModels`：模型目录发现，含参数键/定价描述
- `getImageModelParameters`：参数 schema + 默认值
- `generateImage`：prompt/imageNum 1-8/参考图 URL/parameters 透传；`waitUntilComplete` 默认 true，工具内 3s 间隔轮询至终态，上限 175s（`:441-587,399-439`）
- `getImageGenerationStatus`：按 generationId+asyncTaskId 查单条

`humanIntervention: 'never'`（manifest `:141`）；Client 与 server 双 executor 共用同一 `ImageGenerationExecutionRuntime` 类，分别接客户端 lambda 服务与 tRPC caller（`apps/server/src/services/toolExecution/serverRuntimes/imageGeneration.ts:24-104`）。注入规则：chat mode 下仅当模型支持工具调用、**非**原生 imageOutput 模型、且用户 pin 了该插件时才注入（`apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:258-294`）。结果回流：生成完成输出 `![Generated image N](url)` markdown 标签 + 专用渲染组件 `GenerateImage.tsx`/`GetImageGenerationStatus.tsx`（3s 轮询）进聊天消息。**未找到视频 Agent 工具**（packages 下无 builtin-tool-video-generation，grep 确认）；**未找到 Agent 读取创作历史/工作台历史引用的工具**（媒体历史仅 CommandMenu 全局搜索可见）。

**外部依赖边界**：

- 模型 provider：agent-runtime 统一接口（`createImage`/`createVideo`/`handlePollVideoStatus`/`handleCreateVideoWebhook`），具体 provider 实现与计费为外部服务
- S3/OSS：FileService（`uploadMedia`/`deleteFiles`/`getFullFileUrl`/`getKeyFromFullUrl`）；PostgreSQL（Drizzle）
- sharp（图像转码/封面）；ffmpeg-static（子进程 `execFile` 元数据/截图，`services/generation/video.ts:24-28,223-285`）；Redis 可选（视频平均延迟缓存，`services/generation/latency.ts:15-20`）；LLM（主题标题生成 `chatService.fetchPresetTaskResult`）
- `ssrfSafeFetch`：用户可控 URL 抓取防 SSRF（`services/generation/index.ts:53-70`，注释引用 GHSA-53h9-fmjf-frwr）

OSS 中计费/配额/完成通知为闭源扩展点：`chargeBeforeGenerate`/`chargeAfterGenerate`/`notifyImageCompleted`/`notifyVideoCompleted`/`getVideoFreeQuota` 全部空实现且 `ENABLE_BUSINESS_FEATURES=false`（`packages/business/const/src/index.ts:7`）。无 ComfyUI 服务端编排、无自有渲染器；ComfyUI 仅作为普通图像 provider 之一出现（透传认证头下载结果图，`async/image.ts:212-228`）。

## 7. 权限、资源边界与失败恢复

- **权限**：写操作统一带 `withScopedPermission`（`file:upload`/`file:delete`/`topic:create|update|delete`，各 lambda 路由）；客户端以 `usePermission('create_content')` 门控生成与参考图上传（`PromptInput/index.tsx:140,193`）。workspace 作用域由 `buildWorkspaceWhere` 统一实现（`packages/database/src/utils/workspace.ts:40-86`）：
  - personal 模式：`user_id + workspace_id IS NULL`
  - 工作区模式：成员可见 public，private 限 creator；topic 可见性翻转 `setVisibility` 仅 creator（`models/generationTopic.ts:126-146`），工作区外的 `setTopicVisibility` 调用直接拒绝（`routers/lambda/generationTopic.ts:134-166`）；topic 层 `assertWorkspaceRowManageable` 校验同 workspace 归属

  生成文件的 `files.visibility` 跟随 topic（`models/generation.ts:156`），删除权限为 topic 的 creator 或 workspace owner（`Item/index.tsx:52,91`）。
- **资源限额**：OSS 快照无真实计费额度（charge 钩子空）；输入侧限额来自模型 schema（imageNum 上限 1-8 由 Agent 工具参数声明，`manifest.ts:60-64`；参考图 maxCount/maxFileSize 由 `useGenerationConfigParam` 按 schema 提供，`image/features/PromptInput/useImageReferenceUpload.ts:39-46`）；视频下载 500MB/5min 硬限（`video.ts:166-221`）；轮询/超时上限：客户端 30s 封顶退避、服务端 298s abort、视频后台轮询 120×5s=600s。
- **失败恢复**：任务级失败表现为 Error 状态 + 分类错误（可复制）；重跑入口是 reuseSettings/copyPrompt/复制 seed 后手动再生成（recreate 动作无 UI 绑定，见第 5 节）；超时由 `checkTimeoutTasks` 兜底为 Timeout 错误；异步任务在数据库中的状态保证刷新/重启后可继续轮询取回（第 3 节）。

## 8. 设计取舍、已确认边界与未验证事项

### 设计取舍与已确认边界

- **三层对象把"一次请求配置"（batch）与"单张结果"（generation）分开**：batch.config 既是复用设置的来源，也是资产元数据不索引化的容器；generation 保存 seed/asset/文件关联，便于逐张操作（下载/复制 seed/删除）。
- **参考图以 S3 key 入库而非原始 URL**：防过期 presigned URL 污染数据库；读取时再变换回完整 URL。
- **video 双完成路径按 provider 能力分流**：webhook 型（如 Volcengine 注释）走回调，polling 型（如 OpenAI Sora 注释）走服务端后台轮询；客户端统一只认 asyncTask 状态，不感知具体路径。
- **客户端轮询与服务端收口分离**：客户端退避轮询只读状态，超时/错误判定在服务端（checkTimeoutTasks、abort、120 次上限），刷新/重启后以 DB 为权威恢复。
- **OSS 的计费/通知面全部留 stub**：`ENABLE_BUSINESS_FEATURES=false` 时预扣、结算、免费配额、完成通知都不发生；付费工作区行为（error batch 额度拦截、cooldown、退款）只能从路由器调用点与类型推断，无实现可查。
- **本次未找到**：工作台→聊天会话的回流动作（sendToChat 类，grep `sendToChat|toChat|sendGeneration|generationToChat` 全 src 无命中，notify 钩子为空）；用户侧任务取消入口；recreateImage/recreateVideo 的 UI 调用点；视频 Agent 工具；generation 级父子分支关系；工作台结果与 Work 对象（独特功能笔记未验证项"image/video 创作工作台与 Work 对象的衔接"——生成结果走 files/asset 体系，`work`/`work_versions` 未见到生成来源的写入点）的关联；async/video.ts 的生产调用者。

### 未验证事项

- 真实模型调用（fal/OpenAI/Volcengine 等 provider 的 createImage/createVideo）、S3 上传下载、PostgreSQL 事务与 webhook 网络往返——标注"未验证：需要真实模型、数据库与网络环境"。
- 计费/配额面全部行为（OSS 为 stub，闭源实现不可查）。
- 视频真实生成时长、后台轮询 120 次上限内的实际完成率、webhook 超时后任务如何收口（webhook 路由无自身超时，任务仍由 checkTimeoutTasks 兜底——静态推断）。
- sharp/ffmpeg-static 在本机的转码/截图输出效果（需运行环境与 ffmpeg 二进制）。
- UI 视觉（网格、进度环、播放器）、键盘可用性与移动端适配（本次未找到 (mobile) 侧的 image/video 路由）。
- 仓库自带单元测试（image/video lambda、async、services/generation、client stores、builtin-tool-image-generation）均未运行——约束禁止安装依赖；文件清单见"关键源码索引"。

## 交接专页（与独特功能笔记的分工）

本页承接 [LobeHub 独特功能调查笔记](../独特功能/LobeHub-独特功能调查笔记.md)（快照同为 `3b57a07e`，其中 image/video 创作面仅一句"`(create)/image` 与 `/video` 路由族……本次不展开"）。独特功能笔记负责能力盘点与产品叙事，本页负责媒体创作类目视角：

- **三层事实对象与双路由执行**（§1、§2）：topic/batch/generation + asyncTask/files 的对象模型、lambda 事务提交 + async 模型调用、视频 webhook/后台轮询双完成路径——独特功能笔记未展开。
- **客户端轮询与状态收口**（§3）：SWR 指数退避、DB 权威超时、无用户取消。
- **资产命名/去重/来源与封面回写**（§4）：S3 key 规则、globalFiles hash 去重、FileSource、topic 封面自动回写。
- **复用面与 Agent 通道**（§5、§6）：reuseSettings/copySeed/recreate（无 UI 绑定）、builtin-tool-image-generation 4 API 与聊天回流。
- **未验证事项的交接更新**：独特功能笔记"image/video 创作工作台与 Work 对象的衔接"——本次确认无 generation→work 关联（§8）。

## 关键源码索引

- 路由与页面：`src/spa/router/desktopRouter.shared.tsx:672-711`、`src/routes/(main)/(create)/{features,image,video}/`（CreateGenerationPage、GenerationWorkspace、GenerationFeed、GenerationLayout、PromptInput、ConfigPanel、ImageWorkspace、VideoWorkspace、_layout/Sidebar）
- 数据库：`packages/database/src/schemas/generation.ts`、`relations.ts:325-362`、`models/{generationTopic,generationBatch,generation,asyncTask,file}.ts`、`utils/workspace.ts`
- 服务端路由：`apps/server/src/routers/lambda/{image,generation,generationBatch,generationTopic}/index.ts`、`lambda/video/index.ts`、`routers/async/{image,video,index,caller}.ts`、`src/app/(backend)/api/webhooks/video/[provider]/route.ts`
- 服务：`apps/server/src/services/generation/{index,video,videoBackgroundPolling,latency}.ts`、`services/toolExecution/serverRuntimes/imageGeneration.ts`、`modules/Mecha/AgentToolsEngine/index.ts:258-294`
- 客户端 store：`src/store/image/slices/{createImage,generationBatch,generationConfig,generationTopic}/`、`src/store/video/slices/`（同构）；客户端服务 `src/services/{image,video,generation,generationBatch,generationTopic}.ts`
- Agent 工具：`packages/builtin-tool-image-generation/src/{manifest,ExecutionRuntime,client/executor,client/Render}.ts(x)`；类型 `packages/types/src/generation/index.ts`、`files/index.ts`；参数 `packages/model-bank/src/standard-parameters/{index,video}.ts`
- 业务占位：`packages/business-server/src/{image,video}-generation/*.ts`、`packages/business/const/src/index.ts:7`、`packages/business/config/src/server/route.ts:2`
- 测试文件（未运行）：`apps/server/src/routers/lambda/{image,__tests__/generation,generationBatch,generationTopic,__tests__/video}.test.ts`、`routers/async/__tests__/image.test.ts`、`services/generation/{index,latency,videoBackgroundPolling,videoFile}.test.ts`、`src/store/image|video/slices/*/action|reducer|selectors|hooks*.test.ts*`、`src/routes/(main)/(create)/**/*.test.*`、`packages/builtin-tool-image-generation/src/**/*.test.ts`
