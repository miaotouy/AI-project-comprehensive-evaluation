# Cherry Studio 媒体创作调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`（Electron + React 桌面客户端，v2 架构）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`88cfe5dd2b77e63464be22968f66ebcb1d429483`（分支：`main`）
>
> 调查方式：只读静态源码走读（renderer 绘画页 + main 图像生成/持久化链）；零依赖验证仅限 `node -e` 解析 JSON（package.json、`resources/data/painting-templates/catalog.json`、drizzle 迁移 snapshot）；未安装依赖、未启动应用
>
> 调查范围：绘画工作台主链（能力分型 M1 模型生成工作站 + M3 资产生命周期 + M5 Agent 驱动创作的边界）：入口与触发者、事实对象、参数/参考图/模型能力目录、同步与异步 job 双执行路径、取消/失败/恢复语义、painting/painting_file_ref/file_entry 持久化与清理、预览与复用、generate_image Agent 工具与聊天回流。聊天消息渲染、Agent 工具注册/审批通用机制、LLM 渠道与 provider 模型目录只做交接引用；Mini Program、全局搜索、翻译等其他独特功能不在本页范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 的媒体创作是一条**用户主导、模型能力目录驱动、持久化在 v2 文件层之上的图像生成工作站**，能力分型为 **M1 模型生成工作站（主）+ M3 资产生命周期 + M5 Agent 驱动创作（边界）**。单一核心 `AiService.generateImage` 被两条产品面共享，但持久化目标不同：

1. **工作台面**：绘画页 `/app/paintings/*` 把每次生成写成 `painting` 行（冻结收据：provider/model/prompt，`src/main/data/db/schemas/painting.ts:16-27`）+ `painting_file_ref`（output/input 角色）+ v2 `file_entry` 文件行；参数/模式/seed 等可变表单态**不落盘**，只活在渲染进程内存草稿里，应用退出即弃（`painting.ts:5-15` 注释明示）。
2. **Agent 面**：`generate_image` 工具（AI-SDK builtin 族 + Claude Code 内置 MCP 桥两个运行时）经 `generateImageFromPrompt` 调用同一核心。与工作台不同，它声明 `cleanupPolicy: 'manual'`，**不写 painting 行、不注册任何 ref**，结果只存在于 tool-call part 的文本结果中（`src/main/ai/tools/painting.ts:186-192` 注释 + #17169 跟踪）。待查清单疑点①确认：是同一生成核心的两条产品面。

执行位置全部在 **main 进程**（renderer 只做参数清洁与编排）：普通 provider 走 AI SDK `aiCoreGenerateImage` 同步生成；ppio、dashscope 等异步 submit/poll 供应商走 `image-generation.generate` job（`src/main/ai/AiService.ts:756-758`、`src/main/ai/provider/custom/tasks/imageGenerationJobHandler.ts`，完整供应商清单见第 6 节）。异步 job **非重启持久**，崩溃即弃（`recovery: 'abandon'`，`imageGenerationJobHandler.ts:50-58`）。

待查清单疑点②：**聊天 → 绘画页有导航入口**（消息 markdown 内链经 `isKnownNavigationPath` 渲染为导航条目 `Link.tsx:56-57`、Agent 导航工具 `NavigateTool.tsx:15`、侧栏标签 `sidebar.ts:80-82`）；**绘画页 → 聊天"插入结果"直接入口本次未找到**（painting 目录无 sendToTopic/insert 调用；Artboard 工具栏只有多图切换/缩放/旋转/复位，`Artboard.tsx:548-580`）。

## 系统边界与完整主链

### 边界

| 层 | 承担者 | 证据 |
|---|---|---|
| 创作入口 | `/app/paintings/*` splat 路由（非 provider 深链，注释明示，`src/renderer/routes/app/paintings/$.tsx:4-8`）、侧栏绘画标签、聊天内链、Agent 导航工具 | `sidebar.ts:80-82`、`tabIcons.ts:25`、`Link.tsx:56-57` |
| 事实对象 | `PaintingData`（渲染内存草稿）↔ `painting` 行（冻结收据）+ `painting_file_ref` + `file_entry` | `model/types/paintingData.ts`、`schemas/painting.ts`、`fileRelations.ts:92-111` |
| 输入/表单 | 共享 ComposerSurface 管道（聊天同款）、registry 动态参数字段、模型选择器 | `PaintingComposer.tsx:257-307`、`usePaintingModelCatalog.ts` |
| 任务编排 | `usePaintingGenerationSubmit`（validate→materialize→generate）+ `usePaintingGeneration`（create/update 行 + AbortController + 缓存镜像） | `usePaintingGenerationSubmit.ts:68-91`、`usePaintingGeneration.ts:58-147` |
| 执行位置 | main 进程 `AiService.generateImage`；异步供应商走 job 系统 | `AiService.ts:715-846`、`generateImageViaJob` `:860-961` |
| 持久化 | `PaintingService`（CRUD/list/reorder）+ `FileManager.createInternalEntry` + 清理 pass | `PaintingService.ts:101-322`、`docs/references/file/file-entry-cleanup.md` |
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

**入口**：用户主导是唯一完整触发面。侧栏绘画标签（`sidebar.ts:80-82`，routePrefix `/app/paintings`，resolveUrl 拼 `defaultPaintingProvider`）与 splat 路由（捕获任意 `/app/paintings/*`，`$.tsx:9-10`，不读 `$` 段，非深链）之外，聊天侧还有三个进入点：

- 消息 markdown 中已知路由链接渲染为导航条目（`Link.tsx:56-57`，测试用例 `Link.test.tsx:59` 用 `/app/paintings?source=assistant`）
- Agent 导航工具白名单（`NavigateTool.tsx:15`）
- home 消息适配器通用 `navigateToRoute`（`homeMessageListAdapter.tsx:508-511`）

无插件、定时任务、外部服务触发入口（本次未找到）；Agent 触发面（`generate_image`）见第 6 节。

**事实对象**分两层：

- **活稿 `PaintingData`**（`model/types/paintingData.ts`）：字段为 `id/providerId/mode(generate|edit)/prompt/files/params(Record)/model/inputFiles/generationStatus`。全在渲染进程内存；生成前由 `createPainting` 落收据行。
- **收据行 `painting`**（`schemas/painting.ts:16-27`）：字段为 `id/providerId/modelId/prompt/orderKey/timestamps`，**无 params/mode/seed/文件列**——输出与输入文件全在 `painting_file_ref`（`role` 取 output/input，`fileRelations.ts:92-111`），文件本体在 v2 `file_entry`（`file.ts`）。这是"资产不是消息附件"的关键证据：painting 行独立于会话持久化，聊天回填不是它的投影。

## 2. 参数、素材与模型/渲染执行

**模型能力目录**：三层来源合一：

- **provider 列表**：`usePaintingProviderOptions` 按能力推导——模型带 `image-generation` capability 或 OpenAI image 端点（`paintingModelOptions.ts:25-42`）；OVMS 本地服务需 `ovms.is_supported/get_status` 门（`usePaintingProviderOptions.ts:30-46`）
- **模型选择器**：从统一 `/models?providerId=X` 取数（`usePaintingModelCatalog.ts:63-77`）
- **registry 支持块**：`imageGenerationSupport`（字段 `modes/supports/requirePrompt/maxInputImages/vendorTransport`）经 `GET /providers/:providerId/models/:modelId*/image-generation-support` 提供（`paintingPipeline.ts:60-81`、`models.ts:182`、`ProviderRegistryService.ts:1198`）

Agent 面绘画模型从 `feature.paintings.default_model_id` 偏好解析（`painting.ts:99-110`），与工作台默认草稿同源（`usePaintingDraftDefaults.ts:17-57`），无默认值时回退 `feature.paintings.default_provider`（zhipu）。

**参数清洁**：表单字段由 `imageGenerationToFields` 从 registry support 动态生成（`PaintingComposer.tsx:134-138`）。提交时 `canonicalGenerate` 用 `buildParamsSchema` 校验并强制边界——seed 字符串转数字、enum/range 边界、`customSize` 合成 `WxH`、空值丢弃。main 侧 `splitParamValues` 把参数袋拆成 AI SDK 结构化字段（n/size/seed/aspectRatio）与 vendor 剩余袋（cfg 等），保持“字节一致 wire”不变式（`imageOptions.ts:26-40`）。编辑模式（非 generate）强制要求输入图（`EDIT_IMAGE_REQUIRED`）；输入图以 `data:` URL 随 IPC 发送，main 按 `cleanupPolicy: 'delete_when_unreferenced'` 持久化（`canonicalGenerate.ts:78-136`、`generatePainting.ts:54`）。

**执行位置**：全部在 main。同步路径 `aiCoreGenerateImage` 用 AI SDK ImageModel 调用，vendor wire 映射走 WireProfile 引擎（`AiService.ts:765-817`，含 `experimental_download` 兜底下载 URL 结果）；异步路径 job handler 拥有 submit/poll/download/persist 循环（`imageGenerationJobHandler.ts:100-137`），密钥不落 job——apiKey 每次执行重读（同文件 :27-30）。渲染侧无任何直连模型代码。

## 3. 任务状态、异步回调与取消

- **状态**：`generationStatus`（running/canceled/failed 三值）是页面内存态，另有 Memory 缓存镜像 `painting.generation.${id}`——导航离开再回来可重水合 spinner（`usePaintingGeneration.ts:88-97`）。`painting` 行本身无状态列，收据冻结（`PaintingPage.tsx:80-84` 注释）。
- **进度**：同步路径无进度回调，只有 spinner；异步 job 有 `reportProgress`（poll stage + 100%，`imageGenerationJobHandler.ts:190,136`），但唯一消费者只是等待 job 结束（`AiService.ts:945`），渲染进程无轮询——任务中心 UI 本次未找到（`useJob` 仅被 TranslatePage 消费，`TranslatePage.tsx:81`）。
- **取消**：取消沿全链路传导：
  1. renderer 的 AbortController 经 IPC `ai.image.abort`（`generatePainting.ts:43`、`ai.ts:152-154`）
  2. `runImageRequest` 注册表中止请求（`AiService.ts:715-731`）
  3. AI SDK abortSignal / job 的 `jobManager.cancel`（`AiService.ts:937-941`）；job 取消会顺带调 `transport.cancel` 撤远程任务（`imageGenerationJobHandler.ts:179-197`）

  取消结果折叠为 'canceled' 且不弹错误（`usePaintingGeneration.ts:131-141`）。
- **失败**：provider/SDK 错误经 `exposeAiError` 包成带序列化详情的 IpcError（`ai.ts:39-53`），renderer `runPainting` 恢复真实原因（HTTP 状态/响应体片段，`runPainting.ts:69-83`），用户面 REMOTE_ERROR 模态（`paintingGenerateError.ts`）。
- **重启/重试**：job 明确 `recovery: 'abandon'` 且 `maxAttempts: 1`（防重启后二次提交重复计费，注释详尽，`imageGenerationJobHandler.ts:32-58`）——**生成中崩溃即丢弃，本次未找到重启恢复路径**（与 Chatbox 的 taskId 恢复语义相反）。用户侧重试即改参再次生成（无 taskId 概念）。

## 4. 结果、历史、资产与工程持久化

- **写链**：生成前先 `createPainting` 落收据行（`usePaintingGeneration.ts:76-86`，`shouldCreate` 判定新建 vs 更新）。成功后 `updatePainting` 写 `files:{output,input}`（同文件 :119-124）。`PaintingService` 随后全量替换 `painting_file_ref`（`PaintingService.ts:246-257`，FK 双级联）。v1→v2 过渡期的无效文件 id 由 `buildPaintingRefRowsFiltered` 静默过滤并记日志（同文件 :339-394）。
- **命名/去重**：文件由 FileManager 生成 v2 FileEntry（uuid 主键），无内容级去重（本次未找到）；painting 行 orderKey 排序（`PaintingService.ts:102-145` keyset 分页 + total）。
- **清理**：清理语义见 `docs/references/file/file-entry-cleanup.md`——`painting_file_ref` 提供保护引用；`painting` 删除经 FK 级联删 ref，随后清理 pass（`delete_when_unreferenced` + 1h grace，`:114,133`）回收孤儿文件。**材质化时机=拥有对象持久化时机**：草稿期不落库，materialize 与 painting 行 + input ref 同事务窗（`:83`）。
- **迁移**：v2 `PaintingMigrator` 把 Redux 历史迁入 SQLite（重复 id 重写、悬空 ref 丢弃计数、`markEntriesAutoCleanup` 标记，`PaintingMigrator.ts:54-249`）。
- **来源关联**：painting 行无 parent 列（对比 Chatbox 的 parentIds DAG）；"再次创作"只通过草稿复制/历史回选，无显式分支树。Agent 生成的结果无任何持久化关联（见第 6 节）。

## 5. 预览、编辑、重试、分支与复用

- **预览**：`Artboard` 画布（contain-fit 测量、prompt 条、reveal 动画机，`Artboard.tsx:469-584`）+ `PaintingImageSkeleton`（生成中骨架）；多图时显示 prev/next 切换按钮；`PaintingStrip` 历史缩略图条（滚动加载 `loadMore`，`PaintingStrip.tsx:98-110`）。
- **编辑**：无像素级编辑（裁剪/局部重绘本次未找到）；"编辑"= 换模型/改 prompt/换参考图再次生成。参考图上传走统一 composer 附件管道（`PaintingImageAddButton`/`PaintingImageGallery`，`PaintingImageGallery.tsx:24-127`），仅 `image/*` 扩展（`PaintingComposer.tsx:44-49`）。
- **重试**：无"重试上一次"按钮语义——重新提交即新请求；失败面板给出 REMOTE_ERROR 原因（`errors/paintingGenerateError.ts`）。模型切换保留参数草稿（`usePaintingModelSwitch` 只处理图片能力不兼容清空，`usePaintingModelSwitch.ts:47-49`）。
- **分支**：无显式分支；多条 painting = 平行收据，`select` 在历史间切换（`usePaintingList.ts:62-70`），切换前 `saveCurrent` 保当前草稿（`:47-60`）。
- **复用**：历史回选载入 prompt/模型/参考图（`recordToPaintingData` 水合，`usePaintingHistory.ts:33-47`）；`usePaintingResultSync` 把后台完成的输出回填到可见草稿（`usePaintingResultSync.ts:32-49`）。**导出**：本次未找到绘画页专用下载按钮（工具栏只有切换/缩放/旋转/复位）；文件可从 Files 页管理（v1 习惯，`file-entry-cleanup.md:96`）。**聊天插入**：未找到（见结论摘要疑点②）。

## 6. Agent 回流、插件与外部依赖

**Agent 面**：`generate_image` 工具经 `registerBuiltinTools.ts:34` 进 AI-SDK builtin 族、`cherryBuiltinTools.ts:143` 进 Claude Code 内置 MCP 桥——两运行时共用 `painting.ts` 核心，受两道门控制：聊天 composer 工具栏的 `assistant.settings.enableGenerateImage` 开关（无绘画模型时禁用，`generateImageTool.tsx:21-52`）与全局 `feature.paintings.default_model_id` 默认模型。其余行为要点：

- **schema 与失败**：工具 schema 从模型 support 动态构建（enum/range/size 约束、prompt 1-4000 字符、image_ids ≤ 1，`generateImageTool.ts:104-156`）；失败返回 `{error}` 提示词而非抛出，并按可重试/不可重试分流（`painting.ts:54-72`）
- **结果回流**：经 `paintingModelOutput` 转成一行文本（`文件名 (id)` 列表）回 tool-call part（`painting.ts:88-97`）；`cherryBuiltinApproval.ts:48` 表明 generate_image 在审批名单
- **已有资产引用**：可传 `image_ids`（FileEntry id）做编辑参考，`painting.ts:144-153` 从 FileManager 读回 base64；但 Agent 无 painting 行读取工具（本次未找到——历史条只在绘画页 UI）

**外部依赖**：无 ComfyUI/FFmpeg/自有渲染器/文件 CDN。依赖面为：模型 provider API（AI SDK，同步）+ 异步供应商 submit/poll 端点（ppio/dashscope/modelscope/dmxapi-bespoke）+ 可选 OVMS 本地图像服务（`ovms.*` IPC）+ 本地 SQLite/FileEntry 存储。`downloadImageAsBase64` 兜底下载 URL 结果（`AiService.ts:790-803`、`imageGenerationJobHandler.ts:210`）。

## 7. 权限、资源边界与失败恢复

- **凭据/权限**：provider 与模型管理走 LLM 渠道类目（交接，不重复）；绘画工具经审批链（`cherryBuiltinApproval.ts`）；无绘画专用文件系统直写（FileEntry 抽象）。
- **限额**：
  - job：超时 30 分钟、并发 2/queue、`maxAttempts: 1`（防重复计费，`imageGenerationJobHandler.ts:52-58`）
  - 工具：prompt ≤ 4000 字符、image_ids ≤ 1（`generateImageTool.ts:10-16`）
  - 工作台：输入图上限按模型 support `maxInputImages`（`canonicalGenerate.ts:74-77`）
  - IPC：请求体 1MB job 载荷上限（输入图以 FileEntry id 引用规避，`imageGenerationJobHandler.ts:29-30,884-887`）
- **清理保护**：`delete_when_unreferenced` 仅回收无任何持久 ref 的 file_entry（5 张 ref 表联合 NOT EXISTS，`fileRelations.ts:235-239`）；`manual` 策略文件永不自动回收（Agent 输出，见第 6 节）。
- **失败恢复**：取消=中止请求+job 远程撤销；崩溃后 job 丢弃（abandon）；收据行与文件引用分离保证已完成的生成结果持久。

## 8. 当前创作与文档处理补充

截图能力已具备选择框、标注和 OCR 主链：覆盖层采集用户选择，截图结果可作为输入内容继续进入会话。PDF 翻译使用 BabelDOC 保留版式，翻译结果会写入历史和文件管理器，资源下载过程另有进度反馈。两者分别是输入采集与文档生成/管理路径，不能据此推断通用视频、音频或画布编辑器已经存在。

本次未运行 OCR 质量、BabelDOC 下载、翻译成功率或跨平台屏幕捕获。依据：`src/main/services/screenshot/ScreenshotOverlayService.ts`、`src/renderer/windows/screenshot/ScreenshotApp.tsx`、`src/main/services/PdfTranslationService.ts`、`src/renderer/pages/translate/pdf/PdfTranslationView.tsx`。

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

[独特功能调查笔记](../独特功能/Cherry-Studio-独特功能调查笔记.md)（快照同为 `cd82f996`）覆盖 Mini Program、全局搜索、翻译与归并项（多模型对话、文档处理、Agent workspace），**未覆盖绘画页**——绘画页证据由本页与 [媒体创作横向对比](媒体创作横向对比.md) 候选样本条目承接。本页补充独特功能体系之外的内容：

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
- 持久化：`src/main/data/services/PaintingService.ts`、`src/main/data/db/schemas/painting.ts`、`fileRelations.ts:92-141,214-239`、`src/main/data/migration/v2/migrators/PaintingMigrator.ts`
- Agent 面：`src/main/ai/tools/painting.ts`、`tools/generateImageTool.ts`、`tools/adapters/aiSdk/builtin/PaintingTool.ts`、`registerBuiltinTools.ts:34`、`src/main/ai/mcp/servers/cherryBuiltinTools.ts:143`、`cherryBuiltinApproval.ts:48`、`src/renderer/components/composer/tools/definitions/generateImageTool.tsx`
- 清理与文档：`docs/references/file/file-entry-cleanup.md`（§1、§5.1）
- 偏好：`src/shared/data/preference/preferenceSchemas.ts:396`（feature.paintings.default_model_id）、`src/renderer/hooks/useModel.ts:34`
