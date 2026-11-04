# OpenOcta 媒体创作调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态源码与文档检索。按 image、imagegen、image_generation、video、audio、speech、tts、music、voice、diffusion、comfy、ffmpeg、midjourney、dall-e、whisper、media、transcode 等关键词遍历 `src`、`ui/src`、`docs` 与 README；对命中项逐一读取注册表、handler 与调用方；未调用任何媒体模型或外部服务
>
> 调查范围：是否存在媒体专用入口、生成/渲染任务、参数与素材、任务状态、资产/历史、预览编辑与再次调用。不覆盖普通图片附件的消息渲染、浏览器截图工具、第三方 MCP/Skill 在仓库外提供的能力
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

**本类目不适用（N/A），不纳入媒体创作正式横向比较。** OpenOcta 是面向 IT Ops 的桌面 Agent，仓库内没有图片、视频、音频或 3D 的创作工作台、媒体任务、资产库或工程对象。对话中出现的图片和文件主要来自两处：用户上传的附件，以及 Agent 通过文件工具写出、再被转成聊天附件的产物。两者都不是生成式媒体创作。

按本类目准入条件（媒体专用入口、独立任务/资产身份、可调参与再创作、异步任务语义、结果进入资产库或下一步工作流，至少满足三项），当前实现不满足任何一项的完整组合。

## 检索范围与关键词

| 检索方向 | 结果 | 依据 |
|---|---|---|
| 图片生成 / 文生图 | 本次未找到 | 无生成工具、模型目录、参数或调用；`agent/tools` 下只有附件、浏览器、Cron、文件交付等工具 |
| 图片编辑 / 合成 | 本次未找到 | 无画布、蒙版、图层或图片处理依赖 |
| 视频生成 / 转码 | 本次未找到 | 无 ffmpeg、转码任务或视频输出；视频只作为消息内容类型被转发给模型 |
| 音频 / 音乐 / 配音 | 未接通 | 有 `tts.*` 方法注册与 `tools.media.audio` 配置字段，但无转换实现与前端入口 |
| 扩散 / ComfyUI / 节点工作流 | 本次未找到 | 无 diffusion、comfy、workflow 相关包或配置 |
| 媒体任务 / 历史 / 资产库 | 本次未找到 | 无任务表、生成历史、资产去重或版本对象 |
| 生成结果回流 | 不成立 | 附件块只承载用户文件或 Agent 写出的文件，不是媒体任务结果 |

「本次未找到」限定于上述关键词与本仓库快照，不构成对仓库外 Skill 市场、MCP 服务器或商业服务的判断。

## 命中的边界实现

**TTS 方法壳。** Gateway 注册了 `tts.status`、`tts.providers`、`tts.enable`、`tts.disable`、`tts.convert`、`tts.setProvider` 六个方法（`src/pkg/gateway/handlers/health.go:103-108`）。其中状态接口固定返回 `enabled: false`、provider 为 `openai`、provider 列表为空；启用/禁用只回显布尔值，不改变任何状态；`tts.convert` 与 `tts.setProvider` 直接返回 `method_not_implemented`（`src/pkg/gateway/handlers/tts.go:20-75`）。前端没有任何 TTS 入口或音频播放相关代码。

**视频只作为输入。** 消息内容块支持 `video` 类型，模型适配层会把它转成 `video_url` 的 data URL 交给模型（`src/pkg/agent/eino/event_bridge.go:110-125`）。这是对用户上传视频的理解，不是视频生成或编辑。

**媒体理解只有配置面。** 配置结构里有 `tools.media.models/concurrency` 以及 `image`、`audio`、`video` 三组理解参数，包含启用开关、字节上限、提示词、超时、语言、作用域与附件策略（`src/pkg/config/schema.go:1274-1310`）；Control UI 也为这些键提供了中英文标签（`ui/src/ui/config-field-labels.ts:61-69`）。但除配置定义外，本次未找到消费这些字段的理解管线、工具或调用点，因此「媒体理解」同样只有配置面，不能算作已实现的媒体能力，更不是创作。

**图片与文件的交付。** Agent 写出 HTML、Markdown、文本、PDF 或图片后，后端读取文件并以 base64 内容块回填消息，前端提供预览与下载；单文件上限为 HTML/PDF 2 MiB、图片 5 MiB、文本 2 MiB（`src/pkg/agent/tools/deliverable_files.go:32-34`、`:118-245`）。图片在这里是「产物文件」，没有提示词、参考图、生成参数、任务状态或历史。

**浏览器截图。** 内置 Chromium 工具提供 `screenshot` 动作，用于网页自动化取证（`src/pkg/agent/tools/browser_tool.go:60-75`、`src/pkg/browser/manager.go:323-340`）。捕获对象是网页视口，不是可编辑的媒体工程，也不进入资产库。

**本地模型下载。** `embeddedmodels` 与模型广场用于下载本地对话/嵌入模型，属于模型运行时资源，不是媒体生成模型目录（`ui/src/ui/app-embedded-models.ts:131-175`、`ui/src/ui/views/model-plaza.ts:279-310`）。

## 为什么不满足准入

| 准入条件 | 判断 | 说明 |
|---|---|---|
| 媒体专用入口、工作台或模型目录 | 不满足 | 无媒体页面、工具族或模型能力目录；TTS 仅有未实现的 RPC 壳，媒体理解只有配置字段 |
| 结果具有独立任务、历史、资产或工程身份 | 不满足 | 图片/视频只是消息附件或内联内容块 |
| 用户或 Agent 可调参、提供参考、重试、分支、编辑或继续创作 | 不满足 | 无媒体参数、参考素材与再次生成入口 |
| 生成/渲染/异步任务具备失败、取消、回调或限额 | 不满足 | 不存在媒体任务，因而也没有任务语义 |
| 结果可进入资产库、文件服务、聊天回流或下一次创作 | 不满足 | 产物文件只回到当前消息，无资产索引与复用 |

结论：不属于 `M1`–`M5` 任一工作站分型，也不构成单次媒体 API 调用级别的边界样本（`tts.convert` 未实现）。

## 与相邻类目的交接

- 对话中的图片上传、附件预览与消息内联属于消息渲染/附件处理，不在本类目重复记录。
- Agent 写出的 HTML/PDF 报告及其下载属于生成式输出与任务产物交付，相关链路记录在对话导出与分享笔记的「附件、资源与离线封装」一节。
- 浏览器截图属于 Agent 工具能力，记录在独特功能笔记的工程边界，不计入媒体创作。
- TTS 未实现状态同时写入独特功能笔记的「声明不符与暂缓项」，避免在能力盘点中被误计。

## 未验证事项

- 未运行桌面端，未验证 UI 是否隐藏了未在源码中出现的音频/媒体入口。
- 未验证通过 MCP 或 Skill 市场安装的第三方能力是否在运行时提供图片、视频或音频生成；本笔记只判定仓库自带实现。
- 未验证 `tts.*` 方法是否被旧版客户端或其他分支调用；当前快照中转换能力明确返回未实现。
- 未验证附件块中图片在聊天现场的缩放、格式转换与清理行为，这些属于渲染细节而非创作能力。

## 关键源码索引

- TTS 方法与状态：`src/pkg/gateway/handlers/tts.go:8-75`、`src/pkg/gateway/handlers/health.go:103-108`
- 媒体理解配置面：`src/pkg/config/schema.go:1274-1310`、`ui/src/ui/config-field-labels.ts:61-69`
- 视频输入转换：`src/pkg/agent/eino/event_bridge.go:110-125`
- 文件产物与图片附件：`src/pkg/agent/tools/deliverable_files.go:14-34`、`:118-245`
- 浏览器截图：`src/pkg/agent/tools/browser_tool.go:60-75`、`src/pkg/browser/manager.go:323-340`
- 模型下载边界：`ui/src/ui/app-embedded-models.ts:131-175`、`ui/src/ui/views/model-plaza.ts:279-310`
