# Cherry Studio 媒体创作调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`（Electron + React 桌面客户端，v2 架构）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：只读静态源码走读（renderer 绘画页 + main 图像生成/持久化链）；零依赖验证仅限 `node -e` 解析 JSON（package.json、`resources/data/painting-templates/catalog.json`、drizzle 迁移 snapshot）；未安装依赖、未启动应用
>
> 调查范围：绘画工作台主链（能力分型 M1 模型生成工作站 + M3 资产生命周期 + M5 Agent 驱动创作的边界）：入口与触发者、事实对象、参数/参考图/模型能力目录、同步与异步 job 双执行路径、取消/失败/恢复语义、painting/painting_file_ref/file_entry 持久化与清理、预览与复用、generate_image Agent 工具与聊天回流。聊天消息渲染、Agent 工具注册/审批通用机制、LLM 渠道与 provider 模型目录只做交接引用；Mini Program、全局搜索、翻译等其他独特功能不在本页范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的媒体创作是一条**用户主导、模型能力目录驱动、持久化在 v2 文件层之上的图像生成工作站**，能力分型为 **M1 模型生成工作站（主）+ M3 资产生命周期 + M5 Agent 驱动创作（边界）**。单一核心 `AiService.generateImage` 被两条产品面共享，但持久化目标不同：

1. **工作台面**：绘画页 `/app/paintings/*` 会把每次生成写成一行 `painting` 作为冻结收据，记录 provider、model 与 prompt，再挂上 output/input 两种角色的 `painting_file_ref`，文件本体落在 v2 的 `file_entry`。参数、模式、seed 这些可变表单态**不落盘**，只活在渲染进程的内存草稿里，应用退出即丢失。收据行结构与表头注释见 `src/main/data/db/schemas/painting.ts:5-27`。
2. **Agent 面**：`generate_image` 工具（AI-SDK builtin 族 + Claude Code 内置 MCP 桥两个运行时）经 `generateImageFromPrompt` 调用同一核心。与工作台不同，它声明 `cleanupPolicy: 'manual'`，**不写 painting 行、不注册任何 ref**，结果只存在于 tool-call part 的文本结果中（`src/main/ai/tools/painting.ts:186-192` 注释 + #17169 跟踪）。待查清单疑点①确认：是同一生成核心的两条产品面。

图像生成全部在 **main 进程**执行，renderer 只负责参数清洁与编排。普通 provider 与本地 ComfyUI 服务器共用 AI SDK 的 `aiCoreGenerateImage` 同步路径，ComfyUI 由 transport 内部提交任务并轮询；ppio、dashscope 等异步 submit/poll 供应商则交给 `image-generation.generate` job（`src/main/ai/AiService.ts:756-758`，完整供应商清单见第 6 节）。异步 job **非重启持久**，进程崩溃即丢弃（`recovery: 'abandon'`，见 `imageGenerationJobHandler.ts:50-58`）。

待查清单疑点②：**聊天到绘画页存在导航入口**——消息 markdown 内链命中已知路由即渲染为导航条目，Agent 导航工具与侧栏绘画标签构成另外两个入口（`Link.tsx:56-57`、`NavigateTool.tsx:15`，侧栏标签定位见 §1）。**绘画页到聊天的"插入结果"直接入口本次未找到**：painting 目录内没有 sendToTopic 或 insert 调用，Artboard 工具栏只提供多图切换、缩放、旋转与复位（`Artboard.tsx:548-580`）。

## 系统边界与完整主链

### 边界

| 层 | 承担者 | 证据 |
|---|---|---|
| 创作入口 | `/app/paintings/*` splat 路由（非 provider 深链，注释明示，`src/renderer/routes/app/paintings/$.tsx:4-8`）、侧栏绘画标签、聊天内链、Agent 导航工具 | `sidebar.ts:80-82`、`tabIcons.ts:25`、`Link.tsx:56-57` |
| 事实对象 | `PaintingData`（渲染内存草稿）↔ `painting` 行（冻结收据）+ `painting_file_ref` + `file_entry` | `model/types/paintingData.ts`、`schemas/painting.ts`、`fileRelations.ts:92-111` |
| 输入/表单 | 共享 ComposerSurface 管道（聊天同款）、registry 动态参数字段、模型选择器 | `PaintingComposer.tsx:257-307`、`usePaintingModelCatalog.ts` |
| 任务编排 | `usePaintingGenerationSubmit`（validate→materialize→generate）+ `usePaintingGeneration`（create/update 行 + AbortController + 缓存镜像） | `usePaintingGenerationSubmit.ts:68-91`、`usePaintingGeneration.ts:58-147` |
| 执行位置 | main 进程 `AiService.generateImage`；异步供应商走 job 系统 | `AiService.ts:715-846`、`generateImageViaJob` `:860-961` |
| 持久化 | `PaintingService`（CRUD/list/reorder）+ `FileManager.createInternalEntry` + 清理 pass | `PaintingService.ts:101-322`、`docs/dev/references/file/file-entry-cleanup.md` |
| 历史 UI | `PaintingStrip`（缩略图条，滚动分页）+ `usePaintingHistory`（30/页 keyset） | `PaintingStrip.tsx:85-167`、`usePaintingHistory.ts:8-56` |
| Agent 面 | `generate_image` builtin 工具 + Claude Code MCP 桥 + 审批 | `PaintingTool.ts:44-58`、`cherryBuiltinTools.ts:143`、`cherryBuiltinApproval.ts:48` |

### 完整主链（静态走通）

```text
侧栏绘画标签 / 聊天内链 / Agent 导航 -> /app/paintings/*
  -> PaintingPage（PaintingStrip 历史条 + Artboard 画布 + PaintingComposer 输入）
  -> submit（usePaintingGenerationSubmit：守卫 -> validate -> materialize -> generate）
  -> materialize（usePaintingComposerInputFiles：草稿附件 -> file_entry，delete_when_unreferenced）
  -> usePaintingGeneration.generate：createPainting 先落 painting 行（生成前收据）
  -> paintingGenerate -> canonicalGenerate（registry 参数清洁/输入图 data URL 化）
  -> generatePainting -> IPC ai.image.generate（requestId 绑定 AbortController）
  -> main AiService.generateImage
       ├─ 同步：splitParamValues -> WireProfile -> aiCoreGenerateImage -> base64 -> createInternalEntry
       └─ 异步：generateImageViaJob -> job image-generation.generate（submit/poll/download/persist）
  -> 返回 FileEntry[] -> renderer updatePainting 写 painting_file_ref（output/input）
  -> Artboard 预览/缩放/多图切换；PaintingStrip 历史回选/删除；再次生成复用参数
  -> 取消：IPC ai.image.abort -> runImageRequest abort -> SDK signal / job cancel
```

## 1. 创作入口、触发者与事实对象

**入口**：用户主导是唯一完整触发面。侧栏绘画标签（`sidebar.ts:80-82`，routePrefix `/app/paintings`，resolveUrl 拼 `defaultPaintingProvider`）与 splat 路由（捕获该前缀下任意路径，`$.tsx:9-10`，不读通配段，非深链）之外，聊天侧还有三个进入点：

- 消息 markdown 内的链接：命中已知路由就渲染为导航条目，测试用 `/app/paintings?source=assistant` 覆盖这条路径（`Link.tsx:56-57`，测试见 `Link.test.tsx:59`）
- Agent 导航工具的白名单入口（`NavigateTool.tsx:15`）
- home 消息适配器统一的 `navigateToRoute` 跳转（`homeMessageListAdapter.tsx:508-511`）

无插件、定时任务、外部服务触发入口（本次未找到）；Agent 触发面（`generate_image`）见第 6 节。

**事实对象**分两层：

- **活稿对象**：`PaintingData` 只存活在渲染进程内存里，记录本次生成的 id、providerId、mode（generate 或 edit）、prompt、files、params、model、inputFiles 与 generationStatus；提交生成前由 `createPainting` 先把收据行落库（`model/types/paintingData.ts`）。
- **收据行**：`painting` 表保存 id、providerId、modelId、prompt、orderKey 与时间戳，参数、模式、seed 和文件都不在其中——输出与输入文件通过 `painting_file_ref` 的 role（output/input）关联，文件本体在 v2 的 `file_entry` 里（`schemas/painting.ts:16-27`、`fileRelations.ts:92-111`）。这是资产与消息附件分离的关键证据：painting 行独立于会话持久化，聊天回填并不复用这条记录。

## 2. 参数、素材与模型/渲染执行

**模型能力目录**：三层来源合一：

- **provider 列表**：绘画 provider 由模型能力决定，模型带 image-generation capability 或兼容 OpenAI image 端点即可入选；接入 OVMS 本地服务时还要通过 `ovms.is_supported` 与 `ovms.get_status` 两步探测（`paintingModelOptions.ts:25-42`、`usePaintingProviderOptions.ts:30-46`）
- **模型选择器**：统一从 `/models?providerId=X` 取数（`usePaintingModelCatalog.ts:63-77`）
- **registry 支持块**：`imageGenerationSupport` 由 registry 的 image-generation-support 端点按 provider 与 model 返回，声明可用模式、能力标记、prompt 是否必填、最大输入图数量与 vendor transport 类型（读取与端点实现见 `paintingPipeline.ts:60-81`、`models.ts:182`、`ProviderRegistryService.ts:1198`）

Agent 面绘画模型从 `feature.paintings.default_model_id` 偏好解析（`painting.ts:99-110`），与工作台默认草稿同源（`usePaintingDraftDefaults.ts:17-57`），无默认值时回退 `feature.paintings.default_provider`（zhipu）。

**参数清洁**：表单字段由 registry 的 support 块动态生成，提交时按参数 schema 校验并收紧边界：seed 字符串转数字、enum 与 range 取合法值、自定义尺寸合成为「宽x高」、空值丢弃（`PaintingComposer.tsx:134-138`、`canonicalGenerate.ts:78-136`）。main 侧再把参数袋拆成 AI SDK 的 n/size/seed/aspectRatio 与 vendor 专属剩余袋（如 cfg），维持“字节一致 wire”的不变式（`imageOptions.ts:26-40`）。编辑模式必须携带输入图，缺失时报 `EDIT_IMAGE_REQUIRED`；输入图以 data URL 随 IPC 发送，由 main 按 `cleanupPolicy: 'delete_when_unreferenced'` 持久化。

**执行位置**：全部在 main。同步路径 `aiCoreGenerateImage` 用 AI SDK ImageModel 调用，vendor wire 映射走 WireProfile 引擎（`AiService.ts:765-817`，含 `experimental_download` 兜底下载 URL 结果）；异步路径 job handler 拥有 submit/poll/download/persist 循环（`imageGenerationJobHandler.ts:100-137`），密钥不落 job——apiKey 每次执行重读（同文件 :27-30）。渲染侧无任何直连模型代码。

## 3. 任务状态、异步回调与取消

- **状态**：`generationStatus` 取 running、canceled、failed 三值，只存在于页面内存中；同一状态另有一份 Memory 缓存镜像，键为 `painting.generation.${id}`，导航离开再回来可据此重新水合 spinner。painting 行本身没有状态列，收据写入后不再变更（`usePaintingGeneration.ts:88-97`、`PaintingPage.tsx:80-84`）。
- **进度**：同步路径没有进度回调，界面只显示 spinner；异步 job 会通过 `reportProgress` 上报轮询阶段与 100% 完成度，但唯一的消费者是等待 job 结束的那段代码，渲染进程并不轮询，任务中心 UI 本次未找到（`imageGenerationJobHandler.ts:190,136`、`AiService.ts:945`；`useJob` 只被 TranslatePage 消费，见 `TranslatePage.tsx:81`）。
- **取消**：一次取消会沿全链路向下传导，逐层生效：
  1. renderer 的 AbortController 经 IPC `ai.image.abort` 通知 main（`generatePainting.ts:43`、`ai.ts:152-154`）
  2. main 的 `runImageRequest` 在请求注册表中找到并中止对应请求（`AiService.ts:715-731`）
  3. 到达 SDK 的 abortSignal，或由 job 的 `jobManager.cancel` 取消任务；job 取消时还会调用 `transport.cancel` 撤销已提交的远程任务（`AiService.ts:937-941`、`imageGenerationJobHandler.ts:179-197`）

  取消完成后状态折叠为 canceled，界面不弹错误提示（`usePaintingGeneration.ts:131-141`）。
- **失败**：provider 或 SDK 抛出的错误先由 `exposeAiError` 包成带序列化详情的 IpcError，renderer 侧 `runPainting` 从中还原 HTTP 状态与响应体片段等真实原因，最终以 REMOTE_ERROR 模态提示用户（`ai.ts:39-53`、`runPainting.ts:69-83`，模态定义见 `errors/paintingGenerateError.ts`）。
- **重启/重试**：job 声明 `recovery: 'abandon'` 与 `maxAttempts: 1`，防止重启后再提交一次造成重复计费；生成过程中崩溃的任务会被直接丢弃，重启恢复路径本次未找到（`imageGenerationJobHandler.ts:32-58`）。这一点与 Chatbox 依靠 taskId 恢复的行为相反。用户侧重试就是改参后重新生成，没有 taskId 概念。

## 4. 结果、历史、资产与工程持久化

- **写链**：生成开始前先由 `createPainting` 写入收据行，该调用同时判定是否新建记录；成功后 renderer 补上 output/input 两组文件。随后 `PaintingService` 一次性全量替换该 painting 的 `painting_file_ref`，外键按双级联处理。v1→v2 过渡期产生的无效文件 id 在建 ref 时被静默过滤并记录日志（`usePaintingGeneration.ts:76-124`、`PaintingService.ts:246-394`）。
- **命名/去重**：文件由 FileManager 生成 v2 FileEntry，主键为 uuid，内容级去重本次未找到；painting 行按 orderKey 排序，分页采用 keyset 并附带总数（`PaintingService.ts:102-145`）。
- **清理**：`painting_file_ref` 为文件提供保护引用；删除 painting 时外键级联清掉对应 ref，之后的清理 pass 按 `delete_when_unreferenced` 与 1 小时 grace 回收孤儿文件（`:114,133`）。草稿附件不落库，materialize 与 painting 行、input ref 落在同一事务窗口内（`:83`），文件的持久化时机与拥有它的对象同步（清理语义见 `docs/dev/references/file/file-entry-cleanup.md`）。
- **迁移**：v2 `PaintingMigrator` 把 Redux 历史迁入 SQLite（重复 id 重写、悬空 ref 丢弃计数、`markEntriesAutoCleanup` 标记，`PaintingMigrator.ts:54-249`）。
- **来源关联**：painting 行无 parent 列（对比 Chatbox 的 parentIds DAG）；"再次创作"只通过草稿复制/历史回选，无显式分支树。Agent 生成的结果无任何持久化关联（见第 6 节）。

## 5. 预览、编辑、重试、分支与复用

- **预览**：结果展示在 Artboard 画布上，画布负责 contain-fit 测量、顶部 prompt 条与 reveal 动画，生成期间用骨架屏占位；一次生成多张图时出现 prev/next 切换按钮。历史缩略图条由 PaintingStrip 承担，滚动到底部触发加载更多（`Artboard.tsx:469-584`、`PaintingStrip.tsx:98-110`）。
- **编辑**：裁剪与局部重绘这类像素级编辑本次未找到；页面上的"编辑"是换模型、改 prompt 或换参考图后再生成一次。参考图上传复用 composer 的统一附件管道，接受 `image/*` 类型的文件（`PaintingImageGallery.tsx:24-127`、`PaintingComposer.tsx:44-49`）。
- **重试**：界面没有"重试上一次"按钮，重新提交就产生一次新请求；失败面板展示 REMOTE_ERROR 的具体原因，切换模型时参数草稿保留，`usePaintingModelSwitch` 只在图片能力不兼容时清空（`usePaintingModelSwitch.ts:47-49`、`errors/paintingGenerateError.ts`）。
- **分支**：没有显式分支；多条 painting 是彼此平行的收据，`select` 在历史条目间切换，切换前先用 `saveCurrent` 保存当前草稿（`usePaintingList.ts:47-70`）。
- **复用**：回选历史条目时，`recordToPaintingData` 把 prompt、模型与参考图水合回草稿；后台完成的生成由 `usePaintingResultSync` 自动回填到当前可见草稿（`usePaintingHistory.ts:33-47`、`usePaintingResultSync.ts:32-49`）。**导出**：绘画页专用的下载按钮本次未找到，工具栏只有切换、缩放、旋转与复位，文件可在 Files 页管理，这是沿用 v1 的管理习惯（`file-entry-cleanup.md:96`）。**聊天插入**：未找到直接入口（见结论摘要疑点②）。

## 6. Agent 回流、插件与外部依赖

**Agent 面**：generate_image 工具同时注册进 AI-SDK builtin 族与 Claude Code 内置 MCP 桥两个运行时，两者共用同一份核心实现（注册入口见 `registerBuiltinTools.ts:34`、`cherryBuiltinTools.ts:143`）。是否可用由两道门控制：聊天 composer 工具栏的 `assistant.settings.enableGenerateImage` 开关，以及全局 `feature.paintings.default_model_id` 指定的默认模型；开关在没有可用绘画模型时禁用（UI 见 `generateImageTool.tsx:21-52`）。其余行为要点：

- **schema 与失败**：工具 schema 随模型 support 动态构建，包含 enum/range/size 约束、prompt 1-4000 字符与 image_ids 至多 1 个；生成失败时工具把 `{error}` 文本交回模型，并按可重试与不可重试两类分流（`generateImageTool.ts:104-156`、`painting.ts:54-72`）
- **结果回流**：`paintingModelOutput` 把结果整理成一行文本，每项形如「文件名 (id)」，再写回 tool-call part；generate_image 同时在审批名单中（`painting.ts:88-97`、`cherryBuiltinApproval.ts:48`）
- **已有资产引用**：调用方可以传 `image_ids`（FileEntry id）作为编辑参考图，工具据此从 FileManager 读回 base64；Agent 侧读取 painting 行的工具本次未找到，历史条只出现在绘画页 UI（`painting.ts:144-153`）

**本地 ComfyUI 供应商**：ComfyUI 作为一等图像供应商接入，是 AI SDK Provider V3 的一种，适配器族标识为 `comfyui`，默认地址 `http://localhost:8188`。它走自己的节点图 HTTP API：提交任务走 `/prompt`，轮询取结果走 `/history`，队列查询与用户工作流读取共用同一套接口。这条路径复用同步生成，由 transport 内部提交任务并轮询历史取结果，不进入异步 job 系统。模型来自用户服务器上的工作流：发现阶段读取工作流列表，提交前把 UI 格式工作流转换成 API prompt。该供应商只服务图像生成，chat 与 embedding 工厂直接抛错，避免把聊天请求打到只返回网页的服务器。

**外部依赖**：无 FFmpeg/自有渲染器/文件 CDN。依赖面为：模型 provider API（AI SDK，同步）+ 异步供应商 submit/poll 端点（ppio/dashscope/modelscope/dmxapi-bespoke）+ 可选本地 ComfyUI 服务器与 OVMS 本地图像服务（`ovms.*` IPC）+ 本地 SQLite/FileEntry 存储。`downloadImageAsBase64` 兜底下载 URL 结果（`AiService.ts:790-803`、`imageGenerationJobHandler.ts:210`）。

## 7. 权限、资源边界与失败恢复

- **凭据/权限**：provider 与模型管理沿用 LLM 渠道类目，细节见对应笔记；绘画工具的调用经过审批链；绘画代码只通过 FileEntry 抽象读写文件，没有专用的文件系统直写通道（`cherryBuiltinApproval.ts`）。
- **限额**：
  - job：超时 30 分钟、并发 2/queue、`maxAttempts: 1`（防重复计费，`imageGenerationJobHandler.ts:52-58`）
  - 工具：prompt ≤ 4000 字符、image_ids ≤ 1（`generateImageTool.ts:10-16`）
  - 工作台：输入图上限按模型 support `maxInputImages`（`canonicalGenerate.ts:74-77`）
  - IPC：job 载荷上限为 1MB，输入图改以 FileEntry id 引用，避开把图片本体塞进 payload（`imageGenerationJobHandler.ts:29-30,884-887`）
- **清理保护**：`delete_when_unreferenced` 只回收在 5 张 ref 表里都查不到引用的 file_entry；`manual` 策略的文件永不自动回收，Agent 输出就属于这一类，见第 6 节（`fileRelations.ts:235-239`）。
- **失败恢复**：取消会中止请求并撤销 job 的远程任务；进程崩溃后 job 被丢弃（abandon）；收据行与文件引用分离，已完成的生成结果得以持久。

## 8. 当前创作与文档处理补充

截图能力已具备选择框、标注和 OCR 主链：覆盖层采集用户选择，截图结果可作为输入内容继续进入会话。PDF 翻译使用 BabelDOC 保留版式，翻译结果会写入历史和文件管理器，资源下载过程另有进度反馈。两者分别是输入采集与文档生成/管理路径，本次确认的媒体能力即这两条；通用视频、音频或画布编辑器存在与否需另行核查。

本次未运行 OCR 质量、BabelDOC 下载、翻译成功率或跨平台屏幕捕获。依据：`src/main/services/screenshot/ScreenshotOverlayService.ts`、`src/renderer/windows/screenshot/ScreenshotApp.tsx`、`src/main/services/PdfTranslationService.ts`、`src/renderer/pages/translate/pdf/PdfTranslationView.tsx`。

图像生成的 Provider 面新增 TokenHub `/v1/wand` transport，并继续复用统一的 registry 参数、main 进程执行与 FileEntry 结果链。自动重试在图像生成入口被关闭，避免一次用户提交因通用重试机制重复计费；编辑参考图进入 provider 前会先经 Sharp 归一化，HDR 与旋转元数据由同一入口处理。依据：`src/main/ai/provider/custom/tokenhub/tokenhubTransport.ts`、`src/main/ai/AiService.ts:802`、`src/main/ai/utils/normalizeImageEditInputs.ts:1-23`。

## 9. 设计取舍、已确认边界与未验证事项

### 设计取舍与已确认边界

- **收据行不存参数**：painting 行只冻结 provider/model/prompt，可变表单态留在渲染内存——重启后参数丢失、只留收据与文件（`schemas/painting.ts:5-15` 注释）。这是"结果持久化"与"草稿持久化"的明确分界。
- **两条产品面共享核心**：工作台（delete_when_unreferenced + painting_file_ref）与 Agent 工具（manual + 无 ref）持久化语义相反，Agent 结果一旦删除聊天消息即失去引用（#17169 未闭合）；两者无交叉——Agent 结果不进入绘画历史，绘画历史不暴露给 Agent。
- **job 不重启持久**：注释给出了改为 restart-durable 的具体路径（payload 携带 painting.id 让 handler 直接写结果），当前未实现（`imageGenerationJobHandler.ts:42-49`）。
- **取消是全链路**：IPC abort → SDK signal / job cancel → transport 远程撤销，比"停止监视"（Chatbox）更进一步；但工作台侧"取消后重跑"没有任务 id 取回语义。
- **无显式分支/版本/像素编辑/任务中心 UI/绘画→聊天插入**：本次均未找到（搜索依据：painting 目录 grep sendToTopic/insert 无结果；`useJob` 消费者仅 TranslatePage；Artboard 工具栏按钮枚举 `Artboard.tsx:548-580`）。
- **OVMS 门控**：本地图像服务（ovms）作为绘画 provider 候选被纳入，其可达性经 IPC 探测（`usePaintingProviderOptions.ts:30-46`），属于外部依赖边界而非内置渲染器。

### 运行验证

- 零依赖：`node -e` 解析 package.json（CherryStudio 2.0.3，electron/react/drizzle/ai-sdk 声明齐全）、`resources/data/painting-templates/catalog.json`（25 个模板 id，有效 JSON）、`migrations/sqlite-drizzle/meta/0006_snapshot.json`（painting/painting_file_ref 表在快照中）——均通过。
- 未运行：真实模型生成（同步与异步供应商）、job 提交/轮询/取消的真实时序、崩溃重启行为、UI 视觉效果/键盘可用性、清理 pass 实际回收、v1→v2 迁移实测。标注"未验证：需要真实模型与图形环境"。

### 未验证事项

- 真实模型生成与计费（各 provider 与 OVMS）——未验证：需要真实模型与图形环境。
- job 系统在真实轮询/取消/超时下的行为，以及 `recovery: 'abandon'` 的启动取消时序。
- 清理 pass 对 painting 删除后文件的实际回收（1h grace 语义仅静态确认）。
- Artboard/模板 showcase 的视觉效果、缩放拖动、多图 reveal 动画（`Artboard.test.tsx` 组件测试覆盖状态机，UI 视觉未运行）。
- 聊天 markdown 内链 → 绘画页导航的端到端行为、`source`/`prompt` query 的实际消费（`PaintingPage` 未读 URL 参数，仅 `usePaintingInitialDraft` 用偏好；query 消费本次未确认）。
- v2 迁移实测（PaintingMigrator 大批量历史、重复 id 重写）。
- Agent `generate_image` 在真实模型下的工具 schema 解析与编辑参考图行为。

## 交接专页（与独特功能笔记的分工）

[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)覆盖 Mini Program、全局搜索、翻译与归并项（多模型对话、文档处理、Agent workspace），**未覆盖绘画页**——绘画页证据由本页与 [媒体创作横向对比](媒体创作横向对比.md) 候选样本条目承接。本页补充独特功能体系之外的内容：

- 绘画工作台主链（入口/参数/执行/持久化/复用，§1-§5）与 `AiService.generateImage` 双执行路径（同步 AI SDK vs 异步 job）。
- 工作台（painting 行 + ref）与 Agent 工具（cleanupPolicy manual 无 ref）两条产品面的持久化差异（§4、§6）。
- v2 文件层引用语义、清理 pass、PaintingMigrator 迁移（§4、§7）。
- 待查清单疑点②（聊天↔绘画页插入/导航入口）结论（§5、结论摘要）。

独特功能笔记的 Mini Program/全局搜索/翻译及 Agent workspace 交接结论不在本页范围，不重复抄写。

## 关键源码索引

- 入口与页面：`src/renderer/routes/app/paintings/$.tsx`、`paintings.index.tsx`、`src/renderer/pages/paintings/PaintingPage.tsx`、`paintingPrimitives.ts`、`src/renderer/utils/sidebar.ts:80-82`、`tabIcons.ts:25`
- 表单与输入：`components/PaintingComposer.tsx`、`PaintingImageGallery.tsx`、`hooks/usePaintingComposerInputFiles.ts`（materialize:188-247）、`hooks/usePaintingGenerationSubmit.ts:68-91`
- 生成编排：`hooks/usePaintingGeneration.ts`（generate:58-147）、`model/paintingPipeline.ts`、`model/canonicalGenerate.ts`、`model/generatePainting.ts`（IPC:40-79）、`model/runPainting.ts`
- 历史与复用：`hooks/usePaintingHistory.ts`、`usePaintingList.ts`、`usePaintingResultSync.ts`、`components/PaintingStrip.tsx`、`Artboard.tsx`
- 模型能力目录：`hooks/usePaintingModelCatalog.ts`、`usePaintingProviderOptions.ts`、`model/utils/paintingModelOptions.ts`、`hooks/usePaintingDraftDefaults.ts`、`hooks/usePaintingTemplateCatalog.ts`
- main 执行：`src/main/ai/AiService.ts`（runImageRequest:715、generateImage:733、generateImageViaJob:860）、`src/main/ai/utils/imageOptions.ts`、`src/main/ipc/handlers/ai.ts:150-154`
- 异步 job：`src/main/ai/provider/custom/tasks/imageGenerationJobHandler.ts`、`jobTypes.ts`
- 本地 ComfyUI：`src/main/ai/provider/custom/comfyui/{comfyuiProvider,comfyuiTransport,comfyuiWorkflowDiscovery,uiToApiPrompt}.ts`、`packages/provider-registry/src/providers/comfyui.ts`
- 持久化：`src/main/data/services/PaintingService.ts`、`src/main/data/db/schemas/painting.ts`、`fileRelations.ts:92-141,214-239`、`src/main/data/migration/v2/migrators/PaintingMigrator.ts`
- Agent 面：`src/main/ai/tools/painting.ts`、`tools/generateImageTool.ts`、`tools/adapters/aiSdk/builtin/PaintingTool.ts`、`registerBuiltinTools.ts:34`、`src/main/ai/mcp/servers/cherryBuiltinTools.ts:143`、`cherryBuiltinApproval.ts:48`、`src/renderer/components/composer/tools/definitions/generateImageTool.tsx`
- 清理与文档：`docs/dev/references/file/file-entry-cleanup.md`（§1、§5.1）
- 偏好：`src/shared/data/preference/preferenceSchemas.ts:396`（feature.paintings.default_model_id）、`src/renderer/hooks/useModel.ts:34`
