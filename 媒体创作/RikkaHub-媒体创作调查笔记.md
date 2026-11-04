# RikkaHub 媒体创作调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：静态源码走读；以当前快照的调用链为依据，逐层复核媒体创作页与前台服务、`mediagen` 模块的模型/能力/适配器、Room 实体与仓储、文件目录布局，以及旧图片生成页与聊天内置图片生成两条旁路；未启动应用、未连接任何生成服务、未运行测试
>
> 调查范围：媒体创作会话与时间线、参数与能力收窄、图像/视频生成的提交与轮询、任务状态机与取消恢复、产出落盘与版本切换、Provider 配置与模型清单、聊天内图片生成与旧图库页的边界、音频与语音的边界；不含通用聊天渲染、消息树、Provider/Key 管理机制本身
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 在当前快照中把媒体生成做成了独立子系统，同时保留了两条更早的旁路。

主链路是 **M1 模型生成工作站 + M3 资产与工程工作区**的组合：从抽屉进入“媒体创作”，每次创作是一条会话，会话里有输入区草稿与按时间排列的生成项；每项可以保留多个版本。生成分图像与视频两类，统一由 `mediagen` 模块的 Provider 适配器承担；提交后按厂商协议走同步返回或创建任务 + 轮询，产出下载到应用私有目录并按相对路径登记进 Room。前台服务负责在后台继续轮询与下载，应用被杀后带 `taskId` 的记录可以在下次启动时接着查询。

第二条是聊天内的服务端内置工具产图：结果只是消息里的图片 part，由输出转换器落盘，不属于媒体创作记录。第三条是旧的独立图片生成页（`Screen.ImageGen` + `GenMediaEntity`），入口仍在抽屉里，但功能面比媒体创作窄。

音频与语音仍是边界样本：`speech` 模块提供 TTS 与实时 ASR，两者都不产生可保存的媒体资产。

据此，RikkaHub 已具备“专用入口、参数化模型调用、独立资产记录、结果预览与管理、异步任务状态机、版本语义”，但媒体创作与聊天附件仍不互通，也没有跨记录的素材库或工程文件概念。所有结论来自静态源码；真实模型调用、下载与落盘效果未运行验证。

## 系统边界与完整主链

| 层 | 承担者 | 静态证据 |
|---|---|---|
| 创作入口 | 抽屉 → 媒体创作会话列表 / 新建会话（`Screen.MediaCreationSessions`、`Screen.MediaCreation`） | `ui/pages/chat/ChatDrawer.kt`、`RouteActivity.kt` 的 `openNewMediaCreation` |
| 会话与时间线 | `MediaCreationSession` / `MediaCreationNode` / `MediaCreationRecord` | `data/model/MediaCreation.kt`、`data/repository/MediaCreationRepository.kt` |
| 输入区 | `MediaCreationDraft`（模型、提示词、素材、参数、编辑中的项） | `ui/pages/mediacreation/MediaCreationComposer.kt`、`MediaCreationVM.kt` |
| 能力与参数 | `MediaGenerationCapabilities` / `MediaGenerationParameter`，按模型裁剪 | `mediagen/src/main/java/me/rerere/mediagen/provider/MediaGenerationCapabilities.kt` |
| 厂商适配 | `MediaGenerationProviderSetting` 的五个子类 + `MediaGenerationManager` | `mediagen/.../provider/` |
| 任务执行 | `MediaCreationService`：提交、轮询、下载、取消、恢复 | `service/MediaCreationService.kt`、`service/MediaCreationForegroundService.kt` |
| 产出与持久化 | 相对 `filesDir` 的路径 + Room 三张表 | `MediaCreationRepository`、`data/db/entity/MediaCreationEntity.kt` |

```text
用户：抽屉 -> 媒体创作 -> 新建/打开会话
  -> 输入区：选模型（图像或视频）、写提示词、可加素材、按模型能力展示参数
  -> MediaCreationService.submit(MediaCreationSubmission)
       -> 记录落库（PREPARING，含 params/inputs）
       -> 上传或准备素材、解析 Provider 设置与模型
       -> manager.create(...) 或同步调用
            -> 有任务 id：轮询 manager.query，直到终态或取消
       -> 下载产出到 files/<媒体创作>/<sessionId>/<recordId>/
       -> 更新记录（SUCCEEDED + outputs 列表、封面、尺寸/时长/尾帧）
  -> 页面按会话观察时间线，项内可切换版本、再来一次、修改后重生成
```

另两条旁路不在媒体创作子系统内：聊天抽屉的另一项“图片生成”仍打开旧页，调用 OpenAI 兼容图像接口并把结果登记进 `GenMediaEntity`；聊天过程中模型调用服务端内置图片工具产出的图片只是消息 part。

## 1. 入口、会话与事实对象

媒体创作有两个页面：会话列表与单个会话。抽屉入口直接为“新建会话”打开新页，会话列表页则列出历史会话、封面与进行中数量（`ui/pages/mediacreation/MediaCreationSessionsPage.kt`、`MediaCreationSessionsVM.kt`）。前台服务通知携带会话 id，点按可直达对应会话（`RouteActivity.kt` 读取 `EXTRA_MEDIA_SESSION_ID`）。

事实对象分四层：

| 对象 | 关键字段 | 语义 |
|---|---|---|
| `MediaCreationSession` | id、标题、草稿、创建/更新时间、项数、进行中数、封面 | 一条创作会话 |
| `MediaCreationNode` | 记录、版本下标、版本总数 | 时间线上一项；同一项可有多个版本 |
| `MediaCreationRecord` | 会话/项 id、Provider、模型、`MediaKind`、提示词、参数、输入素材、状态、`taskId`、错误、输出列表 | 一次生成尝试 |
| `MediaCreationOutput` | 相对路径、mime、宽高、时长、封面图、尾帧图 | 已落盘的产出 |

`MediaCreationDraft` 是输入区状态，含所选模型 id、提示词、素材列表、参数与 `editingNodeId`；从历史项“修改后重生成”时填入该 id，结果作为同一项的新版本而不是新项（`data/model/MediaCreation.kt`）。参数模型把数量、分辨率、宽高比、时长、是否带音频、水印、种子、提示词增强都设为可空，null 表示交给接口默认值。

## 2. 能力收窄与参数装配

页面不直接暴露全量参数，而是按所选模型的能力描述决定显示哪些项。`MediaGenerationManager` 把 `MediaKind` 与 Provider 设置映射到 `MediaGenerationCapabilities`：允许的参数集合、必填参数、可接受的图片角色、是否支持视频输入、首尾帧与参考素材是否互斥、提示词是否必填、素材是否必须公网地址（`mediagen/.../MediaGenerationCapabilities.kt`）。

上层在提交前做两层裁剪：切换模型后，旧模型留下的参数按新能力过滤（`MediaCreationParams.supportedBy`），缺必填项时用默认值补齐；输入素材按能力过滤，图片按 `ImageRole` 区分首帧、尾帧与参考图，视频输入只在支持时保留（`data/model/MediaCreation.kt` 的 `supportedBy`/`withRequired`）。这些规则在提交前再过一遍，避免界面上已选、但当前 Provider 不接受的值进入请求。

Provider 配置是独立的：`MediaGenerationProviderSetting` 保存厂商凭据与模型列表，同一份配置可同时提供图像和视频模型，但适配器实现覆盖的 `supportedKinds` 才决定可用种类。当前有五个子类：OpenAI（图像）、OpenRouter（图像 + 视频）、火山方舟（图像 + 视频）、阿里云百炼（图像 + 视频）、MiniMax（视频）。下载产出时是否附带 API Key 由 `downloadHeaders` 决定，默认只对同源地址加 Bearer，避免把密钥发给第三方签名地址（`mediagen/.../MediaGenerationProviderSetting.kt`）。

设置侧有独立入口：媒体 Provider 列表与详情页、模型清单编辑（`ui/pages/setting/SettingMediaPage.kt`、`SettingMediaProviderDetailPage.kt`、`components/MediaGenerationProviderConfigure.kt`）。这与聊天 Provider 的二维码导入/扫码是两套互不相同的配置面板。

## 3. 提交、轮询、下载与取消

执行集中在 `MediaCreationService`。它对每条记录建立 Job 并按记录 id 注册，状态机如下（`data/model/MediaCreation.kt`、`service/MediaCreationService.kt`）：

- `PREPARING`：素材尚未上传或请求尚未组装完成；没有服务端任务。
- `QUEUED` / `RUNNING`：已提交，记录持有 `taskId`（异步接口）或正在等待同步响应。
- `DOWNLOADING`：接口已返回产出地址，正在把文件下载到本地。
- `SUCCEEDED` / `FAILED` / `CANCELLED`：终态；失败时清空 `taskId` 并保留错误信息。

轮询用固定间隔，查询失败按次数退避重试；下载失败会重试并重开连接——源码注释说明取消时线程可能卡在 `read()`，因此要主动关闭连接让读取立刻抛出。取消只停止本地等待，已经提交给服务端的任务无法撤回，`taskId` 会保留，之后可以重试接着查询（`MediaCreationService.cancel`、`retry`）。

前台服务与通知负责保活：生成在应用不在前台时继续，完成后通过通知反馈；`MediaCreationForegroundService` 持有通知通道与启动/停止逻辑，`RouteActivity` 负责点按通知跳转。

应用重启后的恢复由 `resumePending()` 完成：遍历仍处于活动状态且带 `taskId` 的记录，重新注册 Job 继续查询，不必重新提交（`MediaCreationService.kt`）。

## 4. 落盘、持久化与版本

文件按会话与记录分目录：`filesDir/<媒体创作>/<sessionId>/<recordId>/...`，草稿的素材另放会话下的草稿目录。产出的输出、封面与尾帧都以相对 `filesDir` 的路径存进记录，记录里的素材同理（`MediaCreationRepository` 的 `sessionDir`/`recordDir`、`data/files/MediaCreationFiles.kt`）。

素材导入会做统一化：图片先按 EXIF 摆正、长边缩到上限、透明图保留 PNG 其余转 JPEG；视频读取尺寸与时长并可抽帧做封面。这样各家接口对 HEIC、超大尺寸与 EXIF 方向的差异被压在导入阶段（`data/files/MediaCreationFiles.kt`）。

持久化是 Room 三张表：会话、节点、记录；节点表维护 `selectedRecordId`，记录表的参数、输入、输出以 JSON 列保存。仓储提供按会话观察时间线、切换版本、删除项/会话、查询进行中记录与最近成功记录等接口，删除会话按外键级联删节点与记录（`data/db/entity/MediaCreationEntity.kt`、`MediaCreationRepository.kt`）。

版本语义只到“同一项的多个记录”：再来一次或修改后重生成都记在原项的 `nodeId` 下，界面显示选中版本并可左右切换。没有跨项的素材库，也没有把成功产出直接作为下一次输入的回填入口（`editingNodeId` 只回填输入区，素材需重新选择）。

## 5. 与聊天、旧图库和语音的边界

**聊天内图片生成**仍是独立路径：模型通过服务端内置工具产图，流式合并后在生成收尾时由输出转换器把 base64 写成本地文件，图片作为消息 part 随会话 JSON 落库。它没有记录、没有任务，也不出现在媒体创作列表里（细节见 [生成式输出与运行时笔记](../生成式输出与运行时/RikkaHub-生成式输出与运行时调查笔记.md)、[会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)）。

**旧图片生成页**仍可达：抽屉里“图片生成”跳 `Screen.ImageGen`，页面用全局 `imageGenerationModelId` 选图像模型，调用 OpenAI 兼容的生成/编辑接口，结果写应用私有目录并登记 `GenMediaEntity`（生成或编辑类型、来源路径）。它不支持视频，没有会话、任务或版本，与媒体创作的表结构互不相干（`ui/pages/imggen/ImgGenPage.kt`、`ImgGenVM.kt`、`data/db/entity/GenMediaEntity.kt`）。

**语音**不产生媒体资产：TTS 分片在内存播放，ASR 只用于听写；`speech` 模块的 Provider 细节属于语音专题，本笔记只确认它们不进入媒体创作或旧图库的持久化。

**Agent 侧没有媒体创作工具**：工具目录里没有调用媒体生成本地工具，媒体创作只能由用户从界面发起；聊天中模型能触发的只有服务端内置图片工具（见 [Agent 工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)）。

## 6. 设计取舍与已确认边界

- 生成与展示解耦：提交、轮询、下载都在服务层完成，页面只观察 Room 流；因此退出会话页或应用退到后台不会中断任务。
- 记录不可变、期望可变：同一次尝试的记录只在状态与产出上更新，重试沿用同一条记录（带 `taskId` 时接着查询），而“再来一次”建新记录、同项多版本。
- 能力来自适配器而非模型清单：参数是否出现、素材是否必须公网地址等由适配器常量描述；具体模型是否接受某个值仍由接口决定，界面不对取值做过细校验。
- 只保留本地相对路径：记录不保存绝对路径，换设备或恢复备份后依赖统一根目录；旧图库页仍用相对路径登记。
- 密钥按同源规则下发：仅当产出地址与配置的 `baseUrl` 同源时才带 `Authorization`，其余地址原样下载。
- 视频生成的产品缺口已补上：旧快照的 `videogen` 只有库没有调用点，当前由 `mediagen` + 媒体创作页 + 前台服务接通，但聊天内的服务端内置工具仍只覆盖图片。

## 7. 未验证事项

- 真实厂商接口的提交/查询/下载字段映射与时序，包括各 Provider 的轮询终态、失败信息与限流表现；本次只做静态阅读。
- 前台服务在应用被杀、系统回收与省电模式下的实际存活；`resumePending()` 在重启后的恢复成功率未验证。
- 视频下载、封面抽取与尾帧图在真实文件上的表现，以及长视频的内存占用。
- 备份与恢复是否包含媒体创作目录（`MediaCreationRepository` 与备份目录集合的对应关系本次未逐项核对）。
- 同一记录并发提交、删除与取消的竞态；删除会话时正在进行的任务是否被正确取消与清理文件。
- 能力描述与厂商文档的一致性（例如某模型的必填参数遗漏时，界面会显示默认值而请求失败）。

## 8. 关键源码索引

- 会话与记录模型：`app/src/main/java/me/rerere/rikkahub/data/model/MediaCreation.kt`
- 持久化：`app/src/main/java/me/rerere/rikkahub/data/db/entity/MediaCreationEntity.kt`、`data/repository/MediaCreationRepository.kt`
- 执行服务：`app/src/main/java/me/rerere/rikkahub/service/MediaCreationService.kt`、`MediaCreationForegroundService.kt`
- 页面与输入区：`app/src/main/java/me/rerere/rikkahub/ui/pages/mediacreation/`（`MediaCreationPage.kt`、`MediaCreationComposer.kt`、`MediaCreationSessionsPage.kt`、`MediaCreationVM.kt`）
- 媒体文件处理：`app/src/main/java/me/rerere/rikkahub/data/files/MediaCreationFiles.kt`
- 生成抽象与适配器：`mediagen/src/main/java/me/rerere/mediagen/provider/MediaGenerationManager.kt`、`MediaGenerationProvider.kt`、`MediaGenerationProviderSetting.kt`、`MediaGenerationCapabilities.kt`、`provider/providers/`
- 设置入口：`app/src/main/java/me/rerere/rikkahub/ui/pages/setting/SettingMediaPage.kt`、`SettingMediaProviderDetailPage.kt`
- 旧图片生成页与实体：`app/src/main/java/me/rerere/rikkahub/ui/pages/imggen/`（`ImgGenPage.kt`、`ImgGenVM.kt`）、`data/db/entity/GenMediaEntity.kt`
- 语音边界：`speech/src/main/java/me/rerere/tts/`（TTS provider 与控制器）
