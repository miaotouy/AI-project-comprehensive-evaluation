# Codex 媒体创作调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`021fccb046508938c4754982efccfb51d6e8356e`（分支：`main`）
>
> 调查方式：静态源码检索与入口核对；遍历约 166 个成员 crate 的目录，并按 image、imagegen、video、audio、speech、tts、music、diffusion、comfy、media、artifact 等关键词检索源码，重点读取唯一命中的图片生成扩展、其工具定义、产物落盘与线程条目投影，并核对实时语音会话的边界；未调用模型或媒体服务
>
> 调查范围：是否存在媒体专用工作台、生成任务、资产/历史、编辑与结果回流；不覆盖普通图片附件的消息渲染、模型上下文中的图片压缩，也不覆盖仓库外的托管服务
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**本类目不适用（N/A），不纳入媒体创作正式横向比较。** Codex 是编码 Agent，没有图片/视频/音乐/音频的创作工作台、任务队列、资产库或媒体工程对象。本次唯一确认的媒体生成面是 `image_gen.imagegen` 单次图片生成/编辑工具：它由模型调用，结果以图片生成条目回到线程，同时另存一份本地图片文件；另有特性开关控制的简单 GIF 输出，但仍是同一次调用、同一工具。

按本类目的准入条件（媒体专用入口、独立任务/资产身份、可调参与再创作、异步任务语义、结果进入资产库或下一步工作流，至少满足三项），该工具只能算“一次图片 API 调用 + 消息附件”，未形成完整主链，因此按指南默认不计入。下面的卡片用于说明边界，而不是把 Codex 计为媒体创作项目。

检索按媒体关键词、crate 目录与命中复核三步展开，检索面见下表，命中结果随后说明。

| 类别 | 取值 |
|---|---|
| 生成能力关键词 | `imagegen`、`image_generation`、`ImageGeneration`、`generated_images` |
| 媒体类型关键词 | `video`、`audio`、`speech`、`tts`、`music` |
| 实现路径关键词 | `diffusion`、`comfy`、`stable-diffusion`、`workflow`、`media`、`artifact` |
| 搜索目录 | `codex-rs/ext`、`core`、`cli`、`tui`、`app-server`、`cloud-tasks`、`sdk` 与根目录文档 |

命中的生成能力只有 `codex-rs/ext/image-generation`；`voice-host`、`realtime_conversation` 与 `realtime-webrtc` 属于实时语音对话，承载的是对话音频流；`mermaid` crate 提供图表渲染，产出落在另一类内容上。

## 系统边界与检索依据

| 检索方向 | 结果 | 依据 |
|---|---|---|
| 图片生成 | 存在，单工具 | `ext/image-generation` 注册 `image_gen.imagegen`，模型 `gpt-image-2` |
| 图片编辑 | 存在，作为同一工具的一种输入模式 | 最多 5 张参考图或最近 5 张会话图片 |
| 动态图（GIF） | 存在，同一工具的可选输出 | 2–16 帧、后端合成，由特性开关控制（默认关闭） |
| 视频生成/编辑 | 本次未找到 | 无对应 crate、工具名、命令或配置项 |
| 音乐/音效/配音 | 本次未找到 | 无 TTS、音乐或音频生成模块 |
| 扩散/ComfyUI/节点工作流 | 本次未找到 | 无 workflow、节点图或本地推理服务接入 |
| 媒体任务与历史 | 本次未找到 | 无任务表、生成历史对象或跨会话资产库 |
| 资产编辑与复用 | 本次未找到 | 无媒体编辑器、版本、分支或项目文件 |

“本次未找到”限定于上述关键词与目录范围，不构成对仓库外插件市场或服务端能力的判断。

## 唯一的媒体相邻面：`image_gen.imagegen`

**入口与触发者。** 工具由扩展注册到工具表，模型在对话中自行决定是否调用；没有独立的媒体页面、画廊或命令。工具名与命名空间固定在 `codex-rs/ext/image-generation/src/lib.rs:8-9`，工具说明要求模型直接生成、不要反复确认（`imagegen_description.md:1-18`）。是否装配取决于特性开关与 Provider 能力：`image_generation` 特性默认开启（`codex-rs/features/src/lib.rs:1970-1981`），且当前 Provider 必须是 OpenAI、需要 OpenAI 认证或使用 OpenAI actor 授权，否则扩展返回空工具列表（`ext/image-generation/src/extension.rs:43-48,96-98`）。

**输入与约束。** 参数为提示词、透明背景开关、参考图路径列表或“包含最近 N 张会话图片”，参考图上限 5 张（`ext/image-generation/src/tool.rs:101-114`）。说明文档要求编辑时优先用本地路径，只有无法取得路径时才引用最近图片，二者不能同时使用（`imagegen_description.md:12-18`）。输出大小上限 32 MiB，base64 传输有对应换算上限（`tool.rs:69-72`）。

**动态图是可选输出而非独立能力。** 开启 `image_generation_animation` 特性后，工具参数多一个可选的 `gif`：不给字段即普通图片，给空对象取默认值（9 帧、每帧 200 毫秒），也可指定帧数与帧间隔，帧数限制 2–16。

编辑既有 GIF 时先看帧、再拼成等格 spritesheet 作为参考图重新生成，GIF 本身只作为参考素材（`ext/image-generation/src/tool.rs:103-113`、`imagegen_gif_description.md:1-4`）。

产物格式按编码头识别：GIF 存为 `.gif` 并标记 `image/gif`，其余按 PNG 处理（`ext/image-generation/src/artifact.rs:8-30`、`:57-65`）；该特性处于 UnderDevelopment 且默认关闭（`codex-rs/features/src/lib.rs:1977-1981`）。

**执行与结果。** 调用走当前 Provider 的图片接口，成功后把图片写到 codex home 下的 `generated_images/<session>/<call_id>.png`（`ext/image-generation/src/artifact.rs:5-65`）。工具返回给模型的提示只说明“已保存到该路径、已展示给用户、无需在回复里再渲染 Markdown 图片”（`artifact.rs:67-76`）。失败以带原因的结构化失败对象返回，并区分额度耗尽等情况（`ext/image-generation/src/tool.rs:116-128` 的结束事件字段）。

**持久化与回流。** 线程历史中会出现图片生成条目（`ImageGeneration`），并按旧式事件补一条生成结束记录（`ext/image-generation/src/tool.rs:116-128`；条目投影见 `app-server-protocol/src/protocol/v2/item.rs:478,1066-1070`）。rollout 在分页历史模式下保留图片生成响应项，旧式历史模式保留 `ImageGenerationEnd` 事件（`codex-rs/rollout/src/policy.rs:95,154`）。因此生成结果有“线程条目 + 本地文件”两处痕迹，但没有独立任务 ID、状态机、取消、重试或历史列表。

**准入判断。**

| 准入条件 | 判断 | 说明 |
|---|---|---|
| 媒体专用入口/工作台/模型目录 | 部分满足 | 有专用工具与固定模型，但没有工作台或模型选择 |
| 独立任务、历史、资产或工程身份 | 不满足 | 只有线程条目和按调用 ID 命名的 PNG |
| 可调参、参考图、重试、编辑、继续创作 | 部分满足 | 支持参考图编辑与透明背景；重试等于再次调用；无分支/版本 |
| 异步任务、失败/取消/回调/限额 | 不满足 | 同步工具调用，等待期间由 Agent 回合承载；无任务取消 |
| 结果进入资产库或下一步工作流 | 不满足 | 文件留在 codex home，工具提示不要在回复中再次渲染图片 |

结论：满足项不足三项，且不具备独立媒体任务或资产生命周期，故不纳入 `M1`–`M5` 任一正式工作站分型。

## 边界样本

- **普通图片附件与查看**：`view_image` 等工具让模型查看本地图片（测试样例见 `codex-rs/tui/src/app/transcript_export_tests.rs:206-232` 的 imageView 条目）。这是输入理解，不是创作。
- **实时语音对话**：语音会话通过 WebRTC 传输音频帧，并列举可选声音（`codex-rs/core/src/realtime_conversation.rs:64-100,688-689`；`realtime-webrtc`、`voice-host` crate）。它生成的是实时对话语音流，不产生可保存、可编辑的音频资产，也没有创作历史。
- **图片生成结果的导出**：Markdown 导出把它当作一条活动记录，保留调用 ID、状态、改写后的提示词与保存路径，不内联图片（见对话导出笔记第 7 节）。图片在导出模型里归属消息内容，随消息一起序列化。

## 未验证事项

- 未调用真实图片接口，未验证 `gpt-image-2` 的实际参数、响应格式、计费、内容审核与失败码。
- 未在 TUI 中观察生成图的展示、缩放、透明背景效果与本地文件清理行为。
- 未验证非 OpenAI Provider、Bedrock、Azure 等组合下工具是否彻底隐藏，以及 `image_generation` 特性关闭后的回退表现。
- 未检查仓库外插件或服务端是否提供视频、音频等媒体能力；本笔记的 N/A 结论只覆盖本仓库快照。

## 关键源码索引

- 扩展注册与可用性：`codex-rs/ext/image-generation/src/extension.rs:33-136`、`codex-rs/ext/image-generation/src/lib.rs:8-9`
- 工具契约与执行：`codex-rs/ext/image-generation/src/tool.rs:68-129`、`imagegen_description.md:1-20`、`imagegen_gif_description.md:1-4`
- 产物路径与提示：`codex-rs/ext/image-generation/src/artifact.rs:5-76`
- 特性开关：`codex-rs/features/src/lib.rs:385-388,1258-1276,1900-1905`
- 条目与持久化：`codex-rs/app-server-protocol/src/protocol/v2/item.rs:478,1066-1070`、`codex-rs/rollout/src/policy.rs:95,154`
- 实时语音边界：`codex-rs/core/src/realtime_conversation.rs:64-100,688-689`
