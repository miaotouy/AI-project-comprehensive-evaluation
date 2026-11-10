# LobeHub 媒体创作调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`（Next.js 16 SPA + Hono/tRPC 服务端 + Drizzle/PostgreSQL，另含 Electron 桌面目标）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：静态源码走读（只读，未修改仓库）；与独特功能笔记快照比对（HEAD 一致）；零依赖验证仅限 `node -e` 解析 5 个 package.json（全部通过）与 `git status` 工作树核对（0 改动）；未安装依赖、未运行测试、未启动应用（Next.js 应用在无模型/无 DB/S3 环境下 dev 跑不通）
>
> 调查范围：`(create)/image` 与 `/video` 路由族媒体创作主链（能力分型 M1 模型生成工作站 + M3 资产/记录生命周期，含 M5 边界）：入口与触发者、topic/batch/generation 三层事实对象、参数/参考图/模型执行、lambda/async 双路由与轮询、webhook 与后台轮询、结果/历史/资产持久化、预览/复用/重试、Agent 工具回流、workspace 权限与限额。聊天 Agent 工具执行机制、消息渲染与模型 provider 内部实现只做交接引用；独特功能笔记已覆盖的 Schedule/Memory/Brief/Work 等能力不在本页范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 有一条完整的图像 + 视频生成工作链，能力分型为 **M1 模型生成工作站 + M3 记录/资产生命周期**：单一工作台按 `generationTopics → generationBatches → generations` 三层持久化每次创作，生成行再挂 `asyncTasks`（任务状态/错误/预扣句柄）与 `files`（S3 资产行）两张关联表；资产行以 `FileSource.ImageGeneration|VideoGeneration` 标记来源，`asset` jsonb 保存 URL/尺寸/时长。执行分 lambda（提交、事务建行）与 async（实际模型调用）双路由，视频另有 webhook 与后台轮询两条完成路径；客户端以 SWR 指数退避轮询任务终态。

媒体创作视角下三个关键机制（独特功能笔记均未展开）：

1. **三层对象 + 服务端封面收口**：主题组织批次，批次保存模型与输入设置，单项生成关联结果资产、文件和异步任务。服务端成功路径在标记任务成功前，用缩略图填补空主题封面；并发批次通过数据库的空值条件更新只保留一个胜出封面，未使用的上传会清理。客户端即使退出轮询，成功路径仍可落封面。见 [GenerationService.ensureTopicCover](../../lobehub/apps/server/src/services/generation/index.ts#L330-L378)、[条件更新](../../lobehub/packages/database/src/models/generationTopic.ts#L115-L130)。
2. **lambda/async 双路由 + 双完成路径**：提交与执行分两层——lambda 路由在一个事务里建好批次、结果生成行与异步任务行后，以 fire-and-forget 方式触发异步调用，真正调模型发生在 async 路由；视频侧由 lambda 直接发起模型调用，再按 provider 返回的回调形态二选一收口。

   - 图像：lambda 的 `image.createImage` 建好批次、生成行与任务行后，以 fire-and-forget 方式交给 async 路由，由 `asyncCaller.image.createImage` 完成模型调用（`apps/server/src/routers/lambda/image/index.ts:215-332`、`apps/server/src/routers/async/image.ts`）。
   - 视频：lambda 直接调用 createVideo，随后按响应里的 useWebhook 分流：webhook 型等回调（一次性 token 校验），轮询型由 after() 注册后台任务（5s 固定间隔、最多 120 次）。两个分支分别见 `apps/server/src/router-hono/webhooks/handlers/video.ts` 与 `apps/server/src/services/generation/videoBackgroundPolling.ts`。
3. **Agent 创作通道**：`builtin-tool-image-generation` 是唯一的“结果进聊天”回流：Agent 可发现图像模型与参数 schema、发起生成并查询任务状态（4 个 API，见第 6 节），`humanIntervention: 'never'`，默认在工具内等待完成，结果以 markdown 图片标签 + 专用渲染组件进消息（`packages/builtin-tool-image-generation/src/manifest.ts`、`ExecutionRuntime/index.ts:441-587`）。

已确认边界：OSS 快照中计费/通知为闭源占位（`ENABLE_BUSINESS_FEATURES=false`，charge*/notify* 均为 no-op stub），工作台生成结果与聊天会话之间**未找到** sendToChat 类回流入口；`recreateImage/recreateVideo` store 动作存在但**本次未找到 UI 调用点**；`apps/server/src/routers/async/video.ts`（异步轮询变体）注册在 asyncRouter 但**本次未找到生产调用者**。全部结论为静态源码事实；真实模型调用、S3/PostgreSQL/Redis、webhook 网络行为与 UI 视觉效果未运行验证。

## 系统边界与完整主链

### 边界

| 层 | 承担者 | 证据 |
|---|---|---|
| 创作入口 | `/image`、`/video` 路由族（个人与 `/:workspaceSlug/*` 双形态） | `src/spa/router/desktopRouter.shared.tsx:672-711`、`src/routes/(main)/(create)/features/CreateGenerationPage.tsx:43-44` |
| 事实对象 | `generation_topics` / `generation_batches` / `generations` 三表 + `asyncTasks` + `files` | `packages/database/src/schemas/generation.ts`、relations `:325-362` |
| 提交/任务执行 | lambda 路由（事务建行、触发 async）；async 路由（调模型）；视频 webhook 路由（Hono webhook handler） | `apps/server/src/routers/lambda/{image/index.ts,video/index.ts,generation.ts,generationBatch.ts,generationTopic.ts}`、`routers/async/{image,video}.ts`、`apps/server/src/router-hono/webhooks/handlers/video.ts` |
| 结果加工 | GenerationService（sharp 缩略图/封面）、VideoGenerationService（ffmpeg-static 元数据/截图）、FileService（S3） | `apps/server/src/services/generation/{index,video,videoFile,videoBackgroundPolling,latency}.ts` |
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
       -> 终态 Success 时更新本地资产并刷新服务端主题封面；Error 显示分类错误
  -> 复用：BatchItem 的 reuseSettings（回填配置，image 剔除 seed）/ copyPrompt / deleteBatch；
       GenerationItem 的 download / copySeed（模型支持则 reuseSeed 直接应用）/ delete / copyError；
       topic 列表（grid/list）切换历史、删除、publishToWorkspace / makePrivate（creator-only）
  -> Agent：builtin-tool-image-generation 4 API，生成结果以 markdown 图片标签回流聊天（+ 专用渲染组件 3s 轮询）
```

## 1. 创作入口、触发者与事实对象

**入口与触发者**：用户主导的工作台是主入口，两条路由共享同一套页面骨架，顶部模式段负责图像与视频切换，历史主题经 URL 深链与全局命令菜单进入；此外还有一条聊天内 Agent 触发通道（见第 6 节）。

- 路由与页面骨架：图像 /image 与视频 /video 两条路由共用 `(create)` 布局族的同一套页面骨架，页面组件位于 `src/routes/(main)/(create)/features/`，模式切换由顶部模式段与路由表共同完成（`desktopRouter.shared.tsx:672-711`、`GenerationMediaModeSegment.tsx:104-110`）。
- URL 深链：`?topic=` 参数定位历史主题，`?model=&prompt=` 让页面按参数直接进入生成流程（`image/features/PromptInput/index.tsx:187-267`，源码注释记录了模型未就绪时防误触发的守卫）；历史主题也可在全局命令菜单里搜索（`src/features/CommandMenu/SearchResults.tsx:68-71`）。
- Agent 通道：聊天内 Agent 走 `builtin-tool-image-generation` 工具（见第 6 节）。插件、定时任务与外部服务三类触发入口本次未找到；`notifyImageCompleted`/`notifyVideoCompleted` 钩子存在但为空实现（`packages/business-server/src/image-generation/notifyImageCompleted.ts:12`、`video-generation/notifyVideoCompleted.ts:11`）。

**核心事实对象**——三层 + 两个关联对象（`packages/database/src/schemas/generation.ts`、relations `:325-362`）：

- 主题行 `generationTopics`（`:16-54`）：记录归属（userId/workspaceId）、由 LLM 生成的标题、封面 S3 key、图像或视频的类型，以及工作区内的可见性 private/public（personal 模式忽略该字段）。一条主题对应多条批次。
- 批次行 `generationBatches`（`:64-109`）：保存一次请求的完整配置，包括 provider、model、prompt、宽高比与输出宽高。通用设置收在 `config` jsonb 里，不建索引，参考图的 S3 key 也存在此处。每条批次归属一个主题，并对应多条生成行（[主题、批次与生成行关系](<../../lobehub/packages/database/src/schemas/relations.ts#L375-L403>)）。
- 生成行 `generations`（`:122-161`）：保存 seed、`asset` jsonb（含 url、thumbnailUrl、originalUrl、coverUrl、宽高与时长）、异步任务 id（任务删除时置空）与文件 id（文件删除时级联删除该生成行）。
- 异步任务 `asyncTasks`：按 Pending → Processing → Success 或 Error 流转，记录错误信息与耗时，`metadata` 里保存预扣句柄、视频 webhookToken 与 inferenceId。超时由定时检查兜底，阈值取自 `ASYNC_TASK_TIMEOUT`（298 秒），定时检查与阈值分别定义在 `packages/database/src/models/asyncTask.ts:253-289` 和 `packages/business/config/src/server/route.ts:2`。
- 文件 `files` 与 `globalFiles`：前者保存资产行，后者按 hash 保存去重后的 blob 元数据（`packages/database/src/models/file.ts:86-141`）。

前端类型 `GenerationBatch`（含 creator/avgLatencyMs）与 `Generation`（含 task{id,status,error}）在 `packages/types/src/generation/index.ts:79-104`。

## 2. 参数、素材与模型/渲染执行

**模型能力目录**：

- **来源**：模型目录由 aiInfra store 的 enabledImageModelList 与 enabledVideoModelList 两个选择器提供，各自按 provider 分组列出已启用的模型（`src/store/aiInfra`）
- **参数 schema**：每个模型的参数定义来自 model-bank 的标准参数集，图像走 `RuntimeImageGenParams`，视频走 `RuntimeVideoGenParams`；界面据此渲染参数控件，并从 schema 读取默认值、上下界与枚举（`standard-parameters/index.ts:280-289`、`video.ts:191-194`、`generationConfig/hooks.ts`）
- **参数迁移**：切换模型时，generationConfig slice 先用 extractDefaultValues 取新模型的默认值，再由 preserveSupportedParams 过滤，prompt 与参考图保留、新模型不支持的参数丢弃（`generationConfig/action.ts:287-321`、`preserveSupportedParams.ts`）

**参数进入请求**：两份提交 schema 结构一致——主题标识加模型/provider，其余参数宽松透传，因此新增模型参数改动只落在参数清单上，路由契约保持稳定。两侧的透传字段清单见下表。

| 侧 | 提交 schema | params 透传字段 |
|---|---|---|
| 图像 | `apps/server/src/routers/lambda/image/index.ts:50-66` | `params{prompt,cfg?,height?,width?,steps?,seed?,imageUrls?,...passthrough}` |
| 视频 | `routers/lambda/video/index.ts:60-77` | `params{aspectRatio?,cameraFixed?,duration?,endImageUrl?,generateAudio?,imageUrl?,prompt,resolution?,seed?,...passthrough}` |

参考图由本地上传写入 S3 后以 URL 进入请求（上传入口 `useFileStore.uploadWithProgress`，`(create)/features/GenerationInput/useReferenceImageUpload.ts:92-195`）。

lambda 侧再用 `fileService.getKeyFromFullUrl` 把这些 URL 归一化为 S3 key 入库，避免过期 presigned URL 进入数据库，并有 `validateNoUrlsInConfig` 做防御性校验（`image/index.ts:112-186`、`image/utils.ts`）。开发环境另把代理 URL 转回 S3 URL 供 async 任务访问，图像侧落在同一区间，视频侧见 `routers/lambda/video/index.ts:137-165`。

**执行位置**：

- **图像**：lambda 的 `image.createImage` 依次准备请求、创建数据库记录，再触发后台执行，事务仅覆盖中间的建记录步骤：
  1. 事务前映射模型、校验可用性、把参考图 URL 归一化为 S3 key，并做预扣（OSS 快照里预扣为空实现；[准备与预扣](<../../lobehub/apps/server/src/routers/lambda/image/index.ts#L85-L297>)）。
  2. 在同一数据库事务中建批次、N 条生成行与各自的异步任务，并写好关联；参数包含 seed 字段时由 `generateUniqueSeeds` 逐张生成唯一值，否则写 null（[建记录事务](<../../lobehub/apps/server/src/routers/lambda/image/index.ts#L299-L392>)）。
  3. 事务提交后 fire-and-forget 触发 `asyncCaller.image.createImage`，实际生成交给 async 路由独立处理（[后台触发](<../../lobehub/apps/server/src/routers/lambda/image/index.ts#L394-L433>)）。

  实际模型调用发生在 async 路由，四步依次进行（`apps/server/src/routers/async/image.ts:81-401`）：
  1. 从数据库读出 provider 配置初始化模型运行时，再由 createImage 发起真实模型调用；agent-runtime 在这里提供统一接口，各 provider 的实现属于外部依赖
  2. 用 sharp 生成 512 上限的缩略图
  3. 上传原图与缩略图到 S3，key 形如 `generations/images/<uuid>_<WxH>_<日期>_raw.<ext>` 与 `_thumb.webp`（sharp 加工与上传见 `services/generation/index.ts:97-259`）
  4. 调用 createAssetAndFile 写资产行与文件行收尾

  ComfyUI 作为图像 provider 时还会带认证头下载结果图，这一步同样在 async 路由内完成（`async/image.ts:212-228`）。
- **视频**：lambda 的 `video.createVideo` 先在一个事务里建好批次、生成行与异步任务行，随后发起模型调用；入口与事务见 `routers/lambda/video/index.ts:81-372`、`:184-247`（webhookToken 放 metadata），模型调用见 `:259-266` 的 `modelRuntime.createVideo`。
- 视频完成收口：按响应里的 `useWebhook` 分流，webhook 型等回调（`apps/server/src/router-hono/webhooks/handlers/video.ts`），其余由 `after()` 注册后台轮询（`videoBackgroundPolling.ts:32-142`，5s 间隔 × 120 次）。

  视频完成后交给 VideoGenerationService 加工，入口是 processVideoForGeneration（`services/generation/video.ts:58-285`）：
  1. 下载结果视频，单文件 500MB、5 分钟为上限
  2. 调 ffmpeg-static 读取时长与分辨率
  3. 在 0.1 秒处截取一帧
  4. 转出 cover 与 thumb 两张 webp 上传 S3，key 落在 generations/videos/ 下，后缀分别为 _cover.webp 与 _thumb.webp
- **异步变体**：`apps/server/src/routers/async/video.ts` 是同构轮询实现（含 abort 支持），注册于 asyncRouter（`routers/async/index.ts:9-15`），但**本次未找到生产调用者**（grep `asyncCaller.video` 无命中；lambda video 走 webhook/后台轮询）。

**主题标题的 LLM 生成**：`summaryGenerationTopicTitle` 用 `chatService.fetchPresetTaskResult` + `chainSummaryGenerationTitle(prompts, 'image'|'video', lang)` 流式生成标题（`src/store/image/slices/generationTopic/action.ts:74-136`），失败回退"首条 prompt 前 3 词截 20 字符"。

## 3. 任务状态、异步回调与取消

**客户端状态机**：生成卡片按任务状态渲染成功、失败、进行中三种形态；视频批次只有一条生成，同样走这三态（`image/features/GenerationFeed/GenerationItem/index.tsx:22-148`、`video/features/GenerationFeed/BatchItem.tsx:79-88,201-230`）。每条生成由 useCheckGenerationStatus 发起 SWR 轮询，入参是任务与主题的定位信息和轮询开关（图像侧 `src/store/image/slices/generationBatch/action.ts:193-301`；视频侧同构，定位见文末索引）。

**轮询策略**：客户端 SWR 按请求次数指数退避，成功或失败后停止；状态端点会把超龄的待处理/处理中任务结算为超时错误。成功时客户端更新本地资产并刷新批次；本地主题仍无封面时只刷新主题列表，封面写入由服务端成功路径承担。图像异步路由、视频后台轮询与 webhook 均在任务成功前调用同一封面服务。见 [客户端终态处理](../../lobehub/src/store/image/slices/generationBatch/action.ts#L220-L252)、[图像成功路径](../../lobehub/apps/server/src/routers/async/image.ts#L273-L282)、[视频成功路径](../../lobehub/apps/server/src/services/generation/videoBackgroundPolling.ts#L121-L143)。

**服务端超时/中止**：async image 路由内 `AbortController` + `ASYNC_TASK_TIMEOUT`（298s）定时 abort（`async/image.ts:131-133,322-334`），abort 后任务标记 Error 并走退款（OSS stub）；视频 webhook 处理对尚未到终态的任务直接跳过并返回成功，终态写入做幂等（`apps/server/src/router-hono/webhooks/handlers/video.ts`，token 用 `timingSafeEqual` 比对）。

**取消与失败**：**本次未找到用户侧取消动作**——工作台没有 cancel 按钮/action（grep image/video store 未见 cancel 类方法；取消语义只存在于 async 路由的服务端 abort 与 SWR 停止轮询）。失败分类来自 async 路由的图像错误归类（区分编辑图、内容审核、超时等）与 provider content policy 消息，见 `apps/server/src/routers/async/imageError.ts`；客户端错误态按错误类型翻译并支持复制（`GenerationItem/ErrorState.tsx:30-125`），缺失 provider API key 时在批次层整卡引导设置（`BatchItem.tsx:122-136`）。任务层重试入口见第 5 节。

**重启语义**：状态全部在 PostgreSQL；页面刷新/重启后 topic 列表与 batch feed 由 SWR 重新拉取，未终态 generation 的轮询自动恢复（`useFetchGenerationBatches` + `useCheckGenerationStatus` 以 DB 行为为准），无内存态恢复问题（zustand `currentGeneratingId` 类缓存不存在于此设计）。

## 4. 结果、历史、资产与工程持久化

**三层落库**：一次请求的三层对象在同一个 lambda 事务里写入，图像与视频两条路由分别见 `index.ts:215-298`、`index.ts:192-247`。

任务成功时同一事务继续写结果资产（`asset jsonb`）、`files` 行并回填 `fileId`，文件的 visibility 跟随主题；写入入口 `generationModel.createAssetAndFile`，事务范围与可见性继承同在 `packages/database/src/models/generation.ts:137-178`。

**命名与去重**：S3 key 按以下模式生成（`services/generation/index.ts:212-259,266-310`、`video.ts:87-135`）：

```text
images: generations/images/<uuid>_<WxH>_<yyyyMMddHHmmss>_raw.<ext>   + _thumb.webp
videos: generations/videos/<uuid>_<WxH>_<ts>_raw<.mp4|.webm>         + _cover.webp + _thumb.webp
covers: generations/covers/<uuid>_<WxH>_<ts>_cover.webp
```

去重：原图与缩略图各算 sha256（`routers/async/image.ts:116,148`），写入文件时以 hash 指向全局 blob 并忽略冲突，做全局 blob 去重（`models/file.ts:86-141`），`files` 行仍各自建。除这层 blob 去重外没有历史合并逻辑，同 prompt 重复生成会新建 batch。

**索引与来源关联**：生成行的索引、文件来源标记与元数据字段共同决定文件在资源库中的可见位置。

- 索引：生成表在 user_id、workspace_id、batch_id、file_id 四列上建索引，支撑按主题、批次与文件回查（`schemas/generation.ts:155-161`）。
- 来源：`FileSource` 的 ImageGeneration 与 VideoGeneration 两个取值区分生成文件与普通上传（`packages/types/src/files/index.ts:17-27`）；生成文件不在隐藏来源清单 `LIBRARY_HIDDEN_FILE_SOURCES` 里，因此出现在资源库的 Images/Videos 分类（`desktopRouter.shared.tsx:73-74`）。
- 元数据：文件行的 metadata 记录所属生成 id、宽高与存储路径（`async/image.ts:255-264`）；资产 jsonb 另外保存 provider 返回的原始 URL（originalUrl，通常短期过期）。

**删除链**：删除按"数据库优先、文件后清理"原则——topic 删除收集 coverUrl+所有 generation 的 url/thumbnailUrl/coverUrl 后级联删表，再 `fileService.deleteFiles`（S3，失败只记日志不阻塞，`models/generationTopic.ts:159-215`）；batch 删除同构（`models/generationBatch.ts:247-298`）；generation 删除保留主文件、只删缩略图（`routers/lambda/generation.ts:37-63`，注释说明新需求如此）。

**读取变换**：`queryGenerationBatchesByTopicIdWithGenerations` 把 config 中的 S3 key 变回完整 URL、附 creator 信息（`models/generationBatch.ts:168-234`）；`transformGeneration` 把 asset 的 key 变访问 URL（`models/generation.ts:225-268`）；topic 列表附封面完整 URL 与 creator（`models/generationTopic.ts:37-72`）。

## 5. 预览、编辑、重试、分支与复用

- **预览**：图像批次把各张生成排进 Image.PreviewGroup 网格，每张卡片由 GenerationItem 渲染（`BatchItem.tsx:148-159`）；视频结果交给 VideoSuccessItem 播放，组件已在静态代码中确认存在，实际播放未运行验证。
- **导出**：图片走 useDownloadImage，文件名取提示词前 30 个字符加时间戳、扩展名跟随原图；视频走 downloadFile。两者的入口都在这张卡片组件里（`GenerationItem/index.tsx:50-63,132-146`）。
- **重试/再生成**：重试入口停在批次级复用——回填上次配置或复制提示词；生成级只提供复制随机种子；store 层另有整批重建动作。

  - 批次级：批次卡片提供复用设置与复制提示词两个入口。前者把上次的模型与参数回填到表单，图像侧回填前剔除 seed，视频侧逐项回填（`image/features/GenerationFeed/BatchItem.tsx:100-106`、`video/features/GenerationFeed/BatchItem.tsx:110-120`）。
  - 生成级：只提供复制 seed；模型支持 seed 时直接套用上次的值，否则写入剪贴板（`GenerationItem/index.tsx:65-87`）。
  - 整批重建：store 里另有删除原批次、用 batch.config 原参数重建的动作，图像与视频各一份（`src/store/image/slices/createImage/action.ts:115-152`、`src/store/video/slices/createVideo/action.ts:134-164`）。**本次未找到 UI 调用点**（全 src 搜索只命中定义与测试）。
- **视频对话式编辑**：支持该能力的模型、成功结果与结果中的交互句柄共同决定是否显示编辑入口。选中旧结果后，输入区暂存原草稿、继承可用生成设置并接受编辑指令；提交携带前次生成 id，成功提交或取消编辑后恢复原草稿。见 [BatchItem 编辑入口](../../lobehub/src/routes/%28main%29/%28create%29/video/features/GenerationFeed/BatchItem.tsx#L94-L107)、[提交与草稿恢复](../../lobehub/src/store/video/slices/createVideo/action.ts#L152-L174)。
- **版本关系**：服务端核验来源在相同主题、provider 和模型下且有交互句柄后，传前次交互标识调用编辑；结果资产保留 `previousGenerationId` 与交互标识，界面据此显示版本与来源。批次仍追加到时间线；父子字段随视频编辑的来源链写入，适用范围限于该编辑路径产生的资产。见 [来源校验](../../lobehub/apps/server/src/routers/lambda/video/index.ts#L277-L325)、[结果资产写入](../../lobehub/apps/server/src/services/generation/videoBackgroundPolling.ts#L108-L130)。像素级局部绘制入口未在已读工作台中确认。
- **再次引用**：参考图可以从本地上传，也可复用历史（`ReferenceImages` 展示 batch.config 里的参考图，`image/features/GenerationFeed/ReferenceImages.tsx`；复用即 reuseSettings 回填）；结果文件进资源库 tab（第 4 节）；topic 封面被 Sidebar 引用展示。

## 6. Agent 回流、插件与外部依赖

**Agent 创作通道**：`builtin-tool-image-generation`（`packages/builtin-tool-image-generation/src/manifest.ts`）提供 4 个 API：

- `listImageModels`：模型目录发现，含参数键/定价描述
- `getImageModelParameters`：参数 schema + 默认值
- `generateImage`：prompt/imageNum 1-8/参考图 URL/parameters 透传；`waitUntilComplete` 默认 true，工具内 3s 间隔轮询至终态，上限 175s（`:441-587,399-439`）
- `getImageGenerationStatus`：按 generationId+asyncTaskId 查单条

`humanIntervention: 'never'`（manifest `:141`）。Client 与 server 两个 executor 共用 `ImageGenerationExecutionRuntime`，分别接客户端 lambda 服务与 tRPC caller（`apps/server/src/services/toolExecution/serverRuntimes/imageGeneration.ts:24-104`）。

注入条件：chat 模式下模型支持工具调用、模型未声明原生 imageOutput 能力、且用户 pin 了该插件，三条同时成立才注入（`apps/server/src/modules/Mecha/AgentToolsEngine/index.ts:258-294`）。

结果回流：生成完成输出 `![Generated image N](url)` markdown 标签，加专用渲染组件 `GenerateImage.tsx`/`GetImageGenerationStatus.tsx`（3s 轮询）进入聊天消息。**未找到视频 Agent 工具**（packages 下无 builtin-tool-video-generation，grep 确认）；**未找到 Agent 读取创作历史/工作台历史引用的工具**（媒体历史仅 CommandMenu 全局搜索可见）。

**外部依赖边界**：

- 模型 provider：agent-runtime 提供统一的图像与视频调用接口，包括 createImage、createVideo、handlePollVideoStatus 与 handleCreateVideoWebhook 四个入口；具体 provider 的实现与计费在外部服务
- S3/OSS：FileService 负责上传媒体、删除文件、拼装完整 URL 与从完整 URL 反解 key；关系数据存在 PostgreSQL，经 Drizzle 访问
- sharp 负责图像转码与封面；ffmpeg-static 以子进程完成视频元数据提取和截图（`services/generation/video.ts:24-28,223-285`）；Redis 可选，只用于缓存视频平均延迟（`services/generation/latency.ts:15-20`）；主题标题由 LLM 生成，调用 chatService.fetchPresetTaskResult
- `ssrfSafeFetch`：抓取用户可控 URL 前做 SSRF 防护（`services/generation/index.ts:53-70`，注释引用了 GHSA-53h9-fmjf-frwr）

OSS 快照里计费、配额与完成通知属闭源扩展点：`ENABLE_BUSINESS_FEATURES=false`（`packages/business/const/src/index.ts:7`）时，生成前预扣、生成后结算、免费配额与图像/视频完成通知共五个钩子全部空实现（`packages/business-server/src/{image,video}-generation/`）。

ComfyUI 只作为普通图像 provider 之一出现（透传认证头下载结果图，`async/image.ts:212-228`），服务端没有编排层与自有渲染器。

## 7. 权限、资源边界与失败恢复

- **权限**：写操作统一经 `withScopedPermission` 收口，权限点按 file 与 topic 两组覆盖上传、删除与增删改，由各 lambda 路由分别声明；客户端另以 `usePermission` 门控生成与参考图上传（`PromptInput/index.tsx:140,193`）。

  workspace 作用域由 `buildWorkspaceWhere` 统一实现（`packages/database/src/utils/workspace.ts:40-86`）：
  - personal 模式：`user_id + workspace_id IS NULL`
  - 工作区模式：成员可见 public，private 限 creator；topic 可见性翻转 `setVisibility` 仅 creator（`models/generationTopic.ts:126-146`），工作区外的 `setTopicVisibility` 调用直接拒绝（`routers/lambda/generationTopic.ts:134-166`）；topic 层 `assertWorkspaceRowManageable` 校验同 workspace 归属

  生成文件的可见性继承所属主题（`models/generation.ts:156`），删除权限归主题创建者或工作区所有者（`Item/index.tsx:52,91`）。
- **资源限额**：OSS 快照没有真实计费额度，预扣钩子为空实现。输入侧上限由模型 schema 给出，其中图像数量可在 1 到 8 之间，写在 Agent 工具参数里，参考图的数量与单文件大小由参数控件按 schema 读取；视频下载受 500MB 与 5 分钟约束。轮询与超时上限分别是客户端 30 秒封顶退避、服务端 298 秒 abort、视频后台轮询 120 次 × 5 秒共 600 秒（`manifest.ts:60-64`、`useImageReferenceUpload.ts:39-46`、`generationConfig/hooks.ts`、`services/generation/video.ts:166-221`）。
- **失败恢复**：任务级失败表现为 Error 状态 + 分类错误（可复制）；重跑入口是 reuseSettings/copyPrompt/复制 seed 后手动再生成（recreate 动作无 UI 绑定，见第 5 节）；超时由 `checkTimeoutTasks` 兜底为 Timeout 错误；异步任务在数据库中的状态保证刷新/重启后可继续轮询取回（第 3 节）。

## 8. 设计取舍、已确认边界与未验证事项

### 设计取舍与已确认边界

- **三层对象把"一次请求配置"（batch）与"单张结果"（generation）分开**：batch.config 既是复用设置的来源，也是资产元数据不索引化的容器；generation 保存 seed/asset/文件关联，便于逐张操作（下载/复制 seed/删除）。
- **参考图以 S3 key 入库而非原始 URL**：防过期 presigned URL 污染数据库；读取时再变换回完整 URL。
- **video 双完成路径按 provider 能力分流**：webhook 型（如 Volcengine 注释）走回调，polling 型（如 OpenAI Sora 注释）走服务端后台轮询；客户端统一只认 asyncTask 状态，不感知具体路径。
- **客户端轮询与服务端收口分离**：客户端退避轮询只读状态，超时/错误判定在服务端（checkTimeoutTasks、abort、120 次上限），刷新/重启后以 DB 为权威恢复。
- **OSS 的计费/通知面全部留 stub**：`ENABLE_BUSINESS_FEATURES=false` 时预扣、结算、免费配额、完成通知都不发生；付费工作区行为（error batch 额度拦截、cooldown、退款）只能从路由器调用点与类型推断，无实现可查。
- **本次未找到**：工作台→聊天会话的回流动作（sendToChat 类，grep `sendToChat|toChat|sendGeneration|generationToChat` 全 src 无命中，notify 钩子为空）；用户侧任务取消入口；recreateImage/recreateVideo 的 UI 调用点；视频 Agent 工具；通用图像分支编辑；工作台结果与 Work 对象（独特功能笔记未验证项"image/video 创作工作台与 Work 对象的衔接"——生成结果走 files/asset 体系，`work`/`work_versions` 未见到生成来源的写入点）的关联；async/video.ts 的生产调用者。

### 未验证事项

- 真实模型调用（fal/OpenAI/Volcengine 等 provider 的 createImage/createVideo）、S3 上传下载、PostgreSQL 事务与 webhook 网络往返——标注"未验证：需要真实模型、数据库与网络环境"。
- 计费/配额面全部行为（OSS 为 stub，闭源实现不可查）。
- 视频真实生成时长、后台轮询 120 次上限内的实际完成率、webhook 超时后任务如何收口（webhook 路由无自身超时，任务仍由 checkTimeoutTasks 兜底——静态推断）。
- sharp/ffmpeg-static 在本机的转码/截图输出效果（需运行环境与 ffmpeg 二进制）。
- UI 视觉（网格、进度环、播放器）、键盘可用性与移动端适配（本次未找到 (mobile) 侧的 image/video 路由）。
- 仓库自带单元测试（image/video lambda、async、services/generation、client stores、builtin-tool-image-generation）均未运行——约束禁止安装依赖；文件清单见"关键源码索引"。

## 交接专页（与独特功能笔记的分工）

本页承接 [LobeHub 独特功能调查笔记](../独特功能/LobeHub-独特功能调查笔记.md)（其中 image/video 创作面仅一句"`(create)/image` 与 `/video` 路由族……本次不展开"）。独特功能笔记负责能力盘点与产品叙事，本页负责媒体创作类目视角：

- **三层事实对象与双路由执行**（§1、§2）：topic/batch/generation + asyncTask/files 的对象模型、lambda 事务提交 + async 模型调用、视频 webhook/后台轮询双完成路径——独特功能笔记未展开。
- **客户端轮询与状态收口**（§3）：SWR 指数退避、DB 权威超时、无用户取消。
- **资产命名/去重/来源与封面回写**（§4）：S3 key 规则、globalFiles hash 去重、FileSource、topic 封面自动回写。
- **复用面与 Agent 通道**（§5、§6）：reuseSettings/copySeed/recreate（无 UI 绑定）、builtin-tool-image-generation 4 API 与聊天回流。
- **未验证事项的交接更新**：独特功能笔记"image/video 创作工作台与 Work 对象的衔接"——本次确认无 generation→work 关联（§8）。

## 关键源码索引

- 路由与页面：`src/spa/router/desktopRouter.shared.tsx:672-711`、`src/routes/(main)/(create)/{features,image,video}/`（CreateGenerationPage、GenerationWorkspace、GenerationFeed、GenerationLayout、PromptInput、ConfigPanel、ImageWorkspace、VideoWorkspace、_layout/Sidebar）
- 数据库：`packages/database/src/schemas/generation.ts`、`relations.ts:325-362`、`models/{generationTopic,generationBatch,generation,asyncTask,file}.ts`、`utils/workspace.ts`
- 服务端路由：`apps/server/src/routers/lambda/{image/index.ts,video/index.ts,generation.ts,generationBatch.ts,generationTopic.ts}`、`lambda/video/index.ts`、`routers/async/{image,video,index,caller}.ts`、`apps/server/src/router-hono/webhooks/handlers/video.ts`
- 服务：`apps/server/src/services/generation/{index,video,videoFile,videoBackgroundPolling,latency}.ts`、`services/toolExecution/serverRuntimes/imageGeneration.ts`、`modules/Mecha/AgentToolsEngine/index.ts:258-294`
- 客户端 store：`src/store/image/slices/{createImage,generationBatch,generationConfig,generationTopic}/`、`src/store/video/slices/`（同构；视频轮询动作 `src/store/video/slices/generationBatch/action.ts:146-240`）；客户端服务 `src/services/{image,video,generation,generationBatch,generationTopic}.ts`
- Agent 工具：`packages/builtin-tool-image-generation/src/{manifest,ExecutionRuntime,client/executor,client/Render}.ts(x)`；类型 `packages/types/src/generation/index.ts`、`files/index.ts`；参数 `packages/model-bank/src/standard-parameters/{index,video}.ts`
- 业务占位：`packages/business-server/src/{image,video}-generation/`（chargeBeforeGenerate / chargeAfterGenerate / notify*Completed 等）、`packages/business/const/src/index.ts:7`、`packages/business/config/src/server/route.ts:2`
- 测试文件（未运行）：`apps/server/src/routers/lambda/{image/index.test.ts,image/utils.test.ts,video/error.test.ts}`、`routers/async/__tests__/image.test.ts`、`services/generation/{index,latency,videoBackgroundPolling,videoFile}.test.ts`、`src/store/image|video/slices/*/action|reducer|selectors|hooks*.test.ts*`、`src/routes/(main)/(create)/**/*.test.*`、`packages/builtin-tool-image-generation/src/ExecutionRuntime/index.test.ts` 等
