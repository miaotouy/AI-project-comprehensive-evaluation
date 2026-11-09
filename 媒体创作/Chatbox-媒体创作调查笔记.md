# Chatbox 媒体创作调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`（Electron + React 桌面客户端，另含 web/移动目标）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：静态源码走读（只读）并复核旧笔记涉及路径；既有测试结果来自旧快照，本次未重新运行测试；未修改仓库源码
>
> 调查范围：Image Creator 图像工作台主链（能力分型 M1 模型生成工作站 + M3 记录/资产生命周期）：入口与触发者、事实对象、参数/参考图/模型执行、任务状态机与取消/恢复/重试、记录与图片持久化、预览/复用、chatbox_cli 后台任务回填、权限与失败恢复。聊天 Agent 工具、消息渲染与上下文机制只做交接引用；Copilots、team-sharing 等其他独特功能不在本页范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 的媒体创作是一条窄而完整、用户主导的图像生成工作链，能力分型为 **M1 模型生成工作站 + M3 记录/资产生命周期**：单一事实对象 `ImageGeneration` 记录（prompt、模型、参数、参考图键、结果图键、状态、错误与来源），配套 blob 图片存储；执行按 provider 分两条路径（ChatboxAI 服务端异步任务 + 客户端 2 秒轮询；其余 provider 走 `model.paint` 直连），并统一折叠为 `pending / generating / done / error` 四种本地状态（`src/shared/types/image-generation.ts:6`）。

媒体创作视角下有四个关键机制，均为独特功能笔记能力卡二未展开的细节（分工见下文"交接专页"）：

1. **参考图 DAG**：参考图与结果图以 blob 键关联，历史记录复用时把父记录身份保存进新记录；删除后扫描其余记录与当前受保护的参考键，只清理无引用 blob。见 `packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:585-655`。
2. **取消/恢复/重试语义**：应用服务中止本地执行或监视；已有服务端任务身份必须保留，没有任务身份的中断会收口为错误。恢复只监视原任务，重试重新提交。见 `packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:454-565`。
3. **跨重启持久化**：记录存 IndexedDB（桌面/Web）或 SQLite（移动），图片存 blob；核心服务提供启动清算入口，可把遗留 pending/generating 记录标为中断错误；当前 renderer 门面未找到该入口调用。已有任务身份首次落盘失败时还有内存保护，防止同进程重复发起计费任务。见同文件 `:153-182,209-226,325-334,469-486`。
4. **聊天结果投影**：聊天工具触发的生成图片被提升到消息底部 artifacts 区域，与下载文件并列，不因 Work Mode 的过程时间线完成后折叠而隐藏；远程图片加载失败可重新请求并恢复显示。`src/renderer/components/message-parts/ToolCallPartUI.tsx:1038-1069`、`src/renderer/components/chat/Message.tsx:553`、`src/renderer/routes/image-creator/-components/GeneratedImagesGallery.tsx:168-224`。

图像生成与聊天恢复相关测试当前未重新运行，现行测试结果需要在当前快照上复跑。真实计费调用、外部模型与额度链路仍未运行验证。

## 系统边界与完整主链

### 边界

| 层 | 承担者 | 证据 |
|---|---|---|
| 创作入口 | `/image-creator/` 路由 + 侧栏/快捷入口 + 聊天空态链接 | `src/renderer/routes/image-creator/index.tsx:74`、`Sidebar.tsx:89`、`useShortcut.tsx:104`、`InputBox.tsx:1384` |
| 事实对象 | `ImageGeneration` 记录（schema 与本地状态定义） | `src/shared/types/image-generation.ts:26-47` |
| 记录存储 | `ImageGenerationStorage`：桌面/Web 用 IndexedDB，移动用 SQLite | `desktop_platform.ts:363-368`、`web_platform.ts:207-212`、`mobile_platform.ts:323-328` |
| 图片/参考图存储 | 平台 blob 存储，键前缀 `picture:*` | `src/renderer/storage/StoreStorage.ts:30-31`、`BaseStorage.ts:92-105` |
| 任务执行 | ChatboxAI：服务端异步任务 + 轮询；OpenAI/Gemini：`model.paint` 客户端直连 | `imageGenerationActions.ts:42-44,156` |
| 外部依赖 | ChatboxAI API（`/api/images/async_generations`、`/api/ai/paint`）、AI SDK provider（OpenAI/Gemini 直连） | `packages/remote.ts:1145-1168`、`chatboxai.ts:418` |
| 聊天回填 | chatbox_cli 后台任务通知 + `ToolCallPartUI` 工具卡 | `packages/chatbox-cli/image-task-follow-up.ts:23-46`、`ToolCallPartUI.tsx:1585-1648` |

未发现 ComfyUI、FFmpeg、服务端媒体供给层或插件协议：Chatbox 的媒体创作全部收敛在"客户端记录 + 外部图像 API"两层，与 VCPToolBox 的服务端渲染供给层结构不同。

### 完整主链（静态源码确认）

```text
侧栏/快捷键/聊天空态 -> /image-creator/
  -> 模型目录 useImageModelGroups（按 provider 分组；OpenAI OAuth 排除，image-model-catalog.ts:68-74）
  -> 比例 getRatioOptionsForModel（按模型族，image-models.ts:3-7）；参考图上传（≤14 张，blob 暂存）
  -> renderer startImageGeneration → core ImageGenerationService.start
       -> createRecord 落盘（pending）-> onRecordCreated 钩子（CLI 持久化重试元数据）
       -> 服务占用 attempt / backgroundRecordId 单任务闸门
  -> ChatboxAI：POST /api/images/async_generations 拿 taskId -> 每 2s 轮询
       -> 渐进写入 generatedImages/缩略图 -> 终态 done/error
     其他 provider：model.paint -> 每张图 base64 写 blob（picture:image-gen:<recordId>）-> addGeneratedImage
  -> 结果：GeneratedImagesGallery（全屏/下载/用作参考/报告）、PromptDisplay、HistoryPanel
  -> 取消：中止本地执行/监视，保留已提交任务身份；无 taskId 的中断写 error
  -> Resume 监视原 taskId，Retry 重新提交；服务提供启动清算 API，renderer 未见接线
  -> 聊天来源：chatbox image generate（审批）-> 后台任务完成/失败回填原会话 -> 聊天内可恢复
```

## 1. 创作入口、触发者与事实对象

**入口与触发者**：用户主导的工作台是唯一独立入口，路由 `createFileRoute('/image-creator/')`（`routes/image-creator/index.tsx:74`），侧栏、快捷键与聊天输入框空态均可跳转（定位见文末源码索引）。第二个触发者是聊天内的 Agent 工具链：`chatbox image generate`（`packages/chatbox-cli/images.ts:344-351`）以后台任务方式发起生成，属于 Agent 驱动的 M5 边界，见第 6 节。无插件、定时任务或外部服务触发入口（本次未找到）。

**核心事实对象**：`ImageGeneration` 记录（`src/shared/types/image-generation.ts:26-47`）：

- 参数：`prompt`、`model {provider, modelId}`、`dalleStyle`、`imageGenerateNum`、`aspectRatio`、`referenceImages`（存储键数组）
- 结果：`generatedImages`（存储键或 URL 数组）、`generatedImageThumbnails`（与结果对齐）
- 状态：`status`（pending/generating/done/error，本地四态，注释明确与后端 item 状态不同）、`taskId`（异步任务取回凭据）
- DAG：`parentIds`（注释为"tracking iteration DAG, multiple parents possible"）
- 失败：`error`、`errorCode`（数字来自 ChatboxAI API 错误，字符串来自异步 item 错误）、`errorItemUuid`
- 来源：`source`（目前仅 `chatbox_cli {sessionId, toolCallId}` 判别联合，用于后台完成回调回连）

记录不是消息附件，也不是会话树节点：它独立于会话持久化，聊天回填只是它的一个投影（`ImageGenerationResultGallery` 把记录里的键/URL 映射为消息图片 part，`components/chat/image-generation-result.ts:7-11`）。

## 2. 参数、素材与模型/渲染执行

**模型能力目录**：模型目录按 provider 分组——ChatboxAI 在 license 下取远程 manifest 并做排除过滤（`excludedModels`），Gemini 合并内置与自定义 provider 的 image 型模型，OpenAI 以 `isOpenAIImageGenerationAuthSupported` 排除 OAuth 会话（`packages/image-model-catalog.ts:68-74`，源码注释表明避免 OAuth 会话走 DALL-E 计费路径）。分组入口 `useImageModelGroups`（`hooks/useImageModelGroups.ts:45-128`）；非 React 侧（chatbox_cli）用等价接口 `getAvailableImageModels`（同文件 `:107-157`）。

**比例与风格**：`getRatioOptionsForModel` 按模型族给出比例选项（openai 4 项、gemini 11 项，`src/shared/providers/definitions/image-models.ts:3-7`）；`'auto'` 在提交时归一化为 undefined，表示不约束（`packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:229-241`）。风格参数 `dalleStyle` 只接受 `vivid` 与 `natural` 两个取值。

**参考图进入请求**：上传图片先写 blob；应用服务逐项解析参考来源，URL/data URL 直接使用，存储键通过注入的 blob 解析器读取，缺失参考图会中止生成。异步请求把这些内容放进图片 URL 字段，直接路径则传入模型绘图接口。见 `packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:294-336,343-351`。

**执行位置**：核心图像服务按 Provider 选择异步或直接生成，分支见 `packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:307-350`。

1. **异步路径**（ChatboxAI）：`POST /api/images/async_generations` 提交后拿到 task_id 与 items 数组，客户端不直接渲染，只按固定间隔轮询 `GET /api/images/async_generations/{taskId}`（`IMAGE_GENERATION_POLL_INTERVAL_MS = 2000`，`packages/remote.ts:1145-1219`）。接口 schema 注释明确：结构预留数组但产品功能层不支持一次异步生成多张图，后端现阶段写死 item 为 1（`remote.ts:1135-1137`）。
2. **直接路径**（OpenAI/Gemini/自定义 Gemini）：`model.paint` 在客户端逐张调用，内部按 provider 分流：
   - Gemini 原生：`generateText` + `responseModalities: ['TEXT','IMAGE']`（`gemini.ts:98-145`）
   - ChatboxAI 网关的 Gemini 模型：`streamText` 流式收集图片（`chatboxai.ts:320-371`）
   - ChatboxAI 网关的非 google 模型：`/api/ai/paint`（`chatboxai.ts:409-442`）

   两条调用都设 `maxRetries: 0`，注释明确图像生成计费、网络错误重试可能重复扣费（`chatboxai.ts:358-359`、`gemini.ts:132-133`）。参考图在 Gemini 路径下拼入消息内容（text+image 交替），OpenAI/DALL-E 路径经 `images` 字段发送。

## 3. 任务状态、异步回调与取消

任务所有者是核心应用层 `ImageGenerationService`，renderer 动作文件只注入平台存储、模型与异步客户端并映射 UI 状态，聊天 CLI 与工作台共享同一服务。见 `src/renderer/stores/imageGenerationActions.ts:36-91,101-140`。

**状态与单任务闸门**：记录仍为本地四态，服务另有准备、执行、停止与暂停等运行阶段。新建、恢复和重试都先占用单任务闸门，前一执行或后台暂停身份仍存在时拒绝新任务。已提交却未确认持久化的任务身份也阻止新提交。见 `packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:147-182`。

**取消与后台暂停**：取消中止当前 AbortController，等待写尾收敛后释放执行身份。已有 taskId 时保留记录与任务身份；尚未得到任务身份的中断写为 error。服务提供前后台切换 API，已提交任务可暂停并在前台继续监视；对 renderer 门面、工作台与调用点的搜索未找到该 API 接线。客户端停止行为没有撤销后端计费任务的实现证据。见同文件 `:454-466,490-505,567-582`。

**提交身份保护**：异步提交返回任务 ID 后，即使本地刚刚取消，服务仍先保存该身份再检查中止状态。首次持久化失败时保留内存恢复记录并显示持久化失败错误，恢复原任务可重新确认保存；进程退出后这份未落盘身份仍有丢失边界。见同文件 `:314-336,469-486`。

**恢复与重试**：恢复要求记录已有 taskId，将其置为 generating 并监视同一任务；重试清 taskId 与错误、置回 pending，再重新提交。服务的 bootstrap API 可把遗留运行记录收口为中断错误，不自动发送或恢复 Provider 请求。当前 renderer 门面构造服务后只订阅记录/状态与创建查询桥，未找到 bootstrap 调用；此项记为服务已实现、renderer 接线未找到。见同文件 `:209-226,507-565`。

**聊天回填**：任务终态以记录来源的会话和工具调用 ID 为目标，排入后台通知。成功通知说明图片已经显示在原工具处，要求简短确认；失败则携带截短错误。恢复也复用同一通知入口。见 `src/renderer/packages/chatbox-cli/image-task-follow-up.ts:23-77`。

## 4. 结果、历史、资产与工程持久化

**记录持久化**：`ImageGenerationStorage` 接口（`storage/ImageGenerationStorage.ts:7-15`）有两个平台实现：
- 桌面/Web：IndexedDB，库名 `chatbox-image-generation`，建 `createdAt` 索引（`desktop_platform.ts:363-368`、`web_platform.ts:207-212`）
- 移动：SQLite，`SQLiteImageGenerationStorage.ts:36-70` 建表 + `addColumnIfNotExists` 迁移 + 时间索引（`mobile_platform.ts:323-328`）

记录存储也纳入整体数据迁移流程（`stores/migration.ts:523`）。

**图片持久化**：直接路径每张图以键形如 `picture:image-gen:<recordId>:<uuid>` 的 blob 写入（`StorageKeyGenerator.picture`，`src/renderer/stores/imageGenerationActions.ts:68` 与核心图像服务）；ChatboxAI 异步路径的结果是 URL，不回写 blob——**两种结果的持久化形态不同**：前者本机可离线查看，后者依赖网络（`GeneratedImagesGallery` 对两种来源分别走 `fetchBlob`/直接加载，`GeneratedImagesGallery.tsx:139-168`）。

**命名与去重**：图片键按记录 id + uuid 生成，无内容级去重（本次未找到）；参考图键为 `picture:image-creator-ref:*`。

**来源关联与 DAG**：父记录关系承接历史图片再次作为参考的迭代。删除记录先阻止该记录后续异步回写，再扫描其他记录的结果与参考键；仍受当前创作保护的键延期清理，存储读取失败时保留候选，避免误删。见 `packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts:585-655`。

**历史与分页**：`useImageGenerationHistory` 每页 20 条、cursor 分页、5 分钟 staleTime（`imageGenerationStore.ts:60-74`）；历史面板按记录列出 prompt/模型/时间，可点击载入、删除与加载更多（`index.tsx:457-489`）。

## 5. 预览、编辑、重试、分支与复用

- **预览**：`GeneratedImagesGallery`（photoswipe 全屏、按实际宽高自适应、移动端 1:1 封面）；`blobToDataUrl` 兼容 jpeg/png base64（`-components/constants.ts:21-27`）；加载失败显示占位并可点击重试（`GeneratedImagesGallery.tsx:207-224`）。
- **导出**：全屏与缩略图两处下载，URL 走 `platform.exporter.exportByUrl`，本机键走 `exportImageFile`（`GeneratedImagesGallery.tsx:52-71,176-188`）。
- **编辑**：无像素级编辑能力（裁剪/滤镜/局部重绘均未找到）；"编辑"的等价物是改 prompt + 参考图后再次生成。
- **重试**：`ImageGenerationErrorTips` 面板提供 Retry 按钮（`ImageGenerationErrorTips.tsx:156-166`），错误面按错误码分支：
  - ChatboxAI 数字错误码：license_not_found、expired_license 等引导到设置页
  - 任务字符串错误码：`image_content_moderation_blocked`、`ai_provider_error`、`image_generation_failed`（`:21-41`）
  - 失败 item 的 UUID/TaskId 调试信息可复制
- **分支**：无显式分支 UI；DAG（parentIds）在数据层保留多父迭代关系，本次未找到基于 DAG 的导航或画布，仅历史列表线性呈现。
- **复用**：三处——"用作参考"（下一轮输入，`index.tsx:577`）、历史点击重新载入 prompt/参考图（`:457-466`）、聊天消息内结果图以 `ImageGenerationResultGallery` 展示并进入消息资产体系（`components/chat/ImageGenerationResultGallery.tsx`）。

## 6. Agent 回流、插件与外部依赖

**Agent 触发与回流**：聊天内的 `chatbox image generate`（`packages/chatbox-cli/images.ts:344-351`）是后台任务式入口，链路如下：

1. **审批**：`requestAppActionApproval`（`:252-287`）审批详情含 provider/model/count/风格与计费归属（`chatbox_quota | provider`；ChatboxAI 附加剩余图片配额与 compute points 比例），通过后 `startImageGeneration` 发起。
2. **幂等绑定**：`onRecordCreated` 钩子把 `{signature, recordId, startedAt}` 持久化到 `chatbox-cli:image-generation-execution:<sessionId>:<toolCallId>`（`:291-316`），经 `cacheExecution` 与签名校验实现“同一 tool call 幂等绑定”（`:130-152,221-240`），跨重启从持久化元数据恢复。
3. **完成回填**：`queueImageTaskCompletion` 以 `image_generation` 类型后台任务通知回填原会话（`image-task-follow-up.ts:23-46`）。
4. **聊天内恢复**：`ToolCallPartUI` 渲染等待卡，支持中断后从聊天内恢复（`ToolCallPartUI.tsx:1585-1598,1632-1648`）；恢复按钮仅当记录有 `taskId`，无 taskId 或记录丢失判为不可恢复。

Agent 还可读历史：`chatbox image status|history|models`（`images.ts:356-392`），`compactRecord` 返回带 `wait` 提示（callback/manual_resume/manual_retry）的精简记录。

**外部依赖边界**：无 ComfyUI/FFmpeg/自有渲染器/文件服务。依赖面为：ChatboxAI API（异步任务、/api/ai/paint、模型 manifest 网关）、OpenAI/Gemini 官方 SDK 直连、本地 IndexedDB/SQLite 与 blob 存储。远程 manifest 与异步任务均依赖 ChatboxAI 后端可用性（离线不可用，本次未运行验证）。

## 7. 权限、资源边界与失败恢复

- **计费与凭据**：ChatboxAI 路径必须持 licenseKey（`getLicenseKey` 抛错，`imageGenerationActions.ts:34-40`），UI 层在未登录时 toast 拦截（`index.tsx:373-376`）；OpenAI OAuth 会话被排除出图像模型目录（见第 2 节）。
- **输入限额**：参考图 ≤ 14 张且仅 `image/*`（`constants.ts:1`、`index.tsx:324,328`）；CLI 侧 prompt ≤ 8000 字符、count 1–4、--style 白名单（`images.ts:161,165,168-170`）。
- **并发**：全局单生成（见第 3 节）；CLI 侧同一 tool call 参数变更即拒绝（幂等绑定）。
- **网络重试**：计费敏感调用 `maxRetries: 0`；异步提交/轮询的 afetch 层有 `retry: 2`（`remote.ts:1163,1188`）——即提交失败会重放 HTTP 请求，与 paint 的零重试策略不一致，是否造成重复计费无运行时证据（源码事实，效果未验证）。
- **失败恢复**：恢复原任务要求已有 taskId，重试重新提交；无任务身份的取消收口为错误；启动清算为服务 API，renderer 接线未找到。已提交身份首次落盘失败时由同进程内存保护保留，详见第 3 节。
- **文件/进程权限**：本次范围内无文件系统直写（导出经平台 exporter）、无子进程、无沙箱执行；超出本文范围。

## 8. 设计取舍、已确认边界与未验证事项

### 设计取舍与已确认边界

- **双执行路径而非统一任务协议**：ChatboxAI 用服务端异步任务（可跨重启取回），第三方 provider 用客户端同步直连（取消即放弃）——同一记录对象掩盖了两种一致性强度。
- **本地停止与远端任务分离**：服务中止本地执行或监视，远端任务撤销未见客户端实现；已有 taskId 可恢复，直接路径中断后需重试。
- **异步路径结果不落 blob**：历史记录里 URL 与存储键混合，离线可查看性不一致（§4）。
- **参考图 DAG 只记录父 id，不做图浏览/多父可视化**：parentIds 支持多父，但 UI 只有线性历史（§5）。
- **单并发闸门**：全应用同一时刻只能有一个图像任务在生成（含 Agent 后台任务）。
- **本次未找到**：像素编辑、分支画布、内容级去重、后端任务撤销、图片资产管理器（独立于记录的资产库）。

### 运行验证

- 依赖安装：`npm install --no-audit --no-fund` 首次因 ERESOLVE 失败（项目用 zod ^4，`@mastra/core@0.13.2` 声明 peer zod ^3；仓库 pnpm 的 auto-install-peers 可规避，npm 不能）；加 `--legacy-peer-deps` 后成功，2808 包约 6 分钟。设 `ELECTRON_SKIP_BINARY_DOWNLOAD=1`（单元测试不需要 Electron 运行时，本机缓存已有 electron 35.6.0 zip）。postinstall 的原生依赖检查因调用 pnpm（本机 corepack 签名校验故障）失败，非致命。npm 安装未应用仓库 `pnpm-workspace.yaml` 的 patchedDependencies 补丁；首次运行还发现 npm 解析出的 `@tanstack/router-plugin` 1.168.x 无法转换既有路由文件，用 `--no-save` 对齐仓库 pin 的 1.120.15 后路由转换正常（gitignored 的 `routeTree.gen.ts` 由插件生成，`git status` 干净）。
- 以下测试文件覆盖图像生成与聊天恢复主链，当前快照未重新运行，结果不视为当前快照的运行确认——
  - `stores/imageGenerationActions.test.ts`（7 用例：参考图 URL/键双源、completion promise、onRecordCreated 先于计费请求、resume 终态、结构化错误码、缩略图分离、失败 item 折叠）；
  - `storage/__tests__/SQLiteImageGenerationStorage.test.ts`（3）、`packages/chatbox-cli/images.test.ts`（12）、`image-task-follow-up.test.ts`（4）、`image-model-catalog.test.ts`（6）、`routes/image-creator/-components/model-selection.test.ts`（3）、`components/chat/ImageGenerationResultGallery.test.ts`（2）、`message-parts/ToolCallPartUI.image-recovery.test.tsx`（6）、`ToolCallPartUI.command.test.tsx`（6）。
- 当前快照未重新运行上述测试。真实计费生成、真实模型 manifest/异步任务接口、应用级跨重启恢复、IndexedDB/SQLite 真机持久化、参考图实际构图与视觉行为、UI 视觉效果与键盘可用性均未运行。

### 未验证事项

- 真实计费调用（DALL-E/Gemini/ChatboxAI 生图）——需要外部模型与计费环境，标注"未验证：需要外部模型与计费环境"。
- 服务端异步任务的真实轮询/失败/取消时序、取消后后端是否仍在计费、afetch `retry: 2` 是否重复提交任务。
- 参考图多张组合的实际构图行为与上传大图性能。
- 应用重启后跨会话恢复（记录+taskId 取回）的端到端行为。
- 远程模型 manifest 与 ChatboxAI 后端可用性（离线依赖）。
- 移动端 SQLite 存储、桌面 IndexedDB 的实机迁移表现。
- UI 视觉、键盘导航、移动端抽屉与 photoswipe 全屏的实际体验。

## 交接专页（与独特功能笔记的分工）

本页承接 [Chatbox 独特功能调查笔记 能力卡 2](../独特功能/Chatbox-独特功能调查笔记.md)（其中已有工作台产品面盘点：模型分组、参考图 base64、`createAndGenerate`、取消/恢复/重试、Gallery/HistoryPanel/ErrorTips、`image-model-catalog.ts` OAuth 规则、chatbox_cli 来源记录与 `image-task-follow-up` 回填）。独特功能笔记负责"该能力在产品面盘点中的地位与独特性判断"，本页负责媒体创作类目视角：

- **M1 图像工作台**：双执行路径与本地四态折叠（§2、§3）——独特功能笔记未展开的直接/异步路径差异、`maxRetries: 0` 计费防护、异步路径不落 blob。
- **参考图 DAG**：`parentIds` 多父语义、引用计数 blob GC、DAG 只存数据不做图浏览（§4、§5）——独特功能笔记只有一句"保留来源 record id（DAG 语义）"。
- **取消/恢复/重试语义**：取消=停止监视、resume 需 taskId、retry=全新发起、单并发闸门（§3）——独特功能笔记未逐层展开。
- **跨重启持久化**：IndexedDB/SQLite 平台分派、迁移、`currentGeneratingId` 仅内存、聊天侧中断恢复判据（§4、§6、§7）。

独特功能笔记中已覆盖的源证据（工作台完整主链骨架、模型目录规则与 OAuth 排除、CLI 来源回填链、能力卡 3 与团队共享）不再重复抄写。

## 关键源码索引

- 工作台路由与 UI：`src/renderer/routes/image-creator/index.tsx`、`-components/{GeneratedImagesGallery,HistoryPanel,HistoryItem,ImageGenerationErrorTips,ReferenceImagesPreview,PromptDisplay,constants,model-selection,EmptyState,MobileDrawers,Shimmer}.tsx`
- 应用服务：`packages/chatbox-core/src/application/image-generation/ImageGenerationService.ts`；renderer 门面与依赖注入：`src/renderer/stores/imageGenerationActions.ts`
- 记录存储：`src/renderer/stores/imageGenerationStore.ts`（deleteRecord blob GC:128-177）、`src/renderer/storage/ImageGenerationStorage.ts`、`SQLiteImageGenerationStorage.ts`、平台分派 `desktop_platform.ts:363`、`mobile_platform.ts:323`、`web_platform.ts:207`
- 类型：`src/shared/types/image-generation.ts`；比例族 `src/shared/providers/definitions/image-models.ts`
- 远程接口：`src/renderer/packages/remote.ts:1106-1219`（submit/poll/轮询循环）
- 模型执行：`src/shared/providers/definitions/models/chatboxai.ts:304-442`、`gemini.ts:98-145`；目录 `src/renderer/packages/image-model-catalog.ts`、`hooks/useImageModelGroups.ts`
- Agent 链：`src/renderer/packages/chatbox-cli/images.ts`、`image-task-follow-up.ts`、`background-task-result.ts`；聊天恢复 UI `src/renderer/components/message-parts/ToolCallPartUI.tsx:1585-1648`；聊天展示 `components/chat/ImageGenerationResultGallery.tsx`
- 入口：`Sidebar.tsx:89`、`hooks/useShortcut.tsx:104`、`components/InputBox/InputBox.tsx:1384`
- 测试索引：`packages/chatbox-core/src/application/image-generation/ImageGenerationService.test.ts`、`packages/chatbox-cli/images.test.ts`、`image-task-follow-up.test.ts`、`storage/__tests__/SQLiteImageGenerationStorage.test.ts`、`packages/image-model-catalog.test.ts`、`routes/image-creator/-components/model-selection.test.ts`、`components/chat/ImageGenerationResultGallery.test.ts`、`components/message-parts/ToolCallPartUI.image-recovery.test.tsx`
