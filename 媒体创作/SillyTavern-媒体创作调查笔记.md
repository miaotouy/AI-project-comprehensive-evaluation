# SillyTavern 媒体创作调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：静态源码走读；复核既有生成式输出与运行时笔记（同一代码快照），精读 Stable Diffusion 扩展的生成、媒体消息、重生、函数工具和 slash command 路径，并定位服务端 Stable Diffusion/ComfyUI 路由；未启动服务、未配置模型提供商或 ComfyUI、未运行测试
>
> 调查范围：Stable Diffusion 扩展的图像/视频生成、参数与提供商执行、结果文件/聊天媒体持久化、重试与 Agent 回流；普通媒体附件、消息渲染、通用工具调度和聊天 JSONL 机制仅作交接说明
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的 Stable Diffusion 扩展构成 **M1 模型生成工作站（聊天绑定）+ M5 Agent 驱动创作**。用户可从画笔菜单、消息级画笔、slash command 触发，模型也可调用可选 `GenerateImage` function tool。扩展从自由提示、聊天内容、角色/用户头像或安静 LLM 提示生成路径取得提示词，按当前 provider 配置请求外部图像服务或 ComfyUI；成功结果先保存到本地媒体路径，再作为 `extra.media` 附件加入新聊天消息，或追加到既有消息的媒体数组。聊天 JSONL 和媒体文件共同构成可恢复的结果链。

它的历史主体仍是聊天消息而非独立媒体任务/资产表。媒体附件保留 URL、类型、标题、生成模式与负向提示词；消息级画笔能把当前媒体作为基础再生成并追加一张“media swipe”，因此同一消息可形成线性图片候选。该路径支持预览、保存、再次生成和聊天回流，但没有项目级媒体库、媒体搜索/标签、内容去重、任务队列、版本 DAG 或完整的参数快照。

扩展支持许多远端/本地来源，ComfyUI 工作流文件也可由服务端管理，但工作流是 provider 配置物，不与每次结果建立工程关系。取消通过 `AbortController` 中止浏览器请求；实际远端取消与异步提供商的最终状态取决于端点，未运行确认。全部结论为静态源码事实。

## 系统边界与完整主链

| 层 | 承担者 | 静态证据 |
|---|---|---|
| 入口 | 画笔菜单、消息画笔、`/imagine`、function tool | `public/scripts/extensions/stable-diffusion/index.js:5024-5073,5149-5234,5452-5526` |
| 事实对象 | ChatMessage 的 `extra.media` 与文件 URL | `index.js:4966-5001` |
| 参数/提示 | 扩展设置、角色设置、slash 覆盖、提示生成 | `index.js:2990-3334,5384-5449` |
| 执行 | 浏览器请求应用 `/api/sd/*`，服务端代理外部模型/ComfyUI | `index.js:3317-3450`、`src/endpoints/stable-diffusion.js` |
| 文件/持久化 | `saveBase64AsFile` 保存结果；消息随后保存为聊天 JSONL | `index.js:3445-3449,4966-5001` |
| 再创作 | media swipe、slash command、function tool | `index.js:5149-5334,5452-5526` |

```text
画笔菜单/消息画笔、/imagine 或 Agent GenerateImage
  -> generatePicture：判定模式，取得聊天/自由/头像/LLM 提示词，合并负向提示和角色前缀
  -> sendGenerationRequest：按 source 选择外部 API、ComfyUI 或 RunPod 路径，携带 AbortSignal
  -> 成功数据 -> saveBase64AsFile 写媒体文件 -> URL
  -> 新生成：sendMessage 创建含 extra.media 的聊天消息并 saveChat
     或消息级重生：将新 MediaAttachment 追加至原消息并 saveChat
  -> 聊天媒体画廊预览；下一次 media swipe 可沿用标题/负向提示和尺寸再生成
  -> function tool 返回 URL，工具结果再进入模型工具调用循环
```

## 1. 创作入口、触发者与事实对象

用户可以由底部画笔菜单选择角色、用户、背景、最后消息等模式；每条消息上的画笔可对当前消息或已选媒体重生；`/imagine`（别名 `/sd`、`/img`、`/image`）支持命名参数。`GenerateImage` function tool 在开关启用时注册，模型传入 prompt 后复用同一 `generatePicture`。`public/scripts/extensions/stable-diffusion/index.js:5024-5073,5452-5526`。

结果不是独立任务表。新生成会建一条 ChatMessage，其中 `extra.media` 的单项保存 URL、图片/视频类型、标题、生成模式、负向提示与 generated 来源；消息级重生在现有 `extra.media` 数组追加新项并移动选择索引。聊天消息和磁盘文件共同是事实源。`index.js:4966-5001,5149-5234`。

这使生成结果自然进入聊天历史和消息渲染器，但未建立全局资产身份。本次在 Stable Diffusion 扩展及其端点范围内未找到跨聊天资产索引、提示词搜索、标签、媒体任务表或结果版本树。

## 2. 参数、素材与模型/渲染执行

提示词可直接来自自由模式，或由安静 LLM 调用从角色、场景、最后消息等聊天上下文生成；多模态模式会读取用户/角色头像并请求视觉描述。扩展随后合并全局与角色正负前缀，按模式临时调整纵横尺寸，生成后恢复原设置。`public/scripts/extensions/stable-diffusion/index.js:2990-3334`。

slash command 可临时覆盖 seed、宽高、steps、CFG、模型、采样器、scheduler、VAE、upscaler、高分修复和降噪等设置，并在结束后恢复原设置。消息级重生保留旧附件的标题、负向提示以及已有宽高，再生成一个新附件。`index.js:5271-5334,5384-5449`。

`sendGenerationRequest` 为 extras、Horde、Automatic1111 类端点、Draw Things、NovelAI、OpenAI、ComfyUI、RunPod、Stability 等来源分派实现。前端请求应用自己的 `/api/sd/*` 端点，服务端再负责代理、模型列表和 ComfyUI workflow 文件读写/生成。具体 provider 成功率、参数兼容性及远端数据保留不由本次静态调查确认。`index.js:3317-3450`、`src/endpoints/stable-diffusion.js:385-634,2192-2193`。

## 3. 任务状态、回调、取消与失败

生成期间显示可停止的非阻塞加载器，并把 stop 事件接到 `AbortController`；消息级画笔再次点击也会中止自己的 controller。请求失败或中止通过 toast 收口，不会写入成功媒体项。`public/scripts/extensions/stable-diffusion/index.js:3038-3092,3423-3443,5149-5179`。

前端没有持久化任务状态、远端 job ID、进度条或统一 callback 表。部分 provider 内部可能异步，但在这条扩展主链中均被封装为等待结果的 Promise；本次没有运行网络请求，不能确认 AbortSignal 是否会取消远端工作或仅终止浏览器等待。切换聊天后收到的结果会被丢弃，避免保存到错误会话。`index.js:3439-3443`。

## 4. 结果、历史、资产与工程持久化

成功数据先由 `saveBase64AsFile` 以角色名和时间构成文件名写为媒体文件，随后把返回 URL 放入消息附件，并立即调用 `saveChat`。既有生成式输出笔记确认聊天为 JSONL；因此消息元数据随历史恢复，文件路径则依赖应用的媒体目录与文件服务。`public/scripts/extensions/stable-diffusion/index.js:3445-3450,4966-5001`。

附件记录保存结果 URL 和部分创作语义，但没有模型、完整配置、seed 或文件 hash。`/imagine` 在显式传入宽高时会补写该附件的宽高，以便后续重生匹配尺寸；这不是完整参数档案。`index.js:5492-5523`。

ComfyUI workflow 文件可列出、读取、保存、删除和改名，保存在用户 workflow 目录；它们服务于后续 provider 请求，未见每个媒体附件链接到某个 workflow 快照或节点执行记录。`src/endpoints/stable-diffusion.js:485-562`。

## 5. 预览、编辑、重试、分支与复用

媒体结果随消息以内联图片/视频画廊展示，消息级画笔可从当前附件读取提示词、负向提示和可用尺寸，重新请求并追加新附件。用户可通过 media 索引在同一消息选择候选；向右 overswipe 在设置允许时也会自动触发这种再生成。它是线性候选积累，不是带父子关系的版本 DAG。`public/scripts/extensions/stable-diffusion/index.js:5204-5234,5271-5375`。

没有确认的像素编辑、局部重绘、参考图编辑器、资产画廊或媒体导出项目。生成文件 URL 可以由聊天附件显示、保存或被工具返回，构成有限的再次引用；本次未找到 Agent 按历史媒体 ID 浏览或修改附件的专用工具。

## 6. Agent 回流、外部依赖与权限

启用时，`GenerateImage` 仅公开一个必填 prompt 参数，调用共享生成主链并返回编码后的 URL。扩展可设置工具触发生成的消息是否在聊天中可见；因此 Agent 调用既能获得 URL 工具结果，也可选择留下媒体消息。工具注册、模型工具循环和权限策略属于 Agent 工具类目。`public/scripts/extensions/stable-diffusion/index.js:5004-5021,5452-5484`。

外部依赖包括所选图像 API、本地/远程 ComfyUI、RunPod 或其他提供商；服务端是代理和 workflow 文件管理者，不在项目内运行扩散模型。没有本仓库内 FFmpeg 编码链。访问可用性先按对应 URL 或 secret 配置检查，未配置即拒绝生成。`index.js:5076-5136`。

## 7. 设计取舍、已确认边界与未验证事项

设计把媒体当作聊天消息的可选投影，结果能自然跟随角色聊天、swipe 和导出，但全局资产管理与媒体创作历史被牺牲。每次生成等待一个 Promise 并直接存文件，简化了 UI 和恢复；代价是没有可持续观察的异步任务对象。ComfyUI workflow 被视为配置资源而非结果工程。

已确认边界：在 Stable Diffusion 扩展、`src/endpoints/stable-diffusion.js` 和既有聊天媒体链范围内，本次未找到全局媒体资产库、任务队列/回调、进度恢复、内容去重、生成参数全快照、媒体版本 DAG、媒体编辑器或模型可查询的媒体历史。普通附件和其他 provider 的语音/视频端点不自动归入该图像生成闭环。

未验证事项：未运行任何 source 的图像或视频生成、文件写入、聊天保存、工具调用、ComfyUI workflow 或取消；未验证 provider 的异步/轮询行为和 AbortSignal 的远端效果；未运行媒体画廊、overswipe 及消息重生 UI；未运行测试。

## 8. 关键源码索引

- `public/scripts/extensions/stable-diffusion/index.js:2990-3450`：生成入口、提示处理、provider 分派、取消、结果落盘。
- `public/scripts/extensions/stable-diffusion/index.js:4966-5001`：媒体附件消息创建与聊天保存。
- `public/scripts/extensions/stable-diffusion/index.js:5024-5073,5149-5334`：画笔入口与消息级媒体重生。
- `public/scripts/extensions/stable-diffusion/index.js:5384-5526`：slash 参数覆盖与 `GenerateImage` function tool。
- `public/scripts/extensions/stable-diffusion/index.js:5076-5136`：来源配置可用性判断。
- `src/endpoints/stable-diffusion.js:385-634,2192-2193`：ComfyUI workflow/生成代理路由。
- `../生成式输出与运行时/SillyTavern-生成式输出与运行时调查笔记.md`：聊天 JSONL、媒体渲染和通用工具回流的交接。
