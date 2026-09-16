# RikkaHub 媒体创作调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：静态源码走读；以当前快照的调用链为依据，逐层复核图片生成页、AI provider 图像接口、`videogen` 模块、`speech` 模块、Room 实体与文件管理器；未启动应用、未连接任何生成服务、未运行测试
>
> 调查范围：图片生成与编辑（provider 支持、参数、触发入口、落盘与展示）、视频生成（videogen 模块的模型与执行链）、音频与语音（TTS/ASR 入口与实现）、生成媒体的持久化（`GenMediaEntity`）、图库管理与复用、存储位置与生命周期；不含通用聊天渲染、消息树、Provider/Key 管理机制本身
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 在当前快照中同时存在三条相互独立的媒体链路，成熟度差异明显。

图片生成是唯一闭环的一条，可归为 **M1 模型生成工作站 + M3 资产与工程工作区**的轻量组合：从聊天抽屉进入独立的图片生成页，用参数表单调用 OpenAI 兼容的图像接口（生成与编辑），把结果以 base64 解码写入应用私有目录，并在 Room 中登记一条 `GenMediaEntity`；页面内的图库可预览、复制提示词、导出到系统相册和多选删除。但它是一条“单入口、单次调用”的链路：没有任务对象、没有参数历史、没有版本或分支，生成参数不随资产保存。

视频生成是 **M4 插件化媒体编排**的抽象层先行：`videogen` 模块把阿里云百炼万相、火山方舟 Seedance 与 MiniMax H3 统一为“提交任务 + 查询任务”的协议，并提供可取消的轮询 Flow；但当前快照中 app 模块只声明了 Gradle 依赖，没有调用点、UI、任务持久化或产物下载。也就是说，视频生成是“库已就位、产品未接线”，本次不把它计为已闭环的视频创作能力。

音频与语音是边界样本而非创作主链：`speech` 模块提供 TTS 与实时 ASR provider，但两者都不产生可保存的媒体资产。

据此，RikkaHub 满足媒体创作准入的“专用入口、参数化模型调用、独立资产记录、结果预览与管理”条件，但不具备一次完整主链之外的资产复用（生成结果不能直接作为下一次生成的参考或聊天附件）、异步任务状态机、媒体工程或版本语义。所有结论来自静态源码；真实模型调用、图像落盘效果与语音链路的行为均未运行验证。

## 系统边界与完整主链

| 层 | 承担者 | 静态证据 |
|---|---|---|
| 创作入口 | 聊天抽屉菜单 → 图片生成页（`Screen.ImageGen`） | `ChatDrawer.kt:372-379`、`RouteActivity.kt:395-397,637` |
| 参数与请求 | `ImageGenerationParams` / `ImageEditParams` | `ai/.../provider/Provider.kt:81-101` |
| 模型执行 | OpenAI 兼容 provider 的生成/编辑；Google 走聊天输出模态 | `providers/openai/OpenAIProvider.kt:202-312`、`providers/google/GoogleProvider.kt:349-353` |
| 结果落盘 | `ImgGenVM` 解码 base64、写文件、插库 | `app/.../ui/pages/imggen/ImgGenVM.kt:287-326` |
| 资产记录 | `GenMediaEntity` + `GenMediaDAO` + `GenMediaRepository` | `data/db/entity/GenMediaEntity.kt:7-27` |
| 管理与复用 | 图库网格：预览、复制提示词、导出相册、多选删除 | `app/.../ui/pages/imggen/ImgGenPage.kt:594-790` |

```text
用户：聊天抽屉选择“图片生成”
  -> ImageGenPage 表单（提示词、数量 1..4、尺寸、可选参考图）
  -> ImgGenVM.generateImage() / editImage()
  -> ProviderManager 按 provider 类型取实现，调用 OpenAI /images/generations 或 /images/edits
  -> Flow<ImageGenerationItem>（base64 + mimeType）逐步返回
  -> saveImageToStorage：decode -> filesDir/images/<ts>_<model>_<i>.png
  -> 插入 GenMediaEntity(path=images/..., modelId, prompt, createAt, type, sourcePaths)
  -> 页面顶部展示本次结果；图库分页读取同一张表
  -> 用户可预览 / 复制提示词 / 导出到系统相册 / 删除（先删库再删文件）
```

需要与另外两条链路分开理解：语音由 AI 工具或消息操作触发，音频在内存播放，既不落到图片目录，也不登记生成媒体表；视频只在自身模块内完成协议编排，没有连到图片生成页或任何任务仓库。

## 1. 创作入口、触发者与事实对象

图片生成只有一个用户入口，且只有用户本人可触发。聊天抽屉的溢出菜单里有“图片生成”项，点击后导航到 `Screen.ImageGen`，由 `RouteActivity` 渲染 `ImageGenPage`，页面内部用底部导航在“生成”和“图库”两个视图间切换（`ChatDrawer.kt:372-379`、`ImgGenPage.kt:205-230`）。本次未找到第二个入口。

触发者一侧，本地工具集里不存在图片生成工具，模型侧唯一相关的是内置工具标记 `BuiltInTools.ImageGeneration`。该标记的含义是把图像生成交给上游服务端执行，与图片生成页是两条不同的路径；其协议翻译与输出形态归属见 [生成式输出与运行时笔记](../生成式输出与运行时/RikkaHub-生成式输出与运行时调查笔记.md)。

事实对象分两层，且都没有任务身份。UI 层是 `GeneratedImage`，含 id、提示词、文件绝对路径、时间戳与模型名，仅存在于 ViewModel 状态和分页结果中（`ImgGenVM.kt:38-58`）。持久层是 `GenMediaEntity`，字段为自增 id、相对路径、模型标识、提示词、创建时间、类型以及可空的来源路径串（`GenMediaEntity.kt:7-27`）。类型只有 `image_generation` 与 `image_edit` 两种字面量，后者用来源路径以换行分隔记录编辑所用的参考图。视频与音频没有对应实体，本次未找到任何视频或音频资产表。

## 2. 参数收窄与生成/编辑两条产品路径

页面侧暴露的参数被有意收窄：张数被限制在 1 到 4，尺寸从 `ImageGenSize` 枚举中选，参考图最多保留 16 张（`ImgGenVM.kt:103-113,374-377`）。尺寸枚举覆盖 `auto` 以及 1024/1536/1792 几档方形、横向与纵向取值（`ai/.../ui/Image.kt:13-23`）。模型来自全局设置里的 `imageGenerationModelId`，选择器按 `ModelType.IMAGE` 过滤，因此图片生成只能选被标记为图像类型的模型（`ImgGenPage.kt:395-407`）。生成与编辑请求由两个数据类表达，字段基本一致，编辑请求额外带一个图片路径列表（`Provider.kt:81-101`）。

provider 支持面在源码中是非对称的：只有 OpenAI 实现覆盖了专用图像接口，生成与编辑分别走 `/images/generations` 和 multipart 形式的 `/images/edits`；Claude 实现直接返回“不支持”。各家 provider 的协议细节与请求组装归 [LLM渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)，本笔记只保留上述产品结论。

Google 侧没有专用图像接口，图像产出走聊天输出模态，得到的是聊天消息内容而不是图片生成页的资产；服务端内置工具产图同理，其机制归 [生成式输出与运行时笔记](../生成式输出与运行时/RikkaHub-生成式输出与运行时调查笔记.md)。

提交给接口的参数有一个值得记录的边界：两个参数类都带 `partialImages` 字段（默认 2），收集逻辑也能处理带 `partial` 标记的中间图（`ImgGenVM.kt:246-260`），但实际请求体只下发模型、提示词、张数与尺寸，未包含 `partial_images`（`OpenAIProvider.kt:212-226`）。据此推断，当前快照中增量预览分支在 OpenAI 路径上不会被触发；这是基于实现结构的推断，未运行验证。

## 3. 任务语义与结果落盘

图片链路没有任务对象，异步性只体现在协程与 Flow 上。`isGenerating` 是唯一的进行中状态，页面据此显示加载指示并允许把发送按钮变成取消按钮；取消直接终止当前协程，取消异常被静默放行，不写入错误提示。失败信息进入错误状态，页面用 toast 展示并立即清除（`ImgGenVM.kt:76-78,138-141,172-178`、`ImgGenPage.kt:258-263,426-438`）。本次未找到重试次数、退避、进度百分比、任务 ID 或断点续跑：一次生成是一个 Flow，收集完成即结束。

结果收集区分中间图与终图。中间图写入应用临时目录并作为预览展示，新中间图到达时删除上一张临时文件；终图才写入正式目录并登记数据库（`ImgGenVM.kt:234-295`）。这形成了一个粗粒度的“预览—定稿”两段式，但没有跨进程状态，页面关闭或进程结束后无法恢复正在进行的生成。

落盘路径是确定的：文件名由时间戳、模型显示名与序号拼成，写入 `filesDir/images`，数据库存的是 `images/<文件名>` 这样的相对路径，展示时再拼回绝对路径（`ImgGenVM.kt:297-326`、`FilesManager.kt:254-260`）。因此“文件在私有目录、记录在 Room”是这条链路的事实源，两者靠约定好的目录前缀关联，没有外键或内容哈希。查询面只有按创建时间倒序的分页查询、插入与按 id 删除（`GenMediaDAO.kt:11-21`）。

资产元数据非常有限。记录里能回答“什么时候、用哪个模型、什么提示词、生成还是编辑、用了哪些参考图”，但不能回答分辨率、seed、采样步数、耗时、实际请求体或上游请求 ID，这些参数既未随请求持久化，也未在编辑路径之外被保存（`GenMediaEntity.kt:7-27`）。

备份语义进一步印证了存储分离。备份压缩包只包含设置、可选的数据库，以及 upload、skills、fonts 三个目录（`data/sync/BackupManager.kt:37-64`）。`images` 目录不在其中，因此图片生成资产的二进制不会随内置备份、S3 或 WebDAV 同步带出；只有数据库记录会被备份，恢复后可能出现有记录无文件的组合。该后果由备份目录清单推得，未运行验证。

同一应用内还有另一套媒体文件生命周期：聊天中出现的图片进入 upload 目录并由附件实体登记，被附件同步、清理和备份覆盖，其机制归 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。两条链路共用应用私有目录，但不共用表、目录或清理策略。

## 4. 图库：展示、复用与删除

预览与展示分两处。生成中的结果在页面顶部以最多两张的网格展示，点击弹出预览对话框；已完成的结果在“图库”标签以两列自适应网格分页展示，卡片显示模型名与截断后的提示词（`ImgGenPage.kt:265-307,644-715`）。图库卡片的操作是复制提示词到剪贴板、导出图片到系统相册、删除；长按进入多选删除模式（`ImgGenPage.kt:660-775`）。导出按 data URI、file URI、本地路径与 http 四种形态分别处理（`FilesManager.kt:285-319`）。

编辑能力是把参考图喂给编辑接口，而不是对已生成资产做局部编辑。参考图从系统图片选择器获取，解码后统一压成 PNG 并写入临时目录，最多 16 张；移除单张或清空时会顺带删除临时文件，参考图列表非空时发送按钮走编辑而非生成（`ImgGenPage.kt:344-364,426-438`、`ImgGenVM.kt:111-123,363-372`）。

这里有一条入口事实：图库卡片没有“用作参考”“再次生成”或“发送到聊天”的动作，参考图只能来自设备选择器，因此图库中的图片不能直接再次作为参考。这是入口与事件绑定的实现事实；界面是否另有无障碍或拖拽入口未验证。

重试与分支在图片侧基本不存在。没有从历史记录一键复现的按钮，也没有把某条记录重新送入模型的路径；提示词可以被复制，但复现需要手动重填。

## 5. 视频：模块自洽但无应用侧接线

`videogen` 在模块内部是自洽的：有带状态枚举与终止判定的任务模型、只暴露提交与查询的 provider 接口、把轮询留在上层的可取消 Flow，以及三家适配器各自的状态映射与字段拒绝规则，并明确声明不负责持久化、下载与 UI（`videogen/README.md:5-23`）。但 app 侧对模块内视频生成符号的引用只有 Gradle 依赖一处，没有调用点、界面、任务仓库或产物下载。因此这条状态机在当前快照中没有产品侧消费者，本文不把它计入已闭环的视频创作能力。

## 6. 语音：流式内存播放与听写，不产媒体资产

`speech` 模块提供 TTS 与实时 ASR provider。TTS 把文本切成不超过 160 字的分片放进并发队列，预取并逐片播放，播放器把音频转成 WAV 字节交给内存数据源，播完即弃，因此既不落盘也不登记生成媒体表（`TtsController.kt:30-31,46-79`、`AudioPlayer.kt:54-67`）；ASR 用于听写与免手持语音模式，同样不产生可保存的媒体资产。Agent 侧没有图片或视频生成工具，语音是唯一交叉点：语音工具执行时发布事件、由宿主订阅后驱动播放，工具立即返回而不等待播放结束，其工具契约与事件驱动方式归 [Agent工具笔记](../Agent工具/RikkaHub-Agent工具调查笔记.md)。

## 7. 权限、资源边界与失败恢复

资源边界主要内建在参数与文件层：图片张数被夹到 1 至 4，参考图上限 16 张且去重，参考图在准备阶段就被压到 PNG 以规避格式差异；编辑接口要求文件确实存在且扩展名在白名单内，否则请求前就报错（`ImgGenVM.kt:103-113,374-377`、`OpenAIProvider.kt:271-285`）。

失败恢复是有限的。图片生成失败以异常消息弹 toast，取消静默，页面上一次结果会被清空；没有断点续跑或幂等重提。

数据生命周期方面，删除是“先删数据库记录再删文件”，批量删除以逐项 try/catch 汇总成功与失败（`ImgGenVM.kt:328-361`）。没有内容去重、来源反向索引或孤儿清理：图库删除不会检查该图片是否被其他记录引用，也没有后台任务扫描 `images` 目录与数据库的差集。这些缺口由查询面与删除实现推得，未运行验证。

## 8. 设计取舍与已确认边界

设计上，图片生成被做成独立于聊天的专用工作台：入口在抽屉、状态在独立 ViewModel、资产在独立表与目录。好处是不依赖会话上下文与消息树；代价是与聊天、附件与备份三套系统互不联通，生成结果不能直接进入聊天输入，也不被附件清理与备份覆盖。

`videogen` 选择了“先做协议层、后做产品接线”的解耦，模型、provider 接口与轮询 Flow 都在模块内完成；代价是模块存在但产品不可见。语音侧选择流式内存播放而非文件落盘，适合即时朗读与语音模式，但不产生可归档资产。

已确认边界：图片生成没有任务对象、进度、回调、重试、参数历史、版本或分支；生成结果没有再次作为参考图或聊天附件的入口；视频生成模块没有 app 侧调用点、任务持久化或产物下载；TTS/ASR 不产生媒体文件。需要说明的是，“没有视频创作 UI”的结论来自对 app 模块内视频生成符号的全局搜索只有 Gradle 依赖一处命中，以及对设置数据结构中不存在视频模型字段的检查，不排除未来快照或运行期动态装配。

## 9. 未验证事项

未运行任何图片生成或编辑请求，未验证 base64 落盘、PNG 压缩、参考图临时文件清理与导出相册的实际效果；未连接任何视频生成服务，未验证轮询间隔与终止判定在真实服务下的表现，也未运行模块自带的单元测试；未验证 TTS 与 ASR 各 provider 的实际链路与失败提示；未验证备份恢复后“有记录无文件”的具体表现，以及图片目录长期残留的实际规模。

## 10. 关键源码索引

- `app/src/main/java/me/rerere/rikkahub/ui/pages/imggen/ImgGenVM.kt:47-58,138-361`：生成/编辑入口、结果收集、落盘与删除。
- `app/src/main/java/me/rerere/rikkahub/ui/pages/imggen/ImgGenPage.kt:205-230,332-439,594-790`：页面标签、输入栏与参考图选择、图库网格与卡片操作。
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatDrawer.kt:372-379`、`RouteActivity.kt:395-397,637`：图片生成的唯一用户入口与路由。
- `ai/src/main/java/me/rerere/ai/provider/Provider.kt:43-55,81-101`：生成/编辑契约与两个参数类。
- `ai/src/main/java/me/rerere/ai/provider/providers/openai/OpenAIProvider.kt:202-312`：OpenAI 兼容生成与编辑实现。
- `ai/src/main/java/me/rerere/ai/provider/Model.kt:22-57`：模型类型与内置图像生成工具标记。
- `app/src/main/java/me/rerere/rikkahub/data/db/entity/GenMediaEntity.kt:7-27`、`data/db/dao/GenMediaDAO.kt:11-21`、`data/repository/GenMediaRepository.kt:7-13`：生成媒体实体、查询与仓储。
- `app/src/main/java/me/rerere/rikkahub/data/files/FilesManager.kt:254-283,285-319`：图片目录与相册导出。
- `app/src/main/java/me/rerere/rikkahub/data/sync/BackupManager.kt:37-64`：内置备份包含的目录集合。
- `videogen/src/main/java/me/rerere/videogen/model/VideoGeneration.kt:14-164`、`provider/VideoGenerationManager.kt:22-47`、`provider/VideoGenerationProvider.kt:6-21`：请求、任务、状态模型与可取消轮询。
- `videogen/src/main/java/me/rerere/videogen/provider/VideoGenerationProviderSetting.kt:12-34`：三家 provider 的默认端点与模型。
- `speech/src/main/java/me/rerere/tts/provider/TTSManager.kt:20-73`、`tts/controller/TtsController.kt:46-79`、`tts/controller/AudioPlayer.kt:54-67`：TTS provider 分派、分片队列与内存播放。
