# NextChat 媒体创作调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：静态源码走读；复核既有生成式输出与运行时笔记（同一代码快照），检查 Stable Diffusion 路由、表单、持久化 store、文件上传与删除路径；未启动应用、未调用 Stability API 或上传服务、未运行测试
>
> 调查范围：`/sd`、`/sd-new` 图像生成的入口、参数、请求、结果记录、预览、重试和删除；聊天内 DALL-E URL 消息与 HTML Artifact 仅作边界说明，不展开消息渲染、Provider 路由和通用持久化实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 有一条较窄但完整的图像生成闭环，归为 **M1 模型生成工作站（轻量）**：侧栏进入 Stable Diffusion 页面，用户选择 Stable Image Ultra/Core/SD3 模型并填写提示词等参数；store 立即建立带 UUID 的运行中记录，请求完成后将 base64 图像上传或压缩为可显示 URL，再把成功、失败及参数写回同一记录。该列表经持久化 store 保存，页面可恢复历史、预览、复制提示词、用原参数重试和删除结果。

核心事实对象是 `draw` 数组中的任务记录，不是独立数据库表或资产库。每条记录包含本次 `model`、参数、状态、UUID、结果 URL 或错误；它具备工作台内的稳定列表身份，但未见来源聊天、参考图关系、版本、分支、标签、内容去重或跨工作流索引。结果可由 URL 再次使用，但本次未找到把 SD 工作台结果一键回流到聊天、作为下一次生成参考图，或让 Agent 读取该历史的路径。

这与既有生成式输出与运行时笔记所述的聊天内 DALL-E 3 URL 消息不同：后者仍是普通消息内容；HTML Artifact 也只是消息文本的 iframe 投影。媒体类目的主链仅以 `/sd` 工作台的持久化任务列表为准。所有行为均由静态代码确认，真实 API、上传、持久化介质和 UI 行为未运行验证。

## 系统边界与完整主链

| 层 | 承担者 | 静态证据 |
|---|---|---|
| 入口 | 侧栏 Stable Diffusion、`/sd` 与 `/sd-new` | `app/components/sidebar.tsx`、`app/components/home.tsx:166-187` |
| 任务事实源 | `useSdStore` 的 `draw` 记录与当前模型/参数 | `app/store/sd.ts:21-43` |
| 参数与提交 | `SdPanel`、`SdSidebar` | `app/components/sd/sd-panel.tsx`、`sd-sidebar.tsx:26-131` |
| 执行 | 浏览器 POST 到 Stability API 或用户设置的自定义端点 | `app/store/sd.ts:65-135` |
| 结果与文件 | 上传端点返回 URL；无 Service Worker 时压缩为本地可显示数据 | `app/utils/chat.ts:144-173` |
| 预览和复用 | `Sd` 历史列表的图片弹窗、参数查看、复制、重试、删除 | `app/components/sd/sd.tsx:154-333` |

```text
侧栏 -> /sd-new -> SdPanel 填写模型、prompt、negative prompt、比例、风格、seed、格式
  -> SdSidebar 校验必填项并提交 -> useSdStore.sendTask
  -> 生成 UUID、status=running 的 draw 记录，先写入持久化 store
  -> POST <Stability/custom URL>/v2beta/stable-image/generate/<model>
  -> 成功：base64 PNG -> uploadImage（或压缩为本地 URL）-> 记录 status=success、img_data
  -> 失败：记录 status=error、error
  -> /sd 历史列表从 draw 重建：图片预览/查看参数/复制 prompt/原参数重试/删除 URL
```

## 1. 创作入口、触发者与事实对象

用户是唯一已确认的创作触发者。`SdSidebar` 按当前模型筛选表单、检查必填项，然后导航到 `/sd-new` 并发起提交；`home.tsx` 将 `/sd` 与 `/sd-new` 都投影为 `Sd` 页面。移动端也有返回至 `/sd` 的导航绑定，但实际布局、触控与视觉效果未运行验证。

每次提交在网络请求之前创建一个 `draw` 项，写入 UUID、`running` 状态、模型及参数；后续按 UUID 原位替换结果。这使同一列表可并列保存进行中、成功和失败任务。`createPersistStore` 的存储键为 `SdList`，因此历史并不只存在组件状态；底层 IndexedDB/恢复行为由既有生成式输出笔记覆盖，本次未实测。见 `app/store/sd.ts:28-64,137-162`。

记录是工作台专用的历史对象，却没有单独的媒体资产 schema：没有创建者、来源消息、输入文件、父子关系、版本或哈希字段。本次在 `app/store/sd.ts` 与 `app/components/sd/` 范围内未找到资产库、工程文件或任务搜索入口。

## 2. 参数、素材与模型执行

模型目录固定为 Stable Image Ultra、Core 和 Stable Diffusion 3；SD3 还可选三个模型版本。表单按模型显示提示词、负向提示词、比例、风格、seed 和输出格式，seed 上限是 `4294967294`。这些是客户端表单约束，服务端是否接受相同范围未运行确认，见 `app/components/sd/sd-panel.tsx:9-130`。

提交将所有参数原样加入 `FormData`，以 `Authorization` 头请求内置 Stability 路径，或使用访问设置中的自定义 URL/API key。代码只处理单次 JSON 响应：`finish_reason === 'SUCCESS'` 时读取一张 `image` 字段；不满足该条件或响应含 errors 时写入错误记录。这里没有轮询、服务端回调、队列状态或多图批处理协议。`app/store/sd.ts:65-135`。

此工作台没有参考图上传控件；`uploadImage` 出现在结果处理而非提交参数中。本次未把聊天消息的视觉输入、DALL-E 3 或通用附件能力计入这条主链。

## 3. 任务状态、失败、取消与恢复

任务状态仅为 `running`、`success`、`error`，由浏览器 Promise 回调更新；列表页分别显示加载图标、图片或错误图标。失败文本来自响应的首项 error、非成功 JSON 或 fetch 异常。没有进度百分比、远端任务 ID、轮询或 webhook。`app/store/sd.ts:58-135`、`app/components/sd/sd.tsx:164-190`。

本次未找到取消按钮、`AbortController` 或任务超时。页面刷新后的列表恢复依赖持久化记录，但对刷新前仍在运行的请求，没有可验证的重新关联或继续执行机制；静态代码只能确认旧记录仍会被读取，不能确认任务恢复语义。

## 4. 结果、历史与持久化复用

成功响应中的 base64 PNG 先转 Blob。启用 Service Worker 时，`uploadImage` 向上传地址提交文件并保存返回 URL；未启用时退回 `compressImage`，结果仍作为 `img_data` 写入记录。删除动作对该 URL 发送 DELETE 后才从列表移除。结果的真实文件服务、认证、保留期限和删除原子性均未运行验证，见 `app/utils/chat.ts:134-173`。

历史列表保存生成参数，用户可查看全部字段或复制 prompt。重试从旧记录复制模型和参数，建立新 UUID 和新任务，不覆盖原记录；这是可追踪的重复生成而非版本分支。工作台没有结果下载按钮、改图、参数预设、内容去重或按资产跨会话引用。`app/components/sd/sd.tsx:195-321`。

## 5. 预览、再次创作与回流

成功项以图片元素显示，点击使用全局图片弹窗预览；参数和 prompt 都可从每项操作区读取。静态代码确认事件绑定，但大图展示、下载能力和移动端适配需要运行验证。`app/components/sd/sd.tsx:164-305`。

再次创作仅有“Retry”：保留原模型和参数，发起新请求。没有以历史图作参考图、局部编辑、seed 单独复用、显式分支或导出工作流。本次也未找到工作台结果到聊天消息、Agent 工具或模型上下文的自动回流；结果只能通过其 URL 在应用外或其他可接收 URL 的路径中手动使用。

## 6. 外部依赖、权限与资源边界

生成依赖 Stability API 或用户配置的兼容端点，访问令牌可来自自定义 API key 或应用访问码。文件持久化依赖上传服务或浏览器压缩回退；两者都在客户端发起。没有项目内模型执行器、ComfyUI、FFmpeg、浏览器渲染器或异步任务服务。`app/store/sd.ts:65-91`、`app/utils/chat.ts:144-164`。

本次只确认了表单 seed 范围和所列模型参数，没有找到图像大小、并发、每日额度、上传大小或文件配额的本地治理。实际限制取决于远端模型与上传服务，不能从该 UI 推出。

## 7. 设计取舍、已确认边界与未验证事项

该实现以“持久化请求列表”代替资产库：实现简单，重试和历史参数直接来自同一记录，但媒体文件的生命周期、来源关系和跨工作流复用不由应用统一管理。任务只在浏览器 Promise 中执行，避免服务端队列设计，也意味着没有可观察的后台恢复链。

已确认边界：本次在 SD store、组件与上传工具范围内未找到视频/音频生成、参考素材、Agent 媒体工具、工作流/工程对象、任务取消、轮询回调、资产去重、聊天回流或独立导出。聊天 DALL-E 图像与 Artifact 的机制详见 `../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md`，不应与此任务列表混计。

未验证事项：未配置真实 Stability/custom API、访问码和上传端点；未运行任务成功、错误、删除、重试或持久化恢复；未确认 Service Worker 分支下文件 URL 的可访问性与生命周期；未运行测试，未验证预览和移动端 UI。

## 8. 关键源码索引

- `app/components/sidebar.tsx`、`app/components/home.tsx:166-187`：Stable Diffusion 入口和路由投影。
- `app/components/sd/sd-sidebar.tsx:26-131`、`sd-panel.tsx:9-130,279-320`：提交入口、模型和参数契约。
- `app/store/sd.ts:21-162`：任务记录、请求、状态更新和持久化键。
- `app/components/sd/sd.tsx:154-333`：历史预览、参数查看、复制、重试和删除。
- `app/utils/chat.ts:134-173`：base64 转 Blob、上传和删除。
- `../生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md`：聊天内 DALL-E、Artifact 与通用输出边界。
